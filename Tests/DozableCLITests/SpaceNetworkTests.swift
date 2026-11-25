import DozableChat
import Foundation
import XCTest
@testable import DozableHost
@testable import DozableCLI

/// The workspace's network is the space file's top-level `network:` (workspace-model.md: "workspace default < place <
/// agent"; the record's `defaults.network` is the document's `network:`): up records it as the workspace's default — every
/// agent it starts, and a place that declares no network of its own —, the plan says so, and a later up that changes it
/// changes the default. A file that writes none keeps Dozable's default, locked.
final class SpaceNetworkTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("doz-space-network-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func intent(_ text: String) throws -> (SpaceIntent, SpaceModel, [SpaceProblem]) {
        let f = dir.appendingPathComponent("t.space.yaml")
        try Data(text.utf8).write(to: f)
        let r = SpaceResolver().resolve(f.path)
        let (problems, model) = r.check()
        let m = try XCTUnwrap(model, "\(problems.map(\.text))")
        return (SpaceIntent.compile(m, r.filled, r.locator), m, problems)
    }

    static let head = "doz: space/3.1\nspace: t\nowner: ada\nbrief: { text: x }\n"

    func testTheTopLevelNetworkIsTheWorkspacesDefaultAndAPlacesWithoutOne() throws {
        let (i, _, problems) = try intent(Self.head + """
        network: { preset: standard, allow: [registry.npmjs.org] }
        agents:
          w: { kind: claude-code, role: worker, where: desk }
          v: { kind: claude-code, role: worker, where: box }
        x-dozable:
          places:
            desk: { isolation: fenced }
            box: { isolation: vm, network: { preset: standard, allow: [github.com] } }
        """)
        XCTAssertFalse(problems.contains(where: \.isError), "\(problems.map(\.text))")
        XCTAssertEqual(i.network, "standard")
        XCTAssertEqual(i.sites, ["registry.npmjs.org"])
        let desk = try XCTUnwrap(i.places?.first { $0.name == "desk" })
        XCTAssertEqual(desk.network, .network(preset: "standard", allow: ["registry.npmjs.org"]), "a place with none has the workspace's")
        XCTAssertEqual(try WorkspacePlaces.fence(desk, agentNetwork: nil, paths: [:])?.network, ["standard", "site:registry.npmjs.org"],
                       "and its fences are given it")
        XCTAssertEqual(i.places?.first { $0.name == "box" }?.network, .network(preset: "standard", allow: ["github.com"]), "a place's own wins")
        // The plan's step names it.
        let f = SpaceFacts(known: true, home: NSHomeDirectory(), projectsDir: NSHomeDirectory() + "/doz-workspaces", owner: "ada", chatOn: true)
        let p = SpaceUp.plan(i, facts: f, specSHA: "x", sources: [])
        XCTAssertTrue(p.steps.contains { $0.kind == "workspace-new" && $0.text.contains("network standard + registry.npmjs.org") }, "\(p.steps.map(\.text))")
    }

    func testNoNetworkWrittenIsLockedAsBefore() throws {
        let (i, _, _) = try intent(Self.head + "agents:\n  w: { kind: claude-code, role: worker, where: desk }\nx-dozable: { places: { desk: { isolation: fenced } } }\n")
        XCTAssertNil(i.network)
        XCTAssertNil(i.sites)
        XCTAssertEqual(i.places?.first?.network, .text(WorkspacePlaces.networkDefault))
        XCTAssertNil(try WorkspacePlaces.fence(try XCTUnwrap(i.places?.first), agentNetwork: nil, paths: [:])?.network, "the defaults, as before")
    }

    func testAnAgentInAFencedPlaceNarrowsTheWorkspacesNetworkWhenThePlaceHasNone() throws {
        let ok = try intent(Self.head + """
        network: standard
        agents:
          w: { kind: claude-code, role: worker, where: desk, network: standard }
        x-dozable: { places: { desk: { isolation: fenced } } }
        """)
        XCTAssertFalse(ok.2.contains(where: \.isError), "standard within the workspace's standard: \(ok.2.map(\.text))")
        let f = dir.appendingPathComponent("t.space.yaml")
        try Data((Self.head + """
        network: standard
        agents:
          w: { kind: claude-code, role: worker, where: desk, network: open }
        x-dozable: { places: { desk: { isolation: fenced } } }
        """).utf8).write(to: f)
        let problems = SpaceResolver().resolve(f.path).check().problems
        XCTAssertTrue(problems.contains { $0.isError && $0.message.contains("wider than its place desk's (standard)") }, "\(problems.map(\.text))")
    }

    func testAHostWithAPortIsRefusedInThePlan() throws {
        let (i, _, _) = try intent(Self.head + "network: { preset: standard, allow: [\"example.com:8080\"] }\n")
        XCTAssertTrue(i.refusals.contains { $0.pointer == "/network/allow" && $0.message.hasPrefix("network.allow example.com:8080") }, "\(i.refusals)")
    }

    func testALaterUpThatChangesTheNetworkChangesTheDefault() throws {
        let (i, _, _) = try intent(Self.head + "network: { preset: standard, allow: [registry.npmjs.org] }\n")
        var rec = WorkspaceRecord(name: "t", createdAt: Date(), brief: WorkspaceBrief(refs: [], sha256: "", bytes: 0, updatedAt: Date()), folders: [])
        XCTAssertEqual(SpaceUp.networkChange(rec, i), "network locked → standard + registry.npmjs.org")
        rec.defaults = WorkspaceDefaults(network: "standard", sites: ["registry.npmjs.org"])
        XCTAssertNil(SpaceUp.networkChange(rec, i))
        let (none, _, _) = try intent(Self.head)
        XCTAssertEqual(SpaceUp.networkChange(rec, none), "network standard + registry.npmjs.org → locked")
        rec.defaults = WorkspaceDefaults(network: "locked")
        XCTAssertNil(SpaceUp.networkChange(rec, none), "locked and none are the same")
    }
}
