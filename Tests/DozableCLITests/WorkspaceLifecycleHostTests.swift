import DozableChat
import Foundation
import XCTest
@testable import DozableKit
@testable import DozableHost

/// The lifecycle verbs in an in-process daemon core (scratch store, a fresh memory keychain, fakes for the rooms, the
/// participants, the launchers and the agents' places — nothing opened, no VM, never the real Bin): the run order; `ifPlan`
/// (changed since you looked: nothing done); a partial failure (no flag, the rows say why, a retry finishes); archive retires
/// only anonymous workers and restore opens exactly the rooms it archived; delete refuses while anything runs, releases
/// adopted agents loose and touches no folder without its flag (the Bin's seam); the typed name and the "acts as you"
/// confirmation the dashboard requires; a read-only core plans every verb and does none; a plan reads no keychain.
final class WorkspaceLifecycleHostTests: BotTestCase {
    typealias F = WorkspaceLifecycle.AgentFacts

    final class Trace: @unchecked Sendable {
        let lock = NSLock()
        var steps: [String] = []
        func add(_ s: String) { lock.withLock { steps.append(s) } }
        var all: [String] { lock.withLock { steps } }
        func reset() { lock.withLock { steps = [] } }
    }

    final class Rooms: WorkspaceChat, @unchecked Sendable {
        let trace: Trace
        let lock = NSLock()
        var ready: WorkspaceChatReadiness = .ready
        var roomSet: Set<String> = []
        var archived: Set<String> = []
        init(_ t: Trace) { trace = t }
        func readiness() async -> WorkspaceChatReadiness { lock.withLock { ready } }
        func rooms() throws -> Set<String> { lock.withLock { roomSet } }
        func makeRoom(_ name: String) throws { lock.withLock { _ = roomSet.insert(name) } }
        var seqs: [String: Int64] = [:]
        var closedSets: [[String: String]] = []
        var removed: [(room: String, id: String, lastSeq: Int64)] = []
        var msgs: [String: [JValue]] = [:]
        func add(_ room: String, from: String, _ content: String) {
            lock.withLock {
                seqs[room, default: 0] += 1
                msgs[room, default: []].append(.map(["seq": .int(seqs[room]!), "from": .string(from), "content": .string(content),
                                                     "at": .double(Date().timeIntervalSince1970)]))
            }
        }
        func post(room: String, content: String) throws {
            trace.add("post \(room)")
            add(room, from: "ada", content)
        }
        func fetch(_ target: String) throws -> (status: Int, body: Data) {
            if target == "/api/state" { return (200, Data(#"{"participants":[{"name":"ada","kind":"human"}],"rooms":{}}"#.utf8)) }
            let room = String(target.dropFirst("/api/rooms/".count).prefix { $0 != "/" })
            let q = URLComponents(string: "http://x" + target)!.queryItems ?? []
            let before = Int64(q.first { $0.name == "before" }?.value ?? "0") ?? 0
            let limit = Int(q.first { $0.name == "limit" }?.value ?? "500") ?? 500
            let all = lock.withLock { msgs[room] ?? [] }.filter { m in before == 0 || ((try? m.field("seq")?.goInt("seq")) ?? 0)! < before }
            return (200, Data(ChatJSON.encode(.array(Array(all.suffix(limit))))))
        }
        func lastSeq(room: String) throws -> Int64 { lock.withLock { seqs[room] ?? 0 } }
        func archivedRooms() throws -> Set<String> { lock.withLock { archived } }
        func setClosed(_ rooms: [String: String]) async throws -> [String: Int64]? {
            lock.withLock {
                closedSets.append(rooms)
                var out: [String: Int64] = [:]
                for r in rooms.keys { out[r] = seqs[r] ?? 0 }
                return out
            }
        }
        /// Someone else posted (a worker): the room's seq moves.
        func otherPost(_ room: String, _ content: String = "from bot1") { add(room, from: "bot1", content) }
        func invite(room: String, name: String) throws -> Bool { true }
        func setArchived(room: String, _ on: Bool) throws -> Bool {
            let changed = lock.withLock { on ? archived.insert(room).inserted : archived.remove(room) != nil }
            if changed { trace.add((on ? "archive " : "unarchive ") + room) }
            return changed
        }
    }

    final class Managers: ManagerLauncher, @unchecked Sendable {
        let trace: Trace
        let lock = NSLock()
        var places: [String: ManagerPlaceInfo] = [:]
        var restarts = 0
        init(_ t: Trace) { trace = t }
        func info(isolation: ManagerIsolation, place: String) async -> ManagerPlaceInfo { lock.withLock { places[place] ?? ManagerPlaceInfo() } }
        func launch(_ o: ManagerLaunchOrder) async throws -> [String] {
            trace.add("manager \(o.place)\(o.restart ? " (again)" : "")")
            lock.withLock {
                if o.restart { restarts += 1 }
                places[o.place] = ManagerPlaceInfo(exists: true, running: true, heldBy: o.plan.secret?.bot)
            }
            return []
        }
        func stop(isolation: ManagerIsolation, place: String) async throws { lock.withLock { places[place]?.running = false } }
        func down(_ place: String) { lock.withLock { places[place]?.running = false } }
    }

    final class Workers: WorkerLauncher, @unchecked Sendable {
        let trace: Trace
        let lock = NSLock()
        var places: [String: ManagerPlaceInfo] = [:]
        var orders: [WorkerLaunchOrder] = []
        init(_ t: Trace) { trace = t }
        func info(isolation: ManagerIsolation, place: String) async -> ManagerPlaceInfo { lock.withLock { places[place] ?? ManagerPlaceInfo() } }
        func sandbox(_ name: String) async -> WorkerSandboxInfo? { nil }
        func launch(_ o: WorkerLaunchOrder) async throws -> [String] {
            trace.add("worker \(o.place)\(o.restart ? " (again)" : "")")
            lock.withLock {
                orders.append(o)
                places[o.place] = ManagerPlaceInfo(exists: true, running: true, heldBy: o.plan.secret?.bot)
            }
            return []
        }
        func end(_ o: WorkerEndOrder) async throws -> [String] { lock.withLock { places[o.place]?.running = false }; return [] }
        func down(_ place: String) { lock.withLock { places[place]?.running = false } }
    }

    /// The agents' places as the plan sees them: a manager's and a worker's from their launchers, an adopted one's as the
    /// test says; every change recorded, and failing where the test says.
    final class Places: WorkspaceAgentLifecycle, @unchecked Sendable {
        let trace: Trace
        let managers: Managers
        let workers: Workers
        let lock = NSLock()
        var now: [String: F.Now] = [:]
        var fail: Set<String> = []
        init(_ t: Trace, _ m: Managers, _ w: Workers) { trace = t; managers = m; workers = w }
        func facts(_ a: WorkspaceAgent, workspace: String) async -> F {
            guard let key = a.place.key else { return F(now: .elsewhere) }
            let vm = a.place.sandbox != nil
            let place = a.place.sandbox ?? a.place.session ?? ""
            let fenced: Bool? = vm ? nil : a.isolation.map { $0 != "unfenced" } ?? false
            let info = a.isManager ? await managers.info(isolation: .fenced, place: place) : a.isWorker ? await workers.info(isolation: .fenced, place: place) : nil
            if info?.running == true { return F(now: .running, activity: "idle", fenced: fenced, resumable: true, memoryMiB: vm ? 2048 : nil, secretKept: true) }
            if let n = lock.withLock({ now[key] }) { return F(now: n, fenced: fenced, resumable: a.isManager || a.isWorker, memoryMiB: vm ? 2048 : nil, secretKept: true) }
            if info?.exists == true { return F(now: vm ? .off : .ended, fenced: fenced, resumable: true, secretKept: true) }
            return F(now: a.isManager ? .notStarted : .gone)
        }
        private func change(_ verb: String, _ o: AgentLifecycleOrder, to n: F.Now) throws {
            let place = o.sandbox ?? o.session ?? ""
            let what = "\(verb) \(place)"
            if lock.withLock({ fail.contains(what) }) {
                lock.withLock { _ = fail.remove(what) }
                throw HostError(.failed, "\(place) did not \(verb)")
            }
            trace.add(what)
            managers.down(place)
            workers.down(place)
            lock.withLock { now[(o.sandbox != nil ? "sandbox:" : "mac:") + place] = n }
        }
        func sleep(_ o: AgentLifecycleOrder) async throws -> [String] { try change("sleep", o, to: o.sandbox != nil ? .asleep : .ended); return [] }
        func wake(_ o: AgentLifecycleOrder) async throws -> [String] { try change("wake", o, to: .running); return [] }
        func shutdown(_ o: AgentLifecycleOrder) async throws -> [String] { try change("shutdown", o, to: o.sandbox != nil ? .off : .ended); return [] }
        func keepTemplate(sandbox: String, name: String) async throws { trace.add("template \(sandbox) as \(name)") }
        func removeSandbox(_ name: String) async throws {
            trace.add("rm \(name)")
            workers.lock.withLock { workers.places[name] = nil }
            lock.withLock { now["sandbox:" + name] = .gone }
        }
        func forgetSession(_ name: String) async throws { trace.add("forget \(name)") }
    }

    var trace: Trace!
    var rooms: Rooms!
    var managers: Managers!
    var workers: Workers!
    var places: Places!
    var work: URL!
    var bin: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        trace = Trace()
        rooms = Rooms(trace)
        managers = Managers(trace)
        workers = Workers(trace)
        places = Places(trace, managers, workers)
        work = root.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        work = URL(fileURLWithPath: WorkspaceStore.resolved(work.path))
        bin = root.appendingPathComponent("bin-of-this-test")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let tools = root.appendingPathComponent("tools")
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: tools.appendingPathComponent("claude").path, contents: Data("#!/bin/sh\n".utf8),
                                       attributes: [.posixPermissions: 0o755])
        let home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        setenv("DOZ_TEST_MAC_PATH", tools.path + ":/usr/bin:/bin", 1)
        setenv("DOZ_TEST_FENCE_HOME", home.path, 1)
        setenv("DOZ_TEST_TRASH_DIR", bin.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("DOZ_TEST_MAC_PATH")
        unsetenv("DOZ_TEST_FENCE_HOME")
        unsetenv("DOZ_TEST_TRASH_DIR")
        try super.tearDownWithError()
    }

    func lcore(readOnly: Bool = false) async -> HostCore {
        let c = await core(readOnly: readOnly)
        await c.setWorkspaceChat(rooms)
        await c.setManagerLauncher(managers)
        await c.setWorkerLauncher(workers)
        await c.setAgentLifecycle(places)
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

    func plan(_ c: HostCore, _ v: WorkspaceVerb, _ name: String = "demo", _ edit: (inout WorkspaceRequest) -> Void = { _ in }) async throws -> WorkspaceLifecyclePlan {
        let m = await ws(c, .workspaceLifecyclePlan, name) { $0.verb = v.rawValue; edit(&$0) }
        XCTAssertNil(m.error, m.error?.message ?? "")
        return try XCTUnwrap(m.result).decode(WorkspaceLifecyclePlan.self)
    }

    /// The verb acting on the plan just read (as the CLI and the page do).
    @discardableResult
    func act(_ c: HostCore, _ v: WorkspaceVerb, _ name: String = "demo", _ edit: @escaping (inout WorkspaceRequest) -> Void = { _ in }) async throws -> HostMessage {
        let p = try await plan(c, v, name, edit)
        return await ws(c, v.hostOp, name) { $0.ifPlan = p.sha; edit(&$0) }
    }

    func ok(_ m: HostMessage, file: StaticString = #filePath, line: UInt = #line) throws -> WorkspaceChanged {
        XCTAssertNil(m.error, m.error?.message ?? "", file: file, line: line)
        return try XCTUnwrap(m.result, file: file, line: line).decode(WorkspaceChanged.self)
    }

    func record(_ n: String = "demo") throws -> WorkspaceRecord? { try WorkspaceStore(store: store).read(n) }
    func log(_ n: String = "demo") -> [String] { ((try? WorkspaceStore(store: store).log(n)) ?? []).map(\.action) }

    /// demo, started: mira (fenced manager), bot1 (anonymous fenced worker), otto (a fenced worker from a bot).
    func started(_ c: HostCore) async throws {
        _ = try change(await ask(c, .botNew, "mira") { $0.agent = "claude-code"; $0.isolation = "fenced"; $0.deliver = "poll" })
        _ = try change(await ask(c, .botNew, "otto") { $0.agent = "claude-code"; $0.isolation = "fenced"; $0.deliver = "poll" })
        var m = await ws(c, .workspaceNew, "demo") {
            $0.brief = "Make the launch video.\n"
            $0.folders = [WorkspaceFolder(path: self.work.path)]
            $0.manager = "mira"
        }
        XCTAssertNil(m.error, m.error?.message ?? "")
        m = await ws(c, .workspaceStart, "demo")
        XCTAssertNil(m.error, m.error?.message ?? "")
        for q: (inout WorkerRequest) -> Void in [{ _ in }, { $0.fromBot = "otto" }] {
            var w = WorkerRequest(workspace: "demo")
            w.task = "list the files"
            q(&w)
            var r = HostRequest(.workerAdd)
            r.workerRequest = w
            let a = await c.handle(r)
            XCTAssertNil(a.error, a.error?.message ?? "")
        }
        trace.reset()
    }

    // MARK: the run order

    func testSleepWakeFinishReopen() async throws {
        let c = await lcore()
        try await started(c)
        let bot1Token = chat.hashes["bot1"]
        // Sleep: every place ended (its record kept), the records marked; nothing posted.
        let s = try ok(try await act(c, .sleep))
        XCTAssertEqual(Set(s.results.map(\.name)), ["mira", "bot1", "otto"])
        XCTAssertTrue(s.results.allSatisfy(\.ok))
        XCTAssertEqual(Set(trace.all), ["sleep demo", "sleep demo-bot1", "sleep demo-otto"])
        XCTAssertEqual(s.workspace?.state, "asleep")
        XCTAssertTrue(try XCTUnwrap(record()).agents.allSatisfy { $0.stoppedAt != nil })
        XCTAssertTrue(log().contains("slept") && log().filter { $0 == "agent-slept" }.count == 3)
        XCTAssertFalse(trace.all.contains { $0.hasPrefix("post") }, "nothing is posted by any verb")
        // Wake: the manager through its start's restart branch, each worker re-launched in place, the same token.
        trace.reset()
        let w = try ok(try await act(c, .wake))
        XCTAssertTrue(w.results.allSatisfy(\.ok), w.results.map(\.text).joined(separator: "; "))
        XCTAssertEqual(Set(trace.all), ["manager demo (again)", "worker demo-bot1 (again)", "worker demo-otto (again)"])
        XCTAssertTrue(workers.orders.suffix(2).allSatisfy(\.restart))
        let bot1 = try XCTUnwrap(workers.orders.last { $0.name == "bot1" })
        XCTAssertNil(bot1.plan.secret, "an anonymous fenced worker's secret is kept in its session's record: nothing new")
        XCTAssertEqual(workers.orders.last { $0.name == "otto" }?.plan.secret?.bot, "otto", "a bot's own token, given again")
        XCTAssertEqual(chat.hashes["bot1"], bot1Token, "the same token: its launch secret survived the sleep")
        XCTAssertTrue(try XCTUnwrap(record()).agents.allSatisfy { $0.stoppedAt == nil })
        XCTAssertEqual(managers.restarts, 1)
        // Finish: every place ended, the flag set; a worker's add is refused; the room stays writable (nothing archived).
        trace.reset()
        let f = try ok(try await act(c, .finish))
        XCTAssertEqual(f.workspace?.state, "finished")
        XCTAssertNotNil(try XCTUnwrap(record()).flags.finishedAt)
        XCTAssertTrue(rooms.archived.isEmpty)
        var add = HostRequest(.workerAdd)
        var q = WorkerRequest(workspace: "demo")
        q.task = "more"
        add.workerRequest = q
        let refused = await c.handle(add)
        XCTAssertEqual(refused.error?.code, .invalidPhase)
        // Reopen, then wake.
        let r = try ok(try await act(c, .reopen))
        XCTAssertNil(try XCTUnwrap(record()).flags.finishedAt)
        XCTAssertNotNil(try XCTUnwrap(record()).flags.reopenedAt)
        XCTAssertEqual(r.workspace?.state, "asleep")
        let again = try await act(c, .wake)
        XCTAssertTrue(try ok(again).results.allSatisfy(\.ok))
        XCTAssertEqual(log().suffix(1), ["woke"])
    }

    func testIfPlanMismatchIsAConflictAndNothingIsDone() async throws {
        let c = await lcore()
        try await started(c)
        let p = try await plan(c, .sleep)
        // Something changed between the look and the act: bot1 went to sleep by itself.
        workers.down("demo-bot1")
        let m = await ws(c, .workspaceSleep, "demo") { $0.ifPlan = p.sha }
        XCTAssertEqual(m.error?.code, .invalidPhase)
        XCTAssertTrue(m.error?.message.contains("changed since you looked") == true, m.error?.message ?? "")
        XCTAssertTrue(trace.all.isEmpty, "nothing done")
        XCTAssertFalse(log().contains("slept"))
        // The CLI's stop with an old plan too.
        let s = await ws(c, .workspaceStop, "demo") { $0.ifPlan = "0000000000000000" }
        XCTAssertTrue(s.error?.message.contains("changed since you looked") == true)
        XCTAssertEqual(managers.places["demo"]?.running, true)
    }

    func testAPartialFailureSetsNoFlagAndARetryFinishes() async throws {
        let c = await lcore()
        try await started(c)
        places.fail = ["shutdown demo-bot1"]
        let m = try await act(c, .finish)
        XCTAssertEqual(m.error?.code, .failed)
        XCTAssertTrue(m.error?.message.contains("bot1: demo-bot1 did not shutdown") == true, m.error?.message ?? "")
        XCTAssertNil(try XCTUnwrap(record()).flags.finishedAt, "no flag until every agent reached its target")
        XCTAssertNotNil(try XCTUnwrap(record()).agents.first { $0.name == "mira" }?.stoppedAt, "what did stop is kept")
        // The retry plans only what is left, and finishes.
        let p = try await plan(c, .finish)
        XCTAssertEqual(p.rows.filter(\.changes).map(\.name), ["bot1"])
        trace.reset()
        let f = try ok(try await act(c, .finish))
        XCTAssertEqual(trace.all, ["shutdown demo-bot1"])
        XCTAssertEqual(f.workspace?.state, "finished")
    }

    // MARK: archive, restore, delete

    func testArchiveRetiresOnlyAnonymousWorkersAndRestoreOpensItsRooms() async throws {
        let c = await lcore()
        try await started(c)
        let ottoHash = chat.hashes["otto"]
        let m = try ok(try await act(c, .archive))
        XCTAssertTrue(trace.all.contains("archive demo"))
        XCTAssertNil(chat.hashes["bot1"], "the anonymous worker retired: its token refused")
        XCTAssertEqual(chat.hashes["otto"], ottoHash, "a bot keeps its token")
        XCTAssertEqual(chat.hashes["mira"] != nil, true, "the manager keeps its token")
        let rec = try XCTUnwrap(record())
        XCTAssertNotNil(rec.agents.first { $0.name == "bot1" }?.endedAt)
        XCTAssertNil(rec.agents.first { $0.name == "otto" }?.endedAt)
        XCTAssertEqual(rec.flags.archive?.rooms, ["demo"])
        XCTAssertNotNil(rec.flags.finishedAt)
        XCTAssertEqual(m.workspace?.state, "archived")
        XCTAssertTrue(log().contains("worker-retired") && log().contains("room-archived"))
        XCTAssertFalse(trace.all.contains { $0.hasPrefix("rm ") || $0.hasPrefix("template") }, "no disk without --remove-sandboxes")
        // Restore: exactly its rooms, finished; the retired worker stays ended.
        trace.reset()
        let r = try ok(try await act(c, .restore))
        XCTAssertEqual(trace.all, ["unarchive demo"])
        XCTAssertEqual(r.workspace?.state, "finished")
        XCTAssertNil(try XCTUnwrap(record()).flags.archivedAt)
        XCTAssertTrue(r.notes?.contains("retired workers stay ended: bot1") == true)
    }

    func testArchiveWithChatOffIsRefusedNamingTheFix() async throws {
        let c = await lcore()
        try await started(c)
        rooms.ready = .off
        let p = try await plan(c, .archive)
        XCTAssertEqual(p.refusalCode, "unavailable")
        XCTAssertTrue(p.refusals.first?.contains("doz chat on") == true)
        let m = await ws(c, .workspaceArchive, "demo") { $0.ifPlan = p.sha }
        XCTAssertEqual(m.error?.code, .unavailable)
        XCTAssertTrue(trace.all.isEmpty)
    }

    func testRemoveSandboxesKeepsATemplateFirstAndOnlyItsOwn() async throws {
        let c = await lcore()
        try await started(c)
        // A VM worker of its own, and an adopted agent recorded in the workspace.
        var q = WorkerRequest(workspace: "demo")
        q.task = "render"
        q.isolation = "vm"
        var r = HostRequest(.workerAdd)
        r.workerRequest = q
        let added = await c.handle(r)
        XCTAssertNil(added.error)
        var rec = try XCTUnwrap(record())
        rec.agents.append(WorkspaceAgent(name: "lab", place: .sandbox("lab"), startedAt: Date()))
        try WorkspaceStore(store: store).write(rec)
        places.now["sandbox:lab"] = .running
        trace.reset()
        let m = try ok(try await act(c, .archive) { $0.removeSandboxes = true })
        let vm = try XCTUnwrap(workers.orders.last { $0.isolation == .vm }).place
        XCTAssertEqual(m.templates, [vm: vm + "-tpl"])
        let t = trace.all
        XCTAssertLessThan(try XCTUnwrap(t.firstIndex(of: "template \(vm) as \(vm)-tpl")), try XCTUnwrap(t.firstIndex(of: "rm \(vm)")), "the template first")
        XCTAssertFalse(t.contains("rm lab"), "an adopted sandbox is never removed")
        let after = try XCTUnwrap(record())
        XCTAssertEqual(after.flags.archive?.removed, [vm])
        XCTAssertEqual(after.agents.first { $0.place.sandbox == vm }?.template, vm + "-tpl")
        XCTAssertNotNil(after.agents.first { $0.name == "lab" }, "the adopted agent stays in the record")
    }

    func testDeleteRefusesWhileRunningAndReleasesAdoptedAgentsLoose() async throws {
        let c = await lcore()
        try await started(c)
        var rec = try XCTUnwrap(record())
        rec.agents.append(WorkspaceAgent(name: "shell", place: .macSession("shell"), startedAt: Date()))
        try WorkspaceStore(store: store).write(rec)
        places.now["mac:shell"] = .running
        // Not finished: refused.
        var m = try await act(c, .delete) { $0.confirm = "demo" }
        XCTAssertEqual(m.error?.code, .invalidPhase)
        XCTAssertTrue(m.error?.message.contains("finish it first") == true)
        // Finished, but the adopted session still runs: refused, naming it.
        _ = try ok(try await act(c, .finish))
        places.now["mac:shell"] = .running
        m = try await act(c, .delete)
        XCTAssertTrue(m.error?.message.contains("shell still runs") == true, m.error?.message ?? "")
        XCTAssertNotNil(try record())
        // Stopped: deleted — the record gone, the manager's and workers' session records forgotten, shell untouched (loose),
        // the folder on disk, the room archived (it stays readable).
        places.now["mac:shell"] = .ended
        trace.reset()
        let d = try ok(try await act(c, .delete))
        XCTAssertNil(d.workspace)
        XCTAssertNil(try record())
        XCTAssertFalse(WorkspaceStore(store: store).exists("demo"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: work.path), "no folder without --bin-folders")
        XCTAssertEqual(Set(trace.all.filter { $0.hasPrefix("forget") }), ["forget demo", "forget demo-bot1", "forget demo-otto"])
        XCTAssertFalse(trace.all.contains("forget shell"), "an adopted session is released loose, never forgotten")
        XCTAssertTrue(trace.all.contains("archive demo"))
        XCTAssertTrue(d.notes?.contains("loose again: @mac/shell") == true, d.notes?.joined(separator: "; ") ?? "")
        XCTAssertNil(chat.hashes["bot1"])
        XCTAssertNotNil(chat.hashes["otto"], "a bot is untouched")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: bin.path), [], "nothing went to the Bin")
    }

