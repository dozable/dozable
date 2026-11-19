import DozableKit
import Foundation

/// How the chat server looks to the workspaces: whether it is on and ready, its rooms, and making a room AS YOU (with
/// every human). The daemon's is `OwnerWorkspaceChat` (the supervisor + `ChatOwnerRooms`); tests give a fake.
public protocol WorkspaceChat: Sendable {
    /// Waits for a starting server (at most 15 s).
    func readiness() async -> WorkspaceChatReadiness
    func rooms() throws -> Set<String>
    func makeRoom(_ name: String) throws
    /// Post `content` in `room` as you (a workspace's kick-off).
    func post(room: String, content: String) throws
    /// Invite a participant to `room` as you; false: it was a member already.
    @discardableResult func invite(room: String, name: String) throws -> Bool
}

public enum WorkspaceChatReadiness: Equatable, Sendable {
    case off
    case notReady(String)
    case ready
}

/// The daemon's: `ready` asks the supervisor (`ChatSupervisor.sync(waitReady:)`), rooms are made over the owner's socket.
public struct OwnerWorkspaceChat: WorkspaceChat {
    let ready: @Sendable () async -> WorkspaceChatReadiness
    let owner: ChatOwnerRooms
    public init(ready: @escaping @Sendable () async -> WorkspaceChatReadiness, owner: ChatOwnerRooms) { self.ready = ready; self.owner = owner }
    public func readiness() async -> WorkspaceChatReadiness { await ready() }
    public func rooms() throws -> Set<String> { Set(try owner.state().rooms.keys) }
    public func makeRoom(_ name: String) throws {
        try owner.makeRoom(name, members: try owner.state().otherHumans)
    }
    public func post(room: String, content: String) throws { try owner.post(room: room, content: content) }
    @discardableResult public func invite(room: String, name: String) throws -> Bool { try owner.invite(room: room, name: name) }
}

/// The workspaces in the daemon (`workspace-*`). Reading (ls, show, log) is answered in-process by a read-only core too;
/// every change holds the `workspaces` gate, checks everything first and only then writes (`workspace.json` and the log —
/// never a sandbox's `doz.json` nor `mac-sessions/sessions.json`). `docs/engineering/workspaces.md`.
extension HostCore {
    nonisolated var workspaces: WorkspaceStore { WorkspaceStore(store: store) }

    func performWorkspace(_ r: HostRequest) async throws -> JSONValue {
        let w = r.workspaceRequest ?? WorkspaceRequest()
        switch r.op {
        case .workspaceList:
            return try JSONValue(encoding: await workspaceListing(looseOnly: w.loose == true))
        case .workspaceShow:
            let rec = try workspaceRecord(try workspaceName(w))
            return try JSONValue(encoding: await workspaceDetail(rec, withBrief: w.withBrief == true))
        case .workspaceLog:
            let n = try workspaceName(w)
            _ = try workspaceRecord(n)
            return try JSONValue(encoding: try workspaces.log(n, since: w.since))
        default:
            break
        }
        guard !readOnly else { throw HostError(.unavailable, "\(r.op.rawValue) needs the daemon") }
        // Start and stop take the gate themselves: the check under `workspaces`, the launch under `workspace:NAME`.
        if r.op == .workspaceStart { return try JSONValue(encoding: try await workspaceStart(w)) }
        if r.op == .workspaceStop { return try JSONValue(encoding: try await workspaceStop(w)) }
        await workspaceGate.lock("workspaces")
        defer { workspaceGate.unlock("workspaces") }
        switch r.op {
        case .workspaceNew: return try JSONValue(encoding: try await workspaceNew(w))
        case .workspaceAdopt: return try JSONValue(encoding: try await workspaceAdopt(w))
        case .workspaceRelease: return try JSONValue(encoding: try await workspaceRelease(w))
        case .workspaceEdit: return try JSONValue(encoding: try await workspaceEdit(w))
        case .workspaceRename: return try JSONValue(encoding: try await workspaceRename(w))
        default: throw HostError(.invalid, "not a workspace operation: \(r.op.rawValue)")
        }
    }

    // MARK: looking

    func workspaceName(_ w: WorkspaceRequest) throws -> String {
        guard let n = w.name, !n.isEmpty else { throw HostError(.invalid, "which workspace? (doz workspace ls)") }
        try WorkspaceName.validate(n)
        return n
    }

