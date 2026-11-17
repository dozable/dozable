import Darwin
@testable import DozableChat
import Foundation
import XCTest

/// `GET /files/<id>/<name>` on the page port: who the caller is (a participant's `Authorization: Bearer` token, else the
/// human from the owner's own callers), the opening for agent addresses — loopback included, as the daemon's profile
/// makes every TCP caller one — and byte ranges. In-process, neutral names, a scratch data folder.
final class ChatFileFetchTests: XCTestCase {
    static let humanToken = "ada-token-0123456789abcdef"
    static let bot1Token = "bot1-token-0123456789abcdef"
    static let bot2Token = "bot2-token-0123456789abcdef"

    var root = ""

    /// The daemon's profile (`agentProfile`): tokens required, every loopback caller an agent address, nothing owned.
    /// Otherwise the conformance runner's: 127.0.0.1 owned, tokens as asked.
    func core(agentProfile: Bool, requireTokens: Bool = true) throws -> ChatServerCore {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("chat-fetch-\(UUID().uuidString)").path
        addTeardownBlock { [dir = root] in try? FileManager.default.removeItem(atPath: dir) }
        let data = root + "/data"
        try FileManager.default.createDirectory(atPath: data, withIntermediateDirectories: true)
        let access = agentProfile
            ? #""agent_addresses": ["127.0.0.0/8", "::1"], "allow": ["127.0.0.1", "::1"]"#
            : #""test_owned_addresses": ["127.0.0.1"]"#
        let json = """
            {"data_dir": "\(data)", "default_room": "room1", "secrets_file_only": true, "require_tokens": \(requireTokens), \(access),
             "participants": [{"name": "ada", "kind": "human", "deliver": "web"}, {"name": "bot1"}, {"name": "bot2"}],
             "rooms": {"room1": ["ada", "bot1", "bot2"], "room2": ["bot1", "bot2"], "room3": ["ada", "bot1"]}}
            """
        let c = try ChatConfig.parse(Data(json.utf8))
        try c.check()
        let sec = try ChatSecrets.parse(Data(#"{"version": 1, "tokens": {"ada": "\#(Self.humanToken)", "bot1": "\#(Self.bot1Token)", "bot2": "\#(Self.bot2Token)"}}"#.utf8))
        let core = ChatServerCore(config: c, secrets: sec, release: "1.2.3", sessionsDir: root + "/no-sessions")
        core.load()
        return core
    }

    /// bot1 posts a file to a room; its id.
    func botFile(_ core: ChatServerCore, room: String, name: String, _ bytes: [UInt8]) throws -> String {
        var l = ChatLine()
        l.msgID = chatNewID(); l.room = room; l.content = "a file"; l.hasBody = true
        l.attachments = [try ChatJSON.parse(Array(#"{"name":"\#(name)","data_base64":"\#(Data(bytes).base64EncodedString())"}"#.utf8))]
        XCTAssertNotEqual(core.post(l, sender: "bot1").state, "refused")
        let page = try core.messagePage(room: room, after: 0, before: 0, limit: 500, viewer: "")
        return try XCTUnwrap(page.messages.first { $0.msgID == l.msgID }?.attachments.first?.field("id")?.stringValue)
    }

    func get(_ h: ChatPageHandler, _ target: String, from ip: String = "127.0.0.1", bearer: String? = nil, headers: [String: String] = [:],
             method: String = "GET", caller: ChatCaller = .tcp) -> ChatHTTPResponse {
        var hs = headers
        if let bearer { hs["authorization"] = "Bearer " + bearer }
        return h.handle(ChatHTTPRequest(method: method, target: target, headers: hs, remoteIP: ip, caller: caller))
    }

    // MARK: - Who fetches

    /// The failure found on 0.51.4: from loopback (an agent address under the daemon) a participant's token was 403.
    func testALoopbackAgentAddressFetchesAFileWithAParticipantsToken() throws {
        let core = try core(agentProfile: true)
        let h = ChatPageHandler(core: core)
        let id = try botFile(core, room: "room2", name: "notes.txt", Array("for the bots".utf8))
        for ip in ["127.0.0.1", "::1", "127.0.0.2"] {
            let r = get(h, "/files/\(id)/notes.txt", from: ip, bearer: Self.bot2Token)
            XCTAssertEqual(r.status, 200, ip)
            XCTAssertEqual(r.text, "for the bots")
            XCTAssertEqual(r.header("Content-Security-Policy"), "sandbox")
            XCTAssertEqual(r.header("X-Content-Type-Options"), "nosniff")
            XCTAssertEqual(r.header("Accept-Ranges"), "bytes")
        }
        XCTAssertEqual(get(h, "/files/\(id)/notes.txt", method: "HEAD").status, 403, "no token: an agent address only gets /agent/")
        XCTAssertEqual(get(h, "/files/\(id)/notes.txt", bearer: Self.bot2Token, method: "HEAD").status, 200)
    }

    func testAnAgentAddressIsNeverTheHumanOnAFetch() throws {
        let core = try core(agentProfile: true)
        let h = ChatPageHandler(core: core)
        let id = try botFile(core, room: "room3", name: "r3.txt", Array("ada and bot1".utf8))
        // no token: refused at the gate, with the agent-only text
        let none = get(h, "/files/\(id)/r3.txt")
        XCTAssertEqual(none.status, 403)
        XCTAssertEqual(none.text, ChatAccess.agentOnly + "\n")
        // the human's token never makes an agent address the human; an unknown token is no one
        XCTAssertEqual(get(h, "/files/\(id)/r3.txt", bearer: Self.humanToken).status, 404)
        XCTAssertEqual(get(h, "/files/\(id)/r3.txt", bearer: "no-such-token-0123456789").status, 404)
        // X-Chat-Token is not a way in for an agent address
        XCTAssertEqual(get(h, "/files/\(id)/r3.txt", headers: ["x-chat-token": Self.bot1Token]).status, 403)
        // a member's token fetches; one not in the room does not (the plain 404)
        XCTAssertEqual(get(h, "/files/\(id)/r3.txt", bearer: Self.bot1Token).status, 200)
        XCTAssertEqual(get(h, "/files/\(id)/r3.txt", bearer: Self.bot2Token).status, 404)
        // anything a router would tidy, another method or another page is not the opening
        for (m, t) in [("POST", "/files/\(id)/r3.txt"), ("GET", "/files/\(id)/../\(id)/r3.txt"), ("GET", "/files//\(id)/r3.txt"),
                       ("GET", "/files/\(id)"), ("GET", "/files/\(id)/r3.txt/x"), ("GET", "/api/state"), ("GET", "/FILES/\(id)/r3.txt")] {
            XCTAssertEqual(get(h, t, bearer: Self.bot1Token, method: m).status, 403, "\(m) \(t)")
        }
        // the human, on the owner's socket, is served as before
        XCTAssertEqual(get(h, "/files/\(id)/r3.txt", from: "", caller: .owner).status, 200)
    }

    func testAnOwnedCallersTokenMakesThatParticipantTheCaller() throws {
        let core = try core(agentProfile: false)
        let h = ChatPageHandler(core: core)
        let id = try botFile(core, room: "room2", name: "r2.txt", Array("in room2".utf8))
        XCTAssertEqual(get(h, "/files/\(id)/r2.txt").status, 404, "no token: the human, who is not in room2")
        XCTAssertEqual(get(h, "/files/\(id)/r2.txt", bearer: Self.bot2Token).status, 200, "bot2 is in room2")
        XCTAssertEqual(get(h, "/files/\(id)/r2.txt", bearer: "no-such-token-0123456789").status, 404, "an unknown token is no one, never the human")
        let other = try botFile(core, room: "room3", name: "r3.txt", Array("x".utf8))
        XCTAssertEqual(get(h, "/files/\(other)/r3.txt", bearer: Self.bot2Token).status, 404, "bot2 is not in room3")
        XCTAssertEqual(get(h, "/files/\(other)/r3.txt").status, 200, "the human is")
    }

    // MARK: - Ranges

    func testEveryRangeForm() throws {
        let core = try core(agentProfile: false)
        let h = ChatPageHandler(core: core)
        let bytes = Array("0123456789".utf8)
        let id = try botFile(core, room: "room1", name: "ten.bin", bytes)
        let path = "/files/\(id)/ten.bin"
        let whole = get(h, path)
        XCTAssertEqual(whole.status, 200)
        XCTAssertEqual(whole.body, bytes)
        XCTAssertEqual(whole.header("Accept-Ranges"), "bytes")
        for (range, part, cr) in [("bytes=2-5", "2345", "bytes 2-5/10"), ("bytes=7-", "789", "bytes 7-9/10"), ("bytes=-3", "789", "bytes 7-9/10"),
                                  ("bytes=0-0", "0", "bytes 0-0/10"), ("bytes=8-100", "89", "bytes 8-9/10"), ("bytes=-20", "0123456789", "bytes 0-9/10")] {
            let r = get(h, path, headers: ["range": range])
            XCTAssertEqual(r.status, 206, range)
            XCTAssertEqual(r.text, part, range)
            XCTAssertEqual(r.header("Content-Range"), cr, range)
            XCTAssertEqual(r.header("Content-Security-Policy"), "sandbox", range)
            XCTAssertEqual(r.header("X-Content-Type-Options"), "nosniff", range)
            XCTAssertEqual(r.header("Content-Disposition"), "attachment; filename=\"ten.bin\"", range)
            // HEAD: the same headers, the length GET would send, no body
            let head = get(h, path, headers: ["range": range], method: "HEAD")
            XCTAssertEqual(head.status, 206, range)
            XCTAssertEqual(head.body, [], range)
            XCTAssertEqual(head.header("Content-Length"), String(part.utf8.count), range)
            XCTAssertEqual(head.header("Content-Range"), cr, range)
        }
        for range in ["bytes=20-", "bytes=10-12", "bytes=-0"] {
            let r = get(h, path, headers: ["range": range])
            XCTAssertEqual(r.status, 416, range)
            XCTAssertEqual(r.header("Content-Range"), "bytes */10", range)
        }
        // several ranges, or one that cannot be read: the whole file
        for range in ["bytes=0-1,4-5", "bytes=5-2", "bytes=a-b", "items=0-1", "bytes=", "bytes=-", "bytes=+1-2"] {
            let r = get(h, path, headers: ["range": range])
            XCTAssertEqual(r.status, 200, range)
            XCTAssertEqual(r.body, bytes, range)
        }
        XCTAssertEqual(get(h, path, method: "HEAD").header("Content-Length"), "10")
    }
}

/// The conformance ratchet only grows: `Tests/Conformance/expected-green.txt` names each check once and at least as many
/// checks as `Tests/Conformance/RUNNER`'s `minimum` (the runner itself is private; this runs everywhere).
final class ConformanceRatchetTests: XCTestCase {
    static var conformanceDir: String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Conformance").path
    }

    func testTheRatchetHasNoDuplicatesAndIsAtLeastThePinsMinimum() throws {
        let pin = try String(contentsOfFile: Self.conformanceDir + "/RUNNER", encoding: .utf8)
        let minimum = try XCTUnwrap(pin.split(separator: "\n").compactMap { line -> Int? in
            let f = line.split(separator: " ")
            return f.count == 2 && f[0] == "minimum" ? Int(f[1]) : nil
        }.first, "RUNNER names the ratchet's minimum")
        let names = try String(contentsOfFile: Self.conformanceDir + "/expected-green.txt", encoding: .utf8)
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
        XCTAssertEqual(Set(names).count, names.count, "a check is named twice")
        XCTAssertGreaterThanOrEqual(names.count, minimum)
        XCTAssertGreaterThanOrEqual(minimum, 169)
        for n in names { XCTAssertTrue(n.hasPrefix("Test") && n.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }, n) }
    }
}
