import DozableKit
import Foundation
import XCTest
@testable import DozableHost

/// A worker's launch plan: the isolation table (unfenced never from a default), its place's names and their hash, an
/// anonymous worker's name, argv and environment per isolation and program (the allow-list last; dontAsk only fenced;
/// `--allow-tool` appended), a shared sandbox's variables, the flags that do not go together, and no token anywhere.
final class WorkerLaunchTests: XCTestCase {
    let start = "/s/etc/worker/start.md"
    let token = "dzc_" + String(repeating: "b", count: 40)

    func plan(_ i: ManagerIsolation, agent: String = "claude-code", bot: String? = nil, port: Int = 8790, name: String = "bot1",
              shared: Bool = false, allow: [String] = []) throws -> ManagerLaunch.Plan {
        try WorkerLaunch.plan(isolation: i, agent: agent, model: nil, bot: bot, startFile: start, pagePort: port,
                              fingerprint: BotTokens.fingerprint(token), tokenFile: i == .unfenced ? "/t/doz-1/manager-demo-bot1/chat-token" : nil,
                              name: name, shared: shared, allowTools: allow)
    }

    func testTheIsolationTable() throws {
        let rows: [(String?, String?, String?, ManagerIsolation, String)] = [
            (nil, nil, nil, .fenced, "the narrowest by default"),
            (nil, "vm", nil, .vm, "the workspace's default vm"),
            (nil, nil, "vm", .vm, "the bot's default vm"),
            (nil, "unfenced", nil, .fenced, "a workspace default never makes it unfenced"),
            (nil, nil, "unfenced", .fenced, "a bot default never makes it unfenced"),
            (nil, "fenced", "vm", .vm, "vm from either"),
            ("unfenced", nil, nil, .unfenced, "only when named"),
            ("fenced", "vm", "vm", .fenced, "as asked"),
            ("vm", nil, nil, .vm, "as asked"),
        ]
        for (asked, w, b, want, why) in rows {
            XCTAssertEqual(try WorkerIsolation.resolve(asked: asked, workspaceDefault: w, botDefault: b), want, why)
        }
        XCTAssertThrowsError(try WorkerIsolation.resolve(asked: "elsewhere", workspaceDefault: nil, botDefault: nil))
    }

    func testPlaceNames() {
        XCTAssertEqual(WorkerLaunch.placeName(workspace: "demo", name: "bot1"), "demo-bot1")
        XCTAssertEqual(WorkerLaunch.placeName(workspace: "demo", name: "demo-agent"), "demo-agent", "a template's agent: never demo-demo-agent")
        XCTAssertEqual(WorkerLaunch.placeName(workspace: "demo", name: "demolition"), "demo-demolition", "only W- itself")
        let w = String(repeating: "w", count: 30)
        let n = WorkerLaunch.placeName(workspace: w, name: "bot1")
        XCTAssertEqual(n.count, 32)
        XCTAssertTrue(n.hasPrefix(String((w + "-bot1").prefix(27)) + "-"))
        XCTAssertNotEqual(n, WorkerLaunch.placeName(workspace: w, name: "bot2"), "the hash tells them apart")
        XCTAssertNoThrow(try MacPlace.validateSessionName(n))
        XCTAssertEqual(WorkerLaunch.placeName(workspace: String(repeating: "a", count: 27), name: "abcd").count, 32, "32 fits as it is")
    }

    func testAnonymousNames() {
        XCTAssertEqual(WorkerLaunch.nextAnonymousName(taken: []), "bot1")
        XCTAssertEqual(WorkerLaunch.nextAnonymousName(taken: ["bot1", "bot2", "bot4"]), "bot3")
        XCTAssertEqual(WorkerLaunch.nextAnonymousName(taken: ["bot1", "mira"]), "bot2")
    }

