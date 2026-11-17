import Darwin
import DozableChat
import Foundation
import XCTest

/// dozchat (Guest/dozchat/dozchat.c) against the real `doz chat serve`, as ChatPythonClientTests runs the Python client:
/// the doz this test run built, an empty home, a scratch data folder with a short path, 127.0.0.1 and ports the test
/// picks; dozchat itself compiled here from the source with /usr/bin/cc and the shipped warnings (-Werror). bot1 and bot2
/// poll in room1 with ada (the human); bot3 is in no room.
///
/// Every scenario runs twice: straight to the server, and through `StubProxy` — a proxy the test runs that checks each
/// request's absolute form and its `Proxy-Authorization`, the way a Dozable session's proxy is reached. Neither the token
/// nor the proxy's password may appear in any output, on success or failure. `CannedServer` answers fixed bytes for what
/// the real server never sends (a redirect, chunked encoding, a proxy's 403 and 502).
final class ChatDozchatClientTests: XCTestCase {
    var root: URL!
    var home: URL { root.appendingPathComponent("home") }
    var data: URL { root.appendingPathComponent("data") }
    var configFile: URL { root.appendingPathComponent("config.json") }
    let tokens = ["ada": "ada-token-0123456789abcdef0123", "bot1": "bot1-token-0123456789abcdef012", "bot2": "bot2-token-0123456789abcdef012",
                  "bot3": "bot3-token-0123456789abcdef012"]
    static let proxyPassword = "proxy-PASS-0123456789-secret"
    var server: Process?
    var started: [Process] = []
    var page = 0, line = 0
    var proxy: StubProxy?

