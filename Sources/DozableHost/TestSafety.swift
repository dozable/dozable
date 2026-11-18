import Foundation

/// Test safety by default (611). Tests and probes must never reach the person's real Dozable: the default store,
/// the Mac's own `~/.codex`, or the login keychain's Claude Code item. Three agents leaked into a real login in
/// one month, each through a test that forgot ONE seam — so the seams are the Makefile's DEFAULT for every test
/// target (`DOZ_TEST_GUARD=1` and the scratch values beside it), and this guard turns a forgotten one into a
/// hard stop instead of a quiet read of real data.
///
/// The guard is on when `DOZ_TEST_GUARD=1` (every `make test*` target, the probes' `guard-doz.sh`) or inside
/// XCTest, and off only when the run says so explicitly: `DOZ_TEST_REAL_MAC=1` (a person deliberately testing
/// against this Mac). It never changes behaviour outside a test run.
///
/// The decisions are pure functions (unit-tested); `enforce` stops the process with the reason.
public enum TestSafety {
    /// Is this process a guarded test run?
    public static func guarded(_ env: [String: String] = ProcessInfo.processInfo.environment,
                               inXCTest: Bool = NSClassFromString("XCTestCase") != nil) -> Bool {
        if env["DOZ_TEST_REAL_MAC"] == "1" { return false }
        return env["DOZ_TEST_GUARD"] == "1" || inXCTest
    }

    /// The person's real home (never `$HOME`, which a test may point elsewhere — the danger is the REAL one).
    public static var realHome: URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir { return URL(fileURLWithPath: String(cString: dir)) }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// The default store a person's Dozable uses.
    public static func defaultStore(home: URL = realHome) -> URL {
        home.appendingPathComponent("Library/Application Support/doz").standardizedFileURL
    }

    /// Why using `store` is refused in a guarded run (nil: allowed). The default store and anything inside it.
    public static func storeViolation(_ store: URL, home: URL = realHome) -> String? {
        let d = defaultStore(home: home).path
        let s = store.standardizedFileURL.resolvingSymlinksInPath().path
        guard s == d || s.hasPrefix(d + "/") || store.standardizedFileURL.path == d else { return nil }
        return "a test resolved the DEFAULT store (\(d)) — give it a scratch store (--store / DOZ_STORE, and store.path in a scratch XDG_CONFIG_HOME)"
    }

    // `codexHomeViolation` lives in CodexMacLogin.swift — the one file that may name the Mac's Codex home.

    /// Why touching keychain item `service` is refused (nil: allowed). Claude Code's own login items.
    public static func keychainViolation(service: String) -> String? {
        // A chat webhook entry (an address and a secret) is never put in, or read from, the real login keychain by a test:
        // the tests' keychain is the memory seam.
        if service.hasPrefix(ChatWebhookEntries.servicePrefix) {
            return "a test reached the login keychain's chat webhook item (\(service)) — set DOZ_TEST_CREDENTIALS=memory"
        }
        // Nor a bot's token: the tests' keychain is the memory seam.
        if service.hasPrefix(BotTokens.servicePrefix) {
            return "a test reached the login keychain's bot token item (\(service)) — set DOZ_TEST_CREDENTIALS=memory"
        }
        guard service.hasPrefix(ClaudeLogin.baseService) else { return nil }
        return "a test reached the login keychain's Claude Code item (\(service)) — set DOZ_TEST_CREDENTIALS=memory and DOZ_TEST_NO_MAC_LOGIN=1"
    }

    /// 687: why reading Claude Code's credentials file at `path` is refused (nil: allowed) — a `.credentials.json` in the
    /// person's REAL home (`~/.claude`, or any config folder there). A guarded run reads only its seam
    /// (`DOZ_TEST_CLAUDE_CREDENTIALS_FILE`, a scratch file).
    public static func claudeCredentialsFileViolation(_ path: String, home: URL = realHome) -> String? {
        guard (path as NSString).lastPathComponent == ".credentials.json" else { return nil }
        let p = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        let h = home.standardizedFileURL.resolvingSymlinksInPath().path
        guard p == h || p.hasPrefix(h + "/") else { return nil }
        return "a test reached Claude Code's credentials file (\(path)) — give it a scratch one (DOZ_TEST_CLAUDE_CREDENTIALS_FILE)"
    }

