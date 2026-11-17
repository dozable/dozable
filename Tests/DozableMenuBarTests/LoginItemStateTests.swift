import XCTest
@testable import DozableMenuBarCore

/// Start at Login: the menu's row as SMAppService's status × doz's `loginItem.owner` × doz's version × where the app
/// runs; the flow's order (register, then — only once enabled AND loaded — tell doz); the recording service a test run
/// uses (it never calls SMAppService or launchctl).
final class LoginItemStateTests: XCTestCase {
    let doz = "/opt/homebrew/bin/doz"

    func snap(agent: LoginServiceStatus, mainApp: LoginServiceStatus? = nil, owner: String = "none", dozVersion: String? = "0.50.8",
              stable: Bool = true, busy: Snapshot.Busy? = nil) -> Snapshot {
        let st = Fixture.noDaemonWith { o in
            var li = o["loginItem"] as! [String: Any]
            li["owner"] = owner; li["installed"] = owner == "doz"; o["loginItem"] = li
        }
        return Snapshot(doz: .found(path: doz, version: dozVersion), status: st, busy: busy, appVersion: "0.50.8",
                        login: LoginSnapshot(service: LoginServiceState(agent: agent, mainApp: mainApp ?? agent), stablePlace: stable))
    }

    func row(_ s: Snapshot) -> MenuItem? { MenuModel.items(for: s).first { $0.title.hasPrefix("Start at Login") } }

    func testOffIsUncheckedAndTurnsOn() {
        for a in [LoginServiceStatus.notRegistered, .notFound] {
            let r = row(snap(agent: a))
            XCTAssertEqual(r?.title, "Start at Login", "\(a)")
            XCTAssertEqual(r?.checked, false)
            XCTAssertEqual(r?.enabled, true)
            XCTAssertEqual(r?.action, .loginOn)
        }
    }

    func testOnIsCheckedAndTurnsOff() {
        for owner in ["app", "none", "doz"] {
            let r = row(snap(agent: .enabled, owner: owner))
            XCTAssertEqual(r?.title, "Start at Login", owner)
            XCTAssertEqual(r?.checked, true)
            XCTAssertEqual(r?.action, .loginOff)
        }
    }

    func testNeedsApprovalOpensSystemSettings() {
        for (a, m) in [(LoginServiceStatus.requiresApproval, LoginServiceStatus.requiresApproval), (.enabled, .requiresApproval), (.requiresApproval, .enabled)] {
            let r = row(snap(agent: a, mainApp: m))
            XCTAssertEqual(r?.title, "Start at Login — needs approval: Open System Settings…")
            XCTAssertEqual(r?.action, .loginSettings)
            XCTAssertEqual(r?.enabled, true)
            XCTAssertEqual(r?.checked, false)
        }
    }

    func testSetByDozOffersTheHandOver() {
        let r = row(snap(agent: .notRegistered, owner: "doz"))
        XCTAssertEqual(r?.title, "Start at Login (set by doz — click to let this app hold it)")
        XCTAssertEqual(r?.checked, true)
        XCTAssertEqual(r?.action, .loginOn)
    }

    func testDozTooOldDisablesItWithTheReason() {
        for a in [LoginServiceStatus.notRegistered, .enabled, .requiresApproval] {
            let r = row(snap(agent: a, dozVersion: "0.50.7"))
            XCTAssertEqual(r?.title, "Start at Login — needs doz \(MenuBarApp.minimumDozForLogin)")
            XCTAssertEqual(r?.enabled, false)
            XCTAssertNil(r?.action)
        }
        XCTAssertEqual(row(snap(agent: .notRegistered, dozVersion: nil))?.action, .loginOn, "an unreadable version is never called old")
    }

    func testOutsideApplicationsItCannotBeTurnedOn() {
        let r = row(snap(agent: .notRegistered, stable: false))
        XCTAssertEqual(r?.title, "Start at Login — open the copy in Applications (doz app install)")
        XCTAssertEqual(r?.enabled, false)
        // Already on (an older registration): it can still be turned off from here.
        XCTAssertEqual(row(snap(agent: .enabled, stable: false))?.action, .loginOff)
    }

    func testBusyDisablesItAndTheRowSitsBetweenRestartAndTheDashboard() {
        XCTAssertEqual(row(snap(agent: .notRegistered, busy: .loginItem))?.enabled, false)
        XCTAssertEqual(MenuModel.header(for: snap(agent: .notRegistered, busy: .loginItem)), "Changing Start at Login…")
        let items = MenuModel.items(for: snap(agent: .notRegistered))
        let i = items.firstIndex { $0.action == .loginOn }!
        XCTAssertEqual(items[i - 2].action, .restart)
        XCTAssertEqual(items[i - 1].kind, .separator)
        XCTAssertEqual(items[i + 1].kind, .separator)
        XCTAssertEqual(items[i + 2].action, .dashboard)
    }

