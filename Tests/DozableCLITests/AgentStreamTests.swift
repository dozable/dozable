import Foundation
import XCTest
import ArgumentParser
@testable import DozableKit
@testable import DozableHost
@testable import DozableCLI

/// 676: `agent-stream`'s wire — the frames cut anywhere, the parsers both ways, the end record (exit or severed, never both),
/// the label rules, the wake rule, the version check, the CLI's parse and its exit codes. No VM: the relay itself is
/// `AgentStreamRelayTests`, the VM proof `make test-cli-agentstream`.
final class AgentStreamTests: XCTestCase {
    func testFramesRoundTripCutAnywhere() throws {
        let big = Data((0..<(CopyFrame.maximumPayload + 10)).map { UInt8($0 & 0xFF) })
        var wire = Data()
        for f in AgentFrame.chunked(AgentFrame.data, Data("{\"type\":\"system\"}\n".utf8)) { wire.append(f) }
        for f in AgentFrame.chunked(AgentFrame.stderr, Data("warn\n".utf8)) { wire.append(f) }
        for f in AgentFrame.chunked(AgentFrame.data, big) { wire.append(f) }
        let end = AgentStreamEnd(exitCode: nil, severed: "sleeping", stdoutBytes: 3, stdinBytes: 4, milliseconds: 5)
        wire.append(AgentFrame.encode(AgentFrame.end, try HostWire.encoder.encode(end)))
        let p = AgentFrame.clientParser()
        var got: [(type: UInt8, payload: Data)] = []
        var at = 0
        while at < wire.count { got += try p.feed(wire.subdata(in: at..<min(at + 7, wire.count))); at += 7 }
        XCTAssertEqual(got.map(\.type), [AgentFrame.data, AgentFrame.stderr, AgentFrame.data, AgentFrame.data, AgentFrame.end])
        XCTAssertEqual(got[2].payload.count, CopyFrame.maximumPayload, "a payload over 1 MiB goes as two frames")
        XCTAssertEqual(got[2].payload + got[3].payload, big)
        XCTAssertEqual(got[1].payload, Data("warn\n".utf8))
        XCTAssertEqual(try HostWire.decoder.decode(AgentStreamEnd.self, from: got[4].payload), end)
    }

    func testTheParsersEachWay() throws {
        // copy's parser still refuses R.
        XCTAssertThrowsError(try CopyFrame.Parser().feed(AgentFrame.encode(AgentFrame.stderr, Data("x".utf8))))
        // A client skips a host → client type it does not know, and reads on.
        let skipping = try AgentFrame.clientParser().feed(AgentFrame.encode(0x5A, Data("new".utf8)) + AgentFrame.encode(AgentFrame.data, Data("ok".utf8)))
        XCTAssertEqual(skipping.map(\.type), [AgentFrame.data])
        XCTAssertEqual(skipping.first?.payload, Data("ok".utf8))
        // The host refuses a client → host type it does not know — and the host's own types from a client.
        for t: UInt8 in [0x5A, AgentFrame.end, AgentFrame.stderr] {
            XCTAssertThrowsError(try AgentFrame.hostParser().feed(AgentFrame.encode(t, Data())), "type \(t)")
        }
        XCTAssertEqual(try AgentFrame.hostParser().feed(AgentFrame.encode(AgentFrame.data, Data("in".utf8)) + AgentFrame.encode(AgentFrame.finish)).map(\.type),
                       [AgentFrame.data, AgentFrame.finish])
        // Over 1 MiB in one frame: refused either way.
        var huge = Data([AgentFrame.data, 0x00, 0x10, 0x00, 0x01])
        huge.append(Data(count: 8))
        XCTAssertThrowsError(try AgentFrame.hostParser().feed(huge)) { XCTAssertEqual($0 as? CopyFrame.Parser.Failure, .tooLarge) }
        XCTAssertThrowsError(try AgentFrame.clientParser().feed(huge))
    }

    /// `E`: exactly one of the exit code and the severed word — never both, never neither.
    func testTheEndIsTheExitOrTheSeveredWordNeverBoth() {
        func end(_ code: Int32?, _ r: DetachReason?, stopping: Bool = false) -> AgentStreamEnd {
            AgentFrame.end(exitCode: code, severed: r, hostStopping: stopping, stdoutBytes: 1, stdinBytes: 2, milliseconds: 3)
        }
        XCTAssertEqual(end(0, nil).exitCode, 0)
        XCTAssertNil(end(0, nil).severed)
        XCTAssertEqual(end(3, nil, stopping: true).exitCode, 3, "a program that exited exited, even as the host stops")
        XCTAssertEqual(end(nil, .sandboxSleeping).severed, "sleeping")
        XCTAssertEqual(end(nil, .sandboxStopped).severed, "stopped")
        XCTAssertEqual(end(nil, .sandboxSleeping, stopping: true).severed, "host-stopping")
        XCTAssertEqual(end(nil, nil).severed, "transport-lost")
        XCTAssertEqual(end(nil, .transportLost).severed, "transport-lost")
        XCTAssertEqual(end(nil, nil, stopping: true).severed, "host-stopping")
        for code: Int32? in [nil, 0, 7] {
            for r: DetachReason? in [nil, .sandboxSleeping, .sandboxStopped, .transportLost, .closedByClient] {
                for s in [false, true] {
                    let e = end(code, r, stopping: s)
                    XCTAssertTrue((e.exitCode == nil) != (e.severed == nil), "\(String(describing: code)) \(String(describing: r)) \(s)")
                    if let w = e.severed { XCTAssertTrue(AgentFrame.severedWords.contains(w), w) }
                }
            }
        }
    }

