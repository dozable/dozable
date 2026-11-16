import Darwin
import Foundation
import DozableKit

// 695 — the login keep-alive's modes, who holds the Mac's login, and what is recorded about each try. The keep-alive only
// ever RUNS THE MAC'S OWN `claude -p` (LoginWatcher.keepaliveIfDue): Dozable never reads, holds, writes or logs a refresh
// token, and nothing here holds a token — the record's reason is cleaned of token-shaped text before it is stored.

/// `doz account keepalive off|on|always`. `on`: at the login's expiry, while a sandbox or fenced session used the Mac login in the last
/// 15 minutes. `always`: at its expiry, whether or not anything uses it (the daemon keeps a watcher on each Mac login).
public enum KeepaliveMode: String, Codable, Sendable, CaseIterable {
    case off, on, always

    /// The store's mode. `keepalive` (the bool an older doz reads) says on or off; `keepaliveMode` "always" refines on —
    /// a file whose bool an older doz turned off is off, whatever else it says.
    public static func of(_ f: AccountsFile) -> KeepaliveMode {
        guard f.keepalive else { return .off }
        return f.keepaliveMode == KeepaliveMode.always.rawValue ? .always : .on
    }
}

extension AccountsFile {
    /// 695: the mode, written as an older doz reads it (`keepalive` true for on and always).
    public var keepaliveSetting: KeepaliveMode {
        get { KeepaliveMode.of(self) }
        set {
            keepalive = newValue != .off
            keepaliveMode = newValue == .always ? newValue.rawValue : nil
        }
    }
}

/// A Claude Code process that holds its OWN copy of this Mac's login (it is not fenced): renewing now would cancel it.
public struct ClaudeHolder: Equatable, Sendable {
    public var pid: pid_t
    /// The session on this Mac (`@mac S`) it runs in, when it is one of Dozable's.
    public var session: String?
    public init(pid: pid_t, session: String?) { self.pid = pid; self.session = session }

    /// "Claude Code (pid 812, session admin on this Mac)" / "Claude Code (pid 812, not Dozable's)".
    public var label: String {
        let who = session.map { "session \($0) on this Mac" } ?? "not Dozable's"
        return pid > 0 ? "Claude Code (pid \(pid), \(who))" : "Claude Code (\(who))"
    }
}

/// Which running Claude Code processes hold the login, and which are fenced (they hold only a placeholder).
public struct ClaudeHolders: Equatable, Sendable {
    public var holders: [ClaudeHolder] = []
    /// Fenced sessions' Claude Code processes, left out (pid, session).
    public var fenced: [ClaudeHolder] = []
    public init(holders: [ClaudeHolder] = [], fenced: [ClaudeHolder] = []) { self.holders = holders; self.fenced = fenced }

    /// Sort `candidates` (`ClaudeLogin.claudePids`) by the session records of this store: a member of a FENCED session
    /// (its sentinel, `MacFenceStop`'s test — or, without `sandbox_check`, its program and that program's descendants) is
    /// fenced; any other is a holder, named by the unfenced session whose program it is or descends from. The keep-alive's
    /// own runs are neither.
    static func find(candidates: [pid_t], records: [String: MacSessionRecord],
                            own: (pid_t) -> Bool = KeepaliveRuns.contains,
                            isFencedMember: (pid_t, MacFenceRecord, pid_t?) -> Bool = ClaudeHolders.fencedMember,
                            parent: (pid_t) -> pid_t? = MacFenceStop.parent) -> ClaudeHolders {
        var out = ClaudeHolders()
        let fenced = records.filter { $0.value.fence != nil }.sorted { $0.key < $1.key }
        let unfenced = records.filter { $0.value.fence == nil && $0.value.pid != nil }.sorted { $0.key < $1.key }
        for pid in candidates where !own(pid) {
            if let (name, _) = fenced.first(where: { isFencedMember(pid, $0.value.fence!, $0.value.pid.map { pid_t($0) }) }) {
                out.fenced.append(ClaudeHolder(pid: pid, session: name))
                continue
            }
            var chain: Set<pid_t> = [pid]
            var p = pid
            for _ in 0..<64 {
                guard let pp = parent(p), pp > 1, chain.insert(pp).inserted else { break }
                p = pp
            }
            let name = unfenced.first { chain.contains(pid_t($0.value.pid!)) }?.key
            out.holders.append(ClaudeHolder(pid: pid, session: name))
        }
        return out
    }

    /// A process of the fenced session `f` (whose program is `program`)?
    public static func fencedMember(_ pid: pid_t, _ f: MacFenceRecord, _ program: pid_t?) -> Bool {
        if MacFenceStop.available {
            return MacFenceStop.sandboxed(pid) == true && MacFenceStop.mayRead(pid, f.sentinel) == true && MacFenceStop.mayRead(pid, f.antiSentinel) == false
        }
        guard let program, program > 1 else { return false }
        var p = pid
        for _ in 0..<64 {
            if p == program || getpgid(p) == program { return true }
            guard let pp = MacFenceStop.parent(p), pp > 1 else { return false }
            p = pp
        }
        return false
    }
}

