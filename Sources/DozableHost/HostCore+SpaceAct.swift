import DozableChat
import Foundation

// `workspace-up`: a space file acted on. The CLI read the files and sends the merged document again with the plan's sha it
// showed (`ifPlan`) and the unfenced agents the person confirmed on a terminal (`confirmed`); the daemon plans again and
// refuses a plan that changed (nothing done, exit 3), a refusal, and a confirm set that is not exactly the plan's (every
// unfenced agent, at every up, wherever the setting came from — inheriting never pre-approves). Then each step runs in
// order through the daemon's own operations, in-process (new, edit, the rooms, reopen and wake, start, the run's scratch
// folders, adopt, each worker), under `space:W` — so every rule of theirs holds. It stops at the first failure: the rest
// are "not run", the run stays open, and a second up makes only what is missing. `up` never writes a grant, a ceiling or
// `bots.json` (a request is recorded, never granted), never writes the brief, and opens no named file but the brief.
// docs/engineering/workspaces.md ("Space files").

/// What `up` or `down` did, step by step.
public struct SpaceActed: Codable, Equatable, Sendable {
    public struct Result: Codable, Equatable, Sendable {
        public var n: Int
        public var kind: String
        public var subject: String
        /// `done`, `skipped` (already there, or nothing to do), `failed`, `not-run` (after a failure).
        public var status: String
        public var text: String
        public var notes: [String]?
        public init(n: Int, kind: String, subject: String, status: String, text: String, notes: [String]? = nil) {
            self.n = n; self.kind = kind; self.subject = subject; self.status = status; self.text = text; self.notes = notes
        }
    }
    public var space: String
    /// `up`, `down` or `purge`.
    public var verb: String
    public var results: [Result] = []
    /// Every step done or skipped.
    public var ok: Bool = true
    public var run: String?
    public var notes: [String] = []
    public var workspace: WorkspaceDetail?
    public init(space: String, verb: String) { self.space = space; self.verb = verb }
}

extension HostCore {
    /// The brief's text: a space workspace's from the file its record names (under `SpaceBriefFile`'s rules; nil when it
    /// cannot be read — the set-up check then says the brief is missing), any other's from the store's `brief.md`.
    func workspaceBriefText(_ rec: WorkspaceRecord) -> String? {
        if let p = SpaceRecordRef.of(rec)?.brief?.path { return try? SpaceBriefFile.read(p, store: storeRoot).text }
        return workspaces.readBrief(rec.name)
    }

    /// Why a folder the space would make is refused (nil: fine): never in the store.
    func spaceFolderRefusal(_ path: String) -> String? {
        let p = WorkspaceStore.resolved(path)
        return p == storeRoot || p.hasPrefix(storeRoot + "/") ? "\(DisplayPath.tilde(path)) is in Dozable's store — a space's folder never is" : nil
    }

