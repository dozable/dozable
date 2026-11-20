import DozableChat
import Foundation

// `doz chat room archive R` and `doz chat room rm R`: owner-only operations of the daemon — never a slash command or a
// protocol message. Check, then ask: `chat-room-plan` answers what would be done and every refusal (read-only, in-process
// with no daemon — the room's last seq then "not known", the most cautious answer). The guards: the room is owned (the
// room index's owner, or a workspace that made it — a deleted workspace's included), or loose with `--loose` (the
// command line only: no workspace owns or links it); never a room a workspace links; never while its workspace's run is
// open. Archive writes the whole history into `<store>/archives/<owner, or _>/rooms/<room>-<id>/` (swept, verified),
// then archives the room as you. Rm requires the room archived and an archived copy that verifies NOW — its own, or its
// workspace's last run's when that covers every ordinary message — and the name typed; then the chat server removes it
// under its lock (refused when its last seq moved) through the control channel, and a tombstone stays. Nothing is
// removed before its archived copy is hash-checked. docs/engineering/chat.md ("Removing a room").

extension HostCore {
    func performRoomLifecycle(_ r: HostRequest) async throws -> JSONValue {
        guard let q = r.chatRoom else { throw HostError(.invalid, "which room? (doz chat rooms)") }
        guard chatIsRoomName(q.room) else { throw HostError(.invalid, "\(q.room.prefix(60)) is not a room name") }
        switch r.op {
        case .chatRoomPlan:
            let verb = q.verb ?? "archive"
            guard ["archive", "rm"].contains(verb) else { throw HostError(.invalid, "archive or rm") }
            return try JSONValue(encoding: await roomPlan(q.room, verb: verb, loose: q.loose == true).plan)
        case .chatRoomArchive, .chatRoomRm:
            guard !readOnly else { throw HostError(.unavailable, "\(r.op.rawValue) needs the daemon") }
            await workspaceGate.lock("room:" + q.room)
            defer { workspaceGate.unlock("room:" + q.room) }
            return try JSONValue(encoding: r.op == .chatRoomArchive ? try await roomArchive(q) : try await roomRemove(q))
        case .chatRoomClose, .chatRoomOpen:
            guard !readOnly else { throw HostError(.unavailable, "\(r.op.rawValue) needs the daemon") }
            await workspaceGate.lock("room:" + q.room)
            defer { workspaceGate.unlock("room:" + q.room) }
            return try JSONValue(encoding: try await roomCloseLoose(q, close: r.op == .chatRoomClose))
        default:
            throw HostError(.invalid, "not a room operation")
        }
    }

    /// What the plan knows besides the plan itself.
    struct RoomFacts {
        var lastSeq: Int64?
        var exists: Bool?
        var archived: Bool?
        /// The archived copy rm would rely on: its folder (relative to the store) and the run whose archive it is (nil: the room's own).
        var copy: (path: String, run: String?)?
    }

