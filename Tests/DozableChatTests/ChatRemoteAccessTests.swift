import Darwin
@testable import DozableChat
import Foundation
import XCTest

/// Agents on other machines: a caller on a remote listener is `ChatCaller.remote` — an agent, with a token, admitted only
/// when its address is in `allow`; never the human, never the page, /api or the stream. A remote caller is SIMULATED by the
/// listeners' internal seam (a 127.0.0.1 listener marked remote, its callers reported as 100.100.1.2): no test binds a
/// tailnet or LAN address. Neutral names, documentation addresses.
final class ChatRemoteAccessTests: XCTestCase {
    static let humanToken = "ada-token-0123456789abcdef"
    static let botToken = "bot1-token-0123456789abcdef"
    static let agent = "100.100.1.2"
    static let stranger = "100.100.1.3"

    var root = ""

    /// The daemon's generated profile with one remote agent.
    func core() throws -> ChatServerCore {
        root = "/tmp/dzc-rm-\(getpid())-\(UUID().uuidString.prefix(6))"
        addTeardownBlock { [dir = root] in try? FileManager.default.removeItem(atPath: dir) }
        try FileManager.default.createDirectory(atPath: root + "/data", withIntermediateDirectories: true)
        let json = """
            {"data_dir": "\(root)/data", "default_room": "room1", "secrets_file_only": true, "require_tokens": true,
             "allow": ["127.0.0.1", "::1", "\(Self.agent)"], "agent_addresses": ["127.0.0.0/8", "::1", "\(Self.agent)"],
             "bind": "127.0.0.1", "remote_bind": ["100.100.1.1"],
             "participants": [{"name": "ada", "kind": "human", "deliver": "web"}, {"name": "bot1", "kind": "grok-bot"}],
             "rooms": {"room1": ["ada", "bot1"]}}
            """
        let c = try ChatConfig.parse(Data(json.utf8))
        try c.check()
        let sec = try ChatSecrets.parse(Data(#"{"version": 1, "tokens": {"ada": "\#(Self.humanToken)", "bot1": "\#(Self.botToken)"}}"#.utf8))
        let core = ChatServerCore(config: c, secrets: sec, release: "1.2.3", sessionsDir: root + "/no-sessions")
        core.load()
        return core
    }

    func remote(_ h: ChatPageHandler, _ method: String, _ target: String, from ip: String = agent, headers: [String: String] = [:]) -> ChatHTTPResponse {
        h.handle(ChatHTTPRequest(method: method, target: target, headers: headers, remoteIP: ip, caller: .remote))
    }

    /// A file bot1 may read (it posted it).
    func file(_ core: ChatServerCore) throws -> String {
        var l = ChatLine()
        l.msgID = chatNewID(); l.room = "room1"; l.content = "a file"; l.hasBody = true
        l.attachments = [try ChatJSON.parse(Array(#"{"name":"f.txt","data_base64":"\#(Data("file bytes".utf8).base64EncodedString())"}"#.utf8))]
        XCTAssertNotEqual(core.post(l, sender: "bot1").state, "refused")
        let m = try core.messagePage(room: "room1", after: 0, before: 0, limit: 500, viewer: "").messages.first { $0.msgID == l.msgID }
        return try XCTUnwrap(m?.attachments.first?.field("id")?.stringValue)
    }

    // MARK: - the page port, every route

    func testEveryRouteOnARemoteListenerIs403ButTheAgentCallsAndAFileWithAToken() throws {
        let core = try core()
        let h = ChatPageHandler(core: core)
        let id = try file(core)
        let bearer = ["authorization": "Bearer " + Self.botToken]
        for route in ChatPageHandler.routes {
            let path = "/" + route.pattern.map { p -> String in
                switch p {
                case "{room}": return "room1"
                case "{id}": return id
                case "{name}": return "f.txt"
                default: return p
                }
            }.joined(separator: "/")
            let agentCall = path.hasPrefix("/agent/")
            let fileCall = path.hasPrefix("/files/")
            for (headers, label) in [([String: String](), "no token"), (bearer, "bot1's token"), (["x-chat-token": Self.humanToken], "the human's token as X-Chat-Token"),
                                     (["authorization": "Bearer " + Self.humanToken], "the human's token")] {
                let r = remote(h, route.method, path, headers: headers)
                if agentCall {
                    let human = label == "the human's token"
                    // GET /agent/asks/<id> of a message that is no ask is 404 (the ask's own answer)
                    let want: Set<Int> = headers["authorization"] == nil || human ? [401] : [200, 400, 403, 404, 409, 422]
                    XCTAssertTrue(want.contains(r.status), "\(route.method) \(path) with \(label): \(r.status) \(r.text)")
                } else if fileCall && route.method == "GET" && headers["authorization"] != nil {
                    XCTAssertEqual(r.status, label == "bot1's token" ? 200 : 404, "\(path) with \(label)")
                } else {
                    XCTAssertEqual(r.status, 403, "\(route.method) \(path) with \(label): \(r.text)")
                    // every token here is someone's (bot1's, the human's): the agent-only text, never "no one's"
                    XCTAssertEqual(r.text, ChatAccess.agentOnly + "\n")
                }
            }
        }
        // An unknown Bearer on /files/ is the agent-address refusal: the address rule comes first (protocol 1.2, the
        // reference's TestS4_8_FetchFromAgentAddress) — never a file, and the text says the token is no one's (0.14.2);
        // HEAD with a token is served.
        let unknown = remote(h, "GET", "/files/\(id)/f.txt", headers: ["authorization": "Bearer no-such-token-0123456789"])
        XCTAssertEqual(unknown.status, 403)
        XCTAssertEqual(unknown.text, ChatAccess.unknownToken + "\n")
        XCTAssertEqual(remote(h, "GET", "/api/state", headers: ["authorization": "Bearer no-such-token-0123456789"]).text, ChatAccess.unknownToken + "\n")
        XCTAssertEqual(remote(h, "HEAD", "/files/\(id)/f.txt", headers: bearer).status, 200)
        // Anything a router would tidy is refused, not followed.
        for t in ["/agent/../api/state", "/agent//send", "/AGENT/send", "/files/\(id)/../\(id)/f.txt", "/%61gent/send", "/"] {
            XCTAssertEqual(remote(h, "GET", t, headers: bearer).status, 403, t)
        }
        // A caller not in allow gets nothing, not even /agent/.
        let out = remote(h, "GET", "/agent/receive", from: Self.stranger, headers: bearer)
        XCTAssertEqual(out.status, 403)
        XCTAssertEqual(out.text, ChatAccess.notOwned + "\n")
    }

    func testTheAccessTableForAnAgentOnAnotherMachine() throws {
        let a = try core().access
        XCTAssertEqual(a.page(remote: Self.agent, agentPath: false), ChatAccess.agentOnly)
        XCTAssertNil(a.page(remote: Self.agent, agentPath: true))
        XCTAssertFalse(a.isOwned(Self.agent))
        XCTAssertEqual(a.line(remote: Self.agent), true, "admitted, with a token")
        XCTAssertNil(a.line(remote: Self.stranger), "not in allow: closed")
        XCTAssertEqual(a.page(remote: Self.stranger, agentPath: false), ChatAccess.notOwned)
    }

    // MARK: - remote_bind in the config

    func testRemoteBindTakesOnlyThisMacsTailscaleAddressesWithTokens() throws {
        func refusal(_ list: [String], tokens: Bool = true) -> String? { ChatConfig.remoteBindRefusal(list, requireTokens: tokens) }
        XCTAssertNil(refusal([]))
        XCTAssertNil(refusal(["100.100.1.1"]))
        XCTAssertNil(refusal(["100.64.0.1", "100.127.255.254"]))
        for bad in ["0.0.0.0", "::", "192.168.1.5", "169.254.1.1", "127.0.0.2", "127.0.0.1", "100.128.0.1", "224.0.0.1", "fd7a:115c:a1e0::1",
                    "100.64.0.0/10", "100.100.01.1", "x"] {
            XCTAssertNotNil(refusal([bad]), bad)
        }
        XCTAssertNotNil(refusal(["100.100.1.1", "100.100.1.1"]))
        XCTAssertNotNil(refusal(["100.100.1.1"], tokens: false), "never without require_tokens")
        let base = #"{"data_dir": "/tmp/x", "secrets_file_only": true, "require_tokens": %@, "remote_bind": ["%@"]}"#
        XCTAssertThrowsError(try ChatConfig.parse(Data(String(format: base, "true", "0.0.0.0").utf8)).check())
        XCTAssertThrowsError(try ChatConfig.parse(Data(String(format: base, "false", "100.100.1.1").utf8)).check())
        XCTAssertNoThrow(try ChatConfig.parse(Data(String(format: base, "true", "100.100.1.1").utf8)).check())
    }

    func testOnlyAnUpTailscaleInterfaceCounts() {
        let ifs = [ChatInterface(name: "lo0", address: "127.0.0.1", up: true), ChatInterface(name: "en0", address: "100.100.1.5", up: true),
                   ChatInterface(name: "utun4", address: "100.100.1.1", up: true), ChatInterface(name: "utun5", address: "100.100.1.6", up: false)]
        XCTAssertEqual(ChatInterface.missing(["100.100.1.1"], among: ifs), [])
        XCTAssertEqual(ChatInterface.missing(["100.100.1.5"], among: ifs), ["100.100.1.5"], "the same range on a LAN interface (carrier-grade NAT) is not Tailscale")
        XCTAssertEqual(ChatInterface.missing(["100.100.1.6"], among: ifs), ["100.100.1.6"], "an interface that is down")
        XCTAssertEqual(ChatInterface.missing(["100.100.1.9"], among: ifs), ["100.100.1.9"])
    }

    // MARK: - over a real listener, through the seam

    struct Wire {
        let page: Int
        let line: Int
        let strangerLine: Int
        let listeners: ChatListeners
        let serving: Task<Void, Never>
    }

    func listen(_ core: ChatServerCore) async throws -> Wire {
        let l = try await ChatListeners.bind(core: core, host: "127.0.0.1",
                                             remote: [.init(host: "127.0.0.1", peer: Self.agent), .init(host: "127.0.0.1", peer: Self.stranger)],
                                             linePort: 0, pagePort: 0, log: .none)
        let serving = Task { await l.serve() }
        let ports = l.remotePorts
        return Wire(page: ports[0].page, line: ports[0].line, strangerLine: ports[1].line, listeners: l, serving: serving)
    }

    static func connect(_ port: Int) -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var a = sockaddr_in()
        a.sin_family = sa_family_t(AF_INET); a.sin_port = in_port_t(UInt16(port).bigEndian); a.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        return fd
    }

    /// Sends the lines; reads what comes back until `replies` lines came or the connection closed. (closed, lines)
    static func lines(_ port: Int, _ out: [String], replies: Int) -> (closed: Bool, got: [String]) {
        let fd = connect(port)
        defer { close(fd) }
        let text = out.joined(separator: "\n") + "\n"
        _ = text.withCString { write(fd, $0, strlen($0)) }
        var got = [UInt8](), buf = [UInt8](repeating: 0, count: 1 << 20)
        while got.filter({ $0 == 0x0A }).count < replies {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { return (true, String(decoding: got, as: UTF8.self).split(separator: "\n").map(String.init)) }
            got += buf[0..<n]
        }
        return (false, String(decoding: got, as: UTF8.self).split(separator: "\n").map(String.init))
    }

    static func http(_ port: Int, _ request: String) -> String {
        let fd = connect(port)
        defer { close(fd) }
        _ = request.withCString { write(fd, $0, strlen($0)) }
        var out = Data(), buf = [UInt8](repeating: 0, count: 65536)
        while true { let n = read(fd, &buf, buf.count); if n <= 0 { break }; out.append(contentsOf: buf[0..<n]) }
        return String(decoding: out, as: UTF8.self)
    }

    /// The bot's day-one use (the line port across the tailnet): send text, an attachment inline, fetch a file with the
    /// `file` line; refused without a token; refused when not in `allow`.
    func testTheBotsDayOneUseOverTheRemoteLinePort() async throws {
        let core = try core()
        let w = try await listen(core)
        defer { w.listeners.close(); w.serving.cancel() }
        let auth = #"{"type":"auth","token":"\#(Self.botToken)"}"#
        func user(_ body: String) -> String { #"{"msgV":1,"type":"user","room":"room1","msg_id":"\#(chatNewID())",\#(body)}"# }
        // text
        var r = await Task.detached { Self.lines(w.line, [auth, user(#""message":{"content":"hello ada"}"#)], replies: 1) }.value
        XCTAssertTrue(r.got.first?.contains(#""state":"queued""#) == true, "\(r.got)")
        // an attachment, inline
        let b64 = Data("weekly export".utf8).base64EncodedString()
        r = await Task.detached { Self.lines(w.line, [auth, user(#""message":{"content":"the export"},"attachments":[{"name":"export.csv","data_base64":"\#(b64)"}]"#)], replies: 1) }.value
        XCTAssertTrue(r.got.first?.contains(#""state":"queued""#) == true, "\(r.got)")
        let sent = try core.messagePage(room: "room1", after: 0, before: 0, limit: 500, viewer: "").messages.last
        XCTAssertEqual(sent?.from, "bot1")
        XCTAssertTrue(sent?.sender?.verified == true)
        let id = try XCTUnwrap(sent?.attachments.first?.field("id")?.stringValue)
        // the file line
        r = await Task.detached { Self.lines(w.line, [auth, #"{"msgV":1,"msg_id":"f1","type":"control","action":"file","id":"\#(id)"}"#], replies: 1) }.value
        let reply = try ChatJSON.parse(Array((r.got.first ?? "").utf8))
        XCTAssertEqual(reply.field("data_base64")?.stringValue, b64)
        // no token: closed with no reply, nothing posted
        let before = try core.messagePage(room: "room1", after: 0, before: 0, limit: 500, viewer: "").messages.count
        r = await Task.detached { Self.lines(w.line, [user(#""from":"bot1","message":{"content":"no token"}"#)], replies: 1) }.value
        XCTAssertTrue(r.closed && r.got.isEmpty, "\(r.got)")
        // the human's token: closed
        r = await Task.detached { Self.lines(w.line, [#"{"type":"auth","token":"\#(Self.humanToken)"}"#, user(#""message":{"content":"as ada"}"#)], replies: 1) }.value
        XCTAssertTrue(r.closed && r.got.isEmpty, "\(r.got)")
        // not in allow: closed at once, even with a token
        r = await Task.detached { Self.lines(w.strangerLine, [auth, user(#""message":{"content":"from a stranger"}"#)], replies: 1) }.value
        XCTAssertTrue(r.closed && r.got.isEmpty, "\(r.got)")
        XCTAssertEqual(try core.messagePage(room: "room1", after: 0, before: 0, limit: 500, viewer: "").messages.count, before)
    }

    func testThePagePortOverTheSeam() async throws {
        let core = try core()
        let w = try await listen(core)
        defer { w.listeners.close(); w.serving.cancel() }
        let id = try file(core)
        let page = w.page
        func get(_ path: String, _ headers: String = "") async -> String {
            await Task.detached { Self.http(page, "GET \(path) HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\(headers)\r\n") }.value
        }
        var r = await get("/api/state")
        XCTAssertTrue(r.hasPrefix("HTTP/1.1 403"), r)
        r = await get("/")
        XCTAssertTrue(r.hasPrefix("HTTP/1.1 403"), r)
        r = await get("/api/stream", "X-Chat-Token: \(Self.humanToken)\r\n")
        XCTAssertTrue(r.hasPrefix("HTTP/1.1 403"), r)
        r = await get("/agent/receive")
        XCTAssertTrue(r.hasPrefix("HTTP/1.1 401"), r)
        r = await get("/agent/receive", "Authorization: Bearer \(Self.botToken)\r\n")
        XCTAssertTrue(r.hasPrefix("HTTP/1.1 200"), r)
        r = await get("/files/\(id)/f.txt", "Authorization: Bearer \(Self.botToken)\r\n")
        XCTAssertTrue(r.hasPrefix("HTTP/1.1 200") && r.hasSuffix("file bytes"), r)
        r = await get("/files/\(id)/f.txt")
        XCTAssertTrue(r.hasPrefix("HTTP/1.1 403"), r)
    }

    func testOneRemoteAddressHoldsAtMost32Connections() async throws {
        let core = try core()
        let w = try await listen(core)
        defer { w.listeners.close(); w.serving.cancel() }
        let port = w.line
        let fds = await Task.detached { (0..<ChatListeners.maxPerRemoteAddress).map { _ in Self.connect(port) } }.value
        defer { for f in fds { close(f) } }
        try await Task.sleep(for: .milliseconds(300))
        let extra = await Task.detached { () -> Int in
            let fd = Self.connect(port)
            defer { close(fd) }
            var b = [UInt8](repeating: 0, count: 16)
            return read(fd, &b, b.count)
        }.value
        XCTAssertEqual(extra, 0, "the 33rd is closed at once")
        for f in fds { close(f) }
        try await Task.sleep(for: .milliseconds(300))
        let again = await Task.detached { Self.lines(port, [#"{"msgV":1,"msg_id":"p","type":"control","action":"ping"}"#], replies: 1) }.value
        XCTAssertTrue(again.closed, "a ping without a token is closed — but the connection was taken, not refused at the cap")
    }
}
