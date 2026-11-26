import Foundation
import XCTest
@testable import DozableKit
@testable import DozableHost
@testable import DozableCLI

/// 782 — the workspace templates doz carries: the five, in the gallery's order, each read by `template.json`; each renders
/// (every placeholder filled, values quoted) into a space file the CLI's resolver reads with no problem; none runs an agent
/// unfenced and one that needs a manager takes your bot; the release carries them; ids are folder names, never paths.
final class WorkspaceTemplatesTests: XCTestCase {
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    func testTheFiveTemplatesInTheGallerysOrder() throws {
        let all = WorkspaceTemplates.list()
        XCTAssertEqual(all.map(\.id), ["solo", "solo-sandbox", "build-review", "fix-it", "video"])
        XCTAssertEqual(all.map(\.title), ["One agent", "One agent in a Sandbox", "Build & review", "Fix-it team", "Remotion video"])
        XCTAssertEqual(all.map(\.needs.manager), [false, false, true, true, true])
        for t in all {
            XCTAssertFalse(t.summary.isEmpty)
            XCTAssertFalse(t.summary.lowercased().contains("micro vm") || t.summary.contains(" VM"), t.summary)
            XCTAssertTrue(t.agents.allSatisfy { ["manager", "sandbox", "fenced"].contains($0.where) }, "\(t.id): never unfenced")
            XCTAssertEqual(t.agents.contains { $0.where == "manager" }, t.needs.manager)
            XCTAssertNil(t.picture, "the drawing is doz ui's, never in the file")
        }
    }

    func testEachRendersIntoASpaceFileThatReads() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("doz-782-tpl-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for t in WorkspaceTemplates.list() {
            let (yaml, desc) = try WorkspaceTemplates.render(t.id, space: "w-\(t.id)", owner: "you", manager: t.needs.manager ? "mira" : nil,
                                                             folder: dir.path + "/a \"quoted\" folder")
            XCTAssertFalse(yaml.contains("{{"), t.id)
            XCTAssertTrue(yaml.contains("space: \"w-\(t.id)\""), t.id)
            XCTAssertTrue(yaml.contains("\\\"quoted\\\""), "values are JSON-quoted: \(t.id)")
            XCTAssertFalse(desc.isEmpty)
            XCTAssertFalse(yaml.contains("isolation: unfenced"), "\(t.id): a built-in never acts as you")
            if t.needs.manager { XCTAssertTrue(yaml.contains("external: { bot: \"mira\" }"), "\(t.id): your bot, never an owned manager") }
            let sub = dir.appendingPathComponent(t.id)
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            let file = sub.appendingPathComponent("w-\(t.id).workspace.yaml")
            try yaml.write(to: file, atomically: true, encoding: .utf8)
            try desc.write(to: sub.appendingPathComponent("DESCRIPTION.md"), atomically: true, encoding: .utf8)
            let (problems, model) = SpaceResolver().resolve(file.path).check()
            XCTAssertNotNil(model, "\(t.id): \(problems.map(\.message))")
            XCTAssertFalse(problems.contains(where: \.isError), "\(t.id): \(problems.filter(\.isError).map(\.message))")
        }
        XCTAssertThrowsError(try WorkspaceTemplates.render("build-review", space: "w", owner: "you", manager: nil, folder: "/x"), "a manager is needed")
    }

    /// Chat names are global: each template's own agents are named for the workspace, under chat's rule (a letter first,
    /// at most 40), so two workspaces from one template never share one.
    func testTwoWorkspacesFromOneTemplateDoNotShareAgentNames() throws {
        let a = try WorkspaceTemplates.render("fix-it", space: "w1", owner: "you", manager: "mira", folder: "/x").space
        let b = try WorkspaceTemplates.render("fix-it", space: "w2", owner: "you", manager: "mira", folder: "/x").space
        XCTAssertTrue(a.contains("  w1-builder:") && b.contains("  w2-builder:") && a.contains("members: [owner, manager, w1-builder"))
        XCTAssertTrue(a.contains("w1-reviewer: [reviewer]"), "the permissions key follows; the role stays")
        let long = String(repeating: "a", count: 40), digit = "3d-video"
        for space in [long, digit, "workspace12"] {
            let who = WorkspaceTemplates.who(space)
            XCTAssertNil(ChatNames.refusal(who + "-reviewer"), "\(space) → \(who)")
        }
        XCTAssertEqual(WorkspaceTemplates.who("3d-video"), "w3d-video")
        let bare = try WorkspaceTemplates.render("solo", space: "w", owner: "you", manager: nil, folder: "/x", bareNames: true).space
        XCTAssertTrue(bare.contains("  agent:") && !bare.contains("{{"), "the gallery's drawing says the plain names")
    }

    func testIDsArePlainNames() {
        XCTAssertTrue(WorkspaceTemplates.isID("fix-it"))
        for bad in ["", "../skills", "Fix", "a/b", String(repeating: "a", count: 41)] { XCTAssertFalse(WorkspaceTemplates.isID(bad), bad) }
        XCTAssertThrowsError(try WorkspaceTemplates.read("../skills"))
        XCTAssertThrowsError(try WorkspaceTemplates.read("nope"))
    }

    func testTheReleaseCarriesThem() throws {
        let script = try String(contentsOf: repo.appendingPathComponent("Scripts/release.sh"), encoding: .utf8)
        XCTAssertTrue(script.contains("DozableKit_DozableKit.bundle/templates/ORDER"))
        for t in WorkspaceTemplates.list() {
            XCTAssertTrue(script.contains("DozableKit_DozableKit.bundle/templates/\(t.id)/workspace.yaml"), "release.sh's layout check names \(t.id)")
        }
        let manifest = try String(contentsOf: repo.appendingPathComponent("Package.swift"), encoding: .utf8)
        XCTAssertTrue(manifest.contains(".copy(\"Resources/templates\")"), "the bundle copies templates/ whole")
    }
}
