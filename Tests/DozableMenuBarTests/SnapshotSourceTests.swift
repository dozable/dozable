import XCTest
@testable import DozableMenuBarCore

/// Gathering a snapshot with a FAKE runner: what runs at each refresh, the version cache, and the actions' failures.
final class SnapshotSourceTests: XCTestCase {
    var dir: URL!
    var doz: String!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("snapsrc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        doz = dir.appendingPathComponent("doz").path
        try "#!/bin/sh\n".write(toFile: doz, atomically: true, encoding: .utf8)
        chmod(doz, 0o755)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func source(_ r: FakeRunner) -> SnapshotSource {
        SnapshotSource(locator: DozLocator(candidates: [doz]), runner: r, appVersion: "0.50.7")
    }

    func testNoDozRunsNothing() {
        let r = FakeRunner()
        let s = SnapshotSource(locator: DozLocator(candidates: []), runner: r, appVersion: "0.50.7").snapshot()
        XCTAssertEqual(s.doz, .missing)
        XCTAssertTrue(r.labels.isEmpty)
    }

    func testOneStatusPerRefreshTheVersionOnlyWhenDozChanged() throws {
        let r = FakeRunner()
        r.answer(.version, "0.50.7\n")
        r.answer(.appStatus, #"{"bundled":{"version":"0.50.7"}}"#)
        r.answer(.status, Fixture.noDaemon)
        let src = source(r)
        var s = src.snapshot()
        XCTAssertEqual(s.doz, .found(path: doz, version: "0.50.7"))
        XCTAssertEqual(s.bundledAppVersion, "0.50.7")
        XCTAssertEqual(s.status?.isRunning, false)
        XCTAssertEqual(r.labels, ["--version", "app status", "daemon status"])
        s = src.snapshot()
        XCTAssertEqual(r.labels.suffix(1), ["daemon status"], "the steady state is one process per refresh")
        XCTAssertEqual(r.labels.count, 4)
        // doz replaced by rename (an upgrade): asked again.
        let new = dir.appendingPathComponent(".doz.new").path
        try "#!/bin/sh\n# new\n".write(toFile: new, atomically: true, encoding: .utf8)
        chmod(new, 0o755)
        XCTAssertEqual(rename(new, doz), 0)
        r.answer(.version, "0.51.0\n")
        s = src.snapshot()
        XCTAssertEqual(s.dozVersion, "0.51.0")
        XCTAssertEqual(r.labels.suffix(3), ["--version", "app status", "daemon status"])
    }

    func testAnOlderDozWithoutAppStatus() {
        let r = FakeRunner()
        r.answer(.version, "0.50.3")
        r.answer(.status, Fixture.oldNoDaemon)
        r.answer(.appStatus, "", exit: 64)
        let s = source(r).snapshot()
        XCTAssertEqual(s.dozVersion, "0.50.3")
        XCTAssertNil(s.bundledAppVersion)
        XCTAssertEqual(s.status?.isRunning, false)
        XCTAssertNil(s.statusProblem)
    }

    func testStatusProblems() {
        let r = FakeRunner()
        r.answer(.version, "0.50.7")
        r.answers[DozCommand.status.label] = CommandResult(exit: 15, timedOut: true)
        XCTAssertEqual(source(r).snapshot().statusProblem, "doz did not answer within 10 seconds")
        r.answer(.status, "", exit: 6)
        XCTAssertEqual(source(r).snapshot().statusProblem, "doz daemon status failed (exit 6)")
        r.answer(.status, "garbage")
        XCTAssertEqual(source(r).snapshot().statusProblem, "doz's answer could not be read")
    }

    func testActionsAndTheirFailures() {
        let r = FakeRunner()
        r.answer(.start, Fixture.running)
        XCTAssertNil(source(r).perform(.start))
        r.answer(.start, #"{"error":{"code":"unavailable","message":"the daemon did not start — see /x/daemon.log\nmore"}}"#, exit: 6)
        XCTAssertEqual(source(r).perform(.start), "Start failed: the daemon did not start — see /x/daemon.log")
        r.answers[DozCommand.restart.label] = CommandResult(exit: 15, timedOut: true)
        XCTAssertEqual(source(r).perform(.restart), "Restart failed: doz did not finish within 300 seconds")
        // The dashboard's output is never read, even when it fails.
        r.answers[DozCommand.dashboard.label] = CommandResult(exit: 1, stdout: Data(#"{"error":{"message":"SECRET"}}"#.utf8))
        XCTAssertEqual(source(r).perform(.dashboard), "Could not open the dashboard (exit 1)")
        XCTAssertNil(source(r).perform(.quit))
        XCTAssertFalse(r.labels.contains("quit"))
    }
}
