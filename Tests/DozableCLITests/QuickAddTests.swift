import Foundation
import DozableKit
import XCTest
@testable import DozableCLI
@testable import DozableHost

/// 599c — Quick add / `doz new` without a VM: the name and the workspace it picks (from the settings,
/// past collisions with sandboxes and with folders that are not empty), a given name, isolated, and the
/// prerequisites one click cannot decide (the agent's account, an out-of-date image).
final class QuickAddTests: XCTestCase {
    private var projects: String!

    override func setUpWithError() throws {
        projects = "/private/tmp/dzqa-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: projects, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: projects)
    }

    func settings(image: String? = nil, extra: String = "") -> DozableSettings {
        DozableSettings(text: "[defaults]\nprojects_dir = \"\(projects!)\"\n" + (image.map { "image = \"\($0)\"\n" } ?? "") + extra)
    }

    func testTheDefaults_nameAndFolder() throws {
        var p = try QuickAdd.plan(image: nil, name: nil, isolated: false, taken: [], settings: settings(image: "claude-code"))
        XCTAssertEqual(p.name, "claude-sandbox")
        XCTAssertEqual(p.image, "claude-code")
        XCTAssertEqual(p.workspace, projects + "/claude-sandbox")
        XCTAssertEqual(p.projectsDir, projects)
        XCTAssertNil(p.requirement)
        XCTAssertFalse(FileManager.default.fileExists(atPath: projects + "/claude-sandbox"), "a plan makes nothing")
        // defaults.image unset: lab, the setting's default.
        p = try QuickAdd.plan(image: nil, name: nil, isolated: false, taken: [], settings: settings())
        XCTAssertEqual(p.name, "lab-sandbox")
        // --image wins over the setting; a base × agent image names its own sandbox.
        p = try QuickAdd.plan(image: "pi", name: nil, isolated: false, taken: [], settings: settings(image: "claude-code"))
        XCTAssertEqual(p.name, "pi-sandbox")
        p = try QuickAdd.plan(image: "python-claude-code", name: nil, isolated: false, taken: [], settings: settings())
        XCTAssertEqual(p.name, "python-claude-sandbox")
        XCTAssertEqual(p.workspace, projects + "/python-claude-sandbox")
    }

    func testCollisions_aSandboxOrAFolderWithSomethingInIt() throws {
        let s = settings(image: "claude-code")
        // A sandbox has the name: -2; both: -3.
        XCTAssertEqual(try QuickAdd.plan(image: nil, name: nil, isolated: false, taken: ["claude-sandbox"], settings: s).name, "claude-sandbox-2")
        XCTAssertEqual(try QuickAdd.plan(image: nil, name: nil, isolated: false, taken: ["claude-sandbox", "claude-sandbox-2"], settings: s).name,
                       "claude-sandbox-3")
        // A folder there with something in it is someone's: skipped. An EMPTY one is free (it becomes the workspace).
        try FileManager.default.createDirectory(atPath: projects + "/claude-sandbox", withIntermediateDirectories: true)
        XCTAssertEqual(try QuickAdd.plan(image: nil, name: nil, isolated: false, taken: [], settings: s).name, "claude-sandbox")
        try Data("x".utf8).write(to: URL(fileURLWithPath: projects + "/claude-sandbox/README"))
        let p = try QuickAdd.plan(image: nil, name: nil, isolated: false, taken: [], settings: s)
        XCTAssertEqual(p.name, "claude-sandbox-2")
        XCTAssertEqual(p.workspace, projects + "/claude-sandbox-2")
    }

    func testAGivenNameAndIsolated() throws {
        let s = settings(image: "lab")
        var p = try QuickAdd.plan(image: nil, name: "my-box", isolated: false, taken: ["lab-sandbox"], settings: s)
        XCTAssertEqual(p.name, "my-box")
        XCTAssertEqual(p.workspace, projects + "/my-box")
        p = try QuickAdd.plan(image: nil, name: nil, isolated: true, taken: [], settings: s)
        XCTAssertNil(p.workspace, "isolated: nothing shared")
        XCTAssertEqual(p.line(), "lab-sandbox · lab · isolated")
        XCTAssertThrowsError(try QuickAdd.plan(image: nil, name: "lab-sandbox", isolated: false, taken: ["lab-sandbox"], settings: s)) { e in
            XCTAssertEqual((e as? HostError)?.code, .exists)
            XCTAssertTrue((e as? HostError)?.message.contains("doz up lab-sandbox") == true)
        }
        for bad in ["My Box", "-x", "", String(repeating: "a", count: 41)] {
            XCTAssertThrowsError(try QuickAdd.plan(image: nil, name: bad, isolated: false, taken: [], settings: s), bad)
        }
    }

