import Darwin
import Foundation

// 747: fills `timeline.sqlite` from the primary records — primary first, derived second. Every source is read from a
// cursor (metrics rows past the last rowid and every row still open; a log by its creation time, inode and byte offset;
// a room by its seq and times; a run's frames by name), so a write's poke, the start-up catch-up, the hourly one and the
// first backfill are one code path, and a crash between the two writes loses nothing: the next pass picks it up. An
// upsert by id is idempotent (a rebuild gives the same ids and deletes nothing). One serial queue; the daemon's actor
// only pokes, never waits.

/// What changed, for the indexer (a poke coalesces: one pass per source at a time).
public enum TimelinePoke: String, Sendable, CaseIterable {
    case metrics, workspace, grants, chat, runs, samples, all
}

/// Pokes by store, so a write anywhere (`WorkspaceStore.append`, `GrantStore.append`, a frame) reaches the indexer of
/// that store's daemon without a reference to it. Nothing registered (a look in-process, a test): a poke does nothing.
public enum TimelineSignal {
    nonisolated(unsafe) private static var handlers: [String: @Sendable (TimelinePoke) -> Void] = [:]
    private static let lock = NSLock()
    static func key(_ root: String) -> String { WorkspaceStore.resolved(root) }
    public static func register(_ root: String, _ h: @escaping @Sendable (TimelinePoke) -> Void) {
        lock.lock(); handlers[key(root)] = h; lock.unlock()
    }
    public static func unregister(_ root: String) { lock.lock(); handlers[key(root)] = nil; lock.unlock() }
    public static func poke(_ root: String, _ p: TimelinePoke) {
        lock.lock(); let h = handlers[key(root)]; lock.unlock()
        h?(p)
    }
}

public final class TimelineIndexer: @unchecked Sendable {
    public let store: DozableStore
    let queue = DispatchQueue(label: "doz.timeline.indexer", qos: .utility)
    private let lock = NSLock()
    private var pending: Set<TimelinePoke> = []
    private var scheduled = false
    private var tstore: TimelineStore?
    private var metricsDB: SQLiteDB?
    /// The workspaces' membership (`sandbox:NAME` / `mac:SESSION` → workspace), read again when a workspace changes.
    private var membershipCache: (at: Date, map: [String: String])?
    private var spaces: Set<String> = []
    /// 0–100 while a first indexing (or a rebuild) runs; nil when done.
    private var _progress: Int?
    public var progress: Int? { lock.lock(); defer { lock.unlock() }; return _progress }
    /// Called after each pass that changed something (subscribers look for rows past their `rev`).
    public var onChange: (@Sendable () -> Void)?
    /// The clock: the Mac's, or a guarded test's.
    var now: () -> Date = { TimelineClock.now() }
    /// Rows per transaction during a backfill (and the pause between).
    static let slice = 10_000

    public init(store: DozableStore) { self.store = store }

    public var url: URL { TimelineStore.url(store) }

    /// The derived store, opened (made) on first use — and again when its file was deleted.
    func open() throws -> TimelineStore {
        if let t = tstore, FileManager.default.fileExists(atPath: t.url.path) { return t }
        let t = try TimelineStore(url: url)
        tstore = t
        membershipCache = nil
        return t
    }

    func metrics() throws -> SQLiteDB? {
        if let m = metricsDB { return m }
        guard FileManager.default.fileExists(atPath: store.metrics.path) else { return nil }
        let m = try SQLiteDB(path: store.metrics.path, readOnly: true)
        metricsDB = m
        return m
    }

    // MARK: pokes

    public func poke(_ p: TimelinePoke) {
        lock.lock()
        pending.insert(p)
        let go = !scheduled
        scheduled = true
        lock.unlock()
        // At most one pass a second: what a burst of writes pokes is read together.
        if go { queue.asyncAfter(deadline: .now() + .milliseconds(300)) { self.drain() } }
    }

    private func drain() {
        lock.lock()
        let what = pending
        pending = []
        scheduled = false
        lock.unlock()
        _ = pass(what)
    }

