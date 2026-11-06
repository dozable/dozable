import Foundation
import XCTest
@testable import DozableKit

/// 676: an agent stream's pipe in the library — the bounded buffers both ways, the sever, the orphan records, the reap step's
/// place, and the guest script that finds and ends a program (run here over a fake `/proc`). The VM proof is
/// `make test-cli-agentstream`.
final class AgentPipeTests: XCTestCase {
    // MARK: back-pressure

    /// A writer faster than its reader: never more than the mark held, nothing lost, the order kept.
    func testTheOutputBufferHoldsAtMostItsMarkAndLosesNothing() {
        let buf = AgentOutputBuffer(highWater: 64 << 10)
        let chunk = 16 << 10, count = 256                     // 4 MiB through a 64 KiB buffer
        let wrote = expectation(description: "the writer finished")
        Thread.detachNewThread {
            for i in 0..<count {
                let d = Data(repeating: UInt8(i & 0xFF), count: chunk)
                XCTAssertTrue(buf.write(i % 3 == 0 ? .stderr(d) : .stdout(d)))
            }
            buf.finish()
            wrote.fulfill()
        }
        var got = 0, index = 0
        while let c = buf.next() {
            XCTAssertLessThanOrEqual(buf.buffered, buf.highWater)
            XCTAssertEqual(c.data.first, UInt8(index & 0xFF), "chunk \(index) in order")
            if case .stderr = c { XCTAssertEqual(index % 3, 0) } else { XCTAssertNotEqual(index % 3, 0) }
            got += c.data.count
            index += 1
            if index % 16 == 0 { usleep(1_000) }                 // a slow reader
        }
        wait(for: [wrote], timeout: 10)
        XCTAssertEqual(got, chunk * count)
        XCTAssertLessThanOrEqual(buf.peak, buf.highWater, "never above the high-water mark")
    }

    /// A writer blocked on a full buffer is let go by a sever (and by a reader that left).
    func testASeverUnblocksABlockedWriter() {
        for how in ["sever", "discard"] {
            let pipe = AgentPipe(label: "x", argv0: "agent", highWater: 1024)
            pipe.write(stdout: Data(repeating: 1, count: 1024))  // full
            let unblocked = expectation(description: how)
            Thread.detachNewThread {
                pipe.write(stdout: Data(repeating: 2, count: 512))   // blocks
                unblocked.fulfill()
            }
            usleep(100_000)
            if how == "sever" { pipe.sever(.sandboxSleeping) } else { pipe.hangUp() }
            wait(for: [unblocked], timeout: 2)
        }
    }

    /// The client's input: `put` blocks beyond the limit until the guest takes; close ends it after what is queued.
    func testTheInputQueueBlocksBeyondItsLimit() async {
        let q = AgentInputQueue(limit: 4096)
        let done = expectation(description: "all put")
        Thread.detachNewThread {
            for i in 0..<16 { XCTAssertTrue(q.put(Data(repeating: UInt8(i), count: 1024))) }
            q.close()
            done.fulfill()
        }
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertLessThanOrEqual(q.queuedBytes, 4096, "the writer waits for the guest")
        var got = Data()
        while let d = await q.take() {
            got.append(d)
            XCTAssertLessThanOrEqual(q.queuedBytes, 4096)
        }
        await fulfillment(of: [done], timeout: 5)
        XCTAssertEqual(got.count, 16 * 1024)
        XCTAssertEqual(got.last, 15)
        XCTAssertFalse(q.put(Data([1])), "closed: dropped")
    }

    // MARK: how it ends

