import DozableChat
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
    func closeRun(_ n: String, by verb: String, toSeq: [String: Int64], at: Date = Date()) async throws -> WorkspaceRun? {
        var closed: WorkspaceRun?
        _ = try await workspaceUpdate(n) { r in
            if r.openRunIndex == nil, let legacy = WorkspaceRuns.legacyRun(r) { r.runs.append(legacy) }
            guard let i = r.openRunIndex else { return [] }
            WorkspaceRuns.close(&r.runs[i], at: at, toSeq: toSeq, by: verb)
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