    func workspaceRecord(_ n: String) throws -> WorkspaceRecord {
        guard let r = try workspaces.read(n) else { throw HostError(.notFound, "\(n) is not a workspace (doz workspace ls)") }
        return r
    }

    /// The sessions on this Mac by name (none in a build without them).
    func workspaceMacRows() async -> [String: SessionRow] {
        guard !buildFlavor.isHelper else { return [:] }
        var out: [String: SessionRow] = [:]
        for r in await macRows() { out[r.name] = r }
        return out
    }

    /// Each agent as it is now, and what the state derivation sees of it (nil: not an agent now — an ended worker). Ended
    /// workers are left out unless `ended`.
    func workspaceAgents(_ rec: WorkspaceRecord, macs: [String: SessionRow], ended: Bool = false) async -> [(WorkspaceAgentRow, WorkspaceState.Agent?)] {
        var out: [(WorkspaceAgentRow, WorkspaceState.Agent?)] = []
        for a in rec.agents {
            if a.endedAt != nil, !ended { continue }
            var state = "gone", seen = WorkspaceState.Agent.asleep
            if let s = a.place.sandbox {
                if let m = managed[s] {
                    let phase = await effectivePhase(m).rawValue
                    state = phase
                    // A worker in a sandbox it shares counts by its own session only.
                    let mine = a.isWorker && a.place.session != nil ? statuses[s]?[a.place.session!].map { [$0] } : statuses[s].map { Array($0.values) }
                    seen = WorkspaceState.agent(phase: phase, statuses: mine)
                } else if a.isManager {
                    state = "not started"; seen = .notStarted
                }
            } else if a.place.mac == true, let s = a.place.session {
                let row = macs[s]
                if row == nil, a.isManager {
                    state = "not started"; seen = .notStarted
                } else {
                    state = row == nil || row?.gone == true ? "gone" : row!.ended ? "ended" : "running"
                    seen = WorkspaceState.agent(macRow: row)
                }
            } else {
                state = "elsewhere"
            }
            var counted: WorkspaceState.Agent? = seen
            if a.isWorker {
                counted = WorkspaceState.worker(pending: a.pendingAt != nil, ended: a.endedAt != nil, place: seen)
                if a.endedAt != nil { state = "ended" } else if a.pendingAt != nil { state = "starting" }
            }
            out.append((WorkspaceAgentRow(name: a.name, role: a.role, place: a.place.display, state: state, startedAt: a.startedAt, bot: a.bot,
                                          isolation: a.isolation, actsAsYou: a.actsAsYou ? true : nil, task: a.task,
                                          control: a.isWorker ? WorkerLaunch.control(isolation: a.isolation, shares: workerShares(rec, a)) : nil,
                                          // In-process nothing is known of a program (no statuses held): no activity.
                                          activity: readOnly ? nil : WorkspaceState.activity(counted)),
                        counted))
        }
        return out
    }

    /// The sandbox a worker shares with another agent of the workspace not ended (nil: none — a place of its own).
    func workerShares(_ rec: WorkspaceRecord, _ a: WorkspaceAgent) -> String? {
        guard a.isWorker, let s = a.place.sandbox else { return nil }
        let others = rec.agents.contains { o in o.endedAt == nil && o.place.sandbox == s && !(o.name == a.name && o.place == a.place) }
        return others ? s : nil
    }

    func workspaceDetail(_ rec: WorkspaceRecord, withBrief: Bool, macs given: [String: SessionRow]? = nil, notes: [String] = []) async -> WorkspaceDetail {
        let macs: [String: SessionRow]
        if let given { macs = given } else { macs = rec.agents.contains { $0.place.mac == true } ? await workspaceMacRows() : [:] }
        let agents = await workspaceAgents(rec, macs: macs)
        let state = WorkspaceState.derive(WorkspaceState.Input(agents: agents.compactMap(\.1), flags: rec.flags, starting: startingWorkspaces.contains(rec.name)))
        return WorkspaceDetail(name: rec.name, state: state.rawValue, driver: rec.driver, createdAt: rec.createdAt, brief: rec.brief,
                               briefText: withBrief ? workspaces.readBrief(rec.name) : nil, folders: rec.folders, rooms: rec.rooms,
                               agents: agents.map(\.0), defaults: rec.defaults, flags: rec.flags, origin: rec.origin,
                               notes: notes.isEmpty ? nil : notes)
    }