    func testNoDozNoRow() {
        let s = Snapshot(doz: .missing, login: LoginSnapshot(service: .none, stablePlace: true))
        XCTAssertNil(row(s))
    }

    func testLoginActionsRunNoDozCommandOfTheirOwn() {
        for a in [MenuAction.loginOn, .loginOff, .loginSettings] { XCTAssertNil(a.command) }
        XCTAssertEqual(MenuAction(rawValue: "login-on"), .loginOn)
        XCTAssertEqual(MenuAction(rawValue: "login-off"), .loginOff)
        XCTAssertEqual(DozCommand.loginItemOn.arguments, ["config", "set", "daemon.login_item", "on", "--json"])
        XCTAssertEqual(DozCommand.loginItemOff.arguments, ["config", "set", "daemon.login_item", "off", "--json"])
    }

    func testTheDumpCarriesTheLoginState() throws {
        let d = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(MenuDump(snap(agent: .requiresApproval, mainApp: .enabled)).json().utf8)) as? [String: Any])
        let li = try XCTUnwrap(d["loginItem"] as? [String: Any])
        XCTAssertEqual(li["agent"] as? String, "requiresApproval")
        XCTAssertEqual(li["mainApp"] as? String, "enabled")
        XCTAssertEqual(li["stablePlace"] as? Bool, true)
        let row = (d["items"] as? [[String: Any]])?.first { ($0["action"] as? String) == "login-settings" }
        XCTAssertEqual(row?["checked"] as? Bool, false)
    }

    // MARK: the flow

    /// A service that records and returns the state it is told to.
    final class FakeService: LoginItemService, @unchecked Sendable {
        var current = LoginServiceState.none
        var afterRegister = LoginServiceState(agent: .enabled, mainApp: .enabled)
        var registerError: String?
        var calls: [String] = []
        func state() -> LoginServiceState { current }
        func register() -> (lines: [String], error: String?) {
            calls.append("register")
            if registerError == nil { current = afterRegister }
            return (["registered"], registerError)
        }
        func unregister() -> (lines: [String], error: String?) { calls.append("unregister"); current = .none; return (["unregistered"], nil) }
        func openSystemSettings() -> [String] { calls.append("settings"); return ["opened"] }
    }

    /// A launchctl stand-in: `print` succeeds (exit 0) once `marker` exists.
    func look(loadedWhen marker: URL) throws -> LaunchdLook {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("look-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let p = dir.appendingPathComponent("launchctl").path
        try "#!/bin/sh\n[ \"$1\" = print ] && [ -e '\(marker.path)' ]\n".write(toFile: p, atomically: true, encoding: .utf8)
        chmod(p, 0o755)
        return LaunchdLook(program: p)
    }

    func testOnRegistersThenTellsDozOnlyOnceTheJobIsLoaded() throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("loaded-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: marker.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: marker) }
        let service = FakeService(), runner = FakeRunner()
        runner.answer(.loginItemOn, "{}")
        let o = LoginItemFlow.turnOn(service: service, look: try look(loadedWhen: marker), runner: runner, doz: doz, wait: 2)
        XCTAssertNil(o.error)
        XCTAssertEqual(service.calls, ["register"])
        XCTAssertEqual(runner.labels, ["config set daemon.login_item on"])
        XCTAssertEqual(o.steps.suffix(2), ["job loaded", "doz config set daemon.login_item on → exit 0"], "doz is told after the job is loaded")
    }

    func testOnWithTheJobNeverLoadedLeavesDozAlone() throws {
        let never = FileManager.default.temporaryDirectory.appendingPathComponent("never-\(UUID().uuidString)")
        let service = FakeService(), runner = FakeRunner()
        let o = LoginItemFlow.turnOn(service: service, look: try look(loadedWhen: never), runner: runner, doz: doz, wait: 0.3)
        XCTAssertNotNil(o.error)
        XCTAssertTrue(runner.labels.isEmpty, "never daemon.login_item on before launchd has the job — doz keeps its own")
        XCTAssertEqual(o.steps.last, "job not loaded")
    }

    func testOnThatNeedsApprovalStopsThere() throws {
        let service = FakeService(), runner = FakeRunner()
        service.afterRegister = LoginServiceState(agent: .requiresApproval, mainApp: .requiresApproval)
        let o = LoginItemFlow.turnOn(service: service, look: LaunchdLook(program: nil), runner: runner, doz: doz, wait: 0)
        XCTAssertTrue(o.needsApproval)
        XCTAssertTrue(runner.labels.isEmpty)
        service.registerError = "nope"
        service.current = .none
        let failed = LoginItemFlow.turnOn(service: service, look: LaunchdLook(program: nil), runner: runner, doz: doz, wait: 0)
        XCTAssertEqual(failed.error, "Could not turn on Start at Login: nope")
        XCTAssertTrue(runner.labels.isEmpty)
        XCTAssertNotNil(LoginItemFlow.turnOn(service: FakeService(), look: LaunchdLook(program: nil), runner: runner, doz: nil).error,
                        "no doz: nothing registered")
    }

    func testOffUnregistersThenTellsDoz() {
        let service = FakeService(), runner = FakeRunner()
        service.current = LoginServiceState(agent: .enabled, mainApp: .enabled)
        runner.answer(.loginItemOff, "{}")
        let o = LoginItemFlow.turnOff(service: service, runner: runner, doz: doz)
        XCTAssertNil(o.error)
        XCTAssertEqual(service.calls, ["unregister"])
        XCTAssertEqual(runner.labels, ["config set daemon.login_item off"])
    }

    // MARK: the recording service and the test-run rule

    func testTheRecordingServiceRecordsAndKeepsItsState() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let env = ["DOZ_TEST_LOGIN_ITEM_LOG": dir.appendingPathComponent("log").path, "DOZ_TEST_LOGIN_ITEM_STATE": dir.appendingPathComponent("state.json").path]
        let r = RecordingLoginItemService(env: env)
        XCTAssertEqual(r.state(), .none)
        _ = r.register()
        XCTAssertEqual(r.state(), LoginServiceState(agent: .enabled, mainApp: .enabled))
        XCTAssertEqual(RecordingLoginItemService(env: env).state().agent, .enabled, "another run of the app sees it")
        _ = r.unregister()
        XCTAssertEqual(r.state(), .none)
        let log = try String(contentsOf: dir.appendingPathComponent("log"), encoding: .utf8)
        XCTAssertEqual(log, "would register agent com.dozable.app.daemon\nwould register mainApp\nwould unregister agent com.dozable.app.daemon\nwould unregister mainApp\n")
        var approval = env; approval["DOZ_TEST_LOGIN_ITEM_RESULT"] = "requiresApproval"
        _ = RecordingLoginItemService(env: approval).register()
        XCTAssertTrue(r.state().needsApproval)
    }

    func testEveryTestRunIsKeptAwayFromSMAppServiceAndLaunchctl() {
        XCTAssertTrue(MenuBarSeams.testRun(["DOZ_TEST_GUARD": "1"]))
        XCTAssertTrue(MenuBarSeams.testRun(["DOZ_TEST_REAL_MAC": "1"]), "even a run that lifts the guard registers nothing")
        XCTAssertFalse(MenuBarSeams.testRun([:]))
        XCTAssertNil(LaunchdLook(env: ["DOZ_TEST_GUARD": "1"]).program, "no seam: launchd is not looked at")
        XCTAssertEqual(LaunchdLook(env: ["DOZ_TEST_REAL_MAC": "1", "DOZ_TEST_LAUNCHCTL": "/tmp/fake"]).program, "/tmp/fake")
        XCTAssertEqual(LaunchdLook(env: [:]).program, "/bin/launchctl")
        XCTAssertFalse(LaunchdLook(env: ["DOZ_TEST_GUARD": "1"]).loaded())
    }

    func testApplicationsIsTheOnePlaceToHoldIt() throws {
        XCTAssertTrue(LoginPlace.isStable(bundlePath: "/Applications/Dozable.app", env: [:], home: "/Users/x"))
        XCTAssertTrue(LoginPlace.isStable(bundlePath: "/Users/x/Applications/Dozable.app", env: [:], home: "/Users/x"))
        XCTAssertFalse(LoginPlace.isStable(bundlePath: "/Users/x/Downloads/Dozable.app", env: [:], home: "/Users/x"))
        XCTAssertFalse(LoginPlace.isStable(bundlePath: "/opt/homebrew/Cellar/doz/0.50.8/libexec/doz/Dozable.app", env: [:], home: "/Users/x"))
        XCTAssertFalse(LoginPlace.isStable(bundlePath: nil, env: [:]))
        XCTAssertFalse(LoginPlace.isStable(bundlePath: "/Applications/Dozable.app", env: ["DOZ_TEST_GUARD": "1"]), "a test run: the seam only")
        XCTAssertTrue(LoginPlace.isStable(bundlePath: "/tmp/apps/Dozable.app", env: ["DOZ_TEST_GUARD": "1", "DOZ_TEST_APPLICATIONS_DIR": "/tmp/apps"]))
    }
}
