import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import DozableHost
@testable import DozableWeb

/// Chat in the dashboard: the closed routes, the exposure, what passes and what never does. A fake owner's socket (a
/// scratch folder, a thread of this test) stands in for the chat server where the test must plant what a real one never
/// sends; `WebChatRealServerTests` runs the real `doz chat serve` on an owner's socket.
final class WebChatRouteTests: XCTestCase {
    func route(_ m: WebHTTPMethod, _ t: String) -> WebChatRoute? {
        if case .chat(let c)? = WebRoute.parse(method: m, target: t) { return c }
        return nil
    }

    func testTheClosedParse() {
        XCTAssertEqual(route(.get, "/api/v1/chat/status"), .status)
        XCTAssertEqual(route(.get, "/api/v1/chat/state"), .state)
        XCTAssertEqual(route(.get, "/api/v1/chat/presence"), .presence)
        XCTAssertEqual(route(.get, "/api/v1/chat/protocol"), .protocolDescription)
        XCTAssertEqual(route(.get, "/api/v1/chat/stream"), .stream)
        XCTAssertEqual(route(.get, "/api/v1/chat/unread"), .unread([]))
        XCTAssertEqual(route(.get, "/api/v1/chat/unread?room1=4&general=0"), .unread([WebChatMarker(room: "room1", seq: 4), WebChatMarker(room: "general", seq: 0)]))
        XCTAssertEqual(route(.get, "/api/v1/chat/rooms/room1/messages"), .messages(room: "room1", after: nil, before: nil, limit: nil))
        XCTAssertEqual(route(.get, "/api/v1/chat/rooms/room1/messages?after=12&limit=50"), .messages(room: "room1", after: 12, before: nil, limit: 50))
        XCTAssertEqual(route(.post, "/api/v1/chat/rooms/room1/messages"), .post(room: "room1"))
        XCTAssertEqual(route(.get, "/api/v1/chat/files/0123456789abcdef/a.png"), .file(id: "0123456789abcdef", name: "a.png"))
        XCTAssertEqual(route(.get, "/api/v1/chat/files/0123456789abcdef0123456789abcdef/my%20notes%20(1).pdf"),
                       .file(id: "0123456789abcdef0123456789abcdef", name: "my notes (1).pdf"))
    }

    func testNeverReachableAndEveryRule() {
        let refused: [(WebHTTPMethod, String)] = [
            (.get, "/api/v1/chat"), (.get, "/api/v1/chat/"), (.get, "/api/v1/chat/agent/receive"), (.post, "/api/v1/chat/agent/send"),
            (.post, "/api/v1/chat/reload"), (.get, "/api/v1/chat/sw.js"), (.get, "/api/v1/chat/rooms/room1/app"),
            (.post, "/api/v1/chat/files"), (.get, "/api/v1/chat/typing"), (.get, "/api/v1/chat/rooms/room1/reactions"),
            (.post, "/api/v1/chat/rooms/room1/messages/0f8fad5b-d9cb-469f-a165-70867728950e/pin"),
            (.post, "/api/v1/chat/state"), (.delete, "/api/v1/chat/rooms/room1/messages"), (.post, "/api/v1/chat/stream"),
            (.get, "/api/v1/chat/state?x=1"), (.get, "/api/v1/chat/stream?after=1"), (.post, "/api/v1/chat/rooms/room1/messages?x=1"),
            (.get, "/api/v1/chat/rooms/Room1/messages"), (.get, "/api/v1/chat/rooms/-x/messages"), (.get, "/api/v1/chat/rooms/../messages"),
            (.get, "/api/v1/chat/rooms/" + String(repeating: "a", count: 65) + "/messages"),
            (.get, "/api/v1/chat/rooms/room1/messages?after=-1"), (.get, "/api/v1/chat/rooms/room1/messages?limit=0"),
            (.get, "/api/v1/chat/rooms/room1/messages?limit=501"), (.get, "/api/v1/chat/rooms/room1/messages?after=1&after=2"),
            (.get, "/api/v1/chat/rooms/room1/messages?token=x"), (.get, "/api/v1/chat/rooms/room1/messages?after=01"),
            (.get, "/api/v1/chat/unread?Room=1"), (.get, "/api/v1/chat/unread?room1=x"), (.get, "/api/v1/chat/unread?room1=1&room1=2"),
            (.get, "/api/v1/chat/files/0123456789abcde/a.png"), (.get, "/api/v1/chat/files/0123456789ABCDEF/a.png"),
            (.get, "/api/v1/chat/files/0123456789abcdef/..%2Fx"), (.get, "/api/v1/chat/files/0123456789abcdef/%2e%2e"),
            (.get, "/api/v1/chat/files/0123456789abcdef/.hidden"), (.get, "/api/v1/chat/files/0123456789abcdef/a/b"),
            (.get, "/api/v1/chat/files/0123456789abcdef/a.png?download=1"), (.post, "/api/v1/chat/files/0123456789abcdef/a.png"),
            (.get, "/api/v1/chat/files/0123456789abcdef/a;b.png"), (.get, "/api/v1/chat/files/0123456789abcdef/" + String(repeating: "a", count: 121)),
        ]
        for (m, t) in refused { XCTAssertNil(WebRoute.parse(method: m, target: t), "\(m) \(t)") }
        let many = (0..<257).map { "r\($0)=1" }.joined(separator: "&")
        XCTAssertNil(route(.get, "/api/v1/chat/unread?" + many), "at most 256 markers")
        XCTAssertNotNil(route(.get, "/api/v1/chat/unread?" + (0..<256).map { "r\($0)=1" }.joined(separator: "&")))
        XCTAssertTrue(WebChatRoute.isActionID("0f8fad5b-d9cb-469f-a165-70867728950e"))
        XCTAssertFalse(WebChatRoute.isActionID("0f8fad5b-d9cb-169f-a165-70867728950e"), "v4 only")
        XCTAssertFalse(WebChatRoute.isActionID("0F8FAD5B-D9CB-469F-A165-70867728950E"))
    }

