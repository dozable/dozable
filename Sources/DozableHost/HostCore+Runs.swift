import DozableChat
import DozableKit
import Foundation

// A workspace's runs in the daemon (`WorkspaceRuns`): opened at the kick-off and at reopen, closed at finish and at archive;
// the room index's ids (`ChatRoomIndex`); and `workspace-runs`, read in-process with no daemon. `docs/engineering/workspaces.md`
// ("Runs").

extension HostCore {
    var chatPaths: ChatPaths { ChatPaths(store: store) }
    /// The store's root with every link resolved (`/tmp` is one): what the descriptor-walking readers need.
    nonisolated var storeRoot: String { WorkspaceStore.resolved(store.root.path) }

    /// The room index changed under its own gate (the daemon's only — a read-only core never writes it).
    @discardableResult
    func roomIndexUpdate<T>(_ change: (inout ChatRoomIndex) throws -> T) async throws -> T {
        guard !readOnly else { throw HostError(.unavailable, "the room index is the daemon's to change") }
        await workspaceGate.lock("room-index")
        defer { workspaceGate.unlock("room-index") }
        var idx = try ChatRoomIndex.load(chatPaths)
        let before = idx
        let out = try change(&idx)
        if idx != before { try idx.write(chatPaths) }
        return out
    }

    /// Each room of `n` gets its id (made in the room index when it has none; its owner recorded when the workspace made it)
    /// and its ownership written into the record (read once from the log). Best effort; the daemon's only.
    func ensureRoomIDs(_ n: String) async {
        guard !readOnly, let rec = try? workspaceRecord(n), !rec.rooms.isEmpty else { return }
        let log = (try? workspaces.log(n)) ?? []
        var ids: [String: String] = [:]
        var owned: [String: Bool] = [:]
        for r in rec.rooms where r.goneAt == nil { owned[r.chatRoom] = WorkspaceRuns.owned(r, log: log) }
        guard let got = try? await roomIndexUpdate({ idx -> [String: String] in
            for r in rec.rooms where r.goneAt == nil { ids[r.chatRoom] = idx.ensure(r.chatRoom, owner: owned[r.chatRoom] == true ? n : nil).id }
            return ids
        }) else { return }
        guard rec.rooms.contains(where: { $0.goneAt == nil && ($0.id != got[$0.chatRoom] || $0.owned == nil) }) else { return }
        _ = try? await workspaceUpdate(n) { r in
            for i in r.rooms.indices where r.rooms[i].goneAt == nil {
                if let id = got[r.rooms[i].chatRoom] { r.rooms[i].id = id }
                if r.rooms[i].owned == nil { r.rooms[i].owned = owned[r.rooms[i].chatRoom] }
            }
            return []
        }
    }

    /// Each room's newest seq now, as the chat server answers it (a room it does not answer for is left out).
    func roomLastSeqs(_ rec: WorkspaceRecord) async -> [String: Int64] {
        guard let chat = workspaceChat, await chat.readiness() == .ready else { return [:] }
        var out: [String: Int64] = [:]
        for r in rec.rooms where r.goneAt == nil { if let s = try? chat.lastSeq(room: r.chatRoom) { out[r.chatRoom] = s } }
        return out
    }

    /// A run opened now (the kick-off, a reopen): each room's last seq is its start marker. Nothing is posted. When one is
    /// open already, that one is answered.
    @discardableResult
    func openRun(_ n: String) async throws -> WorkspaceRun {
        await ensureRoomIDs(n)
        let rec = try workspaceRecord(n)
        if let r = rec.openRun { return r }
        let seqs = await roomLastSeqs(rec)
        var opened: WorkspaceRun?
        _ = try await workspaceUpdate(n) { r in
            if let o = r.openRun { opened = o; return [] }
            let run = WorkspaceRuns.open(r, at: Date(), lastSeq: seqs)
            r.runs.append(run)
            opened = run
            return [WorkspaceLogEntry(action: "run-opened", run: run.id)]
        }
        note(nil, "workspace \(n): run \(opened!.id) opened")
        return opened!
    }