    func testBinFoldersMovesToTheTestsBinAndRefusesTheStore() async throws {
        let c = await lcore()
        try await started(c)
        _ = try ok(try await act(c, .finish))
        // The store as a folder of the workspace: refused by name, nothing moved, nothing deleted.
        var rec = try XCTUnwrap(record())
        rec.folders.append(WorkspaceFolder(path: WorkspaceStore.resolved(store.root.path)))
        try WorkspaceStore(store: store).write(rec)
        let p = try await plan(c, .delete) { $0.binFolders = true }
        XCTAssertTrue(p.refusals.contains { $0.contains("holds Dozable's store") }, p.refusals.joined(separator: "; "))
        let m = await ws(c, .workspaceDelete, "demo") { $0.binFolders = true; $0.ifPlan = p.sha }
        XCTAssertEqual(m.error?.code, .invalid)
        XCTAssertNotNil(try record())
        XCTAssertTrue(FileManager.default.fileExists(atPath: work.path))
        // Only its own folder: moved into the test's Bin.
        rec.folders.removeLast()
        try WorkspaceStore(store: store).write(rec)
        let d = try ok(try await act(c, .delete) { $0.binFolders = true })
        XCTAssertEqual(d.binned, [work.path])
        XCTAssertFalse(FileManager.default.fileExists(atPath: work.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bin.appendingPathComponent("work").path), "in the test's Bin, never deleted")
    }

