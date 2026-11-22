import DozableChat
import Foundation
import XCTest
@testable import DozableKit
@testable import DozableHost

/// A workspace's manager in an in-process daemon core (scratch store, memory keychain, a fake chat server and a fake
/// launcher — nothing opened, no VM): the order check → invite → post → open; a refusal writes, posts and opens nothing;
/// a post failure opens nothing; an open failure after the post keeps `startedAt` and a retry posts nothing; the
/// one-live-workspace rule (two concurrent starts included); stop ends once and keeps the record; `--manager` validation;
/// a running manager is not released; the read-only core refuses start and stop; the unfenced token file (separable).
final class WorkspaceManagerTests: BotTestCase {
    final class Trace: @unchecked Sendable {
        let lock = NSLock()
        var steps: [String] = []
        func add(_ s: String) { lock.withLock { steps.append(s) } }
        var all: [String] { lock.withLock { steps } }
    }

    final class Chat: WorkspaceChat, @unchecked Sendable {
        let trace: Trace
        let lock = NSLock()
        var roomSet: Set<String> = ["general"]
        var members: [String: Set<String>] = [:]
        var posts: [(String, String)] = []
        var failPost = false
        var off = false
        init(_ t: Trace) { trace = t }
        func readiness() async -> WorkspaceChatReadiness { lock.withLock { off } ? .off : .ready }
        func rooms() throws -> Set<String> { lock.withLock { roomSet } }
        func makeRoom(_ name: String) throws { lock.withLock { _ = roomSet.insert(name) } }
        func post(room: String, content: String) throws {
            if lock.withLock({ failPost }) { throw HostError(.unavailable, "the chat server is gone") }
            lock.withLock { posts.append((room, content)) }
            trace.add("post \(room)")
        }
        func invite(room: String, name: String) throws -> Bool {
            let new = lock.withLock { members[room, default: []].insert(name).inserted }
            if new { trace.add("invite \(name) \(room)") }
            return new
        }
    }

    final class Launcher: ManagerLauncher, @unchecked Sendable {
        let trace: Trace
        let lock = NSLock()
        var places: [String: ManagerPlaceInfo] = [:]
        var orders: [ManagerLaunchOrder] = []
        var failLaunch = false
        var delay: Duration = .zero
        var stops = 0
        init(_ t: Trace) { trace = t }
        func info(isolation: ManagerIsolation, place: String) async -> ManagerPlaceInfo { lock.withLock { places[place] ?? ManagerPlaceInfo() } }
        func launch(_ o: ManagerLaunchOrder) async throws -> [String] {
            if delay != .zero { try await Task.sleep(for: delay) }
            if lock.withLock({ failLaunch }) { throw HostError(.failed, "the holder did not start") }
            lock.withLock {
                orders.append(o)
                places[o.place] = ManagerPlaceInfo(exists: true, running: true, heldBy: o.plan.secret?.bot)
            }
            trace.add("open \(o.place)\(o.restart ? " again" : "")")
            return []
        }
        func stop(isolation: ManagerIsolation, place: String) async throws {
            // A VM's shutdown revokes its secrets: its record no longer names the bot.
            lock.withLock { stops += 1; places[place]?.running = false; if isolation == .vm { places[place]?.heldBy = nil } }
            trace.add("stop \(place)")
        }
    }

