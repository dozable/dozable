import XCTest
@testable import DozableHost

/// 694: the daemon's login item — the plist's exact keys (round-tripped through PropertyListSerialization), the label, the
/// install rule (setting × always on × kept × an app's job × mode), sync and status against a scratch folder and a fake
/// launchctl (a closure: nothing is run), and only this store's label ever removed.
final class DaemonLoginItemTests: XCTestCase {
    var root: URL!
    var agents: URL!
    let store = DozableStore(root: URL(fileURLWithPath: "/tmp/doz-li--store"))

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("doz-li-\(UUID().uuidString.prefix(8))")
        agents = root.appendingPathComponent("LaunchAgents")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func plist(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(try PropertyListSerialization.propertyList(from: Data(text.utf8), format: nil) as? [String: Any])
    }

    func testTheLabelIsTheStoresSocketHash() {
        let l = DaemonLoginItem.label(store)
        XCTAssertTrue(l.hasPrefix("com.dozable.daemon."))
        XCTAssertEqual(l.count, "com.dozable.daemon.".count + 8)
        XCTAssertTrue(MacPlace.socketDirectory(store: store, temp: "/t/").hasSuffix(String(l.suffix(8))), "the same 8 hex as the socket folder")
        XCTAssertNotEqual(l, DaemonLoginItem.label(DozableStore(root: URL(fileURLWithPath: "/tmp/other-store"))))
        XCTAssertNotEqual(l, DaemonLoginItem.appLabel)
    }