    static var source: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Guest/dozchat/dozchat.c")
    }
    nonisolated(unsafe) static var built: String?

    /// dozchat, compiled once per run with the flags build-mac.sh uses.
    static func dozchat() throws -> String {
        if let b = built { return b }
        let dir = "/tmp/dzcc-\(getpid())"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let exe = dir + "/dozchat"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/cc")
        p.arguments = ["-O2", "-std=c11", "-Wall", "-Wextra", "-Wformat=2", "-Wshadow", "-Wvla", "-Werror", "-fstack-protector-strong",
                       "-ftrivial-auto-var-init=zero", "-D_FORTIFY_SOURCE=2", source.path, "-o", exe]
        let e = Pipe()
        p.standardError = e
        try p.run()
        let err = e.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw NSError(domain: "ChatDozchatClientTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "dozchat.c does not compile: " + String(decoding: err, as: UTF8.self)])
        }
        built = exe
        return exe
    }

    override class func tearDown() {
        if let b = built { try? FileManager.default.removeItem(atPath: (b as NSString).deletingLastPathComponent) }
        built = nil
    }

    override func setUpWithError() throws {
        _ = try Self.dozchat()
        root = URL(fileURLWithPath: "/tmp").appendingPathComponent("dzc-\(getpid())-\(UUID().uuidString.prefix(6))")
        for d in [root!, home, data] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        page = ChatPythonClientTests.freePort(); line = ChatPythonClientTests.freePort()
        let c = """
            {"line_port": \(line), "http_port": \(page), "data_dir": "\(data.path)", "default_room": "general",
             "participants": [{"name": "ada", "kind": "human", "deliver": "web"}, {"name": "bot1", "kind": "agent"}, {"name": "bot2", "kind": "agent"}, {"name": "bot3", "kind": "agent"}],
             "rooms": {"general": ["ada"], "room1": ["ada", "bot1", "bot2"]}, "allow": ["127.0.0.1", "::1"], "require_tokens": true,
             "agent_addresses": ["127.0.0.0/8", "::1"], "secrets_file_only": true}
            """
        try Data(c.utf8).write(to: configFile)
        chmod(configFile.path, 0o600)
        let tok = tokens.map { "\"\($0.key)\": \"\($0.value)\"" }.joined(separator: ", ")
        try Data(#"{"version": 1, "tokens": {\#(tok)}, "webhooks": {}}"#.utf8).write(to: data.appendingPathComponent("secrets.json"))
        chmod(data.appendingPathComponent("secrets.json").path, 0o600)
        for name in ["bot1", "bot2", "bot3"] { try writeToken(name) }
        try startServer()
        for name in ["bot1", "bot2"] {
            let r = dz(name, ["receive", "--ack"])
            XCTAssertTrue(r.code == 0 && items(r.out).allSatisfy { $0["type"] as? String == "protocol" }, "\(name): \(r.out.prefix(300)) \(r.err)")
        }
    }

    override func tearDownWithError() throws {
        proxy?.stop()
        for p in started where p.isRunning { kill(p.processIdentifier, SIGKILL); p.waitUntilExit() }
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    // MARK: helpers

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

    /// Through the stub proxy from here on (its password in http_proxy, as a fenced session's).
    func useProxy(password: Bool = true) throws {
        proxy = try StubProxy(upstreamPort: page, password: password ? Self.proxyPassword : nil)
    }

    func environment(_ who: String, file: String? = nil, url: String? = nil) -> [String: String] {
        var e = ["PATH": "/usr/bin:/bin", "HOME": home.path, "LANG": "en_US.UTF-8",
                 "CHAT_URL": url ?? "http://127.0.0.1:\(page)", "CHAT_TOKEN_FILE": file ?? tokenFile(who)]
        if let proxy {
            // A session's proxy has a password; a local proxy without one (Tailscale in userspace, say) is plain.
            e[proxy.expect == nil ? "HTTP_PROXY" : "http_proxy"] = proxy.expect == nil ? "http://127.0.0.1:\(proxy.port)"
                : "http://doz:\(Self.proxyPassword)@127.0.0.1:\(proxy.port)"
            e["NO_PROXY"] = "localhost"
        }
        return e
    }

    func process(_ who: String, _ args: [String], file: String? = nil, url: String? = nil) -> (Process, Pipe, Pipe) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Self.built!)
        p.arguments = args
        p.environment = environment(who, file: file, url: url)
        p.currentDirectoryURL = root
        let o = Pipe(), e = Pipe()
        p.standardOutput = o
        p.standardError = e
        return (p, o, e)
    }

    /// Every output any dozchat printed in this test, for the leak check at the end.
    var allOutput = ""

    @discardableResult
    func dz(_ who: String, _ args: [String], stdin: String? = nil, file: String? = nil, url: String? = nil, timeout: Double = 60) -> ChatPythonClientTests.Run {
        let (p, o, e) = process(who, args, file: file, url: url)
        let i = Pipe()
        p.standardInput = stdin == nil ? FileHandle.nullDevice : i
        do { try p.run() } catch { XCTFail("dozchat did not start: \(error)"); return .init(code: -1, out: "", err: "") }
        started.append(p)
        if let stdin { i.fileHandleForWriting.write(Data(stdin.utf8)); try? i.fileHandleForWriting.close() }
        let out = ChatPythonClientTests.Collector(o), err = ChatPythonClientTests.Collector(e)
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { usleep(20_000) }
        if p.isRunning { kill(p.processIdentifier, SIGKILL); XCTFail("dozchat \(args) timed out") }
        p.waitUntilExit()
        out.finish(); err.finish()
        allOutput += out.text + err.text
        return .init(code: p.terminationStatus, out: out.text, err: err.text)
    }

    func items(_ out: String) -> [[String: Any]] {
        out.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }

    func content(_ item: [String: Any]) -> String { (item["message"] as? [String: Any])?["content"] as? String ?? "" }

    func assertNoSecret(line: UInt = #line) {
        for t in tokens.values { XCTAssertFalse(allOutput.contains(t), "a token appears in dozchat's output", line: line) }
        XCTAssertFalse(allOutput.contains(Self.proxyPassword), "the proxy's password appears in dozchat's output", line: line)
        let basic = Data("doz:\(Self.proxyPassword)".utf8).base64EncodedString()
        XCTAssertFalse(allOutput.contains(basic), "the proxy's credentials appear in dozchat's output", line: line)
    }

    func assertProxied(line: UInt = #line) {
        guard let proxy else { return }
        XCTAssertGreaterThan(proxy.requests, 0, "the calls went through the proxy", line: line)
        XCTAssertEqual(proxy.problems, [], "every request was in absolute form with the proxy's credentials", line: line)
    }

    // MARK: the scenarios (each run direct and proxied)

    func sendReceiveAcknowledge() throws {
        var r = dz("bot1", ["send", "room1", "hello from bot1"])
        XCTAssertEqual(r.code, 0, r.err)
        XCTAssertEqual(items(r.out).first?["state"] as? String, "queued", r.out)

        r = dz("bot2", ["receive", "--wait", "10"])
        XCTAssertEqual(r.code, 0, r.err)
        let got = items(r.out)
        XCTAssertEqual(got.count, 1, r.out)
        XCTAssertEqual(got.first.map(content), "hello from bot1")
        XCTAssertEqual((got.first?["sender"] as? [String: Any])?["verified"] as? Bool, true)
        let firstLine = r.out
        let msg = try XCTUnwrap(got.first?["msg_id"] as? String)

        r = dz("bot2", ["receive"])
        XCTAssertTrue(r.code == 0 && items(r.out).isEmpty, "handed over and not acknowledged: not again within 60 s (\(r.out))")
        r = dz("bot2", ["receive", "--redeliver"])
        XCTAssertEqual(items(r.out).first?["redelivered"] as? Bool, true, r.out)
        r = dz("bot2", ["ack", "-"], stdin: firstLine)
        XCTAssertEqual(r.code, 0, r.err)
        XCTAssertEqual(items(r.out).first?["acked"] as? Int, 1, r.out)
        r = dz("bot2", ["receive", "--redeliver"])
        XCTAssertTrue(items(r.out).isEmpty, "acknowledged: a second receive is empty (\(r.out))")

        // react, an answer by --re, text from stdin with quotes, a backslash and a line break
        r = dz("bot2", ["react", "room1", msg, "like"])
        XCTAssertEqual(r.code, 0, r.err)
        XCTAssertEqual(items(r.out).first?["state"] as? String, "added", r.out)
        let text = "two\nlines with \"quotes\" and \\ and é 😀"
        r = dz("bot2", ["send", "room1", "-", "--re", msg], stdin: text)
        XCTAssertEqual(r.code, 0, r.err)
        r = dz("bot1", ["receive", "--wait", "10", "--ack"])
        let answer = items(r.out).first { content($0) == text }
        XCTAssertNotNil(answer, "the text from stdin arrives as it was: \(r.out)")
        XCTAssertEqual(answer?["re_msg_id"] as? String, msg)
        XCTAssertTrue(r.err.contains("acknowledged"), r.err)

        // ack by reference
        dz("bot1", ["send", "room1", "by reference"])
        r = dz("bot2", ["receive", "--wait", "10"])
        let item = try XCTUnwrap(items(r.out).first)
        r = dz("bot2", ["ack", "room1:\(item["msg_id"] as? String ?? "")"])
        XCTAssertEqual(items(r.out).first?["acked"] as? Int, 1, r.out + r.err)

        // rooms and protocol from anywhere; bot3 is in no room
        r = dz("bot1", ["rooms"])
        XCTAssertTrue(r.code == 0 && (items(r.out).first?["detail"] as? String ?? "").contains("#room1"), r.out)
        r = dz("bot3", ["rooms"])
        XCTAssertEqual(items(r.out).first?["detail"] as? String, "You are in no room.", r.out)
        r = dz("bot3", ["protocol"])
        XCTAssertTrue(r.code == 0 && r.out.contains("chat: rooms shared by agents"), String(r.out.prefix(200)))
        // a 422: printed, exit 3
        r = dz("bot3", ["send", "room1", "x"])
        XCTAssertEqual(r.code, 3, "anything else to a room one is not in is refused")
        r = dz("bot1", ["send", "nosuch", "x"])
        XCTAssertEqual(r.code, 3)
        XCTAssertEqual(items(r.out).first?["state"] as? String, "refused", r.out)
        XCTAssertTrue(r.err.contains(#"no room "nosuch""#), r.err)

        // listen --once: prints what came, acknowledges it, ends
        dz("bot1", ["send", "room1", "for the background listener"])
        r = dz("bot2", ["listen", "--once", "--wait", "5"], timeout: 30)
        XCTAssertEqual(r.code, 0, r.err)
        XCTAssertEqual(items(r.out).map(content), ["for the background listener"])
        r = dz("bot2", ["receive", "--redeliver"])
        XCTAssertTrue(items(r.out).isEmpty, "listen acknowledged it (\(r.out))")
        assertNoSecret()
        assertProxied()
    }

    func aFileBothWays() throws {
        var bytes = [UInt8](repeating: 0, count: 300_000)
        for i in bytes.indices { bytes[i] = UInt8((i * 7 + 3) % 256) }
        let src = root.appendingPathComponent("report one.bin")
        try Data(bytes).write(to: src)
        var r = dz("bot1", ["file", "send", "room1", src.path, "the report"])
        XCTAssertEqual(r.code, 0, r.err)
        XCTAssertEqual(items(r.out).first?["state"] as? String, "queued", r.out)

        r = dz("bot2", ["receive", "--wait", "10", "--ack"])
        let att = (items(r.out).first?["attachments"] as? [[String: Any]])?.first
        let url = try XCTUnwrap(att?["url"] as? String, r.out)
        let out = root.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        r = dz("bot2", ["file", "get", url, "--out", out.path])
        XCTAssertEqual(r.code, 0, r.err)
        let got = try XCTUnwrap(items(r.out).first)
        let path = try XCTUnwrap(got["path"] as? String)
        XCTAssertEqual(got["size"] as? Int, bytes.count)
        XCTAssertEqual(URL(fileURLWithPath: path).deletingLastPathComponent().resolvingSymlinksInPath().path, out.resolvingSymlinksInPath().path)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), Data(bytes), "the bytes fetched are the bytes sent")
        var st = stat()
        XCTAssertEqual(lstat(path, &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o600, "written 0600")
        r = dz("bot2", ["file", "get", url, "--out", out.path])
        XCTAssertEqual(r.code, 1, "never over an existing file")
        // a link where the file would go is never followed
        let target = root.appendingPathComponent("target.txt")
        try Data("keep".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(atPath: out.appendingPathComponent("linked.bin").path, withDestinationPath: target.path)
        r = dz("bot2", ["file", "get", url, "--out", out.path, "--name", "linked.bin"])
        XCTAssertEqual(r.code, 1, "a link in the way is refused")
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "keep", "the link's target is untouched")
        r = dz("bot2", ["file", "get", url, "--out", out.path, "--name", "../escape.bin"])
        XCTAssertEqual(r.code, 0, r.err)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("escape.bin").path), "never outside the folder")
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent("escape.bin").path), "the name cleaned, inside")
        let id = try XCTUnwrap(att?["id"] as? String)
        r = dz("bot2", ["file", "get", id, "--out", out.path, "--name", "by-id.bin"])
        XCTAssertEqual(r.code, 0, r.err)
        r = dz("bot2", ["file", "get", "http://example.invalid" + url, "--out", out.path])
        XCTAssertEqual(r.code, 2, "the token goes to no other address")
        r = dz("bot3", ["file", "get", url, "--out", out.path, "--name", "nope.bin"])
        XCTAssertEqual(r.code, 3, "not a member of the room: no such attachment for it")
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.appendingPathComponent("nope.bin").path), "nothing written on a refusal")
        assertNoSecret()
        assertProxied()
    }

    func refusals() throws {
        let wrong = "wrong-token-0123456789abcdef0"
        try writeToken("bad", value: wrong)
        var r = dz("bad", ["receive"])
        XCTAssertEqual(r.code, 4, r.err)
        XCTAssertFalse(r.out.contains(wrong) || r.err.contains(wrong), "the wrong token appears in the output")
        r = dz("bad", ["send", "room1", "x"])
        XCTAssertEqual(r.code, 4)
        XCTAssertFalse(r.out.contains(wrong) || r.err.contains(wrong))

        try writeToken("loose", value: tokens["bot1"]!, mode: 0o644)
        r = dz("loose", ["receive"])
        XCTAssertEqual(r.code, 2, "a token file others can read is refused")
        XCTAssertTrue(r.err.contains("chmod 600"), r.err)
        try FileManager.default.createSymbolicLink(atPath: tokenFile("link"), withDestinationPath: tokenFile("bot1"))
        r = dz("link", ["receive"])
        XCTAssertEqual(r.code, 2, "a token file that is a link is refused")
        XCTAssertTrue(r.err.contains("not a link"), r.err)
        try writeToken("short", value: "short")
        r = dz("short", ["receive"])
        XCTAssertEqual(r.code, 2, "a token too short to be one")
        r = dz("bot1", ["receive"], url: "https://127.0.0.1:\(page)")
        XCTAssertEqual(r.code, 2)
        XCTAssertTrue(r.err.contains("plain http only"), r.err)
        r = dz("bot1", ["receive"], url: "http://u:p@127.0.0.1:\(page)")
        XCTAssertEqual(r.code, 2, "a user in CHAT_URL")
        r = dz("bot1", ["send", "room1", "x", "--token", tokens["bot1"]!])
        XCTAssertEqual(r.code, 2, "no token on the command line")
        XCTAssertFalse(r.out.contains(tokens["bot1"]!) || r.err.contains(tokens["bot1"]!))
        r = dz("bot1", ["send", "room1", "\u{1}ok"])
        XCTAssertEqual(r.code, 0, "a control character is escaped, not refused")
        assertNoSecret()
    }

    func listenSurvivesARestart() throws {
        let (p, o, e) = process("bot2", ["listen", "--wait", "3"])
        try p.run()
        started.append(p)
        let out = ChatPythonClientTests.Collector(o), err = ChatPythonClientTests.Collector(e)
        func waitFor(_ s: String) -> Bool {
            let deadline = Date().addingTimeInterval(40)
            while Date() < deadline { if out.text.contains(s) { return true }; usleep(100_000) }
            return false
        }
        dz("bot1", ["send", "room1", "before the restart"])
        XCTAssertTrue(waitFor("before the restart"), "listen prints a message")
        let old = try XCTUnwrap(server)
        kill(old.processIdentifier, SIGKILL)
        old.waitUntilExit()
        usleep(1_500_000)
        try startServer()
        let r = dz("bot1", ["send", "room1", "after the restart"])
        XCTAssertEqual(r.code, 0, r.err)
        XCTAssertTrue(waitFor("after the restart"), "listen goes on after the server restarted (stderr: \(err.text))")
        kill(p.processIdentifier, SIGTERM)
        p.waitUntilExit()
        out.finish(); err.finish()
        allOutput += out.text + err.text
        XCTAssertTrue(err.text.contains("trying again"), err.text)
        XCTAssertEqual(items(out.text).filter { content($0) == "before the restart" }.count, 1, "acknowledged: not printed twice")
        assertNoSecret()
    }

    // MARK: the tests

    func testSendReceiveAcknowledgeDirect() throws { try sendReceiveAcknowledge() }
    func testSendReceiveAcknowledgeThroughTheProxy() throws { try useProxy(); try sendReceiveAcknowledge() }
    func testAFileBothWaysDirect() throws { try aFileBothWays() }
    func testAFileBothWaysThroughTheProxy() throws { try useProxy(); try aFileBothWays() }
    func testRefusalsDirect() throws { try refusals() }
    func testRefusalsThroughTheProxy() throws { try useProxy(); try refusals() }
    func testListenSurvivesARestartDirect() throws { try listenSurvivesARestart() }
    func testListenSurvivesARestartThroughTheProxy() throws { try useProxy(); try listenSurvivesARestart(); assertProxied() }
    /// A local proxy with no password (HTTP_PROXY=http://127.0.0.1:PORT): the absolute form, NO Proxy-Authorization, the
    /// answers relayed.
    func testSendReceiveAcknowledgeThroughAProxyWithoutAPassword() throws { try useProxy(password: false); try sendReceiveAcknowledge() }
    func testAFileBothWaysThroughAProxyWithoutAPassword() throws { try useProxy(password: false); try aFileBothWays() }

    /// A proxy that refuses the credentials (407; 401 likewise) and closes before reading the body: exit 4 at once — one
    /// connection, no retry — "the proxy refused the credentials", and its password in no output. A small message, and one
    /// too big for the proxy to have read before it closed.
    func testAProxyThatRefusesTheCredentialsIsExit4AndOneAttempt() throws {
        let big = String(repeating: "x", count: 900_000)
        for status in [407, 401] {
            for text in ["hi", big] {
                let refusing = try RefusingProxy(status: status)
                defer { refusing.stop() }
                let (p, o, e) = process("bot1", text == "hi" ? ["send", "room1", "hi"] : ["send", "room1", "-"])
                var env = p.environment ?? [:]
                env["http_proxy"] = "http://doz:\(Self.proxyPassword)@127.0.0.1:\(refusing.port)"
                env["NO_PROXY"] = "localhost"
                p.environment = env
                let i = Pipe()
                p.standardInput = i
                try p.run()
                started.append(p)
                let out = ChatPythonClientTests.Collector(o), err = ChatPythonClientTests.Collector(e)
                if text != "hi" { DispatchQueue.global().async { i.fileHandleForWriting.write(Data(text.utf8)); try? i.fileHandleForWriting.close() } }
                else { try? i.fileHandleForWriting.close() }
                p.waitUntilExit()
                out.finish(); err.finish()
                allOutput += out.text + err.text
                let what = "\(status), \(text.count) bytes"
                XCTAssertEqual(p.terminationStatus, 4, "\(what): \(err.text)")
                XCTAssertTrue(err.text.contains("dozchat: the proxy refused the credentials (HTTP \(status))"), "\(what): \(err.text)")
                XCTAssertEqual(refusing.connections, 1, "\(what): one attempt, no retry")
                XCTAssertFalse(err.text.contains(String(refusing.port)), "\(what): the proxy's address is not shown")
            }
        }
        assertNoSecret()
    }

    /// What the real server never sends: a redirect (never followed: one connection only), chunked encoding, a head with
    /// two lengths, the proxy's own 403 and 502, an answer cut short — and no secret in any of the words.
    func testAnswersTheServerNeverSends() throws {
        let cases: [(String, Int32, String)] = [
            ("HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:1/agent/receive\r\nContent-Length: 0\r\n\r\n", 1, "redirects are never followed"),
            ("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\n{}\r\n0\r\n\r\n", 1, "chunked"),
            ("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nContent-Length: 2\r\n\r\n{}", 1, "not well-formed"),
            ("HTTP/1.1 403 Forbidden\r\nContent-Type: text/plain\r\nContent-Length: 29\r\n\r\nport 9 is not open to session", 4, "HTTP 403"),
            ("HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\nContent-Length: 0\r\n\r\n", 5, "HTTP 502"),
            ("HTTP/1.1 200 OK\r\nContent-Length: 50\r\n\r\n{\"messages\":[]", 5, "cut off"),
            ("HTTP/1.1 200 OK\r\nContent-Length: 8\r\n\r\nnot json", 5, "not JSON"),
        ]
        for (answer, code, words) in cases {
            let canned = try CannedServer(answer: answer)
            defer { canned.stop() }
            let r = dz("bot1", ["receive"], url: "http://127.0.0.1:\(canned.port)")
            XCTAssertEqual(r.code, code, "\(answer.prefix(30)): \(r.err)")
            XCTAssertTrue(r.err.contains(words), "\(answer.prefix(30)): \(r.err)")
            XCTAssertEqual(canned.connections, 1, "one connection: nothing followed or retried (\(answer.prefix(30)))")
            XCTAssertTrue(canned.lastRequest.hasPrefix("GET /agent/receive?wait=0&ack=1 HTTP/1.1\r\n"), canned.lastRequest)
            XCTAssertTrue(canned.lastRequest.contains("\r\nConnection: close\r\n") && canned.lastRequest.contains("\r\nUser-Agent: dozchat/1\r\n"))
        }
        // send retries a 502 with the same msg_id, three times, and says so
        let canned = try CannedServer(answer: "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n")
        defer { canned.stop() }
        let r = dz("bot1", ["send", "room1", "x"], url: "http://127.0.0.1:\(canned.port)", timeout: 30)
        XCTAssertEqual(r.code, 5, r.err)
        XCTAssertEqual(canned.connections, 3, "send is tried three times")
        let ids = Set(canned.bodies.compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])?["msg_id"] as? String })
        XCTAssertEqual(ids.count, 1, "with the same msg_id: \(canned.bodies)")
        XCTAssertTrue(r.err.contains("with the same msg_id"), r.err)
        assertNoSecret()
    }
}

