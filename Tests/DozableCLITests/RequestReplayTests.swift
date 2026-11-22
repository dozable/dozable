import Foundation
import XCTest
@testable import DozableKit
@testable import DozableHost
@testable import DozableCLI

/// `--request-id` (`RequestReplay`): a replay answers the first answer with `replayed: true` and does nothing again; the same
/// id with other arguments is `request-id-reused` (exit 3), naming the fields and never a value; a failure is not kept; an id
/// expires after 24 h; ids survive a daemon restart; ids are per command kind; two at once with one id never both run. The
/// store's bound and its files. The scratch store, fake chat and launchers of `WorkspaceWorkerTests`.
extension WorkspaceWorkerTests {
    final class Clock: @unchecked Sendable {
        let lock = NSLock()
        var t = Date()
        var now: Date { lock.withLock { t } }
        func advance(_ s: TimeInterval) { lock.withLock { t += s } }
    }

    func once(_ c: HostCore, _ op: HostOp, id: String?, _ edit: (inout HostRequest) -> Void) async -> HostMessage {
        var r = HostRequest(op)
        r.requestID = id
        edit(&r)
        return await c.handle(r)
    }

    func newReq(_ name: String, brief: String = "Make the launch video.\n") -> (inout HostRequest) -> Void {
        let path = work.path
        return { r in
            var w = WorkspaceRequest(name: name)
            w.brief = brief
            w.folders = [WorkspaceFolder(path: path)]
            r.workspaceRequest = w
        }
    }

    func addReq(_ workspace: String, _ name: String?, task: String = "Review the fix") -> (inout HostRequest) -> Void {
        { r in
            var q = WorkerRequest(workspace: workspace, name: name)
            q.task = task
            r.workerRequest = q
        }
    }

    func testAReplayAnswersTheFirstAnswerAndMakesNothingAgain() async throws {
        let c = await wcore()
        let first = await once(c, .workspaceNew, id: "r-1", newReq("app"))
        XCTAssertNil(first.error, first.error?.message ?? "")
        XCTAssertNil(first.result?["replayed"], "the first answer is not a replay")
        let logBefore = try WorkspaceStore(store: store).log("app").count
        let again = await once(c, .workspaceNew, id: "r-1", newReq("app"))
        XCTAssertNil(again.error, again.error?.message ?? "")
        let d = try XCTUnwrap(again.result).decode(WorkspaceDetail.self)
        XCTAssertEqual(d.replayed, true)
        var plain = try XCTUnwrap(again.result)
        if case .object(var o) = plain { o["replayed"] = nil; plain = .object(o) }
        XCTAssertEqual(plain, first.result, "exactly the first answer, with replayed added")
        XCTAssertEqual(try WorkspaceStore(store: store).log("app").count, logBefore, "nothing was done again")
        // Without an id the same request is refused as it always was: it exists.
        let plainAgain = await once(c, .workspaceNew, id: nil, newReq("app"))
        XCTAssertEqual(plainAgain.error.map { ExitCodes.exit(for: $0) }, 4)
    }

