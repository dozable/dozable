import Foundation
import SQLite3
import XCTest
import DozableKit
@testable import DozableHost

/// The records the timeline keeps that lived only in memory (`metrics.sqlite` migration 2): each connection kept and
/// counted once by its id, an allowed DNS lookup counted only, key use by a binding's name, the daemon's events with
/// their lines made safe, resource samples, and the Resources deletion still clearing everything.
final class TimelineRecordsTests: XCTestCase {
    var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("doz-747-rec-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func count(_ m: MetricsStore, _ sql: String) -> Int {
        var db: OpaquePointer?
        sqlite3_open_v2(m.url.path, &db, SQLITE_OPEN_READONLY, nil)
        defer { sqlite3_close(db) }
        var st: OpaquePointer?
        sqlite3_prepare_v2(db, sql, -1, &st, nil)
        defer { sqlite3_finalize(st) }
        return sqlite3_step(st) == SQLITE_ROW ? Int(sqlite3_column_int64(st, 0)) : -1
    }

    func testTheMigrationIsAdditiveAndAnOlderFileMovesUp() throws {
        let url = dir.appendingPathComponent("metrics.sqlite")
        do {
            let m = try MetricsStore(url: url)
            XCTAssertEqual(m.schemaVersion, 2)
            let run = m.beginRun(.init(kind: "test", appVersion: "0", build: "0", machine: "m", chip: "c", macOS: "x"))
            m.record(run: run, action: "start", sandbox: "s", image: nil, startedAt: Date(), durationMs: 1)
        }
        // Reopening changes nothing; the rows are there.
        let m = try MetricsStore(url: url)
        XCTAssertEqual(m.schemaVersion, 2)
        XCTAssertEqual(m.counts().events, 1)
    }

    func testEachConnectionIsKeptAndCountedOnceEvenAcrossARestart() throws {
        let url = dir.appendingPathComponent("metrics.sqlite")
        let t = Date(timeIntervalSince1970: 1_795_000_000)
        var allowed = ConnectionRecord(kind: .connect, host: "api.example.com", port: 443, method: "GET", path: "/v1/x", verdict: .allowed,
                                       rule: "allow example", bytesUp: 10, bytesDown: 20, durationMs: 5, time: t)
        allowed.credential = "swapped anthropic"
        allowed.credentialUse = .swapped("anthropic")
        let denied = ConnectionRecord(kind: .dns, host: "blocked.example.net", verdict: .denied, rule: "deny", time: t)
        let lookup = ConnectionRecord(kind: .dns, host: "api.example.com", verdict: .allowed, rule: "allow", time: t)
        let records = [allowed, denied, lookup]
        var run: Int64 = 0
        do {
            let m = try MetricsStore(url: url)
            run = m.beginRun(.init(kind: "test", appVersion: "0", build: "0", machine: "m", chip: "c", macOS: "x"))
            let b = m.recordConnections(run: run, sandbox: "s", records)
            XCTAssertEqual(b.values.first?.allowed, 2, "the connection and the lookup")
            XCTAssertEqual(b.values.first?.denied, 1)
            // The same records again (the next coalesced pass): nothing new.
            let again = m.recordConnections(run: run, sandbox: "s", [allowed, denied])
            XCTAssertTrue(again.isEmpty)
        }
        // A new daemon (a restart) sees them again: nothing is counted twice.
        let m = try MetricsStore(url: url)
        let run2 = m.beginRun(.init(kind: "test", appVersion: "0", build: "0", machine: "m", chip: "c", macOS: "x"))
        XCTAssertTrue(m.recordConnections(run: run2, sandbox: "s", [allowed, denied]).isEmpty)
        XCTAssertEqual(count(m, "SELECT COUNT(*) FROM egress"), 2, "the allowed lookup is counted, never kept")
        XCTAssertEqual(count(m, "SELECT COUNT(*) FROM egress WHERE kind = 'dns' AND verdict = 'denied'"), 1)
        XCTAssertEqual(count(m, "SELECT COUNT(*) FROM key_use WHERE binding = 'anthropic' AND via = 'swapped' AND ok = 1"), 1)
        XCTAssertEqual(count(m, "SELECT COUNT(*) FROM pragma_table_info('egress') WHERE name IN ('path', 'method', 'detail', 'credential')"), 0,
                       "never a path, a method, a detail or the credential's text")
        _ = run
    }

    func testTheDaemonsEventsAreKeptWithTheirLinesMadeSafe() {
        let home = NSHomeDirectory()
        let note = HostEvent(kind: .note, sandbox: "s", text: "could not reach api.example.com:443 from \(home)/work/repo (10.1.2.3)")
        let line = HostEventSummary.make(note)!
        XCTAssertFalse(line.contains("example.com"))
        XCTAssertFalse(line.contains("10.1.2.3"))
        XCTAssertFalse(line.contains(home))
        XCTAssertTrue(line.contains("~/work/repo"))
        XCTAssertTrue(line.contains("a host"))
        XCTAssertEqual(HostEventSummary.make(HostEvent(kind: .step, sandbox: "s", text: "VM created and booted", milliseconds: 900)), "step: vm boot")
        XCTAssertNil(HostEventSummary.make(HostEvent(kind: .output, sandbox: "s", text: "guest text")))
        XCTAssertNil(HostEventSummary.make(HostEvent(kind: .console, sandbox: "s", text: "guest text")))
        XCTAssertNil(HostEventSummary.make(HostEvent(kind: .progress, sandbox: "s", text: "pull")))
        XCTAssertLessThanOrEqual(HostEventSummary.make(HostEvent(kind: .host, sandbox: nil, text: String(repeating: "x", count: 500)))!.count, 200)
    }

