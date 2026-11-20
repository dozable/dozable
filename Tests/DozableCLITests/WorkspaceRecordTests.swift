import Darwin
import Foundation
import XCTest
@testable import DozableHost

/// The workspace record and its store: the round trip, fields this build does not know kept (top level and nested), a
/// higher version kept, names, modes, links refused, create-by-rename never replacing, the log's torn tail, `--since`.
/// Scratch roots only.
final class WorkspaceRecordTests: XCTestCase {
    private var root: URL!
    private var ws: WorkspaceStore!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: "/tmp/doz-ws-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        ws = WorkspaceStore(store: DozableStore(root: root))
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func record(_ name: String = "demo") -> WorkspaceRecord {
        let at = Date(timeIntervalSince1970: 1_800_000_000.25)
        return WorkspaceRecord(name: name, createdAt: at, brief: WorkspaceBrief(refs: ["https://example.com/spec"], sha256: "ab", bytes: 2, updatedAt: at),
                               folders: [WorkspaceFolder(path: "/tmp/a", mode: "rw", main: true), WorkspaceFolder(path: "/tmp/b", mode: "ro")],
                               rooms: [WorkspaceRoom(label: "main", chatRoom: name, main: true)],
                               agents: [WorkspaceAgent(name: "wsa", place: .sandbox("wsa"), startedAt: at),
                                        WorkspaceAgent(name: "wsu", place: .macSession("wsu"), startedAt: at)],
                               defaults: WorkspaceDefaults(network: "standard"), flags: WorkspaceFlags(firstAgentAt: at),
                               origin: WorkspaceOrigin(kind: "project", project: "/tmp/a/doz_project.yaml"))
    }

    private func make(_ r: WorkspaceRecord, brief: String = "hi") throws {
        try ws.create(r, brief: Data(brief.utf8), log: [WorkspaceLogEntry(action: "created")])
    }

    func testRoundTrip() throws {
        let r = record()
        try make(r)
        XCTAssertEqual(try ws.read("demo"), r)
        XCTAssertEqual(ws.readBrief("demo"), "hi")
        XCTAssertEqual(ws.names(), ["demo"])
        XCTAssertEqual(ws.membership(), ["sandbox:wsa": "demo", "mac:wsu": "demo"])
        XCTAssertEqual(r.agents[1].place.display, "@mac/wsu")
        XCTAssertEqual(r.agentIndex("@mac/wsu"), 1)
        XCTAssertNil(try ws.read("other"))
    }

