import Foundation

/// The menu bar app's constants.
public enum MenuBarApp {
    public static let bundleIdentifier = "com.dozable.app"
    /// The oldest doz this app is made for: the first whose `doz daemon status --json` answers with no daemon running and
    /// carries `store`, `held`, `alwaysOn` and `loginItem`. An older doz still gets status, Start/Stop/Restart and the
    /// dashboard (all there since 0.50); the menu says it is older.
    public static let minimumDoz = "0.50.5"
    /// Where a person reads how to install doz (the manual's install page, as Markdown).
    public static let installHelpURL = "https://dozable.com/docs/install-upgrade-uninstall.md"
    /// The oldest doz Start at Login works with: the first that sees the app's SMAppService job as the owner of the login
    /// item (its program named relative to the bundle) and so removes its own — never two.
    public static let minimumDozForLogin = "0.50.8"
}

/// Everything the menu is drawn from — gathered by running doz, then handed to `MenuModel` (pure).
public struct Snapshot: Equatable, Sendable {
    public enum Doz: Equatable, Sendable {
        case missing
        /// Its path as found (a link kept unresolved) and what `doz --version` said (nil: unreadable).
        case found(path: String, version: String?)
    }

    public enum Busy: String, Equatable, Sendable, Encodable {
        case starting, stopping, restarting, openingDashboard, updatingApp, loginItem
    }

    public var doz: Doz
    /// `doz daemon status --json`, when it answered.
    public var status: DozStatus?
    /// Why the status could not be read (doz did not answer, or said something this app cannot read).
    public var statusProblem: String?
    /// An action under way.
    public var busy: Busy?
    /// This app's own version (the running copy's).
    public var appVersion: String?
    /// The copy of this app that came with doz (`doz app status --json`'s `bundled.version`).
    public var bundledAppVersion: String?
    /// The last action's failure, shown until the next action.
    public var lastError: String?
    /// Start at Login (nil: not known — no row is drawn).
    public var login: LoginSnapshot?

    public init(doz: Doz, status: DozStatus? = nil, statusProblem: String? = nil, busy: Busy? = nil, appVersion: String? = nil,
                bundledAppVersion: String? = nil, lastError: String? = nil, login: LoginSnapshot? = nil) {
        self.doz = doz; self.status = status; self.statusProblem = statusProblem; self.busy = busy; self.appVersion = appVersion
        self.bundledAppVersion = bundledAppVersion; self.lastError = lastError; self.login = login
    }

    public var dozPath: String? { if case .found(let p, _) = doz { return p }; return nil }
    public var dozVersion: String? { if case .found(_, let v) = doz { return v }; return nil }
}

/// What a menu item does when chosen. None of them runs anything but doz (and Quit runs nothing at all).
public enum MenuAction: String, Equatable, Sendable, Encodable {
    case start, stop, restart, dashboard, updateApp, installHelp, quit
    /// Start at Login: on (register the agent and the app, then tell doz), off, and — when macOS waits for the person —
    /// open System Settings › Login Items. None runs a doz command by itself (`LoginItemFlow`).
    case loginOn = "login-on", loginOff = "login-off", loginSettings = "login-settings"

    /// The doz command an action runs (nil: none — Quit quits this app only, never the daemon).
    public var command: DozCommand? {
        switch self {
        case .start: .start
        case .stop: .stop
        case .restart: .restart
        case .dashboard: .dashboard
        case .updateApp: .updateApp
        case .installHelp, .quit, .loginOn, .loginOff, .loginSettings: nil
        }
    }

    public var busy: Snapshot.Busy? {
        switch self {
        case .start: .starting
        case .stop: .stopping
        case .restart: .restarting
        case .dashboard: .openingDashboard
        case .updateApp: .updatingApp
        case .loginOn, .loginOff: .loginItem
        case .installHelp, .quit, .loginSettings: nil
        }
    }
}

/// A question asked before an action runs.
public struct Confirmation: Equatable, Sendable, Encodable {
    public var title: String
    public var message: String
    public var button: String
}

/// One line of the menu.
public struct MenuItem: Equatable, Sendable, Encodable {
    public enum Kind: String, Equatable, Sendable, Encodable { case header, line, action, separator }
    public var kind: Kind
    public var title: String
    public var enabled: Bool
    public var action: MenuAction?
    public var confirm: Confirmation?
    /// Drawn with a check mark (Start at Login when on).
    public var checked: Bool

