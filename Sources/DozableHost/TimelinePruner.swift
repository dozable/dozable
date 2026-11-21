import Darwin
import Foundation

// 747 (14.5a): retention over what the timeline added and nothing else — the DERIVED store (`timeline.sqlite`) and the
// four primary tables it added (`host_events`, `egress`, `samples`, `key_use`). No other metrics row (events, sessions,
// runs, network), no workspace or grants log line, no chat message and no frame is ever removed here: pruning those waits
// for the owner (14.5b). Per source:
//   1. counts are kept before single events go: event bins (1m, 1h, 1d) of what is about to be removed, and the hours and
//      days of a series before its minutes go — each written whole, its cut point recorded BEFORE anything is deleted,
//      so a crash between batches loses nothing and the next pass resumes where it stopped;
//   2. single events older than the cut go (never an open span — the daemon's current run is one);
//   3. the source's new primary rows older than the same cut go;
//   4. each rollup level past its own days goes;
//   5. what is kept from is recorded.
// Cuts are half-open (a row AT the cut is kept) and start at a local midnight (so every bin nests), counted back from the
// NEWEST record or now, whichever is earlier: a clock behind the records, or one that jumped ahead, removes nothing extra.
// A pass runs on the indexer's queue (never the daemon's actor), its own connection to the metrics, 5,000 rows per
// transaction; it touches only the store's own two files, refused when either is not a regular file in the store.

public struct TimelinePruneReport: Sendable, Equatable {
    /// source → kind of row → rows removed (or, a dry run, that would be).
    public var removed: [String: [String: Int]] = [:]
    public var refused: String?
    mutating func add(_ source: String, _ what: String, _ n: Int) { if n > 0 { removed[source, default: [:]][what, default: 0] += n } }
}

public final class TimelinePruner: @unchecked Sendable {
    public static let batch = 5_000
    /// The most single connections kept, whatever the days say (the oldest days go first).
    public static let rowCaps: [String: Int] = ["egress": 1_000_000]
    static let day: Int64 = 86_400_000

    let store: DozableStore
    let timeline: TimelineStore
    let retention: [String: (retention: TimelineRetention, setBy: String)]
    let now: Int64
    let zone: TimeZone
    /// The four tables 14.5a may prune, by source — nothing else of `metrics.sqlite`.
    static let primary: [String: (table: String, time: String)] = [
        "daemon-events": ("host_events", "t * 1000"), "egress": ("egress", "t * 1000"), "resources": ("samples", "t * 60000"), "keys": ("key_use", "t * 1000"),
    ]

    public init(store: DozableStore, timeline: TimelineStore, retention: [String: (retention: TimelineRetention, setBy: String)], now: Int64,
                zone: TimeZone = .current) {
        self.store = store; self.timeline = timeline; self.retention = retention; self.now = now; self.zone = zone
    }

    var db: SQLiteDB { timeline.db }

    /// Local midnight at or before t (a cut's start).
    func midnight(_ t: Int64) -> Int64 { TimelineTime.start(t, .d1, zone) }

    /// The newest record a source holds (its cuts count back from it when the clock is ahead of it, or behind).
    func newest(_ source: String, _ series: [String]) throws -> Int64? {
        var n = try db.scalar("SELECT MAX(t) FROM events WHERE source = ?", [.text(source)]).int
        if !series.isEmpty {
            let r = try db.scalar("SELECT MAX(t) FROM rollups WHERE series IN (\(series.map { _ in "?" }.joined(separator: ",")))", series.map { .text($0) }).int
            n = [n, r].compactMap { $0 }.max()
        }
        return n
    }

    func cut(_ days: Int?, base: Int64) -> Int64? { days.map { midnight(base - Int64($0) * Self.day) } }

    /// The store's own file, as a regular file (never a link) — else nothing is pruned.
    func ownFile(_ url: URL) -> Bool {
        var st = stat()
        guard lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == getuid() else { return false }
        let root = WorkspaceStore.resolved(store.root.path)
        return WorkspaceStore.resolved(url.path).hasPrefix(root + "/") && WorkspaceStore.resolved(url.deletingLastPathComponent().path) == root
    }

