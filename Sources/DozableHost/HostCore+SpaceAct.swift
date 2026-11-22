import DozableChat
import Foundation

// `workspace-up`: a space file acted on. The CLI read the files and sends the merged document again with the plan's sha it
// showed (`ifPlan`) and the unfenced agents the person confirmed on a terminal (`confirmed`); the daemon plans again and
// refuses a plan that changed (nothing done, exit 3), a refusal, and a confirm set that is not exactly the plan's (every
// unfenced agent, at every up, wherever the setting came from — inheriting never pre-approves). Then each step runs in
// order through the daemon's own operations, in-process (new, edit, the rooms, reopen and wake, start, the run's scratch
// folders, adopt, each worker), under `space:W` — so every rule of theirs holds. It stops at the first failure: the rest
// are "not run", the run stays open, and a second up makes only what is missing. `up` never writes a grant, a ceiling or
// `bots.json` (a request is recorded, never granted), never writes the brief, and opens no named file but the brief (the
// space file itself is opened only by `workspace-space` and `-space-save`, never by up).
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
    /// 756, down (which is finish): `WorkspaceFinish`, schema 1, what it removed and kept — folders by their absolute path,
    /// rooms `room/NAME`, agents `agent/NAME`, sandboxes `sandbox/NAME` — and the run's archive (relative to the store).
    /// Additive; nil for up.
    public var kind: String?
    public var schema: Int?
    public var removed: [String]?
    public var kept: [String]?
    public var archive: String?
    /// The workspace's lifetime (`standing` or `runs`).
    public var lifetime: String?
    public init(space: String, verb: String) { self.space = space; self.verb = verb }
}

extension HostCore {
    /// The brief's text: a space workspace's from the file its record names (under `SpaceBriefFile`'s rules; nil when it
    /// cannot be read — the set-up check then says the brief is missing), any other's from the store's `brief.md`.
    func workspaceBriefText(_ rec: WorkspaceRecord) -> String? {
        // An empty path: the brief is held in the space file itself (755: `x-dozable.brief.text`), kept in brief.md.
        if let p = SpaceRecordRef.of(rec)?.brief?.path, !p.isEmpty { return try? SpaceBriefFile.read(p, store: storeRoot).text }
        return workspaces.readBrief(rec.name)
    }

