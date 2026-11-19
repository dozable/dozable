import DozableChat
@testable import DozableHost
import DozableKit
import Foundation
import XCTest

/// The leak sweep every export passes through: a live chat token found by its hash and replaced, only its owner named.
final class ExportSweepTests: XCTestCase {
    let token = ChatTokens.make()
    let given = "my-own-token:with/odd=chars"

    var sweep: ExportSweep { ExportSweep(tokenHashes: ["bot1": ChatSecrets.hash(token), "bot2": ChatSecrets.hash(given)]) }

    func testAPlantedTokenIsFoundByItsHashAndRedacted() {
        for text in ["here it is: \(token) — oops", #"{"content":"\#(token)"}"#, "token=\(token)&x", "x\(token)", "\(given) in prose", #""\#(given)""#] {
            let (out, found) = sweep.clean(Array(text.utf8), file: "room1.jsonl")
            let s = String(decoding: out, as: UTF8.self)
            XCTAssertFalse(s.contains(token) || s.contains(given), text)
            XCTAssertEqual(found.count, 1, text)
            XCTAssertTrue(s.contains("[a chat token of bot"), s)
            XCTAssertNil(found.first?.sentence.range(of: token), "the value is never named")
        }
        let (_, found) = sweep.clean(Array("a \(token) b".utf8), file: "f")
        XCTAssertEqual(found, [ExportSweep.Finding(file: "f", kind: "chat-token", participant: "bot1")])
        XCTAssertTrue(found[0].sentence.contains("doz chat token bot1 --new"))
    }

    func testOtherSecretsByTheirShape() {
        let text = "Authorization: Bearer abcdefghijklmnopqrstuvwxyz012345 and sk-ant-abcdefghijklmnop1234 and doz_cred_0123456789abcdef0123"
        let (out, found) = sweep.clean(Array(text.utf8), file: "t")
        let s = String(decoding: out, as: UTF8.self)
        XCTAssertEqual(Set(found.map(\.kind)), ["bearer", "api-key", "placeholder"])
        XCTAssertFalse(s.contains("abcdefghijklmnopqrstuvwxyz012345") || s.contains("sk-ant-") || s.contains("doz_cred_0123"), s)
    }

    func testNothingFoundLeavesTheBytesAsTheyAre() {
        let text = Array("an ordinary message with dzc_short and a long-word-that-is-no-token-at-all-0123456789".utf8)
        let (out, found) = sweep.clean(text, file: "t")
        XCTAssertEqual(out, text)
        XCTAssertTrue(found.isEmpty)
        XCTAssertTrue(ExportSweep(tokenHashes: [:]).clean(Array(token.utf8), file: "t").findings.isEmpty, "no hashes: no chat token to find")
    }
}

/// `doz chat read --since` and `doz chat export`: paging backwards past 500, the window, attachments, the folder's rules.
final class ChatExportTests: XCTestCase {
    var root = ""

    override func setUpWithError() throws {
        root = "/tmp/dzc-export-\(getpid())-\(UUID().uuidString.prefix(6))"
        try FileManager.default.createDirectory(atPath: root + "/store", withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(atPath: root) }

    /// A room of `n` messages, one a second from t0, as the page API serves it (oldest first in each page).
    final class FakeRoom: @unchecked Sendable {
        let n: Int
        let t0: Double = 1_700_000_000
        var asked: [String] = []
        var files: [String: Data] = [:]
        var attachEvery = 0
        init(_ n: Int) { self.n = n }
        func message(_ seq: Int) -> JValue {
            var m: [String: JValue] = ["seq": .int(Int64(seq)), "at": .double(t0 + Double(seq)), "from": .string("ada"),
                                       "content": .string("message \(seq)"), "msg_id": .string(UUID().uuidString.lowercased())]
            if attachEvery > 0 && seq % attachEvery == 0 {
                m["attachments"] = .array([.map(["id": .string(String(format: "%032x", seq)), "name": .string("note \(seq).txt")])])
            }
            return .map(m)
        }
        func fetch(_ target: String) throws -> (status: Int, body: Data) {
            asked.append(target)
            if target.hasPrefix("/files/") {
                let id = target.split(separator: "/")[1]
                if let d = files[String(id)] { return (200, d) }
                return (404, Data(#"{"error":"no such file"}"#.utf8))
            }
            let q = URLComponents(string: "http://x" + target)!.queryItems ?? []
            let before = Int(q.first { $0.name == "before" }?.value ?? "0") ?? 0
            let limit = Int(q.first { $0.name == "limit" }?.value ?? "500") ?? 500
            let top = before > 0 ? before - 1 : n
            let lo = max(1, top - limit + 1)
            let page = top >= 1 ? (lo...top).map(message) : []
            return (200, Data(ChatJSON.encode(.array(page))))
        }
    }

    func testPagingPastFiveHundredAndTheWindow() throws {
        let room = FakeRoom(1200)
        let all = try ChatExport.messages(room: "room1", since: nil, until: nil, fetch: room.fetch)
        XCTAssertEqual(all.count, 1200, "no cap")
        XCTAssertEqual(all.first?.field("content")?.stringValue, "message 1", "oldest first")
        XCTAssertEqual(all.last?.field("content")?.stringValue, "message 1200")
        XCTAssertEqual(room.asked.count, 3)
        room.asked = []
        let window = try ChatExport.messages(room: "room1", since: room.t0 + 600, until: room.t0 + 1199, fetch: room.fetch)
        XCTAssertEqual(window.count, 600)
        XCTAssertEqual(window.first?.field("content")?.stringValue, "message 600")
        XCTAssertEqual(window.last?.field("content")?.stringValue, "message 1199")
        XCTAssertEqual(room.asked.count, 2, "it stops paging once a page starts before --since")
    }

    func testTheExportFolderItsFilesAndAttachments() throws {
        let room = FakeRoom(600)
        room.attachEvery = 200
        room.files[String(format: "%032x", 200)] = Data("two hundred".utf8)
        room.files[String(format: "%032x", 400)] = Data("four hundred".utf8)       // 600's is gone: a 404, listed
        let store = DozableStore(root: URL(fileURLWithPath: root + "/store"))
        let folder = try ExportFolder(root + "/out", store: store)
        let m = try ChatExport.write(room: "room1", since: nil, until: nil, into: folder, sweep: ExportSweep(tokenHashes: [:]), fetch: room.fetch)
        XCTAssertEqual(m.count, 600)
        XCTAssertEqual(m.firstSeq, 1)
        XCTAssertEqual(m.lastSeq, 600)
        XCTAssertEqual(m.sweep.redacted, 0)
        let jsonl = try String(contentsOfFile: root + "/out/room1.jsonl", encoding: .utf8)
        XCTAssertEqual(jsonl.split(separator: "\n").count, 600)
        XCTAssertEqual(try String(contentsOfFile: root + "/out/attachments/\(String(format: "%032x", 200))/note 200.txt", encoding: .utf8), "two hundred")
        XCTAssertEqual(m.missing?.map(\.why), ["gone (404)"])
        var st = stat()
        XCTAssertEqual(lstat(root + "/out", &st), 0); XCTAssertEqual(st.st_mode & 0o777, 0o700)
        XCTAssertEqual(lstat(root + "/out/room1.jsonl", &st), 0); XCTAssertEqual(st.st_mode & 0o777, 0o600)
        XCTAssertEqual(lstat(root + "/out/attachments", &st), 0); XCTAssertEqual(st.st_mode & 0o777, 0o700)
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: root + "/out/manifest.json"))) as? [String: Any]
        XCTAssertEqual(manifest?["version"] as? Int, 1)
        XCTAssertEqual((manifest?["files"] as? [Any])?.count, 3)
    }

