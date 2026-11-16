import Foundation
import DozableKit

/// Runs the Mac's own `claude` once (the keep-alive, 588 D3). A fake in tests.
public protocol KeepaliveRunning: Sendable {
    func run(binary: String, arguments: [String], environment: [String: String], directory: URL, timeout: TimeInterval) -> Int32
    /// 695: the same, with the program's last line on stderr (what a failed renewal says — never stored as it is: see
    /// `KeepaliveRecord.clean`). A runner that does not capture says nothing.
    func runCapturing(binary: String, arguments: [String], environment: [String: String], directory: URL, timeout: TimeInterval) -> KeepaliveRun
}

extension KeepaliveRunning {
    public func runCapturing(binary: String, arguments: [String], environment: [String: String], directory: URL, timeout: TimeInterval) -> KeepaliveRun {
        KeepaliveRun(code: run(binary: binary, arguments: arguments, environment: environment, directory: directory, timeout: timeout), lastErrorLine: nil)
    }
}

/// 695: how one keep-alive run ended. `code` -1: it could not start; -2: killed at its timeout.
public struct KeepaliveRun: Equatable, Sendable {
    public var code: Int32
    public var lastErrorLine: String?
    public init(code: Int32, lastErrorLine: String?) { self.code = code; self.lastErrorLine = lastErrorLine }
}

/// 695: the pids of the keep-alive's own runs while they run — never counted as a Claude Code that holds the login.
public enum KeepaliveRuns {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var pids: Set<pid_t> = []
    static func insert(_ p: pid_t) { lock.withLock { _ = pids.insert(p) } }
    static func remove(_ p: pid_t) { lock.withLock { _ = pids.remove(p) } }
    public static func contains(_ p: pid_t) -> Bool { lock.withLock { pids.contains(p) } }
}

public struct ProcessKeepaliveRunner: KeepaliveRunning {
    /// 695: this runner runs the Mac's CLAUDE (the login keep-alive) — a guarded run may run only its fake
    /// (`TestSafety.keepaliveClaudeViolation` stops anything else). The Codex keep-alive's runner is not one.
    public var claude = false
    public init(claude: Bool = false) { self.claude = claude }

    public func run(binary: String, arguments: [String], environment: [String: String], directory: URL, timeout: TimeInterval) -> Int32 {
        runCapturing(binary: binary, arguments: arguments, environment: environment, directory: directory, timeout: timeout).code
    }

    public func runCapturing(binary: String, arguments: [String], environment: [String: String], directory: URL, timeout: TimeInterval) -> KeepaliveRun {
        if claude { TestSafety.enforce(TestSafety.keepaliveClaudeViolation(binary)) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = arguments
        p.environment = environment
        p.currentDirectoryURL = directory
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        let err = Pipe()
        p.standardError = err
        do { try p.run() } catch { return KeepaliveRun(code: -1, lastErrorLine: nil) }
        let pid = p.processIdentifier
        KeepaliveRuns.insert(pid)
        defer { KeepaliveRuns.remove(pid) }
        // Collected on its own thread (a full pipe would stall the program); only the last 16 KiB are kept. (A child of
        // the program may keep the pipe open past its exit: the reader is then left behind, and what it has is read.)
        let box = LockedData()
        let done = DispatchSemaphore(value: 0)
        let handle = err.fileHandleForReading
        DispatchQueue.global().async {
            while true {
                let d = handle.availableData
                if d.isEmpty { break }
                box.append(d, keep: 16 << 10)
            }
            done.signal()
        }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { usleep(50_000) }
        var timedOut = false
        if p.isRunning {
            timedOut = true
            p.terminate()
            let grace = Date().addingTimeInterval(5)
            while p.isRunning && Date() < grace { usleep(50_000) }
            if p.isRunning { kill(pid, SIGKILL) }
        }
        _ = done.wait(timeout: .now() + 2)
        let last = String(decoding: box.data, as: UTF8.self).split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty }
        return KeepaliveRun(code: timedOut ? -2 : p.terminationStatus, lastErrorLine: last)
    }
}

