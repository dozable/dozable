import Darwin
import Foundation
import XCTest
@testable import DozableCLI
@testable import DozableHost

/// 749 (WS.02): the test hooks' decisions — the guard (the stub and `doz debug crash` refused unguarded), the stub's argv and
/// environment, how it reads a message and what it answers, and the two log lines. The stub end to end, with the real daemon
/// and chat server: `make test-cli-workspace` rows T1–T8.
final class StubAgentTests: XCTestCase {
    let guardedEnv = ["DOZ_TEST_GUARD": "1", "DOZ_TEST_STUB_AGENT": "1"]
    let unguarded = ["DOZ_TEST_REAL_MAC": "1", "DOZ_TEST_STUB_AGENT": "1"]

    // MARK: the guard

    func testTheStubIsHonouredOnlyGuarded() {
        XCTAssertTrue(TestSafety.stubAgent(guardedEnv))
        XCTAssertFalse(TestSafety.stubAgent(unguarded), "DOZ_TEST_REAL_MAC=1 lifts the guard: no stub")
        XCTAssertFalse(TestSafety.stubAgent(["DOZ_TEST_GUARD": "1"]), "guarded, not asked")
        XCTAssertFalse(TestSafety.stubAgent(["DOZ_TEST_GUARD": "1", "DOZ_TEST_STUB_AGENT": "yes"]), "only 1 turns it on")
    }

    func testTheStubRefusesToRunUnguarded() {
        XCTAssertEqual(StubAgentRunner.run(["--name", "tess"], environment: unguarded), ExitCodes.notPermitted)
        XCTAssertEqual(StubAgentRunner.run(["--name", "tess"], environment: ["DOZ_TEST_REAL_MAC": "1"]), ExitCodes.notPermitted)
        XCTAssertEqual(StubAgentRunner.run(["--name", "tess"], environment: ["DOZ_TEST_GUARD": "1"]), ExitCodes.notPermitted, "guarded but not switched on")
        XCTAssertEqual(StubAgentRunner.run(["--room", "r"], environment: guardedEnv), ExitCodes.usage, "no name: usage")
    }

    func testTheCrashCommandIsRefusedUnguarded() {
        XCTAssertNotNil(TestSafety.debugCrashViolation(["DOZ_TEST_REAL_MAC": "1"]))
        XCTAssertNil(TestSafety.debugCrashViolation(["DOZ_TEST_GUARD": "1"]))
        XCTAssertEqual(ExitCodes.exit(for: HostError(.notPermitted, "x")), 9, "refused as not-permitted: exit 9")
    }

    func testAVMAgentIsRefusedUnderTheStub() {
        let e = StubAgent.vmRefusal("vic")
        XCTAssertEqual(e.code, .invalid)
        XCTAssertTrue(e.message.contains("vic") && e.message.contains("no Sandbox is started"))
    }

    // MARK: its argv and environment

    func testItsArgvRoundTrips() {
        let a = StubAgent.argv(doz: "/opt/doz/doz", name: "tess", room: "stb", task: "-count the files")
        XCTAssertEqual(a, ["/opt/doz/doz", "debug", "stub-agent", "--name", "tess", "--room", "stb", "--task=-count the files"])
        XCTAssertEqual(StubAgent.Options.parse(Array(a.dropFirst(3))), StubAgent.Options(name: "tess", room: "stb", task: "-count the files"))
        XCTAssertEqual(StubAgent.argv(doz: "/d", name: "sera", room: nil, task: nil), ["/d", "debug", "stub-agent", "--name", "sera"])
        XCTAssertEqual(StubAgent.Options.parse(["--name", "sera", "--task", "x y"])?.task, "x y")
        XCTAssertNil(StubAgent.Options.parse(["--name"]))
        XCTAssertNil(StubAgent.Options.parse(["--name", "a", "--other", "b"]))
        XCTAssertNil(StubAgent.Options.parse([]))
        XCTAssertTrue(StubAgent.isStub(argv: a, name: "tess"))
        XCTAssertFalse(StubAgent.isStub(argv: a, name: "sera"))
        XCTAssertFalse(StubAgent.isStub(argv: ["/usr/bin/claude", "--name", "tess"], name: "tess"))
    }