    public static let separator = MenuItem(kind: .separator, title: "", enabled: false)

    public init(kind: Kind, title: String, enabled: Bool, action: MenuAction? = nil, confirm: Confirmation? = nil, checked: Bool = false) {
        self.kind = kind; self.title = title; self.enabled = enabled; self.action = action; self.confirm = confirm; self.checked = checked
    }

    static func line(_ s: String) -> MenuItem { MenuItem(kind: .line, title: s, enabled: false) }
}

/// The menu as a pure function of a `Snapshot` — what the AppKit layer draws, and what `--dump-menu` prints.
public enum MenuModel {
    /// The status item's icon (an SF Symbol name, drawn as a template): filled when the daemon runs, outlined when it is
    /// stopped, a warning when it needs a Restart or the state cannot be read, hollow when there is no doz.
    public static func icon(for s: Snapshot) -> String {
        guard case .found = s.doz else { return "cube.transparent" }
        if s.statusProblem != nil { return "exclamationmark.triangle" }
        guard let st = s.status else { return "cube" }
        if st.isRunning, needsRestart(s) != nil { return "exclamationmark.triangle" }
        return st.isRunning ? "cube.fill" : "cube"
    }

    /// Why the running daemon should be restarted (the header's words), or nil.
    static func needsRestart(_ s: Snapshot) -> String? {
        guard let st = s.status, st.isRunning else { return nil }
        if let why = st.keychainLocked {
            return why == "ssh" ? "Daemon started from ssh — it cannot read your Keychain"
                                : "Daemon started outside your login session — it cannot read your Keychain"
        }
        let v = st.version ?? "?"
        if st.executableChange != nil { return "Daemon runs an older build (\(v)) — Restart to update" }
        if let dv = s.dozVersion, let sv = st.version, dv != sv {
            return DozVersion.isOlder(dv, than: sv) ? "Daemon runs another build (\(sv)) — Restart to switch to \(dv)"
                                                    : "Daemon runs an older build (\(sv)) — Restart to update"
        }
        return nil
    }

    public static func header(for s: Snapshot) -> String {
        switch s.busy {
        case .starting?: return "Starting the daemon…"
        case .stopping?: return "Stopping the daemon…"
        case .restarting?: return "Restarting the daemon…"
        case .openingDashboard?: return "Opening the dashboard…"
        case .updatingApp?: return "Updating the menu bar app…"
        case .loginItem?: return "Changing Start at Login…"
        case nil: break
        }
        guard case .found = s.doz else { return "doz is not installed" }
        if s.statusProblem != nil { return "Cannot read the daemon's state" }
        guard let st = s.status else { return "Daemon state not read yet" }
        if st.isRunning { return needsRestart(s) ?? "Daemon running · \(st.version ?? s.dozVersion ?? "?")" }
        if st.held == true {
            let atLogin = st.loginItem?.installed == true || st.loginItem?.owner == "app"
            return "Daemon stopped until a doz command" + (atLogin ? " or your next login" : " starts it")
        }
        return "Daemon stopped"
    }

    public static func items(for s: Snapshot) -> [MenuItem] {
        var items: [MenuItem] = [MenuItem(kind: .header, title: header(for: s), enabled: false)]
        let found: Bool = { if case .found = s.doz { return true }; return false }()
        let idle = s.busy == nil
        let st = s.status
        let running = st?.isRunning == true

        if found, let v = s.dozVersion, DozVersion.isOlder(v, than: MenuBarApp.minimumDoz) {
            items.append(.line("doz \(v) is older than this app needs (\(MenuBarApp.minimumDoz) or later) — upgrade doz"))
        }
        if let p = s.statusProblem { items.append(.line(p)) }
        if running, let st {
            var parts: [String] = []
            if let a = st.alwaysOn { parts.append(a ? "Always on" : "Stops when idle") }
            let n = st.liveSandboxes?.count ?? 0
            parts.append(n == 0 ? "No sandboxes running" : n == 1 ? "1 sandbox running" : "\(n) sandboxes running")
            items.append(.line(parts.joined(separator: " · ")))
        }
        if let e = s.lastError { items.append(.line(e)) }

        items.append(.separator)
        if found {
            items.append(MenuItem(kind: .action, title: "Start Daemon", enabled: idle && !running, action: .start))
            let live = st?.liveSandboxes ?? []
            let confirm: Confirmation? = live.isEmpty ? nil : Confirmation(
                title: "Stop the daemon?",
                message: (live.count == 1 ? "The running sandbox (\(live[0])) hibernates and wakes when you use it again."
                                          : "The \(live.count) running sandboxes (\(live.joined(separator: ", "))) hibernate and wake when you use them again.")
                    + " Sessions on this Mac keep running.",
                button: "Stop Daemon")
            items.append(MenuItem(kind: .action, title: "Stop Daemon…", enabled: idle && running, action: .stop, confirm: confirm))
            items.append(MenuItem(kind: .action, title: "Restart Daemon", enabled: idle && running, action: .restart))
            if let login = loginItem(for: s) {
                items.append(.separator)
                items.append(login)
            }
            items.append(.separator)
            items.append(MenuItem(kind: .action, title: "Open Dashboard", enabled: idle, action: .dashboard))
            if let bundled = s.bundledAppVersion, let mine = s.appVersion, DozVersion.isOlder(mine, than: bundled) {
                items.append(MenuItem(kind: .action, title: "Update Menu Bar App (\(mine) → \(bundled))", enabled: idle, action: .updateApp))
            }
        } else {
            items.append(MenuItem(kind: .action, title: "How to Install doz…", enabled: true, action: .installHelp))
        }
        items.append(.separator)
        items.append(MenuItem(kind: .action, title: "Quit Dozable Menu", enabled: true, action: .quit))
        return items
    }
}