/// A proxy that refuses the credentials, as tinyproxy does with a wrong password: it reads the request's head only,
/// answers `status` (407, or 401) and closes without reading the body. It counts connections.
final class RefusingProxy: @unchecked Sendable {
    let fd: Int32
    let port: Int
    private let lock = NSLock()
    private var _connections = 0
    var connections: Int { lock.withLock { _connections } }

    init(status: Int) throws {
        let l = try TestListen.listen()
        fd = l.0
        port = l.1
        let reason = status == 407 ? "Proxy Authentication Required" : "Unauthorized"
        Thread.detachNewThread { [self] in
            while true {
                let c = accept(fd, nil, nil)
                if c < 0 { return }
                if TestListen.readHead(c) != nil {
                    lock.withLock { _connections += 1 }
                    _ = TestListen.write(c, "HTTP/1.1 \(status) \(reason)\r\nProxy-Authenticate: Basic realm=\"stub\"\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
                }
                close(c)
            }
        }
    }

    func stop() { shutdown(fd, SHUT_RDWR); close(fd) }
}

/// A plain-HTTP proxy for one test: it accepts absolute-form requests only, checks `Proxy-Authorization: Basic` against
/// its password, forwards the request (origin form, without the proxy's field) to 127.0.0.1:upstreamPort and relays the
/// answer. What it saw wrong is in `problems`.
final class StubProxy: @unchecked Sendable {
    let fd: Int32
    let port: Int
    private let lock = NSLock()
    private var _problems: [String] = []
    private var _requests = 0
    private var stopped = false
    var problems: [String] { lock.withLock { _problems } }
    var requests: Int { lock.withLock { _requests } }

