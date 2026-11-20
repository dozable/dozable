import DozableKit
import Foundation

// A workspace's lifecycle in the daemon: the facts its plan reads (`workspaceLifecycleFacts`), the plan
// (`workspace-lifecycle-plan`, read-only — in-process with no daemon, never the keychain), and the verbs that act on it.
// `docs/engineering/workspaces.md` ("The lifecycle").

/// One agent's place for a lifecycle change.
public struct AgentLifecycleOrder: Equatable, Sendable {
    public var workspace: String
    public var agent: String
    /// `manager`, `worker` or `adopted`.
    public var role: String
    /// A sandbox's name (nil: a session on this Mac).
    public var sandbox: String?
    /// A session on this Mac (nil: a sandbox), or a shared sandbox's session.
    public var session: String?
    /// `vm`, `fenced` or `unfenced`.
    public var isolation: String
    public init(workspace: String, agent: String, role: String, sandbox: String?, session: String?, isolation: String) {
        self.workspace = workspace; self.agent = agent; self.role = role; self.sandbox = sandbox; self.session = session; self.isolation = isolation
    }
}

/// How a workspace's agents are looked at and changed by its lifecycle — the daemon's (`DaemonAgentLifecycle`: a sandbox's
/// hibernate / wake / start / shutdown / template / rm, a session on this Mac's end, restart and forgetting), or a test's
/// fake. A manager's and a worker's relaunch go through their own launchers (`ManagerLauncher`, `WorkerLauncher`).
public protocol WorkspaceAgentLifecycle: Sendable {
    /// What the plan reads of one agent's place now.
    func facts(_ a: WorkspaceAgent, workspace: String) async -> WorkspaceLifecycle.AgentFacts
    /// Sleep: a sandbox hibernated (its memory given back, its sessions kept); a session on this Mac ended, its record and
    /// conversation kept.
    func sleep(_ o: AgentLifecycleOrder) async throws -> [String]
    /// Wake an adopted agent: a sandbox woken (or started, when it was shut down); a session on this Mac restarted (its
    /// conversation resumed when it has one). A sandbox of a manager or a worker woken from sleep comes here too.
    func wake(_ o: AgentLifecycleOrder) async throws -> [String]
    /// Finish: a sandbox shut down (its disk kept); a session on this Mac ended, its record kept.
    func shutdown(_ o: AgentLifecycleOrder) async throws -> [String]
    /// A template of `sandbox` named `name` (its disk, never its state disk).
    func keepTemplate(sandbox: String, name: String) async throws
    /// The sandbox removed (its disks and restore points).
    func removeSandbox(_ name: String) async throws
    /// A session on this Mac that has ended: its record forgotten (and its secrets with it).
    func forgetSession(_ name: String) async throws
}

/// The daemon's: the core's own paths.
final class DaemonAgentLifecycle: WorkspaceAgentLifecycle, @unchecked Sendable {
    weak var core: HostCore?
    init(core: HostCore) { self.core = core }
    func facts(_ a: WorkspaceAgent, workspace: String) async -> WorkspaceLifecycle.AgentFacts {
        await core?.agentFacts(a) ?? WorkspaceLifecycle.AgentFacts(now: .gone)
    }
    func sleep(_ o: AgentLifecycleOrder) async throws -> [String] { try await live().agentSleep(o) }
    func wake(_ o: AgentLifecycleOrder) async throws -> [String] { try await live().agentWake(o) }
    func shutdown(_ o: AgentLifecycleOrder) async throws -> [String] { try await live().agentShutdown(o) }
    func keepTemplate(sandbox: String, name: String) async throws { try await live().agentKeepTemplate(sandbox, name) }
    func removeSandbox(_ name: String) async throws { try await live().agentRemoveSandbox(name) }
    func forgetSession(_ name: String) async throws { try await live().agentForgetSession(name) }
    private func live() throws -> HostCore {
        guard let core else { throw HostError(.unavailable, "the daemon is stopping") }
        return core
    }
}

extension HostCore {
    var agentLifecycle: any WorkspaceAgentLifecycle { agentLifecycleOverride ?? DaemonAgentLifecycle(core: self) }

    // MARK: the facts

    /// What the plan reads of one agent's place: from what the daemon holds (or, in-process, the store's records and the
    /// sessions' holders) — never a guest call, never the keychain.
    func agentFacts(_ a: WorkspaceAgent) async -> WorkspaceLifecycle.AgentFacts {
        typealias F = WorkspaceLifecycle.AgentFacts
        guard a.place.key != nil else { return F(now: .elsewhere) }
        if let s = a.place.sandbox {
            guard let m = managed[s] else { return F(now: a.isManager && a.stoppedAt == nil ? .notStarted : .gone) }
            let phase = await effectivePhase(m)
            let now: F.Now
            switch phase {
            case .running: now = .running
            case .booting: now = .booting
            case .paused: now = .paused
            case .asleep, .hibernated: now = .asleep
            case .off: now = .off
            case .failed: now = .failed
            }
            let own = a.isWorker && a.place.session != nil ? statuses[s]?[a.place.session!].map { [$0] } : statuses[s].map { Array($0.values) }
            var kept: Bool?
            if a.isWorker, a.anonymous == true {
                let v = WorkerLaunch.tokenVariables(name: a.name, shared: a.place.session != nil).variable
                kept = m.config.secrets?.contains { $0.variable == v } == true
            }
            return F(now: now, activity: readOnly ? nil : WorkspaceState.activity(WorkspaceState.agent(phase: phase.rawValue, statuses: own)),
                     resumable: true, memoryMiB: Int(m.config.spec.memoryMiB), diskBytes: allocatedBytes(store.layout(s).sandboxDirectory),
                     points: m.sandbox.restorePoints().count, secretKept: kept)
        }
        guard a.place.mac == true, let s = a.place.session, !buildFlavor.isHelper else { return F(now: .gone) }
        let rec = mac.records().sessions[s]
        let rows = await workspaceMacRows()
        guard let row = rows[s], row.gone != true else {
            return F(now: rec == nil ? (a.isManager && a.stoppedAt == nil ? .notStarted : .gone) : .ended, fenced: rec.map { $0.fence != nil },
                     resumable: rec.map { MacPlace.isClaude($0.argv) } ?? false)
        }
        var kept: Bool?
        if a.isWorker, a.anonymous == true, a.isolation != "unfenced" {
            let v = WorkerLaunch.tokenVariables(name: a.name, shared: false).variable
            kept = rec?.fence?.secrets?.contains { $0.variable == v } == true
        }
        return F(now: row.ended ? .ended : .running, activity: row.ended || readOnly ? nil : WorkspaceState.activity(WorkspaceState.agent(macRow: row)),
                 fenced: rec.map { $0.fence != nil } ?? (row.fence != nil), resumable: rec.map { MacPlace.isClaude($0.argv) } ?? false, secretKept: kept)
    }

