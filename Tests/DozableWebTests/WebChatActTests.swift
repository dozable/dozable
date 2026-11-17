import Darwin
import DozableChat
import Foundation
import XCTest
@testable import DozableHost
@testable import DozableWeb

/// Chat in the dashboard, acting: the routes that change something (upload, reactions, edit, delete, reveal, typing) —
/// the closed parse, the strict bodies, `X-Chat-Id` the only header passed upstream and only as a v4 UUID, the upload's
/// checks made from its HEAD before its body is read, nothing token- or path-shaped coming back — and `serve.chat`
/// (off | read | write) for another computer, with every remote write one line in the audit log.
final class WebChatActRouteTests: XCTestCase {
    func route(_ m: WebHTTPMethod, _ t: String) -> WebChatRoute? {
        if case .chat(let c)? = WebRoute.parse(method: m, target: t) { return c }
        return nil
    }
    static let id = "0f8fad5b-d9cb-469f-a165-70867728950e"

    func testTheSliceTwoRoutesParseAndNothingElse() {
        let m = "/api/v1/chat/rooms/room1/messages/\(Self.id)"
        XCTAssertEqual(route(.post, "/api/v1/chat/rooms/room1/reactions"), .react(room: "room1"))
        XCTAssertEqual(route(.post, m + "/edit"), .edit(room: "room1", id: Self.id))
        XCTAssertEqual(route(.post, m + "/delete"), .delete(room: "room1", id: Self.id))
        XCTAssertEqual(route(.post, m + "/reveal"), .reveal(room: "room1", id: Self.id))
        XCTAssertEqual(route(.post, "/api/v1/chat/typing"), .typing)
        XCTAssertEqual(route(.post, "/api/v1/chat/files?name=a.png"), .upload(name: "a.png"))
        XCTAssertEqual(route(.post, "/api/v1/chat/files?name=my%20notes%20(1).pdf"), .upload(name: "my notes (1).pdf"))
        XCTAssertEqual(route(.post, "/api/v1/chat/files?name=a%2Bb.txt"), .upload(name: "a+b.txt"))
        let refused: [(WebHTTPMethod, String)] = [
            (.get, "/api/v1/chat/rooms/room1/reactions"), (.post, "/api/v1/chat/rooms/room1/reactions?x=1"),
            (.get, m + "/edit"), (.post, m + "/pin"), (.post, m + "/edit?x=1"), (.post, m.uppercased() + "/edit"),
            (.post, "/api/v1/chat/rooms/room1/messages/zz/edit"), (.post, "/api/v1/chat/rooms/room1/messages/\(Self.id)0/edit"),
            (.post, "/api/v1/chat/rooms/Room1/messages/\(Self.id)/delete"), (.get, "/api/v1/chat/typing"), (.post, "/api/v1/chat/typing?x=1"),
            (.get, "/api/v1/chat/files?name=a.png"), (.post, "/api/v1/chat/files"), (.post, "/api/v1/chat/files?name="),
            (.post, "/api/v1/chat/files?name=a.png&x=1"), (.post, "/api/v1/chat/files?x=1&name=a.png"), (.post, "/api/v1/chat/files?name=a+b.png"),
            (.post, "/api/v1/chat/files?name=..%2Fx"), (.post, "/api/v1/chat/files?name=%2E%2E"), (.post, "/api/v1/chat/files?name=.hidden"),
            (.post, "/api/v1/chat/files?name=a%2Fb"), (.post, "/api/v1/chat/files?name=a%00b"), (.post, "/api/v1/chat/files?name=a%zz"),
            (.post, "/api/v1/chat/files?name=a;b"), (.post, "/api/v1/chat/files?name=" + String(repeating: "a", count: 121)),
            (.post, "/api/v1/chat/files?name=%3Cscript%3E"), (.post, "/api/v1/chat/reload"), (.post, "/api/v1/chat/agent/send"),
            (.post, "/api/v1/chat/rooms/room1/app"),
        ]
        for (m, t) in refused { XCTAssertNil(WebRoute.parse(method: m, target: t), "\(m) \(t)") }
    }

