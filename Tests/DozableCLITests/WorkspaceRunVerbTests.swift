import DozableChat
import Foundation
import XCTest
@testable import DozableHost

/// The run verb (`workspace-run`, `doz workspace run W [GOAL]`) in an in-process daemon core with the lifecycle's fakes: one
/// run at a time (`run-open`, exit 3), a finished workspace reopened first, the goal given or the brief, the source, the run
/// it follows, the revision read, who opened it, the goal posted as the owner's message, the sessions started (or not, with
/// `noStart`), an archived workspace refused; `workspace-runs` carries the fields and never invents them for an older run.
extension WorkspaceLifecycleHostTests {
    func runVerb(_ c: HostCore, _ name: String = "demo", actAs: String? = nil, _ edit: (inout WorkspaceRequest) -> Void = { _ in }) async -> HostMessage {
        var w = WorkspaceRequest(name: name)
        edit(&w)
        var r = HostRequest(.workspaceRun)
        r.workspaceRequest = w
        r.actAs = actAs
        return await c.handle(r)
    }

    func opened(_ m: HostMessage, file: StaticString = #filePath, line: UInt = #line) throws -> WorkspaceRunOpened {
        XCTAssertNil(m.error, m.error?.message ?? "", file: file, line: line)
        return try XCTUnwrap(m.result, file: file, line: line).decode(WorkspaceRunOpened.self)
    }

    func lastPost(_ room: String = "demo") -> String? {
        rooms.lock.withLock { rooms.msgs[room]?.last }.flatMap { try? $0.field("content")?.goString("content") }
    }

    func testOneRunAtATimeAndAGoalOpensTheNextAfterFinish() async throws {
        let c = await lcore()
        try await started(c)
        // The start's run is open: a second one is refused, naming finish; nothing written.
        let before = try XCTUnwrap(record())
        let refused = await runVerb(c) { $0.goal = "Another goal" }
        XCTAssertEqual(refused.error?.code, .runOpen)
        XCTAssertEqual(ExitCodes.exit(for: .runOpen), 3)
        XCTAssertTrue(refused.error?.message.contains("doz workspace finish demo") == true, refused.error?.message ?? "")
        XCTAssertEqual(try XCTUnwrap(record()).runs, before.runs)
        // Finished, then a run with a goal: reopened, the goal posted as the owner's message, the agents started again.
        _ = try ok(try await act(c, .finish) { $0.noArchive = true })
        trace.reset()
        let o = try opened(await runVerb(c) { $0.goal = "Fix the failing test" })
        XCTAssertEqual(o.kind, "WorkspaceRun")
        XCTAssertEqual(o.state, "open")
        XCTAssertEqual(o.goal, "Fix the failing test")
        XCTAssertEqual(o.goalFrom, "given")
        XCTAssertEqual(o.source, WorkspaceRunSource(kind: "given"))
        XCTAssertEqual(o.openedBy, "owner")
        XCTAssertEqual(o.revision, 1, "the brief as made, never edited")
        XCTAssertTrue(o.posted)
        XCTAssertEqual(lastPost(), "Make the launch video.\n\nThis run's goal: Fix the failing test", "the brief, then the run's own goal")
        XCTAssertEqual(o.lessons, 0)
        XCTAssertEqual(Set(o.started ?? []), ["mira", "bot1", "otto"], "the manager and the workers a finish left down")
        XCTAssertTrue(trace.all.contains("manager demo (again)"), trace.all.joined(separator: ", "))
        let r = try XCTUnwrap(record())
        XCTAssertNil(r.flags.finishedAt)
        XCTAssertEqual(r.runs.count, 2)
        XCTAssertEqual(r.openRun?.id, o.id)
        XCTAssertEqual(r.openRun?.goal, "Fix the failing test")
        XCTAssertTrue(log().contains("reopened") && log().contains("goal-posted"))
        // The first run (the start's) took the brief.
        XCTAssertEqual(r.runs[0].goalFrom, "brief")
        XCTAssertEqual(r.runs[0].source?.kind, "brief")
        XCTAssertEqual(r.runs[0].goal, "Make the launch video.\n")
    }

