import Foundation
import XCTest
@testable import DozableHost

/// A persisted fenced agent's memory: captured from its private agent folder (memory files only — no transcript, no
/// settings, no link), seeded back only into the SAME agent's next fenced session of the same workspace, only where its
/// space keeps it; a non-persisted agent starts with none (the private folder is cleared at every open); a seed never
/// writes outside `projects/<folder>/memory/`.
final class SpaceMemoryTests: XCTestCase {
    var root: String!

    override func setUpWithError() throws {
        root = WorkspaceStore.resolved("/tmp") + "/doz-mem-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(atPath: root) }

    func write(_ path: String, _ text: String) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    func testCaptureTakesOnlyMemoryAndSeedBringsItBack() throws {
        let agent = root + "/session/agent"
        try write(agent + "/projects/-work/memory/notes.md", "remember this\n")
        try write(agent + "/projects/-work/abc.jsonl", "{}\n")
        try write(agent + "/settings.json", "{}")
        try FileManager.default.createSymbolicLink(atPath: agent + "/projects/-work/memory/link.md", withDestinationPath: "/etc/hosts")
        let dest = root + "/store/workspaces/sp/memory/w1"
        XCTAssertEqual(try SpaceMemory.capture(agentDir: agent, into: dest), 1, "the memory file only; never a link, a transcript or settings")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest + "/memory.json"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest + "/projects/-work/abc.jsonl"))
        let mode = try FileManager.default.attributesOfItem(atPath: dest)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o700)
        // The next private folder: cleared, then seeded.
        let next = root + "/session2/agent"
        try FileManager.default.createDirectory(atPath: next, withIntermediateDirectories: true)
        XCTAssertEqual(try SpaceMemory.seed(from: dest, into: next), 1)
        XCTAssertEqual(try String(contentsOfFile: next + "/projects/-work/memory/notes.md", encoding: .utf8), "remember this\n")
        // Captured again: replaced whole.
        try FileManager.default.removeItem(atPath: agent + "/projects/-work/memory/notes.md")
        XCTAssertEqual(try SpaceMemory.capture(agentDir: agent, into: dest), 0)
    }

    func testASeedNeverWritesOutsideTheMemoryFolder() throws {
        let kept = root + "/kept"
        try write(kept + "/x", "evil")
        let bad = SpaceMemory.Manifest(isolation: "fenced", files: [
            .init(path: "settings.json", sha256: WorkspaceStore.sha256(Data("evil".utf8))),
            .init(path: "projects/a/../../x", sha256: WorkspaceStore.sha256(Data("evil".utf8))),
        ])
        try HostWire.prettyEncoder.encode(bad).write(to: URL(fileURLWithPath: kept + "/memory.json"))
        let agent = root + "/agent"
        try FileManager.default.createDirectory(atPath: agent, withIntermediateDirectories: true)
        XCTAssertEqual(try SpaceMemory.seed(from: kept, into: agent), 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: agent), [])
        // An unfenced capture is never seeded into a fenced session.
        try HostWire.prettyEncoder.encode(SpaceMemory.Manifest(isolation: "unfenced", files: [])).write(to: URL(fileURLWithPath: kept + "/memory.json"))
        XCTAssertEqual(try SpaceMemory.seed(from: kept, into: agent), 0)
    }

    /// Only the same agent's fenced session, of a live worker whose space keeps its memory; never another's.
    func testTheKeptMemoryReachesOnlyTheSameAgentsNextFencedSession() throws {
        let store = DozableStore(root: URL(fileURLWithPath: root + "/store"))
        let ws = WorkspaceStore(store: store)
        let now = Date()
        func worker(_ name: String, session: String, isolation: String = "fenced") -> WorkspaceAgent {
            var a = WorkspaceAgent(name: name, role: "worker", place: .macSession(session), startedAt: now, isolation: isolation)
            a.task = "t"
            return a
        }
        var rec = WorkspaceRecord(name: "sp", createdAt: now, brief: WorkspaceBrief(sha256: "", bytes: 0, updatedAt: now), folders: [],
                                  agents: [worker("w1", session: "sp-w1"), worker("w2", session: "sp-w2"), worker("w3", session: "sp-w3", isolation: "unfenced")])
        var ref = SpaceRecordRef()
        ref.owned = SpaceRecordRef.Owned()
        ref.owned?.agents = ["w1": "persisted", "w2": "run", "w3": "persisted"]
        ref.memoryIsolation = ["w1": "fenced", "w3": "unfenced"]
        ref.store(in: &rec)
        try ws.create(rec, brief: Data(), log: [])
        for a in ["w1", "w2", "w3"] { try write(WorkspaceStore.resolved(ws.folder("sp")) + "/memory/\(a)/memory.json", "{}") }
        XCTAssertNotNil(SpaceMemory.seedFolder(store: store.root.path, session: "sp-w1"))
        XCTAssertNil(SpaceMemory.seedFolder(store: store.root.path, session: "sp-w2"), "a non-persisted agent starts with none")
        XCTAssertNil(SpaceMemory.seedFolder(store: store.root.path, session: "sp-w3"), "an unfenced agent's never reaches a fenced session")
        XCTAssertNil(SpaceMemory.seedFolder(store: store.root.path, session: "other"), "never another session")
        // Ended: none.
        rec.agents[0].endedAt = now
        try ws.write(rec)
        XCTAssertNil(SpaceMemory.seedFolder(store: store.root.path, session: "sp-w1"))
    }

    /// A private agent folder is cleared at every open: a non-persisted agent's memory never survives into its next session.
    func testANonPersistedAgentStartsWithNoMemory() throws {
        let agent = root + "/agent"
        try write(agent + "/projects/-work/memory/notes.md", "old\n")
        try write(agent + "/projects/-work/a.jsonl", "{}\n")
        _ = try MacAgentConfig.clearKeepingTranscripts(agent, projects: "projects/-work")
        XCTAssertFalse(FileManager.default.fileExists(atPath: agent + "/projects/-work/memory"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: agent + "/projects/-work/a.jsonl"))
    }
}
