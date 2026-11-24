import DozableKit
import Foundation

// A workspace's workers (`doz worker add | ls | end`). The order of an add: everything checked (nothing written on a
// refusal) → the entry, marked pending → an anonymous worker's throwaway participant → invited to the main room (and the
// rooms named) → its token as a launch secret (a bot's own, or a daemon-made one) or, unfenced, a 0600 file → its session
// or sandbox → the entry no longer pending. A failing step undoes the earlier ones; a daemon's start sweeps an entry left
// pending by a crash (`sweepPendingWorkers`). `docs/engineering/workspaces.md` ("Workers").

/// What one launch of a worker needs, decided by the core (`WorkerLauncher.launch`).
public struct WorkerLaunchOrder: Equatable, Sendable {
    public var workspace: String
    public var name: String
    public var isolation: ManagerIsolation
    /// Its session on this Mac, or its sandbox.
    public var place: String
    /// Its session in the sandbox (nil: on this Mac).
    public var session: String?
    /// It joins a sandbox another agent of the workspace runs in (`--sandbox`): never made, never shut down for it.
    public var shared: Bool
    /// Its folder: the workspace's main one, else `<projects_dir>/<workspace>/<name>`.
    public var workdir: String
    public var plan: ManagerLaunch.Plan
    /// START's text.
    public var start: Data
    public var agent: String
    public var account: String?
    public var model: String?
    /// Its network permissions: the workspace's default, else `locked`.
    public var permissions: String
    public var cpus: Int?
    public var memoryMiB: UInt64?
    /// A wake: its session or sandbox exists from an earlier run and is opened again in place — a session on this Mac
    /// resumed from its record (its conversation, its kept secrets), a sandbox started with its agent continuing.
    public var restart = false
    /// 774: what its place's policy makes of its fence or its new sandbox (nil: the defaults, as before).
    public var placeFence: PlaceFence? = nil
}

/// What ending a worker needs.
public struct WorkerEndOrder: Equatable, Sendable {
    public var workspace: String
    public var name: String
    public var isolation: ManagerIsolation
    public var place: String
    public var session: String?
    public var shared: Bool
    /// Its place deleted too (its session's record, or its own sandbox).
    public var rm: Bool
    /// Its token's variable in its place's record (nil: unfenced — a file).
    public var variable: String?
}

/// What the core knows of a sandbox a worker would join (`--sandbox`).
public struct WorkerSandboxInfo: Equatable, Sendable {
    public var running: Bool
    public var proxied: Bool
    /// This Mac's ports it reaches.
    public var hostPorts: [UInt16]
    /// Its launch secrets' variables.
    public var variables: [String]
    public init(running: Bool, proxied: Bool = true, hostPorts: [UInt16] = [], variables: [String] = []) {
        self.running = running; self.proxied = proxied; self.hostPorts = hostPorts; self.variables = variables
    }
}

/// How a worker is started and ended — the daemon's (`DaemonWorkerLauncher`: the manager's Mac and VM paths, `macEnd`, a
/// sandbox's session-end and shutdown), or a test's fake.
public protocol WorkerLauncher: Sendable {
    func info(isolation: ManagerIsolation, place: String) async -> ManagerPlaceInfo
    func sandbox(_ name: String) async -> WorkerSandboxInfo?
    /// Start it; answers what to say.
    func launch(_ o: WorkerLaunchOrder) async throws -> [String]
    /// End it (and delete its place with `rm`); answers what to say.
    func end(_ o: WorkerEndOrder) async throws -> [String]
}

/// The daemon's launcher: the core's own paths.
final class DaemonWorkerLauncher: WorkerLauncher, @unchecked Sendable {
    weak var core: HostCore?
    init(core: HostCore) { self.core = core }
    func info(isolation: ManagerIsolation, place: String) async -> ManagerPlaceInfo {
        await core?.managerPlaceInfo(isolation, place) ?? ManagerPlaceInfo()
    }
    func sandbox(_ name: String) async -> WorkerSandboxInfo? { await core?.workerSandboxInfo(name) }
    func launch(_ o: WorkerLaunchOrder) async throws -> [String] {
        guard let core else { throw HostError(.unavailable, "the daemon is stopping") }
        return try await core.launchWorker(o)
    }
    func end(_ o: WorkerEndOrder) async throws -> [String] {
        guard let core else { throw HostError(.unavailable, "the daemon is stopping") }
        return try await core.endWorker(o)
    }
}

extension HostCore {
    var workerLauncher: any WorkerLauncher { workerLauncherOverride ?? DaemonWorkerLauncher(core: self) }

    func performWorker(_ r: HostRequest) async throws -> JSONValue {
        let q = r.workerRequest ?? WorkerRequest()
        if r.op == .workerList { return try JSONValue(encoding: await workerListing(q)) }
        if r.op == .workerPlan { return try JSONValue(encoding: await workerPlan(q)) }
        guard !readOnly else { throw HostError(.unavailable, "\(r.op.rawValue) needs the daemon") }
        switch r.op {
        case .workerAdd: return try JSONValue(encoding: try await workerAdd(q))
        case .workerEnd: return try JSONValue(encoding: try await workerEnd(q))
        default: throw HostError(.invalid, "not a worker operation: \(r.op.rawValue)")
        }
    }

    // MARK: looking

    func workerListing(_ q: WorkerRequest) async throws -> WorkerListing {
        let n = try workspaceName(WorkspaceRequest(name: q.workspace))
        let rec = try workspaceRecord(n)
        let macs = rec.agents.contains { $0.place.mac == true } ? await workspaceMacRows() : [:]
        let rows = await workspaceAgents(rec, macs: macs, ended: q.all == true)
        // Each agent's condition, as `doz workspace state --json` gives it (the record's agents not ended).
        let conditions = WorkspaceConditionsBuilder.build(record: rec, facts: await recordStateFacts(rec), log: (try? workspaces.log(n)) ?? [],
                                                          from: "record")
        var out: [WorkerRow] = []
        var k = 0
        for a in rec.agents {
            if a.endedAt != nil, q.all != true { continue }
            let row = rows[k].0
            k += 1
            out.append(WorkerRow(name: a.name, role: a.isManager ? "manager" : a.isWorker ? "worker" : "adopted", bot: a.bot, place: row.place,
                                 isolation: a.isolation, control: workerControl(rec, a, macs: macs), network: workerNetwork(a, macs: macs),
                                 state: row.state, task: a.task, actsAsYou: a.actsAsYou ? true : nil, shares: workerShares(rec, a),
                                 condition: a.endedAt != nil ? nil : conditions.agents[a.name]?.condition))
        }
        // Then the workers declared at new, not started yet.
        for d in rec.declaredWorkers where !out.contains(where: { $0.name == d.name }) { out.append(declaredWorkerRow(rec, d)) }
        return WorkerListing(workspace: n, agents: out)
    }

    /// What isolates an agent: a manager's or a worker's by its isolation; an adopted one's by what it is.
    func workerControl(_ rec: WorkspaceRecord, _ a: WorkspaceAgent, macs: [String: SessionRow]) -> String {
        if a.isManager || a.isWorker { return WorkerLaunch.control(isolation: a.isolation, shares: workerShares(rec, a)) }
        if a.place.sandbox != nil { return WorkerLaunch.control(isolation: "vm") }
        if a.place.mac == true, let s = a.place.session {
            return macs[s]?.fence != nil || mac.records().sessions[s]?.fence != nil ? WorkerLaunch.control(isolation: "fenced")
                : WorkerLaunch.control(isolation: "unfenced")
        }
        return "elsewhere"
    }