    /// One pass over every kept source (`dryRun`: what it would remove, and nothing removed).
    public func run(dryRun: Bool) -> TimelinePruneReport {
        var rep = TimelinePruneReport()
        guard timeline.url.path == "/dev/null" || ownFile(timeline.url) else { rep.refused = "the history file is not a regular file of the store"; return rep }
        var metrics: SQLiteDB?
        if FileManager.default.fileExists(atPath: store.metrics.path) || (try? FileManager.default.destinationOfSymbolicLink(atPath: store.metrics.path)) != nil {
            guard ownFile(store.metrics) else { rep.refused = "metrics.sqlite is not a regular file of the store"; return rep }
            metrics = try? SQLiteDB(path: store.metrics.path, readOnly: dryRun)
            try? metrics?.exec("PRAGMA foreign_keys=ON")
        }
        for s in TimelineSources.kept {
            do { try prune(s, metrics: metrics, dryRun: dryRun, into: &rep) } catch { rep.refused = (rep.refused.map { $0 + "; " } ?? "") + "\(s.name): \(error.localizedDescription)" }
        }
        return rep
    }

    func kept(_ source: String) throws -> TimelineKeptFrom {
        guard let r = try db.rows("SELECT events, m1, h1, d1 FROM kept WHERE source = ?", [.text(source)]).first else { return TimelineKeptFrom() }
        return TimelineKeptFrom(events: r[0].int, m1: r[1].int, h1: r[2].int, d1: r[3].int)
    }

    func setKept(_ source: String, _ k: TimelineKeptFrom, prunedRev: Int64?) throws {
        try db.run("""
            INSERT INTO kept (source, events, m1, h1, d1, pruned_rev) VALUES (?,?,?,?,?,?)
            ON CONFLICT(source) DO UPDATE SET events = excluded.events, m1 = excluded.m1, h1 = excluded.h1, d1 = excluded.d1,
              pruned_rev = MAX(kept.pruned_rev, excluded.pruned_rev)
            """, [.text(source), .opt(k.events), .opt(k.m1), .opt(k.h1), .opt(k.d1), .int(prunedRev ?? 0)])
    }

    /// Delete in batches of `batch` rows, each its own transaction; the number deleted.
    func deleteBatches(_ db: SQLiteDB, table: String, where w: String, _ args: [SQLValue], rowid: String = "rowid") throws -> Int {
        var total = 0
        while true {
            let n = try db.transaction { try db.run("DELETE FROM \(table) WHERE (\(rowid)) IN (SELECT \(rowid) FROM \(table) WHERE \(w) LIMIT \(Self.batch))", args) }
            total += n
            if n < Self.batch { return total }
            usleep(2_000)
        }
    }

