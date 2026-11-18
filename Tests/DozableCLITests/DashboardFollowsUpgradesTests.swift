import Darwin
import Foundation
import XCTest
@testable import DozableCLI
@testable import DozableHost

/// 714 — the dashboard follows upgrades: what `doz ui restart` (and Restart dashboard) execs, when a dashboard restarts
/// itself after an install, and doctor's advice for the older side. A Homebrew-shaped layout in a scratch prefix.
final class DashboardFollowsUpgradesTests: XCTestCase {
    var prefix: URL!

    override func setUp() {
        prefix = FileManager.default.temporaryDirectory.appendingPathComponent("doz-714-\(UUID().uuidString)").resolvingSymlinksInPath()
        try? FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: prefix) }

    /// `<prefix>/Cellar/<formula>/<v>/libexec/doz/doz` (a copy of /usr/bin/true, so it has an inode of its own) + VERSION.
    @discardableResult
    func keg(_ v: String, formula: String = "doz-canary") throws -> String {
        let dir = prefix.appendingPathComponent("Cellar/\(formula)/\(v)/libexec/doz")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let exe = dir.appendingPathComponent("doz")
        try? FileManager.default.removeItem(at: exe)
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: exe.path)
        try "\(v)\n".write(to: dir.appendingPathComponent("VERSION"), atomically: true, encoding: .utf8)
        return exe.path
    }

    /// `opt/<formula>` → `../Cellar/<formula>/<v>`, swapped by rename as Homebrew's link is.
    func link(_ v: String, formula: String = "doz-canary") throws {
        let opt = prefix.appendingPathComponent("opt")
        try FileManager.default.createDirectory(at: opt, withIntermediateDirectories: true)
        let tmp = opt.appendingPathComponent(".new").path
        unlink(tmp)
        XCTAssertEqual(symlink("../Cellar/\(formula)/\(v)", tmp), 0)
        XCTAssertEqual(rename(tmp, opt.appendingPathComponent(formula).path), 0)
    }

    var opt: String { prefix.appendingPathComponent("opt/doz-canary/libexec/doz/doz").path }

    // MARK: the argv a restart execs

    func testARestartOfADetachedDashboardRunsTheFormulasOptPathNotItsKeg() throws {
        let old = try keg("0.51.8")
        try link("0.51.8")
        try keg("0.51.9")
        try link("0.51.9")                                         // brew upgrade: the old keg is still on disk
        let argv = [old, "ui", "start", "--launched", "--no-open", "--store", "/s"]
        let r = UIRunner.restartArguments(argv, executable: old)
        XCTAssertEqual(r, [opt, "ui", "start", "--launched", "--no-open", "--store", "/s", "--restarted"])
        XCTAssertEqual(ReleaseStamp.read(executable: r[0]), "0.51.9", "the restart runs the doz installed now")
        XCTAssertEqual(StableExecutable.installedVersion(for: old), "0.51.9")
    }

    func testByNameStaysThePATHsAndOtherInstallsKeepTheirPath() throws {
        // Started by name: the PATH decides (Homebrew's bin/doz is relinked by the upgrade).
        XCTAssertEqual(UIRunner.restartArguments(["doz", "ui", "--open"], executable: "/nowhere/doz"), ["doz", "ui", "start", "--restarted"])
        // A make install-cli / tarball install: its own path (its folder is swapped in place).
        let inst = prefix.appendingPathComponent("local/libexec/doz")
        try FileManager.default.createDirectory(at: inst, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: inst.appendingPathComponent("doz").path)
        let p = inst.appendingPathComponent("doz").path
        XCTAssertEqual(UIRunner.restartArguments([p, "serve", "--print-url"], executable: p), [p, "ui", "start", "--lan", "--restarted"])
        // A keg whose formula has no opt link: the keg itself.
        let lone = try keg("0.1.0", formula: "doz-beta")
        XCTAssertEqual(UIRunner.restartArguments([lone, "ui", "start"], executable: lone).first, lone)
    }

    func testDetachedDashboardsAreStartedFromTheStablePath() throws {
        let old = try keg("0.51.8")
        try link("0.51.8")
        XCTAssertEqual(DetachedLauncher.uiProcessArgs(executable: StableExecutable.path(for: old), store: "/s").first, opt)
        XCTAssertEqual(DetachedLauncher.uiIntermediateArgs(executable: StableExecutable.path(for: old), store: "/s").first, opt)
    }

    // MARK: a dashboard's program replaced (it restarts itself only then, and only with nothing open)

    func testAProgramReplacedIsSeenThroughTheOptLinkAndAfterCleanup() throws {
        let old = try keg("0.51.8")
        try link("0.51.8")
        let id = try XCTUnwrap(ExecutableIdentity.of(path: old))
        XCTAssertFalse(UIRunner.programReplaced(id, stable: StableExecutable.path(for: old)), "nothing changed")
        try keg("0.51.9")
        try link("0.51.9")
        XCTAssertTrue(UIRunner.programReplaced(id, stable: StableExecutable.path(for: old)), "brew upgrade relinked opt")
        try FileManager.default.removeItem(at: prefix.appendingPathComponent("Cellar/doz-canary/0.51.8"))
        XCTAssertTrue(UIRunner.programReplaced(id, stable: opt), "brew cleanup removed the old keg: opt still names the new one")
        try FileManager.default.removeItem(at: prefix.appendingPathComponent("Cellar/doz-canary/0.51.9"))
        XCTAssertFalse(UIRunner.programReplaced(id, stable: opt), "nothing installed: never restart into nothing")
    }

    func testAnInstallByRenameIsAReplacementAnOverwriteIsNot() throws {
        let dir = prefix.appendingPathComponent("local/libexec/doz")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let p = dir.appendingPathComponent("doz").path
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: p)
        let id = try XCTUnwrap(ExecutableIdentity.of(path: p))
        // Overwritten in place (it may be half written): never.
        let h = try XCTUnwrap(FileHandle(forWritingAtPath: p))
        h.seekToEndOfFile(); h.write(Data([0])); try h.close()
        XCTAssertFalse(UIRunner.programReplaced(id, stable: p))
        // Renamed over it (make install-cli): yes.
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: p + ".new")
        XCTAssertEqual(rename(p + ".new", p), 0)
        XCTAssertTrue(UIRunner.programReplaced(id, stable: p))
    }

    func testTheCheckIntervalSeamIsForGuardedRunsOnly() {
        XCTAssertEqual(UIRunner.programCheckInterval([:]), 60)
        XCTAssertEqual(UIRunner.programCheckInterval(["DOZ_TEST_GUARD": "1", "DOZ_TEST_UI_PROGRAM_CHECK": "2"]), 2)
        XCTAssertEqual(UIRunner.programCheckInterval(["DOZ_TEST_GUARD": "1", "DOZ_TEST_UI_PROGRAM_CHECK": "0"]), 60)
        XCTAssertEqual(UIRunner.programCheckInterval(["DOZ_TEST_REAL_MAC": "1", "DOZ_TEST_UI_PROGRAM_CHECK": "2"]), 60)
    }

    // MARK: doctor's daemon row

    func testDoctorAdvisesTheOlderSide() throws {
        // The owner's case: this doz (the dashboard's) 0.51.8, the daemon 0.51.9, 0.51.9 installed.
        let a = try XCTUnwrap(Doctor.daemonVersionAdvice(daemon: "0.51.9", this: "0.51.8", installed: "0.51.9", upgrade: "doz upgrade -y"))
        XCTAssertFalse(a.contains("doz daemon stop"), "the daemon is the NEWER one")
        XCTAssertTrue(a.contains("0.51.9 is installed") && a.contains("doz ui restart"), a)
        // Nothing newer installed: upgrade this doz.
        let b = try XCTUnwrap(Doctor.daemonVersionAdvice(daemon: "0.51.9", this: "0.51.8", installed: "0.51.8", upgrade: "doz upgrade -y"))
        XCTAssertTrue(b.contains("upgrade it (doz upgrade -y)") && !b.contains("daemon stop"), b)
        XCTAssertFalse(try XCTUnwrap(Doctor.daemonVersionAdvice(daemon: "0.51.9", this: "0.51.8", installed: nil, upgrade: nil)).contains("("))
        // An older daemon: the daemon's advice, as before.
        XCTAssertEqual(Doctor.daemonVersionAdvice(daemon: "0.51.8", this: "0.51.9", installed: "0.51.9", upgrade: nil), " — this CLI is 0.51.9: doz daemon stop")
        XCTAssertNil(Doctor.daemonVersionAdvice(daemon: "0.51.9", this: "0.51.9", installed: "0.52.0", upgrade: nil))
        XCTAssertNil(Doctor.daemonVersionAdvice(daemon: "0.51.9+a", this: "0.51.9+b", installed: nil, upgrade: nil))
    }
}
