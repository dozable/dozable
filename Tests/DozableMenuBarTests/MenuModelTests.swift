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

    // MARK: workspaces (789)

    func wsSnap(_ list: [WorkspaceEntry]?, doz version: String? = "0.60.8", busy: Snapshot.Busy? = nil, busyWorkspace: String? = nil) -> Snapshot {
        var s = snap(Fixture.runningWith { $0["version"] = version ?? "0.60.8" }, doz: version)
        s.workspaces = list
        s.busy = busy
        s.busyWorkspace = busyWorkspace
        return s
    }
    func rows(_ items: [MenuItem]) -> [MenuItem] { items.filter { $0.submenu != nil } }

    /// Each state: its row in the dashboard's words, Open under it, and the one of Sleep and Wake its state offers.
    func testAWorkspaceRowPerState() {
        let table: [(String, String, MenuAction?)] = [
            ("waiting-on-you", "waiting on you", .sleepWorkspace), ("working", "working", .sleepWorkspace),
            ("starting", "starting", .sleepWorkspace), ("idle", "idle", .sleepWorkspace), ("setting-up", "setting up", nil),
            ("asleep", "asleep", .wakeWorkspace), ("stopped", "stopped", .wakeWorkspace), ("finished", "finished", nil),
            ("archived", "archived", nil),
        ]
        for (state, words, verb) in table {
            let items = MenuModel.items(for: wsSnap([WorkspaceEntry(name: "alpha", state: state)]))
            let row = rows(items)
            XCTAssertEqual(row.count, 1, state)
            XCTAssertEqual(row.first?.title, "alpha · \(words)", state)
            let under = row.first?.submenu ?? []
            XCTAssertEqual(under.first?.title, "Open", state)
            XCTAssertEqual(under.first?.action, .openWorkspace)
            XCTAssertEqual(under.first?.workspace, "alpha")
            let verbs = under.compactMap(\.action).filter { $0 == .sleepWorkspace || $0 == .wakeWorkspace }
            XCTAssertEqual(verbs, verb.map { [$0] } ?? [], state)
            if let v = verb {
                XCTAssertEqual(under.first { $0.action == v }?.title, v == .sleepWorkspace ? "Sleep" : "Wake", state)
                XCTAssertEqual(under.first { $0.action == v }?.workspace, "alpha")
            }
            XCTAssertEqual(item(items, .allWorkspaces)?.title, "All Workspaces…")
        }
    }

    /// The section sits after Open Dashboard and before Quit; everything above it is the menu as it was.
    func testTheSectionLeavesTheRestOfTheMenuAsItWas() {
        let without = MenuModel.items(for: wsSnap(nil))
        let with = MenuModel.items(for: wsSnap([WorkspaceEntry(name: "alpha", state: "idle")]))
        XCTAssertTrue(titles(without).allSatisfy { !$0.contains("Workspace") }, "no listing: no section")
        let head = Array(with.prefix(while: { $0.title != "Workspaces" }))
        XCTAssertEqual(head.dropLast().map(\.title), without.dropLast(2).map(\.title), "the items above the section are unchanged")
        XCTAssertEqual(with.last?.action, .quit)
        let ws = with.firstIndex { $0.title == "Workspaces" }!, dash = with.firstIndex { $0.action == .dashboard }!
        XCTAssertLessThan(dash, ws)
        XCTAssertEqual(with[ws].kind, .header)
    }

    /// Waiting on you first (the dashboard's order), then by name; the first ten, then All Workspaces….
    func testTheCapAndTheOrder() {
        var list = (1...12).map { WorkspaceEntry(name: String(format: "w%02d", $0), state: "idle") }
        list.append(WorkspaceEntry(name: "zz", state: "waiting-on-you"))
        list.append(WorkspaceEntry(name: "aa", state: "archived"))
        let items = MenuModel.items(for: wsSnap(list))
        let r = rows(items)
        XCTAssertEqual(r.count, MenuBarApp.workspaceCap)
        XCTAssertEqual(r.first?.title, "zz · waiting on you")
        XCTAssertEqual(r.dropFirst().map(\.workspace), (1...9).map { String(format: "w%02d", $0) })
        XCTAssertEqual(item(items, .allWorkspaces)?.enabled, true)
        XCTAssertEqual(MenuAction.allWorkspaces.command?.arguments, ["ui", "open", "--workspaces", "-q"])
    }

    func testNoWorkspacesYet() {
        let items = MenuModel.items(for: wsSnap([]))
        XCTAssertTrue(titles(items).contains("Workspaces"))
        XCTAssertTrue(titles(items).contains("No workspaces yet"))
        XCTAssertNil(item(items, .allWorkspaces))
        XCTAssertTrue(rows(items).isEmpty)
    }

    /// `workspace ls --json` carries no Needs you count: a workspace that waits on you says so in its state, with no number.
    func testWaitingOnYouIsTheStateWithNoCount() {
        let r = rows(MenuModel.items(for: wsSnap([WorkspaceEntry(name: "alpha", state: "waiting-on-you")])))
        XCTAssertEqual(r.first?.title, "alpha · waiting on you")
        XCTAssertNil(r.first?.title.rangeOfCharacter(from: .decimalDigits))
    }

    /// An older doz (no `doz ui open`), or one whose version cannot be read: no section, whatever the snapshot holds.
    func testAnOlderDozHasNoWorkspaceSection() {
        for v in ["0.60.7", "0.50.7", "0.60.8-canary.1", nil] as [String?] {
            let items = MenuModel.items(for: wsSnap([WorkspaceEntry(name: "alpha", state: "idle")], doz: v))
            XCTAssertFalse(titles(items).contains("Workspaces"), "\(v ?? "nil")")
            XCTAssertTrue(rows(items).isEmpty)
            XCTAssertNotNil(item(items, .dashboard), "the rest of the menu still works")
        }
        XCTAssertTrue(MenuBarApp.supportsWorkspaces("0.60.8"))
        XCTAssertTrue(MenuBarApp.supportsWorkspaces("0.61.0"))
    }

    func testABusyWorkspaceShowsTheDashboardsTransitionalWordAndDisablesItsActions() {
        let list = [WorkspaceEntry(name: "alpha", state: "idle"), WorkspaceEntry(name: "beta", state: "asleep")]
        let s = wsSnap(list, busy: .sleepingWorkspace, busyWorkspace: "alpha")
        let items = MenuModel.items(for: s)
        XCTAssertEqual(rows(items).map(\.title), ["alpha · sleeping…", "beta · asleep"])
        XCTAssertTrue(rows(items).flatMap { $0.submenu ?? [] }.filter { $0.kind == .action }.allSatisfy { !$0.enabled })
        XCTAssertEqual(item(items, .allWorkspaces)?.enabled, false)
        XCTAssertEqual(MenuModel.header(for: s), "Daemon running · 0.60.8", "the header stays the daemon's")
        let w = wsSnap(list, busy: .wakingWorkspace, busyWorkspace: "beta")
        XCTAssertEqual(rows(MenuModel.items(for: w)).map(\.title), ["alpha · idle", "beta · waking…"])
    }

    func testTheWorkspaceCommands() {
        XCTAssertEqual(MenuAction.openWorkspace.command(workspace: "alpha")?.arguments, ["ui", "open", "alpha", "-q"])
        XCTAssertEqual(MenuAction.openWorkspace.command(workspace: "alpha")?.output, .discard, "doz ui's output never reaches the app")
        XCTAssertEqual(MenuAction.sleepWorkspace.command(workspace: "alpha")?.arguments, ["workspace", "sleep", "alpha", "--json"])
        XCTAssertEqual(MenuAction.wakeWorkspace.command(workspace: "alpha")?.arguments, ["workspace", "wake", "alpha", "--json"])
        XCTAssertEqual(MenuAction.sleepWorkspace.command(workspace: "alpha")?.label, "workspace sleep", "the log names no workspace")
        for bad in [nil, "", "-q", "--all", "Alpha", "a b", String(repeating: "a", count: 41)] as [String?] {
            XCTAssertNil(MenuAction.openWorkspace.command(workspace: bad), "\(bad ?? "nil")")
            XCTAssertNil(MenuAction.sleepWorkspace.command(workspace: bad))
        }
        XCTAssertNil(MenuAction.openWorkspace.command, "a workspace's action needs its name")
        XCTAssertEqual(MenuAction.start.command(workspace: nil)?.arguments, ["daemon", "start", "--json"])
    }

    func testTheListingIsReadForNameAndStateOnly() {
        let json = #"{"workspaces":[{"name":"alpha","state":"waiting-on-you","driver":"you","agents":2,"later":{"x":1}},{"name":"-bad","state":"idle"},{"name":"nostate"},{"name":"beta","state":"asleep"}],"loose":[]}"#
        XCTAssertEqual(DozWorkspaceListing.decode(Data(json.utf8)),
                       [WorkspaceEntry(name: "alpha", state: "waiting-on-you"), WorkspaceEntry(name: "beta", state: "asleep")])
        XCTAssertEqual(DozWorkspaceListing.decode(Data(#"{"workspaces":[],"loose":[]}"#.utf8)), [])
        XCTAssertNil(DozWorkspaceListing.decode(Data(#"{"error":{"message":"x"}}"#.utf8)))
        XCTAssertNil(DozWorkspaceListing.decode(Data("garbage".utf8)))
    }

    func testTheDumpCarriesTheSubmenus() throws {
        let s = wsSnap([WorkspaceEntry(name: "alpha", state: "asleep")])
        let d = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(MenuDump(s).json().utf8)) as? [String: Any])
        let row = try XCTUnwrap((d["items"] as? [[String: Any]])?.first { $0["workspace"] as? String == "alpha" && $0["submenu"] != nil })
        let under = try XCTUnwrap(row["submenu"] as? [[String: Any]])
        XCTAssertEqual(under.compactMap { $0["action"] as? String }, ["open-workspace", "wake-workspace"])
    }
}
