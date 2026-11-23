import DozableChat
import Foundation
import XCTest
@testable import DozableHost
@testable import DozableCLI

/// 762: the lifecycle findings that need no model decision. The plan reads the lifetime (F1, F12); `show` / `ls` carry it
/// (F1b); stop → start is a round trip (F2); a stopped workspace reads stopped, never asleep (F3); `down`'s kept list holds
/// only what is the workspace's own (F7); and — the deletion-safety rows — a sandbox's disk is never removed without a copy:
/// saved as an image first at `down` (a run-lifetime agent's own sandbox) and `down --purge` (a persisted one), named in the
/// result, and nothing removed when the save fails (F5). Fakes only: no VM, no real image, a scratch store.
extension SpaceUpPlanTests {
    /// A space file in the test's scratch root, with `lifetime` under x-dozable (nil: none), a scratch folder, a run room and
    /// a worker. `extra` is appended.
    func lifetimeFile(_ name: String, lifetime: String?, extra: String = "") throws -> Read {
        let dir = root.appendingPathComponent("lt-\(name)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "Fix the build.\n".write(to: dir.appendingPathComponent("BRIEF.md"), atomically: true, encoding: .utf8)
        let life = lifetime.map { "x-dozable:\n  lifetime: \($0)\n" } ?? ""
        let text = """
        doz: space/3
        space: \(name)
        brief: BRIEF.md
        owner: ada
        \(life)folders:
          scratch: {}
        chat:
          rooms:
            \(name): { main: true, members: [owner] }
        agents:
          helper: { kind: claude-code, isolation: fenced, prompt: fix it }
        \(extra)
        """
        let file = dir.appendingPathComponent("\(name).space.yaml")
        try text.write(to: file, atomically: true, encoding: .utf8)
        return try read(file.path)
    }

    func lifetimePlan(_ r: Read) -> SpacePlan {
        SpaceUp.plan(r.intent, facts: recordedFacts(r.intent), specSHA: r.specSHA, sources: r.resolved.sources)
    }

    /// F1: a standing file's plan never says "Nothing persisted" or "removes everything"; it says what down keeps, and each
    /// owned thing is labelled persisted, with what down does to it.
    func test762AStandingPlanSaysWhatDownKeeps() throws {
        let p = lifetimePlan(try lifetimeFile("app", lifetime: "standing"))
        let text = p.summary.joined(separator: "\n")
        XCTAssertFalse(text.contains("Nothing persisted"), text)
        XCTAssertFalse(text.contains("removes everything"), text)
        XCTAssertFalse(text.contains("this run only"), text)
        XCTAssertTrue(text.contains("Standing (x-dozable.lifetime): down stops the run and keeps room app, agent helper and its conversation, scratch folder scratch"), text)
        XCTAssertFalse(text.contains("A clean room"))
        let scratch = try XCTUnwrap(p.steps.first { $0.subject == "folder scratch" })
        XCTAssertEqual(scratch.lifetime, "persisted")
        XCTAssertEqual(scratch.down, "kept on disk (standing)")
        let helper = try XCTUnwrap(p.steps.first { $0.subject == "agent helper" })
        XCTAssertEqual(helper.lifetime, "persisted")
        XCTAssertTrue(helper.down?.contains("kept with its conversation (standing)") == true, helper.down ?? "")
        for s in p.steps where s.kind != "workspace-start" { XCTAssertFalse((s.down ?? "").contains("removed"), "\(s.subject): \(s.down ?? "")") }
    }

    /// F1: what says `lifetime: run` itself inside a standing space still goes, and the plan says so.
    func test762AStandingPlanNamesWhatSaysLifetimeRun() throws {
        var i = try lifetimeFile("app2", lifetime: "standing").intent
        i.runLifetime = ["folder:scratch"]
        let q = SpaceUp.plan(i, facts: recordedFacts(i), specSHA: "x", sources: [])
        let text = q.summary.joined(separator: "\n")
        XCTAssertTrue(text.contains("it removes only what says lifetime: run (scratch folder scratch), archived first."), text)
        XCTAssertEqual(q.steps.first { $0.subject == "folder scratch" }?.lifetime, "run")
        XCTAssertEqual(q.steps.first { $0.subject == "folder scratch" }?.down, "copied into the run's archive, then removed")
    }

    /// F1 / F12: a runs file reads as before — what goes at down is named — and the workspace itself is never labelled a
    /// run's, in either lifetime, new or existing.
    func test762TheWorkspaceItselfIsNeverARunsAndRunsReadsAsBefore() throws {
        for life in [nil, "runs", "standing"] {
            let r = try lifetimeFile("app", lifetime: life)
            let p = lifetimePlan(r)
            let new = try XCTUnwrap(p.steps.first { $0.kind == "workspace-new" })
            XCTAssertEqual(new.lifetime, "persisted", "\(life ?? "none")")
            var f = recordedFacts(r.intent)
            f.record = record("app", space: true)
            let again = SpaceUp.plan(r.intent, facts: f, specSHA: r.specSHA, sources: [])
            XCTAssertEqual(again.steps.first { $0.kind == "workspace-edit" }?.lifetime, "persisted", "\(life ?? "none")")
            XCTAssertFalse(again.steps.contains { $0.kind == "workspace-new" })
            if life != "standing" {
                let text = p.summary.joined(separator: "\n")
                XCTAssertTrue(text.contains("Nothing persisted: down removes everything the space made."), text)
                XCTAssertEqual(p.steps.first { $0.subject == "folder scratch" }?.lifetime, "run")
                XCTAssertEqual(p.steps.first { $0.subject == "agent helper" }?.lifetime, "run")
            }
        }
    }

    /// F1b: the lifetime a workspace carries — a space file's as recorded (none: runs), standing without one.
    func test762TheLifetimeOfARecord() {
        XCTAssertEqual(SpaceRecordRef.lifetime(of: record("a", space: false)), "standing")
        XCTAssertEqual(SpaceRecordRef.lifetime(of: record("a", space: true)), "runs")
        var rec = record("a", space: true)
        var ref = SpaceRecordRef.of(rec) ?? SpaceRecordRef()
        ref.lifetime = "standing"
        ref.store(in: &rec)
        XCTAssertEqual(SpaceRecordRef.lifetime(of: rec), "standing")
    }
}

extension WorkspaceStateTests {
    /// F3: nothing running because a stop stopped it reads stopped; a sleep (or nothing said) still reads asleep; anything
    /// running outranks it.
    func test762StoppedIsNotAsleep() {
        let started = WorkspaceFlags(startedAt: t)
        XCTAssertEqual(S.derive(S.Input(agents: [.asleep, .asleep], flags: started, stopped: true)), .stopped)
        XCTAssertEqual(S.derive(S.Input(agents: [.asleep, .asleep], flags: started)), .asleep)
        XCTAssertEqual(S.derive(S.Input(agents: [.asleep, .running(sessions: ["idle"])], flags: started, stopped: true)), .idle)
        XCTAssertEqual(S.derive(S.Input(agents: [.asleep], flags: WorkspaceFlags(finishedAt: t, startedAt: t), stopped: true)), .finished)
        XCTAssertEqual(S.stopped.words, "stopped")
    }
}

extension WorkspaceLifecycleHostTests {
    func detail(_ c: HostCore, _ n: String = "demo") async throws -> WorkspaceDetail {
        let m = await ws(c, .workspaceShow, n)
        XCTAssertNil(m.error, m.error?.message ?? "")
        return try XCTUnwrap(m.result).decode(WorkspaceDetail.self)
    }

