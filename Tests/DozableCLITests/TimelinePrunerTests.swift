import CryptoKit
import Foundation
import SQLite3
import XCTest
import DozableKit
@testable import DozableHost

/// Deletion safety (14.5a): retention removes only what the timeline added — the history file's rows past their days,
/// and the four new primary tables' rows past the same days — and never: a row at or after its cut, an open span, the
/// daemon's current run, anything when the clock is behind or ahead of the records, anything with `kept`, anything
/// through a link or outside the store, and NO existing record: a `metrics.sqlite` events / sessions / runs / network row
/// and a workspace or grants log line older than every cut all survive, byte for byte.
final class TimelinePrunerTests: XCTestCase {
    static let day: Int64 = 86_400_000
    let utc = TimeZone(identifier: "UTC")!
    var dir: URL!
    var store: DozableStore!
    /// A fixed now: 2026-11-20T12:00Z.
    let now: Int64 = 1_795_262_400_000 - 12 * 3_600_000

    override func setUpWithError() throws {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("doz-747-prune-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        dir = URL(fileURLWithPath: HostCore.resolvedRoot(u.path))
        store = DozableStore(root: dir)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func timeline() throws -> TimelineStore { try TimelineStore(url: TimelineStore.url(store)) }
    func ev(_ id: String, _ source: String, _ t: Int64, dur: Int64? = nil, open: Bool = false, kind: String? = nil) -> StoredEvent {
        StoredEvent(id: id, source: source, t: t, dur: dur, open: open, scope: "sandbox:build-vm", kind: kind ?? (source == "actions" ? "action.ok" : "daemon.event"),
                    summary: id)
    }
    func retention(_ r: TimelineRetention, for sources: [String]) -> [String: (retention: TimelineRetention, setBy: String)] {
        var out = TimelineRetentionSettings.all()
        for s in sources { out[s] = (r, "user") }
        return out
    }
    func pruner(_ t: TimelineStore, _ r: [String: (retention: TimelineRetention, setBy: String)], now: Int64? = nil) -> TimelinePruner {
        TimelinePruner(store: store, timeline: t, retention: r, now: now ?? self.now, zone: utc)
    }
    func ids(_ t: TimelineStore) throws -> Set<String> { Set(try t.db.rows("SELECT id FROM events").compactMap { $0[0].text }) }
    func midnight(_ t: Int64) -> Int64 { t / Self.day * Self.day }

    // MARK: the cut

    func testTheCutIsHalfOpenAtALocalMidnight() throws {
        let t = try timeline()
        let cut = midnight(now - 30 * Self.day)
        try t.upsert([ev("actions/1", "actions", cut - 1), ev("actions/2", "actions", cut), ev("actions/3", "actions", now)])
        let rep = pruner(t, retention(TimelineRetention(events: 30, m1: 30, h1: 365, d1: nil), for: ["actions"])).run(dryRun: false)
        XCTAssertNil(rep.refused)
        XCTAssertEqual(rep.removed["actions"]?["events"], 1)
        XCTAssertEqual(try ids(t), ["actions/2", "actions/3"], "the row AT the cut is kept")
        XCTAssertEqual(try t.db.scalar("SELECT events FROM kept WHERE source = 'actions'").int, cut)
        // Its count is kept, in the bin of its t: by hour and day (its minute's count is past the minutes' own 30 days).
        XCTAssertEqual(try t.db.scalar("SELECT SUM(count) FROM ebins WHERE source = 'actions' AND bin = '1d'").int, 1)
        XCTAssertEqual(try t.db.scalar("SELECT t FROM ebins WHERE source = 'actions' AND bin = '1h'").int, (cut - 1) / 3_600_000 * 3_600_000)
        XCTAssertEqual(try t.db.scalar("SELECT COUNT(*) FROM ebins WHERE source = 'actions' AND bin = '1m'").int, 0)
    }

    func testOpenSpansAndTheCurrentRunAreKept() throws {
        let t = try timeline()
        let old = now - 100 * Self.day
        try t.upsert([ev("actions/1", "actions", old, open: true, kind: "action.open"),
                      StoredEvent(id: "daemon/1", source: "daemon", t: old, open: true, scope: "", kind: "daemon.run", summary: "daemon"),
                      StoredEvent(id: "daemon/0", source: "daemon", t: old - 5 * Self.day, dur: Self.day, scope: "", kind: "daemon.run", summary: "daemon"),
                      ev("actions/9", "actions", now)])
        let rep = pruner(t, retention(TimelineRetention(events: 1, m1: 1, h1: 1, d1: 1), for: ["actions", "daemon"])).run(dryRun: false)
        XCTAssertNil(rep.refused)
        XCTAssertEqual(try ids(t), ["actions/1", "actions/9", "daemon/1"], "an open span and the current daemon run stay; a closed old run goes")
        XCTAssertEqual(try t.db.scalar("SELECT COUNT(*) FROM ebins WHERE source = 'actions'").int, 0, "an open span is not counted as gone")
    }

    func testKeptNeverDeletesAndADryRunRemovesNothing() throws {
        let t = try timeline()
        try t.upsert([ev("actions/1", "actions", now - 3000 * Self.day), ev("actions/2", "actions", now)])
        try t.putMinutes([("net.allowed", "sandbox:build-vm", now - 3000 * Self.day, 1, 1, 1, 1), ("net.allowed", "sandbox:build-vm", now, 1, 1, 1, 1)])
        let kept = TimelineRetention(events: nil, m1: nil, h1: nil, d1: nil)
        var rep = pruner(t, retention(kept, for: ["actions", "network"])).run(dryRun: false)
        XCTAssertTrue(rep.removed["actions"] == nil && rep.removed["network"] == nil)
        XCTAssertEqual(try ids(t), ["actions/1", "actions/2"])
        XCTAssertEqual(try t.db.scalar("SELECT COUNT(*) FROM rollups").int, 2)
        let keptBefore = try t.db.rows("SELECT * FROM kept ORDER BY source")
        rep = pruner(t, retention(TimelineRetention(events: 1, m1: 1, h1: 1, d1: 1), for: ["actions", "network"])).run(dryRun: true)
        XCTAssertEqual(rep.removed["actions"]?["events"], 1, "the dry run says what would go")
        XCTAssertEqual(try ids(t), ["actions/1", "actions/2"], "…and removes nothing")
        XCTAssertEqual(try t.db.scalar("SELECT COUNT(*) FROM rollups").int, 2)
        XCTAssertEqual(try t.db.rows("SELECT * FROM kept ORDER BY source"), keptBefore, "…and records nothing")
    }

    func testZeroDaysIsRefusedAndAMissingSettingGivesTheDefaults() throws {
        XCTAssertNotNil(TimelineRetentionSettings.problem("0/30/365/kept"))
        XCTAssertNotNil(TimelineRetentionSettings.problem("30/30/365"))
        XCTAssertNotNil(TimelineRetentionSettings.problem("30/x/365/kept"))
        XCTAssertNil(TimelineRetentionSettings.problem("7/7/90/365"))
        let d = try XCTUnwrap(DozableSettings.schema.first { $0.key == "timeline.egress" })
        XCTAssertThrowsError(try d.parse("0/7/90/365"))
        XCTAssertEqual(try d.parse("kept/kept/kept/kept"), .string("kept/kept/kept/kept"))
        let xdg = dir.appendingPathComponent("xdg")
        let settings = DozableSettings.load(environment: ["XDG_CONFIG_HOME": xdg.path, "DOZ_TEST_GUARD": "1"])
        for s in TimelineSources.kept {
            let e = TimelineRetentionSettings.effective(s.name, settings: settings)
            XCTAssertEqual(e.retention, s.defaultRetention, s.name)
            XCTAssertEqual(e.setBy, "default")
        }
        XCTAssertEqual(TimelineRetentionSettings.effective("egress", settings: settings).retention, TimelineRetention(events: 7, m1: 7, h1: 90, d1: 365))
        XCTAssertEqual(TimelineRetentionSettings.effective("grants", settings: settings).retention, TimelineRetention(events: 365, m1: 365, h1: 365, d1: nil))
        XCTAssertEqual(TimelineRetentionSettings.effective("workspace", settings: settings).retention, TimelineRetention(events: 90, m1: 90, h1: 365, d1: nil))
        let set = DozableSettings.load(environment: ["XDG_CONFIG_HOME": xdg.path, "DOZ_TEST_GUARD": "1", "DOZ_TIMELINE_EGRESS": "3/3/30/kept"])
        _ = set
    }

    func testAClockBehindOrJumpedAheadDeletesNothingExtra() throws {
        let t = try timeline()
        let newest = now
        try t.upsert([ev("actions/1", "actions", newest - 10 * Self.day), ev("actions/2", "actions", newest)])
        let r = retention(TimelineRetention(events: 30, m1: 30, h1: 365, d1: nil), for: ["actions"])
        // The clock 40 days ahead of every record: the cut counts back from the newest record, so nothing goes.
        var rep = pruner(t, r, now: now + 40 * Self.day).run(dryRun: false)
        XCTAssertNil(rep.removed["actions"])
        // The clock a year behind the records: nothing goes either.
        rep = pruner(t, r, now: now - 365 * Self.day).run(dryRun: false)
        XCTAssertNil(rep.removed["actions"])
        XCTAssertEqual(try ids(t), ["actions/1", "actions/2"])
    }

    // MARK: counts before rows

    func testRollupsEqualTheSumOfTheirMinutesBeforeTheMinutesGo() throws {
        let t = try timeline()
        // 3 days of minutes, 40 days ago (past 1m's 30 days, inside 1h's 365).
        let start = midnight(now - 40 * Self.day)
        var points: [(series: String, scope: String, t: Int64, min: Double, max: Double, sum: Double, count: Int64)] = []
        var total = 0.0, maxSeen = 0.0
        for m in stride(from: Int64(0), to: 3 * 1440, by: 7) {
            let v = Double((m * 13) % 97)
            total += v; maxSeen = max(maxSeen, v)
            points.append(("net.bytes_up", "sandbox:build-vm", start + m * 60_000, v, v, v, 1))
        }
        try t.putMinutes(points)
        try t.upsert([ev("daemon-events/9", "daemon-events", now)])           // the newest record: today
        try t.putMinutes([("net.bytes_up", "sandbox:build-vm", now, 1, 1, 1, 1)])
        let rep = pruner(t, retention(TimelineRetention(events: 30, m1: 30, h1: 365, d1: nil), for: ["network"])).run(dryRun: false)
        XCTAssertNil(rep.refused)
        XCTAssertEqual(rep.removed["network"]?["1m"], points.count)
        XCTAssertEqual(try t.db.scalar("SELECT SUM(sum) FROM rollups WHERE bin = '1h'").real, total, "the hours hold exactly the minutes")
        XCTAssertEqual(try t.db.scalar("SELECT SUM(count) FROM rollups WHERE bin = '1h'").int, Int64(points.count))
        XCTAssertEqual(try t.db.scalar("SELECT MAX(max) FROM rollups WHERE bin = '1h'").real, maxSeen)
        XCTAssertEqual(try t.db.scalar("SELECT COUNT(*) FROM rollups WHERE bin = '1m' AND t < ?", [.int(now - 30 * Self.day)]).int, 0)
        // And a query over the time still answers by hour, the same total.
        let e = TimelineQueryEngine(store: t, host: "host:this%20Mac", now: now, retention: { s in
            s == "network" ? (TimelineRetention(events: 30, m1: 30, h1: 365, d1: nil), "user") : TimelineRetentionSettings.effective(s) })
        let res = try e.query(TimelineQuery(scope: "host:this%20Mac", depth: 1, from: start, to: start + 3 * Self.day, bin: .h1, series: ["net.bytes_up"]))
        let sum = res.metrics.reduce(0.0) { if case .rollup(_, _, _, _, _, _, let s, _) = $1 { return $0 + s }; return $0 }
        XCTAssertEqual(sum, total)
        // A second pass changes nothing (idempotent).
        let again = pruner(t, retention(TimelineRetention(events: 30, m1: 30, h1: 365, d1: nil), for: ["network"])).run(dryRun: false)
        XCTAssertNil(again.removed["network"])
        XCTAssertEqual(try t.db.scalar("SELECT SUM(sum) FROM rollups WHERE bin = '1h'").real, total)
    }

    func testACrashBetweenBatchesLosesNothingNewerAndTheNextPassResumes() throws {
        let t = try timeline()
        let cut = midnight(now - 30 * Self.day)
        var evs: [StoredEvent] = []
        for i in 0..<(TimelinePruner.batch * 2 + 17) { evs.append(ev("actions/\(i)", "actions", cut - Int64(i + 1) * 1000)) }
        for i in 0..<50 { evs.append(ev("actions/new\(i)", "actions", cut + Int64(i) * 1000)) }
        evs.append(ev("actions/now", "actions", now))
        try t.upsert(evs)
        let old = TimelinePruner.batch * 2 + 17
        let r = retention(TimelineRetention(events: 30, m1: 30, h1: 365, d1: nil), for: ["actions"])
        // The first pass dies after the counts and ONE batch.
        let p = pruner(t, r)
        try p.writeEventBins("actions", from: nil, to: cut)
        try p.setKept("actions", TimelineKeptFrom(events: cut), prunedRev: nil)
        try t.db.run("DELETE FROM events WHERE rowid IN (SELECT rowid FROM events WHERE source = 'actions' AND t < ? LIMIT ?)",
                     [.int(cut), .int(Int64(TimelinePruner.batch))])
        // The next pass resumes: the rest goes, the counts are not written again.
        let rep = pruner(t, r).run(dryRun: false)
        XCTAssertEqual(rep.removed["actions"]?["events"], old - TimelinePruner.batch)
        XCTAssertEqual(try t.db.scalar("SELECT COUNT(*) FROM events WHERE t < ?", [.int(cut)]).int, 0)
        XCTAssertEqual(try t.db.scalar("SELECT COUNT(*) FROM events WHERE t >= ?", [.int(cut)]).int, 51, "nothing newer lost")
        XCTAssertEqual(try t.db.scalar("SELECT SUM(count) FROM ebins WHERE source = 'actions' AND bin = '1d'").int, Int64(old), "every gone event counted once")
    }

    // MARK: only what 14.5a may touch

    /// The rule of this step: no `metrics.sqlite` events / sessions / runs / network row and no workspace or grants log
    /// byte is removed, however old, however short the retention.
    func testNoExistingRecordIsEverRemoved() throws {
        let fx = try TimelineFixture(tag: "sentinel", t0: Date(timeIntervalSince1970: Double(now) / 1000 - 3 * 365 * 86_400))
        defer { fx.remove() }
        let m = try fx.fill()
        // Newer records too, so every source's newest is now.
        let run = m.beginRun(.init(kind: "doz host", appVersion: "1", build: "1", machine: "m", chip: "c", macOS: "x"), at: Date(timeIntervalSince1970: Double(now) / 1000))
        m.hostEvent(run: run, at: Date(timeIntervalSince1970: Double(now) / 1000), kind: "note", sandbox: "build-vm", summary: "now", ms: nil, failed: false)
        m.sample(run: run, sandbox: "build-vm", minute: now / 60_000, cpuPercent: 1, memoryBytes: 1, diskBytes: 1)
        var c = ConnectionRecord(kind: .tcp, host: "h", port: 1, verdict: .failed, rule: "r", time: Date(timeIntervalSince1970: Double(now) / 1000))
        c.credentialUse = .rejected
        _ = m.recordConnections(run: run, sandbox: "build-vm", [c])
        let ws = WorkspaceStore(store: fx.store), g = GrantStore(store: fx.store)
        let logPath = ws.folder("example-space") + "/log.jsonl"
        func sha(_ p: String) throws -> String { SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: p))).map { String(format: "%02x", $0) }.joined() }
        let logSHA = try sha(logPath), grantsSHA = try sha(g.logFile)
        func counts() -> [String: Int64] {
            var db: OpaquePointer?
            sqlite3_open_v2(fx.store.metrics.path, &db, SQLITE_OPEN_READONLY, nil)
            defer { sqlite3_close(db) }
            var out: [String: Int64] = [:]
            for t in ["events", "sessions", "runs", "network", "host_events", "egress", "samples", "key_use"] {
                var st: OpaquePointer?
                sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM \(t)", -1, &st, nil)
                if sqlite3_step(st) == SQLITE_ROW { out[t] = sqlite3_column_int64(st, 0) }
                sqlite3_finalize(st)
            }
            return out
        }
        let before = counts()
        XCTAssertGreaterThan(before["events"] ?? 0, 0)
        let ix = TimelineIndexer(store: fx.store)
        ix.now = { Date(timeIntervalSince1970: Double(self.now) / 1000) }
        ix.catchUpNow()
        // The shortest retention there is, for every source.
        let rep = ix.prune(dryRun: false, retention: retention(TimelineRetention(events: 1, m1: 1, h1: 1, d1: 1), for: TimelineSources.kept.map(\.name)))
        XCTAssertNil(rep.refused)
        let after = counts()
        for t in ["events", "sessions", "runs", "network"] { XCTAssertEqual(after[t], before[t], "metrics \(t): nothing existing removed") }
        XCTAssertEqual(try sha(logPath), logSHA, "the workspace log: not a byte")
        XCTAssertEqual(try sha(g.logFile), grantsSHA, "the grants log: not a byte")
        // The four new tables lost their old rows (and kept today's).
        for t in ["host_events", "egress", "samples"] {
            XCTAssertLessThan(after[t] ?? 0, before[t] ?? 0, t)
            XCTAssertGreaterThan(after[t] ?? 0, 0, "\(t): today's row stays")
        }
        XCTAssertEqual(after["key_use"], 1, "the old key use goes, today's stays")
        // Foreign keys hold.
        var db: OpaquePointer?
        sqlite3_open_v2(fx.store.metrics.path, &db, SQLITE_OPEN_READONLY, nil)
        var st: OpaquePointer?
        sqlite3_prepare_v2(db, "PRAGMA foreign_key_check", -1, &st, nil)
        XCTAssertEqual(sqlite3_step(st), SQLITE_DONE, "no row points at a run that is gone")
        sqlite3_finalize(st); sqlite3_close(db)
        // The derived store holds no closed single event older than two days of a source whose newest record is today (a
        // source whose newest record is old keeps it: its cut counts back from that record).
        let t = try TimelineStore(url: ix.url, readOnly: true)
        XCTAssertEqual(try t.db.scalar("""
            SELECT COUNT(*) FROM events e WHERE t < ? AND open = 0 AND (SELECT MAX(t) FROM events f WHERE f.source = e.source) > ?
            """, [.int(now - 2 * Self.day), .int(now - Self.day)]).int, 0)
    }

    func testOnlyTheStoresOwnFilesAndNoLinkIsFollowed() throws {
        // metrics.sqlite is a link to a database outside the store: nothing at all is pruned.
        let outside = dir.deletingLastPathComponent().appendingPathComponent("doz-747-outside-\(UUID().uuidString.prefix(8)).sqlite")
        defer { try? FileManager.default.removeItem(at: outside) }
        let m = try MetricsStore(url: outside)
        let run = m.beginRun(.init(kind: "x", appVersion: "1", build: "1", machine: "m", chip: "c", macOS: "x"), at: Date(timeIntervalSince1970: 1))
        m.hostEvent(run: run, at: Date(timeIntervalSince1970: 1), kind: "note", sandbox: nil, summary: "old", ms: nil, failed: false)
        try FileManager.default.createSymbolicLink(at: store.metrics, withDestinationURL: outside)
        let t = try timeline()
        try t.upsert([ev("daemon-events/1", "daemon-events", 1000), ev("daemon-events/2", "daemon-events", now)])
        let rep = pruner(t, retention(TimelineRetention(events: 1, m1: 1, h1: 1, d1: 1), for: ["daemon-events"])).run(dryRun: false)
        XCTAssertNotNil(rep.refused)
        XCTAssertTrue(rep.removed.isEmpty)
        XCTAssertEqual(try ids(t), ["daemon-events/1", "daemon-events/2"])
        XCTAssertEqual(try SQLiteDB(path: outside.path, readOnly: true).scalar("SELECT COUNT(*) FROM host_events").int, 1, "the file behind the link is untouched")
        // The history file itself a link: refused when opened.
        try? FileManager.default.removeItem(at: store.metrics)
        let link = dir.appendingPathComponent("other.sqlite")
        try FileManager.default.moveItem(at: TimelineStore.url(store), to: link)
        try FileManager.default.createSymbolicLink(at: TimelineStore.url(store), withDestinationURL: link)
        XCTAssertThrowsError(try TimelineStore(url: TimelineStore.url(store)))
    }

    func testClearingTheMetricsStillWorksAndMovesKeptFrom() throws {
        let fx = try TimelineFixture(tag: "clear")
        defer { fx.remove() }
        let m = try fx.fill()
        let ix = TimelineIndexer(store: fx.store)
        ix.catchUpNow()
        let run = m.beginRun(.init(kind: "doz host", appVersion: "1", build: "1", machine: "m", chip: "c", macOS: "x"))
        try m.clearHistory(keepingRun: run)
        ix.clearMetricsDerived()
        let t = try TimelineStore(url: ix.url, readOnly: true)
        XCTAssertEqual(try t.db.scalar("SELECT COUNT(*) FROM events WHERE source IN ('actions', 'sessions', 'egress', 'keys')").int, 0)
        XCTAssertGreaterThan(try t.db.scalar("SELECT COUNT(*) FROM events WHERE source IN ('workspace', 'grants', 'chat', 'runs')").int ?? 0, 0,
                             "the logs' and chat's history stays")
        XCTAssertNotNil(try t.db.scalar("SELECT events FROM kept WHERE source = 'actions'").int)
        XCTAssertEqual(try t.db.scalar("SELECT COUNT(*) FROM events WHERE id = 'daemon/\(run)'").int, 1, "the running daemon is indexed again")
    }
}