    /// The open run closed (finish, archive) with each room's last seq at its close (`toSeq`); a record started before runs
    /// were kept gets its implicit run first (legacy). Answers the closed run (nil: there was none — it never started).
    @discardableResult
    func closeRun(_ n: String, by verb: String, toSeq: [String: Int64], noArchive: Bool = false, at: Date = Date()) async throws -> WorkspaceRun? {
        var closed: WorkspaceRun?
        _ = try await workspaceUpdate(n) { r in
            if r.openRunIndex == nil, let legacy = WorkspaceRuns.legacyRun(r) { r.runs.append(legacy) }
            guard let i = r.openRunIndex else { return [] }
            WorkspaceRuns.close(&r.runs[i], at: at, toSeq: toSeq, by: verb)
            if noArchive { r.runs[i].noArchive = true }
            closed = r.runs[i]
            return [WorkspaceLogEntry(action: "run-closed", reason: verb, run: r.runs[i].id)]
        }
        if let c = closed { note(nil, "workspace \(n): run \(c.id) closed (\(verb))") }
        return closed
    }

    // MARK: workspace-runs

    /// `workspace-runs`: the runs with their archives' status, sizes and totals — read from the store (never the chat server,
    /// never a daemon started).
    func workspaceRuns(_ w: WorkspaceRequest) throws -> WorkspaceRunsListing {
        let n = try workspaceName(w)
        let rec = try workspaceRecord(n)
        var rows: [WorkspaceRunRow] = []
        for run in rec.runs { rows.append(runRow(n, run)) }
        var note: String?
        if rec.runs.isEmpty {
            note = rec.flags.finishedAt != nil ? "no runs recorded (finished before runs were kept)"
                : rec.flags.startedAt == nil ? "no runs yet: the first one opens when doz workspace start \(n) kicks it off"
                : "no runs recorded yet: the work began before runs were kept — its finish records one"
        }
        return WorkspaceRunsListing(workspace: n, runs: rows, note: note)
    }

    func runRow(_ n: String, _ run: WorkspaceRun) -> WorkspaceRunRow {
        var status = "none"
        if run.isOpen { status = "open" }
        else if run.archiveProblem != nil { status = "problem" }
        else if let a = run.archive { status = MacFenceHostFS.kind(storeRoot + "/" + a) == S_IFDIR ? "written" : "missing" }
        var row = WorkspaceRunRow(id: run.id, startedAt: run.startedAt, endedAt: run.endedAt, minutes: WorkspaceRuns.minutes(run),
                                  archiveStatus: status, rooms: run.rooms)
        row.archive = run.archive
        row.archiveProblem = run.archiveProblem
        row.closedBy = run.closedBy
        row.legacy = run.legacy
        if status == "written", let a = run.archive {
            let root = storeRoot + "/" + a
            row.archiveBytes = RunArchiveSummary.bytes(root)
            if let s = RunArchiveSummary.read(root) {
                row.calls = s.calls; row.tokensIn = s.tokensIn; row.tokensOut = s.tokensOut; row.activeMinutes = s.activeMinutes; row.messages = s.messages
            }
        }
        return row
    }
}

/// What a run's row reads of its archive: its size (a bounded walk, no link followed) and the usage totals and message
/// count its files carry. Until a run has an archive, nothing.
public enum RunArchiveSummary {
    public struct Totals: Equatable, Sendable {
        public var calls: Int?, tokensIn: Int?, tokensOut: Int?, activeMinutes: Int?, messages: Int?
    }

    public static func bytes(_ root: String) -> Int64 {
        var total: Int64 = 0
        MacFenceHostFS.walk(root, maximum: 100_000, maxDepth: 8) { p, mode in
            if mode == S_IFREG { var st = stat(); if lstat(p, &st) == 0 { total += Int64(st.st_size) } }
            return true
        }
        return total
    }

    /// The totals from `usage.json` and `manifest.json` (nil: neither can be read).
    public static func read(_ root: String) -> Totals? {
        var t = Totals()
        var any = false
        if let d = try? MacFenceHostFS.readRegular(root + "/usage.json", maximum: 4 << 20),
           let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any], let tot = o["totals"] as? [String: Any] {
            t.calls = tot["calls"] as? Int
            let i = ["tokensNew", "tokensCacheWrite", "tokensCacheRead"].compactMap { tot[$0] as? Int }
            t.tokensIn = i.isEmpty ? nil : i.reduce(0, +)
            t.tokensOut = tot["tokensOut"] as? Int
            t.activeMinutes = tot["activeMinutes"] as? Int
            any = true
        }
        if let d = try? MacFenceHostFS.readRegular(root + "/manifest.json", maximum: 16 << 20),
           let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any], let rooms = o["messages"] as? [String: Int] {
            t.messages = rooms.values.reduce(0, +)
            any = true
        }
        return any ? t : nil
    }
}

// MARK: the evidence archive

