import XCTest
@testable import DozableHost
@testable import DozableCLI

/// `doz app install|status|uninstall`'s decisions, and an install end to end into a SCRATCH folder with a tiny ad-hoc
/// signed bundle made here (a copy of /bin/echo as its executable) — never /Applications.
final class AppInstallTests: XCTestCase {
    var dir: URL!
    let home = URL(fileURLWithPath: "/Users/someone")

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("appinstall-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    /// A signed Dozable.app (ad hoc, identifier com.dozable.app) at `at`, version `version`.
    func makeApp(_ at: URL, version: String, identifier: String = "com.dozable.app") throws -> URL {
        let app = at.appendingPathComponent("Dozable.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: "/bin/echo", toPath: app.appendingPathComponent("Contents/MacOS/Dozable").path)
        let plist: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleExecutable": "Dozable", "CFBundlePackageType": "APPL",
                                    "CFBundleShortVersionString": version, "CFBundleVersion": version, "LSUIElement": true]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        let r = MenuBarAppInstall.runTool("/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", identifier, app.path])
        XCTAssertEqual(r.status, 0, r.output)
        return app
    }

    func testTheDefaultDestination() throws {
        XCTAssertEqual(try MenuBarAppInstall.defaultDestination(env: [:], guarded: false, home: home, writable: { _ in true }).path, "/Applications")
        XCTAssertEqual(try MenuBarAppInstall.defaultDestination(env: [:], guarded: false, home: home, writable: { _ in false }).path,
                       "/Users/someone/Applications", "~/Applications when /Applications is not writable")
        XCTAssertEqual(try MenuBarAppInstall.defaultDestination(env: ["DOZ_TEST_APPLICATIONS_DIR": "/tmp/apps"], guarded: true, home: home).path, "/tmp/apps")
        XCTAssertThrowsError(try MenuBarAppInstall.defaultDestination(env: [:], guarded: true, home: home, writable: { _ in true }),
                             "a test run never falls back to /Applications")
        XCTAssertEqual(MenuBarAppInstall.lookPlaces(env: [:], guarded: false, home: home).map(\.path), ["/Applications", "/Users/someone/Applications"])
        XCTAssertEqual(MenuBarAppInstall.lookPlaces(env: [:], guarded: true, home: home), [], "a test run looks nowhere real")
        XCTAssertEqual(MenuBarAppInstall.lookPlaces(env: ["DOZ_TEST_APPLICATIONS_DIR": "/tmp/apps"], guarded: true, home: home).map(\.path), ["/tmp/apps"])
    }

