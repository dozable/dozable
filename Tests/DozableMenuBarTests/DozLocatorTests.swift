import XCTest
@testable import DozableMenuBarCore

final class DozLocatorTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("dozlocator-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func executable(_ name: String, _ text: String = "#!/bin/sh\necho 0.50.7\n") throws -> String {
        let p = dir.appendingPathComponent(name).path
        try FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: p, atomically: true, encoding: .utf8)
        chmod(p, 0o755)
        return p
    }

    func testTheStandardPlacesInOrder() {
        let c = DozLocator.standardCandidates(env: [:], home: "/Users/someone")
        XCTAssertEqual(c, ["/opt/homebrew/bin/doz", "/usr/local/bin/doz", "/Users/someone/.local/bin/doz"])
    }

    func testAGuardedRunUsesOnlyTheSeam() {
        XCTAssertEqual(DozLocator.standardCandidates(env: ["DOZ_TEST_GUARD": "1", "DOZ_MENUBAR_DOZ": "/tmp/x/doz"], home: "/h"), ["/tmp/x/doz"])
        XCTAssertEqual(DozLocator.standardCandidates(env: ["DOZ_TEST_GUARD": "1"], home: "/h"), [], "never this Mac's own doz in a test")
        XCTAssertEqual(DozLocator.standardCandidates(env: ["DOZ_TEST_GUARD": "1", "DOZ_MENUBAR_DOZ": "relative/doz"], home: "/h"), [])
        XCTAssertEqual(DozLocator.standardCandidates(env: ["DOZ_MENUBAR_DOZ": "/tmp/x/doz"], home: "/h").first, "/opt/homebrew/bin/doz",
                       "a person's run ignores the seam")
        XCTAssertEqual(DozLocator.standardCandidates(env: ["DOZ_TEST_GUARD": "1", "DOZ_TEST_REAL_MAC": "1", "DOZ_MENUBAR_DOZ": "/tmp/x/doz"], home: "/h").count, 3)
    }

    func testTheFirstExecutableWinsAndALinkIsKeptUnresolved() throws {
        let real = try executable("Cellar/doz/0.50.7/libexec/doz/doz")
        let link = dir.appendingPathComponent("bin/doz").path
        try FileManager.default.createDirectory(atPath: (link as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)
        let missing = dir.appendingPathComponent("nothing/doz").path
        let notExecutable = dir.appendingPathComponent("plain").path
        try "x".write(toFile: notExecutable, atomically: true, encoding: .utf8)
        let l = DozLocator(candidates: [missing, notExecutable, dir.path, link, real])
        XCTAssertEqual(l.locate(), link, "a link is used as is — a brew upgrade re-points it")
        XCTAssertNil(DozLocator(candidates: [missing, "relative/doz"]).locate())
    }

    /// An injected verifier (a signature check) that refuses a candidate: the next one is used.
    func testARefusedCandidateIsSkipped() throws {
        let a = try executable("a/doz"), b = try executable("b/doz")
        let l = DozLocator(candidates: [a, b], accept: { $0 != a && DozLocator.isExecutableFile($0) })
        XCTAssertEqual(l.locate(), b)
        XCTAssertNil(DozLocator(candidates: [a, b], accept: { _ in false }).locate())
    }

    /// The login agent's doz: in a release build only one signed by Dozable's team is run — an injected verifier that
    /// refuses the first candidate makes the agent take the next; refusing all, it runs nothing (and says why).
    func testTheLoginAgentRequiresTheTeamInAReleaseBuild() throws {
        let a = try executable("a/doz"), b = try executable("b/doz")
        let env = ["DOZ_TEST_GUARD": "1", "DOZ_MENUBAR_DOZ": a]
        final class Asked: @unchecked Sendable { let lock = NSLock(); var paths: [String] = [] }
        let asked = Asked()
        let verify: @Sendable (String) -> Bool = { _ in false }
        let release = DozLocator.forLaunchAgent(env: env, requireTeam: true, verify: verify)
        XCTAssertNil(release.locate())
        guard case .none(let why) = LaunchAgent.decide(release) else { return XCTFail("a refused doz is never run") }
        XCTAssertTrue(why.contains("not signed by Dozable (team KJ8QMLWB97)"), why)
        let dev = DozLocator.forLaunchAgent(env: env, requireTeam: false, verify: verify)
        XCTAssertEqual(LaunchAgent.decide(dev), .run(a), "a development build runs any doz")
        // The next candidate when the first is refused.
        let two = DozLocator(candidates: [a, b], accept: { p in
            asked.lock.withLock { asked.paths.append(p) }
            return DozLocator.isExecutableFile(p) && p == b
        })
        XCTAssertEqual(LaunchAgent.decide(two), .run(b))
        XCTAssertEqual(asked.lock.withLock { asked.paths }, [a, b])
        // Nothing installed: nothing to run.
        guard case .none(let none) = LaunchAgent.decide(DozLocator(candidates: [dir.appendingPathComponent("x/doz").path])) else { return XCTFail() }
        XCTAssertTrue(none.hasPrefix("doz is not installed"), none)
    }

    func testTheTeamRequirementAndItsSwitch() {
        XCTAssertEqual(DozSignature.requirement, "anchor apple generic and certificate leaf[subject.OU] = \"KJ8QMLWB97\"")
        XCTAssertTrue(LaunchAgent.requiresTeam(releaseBuild: true, env: [:]))
        XCTAssertFalse(LaunchAgent.requiresTeam(releaseBuild: false, env: [:]))
        XCTAssertTrue(LaunchAgent.requiresTeam(releaseBuild: false, env: ["DOZ_TEST_GUARD": "1", "DOZ_TEST_MENUBAR_REQUIRE_TEAM": "1"]))
        XCTAssertFalse(LaunchAgent.requiresTeam(releaseBuild: false, env: ["DOZ_TEST_MENUBAR_REQUIRE_TEAM": "1"]), "a seam of test runs only")
        XCTAssertEqual(LaunchAgent.arguments, ["daemon", "start", "--login-item"])
    }

    /// The real verifier: a script, an Apple program (not Dozable's team) and a missing file are all refused.
    func testTheRealVerifierRefusesWhatDozableDidNotSign() throws {
        XCTAssertFalse(DozSignature.isDozable(try executable("s/doz")))
        XCTAssertFalse(DozSignature.isDozable("/bin/ls"))
        XCTAssertFalse(DozSignature.isDozable(dir.appendingPathComponent("none").path))
    }

    /// The cache key: a doz replaced by rename is another file; one rewritten in place changes size or time; a new VERSION
    /// beside it counts too.
    func testAReplacedDozIsAnotherFile() throws {
        let p = try executable("libexec/doz/doz")
        let stamp = dir.appendingPathComponent("libexec/doz/VERSION").path
        try "0.50.7\n".write(toFile: stamp, atomically: true, encoding: .utf8)
        let before = FileIdentity.ofDoz(p)
        XCTAssertEqual(before.count, 2)
        XCTAssertEqual(FileIdentity.ofDoz(p), before)
        let new = try executable("libexec/doz/.doz.new", "#!/bin/sh\necho 0.51.0\n")
        XCTAssertEqual(rename(new, p), 0)
        XCTAssertNotEqual(FileIdentity.ofDoz(p), before)
        let afterRename = FileIdentity.ofDoz(p)
        try "0.51.0\n".write(toFile: stamp, atomically: true, encoding: .utf8)
        XCTAssertNotEqual(FileIdentity.ofDoz(p), afterRename, "a new VERSION beside it")
        XCTAssertEqual(FileIdentity.ofDoz(dir.appendingPathComponent("none").path), [])
    }
}