    func roomPlan(_ room: String, verb: String, loose: Bool) async -> (plan: ChatRoomPlan, facts: RoomFacts) {
        var refusals: [(HostError.Code, String)] = []
        func refuse(_ c: HostError.Code, _ s: String) { refusals.append((c, s)) }
        let idx = (try? ChatRoomIndex.load(chatPaths)) ?? ChatRoomIndex()
        let records = workspaces.records()
        var owner = idx.rooms[room]?.owner
        var linkedBy: [String] = []
        for rec in records {
            guard let wr = rec.rooms.first(where: { $0.chatRoom == room && $0.goneAt == nil }) else { continue }
            let log = (try? workspaces.log(rec.name)) ?? []
            if WorkspaceRuns.owned(wr, log: log) { owner = owner ?? rec.name } else { linkedBy.append(rec.name) }
        }
        var f = RoomFacts()
        var notes: [String] = []
        if !readOnly, let chat = workspaceChat, await chat.readiness() == .ready {
            let rooms = (try? chat.rooms()) ?? []
            f.exists = rooms.contains(room)
            if f.exists == true {
                f.lastSeq = try? chat.lastSeq(room: room)
                f.archived = (try? chat.archivedRooms())?.contains(room)
            }
        } else {
            notes.append(readOnly ? "no daemon runs: the room's last message is not known — it is checked when you act" : "chat is not ready: the room's last message is not known")
        }
        let closed = owner.flatMap { o in records.first { $0.name == o } }.map { rec in
            WorkspaceRuns.closedSet([rec]) { _, r in r.owned ?? true }[room] } ?? nil
        let tomb = idx.tombstone(room) != nil
        let state = f.exists == nil ? (idx.rooms[room] == nil && tomb ? .gone : (closed != nil ? .closed : .open))
            : RoomState.derive(exists: f.exists!, archived: f.archived == true, closedBy: closed, tombstone: tomb)
        var p = ChatRoomPlan(room: room, verb: verb, state: state.rawValue, confirm: verb == "rm" ? "typed" : "yes",
                             command: "doz chat room \(verb) \(room)" + (loose ? " --loose" : ""))
        p.id = idx.rooms[room]?.id
        p.owner = owner
        p.linkedBy = linkedBy.sorted()
        p.lastSeq = f.lastSeq
        p.messages = f.lastSeq.map { Int($0) }
        p.confirmName = verb == "rm" ? room : nil
        if f.exists == false {
            if let t = idx.tombstone(room) { refuse(.notFound, "\(room) is gone: it was removed for good — read it in \(DisplayPath.tilde(storeRoot + "/" + t.archive))") }
            else { refuse(.notFound, "no room \(room) (doz chat rooms)") }
        }
        if !linkedBy.isEmpty { refuse(.invalidPhase, "\(room) is linked by the workspace \(linkedBy.joined(separator: ", ")): a linked room is never archived or removed here") }
        else if owner == nil && !loose {
            refuse(.invalidPhase, "\(room) is a loose room (made and linked by none of your workspaces): --loose, on the command line only, takes one")
        }
        if let o = owner, let rec = records.first(where: { $0.name == o }), let run = rec.openRun {
            refuse(.invalidPhase, "\(o)'s run \(run.id) is open — doz workspace finish \(o) first")
        }
        let folderOwner = owner ?? "_"
        if verb == "archive" {
            p.archive = "archives/\(folderOwner)/rooms/\(room)-\(p.id ?? "rm_…")"
            if let a = idx.rooms[room]?.archive, let last = f.lastSeq, await roomCovered(room, since: a.lastSeq, last: last) == true,
               RunArchive.verify(root: storeRoot + "/" + a.path).ok, f.archived == true {
                refuse(.exists, "\(room) is archived already, with a copy that holds every message (\(DisplayPath.tilde(storeRoot + "/" + a.path)))")
            }
        } else {
            if f.lastSeq == nil, f.exists != false { refuse(.unavailable, "the room's last message is not known — doz chat status; rm needs the daemon and chat ready") }
            if f.archived == false { refuse(.invalidPhase, "\(room) is not archived — doz chat room archive \(room)\(loose ? " --loose" : "") first") }
            if let last = f.lastSeq {
                // Its own copy, else its workspace's last run's — either must hold every ordinary message and verify now.
                var why: String?
                if let a = idx.rooms[room]?.archive {
                    if await roomCovered(room, since: a.lastSeq, last: last) != true {
                        why = "\(room) changed since it was archived — doz chat room archive \(room) again"
                    } else if !RunArchive.verify(root: storeRoot + "/" + a.path).ok {
                        why = "\(room)'s archive does not verify now (\(DisplayPath.tilde(storeRoot + "/" + a.path))) — doz chat room archive \(room) again"
                    } else { f.copy = (a.path, nil) }
                }
                if f.copy == nil, let o = owner, let rec = records.first(where: { $0.name == o }),
                   let run = rec.runs.last(where: { r in r.archive != nil && r.rooms.contains { $0.room == room } }),
                   let to = run.rooms.first(where: { $0.room == room })?.toSeq, let path = run.archive,
                   await roomCovered(room, since: to, last: last) == true, RunArchive.verify(root: storeRoot + "/" + path).ok {
                    f.copy = (path, run.id)
                    why = nil
                }
                if f.copy == nil { refuse(.invalidPhase, why ?? "\(room) has no archived copy that holds every message — doz chat room archive \(room)\(loose ? " --loose" : "") first") }
            }
            p.archive = f.copy?.path
            p.archiveVerified = f.copy != nil
            p.run = f.copy?.run
            notes.append("rm removes the room for good: its members, its history in the chat server and its files; a tombstone and its archive stay")
        }
        p.refusals = refusals.map(\.1)
        p.refusalCode = refusals.first?.0.rawValue
        p.notes = notes
        let parts = [room, verb, p.id ?? "", owner ?? "", p.linkedBy.joined(separator: ","), p.state, p.lastSeq.map(String.init) ?? "",
                     p.archive ?? "", p.run ?? "", loose ? "loose" : ""] + p.refusals.sorted()
        p.sha = String(RunArchive.sha(Array(parts.joined(separator: "\u{1E}").utf8)).prefix(16))
        return (p, f)
    }