    func spaceUp(_ q: SpaceRequest?) async throws -> SpaceActed {
        guard !readOnly else { throw HostError(.unavailable, "workspace-up needs the daemon") }
        guard let q else { throw HostError(.invalid, "workspace-up needs the merged space") }
        let doc = try q.check()
        let name = SpaceDoc.string(SpaceDoc.member(doc, "space")) ?? ""
        try WorkspaceName.validate(name)
        await workspaceGate.lock("space:" + name)
        defer { workspaceGate.unlock("space:" + name) }
        let plan = try await spaceUpPlan(q)
        let errors = plan.problems.filter(\.isError).count
        if errors > 0 { throw HostError(.invalid, "the space file has \(errors) error\(errors == 1 ? "" : "s") — doz workspace plan -f FILE") }
        guard let want = q.ifPlan, want == plan.sha else {
            throw HostError(.invalidPhase, "\(name) changed since you looked — look again: doz workspace up --dry-run")
        }
        if let first = plan.refusals.first { throw HostError(HostError.Code(rawValue: plan.refusalCode ?? "") ?? .invalidPhase, first) }
        let confirmed = q.confirmed ?? []
        guard Set(confirmed) == Set(plan.confirm), confirmed.count == Set(confirmed).count else {
            throw HostError(.invalidPhase, plan.confirm.isEmpty ? "nothing here is unfenced: there is nothing to confirm"
                            : "\(plan.confirm.joined(separator: ", ")) would run unfenced, with full access to your user — confirm \(plan.confirm.count == 1 ? "it" : "them") at this up")
        }
        guard let intent = plan.intent, let briefPath = q.brief?.path else { throw HostError(.invalid, "workspace-up needs the space's brief") }
        let brief = try SpaceBriefFile.read(briefPath, store: storeRoot)
        let facts = await spaceFacts(intent, brief: q.brief)

        var out = SpaceActed(space: name, verb: "up")
        var ref = (try? workspaces.read(name)).flatMap { $0.flatMap { SpaceRecordRef.of($0) } } ?? SpaceRecordRef()
        spaceRefFill(&ref, q: q, plan: plan, intent: intent, brief: brief)
        var failed = false
        for st in plan.steps {
            if failed {
                out.results.append(.init(n: st.n, kind: st.kind, subject: st.subject, status: "not-run", text: st.text))
                continue
            }
            if st.kind == "check" || st.action == "skip" {
                out.results.append(.init(n: st.n, kind: st.kind, subject: st.subject, status: "skipped", text: st.text + (st.why.map { " (\($0))" } ?? "")))
                continue
            }
            do {
                let notes = try await spaceUpStep(st, intent: intent, facts: facts, ref: &ref, brief: brief)
                out.results.append(.init(n: st.n, kind: st.kind, subject: st.subject, status: "done", text: st.text, notes: notes.isEmpty ? nil : notes))
            } catch {
                failed = true
                out.ok = false
                out.results.append(.init(n: st.n, kind: st.kind, subject: st.subject, status: "failed", text: st.text + ": " + HostError.from(error).message))
            }
        }
        // The reference (also after a partial up: what was made is the space's), and the merged spec beside the record.
        if workspaces.exists(name) {
            ref.upAt = Date()
            ref.planSHA = plan.sha
            let r = try await workspaceUpdate(name) { r in
                ref.store(in: &r)
                return [WorkspaceLogEntry(action: "space-up", sha256: plan.specSHA, reason: failed ? "stopped at a failure; the rest not run" : nil)]
            }
            try? MacFenceHostFS.writeAtomically(Data(q.spec.utf8), dir: WorkspaceStore.resolved(workspaces.folder(name)), name: "space.json", mode: 0o600)
            out.run = r.openRun?.id
            out.workspace = await workspaceDetail(r, withBrief: false)
        }
        if failed { out.notes.append("up stopped at a failure: the steps after it were not run; the run stays open — doz workspace up again makes only what is missing") }
        note(nil, "space \(name): up — \(out.results.filter { $0.status == "done" }.count) done, \(out.results.filter { $0.status == "skipped" }.count) already there" + (failed ? ", stopped at a failure" : ""))
        return out
    }

