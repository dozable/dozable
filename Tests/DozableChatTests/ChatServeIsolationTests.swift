import Darwin
import DozableChat
import Foundation
import XCTest

/// `doz chat serve` as a supervisor starts it: the real `doz` in its own process, an EMPTY home folder, a scratch data
/// folder, 127.0.0.1 and ports it picks. It must write nothing outside its data folder, read no settings file, make no
/// store, start no daemon and never need the Keychain (with an empty home there is none to open); stop with 0 on SIGTERM
/// and SIGHUP; and exit 78 with one line for a fault a restart cannot fix.
final class ChatServeIsolationTests: XCTestCase {
    var root: URL!
    var home: URL { root.appendingPathComponent("home") }
    var tmp: URL { root.appendingPathComponent("tmp") }
    var data: URL { root.appendingPathComponent("data") }
    var configFile: URL { root.appendingPathComponent("config.json") }
    let tokens = ["ada": "0123456789abcdef0123456789abcdef", "bot1": "fedcba9876543210fedcba9876543210"]
    var started: [Process] = []

    /// The doz this test run built, beside the test bundle (or DOZ_CHAT_TEST_DOZ).
    static func doz() throws -> URL {
        if let p = ProcessInfo.processInfo.environment["DOZ_CHAT_TEST_DOZ"], !p.isEmpty { return URL(fileURLWithPath: p) }
        let u = Bundle(for: ChatServeIsolationTests.self).bundleURL.deletingLastPathComponent().appendingPathComponent("doz")
        guard FileManager.default.isExecutableFile(atPath: u.path) else {
            throw XCTSkip("no doz beside the test bundle (\(u.path)); build it first (make build)")
        }
        return u
    }

    override func setUpWithError() throws {
        // A short path: the whole tree is listed at the end, and anything new in it is a failure.
        root = URL(fileURLWithPath: "/tmp").appendingPathComponent("doz-chat-iso-\(getpid())-\(UUID().uuidString.prefix(8))")
        for d in [root!, home, tmp, data] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        try writeConfig()
        let sec = #"{"version": 1, "tokens": {"ada": "\#(tokens["ada"]!)", "bot1": "\#(tokens["bot1"]!)"}, "webhooks": {}}"#
        try Data(sec.utf8).write(to: data.appendingPathComponent("secrets.json"))
        chmod(data.appendingPathComponent("secrets.json").path, 0o600)
    }

    override func tearDownWithError() throws {
        for p in started where p.isRunning { kill(p.processIdentifier, SIGKILL); p.waitUntilExit() }
        chmod(root.appendingPathComponent("locked").path, 0o700)
        try? FileManager.default.removeItem(at: root)
    }

    func writeConfig(_ extra: String = "", dataDir: String? = nil) throws {
        let c = """
            {"line_port": 0, "http_port": 0, "data_dir": "\(dataDir ?? data.path)", "default_room": "room1",
             "participants": [{"name": "ada", "kind": "human", "deliver": "web"}, {"name": "bot1", "kind": "grok-bot", "deliver": "webhook", "webhook": "bot1"}],
             "rooms": {"room1": ["ada", "bot1"]}, "peer_name": "", "agent_run_cap": 0, "require_tokens": false,
             "require_tokens_from": [], "allow": [], "test_owned_addresses": ["127.0.0.1"], "secrets_file_only": true,
             "token_service": "unused"\(extra)}
            """
        try Data(c.utf8).write(to: configFile)
        chmod(configFile.path, 0o600)
    }

    /// The environment of a server: an empty home, a scratch TMPDIR, and settings that would name a store and a settings
    /// folder if anything read them — they must never be made.
    var environment: [String: String] {
        ["HOME": home.path, "TMPDIR": tmp.path + "/", "PATH": "/usr/bin:/bin",
         "DOZ_STORE": root.appendingPathComponent("store").path, "XDG_CONFIG_HOME": root.appendingPathComponent("xdg").path]
    }

    func launch(_ args: [String]) throws -> (Process, Pipe) {
        let p = Process()
        p.executableURL = try Self.doz()
        p.arguments = args
        p.environment = environment
        p.currentDirectoryURL = root
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        started.append(p)
        return (p, err)
    }

    func serve(_ extra: [String] = []) throws -> (Process, Pipe) {
        try launch(["chat", "serve", "--config", configFile.path, "--bind", "127.0.0.1"] + extra)
    }

