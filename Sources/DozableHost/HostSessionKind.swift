import Darwin
import Foundation
import Security

/// 679 B6: can THIS process read the login keychain? A host started over ssh runs in the ssh session's security
/// session, where the login keychain is locked: every sandbox it serves then shows its Mac account `unreadable` — while
/// `doz doctor`, run from the logged-in session, reads the login fine. Seen on a Mac where `doz image bake claude-code`
/// over ssh left such a host behind. So the host records its own session at start, and says why where it shows.
public enum HostSessionKind {
    /// What a session's attributes say.
    public struct Attributes: Equatable, Sendable {
        /// The session can show a GUI (a console login) — its login keychain is unlocked with it.
        public var hasGraphicAccess: Bool
        /// The session came in over the network (ssh).
        public var isRemote: Bool
        /// `SSH_CONNECTION` is in the environment.
        public var sshEnvironment: Bool

        public init(hasGraphicAccess: Bool, isRemote: Bool, sshEnvironment: Bool) {
            self.hasGraphicAccess = hasGraphicAccess
            self.isRemote = isRemote
            self.sshEnvironment = sshEnvironment
        }
    }

    /// Why the login keychain is out of reach (nil: it is in reach).
    public static func lockedReason(_ a: Attributes) -> String? {
        if a.isRemote || (a.sshEnvironment && !a.hasGraphicAccess) { return "ssh" }
        if !a.hasGraphicAccess { return "no login session" }
        return nil
    }

    /// This process's session (`SessionGetInfo` of the caller's security session).
    public static func current(environment env: [String: String] = ProcessInfo.processInfo.environment) -> Attributes {
        var sid = SecuritySessionId()
        var bits = SessionAttributeBits()
        let ok = SessionGetInfo(SecuritySessionId(bitPattern: -1), &sid, &bits) == errSessionSuccess
        return Attributes(hasGraphicAccess: ok && bits.contains(.sessionHasGraphicAccess),
                          isRemote: ok && bits.contains(.sessionIsRemote),
                          sshEnvironment: !(env["SSH_CONNECTION"] ?? "").isEmpty)
    }

    /// Why this process cannot read the login keychain (nil: it can). TEST SEAM (guarded runs only):
    /// `DOZ_TEST_KEYCHAIN_LOCKED=1` says `ssh`, whatever the session is.
    public static func lockedReason(environment env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if env["DOZ_TEST_KEYCHAIN_LOCKED"] == "1", TestSafety.guarded(env) { return "ssh" }
        // A guarded run never looks at the real Mac's login, so its session is no reason to warn.
        if TestSafety.guarded(env) { return nil }
        return lockedReason(current(environment: env))
    }

    /// What to do about it, said where an account shows (`account ls`, `ls`, doctor).
    public static func hostAdvice(pid: Int32, startedAt: Date, reason: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "h:mm a"
        f.amSymbol = "am"
        f.pmSymbol = "pm"
        return "the doz host (pid \(pid), started \(f.string(from: startedAt))) was started from a session where the login keychain is locked (\(reason)) — "
            + "run doz host restart from a logged-in session"
    }

    /// What a command says before it STARTS a host from such a session.
    public static func startWarning(_ reason: String) -> String {
        "doz: starting the doz host from a session where the login keychain is locked (\(reason)) — sandboxes it serves cannot "
            + "use this Mac's Claude login (or anything else in the keychain). Start it from a logged-in session instead "
            + "(doz host restart there fixes one started here)."
    }
}
