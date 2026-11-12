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
        XCTAssertEqual(e["PATH"], "/usr/bin:/bin", "never the host's PATH")
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
        XCTAssertEqual(byName["live"]?.workdir, "/tmp")
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