    func listed(_ c: HostCore, _ n: String = "demo") async throws -> WorkspaceRow {
        let m = await ws(c, .workspaceList, nil)
        XCTAssertNil(m.error, m.error?.message ?? "")
        return try XCTUnwrap(try XCTUnwrap(m.result).decode(WorkspaceListing.self).workspaces.first { $0.name == n })
    }

    /// F2 + F3: stop, then start, brings every agent stop stopped back — the manager by the start, each worker as wake wakes
    /// it (its conversation resumed) — and in between the workspace reads stopped, never asleep, in show and ls.
    func test762StopThenStartIsARoundTrip() async throws {
        let c = await lcore()
        try await started(c)
        let s = try ok(try await act(c, .stop))
        XCTAssertEqual(s.workspace?.state, "stopped")
        let s1 = try await detail(c).state
        XCTAssertEqual(s1, "stopped")
        let s2 = try await listed(c).state
        XCTAssertEqual(s2, "stopped")
        XCTAssertTrue(try XCTUnwrap(record()).agents.allSatisfy { $0.stoppedAt != nil })
        trace.reset()
        let m = await ws(c, .workspaceStart, "demo")
        XCTAssertNil(m.error, m.error?.message ?? "")
        let st = try XCTUnwrap(m.result).decode(WorkspaceStarted.self)
        XCTAssertEqual(Set(st.woke ?? []), ["bot1", "otto"], "every worker stop stopped, brought back by start")
        XCTAssertEqual(Set(trace.all), ["manager demo (again)", "worker demo-bot1 (again)", "worker demo-otto (again)"])
        XCTAssertTrue(workers.orders.suffix(2).allSatisfy(\.restart), "in place: their conversations resumed")
        XCTAssertTrue(try XCTUnwrap(record()).agents.allSatisfy { $0.stoppedAt == nil })
        XCTAssertEqual(log().filter { $0 == "agent-woke" }.count, 2)
        let s3 = try await detail(c).state
        XCTAssertNotEqual(s3, "stopped")
        // A second start: nothing left down, nothing woken again.
        trace.reset()
        let againMessage = await ws(c, .workspaceStart, "demo")
        let again = try XCTUnwrap(againMessage.result).decode(WorkspaceStarted.self)
        XCTAssertNil(again.woke)
        XCTAssertFalse(trace.all.contains { $0.hasPrefix("worker") })
    }