    func testTheUpstreamTargetsAreFixed() {
        XCTAssertEqual(WebChatRoute.upload(name: "my notes (1)+.pdf").upstreamTarget, "/api/files?name=my%20notes%20%281%29%2B.pdf")
        XCTAssertEqual(WebChatRoute.react(room: "general").upstreamTarget, "/api/rooms/general/reactions")
        XCTAssertEqual(WebChatRoute.edit(room: "general", id: Self.id).upstreamTarget, "/api/rooms/general/messages/\(Self.id)/edit")
        XCTAssertEqual(WebChatRoute.delete(room: "general", id: Self.id).upstreamTarget, "/api/rooms/general/messages/\(Self.id)/delete")
        XCTAssertEqual(WebChatRoute.reveal(room: "general", id: Self.id).upstreamTarget, "/api/rooms/general/messages/\(Self.id)/reveal")
        XCTAssertEqual(WebChatRoute.typing.upstreamTarget, "/api/typing")
        for r in [WebChatRoute.react(room: "r"), .edit(room: "r", id: Self.id), .delete(room: "r", id: Self.id)] { XCTAssertTrue(r.takesActionID) }
        for r in [WebChatRoute.reveal(room: "r", id: Self.id), .typing, .upload(name: "a"), .post(room: "r")] { XCTAssertFalse(r.takesActionID) }
        for r in [WebChatRoute.react(room: "r"), .edit(room: "r", id: Self.id), .delete(room: "r", id: Self.id), .reveal(room: "r", id: Self.id),
                  .typing, .upload(name: "a"), .post(room: "r")] {
            XCTAssertFalse(r.isSafe, "\(r) changes something")
            XCTAssertEqual(WebExposure.kind(.chat(r)), .chat)
        }
    }