    /// Whether every message of `room` after `since` (up to `last`) is a recorded change — an archive line, a join — and no
    /// ordinary message (nil: it cannot be read).
    func roomCovered(_ room: String, since: Int64, last: Int64) async -> Bool? {
        if last <= since { return true }
        guard let chat = workspaceChat, let ms = try? ChatExport.messages(room: room, fromSeq: since, toSeq: last, fetch: { try chat.fetch($0) }) else { return nil }
        return ms.allSatisfy { !($0.field("kind")?.stringValue ?? "").isEmpty }
    }

    func roomArchive(_ q: ChatRoomRequest) async throws -> ChatRoomChanged {
        let room = q.room
        let (p, f) = await roomPlan(room, verb: "archive", loose: q.loose == true)
        if let want = q.ifPlan, want != p.sha { throw HostError(.invalidPhase, "\(room) changed since you looked — look again: doz chat room archive \(room) --dry-run") }
        if let first = p.refusals.first { throw HostError(HostError.Code(rawValue: p.refusalCode ?? "") ?? .invalidPhase, first) }
        guard let chat = workspaceChat, let last = f.lastSeq else { throw HostError(.unavailable, "chat is not ready — doz chat status") }
        let id = try await roomIndexUpdate { $0.ensure(room, owner: p.owner).id }
        let ms = try ChatExport.messages(room: room, fromSeq: 0, toSeq: last, fetch: { try chat.fetch($0) })
        let out = try RunArchive.writeRoom(room: room, id: id, owner: p.owner, messages: ms, store: store, sweep: ExportSweep.forStore(store),
                                           fetch: { try chat.fetch($0) })
        // The copy is in place and verified: now the room is archived as you.
        if f.archived != true { try chat.setArchived(room: room, true) }
        try await roomIndexUpdate { idx in idx.rooms[room]?.archive = ChatRoomIndex.ArchiveRef(path: out.path, lastSeq: last, sha256: out.sha256, at: Date()) }
        if let o = p.owner, workspaces.exists(o) { try? workspaces.append(o, WorkspaceLogEntry(action: "room-archived", room: room, sha256: out.sha256)) }
        HostLog.line("chat: archived the room \(room) (\(id)): \(ms.count) message\(ms.count == 1 ? "" : "s") into the store's \(out.path)")
        var c = ChatRoomChanged(room: room, verb: "archive")
        c.id = id
        c.archive = out.path
        c.notes = ["\(ms.count) message\(ms.count == 1 ? "" : "s") copied and verified; the room is read-only — doz chat room rm \(room) removes it for good"]
        return c
    }

