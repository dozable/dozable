import DozableChat
import DozableKit
import Foundation
import XCTest
@testable import DozableHost
@testable import DozableCLI

/// `workspace-state` (`SpaceState`, `SpaceStateBuilder`): the editor's sha reproduced for all seven of its fixtures (and
/// again through Dozable's own types and key order); the builder over the fixtures' space (`example-space`, the same file)
/// in each situation they record — running, asleep, down, drift, not known — compared as facts (type, subject, state,
/// lifetime, activity, drift kind; services, details and what Dozable does not observe left out); a permission prompt as
/// `waiting` with attention `permission`; a program's message only for a viewer who may see its session, never in a
/// detail; the same facts the same sha.
final class SpaceStateTests: XCTestCase {
    static let fixtures = Pins.packageRoot.appendingPathComponent("Tests/DozableCLITests/Fixtures/space-state")
    static let names = ["answered", "asleep", "attention", "down", "drift", "running", "unknown"]
    static let exampleSpace = """
    doz: space/3
    space: example-space
    title: An example space
    brief: BRIEF.md
    owner: ada
    folders:
      repo: { external: ~/work/example-repo }
      scratch: {}
    sandboxes:
      build-vm: { image: claude-code }
    persist:
      vm-disk: { sandbox: build-vm }
      team-chat: { room: team }
    agents:
      manager: { external: { bot: manager }, role: manager }
      worker:
        kind: claude-code
        role: worker
        isolation: fenced
        folder: repo
        prompt: Read the brief and do the work it describes.
      helper:
        kind: claude-code
        role: worker
        where: sandbox:build-vm
        prompt: Help the worker.
    services:
      web: { external: { url: "http://127.0.0.1:8180/" } }
    chat:
      rooms:
        team: { main: true, members: [owner, manager, worker, helper] }

    """
    let home = "/tmp/doz-sst-home"
    let t0 = Date(timeIntervalSince1970: 1_795_000_000)
    var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: "/tmp/doz-sst-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    static func fixture(_ name: String) throws -> Data { try Data(contentsOf: fixtures.appendingPathComponent("\(name).json")) }

    // MARK: the sha

    func testTheEditorsShaIsReproducedForEveryFixture() throws {
        for n in Self.names {
            let data = try Self.fixture(n)
            let doc = try ChatJSON.parse(data)
            guard case .string(let want)? = SpaceDoc.member(doc, "sha") else { return XCTFail("\(n): no sha") }
            XCTAssertEqual(SpaceState.sha(ofDocument: doc), want, "\(n): the document's own order")
            let s = try JSONDecoder().decode(SpaceState.self, from: data)
            XCTAssertEqual(s.computedSHA, want, "\(n): through Dozable's types, in its key order")
            XCTAssertEqual(SpaceState.stringify(s.ordered()), SpaceState.stringify(doc), "\(n): the same bytes")
        }
    }

    func testStringifyIsJSONStringify() {
        XCTAssertEqual(SpaceState.stringify(.string("a/b <c> & \"d\" \\ é \n\t\u{1}")), "\"a/b <c> & \\\"d\\\" \\\\ é \\n\\t\\u0001\"")
        XCTAssertEqual(SpaceState.stringify(.object([JMember("b", .int(1)), JMember("a", .array([.bool(true), .null, .double(2)]))])),
                       "{\"b\":1,\"a\":[true,null,2]}")
    }

    // MARK: the builder

    func intent() throws -> SpaceIntent {
        let file = root.appendingPathComponent("example-space.space.yaml")
        try Self.exampleSpace.write(to: file, atomically: true, encoding: .utf8)
        var r = SpaceResolver()
        r.home = home
        r.environment = [:]
        let res = r.resolve(file.path)
        let (problems, model) = res.check()
        XCTAssertFalse(problems.contains(where: \.isError), "\(problems.map(\.text))")
        return SpaceIntent.compile(try XCTUnwrap(model), res.filled, res.locator)
    }

    var scratchPath: String { home + "/doz-workspaces/.runs/example-space/2026-11-20-1/scratch" }

