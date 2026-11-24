@testable import DozableChat
import Foundation
import XCTest

/// FEEDS on the chat server (ChatNotice.swift, ChatNotices.swift): a notice's shape and its checks, the action's allowlist,
/// repeats and floods; a participant of kind `feed` posts notices and nothing else (an ask is 403 not-permitted, it never
/// decides, reacts or reads the room); who is handed a notice (those it names, and in the room its people — never an agent
/// it does not name); the notice comes back from the room's file (its schema unchanged) and to a polling agent as its own
/// kind; Dozable's own notices come over the control channel under the server's name.
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

    func notice(_ key: String = "k1", severity: String = "warning", action: String? = nil) -> ChatNotice {
        ChatNotice(kind: "health.silent", severity: severity, title: "bot1 is silent", text: "nothing for 10 minutes", source: "this Mac",
                   dedupeKey: key, action: action.map { ChatNoticeAction(label: "See", command: $0) })
    }

    /// What `name` is handed now (a receive that does not wait).
    func received(_ c: ChatServerCore, _ name: String) async -> [JValue] {
        let r = c.receive(name, wait: "0", ack: true, redeliver: false)
        guard let v = try? ChatJSON.parse(r.body), case .array(let items)? = v.field("messages") else { return [] }
        return items
    }

    // MARK: the notice

    func testTheNoticeShapeAndItsChecks() throws {
        let n = notice(action: "doz workspace feeds app")
        XCTAssertNil(n.refusal())
        let back = try ChatNotice.read(n.json)
        XCTAssertEqual(back, n, "read back exactly")
        XCTAssertEqual(ChatJSON.encodeString(n.json),
                       #"{"kind":"health.silent","severity":"warning","title":"bot1 is silent","text":"nothing for 10 minutes","source":"this Mac","dedupeKey":"k1","action":{"label":"See","command":"doz workspace feeds app"}}"#,
                       "the fields in their order")
        XCTAssertEqual(n.plainText(feed: "health"), "[notice · warning · health] bot1 is silent — nothing for 10 minutes (this Mac)\nSee: doz workspace feeds app",
                       "a readable line for a client that knows nothing of notices")
        XCTAssertEqual(n.family, "health")
        for s in ChatNotice.severities { var x = n; x.severity = s; XCTAssertNil(x.refusal(), s) }
        var bad = n; bad.severity = "urgent"; XCTAssertNotNil(bad.refusal())
        bad = n; bad.kind = "Health.Silent"; XCTAssertNotNil(bad.refusal())
        bad = n; bad.kind = "health..x"; XCTAssertTrue(ChatNotice.isKind("health..x"), "dots inside are fine")
        bad = n; bad.dedupeKey = ""; XCTAssertNotNil(bad.refusal())
        bad = n; bad.title = ""; bad.text = ""; XCTAssertNotNil(bad.refusal())
        bad = n; bad.text = String(repeating: "x", count: ChatNotice.maximumText + 1); XCTAssertNotNil(bad.refusal())
        XCTAssertThrowsError(try ChatNotice.read(try ChatJSON.parse(Array(#"{"kind":"a.b","severity":"info","dedupeKey":"k","extra":1}"#.utf8))),
                             "an unknown key is refused")
    }

    func testAnActionIsOneOfDozablesOwnReadCommandsNeverAShellLine() {
        for ok in ["doz workspace feeds app", "doz account ls", "dozchat receive", "doz workspace state app --json", "doz net log app --denied",
                   "dozchat journal --run 2026-11-24-1"] {
            XCTAssertNil(ChatNoticeCommand.refusal(ok), ok)
        }
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
        // The rate: 5 a minute per feed, whatever the keys; the next post says how many were held back.
        var r = ChatNoticeThrottle(window: 600, limit: 5, per: 60)
        let got = (1...10).map { r.decide(scope: "w", feed: "test", key: "d\($0)", now: Double($0)) }
        XCTAssertEqual(got.filter { if case .post = $0 { return true }; return false }.count, 5)
        XCTAssertEqual(got.filter { $0 == .rateLimited }.count, 5)
        XCTAssertEqual(r.decide(scope: "w", feed: "other", key: "x", now: 11), .post(heldBefore: 0), "the rate is per feed")
        XCTAssertEqual(r.decide(scope: "w", feed: "test", key: "late", now: 70), .post(heldBefore: 5))
        XCTAssertEqual(t.decide(scope: "w", feed: "health", key: "a", now: 601), .post(heldBefore: 2), "after its window it posts again")
    }

    // MARK: the server

    func testAFeedPostsNoticesAndNeverAsksDecidesReactsOrReads() async throws {
        let c = try core()
        XCTAssertTrue(c.participant("ci")?.isFeed == true)
        // A notice from the feed: posted, under its own name as the feed.
        var l = ChatLine()
        l.msgID = chatNewID(); l.room = "room1"; l.kind = "notice"; l.content = "x"; l.hasBody = true; l.type = "user"
        let body: JValue = .map(["kind": .string("notice"), "room": .string("room1"), "notice": notice().json])
        let ok = c.feedSend(l, body: body, sender: "ci")
        XCTAssertEqual(ok?.status, 200)
        let page = try c.messagePage(room: "room1", after: 0, before: 0, limit: 50, viewer: "ada").messages
        let m = try XCTUnwrap(page.last { $0.kind == "notice" })
        XCTAssertEqual(m.feed, "ci")
        XCTAssertEqual(m.from, "ci")
        XCTAssertEqual(m.sender?.kind, "feed")
        XCTAssertEqual(m.notice, notice())
        // An ask: not permitted, in the shape a client reads (error.code).
        var ask = l; ask.msgID = chatNewID(); ask.kind = "ask"; ask.content = "May I merge?"
        let no = c.feedSend(ask, body: .map(["kind": .string("ask")]), sender: "ci")
        XCTAssertEqual(no?.status, 403)
        XCTAssertEqual(no?.answer.field("error")?.field("code")?.stringValue, "not-permitted")
        // A plain message, a room command, a reaction: refused; /rooms still answers.
        var plain = l; plain.msgID = chatNewID(); plain.kind = ""; plain.content = "hello"
        XCTAssertEqual(c.feedSend(plain, body: .map([:]), sender: "ci")?.status, 403)
        XCTAssertEqual(c.post(plain, sender: "ci").state, "refused", "the line port's way in is refused too")
        var cmd = plain; cmd.msgID = chatNewID(); cmd.content = "/invite @bot2"
        XCTAssertEqual(c.post(cmd, sender: "ci").state, "refused")
        var rooms = plain; rooms.msgID = chatNewID(); rooms.content = "/rooms"
        XCTAssertNil(c.feedSend(rooms, body: .map([:]), sender: "ci"), "/rooms is the ordinary path")
        XCTAssertNotEqual(c.post(rooms, sender: "ci").state, "refused")
        XCTAssertEqual(c.react(room: "room1", sender: "ci", msgID: m.msgID, what: "like").state, "refused")
        // It never reads the room.
        XCTAssertEqual(c.mayPoll("ci")?.status, 403)
        // An ordinary participant is not a feed: its kind "notice" is an ordinary message.
        XCTAssertNil(c.feedSend(l, body: body, sender: "bot1"))
    }

    func testANoticeIsHandedOnlyToThoseItNamesAndTheRoomsPeople() async throws {
        let c = try core()
        // A room notice naming no one: the room's people, never an agent.
        XCTAssertEqual(c.postNotice(room: "room1", msgID: chatNewID(), from: ChatProtocol.systemName, feed: "journal", notice: notice("r1", severity: "info"),
                                    to: [], direct: false).state, "queued")
        let none1 = await received(c, "bot1")
        XCTAssertTrue(none1.isEmpty, "an agent is never handed a notice that does not name it")
        // A direct notice to the owner: the agents get nothing and cannot read it.
        XCTAssertEqual(c.postNotice(room: "room1", msgID: chatNewID(), from: ChatProtocol.systemName, feed: "test", notice: notice("o1"),
                                    to: ["ada"], direct: true).state, "queued")
        let none2 = await received(c, "bot1")
        XCTAssertTrue(none2.isEmpty)
        let seenByBot = try c.messagePage(room: "room1", after: 0, before: 0, limit: 50, viewer: "bot1").messages
        XCTAssertNil(seenByBot.last?.notice, "a direct notice between others is a stub: no fields")
        // A notice naming bot1 (and the owner): handed to bot1 as its own kind, with how to take it.
        XCTAssertEqual(c.postNotice(room: "room1", msgID: chatNewID(), from: ChatProtocol.systemName, feed: "network",
                                    notice: notice("n2"), to: ["bot1", "ada"], direct: true).state, "queued")
        let got = await received(c, "bot1")
        XCTAssertEqual(got.count, 1)
        XCTAssertEqual(got.first?.field("kind")?.stringValue, "notice")
        XCTAssertEqual(got.first?.field("feed")?.stringValue, "network")
        XCTAssertEqual(got.first?.field("notice")?.field("dedupeKey")?.stringValue, "n2")
        XCTAssertTrue(got.first?.field("how_to_respond")?.stringValue?.contains("not a message to answer") == true)
        let other = await received(c, "bot2")
        XCTAssertTrue(other.isEmpty, "bot2 was not named")
        // The owner reads every one of them in the room, each with its fields.
        let all = try c.messagePage(room: "room1", after: 0, before: 0, limit: 50, viewer: "ada").messages.filter { $0.kind == "notice" }
        XCTAssertEqual(all.map(\.feed), ["journal", "test", "network"])
        XCTAssertEqual(all.map { $0.notice?.dedupeKey }, ["r1", "o1", "n2"])
        XCTAssertTrue(all.allSatisfy { $0.from == ChatProtocol.systemName && $0.sender?.kind == "feed" })
        // A named participant who is not in the room: refused, nothing posted.
        XCTAssertEqual(c.postNotice(room: "room1", msgID: chatNewID(), from: ChatProtocol.systemName, feed: "test", notice: notice("x"),
                                    to: ["stranger"], direct: true).state, "refused")
        // The same msg_id again: a duplicate.
        let id = chatNewID()
        XCTAssertEqual(c.postNotice(room: "room1", msgID: id, from: ChatProtocol.systemName, feed: "test", notice: notice("d"), to: [], direct: false).state, "queued")
        XCTAssertEqual(c.postNotice(room: "room1", msgID: id, from: ChatProtocol.systemName, feed: "test", notice: notice("d"), to: [], direct: false).state, "duplicate")
    }

    func testTheRoomsFileKeepsItsSchemaAndANoticeReadsBack() throws {
        let c = try core()
        XCTAssertEqual(c.postNotice(room: "room1", msgID: chatNewID(), from: ChatProtocol.systemName, feed: "health",
                                    notice: notice(action: "doz workspace state app"), to: [], direct: false).state, "queued")
        let st = try c.store("room1")
        let m = try XCTUnwrap(try st.page(after: 0, before: 0, limit: 10).messages.last)
        XCTAssertEqual(m.kind, "notice")
        XCTAssertEqual(m.notice?.action?.command, "doz workspace state app")
        XCTAssertEqual(m.json.field("notice")?.field("kind")?.stringValue, "health.silent", "the wire shape carries it")
        XCTAssertEqual(m.json.field("feed")?.stringValue, "health")
        // The fields ride in the row's sender_info beside the sender's own; the schema is the reference's.
        XCTAssertEqual(m.sender?.name, "health")
        XCTAssertEqual(m.sender?.id, "dozable:feed:health")
        XCTAssertTrue(ChatRoomStore.schema.contains("CREATE TABLE IF NOT EXISTS messages(") && !ChatRoomStore.schema.contains("notice TEXT"))
        // An ordinary message never has them.
        var plain = ChatStored(msgID: chatNewID(), from: "bot1", content: "hi", at: chatNow(), sender: ChatSender(kind: "bot", id: "x", name: "bot1", verified: true))
        _ = try st.insert(&plain)
        let back = try st.one(plain.msgID)
        XCTAssertNil(back.notice)
        XCTAssertEqual(back.feed, "")
    }

    func testDozablesOwnNoticeComesOverTheControlChannel() throws {
        let c = try core()
        let id = chatNewID()
        let req = ChatJSON.encodeString(.map(["version": .int(1), "id": .string("s1"), "systemNotice": .map([
            "room": .string("room1"), "msgId": .string(id), "feed": .string("journal"), "notice": notice("j1", severity: "info").json,
            "to": .strings([]), "direct": .bool(false)])]))
        let out = ChatRoomControl.answer(try ChatJSON.parse(Array(req.utf8)), core: c)!
        let a = try ChatJSON.parse(Array(out.dropLast()))
        XCTAssertEqual(a.field("noticed")?.field("msgId")?.stringValue, id)
        let bad = ChatRoomControl.answer(try ChatJSON.parse(Array(#"{"version":1,"id":"s2","systemNotice":{"room":"room1"}}"#.utf8)), core: c)!
        XCTAssertNotNil(try ChatJSON.parse(Array(bad.dropLast())).field("refused"))
        let m = try XCTUnwrap(try c.messagePage(room: "room1", after: 0, before: 0, limit: 10, viewer: "ada").messages.last)
        XCTAssertEqual(m.from, ChatProtocol.systemName)
        XCTAssertEqual(m.feed, "journal")
    }
}
