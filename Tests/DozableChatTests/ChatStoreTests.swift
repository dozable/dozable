import DozableChat
import Foundation
import XCTest

/// The room store keeps the reference's format exactly.
///
/// `Fixtures/room1.db` was written by the reference server itself (release 0.9.0 and the commits after it, built from its
/// source): started on 127.0.0.1 with neutral names — the human `ada`, the bots `bot1` and `bot2` (no webhook entry, so
/// their deliveries failed) and one room `room1` — it was sent, through its real ports, a verified line from bot1
/// mentioning ada, ada's answer from the page, an unverified line from bot2, a direct message from ada to bot1, bot1's
/// `like` on the answer and `/hold 3`; then stopped, its WAL checkpointed into the file. The workspace's probe
/// `make-store-fixture.py` (feature 699) made it.
final class ChatStoreTests: XCTestCase {
    var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("chat-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: scratch) }

    /// A copy of the fixture: opening a store may add columns and trims old commands, so the original is never opened.
    func fixtureCopy() throws -> String {
        guard let src = Bundle.module.url(forResource: "room1", withExtension: "db", subdirectory: "Fixtures") else {
            throw XCTSkip("no fixture in the bundle")
        }
        let dst = scratch.appendingPathComponent("room1.db")
        try FileManager.default.copyItem(at: src, to: dst)
        return dst.path
    }

    func testAFileOfTheReferenceOpensAndReadsBack() throws {
        let st = try ChatRoomStore(path: try fixtureCopy())
        defer { st.close() }
        XCTAssertEqual(try st.journalMode(), "wal")
        let (ms, more) = try st.page(after: 0, before: 0, limit: 500)
        XCTAssertFalse(more)
        XCTAssertEqual(ms.map(\.seq), [1, 2, 3, 4, 5, 6])

        let announce = ms[0]
        XCTAssertEqual(announce.kind, "change")
        XCTAssertEqual(announce.from, "switchboard")
        XCTAssertNil(announce.sender, "a change line has no sender")
        XCTAssertTrue(announce.content.hasPrefix("The message protocol was updated to version "))

        let hello = ms[1]
        XCTAssertEqual(hello.from, "bot1")
        XCTAssertEqual(hello.content, "hello @ada")
        XCTAssertEqual(hello.mentions, ["ada"])
        XCTAssertEqual(hello.to, ["ada"])
        XCTAssertEqual(hello.sender, ChatSender(kind: "bot", id: "xai:grok-bot:bot1", name: "bot1", verified: true))
        XCTAssertEqual(hello.states.filter { $0.recipient == "ada" }.map(\.state), ["queued", "answered"], "states oldest first")
        XCTAssertEqual(hello.states.first { $0.state == "answered" }?.detail, "by " + ms[2].msgID)

        let answer = ms[2]
        XCTAssertEqual(answer.reMsgID, hello.msgID)
        XCTAssertEqual(answer.sender?.kind, "human")
        XCTAssertEqual(answer.sender?.verified, false)
        XCTAssertEqual(answer.reactions.map(\.who), ["bot1"])
        XCTAssertEqual(answer.reactions.first?.reaction, "like")
        XCTAssertEqual(answer.reactions.first?.emoji, "\u{1F44D}")

        XCTAssertEqual(ms[3].sender?.verified, false, "a line with no auth line is not verified")
        XCTAssertTrue(ms[4].isPrivate)
        XCTAssertEqual(ms[4].to, ["bot1"])
        XCTAssertEqual(ms[4].content, "a direct message")
        XCTAssertEqual(ms[5].content, "Ada turned the hold on: after 3 agent messages in a row, messages to agents wait until a human posts")

        // the message shape the page reads, for one of them
        let shape = ChatJSON.encodeString(hello.json)
        XCTAssertTrue(shape.hasPrefix(#"{"seq":2,"msg_id":""#), shape)
        XCTAssertTrue(shape.contains(#""attachments":[],"mentions":["ada"],"sender":{"kind":"bot","id":"xai:grok-bot:bot1","name":"bot1","verified":true}}"#), shape)
        XCTAssertFalse(shape.contains("\"private\""), "omitted when false")

        // paging back and forward
        XCTAssertEqual(try st.page(after: 0, before: 0, limit: 2).messages.map(\.seq), [5, 6])
        XCTAssertEqual(try st.page(after: 0, before: 0, limit: 2).more, true)
        XCTAssertEqual(try st.page(after: 2, before: 0, limit: 2).messages.map(\.seq), [3, 4])
        XCTAssertEqual(try st.page(after: 0, before: 3, limit: 5).messages.map(\.seq), [1, 2])
        XCTAssertEqual(st.fullID(String(hello.msgID.prefix(8))), hello.msgID)
        XCTAssertTrue(st.knownID(hello.msgID).known)
        XCTAssertEqual(st.knownID(hello.msgID).by, "bot1")
    }

    func testANewFileHasTheReferenceSchema() throws {
        let ours = try ChatRoomStore(path: scratch.appendingPathComponent("new.db").path)
        defer { ours.close() }
        let theirs = try ChatRoomStore(path: try fixtureCopy())
        defer { theirs.close() }
        XCTAssertEqual(try ours.schemaSQL(), try theirs.schemaSQL(), "the same tables, indexes and column order, statement for statement")
        XCTAssertEqual(try ours.columns(of: "messages"),
                       ["seq", "msg_id", "sender", "recipients", "re_msg_id", "content", "at", "kind", "attachments", "mentions", "private",
                        "revealed", "sender_info", "edited_at", "deleted_at", "deleted_by"])
        XCTAssertEqual(try ours.journalMode(), "wal")
    }

    func testOpeningAgainKeepsEverythingAndRefusesADuplicate() throws {
        let path = scratch.appendingPathComponent("again.db").path
        var m = ChatStored(msgID: chatNewID(), from: "ada", to: [], content: "x <y> & z", at: 1763300000.25,
                           sender: ChatSender(kind: "human", id: "human:ada", name: "ada", verified: false))
        do {
            let st = try ChatRoomStore(path: path)
            XCTAssertFalse(try st.insert(&m))
            XCTAssertEqual(m.seq, 1)
            var again = m
            XCTAssertTrue(try st.insert(&again), "the same msg_id is a duplicate")
            try st.setState(ChatState(msgID: m.msgID, recipient: "bot1", state: "queued", at: 1763300000.5))
            st.close()
        }
        let st = try ChatRoomStore(path: path)
        defer { st.close() }
        let back = try st.one(m.msgID)
        XCTAssertEqual(back.content, "x <y> & z")
        XCTAssertEqual(back.at, 1763300000.25)
        XCTAssertEqual(back.states.map(\.state), ["queued"])
        XCTAssertEqual(ChatJSON.encodeString(back.json),
                       #"{"seq":1,"msg_id":"\#(m.msgID)","from":"ada","to":[],"content":"x \u003cy\u003e \u0026 z","at":1763300000.25,"states":[{"msg_id":"\#(m.msgID)","recipient":"bot1","state":"queued","at":1763300000.5}],"reactions":[],"attachments":[],"mentions":[],"sender":{"kind":"human","id":"human:ada","name":"ada","verified":false}}"#)
    }
}
