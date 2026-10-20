import Foundation
@testable import DozableKit
import XCTest
@testable import DozableCLI
@testable import DozableHost

/// 634 (owner: "focus a single base image … all the tool layers being added to the existing single base image"): a
/// quick-made sandbox's tool goes on the store's base (`defaults.base`, node unless set) — not its recipe's default — unless
/// the person named one; the command shows `--base` only when it differs from that; every published tool on Node shares
/// ONE flattened base disk (the same base key).
final class StoreBaseTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("doz-storebase-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func facts(_ toml: String = "") -> PlanFacts {
        PlanFacts(settings: DozableSettings(text: toml), accounts: AccountsFile(), taken: [], images: [], store: DozableStore(root: root),
                  projectsDir: "/tmp/634-storebase-projects")
    }

    func tryPlan(_ args: [String], _ f: PlanFacts, baseChosen: Bool? = nil) throws -> CreatePlan {
        CreatePlanner.plan(PlanRequest(purpose: "try", create: try ChoiceOptions.from(args).planChoices(), baseChosen: baseChosen), facts: f)
    }

    func testAQuickMadeSandboxUsesTheStoresBase() throws {
        // OpenCode's recipe defaults to Debian; the store's base (node by default) wins — no second base download.
        let p = try tryPlan(["--agent", "opencode"], facts())
        XCTAssertEqual(p.image, "node-opencode2")
        XCTAssertEqual(p.create.image, "node-opencode2")
        XCTAssertEqual(p.command, "doz try opencode", "the store's base is the try's default: no --base")
        // The built-in three are on Node already: unchanged names.
        XCTAssertEqual(try tryPlan(["--agent", "claude-code"], facts()).image, "claude-code")
        XCTAssertEqual(try tryPlan(["--agent", "pi"], facts()).image, "pi")
        // Another store base: OpenCode on Debian is its own default (its own name); Claude Code goes on Debian too.
        let deb = facts("[defaults]\nbase = \"debian\"\n")
        XCTAssertEqual(try tryPlan(["--agent", "opencode"], deb).image, "opencode2")
        let cc = try tryPlan(["--agent", "claude-code"], deb)
        XCTAssertEqual(cc.image, "debian-claude-code")
        XCTAssertEqual(cc.command, "doz try claude-code", "the store's base needs no flag")
    }

    func testABaseThePersonNamedIsKept() throws {
        let p = try tryPlan(["--agent", "opencode", "--base", "debian"], facts(), baseChosen: true)
        XCTAssertEqual(p.image, "opencode2")
        XCTAssertEqual(p.command, "doz try opencode --base debian", "a base other than the store's is said")
        // New sandbox / doz new / doz_project.yaml keep the recipe's default (a project means the same on every Mac).
        let n = CreatePlanner.plan(PlanRequest(purpose: "new", create: try ChoiceOptions.from(["--agent", "opencode"]).planChoices()), facts: facts())
        XCTAssertEqual(n.image, "opencode2")
    }

    func testAToolThatCannotRunOnTheStoresBaseKeepsItsOwn() throws {
        let opencode = try XCTUnwrap(AgentRecipes.recipe("opencode2"))
        XCTAssertFalse(opencode.platforms.musl)
        XCTAssertEqual(CreatePlanner.tryBase(opencode, settings: DozableSettings(text: "[defaults]\nbase = \"alpine\"\n")), opencode.defaultBase)
        XCTAssertEqual(CreatePlanner.tryBase(opencode, settings: DozableSettings(text: "")), "node")
    }

    func testTheToolsOnNodeShareOneBaseKey() throws {
        let store = DozableStore(root: root)
        let keys = try ["claude-code", "pi", "codex", "node-opencode2", "node"].map { image -> String in
            let spec = try XCTUnwrap(DozableImages.spec(name: "k", options: CreateOptions(image: image), store: store).0.imageSpec, image)
            return spec.baseKey
        }
        XCTAssertEqual(Set(keys).count, 1, "one flattened Node base disk for every tool on it: \(keys.map { String($0.prefix(12)) })")
    }
}