/// 695: when the keep-alive's runs for one expiry are due — in seconds after the expiry. Claude Code renews only a token that
/// has expired (observed on a real Mac, Claude Code 2.1.325: a run 7 min 46 s before the expiry exited 0 and left the login as
/// it was; after the expiry the login renewed for 8 hours), so the first run is AT the expiry; a run that leaves the login
/// unchanged is tried again 1, 5 and 15 minutes after the expiry, then every 30 minutes, 6 runs at most.
public enum KeepaliveSchedule {
    public static let offsets: [TimeInterval] = [0, 60, 300, 900, 2700, 4500]

    /// TEST SEAM (guarded runs only): `DOZ_TEST_KEEPALIVE_SCHEDULE=0,2,4` — the offsets in seconds, so a suite sees the
    /// retries and the limit in seconds.
    public static func current(_ env: [String: String] = ProcessInfo.processInfo.environment) -> [TimeInterval] {
        guard TestSafety.guarded(env), let raw = env["DOZ_TEST_KEEPALIVE_SCHEDULE"] else { return offsets }
        let v = raw.split(separator: ",").compactMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) }.filter { $0 >= 0 }
        return v.isEmpty ? offsets : v
    }

    /// When run number `runs + 1` for `expiry` is due (nil: no more runs for it).
    public static func due(expiry: Date, runs: Int, schedule: [TimeInterval] = offsets) -> Date? {
        runs < schedule.count ? expiry.addingTimeInterval(schedule[max(0, runs)]) : nil
    }
}

/// `<store>/keepalive.json` (0600): the last try of the login keep-alive — read by `doz account ls` and `doctor` with or
/// without a daemon. Never a token: `reason` holds the exit code and Claude's last stderr line, cleaned (`clean`).
public struct KeepaliveRecord: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        /// The login's expiry moved later.
        case renewed
        /// Claude Code ran and exited 0, but the login is as it was.
        case unchanged
        /// Not run (a Claude Code holds its own copy, a locked daemon, no claude): `reason` says which.
        case skipped
        /// Claude Code exited non-zero, timed out or could not start.
        case failed
    }

    public var version = 1
    public var account: String
    public var mode: String
    public var lastAttemptAt: Date
    public var outcome: Outcome
    public var reason: String?
    public var exit: Int32?
    public var expiresBefore: Date?
    public var expiresAfter: Date?
    /// When the next try is due: the login's (new) expiry, or the next retry after an unchanged run (nil: none for this login).
    public var nextTryAt: Date?
    /// The last time a run renewed the login, and until when (kept across later tries).
    public var lastRenewedAt: Date?
    public var renewedUntil: Date?

    public init(account: String, mode: String, lastAttemptAt: Date, outcome: Outcome, reason: String? = nil, exit: Int32? = nil,
                expiresBefore: Date? = nil, expiresAfter: Date? = nil, nextTryAt: Date? = nil) {
        self.account = account; self.mode = mode; self.lastAttemptAt = lastAttemptAt; self.outcome = outcome
        self.reason = reason.map { Self.clean($0) }; self.exit = exit
        self.expiresBefore = expiresBefore; self.expiresAfter = expiresAfter; self.nextTryAt = nextTryAt
        if outcome == .renewed { lastRenewedAt = lastAttemptAt; renewedUntil = expiresAfter }
    }

    public static func url(_ store: DozableStore) -> URL { store.root.appendingPathComponent("keepalive.json") }

    public static func read(_ store: DozableStore) -> KeepaliveRecord? {
        (try? Data(contentsOf: url(store))).flatMap { try? HostWire.decoder.decode(KeepaliveRecord.self, from: $0) }
    }

    /// Write it (atomic, 0600), keeping the last renewal of the record it replaces (same account).
    public func save(_ store: DozableStore) throws {
        var r = self
        if r.outcome != .renewed, let old = Self.read(store), old.account == r.account {
            r.lastRenewedAt = old.lastRenewedAt
            r.renewedUntil = old.renewedUntil
        }
        r.reason = r.reason.map { Self.clean($0) }
        try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
        let u = Self.url(store)
        try HostWire.prettyEncoder.encode(r).write(to: u, options: .atomic)
        chmod(u.path, 0o600)
    }

    /// At most 200 characters, one line, every token-shaped run replaced by `…`: `sk-ant-…`, a JWT, a bearer value, and
    /// any run of 24 or more letters, digits and `-_+/=.`.
    public static func clean(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
        for p in [#"sk-ant-[A-Za-z0-9_\-]*"#, #"(?i)bearer\s+\S+"#, #"[A-Za-z0-9_\-+/=.]{24,}"#] {
            t = t.replacingOccurrences(of: p, with: "…", options: .regularExpression)
        }
        t = t.trimmingCharacters(in: .whitespaces)
        return t.count > 200 ? String(t.prefix(199)) + "…" : t
    }
}

