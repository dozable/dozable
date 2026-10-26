import Foundation
import XCTest

/// 655: the recipe audit (`Scripts/recipe_audit.py`, `make recipe-audit`) is Python; its decisions are tested by
/// `Tests/Scripts/test_recipe_audit.py` on fixtures with the network refused. This runs that suite inside `make test`
/// (the same as `make test-recipe-audit`), so a change to the audit, to `BaseCatalogue.swift`'s pins or to a recipe's
/// YAML shape the pin rewrite relies on fails here.
final class RecipeAuditScriptTests: XCTestCase {
    func testTheAuditsDecisionsOnFixturesWithNoNetwork() throws {
        let root = AgentRecipeTests.packageRoot
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = ["-I", "-W", "error::ResourceWarning", "Tests/Scripts/test_recipe_audit.py"]
        p.currentDirectoryURL = root
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, text)
        XCTAssertTrue(text.contains("\nOK"), text)
    }
}
