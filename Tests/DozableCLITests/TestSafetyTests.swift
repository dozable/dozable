import XCTest
@testable import DozableHost
@testable import DozableCLI

/// 611: test safety by default — the guard's decisions, one by one (a forgotten seam STOPS a test run).
final class TestSafetyTests: XCTestCase {
    let home = URL(fileURLWithPath: "/Users/someone")

    func testGuardedByTheMakefileSeamOrXCTestAndLiftedOnlyExplicitly() {
        XCTAssertTrue(TestSafety.guarded(["DOZ_TEST_GUARD": "1"], inXCTest: false))
        XCTAssertTrue(TestSafety.guarded([:], inXCTest: true))
        XCTAssertFalse(TestSafety.guarded([:], inXCTest: false), "a person's doz is never guarded")
        XCTAssertFalse(TestSafety.guarded(["DOZ_TEST_GUARD": "1", "DOZ_TEST_REAL_MAC": "1"], inXCTest: true))
        XCTAssertTrue(TestSafety.guarded(["DOZ_TEST_GUARD": "1", "DOZ_TEST_REAL_MAC": "yes"], inXCTest: false),
                      "only the exact opt-out lifts it")
    }

    func testTheDefaultStoreAndAnythingInsideItAreRefused() {
        let d = home.appendingPathComponent("Library/Application Support/doz")
        XCTAssertNotNil(TestSafety.storeViolation(d, home: home))
        XCTAssertNotNil(TestSafety.storeViolation(d.appendingPathComponent("sandboxes/x"), home: home))
        XCTAssertNotNil(TestSafety.storeViolation(URL(fileURLWithPath: d.path + "/./"), home: home))
        XCTAssertNil(TestSafety.storeViolation(URL(fileURLWithPath: "/tmp/doz-test-store"), home: home))
        XCTAssertNil(TestSafety.storeViolation(home.appendingPathComponent("Library/Application Support/doz-other"), home: home))
    }

    func testTheRealCodexHomeIsRefusedAndAScratchOneIsNot() {
        XCTAssertNotNil(TestSafety.codexHomeViolation(home.appendingPathComponent(".codex"), home: home))
        XCTAssertNotNil(TestSafety.codexHomeViolation(URL(fileURLWithPath: "/Users/someone/x/../.codex"), home: home))
        XCTAssertNil(TestSafety.codexHomeViolation(URL(fileURLWithPath: "/tmp/codex-home"), home: home))
    }

    func testClaudeCodesKeychainItemsAreRefusedAndDozablesOwnAreNot() {
        XCTAssertNotNil(TestSafety.keychainViolation(service: "Claude Code-credentials"))
        XCTAssertNotNil(TestSafety.keychainViolation(service: ClaudeLogin.service(configDir: "/tmp/x")))
        XCTAssertNil(TestSafety.keychainViolation(service: "doz-anthropic:work"))
        XCTAssertNil(TestSafety.keychainViolation(service: "doz-test-limit-1"))
        // A bot's token: never in the real keychain from a test.
        XCTAssertNotNil(TestSafety.keychainViolation(service: BotTokens.service(store: URL(fileURLWithPath: "/tmp/s"), name: "mira")))
    }

    /// The Bin: a guarded run never reaches the real one — no seam, no move; the seam takes only a scratch folder.
    func testTheBinIsTheTestsOwnAndTakesOnlyAScratchFolder() {
        let g = ["DOZ_TEST_GUARD": "1"]
        XCTAssertNotNil(TestSafety.trashViolation(folder: "/tmp/x", env: g), "no DOZ_TEST_TRASH_DIR: refused")
        let seam = g.merging(["DOZ_TEST_TRASH_DIR": "/tmp/bin"]) { a, _ in a }
        XCTAssertEqual(TestSafety.trashDirectory(seam), "/tmp/bin")
        XCTAssertNil(TestSafety.trashViolation(folder: "/private/tmp/work", env: seam))
        XCTAssertNil(TestSafety.trashViolation(folder: "/private/var/folders/ab/T/work", env: seam))
        XCTAssertNotNil(TestSafety.trashViolation(folder: "/Users/someone/Documents", env: seam), "never a person's folder")
        XCTAssertNil(TestSafety.trashDirectory(["DOZ_TEST_TRASH_DIR": "/tmp/bin", "DOZ_TEST_REAL_MAC": "1"]), "unguarded: the real Bin")
    }