    func testNoGoalTakesTheBriefAtItsRevisionAndASourceAndAFollowsAreRecorded() async throws {
        let c = await lcore()
        try await started(c)
        let first = try XCTUnwrap(record()?.openRun?.id)
        // An edit of the brief is the work description's second revision.
        let e = await ws(c, .workspaceEdit, "demo") { $0.brief = "Make the launch video, shorter.\n" }
        XCTAssertNil(e.error, e.error?.message ?? "")
        _ = try ok(try await act(c, .finish) { $0.noArchive = true })
        let o = try opened(await runVerb(c) { $0.noStart = true })
        XCTAssertEqual(o.goalFrom, "brief")
        XCTAssertEqual(o.goal, "Make the launch video, shorter.\n")
        XCTAssertEqual(o.source, WorkspaceRunSource(kind: "brief", revision: 2))
        XCTAssertEqual(o.revision, 2)
        XCTAssertEqual(lastPost(), "Make the launch video, shorter.", "the brief posted as the start posts it")
        _ = try ok(try await act(c, .finish) { $0.noArchive = true })
        // run:ID and --follows: recorded; a source kind or a run that does not exist: 65, nothing written.
        let before = try XCTUnwrap(record()).runs
        for (src, follows) in [("nightly", nil), ("run:2000-01-01-1", nil), ("given", nil), ("run:\(o.id)", "2000-01-01-1")] as [(String, String?)] {
            let m = await runVerb(c) { $0.source = src; $0.follows = follows; $0.noStart = true }
            XCTAssertEqual(m.error.map { ExitCodes.exit(for: $0) }, 65, "\(src) \(follows ?? ""): \(m.error?.message ?? "accepted")")
        }
        XCTAssertEqual(try XCTUnwrap(record()).runs, before, "nothing written by a refusal")
        let second = try opened(await runVerb(c) { $0.goal = "Second"; $0.source = "run:\(first)"; $0.follows = first; $0.noStart = true })
        XCTAssertEqual(second.source, WorkspaceRunSource(kind: "run", ref: first))
        XCTAssertEqual(second.follows, first)
        _ = try ok(try await act(c, .finish) { $0.noArchive = true })
        let third = try opened(await runVerb(c) { $0.goal = "Nightly"; $0.source = "schedule:every night at 2"; $0.noStart = true })
        XCTAssertEqual(third.source, WorkspaceRunSource(kind: "schedule", ref: "every night at 2"))
    }

    func testNoStartStartsNothingAndAnArchivedWorkspaceIsRefused() async throws {
        let c = await lcore()
        try await started(c)
        _ = try ok(try await act(c, .finish) { $0.noArchive = true })
        trace.reset()
        let o = try opened(await runVerb(c) { $0.goal = "Look only"; $0.noStart = true })
        XCTAssertNil(o.started)
        XCTAssertFalse(trace.all.contains { $0.hasPrefix("manager") || $0.hasPrefix("worker") || $0.hasPrefix("wake") }, trace.all.joined(separator: ", "))
        XCTAssertTrue(o.notes?.contains { $0.contains("doz workspace start demo") } == true)
        _ = try ok(try await act(c, .finish) { $0.noArchive = true })
        _ = try ok(try await act(c, .archive) { $0.noArchive = true })
        let m = await runVerb(c) { $0.goal = "Again" }
        XCTAssertEqual(m.error?.code, .invalidPhase)
        XCTAssertTrue(m.error?.message.contains("archived") == true)
    }

