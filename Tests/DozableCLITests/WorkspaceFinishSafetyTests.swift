import Foundation
import XCTest
@testable import DozableHost
@testable import DozableCLI

/// 756 (VOC1): stop stops everything and removes nothing; finish (and down, which is finish) says what it removed and what
/// it kept, by its lifetime. The deletion-safety rows (the owner's rule for this stage): a standing workspace's finish and
/// down remove NOTHING, its folders byte-for-byte as they were; a runs-lifetime scratch folder goes only after its archived
/// copy verifies; a failed archive removes nothing content-bearing; an external folder is never removed by any verb.
/// In-process daemon core, the lifecycle's fakes, scratch store, folders and Bin.
extension WorkspaceLifecycleHostTests {
    func fileSHA(_ path: String) -> String? { FileManager.default.contents(atPath: path).map(WorkspaceStore.sha256) }

    func state(_ c: HostCore, _ n: String = "demo") async throws -> SpaceState {
        let m = await ws(c, .workspaceState, n) { $0.withConditions = true }
        XCTAssertNil(m.error, m.error?.message ?? "")
        return try XCTUnwrap(m.result).decode(SpaceState.self)
    }

    // MARK: stop

    func testStopStopsEveryAgentRemovesNothingAndWakeBringsThemBack() async throws {
        let c = await lcore()
        try await started(c)
        let file = work.appendingPathComponent("keep.txt").path
        try "the work\n".write(toFile: file, atomically: true, encoding: .utf8)
        let before = fileSHA(file)
        let p = try await plan(c, .stop)
        XCTAssertEqual(p.confirm, "yes")
        XCTAssertEqual(Set(p.rows.filter(\.changes).map(\.name)), ["mira", "bot1", "otto"], "every agent, not the manager alone")
        let s = try ok(try await act(c, .stop))
        XCTAssertEqual(s.verb, "stop")
        XCTAssertEqual(Set(s.results.map(\.name)), ["mira", "bot1", "otto"])
        XCTAssertTrue(s.results.allSatisfy(\.ok), s.results.map(\.text).joined(separator: "; "))
        XCTAssertEqual(Set(trace.all), ["shutdown demo", "shutdown demo-bot1", "shutdown demo-otto"], "ended, never hibernated, nothing removed")
        XCTAssertFalse(trace.all.contains { $0.hasPrefix("rm ") || $0.hasPrefix("forget ") || $0.hasPrefix("post") })
        XCTAssertTrue(try XCTUnwrap(record()).agents.allSatisfy { $0.stoppedAt != nil && $0.endedAt == nil })
        XCTAssertTrue(log().contains("stopped") && log().filter { $0 == "agent-stopped" }.count == 3)
        // Each agent stopped, not asleep; the workspace's phase stopped.
        let st = try await state(c)
        XCTAssertEqual(st.agentConditions?.agents.mapValues(\.condition), ["mira": "stopped", "bot1": "stopped", "otto": "stopped"])
        XCTAssertEqual(st.agentConditions?.phase, "stopped")
        XCTAssertEqual(fileSHA(file), before, "its folder byte-for-byte")
        XCTAssertNil(try XCTUnwrap(record()).flags.finishedAt, "stop is not finish")
        // Again: nothing runs, nothing done, no error.
        trace.reset()
        let again = try ok(try await act(c, .stop))
        XCTAssertTrue(again.results.isEmpty)
        XCTAssertTrue(trace.all.isEmpty)
        // Wake brings every agent back.
        let w = try ok(try await act(c, .wake))
        XCTAssertTrue(w.results.allSatisfy(\.ok), w.results.map(\.text).joined(separator: "; "))
        XCTAssertTrue(try XCTUnwrap(record()).agents.allSatisfy { $0.stoppedAt == nil }, "every agent back")
    }

    func testStopOfAnAsleepWorkspaceIsHarmless() async throws {
        let c = await lcore()
        try await started(c)
        _ = try ok(try await act(c, .sleep))
        trace.reset()
        let s = try ok(try await act(c, .stop))
        XCTAssertTrue(s.results.isEmpty, "what sleeps stays asleep")
        XCTAssertTrue(trace.all.isEmpty)
        let phase = try await state(c).agentConditions?.phase
        XCTAssertEqual(phase, "asleep")
    }