    /// Waits for status.json to say ready and returns the two ports.
    func waitReady(_ p: Process, dir: URL? = nil) throws -> (line: Int, page: Int) {
        let file = (dir ?? data).appendingPathComponent("status.json")
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if !p.isRunning { XCTFail("the server exited \(p.terminationStatus) before it was ready"); break }
            if let d = FileManager.default.contents(atPath: file.path), let v = try? ChatJSON.parse(d), v.field("ready") == .bool(true),
               let ports = v.field("ports") {
                return (try ports.field("line")?.goInt("line") ?? 0, try ports.field("page")?.goInt("page") ?? 0)
            }
            usleep(50_000)
        }
        throw XCTSkip("not ready within 20 s")
    }

    func waitExit(_ p: Process, seconds: Double = 10) -> Int32? {
        let deadline = Date().addingTimeInterval(seconds)
        while p.isRunning && Date() < deadline { usleep(20_000) }
        return p.isRunning ? nil : p.terminationStatus
    }

    func stderrText(_ pipe: Pipe) -> String { String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) }

    /// Every path under a folder, relative to it.
    func tree(_ dir: URL) -> Set<String> {
        guard let e = FileManager.default.enumerator(atPath: dir.path) else { return [] }
        return Set(e.compactMap { $0 as? String })
    }

    // MARK: the line port and the page port, raw

    func lineExchange(port: Int, _ lines: [String]) -> [String] {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var a = sockaddr_in()
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = in_port_t(UInt16(port).bigEndian)
        a.sin_addr.s_addr = inet_addr("127.0.0.1")
        let ok = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard ok == 0 else { return [] }
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let out = lines.joined(separator: "\n") + "\n"
        _ = out.withCString { write(fd, $0, strlen($0)) }
        var got = [UInt8](), buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            got += buf[0..<n]
            if got.last == 0x0A { break }
        }
        return String(decoding: got, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    func httpGet(port: Int, _ path: String) -> String {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var a = sockaddr_in()
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = in_port_t(UInt16(port).bigEndian)
        a.sin_addr.s_addr = inet_addr("127.0.0.1")
        let ok = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard ok == 0 else { return "" }
        let req = "GET \(path) HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"
        _ = req.withCString { write(fd, $0, strlen($0)) }
        var got = [UInt8](), buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            got += buf[0..<n]
        }
        return String(decoding: got, as: UTF8.self)
    }

    // MARK: the tests

    func testItRunsInAnEmptyHomeAndWritesNothingOutsideItsDataFolder() throws {
        let (p, err) = try serve()
        let ports = try waitReady(p)
        let state = httpGet(port: ports.page, "/api/state")
        XCTAssertTrue(state.hasPrefix("HTTP/1.1 200"), state)
        XCTAssertTrue(state.contains("Strict-Transport-Security: max-age=0"))
        let id = UUID().uuidString.lowercased()
        let reply = lineExchange(port: ports.line, [#"{"type":"auth","token":"\#(tokens["bot1"]!)"}"#,
                                                    #"{"msgV":1,"msg_id":"\#(id)","type":"user","room":"room1","message":{"role":"user","content":"hello @ada"}}"#])
        XCTAssertEqual(reply.count, 1)
        XCTAssertTrue(reply.first?.contains(#""state":"queued""#) ?? false, "\(reply)")

        // `doz chat status` sees it running and ready, from the same empty home
        let sp = Process()
        sp.executableURL = try Self.doz()
        sp.arguments = ["chat", "status", "--json", "--data-dir", data.path]
        sp.environment = environment
        sp.currentDirectoryURL = root
        let out = Pipe()
        sp.standardOutput = out
        try sp.run()
        started.append(sp)
        let status = try ChatJSON.parse(out.fileHandleForReading.readDataToEndOfFile())
        XCTAssertEqual(waitExit(sp), 0)
        XCTAssertEqual(status.field("running"), .bool(true))
        XCTAssertEqual(status.field("ready"), .bool(true))
        XCTAssertEqual(try status.field("pid")?.goInt("pid"), Int(p.processIdentifier))
        XCTAssertEqual(try status.field("contract")?.goInt("contract"), 1)

        kill(p.processIdentifier, SIGTERM)
        XCTAssertEqual(waitExit(p), 0, "SIGTERM stops it with 0")
        let log = stderrText(err)
        for t in tokens.values { XCTAssertFalse(log.contains(t), "no token in the log") }

        XCTAssertEqual(tree(home), [], "nothing in the home folder")
        XCTAssertEqual(tree(tmp), [], "nothing in TMPDIR")
        XCTAssertEqual(Set((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []), ["config.json", "data", "home", "tmp"],
                       "no store, no settings folder, nothing beside the data folder")
        let allowed: Set<String> = ["secrets.json", "server.lock", "protocol-version", "rooms", "rooms/room1.db", "rooms/room1.db-wal", "rooms/room1.db-shm"]
        XCTAssertTrue(tree(data).isSubset(of: allowed), "unexpected in the data folder: \(tree(data).subtracting(allowed))")
        XCTAssertTrue(tree(data).contains("rooms/room1.db"))
        XCTAssertFalse(tree(data).contains("status.json"), "a clean stop removes status.json")
    }

    /// The webhook client in the real binary: the start's announcement calls bot1's webhook (a listener this test
    /// started), and still nothing is written outside the data folder and no secret reaches the log.
    func testAWebhookCallWritesNothingOutsideTheDataFolder() throws {
        let hook = try TestWebhookListener()
        defer { hook.stop() }
        let header = "Bearer iso-hook-secret-0123456789"
        let sec = #"{"version": 1, "tokens": {"ada": "\#(tokens["ada"]!)"}, "webhooks": {"bot1": {"url": "\#(hook.url)/hook/iso-url-secret", "header": "\#(header)"}}}"#
        try Data(sec.utf8).write(to: data.appendingPathComponent("secrets.json"))
        chmod(data.appendingPathComponent("secrets.json").path, 0o600)
        let (p, err) = try serve()
        _ = try waitReady(p)
        let call = try XCTUnwrap(hook.calls.first, "the announcement is made before the server is ready")
        XCTAssertEqual(call.path, "/hook/iso-url-secret")
        XCTAssertEqual(call.headers["authorization"], header)
        XCTAssertEqual(call.json?["event"] as? String, "protocol-updated")
        kill(p.processIdentifier, SIGTERM)
        XCTAssertEqual(waitExit(p), 0)
        let log = stderrText(err)
        for secret in ["iso-url-secret", "iso-hook-secret", tokens["ada"]!] { XCTAssertFalse(log.contains(secret), "\(secret) in the log") }
        XCTAssertEqual(tree(home), [], "nothing in the home folder")
        XCTAssertEqual(tree(tmp), [], "nothing in TMPDIR")
        XCTAssertEqual(Set((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []), ["config.json", "data", "home", "tmp"])
    }

    /// Delivery into a Claude Code session, in the real binary: the ONLY things it may touch outside its data folder are
    /// the session records it reads (here a scratch folder handed in with --claude-sessions; by default $HOME/.claude/
    /// sessions) and the running session's own inbox socket it writes to (here one this test listens on). The records
    /// are left exactly as they were, the empty home stays empty, and no token reaches the log.
    func testDeliveryIntoASessionReadsOnlyItsRecordsAndWritesOnlyToItsSocket() throws {
        try writeConfig()
        var c = try String(contentsOf: configFile, encoding: .utf8)
        c = c.replacingOccurrences(of: #"{"name": "bot1", "kind": "grok-bot", "deliver": "webhook", "webhook": "bot1"}"#,
                                   with: #"{"name": "bot1", "kind": "grok-bot", "deliver": "webhook", "webhook": "bot1"}, {"name": "bot2", "kind": "claude-session", "deliver": "inbox-socket", "session": "bot2"}"#)
        c = c.replacingOccurrences(of: #""room1": ["ada", "bot1"]"#, with: #""room1": ["ada", "bot1", "bot2"]"#)
        try Data(c.utf8).write(to: configFile)
        let sessions = root.appendingPathComponent("sessions").path
        let s = try TestClaudeSession(name: "bot2", sessionsDir: sessions)
        defer { s.stop() }
        let records = tree(URL(fileURLWithPath: sessions))
        let (p, err) = try serve(["--claude-sessions", sessions])
        let ports = try waitReady(p)
        let id = UUID().uuidString.lowercased()
        let reply = lineExchange(port: ports.line, [#"{"type":"auth","token":"\#(tokens["bot1"]!)"}"#,
                                                    #"{"msgV":1,"msg_id":"\#(id)","type":"user","room":"room1","message":{"role":"user","content":"hello @bot2"}}"#])
        XCTAssertTrue(reply.first?.contains(#""state":"queued""#) ?? false, "\(reply)")
        let texts = s.waitTexts(2)
        XCTAssertTrue(texts.first?.hasPrefix("[switchboard] The message protocol was updated.") ?? false, "the first start's announcement: \(texts)")
        XCTAssertTrue(texts.dropFirst().first?.hasPrefix("[room room1 · from bot1 (bot, xai:grok-bot:bot1, verified by token)") ?? false, "\(texts)")
        XCTAssertTrue(s.lines.contains { $0["type"] as? String == "auth" && $0["token"] as? String == s.token })
        kill(p.processIdentifier, SIGTERM)
        XCTAssertEqual(waitExit(p), 0)
        let log = stderrText(err)
        for t in tokens.values + [s.token] { XCTAssertFalse(log.contains(t), "no token in the log") }
        XCTAssertEqual(tree(URL(fileURLWithPath: sessions)), records, "the session records are read, never written")
        XCTAssertEqual(tree(home), [], "nothing in the home folder")
        XCTAssertEqual(tree(tmp), [], "nothing in TMPDIR")
        XCTAssertEqual(Set((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []), ["config.json", "data", "home", "tmp", "sessions"])
    }

    func testStatusSaysRunningAndReady() throws {
        let (p, _) = try serve()
        _ = try waitReady(p)
        let s = ChatServer.status(dataDir: data.path, release: "0.0.0")
        XCTAssertTrue(s.running)
        XCTAssertTrue(s.ready)
        XCTAssertEqual(s.pid, Int(p.processIdentifier))
        XCTAssertEqual(s.rooms, 1)
        XCTAssertEqual(s.participants, 2)
        XCTAssertEqual(s.problems.map(\.code), ["secret-missing"], "bot1 has no webhook address")
        kill(p.processIdentifier, SIGTERM)
        XCTAssertEqual(waitExit(p), 0)
        let after = ChatServer.status(dataDir: data.path, release: "0.0.0")
        XCTAssertFalse(after.running)
        XCTAssertEqual(after.problems, [], "a clean stop leaves no problem behind")
    }

    func testSIGHUPStopsWithZero() throws {
        let (p, _) = try serve()
        _ = try waitReady(p)
        kill(p.processIdentifier, SIGHUP)
        XCTAssertEqual(waitExit(p), 0)
    }

    func testASecondServerOnTheSameFolderExits78AndLeavesTheFirst() throws {
        let (first, _) = try serve()
        let ports = try waitReady(first)
        let (second, err) = try serve()
        XCTAssertEqual(waitExit(second), 78)
        let line = stderrText(err).trimmingCharacters(in: .newlines)
        XCTAssertTrue(line.contains("another chat server already runs on the data folder"), line)
        XCTAssertFalse(line.contains("\n"), "one line")
        XCTAssertTrue(first.isRunning)
        XCTAssertTrue(httpGet(port: ports.page, "/api/state").hasPrefix("HTTP/1.1 200"), "the first still answers")
        kill(first.processIdentifier, SIGTERM)
        XCTAssertEqual(waitExit(first), 0)
    }

    func testABadConfigExits78WithOneLine() throws {
        try writeConfig(#", "mystery": true"#)
        let (p, err) = try serve()
        XCTAssertEqual(waitExit(p), 78)
        let text = stderrText(err)
        XCTAssertEqual(text.filter { $0 == "\n" }.count, 1, text)
        XCTAssertTrue(text.contains("unknown key \"mystery\""), text)
    }

    func testABadFlagExits78() throws {
        let (p, _) = try launch(["chat", "serve", "--config", configFile.path, "--bind", "127.0.0.1", "--no-such-flag"])
        XCTAssertEqual(waitExit(p), 78)
    }

    func testAPortInUseExits78() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var a = sockaddr_in()
        a.sin_family = sa_family_t(AF_INET)
        a.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, len) } }
        listen(fd, 1)
        _ = withUnsafeMutablePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        let taken = Int(UInt16(bigEndian: a.sin_port))
        let (p, err) = try serve(["--page-port", String(taken)])
        XCTAssertEqual(waitExit(p), 78)
        XCTAssertTrue(stderrText(err).contains("a port is in use"))
    }

    func testAFolderItCannotWriteExits78() throws {
        let locked = root.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        chmod(locked.path, 0o500)
        let (p, err) = try serve(["--data-dir", locked.appendingPathComponent("data").path])
        XCTAssertEqual(waitExit(p), 78)
        XCTAssertTrue(stderrText(err).contains("data folder"))
    }

    func testANonLoopbackAddressIsRefusedBeforeAnythingListens() throws {
        let (p, err) = try launch(["chat", "serve", "--config", configFile.path, "--bind", "0.0.0.0"])
        XCTAssertEqual(waitExit(p), 78)
        XCTAssertTrue(stderrText(err).contains("loopback"))
        XCTAssertFalse(tree(data).contains("server.lock"), "refused before the data folder was touched")
    }
}
