import DozableKit
import Foundation
import XCTest
@testable import DozableHost

/// The manager's launch plan: argv and environment per isolation and program, no token anywhere, CHAT_URL per isolation,
/// the session-name table, isolation resolution (unfenced never by default), resume, unknown programs refused; START and
/// the kick-off's text.
final class ManagerLaunchTests: XCTestCase {
    let start = "/s/etc/manager/start.md"
    let token = "dzc_" + String(repeating: "a", count: 40)

    func plan(_ i: ManagerIsolation, agent: String = "claude-code", model: String? = nil, port: Int = 8790) throws -> ManagerLaunch.Plan {
        try ManagerLaunch.plan(isolation: i, agent: agent, model: model, bot: "mira", startFile: start, pagePort: port,
                               fingerprint: BotTokens.fingerprint(token), tokenFile: i == .unfenced ? "/t/doz-1/manager-demo/chat-token" : nil)
    }

    func testFencedClaude() throws {
        let p = try plan(.fenced, model: "opus", port: 41000)
        XCTAssertEqual(p.argv, ["claude", "--model", "opus", "Read \(start) and do what it says.", "--permission-mode", "dontAsk",
                                "--allowedTools", "Bash(dozchat:*)"])
        XCTAssertEqual(p.argv.suffix(2), ["--allowedTools", "Bash(dozchat:*)"], "the allow-list is last")
        XCTAssertEqual(p.environment, ["CHAT_URL": "http://host.dozable.internal:41000"])
        XCTAssertEqual(p.hostPorts, [41000])
        let s = try XCTUnwrap(p.secret)
        XCTAssertEqual(s.variable, "CHAT_TOKEN")
        XCTAssertEqual(s.fileVariable, "CHAT_TOKEN_FILE")
        XCTAssertEqual(s.bot, "mira")
        XCTAssertNil(s.keychainService, "a bot-held secret has no item of its own")
        XCTAssertEqual(s.destination, "host.dozable.internal:41000")
        XCTAssertEqual(s.fingerprint, BotTokens.fingerprint(token))
    }

    func testVM() throws {
        let p = try plan(.vm, model: "opus")
        XCTAssertEqual(p.argv, ["claude", "Read \(start) and do what it says."], "the model rides on the create; no dontAsk")
        XCTAssertEqual(p.environment["CHAT_URL"], "http://host.dozable.internal:8790")
        XCTAssertNotNil(p.secret?.bot)
    }

    func testUnfenced() throws {
        var p = try plan(.unfenced)
        XCTAssertFalse(p.argv.contains("dontAsk"), "no dontAsk: anything beyond dozchat asks")
        XCTAssertEqual(p.argv.suffix(2), ["--allowedTools", "Bash(dozchat:*)"])
        XCTAssertEqual(p.environment, ["CHAT_TOKEN_FILE": "/t/doz-1/manager-demo/chat-token"], "no CHAT_URL on the default port")
        XCTAssertNil(p.secret)
        XCTAssertEqual(p.hostPorts, [])
        p = try plan(.unfenced, port: 41000)
        XCTAssertEqual(p.environment["CHAT_URL"], "http://127.0.0.1:41000")
        XCTAssertThrowsError(try ManagerLaunch.plan(isolation: .unfenced, agent: "claude-code", model: nil, bot: "m", startFile: start,
                                                    pagePort: 1, fingerprint: "x", tokenFile: nil))
    }

    func testCodexAndUnknownPrograms() throws {
        let p = try plan(.fenced, agent: "codex", model: "o3")
        XCTAssertEqual(p.argv, ["codex", "--model", "o3", "Read \(start) and do what it says."])
        XCTAssertEqual(ManagerLaunch.program(agent: "openai/codex@1.2"), "codex")
        XCTAssertEqual(ManagerLaunch.program(agent: "anthropic/claude-code@2"), "claude")
        XCTAssertNil(ManagerLaunch.program(agent: "pi"))
        XCTAssertThrowsError(try plan(.fenced, agent: "pi"))
    }