    var trace: Trace!
    var wchat: Chat!
    var launcher: Launcher!
    var work: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        trace = Trace()
        wchat = Chat(trace)
        launcher = Launcher(trace)
        work = root.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        work = URL(fileURLWithPath: WorkspaceStore.resolved(work.path))
        // The sessions' PATH (a fake claude on it) and the fence's scratch home — this process's seams.
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: bin.appendingPathComponent("claude").path, contents: Data("#!/bin/sh\n".utf8),
                                       attributes: [.posixPermissions: 0o755])
        let home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        setenv("DOZ_TEST_MAC_PATH", bin.path + ":/usr/bin:/bin", 1)
        setenv("DOZ_TEST_FENCE_HOME", home.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("DOZ_TEST_MAC_PATH")
        unsetenv("DOZ_TEST_FENCE_HOME")
        try super.tearDownWithError()
    }

    func mgr(readOnly: Bool = false) async -> HostCore {
        let c = await core(readOnly: readOnly)
        await c.setWorkspaceChat(wchat)
        await c.setManagerLauncher(launcher)
        return c
    }

    @discardableResult
    func ws(_ c: HostCore, _ op: HostOp, _ name: String?, _ edit: (inout WorkspaceRequest) -> Void = { _ in }) async -> HostMessage {
        var w = WorkspaceRequest(name: name)
        edit(&w)
        var r = HostRequest(op)
        r.workspaceRequest = w
        return await c.handle(r)
    }

    func newBot(_ c: HostCore, _ name: String = "mira", isolation: String = "fenced", deliver: String = "poll") async throws {
        _ = try change(await ask(c, .botNew, name) { $0.agent = "claude-code"; $0.isolation = isolation; $0.deliver = deliver })
    }

    func newWorkspace(_ c: HostCore, _ name: String = "demo", manager: String? = "mira", isolation: String? = nil,
                      file: StaticString = #filePath, line: UInt = #line) async throws -> WorkspaceDetail {
        let m = await ws(c, .workspaceNew, name) {
            $0.brief = "Make the launch video.\n"
            $0.folders = [WorkspaceFolder(path: self.work.path)]
            $0.manager = manager
            $0.managerIsolation = isolation
        }
        XCTAssertNil(m.error, m.error?.message ?? "", file: file, line: line)
        return try XCTUnwrap(m.result, file: file, line: line).decode(WorkspaceDetail.self)
    }

    func started(_ m: HostMessage, file: StaticString = #filePath, line: UInt = #line) throws -> WorkspaceStarted {
        XCTAssertNil(m.error, m.error?.message ?? "", file: file, line: line)
        return try XCTUnwrap(m.result, file: file, line: line).decode(WorkspaceStarted.self)
    }

    func record(_ n: String) throws -> WorkspaceRecord? { try WorkspaceStore(store: store).read(n) }
    func recordBytes(_ n: String) -> Data? { try? Data(contentsOf: URL(fileURLWithPath: WorkspaceStore(store: store).folder(n) + "/workspace.json")) }

    // MARK: the record

    func testManagerIsRecordedNotStarted() async throws {
        let c = await mgr()
        try await newBot(c)
        let d = try await newWorkspace(c)
        XCTAssertEqual(d.state, "setting-up")
        let a = try XCTUnwrap(d.agents.first)
        XCTAssertEqual(a.role, "manager")
        XCTAssertEqual(a.bot, "mira")
        XCTAssertEqual(a.isolation, "fenced")
        XCTAssertNil(a.actsAsYou)
        XCTAssertEqual(a.state, "not started")
        XCTAssertEqual(a.place, "@mac/demo")
        XCTAssertEqual(trace.all, [], "nothing posted, nothing started")
        XCTAssertEqual(try WorkspaceStore(store: store).log("demo").map(\.action), ["created", "manager-set", "room-made"])
        let lm = await ws(c, .workspaceList, nil)
        let l = try XCTUnwrap(lm.result).decode(WorkspaceListing.self)
        XCTAssertEqual(l.workspaces.first?.manager?.words, "mira (fenced)")
    }

    func testManagerValidation() async throws {
        let c = await mgr()
        try await newBot(c)
        _ = try change(await ask(c, .botNew, "far") { $0.agent = "codex"; $0.isolation = "elsewhere" })
        _ = try change(await ask(c, .botNew, "gone") { $0.agent = "codex" })
        _ = try change(await ask(c, .botRetire, "gone"))
        try await newBot(c, "otto", isolation: "unfenced")
        try await newBot(c, "vera", isolation: "vm")
        for (bot, iso, code) in [("nosuch", nil, HostError.Code.notFound), ("far", nil, .invalid), ("gone", nil, .exists), ("mira", "elsewhere", .invalid)] {
            let m = await ws(c, .workspaceNew, "bad") { $0.brief = "B"; $0.manager = bot; $0.managerIsolation = iso }
            XCTAssertEqual(m.error?.code, code, "\(bot) \(iso ?? ""): \(m.error?.message ?? "")")
        }
        XCTAssertFalse(WorkspaceStore(store: store).exists("bad"))
        // Isolation: the bot's vm default carries; unfenced only when named.
        var d = try await newWorkspace(c, "solo", manager: "otto")
        XCTAssertEqual(d.agents.first?.isolation, "fenced", "never unfenced by default")
        d = try await newWorkspace(c, "vmw", manager: "vera")
        XCTAssertEqual(d.agents.first?.isolation, "vm")
        XCTAssertEqual(d.agents.first?.place, "vmw")
        let m = await ws(c, .workspaceEdit, "solo") { $0.manager = "otto"; $0.managerIsolation = "unfenced" }
        d = try XCTUnwrap(m.result).decode(WorkspaceDetail.self)
        XCTAssertEqual(d.agents.first?.actsAsYou, true)
        XCTAssertEqual(d.agents.first?.isolation, "unfenced")
        // --no-manager.
        let n = await ws(c, .workspaceEdit, "vmw") { $0.noManager = true }
        XCTAssertEqual(try XCTUnwrap(n.result).decode(WorkspaceDetail.self).agents, [])
        XCTAssertEqual(try WorkspaceStore(store: store).log("vmw").map(\.action).last, "manager-removed")
    }

    // MARK: start

    func testStartOrderAndRecord() async throws {
        let c = await mgr()
        try await newBot(c)
        _ = try await newWorkspace(c)
        let s = try started(await ws(c, .workspaceStart, "demo"))
        XCTAssertTrue(s.kickedOff)
        XCTAssertEqual(s.manager, "mira")
        XCTAssertEqual(s.session, "demo")
        XCTAssertEqual(trace.all, ["invite mira demo", "post demo", "open demo"], "check → invite → post → open")
        XCTAssertEqual(wchat.posts.first?.1, "Make the launch video.")
        let o = try XCTUnwrap(launcher.orders.first)
        XCTAssertEqual(o.isolation, .fenced)
        XCTAssertEqual(o.workdir, work.path)
        XCTAssertEqual(o.permissions, "locked")
        XCTAssertEqual(o.plan.secret?.bot, "mira")
        XCTAssertTrue(o.plan.argv.contains("dontAsk"))
        XCTAssertTrue(String(decoding: o.start, as: UTF8.self).contains("Make the launch video."))
        let token = try XCTUnwrap(item("mira"))
        XCTAssertFalse(o.plan.argv.joined().contains(token) || o.plan.environment.values.joined().contains(token)
                       || String(decoding: o.start, as: UTF8.self).contains("dzc_"), "no token in what is launched")
        let rec = try XCTUnwrap(record("demo"))
        XCTAssertNotNil(rec.flags.startedAt)
        XCTAssertEqual(try WorkspaceStore(store: store).log("demo").map(\.action).suffix(4), ["bot-invited", "run-opened", "kicked-off", "manager-started"])
        let logText = String(decoding: try Data(contentsOf: URL(fileURLWithPath: WorkspaceStore(store: store).folder("demo") + "/log.jsonl")), as: UTF8.self)
        XCTAssertFalse(logText.contains("Make the launch video") || logText.contains("dzc_"), "the log has hashes, never the brief or a token")
        XCTAssertTrue(logText.contains(BotTokens.fingerprint(token)))
        XCTAssertFalse(String(decoding: recordBytes("demo") ?? Data(), as: UTF8.self).contains("dzc_"))
        // Already running: nothing again.
        let again = try started(await ws(c, .workspaceStart, "demo"))
        XCTAssertEqual(again.alreadyRunning, true)
        XCTAssertEqual(trace.all.count, 3)
        // bot ls says where it runs.
        let bm = await ask(c, .botList, "")
        let l = try XCTUnwrap(bm.result).decode(BotListing.self)
        XCTAssertEqual(l.bots.first { $0.name == "mira" }?.running, "demo")
    }

    func testARefusalWritesPostsAndOpensNothing() async throws {
        let c = await mgr()
        try await newBot(c, deliver: "inbox")
        _ = try await newWorkspace(c)
        try FileManager.default.removeItem(at: work)
        let before = recordBytes("demo")
        let m = await ws(c, .workspaceStart, "demo")
        let msg = m.error?.message ?? ""
        XCTAssertEqual(m.error?.code, .invalidPhase)
        XCTAssertTrue(msg.contains("--remove-folder") && msg.contains("doz bot set mira --deliver poll"), "every gap at once: \(msg)")
        XCTAssertEqual(recordBytes("demo"), before)
        XCTAssertEqual(trace.all, [])
    }

    func testAPostFailureOpensNothing() async throws {
        let c = await mgr()
        try await newBot(c)
        _ = try await newWorkspace(c)
        wchat.failPost = true
        let m = await ws(c, .workspaceStart, "demo")
        XCTAssertNotNil(m.error)
        XCTAssertNil(try record("demo")?.flags.startedAt)
        XCTAssertEqual(launcher.orders.count, 0)
    }

    func testAnOpenFailureKeepsTheKickOffAndARetryPostsNothing() async throws {
        let c = await mgr()
        try await newBot(c)
        _ = try await newWorkspace(c)
        launcher.failLaunch = true
        let m = await ws(c, .workspaceStart, "demo")
        XCTAssertTrue(m.error?.message.contains("doz workspace start demo again (the brief is not posted twice)") == true, m.error?.message ?? "")
        XCTAssertNotNil(try record("demo")?.flags.startedAt)
        launcher.failLaunch = false
        let s = try started(await ws(c, .workspaceStart, "demo"))
        XCTAssertFalse(s.kickedOff)
        XCTAssertEqual(wchat.posts.count, 1, "the brief is posted once")
    }

    func testOneLiveWorkspacePerBot() async throws {
        let c = await mgr()
        try await newBot(c)
        _ = try await newWorkspace(c)
        _ = try await newWorkspace(c, "demo2")
        _ = try started(await ws(c, .workspaceStart, "demo"))
        let m = await ws(c, .workspaceStart, "demo2")
        XCTAssertEqual(m.error?.message, "mira already manages demo, which is running. For now a bot runs in one live workspace at a time — doz workspace stop demo first.")
        XCTAssertEqual(wchat.posts.count, 1)
        // Two at once: one wins.
        _ = try await newWorkspace(c, "w3")
        _ = try await newWorkspace(c, "w4")
        launcher.places["demo"]?.running = false
        launcher.delay = .milliseconds(300)
        func start(_ n: String) -> Task<HostMessage, Never> {
            var r = HostRequest(.workspaceStart)
            r.workspaceRequest = WorkspaceRequest(name: n)
            let req = r
            return Task { await c.handle(req) }
        }
        let a = start("w3"), b = start("w4")
        let x = await a.value, y = await b.value
        XCTAssertEqual([x.error == nil, y.error == nil].filter { $0 }.count, 1, "\(x.error?.message ?? "-") / \(y.error?.message ?? "-")")
    }

    func testStopEndsOnceAndKeepsTheRecord() async throws {
        let c = await mgr()
        try await newBot(c)
        _ = try await newWorkspace(c)
        _ = try started(await ws(c, .workspaceStart, "demo"))
        // Releasing a running manager, or editing it, is refused.
        let rel = await ws(c, .workspaceRelease, "demo") { $0.agent = "mira" }
        XCTAssertEqual(rel.error?.code, .invalidPhase)
        XCTAssertTrue(rel.error?.message.contains("doz workspace stop demo") == true)
        let ed = await ws(c, .workspaceEdit, "demo") { $0.noManager = true }
        XCTAssertEqual(ed.error?.code, .invalidPhase)
        var m = await ws(c, .workspaceStop, "demo")
        var st = try XCTUnwrap(m.result).decode(WorkspaceStopped.self)
        XCTAssertTrue(st.stopped)
        XCTAssertEqual(st.workspace.state, "asleep")
        XCTAssertNotNil(try record("demo")?.manager?.stoppedAt)
        m = await ws(c, .workspaceStop, "demo")
        st = try XCTUnwrap(m.result).decode(WorkspaceStopped.self)
        XCTAssertFalse(st.stopped, "nothing running: said, not an error")
        XCTAssertEqual(launcher.stops, 1)
        XCTAssertNotNil(item("mira"), "its token stays in its item")
        // Started again: the same place, opened again, nothing posted.
        let s = try started(await ws(c, .workspaceStart, "demo"))
        XCTAssertFalse(s.kickedOff)
        XCTAssertEqual(trace.all.last, "open demo again")
        XCTAssertEqual(wchat.posts.count, 1)
        XCTAssertNil(try record("demo")?.manager?.stoppedAt)
    }

    func testAVMManagerStartsAgainAfterAStop() async throws {
        let c = await mgr()
        try await newBot(c, "vera", isolation: "vm")
        _ = try await newWorkspace(c, "vmw", manager: "vera")
        _ = try started(await ws(c, .workspaceStart, "vmw"))
        _ = await ws(c, .workspaceStop, "vmw")
        XCTAssertNil(launcher.places["vmw"]?.heldBy)
        let s = try started(await ws(c, .workspaceStart, "vmw"))
        XCTAssertFalse(s.kickedOff)
        XCTAssertEqual(trace.all.last, "open vmw again")
        // A stranger's sandbox of that name, never this manager's: refused.
        _ = try await newWorkspace(c, "other", manager: nil)
        launcher.places["fresh"] = ManagerPlaceInfo(exists: true, running: false, heldBy: nil)
        try await newBot(c, "nova", isolation: "vm")
        _ = try await newWorkspace(c, "fresh", manager: "nova")
        let m = await ws(c, .workspaceStart, "fresh")
        XCTAssertTrue(m.error?.message.contains("a sandbox called fresh already exists") == true, m.error?.message ?? "")
    }

    func testNoManagerYouDrive() async throws {
        let c = await mgr()
        _ = try await newWorkspace(c, manager: nil)
        let s = try started(await ws(c, .workspaceStart, "demo"))
        XCTAssertTrue(s.kickedOff)
        XCTAssertNil(s.manager)
        XCTAssertEqual(trace.all, ["post demo"])
        XCTAssertEqual(s.workspace.state, "asleep")
    }

    // MARK: the brief edited after the start

    func edit(_ c: HostCore, _ text: String, ifBrief: String? = nil) async -> HostMessage {
        await ws(c, .workspaceEdit, "demo") { $0.brief = text; $0.ifBrief = ifBrief }
    }

    func logActions(_ n: String = "demo") throws -> [String] { try WorkspaceStore(store: store).log(n).map(\.action) }

    func testAnEditWhileSettingUpPostsNothing() async throws {
        let c = await mgr()
        _ = try await newWorkspace(c, manager: nil)
        let m = await edit(c, "A new brief.\n")
        XCTAssertNil(m.error, m.error?.message ?? "")
        XCTAssertTrue(wchat.posts.isEmpty, "setting up: the start posts the brief, an edit posts nothing")
        XCTAssertFalse(try logActions().contains("brief-announced"))
        XCTAssertEqual(try record("demo")?.brief.bytes, "A new brief.\n".utf8.count)
    }

    func testEachEditAfterTheStartIsAnnouncedOnceAsYou() async throws {
        let c = await mgr()
        _ = try await newWorkspace(c, manager: nil)
        _ = try started(await ws(c, .workspaceStart, "demo"))
        XCTAssertEqual(wchat.posts.count, 1, "the kick-off")
        var m = await edit(c, "Make it 45 seconds.\n")
        XCTAssertNil(m.error, m.error?.message ?? "")
        XCTAssertEqual(wchat.posts.count, 2)
        XCTAssertEqual(wchat.posts.last?.0, "demo", "in the main room")
        XCTAssertEqual(wchat.posts.last?.1, ManagerKickoff.briefEdited(brief: "Make it 45 seconds.\n", refs: []))
        XCTAssertTrue(wchat.posts.last?.1.hasPrefix("I edited the work:\n\nMake it 45 seconds.") == true)
        let entries = try WorkspaceStore(store: store).log("demo")
        XCTAssertEqual(entries.suffix(2).map(\.action), ["brief-edited", "brief-announced"])
        XCTAssertEqual(entries.last?.room, "demo")
        XCTAssertEqual(entries.last?.by, "you")
        // A second edit: one more post; an edit of the references only: none.
        m = await edit(c, "Make it 30 seconds.\n")
        XCTAssertNil(m.error)
        XCTAssertEqual(wchat.posts.count, 3)
        m = await ws(c, .workspaceEdit, "demo") { $0.addRefs = ["https://example.com/spec"] }
        XCTAssertNil(m.error, m.error?.message ?? "")
        XCTAssertEqual(wchat.posts.count, 3, "only a new brief is announced")
        XCTAssertEqual(try logActions().filter { $0 == "brief-announced" }.count, 2)
    }

    /// A bot running in a started workspace: changing its instructions, model or account posts ONE line as you in that
    /// workspace's main room and logs `bot-changed`; an avatar posts nothing; a bot that does not run posts nothing.
    func testARunningBotsChangeIsToldInItsRoomOnce() async throws {
        let c = await mgr()
        try await newBot(c)
        _ = try await newWorkspace(c)
        _ = try started(await ws(c, .workspaceStart, "demo"))
        let kickoff = wchat.posts.count
        let m = await ask(c, .botSet, "mira") { $0.instructions = "Answer in one line.\n" }
        let ch = try change(m)
        XCTAssertEqual(wchat.posts.count, kickoff + 1, "one line")
        XCTAssertEqual(wchat.posts.last?.0, "demo", "in the main room")
        XCTAssertEqual(wchat.posts.last?.1, "mira's instructions changed; they apply from mira's next session")
        XCTAssertTrue(ch.bot.notes?.contains("mira runs in demo: its instructions apply from its next session; demo's room is told") == true,
                      "\(ch.bot.notes ?? [])")
        var entries = try WorkspaceStore(store: store).log("demo")
        XCTAssertEqual(entries.last?.action, "bot-changed")
        XCTAssertEqual(entries.last?.agent, "mira")
        XCTAssertEqual(entries.last?.reason, "instructions")
        XCTAssertEqual(entries.last?.sentence, "told demo that mira's instructions apply from its next session")
        // Model and account together: one line; an avatar alone: none; the same model again: none.
        _ = try change(await ask(c, .botSet, "mira") { $0.model = "sonnet"; $0.account = "mac" })
        XCTAssertEqual(wchat.posts.count, kickoff + 2)
        XCTAssertEqual(wchat.posts.last?.1, "mira's model and account changed; they apply from mira's next session")
        _ = try change(await ask(c, .botSet, "mira") { $0.avatar = "🦊" })
        _ = try change(await ask(c, .botSet, "mira") { $0.model = "sonnet" })
        XCTAssertEqual(wchat.posts.count, kickoff + 2, "an avatar, or nothing new, posts nothing")
        // Stopped: nothing runs, nothing is told.
        _ = await ws(c, .workspaceStop, "demo")
        _ = try change(await ask(c, .botSet, "mira") { $0.instructions = "Two lines.\n" })
        XCTAssertEqual(wchat.posts.count, kickoff + 2, "a bot that does not run: nothing posted")
        entries = try WorkspaceStore(store: store).log("demo")
        XCTAssertEqual(entries.filter { $0.action == "bot-changed" }.count, 2)
    }

    func testChatOffKeepsTheEditAndSaysItWasNotAnnounced() async throws {
        let c = await mgr()
        _ = try await newWorkspace(c, manager: nil)
        _ = try started(await ws(c, .workspaceStart, "demo"))
        wchat.lock.withLock { wchat.off = true }
        let m = await edit(c, "Changed while chat is off.\n")
        XCTAssertNil(m.error, m.error?.message ?? "")
        let d = try XCTUnwrap(m.result).decode(WorkspaceDetail.self)
        XCTAssertEqual(d.notes, ["not announced: chat is off"])
        XCTAssertEqual(wchat.posts.count, 1, "only the kick-off")
        XCTAssertEqual(try record("demo")?.brief.bytes, "Changed while chat is off.\n".utf8.count, "the edit is kept")
        XCTAssertFalse(try logActions().contains("brief-announced"))
    }

    func testIfBriefMismatchWritesNothing() async throws {
        let c = await mgr()
        _ = try await newWorkspace(c, manager: nil)
        _ = try started(await ws(c, .workspaceStart, "demo"))
        let before = recordBytes("demo")
        let logBefore = try logActions()
        let briefBefore = WorkspaceStore(store: store).readBrief("demo")
        let m = await edit(c, "Someone else's change.\n", ifBrief: String(repeating: "0", count: 64))
        XCTAssertEqual(m.error?.code, .fileChanged)
        XCTAssertTrue(m.error?.message.contains("changed since you opened it") == true, m.error?.message ?? "")
        XCTAssertEqual(recordBytes("demo"), before, "nothing written")
        XCTAssertEqual(try logActions(), logBefore)
        XCTAssertEqual(WorkspaceStore(store: store).readBrief("demo"), briefBefore)
        XCTAssertEqual(wchat.posts.count, 1, "nothing posted")
        // The current sha256 is accepted.
        let sha = try XCTUnwrap(try record("demo")?.brief.sha256)
        let mine = await edit(c, "Mine.\n", ifBrief: sha)
        XCTAssertNil(mine.error)
        XCTAssertEqual(wchat.posts.count, 2)
    }

    func testTheReadOnlyCoreRefuses() async throws {
        let c = await mgr()
        try await newBot(c)
        _ = try await newWorkspace(c)
        let r = await mgr(readOnly: true)
        for op in [HostOp.workspaceStart, .workspaceStop] {
            let a = await ws(r, op, "demo")
            XCTAssertEqual(a.error?.code, .unavailable, op.rawValue)
        }
        XCTAssertFalse(HostOp.workspaceStart.isReadOnly)
        XCTAssertFalse(HostOp.workspaceStop.isReadOnly)
    }

    // MARK: unfenced (separable)

    func testUnfencedTokenFile() async throws {
        let c = await mgr()
        try await newBot(c, "otto", isolation: "unfenced")
        _ = try await newWorkspace(c, "solo", manager: "otto", isolation: "unfenced")
        let s = try started(await ws(c, .workspaceStart, "solo"))
        XCTAssertEqual(s.isolation, "unfenced")
        let o = try XCTUnwrap(launcher.orders.first)
        XCTAssertNil(o.plan.secret)
        let file = try XCTUnwrap(o.plan.environment["CHAT_TOKEN_FILE"])
        let dir = (file as NSString).deletingLastPathComponent
        func mode(_ p: String) -> mode_t { var st = stat(); return lstat(p, &st) == 0 ? st.st_mode & 0o777 : 0 }
        XCTAssertEqual(mode(file), 0o600)
        XCTAssertEqual(mode(dir), 0o700)
        XCTAssertEqual(try String(contentsOfFile: file, encoding: .utf8), item("otto"))
        XCTAssertFalse(o.plan.argv.contains("dontAsk"))
        _ = await ws(c, .workspaceStop, "solo")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir), "deleted at stop")
        // The sweep: a folder of no running session goes.
        try FileManager.default.createDirectory(atPath: c.managerTokenFolder("ghost"), withIntermediateDirectories: true)
        await c.sweepManagerTokenFiles()
        XCTAssertFalse(FileManager.default.fileExists(atPath: c.managerTokenFolder("ghost")))
        try? FileManager.default.removeItem(atPath: c.managerTokenRoot)
    }
}