    func testThePlistHasExactlyTheKeysOfTheDesign() throws {
        let text = DaemonLoginItem.render(store: store, program: "/opt/homebrew/opt/doz/libexec/doz/doz", xdgConfigHome: nil)
        let p = try plist(text)
        XCTAssertEqual(Set(p.keys), ["Label", "ProgramArguments", "RunAtLoad", "StartInterval", "LimitLoadToSessionType", "AbandonProcessGroup",
                                     "ProcessType", "StandardOutPath", "StandardErrorPath"])
        XCTAssertEqual(p["Label"] as? String, DaemonLoginItem.label(store))
        XCTAssertEqual(p["ProgramArguments"] as? [String],
                       ["/opt/homebrew/opt/doz/libexec/doz/doz", "daemon", "start", "--login-item", "--store", "/tmp/doz-li--store"],
                       "doz itself (the stable path), never a shell")
        XCTAssertEqual(p["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(p["StartInterval"] as? Int, 900)
        XCTAssertEqual(p["LimitLoadToSessionType"] as? String, "Aqua")
        XCTAssertEqual(p["AbandonProcessGroup"] as? Bool, true)
        XCTAssertEqual(p["ProcessType"] as? String, "Standard")
        XCTAssertEqual(p["StandardOutPath"] as? String, "/tmp/doz-li--store/login-item.log")
        XCTAssertEqual(p["StandardErrorPath"] as? String, "/tmp/doz-li--store/login-item.log")
        for never in ["KeepAlive", "Sockets", "MachServices", "Program", "EnvironmentVariables"] { XCTAssertNil(p[never], never) }
        XCTAssertTrue(text.contains("<!-- Dozable: starts the doz daemon for the store /tmp/doz-li- -store"),
                      "the comment names the store (its dashes broken up: a comment may not hold two)")
        XCTAssertTrue(text.contains("doz daemon login-item off"), "and how to remove it")
        XCTAssertFalse(text.components(separatedBy: "<!--")[1].components(separatedBy: "-->")[0].contains("--"))
    }

    func testXDGOnlyWhenSetAndNotTheDefault() throws {
        let p = try plist(DaemonLoginItem.render(store: store, program: "/x/doz", xdgConfigHome: "/tmp/xdg & co"))
        XCTAssertEqual((p["EnvironmentVariables"] as? [String: String]), ["XDG_CONFIG_HOME": "/tmp/xdg & co"], "escaped and read back whole")
        XCTAssertNil(DaemonLoginItem.xdgForPlist([:]))
        XCTAssertNil(DaemonLoginItem.xdgForPlist(["XDG_CONFIG_HOME": ""]))
        XCTAssertNil(DaemonLoginItem.xdgForPlist(["XDG_CONFIG_HOME": TestSafety.realHome.appendingPathComponent(".config").path]))
        XCTAssertEqual(DaemonLoginItem.xdgForPlist(["XDG_CONFIG_HOME": "/tmp/x"]), "/tmp/x")
    }

    /// The install rule: login_item × always_on × kept × an app's job × installed/stale/loaded × mode.
    func testTheSyncTable() {
        func a(_ setting: String, on: Bool = true, kept: Int = 0, app: Bool = false, installed: Bool = false, stale: Bool = false,
               loaded: Bool = false, _ mode: DaemonLoginItem.Mode = .command) -> DaemonLoginItem.Action {
            DaemonLoginItem.decide(setting: setting, alwaysOn: on, keepers: kept, appOwned: app, installed: installed, stale: stale, loaded: loaded, mode: mode).action
        }
        // Consent: only `on` ever installs; ask and off never do.
        XCTAssertEqual(a("on"), .install)
        XCTAssertEqual(a("ask"), .none)
        XCTAssertEqual(a("off"), .none)
        XCTAssertEqual(a("ask", installed: true), .remove, "present ⇔ on")
        XCTAssertEqual(a("off", installed: true, loaded: true), .remove)
        // always_on off: only a kept session keeps it.
        XCTAssertEqual(a("on", on: false, installed: true), .remove)
        XCTAssertEqual(a("on", on: false), .none)
        XCTAssertEqual(a("on", on: false, kept: 1), .install)
        XCTAssertEqual(a("on", on: false, kept: 2, installed: true, loaded: true), .none, "kept: it stays")
        // The menu bar app's job: doz removes its own and never writes one.
        XCTAssertEqual(a("on", app: true), .none)
        XCTAssertEqual(a("on", app: true, installed: true, loaded: true), .remove)
        // Present: rewritten when stale, loaded when not loaded (a command), left otherwise.
        XCTAssertEqual(a("on", installed: true, stale: true, loaded: true), .rewrite)
        XCTAssertEqual(a("on", installed: true, loaded: false), .load)
        XCTAssertEqual(a("on", installed: true, loaded: true), .none)
        // A daemon's start: never installs, never loads; rewrites a stale path; removes.
        XCTAssertEqual(a("on", .daemonStart), .none)
        XCTAssertEqual(a("on", installed: true, loaded: false, .daemonStart), .none)
        XCTAssertEqual(a("on", installed: true, stale: true, .daemonStart), .rewrite)
        XCTAssertEqual(a("off", installed: true, .daemonStart), .remove)
        XCTAssertEqual(a("on", app: true, installed: true, .daemonStart), .remove)
        // The reasons a person reads.
        XCTAssertEqual(DaemonLoginItem.decide(setting: "on", alwaysOn: true, keepers: 0, appOwned: true, installed: false, stale: false,
                                              loaded: false, mode: .command).reason, "the Dozable menu bar app starts the daemon at login")
        XCTAssertTrue(DaemonLoginItem.decide(setting: "on", alwaysOn: false, keepers: 0, appOwned: false, installed: true, stale: false,
                                             loaded: true, mode: .command).reason.contains("daemon.always_on is off"))
    }

    /// A fake launchd: a dictionary of loaded labels → plist paths, apps → program, and every argv recorded.
    final class FakeLaunchd: @unchecked Sendable {
        let lock = NSLock()
        var loaded: [String: String] = [:]
        var apps: [String: String] = [:]
        /// `print`'s whole answer for a label (an SMAppService job's shape).
        var prints: [String: String] = [:]
        var disabled: Set<String> = []
        var calls: [[String]] = []
        var refuseBootstrap = false

        var launchctl: Launchctl {
            Launchctl(uid: 501) { [self] argv in
                lock.withLock {
                    calls.append(argv)
                    let label = argv.count > 1 ? argv[1].split(separator: "/").dropFirst(2).joined(separator: "/") : ""
                    switch argv.first {
                    case "bootstrap":
                        if refuseBootstrap { return .init(code: 5, output: "Bootstrap failed: 5: Input/output error\n") }
                        let p = (try? PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: argv[2])), format: nil)) as? [String: Any]
                        loaded[p?["Label"] as? String ?? "?"] = argv[2]
                        return .init(code: 0, output: "")
                    case "bootout":
                        return loaded.removeValue(forKey: label) != nil ? .init(code: 0, output: "") : .init(code: 113, output: "")
                    case "print":
                        if let path = loaded[label] { return .init(code: 0, output: "x = {\n\tpath = \(path)\n}\n") }
                        if let prog = apps[label] { return .init(code: 0, output: "x = {\n\tprogram = \(prog)\n}\n") }
                        if let raw = prints[label] { return .init(code: 0, output: raw) }
                        return .init(code: 113, output: "Could not find service")
                    case "print-disabled":
                        return .init(code: 0, output: "disabled services = {\n" + disabled.map { "\t\"\($0)\" => disabled\n" }.joined() + "}\n")
                    default:
                        return .init(code: 0, output: "")
                    }
                }
            }
        }
    }

    func settings(_ values: [String: TOMLValue]) throws -> DozableSettings {
        let xdg = root.appendingPathComponent("xdg")
        var s = DozableSettings.load(environment: ["XDG_CONFIG_HOME": xdg.path])
        for (k, v) in values { s = try s.writing(k, v) }
        return s
    }

    func testOnInstallsLoadsAndOffRemovesOnlyThisLabel() throws {
        let fake = FakeLaunchd()
        let program = root.appendingPathComponent("doz").path
        FileManager.default.createFile(atPath: program, contents: Data(), attributes: [.posixPermissions: 0o755])
        // Another store's item and an unrelated agent beside it: never touched.
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        let other = agents.appendingPathComponent("com.dozable.daemon.deadbeef.plist")
        let unrelated = agents.appendingPathComponent("com.example.thing.plist")
        try Data("other".utf8).write(to: other)
        try Data("unrelated".utf8).write(to: unrelated)

        var s = try settings([SettingKey.loginItem: .string("ask"), SettingKey.alwaysOn: .bool(true)])
        var r = DaemonLoginItem.sync(store: store, mode: .command, settings: s, launchctl: fake.launchctl, folder: agents, program: program, environment: [:])
        XCTAssertEqual(r.decision.action, .none, "ask writes nothing")
        XCTAssertFalse(FileManager.default.fileExists(atPath: DaemonLoginItem.plistURL(store, folder: agents).path))

        s = try settings([SettingKey.loginItem: .string("on"), SettingKey.alwaysOn: .bool(true)])
        r = DaemonLoginItem.sync(store: store, mode: .command, settings: s, launchctl: fake.launchctl, folder: agents, program: program, environment: [:])
        let url = DaemonLoginItem.plistURL(store, folder: agents)
        XCTAssertEqual(r.decision.action, .install)
        XCTAssertEqual(r.loaded, true)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o644)
        XCTAssertEqual(DaemonLoginItem.installedArguments(url)?.first, program)
        XCTAssertTrue(fake.calls.contains(["bootstrap", "gui/501", url.path]))
        XCTAssertTrue(r.line.contains("Background Items Added"))

        var st = DaemonLoginItem.status(store: store, settings: s, launchctl: fake.launchctl, folder: agents, program: program)
        XCTAssertEqual(st.owner, "doz")
        XCTAssertTrue(st.installed && st.loaded && st.wanted && !st.stale)
        XCTAssertEqual(st.disabled, nil)
        fake.lock.withLock { _ = fake.disabled.insert(DaemonLoginItem.label(store)) }
        st = DaemonLoginItem.status(store: store, settings: s, launchctl: fake.launchctl, folder: agents, program: program)
        XCTAssertEqual(st.disabled, true, "switched off in System Settings")
        XCTAssertTrue(st.line.contains("SWITCHED OFF"))

        // Stale: another program path — rewritten (bootout, write, bootstrap).
        let st2 = DaemonLoginItem.status(store: store, settings: s, launchctl: fake.launchctl, folder: agents, program: "/elsewhere/doz")
        XCTAssertTrue(st2.stale)
        r = DaemonLoginItem.sync(store: store, mode: .daemonStart, settings: s, launchctl: fake.launchctl, folder: agents, program: program + "2", environment: [:])
        XCTAssertEqual(r.decision.action, .rewrite)
        XCTAssertEqual(DaemonLoginItem.installedArguments(url)?.first, program + "2")

        // off: removed (bootout, unlink) — only this label.
        s = try settings([SettingKey.loginItem: .string("off")])
        r = DaemonLoginItem.sync(store: store, mode: .command, settings: s, launchctl: fake.launchctl, folder: agents, program: program, environment: [:])
        XCTAssertEqual(r.decision.action, .remove)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(fake.calls.contains(["bootout", "gui/501/\(DaemonLoginItem.label(store))"]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path) && FileManager.default.fileExists(atPath: unrelated.path))
        XCTAssertEqual(DaemonLoginItem.otherItems(store, folder: agents), [other])
        XCTAssertFalse(fake.calls.contains { $0.contains { $0.contains("deadbeef") } }, "another store's label is never named to launchd")
    }

    func testFromSshTheFileIsStillWrittenAndLoadsAtTheNextLogin() throws {
        let fake = FakeLaunchd()
        fake.refuseBootstrap = true
        let s = try settings([SettingKey.loginItem: .string("on"), SettingKey.alwaysOn: .bool(true)])
        let r = DaemonLoginItem.sync(store: store, mode: .command, settings: s, launchctl: fake.launchctl, folder: agents, program: "/x/doz", environment: [:])
        XCTAssertEqual(r.decision.action, .install)
        XCTAssertEqual(r.loaded, false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: DaemonLoginItem.plistURL(store, folder: agents).path))
        XCTAssertTrue(r.line.contains("it loads at your next login"))
    }

    func testADaemonStartNeverInstallsAndLooksAtNothingWithoutAPlist() throws {
        let fake = FakeLaunchd()
        let s = try settings([SettingKey.loginItem: .string("on"), SettingKey.alwaysOn: .bool(true)])
        let r = DaemonLoginItem.sync(store: store, mode: .daemonStart, settings: s, launchctl: fake.launchctl, folder: agents, program: "/x/doz", environment: [:])
        XCTAssertEqual(r.decision.action, .none)
        XCTAssertFalse(FileManager.default.fileExists(atPath: agents.path), "nothing written, not even the folder")
        XCTAssertTrue(fake.calls.isEmpty, "not even a look at launchd")
    }

    func testAnAppsJobWinsAndOneWhoseProgramIsGoneCountsAsAbsent() throws {
        let fake = FakeLaunchd()
        let appProgram = root.appendingPathComponent("Dozable.app-doz")
        FileManager.default.createFile(atPath: appProgram.path, contents: Data(), attributes: [.posixPermissions: 0o755])
        fake.apps[DaemonLoginItem.appLabel] = appProgram.path
        let s = try settings([SettingKey.loginItem: .string("on"), SettingKey.alwaysOn: .bool(true)])
        // doz's own, there from before: removed, and never written again while the app's job is loaded.
        try DaemonLoginItem.write(DaemonLoginItem.render(store: store, program: "/x/doz", xdgConfigHome: nil), to: DaemonLoginItem.plistURL(store, folder: agents))
        var r = DaemonLoginItem.sync(store: store, mode: .command, settings: s, launchctl: fake.launchctl, folder: agents, program: "/x/doz", environment: [:])
        XCTAssertEqual(r.decision.action, .remove)
        r = DaemonLoginItem.sync(store: store, mode: .command, settings: s, launchctl: fake.launchctl, folder: agents, program: "/x/doz", environment: [:])
        XCTAssertEqual(r.decision.action, .none)
        XCTAssertFalse(FileManager.default.fileExists(atPath: DaemonLoginItem.plistURL(store, folder: agents).path))
        XCTAssertEqual(DaemonLoginItem.status(store: store, settings: s, launchctl: fake.launchctl, folder: agents, program: "/x/doz").owner, "app")
        // The app deleted: its job's program is gone — absent; doz adds its own again.
        try FileManager.default.removeItem(at: appProgram)
        r = DaemonLoginItem.sync(store: store, mode: .command, settings: s, launchctl: fake.launchctl, folder: agents, program: "/x/doz", environment: [:])
        XCTAssertEqual(r.decision.action, .install)
    }

    /// What `launchctl print` says of an SMAppService agent with a BundleProgram: no absolute program — `arguments` start
    /// with the bare `Dozable`, or nothing names one (`path = (submitted by smd.N)`). Read on this Mac from other apps'
    /// SMAppService jobs (`launchctl dumpstate`); the exact shape of Dozable's own is checked on the test Mac.
    static let smappPrint = """
    gui/501/com.dozable.app.daemon = {
    	active count = 0
    	path = (submitted by smd.552)
    	type = Submitted
    	managed_by = com.apple.xpc.ServiceManagement
    	state = not running

    	program identifier = Contents/MacOS/Dozable (mode: 2)
    	parent bundle identifier = com.dozable.app
    	arguments = {
    		Dozable
    		--launch-daemon
    	}
    }

    """

    func installApp(in place: URL, identifier: String = "com.dozable.app") throws -> URL {
        let app = place.appendingPathComponent("Dozable.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        let info = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": identifier], format: .xml, options: 0)
        try info.write(to: app.appendingPathComponent("Contents/Info.plist"))
        FileManager.default.createFile(atPath: app.appendingPathComponent("Contents/MacOS/Dozable").path, contents: Data(), attributes: [.posixPermissions: 0o755])
        return app
    }

    /// The decision-13 refinement: the app's SMAppService job (its program relative to its bundle) counts while an
    /// installed copy of the app is there — doz removes its own and says the app owns it — and as ABSENT once the app is
    /// gone (deleted without unregistering), so `doz daemon login-item on` adds doz's own again.
    func testAnSMAppServiceJobCountsWhileTheAppIsInstalled() throws {
        let fake = FakeLaunchd()
        fake.prints[DaemonLoginItem.appLabel] = Self.smappPrint
        let apps = root.appendingPathComponent("Applications")
        let s = try settings([SettingKey.loginItem: .string("on"), SettingKey.alwaysOn: .bool(true)])
        let app = try installApp(in: apps)
        XCTAssertEqual(DaemonLoginItem.appJob(fake.launchctl, appPlaces: [apps]).loaded, true)
        try DaemonLoginItem.write(DaemonLoginItem.render(store: store, program: "/x/doz", xdgConfigHome: nil), to: DaemonLoginItem.plistURL(store, folder: agents))
        var r = DaemonLoginItem.sync(store: store, mode: .command, settings: s, launchctl: fake.launchctl, folder: agents, program: "/x/doz",
                                     appPlaces: [apps], environment: [:])
        XCTAssertEqual(r.decision.action, .remove, "the app holds it: doz's own goes — never two")
        let st = DaemonLoginItem.status(store: store, settings: s, launchctl: fake.launchctl, folder: agents, program: "/x/doz", appPlaces: [apps])
        XCTAssertEqual(st.owner, "app")
        XCTAssertTrue(st.note?.contains(app.appendingPathComponent("Contents/MacOS/Dozable").path) == true, st.note ?? "")
        // Another app's bundle by that name is not Dozable's.
        try FileManager.default.removeItem(at: app)
        _ = try installApp(in: apps, identifier: "com.example.other")
        XCTAssertEqual(DaemonLoginItem.appJob(fake.launchctl, appPlaces: [apps]).loaded, false)
        // The app deleted: absent; doz adds its own again.
        try FileManager.default.removeItem(at: apps)
        XCTAssertEqual(DaemonLoginItem.appJob(fake.launchctl, appPlaces: [apps]).loaded, false)
        r = DaemonLoginItem.sync(store: store, mode: .command, settings: s, launchctl: fake.launchctl, folder: agents, program: "/x/doz",
                                 appPlaces: [apps], environment: [:])
        XCTAssertEqual(r.decision.action, .install)
        // No print at all for the label: no job.
        fake.prints = [:]
        XCTAssertEqual(DaemonLoginItem.appJob(fake.launchctl, appPlaces: [apps]).loaded, false)
    }

    /// When `print` names the plist inside a bundle, that bundle's executable decides.
    func testAPlistPathInsideABundleDecides() throws {
        let fake = FakeLaunchd()
        let app = try installApp(in: root.appendingPathComponent("Elsewhere"))
        let plistPath = app.appendingPathComponent("Contents/Library/LaunchAgents/com.dozable.app.daemon.plist").path
        fake.prints[DaemonLoginItem.appLabel] = "x = {\n\tpath = \(plistPath)\n\targuments = {\n\t\tDozable\n\t}\n}\n"
        XCTAssertEqual(Launchctl.parsePath(fake.prints[DaemonLoginItem.appLabel]!), plistPath)
        XCTAssertNil(Launchctl.parsePath(Self.smappPrint), "(submitted by …) is not a path")
        XCTAssertEqual(DaemonLoginItem.appJob(fake.launchctl, appPlaces: []).loaded, true)
        try FileManager.default.removeItem(at: app)
        XCTAssertEqual(DaemonLoginItem.appJob(fake.launchctl, appPlaces: []).loaded, false)
    }

    /// The menu bar app's agent plist (Resources/MenuBar, sealed into the bundle) carries doz's reserved label.
    func testTheAppsAgentPlistCarriesDozsReservedLabel() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let d = try Data(contentsOf: repo.appendingPathComponent("Resources/MenuBar/com.dozable.app.daemon.plist"))
        let p = try XCTUnwrap(try PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any])
        XCTAssertEqual(p["Label"] as? String, DaemonLoginItem.appLabel)
        XCTAssertEqual(p["ProgramArguments"] as? [String], ["Dozable", "--launch-daemon"])
        XCTAssertNil(p["KeepAlive"])
        XCTAssertEqual(p["StartInterval"] as? Int, DaemonLoginItem.startInterval, "the same 15-minute look as doz's own")
    }

    func testTheAppsInstallPlaces() {
        let home = URL(fileURLWithPath: "/Users/someone")
        XCTAssertEqual(MenuBarAppPlaces.lookPlaces(env: [:], guarded: false, home: home).map(\.path), ["/Applications", "/Users/someone/Applications"])
        XCTAssertEqual(MenuBarAppPlaces.lookPlaces(env: [:], guarded: true, home: home), [])
        XCTAssertEqual(MenuBarAppPlaces.lookPlaces(env: ["DOZ_TEST_GUARD": "1", "DOZ_TEST_APPLICATIONS_DIR": "/tmp/a"], home: home).map(\.path), ["/tmp/a"])
    }

    func testRemoveTouchesOnlyThisStoresLabel() throws {
        let fake = FakeLaunchd()
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        let other = agents.appendingPathComponent("com.dozable.daemon.0badf00d.plist")
        try Data("x".utf8).write(to: other)
        XCTAssertFalse(DaemonLoginItem.remove(store: store, launchctl: fake.launchctl, folder: agents), "none here: nothing removed")
        try DaemonLoginItem.write(DaemonLoginItem.render(store: store, program: "/x/doz", xdgConfigHome: nil), to: DaemonLoginItem.plistURL(store, folder: agents))
        XCTAssertTrue(DaemonLoginItem.remove(store: store, launchctl: fake.launchctl, folder: agents))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
    }

    func testStatusInAGuardedRunWithoutSeamsLooksAtNothing() throws {
        let s = try settings([SettingKey.loginItem: .string("on")])
        let st = DaemonLoginItem.status(store: store, settings: s, launchctl: nil, folder: nil)
        XCTAssertFalse(st.installed)
        XCTAssertTrue(st.note?.hasPrefix("not looked at") == true)
        XCTAssertNil(LaunchAgentsFolder.forLooking(environment: ["DOZ_TEST_GUARD": "1"]))
        XCTAssertNil(Launchctl.forLooking(environment: ["DOZ_TEST_GUARD": "1"]))
    }

    func testTheSettingHasNoEnvironmentVariable() throws {
        let d = try XCTUnwrap(DozableSettings.definition(SettingKey.loginItem))
        XCTAssertNil(d.environment, "consent is never an environment value")
        XCTAssertEqual(d.defaultValue, .string("ask"))
        XCTAssertEqual(d.type, .choice(["ask", "on", "off"]))
        XCTAssertTrue(DozableSettings.definition(SettingKey.loginItem)?.summary.contains("when you log in") == true, "700: always_on's text names its neighbour the timeout; login_item says the log-in part")
    }
}
