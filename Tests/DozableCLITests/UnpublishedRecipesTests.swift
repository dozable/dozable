import ArgumentParser
import Foundation
@testable import DozableKit
import XCTest
@testable import DozableCLI
@testable import DozableHost
@testable import DozableWeb

/// 629 (owner: "withdraw most of the recipes … keep only: claude code, open ai codex, pi, opencode and openrouter as the
/// gateway. Everything else gets retracted and set to 'unpublished'"): `directory@1` `published: false` (and gateways.json's)
/// takes a tool out of every list a person picks from and refuses it for a NEW sandbox by name — while everything stored
/// (a sandbox, its image, its account, its settings) keeps working, because the full set stays the validator.
final class UnpublishedRecipesTests: XCTestCase {
    static let offered = ["claude-code", "pi", "codex", "opencode", "opencode2"]
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("doz-629-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    // MARK: the set

    func testThePublishedSetIsTheFiveAndOpenRouter() {
        XCTAssertEqual(AgentRecipes.published.map(\.id), Self.offered)
        XCTAssertEqual(Gateways.published.map(\.id), ["openrouter"])
        XCTAssertEqual(ModelSources.publishedGateways, ["openrouter"])
        XCTAssertFalse(ModelSources.isPublished("vercel-ai-gateway"))
        XCTAssertTrue(ModelSources.isPublished("xai"), "a provider is never unpublished by this")
        // The full set stays: every recipe decodes, validates and is still named.
        XCTAssertEqual(AgentRecipes.all.count, AgentRecipes.compiledFiles.count)
        XCTAssertNoThrow(try AgentRecipes.validate(AgentRecipes.all))
        XCTAssertEqual(Gateways.all.map(\.id), ["openrouter", "vercel-ai-gateway"])
        XCTAssertEqual(ModelSources.ids.filter(ModelSources.isGateway), ["openrouter", "vercel-ai-gateway"])
        for r in AgentRecipes.all where !Self.offered.contains(r.id) {
            XCTAssertFalse(r.isPublished, r.id)
            XCTAssertNotNil(AgentKind(rawValue: r.id), r.id)
        }
        XCTAssertEqual(AgentKind.published.map(\.rawValue), ["claude-code", "pi", "none", "codex", "opencode", "opencode2"])
    }

    // MARK: every list shows only those

    func testEveryListShowsOnlyThePublished() throws {
        XCTAssertEqual(WebTryCatalog.list(secretEntry: true).agents.map(\.id).sorted(), Self.offered.sorted())
        XCTAssertEqual(WebBases.catalogAgents.map(\.id), Self.offered)
        XCTAssertEqual(DozableProject.agentWords, "claude-code, pi, codex, opencode or none")
        let index = DirectoryIndex.build(version: "t")
        XCTAssertEqual(index.entries.filter { $0.kind == "agent" && $0.status == "supported" }.map(\.id).sorted(), Self.offered.sorted())
        XCTAssertFalse(index.entries.contains { $0.id == "vercel-ai-gateway" })
        for e in index.entries where e.kind == "agent" && e.status == "supported" {
            XCTAssertEqual(e.gateways.map(\.gateway), ["openrouter"], e.id)
            XCTAssertFalse(e.tags.contains { $0.tag == "gateway:vercel-ai-gateway" }, e.id)
        }
        for e in index.entries where e.kind != "agent" { for a in e.agents ?? [] { XCTAssertTrue(Self.offered.contains(a), "\(e.id): \(a)") } }
        XCTAssertTrue(DirectorySearch.search(SearchQuery.parse(["grok"]), in: index).hits.allSatisfy { $0.entry.id != "grok" })
        // The gateway: the Quick try's pill and the plan's offer.
        let oc2 = try XCTUnwrap(AgentRecipes.recipe("opencode2"))
        XCTAssertTrue(oc2.offeredSources.contains("vercel-ai-gateway"), "still a source it CAN use (a sandbox on it keeps it)")
        XCTAssertFalse(oc2.publishedSources.contains("vercel-ai-gateway"))
        XCTAssertTrue(oc2.throughGateway)
        let p = CreatePlanner.plan(PlanRequest(purpose: "try", create: try ChoiceOptions.from(["--agent", "opencode@2"]).planChoices()),
                                   facts: PlanFacts(settings: DozableSettings(text: ""), accounts: AccountsFile(), taken: [], images: [],
                                                    store: DozableStore(root: root), projectsDir: root.path))
        let offered = try XCTUnwrap(p.model?.offered.map(\.id))
        XCTAssertTrue(offered.contains("openrouter"))
        XCTAssertFalse(offered.contains("vercel-ai-gateway"))
        // Accounts & keys and New Sandbox.
        let a = WebAccounts(accounts: [], defaultAccount: "mac", keepalive: false)
        XCTAssertEqual(a.gatewaySources, ["openrouter"])
        XCTAssertFalse(a.providers.contains("vercel-ai-gateway"))
        XCTAssertNil(a.agents["grok"])
        for (id, s) in a.sources {
            XCTAssertTrue(Self.offered.contains(id), id)
            XCTAssertFalse(s.contains("vercel-ai-gateway"), id)
        }
        for ids in a.providerTools.values { for id in ids { XCTAssertTrue(Self.offered.contains(id), id) } }
        // A Vercel key already here keeps its card.
        var row = AccountRow(name: "v1", kind: "key", plan: nil, identity: nil, expiresAt: nil, verification: "unchecked",
                             isDefault: true, usedBy: [], state: "ok", keychainService: "doz-key:v1", fingerprint: "abc")
        row.provider = "vercel-ai-gateway"
        XCTAssertTrue(WebAccounts(accounts: [WebAccount(row)], defaultAccount: "mac", keepalive: false).providers.contains("vercel-ai-gateway"))
    }

    func testSettingsListThePublishedAndAcceptEveryAgent() throws {
        let plain = DozableSettings(text: "")
        XCTAssertEqual(plain.report().settings.map(\.key), DozableSettings.schema.map(\.key), "doz config show: the whole schema")
        let rep = plain.report(offered: true)
        XCTAssertFalse(rep.settings.contains { $0.key == "recipes.xai.grok.version" })
        XCTAssertTrue(rep.settings.contains { $0.key == "recipes.anomalyco.opencode.version" })
        let choices = try XCTUnwrap(rep.settings.first { $0.key == SettingKey.defaultImage }?.choices)
        XCTAssertEqual(choices, ["lab", "claude-code", "pi", "codex", "opencode", "opencode2"])
        // Stored: an unpublished agent's key and defaults.image still parse, apply and are listed — no warning.
        let held = DozableSettings(text: "[defaults]\nimage = \"grok\"\n\n[images]\ngrok_version = \"1.0.52\"\n")
        XCTAssertEqual(held.warnings, [])
        XCTAssertEqual(held.string(SettingKey.defaultImage), "grok")
        XCTAssertEqual(held.string("images.grok_version"), "1.0.52")
        let r2 = held.report(offered: true)
        XCTAssertTrue(r2.settings.contains { $0.key == "recipes.xai.grok.version" }, "a set agent's settings are listed")
        XCTAssertTrue(r2.settings.first { $0.key == SettingKey.defaultImage }?.choices?.contains("grok") == true, "and the value it has")
        XCTAssertNotNil(DozableSettings.definition("images.gemini_version"), "the schema stays complete")
        // Onboarding (634): it chooses the store's base, never an image — the body names no agent at all.
        XCTAssertThrowsError(try WebOnboardingConfig.decode(Data(#"{"defaultImage":"grok","account":"later"}"#.utf8)))
        XCTAssertThrowsError(try WebOnboardingConfig.decode(Data(#"{"base":"grok"}"#.utf8))) { e in
            XCTAssertFalse("\(e)".contains("grok"), "a refusal never echoes the value: \(e)")
        }
    }

    // MARK: a new sandbox by typed name is refused

    func testATypedNameOfAnUnpublishedToolIsRefused() throws {
        let said = "Grok Build is unpublished in this version of Dozable — see doz search for the tools offered now"
        XCTAssertThrowsError(try AgentRef.resolve("grok")) { XCTAssertEqual("\($0)", said) }
        XCTAssertThrowsError(try AgentRef.resolve("grok@1")) { XCTAssertEqual("\($0)", said) }
        XCTAssertThrowsError(try AgentRef.resolve("agy")) { XCTAssertTrue("\($0)".hasPrefix("Antigravity CLI is unpublished"), "\($0)") }
        XCTAssertEqual(try AgentRef.resolve("opencode")?.recipe.id, AgentRef.recommended("opencode")?.id)
        XCTAssertEqual(try AgentRef.resolve("claude")?.recipe.id, "claude-code")
        // CLI: --agent, --image, --gateway.
        XCTAssertThrowsError(try ChoiceOptions.from(["--agent", "grok"]).planChoices()) { XCTAssertEqual("\($0)", said) }
        XCTAssertThrowsError(try ChoiceOptions.from(["--image", "grok"]).planChoices()) { XCTAssertEqual("\($0)", said) }
        XCTAssertThrowsError(try ChoiceOptions.from(["--image", "python-gemini"]).options()) { XCTAssertTrue("\($0)".hasPrefix("Gemini CLI is unpublished"), "\($0)") }
        XCTAssertEqual(try ChoiceOptions.from(["--image", "lab"]).planChoices().image, "lab")
        var o = CreateOptions(image: "opencode2")
        XCTAssertThrowsError(try ChoiceOptions.from(["--gateway", "vercel-ai-gateway"]).applyModelSource(to: &o)) {
            XCTAssertEqual("\($0)", "Vercel AI Gateway is unpublished in this version of Dozable — the gateway offered now: openrouter")
        }
        XCTAssertNoThrow(try ChoiceOptions.from(["--gateway", "openrouter"]).applyModelSource(to: &o))
        XCTAssertEqual(o.modelSource, "openrouter")
        // The web plan.
        XCTAssertThrowsError(try WebPlanQuery.decode(Data(#"{"purpose":"try","agent":"grok"}"#.utf8))) { XCTAssertTrue("\($0)".contains(said), "\($0)") }
        XCTAssertThrowsError(try WebPlanQuery.decode(Data(#"{"purpose":"try","agent":"opencode@2","source":"vercel-ai-gateway"}"#.utf8))) {
            XCTAssertTrue("\($0)".contains("Vercel AI Gateway is unpublished"), "\($0)")
        }
        XCTAssertNoThrow(try WebPlanQuery.decode(Data(#"{"purpose":"try","agent":"opencode@2","source":"openrouter"}"#.utf8)))
        // The plain message carries no internal number.
        XCTAssertNil(said.range(of: "[0-9]", options: .regularExpression))
    }

    // MARK: what is stored keeps working

    func testStoredNamesStillServe() throws {
        XCTAssertEqual(ImageChoice.parse("grok")?.agent.rawValue, "grok")
        XCTAssertEqual(ImageChoice.parse("python-gemini")?.agent.rawValue, "gemini")
        XCTAssertNotNil(AgentRecipes.recipe("grok"))
        XCTAssertNotNil(AgentRecipes.matching("agy"))
        XCTAssertEqual(DozableSettings.imageKeys(imageSpecName: "debian-grok").memory, "recipes.xai.grok.memory_mib")
        // An existing sandbox's sources (a Vercel key included), its account and selection.
        XCTAssertTrue(AgentCredentials.sources("opencode2")?.contains("vercel-ai-gateway") == true)
        XCTAssertNotNil(AgentRecipes.recipe("opencode2")?.selection(source: "vercel-ai-gateway"))
        XCTAssertTrue(AgentCredentials.accepts("grok", .key, provider: "xai"))
        XCTAssertTrue(ModelSources.ids.contains("vercel-ai-gateway"))
        XCTAssertTrue(UsageSchema.agents.contains("grok"), "a sandbox of it still reports its id")
        // A project file written for it still names its image (it is a record of a sandbox).
        var p = DozableProject(name: "old", image: "")
        p.agent = "grok"
        XCTAssertEqual(p.chosenImage, "grok")
        XCTAssertNil(DozableProject.agentProblem("grok"))
    }

    func testTheHourlyLookUpIsThePublishedAndWhatIsInUse() throws {
        let store = DozableStore(root: root)
        XCTAssertEqual(HostCore.agentsToLookUp(store: store, sandboxAgents: []).map(\.id), Self.offered)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("images/python-grok"), withIntermediateDirectories: true)
        XCTAssertEqual(Set(HostCore.agentsToLookUp(store: store, sandboxAgents: ["gemini"]).map(\.id)), Set(Self.offered + ["grok", "gemini"]))
    }

    // MARK: per-recipe work

    func testRecipeCheckSelectsThePublished() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        func run(_ args: [String]) throws -> String {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            p.arguments = args
            p.currentDirectoryURL = repo
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
            return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        XCTAssertEqual(try run(["Scripts/recipe-check.py", "--list", "all"]), Self.offered.sorted().joined(separator: " "))
        XCTAssertEqual(try run(["Scripts/recipe-check.py", "--list", "grok"]), "grok", "an unpublished recipe still runs when named")
        XCTAssertEqual(try run(["Scripts/recipes_published.py"]), Self.offered.sorted().joined(separator: " "))
        XCTAssertEqual(try run(["Scripts/recipes_published.py", "--unpublished"]).split(separator: " ").count, AgentRecipes.all.count - Self.offered.count)
    }

    func testTheSeamPublishesEverythingAndIsOff() {
        XCTAssertFalse(AgentRecipes.isPublished("grok"))
        AgentRecipes.publishEverythingForTests(true)
        XCTAssertTrue(AgentRecipes.isPublished("grok"))
        XCTAssertTrue(ModelSources.isPublished("vercel-ai-gateway"))
        AgentRecipes.publishEverythingForTests(false)
        XCTAssertFalse(AgentRecipes.isPublished("grok"))
    }
}
