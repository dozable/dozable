import Foundation
import SQLite3
import XCTest
import DozableChat
import DozableKit
@testable import DozableHost

/// A scratch store with one of every record the timeline reads — metrics rows (a daemon run, an action, a step, a
/// session, a network minute, a daemon event, connections with a key's use, samples), a workspace with its log and a
/// run with a frame, the grants log, a chat room with a message, its states and an Ask — each carrying a sentinel that
/// must never reach the derived store's text: a host, a folder, message text, an Ask's question, a key's value.
struct TimelineFixture {
    static let host = "sentinel-host.example.org"
    static let folder = "/Users/sentinel-account/secret-folder"
    static let text = "SENTINEL MESSAGE TEXT never stored"
    static let question = "SENTINEL QUESTION never stored"
    static let keyValue = "sk-sentinel-key-value-0123456789"
    static let owner = "ada"

    let root: URL
    let store: DozableStore
    /// The base time: a few days ago, so every default retention keeps it.
    let t0: Date

    init(tag: String = "fx", t0: Date = Date().addingTimeInterval(-3 * 86_400)) throws {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("doz-747-\(tag)-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        root = URL(fileURLWithPath: HostCore.resolvedRoot(u.path))
        store = DozableStore(root: root)
        self.t0 = t0
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }

    /// Every record, written.
    @discardableResult
    func fill() throws -> MetricsStore {
        let m = try MetricsStore(url: store.metrics)
        let run = m.beginRun(.init(kind: "doz host", appVersion: "0.52.28", build: "0.52.28", machine: "Mac99,1 " + Self.host, chip: "c", macOS: "27"),
                             at: at(0))
        let a = m.begin(run: run, action: "start", sandbox: "build-vm", image: "pi", phaseBefore: "off", startedAt: at(10))
        m.record(run: run, action: "step: vm boot", kind: .step, sandbox: "build-vm", image: "pi", startedAt: at(11), durationMs: 800, parent: a)
        m.finish(a, phaseAfter: "running", durationMs: 1200, ok: true)
        let bad = m.begin(run: run, action: "wake", sandbox: "build-vm", image: "pi", phaseBefore: "asleep", startedAt: at(20))
        m.finish(bad, phaseAfter: "failed", durationMs: 50, ok: false, error: "could not open \(Self.folder) on \(Self.host)")
        let s = m.sessionOpened(run: run, sandbox: "build-vm", image: "pi", session: "claude", command: "/usr/bin/claude --key \(Self.keyValue) -p \(Self.text)",
                                openedAt: at(30), openMs: 40)
        m.sessionEnded(s, at: at(90), exitCode: 0)
        m.addNetwork(run: run, sandbox: "build-vm", minute: Int64(at(60).timeIntervalSince1970 / 60), allowed: 3, denied: 1, failed: 0, bytesUp: 10, bytesDown: 20)
        m.hostEvent(run: run, at: at(40), kind: "note", sandbox: "build-vm", summary: HostEventSummary.make(
            HostEvent(kind: .note, sandbox: "build-vm", text: "reached \(Self.host) from \(Self.folder)"))!, ms: nil, failed: false)
        var c = ConnectionRecord(kind: .connect, host: Self.host, port: 443, method: "POST", path: "/v1/\(Self.text)", verdict: .allowed,
                                 rule: "allow \(Self.host)", bytesUp: 100, bytesDown: 200, durationMs: 300, time: at(61))
        c.credential = "swapped anthropic"; c.credentialUse = .swapped("anthropic")
        let d = ConnectionRecord(kind: .tcp, host: Self.host, port: 22, verdict: .denied, rule: "deny", time: at(62))
        _ = m.recordConnections(run: run, sandbox: "build-vm", [c, d])
        m.sample(run: run, sandbox: "build-vm", minute: Int64(at(60).timeIntervalSince1970 / 60), cpuPercent: 12.5, memoryBytes: 1 << 30, diskBytes: 1 << 31)

        let ws = WorkspaceStore(store: store)
        let rec = WorkspaceRecord(name: "example-space", createdAt: at(1), brief: WorkspaceBrief(refs: [], sha256: "ab", bytes: 2, updatedAt: at(1)),
                                  folders: [WorkspaceFolder(path: Self.folder, mode: "rw", main: true)],
                                  rooms: [WorkspaceRoom(label: "main", chatRoom: "team", main: true)],
                                  agents: [WorkspaceAgent(name: "manager", place: .sandbox("build-vm"), startedAt: at(1))],
                                  defaults: WorkspaceDefaults(network: "standard"), flags: WorkspaceFlags(firstAgentAt: at(1)),
                                  origin: WorkspaceOrigin(kind: "project", project: Self.folder + "/doz_project.yaml"))
        var withRun = rec
        var r = WorkspaceRun(id: "2026-11-20-1", startedAt: at(2))
        r.endedAt = at(500); r.closedBy = "finish"
        withRun.runs = [r]
        try ws.create(withRun, brief: Data("brief".utf8), log: [WorkspaceLogEntry(at: at(1), action: "created")])
        try ws.append("example-space", WorkspaceLogEntry(at: at(2), action: "run-opened", run: "2026-11-20-1"))
        try ws.append("example-space", WorkspaceLogEntry(at: at(3), action: "worker-added", agent: "bot1", reason: "because \(Self.host)", isolation: "fenced"))
        try ws.append("example-space", WorkspaceLogEntry(at: at(4), action: "granted", reason: "a permission line"))
        let frames = WorkspaceStore.resolved(ws.folder("example-space")) + "/runs/2026-11-20-1/frames"
        try FileManager.default.createDirectory(atPath: frames, withIntermediateDirectories: true)
        try Data(#"{"at":"\#(ISO8601DateFormatter().string(from: at(5)))","label":"up","state":{}}"#.utf8).write(to: URL(fileURLWithPath: frames + "/000001.json"))

        let g = GrantStore(store: store)
        try g.append(GrantLogEntry(at: at(6), by: "you", action: "granted", subject: "agent:example-space/bot1", perm: "folder.write", scope: "workspace:example-space", id: "g7"))
        try g.append(GrantLogEntry(at: at(7), by: "bot1", action: "permission-decided", subject: "agent:example-space/bot1", perm: "net.open", answer: "never",
                                   reason: "asked for \(Self.host)"))

        // The chat server's room, as it writes it.
        let paths = ChatPaths(store: store)
        try FileManager.default.createDirectory(atPath: paths.data + "/rooms", withIntermediateDirectories: true)
        var idx = ChatRoomIndex()
        _ = idx.ensure("team", owner: "example-space", now: at(1))
        try HostWire.encoder.encode(idx).write(to: URL(fileURLWithPath: ChatRoomIndex.path(paths)))
        var dir = ChatDirectory()
        dir.human = Self.owner
        try JSONEncoder().encode(dir).write(to: URL(fileURLWithPath: paths.directory))
        var db: OpaquePointer?
        sqlite3_open(paths.data + "/rooms/team.db", &db)
        defer { sqlite3_close(db) }
        sqlite3_exec(db, ChatRoomStore.schema, nil, nil, nil)
        for a in ChatRoomStore.alters { sqlite3_exec(db, a, nil, nil, nil) }
        func exec(_ sql: String) { XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, sql) }
        let tm = at(100).timeIntervalSince1970
        exec("INSERT INTO messages (msg_id, sender, recipients, content, at) VALUES ('msg_1', '\(Self.owner)', '[\"bot1\"]', '\(Self.text)', \(tm))")
        exec("INSERT INTO states (msg_id, recipient, state, at) VALUES ('msg_1', 'bot1', 'delivered', \(tm + 1))")
        exec("INSERT INTO messages (msg_id, sender, recipients, content, at) VALUES ('msg_2', 'bot1', '[\"\(Self.owner)\"]', '\(Self.question)', \(tm + 2))")
        exec("""
            INSERT INTO asks (msg_id, ask, state, closed_at, decision) VALUES ('msg_2', '{"number":12,"question":"\(Self.question)","options":["Ship","Wait"]}',
              'decided', \(tm + 30), '{"by":"\(Self.owner)","option":0,"text":"\(Self.text)"}')
            """)
        return m
    }

    /// Every byte of the derived store (and its WAL) — for the sentinel sweep.
    func derivedBytes() -> String {
        var out = Data()
        for s in ["", "-wal"] { out.append((try? Data(contentsOf: URL(fileURLWithPath: TimelineStore.url(store).path + s))) ?? Data()) }
        return String(decoding: out, as: UTF8.self)
    }
}
