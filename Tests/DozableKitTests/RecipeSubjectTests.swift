import Foundation
import XCTest
@testable import DozableKit

/// 669 (659 §0, items 1 and 1a): a recipe's subject (what its agent is, beside its name) and its own settings
/// (`com.dozable/settings@1`). The subject rides in the Kit `description` of the recipe's `com.dozable/directory@1`
/// entry — a field every schema 2 reader already takes — so a doz from before 669 still accepts a catalogue whose recipes
/// carry one. The proof against "today's decoder": the schema as it was before 669 (`Tests/Fixtures/recipes-pre-669/`),
/// which RecipeSchemaTests holds the loader to, accepts every compiled recipe that does not use settings@1 (a built-in
/// one only, which a catalogue never carries).
final class RecipeSubjectTests: XCTestCase {
    static let oldSchema = RecipeSchemaTests.root.appendingPathComponent("Tests/Fixtures/recipes-pre-669/dozable-recipe-2.schema.json")

    func testPiAndFabricNameTheirSubjectAndTheRestSayAgent() throws {
        XCTAssertEqual(AgentRecipes.recipe("pi")?.subject, "coding harness")
        XCTAssertEqual(AgentRecipes.recipe("fabric")?.subject, "agentic tool")
        XCTAssertNil(AgentRecipes.recipe("claude-code")?.subject)
        XCTAssertEqual(AgentRecipes.recipe("claude-code")?.subjectWords, "agent", "no subject: generic copy says agent")
        for r in AgentRecipes.all { if let s = r.subject { XCTAssertNil(RecipeSettings.subjectProblem(s), r.id) } }
    }

    func testTheSubjectIsADirectoryDescriptionAndRoundTrips() throws {
        let pi = try XCTUnwrap(AgentRecipes.recipe("pi"))
        let doc = RecipeDocument(pi, vendor: "earendil-works", description: pi.description, licenses: ["MIT"])
        XCTAssertEqual(doc.capabilities.first { $0.type == RecipeDocument.Types.directory }?.description, "coding harness")
        XCTAssertEqual(try doc.recipe().subject, "coding harness")
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(pi), as: UTF8.self).contains("coding harness"),
                       "not a coding key: the recipe's JSON (and so every bake key) is as it was")
    }

    /// Item 1a: a doz from before 669 accepts a catalogue whose recipes carry a subject.
    func testTheSchemaBefore669AcceptsARecipeWithASubject() throws {
        var v = JSONSchemaValidator()
        var checked = 0
        for (f, t) in try RecipeSchemaTests.trees() {
            let caps = t["capabilities"] as? [[String: Any]] ?? []
            if caps.contains(where: { ($0["type"] as? String) == "com.dozable/settings@1" }) {
                // settings@1 is a new capability type: only a built-in recipe (Codex) uses it, and a catalogue never
                // carries a built-in one (RecipeCatalogue.merged keeps this build's).
                XCTAssertTrue(AgentRecipes.recipe(String(f.dropLast(5)))?.isBuiltin == true, f)
                continue
            }
            XCTAssertEqual(v.validate(t, schemaFile: Self.oldSchema), [], "\(f): the pre-669 schema refuses it")
            checked += 1
        }
        XCTAssertGreaterThan(checked, 40)
        // fabric (not built-in: what a catalogue carries) has a subject, and the old contract takes it.
        let fabric = try XCTUnwrap(try RecipeSchemaTests.trees().first { $0.0 == "fabric.json" }?.1)
        let dir = (fabric["capabilities"] as? [[String: Any]])?.first { ($0["type"] as? String) == "com.dozable/directory@1" }
        XCTAssertEqual(dir?["description"] as? String, "agentic tool")
        XCTAssertEqual(v.validate(fabric, schemaFile: Self.oldSchema), [])
    }

    func testOwnSettingsAreClosed() {
        let ok = RecipeSettingOption(name: "keep_alive", type: "bool", default: .bool(false), summary: "x", applies: "now")
        XCTAssertNil(RecipeSettings.problem([ok]))
        var bad = ok; bad.type = "float"
        XCTAssertNotNil(RecipeSettings.problem([bad]))
        bad = ok; bad.name = "approvals"
        XCTAssertNotNil(RecipeSettings.problem([bad]), "a common option is every recipe's")
        bad = ok; bad.default = .string("off")
        XCTAssertNotNil(RecipeSettings.problem([bad]), "its default is of its type")
        bad = ok; bad.applies = "someday"
        XCTAssertNotNil(RecipeSettings.problem([bad]))
        XCTAssertNotNil(RecipeSettings.problem([ok, ok]), "a name once")
        let int = RecipeSettingOption(name: "n", type: "int", min: 1, max: 4, default: .number(9), summary: "x", applies: "now")
        XCTAssertNotNil(RecipeSettings.problem([int]), "the default in its range")
        XCTAssertEqual(AgentRecipes.recipe("codex")?.ownSettings?.map(\.name), ["keep_alive"], "Codex declares its keep-alive")
    }
}
