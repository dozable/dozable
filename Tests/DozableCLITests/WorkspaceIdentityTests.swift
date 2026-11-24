import Foundation
import XCTest
@testable import DozableHost

/// Identities and sessions in the record, pure: a 0.52.54 record (`agents[]`) read as identities and sessions and written in
/// the new form (`identities[]`, `sessions[]`, never `agents[]`), round-tripped unchanged; each identity's id stable (derived
/// when never recorded, a freed name's next identity another); who owns an identity by its naming; which identities a
/// record still has; its sessions.
final class WorkspaceIdentityTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("doz-idt-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    /// A record exactly as 0.52.54 wrote it: a manager (a bot), a named worker, a worker Dozable named (`bot1`), a bot's
    /// worker, an adopted agent, an ended worker — and a field this build does not know on one agent.
    static let record05254 = #"""
    {"agents":[{"bot":"mira","isolation":"fenced","name":"mira","place":{"mac":true,"session":"app"},"role":"manager","startedAt":"2026-11-20T10:00:00.000Z","startedBy":"you"},
    {"anonymous":true,"isolation":"fenced","name":"helper","place":{"mac":true,"session":"app-helper"},"role":"worker","startedAt":"2026-11-20T10:01:00.000Z","startedBy":"you","task":"Work on the project","later_agent":"kept"},
    {"anonymous":true,"isolation":"fenced","name":"bot1","place":{"mac":true,"session":"app-bot1"},"role":"worker","startedAt":"2026-11-20T10:02:00.000Z","startedBy":"you","stoppedAt":"2026-11-20T11:00:00.000Z","task":"list the files"},
    {"bot":"otto","isolation":"vm","name":"otto","place":{"sandbox":"app-otto"},"role":"worker","startedAt":"2026-11-20T10:03:00.000Z","startedBy":"you","task":"render"},
    {"name":"shell","place":{"mac":true,"session":"shell"},"role":"worker","startedAt":"2026-11-20T10:04:00.000Z","startedBy":"you"},
    {"anonymous":true,"endedAt":"2026-11-20T10:30:00.000Z","isolation":"fenced","name":"bot2","place":{"mac":true,"session":"app-bot2"},"role":"worker","startedAt":"2026-11-20T10:05:00.000Z","startedBy":"you","task":"tidy"}],
    "brief":{"bytes":15,"refs":[],"sha256":"x","updatedAt":"2026-11-20T09:59:00.000Z"},"createdAt":"2026-11-20T09:59:00.000Z",
    "defaults":{},"driver":"you","flags":{"startedAt":"2026-11-20T10:00:00.000Z"},"folders":[{"main":true,"mode":"rw","path":"/work/app"}],
    "name":"app","origin":{"kind":"new"},"rooms":[{"chatRoom":"app","label":"main","main":true}],"version":1}
    """#

    func testARecordFrom05254IsReadAsIdentitiesAndSessionsAndWrittenInTheNewForm() throws {
        let old = try HostWire.decoder.decode(WorkspaceRecord.self, from: Data(Self.record05254.utf8))
        XCTAssertEqual(old.agents.map(\.name), ["mira", "helper", "bot1", "otto", "shell", "bot2"])
        XCTAssertEqual(old.agents[1].unknown.extra["later_agent"], .string("kept"))
        // Who owns each, derived (a record before identities says none): only what Dozable named itself is the run's.
        XCTAssertEqual(old.agents.map(\.effectiveLifetime), ["workspace", "workspace", "run", "workspace", "workspace", "run"])
        XCTAssertTrue(old.agents.allSatisfy { $0.identityID == nil && $0.lifetime == nil })
        // Written: identities and sessions, never agents; the ids derived, each session naming its identity's.
        let data = try HostWire.encoder.encode(old)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(obj["agents"])
        let ids = try XCTUnwrap(obj["identities"] as? [[String: Any]])
        let sessions = try XCTUnwrap(obj["sessions"] as? [[String: Any]])
        XCTAssertEqual(ids.map { $0["name"] as? String }, ["mira", "helper", "bot1", "otto", "shell", "bot2"])
        XCTAssertEqual(sessions.map { $0["identity"] as? String }, ids.map { $0["id"] as? String })
        XCTAssertEqual(ids[1]["later_agent"] as? String, "kept", "a field this build does not know stays on the identity")
        XCTAssertNil(ids[0]["place"], "the place is the session's")
        XCTAssertNil(ids[0]["startedAt"])
        XCTAssertEqual((sessions[2]["stoppedAt"] as? String), "2026-11-20T11:00:00.000Z")
        XCTAssertEqual(sessions[5]["endedAt"] as? String, "2026-11-20T10:30:00.000Z")
        XCTAssertNil(sessions[0]["role"], "the role is the identity's")
        for i in ids { XCTAssertTrue((i["id"] as? String ?? "").hasPrefix("idn-")) }
        XCTAssertEqual(Set(ids.compactMap { $0["id"] as? String }).count, 6, "one id each")
        // Read back: the same agents, field for field (the derived ids are not recorded twice).
        let again = try HostWire.decoder.decode(WorkspaceRecord.self, from: data)
        XCTAssertEqual(again, old)
        XCTAssertEqual(try HostWire.encoder.encode(again), data, "written back byte for byte")
        // Through the store too (its own file, as a daemon writes it).
        let ws = WorkspaceStore(store: DozableStore(root: root))
        try ws.write(old)
        XCTAssertEqual(try ws.read("app"), old)
        let onDisk = try String(contentsOfFile: ws.folder("app") + "/workspace.json", encoding: .utf8)
        XCTAssertTrue(onDisk.contains("\"identities\"") && onDisk.contains("\"sessions\"") && !onDisk.contains("\"agents\""))
    }

    func testANewFieldOnASessionIsKeptOnTheSession() throws {
        var rec = try HostWire.decoder.decode(WorkspaceRecord.self, from: Data(Self.record05254.utf8))
        rec.agents[0].sessionUnknown = UnknownFields(["later_session": .string("kept")])
        rec.agents[0].tokenIssuedAt = Date(timeIntervalSince1970: 1_800_000_000)
        rec.agents[0].lifetime = "workspace"
        rec.agents[0].kind = "claude-code"
        let data = try HostWire.encoder.encode(rec)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual((obj["sessions"] as? [[String: Any]])?.first?["later_session"] as? String, "kept")
        XCTAssertNil((obj["identities"] as? [[String: Any]])?.first?["later_session"])
        XCTAssertEqual((obj["identities"] as? [[String: Any]])?.first?["kind"] as? String, "claude-code")
        XCTAssertEqual(try HostWire.decoder.decode(WorkspaceRecord.self, from: data), rec)
    }

    /// An older doz that kept `identities` as a field it did not know and added an agent of its own to `agents`: both read.
    func testAnAgentAnOlderDozAddedBesideTheNewFormIsRead() throws {
        let rec = try HostWire.decoder.decode(WorkspaceRecord.self, from: Data(Self.record05254.utf8))
        var obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: try HostWire.encoder.encode(rec)) as? [String: Any])
        obj["agents"] = [["name": "late", "place": ["mac": true, "session": "late"], "role": "worker", "startedAt": "2026-11-21T10:00:00.000Z"]]
        let mixed = try HostWire.decoder.decode(WorkspaceRecord.self, from: try JSONSerialization.data(withJSONObject: obj))
        XCTAssertEqual(mixed.agents.map(\.name), ["mira", "helper", "bot1", "otto", "shell", "bot2", "late"])
    }

    func testTheIDIsStableAndAFreedNameGetsANewOne() throws {
        let t = Date(timeIntervalSince1970: 1_800_000_000.25)
        let a = WorkspaceAgent(name: "bot1", place: .macSession("x"), startedAt: t)
        XCTAssertEqual(a.id, WorkspaceAgent.derivedID(name: "bot1", startedAt: t))
        XCTAssertEqual(a.id, WorkspaceAgent.derivedID(name: "bot1", startedAt: Date(timeIntervalSince1970: 1_800_000_000.9)), "whole seconds")
        let next = WorkspaceAgent(name: "bot1", place: .macSession("x"), startedAt: t.addingTimeInterval(60))
        XCTAssertNotEqual(next.id, a.id, "a freed name's next identity is another")
        var kept = next
        kept.identityID = a.id
        XCTAssertEqual(kept.id, a.id, "a lasting identity added again keeps its id")
        XCTAssertFalse(a.id.contains(where: { $0.isUppercase }))
        XCTAssertEqual(a.id.count, 16)
    }

    func testWhoOwnsAnIdentity() {
        func w(_ name: String, bot: String? = nil, anonymous: Bool? = true, task: String? = "t", lifetime: String? = nil) -> WorkspaceAgent {
            var a = WorkspaceAgent(name: name, place: .macSession(name), startedAt: Date(), bot: bot)
            a.task = task; a.anonymous = anonymous; a.lifetime = lifetime
            return a
        }
        XCTAssertEqual(w("bot3").effectiveLifetime, "run", "named by Dozable")
        XCTAssertEqual(w("helper").effectiveLifetime, "workspace", "a name given")
        XCTAssertEqual(w("bot3", lifetime: "workspace").effectiveLifetime, "workspace", "as recorded")
        XCTAssertEqual(w("helper", lifetime: "run").effectiveLifetime, "run", "as recorded")
        XCTAssertEqual(w("otto", bot: "otto", anonymous: nil).effectiveLifetime, "workspace", "a bot")
        XCTAssertEqual(w("shell", anonymous: nil, task: nil).effectiveLifetime, "workspace", "an adopted agent")
        XCTAssertEqual(w("bot3", lifetime: "standing").effectiveLifetime, "run", "an unknown word is derived")
        XCTAssertTrue(WorkspaceAgent.isAutoName("bot12"))
        XCTAssertFalse(WorkspaceAgent.isAutoName("bot"))
        XCTAssertFalse(WorkspaceAgent.isAutoName("botany"))
    }

    func testWhichIdentitiesARecordHas() throws {
        var rec = try HostWire.decoder.decode(WorkspaceRecord.self, from: Data(Self.record05254.utf8))
        // bot2 (the run's, ended) is no identity any more; helper ended stays one; a retired one is not.
        rec.agents[1].endedAt = Date()
        var retired = WorkspaceAgent(name: "gone", place: .macSession("app-gone"), startedAt: Date(), isolation: "fenced")
        retired.task = "x"; retired.anonymous = true; retired.lifetime = "workspace"; retired.endedAt = Date(); retired.retiredAt = Date()
        rec.agents.append(retired)
        XCTAssertEqual(WorkspaceIdentities.current(rec).map(\.name), ["mira", "helper", "bot1", "otto", "shell"])
        // A lasting identity ended and added again: its live entry is the one.
        var back = rec.agents[1]
        back.endedAt = nil
        back.startedAt = Date().addingTimeInterval(5)
        back.identityID = rec.agents[1].id
        rec.agents.append(back)
        let cur = WorkspaceIdentities.current(rec)
        XCTAssertEqual(cur.filter { $0.name == "helper" }.count, 1)
        XCTAssertNil(cur.first { $0.name == "helper" }?.endedAt)
        // Sessions: every one not ended, with what the record knows of it.
        let s = WorkspaceIdentities.sessions(rec, conditions: nil)
        XCTAssertEqual(s.map(\.identity), ["mira", "bot1", "otto", "shell", "helper"])
        XCTAssertEqual(s.first { $0.identity == "bot1" }?.state, "stopped")
        XCTAssertEqual(s.first { $0.identity == "bot1" }?.since, "2026-11-20T11:00:00Z")
        XCTAssertEqual(s.first { $0.identity == "otto" }?.place, "app-otto")
        XCTAssertEqual(s.first { $0.identity == "mira" }?.place, "@mac/app")
    }
}
