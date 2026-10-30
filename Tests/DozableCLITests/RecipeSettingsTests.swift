import Darwin
import Foundation
import DozableKit
import XCTest
@testable import DozableHost

/// 669 (loop 627 step 20; the design is 659): settings per recipe — the generated `recipes.VENDOR.PRODUCT.NAME` keys,
/// one precedence (flag › env › sandbox › project › Mac › default) with a source for each layer, the doz.toml shape
/// (T2: bare dotted tables), the migration (M1: read the 0.37 names, write the new shape and a one-off
/// `doz.toml.0.37.bak`, never lose a value), `defaults.memory_mib`/`defaults.network`, and the old names as aliases.
/// Every file lives under a scratch XDG_CONFIG_HOME.
final class RecipeSettingsTests: XCTestCase {
    private var xdg: URL!
    private var env: [String: String] { ["XDG_CONFIG_HOME": xdg.path] }
    private var file: URL { xdg.appendingPathComponent("doz/doz.toml") }
    private var bak: URL { xdg.appendingPathComponent("doz/doz.toml.0.37.bak") }

    override func setUpWithError() throws {
        xdg = FileManager.default.temporaryDirectory.appendingPathComponent("doz-recipe-settings-\(UUID().uuidString.prefix(8))")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: xdg)
    }

    private func write(_ text: String) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
    }

    // MARK: item 1 — the schema

    func testEveryRecipesSettingsAreGeneratedUnderRecipes() throws {
        for r in AgentRecipes.all {
            let defs = DozableSettings.recipeDefinitions(r.id)
            XCTAssertTrue(defs.allSatisfy { $0.section == r.settingsSection && $0.key.hasPrefix("recipes.") }, r.id)
            XCTAssertEqual(Array(defs.map(\.name).prefix(1)), ["version"], r.id)
            XCTAssertTrue(defs.contains { $0.name == "memory_mib" } && defs.contains { $0.name == "network" }, r.id)
            XCTAssertEqual(defs.contains { $0.name == "approvals" }, r.permissionsSettingKey != nil, "\(r.id): approvals when it has prompts to skip")
            XCTAssertTrue(defs.allSatisfy { $0.settingClass == .recipe && $0.defaultSource == .recipe }, r.id)
        }
        XCTAssertEqual(SettingKey.claudeCodeVersion, "recipes.anthropic.claude-code.version")
        XCTAssertEqual(SettingKey.claudePermissions, "recipes.anthropic.claude-code.approvals")
        XCTAssertEqual(SettingKey.codexKeepAlive, "recipes.openai.codex.keep_alive", "Codex's own, from its settings@1")
        XCTAssertNil(SettingKey.approvals("pi"), "pi has no prompts to skip")
        // The built-in three have no hand-written key left: nothing in [claude], [codex], [images] or [images.claude-code].
        for d in DozableSettings.schema where d.agent == nil {
            XCTAssertFalse(["claude", "codex", "images", "images.claude-code", "images.pi", "images.codex"].contains(d.section), d.key)
        }
    }

    // MARK: item 2 — one precedence, a source per layer, for each kind

    func testEachLayerWinsInTurnForEachKind() throws {
        let file = """
        [ui]
        theme = "dark"
        [defaults]
        cpus = 4
        [sandbox]
        clipboard = "off"
        [recipes.anthropic.claude-code]
        approvals = "ask"
        [host]
        idle_timeout_minutes = 9
        """
        let s = DozableSettings(text: file, environment: ["DOZ_HOST_IDLE": "3"])
        // M (Mac): flag › env › Mac › default; a sandbox or project value is not one of its layers.
        XCTAssertEqual(s.resolve("ui.theme", flag: .string("light")).source, .flag)
        XCTAssertEqual(s.resolve("host.idle_timeout_minutes").source, .env)
        XCTAssertEqual(s.resolve("ui.theme", sandbox: .string("light"), project: .string("light")).source, .mac, "M has no sandbox or project layer")
        XCTAssertEqual(s.resolve("ui.density").source, .default)
        XCTAssertEqual(DozableSettings.definition("ui.theme")?.settingClass, .mac)
        // N (a new sandbox's default), S (per sandbox, live), R (a recipe's): flag › sandbox › project › Mac › default.
        for (key, kind, other, recipeDefault) in [("defaults.cpus", SettingClass.newSandbox, TOMLValue.int(8), false),
                                                  ("sandbox.clipboard", .perSandbox, .string("write"), false),
                                                  ("recipes.anthropic.claude-code.approvals", .recipe, .string("skip"), true)] {
            XCTAssertEqual(DozableSettings.definition(key)?.settingClass, kind, key)
            XCTAssertEqual(s.resolve(key, flag: other, sandbox: other, project: other).source, .flag, key)
            XCTAssertEqual(s.resolve(key, sandbox: other, project: other).source, .sandbox, key)
            XCTAssertEqual(s.resolve(key, sandbox: other, project: other).value, other, key)
            XCTAssertEqual(s.resolve(key, project: other).source, .project, key)
            XCTAssertEqual(s.resolve(key).source, .mac, key)
            XCTAssertEqual(DozableSettings(text: "").resolve(key).source, recipeDefault ? .recipe : .default, "\(key): whose default")
        }
        // The JSON says mac, and still reads an older host's file.
        XCTAssertEqual(String(decoding: try JSONEncoder().encode(SettingSource.mac), as: UTF8.self), "\"mac\"")
        XCTAssertEqual(try JSONDecoder().decode(SettingSource.self, from: Data("\"file\"".utf8)), .mac)
        XCTAssertEqual(try JSONDecoder().decode([SettingSource].self, from: Data("[\"recipe\",\"sandbox\",\"project\"]".utf8)), [.recipe, .sandbox, .project])
    }

    // MARK: item 3 — the doz.toml shape

    func testAFreshFileListsDozablesOwnAndNoRecipeAndA037ReaderParsesIt() throws {
        let fresh = DozableSettings.render(values: [:])
        XCTAssertFalse(fresh.contains("\n[recipes."))
        let own = DozableSettings.schema.filter { $0.agent == nil }.count
        XCTAssertEqual(DozableSettings.listedCount(values: [:]), own)
        // 659 counted 61 + 2 (defaults.memory_mib, defaults.network); 667 added sandbox.audio and sandbox.microphone_ask.
        XCTAssertEqual(own, 65)
        XCTAssertEqual(fresh.components(separatedBy: "\n# ").filter { $0.range(of: #"^[a-z_]+ = "#, options: .regularExpression) != nil }.count, own)
        // One value of a recipe: exactly its block, the others commented.
        let one = DozableSettings.render(values: ["recipes.anthropic.claude-code.version": .string("2.1.290")])
        XCTAssertTrue(one.contains("\n[recipes.anthropic.claude-code]\n"))
        XCTAssertTrue(one.contains("\nversion = \"2.1.290\"\n"))
        XCTAssertTrue(one.contains("\n# memory_mib = 2048\n") && one.contains("\n# network = \"agent\"\n") && one.contains("\n# approvals = \"skip\"\n"))
        XCTAssertEqual(one.components(separatedBy: "\n[recipes.").count, 2)
        // A 0.37 doz reads it: the TOML reader is the one 0.37 has (TOML.swift is unchanged by 669) — bare dotted tables,
        // `-` in a key — so the file parses, and 0.37 only warns about the keys it does not know (and keeps them).
        let entries = try TOML.parse(one)
        XCTAssertTrue(entries.contains { $0.path == "recipes.anthropic.claude-code.version" })
        XCTAssertTrue(entries.allSatisfy { DozableSettings.definition($0.path) != nil })
    }

    // MARK: items 4 and 5 — the migration, and the no-agent images' own defaults

    static let old037 = """
    # a 0.37 doz.toml
    [ui]
    theme = "dark"

    [claude]
    permissions = "ask"

    [codex]
    keep_alive = true

    [grok]
    permissions = "ask"

    [images]
    claude_code_version = "2.1.227"
    fabric_version = "1.4.518"

    [images.claude-code]
    memory_mib = 6144
    """

    func testA037FileReadsWithEveryValueAppliedFromTheMacWithANote() throws {
        let s = DozableSettings(text: Self.old037)
        XCTAssertNil(s.fileError)
        XCTAssertTrue(s.warnings.isEmpty, s.warnings.joined(separator: "\n"))
        let want: [(String, String, TOMLValue)] = [
            ("recipes.anthropic.claude-code.approvals", "claude.permissions", .string("ask")),
            ("recipes.openai.codex.keep_alive", "codex.keep_alive", .bool(true)),
            ("recipes.xai.grok.approvals", "grok.permissions", .string("ask")),
            ("recipes.anthropic.claude-code.version", "images.claude_code_version", .string("2.1.227")),
            ("recipes.danielmiessler.fabric.version", "images.fabric_version", .string("1.4.518")),
            ("recipes.anthropic.claude-code.memory_mib", "images.claude-code.memory_mib", .int(6144)),
            ("defaults.memory_mib", "images.claude-code.memory_mib", .int(6144)),
        ]
        for (key, old, v) in want {
            let r = s.resolve(key)
            XCTAssertEqual(r.value, v, key)
            XCTAssertEqual(r.source, .mac, key)
            XCTAssertEqual(r.migratedFrom, old, key)
            XCTAssertEqual(s.resolve(old).value, v, "\(old) still names it")
        }
        XCTAssertEqual(s.migrationNotes.count, want.count)
        XCTAssertEqual(s.report().notes?.count, want.count)
        XCTAssertEqual(s.report().settings.first { $0.key == "recipes.openai.codex.keep_alive" }?.migratedFrom, "codex.keep_alive")
    }

    func testTheFirstWriteMovesEveryValueAndKeepsTheOldFileOnce() throws {
        try write(Self.old037)
        let read = DozableSettings.load(environment: env)
        XCTAssertFalse(FileManager.default.fileExists(atPath: bak.path), "a read never writes")
        let now = try read.writing("ui.theme", .string("light"))
        XCTAssertNotNil(now.migrationNotice)
        XCTAssertTrue(now.migrationNotice?.contains("doz.toml.0.37.bak") == true)
        // The .bak is the file exactly as it was, private.
        XCTAssertEqual(try String(contentsOf: bak, encoding: .utf8), Self.old037)
        var st = stat()
        XCTAssertEqual(stat(bak.path, &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o600)
        // The new shape: no 0.37 name is written again, and every old value is in its new home, byte for byte.
        let text = try String(contentsOf: file, encoding: .utf8)
        for gone in ["\n[claude]\n", "\n[codex]\n", "\n[grok]\n", "\n[images]\n", "\n[images.claude-code]\n", "claude_code_version", "fabric_version"] {
            XCTAssertFalse(text.contains(gone), gone)
        }
        func block(_ section: String) -> String {
            guard let r = text.range(of: "\n[\(section)]\n") else { return "" }
            let rest = text[r.upperBound...]
            return String(rest[..<(rest.range(of: "\n[")?.lowerBound ?? rest.endIndex)])
        }
        XCTAssertTrue(block("recipes.anthropic.claude-code").contains("\napprovals = \"ask\"\n"))
        XCTAssertTrue(block("recipes.anthropic.claude-code").contains("\nversion = \"2.1.227\"\n"))
        XCTAssertTrue(block("recipes.anthropic.claude-code").contains("\nmemory_mib = 6144\n"))
        XCTAssertTrue(block("recipes.openai.codex").contains("\nkeep_alive = true\n"))
        XCTAssertTrue(block("recipes.xai.grok").contains("\napprovals = \"ask\"\n"))
        XCTAssertTrue(block("recipes.danielmiessler.fabric").contains("\nversion = \"1.4.518\"\n"))
        XCTAssertTrue(block("defaults").contains("\nmemory_mib = 6144\n"), "659 Q8: seeded from claude-code's")
        XCTAssertTrue(block("ui").contains("\ntheme = \"light\"\n"))
        let again = DozableSettings.load(environment: env)
        XCTAssertTrue(again.migrated.isEmpty && !again.hasOldNames && again.warnings.isEmpty, again.warnings.joined(separator: "\n"))
        XCTAssertEqual(again.string("recipes.anthropic.claude-code.version"), "2.1.227")
        // Once: a later write never touches the .bak (even when it is not what the file was).
        try "kept\n".write(to: bak, atomically: true, encoding: .utf8)
        _ = try again.writing("ui.theme", nil)
        XCTAssertEqual(try String(contentsOf: bak, encoding: .utf8), "kept\n")
        XCTAssertNil(try again.writing("ui.theme", .string("dark")).migrationNotice, "said once")
    }

    func testAConflictKeepsTheNewValueTheOldLineAndWarns() throws {
        try write("[recipes.xai.grok]\napprovals = \"skip\"\n\n[grok]\npermissions = \"ask\"\n")
        let s = DozableSettings.load(environment: env)
        XCTAssertEqual(s.string("recipes.xai.grok.approvals"), "skip", "the new key wins")
        XCTAssertTrue(s.warnings.contains { $0.contains("grok.permissions") && $0.contains("recipes.xai.grok.approvals") }, s.warnings.joined(separator: "\n"))
        _ = try s.writingAll(s.fileValues)
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.contains("# not known to this version (kept as they were):\n[grok]\npermissions = \"ask\"\n"), text)
        XCTAssertTrue(text.contains("\n[recipes.xai.grok]\n") && text.contains("\napprovals = \"skip\"\n"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bak.path))
    }

    func testAFileThatDoesNotParseIsNeverTouched() throws {
        let bad = "[images]\nclaude_code_version = [\"x\"]\n"
        try write(bad)
        let s = DozableSettings.load(environment: env)
        XCTAssertNotNil(s.fileError)
        XCTAssertThrowsError(try s.writing("ui.theme", .string("dark")))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), bad)
        XCTAssertFalse(FileManager.default.fileExists(atPath: bak.path))
    }

    func testANoAgentImageKeepsTheMemoryItHad() throws {
        // 0.37: a python sandbox (a base, no agent) took claude-code's memory.
        let s = DozableSettings(text: "[images.claude-code]\nmemory_mib = 6144\nnetwork = \"locked\"\n")
        let keys = DozableSettings.imageKeys(imageSpecName: "python")
        XCTAssertEqual(keys.memory, SettingKey.defaultMemory)
        XCTAssertEqual(s.int(keys.memory), 6144)
        XCTAssertEqual(s.string(keys.network), "locked")
        XCTAssertEqual(DozableSettings(text: "").int(SettingKey.defaultMemory), 2048, "unset: what claude-code's default was")
        XCTAssertEqual(DozableSettings(text: "").string(SettingKey.defaultNetwork), "agent")
        // Set on its own, it is not overridden by the old name.
        let own = DozableSettings(text: "[defaults]\nmemory_mib = 3072\n[images.claude-code]\nmemory_mib = 6144\n")
        XCTAssertEqual(own.int(SettingKey.defaultMemory), 3072)
    }

    // MARK: item 6 — aliases

    func testTheOldNamesAreAliases() throws {
        XCTAssertEqual(DozableSettings.canonicalKey("images.claude_code_version"), "recipes.anthropic.claude-code.version")
        XCTAssertEqual(DozableSettings.canonicalKey("claude.permissions"), "recipes.anthropic.claude-code.approvals")
        XCTAssertEqual(DozableSettings.canonicalKey("codex.keep_alive"), "recipes.openai.codex.keep_alive")
        XCTAssertEqual(DozableSettings.canonicalKey("images.pi.network"), "recipes.earendil-works.pi.network")
        XCTAssertEqual(DozableSettings.canonicalKey("ui.theme"), "ui.theme")
        XCTAssertNil(DozableSettings.canonicalKey("images.nothing_version"))
        // Set and unset by the old name: written under the new one.
        var s = DozableSettings.load(environment: env)
        s = try s.writing("images.claude_code_version", .string("2.1.290"))
        XCTAssertEqual(s.fileValues["recipes.anthropic.claude-code.version"], .string("2.1.290"))
        XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains("claude_code_version"))
        s = try s.writing("images.claude_code_version", nil)
        XCTAssertTrue(s.fileValues.isEmpty)
        // --agent ID NAME, by any of a recipe's names.
        for name in ["claude-code", "claude", "anthropic/claude-code"] {
            let r = try XCTUnwrap(DozableSettings.recipe(named: name), name)
            XCTAssertEqual(DozableSettings.recipeKey(r, "version"), "recipes.anthropic.claude-code.version", name)
        }
        XCTAssertEqual(DozableSettings.recipe(named: "opencode@2")?.id, "opencode2")
        XCTAssertEqual(DozableSettings.recipeKey(try XCTUnwrap(DozableSettings.recipe(named: "codex")), "codex.keep_alive"), "recipes.openai.codex.keep_alive")
        XCTAssertNil(DozableSettings.recipeKey(try XCTUnwrap(DozableSettings.recipe(named: "pi")), "approvals"))
    }
}