    func testItsEnvironmentIsMarked() {
        let e = StubAgent.environment(["CHAT_URL": "http://host.dozable.internal:1"], resumed: false)
        XCTAssertEqual(e["DOZ_TEST_GUARD"], "1")
        XCTAssertEqual(e[StubAgent.variable], "1")
        XCTAssertNil(e[StubAgent.resumedVariable])
        XCTAssertEqual(e["CHAT_URL"], "http://host.dozable.internal:1")
        XCTAssertEqual(StubAgent.environment(e, resumed: true)[StubAgent.resumedVariable], "1")
    }

    // MARK: what it hears

    func testTheCommands() {
        XCTAssertEqual(StubAgent.command("hello there"), .ack)
        XCTAssertEqual(StubAgent.command("/stubby"), .ack, "not the word /stub")
        XCTAssertEqual(StubAgent.command("/stub ping"), .ping)
        XCTAssertEqual(StubAgent.command("  /stub   write  notes/a.txt "), .write("notes/a.txt"))
        XCTAssertEqual(StubAgent.command("/stub write"), .unknown("write"))
        XCTAssertEqual(StubAgent.command("/stub ask ship it?"), .ask("ship it?"))
        XCTAssertEqual(StubAgent.command("/stub exit 3"), .exit(3))
        XCTAssertEqual(StubAgent.command("/stub exit 0"), .exit(0))
        XCTAssertEqual(StubAgent.command("/stub exit 256"), .unknown("exit 256"))
        XCTAssertEqual(StubAgent.command("/stub exit x"), .unknown("exit x"))
        XCTAssertEqual(StubAgent.command("/stub dance"), .unknown("dance"))
        XCTAssertEqual(StubAgent.command("/stub"), .unknown(""))
    }

    func testAddressedOnlyByItsOwnName() {
        XCTAssertEqual(StubAgent.addressedText("@tess hello", name: "tess"), "hello")
        XCTAssertEqual(StubAgent.addressedText("  @tess", name: "tess"), "")
        XCTAssertNil(StubAgent.addressedText("@tessa hello", name: "tess"))
        XCTAssertNil(StubAgent.addressedText("hello @tess", name: "tess"))
        XCTAssertNil(StubAgent.addressedText("@sera hello", name: "tess"))
    }

