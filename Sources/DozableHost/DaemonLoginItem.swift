import Darwin
import Foundation
import DozableKit

/// 694 — the daemon's login item: with the person's consent (`daemon.login_item on`), ONE per-store LaunchAgent that runs
/// `doz daemon start --login-item --store <store>` when they log in (and every 15 minutes after), from their desktop
/// session. Never without consent: the default `ask` and an upgrade write nothing; only `on` ever writes a plist.
///
/// launchd never runs the daemon. The job is a short doz command (`LoginStart`) that starts the daemon THE USUAL WAY
/// (`HostLauncher.spawn`: the double spawn, parent launchd, its own session) and exits within seconds — so the plist has no
/// `KeepAlive`, no `Sockets`, no `MachServices`, and `AbandonProcessGroup` (launchd never reaps what the job started).
///
///   · label `com.dozable.daemon.<8 hex>` — the store path's hash, as its socket folder (`MacPlace.storeHash`), so two stores
///     (doz-dev's, a test's) never share one; file `<LaunchAgents>/<label>.plist`, 0644, written atomically, with a comment
///     naming the store and how to remove it;
///   · ProgramArguments = [the STABLE doz (`StableExecutable` — a Homebrew formula's `opt` path survives `brew upgrade` and
///     `brew cleanup`), daemon, start, --login-item, --store, <store>] — doz itself, never a shell;
///   · RunAtLoad, StartInterval 900, LimitLoadToSessionType Aqua, AbandonProcessGroup, ProcessType Standard,
///     StandardOutPath = StandardErrorPath = <store>/login-item.log, EnvironmentVariables {XDG_CONFIG_HOME} only when set and
///     not the default.
///
/// The install rule (`decide`): present ⇔ `login_item == on` AND (`always_on` OR ≥ 1 kept session) AND no app-owned job
/// (`com.dozable.app.daemon`, reserved for the menu bar app; one whose program no longer exists counts as absent). `sync`
/// is called by `doz daemon login-item on|off`, `doz config set|unset` of the daemon's settings, the web settings route (`daemon.always_on` only — the
/// login item itself is set on the Mac, never from the dashboard),
/// and each daemon start — which only rewrites a stale program path or removes; it never installs.
///
/// Every path goes through the seams: `LaunchAgentsFolder` and `Launchctl` (TestSafety stops a guarded run at the real ones).
public enum DaemonLoginItem {
    public static let labelPrefix = "com.dozable.daemon."
    /// Reserved for the menu bar app's own login item (an SMAppService agent running the same `daemon start --login-item`).
    /// While it is loaded, doz's own plist is removed and never written again.
    public static let appLabel = "com.dozable.app.daemon"
    /// The 15-minute look (a held marker, a daemon gone): launchd runs the job again this often.
    public static let startInterval = 900
    /// `login-item.log` is cut back to empty above this.
    public static let logLimit = 256 * 1024

    public static func label(_ store: DozableStore) -> String { labelPrefix + MacPlace.storeHash(store) }
    public static func plistURL(_ store: DozableStore, folder: URL) -> URL { folder.appendingPathComponent(label(store) + ".plist") }

    /// What the job runs.
    public static func programArguments(store: DozableStore, program: String) -> [String] {
        [program, "daemon", "start", "--login-item", "--store", store.root.standardizedFileURL.path]
    }

    /// `XDG_CONFIG_HOME` for the plist: only when set, not empty, and not the default (`~/.config` of the real home).
    public static func xdgForPlist(_ env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        guard let x = env["XDG_CONFIG_HOME"], !x.isEmpty else { return nil }
        let d = URL(fileURLWithPath: (x as NSString).expandingTildeInPath).standardizedFileURL.path
        return d == TestSafety.realHome.appendingPathComponent(".config").standardizedFileURL.path ? nil : d
    }

    // MARK: render (pure — DaemonLoginItemTests)

