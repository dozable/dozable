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

    /// A VM worker's stand-ins in a guarded run only (`make test-cli-workspace-vm`): `DOZ_TEST_WORKER_IMAGE` (an image
    /// instead of the agent's — `lab`) and `DOZ_TEST_WORKER_ARGV` (a JSON array: a FAKE worker program, its first prompt
    /// appended). Unguarded, both are nil whatever the environment says.
    public static func workerSeams(_ env: [String: String] = ProcessInfo.processInfo.environment) -> (image: String?, argv: [String]?) {
        guard guarded(env) else { return (nil, nil) }
        return (env["DOZ_TEST_WORKER_IMAGE"], env["DOZ_TEST_WORKER_ARGV"].flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) })
    }

    /// 749: the stub agent in place of every workspace agent program on this Mac (`StubAgent`) — `DOZ_TEST_STUB_AGENT=1`, in a
    /// guarded run only. Unguarded it is false whatever the environment says.
    public static func stubAgent(_ env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        guarded(env) && env[StubAgent.variable] == "1"
    }

    /// 749: why `doz debug crash` is refused (nil: allowed) — outside a guarded run, always.
    public static func debugCrashViolation(_ env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        guarded(env) ? nil : "doz debug crash is a test hook: it runs only in a guarded test run (DOZ_TEST_GUARD=1)"
    }

    /// The person's real home (never `$HOME`, which a test may point elsewhere — the danger is the REAL one).
    public static var realHome: URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir { return URL(fileURLWithPath: String(cString: dir)) }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// 755: the home a space file's `~` stands for (its folders, its brief, `extends:`, a `prompt_file`, and the place
    /// `doz workspace doc --write` and the recorded files must be under): the person's real one — in a guarded test run
    /// (`DOZ_TEST_GUARD=1`), `DOZ_TEST_HOME` when it is an absolute path, so a harness's scratch home stands in for it.
    /// Unguarded it is always the real home, whatever the environment says. `TestSafetyTests.testASpaceFilesHome`.
    public static func spaceHome(_ env: [String: String] = ProcessInfo.processInfo.environment) -> String {
        // In Foundation's spelling (`/private/tmp/x` reads `/tmp/x`), the one a standardized path under it has: the place
        // rules then see both spellings (`SpaceRecordFile.placeRefusal` adds the resolved one).
        if guarded(env, inXCTest: false), let t = env["DOZ_TEST_HOME"], t.hasPrefix("/") { return URL(fileURLWithPath: t).standardizedFileURL.path }
        return realHome.path
    }

    /// `~` and `~/…` in a space file's path, from `spaceHome` (anything else as it is).
    public static func expandSpaceTilde(_ p: String, home: String = spaceHome()) -> String {
        p == "~" ? home : p.hasPrefix("~/") ? home + String(p.dropFirst(1)) : p
    }

    /// 751: whether `doz daemon stop` also ends the sessions on this Mac its store holds (the `deckhold-mac serve` holders
    /// in that store's own socket folder): only in a guarded test run, and only for a store that is not the default one — so
    /// a test that forgets `workspace finish` leaks no holder. Outside a test a person's `@mac` sessions outlive the daemon
    /// by design (docs/engineering/engine.md, "A guarded stop ends its store's sessions"). A test that proves exactly that
    /// survival keeps them with `DOZ_TEST_KEEP_MAC_SESSIONS=1` in the daemon's environment (`make test-cli`'s harness sets it
    /// by default; its T9 row runs a daemon without it).
    public static func endsHeldSessionsAtStop(store: URL, env: [String: String] = ProcessInfo.processInfo.environment,
                                              inXCTest: Bool = NSClassFromString("XCTestCase") != nil, home: URL = realHome) -> Bool {
        guarded(env, inXCTest: inXCTest) && env[keepMacSessionsVariable] != "1" && storeViolation(store, home: home) == nil
    }

    /// A guarded test's way to keep its store's sessions on this Mac across `doz daemon stop` (`endsHeldSessionsAtStop`).
    public static let keepMacSessionsVariable = "DOZ_TEST_KEEP_MAC_SESSIONS"

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

    /// Why writing an unfenced workspace manager's token file for `store` is refused (nil: allowed): its temp folder is named
    /// by the store, so a test writes one only for a scratch store — never the person's (`<temp>/doz-<default store's hex>`).
    public static func managerTokenViolation(store: URL, home: URL = realHome) -> String? {
        storeViolation(store, home: home).map { _ in
            "a test would write a manager's token file for the DEFAULT store — give it a scratch store (--store / DOZ_STORE)"
        }
    }

    /// Where a guarded run's "Bin" is (`DOZ_TEST_TRASH_DIR`), and why moving `folder` there is refused (nil: allowed). A test
    /// never reaches the real Bin: with no seam set, a move is refused; and the seam only ever takes a scratch folder
    /// (under the temporary folders) — never a person's own, whatever went wrong before it.
    public static func trashDirectory(_ env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        guard guarded(env) else { return nil }
        return env["DOZ_TEST_TRASH_DIR"].flatMap { $0.isEmpty ? nil : $0 }
    }

    public static func trashViolation(folder: String, env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        guard guarded(env) else { return nil }
        guard trashDirectory(env) != nil else { return "a test would move \(folder) to the real Bin — set DOZ_TEST_TRASH_DIR to a scratch folder" }
        let scratch = ["/tmp/", "/private/tmp/", "/var/folders/", "/private/var/folders/"]
        guard scratch.contains(where: { folder.hasPrefix($0) }) else { return "a test would move \(folder) to the Bin — only a scratch folder under the temporary folders" }
        return nil
    }

    /// Why a guarded run may not MAKE the folder `path` (nil: it may) — a project, run or scratch folder under
    /// `defaults.projects_dir`, a manager's or a worker's own folder, `--new-folder`: one under the person's REAL home is
    /// refused (a run that never set `defaults.projects_dir` to a scratch path resolves the real `~/doz-workspaces`), unless it
    /// is under `DOZ_TEST_HOME` (when set) or a scratch temporary folder. Unguarded: always nil. `TestSafetyTests`.
    public static func projectsDirViolation(_ path: String, home: URL = realHome,
                                            env: [String: String] = ProcessInfo.processInfo.environment,
                                            inXCTest: Bool = NSClassFromString("XCTestCase") != nil) -> String? {
        guard guarded(env, inXCTest: inXCTest) else { return nil }
        let p = URL(fileURLWithPath: path).standardizedFileURL.path
        func under(_ root: String) -> Bool { let r = root.hasSuffix("/") ? String(root.dropLast()) : root; return p == r || p.hasPrefix(r + "/") }
        let scratch = ["/tmp", "/private/tmp", "/var/folders", "/private/var/folders"]
        if scratch.contains(where: under) { return nil }
        if let t = env["DOZ_TEST_HOME"], t.hasPrefix("/"), under(URL(fileURLWithPath: t).standardizedFileURL.path) { return nil }
        let h = home.standardizedFileURL.path
        guard under(h) else { return nil }
        return "a test would make the folder \(p) under your real home — set defaults.projects_dir to a scratch folder (doz config set defaults.projects_dir /tmp/…) in the test's scratch XDG_CONFIG_HOME"
    }

    /// Stop a guarded run that is about to make `path` where `projectsDirViolation` refuses it.
    public static func checkMadeFolder(_ path: String, env: [String: String] = ProcessInfo.processInfo.environment) {
        enforce(projectsDirViolation(path, env: env), env: env)
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
