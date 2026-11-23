import XCTest
@testable import DozableMenuBarCore

/// The menu as a pure function of the snapshot: every state's header, lines, and which actions are enabled.
final class MenuModelTests: XCTestCase {
    let doz = "/opt/homebrew/bin/doz"

    func snap(_ status: DozStatus?, doz version: String? = "0.50.7", busy: Snapshot.Busy? = nil, problem: String? = nil,
              app: String? = "0.50.7", bundled: String? = "0.50.7", error: String? = nil) -> Snapshot {
        Snapshot(doz: .found(path: doz, version: version), status: status, statusProblem: problem, busy: busy, appVersion: app,
                 bundledAppVersion: bundled, lastError: error)
    }

    func item(_ items: [MenuItem], _ a: MenuAction) -> MenuItem? { items.first { $0.action == a } }
    func titles(_ items: [MenuItem]) -> [String] { items.filter { $0.kind != .separator }.map(\.title) }

    /// Install help opens THIS app's version of the manual's install page, never the version-less (stable) one.
    func testInstallHelpIsThisVersionsPage() {
        XCTAssertEqual(MenuBarApp.installHelpURL(appVersion: "0.52.50"), "https://dozable.com/v/0.52.50/docs/install-upgrade-uninstall.md")
        XCTAssertEqual(MenuBarApp.installHelpURL(appVersion: "0.53.0-canary.1"), "https://dozable.com/v/0.53.0-canary.1/docs/install-upgrade-uninstall.md")
        for bad in [nil, "", "0.52/../x", "0.52 x"] {
            XCTAssertEqual(MenuBarApp.installHelpURL(appVersion: bad), "https://dozable.com/", "\(String(describing: bad))")
        }
    }

    func testRunning() {
        let s = snap(Fixture.runningWith { $0["version"] = "0.50.7"; $0["alwaysOn"] = true })
        let items = MenuModel.items(for: s)
        XCTAssertEqual(items.first?.title, "Daemon running · 0.50.7")
        XCTAssertEqual(items.first?.kind, .header)
        XCTAssertFalse(items.first!.enabled)
        XCTAssertTrue(titles(items).contains("Always on · No sandboxes running"))
        XCTAssertEqual(item(items, .start)?.enabled, false)
        XCTAssertEqual(item(items, .stop)?.enabled, true)
        XCTAssertNil(item(items, .stop)?.confirm, "nothing running: Stop asks nothing")
        XCTAssertEqual(item(items, .restart)?.enabled, true)
        XCTAssertEqual(item(items, .dashboard)?.enabled, true)
        XCTAssertNil(item(items, .updateApp))
        XCTAssertNil(item(items, .installHelp))
        XCTAssertEqual(item(items, .quit)?.enabled, true)
        XCTAssertEqual(MenuModel.icon(for: s), "cube.fill")
    }

    func testStopAsksWhenSandboxesRun() {
        let one = MenuModel.items(for: snap(Fixture.runningWith { $0["version"] = "0.50.7"; $0["liveSandboxes"] = ["lab"] }))
        XCTAssertTrue(titles(one).contains("Stops when idle · 1 sandbox running"))
        let c1 = item(one, .stop)?.confirm
        XCTAssertEqual(c1?.title, "Stop the daemon?")
        XCTAssertEqual(c1?.message, "The running sandbox (lab) hibernates and wakes when you use it again. Sessions on this Mac keep running.")
        let two = MenuModel.items(for: snap(Fixture.runningWith { $0["version"] = "0.50.7"; $0["liveSandboxes"] = ["lab", "pi"] }))
        XCTAssertEqual(item(two, .stop)?.confirm?.message,
                       "The 2 running sandboxes (lab, pi) hibernate and wake when you use them again. Sessions on this Mac keep running.")
        XCTAssertTrue(titles(two).contains("Stops when idle · 2 sandboxes running"))
    }

