import Foundation

/// The copy of this app on disk at a bundle's path: its Info.plist read again (an install swaps the bundle by rename, so
/// a running copy's own `Bundle.main` keeps the version it started with).
public enum AppOnDisk {
    public static func version(bundlePath: String) -> String? {
        let plist = (bundlePath as NSString).appendingPathComponent("Contents/Info.plist")
        guard let d = FileManager.default.contents(atPath: plist),
              let p = try? PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any] else { return nil }
        return p["CFBundleShortVersionString"] as? String
    }
}

/// Gathers a `Snapshot` by running doz, and runs the menu's actions. Used by the menu (on a background queue, one
/// command at a time) and by `--dump-menu` / `--run-action`.
///
/// Per refresh: the locator's `stat`s, then `doz daemon status --json`. `doz --version` and `doz app status --json` run
/// only when the doz file (or the VERSION beside it) is a different file than last time — a refresh after an upgrade sees
/// the new version at once, and the steady state costs one process.
public final class SnapshotSource: @unchecked Sendable {
    public let locator: DozLocator
    public let runner: CommandRunning
    public let appVersion: String?
    /// Start at Login: SMAppService (the recording one in a test run), launchd's look, and whether this copy may hold a
    /// login item where it runs. nil: the menu has no login row and the login actions do nothing.
    public let login: LoginContext?
    /// The version of the copy on disk at this app's own place (`AppOnDisk.version`; nil: not looked at).
    public let installedAppVersion: (@Sendable () -> String?)?
    /// Which app this is: the dev flavour refuses Start at Login and `doz app install`, whatever asks.
    public let flavour: MenuBarFlavour
    private let lock = NSLock()
    private var cache: (path: String, ids: [FileIdentity], version: String?, bundled: String?)?

    public struct LoginContext: Sendable {
        public var service: LoginItemService
        public var look: LaunchdLook
        public var stablePlace: Bool
        public var loadedWait: TimeInterval
        public init(service: LoginItemService, look: LaunchdLook, stablePlace: Bool, loadedWait: TimeInterval = LoginItemFlow.loadedWait) {
            self.service = service; self.look = look; self.stablePlace = stablePlace; self.loadedWait = loadedWait
        }
    }

    public init(locator: DozLocator, runner: CommandRunning, appVersion: String?, login: LoginContext? = nil,
                installedAppVersion: (@Sendable () -> String?)? = nil, flavour: MenuBarFlavour = .release) {
        self.locator = locator; self.runner = runner; self.appVersion = appVersion; self.login = login
        self.installedAppVersion = installedAppVersion; self.flavour = flavour
    }

    /// What the dev flavour answers an action it never takes.
    public static let devRefusal = "Updating the menu bar app is \(MenuBarFlavour.notInDev)"

    /// The login row's state (SMAppService's status is a local look — no process).
    func loginSnapshot() -> LoginSnapshot? {
        login.map { LoginSnapshot(service: $0.service.state(), stablePlace: $0.stablePlace) }
    }

    /// The menu's state now. `busy` and `lastError` are the caller's to fill.
    public func snapshot() -> Snapshot {
        let onDisk = installedAppVersion?()
        guard let doz = locator.locate() else {
            return Snapshot(doz: .missing, appVersion: appVersion, login: loginSnapshot(), installedAppVersion: onDisk, flavour: flavour)
        }
        let ids = FileIdentity.ofDoz(doz)
        let cached: (version: String?, bundled: String?)? = lock.withLock {
            guard let c = cache, c.path == doz, c.ids == ids, !ids.isEmpty else { return nil }
            return (c.version, c.bundled)
        }
        var version = cached?.version
        var bundled = cached?.bundled
        if cached == nil {
            let r = runner.run(.version, doz: doz)
            version = r.ok ? Self.parseVersion(r.stdout) : nil
            let a = runner.run(.appStatus, doz: doz)
            bundled = a.ok ? DozAppStatus.decode(a.stdout)?.bundled?.version : nil
            lock.withLock { cache = (doz, ids, version, bundled) }
        }
        var s = Snapshot(doz: .found(path: doz, version: version), appVersion: appVersion, bundledAppVersion: bundled, login: loginSnapshot(),
                         installedAppVersion: onDisk, flavour: flavour)
        let r = runner.run(.status, doz: doz)
        if r.timedOut { s.statusProblem = "doz did not answer within \(Int(DozCommand.status.timeout)) seconds" }
        else if r.exit != 0 { s.statusProblem = "doz daemon status failed (\(Self.failure(r)))" }
        else if let st = DozStatus.decode(r.stdout) { s.status = st }
        else { s.statusProblem = "doz's answer could not be read" }
        return s
    }