final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var _data = Data()
    var data: Data { lock.withLock { _data } }
    func append(_ d: Data, keep: Int) { lock.withLock { _data.append(d); if _data.count > keep { _data = Data(_data.suffix(keep)) } } }
}

/// How the keep-alive decides and acts (injected so tests use a fake runner and fake probes).
public struct KeepaliveConfig: Sendable {
    /// 695: off, on (a subscriber used the login lately) or always (no use needed).
    public var mode: KeepaliveMode
    public var enabled: Bool { mode != .off }
    public var runner: KeepaliveRunning
    /// 695: the Claude Code processes that hold their own copy of the login now (unfenced), and the fenced ones left out.
    public var holders: @Sendable () -> ClaudeHolders
    public var binary: @Sendable () -> String?
    /// 695: why this daemon cannot read the login keychain (nil: it can) — it then never runs the keep-alive.
    public var keychainLocked: @Sendable () -> String? = { nil }
    /// 695: the run's folder — made fresh and empty (0700) for each run (`<store>/keepalive/run`; nil: a fresh temporary one).
    public var runDirectory: URL?
    /// 695: each try's record (written to `<store>/keepalive.json`, the log, the metrics) — and whether it is news (a skip
    /// repeated at every look is recorded once).
    public var report: @Sendable (KeepaliveRecord) -> Void = { _ in }
    /// (Mode on) a sandbox used it within this long.
    public var recentUse: TimeInterval = 900
    /// 695: WHEN the runs for one expiry are due, in seconds after it (`KeepaliveSchedule`): the first AT the expiry — Claude
    /// Code renews only a token that has expired (seen on a real Mac, Claude Code 2.1.325: a run 7 min 46 s before the expiry
    /// exited 0 and left the login as it was) — and, while a run leaves it unchanged, again 1, 5 and 15 minutes after,
    /// then every 30. After the last, `failed`. A renewal or a run that exits non-zero ends the tries for that expiry.
    public var schedule: [TimeInterval] = KeepaliveSchedule.offsets
    /// 695: the watcher sets itself a timer for the next due time (the expiry, the next retry), so a renewal follows the
    /// expiry within seconds instead of at the next poll. Off in unit tests (they pass `now:`).
    public var timers = false

    public init(mode: KeepaliveMode, runner: KeepaliveRunning = ProcessKeepaliveRunner(claude: true),
                holders: @escaping @Sendable () -> ClaudeHolders = { ClaudeHolders(holders: ClaudeLogin.loginHolders(excluding: { _ in false }).map { ClaudeHolder(pid: $0, session: nil) }) },
                binary: @escaping @Sendable () -> String? = { ClaudeLogin.resolveBinary() }) {
        self.mode = mode
        self.runner = runner
        self.holders = holders
        self.binary = binary
    }

    /// An older shape (tests): on or off, and "is a Claude Code running" as one unnamed holder.
    public init(enabled: Bool, runner: KeepaliveRunning = ProcessKeepaliveRunner(claude: true),
                isClaudeRunning: @escaping @Sendable () -> Bool,
                binary: @escaping @Sendable () -> String? = { ClaudeLogin.resolveBinary() }) {
        self.init(mode: enabled ? .on : .off, runner: runner,
                  holders: { ClaudeHolders(holders: isClaudeRunning() ? [ClaudeHolder(pid: -1, session: nil)] : []) }, binary: binary)
    }

