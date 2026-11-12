import Foundation
import XCTest
@testable import DozableKit

/// 678: a start decodes the compiled-in recipes WITHOUT the unknown-key round trip and `check()` (they are this build's
/// own bytes) — so this suite is where every one of them gets the full, checked decode, in `make test` and CI.
final class EmbeddedRecipesCheckedTests: XCTestCase {
    func testEveryCompiledInDocumentPassesTheFullCheckedDecode() throws {
        let docs = AgentRecipes.embeddedDocuments
        XCTAssertEqual(docs.map(\.0), AgentRecipes.compiledFiles, "embeddedDocuments and compiledFiles name the same files, in order")
        var checked: [AgentRecipe] = []
        for (name, bytes) in docs {
            do {
                let d = try RecipeDocument.decode(Data(bytes), checked: true)
                let r = try d.recipe()
                try r.validate()
                checked.append(r)
            } catch {
                XCTFail("\(name): \(error)")
            }
        }
        try AgentRecipes.validate(checked)
        try AgentLifecycle.validate(recipes: checked, known: RecipeSet.embedded.known)
    }

    /// The unchecked decode a start uses gives the very same model as the checked one.
    func testTheUncheckedDecodeGivesTheSameRecipes() throws {
        for (name, bytes) in AgentRecipes.embeddedDocuments {
            let full = try RecipeDocument.decode(Data(bytes)).recipe()
            let fast = try RecipeDocument.decode(Data(bytes), checked: false).recipeUnchecked()
            XCTAssertEqual(try JSONEncoder.sorted.encode(full), try JSONEncoder.sorted.encode(fast), name)
            XCTAssertEqual(fast.vendor, full.vendor, name)
            XCTAssertEqual(fast.subject, full.subject, name)
        }
        XCTAssertEqual(AgentRecipes.embedded().map(\.id), RecipeSet.embedded.recipes.map(\.id))
    }

    /// The unchecked decode is for the compiled-in bytes only: the default still refuses an unknown key and a bad check.
    func testTheDefaultDecodeStillChecks() throws {
        let bytes = Data(AgentRecipes.embeddedDocuments[0].1)
        var tree = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        tree["surprise"] = 1
        let unknown = try JSONSerialization.data(withJSONObject: tree)
        XCTAssertThrowsError(try RecipeDocument.decode(unknown))
        tree["surprise"] = nil
        tree["kind"] = "other"
        XCTAssertThrowsError(try RecipeDocument.decode(try JSONSerialization.data(withJSONObject: tree)))
    }

    func testTheTemplateExpressionIsCompiledOnceAndStillMatches() {
        XCTAssertEqual(RecipeDocument.templateNames("a ${{ kit.args.version }} b ${{dozable.model}}"), ["kit.args.version", "dozable.model"])
        XCTAssertEqual(RecipeDocument.toModel("x${{ kit.args.version }}y${{ dozable.base_url }}"), "x{version}y{base_url}")
    }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }
}
