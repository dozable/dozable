import Foundation
@testable import DozableKit
import XCTest
@testable import DozableCLI
@testable import DozableHost

/// 669 (659 items 7–11): the sandbox and project layers. A recipe's approvals per sandbox and per project
/// (`--approvals`, `approvals:`, `doz config set --sandbox NAME approvals ask`), the sources a sandbox records
/// (`recipeSettings` at create, `settingsFrom` for its own values), a try never writing doz.toml, and `doz config set`
/// writing only the place it names. In-process host, no VM (create never boots), fake keychain, scratch folders.
final class SettingLayersTests: XCTestCase {
    private var root: URL!
    let keychain = FakeKeychain()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("doz-layers-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func core() async -> HostCore {
        let s = CredentialServices(keychain: keychain, verifier: FakeVerifier(answer: .verified), claudeBinary: { nil }, home: root,
                                   keepaliveRunner: FakeRunner(), isClaudeRunning: { false }, watchInterval: .seconds(3600))
        let c = HostCore(store: DozableStore(root: root.appendingPathComponent("store")), readOnly: false, version: "test", services: s)
        await c.load()
        return c
    }

    @discardableResult
    func create(_ c: HostCore, _ name: String, _ o: CreateOptions) async throws -> SandboxInfo {
        var r = HostRequest(.create, name: name)
        r.create = o
        let m = await c.handle(r)
        if let e = m.error { throw e }
        return try XCTUnwrap(m.result).decode(SandboxInfo.self)
    }

    func config(_ name: String) throws -> SandboxConfig {
        try XCTUnwrap(SandboxConfig.read(DozableStore(root: root.appendingPathComponent("store")).configFile(name)))
    }

    func settingsOp(_ c: HostCore, _ name: String, _ key: String? = nil, _ value: String? = nil, clear: Bool = false, from: String? = nil) async throws -> SandboxSettingsReport {
        var r = HostRequest(.sandboxSettings, name: name)
        r.setting = key
        if let value { r.settingValue = .string(value) }
        if clear { r.clearSetting = true }
        r.settingFrom = from
        let m = await c.handle(r)
        if let e = m.error { throw e }
        return try XCTUnwrap(m.result).decode(SandboxSettingsReport.self)
    }

    // MARK: item 7 — approvals per sandbox and per project

    func testApprovalsPerSandboxWinOverTheMacAndTheCallersEnvWinsOverBoth() {
        let macAsk = DozableSettings(text: "[recipes.anthropic.claude-code]\napprovals = \"ask\"\n")
        let macSkip = DozableSettings(text: "")
        XCTAssertEqual(HostCore.withClaudePermissions([:], imageSpec: "claude-code", own: .string("ask"), settings: macSkip), ["DOZ_CLAUDE_PERMISSIONS": "ask"])
        XCTAssertEqual(HostCore.withClaudePermissions([:], imageSpec: "claude-code", own: .string("skip"), settings: macAsk), [:], "the sandbox's skip over the Mac's ask")
        XCTAssertEqual(HostCore.withClaudePermissions([:], imageSpec: "claude-code", own: nil, settings: macAsk), ["DOZ_CLAUDE_PERMISSIONS": "ask"])
        XCTAssertEqual(HostCore.withClaudePermissions(["DOZ_CLAUDE_PERMISSIONS": "skip"], imageSpec: "claude-code", own: .string("ask"), settings: macAsk),
                       ["DOZ_CLAUDE_PERMISSIONS": "skip"], "-e on run/exec wins for one session")
        XCTAssertEqual(HostCore.withClaudePermissions([:], imageSpec: "pi", own: .string("ask"), settings: macSkip), [:], "pi has no prompts to skip")
    }

