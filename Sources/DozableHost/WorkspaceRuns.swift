import Foundation

// A workspace's runs (`WorkspaceRecord.runs`): one opens at `doz workspace start`'s kick-off (the first start) and at
// `reopen`; it closes at `finish`, and at `archive` when the archive does finish's steps. Sleep, wake, stop and start inside a
// run never close it. A run's rooms carry their markers as data — the room's last seq when it opened and when the room was
// closed — so the run's messages are exactly `fromSeq < seq <= toSeq`; nothing is posted. Pure: `WorkspaceRunsTests`.
// `docs/engineering/workspaces.md` ("Runs").

public enum WorkspaceRuns {
    /// A new run's id: `YYYY-MM-DD-N` in this Mac's time zone, N one more than the highest N of that day already in the
    /// record (a run id never repeats within a record, whatever was archived or pruned).
    public static func nextID(_ existing: [WorkspaceRun], at: Date, timeZone: TimeZone = .current) -> String {
        let day = dayString(at, timeZone: timeZone)
        var n = 0
        for r in existing where r.id.hasPrefix(day + "-") {
            if let k = Int(r.id.dropFirst(day.count + 1)) { n = max(n, k) }
        }
        return "\(day)-\(n + 1)"
    }

    public static func dayString(_ d: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    /// A run id as typed: `YYYY-MM-DD-N` (also a folder's name — checked before any path is built from it).
    public static func isValidID(_ s: String) -> Bool {
        s.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{1,6}$", options: .regularExpression) != nil
    }

    /// The rooms a run covers: the workspace's rooms that are not gone, each with its last seq now (`lastSeq`; a room the
    /// chat server does not answer for starts at 0 — everything in it is the run's).
    public static func open(_ rec: WorkspaceRecord, at: Date, lastSeq: [String: Int64], timeZone: TimeZone = .current) -> WorkspaceRun {
        let rooms = rec.rooms.filter { $0.goneAt == nil }.map { WorkspaceRunRoom(room: $0.chatRoom, id: $0.id, fromSeq: lastSeq[$0.chatRoom] ?? 0) }
        return WorkspaceRun(id: nextID(rec.runs, at: at, timeZone: timeZone), startedAt: at, rooms: rooms)
    }

    /// A record started before runs were kept, finishing now with none open: an implicit open run from its first start
    /// (`legacy`), its rooms from 0 (the whole history up to now is the run's). nil: one is open, or it never started.
    public static func legacyRun(_ rec: WorkspaceRecord, timeZone: TimeZone = .current) -> WorkspaceRun? {
        guard rec.openRun == nil, rec.runs.isEmpty, rec.flags.finishedAt == nil else { return nil }
        guard let start = rec.flags.startedAt ?? rec.flags.firstAgentAt else { return nil }
        var r = open(rec, at: start, lastSeq: [:], timeZone: timeZone)
        r.legacy = true
        return r
    }

    /// The open run closed: its end, each room's last seq (`toSeq`, the close's answer — a room not answered keeps nil and
    /// its slice is everything after `fromSeq`), who closed it.
    public static func close(_ run: inout WorkspaceRun, at: Date, toSeq: [String: Int64], by verb: String) {
        run.endedAt = at
        run.closedBy = verb
        for i in run.rooms.indices { if let t = toSeq[run.rooms[i].room] { run.rooms[i].toSeq = max(t, run.rooms[i].fromSeq) } }
    }

    /// Whether the workspace owns `room` (made it): the record's `owned` when set, else the log (`room-made` owned,
    /// `room-linked` not); a room neither says is not owned.
    public static func owned(_ room: WorkspaceRoom, log: [WorkspaceLogEntry]) -> Bool {
        if let o = room.owned { return o }
        for e in log.reversed() where e.room == room.chatRoom {
            if e.action == "room-made" { return true }
            if e.action == "room-linked" { return false }
        }
        return false
    }

    /// The archive's folder relative to the store: `archives/<workspace>/runs/<run>`.
    public static func archivePath(workspace: String, run: String) -> String { "archives/\(workspace)/runs/\(run)" }

    /// A run's length in whole minutes (to now while open).
    public static func minutes(_ r: WorkspaceRun, now: Date = Date()) -> Int {
        max(0, Int(((r.endedAt ?? now).timeIntervalSince(r.startedAt)) / 60))
    }

    /// The closed set, worked out from the records alone: every OWNED room of a workspace that is finished and not archived,
    /// whose last run was closed (a workspace finished before runs were kept is never closed after the fact), and not gone
    /// → its workspace. Archived outranks closed; an asleep workspace's rooms stay open. `owned` decides ownership.
    public static func closedSet(_ records: [WorkspaceRecord], owned: (WorkspaceRecord, WorkspaceRoom) -> Bool) -> [String: String] {
        var out: [String: String] = [:]
        for rec in records where rec.flags.finishedAt != nil && rec.flags.archivedAt == nil {
            guard let last = rec.runs.last, !last.isOpen else { continue }
            for room in rec.rooms where room.goneAt == nil && owned(rec, room) { out[room.chatRoom] = rec.name }
        }
        return out
    }
}

/// `workspace-runs`: a workspace's runs as a person reads them — answered from the store in-process (no daemon started).
public struct WorkspaceRunsListing: Codable, Equatable, Sendable {
    public var workspace: String
    public var runs: [WorkspaceRunRow]
    /// Said when there is nothing to list ("no runs recorded (finished before runs were kept)").
    public var note: String?
    public init(workspace: String, runs: [WorkspaceRunRow], note: String? = nil) { self.workspace = workspace; self.runs = runs; self.note = note }
}

/// One run: its window, its archive (status, place, size) and the timesheet's totals when its archive has them.
public struct WorkspaceRunRow: Codable, Equatable, Sendable {
    public var id: String
    public var startedAt: Date
    public var endedAt: Date?
    public var minutes: Int
    /// `open` (the run is open), `written`, `problem` (`archiveProblem` says why), `none` (finished with --no-archive, or
    /// before runs had archives), `missing` (recorded, but its folder is not there).
    public var archiveStatus: String
    /// Relative to the store.
    public var archive: String?
    public var archiveBytes: Int64?
    public var archiveProblem: String?
    public var closedBy: String?
    public var legacy: Bool?
    public var rooms: [WorkspaceRunRoom]
    /// From the archive's `usage.json`: model calls and tokens (in: new + cache write + cache read; out), and active minutes.
    public var calls: Int?
    public var tokensIn: Int?
    public var tokensOut: Int?
    public var activeMinutes: Int?
    /// The messages in its chat slice, by room (from the archive's manifest).
    public var messages: Int?
    public init(id: String, startedAt: Date, endedAt: Date?, minutes: Int, archiveStatus: String, rooms: [WorkspaceRunRoom]) {
        self.id = id; self.startedAt = startedAt; self.endedAt = endedAt; self.minutes = minutes; self.archiveStatus = archiveStatus; self.rooms = rooms
    }
}