    /// The plist, as XML text (an XML comment says what it is — `PropertyListSerialization` cannot write one).
    public static func render(store: DozableStore, program: String, xdgConfigHome: String?) -> String {
        func x(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        // An XML comment may not hold "--" (nor end in "-"): the store's path is written with every run of dashes broken up.
        func c(_ s: String) -> String {
            var t = x(s)
            while t.contains("--") { t = t.replacingOccurrences(of: "--", with: "- -") }
            return t.hasSuffix("-") ? t + " " : t
        }
        let log = store.loginItemLog.path
        var s = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <!-- Dozable: starts the doz daemon for the store \(c(store.root.path)) when you log in (doz daemon start with
             its login-item flag starts the daemon and exits; launchd never runs the daemon itself).
             Written because daemon.login_item is on. Remove it with: doz daemon login-item off (or doz uninstall). -->
        <plist version="1.0">
        <dict>
        \t<key>Label</key>
        \t<string>\(x(label(store)))</string>
        \t<key>ProgramArguments</key>
        \t<array>

        """
        for a in programArguments(store: store, program: program) { s += "\t\t<string>\(x(a))</string>\n" }
        s += """
        \t</array>
        \t<key>RunAtLoad</key>
        \t<true/>
        \t<key>StartInterval</key>
        \t<integer>\(startInterval)</integer>
        \t<key>LimitLoadToSessionType</key>
        \t<string>Aqua</string>
        \t<key>AbandonProcessGroup</key>
        \t<true/>
        \t<key>ProcessType</key>
        \t<string>Standard</string>
        \t<key>StandardOutPath</key>
        \t<string>\(x(log))</string>
        \t<key>StandardErrorPath</key>
        \t<string>\(x(log))</string>

        """
        if let xdg = xdgConfigHome {
            s += "\t<key>EnvironmentVariables</key>\n\t<dict>\n\t\t<key>XDG_CONFIG_HOME</key>\n\t\t<string>\(x(xdg))</string>\n\t</dict>\n"
        }
        s += "</dict>\n</plist>\n"
        return s
    }

    // MARK: the install rule (pure — DaemonLoginItemTests)

    public enum Mode: String, Sendable {
        /// A person's command (login-item on|off, config set, the web settings route): installs, rewrites, loads, removes.
        case command
        /// A daemon's start: only rewrites a stale program path, or removes — never installs.
        case daemonStart
    }

    public enum Action: String, Codable, Equatable, Sendable { case install, rewrite, load, remove, none }

    public struct Decision: Equatable, Sendable {
        public var action: Action
        /// The rule holds: it should be there.
        public var wanted: Bool
        /// Why, in one plain sentence.
        public var reason: String
    }

    public static func decide(setting: String, alwaysOn: Bool, keepers: Int, appOwned: Bool,
                              installed: Bool, stale: Bool, loaded: Bool, mode: Mode) -> Decision {
        let wanted = setting == "on" && (alwaysOn || keepers > 0) && !appOwned
        if wanted {
            let why = alwaysOn ? "daemon.login_item is on" : "daemon.login_item is on and \(keepers) kept session\(keepers == 1 ? "" : "s") on this Mac need\(keepers == 1 ? "s" : "") the daemon at login (daemon.always_on is off)"
            if !installed {
                return mode == .command ? Decision(action: .install, wanted: true, reason: why)
                    : Decision(action: .none, wanted: true, reason: "not installed — a daemon's start never installs it (doz daemon login-item on does)")
            }
            if stale { return Decision(action: .rewrite, wanted: true, reason: why + " — its program path is out of date") }
            if !loaded, mode == .command { return Decision(action: .load, wanted: true, reason: why) }
            return Decision(action: .none, wanted: true, reason: why)
        }
        let why: String
        if appOwned { why = "the Dozable menu bar app starts the daemon at login" }
        else if setting == "off" { why = "daemon.login_item is off" }
        else if setting != "on" { why = "daemon.login_item is ask: not set up (doz daemon login-item on)" }
        else { why = "daemon.always_on is off and no session is kept: nothing to start at login — it is added again when either changes" }
        return Decision(action: installed ? .remove : .none, wanted: false, reason: why)
    }

    // MARK: looking (status)

    /// The menu bar app's job, when loaded and its program still exists (one whose program is gone counts as ABSENT —
    /// otherwise doz would never add its own item back after the app is deleted).
    public static func appJob(_ launchctl: Launchctl) -> (loaded: Bool, program: String?) {
        guard let out = launchctl.printJob(label: appLabel) else { return (false, nil) }
        let program = Launchctl.parseProgram(out)
        if let program, !FileManager.default.fileExists(atPath: program) { return (false, program) }
        return (true, program)
    }

    /// The plist's ProgramArguments (nil: no plist, or one that does not parse).
    public static func installedArguments(_ url: URL) -> [String]? {
        guard let d = try? Data(contentsOf: url),
              let p = try? PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any] else { return nil }
        return p["ProgramArguments"] as? [String]
    }

    /// The login item as `doz daemon status` and `doctor` show it — read only (the plist, `print`, `print-disabled`); it
    /// starts nothing. nil folder or launchctl: a guarded run without the seams (nothing of launchd or the folder is read).
    public static func status(store: DozableStore, settings: DozableSettings = .load(), keepers: Int = 0,
                              launchctl: Launchctl? = Launchctl.forLooking(), folder: URL? = LaunchAgentsFolder.forLooking(),
                              program: String = StableExecutable.path()) -> LoginItemStatus {
        let setting = settings.string(SettingKey.loginItem) ?? "ask"
        let alwaysOn = settings.bool(SettingKey.alwaysOn)
        var st = LoginItemStatus(setting: setting, owner: "none", label: label(store), path: "", program: nil, installed: false,
                                 loaded: false, disabled: nil, stale: false, wanted: false, note: nil)
        guard let folder, let launchctl else {
            st.note = "not looked at (a test run without its LaunchAgents and launchctl seams)"
            return st
        }
        let url = plistURL(store, folder: folder)
        st.path = url.path
        st.installed = FileManager.default.fileExists(atPath: url.path)
        let args = st.installed ? installedArguments(url) : nil
        st.program = args?.first
        if st.installed {
            let expected = programArguments(store: store, program: program)
            st.stale = args != expected || !(args.flatMap(\.first).map { FileManager.default.isExecutableFile(atPath: $0) } ?? false)
            st.loaded = launchctl.printJob(label: st.label) != nil
            st.disabled = launchctl.disabled(label: st.label)
        }
        let app = appJob(launchctl)
        st.owner = app.loaded ? "app" : (st.installed ? "doz" : "none")
        let d = decide(setting: setting, alwaysOn: alwaysOn, keepers: keepers, appOwned: app.loaded, installed: st.installed,
                       stale: st.stale, loaded: st.loaded, mode: .command)
        st.wanted = d.wanted
        if app.loaded { st.note = "the Dozable menu bar app starts the daemon at login" + (app.program.map { " (\($0))" } ?? "") }
        else if !d.wanted || d.action != .none { st.note = d.reason }
        return st
    }

    /// The other stores' login items in `folder` (listed read-only by uninstall and nuke; never touched).
    public static func otherItems(_ store: DozableStore, folder: URL) -> [URL] {
        let mine = label(store) + ".plist"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.hasPrefix(labelPrefix) && $0.hasSuffix(".plist") && $0 != mine }.sorted().map { folder.appendingPathComponent($0) }
    }

    // MARK: sync

    public struct SyncResult: Equatable, Sendable {
        public var decision: Decision
        public var label: String
        public var path: String
        /// After an install, a rewrite or a load: whether launchd took it now (false: it loads at the next login — from ssh).
        public var loaded: Bool?
        /// What launchd said when it refused (one line).
        public var problem: String?

        /// One line for the person.
        public var line: String {
            switch decision.action {
            case .install, .rewrite, .load:
                let what = decision.action == .install ? "added the login item" : decision.action == .rewrite ? "updated the login item (its program path)" : "loaded the login item"
                return "\(what) \(DisplayPath.tilde(path)) — " + (loaded == true
                    ? "the daemon starts when you log in (macOS may show \"Background Items Added\")"
                    : "it loads at your next login" + (problem.map { " (launchd: \($0))" } ?? ""))
            case .remove:
                return "removed the login item \(DisplayPath.tilde(path)) — \(decision.reason)"
            case .none:
                return decision.wanted ? "the login item is in place (\(DisplayPath.tilde(path)))" : decision.reason
            }
        }
    }

    /// Bring the login item in line with the rule. `mode: .daemonStart` never installs; with no plist there it does nothing
    /// at all (not even a look at launchd), so a daemon's start costs nothing on a Mac without the item.
    @discardableResult
    public static func sync(store: DozableStore, mode: Mode, settings: DozableSettings = .load(), keepers: Int = 0,
                            launchctl: Launchctl? = nil, folder: URL? = nil, program: String? = nil,
                            environment env: [String: String] = ProcessInfo.processInfo.environment) -> SyncResult {
        let setting = settings.string(SettingKey.loginItem) ?? "ask"
        let alwaysOn = settings.bool(SettingKey.alwaysOn)
        let lbl = label(store)
        // A daemon's start: a look only (no seam in a guarded run: nothing at all).
        let folder = folder ?? (mode == .daemonStart ? LaunchAgentsFolder.forLooking(environment: env) : LaunchAgentsFolder.current(environment: env))
        guard let folder else {
            return SyncResult(decision: Decision(action: .none, wanted: false, reason: "not looked at (a test run without its seams)"), label: lbl, path: "")
        }
        let url = plistURL(store, folder: folder)
        let installed = FileManager.default.fileExists(atPath: url.path)
        if mode == .daemonStart, !installed {
            return SyncResult(decision: Decision(action: .none, wanted: false, reason: "no login item"), label: lbl, path: url.path)
        }
        let lc = launchctl ?? (mode == .daemonStart ? Launchctl.forLooking(environment: env) : Launchctl.current(environment: env))
        guard let lc else {
            return SyncResult(decision: Decision(action: .none, wanted: false, reason: "not looked at (a test run without its seams)"), label: lbl, path: url.path)
        }
        let program = program ?? StableExecutable.path()
        let expected = programArguments(store: store, program: program)
        let stale = installed && installedArguments(url) != expected
        let loaded = installed && lc.printJob(label: lbl) != nil
        let app = appJob(lc)
        let d = decide(setting: setting, alwaysOn: alwaysOn, keepers: keepers, appOwned: app.loaded, installed: installed,
                       stale: stale, loaded: loaded, mode: mode)
        var r = SyncResult(decision: d, label: lbl, path: url.path)
        switch d.action {
        case .none:
            break
        case .remove:
            if loaded { _ = lc.bootout(label: lbl) }
            unlink(url.path)
        case .install, .rewrite:
            do {
                try write(render(store: store, program: program, xdgConfigHome: xdgForPlist(env)), to: url)
            } catch {
                r.problem = "could not write \(url.path): \(error.localizedDescription)"
                r.loaded = false
                return r
            }
            if loaded { _ = lc.bootout(label: lbl) }
            fallthrough
        case .load:
            let b = lc.bootstrap(plist: url.path)
            r.loaded = b.ok
            if !b.ok {
                r.problem = b.output.split(separator: "\n").first.map(String.init)
            }
        }
        return r
    }

    /// Remove this store's item whatever the rule says (doz uninstall, doz nuke): bootout, then unlink. Only this label.
    @discardableResult
    public static func remove(store: DozableStore, launchctl: Launchctl? = nil, folder: URL? = nil) -> Bool {
        let folder = folder ?? LaunchAgentsFolder.current()
        let url = plistURL(store, folder: folder)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let lc = launchctl ?? Launchctl.current()
        if lc.printJob(label: label(store)) != nil { _ = lc.bootout(label: label(store)) }
        return unlink(url.path) == 0
    }

    /// Atomically: a temporary file beside it, 0644, renamed over. The folder is made (0755) when missing.
    static func write(_ text: String, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).\(getpid()).tmp")
        try Data(text.utf8).write(to: tmp)
        chmod(tmp.path, 0o644)
        guard rename(tmp.path, url.path) == 0 else {
            let e = errno
            unlink(tmp.path)
            throw POSIXError(POSIXErrorCode(rawValue: e) ?? .EIO)
        }
    }
}

/// 694: the login item as `doz daemon status --json` and doctor carry it (`HostStatus.loginItem`, and without a daemon).
public struct LoginItemStatus: Codable, Equatable, Sendable {
    /// `daemon.login_item`: ask, on or off.
    public var setting: String
    /// Who starts the daemon at login: `doz` (this store's plist), `app` (the menu bar app's job), `none`.
    public var owner: String
    public var label: String
    public var path: String
    /// The program its plist runs.
    public var program: String?
    public var installed: Bool
    /// launchd has it loaded in the person's GUI domain.
    public var loaded: Bool
    /// The person switched it off (System Settings › Login Items); nil: not known.
    public var disabled: Bool?
    /// Its program path or arguments are not what this doz would write (an install moved; the program is gone).
    public var stale: Bool
    /// The install rule holds (setting on, always on or a kept session, no app job).
    public var wanted: Bool
    public var note: String?

    public init(setting: String, owner: String, label: String, path: String, program: String?, installed: Bool, loaded: Bool,
                disabled: Bool?, stale: Bool, wanted: Bool, note: String?) {
        self.setting = setting; self.owner = owner; self.label = label; self.path = path; self.program = program
        self.installed = installed; self.loaded = loaded; self.disabled = disabled; self.stale = stale; self.wanted = wanted; self.note = note
    }

    /// The `doz daemon status` line.
    public var line: String {
        if owner == "app" { return "login item: the Dozable menu bar app starts the daemon at login" }
        if !installed {
            switch setting {
            case "on": return "login item: on, not installed — " + (note ?? "doz daemon login-item on adds it")
            case "off": return "login item: off (doz daemon login-item on starts the daemon when you log in)"
            default: return "login item: not set up (doz daemon login-item on starts the daemon when you log in)"
            }
        }
        var s = "login item: \(DisplayPath.tilde(path))"
        if disabled == true { s += " — SWITCHED OFF in System Settings › General › Login Items" }
        else { s += loaded ? " — loaded" : " — not loaded (it loads at your next login)" }
        if stale { s += " — its program is out of date (\(program.map { DisplayPath.tilde($0) } ?? "none")): doz daemon login-item on rewrites it" }
        if !wanted, let note { s += " — \(note); the next daemon start removes it" }
        return s
    }
}