    /// What the reference records from this up (everything but the times and what the steps add).
    func spaceRefFill(_ ref: inout SpaceRecordRef, q: SpaceRequest, plan: SpacePlan, intent i: SpaceIntent, brief: SpaceBriefFile.Read) {
        ref.file = q.specPath.map { ($0 as NSString).lastPathComponent }
        ref.path = q.specPath
        ref.sha256 = plan.specSHA
        ref.title = i.title
        ref.sources = q.sources
        var prov: [String: String] = [:]
        for (p, o) in q.origins where o.s < q.sources.count && q.sources[o.s].kind != "space" { prov[p] = "\(q.sources[o.s].name):\(o.l)" }
        ref.provenance = prov.isEmpty ? nil : prov
        ref.brief = SpaceBriefLook(path: q.brief?.path ?? "", sha256: brief.sha256, bytes: brief.bytes)
        var owned = SpaceRecordRef.Owned()
        for a in i.ownedAgents { owned.agents[a.name] = a.memory == nil ? "run" : "persisted" }
        for r in i.rooms where !r.external { owned.rooms[r.chatRoom] = r.persisted == nil ? "run" : "persisted" }
        for s in i.sandboxes where !s.external { owned.sandboxes[s.placeName] = s.persisted == nil ? "run" : "persisted" }
        for f in i.folders where f.path == nil { owned.folders[f.name] = f.persisted == nil ? "run" : "persisted" }
        ref.owned = owned
        ref.archiveOff = i.archive.value == "off" ? true : nil
        ref.archiveKeep = i.archiveKeep.isEmpty ? nil : i.archiveKeep
        var t: [String: String] = [:]
        for a in i.ownedAgents where a.memory == nil && a.transcripts?.value == "discard" { t[a.name] = "discard" }
        ref.transcripts = t.isEmpty ? nil : t
        var iso = ref.memoryIsolation ?? [:]
        for a in i.ownedAgents where a.memory != nil { iso[a.name] = a.isolation?.value ?? "fenced" }
        ref.memoryIsolation = iso.isEmpty ? nil : iso
    }

