import Darwin
import DozableChat
import Foundation
import XCTest

/// Posting and reading, in-process with neutral names: the live stream (its events, its resync, its framing over a real
/// listener), polling (receive, ack, redelivery, never twice), edit and delete once per id, unread, direct messages as
/// stubs, presence, /avatar and /session.
final class ChatPostingAndReadingTests: XCTestCase {
    static let pollToken = "bot3-token-0123456789abcdef"
    static let humanToken = "ada-token-0123456789abcdef"

    var dataDir = ""

    func core(requireTokens: Bool = false, sessionsDir: String? = nil) throws -> ChatServerCore {
        dataDir = FileManager.default.temporaryDirectory.appendingPathComponent("chat-posting-\(UUID().uuidString)").path
        addTeardownBlock { [dir = dataDir] in try? FileManager.default.removeItem(atPath: dir) }
        let json = """
            {"data_dir": "\(dataDir)", "default_room": "room1", "secrets_file_only": true, "require_tokens": \(requireTokens),
             "test_owned_addresses": ["127.0.0.1"],
             "participants": [{"name": "ada", "kind": "human", "deliver": "web"},
                              {"name": "bot1", "kind": "grok-bot", "deliver": "webhook", "webhook": "bot1"},
                              {"name": "bot3", "kind": "grok-bot"}],
             "rooms": {"room1": ["ada", "bot1", "bot3"], "room2": ["bot1", "bot3"]}}
            """
        let c = try ChatConfig.parse(Data(json.utf8))
        try c.check()
        let sec = try ChatSecrets.parse(Data(#"{"version": 1, "tokens": {"ada": "\#(Self.humanToken)", "bot3": "\#(Self.pollToken)"}}"#.utf8))
        let core = ChatServerCore(config: c, secrets: sec, release: "1.2.3",
                                  sessionsDir: sessionsDir ?? (dataDir as NSString).appendingPathComponent("no-sessions"))
        core.load()
        return core
    }

    func req(_ method: String, _ target: String, _ body: String = "", headers: [String: String] = [:]) -> ChatHTTPRequest {
        ChatHTTPRequest(method: method, target: target, headers: headers, body: Array(body.utf8), remoteIP: "127.0.0.1")
    }

    func json(_ r: ChatHTTPResponse) throws -> JValue { try ChatJSON.parse(r.body) }

    /// The human posts from the page; the msg_id.
    @discardableResult
    func humanSays(_ h: ChatPageHandler, _ room: String, _ text: String) throws -> String {
        let id = chatNewID()
        let r = h.handle(req("POST", "/api/rooms/\(room)/messages", #"{"content": "\#(text)", "msg_id": "\#(id)"}"#))
        XCTAssertEqual(r.status, 200, r.text)
        return id
    }

    func states(_ core: ChatServerCore, _ room: String, _ id: String, for who: String) throws -> [String] {
        try core.messagePage(room: room, after: 0, before: 0, limit: 500, viewer: "").messages.first { $0.msgID == id }?
            .states.filter { $0.recipient == who }.map(\.state) ?? []
    }

    // MARK: the stream

    func testAPostReachesTheStreamAsAMessageAndThenItsStates() async throws {
        let core = try core()
        let h = ChatPageHandler(core: core)
        let open = h.handle(req("GET", "/api/stream"))
        XCTAssertEqual(open.header("Content-Type"), "text/event-stream")
        XCTAssertEqual(open.header("Cache-Control"), "no-cache")
        XCTAssertEqual(open.text, #"data: {"kind":"hello","version":"\#(ChatServerCore.pageVersion)"}"# + "\n\n")
        let sub = try XCTUnwrap(open.stream)
        XCTAssertEqual(core.viewers, 1)
        let id = try humanSays(h, "room1", "hello @bot1")
        guard case .event(let first) = await sub.next() else { return XCTFail("no event") }
        XCTAssertEqual(first.kind, "message")
        XCTAssertEqual(first.room, "room1")
        XCTAssertEqual(first.message?.msgID, id)
        XCTAssertEqual(first.message?.mentions, ["bot1"])
        let frame = String(decoding: first.frame, as: UTF8.self)
        XCTAssertTrue(frame.hasPrefix(#"data: {"kind":"message","room":"room1","message":{"seq":"#), frame)
        XCTAssertTrue(frame.hasSuffix("}\n\n"))
        guard case .event(let second) = await sub.next() else { return XCTFail("no state event") }
        XCTAssertEqual(second.kind, "state")
        XCTAssertEqual(second.state?.msgID, id)
        // nothing of a room the human is not in
        let line = ChatLine.post(room: "room2", "between bots")
        XCTAssertEqual(core.post(line, sender: "bot3").state, "queued")
        let reload = h.handle(req("POST", "/api/reload"))
        XCTAssertEqual(try json(reload).field("pages")?.intValue, 1)
        while case .event(let e) = await sub.next() {
            XCTAssertNotEqual(e.room, "room2", "an event of a room without the human")
            if e.kind == "reload" { XCTAssertEqual(String(decoding: e.frame, as: UTF8.self), "data: {\"kind\":\"reload\",\"room\":\"\"}\n\n"); break }
        }
        sub.cancel()
        core.unsubscribe(sub)
        XCTAssertEqual(core.viewers, 0)
    }

    func testAStreamThatFallsBehindGetsWhatWasQueuedThenResync() async throws {
        let core = try core()
        let h = ChatPageHandler(core: core)
        let sub = try XCTUnwrap(h.handle(req("GET", "/api/stream")).stream)
        for i in 0..<40 { XCTAssertEqual(core.post(.post(room: "room1", "m\(i)"), sender: "bot3").state, "queued") }
        XCTAssertEqual(core.viewers, 0, "a subscriber whose queue filled is dropped")
        var n = 0
        loop: while true {
            switch await sub.next() {
            case .event: n += 1
            case .resync: break loop
            case .end: return XCTFail("ended without resync")
            }
        }
        XCTAssertEqual(n, ChatSubscriber.queueSize, "every event that was queued comes first")
        guard case .end = await sub.next() else { return XCTFail("the stream goes on after resync") }
    }

    func testTheStreamOverARealListenerAndACallerThatGoesAway() async throws {
        let core = try core()
        let l = try await ChatListeners.bind(core: core, host: "127.0.0.1", linePort: 0, pagePort: 0, log: .none)
        let serving = Task { await l.serve() }
        defer { l.close(); serving.cancel() }
        let fd = try Self.connect(port: l.pagePort)
        Self.send(fd, "GET /api/stream HTTP/1.1\r\nHost: x\r\n\r\n")
        var got = try Self.read(fd, until: #"data: {"kind":"hello","version":"\#(ChatServerCore.pageVersion)"}"#)
        XCTAssertTrue(got.contains("Content-Type: text/event-stream"), got)
        XCTAssertTrue(got.lowercased().contains("transfer-encoding: chunked"), got)
        let id = try humanSays(ChatPageHandler(core: core), "room1", "over the wire")
        got = try Self.read(fd, until: id)
        XCTAssertTrue(got.contains(#"data: {"kind":"message","room":"room1""#), got)
        close(fd)
        let deadline = Date().addingTimeInterval(5)
        while core.viewers > 0 && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(core.viewers, 0, "a caller that closes is no longer a page")
    }

    // MARK: polling

    func testAParticipantWithNoDeliverValuePollsAcksAndIsHandedEachMessageOnce() throws {
        let core = try core()
        let h = ChatPageHandler(core: core)
        let auth = ["authorization": "Bearer " + Self.pollToken]
        let id = try humanSays(h, "room1", "@bot3 have a look")
        XCTAssertEqual(try states(core, "room1", id, for: "bot3"), ["queued"], "it waits, never failed")
        let first = h.handle(req("GET", "/agent/receive?ack=1", headers: auth))
        XCTAssertEqual(first.status, 200, first.text)
        let items = try json(first).field("messages")?.arrayValue ?? []
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.field("delivery")?.stringValue, id)
        XCTAssertEqual(items.first?.field("addressed_to_you"), .bool(true))
        XCTAssertNil(items.first?.field("redelivered"))
        XCTAssertEqual(try json(first).field("protocol_version")?.stringValue, ChatProtocol.version)
        XCTAssertEqual(try states(core, "room1", id, for: "bot3"), ["queued", "woken"])
        XCTAssertEqual(try json(h.handle(req("GET", "/agent/receive?ack=1", headers: auth))).field("messages")?.arrayValue?.count, 0,
                       "not handed over again at once")
        let again = try json(h.handle(req("GET", "/agent/receive?ack=1&redeliver=1", headers: auth))).field("messages")?.arrayValue ?? []
        XCTAssertEqual(again.first?.field("redelivered"), .bool(true))
        let ack = h.handle(req("POST", "/agent/ack", #"{"acks": [{"room": "room1", "msg_id": "\#(id)", "delivery": ""}]}"#, headers: auth))
        XCTAssertEqual(try json(ack).field("acked")?.intValue, 1)
        XCTAssertEqual(try states(core, "room1", id, for: "bot3"), ["queued", "woken", "delivered"])
        // the human is refused with 403, a webhook participant with 409
        let human = h.handle(req("GET", "/agent/receive", headers: ["authorization": "Bearer " + Self.humanToken]))
        XCTAssertEqual(human.status, 403)
        XCTAssertEqual(try json(human).field("error")?.stringValue, "ada is not a registered session; it is delivered to another way")
        XCTAssertEqual(core.mayPoll("bot1")?.status, 409)
    }

    func testAReceiveThatWaitsIsWokenByAPost() async throws {
        let core = try core()
        let h = ChatPageHandler(core: core)
        let r = h.handle(req("GET", "/agent/receive?wait=10", headers: ["authorization": "Bearer " + Self.pollToken]))
        let poll = try XCTUnwrap(r.poll, "nothing waits, so it waits")
        let started = Date()
        async let answer = poll.finish()
        try await Task.sleep(nanoseconds: 200_000_000)
        let id = try humanSays(h, "room1", "wake up")
        let items = try ChatJSON.parse((await answer).body).field("messages")?.arrayValue ?? []
        XCTAssertEqual(items.first?.field("msg_id")?.stringValue, id)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "woken by the post, not by the end of the wait")
        XCTAssertEqual(try states(core, "room1", id, for: "bot3"), ["queued", "delivered"], "without ack the hand-over is the delivery")
    }

    // MARK: edit, delete, once

    func testEditAndDeleteFromThePageAreDoneOncePerID() throws {
        let core = try core()
        let h = ChatPageHandler(core: core)
        let id = try humanSays(h, "room1", "first words")
        let key = chatNewID()
        func edit(_ text: String, _ k: String) -> ChatHTTPResponse {
            h.handle(req("POST", "/api/rooms/room1/messages/\(id)/edit", #"{"text": "\#(text)"}"#, headers: ["x-chat-id": k]))
        }
        XCTAssertEqual(edit("second words", key).text, #"{"detail":"","state":"edited"}"# + "\n")
        XCTAssertEqual(edit("third words", key).text, #"{"detail":"already done: edited","state":"duplicate"}"# + "\n")
        XCTAssertEqual(try core.messagePage(room: "room1", after: 0, before: 0, limit: 500, viewer: "").messages.last?.content, "second words")
        XCTAssertEqual(edit("x", "not-a-uuid").status, 400)
        let del = h.handle(req("POST", "/api/rooms/room1/messages/\(String(id.prefix(8)))/delete"))
        XCTAssertEqual(del.text, #"{"detail":"","state":"deleted"}"# + "\n")
        let twice = h.handle(req("POST", "/api/rooms/room1/messages/\(id)/delete"))
        XCTAssertEqual(twice.status, 422)
        XCTAssertEqual(try json(twice).field("detail")?.stringValue, "that message was already deleted")
        let m = try XCTUnwrap(try core.messagePage(room: "room1", after: 0, before: 0, limit: 500, viewer: "").messages.last)
        XCTAssertTrue(m.deleted)
        XCTAssertEqual(m.content, "")
        XCTAssertEqual(m.deletedBy, "ada")
        // a bot's /edit of another's message is refused; its own is done once per msg_id
        var mine = ChatLine.post(room: "room1", "a bot's words")
        XCTAssertEqual(core.post(mine, sender: "bot3").state, "queued")
        let cmd = ChatLine.post(room: "room1", "/edit ^\(mine.msgID.prefix(8)) better words")
        XCTAssertEqual(core.post(cmd, sender: "bot3"), ChatReceipt("edited"))
        XCTAssertEqual(core.post(cmd, sender: "bot3"), ChatReceipt("duplicate", "already done: edited"))
        mine = ChatLine.post(room: "room1", "/delete ^\(mine.msgID.prefix(8))")
        XCTAssertEqual(core.post(mine, sender: "bot1"), ChatReceipt("refused", "only bot3 or a human can delete that message"))
    }

    // MARK: unread, direct messages, presence, avatars

    func testUnreadCountsWhatTheHumanHasNotSeen() throws {
        let core = try core()
        let h = ChatPageHandler(core: core)
        let before = try json(h.handle(req("GET", "/api/unread")))
        XCTAssertNil(before.field("room2"), "a room the human is not in")
        let mark = try XCTUnwrap(before.field("room1")?.field("last")?.intValue)
        _ = core.post(.post(room: "room1", "one"), sender: "bot3")
        _ = core.post(.post(room: "room1", "two, for @ada"), sender: "bot1")
        try humanSays(h, "room1", "the human's own")
        _ = core.post(.post(room: "room1", "/dm @bot1 between bots"), sender: "bot3")
        let u = try json(h.handle(req("GET", "/api/unread?room1=\(mark)"))).field("room1")
        XCTAssertEqual(u?.field("count")?.intValue, 2)
        XCTAssertEqual(u?.field("mentions")?.intValue, 1)
        XCTAssertEqual(u?.field("preview")?.field("text")?.stringValue, "the human's own")
        let none = try json(h.handle(req("GET", "/api/unread?room1=abc"))).field("room1")
        XCTAssertEqual(none?.field("count")?.intValue, 0, "a marker that is not a number is no marker")
    }

    func testADirectMessageBetweenOthersIsAStubUntilRevealed() throws {
        let core = try core()
        let h = ChatPageHandler(core: core)
        let dm = ChatLine.post(room: "room1", "/dm @bot1 a quiet word")
        XCTAssertEqual(core.post(dm, sender: "bot3").state, "queued")
        let page = try json(h.handle(req("GET", "/api/rooms/room1/messages")))
        let stub = try XCTUnwrap(page.arrayValue?.last)
        XCTAssertEqual(stub.field("kind")?.stringValue, "private")
        XCTAssertEqual(stub.field("content")?.stringValue, "")
        let bad = h.handle(req("POST", "/api/rooms/room1/messages/ffffffff/reveal"))
        XCTAssertEqual(bad.status, 400)
        XCTAssertEqual(try json(bad).field("error")?.stringValue, "no such direct message")
        let shown = h.handle(req("POST", "/api/rooms/room1/messages/\(dm.msgID.prefix(8))/reveal"))
        XCTAssertEqual(try json(shown).field("content")?.stringValue, "a quiet word")
        XCTAssertEqual(try json(shown).field("revealed"), .bool(true))
        let log = try core.messagePage(room: "room1", after: 0, before: 0, limit: 500, viewer: "ada").messages
        XCTAssertEqual(log.last?.content, "Ada revealed a direct message from bot3 to bot1")
    }

    func testPresenceAvatarsAndSessionLinks() throws {
        let core = try core()
        func presence(_ name: String) -> JValue? { core.presence().first { $0.field("name")?.stringValue == name } }
        XCTAssertEqual(presence("ada")?.field("state")?.stringValue, "away")
        XCTAssertEqual(presence("bot3")?.field("detail")?.stringValue, "its session is not connected; messages wait for it")
        XCTAssertEqual(presence("bot1")?.field("avatar")?.stringValue, "grokbot:sphere:default")
        XCTAssertEqual(core.post(.post(room: "room1", "/avatar emoji:cat:default"), sender: "bot1").state, "queued")
        XCTAssertEqual(presence("bot1")?.field("avatar")?.stringValue, "emoji:cat:default")
        XCTAssertEqual(presence("bot1")?.field("state")?.stringValue, "present", "a command is a sign of life")
        XCTAssertEqual(core.post(.post(room: "room1", "/avatar gravatar:someone@example.com"), sender: "bot1").state, "queued")
        let g = try XCTUnwrap(presence("bot1")?.field("avatar")?.stringValue)
        XCTAssertTrue(g.hasPrefix("gravatar:") && !g.contains("example"), "only a hash of the address is kept: \(g)")
        XCTAssertEqual(core.post(.post(room: "room1", "/avatar nonsense"), sender: "bot1").state, "refused")
        XCTAssertEqual(core.post(.post(room: "room1", "/session https://example.com/s/1"), sender: "bot3").state, "queued")
        XCTAssertEqual(presence("bot3")?.field("session_url")?.stringValue, "https://example.com/s/1")
        XCTAssertEqual(core.post(.post(room: "room1", "/session http://example.com"), sender: "bot3").state, "refused")
        let saved = try ChatJSON.parse(Data(contentsOf: URL(fileURLWithPath: dataDir).appendingPathComponent("avatars.json")))
        XCTAssertEqual(saved.field("bot1")?.stringValue, g)
    }

    // MARK: a socket client for the real listener

    static func connect(port: Int) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var a = sockaddr_in()
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = in_port_t(UInt16(port)).bigEndian
        a.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard rc == 0 else { close(fd); throw XCTSkip("cannot connect to the listener") }
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        return fd
    }

    static func send(_ fd: Int32, _ s: String) { _ = Array(s.utf8).withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) } }

    /// Reads until the text has arrived (or fails after the socket's 5 s timeout).
    static func read(_ fd: Int32, until text: String) throws -> String {
        var got = [UInt8]()
        var buf = [UInt8](repeating: 0, count: 65536)
        while !String(decoding: got, as: UTF8.self).contains(text) {
            let n = recv(fd, &buf, buf.count, 0)
            if n <= 0 { throw NSError(domain: "chat-test", code: 1, userInfo: [NSLocalizedDescriptionKey: "no \(text) in: \(String(decoding: got, as: UTF8.self))"]) }
            got += buf[0..<n]
        }
        return String(decoding: got, as: UTF8.self)
    }
}

extension ChatLine {
    /// A message line for a room with a new msg_id.
    static func post(room: String, _ text: String) -> ChatLine {
        var l = ChatLine()
        l.msgID = chatNewID(); l.type = "user"; l.hasBody = true; l.room = room; l.content = text; l.msgV = 1
        return l
    }
}

extension JValue {
    var arrayValue: [JValue]? { if case .array(let a) = self { return a }; return nil }
    var intValue: Int64? { doubleValue.map { Int64($0) } }
}
