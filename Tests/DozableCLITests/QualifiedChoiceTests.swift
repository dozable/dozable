import ArgumentParser
import Foundation
@testable import DozableKit
import XCTest
@testable import DozableCLI
@testable import DozableHost
@testable import DozableWeb

/// 654: a qualified name (`[SOURCE/]VENDOR/PRODUCT[@…]`) everywhere a tool is typed — `--agent`, `--image`, `doz try`,
/// a project file's `agent:`, the web plan query, `doz search` — and the recipe's full name where it is shown (the plan,
/// search, the try list's catalog, `doz recipe show`'s target). The grammar itself is QualifiedNameTests'.
final class QualifiedChoiceTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        AgentRecipes.publishEverythingForTests(true)
        root = FileManager.default.temporaryDirectory.appendingPathComponent("doz-qualified-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        AgentRecipes.publishEverythingForTests(false)
        try? FileManager.default.removeItem(at: root)
    }

    func facts() -> PlanFacts {
        PlanFacts(settings: DozableSettings(text: ""), accounts: AccountsFile(), taken: [], images: [], store: DozableStore(root: root),
                  projectsDir: "/tmp/654-qualified-projects")
    }

    func plan(_ purpose: String, _ args: [String]) throws -> CreatePlan {
        let c = try ChoiceOptions.from(args)
        return CreatePlanner.plan(PlanRequest(purpose: purpose, create: try c.planChoices(), baseChosen: c.namesTheBase ? true : nil), facts: facts())
    }

    func testAgentAndImageTakeAQualifiedName() throws {
        let q = try ChoiceOptions.from(["--agent", "anthropic/claude-code"]).planChoices()
        let plain = try ChoiceOptions.from(["--agent", "claude"]).planChoices()
        XCTAssertEqual(q.image, plain.image, "the same sandbox as the short name")
        XCTAssertEqual(q.agentRef, "anthropic/claude-code", "what was typed, for the plan's command and file")
        XCTAssertNil(plain.agentRef, "a plain name records nothing new (618's rule, unchanged)")
        let full = try ChoiceOptions.from(["--agent", "dozable/anthropic/claude-code"]).planChoices()
        XCTAssertEqual(full.image, plain.image)
        let img = try ChoiceOptions.from(["--image", "anomalyco/opencode@1"]).planChoices()
        XCTAssertEqual(img.image, "opencode")
        XCTAssertEqual(img.agentRef, "anomalyco/opencode@1")
        let exact = try ChoiceOptions.from(["--agent", "anomalyco/opencode@2.0.28"]).planChoices()
        XCTAssertEqual(exact.image, "opencode2")
        XCTAssertEqual(exact.agentVersion, "2.0.28")
        XCTAssertEqual(try ChoiceOptions.from(["--agent", "earendil-works/pi", "--base", "python"]).planChoices().image, "python-pi")
        // Refused as the command's own error, in the grammar's words.
        XCTAssertThrowsError(try ChoiceOptions.from(["--agent", "openai/claude-code"]).planChoices()) {
            XCTAssertTrue("\($0)".contains("anthropic/claude-code"), "\($0)")
        }
        // 670: Dozable's directory is `doz.sh` — the same tool as the short name, keeping what was typed; no other host is.
        let dir = try ChoiceOptions.from(["--image", "doz.sh/anthropic/claude-code"]).planChoices()
        XCTAssertEqual(dir.image, plain.image)
        XCTAssertEqual(dir.agentRef, "doz.sh/anthropic/claude-code")
        XCTAssertEqual(try ChoiceOptions.from(["--agent", "doz.sh/anthropic/claude-code"]).planChoices().image, plain.image)
        XCTAssertThrowsError(try ChoiceOptions.from(["--image", "example.com/anthropic/claude-code"]).planChoices()) {
            XCTAssertTrue("\($0)".contains("only doz.sh is a recipe directory"), "\($0)")
        }
        XCTAssertThrowsError(try ChoiceOptions.from(["--agent", "doz.sh/claude-code"]).planChoices()) {
            XCTAssertTrue("\($0)".contains("doz.sh/VENDOR/PRODUCT"), "\($0)")
        }
        // Not a tool: as before.
        XCTAssertEqual(try ChoiceOptions.from(["--image", "lab"]).planChoices().image, "lab")
        XCTAssertEqual(try ChoiceOptions.from(["--image", "python-claude-code"]).planChoices().image, "python-claude-code")
    }

    func testThePlanSaysTheRecipesFullName() throws {
        let p = try plan("try", ["--agent", "anthropic/claude-code"])
        XCTAssertEqual(Array(p.argv.prefix(3)), ["doz", "try", "anthropic/claude-code"])
        let r = try XCTUnwrap(p.version?.recipe)
        XCTAssertTrue(r.hasPrefix("dozable/anthropic/claude-code"), r)
        XCTAssertTrue(renderPlan(p).contains("  recipe: dozable/anthropic/claude-code"), renderPlan(p))
        XCTAssertTrue(p.yaml.contains("agent: anthropic/claude-code"), p.yaml)
        // A plain name's plan says it too (every recipe agent's plan).
        let g = try plan("try", ["--agent", "grok"])
        XCTAssertTrue(g.version?.recipe?.hasPrefix("dozable/xai/grok") == true, g.version?.recipe ?? "none")
        XCTAssertEqual(Array(g.argv.prefix(3)), ["doz", "try", "grok"], "the plain command, unchanged")
        // A family with its vendor: the file keeps the major and the qualification.
        let f = try plan("try", ["--agent", "anomalyco/opencode"])
        let rec = try XCTUnwrap(AgentRef.recommended("opencode"))
        XCTAssertTrue(f.yaml.contains("anomalyco/opencode@\(rec.family!.major)"), f.yaml)
    }

    /// 670: the plan's command and file say what was typed; the recipe's recorded full name stays `dozable/…`.
    func testThePlanForADirectoryName() throws {
        let p = try plan("try", ["--agent", "doz.sh/anthropic/claude-code"])
        XCTAssertEqual(Array(p.argv.prefix(3)), ["doz", "try", "doz.sh/anthropic/claude-code"])
        XCTAssertTrue(p.yaml.contains("agent: doz.sh/anthropic/claude-code"), p.yaml)
        XCTAssertTrue(try XCTUnwrap(p.version?.recipe).hasPrefix("dozable/anthropic/claude-code"))
    }

    /// 670: `doz recipe show doz.sh/VENDOR/PRODUCT` reads as `dozable/VENDOR/PRODUCT` does (Dozable's own recipes are not
    /// shown there: its checks are Dozable's); another host is not a recipe name at all.
    func testRecipeShowTakesADirectoryName() throws {
        let g = try XCTUnwrap(try DozableCommand.parseAsRoot(["recipe", "show", "doz.sh/anthropic/claude-code"]) as? RecipeShow)
        let paths = RecipeExtrasPaths(dir: root.appendingPathComponent("recipes"))
        func message(_ name: String) -> String {
            do { _ = try recipeTarget(name, paths, g.g); return "no refusal" } catch { return "\(error)" }
        }
        XCTAssertEqual(message("doz.sh/anthropic/claude-code"), message("dozable/anthropic/claude-code"))
        XCTAssertNotEqual(message("doz.sh/anthropic/claude-code"), "no refusal")
        XCTAssertFalse(message("example.com/anthropic/claude-code").contains("one of Dozable's own"), "another host is a missing file, not Dozable's recipe")
    }

    func testAProjectFileTakesAQualifiedName() throws {
        XCTAssertNil(DozableProject.agentProblem("anthropic/claude-code"))
        XCTAssertNil(DozableProject.agentProblem("doz.sh/anthropic/claude-code"))
        XCTAssertEqual(try XCTUnwrap(DozableProject.agentProblem("example.com/anthropic/claude-code")).contains("only doz.sh"), true)
        XCTAssertNil(DozableProject.agentProblem("anomalyco/opencode@1"))
        let wrong = try XCTUnwrap(DozableProject.agentProblem("openai/claude-code"))
        XCTAssertTrue(wrong.contains("anthropic/claude-code"), wrong)
        let p = try DozableProject.parse("version: 1\nname: p\nagent: anomalyco/opencode@1\n")
        XCTAssertEqual(p.chosenImage, "opencode")
        let o = p.createOptions(folder: root, file: root.appendingPathComponent("doz_project.yaml"), settings: DozableSettings(text: ""))
        XCTAssertEqual(o.agentRef, "anomalyco/opencode@1")
        XCTAssertEqual(try DozableProject.parse(p.render()).agent, "anomalyco/opencode@1", "the file round-trips")
        XCTAssertEqual(DozableProject.fileAgent("anthropic/claude-code"), "anthropic/claude-code")
        XCTAssertThrowsError(try DozableProject.parse("version: 1\nname: p\nagent: mine/anthropic/claude-code\n"))
    }

    func testSearchFindsAndShowsTheFullName() throws {
        let s = try XCTUnwrap(try DozableCommand.parseAsRoot(["search", "anomalyco/opencode2", "anthropic/claude-code"]) as? SearchCommand)
        XCTAssertEqual(s.resolvedTerms, ["opencode2", "claude-code"])
        let e = try XCTUnwrap(DirectoryIndex.build(version: "t").entries.first { $0.id == "claude-code" })
        XCTAssertEqual(e.qualified, "anthropic/claude-code")
        let line = searchLine(SearchHit(outcome: "supported", limit: nil, entry: e), local: nil, base: nil)
        XCTAssertTrue(line.hasPrefix("\(e.title) · anthropic/claude-code"), line)
        XCTAssertTrue(searchDetails(e).contains("  full name: anthropic/claude-code\n"), searchDetails(e))
        // `doz try` with a qualified THING and --agent naming the same tool agree.
        let t = try XCTUnwrap(try DozableCommand.parseAsRoot(["try", "anthropic/claude-code", "--agent", "claude", "--dry-run"]) as? TryCommand)
        XCTAssertEqual(try AgentRef.resolve(t.thing!)?.bare, try AgentRef.resolve(t.choices.agent!)?.bare)
    }

    func testTheWebPlanQueryAndTheTryCatalog() throws {
        let body = try JSONSerialization.data(withJSONObject: ["purpose": "try", "agent": "anthropic/claude-code"])
        let q = try WebPlanQuery.decode(body)
        XCTAssertEqual(q.request.create.image, "claude-code")
        XCTAssertEqual(q.request.create.agentRef, "anthropic/claude-code")
        let fam = try WebPlanQuery.decode(try JSONSerialization.data(withJSONObject: ["purpose": "try", "agent": "anomalyco/opencode@1"]))
        XCTAssertEqual(fam.request.create.image, "opencode")
        // 670: Dozable's directory in the web plan: the same recipe, what was typed kept.
        let dz = try WebPlanQuery.decode(try JSONSerialization.data(withJSONObject: ["purpose": "try", "agent": "doz.sh/anthropic/claude-code"]))
        XCTAssertEqual(dz.request.create.image, "claude-code")
        XCTAssertEqual(dz.request.create.agentRef, "doz.sh/anthropic/claude-code")
        for bad in ["example.com/anthropic/claude-code", "doz.sh/claude-code", "openai/claude-code", String(repeating: "a/", count: 90)] {
            XCTAssertThrowsError(try WebPlanQuery.decode(try JSONSerialization.data(withJSONObject: ["purpose": "try", "agent": bad])), bad)
        }
        let list = WebTryCatalog.list(secretEntry: false)
        XCTAssertEqual(list.agents.first { $0.id == "claude-code" }?.qualified, "anthropic/claude-code")
        if let other = AgentRef.members("opencode").first(where: { !($0.family?.isRecommended ?? false) }), let a = list.agents.first(where: { $0.id == other.id }) {
            XCTAssertEqual(a.qualified, "anomalyco/opencode@\(other.family!.major)", "the name that means exactly that major")
        }
    }

    func testASourceCannotTakeTheWordsOfANamesSource() throws {
        XCTAssertTrue(RecipeOrigin.reservedSourceNames.contains("mine"))
        XCTAssertTrue(RecipeOrigin.reservedSourceNames.contains("dozable"))
        XCTAssertTrue(RecipeOrigin.isSourceName("mine"), "well formed — refused by `doz recipe source add` as reserved")
    }
}