    func workspaceListing(looseOnly: Bool) async -> WorkspaceListing {
        let macs = await workspaceMacRows()
        let records = workspaces.records()
        var member: [String: String] = [:]
        for r in records { for a in r.agents { if let k = a.place.key, member[k] == nil { member[k] = r.name } } }
        var rows: [WorkspaceRow] = []
        if !looseOnly {
            for rec in records {
                let agents = await workspaceAgents(rec, macs: macs)
                let state = WorkspaceState.derive(WorkspaceState.Input(agents: agents.compactMap(\.1), flags: rec.flags, starting: startingWorkspaces.contains(rec.name)))
                let manager = rec.manager.flatMap { m in agents.first { $0.0.role == "manager" }.map { row in
                    WorkspaceManagerRow(bot: m.bot ?? m.name, isolation: m.isolation ?? "fenced", actsAsYou: m.actsAsYou, state: row.0.state)
                } }
                rows.append(WorkspaceRow(name: rec.name, state: state.rawValue, driver: rec.driver, agents: agents.count, room: rec.mainRoom?.chatRoom,
                                         manager: manager, working: readOnly ? nil : WorkspaceState.working(agents.map(\.0)),
                                         folders: rec.folders.isEmpty ? nil : rec.folders.map(\.path)))
            }
        }
        var loose: [LooseAgent] = []
        for m in managed.values.sorted(by: { $0.name < $1.name }) where member["sandbox:" + m.name] == nil {
            loose.append(LooseAgent(name: m.name, kind: "sandbox", state: await effectivePhase(m).rawValue))
        }
        for r in macs.values.sorted(by: { $0.name < $1.name }) where member["mac:" + r.name] == nil {
            loose.append(LooseAgent(name: MacPlace.name + "/" + r.name, kind: "mac", state: r.gone == true ? "gone" : r.ended ? "ended" : "running"))
        }
        return WorkspaceListing(workspaces: rows, loose: loose)
    }

    // MARK: checks

    /// A sandbox's name or `@mac/SESSION` → its default agent name and place. Missing is refused.
    func workspaceTarget(_ s: String) throws -> (String, AgentPlace) {
        if s == MacPlace.name { throw HostError(.invalid, "name the session: @mac/SESSION") }
        if s.hasPrefix(MacPlace.name + "/") {
            let session = String(s.dropFirst(MacPlace.name.count + 1))
            try MacPlace.validateSessionName(session)
            guard mac.records().sessions[session] != nil else { throw HostError(.notFound, "no session \(session) on this Mac (doz sessions @mac)") }
            return (session, .macSession(session))
        }
        guard managed[s] != nil else { throw HostError(.notFound, "no sandbox \(s) (doz ls)") }
        return (s, .sandbox(s))
    }

    /// Whether an agent's place runs now (adopting a RUNNING agent marks the workspace started).
    func workspacePlaceRunning(_ place: AgentPlace) async -> Bool {
        if let s = place.sandbox, let m = managed[s] {
            let p = await effectivePhase(m)
            return p == .running || p == .booting
        }
        if place.mac == true, let s = place.session, !buildFlavor.isHelper { return await mac.isRunning(s) }
        return false
    }

    func workspaceCheckFree(_ place: AgentPlace, member: [String: String]) throws {
        if let k = place.key, let w = member[k] {
            throw HostError(.exists, "\(place.display) is already in \(w) — doz workspace release \(w) \(place.display) first.")
        }
    }

