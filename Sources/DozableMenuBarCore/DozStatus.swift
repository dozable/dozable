import Foundation

/// What `doz daemon status --json` says, as the menu bar app reads it — the app's OWN types, every field optional and
/// unknown fields ignored, so an app built today keeps reading every later doz (its JSON only gains fields) and an
/// older one (0.50.0–0.50.4 print only `{"running": false}` with no daemon).
///
/// Two shapes: with no daemon, `{"running": false, "store", "held", "alwaysOn", "loginItem", …}`; with one, the
/// daemon's status (`version`, `pid`, `store`, `liveSandboxes`, `executableChange`, `parentPid`, `keychainLocked`,
/// `alwaysOn`, `loginItem`, `held`, …) and NO `running` key. Never argv, environment or a session's screen: the app has
/// no field for any of them.
public struct DozStatus: Decodable, Equatable, Sendable {
    public var running: Bool?
    public var version: String?
    public var pid: Int32?
    public var store: String?
    public var liveSandboxes: [String]?
    public var executableChange: String?
    public var executableNote: String?
    public var parentPid: Int32?
    public var keychainLocked: String?
    public var alwaysOn: Bool?
    public var idleTimeoutMinutes: Double?
    public var held: Bool?
    public var loginItem: LoginItem?

    public struct LoginItem: Decodable, Equatable, Sendable {
        /// `doz` (its own plist for this store), `app` (the menu bar app's job), `none`.
        public var owner: String?
        public var setting: String?
        public var installed: Bool?
        public var loaded: Bool?
        public var disabled: Bool?
        public init(owner: String? = nil, setting: String? = nil, installed: Bool? = nil, loaded: Bool? = nil, disabled: Bool? = nil) {
            self.owner = owner; self.setting = setting; self.installed = installed; self.loaded = loaded; self.disabled = disabled
        }
    }

    public init(running: Bool? = nil, version: String? = nil, pid: Int32? = nil, store: String? = nil, liveSandboxes: [String]? = nil,
                executableChange: String? = nil, executableNote: String? = nil, parentPid: Int32? = nil, keychainLocked: String? = nil,
                alwaysOn: Bool? = nil, idleTimeoutMinutes: Double? = nil, held: Bool? = nil, loginItem: LoginItem? = nil) {
        self.running = running; self.version = version; self.pid = pid; self.store = store; self.liveSandboxes = liveSandboxes
        self.executableChange = executableChange; self.executableNote = executableNote; self.parentPid = parentPid
        self.keychainLocked = keychainLocked; self.alwaysOn = alwaysOn; self.idleTimeoutMinutes = idleTimeoutMinutes
        self.held = held; self.loginItem = loginItem
    }

    /// A daemon runs: the daemon's own status has no `running` key (it carries `pid`); the no-daemon answer says false.
    public var isRunning: Bool { running ?? (pid != nil) }

    /// Decode doz's JSON (nil: not a JSON object this app can read).
    public static func decode(_ data: Data) -> DozStatus? {
        guard let s = try? JSONDecoder().decode(DozStatus.self, from: data) else { return nil }
        // Something that is not a status at all (an error object, `{}`) says neither.
        guard s.running != nil || s.pid != nil else { return nil }
        return s
    }
}

/// What `doz app status --json` says (all optional): the copy of the menu bar app inside doz's own folder, and the
/// installed copies.
public struct DozAppStatus: Decodable, Equatable, Sendable {
    public var bundled: Copy?
    public var installed: [Copy]?

    public struct Copy: Decodable, Equatable, Sendable {
        public var path: String?
        public var version: String?
        public init(path: String? = nil, version: String? = nil) { self.path = path; self.version = version }
    }

    public init(bundled: Copy? = nil, installed: [Copy]? = nil) { self.bundled = bundled; self.installed = installed }

    public static func decode(_ data: Data) -> DozAppStatus? { try? JSONDecoder().decode(DozAppStatus.self, from: data) }
}
