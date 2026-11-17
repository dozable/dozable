import Darwin
import DozableChat
import Foundation
import XCTest

/// The daemon's profile of the server: tokens as hashes only (`--token-hashes`), the owner's private socket
/// (`--owner-socket`: the human with no token, this user only), no TCP caller ever the human, and `--supervised`'s
/// parent watch. Pure decisions first, then the real `doz` in an empty home.
final class ChatTokenHashesTests: XCTestCase {
    func testHashesOnly() throws {
        let h = ChatSecrets.hash("0123456789abcdef0123")
        let s = try ChatSecrets.parseHashes(Data(#"{"version":1,"sha256":{"bot1":"\#(h)"}}"#.utf8))
        XCTAssertEqual(s.whoHas("0123456789abcdef0123", among: ["bot1"]), "bot1")
        XCTAssertNil(s.whoHas(h, among: ["bot1"]), "the hash itself is not the token")
        for bad in [#"{"version":2,"sha256":{}}"#, #"{"version":1,"sha256":{"bot1":"ABC"}}"#, #"{"version":1,"sha256":{"bot1":"\#(h.uppercased())"}}"#,
                    #"{"version":1,"sha256":{"bot1":1}}"#, "[]"] {
            XCTAssertThrowsError(try ChatSecrets.parseHashes(Data(bad.utf8)), bad)
        }
    }

    func testTheFileChecks() throws {
        let dir = "/tmp/dzc-th-\(getpid())-\(UUID().uuidString.prefix(6))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let f = dir + "/tokens.json"
        FileManager.default.createFile(atPath: f, contents: Data(#"{"version":1,"sha256":{}}"#.utf8))
        chmod(f, 0o644)
        XCTAssertThrowsError(try ChatSecrets.loadHashes(path: f), "readable by others")
        chmod(f, 0o600)
        XCTAssertNoThrow(try ChatSecrets.loadHashes(path: f))
        symlink(f, dir + "/link.json")
        XCTAssertThrowsError(try ChatSecrets.loadHashes(path: dir + "/link.json"), "a link")
    }
}

final class ChatOwnerSocketTests: XCTestCase {
    func testAdmitIsTheSameUserOnly() {
        XCTAssertTrue(ChatOwnerSocket.admit(peerUID: 501, ourUID: 501))
        XCTAssertFalse(ChatOwnerSocket.admit(peerUID: 0, ourUID: 501), "not even root")
        XCTAssertFalse(ChatOwnerSocket.admit(peerUID: 502, ourUID: 501))
        XCTAssertFalse(ChatOwnerSocket.admit(peerUID: nil, ourUID: 501), "an unknown peer")
    }

    func testTheFolderMustBeTheUsersAlone() throws {
        let dir = "/tmp/dzc-os-\(getpid())-\(UUID().uuidString.prefix(6))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        chmod(dir, 0o700)
        XCTAssertNil(ChatOwnerSocket.refusal(path: dir + "/chat.sock"))
        chmod(dir, 0o750)
        XCTAssertNotNil(ChatOwnerSocket.refusal(path: dir + "/chat.sock"), "a group-readable folder")
        chmod(dir, 0o700)
        XCTAssertNotNil(ChatOwnerSocket.refusal(path: dir + "/chat.sock", ourUID: getuid() + 1), "another user's folder")
        XCTAssertNotNil(ChatOwnerSocket.refusal(path: "relative.sock"))
        XCTAssertNotNil(ChatOwnerSocket.refusal(path: dir + "/" + String(repeating: "x", count: 120)))
        FileManager.default.createFile(atPath: dir + "/file", contents: Data())
        XCTAssertNotNil(ChatOwnerSocket.refusal(path: dir + "/file"), "never removes what is not a socket")
        symlink(dir, dir + "-link")
        defer { unlink(dir + "-link") }
        XCTAssertNotNil(ChatOwnerSocket.refusal(path: dir + "-link/chat.sock"), "a folder that is a link")
    }
}

/// The daemon's config, judged by the page handler itself: TCP loopback is an agent address, never the human.
final class ChatProfileTests: XCTestCase {
    var dir: String!
    override func setUpWithError() throws {
        dir = "/tmp/dzc-pr-\(getpid())-\(UUID().uuidString.prefix(6))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(atPath: dir) }

    static func production(_ data: String) -> String {
        #"{"line_port":0,"http_port":0,"data_dir":"\#(data)","default_room":"general","participants":[{"name":"ada","kind":"human","deliver":"web"},{"name":"bot1","kind":"agent"}],"rooms":{"general":["ada","bot1"]},"allow":["127.0.0.1","::1"],"require_tokens":true,"agent_addresses":["127.0.0.0/8","::1"],"secrets_file_only":true,"bind":"127.0.0.1"}"#
    }

    func testTCPIsNeverTheHumanAndTheSocketIs() throws {
        let c = try ChatConfig.parse(Data(Self.production(dir).utf8))
        let token = "bot1-token-0123456789"
        let s = try ChatSecrets.parseHashes(Data(#"{"version":1,"sha256":{"bot1":"\#(ChatSecrets.hash(token))"}}"#.utf8))
        let core = ChatServerCore(config: c, secrets: s, release: "0.0.0")
        core.load()
        defer { core.close() }
        let h = ChatPageHandler(core: core)
        for ip in ["127.0.0.1", "::1", "127.0.0.2"] {
            for p in ["/api/state", "/api/stream", "/", "/api/rooms/general/messages"] {
                XCTAssertEqual(h.handle(ChatHTTPRequest(method: "GET", target: p, remoteIP: ip)).status, 403, "\(ip) \(p)")
            }
            let post = ChatHTTPRequest(method: "POST", target: "/api/rooms/general/messages", body: Array(#"{"content":"hi"}"#.utf8), remoteIP: ip)
            XCTAssertEqual(h.handle(post).status, 403, "posting as the human over TCP")
        }
        XCTAssertNil(c.access.line(remote: "10.0.0.5"))
        XCTAssertEqual(c.access.line(remote: "127.0.0.1"), true, "the line port always wants a token")
        // An agent with its own token on TCP: its /agent/ calls only.
        let rcv = ChatHTTPRequest(method: "GET", target: "/agent/receive", headers: ["authorization": "Bearer " + token], remoteIP: "127.0.0.1")
        XCTAssertEqual(h.handle(rcv).status, 200)
        // The owner's socket: the human, no token, and what it posts is marked checked.
        XCTAssertEqual(h.handle(ChatHTTPRequest(method: "GET", target: "/api/state", remoteIP: "", caller: .owner)).status, 200)
        let post = ChatHTTPRequest(method: "POST", target: "/api/rooms/general/messages", body: Array(#"{"content":"hello @bot1"}"#.utf8),
                                   remoteIP: "", caller: .owner)
        XCTAssertEqual(h.handle(post).status, 200)
        let page = h.handle(ChatHTTPRequest(method: "GET", target: "/api/rooms/general/messages", remoteIP: "", caller: .owner))
        XCTAssertTrue(page.text.contains(#""name":"ada","verified":true"#), page.text)
    }
}

/// The real `doz chat serve` as the daemon starts it: hashes only, the owner's socket, a plain HTTP/1.1 client on it.
final class ChatDaemonProfileServeTests: XCTestCase {
    var root: String!
    var started: [Process] = []
    var chat: String { root + "/chat" }

    override func setUpWithError() throws {
        root = "/tmp/dzc-sv-\(getpid())-\(UUID().uuidString.prefix(6))"
        for d in [root!, chat, root + "/home", root + "/tmp"] {
            try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
    }
    override func tearDownWithError() throws {
        for p in started where p.isRunning { kill(p.processIdentifier, SIGKILL); p.waitUntilExit() }
        try? FileManager.default.removeItem(atPath: root)
    }

    let token = "bot1-token-0123456789"
    let plain = "plain-file-token-0123456789"

    func launch() throws -> Process {
        try Data(ChatProfileTests.production(chat + "/data").utf8).write(to: URL(fileURLWithPath: chat + "/config.json"))
        let h = #"{"version":1,"sha256":{"bot1":"\#(ChatSecrets.hash(token))"}}"#
        FileManager.default.createFile(atPath: chat + "/tokens.json", contents: Data(h.utf8), attributes: [.posixPermissions: 0o600])
        // A plain secrets file in the data folder (an imported one) must never be read.
        try FileManager.default.createDirectory(atPath: chat + "/data", withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        FileManager.default.createFile(atPath: chat + "/data/secrets.json", contents: Data(#"{"version":1,"tokens":{"bot1":"\#(plain)"}}"#.utf8),
                                       attributes: [.posixPermissions: 0o600])
        let p = Process()
        p.executableURL = try ChatServeIsolationTests.doz()
        p.arguments = ["chat", "serve", "--config", chat + "/config.json", "--bind", "127.0.0.1", "--token-hashes", chat + "/tokens.json",
                       "--owner-socket", chat + "/chat.sock", "--supervised"]
        p.environment = ["HOME": root + "/home", "TMPDIR": root + "/tmp/", "PATH": "/usr/bin:/bin"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        started.append(p)
        return p
    }

    func status() -> ChatStatus { ChatServer.status(dataDir: chat + "/data", release: "") }

    func waitReady() -> Bool {
        for _ in 0..<100 { if status().ready { return true }; usleep(100_000) }
        return false
    }

    /// A plain client: a Unix socket, HTTP/1.1 written by hand.
    func unix(_ request: String, until: ((String) -> Bool)? = nil, also: (() -> Void)? = nil) -> String {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var a = sockaddr_un()
        a.sun_family = sa_family_t(AF_UNIX)
        let b = Array((chat + "/chat.sock").utf8)
        withUnsafeMutableBytes(of: &a.sun_path) { p in for (i, c) in b.enumerated() { p[i] = c } }
        guard withUnsafePointer(to: &a, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }) == 0 else { return "" }
        _ = request.withCString { write(fd, $0, strlen($0)) }
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 8192)
        var poked = false
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            out.append(contentsOf: buf[0..<n])
            let text = String(decoding: out, as: UTF8.self)
            if let until {
                if !poked, text.contains("\"kind\":\"hello\"") { poked = true; also?() }
                if until(text) { break }
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    func tcp(_ port: Int, _ request: String) -> String {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var a = sockaddr_in()
        a.sin_family = sa_family_t(AF_INET); a.sin_port = in_port_t(UInt16(port).bigEndian); a.sin_addr.s_addr = inet_addr("127.0.0.1")
        guard withUnsafePointer(to: &a, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }) == 0 else { return "" }
        _ = request.withCString { write(fd, $0, strlen($0)) }
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 8192)
        while true { let n = read(fd, &buf, buf.count); if n <= 0 { break }; out.append(contentsOf: buf[0..<n]) }
        return String(decoding: out, as: UTF8.self)
    }

    func testThePlainHTTPClientOnTheOwnersSocketAndTCPNeverTheHuman() throws {
        _ = try launch()
        XCTAssertTrue(waitReady(), "ready")
        var st = stat()
        XCTAssertEqual(lstat(chat + "/chat.sock", &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o600, "the socket is the user's alone")
        XCTAssertTrue(status().problems.contains { $0.code == "secrets-file-ignored" })
        XCTAssertFalse(status().problems.contains { $0.code == "token-missing" }, "the human needs no token with the owner's socket")

        // GET /api/state over HTTP/1.1, keep-alive closed by the client's Connection: close.
        let state = unix("GET /api/state HTTP/1.1\r\nHost: chat\r\nConnection: close\r\n\r\n")
        XCTAssertTrue(state.hasPrefix("HTTP/1.1 200"), String(state.prefix(200)))
        XCTAssertTrue(state.contains(#""need_token":true"#))

        // /api/stream as SSE: the hello, then a message posted meanwhile (with its X-Chat-Id-free page call).
        let streamed = unix("GET /api/stream HTTP/1.1\r\nHost: chat\r\n\r\n", until: { $0.contains("\"kind\":\"message\"") }) {
            let body = #"{"content":"over the socket"}"#
            _ = self.unix("POST /api/rooms/general/messages HTTP/1.1\r\nHost: chat\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)")
        }
        XCTAssertTrue(streamed.contains("text/event-stream"))
        XCTAssertTrue(streamed.contains("over the socket"), String(streamed.suffix(400)))

        // TCP: never the human.
        let ports = status().ports!
        XCTAssertTrue(tcp(ports.page, "GET /api/state HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n").hasPrefix("HTTP/1.1 403"))
        let post = #"{"content":"x"}"#
        XCTAssertTrue(tcp(ports.page, "POST /api/rooms/general/messages HTTP/1.1\r\nHost: x\r\nContent-Length: \(post.utf8.count)\r\nConnection: close\r\n\r\n\(post)").hasPrefix("HTTP/1.1 403"))
        // The hashed token works; the plain one in the ignored secrets.json does not.
        XCTAssertTrue(tcp(ports.page, "GET /agent/receive HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer \(token)\r\nConnection: close\r\n\r\n").hasPrefix("HTTP/1.1 200"))
        XCTAssertTrue(tcp(ports.page, "GET /agent/receive HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer \(plain)\r\nConnection: close\r\n\r\n").hasPrefix("HTTP/1.1 401"))
        // The line port without a token: a line that is not hello with a token is refused.
        let line = tcp(ports.line, #"{"type":"user","message":{"content":"x"},"room":"general","msg_id":"\#(UUID().uuidString.lowercased())"}"# + "\n")
        XCTAssertFalse(line.contains(#""state":"queued""#), line)
    }

    /// An answer larger than a Unix socket's buffer (8 KiB) arrives WHOLE, every time: the connection is closed only
    /// after the answer has reached the socket. (It was cut short about one time in six.)
    func testALargeAnswerOnTheOwnersSocketIsNeverCutShort() throws {
        _ = try launch()
        XCTAssertTrue(waitReady(), "ready")
        let filler = String(repeating: "x", count: 900)
        for i in 0..<24 {
            let body = #"{"content":"message \#(i) \#(filler)"}"#
            let sent = unix("POST /api/rooms/general/messages HTTP/1.1\r\nHost: chat\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)")
            XCTAssertTrue(sent.hasPrefix("HTTP/1.1 200"), String(sent.prefix(120)))
        }
        var cut = 0
        var size = 0
        for _ in 0..<60 {
            let answer = unix("GET /api/rooms/general/messages?limit=24 HTTP/1.0\r\nHost: chat\r\n\r\n")
            guard let split = answer.range(of: "\r\n\r\n"),
                  let line = answer[..<split.lowerBound].components(separatedBy: "\r\n").first(where: { $0.lowercased().hasPrefix("content-length:") }),
                  let want = Int(line.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) else { cut += 1; continue }
            size = want
            if answer[split.upperBound...].utf8.count != want { cut += 1 }
        }
        XCTAssertGreaterThan(size, 16 * 1024, "the answer is larger than the socket's buffer")
        XCTAssertEqual(cut, 0, "every one of 60 answers arrived whole")
    }

    func testTheServerExitsWhenItsParentIsKilled() throws {
        let iso = ChatProfileTests.production(chat + "/data")
        try Data(iso.utf8).write(to: URL(fileURLWithPath: chat + "/config.json"))
        FileManager.default.createFile(atPath: chat + "/tokens.json", contents: Data(#"{"version":1,"sha256":{}}"#.utf8), attributes: [.posixPermissions: 0o600])
        // A parent shell that starts the server in the background and then waits: killed with SIGKILL, as a daemon can be.
        let doz = try ChatServeIsolationTests.doz().path
        let sh = Process()
        sh.executableURL = URL(fileURLWithPath: "/bin/sh")
        sh.arguments = ["-c", "'\(doz)' chat serve --config '\(chat)/config.json' --bind 127.0.0.1 --token-hashes '\(chat)/tokens.json' --supervised >/dev/null 2>&1 & echo $! > '\(root!)/pid'; wait"]
        sh.environment = ["HOME": root + "/home", "TMPDIR": root + "/tmp/", "PATH": "/usr/bin:/bin"]
        try sh.run()
        started.append(sh)
        XCTAssertTrue(waitReady())
        guard let pid = Int32((try? String(contentsOfFile: root + "/pid", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") else {
            return XCTFail("no pid")
        }
        kill(sh.processIdentifier, SIGKILL)
        var gone = false
        for _ in 0..<40 { if kill(pid, 0) != 0 { gone = true; break }; usleep(50_000) }
        if !gone { kill(pid, SIGKILL) }
        XCTAssertTrue(gone, "the server exited within 2 s of its parent's SIGKILL")
        XCTAssertFalse(status().running)
    }
}