    /// The workspace `up` made of example-space, its run open (or closed by down).
    func record(open: Bool) -> (WorkspaceRecord, SpaceRecordRef) {
        var rec = WorkspaceRecord(name: "example-space", createdAt: t0, brief: WorkspaceBrief(sha256: "ab", bytes: 2, updatedAt: t0), folders: [],
                                  rooms: [WorkspaceRoom(label: "main", chatRoom: "example-space", main: true, owned: true)])
        var manager = WorkspaceAgent(name: "manager", role: "manager", place: .macSession("example-space-manager"), startedAt: t0, bot: "manager")
        manager.isolation = "fenced"
        var worker = WorkspaceAgent(name: "worker", place: .macSession("example-space-worker"), startedAt: t0, isolation: "fenced")
        worker.task = "go"
        var helper = WorkspaceAgent(name: "helper", place: AgentPlace(sandbox: "example-space-build-vm", session: "helper"), startedAt: t0, isolation: "vm")
        helper.task = "help"
        if !open { worker.endedAt = t0.addingTimeInterval(60); helper.endedAt = t0.addingTimeInterval(60) }
        rec.agents = [manager, worker, helper]
        var run = WorkspaceRun(id: "2026-11-20-1", startedAt: t0)
        if !open { run.endedAt = t0.addingTimeInterval(120) }
        rec.runs = [run]
        var ref = SpaceRecordRef()
        var owned = SpaceRecordRef.Owned()
        owned.agents = ["worker": "run", "helper": "run"]
        owned.rooms = ["example-space": "persisted"]
        owned.sandboxes = ["example-space-build-vm": "persisted"]
        owned.folders = ["scratch": "run"]
        ref.owned = owned
        ref.upAt = t0
        if !open { ref.downAt = t0.addingTimeInterval(120) }
        ref.scratch = [SpaceRecordRef.Scratch(run: "2026-11-20-1", name: "scratch", path: scratchPath)]
        ref.store(in: &rec)
        return (rec, ref)
    }

    func status(_ s: ProgramStatus.State, kind: ProgramStatus.Kind? = nil, message: String? = nil) -> SessionStatus {
        SessionStatus(session: "x", state: s, kind: kind, message: message, updatedAt: t0)
    }

    /// Everything up made, running: the manager idle, the worker working, the helper idle in its sandbox.
    func runningFacts() -> SpaceStateFacts {
        var f = SpaceStateFacts(known: true, home: home, projectsDir: home + "/doz-workspaces")
        f.agents = ["manager": .init(state: "running", status: status(.idle)), "worker": .init(state: "running", status: status(.working)),
                    "helper": .init(state: "running", status: status(.idle))]
        f.sandboxes = ["example-space-build-vm": "running"]
        f.folders = [home + "/work/example-repo": true, scratchPath: true]
        f.rooms = ["example-space"]
        f.participants = ["ada", "manager", "worker", "helper"]
        return f
    }

    func build(_ i: SpaceIntent, open: Bool = true, _ f: SpaceStateFacts, viewer: SpaceStateViewer = .owner, now: Date? = nil) -> SpaceState {
        let (rec, ref) = record(open: open)
        return SpaceStateBuilder.build(intent: i, ref: ref, record: rec, facts: f, host: "host-a", now: now ?? t0, viewer: viewer)
    }

    struct Fact: Equatable, CustomStringConvertible {
        var type, subject, state, lifetime: String
        var activity: String?
        var drift: String?
        var description: String { "\(type) \(subject) \(state) \(lifetime) \(activity ?? "-") \(drift ?? "-")" }
    }

    /// The facts of a document's items, services left out (Dozable does not check them) and a `differs` drift too (it does
    /// not observe one yet).
    func facts(_ items: [SpaceState.Item]) -> [Fact] {
        items.filter { $0.type != "service" }.map {
            Fact(type: $0.type, subject: $0.subject, state: $0.state, lifetime: $0.lifetime, activity: $0.activity,
                 drift: $0.drift?.kind == "differs" ? nil : $0.drift?.kind)
        }
    }