    /// A guarded run never MAKES a project, run or scratch folder under the real home — the real `~/doz-workspaces` an unset
    /// `defaults.projects_dir` resolves; a scratch one, and one under `DOZ_TEST_HOME`, are allowed; unguarded nothing changes.
    func testAGuardedRunNeverMakesAFolderInTheRealProjectsFolder() {
        let home = URL(fileURLWithPath: "/Users/someone")
        let g = ["DOZ_TEST_GUARD": "1"]
        func v(_ p: String, _ env: [String: String] = g) -> String? { TestSafety.projectsDirViolation(p, home: home, env: env, inXCTest: false) }
        XCTAssertNotNil(v("/Users/someone/doz-workspaces"), "the real projects root")
        XCTAssertNotNil(v("/Users/someone/doz-workspaces/.runs/rs/2026-11-23-1/scratch"), "a run's scratch folder in it")
        XCTAssertNotNil(v("/Users/someone/doz-workspaces/app/bot1"), "a worker's folder in it")
        XCTAssertNotNil(v("/Users/someone/doz-workspaces/../code/x"), "standardized first")
        XCTAssertTrue(v("/Users/someone/doz-workspaces")?.contains("defaults.projects_dir") == true, "the reason names the fix")
        XCTAssertNil(v("/private/tmp/dzo-1-projects/.runs/rs/r/scratch"), "a scratch projects folder")
        XCTAssertNil(v("/tmp/x"))
        XCTAssertNil(v("/private/var/folders/ab/T/x"))
        XCTAssertNil(v("/Users/elsewhere/doz-workspaces/x"), "not the real home")
        let th = g.merging(["DOZ_TEST_HOME": "/Users/someone/scratch-home"]) { a, _ in a }
        XCTAssertNil(v("/Users/someone/scratch-home/doz-workspaces/x", th), "under DOZ_TEST_HOME")
        XCTAssertNotNil(v("/Users/someone/doz-workspaces/x", th), "DOZ_TEST_HOME does not open the rest of the home")
        XCTAssertNil(v("/Users/someone/doz-workspaces/x", ["DOZ_TEST_GUARD": "1", "DOZ_TEST_REAL_MAC": "1"]), "lifted deliberately: unchanged")
        XCTAssertNil(v("/Users/someone/doz-workspaces/x", [:]), "unguarded: unchanged")
    }

    func testEnforceIsSilentWhenNotGuardedOrNothingIsWrong() {
        TestSafety.enforce(nil, env: ["DOZ_TEST_GUARD": "1"])
        TestSafety.enforce("anything", env: ["DOZ_TEST_REAL_MAC": "1"])
        TestSafety.checkStore(URL(fileURLWithPath: "/tmp/doz-ok"), env: ["DOZ_TEST_GUARD": "1"])
    }

    /// The CLI's own looks at the Mac's Claude login use an empty in-memory keychain under either seam.
    func testTheMacLoginKeychainIsAFakeUnderTheSeams() {
        XCTAssertTrue(macLoginKeychain(["DOZ_TEST_NO_MAC_LOGIN": "1"]) is MemoryKeychain)
        XCTAssertTrue(macLoginKeychain(["DOZ_TEST_CREDENTIALS": "memory"]) is MemoryKeychain)
        XCTAssertTrue(macLoginKeychain([:]) is SystemKeychain)
    }

    /// 694: the real ~/Library/LaunchAgents (and anything in it) and the real launchctl are refused; scratch ones are not.
    func testTheRealLaunchAgentsAndLaunchctlAreRefused() {
        XCTAssertNotNil(TestSafety.launchAgentsViolation(home.appendingPathComponent("Library/LaunchAgents"), home: home))
        XCTAssertNotNil(TestSafety.launchAgentsViolation(home.appendingPathComponent("Library/LaunchAgents/com.dozable.daemon.0a1b2c3d.plist"), home: home))
        XCTAssertNotNil(TestSafety.launchAgentsViolation(URL(fileURLWithPath: "/Users/someone/x/../Library/LaunchAgents"), home: home))
        XCTAssertNil(TestSafety.launchAgentsViolation(URL(fileURLWithPath: "/tmp/doz-test-launchagents"), home: home))
        XCTAssertNil(TestSafety.launchAgentsViolation(home.appendingPathComponent("Library/LaunchAgentsX"), home: home))
        XCTAssertNotNil(TestSafety.launchctlViolation("/bin/launchctl"))
        XCTAssertNotNil(TestSafety.launchctlViolation("/bin/../bin/launchctl"))
        XCTAssertNil(TestSafety.launchctlViolation("/tmp/fake-launchctl.py"))
    }