    func testExitAndSeverNeverBoth() {
        let a = AgentPipe(label: "a", argv0: "agent")
        XCTAssertTrue(a.sever(.sandboxSleeping))
        a.ended(0)                                              // the exec's late end never overwrites the cut
        XCTAssertEqual(a.severed, .sandboxSleeping)
        XCTAssertNil(a.exitCode)
        XCTAssertNil(a.nextOutput())

        let b = AgentPipe(label: "b", argv0: "agent")
        b.write(stdout: Data("last words".utf8))
        b.ended(3)
        XCTAssertFalse(b.sever(.sandboxStopped), "an exit is never re-labelled as a sever")
        XCTAssertEqual(b.exitCode, 3)
        XCTAssertNil(b.severed)
        XCTAssertEqual(b.nextOutput(), .stdout(Data("last words".utf8)), "what was held is still read")
        XCTAssertNil(b.nextOutput())
        XCTAssertEqual(b.info.stdoutBytes, 10)
    }

    func testTheLabelAndTheLimit() {
        XCTAssertEqual(Sandbox.agentStreamAdmission(open: [], label: "a", force: false), .open)
        XCTAssertEqual(Sandbox.agentStreamAdmission(open: ["a"], label: "a", force: false), .labelInUse)
        XCTAssertEqual(Sandbox.agentStreamAdmission(open: ["a"], label: "a", force: true), .replace)
        let eight = (1...8).map { "s\($0)" }
        XCTAssertEqual(Sandbox.agentStreamAdmission(open: Array(eight.prefix(7)), label: "s8", force: false), .open)
        XCTAssertEqual(Sandbox.agentStreamAdmission(open: eight, label: "s9", force: false), .tooMany, "the ninth")
        XCTAssertEqual(Sandbox.agentStreamAdmission(open: eight, label: "s9", force: true), .tooMany)
        XCTAssertEqual(Sandbox.agentStreamAdmission(open: eight, label: "s1", force: true), .replace, "a replacement is not a ninth")
    }

    // MARK: orphans

