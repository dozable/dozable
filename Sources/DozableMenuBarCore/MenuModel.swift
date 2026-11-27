import Foundation

/// The menu bar app's constants.
public enum MenuBarApp {
    public static let bundleIdentifier = "com.dozable.app"
    /// The oldest doz this app is made for: the first whose `doz daemon status --json` answers with no daemon running and
    /// carries `store`, `held`, `alwaysOn` and `loginItem`. An older doz still gets status, Start/Stop/Restart and the
    /// dashboard (all there since 0.50); the menu says it is older.
    public static let minimumDoz = "0.50.5"
    /// Where a person reads how to install doz: the manual's install page, as Markdown, of THIS app's version
    /// (`https://dozable.com/v/X.Y.Z/docs/…`) — never the version-less page, which is the stable release's. Only an app
    /// that cannot read its own version (it always can, from its Info.plist) falls back to the home page.
    public static func installHelpURL(appVersion: String?) -> String {
        guard let v = appVersion, !v.isEmpty, v.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || ".+-".contains($0)) }) else {
            return "https://dozable.com/"
        }
        return "https://dozable.com/v/\(v)/docs/install-upgrade-uninstall.md"
    }
    /// The oldest doz Start at Login works with: the first that sees the app's SMAppService job as the owner of the login
    /// item (its program named relative to the bundle) and so removes its own — never two.
    public static let minimumDozForLogin = "0.50.8"
    /// The oldest doz the workspace section works with: the first with `doz ui open NAME` (the page itself
    /// through doz — the app never builds a link). An older doz (or one whose version cannot be read): no section, and
    /// `workspace ls` is never run.
    public static let minimumDozForWorkspaces = "0.60.8"
    /// How many workspaces the menu lists (in the dashboard's order); the rest are on the Workspaces page.
    public static let workspaceCap = 10

    /// The doz at `version` has what the workspace section needs.
    public static func supportsWorkspaces(_ version: String?) -> Bool {
        guard let version, DozVersion(version) != nil else { return false }
        return !DozVersion.isOlder(version, than: minimumDozForWorkspaces)
    }
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
        /// A workspace's Sleep or Wake under way (`busyWorkspace` names it): its row shows the dashboard's
        /// transitional word; the header stays the daemon's.
        case sleepingWorkspace, wakingWorkspace
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
    /// The copy on disk at this app's own place, read again at each refresh (nil: unreadable). Newer than `appVersion`:
    /// an install swapped it in while this one runs — it must be restarted to update.
    public var installedAppVersion: String?
    /// The last action's failure, shown until the next action.
    public var lastError: String?
    /// Start at Login (nil: not known — no row is drawn).
    public var login: LoginSnapshot?
    /// Which app this is (the dev flavour: its own header, and no Start at Login or app install).
    public var flavour: MenuBarFlavour
    /// `doz workspace ls --json`'s workspaces (nil: not read — a doz too old for it, or no answer: no section).
    public var workspaces: [WorkspaceEntry]?
    /// The workspace a Sleep or Wake under way is for.
    public var busyWorkspace: String?

    public init(doz: Doz, status: DozStatus? = nil, statusProblem: String? = nil, busy: Busy? = nil, appVersion: String? = nil,
                bundledAppVersion: String? = nil, lastError: String? = nil, login: LoginSnapshot? = nil, installedAppVersion: String? = nil,
                flavour: MenuBarFlavour = .release, workspaces: [WorkspaceEntry]? = nil) {
        self.doz = doz; self.status = status; self.statusProblem = statusProblem; self.busy = busy; self.appVersion = appVersion
        self.bundledAppVersion = bundledAppVersion; self.lastError = lastError; self.login = login
        self.installedAppVersion = installedAppVersion; self.flavour = flavour; self.workspaces = workspaces
    }

    public var dozPath: String? { if case .found(let p, _) = doz { return p }; return nil }
    public var dozVersion: String? { if case .found(_, let v) = doz { return v }; return nil }
}