    /// The facts `keptFolderPaths` needs: the home and the projects folder.
    func spaceFactsHome() -> SpaceFacts {
        SpaceFacts(known: true, home: TestSafety.spaceHome(), projectsDir: (Workspace.defaultPath(name: "x") as NSString).deletingLastPathComponent)
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
            throw HostError(.planChanged, "\(name) changed since you looked — look again: doz workspace up --dry-run")
        }
        if let first = plan.refusals.first { throw HostError(HostError.Code(rawValue: plan.refusalCode ?? "") ?? .invalidPhase, first) }
        let confirmed = q.confirmed ?? []
        guard Set(confirmed) == Set(plan.confirm), confirmed.count == Set(confirmed).count else {
            throw HostError(.invalidPhase, plan.confirm.isEmpty ? "nothing here is unfenced: there is nothing to confirm"
                            : "\(plan.confirm.joined(separator: ", ")) would run unfenced, with full access to your user — confirm \(plan.confirm.count == 1 ? "it" : "them") at this up")
        }
        guard let intent = plan.intent else { throw HostError(.invalid, "workspace-up needs the space's brief") }
        let brief: SpaceBriefFile.Read
        if let text = intent.briefText {
            // 755: the brief held in the document (`x-dozable.brief.text`): kept in the store's brief.md, as `new` keeps one.
            let d = try workspaceCheckBrief(text)
            brief = SpaceBriefFile.Read(text: text, sha256: WorkspaceStore.sha256(d), bytes: d.count)
        } else {
            guard let briefPath = q.brief?.path else { throw HostError(.invalid, "workspace-up needs the space's brief") }
            brief = try SpaceBriefFile.read(briefPath, store: storeRoot)
        }
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
            let store = workspaces
            let held = intent.briefText != nil
            let r = try await workspaceUpdate(name) { r in
                ref.store(in: &r)
                var log = [WorkspaceLogEntry(action: "space-up", sha256: plan.specSHA, reason: failed ? "stopped at a failure; the rest not run" : nil)]
                // 755: a brief held in the document that changed since the last up: the store's copy follows it.
                if held, r.brief.sha256 != brief.sha256, (try? store.writeBrief(name, Data(brief.text.utf8))) != nil {
                    r.brief.sha256 = brief.sha256
                    r.brief.bytes = brief.bytes
                    r.brief.updatedAt = Date()
                    log.append(WorkspaceLogEntry(action: "brief-edited", sha256: brief.sha256, bytes: brief.bytes))
                }
                return log
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
        ref.lifetime = i.lifetime
        ref.runLifetime = i.runLifetime
        ref.archiveOff = i.archive.value == "off" ? true : nil
        ref.archiveKeep = i.archiveKeep.isEmpty ? nil : i.archiveKeep
        var t: [String: String] = [:]
        for a in i.ownedAgents where a.memory == nil && a.transcripts?.value == "discard" { t[a.name] = "discard" }
        ref.transcripts = t.isEmpty ? nil : t
        var kept = ref.persistedPaths ?? []
        for k in SpaceUp.keptFolderPaths(i, spaceFactsHome()) where !kept.contains(k.path) { kept.append(k.path) }
        ref.persistedPaths = kept.isEmpty ? nil : kept
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
            w.refs = i.briefRefs
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
            guard let a = i.agents.first(where: { "agent \($0.name)" == st.subject }), let place = a.session.map({ MacPlace.name + "/" + $0 }) ?? a.sandbox else { return [] }
            var w = WorkspaceRequest(name: n)
            w.agent = place
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

// MARK: down and --purge

// `workspace-down`: the space's run ended and what it made for the run removed — and with `purge` what persists too. In
// order: (1) finish (rooms closed, agents stopped, the archive written and hash-checked, the run closed); (2) a persisted
// fenced agent's memory captured; (3) each run-lifetime agent ended and forgotten (its own sandbox removed), its transcripts
// discarded where `transcripts: discard` — only unchanged files, against the archive or, with `archive: off`, the
// hashes-only ledger written just before; (4) the run's scratch folders copied into the archive and hash-checked, then
// removed — only a folder the record names, never in the store; (5) the run-lifetime rooms archived, hash-checked, then
// removed (a tombstone kept). Nothing content-bearing goes when the archive failed. `archive: off` is the one exception
// to "a copy first": what goes with no copy is named in the plan and the confirmation. A failed step is logged and down
// carries on; a second down plans only what is left. Folders the space keeps are never deleted (`--purge` releases them);
// external things are never touched.
extension HostCore {
    func spaceDownPlan(_ q: SpaceDownRequest?) throws -> SpaceDownPlan {
        guard let q else { throw HostError(.invalid, "which workspace? (doz workspace ls)") }
        try WorkspaceName.validate(q.workspace)
        return SpaceDown.plan(try workspaces.read(q.workspace), space: q.workspace, purge: q.purge == true)
    }

    func spaceDown(_ q: SpaceDownRequest?) async throws -> SpaceActed {
        guard !readOnly else { throw HostError(.unavailable, "workspace-down needs the daemon") }
        guard let q else { throw HostError(.invalid, "which workspace? (doz workspace ls)") }
        let n = q.workspace
        try WorkspaceName.validate(n)
        await workspaceGate.lock("space:" + n)
        defer { workspaceGate.unlock("space:" + n) }
        let plan = try spaceDownPlan(q)
        guard let want = q.ifPlan, want == plan.sha else {
            throw HostError(.planChanged, "\(n) changed since you looked — look again: doz workspace down \(n) --dry-run")
        }
        if let first = plan.refusals.first { throw HostError(HostError.Code(rawValue: plan.refusalCode ?? "") ?? .invalidPhase, first) }
        var out = SpaceActed(space: n, verb: q.purge == true ? "purge" : "down")
        out.run = plan.run
        // What it held before, so what it kept is named (and what it removed, step by step, below).
        let before = try workspaceRecord(n)
        let beforeRef = SpaceRecordRef.of(before)
        var removed: [String] = []
        var archiveFailed = false
        var toSeq: [String: Int64] = [:]
        for st in plan.steps {
            let fail = { (why: String) in
                out.ok = false
                out.results.append(.init(n: st.n, kind: st.kind, subject: st.subject, status: "failed", text: st.text + ": " + why))
                try? self.workspaces.append(n, WorkspaceLogEntry(action: "space-down", reason: "FAILED \(st.subject): \(why)"))
            }
            // Nothing content-bearing goes when the archive failed: the rooms, the scratch folders and discarded transcripts.
            // (An agent still ends and is forgotten — its transcripts kept.)
            if archiveFailed, st.kind == "scratch-rm" || st.kind == "room-rm" {
                out.results.append(.init(n: st.n, kind: st.kind, subject: st.subject, status: "skipped",
                                         text: st.text + " (kept: the run's archive was not written, so nothing is removed)"))
                continue
            }
            do {
                var notes: [String] = []
                switch st.kind {
                case "finish":
                    let rec = try workspaceRecord(n)
                    let ref = SpaceRecordRef.of(rec)
                    var w = WorkspaceRequest(name: n)
                    w.noArchive = ref?.archiveOff == true ? true : nil
                    let c = try await workspaceLifecycle(.finish, w)
                    notes = c.notes ?? []
                    out.archive = c.archive
                    if ref?.archiveOff != true, c.archiveProblem != nil || c.archive == nil { archiveFailed = true; notes.append("the run's archive was not written: nothing content-bearing is removed") }
                    if let r = try workspaceRecord(n).runs.last { for x in r.rooms { if let t = x.toSeq { toSeq[x.room] = t } } }
                case "memory":
                    notes = try spaceMemoryCapture(n, agent: String(st.subject.dropFirst("agent ".count)))
                case "worker-end":
                    let name = String(st.subject.dropFirst("agent ".count))
                    let sandbox = try workspaceRecord(n).agents.last { $0.name == name && $0.endedAt == nil }?.place.sandbox
                    notes = try await spaceEndAgent(n, name, discard: st.copy, archiveFailed: archiveFailed)
                    removed.append("agent/" + name)
                    if let sb = sandbox, managed[sb] == nil { removed.append("sandbox/" + sb) }
                case "release":
                    var w = WorkspaceRequest(name: n)
                    w.agent = String(st.subject.dropFirst("agent ".count))
                    await workspaceGate.lock("workspaces")
                    defer { workspaceGate.unlock("workspaces") }
                    _ = try await workspaceRelease(w)
                case "scratch-rm":
                    let name = String(st.subject.dropFirst("folder ".count))
                    let path = beforeRef?.scratch?.first { $0.name == name }?.path
                    notes = try await spaceRemoveScratch(n, name: name, noCopy: st.copy == "none")
                    if let path { removed.append(path) }
                case "room-rm":
                    let room = String(st.subject.dropFirst("room ".count))
                    notes = try await spaceRemoveRoom(n, room: room, noCopy: st.copy == "none", toSeq: toSeq)
                    removed.append("room/" + room)
                case "memory-rm":
                    spaceMemoryReset(n, agent: String(st.subject.dropFirst("agent ".count)))
                case "sandbox-rm":
                    let s = String(st.subject.dropFirst("sandbox ".count))
                    if managed[s] != nil, workspaces.membership()["sandbox:" + s] == n {
                        let a = await handle(HostRequest(.rm, name: s))
                        if let e = a.error { throw HostError(e.code, e.message) }
                        removed.append("sandbox/" + s)
                        try? workspaces.append(n, WorkspaceLogEntry(action: "sandbox-removed", place: "sandbox:" + s))
                    }
                case "folder-release":
                    let path = String(st.subject.dropFirst("folder ".count))
                    var w = WorkspaceRequest(name: n)
                    if try workspaceRecord(n).folders.contains(where: { $0.path == path }) {
                        w.removeFolders = [path]
                        await workspaceGate.lock("workspaces")
                        defer { workspaceGate.unlock("workspaces") }
                        _ = try await workspaceEdit(w)
                    }
                    _ = try await workspaceUpdate(n) { r in
                        var ref = SpaceRecordRef.of(r) ?? SpaceRecordRef()
                        ref.persistedPaths?.removeAll { $0 == path }
                        ref.store(in: &r)
                        return [WorkspaceLogEntry(action: "folder-released", reason: "kept on disk, off the record")]
                    }
                case "record":
                    let purge = q.purge == true
                    _ = try await workspaceUpdate(n) { r in
                        var ref = SpaceRecordRef.of(r) ?? SpaceRecordRef()
                        ref.downAt = Date()
                        if purge { ref.purgedAt = Date(); ref.memoryIsolation = nil }
                        ref.store(in: &r)
                        return [WorkspaceLogEntry(action: purge ? "space-purged" : "space-down", reason: out.ok ? nil : "a step failed; down again does what is left", run: plan.run)]
                    }
                default:
                    break
                }
                out.results.append(.init(n: st.n, kind: st.kind, subject: st.subject, status: "done", text: st.text, notes: notes.isEmpty ? nil : notes))
            } catch {
                fail(HostError.from(error).message)
            }
        }
        out.notes = plan.notes
        out.kind = WorkspaceFinishInventory.kind
        out.schema = WorkspaceFinishInventory.schema
        out.removed = WorkspaceFinishInventory.dedupe(removed)
        out.kept = WorkspaceFinishInventory.kept(before: before, removed: removed)
        out.lifetime = beforeRef?.lifetime ?? SpaceDozable.defaultLifetime
        if !out.ok { out.notes.append("a step failed: down carried on and did what it could — doz workspace down \(n) again does what is left") }
        if let r = try? workspaceRecord(n) { out.workspace = await workspaceDetail(r, withBrief: false) }
        note(nil, "space \(n): \(out.verb) — \(out.results.filter { $0.status == "done" }.count) done" + (out.ok ? "" : ", a step failed"))
        return out
    }

    /// A persisted fenced agent's memory, captured from its session's private agent folder into the store.
    func spaceMemoryCapture(_ n: String, agent: String) throws -> [String] {
        let rec = try workspaceRecord(n)
        guard let a = rec.agents.last(where: { $0.name == agent && $0.endedAt == nil }), let s = a.place.session, a.place.mac == true else { return [] }
        guard let fence = mac.records().sessions[s]?.fence, fence.agentConfig == MacAgentConfig.privateMode else {
            return ["\(agent): no private agent folder — its memory is its own (never ~/.claude)"]
        }
        let agentDir = MacFence.sessionFolder(try mac.fencePlaces(), session: s) + "/agent"
        let dest = WorkspaceStore.resolved(workspaces.folder(n)) + "/memory/" + agent
        let count = try SpaceMemory.capture(agentDir: agentDir, into: dest)
        try? workspaces.append(n, WorkspaceLogEntry(action: "memory-kept", agent: agent, added: count))
        return ["\(agent): \(count) memory file\(count == 1 ? "" : "s") kept for its next fenced session"]
    }

    /// A run-lifetime agent ended and forgotten — its own sandbox removed unless the space keeps it —, its transcripts
    /// discarded first when the space says so: against the run's verified archive, or with `archive: off` against the
    /// hashes-only ledger written now. With a failed archive nothing is discarded.
    func spaceEndAgent(_ n: String, _ name: String, discard: String?, archiveFailed: Bool) async throws -> [String] {
        let rec = try workspaceRecord(n)
        guard let a = rec.agents.last(where: { $0.name == name && $0.isWorker && $0.endedAt == nil }) else { return ["\(name) has ended already"] }
        let ref = SpaceRecordRef.of(rec)
        var notes: [String] = []
        if discard != nil, !archiveFailed, a.place.mac == true, let s = a.place.session {
            if discard == "none" {
                notes += try spaceDiscardByLedger(n, session: s, run: rec.runs.last?.id ?? "run")
            } else {
                let d = macDiscardTranscripts(s, workspace: n)
                if let why = d.refused { notes.append("\(name)'s transcripts kept: \(why)") } else {
                    notes += d.notes
                    try? workspaces.append(n, WorkspaceLogEntry(action: "transcripts-discarded", agent: name, place: "mac:" + s, removed: d.removed, run: d.run))
                }
            }
        }
        let shared = a.place.sandbox != nil && a.place.session != nil
        let keepsSandbox = a.place.sandbox.map { s in ref.map { $0.effective("sandbox", s, recorded: $0.owned?.sandboxes[s]) == "persisted" } ?? false } ?? false
        var q = WorkerRequest(workspace: n, name: name)
        q.rm = !shared && !keepsSandbox && a.bot == nil
        let e = try await workerEnd(q)
        return notes + (e.notes ?? [])
    }

    /// `transcripts: discard` with `archive: off`: the session's conversations hashed now (the ledger: names and sha256
    /// only, in the store) and each removed only while it still hashes so, through its descriptor, its inode unchanged.
    func spaceDiscardByLedger(_ n: String, session s: String, run: String) throws -> [String] {
        var r = HostRequest(.sessionTranscripts, name: MacPlace.name)
        r.session = s
        let own = ((try? macTranscriptsList(r))?.conversations ?? []).filter { $0.sha256 != nil }
        let ledger = SpaceLedger(run: run, session: s, files: own.map { .init(name: $0.name, source: $0.source ?? "", sha256: $0.sha256!) })
        let dir = WorkspaceStore.resolved(workspaces.folder(n)) + "/ledger"
        try MacFenceHostFS.ensureDirectory(dir)
        try MacFenceHostFS.writeAtomically(try HostWire.prettyEncoder.encode(ledger), dir: dir, name: "\(run)-\(s).json")
        var removed = 0
        var notes: [String] = []
        for i in own {
            switch TranscriptDiscard.remove(i.path, sha256: i.sha256!) {
            case .removed: removed += 1
            case .kept(let why): notes.append("\(s): \((i.path as NSString).lastPathComponent) kept — \(why)")
            }
        }
        try? workspaces.append(n, WorkspaceLogEntry(action: "transcripts-discarded", agent: s, place: "mac:" + s, removed: removed, reason: "deleted with no copy (archive: off); the ledger keeps their sha256", run: run))
        return ["\(s): \(removed) conversation file\(removed == 1 ? "" : "s") deleted with no copy (archive: off)"] + notes
    }

    /// A recorded scratch folder removed: copied into the archive and hash-checked first (none with `archive: off`); only a
    /// folder the record names, under `<projects_dir>/.runs/<space>/`, never in the store.
    func spaceRemoveScratch(_ n: String, name: String, noCopy: Bool) async throws -> [String] {
        let rec = try workspaceRecord(n)
        guard let ref = SpaceRecordRef.of(rec), let s = (ref.scratch ?? []).first(where: { $0.name == name }) else {
            throw HostError(.notFound, "no scratch folder \(name) in the record — nothing removed")
        }
        let projects = WorkspaceStore.resolved((Workspace.defaultPath(name: "x") as NSString).deletingLastPathComponent)
        guard s.path.hasPrefix(projects + "/.runs/\(n)/"), spaceFolderRefusal(s.path) == nil else {
            throw HostError(.invalid, "\(DisplayPath.tilde(s.path)) is not where a scratch folder of \(n) is made — nothing removed")
        }
        var notes: [String] = []
        if MacFenceHostFS.kind(s.path) == S_IFDIR {
            if !noCopy {
                let path = try RunArchive.writeFolder(source: s.path, name: name, workspace: n, run: s.run, store: store, sweep: ExportSweep.forStore(store))
                guard RunArchive.verify(root: storeRoot + "/" + path).ok else { throw HostError(.failed, "the copy of \(name) does not verify — kept") }
                notes.append("copied into \(DisplayPath.tilde(storeRoot + "/" + path)) and hash-checked")
            }
            if rec.folders.contains(where: { $0.path == s.path }) {
                var w = WorkspaceRequest(name: n)
                w.removeFolders = [s.path]
                await workspaceGate.lock("workspaces")
                defer { workspaceGate.unlock("workspaces") }
                _ = try await workspaceEdit(w)
            }
            try MacFenceHostFS.remove(s.path)
        }
        _ = try await workspaceUpdate(n) { r in
            var x = SpaceRecordRef.of(r) ?? SpaceRecordRef()
            x.scratch?.removeAll { $0.name == name && $0.run == s.run }
            x.store(in: &r)
            return [WorkspaceLogEntry(action: "scratch-removed", reason: noCopy ? "\(name): deleted with no copy (archive: off)" : "\(name): copied and hash-checked first", run: s.run)]
        }
        return notes + (noCopy ? ["\(name): deleted with no copy (archive: off)"] : [])
    }

    /// A room the space made removed for good: archived and hash-checked first (`chat-room-archive`, then `chat-room-rm`
    /// and its guards), or — `archive: off` — with no copy, only while its last message is still the run's close.
    func spaceRemoveRoom(_ n: String, room: String, noCopy: Bool, toSeq: [String: Int64]) async throws -> [String] {
        await workspaceGate.lock("room:" + room)
        defer { workspaceGate.unlock("room:" + room) }
        if !noCopy {
            var a = ChatRoomRequest(room: room)
            do { _ = try await roomArchive(a) } catch let e as HostError where e.code == .exists {}
            a.confirm = room
            let c = try await roomRemove(a)
            return c.notes ?? []
        }
        guard let chat = workspaceChat, await chat.readiness() == .ready else { throw HostError(.unavailable, "chat is not ready — doz chat status") }
        guard try chat.rooms().contains(room) else { return ["\(room) is gone already"] }
        let rec = try workspaceRecord(n)
        guard rec.openRun == nil else { throw HostError(.invalidPhase, "\(n)'s run is open — kept") }
        let last = try chat.lastSeq(room: room)
        let closedAt = toSeq[room] ?? rec.runs.last?.rooms.first { $0.room == room }?.toSeq
        guard let closedAt, last == closedAt else {
            throw HostError(.invalidPhase, "\(room) has messages after its run closed — kept (no copy of them would be left)")
        }
        let id = try await roomIndexUpdate { $0.ensure(room, owner: n).id }
        try await chat.removeRoom(room, id: id, lastSeq: last)
        let now = Date()
        _ = try await roomIndexUpdate { idx in idx.bury(room, at: now, run: rec.runs.last?.id, archive: "") }
        _ = try await workspaceUpdate(n) { r in
            for i in r.rooms.indices where r.rooms[i].chatRoom == room && r.rooms[i].goneAt == nil { r.rooms[i].goneAt = now }
            return [WorkspaceLogEntry(action: "room-removed", room: room, reason: "deleted with no copy (archive: off)", run: rec.runs.last?.id)]
        }
        await pushClosedSet()
        return ["\(room) deleted with no copy (archive: off); a tombstone stays"]
    }
}

/// The hashes-only ledger of a discard with `archive: off` (`<store>/workspaces/W/ledger/<run>-<session>.json`): names and
/// sha256 only — never a byte of a conversation.
struct SpaceLedger: Codable {
    struct File: Codable { var name: String; var source: String; var sha256: String }
    var run: String
    var session: String
    var files: [File]
}
