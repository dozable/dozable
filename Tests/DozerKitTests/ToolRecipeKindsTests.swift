import Foundation
import XCTest
@testable import DozerKit

/// 617 (other AI tools): the recipe format's additions for tools that are not coding agents — the `pypi` and
/// `release-binary` install kinds, a dotenv first-run file, and `launch.session: shell` — validated, refused with a
/// reason, and turned into the bake steps they describe.
final class ToolRecipeKindsTests: XCTestCase {
    static let sha = String(repeating: "a", count: 64)

    /// Fabric's recipe as model JSON, with `install` changed by `edit`.
    func recipe(_ edit: (inout [String: Any]) -> Void = { _ in }, launch: ((inout [String: Any]) -> Void)? = nil,
                platforms: [String: Any]? = nil) throws -> AgentRecipe {
        var o = try AgentRecipeTests.json("fabric")
        var i = try XCTUnwrap(o["install"] as? [String: Any])
        edit(&i)
        o["install"] = i
        if let launch {
            var l = try XCTUnwrap(o["launch"] as? [String: Any])
            launch(&l)
            o["launch"] = l
        }
        if let platforms { o["platforms"] = platforms }
        return try AgentRecipes.decode(AgentRecipeTests.data(o))
    }

    func pypi(_ reqs: [String], package: String = "llm", version: String = "0.36") -> (inout [String: Any]) -> Void {
        { i in
            i["kind"] = "pypi"; i["package"] = package; i["binary"] = "fabric"; i["requirements"] = reqs
            i["url"] = nil; i["payload"] = nil; i["bake_hosts"] = nil
            i["pinned"] = ["version": version, "integrity": "sha512-AAAA"]
        }
    }

    // MARK: release-binary

    func test_releaseBinaryIsValidatedAndBaked() throws {
        let r = try XCTUnwrap(AgentRecipes.recipe("fabric"))
        XCTAssertEqual(r.install.kind, "release-binary")
        XCTAssertEqual(r.install.archive, "tar.gz")
        XCTAssertTrue(AgentRecipe.pinnedOnlyKinds.contains(r.install.kind))
        let step = AgentImages.releaseBinaryInstall(r, r.pinnedRelease!)
        let s = step.argv.last!
        XCTAssertTrue(s.contains("https://github.com/danielmiessler/Fabric/releases/download/v1.4.518/fabric_Linux_arm64.tar.gz"), s)
        XCTAssertTrue(s.contains(r.install.pinned.integrity!), "the download's sha512 is checked")
        XCTAssertTrue(s.contains("tar -xzf dl -C x"))
        XCTAssertTrue(s.contains("src=x/fabric"))
        XCTAssertTrue(s.contains("ln -sf /opt/fabric/fabric /usr/local/bin/fabric"))
    }

    func test_releaseBinaryRefusals() throws {
        XCTAssertThrowsError(try recipe { $0["url"] = "https://example.com/fabric_Linux_arm64.tar.gz" }, "no {version}")
        XCTAssertThrowsError(try recipe { $0["payload"] = nil }, "an archive names its program")
        XCTAssertThrowsError(try recipe { $0["url"] = "https://example.com/v{version}/tool-linux-arm64" }, "a raw download has no payload")
        XCTAssertNoThrow(try recipe { $0["url"] = "https://example.com/v{version}/tool-linux-arm64"; $0["payload"] = nil })
        XCTAssertThrowsError(try recipe { $0["url"] = "http://example.com/v{version}/x.tar.gz" }, "https only")
        XCTAssertThrowsError(try recipe { $0["package"] = "fabric" }, "nothing of npm's")
        XCTAssertEqual(try recipe { $0["url"] = "https://example.com/v{version}/x.zip" }.install.archive, "zip")
    }

    // MARK: pypi

    func test_pypiIsValidatedAndBaked() throws {
        let reqs = ["llm==0.36 --hash=sha256:\(Self.sha)", "click==8.2.1 --hash=sha256:\(Self.sha)"]
        let r = try recipe(pypi(reqs), platforms: ["glibc": true, "musl": false])
        let s = AgentImages.pypiInstall(r, r.pinnedRelease!).argv.last!
        XCTAssertTrue(s.contains("llm==0.36 --hash=sha256:\(Self.sha)\nclick==8.2.1 --hash=sha256:\(Self.sha)"), "the lock, verbatim")
        XCTAssertTrue(s.contains("download --no-deps --require-hashes -d dist -r requirements.txt"))
        XCTAssertTrue(s.contains("install --no-index --find-links dist --no-deps --require-hashes -r requirements.txt"))
        XCTAssertTrue(s.contains("grep -i '^llm-0.36[-.]'"), "the package's own file is found by its wheel name")
        XCTAssertTrue(s.contains("sha512-AAAA"), "and checked against the integrity")
        XCTAssertTrue(s.contains("/opt/python/bin/python3 -m venv /opt/fabric/venv"))
        let py = AgentImages.pythonRuntime(for: "x").argv.last!
        XCTAssertTrue(py.contains(PythonRuntime.sha256) && py.contains(PythonRuntime.url))
        let steps = AgentImages.recipeInstall(r, r.pinnedRelease!, base: BaseCatalogue.base("debian")!.source())
        XCTAssertEqual(steps.steps.count, 2)
        XCTAssertTrue(steps.bakeHosts.contains("files.pythonhosted.org") && steps.bakeHosts.contains("release-assets.githubusercontent.com"))
        XCTAssertEqual(AgentRecipe.Install.wheelName("Shell-GPT"), "shell_gpt")
        XCTAssertEqual(AgentRecipe.Install.wheelName("google.adk"), "google_adk")
    }