    func testTheManagerAloneIsManagerStop() async throws {
        let c = await lcore()
        try await started(c)
        let m = await ws(c, .workspaceStop, "demo") { $0.managerOnly = true }
        XCTAssertNil(m.error, m.error?.message ?? "")
        XCTAssertTrue(try XCTUnwrap(m.result).decode(WorkspaceStopped.self).stopped)
        XCTAssertEqual(managers.places["demo"]?.running, false)
        XCTAssertEqual(workers.places["demo-bot1"]?.running, true, "a worker runs on")
    }

    // MARK: a standing workspace removes nothing

    func testAStandingRecordWorkspacesFinishRemovesNothing() async throws {
        let c = await lcore()
        try await started(c)
        let file = work.appendingPathComponent("keep.txt").path
        try "the work\n".write(toFile: file, atomically: true, encoding: .utf8)
        let before = fileSHA(file)
        let held = WorkspaceFinishInventory.held(try XCTUnwrap(record()))
        let f = try ok(try await act(c, .finish))
        XCTAssertEqual(f.kind, "WorkspaceFinish")
        XCTAssertEqual(f.schema, 1)
        XCTAssertEqual(f.removed, [], "standing: nothing removed")
        let kept = try XCTUnwrap(f.kept)
        XCTAssertTrue(kept.contains(work.path), "the folder by its absolute path (\(kept))")
        // 762 (F7): and named untouched — the person's folder, said apart in the text.
        XCTAssertEqual(f.untouched, [work.path])
        XCTAssertTrue(work.path.hasPrefix("/"))
        XCTAssertTrue(kept.contains("agent/mira") && kept.contains("agent/bot1") && kept.contains("agent/otto"))
        XCTAssertEqual(Set(kept), Set(held), "everything it held is kept")
        if try XCTUnwrap(record()).rooms.contains(where: { $0.chatRoom == "demo" }) { XCTAssertTrue(kept.contains("room/demo")) }
        XCTAssertNotNil(f.archive, "the run archived")
        XCTAssertFalse(trace.all.contains { $0.hasPrefix("rm ") || $0.hasPrefix("forget ") }, trace.all.joined(separator: ", "))
        XCTAssertTrue(rooms.removed.isEmpty)
        XCTAssertEqual(fileSHA(file), before, "the folder byte-for-byte")
        XCTAssertEqual(try XCTUnwrap(record()).folders.map(\.path), [work.path])
        let phase = try await state(c).agentConditions?.phase
        XCTAssertEqual(phase, "finished")
    }