    /// Everything the plan of `rec` reads besides the record. A look never starts the daemon and never reads the keychain.
    func workspaceLifecycleFacts(_ rec: WorkspaceRecord) async -> WorkspaceLifecycle.Facts {
        var f = WorkspaceLifecycle.Facts()
        f.known = !readOnly
        for a in rec.agents where a.endedAt == nil { f.agents[a.name] = await agentLifecycle.facts(a, workspace: rec.name) }
        switch await workspaceLookReadiness(look: true).0 {
        case .off: f.chat = .off
        case .notReady(let why): f.chat = .notReady(why)
        case .ready: f.chat = .ready
        }
        f.width = max(1, DozableSettings.load().int(SettingKey.batchConcurrency))
        f.busy = startingWorkspaces.contains(rec.name) || lifecycleWorkspaces.contains(rec.name)
        f.home = WorkspaceStore.resolved(TestSafety.realHome.path)
        f.store = WorkspaceStore.resolved(store.root.path)
        for other in workspaces.records() where other.name != rec.name {
            for fo in other.folders { f.foldersInUse[WorkspaceStore.resolved(fo.path)] = "the workspace \(other.name)" }
        }
        for m in managed.values {
            guard let folder = m.config.workspace else { continue }
            // A sandbox of this workspace that the delete removes does not hold its folders.
            if rec.agents.contains(where: { $0.endedAt == nil && $0.place.sandbox == m.name }) { continue }
            f.foldersInUse[WorkspaceStore.resolved(folder)] = "the sandbox \(m.name)"
        }
        f.imagesTaken = Set(store.layout("_").customImages().map(\.name)).union(DozableImages.builtIn)
        f.ownedRooms = Set(ownedRooms(rec))
        return f
    }

