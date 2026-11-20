import Foundation
import XCTest
@testable import DozableHost

/// Runs as data (`WorkspaceRuns`): ids unique per day in a record; a run's rooms from their last seq; the close's `toSeq`;
/// the legacy run of a record started before runs; ownership read from the log; the closed set; and the record keeping a
/// field this build does not know in a run and its rooms.
final class WorkspaceRunsTests: XCTestCase {
    let utc = TimeZone(identifier: "UTC")!
    let day = Date(timeIntervalSince1970: 1_795_000_000)   // 2026-11-18 UTC

    func rec(_ rooms: [WorkspaceRoom] = [WorkspaceRoom(label: "main", chatRoom: "demo", main: true)]) -> WorkspaceRecord {
        WorkspaceRecord(name: "demo", createdAt: day, brief: WorkspaceBrief(sha256: "x", bytes: 1, updatedAt: day), folders: [], rooms: rooms)
    }

    func testIDsAreUniquePerDayWithinTheRecord() {
        var runs: [WorkspaceRun] = []
        XCTAssertEqual(WorkspaceRuns.nextID(runs, at: day, timeZone: utc), "2026-11-18-1")
        runs.append(WorkspaceRun(id: "2026-11-18-1", startedAt: day))
        runs.append(WorkspaceRun(id: "2026-11-18-3", startedAt: day))   // a gap (another build, a hand edit): never reused
        XCTAssertEqual(WorkspaceRuns.nextID(runs, at: day, timeZone: utc), "2026-11-18-4")
        XCTAssertEqual(WorkspaceRuns.nextID(runs, at: day.addingTimeInterval(86_400), timeZone: utc), "2026-11-19-1")
        XCTAssertTrue(WorkspaceRuns.isValidID("2026-11-18-12"))
        for bad in ["2026-11-18", "../x", "2026-11-18-1/..", "2026-1-18-1", "", "2026-11-18-a"] { XCTAssertFalse(WorkspaceRuns.isValidID(bad), bad) }
    }

    func testOpenAndCloseCarryTheMarkersAsData() {
        var r = rec([WorkspaceRoom(label: "main", chatRoom: "demo", main: true, id: "rm_0000000000000001"),
                     WorkspaceRoom(label: "review", chatRoom: "demo-review", main: false)])
        r.rooms[1].goneAt = day   // a removed room is not part of a new run
        var run = WorkspaceRuns.open(r, at: day, lastSeq: ["demo": 7], timeZone: utc)
        XCTAssertEqual(run.rooms, [WorkspaceRunRoom(room: "demo", id: "rm_0000000000000001", fromSeq: 7)])
        XCTAssertTrue(run.isOpen)
        WorkspaceRuns.close(&run, at: day.addingTimeInterval(600), toSeq: ["demo": 12], by: "finish")
        XCTAssertEqual(run.rooms[0].toSeq, 12)
        XCTAssertEqual(run.closedBy, "finish")
        XCTAssertEqual(WorkspaceRuns.minutes(run), 10)
        // A close that saw a smaller seq than the start (a room emptied and made again) never ends before it began.
        var other = WorkspaceRuns.open(r, at: day, lastSeq: ["demo": 9], timeZone: utc)
        WorkspaceRuns.close(&other, at: day, toSeq: ["demo": 3], by: "finish")
        XCTAssertEqual(other.rooms[0].toSeq, 9)
    }

    func testALegacyRecordGetsItsImplicitRunAtItsNextFinish() {
        var r = rec()
        XCTAssertNil(WorkspaceRuns.legacyRun(r), "never started: no run")
        r.flags.startedAt = day
        let l = WorkspaceRuns.legacyRun(r, timeZone: utc)
        XCTAssertEqual(l?.legacy, true)
        XCTAssertEqual(l?.startedAt, day)
        XCTAssertEqual(l?.rooms.first?.fromSeq, 0, "the whole history up to now is its run")
        r.flags.finishedAt = day
        XCTAssertNil(WorkspaceRuns.legacyRun(r), "finished before runs were kept: never closed after the fact")
        r.flags.finishedAt = nil
        r.runs = [WorkspaceRun(id: "2026-11-18-1", startedAt: day)]
        XCTAssertNil(WorkspaceRuns.legacyRun(r), "a record with runs needs none")
    }

    func testOwnershipIsTheRecordsElseTheLogs() {
        let made = WorkspaceRoom(label: "main", chatRoom: "demo", main: true)
        XCTAssertTrue(WorkspaceRuns.owned(made, log: [WorkspaceLogEntry(action: "room-made", room: "demo")]))
        XCTAssertFalse(WorkspaceRuns.owned(made, log: [WorkspaceLogEntry(action: "room-linked", room: "demo")]))
        XCTAssertFalse(WorkspaceRuns.owned(made, log: []), "neither says: not owned")
        var o = made
        o.owned = false
        XCTAssertFalse(WorkspaceRuns.owned(o, log: [WorkspaceLogEntry(action: "room-made", room: "demo")]), "the record wins")
    }

