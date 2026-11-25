import DozableKit
import Foundation
import XCTest
@testable import DozableHost

/// The chat skills an agent Dozable starts is told to read by path: doz carries them (the same text as docs/chat/skills),
/// a release's tarball carries them, START names each by where that agent reads it, a missing one is said plainly, a
/// fenced profile lets the session read exactly those files, and nothing is written into an agent's config.
final class AgentSkillFilesTests: XCTestCase {
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    func testDozCarriesTheChatSkillsAsPublished() throws {
        for n in AgentSkillFiles.chatSkills {
            let shipped = try Data(contentsOf: repo.appendingPathComponent("Sources/DozableKit/Resources/skills/\(n)/SKILL.md"))
            let published = try Data(contentsOf: repo.appendingPathComponent("docs/chat/skills/\(n)/SKILL.md"))
            XCTAssertEqual(shipped, published, "\(n): the shipped copy is docs/chat/skills' text")
            // …and the build beside these tests has it, at an absolute, resolved path.
            let p = try XCTUnwrap(AgentSkillFiles.macPath(n), "\(n) beside the build")
            XCTAssertTrue(p.hasPrefix("/") && p.hasSuffix("/skills/\(n)/SKILL.md"), p)
            XCTAssertFalse(p.hasPrefix(TestSafety.realHome.appendingPathComponent(".claude").path + "/"), "never an agent's config")
        }
    }

    func testTheReleaseTarballCarriesThem() throws {
        let script = try String(contentsOf: repo.appendingPathComponent("Scripts/release.sh"), encoding: .utf8)
        for n in AgentSkillFiles.chatSkills {
            XCTAssertTrue(script.contains("DozableKit_DozableKit.bundle/skills/\(n)/SKILL.md"), "release.sh's layout check names \(n)")
        }
        let manifest = try String(contentsOf: repo.appendingPathComponent("Package.swift"), encoding: .utf8)
        XCTAssertTrue(manifest.contains(".copy(\"Resources/skills\")"), "the bundle copies skills/ whole")
    }

    func testStartNamesEachSkillByWhereTheAgentReadsIt() throws {
        let mac = AgentSkillFiles.paths(AgentSkillFiles.manager, isolation: .unfenced)
        let room = try XCTUnwrap(mac["chat-room-member"])
        XCTAssertEqual(AgentSkillFiles.paths(AgentSkillFiles.manager, isolation: .fenced)["chat-room-member"], room)
        XCTAssertEqual(AgentSkillFiles.paths(AgentSkillFiles.manager, isolation: .vm)["chat-room-member"], "~/.doz-workspace/skills/chat-room-member/SKILL.md")
        for iso in ManagerIsolation.allCases {
            let files = AgentSkillFiles.paths(AgentSkillFiles.worker, isolation: iso)
            let m = ManagerKickoff.startText(bot: "mira", workspace: "w", room: "w", isolation: iso, skills: ["review"], instructions: nil,
                                             brief: "B", refs: [], skillFiles: AgentSkillFiles.paths(AgentSkillFiles.manager, isolation: iso))
            XCTAssertTrue(m.contains("- chat-room-member: read \(AgentSkillFiles.paths(AgentSkillFiles.manager, isolation: iso)["chat-room-member"]!)\n"), "\(iso): \(m)")
            XCTAssertTrue(m.contains("- review\n"))
            let w = WorkerKickoff.startText(name: "b", workspace: "w", room: "w", task: "T", director: nil,
                                            place: iso == .vm ? .vm : iso == .unfenced ? .unfenced : .fenced, skills: [], instructions: nil, skillFiles: files)
            for n in AgentSkillFiles.worker { XCTAssertTrue(w.contains("- \(n): read \(files[n]!)\n"), "\(iso) \(n)") }
        }
        // An install that does not carry one: said plainly, the dozchat commands kept.
        let none = ManagerKickoff.startText(bot: "mira", workspace: "w", room: "w", isolation: .fenced, skills: [], instructions: nil, brief: "B", refs: [])
        XCTAssertTrue(none.contains("- chat-room-member: this install of doz does not carry its file — the dozchat commands above are what you need"))
        XCTAssertTrue(none.contains("dozchat send w"))
        XCTAssertTrue(none.contains("`dozchat receive --wait 60 --ack`"))
        XCTAssertEqual(AgentSkillFiles.paths(["no-such-skill"], isolation: .unfenced), [:])
    }

    func testAFencedProfileReadsExactlyTheSkillFiles() throws {
        let files = AgentSkillFiles.forFence()
        XCTAssertEqual(files.count, AgentSkillFiles.chatSkills.count)
        XCTAssertEqual(Set(AgentSkillFiles.vmCopies(AgentSkillFiles.chatSkills).keys), Set(AgentSkillFiles.chatSkills))
    }
}