    /// `workspace-lifecycle-plan`: the plan of `w.verb` — nothing written, no daemon started, no keychain item read.
    func workspaceLifecyclePlan(_ w: WorkspaceRequest) async throws -> WorkspaceLifecyclePlan {
        let n = try workspaceName(w)
        guard let v = w.verb, let verb = WorkspaceVerb(rawValue: v) else {
            throw HostError(.invalid, "which change? one of \(WorkspaceVerb.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        let rec = try workspaceRecord(n)
        return await lifecyclePlan(verb, rec, WorkspaceLifecycle.Options(w))
    }

    /// The plan of `verb` for `rec` as it is now.
    func lifecyclePlan(_ verb: WorkspaceVerb, _ rec: WorkspaceRecord, _ o: WorkspaceLifecycle.Options) async -> WorkspaceLifecyclePlan {
        var facts = await workspaceLifecycleFacts(rec)
        if (verb == .finish || (verb == .archive && rec.flags.finishedAt == nil)) && !o.noArchive { facts.archive = await archiveFacts(rec, chat: facts.chat) }
        let d = await workspaceDetail(rec, withBrief: false)
        return WorkspaceLifecycle.plan(verb: verb, record: rec, state: d.state, facts: facts, options: o)
    }
}

// MARK: what a run's archive would hold

extension HostCore {
    /// The archive section's facts: the run, each room's messages so far (only when chat answers), each agent's conversations
    /// (a session on this Mac's from its listing; a sandbox's are found when it is copied), the screens, the free space.
    func archiveFacts(_ rec: WorkspaceRecord, chat: WorkspaceLifecycle.Chat) async -> WorkspaceLifecycle.ArchiveFacts {
        let run = rec.openRun ?? WorkspaceRuns.legacyRun(rec) ?? WorkspaceRun(id: WorkspaceRuns.nextID(rec.runs, at: Date()), startedAt: Date())
        var a = WorkspaceLifecycle.ArchiveFacts(run: run.id, path: WorkspaceRuns.archivePath(workspace: rec.name, run: run.id))
        let rooms = run.rooms.isEmpty ? rec.rooms.filter { $0.goneAt == nil }.map { WorkspaceRunRoom(room: $0.chatRoom, fromSeq: 0) } : run.rooms
        for r in rooms {
            var count: Int?
            if chat == .ready, !readOnly, let c = workspaceChat, let last = try? c.lastSeq(room: r.room) { count = Int(max(0, last - r.fromSeq)) }
            a.rooms[r.room] = count
        }
        let since = MacTranscripts.stamp(run.startedAt)
        for ag in runAgents(rec, run) where ag.place.key != nil {
            a.screens.append(ag.name)
            if let s = ag.place.sandbox {
                let who = ag.place.session != nil && ag.isWorker ? s : ag.name
                if a.transcripts[who] == nil { a.transcripts[who] = ("sandbox", nil, nil) }
                continue
            }
            guard let s = ag.place.session, !buildFlavor.isHelper else { continue }
            let fenced = mac.records().sessions[s]?.fence != nil
            var r = HostRequest(.sessionTranscripts, name: MacPlace.name)
            r.session = s
            let l = try? macTranscriptsList(r)
            let items = (l?.items.filter { $0.endedAt >= since } ?? []) + (l?.conversations ?? [])
            var bytes: Int64 = 0
            for i in items { var st = stat(); if lstat(i.path, &st) == 0 { bytes += Int64(st.st_size) } }
            a.transcripts[ag.name] = (fenced ? "fenced" : "unfenced", items.count, bytes)
        }
        var fs = statfs()
        if statfs(storeRoot, &fs) == 0 { a.freeBytes = Int64(fs.f_bavail) * Int64(fs.f_bsize) }
        return a
    }
}

// MARK: the daemon's agent paths

extension HostCore {
    /// One sandbox operation through the daemon's own `handle` (its progress, its gates, its rules).
    func sandboxOp(_ op: HostOp, _ name: String, _ edit: (inout HostRequest) -> Void = { _ in }) async throws {
        var r = HostRequest(op, name: name)
        edit(&r)
        let a = await handle(r)
        if let e = a.error { throw HostError(e.code, e.message) }
    }

    func macEndSession(_ s: String) async throws {
        guard !buildFlavor.isHelper else { throw HostError(.notImplemented, BuildFlavor.helperLeavesOut("sessions on this Mac")) }
        var r = HostRequest(.sessionEnd, name: MacPlace.name)
        r.session = s
        _ = try await macEnd(r)
    }

    func agentSleep(_ o: AgentLifecycleOrder) async throws -> [String] {
        if let s = o.sandbox {
            try await sandboxOp(.hibernate, s)
            return []
        }
        guard let s = o.session else { return [] }
        if await mac.isRunning(s) { try await macEndSession(s) }
        return []
    }

    func agentWake(_ o: AgentLifecycleOrder) async throws -> [String] {
        if let s = o.sandbox {
            guard let m = managed[s] else { throw HostError(.notFound, "no sandbox \(s) (doz ls)") }
            switch await effectivePhase(m) {
            case .running, .booting: return []
            case .paused: try await sandboxOp(.resume, s)
            case .asleep, .hibernated: try await sandboxOp(.wake, s)
            case .off, .failed: try await sandboxOp(.start, s)
            }
            return []
        }
        guard let s = o.session else { return [] }
        guard !buildFlavor.isHelper else { throw HostError(.notImplemented, BuildFlavor.helperLeavesOut("sessions on this Mac")) }
        if await mac.isRunning(s) { return [] }
        var r = HostRequest(.sessionRestart, name: MacPlace.name)
        r.session = s
        let done = try await macRestart(r)
        return done.notice.map { [$0] } ?? []
    }

    func agentShutdown(_ o: AgentLifecycleOrder) async throws -> [String] {
        if let s = o.sandbox {
            guard let m = managed[s] else { return [] }
            switch await effectivePhase(m) {
            case .off: return []
            default: try await sandboxOp(.shutdown, s)
            }
            return []
        }
        guard let s = o.session else { return [] }
        if await mac.isRunning(s) { try await macEndSession(s) }
        return []
    }

    func agentKeepTemplate(_ s: String, _ name: String) async throws {
        try await sandboxOp(.templateCreate, s) { $0.image = name }
    }

    func agentRemoveSandbox(_ s: String) async throws {
        guard managed[s] != nil else { return }
        try await sandboxOp(.rm, s)
    }

    func agentForgetSession(_ s: String) async throws {
        guard mac.records().sessions[s] != nil else { return }
        if await mac.isRunning(s) { throw HostError(.invalidPhase, "the session \(s) on this Mac still runs") }
        try await macEndSession(s)
    }
}

// MARK: the verbs

/// One agent's change, decided by the plan.
struct LifecycleChange: Sendable {
    var key: String
    var agents: [WorkspaceAgent]
}

extension HostCore {
    static func changedSinceYouLooked(_ n: String, _ v: WorkspaceVerb) -> HostError {
        HostError(.invalidPhase, "\(n) changed since you looked — look again: doz workspace \(v.rawValue) \(n) --dry-run")
    }

    /// Sleep, wake, finish, reopen, archive, restore or delete `w.name`: the plan built again and checked (`ifPlan`, its
    /// refusals, the typed name and the "acts as you" confirmation the dashboard requires), then — one gate for the whole
    /// verb — each agent's change, at most `ui.batch_concurrency` at once. A flag is set only once every agent reached its
    /// target; a partial failure says which did not and why (a retry does the rest).
    func workspaceLifecycle(_ verb: WorkspaceVerb, _ w: WorkspaceRequest) async throws -> WorkspaceChanged {
        guard !readOnly else { throw HostError(.unavailable, "\(verb.hostOp.rawValue) needs the daemon") }
        let n = try workspaceName(w)
        let o = WorkspaceLifecycle.Options(w)
        await workspaceGate.lock("workspace:" + n)
        defer { workspaceGate.unlock("workspace:" + n) }
        await workspaceGate.lock("workspaces")
        let rec: WorkspaceRecord
        let plan: WorkspaceLifecyclePlan
        do {
            rec = try workspaceRecord(n)
            plan = await lifecyclePlan(verb, rec, o)
            if let want = w.ifPlan, want != plan.sha { throw Self.changedSinceYouLooked(n, verb) }
            if let first = plan.refusals.first { throw HostError(HostError.Code(rawValue: plan.refusalCode ?? "") ?? .invalidPhase, first) }
            // The dashboard's archive and delete carry the name as the person typed it: checked here, whatever the page did.
            if verb.confirm == .typed, w.confirmRequired == true, w.confirm != n {
                throw HostError(.invalid, "type the name \(n) to \(verb.rawValue) it — the name typed is not its name")
            }
            // An unfenced manager woken from a browser acts as the person: confirmed, as a start is.
            if verb == .wake, w.confirmRequired == true, w.unfencedConfirmed != true, let m = rec.manager, m.actsAsYou,
               plan.rows.contains(where: { $0.name == m.name && $0.changes }) {
                throw HostError(.invalidPhase, "\(m.name) acts as you — confirm it")
            }
            lifecycleWorkspaces.insert(n)
        } catch {
            workspaceGate.unlock("workspaces")
            throw error
        }
        workspaceGate.unlock("workspaces")
        defer { lifecycleWorkspaces.remove(n) }
        note(nil, "workspace \(n): \(verb.rawValue) — \(plan.queue.changes) change\(plan.queue.changes == 1 ? "" : "s"), at most \(plan.queue.width) at once")
        switch verb {
        case .stop: throw HostError(.invalid, "stop is workspace-stop")
        case .sleep: return try await lifecycleSleep(rec, plan)
        case .wake: return try await lifecycleWake(rec, plan)
        case .finish: return try await lifecycleFinish(rec, plan, o)
        case .reopen: return try await lifecycleReopen(rec)
        case .archive: return try await lifecycleArchive(rec, plan, o)
        case .restore: return try await lifecycleRestore(rec)
        case .delete: return try await lifecycleDelete(rec, plan, o)
        }
    }

    /// The plan's changes, in its order, two agents of one place one change.
    func lifecycleChanges(_ rec: WorkspaceRecord, _ plan: WorkspaceLifecyclePlan) -> [LifecycleChange] {
        var out: [LifecycleChange] = []
        for r in plan.rows where r.changes {
            guard let a = rec.agents.first(where: { $0.name == r.name && $0.endedAt == nil }) else { continue }
            let key = r.change ?? r.name
            if let i = out.firstIndex(where: { $0.key == key }) { out[i].agents.append(a) } else { out.append(LifecycleChange(key: key, agents: [a])) }
        }
        return out
    }

    /// Run `changes` at most `width` at once (the rest wait their turn, said in the daemon's log: "queued — N ahead"); each
    /// answers its agents' results.
    func runLifecycle(_ n: String, _ changes: [LifecycleChange], width: Int,
                      _ body: @escaping @Sendable (LifecycleChange) async -> [WorkspaceAgentResult]) async -> [WorkspaceAgentResult] {
        var results: [WorkspaceAgentResult] = []
        var next = 0
        await withTaskGroup(of: [WorkspaceAgentResult].self) { group in
            while next < changes.count, next < width {
                let c = changes[next]
                next += 1
                group.addTask { await body(c) }
            }
            for (i, c) in changes.enumerated() where i >= next {
                note(nil, "workspace \(n): \(c.agents.map(\.name).joined(separator: ", ")) queued — \(i - next + 1) ahead")
            }
            while let r = await group.next() {
                results += r
                if next < changes.count {
                    let c = changes[next]
                    next += 1
                    group.addTask { await body(c) }
                }
            }
        }
        // In the plan's order.
        let order = changes.flatMap { $0.agents.map(\.name) }
        return results.sorted { (order.firstIndex(of: $0.name) ?? 0) < (order.firstIndex(of: $1.name) ?? 0) }
    }

    func lifecycleOrder(_ n: String, _ a: WorkspaceAgent) -> AgentLifecycleOrder {
        let role = a.isManager ? "manager" : a.isWorker ? "worker" : "adopted"
        if let s = a.place.sandbox { return AgentLifecycleOrder(workspace: n, agent: a.name, role: role, sandbox: s, session: a.place.session, isolation: "vm") }
        let fenced = a.isolation.map { $0 != "unfenced" } ?? (mac.records().sessions[a.place.session ?? ""]?.fence != nil)
        return AgentLifecycleOrder(workspace: n, agent: a.name, role: role, sandbox: nil, session: a.place.session, isolation: fenced ? "fenced" : "unfenced")
    }

    /// The failures of `results`, or nil when every agent reached its target.
    static func lifecycleFailure(_ n: String, _ verb: String, _ results: [WorkspaceAgentResult]) -> HostError? {
        let bad = results.filter { !$0.ok }
        guard !bad.isEmpty else { return nil }
        return HostError(.failed, "\(n): \(bad.count) of \(results.count) agent\(results.count == 1 ? "" : "s") did not \(verb):\n"
                         + bad.map { "  - \($0.name): \($0.text)" }.joined(separator: "\n") + "\nwhat did is kept — run it again to do the rest")
    }

    /// The record's agents changed under the `workspaces` gate, with their log lines.
    func lifecycleRecord(_ n: String, _ log: [WorkspaceLogEntry], _ change: @escaping (inout WorkspaceRecord) -> Void) async {
        _ = try? await workspaceUpdate(n) { r in change(&r); return log }
    }

    // MARK: sleep

    func lifecycleSleep(_ rec: WorkspaceRecord, _ plan: WorkspaceLifecyclePlan) async throws -> WorkspaceChanged {
        let n = rec.name
        let results = await runLifecycle(n, lifecycleChanges(rec, plan), width: plan.queue.width) { c in
            await self.sleepChange(n, c)
        }
        let failed = Self.lifecycleFailure(n, "sleep", results)
        try? workspaces.append(n, WorkspaceLogEntry(action: "slept", reason: failed == nil ? nil : "not every agent went to sleep"))
        if let failed { throw failed }
        note(nil, "workspace \(n): asleep")
        return WorkspaceChanged(name: n, verb: "sleep", results: results, notes: ["it stays asleep until you wake it: doz workspace wake \(n)"],
                                workspace: await workspaceDetail(try workspaceRecord(n), withBrief: false))
    }

    func sleepChange(_ n: String, _ c: LifecycleChange) async -> [WorkspaceAgentResult] {
        let first = c.agents[0]
        do {
            _ = try await agentLifecycle.sleep(lifecycleOrder(n, first))
            for a in c.agents where a.actsAsYou { if let s = a.place.session { removeManagerTokenFolder(s) } }
            let names = c.agents.map(\.name)
            await lifecycleRecord(n, names.map { WorkspaceLogEntry(action: "agent-slept", agent: $0) }) { r in
                for i in r.agents.indices where names.contains(r.agents[i].name) && r.agents[i].endedAt == nil { r.agents[i].stoppedAt = Date() }
            }
            return c.agents.map { WorkspaceAgentResult(name: $0.name, ok: true, text: first.place.sandbox != nil ? "hibernated" : "ended, its record kept") }
        } catch {
            let why = HostError.from(error).message
            return c.agents.map { WorkspaceAgentResult(name: $0.name, ok: false, text: why) }
        }
    }

    // MARK: wake

    func lifecycleWake(_ rec: WorkspaceRecord, _ plan: WorkspaceLifecyclePlan) async throws -> WorkspaceChanged {
        let n = rec.name
        let results = await runLifecycle(n, lifecycleChanges(rec, plan), width: plan.queue.width) { c in
            await self.wakeChange(rec, c)
        }
        let failed = Self.lifecycleFailure(n, "wake", results)
        try? workspaces.append(n, WorkspaceLogEntry(action: "woke", reason: failed == nil ? nil : "not every agent woke"))
        if let failed { throw failed }
        note(nil, "workspace \(n): awake")
        return WorkspaceChanged(name: n, verb: "wake", results: results, workspace: await workspaceDetail(try workspaceRecord(n), withBrief: false))
    }

    /// One place woken: a manager through its start's restart branch; a worker re-launched in place (a sandbox woken from
    /// sleep keeps its sessions); an adopted agent's sandbox woken or started, its session restarted.
    func wakeChange(_ rec: WorkspaceRecord, _ c: LifecycleChange) async -> [WorkspaceAgentResult] {
        let n = rec.name
        var out: [WorkspaceAgentResult] = []
        var sandboxWoken = false
        for a in c.agents {
            do {
                let facts = await agentLifecycle.facts(a, workspace: n)
                var text = "running again"
                if let s = a.place.sandbox, facts.now == .asleep || facts.now == .paused {
                    // From sleep: the same sessions and screens, once per sandbox.
                    if !sandboxWoken { _ = try await agentLifecycle.wake(lifecycleOrder(n, a)) }
                    sandboxWoken = true
                    text = "woken (\(s))"
                } else if a.isManager, let bot = a.bot {
                    let iso = ManagerIsolation(rawValue: a.isolation ?? "fenced") ?? .fenced
                    let place = a.place.sandbox ?? a.place.session ?? ManagerLaunch.sessionName(workspace: n)
                    let info = await managerLauncher.info(isolation: iso, place: place)
                    if !info.running {
                        let launched = try await workspaceLaunchManager(try workspaceRecord(n), bot: bot, isolation: iso, place: place, restart: info.exists)
                        await lifecycleRecord(n, [WorkspaceLogEntry(action: "manager-started", agent: bot, place: a.place.key, isolation: iso.rawValue,
                                                                    fingerprint: launched.fingerprint)]) { _ in }
                        text = info.exists ? "running again, in the same conversation" : "started"
                    }
                } else if a.isWorker {
                    text = try await workerWake(try workspaceRecord(n), a, facts: facts)
                } else {
                    _ = try await agentLifecycle.wake(lifecycleOrder(n, a))
                    text = a.place.sandbox != nil ? "running again" : (facts.resumable ? "running again, in the same conversation" : "running again, started fresh")
                }
                let name = a.name
                await lifecycleRecord(n, [WorkspaceLogEntry(action: "agent-woke", agent: name)]) { r in
                    if let i = r.agents.firstIndex(where: { $0.name == name && $0.endedAt == nil }) { r.agents[i].stoppedAt = nil }
                }
                out.append(WorkspaceAgentResult(name: a.name, ok: true, text: text))
            } catch {
                out.append(WorkspaceAgentResult(name: a.name, ok: false, text: HostError.from(error).message))
            }
        }
        return out
    }

    /// A worker re-launched in place: its START written again, its token — a bot's own; an anonymous one's kept by its place,
    /// else a new one (its participant's token replaced: an unfenced worker's file, or a sandbox shut down since) — and its
    /// session opened again, its conversation resumed.
    func workerWake(_ rec: WorkspaceRecord, _ a: WorkspaceAgent, facts: WorkspaceLifecycle.AgentFacts) async throws -> String {
        let n = rec.name, name = a.name
        let iso = ManagerIsolation(rawValue: a.isolation ?? "fenced") ?? .fenced
        let shared = a.place.sandbox != nil && a.place.session != nil
        let place = a.place.sandbox ?? a.place.session ?? name
        let bot = try a.bot.flatMap { try bots.read().bot($0) }
        if a.bot != nil, bot == nil { throw HostError(.notFound, "\(a.bot!) is not a bot any more (doz bot ls)") }
        let agent: String
        if let b = bot { agent = b.agent }
        else if let s = a.place.sandbox, let m = managed[s] { agent = m.config.image == "codex" ? "codex" : "claude-code" }
        else if let s = a.place.session, let r = mac.records().sessions[s] { agent = MacPlace.program(r.argv) == "codex" ? "codex" : "claude-code" }
        else { agent = "claude-code" }
        let pagePort = ChatSettingsView.read().pagePort
        let workdir = try workerFolder(rec, name: name)
        let room = rec.mainRoom?.chatRoom ?? n
        var director: String?
        if let m = rec.manager, let mb = m.bot, await managerRunning(m) { director = mb }
        let wherePlace: WorkerKickoff.Where = shared ? .shared(place) : iso == .vm ? .vm : iso == .unfenced ? .unfenced : .fenced
        let start = Data(WorkerKickoff.startText(name: name, workspace: n, room: room, task: a.task ?? "", director: director, place: wherePlace,
                                                 skills: bot?.skills ?? [], instructions: bot.flatMap { bots.readInstructions($0.name) }).utf8)
        let vars = WorkerLaunch.tokenVariables(name: name, shared: shared)
        var newToken = false
        /// An anonymous worker's new token: its participant's replaced (the old one refused from now on).
        func freshToken() async throws -> String {
            guard let participants = botChat else { throw HostError(.unavailable, "a worker needs chat — doz chat on") }
            let t = ChatTokens.make()
            try await participants.replaceToken(name, token: t)
            newToken = true
            return t
        }
        let plan: ManagerLaunch.Plan
        switch iso {
        case .fenced, .vm:
            let startFile = iso == .vm ? "~/" + WorkerLaunch.vmStartFolder + "/" + name + "/start.md"
                : MacFence.sessionFolder(try mac.fencePlaces(), session: place) + "/etc/worker/start.md"
            var secret: LaunchSecret?
            if let b = bot {
                secret = try botLaunchSecret(b.name, port: pagePort, variable: vars.variable, fileVariable: vars.fileVariable)
            } else if facts.secretKept != true {
                let owner = iso == .vm ? place : LaunchSecrets.macOwner(place)
                let t = try await freshToken()
                let s = try daemonWorkerSecret(owner: owner, token: t, variable: vars.variable, fileVariable: vars.fileVariable, port: pagePort)
                launchSecretSettled(owner: owner, s)
                secret = s
            } else if iso == .vm, let m = managed[place] {
                secret = m.config.secrets?.first { $0.variable == vars.variable }
            }
            var pl = try WorkerLaunch.plan(isolation: iso, agent: agent, model: bot?.model, bot: bot?.name, startFile: startFile, pagePort: pagePort,
                                           fingerprint: secret?.fingerprint ?? "", name: name, shared: shared)
            // A fenced worker's kept secret stays in its session's record; only a bot's or a new one is given again.
            pl.secret = iso == .fenced && bot == nil && !newToken ? nil : secret
            if iso == .vm, pl.secret == nil { throw HostError(.failed, "\(name)'s token is not held by its sandbox \(place) — doz worker end \(n) \(name), then add it again") }
            plan = pl
        case .unfenced:
            if let no = unfencedManagerRefusal() { throw no }
            TestSafety.enforce(TestSafety.managerTokenViolation(store: store.root))
            let value: String
            if let b = bot {
                guard let v = services.keychain.read(service: botService(b.name), account: Keychain.user).value,
                      BotTokens.fingerprint(v) == b.token.fingerprint else {
                    throw HostError(.unavailable, "\(b.name)'s token cannot be read from the login keychain — unlock it, or doz bot token \(b.name) --new")
                }
                value = v
            } else {
                value = try await freshToken()
            }
            let files = try writeAgentTokenFolder(workerTokenFolder(place), token: value, start: start, who: name)
            plan = try WorkerLaunch.plan(isolation: .unfenced, agent: agent, model: bot?.model, bot: bot?.name, startFile: files.startFile,
                                         pagePort: pagePort, fingerprint: BotTokens.fingerprint(value), tokenFile: files.tokenFile, name: name, shared: false)
        }
        let order = WorkerLaunchOrder(workspace: n, name: name, isolation: iso, place: place, session: shared ? name : (iso == .vm ? name : nil), shared: shared,
                                      workdir: workdir, plan: plan, start: start, agent: agent, account: bot?.account, model: bot?.model,
                                      permissions: rec.defaults.network ?? "locked", cpus: nil, memoryMiB: nil, restart: true)
        do {
            _ = try await workerLauncher.launch(order)
        } catch {
            if iso == .unfenced { removeManagerTokenFolder(place) }
            throw error
        }
        let how = iso == .vm ? "started, its agent continuing its conversation" : "running again, in the same conversation"
        return newToken ? how + ", with a new token" : how
    }

    // MARK: finish

    func lifecycleFinish(_ rec: WorkspaceRecord, _ plan: WorkspaceLifecyclePlan, _ o: WorkspaceLifecycle.Options) async throws -> WorkspaceChanged {
        let n = rec.name
        // A sandbox agent's conversations and screen, copied out while its VM still runs.
        let current = rec.openRun ?? WorkspaceRuns.legacyRun(rec)
        let pre = o.noArchive || current == nil ? RunPreStop() : await gatherBeforeStop(rec, current!)
        // 1. Its own rooms closed to new messages first: the close's answer is each room's last seq, taken under the chat
        // server's lock — the run's end marker.
        let toSeq = await closeOwnedRooms(rec)
        let results = await stopEverything(rec, plan)
        if let failed = Self.lifecycleFailure(n, "stop", results) { throw failed }
        let closed = try await closeRun(n, by: "finish", toSeq: toSeq, noArchive: o.noArchive)
        let archive = await archiveClosedRun(n, closed, plan: plan, pre: pre, noArchive: o.noArchive)
        _ = try await workspaceUpdate(n) { r in
            r.flags.finishedAt = Date()
            return [WorkspaceLogEntry(action: "finished")]
        }
        note(nil, "workspace \(n): finished")
        var c = WorkspaceChanged(name: n, verb: "finish", results: results,
                                 notes: ["nothing runs now; its room\(rec.rooms.count == 1 ? "" : "s") and tokens are kept — doz workspace reopen \(n), then wake, to work on it again"]
                                     + archive.notes,
                                 workspace: await workspaceDetail(try workspaceRecord(n), withBrief: false))
        c.run = closed?.id; c.archive = archive.path; c.archiveSHA256 = archive.sha; c.archiveProblem = archive.problem
        return c
    }

    /// Finish's first step: the workspace's own rooms closed (the closed set with them), each room's last seq as the chat
    /// server took it under its lock; a linked room is not closed — its last seq is read as it is. Each closed room logged.
    func closeOwnedRooms(_ rec: WorkspaceRecord) async -> [String: Int64] {
        let n = rec.name
        let owned = ownedRooms(rec)
        var toSeq = await roomLastSeqs(rec)
        guard !owned.isEmpty else { return toSeq }
        var extra: [String: String] = [:]
        for r in owned { extra[r] = n }
        if let seqs = await pushClosedSet(extra: extra) {
            for r in owned { if let s = seqs[r] { toSeq[r] = s } }
            for r in owned { try? workspaces.append(n, WorkspaceLogEntry(action: "room-closed", room: r)) }
        } else {
            for r in owned { try? workspaces.append(n, WorkspaceLogEntry(action: "room-closed", room: r, reason: "the chat server takes it at its next start")) }
        }
        return toSeq
    }

    /// The closed run's archive written (unless `noArchive`): what was gathered before the stop and what is read now. A
    /// failure is recorded in the run and answered — the verb itself is never undone by it.
    func archiveClosedRun(_ n: String, _ closed: WorkspaceRun?, plan: WorkspaceLifecyclePlan, pre: RunPreStop,
                          noArchive: Bool) async -> (path: String?, sha: String?, problem: String?, notes: [String]) {
        // A space's final frame (its run down), before the archive copies the run's frames.
        if let run = closed { await spaceFrameRecord(n, label: "down", closed: run) }
        guard let run = closed, !noArchive, let rec = try? workspaceRecord(n) else {
            return (nil, nil, nil, closed != nil && noArchive ? ["no archive was written (--no-archive)"] : [])
        }
        var g = gatherAfterStop(rec, run)
        g.transcripts = pre.transcripts + g.transcripts
        g.screens.merge(pre.screens) { a, _ in a }
        // A space file's `archive: keep:` filters what is optional: transcripts and screens (the chat slice, the manifest,
        // usage and the timesheet are always kept — a room's removal relies on the slice).
        if let keep = SpaceRecordRef.of(rec)?.archiveKeep {
            if !keep.contains("transcripts") { g.transcripts = []; g.notes.append("transcripts not kept (the space's archive keep list)") }
            if !keep.contains("screens") { g.screens = [:] }
        }
        g.notes = pre.notes + g.notes
        do {
            let (path, sha) = try await writeRunArchive(rec, run, plan: plan, gathered: g)
            await recordRunArchive(n, run.id, path: path, sha: sha, problem: nil)
            spaceFramesArchived(n, run.id, archive: path)
            note(nil, "workspace \(n): the archive of run \(run.id) written")
            return (path, sha, nil, ["run \(run.id)'s archive: \(DisplayPath.tilde(storeRoot + "/" + path))"])
        } catch {
            let why = HostError.from(error).message
            await recordRunArchive(n, run.id, path: nil, sha: nil, problem: why)
            note(nil, "workspace \(n): the archive of run \(run.id) was not written: \(why)")
            return (nil, nil, why, ["run \(run.id)'s archive was not written: \(why) — doz workspace runs \(n) --archive \(run.id) writes it again"])
        }
    }

    /// Finish's steps: every place that runs (or sleeps in a VM) shut down or ended, its record, disk and conversation kept;
    /// an unfenced agent's token file deleted.
    func stopEverything(_ rec: WorkspaceRecord, _ plan: WorkspaceLifecyclePlan) async -> [WorkspaceAgentResult] {
        let n = rec.name
        var changes: [LifecycleChange] = []
        for c in lifecycleChanges(rec, plan) {
            let f = await agentLifecycle.facts(c.agents[0], workspace: n)
            if f.runs || (c.agents[0].place.sandbox != nil && f.now == .asleep) { changes.append(c) }
        }
        return await runLifecycle(n, changes, width: plan.queue.width) { c in
            let first = c.agents[0]
            do {
                _ = try await self.agentLifecycle.shutdown(self.lifecycleOrder(n, first))
                for a in c.agents where a.actsAsYou { if let s = a.place.session { self.removeManagerTokenFolder(s) } }
                let names = c.agents.map(\.name)
                await self.lifecycleRecord(n, names.map { WorkspaceLogEntry(action: "agent-slept", agent: $0, reason: "finished") }) { r in
                    for i in r.agents.indices where names.contains(r.agents[i].name) && r.agents[i].endedAt == nil { r.agents[i].stoppedAt = Date() }
                }
                return c.agents.map { WorkspaceAgentResult(name: $0.name, ok: true, text: first.place.sandbox != nil ? "shut down, its disk kept" : "ended, its record kept") }
            } catch {
                let why = HostError.from(error).message
                return c.agents.map { WorkspaceAgentResult(name: $0.name, ok: false, text: why) }
            }
        }
    }

    // MARK: reopen

    func lifecycleReopen(_ rec: WorkspaceRecord) async throws -> WorkspaceChanged {
        let n = rec.name
        _ = try await workspaceUpdate(n) { r in
            r.flags.finishedAt = nil
            r.flags.reopenedAt = Date()
            return [WorkspaceLogEntry(action: "reopened")]
        }
        // Its rooms open to new messages again (the closed set without them), then a new run opens: each room's last seq
        // now is its start marker.
        if await pushClosedSet() != nil {
            for room in ownedRooms(rec) { try? workspaces.append(n, WorkspaceLogEntry(action: "room-opened", room: room)) }
        }
        try await openRun(n)
        let r = try workspaceRecord(n)
        note(nil, "workspace \(n): reopened")
        return WorkspaceChanged(name: n, verb: "reopen", results: [], notes: ["nothing runs yet — doz workspace wake \(n) brings its agents back"],
                                workspace: await workspaceDetail(r, withBrief: false))
    }

    // MARK: archive and restore

    func lifecycleArchive(_ rec: WorkspaceRecord, _ plan: WorkspaceLifecyclePlan, _ o: WorkspaceLifecycle.Options) async throws -> WorkspaceChanged {
        let n = rec.name
        let current = rec.flags.finishedAt == nil ? (rec.openRun ?? WorkspaceRuns.legacyRun(rec)) : nil
        let pre = o.noArchive || current == nil ? RunPreStop() : await gatherBeforeStop(rec, current!)
        var results = await stopEverything(rec, plan)
        if let failed = Self.lifecycleFailure(n, "stop", results) { throw failed }
        // Archive does finish's steps when it is not finished: its run closes here, and its archive is written.
        var archive: (path: String?, sha: String?, problem: String?, notes: [String]) = (nil, nil, nil, [])
        var closedRun: WorkspaceRun?
        if rec.flags.finishedAt == nil {
            closedRun = try await closeRun(n, by: "archive", toSeq: await closeOwnedRooms(rec), noArchive: o.noArchive)
            archive = await archiveClosedRun(n, closedRun, plan: plan, pre: pre, noArchive: o.noArchive)
        }
        // The rooms, read-only from now on (their history kept) — as you.
        var archivedRooms: [String] = []
        var notes: [String] = []
        if !rec.rooms.isEmpty {
            guard let chat = workspaceChat, await chat.readiness() == .ready else { throw HostError(.unavailable, "chat is not ready — doz chat status") }
            for room in rec.rooms.map(\.chatRoom) {
                try chat.setArchived(room: room, true)
                archivedRooms.append(room)
                try? workspaces.append(n, WorkspaceLogEntry(action: "room-archived", room: room))
            }
        }
        // Anonymous workers retired; a bot keeps its token and its membership.
        for a in rec.agents where a.isLiveWorker && a.anonymous == true {
            results.append(await retireWorker(n, a))
        }
        // The sandboxes Dozable made for it, only when asked — a template of each first.
        let (removed, templates, sbx) = await removeOwnSandboxes(rec, plan, o)
        results += sbx
        if let failed = Self.lifecycleFailure(n, "archive", results) { throw failed }
        let r = try await workspaceUpdate(n) { r in
            let now = Date()
            if r.flags.finishedAt == nil { r.flags.finishedAt = now }
            r.flags.archivedAt = now
            r.flags.archive = WorkspaceArchive(rooms: archivedRooms, removed: removed, templates: templates)
            return [WorkspaceLogEntry(action: "archived", added: removed.isEmpty ? nil : removed.count)]
        }
        if !removed.isEmpty { notes.append("removed: \(removed.joined(separator: ", "))" + (templates.isEmpty ? "" : " — templates kept: " + templates.values.sorted().joined(separator: ", "))) }
        notes.append("doz workspace restore \(n) brings it back, finished")
        notes += archive.notes
        await pushClosedSet()
        note(nil, "workspace \(n): archived (\(archivedRooms.count) room\(archivedRooms.count == 1 ? "" : "s"), \(removed.count) sandbox\(removed.count == 1 ? "" : "es") removed)")
        var c = WorkspaceChanged(name: n, verb: "archive", results: results, templates: templates.isEmpty ? nil : templates, notes: notes,
                                 workspace: await workspaceDetail(r, withBrief: false))
        c.run = closedRun?.id; c.archive = archive.path; c.archiveSHA256 = archive.sha; c.archiveProblem = archive.problem
        return c
    }

    /// An anonymous worker retired: its participant removed (out of every room, its token refused, its messages kept), its
    /// launch secret forgotten, its entry ended.
    func retireWorker(_ n: String, _ a: WorkspaceAgent) async -> WorkspaceAgentResult {
        let iso = ManagerIsolation(rawValue: a.isolation ?? "fenced") ?? .fenced
        let shared = a.place.sandbox != nil && a.place.session != nil
        let place = a.place.sandbox ?? a.place.session ?? a.name
        let vars = WorkerLaunch.tokenVariables(name: a.name, shared: shared)
        do {
            if let participants = botChat, (try? participants.directory().participants.contains { $0.name == a.name }) == true {
                try await participants.remove(a.name)
            }
            switch iso {
            case .unfenced:
                removeManagerTokenFolder(place)
            case .fenced:
                let owner = LaunchSecrets.macOwner(place)
                forgetLaunchSecret(owner: owner, LaunchSecret(variable: vars.variable, fileVariable: vars.fileVariable, host: HostRoute.hostName, port: 0,
                                                              fingerprint: "", keychainService: LaunchSecrets.service(store: store.root, owner: owner, variable: vars.variable)))
                if !buildFlavor.isHelper, mac.records().sessions[place] != nil {
                    await sessionGate.lock(MacPlace.name)
                    await mac.updateRecord(place) { r in r.fence?.secrets?.removeAll { $0.variable == vars.variable } }
                    sessionGate.unlock(MacPlace.name)
                }
            case .vm:
                forgetLaunchSecret(owner: place, LaunchSecret(variable: vars.variable, fileVariable: vars.fileVariable, host: HostRoute.hostName, port: 0,
                                                              fingerprint: "", keychainService: LaunchSecrets.service(store: store.root, owner: place, variable: vars.variable)))
                if let m = managed[place], m.config.secrets?.contains(where: { $0.variable == vars.variable }) == true {
                    let kept = (m.config.secrets ?? []).filter { $0.variable != vars.variable }
                    m.config.secrets = kept.isEmpty ? nil : kept
                    try? m.config.write(store.configFile(m.name))
                    applyLaunchSecrets(m)
                }
            }
            sweepLaunchSecrets()
            let name = a.name
            await lifecycleRecord(n, [WorkspaceLogEntry(action: "worker-retired", agent: name, place: a.place.key)]) { r in
                if let i = r.agents.firstIndex(where: { $0.name == name && $0.endedAt == nil }) { r.agents[i].endedAt = Date(); r.agents[i].pendingAt = nil }
            }
            return WorkspaceAgentResult(name: a.name, ok: true, text: "retired: its token is refused from now on")
        } catch {
            return WorkspaceAgentResult(name: a.name, ok: false, text: "not retired: \(HostError.from(error).message)")
        }
    }

    /// With `--remove-sandboxes`: each sandbox Dozable made for the workspace (a manager's or a worker's own) — a template of
    /// it first unless `--no-keep-templates`, then removed. Adopted sandboxes and shared ones are never removed.
    func removeOwnSandboxes(_ rec: WorkspaceRecord, _ plan: WorkspaceLifecyclePlan,
                            _ o: WorkspaceLifecycle.Options) async -> (removed: [String], templates: [String: String], results: [WorkspaceAgentResult]) {
        guard o.removeSandboxes else { return ([], [:], []) }
        let n = rec.name
        var removed: [String] = [], templates: [String: String] = [:], results: [WorkspaceAgentResult] = []
        for a in rec.agents where (a.isManager || a.isWorker) && a.place.sandbox != nil && a.place.session == nil {
            let s = a.place.sandbox!
            guard await agentLifecycle.facts(a, workspace: n).now != .gone else { continue }
            do {
                if o.keepTemplates, let t = plan.templates?[s] {
                    try await agentLifecycle.keepTemplate(sandbox: s, name: t)
                    templates[s] = t
                    let name = a.name
                    await lifecycleRecord(n, [WorkspaceLogEntry(action: "template-kept", agent: name, from: s, to: t)]) { r in
                        if let i = r.agents.firstIndex(where: { $0.name == name && $0.place.sandbox == s }) { r.agents[i].template = t }
                    }
                }
                lifecycleRemoving.insert(s)
                defer { lifecycleRemoving.remove(s) }
                try await agentLifecycle.removeSandbox(s)
                removed.append(s)
                try? workspaces.append(n, WorkspaceLogEntry(action: "sandbox-removed", agent: a.name, place: "sandbox:" + s))
                results.append(WorkspaceAgentResult(name: a.name, ok: true, text: "its sandbox \(s) removed" + (templates[s].map { " (its template \($0) kept)" } ?? "")))
            } catch {
                results.append(WorkspaceAgentResult(name: a.name, ok: false, text: "its sandbox \(s) was not removed: \(HostError.from(error).message)"))
            }
        }
        return (removed, templates, results)
    }

    func lifecycleRestore(_ rec: WorkspaceRecord) async throws -> WorkspaceChanged {
        let n = rec.name
        let rooms = rec.flags.archive?.rooms ?? rec.rooms.map(\.chatRoom)
        if !rooms.isEmpty {
            guard let chat = workspaceChat, await chat.readiness() == .ready else { throw HostError(.unavailable, "chat is not ready — doz chat status") }
            for room in rooms {
                do { try chat.setArchived(room: room, false) } catch let e as HostError where e.code == .notFound { continue }
                try? workspaces.append(n, WorkspaceLogEntry(action: "room-unarchived", room: room))
            }
        }
        var notes: [String] = []
        let retired = rec.agents.filter { $0.isWorker && $0.anonymous == true && $0.endedAt != nil }.map(\.name)
        if !retired.isEmpty { notes.append("retired workers stay ended: \(retired.joined(separator: ", "))") }
        for s in rec.flags.archive?.removed ?? [] {
            notes.append("\(s) is gone" + (rec.flags.archive?.templates[s].map { " — its template \($0)" } ?? ""))
        }
        let r = try await workspaceUpdate(n) { r in
            r.flags.archivedAt = nil
            r.flags.archive = nil
            if r.flags.finishedAt == nil { r.flags.finishedAt = Date() }
            return [WorkspaceLogEntry(action: "restored")]
        }
        notes.append("it is finished: doz workspace reopen \(n), then wake, to work on it again")
        // Its rooms are closed again (finished): readable, posts refused until it is reopened.
        if r.runs.last.map({ !$0.isOpen }) == true, !ownedRooms(r).isEmpty, await pushClosedSet() != nil {
            notes.append("its rooms read closed: doz workspace reopen \(n) opens them to new messages")
        }
        note(nil, "workspace \(n): restored (finished)")
        return WorkspaceChanged(name: n, verb: "restore", results: [], notes: notes, workspace: await workspaceDetail(r, withBrief: false))
    }

    // MARK: delete

    func lifecycleDelete(_ rec: WorkspaceRecord, _ plan: WorkspaceLifecyclePlan, _ o: WorkspaceLifecycle.Options) async throws -> WorkspaceChanged {
        let n = rec.name
        var results: [WorkspaceAgentResult] = []
        var notes: [String] = []
        // Its rooms stay — the chat server cannot delete one — archived, with their history.
        if !rec.rooms.isEmpty, rec.flags.archivedAt == nil {
            if let chat = workspaceChat, await chat.readiness() == .ready {
                for room in rec.rooms.map(\.chatRoom) {
                    do { try chat.setArchived(room: room, true) } catch { notes.append("the room \(room) was not archived: \(HostError.from(error).message)") }
                }
            } else {
                notes.append("chat is not running: its rooms stay as they are")
            }
        }
        for a in rec.agents where a.isLiveWorker && a.anonymous == true { results.append(await retireWorker(n, a)) }
        // A manager's and a worker's sessions on this Mac: their records forgotten (their secrets with them); an unfenced one's
        // token folder swept.
        for a in rec.agents where (a.isManager || a.isWorker) && a.place.mac == true {
            guard let s = a.place.session else { continue }
            if a.actsAsYou { removeManagerTokenFolder(s) }
            do {
                try await agentLifecycle.forgetSession(s)
                if !results.contains(where: { $0.name == a.name }) { results.append(WorkspaceAgentResult(name: a.name, ok: true, text: "its session's record forgotten")) }
            } catch {
                results.append(WorkspaceAgentResult(name: a.name, ok: false, text: "its session's record was not forgotten: \(HostError.from(error).message)"))
            }
        }
        let (removed, templates, sbx) = await removeOwnSandboxes(rec, plan, o)
        results += sbx
        if let failed = Self.lifecycleFailure(n, "delete", results) { throw failed }
        // Its folders to the Bin, only when asked — checked again now.
        var binned: [String] = []
        if o.binFolders {
            let facts = await workspaceLifecycleFacts(rec)
            for f in rec.folders {
                if let why = WorkspaceLifecycle.binRefusal(WorkspaceStore.resolved(f.path), workspace: n, facts: facts) { throw HostError(.invalid, why) }
            }
            for f in rec.folders {
                guard MacFenceHostFS.kind(f.path) != nil else { notes.append("\(DisplayPath.tilde(f.path)) was gone already"); continue }
                do { _ = try WorkspaceBin.move(WorkspaceStore.resolved(f.path)); binned.append(f.path) } catch {
                    throw HostError(.failed, "\(DisplayPath.tilde(f.path)) could not be moved to the Bin: \(HostError.from(error).message) — the workspace is kept; run it again")
                }
            }
        }
        await workspaceGate.lock("workspaces")
        defer { workspaceGate.unlock("workspaces") }
        try workspaces.remove(n)
        Task { await self.pushClosedSet() }
        let released = rec.agents.filter { !$0.isManager && !$0.isWorker && $0.place.key != nil }.map { $0.place.display }
        HostLog.line("workspaces: \(n) deleted (\(rec.agents.count) agent\(rec.agents.count == 1 ? "" : "s"), \(released.count) released loose, \(removed.count) sandbox\(removed.count == 1 ? "" : "es") removed, \(binned.count) folder\(binned.count == 1 ? "" : "s") to the Bin)")
        if !released.isEmpty { notes.append("loose again: \(released.joined(separator: ", "))") }
        if !rec.rooms.isEmpty { notes.append("its room\(rec.rooms.count == 1 ? "" : "s") \(rec.rooms.map { "#" + $0.chatRoom }.joined(separator: ", ")) stay\(rec.rooms.count == 1 ? "s" : ""), archived, with their history") }
        if !o.binFolders, !rec.folders.isEmpty { notes.append("its folders are untouched") }
        return WorkspaceChanged(name: n, verb: "delete", results: results, templates: templates.isEmpty ? nil : templates, binned: binned.isEmpty ? nil : binned,
                                notes: notes, workspace: nil)
    }
}

/// The Bin: a folder moved there, never deleted (macOS's own Trash — `FileManager.trashItem`). A guarded test run moves it
/// into `DOZ_TEST_TRASH_DIR` instead, and only a scratch folder (`TestSafety.trashViolation`): never the real Bin.
public enum WorkspaceBin {
    /// Moves `path` to the Bin and answers where it went.
    @discardableResult
    public static func move(_ path: String, env: [String: String] = ProcessInfo.processInfo.environment) throws -> String {
        TestSafety.enforce(TestSafety.trashViolation(folder: path, env: env), env: env)
        if let dir = TestSafety.trashDirectory(env) {
            let base = (path as NSString).lastPathComponent
            var dest = dir + "/" + base
            var i = 2
            while FileManager.default.fileExists(atPath: dest) { dest = dir + "/" + base + " \(i)"; i += 1 }
            guard rename(path, dest) == 0 else { throw HostError(.failed, String(cString: strerror(errno))) }
            return dest
        }
        var out: NSURL?
        try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &out)
        return out?.path ?? path
    }
}