    func testApprovalsAreAChoiceOfNewCreateUpAndTryRecordedAsTheSandboxsOwn() async throws {
        // The flag, into the create and the plan's command and project file.
        let o = try ChoiceOptions.from(["--agent", "claude-code", "--approvals", "ask"]).options()
        XCTAssertEqual(o.settings?[SettingKey.sandboxApprovals], .string("ask"))
        XCTAssertThrowsError(try ChoiceOptions.from(["--agent", "claude-code", "--approvals", "yolo"]).options())
        let argv = CreatePlanner.argv(purpose: "create", name: "a", options: o, given: o, choice: ImageChoice.parse(o.image), settings: DozableSettings(text: ""))
        XCTAssertTrue(CreatePlanner.shellLine(argv).contains("--approvals ask"), CreatePlanner.shellLine(argv))
        XCTAssertEqual(try ChoiceOptions.from(Array(argv.dropFirst(3))).options().settings?[SettingKey.sandboxApprovals], .string("ask"), "the argv reads back")
        let (yaml, _) = CreatePlanner.yaml(name: "a", options: o, choice: ImageChoice.parse(o.image), isolated: true)
        XCTAssertTrue(yaml.contains("\napprovals: ask\n"), yaml)
        // Made: its own value, from the sandbox.
        let c = await core()
        var co = CreateOptions(image: "claude-code")
        co.settings = [SettingKey.sandboxApprovals: .string("ask")]
        try await create(c, "a", co)
        XCTAssertEqual(try config("a").settings?[SettingKey.sandboxApprovals], .string("ask"))
        XCTAssertNil(try config("a").settingsFrom, "the sandbox's own: no `from` needed")
        // An agent with no prompts to skip refuses it.
        var pi = CreateOptions(image: "codex")
        pi.settings = [SettingKey.sandboxApprovals: .string("ask")]
        XCTAssertNoThrow(try HostCore.checkedSandboxSettings(pi.settings!, image: "codex"))
        XCTAssertThrowsError(try HostCore.checkedSandboxSettings(pi.settings!, image: "pi"))
    }

    func testDozConfigSetSandboxApprovalsTakesEffectAndClears() async throws {
        let c = await core()
        try await create(c, "b", CreateOptions(image: "claude-code"))
        var rep = try await settingsOp(c, "b", "approvals", "ask")
        XCTAssertEqual(rep.settings.first { $0.key == "approvals" }?.value, .string("ask"))
        XCTAssertEqual(rep.settings.first { $0.key == "approvals" }?.source, "sandbox")
        XCTAssertEqual(rep.settings.first { $0.key == "approvals" }?.settingKey, "recipes.anthropic.claude-code.approvals")
        XCTAssertEqual(try config("b").settings?["approvals"], .string("ask"), "what the next session reads")
        // By the recipe's full key too.
        rep = try await settingsOp(c, "b", "recipes.anthropic.claude-code.approvals", "skip")
        XCTAssertEqual(rep.settings.first { $0.key == "approvals" }?.value, .string("skip"))
        rep = try await settingsOp(c, "b", "approvals", clear: true)
        XCTAssertNil(try config("b").settings?["approvals"])
        XCTAssertEqual(rep.settings.first { $0.key == "approvals" }?.source, "recipe", "follows the recipe's default again")
    }