    /// Its network permissions as a person reads them.
    func workerNetwork(_ a: WorkspaceAgent, macs: [String: SessionRow]) -> String {
        if let s = a.place.sandbox { return managed[s]?.config.networkName ?? "—" }
        if a.place.mac == true, let s = a.place.session {
            if let f = macs[s]?.fence { return f.preset ?? f.permissions?.joined(separator: ",") ?? "—" }
            if a.isolation == "unfenced" { return "not limited" }
            if a.isolation == nil, let r = mac.records().sessions[s], r.fence == nil { return "not limited" }
            return "—"
        }
        return "—"
    }

    // MARK: adding

    /// The first checks of an add (and of its plan), in its order: the workspace's name, the task, the workspace.
    func workerBasics(_ q: WorkerRequest) throws -> (workspace: String, task: String) {
        let n: String
        do { n = try workspaceName(WorkspaceRequest(name: q.workspace)) } catch { throw WorkerFieldRefusal.tag("workspace", error) }
        let task = (q.task ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty else { throw WorkerFieldRefusal("task", HostError(.invalid, "what is it to do? --task \"…\"")) }
        guard task.utf8.count <= WorkerLaunch.maximumTaskBytes else {
            throw WorkerFieldRefusal("task", HostError(.invalid, "the task is \(task.utf8.count) bytes — at most \(WorkerLaunch.maximumTaskBytes >> 10) KiB"))
        }
        do { _ = try workspaceRecord(n) } catch { throw WorkerFieldRefusal.tag("workspace", error) }
        return (n, task)
    }

    /// Chat as a worker needs it (nil: ready).
    static func workerChatRefusal(_ r: WorkspaceChatReadiness) -> WorkerFieldRefusal? {
        switch r {
        case .off: return WorkerFieldRefusal("workspace", HostError(.unavailable, "a worker needs chat — doz chat on"))
        case .notReady(let why): return WorkerFieldRefusal("workspace", HostError(.unavailable, "chat is on but its server is not ready (\(why)) — doz chat status"))
        case .ready: return nil
        }
    }

    /// `place`: 774, the enforcement its declared place builds for this one session (a space file's up only — never a
    /// request's field, so no caller widens a worker through it).
    func workerAdd(_ q: WorkerRequest, place: PlaceFence? = nil) async throws -> WorkerAdded {
        let (n, task) = try workerBasics(q)
        // Chat: a worker talks in the workspace's room.
        guard let chat = workspaceChat, let participants = botChat else { throw HostError(.unavailable, "a worker needs chat — doz chat on") }
        if let no = Self.workerChatRefusal(await chat.readiness()) { throw no }
        // 1. Under the gate: every check, then the entry, marked pending (nothing written on a refusal).
        await workspaceGate.lock("workspaces")
        var prepared: WorkerPrepared
        do {
            prepared = try await workerPrepare(n, q, task: task)
            prepared.placeFence = place
            var rec = prepared.record
            rec.agents.removeAll { $0.name == prepared.entry.name && $0.endedAt != nil }       // an ended one's name is free again
            rec.agents.append(prepared.entry)
            try workspaces.write(rec)
        } catch {
            workspaceGate.unlock("workspaces")
            throw error
        }
        workspaceGate.unlock("workspaces")
        let name = prepared.entry.name
        var made = WorkerMade()
        do {
            let notes = try await workerMake(prepared, chat: chat, participants: participants, made: &made)
            launchSecretSettledIfAny(made)
            _ = try await workspaceUpdate(n) { r in
                guard let i = r.agents.firstIndex(where: { $0.name == name && $0.pendingAt != nil }) else { return [] }
                r.agents[i].pendingAt = nil
                return [WorkspaceLogEntry(action: "worker-added", agent: name, place: r.agents[i].place.key, sha256: WorkspaceStore.sha256(Data(task.utf8)),
                                          bytes: task.utf8.count, isolation: prepared.isolation.rawValue, fingerprint: made.fingerprint)]
            }
            note(nil, "workspace \(n): worker \(name) added (\(prepared.isolation.rawValue), \(prepared.place)), token fp \(made.fingerprint ?? "?")")
            let listing = try await workerListing(WorkerRequest(workspace: n))
            let row = listing.agents.first { $0.name == name && $0.role == "worker" }
                ?? WorkerRow(name: name, role: "worker", bot: prepared.entry.bot, place: prepared.entry.place.display, isolation: prepared.isolation.rawValue,
                             control: WorkerLaunch.control(isolation: prepared.isolation.rawValue), network: prepared.permissions, state: "running",
                             task: task, actsAsYou: nil, shares: nil)
            return WorkerAdded(workspace: n, worker: row, session: prepared.session ?? prepared.place,
                               sandbox: prepared.isolation == .vm ? prepared.place : nil, notes: notes.isEmpty ? nil : notes)
        } catch {
            await workerUndo(prepared, made: made, participants: participants)
            let e = HostError.from(error)
            throw HostError(e.code, "\(name) did not start: \(e.message)")
        }
    }

    /// Everything an add decided before anything is written.
    struct WorkerPrepared {
        var record: WorkspaceRecord
        var entry: WorkspaceAgent
        var isolation: ManagerIsolation
        var bot: BotRecord?
        var agent: String
        var place: String
        var session: String?
        var shared: Bool
        var rooms: [String]
        var permissions: String
        var director: String?
        var cpus: Int?
        var memoryMiB: UInt64?
        var allowTools: [String]
        /// `bypass`: its own argv bypasses its permissions (marked); nil: as today.
        var permissionMode: String? = nil
        /// A look with no daemon: the checks that need one, skipped ("checked again when you add").
        var notes: [String] = []
        /// 774: its place's enforcement (`workerAdd`'s `place`).
        var placeFence: PlaceFence? = nil
    }

    /// What an add has made so far (undone in reverse when a later step fails).
    struct WorkerMade {
        var participant = false
        var secret: LaunchSecret?
        var secretOwner: String?
        var tokenFolder: String?
        var fingerprint: String?
    }

    /// The checks of an add, in the order a person fixes them (under the `workspaces` gate). Each refusal carries the
    /// request's field it is about (`WorkerFieldRefusal`; `HostError.from` gives back the add's own error). `look`: the plan's
    /// (`worker-plan`) — the same checks; with no daemon (the read-only core) those that ask the daemon about a running place
    /// are skipped and said to be checked again at the add.
    func workerPrepare(_ n: String, _ q: WorkerRequest, task: String, look: Bool = false) async throws -> WorkerPrepared {
        func no(_ field: String, _ e: HostError) -> WorkerFieldRefusal { WorkerFieldRefusal(field, e) }
        func tagged<T>(_ field: String, _ body: () throws -> T) throws -> T {
            do { return try body() } catch { throw WorkerFieldRefusal.tag(field, error) }
        }
        let rec = try tagged("workspace") { try workspaceRecord(n) }
        let skipLive = look && readOnly
        var notes: [String] = []
        guard rec.flags.archivedAt == nil, rec.flags.finishedAt == nil else {
            throw no("workspace", HostError(.invalidPhase, "\(n) is \(rec.flags.archivedAt != nil ? "archived" : "finished")"))
        }
        guard !startingWorkspaces.contains(n) else { throw no("workspace", HostError(.invalidPhase, "\(n) is starting — add the worker once its start is over")) }
        guard !lifecycleWorkspaces.contains(n) else {
            throw no("workspace", HostError(.invalidPhase, "\(n) is busy: it is being put to sleep, woken, finished or archived — add the worker once that is over"))
        }
        guard rec.flags.startedAt != nil || rec.flags.firstAgentAt != nil else {
            throw no("workspace", HostError(.invalidPhase, "\(n) is still setting up — doz workspace start \(n) first (a workspace with no manager starts with you driving), or declare workers at doz workspace new --worker TASK"))
        }
        guard let main = rec.mainRoom?.chatRoom else { throw no("workspace", HostError(.invalidPhase, "\(n) has no room — doz workspace edit \(n) --make-room")) }
        var rooms = [main]
        for label in q.rooms ?? [] {
            guard let r = rec.rooms.first(where: { $0.label == label || $0.chatRoom == label }) else {
                throw no("rooms", HostError(.notFound, "\(n) has no room \(label) (its rooms: \(rec.rooms.map(\.label).joined(separator: ", ")))"))
            }
            if !rooms.contains(r.chatRoom) { rooms.append(r.chatRoom) }
        }
        // The bot it is, when it is one.
        var bot: BotRecord?
        if let b = q.fromBot {
            if let why = ChatNames.refusal(b) { throw no("fromBot", HostError(.invalid, why)) }
            guard let rec = try tagged("fromBot", { try bots.read().bot(b) }) else { throw no("fromBot", HostError(.notFound, "\(b) is not a bot (doz bot ls)")) }
            if let at = rec.retiredAt { throw WorkerFieldRefusal.tag("fromBot", BotName.retiredRefusal(b, at)) }
            guard rec.isolation.default != "elsewhere" else {
                throw no("fromBot", HostError(.invalid, "a bot elsewhere runs on its own machine; Dozable never starts it — choose a bot that runs here"))
            }
            bot = rec
        }
        // Its isolation and program; the flags that do not go together.
        let shared = q.sandbox != nil
        let iso: ManagerIsolation = shared ? .vm
            : try tagged("isolation") { try WorkerIsolation.resolve(asked: q.isolation, workspaceDefault: rec.defaults.isolation, botDefault: bot?.isolation.default) }
        if iso == .unfenced, let refused = unfencedManagerRefusal() { throw WorkerFieldRefusal.tag("isolation", refused) }
        // 749: under the stub agent a VM worker is refused, nothing made.
        if let refused = stubVMRefusal(q.name ?? "the worker", isolation: iso) { throw WorkerFieldRefusal.tag("isolation", refused) }
        let agent = bot?.agent ?? q.agent ?? "claude-code"
        guard let program = ManagerLaunch.program(agent: agent) else {
            throw no(bot != nil ? "fromBot" : "agent", HostError(.invalid, "Dozable starts a worker running Claude Code or Codex — --agent claude-code or codex, not \(agent.prefix(40))"))
        }
        let flags = WorkerLaunch.Flags(isolation: q.isolation, sandbox: q.sandbox, session: q.session, cpus: q.cpus, memory: q.memory, agent: q.agent,
                                       fromBot: q.fromBot, name: q.name, allowTools: q.allowTools ?? [])
        if let p = WorkerLaunch.flagProblem(flags, isolation: iso, program: program) { throw no(p.field, HostError(.invalid, p.text)) }
        var memoryMiB: UInt64?
        if let m = q.memory {
            guard let v = DozableImages.parseMemory(m) else { throw no("memory", HostError(.invalid, "--memory \(m.prefix(20)): a size like 2G or 2048M")) }
            memoryMiB = v
        }
        if let c = q.cpus, !(1...64).contains(c) { throw no("cpus", HostError(.invalid, "--cpus is 1 to 64")) }
        if let pm = q.permissionMode, !WorkerLaunch.permissionModes.contains(pm) {
            throw no("permissionMode", HostError(.invalid, "--permissions is standard or bypass, not \(pm.prefix(40)) — not a preset Dozable holds yet"))
        }
        if let ns = q.newSandbox {
            guard iso == .vm, q.sandbox == nil else { throw no("newSandbox", HostError(.invalid, "a new sandbox's name goes with --isolation vm")) }
            if let why = Self.sandboxNameRefusal(ns) { throw no("newSandbox", HostError(.invalid, why)) }
        }
        if iso != .vm, buildFlavor.isHelper { throw no("isolation", HostError(.notImplemented, BuildFlavor.helperLeavesOut("sessions on this Mac"))) }
        // A bot's own rules: one role in a workspace, one live workspace, reached by polling where it is fenced.
        if let b = bot {
            if rec.manager?.bot == b.name { throw no("fromBot", HostError(.exists, "\(b.name) is \(n)'s manager — a bot plays one role in a workspace")) }
            if rec.liveWorkerIndex(b.name) != nil { throw no("fromBot", HostError(.exists, "\(b.name) already works in \(n) (doz worker ls \(n))")) }
            if let other = await liveWorkspace(of: b.name, except: n) {
                throw no("fromBot", HostError(.exists, WorkspaceSetupCheck.liveElsewhereRefusal(bot: b.name, other)))
            }
            guard b.holdsToken else { throw no("fromBot", HostError(.invalid, "\(b.name)'s token is not held by Dozable — doz bot token \(b.name) --new")) }
            if b.deliver == "inbox", iso != .unfenced {
                throw no("fromBot", HostError(.invalid, "\(b.name) is reached by inbox, which only an unfenced session gets; a fenced or VM worker polls — doz bot set \(b.name) --deliver poll"))
            }
            if b.deliver == "webhook" {
                throw no("fromBot", HostError(.invalid, "\(b.name) is reached by webhook; a worker Dozable starts collects its own messages — doz bot set \(b.name) --deliver poll"))
            }
        }
        // Its name: the bot's, as given, or the first free botN.
        let dir = try tagged("workspace") { try botDirectory() }
        let file = bots.readOrEmpty()
        var liveNames = Set<String>()
        for w in workspaces.records() { for a in w.agents where a.isLiveWorker { liveNames.insert(a.name) } }
        let here = Set(rec.agents.filter { $0.endedAt == nil }.map(\.name))
        let name: String
        if let b = bot {
            name = b.name
        } else if let given = q.name {
            if let why = ChatNames.refusal(given) { throw no("name", HostError(.invalid, why)) }
            if let e = BotName.refusal(given, human: dir.human, file: file) {
                throw no("name", e.code == .exists && file.bot(given)?.retiredAt == nil ? HostError(.exists, "\(given) is a bot — doz worker add \(n) --from-bot \(given)") : e)
            }
            if dir.has(given) { throw no("name", HostError(.exists, "\(given) is already in chat — choose another name, or leave it out")) }
            if liveNames.contains(given) { throw no("name", HostError(.exists, "\(given) is already a worker — choose another name, or leave it out")) }
            if here.contains(given) { throw no("name", HostError(.exists, "\(n) already has an agent called \(given)")) }
            name = given
        } else {
            // A worker declared anywhere keeps the name it was declared with.
            let declared = Set(workspaces.records().flatMap { $0.declaredWorkers.map(\.name) })
            let taken = Set(dir.participants.map(\.name)).union(file.bots.map(\.name)).union(liveNames).union(here)
                .union(dir.human.map { [$0] } ?? []).union(declared)
            name = WorkerLaunch.nextAnonymousName(taken: taken)
        }
        guard WorkspaceName.isValidAgent(name) else { throw no(bot != nil ? "fromBot" : "name", HostError(.invalid, "\(name) is not an agent name")) }
        do { try WorkspaceName.checkNewAgent(name) } catch { throw no(bot != nil ? "fromBot" : "name", HostError.from(error)) }
        if bot != nil, here.contains(name) { throw no("fromBot", HostError(.exists, "\(n) already has an agent called \(name)")) }
        // Its place.
        let pagePort = ChatSettingsView.read().pagePort
        var place: String
        var session: String?
        let placeField = q.session != nil ? "session" : "name"
        if let x = q.sandbox {
            guard let owner = rec.agents.first(where: { $0.endedAt == nil && $0.place.sandbox == x }) else {
                throw no("sandbox", HostError(.notFound, "\(x) is not a sandbox of \(n) — a worker joins an adopted agent's or another worker's sandbox (doz worker ls \(n))"))
            }
            if owner.isManager { throw no("sandbox", HostError(.invalid, "\(x) is the manager's sandbox — a worker never shares it")) }
            let v = WorkerLaunch.tokenVariables(name: name, shared: true)
            if skipLive {
                notes.append("whether \(x) runs, reaches the chat server and has room for \(v.variable) is checked again when you add")
            } else {
                guard let info = await workerLauncher.sandbox(x) else { throw no("sandbox", HostError(.notFound, "no sandbox \(x) (doz ls)")) }
                guard info.running else { throw no("sandbox", HostError(.invalidPhase, "\(x) is stopped — doz start \(x)")) }
                guard info.proxied else { throw no("sandbox", HostError(.invalid, "\(x) is not proxied — a worker's token is held by Dozable's proxy")) }
                guard info.hostPorts.contains(UInt16(clamping: pagePort)) else {
                    throw no("sandbox", HostError(.invalid, "\(x) does not reach the chat server's page port \(pagePort) — doz net allow \(x) host:\(pagePort)"))
                }
                guard info.variables.count < LaunchSecrets.maximum else {
                    throw no("sandbox", HostError(.invalid, "\(x) holds \(LaunchSecrets.maximum) secrets already, the most a sandbox has — end a worker there, or give this one a place of its own"))
                }
                if info.variables.contains(v.variable) { throw no("sandbox", HostError(.exists, "\(x) holds \(v.variable) already")) }
            }
            place = x
            session = name
        } else {
            place = iso == .vm ? (q.newSandbox ?? WorkerLaunch.placeName(workspace: n, name: name)) : (q.session ?? WorkerLaunch.placeName(workspace: n, name: name))
            if iso != .vm { try tagged(placeField) { try MacPlace.validateSessionName(place) } } else { session = name }
            if iso == .vm, let why = Self.sandboxNameRefusal(place) { throw no("name", HostError(.invalid, why)) }
            if skipLive {
                notes.append("whether \(iso == .vm ? "a sandbox" : "a session on this Mac") called \(place) already exists is checked again when you add")
            } else {
                let info = await workerLauncher.info(isolation: iso, place: place)
                if info.exists {
                    let ours = rec.agents.contains { $0.isWorker && $0.endedAt != nil && ($0.place.session == place || $0.place.sandbox == place) }
                    if info.running || !ours || iso == .vm {
                        throw no(iso == .vm ? "name" : placeField, HostError(.exists, iso == .vm ? "a sandbox called \(place) already exists — doz rm \(place) first"
                                        : "a session called \(place) already exists on this Mac — doz sessions end @mac \(place) twice, or --session NAME"))
                    }
                }
            }
            let member = workspaces.membership()
            if iso != .vm, let w = member["mac:" + place], w != n { throw no(placeField, HostError(.exists, "@mac/\(place) is in \(w) already — --session NAME")) }
        }
        let now = Date()
        var e = WorkspaceAgent(name: name, role: "worker",
                               place: shared ? AgentPlace(sandbox: place, session: name) : iso == .vm ? .sandbox(place) : .macSession(place),
                               startedBy: "you", startedAt: now, bot: bot?.name, isolation: iso.rawValue)
        e.task = task
        e.placeName = q.placeName.flatMap { WorkspaceName.isValidAgent($0) ? $0 : nil }
        e.anonymous = bot == nil ? true : nil
        e.pendingAt = now
        var director: String?
        if let m = rec.manager, let mb = m.bot, await managerRunning(m) { director = mb }
        return WorkerPrepared(record: rec, entry: e, isolation: iso, bot: bot, agent: agent, place: place, session: session, shared: shared,
                              rooms: rooms, permissions: rec.defaults.network ?? "locked", director: director, cpus: q.cpus, memoryMiB: memoryMiB,
                              allowTools: q.allowTools ?? [], permissionMode: q.permissionMode == "bypass" ? "bypass" : nil, notes: notes)
    }

    /// `worker-plan`: the add's checks and decisions with nothing written, no participant made, no keychain item read and
    /// nothing started — the first refusal with its field, else what the add would do; and the command.
    func workerPlan(_ q: WorkerRequest) async -> WorkerPlan {
        var plan = WorkerPlan(workspace: q.workspace ?? "", command: WorkerAddCommand.text(q))
        if let note = WorkerAddCommand.taskFileNote(q) { plan.notes.append(note) }
        do {
            let (n, task) = try workerBasics(q)
            let (readiness, assumed) = await workspaceLookReadiness(look: true)
            if let no = Self.workerChatRefusal(readiness) { throw no }
            if assumed { plan.notes.append("no daemon runs: chat is judged from its setting, and checked again when you add") }
            let p = try await workerPrepare(n, q, task: task, look: true)
            plan.workspace = n
            plan.name = p.entry.name
            plan.agent = p.agent
            let program = ManagerLaunch.program(agent: p.agent)
            switch p.isolation {
            case .unfenced: plan.account = nil
            case .vm: plan.account = p.bot?.account ?? accountStore.load().defaultAccount(for: program == "codex" ? "codex" : "claude-code")
            case .fenced: plan.account = p.bot?.account ?? DozableSettings.load().string(SettingKey.macAccount) ?? "mac"
            }
            plan.isolation = p.isolation.rawValue
            plan.place = p.entry.place.display
            plan.session = p.session ?? (p.isolation == .vm ? nil : p.place)
            plan.sandbox = p.isolation == .vm ? p.place : nil
            plan.folder = p.record.mainFolder?.path ?? Workspace.defaultPath(name: n) + "/" + p.entry.name
            plan.network = p.isolation == .unfenced ? "not limited" : p.permissions
            plan.shares = p.shared ? p.place : nil
            plan.control = WorkerLaunch.control(isolation: p.isolation.rawValue, shares: plan.shares)
            plan.rooms = p.rooms
            plan.allowTools = p.isolation == .fenced && program == "claude" ? WorkerLaunch.defaultAllowedTools + p.allowTools : []
            plan.actsAsYou = p.isolation == .unfenced
            plan.director = p.director ?? "you"
            plan.notes += p.notes
            if p.shared { plan.notes.append("\(p.entry.name) shares \(p.place): workers there can read each other's placeholders") }
        } catch {
            let t = WorkerFieldRefusal.tag("workspace", error)
            plan.problem = WorkerPlanProblem(field: t.field, text: t.error.message, code: t.error.code.rawValue)
        }
        plan.lines = WorkerPlanLines.lines(plan)
        return plan
    }

    // MARK: declared at new

    /// The names an anonymous worker may not take: chat's participants and its human, every bot, every live worker and every
    /// worker declared anywhere.
    func workerTakenNames() -> Set<String> {
        var s = Set(bots.readOrEmpty().bots.map(\.name))
        if let dir = try? botDirectory() {
            s.formUnion(dir.participants.map(\.name))
            if let h = dir.human { s.insert(h) }
        }
        for w in workspaces.records() {
            for a in w.agents where a.isLiveWorker { s.insert(a.name) }
            for d in w.declaredWorkers { s.insert(d.name) }
        }
        return s
    }

    /// The workers `new --worker TASK` declares: each task checked as `worker add --task` checks it, each given the first free
    /// `botN` (`workerTakenNames`, and `taken` — the new workspace's own agents). Nothing is made.
    func workspaceDeclareWorkers(_ tasks: [String], taken here: Set<String>, at now: Date) throws -> [WorkspaceDeclaredWorker] {
        guard tasks.count <= WorkerLaunch.maximumDeclared else {
            throw HostError(.invalid, "at most \(WorkerLaunch.maximumDeclared) workers at new — add more with doz worker add once it has started")
        }
        var taken = workerTakenNames().union(here)
        var out: [WorkspaceDeclaredWorker] = []
        for t in tasks {
            let task = t.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !task.isEmpty else { throw HostError(.invalid, "--worker: what is it to do? --worker \"…\"") }
            guard task.utf8.count <= WorkerLaunch.maximumTaskBytes else {
                throw HostError(.invalid, "--worker: the task is \(task.utf8.count) bytes — at most \(WorkerLaunch.maximumTaskBytes >> 10) KiB")
            }
            let name = WorkerLaunch.nextAnonymousName(taken: taken)
            taken.insert(name)
            out.append(WorkspaceDeclaredWorker(name: name, task: task, declaredAt: now))
        }
        return out
    }

    /// `workspace-start`'s last step: each worker declared at `new` added as `doz worker add W NAME --task TASK` adds it (the
    /// workspace's default isolation), its declaration gone once it runs. Its name taken since: the next free `botN`. One that
    /// does not start stays declared — said, and the next start tries it again.
    func startDeclaredWorkers(_ n: String) async -> (started: [String], notes: [String]) {
        guard let rec = try? workspaceRecord(n), !rec.declaredWorkers.isEmpty else { return ([], []) }
        var started: [String] = [], notes: [String] = []
        for d in rec.declaredWorkers {
            let key = n + "/" + d.name
            guard startingDeclaredWorkers.insert(key).inserted else { continue }
            defer { startingDeclaredWorkers.remove(key) }
            var q = WorkerRequest(workspace: n, name: d.name)
            q.task = d.task
            do {
                let added: WorkerAdded
                do { added = try await workerAdd(q) } catch let e as WorkerFieldRefusal where e.field == "name" && e.error.code == .exists {
                    q.name = nil
                    added = try await workerAdd(q)
                }
                _ = try await workspaceUpdate(n) { r in r.declaredWorkers.removeAll { $0 == d }; return [] }
                started.append(added.worker.name)
            } catch {
                var why = HostError.from(error).message
                for prefix in [d.name, q.name ?? d.name].map({ $0 + " did not start: " }) where why.hasPrefix(prefix) { why = String(why.dropFirst(prefix.count)) }
                notes.append("the worker \(d.name) (\(WorkerLaunch.shortTask(d.task))) did not start: \(why) — doz workspace start \(n) tries it again")
            }
        }
        return (started, notes)
    }

    /// A declared worker as `doz worker ls` shows it: where it will run (the workspace's default isolation), not started.
    func declaredWorkerRow(_ rec: WorkspaceRecord, _ d: WorkspaceDeclaredWorker) -> WorkerRow {
        let iso = (try? WorkerIsolation.resolve(asked: nil, workspaceDefault: rec.defaults.isolation, botDefault: nil)) ?? .fenced
        let place = WorkerLaunch.placeName(workspace: rec.name, name: d.name)
        return WorkerRow(name: d.name, role: "worker", bot: nil, place: iso == .vm ? place : MacPlace.name + "/" + place, isolation: iso.rawValue,
                         control: WorkerLaunch.control(isolation: iso.rawValue), network: rec.defaults.network ?? "locked", state: "not-started",
                         task: d.task, actsAsYou: nil, shares: nil, condition: "not-started", declared: true)
    }

    /// A sandbox name a worker's place must be (nil: fine).
    static func sandboxNameRefusal(_ s: String) -> String? {
        WorkspaceName.isValid(s) ? nil : "\(s) is not a sandbox name — a shorter workspace or worker name"
    }

    /// The participant, the invites, the token, the launch.
    func workerMake(_ p: WorkerPrepared, chat: WorkspaceChat, participants: BotChat, made: inout WorkerMade) async throws -> [String] {
        let n = p.record.name, name = p.entry.name
        var notes: [String] = []
        // 2. An anonymous worker's throwaway participant (polls; removed at end).
        var token: String?
        if p.bot == nil {
            let t = ChatTokens.make()
            await botGate.lock("bots")
            do {
                if try participants.directory().has(name) || bots.readOrEmpty().bot(name) != nil {
                    throw HostError(.exists, "\(name) was taken in chat just now — try again")
                }
                try await participants.add(name, token: t, kind: BotKinds.kind(forAgent: p.agent), deliver: "poll", entry: nil, session: nil)
            } catch {
                botGate.unlock("bots")
                throw error
            }
            botGate.unlock("bots")
            made.participant = true
            token = t
        }
        // 3. Invited to the main room, and the rooms named.
        for room in p.rooms {
            if try chat.invite(room: room, name: name) {
                try? workspaces.append(n, WorkspaceLogEntry(action: "bot-invited", agent: name, room: room))
                if room == p.rooms.first { logAgentJoined(n, agent: name, room: room) }
            }
        }
        // 4. Its token and START.
        let pagePort = ChatSettingsView.read().pagePort
        let workdir = try workerFolder(p.record, name: name)
        let instructions = p.bot.flatMap { bots.readInstructions($0.name) }
        let place: WorkerKickoff.Where = p.shared ? .shared(p.place) : p.isolation == .vm ? .vm : p.isolation == .unfenced ? .unfenced : .fenced
        let start = Data(WorkerKickoff.startText(name: name, workspace: n, room: p.rooms[0], task: p.entry.task ?? "", director: p.director, place: place,
                                                 skills: p.bot?.skills ?? [], instructions: instructions).utf8)
        let vars = WorkerLaunch.tokenVariables(name: name, shared: p.shared)
        let plan: ManagerLaunch.Plan
        switch p.isolation {
        case .fenced, .vm:
            let startFile = p.isolation == .vm ? "~/" + WorkerLaunch.vmStartFolder + "/" + name + "/start.md"
                : MacFence.sessionFolder(try mac.fencePlaces(), session: p.place) + "/etc/worker/start.md"
            let secret: LaunchSecret
            if let b = p.bot {
                secret = try botLaunchSecret(b.name, port: pagePort, variable: vars.variable, fileVariable: vars.fileVariable)
            } else {
                let owner = p.isolation == .vm ? p.place : LaunchSecrets.macOwner(p.place)
                secret = try daemonWorkerSecret(owner: owner, token: token ?? "", variable: vars.variable, fileVariable: vars.fileVariable, port: pagePort)
                made.secretOwner = owner
            }
            made.secret = secret
            made.fingerprint = secret.fingerprint
            var pl = try WorkerLaunch.plan(isolation: p.isolation, agent: p.agent, model: p.bot?.model, bot: p.bot?.name, startFile: startFile,
                                           pagePort: pagePort, fingerprint: secret.fingerprint, name: name, shared: p.shared,
                                           allowTools: p.isolation == .fenced ? p.allowTools : [], permissionMode: p.permissionMode)
            pl.secret = secret
            plan = pl
        case .unfenced:
            if let no = unfencedManagerRefusal() { throw no }
            TestSafety.enforce(TestSafety.managerTokenViolation(store: store.root))
            let value: String
            if let b = p.bot {
                guard let v = services.keychain.read(service: botService(b.name), account: Keychain.user).value,
                      BotTokens.fingerprint(v) == b.token.fingerprint else {
                    throw HostError(.unavailable, "\(b.name)'s token cannot be read from the login keychain — unlock it, or doz bot token \(b.name) --new")
                }
                value = v
            } else {
                value = token ?? ""
            }
            let dir = workerTokenFolder(p.place)
            let files = try writeAgentTokenFolder(dir, token: value, start: start, who: name)
            made.tokenFolder = dir
            made.fingerprint = BotTokens.fingerprint(value)
            notes.append("unfenced: \(name) acts as you; its token is in a 0600 file named by $\(ManagerLaunch.tokenFileVariable), deleted at doz worker end")
            if let b = p.bot { notes += await pointBotInbox(n, bot: b, place: p.place) }
            plan = try WorkerLaunch.plan(isolation: .unfenced, agent: p.agent, model: p.bot?.model, bot: p.bot?.name, startFile: files.startFile,
                                         pagePort: pagePort, fingerprint: made.fingerprint ?? "", tokenFile: files.tokenFile, name: name, shared: false,
                                         permissionMode: p.permissionMode)
        }
        if p.shared { notes.append("\(name) shares \(p.place): workers there can read each other's placeholders") }
        // 5. Its session or sandbox.
        var order = WorkerLaunchOrder(workspace: n, name: name, isolation: p.isolation, place: p.place, session: p.session, shared: p.shared,
                                      workdir: workdir, plan: plan, start: start, agent: p.agent, account: p.bot?.account, model: p.bot?.model,
                                      permissions: p.permissions, cpus: p.cpus, memoryMiB: p.memoryMiB)
        order.placeFence = try Self.placeFence(p.placeFence, isolation: p.isolation, workdir: workdir, shared: p.shared)
        if let pf = order.placeFence { notes += Self.placeFenceNotes(pf, isolation: p.isolation) }
        notes += try await workerLauncher.launch(order)
        return notes
    }

    /// 774: a place's enforcement checked against this session's own folder: a fenced session's own folder is always
    /// read-write (listed read-write: dropped; read-only: refused — the fence cannot narrow its own folder); a sandbox
    /// shares exactly that folder at /workspace, read-write, and nothing else (another folder, or read-only: refused). A
    /// sandbox another agent made already keeps its own network and credentials (they are set when it is made).
    static func placeFence(_ f: PlaceFence?, isolation: ManagerIsolation, workdir: String, shared: Bool) throws -> PlaceFence? {
        guard var f else { return nil }
        let own = WorkspaceStore.resolved(workdir)
        func same(_ p: String) -> Bool { WorkspaceStore.resolved(p) == own }
        switch isolation {
        case .unfenced: return nil
        case .fenced:
            if let ro = f.read.first(where: same) {
                throw HostError(.invalid, "place \(f.place): its view makes \(DisplayPath.tilde(ro)) read-only, but that is the session's own folder, which a fence always lets it write — use another folder, or rw")
            }
            f.write.removeAll(where: same)
            if f.keys != nil { throw HostError(.invalid, "place \(f.place): a fence holds no key accounts") }
        case .vm:
            if let other = (f.read + f.write).first(where: { !same($0) }) ?? f.read.first {
                throw HostError(.invalid, "place \(f.place): a sandbox shares one folder, read-write, at /workspace (\(DisplayPath.tilde(own))) — its view can't hold \(DisplayPath.tilde(other))\(f.read.isEmpty ? "" : " read-only")")
            }
            if f.sshAgent == true { throw HostError(.invalid, "place \(f.place): a sandbox has no SSH agent of yours") }
            f.read = []; f.write = []
        }
        return f
    }

    static func placeFenceNotes(_ f: PlaceFence, isolation: ManagerIsolation) -> [String] {
        var parts: [String] = []
        if let n = f.network { parts.append("network \(n.joined(separator: " "))") }
        if !f.read.isEmpty { parts.append("read-only " + f.read.map { DisplayPath.tilde($0) }.joined(separator: ", ")) }
        if !f.write.isEmpty { parts.append("read-write " + f.write.map { DisplayPath.tilde($0) }.joined(separator: ", ")) }
        if let g = f.github { parts.append("GitHub as you (\(g))") }
        if f.sshAgent == true { parts.append("the SSH agent") }
        if let k = f.keys { parts.append("keys " + k.joined(separator: ", ")) }
        guard !parts.isEmpty else { return [] }
        return ["\(isolation == .vm ? "its sandbox" : "its fence"), from the place \(f.place): " + parts.joined(separator: "; ")]
    }

    /// A failed add, undone in reverse: the token file, the secret, the participant, the entry.
    func workerUndo(_ p: WorkerPrepared, made: WorkerMade, participants: BotChat) async {
        if let d = made.tokenFolder { try? FileManager.default.removeItem(atPath: d) }
        if let s = made.secret, let owner = made.secretOwner {
            forgetLaunchSecret(owner: owner, s)
            launchSecretSettled(owner: owner, s)
            sweepLaunchSecrets()
        }
        if made.participant { try? await participants.remove(p.entry.name) }
        _ = try? await workspaceUpdate(p.record.name) { r in
            r.agents.removeAll { $0.name == p.entry.name && $0.pendingAt != nil }
            return []
        }
    }

    func launchSecretSettledIfAny(_ made: WorkerMade) {
        if let s = made.secret, let owner = made.secretOwner { launchSecretSettled(owner: owner, s) }
    }

    /// A worker's folder: the workspace's main one, else `<projects_dir>/<workspace>/<name>` (made 0700).
    func workerFolder(_ rec: WorkspaceRecord, name: String) throws -> String {
        if let f = rec.mainFolder?.path { return f }
        // Resolved first (`/var` and `/tmp` are links, which the folder's walk refuses).
        let parent = WorkspaceStore.resolved(Workspace.defaultPath(name: rec.name))
        let p = parent + "/" + name
        TestSafety.checkMadeFolder(p)
        do {
            try MacFenceHostFS.ensureDirectory(parent, mode: 0o700)
            try MacFenceHostFS.ensureDirectory(p, mode: 0o700)
        } catch {
            throw HostError(.failed, "cannot make \(DisplayPath.tilde(p)) for the worker: \(error)")
        }
        return WorkspaceStore.resolved(p)
    }

    // MARK: ending

    func workerEnd(_ q: WorkerRequest) async throws -> WorkerEnded {
        let n = try workspaceName(WorkspaceRequest(name: q.workspace))
        guard let name = q.name, !name.isEmpty else { throw HostError(.invalid, "which worker? (doz worker ls \(n))") }
        let rec = try workspaceRecord(n)
        guard let i = rec.liveWorkerIndex(name) else {
            if let a = rec.agents.first(where: { $0.name == name }) {
                if a.isManager { throw HostError(.invalid, "\(name) is \(n)'s manager — doz workspace stop \(n)") }
                if !a.isWorker { throw HostError(.invalid, "\(name) was adopted, not added — doz workspace release \(n) \(name)") }
                if q.rm == true, let e = rec.agents.last(where: { $0.name == name && $0.isWorker }) { return try await workerRemovePlace(n, e) }
                throw HostError(.invalidPhase, "\(name) has ended already")
            }
            throw HostError(.notFound, "\(name) is not a worker of \(n) (doz worker ls \(n))")
        }
        let a = rec.agents[i]
        guard a.pendingAt == nil else { throw HostError(.invalidPhase, "\(name) is still being added — try again in a moment") }
        let iso = ManagerIsolation(rawValue: a.isolation ?? "fenced") ?? .fenced
        let shared = a.place.sandbox != nil && a.place.session != nil
        let place = a.place.sandbox ?? a.place.session ?? name
        if q.rm == true, shared {
            throw HostError(.invalid, "\(name) runs in \(place), which it shares — --rm deletes only a worker's own place; doz worker end \(n) \(name)")
        }
        let vars = WorkerLaunch.tokenVariables(name: name, shared: shared)
        let order = WorkerEndOrder(workspace: n, name: name, isolation: iso, place: place, session: shared ? name : (iso == .vm ? name : nil),
                                   shared: shared, rm: q.rm == true, variable: iso == .unfenced ? nil : vars.variable)
        var notes = try await workerLauncher.end(order)
        // Its token: a throwaway one revoked (the participant leaves every room; its old messages keep its name); a bot's kept.
        if a.anonymous == true {
            if iso != .unfenced {
                let owner = iso == .vm ? place : LaunchSecrets.macOwner(place)
                forgetLaunchSecret(owner: owner, LaunchSecret(variable: vars.variable, fileVariable: vars.fileVariable, host: HostRoute.hostName,
                                                              port: 0, fingerprint: "",
                                                              keychainService: LaunchSecrets.service(store: store.root, owner: owner, variable: vars.variable)))
            }
            if let participants = botChat, (try? participants.directory().participants.contains { $0.name == name }) == true {
                do { try await participants.remove(name) } catch { notes.append("\(name) is still in chat: \(HostError.from(error).message)") }
            }
        } else if let b = a.bot {
            notes.append("\(b)'s token is kept; it stays a member of the room")
        }
        if iso == .unfenced { try? FileManager.default.removeItem(atPath: workerTokenFolder(place)) }
        _ = try await workspaceUpdate(n) { r in
            guard let j = r.liveWorkerIndex(name) else { return [] }
            r.agents[j].endedAt = Date()
            r.agents[j].pendingAt = nil
            return [WorkspaceLogEntry(action: "worker-ended", agent: name, place: r.agents[j].place.key, isolation: iso.rawValue)]
        }
        note(nil, "workspace \(n): worker \(name) ended" + (q.rm == true ? ", its place deleted" : ""))
        return WorkerEnded(workspace: n, name: name, removed: q.rm == true, notes: notes.isEmpty ? nil : notes)
    }

    /// `end --rm` of a worker already ended: the place it kept (its session's record, or its own sandbox) deleted.
    func workerRemovePlace(_ n: String, _ a: WorkspaceAgent) async throws -> WorkerEnded {
        let iso = ManagerIsolation(rawValue: a.isolation ?? "fenced") ?? .fenced
        let shared = a.place.sandbox != nil && a.place.session != nil
        let place = a.place.sandbox ?? a.place.session ?? a.name
        if shared { throw HostError(.invalid, "\(a.name) ran in \(place), which it shares — --rm deletes only a worker's own place") }
        let notes = try await workerLauncher.end(WorkerEndOrder(workspace: n, name: a.name, isolation: iso, place: place,
                                                               session: iso == .vm ? a.name : nil, shared: false, rm: true, variable: nil))
        try? workspaces.append(n, WorkspaceLogEntry(action: "worker-ended", agent: a.name, place: a.place.key, reason: "its place deleted"))
        return WorkerEnded(workspace: n, name: a.name, removed: true, notes: notes.isEmpty ? nil : notes)
    }

    // MARK: the daemon's launcher

    func workerSandboxInfo(_ x: String) async -> WorkerSandboxInfo? {
        guard let m = managed[x] else { return nil }
        let phase = await effectivePhase(m)
        let egress = m.sandbox.egress
        return WorkerSandboxInfo(running: phase == .running, proxied: egress != nil, hostPorts: egress?.hostPorts.map(\.port) ?? [],
                                 variables: (m.config.secrets ?? []).map(\.variable))
    }

    func launchWorker(_ o: WorkerLaunchOrder) async throws -> [String] {
        switch o.isolation {
        case .fenced, .unfenced:
            guard !buildFlavor.isHelper else { throw HostError(.notImplemented, BuildFlavor.helperLeavesOut("sessions on this Mac")) }
            if o.restart, let rec = mac.records().sessions[o.place] { return try await relaunchWorkerOnMac(o, rec) }
            // 749: the stub agent in its place under DOZ_TEST_STUB_AGENT (guarded runs only), told its task.
            let task = (try? workspaceRecord(o.workspace))?.agents.last { $0.name == o.name && $0.isWorker }?.task
            let program = agentMacProgram(argv: o.plan.argv, environment: o.plan.environment, account: o.account, workspace: o.workspace,
                                          name: o.name, task: task)
            var launch = AgentMacLaunch(place: o.place, argv: program.argv, workdir: o.workdir, environment: program.environment,
                                        fenced: o.isolation == .fenced, permissions: o.permissions, hostPorts: o.plan.hostPorts,
                                        account: program.account, secrets: o.plan.secret.map { [$0] },
                                        start: o.isolation == .fenced ? o.start : nil, startFolder: "worker", bridgesOff: true)
            launch.placeFence = o.isolation == .fenced ? o.placeFence : nil
            return try await launchAgentOnMac(launch)
        case .vm:
            if let no = stubVMRefusal(o.name, isolation: .vm) { throw no }
            guard let secret = o.plan.secret else { throw HostError(.invalid, "a VM worker needs its token's launch secret") }
            // The guarded seams: the lab image and a FAKE worker program (its first prompt appended, so it finds START).
            let seams = TestSafety.workerSeams()
            let session = o.session ?? o.name
            var vmLaunch = AgentVMLaunch(
                sandbox: o.place, session: session, create: !o.shared, workdir: o.workdir, permissions: o.permissions, account: o.account,
                model: o.model, agent: o.agent, hostPorts: o.plan.hostPorts, secret: secret, start: o.start,
                startDir: WorkerLaunch.vmStartFolder + "/" + o.name,
                argv: seams.argv.map { $0 + [ManagerLaunch.firstPrompt(start: o.plan.startFile)] }
                    ?? (o.restart ? ManagerLaunch.vmResumeArgv(agent: o.agent) : nil) ?? o.plan.argv,
                environment: o.plan.environment, seamImage: seams.image, cpus: o.cpus,
                memoryMiB: o.memoryMiB, bridgesOff: true, alias: o.shared ? secret.variable : nil)
            vmLaunch.placeFence = o.placeFence
            return try await launchAgentInVM(vmLaunch)
        }
    }

    /// A worker's session on this Mac opened again in place (a wake): its record's program, its conversation resumed, its
    /// kept secrets (a bot's given again), START rewritten under `etc/worker/` (fenced).
    func relaunchWorkerOnMac(_ o: WorkerLaunchOrder, _ rec: MacSessionRecord) async throws -> [String] {
        let located = MacDeckhold.locate()
        guard let holder = located.url else {
            throw HostError(.unavailable, "sessions on this Mac need deckhold-mac beside doz — \(located.why ?? "it is not there")")
        }
        let fenced = o.isolation == .fenced
        guard (rec.fence != nil) == fenced else {
            throw HostError(.invalid, "the session \(o.place) on this Mac is \(fenced ? "unfenced" : "fenced") — doz worker end \(o.workspace) \(o.name), then add it again")
        }
        await sessionGate.lock(MacPlace.name)
        defer { sessionGate.unlock(MacPlace.name) }
        let held = await macLearnClaudeID(o.place)
        let how = try await mac.end(o.place)
        if how == .stuck { throw HostError(.failed, "session \(o.place) on this Mac did not end, even after SIGKILL") }
        let r = try await macReopen(o.place, rec: mac.records().sessions[o.place] ?? rec, holder: holder, fresh: false,
                                    size: TermSize(cols: 120, rows: 40), knownID: held, ended: how.rawValue,
                                    request: HostRequest(.sessionRestart, name: MacPlace.name), extra: agentMacReopenEnvironment(o.plan.environment),
                                    botSecrets: o.plan.secret.map { [$0] }, managerStart: fenced ? o.start : nil, startFolder: "worker")
        return r.notice.map { [$0] } ?? []
    }

    func endWorker(_ o: WorkerEndOrder) async throws -> [String] {
        var notes: [String] = []
        switch o.isolation {
        case .fenced, .unfenced:
            guard !buildFlavor.isHelper else { throw HostError(.notImplemented, BuildFlavor.helperLeavesOut("sessions on this Mac")) }
            var r = HostRequest(.sessionEnd, name: MacPlace.name)
            r.session = o.place
            if await mac.isRunning(o.place) { _ = try await macEnd(r) }
            // Its token's secret leaves the session's record (and so its vault, at any later open).
            if let v = o.variable {
                await sessionGate.lock(MacPlace.name)
                await mac.updateRecord(o.place) { rec in rec.fence?.secrets?.removeAll { $0.variable == v } }
                sessionGate.unlock(MacPlace.name)
            }
            if o.rm, mac.records().sessions[o.place] != nil { _ = try await macEnd(r) }
            else { notes.append("its session's record is kept (@mac/\(o.place)) — --rm deletes it") }
        case .vm:
            guard let m = managed[o.place] else { return ["its sandbox \(o.place) is gone"] }
            let phase = await effectivePhase(m)
            if phase == .running, let s = o.session {
                var r = HostRequest(.sessionEnd, name: o.place)
                r.session = s
                let a = await handle(r)
                if let e = a.error, o.shared { notes.append("its session \(s) in \(o.place): \(e.message)") }
            }
            if o.shared {
                // Only its own secret leaves the sandbox; the sandbox and the other agents in it go on.
                if let v = o.variable, let mm = managed[o.place] {
                    let kept = (mm.config.secrets ?? []).filter { $0.variable != v }
                    mm.config.secrets = kept.isEmpty ? nil : kept
                    try mm.config.write(store.configFile(mm.name))
                    applyLaunchSecrets(mm)
                }
                return notes
            }
            if phase == .running || phase == .booting || phase == .paused {
                let a = await handle(HostRequest(.shutdown, name: o.place))
                if let e = a.error { throw HostError(e.code, e.message) }
            }
            if o.rm {
                let a = await handle(HostRequest(.rm, name: o.place))
                if let e = a.error { throw HostError(e.code, e.message) }
            } else {
                notes.append("its sandbox \(o.place) is stopped and kept (its disk) — --rm deletes it")
            }
        }
        return notes
    }

    // MARK: the sweep

    /// At a daemon's start: a worker entry left pending (a daemon that died mid-add) whose place does not run is undone —
    /// its throwaway participant, its secret, its token file, the entry (logged `worker-add-undone`); one whose place runs
    /// is simply no longer pending. Never in the read-only core.
    public func sweepPendingWorkers() async {
        guard !readOnly else { return }
        for w in workspaces.records() {
            for a in w.agents where a.isWorker && a.pendingAt != nil {
                let iso = ManagerIsolation(rawValue: a.isolation ?? "fenced") ?? .fenced
                let shared = a.place.sandbox != nil && a.place.session != nil
                let place = a.place.sandbox ?? a.place.session ?? a.name
                var running = await workerLauncher.info(isolation: iso, place: place).running
                if shared, running, let m = managed[place] {
                    let v = WorkerLaunch.tokenVariables(name: a.name, shared: true).variable
                    running = m.config.secrets?.contains { $0.variable == v } == true
                }
                if running {
                    _ = try? await workspaceUpdate(w.name) { r in
                        if let i = r.agents.firstIndex(where: { $0.name == a.name && $0.pendingAt != nil }) { r.agents[i].pendingAt = nil }
                        return []
                    }
                    continue
                }
                if a.anonymous == true, let participants = botChat, (try? participants.directory().participants.contains { $0.name == a.name }) == true {
                    try? await participants.remove(a.name)
                }
                let vars = WorkerLaunch.tokenVariables(name: a.name, shared: shared)
                if iso == .vm, let m = managed[place], m.config.secrets?.contains(where: { $0.variable == vars.variable }) == true {
                    let kept = (m.config.secrets ?? []).filter { $0.variable != vars.variable }
                    m.config.secrets = kept.isEmpty ? nil : kept
                    try? m.config.write(store.configFile(m.name))
                }
                if iso == .unfenced { try? FileManager.default.removeItem(atPath: workerTokenFolder(place)) }
                _ = try? await workspaceUpdate(w.name) { r in
                    r.agents.removeAll { $0.name == a.name && $0.pendingAt != nil }
                    return [WorkspaceLogEntry(by: "doz", action: "worker-add-undone", agent: a.name, place: a.place.key,
                                              reason: "the daemon stopped before it ran")]
                }
                HostLog.line("workspaces: \(w.name): worker \(a.name) left pending by a daemon that stopped — undone")
            }
        }
        sweepLaunchSecrets()
    }
}