    /// Why handing the chat server `path` as Claude Code's sessions folder is refused in a guarded run (nil: allowed) —
    /// anything under the person's REAL `~/.claude`: a test never reads a real session's record or key, nor connects to
    /// its socket. A guarded run uses its seam (`DOZ_TEST_CLAUDE_SESSIONS`, a scratch folder the Makefile sets).
    public static func claudeSessionsViolation(_ path: String, home: URL = realHome) -> String? {
        let real = home.appendingPathComponent(".claude").standardizedFileURL
        let r = real.resolvingSymlinksInPath().path
        let p = URL(fileURLWithPath: path).standardizedFileURL
        let d = p.resolvingSymlinksInPath().path
        guard d == r || d.hasPrefix(r + "/") || p.path == real.path || p.path.hasPrefix(real.path + "/") else { return nil }
        return "a test would hand the chat server Claude Code's real sessions folder (\(path)) — give it a scratch one (DOZ_TEST_CLAUDE_SESSIONS)"
    }

    /// 694: a test run of any kind — guarded, or one that lifted the guard on purpose (`DOZ_TEST_REAL_MAC=1`). The login
    /// item's seams (`DOZ_TEST_LAUNCH_AGENTS_DIR`, `DOZ_TEST_LAUNCHCTL`) are honoured in both: a run against this Mac's
    /// own login still never writes a login item. A person's doz is neither, and ignores them.
    public static func testRun(_ env: [String: String] = ProcessInfo.processInfo.environment,
                               inXCTest: Bool = NSClassFromString("XCTestCase") != nil) -> Bool {
        guarded(env, inXCTest: inXCTest) || env["DOZ_TEST_REAL_MAC"] == "1"
    }

    /// 694: the person's real per-user LaunchAgents folder (`~/Library/LaunchAgents` of the REAL home).
    public static func realLaunchAgents(home: URL = realHome) -> URL {
        home.appendingPathComponent("Library/LaunchAgents").standardizedFileURL
    }

    /// 694: why touching `dir` (reading, writing or removing a login item there) is refused in a guarded run (nil:
    /// allowed) — the real `~/Library/LaunchAgents` or anything inside it. A guarded run uses its seam
    /// (`DOZ_TEST_LAUNCH_AGENTS_DIR`, a scratch folder the Makefile sets for every test target).
    public static func launchAgentsViolation(_ dir: URL, home: URL = realHome) -> String? {
        let real = realLaunchAgents(home: home)
        let r = real.resolvingSymlinksInPath().path
        let d = dir.standardizedFileURL.resolvingSymlinksInPath().path
        let plain = dir.standardizedFileURL.path
        guard d == r || d.hasPrefix(r + "/") || plain == real.path || plain.hasPrefix(real.path + "/") else { return nil }
        return "a test reached ~/Library/LaunchAgents (\(dir.path)) — give it a scratch folder (DOZ_TEST_LAUNCH_AGENTS_DIR)"
    }

    /// 694: the real launchctl.
    public static let realLaunchctl = "/bin/launchctl"

    /// 694: why running `path` as launchctl is refused in a guarded run (nil: allowed) — the real `/bin/launchctl`, for
    /// any verb (a `print` too: a guarded run reads launchd's state only through its seam, `DOZ_TEST_LAUNCHCTL`).
    public static func launchctlViolation(_ path: String) -> String? {
        let p = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        guard p == realLaunchctl || path == realLaunchctl || (path as NSString).lastPathComponent == "launchctl" && p.hasPrefix("/bin/") else { return nil }
        return "a test would run the real launchctl (\(path)) — give it a fake one (DOZ_TEST_LAUNCHCTL)"
    }

