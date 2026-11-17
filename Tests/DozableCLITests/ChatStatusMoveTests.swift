import Darwin
@testable import DozableChat
import Foundation
import XCTest
@testable import DozableCLI
@testable import DozableHost

/// `doz chat status`, `doz doctor` and `doz daemon status` never name a NEW port or address as listened on before the
/// running chat server has it: just after `doz config set chat.line_port N` the settings already say N while the old
/// server still holds the old port (seen live for about three seconds). The supervisor runs against the FAKE process
/// table; the server's own status file is the `ChatStatus` the report is handed.
final class ChatStatusMoveTests: XCTestCase {
    var root: String!
    var fake: FakeChatProcesses!
    var box: SettingsBox!
    var sup: ChatSupervisor!
    var paths: ChatPaths { ChatPaths(folder: root + "/chat") }

    override func setUpWithError() throws {
        root = "/tmp/dzc-mv-\(getpid())-\(UUID().uuidString.prefix(6))"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        fake = FakeChatProcesses()
        box = SettingsBox()
        let b = box!
        sup = ChatSupervisor(paths: ChatPaths(folder: root + "/chat"), executable: "/usr/bin/false", release: "0.0.0", processes: fake,
                             environment: [:], readSettings: { b.get() })
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(atPath: root) }

    /// The running server's own status: its pid, whether it is ready, the ports it has bound (nil: none yet).
    func server(pid: Int32, ready: Bool, page: Int?, line: Int?) -> ChatStatus {
        var s = ChatStatus(release: "0.0.0", dataDir: paths.data)
        s.running = true
        s.pid = Int(pid)
        s.ready = ready
        if let page, let line { s.ports = .init(line: line, page: page, https: 0) }
        return s
    }

    func report(_ server: ChatStatus) async -> ChatStatusReport {
        ChatStatusReport.make(paths: paths, view: box.get(), sup: await sup.status(), server: server, dir: ChatDirectory(), daemon: true)
    }

    func testANewLinePortIsNeverSaidBeforeTheServerHasIt() async throws {
        box.set(true)
        _ = try await sup.sync(human: "ada", retry: true, waitReady: false, blocked: false)
        await sup.tick(blocked: false)
        let first = fake.nextPid
        var r = await report(server(pid: first, ready: true, page: 8790, line: 8791))
        XCTAssertEqual(r.state, "running")
        XCTAssertTrue(r.ready)
        XCTAssertNil(r.movingTo)

        // doz config set chat.line_port 8765: the settings say it at once; the daemon has not looked yet.
        box.lock.withLock { box.view.linePort = 8765 }
        r = await report(server(pid: first, ready: true, page: 8790, line: 8791))
        XCTAssertEqual(r.state, "restarting", "not running and ready on a port it has not bound")
        XCTAssertFalse(r.ready)
        XCTAssertEqual(r.linePort, 8791, "the port it has")
        XCTAssertEqual(r.movingTo, ChatPortsMove(pagePort: 8790, linePort: 8765))
        XCTAssertTrue(r.text.contains("line port 8791 — moving to page port 8790, line port 8765 (not listening there yet)"), r.text)
        XCTAssertFalse(r.text.contains("running and ready"))
        XCTAssertEqual(chatDoctorCheck(fromReport: r).status, .warn)

        // The daemon's next look restarts it: the old one is gone, the new one not ready yet.
        _ = try await sup.sync(human: nil, retry: false, waitReady: false, blocked: false)
        let second = fake.nextPid
        XCTAssertNotEqual(second, first)
        r = await report(server(pid: second, ready: false, page: nil, line: nil))
        XCTAssertFalse(r.ready)
        XCTAssertEqual(r.state, "starting")
        let daemonLine = chatDaemonLine(await sup.status()) ?? ""
        XCTAssertTrue(daemonLine.hasPrefix("chat: starting"), daemonLine)

        // Only when the new server's own status file reports the new ports is it running there.
        await sup.tick(blocked: false)
        r = await report(server(pid: second, ready: true, page: 8790, line: 8765))
        XCTAssertEqual(r.state, "running")
        XCTAssertTrue(r.ready)
        XCTAssertEqual(r.linePort, 8765)
        XCTAssertNil(r.movingTo)
        XCTAssertTrue(r.text.contains("line port 8765\n"), r.text)
    }

    func testAnotherAddressIsSaidStartingUntilTheServerRunsReadyWithIt() {
        var c = ChatServerState()
        c.enabled = true
        c.state = "starting"
        c.ready = false
        c.remote = ChatRemoteState(listen: ["100.64.0.7"], agents: ["100.64.0.8"], missing: [])
        let line = chatDaemonLine(c) ?? ""
        XCTAssertFalse(line.contains("also on"), line)
        XCTAssertTrue(line.contains("starting on 100.64.0.7 too"), line)
        c.state = "running"
        c.ready = true
        c.pid = 4242
        XCTAssertTrue((chatDaemonLine(c) ?? "").contains("chat: also on 100.64.0.7"))
        // chat status: the address is "starting" while the server is not ready with it.
        let s = ChatRemoteAddressStatus.of(wanted: ["100.64.0.7"], seen: c.remote, serverReady: false, pagePort: 8790, linePort: 8791)
        XCTAssertEqual(s.first?.state, "starting")
    }
}
