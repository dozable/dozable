import Foundation
import XCTest
@testable import DozableHost

/// Finish closes the room (the closed set handed to the chat server, its answer the run's end), reopen opens it; a finish's
/// plan shows each room's row and the owner's line; room archive and rm: owned only (or loose with --loose), never linked,
/// never while a run is open, rm only after a copy that verifies now and with the name typed; a tombstone with its five fields.
extension WorkspaceLifecycleHostTests {
    func room(_ c: HostCore, _ op: HostOp, _ room: String, _ edit: (inout ChatRoomRequest) -> Void = { _ in }) async -> HostMessage {
        var q = ChatRoomRequest(room: room)
        edit(&q)
        var r = HostRequest(op)
        r.chatRoom = q
        return await c.handle(r)
    }

    func roomPlan(_ c: HostCore, _ verb: String, _ name: String, loose: Bool = false) async throws -> ChatRoomPlan {
        let m = await room(c, .chatRoomPlan, name) { $0.verb = verb; $0.loose = loose ? true : nil }
        XCTAssertNil(m.error, m.error?.message ?? "")
        return try XCTUnwrap(m.result).decode(ChatRoomPlan.self)
    }

    func testFinishClosesTheRoomAndReopenOpensIt() async throws {
        let c = await lcore()
        try await started(c)
        let p = try await plan(c, .finish)
        XCTAssertEqual(p.rooms, [WorkspaceLifecycleRoomRow(room: "demo", label: "main", owned: true, after: "closed: members can read it, posts refused (space-down)")])
        XCTAssertTrue(p.notes.contains(WorkspaceLifecycle.closesNote))
        rooms.otherPost("demo")
        _ = try ok(try await act(c, .finish))
        XCTAssertEqual(rooms.closedSets.last, ["demo": "demo"])
        XCTAssertEqual(try XCTUnwrap(record()).runs.last?.rooms.first?.toSeq, 2, "the close's answer is the run's end")
        XCTAssertTrue(log().contains("room-closed"))
        // The archive is refused while the run is open; after finish it may be archived. Reopen opens the room.
        _ = try ok(try await act(c, .reopen))
        XCTAssertEqual(rooms.closedSets.last, [:])
        XCTAssertTrue(log().contains("room-opened"))
        let refused = try await roomPlan(c, "archive", "demo")
        XCTAssertTrue(refused.refusals.contains { $0.contains("run") && $0.contains("is open") }, "\(refused.refusals)")
    }

    func testALinkedRoomIsNotClosed() async throws {
        let c = await lcore()
        rooms.roomSet.insert("shared")
        var m = await ws(c, .workspaceNew, "linked") { $0.brief = "x\n"; $0.room = "shared" }
        XCTAssertNil(m.error, m.error?.message ?? "")
        m = await ws(c, .workspaceStart, "linked")
        XCTAssertNil(m.error, m.error?.message ?? "")
        let p = try await plan(c, .finish, "linked")
        XCTAssertEqual(p.rooms?.first?.after, "linked: not closed")
        XCTAssertFalse(p.notes.contains(WorkspaceLifecycle.closesNote))
        _ = try ok(try await act(c, .finish, "linked"))
        XCTAssertNil(rooms.closedSets.last?["shared"])
        let plan = try await roomPlan(c, "archive", "shared")
        XCTAssertTrue(plan.refusals.contains { $0.contains("linked") }, "\(plan.refusals)")
        let loose = try await roomPlan(c, "rm", "shared", loose: true)
        XCTAssertTrue(loose.refusals.contains { $0.contains("linked") }, "--loose never takes a linked room")
    }

