import Darwin
import DozableChat
import Foundation
import XCTest

/// Importing another chat server's history (`ChatImport`): a copy made by that server's own copy script is read without
/// trust, staged in this server's format, and the first start after it wakes nobody.
///
/// `Fixtures/import1/` was made by the workspace's probe `make-import-fixture.py` with the reference server (v0.13.2) and
/// finished by its own `copy-data-for-import.sh`, with neutral names: ada the human; bot1 a grok-bot delivered to by
/// webhook (a listener the probe ran), with one message to it left `queued` (its first try failed, the copy was made
/// before the next); bot2 a claude-session with no running session (every hand-over to it failed); room1 and room2
/// (archived); a hold of 2 with one message held for bot2; bot1's avatar, bot2's session link, one attachment.
///
/// Every hostile copy is built here in a scratch folder from that fixture and must be refused — nothing written, the copy
/// unchanged.
final class ChatImportTests: XCTestCase {
    var scratch = ""

    override func setUpWithError() throws {
        scratch = "/tmp/dzi-\(getpid())-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // A test may leave a folder it made read-only or a link: remove what is ours, never follow a link out.
        try? FileManager.default.removeItem(atPath: scratch)
    }

    static func fixture(_ name: String) throws -> String {
        guard let u = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures") else { throw XCTSkip("no fixture \(name)") }
        return u.path
    }

    /// A fresh copy of the import fixture in the scratch folder.
    func makeCopy(_ name: String = "copy") throws -> String {
        let dst = scratch + "/" + name
        try FileManager.default.copyItem(atPath: try Self.fixture("import1"), toPath: dst)
        return dst
    }

