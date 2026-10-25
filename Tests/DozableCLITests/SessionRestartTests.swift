import Foundation
import XCTest
import ArgumentParser
@testable import DozableCLI
@testable import DozableKit
@testable import DozableHost
@testable import DozableWeb

/// 608: the workspace view setting (every share through the live view, unless off) and End / Restart session —
/// the setting and its per-sandbox forms, the info a running sandbox reports, the guest script that ends a
/// session, the record a restart reopens from, the resume arguments per agent, and the CLI's shape.
final class SessionRestartTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("doz-sr-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func config(image: String = "lab") throws -> SandboxConfig {
        let (s, n) = try DozableImages.spec(name: "x", options: CreateOptions(image: image), store: DozableStore(root: root), environment: [:])
        return SandboxConfig(name: "x", image: n, spec: s, workspace: nil)
    }

    // MARK: workspace.view

    func testWorkspaceViewIsOnByDefaultAndPerSandbox() throws {
        let d = try XCTUnwrap(DozableSettings.definition(SettingKey.workspaceView))
        XCTAssertEqual(d.type, .choice(["on", "off"]))
        XCTAssertEqual(d.defaultValue, .string("on"))
        XCTAssertEqual(d.applies, .nextStart)
        XCTAssertEqual(d.flag, "doz create --workspace-view on|off")
        XCTAssertTrue(DozableSettings.perSandbox.contains(SettingKey.workspaceView))
        XCTAssertTrue(d.summary.contains("git status"), "the cost is said in plain words")
        XCTAssertTrue(d.summary.contains("invalid cwd"), "and what off costs")
        var cfg = try config()
        XCTAssertTrue(HostCore.workspaceViewOn(cfg, settings: DozableSettings(text: "")))
        XCTAssertFalse(HostCore.workspaceViewOn(cfg, settings: DozableSettings(text: "[workspace]\nview = \"off\"\n")))
        cfg.settings = [SettingKey.workspaceView: .string("on")]
        XCTAssertTrue(HostCore.workspaceViewOn(cfg, settings: DozableSettings(text: "[workspace]\nview = \"off\"\n")), "the sandbox's own choice wins")
        cfg.settings = [SettingKey.workspaceView: .string("off")]
        XCTAssertFalse(HostCore.workspaceViewOn(cfg, settings: DozableSettings(text: "")))
    }

    func testTheProjectFileAndTheCLICarryWorkspaceView() throws {
        XCTAssertTrue(DozableProject.settingKeys.contains { $0.key == "workspace_view" && $0.setting == SettingKey.workspaceView })
        let p = try DozableProject.parse("version: 1\nname: demo\nimage: lab\nworkspace_view: off\n")
        XCTAssertEqual(p.settings[SettingKey.workspaceView], .string("off"))
        XCTAssertThrowsError(try DozableProject.parse("version: 1\nname: demo\nimage: lab\nworkspace_view: sometimes\n"))
        XCTAssertEqual(try DozableProject.parse(p.render()).settings[SettingKey.workspaceView], .string("off"), "rendered and read back")
        let form = WebProjectForm(p)
        XCTAssertEqual(form.workspaceView, "off")
        XCTAssertEqual(try form.project().settings[SettingKey.workspaceView], .string("off"), "the dashboard keeps it")
        let c = try Create.parse(["x", "--image", "lab", "--workspace-view", "off"])
        XCTAssertEqual(try c.create.sandboxSettings()?[SettingKey.workspaceView], .string("off"))
        XCTAssertThrowsError(try Create.parse(["x", "--image", "lab", "--workspace-view", "maybe"]).create.sandboxSettings())
    }

    func testWhatARunningSandboxSaysAboutItsWorkspace() {
        let live = WorkspaceViewConfig(tag: "t", guestPath: "/workspace", mode: .lock, fold: true, passthrough: true)
        let rules = WorkspaceViewConfig(tag: "t", guestPath: "/workspace", mode: .lock, fold: true)
        func s(_ running: Bool = true, _ ws: Bool = true, _ a: [WorkspaceViewConfig] = [], _ fb: Set<String> = [], _ on: Bool = true) -> String? {
            HostCore.workspaceViewState(running: running, workspace: ws, active: a, fallbacks: fb, viewOn: on)
        }
        XCTAssertNil(s(false, true, [live]), "not running: nothing to say")
        XCTAssertNil(s(true, false), "isolated: no workspace")
        XCTAssertEqual(s(true, true, [live]), "live")
        XCTAssertEqual(s(true, true, [rules]), "rules")
        XCTAssertEqual(s(true, true, [], ["/workspace"]), "fallback")
        XCTAssertEqual(s(true, true, [], [], true), "next-start", "running from before the view was on")
        XCTAssertEqual(s(true, true, [], [], false), "direct")
        var info = SandboxInfo(name: "x", image: "lab", phase: "running", busy: false, cpus: 1, memoryMiB: 1, ramHeldMiB: 0, memoryReturnedMiB: 0,
                               diskBytes: 0, sessions: nil, network: "none", deniedConnections: 0, workspace: "/w", createdAt: Date(), diedWithHost: nil)
        info.workspaceView = "live"
        let back = try? HostWire.decoder.decode(SandboxInfo.self, from: HostWire.encoder.encode(info))
        XCTAssertEqual(back?.workspaceView, "live", "the field travels (fields only ever added)")
    }

    // MARK: ending a session

    func testTheEndScriptHangsUpThenHarderAndKillsTheSessionsTmux() {
        let s = GuestCommand.endSession(name: "codex")
        let order = ["deckhold ls", "doz-end not-running", "/tmp/tmux-*/doz-codex", "hit HUP", "doz-end hangup", "hit TERM", "doz-end terminate", "hit KILL", "doz-end kill", "doz-end stuck"]
        var last = s.startIndex
        for o in order {
            guard let r = s.range(of: o, range: last..<s.endIndex) else { return XCTFail("missing or out of order: \(o)") }
            last = r.upperBound
        }
        XCTAssertTrue(s.contains(#"kill -s "$1" -- "-$pid""#), "the program's whole process group (forkpty made it a group leader)")
        XCTAssertTrue(s.contains("[ ! -S \"$d/$n.sock\" ]"), "done = the holder's socket is gone")
        XCTAssertTrue(GuestCommand.endSession(name: "a.b").contains("doz-a_b"), "tmux's name for a session with a dot")
        XCTAssertEqual(Sandbox.SessionEnd(rawValue: "not-running"), .notRunning)
    }

    // MARK: restarting

    func testTheRecordKeepsTheProgramNeverAVariablesValue() throws {
        let store = DozableStore(root: root)
        try config().write(store.configFile("x"))
        XCTAssertTrue(SessionRecords.read(store, "x").sessions.isEmpty)
        let rec = SessionRecord(argv: ["bash", "-lc", "make test"], workdir: "/workspace/app", user: "agent", environmentKeys: ["TOKEN", "A"])
        SessionRecords.record("build", rec, store, "x")
        let back = SessionRecords.read(store, "x").sessions["build"]
        XCTAssertEqual(back?.argv, ["bash", "-lc", "make test"], "an argv is kept whole — deckhold's own line is space-joined")
        XCTAssertEqual(back?.environmentKeys, ["A", "TOKEN"])
        let text = try String(contentsOf: SessionRecords.url(store, "x"), encoding: .utf8)
        XCTAssertFalse(text.contains("secret"), "names only")
        let mode = try FileManager.default.attributesOfItem(atPath: SessionRecords.url(store, "x").path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        for i in 0..<70 { SessionRecords.record("s\(i)", SessionRecord(argv: ["sh"], workdir: nil, user: nil, environmentKeys: nil, openedAt: Date(timeIntervalSince1970: Double(i))), store, "x") }
        XCTAssertEqual(SessionRecords.read(store, "x").sessions.count, 64, "bounded")
        SessionRecords.write(nil, store, "x")
        XCTAssertFalse(FileManager.default.fileExists(atPath: SessionRecords.url(store, "x").path), "cleared with the sessions")
        SessionRecords.record("y", rec, store, "gone")
        XCTAssertFalse(FileManager.default.fileExists(atPath: SessionRecords.url(store, "gone").path), "never into a removed sandbox")
    }

    func testEachAgentResumesItsOwnWay() {
        XCTAssertEqual(SessionResume.arguments(for: .claudeCode), ["--continue"])
        XCTAssertEqual(SessionResume.arguments(for: .codex), ["resume", "--last"], "Codex 0.160.1: the newest session in this folder (no --all)")
        XCTAssertEqual(SessionResume.arguments(for: .pi), ["--continue"])
        XCTAssertEqual(SessionResume.arguments(for: AgentKind.none), [])
        XCTAssertEqual(SessionResume.arguments(for: nil), [])
        // Claude Code refuses --continue without a conversation: checked first, in the session's folder.
        let check = SessionResume.check(for: .claudeCode)
        XCTAssertNotNil(check)
        XCTAssertTrue(check!.contains(#".claude/projects/$(pwd -P | sed 's/[^A-Za-z0-9]/-/g')"#))
        XCTAssertNil(SessionResume.check(for: .codex), "Codex starts a new one when there is none")
        XCTAssertNil(SessionResume.check(for: .pi))
        // The launchers pass the resume words through to the agent.
        XCTAssertTrue(AgentImages.codexLauncherScript.contains("exec|e|resume|fork)"))
    }

    /// 648: every Claude session resumes ITS conversation — found from Claude Code's record of the process — never the
    /// folder's newest (two sessions in one folder would both reopen one). The guest check runs under /bin/sh here.
    func testEachClaudeSessionResumesItsOwnConversation() throws {
        XCTAssertNil(SessionResume.exactCheck(for: .codex, pid: 7), "no per-process record: the default session's --last only")
        XCTAssertNil(SessionResume.exactCheck(for: .pi, pid: 7))
        XCTAssertNil(SessionResume.exactCheck(for: .claudeCode, pid: nil))
        XCTAssertNil(SessionResume.exactCheck(for: .claudeCode, pid: 0))
        let script = try XCTUnwrap(SessionResume.exactCheck(for: .claudeCode, pid: 7390))

        let home = FileManager.default.temporaryDirectory.appendingPathComponent("doz-resume-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let id = "dea19ba5-93a9-4f78-b84e-955b0234cec4"
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude/sessions"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude/projects/-workspace"), withIntermediateDirectories: true)
        // Claude Code 2.1.304's record, as found in a sandbox.
        try #"{"pid":7390,"sessionId":"\#(id)","cwd":"/workspace","startedAt":1792956399473,"kind":"interactive"}"#
            .write(to: home.appendingPathComponent(".claude/sessions/7390.json"), atomically: true, encoding: .utf8)
        func run() throws -> String {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", script]
            p.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
            let out = Pipe()
            p.standardOutput = out
            try p.run()
            p.waitUntilExit()
            return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }
        XCTAssertEqual(try run(), "", "a conversation with no transcript yet is not resumed (claude --resume would refuse it)")
        try "{}\n".write(to: home.appendingPathComponent(".claude/projects/-workspace/\(id).jsonl"), atomically: true, encoding: .utf8)
        let out = try run()
        XCTAssertEqual(out, "resume-id \(id)\n")
        XCTAssertEqual(SessionResume.exactArguments(for: .claudeCode, checkOutput: out), ["--resume", id])
        // Only a UUID ever reaches the argv; only Claude Code's answer is read.
        XCTAssertEqual(SessionResume.exactArguments(for: .claudeCode, checkOutput: "resume-id ; rm -rf /\n"), [])
        XCTAssertEqual(SessionResume.exactArguments(for: .claudeCode, checkOutput: "resume-id --dangerous\n"), [])
        XCTAssertEqual(SessionResume.exactArguments(for: .codex, checkOutput: out), [])
        // Another process's record is not this one's.
        let other = try XCTUnwrap(SessionResume.exactCheck(for: .claudeCode, pid: 7474))
        XCTAssertTrue(other.contains("sessions/7474.json"))
    }

    func testTheResultsTravel() throws {
        let r = SessionRestarted(name: "x", session: "codex", ended: "hangup", resumed: true, command: "codex resume --last", notice: nil)
        XCTAssertEqual(try HostWire.decoder.decode(SessionRestarted.self, from: HostWire.encoder.encode(r)), r)
        let e = SessionEnded(name: "x", session: "s", how: "kill")
        XCTAssertEqual(try HostWire.decoder.decode(SessionEnded.self, from: HostWire.encoder.encode(e)), e)
        XCTAssertFalse(HostOp.sessionEnd.isReadOnly)
        XCTAssertFalse(HostOp.sessionRestart.isReadOnly)
        XCTAssertEqual(HostOp(rawValue: "session-restart"), .sessionRestart)
    }

    // MARK: the CLI

    func testTheSessionsCommandsShape() throws {
        // `doz sessions NAME` still lists (the default subcommand); end/restart take NAME SESSION.
        XCTAssertNoThrow(try DozableCommand.parseAsRoot(["sessions", "box"]))
        let end = try DozableCommand.parseAsRoot(["sessions", "end", "box", "codex", "--yes"])
        XCTAssertTrue(end is SessionsEnd)
        let restart = try XCTUnwrap(DozableCommand.parseAsRoot(["sessions", "restart", "box", "codex", "--fresh", "-d"]) as? SessionsRestart)
        XCTAssertTrue(restart.fresh)
        XCTAssertTrue(restart.detach)
        XCTAssertThrowsError(try DozableCommand.parseAsRoot(["sessions", "end", "box"]), "the session is required")
        XCTAssertEqual(SessionsEnd.howText("terminate"), "it did not hang up — terminated")
    }

    /// 610 (609.B2): a script's `doz sessions restart NAME SESSION --yes` restarted and then ATTACHED, never returning.
    /// It attaches only on a terminal (stdin AND stdout) or with --attach; never with -d or --json.
    func testARestartAttachesOnlyOnATerminalOrWhenAsked() throws {
        func a(_ detach: Bool = false, _ attach: Bool = false, json: Bool = false, stdin: Bool, stdout: Bool) -> Bool {
            SessionsRestart.attaches(detach: detach, attach: attach, json: json, stdinTTY: stdin, stdoutTTY: stdout)
        }
        XCTAssertTrue(a(stdin: true, stdout: true), "a person at a terminal: attach, as before")
        XCTAssertFalse(a(stdin: false, stdout: false), "a script: return")
        XCTAssertFalse(a(stdin: false, stdout: true), "stdin not a terminal (piped, </dev/null): return")
        XCTAssertFalse(a(stdin: true, stdout: false), "stdout captured: return")
        XCTAssertFalse(a(json: true, stdin: true, stdout: true), "--json answers and returns, even on a terminal")
        XCTAssertFalse(a(true, stdin: true, stdout: true), "-d returns")
        XCTAssertTrue(a(false, true, stdin: false, stdout: false), "--attach attaches without a terminal")
        let r = try XCTUnwrap(DozableCommand.parseAsRoot(["sessions", "restart", "box", "s", "--attach"]) as? SessionsRestart)
        XCTAssertTrue(r.attach)
        XCTAssertThrowsError(try DozableCommand.parseAsRoot(["sessions", "restart", "box", "s", "--attach", "-d"]), "--attach with -d")
        XCTAssertThrowsError(try DozableCommand.parseAsRoot(["sessions", "restart", "box", "s", "--attach", "--json"]), "--attach with --json")
    }
}
