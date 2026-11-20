import Darwin
@testable import DozableChat
import Foundation
import XCTest

/// The closed set and a room's removal (ChatRoomControl.swift), on a core made as a start makes it: a closed room refuses
/// posts, edits, reactions and commands with the archived room's status and Dozable's words, `reason` only with the flag;
/// reads stay; archived outranks closed; the set comes over the control channel (never a file or a route) and a reload
/// keeps it, as a restart that the daemon hands the set again would. A removal is refused when the last seq moved, ends
/// its members' waiting receives, drops the room's files and keeps an attachment another room names.
final class ChatClosedTests: XCTestCase {
    var dir = ""
    var dataDir: String { dir + "/data" }

    override func setUpWithError() throws {
        dir = "/tmp/dzc-closed-\(getpid())-\(UUID().uuidString.prefix(6))"
        try FileManager.default.createDirectory(atPath: dataDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data(#"{"room1": ["ada", "bot1"], "room2": ["ada", "bot1"]}"#.utf8).write(to: URL(fileURLWithPath: dataDir + "/rooms.json"))
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(atPath: dir) }

    func core() throws -> ChatServerCore {
        let json = """
            {"line_port": 0, "http_port": 0, "data_dir": "\(dataDir)", "default_room": "room1",
             "participants": [{"name": "ada", "kind": "human", "deliver": "web"}, {"name": "bot1", "kind": "agent"}],
             "rooms": {"room1": ["ada"], "room2": ["ada"]}, "allow": ["127.0.0.1", "::1"], "require_tokens": true, "agent_addresses": ["127.0.0.0/8", "::1"],
             "secrets_file_only": true, "bind": "127.0.0.1"}
            """
        let c = try ChatConfig.resolve(data: Data(json.utf8), .init())
        let core = ChatServerCore(config: c, secrets: ChatSecrets(), release: "1.2.3", sessionsDir: dir + "/no-sessions")
        core.load()
        return core
    }

    func line(_ text: String, room: String = "room1") -> ChatLine {
        var l = ChatLine()
        l.msgID = UUID().uuidString.lowercased()
        l.content = text
        l.room = room
        l.msgV = 1
        l.type = "user"
        l.hasBody = true
        return l
    }

    func control(_ core: ChatServerCore, _ json: String) -> JValue {
        let out = ChatRoomControl.answer(try! ChatJSON.parse(Array(json.utf8)), core: core)!
        return try! ChatJSON.parse(Array(out.dropLast()))
    }

    func testAClosedRoomIsReadableAndRefusesPosts() throws {
        let c = try core()
        XCTAssertEqual(c.post(line("before"), sender: "bot1").state, "queued")
        let a = control(c, #"{"version":1,"id":"c1","closed":{"rooms":{"room1":"demo","nosuch":"x"},"reasons":false}}"#)
        XCTAssertEqual(a.field("id")?.stringValue, "c1")
        XCTAssertEqual((try? a.field("closed")?.field("room1")?.goInt("s")) ?? nil, 1, "its last seq, taken under the close gate")
        XCTAssertNil(a.field("closed")?.field("nosuch"), "a room the server does not have is not closed")
        for who in ["bot1", "ada"] {
            let r = c.post(line("after"), sender: who)
            XCTAssertEqual(r.state, "refused")
            XCTAssertEqual(r.detail, ChatRoomControl.closedText(room: "room1", workspace: "demo"))
            XCTAssertEqual(r.reason, "", "no reason without the setting")
        }
        XCTAssertEqual(c.react(room: "room1", sender: "bot1", msgID: "x", what: "like").state, "refused")
        XCTAssertEqual(c.edit(room: "room1", sender: "bot1", ref: "", text: "x").state, "refused")
        XCTAssertEqual(c.post(line("/hold on"), sender: "ada").state, "refused")
        XCTAssertNotEqual(c.post(line("/rooms"), sender: "bot1").state, "refused", "/rooms still answers")
        XCTAssertEqual(c.post(line("fine", room: "room2"), sender: "bot1").state, "queued", "another room is open")
        // Reads stay.
        XCTAssertEqual(try c.messagePage(room: "room1", after: 0, before: 0, limit: 50, viewer: "bot1").messages.count, 1)
        // The reason, only with the flag; archived outranks closed.
        _ = control(c, #"{"version":1,"id":"c2","closed":{"rooms":{"room1":"demo"},"reasons":true}}"#)
        XCTAssertEqual(c.post(line("again"), sender: "bot1").reason, ChatRoomControl.reasonWord)
        XCTAssertEqual(c.post(line("/archive"), sender: "ada").state, "queued", "a human may still archive it")
        XCTAssertTrue(c.post(line("x"), sender: "bot1").detail.contains("archived"), "archived outranks closed")
        XCTAssertEqual(c.post(line("/unarchive"), sender: "ada").state, "queued")
        // The whole set every time: an empty one opens it.
        _ = control(c, #"{"version":1,"id":"c3","closed":{"rooms":{}}}"#)
        XCTAssertEqual(c.post(line("open again"), sender: "bot1").state, "queued")
    }

    func testAReloadKeepsTheClosedSet() throws {
        let c = try core()
        c.setClosed(["room1": "demo"], reasons: false)
        c.apply(participants: c.people().filter { !$0.isHuman }, hashes: ChatSecrets())
        XCTAssertEqual(c.closedRooms(), ["room1": "demo"], "a reload does not touch it; a restart is handed it again by the daemon")
    }

    func testTheFirstLineAtTheStartIsTheClosedSet() throws {
        let c = try core()
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        defer { close(fds[0]); close(fds[1]) }
        ChatRoomControl.write(fds[0], Array(#"{"version":1,"id":"start","closed":{"rooms":{"room2":"w"}}}"#.utf8) + [0x0A] + Array(#"{"version":1,"reload":"x"#.utf8))
        let rest = ChatRoomControl.takeFirst(fd: fds[1], core: c, seconds: 2, log: .none)
        XCTAssertEqual(c.closedRooms(), ["room2": "w"])
        XCTAssertEqual(String(decoding: rest, as: UTF8.self), #"{"version":1,"reload":"x"#, "what follows is left for the serve loop")
    }

    func testRemovalIsCheckedUnderTheLock() throws {
        let c = try core()
        let shared = String(repeating: "a", count: 32)
        // Attachments: one only room1 names, one room2 names too.
        for (id, rooms) in [(shared, ["room1", "room2"]), (String(repeating: "b", count: 32), ["room1"])] {
            try FileManager.default.createDirectory(atPath: c.filesDir + "/" + id, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: URL(fileURLWithPath: c.filesDir + "/" + id + "/f.txt"))
            for r in rooms {
                var m = ChatStored(msgID: UUID().uuidString.lowercased(), from: "bot1", to: [], reMsgID: "", content: "file", at: chatNow(), mentions: [],
                                   sender: ChatSender(kind: "bot", id: "x", name: "bot1", verified: true), isPrivate: false)
                m.attachments = [.map(["id": .string(id), "name": .string("f.txt")])]
                _ = try c.store(r).insert(&m)
            }
        }
        let last = try c.store("room1").lastSeq()
        XCTAssertEqual(last, 2)
        // A moved last seq: refused, nothing removed.
        if case .success = c.removeRoom("room1", lastSeq: last - 1, id: "rm_0000000000000001") { XCTFail("a moved last seq must be refused") }
        XCTAssertTrue(c.hasRoom("room1"))
        // A waiting receive of a member ends (with nothing) when the room goes.
        let poll = ChatLongPoll(core: c, name: "bot1", ack: false, seconds: 20)
        let done = expectation(description: "poll ends")
        Task { let r = await poll.finish(); XCTAssertEqual(r.status, 200); done.fulfill() }
        usleep(100_000)
        guard case .success = c.removeRoom("room1", lastSeq: last, id: "rm_0000000000000001") else { return XCTFail("not removed") }
        wait(for: [done], timeout: 5)
        XCTAssertFalse(c.hasRoom("room1"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dataDir + "/rooms/room1.db"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: c.filesDir + "/" + shared), "an attachment another room names is kept")
        XCTAssertFalse(FileManager.default.fileExists(atPath: c.filesDir + "/" + String(repeating: "b", count: 32)))
        XCTAssertEqual(c.post(line("x"), sender: "bot1").state, "refused", "an unknown room now")
        // Made again under the same name: a new, empty room.
        XCTAssertEqual(c.post(line("/room room1 @bot1", room: "room2"), sender: "ada").state, "queued")
        XCTAssertEqual(try c.store("room1").lastSeq(), 1, "only its 'created' line")
    }
}
