import ArgumentParser
import Darwin
import Foundation
import DozableKit
import XCTest
@testable import DozableCLI
@testable import DozableHost

/// 675 — the helper build (the doz an app carries): what decides it, that it never updates itself (not even asked, never
/// a feed request), that the host says which flavour it is, and the app it belongs to. The compile-time half (no
/// dashboard, no wizards) is checked on the packed binary by `make release FLAVOUR=helper` and `make test-cli-helper`.
final class HelperBuildTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: "/tmp/d675-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        unsetenv("DOZ_TEST_HELPER_BUILD")
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    /// `<root>/libexec/doz/doz` (or any folder) with VERSION and, when given, RELEASE.
    private func install(_ folder: URL, release: String?) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let exe = folder.appendingPathComponent("doz")
        FileManager.default.createFile(atPath: exe.path, contents: Data())
        try "0.37.41\n".write(to: folder.appendingPathComponent("VERSION"), atomically: true, encoding: .utf8)
        if let release { try (release + "\n").write(to: folder.appendingPathComponent("RELEASE"), atomically: true, encoding: .utf8) }
        return exe
    }

    func testTheFlavourIsTheCompiledOneUnlessTheTestSeamSaysOtherwise() {
        let cli = BuildFlavor(isPublic: true)
        XCTAssertFalse(BuildFlavor.from([:], compiled: cli).isHelper)
        XCTAssertTrue(BuildFlavor.from(["DOZ_TEST_HELPER_BUILD": "1"], compiled: cli).isHelper)
        XCTAssertFalse(BuildFlavor.from(["DOZ_TEST_HELPER_BUILD": "0"], compiled: BuildFlavor(isPublic: true, isHelper: true)).isHelper)
        XCTAssertFalse(BuildFlavor.from(["DOZ_TEST_HELPER_BUILD": "yes"], compiled: cli).isHelper)
        // The two seams are independent.
        let both = BuildFlavor.from(["DOZ_TEST_HELPER_BUILD": "1", "DOZ_TEST_PUBLIC_BUILD": "0"], compiled: cli)
        XCTAssertTrue(both.isHelper)
        XCTAssertFalse(both.isPublic)
        XCTAssertEqual(BuildFlavor(isPublic: true).flavourName, "cli")
        XCTAssertEqual(BuildFlavor(isPublic: true, isHelper: true).flavourName, "helper")
        XCTAssertFalse(BuildFlavor.compiled.isHelper, "the tests are the CLI build")
    }

    func testTheAppAHelperBelongsTo() {
        XCTAssertEqual(BuildFlavor.owningApp(executable: "/Applications/SandboxLab.app/Contents/Resources/Helpers/doz/doz"), "SandboxLab")
        XCTAssertEqual(BuildFlavor.owningApp(executable: "/Applications/Deck osaurus.app/Contents/Resources/Helpers/doz/doz"), "Deck osaurus")
        XCTAssertNil(BuildFlavor.owningApp(executable: "/opt/homebrew/Cellar/doz/0.37.41/libexec/doz/doz"))
        XCTAssertNil(BuildFlavor.owningApp(executable: "/x/.app/doz"), "a folder called .app is no app")
        XCTAssertTrue(BuildFlavor.helperUpdates(app: "SandboxLab").contains("this doz belongs to SandboxLab; SandboxLab updates it"))
        XCTAssertTrue(BuildFlavor.helperUpdates(app: nil).contains("the app updates it"))
        XCTAssertTrue(BuildFlavor.helperLeavesOut("doz ui").hasPrefix("doz ui is not in this build"))
    }

    func testAHelperIsDetectedByItsMarkerOrItsBuildAndNeverUpdated() throws {
        let cli = BuildFlavor(isPublic: true)
        // The helper's layout inside an app: RELEASE says helper.
        let inApp = try install(dir.appendingPathComponent("Lab.app/Contents/Resources/Helpers/doz"), release: "helper")
        XCTAssertEqual(InstallMethod.detect(executable: inApp.path, flavour: cli), .helper(app: "Lab"))
        // The same folder as a release tarball's libexec/doz: still the helper (the marker decides, not the place).
        let tar = try install(dir.appendingPathComponent("doz-0.37.41-helper/libexec/doz"), release: "helper+cloud")
        XCTAssertEqual(InstallMethod.detect(executable: tar.path, flavour: cli), .helper(app: nil))
        // A CLI release tarball is still a tarball; a helper BUILD is a helper wherever it is.
        let cliTar = try install(dir.appendingPathComponent("doz-0.37.41/libexec/doz"), release: "public+cloud")
        XCTAssertEqual(InstallMethod.detect(executable: cliTar.path, flavour: cli), .tarball(prefix: dir.appendingPathComponent("doz-0.37.41").resolvingSymlinksInPath()))
        XCTAssertEqual(InstallMethod.detect(executable: cliTar.path, flavour: BuildFlavor(isPublic: true, isHelper: true)), .helper(app: nil))
        XCTAssertNil(InstallMethod.helper(app: "Lab").upgradeCommand)
        XCTAssertEqual(UpdateHook.describe(.helper(app: "Lab")), "helper build (Lab)")
    }

    func testAHelperNeverAsksTheFeedNotEvenWhenAsked() async throws {
        let ctx = UpdateContext(mode: .auto, channel: .stable, current: "0.37.41", method: .helper(app: "Lab"),
                                feedURL: URL(string: "https://updates.example.invalid/v1/feed.json")!,
                                publicKey: Data(repeating: 1, count: 32), stateURL: dir.appendingPathComponent("updates.json"),
                                testWithoutFeed: true)
        for manual in [false, true] {
            XCTAssertEqual(ctx.disabledReason(manual: manual), BuildFlavor.helperUpdates(app: "Lab"), "the helper's reason first, whatever else")
        }
        let asked = Counter()
        let fetch: UpdateFetch = { _ in asked.add(); throw URLError(.cancelled) }
        for (force, manual) in [(false, false), (true, false), (false, true)] {
            let r = await UpdateChecker.check(ctx, force: force, manual: manual, fetch: fetch)
            XCTAssertEqual(r.disabled, BuildFlavor.helperUpdates(app: "Lab"))
            XCTAssertNil(r.available)
        }
        XCTAssertEqual(asked.value, 0, "no feed request, ever")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("updates.json").path), "no update state written")
        do {
            _ = try await UpdateHook.install(UpdateEntry.sample, ctx, store: DozableStore(root: dir.appendingPathComponent("store")), quiet: true)
            XCTFail("a helper installs nothing")
        } catch let e as UpdateInstaller.Failure {
            XCTAssertTrue("\(e)".contains("belongs to Lab"), "\(e)")
        }
    }

    func testDozUpgradeRefusesInAHelperBeforeAnything() async throws {
        setenv("DOZ_TEST_HELPER_BUILD", "1", 1)
        let store = dir.appendingPathComponent("store")
        var cmd = try DozableCommand.parseAsRoot(["upgrade", "--channel", "beta", "--yes", "--store", store.path, "--json"])
        do {
            try await (cmd as! UpdateCommand).run()
            XCTFail("doz upgrade must refuse in a helper")
        } catch let e as ExitCode {
            XCTAssertEqual(e.rawValue, DozableExit.failed)
        }
        cmd = try DozableCommand.parseAsRoot(["upgrade", "--check", "--store", store.path, "--json"])
        do { try await (cmd as! UpdateCommand).run(); XCTFail() } catch let e as ExitCode { XCTAssertEqual(e.rawValue, DozableExit.failed) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.path), "nothing was made")
    }

    /// H6: the host's status (the ping answer) says which build it is.
    func testTheHostSaysWhichFlavourItIs() async throws {
        let core = HostCore(store: DozableStore(root: dir.appendingPathComponent("store")), readOnly: true, version: "0.37.41")
        await core.load()
        let cli = await core.status()
        XCTAssertEqual(cli.flavour, "cli")
        XCTAssertEqual(cli.protocolVersion, HostProtocol.version)
        setenv("DOZ_TEST_HELPER_BUILD", "1", 1)
        let helper = await core.status()
        XCTAssertEqual(helper.flavour, "helper")
        // On the wire, beside version and protocolVersion; an older host's status (no flavour) still decodes.
        let wire = String(decoding: try HostWire.encoder.encode(helper), as: UTF8.self)
        XCTAssertTrue(wire.contains("\"flavour\":\"helper\""), wire)
        var old = helper
        old.flavour = nil
        let decoded = try HostWire.decoder.decode(HostStatus.self, from: try HostWire.encoder.encode(old))
        XCTAssertNil(decoded.flavour)
        XCTAssertTrue(describe(helper).hasPrefix("host 0.37.41 (the helper build) running"), describe(helper))
        XCTAssertFalse(describe(cli).contains("helper"))
    }

    /// The helper sends no usage statistics: never linked with the package, and off even if it ever were, whatever
    /// the setting or the flag says.
    func testAHelperSendsNoUsageStatistics() {
        let settings = DozableSettings(text: nil)
        for official in [false, true] {
            let s = UsageSwitches.decide(official: official, method: .helper(app: "SandboxLab"), settings: settings, env: [:],
                                         flag: true, guarded: false)
            XCTAssertFalse(s.on)
            XCTAssertTrue(s.why.contains("helper build"), s.why)
        }
        setenv("DOZ_TEST_HELPER_BUILD", "1", 1)
        XCTAssertTrue(UsageRuntime.decide(env: [:], settings: settings, flag: true).why.contains("helper build"))
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func add() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
}

private extension UpdateEntry {
    static var sample: UpdateEntry {
        UpdateEntry(version: "9.9.9", build: 99, channel: "stable", archive: "https://example.invalid/doz.tar.gz", size: 1,
                    sha256: String(repeating: "0", count: 64), signature: "x")
    }
}
