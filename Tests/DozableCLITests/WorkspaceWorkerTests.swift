import DozableChat
import Foundation
import XCTest
@testable import DozableKit
@testable import DozableHost

/// Workers in an in-process daemon core (scratch store, a fresh memory keychain, fakes for the chat server's rooms, its
/// participants and the launchers — nothing opened, no VM): the order check → pending → participant → invite → secret →
/// launch → live; each failure undoes the earlier steps; the refusals; end (an anonymous worker removed and its token
/// refused, its item gone; a bot's item kept; --rm; an unknown NAME); names; the sweep of a pending entry; the one-live
/// rule both ways.
final class WorkspaceWorkerTests: BotTestCase {
    final class Trace: @unchecked Sendable {
        let lock = NSLock()
        var steps: [String] = []
        func add(_ s: String) { lock.withLock { steps.append(s) } }
        var all: [String] { lock.withLock { steps } }
    }

    final class Rooms: WorkspaceChat, @unchecked Sendable {
        let trace: Trace
        let participants: FakeBotChat
        let lock = NSLock()
        var ready: WorkspaceChatReadiness = .ready
        var roomSet: Set<String> = []
        var members: [String: Set<String>] = [:]
        var failInvite = false
        init(_ t: Trace, _ p: FakeBotChat) { trace = t; participants = p }
        func readiness() async -> WorkspaceChatReadiness { lock.withLock { ready } }
        func rooms() throws -> Set<String> { lock.withLock { roomSet } }
        func makeRoom(_ name: String) throws { lock.withLock { _ = roomSet.insert(name) } }
        func post(room: String, content: String) throws { trace.add("post \(room)") }
        func invite(room: String, name: String) throws -> Bool {
            if lock.withLock({ failInvite }) { throw HostError(.failed, "the chat server is gone") }
            let there = (try? participants.directory().has(name)) == true
            let new = lock.withLock { members[room, default: []].insert(name).inserted }
            if new { trace.add("invite \(name) \(room)\(there ? "" : " (no participant!)")") }
            return new
        }
    }

    final class Managers: ManagerLauncher, @unchecked Sendable {
        let lock = NSLock()
        var places: [String: ManagerPlaceInfo] = [:]
        var delay: Duration = .zero
        func info(isolation: ManagerIsolation, place: String) async -> ManagerPlaceInfo { lock.withLock { places[place] ?? ManagerPlaceInfo() } }
        func launch(_ o: ManagerLaunchOrder) async throws -> [String] {
            if delay != .zero { try await Task.sleep(for: delay) }
            lock.withLock { places[o.place] = ManagerPlaceInfo(exists: true, running: true, heldBy: o.plan.secret?.bot) }
            return []
        }
        func stop(isolation: ManagerIsolation, place: String) async throws { lock.withLock { places[place]?.running = false } }
    }

    final class Workers: WorkerLauncher, @unchecked Sendable {
        let trace: Trace
        let lock = NSLock()
        var places: [String: ManagerPlaceInfo] = [:]
        var sandboxes: [String: WorkerSandboxInfo] = [:]
        var orders: [WorkerLaunchOrder] = []
        var ends: [WorkerEndOrder] = []
        var failLaunch = false
        /// What the launch saw: the record's entry pending, the participant, the token's item.
        var seen: (() -> String)?
        init(_ t: Trace) { trace = t }
        func info(isolation: ManagerIsolation, place: String) async -> ManagerPlaceInfo { lock.withLock { places[place] ?? ManagerPlaceInfo() } }
        func sandbox(_ name: String) async -> WorkerSandboxInfo? { lock.withLock { sandboxes[name] } }
        func launch(_ o: WorkerLaunchOrder) async throws -> [String] {
            let saw = lock.withLock { seen }?() ?? ""
            trace.add("launch \(o.place)\(saw)")
            if lock.withLock({ failLaunch }) { throw HostError(.failed, "the holder did not start") }
            lock.withLock {
                orders.append(o)
                if !o.shared { places[o.place] = ManagerPlaceInfo(exists: true, running: true, heldBy: o.plan.secret?.bot) }
            }
            return []
        }
        func end(_ o: WorkerEndOrder) async throws -> [String] {
            lock.withLock {
                ends.append(o)
                places[o.place]?.running = false
                if o.rm { places[o.place] = nil }
            }
            trace.add("end \(o.place)")
            return []
        }
    }