    func testRoomArchiveThenRemove() async throws {
        let c = await lcore()
        try await started(c)
        _ = try ok(try await act(c, .finish))
        // Its state now: closed. rm before an archive: refused.
        var p = try await roomPlan(c, "rm", "demo")
        XCTAssertEqual(p.state, "closed")
        XCTAssertTrue(p.refusals.contains { $0.contains("not archived") }, "\(p.refusals)")
        // Archive: the whole history copied, verified, then archived as you.
        p = try await roomPlan(c, "archive", "demo")
        XCTAssertEqual(p.refusals, [])
        XCTAssertEqual(p.owner, "demo")
        var a = await room(c, .chatRoomArchive, "demo") { $0.ifPlan = p.sha }
        XCTAssertNil(a.error, a.error?.message ?? "")
        let archived = try XCTUnwrap(a.result).decode(ChatRoomChanged.self)
        let path = try XCTUnwrap(archived.archive)
        XCTAssertTrue(path.hasPrefix("archives/demo/rooms/demo-rm_"))
        XCTAssertTrue(RunArchive.verify(root: WorkspaceStore.resolved(store.root.path) + "/" + path).ok)
        XCTAssertTrue(rooms.archived.contains("demo"))
        // Someone wrote since (unarchive, post, archive again): rm is refused "changed since it was archived".
        rooms.otherPost("demo")
        p = try await roomPlan(c, "rm", "demo")
        XCTAssertTrue(p.refusals.contains { $0.contains("changed since it was archived") }, "\(p.refusals)")
        p = try await roomPlan(c, "archive", "demo")
        XCTAssertEqual(p.refusals, [])
        // Archived again: a copy of its own beside the first (which is kept).
        a = await room(c, .chatRoomArchive, "demo") { $0.ifPlan = p.sha }
        XCTAssertNil(a.error, a.error?.message ?? "")
        let second = try XCTUnwrap(try XCTUnwrap(a.result).decode(ChatRoomChanged.self).archive)
        XCTAssertNotEqual(second, path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: WorkspaceStore.resolved(store.root.path) + "/" + path), "the first copy is kept")
        let indexed = await roomIndexArchive()
        XCTAssertEqual(indexed, second)
        // rm: the name typed, checked by the daemon.
        p = try await roomPlan(c, "rm", "demo")
        XCTAssertEqual(p.refusals, [])
        XCTAssertEqual(p.archiveVerified, true)
        var r = await room(c, .chatRoomRm, "demo") { $0.ifPlan = p.sha; $0.confirm = "dem" }
        XCTAssertEqual(r.error?.code, .invalid, "the wrong name: nothing removed")
        XCTAssertTrue(rooms.removed.isEmpty)
        r = await room(c, .chatRoomRm, "demo") { $0.ifPlan = p.sha; $0.confirm = "demo" }
        XCTAssertNil(r.error, r.error?.message ?? "")
        let gone = try XCTUnwrap(r.result).decode(ChatRoomChanged.self)
        XCTAssertEqual(rooms.removed.first?.room, "demo")
        let t = try XCTUnwrap(gone.tombstone)
        XCTAssertEqual(t.name, "demo")
        XCTAssertTrue(ChatRoomIndex.isID(t.id))
        XCTAssertEqual(t.owner, "demo")
        XCTAssertFalse(t.archive.isEmpty)
        XCTAssertNotNil(try XCTUnwrap(record()).rooms.first?.goneAt)
        XCTAssertTrue(log().contains("room-removed"))
        // Its plan now says gone.
        rooms.ready = .ready
        let after = try await roomPlan(c, "archive", "demo")
        XCTAssertTrue(after.refusals.contains { $0.contains("gone") }, "\(after.refusals)")
    }

    func roomIndexArchive() async -> String? { (try? ChatRoomIndex.load(ChatPaths(store: store)))?.rooms["demo"]?.archive?.path }

    func testALooseRoomOnlyWithLoose() async throws {
        let c = await lcore()
        rooms.roomSet.insert("old-room")
        rooms.otherPost("old-room")
        var p = try await roomPlan(c, "archive", "old-room")
        XCTAssertTrue(p.refusals.contains { $0.contains("--loose") }, "\(p.refusals)")
        p = try await roomPlan(c, "archive", "old-room", loose: true)
        XCTAssertEqual(p.refusals, [])
        var a = await room(c, .chatRoomArchive, "old-room") { $0.ifPlan = p.sha; $0.loose = true }
        XCTAssertNil(a.error, a.error?.message ?? "")
        XCTAssertTrue(try XCTUnwrap(a.result).decode(ChatRoomChanged.self).archive?.hasPrefix("archives/_/rooms/old-room-") == true)
        p = try await roomPlan(c, "rm", "old-room", loose: true)
        XCTAssertEqual(p.refusals, [])
        a = await room(c, .chatRoomRm, "old-room") { $0.ifPlan = p.sha; $0.loose = true; $0.confirm = "old-room" }
        XCTAssertNil(a.error, a.error?.message ?? "")
        XCTAssertNil(try XCTUnwrap(a.result).decode(ChatRoomChanged.self).tombstone?.owner)
    }

    func testAReadOnlyCoreSaysTheLastSeqIsNotKnown() async throws {
        let ro = await lcore(readOnly: true)
        let p = try await roomPlan(ro, "rm", "demo")
        XCTAssertNil(p.lastSeq)
        XCTAssertFalse(p.refusals.isEmpty, "the most cautious answer")
    }
}

