import Foundation

/// 693 — what an idle daemon does at each look (`HostServer.idleLoop`): pure, so every case is a unit test
/// (`IdleDecisionTests`).
///
/// The rules, in order:
///   · a daemon that is stopping does nothing more;
///   · its program changed (an update renamed a new build over it, or relinked its stable path) or a newer recipe catalogue
///     waits, while NOTHING is live (no VM, no preparation) and NO client is connected:
///       – fenced sessions on this Mac (or kept ones) keep it: HAND OVER — a new daemon of the installed build, started from
///         the stable path, takes them once this one lets go of the lock;
///       – always on (and started by the launcher — a person's `--foreground` daemon exits): RESTART IN PLACE — a new daemon from the stable path, then exit; the new one waits for the lock;
///       – otherwise: EXIT (the next command starts the installed build);
///   · idle (nothing live, no fenced or kept session, no client): exit once idle for the effective timeout — never while
///     always on; a daemon whose login keychain is locked is NEVER always on, and exits after at most 5 minutes whatever
///     the settings say (a daemon started over ssh cannot read the login Keychain; a later command from the desktop
///     should get one that can).
public struct IdleDecision: Equatable, Sendable {
    /// A daemon whose login keychain is locked exits after at most this many minutes with nothing running.
    public static let lockedTimeoutMinutes = 5.0

    public enum Action: Equatable, Sendable {
        case stay
        /// Exit; the next command starts a daemon of the build installed now.
        case exit(String)
        /// Start a new daemon from the stable path, then exit (always on: no command needed).
        case restartInPlace(String)
        /// Fenced (or kept) sessions on this Mac: hand them to a new daemon (`HostServer.handOver`).
        case handOver(String)
    }

    public var alwaysOnSetting: Bool
    /// Why this daemon cannot read the login keychain (nil: it can).
    public var keychainLocked: String?
    /// The idle timeout this daemon was started with (`--idle-timeout`, `$DOZ_DAEMON_IDLE`, the setting); 0 = never.
    public var timeoutMinutes: Double
    /// Sandboxes with a VM, and preparations under way.
    public var live: [String]
    /// Fenced sessions on this Mac (their proxy and git guard are the daemon's).
    public var fenced: [String]
    /// Kept sessions on this Mac (none yet).
    public var keepers: Int
    public var connections: Int
    public var stopping: Bool
    public var executableChange: ExecutableIdentity.Change?
    public var recipeCatalogueWaiting: Bool
    /// Seconds idle so far (nil: not idle at the last look).
    public var idleSeconds: Double?
    /// Started by the launcher (detached). A person's `--foreground` daemon is never replaced by a detached one: it exits.
    public var launched: Bool

    public init(alwaysOnSetting: Bool, keychainLocked: String? = nil, timeoutMinutes: Double, live: [String] = [], fenced: [String] = [],
                keepers: Int = 0, connections: Int = 0, stopping: Bool = false, executableChange: ExecutableIdentity.Change? = nil,
                recipeCatalogueWaiting: Bool = false, idleSeconds: Double? = nil, launched: Bool = true) {
        self.alwaysOnSetting = alwaysOnSetting
        self.keychainLocked = keychainLocked
        self.timeoutMinutes = timeoutMinutes
        self.live = live
        self.fenced = fenced
        self.keepers = keepers
        self.connections = connections
        self.stopping = stopping
        self.executableChange = executableChange
        self.recipeCatalogueWaiting = recipeCatalogueWaiting
        self.idleSeconds = idleSeconds
        self.launched = launched
    }

    /// Whether this daemon stays running with nothing open: the setting, unless its login keychain is locked.
    public static func alwaysOn(setting: Bool, keychainLocked: String?) -> Bool { setting && keychainLocked == nil }
    public var alwaysOn: Bool { Self.alwaysOn(setting: alwaysOnSetting, keychainLocked: keychainLocked) }

    /// Minutes with nothing running before it exits; nil = never. Locked: at most 5 (a shorter configured timeout — a
    /// test's — still applies).
    public static func effectiveTimeout(alwaysOnSetting: Bool, keychainLocked: String?, timeoutMinutes: Double) -> Double? {
        if keychainLocked != nil { return timeoutMinutes > 0 ? min(timeoutMinutes, lockedTimeoutMinutes) : lockedTimeoutMinutes }
        if alwaysOnSetting { return nil }
        return timeoutMinutes > 0 ? timeoutMinutes : nil
    }
    public var effectiveTimeout: Double? {
        Self.effectiveTimeout(alwaysOnSetting: alwaysOnSetting, keychainLocked: keychainLocked, timeoutMinutes: timeoutMinutes)
    }

    /// Nothing live, no fenced or kept session, no client: the idle clock runs.
    public var isIdle: Bool { live.isEmpty && fenced.isEmpty && keepers == 0 && connections == 0 }

    public var action: Action {
        guard !stopping else { return .stay }
        let why: String? = executableChange.map { "my program changed (\($0.rawValue))" }
            ?? (recipeCatalogueWaiting ? "a newer recipe catalogue is downloaded" : nil)
        if let why, live.isEmpty, connections == 0 {
            if !fenced.isEmpty || keepers > 0 {
                let held = fenced + (keepers > 0 ? ["\(keepers) kept"] : [])
                return .handOver("\(why) and only sessions on this Mac keep me (\(held.joined(separator: ", ")))")
            }
            if alwaysOn && launched { return .restartInPlace("\(why) and nothing is running — restarting in place, from the installed build") }
            return .exit("\(why) and nothing is running — exiting so the next command runs the installed build")
        }
        if isIdle, let t = effectiveTimeout, let idle = idleSeconds, idle >= t * 60 {
            let locked = keychainLocked.map { " (the login keychain is locked here — \($0) — so it is never kept running)" } ?? ""
            return .exit("idle for \(t.formatted()) min with nothing running\(locked) — exiting")
        }
        return .stay
    }

    /// How often the daemon looks: within 5 s when it never exits by idling (a program change is picked up promptly);
    /// else a quarter of the timeout, 0.5–15 s.
    public static func interval(effectiveTimeout: Double?) -> Double {
        guard let t = effectiveTimeout, t > 0 else { return 5 }
        return min(15, max(0.5, t * 60 / 4))
    }
}