    func testTheBundledCopyIsBesideTheResolvedDoz() throws {
        let libexec = dir.appendingPathComponent("libexec/doz")
        try FileManager.default.createDirectory(at: libexec, withIntermediateDirectories: true)
        let doz = libexec.appendingPathComponent("doz")
        FileManager.default.createFile(atPath: doz.path, contents: Data())
        let bin = dir.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: bin.appendingPathComponent("doz").path, withDestinationPath: "../libexec/doz/doz")
        XCTAssertNil(MenuBarAppInstall.bundled(executable: bin.appendingPathComponent("doz").path))
        _ = try makeApp(libexec, version: "0.50.7")
        XCTAssertEqual(MenuBarAppInstall.bundled(executable: bin.appendingPathComponent("doz").path)?.resolvingSymlinksInPath().path,
                       libexec.appendingPathComponent("Dozable.app").resolvingSymlinksInPath().path)
    }

    func testATeamIsRequiredOfAReleaseOnly() throws {
        let libexec = dir.appendingPathComponent("rel/libexec/doz")
        try FileManager.default.createDirectory(at: libexec, withIntermediateDirectories: true)
        let doz = libexec.appendingPathComponent("doz").path
        FileManager.default.createFile(atPath: doz, contents: Data())
        XCTAssertFalse(MenuBarAppInstall.requiresTeam(executable: doz, env: [:], guarded: false), "a development install")
        FileManager.default.createFile(atPath: libexec.appendingPathComponent("RELEASE").path, contents: Data("public\n".utf8))
        XCTAssertTrue(MenuBarAppInstall.requiresTeam(executable: doz, env: [:], guarded: false))
        XCTAssertFalse(MenuBarAppInstall.requiresTeam(executable: doz, env: ["DOZ_TEST_UPDATE_ALLOW_ADHOC": "1"], guarded: true))
        XCTAssertTrue(MenuBarAppInstall.requiresTeam(executable: doz, env: ["DOZ_TEST_UPDATE_ALLOW_ADHOC": "1"], guarded: false), "the seam is a test run's only")
    }

    func testVerify() throws {
        let app = try makeApp(dir.appendingPathComponent("a"), version: "0.50.7")
        XCTAssertNil(MenuBarAppInstall.verify(app, version: "0.50.7", requireTeam: false))
        XCTAssertNotNil(MenuBarAppInstall.verify(app, version: "0.50.8", requireTeam: false), "its version must be doz's")
        XCTAssertNotNil(MenuBarAppInstall.verify(app, version: "0.50.7", requireTeam: true), "ad hoc is not Dozable's team")
        let other = try makeApp(dir.appendingPathComponent("b"), version: "0.50.7", identifier: "com.example.other")
        XCTAssertNotNil(MenuBarAppInstall.verify(other, version: "0.50.7", requireTeam: false))
        // Signed by the team (as codesign would say it) passes the team check.
        let fake: (String, [String]) -> (status: Int32, output: String) = { _, args in
            args.contains("--verify") ? (0, "") : (0, "Identifier=com.dozable.app\nTeamIdentifier=\(Distribution.teamID)\n")
        }
        XCTAssertNil(MenuBarAppInstall.verify(app, version: "0.50.7", requireTeam: true, run: fake))
    }

    func testInstallBySwapQuarantineRemovedTamperedRefused() throws {
        let src = try makeApp(dir.appendingPathComponent("src1"), version: "0.50.7")
        XCTAssertEqual(setxattr(src.appendingPathComponent("Contents/MacOS/Dozable").path, "com.apple.quarantine", "0081;00000000;Safari;", 21, 0, 0), 0)
        XCTAssertTrue(MenuBarAppInstall.hasQuarantine(src))
        let dest = dir.appendingPathComponent("Applications")
        var opened: [URL] = []
        var r = try MenuBarAppInstall.install(bundled: src, dest: dest, version: "0.50.7", requireTeam: false, open: false, opener: { opened.append($0); return true })
        let target = dest.appendingPathComponent("Dozable.app")
        XCTAssertEqual(r.path, target.path)
        XCTAssertNil(r.previousVersion)
        XCTAssertFalse(r.opened)
        XCTAssertTrue(opened.isEmpty)
        XCTAssertFalse(MenuBarAppInstall.hasQuarantine(target), "the verified copy carries no quarantine mark")
        XCTAssertEqual(MenuBarAppInstall.runTool("/usr/bin/codesign", ["--verify", "--strict", target.path]).status, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.appendingPathComponent(".Dozable.app.new").path))
        XCTAssertEqual(MenuBarAppInstall.installedCopies([dest]), [target])

        // A newer copy swaps in: a new file (the running one keeps its inode), the previous removed after the swap.
        let inodeBefore = try FileManager.default.attributesOfItem(atPath: target.appendingPathComponent("Contents/MacOS/Dozable").path)[.systemFileNumber] as? Int
        let held = open(target.appendingPathComponent("Contents/MacOS/Dozable").path, O_RDONLY)
        defer { close(held) }
        let src2 = try makeApp(dir.appendingPathComponent("src2"), version: "0.51.0")
        r = try MenuBarAppInstall.install(bundled: src2, dest: dest, version: "0.51.0", requireTeam: false, open: true, opener: { opened.append($0); return true })
        XCTAssertEqual(r.previousVersion, "0.50.7")
        XCTAssertTrue(r.opened)
        XCTAssertEqual(opened, [target])
        XCTAssertEqual(MenuBarAppInstall.info(target)?.version, "0.51.0")
        let inodeAfter = try FileManager.default.attributesOfItem(atPath: target.appendingPathComponent("Contents/MacOS/Dozable").path)[.systemFileNumber] as? Int
        XCTAssertNotEqual(inodeBefore, inodeAfter, "never written in place")
        var st = stat()
        XCTAssertEqual(fstat(held, &st), 0, "the old file a running copy holds is still there for it")
        XCTAssertEqual(Int(st.st_ino), inodeBefore)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.appendingPathComponent(".Dozable.app.new").path))

        // Tampered (a file added after signing): refused, the installed copy unchanged.
        let src3 = try makeApp(dir.appendingPathComponent("src3"), version: "0.52.0")
        try FileManager.default.createDirectory(at: src3.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: src3.appendingPathComponent("Contents/Resources/added"))
        XCTAssertThrowsError(try MenuBarAppInstall.install(bundled: src3, dest: dest, version: "0.52.0", requireTeam: false, open: false, opener: { _ in true }))
        XCTAssertEqual(MenuBarAppInstall.info(target)?.version, "0.51.0")

        // Another app of the same name is never replaced.
        let foreign = dir.appendingPathComponent("foreign")
        _ = try makeApp(foreign, version: "1.0.0", identifier: "com.example.other")
        XCTAssertThrowsError(try MenuBarAppInstall.install(bundled: src2, dest: foreign, version: "0.51.0", requireTeam: false, open: false, opener: { _ in true }))
        XCTAssertEqual(MenuBarAppInstall.installedCopies([foreign]), [], "not Dozable's: not listed")
    }
}
