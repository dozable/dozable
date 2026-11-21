import Darwin
import Foundation
import SQLite3

// 747: `<store>/timeline.sqlite` — the timeline's DERIVED store (0600, WAL, its own connections): one row per event
// with its summary, attrs and the sensitive ones apart (`sattrs`, never in the text index, a summary or a rollup), a
// trigram text index over the rest, the scopes, renames, minute rollups (hours and days written before minutes go), event
// bins for time whose single events have gone, the tailer's cursors and what retention has removed so far. Everything in
// it is made again from the primary records (`metrics.sqlite`, the workspace and grants logs, the chat server's rooms,
// a space's frames): deleting the file loses only what retention already removed from those (`doz timeline rebuild`).

public struct TimelineDBError: Error, LocalizedError {
    public var message: String
    public var errorDescription: String? { "timeline database: \(message)" }
}

/// A value bound to, or read from, a statement.
public enum SQLValue: Equatable, Sendable {
    case int(Int64), real(Double), text(String), null
    public static func opt(_ s: String?) -> SQLValue { s.map(SQLValue.text) ?? .null }
    public static func opt(_ i: Int64?) -> SQLValue { i.map(SQLValue.int) ?? .null }
    public static func opt(_ d: Double?) -> SQLValue { d.map(SQLValue.real) ?? .null }
    public var int: Int64? { switch self { case .int(let i): return i; case .real(let d): return Int64(d); default: return nil } }
    public var real: Double? { switch self { case .real(let d): return d; case .int(let i): return Double(i); default: return nil } }
    public var text: String? { if case .text(let s) = self { return s }; return nil }
}

/// One SQLite connection, serialised by a lock (every statement and transaction).
public final class SQLiteDB: @unchecked Sendable {
    let db: OpaquePointer?
    public let path: String
    let lock = NSRecursiveLock()
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// `readOnly`: opened `mode=ro` through a URI (the chat server's rooms, the metrics as read by the indexer) — a
    /// read never changes the file.
    public init(path: String, readOnly: Bool, create: Bool = false) throws {
        self.path = path
        var h: OpaquePointer?
        let rc: Int32
        if readOnly {
            let uri = "file:" + Self.uriPath(path) + "?mode=ro"
            rc = sqlite3_open_v2(uri, &h, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_FULLMUTEX, nil)
        } else {
            rc = sqlite3_open_v2(path, &h, SQLITE_OPEN_READWRITE | (create ? SQLITE_OPEN_CREATE : 0) | SQLITE_OPEN_FULLMUTEX, nil)
        }
        guard rc == SQLITE_OK else {
            let msg = h.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            sqlite3_close(h)
            throw TimelineDBError(message: "\(DisplayPath.tilde(path)): \(msg)")
        }
        db = h
        sqlite3_busy_timeout(h, 2000)
        try? exec("PRAGMA trusted_schema=OFF")
    }
    deinit { sqlite3_close(db) }

    static func uriPath(_ p: String) -> String {
        let ok = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~/")
        return p.addingPercentEncoding(withAllowedCharacters: ok) ?? p
    }

    var message: String { String(cString: sqlite3_errmsg(db)) }