    /// F3: a sleep still reads asleep (the stop is what reads stopped); after a sleep, start brings the workers back too.
    func test762ASleepStillReadsAsleep() async throws {
        let c = await lcore()
        try await started(c)
        _ = try ok(try await act(c, .stop))
        _ = try ok(try await act(c, .wake))
        _ = try ok(try await act(c, .sleep))
        let s4 = try await detail(c).state
        XCTAssertEqual(s4, "asleep")
        let s5 = try await listed(c).state
        XCTAssertEqual(s5, "asleep")
    }

    /// F7: a finish's kept list holds only what is the workspace's own; the person's folder (given with --folder) is untouched.
    func test762FinishKeepsItsOwnAndLeavesYourFolderUntouched() async throws {
        let c = await lcore()
        try await started(c)
        let p = try await plan(c, .finish)
        XCTAssertFalse(p.keeps.contains { $0.path != nil || $0.text.contains("folder") }, "\(p.keeps)")
        XCTAssertEqual(p.untouched?.compactMap(\.path), [work.path])
        let f = try ok(try await act(c, .finish))
        XCTAssertTrue((f.kept ?? []).contains(work.path), "the --json contract: kept holds it (\(f.kept ?? []))")
        XCTAssertEqual(f.untouched, [work.path])
        let text = WorkspaceFinishInventory.lines(removed: f.removed ?? [], kept: f.kept ?? [], untouched: f.untouched ?? [], standing: true, archive: nil)
        XCTAssertFalse(try XCTUnwrap(text.first { $0.hasPrefix("kept:") }).contains(work.path), "\(text)")
        XCTAssertTrue(text.contains { $0.hasPrefix("untouched") && $0.contains(DisplayPath.tilde(work.path)) }, "\(text)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: work.path), "your folder: untouched")
    }
}

/// F5, the deletion-safety rows: a space's sandbox is removed only after its disk is saved as an image.
extension WorkspaceLifecycleHostTests {
    func boxSpace(_ name: String, persisted: Bool) throws -> SpaceFiles {
        try spaceFiles(name, agents: """
          w1: { kind: claude-code, where: "sandbox:box", prompt: build it }
        """, extra: """
        sandboxes:
          box: { image: claude-code, cpus: 2, memory: 2G }
        \(persisted ? "persist:\n  box-disk: { sandbox: box }\n" : "")
        """)
    }

    func downIn(_ c: HostCore, _ n: String, purge: Bool = false) async throws -> (SpaceDownPlan, HostMessage) {
        var r = HostRequest(.workspaceDownPlan)
        r.spaceDown = SpaceDownRequest(workspace: n, purge: purge ? true : nil)
        let pm = await c.handle(r)
        XCTAssertNil(pm.error, pm.error?.message ?? "")
        let p = try XCTUnwrap(pm.result).decode(SpaceDownPlan.self)
        var d = HostRequest(.workspaceDown)
        d.spaceDown = SpaceDownRequest(workspace: n, purge: purge ? true : nil, ifPlan: p.sha)
        return (p, await c.handle(d))
    }

    /// At down, a run-lifetime agent's own sandbox: its disk saved as an image first, named in the result, then removed.
    func test762DownSavesARunSandboxsDiskBeforeRemovingIt() async throws {
        try await withBriefHome {
            let c = await lcore()
            let up = try acted(try await spaceUpAct(c, try spaceRequest(try boxSpace("bx", persisted: false))))
            XCTAssertTrue(up.ok, up.results.map { "\($0.status) \($0.text)" }.joined(separator: " | "))
            XCTAssertEqual(workers.orders.last?.place, "bx-box")
            trace.reset()
            let (p, m) = try await downIn(c, "bx")
            XCTAssertTrue(p.steps.contains { $0.kind == "worker-end" && $0.text.contains("disk saved as an image, then the sandbox removed") },
                          p.steps.map(\.text).joined(separator: "; "))
            let d = try acted(m)
            XCTAssertTrue(d.ok, d.results.map { "\($0.status) \($0.text)" }.joined(separator: " | "))
            XCTAssertTrue(trace.all.contains("template bx-box as bx-box-tpl"), "\(trace.all)")
            XCTAssertEqual(d.savedDisks, ["bx-box": "bx-box-tpl"])
            let end = try XCTUnwrap(workers.ends.last { $0.name == "w1" })
            XCTAssertTrue(end.rm, "the sandbox removed — after its copy")
            XCTAssertTrue((d.removed ?? []).contains("sandbox/bx-box"))
            XCTAssertTrue(d.results.flatMap { $0.notes ?? [] }.contains { $0.contains("saved as the image bx-box-tpl") })
            XCTAssertTrue(((try? WorkspaceStore(store: store).log("bx")) ?? []).contains { $0.action == "template-kept" && $0.to == "bx-box-tpl" })
        }
    }