    /// One step of `up`, through the daemon's own operation; answers what to say.
    func spaceUpStep(_ st: SpacePlan.Step, intent i: SpaceIntent, facts f: SpaceFacts, ref: inout SpaceRecordRef,
                     brief: SpaceBriefFile.Read) async throws -> [String] {
        let n = i.space
        switch st.kind {
        case "folder" where st.lifetime == "persisted":
            guard let k = SpaceUp.keptFolderPaths(i, f).first(where: { "folder \($0.name)" == st.subject }) else { return [] }
            if let why = spaceFolderRefusal(k.path) { throw HostError(.invalid, why) }
            try MacFenceHostFS.ensureDirectory(WorkspaceStore.resolved((k.path as NSString).deletingLastPathComponent) + "/" + (k.path as NSString).lastPathComponent)
            var kept = ref.persistedPaths ?? []
            if !kept.contains(k.path) { kept.append(k.path) }
            ref.persistedPaths = kept
            return []

        case "workspace-new":
            var w = WorkspaceRequest(name: n)
            w.folders = spaceFolders(i, f)
            if i.rooms.isEmpty { w.noRoom = true }
            else if let m = i.mainRoom, m.external { w.room = m.chatRoom }
            w.manager = i.manager?.bot
            await workspaceGate.lock("workspaces")
            defer { workspaceGate.unlock("workspaces") }
            let d = try await workspaceNew(w, space: (ref, brief))
            return d.notes ?? []

        case "workspace-edit":
            let rec = try workspaceRecord(n)
            let scratch = Set((ref.scratch ?? []).map(\.path))
            let want = spaceFolders(i, f)
            var w = WorkspaceRequest(name: n)
            let have = rec.folders.filter { !scratch.contains($0.path) }
            let add = want.filter { x in !have.contains { $0.path == x.path } }
            let remove = have.filter { x in !want.contains { $0.path == x.path } }.map(\.path)
            w.addFolders = add.isEmpty ? nil : add
            w.removeFolders = remove.isEmpty ? nil : remove
            if rec.manager?.bot != i.manager?.bot {
                if let b = i.manager?.bot { w.manager = b } else { w.noManager = true }
            }
            guard w.addFolders != nil || w.removeFolders != nil || w.manager != nil || w.noManager != nil else { return [] }
            await workspaceGate.lock("workspaces")
            defer { workspaceGate.unlock("workspaces") }
            return try await workspaceEdit(w).notes ?? []

        case "room":
            guard let r = i.rooms.first(where: { "room \($0.name)" == st.subject }) else { return [] }
            return try await spaceRoom(r, intent: i)

        case "workspace-reopen":
            return try await workspaceLifecycle(.reopen, WorkspaceRequest(name: n)).notes ?? []

        case "workspace-wake":
            let c = try await workspaceLifecycle(.wake, WorkspaceRequest(name: n))
            if let bad = c.results.first(where: { !$0.ok }) { throw HostError(.failed, "\(bad.name): \(bad.text)") }
            return c.notes ?? []

        case "workspace-start":
            return try await workspaceStart(WorkspaceRequest(name: n)).notes ?? []

        case "folder":
            guard let x = i.folders.first(where: { "folder \($0.name)" == st.subject }), let run = try workspaceRecord(n).openRun else {
                throw HostError(.invalidPhase, "no run is open for a scratch folder")
            }
            let parent = WorkspaceStore.resolved(f.projectsDir) + "/.runs/\(n)/\(run.id)"
            let path = parent + "/" + x.name
            if let why = spaceFolderRefusal(path) { throw HostError(.invalid, why) }
            try MacFenceHostFS.ensureDirectory(path, mode: 0o700)
            var list = ref.scratch ?? []
            if !list.contains(where: { $0.run == run.id && $0.name == x.name }) { list.append(.init(run: run.id, name: x.name, path: path)) }
            ref.scratch = list
            // Recorded before it is used: down removes only a scratch folder its record names.
            _ = try await workspaceUpdate(n) { r in ref.store(in: &r); return [] }
            var w = WorkspaceRequest(name: n)
            w.addFolders = [WorkspaceFolder(path: path, mode: x.access == "ro" ? "ro" : "rw")]
            await workspaceGate.lock("workspaces")
            defer { workspaceGate.unlock("workspaces") }
            _ = try await workspaceEdit(w)
            return []

        case "workspace-adopt":
            guard let a = i.agents.first(where: { "agent \($0.name)" == st.subject }), let s = a.session else { return [] }
            var w = WorkspaceRequest(name: n)
            w.agent = MacPlace.name + "/" + s
            w.asName = a.name
            await workspaceGate.lock("workspaces")
            defer { workspaceGate.unlock("workspaces") }
            _ = try await workspaceAdopt(w)
            return []

        case "worker-add":
            guard var q = st.worker else { return [] }
            q.workspace = n
            // A persisted agent whose isolation switched (fenced ↔ unfenced): ended and forgotten, its kept memory reset.
            if let name = q.name, let rec = try? workspaceRecord(n), rec.liveWorkerIndex(name) != nil {
                var e = WorkerRequest(workspace: n, name: name)
                e.rm = true
                _ = try await workerEnd(e)
                spaceMemoryReset(n, agent: name)
                try? workspaces.append(n, WorkspaceLogEntry(action: "memory-reset", agent: name, reason: "its isolation changed"))
            }
            let added = try await workerAdd(q)
            return added.notes ?? []

        case "requests":
            let now = Date()
            let rows: [JSONValue] = i.requests.compactMap { r in
                try? JSONValue(encoding: SpaceRequestRow(agent: r.agent, role: r.role, grants: r.grants, reason: r.reason, source: r.source,
                                                          spaceSHA: ref.sha256 ?? "", at: now))
            }
            let old = (try? workspaceRecord(n))?.permissions?.requests ?? []
            func key(_ v: JSONValue) -> String {
                guard let r = try? v.decode(SpaceRequestRow.self) else { return "" }
                return ([r.agent, r.role ?? "", r.reason] + r.grants).joined(separator: "\u{1E}")
            }
            let had = Set(old.map(key))
            var fresh: [SpaceIntent.Request] = []
            _ = try await workspaceUpdate(n) { r in
                var g = r.permissions ?? WorkspaceGrants()
                g.requests = rows
                r.permissions = g
                var log: [WorkspaceLogEntry] = []
                for (k, v) in rows.enumerated() where !had.contains(key(v)) {
                    fresh.append(i.requests[k])
                    var e = WorkspaceLogEntry(action: "request-recorded", agent: i.requests[k].agent, reason: i.requests[k].reason)
                    e.role = i.requests[k].role
                    e.perm = i.requests[k].grants.joined(separator: ", ")
                    log.append(e)
                }
                return log
            }
            for x in fresh {
                try? grantStore.append(GrantLogEntry(action: "request-recorded", subject: "agent:\(n)/\(x.agent)", perm: x.grants.joined(separator: ", "),
                                                     role: x.role, scope: "workspace:\(n)", reason: x.reason))
            }
            return []

        default:
            return []
        }
    }