    func testTheLine() {
        let p = QuickAddPlan(name: "claude-sandbox-2", image: "claude-code", workspace: "/Users/me/doz-workspaces/claude-sandbox-2",
                             projectsDir: "/Users/me/doz-workspaces")
        XCTAssertEqual(p.line(homes: ["/Users/me"]), "claude-sandbox-2 · claude-code · ~/doz-workspaces/claude-sandbox-2")
        XCTAssertEqual(p.line(homes: ["/Users/other"]), "claude-sandbox-2 · claude-code · /Users/me/doz-workspaces/claude-sandbox-2")
    }

    /// What one click cannot decide: the New Sandbox form opens with it said (the CLI asks, as create does).
    func testPrerequisiteFallbacks() {
        let none: [String: AccountKind] = ["mac": .mac]
        // pi with no API-key account (default none, or the Mac login): the account.
        var r = QuickAdd.requirement(image: "pi", network: nil, defaultAccount: "none", accountKinds: none)
        XCTAssertEqual(r?.kind, "account")
        XCTAssertTrue(r?.text.contains("pi needs an Anthropic API key") == true, r?.text ?? "")
        r = QuickAdd.requirement(image: "pi", network: nil, defaultAccount: "mac", accountKinds: none)
        XCTAssertEqual(r?.kind, "account")
        // pi with an API key as the default: fine. With nat/none networking no account applies at all.
        XCTAssertNil(QuickAdd.requirement(image: "pi", network: nil, defaultAccount: "work", accountKinds: ["mac": .mac, "work": .apiKey]))
        XCTAssertNil(QuickAdd.requirement(image: "pi", network: "nat", defaultAccount: "none", accountKinds: none))
        // Claude Code may start with none, or the Mac login; lab has no agent.
        XCTAssertNil(QuickAdd.requirement(image: "claude-code", network: nil, defaultAccount: "none", accountKinds: none))
        XCTAssertNil(QuickAdd.requirement(image: "claude-code", network: nil, defaultAccount: "mac", accountKinds: none))
        XCTAssertNil(QuickAdd.requirement(image: "lab", network: nil, defaultAccount: "none", accountKinds: [:]))
        // 635 (owner: Quick add stopped on a newer patch release): an out-of-date image is used as it is and SAID — never a
        // requirement, never rebuilt by itself.
        XCTAssertEqual(QuickAdd.notice(image: "claude-code", outOfDate: "Claude Code 2.1.305 is available (image has 2.1.304) — rebuild when ready: doz image bake claude-code"),
                       "it uses the claude-code image as it is — Claude Code 2.1.305 is available (image has 2.1.304); Images › Rebuild when you want it")
        XCTAssertNil(QuickAdd.notice(image: "claude-code", outOfDate: nil))
        // The image's network setting decides whether an account applies.
        let s = settings(extra: "[images.pi]\nnetwork = \"none\"\n")
        XCTAssertEqual(QuickAdd.network(image: "pi", settings: s), "none")
        XCTAssertNil(QuickAdd.network(image: "lab", settings: s), "no agent: no account question")
    }

    /// `doz new` is a top-level command that clashes with nothing.
    func testDozNewIsACommand() throws {
        let names = DozableCommand.configuration.subcommands.map { $0._commandName }
        XCTAssertEqual(names.filter { $0 == "new" }.count, 1)
        let aliases = DozableCommand.configuration.subcommands.flatMap { $0.configuration.aliases }
        XCTAssertFalse(aliases.contains("new"))
        let n = try New.parse(["--image", "pi", "--name", "x1", "--isolated", "-d"])
        XCTAssertEqual(n.image, "pi")
        XCTAssertEqual(n.name, "x1")
        XCTAssertTrue(n.isolated && n.detach)
    }
}