    /// A space file that says `x-dozable.lifetime: standing`: down removes nothing it owns — scratch folders and a room for
    /// "this run only" included — but what says `x-dozable.lifetime: run` itself, and that only after its archived copy
    /// verifies.
    func standingSpace() throws -> (SpaceFiles, String) {
        let ext = root.appendingPathComponent("external-std")
        try FileManager.default.createDirectory(at: ext, withIntermediateDirectories: true)
        try "keep me\n".write(to: ext.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        let s = try spaceFiles("lv", agents: """
          w1: { kind: claude-code, prompt: one }
        """, extra: """
        x-dozable:
          lifetime: standing
        folders:
          svc:     { external: \(ext.path) }
          scratch: {}
          tmp:     { x-dozable: { lifetime: run } }
        """)
        var text = try String(contentsOfFile: s.file, encoding: .utf8)
        text = text.replacingOccurrences(of: "    lv: { main: true, members: [owner] }\n", with: "    lv: { main: true, members: [owner] }\n    run: { members: [owner] }\n")
        try text.write(toFile: s.file, atomically: true, encoding: .utf8)
        return (s, ext.path)
    }

    func testAStandingSpacesDownRemovesNothingButWhatSaysRun() async throws {
        try await withBriefHome {
            let c = await lcore()
            let (s, ext) = try standingSpace()
            let up = try acted(try await spaceUpAct(c, try spaceRequest(s)))
            XCTAssertTrue(up.ok, up.results.map { "\($0.status) \($0.text)" }.joined(separator: " | "))
            var rec = try XCTUnwrap(record("lv"))
            let ref = try XCTUnwrap(SpaceRecordRef.of(rec))
            XCTAssertEqual(ref.lifetime, "standing")
            XCTAssertEqual(ref.runLifetime, ["folder:tmp"])
            let run1 = try XCTUnwrap(rec.openRun?.id)
            let scratch = try XCTUnwrap(ref.scratch?.first { $0.name == "scratch" })
            let tmp = try XCTUnwrap(ref.scratch?.first { $0.name == "tmp" })
            try "notes\n".write(toFile: scratch.path + "/n.txt", atomically: true, encoding: .utf8)
            try "scrap\n".write(toFile: tmp.path + "/t.txt", atomically: true, encoding: .utf8)
            let scratchSHA = fileSHA(scratch.path + "/n.txt"), extSHA = fileSHA(ext + "/file.txt")
            // The plan: only tmp goes, archived first; no room, no agent, not the scratch folder.
            let p = try await downPlan(c)
            XCTAssertEqual(p.steps.filter { $0.kind == "scratch-rm" }.map(\.subject), ["folder tmp"])
            XCTAssertEqual(p.steps.first { $0.kind == "scratch-rm" }?.copy, "archived")
            XCTAssertFalse(p.steps.contains { $0.kind == "room-rm" || $0.kind == "worker-end" || $0.kind == "sandbox-rm" },
                           p.steps.map(\.text).joined(separator: "; "))
            XCTAssertTrue(p.notes.contains { $0.hasPrefix("standing:") && $0.contains(DisplayPath.tilde(scratch.path)) })
            let d = try acted(try await down(c))
            XCTAssertTrue(d.ok, d.results.map { "\($0.status) \($0.text)" }.joined(separator: " | "))
            XCTAssertEqual(d.kind, "WorkspaceFinish")
            XCTAssertEqual(d.removed, [tmp.path], "only what says lifetime: run")
            XCTAssertEqual(d.lifetime, "standing")
            let kept = try XCTUnwrap(d.kept)
            XCTAssertTrue(kept.contains(scratch.path), "the scratch folder kept (standing): \(kept)")
            XCTAssertTrue(kept.contains { $0 == ext || $0 == WorkspaceStore.resolved(ext) }, "the external folder kept: \(kept)")
            // 762 (F7): and named untouched (said apart in the text).
            XCTAssertTrue((d.untouched ?? []).contains { $0 == ext || $0 == WorkspaceStore.resolved(ext) }, "the external folder untouched: \(d.untouched ?? [])")
            XCTAssertTrue(kept.contains("room/lv") && kept.contains("room/lv-run") && kept.contains("agent/w1"), "\(kept)")
            XCTAssertNotNil(d.archive)
            // On disk: the scratch folder byte-for-byte, the external untouched; tmp only after its copy verifies.
            XCTAssertEqual(fileSHA(scratch.path + "/n.txt"), scratchSHA)
            XCTAssertEqual(fileSHA(ext + "/file.txt"), extSHA)
            XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.path))
            let copy = archivesRoot + "/lv/folders/\(run1)/tmp"
            XCTAssertTrue(RunArchive.verify(root: copy).ok, "removed only with a copy that verifies")
            XCTAssertEqual(try String(contentsOfFile: copy + "/files/t.txt", encoding: .utf8), "scrap\n")
            XCTAssertTrue(rooms.removed.isEmpty, "no room removed")
            rec = try XCTUnwrap(record("lv"))
            XCTAssertTrue(rec.agents.filter { $0.name == "w1" }.contains { $0.endedAt == nil }, "the agent kept")
            XCTAssertNotNil(rec.flags.finishedAt)
        }
    }

    func testAStandingSpacesFailedArchiveRemovesNothing() async throws {
        try await withBriefHome {
            let c = await lcore()
            let (s, ext) = try standingSpace()
            _ = try acted(try await spaceUpAct(c, try spaceRequest(s)))
            let ref = try XCTUnwrap(SpaceRecordRef.of(try XCTUnwrap(record("lv"))))
            let tmp = try XCTUnwrap(ref.scratch?.first { $0.name == "tmp" })
            try "scrap\n".write(toFile: tmp.path + "/t.txt", atomically: true, encoding: .utf8)
            let tmpSHA = fileSHA(tmp.path + "/t.txt")
            try Data("x".utf8).write(to: URL(fileURLWithPath: archivesRoot))
            let d = try acted(try await down(c))
            XCTAssertEqual(d.removed, [], "a failed archive: nothing removed")
            XCTAssertEqual(fileSHA(tmp.path + "/t.txt"), tmpSHA)
            XCTAssertEqual(d.results.first { $0.kind == "scratch-rm" }?.status, "skipped")
            XCTAssertEqual(fileSHA(ext + "/file.txt"), WorkspaceStore.sha256(Data("keep me\n".utf8)))
            XCTAssertTrue(rooms.removed.isEmpty)
        }
    }

    // MARK: runs: removed only after the archive verifies

    func testARunsScratchFolderIsRemovedOnlyAfterItsArchiveVerifiesAndIsNamed() async throws {
        try await withBriefHome {
            let c = await lcore()
            let (s, ext) = try liveSpace()
            _ = try acted(try await spaceUpAct(c, try spaceRequest(s)))
            let rec = try XCTUnwrap(record("lv"))
            let run1 = try XCTUnwrap(rec.openRun?.id)
            let scratch = try XCTUnwrap(SpaceRecordRef.of(rec)?.scratch?.first)
            try "notes\n".write(toFile: scratch.path + "/n.txt", atomically: true, encoding: .utf8)
            let d = try acted(try await down(c))
            XCTAssertTrue(d.ok, d.results.map { "\($0.status) \($0.text)" }.joined(separator: " | "))
            XCTAssertEqual(d.kind, "WorkspaceFinish")
            XCTAssertEqual(d.lifetime, "runs")
            let removed = try XCTUnwrap(d.removed)
            XCTAssertTrue(removed.contains(scratch.path), "the scratch folder by its absolute path (\(removed))")
            XCTAssertTrue(removed.contains("room/lv-run"))
            XCTAssertFalse(removed.contains { $0.hasPrefix(ext) }, "never the external")
            let kept = try XCTUnwrap(d.kept)
            XCTAssertTrue(kept.contains("room/lv"), "the persisted room kept (\(kept))")
            XCTAssertFalse(kept.contains(scratch.path))
            XCTAssertTrue(RunArchive.verify(root: archivesRoot + "/lv/folders/\(run1)/scratch").ok)
            XCTAssertEqual(try String(contentsOfFile: ext + "/file.txt", encoding: .utf8), "keep me\n")
        }
    }

    func testARunsFailedArchiveRemovesNoFolderAndNoRoom() async throws {
        try await withBriefHome {
            let c = await lcore()
            let (s, ext) = try liveSpace()
            _ = try acted(try await spaceUpAct(c, try spaceRequest(s)))
            let scratch = try XCTUnwrap(SpaceRecordRef.of(try XCTUnwrap(record("lv")))?.scratch?.first)
            try "notes\n".write(toFile: scratch.path + "/n.txt", atomically: true, encoding: .utf8)
            let sha = fileSHA(scratch.path + "/n.txt")
            try Data("x".utf8).write(to: URL(fileURLWithPath: archivesRoot))
            let d = try acted(try await down(c))
            let removed = d.removed ?? []
            XCTAssertFalse(removed.contains { $0.hasPrefix("/") || $0.hasPrefix("room/") }, "nothing content-bearing: \(removed)")
            XCTAssertEqual(fileSHA(scratch.path + "/n.txt"), sha)
            XCTAssertTrue(rooms.removed.isEmpty)
            XCTAssertEqual(try String(contentsOfFile: ext + "/file.txt", encoding: .utf8), "keep me\n")
        }
    }

    // MARK: external folders: never removed by any verb

    func testNoVerbRemovesAFolder() async throws {
        let c = await lcore()
        try await started(c)
        let file = work.appendingPathComponent("keep.txt").path
        try "the work\n".write(toFile: file, atomically: true, encoding: .utf8)
        let before = fileSHA(file)
        for v: WorkspaceVerb in [.stop, .wake, .sleep, .wake, .finish, .reopen, .finish] {
            let m = try await act(c, v)
            XCTAssertNil(m.error, "\(v): " + (m.error?.message ?? ""))
            XCTAssertEqual(fileSHA(file), before, "after \(v): the folder byte-for-byte")
        }
        _ = try ok(try await act(c, .archive) { $0.confirm = "demo" })
        XCTAssertEqual(fileSHA(file), before, "after archive")
        _ = try ok(try await act(c, .delete) { $0.confirm = "demo" })
        XCTAssertEqual(fileSHA(file), before, "after delete (no --bin-folders)")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: bin.path).isEmpty, "nothing in the Bin")
    }
}