    func testTheOpAndItsRequest() throws {
        XCTAssertEqual(HostOp.agentStream.rawValue, "agent-stream")
        XCTAssertFalse(HostOp.agentStream.isReadOnly)
        var r = HostRequest(.agentStream, name: "x")
        r.argv = ["claude", "--print"]
        r.stream = "chat-1"
        r.force = true
        let back = try HostWire.decoder.decode(HostRequest.self, from: try HostWire.encoder.encode(r))
        XCTAssertEqual(back, r)
        XCTAssertEqual(back.stream, "chat-1")
    }

    /// It streams on its own connection: as a plain request it is refused; from a future client, `version` first.
    func testAsAPlainRequestItIsRefusedAndAFutureClientGetsVersion() async throws {
        let root = URL(fileURLWithPath: "/tmp/dza-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let core = HostCore(store: DozableStore(root: root), readOnly: false, version: "0.0.0-test")
        let m = await core.handle(HostRequest(.agentStream, name: "x"))
        XCTAssertEqual(m.error?.code, .invalid)
        var r = HostRequest(.agentStream, name: "x")
        r.v = 2
        XCTAssertEqual(HostServer.versionRefusal(try HostWire.encoder.encode(r))?.error?.code, .version)
    }

    func testStreamLabels() {
        for ok in ["chat", "chat-1", "s-0a1b2c3d", "a.b_c:d", String(repeating: "x", count: 64)] { XCTAssertTrue(HostCore.validStreamLabel(ok), ok) }
        for bad in ["", "two words", "é", "a/b", String(repeating: "x", count: 65), "x\n"] { XCTAssertFalse(HostCore.validStreamLabel(bad), bad) }
        let made = HostCore.newStreamLabel()
        XCTAssertTrue(made.hasPrefix("s-") && HostCore.validStreamLabel(made))
        XCTAssertNotEqual(made, HostCore.newStreamLabel())
    }

    /// A client's line wakes a paused or asleep sandbox — and nothing else (hibernated or off: its stream was severed).
    func testInputWakesPausedAndAsleepOnly() {
        for p in Phase.allCases { XCTAssertEqual(HostCore.agentInputWakes(p), p == .paused || p == .asleep, p.rawValue) }
    }

    /// The wake is asked once at a time, however many frames arrive meanwhile.
    func testWakeOnInputIsDeduplicated() async {
        let count = ByteCount()
        let gate = DispatchSemaphore(value: 0)
        let w = WakeOnInput { count.add(1); await Task.detached { Self.block(gate) }.value }
        for _ in 0..<50 { w.input() }
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(count.value, 1)
        gate.signal()
        try? await Task.sleep(for: .milliseconds(100))
        w.input()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(count.value, 2)
        gate.signal()
    }

    func testTheReadyAnswer() throws {
        let r = AgentStreamReady(stream: "chat", runAs: "agent", workdir: "/workspace", woke: true)
        XCTAssertEqual(String(decoding: try HostWire.encoder.encode(r), as: UTF8.self), #"{"runAs":"agent","stream":"chat","woke":true,"workdir":"/workspace"}"#)
    }

    private static func block(_ s: DispatchSemaphore) { _ = s.wait(timeout: .now() + 10) }

    // MARK: the CLI

    func testTheCommandParses() throws {
        let c = try AgentStreamCommand.parse(["box", "--stream", "chat", "--force", "--user", "root", "--workdir", "/tmp", "-e", "A=1",
                                              "--no-wake", "--", "claude", "--print"])
        XCTAssertEqual(c.name, "box")
        XCTAssertEqual(c.command, ["claude", "--print"])
        let r = try c.request()
        XCTAssertEqual(r.op, .agentStream)
        XCTAssertEqual(r.stream, "chat")
        XCTAssertEqual(r.force, true)
        XCTAssertEqual(r.user, "root")
        XCTAssertEqual(r.workdir, "/tmp")
        XCTAssertEqual(r.environment, ["A": "1"])
        XCTAssertEqual(r.wake, false)
        XCTAssertEqual(r.start, true, "an off sandbox is started unless --no-start")
        let plain = try AgentStreamCommand.parse(["box", "--", "sh"]).request()
        XCTAssertNil(plain.stream)
        XCTAssertNil(plain.force)
        XCTAssertThrowsError(try AgentStreamCommand.parse(["box"]))
    }

    /// The program's code passes through; severed — or no `E` at all — is 75 with one line on stderr.
    func testExitCodes() {
        func e(_ c: Int32?, _ s: String?) -> AgentStreamEnd { AgentStreamEnd(exitCode: c, severed: s, stdoutBytes: 0, stdinBytes: 0, milliseconds: 0) }
        XCTAssertEqual(AgentStreamCommand.outcome(e(0, nil)).code, 0)
        XCTAssertNil(AgentStreamCommand.outcome(e(0, nil)).line)
        XCTAssertEqual(AgentStreamCommand.outcome(e(3, nil)).code, 3)
        for w in AgentFrame.severedWords + ["a-word-from-a-newer-host"] {
            let o = AgentStreamCommand.outcome(e(nil, w))
            XCTAssertEqual(o.code, 75)
            XCTAssertEqual(o.line, "doz agent-stream: severed (\(w))")
        }
        XCTAssertEqual(AgentStreamCommand.outcome(nil).code, 75)
        XCTAssertEqual(AgentStreamCommand.outcome(nil).line, "doz agent-stream: severed (transport-lost)")
        XCTAssertEqual(AgentStreamCommand.severedExit, 75)
    }
}
