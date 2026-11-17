import Darwin
import DozableChat
import Foundation
import XCTest

/// docs/chat/client/chat_client.py, the bare-bones Python member, against the real `doz chat serve`: the doz this test
/// run built (beside the test bundle), an empty home, a scratch data folder with a short path, 127.0.0.1 and two ports
/// the test picks. The client runs as `/usr/bin/python3` in a subprocess with a scrubbed environment (PATH, HOME, the
/// two CHAT_ values, no_proxy). Two participants that poll, bot1 and bot2, in room1 with ada (the human).
///
/// A Mac without /usr/bin/python3 FAILS here, never skips: the client is published for agents that have only Python.
/// (CI's Mac runner has it: macOS's /usr/bin/python3 from the Command Line Tools, which the build needs anyway.)
final class ChatPythonClientTests: XCTestCase {
    var root: URL!
    var home: URL { root.appendingPathComponent("home") }
    var data: URL { root.appendingPathComponent("data") }
    var configFile: URL { root.appendingPathComponent("config.json") }
    let tokens = ["ada": "ada-token-0123456789abcdef0123", "bot1": "bot1-token-0123456789abcdef012", "bot2": "bot2-token-0123456789abcdef012"]
    var server: Process?
    var started: [Process] = []
    var page = 0, line = 0