/// What a menu item does when chosen. None of them runs anything but doz (and Quit runs nothing at all).
public enum MenuAction: String, Equatable, Sendable, Encodable {
    case start, stop, restart, dashboard, updateApp, installHelp, quit
    /// The copy on disk is newer than this running one: quit this one and open the copy on disk (no doz command).
    case restartApp = "restart-app"
    /// Start at Login: on (register the agent and the app, then tell doz), off, and — when macOS waits for the person —
    /// open System Settings › Login Items. None runs a doz command by itself (`LoginItemFlow`).
    case loginOn = "login-on", loginOff = "login-off", loginSettings = "login-settings"
    /// A workspace (the item's `workspace`): its page in the dashboard, its Sleep, its Wake — and the Workspaces page.
    case openWorkspace = "open-workspace", sleepWorkspace = "sleep-workspace", wakeWorkspace = "wake-workspace"
    case allWorkspaces = "all-workspaces"

    /// The actions that name a workspace.
    public var needsWorkspace: Bool { self == .openWorkspace || self == .sleepWorkspace || self == .wakeWorkspace }

    /// The doz command an action runs (nil: none — Quit quits this app only, never the daemon).
    public var command: DozCommand? {
        switch self {
        case .start: .start
        case .stop: .stop
        case .restart: .restart
        case .dashboard: .dashboard
        case .updateApp: .updateApp
        case .allWorkspaces: .openWorkspaces
        case .installHelp, .quit, .loginOn, .loginOff, .loginSettings, .restartApp, .openWorkspace, .sleepWorkspace, .wakeWorkspace: nil
        }
    }

    /// The doz command an action runs for `workspace` (nil: none, or a name that is not a workspace's).
    public func command(workspace: String?) -> DozCommand? {
        guard needsWorkspace else { return command }
        guard let workspace, WorkspaceName.isValid(workspace) else { return nil }
        switch self {
        case .openWorkspace: return .openWorkspace(workspace)
        case .sleepWorkspace: return .sleepWorkspace(workspace)
        case .wakeWorkspace: return .wakeWorkspace(workspace)
        default: return nil
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
        case .openWorkspace, .allWorkspaces: .openingDashboard
        case .sleepWorkspace: .sleepingWorkspace
        case .wakeWorkspace: .wakingWorkspace
        case .installHelp, .quit, .loginSettings, .restartApp: nil
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
    /// The workspace the action is for (open, sleep, wake).
    public var workspace: String?
    /// The items under it (a workspace's row: Open, then Sleep or Wake). nil: none.
    public var submenu: [MenuItem]?

    public static let separator = MenuItem(kind: .separator, title: "", enabled: false)

    public init(kind: Kind, title: String, enabled: Bool, action: MenuAction? = nil, confirm: Confirmation? = nil, checked: Bool = false,
                workspace: String? = nil, submenu: [MenuItem]? = nil) {
        self.kind = kind; self.title = title; self.enabled = enabled; self.action = action; self.confirm = confirm; self.checked = checked
        self.workspace = workspace; self.submenu = submenu
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
        case .sleepingWorkspace?, .wakingWorkspace?, nil: break
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
        var items: [MenuItem] = []
        // The dev flavour names itself first, so it is never mistaken for the release app beside it.
        if s.flavour.isDev { items.append(MenuItem(kind: .header, title: MenuBarFlavour.devName, enabled: false)) }
        items.append(MenuItem(kind: .header, title: header(for: s), enabled: false))
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
            if let mine = s.appVersion, let onDisk = s.installedAppVersion, DozVersion.isOlder(mine, than: onDisk) {
                // An install already put a newer copy where this one runs: restarting is the update.
                items.append(MenuItem(kind: .action, title: "Restart to Update (\(mine) → \(onDisk))", enabled: idle, action: .restartApp))
            } else if let bundled = s.bundledAppVersion, let mine = s.appVersion, DozVersion.isOlder(mine, than: bundled) {
                if s.flavour.isDev {
                    // `doz app install` puts the release app in Applications: never from the dev build.
                    items.append(MenuItem(kind: .action, title: "Update Menu Bar App — \(MenuBarFlavour.notInDev)", enabled: false, action: nil))
                } else {
                    items.append(MenuItem(kind: .action, title: "Update Menu Bar App (\(mine) → \(bundled))", enabled: idle, action: .updateApp))
                }
            }
            items.append(contentsOf: workspaceItems(for: s))
        } else {
            items.append(MenuItem(kind: .action, title: "How to Install doz…", enabled: true, action: .installHelp))
        }
        items.append(.separator)
        items.append(MenuItem(kind: .action, title: s.flavour.isDev ? "Quit Dozable Dev Menu" : "Quit Dozable Menu", enabled: true, action: .quit))
        return items
    }
}

extension MenuModel {
    /// The dashboard's order (`core/workspaces.js` STATE_ORDER): what waits on you first; an unknown state after these.
    public static let workspaceStateOrder = ["waiting-on-you", "working", "starting", "idle", "setting-up", "asleep", "stopped",
                                             "finished", "archived"]