    func testStopped() {
        let s = snap(Fixture.status(Fixture.noDaemon))
        let items = MenuModel.items(for: s)
        XCTAssertEqual(items.first?.title, "Daemon stopped")
        XCTAssertEqual(item(items, .start)?.enabled, true)
        XCTAssertEqual(item(items, .stop)?.enabled, false)
        XCTAssertEqual(item(items, .restart)?.enabled, false)
        XCTAssertEqual(item(items, .dashboard)?.enabled, true, "doz ui starts the daemon itself")
        XCTAssertEqual(MenuModel.icon(for: s), "cube")
    }

    func testHeld() {
        let held = Fixture.noDaemonWith { $0["held"] = true }
        XCTAssertEqual(MenuModel.header(for: snap(held)), "Daemon stopped until a doz command starts it")
        let heldWithItem = Fixture.noDaemonWith { o in
            o["held"] = true
            var li = o["loginItem"] as! [String: Any]; li["owner"] = "doz"; li["installed"] = true; o["loginItem"] = li
        }
        XCTAssertEqual(MenuModel.header(for: snap(heldWithItem)), "Daemon stopped until a doz command or your next login")
    }

    func testLockedOffersRestart() {
        let s = snap(Fixture.runningWith { $0["version"] = "0.50.7"; $0["keychainLocked"] = "ssh" })
        let items = MenuModel.items(for: s)
        XCTAssertEqual(items.first?.title, "Daemon started from ssh — it cannot read your Keychain")
        XCTAssertEqual(item(items, .restart)?.enabled, true)
        XCTAssertEqual(MenuModel.icon(for: s), "exclamationmark.triangle")
        let other = snap(Fixture.runningWith { $0["version"] = "0.50.7"; $0["keychainLocked"] = "no login session" })
        XCTAssertEqual(MenuModel.header(for: other), "Daemon started outside your login session — it cannot read your Keychain")
    }

    func testAnOlderBuildRunning() {
        // Its program replaced (an install) — or a doz of another version answering.
        let replaced = snap(Fixture.runningWith { $0["version"] = "0.50.7"; $0["executableChange"] = "replaced" })
        XCTAssertEqual(MenuModel.header(for: replaced), "Daemon runs an older build (0.50.7) — Restart to update")
        let upgraded = snap(Fixture.runningWith { $0["version"] = "0.50.4" }, doz: "0.50.7")
        XCTAssertEqual(MenuModel.header(for: upgraded), "Daemon runs an older build (0.50.4) — Restart to update")
        XCTAssertEqual(item(MenuModel.items(for: upgraded), .restart)?.enabled, true)
        let downgraded = snap(Fixture.runningWith { $0["version"] = "0.51.0" }, doz: "0.50.7")
        XCTAssertEqual(MenuModel.header(for: downgraded), "Daemon runs another build (0.51.0) — Restart to switch to 0.50.7")
    }

    func testNoDoz() {
        let s = Snapshot(doz: .missing, appVersion: "0.50.7")
        let items = MenuModel.items(for: s)
        XCTAssertEqual(items.first?.title, "doz is not installed")
        XCTAssertNil(item(items, .start))
        XCTAssertNil(item(items, .dashboard))
        XCTAssertEqual(item(items, .installHelp)?.enabled, true)
        XCTAssertEqual(item(items, .quit)?.enabled, true)
        XCTAssertEqual(MenuModel.icon(for: s), "cube.transparent")
    }

    func testDozTooOldStillOffersWhatWorks() {
        let s = snap(Fixture.status(Fixture.oldNoDaemon), doz: "0.50.3")
        let items = MenuModel.items(for: s)
        XCTAssertEqual(items.first?.title, "Daemon stopped")
        XCTAssertTrue(titles(items).contains("doz 0.50.3 is older than this app needs (0.50.5 or later) — upgrade doz"))
        XCTAssertEqual(item(items, .start)?.enabled, true)
        XCTAssertEqual(item(items, .dashboard)?.enabled, true)
        // The minimum itself, and later, say nothing.
        XCTAssertFalse(titles(MenuModel.items(for: snap(Fixture.status(Fixture.noDaemon), doz: "0.50.5"))).contains { $0.contains("older than this app") })
    }

