import Foundation
import XCTest
@testable import DozableHost

/// Runs in an in-process daemon core (the lifecycle's fakes): the kick-off opens run 1 just before the brief (the brief is
/// its first message); sleep, wake, stop and start never close it; finish closes it with each room's last seq; reopen opens
/// run 2 from the seq then; `workspace-runs` answers with no daemon; the room's id and ownership are recorded at `new`.
extension WorkspaceLifecycleHostTests {
    func testRunsOpenAtTheKickoffAndReopenAndCloseAtFinish() async throws {
        let c = await lcore()
        rooms.otherPost("demo")   // a message before the start: never the run's
        try await started(c)
        var r = try XCTUnwrap(record())
        XCTAssertEqual(r.runs.count, 1)
        let run1 = r.runs[0]
        XCTAssertTrue(run1.isOpen)
        XCTAssertEqual(run1.rooms.first?.room, "demo")
        XCTAssertEqual(run1.rooms.first?.fromSeq, 1, "the start marker is the seq before the brief")
        XCTAssertEqual(r.rooms.first?.owned, true, "new made the room: owned")
        XCTAssertTrue(ChatRoomIndex.isID(r.rooms.first?.id ?? ""), "its id in the room index")
        XCTAssertEqual(try ChatRoomIndex.load(ChatPaths(store: store)).rooms["demo"]?.owner, "demo")
        XCTAssertTrue(log().contains("run-opened"))
        // Sleep and wake never close it; nor a stop and a start.
        _ = try ok(try await act(c, .sleep))
        _ = try ok(try await act(c, .wake))
        var m = await ws(c, .workspaceStop, "demo")
        XCTAssertNil(m.error, m.error?.message ?? "")
        m = await ws(c, .workspaceStart, "demo")
        XCTAssertNil(m.error, m.error?.message ?? "")
        r = try XCTUnwrap(record())
        XCTAssertEqual(r.runs.count, 1)
        XCTAssertTrue(r.runs[0].isOpen)
        // Finish closes it at the room's last seq.
        rooms.otherPost("demo")
        rooms.otherPost("demo")
        _ = try ok(try await act(c, .finish, "demo") { $0.noArchive = true })
        r = try XCTUnwrap(record())
        XCTAssertFalse(r.runs[0].isOpen)
        XCTAssertEqual(r.runs[0].closedBy, "finish")
        XCTAssertEqual(r.runs[0].rooms.first?.toSeq, 4, "the brief and the two posts after it")
        // Reopen opens run 2 from the seq then.
        _ = try ok(try await act(c, .reopen))
        r = try XCTUnwrap(record())
        XCTAssertEqual(r.runs.count, 2)
        XCTAssertEqual(r.runs[1].rooms.first?.fromSeq, 4)
        XCTAssertNotEqual(r.runs[0].id, r.runs[1].id, "two runs on one day, each its own id")
        // Runs answered with no daemon (a read-only core), nothing written.
        let ro = await lcore(readOnly: true)
        let a = await ws(ro, .workspaceRuns, "demo")
        XCTAssertNil(a.error, a.error?.message ?? "")
        let l = try XCTUnwrap(a.result).decode(WorkspaceRunsListing.self)
        XCTAssertEqual(l.runs.map(\.archiveStatus), ["none", "open"])
    }

    func testALegacyRecordGetsAnImplicitRunAtItsFinish() async throws {
        let c = await lcore()
        try await started(c)
        // As a record of a build before runs: started, no runs.
        var r = try XCTUnwrap(record())
        r.runs = []
        try WorkspaceStore(store: store).write(r)
        _ = try ok(try await act(c, .finish, "demo") { $0.noArchive = true })
        r = try XCTUnwrap(record())
        XCTAssertEqual(r.runs.count, 1)
        XCTAssertEqual(r.runs[0].legacy, true)
        XCTAssertFalse(r.runs[0].isOpen)
    }
}