    /// 694: the seams decide the folder and the program in a test run; outside one (a person's doz) they are ignored.
    func testTheLoginItemSeams() {
        let scratch = LaunchAgentsFolder.current(environment: ["DOZ_TEST_GUARD": "1", "DOZ_TEST_LAUNCH_AGENTS_DIR": "/tmp/doz-la-seam"])
        XCTAssertEqual(scratch.path, "/tmp/doz-la-seam")
        XCTAssertEqual(Launchctl.current(environment: ["DOZ_TEST_GUARD": "1", "DOZ_TEST_LAUNCHCTL": "/tmp/fake-lc"]).path, "/tmp/fake-lc")
        XCTAssertFalse(TestSafety.testRun(["DOZ_TEST_LAUNCH_AGENTS_DIR": "/tmp/x"], inXCTest: false))
        XCTAssertTrue(TestSafety.testRun(["DOZ_TEST_REAL_MAC": "1"], inXCTest: false))
    }

    /// 695: the login keep-alive may run only the fake claude in a test — never the Mac's own (it would renew THIS Mac's
    /// login and cancel the copy of every running Claude Code). Anything else is a violation, the seam's own path is not.
    func testTheKeepaliveRunsOnlyTheFakeClaude() throws {
        let real = home.appendingPathComponent(".local/bin/claude").path
        XCTAssertNotNil(TestSafety.keepaliveClaudeViolation(real, env: ["DOZ_TEST_GUARD": "1"]))
        XCTAssertNotNil(TestSafety.keepaliveClaudeViolation("/opt/homebrew/bin/claude", env: ["DOZ_TEST_GUARD": "1"]))
        XCTAssertNotNil(TestSafety.keepaliveClaudeViolation(real, env: ["DOZ_TEST_CLAUDE_BIN": "/tmp/fake-claude"]), "another program than the seam's")
        XCTAssertNotNil(TestSafety.keepaliveClaudeViolation("/tmp/x/claude", env: ["DOZ_TEST_CLAUDE_BIN": "relative/claude"]), "a relative seam is no seam")
        XCTAssertNil(TestSafety.keepaliveClaudeViolation("/tmp/fake-claude", env: ["DOZ_TEST_CLAUDE_BIN": "/tmp/fake-claude"]))
        XCTAssertNil(TestSafety.keepaliveClaudeViolation("/tmp/./fake-claude", env: ["DOZ_TEST_CLAUDE_BIN": "/tmp/fake-claude"]))
        // The seam is honoured only in a guarded run (this XCTest run is one), and only as an executable file.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("doz-ts-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = dir.appendingPathComponent("claude-fake").path
        FileManager.default.createFile(atPath: fake, contents: Data("#!/bin/sh\nexit 0\n".utf8), attributes: [.posixPermissions: 0o755])
        XCTAssertEqual(ClaudeLogin.testBinary(["DOZ_TEST_GUARD": "1", "DOZ_TEST_CLAUDE_BIN": fake]), fake)
        XCTAssertNil(ClaudeLogin.testBinary(["DOZ_TEST_GUARD": "1"]))
        XCTAssertEqual(ClaudeLogin.resolveBinary(environment: ["DOZ_TEST_GUARD": "1", "DOZ_TEST_CLAUDE_BIN": fake]), fake,
                       "a guarded run resolves only its fake")
        XCTAssertNil(ClaudeLogin.resolveBinary(environment: ["DOZ_TEST_GUARD": "1", "CLAUDE_BINARY": "/bin/sh"]),
                     "a guarded run never finds the Mac's claude, however it is named")
        // A guarded run without a fake counts no Claude Code at all (the Mac's own runs these tests' session).
        XCTAssertEqual(ClaudeLogin.claudePids(env: ["DOZ_TEST_GUARD": "1"]), [])
        // The memory seam's keep-alive: nothing to run without a fake; the fake through the guarded runner with one.
        XCTAssertTrue(CredentialServices.forHost(environment: ["DOZ_TEST_CREDENTIALS": "memory", "DOZ_TEST_GUARD": "1"]).keepaliveRunner is NoKeepalive)
        let s = CredentialServices.forHost(environment: ["DOZ_TEST_CREDENTIALS": "memory", "DOZ_TEST_GUARD": "1", "DOZ_TEST_CLAUDE_BIN": fake])
        XCTAssertEqual(s.claudeBinary(), fake)
        XCTAssertEqual((s.keepaliveRunner as? ProcessKeepaliveRunner)?.claude, true)
        XCTAssertEqual((CredentialServices.system.keepaliveRunner as? ProcessKeepaliveRunner)?.claude, true, "the real runner is the guarded one")
    }