    // MARK: the dashboard's confirmations, the read-only core, the keychain

    func testTheTypedNameIsCheckedByTheDaemon() async throws {
        let c = await lcore()
        try await started(c)
        for wrong in [nil, "dem", "demo2"] as [String?] {
            let m = try await act(c, .archive) { $0.confirmRequired = true; $0.confirm = wrong }
            XCTAssertEqual(m.error?.code, .invalid, String(describing: wrong))
            XCTAssertTrue(m.error?.message.contains("type the name demo") == true)
        }
        XCTAssertTrue(trace.all.isEmpty, "nothing done")
        XCTAssertNil(try XCTUnwrap(record()).flags.archivedAt)
        let right = try await act(c, .archive) { $0.confirmRequired = true; $0.confirm = "demo" }
        XCTAssertNoThrow(try ok(right))
    }

    func testAnUnfencedManagersWakeFromABrowserNeedsTheConfirmation() async throws {
        let c = await lcore()
        // An unfenced manager's token file is written under the temporary folder (named by this scratch store): gone after.
        defer { c.removeManagerTokenFolder("solo"); try? FileManager.default.removeItem(atPath: c.managerTokenRoot) }
        _ = try change(await ask(c, .botNew, "uma") { $0.agent = "claude-code"; $0.isolation = "unfenced"; $0.deliver = "poll" })
        let made = await ws(c, .workspaceNew, "solo") {
            $0.brief = "x\n"; $0.folders = [WorkspaceFolder(path: self.work.path)]; $0.manager = "uma"; $0.managerIsolation = "unfenced"
        }
        XCTAssertNil(made.error, made.error?.message ?? "")
        let begun = await ws(c, .workspaceStart, "solo")
        XCTAssertNil(begun.error, begun.error?.message ?? "")
        _ = try ok(try await act(c, .sleep, "solo"))
        trace.reset()
        let m = try await act(c, .wake, "solo") { $0.confirmRequired = true }
        XCTAssertEqual(m.error?.message, "uma acts as you — confirm it")
        XCTAssertTrue(trace.all.isEmpty)
        let confirmed = try await act(c, .wake, "solo") { $0.confirmRequired = true; $0.unfencedConfirmed = true }
        XCTAssertTrue(try ok(confirmed).results.allSatisfy(\.ok))
        XCTAssertEqual(trace.all, ["manager solo (again)"])
    }