/// What `doz account ls` (`--json` `keepalive` on a Mac login's row), `doz daemon status` and `doctor` say about the
/// keep-alive: the mode, the last try (from the record), the next try (from the login's expiry now), and why this daemon
/// cannot run it (a locked keychain).
public struct KeepaliveStatus: Codable, Equatable, Sendable {
    public var mode: String
    public var account: String?
    public var lastAttemptAt: Date?
    public var outcome: String?
    public var reason: String?
    public var exit: Int32?
    public var lastRenewedAt: Date?
    public var renewedUntil: Date?
    public var nextTryAt: Date?
    /// The running daemon can never run it: started where the login keychain is locked (`ssh`, …).
    public var keychainLocked: String?
    /// The last try failed for the login as it is now: no other try until the login changes (a failure is not repeated).
    public var waitsForChange: Bool? = nil

    public init(mode: KeepaliveMode, account: String = "mac", record: KeepaliveRecord?, expiresAt: Date?, keychainLocked: String? = nil) {
        self.mode = mode.rawValue
        self.account = account
        self.keychainLocked = mode == .off ? nil : keychainLocked
        if let r = record, r.account == account {
            lastAttemptAt = r.lastAttemptAt
            outcome = r.outcome.rawValue
            reason = r.reason
            exit = r.exit
            lastRenewedAt = r.lastRenewedAt
            renewedUntil = r.renewedUntil
        }
        guard mode != .off else { return }
        // The record is about the login as it is now (the same expiry): its own word on the next try.
        if let r = record, r.account == account, let tried = r.expiresBefore, abs((expiresAt ?? tried).timeIntervalSince(tried)) < 1 {
            if r.outcome == .failed { waitsForChange = true; return }
            if r.outcome == .unchanged { nextTryAt = r.nextTryAt; return }
        }
        // Otherwise: at the login's expiry (Claude Code renews only an expired token).
        nextTryAt = expiresAt ?? record.flatMap { $0.account == account ? ($0.expiresAfter ?? $0.nextTryAt) : nil }
    }

    /// From the store alone (no daemon): the mode, the record, the expiry the record knew.
    public static func fromStore(_ store: DozableStore, settings: DozableSettings = .load(), account: String = "mac") -> KeepaliveStatus {
        KeepaliveStatus(mode: KeepaliveMode.of(AccountStore(store: store, settings: settings).load()), account: account,
                        record: KeepaliveRecord.read(store), expiresAt: nil)
    }

    public var failed: Bool { outcome == KeepaliveRecord.Outcome.failed.rawValue }

    /// "keep-alive always · last renewed 09:02 (until 17:02) · next try 16:52", or "· last try 09:02 FAILED (exit 1: …)".
    public func line(now: Date = Date()) -> String {
        guard mode != KeepaliveMode.off.rawValue else { return "keep-alive off (doz account keepalive on|always)" }
        var parts = ["keep-alive \(mode)"]
        let hm = CredentialVaultClock.hm
        switch outcome {
        case KeepaliveRecord.Outcome.failed.rawValue?:
            parts.append("last try \(lastAttemptAt.map(hm) ?? "?") FAILED (\(reason ?? "exit \(exit ?? -1)"))")
        case KeepaliveRecord.Outcome.skipped.rawValue?:
            parts.append("last try \(lastAttemptAt.map(hm) ?? "?") skipped: \(reason ?? "?")")
        case KeepaliveRecord.Outcome.unchanged.rawValue?:
            parts.append("last try \(lastAttemptAt.map(hm) ?? "?"): Claude Code did not renew the login yet")
        default: break
        }
        if let r = lastRenewedAt { parts.append("last renewed \(hm(r))" + (renewedUntil.map { " (until \(hm($0)))" } ?? "")) }
        else if outcome == nil { parts.append("no renewal yet") }
        if let why = keychainLocked {
            parts.append("never run by this daemon: it was started where the login keychain is locked (\(why))")
        } else if waitsForChange == true {
            parts.append("no other try for this login: it renews when Claude Code is next used on this Mac")
        } else if let n = nextTryAt {
            parts.append(n <= now ? "next try now (the login has expired)" : "next try \(hm(n))" + (mode == KeepaliveMode.on.rawValue ? " if a sandbox or fenced session uses the login" : ""))
        }
        return parts.joined(separator: " · ")
    }
}