    /// The Proxy-Authorization value it requires; nil: it requires there be NONE.
    let expect: String?

    init(upstreamPort: Int, password: String?) throws {
        let l = try TestListen.listen()
        fd = l.0
        port = l.1
        let expect = password.map { "Basic " + Data("doz:\($0)".utf8).base64EncodedString() }
        self.expect = expect
        Thread.detachNewThread { [self] in
            while true {
                let c = accept(fd, nil, nil)
                if c < 0 { return }
                Thread.detachNewThread { [self] in self.serve(c, upstreamPort: upstreamPort, expect: expect) }
            }
        }
    }

    func stop() {
        lock.withLock { stopped = true }
        shutdown(fd, SHUT_RDWR)
        close(fd)
    }

    private func note(_ s: String) { lock.withLock { _problems.append(s) } }

    private func serve(_ c: Int32, upstreamPort: Int, expect: String?) {
        defer { close(c) }
        guard let (head, rest) = TestListen.readHead(c) else { return }
        lock.withLock { _requests += 1 }
        var lines = head.components(separatedBy: "\r\n")
        let parts = lines[0].split(separator: " ")
        let prefix = "http://127.0.0.1:\(upstreamPort)/"
        guard parts.count == 3, String(parts[1]).hasPrefix(prefix) else {
            note("not the absolute form: \(lines[0])")
            _ = TestListen.write(c, "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n")
            return
        }
        let auth = lines.first { $0.lowercased().hasPrefix("proxy-authorization:") }
        if auth.map({ $0.dropFirst("proxy-authorization:".count).trimmingCharacters(in: .whitespaces) }) != expect {
            note(expect == nil ? "a Proxy-Authorization sent to a proxy without a password" : "no or a wrong Proxy-Authorization")
            _ = TestListen.write(c, "HTTP/1.1 407 Proxy Authentication Required\r\nContent-Length: 0\r\n\r\n")
            return
        }
        lines[0] = "\(parts[0]) /\(String(parts[1]).dropFirst(prefix.count)) \(parts[2])"
        lines.removeAll { $0.lowercased().hasPrefix("proxy-authorization:") }
        let u = TestListen.connect(upstreamPort)
        guard u >= 0 else { _ = TestListen.write(c, "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n"); return }
        defer { close(u) }
        _ = TestListen.write(u, lines.joined(separator: "\r\n") + "\r\n\r\n")
        _ = TestListen.writeBytes(u, rest)
        Thread.detachNewThread { TestListen.pipe(from: c, to: u) }
        TestListen.pipe(from: u, to: c)
    }
}

/// A server that answers every request with the same fixed bytes and closes; it counts connections and keeps the last
/// request's head and every body.
final class CannedServer: @unchecked Sendable {
    let fd: Int32
    let port: Int
    private let lock = NSLock()
    private var _connections = 0
    private var _last = ""
    private var _bodies: [String] = []
    var connections: Int { lock.withLock { _connections } }
    var lastRequest: String { lock.withLock { _last } }
    var bodies: [String] { lock.withLock { _bodies } }