    /// Read every record again (`doz timeline rebuild`): every cursor forgotten, every event upserted — nothing deleted.
    /// `clean`: the derived file set aside first, so it starts empty (what retention removed from it is lost).
    public func rebuild(clean: Bool) {
        queue.sync {
            if clean {
                tstore = nil
                for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + s) }
            } else if let t = try? open() {
                try? t.db.run("DELETE FROM cursors")
                try? t.db.run("DELETE FROM meta WHERE key = 'backfilled'")
            }
            _ = pass([.all])
        }
    }

    /// Everything, now, on the queue (the start-up and hourly catch-ups, a test's wait).
    public func catchUpNow() { queue.sync { _ = self.pass([.all]) } }

    /// One pass over what was poked; true when something changed.
    @discardableResult
    func pass(_ what: Set<TimelinePoke>) -> Bool {
        guard let t = try? open() else { return false }
        let before = t.currentRev
        let all = what.contains(.all)
        let backfill = t.meta("backfilled") == nil
        if backfill { lock.lock(); _progress = 0; lock.unlock() }
        if all || what.contains(.metrics) || what.contains(.samples) {
            indexMetrics(t)
        }
        if backfill { lock.lock(); _progress = 50; lock.unlock() }
        if all || what.contains(.workspace) { membershipCache = nil; indexWorkspaceLogs(t); indexRuns(t) }
        if all || what.contains(.runs) { indexRuns(t) }
        if all || what.contains(.grants) { indexGrants(t) }
        if all || what.contains(.chat) { indexChat(t) }
        if backfill, all {
            try? t.setMeta("backfilled", String(Int64(now().timeIntervalSince1970 * 1000)))
            lock.lock(); _progress = nil; lock.unlock()
        }
        let changed = t.currentRev != before
        if changed { onChange?() }
        return changed
    }

    // MARK: scopes

    func membership() -> [String: String] {
        if let c = membershipCache, Date().timeIntervalSince(c.at) < 60 { return c.map }
        let ws = WorkspaceStore(store: store)
        var map: [String: String] = [:]
        var sp: Set<String> = []
        for r in ws.records() {
            for a in r.agents { if let k = a.place.key, map[k] == nil { map[k] = r.name } }
            if SpaceRecordRef.of(r) != nil { sp.insert(r.name) }
        }
        membershipCache = (Date(), map)
        spaces = sp
        return map
    }

    /// A sandbox's scope: under its workspace when one holds it now, else straight under the host.
    func sandboxScope(_ name: String?) -> String {
        guard let name, !name.isEmpty, name != MacPlace.name else { return "" }
        let s = TimelineScope.join("", "sandbox", name)
        if let w = membership()["sandbox:" + name] { return TimelineScope.join("workspace:" + TimelineScope.escape(w), "sandbox", name) }
        return s
    }

    /// A session's scope: `name~rowid` under its sandbox (or, on this Mac, under its workspace or the host).
    func sessionScope(sandbox: String?, session: String, row: Int64) -> String {
        let seg = "\(session)~\(row)"
        if sandbox == MacPlace.name {
            if let w = membership()["mac:" + session] { return TimelineScope.join("workspace:" + TimelineScope.escape(w), "session", seg) }
            return TimelineScope.join("", "session", seg)
        }
        return TimelineScope.join(sandboxScope(sandbox), "session", seg)
    }

    static func ms(_ seconds: Double) -> Int64 { Int64((seconds * 1000).rounded()) }

    /// The events retention cut of a source (nothing older is indexed as a single event in a backfill).
    func eventsCut(_ source: String) -> Int64? {
        guard let days = TimelineRetentionSettings.effective(source).retention.events else { return nil }
        return Int64(now().timeIntervalSince1970 * 1000) - Int64(days) * 86_400_000
    }

    // MARK: metrics — actions, sessions, daemon runs, network, the daemon's events, egress, resources, keys

    func indexMetrics(_ t: TimelineStore) {
        guard let m = try? metrics() else { return }
        let runs = (try? m.rows("SELECT id, started_at, kind, app_version, build, machine, chip, macos, pid FROM runs ORDER BY id")) ?? []
        let currentRun = runs.last?[0].int ?? 0
        var runEnd: [Int64: Double] = [:]
        for (i, r) in runs.enumerated() where i + 1 < runs.count { runEnd[r[0].int ?? 0] = runs[i + 1][1].real }
        indexDaemon(t, runs)
        indexActions(t, m, currentRun: currentRun, runEnd: runEnd)
        indexSessions(t, m, currentRun: currentRun, runEnd: runEnd)
        indexNetwork(t, m)
        indexHostEvents(t, m)
        indexEgress(t, m)
        indexSamples(t, m)
        indexKeys(t, m)
    }

    func indexDaemon(_ t: TimelineStore, _ runs: [[SQLValue]]) {
        var out: [StoredEvent] = []
        let from = Int(t.cursor("metrics.runs") ?? "0") ?? 0
        // The last run indexed is read again (its span grows to the next run's start).
        for (i, r) in runs.enumerated() where (r[0].int ?? 0) >= Int64(from) {
            let id = r[0].int ?? 0, at = Self.ms(r[1].real ?? 0)
            var a = TimelineAttrs.Builder(), s = TimelineAttrs.Builder()
            a.set("run_kind", r[2].text); a.set("app_version", r[3].text); a.set("build", r[4].text); a.set("chip", r[6].text)
            a.set("macos", r[7].text); a.set("pid", r[8].int)
            s.set("machine", r[5].text)
            let next = i + 1 < runs.count ? Self.ms(runs[i + 1][1].real ?? 0) : nil
            let v = r[3].text ?? "?"
            out.append(StoredEvent(id: "daemon/\(id)", source: "daemon", t: at, dur: next.map { max(0, $0 - at) }, open: next == nil, scope: "",
                                   kind: "daemon.run", summary: "daemon (\(v))", attrs: a, sattrs: s))
            out.append(StoredEvent(id: "daemon/\(id)/start", source: "daemon", t: at, scope: "", kind: "daemon.start", summary: "daemon started (\(v))",
                                   attrs: a, sattrs: s))
        }
        try? t.upsert(out)
        if let last = runs.last?[0].int { try? t.setCursor("metrics.runs", String(last)) }
    }

    /// Rows past the cursor, and the rows indexed open (until they close), in slices.
    func rowsToRead(_ t: TimelineStore, _ m: SQLiteDB, table: String, columns: String, source: String, idPrefix: String,
                    _ each: ([[SQLValue]]) -> Void) {
        let key = "metrics." + table
        var cursor = Int64(t.cursor(key) ?? "0") ?? 0
        let reopen = t.openIDs(source).compactMap { id -> Int64? in
            guard id.hasPrefix(idPrefix) else { return nil }
            let rest = id.dropFirst(idPrefix.count)
            return rest.contains("/") ? nil : Int64(rest)
        }
        if !reopen.isEmpty {
            for chunk in stride(from: 0, to: reopen.count, by: 500) {
                let ids = reopen[chunk..<min(reopen.count, chunk + 500)].map(String.init).joined(separator: ",")
                each((try? m.rows("SELECT \(columns) FROM \(table) WHERE id IN (\(ids))")) ?? [])
            }
        }
        while true {
            let rows = (try? m.rows("SELECT \(columns) FROM \(table) WHERE id > ? ORDER BY id LIMIT ?", [.int(cursor), .int(Int64(Self.slice))])) ?? []
            guard !rows.isEmpty else { break }
            each(rows)
            cursor = rows.last?[0].int ?? cursor
            try? t.setCursor(key, String(cursor))
            if rows.count < Self.slice { break }
            usleep(20_000)
        }
    }

    func indexActions(_ t: TimelineStore, _ m: SQLiteDB, currentRun: Int64, runEnd: [Int64: Double]) {
        let cut = eventsCut("actions")
        var minutes: Set<String> = []
        rowsToRead(t, m, table: "events", columns: "id, run, parent, kind, sandbox, image, action, phase_before, phase_after, started_at, duration_ms, ok, error, bytes",
                   source: "actions", idPrefix: "actions/") { rows in
            var out: [StoredEvent] = []
            for r in rows {
                let id = r[0].int ?? 0, run = r[1].int ?? 0, at = Self.ms(r[9].real ?? 0)
                if let cut, at < cut { continue }
                let step = r[3].text == "step"
                let action = r[6].text ?? "?"
                var a = TimelineAttrs.Builder(), s = TimelineAttrs.Builder()
                a.set("action", action); a.set("phase_before", r[7].text); a.set("phase_after", r[8].text); a.set("image", r[5].text)
                a.set("bytes", r[13].int); a.set("parent", r[2].int)
                s.set("error", r[12].text)
                let dur = r[10].real.map { Int64($0.rounded()) }
                var kind: String, sev = TimelineSeverity.info, open = false, d = dur, summary: String
                let base = step ? "step" : "action"
                if let dur {
                    let ok = r[11].int != 0
                    kind = base + (ok ? ".ok" : ".error")
                    sev = ok ? (step ? .debug : .info) : .warning
                    summary = "\(action) \(ok ? "ok" : "failed") in \(MetricsMath.format(Double(dur)))"
                } else {
                    kind = base + ".open"
                    summary = "\(action) …"
                    if run == currentRun { open = true } else if let end = runEnd[run] { d = max(0, Self.ms(end) - at); summary = "\(action) (not finished)" }
                }
                let scope = (r[4].text == MacPlace.name) ? "" : sandboxScope(r[4].text)
                out.append(StoredEvent(id: "actions/\(id)", source: "actions", t: at, dur: d, open: open, scope: scope, kind: kind, severity: sev,
                                       summary: summary, attrs: a, sattrs: s))
                if !step, dur != nil { minutes.insert("\(scope)\u{0}\(at / 60_000)") }
            }
            try? t.upsert(out)
        }
        // action.duration per minute and scope: recomputed from the rows (idempotent).
        var points: [(series: String, scope: String, t: Int64, min: Double, max: Double, sum: Double, count: Int64)] = []
        for k in minutes {
            let parts = k.split(separator: "\u{0}", omittingEmptySubsequences: false)
            guard parts.count == 2, let minute = Int64(parts[1]) else { continue }
            let scope = String(parts[0])
            let rows = (try? m.rows("""
                SELECT sandbox, MIN(duration_ms), MAX(duration_ms), SUM(duration_ms), COUNT(*) FROM events
                WHERE kind = 'action' AND duration_ms IS NOT NULL AND started_at >= ? AND started_at < ? GROUP BY sandbox
                """, [.real(Double(minute) * 60), .real(Double(minute + 1) * 60)])) ?? []
            var mn = Double.infinity, mx = -Double.infinity, sum = 0.0, n: Int64 = 0
            for r in rows where ((r[0].text == MacPlace.name) ? "" : sandboxScope(r[0].text)) == scope {
                mn = min(mn, r[1].real ?? 0); mx = max(mx, r[2].real ?? 0); sum += r[3].real ?? 0; n += r[4].int ?? 0
            }
            if n > 0 { points.append(("action.duration", scope, minute * 60_000, mn, mx, sum, n)) }
        }
        try? t.putMinutes(points)
    }

    func indexSessions(_ t: TimelineStore, _ m: SQLiteDB, currentRun: Int64, runEnd: [Int64: Double]) {
        let cut = eventsCut("sessions")
        rowsToRead(t, m, table: "sessions", columns: "id, run, sandbox, image, session, command, opened_at, open_ms, first_attach_ms, first_screen_ms, ended_at, exit_code",
                   source: "sessions", idPrefix: "sessions/") { rows in
            var out: [StoredEvent] = []
            for r in rows {
                let id = r[0].int ?? 0, run = r[1].int ?? 0, at = Self.ms(r[6].real ?? 0)
                if let cut, at < cut { continue }
                let name = r[4].text ?? "?"
                let scope = sessionScope(sandbox: r[2].text, session: name, row: id)
                // The program by its basename — never the command line.
                let program = (r[5].text ?? "").split(separator: " ").first.map { (String($0) as NSString).lastPathComponent }
                var a = TimelineAttrs.Builder()
                a.set("program", program); a.set("image", r[3].text); a.set("open_ms", r[7].real.map { Int64($0.rounded()) })
                a.set("first_attach_ms", r[8].real.map { Int64($0.rounded()) }); a.set("first_screen_ms", r[9].real.map { Int64($0.rounded()) })
                let links = TimelineLinks(session: String(id))
                var dur: Int64?, open = false
                if let end = r[10].real { dur = max(0, Self.ms(end) - at) }
                else if run == currentRun { open = true }
                else if let end = runEnd[run] { dur = max(0, Self.ms(end) - at) }
                out.append(StoredEvent(id: "sessions/\(id)", source: "sessions", t: at, dur: dur, open: open, scope: scope, kind: "session",
                                       summary: "session \(name)" + (program.map { " (\($0))" } ?? ""), attrs: a, links: links))
                if let o = r[7].real {
                    out.append(StoredEvent(id: "sessions/\(id)/open", source: "sessions", t: at, dur: Int64(o.rounded()), scope: scope, kind: "session.open",
                                           severity: .debug, summary: "session \(name) opened in \(MetricsMath.format(o))", attrs: a, links: links))
                }
                if let end = r[10].real {
                    var e = TimelineAttrs.Builder()
                    e.set("program", program); e.set("exit_code", r[11].int)
                    let code = r[11].int
                    out.append(StoredEvent(id: "sessions/\(id)/end", source: "sessions", t: Self.ms(end), scope: scope, kind: "session.end",
                                           severity: (code ?? 0) != 0 ? .warning : .info,
                                           summary: "session \(name) ended" + (code.map { " (exit \($0))" } ?? ""), attrs: e, links: links))
                }
            }
            try? t.upsert(out)
        }
    }

    /// The network's minutes, summed across the daemon's runs (a minute counts once after a restart); the recent minutes
    /// are read again (a minute's counts grow as its connections close).
    func indexNetwork(_ t: TimelineStore, _ m: SQLiteDB) {
        let since = (Int64(t.cursor("metrics.network") ?? "0") ?? 0) - 180
        let rows = (try? m.rows("""
            SELECT sandbox, minute, SUM(allowed), SUM(denied), SUM(failed), SUM(bytes_up), SUM(bytes_down) FROM network
            WHERE minute >= ? GROUP BY sandbox, minute ORDER BY minute
            """, [.int(max(0, since))])) ?? []
        var points: [(series: String, scope: String, t: Int64, min: Double, max: Double, sum: Double, count: Int64)] = []
        var last: Int64 = 0
        for r in rows {
            let scope = sandboxScope(r[0].text), minute = r[1].int ?? 0
            last = max(last, minute)
            for (i, s) in ["net.allowed", "net.denied", "net.failed", "net.bytes_up", "net.bytes_down"].enumerated() {
                let v = r[2 + i].real ?? 0
                guard v != 0 else { continue }
                points.append((s, scope, minute * 60_000, v, v, v, 1))
            }
        }
        for chunk in stride(from: 0, to: points.count, by: Self.slice) { try? t.putMinutes(Array(points[chunk..<min(points.count, chunk + Self.slice)])) }
        if last > 0 { try? t.setCursor("metrics.network", String(last)) }
    }

    func indexHostEvents(_ t: TimelineStore, _ m: SQLiteDB) {
        guard (try? m.scalar("SELECT COUNT(*) FROM sqlite_master WHERE name = 'host_events'").int) == 1 else { return }
        let cut = eventsCut("daemon-events")
        rowsToRead(t, m, table: "host_events", columns: "id, t, kind, sandbox, session, summary, ms, failed", source: "daemon-events", idPrefix: "daemon-events/") { rows in
            var out: [StoredEvent] = []
            for r in rows {
                let at = Self.ms(r[1].real ?? 0)
                if let cut, at < cut { continue }
                let kind = r[2].text ?? "note"
                var a = TimelineAttrs.Builder()
                a.set("event", kind); a.set("subject", r[3].text)
                let sev: TimelineSeverity = r[7].int == 1 ? .warning : (kind == "step" || kind == "started") ? .debug : .info
                out.append(StoredEvent(id: "daemon-events/\(r[0].int ?? 0)", source: "daemon-events", t: at, scope: sandboxScope(r[3].text),
                                       kind: "daemon.event", severity: sev, summary: r[5].text ?? kind, attrs: a))
            }
            try? t.upsert(out)
        }
    }

    func indexEgress(_ t: TimelineStore, _ m: SQLiteDB) {
        guard (try? m.scalar("SELECT COUNT(*) FROM sqlite_master WHERE name = 'egress'").int) == 1 else { return }
        let cut = eventsCut("egress")
        var minutes: Set<String> = []
        rowsToRead(t, m, table: "egress", columns: "id, sandbox, t, kind, host, port, verdict, rule, bytes_up, bytes_down, duration_ms",
                   source: "egress", idPrefix: "egress/") { rows in
            var out: [StoredEvent] = []
            for r in rows {
                let at = Self.ms(r[2].real ?? 0), sandbox = r[1].text ?? "?"
                minutes.insert("\(sandbox)\u{0}\(at / 60_000)")
                if let cut, at < cut { continue }
                let verdict = r[6].text ?? "allowed"
                var a = TimelineAttrs.Builder(), s = TimelineAttrs.Builder()
                a.set("port", r[5].int); a.set("protocol", r[3].text); a.set("bytes_up", r[8].int); a.set("bytes_down", r[9].int)
                // The host and the rule that judged it are sensitive: never in the summary, the text index or a rollup.
                s.set("dest", r[4].text); s.set("rule", r[7].text)
                let port = r[5].int.map { " to port \($0)" } ?? ""
                out.append(StoredEvent(id: "egress/\(r[0].int ?? 0)", source: "egress", t: at,
                                       dur: verdict == "allowed" ? r[10].real.map { Int64($0.rounded()) } ?? 0 : nil, scope: sandboxScope(sandbox),
                                       kind: "egress." + verdict, severity: verdict == "allowed" ? .debug : .warning,
                                       summary: "a \(r[3].text ?? "") connection \(verdict)\(port)", attrs: a, sattrs: s))
            }
            try? t.upsert(out)
        }
        var points: [(series: String, scope: String, t: Int64, min: Double, max: Double, sum: Double, count: Int64)] = []
        for k in minutes {
            let p = k.split(separator: "\u{0}", omittingEmptySubsequences: false)
            guard p.count == 2, let minute = Int64(p[1]) else { continue }
            let sandbox = String(p[0])
            guard let r = (try? m.rows("""
                SELECT SUM(verdict = 'allowed'), SUM(verdict = 'denied'), SUM(bytes_up + bytes_down) FROM egress WHERE sandbox = ? AND t >= ? AND t < ?
                """, [.text(sandbox), .real(Double(minute) * 60), .real(Double(minute + 1) * 60)]))?.first else { continue }
            let scope = sandboxScope(sandbox)
            for (i, s) in ["egress.allowed", "egress.denied", "egress.bytes"].enumerated() {
                let v = r[i].real ?? 0
                if v != 0 { points.append((s, scope, minute * 60_000, v, v, v, 1)) }
            }
        }
        try? t.putMinutes(points)
    }

    func indexSamples(_ t: TimelineStore, _ m: SQLiteDB) {
        guard (try? m.scalar("SELECT COUNT(*) FROM sqlite_master WHERE name = 'samples'").int) == 1 else { return }
        var cursor = Int64(t.cursor("metrics.samples") ?? "0") ?? 0
        while true {
            let rows = (try? m.rows("SELECT rowid, sandbox, t, cpu_pct, mem_bytes, disk_bytes FROM samples WHERE rowid > ? ORDER BY rowid LIMIT ?",
                                    [.int(cursor), .int(Int64(Self.slice))])) ?? []
            guard !rows.isEmpty else { break }
            var points: [(series: String, scope: String, t: Int64, min: Double, max: Double, sum: Double, count: Int64)] = []
            for r in rows {
                let scope = sandboxScope(r[1].text), at = (r[2].int ?? 0) * 60_000
                for (i, s) in ["cpu", "memory", "disk"].enumerated() {
                    if let v = r[3 + i].real { points.append((s, scope, at, v, v, v, 1)) }
                }
            }
            try? t.putMinutes(points)
            cursor = rows.last?[0].int ?? cursor
            try? t.setCursor("metrics.samples", String(cursor))
            if rows.count < Self.slice { break }
        }
    }

    func indexKeys(_ t: TimelineStore, _ m: SQLiteDB) {
        guard (try? m.scalar("SELECT COUNT(*) FROM sqlite_master WHERE name = 'key_use'").int) == 1 else { return }
        let cut = eventsCut("keys")
        var minutes: [String: Double] = [:]
        rowsToRead(t, m, table: "key_use", columns: "id, sandbox, t, binding, via, ok", source: "keys", idPrefix: "keys/") { rows in
            var out: [StoredEvent] = []
            for r in rows {
                let at = Self.ms(r[2].real ?? 0), sandbox = r[1].text ?? "?"
                minutes["\(sandbox)\u{0}\(at / 60_000)", default: 0] += 0
                if let cut, at < cut { continue }
                let ok = r[5].int == 1, via = r[4].text ?? "?", key = r[3].text
                var a = TimelineAttrs.Builder()
                a.set("key", key); a.set("via", via); a.set("ok", ok)
                out.append(StoredEvent(id: "keys/\(r[0].int ?? 0)", source: "keys", t: at, scope: sandboxScope(sandbox), kind: "key.use",
                                       severity: ok ? .info : .warning, summary: "\(key.map { "the \($0) key" } ?? "a key") \(via)" + (ok ? "" : " (refused)"),
                                       attrs: a))
            }
            try? t.upsert(out)
        }
        var points: [(series: String, scope: String, t: Int64, min: Double, max: Double, sum: Double, count: Int64)] = []
        for k in minutes.keys {
            let p = k.split(separator: "\u{0}", omittingEmptySubsequences: false)
            guard p.count == 2, let minute = Int64(p[1]) else { continue }
            let n = (try? m.scalar("SELECT COUNT(*) FROM key_use WHERE sandbox = ? AND t >= ? AND t < ?",
                                   [.text(String(p[0])), .real(Double(minute) * 60), .real(Double(minute + 1) * 60)]))?.real ?? 0
            if n > 0 { points.append(("keys.uses", sandboxScope(String(p[0])), minute * 60_000, n, n, n, 1)) }
        }
        try? t.putMinutes(points)
    }

    // MARK: logs — the workspace logs and the grants log, read by byte offset

    /// Complete lines from `offset` (a last line with no line break is a write under way: left for the next pass), with
    /// each line's offset. Read through a descriptor opened with no link in its path; at most `limit` lines.
    static func lines(_ path: String, from offset: Int, limit: Int = slice) -> (lines: [(offset: Int, data: Data)], end: Int, inode: UInt64)? {
        guard let fd = try? MacFenceHostFS.open(path, O_RDONLY | O_NONBLOCK) else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == getuid() else { return nil }
        let size = Int(st.st_size)
        guard offset < size, limit > 0 else { return ([], offset, UInt64(st.st_ino)) }
        // The logs are bounded (16 MiB): the rest is read in one go, then split on line breaks.
        let want = min(size - offset, limit <= 1 ? 64 << 10 : 64 << 20)
        var all = [UInt8](repeating: 0, count: want)
        let got = all.withUnsafeMutableBytes { pread(fd, $0.baseAddress!, want, off_t(offset)) }
        guard got > 0 else { return ([], offset, UInt64(st.st_ino)) }
        var result: [(offset: Int, data: Data)] = []
        var lineStart = 0
        for j in 0..<got where all[j] == 0x0A {
            if result.count >= limit { break }
            if j > lineStart { result.append((offset + lineStart, Data(all[lineStart..<j]))) }
            lineStart = j + 1
        }
        return (result, offset + lineStart, UInt64(st.st_ino))
    }

    func indexWorkspaceLogs(_ t: TimelineStore) {
        let ws = WorkspaceStore(store: store)
        let cut = eventsCut("workspace")
        for rec in ws.records() {
            let name = rec.name, created = Self.ms(rec.createdAt.timeIntervalSince1970)
            let path = ws.folder(name) + "/log.jsonl"
            let key = "log.workspace:" + name
            // `createdAt:inode:offset` — a removed-and-remade workspace (or a replaced file) starts again at 0.
            let parts = (t.cursor(key) ?? "").split(separator: ":").map(String.init)
            var offset = 0
            guard let probe = Self.lines(path, from: 0, limit: 0) else { continue }
            if parts.count == 3, parts[0] == String(created), parts[1] == String(probe.inode) { offset = Int(parts[2]) ?? 0 }
            let wscope = "workspace:" + TimelineScope.escape(name)
            try? t.label(wscope, name, space: SpaceRecordRef.of(rec) != nil)
            while let got = Self.lines(path, from: offset), !got.lines.isEmpty {
                var out: [StoredEvent] = []
                for (off, d) in got.lines {
                    guard let e = try? HostWire.decoder.decode(WorkspaceLogEntry.self, from: d) else { continue }
                    let at = Self.ms(e.at.timeIntervalSince1970)
                    if e.action == "renamed", let from = e.from, let to = e.to {
                        try? t.alias("workspace:" + TimelineScope.escape(from), to: "workspace:" + TimelineScope.escape(to), at: at)
                    }
                    // Permission lines are the grants source's (they are written to both logs).
                    if GrantLogEntry.actions.contains(e.action) { continue }
                    if let cut, at < cut { continue }
                    out.append(workspaceEvent(e, workspace: name, created: created, offset: off, wscope: wscope))
                }
                try? t.upsert(out)
                offset = got.end
                try? t.setCursor(key, "\(created):\(got.inode):\(offset)")
                if got.lines.count < Self.slice { break }
            }
        }
    }

    func workspaceEvent(_ e: WorkspaceLogEntry, workspace: String, created: Int64, offset: Int, wscope: String) -> StoredEvent {
        let action = e.action.lowercased().map { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" ? $0 : "-" }
        let kind = "workspace." + (action.first.map { ("a"..."z").contains($0) } == true ? String(action) : "x" + String(action))
        var a = TimelineAttrs.Builder(), s = TimelineAttrs.Builder()
        a.set("action", e.action); a.set("by", e.by == "you" ? "you" : e.by); a.set("agent", e.agent); a.set("place", e.place)
        a.set("room", e.room); a.set("run", e.run); a.set("from", e.from); a.set("to", e.to); a.set("isolation", e.isolation)
        a.set("added", e.added); a.set("removed", e.removed); a.set("bytes", e.bytes)
        s.set("reason", e.reason)
        var scope = wscope
        if let run = e.run { scope = TimelineScope.join(wscope, "run", run) }
        else if let p = e.place, p.hasPrefix("sandbox:") { scope = TimelineScope.join(wscope, "sandbox", String(p.dropFirst(8))) }
        let sev: TimelineSeverity = e.action.hasSuffix("-failed") ? .error : (e.action == "restored" && e.reason != nil) ? .notice : .info
        let what = [e.agent, e.run, e.to].compactMap { $0 }.first
        return StoredEvent(id: "workspace/\(workspace)@\(created)/\(offset)", source: "workspace", t: Self.ms(e.at.timeIntervalSince1970), scope: scope,
                           kind: kind, severity: sev, summary: e.action.replacingOccurrences(of: "-", with: " ") + (what.map { " " + $0 } ?? ""),
                           attrs: a, sattrs: s, links: TimelineLinks(run: e.run.map { "\(workspace)/\($0)" }))
    }

    func indexGrants(_ t: TimelineStore) {
        let g = GrantStore(store: store)
        let cut = eventsCut("grants")
        guard let probe = Self.lines(g.logFile, from: 0, limit: 1) else { return }
        // The log's identity: its first line's time (and inode) — `grants/_@<first line ms>/<offset>`.
        guard let first = probe.lines.first, let e0 = try? HostWire.decoder.decode(GrantLogEntry.self, from: first.data) else { return }
        let firstMs = Self.ms(e0.at.timeIntervalSince1970)
        let parts = (t.cursor("log.grants") ?? "").split(separator: ":").map(String.init)
        var offset = 0
        if parts.count == 3, parts[0] == String(firstMs), parts[1] == String(probe.inode) { offset = Int(parts[2]) ?? 0 }
        while let got = Self.lines(g.logFile, from: offset), !got.lines.isEmpty {
            var out: [StoredEvent] = []
            for (off, d) in got.lines {
                guard let e = try? HostWire.decoder.decode(GrantLogEntry.self, from: d) else { continue }
                let at = Self.ms(e.at.timeIntervalSince1970)
                if let cut, at < cut { continue }
                out.append(grantEvent(e, id: "grants/_@\(firstMs)/\(off)"))
            }
            try? t.upsert(out)
            offset = got.end
            try? t.setCursor("log.grants", "\(firstMs):\(got.inode):\(offset)")
            if got.lines.count < Self.slice { break }
        }
    }

    func grantEvent(_ e: GrantLogEntry, id: String) -> StoredEvent {
        let kind: String, sev: TimelineSeverity
        switch e.action {
        case "permission-decided":
            let ans = ["allow", "ask", "never"].contains(e.answer ?? "") ? e.answer! : "never"
            kind = "decision." + ans; sev = ans == "never" ? .warning : ans == "ask" ? .notice : .info
        case "granted": kind = "grant.add"; sev = .notice
        case "revoked": kind = "grant.revoke"; sev = .info
        case "request-recorded": kind = "grant.request"; sev = .notice
        default: kind = "ceiling.set"; sev = .info
        }
        var a = TimelineAttrs.Builder(), s = TimelineAttrs.Builder()
        a.set("action", e.action); a.set("by", e.by); a.set("subject", e.subject); a.set("perm", e.perm); a.set("role", e.role)
        a.set("answer", e.answer); a.set("scope", e.scope); a.set("op", e.op); a.set("grant", e.id)
        if let u = e.until { a.set("until", ISO8601DateFormatter().string(from: u)) }
        s.set("reason", e.reason)
        // Where: the workspace the line is about (its subject's, or its scope's), else the host.
        var w: String?
        if let sub = e.subject, sub.hasPrefix("agent:"), let slash = sub.firstIndex(of: "/") { w = String(sub[sub.index(sub.startIndex, offsetBy: 6)..<slash]) }
        if w == nil, let sc = e.scope, sc.hasPrefix("workspace:") { w = String(sc.dropFirst(10)) }
        if w == nil, let sc = e.scope, sc.hasPrefix("room:"), let slash = sc.firstIndex(of: "/") { w = String(sc[sc.index(sc.startIndex, offsetBy: 5)..<slash]) }
        let scope = w.map { "workspace:" + TimelineScope.escape($0) } ?? ""
        let summary = [kind.replacingOccurrences(of: ".", with: " "), e.perm, e.subject].compactMap { $0 }.joined(separator: " ")
        return StoredEvent(id: id, source: "grants", t: Self.ms(e.at.timeIntervalSince1970), scope: scope, kind: kind, severity: sev, summary: summary,
                           attrs: a, sattrs: s, links: TimelineLinks(decision: id))
    }

    // MARK: runs and frames

    func indexRuns(_ t: TimelineStore) {
        let ws = WorkspaceStore(store: store)
        for rec in ws.records() where !rec.runs.isEmpty {
            let wscope = "workspace:" + TimelineScope.escape(rec.name)
            var out: [StoredEvent] = []
            for run in rec.runs {
                let scope = TimelineScope.join(wscope, "run", run.id)
                let at = Self.ms(run.startedAt.timeIntervalSince1970)
                let link = TimelineLinks(run: "\(rec.name)/\(run.id)")
                let folder = WorkspaceStore.resolved(ws.folder(rec.name)) + "/runs/\(run.id)/frames"
                let frameNames = ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).filter { $0.hasSuffix(".json") }.sorted()
                var a = TimelineAttrs.Builder()
                a.set("closed_by", run.closedBy); a.set("archived", run.archive != nil); a.set("frames", frameNames.count)
                a.set("frames_capped", run.framesCapped == true); a.set("legacy", run.legacy == true)
                let end = run.endedAt.map { Self.ms($0.timeIntervalSince1970) }
                out.append(StoredEvent(id: "runs/\(rec.name)/\(run.id)", source: "runs", t: at, dur: end.map { max(0, $0 - at) }, open: end == nil,
                                       scope: scope, kind: "run", summary: "run \(run.id)", attrs: a, links: link))
                out.append(StoredEvent(id: "runs/\(rec.name)/\(run.id)/open", source: "runs", t: at, scope: scope, kind: "run.open",
                                       summary: "run \(run.id) started", links: link))
                if let end {
                    var c = TimelineAttrs.Builder()
                    c.set("closed_by", run.closedBy); c.set("archived", run.archive != nil)
                    out.append(StoredEvent(id: "runs/\(rec.name)/\(run.id)/close", source: "runs", t: end, scope: scope, kind: "run.close",
                                           summary: "run \(run.id) \(run.closedBy == "archive" ? "archived" : "finished")", attrs: c, links: link))
                }
                // Frames: by name; `last.json` keeps one id and each rewrite replaces it.
                let key = "frames:\(rec.name)/\(run.id)"
                let seen = t.cursor(key) ?? ""
                var newest = seen
                for f in frameNames where f > seen || f == SpaceStateRecorder.lastName {
                    guard let d = try? MacFenceHostFS.readRegular(folder + "/" + f, maximum: 16 << 20),
                          let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                          let atS = o["at"] as? String, let when = ISO8601DateFormatter.frame.date(from: atS) ?? ISO8601DateFormatter().date(from: atS) else { continue }
                    var fa = TimelineAttrs.Builder()
                    fa.set("label", (o["label"] as? String).map { HostEventSummary.scrub(DisplayPath.tildeIn($0)) })
                    let n = f == SpaceStateRecorder.lastName ? "last" : String(f.dropLast(5))
                    out.append(StoredEvent(id: "runs/\(rec.name)/\(run.id)/\(n)", source: "runs", t: Self.ms(when.timeIntervalSince1970), scope: scope,
                                           kind: "run.frame", severity: .debug, summary: "a frame of run \(run.id)", attrs: fa, links: link))
                    if f != SpaceStateRecorder.lastName { newest = max(newest, f) }
                }
                if newest != seen { try? t.setCursor(key, newest) }
            }
            try? t.upsert(out)
        }
    }

    // MARK: chat — read only, never a message's words or an Ask's question

    func indexChat(_ t: TimelineStore) {
        let paths = ChatPaths(store: store)
        let roomsDir = paths.data + "/rooms"
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: roomsDir) else { return }
        let index = (try? ChatRoomIndex.load(paths)) ?? ChatRoomIndex()
        let human = (try? ChatDirectory.load(paths))?.human
        let records = WorkspaceStore(store: store).records()
        let cut = eventsCut("chat")
        for f in files.sorted() where f.hasSuffix(".db") {
            let room = String(f.dropLast(3))
            let id = index.rooms[room]?.id
            let holders = Set(records.filter { r in r.rooms.contains { $0.chatRoom == room && $0.goneAt == nil } }.map(\.name))
            let seg = id ?? room
            let scope = holders.count == 1 ? TimelineScope.join("workspace:" + TimelineScope.escape(holders.first!), "room", seg)
                                           : TimelineScope.join("", "room", seg)
            try? t.label(scope, room)
            guard let db = try? SQLiteDB(path: roomsDir + "/" + f, readOnly: true) else { continue }
            indexRoom(t, db, room: room, scope: scope, human: human, cut: cut)
        }
    }

    struct RoomCursor: Codable { var seq: Int64 = 0; var states: Double = 0; var hand: Double = 0; var edits: Double = 0; var asks: Double = 0 }

    func indexRoom(_ t: TimelineStore, _ db: SQLiteDB, room: String, scope: String, human: String?, cut: Int64?) {
        let key = "chat:" + room
        var c = t.cursor(key).flatMap { try? JSONDecoder().decode(RoomCursor.self, from: Data($0.utf8)) } ?? RoomCursor()
        func person(_ s: String?) -> String? { guard let s else { return nil }; return s == human ? "you" : s }
        func old(_ at: Double) -> Bool { cut.map { Self.ms(at) < $0 } ?? false }
        var out: [StoredEvent] = []
        let hasKind = ((try? db.rows("SELECT name FROM pragma_table_info('messages')")) ?? []).contains { $0[0].text == "kind" }
        let extra = hasKind ? "kind, private, edited_at, deleted_at" : "'', 0, 0, 0"
        // Messages: ids, times, counts — the SQL never names `content`.
        let msgs = (try? db.rows("SELECT seq, msg_id, sender, json_array_length(recipients), re_msg_id, at, \(extra) FROM messages WHERE seq > ? ORDER BY seq",
                                 [.int(c.seq)])) ?? []
        for r in msgs {
            let seq = r[0].int ?? 0, msg = r[1].text ?? "", at = r[5].real ?? 0
            c.seq = max(c.seq, seq)
            if old(at) { continue }
            var a = TimelineAttrs.Builder()
            a.set("from", person(r[2].text)); a.set("to_count", r[3].int); a.set("seq", seq)
            if let k = r[6].text, !k.isEmpty { a.set("msg_kind", k) }
            a.set("private", r[7].int == 1)
            if let re = r[4].text, !re.isEmpty { a.set("re_msg_id", re) }
            out.append(StoredEvent(id: "chat/\(msg)", source: "chat", t: Self.ms(at), scope: scope, kind: "chat.message",
                                   summary: "a message from \(person(r[2].text) ?? "someone") to \(r[3].int ?? 0)", attrs: a, links: TimelineLinks(msg: msg)))
        }
        if hasKind {
            let marks = (try? db.rows("SELECT msg_id, edited_at, deleted_at FROM messages WHERE edited_at > ? OR deleted_at > ?",
                                      [.real(c.edits), .real(c.edits)])) ?? []
            for r in marks {
                let msg = r[0].text ?? ""
                for (i, kind) in ["chat.edited", "chat.deleted"].enumerated() {
                    let at = r[1 + i].real ?? 0
                    guard at > 0 else { continue }
                    c.edits = max(c.edits, at)
                    if old(at) { continue }
                    out.append(StoredEvent(id: "chat/\(msg)/\(kind.dropFirst(5))", source: "chat", t: Self.ms(at), scope: scope, kind: kind,
                                           summary: "a message \(kind.dropFirst(5))", links: TimelineLinks(msg: msg)))
                }
            }
        }
        let states = (try? db.rows("""
            SELECT s.msg_id, s.recipient, s.state, s.at, m.at FROM states s LEFT JOIN messages m ON m.msg_id = s.msg_id WHERE s.at >= ? ORDER BY s.at
            """, [.real(c.states)])) ?? []
        for r in states {
            let msg = r[0].text ?? "", state = r[2].text ?? "", at = r[3].real ?? 0
            c.states = max(c.states, at)
            guard TimelineSources.messageStates.contains(state), !old(at) else { continue }
            var a = TimelineAttrs.Builder()
            a.set("to", person(r[1].text))
            if state == "delivered", let sent = r[4].real { a.set("ms_to_deliver", max(0, Self.ms(at) - Self.ms(sent))) }
            out.append(StoredEvent(id: "chat/\(msg)/\(r[1].text ?? "")/\(state)", source: "chat", t: Self.ms(at), scope: scope, kind: "chat." + state,
                                   severity: state == "failed" ? .warning : .debug, summary: "a message \(state) for \(person(r[1].text) ?? "someone")",
                                   attrs: a, links: TimelineLinks(msg: msg)))
        }
        let hands = (try? db.rows("SELECT msg_id, recipient, handed_at FROM handovers WHERE handed_at >= ?", [.real(c.hand)])) ?? []
        for r in hands {
            let msg = r[0].text ?? "", at = r[2].real ?? 0
            c.hand = max(c.hand, at)
            guard at > 0, !old(at) else { continue }
            var a = TimelineAttrs.Builder()
            a.set("to", person(r[1].text))
            out.append(StoredEvent(id: "chat/\(msg)/\(r[1].text ?? "")/handover", source: "chat", t: Self.ms(at), scope: scope, kind: "chat.handover",
                                   severity: .debug, summary: "a message handed to \(person(r[1].text) ?? "someone")", attrs: a, links: TimelineLinks(msg: msg)))
        }
        // Asks: the number and the outcome — never the question (`ask` is read only for its number).
        let asks = (try? db.rows("""
            SELECT a.msg_id, json_extract(a.ask, '$.number'), a.state, a.closed_at, a.declined, a.no_decider, json_extract(a.decision, '$.by'),
              json_extract(a.decision, '$.option'), m.at, m.seq FROM asks a JOIN messages m ON m.msg_id = a.msg_id
            WHERE a.state = 'open' OR a.closed_at >= ? OR m.seq > ?
            """, [.real(c.asks), .int(c.seq - Int64(msgs.count))])) ?? []
        for r in asks {
            let msg = r[0].text ?? "", state = r[2].text ?? "open", at = r[8].real ?? 0, closed = r[3].real ?? 0
            c.asks = max(c.asks, closed)
            if old(max(at, closed)) { continue }
            let number = r[1].int
            let aid = number.map { "ask/#\($0)" } ?? "ask/\(msg)"
            let links = TimelineLinks(ask: number.map { "#\($0)" }, msg: msg)
            out.append(StoredEvent(id: aid, source: "chat", t: Self.ms(at), dur: state == "open" ? nil : max(0, Self.ms(closed) - Self.ms(at)),
                                   open: state == "open", scope: scope, kind: "ask.open", severity: .notice,
                                   summary: "an Ask" + (number.map { " #\($0)" } ?? "") + (state == "open" ? " open" : ""), links: links))
            if state != "open", ["decided", "expired", "withdrawn"].contains(state) {
                var a = TimelineAttrs.Builder()
                if state == "decided" {
                    a.set("decider", person(r[6].text)); a.set("declined", r[4].int == 1)
                    if let o = r[7].int { a.set("option", o) } else { a.set("option", r[7].text) }
                }
                a.set("no_decider", r[5].int == 1)
                out.append(StoredEvent(id: aid + "/" + state, source: "chat", t: Self.ms(closed), scope: scope, kind: "ask." + state,
                                       severity: state == "decided" ? .info : .notice,
                                       summary: "an Ask" + (number.map { " #\($0)" } ?? "") + " " + state + (r[4].int == 1 ? " (declined)" : ""),
                                       attrs: a, links: links))
            }
        }
        try? t.upsert(out)
        if let d = try? JSONEncoder().encode(c) { try? t.setCursor(key, String(decoding: d, as: UTF8.self)) }
    }
}

extension ISO8601DateFormatter {
    /// A frame's `at`: with fractions.
    nonisolated(unsafe) static let frame: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()
}
