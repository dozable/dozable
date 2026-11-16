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
    }
}
