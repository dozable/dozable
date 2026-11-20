import XCTest
@testable import DozableMenuBarCore

/// The dev flavour ("Dozable Dev.app", `make app-dev`): chosen by the bundle's Info.plist; its ONE doz is
/// `DozableDevDoz` (never a standard place); doz runs with the dev settings (`XDG_CONFIG_HOME`); it registers nothing —
/// Start at Login, the login agent and `doz app install` are refused even if reached. The release flavour is unchanged.
final class MenuBarFlavourTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("flavour-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func executable(_ name: String) throws -> String {
        let p = dir.appendingPathComponent(name).path
        try FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try "#!/bin/sh\necho 0.52.16\n".write(toFile: p, atomically: true, encoding: .utf8)
        chmod(p, 0o755)
        return p
    }

    let devInfo: [String: Any] = ["CFBundleIdentifier": "com.dozable.app.dev", "DozableFlavour": "dev",
                                  "DozableDevDoz": "/Users/someone/.local/doz-dev/bin/doz",
                                  "DozableDevConfigHome": "/Users/someone/.local/doz-dev/config"]
    var dev: MenuBarFlavour { MenuBarFlavour.from(info: devInfo) }
    /// A person's run (no test guard): what the app does outside a test.
    let personEnv: [String: String] = [:]

    // MARK: choosing the flavour

    func testTheFlavourComesFromTheInfoPlist() {
        XCTAssertEqual(dev, .dev(doz: "/Users/someone/.local/doz-dev/bin/doz", configHome: "/Users/someone/.local/doz-dev/config"))
        XCTAssertEqual(MenuBarFlavour.from(info: nil), .release)
        XCTAssertEqual(MenuBarFlavour.from(info: ["CFBundleIdentifier": "com.dozable.app"]), .release)
        XCTAssertEqual(MenuBarFlavour.from(info: ["DozableFlavour": "release"]), .release)
        XCTAssertEqual(MenuBarFlavour.from(info: ["DozableFlavour": "dev", "DozableDevDoz": "bin/doz", "DozableDevConfigHome": 3]),
                       .dev(doz: nil, configHome: nil), "a relative or wrong-typed value is no value — never a fallback")
        XCTAssertTrue(dev.isDev)
        XCTAssertEqual(dev.name, "Dozable Dev")
        XCTAssertEqual(dev.badge, "DEV")
        XCTAssertEqual(MenuBarFlavour.release.name, "Dozable")
        XCTAssertNil(MenuBarFlavour.release.badge)
    }

    // MARK: finding doz

    func testTheDevFlavoursOnlyCandidateIsTheDevDoz() {
        XCTAssertEqual(dev.dozCandidates(env: personEnv, home: "/Users/someone"), ["/Users/someone/.local/doz-dev/bin/doz"])
        XCTAssertEqual(MenuBarFlavour.dev(doz: nil, configHome: nil).dozCandidates(env: personEnv, home: "/h"), [],
                       "no dev doz named → no doz at all: never the release doz, never a PATH search")
        XCTAssertEqual(MenuBarFlavour.dev(doz: nil, configHome: nil).dozCandidates(env: ["PATH": "/opt/homebrew/bin"], home: "/h"), [])
    }

    func testTheDevDozIsUsedOnlyWhenItIsAnExecutableFile() throws {
        let missing = dir.appendingPathComponent("doz-dev/bin/doz").path
        let flavour = MenuBarFlavour.dev(doz: missing, configHome: nil)
        XCTAssertNil(DozLocator.standard(flavour: flavour, env: personEnv).locate(), "missing → not installed, nothing else tried")
        try FileManager.default.createDirectory(atPath: missing, withIntermediateDirectories: true)
        XCTAssertNil(DozLocator.standard(flavour: flavour, env: personEnv).locate(), "a directory is not doz")
        try FileManager.default.removeItem(atPath: missing)
        try "plain".write(toFile: missing, atomically: true, encoding: .utf8)
        XCTAssertNil(DozLocator.standard(flavour: flavour, env: personEnv).locate(), "not executable → not doz")
        try FileManager.default.removeItem(atPath: missing)
        let real = try executable("doz-dev/libexec/doz/doz")
        try FileManager.default.createSymbolicLink(atPath: missing, withDestinationPath: real)
        XCTAssertEqual(DozLocator.standard(flavour: flavour, env: personEnv).locate(), missing, "bin/doz → libexec: the link as named")
    }

    func testAGuardedRunUsesOnlyTheSeamWhateverTheFlavour() {
        let guarded = ["DOZ_TEST_GUARD": "1", "DOZ_MENUBAR_DOZ": "/tmp/fake/doz"]
        XCTAssertEqual(dev.dozCandidates(env: guarded, home: "/h"), ["/tmp/fake/doz"], "a test never runs the real dev doz")
        XCTAssertEqual(dev.dozCandidates(env: ["DOZ_TEST_GUARD": "1"], home: "/h"), [])
    }

    func testTheReleaseFlavourIsUnchanged() {
        XCTAssertEqual(MenuBarFlavour.release.dozCandidates(env: personEnv, home: "/Users/someone"),
                       DozLocator.standardCandidates(env: personEnv, home: "/Users/someone"))
        XCTAssertEqual(DozLocator.standard(flavour: .release, env: personEnv, home: "/Users/someone").candidates,
                       ["/opt/homebrew/bin/doz", "/usr/local/bin/doz", "/Users/someone/.local/bin/doz"])
        XCTAssertEqual(MenuBarFlavour.release.childEnvironment(env: personEnv), [:])
        let s = Snapshot(doz: .found(path: "/opt/homebrew/bin/doz", version: "0.52.16"), status: Fixture.status(Fixture.noDaemon),
                         appVersion: "0.52.16", login: LoginSnapshot(service: .none, stablePlace: true))
        XCTAssertEqual(s.flavour, .release)
        let items = MenuModel.items(for: s)
        XCTAssertEqual(items.first?.title, "Daemon stopped")
        XCTAssertFalse(items.contains { $0.title.contains("Dozable Dev") || $0.title.contains("dev build") })
        XCTAssertEqual(items.last?.title, "Quit Dozable Menu")
        XCTAssertEqual(MenuDump(s).flavour, "release")
        XCTAssertNil(MenuDump(s).badge)
    }

    // MARK: the child's environment

    func testTheDevDozRunsWithTheDevSettings() throws {
        XCTAssertEqual(dev.childEnvironment(env: personEnv), ["XDG_CONFIG_HOME": "/Users/someone/.local/doz-dev/config"])
        XCTAssertEqual(MenuBarFlavour.dev(doz: "/x/doz", configHome: nil).childEnvironment(env: personEnv), [:])
        // A test run: only the seam, never the real dev settings.
        XCTAssertEqual(dev.childEnvironment(env: ["DOZ_TEST_GUARD": "1"]), [:])
        XCTAssertEqual(dev.childEnvironment(env: ["DOZ_TEST_GUARD": "1", "DOZ_MENUBAR_CONFIG_HOME": "/tmp/xdg"]), ["XDG_CONFIG_HOME": "/tmp/xdg"])
        XCTAssertEqual(dev.childEnvironment(env: ["DOZ_TEST_GUARD": "1", "DOZ_MENUBAR_CONFIG_HOME": "rel"]), [:])

        let p = try XCTUnwrap(CommandRunner.process(.status, doz: "/x/doz", extraEnvironment: ["XDG_CONFIG_HOME": "/dev/config"],
                                                    base: ["HOME": "/Users/someone", "XDG_CONFIG_HOME": "/Users/someone/.config"]))
        XCTAssertEqual(p.environment, ["HOME": "/Users/someone", "XDG_CONFIG_HOME": "/dev/config"])
        XCTAssertEqual(p.executableURL?.path, "/x/doz", "still the absolute path — never a shell")
        XCTAssertEqual(p.arguments, DozCommand.status.arguments)
        XCTAssertNil(try XCTUnwrap(CommandRunner.process(.status, doz: "/x/doz")).environment, "the release child inherits as is")
    }

    func testTheRunnerHandsTheDevSettingsToDoz() throws {
        let out = dir.appendingPathComponent("env.txt").path
        let doz = dir.appendingPathComponent("doz").path
        try "#!/bin/sh\necho \"$XDG_CONFIG_HOME|$*\" > '\(out)'\n".write(toFile: doz, atomically: true, encoding: .utf8)
        chmod(doz, 0o755)
        let r = CommandRunner(extraEnvironment: ["XDG_CONFIG_HOME": "/dev/settings"], log: { _ in }).run(.version, doz: doz)
        XCTAssertEqual(r.exit, 0)
        XCTAssertEqual(try String(contentsOfFile: out, encoding: .utf8), "/dev/settings|--version\n")
    }

    // MARK: no system registration

    func devSource(_ runner: FakeRunner, service: LoginItemService) -> SnapshotSource {
        SnapshotSource(locator: DozLocator(candidates: ["/x/doz"], accept: { _ in true }), runner: runner, appVersion: "0.52.16",
                       login: .init(service: service, look: LaunchdLook(program: nil), stablePlace: true, loadedWait: 0),
                       flavour: dev)
    }

    func testStartAtLoginIsRefusedEvenIfReached() {
        let runner = FakeRunner()
        let log = dir.appendingPathComponent("login.log").path
        // Even handed the recording service, the dev flavour asks it nothing and runs no doz command.
        let recording = RecordingLoginItemService(env: ["DOZ_TEST_LOGIN_ITEM_LOG": log])
        let source = devSource(runner, service: recording)
        for action in [MenuAction.loginOn, .loginOff, .loginSettings] {
            let o = source.performLogin(action)
            XCTAssertEqual(o.error, "Start at Login is not in the dev build", action.rawValue)
            XCTAssertEqual(o.steps, [])
            XCTAssertEqual(source.perform(action), "Start at Login is not in the dev build")
        }
        XCTAssertEqual(runner.labels, [], "no doz config set, nothing")
        XCTAssertFalse(FileManager.default.fileExists(atPath: log), "the service was never asked to register")

        let refusing = RefusingLoginItemService()
        XCTAssertEqual(refusing.state(), .none)
        XCTAssertEqual(refusing.register().error, "Start at Login is not in the dev build")
        XCTAssertNil(refusing.unregister().error, "nothing to take back")
        // The flow itself, if anything reached it with the dev service: refused at the registration, doz never told.
        let o = LoginItemFlow.turnOn(service: refusing, look: LaunchdLook(program: nil), runner: runner, doz: "/x/doz", wait: 0)
        XCTAssertNotNil(o.error)
        XCTAssertEqual(runner.labels, [])
    }

    func testAppInstallIsRefusedAndTheRowsSaySo() {
        let runner = FakeRunner()
        runner.answer(.updateApp, "{}")
        let source = devSource(runner, service: RefusingLoginItemService())
        XCTAssertEqual(source.perform(.updateApp), "Updating the menu bar app is not in the dev build")
        XCTAssertEqual(runner.labels, [], "doz app install never run")

        let s = Snapshot(doz: .found(path: "/x/doz", version: "0.52.16"), status: Fixture.status(Fixture.noDaemon),
                         appVersion: "0.52.15", bundledAppVersion: "0.52.16", login: LoginSnapshot(service: .none, stablePlace: false),
                         flavour: dev)
        let items = MenuModel.items(for: s)
        XCTAssertEqual(items.first?.title, "Dozable Dev", "the menu's header names the dev app")
        XCTAssertEqual(items.first?.kind, .header)
        XCTAssertEqual(items[1].title, "Daemon stopped")
        let login = items.first { $0.title.hasPrefix("Start at Login") }
        XCTAssertEqual(login?.title, "Start at Login — not in the dev build")
        XCTAssertEqual(login?.enabled, false)
        XCTAssertNil(login?.action)
        let update = items.first { $0.title.hasPrefix("Update Menu Bar App") }
        XCTAssertEqual(update?.title, "Update Menu Bar App — not in the dev build")
        XCTAssertEqual(update?.enabled, false)
        XCTAssertNil(update?.action)
        XCTAssertFalse(items.contains { $0.action == .updateApp || $0.action == .loginOn || $0.action == .loginOff || $0.action == .loginSettings })
        XCTAssertEqual(items.last?.title, "Quit Dozable Dev Menu")
        XCTAssertEqual(MenuDump(s).flavour, "dev")
        XCTAssertEqual(MenuDump(s).badge, "DEV")
    }

    func testTheLoginAgentStartsNothingInTheDevBuild() throws {
        let doz = try executable("bin/doz")
        let locator = DozLocator(candidates: [doz])
        XCTAssertEqual(LaunchAgent.decide(locator, flavour: dev), .none(LaunchAgent.devRefusal))
        XCTAssertEqual(LaunchAgent.decide(locator, flavour: .release), .run(doz), "the release agent unchanged")
    }
}
