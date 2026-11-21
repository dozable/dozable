import Foundation
import XCTest
@testable import DozableHost

/// `timeline.sqlite` filled from the primary records: every source's events appear with the contract's ids, scopes
/// nest (a sandbox under its workspace, a room by its id), the same ids come back after a reopen and a rebuild, a
/// removed-and-remade workspace gets new ones, and no message text, question, key, folder or host reaches the text the
/// derived store answers from.
final class TimelineIndexerTests: XCTestCase {
    var fx: TimelineFixture!
    override func setUpWithError() throws { fx = try TimelineFixture(tag: "ix") }
    override func tearDown() { fx.remove() }

    func ids(_ ix: TimelineIndexer) throws -> Set<String> {
        let t = try TimelineStore(url: ix.url, readOnly: true)
        return Set(try t.db.rows("SELECT id FROM events").compactMap { $0[0].text })
    }

    func testEverySourceIsIndexedWithTheContractsIds() throws {
        try fx.fill()
        let ix = TimelineIndexer(store: fx.store)
        ix.catchUpNow()
        let all = try ids(ix)
        for id in ["daemon/1", "daemon/1/start", "actions/1", "actions/2", "actions/3", "sessions/1", "sessions/1/open", "sessions/1/end",
                   "daemon-events/1", "egress/1", "egress/2", "keys/1", "chat/msg_1", "chat/msg_1/bot1/delivered", "ask/#12", "ask/#12/decided",
                   "runs/example-space/2026-11-20-1", "runs/example-space/2026-11-20-1/close", "runs/example-space/2026-11-20-1/000001"] {
            XCTAssertTrue(all.contains(id), id)
        }
        let created = Int64((fx.at(1).timeIntervalSince1970 * 1000).rounded())
        XCTAssertTrue(all.contains { $0.hasPrefix("workspace/example-space@\(created)/") })
        XCTAssertTrue(all.contains { $0.hasPrefix("grants/_@") })
        // The permission line of the workspace log is the grants source's, not counted twice.
        let t = try TimelineStore(url: ix.url, readOnly: true)
        XCTAssertEqual(try t.db.scalar("SELECT COUNT(*) FROM events WHERE source = 'workspace' AND kind = 'workspace.granted'").int, 0)
        // Scopes: the sandbox under the workspace that holds it; the room by its id under its one workspace.
        let scope = try t.db.scalar("SELECT scope FROM events WHERE id = 'actions/1'").text
        XCTAssertEqual(scope, "workspace:example-space/sandbox:build-vm")
        let room = try XCTUnwrap(try t.db.scalar("SELECT scope FROM events WHERE id = 'chat/msg_1'").text)
        XCTAssertTrue(room.hasPrefix("workspace:example-space/room:rm_"), room)
        XCTAssertEqual(try t.db.scalar("SELECT label FROM scopes WHERE scope = ?", [.text(room)]).text, "team")
        XCTAssertEqual(try t.db.scalar("SELECT scope FROM events WHERE id = 'sessions/1'").text, "workspace:example-space/sandbox:build-vm/session:claude~1")
        // The owner is "you"; the session's program its basename.
        XCTAssertTrue(try t.db.scalar("SELECT attrs FROM events WHERE id = 'chat/msg_1'").text!.contains(#""from":"you""#))
        XCTAssertTrue(try t.db.scalar("SELECT attrs FROM events WHERE id = 'sessions/1'").text!.contains(#""program":"claude""#))
        // Rollups: the network minute and the samples.
        XCTAssertEqual(try t.db.scalar("SELECT sum FROM rollups WHERE series = 'net.allowed'").real, 3)
        XCTAssertEqual(try t.db.scalar("SELECT sum FROM rollups WHERE series = 'cpu'").real, 12.5)
        XCTAssertEqual(try t.db.scalar("SELECT sum FROM rollups WHERE series = 'egress.denied'").real, 1)
    }

    func testNoTextQuestionKeyFolderOrHostReachesWhatIsSearchedOrShown() throws {
        try fx.fill()
        let ix = TimelineIndexer(store: fx.store)
        ix.catchUpNow()
        try? TimelineStore(url: ix.url).db.exec("PRAGMA wal_checkpoint(TRUNCATE)")
        let bytes = fx.derivedBytes()
        XCTAssertFalse(bytes.contains(TimelineFixture.text), "message text")
        XCTAssertFalse(bytes.contains("SENTINEL QUESTION"), "an Ask's question")
        XCTAssertFalse(bytes.contains(TimelineFixture.keyValue), "a key's value")
        XCTAssertFalse(bytes.contains("/v1/"), "a request's path")
        let t = try TimelineStore(url: ix.url, readOnly: true)
        for col in ["hay", "summary", "attrs"] {
            let leaks = try t.db.scalar("SELECT COUNT(*) FROM events WHERE instr(lower(\(col)), lower(?)) > 0 OR instr(\(col), ?) > 0 OR instr(\(col), ?) > 0",
                                        [.text(TimelineFixture.host), .text(TimelineFixture.folder), .text("sentinel-account")]).int
            XCTAssertEqual(leaks, 0, col)
        }
        XCTAssertEqual(try t.db.scalar("SELECT COUNT(*) FROM rollups WHERE instr(scope, 'sentinel') > 0 OR instr(series, 'sentinel') > 0").int, 0)
        // The host IS kept, as a sensitive attr only.
        XCTAssertTrue(try t.db.scalar("SELECT sattrs FROM events WHERE id = 'egress/1'").text!.contains(TimelineFixture.host))
        // The file is the owner's alone.
        var st = stat()
        XCTAssertEqual(lstat(ix.url.path, &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o600)
    }

    func testTheSameIdsAfterAReopenAndARebuild() throws {
        try fx.fill()
        let ix = TimelineIndexer(store: fx.store)
        ix.catchUpNow()
        let first = try ids(ix)
        // Reopen: a new indexer (a daemon restart) adds nothing and loses nothing.
        let again = TimelineIndexer(store: fx.store)
        again.catchUpNow()
        XCTAssertEqual(try ids(again), first)
        // Rebuild: the file deleted is made again with the same ids.
        for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: ix.url.path + s) }
        let rebuilt = TimelineIndexer(store: fx.store)
        rebuilt.catchUpNow()
        XCTAssertEqual(try ids(rebuilt), first)
    }

    func testARemovedAndRemadeWorkspaceGetsNewIds() throws {
        try fx.fill()
        let ix = TimelineIndexer(store: fx.store)
        ix.catchUpNow()
        let before = try ids(ix).filter { $0.hasPrefix("workspace/") }
        let ws = WorkspaceStore(store: fx.store)
        let rec = try XCTUnwrap(try ws.read("example-space"))
        try ws.remove("example-space")
        var again = rec
        again.createdAt = fx.at(1000)
        again.runs = []
        try ws.create(again, brief: Data("b".utf8), log: [WorkspaceLogEntry(at: fx.at(1000), action: "created")])
        ix.catchUpNow()
        let after = try ids(ix).filter { $0.hasPrefix("workspace/") }
        XCTAssertTrue(before.isSubset(of: after), "history is kept")
        XCTAssertEqual(after.count, before.count + 1, "the new workspace's first line is a new id")
    }

    func testAnOpenActionIsReadAgainUntilItCloses() throws {
        let m = try fx.fill()
        let ix = TimelineIndexer(store: fx.store)
        let run = m.beginRun(.init(kind: "doz host", appVersion: "1", build: "1", machine: "m", chip: "c", macOS: "x"), at: fx.at(600))
        let id = m.begin(run: run, action: "stop", sandbox: "build-vm", image: "pi", phaseBefore: "running", startedAt: fx.at(601))
        ix.catchUpNow()
        let t = try TimelineStore(url: ix.url, readOnly: true)
        XCTAssertEqual(try t.db.scalar("SELECT open FROM events WHERE id = 'actions/\(id)'").int, 1)
        XCTAssertEqual(try t.db.scalar("SELECT open FROM events WHERE id = 'daemon/1'").int, 0, "an earlier daemon run's span is closed by the next")
        m.finish(id, phaseAfter: "off", durationMs: 900, ok: true)
        ix.catchUpNow()
        XCTAssertEqual(try t.db.scalar("SELECT open FROM events WHERE id = 'actions/\(id)'").int, 0)
        XCTAssertEqual(try t.db.scalar("SELECT kind FROM events WHERE id = 'actions/\(id)'").text, "action.ok")
    }
}
