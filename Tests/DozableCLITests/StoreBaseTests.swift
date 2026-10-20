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

    /// The orchestrator's ruling B: onboarding's First sandbox is made the quick way (the store's base, a new empty
    /// folder; 635: a new sandbox's network, Standard — no longer Locked) but named after its tool, and its command is the
    /// `doz new` that makes the same sandbox.
    func testTheFirstSandboxIsNamedAfterItsToolAndItsCommandIsDozNew() throws {
        func first(_ args: [String], _ f: PlanFacts, name: String? = nil) throws -> CreatePlan {
            CreatePlanner.plan(PlanRequest(purpose: "first", name: name, create: try ChoiceOptions.from(args).planChoices()), facts: f)
        }
        let cc = try first(["--agent", "claude-code"], facts())
        XCTAssertEqual(cc.name, "claude")
        XCTAssertEqual(cc.workspace, "/tmp/634-storebase-projects/claude", "a new empty folder of its own")
        XCTAssertNil(cc.create.network)
        XCTAssertEqual(cc.command, "doz new claude --agent claude-code")
        XCTAssertTrue(cc.problems.allSatisfy { $0.code == "key" }, "\(cc.problems)")
        // OpenCode on the store's base (Node.js, not its recipe's Debian): said with --base.
        let oc = try first(["--agent", "opencode"], facts())
        XCTAssertEqual(oc.name, "opencode")
        XCTAssertEqual(oc.image, "node-opencode2")
        XCTAssertEqual(oc.command, "doz new opencode --agent opencode --base node")
        // Taken: uniquified, as a try's name is.
        var f = facts()
        f.taken = ["claude"]
        XCTAssertEqual(try first(["--agent", "claude-code"], f).name, "claude-2")
        // A name and a project folder given: kept, and said.
        let named = try first(["--agent", "pi", "--workspace", "/tmp/634-storebase-mine"], facts(), name: "work")
        XCTAssertEqual(named.name, "work")
        XCTAssertEqual(named.workspace, "/tmp/634-storebase-mine")
        XCTAssertEqual(named.command, "doz new work --agent pi --workspace /tmp/634-storebase-mine")
        // A try keeps its own name.
        XCTAssertEqual(try tryPlan(["--agent", "claude-code"], facts()).name, "try-claude")
    }

    func testOnboardsFlags() throws {
        XCTAssertNoThrow(try Onboard.parse(["--base", "python", "--key", "openrouter", "--key-name", "or", "--secret-stdin", "--first", "claude"]).validate())
        XCTAssertNoThrow(try Onboard.parse(["--no-base", "--yes", "--first", "none"]).validate())
        XCTAssertThrowsError(try Onboard.parse(["--base", "nonsense"]).validate())
        XCTAssertThrowsError(try Onboard.parse(["--base", "node", "--no-base"]).validate())
        XCTAssertThrowsError(try Onboard.parse(["--key", "nonsense"]).validate())
        XCTAssertThrowsError(try Onboard.parse(["--key-name", "x"]).validate(), "--key-name goes with --key")
        XCTAssertThrowsError(try Onboard.parse(["--key", "xai", "--plan", "max"]).validate(), "--plan goes with setup-token")
        XCTAssertThrowsError(try Onboard.parse(["--first", "nonsense"]).validate())
        XCTAssertThrowsError(try Onboard.parse(["--status", "--base", "node"]).validate())
        XCTAssertEqual(OnboardingFlow.firstTool("claude")?.id, "claude-code")
        XCTAssertEqual(OnboardingFlow.firstTool("opencode")?.id, "opencode2", "a family's name is its recommended major")
        XCTAssertTrue(OnboardingFlow.keyWords.contains("openrouter"))
        XCTAssertTrue(OnboardingFlow.keyWords.contains("setup-token"))
    }

    func testOnboardStatusSaysTheBase() throws {
        let b = try XCTUnwrap(BaseCatalogue.base("node"))
        var st = PrepareStatus(preparations: [], onboarded: nil, images: [], hostRunning: false)
        st.base = BaseState(b, prepared: true)
        XCTAssertTrue(Onboard.render(st).contains("base node ready — Node.js, node:"), Onboard.render(st))
        st.base = BaseState(b, prepared: false)
        XCTAssertTrue(Onboard.render(st).contains("base node not prepared"))
        XCTAssertEqual(OnboardingFlow.baseLine(st, base: "node"), nil, "nothing to say while nothing runs and it is not ready")
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
