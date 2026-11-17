import Darwin
import Foundation
@testable import DozableKit
import XCTest
@testable import DozableHost

/// `@mac` — the place that is this Mac: its name, its refusals, its socket folder's rules.
final class MacPlaceTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: "/tmp/dzmp-\(getpid())-\(UInt32.random(in: 0...UInt32.max))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testTheNameCanNeverBeASandbox() {
        XCTAssertTrue(MacPlace.isPlace("@mac"))
        XCTAssertFalse(MacPlace.isPlace("mac"))
        XCTAssertFalse(MacPlace.isPlace(nil))
        XCTAssertNil(MacPlace.name.range(of: "^[a-z0-9-]+$", options: .regularExpression), "a sandbox name is a-z0-9- — @mac can never collide")
    }

    func testSessionNames_atMost32() throws {
        XCTAssertNoThrow(try MacPlace.validateSessionName(String(repeating: "a", count: 32)))
        XCTAssertThrowsError(try MacPlace.validateSessionName(String(repeating: "a", count: 33)))
        XCTAssertThrowsError(try MacPlace.validateSessionName("../x"))
        XCTAssertThrowsError(try MacPlace.validateSessionName(".hidden"))
        XCTAssertThrowsError(try MacPlace.validateSessionName(""))
    }

    func testTheSocketFolder_isTheUsersTempAndTheStoresHash_andFits() throws {
        let a = MacPlace.socketDirectory(store: DozableStore(root: root.appendingPathComponent("a")))
        let b = MacPlace.socketDirectory(store: DozableStore(root: root.appendingPathComponent("b")))
        XCTAssertNotEqual(a, b, "two stores never share a folder")
        XCTAssertTrue(a.hasPrefix(MacPlace.userTempDirectory()))
        XCTAssertTrue((a as NSString).lastPathComponent.hasPrefix("dh-"))
        XCTAssertEqual((a as NSString).lastPathComponent.count, 11, "dh- and 8 hex")
        XCTAssertFalse(MacPlace.userTempDirectory().contains("$"), "confstr, never $TMPDIR")
        XCTAssertNoThrow(try MacPlace.checkPathBudget(a, String(repeating: "x", count: 32)))
        XCTAssertThrowsError(try MacPlace.checkPathBudget("/" + String(repeating: "d", count: 90), String(repeating: "x", count: 32)))
    }

    func testTheFolder_mustBeOurs_0700_andNoLink() throws {
        let d = root.appendingPathComponent("dh").path
        XCTAssertNoThrow(try MacPlace.ensureFolder(d))
        XCTAssertNil(MacPlace.folderProblem(d))
        chmod(d, 0o755)
        XCTAssertNotNil(MacPlace.folderProblem(d), "a folder others can read is refused")
        XCTAssertThrowsError(try MacPlace.ensureFolder(d))
        chmod(d, 0o700)
        let link = root.appendingPathComponent("link").path
        symlink(d, link)
        XCTAssertTrue(MacPlace.folderProblem(link)?.contains("link") == true, "a link is refused")
        XCTAssertTrue(MacPlace.folderProblem(d, uid: getuid() + 1)?.contains("another user") == true, "another owner is refused")
        let f = root.appendingPathComponent("file").path
        FileManager.default.createFile(atPath: f, contents: Data())
        XCTAssertNotNil(MacPlace.folderProblem(f))
    }

    func testTheSocketFolderIsNeverAWorkspace() {
        let store = DozableStore(root: root.appendingPathComponent("store"))
        let dir = MacPlace.socketDirectory(store: store)
        XCTAssertNotNil(Workspace.refusal(dir, store: store), "the folder itself")
        XCTAssertNotNil(Workspace.refusal(MacPlace.userTempDirectory(), store: store), "a folder that holds it")
        XCTAssertNotNil(Workspace.refusal(dir + "/inside", store: store), "a folder inside it")
        XCTAssertNil(Workspace.refusal(root.appendingPathComponent("work").path, store: store), "anything else as before")
    }

    /// The host writes the client's pieces apart; an older client's single input still gets its Enter split off.
    func testSendPieces() {
        var r = HostRequest(.sessionSend, name: "x")
        let bytes = Data("hello\r".utf8)
        r.inputPieces = [Data("hello".utf8), Data([0x0D])]
        XCTAssertEqual(HostCore.sendPieces(r, bytes), [Data("hello".utf8), Data([0x0D])])
        r.inputPieces = [Data("other".utf8)]
        XCTAssertEqual(HostCore.sendPieces(r, bytes), [Data("hello".utf8), Data([0x0D])], "pieces that are not the input: ignored")
        r.inputPieces = nil
        XCTAssertEqual(HostCore.sendPieces(r, bytes), [Data("hello".utf8), Data([0x0D])], "an older client: the Enter split off")
        XCTAssertEqual(HostCore.sendPieces(r, Data("ab".utf8)), [Data("ab".utf8)])
        XCTAssertEqual(HostCore.sendPieces(r, Data([0x0D])), [Data([0x0D])])
    }

    /// A sandbox session's argv over 255 characters (a long --append-system-prompt) comes back WHOLE in `sessions --json`;
    /// `command` keeps the holder's cut line.
    func testASandboxSessionsLongArgvRoundTripsWhole() async throws {
        let store = DozableStore(root: root.appendingPathComponent("store"))
        let name = "box"
        try FileManager.default.createDirectory(at: store.configFile(name).deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: store.configFile(name).path, contents: Data("{}".utf8))
        let prompt = String(repeating: "facts and more facts ", count: 30)          // ~630 characters
        let argv = ["claude", "--append-system-prompt", prompt, "--model", "x"]
        SessionRecords.record("claude", SessionRecord(argv: argv, workdir: "/workspace", user: nil, environmentKeys: nil), store, name)
        let cut = String(argv.joined(separator: " ").prefix(255))
        let row = SessionRow(SessionInfo(name: "claude", pid: 7, command: cut))
        let core = HostCore(store: store, readOnly: true, version: "test",
                            services: CredentialServices(keychain: FakeKeychain(), verifier: FakeVerifier(answer: .verified), claudeBinary: { nil },
                                                         home: root, keepaliveRunner: FakeRunner(), isClaudeRunning: { false },
                                                         watchInterval: .seconds(3600)))
        let out = await core.withOpenedAt(name, [row])
        let back = try HostWire.decoder.decode([SessionRow].self, from: try HostWire.encoder.encode(out))
        XCTAssertEqual(back.first?.argv, argv, "the argv whole")
        XCTAssertEqual(back.first?.argv?[2].count, prompt.count)
        XCTAssertEqual(back.first?.command, cut, "command as it was, for older readers")
        XCTAssertGreaterThan(argv.joined(separator: " ").count, 255)
    }

    /// `--continue` only where Claude Code has a conversation (its own folder naming), else a fresh start.
    func testClaudeConversationCheck() throws {
        XCTAssertEqual(MacPlace.claudeProjectFolderName("/Users/x/my.app_2"), "-Users-x-my-app-2")
        let projects = root.appendingPathComponent("projects").path
        let work = root.appendingPathComponent("work").path
        try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
        XCTAssertFalse(MacPlace.claudeHasConversation(workdir: work, projects: projects), "no projects folder: none")
        let mine = projects + "/" + MacPlace.claudeProjectFolderName(work)
        try FileManager.default.createDirectory(atPath: mine, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: mine + "/notes.txt", contents: Data())
        XCTAssertFalse(MacPlace.claudeHasConversation(workdir: work, projects: projects), "a folder without a .jsonl: none")
        FileManager.default.createFile(atPath: mine + "/abc.jsonl", contents: Data("{}".utf8))
        XCTAssertTrue(MacPlace.claudeHasConversation(workdir: work, projects: projects))
        // /tmp is /private/tmp: the resolved folder's name counts too.
        let resolved = projects + "/" + MacPlace.claudeProjectFolderName("/private" + work)
        try FileManager.default.removeItem(atPath: mine)
        try FileManager.default.createDirectory(atPath: resolved, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: resolved + "/abc.jsonl", contents: Data("{}".utf8))
        XCTAssertTrue(MacPlace.claudeHasConversation(workdir: work, projects: projects))
        XCTAssertEqual(MacPlace.claudeProjects(["DOZ_TEST_GUARD": "1", "DOZ_TEST_CLAUDE_PROJECTS": "/s/p", "HOME": "/h"]), "/s/p")
        XCTAssertEqual(MacPlace.claudeProjects(["DOZ_TEST_REAL_MAC": "1", "DOZ_TEST_CLAUDE_PROJECTS": "/s/p", "HOME": "/h"]), "/h/.claude/projects",
                       "the seam only in a guarded run")
        XCTAssertEqual(MacPlace.claudeProjects(["DOZ_TEST_REAL_MAC": "1", "CLAUDE_CONFIG_DIR": "/c", "HOME": "/h"]), "/c/projects")
    }

    func testBypassIsSeen_neverAdded() {
        XCTAssertTrue(MacPlace.bypassesPermissions(["claude", "--dangerously-skip-permissions"]))
        XCTAssertTrue(MacPlace.bypassesPermissions(["claude", "--permission-mode", "bypassPermissions"]))
        XCTAssertTrue(MacPlace.bypassesPermissions(["claude", "--permission-mode=bypassPermissions"]))
        XCTAssertTrue(MacPlace.bypassesPermissions(["codex", "--dangerously-bypass-approvals-and-sandbox"]))
        XCTAssertFalse(MacPlace.bypassesPermissions(["claude", "--permission-mode", "plan"]))
        XCTAssertFalse(MacPlace.bypassesPermissions(["claude"]))
    }

    func testRestart_claudeContinues_unlessFreshOrNamed() {
        XCTAssertEqual(MacPlace.resumeArguments(["claude"], fresh: false), ["--continue"])
        XCTAssertEqual(MacPlace.resumeArguments(["/usr/local/bin/claude", "--model", "x"], fresh: false), ["--continue"])
        XCTAssertEqual(MacPlace.resumeArguments(["claude"], fresh: true), [])
        XCTAssertEqual(MacPlace.resumeArguments(["claude", "--resume", "abc"], fresh: false), [])
        XCTAssertEqual(MacPlace.resumeArguments(["claude", "-c"], fresh: false), [])
        XCTAssertEqual(MacPlace.resumeArguments(["sh"], fresh: false), [])
    }

    // MARK: 685 M1 — the restart's argv

    static let U = "0f8fad5b-d9cb-469f-a165-70867728950e"
    static let V = "7c9e6679-7425-40de-944b-e07fc1f90ae7"

    /// The table: what a restart opens for each argv (`has`: the transcript exists; `conv`: the folder has a conversation).
    func testRestartArgv_table() {
        let U = Self.U, V = Self.V
        struct Row { var argv: [String]; var fresh = false; var known: String? = nil; var has: Set<String> = []; var conv = false
                     var want: [String]; var how: MacPlace.RestartResume; var line: UInt = #line }
        let rows: [Row] = [
            // --session-id, both forms, with and without a transcript; its place kept.
            Row(argv: ["claude", "--session-id", U, "--remote-control", "admin"], has: [U], want: ["claude", "--resume", U, "--remote-control", "admin"], how: .resume(U)),
            Row(argv: ["claude", "--session-id=\(U)", "--remote-control", "admin"], has: [U], want: ["claude", "--resume", U, "--remote-control", "admin"], how: .resume(U)),
            Row(argv: ["claude", "--session-id", U], conv: true, want: ["claude", "--session-id", U], how: .sessionID(U)),
            Row(argv: ["claude", "--model", "opus", "--session-id", U.uppercased()], has: [U], want: ["claude", "--model", "opus", "--resume", U], how: .resume(U)),
            // --resume: a value, -r, --resume=, a bare picker (taken out), no transcript.
            Row(argv: ["claude", "--resume", U], has: [U], want: ["claude", "--resume", U], how: .resume(U)),
            Row(argv: ["claude", "-r", U, "--verbose"], has: [U], want: ["claude", "--resume", U, "--verbose"], how: .resume(U)),
            Row(argv: ["claude", "--resume=\(U)"], has: [U], want: ["claude", "--resume", U], how: .resume(U)),
            Row(argv: ["claude", "--resume"], conv: true, want: ["claude", "--continue"], how: .continued),
            Row(argv: ["claude", "-r", "--verbose"], want: ["claude", "--verbose"], how: .none),
            Row(argv: ["claude", "--resume", U], want: ["claude", "--session-id", U], how: .sessionID(U)),
            // --fork-session goes (each restart would fork again), with --resume or --session-id.
            Row(argv: ["claude", "--resume", U, "--fork-session"], has: [U], want: ["claude", "--resume", U], how: .resume(U)),
            Row(argv: ["claude", "--fork-session", "--session-id", U], has: [U], want: ["claude", "--resume", U], how: .resume(U)),
            // A value is never read as a flag: -n -c is a name; --name x; --remote-control keeps its value.
            Row(argv: ["claude", "-n", "-c"], conv: true, want: ["claude", "-n", "-c", "--continue"], how: .continued),
            Row(argv: ["claude", "--name", "x", "-c"], conv: true, want: ["claude", "--name", "x", "--continue"], how: .continued),
            Row(argv: ["claude", "--remote-control", "admin", "--session-id", U], has: [U], want: ["claude", "--remote-control", "admin", "--resume", U], how: .resume(U)),
            Row(argv: ["claude", "--remote-control", "--session-id", U], has: [U], want: ["claude", "--remote-control", "--resume", U], how: .resume(U)),
            // Today's rule when nothing is known: --continue with a conversation, else nothing.
            Row(argv: ["claude"], conv: true, want: ["claude", "--continue"], how: .continued),
            Row(argv: ["claude"], want: ["claude"], how: .none),
            Row(argv: ["claude", "--continue"], want: ["claude"], how: .none),
            Row(argv: ["claude", "-c", "--verbose"], conv: true, want: ["claude", "--continue", "--verbose"], how: .continued),
            // --fresh: everything taken out, nothing added (a --session-id too: Claude refuses an id in use).
            Row(argv: ["claude", "--session-id", U, "--remote-control", "admin"], fresh: true, known: V, has: [U, V], conv: true,
                want: ["claude", "--remote-control", "admin"], how: .none),
            // A known id (what it holds, or the learned one) comes first.
            Row(argv: ["claude", "--session-id", U], known: V, has: [U, V], want: ["claude", "--resume", V], how: .resume(V)),
            Row(argv: ["claude"], known: V, has: [V], conv: true, want: ["claude", "--resume", V], how: .resume(V)),
            // An id that is not a UUID is ignored (never passed on, never trusted).
            Row(argv: ["claude", "--resume", "my-chat"], known: "nope", conv: true, want: ["claude", "--continue"], how: .continued),
            Row(argv: ["claude", "--session-id", "x;rm -rf /"], want: ["claude"], how: .none),
            // After `--` nothing is touched; what is put back goes before it.
            Row(argv: ["claude", "--session-id", U, "--", "-c"], has: [U], want: ["claude", "--resume", U, "--", "-c"], how: .resume(U)),
            Row(argv: ["claude", "--", "--continue"], conv: true, want: ["claude", "--continue", "--", "--continue"], how: .continued),
            // Not Claude Code: as it is.
            Row(argv: ["sh", "--session-id", U, "-c", "x"], known: V, has: [U, V], conv: true, want: ["sh", "--session-id", U, "-c", "x"], how: .none),
            Row(argv: ["/opt/homebrew/bin/claude", "--session-id", U], has: [U], want: ["/opt/homebrew/bin/claude", "--resume", U], how: .resume(U)),
        ]
        for r in rows {
            let got = MacPlace.restartArgv(r.argv, fresh: r.fresh, knownID: r.known, transcriptExists: { r.has.contains($0) }, hasConversation: r.conv)
            XCTAssertEqual(got.argv, r.want, "\(r.argv)", line: r.line)
            XCTAssertEqual(got.how, r.how, "\(r.argv)", line: r.line)
        }
    }

    /// The invariant, over generated argvs: never --continue beside --session-id (Claude refuses it and exits at once —
    /// the bug seen on a real Mac), never two conversation choices, never a bare --resume picker, never --fork-session.
    func testRestartArgv_neverContinueBesideSessionID() {
        let words = ["--session-id", Self.U, "--session-id=\(Self.V)", "--continue", "-c", "--resume", "-r", "--resume=\(Self.U)", "--fork-session",
                     "-n", "--name", "x", "--remote-control", "admin", "--model", "opus", "--verbose", "-p", "hi", Self.V, "--"]
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<4000 {
            let argv = ["claude"] + (0..<Int.random(in: 0...7, using: &rng)).map { _ in words.randomElement(using: &rng)! }
            let fresh = Bool.random(using: &rng), conv = Bool.random(using: &rng)
            let known: String? = [nil, Self.U, Self.V, "junk"].randomElement(using: &rng)!
            let has = Bool.random(using: &rng)
            let got = MacPlace.restartArgv(argv, fresh: fresh, knownID: known, transcriptExists: { _ in has }, hasConversation: conv).argv
            // Only the part before `--` is Claude's flags.
            let flags = Array(got.prefix(upTo: got.firstIndex(of: "--") ?? got.count))
            // Values of value-taking flags are not flags.
            var real: [String] = []
            var resumeAt: [Int] = []
            var i = 1
            while i < flags.count {
                let a = flags[i]
                real.append(a)
                if a == "--resume" { resumeAt.append(i) }
                if ["--session-id", "--name", "-n", "--model"].contains(a), i + 1 < flags.count { i += 2; continue }
                if ["--resume", "-r", "--remote-control"].contains(a), i + 1 < flags.count, !flags[i + 1].hasPrefix("-") { i += 2; continue }
                i += 1
            }
            let choices = real.filter { ["--session-id", "--continue", "-c", "--resume", "-r"].contains($0) || $0.hasPrefix("--session-id=") || $0.hasPrefix("--resume=") }
            XCTAssertLessThanOrEqual(choices.count, 1, "\(argv) → \(got)")
            XCTAssertFalse(real.contains("--fork-session"), "\(argv) → \(got)")
            if real.contains("--session-id") { XCTAssertFalse(real.contains("--continue") || real.contains("-c"), "\(argv) → \(got)") }
            for at in resumeAt {
                XCTAssertTrue(at + 1 < flags.count && UUID(uuidString: flags[at + 1]) != nil, "a --resume always names its id: \(argv) → \(got)")
            }
            if fresh { XCTAssertTrue(choices.isEmpty, "fresh adds nothing: \(argv) → \(got)") }
        }
    }

    /// Claude's `sessions/<pid>.json`: a UUID sessionId (lower-cased); malformed, missing, not a UUID, a link → none.
    func testClaudeHeldSessionID_thePidFile() throws {
        let dir = root.appendingPathComponent("claude/sessions").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        func put(_ pid: Int, _ s: String) { FileManager.default.createFile(atPath: dir + "/\(pid).json", contents: Data(s.utf8)) }
        put(101, #"{"pid":101,"sessionId":"\#(Self.U)","cwd":"/x","startedAt":1}"#)
        XCTAssertEqual(MacPlace.claudeHeldSessionID(sessions: dir, pid: 101), Self.U)
        put(102, #"{"sessionId":"\#(Self.V.uppercased())"}"#)
        XCTAssertEqual(MacPlace.claudeHeldSessionID(sessions: dir, pid: 102), Self.V, "upper-case: lower-cased")
        put(103, "{not json")
        XCTAssertNil(MacPlace.claudeHeldSessionID(sessions: dir, pid: 103), "malformed")
        put(104, #"{"sessionId":"../../etc"}"#)
        XCTAssertNil(MacPlace.claudeHeldSessionID(sessions: dir, pid: 104), "not a UUID")
        put(105, #"{"sessionId":42}"#)
        XCTAssertNil(MacPlace.claudeHeldSessionID(sessions: dir, pid: 105))
        XCTAssertNil(MacPlace.claudeHeldSessionID(sessions: dir, pid: 106), "no file")
        XCTAssertNil(MacPlace.claudeHeldSessionID(sessions: dir, pid: 0))
        try FileManager.default.createSymbolicLink(atPath: dir + "/107.json", withDestinationPath: dir + "/101.json")
        XCTAssertNil(MacPlace.claudeHeldSessionID(sessions: dir, pid: 107), "a link is refused")
        // Where it is looked for: beside the projects folder; the seam only in a guarded run.
        XCTAssertEqual(MacPlace.claudeSessions(["DOZ_TEST_GUARD": "1", "DOZ_TEST_CLAUDE_PROJECTS": "/s/home/projects", "HOME": "/h"]), "/s/home/sessions")
        XCTAssertEqual(MacPlace.claudeSessions(["DOZ_TEST_REAL_MAC": "1", "DOZ_TEST_CLAUDE_PROJECTS": "/s/p", "HOME": "/h"]), "/h/.claude/sessions")
        XCTAssertEqual(MacPlace.claudeSessions(["DOZ_TEST_REAL_MAC": "1", "CLAUDE_CONFIG_DIR": "/c", "HOME": "/h"]), "/c/sessions")
        // The transcript check: <projects>/<folder>/<id>.jsonl, a regular file.
        let projects = root.appendingPathComponent("claude/projects").path
        let work = root.appendingPathComponent("w").path
        try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
        let folder = projects + "/" + MacPlace.claudeProjectFolderName(realpath(work, nil).map { p in defer { free(p) }; return String(cString: p) } ?? work)
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        XCTAssertFalse(MacPlace.claudeTranscriptExists(id: Self.U, workdir: work, projects: projects))
        FileManager.default.createFile(atPath: folder + "/\(Self.U).jsonl", contents: Data("{}\n".utf8))
        XCTAssertTrue(MacPlace.claudeTranscriptExists(id: Self.U, workdir: work, projects: projects))
        XCTAssertFalse(MacPlace.claudeTranscriptExists(id: "../x", workdir: work, projects: projects))
    }

    /// Every host operation that is not a session operation refuses @mac, with the one message.
    func testEveryOtherOperationIsRefused() async throws {
        let core = HostCore(store: DozableStore(root: root.appendingPathComponent("store")), readOnly: false, version: "test",
                            services: CredentialServices(keychain: FakeKeychain(), verifier: FakeVerifier(answer: .verified), claudeBinary: { nil },
                                                         home: root, keepaliveRunner: FakeRunner(), isClaudeRunning: { false },
                                                         watchInterval: .seconds(3600)))
        for op in HostOp.allCases where !MacPlace.operations.contains(op) {
            let m = await core.handle(HostRequest(op, name: MacPlace.name))
            XCTAssertNotEqual(m.ok, true, op.rawValue)
            XCTAssertTrue(m.error?.message.contains("@mac is this Mac, not a sandbox") == true, "\(op.rawValue): \(m.error?.message ?? "")")
        }
        XCTAssertFalse(MacPlace.operations.contains(.exec))
        XCTAssertFalse(MacPlace.operations.contains(.start))
    }
}

/// The environment a session on this Mac gets: an allowlist, the markers never.
final class MacSessionsEnvironmentTests: XCTestCase {
    let host: [String: String] = [
        "HOME": "/Users/x", "USER": "x", "LOGNAME": "x", "SHELL": "/bin/zsh", "TMPDIR": "/var/folders/t/", "LANG": "en_AU.UTF-8",
        "LC_CTYPE": "UTF-8", "SSH_AUTH_SOCK": "/tmp/agent", "PATH": "/host/bin",
        "CLAUDECODE": "1", "CLAUDE_CODE_ENTRYPOINT": "cli", "DOZ_STORE": "/s", "ANTHROPIC_API_KEY": "sk-x", "__CF_USER_TEXT_ENCODING": "0",
        "XPC_SERVICE_NAME": "x", "TERM_PROGRAM": "iTerm", "VSCODE_PID": "1", "CURSOR_TRACE_ID": "t", "TERM": "dumb", "SECRET": "s",
    ]

    func testAnAllowlist_builtNew() throws {
        let e = try MacSessionsEnvironment.build(host: host, path: "/usr/bin:/bin")
        XCTAssertEqual(Set(e.keys), ["HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "LC_CTYPE", "SSH_AUTH_SOCK", "TERM", "COLORTERM", "PATH"])
        XCTAssertEqual(e["TERM"], "xterm-256color")
        XCTAssertEqual(e["COLORTERM"], "truecolor")
        XCTAssertEqual(e["PATH"], "/usr/bin:/bin", "never the daemon's PATH")
    }

    func testThePersonsVariables_butNeverTheMarkers() throws {
        let e = try MacSessionsEnvironment.build(host: host, path: "/p", extra: ["PATH": "/mine", "DEVELOPER_DIR": "/x", "FOO": "bar"])
        XCTAssertEqual(e["PATH"], "/mine", "-e PATH=… is the person's to give")
        XCTAssertEqual(e["DEVELOPER_DIR"], "/x")
        XCTAssertThrowsError(try MacSessionsEnvironment.build(host: host, path: "/p", extra: ["CLAUDECODE": "1"]))
        XCTAssertThrowsError(try MacSessionsEnvironment.build(host: host, path: "/p", extra: ["CLAUDE_CODE_ENTRYPOINT": "x"]))
        XCTAssertThrowsError(try MacSessionsEnvironment.build(host: host, path: "/p", extra: ["": "x"]))
        XCTAssertTrue(MacSessionsEnvironment.refusal("CLAUDECODE")?.contains("Claude Code") == true)
    }

    func testPathHelper_fromFixtureFiles() throws {
        let etc = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dzpaths-\(UUID().uuidString.prefix(6))")
        defer { try? FileManager.default.removeItem(at: etc) }
        try FileManager.default.createDirectory(at: etc.appendingPathComponent("paths.d"), withIntermediateDirectories: true)
        try "/usr/local/bin\n/usr/bin\n/bin\n# a comment\n".write(to: etc.appendingPathComponent("paths"), atomically: true, encoding: .utf8)
        try "/b/two\n".write(to: etc.appendingPathComponent("paths.d/20-b"), atomically: true, encoding: .utf8)
        try "/a/one\n/usr/bin\n".write(to: etc.appendingPathComponent("paths.d/10-a"), atomically: true, encoding: .utf8)
        XCTAssertEqual(MacSessionsEnvironment.pathHelperPath(etc: etc.path, home: "/Users/x"),
                       "/usr/local/bin:/usr/bin:/bin:/a/one:/b/two:/opt/homebrew/bin:/Users/x/.local/bin")
    }

    func testTheLoginShellsAnswer_isChecked() {
        XCTAssertEqual(MacSessionsEnvironment.checkedPath("/a:/b\n"), "/a:/b")
        XCTAssertNil(MacSessionsEnvironment.checkedPath("relative:/b"))
        XCTAssertNil(MacSessionsEnvironment.checkedPath("/a\n/b"))
        XCTAssertNil(MacSessionsEnvironment.checkedPath(""))
    }

    func testATestNeverRunsTheLoginShell() {
        XCTAssertEqual(MacSessionsEnvironment.loginPath(host: ["HOME": "/h", "DOZ_TEST_MAC_PATH": "/t/bin", "DOZ_TEST_GUARD": "1"]).path, "/t/bin")
        XCTAssertEqual(MacSessionsEnvironment.loginPath(host: ["HOME": "/h", "DOZ_TEST_GUARD": "1"]).source, "path_helper")
    }
}

/// Records and adoption against a scratch socket folder with fake holders: live, stale, ended, gone.
final class MacSessionsRecordTests: XCTestCase {
    private var root: URL!
    private var dir: String!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: "/tmp/dzmr-\(getpid())-\(UInt32.random(in: 0...UInt32.max))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        dir = root.appendingPathComponent("dh").path
        try MacPlace.ensureFolder(dir)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    /// A listener that answers QUERY with `line` (or, with `line` nil, a socket file nothing listens on).
    private func holder(_ name: String, line: String?) -> Int32 {
        let path = dir + "/" + name + ".sock"
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var a = sockaddr_un()
        a.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &a.sun_path) { r in r.copyBytes(from: Array(path.utf8)); r[path.utf8.count] = 0 }
        _ = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard let line else { Darwin.close(fd); return -1 }
        Darwin.listen(fd, 4)
        let frame = DeckholdFrame.info(line).encoded
        Thread.detachNewThread {
            while true {
                let c = Darwin.accept(fd, nil, nil)
                if c < 0 { return }
                var b = [UInt8](repeating: 0, count: 64)
                _ = Darwin.read(c, &b, b.count)
                frame.withUnsafeBytes { _ = Darwin.write(c, $0.baseAddress, $0.count) }
                Darwin.close(c)
            }
        }
        return fd
    }

    func testAdopt_live_stale_ended_gone() async throws {
        let store = DozableStore(root: root.appendingPathComponent("store"))
        let m = MacSessions(store: store, readOnly: false, environment: ["HOME": "/tmp"], directory: dir)
        let live = holder("live", line: "live\tpid=4242\tsize=80x24\tclients=0\tscreen=primary\thistory=0\tbytes=1\tsh")
        defer { Darwin.shutdown(live, SHUT_RDWR); Darwin.close(live) }
        _ = holder("stale", line: nil)
        try "0\n".write(toFile: dir + "/ended.exit", atomically: true, encoding: .utf8)
        await m.record("live", MacSessionRecord(argv: ["sh"], workdir: "/tmp", openedAt: Date(), pid: 1))
        await m.record("ended", MacSessionRecord(argv: ["true"], workdir: "/tmp", openedAt: Date()))
        await m.record("gone", MacSessionRecord(argv: ["sleep", "9"], workdir: "/tmp", openedAt: Date(), bypassed: true))

        let adopted = await m.adopt()
        XCTAssertEqual(adopted, ["live"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir + "/stale.sock"), "a socket nothing answers is removed")
        XCTAssertEqual(m.records().sessions["live"]?.pid, 4242, "the record follows the holder's pid")

        let rows = await m.rows()
        XCTAssertEqual(rows.map(\.name), ["ended", "gone", "live"])
        let byName = Dictionary(uniqueKeysWithValues: rows.map { ($0.name, $0) })
        XCTAssertEqual(byName["live"]?.ended, false)
        XCTAssertEqual(byName["live"]?.folder, "/tmp")
        XCTAssertEqual(byName["ended"]?.ended, true)
        XCTAssertEqual(byName["ended"]?.exitCode, 0)
        XCTAssertNil(byName["ended"]?.gone)
        XCTAssertEqual(byName["gone"]?.gone, true)
        XCTAssertEqual(byName["gone"]?.bypassed, true)
        XCTAssertEqual(byName["gone"]?.command, "sleep 9")
    }

    func testRecords_are0600_andAReadOnlyLookWritesNothing() async throws {
        let store = DozableStore(root: root.appendingPathComponent("store"))
        let m = MacSessions(store: store, readOnly: false, directory: dir)
        await m.record("a", MacSessionRecord(argv: ["sh"], workdir: "/tmp", environmentKeys: ["K"], openedAt: Date()))
        var st = stat()
        XCTAssertEqual(stat(m.recordsURL.path, &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o600)
        XCTAssertFalse(String(decoding: try Data(contentsOf: m.recordsURL), as: UTF8.self).contains("VALUE"), "names only")
        let ro = MacSessions(store: store, readOnly: true, directory: dir)
        _ = holder("stale", line: nil)
        _ = await ro.adopt()
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir + "/stale.sock"), "looking removes nothing")
    }

    func testAFolderNotOursIsNotRead() async throws {
        chmod(dir, 0o755)
        let m = MacSessions(store: DozableStore(root: root.appendingPathComponent("store")), readOnly: false, directory: dir)
        let l = await m.listing()
        XCTAssertTrue(l.sessions.isEmpty)
        chmod(dir, 0o700)
    }
}
