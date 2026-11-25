import DozableChat
import Foundation
import XCTest
@testable import DozableHost
@testable import DozableWeb

/// Every workspace drawn (web.md, "The workspace drawn"): one made without a space file — the wizard, `doz workspace new`,
/// adopted agents, with or without a manager, its workers in VMs, fenced or unfenced — is drawn from its document (the one
/// `doz workspace doc` writes, `RecordDocument.generate`), said in the renderer's words (`SpacePicture.recordDocument`), with
/// what its state calls each thing (`subjects`) so the live marks land on its boxes, and nothing of this Mac's sessions for a
/// browser that may not see them (`WebWorkspaceDoc`). The route and its exposure: `WebHTTPIntegrationTests`,
/// `ServeHTTPTests`, `ServeExposureTests`; the drawing in a real browser: `make dashboard-walk` ("pictures", a plain one).
final class WebDocPictureTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func record(_ name: String, folders: [WorkspaceFolder] = [], rooms: [WorkspaceRoom]? = nil, agents: [WorkspaceAgent] = [],
                isolation: String? = nil) -> WorkspaceRecord {
        var r = WorkspaceRecord(name: name, createdAt: t0, brief: WorkspaceBrief(sha256: "x", bytes: 1, updatedAt: t0), folders: folders,
                                rooms: rooms ?? [WorkspaceRoom(label: "main", chatRoom: name, main: true, owned: true)], agents: agents)
        r.defaults.isolation = isolation
        return r
    }
    func worker(_ n: String, _ place: AgentPlace, _ iso: String) -> WorkspaceAgent {
        var a = WorkspaceAgent(name: n, place: place, startedAt: t0, isolation: iso)
        a.task = "do " + n
        a.anonymous = true
        return a
    }
    func generate(_ r: WorkspaceRecord) -> RecordDocument.Generated {
        RecordDocument.generate(.init(record: r, briefText: "Mind the build.", owner: "ada", host: "this-mac"))
    }
    /// The picture's text read back (YAML reads JSON's flow form) — the document the renderer is given.
    func drawn(_ text: String) throws -> JValue {
        let body = text.split(separator: "\n").dropFirst().map { line -> String in
            let i = try! XCTUnwrap(line.range(of: ": "))
            return String(line[..<i.lowerBound]) + ":" + String(line[i.upperBound...])
        }
        return try ChatJSON.parse(Data(("{" + body.joined(separator: ",") + "}").utf8))
    }

    /// Every kind: a manager, fenced and unfenced workers on this Mac beside a VM default, a VM worker, an adopted session and
    /// sandbox, a linked room. The agents on this Mac say `where: mac`; a linked room is a room of its key; the subjects name
    /// each thing as the record's state does.
    func testEveryKindIsDrawnFromItsDocument() throws {
        let r = record("plain", folders: [WorkspaceFolder(path: "/tmp/work/App", main: true)],
                       rooms: [WorkspaceRoom(label: "main", chatRoom: "plain", main: true, owned: true), WorkspaceRoom(label: "ops", chatRoom: "ops-room", main: false, owned: false)],
                       agents: [
                        WorkspaceAgent(name: "mira", role: "manager", place: .macSession("plain"), startedAt: t0, bot: "mira", isolation: "fenced"),
                        worker("w1", .macSession("plain-w1"), "fenced"),
                        worker("w2", .macSession("plain-w2"), "unfenced"),
                        worker("vm1", AgentPlace(sandbox: "plain-vm1", session: "vm1"), "vm"),
                        WorkspaceAgent(name: "wsu", place: .macSession("wsu"), startedAt: t0),
                        WorkspaceAgent(name: "box", place: .sandbox("box"), startedAt: t0),
                       ], isolation: "vm")
        let g = generate(r)
        let d = try drawn(SpacePicture.recordDocument(g.document))
        XCTAssertTrue(SpacePicture.recordDocument(g.document).hasPrefix("doz: space/3.1\n"))
        for a in ["w1", "w2"] { XCTAssertEqual(SpaceDoc.string(SpaceDoc.at(d, "/agents/\(a)/where")), "mac", a) }
        XCTAssertEqual(SpaceDoc.string(SpaceDoc.at(d, "/agents/w2/isolation")), "unfenced")
        XCTAssertEqual(SpaceDoc.string(SpaceDoc.at(d, "/agents/vm1/where")), "sandbox:plain-vm1")
        XCTAssertEqual(SpaceDoc.string(SpaceDoc.at(d, "/agents/wsu/external/session")), "wsu")
        XCTAssertNil(SpaceDoc.at(d, "/chat/rooms/ops/external"), "a linked room is drawn as a room")
        XCTAssertNotNil(SpaceDoc.at(d, "/chat/rooms/ops"))
        XCTAssertEqual(SpaceDoc.bool(SpaceDoc.at(d, "/chat/rooms/plain/main")), true)
        // The document itself is untouched (what `doz workspace doc` prints).
        XCTAssertNotNil(SpaceDoc.at(g.document, "/chat/rooms/ops/external"))
        XCTAssertNil(SpaceDoc.at(g.document, "/agents/w1/where"))
        // Subjects: as the record's state names them → the document's keys.
        XCTAssertEqual(g.subjects["folder:/tmp/work/App"], "app")
        XCTAssertEqual(g.subjects["sandbox:plain-vm1"], "plain-vm1")
        XCTAssertEqual(g.subjects["room:ops-room"], "ops")
        XCTAssertEqual(g.subjects["room:plain"], "plain")
        XCTAssertEqual(g.subjects["agent:mira"], "mira")
        XCTAssertEqual(g.subjects["member:w1"], "w1")
        XCTAssertEqual(Set(g.macAgents), ["mira", "w1", "w2", "wsu"], "the agents on this Mac")
    }

    /// No file, nothing but the record: a wizard's workspace with no agent yet is still drawn (its brief and room).
    func testAWorkspaceWithNoFileAndNoAgentIsStillDrawn() throws {
        let g = generate(record("wiz1", folders: [WorkspaceFolder(path: "/tmp/a", main: true)]))
        let t = SpacePicture.recordDocument(g.document)
        XCTAssertTrue(t.hasPrefix("doz: space/3.1\n"), t)
        let d = try drawn(t)
        XCTAssertEqual(SpaceDoc.string(SpaceDoc.member(d, "space")), "wiz1")
        XCTAssertNotNil(SpaceDoc.at(d, "/chat/rooms/wiz1"))
        XCTAssertNotNil(SpaceDoc.at(d, "/folders/a"))
    }

    /// A browser that may not see this Mac's sessions: the agents there are left out of the drawing and of the subjects, no
    /// session's name anywhere; the sha changes with what is drawn.
    func testThisMacsAgentsAreLeftOutForABrowserThatMayNotSeeThem() throws {
        let r = record("plain", agents: [worker("w1", .macSession("plain-w1"), "fenced"), WorkspaceAgent(name: "wsu", place: .macSession("private-session"), startedAt: t0),
                                         worker("vm1", AgentPlace(sandbox: "plain-vm1", session: "vm1"), "vm")])
        let g = generate(r)
        let a = WorkspaceDocumentAnswer(workspace: "plain", from: "record", document: SpaceDoc.text(RecordDocument.view(g.document)), notes: g.notes,
                                        subjects: g.subjects, macAgents: g.macAgents)
        let all = try WebWorkspaceDoc(a, macAllowed: true)
        let hidden = try WebWorkspaceDoc(a, macAllowed: false)
        XCTAssertTrue(all.picture.contains("private-session"))
        XCTAssertFalse(hidden.picture.contains("private-session"), hidden.picture)
        XCTAssertNil(SpaceDoc.at(try drawn(hidden.picture), "/agents/w1"))
        XCTAssertNotNil(SpaceDoc.at(try drawn(hidden.picture), "/agents/vm1"))
        XCTAssertNil(hidden.subjects["agent:wsu"])
        XCTAssertNil(hidden.subjects["member:w1"])
        XCTAssertEqual(hidden.subjects["sandbox:plain-vm1"], "plain-vm1")
        XCTAssertNotEqual(all.sha256, hidden.sha256)
        XCTAssertEqual(try WebWorkspaceDoc(a, macAllowed: true).sha256, all.sha256, "the same drawing, the same sha")
        // The document holds no token: what is drawn is the document's own text.
        XCTAssertFalse(all.picture.contains("token"))
        // An older daemon (no subjects, no agents named as this Mac's): drawn, nothing left out it cannot tell.
        var old = a
        old.subjects = nil
        old.macAgents = nil
        XCTAssertEqual(try WebWorkspaceDoc(old, macAllowed: false).subjects, [:])
    }

    /// The picture changes when the record does: a worker added, then ended.
    func testThePictureFollowsTheRecord() throws {
        var r = record("plain")
        let before = SpacePicture.recordDocument(generate(r).document)
        r.agents.append(worker("w1", .macSession("plain-w1"), "fenced"))
        let added = SpacePicture.recordDocument(generate(r).document)
        XCTAssertNotEqual(before, added)
        XCTAssertTrue(added.contains("\"w1\""))
        r.agents[0].endedAt = t0
        XCTAssertEqual(SpacePicture.recordDocument(generate(r).document), before, "an ended worker is no longer drawn")
    }

    /// The vendored renderer itself reads every kind without its problem marker (node, when this Mac has it; the walk always
    /// draws it in Chrome).
    func testTheVendoredRendererDrawsEveryKindWithoutAProblem() throws {
        guard let node = ["/opt/homebrew/bin/node", "/usr/local/bin/node"].first(where: { FileManager.default.isExecutableFile(atPath: $0) })
                ?? ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map({ $0 + "/node" }).first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else { throw XCTSkip("no node on this Mac: the dashboard walk draws it") }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let renderer = root.appendingPathComponent("Sources/DozableWeb/WebSource/vendor/space-editor/space-render.js").path
        let r = record("plain", folders: [WorkspaceFolder(path: "/tmp/work/app", main: true)],
                       rooms: [WorkspaceRoom(label: "main", chatRoom: "plain", main: true, owned: true), WorkspaceRoom(label: "ops", chatRoom: "ops-room", main: false, owned: false)],
                       agents: [
                        WorkspaceAgent(name: "mira", role: "manager", place: .macSession("plain"), startedAt: t0, bot: "mira", isolation: "fenced"),
                        worker("w1", .macSession("plain-w1"), "fenced"), worker("w2", .macSession("plain-w2"), "unfenced"),
                        worker("vm1", AgentPlace(sandbox: "plain-vm1", session: "vm1"), "vm"),
                        WorkspaceAgent(name: "wsu", place: .macSession("wsu"), startedAt: t0), WorkspaceAgent(name: "box", place: .sandbox("box"), startedAt: t0),
                       ], isolation: "vm")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("doz-docpicture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var texts = [SpacePicture.recordDocument(generate(r).document), SpacePicture.recordDocument(generate(record("wiz1")).document)]
        texts.append(SpacePicture.recordDocument(generate(r).document, hiding: Set(generate(r).macAgents)))
        let script = """
        import { readFileSync } from 'node:fs';
        const m = await import(process.argv[2]);
        for (const f of process.argv.slice(3)) {
          const svg = m.render(readFileSync(f, 'utf8'), undefined, { detail: 'hero', width: 1200, height: 500, theme: 'light', idPrefix: 't-' });
          console.log(/<svg[^>]*class="[^"]*problem/.test(svg) ? 'PROBLEM ' + svg.replace(/<style[\\s\\S]*?<\\/style>/g, '').replace(/<[^>]+>/g, ' ').replace(/\\s+/g, ' ').slice(0, 300) : 'ok');
        }
        """
        try script.write(to: dir.appendingPathComponent("draw.mjs"), atomically: true, encoding: .utf8)
        var files: [String] = []
        for (i, t) in texts.enumerated() {
            let f = dir.appendingPathComponent("\(i).space.yaml").path
            try t.write(toFile: f, atomically: true, encoding: .utf8)
            files.append(f)
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: node)
        p.arguments = [dir.appendingPathComponent("draw.mjs").path, renderer] + files
        p.currentDirectoryURL = dir
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        p.waitUntilExit()
        let lines = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines, ["ok", "ok", "ok"], lines.joined(separator: "\n"))
    }
}