    func testAProjectsApprovalsParseRenderAndAreSyncedAsTheProjects() async throws {
        let p = try DozableProject.parse("version: 1\nname: x\nagent: claude-code\napprovals: ask\n")
        XCTAssertEqual(p.settings[SettingKey.sandboxApprovals], .string("ask"))
        XCTAssertTrue(p.render().contains("\napprovals: ask\n"))
        XCTAssertTrue(DozableProject(name: "y", image: "claude-code").render().contains("# approvals: skip"), "listed, commented")
        XCTAssertThrowsError(try DozableProject.parse("version: 1\nname: x\nagent: claude-code\napprovals: yolo\n")) {
            XCTAssertTrue("\($0)".contains("approvals"), "\($0)")
        }
        let o = p.createOptions(folder: root, file: root.appendingPathComponent(DozableProject.fileName))
        XCTAssertEqual(o.fromProject, [SettingKey.sandboxApprovals])
        // 0.37's project files parse unchanged (no approvals key in them).
        XCTAssertNoThrow(try DozableProject.parse("version: 1\nname: x\nimage: claude-code\nclipboard: off\nmemory: 4G\n"))
        // Made from it, then synced by doz up: from the project.
        let c = await core()
        var co = CreateOptions(image: "claude-code")
        co.settings = o.settings
        co.fromProject = o.fromProject
        try await create(c, "p", co)
        XCTAssertEqual(try config("p").settingsFrom, [SettingKey.sandboxApprovals: "project"])
        let rep = try await settingsOp(c, "p")
        XCTAssertEqual(rep.settings.first { $0.key == "approvals" }?.source, "project")
        _ = try await settingsOp(c, "p", SettingKey.clipboard, "off", from: "project")
        XCTAssertEqual(try config("p").settingsFrom?[SettingKey.clipboard], "project", "doz up writes from: project")
        _ = try await settingsOp(c, "p", SettingKey.clipboard, "write")
        XCTAssertNil(try config("p").settingsFrom?[SettingKey.clipboard], "set with --sandbox: the sandbox's own")
    }

    // MARK: item 8 — recorded sources

    func testCreateRecordsTheRecipesValuesWithWhereEachCameFrom() async throws {
        let c = await core()
        try await create(c, "d", CreateOptions(image: "claude-code"))
        let d = try XCTUnwrap(try config("d").recipeSettings)
        XCTAssertEqual(d["memory_mib"], RecordedSetting(value: .int(2048), from: "recipe"))
        XCTAssertEqual(d["network"]?.from, "recipe")
        XCTAssertEqual(d["version"]?.from, "recipe")
        try await create(c, "f", CreateOptions(image: "claude-code", memoryMiB: 4096))
        XCTAssertEqual(try config("f").recipeSettings?["memory_mib"], RecordedSetting(value: .int(4096), from: "flag"))
        var po = CreateOptions(image: "claude-code", memoryMiB: 3072)
        po.fromProject = ["memory_mib"]
        try await create(c, "g", po)
        XCTAssertEqual(try config("g").recipeSettings?["memory_mib"], RecordedSetting(value: .int(3072), from: "project"))
        // The lab has no recipe: nothing recorded.
        try await create(c, "l", CreateOptions(image: "lab"))
        XCTAssertNil(try config("l").recipeSettings)
        // Shown with the sandbox's settings, as recorded.
        let rep = try await settingsOp(c, "g")
        let mem = try XCTUnwrap(rep.settings.first { $0.key == "recipes.anthropic.claude-code.memory_mib" })
        XCTAssertEqual(mem.recorded, true)
        XCTAssertEqual(mem.source, "project")
        XCTAssertEqual(mem.settingValue, .int(2048), "this Mac's value now, beside it")
    }

    func testAnOldFlatDozJsonReadsAsTheSandboxsOwn() throws {
        // A doz.json as 0.37 wrote it: `settings` flat, no `settingsFrom`, no `recipeSettings`.
        let (spec, _) = try DozableImages.spec(name: "o", options: CreateOptions(image: "lab"), store: DozableStore(root: root), environment: [:])
        var tree = try XCTUnwrap(JSONSerialization.jsonObject(with: try HostWire.prettyEncoder.encode(SandboxConfig(name: "o", image: "lab", spec: spec, workspace: nil))) as? [String: Any])
        tree["settings"] = ["sandbox.clipboard": "off"]
        XCTAssertNil(tree["settingsFrom"])
        let cfg = try HostWire.decoder.decode(SandboxConfig.self, from: try JSONSerialization.data(withJSONObject: tree))
        XCTAssertEqual(cfg.settings?[SettingKey.clipboard], .string("off"))
        XCTAssertNil(cfg.settingsFrom)
        XCTAssertNil(cfg.recipeSettings)
        let rep = HostCore.sandboxSettingsReport(cfg, settings: DozableSettings(text: ""))
        XCTAssertEqual(rep.settings.first { $0.key == SettingKey.clipboard }?.source, "sandbox")
    }