    func fixtureState(_ n: String) throws -> SpaceState { try JSONDecoder().decode(SpaceState.self, from: try Self.fixture(n)) }

    func testRunningAsleepDownDriftAndUnknownAreTheFixturesFacts() throws {
        let i = try intent()
        // running
        XCTAssertEqual(facts(build(i, runningFacts()).items), facts(try fixtureState("running").items))
        // asleep: the helper's sandbox hibernated
        var f = runningFacts()
        f.agents["helper"] = .init(state: "asleep", detail: "in example-space-build-vm, hibernated")
        f.sandboxes["example-space-build-vm"] = "hibernated"
        XCTAssertEqual(facts(build(i, f).items), facts(try fixtureState("asleep").items))
        // down: the run closed, its agents ended and out of chat, the scratch folder gone, the sandbox shut down
        f = runningFacts()
        f.agents = ["manager": .init(state: "running", status: status(.idle))]
        f.participants = ["ada", "manager"]
        f.sandboxes["example-space-build-vm"] = "off"
        f.folders[scratchPath] = false
        let down = build(i, open: false, f)
        XCTAssertEqual(facts(down.items), facts(try fixtureState("down").items))
        XCTAssertEqual(down.run?.phase, "down")
        XCTAssertNil(down.items.first { $0.state == "gone" }?.drift, "gone is no drift")
        // drift: the repository is not there; a room named like the space the file does not name
        f = runningFacts()
        f.folders[home + "/work/example-repo"] = false
        f.rooms = ["example-space", "example-space-old"]
        let drift = build(i, f)
        XCTAssertEqual(facts(drift.items), facts(try fixtureState("drift").items))
        XCTAssertEqual(facts(drift.extras), facts(try fixtureState("drift").extras.filter { $0.type == "room" }))
        // not known: no daemon
        let unknown = build(i, SpaceStateFacts(known: false, home: home, projectsDir: home + "/doz-workspaces"))
        XCTAssertFalse(unknown.factsKnown)
        XCTAssertEqual(facts(unknown.items), facts(try fixtureState("unknown").items))
        XCTAssertTrue(unknown.items.allSatisfy { $0.state == "unknown" })
        XCTAssertEqual(unknown.items.filter { $0.type == "service" }.map(\.subject), ["web"])
    }

    func testAPermissionPromptIsWaitingWithAttention() throws {
        let i = try intent()
        var f = runningFacts()
        f.agents["worker"] = .init(state: "running", status: status(.blocked, kind: .permission, message: "Allow Bash(ls)?\nsecond line"))
        let s = build(i, f)
        XCTAssertEqual(s.items.first { $0.type == "agent" && $0.subject == "worker" }?.activity, "waiting")
        XCTAssertEqual(s.attention.map(\.kind), ["permission"])
        XCTAssertEqual(s.attention.first?.text, "worker: blocked: needs permission — Allow Bash(ls)?")
        XCTAssertFalse(s.items.contains { ($0.detail ?? "").contains("Allow") }, "the program's message is never a detail")
        // A question, and a sign-in.
        f.agents["worker"] = .init(state: "running", status: status(.blocked, kind: .question))
        XCTAssertEqual(build(i, f).attention.map(\.kind), ["confirm"])
        f.agents["worker"] = .init(state: "running", status: status(.blocked, kind: .auth))
        XCTAssertEqual(build(i, f).attention.map(\.kind), ["problem"])
        // A long message: one line of 120 characters.
        f.agents["worker"] = .init(state: "running", status: status(.blocked, kind: .permission, message: String(repeating: "x", count: 300)))
        let line = try XCTUnwrap(build(i, f).attention.first?.text)
        XCTAssertEqual(line.count, "worker: blocked: needs permission — ".count + SpaceStateBuilder.messageLimit)
    }