    public func exec(_ sql: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw TimelineDBError(message: message) }
    }

    private func prepare(_ sql: String, _ args: [SQLValue]) throws -> OpaquePointer? {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { throw TimelineDBError(message: message + " — " + sql.prefix(80)) }
        for (i, a) in args.enumerated() {
            let idx = Int32(i + 1)
            switch a {
            case .int(let v): sqlite3_bind_int64(st, idx, v)
            case .real(let v): sqlite3_bind_double(st, idx, v)
            case .text(let v): sqlite3_bind_text(st, idx, v, -1, Self.transient)
            case .null: sqlite3_bind_null(st, idx)
            }
        }
        return st
    }

    /// One statement; the rows it changed.
    @discardableResult
    public func run(_ sql: String, _ args: [SQLValue] = []) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        let st = try prepare(sql, args)
        defer { sqlite3_finalize(st) }
        let rc = sqlite3_step(st)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw TimelineDBError(message: message) }
        return Int(sqlite3_changes(db))
    }

    public func rows(_ sql: String, _ args: [SQLValue] = []) throws -> [[SQLValue]] {
        lock.lock(); defer { lock.unlock() }
        let st = try prepare(sql, args)
        defer { sqlite3_finalize(st) }
        var out: [[SQLValue]] = []
        let n = sqlite3_column_count(st)
        while true {
            let rc = sqlite3_step(st)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw TimelineDBError(message: message) }
            var row: [SQLValue] = []
            row.reserveCapacity(Int(n))
            for i in 0..<n {
                switch sqlite3_column_type(st, i) {
                case SQLITE_INTEGER: row.append(.int(sqlite3_column_int64(st, i)))
                case SQLITE_FLOAT: row.append(.real(sqlite3_column_double(st, i)))
                case SQLITE_NULL: row.append(.null)
                default: row.append(.text(sqlite3_column_text(st, i).map { String(cString: $0) } ?? ""))
                }
            }
            out.append(row)
        }
        return out
    }

    public func scalar(_ sql: String, _ args: [SQLValue] = []) throws -> SQLValue {
        try rows(sql, args).first?.first ?? .null
    }

    /// `body` in one transaction (rolled back when it throws).
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        try exec("BEGIN IMMEDIATE")
        do { let v = try body(); try exec("COMMIT"); return v } catch { try? exec("ROLLBACK"); throw error }
    }
}

/// One event as the derived store holds it: its scope relative to the host (the host segment is added when it is
/// answered, so renaming the Mac relabels without rewriting), its sensitive attrs apart.
public struct StoredEvent: Equatable, Sendable {
    public var id: String
    public var source: String
    public var t: Int64
    public var dur: Int64?
    public var open: Bool
    /// Host-relative: "" is the host itself, `workspace:w/sandbox:s` below it.
    public var scope: String
    public var kind: String
    public var severity: TimelineSeverity
    public var summary: String
    public var attrs: [String: TimelineAttr]
    public var sattrs: [String: TimelineAttr]
    public var links: TimelineLinks

    public init(id: String, source: String, t: Int64, dur: Int64? = nil, open: Bool = false, scope: String, kind: String,
                severity: TimelineSeverity = .info, summary: String, attrs: TimelineAttrs.Builder = .init(), sattrs: TimelineAttrs.Builder = .init(),
                links: TimelineLinks = TimelineLinks()) {
        self.id = id; self.source = source; self.t = t; self.dur = dur; self.open = open; self.scope = scope; self.kind = kind
        self.severity = severity; self.summary = TimelineText.line(summary); self.attrs = attrs.attrs; self.sattrs = sattrs.attrs; self.links = links
    }

    /// What free text searches: the summary, kind, source, scope and the non-sensitive string attrs, lowercased, each
    /// apart (a value never matches across two of them).
    public func hay(host: String) -> String {
        var parts = [summary, kind, source, TimelineStore.full(scope, host: host)]
        for k in attrs.keys.sorted() { if case .string(let s) = attrs[k]! { parts.append(s) } }
        return parts.map { $0.lowercased() }.joined(separator: "\u{1}")
    }

    /// As the contract's document: the host's scope added; sensitive attrs only when asked for.
    public func event(host: String, sensitive: Bool) -> TimelineEvent {
        var a = attrs
        if sensitive { for (k, v) in sattrs { a[k] = v } }
        return TimelineEvent(id: id, t: t, dur: dur, open: open ? true : nil, scope: TimelineStore.full(scope, host: host), source: source,
                             kind: kind, severity: severity, summary: summary, attrs: a, links: links)
    }
}

