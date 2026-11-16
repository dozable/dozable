import ArgumentParser
import Darwin
import Foundation
import XCTest
@testable import DozableCLI
@testable import DozableHost

/// The temporary host→daemon migration (Sources/DozableHost/Migration/HostToDaemon.swift) — delete this file with it.
/// Both locks taken, an old lock held → waited for, the log renamed once, `host.*` settings read and moved by the first
/// write, the old launcher forms taken and nothing else, and nothing outside its file and its one call refers to it.
final class HostToDaemonMigrationTests: XCTestCase {
    private var dir: URL!
    private var store: DozableStore!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: "/private/tmp/dzm-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = DozableStore(root: dir.appendingPathComponent("s"))
        try store.ensureDirectory()
        _ = HostToDaemon.begin([])
    }

    override func tearDownWithError() throws {
        // The seams are process-wide: leave them as every other test expects (no migration).
        DozableStore.formerDaemonFiles = nil
        DozableSettings.formerNames = [:]
        try? FileManager.default.removeItem(at: dir)
    }

    private func held(_ name: String) -> Bool {
        let fd = open(store.root.appendingPathComponent(name).path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 { flock(fd, LOCK_UN); return false }
        return errno == EWOULDBLOCK
    }

    /// An older daemon's hold on `host.lock` (another open file: flock conflicts within one process too).
    private func holdOldLock() throws -> Int32 {
        let fd = open(store.root.appendingPathComponent("host.lock").path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        XCTAssertGreaterThanOrEqual(fd, 0)
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        return fd
    }

    func testADaemonTakesBothLocksAndHoldsThem() throws {
        try "4242\n".write(to: store.root.appendingPathComponent("host.pid"), atomically: true, encoding: .utf8)
        let fds = try HostServer.takeStoreLocks(store, waitSeconds: 1)
        defer { fds.forEach { close($0) } }
        XCTAssertEqual(fds.count, 2)
        XCTAssertTrue(held("daemon.lock"))
        XCTAssertTrue(held("host.lock"), "an older doz finds its lock held: it never becomes a second owner")
        XCTAssertTrue(store.hostIsRunning())
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.root.appendingPathComponent("host.pid").path),
                       "the older daemon's pid (it is gone: its lock is ours) is not left to read as a daemon killed")
    }

    func testWithoutTheMigrationOnlyTheDaemonsLock() throws {
        DozableStore.formerDaemonFiles = nil
        let fds = try HostServer.takeStoreLocks(store, waitSeconds: 1)
        defer { fds.forEach { close($0) } }
        XCTAssertEqual(fds.count, 1)
        XCTAssertFalse(held("host.lock"))
    }

    func testAnOlderDaemonsLockHeldIsWaitedForThenTaken() throws {
        let old = try holdOldLock()
        XCTAssertTrue(store.hostIsRunning(), "an older daemon holding host.lock is a running daemon")
        // An older daemon that is exiting lets go within the wait: the new one then has both.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { flock(old, LOCK_UN); close(old) }
        let t0 = Date()
        let fds = try HostServer.takeStoreLocks(store, waitSeconds: 10)
        defer { fds.forEach { close($0) } }
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(t0), 0.3, "it waited")
        XCTAssertEqual(fds.count, 2)
        XCTAssertTrue(held("host.lock"))
    }

    func testAnOlderDaemonThatStaysIsNeverJoined() throws {
        let old = try holdOldLock()
        defer { close(old) }
        XCTAssertThrowsError(try HostServer.takeStoreLocks(store, waitSeconds: 0.5)) { e in
            guard case HostServer.StartError.alreadyRunning = e else { return XCTFail("\(e)") }
        }
        XCTAssertFalse(held("daemon.lock"), "giving up lets go of the daemon's own lock too")
    }

    func testTheLogIsRenamedOnce() throws {
        let old = store.root.appendingPathComponent("host.log")
        try "the host's lines\n".write(to: old, atomically: true, encoding: .utf8)
        store.adoptFormerLog()
        XCTAssertEqual(try String(contentsOf: store.logFile, encoding: .utf8), "the host's lines\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        // Once: a daemon.log there is never replaced by an old one.
        try "older\n".write(to: old, atomically: true, encoding: .utf8)
        store.adoptFormerLog()
        XCTAssertEqual(try String(contentsOf: store.logFile, encoding: .utf8), "the host's lines\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.path))
    }

    func testAClientReachesAnOlderDaemonOnItsOldSocket() throws {
        let path = store.root.appendingPathComponent("host.sock").path
        let lfd = try UnixSocket.listen(path)
        defer { close(lfd); unlink(path) }
        let fd = try XCTUnwrap(HostClient.connectAny(store))
        close(fd)
        DozableStore.formerDaemonFiles = nil
        XCTAssertNil(HostClient.connectAny(store), "without the migration only daemon.sock")
    }

    func testHostSettingsAreReadAsDaemonAndMovedByTheFirstWrite() throws {
        let xdg = dir.appendingPathComponent("xdg")
        let file = xdg.appendingPathComponent("doz/doz.toml")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "[host]\nidle_timeout_minutes = 9\nkeepalive = true\n".write(to: file, atomically: true, encoding: .utf8)
        let env = ["XDG_CONFIG_HOME": xdg.path]
        let s = DozableSettings.load(environment: env)
        XCTAssertEqual(s.resolve(SettingKey.idleTimeout).value, .int(9))
        XCTAssertEqual(s.resolve(SettingKey.idleTimeout).migratedFrom, "host.idle_timeout_minutes")
        XCTAssertEqual(s.resolve(SettingKey.keepalive).value, .bool(true))
        XCTAssertTrue(s.warnings.isEmpty, "\(s.warnings)")
        XCTAssertEqual(s.idleTimeoutMinutes(flag: nil), 9)
        // DOZ_HOST_IDLE is not read; DOZ_DAEMON_IDLE is.
        XCTAssertEqual(DozableSettings.load(environment: env.merging(["DOZ_HOST_IDLE": "2"]) { $1 }).idleTimeoutMinutes(flag: nil), 9)
        XCTAssertEqual(DozableSettings.load(environment: env.merging(["DOZ_DAEMON_IDLE": "2"]) { $1 }).idleTimeoutMinutes(flag: nil), 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: xdg.appendingPathComponent("doz/doz.toml.0.37.bak").path), "a read never writes")
        let now = try s.writing("ui.theme", .string("light"))
        XCTAssertTrue(now.migrationNotice?.contains("[daemon]") == true, now.migrationNotice ?? "no notice")
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.contains("[daemon]") && text.contains("\nidle_timeout_minutes = 9\n") && text.contains("\nkeepalive = true\n"), text)
        XCTAssertFalse(text.contains("[host]"))
        XCTAssertEqual(DozableSettings.load(environment: env).resolve(SettingKey.idleTimeout).migratedFrom, nil, "moved: read under its own name now")
        // Without the migration an old key is just unknown (the default applies, with a warning).
        DozableSettings.formerNames = [:]
        let plain = DozableSettings(text: "[host]\nidle_timeout_minutes = 9\n")
        XCTAssertEqual(plain.resolve(SettingKey.idleTimeout).value, .int(0))          // 693: the default is 0 (never)
        XCTAssertTrue(plain.warnings.contains { $0.contains("unknown setting host.idle_timeout_minutes") }, "\(plain.warnings)")
    }

    func testOnlyTheOlderLaunchersFormsAreTaken() {
        XCTAssertEqual(HostToDaemon.launcherArguments(["host", "start", "--launch-detached", "--store", "/s"]),
                       ["daemon", "start", "--launch-detached", "--store", "/s"])
        XCTAssertEqual(HostToDaemon.launcherArguments(["host", "start", "--foreground", "--launched", "--store", "/s", "--idle-timeout", "5"]),
                       ["daemon", "start", "--foreground", "--launched", "--store", "/s", "--idle-timeout", "5"])
        for a in [["host"], ["host", "status"], ["host", "stop"], ["host", "start"], ["host", "start", "--foreground"], ["host", "restart"],
                  ["daemon", "start", "--launch-detached"], ["ls"]] {
            XCTAssertEqual(HostToDaemon.launcherArguments(a), a, "\(a) is left as typed")
        }
    }

    func testDozHostIsAnUnknownCommandWithNoAlias() throws {
        XCTAssertTrue(try DozableCommand.parseAsRoot(["daemon", "status"]) is HostStatusCommand)
        XCTAssertTrue(try DozableCommand.parseAsRoot(["daemon", "stop"]) is HostStop)
        XCTAssertTrue(try DozableCommand.parseAsRoot(["daemon", "restart"]) is HostRestart)
        XCTAssertTrue(try DozableCommand.parseAsRoot(["daemon", "start", "--foreground"]) is HostRun)
        for a in [["host", "status"], ["host", "stop"], ["host"]] {
            XCTAssertThrowsError(try DozableCommand.parseAsRoot(a)) { e in
                let m = DozableCommand.message(for: e)
                XCTAssertFalse(m.contains("daemon"), "no hint, no alias: \(m)")
                XCTAssertEqual(DozableCommand.exitCode(for: e), .validationFailure, "\(a): \(m)")
            }
        }
    }

    /// The migration is ONE file, ONE call and this test: nothing else may name it (so deleting those three is the whole
    /// removal — the seams it fills are inert without it).
    func testNothingElseReferencesTheMigration() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let allowed = ["Sources/DozableHost/Migration/HostToDaemon.swift": nil, "Sources/DozableCLI/UpdateCommands.swift": 1,
                       "Tests/DozableCLITests/HostToDaemonMigrationTests.swift": nil] as [String: Int?]
        var found: [String: Int] = [:]
        for top in ["Sources", "Tests", "Scripts", "Package.swift", "Makefile"] {
            let base = repo.appendingPathComponent(top)
            var files: [URL] = []
            if let e = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) {
                for case let u as URL in e where ["swift", "sh", "py", "mjs", "js", ""].contains(u.pathExtension) { files.append(u) }
            } else { files = [base] }
            if top == "Package.swift" || top == "Makefile" { files = [base] }
            for u in files {
                guard let text = try? String(contentsOf: u, encoding: .utf8) else { continue }
                let n = text.components(separatedBy: "HostToDaemon").count - 1
                if n > 0 { found[String(u.path.dropFirst(repo.path.count + 1)), default: 0] += n }
            }
        }
        for (path, n) in found {
            XCTAssertTrue(allowed.keys.contains(path), "\(path) names the migration (\(n)×) — only its file, its one call and this test may")
            if let want = allowed[path] ?? nil { XCTAssertEqual(n, want, "\(path): exactly one call") }
        }
        XCTAssertEqual(found["Sources/DozableCLI/UpdateCommands.swift"], 1, "the one call is there")
    }
}