    var trace: Trace!
    var rooms: Rooms!
    var managers: Managers!
    var workers: Workers!
    var work: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        trace = Trace()
        rooms = Rooms(trace, chat)
        managers = Managers()
        workers = Workers(trace)
        work = root.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        work = URL(fileURLWithPath: WorkspaceStore.resolved(work.path))
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

    func wcore(readOnly: Bool = false) async -> HostCore {
        let c = await core(readOnly: readOnly)
        await c.setWorkspaceChat(rooms)
        await c.setManagerLauncher(managers)
        await c.setWorkerLauncher(workers)
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

    @discardableResult
    func wk(_ c: HostCore, _ op: HostOp, _ workspace: String?, _ name: String? = nil, _ edit: (inout WorkerRequest) -> Void = { _ in }) async -> HostMessage {
        var q = WorkerRequest(workspace: workspace, name: name)
        if op == .workerAdd { q.task = "list the files" }
        edit(&q)
        var r = HostRequest(op)
        r.workerRequest = q
        return await c.handle(r)
    }

    func added(_ m: HostMessage, file: StaticString = #filePath, line: UInt = #line) throws -> WorkerAdded {
        XCTAssertNil(m.error, m.error?.message ?? "", file: file, line: line)
        return try XCTUnwrap(m.result, file: file, line: line).decode(WorkerAdded.self)
    }

    /// A workspace, started (no manager unless given: you drive).
    func started(_ c: HostCore, _ name: String = "demo", manager: String? = nil, managerIsolation: String? = nil) async throws {
        let m = await ws(c, .workspaceNew, name) {
            $0.brief = "Make the launch video.\n"
            $0.folders = [WorkspaceFolder(path: self.work.path)]
            $0.manager = manager
            $0.managerIsolation = managerIsolation
        }
        XCTAssertNil(m.error, m.error?.message ?? "")
        let s = await ws(c, .workspaceStart, name)
        XCTAssertNil(s.error, s.error?.message ?? "")
    }

    func newBot(_ c: HostCore, _ name: String, isolation: String = "fenced", deliver: String = "poll", agent: String = "claude-code") async throws {
        _ = try change(await ask(c, .botNew, name) { $0.agent = agent; $0.isolation = isolation; $0.deliver = deliver })
    }

    func record(_ n: String) throws -> WorkspaceRecord? { try WorkspaceStore(store: store).read(n) }
    func text(_ n: String, _ file: String) -> String {
        (try? String(contentsOfFile: WorkspaceStore(store: store).folder(n) + "/" + file, encoding: .utf8)) ?? ""
    }
    func itemOf(_ owner: String, _ v: String = "CHAT_TOKEN") -> String? {
        keychain.read(service: LaunchSecrets.service(store: store.root, owner: owner, variable: v), account: nil).value
    }

    // MARK: add

    func testTheOrderAndTheRecord() async throws {
        let c = await wcore()
        try await started(c)
        trace.steps = []
        workers.seen = { [unowned self] in
            let pending = (try? self.record("demo"))?.agents.first { $0.name == "bot1" }?.pendingAt != nil
            let inChat = self.chat.hashes["bot1"] != nil
            let item = self.itemOf("mac.demo-bot1") != nil
            return " (pending \(pending), participant \(inChat), item \(item))"
        }
        let a = try added(await wk(c, .workerAdd, "demo"))
        XCTAssertEqual(a.worker.name, "bot1")
        XCTAssertEqual(a.worker.isolation, "fenced")
        XCTAssertEqual(a.worker.control, "proxy · placeholders · guard")
        XCTAssertEqual(a.worker.network, "—", "the fake opened nothing; the network is read from the session")
        XCTAssertEqual(a.session, "demo-bot1")
        XCTAssertEqual(trace.all, ["invite bot1 demo", "launch demo-bot1 (pending true, participant true, item true)"],
                       "check → pending → participant → invite → secret → launch")
        let o = try XCTUnwrap(workers.orders.first)
        XCTAssertEqual(o.isolation, .fenced)
        XCTAssertEqual(o.workdir, work.path)
        XCTAssertEqual(o.permissions, "locked")
        let list = Array(o.plan.argv.suffix(from: try XCTUnwrap(o.plan.argv.firstIndex(of: "--allowedTools")) + 1))
        XCTAssertEqual(list.first, "Bash(dozchat:*)")
        XCTAssertTrue(list.contains { $0.hasPrefix("Read(//") && $0.hasSuffix("/etc/worker/start.md)") }, "its START's Read rule: \(list)")
        XCTAssertTrue(list.dropFirst().allSatisfy { $0.hasPrefix("Read(//") }, "nothing but exact Read rules after dozchat")
        XCTAssertTrue(o.plan.argv.contains("dontAsk"))
        let s = try XCTUnwrap(o.plan.secret)
        XCTAssertNil(s.bot)
        XCTAssertEqual(s.keychainService, LaunchSecrets.service(store: store.root, owner: "mac.demo-bot1", variable: "CHAT_TOKEN"))
        let token = try XCTUnwrap(itemOf("mac.demo-bot1"))
        XCTAssertEqual(chat.hashes["bot1"], ChatSecrets.hash(token), "the participant's token is the one held")
        XCTAssertEqual(chat.dir.participants.first { $0.name == "bot1" }?.delivery, "poll")
        let startText = String(decoding: o.start, as: UTF8.self)
        XCTAssertTrue(startText.hasPrefix("You are bot1, a worker in the workspace demo. Your task: list the files\nYour room in chat: demo\n"))
        let rec = try XCTUnwrap(record("demo"))
        let e = try XCTUnwrap(rec.agents.first { $0.name == "bot1" })
        XCTAssertNil(e.pendingAt)
        XCTAssertEqual(e.task, "list the files")
        XCTAssertEqual(e.anonymous, true)
        XCTAssertEqual(e.place, .macSession("demo-bot1"))
        XCTAssertEqual(try WorkspaceStore(store: store).log("demo").map(\.action).suffix(3), ["bot-invited", "agent-joined", "worker-added"])
        for (what, t) in [("the record", text("demo", "workspace.json")), ("the log", text("demo", "log.jsonl")), ("argv", o.plan.argv.joined()),
                          ("env", o.plan.environment.values.joined()), ("START", startText), ("the answer", encoded(await wk(c, .workerList, "demo"))),
                          ("events", events.text)] {
            XCTAssertFalse(t.contains("dzc_") || t.contains(token), "no token in \(what)")
        }
        XCTAssertTrue(text("demo", "log.jsonl").contains(BotTokens.fingerprint(token)))
        XCTAssertEqual(LaunchSecretLedger.load(store).items.values.filter { $0 == "mac.demo-bot1" }.count, 1, "one ledger line")
        // ls: every agent; the state is derived.
        let m1x = await wk(c, .workerList, "demo")
        let l = try XCTUnwrap(m1x.result).decode(WorkerListing.self)
        XCTAssertEqual(l.agents.map(\.name), ["bot1"])
        XCTAssertEqual(l.agents.first?.task, "list the files")
        // The next anonymous worker: bot2.
        let m2x = await wk(c, .workerAdd, "demo")
        XCTAssertEqual(try added(m2x).worker.name, "bot2")
    }

    func testEachFailureUndoesTheEarlierSteps() async throws {
        let c = await wcore()
        try await started(c)
        func clean(_ why: String) throws {
            XCTAssertNil(try record("demo")?.agents.first { $0.name == "bot1" }, "\(why): no entry")
            XCTAssertNil(chat.hashes["bot1"], "\(why): no participant")
            XCTAssertNil(itemOf("mac.demo-bot1"), "\(why): no item")
            XCTAssertFalse(LaunchSecretLedger.load(store).items.values.contains("mac.demo-bot1"), "\(why): no ledger line")
        }
        workers.failLaunch = true
        var m = await wk(c, .workerAdd, "demo")
        XCTAssertTrue(m.error?.message.contains("bot1 did not start: the holder did not start") == true, m.error?.message ?? "")
        try clean("a launch failure")
        workers.failLaunch = false
        rooms.failInvite = true
        m = await wk(c, .workerAdd, "demo")
        XCTAssertNotNil(m.error)
        try clean("an invite failure")
        rooms.failInvite = false
        chat.failing = ["add"]
        m = await wk(c, .workerAdd, "demo")
        XCTAssertNotNil(m.error)
        chat.failing = []
        try clean("a participant failure")
        XCTAssertEqual(workers.orders.count, 0)
        let m3x = await wk(c, .workerAdd, "demo")
        XCTAssertEqual(try added(m3x).worker.name, "bot1", "the name was never taken")
    }

    func testRefusals() async throws {
        let c = await wcore()
        // Setting up: refused, nothing made.
        let n = await ws(c, .workspaceNew, "demo") { $0.brief = "B"; $0.folders = [WorkspaceFolder(path: self.work.path)] }
        XCTAssertNil(n.error)
        var m = await wk(c, .workerAdd, "demo")
        XCTAssertEqual(m.error?.message, "demo is still setting up — doz workspace start demo first (a workspace with no manager starts with you driving), or declare workers at doz workspace new --worker TASK")
        XCTAssertTrue(chat.dir.participants.isEmpty && trace.all.isEmpty)
        XCTAssertEqual(try record("demo")?.agents.count, 0)
        _ = await ws(c, .workspaceStart, "demo")
        // Unknown workspace; chat off; no task.
        m = await wk(c, .workerAdd, "nosuch")
        XCTAssertEqual(m.error?.code, .notFound)
        rooms.ready = .off
        m = await wk(c, .workerAdd, "demo")
        XCTAssertEqual(m.error?.message, "a worker needs chat — doz chat on")
        rooms.ready = .ready
        m = await wk(c, .workerAdd, "demo") { $0.task = "  " }
        XCTAssertEqual(m.error?.code, .invalid)
        // Taken names: a participant, a bot, a retired bot, you.
        chat.plant("pat", token: "pat-token-0123456789")
        try await newBot(c, "otto")
        try await newBot(c, "gone")
        _ = try change(await ask(c, .botRetire, "gone"))
        for (name, code, words) in [("pat", HostError.Code.exists, "already in chat"), ("otto", .exists, "--from-bot otto"), ("gone", .exists, "retired"),
                                    ("ada", .invalid, "you in chat"), ("Bad", .invalid, "not a name in chat")] {
            m = await wk(c, .workerAdd, "demo", name)
            XCTAssertEqual(m.error?.code, code, name)
            XCTAssertTrue(m.error?.message.contains(words) == true, "\(name): \(m.error?.message ?? "")")
        }
        // Bots: unknown, retired, elsewhere, a fenced inbox bot, a webhook bot.
        _ = try change(await ask(c, .botNew, "far") { $0.agent = "codex"; $0.isolation = "elsewhere" })
        try await newBot(c, "inby", deliver: "inbox")
        for (bot, words) in [("nosuch", "is not a bot"), ("gone", "retired"), ("far", "Dozable never starts it"),
                             ("inby", "doz bot set inby --deliver poll")] {
            m = await wk(c, .workerAdd, "demo") { $0.fromBot = bot }
            XCTAssertTrue(m.error?.message.contains(words) == true, "\(bot): \(m.error?.message ?? "")")
        }
        // Flags.
        m = await wk(c, .workerAdd, "demo") { $0.cpus = 2 }
        XCTAssertTrue(m.error?.message.contains("--cpus and --memory go with --isolation sandbox") == true, m.error?.message ?? "")
        m = await wk(c, .workerAdd, "demo") { $0.sandbox = "x"; $0.isolation = "vm" }
        XCTAssertTrue(m.error?.message.contains("--sandbox or --isolation") == true, m.error?.message ?? "")
        m = await wk(c, .workerAdd, "demo", "carl") { $0.fromBot = "otto" }
        XCTAssertTrue(m.error?.message.contains("takes the bot's name") == true, m.error?.message ?? "")
        m = await wk(c, .workerAdd, "demo") { $0.agent = "pi" }
        XCTAssertTrue(m.error?.message.contains("Claude Code or Codex") == true, m.error?.message ?? "")
        XCTAssertEqual(workers.orders.count, 0, "nothing launched")
        XCTAssertEqual(try record("demo")?.agents.count, 0, "nothing written")
        // Finished.
        var rec = try XCTUnwrap(record("demo"))
        rec.flags.finishedAt = Date()
        try WorkspaceStore(store: store).write(rec)
        m = await wk(c, .workerAdd, "demo")
        XCTAssertEqual(m.error?.message, "demo is finished")
    }

    func testTheSandboxRefusals() async throws {
        let c = await wcore()
        var r = HostRequest(.create, name: "wsa")
        r.create = CreateOptions(image: "lab")
        let m4x = await c.handle(r)
        XCTAssertNil(m4x.error)
        r = HostRequest(.create, name: "loose")
        r.create = CreateOptions(image: "lab")
        let m5x = await c.handle(r)
        XCTAssertNil(m5x.error)
        try await newBot(c, "vera", isolation: "vm")
        try await started(c, manager: "vera", managerIsolation: "vm")
        let m6x = await ws(c, .workspaceAdopt, "demo") { $0.agent = "wsa" }
        XCTAssertNil(m6x.error)
        let port = UInt16(ChatSettingsView.read().pagePort)
        var m = await wk(c, .workerAdd, "demo") { $0.sandbox = "loose" }
        XCTAssertTrue(m.error?.message.contains("loose is not a sandbox of demo") == true, m.error?.message ?? "")
        m = await wk(c, .workerAdd, "demo") { $0.sandbox = "demo" }
        XCTAssertEqual(m.error?.message, "demo is the manager's sandbox — a worker never shares it")
        workers.sandboxes["wsa"] = WorkerSandboxInfo(running: false)
        m = await wk(c, .workerAdd, "demo") { $0.sandbox = "wsa" }
        XCTAssertEqual(m.error?.message, "wsa is stopped — doz start wsa")
        workers.sandboxes["wsa"] = WorkerSandboxInfo(running: true, hostPorts: [])
        m = await wk(c, .workerAdd, "demo") { $0.sandbox = "wsa" }
        XCTAssertTrue(m.error?.message.contains("doz net allow wsa host:\(port)") == true, m.error?.message ?? "")
        workers.sandboxes["wsa"] = WorkerSandboxInfo(running: true, hostPorts: [port], variables: ["A", "B", "C", "D"])
        m = await wk(c, .workerAdd, "demo") { $0.sandbox = "wsa" }
        XCTAssertTrue(m.error?.message.contains("holds 4 secrets already") == true, m.error?.message ?? "")
        XCTAssertEqual(workers.orders.count, 0)
        // Running, its port open, room for one more: it joins, with its own variables, aliased for its session.
        workers.sandboxes["wsa"] = WorkerSandboxInfo(running: true, hostPorts: [port], variables: ["A"])
        let a = try added(await wk(c, .workerAdd, "demo", "v2") { $0.sandbox = "wsa" })
        XCTAssertEqual(a.worker.shares, "wsa")
        XCTAssertTrue(a.worker.control.hasSuffix("· shares wsa"))
        let o = try XCTUnwrap(workers.orders.last)
        XCTAssertTrue(o.shared)
        XCTAssertEqual(o.session, "v2")
        XCTAssertEqual(o.plan.secret?.variable, "CHAT_TOKEN_V2")
        XCTAssertEqual(o.plan.secret?.fileVariable, "CHAT_TOKEN_FILE_V2")
        XCTAssertNotNil(itemOf("wsa", "CHAT_TOKEN_V2"))
        XCTAssertTrue(a.notes?.contains { $0.contains("workers there can read each other's placeholders") } == true)
        // Ending it ends only its session; --rm is refused for a shared place.
        m = await wk(c, .workerEnd, "demo", "v2") { $0.rm = true }
        XCTAssertTrue(m.error?.message.contains("which it shares") == true, m.error?.message ?? "")
        let m7x = await wk(c, .workerEnd, "demo", "v2")
        XCTAssertNil(m7x.error)
        XCTAssertEqual(workers.ends.last?.shared, true)
        XCTAssertEqual(workers.ends.last?.variable, "CHAT_TOKEN_V2")
        XCTAssertNil(itemOf("wsa", "CHAT_TOKEN_V2"), "its secret revoked")
    }

    // MARK: end

    func testEnd() async throws {
        let c = await wcore()
        try await started(c)
        try await newBot(c, "otto")
        _ = try added(await wk(c, .workerAdd, "demo"))
        _ = try added(await wk(c, .workerAdd, "demo") { $0.fromBot = "otto" })
        let ottoToken = try XCTUnwrap(item("otto"))
        XCTAssertEqual(workers.orders.last?.plan.secret?.bot, "otto")
        // Unknown, the manager's, an adopted agent's.
        var m = await wk(c, .workerEnd, "demo", "nobody")
        XCTAssertEqual(m.error?.code, .notFound)
        // Releasing a live worker is refused.
        m = await ws(c, .workspaceRelease, "demo") { $0.agent = "bot1" }
        XCTAssertTrue(m.error?.message.contains("doz worker end demo bot1") == true, m.error?.message ?? "")
        // An anonymous one: its participant and item gone; its token refused (the fake has no hash for it).
        m = await wk(c, .workerEnd, "demo", "bot1")
        XCTAssertNil(m.error, m.error?.message ?? "")
        XCTAssertNil(chat.hashes["bot1"], "its token is refused")
        XCTAssertFalse(chat.dir.participants.contains { $0.name == "bot1" })
        XCTAssertNil(itemOf("mac.demo-bot1"), "its item is gone")
        XCTAssertFalse(LaunchSecretLedger.load(store).items.values.contains("mac.demo-bot1"))
        let rec = try XCTUnwrap(record("demo"))
        XCTAssertNotNil(rec.agents.first { $0.name == "bot1" }?.endedAt, "ended, its entry kept")
        XCTAssertEqual(try WorkspaceStore(store: store).log("demo").last?.action, "worker-ended")
        m = await wk(c, .workerEnd, "demo", "bot1")
        XCTAssertEqual(m.error?.message, "bot1 has ended already")
        // ls leaves it out unless --all.
        let m8x = await wk(c, .workerList, "demo")
        var l = try XCTUnwrap(m8x.result).decode(WorkerListing.self)
        XCTAssertEqual(l.agents.map(\.name), ["otto"])
        let m9x = await wk(c, .workerList, "demo") { $0.all = true }
        l = try XCTUnwrap(m9x.result).decode(WorkerListing.self)
        XCTAssertEqual(l.agents.first { $0.name == "bot1" }?.state, "ended")
        // A bot's: its token held, it stays in chat; bot ls says where it works until then.
        let m10x = await ask(c, .botList, "")
        var bl = try XCTUnwrap(m10x.result).decode(BotListing.self)
        XCTAssertEqual(bl.bots.first { $0.name == "otto" }?.worksIn, "demo")
        m = await wk(c, .workerEnd, "demo", "otto") { $0.rm = true }
        XCTAssertNil(m.error, m.error?.message ?? "")
        XCTAssertEqual(item("otto"), ottoToken, "a bot's token is kept")
        XCTAssertNotNil(chat.hashes["otto"])
        XCTAssertEqual(workers.ends.last?.rm, true)
        let m11x = await ask(c, .botList, "")
        bl = try XCTUnwrap(m11x.result).decode(BotListing.self)
        XCTAssertNil(bl.bots.first { $0.name == "otto" }?.worksIn)
        // The name is free again.
        let m12x = await wk(c, .workerAdd, "demo")
        XCTAssertEqual(try added(m12x).worker.name, "bot1")
        XCTAssertEqual(try record("demo")?.agents.filter { $0.name == "bot1" }.count, 1, "the ended entry is replaced")
        // The read-only core refuses add and end, and answers ls.
        let ro = await wcore(readOnly: true)
        let m13x = await wk(ro, .workerAdd, "demo")
        XCTAssertEqual(m13x.error?.code, .unavailable)
        let m14x = await wk(ro, .workerEnd, "demo", "bot1")
        XCTAssertEqual(m14x.error?.code, .unavailable)
        let m15x = await wk(ro, .workerList, "demo")
        XCTAssertNil(m15x.error)
        XCTAssertTrue(HostOp.workerList.isReadOnly)
        XCTAssertFalse(HostOp.workerAdd.isReadOnly)
    }

    // MARK: the dashboard's additive fields

    /// `working` and `activity` (the dashboard's Home): known only to a daemon core — from what it holds, never a guest call —
    /// and absent in-process; `folders` in both. The text of `ls` is unchanged (the CLI prints neither).
    func testTheDashboardFields() async throws {
        let c = await wcore()
        try await started(c)
        _ = try added(await wk(c, .workerAdd, "demo"))
        let m1 = await ws(c, .workspaceList, nil)
        let live = try XCTUnwrap(m1.result).decode(WorkspaceListing.self)
        let row = try XCTUnwrap(live.workspaces.first)
        XCTAssertEqual(row.working, [], "a daemon knows: nobody working (the fake's session has no holder)")
        XCTAssertEqual(row.folders, [work.path])
        let m2 = await ws(c, .workspaceShow, "demo")
        let shown = try XCTUnwrap(m2.result).decode(WorkspaceDetail.self)
        XCTAssertNil(shown.agents.first { $0.name == "bot1" }?.activity, "not running: no activity")
        let ro = await wcore(readOnly: true)
        let m3 = await ws(ro, .workspaceList, nil)
        let off = try XCTUnwrap(m3.result).decode(WorkspaceListing.self)
        XCTAssertNil(off.workspaces.first?.working, "in-process: not known")
        XCTAssertEqual(off.workspaces.first?.folders, [work.path])
        XCTAssertEqual(WorkspaceState.activity(.running(sessions: ["working"])), "working")
    }

    // MARK: one live workspace per bot

    func testOneLiveWorkspaceBothWays() async throws {
        let c = await wcore()
        try await newBot(c, "otto")
        try await newBot(c, "mira")
        try await started(c, "wk")
        _ = try added(await wk(c, .workerAdd, "wk") { $0.fromBot = "otto" })
        // otto works in wk: managing w2 is refused with the sentence, and working in w3 too.
        let n = await ws(c, .workspaceNew, "w2") { $0.brief = "B"; $0.folders = [WorkspaceFolder(path: self.work.path)]; $0.manager = "otto" }
        XCTAssertNil(n.error)
        let sentence = "otto already works in wk, which is running. For now a bot runs in one live workspace at a time — doz worker end wk otto first."
        var m = await ws(c, .workspaceStart, "w2")
        XCTAssertEqual(m.error?.message, sentence)
        try await started(c, "w3")
        m = await wk(c, .workerAdd, "w3") { $0.fromBot = "otto" }
        XCTAssertEqual(m.error?.message, sentence)
        // mira manages w4 (running): working in w3 is refused with the manager's sentence; nor is she a worker of w4.
        try await started(c, "w4", manager: "mira")
        m = await wk(c, .workerAdd, "w3") { $0.fromBot = "mira" }
        XCTAssertEqual(m.error?.message, "mira already manages w4, which is running. For now a bot runs in one live workspace at a time — doz workspace stop w4 first.")
        m = await wk(c, .workerAdd, "w4") { $0.fromBot = "mira" }
        XCTAssertEqual(m.error?.message, "mira is w4's manager — a bot plays one role in a workspace")
        // otto's end frees him.
        let m16x = await wk(c, .workerEnd, "wk", "otto")
        XCTAssertNil(m16x.error)
        m = await ws(c, .workspaceStart, "w2")
        XCTAssertNil(m.error, m.error?.message ?? "")
    }

    func testAStartInProgressIsRefused() async throws {
        let c = await wcore()
        try await newBot(c, "mira")
        let n = await ws(c, .workspaceNew, "slow") { $0.brief = "B"; $0.folders = [WorkspaceFolder(path: self.work.path)]; $0.manager = "mira" }
        XCTAssertNil(n.error)
        _ = await ws(c, .workspaceStart, "slow")
        _ = await ws(c, .workspaceStop, "slow") { $0.managerOnly = true }
        managers.places["slow"]?.running = false
        managers.delay = .milliseconds(400)
        var r = HostRequest(.workspaceStart)
        r.workspaceRequest = WorkspaceRequest(name: "slow")
        let req = r
        let t = Task { await c.handle(req) }
        try await Task.sleep(for: .milliseconds(150))
        let m = await wk(c, .workerAdd, "slow")
        XCTAssertEqual(m.error?.message, "slow is starting — add the worker once its start is over")
        _ = await t.value
    }

    // MARK: the sweep

    func testTheSweepUndoesAPendingWorker() async throws {
        let c = await wcore()
        try await started(c)
        _ = try added(await wk(c, .workerAdd, "demo"))
        // Make it look as a daemon that died mid-add left it: pending, its place not running.
        var rec = try XCTUnwrap(record("demo"))
        let i = try XCTUnwrap(rec.agents.firstIndex { $0.name == "bot1" })
        rec.agents[i].pendingAt = Date()
        try WorkspaceStore(store: store).write(rec)
        workers.places["demo-bot1"]?.running = false
        // A second one, pending but running: only its mark goes.
        _ = try added(await wk(c, .workerAdd, "demo"))
        rec = try XCTUnwrap(record("demo"))
        let j = try XCTUnwrap(rec.agents.firstIndex { $0.name == "bot2" })
        rec.agents[j].pendingAt = Date()
        try WorkspaceStore(store: store).write(rec)
        await c.sweepPendingWorkers()
        rec = try XCTUnwrap(record("demo"))
        XCTAssertNil(rec.agents.first { $0.name == "bot1" }, "undone")
        XCTAssertNil(chat.hashes["bot1"], "its participant removed")
        XCTAssertEqual(try WorkspaceStore(store: store).log("demo").last?.action, "worker-add-undone")
        XCTAssertNil(rec.agents.first { $0.name == "bot2" }?.pendingAt, "running: no longer pending")
        XCTAssertNotNil(chat.hashes["bot2"])
    }
}
