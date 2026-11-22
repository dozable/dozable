import DozableChat
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
    /// Archive `room` as you (read-only, its history kept) or open it again; false: it was so already.
    @discardableResult func setArchived(room: String, _ on: Bool) throws -> Bool
    /// The room's newest seq (0: empty) — a run's marker, as data.
    func lastSeq(room: String) throws -> Int64
    /// The rooms archived now.
    func archivedRooms() throws -> Set<String>
    /// One request on the owner's socket (a run's chat slice, a room's whole history): the status and the body.
    func fetch(_ target: String) throws -> (status: Int, body: Data)
    /// The closed set — the whole of it, room → workspace — handed to the running chat server over its control channel
    /// and kept for its next start. Answers each room's last seq as the server took it under its lock (nil: no server took
    /// it now — it is handed over at its start).
    func setClosed(_ rooms: [String: String]) async throws -> [String: Int64]?
    /// A room removed for good by the running chat server (its id and its last seq checked under its lock).
    func removeRoom(_ room: String, id: String, lastSeq: Int64) async throws
    /// One fixed call on the owner's socket, as you: the status and the JSON answer (`HostCore+ChatAsks` builds each from
    /// checked values — never a caller's path).
    func ownerCall(_ method: String, _ target: String, body: JValue?, headers: [(String, String)]) throws -> (Int, JValue)
}

extension WorkspaceChat {
    /// A chat that cannot archive (a test's that does not need to).
    @discardableResult public func setArchived(room: String, _ on: Bool) throws -> Bool {
        throw HostError(.notImplemented, "this chat cannot archive a room")
    }
    public func lastSeq(room: String) throws -> Int64 { 0 }
    public func archivedRooms() throws -> Set<String> { [] }
    public func fetch(_ target: String) throws -> (status: Int, body: Data) {
        throw HostError(.notImplemented, "this chat cannot be read")
    }
    public func setClosed(_ rooms: [String: String]) async throws -> [String: Int64]? { nil }
    public func removeRoom(_ room: String, id: String, lastSeq: Int64) async throws {
        throw HostError(.notImplemented, "this chat cannot remove a room")
    }
    public func ownerCall(_ method: String, _ target: String, body: JValue?, headers: [(String, String)]) throws -> (Int, JValue) {
        throw HostError(.notImplemented, "this chat cannot be asked")
    }
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
    /// The supervisor's control channel: the closed set, a room's removal.
    let closed: (@Sendable ([String: String]) async -> [String: Int64]?)?
    let remove: (@Sendable (String, String, Int64) async throws -> Void)?
    public init(ready: @escaping @Sendable () async -> WorkspaceChatReadiness, owner: ChatOwnerRooms,
                closed: (@Sendable ([String: String]) async -> [String: Int64]?)? = nil,
                remove: (@Sendable (String, String, Int64) async throws -> Void)? = nil) {
        self.ready = ready; self.owner = owner; self.closed = closed; self.remove = remove
    }
    public func setClosed(_ rooms: [String: String]) async throws -> [String: Int64]? { await closed?(rooms) }
    public func removeRoom(_ room: String, id: String, lastSeq: Int64) async throws {
        guard let remove else { throw HostError(.notImplemented, "this chat cannot remove a room") }
        try await remove(room, id, lastSeq)
    }
    public func readiness() async -> WorkspaceChatReadiness { await ready() }
    public func rooms() throws -> Set<String> { Set(try owner.state().rooms.keys) }
    public func makeRoom(_ name: String) throws {
        try owner.makeRoom(name, members: try owner.state().otherHumans)
    }
    public func post(room: String, content: String) throws { try owner.post(room: room, content: content) }
    @discardableResult public func invite(room: String, name: String) throws -> Bool { try owner.invite(room: room, name: name) }
    @discardableResult public func setArchived(room: String, _ on: Bool) throws -> Bool { try owner.setArchived(room: room, on) }
    public func lastSeq(room: String) throws -> Int64 { try owner.lastSeq(room: room) }
    public func archivedRooms() throws -> Set<String> { try owner.state().archived }
    public func ownerCall(_ method: String, _ target: String, body: JValue?, headers: [(String, String)]) throws -> (Int, JValue) {
        do {
            let a = try owner.client.request(method, target, json: body.map { Data(ChatJSON.encode($0)) }, headers: headers)
            return (a.status, (try? ChatJSON.parse(a.body)) ?? .null)
        } catch ChatOwnerClient.Failure.notListening {
            throw HostError(.unavailable, "chat is on but its server is not ready — doz chat status")
        } catch ChatOwnerClient.Failure.failed(let why) {
            throw HostError(.unavailable, why)
        }
    }
    public func fetch(_ target: String) throws -> (status: Int, body: Data) {
        do {
            let a = try owner.client.request("GET", target, json: nil)
            return (a.status, a.body)
        } catch ChatOwnerClient.Failure.notListening {
            throw HostError(.unavailable, "chat is on but its server is not ready — doz chat status")
        } catch ChatOwnerClient.Failure.failed(let why) {
            throw HostError(.unavailable, why)
        }
    }
}

