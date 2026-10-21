import Foundation
import XCTest
@testable import DozableKit
@testable import DozableHost
@testable import DozableWeb

/// 635: the host-side session registry — every sandbox's sessions from the host's own events, so the overview lists
/// them without a guest call. The registry is pure; the host-level tests drive it through `HostCore` with no VM.
final class SessionRegistryTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("doz-reg-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func list(_ lines: String...) -> [SessionInfo] { SessionInfo.parseList(lines.joined(separator: "\n") + "\n") }
    private func live(_ name: String, _ cmd: String) -> String {
        "\(name)\tpid=1\tsize=80x24\tclients=0\tscreen=primary\thistory=0\tbytes=0\t\(cmd)"
    }
    private func screen(_ session: String, _ command: String) -> SavedScreenInfo {
        SavedScreenInfo(session: session, savedAt: Date(timeIntervalSince1970: 100), reason: "sleep", command: command)
    }
    private func names(_ v: (list: [SessionBrief], more: Int)) -> [String] { v.list.map(\.name) }

    // MARK: the pure registry

    func testAnOpenIsListedAndAnEndRemovesIt() {
        var r = SessionRegistry()
        r.opened("box", "claude", program: "/usr/local/bin/claude")
        r.opened("box", "shell-2", program: "bash")
        r.reconcile("box", live: list(live("claude", "claude"), live("shell-2", "bash -l")), mark: r.epoch)
        XCTAssertEqual(r.names("box"), ["claude", "shell-2"])
        XCTAssertEqual(r.entry("box", "claude")?.program, "claude", "the basename")
        r.ended("box", "shell-2")
        XCTAssertEqual(r.names("box"), ["claude"])
        r.ended("box", "claude")
        XCTAssertEqual(r.names("box"), [])
    }

    func testARestartsLateEndOfTheOldProgramIsIgnored() {
        var r = SessionRegistry()
        let old = r.opened("box", "claude", program: "claude")
        let new = r.opened("box", "claude", program: "claude")          // restarted under the same name
        XCTAssertNotEqual(old, new)
        r.ended("box", "claude", ifEpoch: old)                            // the old watcher's `.ended`, late
        XCTAssertEqual(r.names("box"), ["claude"], "the new program still runs")
        r.ended("box", "claude", ifEpoch: new)
        XCTAssertEqual(r.names("box"), [])
    }

    func testAListTakenBeforeAnOpenNeverDropsIt() {
        var r = SessionRegistry()
        r.opened("box", "claude", program: "claude")
        let mark = r.epoch                                                // the page's detail starts its `deckhold ls`
        r.opened("box", "shell-2", program: "bash")                       // New shell opens meanwhile
        r.reconcile("box", live: list(live("claude", "claude")), mark: mark)
        XCTAssertEqual(r.names("box"), ["claude", "shell-2"], "opened after the list began: kept")
        r.reconcile("box", live: list(live("claude", "claude")), mark: r.epoch)
        XCTAssertEqual(r.names("box"), ["claude"], "a later list without it: dropped")
    }

    func testAReconcileAddsWhatTheGuestRunsAndDropsWhatEnded() {
        var r = SessionRegistry()
        r.opened("box", "gone", program: "sleep")
        r.reconcile("box", live: list(live("inside", "/usr/bin/htop -d 5"), "gone\tended=0", "stale\t(stale socket)"), mark: r.epoch)
        XCTAssertEqual(r.names("box"), ["inside"], "an ended holder is never a session")
        XCTAssertEqual(r.entry("box", "inside")?.program, "htop")
        XCTAssertTrue(r.hasListed("box"))
        r.cameToRun("box")
        XCTAssertFalse(r.hasListed("box"))
    }

    func testSeenKeepsAKnownSessionAsItIs() {
        var r = SessionRegistry()
        let e = r.opened("box", "claude", program: "claude")
        r.seen("box", "claude", program: nil)
        XCTAssertEqual(r.entry("box", "claude")?.epoch, e, "an attach does not re-register it")
        r.seen("box", "other", program: nil)
        XCTAssertEqual(r.entry("box", "other")?.program, "other")
    }

    func testTheViewByPhase() {
        var r = SessionRegistry()
        var recs = SessionRecords()
        recs.sessions["shell-2"] = SessionRecord(argv: ["bash", "-l"], workdir: nil, user: nil, environmentKeys: nil,
                                                 openedAt: Date(timeIntervalSince1970: 50))
        recs.sessions["claude"] = SessionRecord(argv: ["claude"], workdir: nil, user: nil, environmentKeys: nil,
                                                openedAt: Date(timeIntervalSince1970: 60))
        let saved = [screen("shell-2", "bash -l"), screen("claude", "claude --continue")]
        // Asleep: the saved screens, marked saved, the default first.
        let asleep = r.view("box", phase: .asleep, saved: saved, records: recs, defaultSession: "claude")
        XCTAssertEqual(names(asleep), ["claude", "shell-2"])
        XCTAssertEqual(asleep.list.map(\.saved), [true, true])
        XCTAssertEqual(asleep.list.first?.isDefault, true)
        XCTAssertEqual(asleep.list.last?.openedAt, Date(timeIntervalSince1970: 50))
        for p in [Phase.paused, .hibernated] { XCTAssertEqual(names(r.view("box", phase: p, saved: saved, records: recs, defaultSession: "claude")), ["claude", "shell-2"]) }
        // Off, failed, booting: none, whatever is on disk or in memory.
        r.opened("box", "claude", program: "claude")
        for p in [Phase.off, .failed, .booting] { XCTAssertTrue(r.view("box", phase: p, saved: saved, records: recs, defaultSession: "claude").list.isEmpty) }
        // Running before this run's first guest list (a wake): the saved screens, not marked saved.
        let waking = r.view("box", phase: .running, saved: saved, records: recs, defaultSession: "claude")
        XCTAssertEqual(names(waking), ["claude", "shell-2"])
        XCTAssertEqual(waking.list.map(\.saved), [nil, nil])
        // Running after it: memory.
        r.reconcile("box", live: list(live("claude", "claude"), live("dev", "npm run dev")), mark: r.epoch)
        let run = r.view("box", phase: .running, saved: saved, records: recs, defaultSession: "claude")
        XCTAssertEqual(names(run), ["claude", "dev"])
        XCTAssertEqual(run.list.map(\.program), ["claude", "npm"])
        r.clear("box")
        XCTAssertTrue(r.view("box", phase: .running, saved: [], records: recs, defaultSession: "claude").list.isEmpty)
    }

    func testTheOrderIsStableAndCapped() {
        var r = SessionRegistry()
        let t0 = Date(timeIntervalSince1970: 1000)
        for i in 0..<40 { r.opened("box", String(format: "s-%02d", 39 - i), program: "bash", now: t0.addingTimeInterval(Double(i))) }
        r.opened("box", "claude", program: "claude", now: t0.addingTimeInterval(500))
        r.reconcile("box", live: [], mark: 0)        // listed (nothing it registered after mark 0 is dropped)
        let v = r.view("box", phase: .running, saved: [], records: SessionRecords(), defaultSession: "claude")
        XCTAssertEqual(v.list.count, SessionRegistry.maximumListed)
        XCTAssertEqual(v.more, 41 - SessionRegistry.maximumListed)
        XCTAssertEqual(v.list.first?.name, "claude", "the sandbox's own session first")
        XCTAssertEqual(v.list[1].name, "s-39", "then by when it was opened, not by name")
    }

    func testAProgramNameIsPrintableAndShort() {
        XCTAssertEqual(SessionRegistry.programName("/opt/x/bin/node"), "node")
        XCTAssertEqual(SessionRegistry.programName("ev\u{1B}[31mil"), "ev[31mil", "no control character")
        XCTAssertEqual(SessionRegistry.programName(String(repeating: "a", count: 200)).count, SessionRegistry.maximumProgramLength)
        XCTAssertEqual(SessionRegistry.programName(""), "program")
    }

    // MARK: through the host (no VM)

    func testTheHostListsASleepingSandboxFromItsFilesAndARunningOneFromMemory() async throws {
        let store = DozableStore(root: root)
        let core = HostCore(store: store, readOnly: false, version: "test")
        var c = HostRequest(.create, name: "x")
        c.create = CreateOptions(image: "lab")
        let made = await core.handle(c)
        XCTAssertNil(made.error, "\(String(describing: made.error))")
        let layout = store.layout("x")
        try SavedScreens.write(layout, info: screen("work", "bash -l"), vt: Data(), text: "")
        try SavedScreens.write(layout, info: screen("shell", "sh -l"), vt: Data(), text: "")
        SessionRecords.record("work", SessionRecord(argv: ["/bin/bash", "-l"], workdir: nil, user: nil, environmentKeys: nil,
                                                    openedAt: Date(timeIntervalSince1970: 7)), store, "x")
        let none = await core.sessionBriefs("x", phase: .off)
        XCTAssertNil(none, "a shut-down sandbox has no sessions")
        let asleepV = await core.sessionBriefs("x", phase: .hibernated)
        let asleep = try XCTUnwrap(asleepV)
        XCTAssertEqual(Set(asleep.list.map(\.name)), ["work", "shell"])
        XCTAssertEqual(asleep.list.first { $0.name == "work" }?.openedAt, Date(timeIntervalSince1970: 7), "from sessions.json")
        XCTAssertEqual(asleep.list.first { $0.name == "work" }?.program, "bash")
        // Running, before a list: the saved screens; after one: the guest's set.
        let earlyV = await core.sessionBriefs("x", phase: .running)
        let early = try XCTUnwrap(earlyV)
        XCTAssertEqual(Set(early.list.map(\.name)), ["work", "shell"])
        await core.reconcileSessions("x", list(live("work", "bash -l")), mark: 0)
        let runV = await core.sessionBriefs("x", phase: .running)
        let run = try XCTUnwrap(runV)
        XCTAssertEqual(run.list.map(\.name), ["work"])
        // ls carries it (the sandbox is off on disk here: none).
        let ls = await core.handle(HostRequest(.ls))
        let rows = try XCTUnwrap(ls.result?.decode([SandboxInfo].self))
        XCTAssertNil(rows.first?.sessionList)
    }

    func testTheFieldsRoundTripAndAnOlderPayloadDecodes() throws {
        var info = SandboxInfo(name: "box", image: "lab", phase: "asleep", busy: false, cpus: 1, memoryMiB: 512, ramHeldMiB: 0,
                               memoryReturnedMiB: 0, diskBytes: 0, sessions: nil, network: "nat", deniedConnections: nil,
                               workspace: nil, createdAt: nil, diedWithHost: nil)
        let plain = String(decoding: try HostWire.encoder.encode(info), as: UTF8.self)
        XCTAssertFalse(plain.contains("sessionList"), "nothing known: no field")
        info.sessionList = [SessionBrief(name: "claude", program: "claude", isDefault: true, openedAt: Date(timeIntervalSince1970: 3), saved: true)]
        info.sessionMore = 2
        XCTAssertEqual(try HostWire.decoder.decode(SandboxInfo.self, from: HostWire.encoder.encode(info)), info)
        let row = WebSandboxRow(info)
        XCTAssertEqual(row.sessionList?.first?.program, "claude")
        XCTAssertEqual(row.sessionMore, 2)
        let json = String(decoding: try WebJSON.encoder.encode(row), as: UTF8.self)
        XCTAssertFalse(json.contains("command"), "the overview never carries a command line")
    }

    func testAQuietPollIsNotAChange() throws {
        var info = SandboxInfo(name: "box", image: "lab", phase: "running", busy: false, cpus: 1, memoryMiB: 512, ramHeldMiB: 0,
                               memoryReturnedMiB: 0, diskBytes: 0, sessions: nil, network: "nat", deniedConnections: nil,
                               workspace: nil, createdAt: nil, diedWithHost: nil)
        var r = SessionRegistry()
        r.opened("box", "claude", program: "claude", now: Date(timeIntervalSince1970: 9))
        r.reconcile("box", live: list(live("claude", "claude")), mark: r.epoch)
        let a = r.view("box", phase: .running, saved: [], records: SessionRecords(), defaultSession: "claude")
        r.reconcile("box", live: list(live("claude", "claude")), mark: r.epoch)          // the next poll's look
        let b = r.view("box", phase: .running, saved: [], records: SessionRecords(), defaultSession: "claude")
        XCTAssertEqual(a.list, b.list, "nothing in it moves by itself")
        info.sessionList = a.list
        XCTAssertEqual(try WebJSON.encoder.encode(WebSandboxRow(info)), try WebJSON.encoder.encode(WebSandboxRow({ var j = info; j.sessionList = b.list; return j }())))
    }
}