    /// A state as the dashboard words it (`workspacePill`: `waiting on you`, `setting up`).
    public static func workspaceStateWords(_ state: String) -> String { state.replacingOccurrences(of: "-", with: " ") }

    /// The one of Sleep and Wake a state offers (the dashboard's `primaryVerb`, those two only): running — idle, working,
    /// waiting on you, starting — → Sleep; asleep or stopped → Wake; setting up, finished, archived → neither.
    public static func workspaceVerb(_ state: String) -> MenuAction? {
        switch state {
        case "idle", "working", "waiting-on-you", "starting": .sleepWorkspace
        case "asleep", "stopped": .wakeWorkspace
        default: nil
        }
    }

    /// The workspace section (empty: none — doz too old, or no listing): a "Workspaces" header; the first
    /// `MenuBarApp.workspaceCap` in the dashboard's order, each "NAME · STATE" with Open and Sleep or Wake under it;
    /// "All Workspaces…" (the Workspaces page); "No workspaces yet" when there are none.
    public static func workspaceItems(for s: Snapshot) -> [MenuItem] {
        guard let list = s.workspaces, MenuBarApp.supportsWorkspaces(s.dozVersion) else { return [] }
        let idle = s.busy == nil
        var items: [MenuItem] = [.separator, MenuItem(kind: .header, title: "Workspaces", enabled: false)]
        if list.isEmpty {
            items.append(.line("No workspaces yet"))
            return items
        }
        let at = { (st: String) in workspaceStateOrder.firstIndex(of: st) ?? workspaceStateOrder.count }
        let sorted = list.sorted { at($0.state) != at($1.state) ? at($0.state) < at($1.state) : $0.name < $1.name }
        for w in sorted.prefix(MenuBarApp.workspaceCap) {
            var words = workspaceStateWords(w.state)
            if w.name == s.busyWorkspace {
                if s.busy == .sleepingWorkspace { words = "sleeping…" } else if s.busy == .wakingWorkspace { words = "waking…" }
            }
            var under = [MenuItem(kind: .action, title: "Open", enabled: idle, action: .openWorkspace, workspace: w.name)]
            if let verb = workspaceVerb(w.state) {
                under.append(.separator)
                under.append(MenuItem(kind: .action, title: verb == .sleepWorkspace ? "Sleep" : "Wake", enabled: idle, action: verb,
                                      workspace: w.name))
            }
            items.append(MenuItem(kind: .action, title: "\(w.name) · \(words)", enabled: true, workspace: w.name, submenu: under))
        }
        items.append(MenuItem(kind: .action, title: "All Workspaces…", enabled: idle, action: .allWorkspaces))
        return items
    }

    /// The Start at Login row (nil: no row — the login state is not known). In order:
    ///   · doz too old for it → disabled, "needs doz X";
    ///   · macOS waits for the person (switched off in System Settings) → "needs approval", opens that page;
    ///   · the app's agent enabled → "Start at Login" ✓ (a click turns it off);
    ///   · this copy is not in Applications → disabled, with where it must be (SMAppService keeps a stable path);
    ///   · doz holds its own login item → ✓ "(set by doz — click to let this app hold it)" (a click hands it over);
    ///   · else "Start at Login", unchecked.
    public static func loginItem(for s: Snapshot) -> MenuItem? {
        // The dev flavour registers nothing with the system: the row says so, and does nothing.
        if s.flavour.isDev { return MenuItem(kind: .action, title: "Start at Login — \(MenuBarFlavour.notInDev)", enabled: false, action: nil) }
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
    /// "release" or "dev".
    public var flavour: String
    /// What is drawn beside the icon (the dev flavour's "DEV"; nil: the icon alone).
    public var badge: String?

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
        flavour = s.flavour.rawName
        badge = s.flavour.badge
    }

    public func json() -> String {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? e.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}