    /// A disk that cannot be saved is never removed: the step fails, the agent stays, its sandbox is kept, and down says why.
    func test762ADiskThatCannotBeSavedIsNeverRemoved() async throws {
        try await withBriefHome {
            let c = await lcore()
            let up = try acted(try await spaceUpAct(c, try spaceRequest(try boxSpace("bf", persisted: false))))
            XCTAssertTrue(up.ok)
            places.lock.withLock { places.failTemplate = true }
            let (_, m) = try await downIn(c, "bf")
            let d = try acted(m)
            XCTAssertFalse(d.ok, "a step failed")
            let failed = try XCTUnwrap(d.results.first { $0.kind == "worker-end" })
            XCTAssertEqual(failed.status, "failed")
            XCTAssertTrue(failed.text.contains("never removed without a copy"), failed.text)
            XCTAssertFalse(workers.ends.contains { $0.name == "w1" && $0.rm }, "nothing removed")
            XCTAssertFalse(trace.all.contains { $0.hasPrefix("rm ") })
            XCTAssertNil(try XCTUnwrap(record("bf")).agents.first { $0.name == "w1" }?.endedAt, "the agent stays")
            XCTAssertFalse((d.removed ?? []).contains("sandbox/bf-box"))
            XCTAssertNil(d.savedDisks)
            // Once a save can be made, down again does what is left — the copy first.
            places.lock.withLock { places.failTemplate = false }
            let (_, m2) = try await downIn(c, "bf")
            let d2 = try acted(m2)
            XCTAssertTrue(d2.ok, d2.results.map { "\($0.status) \($0.text)" }.joined(separator: " | "))
            XCTAssertEqual(d2.savedDisks, ["bf-box": "bf-box-tpl"])
            XCTAssertTrue(workers.ends.contains { $0.name == "w1" && $0.rm })
        }
    }

    /// At down --purge, a persisted sandbox: kept at down (no copy needed, nothing removed), then at --purge its disk saved
    /// as an image first, then removed; a failed save removes nothing.
    func test762PurgeSavesAPersistedSandboxsDiskBeforeRemovingIt() async throws {
        try await withBriefHome {
            let c = await lcore()
            let up = try acted(try await spaceUpAct(c, try spaceRequest(try boxSpace("bp", persisted: true))))
            XCTAssertTrue(up.ok, up.results.map { "\($0.status) \($0.text)" }.joined(separator: " | "))
            let (_, m) = try await downIn(c, "bp")
            let d = try acted(m)
            XCTAssertTrue(d.ok, d.results.map { "\($0.status) \($0.text)" }.joined(separator: " | "))
            XCTAssertFalse(trace.all.contains { $0.hasPrefix("rm ") || $0.hasPrefix("template") }, "a persisted sandbox stays at down: \(trace.all)")
            XCTAssertFalse(workers.ends.contains { $0.rm })
            // --purge, with a save that fails: nothing removed.
            places.lock.withLock { places.failTemplate = true }
            let (pp, pm) = try await downIn(c, "bp", purge: true)
            XCTAssertTrue(pp.steps.contains { $0.kind == "sandbox-rm" && $0.text.contains("disk as an image, then remove the sandbox") },
                          pp.steps.map(\.text).joined(separator: "; "))
            let bad = try acted(pm)
            XCTAssertFalse(bad.ok)
            XCTAssertEqual(bad.results.first { $0.kind == "sandbox-rm" }?.status, "failed")
            XCTAssertFalse(trace.all.contains("rm bp-box"), "never removed without a copy")
            // A save that works: the image first, then the removal; both named.
            places.lock.withLock { places.failTemplate = false }
            trace.reset()
            let (_, pm2) = try await downIn(c, "bp", purge: true)
            let good = try acted(pm2)
            XCTAssertTrue(good.ok, good.results.map { "\($0.status) \($0.text)" }.joined(separator: " | "))
            XCTAssertEqual(trace.all.filter { $0.hasPrefix("template") || $0.hasPrefix("rm ") }, ["template bp-box as bp-box-tpl", "rm bp-box"])
            XCTAssertEqual(good.savedDisks, ["bp-box": "bp-box-tpl"])
            XCTAssertTrue((good.removed ?? []).contains("sandbox/bp-box"))
        }
    }
}