    /// The folders the workspace holds for the space: its external folders that exist, then the folders it keeps.
    func spaceFolders(_ i: SpaceIntent, _ f: SpaceFacts) -> [WorkspaceFolder] {
        var out = i.folders.compactMap { x -> WorkspaceFolder? in
            guard let p = x.path else { return nil }
            let path = f.expand(p)
            var d: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &d), d.boolValue else { return nil }
            return WorkspaceFolder(path: path, mode: x.access == "ro" ? "ro" : "rw")
        }
        for k in SpaceUp.keptFolderPaths(i, f) where !out.contains(where: { $0.path == k.path }) { out.append(WorkspaceFolder(path: k.path, mode: "rw")) }
        if !out.isEmpty { out[0].main = true }
        return out
    }

    /// A room of the space: the main one made again, another owned one made as you, or an external one linked (its
    /// missing members invited — one already there gets no invitation).
    func spaceRoom(_ r: SpaceIntent.Room, intent i: SpaceIntent) async throws -> [String] {
        let n = i.space
        guard let chat = workspaceChat, await chat.readiness() == .ready else { throw HostError(.unavailable, "chat is not ready — doz chat status") }
        let exists = try chat.rooms().contains(r.chatRoom)
        if !r.external {
            if exists { throw HostError(.exists, "there is already a room \(r.chatRoom) — the space makes its own rooms") }
            if let owner = workspaceRoomOwner(r.chatRoom, except: n) { throw HostError(.exists, "the room \(r.chatRoom) is already the room of \(owner)") }
            try chat.makeRoom(r.chatRoom)
        } else if !exists {
            throw HostError(.notFound, "no room \(r.chatRoom) (doz chat rooms)")
        }
        let id = try? await roomIndexUpdate { $0.ensure(r.chatRoom, owner: r.external ? nil : n).id }
        _ = try await workspaceUpdate(n) { rec in
            if r.main { for k in rec.rooms.indices where rec.rooms[k].main && rec.rooms[k].goneAt != nil { rec.rooms[k].main = false } }
            rec.rooms.append(WorkspaceRoom(label: r.main ? "main" : r.name, chatRoom: r.chatRoom, main: r.main, id: id, owned: !r.external))
            return [WorkspaceLogEntry(action: r.external ? "room-linked" : "room-made", room: r.chatRoom)]
        }
        // Members the space names that are bots of this Mac and not started by up (a worker is invited by its add).
        var notes: [String] = []
        let started = Set(i.agents.filter { !$0.external || ($0.bot != nil && $0.role != "manager") }.map(\.name))
        for m in r.members where m != "owner" && !started.contains(m) {
            guard let a = i.agents.first(where: { $0.name == m }), let bot = a.bot else { continue }
            if (try? chat.invite(room: r.chatRoom, name: bot)) == true {
                try? workspaces.append(n, WorkspaceLogEntry(action: "bot-invited", agent: bot, room: r.chatRoom))
            } else { notes.append("\(bot) is in \(r.chatRoom) already") }
        }
        return notes
    }

    /// A persisted agent's kept memory, deleted (a switch fenced ↔ unfenced, or `--purge`).
    func spaceMemoryReset(_ n: String, agent: String) {
        let dir = WorkspaceStore.resolved(workspaces.folder(n)) + "/memory/" + agent
        if MacFenceHostFS.kind(dir) != nil { try? MacFenceHostFS.remove(dir) }
    }
}

/// One request a space file makes for an agent (`permissions.requests[]`): recorded at every up, never granted.
public struct SpaceRequestRow: Codable, Equatable, Sendable {
    public var agent: String
    public var role: String?
    public var grants: [String]
    public var reason: String
    /// `FILE:LINE`.
    public var source: String
    public var spaceSHA: String
    public var at: Date
}