/// Discarding a conversation file: only while it is the archived bytes, through one descriptor, never a link or another file.
final class TranscriptDiscardTests: XCTestCase {
    var dir = ""
    override func setUpWithError() throws {
        dir = WorkspaceStore.resolved("/tmp") + "/dzc-discard-\(getpid())-\(UUID().uuidString.prefix(6))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(atPath: dir) }

    func file(_ name: String, _ text: String) throws -> (String, String) {
        let p = dir + "/" + name
        try Data(text.utf8).write(to: URL(fileURLWithPath: p))
        return (p, TranscriptCopy.sha256(Data(text.utf8)))
    }

    func testOnlyAnUnchangedFileGoes() throws {
        let (a, sha) = try file("a.jsonl", "{}\n")
        let (other, _) = try file("other.jsonl", "{}\n")
        XCTAssertEqual(TranscriptDiscard.remove(a, sha256: sha), .removed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: a))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other), "another session's file is untouched")
        // Appended since it was archived: kept.
        let (b, bsha) = try file("b.jsonl", "{}\n")
        try Data("{}\n{}\n".utf8).write(to: URL(fileURLWithPath: b))
        XCTAssertEqual(TranscriptDiscard.remove(b, sha256: bsha), .kept("changed since it was archived"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: b))
        // A link is refused, and so is a link in the path and a hard link.
        try FileManager.default.createSymbolicLink(atPath: dir + "/l.jsonl", withDestinationPath: other)
        XCTAssertEqual(TranscriptDiscard.remove(dir + "/l.jsonl", sha256: sha), .kept("a link — refused"))
        try FileManager.default.createDirectory(atPath: dir + "/real", withIntermediateDirectories: true)
        let (inner, isha) = try file("real/x.jsonl", "{}\n")
        try FileManager.default.createSymbolicLink(atPath: dir + "/via", withDestinationPath: dir + "/real")
        XCTAssertEqual(TranscriptDiscard.remove(dir + "/via/x.jsonl", sha256: isha), .kept("a link in its path — not followed"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: inner))
        XCTAssertEqual(link(other, dir + "/hard.jsonl"), 0)
        XCTAssertEqual(TranscriptDiscard.remove(other, sha256: sha), .kept("a hard link (2 names) — refused"))
        // A folder is never removed.
        XCTAssertEqual(TranscriptDiscard.remove(dir + "/real", sha256: sha), .kept("not a regular file"))
    }

    func testTargetsAreOnlyTheSessionsArchivedFiles() {
        let n = "8f8f8f8f-1111-4222-8333-444455556666.jsonl"
        let files = [RunArchive.File(path: "transcripts/w1/20261120T010203Z-\(n)", sha256: "s", sourceSHA256: "A", bytes: 1, agent: "w1", source: "archive", session: "w1"),
                     RunArchive.File(path: "transcripts/w1/carried-\(n)", sha256: "s", sourceSHA256: "C", bytes: 1, agent: "w1", source: "carried", session: "w1"),
                     RunArchive.File(path: "transcripts/w2/\(n)", sha256: "s", sourceSHA256: "D", bytes: 1, agent: "w2", source: "conversation", session: "w2")]
        let own = [MacTranscripts.Item(name: n, endedAt: "", bytes: 0, path: "/h/p/\(n)", source: "carried", sha256: "C"),
                   MacTranscripts.Item(name: n, endedAt: "", bytes: 0, path: "/h/q/\(n)", source: "carried", sha256: "OTHER")]
        let t = TranscriptDiscard.targets(session: "w1", archived: files, keptRoot: "/s/kept", own: own)
        XCTAssertEqual(t.map(\.path), ["/s/kept/20261120T010203Z/\(n)", "/h/p/\(n)"], "a carried copy only when its recorded sha256 is the archive's")
    }
}