    init(answer: String) throws {
        let l = try TestListen.listen()
        fd = l.0
        port = l.1
        Thread.detachNewThread { [self] in
            while true {
                let c = accept(fd, nil, nil)
                if c < 0 { return }
                if let (head, rest) = TestListen.readHead(c) {
                    var body = rest
                    if let l = head.components(separatedBy: "\r\n").first(where: { $0.lowercased().hasPrefix("content-length:") }),
                       let n = Int(l.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) {
                        body += TestListen.readExactly(c, max(0, n - body.count))
                    }
                    lock.withLock { _connections += 1; _last = head + "\r\n\r\n"; _bodies.append(String(decoding: body, as: UTF8.self)) }
                    _ = TestListen.write(c, answer)
                }
                close(c)
            }
        }
    }

    func stop() { shutdown(fd, SHUT_RDWR); close(fd) }
}

/// Blocking socket helpers for the test's own servers (127.0.0.1, a port the system picks).
enum TestListen {
    static func listen() throws -> (Int32, Int) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var a = sockaddr_in()
        a.sin_family = sa_family_t(AF_INET); a.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &a) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) == 0 && Darwin.listen(fd, 16) == 0 && getsockname(fd, $0, &len) == 0 }
        }
        guard ok else { close(fd); throw NSError(domain: "TestListen", code: 1) }
        return (fd, Int(UInt16(bigEndian: a.sin_port)))
    }

    static func connect(_ port: Int) -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var a = sockaddr_in()
        a.sin_family = sa_family_t(AF_INET); a.sin_addr.s_addr = inet_addr("127.0.0.1"); a.sin_port = in_port_t(UInt16(port).bigEndian)
        let r = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        if r != 0 { close(fd); return -1 }
        return fd
    }

    /// The head (without its blank line) and whatever came after it.
    static func readHead(_ fd: Int32) -> (String, [UInt8])? {
        var buf: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 4096)
        while buf.count < 1 << 20 {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { return nil }
            buf += chunk[0..<n]
            if let r = buf.indices.dropLast(3).first(where: { buf[$0] == 13 && buf[$0 + 1] == 10 && buf[$0 + 2] == 13 && buf[$0 + 3] == 10 }) {
                return (String(decoding: buf[0..<r], as: UTF8.self), Array(buf[(r + 4)...]))
            }
        }
        return nil
    }

    static func readExactly(_ fd: Int32, _ n: Int) -> [UInt8] {
        var out: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 65536)
        while out.count < n {
            let r = read(fd, &chunk, min(chunk.count, n - out.count))
            if r <= 0 { break }
            out += chunk[0..<r]
        }
        return out
    }

    static func write(_ fd: Int32, _ s: String) -> Bool { writeBytes(fd, Array(s.utf8)) }

    static func writeBytes(_ fd: Int32, _ b: [UInt8]) -> Bool {
        var off = 0
        while off < b.count {
            let n = b[off...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if n <= 0 { return false }
            off += n
        }
        return true
    }

    static func pipe(from a: Int32, to b: Int32) {
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(a, &chunk, chunk.count)
            if n <= 0 { shutdown(b, SHUT_WR); return }
            if !writeBytes(b, Array(chunk[0..<n])) { return }
        }
    }
}
