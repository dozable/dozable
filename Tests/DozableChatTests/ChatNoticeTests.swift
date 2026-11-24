@testable import DozableChat
import Foundation
import XCTest

/// FEEDS on the chat server (ChatNotice.swift, ChatNotices.swift), in the reference's shape: a notice's fields and checks
/// (unknown fields refused, `feed` filled in by the server, the plain `content`), the action's allowlist over its command and
/// args, repeats and floods; a participant of kind `feed` posts notices and nothing else; notices are pulled in their own
/// list (`notices`, beside `messages`) — those addressed to the caller by default, once; `all` for the rest; never pushed —
/// and `GET /agent/notices`; a notice's `to` never names its source; the room's file keeps its schema.
final class ChatNoticeTests: XCTestCase {
    var dir = ""
    var dataDir: String { dir + "/data" }

    override func setUpWithError() throws {
        dir = "/tmp/dzc-notice-\(getpid())-\(UUID().uuidString.prefix(6))"
        try FileManager.default.createDirectory(atPath: dataDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data(#"{"room1": ["ada", "bot1", "bot2", "ci"]}"#.utf8).write(to: URL(fileURLWithPath: dataDir + "/rooms.json"))
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(atPath: dir) }

    func core() throws -> ChatServerCore {
        let json = """
            {"line_port": 0, "http_port": 0, "data_dir": "\(dataDir)", "default_room": "room1",
             "participants": [{"name": "ada", "kind": "human", "deliver": "web"}, {"name": "bot1", "kind": "agent"},
                              {"name": "bot2", "kind": "agent"}, {"name": "ci", "kind": "feed"}],
             "rooms": {"room1": ["ada"]}, "allow": ["127.0.0.1", "::1"], "require_tokens": true, "agent_addresses": ["127.0.0.0/8", "::1"],
             "secrets_file_only": true, "bind": "127.0.0.1"}
            """
        let c = try ChatConfig.resolve(data: Data(json.utf8), .init())
        let core = ChatServerCore(config: c, secrets: ChatSecrets(), release: "1.2.3", sessionsDir: dir + "/no-sessions")
        core.load()
        return core
    }

    func notice(_ dedupe: String? = "k1", severity: String = "warning", title: String? = "bot1 is silent", source: String = "this Mac",
                action: ChatNoticeAction? = nil) -> ChatNotice {
        ChatNotice(kind: "health.silent", severity: severity, subject: ChatNoticeSubject(type: "identity", name: "bot1"),
                   source: ChatNoticeSource(name: source, log: "health"), text: "nothing for 10 minutes", action: action, dedupe: dedupe,
                   at: "2026-11-25T03:12:09Z", title: title)
    }

    /// What `name` pulls now: (messages, notices).
    func received(_ c: ChatServerCore, _ name: String, notices: String = "") -> (messages: [JValue], notices: [JValue]) {
        let r = c.receive(name, wait: "0", ack: true, redeliver: false, notices: notices)
        guard let v = try? ChatJSON.parse(r.body) else { return ([], []) }
        var m: [JValue] = [], n: [JValue] = []
        if case .array(let a)? = v.field("messages") { m = a }
        if case .array(let a)? = v.field("notices") { n = a }
        return (m, n)
    }

    // MARK: the notice

    func testTheNoticeShapeAndItsChecks() throws {
        var n = notice(action: ChatNoticeAction(label: "See", command: "doz", args: ["workspace", "feeds", "app"]))
        n.feed = "health"
        XCTAssertNil(n.refusal())
        XCTAssertEqual(try ChatNotice.read(n.json), n, "read back exactly")
        XCTAssertEqual(ChatJSON.encodeString(n.json),
                       #"{"feed":"health","kind":"health.silent","severity":"warning","subject":{"type":"identity","name":"bot1"},"source":{"name":"this Mac","log":"health"},"text":"nothing for 10 minutes","action":{"label":"See","command":"doz","args":["workspace","feeds","app"]},"dedupe":"k1","at":"2026-11-25T03:12:09Z","title":"bot1 is silent"}"#,
                       "the reference's fields in their order")
        XCTAssertEqual(n.plainText, "[health · warning] bot1 is silent: nothing for 10 minutes (from this Mac's health)")
        var untitled = n; untitled.title = nil
        XCTAssertEqual(untitled.plainText, "[health · warning] nothing for 10 minutes (from this Mac's health)")
        for s in ChatNotice.severities { var x = n; x.severity = s; XCTAssertNil(x.refusal(), s) }
        var bad = n; bad.severity = "urgent"; XCTAssertNotNil(bad.refusal())
        bad = n; bad.kind = "Health.Silent"; XCTAssertNotNil(bad.refusal())
        bad = n; bad.subject.type = "room"; XCTAssertNotNil(bad.refusal())
        bad = n; bad.source.log = ""; XCTAssertNotNil(bad.refusal())
        bad = n; bad.text = ""; XCTAssertNotNil(bad.refusal())
        bad = n; bad.title = String(repeating: "x", count: 121); XCTAssertNotNil(bad.refusal(), "a title is at most 120 characters")
        bad = n; bad.title = "two\nlines"; XCTAssertNotNil(bad.refusal(), "a title is one line")
        bad = n; bad.dedupe = String(repeating: "d", count: 201); XCTAssertNotNil(bad.refusal())
        bad = n; bad.at = "2026-11-25T03:12:09+02:00"; XCTAssertNotNil(bad.refusal(), "at is UTC")
        bad = n; bad.ttl = 0; XCTAssertNotNil(bad.refusal())
        XCTAssertNil({ var x = n; x.at = "2026-11-25T03:12:09.123Z"; x.ttl = 600; x.dedupe = nil; return x.refusal() }())
        for raw in [#"{"kind":"a.b","severity":"info","subject":{"type":"run","name":"r"},"source":{"name":"x","log":"y"},"text":"t","at":"2026-11-25T03:12:09Z","dedupeKey":"k"}"#,
                    #"{"kind":"a.b","severity":"info","subject":{"type":"run","name":"r","extra":1},"source":{"name":"x","log":"y"},"text":"t","at":"2026-11-25T03:12:09Z"}"#,
                    #"{"kind":"a.b","severity":"info","source":{"name":"x","log":"y"},"text":"t","at":"2026-11-25T03:12:09Z"}"#] {
            XCTAssertThrowsError(try ChatNotice.read(try ChatJSON.parse(Array(raw.utf8))), "unknown or missing fields are refused: \(raw)")
        }
    }

    func testAnActionIsOneOfDozablesOwnReadCommandsNeverAShellLine() {
        for ok in ["doz workspace feeds app", "doz account ls", "dozchat receive", "doz workspace state app --json", "doz net log app --denied",
                   "dozchat journal --run 2026-11-24-1"] {
            XCTAssertNil(ChatNoticeCommand.refusal(ok), ok)
        }
        XCTAssertNil(ChatNoticeCommand.refusal(["doz", "workspace", "feeds", "app"]))
        XCTAssertNotNil(ChatNoticeCommand.refusal(["doz", "account", "ls", "; rm -rf ~"]), "args are judged word by word")
        XCTAssertNotNil(ChatNoticeCommand.refusal(ChatNoticeAction(label: "x", command: "rm", args: ["-rf", "~"]).words))
        for bad in ["rm -rf ~", "doz rm app", "doz workspace delete app", "doz account ls; rm -rf ~", "doz account ls | sh",
                    "doz account ls && curl x", "$(rm -rf ~)", "doz account ls `id`", "doz  account ls", "doz account ls\nrm x",
                    "sh -c 'doz account ls'", "doz workspace feeds app > /tmp/x", "", "dozchat send app hi", "doz sessions send x y --text z",
                    "doz resources clean", "dozchat journal add note x", "doz workspace feeds app --emit test.x", "doz doctor --fix"] {
            XCTAssertNotNil(ChatNoticeCommand.refusal(bad), bad)
        }
    }

    func testRepeatsPostOnceAndAFeedIsRateLimited() {
        var t = ChatNoticeThrottle(window: 600, limit: 5, per: 60)
        XCTAssertEqual(t.decide(scope: "w", feed: "health", key: "a", now: 0), .post(heldBefore: 0))
        XCTAssertEqual(t.decide(scope: "w", feed: "health", key: "a", now: 10), .repeated)
        XCTAssertEqual(t.decide(scope: "w", feed: "health", key: "a", now: 599), .repeated)
        XCTAssertEqual(t.decide(scope: "w2", feed: "health", key: "a", now: 20), .post(heldBefore: 0), "another workspace is its own")
        var r = ChatNoticeThrottle(window: 600, limit: 5, per: 60)
        let got = (1...10).map { r.decide(scope: "w", feed: "test", key: "d\($0)", now: Double($0)) }
        XCTAssertEqual(got.filter { if case .post = $0 { return true }; return false }.count, 5)
        XCTAssertEqual(got.filter { $0 == .rateLimited }.count, 5)
        XCTAssertEqual(r.decide(scope: "w", feed: "other", key: "x", now: 11), .post(heldBefore: 0), "the rate is per feed")
        XCTAssertEqual(r.decide(scope: "w", feed: "test", key: "late", now: 70), .post(heldBefore: 5))
        XCTAssertEqual(t.decide(scope: "w", feed: "health", key: "a", now: 601), .post(heldBefore: 2), "after its window it posts again")
    }

    func testAHigherSeverityRepeatIsNeverDroppedAndCriticalIsNeverRateLimited() {
        var t = ChatNoticeThrottle(window: 600, limit: 5, per: 60)
        XCTAssertEqual(t.decide(scope: "w", feed: "resources", key: "disk", now: 0, severity: "warning"), .post(heldBefore: 0))
        XCTAssertEqual(t.decide(scope: "w", feed: "resources", key: "disk", now: 10, severity: "warning"), .repeated, "the same severity is a repeat")
        XCTAssertEqual(t.decide(scope: "w", feed: "resources", key: "disk", now: 20, severity: "info"), .repeated, "a lower one too")
        XCTAssertEqual(t.decide(scope: "w", feed: "resources", key: "disk", now: 30, severity: "critical"), .post(heldBefore: 2),
                       "a warning that turns critical inside the window is posted as a new notice")
        XCTAssertEqual(t.decide(scope: "w", feed: "resources", key: "disk", now: 40, severity: "critical"), .repeated, "then critical is the bar")
        var r = ChatNoticeThrottle(window: 600, limit: 5, per: 60)
        for i in 1...5 { _ = r.decide(scope: "w", feed: "test", key: "k\(i)", now: Double(i), severity: "info") }
        XCTAssertEqual(r.decide(scope: "w", feed: "test", key: "k6", now: 6, severity: "warning"), .rateLimited)
        XCTAssertEqual(r.decide(scope: "w", feed: "test", key: "k7", now: 7, severity: "critical"), .post(heldBefore: 1),
                       "a critical notice is never held by the rate limit")
    }

    // MARK: the server

    func testAFeedPostsNoticesAndNeverAsksDecidesReactsOrReads() throws {
        let c = try core()
        var l = ChatLine()
        l.msgID = chatNewID(); l.room = "room1"; l.kind = "notice"; l.content = "x"; l.hasBody = true; l.type = "user"
        var sent = notice().json
        if case .object(var ms) = sent { ms.insert(JMember("feed", .string("someone-else")), at: 0); sent = .object(ms) }
        let body: JValue = .map(["kind": .string("notice"), "room": .string("room1"), "notice": sent])
        XCTAssertEqual(c.feedSend(l, body: body, sender: "ci")?.status, 200)
        let m = try XCTUnwrap(try c.messagePage(room: "room1", after: 0, before: 0, limit: 50, viewer: "ada").messages.last { $0.kind == "notice" })
        XCTAssertEqual(m.notice?.feed, "ci", "the server fills in the feed, whatever the poster sent")
        XCTAssertEqual(m.from, "ci")
        XCTAssertEqual(m.sender?.kind, "feed")
        XCTAssertEqual(m.content, "[ci · warning] bot1 is silent: nothing for 10 minutes (from this Mac's health)")
        XCTAssertNil(m.json.field("feed"), "no top-level feed: it is inside the notice")
        // An unknown field: refused.
        var odd = l; odd.msgID = chatNewID()
        let oddBody: JValue = .map(["kind": .string("notice"), "notice": .map(["kind": .string("a.b"), "dedupeKey": .string("x")])])
        XCTAssertEqual(c.feedSend(odd, body: oddBody, sender: "ci")?.status, 422)
        // An ask: not permitted, in the shape a client reads (error.code).
        var ask = l; ask.msgID = chatNewID(); ask.kind = "ask"; ask.content = "May I merge?"
        let no = c.feedSend(ask, body: .map(["kind": .string("ask")]), sender: "ci")
        XCTAssertEqual(no?.status, 403)
        XCTAssertEqual(no?.answer.field("error")?.field("code")?.stringValue, "not-permitted")
        var plain = l; plain.msgID = chatNewID(); plain.kind = ""; plain.content = "hello"
        XCTAssertEqual(c.feedSend(plain, body: .map([:]), sender: "ci")?.status, 403)
        XCTAssertEqual(c.post(plain, sender: "ci").state, "refused", "the line port's way in is refused too")
        var cmd = plain; cmd.msgID = chatNewID(); cmd.content = "/invite @bot2"
        XCTAssertEqual(c.post(cmd, sender: "ci").state, "refused")
        var rooms = plain; rooms.msgID = chatNewID(); rooms.content = "/rooms"
        XCTAssertNil(c.feedSend(rooms, body: .map([:]), sender: "ci"), "/rooms is the ordinary path")
        XCTAssertNotEqual(c.post(rooms, sender: "ci").state, "refused")
        XCTAssertEqual(c.react(room: "room1", sender: "ci", msgID: m.msgID, what: "like").state, "refused")
        XCTAssertEqual(c.mayPoll("ci")?.status, 403, "a feed never reads the room")
        XCTAssertNil(c.feedSend(l, body: body, sender: "bot1"), "an ordinary participant is not a feed")
    }

    func testNoticesArePulledInTheirOwnListNeverPushed() throws {
        let c = try core()
        // A room notice naming no one: the room's people see it; no agent is handed it.
        XCTAssertEqual(c.postNotice(room: "room1", msgID: chatNewID(), from: ChatProtocol.systemName, feed: "journal",
                                    notice: notice("r1", severity: "info", source: "bot2"), to: [], direct: false).state, "queued")
        // A direct notice to the owner alone.
        XCTAssertEqual(c.postNotice(room: "room1", msgID: chatNewID(), from: ChatProtocol.systemName, feed: "test", notice: notice("o1"),
                                    to: ["ada"], direct: true).state, "queued")
        var got = received(c, "bot1")
        XCTAssertTrue(got.messages.isEmpty && got.notices.isEmpty, "nothing addressed to bot1")
        // A notice naming bot1: pulled in `notices`, never among the messages; once.
        XCTAssertEqual(c.postNotice(room: "room1", msgID: chatNewID(), from: ChatProtocol.systemName, feed: "network",
                                    notice: notice("n2"), to: ["bot1", "ada"], direct: true).state, "queued")
        got = received(c, "bot1")
        XCTAssertTrue(got.messages.isEmpty, "a notice is never a message")
        XCTAssertEqual(got.notices.count, 1)
        let item = try XCTUnwrap(got.notices.first)
        XCTAssertEqual(item.field("type")?.stringValue, "notice")
        XCTAssertEqual(item.field("addressed_to_you")?.boolValue, true)
        XCTAssertEqual(item.field("about_you")?.boolValue, true, "its subject is bot1")
        XCTAssertEqual(item.field("source")?.field("log")?.stringValue, "health")
        XCTAssertEqual(item.field("notice")?.field("feed")?.stringValue, "network")
        XCTAssertEqual(item.field("notice")?.field("dedupe")?.stringValue, "n2")
        XCTAssertTrue(item.field("content")?.stringValue?.hasPrefix("[network · warning] ") == true)
        XCTAssertTrue(received(c, "bot1").notices.isEmpty, "handed once")
        XCTAssertTrue(received(c, "bot2").notices.isEmpty, "bot2 was not named")
        // `all`: the room notices it may read too (a look); the owner's own stays private; `none`: none.
        let all = received(c, "bot2", notices: "all").notices
        XCTAssertEqual(all.map { $0.field("notice")?.field("dedupe")?.stringValue }, ["r1"])
        XCTAssertEqual(all.first?.field("addressed_to_you")?.boolValue, false)
        XCTAssertEqual(c.postNotice(room: "room1", msgID: chatNewID(), from: ChatProtocol.systemName, feed: "network",
                                    notice: notice("n3"), to: ["bot1"], direct: true).state, "queued")
        XCTAssertTrue(received(c, "bot1", notices: "none").notices.isEmpty, "listen's way: none taken")
        XCTAssertEqual(received(c, "bot1").notices.count, 1, "still there for the next receive")
        // An answer with no notice is the protocol's own: no `notices` member.
        let plain = try ChatJSON.parse(c.receive("bot2", wait: "0", ack: true, redeliver: false).body)
        XCTAssertNil(plain.field("notices"))
        // The owner reads every one it is named in, and the room's (Dozable's own name the owner beside an agent).
        let shown = try c.messagePage(room: "room1", after: 0, before: 0, limit: 50, viewer: "ada").messages.filter { $0.kind == "notice" }
        XCTAssertEqual(shown.map { $0.notice?.dedupe }, ["r1", "o1", "n2"])
        XCTAssertNil(try c.messagePage(room: "room1", after: 0, before: 0, limit: 50, viewer: "bot2").messages.first { $0.to == ["ada"] }?.notice,
                     "a direct notice between others is a stub")
        // Never addressed to its source; never to a stranger; a msg_id twice is a duplicate.
        XCTAssertEqual(c.postNotice(room: "room1", msgID: chatNewID(), from: ChatProtocol.systemName, feed: "journal",
                                    notice: notice("s", source: "bot1"), to: ["bot1"], direct: true).state, "refused")
        XCTAssertEqual(c.postNotice(room: "room1", msgID: chatNewID(), from: ChatProtocol.systemName, feed: "test", notice: notice("x"),
                                    to: ["stranger"], direct: true).state, "refused")
        let id = chatNewID()
        XCTAssertEqual(c.postNotice(room: "room1", msgID: id, from: ChatProtocol.systemName, feed: "test", notice: notice("d"), to: [], direct: false).state, "queued")
        XCTAssertEqual(c.postNotice(room: "room1", msgID: id, from: ChatProtocol.systemName, feed: "test", notice: notice("d"), to: [], direct: false).state, "duplicate")
    }

    func testTheNoticesRouteIsALook() throws {
        let c = try core()
        XCTAssertEqual(c.postNotice(room: "room1", msgID: chatNewID(), from: ChatProtocol.systemName, feed: "health",
                                    notice: notice("w1"), to: ["bot1"], direct: true).state, "queued")
        XCTAssertEqual(c.pullNotices("bot1", mode: "mine", room: "room1", hand: false).count, 1)
        XCTAssertEqual(c.pullNotices("bot1", mode: "mine", room: "room1", hand: false).count, 1, "a look marks nothing")
        XCTAssertTrue(c.pullNotices("bot1", mode: "mine", room: "nosuch", hand: false).isEmpty)
        XCTAssertEqual(received(c, "bot1").notices.count, 1, "still handed once by receive")
    }

    func testTheRoomsFileKeepsItsSchemaAndANoticeReadsBack() throws {
        let c = try core()
        XCTAssertEqual(c.postNotice(room: "room1", msgID: chatNewID(), from: ChatProtocol.systemName, feed: "health",
                                    notice: notice(action: ChatNoticeAction(label: "See", command: "doz workspace state app")), to: [], direct: false).state, "queued")
        let st = try c.store("room1")
        let m = try XCTUnwrap(try st.page(after: 0, before: 0, limit: 10).messages.last)
        XCTAssertEqual(m.kind, "notice")
        XCTAssertEqual(m.notice?.action?.command, "doz workspace state app")
        XCTAssertEqual(m.json.field("notice")?.field("feed")?.stringValue, "health")
        XCTAssertEqual(m.sender?.id, "dozable:feed:health")
        XCTAssertFalse(ChatRoomStore.schema.contains("notice TEXT"), "the schema is the reference's")
        var plain = ChatStored(msgID: chatNewID(), from: "bot1", content: "hi", at: chatNow(), sender: ChatSender(kind: "bot", id: "x", name: "bot1", verified: true))
        _ = try st.insert(&plain)
        XCTAssertNil(try st.one(plain.msgID).notice)
    }

    func testDozablesOwnNoticeComesOverTheControlChannel() throws {
        let c = try core()
        let id = chatNewID()
        let req = ChatJSON.encodeString(.map(["version": .int(1), "id": .string("s1"), "systemNotice": .map([
            "room": .string("room1"), "msgId": .string(id), "feed": .string("journal"), "notice": notice("j1", severity: "info").json,
            "to": .strings([]), "direct": .bool(false)])]))
        let a = try ChatJSON.parse(Array(ChatRoomControl.answer(try ChatJSON.parse(Array(req.utf8)), core: c)!.dropLast()))
        XCTAssertEqual(a.field("noticed")?.field("msgId")?.stringValue, id)
        let bad = ChatRoomControl.answer(try ChatJSON.parse(Array(#"{"version":1,"id":"s2","systemNotice":{"room":"room1"}}"#.utf8)), core: c)!
        XCTAssertNotNil(try ChatJSON.parse(Array(bad.dropLast())).field("refused"))
        let m = try XCTUnwrap(try c.messagePage(room: "room1", after: 0, before: 0, limit: 10, viewer: "ada").messages.last)
        XCTAssertEqual(m.from, ChatProtocol.systemName)
        XCTAssertEqual(m.notice?.feed, "journal")
    }
}