    func line(_ o: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: o) }

    func testAReceivedItem() {
        let item: [String: Any] = ["msgV": 1, "msg_id": "41fa46f4-1111-4222-8333-444455556666", "type": "user", "from": "ada", "room": "stb",
                                   "message": ["role": "user", "content": "@tess /stub ping"]]
        XCTAssertEqual(StubAgent.addressed(line(item), name: "tess"),
                       StubAgent.Addressed(room: "stb", msgID: "41fa46f4-1111-4222-8333-444455556666", from: "ada", command: .ping))
        var mine = item; mine["from"] = "tess"
        XCTAssertNil(StubAgent.addressed(line(mine), name: "tess"), "never its own message")
        var notice = item; notice["type"] = "notice"
        XCTAssertNil(StubAgent.addressed(line(notice), name: "tess"), "a notice is not a message")
        var other = item; other["message"] = ["content": "@sera hi"]
        XCTAssertNil(StubAgent.addressed(line(other), name: "tess"))
        XCTAssertNil(StubAgent.addressed(Data("not json".utf8), name: "tess"))
        XCTAssertNil(StubAgent.addressed(line(["msg_id": "x", "room": "r", "from": "a"]), name: "tess"), "no content")
    }

    // MARK: what it says

    func testItsWordsAreDeterministic() {
        XCTAssertEqual(StubAgent.isUp("tess"), "tess is up")
        XCTAssertEqual(StubAgent.ack("41fa46f4-1111-4222-8333-444455556666"), "ack 41fa46f4")
        XCTAssertEqual(StubAgent.task("count the files"), "task: count the files")
        XCTAssertEqual(StubAgent.done, "done")
        XCTAssertEqual(StubAgent.pong, "pong")
        XCTAssertEqual(StubAgent.wrote("out.txt"), "wrote out.txt")
        XCTAssertEqual(StubAgent.refused("x", "why"), "refused x: why")
        XCTAssertEqual(StubAgent.noDecider, "refused ask: no decider")
    }

    func testTheAskAnswer() {
        XCTAssertNil(StubAgent.askAnswer(exit: 0, output: #"{"msg_id":"a","state":"accepted"}"#), "the ask is the message")
        XCTAssertEqual(StubAgent.askAnswer(exit: 3, output: #"{"msg_id":"a","state":"refused","detail":"an ask needs a decider: nobody here can decide"}"#),
                       StubAgent.noDecider)
        XCTAssertEqual(StubAgent.askAnswer(exit: 3, output: #"{"state":"refused","detail":"asks are off on this server"}"#),
                       "refused ask: asks are off on this server")
        XCTAssertEqual(StubAgent.askAnswer(exit: 5, output: "dozchat: no answer"), "refused ask: dozchat: no answer")
    }

    func testAWriteRefusalNamesTheGrantOrTheRule() throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("stub-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: work) }
        XCTAssertEqual(StubAgent.writeRefusal(errno: EPERM, path: "/somewhere/else.txt", workdir: work),
                       "no folder.write grant — it is outside the workspace's folders")
        XCTAssertEqual(StubAgent.writeRefusal(errno: EPERM, path: "a.txt", workdir: work), "a folder rule (the fence's) makes it read-only")
        try Data().write(to: URL(fileURLWithPath: work + "/.dozreadonly"))
        XCTAssertEqual(StubAgent.writeRefusal(errno: EACCES, path: work + "/b.txt", workdir: work), "a folder rule (.dozreadonly) makes it read-only")
        XCTAssertEqual(StubAgent.writeRefusal(errno: ENOENT, path: "x/y.txt", workdir: work), String(cString: strerror(ENOENT)))
    }

    func testItReadsItsOwnArguments() throws {
        let args = try XCTUnwrap(StubAgent.processArguments(getpid()))
        XCTAssertFalse(args.isEmpty)
        XCTAssertNil(StubAgent.processArguments(-1))
    }

    // MARK: the log lines

    func testTheJoinedAndCrashedLines() throws {
        XCTAssertEqual(WorkspaceLogEntry(by: "doz", action: "agent-joined", agent: "tess", room: "stb").sentence, "tess joined")
        var e = WorkspaceLogEntry(by: "doz", action: "agent-crashed", agent: "tess", place: "mac:stb-tess")
        e.exitCode = 70
        XCTAssertEqual(e.sentence, "tess crashed: exit 70")
        XCTAssertTrue(WorkspaceLogEntry.actions.isSuperset(of: ["agent-joined", "agent-crashed"]))
        // Additive: the code round-trips, and a line written before it reads with none.
        let back = try HostWire.decoder.decode(WorkspaceLogEntry.self, from: HostWire.encoder.encode(e))
        XCTAssertEqual(back.exitCode, 70)
        let old = try HostWire.decoder.decode(WorkspaceLogEntry.self, from: Data(#"{"v":1,"at":"2026-11-22T10:00:00Z","by":"doz","action":"agent-crashed","agent":"tess"}"#.utf8))
        XCTAssertEqual(old.sentence, "tess crashed: exit ?")
    }

    func testARequestedEndIsTakenOnce() async {
        let store = DozableStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("stub-\(UUID().uuidString)"))
        let mac = MacSessions(store: store, readOnly: true)
        let taken = await mac.takeRequestedEnd("nothing")
        XCTAssertFalse(taken, "no end asked: an exit with a code is a crash")
    }
}