    /// Folders are optional: a workspace with none keeps `folders: []` and has no main folder.
    func testAWorkspaceWithNoFolders() throws {
        var r = record("bare")
        r.folders = []
        try make(r)
        let back = try XCTUnwrap(try ws.read("bare"))
        XCTAssertEqual(back.folders, [])
        XCTAssertNil(back.mainFolder)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: ws.folder("bare") + "/workspace.json"))) as? [String: Any])
        XCTAssertEqual((obj["folders"] as? [Any])?.count, 0, "written as an empty list")
    }

    /// Fields a newer doz wrote survive this build's rewrite — top level and in folders, rooms and agents — and a higher
    /// version is kept, never lowered.
    func testUnknownFieldsAndAHigherVersionSurviveARewrite() throws {
        try make(record())
        let path = ws.folder("demo") + "/workspace.json"
        var obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any])
        obj["version"] = 7
        obj["future"] = ["deep": [1, 2]]
        for k in ["folders", "rooms", "agents"] {
            var a = try XCTUnwrap(obj[k] as? [[String: Any]])
            a[0]["later_\(k)"] = "kept"
            obj[k] = a
        }
        var flags = (obj["flags"] as? [String: Any]) ?? [:]
        flags["later_flags"] = "kept"
        obj["flags"] = flags
        try JSONSerialization.data(withJSONObject: obj).write(to: URL(fileURLWithPath: path))
        var r = try XCTUnwrap(try ws.read("demo"))
        XCTAssertEqual(r.version, 7)
        r.brief.refs.append("/tmp/x")
        try ws.write(r)
        let again = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any])
        XCTAssertEqual(again["version"] as? Int, 7)
        XCTAssertEqual((again["future"] as? [String: Any])?["deep"] as? [Int], [1, 2])
        for k in ["folders", "rooms", "agents"] {
            XCTAssertEqual((again[k] as? [[String: Any]])?.first?["later_\(k)"] as? String, "kept", k)
        }
        XCTAssertEqual(((again["brief"] as? [String: Any])?["refs"] as? [String])?.last, "/tmp/x")
        XCTAssertEqual((again["flags"] as? [String: Any])?["later_flags"] as? String, "kept", "a flag this build does not know is kept")
    }

    /// The permissions section (additive): a record written before it reads unchanged and is written back with no such key;
    /// with it, a newer section's fields survive a rewrite, and "an older doz" — one that does not know the key — keeps it whole
    /// as a field it does not know.
    func testThePermissionsSection() throws {
        try make(record())
        let path = ws.folder("demo") + "/workspace.json"
        let before = try Data(contentsOf: URL(fileURLWithPath: path))
        var r = try XCTUnwrap(try ws.read("demo"))
        XCTAssertNil(r.permissions, "a record from before: no section")
        try ws.write(r)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), before, "written back byte for byte")
        r.permissions = WorkspaceGrants(grants: [Grant(id: "g1", subject: .agent("demo", "wsa"), perm: "net.allow", answer: .ask, scope: .workspace("demo"),
                                                       at: Date(timeIntervalSince1970: 1_900_000_000))], ceiling: ["sudo": "never"])
        try ws.write(r)
        var obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any])
        var p = try XCTUnwrap(obj["permissions"] as? [String: Any])
        XCTAssertEqual(p["version"] as? Int, 1)
        p["version"] = 2
        p["later"] = "kept"
        obj["permissions"] = p
        try JSONSerialization.data(withJSONObject: obj).write(to: URL(fileURLWithPath: path))
        var back = try XCTUnwrap(try ws.read("demo"))
        XCTAssertEqual(back.permissions?.version, 2)
        XCTAssertEqual(back.permissions?.grants.first?.perm, "net.allow")
        back.brief.refs.append("/tmp/y")
        try ws.write(back)
        let again = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any])
        XCTAssertEqual((again["permissions"] as? [String: Any])?["later"] as? String, "kept")
        XCTAssertEqual((again["permissions"] as? [String: Any])?["version"] as? Int, 2)
        // An older doz: the key is not one it knows, so it is carried as it was.
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let c = try JSONDecoder().decode(OlderRecord.self, from: data)
        XCTAssertNotNil(c.unknown.extra["permissions"], "an older doz keeps the section as a field it does not know")
    }

    func testNames() {
        for ok in ["a", "demo", "launch-video", "x1", String(repeating: "a", count: 40)] { XCTAssertTrue(WorkspaceName.isValid(ok), ok) }
        for bad in ["", "-a", "A", "a_b", "a.b", "a/b", "..", ".new-x", "a b", "é", String(repeating: "a", count: 41)] {
            XCTAssertFalse(WorkspaceName.isValid(bad), bad)
            XCTAssertThrowsError(try WorkspaceName.validate(bad), bad)
        }
        XCTAssertThrowsError(try ws.read("../x"))
        XCTAssertTrue(WorkspaceName.isValidAgent("wsu_1.b"))
        XCTAssertFalse(WorkspaceName.isValidAgent("-x"))
        XCTAssertFalse(WorkspaceName.isValidAgent("a/b"))
    }

    /// 0700 folders, 0600 files.
    func testModes() throws {
        try make(record())
        func mode(_ p: String) -> mode_t { var st = stat(); lstat(p, &st); return st.st_mode & 0o777 }
        XCTAssertEqual(mode(ws.root), 0o700)
        XCTAssertEqual(mode(ws.folder("demo")), 0o700)
        for f in ["workspace.json", "brief.md", "log.jsonl"] { XCTAssertEqual(mode(ws.folder("demo") + "/" + f), 0o600, f) }
        try ws.append("demo", WorkspaceLogEntry(action: "released", agent: "wsa"))
        XCTAssertEqual(mode(ws.folder("demo") + "/log.jsonl"), 0o600)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: ws.root).contains { $0.hasPrefix(".new-") }, "no assembly folder left")
    }

    /// A link where `workspaces/` or a workspace's file is: refused, never followed.
    func testLinksAreRefused() throws {
        let elsewhere = root.appendingPathComponent("elsewhere").path
        try FileManager.default.createDirectory(atPath: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: ws.root, withDestinationPath: elsewhere)
        XCTAssertThrowsError(try make(record()))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: elsewhere), [])
        try FileManager.default.removeItem(atPath: ws.root)
        try make(record())
        let log = ws.folder("demo") + "/log.jsonl"
        try FileManager.default.removeItem(atPath: log)
        try FileManager.default.createSymbolicLink(atPath: log, withDestinationPath: elsewhere + "/stolen")
        XCTAssertThrowsError(try ws.append("demo", WorkspaceLogEntry(action: "released")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: elsewhere + "/stolen"))
        let rec = ws.folder("demo") + "/workspace.json"
        try FileManager.default.removeItem(atPath: rec)
        try FileManager.default.createSymbolicLink(atPath: rec, withDestinationPath: elsewhere + "/r.json")
        XCTAssertThrowsError(try ws.read("demo"))
    }

    /// Making one that exists is refused and leaves it as it was.
    func testCreateNeverReplaces() throws {
        try make(record(), brief: "first")
        XCTAssertThrowsError(try make(record(), brief: "second")) { e in XCTAssertEqual((e as? HostError)?.code, .exists) }
        XCTAssertEqual(ws.readBrief("demo"), "first")
        XCTAssertEqual(try ws.log("demo").count, 1)
    }

    func testRename() throws {
        try make(record())
        try ws.rename("demo", to: "demo2")
        XCTAssertEqual(ws.names(), ["demo2"])
        XCTAssertEqual(try ws.read("demo2")?.name, "demo2")
        try make(record("demo"))
        XCTAssertThrowsError(try ws.rename("demo", to: "demo2")) { e in XCTAssertEqual((e as? HostError)?.code, .exists) }
    }

    /// A torn last line (a write cut short) is skipped; the lines before it are read.
    func testTheLogsTornTail() throws {
        try make(record())
        try ws.append("demo", WorkspaceLogEntry(action: "adopted", agent: "wsa", place: "sandbox:wsa"))
        let h = try XCTUnwrap(FileHandle(forWritingAtPath: ws.folder("demo") + "/log.jsonl"))
        h.seekToEndOfFile()
        h.write(Data("{\"v\":1,\"at\":\"2026-".utf8))
        try h.close()
        let entries = try ws.log("demo")
        XCTAssertEqual(entries.map(\.action), ["created", "adopted"])
        XCTAssertEqual(entries[1].sentence, "adopted wsa (sandbox:wsa)")
        try ws.append("demo", WorkspaceLogEntry(action: "released", agent: "wsa"))
        XCTAssertEqual(try ws.log("demo").map(\.action), ["created", "adopted", "released"], "a line after a torn one starts on its own line")
    }

    func testSince() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        XCTAssertEqual(WorkspaceStore.since("30m", now: now), now.addingTimeInterval(-1800))
        XCTAssertEqual(WorkspaceStore.since("2h", now: now), now.addingTimeInterval(-7200))
        XCTAssertEqual(WorkspaceStore.since("3d", now: now), now.addingTimeInterval(-3 * 86_400))
        XCTAssertEqual(WorkspaceStore.since("2033-05-18T03:33:20Z", now: now), now)
        XCTAssertNotNil(WorkspaceStore.since("2033-05-18T03:33:20.5Z", now: now))
        XCTAssertNil(WorkspaceStore.since("soon", now: now))
        XCTAssertNil(WorkspaceStore.since("-2h", now: now))
        try make(record())
        let old = WorkspaceLogEntry(at: now.addingTimeInterval(-10_000), action: "adopted", agent: "a")
        let new = WorkspaceLogEntry(at: now, action: "released", agent: "a")
        try ws.append("demo", old)
        try ws.append("demo", new)
        XCTAssertEqual(try ws.log("demo", since: now.addingTimeInterval(-60)).map(\.action), ["released"])
    }
}

/// A record as a doz from before the permissions section reads it: every key it does not know kept (`UnknownFields`).
private struct OlderRecord: Decodable {
    var unknown: UnknownFields
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicKey.self)
        unknown = try UnknownFields(c, known: WorkspaceRecord.known.subtracting(["permissions"]))
    }
}