/// The derived store: its schema, upserts and reads. Written by the indexer only (one serial queue); read by queries
/// on their own connection.
public final class TimelineStore: @unchecked Sendable {
    public static let schemaVersion = 1
    public let url: URL
    public let db: SQLiteDB
    /// The newest `rev` given (a change's order: subscribe resumes from it, a restart included).
    private var revSeq: Int64 = 0
    private let revLock = NSLock()
    /// This host's segment, as free text sees an event's scope.
    public var host = MacDisplayName.scope()
    /// Scopes already noted (with their ancestors) by this connection.
    private var known: Set<String> = []

    public static func url(_ store: DozableStore) -> URL { store.root.appendingPathComponent("timeline.sqlite") }

    /// A scope as answered: under the host's segment.
    public static func full(_ rel: String, host: String) -> String { rel.isEmpty ? host : host + "/" + rel }
    /// A query's scope relative to this host (nil: not this host's).
    public static func relative(_ full: String, host: String) -> String? {
        if full == host { return "" }
        if full.hasPrefix(host + "/") { return String(full.dropFirst(host.count + 1)) }
        return nil
    }

    static let schema: [String] = [
        "CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT)",
        """
        CREATE TABLE IF NOT EXISTS events (id TEXT PRIMARY KEY, source TEXT NOT NULL, t INTEGER NOT NULL, dur INTEGER, open INTEGER NOT NULL DEFAULT 0,
          scope TEXT NOT NULL, kind TEXT NOT NULL, sev INTEGER NOT NULL, summary TEXT NOT NULL, attrs TEXT NOT NULL, sattrs TEXT,
          l_run TEXT, l_ask TEXT, l_msg TEXT, l_session TEXT, l_decision TEXT, rev INTEGER NOT NULL, hay TEXT NOT NULL)
        """,
        "CREATE INDEX IF NOT EXISTS events_scope_t ON events(scope, t)",
        "CREATE INDEX IF NOT EXISTS events_t_id ON events(t, id)",
        "CREATE INDEX IF NOT EXISTS events_source_t ON events(source, t)",
        "CREATE INDEX IF NOT EXISTS events_rev ON events(rev)",
        "CREATE INDEX IF NOT EXISTS events_spans ON events(t + COALESCE(dur, 0)) WHERE dur IS NOT NULL OR open = 1",
        "CREATE VIRTUAL TABLE IF NOT EXISTS events_fts USING fts5(hay, content='events', content_rowid='rowid', tokenize='trigram')",
        "CREATE TRIGGER IF NOT EXISTS events_ai AFTER INSERT ON events BEGIN INSERT INTO events_fts(rowid, hay) VALUES (new.rowid, new.hay); END",
        "CREATE TRIGGER IF NOT EXISTS events_ad AFTER DELETE ON events BEGIN INSERT INTO events_fts(events_fts, rowid, hay) VALUES ('delete', old.rowid, old.hay); END",
        """
        CREATE TRIGGER IF NOT EXISTS events_au AFTER UPDATE OF hay ON events BEGIN
          INSERT INTO events_fts(events_fts, rowid, hay) VALUES ('delete', old.rowid, old.hay);
          INSERT INTO events_fts(rowid, hay) VALUES (new.rowid, new.hay); END
        """,
        "CREATE TABLE IF NOT EXISTS scopes (scope TEXT PRIMARY KEY, parent TEXT NOT NULL, kind TEXT NOT NULL, label TEXT NOT NULL, space INTEGER NOT NULL DEFAULT 0, first_t INTEGER, last_t INTEGER)",
        "CREATE INDEX IF NOT EXISTS scopes_parent ON scopes(parent)",
        "CREATE TABLE IF NOT EXISTS names (scope TEXT NOT NULL, alias_of TEXT NOT NULL, at INTEGER NOT NULL, PRIMARY KEY (scope, alias_of))",
        """
        CREATE TABLE IF NOT EXISTS rollups (series TEXT NOT NULL, scope TEXT NOT NULL, bin TEXT NOT NULL, t INTEGER NOT NULL, min REAL NOT NULL,
          max REAL NOT NULL, sum REAL NOT NULL, count INTEGER NOT NULL, rev INTEGER NOT NULL, PRIMARY KEY (series, scope, bin, t)) WITHOUT ROWID
        """,
        "CREATE INDEX IF NOT EXISTS rollups_t ON rollups(bin, t)",
        "CREATE INDEX IF NOT EXISTS rollups_rev ON rollups(rev)",
        """
        CREATE TABLE IF NOT EXISTS ebins (source TEXT NOT NULL, scope TEXT NOT NULL, bin TEXT NOT NULL, t INTEGER NOT NULL, count INTEGER NOT NULL,
          sev0 INTEGER NOT NULL DEFAULT 0, sev1 INTEGER NOT NULL DEFAULT 0, sev2 INTEGER NOT NULL DEFAULT 0, sev3 INTEGER NOT NULL DEFAULT 0,
          sev4 INTEGER NOT NULL DEFAULT 0, kinds TEXT NOT NULL, kinds_truncated INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (source, scope, bin, t)) WITHOUT ROWID
        """,
        "CREATE TABLE IF NOT EXISTS cursors (key TEXT PRIMARY KEY, pos TEXT NOT NULL)",
        // What retention removed so far: before each cut point nothing of that level is held (null: nothing removed).
        "CREATE TABLE IF NOT EXISTS kept (source TEXT PRIMARY KEY, events INTEGER, m1 INTEGER, h1 INTEGER, d1 INTEGER, pruned_rev INTEGER NOT NULL DEFAULT 0)",
    ]