/// The daemon's way into a sandbox for a run's archive: an exec to list (only while it runs — never woken) and a tar on the
/// guest stream to read one file, as `copy` does.
final class DaemonSandboxTranscripts: SandboxTranscriptSource, @unchecked Sendable {
    weak var core: HostCore?
    init(core: HostCore) { self.core = core }
    func list(sandbox: String, script: [String]) async throws -> String? { try await core?.sandboxTranscriptList(sandbox, script) }
    func tar(sandbox: String, argv: [String], maximum: Int) async throws -> Data {
        guard let core else { throw HostError(.unavailable, "the daemon is stopping") }
        return try await core.sandboxTranscriptTar(sandbox, argv, maximum: maximum)
    }
}

/// What a finish gathers while the agents still run: each sandbox agent's conversations and screen.
struct RunPreStop: Sendable {
    var transcripts: [RunTranscript] = []
    var screens: [String: String] = [:]
    var notes: [String] = []
}

extension HostCore {
    var sandboxTranscripts: any SandboxTranscriptSource { sandboxTranscriptsOverride ?? DaemonSandboxTranscripts(core: self) }

    func sandboxTranscriptList(_ s: String, _ script: [String]) async throws -> String? {
        guard let m = managed[s], await effectivePhase(m) == .running else { return nil }
        let r = try await m.sandbox.exec(script, user: m.config.spec.imageSpec?.user, timeoutSeconds: 30)
        return r.output
    }

    func sandboxTranscriptTar(_ s: String, _ argv: [String], maximum: Int) async throws -> Data {
        guard let m = managed[s], await effectivePhase(m) == .running else { throw HostError(.invalidPhase, "\(s) is not running") }
        let stream = try await m.sandbox.openGuestStream(argv, user: m.config.spec.imageSpec?.user)
        stream.finishInput()
        var out = Data()
        for await chunk in stream.output {
            out += chunk
            if out.count > maximum { throw HostError(.failed, "larger than \(maximum) bytes") }
        }
        return out
    }

    /// The agents a run's archive covers: every one not ended before the run began.
    func runAgents(_ rec: WorkspaceRecord, _ run: WorkspaceRun) -> [WorkspaceAgent] {
        rec.agents.filter { $0.endedAt == nil || $0.endedAt! >= run.startedAt }
    }

    static func roleName(_ a: WorkspaceAgent) -> String { a.isManager ? "manager" : a.isWorker ? "worker" : "adopted" }

    /// Before the agents stop: each sandbox agent's conversations (modified since the run began) and its last saved screen.
    func gatherBeforeStop(_ rec: WorkspaceRecord, _ run: WorkspaceRun) async -> RunPreStop {
        var out = RunPreStop()
        var done = Set<String>()
        for a in runAgents(rec, run) where a.endedAt == nil {
            guard let s = a.place.sandbox else { continue }
            if let m = managed[s], let saved = SavedScreens.read(m.sandbox.layout, session: a.place.session ?? a.name) { out.screens[a.name] = saved.text }
            // A shared sandbox: its conversations once, under the sandbox's name.
            let who = a.place.session != nil && a.isWorker ? s : a.name
            guard done.insert(who).inserted else { continue }
            let got = await SandboxTranscriptExport.collect(sandboxTranscripts, sandbox: s, agent: who, since: run.startedAt)
            out.transcripts += got.files
            out.notes += got.notes
            if who != a.name { out.notes.append("\(s) is shared: its conversations are under transcripts/\(s)/ (\(rec.agents.filter { $0.place.sandbox == s && $0.endedAt == nil }.map(\.name).joined(separator: ", ")))") }
        }
        return out
    }

    /// After the agents stopped: each session on this Mac's conversations (a fenced one's carried back as it ended) and its
    /// last screen.
    func gatherAfterStop(_ rec: WorkspaceRecord, _ run: WorkspaceRun) -> RunPreStop {
        var out = RunPreStop()
        guard !buildFlavor.isHelper else { return out }
        let since = MacTranscripts.stamp(run.startedAt)
        for a in runAgents(rec, run) where a.place.mac == true {
            guard let s = a.place.session else { continue }
            if let screen = mac.endedScreen(s) { out.screens[a.name] = screen.text }
            var r = HostRequest(.sessionTranscripts, name: MacPlace.name)
            r.session = s
            guard let l = try? macTranscriptsList(r) else { out.notes.append("\(a.name): no conversation of \(s) is kept"); continue }
            let items = l.items.filter { $0.endedAt >= since }.map { ($0, "archive") }
                + (l.conversations ?? []).map { ($0, $0.source ?? "conversation") }
            for (item, source) in items {
                switch TranscriptCopy.read(item.path, name: item.name, workdir: source == "archive" ? nil : l.workdir) {
                case .failure(let why):
                    out.notes.append("\(a.name): \(item.name) not copied (\(why.why))")
                case .success(let data):
                    if let want = item.sha256, want != TranscriptCopy.sha256(data) {
                        out.notes.append("\(a.name): \(item.name) changed since it was carried back — not copied")
                        continue
                    }
                    let name = source == "archive" ? "\(item.endedAt)-\(item.name)" : source == "carried" ? "carried-\(item.name)" : item.name
                    out.transcripts.append(RunTranscript(agent: a.name, name: name, source: source, data: data, session: s, sourcePath: item.path))
                }
            }
            for n in l.notes ?? [] { out.notes.append("\(a.name): \(n)") }
        }
        return out
    }