    func testAReadOnlyCorePlansEveryVerbAndDoesNone() async throws {
        let c = await lcore()
        try await started(c)
        let ro = await lcore(readOnly: true)
        for v in WorkspaceVerb.allCases {
            let p = try await plan(ro, v)
            XCTAssertFalse(p.factsKnown, v.rawValue)
            XCTAssertTrue(p.notes.contains { $0.contains("no daemon runs") }, v.rawValue)
            if v == .stop { continue }
            let m = await ws(ro, v.hostOp, "demo") { $0.ifPlan = p.sha }
            XCTAssertEqual(m.error?.code, .unavailable, v.rawValue)
            XCTAssertTrue(m.error?.message.contains("needs the daemon") == true, v.rawValue)
        }
        XCTAssertTrue(trace.all.isEmpty)
        let unknown = await ws(ro, .workspaceLifecyclePlan, "demo") { $0.verb = "pause" }
        XCTAssertEqual(unknown.error?.code, .invalid, "an unknown verb")
    }

    final class CountingKeychain: KeychainAccess, @unchecked Sendable {
        let inner: MemoryKeychain
        let lock = NSLock()
        var reads = 0
        init(_ k: MemoryKeychain) { inner = k }
        func read(service: String, account: String?) -> KeychainRead { lock.withLock { reads += 1 }; return inner.read(service: service, account: account) }
        func write(service: String, account: String, secret: String) throws { try inner.write(service: service, account: account, secret: secret) }
        func delete(service: String, account: String) throws { try inner.delete(service: service, account: account) }
        func items(servicePrefix: String) -> [KeychainItemInfo] { inner.items(servicePrefix: servicePrefix) }
    }

    func testAPlanReadsNoKeychain() async throws {
        let c = await lcore()
        try await started(c)
        let counting = CountingKeychain(keychain)
        let s = CredentialServices(keychain: counting, verifier: FakeVerifier(answer: .verified), claudeBinary: { nil }, home: root,
                                   keepaliveRunner: FakeRunner(), isClaudeRunning: { false }, watchInterval: .seconds(3600))
        let look = HostCore(store: store, readOnly: true, version: "test", services: s)
        await look.load()
        await look.setAgentLifecycle(places)
        await look.setManagerLauncher(managers)
        await look.setWorkerLauncher(workers)
        for v in WorkspaceVerb.allCases { _ = try await plan(look, v) }
        XCTAssertEqual(counting.reads, 0, "a look never reads the keychain")
    }
}