    func test_pypiRefusals() throws {
        let ok = ["llm==0.36 --hash=sha256:\(Self.sha)"]
        let glibc: [String: Any] = ["glibc": true, "musl": false]
        XCTAssertNoThrow(try recipe(pypi(ok), platforms: glibc))
        XCTAssertThrowsError(try recipe(pypi(ok)), "musl: Dozer's Python is glibc")
        XCTAssertThrowsError(try recipe(pypi([]), platforms: glibc), "no requirements")
        XCTAssertThrowsError(try recipe(pypi(["llm==0.36"]), platforms: glibc), "a requirement without its hash")
        XCTAssertThrowsError(try recipe(pypi(["llm>=0.36 --hash=sha256:\(Self.sha)"]), platforms: glibc), "not pinned exactly")
        XCTAssertThrowsError(try recipe(pypi(["llm==0.35 --hash=sha256:\(Self.sha)"]), platforms: glibc), "the package at another version")
        XCTAssertThrowsError(try recipe(pypi(ok + ["LLM==0.36 --hash=sha256:\(Self.sha)"]), platforms: glibc), "a distribution twice")
        XCTAssertThrowsError(try recipe(pypi(["llm==0.36 --hash=sha256:\(Self.sha)'; rm -rf /"]), platforms: glibc), "nothing a script would run")
        XCTAssertThrowsError(try recipe({ i in self.pypi(ok)(&i); i["url"] = "https://example.com/{version}" }, platforms: glibc), "no url")
        XCTAssertThrowsError(try recipe({ i in i["requirements"] = ok }), "requirements are a pypi install's")
    }

    // MARK: Node 24

    /// An npm recipe that needs a newer Node than the bases' gets Dozer's Node 24 under /opt/node on every glibc base —
    /// the Node base included — and a wrapper; never on musl.
    func test_aNewerNodeIsInstalledForTheRecipeThatNeedsIt() throws {
        let r = try XCTUnwrap(AgentRecipes.recipe("openclaw"))
        XCTAssertEqual(r.install.needsNode, "24")
        for base in ["node", "debian", "python"] {
            let steps = AgentImages.recipeInstall(r, r.pinnedRelease!, base: BaseCatalogue.base(base)!.source())
            XCTAssertEqual(steps.steps.map(\.name).first, "install Node \(NodeRuntime.V24.version) for OpenClaw (/opt/node, checksum-verified)", base)
            XCTAssertTrue(steps.steps[0].argv.last!.contains(NodeRuntime.V24.sha256))
            XCTAssertEqual(steps.steps[1].environment["PATH"]?.hasPrefix("/opt/node/bin:"), true)
            XCTAssertEqual(steps.steps.last?.name, "install the openclaw wrapper (/usr/local/bin/openclaw)")
        }
        var o = try AgentRecipeTests.json("openclaw")
        o["platforms"] = ["glibc": true, "musl": true]
        XCTAssertThrowsError(try AgentRecipes.decode(AgentRecipeTests.data(o)), "Node 24 is glibc only")
        o = try AgentRecipeTests.json("openclaw")
        var i = try XCTUnwrap(o["install"] as? [String: Any])
        i["needs_node"] = "26"
        o["install"] = i
        XCTAssertThrowsError(try AgentRecipes.decode(AgentRecipeTests.data(o)), "Node 24 at most")
        // An agent whose needs_node is the bases' own keeps the old steps (Gemini CLI on Node: the npm install alone).
        let g = try XCTUnwrap(AgentRecipes.recipe("gemini"))
        XCTAssertEqual(AgentImages.recipeInstall(g, g.pinnedRelease!, base: BaseCatalogue.base("node")!.source()).steps.count, 1)
    }

    // MARK: launch

    func test_shellSessionAndDotenvFirstRun() throws {
        let r = try XCTUnwrap(AgentRecipes.recipe("fabric"))
        XCTAssertEqual(r.launch.session, "shell")
        XCTAssertThrowsError(try recipe(launch: { $0["session"] = "tmux" }), "shell only")
        XCTAssertThrowsError(try recipe(launch: { $0["first_run"] = [["file": "~/.config/fabric/.env", "set": ["GEMINI_API_KEY": "x"]]] }),
                             "a dotenv first run never names a credential")
        XCTAssertThrowsError(try recipe(launch: { $0["first_run"] = [["file": "~/.config/fabric/.env", "set": ["A": "$(id)"]]] }))
    }

    /// The dotenv helper: absent keys appended, a person's own line (set or commented out) kept, the file made when missing.
    func test_dotenvFirstRunMergesAbsentKeysOnly() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else { throw XCTSkip("no python3") }
        let r = try XCTUnwrap(AgentRecipes.recipe("fabric"))
        let py = AgentImages.recipeSetupPython(r.launch.firstRun!)
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("dotenv-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let script = home.appendingPathComponent("setup.py")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try py.write(to: script, atomically: true, encoding: .utf8)
        func run() throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            p.arguments = [script.path]
            p.environment = ["HOME": home.path]
            try p.run()
            p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 0)
        }
        let env = home.appendingPathComponent(".config/fabric/.env")
        try run()
        XCTAssertEqual(try String(contentsOf: env, encoding: .utf8), "DEFAULT_MODEL=gemini-2.5-flash\nDEFAULT_VENDOR=Gemini\n")
        try Data("# DEFAULT_MODEL=mine\nOTHER=1\n".utf8).write(to: env)
        try run()
        XCTAssertEqual(try String(contentsOf: env, encoding: .utf8), "# DEFAULT_MODEL=mine\nOTHER=1\nDEFAULT_VENDOR=Gemini\n")
        // The other recipes' helpers are unchanged by the dotenv support (their bake keys stay).
        XCTAssertFalse(AgentImages.recipeSetupPython(AgentRecipes.recipe("gemini")!.launch.firstRun!).contains("merge_env"))
    }
}