    func testTheClosedSetIsWorkedOutFromTheRecords() {
        var finished = rec()
        finished.flags.finishedAt = day
        finished.runs = [WorkspaceRun(id: "2026-11-18-1", startedAt: day)]
        finished.runs[0].endedAt = day
        var linked = finished
        linked.name = "linked"
        linked.rooms = [WorkspaceRoom(label: "main", chatRoom: "shared", main: true, owned: false)]
        var old = rec()
        old.name = "old"
        old.rooms = [WorkspaceRoom(label: "main", chatRoom: "old", main: true, owned: true)]
        old.flags.finishedAt = day   // finished before runs: never closed after the fact
        var archived = finished
        archived.name = "arch"
        archived.rooms = [WorkspaceRoom(label: "main", chatRoom: "arch", main: true, owned: true)]
        archived.flags.archivedAt = day
        var asleep = rec()
        asleep.name = "zz"
        asleep.rooms = [WorkspaceRoom(label: "main", chatRoom: "zz", main: true, owned: true)]
        asleep.runs = [WorkspaceRun(id: "2026-11-18-1", startedAt: day)]
        let set = WorkspaceRuns.closedSet([finished, linked, old, archived, asleep]) { _, room in room.owned ?? true }
        XCTAssertEqual(set, ["demo": "demo"])
    }

    func testARunKeepsWhatThisBuildDoesNotKnow() throws {
        let json = """
        {"version":1,"name":"demo","createdAt":"2026-11-18T00:00:00Z","brief":{"refs":[],"sha256":"x","bytes":1,"updatedAt":"2026-11-18T00:00:00Z"},
         "rooms":[{"label":"main","chatRoom":"demo","main":true,"id":"rm_00000000000000aa","owned":true,"future":1}],
         "runs":[{"id":"2026-11-18-1","startedAt":"2026-11-18T00:00:00Z","rooms":[{"room":"demo","fromSeq":3,"toSeq":9,"later":"x"}],"newer":{"a":2}}]}
        """
        let r = try HostWire.decoder.decode(WorkspaceRecord.self, from: Data(json.utf8))
        XCTAssertEqual(r.runs.first?.rooms.first?.toSeq, 9)
        XCTAssertEqual(r.rooms.first?.id, "rm_00000000000000aa")
        let back = String(decoding: try HostWire.prettyEncoder.encode(r), as: UTF8.self)
        for k in ["\"future\" : 1", "\"later\" : \"x\"", "\"newer\"", "\"owned\" : true"] { XCTAssertTrue(back.contains(k), k) }
        // No runs: none written (a record of an older build is unchanged by a rewrite).
        let plain = String(decoding: try HostWire.prettyEncoder.encode(rec()), as: UTF8.self)
        XCTAssertFalse(plain.contains("\"runs\""))
    }
}

/// The room index: an id per room, a new id for a room made again under the same name, the owner recorded once, the
/// tombstone's five fields, 0600 on disk, an unknown field kept.
final class ChatRoomIndexTests: XCTestCase {
    func testIDsOwnersAndTombstones() throws {
        let dir = URL(fileURLWithPath: "/tmp/doz-ri-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = ChatPaths(folder: dir.path)
        var idx = try ChatRoomIndex.load(paths)
        XCTAssertTrue(idx.rooms.isEmpty)
        let a = idx.ensure("demo", owner: "demo")
        XCTAssertTrue(a.changed)
        XCTAssertTrue(ChatRoomIndex.isID(a.id))
        XCTAssertEqual(idx.ensure("demo", owner: "other").id, a.id, "the id stays; the owner is never changed once set")
        XCTAssertEqual(idx.rooms["demo"]?.owner, "demo")
        idx.ensure("loose")
        XCTAssertNil(idx.rooms["loose"]?.owner)
        idx.bury("demo", at: Date(timeIntervalSince1970: 1), run: "2026-11-18-1", archive: "archives/demo/runs/2026-11-18-1")
        XCTAssertNil(idx.rooms["demo"])
        let t = try XCTUnwrap(idx.tombstone("demo"))
        XCTAssertEqual([t.name, t.id, t.run ?? "", t.archive, t.owner ?? ""], ["demo", a.id, "2026-11-18-1", "archives/demo/runs/2026-11-18-1", "demo"])
        let b = idx.ensure("demo", owner: "demo")
        XCTAssertNotEqual(b.id, a.id, "a room made again under the same name is another room")
        try idx.write(paths)
        var st = stat()
        XCTAssertEqual(stat(ChatRoomIndex.path(paths), &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o600)
        // An unknown field is kept.
        var raw = try String(contentsOfFile: ChatRoomIndex.path(paths), encoding: .utf8)
        raw = raw.replacingOccurrences(of: "\"version\"", with: "\"later\" : [1],\n  \"version\"")
        try Data(raw.utf8).write(to: URL(fileURLWithPath: ChatRoomIndex.path(paths)))
        let again = try ChatRoomIndex.load(paths)
        XCTAssertEqual(again.rooms["demo"]?.id, b.id)
        XCTAssertEqual(again.tombstones.count, 1)
        try again.write(paths)
        XCTAssertTrue(try String(contentsOfFile: ChatRoomIndex.path(paths), encoding: .utf8).contains("\"later\""))
    }
}

/// A room's state: archived outranks closed; asleep stays open; gone only with a tombstone.
final class RoomStateTests: XCTestCase {
    func testTheTable() {
        XCTAssertEqual(RoomState.derive(exists: true, archived: false, closedBy: nil, tombstone: false), .open)
        XCTAssertEqual(RoomState.derive(exists: true, archived: false, closedBy: "demo", tombstone: false), .closed)
        XCTAssertEqual(RoomState.derive(exists: true, archived: true, closedBy: "demo", tombstone: false), .archived)
        XCTAssertEqual(RoomState.derive(exists: false, archived: false, closedBy: nil, tombstone: true), .gone)
        XCTAssertEqual(RoomState.derive(exists: true, archived: false, closedBy: nil, tombstone: true), .open, "made again: a new room, open")
        XCTAssertTrue(RoomState.closedRefusal(room: "demo", workspace: "demo").contains("doz workspace reopen demo"))
    }
}