    /// The run's archive written from what was gathered: the chat slice read now, everything swept, verified and put in place.
    /// Answers its path and its manifest's sha256, or throws why it was not kept (nothing else is touched).
    func writeRunArchive(_ rec: WorkspaceRecord, _ run: WorkspaceRun, plan: WorkspaceLifecyclePlan?, gathered: RunPreStop) async throws -> (path: String, sha: String) {
        let n = rec.name
        var e = RunEvidence(workspace: n, run: run, endedAt: run.endedAt ?? Date(), brief: Data((workspaceBriefText(rec) ?? "").utf8))
        e.plan = try plan.map { try JSONValue(encoding: $0) }
        for r in run.rooms { e.rooms[r.room] = r.id ?? (rec.rooms.first { $0.chatRoom == r.room }?.id ?? "") }
        e.versions = ["doz": version]
        e.transcripts = gathered.transcripts
        e.screens = gathered.screens
        e.notes = gathered.notes
        e.agents = runAgents(rec, run).map { a in
            (a.name, Self.roleName(a), a.place.key == nil ? "elsewhere: its conversations are on its own machine" : nil)
        }
        var fetch: ChatExport.Fetch?
        if !run.rooms.isEmpty {
            guard let chat = workspaceChat, await chat.readiness() == .ready else {
                throw HostError(.unavailable, "chat is not ready: the run's messages cannot be read — doz chat status")
            }
            let f: ChatExport.Fetch = { try chat.fetch($0) }
            fetch = f
            if let a = try? chat.fetch("/api/state"), a.status == 200, let v = try? ChatJSON.parse(a.body) { e.you = ChatStateView(v).human ?? "you" }
            for r in run.rooms {
                do { e.chat[r.room] = try ChatExport.messages(room: r.room, fromSeq: r.fromSeq, toSeq: r.toSeq, fetch: f) } catch {
                    throw HostError(.failed, "the messages of \(r.room) cannot be read: \(HostError.from(error).message)")
                }
            }
        }
        let sweep = ExportSweep.forStore(store)
        let out = try RunArchive.write(e, store: store, sweep: sweep, verifySweep: archiveVerifySweepOverride, fetch: fetch)
        return (out.path, out.sha256)
    }

    /// Records the archive of `runID` (or why it was not written) in the record and the log.
    func recordRunArchive(_ n: String, _ runID: String, path: String?, sha: String?, problem: String?) async {
        _ = try? await workspaceUpdate(n) { r in
            guard let i = r.runs.firstIndex(where: { $0.id == runID }) else { return [] }
            r.runs[i].archive = path
            r.runs[i].archiveSHA256 = sha
            r.runs[i].archiveProblem = problem
            if let problem { return [WorkspaceLogEntry(action: "run-archive-failed", reason: problem, run: runID)] }
            let files = path.flatMap { RunArchive.verify(root: self.storeRoot + "/" + $0).manifest?.files.count }
            return [WorkspaceLogEntry(action: "run-archived", sha256: sha, added: files, run: runID)]
        }
    }

