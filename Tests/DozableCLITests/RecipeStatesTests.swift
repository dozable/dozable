import Foundation
@testable import DozableKit
import XCTest
@testable import DozableHost

/// 669 (659 §0, item 16): a recipe's state on this Mac — in use (a sandbox runs it), installed (a baked image, or this
/// Mac's values with none: "not installed"), available — and uninstalling one: refused while a sandbox runs it, naming
/// them; its settings kept unless forgotten. In-process host (create never boots), scratch store and settings.
final class RecipeStatesTests: XCTestCase {
    private var root: URL!
    let keychain = FakeKeychain()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("doz-states-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    var store: DozableStore { DozableStore(root: root.appendingPathComponent("store")) }

    func core() async -> HostCore {
        let s = CredentialServices(keychain: keychain, verifier: FakeVerifier(answer: .verified), claudeBinary: { nil }, home: root,
                                   keepaliveRunner: FakeRunner(), isClaudeRunning: { false }, watchInterval: .seconds(3600))
        let c = HostCore(store: store, readOnly: false, version: "test", services: s)
        await c.load()
        return c
    }

    func testStatesComeFromTheStoreAndThisMacsValues() async throws {
        let c = await core()
        var r = HostRequest(.create, name: "work")
        r.create = CreateOptions(image: "claude-code")
        let m = await c.handle(r)
        XCTAssertNil(m.error, m.error?.message ?? "")
        let settings = DozableSettings(text: "[recipes.xai.grok]\napprovals = \"ask\"\n[defaults]\nimage = \"claude-code\"\n")
        let rows = Dictionary(uniqueKeysWithValues: RecipeStates.all(store: store, settings: settings).map { ($0.id, $0) })
        let cc = try XCTUnwrap(rows["claude-code"])
        XCTAssertEqual(cc.state, RecipeStateRow.inUse)
        XCTAssertEqual(cc.sandboxes, ["work"])
        XCTAssertTrue(cc.isDefault, "★: defaults.image's agent")
        XCTAssertEqual(cc.qualified, "anthropic/claude-code")
        let grok = try XCTUnwrap(rows["grok"])
        XCTAssertEqual(grok.state, RecipeStateRow.installed, "Mac values and no image: listed with the installed ones")
        XCTAssertTrue(grok.notInstalled)
        XCTAssertEqual(grok.macValues, ["approvals": .string("ask")])
        XCTAssertEqual(rows["gemini"]?.state, RecipeStateRow.available)
        XCTAssertEqual(rows["pi"]?.subject, "coding harness")
        XCTAssertTrue(RecipeStates.line(Array(rows.values)).hasPrefix("Recipes in use: Claude Code · installed: Grok Build (not installed)"),
                      RecipeStates.line(Array(rows.values)))
    }

    func testUninstallIsRefusedWhileASandboxRunsItNamingThem() {
        var row = RecipeStateRow(id: "pi", qualified: "earendil-works/pi", title: "pi", subject: "coding harness", source: "Dozable", state: RecipeStateRow.inUse,
                                 notInstalled: false, sandboxes: ["a", "b"], images: [RecipeImage(name: "pi", allocatedBytes: 10), RecipeImage(name: "python-pi", allocatedBytes: 5)],
                                 imageBytes: 15, isDefault: false, macValues: [:], section: "recipes.earendil-works.pi", published: true)
        let refused = RecipeStates.uninstallPlan(row)
        XCTAssertTrue(refused.refusal?.contains("in use by a, b") == true, refused.refusal ?? "")
        XCTAssertTrue(refused.ids.isEmpty)
        row.sandboxes = []
        XCTAssertEqual(RecipeStates.uninstallPlan(row).ids, ["image:pi", "image:python-pi"], "Resources' own ids — its path deletes them")
        XCTAssertNil(RecipeStates.uninstallPlan(row).refusal)
    }

    func testItsSettingsAreKeptUnlessForgotten() throws {
        let xdg = root.appendingPathComponent("xdg")
        let env = ["XDG_CONFIG_HOME": xdg.path]
        var s = DozableSettings.load(environment: env)
        s = try s.writing("recipes.earendil-works.pi.memory_mib", .int(4096))
        s = try s.writing("ui.theme", .string("dark"))
        // Uninstalling without --forget-settings writes nothing: the values stay (it is listed "not installed").
        let kept = RecipeStates.all(store: store, settings: s).first { $0.id == "pi" }
        XCTAssertEqual(kept?.state, RecipeStateRow.installed)
        XCTAssertEqual(kept?.notInstalled, true)
        s = try RecipeStates.forgetSettings("pi", settings: s)
        XCTAssertNil(s.fileValues["recipes.earendil-works.pi.memory_mib"])
        XCTAssertEqual(s.fileValues["ui.theme"], .string("dark"), "the file's other values kept")
        XCTAssertEqual(RecipeStates.all(store: store, settings: s).first { $0.id == "pi" }?.state, RecipeStateRow.available, "then not listed at all")
    }
}
