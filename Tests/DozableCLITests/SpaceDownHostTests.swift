import DozableChat
import Foundation
import XCTest
@testable import DozableHost
@testable import DozableCLI

/// `doz workspace down` and `--purge` in an in-process daemon core (the lifecycle's fakes; scratch store, folders and Bin),
/// after the live fixture's shape (the reference's real up → down → up → down --purge: an external folder, a scratch and
/// a persisted folder, a persisted room and a run room). The safety rows: nothing content-bearing is removed before its
/// archived copy is hash-checked, and nothing at all when the archive failed; `archive: off` is the one exception and is
/// named; a persisted folder is released, never deleted; a scratch folder goes only when recorded and never from the
/// store; external things are never touched; a changed plan does nothing.
extension WorkspaceLifecycleHostTests {
    func liveSpace(archiveOff: Bool = false) throws -> (SpaceFiles, String) {
        let ext = root.appendingPathComponent("external-svc")
        try FileManager.default.createDirectory(at: ext, withIntermediateDirectories: true)
        try "keep me\n".write(to: ext.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        let s = try spaceFiles("lv", agents: """
          w1: { kind: claude-code, prompt: one }
        """, extra: """
        folders:
          svc:     { external: \(ext.path) }
          scratch: {}
          data:    {}
        persist:
          shared-data: { folder: data }
          team-chat: { room: lv }
        \(archiveOff ? "archive: off\n" : "")
        """)
        // A second room, for this run only.
        var text = try String(contentsOfFile: s.file, encoding: .utf8)
        text = text.replacingOccurrences(of: "    lv: { main: true, members: [owner] }\n", with: "    lv: { main: true, members: [owner] }\n    run: { members: [owner] }\n")
        try text.write(toFile: s.file, atomically: true, encoding: .utf8)
        return (s, ext.path)
    }

    func downPlan(_ c: HostCore, purge: Bool = false) async throws -> SpaceDownPlan {
        var r = HostRequest(.workspaceDownPlan)
        r.spaceDown = SpaceDownRequest(workspace: "lv", purge: purge ? true : nil)
        let m = await c.handle(r)
        XCTAssertNil(m.error, m.error?.message ?? "")
        return try XCTUnwrap(m.result).decode(SpaceDownPlan.self)
    }

    func down(_ c: HostCore, purge: Bool = false, ifPlan: String? = nil) async throws -> HostMessage {
        let p = try await downPlan(c, purge: purge)
        var r = HostRequest(.workspaceDown)
        r.spaceDown = SpaceDownRequest(workspace: "lv", purge: purge ? true : nil, ifPlan: ifPlan ?? p.sha)
        return await c.handle(r)
    }

    var archivesRoot: String { WorkspaceStore.resolved(store.root.path) + "/archives" }

    func testDownArchivesFirstThenRemovesWhatTheRunMadeAndKeepsWhatPersists() async throws {
        try await withBriefHome {
            let c = await lcore()
            let (s, ext) = try liveSpace()
            let up = try acted(try await spaceUpAct(c, try spaceRequest(s)))
            XCTAssertTrue(up.ok, up.results.map { "\($0.status) \($0.text)" }.joined(separator: " | "))
            var rec = try XCTUnwrap(record("lv"))
            let run1 = try XCTUnwrap(rec.openRun?.id)
            XCTAssertEqual(Set(rec.rooms.map(\.chatRoom)), ["lv", "lv-run"])
            let scratch = try XCTUnwrap(SpaceRecordRef.of(rec)?.scratch?.first)
            try "notes\n".write(toFile: scratch.path + "/n.txt", atomically: true, encoding: .utf8)
            let data = try XCTUnwrap(SpaceRecordRef.of(rec)?.persistedPaths?.first)
            try "data\n".write(toFile: data + "/d.txt", atomically: true, encoding: .utf8)
            rooms.otherPost("lv-run", "work")
            // A changed plan: refused, nothing done.
            let stale = try await down(c, ifPlan: String(repeating: "0", count: 64))
            XCTAssertEqual(stale.error?.code, .planChanged)
            XCTAssertNotNil(try XCTUnwrap(record("lv")).openRun)
            // The plan: no copy-less deletion (the archive is on).
            let p = try await downPlan(c)
            XCTAssertTrue(p.up)
            XCTAssertTrue(p.noCopy.isEmpty)
            XCTAssertEqual(p.steps.first?.kind, "finish")
            XCTAssertTrue(p.steps.contains { $0.kind == "room-rm" && $0.subject == "room lv-run" && $0.copy == "archived" })
            XCTAssertFalse(p.steps.contains { $0.subject == "room lv" }, "a persisted room stays")
            let d = try acted(try await down(c))
            XCTAssertTrue(d.ok, d.results.map { "\($0.status) \($0.text)" }.joined(separator: " | "))
            rec = try XCTUnwrap(record("lv"))
            // The run's archive: written and verified.
            let run = try XCTUnwrap(rec.runs.first { $0.id == run1 })
            XCTAssertFalse(run.isOpen)
            let runArchive = try XCTUnwrap(run.archive)
            XCTAssertTrue(RunArchive.verify(root: WorkspaceStore.resolved(store.root.path) + "/" + runArchive).ok)
            // The run room: archived (its own copy verifies), then removed, a tombstone naming the copy.
            XCTAssertEqual(rooms.removed.map(\.room), ["lv-run"])
            let tomb = try XCTUnwrap(ChatRoomIndex.load(ChatPaths(store: store)).tombstone("lv-run"))
            XCTAssertFalse(tomb.archive.isEmpty)
            XCTAssertTrue(RunArchive.verify(root: WorkspaceStore.resolved(store.root.path) + "/" + tomb.archive).ok, "removed only with a copy that verifies")
            // The persisted room: closed, kept.
            XCTAssertNil(rec.rooms.first { $0.chatRoom == "lv" }?.goneAt)
            XCTAssertEqual(rooms.closedSets.last?["lv"], "lv")
            // The scratch folder: copied, hash-checked, then removed; the persisted folder kept; the external untouched.
            XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.path))
            let copy = archivesRoot + "/lv/folders/\(run1)/scratch"
            XCTAssertTrue(RunArchive.verify(root: copy).ok)
            XCTAssertEqual(try String(contentsOfFile: copy + "/files/n.txt", encoding: .utf8), "notes\n")
            XCTAssertEqual(try String(contentsOfFile: data + "/d.txt", encoding: .utf8), "data\n")
            XCTAssertEqual(try String(contentsOfFile: ext + "/file.txt", encoding: .utf8), "keep me\n")
            // The run's agent ended; the record says down.
            XCTAssertTrue(rec.agents.filter(\.isWorker).allSatisfy { $0.endedAt != nil })
            XCTAssertNotNil(SpaceRecordRef.of(rec)?.downAt)
            XCTAssertFalse(SpaceRecordRef.of(rec)?.isUp ?? true)
            // A second down: nothing left.
            let again = try await downPlan(c)
            XCTAssertFalse(again.up)
            XCTAssertTrue(again.steps.isEmpty, again.steps.map(\.text).joined(separator: "; "))
            // Up again: the persisted room and folder reused, the run room made again (a new id), a new run.
            let up2 = try acted(try await spaceUpAct(c, try spaceRequest(s)))
            XCTAssertTrue(up2.ok, up2.results.map { "\($0.status) \($0.text)" }.joined(separator: " | "))
            rec = try XCTUnwrap(record("lv"))
            XCTAssertNotEqual(rec.openRun?.id, run1)
            XCTAssertEqual(rec.rooms.filter { $0.chatRoom == "lv-run" && $0.goneAt == nil }.count, 1)
            XCTAssertEqual(try String(contentsOfFile: data + "/d.txt", encoding: .utf8), "data\n")
            // --purge: down first, then what persists: the persisted room archived and removed; the folder released, never deleted.
            let pp = try await downPlan(c, purge: true)
            XCTAssertTrue(pp.steps.contains { $0.kind == "folder-release" })
            let purged = try acted(try await down(c, purge: true))
            XCTAssertTrue(purged.ok, purged.results.map { "\($0.status) \($0.text)" }.joined(separator: " | "))
            rec = try XCTUnwrap(record("lv"))
            XCTAssertNotNil(rec.rooms.first { $0.chatRoom == "lv" }?.goneAt)
            let lvTomb = try XCTUnwrap(ChatRoomIndex.load(ChatPaths(store: store)).tombstone("lv"))
            XCTAssertTrue(RunArchive.verify(root: WorkspaceStore.resolved(store.root.path) + "/" + lvTomb.archive).ok)
            XCTAssertFalse(rec.folders.contains { $0.path == data }, "released: off the record")
            XCTAssertEqual(try String(contentsOfFile: data + "/d.txt", encoding: .utf8), "data\n", "a persisted folder is never deleted")
            XCTAssertEqual(try String(contentsOfFile: ext + "/file.txt", encoding: .utf8), "keep me\n", "an external folder is never touched")
            XCTAssertNotNil(SpaceRecordRef.of(rec)?.purgedAt)
            XCTAssertTrue(log("lv").contains("space-purged"))
        }
    }

    func testAFailedArchiveRemovesNothingContentBearing() async throws {
        try await withBriefHome {
            let c = await lcore()
            let (s, _) = try liveSpace()
            _ = try acted(try await spaceUpAct(c, try spaceRequest(s)))
            let rec = try XCTUnwrap(record("lv"))
            let scratch = try XCTUnwrap(SpaceRecordRef.of(rec)?.scratch?.first)
            try "notes\n".write(toFile: scratch.path + "/n.txt", atomically: true, encoding: .utf8)
            // The archives' folder cannot be made: a file stands where it would be.
            try Data("x".utf8).write(to: URL(fileURLWithPath: archivesRoot))
            let d = try acted(try await down(c))
            XCTAssertTrue(rooms.removed.isEmpty, "no room removed without its copy")
            XCTAssertTrue(FileManager.default.fileExists(atPath: scratch.path + "/n.txt"), "no scratch folder removed without its copy")
            XCTAssertTrue(d.results.filter { $0.kind == "room-rm" || $0.kind == "scratch-rm" }.allSatisfy { $0.status == "skipped" },
                          d.results.map { "\($0.kind) \($0.status)" }.joined(separator: ", "))
            XCTAssertTrue(try XCTUnwrap(record("lv")).agents.filter(\.isWorker).allSatisfy { $0.endedAt != nil }, "the agents still go: " + d.results.map { "\($0.kind) \($0.status) \($0.text)" }.joined(separator: " | "))
            XCTAssertEqual(try String(contentsOfFile: archivesRoot, encoding: .utf8), "x")
            // Fixed: a second down removes what is left, each with its copy.
            try FileManager.default.removeItem(atPath: archivesRoot)
            let p = try await downPlan(c)
            XCTAssertTrue(p.steps.contains { $0.subject == "room lv-run" })
        }
    }

    func testArchiveOffIsTheOneExceptionAndIsNamed() async throws {
        try await withBriefHome {
            let c = await lcore()
            let (s, _) = try liveSpace(archiveOff: true)
            let plan = try await spacePlanned(c, try spaceRequest(s))
            XCTAssertTrue(plan.summary.contains { $0.contains("Archive: off") && $0.contains("no copy") })
            _ = try acted(try await spaceUpAct(c, try spaceRequest(s)))
            let scratch = try XCTUnwrap(SpaceRecordRef.of(try XCTUnwrap(record("lv")))?.scratch?.first)
            let p = try await downPlan(c)
            XCTAssertEqual(Set(p.noCopy), ["the scratch folder scratch", "the room lv-run"])
            XCTAssertTrue(p.summary.contains { $0.hasPrefix("Deleted with no copy (archive: off)") })
            let d = try acted(try await down(c))
            XCTAssertTrue(d.ok, d.results.map { "\($0.status) \($0.text)" }.joined(separator: " | "))
            XCTAssertEqual(rooms.removed.map(\.room), ["lv-run"])
            XCTAssertEqual(try ChatRoomIndex.load(ChatPaths(store: store)).tombstone("lv-run")?.archive, "", "no copy, said")
            XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: archivesRoot), "no archive at all")
            XCTAssertTrue(log("lv").contains("scratch-removed"))
        }
    }

    func testAScratchFolderGoesOnlyWhenRecordedAndNeverFromTheStore() async throws {
        try await withBriefHome {
            let c = await lcore()
            let (s, _) = try liveSpace()
            _ = try acted(try await spaceUpAct(c, try spaceRequest(s)))
            // The record is made to name a folder in the store: down refuses to remove it.
            let inStore = WorkspaceStore.resolved(store.root.path) + "/keep-me"
            try FileManager.default.createDirectory(atPath: inStore, withIntermediateDirectories: true)
            _ = try await c.workspaceUpdate("lv") { r in
                var ref = SpaceRecordRef.of(r)!
                ref.scratch = [.init(run: ref.scratch![0].run, name: "scratch", path: inStore)]
                ref.store(in: &r)
                return []
            }
            let d = try acted(try await down(c))
            XCTAssertFalse(d.ok)
            XCTAssertEqual(d.results.first { $0.kind == "scratch-rm" }?.status, "failed")
            XCTAssertTrue(FileManager.default.fileExists(atPath: inStore))
        }
    }
}