    func testAPlantedTokenNeverReachesTheExport() throws {
        let token = ChatTokens.make()
        final class Planted: @unchecked Sendable {
            let token: String
            init(_ t: String) { token = t }
            func fetch(_ target: String) throws -> (status: Int, body: Data) {
                (200, Data(ChatJSON.encode(.array([.map(["seq": .int(1), "at": .double(1), "from": .string("bot1"),
                                                         "content": .string("my token is \(token)")])]))))
            }
        }
        let store = DozableStore(root: URL(fileURLWithPath: root + "/store"))
        let m = try ChatExport.write(room: "room1", since: nil, until: nil, into: try ExportFolder(root + "/out", store: store),
                                     sweep: ExportSweep(tokenHashes: ["bot1": ChatSecrets.hash(token)]), fetch: Planted(token).fetch)
        XCTAssertEqual(m.sweep.redacted, 1)
        XCTAssertEqual(m.sweep.findings.first?.participant, "bot1")
        for f in try FileManager.default.subpathsOfDirectory(atPath: root + "/out") {
            XCTAssertFalse((try? String(contentsOfFile: root + "/out/" + f, encoding: .utf8))?.contains(token) ?? false, f)
        }
    }

    func testTheFolderRules() throws {
        let store = DozableStore(root: URL(fileURLWithPath: root + "/store"))
        XCTAssertThrowsError(try ExportFolder(root + "/store/exports", store: store), "never inside the store")
        try FileManager.default.createDirectory(atPath: root + "/full", withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: root + "/full/x", contents: Data())
        XCTAssertThrowsError(try ExportFolder(root + "/full", store: store), "never a folder that holds anything")
        try FileManager.default.createDirectory(atPath: root + "/real", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: root + "/link", withDestinationPath: root + "/real")
        XCTAssertThrowsError(try ExportFolder(root + "/link", store: store), "never through a link")
        let f = try ExportFolder(root + "/new", store: store)
        try f.write("a.txt", Array("x".utf8))
        XCTAssertThrowsError(try f.write("a.txt", Array("y".utf8)), "never written over")
        XCTAssertThrowsError(try f.write("../escape", Array("y".utf8)))
    }

    func testTimesAPersonWrites() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(ChatTime.parse("2026-11-20T09:00:00Z", now: now), 1_795_165_200)
        XCTAssertEqual(ChatTime.parse("2026-11-20", now: now), 1_795_132_800)
        XCTAssertEqual(ChatTime.parse("1795165200", now: now), 1_795_165_200)
        XCTAssertEqual(ChatTime.parse("30m", now: now), 1_800_000_000 - 1800)
        XCTAssertEqual(ChatTime.parse("2h", now: now), 1_800_000_000 - 7200)
        XCTAssertEqual(ChatTime.parse("7d", now: now), 1_800_000_000 - 604_800)
        XCTAssertNil(ChatTime.parse("yesterday", now: now))
        XCTAssertNil(ChatTime.parse("", now: now))
    }
}