    func sql(_ db: String, _ statements: String) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        p.arguments = [db, statements]
        p.standardOutput = FileHandle.nullDevice
        let err = Pipe()
        p.standardError = err
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 { throw XCTSkip("sqlite3: \(String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))") }
    }

    /// Every file of a folder (links included, never followed) with its bytes' hash and its mode.
    func tree(_ dir: String) -> [String: String] {
        var out: [String: String] = [:]
        let fm = FileManager.default
        guard let e = fm.enumerator(atPath: dir) else { return out }
        while let rel = e.nextObject() as? String {
            let p = dir + "/" + rel
            var st = stat()
            guard lstat(p, &st) == 0 else { continue }
            let kind = st.st_mode & S_IFMT
            var v = "mode \(st.st_mode) size \(st.st_size) mtime \(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec)"
            if kind == S_IFLNK { v += " -> " + ((try? fm.destinationOfSymbolicLink(atPath: p)) ?? "?") }
            if kind == S_IFREG, let d = fm.contents(atPath: p) { v += " " + String(d.hashValue) + " \(d.count)" }
            out[rel] = v
        }
        return out
    }

    /// The copy is refused, says why, and is left exactly as it was.
    func assertRefused(_ dir: String, _ why: String, file: StaticString = #filePath, line: UInt = #line) {
        let before = tree(dir)
        XCTAssertThrowsError(try ChatImport.read(dir), file: file, line: line) { e in
            guard let r = e as? ChatImportRefusal else { return XCTFail("not a refusal: \(e)", file: file, line: line) }
            XCTAssertTrue(r.description.contains(why), "\(r.description) — wanted \(why)", file: file, line: line)
        }
        XCTAssertEqual(tree(dir), before, "the copy is never changed", file: file, line: line)
    }

    func messages(_ path: String) throws -> [ChatStored] {
        let st = try ChatRoomStore(path: path)
        defer { st.close() }
        return try st.page(after: 0, before: 0, limit: 500).messages
    }

    // MARK: - The fixture

    func testTheFixtureReadsAsTheReferenceWroteIt() throws {
        let c = try ChatImport.read(try makeCopy())
        let s = c.summary
        XCTAssertEqual(s.rooms.map(\.name), ["room1", "room2"])
        XCTAssertEqual(s.rooms.map(\.messages), [12, 3])
        XCTAssertEqual(s.messages, 15)
        XCTAssertEqual(s.files, 1)
        XCTAssertEqual(s.rooms[0].members, ["ada", "bot1", "bot2"])
        XCTAssertEqual(s.rooms[0].hold, 2)
        XCTAssertEqual(s.rooms[0].held, 1)
        XCTAssertEqual(s.rooms[0].attachments, 1)
        XCTAssertTrue(s.rooms[1].archived)
        XCTAssertEqual(s.human, "ada")
        XCTAssertEqual(s.names, [ChatImportName(name: "bot1", kind: "grok-bot", webhook: true),
                                 ChatImportName(name: "bot2", kind: "claude-session", webhook: false)])
        XCTAssertEqual(s.waiting["bot1"], 1, "the webhook message left queued")
        XCTAssertNil(s.waiting["bot2"], "every hand-over to bot2 failed; its held message is not waiting")
        XCTAssertTrue(s.dropped.isEmpty, "\(s.dropped)")
        XCTAssertTrue(s.ignored.isEmpty, "\(s.ignored)")
    }

    /// Acceptance: every room, message, state and reaction intact; the one waiting message cancelled; files, member
    /// lists, archive, hold, avatar and session link kept; this build's protocol version written.
    func testStagingKeepsEveryRowAndCancelsOnlyWhatWaited() throws {
        let src = try makeCopy()
        let before = tree(src)
        let c = try ChatImport.read(src)
        let staging = scratch + "/staged"
        let staged = try ChatImport.stage(c, into: staging, human: "ada")
        XCTAssertEqual(staged.cancelled, ["bot1": 1])
        XCTAssertEqual(tree(src), before, "the copy is never changed")

        for room in ["room1", "room2"] {
            // The source read through a separate scratch copy (opening a store may add columns).
            let ref = scratch + "/ref-\(room).db"
            try FileManager.default.copyItem(atPath: src + "/rooms/\(room).db", toPath: ref)
            let want = try messages(ref), got = try messages(staging + "/rooms/\(room).db")
            XCTAssertEqual(got.count, want.count)
            for (g, w) in zip(got, want) {
                var g2 = g
                let added = g.states.filter { $0.state == "cancelled" && $0.detail == ChatImport.cancelDetail }
                g2.states.removeAll { $0.state == "cancelled" && $0.detail == ChatImport.cancelDetail }
                XCTAssertEqual(g2, w, "message \(g.seq) of \(room) reads back the same")
                if g.content == "@bot1 slow one" {
                    XCTAssertEqual(added.map(\.recipient), ["bot1"])
                } else {
                    XCTAssertTrue(added.isEmpty, "message \(g.seq): nothing else cancelled")
                }
            }
        }
        let fm = FileManager.default
        let ids = try fm.contentsOfDirectory(atPath: staging + "/files")
        XCTAssertEqual(ids.count, 1)
        XCTAssertEqual(fm.contents(atPath: staging + "/files/\(ids[0])/notes.txt"), fm.contents(atPath: src + "/files/\(ids[0])/notes.txt"))
        XCTAssertEqual(try String(contentsOfFile: staging + "/protocol-version", encoding: .utf8), ChatProtocol.version + "\n")
        for f in ["rooms.json", "archived.json", "holds.json", "avatars.json", "sessions.json"] {
            let a = try ChatJSON.parse(fm.contents(atPath: staging + "/" + f)!), b = try ChatJSON.parse(fm.contents(atPath: src + "/" + f)!)
            XCTAssertEqual(ChatJSON.encodeString(a), ChatJSON.encodeString(b), f)
        }
        // 0700 folders, 0600 files.
        for (rel, _) in tree(staging) {
            var st = stat()
            lstat(staging + "/" + rel, &st)
            XCTAssertEqual(st.st_mode & 0o077, 0, "\(rel) is the user's alone")
        }
        // The hold still holds bot2's message.
        let st = try ChatRoomStore(path: staging + "/rooms/room1.db")
        defer { st.close() }
        XCTAssertEqual(try st.held().map(\.1), ["bot2"])
        XCTAssertTrue(try st.pending().allSatisfy { $0.1 == "ada" }, "nothing waits for anyone but the human")
    }

    /// The first start after an import wakes nobody: no webhook call (the bot's listener is real and gets nothing), an
    /// empty receive for a participant that polls, no change line, no protocol announcement. The hold is released only
    /// when the human posts.
    func testTheFirstStartWakesNobody() throws {
        let c = try ChatImport.read(try makeCopy())
        let data = scratch + "/data"
        _ = try ChatImport.stage(c, into: data, human: "ada")
        let hook = try TestWebhookListener(answer: { _ in .status(200) })
        defer { hook.stop() }
        let json = """
            {"data_dir": "\(data)", "default_room": "general", "secrets_file_only": true, "require_tokens": true,
             "agent_addresses": ["127.0.0.0/8"],
             "participants": [{"name": "ada", "kind": "human", "deliver": "web"},
                              {"name": "bot1", "kind": "grok-bot", "deliver": "webhook", "webhook": "bot1"},
                              {"name": "bot2", "kind": "claude-session"}],
             "rooms": {"general": ["ada"]}}
            """
        let config = try ChatConfig.parse(Data(json.utf8))
        try config.check()
        let token = "bot2-token-0123456789abcdef"
        let sec = try ChatSecrets.parse(Data(#"{"version": 1, "tokens": {"bot2": "\#(token)"}, "webhooks": {"bot1": {"url": "\#(hook.url)", "header": ""}}}"#.utf8))
        let core = ChatServerCore(config: config, secrets: sec, release: "1.2.3", sessionsDir: scratch + "/no-sessions")
        defer { core.close() }
        core.load()
        XCTAssertEqual(core.redeliver(), 0, "nothing is handed over again")
        XCTAssertFalse(core.announceProtocol(), "the protocol version is this build's: no announcement")
        core.waitForAnnouncement(seconds: 1)
        XCTAssertEqual(core.roomNames(), ["general", "room1", "room2"])
        XCTAssertEqual(core.members("room1"), ["ada", "bot1", "bot2"], "membership kept")
        XCTAssertTrue(core.isArchived("room2"))
        let h = ChatPageHandler(core: core)
        let r = h.handle(ChatHTTPRequest(method: "GET", target: "/agent/receive", headers: ["authorization": "Bearer " + token], body: [], remoteIP: "127.0.0.1"))
        XCTAssertEqual(r.status, 200, r.text)
        XCTAssertEqual(try ChatJSON.parse(r.body).field("messages")?.arrayValue?.count, 0, "the poller's receive is empty")
        usleep(400_000)
        XCTAssertEqual(hook.calls.count, 0, "no webhook call")
        XCTAssertEqual(try core.messagePage(room: "room1", after: 0, before: 0, limit: 500, viewer: "").messages.count, 12, "no change line")
        XCTAssertEqual(try core.messagePage(room: "room2", after: 0, before: 0, limit: 500, viewer: "").messages.count, 3)

        // Releasing the hold is the human's own later act: bot2 gets the held message only then.
        var l = ChatLine()
        l.msgID = chatNewID(); l.type = "user"; l.hasBody = true; l.room = "room1"; l.content = "back again"; l.msgV = 1
        XCTAssertEqual(core.post(l, sender: "ada").state, "queued")
        let after = h.handle(ChatHTTPRequest(method: "GET", target: "/agent/receive", headers: ["authorization": "Bearer " + token], body: [], remoteIP: "127.0.0.1"))
        let items = try ChatJSON.parse(after.body).field("messages")?.arrayValue ?? []
        XCTAssertEqual(items.compactMap { $0.field("message")?.field("content")?.stringValue }, ["bot1 in a row 3", "back again"])
        let until = Date().addingTimeInterval(5)
        while hook.calls.isEmpty && Date() < until { usleep(20_000) }
        XCTAssertEqual(hook.calls.count, 1, "the new message, and only it, goes to the bot")
    }

    func testAnEarlierFileIdOf16HexComesAcross() throws {
        let src = try makeCopy()
        let old = try FileManager.default.contentsOfDirectory(atPath: src + "/files")[0]
        let id16 = "0123456789abcdef"
        try FileManager.default.moveItem(atPath: src + "/files/" + old, toPath: src + "/files/" + id16)
        try sql(src + "/rooms/room1.db", "UPDATE messages SET attachments=replace(attachments,'\(old)','\(id16)');")
        let c = try ChatImport.read(src)
        XCTAssertEqual(c.summary.files, 1)
        let staging = scratch + "/staged"
        _ = try ChatImport.stage(c, into: staging, human: "ada")
        XCTAssertEqual(FileManager.default.contents(atPath: staging + "/files/\(id16)/notes.txt"), Data("notes for room1\n".utf8))
        let m = try messages(staging + "/rooms/room1.db").first { !$0.attachments.isEmpty }
        XCTAssertEqual(m?.attachments.first?.field("url")?.stringValue, "/files/\(id16)/notes.txt", "old messages' links keep working")
    }

    /// The room file the reference wrote at an earlier release (Fixtures/room1.db), imported: every row reads back the same.
    func testAnOlderRoomFileImportsWithEveryRowIntact() throws {
        let src = scratch + "/old"
        try FileManager.default.createDirectory(atPath: src + "/rooms", withIntermediateDirectories: true)
        guard let db = Bundle.module.url(forResource: "room1", withExtension: "db", subdirectory: "Fixtures") else { throw XCTSkip("no fixture") }
        try FileManager.default.copyItem(atPath: db.path, toPath: src + "/rooms/room1.db")
        try Data(#"{"room1": ["ada", "bot1", "bot2"]}"#.utf8).write(to: URL(fileURLWithPath: src + "/rooms.json"))
        let c = try ChatImport.read(src)
        XCTAssertEqual(c.summary.human, "ada")
        XCTAssertEqual(c.summary.names.map(\.name), ["bot1", "bot2"])
        let staging = scratch + "/staged"
        _ = try ChatImport.stage(c, into: staging, human: "ada")
        try FileManager.default.copyItem(atPath: db.path, toPath: scratch + "/ref.db")
        let want = try messages(scratch + "/ref.db")
        let got = try messages(staging + "/rooms/room1.db").map { m -> ChatStored in
            var m = m; m.states.removeAll { $0.state == "cancelled" && $0.detail == ChatImport.cancelDetail }; return m
        }
        XCTAssertEqual(got, want)
        XCTAssertEqual(want.first?.from, "switchboard", "an older server's own lines are shown as they are")
    }

    // MARK: - What a real copy may hold and lack

    func testOnlyRoomsAndMemberListsAndFilesIsEnough() throws {
        let src = try makeCopy()
        for f in ["archived.json", "holds.json", "avatars.json", "sessions.json"] { try FileManager.default.removeItem(atPath: src + "/" + f) }
        let c = try ChatImport.read(src)
        XCTAssertEqual(c.summary.messages, 15)
        XCTAssertFalse(c.summary.rooms[1].archived)
        XCTAssertNil(c.summary.rooms[0].hold)
        let staging = scratch + "/staged"
        _ = try ChatImport.stage(c, into: staging, human: "ada")
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging + "/rooms.json"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging + "/holds.json"))
    }

    func testRoomAppsAndUnknownEntriesAreIgnoredAndListed() throws {
        let src = try makeCopy()
        try Data(#"{"room1": {"name": "Room One", "icon": "image", "ver": 1}}"#.utf8).write(to: URL(fileURLWithPath: src + "/apps.json"))
        try FileManager.default.createDirectory(atPath: src + "/appicons", withIntermediateDirectories: true)
        try Data([0x89, 0x50]).write(to: URL(fileURLWithPath: src + "/appicons/room1.png"))
        try FileManager.default.createDirectory(atPath: src + "/exports", withIntermediateDirectories: true)
        try Data("a log line\n".utf8).write(to: URL(fileURLWithPath: src + "/server.log"))
        let c = try ChatImport.read(src)
        XCTAssertEqual(c.summary.ignored.count, 4, "\(c.summary.ignored)")
        XCTAssertTrue(c.summary.ignored.contains { $0.hasPrefix("apps.json") } && c.summary.ignored.contains { $0.hasPrefix("appicons/") })
        let staging = scratch + "/staged"
        _ = try ChatImport.stage(c, into: staging, human: "ada")
        for f in ["apps.json", "appicons", "exports", "server.log"] { XCTAssertFalse(FileManager.default.fileExists(atPath: staging + "/" + f)) }
    }

    func testARoomFileWithNoMemberListComesAcrossWithTheHumanAlone() throws {
        let src = try makeCopy()
        try Data(#"{"room1": ["ada", "bot1", "bot2"]}"#.utf8).write(to: URL(fileURLWithPath: src + "/rooms.json"))
        let c = try ChatImport.read(src)
        XCTAssertEqual(c.summary.rooms.first { $0.name == "room2" }?.members, ["ada"])
        XCTAssertEqual(c.summary.rooms.first { $0.name == "room2" }?.noMemberList, true)
        XCTAssertTrue(c.summary.dropped.contains { $0.contains("room2") })
    }

    func testAnUnusedFileIsDroppedAndAnUnknownRoomsEntriesAreDropped() throws {
        let src = try makeCopy()
        let extra = "ffffffffffffffffffffffffffffffff"
        try FileManager.default.createDirectory(atPath: src + "/files/" + extra, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: URL(fileURLWithPath: src + "/files/\(extra)/x.txt"))
        try Data(#"{"room9": 3, "room1": 2}"#.utf8).write(to: URL(fileURLWithPath: src + "/holds.json"))
        try Data(#"{"bot1": "not:an:avatar!"}"#.utf8).write(to: URL(fileURLWithPath: src + "/avatars.json"))
        let c = try ChatImport.read(src)
        XCTAssertEqual(c.summary.files, 1)
        XCTAssertTrue(c.summary.dropped.contains { $0.contains(extra) })
        XCTAssertTrue(c.summary.dropped.contains { $0.contains("room9") })
        XCTAssertTrue(c.summary.dropped.contains { $0.contains("avatars.json: bot1") })
        let staging = scratch + "/staged"
        _ = try ChatImport.stage(c, into: staging, human: "ada")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging + "/files/" + extra))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging + "/avatars.json"))
    }

    // MARK: - Refused: secrets, a live folder, unsaved changes

    func testACopyHoldingSecretsIsRefused() throws {
        for s in ["secrets.json", "secrets.lock", "agents.json"] {
            let src = try makeCopy(s)
            try Data("{}".utf8).write(to: URL(fileURLWithPath: src + "/" + s))
            assertRefused(src, "it holds secrets (\(s))")
        }
        let src = try makeCopy("tls")
        try FileManager.default.createDirectory(atPath: src + "/tls", withIntermediateDirectories: true)
        assertRefused(src, "it holds secrets (tls)")
    }

    func testAFolderARunningServerHoldsIsRefused() throws {
        let src = try makeCopy()
        FileManager.default.createFile(atPath: src + "/server.lock", contents: Data())
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = ["-c", "import fcntl,sys,time; f=open(sys.argv[1],'r+'); fcntl.lockf(f, fcntl.LOCK_EX); print('locked', flush=True); time.sleep(30)", src + "/server.lock"]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        defer { p.terminate(); p.waitUntilExit() }
        _ = out.fileHandleForReading.availableData   // "locked"
        assertRefused(src, "a running chat server")
    }

    func testARoomFileWithChangesBesideItIsRefused() throws {
        let src = try makeCopy()
        try Data("wal".utf8).write(to: URL(fileURLWithPath: src + "/rooms/room1.db-wal"))
        assertRefused(src, "holds changes not yet in the room file")
        // An empty one (the mode change's leftover) is only listed.
        try Data().write(to: URL(fileURLWithPath: src + "/rooms/room1.db-wal"))
        XCTAssertTrue(try ChatImport.read(src).summary.ignored.contains("rooms/room1.db-wal"))
    }

    // MARK: - Refused: paths

    func testLinksAnywhereAreRefused() throws {
        let fm = FileManager.default
        var src = try makeCopy("l1")
        let id = try fm.contentsOfDirectory(atPath: src + "/files")[0]
        try fm.removeItem(atPath: src + "/files/\(id)/notes.txt")
        try fm.createSymbolicLink(atPath: src + "/files/\(id)/notes.txt", withDestinationPath: "/etc/hosts")
        assertRefused(src, "not a regular file (a link is refused)")

        src = try makeCopy("l2")
        try fm.moveItem(atPath: src + "/files/\(id)", toPath: scratch + "/elsewhere")
        try fm.createSymbolicLink(atPath: src + "/files/\(id)", withDestinationPath: scratch + "/elsewhere")
        assertRefused(src, "is a link")

        src = try makeCopy("l3")
        try fm.moveItem(atPath: src + "/rooms/room2.db", toPath: scratch + "/room2.db")
        try fm.createSymbolicLink(atPath: src + "/rooms/room2.db", withDestinationPath: scratch + "/room2.db")
        assertRefused(src, "is a link")

        src = try makeCopy("l4")
        try fm.removeItem(atPath: src + "/avatars.json")
        try fm.createSymbolicLink(atPath: src + "/avatars.json", withDestinationPath: "/etc/hosts")
        assertRefused(src, "a link is refused")

        src = try makeCopy("l5")
        try fm.createSymbolicLink(atPath: scratch + "/link", withDestinationPath: src)
        assertRefused(scratch + "/link", "is a link")

        src = try makeCopy("l6")
        try fm.moveItem(atPath: src + "/rooms", toPath: scratch + "/rooms-elsewhere")
        try fm.createSymbolicLink(atPath: src + "/rooms", withDestinationPath: scratch + "/rooms-elsewhere")
        assertRefused(src, "is a link")
    }

    func testOddAttachmentIdsAndNamesAreRefused() throws {
        let fm = FileManager.default
        var src = try makeCopy("a1")
        try fm.createDirectory(atPath: src + "/files/ABCDEF0123456789", withIntermediateDirectories: true)
        assertRefused(src, "is not an attachment id")

        src = try makeCopy("a2")
        try fm.createDirectory(atPath: src + "/files/..x", withIntermediateDirectories: true)
        assertRefused(src, "is not an attachment id")

        src = try makeCopy("a3")
        let id = try fm.contentsOfDirectory(atPath: src + "/files")[0]
        try fm.moveItem(atPath: src + "/files/\(id)/notes.txt", toPath: src + "/files/\(id)/..notes.txt")
        assertRefused(src, "is not a clean attachment name")

        src = try makeCopy("a4")
        try Data("y".utf8).write(to: URL(fileURLWithPath: src + "/files/\(id)/second.txt"))
        assertRefused(src, "an attachment is one file")

        for (n, bad) in [("../../etc/passwd", "is not clean"), ("/etc/passwd", "is not clean")] {
            src = try makeCopy("a5-\(bad.count)-\(n.count)")
            try sql(src + "/rooms/room1.db", "UPDATE messages SET attachments=replace(attachments,'\"name\":\"notes.txt\"','\"name\":\"\(n)\"');")
            assertRefused(src, bad)
        }
        src = try makeCopy("a6")
        try sql(src + "/rooms/room1.db", "UPDATE messages SET attachments=replace(attachments,'\"id\":\"\(id)\"','\"id\":\"../\(id)\"');")
        assertRefused(src, "is not 16 or 32 lower-case hex")

        src = try makeCopy("a7")
        try Data().write(to: URL(fileURLWithPath: src + "/files/\(id)/notes.txt"))
        assertRefused(src, "an attachment is 1 byte to")
    }

    func testBadRoomNamesAreRefused() throws {
        var src = try makeCopy("r1")
        try Data(#"{"Room 1": ["ada"]}"#.utf8).write(to: URL(fileURLWithPath: src + "/rooms.json"))
        assertRefused(src, "is not a room name")
        src = try makeCopy("r2")
        try FileManager.default.copyItem(atPath: src + "/rooms/room2.db", toPath: src + "/rooms/Room3.db")
        assertRefused(src, "is not a room name")
        src = try makeCopy("r3")
        try FileManager.default.copyItem(atPath: src + "/rooms/room2.db", toPath: src + "/rooms/..db")
        assertRefused(src, "is not a room name")
    }

    func testAnOversizedOrMalformedJSONFileIsRefused() throws {
        var src = try makeCopy("j1")
        try Data(#"{"bot1": ""#.utf8 + Data(repeating: 0x61, count: ChatImport.maxJSONBytes) + Data(#""}"#.utf8))
            .write(to: URL(fileURLWithPath: src + "/avatars.json"))
        assertRefused(src, "larger than 4 MiB")
        src = try makeCopy("j2")
        try Data(#"["room1"]"#.utf8).write(to: URL(fileURLWithPath: src + "/rooms.json"))
        assertRefused(src, "is not a JSON object")
        src = try makeCopy("j3")
        try Data(#"{"room1": ["ada"], "room1": ["ada", "bot1"]}"#.utf8).write(to: URL(fileURLWithPath: src + "/rooms.json"))
        assertRefused(src, "twice")
    }

    func testNamesThatCannotBeNamesHereAreRefusedNeverRewritten() throws {
        var src = try makeCopy("n1")
        try Data(#"{"room1": ["ada", "bot1", "Bot_9"], "room2": ["ada", "bot1"]}"#.utf8).write(to: URL(fileURLWithPath: src + "/rooms.json"))
        assertRefused(src, "names are never rewritten")
        src = try makeCopy("n2")
        try sql(src + "/rooms/room1.db", "UPDATE states SET recipient='chat' WHERE recipient='bot2';")
        assertRefused(src, "\"chat\"")
        src = try makeCopy("n3")
        try sql(src + "/rooms/room1.db", "UPDATE messages SET sender_info=replace(sender_info,'\"kind\":\"bot\"','\"kind\":\"human\"') WHERE sender='bot1';")
        assertRefused(src, "more than one person")
    }

    // MARK: - Refused: hostile room files

    func testAHostileSchemaIsRefused() throws {
        let cases: [(String, String)] = [
            ("CREATE TRIGGER t AFTER INSERT ON states BEGIN DELETE FROM messages; END;", "a trigger"),
            ("CREATE VIEW v AS SELECT * FROM messages;", "a view"),
            ("CREATE TABLE extra(x TEXT);", "an unknown table"),
            ("ALTER TABLE messages ADD COLUMN extra TEXT NOT NULL DEFAULT '';", "not the protocol's"),
            ("CREATE INDEX i ON messages(sender);", "an index the protocol does not make"),
            ("ALTER TABLE states RENAME COLUMN detail TO details;", "not the protocol's"),
        ]
        for (i, (stmt, why)) in cases.enumerated() {
            let src = try makeCopy("s\(i)")
            try sql(src + "/rooms/room1.db", stmt)
            assertRefused(src, why)
        }
        let src = try makeCopy("v")
        do { try sql(src + "/rooms/room2.db", "CREATE VIRTUAL TABLE vt USING rtree(id, a, b);") } catch { throw XCTSkip("no rtree in this sqlite3") }
        assertRefused(src, "virtual table")
    }

    func testACorruptedRoomFileIsRefused() throws {
        var src = try makeCopy("c1")
        let p = src + "/rooms/room1.db"
        var d = try Data(contentsOf: URL(fileURLWithPath: p))
        let page = 4096
        for i in (page * 2)..<(page * 2 + 600) { d[i] = UInt8(truncatingIfNeeded: i &* 31) }
        try d.write(to: URL(fileURLWithPath: p))
        assertRefused(src, "rooms/room1.db")

        src = try makeCopy("c2")
        try Data("not a database at all, just text".utf8).write(to: URL(fileURLWithPath: src + "/rooms/room1.db"))
        assertRefused(src, "not an SQLite file")
    }

    /// A history with asks (the reference's table `asks`, kind `ask`) comes across; an open ask is closed as expired on the
    /// staged copy (the server's decline, no cooldown, nobody told) and a closed one is kept as it was.
    func testAsksComeAcrossAndAnOpenOneIsExpired() throws {
        let src = try makeCopy("asks")
        let db = src + "/rooms/room1.db"
        let open = "11111111-1111-4111-8111-111111111111", done = "22222222-2222-4222-8222-222222222222"
        let ask = #"{"question":"Q?","questions":[{"id":"q1","question":"Q?","options":[{"id":"yes","label":"Yes"}],"multi":false,"min":1,"max":1,"free_text":false,"optional":false}],"deciders":["ada"],"digest":"abc","state":""}"#
        try sql(db, """
            CREATE TABLE IF NOT EXISTS asks(msg_id TEXT PRIMARY KEY, ask TEXT NOT NULL, state TEXT NOT NULL DEFAULT 'open', expires REAL NOT NULL DEFAULT 0,
              decision TEXT NOT NULL DEFAULT '', closed_at REAL NOT NULL DEFAULT 0, asker TEXT NOT NULL DEFAULT '',
              about TEXT NOT NULL DEFAULT '', declined INTEGER NOT NULL DEFAULT 0, no_decider INTEGER NOT NULL DEFAULT 0);
            INSERT INTO messages(msg_id,sender,recipients,content,at,kind) VALUES('\(open)','bot1','["ada"]','Q? plain',1,'ask'),('\(done)','bot1','["ada"]','Q? plain',2,'ask');
            INSERT INTO asks(msg_id,ask,state,expires,asker) VALUES('\(open)','\(ask)','open',9999999999,'bot1');
            INSERT INTO asks(msg_id,ask,state,decision,closed_at,asker,declined) VALUES('\(done)','\(ask)','decided','{"by":"ada","declined":true,"answers":[],"option":"decline","label":"Decline","at":3,"digest":"abc","via":"page"}',3,'bot1',1);
            """)
        let c = try ChatImport.read(src)
        let staging = scratch + "/staged-asks"
        let staged = try ChatImport.stage(c, into: staging, human: "ada")
        XCTAssertEqual(staged.asksExpired, 1)
        let st = try ChatRoomStore(path: staging + "/rooms/room1.db")
        defer { st.close() }
        let a = try XCTUnwrap(st.askOf(open))
        XCTAssertEqual(a.state, "expired")
        XCTAssertEqual(a.decision?.via, "expiry"); XCTAssertEqual(a.decision?.digest, "abc")
        XCTAssertNil(st.declinedSince("bot1", about: "", since: 3.5), "the import's expiry starts no cooldown")
        XCTAssertEqual(st.askOf(done)?.decision?.by, "ada")
        XCTAssertEqual(st.openAsks().count, 0)
    }

    func testAMessageWhoseJSONColumnsDoNotParseIsRefused() throws {
        var src = try makeCopy("m1")
        try sql(src + "/rooms/room1.db", "UPDATE messages SET recipients='[1,2' WHERE seq=2;")
        assertRefused(src, "recipients is not a list of names")
        src = try makeCopy("m2")
        try sql(src + "/rooms/room1.db", "UPDATE messages SET content=x'00ff' WHERE seq=2;")
        assertRefused(src, "the wrong type")
        src = try makeCopy("m3")
        try sql(src + "/rooms/room1.db", "UPDATE messages SET kind='app' WHERE seq=2;")
        assertRefused(src, "an unknown kind")
    }

    // MARK: - The data folder's history

    func testAFirstStartFolderHasNoHistoryAndAMessageIs() throws {
        let data = scratch + "/data"
        try FileManager.default.createDirectory(atPath: data + "/rooms", withIntermediateDirectories: true)
        let st = try ChatRoomStore(path: data + "/rooms/general.db")
        var ch = ChatStored.change(chatNewID(), from: ChatProtocol.systemName, content: "announced", at: chatNow())
        _ = try st.insert(&ch)
        st.close()
        XCTAssertFalse(ChatImport.hasHistory(data).history, "the server's own first line is no history")
        let st2 = try ChatRoomStore(path: data + "/rooms/general.db")
        var m = ChatStored(msgID: chatNewID(), from: "ada", content: "hi", at: chatNow())
        _ = try st2.insert(&m)
        st2.close()
        XCTAssertEqual(ChatImport.hasHistory(data).history, true)
        XCTAssertEqual(ChatImport.hasHistory(data).messages, 1)
    }
}