    /// An empty store in memory (a look with no derived file yet answers from it: nothing).
    public static func empty() throws -> TimelineStore { try TimelineStore(memory: ()) }

    private init(memory: ()) throws {
        url = URL(fileURLWithPath: "/dev/null")
        db = try SQLiteDB(path: ":memory:", readOnly: false, create: true)
        for s in Self.schema { try db.exec(s) }
    }

    /// Open (and make, 0600) the store's file.
    public init(url: URL, readOnly: Bool = false) throws {
        self.url = url
        if readOnly {
            db = try SQLiteDB(path: url.path, readOnly: true)
        } else {
            try Self.refuseLink(url)
            let fresh = !FileManager.default.fileExists(atPath: url.path)
            if fresh {
                let fd = open(url.path, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW, 0o600)
                if fd >= 0 { close(fd) }
            }
            db = try SQLiteDB(path: url.path, readOnly: false, create: true)
            chmod(url.path, 0o600)
            try db.exec("PRAGMA journal_mode=WAL")
            try db.exec("PRAGMA synchronous=NORMAL")
            for s in Self.schema { try db.exec(s) }
            if try db.scalar("SELECT value FROM meta WHERE key = 'schema'").text == nil {
                try db.run("INSERT OR REPLACE INTO meta (key, value) VALUES ('schema', ?), ('built_at', ?), ('tz', ?)",
                           [.text(String(Self.schemaVersion)), .text(String(Int64(Date().timeIntervalSince1970 * 1000))), .text(TimeZone.current.identifier)])
            }
            for suffix in ["-wal", "-shm"] { chmod(url.path + suffix, 0o600) }
        }
        let a = try db.scalar("SELECT MAX(rev) FROM events").int ?? 0
        let b = try db.scalar("SELECT MAX(rev) FROM rollups").int ?? 0
        let c = (try? db.scalar("SELECT MAX(pruned_rev) FROM kept").int) ?? 0
        revSeq = max(a, b, c ?? 0)
    }