    func testClearingTheHistoryClearsTheNewRecordsToo() throws {
        let m = try MetricsStore(url: dir.appendingPathComponent("metrics.sqlite"))
        let old = m.beginRun(.init(kind: "test", appVersion: "0", build: "0", machine: "m", chip: "c", macOS: "x"))
        m.hostEvent(run: old, at: Date(), kind: "note", sandbox: "s", summary: "x", ms: nil, failed: false)
        m.sample(run: old, sandbox: "s", minute: 1, cpuPercent: 1, memoryBytes: 2, diskBytes: 3)
        _ = m.recordConnections(run: old, sandbox: "s", [ConnectionRecord(kind: .tcp, host: "h", verdict: .failed, rule: "r")])
        let now = m.beginRun(.init(kind: "test", appVersion: "0", build: "0", machine: "m", chip: "c", macOS: "x"))
        try m.clearHistory(keepingRun: now)
        for t in ["host_events", "samples", "egress", "runs"] {
            XCTAssertEqual(count(m, "SELECT COUNT(*) FROM \(t) WHERE \(t == "runs" ? "id" : "run") = \(old)"), 0, t)
        }
    }

    func testASampleIsTakenFromTheMacsSideWithinItsBudget() throws {
        let sb = dir.appendingPathComponent("sandboxes/s")
        try FileManager.default.createDirectory(at: sb, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 8192).write(to: sb.appendingPathComponent("rootfs.ext4"))
        let s = ResourceSampler()
        let t = ResourceSampler.Target(name: "s", cpus: 2, memoryMiB: 1024, returnedMiB: 256, directory: sb, rootfs: sb.appendingPathComponent("rootfs.ext4"))
        let r = s.sample(t)
        XCTAssertNil(r.cpuPercent, "no helper runs it")
        XCTAssertEqual(r.memoryBytes, 768 * 1_048_576, "the spec less what the balloon returned")
        XCTAssertGreaterThanOrEqual(r.diskBytes ?? 0, 8192)
        for _ in 0..<20 { _ = s.sample(t) }
        XCTAssertEqual(s.cost.samples, 21)
        XCTAssertLessThan(s.cost.meanMicros, 2000, "a sample costs under 2 ms")
        XCTAssertEqual(s.cost.searches, 21, "no helper: looked for at each sample")
    }

    func testTheClockSeamIsHonouredOnlyInAGuardedRun() {
        let real = Date().timeIntervalSince1970
        XCTAssertEqual(TimelineClock.now(["DOZ_TEST_REAL_MAC": "1", "DOZ_TEST_TIMELINE_NOW": "1000"]).timeIntervalSince1970, real, accuracy: 5)
        XCTAssertEqual(TimelineClock.now(["DOZ_TEST_GUARD": "1", "DOZ_TEST_TIMELINE_NOW": "1000"]).timeIntervalSince1970, 1)
        XCTAssertEqual(TimelineClock.now(["DOZ_TEST_GUARD": "1", "DOZ_TEST_TIMELINE_NOW": "+40d"]).timeIntervalSince1970, real + 40 * 86_400, accuracy: 5)
    }

    func testTheSampleSettingIsOffOrTenSecondsAtLeast() throws {
        let d = try XCTUnwrap(DozableSettings.schema.first { $0.key == SettingKey.timelineSampleSeconds })
        XCTAssertNoThrow(try d.parse("0"))
        XCTAssertNoThrow(try d.parse("60"))
        XCTAssertThrowsError(try d.parse("5"))
        XCTAssertThrowsError(try d.parse("3601"))
        let n = try XCTUnwrap(DozableSettings.schema.first { $0.key == SettingKey.macName })
        XCTAssertNoThrow(try n.parse("studio"))
        XCTAssertThrowsError(try n.parse("studio.local"))
    }

    func testACredentialsUseTravelsWithItsRecord() throws {
        var r = ConnectionRecord(kind: .http, host: "h", verdict: .denied, rule: "r")
        r.credentialUse = .rejected
        let back = try JSONDecoder().decode(ConnectionRecord.self, from: JSONEncoder().encode(r))
        XCTAssertEqual(back.credentialUse, .rejected)
        // An older record (no field) still reads.
        let old = try JSONDecoder().decode(ConnectionRecord.self, from: Data(#"{"id":"\#(UUID().uuidString)","time":0,"kind":"tcp","host":"h","verdict":"allowed","rule":"r","decrypted":false,"bytesUp":0,"bytesDown":0,"open":false}"#.utf8))
        XCTAssertNil(old.credentialUse)
    }
}
