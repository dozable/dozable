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
        let facts = await workspaceLifecycleFacts(rec)
        let d = await workspaceDetail(rec, withBrief: false)
        return WorkspaceLifecycle.plan(verb: verb, record: rec, state: d.state, facts: facts, options: o)
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