    func testTheBodiesAreStrictAndReEncoded() throws {
        XCTAssertEqual(String(decoding: try WebChatProjection.reactBody(Data(#"{"reaction":"like","msg_id":"0f8fad5b"}"#.utf8)), as: UTF8.self),
                       #"{"msg_id":"0f8fad5b","reaction":"like"}"#)
        XCTAssertNoThrow(try WebChatProjection.reactBody(Data(#"{"msg_id":"0f8fad5b","reaction":"👍"}"#.utf8)))
        for bad in [#"{}"#, #"{"msg_id":"0f8fad5b"}"#, #"{"msg_id":"ZZ","reaction":"like"}"#, #"{"msg_id":"0f8fad5b","reaction":""}"#,
                    #"{"msg_id":"0f8fad5b","reaction":"\#(String(repeating: "x", count: 33))"}"#, #"{"msg_id":"0f8fad5b","reaction":"a\nb"}"#,
                    #"{"msg_id":"0f8fad5b","reaction":"like","who":"bot1"}"#, #"{"msg_id":"0f8fad5b","reaction":1}"#] {
            XCTAssertThrowsError(try WebChatProjection.reactBody(Data(bad.utf8)), bad)
        }
        XCTAssertEqual(String(decoding: try WebChatProjection.editBody(Data(#"{"text":"new"}"#.utf8)), as: UTF8.self), #"{"text":"new"}"#)
        for bad in [#"{}"#, #"{"text":1}"#, #"{"text":"x","to":["bot1"]}"#, #"{"text":"\#(String(repeating: "a", count: 64 * 1024 + 1))"}"#] {
            XCTAssertThrowsError(try WebChatProjection.editBody(Data(bad.utf8)))
        }
        XCTAssertEqual(try WebChatProjection.emptyBody(Data()), Data("{}".utf8))
        XCTAssertEqual(try WebChatProjection.emptyBody(Data("{}".utf8)), Data("{}".utf8))
        XCTAssertThrowsError(try WebChatProjection.emptyBody(Data(#"{"who":"bot1"}"#.utf8)))
        // A post with attachments: at most 10 {id}; with one, the text may be empty.
        let one = try WebChatProjection.postBody(Data(#"{"content":"","attachments":[{"id":"0123456789abcdef0123456789abcdef"}]}"#.utf8))
        XCTAssertEqual(String(decoding: one, as: UTF8.self), #"{"attachments":[{"id":"0123456789abcdef0123456789abcdef"}],"content":""}"#)
        let eleven = (0..<11).map { _ in #"{"id":"0123456789abcdef"}"# }.joined(separator: ",")
        for bad in [#"{"content":"","attachments":[]}"#, #"{"content":"x","attachments":[\#(eleven)]}"#,
                    #"{"content":"x","attachments":[{"id":"0123456789abcdef","path":"/etc/passwd"}]}"#,
                    #"{"content":"x","attachments":[{"id":"../x"}]}"#, #"{"content":"x","attachments":{"id":"0123456789abcdef"}}"#] {
            XCTAssertThrowsError(try WebChatProjection.postBody(Data(bad.utf8)), bad)
        }
    }

    func testTheUploadAnswerNeverCarriesThePathOrAnythingElse() throws {
        let up = #"{"id":"0123456789abcdef0123456789abcdef","name":"a b.png","type":"image/png","size":3,"url":"/files/0123456789abcdef0123456789abcdef/a b.png","path":"/Users/someone/store/chat/data/files/x","token":"dzc_CANARY"}"#
        let out = try XCTUnwrap(WebChatProjection.uploaded(Data(up.utf8)))
        let o = try XCTUnwrap(try JSONSerialization.jsonObject(with: out) as? [String: Any])
        XCTAssertEqual(Set(o.keys), ["id", "name", "type", "size", "url"])
        XCTAssertFalse(String(decoding: out, as: UTF8.self).contains("Users"))
        XCTAssertNil(WebChatProjection.uploaded(Data(#"{"id":"0123456789abcdef","name":"a.png","url":"/elsewhere"}"#.utf8)), "the url is the file's own")
        XCTAssertNil(WebChatProjection.uploaded(Data(#"{"id":"x","name":"a.png","url":"/files/x/a.png"}"#.utf8)))
    }

    func testTheLimitsAreTheChatServersOwn() {
        XCTAssertEqual(WebChatProxy.maximumUpload, ChatProtocol.maxFileSize, "the dashboard's upload limit is the chat server's file limit")
        XCTAssertEqual(DozableWebServer.bodyLimit(.chat(.upload(name: "a")), .standard), ChatProtocol.maxFileSize + 1)
        XCTAssertEqual(DozableWebServer.bodyLimit(.chat(.edit(room: "r", id: Self.id)), .standard), 80 * 1024)
        XCTAssertEqual(DozableWebServer.bodyLimit(.chat(.react(room: "r")), .standard), 16 * 1024)
    }

    /// serve.chat: off refuses every chat route to another computer; read lets it read and refuses every change; write is
    /// everything. The Mac's own browser has chat whatever the setting says.
    func testServeChatDecides() {
        let reads: [WebChatRoute] = [.status, .state, .presence, .unread([]), .protocolDescription, .messages(room: "r", after: nil, before: nil, limit: nil),
                                     .stream, .file(id: "0123456789abcdef", name: "a")]
        let writes: [WebChatRoute] = [.post(room: "r"), .upload(name: "a"), .react(room: "r"), .edit(room: "r", id: Self.id),
                                      .delete(room: "r", id: Self.id), .reveal(room: "r", id: Self.id), .typing]
        for secure in [true, false] {
            let remote = WebExposure.Principal.remote(secure: secure)
            for r in reads + writes {
                XCTAssertEqual(WebExposure.decide(.chat(r), remote), .chatRemote, "off is the default")
                XCTAssertEqual(WebExposure.decide(.chat(r), remote, macSessions: .interactive, chat: .off), .chatRemote)
                XCTAssertNil(WebExposure.decide(.chat(r), remote, chat: .write))
                for s in WebExposure.ChatServe.allCases { XCTAssertNil(WebExposure.decide(.chat(r), .mac, chat: s)) }
            }
            for r in reads { XCTAssertNil(WebExposure.decide(.chat(r), remote, chat: .read), "\(r)") }
            for r in writes { XCTAssertEqual(WebExposure.decide(.chat(r), remote, chat: .read), .chatReadOnly, "\(r)") }
        }
        XCTAssertEqual(WebRejection.chatReadOnly.status, 403)
        XCTAssertTrue(WebRejection.chatReadOnly.message.contains("serve.chat write"))
        XCTAssertTrue(WebRejection.chatRemote.message.contains("serve.chat"))
        XCTAssertEqual(WebRejection.chatFileTooLarge.status, 413)
        // The setting: default off, set on this Mac only.
        let d = DozableSettings.definition(SettingKey.serveChat)
        XCTAssertEqual(d?.defaultValue, .string("off"))
        XCTAssertEqual(d?.editableInUI, false, "never set from the dashboard")
        XCTAssertTrue(d?.summary.contains("acts as you in chat, the verified human") == true)
    }
}

/// The acting routes through a real dashboard listener (this Mac's own browser) against `FakeChatSocket`.
final class WebChatActHTTPTests: XCTestCase {
    var http: WebChatHTTPTests!
    static let canary = "dzc_CANARYvalue0123456789abcdef"
    static let id = WebChatActRouteTests.id

    override func setUp() async throws {
        http = WebChatHTTPTests()
        try http.setUpWithError()
    }
    override func tearDown() async throws { try await http.tearDown() }

    func plant() throws {
        let c = Self.canary
        http.socket = try FakeChatSocket(path: http.root + "/chat/chat.sock") { a in
            let line = a.head.components(separatedBy: "\r\n")[0]
            let leak: [(String, String)] = [("Set-Cookie", "t=\(c)"), ("X-Chat-Token", c), ("Access-Control-Allow-Origin", "*")]
            if line.hasPrefix("POST /api/files?name=") {
                return FakeChatSocket.answer(200, leak, #"{"id":"0123456789abcdef0123456789abcdef","name":"a b.png","type":"image/png","size":\#(a.body.count),"url":"/files/0123456789abcdef0123456789abcdef/a b.png","path":"/Users/someone/\#(c)/files"}"#)
            }
            switch line {
            case "POST /api/rooms/general/reactions HTTP/1.0", "POST /api/rooms/general/messages/\(Self.id)/edit HTTP/1.0",
                 "POST /api/rooms/general/messages/\(Self.id)/delete HTTP/1.0":
                return FakeChatSocket.answer(200, leak, #"{"state":"done","detail":"","token":"\#(c)"}"#)
            case "POST /api/rooms/general/messages/\(Self.id)/reveal HTTP/1.0":
                return FakeChatSocket.answer(200, leak, #"{"msg_id":"\#(Self.id)","from":"bot1","to":["bot2"],"content":"psst","private":true,"revealed":true}"#)
            case "POST /api/typing HTTP/1.0":
                return FakeChatSocket.answer(204, leak, "")
            default:
                return FakeChatSocket.answer(404, leak, #"{"error":"not found"}"#)
            }
        }
    }

    func post(_ path: String, _ body: String?, _ cookie: String, _ csrf: String?, type: String = "application/json", extra: [String: String] = [:]) throws -> RawResponse {
        var h = ["Host": http.server.origin.authority, "Cookie": cookie, "Origin": http.server.origin.value, "Content-Type": type, "Sec-Fetch-Site": "same-origin"]
        if let csrf { h["X-Doz-CSRF"] = csrf }
        for (k, v) in extra { h[k] = v }
        return try RawHTTP.request(port: http.server.origin.port, method: "POST", path: path, headers: h, body: body)
    }

    /// The head alone, a body announced and never sent: an answer within seconds proves the body was not waited for.
    func headOnly(_ path: String, contentLength: Int, _ headers: [String: String]) throws -> RawResponse {
        let fd = try RawHTTP.connect(port: http.server.origin.port)
        defer { close(fd) }
        var tv = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var s = "POST \(path) HTTP/1.1\r\n"
        for (k, v) in headers { s += "\(k): \(v)\r\n" }
        s += "Content-Length: \(contentLength)\r\n\r\n"
        let d = Data(s.utf8)
        _ = d.withUnsafeBytes { write(fd, $0.baseAddress, d.count) }
        var all = Data(), buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            all.append(contentsOf: buf[0..<n])
        }
        return try RawHTTP.parse(all, method: "POST")
    }

    func testTheActionsCarryOnlyAValidChatIdAndNothingLeaks() async throws {
        try await http.start(chatOn: true)
        try plant()
        let (cookie, csrf) = try http.signIn()
        let m = "/api/v1/chat/rooms/general/messages/\(Self.id)"
        let react = "/api/v1/chat/rooms/general/reactions", body = #"{"msg_id":"\#(Self.id)","reaction":"like"}"#
        // X-Chat-Id is required on a reaction, an edit and a delete, as a v4 UUID.
        XCTAssertEqual(try post(react, body, cookie, csrf).status, 400, "no X-Chat-Id")
        XCTAssertEqual(try post(react, body, cookie, csrf, extra: ["X-Chat-Id": "0f8fad5b-d9cb-169f-a165-70867728950e"]).status, 400, "not v4")
        XCTAssertEqual(try post(react, body, cookie, csrf, extra: ["X-Chat-Id": "x\r\nX-Chat-Token: y"]).status, 400)
        XCTAssertEqual(try post(m + "/delete", "{}", cookie, csrf).status, 400, "no X-Chat-Id")
        XCTAssertEqual(try post(react, body, cookie, nil, extra: ["X-Chat-Id": Self.id]).status, 403, "no CSRF")
        XCTAssertEqual(try post(react, body, cookie, csrf, extra: ["X-Chat-Id": Self.id, "Origin": "http://evil.example"]).status, 403, "a wrong Origin")
        XCTAssertEqual(try post(react, body, cookie, csrf, type: "text/plain", extra: ["X-Chat-Id": Self.id]).status, 415)
        XCTAssertEqual(http.socket!.asked.count, 0, "nothing refused reached the socket")
        let actionID = "3b241101-e2bb-4255-8caf-4136c566a962"
        var answers: [RawResponse] = []
        let ok: [(String, String?)] = [(react, body), (m + "/edit", #"{"text":"new **text**"}"#), (m + "/delete", "{}"), (m + "/delete", nil)]
        for (p, b) in ok {
            let r = try post(p, b, cookie, csrf, extra: ["X-Chat-Id": actionID, "Authorization": "Bearer x", "X-Chat-Token": "planted"])
            XCTAssertEqual(r.status, 200, "\(p): \(r.text)")
            XCTAssertEqual(r.text, #"{"detail":"","state":"done"}"#)
            answers.append(r)
        }
        let rev = try post(m + "/reveal", "{}", cookie, csrf)
        XCTAssertEqual(rev.status, 200, rev.text)
        XCTAssertTrue(rev.text.contains("psst"))
        answers.append(rev)
        let typing = try post("/api/v1/chat/typing", nil, cookie, csrf)
        XCTAssertEqual(typing.status, 204, typing.text)
        answers.append(typing)
        for a in answers {
            XCTAssertFalse(a.text.contains("dzc_"), a.text)
            for (k, v) in a.headers {
                XCTAssertFalse(v.contains("dzc_"), "\(k): \(v)")
                XCTAssertFalse(k.hasPrefix("access-control-"))
                XCTAssertNotEqual(k, "x-chat-token")
            }
        }
        // Upstream: the fixed paths, X-Chat-Id exactly as given on the calls done once — and no other header of the browser's.
        for a in http.socket!.asked {
            let h = a.head.lowercased()
            for never in ["cookie:", "origin:", "x-doz-csrf", "authorization:", "x-chat-token", "sec-fetch", "planted"] {
                XCTAssertFalse(h.contains(never), "\(never) reached the socket: \(a.head)")
            }
            let once = a.head.hasPrefix("POST /api/rooms/general/reactions") || a.head.contains("/edit ") || a.head.contains("/delete ")
            XCTAssertEqual(h.contains("x-chat-id: \(actionID)"), once, a.head)
        }
        let edit = try XCTUnwrap(http.socket!.asked.first { $0.head.contains("/edit ") })
        XCTAssertEqual(String(decoding: edit.body, as: UTF8.self), #"{"text":"new **text**"}"#)
    }

    func testTheUploadIsCheckedFromItsHeadBeforeItsBodyIsRead() async throws {
        try await http.start(chatOn: true)
        try plant()
        let (cookie, csrf) = try http.signIn()
        let s = http.server!
        let base = ["Host": s.origin.authority, "Cookie": cookie, "Origin": s.origin.value, "Content-Type": "application/octet-stream",
                    "Sec-Fetch-Site": "same-origin", "X-Doz-CSRF": csrf]
        let path = "/api/v1/chat/files?name=a%20b.png"
        // Each refusal answers from the head alone (the 1 MiB body announced is never sent).
        var noCSRF = base; noCSRF["X-Doz-CSRF"] = nil
        XCTAssertEqual(try headOnly(path, contentLength: 1 << 20, noCSRF).status, 403, "no CSRF")
        var wrong = base; wrong["X-Doz-CSRF"] = "wrong-wrong-wrong-wrong-wrong-wrong"
        XCTAssertEqual(try headOnly(path, contentLength: 1 << 20, wrong).status, 403)
        var evil = base; evil["Origin"] = "http://evil.example"
        XCTAssertEqual(try headOnly(path, contentLength: 1 << 20, evil).status, 403, "a wrong Origin")
        var noOrigin = base; noOrigin["Origin"] = nil
        XCTAssertEqual(try headOnly(path, contentLength: 1 << 20, noOrigin).status, 403, "no Origin")
        var nobody = base; nobody["Cookie"] = "doz_ui_\(s.origin.port)=nobody-nobody-nobody-nobody"
        XCTAssertEqual(try headOnly(path, contentLength: 1 << 20, nobody).status, 401, "not signed in")
        var form = base; form["Content-Type"] = "multipart/form-data; boundary=x"
        XCTAssertEqual(try headOnly(path, contentLength: 1 << 20, form).status, 415, "never a form")
        let big = try headOnly(path, contentLength: ChatProtocol.maxFileSize + 1, base)
        XCTAssertEqual(big.status, 413, "over the chat server's limit, said before a byte is read")
        XCTAssertTrue(big.text.contains("chat-file-too-large") && big.text.contains("20 MB"), big.text)
        XCTAssertEqual(http.socket!.asked.count, 0, "nothing refused reached the socket")
        // A good one: the bytes go upstream as they are, with a cleaned name in a fixed path; the answer has no path.
        let ok = try post(path, "PNGDATA", cookie, csrf, type: "application/octet-stream")
        XCTAssertEqual(ok.status, 200, ok.text)
        let o = try XCTUnwrap(try JSONSerialization.jsonObject(with: ok.body) as? [String: Any])
        XCTAssertEqual(Set(o.keys), ["id", "name", "type", "size", "url"])
        XCTAssertFalse(ok.text.contains("dzc_") || ok.text.contains("Users"), ok.text)
        let up = try XCTUnwrap(http.socket!.asked.first)
        XCTAssertTrue(up.head.hasPrefix("POST /api/files?name=a%20b.png HTTP/1.0"), up.head)
        XCTAssertTrue(up.head.lowercased().contains("content-type: application/octet-stream"))
        XCTAssertEqual(up.body, Data("PNGDATA".utf8))
        XCTAssertEqual(try post(path, "", cookie, csrf, type: "application/octet-stream").status, 400, "an empty file")
    }

    func testTheStatusSaysThisBrowserMayWrite() async throws {
        try await http.start(chatOn: true)
        try plant()
        http.holdTheDaemonLock()
        try Data(#"{"enabled":true,"state":"running","ready":true,"bind":"127.0.0.1","pagePort":8790,"linePort":8791,"restarts":0}"#.utf8)
            .write(to: URL(fileURLWithPath: http.root + "/chat/supervisor.json"))
        let (cookie, _) = try http.signIn()
        let st = try WebJSON.decoder.decode(WebChatStatus.self, from: try http.get("/api/v1/chat/status", cookie).body)
        XCTAssertEqual(st, WebChatStatus(state: "running", access: "write"))
    }
}

/// Another computer (the LAN option) under serve.chat.
final class WebChatServeTests: XCTestCase {
    var server: DozableWebServer!
    var serveTask: Task<Void, Error>!
    var state: WebServeState!
    var socket: FakeChatSocket?
    var lockFD: Int32 = -1
    let fake = FakeData()
    var root: String!
    let capability = try! WebBootstrapCapability(testingValue: "mac-link-capability-708-AAAAAAAAAAAAAAAA")

    override func setUpWithError() throws {
        root = "/tmp/dzr-\(getpid())-\(UUID().uuidString.prefix(6))"
        for d in [root!, root + "/chat", root + "/xdg/doz", root + "/serve"] {
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

    var auditFile: URL { URL(fileURLWithPath: root + "/serve/audit.jsonl") }

    func start(chat: String?) async throws {
        var toml = "[chat]\nenabled = true\n"
        if let chat { toml += "\n[serve]\nchat = \"\(chat)\"\n" }
        try toml.write(toFile: root + "/xdg/doz/doz.toml", atomically: true, encoding: .utf8)
        state = WebServeState(config: WebServeConfig(port: 0, bind: .loopback, advertise: false), names: WebMacNames(localHostName: "testmac", hostName: nil),
                              devices: WebDeviceStore(file: URL(fileURLWithPath: root + "/serve/devices.json")),
                              audit: WebServeAudit(file: auditFile),
                              interfaces: { [WebInterfaceAddress(name: "lo0", address: WebIP("127.0.0.1")!, prefix: 8)] })
        server = try await DozableWebServer.bindServe(data: fake, assets: try WebAssets.load(), version: "test", limits: .standard,
                                                    settings: WebSettingsStore(environment: ["XDG_CONFIG_HOME": root + "/xdg"]), serve: state,
                                                    capability: capability, pollInterval: .milliseconds(200),
                                                    sessionsFile: URL(fileURLWithPath: root + "/serve/ui.sessions"),
                                                    revokedFile: URL(fileURLWithPath: root + "/serve/ui.revoked"))
        let s = server!
        serveTask = Task { try await s.run() }
        socket = try FakeChatSocket(path: root + "/chat/chat.sock") { a in
            let line = a.head.components(separatedBy: "\r\n")[0]
            if line.hasPrefix("POST /api/files") {
                return FakeChatSocket.answer(200, [], #"{"id":"0123456789abcdef","name":"a.png","type":"image/png","size":3,"url":"/files/0123456789abcdef/a.png"}"#)
            }
            if line.hasPrefix("POST /api/rooms/general/messages ") { return FakeChatSocket.answer(200, [], #"{"msg_id":"m1","state":"queued","detail":""}"#) }
            if line.hasPrefix("POST ") { return FakeChatSocket.answer(200, [], #"{"state":"done","detail":""}"#) }
            if line.hasPrefix("GET /api/state ") { return FakeChatSocket.answer(200, [], #"{"rooms":{"general":["ada"]},"participants":[{"name":"ada","kind":"human"}]}"#) }
            return FakeChatSocket.answer(200, [], "[]")
        }
        lockFD = open(root + "/daemon.lock", O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        XCTAssertEqual(flock(lockFD, LOCK_EX | LOCK_NB), 0)
        try Data(#"{"enabled":true,"state":"running","ready":true,"bind":"127.0.0.1","pagePort":8790,"linePort":8791,"restarts":0}"#.utf8)
            .write(to: URL(fileURLWithPath: root + "/chat/supervisor.json"))
    }

    var port: Int { state.port }
    var own: String { "http://localhost:\(port)" }

    func req(_ path: String, _ headers: [String: String] = [:], method: String = "GET", body: String? = nil) throws -> RawResponse {
        var h = ["Host": "localhost:\(port)"]
        for (k, v) in headers { h[k] = v }
        return try RawHTTP.request(port: port, method: method, path: path, headers: h, body: body)
    }

    func admit() async throws -> (String, String) {
        let inv = await server.share(by: "the Mac")
        let r = try req("/api/v1/session", ["Origin": own, "Authorization": "Bearer \(inv.testToken)"], method: "POST")
        XCTAssertEqual(r.status, 200, r.text)
        let set = try XCTUnwrap(r.header("set-cookie"))
        let csrf = try XCTUnwrap((try JSONSerialization.jsonObject(with: r.body) as? [String: Any])?["csrf"] as? String)
        return (String(set.split(separator: ";")[0]), csrf)
    }

    func writes(_ cookie: String, _ csrf: String) throws -> [(String, RawResponse)] {
        let id = WebChatActRouteTests.id, m = "/api/v1/chat/rooms/general/messages/\(id)"
        let h = ["Cookie": cookie, "Origin": own, "X-Doz-CSRF": csrf, "Content-Type": "application/json", "X-Chat-Id": "3b241101-e2bb-4255-8caf-4136c566a962"]
        var out: [(String, RawResponse)] = []
        out.append(("post", try req("/api/v1/chat/rooms/general/messages", h, method: "POST", body: #"{"content":"a secret plan"}"#)))
        out.append(("react", try req("/api/v1/chat/rooms/general/reactions", h, method: "POST", body: #"{"msg_id":"\#(id)","reaction":"like"}"#)))
        out.append(("edit", try req(m + "/edit", h, method: "POST", body: #"{"text":"a secret edit"}"#)))
        out.append(("delete", try req(m + "/delete", h, method: "POST", body: "{}")))
        out.append(("reveal", try req(m + "/reveal", h, method: "POST", body: "{}")))
        out.append(("typing", try req("/api/v1/chat/typing", h, method: "POST")))
        var u = h; u["Content-Type"] = "application/octet-stream"
        out.append(("upload", try req("/api/v1/chat/files?name=a.png", u, method: "POST", body: "PNG")))
        return out
    }

    func testOffIsTheDefaultAndGivesNothing() async throws {
        try await start(chat: nil)
        let (cookie, csrf) = try await admit()
        for p in ["/api/v1/chat/status", "/api/v1/chat/state", "/api/v1/chat/stream"] {
            let r = try req(p, ["Cookie": cookie])
            XCTAssertEqual(r.status, 403, p)
            XCTAssertTrue(r.text.contains("chat-remote"), r.text)
        }
        for (name, r) in try writes(cookie, csrf) {
            XCTAssertEqual(r.status, 403, name)
            XCTAssertTrue(r.text.contains("chat-remote"), "\(name): \(r.text)")
        }
        XCTAssertEqual(socket!.asked.count, 0, "nothing reached the chat server")
    }

    func testReadReadsAndChangesNothing() async throws {
        try await start(chat: "read")
        let (cookie, csrf) = try await admit()
        let st = try req("/api/v1/chat/status", ["Cookie": cookie])
        XCTAssertEqual(st.status, 200, st.text)
        XCTAssertEqual(try WebJSON.decoder.decode(WebChatStatus.self, from: st.body), WebChatStatus(state: "running", access: "read"),
                       "the page disables its composer")
        XCTAssertEqual(try req("/api/v1/chat/state", ["Cookie": cookie]).status, 200)
        XCTAssertEqual(try req("/api/v1/chat/rooms/general/messages", ["Cookie": cookie]).status, 200)
        for (name, r) in try writes(cookie, csrf) {
            XCTAssertEqual(r.status, 403, name)
            XCTAssertTrue(r.text.contains("chat-read-only"), "\(name): \(r.text)")
        }
        XCTAssertFalse(socket!.asked.contains { $0.head.hasPrefix("POST") }, "no change reached the chat server")
    }

    func testWriteActsAndEachRemoteWriteIsOneAuditLineWithoutContent() async throws {
        try await start(chat: "write")
        let (cookie, csrf) = try await admit()
        let st = try WebJSON.decoder.decode(WebChatStatus.self, from: try req("/api/v1/chat/status", ["Cookie": cookie]).body)
        XCTAssertEqual(st.access, "write")
        let results = try writes(cookie, csrf)
        for (name, r) in results { XCTAssertLessThan(r.status, 300, "\(name): \(r.text)") }
        let lines = WebServeAudit.recent(auditFile, limit: 200).filter { $0.kind == "change" && ($0.route ?? "").hasPrefix("chat-") }
        XCTAssertEqual(lines.map { $0.route ?? "" }.sorted(), results.map { "chat-" + $0.0 }.sorted(), "one line per remote write, naming the call")
        XCTAssertTrue(lines.allSatisfy { $0.device != nil && $0.outcome == "ok" })
        let raw = (try? String(contentsOf: auditFile, encoding: .utf8)) ?? ""
        XCTAssertFalse(raw.contains("secret") || raw.contains("PNG") || raw.contains("like"), "never what was said: \(raw)")
    }
}

/// The acting routes against the REAL `doz chat serve` (an owner's socket in a scratch store): an upload, a post that names
/// it, a reaction, an edit and a delete (each with its X-Chat-Id, done once), typing, and the file served back.
final class WebChatActRealServerTests: XCTestCase {
    var real: WebChatRealServerTests!

    override func setUp() async throws {
        real = WebChatRealServerTests()
        try await real.setUp()
    }
    override func tearDown() async throws { try await real.tearDown() }

    func testUploadPostReactEditDeleteThroughTheDashboard() async throws {
        try real.launch()
        let http = real.http!
        try await http.start(chatOn: true)
        let (cookie, csrf) = try http.signIn()
        let s = http.server!
        func post(_ path: String, _ body: String?, type: String = "application/json", id: String? = nil) throws -> RawResponse {
            var h = ["Host": s.origin.authority, "Cookie": cookie, "Origin": s.origin.value, "Content-Type": type, "X-Doz-CSRF": csrf, "Sec-Fetch-Site": "same-origin"]
            if let id { h["X-Chat-Id"] = id }
            return try RawHTTP.request(port: s.origin.port, method: "POST", path: path, headers: h, body: body)
        }
        let up = try post("/api/v1/chat/files?name=notes%20(1).txt", "hello file", type: "application/octet-stream")
        XCTAssertEqual(up.status, 200, up.text)
        let file = try XCTUnwrap(try JSONSerialization.jsonObject(with: up.body) as? [String: Any])
        let fid = try XCTUnwrap(file["id"] as? String)
        XCTAssertNil(file["path"], "never the server's folder")
        let sent = try post("/api/v1/chat/rooms/general/messages", #"{"content":"see attached","attachments":[{"id":"\#(fid)"}]}"#)
        XCTAssertEqual(sent.status, 200, sent.text)
        let mid = try XCTUnwrap((try JSONSerialization.jsonObject(with: sent.body) as? [String: Any])?["msg_id"] as? String)
        let got = try http.get("/api/v1/chat/files/\(fid)/notes%20(1).txt", cookie)
        XCTAssertEqual(got.status, 200)
        XCTAssertEqual(got.text, "hello file")
        XCTAssertEqual(got.header("content-disposition"), "attachment; filename=\"notes (1).txt\"")
        let once = UUID().uuidString.lowercased()
        let reacted = try post("/api/v1/chat/rooms/general/reactions", #"{"msg_id":"\#(mid)","reaction":"like"}"#, id: once)
        XCTAssertEqual(reacted.status, 200, reacted.text)
        XCTAssertEqual(try post("/api/v1/chat/rooms/general/reactions", #"{"msg_id":"\#(mid)","reaction":"like"}"#, id: once).status, 200,
                       "the same X-Chat-Id again: done once (the reaction is not taken off)")
        let edited = try post("/api/v1/chat/rooms/general/messages/\(mid)/edit", #"{"text":"see attached, edited"}"#, id: UUID().uuidString.lowercased())
        XCTAssertEqual(edited.status, 200, edited.text)
        XCTAssertEqual(try post("/api/v1/chat/typing", nil).status, 204)
        var page = try http.get("/api/v1/chat/rooms/general/messages?after=0", cookie)
        let m = try XCTUnwrap((try JSONSerialization.jsonObject(with: page.body) as? [[String: Any]])?.first { $0["msg_id"] as? String == mid })
        XCTAssertEqual(m["content"] as? String, "see attached, edited")
        XCTAssertEqual((m["reactions"] as? [[String: Any]])?.count, 1, page.text)
        XCTAssertEqual((m["attachments"] as? [[String: Any]])?.first?["id"] as? String, fid)
        let deleted = try post("/api/v1/chat/rooms/general/messages/\(mid)/delete", "{}", id: UUID().uuidString.lowercased())
        XCTAssertEqual(deleted.status, 200, deleted.text)
        page = try http.get("/api/v1/chat/rooms/general/messages?after=0", cookie)
        XCTAssertFalse(page.text.contains("see attached"), page.text)
    }
}