    func testFencedClaude() throws {
        let p = try plan(.fenced, port: 41000, allow: ["Edit", "Bash(git status:*)"])
        XCTAssertEqual(p.argv, ["claude", "Read \(start) and do what it says.", "--permission-mode", "dontAsk",
                                "--allowedTools", "Bash(dozchat:*)", "Edit", "Bash(git status:*)", "Read(/\(start))"],
                       "the allow-list last, --allow-tool appended, then START's exact Read rule")
        XCTAssertEqual(WorkerLaunch.defaultAllowedTools, ["Bash(dozchat:*)"], "nothing beyond dozchat by default")
        XCTAssertEqual(p.environment, ["CHAT_URL": "http://host.dozable.internal:41000"])
        XCTAssertEqual(p.hostPorts, [41000])
        let s = try XCTUnwrap(p.secret)
        XCTAssertEqual(s.variable, "CHAT_TOKEN")
        XCTAssertEqual(s.fileVariable, "CHAT_TOKEN_FILE")
        XCTAssertNil(s.bot, "an anonymous worker's token is a daemon-made secret, not a bot's")
        XCTAssertEqual(try plan(.fenced, bot: "otto").secret?.bot, "otto")
    }

    func testVMAndUnfenced() throws {
        let v = try plan(.vm, allow: ["Edit"])
        XCTAssertEqual(v.argv, ["claude", "Read \(start) and do what it says."], "a VM's approvals are skipped: no dontAsk, no list")
        let u = try plan(.unfenced)
        XCTAssertFalse(u.argv.contains("dontAsk"), "dontAsk only fenced")
        XCTAssertEqual(u.argv.suffix(3), ["--allowedTools", "Bash(dozchat:*)", "Read(/\(start))"])
        XCTAssertEqual(u.environment, ["CHAT_TOKEN_FILE": "/t/doz-1/manager-demo-bot1/chat-token", "CHAT_URL": "http://127.0.0.1:8790"])
        XCTAssertNil(u.secret)
        let c = try plan(.fenced, agent: "codex")
        XCTAssertEqual(c.argv, ["codex", "Read \(start) and do what it says."])
        XCTAssertThrowsError(try plan(.fenced, agent: "pi")) { e in
            XCTAssertTrue("\(HostError.from(e).message)".contains("a worker running pi"))
        }
    }

    func testASharedSandboxsVariables() throws {
        XCTAssertTrue(WorkerLaunch.tokenVariables(name: "v1", shared: false) == ("CHAT_TOKEN", "CHAT_TOKEN_FILE"))
        XCTAssertTrue(WorkerLaunch.tokenVariables(name: "bot-2", shared: true) == ("CHAT_TOKEN_BOT_2", "CHAT_TOKEN_FILE_BOT_2"))
        let p = try plan(.vm, name: "v2", shared: true)
        XCTAssertEqual(p.secret?.variable, "CHAT_TOKEN_V2")
        XCTAssertEqual(p.secret?.fileVariable, "CHAT_TOKEN_FILE_V2")
        XCTAssertNil(LaunchSecrets.variableProblem("CHAT_TOKEN_V2"))
        XCTAssertNil(LaunchSecrets.variableProblem("CHAT_TOKEN_FILE_BOT_2"))
    }

    func testFlagConflicts() {
        typealias F = WorkerLaunch.Flags
        func problem(_ f: F, _ i: ManagerIsolation = .fenced, _ p: String? = "claude") -> String? { WorkerLaunch.flagProblems(f, isolation: i, program: p) }
        XCTAssertNil(problem(F()))
        XCTAssertNil(problem(F(cpus: 2, memory: "2G"), .vm))
        XCTAssertNotNil(problem(F(cpus: 2)), "--cpus without vm")
        XCTAssertNotNil(problem(F(memory: "2G"), .unfenced))
        XCTAssertNotNil(problem(F(isolation: "vm", sandbox: "x"), .vm), "--sandbox with --isolation")
        XCTAssertNotNil(problem(F(sandbox: "x", cpus: 2), .vm))
        XCTAssertNotNil(problem(F(sandbox: "x", session: "s"), .vm))
        XCTAssertNotNil(problem(F(session: "s"), .vm))
        XCTAssertNil(problem(F(session: "s")))
        XCTAssertNotNil(problem(F(agent: "codex", fromBot: "otto")))
        XCTAssertNotNil(problem(F(fromBot: "otto", name: "carl")), "a different NAME")
        XCTAssertNil(problem(F(fromBot: "otto", name: "otto")))
        XCTAssertNil(problem(F(allowTools: ["Edit"])))
        XCTAssertNotNil(problem(F(allowTools: ["Edit"]), .vm))
        XCTAssertNotNil(problem(F(allowTools: ["Edit"]), .unfenced))
        XCTAssertNotNil(problem(F(allowTools: ["Edit"]), .fenced, "codex"))
        XCTAssertNotNil(problem(F(allowTools: ["--dangerously-skip-permissions"])), "never a flag")
    }