/// What `workspace-new` would write (`HostCore.workspaceNewDraft`).
struct WorkspaceNewDraft {
    var record: WorkspaceRecord
    var brief: Data
    var log: [WorkspaceLogEntry]
    var refusals: [HostError]
    var notes: [String]
    /// The main room made now (its name), or linked.
    var makeRoom: String?
    var roomLinked: Bool
    /// `<projects_dir>/NAME`, made now (it is missing).
    var makeFolder: String?
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
            var d = await workspaceDetail(rec, withBrief: w.withBrief == true)
            // While it is setting up: what the start would refuse now (a look — the keychain is not read).
            if d.state == WorkspaceState.settingUp.rawValue {
                d.gaps = WorkspaceSetupCheck.gaps(await workspaceSetupInput(rec, look: true))
            }
            return try JSONValue(encoding: d)
        case .workspaceLog:
            return try workspaceLogAnswer(w)
        case .workspaceReach:
            return try JSONValue(encoding: try await workspaceReach(w))
        case .workspaceFolders:
            return try JSONValue(encoding: try await workspaceFolders(w))
        case .workspacePlan:
            return try JSONValue(encoding: await workspacePlan(w))
        case .workspaceLifecyclePlan:
            return try JSONValue(encoding: try await workspaceLifecyclePlan(w))
        case .workspaceRuns:
            return try JSONValue(encoding: try workspaceRuns(w))
        case .workspaceRunChat:
            return try JSONValue(encoding: try workspaceRunChat(w))
        case .workspaceState:
            return try JSONValue(encoding: try await workspaceState(w))
        case .workspaceSpace:
            return try JSONValue(encoding: try workspaceSpaceFile(w))
        case .workspaceSpaceSave:
            return try JSONValue(encoding: try await workspaceSpaceSave(w))
        case .workspaceRunFrames:
            return try JSONValue(encoding: try await workspaceRunFrames(w))
        default:
            break
        }
        guard !readOnly else { throw HostError(.unavailable, "\(r.op.rawValue) needs the daemon") }
        // Start and stop take the gate themselves: the check under `workspaces`, the launch under `workspace:NAME`.
        if r.op == .workspaceStart { return try JSONValue(encoding: try await workspaceStart(w)) }
        if r.op == .workspaceStop { return try JSONValue(encoding: try await workspaceStop(w)) }
        if let verb = WorkspaceVerb(op: r.op) { return try JSONValue(encoding: try await workspaceLifecycle(verb, w)) }
        if r.op == .workspaceRunArchive { return try JSONValue(encoding: try await workspaceRunArchive(w)) }
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
                                          activity: readOnly ? nil : WorkspaceState.activity(counted), startedBy: a.startedBy,
                                          session: a.place.sandbox != nil ? a.place.session : nil),
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
        var d = WorkspaceDetail(name: rec.name, state: state.rawValue, driver: rec.driver, createdAt: rec.createdAt, brief: rec.brief,
                                briefText: withBrief ? workspaceBriefText(rec) : nil, folders: rec.folders, rooms: rec.rooms,
                                agents: agents.map(\.0), defaults: rec.defaults, flags: rec.flags, origin: rec.origin,
                                notes: notes.isEmpty ? nil : notes)
        d.space = SpaceShown.of(rec)
        d.declaredWorkers = rec.declaredWorkers.isEmpty ? nil : rec.declaredWorkers
        return d
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
                                         folders: rec.folders.isEmpty ? nil : rec.folders.map(\.path), places: Self.workspacePlaces(rec),
                                         space: WorkspaceRowSpace.of(rec),
                                         lastAt: (try? workspaces.logPage(rec.name, limit: 1))?.entries.first?.at))
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

    /// The places of a workspace's agents that have not ended, each once, in record order (nil: none) — elsewhere has none.
    static func workspacePlaces(_ rec: WorkspaceRecord) -> [String]? {
        var out: [String] = []
        for a in rec.agents where a.endedAt == nil && a.place.key != nil && !out.contains(a.place.display) { out.append(a.place.display) }
        return out.isEmpty ? nil : out
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

    /// What `workspace-new` would make of `w`, with nothing written, no room made and the keychain not read: the record, the
    /// brief, the log, EVERY refusal (in the order `new` checks them — `new` answers with the first) and the notes. `look`:
    /// the plan's (with no daemon, chat is judged from its setting and a room's clash becomes a note); else `new`'s own.
    /// `space`: made by `up` from a space file — its brief is the file's (read under `SpaceBriefFile`'s rules; the store's
    /// `brief.md` stays empty, never a copy) and the record carries the space's reference from its first write.
    func workspaceNewDraft(_ w: WorkspaceRequest, look: Bool, space: (ref: SpaceRecordRef, brief: SpaceBriefFile.Read)? = nil) async -> WorkspaceNewDraft {
        var refusals: [HostError] = []
        func refuse(_ e: HostError) { refusals.append(e) }
        func attempt(_ f: () throws -> Void) { do { try f() } catch { refuse(HostError.from(error)) } }
        var name = w.name ?? ""
        do { name = try workspaceName(w) } catch { refuse(HostError.from(error)) }
        let named = WorkspaceName.isValid(name)
        if named, workspaces.exists(name) { refuse(HostError(.exists, "there is already a workspace \(name)")) }
        var brief = Data((w.brief ?? "").utf8)
        if let space { attempt { _ = try workspaceCheckBrief(space.brief.text) }; brief = Data() }
        else { attempt { brief = try workspaceCheckBrief(w.brief ?? "") } }
        // The folders: `<projects_dir>/NAME` first when it is made now, then each given one.
        var folders: [WorkspaceFolder] = []
        var makeFolder: String?
        if w.newFolder == true, named {
            let p = WorkspaceStore.resolved(Workspace.defaultPath(name: name))
            var dir: ObjCBool = false
            if FileManager.default.fileExists(atPath: p, isDirectory: &dir), !dir.boolValue {
                refuse(HostError(.exists, "\(DisplayPath.tilde(p)) is a file, not a folder"))
            } else {
                if !FileManager.default.fileExists(atPath: p) { makeFolder = p }
                folders.append(WorkspaceFolder(path: p, mode: "rw", main: true))
            }
        }
        for f in w.folders ?? [] {
            if folders.contains(where: { $0.path == f.path }) {
                refuse(HostError(.invalid, "\(DisplayPath.tilde(f.path)) is given twice"))
                continue
            }
            do { try workspaceCheckFolder(f) } catch { refuse(HostError.from(error)); continue }
            folders.append(WorkspaceFolder(path: f.path, mode: f.mode, main: folders.isEmpty))
        }
        let refs = w.refs ?? []
        for r in refs { attempt { try workspaceCheckRef(r) } }
        if w.project != nil, folders.isEmpty {
            refuse(HostError(.invalid, "--from-project reads the project file in the main folder — give it with --folder DIR"))
        }
        // The agents to adopt at once: each there, in no workspace, under a name of its own.
        let member = workspaces.membership()
        let now = Date()
        var agents: [WorkspaceAgent] = []
        for a in w.adopt ?? [] {
            do {
                let (n, place) = try workspaceTarget(a)
                try workspaceCheckFree(place, member: member)
                guard !agents.contains(where: { $0.place == place }) else { throw HostError(.invalid, "\(a) is given twice") }
                guard WorkspaceName.isValidAgent(n), !agents.contains(where: { $0.name == n }) else {
                    throw HostError(.exists, "two agents would be called \(n) — adopt one with doz workspace adopt \(name) \(a) --as NAME")
                }
                agents.append(WorkspaceAgent(name: n, place: place, startedAt: now))
            } catch { refuse(HostError.from(error)) }
        }
        var anyRunning = false
        for a in agents where await workspacePlaceRunning(a.place) { anyRunning = true }
        // Its manager: recorded, not started (nothing posted, nothing started).
        if w.managerIsolation != nil, w.manager == nil { refuse(HostError(.invalid, "--manager-isolation goes with --manager BOT")) }
        if let bot = w.manager {
            do {
                let m = try workspaceManagerEntry(bot: bot, asked: w.managerIsolation, workspace: named ? name : "workspace", at: now)
                try workspaceCheckFree(m.place, member: member)
                guard !agents.contains(where: { $0.name == m.name }) else { throw HostError(.exists, "two agents would be called \(m.name)") }
                agents.append(m)
            } catch { refuse(HostError.from(error)) }
        }
        // New workers' default and the network preset.
        if let i = w.workerIsolation {
            if i == "unfenced" {
                refuse(HostError(.invalid, "new workers are never unfenced by default — name one: doz worker add W --isolation unfenced"))
            } else if !WorkspaceNetworks.workerIsolations.contains(i) {
                refuse(HostError(.invalid, "--worker-isolation is vm or fenced, not \(i)"))
            }
        }
        if let n = w.network, !(WorkspaceNetworks.presets + WorkspaceNetworks.projectWords).contains(n) {
            refuse(HostError(.invalid, "--network is locked, standard or open, not \(n)"))
        }
        // The room: made, linked, or none — checked before anything is written.
        if w.noRoom == true, w.room != nil { refuse(HostError(.invalid, "--room or --no-room, not both")) }
        var rooms: [WorkspaceRoom] = []
        var log = [WorkspaceLogEntry(at: now, action: "created")]
        var notes: [String] = []
        for a in agents where !a.isManager { log.append(WorkspaceLogEntry(at: now, action: "adopted", agent: a.name, place: a.place.key)) }
        if let m = agents.first(where: \.isManager) {
            if m.actsAsYou { notes.append("unfenced: \(m.name) acts as you when it runs") }
            log.append(WorkspaceLogEntry(at: now, action: "manager-set", agent: m.name, place: m.place.key, isolation: m.isolation))
        }
        let (readiness, assumed) = await workspaceLookReadiness(look: look)
        var makeRoom: String?
        var linked = false
        if w.noRoom == true {
            notes.append("no room — doz workspace edit \(name) --make-room makes one")
        } else if let room = w.room {
            switch readiness {
            case .off: refuse(HostError(.unavailable, "chat is off — doz chat on, or leave out --room"))
            case .notReady(let why): refuse(HostError(.unavailable, "chat is on but its server is not ready (\(why)) — doz chat status"))
            case .ready:
                if assumed {
                    notes.append("whether the room \(room) exists is checked when it is made")
                } else {
                    do {
                        guard try workspaceChat?.rooms().contains(room) == true else { throw HostError(.notFound, "no room \(room) (doz chat rooms)") }
                    } catch { refuse(HostError.from(error)) }
                }
                if let owner = workspaceRoomOwner(room) { refuse(HostError(.exists, "the room \(room) is already the room of \(owner)")) }
            }
            rooms.append(WorkspaceRoom(label: "main", chatRoom: room, main: true, owned: false))
            log.append(WorkspaceLogEntry(at: now, action: "room-linked", room: room))
            linked = true
        } else {
            switch readiness {
            case .off:
                notes.append("no room: chat is off — doz workspace edit \(name) --make-room once it is on")
            case .notReady(let why):
                refuse(HostError(.unavailable, "chat is on but its server is not ready (\(why)) — doz chat status, or pass --no-room"))
            case .ready:
                if assumed {
                    notes.append("whether a room \(name) exists already is checked when it is made")
                } else if (try? workspaceChat?.rooms().contains(name)) == true {
                    refuse(HostError(.exists, "there is already a room \(name) — pass --room \(name) to make it this workspace's room, or choose another name"))
                }
                if named, let owner = workspaceRoomOwner(name) { refuse(HostError(.exists, "the room \(name) is already the room of \(owner)")) }
                rooms.append(WorkspaceRoom(label: "main", chatRoom: name, main: true, owned: true))
                log.append(WorkspaceLogEntry(at: now, action: "room-made", room: name))
                makeRoom = name
            }
        }
        // The workers declared now: recorded, started by the start (a worker talks in the room — none, none declared).
        var declared: [WorkspaceDeclaredWorker] = []
        if let tasks = w.workers, !tasks.isEmpty {
            do {
                declared = try workspaceDeclareWorkers(tasks, taken: Set(agents.map(\.name)), at: now)
                var chatOff = false
                if case .off = readiness { chatOff = true }
                if rooms.isEmpty, w.noRoom == true || chatOff {
                    refuse(HostError(.invalid, "a worker talks in the workspace's room, and \(named ? name : "it") would have none"
                                     + (w.noRoom == true ? " — leave out --no-room" : ": chat is off — doz chat on")))
                }
            } catch { refuse(HostError.from(error)) }
            for d in declared {
                log.append(WorkspaceLogEntry(at: now, action: "worker-declared", agent: d.name, sha256: WorkspaceStore.sha256(Data(d.task.utf8)),
                                             bytes: d.task.utf8.count))
            }
        }
        let origin = w.project != nil ? WorkspaceOrigin(kind: "project", project: w.project)
            : agents.allSatisfy(\.isManager) ? WorkspaceOrigin(kind: "new") : WorkspaceOrigin(kind: "adopted")
        var rec = WorkspaceRecord(name: name, createdAt: now,
                                  brief: WorkspaceBrief(refs: refs, sha256: space?.brief.sha256 ?? WorkspaceStore.sha256(brief),
                                                        bytes: space?.brief.bytes ?? brief.count, updatedAt: now),
                                  folders: folders, rooms: rooms, agents: agents,
                                  defaults: WorkspaceDefaults(isolation: w.workerIsolation, network: w.network),
                                  flags: WorkspaceFlags(firstAgentAt: anyRunning ? now : nil), origin: origin)
        rec.declaredWorkers = declared
        if let space { space.ref.store(in: &rec) }
        return WorkspaceNewDraft(record: rec, brief: brief, log: log, refusals: refusals, notes: notes, makeRoom: makeRoom, roomLinked: linked,
                                 makeFolder: makeFolder)
    }

    /// The chat server as a look sees it: the daemon asks it (a starting one is waited for); with no daemon its setting
    /// decides — on is taken as "starts with Dozable" (`assumed`: nothing of it was asked). Nothing starts the daemon.
    func workspaceLookReadiness(look: Bool) async -> (WorkspaceChatReadiness, assumed: Bool) {
        if let chat = workspaceChat { return (await chat.readiness(), false) }
        guard look, readOnly else { return (.off, false) }
        return ((chatSettingOverride ?? ChatSettingsView.read().enabled) ? .ready : .off, true)
    }

    func workspaceNew(_ w: WorkspaceRequest, space: (ref: SpaceRecordRef, brief: SpaceBriefFile.Read)? = nil) async throws -> WorkspaceDetail {
        let d = await workspaceNewDraft(w, look: false, space: space)
        if let first = d.refusals.first { throw first }
        let name = d.record.name
        // Then the folder made now, the room, the files — the folder taken back when a later step fails.
        if let p = d.makeFolder {
            do { try MacFenceHostFS.ensureDirectory(p, mode: 0o700) } catch {
                throw HostError(.failed, "cannot make \(DisplayPath.tilde(p)): \(error)")
            }
        }
        do {
            if let room = d.makeRoom, let chat = workspaceChat { try chat.makeRoom(room) }
            try workspaces.create(d.record, brief: d.brief, log: d.log)
        } catch {
            if let p = d.makeFolder { try? FileManager.default.removeItem(atPath: p) }
            throw error
        }
        // Its room's id in the room index (its owner when the workspace made it) — the index's own gate; the record takes the
        // id when its first run opens.
        for r in d.record.rooms { _ = try? await roomIndexUpdate { $0.ensure(r.chatRoom, owner: r.owned == true ? name : nil) } }
        let rec = d.record
        note(nil, "workspace \(name) made (\(rec.agents.count) agent\(rec.agents.count == 1 ? "" : "s"), \(rec.rooms.isEmpty ? "no room" : "room \(rec.rooms[0].chatRoom)"))")
        return await workspaceDetail(rec, withBrief: false, notes: d.notes)
    }

    /// `workspace-plan`: the draft, its gaps and its commands — nothing written.
    func workspacePlan(_ w: WorkspaceRequest) async -> WorkspacePlan {
        let d = await workspaceNewDraft(w, look: true)
        let gaps = WorkspaceSetupCheck.gaps(await workspaceSetupInput(d.record, look: true, brief: d.brief.count,
                                                                      roomWillBeMade: d.makeRoom != nil || d.roomLinked,
                                                                      foldersMadeNow: d.makeFolder.map { [$0] } ?? []))
        let name = w.name ?? ""
        return WorkspacePlan(name: name, refusals: d.refusals.map(\.message), refusalCode: d.refusals.first?.code.rawValue, gaps: gaps,
                             notes: d.notes,
                             lines: WorkspacePlanLines.lines(d.record, roomMade: d.makeRoom != nil, roomLinked: d.roomLinked,
                                                             newFolder: d.makeFolder, workerIsolation: w.workerIsolation),
                             commands: WorkspaceNewCommand.text(w), startCommand: WorkspaceNewCommand.startText(name.isEmpty ? "NAME" : name))
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
        // Everything is checked first — the brief as the editor read it first of all (a change since: nothing written). A
        // space's brief is its file, hashed as it is now through its descriptor; the path is the record's, never a request's.
        let spaceBrief = SpaceRecordRef.of(rec)?.brief.flatMap { $0.path.isEmpty ? nil : $0.path }
        let current = try spaceBrief.map { try SpaceBriefFile.read($0, store: storeRoot).sha256 } ?? rec.brief.sha256
        if let want = w.ifBrief, want != current {
            throw HostError(.fileChanged, "the brief of \(n) changed since you opened it — read it again (doz workspace show \(n) --brief)")
        }
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
            let id = try? await roomIndexUpdate { $0.ensure(n, owner: n).id }
            rec.rooms.append(WorkspaceRoom(label: "main", chatRoom: n, main: true, id: id, owned: true))
            log.append(WorkspaceLogEntry(at: now, action: "room-made", room: n))
        }
        if let brief, let path = spaceBrief {
            // The file wins: written in place (temp, then renamed over it, its mode kept); the store's copy never.
            let wrote = try SpaceBriefFile.write(String(decoding: brief, as: UTF8.self), to: path, ifSHA: current, store: storeRoot)
            rec.brief.sha256 = wrote.sha256
            rec.brief.bytes = wrote.bytes
            rec.brief.updatedAt = now
            log.append(WorkspaceLogEntry(at: now, action: "brief-edited", sha256: wrote.sha256, bytes: wrote.bytes, reason: "written to the space's brief file"))
        } else if let brief {
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
        // After the start, a new brief is announced as your message in the main room — once per edit; while setting up
        // nothing is posted (the start posts the brief). The edit is kept whatever the chat server says.
        var notes: [String] = []
        if let brief, rec.flags.startedAt != nil, let room = rec.mainRoom?.chatRoom {
            notes += await workspaceAnnounceBrief(n, room: room, brief: String(decoding: brief, as: UTF8.self), refs: rec.brief.refs)
        }
        return await workspaceDetail(rec, withBrief: false, notes: notes)
    }

    /// Posts the edited brief in `room` as you (`ManagerKickoff.briefEdited`) and logs `brief-announced`; answers the notes
    /// to show when it could not.
    func workspaceAnnounceBrief(_ n: String, room: String, brief: String, refs: [String]) async -> [String] {
        await workspaceAnnounce(n, room: room, content: ManagerKickoff.briefEdited(brief: brief, refs: refs),
                                entry: WorkspaceLogEntry(action: "brief-announced", room: room))
    }

    /// Posts `content` in `room` as you and appends `entry` to the workspace's log; answers the notes to show when it could
    /// not (nothing posted, nothing logged). The brief's announcement and a running bot's change (`botTellRunningSessions`).
    func workspaceAnnounce(_ n: String, room: String, content: String, entry: WorkspaceLogEntry) async -> [String] {
        guard let chat = workspaceChat else { return ["not announced: chat is off"] }
        switch await chat.readiness() {
        case .off: return ["not announced: chat is off"]
        case .notReady(let why): return ["not announced: the chat server is not ready (\(why))"]
        case .ready: break
        }
        do {
            try chat.post(room: room, content: content)
        } catch {
            return ["not announced: \(HostError.from(error).message)"]
        }
        try? workspaces.append(n, entry)
        return []
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
        // A worker's entry stays (`doz worker end` ends it; a sandbox deleted by `--rm` is its own); so does the agent of a
        // sandbox the workspace's own lifecycle removes (an archive or a delete with --remove-sandboxes).
        guard !lifecycleRemoving.contains(name), let n = ws.membership()["sandbox:" + name], var rec = try? ws.read(n),
              let i = rec.agents.firstIndex(where: { $0.place.sandbox == name && !$0.isWorker }) else { return }
        let gone = rec.agents.remove(at: i)
        do {
            try ws.write(rec)
            try ws.append(n, WorkspaceLogEntry(by: "doz", action: "agent-removed", agent: gone.name, place: "sandbox:" + name))
        } catch { note(name, "its workspace \(n) could not let it go: \(error)") }
    }
}