    // MARK: item 9 — a try never writes doz.toml

    func testATryNeverWritesDozToml() async throws {
        let file = try XCTUnwrap(DozableSettings.fileURL())
        let before = FileManager.default.contents(atPath: file.path)
        let c = await core()
        // What a try makes: the plan's create — its tool, its own approvals.
        let o = try ChoiceOptions.from(["--agent", "claude-code", "--approvals", "ask", "--memory", "3G"]).options()
        try await create(c, "claude-code-try", o)
        XCTAssertEqual(try config("claude-code-try").settings?[SettingKey.sandboxApprovals], .string("ask"), "recorded in the sandbox instead")
        XCTAssertEqual(FileManager.default.contents(atPath: file.path), before, "the same bytes before and after")
    }

    // MARK: item 11 — `doz config set --project`

    func testSetProjectWritesOnlyTheProjectFileAndRefusesOneThatDoesNotParse() throws {
        let dir = root.appendingPathComponent("proj")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = dir.appendingPathComponent(DozableProject.fileName)
        try DozableProject(name: "proj", image: "claude-code").render().write(to: f, atomically: true, encoding: .utf8)
        let mac = try XCTUnwrap(DozableSettings.fileURL())
        let macBefore = FileManager.default.contents(atPath: mac.path)
        let g = try GlobalOptions.parse(["-q"])
        try ConfigProject.change(folder: dir.path, key: SettingKey.sandboxApprovals, value: "ask", g)
        XCTAssertEqual(try DozableProject.load(f).settings[SettingKey.sandboxApprovals], .string("ask"))
        try ConfigProject.change(folder: dir.path, key: SettingKey.clipboard, value: "off", g)
        XCTAssertEqual(try DozableProject.load(f).settings[SettingKey.clipboard], .string("off"))
        try ConfigProject.change(folder: dir.path, key: SettingKey.sandboxApprovals, value: nil, g)
        XCTAssertNil(try DozableProject.load(f).settings[SettingKey.sandboxApprovals])
        XCTAssertEqual(FileManager.default.contents(atPath: mac.path), macBefore, "this Mac's file untouched")
        let bad = "version: 1\nname: proj\nimage: claude-code\nnonsense: 1\n"
        try bad.write(to: f, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try ConfigProject.change(folder: dir.path, key: SettingKey.sandboxApprovals, value: "ask", g))
        XCTAssertEqual(try String(contentsOf: f, encoding: .utf8), bad, "never rewritten")
    }

    func testSandboxKeysNameApprovalsAndRefuseAWhenMadeValue() throws {
        let g = try GlobalOptions.parse(["-q"])
        XCTAssertEqual(try sandboxKey("approvals", agent: nil, g), "approvals")
        XCTAssertEqual(try sandboxKey("recipes.anthropic.claude-code.approvals", agent: nil, g), "approvals")
        XCTAssertEqual(try sandboxKey("approvals", agent: "claude-code", g), "approvals")
        XCTAssertEqual(try sandboxKey("claude.permissions", agent: nil, g), "approvals", "a 0.37 name too")
        XCTAssertEqual(try sandboxKey("clipboard", agent: nil, g), SettingKey.clipboard)
        XCTAssertEqual(try sandboxKey("sandbox.clipboard", agent: nil, g), SettingKey.clipboard)
        XCTAssertThrowsError(try sandboxKey("version", agent: "claude-code", g), "set when a sandbox is made")
        XCTAssertThrowsError(try sandboxKey("ui.theme", agent: nil, g))
    }
}