    func roomRemove(_ q: ChatRoomRequest) async throws -> ChatRoomChanged {
        let room = q.room
        let (p, f) = await roomPlan(room, verb: "rm", loose: q.loose == true)
        if let want = q.ifPlan, want != p.sha { throw HostError(.invalidPhase, "\(room) changed since you looked — look again: doz chat room rm \(room) --dry-run") }
        if let first = p.refusals.first { throw HostError(HostError.Code(rawValue: p.refusalCode ?? "") ?? .invalidPhase, first) }
        guard q.confirm == room else { throw HostError(.invalid, "type the name \(room) to remove it — the name typed is not its name") }
        guard let chat = workspaceChat, let last = f.lastSeq, let copy = f.copy else { throw HostError(.unavailable, "chat is not ready — doz chat status") }
        // The copy is hash-checked again, just before the removal.
        guard RunArchive.verify(root: storeRoot + "/" + copy.path).ok else { throw HostError(.failed, "\(room)'s archive does not verify — nothing removed") }
        let id = try await roomIndexUpdate { $0.ensure(room, owner: p.owner).id }
        try await chat.removeRoom(room, id: id, lastSeq: last)
        let now = Date()
        let tomb: ChatRoomIndex.Tombstone? = try await roomIndexUpdate { idx in
            idx.bury(room, at: now, run: copy.run, archive: copy.path)
            return idx.tombstone(room)
        }
        if let o = p.owner, workspaces.exists(o) {
            _ = try? await workspaceUpdate(o) { r in
                for i in r.rooms.indices where r.rooms[i].chatRoom == room && r.rooms[i].goneAt == nil { r.rooms[i].goneAt = now }
                return [WorkspaceLogEntry(action: "room-removed", room: room, run: copy.run)]
            }
        }
        HostLog.line("chat: removed the room \(room) (\(id)) for good; its archive: the store's \(copy.path)")
        await pushClosedSet()
        var c = ChatRoomChanged(room: room, verb: "rm")
        c.id = id
        c.archive = copy.path
        c.tombstone = tomb
        c.notes = ["\(room) is gone; read it in \(DisplayPath.tilde(storeRoot + "/" + copy.path))" + (copy.run.map { " (run \($0)'s archive)" } ?? "")]
        return c
    }
}

// MARK: closing a loose room

extension HostCore {
    /// A loose room closed to new messages (still readable) or opened again: refused for a room a workspace made or links
    /// (finish and reopen, down and up close and open those), without `--loose`, and for a room that is gone or not there.
    /// The mark lives in the room index (`closedAt`); the chat server takes it in the closed set over the control channel.
    func roomCloseLoose(_ q: ChatRoomRequest, close: Bool) async throws -> ChatRoomChanged {
        let room = q.room
        let verb = close ? "close" : "open"
        guard q.loose == true else { throw HostError(.invalidPhase, "\(room): only a loose room is closed or opened by hand — --loose, on the command line only, takes one") }
        let idx = (try? ChatRoomIndex.load(chatPaths)) ?? ChatRoomIndex()
        for rec in workspaces.records() where rec.rooms.contains(where: { $0.chatRoom == room && $0.goneAt == nil }) {
            throw HostError(.invalidPhase, "\(room) is a room of the workspace \(rec.name): its finish closes it and its reopen opens it")
        }
        if let o = idx.rooms[room]?.owner { throw HostError(.invalidPhase, "\(room) was made by the workspace \(o)") }
        guard let chat = workspaceChat, await chat.readiness() == .ready else { throw HostError(.unavailable, "chat is not ready — doz chat status") }
        guard try chat.rooms().contains(room) else {
            if idx.tombstone(room) != nil { throw HostError(.notFound, "\(room) is gone: it was removed for good") }
            throw HostError(.notFound, "no room \(room) (doz chat rooms)")
        }
        let was = idx.rooms[room]?.closedAt != nil
        if was == close {
            var c = ChatRoomChanged(room: room, verb: verb)
            c.notes = ["#\(room) is \(close ? "closed" : "open") already"]
            return c
        }
        let id = try await roomIndexUpdate { i -> String in
            let id = i.ensure(room).id
            i.rooms[room]?.closedAt = close ? Date() : nil
            return id
        }
        await pushClosedSet()
        HostLog.line("chat: \(close ? "closed" : "opened") the loose room \(room) (\(id))")
        var c = ChatRoomChanged(room: room, verb: verb)
        c.id = id
        c.notes = [close ? "#\(room) is closed: it can still be read; doz chat room open \(room) --loose opens it again"
                         : "#\(room) is open again"]
        return c
    }
}