extension MenuModel {
    /// The Start at Login row (nil: no row — the login state is not known). In order:
    ///   · doz too old for it → disabled, "needs doz X";
    ///   · macOS waits for the person (switched off in System Settings) → "needs approval", opens that page;
    ///   · the app's agent enabled → "Start at Login" ✓ (a click turns it off);
    ///   · this copy is not in Applications → disabled, with where it must be (SMAppService keeps a stable path);
    ///   · doz holds its own login item → ✓ "(set by doz — click to let this app hold it)" (a click hands it over);
    ///   · else "Start at Login", unchecked.
    public static func loginItem(for s: Snapshot) -> MenuItem? {
        guard let login = s.login else { return nil }
        let idle = s.busy == nil
        let title = "Start at Login"
        if let v = s.dozVersion, DozVersion.isOlder(v, than: MenuBarApp.minimumDozForLogin) {
            return MenuItem(kind: .action, title: "\(title) — needs doz \(MenuBarApp.minimumDozForLogin)", enabled: false, action: nil)
        }
        if login.service.needsApproval {
            return MenuItem(kind: .action, title: "\(title) — needs approval: Open System Settings…", enabled: idle, action: .loginSettings)
        }
        if login.service.agent == .enabled {
            return MenuItem(kind: .action, title: title, enabled: idle, action: .loginOff, checked: true)
        }
        if !login.stablePlace {
            return MenuItem(kind: .action, title: "\(title) — open the copy in Applications (doz app install)", enabled: false, action: nil)
        }
        if let li = s.status?.loginItem, li.owner == "doz", li.installed == true {
            return MenuItem(kind: .action, title: "\(title) (set by doz — click to let this app hold it)", enabled: idle, action: .loginOn, checked: true)
        }
        return MenuItem(kind: .action, title: title, enabled: idle, action: .loginOn)
    }
}

/// What `--dump-menu` prints: the model, and what it was made from (doz's path and version, the daemon's state).
public struct MenuDump: Encodable, Sendable {
    public var doz: DozFound?
    public var running: Bool?
    public var daemonVersion: String?
    public var appVersion: String?
    public var icon: String
    public var items: [MenuItem]
    /// Start at Login as SMAppService reports it (nil: not looked at).
    public var loginItem: LoginDump?

    public struct LoginDump: Encodable, Sendable {
        public var agent: LoginServiceStatus
        public var mainApp: LoginServiceStatus
        public var stablePlace: Bool
    }

    public struct DozFound: Encodable, Sendable {
        public var path: String
        public var version: String?
    }

    public init(_ s: Snapshot) {
        if case .found(let p, let v) = s.doz { doz = DozFound(path: p, version: v) }
        running = s.status?.isRunning
        daemonVersion = s.status?.isRunning == true ? s.status?.version : nil
        appVersion = s.appVersion
        icon = MenuModel.icon(for: s)
        items = MenuModel.items(for: s)
        loginItem = s.login.map { LoginDump(agent: $0.service.agent, mainApp: $0.service.mainApp, stablePlace: $0.stablePlace) }
    }

    public func json() -> String {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? e.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}