    func testCannotRead() {
        let s = snap(nil, problem: "doz did not answer within 10 seconds")
        let items = MenuModel.items(for: s)
        XCTAssertEqual(items.first?.title, "Cannot read the daemon's state")
        XCTAssertTrue(titles(items).contains("doz did not answer within 10 seconds"))
        XCTAssertEqual(item(items, .start)?.enabled, true, "start is safe: it only starts one when none runs")
        XCTAssertEqual(MenuModel.icon(for: s), "exclamationmark.triangle")
    }

    func testBusyDisablesEveryActionButQuit() {
        for (busy, title) in [(Snapshot.Busy.starting, "Starting the daemon…"), (.stopping, "Stopping the daemon…"),
                              (.restarting, "Restarting the daemon…"), (.openingDashboard, "Opening the dashboard…"),
                              (.updatingApp, "Updating the menu bar app…")] {
            let items = MenuModel.items(for: snap(Fixture.runningWith { $0["version"] = "0.50.7" }, busy: busy, bundled: "0.51.0"))
            XCTAssertEqual(items.first?.title, title)
            for a in [MenuAction.start, .stop, .restart, .dashboard, .updateApp] { XCTAssertEqual(item(items, a)?.enabled, false, "\(a) while \(busy)") }
            XCTAssertEqual(item(items, .quit)?.enabled, true)
        }
    }

    func testNoLoginRowWhenTheLoginStateIsNotKnown() {
        let withItem = Fixture.runningWith { o in
            o["version"] = "0.50.8"
            var li = o["loginItem"] as! [String: Any]; li["owner"] = "doz"; li["installed"] = true; o["loginItem"] = li
        }
        let items = MenuModel.items(for: snap(withItem, doz: "0.50.8"))
        XCTAssertFalse(titles(items).contains { $0.contains("Start at Login") || $0.contains("login") },
                       "the row needs the login state (SMAppService's); without it there is none")
        XCTAssertNil(item(items, .loginOn))
    }

    func testUpdateMenuBarAppOnlyWhenTheBundledCopyIsNewer() {
        let st = Fixture.runningWith { $0["version"] = "0.51.0" }
        let newer = MenuModel.items(for: snap(st, doz: "0.51.0", app: "0.50.7", bundled: "0.51.0"))
        XCTAssertEqual(item(newer, .updateApp)?.title, "Update Menu Bar App (0.50.7 → 0.51.0)")
        XCTAssertEqual(item(newer, .updateApp)?.enabled, true)
        XCTAssertNil(item(MenuModel.items(for: snap(st, app: "0.51.0", bundled: "0.51.0")), .updateApp))
        XCTAssertNil(item(MenuModel.items(for: snap(st, app: "0.51.0", bundled: "0.50.7")), .updateApp), "never an older copy")
        XCTAssertNil(item(MenuModel.items(for: snap(st, app: nil, bundled: "0.51.0")), .updateApp), "a build outside a bundle")
    }

    /// The copy on disk is newer than this running one (an install swapped it in): "Restart to Update", which runs no doz
    /// command (the app reopens itself); it wins over "Update Menu Bar App".
    func testRestartToUpdateWhenTheCopyOnDiskIsNewer() {
        let st = Fixture.runningWith { $0["version"] = "0.51.0" }
        var s = snap(st, doz: "0.51.0", app: "0.50.7", bundled: "0.51.0")
        s.installedAppVersion = "0.51.0"
        let items = MenuModel.items(for: s)
        XCTAssertEqual(item(items, .restartApp)?.title, "Restart to Update (0.50.7 → 0.51.0)")
        XCTAssertEqual(item(items, .restartApp)?.enabled, true)
        XCTAssertNil(item(items, .updateApp), "the install is done: restarting is the update")
        XCTAssertNil(MenuAction.restartApp.command, "no doz command")
        s.installedAppVersion = "0.50.7"
        XCTAssertNil(item(MenuModel.items(for: s), .restartApp))
        XCTAssertNotNil(item(MenuModel.items(for: s), .updateApp), "the same copy on disk: the update item as before")
        s.installedAppVersion = nil
        XCTAssertNil(item(MenuModel.items(for: s), .restartApp))
        s.busy = .starting
        s.installedAppVersion = "0.51.0"
        XCTAssertEqual(item(MenuModel.items(for: s), .restartApp)?.enabled, false, "not while something runs")
    }