    func testOrphanRecordsPersistAndAnOlderRecordHasNone() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dzk-orphan-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("doz.json")
        let spec = SandboxSpec(name: "box", storeRoot: dir)
        var p = PersistedSandbox(spec: spec, phase: .hibernated, machineIdentifier: Data([1, 2]), macAddress: nil, subnet: nil, shareTags: [:])
        try p.write(to: url)
        XCTAssertNil(PersistedSandbox.read(from: url)?.orphanedAgentPrograms, "nothing recorded: none")
        let at = Date(timeIntervalSince1970: 1_767_225_600)
        p.orphanedAgentPrograms = [AgentProgramRecord(stream: "chat", marker: "m1", pid: 42, starttime: 1234, argv0: "claude", openedAt: at),
                                   AgentProgramRecord(stream: "s-2", marker: "m2", argv0: "agent", openedAt: at)]
        try p.write(to: url)
        let back = try XCTUnwrap(PersistedSandbox.read(from: url))
        XCTAssertEqual(back.orphanedAgentPrograms, p.orphanedAgentPrograms)
        XCTAssertEqual(GuestCommand.agentReapArguments(back.orphanedAgentPrograms ?? []), ["m1", "42", "1234", "m2", "-", "-"])
    }

    /// The reap is the FIRST thing after every wake and adoption — before the guest fixes, so before any new stream (which
    /// waits for the after-wake steps) — and a resume from Pause has it only when there is something to reap.
    func testTheReapIsPlannedFirstAfterAWakeOrAnAdoption() {
        for (op, p) in [(LifecycleOperation.wake, Phase.asleep), (.resume, .asleep), (.wake, .hibernated)] {
            XCTAssertEqual(LifecyclePlanner.afterWake(op, from: p).first, .reapOrphanedAgentPrograms, "\(op) from \(p)")
        }
        XCTAssertEqual(LifecyclePlanner.afterAdoption.first, .reapOrphanedAgentPrograms)
        XCTAssertEqual(LifecyclePlanner.afterWake(.resume, from: .paused), [], "a resume from Pause stays ~1 ms")
        XCTAssertEqual(LifecyclePlanner.afterWake(.resume, from: .paused, orphanedAgentPrograms: true), [.reapOrphanedAgentPrograms])
        XCTAssertFalse(LifecyclePlanner.skippedWhenWaiting(.reapOrphanedAgentPrograms, pauseWaiting: true, putAwayWaiting: false),
                       "a waiting pause never skips it")
        // A stop's programs end with the VM: none of its plans reap.
        for op in [LifecycleOperation.shutDown, .resetToImage, .delete] {
            for p in Phase.allCases { XCTAssertFalse((LifecyclePlanner.plan(op, from: p) ?? []).contains(.reapOrphanedAgentPrograms)) }
        }
    }

    // MARK: the guest script, over a fake /proc

    /// `/proc/PID/stat` with the fields the script reads: state (3), ppid (4), pgrp (5), session (6), start time (22).
    private func fakeProcess(_ root: URL, pid: Int, comm: String = "agent", state: String = "S", ppid: Int = 0, pgrp: Int, session: Int,
                             starttime: UInt64, environ: [String]) throws {
        let d = root.appendingPathComponent(String(pid))
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        var f = ["\(pid)", "(\(comm))", state, "\(ppid)", "\(pgrp)", "\(session)"]
        while f.count < 21 { f.append("0") }
        f.append(String(starttime))
        f += ["0", "0"]
        try f.joined(separator: " ").write(to: d.appendingPathComponent("stat"), atomically: true, encoding: .utf8)
        try Data(environ.joined(separator: "\0").utf8 + [0]).write(to: d.appendingPathComponent("environ"))
    }

    private func script(_ args: [String], proc: URL) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", GuestCommand.agentPrograms, "sh"] + args
        p.environment = ["DOZ_PROC": proc.path, "PATH": "/usr/bin:/bin"]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        p.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    func testTheGuestScriptFindsTheSessionLeaderByItsMarkerAndGuardsItsStartTime() throws {
        XCTAssertTrue(GuestCommand.agentPrograms.contains(AgentPipe.markerVariable + "="), "the script looks for the variable the pipe sets")
        let proc = FileManager.default.temporaryDirectory.appendingPathComponent("dzk-proc-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: proc) }
        let m = "\(AgentPipe.markerVariable)=abc"
        // The program (a session leader, comm with a space and a parenthesis), its child (inherits the marker), a stranger.
        try fakeProcess(proc, pid: 4100, comm: "my (agent)", pgrp: 4100, session: 4100, starttime: 777, environ: ["HOME=/root", m])
        try fakeProcess(proc, pid: 4101, ppid: 4100, pgrp: 4100, session: 4100, starttime: 778, environ: [m])
        try fakeProcess(proc, pid: 4200, pgrp: 4200, session: 4200, starttime: 900, environ: ["\(AgentPipe.markerVariable)=other"])
        let found = GuestCommand.parseAgentLocate(try script(["locate", "abc"], proc: proc))
        XCTAssertEqual(found?.pid, 4100)
        XCTAssertEqual(found?.starttime, 777)
        // A pid that now belongs to another program (its start time differs) is never signalled: gone.
        let reaped = GuestCommand.parseAgentReap(try script(["reap", "abc", "4100", "999", "zzz", "4999", "1"], proc: proc))
        XCTAssertEqual(reaped, ["abc": "gone", "zzz": "gone"])
        // A zombie is gone too.
        try fakeProcess(proc, pid: 4300, state: "Z", pgrp: 4300, session: 4300, starttime: 5, environ: [])
        XCTAssertEqual(GuestCommand.parseAgentReap(try script(["reap", "z", "4300", "5"], proc: proc)), ["z": "gone"])
    }

    func testTheGuestScriptIsShellAndItsAnswersParse() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-n", "-c", GuestCommand.agentPrograms]
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, "sh -n accepts it")
        XCTAssertNil(GuestCommand.parseAgentLocate("doz-agent none\n"))
        XCTAssertEqual(GuestCommand.parseAgentLocate("noise\ndoz-agent 12 34\n")?.pid, 12)
        XCTAssertEqual(GuestCommand.parseAgentReap("agent-reap a hangup\nagent-reap b kill\nother\n"), ["a": "hangup", "b": "kill"])
    }
}