/// A persisted agent switched fenced → unfenced between runs: it is ended and forgotten and starts fresh in its new place —
/// confirmed as every unfenced agent is — and (776) its kept memory is KEPT, never reset silently: a warning says so.
extension WorkspaceLifecycleHostTests {
    func testAnIsolationSwitchKeepsTheKeptMemory() async throws {
        try await withBriefHome {
            let c = await lcore()
            let s = try spaceFiles("lv", agents: """
              w1: { kind: claude-code, isolation: fenced, prompt: remember }
            """, extra: """
            persist:
              mem: { agent: w1 }
            """)
            _ = try acted(try await spaceUpAct(c, try spaceRequest(s)))
            _ = try acted(try await down(c))
            // What a capture would have kept.
            let mem = WorkspaceStore.resolved(WorkspaceStore(store: store).folder("lv")) + "/memory/w1"
            try FileManager.default.createDirectory(atPath: mem, withIntermediateDirectories: true)
            try #"{"isolation":"fenced","files":[]}"#.write(toFile: mem + "/memory.json", atomically: true, encoding: .utf8)
            var text = try String(contentsOfFile: s.file, encoding: .utf8)
            text = text.replacingOccurrences(of: "isolation: fenced", with: "isolation: unfenced")
            try text.write(toFile: s.file, atomically: true, encoding: .utf8)
            let p = try await spacePlanned(c, try spaceRequest(s))
            XCTAssertEqual(p.confirm, ["w1"])
            XCTAssertTrue(p.steps.contains { $0.subject == "agent w1" && $0.action == "run" && ($0.why ?? "").contains("its kept memory is kept") })
            let up = try acted(try await spaceUpAct(c, try spaceRequest(s), confirmed: ["w1"]))
            XCTAssertTrue(up.ok, up.results.map { "\($0.status) \($0.text)" }.joined(separator: " | "))
            XCTAssertTrue(FileManager.default.fileExists(atPath: mem + "/memory.json"), "the kept memory is kept")
            XCTAssertFalse(log("lv").contains("memory-reset"))
            XCTAssertTrue(log("lv").contains("memory-kept"))
            XCTAssertTrue(up.results.contains { ($0.notes ?? []).contains { $0.contains("isolation changed: its kept memory is kept") } },
                          up.results.map { ($0.notes ?? []).joined(separator: "; ") }.joined(separator: " | "))
            XCTAssertEqual(try XCTUnwrap(record("lv")).agents.last { $0.name == "w1" && $0.endedAt == nil }?.isolation, "unfenced")
        }
    }
}
