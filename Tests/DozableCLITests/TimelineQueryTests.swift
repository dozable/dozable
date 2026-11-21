import Foundation
import XCTest
@testable import DozableHost

/// The query engine over `timeline.sqlite`: on the week's recording, every search vector's SQL returns exactly the
/// events the contract's matcher (ported) picks; every document Dozable builds from a fixture store passes the schema;
/// rows fold by depth; bins add up to the single events; sensitive attrs answer only an `attr.` search; pages and the
/// live feed resume where they left off.
final class TimelineQueryTests: XCTestCase {
    static let host = "host:host-a"
    static func keptForever(_ s: String) -> (retention: TimelineRetention, setBy: String) { (TimelineRetention(events: nil, m1: nil, h1: nil, d1: nil), "default") }

    var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("doz-747-q-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    /// The recording loaded as the indexer would store it.
    func weekStore() throws -> (TimelineStore, TimelineRecording) {
        let rec = try TimelineMatchTests.recording()
        let t = try TimelineStore(url: dir.appendingPathComponent("timeline.sqlite"))
        t.host = Self.host
        try t.upsert(rec.events.compactMap { TimelineStore.stored($0, host: Self.host) })
        var points: [(series: String, scope: String, t: Int64, min: Double, max: Double, sum: Double, count: Int64)] = []
        for m in rec.metrics {
            guard case .point(let s, let sc, let tt, let v) = m, let rel = TimelineStore.relative(sc, host: Self.host) else { continue }
            points.append((s, rel, tt, v, v, v, 1))
        }
        try t.putMinutes(points)
        return (t, rec)
    }

    static func inRange(_ e: TimelineEvent, _ from: Int64, _ to: Int64, now: Int64) -> Bool {
        if e.t >= from && e.t < to { return true }
        if e.t < from, e.open != true, let d = e.dur, e.t + d > from { return true }
        if e.t < from, e.open == true, now > from { return true }
        return false
    }

    func allPages(_ engine: TimelineQueryEngine, _ q: TimelineQuery) throws -> (ids: [String], total: Int64) {
        var q = q, out: [String] = [], total: Int64 = 0
        q.limit = 10_000
        while true {
            let r = try engine.query(q)
            total = r.total
            out += (r.events ?? []).map(\.id)
            guard let n = r.next else { break }
            q.cursor = n
        }
        return (out, total)
    }

    func testEveryVectorsSQLAgreesWithTheMatcher() throws {
        let (t, rec) = try weekStore()
        let v = try TimelineMatchTests.vectors()
        let engine = TimelineQueryEngine(store: t, host: Self.host, now: v.now, retention: Self.keptForever)
        var checked = 0
        for x in v.vectors {
            let expected = rec.events.filter { Self.inRange($0, x.from, x.to, now: v.now) && TimelineMatcher.matches(x.where, $0) }
            let got = try allPages(engine, TimelineQuery(scope: Self.host, depth: 1, from: x.from, to: x.to, where: x.where))
            XCTAssertEqual(Set(got.ids), Set(expected.map(\.id)), "vector \(x.q)")
            XCTAssertEqual(got.ids.count, expected.count, "vector \(x.q): no event twice")
            XCTAssertEqual(got.total, Int64(expected.count), "vector \(x.q): total")
            checked += 1
        }
        XCTAssertEqual(checked, v.vectors.count)
    }

    func testPagesAreOrderedByTimeAndIdAndResume() throws {
        let (t, rec) = try weekStore()
        let v = try TimelineMatchTests.vectors()
        let engine = TimelineQueryEngine(store: t, host: Self.host, now: v.now, retention: Self.keptForever)
        var q = TimelineQuery(scope: Self.host, depth: 0, from: v.from, to: v.to, limit: 500)
        var seen: [TimelineEvent] = []
        while true {
            let r = try engine.query(q)
            seen += r.events ?? []
            guard let n = r.next else { break }
            q.cursor = n
        }
        XCTAssertEqual(seen.count, rec.events.filter { Self.inRange($0, v.from, v.to, now: v.now) }.count)
        XCTAssertEqual(seen.map(\.id), seen.sorted { $0.t != $1.t ? $0.t < $1.t : $0.id < $1.id }.map(\.id))
    }

    func testBinsAddUpToTheEventsAndFoldIntoRows() throws {
        let (t, _) = try weekStore()
        let v = try TimelineMatchTests.vectors()
        let engine = TimelineQueryEngine(store: t, host: Self.host, now: v.now, retention: Self.keptForever)
        let flat = try engine.query(TimelineQuery(scope: Self.host, depth: 1, from: v.from, to: v.to, limit: 1))
        for (bin, tz) in [(TimelineBin.h1, nil), (.d1, "Australia/Sydney"), (.d1, nil), (.h1, "Asia/Kolkata")] as [(TimelineBin, String?)] {
            let b = try engine.query(TimelineQuery(scope: Self.host, depth: 1, from: v.from, to: v.to, bin: bin, tz: tz))
            let binned = (b.bins ?? []).reduce(0) { $0 + $1.count }
            let startedIn = try engine.query(TimelineQuery(scope: Self.host, depth: 1, from: v.from, to: v.to, limit: 10_000))
            let inside = (startedIn.events ?? []).filter { $0.t >= v.from }.count
            XCTAssertEqual(binned, Int64(inside), "\(bin) \(tz ?? "UTC"): an event counts in the bin of its t")
            XCTAssertTrue((b.bins ?? []).allSatisfy { $0.t == TimelineTime.start($0.t, bin, TimelineTime.zone(tz).0) }, "bins start on their boundary")
            XCTAssertEqual(b.rows.map(\.scope), flat.rows.map(\.scope))
            XCTAssertFalse((b.metrics).isEmpty)
        }
        // Depth 1 under the host: its workspaces, sandboxes and rooms straight in it, and the host itself as its own row.
        XCTAssertTrue(flat.rows.contains { $0.scope == "host:host-a/workspace:example-space" && $0.space == true || $0.scope == "host:host-a/workspace:example-space" })
        XCTAssertTrue(flat.rows.contains { $0.scope == Self.host && $0.own == true })
        // A day bin in Sydney starts at Sydney's midnight.
        let syd = TimeZone(identifier: "Australia/Sydney")!
        let s = TimelineTime.start(v.now, .d1, syd)
        var cal = Calendar(identifier: .gregorian); cal.timeZone = syd
        let c = cal.dateComponents([.hour, .minute], from: Date(timeIntervalSince1970: Double(s) / 1000))
        XCTAssertEqual(c.hour, 0); XCTAssertEqual(c.minute, 0)
    }

    func testEveryDozableBuiltDocumentPassesTheSchema() throws {
        let fx = try TimelineFixture(tag: "qdoc")
        defer { fx.remove() }
        try fx.fill()
        let ix = TimelineIndexer(store: fx.store)
        ix.catchUpNow()
        let t = try TimelineStore(url: ix.url, readOnly: true)
        let host = MacDisplayName.scope(["DOZ_TEST_GUARD": "1", "DOZ_TEST_MAC_NAME": "this Mac"])
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let e = TimelineQueryEngine(store: t, host: host, now: now)
        let from = now - 7 * 86_400_000
        XCTAssertEqual(try TimelineSchemaTests.validate(encoded: try e.catalog()), [])
        let flat = try e.query(TimelineQuery(scope: host, depth: 1, from: from, to: now))
        XCTAssertGreaterThan(flat.total, 10)
        XCTAssertEqual(try TimelineSchemaTests.validate(encoded: flat), [])
        let deep = try e.query(TimelineQuery(scope: host + "/workspace:example-space", depth: 2, from: from, to: now))
        XCTAssertEqual(try TimelineSchemaTests.validate(encoded: deep), [])
        let binned = try e.query(TimelineQuery(scope: host, depth: 1, from: from, to: now, bin: .h1, tz: "Australia/Sydney"))
        XCTAssertEqual(try TimelineSchemaTests.validate(encoded: binned), [])
        let batch = try XCTUnwrap(try e.batch(TimelineQuery(scope: host, depth: 1, from: from, to: now), after: 0))
        XCTAssertFalse(batch.events.isEmpty)
        XCTAssertEqual(try TimelineSchemaTests.validate(encoded: batch), [])
        // Each source only its kinds and attrs (the schema checks it), and no forbidden key anywhere.
        let withSensitive = try e.query(TimelineQuery(scope: host, depth: 1, from: from, to: now,
                                                      where: TimelineSearchAst(all: [TimelineAstTerm(any: [.attr(key: "dest", value: TimelineFixture.host)])])))
        XCTAssertEqual(try TimelineSchemaTests.validate(encoded: withSensitive), [])
        for ev in (flat.events ?? []) + (withSensitive.events ?? []) { XCTAssertTrue(TimelineAttrs.forbidden.isDisjoint(with: ev.attrs.keys), ev.id) }
    }

    func testSensitiveAttrsAnswerOnlyAnAttrSearchAndNeverText() throws {
        let fx = try TimelineFixture(tag: "qpriv")
        defer { fx.remove() }
        try fx.fill()
        let ix = TimelineIndexer(store: fx.store)
        ix.catchUpNow()
        let host = MacDisplayName.scope()
        let now = Int64(Date().timeIntervalSince1970 * 1000), from = now - 7 * 86_400_000
        let e = TimelineQueryEngine(store: try TimelineStore(url: ix.url, readOnly: true), host: host, now: now)
        let text = try e.query(TimelineQuery(scope: host, depth: 1, from: from, to: now,
                                             where: TimelineSearchAst(all: [TimelineAstTerm(any: [.text("sentinel-host")])])))
        XCTAssertEqual(text.total, 0, "free text never matches a host")
        for s in [TimelineFixture.text, "SENTINEL QUESTION", TimelineFixture.keyValue, "secret-folder"] {
            let r = try e.query(TimelineQuery(scope: host, depth: 1, from: from, to: now, where: TimelineSearchAst(all: [TimelineAstTerm(any: [.text(s)])])))
            XCTAssertEqual(r.total, 0, s)
        }
        let all = try e.query(TimelineQuery(scope: host, depth: 1, from: from, to: now))
        let egress = try XCTUnwrap(all.events?.first { $0.source == "egress" })
        XCTAssertNil(egress.attrs["dest"], "hidden until asked")
        XCTAssertFalse(egress.summary.contains("sentinel"))
        let asked = try e.query(TimelineQuery(scope: host, depth: 1, from: from, to: now,
                                              where: TimelineSearchAst(all: [TimelineAstTerm(any: [.attr(key: "dest", value: TimelineFixture.host.uppercased())])])))
        XCTAssertEqual(asked.events?.compactMap { $0.attrs["dest"]?.stringValue }, [TimelineFixture.host, TimelineFixture.host])
        // The owner is "you" in a people attr.
        XCTAssertTrue(all.events?.contains { $0.source == "chat" && $0.attrs["from"] == .string("you") } == true)
        // Rollups: counts per sandbox, never a host.
        XCTAssertTrue(all.metrics.allSatisfy { !$0.scope.contains("sentinel") && !$0.series.contains("sentinel") })
    }

    func testTheLiveFeedResumesAndResetsPastAPrune() throws {
        let fx = try TimelineFixture(tag: "qlive")
        defer { fx.remove() }
        let m = try fx.fill()
        let ix = TimelineIndexer(store: fx.store)
        ix.catchUpNow()
        let host = MacDisplayName.scope()
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let q = TimelineQuery(scope: host, depth: 1, from: now - 7 * 86_400_000, to: now + 86_400_000)
        let ro = try TimelineStore(url: ix.url, readOnly: true)
        let first = try XCTUnwrap(try TimelineQueryEngine(store: ro, host: host, now: now).batch(q, after: 0))
        let token = try XCTUnwrap(Int64(first.resume ?? ""))
        // Nothing new: an empty batch.
        XCTAssertEqual(try TimelineQueryEngine(store: ro, host: host, now: now).batch(q, after: token)?.events.count, 0)
        // A new action and its finish arrive as one replacing event.
        let run = m.beginRun(.init(kind: "doz host", appVersion: "1", build: "1", machine: "m", chip: "c", macOS: "x"))
        let id = m.begin(run: run, action: "pause", sandbox: "build-vm", image: "pi", phaseBefore: "running")
        m.finish(id, phaseAfter: "paused", durationMs: 30, ok: true)
        ix.catchUpNow()
        let ro2 = try TimelineStore(url: ix.url, readOnly: true)
        let next = try XCTUnwrap(try TimelineQueryEngine(store: ro2, host: host, now: now + 1000).batch(q, after: token))
        XCTAssertTrue(next.events.contains { $0.id == "actions/\(id)" && $0.kind == "action.ok" })
        // A token older than a prune: reset.
        try TimelineStore(url: ix.url).db.run("INSERT OR REPLACE INTO kept (source, pruned_rev) VALUES ('actions', ?)", [.int(token + 1_000_000)])
        let ro3 = try TimelineStore(url: ix.url, readOnly: true)
        XCTAssertNil(try TimelineQueryEngine(store: ro3, host: host, now: now).batch(q, after: token))
    }

    func testARequestIsStrictAndBounded() throws {
        XCTAssertThrowsError(try TimelineRequest.decode(.object(["query": .object(["scope": .string("")]), "extra": .bool(true)])))
        XCTAssertThrowsError(try TimelineRequest.decode(.object(["query": .object(["timeline": .number(1), "type": .string("query"), "scope": .string(""),
                                                                                  "depth": .number(0), "from": .number(0), "to": .number(1), "sql": .string("x")])])))
        XCTAssertThrowsError(try TimelineRequest.decode(.object(["resume": .string(String(repeating: "x", count: 300 << 10))])))
        let ok = try TimelineRequest.decode(.object(["query": .object(["timeline": .number(1), "type": .string("query"), "scope": .string("host:a"),
                                                                       "depth": .number(1), "from": .number(0), "to": .number(1)])]))
        XCTAssertEqual(ok.query?.scope, "host:a")
        XCTAssertEqual(ActionClasses.classify(HostRequest(.timelineQuery)), .dozableOwn)
    }
}