    /// `workspace-run-archive`: a closed run's archive written again (its problem cleared). What a sandbox held is not
    /// copied now — its VM is shut down: said in the notes.
    func workspaceRunArchive(_ w: WorkspaceRequest) async throws -> WorkspaceChanged {
        let n = try workspaceName(w)
        guard let id = w.run, WorkspaceRuns.isValidID(id) else { throw HostError(.invalid, "which run? doz workspace runs \(n)") }
        await workspaceGate.lock("workspace:" + n)
        defer { workspaceGate.unlock("workspace:" + n) }
        let rec = try workspaceRecord(n)
        guard let run = rec.runs.first(where: { $0.id == id }) else { throw HostError(.notFound, "\(n) has no run \(id) (doz workspace runs \(n))") }
        guard !run.isOpen else { throw HostError(.invalidPhase, "run \(id) is still open — its archive is written when \(n) finishes") }
        if run.archive != nil, run.archiveProblem == nil { throw HostError(.exists, "the archive of run \(id) is written already") }
        var g = gatherAfterStop(rec, run)
        if rec.agents.contains(where: { $0.place.sandbox != nil }) { g.notes.append("a sandbox's conversations are copied only while it runs, at finish: not copied now") }
        do {
            let (path, sha) = try await writeRunArchive(rec, run, plan: nil, gathered: g)
            await recordRunArchive(n, id, path: path, sha: sha, problem: nil)
            var c = WorkspaceChanged(name: n, verb: "run-archive", results: [], notes: g.notes.isEmpty ? nil : g.notes, workspace: nil)
            c.run = id; c.archive = path; c.archiveSHA256 = sha
            return c
        } catch {
            let why = HostError.from(error).message
            await recordRunArchive(n, id, path: nil, sha: nil, problem: why)
            throw HostError(HostError.from(error).code, "the archive of run \(id) was not written: \(why)")
        }
    }
}

// MARK: the closed set

extension HostCore {
    /// The rooms `rec` owns (made them), by the record or its log.
    func ownedRooms(_ rec: WorkspaceRecord) -> [String] {
        let log = (try? workspaces.log(rec.name)) ?? []
        return rec.rooms.filter { $0.goneAt == nil && WorkspaceRuns.owned($0, log: log) }.map(\.chatRoom)
    }

    /// The closed set worked out from the records (`WorkspaceRuns.closedSet`), plus `extra`, handed to the chat server (the
    /// whole set, every time). Answers each room's last seq as the server took it (nil: no server took it now — it is handed
    /// over at its start).
    @discardableResult
    func pushClosedSet(extra: [String: String] = [:]) async -> [String: Int64]? {
        guard !readOnly, let chat = workspaceChat else { return nil }
        var logs: [String: [WorkspaceLogEntry]] = [:]
        var set = WorkspaceRuns.closedSet(workspaces.records()) { rec, room in
            if let o = room.owned { return o }
            if logs[rec.name] == nil { logs[rec.name] = (try? self.workspaces.log(rec.name)) ?? [] }
            return WorkspaceRuns.owned(room, log: logs[rec.name]!)
        }
        set.merge(extra) { _, b in b }
        return try? await chat.setClosed(set)
    }
}

// MARK: a run's archived chat

extension HostCore {
    /// `workspace-run-chat`: a room's messages of a closed run, read from its archive once the archive verifies.
    func workspaceRunChat(_ w: WorkspaceRequest) throws -> WorkspaceRunChat {
        let n = try workspaceName(w)
        let rec = try workspaceRecord(n)
        guard let id = w.run, WorkspaceRuns.isValidID(id), let run = rec.runs.first(where: { $0.id == id }) else {
            throw HostError(.notFound, "\(n) has no such run (doz workspace runs \(n))")
        }
        guard let room = w.runRoom, run.rooms.contains(where: { $0.room == room }) else { throw HostError(.notFound, "run \(id) has no such room") }
        guard let a = run.archive else { throw HostError(.notFound, "run \(id) has no archive") }
        let root = storeRoot + "/" + a
        let v = RunArchive.verify(root: root)
        guard v.ok else { throw HostError(.failed, "run \(id)'s archive does not verify: " + v.problems.prefix(2).joined(separator: "; ")) }
        let fd = open(root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw HostError(.notFound, "run \(id)'s archive is not there") }
        let folder = ExportFolder(adopting: fd, path: root)
        var all: [WorkspaceRunChat.Message] = []
        if let bytes = try? folder.read("chat/\(room).jsonl") {
            for line in bytes.split(separator: 0x0A) {
                guard let o = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { continue }
                all.append(.init(seq: (o["seq"] as? NSNumber)?.int64Value ?? 0, from: o["from"] as? String ?? "?", content: o["content"] as? String ?? "",
                                 at: (o["at"] as? NSNumber)?.doubleValue, kind: (o["kind"] as? String).flatMap { $0.isEmpty ? nil : $0 }))
            }
        }
        let limit = max(1, min(w.limit ?? 500, 500))
        var page = all
        if let b = w.before { page = page.filter { $0.seq < Int64(b) } }
        let more = page.count > limit
        page = Array(page.suffix(limit))
        let sheet = (try? folder.read("timesheet.md")).map { String(decoding: $0, as: UTF8.self) }
        return WorkspaceRunChat(workspace: n, run: id, room: room, messages: page, more: more, timesheet: sheet)
    }
}