    /// Forget the cached version (the next snapshot asks doz again).
    public func invalidate() { lock.withLock { cache = nil } }

    /// Run `action`'s doz command. nil: done; else what to show (one line).
    public func perform(_ action: MenuAction) -> String? {
        switch action {
        case .loginOn, .loginOff, .loginSettings: return performLogin(action).error
        default: break
        }
        guard let command = action.command else { return nil }
        // `doz app install` puts an app in Applications: never from the dev build, even if something asks.
        if flavour.isDev, action == .updateApp { return Self.devRefusal }
        guard let doz = locator.locate() else { return "doz is not installed" }
        let r = runner.run(command, doz: doz)
        if r.ok { return nil }
        let what: String
        switch action {
        case .start: what = "Start failed"
        case .stop: what = "Stop failed"
        case .restart: what = "Restart failed"
        case .dashboard: what = "Could not open the dashboard"
        case .updateApp: what = "Could not update the menu bar app"
        case .installHelp, .quit, .loginOn, .loginOff, .loginSettings, .restartApp: what = "Failed"
        }
        if r.timedOut { return "\(what): doz did not finish within \(Int(command.timeout)) seconds" }
        // The dashboard's output is never read: only its exit status is known.
        if command.output == .capture, let m = Self.errorMessage(r.stdout) { return "\(what): \(m)" }
        return "\(what) (\(Self.failure(r)))"
    }

    /// Start at Login's clicks, step by step (`--run-action login-on|login-off` prints the steps).
    public func performLogin(_ action: MenuAction) -> LoginOutcome {
        // The dev flavour registers nothing with the system — refused before any step, any doz command.
        if flavour.isDev { return LoginOutcome(steps: [], error: RefusingLoginItemService.refusal, needsApproval: false) }
        guard let login else { return LoginOutcome(steps: [], error: "Start at Login is not available here", needsApproval: false) }
        switch action {
        case .loginOn:
            return LoginItemFlow.turnOn(service: login.service, look: login.look, runner: runner, doz: locator.locate(), wait: login.loadedWait)
        case .loginOff:
            return LoginItemFlow.turnOff(service: login.service, runner: runner, doz: locator.locate())
        case .loginSettings:
            return LoginOutcome(steps: login.service.openSystemSettings(), error: nil, needsApproval: true)
        default:
            return LoginOutcome(steps: [], error: nil, needsApproval: false)
        }
    }

    static func failure(_ r: CommandResult) -> String {
        if let e = r.launchError { return "could not run doz: \(e)" }
        return "exit \(r.exit.map(String.init) ?? "?")"
    }

    /// doz's `--version`: one version line.
    static func parseVersion(_ d: Data) -> String? {
        let t = String(decoding: d.prefix(200), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return DozVersion(t) != nil ? t : nil
    }

    /// doz's `--json` failure, `{"error": {"code", "message"}}`: its message, one line, at most 200 characters.
    static func errorMessage(_ d: Data) -> String? {
        struct E: Decodable { struct Inner: Decodable { var message: String? }; var error: Inner? }
        guard let m = (try? JSONDecoder().decode(E.self, from: d))?.error?.message else { return nil }
        let line = m.split(whereSeparator: \.isNewline).first.map(String.init) ?? m
        return line.count > 200 ? String(line.prefix(199)) + "…" : line
    }
}