    func testNoTokenAnywhere() throws {
        for i in ManagerIsolation.allCases {
            let p = try plan(i)
            let all = p.argv.joined(separator: " ") + p.environment.map { $0.key + "=" + $0.value }.joined() + p.startFile
            XCTAssertFalse(all.contains("dzc_"), "\(i)")
            XCTAssertFalse(String(decoding: try JSONEncoder().encode(p.secret), as: UTF8.self).contains("dzc_"))
        }
        let t = ManagerKickoff.startText(bot: "mira", workspace: "demo", room: "demo", isolation: .fenced, skills: ["review"],
                                         instructions: "Be brief.", brief: "Make the video.", refs: ["https://x.example"])
        XCTAssertFalse(t.contains("dzc_"))
        XCTAssertTrue(t.hasPrefix("You are mira, the manager of the workspace demo.\nYour room in chat: demo\n"))
        for s in ["chat-room-member", "- review", "Be brief.", "CHAT_TOKEN_FILE", "cannot start or stop agents yet", "Make the video.",
                  "References:\n- https://x.example"] {
            XCTAssertTrue(t.contains(s), s)
        }
        let u = ManagerKickoff.startText(bot: "otto", workspace: "solo", room: "solo", isolation: .unfenced, skills: [], instructions: nil,
                                         brief: "B", refs: [])
        XCTAssertTrue(u.contains("You act as the person"))
        XCTAssertEqual(ManagerKickoff.briefPost(brief: "Make it.\n", refs: []), "Make it.")
        XCTAssertEqual(ManagerKickoff.briefPost(brief: "Make it.", refs: ["https://a.example"]), "Make it.\n\nReferences:\n- https://a.example")
    }

    func testSessionNames() {
        XCTAssertEqual(ManagerLaunch.sessionName(workspace: "demo"), "demo")
        let w32 = String(repeating: "a", count: 32)
        XCTAssertEqual(ManagerLaunch.sessionName(workspace: w32), w32)
        let w40 = String(repeating: "b", count: 40)
        let n = ManagerLaunch.sessionName(workspace: w40)
        XCTAssertEqual(n.count, 32)
        XCTAssertTrue(n.hasPrefix(String(repeating: "b", count: 27) + "-"))
        XCTAssertNotEqual(n, ManagerLaunch.sessionName(workspace: String(repeating: "b", count: 39)), "the hash tells them apart")
        XCTAssertNoThrow(try MacPlace.validateSessionName(n))
    }

    func testIsolationResolution() throws {
        XCTAssertEqual(try ManagerIsolation.resolve(asked: nil, botDefault: "fenced"), .fenced)
        XCTAssertEqual(try ManagerIsolation.resolve(asked: nil, botDefault: "vm"), .vm)
        XCTAssertEqual(try ManagerIsolation.resolve(asked: nil, botDefault: "unfenced"), .fenced, "never unfenced by default")
        XCTAssertEqual(try ManagerIsolation.resolve(asked: "unfenced", botDefault: "fenced"), .unfenced, "only when named")
        XCTAssertEqual(try ManagerIsolation.resolve(asked: "vm", botDefault: "fenced"), .vm)
        XCTAssertThrowsError(try ManagerIsolation.resolve(asked: "elsewhere", botDefault: "fenced"))
    }

    func testResume() {
        XCTAssertEqual(ManagerLaunch.vmResumeArgv(agent: "claude-code"), ["claude", "--continue"])
        XCTAssertNil(ManagerLaunch.vmResumeArgv(agent: "pi"))
        // On this Mac a start after a stop resumes the conversation recorded at the stop.
        let argv = ["claude", "Read \(start) and do what it says.", "--permission-mode", "dontAsk", "--allowedTools", "Bash(dozchat:*)"]
        let id = "0f0e0d0c-0b0a-4908-8706-050403020100"
        let r = MacPlace.restartArgv(argv, fresh: false, knownID: id, transcriptExists: { _ in true }, hasConversation: true)
        XCTAssertEqual(r.how, .resume(id))
        XCTAssertTrue(r.argv.contains("--resume") && r.argv.contains(id))
    }
}
