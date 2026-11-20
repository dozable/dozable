import DozableChat
import Foundation
import XCTest
@testable import DozableHost
@testable import DozableCLI

/// `doz workspace up -f` in an in-process daemon core (the lifecycle's fakes; a scratch store; the brief's home a scratch
/// folder): the reference and `space.json` recorded, requests recorded and never granted (`grants.json` byte-identical),
/// the brief read from the file and never copied into the store, bypass in the worker's own argv, an owned sandbox named
/// `<space>-<name>`, every unfenced agent confirmed (exactly the plan's set, whatever set it), a plan changed since the
/// look refused with nothing done, a second up making nothing, and a partial up finished by the next.
extension WorkspaceLifecycleHostTests {
    struct SpaceFiles {
        var file: String
        var brief: String
    }

    func spaceFiles(_ name: String = "sp", agents: String, extra: String = "", defaults: String? = nil) throws -> SpaceFiles {
        let dir = root.appendingPathComponent("spaces-\(name)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "Make the thing.\n".write(to: dir.appendingPathComponent("BRIEF.md"), atomically: true, encoding: .utf8)
        var head = "doz: space/3\n"
        if let d = defaults {
            try d.write(to: dir.appendingPathComponent("defaults.yaml"), atomically: true, encoding: .utf8)
            head += "extends: ./defaults.yaml\n"
        }
        let text = head + """
        space: \(name)
        brief: BRIEF.md
        owner: ada
        chat:
          rooms:
            \(name): { main: true, members: [owner] }
        agents:
        \(agents)
        \(extra)
        """
        let file = dir.appendingPathComponent("\(name).space.yaml")
        try text.write(to: file, atomically: true, encoding: .utf8)
        return SpaceFiles(file: file.path, brief: dir.appendingPathComponent("BRIEF.md").path)
    }

    func spaceRequest(_ s: SpaceFiles) throws -> SpaceRequest {
        let r = SpaceResolver().resolve(s.file)
        let (problems, model) = r.check()
        XCTAssertFalse(problems.contains(where: \.isError), problems.map(\.text).joined(separator: "\n"))
        return r.request(profiles: [], brief: spaceBriefLook(try XCTUnwrap(model).brief, file: r.file))
    }

    func spacePlanned(_ c: HostCore, _ q: SpaceRequest) async throws -> SpacePlan {
        var r = HostRequest(.workspaceUpPlan)
        r.space = q
        let m = await c.handle(r)
        XCTAssertNil(m.error, m.error?.message ?? "")
        return try XCTUnwrap(m.result).decode(SpacePlan.self)
    }

    /// The plan, then up acting on it (as the CLI does).
    func spaceUpAct(_ c: HostCore, _ q: SpaceRequest, confirmed: [String]? = nil, ifPlan: String? = nil) async throws -> HostMessage {
        let p = try await spacePlanned(c, q)
        var x = q
        x.ifPlan = ifPlan ?? p.sha
        x.confirmed = confirmed ?? p.confirm
        var r = HostRequest(.workspaceUp)
        r.space = x
        return await c.handle(r)
    }

    func acted(_ m: HostMessage, file: StaticString = #filePath, line: UInt = #line) throws -> SpaceActed {
        XCTAssertNil(m.error, m.error?.message ?? "", file: file, line: line)
        return try XCTUnwrap(m.result, file: file, line: line).decode(SpaceActed.self)
    }

    func withBriefHome<T>(_ body: () async throws -> T) async rethrows -> T {
        setenv("DOZ_TEST_BRIEF_HOME", root.path, 1)
        defer { unsetenv("DOZ_TEST_BRIEF_HOME") }
        return try await body()
    }

    func testUpRecordsTheSpaceAndItsRequestsAndGrantsNothing() async throws {
        try await withBriefHome {
            let c = await lcore()
            let s = try spaceFiles(agents: """
              w1:
                kind: claude-code
                isolation: fenced
                permissions: bypass
                prompt: list the files
                requests: { grants: [net.allow], reason: post review comments }
            """, extra: """
            folders:
              notes: {}
            """)
            // A grants file exists before: up never writes it.
            let gs = GrantStore(store: store)
            try gs.write(GrantsFile())
            let grantsBefore = try Data(contentsOf: URL(fileURLWithPath: gs.file))
            let done = try acted(try await spaceUpAct(c, try spaceRequest(s)))
            XCTAssertTrue(done.ok, done.results.map { "\($0.status) \($0.text)" }.joined(separator: " | "))
            let rec = try XCTUnwrap(record("sp"))
            let ref = try XCTUnwrap(SpaceRecordRef.of(rec))
            XCTAssertEqual(ref.file, "sp.space.yaml")
            XCTAssertEqual(ref.brief?.path.hasSuffix("/BRIEF.md"), true)
            XCTAssertNotNil(ref.upAt)
            XCTAssertEqual(ref.owned?.agents["w1"], "run")
            XCTAssertEqual(ref.scratch?.count, 1)
            // The merged spec beside the record, 0600.
            let spec = WorkspaceStore.resolved(WorkspaceStore(store: store).folder("sp")) + "/space.json"
            let attrs = try FileManager.default.attributesOfItem(atPath: spec)
            XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            // The brief: the file's, posted at the kick-off; the store's brief.md never a copy.
            XCTAssertEqual(WorkspaceStore(store: store).readBrief("sp"), "")
            XCTAssertEqual(rec.brief.sha256, WorkspaceStore.sha256(Data("Make the thing.\n".utf8)))
            XCTAssertTrue(trace.all.contains("post sp"), "the brief is the run's first message")
            // Requested, not granted: the record's requests, logged once; grants.json byte-identical.
            XCTAssertEqual(rec.permissions?.requests.count, 1)
            XCTAssertEqual(rec.permissions?.grants.count ?? 0, 0)
            XCTAssertTrue(log("sp").contains("request-recorded"))
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: gs.file)), grantsBefore, "up never writes a grant")
            // Bypass: in the worker's own argv.
            let o = try XCTUnwrap(workers.orders.last { $0.name == "w1" })
            XCTAssertTrue(MacPlace.bypassesPermissions(o.plan.argv), o.plan.argv.joined(separator: " "))
            XCTAssertFalse(o.plan.argv.contains("dontAsk"))
            // The scratch folder: under the projects folder's .runs, never the store, attached to the workspace.
            let scratch = try XCTUnwrap(ref.scratch?.first)
            XCTAssertTrue(scratch.path.contains("/.runs/sp/\(rec.openRun?.id ?? "?")/notes"), scratch.path)
            XCTAssertFalse(scratch.path.hasPrefix(WorkspaceStore.resolved(store.root.path)))
            XCTAssertTrue(rec.folders.contains { $0.path == scratch.path })
            // A second up makes nothing: every step already there.
            let before = workers.orders.count
            let again = try acted(try await spaceUpAct(c, try spaceRequest(s)))
            XCTAssertTrue(again.ok)
            XCTAssertEqual(again.results.filter { $0.status == "done" }.map(\.kind), [], again.results.map { "\($0.kind) \($0.status)" }.joined(separator: ", "))
            XCTAssertEqual(workers.orders.count, before)
            XCTAssertEqual(log("sp").filter { $0 == "request-recorded" }.count, 1, "a request is logged once")
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: gs.file)), grantsBefore)
        }
    }

    func testEveryUnfencedAgentIsConfirmedAtEveryUpAndAChangedPlanIsRefused() async throws {
        try await withBriefHome {
            let c = await lcore()
            // Unfenced inherited from a defaults file: still confirmed.
            let s = try spaceFiles(agents: """
              w1: { kind: claude-code, isolation: unfenced, prompt: list the files }
            """)
            let q = try spaceRequest(s)
            let p = try await spacePlanned(c, q)
            XCTAssertEqual(p.confirm, ["w1"])
            // Not confirmed: refused, nothing made.
            var m = try await spaceUpAct(c, q, confirmed: [])
            XCTAssertEqual(m.error?.code, .invalidPhase, m.error?.message ?? "")
            XCTAssertNil(try record("sp"), "nothing made")
            // A plan changed since the look: refused, nothing made.
            m = try await spaceUpAct(c, q, ifPlan: String(repeating: "0", count: 64))
            XCTAssertEqual(m.error?.code, .invalidPhase)
            XCTAssertTrue(m.error?.message.contains("changed since you looked") == true)
            XCTAssertNil(try record("sp"))
            XCTAssertTrue(workers.orders.isEmpty)
            // Confirmed: up runs it.
            let done = try acted(try await spaceUpAct(c, q, confirmed: ["w1"]))
            XCTAssertTrue(done.ok, done.results.map { "\($0.status) \($0.text)" }.joined(separator: " | "))
            XCTAssertEqual(workers.orders.last?.isolation, .unfenced)
        }
    }

    func testAnOwnedSandboxIsNamedForTheSpace() async throws {
        try await withBriefHome {
            let c = await lcore()
            let s = try spaceFiles(agents: """
              w1: { kind: claude-code, where: "sandbox:box", prompt: build it }
            """, extra: """
            sandboxes:
              box: { image: claude-code, cpus: 2, memory: 2G }
            """)
            let p = try await spacePlanned(c, try spaceRequest(s))
            let add = try XCTUnwrap(p.steps.first { $0.kind == "worker-add" })
            XCTAssertEqual(add.worker?.newSandbox, "sp-box")
            XCTAssertEqual(add.worker?.isolation, "vm")
            let done = try acted(try await spaceUpAct(c, try spaceRequest(s)))
            XCTAssertTrue(done.ok, done.results.map { "\($0.status) \($0.text)" }.joined(separator: " | "))
            XCTAssertEqual(workers.orders.last?.place, "sp-box")
        }
    }

    func testAPartialUpStopsAndTheNextUpMakesOnlyWhatIsMissing() async throws {
        try await withBriefHome {
            let c = await lcore()
            let s = try spaceFiles(agents: """
              w1: { kind: claude-code, prompt: one }
              w2: { kind: claude-code, prompt: two }
              w3: { kind: claude-code, prompt: three }
            """)
            // Another session already holds w2's place: its add fails.
            workers.places["sp-w2"] = ManagerPlaceInfo(exists: true, running: true)
            let first = try acted(try await spaceUpAct(c, try spaceRequest(s)))
            XCTAssertFalse(first.ok)
            XCTAssertEqual(first.results.first { $0.subject == "agent w2" }?.status, "failed")
            XCTAssertEqual(first.results.first { $0.subject == "agent w3" }?.status, "not-run")
            XCTAssertNotNil(try XCTUnwrap(record("sp")).openRun, "the run stays open")
            workers.places["sp-w2"] = nil
            let second = try acted(try await spaceUpAct(c, try spaceRequest(s)))
            XCTAssertTrue(second.ok, second.results.map { "\($0.status) \($0.text)" }.joined(separator: " | "))
            XCTAssertEqual(second.results.filter { $0.status == "done" }.map(\.subject), ["agent w2", "agent w3"])
            let third = try acted(try await spaceUpAct(c, try spaceRequest(s)))
            XCTAssertEqual(third.results.filter { $0.status == "done" }.count, 0)
        }
    }
}
