import XCTest
@testable import DozableMenuBarCore

/// The runner: doz by absolute path with an argv array (no shell), stdin /dev/null, a cap on what it reads, a timeout,
/// and a log line with the command words and the exit only. Real processes here are tiny scripts in a scratch folder.
final class CommandRunnerTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("cmdrunner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func script(_ body: String) throws -> String {
        let p = dir.appendingPathComponent("doz-\(UUID().uuidString.prefix(6))").path
        try ("#!/bin/sh\n" + body + "\n").write(toFile: p, atomically: true, encoding: .utf8)
        chmod(p, 0o755)
        return p
    }

    final class Lines: @unchecked Sendable {
        private let lock = NSLock(); private var all: [String] = []
        func add(_ s: String) { lock.lock(); all.append(s); lock.unlock() }
        var lines: [String] { lock.lock(); defer { lock.unlock() }; return all }
    }

    func testTheProcessIsDozItselfWithAnArgvNeverAShell() throws {
        let p = try XCTUnwrap(CommandRunner.process(.status, doz: "/opt/homebrew/bin/doz"))
        XCTAssertEqual(p.executableURL?.path, "/opt/homebrew/bin/doz")
        XCTAssertEqual(p.arguments, ["daemon", "status", "--json", "--no-send-anonymous-usage-stats"])
        XCTAssertNotEqual(p.executableURL?.path, "/bin/sh")
        XCTAssertNotNil(p.standardInput as? FileHandle, "stdin is /dev/null")
        XCTAssertNil(CommandRunner.process(.status, doz: "doz"), "never a bare name a PATH would resolve")
        let d = try XCTUnwrap(CommandRunner.process(.dashboard, doz: "/x/doz"))
        XCTAssertTrue((d.standardOutput as? FileHandle) === FileHandle.nullDevice, "the dashboard's output goes nowhere")
        XCTAssertTrue((d.standardError as? FileHandle) === FileHandle.nullDevice)
    }

    func testTheRefreshesAreNotCountedAsThePersonsCommands() {
        for c in [DozCommand.status, .appStatus] { XCTAssertTrue(c.arguments.contains("--no-send-anonymous-usage-stats"), c.label) }
        for c in [DozCommand.start, .stop, .restart, .dashboard, .updateApp] { XCTAssertFalse(c.arguments.contains("--no-send-anonymous-usage-stats"), c.label) }
    }

    func testOutputArgvAndStdin() throws {
        // It prints its arguments one per line and what it reads from stdin (nothing: /dev/null).
        let doz = try script(#"for a in "$@"; do echo "arg:$a"; done; cat; echo end"#)
        let lines = Lines()
        let r = CommandRunner(log: { lines.add($0) }).run(.status, doz: doz)
        XCTAssertEqual(r.exit, 0)
        XCTAssertFalse(r.timedOut)
        XCTAssertEqual(String(decoding: r.stdout, as: UTF8.self),
                       "arg:daemon\narg:status\narg:--json\narg:--no-send-anonymous-usage-stats\nend\n")
        XCTAssertEqual(lines.lines.count, 1)
        XCTAssertTrue(lines.lines[0].hasPrefix("doz daemon status → exit 0 in "), lines.lines[0])
    }

    func testTheExitCodeIsKept() throws {
        let r = CommandRunner(log: { _ in }).run(.start, doz: try script(#"echo '{"error":{"code":"failed","message":"no"}}'; exit 6"#))
        XCTAssertEqual(r.exit, 6)
        XCTAssertFalse(r.ok)
    }

    func testATimeoutKillsIt() throws {
        let doz = try script("exec sleep 30")
        let quick = DozCommand(["x"], timeout: 0.5, label: "x")
        let lines = Lines()
        let t0 = Date()
        let r = CommandRunner(log: { lines.add($0) }).run(quick, doz: doz)
        XCTAssertTrue(r.timedOut)
        XCTAssertFalse(r.ok)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 5)
        XCTAssertTrue(lines.lines.first?.contains("timed out") == true)
    }

    func testTheOutputIsCapped() throws {
        // 3 MiB of output: 1 MiB kept, the rest read and dropped (the writer is never blocked).
        let doz = try script("head -c 3145728 /dev/zero")
        let r = CommandRunner(log: { _ in }).run(DozCommand(["x"], timeout: 20, label: "x"), doz: doz)
        XCTAssertEqual(r.exit, 0)
        XCTAssertEqual(r.stdout.count, CommandRunner.outputCap)
        XCTAssertTrue(r.truncated)
    }

    /// The dashboard: whatever doz ui prints (a link, were it ever printed) never reaches this process or its log.
    func testTheDashboardsOutputNeverReachesTheAppOrItsLog() throws {
        let doz = try script("echo 'http://127.0.0.1:7777/#k=SECRETTOKEN'; echo 'SECRETTOKEN' >&2")
        let lines = Lines()
        let r = CommandRunner(log: { lines.add($0) }).run(.dashboard, doz: doz)
        XCTAssertEqual(r.exit, 0)
        XCTAssertTrue(r.stdout.isEmpty)
        XCTAssertEqual(lines.lines.count, 1)
        XCTAssertFalse(lines.lines[0].contains("SECRET"))
        XCTAssertFalse(lines.lines[0].contains("#"))
        XCTAssertTrue(lines.lines[0].hasPrefix("doz ui --detach → exit 0"), lines.lines[0])
    }

    /// The log line names the command words and how it ended — never an output or an argument value.
    func testTheLogLineCarriesNoOutput() throws {
        let doz = try script("echo '{\"running\":false,\"store\":\"/secret/place\"}'")
        let lines = Lines()
        _ = CommandRunner(log: { lines.add($0) }).run(.status, doz: doz)
        XCTAssertFalse(lines.lines[0].contains("/secret/place"))
        XCTAssertFalse(lines.lines[0].contains("--no-send"))
    }

    func testAProgramThatCannotRun() {
        let lines = Lines()
        let r = CommandRunner(log: { lines.add($0) }).run(.status, doz: dir.appendingPathComponent("missing").path)
        XCTAssertNil(r.exit)
        XCTAssertNotNil(r.launchError)
        XCTAssertTrue(lines.lines[0].contains("could not start"))
    }
}