    func testTheSameIdWithOtherArgumentsIsRefusedNamingWhatDiffered() async throws {
        let c = await wcore()
        let m1 = await once(c, .workspaceNew, id: "r-1", newReq("app", brief: "first brief"))
        XCTAssertNil(m1.error)
        let m = await once(c, .workspaceNew, id: "r-1", newReq("app", brief: "secret-ish other brief"))
        let e = try XCTUnwrap(m.error)
        XCTAssertEqual(e.code, .requestIDReused)
        XCTAssertEqual(e.code.rawValue, "request-id-reused")
        XCTAssertEqual(ExitCodes.exit(for: e), 3)
        XCTAssertTrue(e.message.contains("--brief"), e.message)
        XCTAssertFalse(e.message.contains("first brief") || e.message.contains("secret-ish"), "never a value: \(e.message)")
        let other = await once(c, .workspaceNew, id: "r-1", newReq("app2", brief: "first brief"))
        XCTAssertEqual(other.error?.code, .requestIDReused)
        XCTAssertTrue(other.error?.message.contains("NAME") == true, other.error?.message ?? "")
        XCTAssertNil(try WorkspaceStore(store: store).read("app2"), "nothing made")
        // The kept file holds hashes of the arguments, never the arguments.
        let files = try FileManager.default.contentsOfDirectory(atPath: RequestReplayStore(store: store).root)
        XCTAssertEqual(files.filter { $0.hasSuffix(".json") }.count, 1)
        let raw = try String(contentsOfFile: RequestReplayStore(store: store).root + "/" + files[0], encoding: .utf8)
        XCTAssertFalse(raw.contains("secret-ish"))
        let st = try FileManager.default.attributesOfItem(atPath: RequestReplayStore(store: store).root + "/" + files[0])
        XCTAssertEqual((st[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testAFailureIsNotKeptSoARetryRunsForReal() async throws {
        let c = await wcore()
        // No folder that exists: refused.
        let bad = await once(c, .workspaceNew, id: "r-3") { r in
            var w = WorkspaceRequest(name: "app")
            w.brief = "x"
            w.folders = [WorkspaceFolder(path: self.root.appendingPathComponent("missing").path)]
            r.workspaceRequest = w
        }
        XCTAssertNotNil(bad.error)
        XCTAssertNil(RequestReplayStore(store: store).read(.workspaceNew, "r-3"), "a failure is not kept")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("missing"), withIntermediateDirectories: true)
        let good = await once(c, .workspaceNew, id: "r-3") { r in
            var w = WorkspaceRequest(name: "app")
            w.brief = "x"
            w.folders = [WorkspaceFolder(path: WorkspaceStore.resolved(self.root.appendingPathComponent("missing").path))]
            r.workspaceRequest = w
        }
        XCTAssertNil(good.error, good.error?.message ?? "")
        XCTAssertNil(good.result?["replayed"], "it ran for real")
        XCTAssertNotNil(try WorkspaceStore(store: store).read("app"))
    }

    func testAnIdExpiresAfterADay() async throws {
        let clock = Clock()
        let c = await wcore()
        await c.setRequestReplayClock { clock.now }
        let m2 = await once(c, .workspaceNew, id: "r-4", newReq("app"))
        XCTAssertNil(m2.error)
        clock.advance(RequestReplay.ttl - 60)
        let m3 = await once(c, .workspaceNew, id: "r-4", newReq("app"))
        XCTAssertEqual(m3.result?["replayed"], .bool(true), "kept for a day")
        clock.advance(120)
        let late = await once(c, .workspaceNew, id: "r-4", newReq("app"))
        XCTAssertEqual(late.error.map { ExitCodes.exit(for: $0) }, 4, "expired: it runs for real (and the workspace exists)")
        XCTAssertNil(RequestReplayStore(store: store, now: { clock.now }).read(.workspaceNew, "r-4"))
    }

    func testIdsSurviveADaemonRestart() async throws {
        let c = await wcore()
        let m4 = await once(c, .workspaceNew, id: "r-5", newReq("app"))
        XCTAssertNil(m4.error)
        let c2 = await wcore()           // a new daemon on the same store
        let m = await once(c2, .workspaceNew, id: "r-5", newReq("app"))
        XCTAssertNil(m.error, m.error?.message ?? "")
        XCTAssertEqual(m.result?["replayed"], .bool(true))
    }

    func testIdsAreScopedPerCommandKind() async throws {
        let c = await wcore()
        try await started(c)
        let m5 = await once(c, .workspaceNew, id: "same", newReq("app"))
        XCTAssertNil(m5.error)
        let a = await once(c, .workerAdd, id: "same", addReq("demo", "reviewer"))
        XCTAssertNil(a.error, "another kind: another id (\(a.error?.message ?? ""))")
        XCTAssertNil(a.result?["replayed"])
    }

    func testAWorkerAddReplayAddsOneWorker() async throws {
        let c = await wcore()
        try await started(c)
        let first = try added(await once(c, .workerAdd, id: "r-2", addReq("demo", "reviewer")))
        XCTAssertNil(first.replayed)
        let again = try added(await once(c, .workerAdd, id: "r-2", addReq("demo", "reviewer")))
        XCTAssertEqual(again.replayed, true)
        XCTAssertEqual(again.worker.name, "reviewer")
        XCTAssertEqual(workers.orders.count, 1, "launched once")
        XCTAssertEqual(try record("demo")?.agents.filter { $0.name == "reviewer" }.count, 1)
        let other = await once(c, .workerAdd, id: "r-2", addReq("demo", "reviewer", task: "Another task"))
        XCTAssertEqual(other.error?.code, .requestIDReused)
        XCTAssertTrue(other.error?.message.contains("--task") == true, other.error?.message ?? "")
    }

    func testTwoAtOnceWithOneIdNeverBothRun() async throws {
        let c = await wcore()
        try await started(c)
        var r = HostRequest(.workerAdd)
        r.requestID = "r-6"
        addReq("demo", "reviewer")(&r)
        let req = r
        let ms = await withTaskGroup(of: HostMessage.self) { g in
            for _ in 0..<4 { g.addTask { await c.handle(req) } }
            var out: [HostMessage] = []
            for await m in g { out.append(m) }
            return out
        }
        XCTAssertEqual(ms.compactMap(\.error).map(\.message), [], "every one answered")
        XCTAssertEqual(ms.filter { $0.result?["replayed"] == .bool(true) }.count, 3, "one ran, three replayed")
        XCTAssertEqual(workers.orders.count, 1)
        XCTAssertEqual(try record("demo")?.agents.filter { $0.name == "reviewer" }.count, 1)
    }

    func testAdoptAndGrantTakeAnId() async throws {
        let c = await wcore()
        let grant: (inout HostRequest) -> Void = { r in
            var p = PermissionsRequest(agent: "role:worker")
            p.words = ["net.allow=allow"]
            p.everywhere = true
            p.untilTyped = "2h"
            p.until = Date().addingTimeInterval(7200)
            r.permissionsRequest = p
        }
        let g1 = await once(c, .permissionsGrant, id: "g-1", grant)
        XCTAssertNil(g1.error, g1.error?.message ?? "")
        let grantsAfterFirst = GrantStore(store: store).readOrEmpty().grants.count
        // A retry a moment later: `until` moved with the clock, but it was typed the same.
        let g2 = await once(c, .permissionsGrant, id: "g-1") { r in grant(&r); r.permissionsRequest?.until = Date().addingTimeInterval(7300) }
        XCTAssertNil(g2.error, g2.error?.message ?? "")
        XCTAssertEqual(try XCTUnwrap(g2.result).decode(PermissionsChanged.self).replayed, true)
        XCTAssertEqual(GrantStore(store: store).readOrEmpty().grants.count, grantsAfterFirst, "granted once")
        // adopt: the request id is checked before the work (an invalid id is a value refused, nothing done).
        let bad = await once(c, .workspaceAdopt, id: "no spaces allowed") { r in r.workspaceRequest = WorkspaceRequest(name: "x") }
        XCTAssertEqual(bad.error?.code, .invalidValue)
        XCTAssertEqual(bad.error.map { ExitCodes.exit(for: $0) }, 65)
    }

    // MARK: the store

    func testTheStoreIsBoundedAndPrunesTheExpired() throws {
        let clock = Clock()
        let s = RequestReplayStore(store: store, now: { clock.now })
        for i in 0..<5 { try s.record(.workspaceNew, "id-\(i)", fields: ["name": "h"], answer: .object(["name": .string("n\(i)")])) }
        XCTAssertEqual(s.count(), 5)
        s.prune(keeping: 3)
        XCTAssertEqual(s.count(), 3, "the oldest go past the bound")
        clock.advance(RequestReplay.ttl + 1)
        try s.record(.workspaceNew, "fresh", fields: [:], answer: .null)
        // The files' times are real: an expired entry is pruned on the write and never answers.
        XCTAssertNil(s.read(.workspaceNew, "id-4"))
        XCTAssertNotNil(s.read(.workspaceNew, "fresh"))
        XCTAssertEqual(s.count(), 1)
        XCTAssertNil(s.read(.workerAdd, "fresh"), "per kind")
    }

    func testTheDifferencesAreFlagNames() {
        XCTAssertEqual(RequestReplay.differences(["brief": "a", "folders": "b"], ["brief": "x", "folders": "b", "workers": "w"], op: .workspaceNew),
                       ["--brief", "--worker"])
        XCTAssertEqual(RequestReplay.flagName("managerIsolation", op: .workspaceNew), "--manager-isolation")
        XCTAssertEqual(RequestReplay.flagName("asName", op: .workspaceAdopt), "--as")
        XCTAssertNoThrow(try RequestReplay.validate("0b5a1c2e-7f3d-4c1a-9e1f-2f6d3b8a9c10"))
        XCTAssertThrowsError(try RequestReplay.validate(""))
        XCTAssertThrowsError(try RequestReplay.validate(String(repeating: "a", count: 129)))
        XCTAssertThrowsError(try RequestReplay.validate("r/1"))
    }

    func testTheCommandsSendTheId() throws {
        let n = try WorkspaceNew.parse(["app", "--brief", "x", "--request-id", "r-1"])
        XCTAssertEqual(n.requestID, "r-1")
        XCTAssertEqual(try WorkerAdd.parse(["demo", "reviewer", "--task", "t", "--request-id", "r-2"]).requestID, "r-2")
        XCTAssertEqual(try WorkspaceAdopt.parse(["demo", "box", "--request-id", "r-3"]).requestID, "r-3")
    }
}