    /// 695: why running `binary` as the login keep-alive's Claude Code is refused in a guarded run (nil: allowed) — anything
    /// but the test seam `DOZ_TEST_CLAUDE_BIN` (a fake). The real `claude -p` renews THIS Mac's login, and a renewal by one
    /// holder cancels the copy every other running Claude Code holds (the session running the tests among them).
    public static func keepaliveClaudeViolation(_ binary: String, env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        func resolved(_ p: String) -> String { URL(fileURLWithPath: p).standardizedFileURL.resolvingSymlinksInPath().path }
        if let seam = env["DOZ_TEST_CLAUDE_BIN"], seam.hasPrefix("/"), resolved(seam) == resolved(binary) { return nil }
        return "a test would run \(binary) as the login keep-alive's claude — the real one renews this Mac's Claude login and "
            + "cancels the copy every running Claude Code holds; give it a fake one (DOZ_TEST_CLAUDE_BIN)"
    }

    /// The real folders a menu bar app is installed into: `/Applications` and the REAL home's `~/Applications`.
    public static func realApplicationsFolders(home: URL = realHome) -> [URL] {
        [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications").standardizedFileURL]
    }

    /// Why installing into, removing from or looking in `dir` for the menu bar app is refused in a guarded run (nil:
    /// allowed) — `/Applications`, the real `~/Applications`, or anything inside either. A guarded run uses `--dest` or its
    /// seam (`DOZ_TEST_APPLICATIONS_DIR`, a scratch folder the Makefile sets for every test target).
    public static func applicationsViolation(_ dir: URL, home: URL = realHome) -> String? {
        let d = dir.standardizedFileURL.resolvingSymlinksInPath().path
        let plain = dir.standardizedFileURL.path
        for real in realApplicationsFolders(home: home) {
            let r = real.resolvingSymlinksInPath().path
            if d == r || d.hasPrefix(r + "/") || plain == real.path || plain.hasPrefix(real.path + "/") {
                return "a test reached \(real.path) (\(dir.path)) — give it a scratch folder (--dest, or DOZ_TEST_APPLICATIONS_DIR)"
            }
        }
        return nil
    }

    /// Why asking macOS to OPEN an app (`/usr/bin/open`, LaunchServices — `doz app install --open`) is refused in a guarded
    /// run (nil: allowed): a test records what it would open in its seam `DOZ_TEST_APP_OPEN_LOG` (an absolute path) and
    /// opens nothing. Opening a scratch bundle has LaunchServices register it and Gatekeeper judge it — a dialog on the
    /// person's screen ("“Dozable” is damaged and can't be opened") when it is not a whole, signed copy.
    public static func appOpenViolation(env: [String: String] = ProcessInfo.processInfo.environment,
                                        inXCTest: Bool = NSClassFromString("XCTestCase") != nil) -> String? {
        guard guarded(env, inXCTest: inXCTest) else { return nil }
        if let log = env["DOZ_TEST_APP_OPEN_LOG"], log.hasPrefix("/") { return nil }
        return "a test would ask macOS to open an app — give it the seam DOZ_TEST_APP_OPEN_LOG (nothing is opened then)"
    }

    /// Stop a guarded run that is about to do what `violation` describes.
    public static func enforce(_ violation: String?, env: [String: String] = ProcessInfo.processInfo.environment) {
        guard let violation, guarded(env) else { return }
        FileHandle.standardError.write(Data("doz: TEST SAFETY: \(violation). (DOZ_TEST_REAL_MAC=1 lifts this guard deliberately.)\n".utf8))
        fatalError("TEST SAFETY: \(violation)")
    }

    public static func checkStore(_ store: URL, env: [String: String] = ProcessInfo.processInfo.environment) {
        guard guarded(env) else { return }
        enforce(storeViolation(store), env: env)
    }
}