    func testTheUpstreamTargetIsBuiltFromCheckedValuesOnly() {
        XCTAssertEqual(WebChatRoute.messages(room: "room1", after: 3, before: nil, limit: 20).upstreamTarget, "/api/rooms/room1/messages?after=3&limit=20")
        XCTAssertEqual(WebChatRoute.unread([WebChatMarker(room: "general", seq: 9)]).upstreamTarget, "/api/unread?general=9")
        XCTAssertEqual(WebChatRoute.file(id: "0123456789abcdef", name: "my notes.pdf").upstreamTarget, "/files/0123456789abcdef/my%20notes.pdf")
        XCTAssertEqual(WebChatRoute.post(room: "general").upstreamTarget, "/api/rooms/general/messages")
    }

    func testEveryChatRouteIsKindChatAndARemoteBrowserIsRefused() {
        let all: [WebChatRoute] = [.status, .state, .presence, .unread([]), .protocolDescription, .messages(room: "r", after: nil, before: nil, limit: nil),
                                   .post(room: "r"), .stream, .file(id: "0123456789abcdef", name: "a")]
        for c in all {
            XCTAssertEqual(WebExposure.kind(.chat(c)), .chat)
            XCTAssertEqual(WebExposure.decide(.chat(c), .remote(secure: true), macSessions: .interactive), .chatRemote)
            XCTAssertEqual(WebExposure.decide(.chat(c), .remote(secure: false)), .chatRemote)
            XCTAssertNil(WebExposure.decide(.chat(c), .mac))
        }
        XCTAssertEqual(WebRejection.chatRemote.status, 403)
        XCTAssertEqual(WebRejection.chatOff.status, 503)
        XCTAssertTrue(WebRejection.chatOff.message.contains("doz chat on"))
        XCTAssertTrue(WebRejection.chatNotReady.message.contains("doz chat status"))
    }