    func prune(_ s: TimelineSourceInfo, metrics: SQLiteDB?, dryRun: Bool, into rep: inout TimelinePruneReport) throws {
        let r = retention[s.name]?.retention ?? s.defaultRetention
        let series = s.series.map(\.name)
        guard let newest = try newest(s.name, series) else { return }
        let base = min(now, newest)
        var k = try kept(s.name)
        var prunedRev: Int64 = 0
        let inSeries = series.isEmpty ? "0" : "series IN (" + series.map { _ in "?" }.joined(separator: ",") + ")"
        let seriesArgs: [SQLValue] = series.map { .text($0) }

        // Single events: their cut (the row cap may move it later, never earlier than the days').
        if var cutE = cut(r.events, base: base) {
            if let cap = Self.rowCaps[s.name] {
                let n = try db.scalar("SELECT COUNT(*) FROM events WHERE source = ?", [.text(s.name)]).int ?? 0
                if n > Int64(cap), let t = try db.scalar("SELECT t FROM events WHERE source = ? ORDER BY t DESC LIMIT 1 OFFSET ?",
                                                          [.text(s.name), .int(Int64(cap))]).int {
                    cutE = max(cutE, midnight(t) + Self.day)
                }
            }
            let gone = "source = ? AND t < ? AND open = 0"
            let gArgs: [SQLValue] = [.text(s.name), .int(cutE)]
            let n = Int(try db.scalar("SELECT COUNT(*) FROM events WHERE \(gone)", gArgs).int ?? 0)
            rep.add(s.name, "events", n)
            if !dryRun, n > 0 {
                // 1. Counts first: the event bins of exactly what goes — written whole, the cut recorded, then deleted.
                if (k.events ?? .min) < cutE {
                    try writeEventBins(s.name, from: k.events, to: cutE)
                    k.events = cutE
                    try setKept(s.name, k, prunedRev: nil)
                }
                prunedRev = max(prunedRev, try db.scalar("SELECT MAX(rev) FROM events WHERE \(gone)", gArgs).int ?? 0)
                // 2. Then the events (a crash here: the next pass deletes the rest; the bins are written already).
                _ = try deleteBatches(db, table: "events", where: gone, gArgs)
            } else if !dryRun, (k.events ?? .min) < cutE, n == 0, try db.scalar("SELECT COUNT(*) FROM events WHERE source = ?", [.text(s.name)]).int ?? 0 > 0 {
                k.events = max(k.events ?? cutE, cutE)
                try setKept(s.name, k, prunedRev: nil)
            }
            // 3. The new primary rows of this source (14.5a: only these four tables).
            if let p = Self.primary[s.name], let m = metrics {
                let w = "\(p.time) < ?"
                let n = Int(try m.scalar("SELECT COUNT(*) FROM \(p.table) WHERE \(w)", [.int(cutE)]).int ?? 0)
                rep.add(s.name, p.table + " rows", n)
                if !dryRun, n > 0 { _ = try deleteBatches(m, table: p.table, where: w, [.int(cutE)]) }
            }
        }

        // 4. Rollups: hours and days written from what is finer before the finer level goes; each level past its days.
        for (level, coarser) in [(TimelineBin.m1, TimelineBin.h1), (.h1, .d1)] {
            guard let c = cut(r.days(level), base: base), !series.isEmpty else { continue }
            let from = level == .m1 ? k.m1 : k.h1
            if !dryRun, (from ?? .min) < c {
                try writeCoarser(series: series, from: from, to: c, coarser: coarser, keptM1: k.m1)
                if level == .m1 { k.m1 = c } else { k.h1 = c }
                try setKept(s.name, k, prunedRev: nil)
            }
            let w = "bin = ? AND t < ? AND \(inSeries)"
            let args: [SQLValue] = [.text(level.rawValue), .int(c)] + seriesArgs
            let n = Int(try db.scalar("SELECT COUNT(*) FROM rollups WHERE \(w)", args).int ?? 0)
            rep.add(s.name, level.rawValue, n)
            if !dryRun, n > 0 {
                prunedRev = max(prunedRev, try db.scalar("SELECT MAX(rev) FROM rollups WHERE \(w)", args).int ?? 0)
                _ = try deleteBatches(db, table: "rollups", where: w, args, rowid: "series, scope, bin, t")
            }
        }
        if let c = cut(r.d1, base: base), !series.isEmpty {
            let w = "bin = '1d' AND t < ? AND \(inSeries)"
            let n = Int(try db.scalar("SELECT COUNT(*) FROM rollups WHERE \(w)", [.int(c)] + seriesArgs).int ?? 0)
            rep.add(s.name, "1d", n)
            if !dryRun, n > 0 { _ = try deleteBatches(db, table: "rollups", where: w, [.int(c)] + seriesArgs, rowid: "series, scope, bin, t") }
            if !dryRun, (k.d1 ?? .min) < c { k.d1 = c }
        }
        // The event bins past their own days.
        for level in TimelineBin.allCases {
            guard let c = cut(r.days(level), base: base) else { continue }
            let w = "source = ? AND bin = ? AND t < ?"
            let args: [SQLValue] = [.text(s.name), .text(level.rawValue), .int(c)]
            let n = Int(try db.scalar("SELECT COUNT(*) FROM ebins WHERE \(w)", args).int ?? 0)
            rep.add(s.name, "counts by " + level.rawValue, n)
            if !dryRun, n > 0 { _ = try deleteBatches(db, table: "ebins", where: w, args, rowid: "source, scope, bin, t") }
        }
        // 5. What is kept from.
        if !dryRun { try setKept(s.name, k, prunedRev: prunedRev) }
    }