    /// The owner is never gated; an agent's run needs run.open (off until granted), its finish run.finish — and Dozable never
    /// posts the goal for an agent.
    func testAnAgentOpensARunOnlyWithRunOpen() async throws {
        let c = await lcore()
        try await started(c)
        _ = try ok(try await act(c, .finish) { $0.noArchive = true })
        var q = HostRequest(.workspaceRun)
        q.workspaceRequest = WorkspaceRequest(name: "demo")
        q.actAs = "demo/mira"
        XCTAssertEqual(PermissionGate.refusal(q, store: store)?.code, .notPermitted, "nothing says anything: ask, refused")
        XCTAssertTrue(PermissionGate.refusal(q, store: store)?.message.contains("run.open") == true)
        try GrantStore(store: store).write(GrantsFile(grants: [Grant(subject: .agent("demo", "mira"), perm: "run.open", answer: .allow, scope: .workspace("demo"))]))
        XCTAssertNil(PermissionGate.refusal(q, store: store))
        let posts = rooms.lock.withLock { rooms.msgs["demo"]?.count ?? 0 }
        let o = try opened(await runVerb(c, actAs: "demo/mira") { $0.goal = "Fix the failing test"; $0.noStart = true })
        XCTAssertEqual(o.openedBy, "mira")
        XCTAssertFalse(o.posted)
        XCTAssertEqual(rooms.lock.withLock { rooms.msgs["demo"]?.count ?? 0 }, posts, "nothing posted for an agent")
        var f = HostRequest(.workspaceFinish)
        f.workspaceRequest = WorkspaceRequest(name: "demo")
        f.actAs = "demo/mira"
        XCTAssertEqual(ActionClasses.classify(f), .needs(["run.finish"], .workspace("demo")))
        XCTAssertTrue(PermissionGate.refusal(f, store: store)?.message.contains("run.finish") == true)
        XCTAssertTrue(GrantPermissions.isKnown("run.open") && GrantPermissions.isKnown("run.finish"))
    }

    func testRunsListTheFieldsAndAnOlderRunHasNone() async throws {
        let c = await lcore()
        try await started(c)
        _ = try ok(try await act(c, .finish) { $0.noArchive = true })
        let o = try opened(await runVerb(c) { $0.goal = "Fix the failing test"; $0.noStart = true })
        // A run recorded before 765: none of the fields.
        var r = try XCTUnwrap(record())
        r.runs[0].goal = nil; r.runs[0].goalFrom = nil; r.runs[0].source = nil; r.runs[0].revision = nil; r.runs[0].openedBy = nil
        try WorkspaceStore(store: store).write(r)
        let ro = await lcore(readOnly: true)
        let lm = await ws(ro, .workspaceRuns, "demo")
        let l = try XCTUnwrap(lm.result).decode(WorkspaceRunsListing.self)
        let old = try XCTUnwrap(l.runs.first)
        XCTAssertNil(old.goal); XCTAssertNil(old.goalFrom); XCTAssertNil(old.source); XCTAssertNil(old.revision); XCTAssertNil(old.openedBy)
        XCTAssertNotNil(old.usage?.durationMs, "its length is a fact, not invented")
        let new = try XCTUnwrap(l.runs.first { $0.id == o.id })
        XCTAssertEqual(new.goal, "Fix the failing test")
        XCTAssertEqual(new.goalFrom, "given")
        XCTAssertEqual(new.source?.kind, "given")
        XCTAssertEqual(new.revision, 1)
        XCTAssertEqual(new.openedBy, "owner")
        XCTAssertEqual(new.archiveStatus, "open")
        // And state's run condition says it.
        let st = await ws(ro, .workspaceState, "demo") { $0.withConditions = true }
        XCTAssertNil(st.error, st.error?.message ?? "")
    }

    func testTheSourceIsReadStrictly() throws {
        let runs = [WorkspaceRun(id: "2026-11-23-1", startedAt: Date())]
        XCTAssertEqual(try WorkspaceRuns.source("ask:the owner asked in chat", existing: runs), WorkspaceRunSource(kind: "ask", ref: "the owner asked in chat"))
        XCTAssertEqual(try WorkspaceRuns.source("run:2026-11-23-1", existing: runs), WorkspaceRunSource(kind: "run", ref: "2026-11-23-1"))
        XCTAssertEqual(try WorkspaceRuns.source("brief", existing: runs), WorkspaceRunSource(kind: "brief"))
        for bad in ["cron:x", "run:2026-11-23-2", "run", "ask:", "brief:x", "schedule:a\nb"] {
            XCTAssertThrowsError(try WorkspaceRuns.source(bad, existing: runs), bad) { XCTAssertEqual(ExitCodes.exit(for: HostError.from($0)), 65, bad) }
        }
        XCTAssertEqual(WorkspaceRuns.descriptionRevision([WorkspaceLogEntry(action: "created"), WorkspaceLogEntry(action: "brief-edited"),
                                                          WorkspaceLogEntry(action: "refs-edited"), WorkspaceLogEntry(action: "slept")]), 3)
    }
}
