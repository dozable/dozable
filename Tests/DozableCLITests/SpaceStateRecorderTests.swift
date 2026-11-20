import DozableChat
import DozableKit
import Foundation
import XCTest
@testable import DozableHost
@testable import DozableCLI

/// A space's frames during a run (`SpaceStateRecorder`) in an in-process daemon core (the lifecycle's fakes, a scratch
/// store): a frame only when the state's sha changes, moved by events (a session's status) and never a timer; 0600 files in
/// 0700 folders; never a program's message; bounded (past it only `last.json`, the run `framesCapped`); down writes a final
/// frame, the archive holds and verifies `frames/`, and the run's folder is removed only after it verifies; a run from before
/// frames has one, its last state; another computer that may not see this Mac's sessions reads them projected.
extension WorkspaceLifecycleHostTests {
    func frameNames(_ folder: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).filter(SpaceStateRecorder.isFrameName).sorted()
    }

    func mode(_ p: String) -> Int { ((try? FileManager.default.attributesOfItem(atPath: p))?[.posixPermissions] as? NSNumber)?.intValue ?? -1 }

    func testFramesOnlyOnAShaChangeBoundedArchivedAndVerified() async throws {
        try await withBriefHome {
            let c = await lcore()
            c.spaceFrames.debounce = .milliseconds(20)
            let (s, _) = try liveSpace()
            _ = try acted(try await spaceUpAct(c, try spaceRequest(s)))
            let rec = try XCTUnwrap(record("lv"))
            let run = try XCTUnwrap(rec.openRun)
            let folder = c.spaceFrameFolder("lv", run.id)
            // Up wrote the record: its pokes recorded the first frame (events, not a timer).
            let deadline = Date().addingTimeInterval(5)
            while frameNames(folder).isEmpty && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertFalse(frameNames(folder).isEmpty, "a frame after up's events")
            XCTAssertEqual(mode(folder), 0o700)
            XCTAssertEqual(mode((folder as NSString).deletingLastPathComponent), 0o700)
            for f in frameNames(folder) { XCTAssertEqual(mode(folder + "/" + f), 0o600, f) }
            // The same facts: no new frame.
            let count = frameNames(folder).count
            let again = await c.spaceFrameRecord("lv", label: "nothing changed")
            XCTAssertFalse(again)
            XCTAssertEqual(frameNames(folder).count, count)
            // No timer: nothing more is written while nothing happens.
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertEqual(frameNames(folder).count, count)
            // A fact changes (the scratch folder gone) — nothing is written until an event comes; a program's status changes
            // (an event): a new frame — its state, never its message.
            let scratch = try XCTUnwrap(SpaceRecordRef.of(rec)?.scratch?.first?.path)
            try FileManager.default.removeItem(atPath: scratch)
            try await Task.sleep(for: .milliseconds(200))
            XCTAssertEqual(frameNames(folder).count, count, "no event yet: no frame")
            let session = try XCTUnwrap(rec.agents.first { $0.name == "w1" }?.place.session)
            await c.setStatus(MacPlace.name, session: session, SessionStatus(session: session, state: .blocked, kind: .permission, message: "Allow THE-SECRET-WORDS?"))
            let d2 = Date().addingTimeInterval(5)
            while frameNames(folder).count == count && Date() < d2 { try await Task.sleep(for: .milliseconds(20)) }
            let all = frameNames(folder)
            XCTAssertEqual(all.count, count + 1, all.joined(separator: ","))
            for f in all {
                let t = (try? String(contentsOfFile: folder + "/" + f, encoding: .utf8)) ?? ""
                XCTAssertFalse(t.contains("THE-SECRET-WORDS"), "\(f): a frame never holds a program's message")
                XCTAssertNotNil(try? JSONDecoder().decode(SpaceStateRecorder.Frame.self, from: Data(t.utf8)), f)
            }
            // The bound: past it only last.json, and the run says so.
            let key = "lv/" + run.id
            c.spaceFrames.setMemo(key, SpaceStateRecorder.Memo(count: SpaceStateRecorder.maximumFrames, bytes: 0, lastSHA: "x", capped: false))
            let past = await c.spaceFrameRecord("lv", label: "past the bound")
            XCTAssertTrue(past)
            XCTAssertTrue(FileManager.default.fileExists(atPath: folder + "/last.json"))
            XCTAssertEqual(frameNames(folder).count, count + 2, "the numbered frames kept, last.json beside them")
            XCTAssertEqual(try XCTUnwrap(record("lv")).runs.first { $0.id == run.id }?.framesCapped, true)
            c.spaceFrames.setMemo(key, SpaceStateRecorder.Memo(count: count + 1, bytes: 0, lastSHA: "y", capped: true))
            let still = await c.spaceFrameRecord("lv", label: "still past it")
            XCTAssertTrue(still)
            XCTAssertEqual(frameNames(folder).count, count + 2, "only last.json rewritten")
            // The frames read while the run is open.
            var m = await ws(c, .workspaceRunFrames, "lv") { $0.run = run.id }
            var detail = try XCTUnwrap(m.result).decode(SpaceRunDetail.self)
            XCTAssertEqual(detail.frames.count, count + 2)
            XCTAssertEqual(detail.frames.last?.file, "last.json")
            XCTAssertEqual(detail.capped, true)
            XCTAssertNil(detail.archive)
            // Another computer that may not see this Mac's sessions: w1 (on this Mac) not known in every frame.
            m = await ws(c, .workspaceRunFrames, "lv") { $0.run = run.id; $0.macSessionsHidden = true }
            detail = try XCTUnwrap(m.result).decode(SpaceRunDetail.self)
            XCTAssertTrue(detail.frames.allSatisfy { f in f.state.items.first { $0.type == "agent" && $0.subject == "w1" }?.state == "unknown" })
            XCTAssertTrue(detail.frames.allSatisfy { $0.state.attention.isEmpty && $0.state.sha == $0.state.computedSHA })
            // Down: a final frame, the archive holds frames/ and verifies, then the run's folder is gone.
            let d = try acted(try await down(c))
            XCTAssertTrue(d.ok, d.results.map { "\($0.status) \($0.text)" }.joined(separator: " | "))
            let closed = try XCTUnwrap(try XCTUnwrap(record("lv")).runs.first { $0.id == run.id })
            let archive = try XCTUnwrap(closed.archive)
            let v = RunArchive.verify(root: WorkspaceStore.resolved(store.root.path) + "/" + archive)
            XCTAssertTrue(v.ok, v.problems.joined(separator: "; "))
            let archived = (v.manifest?.files ?? []).filter { $0.path.hasPrefix("frames/") }.map(\.path)
            XCTAssertEqual(archived.count, count + 2, archived.joined(separator: ","))
            XCTAssertTrue(archived.contains("frames/last.json"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: c.spaceRunFolder("lv", run.id)), "removed once the archive verified")
            m = await ws(c, .workspaceRunFrames, "lv") { $0.run = run.id }
            detail = try XCTUnwrap(m.result).decode(SpaceRunDetail.self)
            XCTAssertEqual(detail.archive?.verified, true)
            XCTAssertEqual(detail.frames.count, count + 2, "read from the archive")
            XCTAssertEqual(detail.frames.last?.state.run?.phase, "down", "the final frame: the run down")
            let runsM = await ws(c, .workspaceRuns, "lv")
            let runs = try XCTUnwrap(runsM.result).decode(WorkspaceRunsListing.self)
            XCTAssertEqual(runs.runs.first { $0.id == run.id }?.frames, count + 2)
        }
    }

    func testAFailedArchiveKeepsTheFramesAndAnOldRunHasItsLastState() async throws {
        try await withBriefHome {
            let c = await lcore()
            c.spaceFrames.debounce = .milliseconds(20)
            let (s, _) = try liveSpace()
            _ = try acted(try await spaceUpAct(c, try spaceRequest(s)))
            let run = try XCTUnwrap(try XCTUnwrap(record("lv")).openRun)
            let now = await c.spaceFrameRecord("lv", label: "now")
            XCTAssertTrue(now)
            // The frames are never removed before an archive that verifies: a folder that does not verify keeps them.
            await c.spaceFramesArchived("lv", run.id, archive: "archives/lv/runs/none")
            XCTAssertTrue(FileManager.default.fileExists(atPath: c.spaceFrameFolder("lv", run.id)))
            // A run with no frames (a record from before them): its last state, said so.
            // (the daemon core's own recompute after up's events settles first: it would write a frame of its own)
            try await Task.sleep(for: .milliseconds(800))
            try FileManager.default.removeItem(atPath: c.spaceRunFolder("lv", run.id))
            c.spaceFrames.forget("lv/" + run.id)
            let ro = await lcore(readOnly: true)
            let m = await ws(ro, .workspaceRunFrames, "lv") { $0.run = run.id }
            let d = try XCTUnwrap(m.result).decode(SpaceRunDetail.self)
            XCTAssertEqual(d.frames.map(\.label), [HostCore.noFramesLabel])
            XCTAssertEqual(d.frames.first?.file, "record")
            XCTAssertFalse(d.frames.first?.state.factsKnown ?? true, "with no daemon: not known")
            // A read-only core never writes one.
            let wrote = await ro.spaceFrameRecord("lv", label: "x")
            XCTAssertFalse(wrote)
        }
    }
}

/// The projection another computer reads frames through is exactly the builder's own for that viewer.
extension SpaceStateTests {
    func testHidingIsTheBuildersHiddenViewer() throws {
        let i = try intent()
        var f = runningFacts()
        f.agents["worker"] = .init(state: "running", status: status(.blocked, kind: .permission, message: "Allow?"))
        let (rec, _) = record(open: true)
        let owner = build(i, f)
        let hidden = build(i, f, viewer: SpaceStateViewer(macSessions: false))
        XCTAssertEqual(owner.hiding(SpaceStateBuilder.macSubjects(intent: i, record: rec)), hidden)
    }
}
