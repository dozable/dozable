import ArgumentParser
import Foundation
import XCTest
@testable import DozableCLI
@testable import DozableHost
@testable import DozableKit

/// The agent briefing: `doz --help` leads with workspaces (an agent whose tool cuts the output still sees how to make
/// one), and the `doz` skill ships inside doz (`doz skill show doz [--json]`).
final class AgentBriefingTests: XCTestCase {
    func testTheTopLevelHelpNamesWorkspaceNewWithinItsFirst25Lines() {
        let lines = DozableCommand.helpMessage(columns: 80).split(separator: "\n", omittingEmptySubsequences: false)
        let first = lines.prefix(25)
        XCTAssertTrue(first.contains { $0.contains("doz workspace new") }, first.joined(separator: "\n"))
        XCTAssertTrue(first.contains { $0.contains("doz workspace state") }, "see it")
        XCTAssertTrue(first.contains { $0.contains("doz worker add") }, "add a helper")
        XCTAssertTrue(first.contains { $0.contains("doz skill show doz") }, "the skill, for an agent")
        XCTAssertTrue(first.contains { $0.contains("letting-another-agent-drive") }, "the agent page")
        // The one-command line is whole on an 80-column screen (never wrapped mid-command).
        XCTAssertTrue(lines.contains { $0.contains(#"doz workspace new NAME --brief "…" --folder PATH [--worker "TASK"]"#) })
        // The full list follows, as before — with the new group.
        let listed = DozableCommand.helpMessage().components(separatedBy: "SUBCOMMANDS:").last ?? ""
        XCTAssertTrue(listed.contains("  workspace ") && listed.contains("  skill ") && listed.contains("  create "), listed)
    }

    func testTheShippedSkillIsFoundBesideTheBuild() throws {
        let dir = try XCTUnwrap(ShippedSkills.directory(), "the resource bundle beside the build carries skills/")
        XCTAssertTrue(ShippedSkills.names(in: dir).contains("doz"))
        let url = try XCTUnwrap(ShippedSkills.locate("doz"))
        XCTAssertTrue(url.path.hasPrefix("/"))
        XCTAssertTrue(url.path.hasSuffix("/skills/doz/SKILL.md"))
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("---\nname: doz\ndescription: "), "the chat skills' frontmatter")
        for must in ["doz workspace new", "--brief", "--worker", "--preset", "doz workspace create", "doz workspace state", "--json",
                     "conditions.ready", "doz worker add", "doz worker end", "doz help exit-codes --json", "error.code", "error.exit",
                     "--yes", "needs-confirmation", "unfenced", "Never `doz create` when a workspace is meant"] {
            XCTAssertTrue(text.contains(must), must)
        }
        // Every exit it lists is the published table's, with the same meaning's code.
        for row in ExitCodes.table where row.exit != 0 { XCTAssertTrue(text.contains("| \(row.exit) |"), "exit \(row.exit) in the skill's table") }
        // It names every condition there is.
        for c in AgentCondition.all { XCTAssertTrue(text.contains("`\(c)`"), c) }
    }

    func testSkillShowJSONHasTheShapeAndAPathThatExists() throws {
        let a = try SkillShow.resolve("doz").get()
        let d = try HostWire.prettyEncoder.encode(a)
        let o = try XCTUnwrap(JSONSerialization.jsonObject(with: d) as? [String: Any])
        XCTAssertEqual(Set(o.keys), ["kind", "schema", "name", "path"])
        XCTAssertEqual(o["kind"] as? String, "Skill")
        XCTAssertEqual(o["schema"] as? Int, 1)
        XCTAssertEqual(o["name"] as? String, "doz")
        let path = try XCTUnwrap(o["path"] as? String)
        XCTAssertTrue(path.hasPrefix("/") && FileManager.default.fileExists(atPath: path), path)
        XCTAssertTrue(try parse(["skill", "show", "doz", "--json"]) is SkillShow)
    }

    func testAnUnknownSkillIsNotFoundNamingTheSkillsThereAre() {
        guard case .failure(let e) = SkillShow.resolve("nosuch") else { return XCTFail("nosuch was found") }
        XCTAssertEqual(e.code, .notFound)
        XCTAssertEqual(ExitCodes.exit(for: e), 2)
        XCTAssertTrue(e.message.contains("doz"), e.message)
        // A name is a folder name, never a path.
        for bad in ["../doz", "doz/SKILL.md", "", "/etc", "DOZ"] {
            guard case .failure(let x) = SkillShow.resolve(bad) else { return XCTFail("\(bad) was found") }
            XCTAssertEqual(ExitCodes.exit(for: x), 2, bad)
        }
    }

    func testABuildWithNoSkillsSaysSo() throws {
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("doz-skills-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        guard case .failure(let e) = SkillShow.resolve("doz", in: empty) else { return XCTFail() }
        XCTAssertEqual(e.code, .failed)
        guard case .failure(let n) = SkillShow.resolve("doz", in: nil) else { return XCTFail() }
        XCTAssertEqual(n.code, .failed)
    }

    private func parse(_ a: [String]) throws -> ParsableCommand { try DozableCommand.parseAsRoot(a) }
}