    func testNoTokenAnywhereAndTheControlWords() throws {
        for i in ManagerIsolation.allCases {
            let p = try plan(i)
            let all = p.argv.joined(separator: " ") + p.environment.map { $0.key + "=" + $0.value }.joined() + p.startFile
            XCTAssertFalse(all.contains("dzc_"), "\(i)")
            XCTAssertFalse(String(decoding: try JSONEncoder().encode(p.secret), as: UTF8.self).contains("dzc_"))
        }
        XCTAssertEqual(WorkerLaunch.control(isolation: "fenced"), "proxy · placeholders · guard")
        XCTAssertEqual(WorkerLaunch.control(isolation: "vm"), "Sandbox · proxy · placeholders")
        XCTAssertEqual(WorkerLaunch.control(isolation: "unfenced"), "no proxy · no placeholders · no guard · acts as you")
        XCTAssertEqual(WorkerLaunch.control(isolation: "vm", shares: "vw-v1"), "Sandbox · proxy · placeholders · shares vw-v1")
        XCTAssertEqual(WorkerLaunch.shortTask("list the files\nand more"), "list the files")
        XCTAssertEqual(WorkerLaunch.shortTask(String(repeating: "x", count: 60), limit: 10), String(repeating: "x", count: 9) + "…")
    }

    /// The record's worker fields: round trip; a worker is told from an adopted agent by its task; an ended entry is found
    /// by name only when nothing live answers to it.
    func testTheRecordsWorkerFields() throws {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        var a = WorkspaceAgent(name: "bot1", place: .macSession("demo-bot1"), startedAt: t, isolation: "unfenced")
        XCTAssertFalse(a.isWorker, "an adopted agent")
        XCTAssertFalse(a.actsAsYou)
        a.task = "list the files"
        a.anonymous = true
        a.pendingAt = t
        XCTAssertTrue(a.isWorker && a.isLiveWorker && a.actsAsYou)
        let back = try JSONDecoder().decode(WorkspaceAgent.self, from: JSONEncoder().encode(a))
        XCTAssertEqual(back, a)
        var ended = a
        ended.endedAt = t
        ended.pendingAt = nil
        XCTAssertFalse(ended.isLiveWorker)
        var rec = WorkspaceRecord(name: "demo", createdAt: t, brief: WorkspaceBrief(sha256: "x", bytes: 1, updatedAt: t), folders: [],
                                  agents: [ended, a])
        XCTAssertEqual(rec.agentIndex("bot1"), 1, "the live one first")
        XCTAssertEqual(rec.liveWorkerIndex("bot1"), 1)
        rec.agents.removeLast()
        XCTAssertEqual(rec.agentIndex("bot1"), 0)
        XCTAssertNil(rec.liveWorkerIndex("bot1"))
        XCTAssertEqual(WorkspaceLogEntry(action: "worker-added", agent: "bot1", bytes: 14, isolation: "fenced").sentence,
                       "added the worker bot1 (fenced; its task 14 bytes)")
    }