    func testTheCopyOnDiskIsReadFromItsInfoPlist() throws {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent("ondisk-\(UUID().uuidString)/Dozable.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": "0.51.10"], format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        XCTAssertEqual(AppOnDisk.version(bundlePath: app.path), "0.51.10")
        XCTAssertNil(AppOnDisk.version(bundlePath: app.deletingLastPathComponent().appendingPathComponent("none.app").path))
    }

    func testTheLastErrorIsShown() {
        let items = MenuModel.items(for: snap(Fixture.status(Fixture.noDaemon), error: "Start failed: the daemon did not start"))
        XCTAssertTrue(titles(items).contains("Start failed: the daemon did not start"))
    }

    func testQuitRunsNoDozCommandAndEveryOtherActionItsOwn() {
        XCTAssertNil(MenuAction.quit.command, "Quit quits this app only — never the daemon")
        XCTAssertNil(MenuAction.installHelp.command)
        XCTAssertEqual(MenuAction.start.command?.arguments, ["daemon", "start", "--json"])
        XCTAssertEqual(MenuAction.stop.command?.arguments, ["daemon", "stop", "--json"])
        XCTAssertEqual(MenuAction.restart.command?.arguments, ["daemon", "restart", "--json"])
        XCTAssertEqual(MenuAction.updateApp.command?.arguments, ["app", "install", "--open", "--json"])
    }

    func testTheDashboardLinkNeverPassesThroughTheApp() {
        let c = DozCommand.dashboard
        XCTAssertEqual(c.arguments, ["ui", "--detach", "--open", "-q"])
        XCTAssertFalse(c.arguments.contains("--print-url"))
        XCTAssertFalse(c.arguments.contains("--json"))
        XCTAssertEqual(c.output, .discard, "doz ui's output goes to /dev/null, never into the app")
    }

    /// No secret is ever shown: the model has no field for argv, the environment or a screen — a status carrying them
    /// (fields of a later doz) renders none of it.
    func testNoSecretIsEverShown() {
        let secret = "sk-ant-api03-SECRETSECRETSECRET"
        let st = Fixture.runningWith { o in
            o["version"] = "0.50.7"
            o["liveSandboxes"] = ["lab"]
            o["fencedSessions"] = ["claude --api-key \(secret)"]
            o["sessions"] = [["name": "a", "argv": ["claude", "--key", secret], "env": ["ANTHROPIC_API_KEY": secret], "screen": secret]]
            o["executableNote"] = "note"
        }
        let s = snap(st, error: nil)
        let dump = MenuDump(s).json()
        XCTAssertFalse(dump.contains(secret))
        XCTAssertFalse(dump.contains("sk-ant"))
        for i in MenuModel.items(for: s) {
            XCTAssertFalse(i.title.contains("sk-ant"))
            XCTAssertFalse(i.confirm?.message.contains("sk-ant") ?? false)
        }
    }

    func testTheDumpCarriesTheModel() throws {
        let s = snap(Fixture.runningWith { $0["version"] = "0.50.7" })
        let d = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(MenuDump(s).json().utf8)) as? [String: Any])
        XCTAssertEqual((d["doz"] as? [String: Any])?["version"] as? String, "0.50.7")
        XCTAssertEqual(d["running"] as? Bool, true)
        XCTAssertEqual(d["icon"] as? String, "cube.fill")
        XCTAssertEqual(((d["items"] as? [[String: Any]])?.first)?["title"] as? String, "Daemon running · 0.50.7")
    }
}
