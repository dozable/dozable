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

/// The archive at finish: written in the store (the slice excludes what came before the start), recorded in the run; a
/// failure finishes anyway, removes nothing, says why, and `workspace-run-archive` writes it once fixed.
extension WorkspaceLifecycleHostTests {
    func testFinishWritesTheRunsArchive() async throws {
        let c = await lcore()
        rooms.otherPost("demo", "before the start")
        try await started(c)
        rooms.otherPost("demo", "work")
        let p = try await plan(c, .finish)
        XCTAssertEqual(p.archive?.off, false)
        XCTAssertEqual(p.archive?.rooms.map(\.room), ["demo"])
        XCTAssertEqual(p.archive?.rooms.first?.messages, 2, "the brief and the post after it")
        let f = try ok(try await act(c, .finish))
        XCTAssertNil(f.archiveProblem, f.archiveProblem ?? "")
        let path = try XCTUnwrap(f.archive)
        let dir = WorkspaceStore.resolved(store.root.path) + "/" + path
        XCTAssertTrue(RunArchive.verify(root: dir).ok)
        let chat = try String(contentsOfFile: dir + "/chat/demo.jsonl", encoding: .utf8)
        XCTAssertFalse(chat.contains("before the start"), "the slice excludes a message from before the start")
        XCTAssertTrue(chat.contains("\"work\""))
        let r = try XCTUnwrap(record())
        XCTAssertEqual(r.runs.last?.archive, path)
        XCTAssertEqual(r.runs.last?.archiveSHA256, f.archiveSHA256)
        XCTAssertTrue(log().contains("run-archived"))
        // Runs: written, with its size and its messages.
        let lr = await ws(c, .workspaceRuns, "demo")
        let l = try XCTUnwrap(lr.result).decode(WorkspaceRunsListing.self)
        XCTAssertEqual(l.runs.first?.archiveStatus, "written")
        XCTAssertEqual(l.runs.first?.messages, 2)
        XCTAssertGreaterThan(l.runs.first?.archiveBytes ?? 0, 0)
    }

    func testAFailedArchiveFinishesAnywayAndIsWrittenAgainOnceFixed() async throws {
        let c = await lcore()
        try await started(c)
        // The archives' folder cannot be made: a file stands where it would be.
        let blocker = WorkspaceStore.resolved(store.root.path) + "/archives"
        try Data("x".utf8).write(to: URL(fileURLWithPath: blocker))
        let f = try ok(try await act(c, .finish))
        XCTAssertEqual(f.workspace?.state, "finished", "finish still completes")
        let why = try XCTUnwrap(f.archiveProblem)
        XCTAssertTrue(f.notes?.contains { $0.contains("--archive \(f.run ?? "")") } == true)
        XCTAssertEqual(try XCTUnwrap(record()).runs.last?.archiveProblem, why)
        XCTAssertTrue(log().contains("run-archive-failed"))
        XCTAssertEqual(try String(contentsOfFile: blocker, encoding: .utf8), "x", "nothing of the person's was removed")
        try FileManager.default.removeItem(atPath: blocker)
        let again = await ws(c, .workspaceRunArchive, "demo") { $0.run = f.run }
        XCTAssertNil(again.error, again.error?.message ?? "")
        let r = try XCTUnwrap(record())
        XCTAssertNil(r.runs.last?.archiveProblem)
        XCTAssertNotNil(r.runs.last?.archive)
        let twice = await ws(c, .workspaceRunArchive, "demo") { $0.run = f.run }
        XCTAssertEqual(twice.error?.code, .exists)
    }

    func testFinishWithoutAnArchive() async throws {
        let c = await lcore()
        try await started(c)
        let p = try await plan(c, .finish) { $0.noArchive = true }
        XCTAssertEqual(p.archive?.off, true)
        XCTAssertTrue(p.command.hasSuffix("--no-archive"))
        let f = try ok(try await act(c, .finish) { $0.noArchive = true })
        XCTAssertNil(f.archive)
        XCTAssertEqual(try XCTUnwrap(record()).runs.last?.noArchive, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: WorkspaceStore.resolved(store.root.path) + "/archives"))
    }
}