    func testAnotherComputerSeesThisMacsAgentsOnlyAsServeMacSessionsAllows() throws {
        let i = try intent()
        var f = runningFacts()
        f.agents["worker"] = .init(state: "running", status: status(.blocked, kind: .permission, message: "Allow it?"))
        let hidden = build(i, f, viewer: SpaceStateViewer(macSessions: false))
        let shown = build(i, f)
        // The same keys either way; the worker (on this Mac) not known, and nothing else said of it.
        XCTAssertEqual(hidden.items.map { "\($0.type) \($0.subject)" }, shown.items.map { "\($0.type) \($0.subject)" })
        let w = try XCTUnwrap(hidden.items.first { $0.type == "agent" && $0.subject == "worker" })
        XCTAssertEqual(w.state, "unknown")
        XCTAssertEqual(w.detail, SpaceStateBuilder.hiddenDetail)
        XCTAssertTrue(hidden.attention.isEmpty)
        XCTAssertFalse(SpaceState.stringify(hidden.ordered()).contains("Allow it"))
        // The helper in its sandbox is no session on this Mac.
        XCTAssertEqual(hidden.items.first { $0.type == "agent" && $0.subject == "helper" }?.state, "running")
    }

    /// A frame's facts drop the programs' own messages: the attention line keeps the status, never the text.
    func testAFramesFactsCarryNoProgramMessage() throws {
        let i = try intent()
        var f = runningFacts()
        f.agents["worker"] = .init(state: "running", status: status(.blocked, kind: .permission, message: "Allow THE-WORDS?"))
        f.dropMessages()
        let s = build(i, f)
        XCTAssertEqual(s.attention.map(\.text), ["worker: blocked: needs permission"])
        XCTAssertFalse(SpaceState.stringify(s.ordered()).contains("THE-WORDS"))
    }

    func testTheSameFactsTheSameSha() throws {
        let i = try intent()
        let a = build(i, runningFacts(), now: t0)
        let b = build(i, runningFacts(), now: t0.addingTimeInterval(3600))
        XCTAssertNotEqual(a.observedAt, b.observedAt)
        XCTAssertEqual(a.sha, b.sha)
        XCTAssertEqual(a.sha, a.computedSHA)
        var f = runningFacts()
        f.agents["worker"] = .init(state: "running", status: status(.idle))
        XCTAssertNotEqual(build(i, f).sha, a.sha, "a fact changed: a new sha")
    }

    func testAnUpThatStoppedIsARefusalAndExtrasComeFromTheRecord() throws {
        let i = try intent()
        var f = runningFacts()
        f.upStopped = true
        f.agents["stray"] = .init(state: "running", status: status(.working))
        var (rec, _) = record(open: true)
        var stray = WorkspaceAgent(name: "stray", place: .macSession("stray"), startedAt: t0)
        stray.task = "t"
        rec.agents.append(stray)
        let s = SpaceStateBuilder.build(intent: i, ref: SpaceRecordRef.of(rec), record: rec, facts: f, host: "host-a", now: t0, viewer: .owner)
        XCTAssertEqual(s.attention.map(\.kind), ["refusal"])
        XCTAssertEqual(s.extras.map { "\($0.type) \($0.subject) \($0.drift?.kind ?? "")" }, ["agent stray extra"])
    }

    /// Every document the builder makes in these tests passes the editor's schema.
    func testEveryBuiltDocumentPassesTheSchema() throws {
        let i = try intent()
        let schema = try SpaceStateSchemaTests.schema()
        var f = runningFacts()
        f.agents["worker"] = .init(state: "running", status: status(.blocked, kind: .permission, message: "m"))
        f.upStopped = true
        f.rooms = ["example-space", "example-space-x"]
        for s in [build(i, runningFacts()), build(i, f), build(i, open: false, f), build(i, f, viewer: SpaceStateViewer(macSessions: false)),
                  build(i, SpaceStateFacts(known: false, home: home, projectsDir: home))] {
            let v = try JSONSerialization.jsonObject(with: Data(SpaceState.stringify(s.ordered()).utf8))
            XCTAssertEqual(SpaceStateSchemaTests.validate(v, schema), [])
        }
    }
}
