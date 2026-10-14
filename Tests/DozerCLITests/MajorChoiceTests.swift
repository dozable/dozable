import ArgumentParser
import Foundation
@testable import DozerKit
import XCTest
@testable import DozerCLI
@testable import DozerHost

/// 618: an earlier major (or an exact release) can be chosen everywhere a tool is chosen in the CLI — try, new, create,
/// up (`--agent`, `--image`), a project file's `agent:` — and the plan says which release and how to get the other.
final class MajorChoiceTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("doz-majors-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func facts() -> PlanFacts {
        PlanFacts(settings: DozerSettings(text: ""), accounts: AccountsFile(), taken: [], images: [], store: DozerStore(root: root),
                  projectsDir: "/tmp/618-pin-projects")
    }

    func plan(_ purpose: String, _ args: [String]) throws -> CreatePlan {
        CreatePlanner.plan(PlanRequest(purpose: purpose, create: try ChoiceOptions.from(args).planChoices()), facts: facts())
    }

    var recommended: AgentRecipe { AgentRef.recommended("opencode")! }

    func testAgentAndImageTakeAMajorOrARelease() throws {
        let one = try ChoiceOptions.from(["--agent", "opencode@1"]).planChoices()
        XCTAssertEqual(one.image, "opencode")
        XCTAssertEqual(one.agentRef, "opencode@1")
        XCTAssertNil(one.agentVersion)
        let two = try ChoiceOptions.from(["--agent", "opencode@2.0.28"]).planChoices()
        XCTAssertEqual(two.image, "opencode2")
        XCTAssertEqual(two.agentVersion, "2.0.28")
        XCTAssertEqual(two.agentRef, "opencode@2.0.28")
        let img = try ChoiceOptions.from(["--image", "opencode@2"]).planChoices()
        XCTAssertEqual(img.image, "opencode2")
        XCTAssertEqual(img.agentRef, "opencode@2")
        let fam = try ChoiceOptions.from(["--agent", "opencode"]).planChoices()
        XCTAssertEqual(fam.image, recommended.id, "a family's name is its recommended major")
        let based = try ChoiceOptions.from(["--agent", "opencode@2", "--base", "python"]).planChoices()
        XCTAssertEqual(based.image, "python-opencode2")
        XCTAssertThrowsError(try ChoiceOptions.from(["--agent", "opencode@9"]).planChoices()) {
            XCTAssertTrue("\($0)".contains("opencode@1") && "\($0)".contains("opencode@2"), "\($0)")
        }
        // Not a tool: as before.
        XCTAssertEqual(try ChoiceOptions.from(["--image", "lab"]).planChoices().image, "lab")
        XCTAssertNil(try ChoiceOptions.from(["--agent", "grok"]).planChoices().agentRef)
    }

    func testThePlanSaysWhichReleaseAndHowToGetTheOther() throws {
        let p = try plan("try", ["--agent", "opencode@2"])
        XCTAssertEqual(p.argv.prefix(3), ["doz", "try", "opencode@2"])
        let v = try XCTUnwrap(p.version)
        XCTAssertEqual(v.majors.map(\.ref), ["opencode@1", "opencode@2"])
        XCTAssertEqual(v.majors.first(where: \.chosen)?.major, 2)
        XCTAssertEqual(v.version, AgentRecipes.recipe("opencode2")!.install.pinned.version, "never asked: its pin")
        let line = try XCTUnwrap(v.familyLine())
        XCTAssertTrue(line.hasPrefix("OpenCode 2 "), line)
        XCTAssertTrue(line.contains("OpenCode 1"), line)
        XCTAssertTrue(line.contains("doz try opencode@1") || line.contains("doz try opencode"), line)
        XCTAssertFalse(line.lowercased().contains("latest"), "recommended, never latest")
        XCTAssertTrue(renderPlan(p).contains("  version: OpenCode 2"))
        XCTAssertTrue(p.yaml.contains("agent: opencode@2"), p.yaml)
        // A tool that is not a family: its release only.
        let g = try XCTUnwrap(try plan("try", ["--agent", "grok"]).version)
        XCTAssertTrue(g.majors.isEmpty)
        XCTAssertNil(g.familyLine())
        // The command printed for a family member never means another major (its id alone would be the family's).
        let o1 = try plan("create", ["--image", "opencode@1"])
        XCTAssertTrue(o1.argv.contains("opencode@1"), o1.command)
    }

    func testAProjectFileTakesAMajor() throws {
        XCTAssertNil(DozerProject.agentProblem("opencode@1"))
        XCTAssertNil(DozerProject.agentProblem("opencode@2.0.28"))
        XCTAssertNil(DozerProject.agentProblem("none"))
        XCTAssertNotNil(DozerProject.agentProblem("opencode@9"))
        XCTAssertNotNil(DozerProject.agentProblem("nosuch"))
        let yaml = "version: 1\nname: p\nagent: opencode@1\n"
        let p = try DozerProject.parse(yaml)
        XCTAssertEqual(p.agent, "opencode@1")
        XCTAssertEqual(p.chosenImage, "opencode")
        let o = p.createOptions(folder: root, file: root.appendingPathComponent("doz_project.yaml"), settings: DozerSettings(text: ""))
        XCTAssertEqual(o.agentRef, "opencode@1")
        let exact = try DozerProject.parse("version: 1\nname: p\nagent: opencode@2.0.28\n")
        let e = exact.createOptions(folder: root, file: root.appendingPathComponent("doz_project.yaml"), settings: DozerSettings(text: ""))
        XCTAssertEqual(e.image, "opencode2")
        XCTAssertEqual(e.agentVersion, "2.0.28")
        XCTAssertThrowsError(try DozerProject.parse("version: 1\nname: p\nagent: opencode@9\n"))
        // The file round-trips.
        XCTAssertEqual(try DozerProject.parse(p.render()).agent, "opencode@1")
    }

    func testTheListShowsAFamilyOnceAndSearchFindsAMajor() throws {
        let rec = recommended
        let line = searchLine(SearchHit(outcome: "supported", limit: nil, entry: try XCTUnwrap(DirectoryIndex.build(version: "t").entries.first { $0.id == rec.id })),
                              local: nil, base: nil)
        XCTAssertTrue(line.contains("(recommended; also @"), line)
        XCTAssertTrue(line.contains("try it: doz try opencode"), line)
        let other = AgentRef.members("opencode").first { $0.id != rec.id }!
        let o = searchLine(SearchHit(outcome: "supported", limit: nil, entry: try XCTUnwrap(DirectoryIndex.build(version: "t").entries.first { $0.id == other.id })),
                           local: nil, base: nil)
        XCTAssertTrue(o.contains("try it: doz try opencode@\(other.family!.major)"), o)
        let s = try XCTUnwrap(try DozerCommand.parseAsRoot(["search", "opencode@1"]) as? SearchCommand)
        XCTAssertEqual(s.resolvedTerms, ["opencode"])
    }
}