    /// The guard is armed in this very run when `make test` runs it (DOZ_TEST_GUARD=1 is a forced default).
    func testTheMakefileArmsTheGuard() throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["DOZ_TEST_GUARD"] != nil, "run through make test")
        XCTAssertEqual(env["DOZ_TEST_GUARD"], "1")
        XCTAssertEqual(env["DOZ_TEST_CREDENTIALS"], "memory")
        XCTAssertEqual(env["DOZ_TEST_NO_MAC_LOGIN"], "1")
        XCTAssertNotNil(env["DOZ_TEST_CODEX_HOME"])
        let s = DozableSettings.load()
        let store = s.fileValues[SettingKey.storePath]
        let projects = s.fileValues[SettingKey.projectsDir]
        guard case .string(let sp)? = store, case .string(let pp)? = projects else { return XCTFail("the scratch doz.toml sets store.path and projects_dir") }
        XCTAssertNil(TestSafety.storeViolation(URL(fileURLWithPath: sp)))
        XCTAssertFalse(pp.contains("/Developer/"), "a test's new workspace is never under ~/Developer")
        // 694: a scratch LaunchAgents folder and a refusing launchctl — never the real ones.
        let agents = try XCTUnwrap(env["DOZ_TEST_LAUNCH_AGENTS_DIR"])
        XCTAssertNil(TestSafety.launchAgentsViolation(URL(fileURLWithPath: agents)))
        let lc = try XCTUnwrap(env["DOZ_TEST_LAUNCHCTL"])
        XCTAssertNil(TestSafety.launchctlViolation(lc))
        XCTAssertFalse(Launchctl.current().run(["print", "gui/\(getuid())/com.dozable.app.daemon"]).ok, "the Makefile's launchctl refuses everything")
        // The menu bar app: a scratch Applications folder — never /Applications or ~/Applications.
        let apps = try XCTUnwrap(env["DOZ_TEST_APPLICATIONS_DIR"])
        XCTAssertNil(TestSafety.applicationsViolation(URL(fileURLWithPath: apps)))
    }

    /// The menu bar app is never installed into, removed from or looked for in the real Applications folders by a test.
    func testTheRealApplicationsFoldersAreRefused() {
        XCTAssertNotNil(TestSafety.applicationsViolation(URL(fileURLWithPath: "/Applications"), home: home))
        XCTAssertNotNil(TestSafety.applicationsViolation(URL(fileURLWithPath: "/Applications/"), home: home))
        XCTAssertNotNil(TestSafety.applicationsViolation(URL(fileURLWithPath: "/Applications/Dozable.app"), home: home))
        XCTAssertNotNil(TestSafety.applicationsViolation(URL(fileURLWithPath: "/tmp/../Applications"), home: home))
        XCTAssertNotNil(TestSafety.applicationsViolation(home.appendingPathComponent("Applications"), home: home))
        XCTAssertNotNil(TestSafety.applicationsViolation(home.appendingPathComponent("Applications/Dozable.app"), home: home))
        XCTAssertNil(TestSafety.applicationsViolation(URL(fileURLWithPath: "/tmp/doz-test-applications"), home: home))
        XCTAssertNil(TestSafety.applicationsViolation(URL(fileURLWithPath: "/ApplicationsX"), home: home))
        XCTAssertNil(TestSafety.applicationsViolation(home.appendingPathComponent("ApplicationsX"), home: home))
        XCTAssertNil(TestSafety.applicationsViolation(URL(fileURLWithPath: "/Users/other/Applications"), home: home),
                     "another home's folder is not this person's")
    }

    /// A test run never asks macOS to open an app (LaunchServices would have Gatekeeper judge a scratch bundle — a
    /// stand-in inside one showed "“Dozable” is damaged" on a person's screen): a guarded run records what it would open
    /// in DOZ_TEST_APP_OPEN_LOG, and without that seam it STOPS. The same seam is the only way a test asks for a quit of a
    /// "running copy": a stand-in process (DOZ_TEST_APP_STANDIN), never a program inside a bundle.
    func testAGuardedRunNeverOpensAnApp() {
        XCTAssertNotNil(TestSafety.appOpenViolation(env: ["DOZ_TEST_GUARD": "1"]))
        XCTAssertNotNil(TestSafety.appOpenViolation(env: ["DOZ_TEST_GUARD": "1", "DOZ_TEST_APP_OPEN_LOG": "relative.log"]))
        XCTAssertNil(TestSafety.appOpenViolation(env: ["DOZ_TEST_GUARD": "1", "DOZ_TEST_APP_OPEN_LOG": "/tmp/open.log"]))
        XCTAssertNil(TestSafety.appOpenViolation(env: [:], inXCTest: false), "a person's run opens the app")
        XCTAssertNotNil(TestSafety.appOpenViolation(env: [:]), "an XCTest run is guarded whatever its environment")
        XCTAssertNil(TestSafety.appOpenViolation(env: ["DOZ_TEST_GUARD": "1", "DOZ_TEST_REAL_MAC": "1"]), "lifted only deliberately")
    }

    /// A VM worker's stand-ins are read only in a guarded run.
    func testTheWorkerSeamsOnlyInAGuardedRun() {
        let env = ["DOZ_TEST_GUARD": "1", "DOZ_TEST_WORKER_IMAGE": "lab", "DOZ_TEST_WORKER_ARGV": #"["/bin/sh", "/workspace/fake.sh"]"#]
        let s = TestSafety.workerSeams(env)
        XCTAssertEqual(s.image, "lab")
        XCTAssertEqual(s.argv, ["/bin/sh", "/workspace/fake.sh"])
        let lifted = TestSafety.workerSeams(env.merging(["DOZ_TEST_REAL_MAC": "1"]) { _, b in b })
        XCTAssertNil(lifted.image)
        XCTAssertNil(lifted.argv)
    }

    /// 751: a daemon stop ends its store's held sessions on this Mac only in a guarded run of a scratch store — a person's
    /// `@mac` sessions outlive the daemon, and the default store's are never ended even by a test.
    func testOnlyAGuardedStopOfAScratchStoreEndsItsHeldSessions() {
        let scratch = URL(fileURLWithPath: "/tmp/doz-clitest-store")
        let real = home.appendingPathComponent("Library/Application Support/doz")
        XCTAssertTrue(TestSafety.endsHeldSessionsAtStop(store: scratch, env: ["DOZ_TEST_GUARD": "1"], inXCTest: false, home: home))
        XCTAssertTrue(TestSafety.endsHeldSessionsAtStop(store: scratch, env: [:], inXCTest: true, home: home))
        XCTAssertFalse(TestSafety.endsHeldSessionsAtStop(store: scratch, env: [:], inXCTest: false, home: home), "a person's stop: they keep running")
        XCTAssertFalse(TestSafety.endsHeldSessionsAtStop(store: scratch, env: ["DOZ_TEST_GUARD": "1", "DOZ_TEST_REAL_MAC": "1"], inXCTest: false, home: home),
                       "lifted only deliberately — and then they keep running")
        XCTAssertFalse(TestSafety.endsHeldSessionsAtStop(store: real, env: ["DOZ_TEST_GUARD": "1"], inXCTest: false, home: home), "never the default store's")
        XCTAssertFalse(TestSafety.endsHeldSessionsAtStop(store: real.appendingPathComponent("x/.."), env: ["DOZ_TEST_GUARD": "1"], inXCTest: true, home: home))
        XCTAssertFalse(TestSafety.endsHeldSessionsAtStop(store: scratch, env: ["DOZ_TEST_GUARD": "1", "DOZ_TEST_KEEP_MAC_SESSIONS": "1"], inXCTest: false, home: home),
                       "a test proving their survival keeps them")
        XCTAssertTrue(TestSafety.endsHeldSessionsAtStop(store: scratch, env: ["DOZ_TEST_GUARD": "1", "DOZ_TEST_KEEP_MAC_SESSIONS": "yes"], inXCTest: false, home: home),
                      "only the exact value keeps them")
    }
}