    /// The one command: the Mac's Claude Code, one tiny non-interactive turn. Its normal startup renews the login under
    /// Claude Code's own lock — doz never touches the refresh token. Nothing from a sandbox reaches the argv, env or cwd.
    ///
    /// 695 step 0 — the flags, read from `claude --help` of Claude Code 2.1.325 on the build Mac (help only; `claude -p`
    /// was never run): `--tools <tools...>` ("Use \"\" to disable all tools"), `--strict-mcp-config` ("Only use MCP servers
    /// from --mcp-config") and `--settings <file-or-json>` are listed, so all three are kept (`disableAllHooks` is a settings
    /// key, not a flag). `--max-turns` is NOT listed in that help (a hidden flag Claude Code has long accepted); it stays as
    /// before. Not used: `--bare` — it reads no OAuth login and no keychain, so it could not renew the login at all.
    /// `--tools ""` comes after the prompt: its value list ends at the next flag.
    public static let arguments = ["-p", "ok", "--model", "haiku", "--max-turns", "1", "--no-session-persistence",
                                   "--tools", "", "--strict-mcp-config", "--settings", #"{"disableAllHooks":true}"#]
}

/// ONE watcher per Mac Claude login (keychain item), fanned out to every sandbox that uses it
/// (588: one `security` read per interval however many sandboxes follow it).
///
/// It follows the Mac: a renewed access token goes to every subscriber's vault; an expired one
/// stays (the proxy answers 401 with how to renew it); a Mac sign-out clears it at once (D5); a
/// different account signing in on the Mac is FOLLOWED (owner, 2026-10-23: "this should be
/// transparent to the sandboxes" — D6's hold is gone): the new identity is pinned and said once;
/// a locked or unreadable keychain keeps the last token and warns. `freshen()` (the vault's
/// `onBeforeUse`) notices a sign-in between polls from the config file's date, so the request
/// after `claude /login` already carries the new account's token.
public final class LoginWatcher: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case unknown, ok, expired, signedOut, unreadable
        public var label: String {
            switch self {
            case .unknown: "unknown"
            case .ok: "ok"
            case .expired: "expired"
            case .signedOut: "signed-out"
            case .unreadable: "unreadable"
            }
        }
    }

    public let account: String
    public let configDir: String?
    public let service: String
    let keychain: KeychainAccess
    let identityReader: @Sendable () -> ClaudeIdentity?
    /// The identity file's modification date (nil: none) — `freshen()`'s cheap look.
    let identityStamp: @Sendable () -> Date?
    /// 687: the credentials file read beside the Keychain item (nil: none — `ClaudeCredentialsFile.path`).
    let credentialsFile: @Sendable () -> String?

    private let lock = NSLock()
    private var _stamp: Date?
    private var _stampChecked = Date.distantPast
    private var _pinned: ClaudeIdentity?
    private var _seen: ClaudeIdentity?
    private var token: ClaudeLoginToken?
    private var _store: ClaudeLoginStore?
    private var _state: State = .unknown
    private var warnedUnreadable = false
    private var subscribers: [String: any CredentialTarget] = [:]
    private var _reads = 0
    /// 695: the runs made for one expiry — how many, the last one's time, and whether that expiry is done with.
    private var runsFor: (expiry: Date, count: Int, last: Date, done: Bool)?
    /// 695: the last skip reported (expiry + why) — a skip repeated at every look is recorded once.
    private var lastSkip: String?
    private var _standing = false
    /// 695: the times a look was set for (`scheduleLook`) — each only once.
    private var scheduled: Set<Date> = []
    private let runLock = NSLock()
    private var _keepalive: KeepaliveConfig?
    private var task: Task<Void, Never>?

    /// (sandbox or nil for the host, text) — the host turns these into events.
    public var onEvent: @Sendable (String?, String) -> Void = { _, _ in }
    /// The first identity seen while none is pinned (the host records it in accounts.json).
    public var onIdentity: @Sendable (ClaudeIdentity) -> Void = { _ in }

    public init(account: String, configDir: String?, keychain: KeychainAccess, pinned: ClaudeIdentity?,
                identityReader: (@Sendable () -> ClaudeIdentity?)? = nil, identityStamp: (@Sendable () -> Date?)? = nil,
                credentialsFile: (@Sendable () -> String?)? = nil) {
        self.account = account
        self.configDir = configDir
        self.service = ClaudeLogin.service(configDir: configDir)
        self.keychain = keychain
        self._pinned = pinned
        self.credentialsFile = credentialsFile ?? { ClaudeCredentialsFile.path(configDir: configDir) }
        self.identityReader = identityReader ?? { ClaudeLogin.identity(configDir: configDir) }
        self.identityStamp = identityStamp ?? {
            let path = ClaudeLogin.configFile(configDir: configDir).path
            return (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        }
    }

    public var state: State { lock.lock(); defer { lock.unlock() }; return _state }
    public var reads: Int { lock.lock(); defer { lock.unlock() }; return _reads }
    public var expiresAt: Date? { lock.lock(); defer { lock.unlock() }; return token?.expiresAt }
    /// 687: where the login in use was read from (the Keychain, or the credentials file).
    public var store: ClaudeLoginStore? { lock.lock(); defer { lock.unlock() }; return token == nil ? nil : _store }
    public var subscriberNames: [String] { lock.lock(); defer { lock.unlock() }; return subscribers.keys.sorted() }
    public var seenIdentity: ClaudeIdentity? { lock.lock(); defer { lock.unlock() }; return _seen }
    public var keepalive: KeepaliveConfig? {
        get { lock.lock(); defer { lock.unlock() }; return _keepalive }
        set { lock.lock(); _keepalive = newValue; lock.unlock() }
    }

    /// Follow whoever is signed in on the Mac now (`doz account use NAME mac`).
    public func repin(_ identity: ClaudeIdentity?) {
        lock.lock(); _pinned = identity; lock.unlock()
        readNow()
    }

    public func subscribe(_ name: String, _ sandbox: any CredentialTarget) {
        lock.lock()
        subscribers[name] = sandbox
        let first = _state == .unknown
        lock.unlock()
        if first { readNow() } else { lock.lock(); apply(name, sandbox); lock.unlock() }
    }

    public func unsubscribe(_ name: String) {
        lock.lock(); subscribers[name] = nil; lock.unlock()
    }

    public var isEmpty: Bool { lock.lock(); defer { lock.unlock() }; return subscribers.isEmpty }

    /// 695: kept by the daemon with no subscriber (`doz account keepalive always`) — never stopped for having none.
    public var standing: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _standing }
        set { lock.lock(); _standing = newValue; lock.unlock() }
    }

    /// Poll every `interval` (ContinuousClock: it counts across Mac sleep, so a wake reads soon).
    public func start(interval: Duration = .seconds(120)) {
        lock.lock(); defer { lock.unlock() }
        guard task == nil else { return }
        task = Task.detached { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, !Task.isCancelled else { return }
                self.tick()
            }
        }
    }

    public func stop() { lock.lock(); task?.cancel(); task = nil; lock.unlock() }

    /// One poll: read, fan out, and the keep-alive when it is due.
    public func tick(now: Date = Date()) {
        readNow(now: now)
        keepaliveIfDue(now: now)
    }

    /// A proxy found the token expired or had it refused upstream: read now; still expired → the
    /// keep-alive (when enabled) runs off the proxy's thread.
    public func stale(now: Date = Date()) {
        readNow(now: now)
        if state == .expired, keepalive?.enabled == true {
            DispatchQueue.global().async { [weak self] in self?.keepaliveIfDue(now: Date()) }
        }
    }

    /// Before a request uses the login: one `stat` of the identity file (at most once a second); when
    /// it changed and names another account than the one followed, read the keychain now — a Mac
    /// `claude /login` as someone else then reaches the very next request, not the next poll.
    public func freshen(now: Date = Date()) {
        lock.lock()
        guard now.timeIntervalSince(_stampChecked) >= 1 else { lock.unlock(); return }
        _stampChecked = now
        let before = _stamp
        lock.unlock()
        let stamp = identityStamp()
        guard stamp != before else { return }
        lock.lock(); _stamp = stamp; let followed = _seen; lock.unlock()
        let id = identityReader()
        if let id, let followed, id.sameAccount(as: followed) { return }
        if id == nil && followed == nil { return }
        readNow(now: now)
    }

    /// Read the login once — the keychain item, and (687) the credentials file beside it (`ClaudeMacLogin.choose`: the
    /// file only when it holds an unexpired login, the later expiry when both do) — and fan out whatever changed.
    public func readNow(now: Date = Date()) {
        let r = keychain.read(service: service, account: Keychain.user)
        let outcome = ClaudeMacLogin.choose(keychain: r, file: ClaudeCredentialsFile.read(credentialsFile()), now: now)
        let stamp = identityStamp()
        let identity: ClaudeIdentity? = { if case .token = outcome { return identityReader() }; return nil }()
        var events: [(String?, String)] = []
        var newIdentity: ClaudeIdentity?
        lock.lock()
        _reads += 1
        _stamp = stamp
        HostLog.line("\(account): read the keychain item \(service) for \(subscribers.count) sandbox(es)")
        let before = _state, beforeToken = token?.accessToken, beforeStore = _store
        switch outcome {
        case .token(let t, let store):
            do {                                    // (a block: the same lines as before the file was a store)
                warnedUnreadable = false
                if store != beforeStore, store == .file || beforeStore == .file {
                    events.append((nil, "\(account): this Mac's Claude login is read from \(store.label(configDir: configDir))"
                                   + (store == .file ? " (the Keychain's is older or not there — a login made over ssh)" : "")))
                }
                _store = store
                if let id = identity {
                    _seen = id
                    if _pinned == nil { _pinned = id; newIdentity = id }
                    else if let p = _pinned, !id.sameAccount(as: p) {
                        // Another account signed in on the Mac: follow it (no hold), and say so once.
                        _pinned = id
                        newIdentity = id
                        for name in subscribers.keys.sorted() {
                            events.append((name, "\(account): the Mac is now signed in as \(id.label) — \(name) uses it from now on"))
                        }
                    }
                }
                token = t
                _state = (t.expiresAt.map { $0 <= now } ?? false) ? .expired : .ok
            }
        case .unparsable:
            if !warnedUnreadable { events.append((nil, "\(account): Claude Code's keychain item \(service) has a format doz doesn't know — keeping the last token")) }
            warnedUnreadable = true
            if token == nil { _state = .unreadable }
        case .absent:
            token = nil
            _state = .signedOut
        case .locked, .failed:
            if !warnedUnreadable {
                events.append((nil, "\(account): could not read \(service) (\(r == .locked ? "the keychain is locked" : "security failed")) — keeping the last token"))
            }
            warnedUnreadable = true
            if token == nil { _state = .unreadable }
        }
        if _state != before || token?.accessToken != beforeToken {
            for (name, sb) in subscribers { apply(name, sb) }
            if _state != before, _state != .unknown {
                let text = describe(now: now)
                for name in subscribers.keys.sorted() { events.append((name, text)) }
            }
        }
        let expiry = token?.expiresAt
        lock.unlock()
        // 695: a look at the expiry (Claude Code renews only an expired token) — at once when it has expired already.
        if let expiry { scheduleLook(at: expiry) }
        if let newIdentity { onIdentity(newIdentity) }
        for (s, t) in events { onEvent(s, t) }
    }

    /// Under the lock.
    private func describe(now: Date) -> String {
        switch _state {
        case .ok: "\(account) login ok" + (token?.expiresAt.map { " (access expires \(CredentialVaultClock.hm($0)))" } ?? "")
        case .expired: "\(account) login expired at \(token?.expiresAt.map(CredentialVaultClock.hm) ?? "?") — it renews only while Claude Code runs on the Mac"
        case .signedOut: "\(account): Claude Code signed out on the Mac — the sandbox's token was cleared"
        case .unreadable: "\(account): the Mac login could not be read"
        case .unknown: ""
        }
    }

    /// Under the lock: what one subscriber's vault gets now.
    private func apply(_ name: String, _ sb: any CredentialTarget) {
        let b = CredentialBinding.claudeOAuth
        switch _state {
        case .ok, .expired:
            guard let t = token else { return }
            sb.setCredential(b, secret: t.accessToken, expiresAt: t.expiresAt, environment: t.sessionEnvironment,
                             notice: "this Mac's Claude login expired at \(t.expiresAt.map(CredentialVaultClock.hm) ?? "?") — open Claude Code on the Mac "
                                     + "(any prompt), then retry: this session recovers without a restart")
        case .signedOut:
            sb.setCredential(b, secret: nil, expiresAt: nil, environment: [:],
                             notice: "this Mac's Claude Code signed out — sign in again with `claude` on the Mac, or pick another account: "
                                     // 683: a fenced session on this Mac (`@mac SESSION`) chooses its account when it starts.
                                     + (name.hasPrefix(MacPlace.name + " ") ? "doz run @mac --account ACCOUNT …" : "doz account use \(name) ACCOUNT"))
        case .unreadable, .unknown:
            if token == nil {
                sb.setCredential(b, secret: nil, expiresAt: nil, environment: [:],
                                 notice: "doz could not read this Mac's Claude login (\(service)) — doz doctor says why")
            }
        }
    }

    /// D3 / 695: the Mac's own `claude -p`, when the access token has EXPIRED (`schedule`: at the expiry, then the retries) and — mode on —
    /// a subscriber (a sandbox, a fenced session) used it within `recentUse`; mode always needs no use. Never when this
    /// daemon cannot read the login keychain, when Claude Code is not installed, or while an UNFENCED Claude Code runs (it
    /// holds its own copy of the login, which a renewal by anyone else would cancel) — each skip recorded with its reason
    /// and retried at the next look. One run per expiry (a run that left the login unchanged is tried again, at most
    /// `maxRuns` per expiry). Off unless enabled. True: it ran.
    @discardableResult
    public func keepaliveIfDue(now: Date = Date()) -> Bool {
        lock.lock()
        guard let k = _keepalive, k.enabled, let t = token, let exp = t.expiresAt,
              _state == .ok || _state == .expired else {
            lock.unlock(); return false
        }
        let done0 = runsFor.map { $0.expiry == exp ? $0.count : 0 } ?? 0
        guard !(runsFor?.expiry == exp && runsFor?.done == true),
              let due = KeepaliveSchedule.due(expiry: exp, runs: done0, schedule: k.schedule), now >= due else {
            lock.unlock(); return false
        }
        if k.mode == .on {
            let used = subscribers.values.contains { sb in
                sb.egress?.vault.lastUsed(CredentialBinding.claudeOAuth.id).map { now.timeIntervalSince($0) <= k.recentUse } ?? false
            }
            guard used else { lock.unlock(); return false }
        }
        lock.unlock()
        func skip(_ key: String, _ reason: String) -> Bool {
            let news = lock.withLock { () -> Bool in
                let id = "\(exp.timeIntervalSince1970)|\(key)"
                defer { lastSkip = id }
                return lastSkip != id
            }
            guard news else { return false }
            onEvent(nil, "\(account): \(reason)")
            k.report(KeepaliveRecord(account: account, mode: k.mode.rawValue, lastAttemptAt: now, outcome: .skipped,
                                     reason: reason.replacingOccurrences(of: "keep-alive skipped — ", with: ""), expiresBefore: exp,
                                     nextTryAt: now.addingTimeInterval(120)))
            return false
        }
        if let why = k.keychainLocked() {
            return skip("locked", "keep-alive skipped — this daemon was started where the login keychain is locked (\(why)): it never runs "
                        + "this Mac's Claude Code. doz daemon restart from your desktop session (or doz daemon login-item on) starts one that can")
        }
        guard let bin = k.binary() else {
            return skip("no-claude", "keep-alive skipped — Claude Code isn't installed on this Mac")
        }
        let look = k.holders()
        if let h = look.holders.first {
            return skip("holder-\(h.pid)", "keep-alive skipped — \(h.label) holds its own copy of this Mac's login; renewing now would cancel "
                        + "that copy. It renews when that Claude Code is next used.")
        }
        // One run at a time, and claimed for this expiry before it starts.
        guard runLock.try() else { return false }
        defer { runLock.unlock() }
        let claimed: Int? = lock.withLock {
            // Again under the lock: a look that raced this one may have run (and finished) meanwhile.
            let before = runsFor.map { $0.expiry == exp ? $0.count : 0 } ?? 0
            if runsFor?.expiry == exp && runsFor?.done == true { return nil }
            guard let due = KeepaliveSchedule.due(expiry: exp, runs: before, schedule: k.schedule), now >= due else { return nil }
            let n = before + 1
            runsFor = (exp, n, now, false)
            lastSkip = nil
            return n
        }
        guard let attempt = claimed else { return false }
        let fenced = look.fenced.map { "\($0.session ?? "?") pid \($0.pid)" }
        HostLog.line("\(account): keep-alive run \(attempt) for the login expiring \(CredentialVaultClock.hm(exp))"
                     + (fenced.isEmpty ? "" : " — fenced sessions' Claude Code left out (they hold a placeholder, not the login): " + fenced.joined(separator: ", ")))
        onEvent(nil, "\(account): keep-alive — the login expires \(CredentialVaultClock.hm(exp))"
                + (k.mode == .always ? "" : " and a sandbox or session is using it") + ": running the Mac's Claude Code once")
        let dir = Self.freshRunDirectory(k.runDirectory)
        let r = k.runner.runCapturing(binary: bin, arguments: KeepaliveConfig.arguments, environment: Self.scrubbedEnvironment(configDir: configDir),
                                      directory: dir, timeout: 120)
        readNow(now: Date())
        let after = expiresAt
        var outcome: KeepaliveRecord.Outcome = r.code != 0 ? .failed : ((after ?? .distantPast) > exp ? .renewed : .unchanged)
        let retry = outcome == .unchanged ? KeepaliveSchedule.due(expiry: exp, runs: attempt, schedule: k.schedule) : nil
        if outcome == .unchanged && retry == nil { outcome = .failed }
        let reason: String? = {
            switch outcome {
            case .failed where r.code == 0:
                return "Claude Code did not renew the login after \(attempt) tries (exit 0 each time) — run claude on the Mac to see why"
            case .failed:
                let what = r.code == -2 ? "timed out after 120 s" : r.code == -1 ? "could not start \(bin)" : "exit \(r.code)"
                return what + (r.lastErrorLine.map { ": " + KeepaliveRecord.clean($0) } ?? "")
            case .unchanged: return "Claude Code did not renew the login (the token had not expired yet) — tried again"
            default: return nil
            }
        }()
        lock.withLock { runsFor = (exp, attempt, now, outcome != .unchanged) }
        let next: Date? = outcome == .renewed ? after : retry
        k.report(KeepaliveRecord(account: account, mode: k.mode.rawValue, lastAttemptAt: now, outcome: outcome, reason: reason, exit: r.code,
                                 expiresBefore: exp, expiresAfter: after, nextTryAt: next))
        if let next { scheduleLook(at: next) }
        onEvent(nil, "\(account): keep-alive finished (\(outcome == .failed ? reason ?? "failed" : "exit \(r.code)")); the login now "
                + (state == .ok ? "is ok" + (after.map { " until \(CredentialVaultClock.hm($0))" } ?? "") : "is \(state.label)"))
        return true
    }

    /// 695: a look at `at` (+1 s), once per time — the expiry, or a retry — when the keep-alive keeps timers (the daemon).
    func scheduleLook(at: Date) {
        guard let k = keepalive, k.enabled, k.timers else { return }
        let fresh: Bool = lock.withLock { scheduled.insert(at).inserted }
        guard fresh else { return }
        let delay = max(0, at.timeIntervalSinceNow) + 1
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.readNow(now: Date())
            self.keepaliveIfDue(now: Date())
        }
    }

    /// 695: the run's folder, made fresh and empty (0700) each time: `dir` removed and made again (nil: a new temporary one).
    static func freshRunDirectory(_ dir: URL?) -> URL {
        let fm = FileManager.default
        if let dir {
            try? fm.removeItem(at: dir)
            try? fm.createDirectory(at: dir.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            chmod(dir.deletingLastPathComponent().path, 0o700)
            if (try? fm.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])) != nil {
                chmod(dir.path, 0o700)
                return dir
            }
        }
        var template = Array((fm.temporaryDirectory.path + "/doz-keepalive-XXXXXX").utf8CString)
        guard let made = mkdtemp(&template) else { return fm.temporaryDirectory }
        return URL(fileURLWithPath: String(cString: made))
    }

    /// PATH, HOME, USER, LANG, TMPDIR — never ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN (they
    /// would override the login this run exists to renew).
    public static func scrubbedEnvironment(configDir: String?, from env: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var out: [String: String] = [:]
        for k in ["PATH", "HOME", "USER", "LOGNAME", "LANG", "TMPDIR", "SHELL"] { if let v = env[k] { out[k] = v } }
        if let d = configDir { out["CLAUDE_CONFIG_DIR"] = d }
        return out
    }
}

public enum CredentialVaultClock {
    public static func hm(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }
}