    func workspaceCheckBrief(_ text: String) throws -> Data {
        let d = Data(text.utf8)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw HostError(.invalid, "the brief is empty") }
        guard d.count <= WorkspaceStore.maximumBriefBytes else {
            throw HostError(.invalid, "the brief is \(d.count) bytes — at most \(WorkspaceStore.maximumBriefBytes >> 10) KiB")
        }
        return d
    }

    func workspaceCheckFolder(_ f: WorkspaceFolder) throws {
        guard f.path.hasPrefix("/") else { throw HostError(.invalid, "\(f.path): a folder is an absolute path") }
        guard WorkspaceFolder.modes.contains(f.mode) else { throw HostError(.invalid, "\(f.path): the mode is rw or ro, not \(f.mode)") }
        var dir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: f.path, isDirectory: &dir), dir.boolValue else {
            throw HostError(.notFound, "no folder \(DisplayPath.tilde(f.path))")
        }
    }

    func workspaceCheckRef(_ s: String) throws {
        if s.hasPrefix("http://") || s.hasPrefix("https://") {
            guard let u = URL(string: s), u.host?.isEmpty == false else { throw HostError(.invalid, "\(s) is not an address") }
            return
        }
        guard s.hasPrefix("/") else { throw HostError(.invalid, "\(s): a reference is an absolute path or an http(s) address") }
        guard FileManager.default.fileExists(atPath: s) else { throw HostError(.notFound, "no file or folder \(DisplayPath.tilde(s))") }
    }

    /// The rooms other workspaces hold.
    func workspaceRoomOwner(_ room: String, except: String? = nil) -> String? {
        workspaces.records().first { $0.name != except && $0.rooms.contains { $0.chatRoom == room } }?.name
    }

    /// Whether the main room `name` can be made now (nil: chat off). Throws when chat is on but cannot take it.
    func workspaceRoomCheck(_ name: String) async throws -> WorkspaceChat? {
        guard let chat = workspaceChat else { return nil }
        switch await chat.readiness() {
        case .off: return nil
        case .notReady(let why):
            throw HostError(.unavailable, "chat is on but its server is not ready (\(why)) — doz chat status, or pass --no-room")
        case .ready:
            if try chat.rooms().contains(name) {
                throw HostError(.exists, "there is already a room \(name) — pass --room \(name) to make it this workspace's room, or choose another name")
            }
            return chat
        }
    }

    // MARK: changing

    func workspaceNew(_ w: WorkspaceRequest) async throws -> WorkspaceDetail {
        let name = try workspaceName(w)
        guard !workspaces.exists(name) else { throw HostError(.exists, "there is already a workspace \(name)") }
        let brief = try workspaceCheckBrief(w.brief ?? "")
        var folders: [WorkspaceFolder] = []
        for f in w.folders ?? [] {
            try workspaceCheckFolder(f)
            guard !folders.contains(where: { $0.path == f.path }) else { throw HostError(.invalid, "\(DisplayPath.tilde(f.path)) is given twice") }
            folders.append(WorkspaceFolder(path: f.path, mode: f.mode, main: folders.isEmpty))
        }
        let refs = w.refs ?? []
        for r in refs { try workspaceCheckRef(r) }
        if w.project != nil, folders.isEmpty {
            throw HostError(.invalid, "--from-project reads the project file in the main folder — give it with --folder DIR")
        }
        // The agents to adopt at once: each there, in no workspace, under a name of its own.
        let member = workspaces.membership()
        let now = Date()
        var agents: [WorkspaceAgent] = []
        for a in w.adopt ?? [] {
            let (n, place) = try workspaceTarget(a)
            try workspaceCheckFree(place, member: member)
            guard !agents.contains(where: { $0.place == place }) else { throw HostError(.invalid, "\(a) is given twice") }
            guard WorkspaceName.isValidAgent(n), !agents.contains(where: { $0.name == n }) else {
                throw HostError(.exists, "two agents would be called \(n) — adopt one with doz workspace adopt \(name) \(a) --as NAME")
            }
            agents.append(WorkspaceAgent(name: n, place: place, startedAt: now))
        }
        var anyRunning = false
        for a in agents where await workspacePlaceRunning(a.place) { anyRunning = true }
        // Its manager: recorded, not started (nothing posted, nothing started).
        if w.managerIsolation != nil, w.manager == nil { throw HostError(.invalid, "--manager-isolation goes with --manager BOT") }
        if let bot = w.manager {
            let m = try workspaceManagerEntry(bot: bot, asked: w.managerIsolation, workspace: name, at: now)
            try workspaceCheckFree(m.place, member: member)
            guard !agents.contains(where: { $0.name == m.name }) else { throw HostError(.exists, "two agents would be called \(m.name)") }
            agents.append(m)
        }
        // The room: made, linked, or none — checked before anything is written.
        if w.noRoom == true, w.room != nil { throw HostError(.invalid, "--room or --no-room, not both") }
        var rooms: [WorkspaceRoom] = []
        var log = [WorkspaceLogEntry(at: now, action: "created")]
        var notes: [String] = []
        for a in agents where !a.isManager { log.append(WorkspaceLogEntry(at: now, action: "adopted", agent: a.name, place: a.place.key)) }
        if let m = agents.first(where: \.isManager) {
            if m.actsAsYou { notes.append("unfenced: \(m.name) acts as you when it runs") }
            log.append(WorkspaceLogEntry(at: now, action: "manager-set", agent: m.name, place: m.place.key, isolation: m.isolation))
        }
        let readiness = await workspaceChat?.readiness() ?? .off
        if w.noRoom == true {
            notes.append("no room — doz workspace edit \(name) --make-room makes one")
        } else if let linked = w.room {
            switch readiness {
            case .off: throw HostError(.unavailable, "chat is off — doz chat on, or leave out --room")
            case .notReady(let why): throw HostError(.unavailable, "chat is on but its server is not ready (\(why)) — doz chat status")
            case .ready:
                guard try workspaceChat?.rooms().contains(linked) == true else { throw HostError(.notFound, "no room \(linked) (doz chat rooms)") }
                if let owner = workspaceRoomOwner(linked) { throw HostError(.exists, "the room \(linked) is already the room of \(owner)") }
            }
            rooms.append(WorkspaceRoom(label: "main", chatRoom: linked, main: true))
            log.append(WorkspaceLogEntry(at: now, action: "room-linked", room: linked))
        } else if let chat = try await workspaceRoomCheck(name) {
            if let owner = workspaceRoomOwner(name) { throw HostError(.exists, "the room \(name) is already the room of \(owner)") }
            try chat.makeRoom(name)
            rooms.append(WorkspaceRoom(label: "main", chatRoom: name, main: true))
            log.append(WorkspaceLogEntry(at: now, action: "room-made", room: name))
        } else {
            notes.append("no room: chat is off — doz workspace edit \(name) --make-room once it is on")
        }
        let origin = w.project != nil ? WorkspaceOrigin(kind: "project", project: w.project)
            : agents.allSatisfy(\.isManager) ? WorkspaceOrigin(kind: "new") : WorkspaceOrigin(kind: "adopted")
        let rec = WorkspaceRecord(name: name, createdAt: now,
                                  brief: WorkspaceBrief(refs: refs, sha256: WorkspaceStore.sha256(brief), bytes: brief.count, updatedAt: now),
                                  folders: folders, rooms: rooms, agents: agents, defaults: WorkspaceDefaults(network: w.network),
                                  flags: WorkspaceFlags(firstAgentAt: anyRunning ? now : nil), origin: origin)
        try workspaces.create(rec, brief: brief, log: log)
        note(nil, "workspace \(name) made (\(agents.count) agent\(agents.count == 1 ? "" : "s"), \(rooms.isEmpty ? "no room" : "room \(rooms[0].chatRoom)"))")
        return await workspaceDetail(rec, withBrief: false, notes: notes)
    }

    func workspaceAdopt(_ w: WorkspaceRequest) async throws -> WorkspaceDetail {
        let n = try workspaceName(w)
        var rec = try workspaceRecord(n)
        guard rec.flags.archivedAt == nil else { throw HostError(.invalidPhase, "\(n) is archived") }
        guard let target = w.agent, !target.isEmpty else { throw HostError(.invalid, "which agent? a sandbox's name or @mac/SESSION") }
        let (defaultName, place) = try workspaceTarget(target)
        try workspaceCheckFree(place, member: workspaces.membership())
        let agent = w.asName ?? defaultName
        guard WorkspaceName.isValidAgent(agent) else { throw HostError(.invalid, "\(agent) is not an agent name — pass --as NAME") }
        guard !rec.agents.contains(where: { $0.name == agent }) else {
            throw HostError(.exists, "\(n) already has an agent called \(agent) — pass --as NAME")
        }
        let now = Date()
        rec.agents.append(WorkspaceAgent(name: agent, place: place, startedAt: now))
        // Adopting a RUNNING agent marks it started; one that does not run leaves it setting up.
        if rec.flags.firstAgentAt == nil, await workspacePlaceRunning(place) { rec.flags.firstAgentAt = now }
        try workspaces.write(rec)
        try? workspaces.append(n, WorkspaceLogEntry(at: now, action: "adopted", agent: agent, place: place.key))
        return await workspaceDetail(rec, withBrief: false)
    }

    func workspaceRelease(_ w: WorkspaceRequest) async throws -> WorkspaceDetail {
        let n = try workspaceName(w)
        var rec = try workspaceRecord(n)
        guard let a = w.agent, let i = rec.agentIndex(a) else {
            throw HostError(.notFound, "\(w.agent ?? "?") is not in \(n) (doz workspace show \(n))")
        }
        if rec.agents[i].isManager, await managerRunning(rec.agents[i]) {
            throw HostError(.invalidPhase, "\(rec.agents[i].name) manages \(n) and is running — stop it first: doz workspace stop \(n)")
        }
        if rec.agents[i].isLiveWorker {
            throw HostError(.invalidPhase, "\(rec.agents[i].name) is a worker of \(n) — doz worker end \(n) \(rec.agents[i].name)")
        }
        let gone = rec.agents.remove(at: i)
        try workspaces.write(rec)
        try? workspaces.append(n, WorkspaceLogEntry(action: gone.isManager ? "manager-removed" : "released", agent: gone.name, place: gone.place.key))
        return await workspaceDetail(rec, withBrief: false)
    }

    func workspaceEdit(_ w: WorkspaceRequest) async throws -> WorkspaceDetail {
        let n = try workspaceName(w)
        var rec = try workspaceRecord(n)
        let now = Date()
        var log: [WorkspaceLogEntry] = []
        // Everything is checked first.
        var brief: Data?
        if let b = w.brief { brief = try workspaceCheckBrief(b) }
        var refsAdded = 0, refsRemoved = 0
        for r in w.removeRefs ?? [] {
            guard let i = rec.brief.refs.firstIndex(of: r) else { throw HostError(.notFound, "\(r) is not a reference of \(n)") }
            rec.brief.refs.remove(at: i)
            refsRemoved += 1
        }
        for r in w.addRefs ?? [] where !rec.brief.refs.contains(r) {
            try workspaceCheckRef(r)
            rec.brief.refs.append(r)
            refsAdded += 1
        }
        var foldersAdded = 0, foldersRemoved = 0
        for p in w.removeFolders ?? [] {
            guard let i = rec.folders.firstIndex(where: { $0.path == p }) else { throw HostError(.notFound, "\(DisplayPath.tilde(p)) is not a folder of \(n)") }
            rec.folders.remove(at: i)
            foldersRemoved += 1
        }
        for f in w.addFolders ?? [] {
            try workspaceCheckFolder(f)
            guard !rec.folders.contains(where: { $0.path == f.path }) else { throw HostError(.exists, "\(DisplayPath.tilde(f.path)) is already a folder of \(n)") }
            rec.folders.append(WorkspaceFolder(path: f.path, mode: f.mode, main: false))
            foldersAdded += 1
        }
        if !rec.folders.isEmpty, !rec.folders.contains(where: \.main) { rec.folders[0].main = true }
        // The manager: added, replaced or removed — never while it runs.
        var managerChanged = false
        if w.manager != nil || w.managerIsolation != nil || w.noManager == true {
            if w.noManager == true, w.manager != nil || w.managerIsolation != nil {
                throw HostError(.invalid, "--manager or --no-manager, not both")
            }
            let old = rec.managerIndex.map { rec.agents[$0] }
            if let old, await managerRunning(old) {
                throw HostError(.invalidPhase, "\(old.name) is running — stop it first: doz workspace stop \(n)")
            }
            if w.noManager == true {
                guard let old else { throw HostError(.notFound, "\(n) has no manager") }
                rec.agents.removeAll { $0.isManager }
                log.append(WorkspaceLogEntry(at: now, action: "manager-removed", agent: old.name, place: old.place.key))
            } else {
                guard let bot = w.manager ?? old?.bot else { throw HostError(.invalid, "--manager-isolation goes with --manager BOT") }
                let m = try workspaceManagerEntry(bot: bot, asked: w.managerIsolation ?? (w.manager == nil ? old?.isolation : nil), workspace: n, at: now)
                var member = workspaces.membership()
                if let old, let k = old.place.key { member[k] = nil }
                try workspaceCheckFree(m.place, member: member)
                rec.agents.removeAll { $0.isManager }
                guard !rec.agents.contains(where: { $0.name == m.name }) else { throw HostError(.exists, "\(n) already has an agent called \(m.name)") }
                rec.agents.append(m)
                log.append(WorkspaceLogEntry(at: now, action: "manager-set", agent: m.name, place: m.place.key, isolation: m.isolation))
            }
            managerChanged = true
        }
        var chat: WorkspaceChat?
        if w.makeRoom == true {
            if let r = rec.mainRoom { throw HostError(.exists, "\(n) already has its room \(r.chatRoom)") }
            if let owner = workspaceRoomOwner(n, except: n) { throw HostError(.exists, "the room \(n) is already the room of \(owner)") }
            guard let c = try await workspaceRoomCheck(n) else { throw HostError(.unavailable, "chat is off — doz chat on, then try again") }
            chat = c
        }
        guard brief != nil || refsAdded + refsRemoved + foldersAdded + foldersRemoved > 0 || chat != nil || managerChanged else {
            throw HostError(.invalid, "nothing to change — give --prompt-file, --add-ref, --remove-ref, --add-folder, --remove-folder, --make-room, --manager or --no-manager")
        }
        // Then the room, then the files.
        if let chat {
            try chat.makeRoom(n)
            rec.rooms.append(WorkspaceRoom(label: "main", chatRoom: n, main: true))
            log.append(WorkspaceLogEntry(at: now, action: "room-made", room: n))
        }
        if let brief {
            try workspaces.writeBrief(n, brief)
            rec.brief.sha256 = WorkspaceStore.sha256(brief)
            rec.brief.bytes = brief.count
            rec.brief.updatedAt = now
            log.append(WorkspaceLogEntry(at: now, action: "brief-edited", sha256: rec.brief.sha256, bytes: brief.count))
        }
        if refsAdded + refsRemoved > 0 { log.append(WorkspaceLogEntry(at: now, action: "refs-edited", added: refsAdded, removed: refsRemoved)) }
        if foldersAdded + foldersRemoved > 0 { log.append(WorkspaceLogEntry(at: now, action: "folders-edited", added: foldersAdded, removed: foldersRemoved)) }
        try workspaces.write(rec)
        for e in log { try? workspaces.append(n, e) }
        return await workspaceDetail(rec, withBrief: false)
    }

    func workspaceRename(_ w: WorkspaceRequest) async throws -> WorkspaceDetail {
        let n = try workspaceName(w)
        guard let new = w.newName, !new.isEmpty else { throw HostError(.invalid, "rename needs the new name (doz workspace rename \(n) NEW)") }
        try WorkspaceName.validate(new)
        guard new != n else { throw HostError(.invalid, "\(n) is already called \(new)") }
        _ = try workspaceRecord(n)
        try workspaces.rename(n, to: new)
        try? workspaces.append(new, WorkspaceLogEntry(action: "renamed", from: n, to: new))
        let rec = try workspaceRecord(new)
        let notes = rec.mainRoom.map { ["its room keeps its name, \($0.chatRoom) (the chat server cannot rename rooms)"] } ?? []
        return await workspaceDetail(rec, withBrief: false, notes: notes)
    }

    // MARK: the hooks of `doz rename` and `doz rm`

    /// A renamed sandbox: its workspace's agent follows it (and takes the new name when it had the old one).
    func workspaceSandboxRenamed(_ old: String, to new: String) async {
        guard !readOnly else { return }
        await workspaceGate.lock("workspaces")
        defer { workspaceGate.unlock("workspaces") }
        let ws = workspaces
        guard let n = ws.membership()["sandbox:" + old], var rec = try? ws.read(n),
              let i = rec.agents.firstIndex(where: { $0.place.sandbox == old }) else { return }
        let was = rec.agents[i].name
        rec.agents[i].place.sandbox = new
        if was == old, !rec.agents.contains(where: { $0.name == new }) { rec.agents[i].name = new }
        do {
            try ws.write(rec)
            try ws.append(n, WorkspaceLogEntry(by: "doz", action: "agent-renamed", agent: rec.agents[i].name, place: "sandbox:" + new, from: old, to: new))
        } catch { note(old, "its workspace \(n) could not follow the rename: \(error)") }
    }

    /// A deleted sandbox: its workspace lets it go.
    func workspaceSandboxRemoved(_ name: String) async {
        guard !readOnly, managed[name] == nil else { return }
        await workspaceGate.lock("workspaces")
        defer { workspaceGate.unlock("workspaces") }
        let ws = workspaces
        // A worker's entry stays (`doz worker end` ends it; a sandbox deleted by `--rm` is its own).
        guard let n = ws.membership()["sandbox:" + name], var rec = try? ws.read(n),
              let i = rec.agents.firstIndex(where: { $0.place.sandbox == name && !$0.isWorker }) else { return }
        let gone = rec.agents.remove(at: i)
        do {
            try ws.write(rec)
            try ws.append(n, WorkspaceLogEntry(by: "doz", action: "agent-removed", agent: gone.name, place: "sandbox:" + name))
        } catch { note(name, "its workspace \(n) could not let it go: \(error)") }
    }
}