    /// A first-run bug: a fenced Claude Code ran under dontAsk with only Bash(dozchat:*) allowed, and its START and the chat
    /// skills START names are outside its folder — every Read was refused and the agent sat idle. Each file it is told to
    /// read gets exactly one `Read(//ABS)` rule (an absolute path in a Read rule starts with `//`), and nothing wider: no bare
    /// Read, no folder, no pattern; a VM and Codex get none; a path a rule could not name exactly gets none.
    func testEveryAgentMayReadExactlyItsStartAndSkillFiles() throws {
        let skills = ["/opt/doz/libexec/skills/chat-worker/SKILL.md", "/opt/doz/libexec/skills/chat-room-member/SKILL.md"]
        for i in [ManagerIsolation.fenced, .unfenced] {
            let w = try WorkerLaunch.plan(isolation: i, agent: "claude-code", model: nil, bot: nil, startFile: start, pagePort: 8790,
                                          fingerprint: "f", tokenFile: i == .unfenced ? "/t/f" : nil, name: "bot1", shared: false, readFiles: skills)
            let list = Array(w.argv.suffix(from: try XCTUnwrap(w.argv.firstIndex(of: "--allowedTools")) + 1))
            XCTAssertEqual(list, ["Bash(dozchat:*)", "Read(/\(start))", "Read(/\(skills[0]))", "Read(/\(skills[1]))"], "\(i)")
            XCTAssertFalse(list.contains("Read"), "never a bare Read")
            let m = try ManagerLaunch.plan(isolation: i, agent: "claude-code", model: nil, bot: "mira", startFile: start, pagePort: 8790,
                                           fingerprint: "f", tokenFile: i == .unfenced ? "/t/f" : nil, readFiles: [skills[1]])
            XCTAssertEqual(Array(m.argv.suffix(3)), ["Bash(dozchat:*)", "Read(/\(start))", "Read(/\(skills[1]))"], "\(i)")
        }
        let v = try WorkerLaunch.plan(isolation: .vm, agent: "claude-code", model: nil, bot: nil, startFile: "~/.doz-workspace/bot1/start.md",
                                      pagePort: 8790, fingerprint: "f", name: "bot1", shared: false, readFiles: skills)
        XCTAssertFalse(v.argv.contains { $0.hasPrefix("Read(") }, "a VM's approvals are skipped: no list")
        let c = try WorkerLaunch.plan(isolation: .fenced, agent: "codex", model: nil, bot: nil, startFile: start, pagePort: 8790,
                                      fingerprint: "f", name: "bot1", shared: false, readFiles: skills)
        XCTAssertFalse(c.argv.contains { $0.hasPrefix("Read(") }, "Codex takes no Claude Code rules")
        // The rule's form; spaces kept (the fence's folder is under Application Support); once each; nothing it could not name.
        XCTAssertEqual(AgentLaunch.readRules(["/Users/a/Library/Application Support/Dozable/fence/x/s/etc/worker/start.md"]),
                       ["Read(//Users/a/Library/Application Support/Dozable/fence/x/s/etc/worker/start.md)"])
        XCTAssertEqual(AgentLaunch.readRules(["/a/b", "/a/b"]), ["Read(//a/b)"])
        XCTAssertEqual(AgentLaunch.readRules(["~/x", "rel/x", "//x", "/a/*", "/a/[b]", "/a/(b)", "/a/b\nc", "/a/!b", "/a/#b", "/a/{b}", "/a/b\\c"]), [])
    }

    /// The manager's plan is unchanged by the generalisation (but for START's Read rule).
    func testTheManagersPlanIsUnchanged() throws {
        let m = try ManagerLaunch.plan(isolation: .fenced, agent: "claude-code", model: nil, bot: "mira", startFile: start, pagePort: 8790,
                                       fingerprint: "f")
        XCTAssertEqual(m.argv, ["claude", "Read \(start) and do what it says.", "--permission-mode", "dontAsk", "--allowedTools", "Bash(dozchat:*)",
                                "Read(/\(start))"])
        XCTAssertEqual(m.secret?.bot, "mira")
        XCTAssertThrowsError(try ManagerLaunch.plan(isolation: .fenced, agent: "pi", model: nil, bot: "m", startFile: start, pagePort: 1,
                                                    fingerprint: "f")) { e in
            XCTAssertEqual(HostError.from(e).message, "Dozable does not start a manager running pi yet")
        }
    }
}