    /// The event bins of a source's events in [from, to) that are about to go (open spans stay and are not counted).
    func writeEventBins(_ source: String, from: Int64?, to: Int64) throws {
        let rows = try db.rows("""
            SELECT scope, t / 60000, kind, sev, COUNT(*) FROM events WHERE source = ? AND t >= ? AND t < ? AND open = 0 GROUP BY scope, t / 60000, kind, sev
            """, [.text(source), .int(from ?? .min), .int(to)])
        struct Acc { var count: Int64 = 0; var sev = [Int64](repeating: 0, count: 5); var kinds: [String: Int64] = [:] }
        var acc: [String: Acc] = [:]
        for r in rows {
            guard let scope = r[0].text else { continue }
            let t0 = (r[1].int ?? 0) * 60_000
            for b in TimelineBin.allCases {
                let k = "\(b.rawValue)\u{0}\(scope)\u{0}\(TimelineTime.start(t0, b, zone))"
                var a = acc[k] ?? Acc()
                let n = r[4].int ?? 0
                a.count += n; a.sev[min(4, max(0, Int(r[3].int ?? 1)))] += n; a.kinds[r[2].text ?? "", default: 0] += n
                acc[k] = a
            }
        }
        try db.transaction {
            for (k, a) in acc {
                let p = k.split(separator: "\u{0}", omittingEmptySubsequences: false).map(String.init)
                var kinds = a.kinds, truncated = false
                if kinds.count > 20 {
                    kinds = Dictionary(uniqueKeysWithValues: kinds.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }.prefix(20).map { ($0.key, $0.value) })
                    truncated = true
                }
                let kj = (try? JSONEncoder().encode(kinds)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
                try db.run("""
                    INSERT OR REPLACE INTO ebins (source, scope, bin, t, count, sev0, sev1, sev2, sev3, sev4, kinds, kinds_truncated) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
                    """, [.text(source), .text(p[1]), .text(p[0]), .int(Int64(p[2]) ?? 0), .int(a.count), .int(a.sev[0]), .int(a.sev[1]), .int(a.sev[2]),
                          .int(a.sev[3]), .int(a.sev[4]), .text(kj), .int(truncated ? 1 : 0)])
            }
        }
    }

    /// The `coarser` rows of [from, to) made from what is finer (minutes, or where minutes already went, the stored
    /// hours) — replacing what they held, so writing them again changes nothing.
    func writeCoarser(series: [String], from: Int64?, to: Int64, coarser: TimelineBin, keptM1: Int64?) throws {
        let inSeries = "series IN (" + series.map { _ in "?" }.joined(separator: ",") + ")"
        var acc: [String: (min: Double, max: Double, sum: Double, count: Int64)] = [:]
        func fold(_ rows: [[SQLValue]]) {
            for r in rows {
                guard let s = r[0].text, let scope = r[1].text, let t = r[2].int else { continue }
                let k = "\(s)\u{0}\(scope)\u{0}\(TimelineTime.start(t, coarser, coarser == .d1 ? zone : nil))"
                var a = acc[k] ?? (Double.infinity, -Double.infinity, 0, 0)
                a.min = min(a.min, r[3].real ?? 0); a.max = max(a.max, r[4].real ?? 0); a.sum += r[5].real ?? 0; a.count += r[6].int ?? 0
                acc[k] = a
            }
        }
        let lo = from ?? .min
        fold(try db.rows("SELECT series, scope, t, min, max, sum, count FROM rollups WHERE bin = '1m' AND t >= ? AND t < ? AND \(inSeries)",
                         [.int(lo), .int(to)] + series.map { .text($0) }))
        if coarser == .d1 {
            // Days from the stored hours where the minutes have gone (each day is wholly one or the other: cuts are midnights).
            fold(try db.rows("SELECT series, scope, t, min, max, sum, count FROM rollups WHERE bin = '1h' AND t >= ? AND t < ? AND t < ? AND \(inSeries)",
                             [.int(lo), .int(to), .int(keptM1 ?? .min)] + series.map { .text($0) }))
        }
        try db.transaction {
            for (k, a) in acc {
                let p = k.split(separator: "\u{0}", omittingEmptySubsequences: false).map(String.init)
                try db.run("""
                    INSERT INTO rollups (series, scope, bin, t, min, max, sum, count, rev) VALUES (?,?,?,?,?,?,?,?,?)
                    ON CONFLICT(series, scope, bin, t) DO UPDATE SET min = excluded.min, max = excluded.max, sum = excluded.sum, count = excluded.count,
                      rev = excluded.rev
                    """, [.text(p[0]), .text(p[1]), .text(coarser.rawValue), .int(Int64(p[2]) ?? 0), .real(a.min), .real(a.max), .real(a.sum), .int(a.count),
                          .int(timeline.nextRev())])
            }
        }
    }
}