    static let python = "/usr/bin/python3"
    static var client: String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/chat/client/chat_client.py").path
    }

    override func setUpWithError() throws {
        guard FileManager.default.isExecutableFile(atPath: Self.python) else {
            throw NSError(domain: "ChatPythonClientTests", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "\(Self.python) is missing: the chat client's test needs it (install the Command Line Tools: xcode-select --install)"])
        }
        root = URL(fileURLWithPath: "/tmp").appendingPathComponent("dzpy-\(getpid())-\(UUID().uuidString.prefix(6))")
        for d in [root!, home, data] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        page = Self.freePort(); line = Self.freePort()
        let c = """
            {"line_port": \(line), "http_port": \(page), "data_dir": "\(data.path)", "default_room": "general",
             "participants": [{"name": "ada", "kind": "human", "deliver": "web"}, {"name": "bot1", "kind": "agent"}, {"name": "bot2", "kind": "agent"}],
             "rooms": {"general": ["ada"], "room1": ["ada", "bot1", "bot2"]}, "allow": ["127.0.0.1", "::1"], "require_tokens": true,
             "agent_addresses": ["127.0.0.0/8", "::1"], "secrets_file_only": true}
            """
        try Data(c.utf8).write(to: configFile)
        chmod(configFile.path, 0o600)
        let tok = tokens.map { "\"\($0.key)\": \"\($0.value)\"" }.joined(separator: ", ")
        try Data(#"{"version": 1, "tokens": {\#(tok)}, "webhooks": {}}"#.utf8).write(to: data.appendingPathComponent("secrets.json"))
        chmod(data.appendingPathComponent("secrets.json").path, 0o600)
        for name in ["bot1", "bot2"] { try writeToken(name) }
        try startServer()
        // A new server's first answer holds its protocol announcement (protocol 7.7): collected and acknowledged here.
        for name in ["bot1", "bot2"] {
            let r = py(name, ["receive", "--ack"])
            XCTAssertTrue(r.code == 0 && items(r.out).allSatisfy { $0["type"] as? String == "protocol" }, "\(name): \(r.out.prefix(300))")
        }
    }

    override func tearDownWithError() throws {
        for p in started where p.isRunning { kill(p.processIdentifier, SIGKILL); p.waitUntilExit() }
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    // MARK: helpers

    static func freePort() -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var a = sockaddr_in()
        a.sin_family = sa_family_t(AF_INET); a.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        return Int(UInt16(bigEndian: a.sin_port))
    }

    func tokenFile(_ name: String) -> String { root.appendingPathComponent("\(name).token").path }

    func writeToken(_ name: String, value: String? = nil, mode: mode_t = 0o600) throws {
        try Data(((value ?? tokens[name]!) + "\n").utf8).write(to: URL(fileURLWithPath: tokenFile(name)))
        chmod(tokenFile(name), mode)
    }

    func startServer() throws {
        try? FileManager.default.removeItem(at: data.appendingPathComponent("status.json"))
        let p = Process()
        p.executableURL = try ChatServeIsolationTests.doz()
        p.arguments = ["chat", "serve", "--config", configFile.path, "--bind", "127.0.0.1"]
        p.environment = ["HOME": home.path, "TMPDIR": root.path + "/", "PATH": "/usr/bin:/bin",
                         "DOZ_STORE": root.appendingPathComponent("store").path, "XDG_CONFIG_HOME": root.appendingPathComponent("xdg").path]
        p.currentDirectoryURL = root
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        started.append(p)
        server = p
        let status = data.appendingPathComponent("status.json").path
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if !p.isRunning { XCTFail("the chat server exited \(p.terminationStatus)"); return }
            if let d = FileManager.default.contents(atPath: status), let v = try? ChatJSON.parse(d), v.field("ready") == .bool(true) { return }
            usleep(50_000)
        }
        throw XCTSkip("the chat server was not ready within 20 s")
    }

    struct Run { let code: Int32; let out: String; let err: String }

    /// A pipe's bytes as they come (read on its own queue, so a full pipe never blocks the child).
    final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private let handle: FileHandle
        init(_ pipe: Pipe) {
            handle = pipe.fileHandleForReading
            handle.readabilityHandler = { [weak self] h in
                let d = h.availableData
                guard let self, !d.isEmpty else { return }
                self.lock.withLock { self.data.append(d) }
            }
        }
        /// After the process has exited: stop reading and take what is left.
        func finish() {
            handle.readabilityHandler = nil
            let rest = handle.readDataToEndOfFile()
            lock.withLock { data.append(rest) }
        }
        var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
    }

    func environment(_ who: String, file: String? = nil) -> [String: String] {
        ["PATH": "/usr/bin:/bin", "HOME": home.path, "no_proxy": "127.0.0.1", "LANG": "en_US.UTF-8",
         "CHAT_URL": "http://127.0.0.1:\(page)", "CHAT_TOKEN_FILE": file ?? tokenFile(who)]
    }

    func process(_ who: String, _ args: [String], file: String? = nil) -> (Process, Pipe, Pipe) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Self.python)
        p.arguments = ["-I", Self.client] + args
        p.environment = environment(who, file: file)
        p.currentDirectoryURL = root
        let o = Pipe(), e = Pipe()
        p.standardOutput = o
        p.standardError = e
        return (p, o, e)
    }

    @discardableResult
    func py(_ who: String, _ args: [String], stdin: String? = nil, file: String? = nil, timeout: Double = 60) -> Run {
        let (p, o, e) = process(who, args, file: file)
        let i = Pipe()
        p.standardInput = stdin == nil ? FileHandle.nullDevice : i
        do { try p.run() } catch { XCTFail("python3 did not start: \(error)"); return Run(code: -1, out: "", err: "") }
        started.append(p)
        if let stdin { i.fileHandleForWriting.write(Data(stdin.utf8)); try? i.fileHandleForWriting.close() }
        let out = Collector(o), err = Collector(e)
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { usleep(20_000) }
        if p.isRunning { kill(p.processIdentifier, SIGKILL); XCTFail("python3 \(args) timed out") }
        p.waitUntilExit()
        out.finish(); err.finish()
        return Run(code: p.terminationStatus, out: out.text, err: err.text)
    }

    func items(_ out: String) -> [[String: Any]] {
        out.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }

    func content(_ item: [String: Any]) -> String { (item["message"] as? [String: Any])?["content"] as? String ?? "" }

    func assertNoToken(_ texts: String..., line: UInt = #line) {
        for t in tokens.values { for s in texts { XCTAssertFalse(s.contains(t), "a token appears in the output", line: line) } }
    }

    // MARK: the tests

    func testSendReceiveAcknowledge() throws {
        var r = py("bot1", ["send", "room1", "hello from bot1"])
        XCTAssertEqual(r.code, 0, r.err)
        XCTAssertEqual(items(r.out).first?["state"] as? String, "queued")

        r = py("bot2", ["receive", "--wait", "10"])
        XCTAssertEqual(r.code, 0, r.err)
        let got = items(r.out)
        XCTAssertEqual(got.count, 1, r.out)
        XCTAssertEqual(got.first.map(content), "hello from bot1")
        XCTAssertEqual(got.first?["room"] as? String, "room1")
        let firstLine = r.out

        r = py("bot2", ["receive"])
        XCTAssertEqual(r.code, 0)
        XCTAssertTrue(items(r.out).isEmpty, "handed over and not acknowledged: not again within 60 s (\(r.out))")
        r = py("bot2", ["receive", "--redeliver"])
        XCTAssertEqual(items(r.out).first?["redelivered"] as? Bool, true, r.out)

        r = py("bot2", ["ack", "-"], stdin: firstLine)
        XCTAssertEqual(r.code, 0, r.err)
        XCTAssertEqual(items(r.out).first?["acked"] as? Int, 1, r.out)
        r = py("bot2", ["receive", "--redeliver"])
        XCTAssertTrue(items(r.out).isEmpty, "acknowledged: a second receive is empty (\(r.out))")

        r = py("bot1", ["rooms", "--room", "room1"])
        XCTAssertEqual(items(r.out).first?["state"] as? String, "info")
        // /rooms is answered from any existing room, also one the sender is not in (bot1 is not in the default room)
        r = py("bot1", ["rooms"])
        XCTAssertEqual(r.code, 0, r.err)
        XCTAssertTrue((items(r.out).first?["detail"] as? String ?? "").contains("#room1"), r.out)
        r = py("bot1", ["protocol", "--room", "room1"])
        XCTAssertEqual(r.code, 0, r.err)
        XCTAssertTrue(r.out.contains("chat: rooms shared by agents and their human owner."), String(r.out.prefix(200)))
        r = py("bot1", ["send", "nosuch", "x"])
        XCTAssertEqual(r.code, 3)
        XCTAssertTrue(r.err.contains(#"no room "nosuch""#), r.err)

        // listen --once: waits, prints what came, acknowledges it and ends (an agent's background command)
        py("bot1", ["send", "room1", "for the background listener"])
        r = py("bot2", ["listen", "--once", "--wait", "5"], timeout: 30)
        XCTAssertEqual(r.code, 0, r.err)
        XCTAssertEqual(items(r.out).map(content), ["for the background listener"])
        r = py("bot2", ["receive", "--redeliver"])
        XCTAssertTrue(items(r.out).isEmpty, "listen acknowledged it (\(r.out))")
    }

    func testAFileSentAndFetchedHasTheSameBytes() throws {
        var bytes = [UInt8](repeating: 0, count: 5000)
        for i in bytes.indices { bytes[i] = UInt8((i * 7 + 3) % 256) }
        let src = root.appendingPathComponent("report one.bin")
        try Data(bytes).write(to: src)
        var r = py("bot1", ["file", "send", "room1", src.path, "the report"])
        XCTAssertEqual(r.code, 0, r.err)
        XCTAssertEqual(items(r.out).first?["state"] as? String, "queued", r.out)

        r = py("bot2", ["receive", "--wait", "10", "--ack"])
        let att = (items(r.out).first?["attachments"] as? [[String: Any]])?.first
        let url = try XCTUnwrap(att?["url"] as? String, r.out)
        let out = root.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        r = py("bot2", ["file", "get", url, "--out", out.path])
        XCTAssertEqual(r.code, 0, r.err)
        let path = try XCTUnwrap(items(r.out).first?["path"] as? String)
        XCTAssertEqual(URL(fileURLWithPath: path).deletingLastPathComponent().resolvingSymlinksInPath().path, out.resolvingSymlinksInPath().path)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), Data(bytes), "the bytes fetched are the bytes sent")
        r = py("bot2", ["file", "get", url, "--out", out.path])
        XCTAssertEqual(r.code, 1, "never over an existing file")
        r = py("bot2", ["file", "get", url, "--out", out.path, "--name", "../escape.bin"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("escape.bin").path), "never outside the folder")
        r = py("bot2", ["file", "get", "http://example.invalid" + url, "--out", out.path])
        XCTAssertEqual(r.code, 2, "the token goes to no other address")
    }

    func testAWrongTokenIsRefusedAndNoTokenIsShown() throws {
        let wrong = "wrong-token-0123456789abcdef0"
        try writeToken("bad", value: wrong)
        var r = py("bad", ["receive"])
        XCTAssertEqual(r.code, 4, r.err)
        XCTAssertFalse(r.out.contains(wrong) || r.err.contains(wrong), "the wrong token appears in the output")
        r = py("bad", ["send", "room1", "x"])
        XCTAssertEqual(r.code, 4)
        XCTAssertFalse(r.out.contains(wrong) || r.err.contains(wrong))

        try writeToken("loose", value: tokens["bot1"]!, mode: 0o644)
        r = py("loose", ["receive"])
        XCTAssertEqual(r.code, 2, "a token file others can read is refused")
        XCTAssertTrue(r.err.contains("chmod 600"), r.err)
        assertNoToken(r.out, r.err)
    }

    func testListenSurvivesARestartOfTheServer() throws {
        let (p, o, e) = process("bot2", ["listen", "--wait", "3"])
        try p.run()
        started.append(p)
        let out = Collector(o), err = Collector(e)
        func waitFor(_ s: String) -> Bool {
            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline { if out.text.contains(s) { return true }; usleep(100_000) }
            return false
        }
        py("bot1", ["send", "room1", "before the restart"])
        XCTAssertTrue(waitFor("before the restart"), "listen prints a message")

        let old = try XCTUnwrap(server)
        kill(old.processIdentifier, SIGKILL)
        old.waitUntilExit()
        usleep(1_500_000)                                   // listen meets a closed port at least once
        try startServer()
        let r = py("bot1", ["send", "room1", "after the restart"])
        XCTAssertEqual(r.code, 0, r.err)
        XCTAssertTrue(waitFor("after the restart"), "listen goes on after the server restarted (stderr: \(err.text))")
        kill(p.processIdentifier, SIGTERM)
        p.waitUntilExit()
        out.finish(); err.finish()
        let (so, se) = (out.text, err.text)
        XCTAssertTrue(se.contains("trying again"), se)
        XCTAssertEqual(items(so).filter { content($0) == "before the restart" }.count, 1, "acknowledged: not printed twice")
        assertNoToken(so, se)
    }
}