    func testThePostBodyIsStrictAndReEncoded() throws {
        let ok = try WebChatProjection.postBody(Data(#"{"content":"hi @bot1","to":["bot1"],"re_msg_id":"0f8fad5b"}"#.utf8))
        XCTAssertEqual(String(decoding: ok, as: UTF8.self), #"{"content":"hi @bot1","re_msg_id":"0f8fad5b","to":["bot1"]}"#)
        for bad in [#"{}"#, #"{"content":""}"#, #"{"content":1}"#, #"{"content":"x","attachments":[{"id":"x"}]}"#, #"{"content":"x","private":true}"#,
                    #"{"content":"x","to":["Bot1"]}"#, #"{"content":"x","to":"bot1"}"#, #"{"content":"x","re_msg_id":"zz"}"#, #"[1]"#, "not json",
                    #"{"content":"x","msg_id":"0f8fad5b-d9cb-469f-a165-70867728950e"}"#] {
            XCTAssertThrowsError(try WebChatProjection.postBody(Data(bad.utf8)), bad)
        }
        let big = String(repeating: "a", count: 64 * 1024 + 1)
        XCTAssertThrowsError(try WebChatProjection.postBody(Data(#"{"content":"\#(big)"}"#.utf8)))
        let names = (0..<33).map { "\"b\($0)\"" }.joined(separator: ",")
        XCTAssertThrowsError(try WebChatProjection.postBody(Data(#"{"content":"x","to":[\#(names)]}"#.utf8)))
    }

    func testTheStateProjectionDropsTheTokenFields() throws {
        let canary = "dzc_CANARYvalue0123456789"
        let up = #"{"rooms":{"general":["ada","bot1"],"BAD":["x"]},"archived":["old"],"participants":[{"name":"ada","kind":"human","deliver":"web","identity":"\#(canary)"},{"name":"bot1","kind":"agent","webhook":"\#(canary)","session":"\#(canary)"}],"default_room":"general","token_service":"\#(canary)","need_token":true,"reactions":[{"name":"like","emoji":"👍"}],"version":"v1","release":"\#(canary)","https_url":"https://\#(canary)","apps":{"general":{"name":"\#(canary)"}}}"#
        let out = try XCTUnwrap(WebChatProjection.state(Data(up.utf8)))
        let text = String(decoding: out, as: UTF8.self)
        XCTAssertFalse(text.contains("dzc_"), text)
        let o = try XCTUnwrap(try JSONSerialization.jsonObject(with: out) as? [String: Any])
        XCTAssertEqual(Set(o.keys), ["rooms", "archived", "participants", "default_room", "reactions", "version"])
        XCTAssertEqual((o["participants"] as? [[String: String]])?.first, ["name": "ada", "kind": "human"])
        XCTAssertNil((o["rooms"] as? [String: Any])?["BAD"])
    }

    func testTheErrorIsReWrappedAndCut() throws {
        let (s, d) = WebChatProjection.error(status: 422, Data(#"{"msg_id":"x","state":"refused","detail":"\#(String(repeating: "x", count: 400))"}"#.utf8))
        XCTAssertEqual(s, 422)
        let e = try XCTUnwrap((try JSONSerialization.jsonObject(with: d) as? [String: Any])?["error"] as? [String: String])
        XCTAssertEqual(e["code"], "chat")
        XCTAssertEqual(e["message"]?.count, 300)
        XCTAssertEqual(WebChatProjection.error(status: 302, Data()).0, 502, "never a redirect")
    }

    func testTheFileHeadersAreDecidedHere() {
        func h(_ t: String?) -> [String: String] { Dictionary(WebChatProjection.fileHeaders(upstreamType: t, name: "x\"y.svg").map { ($0.0.lowercased(), $0.1) }) { a, _ in a } }
        let png = h("image/png")
        XCTAssertEqual(png["content-type"], "image/png")
        XCTAssertNil(png["content-disposition"])
        for t in ["image/svg+xml", "text/html; charset=utf-8", nil, "application/pdf", "image/png+evil"] {
            let x = h(t)
            XCTAssertEqual(x["content-type"], "application/octet-stream", t ?? "none")
            XCTAssertEqual(x["content-disposition"], "attachment; filename=\"xy.svg\"")
        }
        for x in [png, h("text/html")] {
            XCTAssertEqual(x["x-content-type-options"], "nosniff")
            XCTAssertEqual(x["content-security-policy"], "sandbox; default-src 'none'")
            XCTAssertEqual(x["cross-origin-resource-policy"], "same-origin")
            XCTAssertEqual(x["cache-control"], "private, no-store")
            XCTAssertEqual(x["referrer-policy"], "no-referrer")
        }
    }

    func testAStreamLineIsJudged() {
        XCTAssertEqual(WebChatProjection.streamKind(#"{"kind":"message","room":"general"}"#), "message")
        XCTAssertNil(WebChatProjection.streamKind(#"{"kind":3}"#))
        XCTAssertNil(WebChatProjection.streamKind("[1]"))
        XCTAssertNil(WebChatProjection.streamKind("not json"))
        XCTAssertNil(WebChatProjection.streamKind(#"{"kind":"x","t":""# + String(repeating: "a", count: 1 << 20) + #""}"#))
    }

    func testTheBodyLimitIsPerRoute() throws {
        XCTAssertEqual(DozableWebServer.bodyLimit(.chat(.post(room: "r")), .standard), 80 * 1024)
        XCTAssertEqual(DozableWebServer.bodyLimit(.actions, .standard), 16 * 1024)
    }
}

/// A stand-in for the chat server's owner's socket, in a scratch folder: what it was asked, and what it answers.
final class FakeChatSocket: @unchecked Sendable {
    struct Asked { var head: String; var body: Data }
    enum Reply { case raw(Data); case stream([String], hold: Bool) }

    let path: String
    private let fd: Int32
    private let lock = NSLock()
    private var _asked: [Asked] = []
    private var _streamsClosed = 0
    var handler: @Sendable (Asked) -> Reply

    var asked: [Asked] { lock.withLock { _asked } }
    var streamsClosed: Int { lock.withLock { _streamsClosed } }

    init(path: String, handler: @escaping @Sendable (Asked) -> Reply) throws {
        self.path = path
        self.handler = handler
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let b = Array(path.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { p in for (i, c) in b.enumerated() { p[i] = c }; p[b.count] = 0 }
        let r = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard r == 0, listen(fd, 16) == 0 else { throw POSIXError(.EADDRINUSE) }
        let t = Thread { [self] in acceptLoop() }
        t.start()
    }

    func stop() { shutdown(fd, SHUT_RDWR); close(fd); unlink(path) }

    static func answer(_ status: Int, _ headers: [(String, String)], _ body: String) -> Reply {
        var s = "HTTP/1.0 \(status) X\r\n"
        for (k, v) in headers { s += "\(k): \(v)\r\n" }
        return .raw(Data((s + "Content-Length: \(body.utf8.count)\r\n\r\n" + body).utf8))
    }

    private func acceptLoop() {
        while true {
            let c = accept(fd, nil, nil)
            if c < 0 { return }
            Thread { [self] in serve(c) }.start()
        }
    }

    private func serve(_ c: Int32) {
        defer { close(c) }
        var one: Int32 = 1
        setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var buf = Data(), chunk = [UInt8](repeating: 0, count: 65536)
        while buf.range(of: Data("\r\n\r\n".utf8)) == nil {
            let n = read(c, &chunk, chunk.count)
            if n <= 0 { return }
            buf.append(contentsOf: chunk[0..<n])
        }
        let end = buf.range(of: Data("\r\n\r\n".utf8))!
        let head = String(decoding: buf[..<end.lowerBound], as: UTF8.self)
        var body = Data(buf[end.upperBound...])
        if let l = head.components(separatedBy: "\r\n").first(where: { $0.lowercased().hasPrefix("content-length:") }),
           let n = Int(l.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) {
            while body.count < n { let k = read(c, &chunk, chunk.count); if k <= 0 { break }; body.append(contentsOf: chunk[0..<k]) }
        }
        let a = Asked(head: head, body: body)
        lock.withLock { _asked.append(a) }
        func put(_ d: Data) { _ = d.withUnsafeBytes { write(c, $0.baseAddress, d.count) } }
        switch handler(a) {
        case .raw(let d): put(d)
        case .stream(let lines, let hold):
            put(Data("HTTP/1.0 200 OK\r\nContent-Type: text/event-stream\r\n\r\n".utf8))
            for l in lines { put(Data("data: \(l)\n\n".utf8)) }
            if hold { while read(c, &chunk, chunk.count) > 0 {} }
            lock.withLock { _streamsClosed += 1 }
        }
    }
}

/// The routes through a real dashboard listener against `FakeChatSocket`.
final class WebChatHTTPTests: XCTestCase {
    var root: String!
    var server: DozableWebServer!
    var serveTask: Task<Void, Error>!
    var socket: FakeChatSocket?
    var lockFD: Int32 = -1
    let capability = try! WebBootstrapCapability(testingValue: "test-capability-abcdefghijklmnopqrstuvwxyz")
    let fake = FakeData()
    static let canary = "dzc_CANARYvalue0123456789abcdef"

    override func setUpWithError() throws {
        root = "/tmp/dzw-\(getpid())-\(UUID().uuidString.prefix(6))"
        for d in [root!, root + "/chat", root + "/cfg/doz"] {
            try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        fake.storePath = root
    }

    override func tearDown() async throws {
        await server?.close()
        _ = try? await serveTask?.value
        server = nil
        socket?.stop()
        if lockFD >= 0 { close(lockFD) }
        try? FileManager.default.removeItem(atPath: root)
    }

    func start(chatOn: Bool, limits: WebLimits = .standard) async throws {
        try Data((chatOn ? "[chat]\nenabled = true\n" : "").utf8).write(to: URL(fileURLWithPath: root + "/cfg/doz/doz.toml"))
        let settings = WebSettingsStore(environment: ["XDG_CONFIG_HOME": root + "/cfg"])
        XCTAssertEqual(settings.bool(SettingKey.chatEnabled), chatOn)
        server = try await DozableWebServer.bind(data: fake, assets: try WebAssets.load(), version: "test", limits: limits, settings: settings,
                                                capability: capability, pollInterval: .milliseconds(200))
        let s = server!
        serveTask = Task { try await s.run() }
    }

    func holdTheDaemonLock() {
        lockFD = open(root + "/daemon.lock", O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        XCTAssertEqual(flock(lockFD, LOCK_EX | LOCK_NB), 0)
    }

    func signIn() throws -> (cookie: String, csrf: String) {
        let s = server!
        let boot = try RawHTTP.request(port: s.origin.port, method: "POST", path: "/api/v1/session",
                                       headers: ["Host": s.origin.authority, "Origin": s.origin.value, "Authorization": "Bearer \(capability.value)"])
        XCTAssertEqual(boot.status, 200, boot.text)
        let cookie = String(try XCTUnwrap(boot.header("set-cookie")).split(separator: ";")[0])
        let csrf = try XCTUnwrap((try JSONSerialization.jsonObject(with: boot.body) as? [String: Any])?["csrf"] as? String)
        return (cookie, csrf)
    }

    func get(_ path: String, _ cookie: String, extra: [String: String] = [:]) throws -> RawResponse {
        try RawHTTP.request(port: server.origin.port, method: "GET", path: path,
                            headers: ["Host": server.origin.authority, "Cookie": cookie].merging(extra) { $1 })
    }

    func post(_ path: String, _ body: String, cookie: String, csrf: String?, origin: String? = nil) throws -> RawResponse {
        var h = ["Host": server.origin.authority, "Cookie": cookie, "Origin": origin ?? server.origin.value, "Content-Type": "application/json",
                 "Sec-Fetch-Site": "same-origin"]
        if let csrf { h["X-Doz-CSRF"] = csrf }
        return try RawHTTP.request(port: server.origin.port, method: "POST", path: path, headers: h, body: body)
    }

    /// The fake chat server, planting canaries everywhere a real one could not: in dropped fields, in headers.
    func plantFakeServer() throws {
        let c = Self.canary
        socket = try FakeChatSocket(path: root + "/chat/chat.sock") { a in
            let line = a.head.components(separatedBy: "\r\n")[0]
            let leak: [(String, String)] = [("Set-Cookie", "t=\(c)"), ("X-Chat-Token", c), ("Access-Control-Allow-Origin", "*"), ("Location", "http://x/\(c)")]
            switch line {
            case "GET /api/state HTTP/1.0":
                return FakeChatSocket.answer(200, leak + [("Content-Type", "application/json")],
                    #"{"rooms":{"general":["ada","bot1"]},"archived":[],"participants":[{"name":"ada","kind":"human","identity":"\#(c)"}],"default_room":"general","token_service":"\#(c)","need_token":false,"reactions":[],"version":"v","release":"\#(c)","https_url":"\#(c)","apps":{}}"#)
            case "GET /api/rooms/general/messages?after=3 HTTP/1.0":
                return FakeChatSocket.answer(200, leak + [("X-More", "true")], #"[{"msg_id":"a","seq":4,"content":"hi"}]"#)
            case "GET /api/presence HTTP/1.0":
                return FakeChatSocket.answer(200, leak, #"[{"name":"ada","state":"here"}]"#)
            case "POST /api/rooms/general/messages HTTP/1.0":
                return FakeChatSocket.answer(200, leak, #"{"msg_id":"m1","state":"queued","detail":"","token":"\#(c)"}"#)
            case "POST /api/rooms/locked/messages HTTP/1.0":
                return FakeChatSocket.answer(422, leak, #"{"msg_id":"m2","state":"refused","detail":"room locked is archived"}"#)
            case "GET /files/0123456789abcdef/pic.png HTTP/1.0":
                return FakeChatSocket.answer(200, leak + [("Content-Type", "image/png"), ("Content-Disposition", "inline")], "PNG")
            case "GET /files/0123456789abcdef/page.html HTTP/1.0":
                return FakeChatSocket.answer(200, leak + [("Content-Type", "text/html"), ("Content-Disposition", "inline")], "<script>alert(1)</script>")
            case "GET /files/0123456789abcdef/x.svg HTTP/1.0":
                return FakeChatSocket.answer(200, leak + [("Content-Type", "image/svg+xml")], "<svg onload=alert(1)/>")
            case "GET /api/stream HTTP/1.0":
                return .stream([#"{"kind":"hello","version":"v"}"#, "not json", #"{"kind":"message","room":"general"}"#], hold: true)
            default:
                return FakeChatSocket.answer(404, leak, #"{"error":"not found: \#(c)"}"#.replacingOccurrences(of: c, with: "x"))
            }
        }
    }

    func testChatOffIsSaidAndNothingTurnsItOn() async throws {
        try await start(chatOn: false)
        let (cookie, csrf) = try signIn()
        let st = try get("/api/v1/chat/status", cookie)
        XCTAssertEqual(st.status, 200)
        XCTAssertEqual(try WebJSON.decoder.decode(WebChatStatus.self, from: st.body).state, "off")
        let r = try get("/api/v1/chat/state", cookie)
        XCTAssertEqual(r.status, 503)
        XCTAssertTrue(r.text.contains("chat-off"), r.text)
        XCTAssertEqual(try get("/api/v1/chat/stream", cookie).status, 503)
        // The settings route never sets chat.enabled.
        let s = try post("/api/v1/settings", #"{"key":"chat.enabled","value":true}"#, cookie: cookie, csrf: csrf)
        XCTAssertNotEqual(s.status, 200, s.text)
    }

    func testOnButNotReadyAndTheStatusStates() async throws {
        try await start(chatOn: true)
        let (cookie, _) = try signIn()
        XCTAssertEqual(try WebJSON.decoder.decode(WebChatStatus.self, from: try get("/api/v1/chat/status", cookie).body).state, "no-daemon")
        holdTheDaemonLock()
        XCTAssertEqual(try WebJSON.decoder.decode(WebChatStatus.self, from: try get("/api/v1/chat/status", cookie).body).state, "starting")
        try Data(#"{"enabled":true,"state":"failing","ready":false,"problem":"port 8790 is in use","restarts":5,"bind":"127.0.0.1","pagePort":8790,"linePort":8791}"#.utf8)
            .write(to: URL(fileURLWithPath: root + "/chat/supervisor.json"))
        let f = try WebJSON.decoder.decode(WebChatStatus.self, from: try get("/api/v1/chat/status", cookie).body)
        XCTAssertEqual(f, WebChatStatus(state: "failing", problem: "port 8790 is in use"))
        let r = try get("/api/v1/chat/presence", cookie)
        XCTAssertEqual(r.status, 503)
        XCTAssertTrue(r.text.contains("chat-not-ready"), r.text)
    }

    func testWhatPassesAndNothingLeaks() async throws {
        try await start(chatOn: true)
        try plantFakeServer()
        let (cookie, csrf) = try signIn()
        var answers: [RawResponse] = []
        let state = try get("/api/v1/chat/state", cookie)
        XCTAssertEqual(state.status, 200, state.text)
        answers.append(state)
        let page = try get("/api/v1/chat/rooms/general/messages?after=3", cookie, extra: ["X-Chat-Id": "0f8fad5b-d9cb-469f-a165-70867728950e", "Authorization": "Bearer x"])
        XCTAssertEqual(page.status, 200, page.text)
        XCTAssertEqual(page.header("x-more"), "true", "X-More is copied back")
        answers.append(page)
        answers.append(try get("/api/v1/chat/presence", cookie))
        let sent = try post("/api/v1/chat/rooms/general/messages", #"{"content":"hello @bot1","to":["bot1"]}"#, cookie: cookie, csrf: csrf)
        XCTAssertEqual(sent.status, 200, sent.text)
        XCTAssertEqual(sent.text, #"{"detail":"","msg_id":"m1","state":"queued"}"#)
        answers.append(sent)
        let refused = try post("/api/v1/chat/rooms/locked/messages", #"{"content":"x"}"#, cookie: cookie, csrf: csrf)
        XCTAssertEqual(refused.status, 422)
        XCTAssertTrue(refused.text.contains(#""code":"chat""#) && refused.text.contains("archived"), refused.text)
        answers.append(refused)
        let missing = try get("/api/v1/chat/rooms/nowhere/messages", cookie)
        XCTAssertEqual(missing.status, 404)
        answers.append(missing)
        for a in answers {
            XCTAssertFalse(a.text.contains("dzc_"), a.text)
            for (k, v) in a.headers {
                XCTAssertFalse(v.contains("dzc_"), "\(k): \(v)")
                XCTAssertFalse(k.hasPrefix("access-control-"), k)
                XCTAssertNotEqual(k, "x-chat-token")
                XCTAssertNotEqual(k, "location")
            }
            XCTAssertNil(a.header("set-cookie"))
        }
        // What reached the socket: fixed paths, and none of the browser's own headers.
        for a in socket!.asked {
            let h = a.head.lowercased()
            for never in ["cookie:", "origin:", "x-doz-csrf", "authorization:", "x-chat-id", "sec-fetch", "doz_ui_"] {
                XCTAssertFalse(h.contains(never), "\(never) reached the socket: \(a.head)")
            }
        }
        let postBody = try XCTUnwrap(socket!.asked.first { $0.head.hasPrefix("POST /api/rooms/general/") }?.body)
        XCTAssertEqual(String(decoding: postBody, as: UTF8.self), #"{"content":"hello @bot1","to":["bot1"]}"#)
    }

    func testTheUnsafeRequestChecks() async throws {
        try await start(chatOn: true)
        try plantFakeServer()
        let (cookie, csrf) = try signIn()
        let p = "/api/v1/chat/rooms/general/messages"
        XCTAssertEqual(try post(p, #"{"content":"x"}"#, cookie: cookie, csrf: nil).status, 403, "no CSRF")
        XCTAssertEqual(try post(p, #"{"content":"x"}"#, cookie: cookie, csrf: "wrong-wrong-wrong-wrong-wrong-wrong").status, 403, "a wrong CSRF")
        XCTAssertEqual(try post(p, #"{"content":"x"}"#, cookie: cookie, csrf: csrf, origin: "http://evil.example").status, 403, "a wrong Origin")
        XCTAssertEqual(try post(p, #"{"content":"x","private":true}"#, cookie: cookie, csrf: csrf).status, 400, "strict")
        let big = String(repeating: "a", count: 81 * 1024)
        XCTAssertEqual(try post(p, #"{"content":"\#(big)"}"#, cookie: cookie, csrf: csrf).status, 413, "over the cap")
        let mid = String(repeating: "a", count: 60 * 1024)
        XCTAssertEqual(try post(p, #"{"content":"\#(mid)"}"#, cookie: cookie, csrf: csrf).status, 200, "60 KiB of text is a message")
        XCTAssertEqual(try get("/api/v1/chat/state", "doz_ui_\(server.origin.port)=nobody-nobody-nobody-nobody").status, 401)
        XCTAssertEqual(socket!.asked.filter { $0.head.hasPrefix("POST") }.count, 1, "only the good post reached the socket")
    }

    func testTheFileHeaders() async throws {
        try await start(chatOn: true)
        try plantFakeServer()
        let (cookie, _) = try signIn()
        let png = try get("/api/v1/chat/files/0123456789abcdef/pic.png", cookie)
        XCTAssertEqual(png.status, 200)
        XCTAssertEqual(png.header("content-type"), "image/png")
        XCTAssertNil(png.header("content-disposition"), "a picture is shown")
        for name in ["page.html", "x.svg"] {
            let r = try get("/api/v1/chat/files/0123456789abcdef/\(name)", cookie)
            XCTAssertEqual(r.status, 200)
            XCTAssertEqual(r.header("content-type"), "application/octet-stream", name)
            XCTAssertEqual(r.header("content-disposition"), "attachment; filename=\"\(name)\"")
        }
        for r in [png, try get("/api/v1/chat/files/0123456789abcdef/page.html", cookie)] {
            XCTAssertEqual(r.header("x-content-type-options"), "nosniff")
            XCTAssertEqual(r.header("content-security-policy"), "sandbox; default-src 'none'")
            XCTAssertEqual(r.header("cache-control"), "private, no-store")
            XCTAssertEqual(r.header("cross-origin-resource-policy"), "same-origin")
            XCTAssertNil(r.header("set-cookie"))
        }
        XCTAssertEqual(try get("/api/v1/chat/files/0123456789abcdef/..%2Fsecrets.json", cookie).status, 404, "traversal is no route")
        XCTAssertEqual(try get("/api/v1/chat/files/0123456789abcdef/%2e%2e", cookie).status, 404)
    }

    func testTheStreamRelayAndItsEnds() async throws {
        try await start(chatOn: true)
        try plantFakeServer()
        let (cookie, csrf) = try signIn()
        let headers = ["Host": server.origin.authority, "Cookie": cookie]
        let st = try RawStream(port: server.origin.port, path: "/api/v1/chat/stream", headers: headers)
        let seen = try st.read(until: #""kind":"message""#, seconds: 5)
        XCTAssertTrue(seen.contains("event: chat"), seen)
        let hello = try XCTUnwrap(seen.range(of: #""kind":"hello""#)), msg = try XCTUnwrap(seen.range(of: #""kind":"message""#))
        XCTAssertLessThan(hello.lowerBound, msg.lowerBound, "hello first")
        XCTAssertFalse(seen.contains("not json"), "a line that is not a JSON object with a kind is dropped")
        XCTAssertEqual(socket!.streamsClosed, 0)
        st.close()
        // The browser gone: the upstream is shut, and the server sees the close.
        // Only a failed write tells a server the browser went: the relay's 2 s heartbeat finds it within a few seconds.
        for _ in 0..<100 where socket!.streamsClosed == 0 { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertEqual(socket!.streamsClosed, 1, "closing the browser closes the upstream")
        // Signing out ends a chat stream too, and with it the upstream.
        let st2 = try RawStream(port: server.origin.port, path: "/api/v1/chat/stream", headers: headers)
        _ = try st2.read(until: #""kind":"message""#, seconds: 5)
        let out = try RawHTTP.request(port: server.origin.port, method: "DELETE", path: "/api/v1/session",
                                      headers: headers.merging(["Origin": server.origin.value, "X-Doz-CSRF": csrf]) { $1 })
        XCTAssertEqual(out.status, 204, out.text)
        let ended = try st2.read(until: "session-ended", seconds: 5)
        XCTAssertTrue(ended.contains("event: end"), ended)
        for _ in 0..<50 where socket!.streamsClosed < 2 { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertEqual(socket!.streamsClosed, 2)
        st2.close()
    }

    func testTheUpstreamsEndsReachTheBrowser() async throws {
        try await start(chatOn: true)
        let (cookie, _) = try signIn()
        socket = try FakeChatSocket(path: root + "/chat/chat.sock") { _ in .stream([#"{"kind":"hello"}"#], hold: false) }
        let headers = ["Host": server.origin.authority, "Cookie": cookie]
        let gone = try RawStream(port: server.origin.port, path: "/api/v1/chat/stream", headers: headers)
        XCTAssertTrue(try gone.read(until: "chat-gone", seconds: 5).contains("event: end"), "the server's end: the page reconnects")
        gone.close()
        socket?.stop()
        socket = try FakeChatSocket(path: root + "/chat/chat.sock") { _ in .stream([#"{"kind":"hello"}"#, #"{"kind":"resync"}"#], hold: true) }
        let rs = try RawStream(port: server.origin.port, path: "/api/v1/chat/stream", headers: headers)
        XCTAssertTrue(try rs.read(until: "event: resync", seconds: 5).contains("event: resync"))
        rs.close()
    }

    func testASlowReaderGetsResyncAndNothingGrows() throws {
        root = root ?? "/tmp/dzw-x"
        let lines = (0..<40).map { #"{"kind":"message","n":\#($0)}"# }
        socket = try FakeChatSocket(path: root + "/chat/chat.sock") { _ in .stream(lines, hold: true) }
        let proxy = WebChatProxy(storePath: root, enabled: { true })
        let hub = SSEHub(maxClients: 4, capacity: 4)
        let client = try XCTUnwrap(hub.add(cookie: "c"))
        let handle = ChatOwnerClient.StreamHandle()
        proxy.relay(to: client, hub: hub, handle: handle)
        for _ in 0..<50 where client.end == nil { usleep(100_000) }
        XCTAssertEqual(client.end, .overflow, "a reader four events behind is ended with resync, never buffered")
        handle.cancel()
        for _ in 0..<50 where socket!.streamsClosed == 0 { usleep(100_000) }
        XCTAssertEqual(socket!.streamsClosed, 1, "and its upstream is shut")
    }
}

/// The real `doz chat serve` on an owner's socket in a scratch store (as the daemon starts it), the dashboard in front of it:
/// a post through the dashboard is in the room and on the relayed stream, the person is "here" only while a chat stream is
/// open, and away once the browser's stream is gone.
final class WebChatRealServerTests: XCTestCase {
    var http: WebChatHTTPTests!
    var serverProcess: Process?

    override func setUp() async throws {
        http = WebChatHTTPTests()
        try http.setUpWithError()
    }

    override func tearDown() async throws {
        if let p = serverProcess, p.isRunning { kill(p.processIdentifier, SIGTERM); p.waitUntilExit() }
        try await http.tearDown()
    }

    static func doz() throws -> URL {
        if let p = ProcessInfo.processInfo.environment["DOZ_CHAT_TEST_DOZ"], !p.isEmpty { return URL(fileURLWithPath: p) }
        let u = Bundle(for: WebChatRealServerTests.self).bundleURL.deletingLastPathComponent().appendingPathComponent("doz")
        guard FileManager.default.isExecutableFile(atPath: u.path) else { throw XCTSkip("no doz beside the test bundle; build it first (make build)") }
        return u
    }

    func launch() throws {
        let chat = http.root + "/chat"
        for d in [chat + "/data", http.root + "/home", http.root + "/tmp"] {
            try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let config = #"{"line_port":0,"http_port":0,"data_dir":"\#(chat)/data","default_room":"general","participants":[{"name":"ada","kind":"human","deliver":"web"},{"name":"bot1","kind":"agent"}],"rooms":{"general":["ada","bot1"]},"allow":["127.0.0.1","::1"],"require_tokens":true,"agent_addresses":["127.0.0.0/8","::1"],"secrets_file_only":true,"bind":"127.0.0.1"}"#
        try Data(config.utf8).write(to: URL(fileURLWithPath: chat + "/config.json"))
        let hash = SHA256.hash(data: Data("bot1-token-0123456789".utf8)).map { String(format: "%02x", $0) }.joined()
        FileManager.default.createFile(atPath: chat + "/tokens.json", contents: Data(#"{"version":1,"sha256":{"bot1":"\#(hash)"}}"#.utf8),
                                       attributes: [.posixPermissions: 0o600])
        let p = Process()
        p.executableURL = try Self.doz()
        p.arguments = ["chat", "serve", "--config", chat + "/config.json", "--bind", "127.0.0.1", "--token-hashes", chat + "/tokens.json",
                       "--owner-socket", chat + "/chat.sock", "--supervised"]
        p.environment = ["HOME": http.root + "/home", "TMPDIR": http.root + "/tmp/", "PATH": "/usr/bin:/bin"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        serverProcess = p
        for _ in 0..<100 where (try? ChatOwnerClient(socket: chat + "/chat.sock").request("GET", "/api/state").status) != 200 { usleep(100_000) }
    }

    func humanState() throws -> String? {
        let a = try ChatOwnerClient(socket: http.root + "/chat/chat.sock").request("GET", "/api/presence")
        let list = try JSONSerialization.jsonObject(with: a.body) as? [[String: Any]]
        return list?.first { $0["name"] as? String == "ada" }?["state"] as? String
    }

    func testPostStreamAndPresenceThroughTheDashboard() async throws {
        try launch()
        try await http.start(chatOn: true)
        let (cookie, csrf) = try http.signIn()
        let state = try http.get("/api/v1/chat/state", cookie)
        XCTAssertEqual(state.status, 200, state.text)
        XCTAssertFalse(state.text.contains("token_service") || state.text.contains("need_token"), state.text)
        XCTAssertEqual(try humanState(), "away", "no chat stream: the person is away")
        let st = try RawStream(port: http.server.origin.port, path: "/api/v1/chat/stream", headers: ["Host": http.server.origin.authority, "Cookie": cookie])
        _ = try st.read(until: #""kind":"hello""#, seconds: 5)
        for _ in 0..<30 where try humanState() != "here" { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertEqual(try humanState(), "here", "a chat stream open: here")
        let sent = try http.post("/api/v1/chat/rooms/general/messages", #"{"content":"hello **bot1**"}"#, cookie: cookie, csrf: csrf)
        XCTAssertEqual(sent.status, 200, sent.text)
        let seen = try st.read(until: "hello **bot1**", seconds: 5)
        XCTAssertTrue(seen.contains("event: chat"), seen)
        let page = try http.get("/api/v1/chat/rooms/general/messages?after=0", cookie)
        XCTAssertTrue(page.text.contains("hello **bot1**"), page.text)
        XCTAssertNotNil(page.header("x-more"))
        st.close()
        for _ in 0..<100 where try humanState() != "away" { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertEqual(try humanState(), "away", "the browser gone: the upstream closed, the person away")
    }
}
