import DozableChat
import DozableKit
import Foundation
import XCTest
@testable import DozableHost

/// 751 (WS.03): state for every workspace. A workspace made with no space file has a `SpaceState` derived from its record
/// (`RecordStateBuilder`) that passes the editor's schema in every situation; each agent's condition
/// (`WorkspaceConditionsBuilder`) from what the daemon holds and the last log line about it — running, asleep, stopped,
/// crashed, not started, and not known with no daemon; `ready`; and the `--json` contract around the document (`kind`,
/// `schema`, `agents.<name>.condition`) leaving the document and its sha exactly as they were.
final class WorkspaceRecordStateTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_795_000_000)

    func status(_ s: ProgramStatus.State, kind: ProgramStatus.Kind? = nil) -> SessionStatus {
        SessionStatus(session: "x", state: s, kind: kind, updatedAt: t0)
    }

    /// `doz workspace new app --manager mira --folder /tmp/repo` with a worker `tess` on this Mac, an adopted sandbox `lab`
    /// and the main room `app`, started.
    func record() -> WorkspaceRecord {
        var rec = WorkspaceRecord(name: "app", createdAt: t0, brief: WorkspaceBrief(sha256: "ab", bytes: 2, updatedAt: t0),
                                  folders: [WorkspaceFolder(path: "/tmp/doz-wrs-repo", main: true)],
                                  rooms: [WorkspaceRoom(label: "main", chatRoom: "app", main: true, owned: true)])
        let mira = WorkspaceAgent(name: "mira", role: "manager", place: .macSession("app"), startedAt: t0, bot: "mira", isolation: "fenced")
        var tess = WorkspaceAgent(name: "tess", place: .macSession("app-tess"), startedAt: t0, isolation: "fenced")
        tess.task = "count the files"
        let lab = WorkspaceAgent(name: "lab", place: .sandbox("lab"), startedAt: t0)
        rec.agents = [mira, tess, lab]
        rec.flags.startedAt = t0
        rec.runs = [WorkspaceRun(id: "2026-11-22-1", startedAt: t0)]
        return rec
    }

    func runningFacts() -> SpaceStateFacts {
        var f = SpaceStateFacts(known: true, home: "/tmp/doz-wrs-home", projectsDir: "/tmp/doz-wrs-home/doz")
        f.agents = ["mira": .init(state: "running", status: status(.idle)), "tess": .init(state: "running", status: status(.working)),
                    "lab": .init(state: "running", status: status(.idle))]
        f.sandboxes = ["lab": "running"]
        f.folders = ["/tmp/doz-wrs-repo": true]
        f.rooms = ["app"]
        f.participants = ["ada", "mira", "tess"]
        return f
    }

    func log(_ entries: (String, String, Int?)...) -> [WorkspaceLogEntry] {
        entries.enumerated().map { i, e in
            var l = WorkspaceLogEntry(at: t0.addingTimeInterval(Double(i + 1)), by: "doz", action: e.1, agent: e.0)
            l.exitCode = e.2
            return l
        }
    }

    func conditions(_ rec: WorkspaceRecord, _ f: SpaceStateFacts, _ l: [WorkspaceLogEntry] = []) -> [String: String] {
        WorkspaceConditionsBuilder.build(record: rec, facts: f, log: l, from: "record").agents.mapValues(\.condition)
    }

    func build(_ rec: WorkspaceRecord, _ f: SpaceStateFacts, _ l: [WorkspaceLogEntry] = [], viewer: SpaceStateViewer = .owner) -> SpaceState {
        let c = WorkspaceConditionsBuilder.build(record: rec, facts: f, log: l, from: "record")
        var s = RecordStateBuilder.build(record: rec, facts: f, conditions: c, host: "host-a", now: t0, viewer: viewer)
        s.agentConditions = c
        return s
    }

    // MARK: conditions

    func testEachAgentsCondition() {
        let rec = record()
        // running
        XCTAssertEqual(conditions(rec, runningFacts()), ["mira": "running", "tess": "running", "lab": "running"])
        // asleep: put to sleep (a session on this Mac ends — the log says it slept), or its sandbox hibernated
        var f = runningFacts()
        f.agents["mira"] = .init(state: "ended"); f.agents["tess"] = .init(state: "ended")
        f.agents["lab"] = .init(state: "asleep", detail: "in lab, hibernated")
        XCTAssertEqual(conditions(rec, f, log(("mira", "agent-slept", nil), ("tess", "agent-slept", nil))),
                       ["mira": "asleep", "tess": "asleep", "lab": "asleep"])
        // crashed: the log says so (its exit code the reason); a failed sandbox
        f = runningFacts()
        f.agents["tess"] = .init(state: "ended")
        f.agents["lab"] = .init(state: "ended", detail: "in lab, failed", failed: true)
        let c = WorkspaceConditionsBuilder.build(record: rec, facts: f, log: log(("tess", "agent-woke", nil), ("tess", "agent-crashed", 70)), from: "record")
        XCTAssertEqual(c.agents["tess"]?.condition, "crashed")
        XCTAssertEqual(c.agents["tess"]?.reason, "its program exited with 70")
        XCTAssertEqual(c.agents["tess"]?.since, SpaceState.time(t0.addingTimeInterval(2)))
        XCTAssertEqual(c.agents["lab"]?.condition, "crashed")
        XCTAssertFalse(c.ready)
        // a crash then a wake: running again
        f = runningFacts()
        XCTAssertEqual(conditions(rec, f, log(("tess", "agent-crashed", 70), ("tess", "agent-woke", nil)))["tess"], "running")
        // not started: a manager recorded, never started
        f = runningFacts()
        f.agents["mira"] = .init(state: "ended", detail: "not started")
        XCTAssertEqual(conditions(rec, f)["mira"], "not-started")
        // stopped: a manager stopped; a session that is gone; a finished workspace
        f.agents["mira"] = .init(state: "ended")
        f.agents["tess"] = .init(state: "missing")
        XCTAssertEqual(conditions(rec, f, log(("mira", "manager-stopped", nil))), ["mira": "stopped", "tess": "stopped", "lab": "running"])
        var finished = rec
        finished.flags.finishedAt = t0
        f.agents["tess"] = .init(state: "ended")
        let fin = WorkspaceConditionsBuilder.build(record: finished, facts: f, log: log(("tess", "agent-slept", nil)), from: "record")
        XCTAssertEqual(fin.agents["tess"]?.condition, "stopped", "finished is stopped, not asleep")
        XCTAssertEqual(fin.agents["tess"]?.reason, "the workspace is finished")
        XCTAssertFalse(fin.ready)
        // being added
        var adding = rec
        adding.agents[1].pendingAt = t0
        XCTAssertEqual(conditions(adding, runningFacts())["tess"], "not-started")
        // with no daemon: not known, never a guess
        let none = SpaceStateFacts(known: false, home: "/tmp", projectsDir: "/tmp")
        XCTAssertEqual(Set(conditions(rec, none).values), ["unknown"])
        // an ended worker is no agent of the workspace
        var ended = rec
        ended.agents[1].endedAt = t0
        XCTAssertNil(conditions(ended, runningFacts())["tess"])
        // every condition is one of the contract's
        XCTAssertTrue(Set(conditions(rec, f).values).isSubset(of: Set(AgentCondition.all)))
    }

    func testReadyOnlyWhenEveryAgentRuns() {
        let rec = record()
        XCTAssertTrue(WorkspaceConditionsBuilder.build(record: rec, facts: runningFacts(), log: [], from: "record").ready)
        var f = runningFacts()
        f.agents["lab"] = .init(state: "asleep")
        XCTAssertFalse(WorkspaceConditionsBuilder.build(record: rec, facts: f, log: [], from: "record").ready)
        var empty = rec
        empty.agents = []
        XCTAssertFalse(WorkspaceConditionsBuilder.build(record: empty, facts: runningFacts(), log: [], from: "record").ready, "no agent: not ready")
    }

    // MARK: the document

    func testTheRecordsDocumentHasOneItemPerThing() {
        let s = build(record(), runningFacts())
        XCTAssertEqual(s.space, "app")
        XCTAssertTrue(s.factsKnown)
        XCTAssertEqual(s.run?.phase, "up")
        XCTAssertEqual(s.items.map { "\($0.type) \($0.subject) \($0.state)" }, [
            "agent mira running", "member mira present", "agent tess running", "member tess present", "agent lab running",
            "sandbox lab running", "folder /tmp/doz-wrs-repo present", "room app open",
        ])
        XCTAssertEqual(s.items.first { $0.subject == "tess" }?.activity, "working")
        XCTAssertEqual(s.extras, [], "nothing is outside a record: it is the declaration")
        XCTAssertEqual(s.sha, s.computedSHA)
        XCTAssertEqual(build(record(), runningFacts()).sha, s.sha, "the same facts, the same sha")
    }

    func testAttentionForABlockedAgentACrashAndAMissingFolder() {
        var f = runningFacts()
        f.agents["mira"] = .init(state: "running", status: status(.blocked, kind: .permission))
        f.agents["tess"] = .init(state: "ended")
        f.folders = [:]
        let s = build(record(), f, log(("tess", "agent-crashed", 3)))
        XCTAssertEqual(s.attention.map(\.kind).sorted(), ["health", "permission"])
        XCTAssertEqual(s.items.first { $0.type == "agent" && $0.subject == "tess" }?.state, "ended")
        XCTAssertEqual(s.items.first { $0.type == "folder" }?.drift?.kind, "missing")
        XCTAssertEqual(s.items.first { $0.type == "agent" && $0.subject == "mira" }?.activity, "waiting")
    }

    func testWithNoDaemonEveryItemIsUnknown() {
        let s = build(record(), SpaceStateFacts(known: false, home: "/tmp", projectsDir: "/tmp"))
        XCTAssertFalse(s.factsKnown)
        XCTAssertTrue(s.items.allSatisfy { $0.state == "unknown" })
        XCTAssertEqual(s.items.count, 8, "stable keys: the same items as with a daemon")
    }

    /// The editor's schema, whatever the situation: running, asleep, crashed, finished, not known, hidden from another computer.
    func testEveryRecordDocumentPassesTheSchema() throws {
        let schema = try SpaceStateSchemaTests.schema()
        let rec = record()
        var asleep = runningFacts()
        asleep.agents = ["mira": .init(state: "ended"), "tess": .init(state: "ended"), "lab": .init(state: "asleep", detail: "in lab, hibernated")]
        asleep.sandboxes = ["lab": "hibernated"]
        asleep.participants = ["ada"]
        var crashed = runningFacts()
        crashed.agents["lab"] = .init(state: "ended", detail: "in lab, failed", failed: true)
        crashed.sandboxes = ["lab": "failed"]
        crashed.rooms = nil
        crashed.participants = nil
        var gone = rec
        gone.flags.finishedAt = t0
        gone.runs[0].endedAt = t0
        var docs = [build(rec, runningFacts()), build(rec, asleep, log(("mira", "agent-slept", nil))), build(rec, crashed),
                    build(gone, asleep), build(rec, SpaceStateFacts(known: false, home: "/tmp", projectsDir: "/tmp")),
                    RecordStateBuilder.build(record: rec, facts: runningFacts(), conditions: WorkspaceConditionsBuilder.build(record: rec, facts: runningFacts(), log: [], from: "record"),
                                             host: "h", now: t0, viewer: .owner, note: "its space was recorded by an older doz")]
        docs.append(docs[0].hiding(RecordStateBuilder.macSubjects(rec)))
        for (i, s) in docs.enumerated() {
            let v = try JSONSerialization.jsonObject(with: Data(SpaceState.stringify(s.ordered()).utf8))
            XCTAssertEqual(SpaceStateSchemaTests.validate(v, schema), [], "document \(i)")
            XCTAssertEqual(s.sha, s.computedSHA, "document \(i)")
        }
    }

    func testAnotherComputerSeesThisMacsAgentsAsUnknown() {
        let rec = record()
        let s = build(rec, runningFacts()).hiding(RecordStateBuilder.macSubjects(rec))
        for i in s.items where i.subject == "mira" || i.subject == "tess" {
            XCTAssertEqual(i.state, "unknown")
            XCTAssertEqual(i.detail, SpaceStateBuilder.hiddenDetail)
        }
        XCTAssertEqual(s.items.first { $0.type == "agent" && $0.subject == "lab" }?.state, "running", "a sandbox is not a session on this Mac")
        let c = WorkspaceConditionsBuilder.build(record: rec, facts: runningFacts(), log: [], from: "record", hidden: true)
        XCTAssertEqual(c.agents.mapValues(\.condition), ["mira": "unknown", "tess": "unknown", "lab": "running"])
    }

    // MARK: the phase (756)

    func testThePhaseFromTheFlagsThenTheAgentsThenTheLog() {
        typealias B = WorkspaceConditionsBuilder
        let c = { (x: String) in AgentCondition(condition: x, role: "worker", place: "p") }
        var rec = record()
        XCTAssertEqual(B.phase(rec, agents: ["a": c("running"), "b": c("asleep")], known: true, log: []), "running")
        XCTAssertEqual(B.phase(rec, agents: ["a": c("asleep"), "b": c("stopped")], known: true, log: []), "asleep")
        XCTAssertEqual(B.phase(rec, agents: ["a": c("stopped"), "b": c("crashed")], known: true, log: []), "stopped")
        // No daemon: the log's last workspace-wide change.
        XCTAssertEqual(B.phase(rec, agents: ["a": c("unknown")], known: false, log: [WorkspaceLogEntry(action: "woke"), WorkspaceLogEntry(action: "stopped")]), "stopped")
        XCTAssertEqual(B.phase(rec, agents: ["a": c("unknown")], known: false, log: [WorkspaceLogEntry(action: "slept")]), "asleep")
        rec.flags.finishedAt = Date()
        XCTAssertEqual(B.phase(rec, agents: [:], known: true, log: []), "finished")
        rec.flags.archivedAt = Date()
        XCTAssertEqual(B.phase(rec, agents: [:], known: true, log: []), "archived")
        rec.flags = WorkspaceFlags()
        XCTAssertEqual(B.phase(rec, agents: [:], known: true, log: []), "setting-up")
        XCTAssertEqual(WorkspaceConditions.phases, ["setting-up", "running", "asleep", "stopped", "finished", "archived"])
    }

    // MARK: the --json contract

    func testTheJSONCarriesKindSchemaAndEachAgentsConditionAroundTheSameDocument() throws {
        let s = build(record(), runningFacts())
        let answer = SpaceState.stringify(s.stateAnswer())
        let o = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(answer.utf8)) as? [String: Any])
        XCTAssertEqual(o["kind"] as? String, "WorkspaceState")
        XCTAssertEqual(o["schema"] as? Int, 1)
        XCTAssertEqual(o["from"] as? String, "record")
        XCTAssertEqual(o["revision"] as? String, "")
        let agents = try XCTUnwrap(o["agents"] as? [String: [String: Any]])
        XCTAssertEqual(agents["mira"]?["condition"] as? String, "running")
        XCTAssertEqual(agents["mira"]?["role"] as? String, "manager")
        XCTAssertEqual(agents["tess"]?["place"] as? String, "@mac/app-tess")
        XCTAssertEqual(agents["lab"]?["role"] as? String, "adopted")
        XCTAssertEqual((o["conditions"] as? [String: Any])?["ready"] as? Bool, true)
        XCTAssertEqual(o["phase"] as? String, "running", "756: the workspace's phase, top level")
        XCTAssertTrue(answer.hasPrefix(#"{"kind":"WorkspaceState","schema":1,"version":1,"space":"app""#), "kind and schema first, then the document")
        // The document inside is exactly ordered()'s, its sha unchanged: drop what the contract adds and it is the same bytes.
        var doc = o
        for k in ["kind", "schema", "from", "phase", "agents", "conditions", "revision"] { doc[k] = nil }
        XCTAssertEqual(SpaceStateSchemaTests.validate(doc, try SpaceStateSchemaTests.schema()), [])
        XCTAssertEqual(doc["sha"] as? String, s.computedSHA)
        // …and a reader that decodes it as the document still can (`make test-cli-workspace` F1 does): additive.
        let back = try JSONDecoder().decode(SpaceState.self, from: Data(answer.utf8))
        XCTAssertEqual(back.sha, s.sha)
        XCTAssertEqual(back.items, s.items)
        // A document carried without conditions (the dashboard's) gains only kind, schema and revision.
        var plain = s
        plain.agentConditions = nil
        let p = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(SpaceState.stringify(plain.stateAnswer()).utf8)) as? [String: Any])
        XCTAssertNil(p["agents"])
        XCTAssertEqual(p["kind"] as? String, "WorkspaceState")
    }

    /// The dashboard's document is the editor's: conditions are never encoded unless carried, and `ordered()` never writes them.
    func testTheEditorsDocumentNeverCarriesConditions() throws {
        var s = build(record(), runningFacts())
        XCTAssertFalse(SpaceState.stringify(s.ordered()).contains("\"conditions\""))
        s.agentConditions = nil
        let enc = String(decoding: try JSONEncoder().encode(s), as: UTF8.self)
        XCTAssertFalse(enc.contains("agentConditions"))
    }

    // MARK: one condition per layer (764)

    func layers(_ rec: WorkspaceRecord, _ f: SpaceStateFacts, _ l: [WorkspaceLogEntry] = []) throws -> LayerConditions {
        try XCTUnwrap(WorkspaceConditionsBuilder.build(record: rec, facts: f, log: l, from: "record").layers)
    }

    func testAllocatedFromTheRecordsLifecycle() throws {
        // A record workspace: allocated from new, through finish (finish ends the run, not the allocation), until archive.
        var rec = record()
        XCTAssertEqual(try layers(rec, runningFacts()).allocated, .init(value: true, since: SpaceState.time(t0)))
        rec.flags.finishedAt = t0.addingTimeInterval(60)
        rec.runs[0].endedAt = t0.addingTimeInterval(60)
        XCTAssertEqual(try layers(rec, runningFacts()).allocated.value, true)
        rec.flags.archivedAt = t0.addingTimeInterval(120)
        XCTAssertEqual(try layers(rec, runningFacts()).allocated, .init(value: false, since: SpaceState.time(t0.addingTimeInterval(120)), reason: "archived"))

        // A space file's, lifetime runs: down releases it; an up after it allocates again, since that up.
        var space = record()
        var ref = SpaceRecordRef()
        ref.upAt = t0.addingTimeInterval(10)
        ref.store(in: &space)
        XCTAssertEqual(try layers(space, runningFacts()).allocated.value, true)
        ref.downAt = t0.addingTimeInterval(20)
        ref.store(in: &space)
        XCTAssertEqual(try layers(space, runningFacts()).allocated, .init(value: false, since: SpaceState.time(t0.addingTimeInterval(20)), reason: "down"))
        ref.upAt = t0.addingTimeInterval(30)
        ref.store(in: &space)
        XCTAssertEqual(try layers(space, runningFacts()).allocated, .init(value: true, since: SpaceState.time(t0.addingTimeInterval(30))))

        // Standing: down keeps it — but a purge releases it.
        ref.lifetime = "standing"; ref.upAt = t0.addingTimeInterval(10); ref.downAt = t0.addingTimeInterval(20)
        ref.store(in: &space)
        XCTAssertEqual(try layers(space, runningFacts()).allocated, .init(value: true, since: SpaceState.time(t0)))
        ref.purgedAt = t0.addingTimeInterval(20)
        ref.store(in: &space)
        XCTAssertEqual(try layers(space, runningFacts()).allocated.reason, "down")
    }

    func testHotPerSessionRunAndArchived() throws {
        let rec = record()
        var l = try layers(rec, runningFacts())
        XCTAssertEqual(l.hot.value, "all")
        XCTAssertEqual(l.hot.sessions?.mapValues(\.condition), ["mira": "running", "tess": "running", "lab": "running"])
        XCTAssertEqual(l.run, .init(open: true, id: "2026-11-22-1", since: SpaceState.time(t0)))
        XCTAssertEqual(l.archived, .init(value: false))

        // Some: one asleep, one crashed (ended).
        var f = runningFacts()
        f.agents["lab"] = .init(state: "asleep", detail: "in lab, hibernated")
        f.agents["tess"] = .init(state: "ended")
        l = try layers(rec, f, log(("tess", "agent-crashed", 70)))
        XCTAssertEqual(l.hot.value, "some")
        XCTAssertEqual(l.hot.sessions?.mapValues(\.condition), ["mira": "running", "tess": "ended", "lab": "asleep"])

        // None: stopped, every session's since a parseable time.
        f.agents = ["mira": .init(state: "ended"), "tess": .init(state: "ended"), "lab": .init(state: "ended", detail: "in lab, shut down")]
        l = try layers(rec, f, log(("mira", "agent-stopped", nil), ("tess", "agent-stopped", nil), ("lab", "agent-stopped", nil)))
        XCTAssertEqual(l.hot.value, "none")
        XCTAssertEqual(Set(l.hot.sessions!.values.map(\.condition)), ["stopped"])
        for s in l.hot.sessions!.values { XCTAssertNotNil(ISO8601DateFormatter().date(from: s.since), s.since) }

        // No daemon: not known; a worker being added is starting.
        XCTAssertEqual(Set(try layers(rec, SpaceStateFacts(known: false, home: "", projectsDir: "")).hot.sessions!.values.map(\.condition)), ["unknown"])
        var adding = record()
        adding.agents[1].pendingAt = t0
        XCTAssertEqual(try layers(adding, runningFacts()).hot.sessions?["tess"]?.condition, "starting")

        // The run closed, then archived.
        var done = record()
        done.runs[0].endedAt = t0.addingTimeInterval(60)
        done.flags.finishedAt = t0.addingTimeInterval(60)
        done.flags.archivedAt = t0.addingTimeInterval(90)
        l = try layers(done, runningFacts())
        XCTAssertEqual(l.run, .init(open: false, id: "2026-11-22-1", since: SpaceState.time(t0.addingTimeInterval(60))))
        XCTAssertEqual(l.archived, .init(value: true, at: SpaceState.time(t0.addingTimeInterval(90))))
        // No run yet.
        var fresh = record()
        fresh.runs = []
        XCTAssertEqual(try layers(fresh, runningFacts()).run, .init(open: false))
    }

    /// The layers sit BESIDE `ready` in `conditions`, never replacing it; an ls row carries the short form.
    func testTheJSONCarriesEachLayerBesideReady() throws {
        let s = build(record(), runningFacts())
        let o = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(SpaceState.stringify(s.stateAnswer()).utf8)) as? [String: Any])
        let c = try XCTUnwrap(o["conditions"] as? [String: Any])
        XCTAssertEqual(Array(c.keys).sorted(), ["allocated", "archived", "hot", "ready", "run"])
        XCTAssertEqual(c["ready"] as? Bool, true)
        XCTAssertEqual((c["allocated"] as? [String: Any])?["value"] as? Bool, true)
        XCTAssertNil((c["allocated"] as? [String: Any])?["reason"])
        XCTAssertEqual((c["hot"] as? [String: Any])?["value"] as? String, "all")
        XCTAssertEqual(((c["hot"] as? [String: Any])?["sessions"] as? [String: [String: Any]])?["mira"]?["condition"] as? String, "running")
        XCTAssertEqual((c["run"] as? [String: Any])?["open"] as? Bool, true)
        XCTAssertEqual((c["archived"] as? [String: Any])?["value"] as? Bool, false)
        XCTAssertNil((c["archived"] as? [String: Any])?["at"])
        XCTAssertEqual(o["phase"] as? String, "running", "phase stays")

        let short = try XCTUnwrap(s.agentConditions?.layers?.short)
        let row = try XCTUnwrap(try JSONSerialization.jsonObject(with: JSONEncoder().encode(short)) as? [String: Any])
        XCTAssertEqual(Array(row.keys).sorted(), ["allocated", "hot", "run"])
        XCTAssertNil((row["hot"] as? [String: Any])?["sessions"], "the short form has no sessions")
    }
}
