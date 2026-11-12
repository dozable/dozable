import Foundation
import DozableKit
import XCTest
@testable import DozableHost

/// 678: a settings read builds the recipes' settings only when it needs them. Dozable's own keys are checked at once
/// against the core schema; every other line is settled the first time one is asked for — with exactly what the eager
/// read gave (the reference below IS that read: every line through the full schema, in file order).
final class SettingsLazySchemaTests: XCTestCase {
    /// What `init(text:)` read before 678: every entry through the full index.
    private func eager(_ text: String) throws -> SettingsRest.Settled {
        let entries = try TOML.parse(text)
        return DozableSettings.settle(entries.enumerated().map { ($0.offset, $0.element) }, core: [:], coreWarnings: [])
    }

    private func assertSame(_ text: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let want = try eager(text)
        let s = DozableSettings(text: text)
        XCTAssertEqual(s.fileValues.all, want.values, file: file, line: line)
        XCTAssertEqual(s.warnings, want.warnings, file: file, line: line)
        XCTAssertEqual(s.unknown, want.unknown, file: file, line: line)
        XCTAssertEqual(s.migrated, want.migrated, file: file, line: line)
        XCTAssertEqual(s.hasOldNames, want.oldNames, file: file, line: line)
        XCTAssertEqual(s.migrationNotes, DozableSettings(text: text).migrationNotes, file: file, line: line)
        for k in want.values.keys { XCTAssertEqual(DozableSettings(text: text).fileValues[k], want.values[k], k, file: file, line: line) }
    }

    // (1) the full schema is the core one then each recipe's, key for key, in order.
    func testTheFullSchemaIsCoreThenEveryRecipesInOrder() {
        let core = DozableSettings.coreSchema(images: DozableSettings.builtinImages)
        let recipe = AgentRecipes.all.flatMap(DozableSettings.recipeSchema)
        let full = DozableSettings.schema
        XCTAssertEqual(full.map(\.key), core.map(\.key) + recipe.map(\.key))
        XCTAssertEqual(DozableSettings.coreIndexed.schema.map(\.key), core.map(\.key))
        for (a, b) in zip(full, core) where a.key != SettingKey.defaultImage {
            XCTAssertEqual(a.type, b.type, a.key)
            XCTAssertEqual(a.defaultValue, b.defaultValue, a.key)
            XCTAssertEqual(a.summary, b.summary, a.key)
            XCTAssertEqual(a.environment, b.environment, a.key)
            XCTAssertEqual(a.flag, b.flag, a.key)
            XCTAssertEqual(a.aliases, b.aliases, a.key)
            XCTAssertNil(b.agent, "\(a.key): a core key is no recipe's")
        }
        // defaults.image: the core offers the built-in images; the full definition every recipe agent too.
        let image = DozableSettings.definition(SettingKey.defaultImage)
        XCTAssertEqual(image?.type, .choice(DozableSettings.builtinImages + DozableSettings.recipeAgents.map(\.id)))
        XCTAssertNil(DozableSettings.coreDefinition(SettingKey.defaultImage))
        // No core key has an old name (the core-final rule leans on it — a new one must come with its migration here).
        XCTAssertTrue(core.allSatisfy(\.aliases.isEmpty))
        XCTAssertEqual(DozableSettings.canonicalKey("store.path"), "store.path")
        XCTAssertEqual(DozableSettings.canonicalKey("images.claude_code_version"), "recipes.anthropic.claude-code.version")
    }

    // (2) a file of Dozable's own keys only: the same values and warnings, and nothing waits on the recipes.
    func testACoreOnlyFileReadsTheSameAndSettlesNothingLater() throws {
        let text = "[store]\npath = \"/tmp/x\"\n\n[defaults]\ncpus = 99999\nimage = \"pi\"\n\n[telemetry]\nsend_anonymous_usage_stats = false\n\n[ui]\ntheme = \"dark\"\n"
        try assertSame(text)
        let s = DozableSettings(text: text)
        XCTAssertTrue(s.rest.isSettled, "no line needs a recipe")
        XCTAssertEqual(s.fileValues[SettingKey.storePath], .string("/tmp/x"))
        XCTAssertEqual(s.fileValues[SettingKey.defaultImage], .string("pi"))
        XCTAssertEqual(s.warnings.count, 1, s.warnings.joined(separator: "\n"))
    }

    // (3) a recipe key, a 0.37 name, a seeded one, an unknown key and a recipe agent as the image: the same values,
    // warnings, unknown keys and migration notes — and reading a core key first settles nothing.
    func testRecipeKeysOldNamesAndUnknownKeysReadTheSameWhenAskedFor() throws {
        let text = """
        [store]
        path = "/tmp/y"

        [defaults]
        image = "gemini"
        cpus = 0

        [future]
        thing = 1

        [recipes.xai.grok]
        approvals = "skip"

        [grok]
        permissions = "ask"

        [images]
        claude_code_version = "2.1.290"

        [images.claude-code]
        memory_mib = 4096

        [ui]
        colour = "red"

        """
        try assertSame(text)
        let s = DozableSettings(text: text)
        XCTAssertEqual(s.fileValues[SettingKey.storePath], .string("/tmp/y"))
        XCTAssertEqual(s.resolve(SettingKey.storePath).value, .string("/tmp/y"))
        XCTAssertFalse(s.rest.isSettled, "a core read settles nothing")
        XCTAssertEqual(s.fileValues[SettingKey.defaultImage], .string("gemini"), "a recipe agent as the image waits for the full definition")
        XCTAssertTrue(s.rest.isSettled)
        // A seeded core key (the migration fills defaults.memory_mib from claude-code's old name) is not core-final.
        let t = DozableSettings(text: text)
        XCTAssertEqual(t.fileValues[SettingKey.defaultMemory], .int(4096))
        XCTAssertEqual(t.resolve(SettingKey.defaultMemory).migratedFrom, "images.claude-code.memory_mib")
        XCTAssertFalse(t.migrationNotes.isEmpty)
        // A bad image is refused with the full definition's words.
        try assertSame("[defaults]\nimage = \"nosuch\"\n")
    }

    // (4) a file that does not parse is still ignored whole.
    func testAFileThatDoesNotParseIsIgnoredWhole() throws {
        let s = DozableSettings(text: "[store]\npath = \"/tmp/z\"\nthis is not toml\n")
        XCTAssertNotNil(s.fileError)
        XCTAssertTrue(s.fileValues.isEmpty)
        XCTAssertNil(s.fileValues[SettingKey.storePath])
        XCTAssertEqual(s.warnings.count, 1)
        XCTAssertTrue(s.warnings[0].contains("the file is ignored until it is fixed"), s.warnings[0])
        XCTAssertTrue(s.unknown.isEmpty)
        XCTAssertFalse(s.hasOldNames)
        let r = DozableSettings(text: nil, readError: "x is not a file")
        XCTAssertTrue(r.fileValues.isEmpty)
        XCTAssertEqual(r.warnings, ["x is not a file — the file is ignored until it is fixed (or removed)"])
    }
}
