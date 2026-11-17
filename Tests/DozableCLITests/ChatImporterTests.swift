import Darwin
import DozableChat
import Foundation
import XCTest
@testable import DozableHost

/// `doz chat import` under the daemon (`ChatImporter`, `ChatSupervisor.importCopy`) with the reference-built fixture
/// (`Tests/DozableChatTests/Fixtures/import1`, see `ChatImportTests`): names never rewritten, the person, the participants
/// that must exist first or come in without a token, the store's own history never merged, overwritten or deleted, refused
/// while chat is on, a dry run that writes nothing, and nothing written by any refusal.
final class ChatImporterTests: XCTestCase {
    var root: String!
    var paths: ChatPaths { ChatPaths(folder: root + "/chat") }

    static var fixture: String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("DozableChatTests/Fixtures/import1").path
    }

    override func setUpWithError() throws {
        root = "/tmp/dzc-imp-\(getpid())-\(UUID().uuidString.prefix(6))"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: Self.fixture, toPath: root + "/copy")
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(atPath: root) }

    var source: String { root + "/copy" }

    /// A store's chat with the human (or none) and these participants.
    func directory(human: String?, _ names: [(String, String)]) throws {
        try paths.ensureFolder()
        let d = ChatDirectory(human: human, participants: names.map { .init(name: $0.0, kind: $0.1, added: "2026-11-17T00:00:00Z") })
        try paths.write("directory.json", d.bytes())
    }

    /// Every file under the chat folder, with its size and modification time — but a room file's `-shm`, SQLite's
    /// shared-memory index, which reading the store's own room files (to see whether they hold history) touches.
    func snapshot() -> [String: String] {
        var out: [String: String] = [:]
        guard let e = FileManager.default.enumerator(atPath: paths.folder) else { return out }
        while let rel = e.nextObject() as? String {
            if rel.hasSuffix(".db-shm") { continue }
            var st = stat()
            lstat(paths.folder + "/" + rel, &st)
            out[rel] = "\(st.st_mode) \(st.st_size) \(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec)"
        }
        return out
    }

    func assertThrows(_ code: HostError.Code, _ text: String, _ f: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try f(), file: file, line: line) { e in
            guard let h = e as? HostError else { return XCTFail("\(e)", file: file, line: line) }
            XCTAssertEqual(h.code, code, h.message, file: file, line: line)
            XCTAssertTrue(h.message.contains(text), "\(h.message) — wanted \(text)", file: file, line: line)
        }
    }

    // MARK: names

    func testMissingParticipantsRefuseWithTheCommandsToAddThem() throws {
        try directory(human: nil, [])
        let before = snapshot()
        assertThrows(.notFound, "doz chat add bot1 --kind grok-bot --webhook --to-file bot1.token") {
            _ = try ChatImporter.run(paths: paths, source: source, addMissing: false, replace: false)
        }
        XCTAssertEqual(snapshot(), before, "nothing written")
        let (_, r) = try ChatImporter.plan(paths: paths, source: source, addMissing: false, replace: false, chatOn: false)
        XCTAssertEqual(r.addCommands, ["doz chat add bot1 --kind grok-bot --webhook --to-file bot1.token",
                                       "doz chat add bot2 --kind claude-session --to-file bot2.token"])
    }

    func testWithEveryoneThereItImportsAndNamesYou() throws {
        try directory(human: nil, [("bot1", "grok-bot"), ("bot2", "claude-session")])
        let r = try ChatImporter.run(paths: paths, source: source, addMissing: false, replace: false)
        XCTAssertTrue(r.imported)
        XCTAssertTrue(r.namesYou)
        XCTAssertEqual(r.human, "ada")
        XCTAssertEqual(r.cancelled, ["bot1": 1])
        XCTAssertNil(r.keptAs)
        let d = try ChatDirectory.load(paths)
        XCTAssertEqual(d.human, "ada")
        XCTAssertEqual(d.participants.map(\.name), ["bot1", "bot2"], "nobody added, nobody renamed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.data + "/rooms/room1.db"))
        XCTAssertEqual(try String(contentsOfFile: paths.data + "/protocol-version", encoding: .utf8), ChatProtocol.version + "\n")
        let rec = try JSONDecoder().decode(ChatImportRecord.self, from: Data(contentsOf: URL(fileURLWithPath: paths.folder + "/imported.json")))
        XCTAssertEqual(rec.messages, 15)
        XCTAssertEqual(rec.rooms.map(\.sha256?.count), [64, 64])
        XCTAssertNil(try? ChatTokenHashes.load(paths).sha256["ada"], "no token was made")
        // No staging folder is left behind.
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: paths.folder).contains { $0.hasPrefix(".import-") })
    }

    func testAddMissingAddsTokenlessParticipantsOfTheKindTheHistoryShows() throws {
        let r = try ChatImporter.run(paths: paths, source: source, addMissing: true, replace: false)
        XCTAssertEqual(r.added, ["bot1", "bot2"])
        let d = try ChatDirectory.load(paths)
        XCTAssertEqual(d.participants.map(\.name), ["bot1", "bot2"])
        XCTAssertEqual(d.participants.map(\.kind), ["grok-bot", "claude-session"])
        XCTAssertEqual(d.participants.map(\.deliver), [nil, nil], "no deliver: they cannot be called until set up")
        XCTAssertTrue((try ChatTokenHashes.load(paths)).sha256.isEmpty, "tokenless")
    }

    func testAStoreWhosePersonHasAnotherNameIsRefused() throws {
        try directory(human: "zed", [("bot1", "grok-bot"), ("bot2", "claude-session")])
        let before = snapshot()
        assertThrows(.failed, "names are never rewritten; this store's chat is yours as zed") {
            _ = try ChatImporter.run(paths: paths, source: source, addMissing: true, replace: true)
        }
        XCTAssertEqual(snapshot(), before, "nothing written")
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.data))
    }

    func testThePersonsNameAsAParticipantIsRefused() throws {
        try directory(human: nil, [("ada", "agent"), ("bot1", "grok-bot"), ("bot2", "claude-session")])
        assertThrows(.failed, "here ada is a participant, not you") {
            _ = try ChatImporter.run(paths: paths, source: source, addMissing: false, replace: false)
        }
    }

    // MARK: the store's own history

    func testHistoryIsNeverMergedAndReplaceKeepsItAside() throws {
        try directory(human: "ada", [("bot1", "grok-bot"), ("bot2", "claude-session")])
        _ = try ChatImporter.run(paths: paths, source: source, addMissing: false, replace: false)
        // A message after the import: now the store has history of its own.
        let st = try ChatRoomStore(path: paths.data + "/rooms/room1.db")
        var m = ChatStored(msgID: chatNewID(), from: "ada", content: "after the import", at: chatNow())
        _ = try st.insert(&m)
        st.close()
        let before = snapshot()
        assertThrows(.exists, "never merged or overwritten") {
            _ = try ChatImporter.run(paths: paths, source: source, addMissing: false, replace: false)
        }
        XCTAssertEqual(snapshot(), before, "the same copy again is refused, nothing written")

        let r = try ChatImporter.run(paths: paths, source: source, addMissing: false, replace: true, now: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(r.keptAs, paths.folder + "/data.before-import-20270115T080000Z")
        let kept = try ChatRoomStore(path: r.keptAs! + "/rooms/room1.db")
        XCTAssertTrue(try kept.page(after: 0, before: 0, limit: 500).messages.contains { $0.content == "after the import" }, "kept, never deleted")
        kept.close()
        let now = try ChatRoomStore(path: paths.data + "/rooms/room1.db")
        XCTAssertEqual(try now.page(after: 0, before: 0, limit: 500).messages.count, 12, "the copy again, as it was")
        now.close()
        // Once more in the same second: a second folder aside, the first untouched.
        let r2 = try ChatImporter.run(paths: paths, source: source, addMissing: false, replace: true, now: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(r2.keptAs, paths.folder + "/data.before-import-20270115T080000Z-2")
    }

    func testAFirstStartFolderIsPutAsideWithoutReplace() throws {
        try directory(human: "ada", [("bot1", "grok-bot"), ("bot2", "claude-session")])
        try FileManager.default.createDirectory(atPath: paths.data + "/rooms", withIntermediateDirectories: true)
        let st = try ChatRoomStore(path: paths.data + "/rooms/general.db")
        var ch = ChatStored.change(chatNewID(), from: ChatProtocol.systemName, content: "announced", at: chatNow())
        _ = try st.insert(&ch)
        st.close()
        let r = try ChatImporter.run(paths: paths, source: source, addMissing: false, replace: false)
        XCTAssertNotNil(r.keptAs)
        XCTAssertTrue(FileManager.default.fileExists(atPath: r.keptAs! + "/rooms/general.db"), "kept aside, never deleted")
    }

    func testARefusedCopyWritesNothing() throws {
        try directory(human: nil, [("bot1", "grok-bot"), ("bot2", "claude-session")])
        try Data("{}".utf8).write(to: URL(fileURLWithPath: source + "/agents.json"))
        let before = snapshot()
        assertThrows(.failed, "the copy is refused, nothing was written: not a copy made for import: it holds secrets (agents.json)") {
            _ = try ChatImporter.run(paths: paths, source: source, addMissing: true, replace: true)
        }
        XCTAssertEqual(snapshot(), before)
    }

    func testADryRunWritesNothing() throws {
        let (_, r) = try ChatImporter.plan(paths: paths, source: source, addMissing: false, replace: false, chatOn: false)
        XCTAssertEqual(r.problems.map(\.kind), ["missing"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.folder), "not even the chat folder is made")
        let (_, on) = try ChatImporter.plan(paths: paths, source: source, addMissing: true, replace: false, chatOn: true)
        XCTAssertEqual(on.problems.map(\.kind), ["chat-on"])
    }

    // MARK: only while chat is off

    func testRefusedWhileChatIsOn() async throws {
        try directory(human: "ada", [("bot1", "grok-bot"), ("bot2", "claude-session")])
        let fake = FakeChatProcesses()
        let box = SettingsBox()
        let b = box
        let sup = ChatSupervisor(paths: paths, executable: "/usr/bin/false", release: "0.0.0", processes: fake, environment: [:], readSettings: { b.get() })
        box.set(true)
        do { _ = try await sup.importCopy(source, addMissing: false, replace: false); XCTFail("imported while chat is on") } catch let e as HostError {
            XCTAssertEqual(e.code, .unavailable)
            XCTAssertTrue(e.message.contains("doz chat off first"))
        }
        // The setting off, but a server still holds the data folder.
        box.set(false)
        fake.lockHolder = 4242
        do { _ = try await sup.importCopy(source, addMissing: false, replace: false); XCTFail("imported beside a server") } catch let e as HostError {
            XCTAssertEqual(e.code, .unavailable)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.data))
        fake.lockHolder = nil
        let r = try await sup.importCopy(source, addMissing: false, replace: false)
        XCTAssertTrue(r.imported)
        XCTAssertEqual(fake.spawnCount, 0, "an import starts nothing")
    }
}