    /// The file is never a link (nothing in the store is followed out of it).
    static func refuseLink(_ url: URL) throws {
        var st = stat()
        if lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) != S_IFREG {
            throw TimelineDBError(message: "\(DisplayPath.tilde(url.path)) is not a regular file — refused")
        }
    }

    public func nextRev() -> Int64 { revLock.lock(); defer { revLock.unlock() }; revSeq += 1; return revSeq }
    public var currentRev: Int64 { revLock.lock(); defer { revLock.unlock() }; return revSeq }

    // MARK: writes (the indexer's queue)

    static func json(_ a: [String: TimelineAttr]) -> String {
        (try? HostWire.encoder.encode(a)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    /// Insert or replace each event by its id (a later write of the same record replaces it, its `rev` bumped), and note
    /// its scope with every ancestor.
    public func upsert(_ events: [StoredEvent]) throws {
        guard !events.isEmpty else { return }
        try db.transaction {
            for e in events {
                try db.run("""
                    INSERT INTO events (id, source, t, dur, open, scope, kind, sev, summary, attrs, sattrs, l_run, l_ask, l_msg, l_session, l_decision, rev, hay)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                    ON CONFLICT(id) DO UPDATE SET source = excluded.source, t = excluded.t, dur = excluded.dur, open = excluded.open,
                      scope = excluded.scope, kind = excluded.kind, sev = excluded.sev, summary = excluded.summary, attrs = excluded.attrs,
                      sattrs = excluded.sattrs, l_run = excluded.l_run, l_ask = excluded.l_ask, l_msg = excluded.l_msg,
                      l_session = excluded.l_session, l_decision = excluded.l_decision, rev = excluded.rev, hay = excluded.hay
                    WHERE events.t IS NOT excluded.t OR events.dur IS NOT excluded.dur OR events.open IS NOT excluded.open
                      OR events.scope IS NOT excluded.scope OR events.kind IS NOT excluded.kind OR events.sev IS NOT excluded.sev
                      OR events.summary IS NOT excluded.summary OR events.attrs IS NOT excluded.attrs OR events.sattrs IS NOT excluded.sattrs
                      OR events.l_run IS NOT excluded.l_run OR events.l_ask IS NOT excluded.l_ask OR events.l_msg IS NOT excluded.l_msg
                      OR events.l_session IS NOT excluded.l_session OR events.l_decision IS NOT excluded.l_decision
                    """, [.text(e.id), .text(e.source), .int(e.t), .opt(e.dur), .int(e.open ? 1 : 0), .text(e.scope), .text(e.kind),
                          .int(Int64(e.severity.rank)), .text(e.summary), .text(Self.json(e.attrs)),
                          e.sattrs.isEmpty ? .null : .text(Self.json(e.sattrs)), .opt(e.links.run), .opt(e.links.ask), .opt(e.links.msg),
                          .opt(e.links.session), .opt(e.links.decision), .int(nextRev()), .text(e.hay(host: host))])
                try noteOnce(e.scope, t: e.t)
            }
        }
    }

    func noteOnce(_ scope: String, t: Int64) throws {
        revLock.lock(); let seen = known.contains(scope); revLock.unlock()
        guard !seen else { return }
        try noteScope(scope, t: t)
        revLock.lock(); known.insert(scope); revLock.unlock()
    }

    /// A scope and each of its ancestors, with the first and last times seen.
    public func noteScope(_ scope: String, t: Int64?, label: String? = nil, space: Bool = false) throws {
        var s = scope
        while !s.isEmpty {
            let parent = TimelineScope.parent(s)
            try db.run("""
                INSERT INTO scopes (scope, parent, kind, label, space, first_t, last_t) VALUES (?,?,?,?,?,?,?)
                ON CONFLICT(scope) DO UPDATE SET first_t = MIN(COALESCE(first_t, excluded.first_t), COALESCE(excluded.first_t, first_t)),
                  last_t = MAX(COALESCE(last_t, excluded.last_t), COALESCE(excluded.last_t, last_t)),
                  label = CASE WHEN ? IS NOT NULL THEN excluded.label ELSE label END,
                  space = MAX(space, excluded.space)
                """, [.text(s), .text(parent), .text(TimelineScope.kind(s)), .text(s == scope ? (label ?? TimelineScope.name(s)) : TimelineScope.name(s)),
                      .int(s == scope && space ? 1 : 0), .opt(t), .opt(t), s == scope ? .opt(label) : .null])
            s = parent
        }
    }

    /// A scope's label (a room's name for its `rm_` id) and whether a workspace is a space.
    public func label(_ scope: String, _ label: String, space: Bool = false) throws {
        try noteScope(scope, t: nil, label: label, space: space)
    }

    /// `old` was renamed to `new` (its history shows on the new scope's row).
    public func alias(_ old: String, to new: String, at: Int64) throws {
        guard old != new else { return }
        try db.run("INSERT OR IGNORE INTO names (scope, alias_of, at) VALUES (?,?,?)", [.text(new), .text(old), .int(at)])
    }

    /// Minute points of a series, replacing what each (series, scope, minute) held.
    public func putMinutes(_ points: [(series: String, scope: String, t: Int64, min: Double, max: Double, sum: Double, count: Int64)]) throws {
        guard !points.isEmpty else { return }
        try db.transaction {
            for p in points {
                try db.run("""
                    INSERT INTO rollups (series, scope, bin, t, min, max, sum, count, rev) VALUES (?,?,'1m',?,?,?,?,?,?)
                    ON CONFLICT(series, scope, bin, t) DO UPDATE SET min = excluded.min, max = excluded.max, sum = excluded.sum,
                      count = excluded.count, rev = excluded.rev
                    WHERE rollups.min != excluded.min OR rollups.max != excluded.max OR rollups.sum != excluded.sum OR rollups.count != excluded.count
                    """, [.text(p.series), .text(p.scope), .int(p.t), .real(p.min), .real(p.max), .real(p.sum), .int(p.count), .int(nextRev())])
                try noteOnce(p.scope, t: p.t)
            }
        }
    }

    public func cursor(_ key: String) -> String? { (try? db.scalar("SELECT pos FROM cursors WHERE key = ?", [.text(key)]))?.text }
    public func setCursor(_ key: String, _ pos: String) throws {
        try db.run("INSERT INTO cursors (key, pos) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET pos = excluded.pos", [.text(key), .text(pos)])
    }
    public func cursors(prefix: String) -> [String: String] {
        var out: [String: String] = [:]
        for r in (try? db.rows("SELECT key, pos FROM cursors WHERE key GLOB ?", [.text(prefix + "*")])) ?? [] {
            if let k = r[0].text, let p = r[1].text { out[k] = p }
        }
        return out
    }

    public func meta(_ key: String) -> String? { (try? db.scalar("SELECT value FROM meta WHERE key = ?", [.text(key)]))?.text }
    public func setMeta(_ key: String, _ value: String) throws {
        try db.run("INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", [.text(key), .text(value)])
    }

    /// The ids of a source's events still open (their records are read again until they close).
    public func openIDs(_ source: String) -> [String] {
        ((try? db.rows("SELECT id FROM events WHERE source = ? AND open = 1", [.text(source)])) ?? []).compactMap { $0[0].text }
    }

    /// A contract event (a recording's, a test's) stored as the indexer would: its scope made relative to `host`, its
    /// sensitive attrs apart.
    public static func stored(_ e: TimelineEvent, host: String) -> StoredEvent? {
        guard let rel = relative(e.scope, host: host) else { return nil }
        var a = TimelineAttrs.Builder(), s = TimelineAttrs.Builder()
        for (k, v) in e.attrs { if TimelineSources.isSensitive(e.source, k) { s.set(k, v) } else { a.set(k, v) } }
        var out = StoredEvent(id: e.id, source: e.source, t: e.t, dur: e.dur, open: e.open == true, scope: rel, kind: e.kind, severity: e.severity,
                              summary: e.summary, attrs: a, sattrs: s, links: e.links)
        out.summary = e.summary
        return out
    }

    public var size: Int64 {
        var total: Int64 = 0
        for s in ["", "-wal", "-shm"] {
            var st = stat()
            if lstat(url.path + s, &st) == 0 { total += Int64(st.st_size) }
        }
        return total
    }
}
