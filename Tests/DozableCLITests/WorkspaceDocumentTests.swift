import Darwin
import DozableChat
import Foundation
import XCTest
@testable import DozableHost
@testable import DozableCLI

/// 755: a document for every workspace (docs/engineering/workspace-model.md). `RecordDocument.generate` maps a record onto a
/// space/3 document — each mapping, `lifetime: standing` always written, never a secret's value, a grant, a token or the
/// phase — and what it generates validates (generate → validate, over every kind of record); the `x-dozable` keys the
/// validator accepts and refuses; `lifetime` read as `runs` when a file says none; the `--json` shape; the YAML text reads
/// back as the same document; `--write`'s refusals.
final class WorkspaceDocumentTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: fixtures

    func record(_ name: String = "app", folders: [WorkspaceFolder] = [WorkspaceFolder(path: "/Users/ada/work/app", main: true)],
                rooms: [WorkspaceRoom]? = nil, agents: [WorkspaceAgent] = []) -> WorkspaceRecord {
        WorkspaceRecord(name: name, createdAt: t0, brief: WorkspaceBrief(sha256: "x", bytes: 1, updatedAt: t0), folders: folders,
                        rooms: rooms ?? [WorkspaceRoom(label: "main", chatRoom: name, main: true, owned: true)], agents: agents)
    }

    func generate(_ r: WorkspaceRecord, brief: String = "Fix the build", roomsMade: Set<String> = [], owners: [String: String] = [:]) -> RecordDocument.Generated {
        RecordDocument.generate(.init(record: r, briefText: brief, owner: "ada", host: "john-mac-studio", roomsMade: roomsMade, roomOwners: owners))
    }

    /// The merged validator over a document (one source: the space file), as the daemon runs it.
    func problems(_ doc: JValue) -> [SpaceProblem] {
        SpaceValidator.checkMerged(doc, SpaceLocator(sources: [SpaceSource(path: "/x/t.space.yaml", name: "t.space.yaml", kind: "space", sha256: "")], origins: [:])).problems
    }

    /// A YAML text through the CLI's parser and the merged validator.
    func check(_ yaml: String) -> (problems: [SpaceProblem], model: SpaceModel) {
        let (doc, lines, parse) = SpaceResolver.parse(yaml, name: "t.space.yaml")
        XCTAssertTrue(parse.isEmpty, parse.map(\.text).joined(separator: "\n"))
        let loc = SpaceLocator(sources: [SpaceSource(path: "/x/t.space.yaml", name: "t.space.yaml", kind: "space", sha256: "")], origins: lines)
        return SpaceValidator.checkMerged(doc ?? .object([]), loc)
    }

    func errors(_ yaml: String) -> [String] { check(yaml).problems.filter(\.isError).map(\.message) }

    func at(_ v: JValue, _ p: String) -> JValue? { SpaceDoc.at(v, p) }
    func str(_ v: JValue, _ p: String) -> String? { SpaceDoc.string(SpaceDoc.at(v, p)) }

    // MARK: generate: each mapping

    /// A plain `new` (a folder, its own room, a brief): space/3.1, standing, the brief held in the document, the folder
    /// external and main, the room owned and main; nothing of the phase.
    func testAPlainNew() {
        var r = record()
        r.brief.refs = ["https://example.com/issue/1"]
        r.flags.startedAt = t0
        r.permissions = WorkspaceGrants()
        let g = generate(r)
        let d = g.document
        XCTAssertEqual(SpaceDoc.members(d).map(\.key), ["doz", "space", "owner", "lifetime", "brief", "folders", "chat"])
        XCTAssertEqual(str(d, "/doz"), "space/3.1")
        XCTAssertEqual(str(d, "/lifetime"), "standing")
        XCTAssertEqual(str(d, "/brief/text"), "Fix the build")
        XCTAssertEqual(SpaceDoc.strings(at(d, "/brief/refs")), ["https://example.com/issue/1"])
        XCTAssertEqual(str(d, "/folders/app-folder/external"), "/Users/ada/work/app")
        XCTAssertEqual(SpaceDoc.bool(at(d, "/folders/app-folder/main")), true)
        XCTAssertEqual(SpaceDoc.bool(at(d, "/chat/rooms/app/main")), true)
        XCTAssertNil(at(d, "/chat/rooms/app/external"))
        XCTAssertNil(at(d, "/x-dozable"), "no held key here: nothing under x-dozable")
        let text = SpaceDoc.text(d)
        for never in ["startedAt", "flags", "runs", "permissions", "grant", "running", "setting-up"] {
            XCTAssertFalse(text.contains(never), "never the phase or a grant: \(never)")
        }
        XCTAssertEqual(problems(d).filter(\.isError).map(\.message), [])
    }

    /// `new --preset … --worker`: a declared worker is an owned agent (task → prompt) in the main folder; defaults →
    /// agent_defaults (vm under x-dozable); the network default → x-dozable.network.
    func testADeclaredWorkerAndTheDefaults() {
        var r = record()
        r.declaredWorkers = [WorkspaceDeclaredWorker(name: "bot1", task: "Fix the failing test", declaredAt: t0)]
        r.defaults = WorkspaceDefaults(isolation: "fenced", network: "standard")
        var d = generate(r).document
        XCTAssertEqual(str(d, "/agents/bot1/prompt"), "Fix the failing test")
        XCTAssertEqual(str(d, "/agents/bot1/kind"), "claude-code")
        XCTAssertEqual(str(d, "/agents/bot1/role"), "worker")
        XCTAssertEqual(str(d, "/agents/bot1/folder"), "app-folder")
        XCTAssertEqual(str(d, "/agent_defaults/isolation"), "fenced")
        XCTAssertEqual(str(d, "/x-dozable/network"), "standard")
        XCTAssertEqual(problems(d).filter(\.isError).map(\.message), [])
        r.defaults = WorkspaceDefaults(isolation: "vm")
        d = generate(r).document
        XCTAssertEqual(str(d, "/agent_defaults/x-dozable/isolation"), "vm")
        XCTAssertEqual(problems(d).filter(\.isError).map(\.message), [])
    }

    /// A manager → external {bot} with role manager; a worker from a bot → external {bot}; an anonymous worker → owned
    /// (fenced, unfenced, or `where: sandbox:` with the sandbox owned); an ended worker is gone.
    func testTheManagerAndTheWorkers() {
        let r = record(agents: [
            WorkspaceAgent(name: "mira", role: "manager", place: .macSession("app"), startedAt: t0, bot: "mira", isolation: "fenced"),
            { var a = WorkspaceAgent(name: "bot1", place: .macSession("app-bot1"), startedAt: t0, isolation: "fenced"); a.task = "list the files"; a.anonymous = true; return a }(),
            { var a = WorkspaceAgent(name: "bot2", place: .macSession("app-bot2"), startedAt: t0, isolation: "unfenced"); a.task = "review"; a.anonymous = true; return a }(),
            { var a = WorkspaceAgent(name: "vm1", place: AgentPlace(sandbox: "app-vm1", session: "vm1"), startedAt: t0, isolation: "vm"); a.task = "build"; a.anonymous = true; return a }(),
            { var a = WorkspaceAgent(name: "otto", place: .macSession("app-otto"), startedAt: t0, bot: "otto", isolation: "fenced"); a.task = "help"; return a }(),
            { var a = WorkspaceAgent(name: "gone", place: .macSession("app-gone"), startedAt: t0); a.task = "x"; a.anonymous = true; a.endedAt = t0; return a }(),
        ])
        let g = generate(r)
        let d = g.document
        XCTAssertEqual(SpaceDoc.members(at(d, "/agents")).map(\.key), ["mira", "bot1", "bot2", "vm1", "otto"])
        XCTAssertEqual(str(d, "/agents/mira/external/bot"), "mira")
        XCTAssertEqual(str(d, "/agents/mira/role"), "manager")
        XCTAssertEqual(str(d, "/agents/bot1/isolation"), "fenced")
        XCTAssertEqual(str(d, "/agents/bot1/prompt"), "list the files")
        XCTAssertEqual(str(d, "/agents/bot2/isolation"), "unfenced")
        XCTAssertEqual(str(d, "/agents/vm1/where"), "sandbox:app-vm1")
        XCTAssertNil(at(d, "/agents/vm1/isolation"))
        XCTAssertNotNil(at(d, "/sandboxes/app-vm1"))
        XCTAssertEqual(str(d, "/agents/otto/external/bot"), "otto")
        XCTAssertEqual(str(d, "/agents/otto/role"), "worker")
        XCTAssertTrue(g.notes.contains { $0.contains("otto") })
        XCTAssertEqual(problems(d).filter(\.isError).map(\.message), [])
    }

    /// Adopted: an `@mac` session → external {session}; a sandbox → x-dozable.external.sandbox (only referenced); an agent
    /// elsewhere is left out with a note.
    func testAdoptedAgents() {
        let r = record(agents: [
            WorkspaceAgent(name: "wsu", place: .macSession("wsu"), startedAt: t0),
            WorkspaceAgent(name: "wsa", place: .sandbox("wsa"), startedAt: t0),
            WorkspaceAgent(name: "far", place: AgentPlace(elsewhere: "m1b"), startedAt: t0),
        ])
        let g = generate(r)
        let d = g.document
        XCTAssertEqual(str(d, "/agents/wsu/external/session"), "wsu")
        XCTAssertEqual(str(d, "/agents/wsa/x-dozable/external/sandbox"), "wsa")
        XCTAssertNil(at(d, "/agents/far"))
        XCTAssertTrue(g.notes.contains { $0.contains("far runs elsewhere") })
        let checked = SpaceValidator.checkMerged(d, SpaceLocator(sources: [SpaceSource(path: "/x", name: "x", kind: "space", sha256: "")], origins: [:]))
        XCTAssertEqual(checked.problems.filter(\.isError).map(\.message), [])
        // The sandbox agent is external: compiled as adopted, never started.
        let i = SpaceIntent.compile(checked.model, d, SpaceLocator(sources: [], origins: [:]))
        let wsa = i.agents.first { $0.name == "wsa" }
        XCTAssertEqual(wsa?.external, true)
        XCTAssertEqual(wsa?.sandbox, "wsa")
        XCTAssertFalse(i.ownedAgents.contains { $0.name == "wsa" })
        XCTAssertEqual(i.effectiveLifetime, "standing")
    }

    /// No room: no `chat:` at all, and it validates. A linked room: external by the shared-room rule — the workspace whose
    /// log made it, else `_`.
    func testRoomsOwnedLinkedAndNone() {
        var d = generate(record(rooms: [])).document
        XCTAssertNil(at(d, "/chat"))
        XCTAssertEqual(problems(d).filter(\.isError).map(\.message), [])
        let linked = record(rooms: [WorkspaceRoom(label: "main", chatRoom: "launch", main: true)])
        d = generate(linked, owners: ["launch": "video"]).document
        XCTAssertEqual(str(d, "/chat/rooms/launch/external"), "doz://john-mac-studio/video/room/launch")
        XCTAssertEqual(SpaceDoc.bool(at(d, "/chat/rooms/launch/main")), true)
        XCTAssertEqual(problems(d).filter(\.isError).map(\.message), [])
        d = generate(linked).document
        XCTAssertEqual(str(d, "/chat/rooms/launch/external"), "doz://john-mac-studio/_/room/launch")
        // A room the record does not mark owned, which its own log says it made: owned.
        d = generate(record(rooms: [WorkspaceRoom(label: "main", chatRoom: "app", main: true)]), roomsMade: ["app"]).document
        XCTAssertNil(at(d, "/chat/rooms/app/external"))
        // A room gone for good is not in the document.
        var gone = WorkspaceRoom(label: "main", chatRoom: "app", main: true, owned: true)
        gone.goneAt = t0
        XCTAssertNil(at(generate(record(rooms: [gone])).document, "/chat"))
    }

    /// Names: one namespace, the name rule; a folder with the space's name or a clash gets a suffix; no folder at all.
    func testNamesAreOneNamespace() {
        let r = record(folders: [WorkspaceFolder(path: "/w/app", main: true), WorkspaceFolder(path: "/x/App", mode: "ro"), WorkspaceFolder(path: "/y/_9")],
                       agents: [WorkspaceAgent(name: "My_Session", place: .macSession("My_Session"), startedAt: t0)])
        let g = generate(r)
        XCTAssertEqual(SpaceDoc.members(at(g.document, "/folders")).map(\.key), ["app-folder", "app-2", "folder"])
        XCTAssertEqual(str(g.document, "/folders/app-2/access"), "ro")
        XCTAssertNil(at(g.document, "/folders/app-2/main"), "only the main folder is marked")
        XCTAssertEqual(SpaceDoc.members(at(g.document, "/agents")).map(\.key), ["my-session"])
        XCTAssertEqual(str(g.document, "/agents/my-session/external/session"), "My_Session")
        XCTAssertEqual(problems(g.document).filter(\.isError).map(\.message), [])
        XCTAssertNil(at(generate(record(folders: [])).document, "/folders"))
    }

    // MARK: generate → validate, over every record fixture (the zero-change gate is a later stage)

    func testEveryRecordFixtureGeneratesAValidDocument() {
        let fixtures: [String: WorkspaceRecord] = [
            "plain new": record(),
            "preset + worker": { var r = record(); r.declaredWorkers = [WorkspaceDeclaredWorker(name: "bot1", task: "Fix it", declaredAt: t0)]; r.defaults = WorkspaceDefaults(isolation: "fenced", network: "locked"); return r }(),
            "an adopted @mac session": record(agents: [WorkspaceAgent(name: "wsu", place: .macSession("wsu"), startedAt: t0)]),
            "a manager": record(agents: [WorkspaceAgent(name: "mira", role: "manager", place: .macSession("app"), startedAt: t0, bot: "mira", isolation: "vm")]),
            "no room": record(rooms: []),
            "no folder, no room, empty brief": record(folders: [], rooms: []),
        ]
        for (what, r) in fixtures {
            let d = generate(r, brief: what == "no folder, no room, empty brief" ? "" : "Fix the build").document
            XCTAssertEqual(problems(d).filter(\.isError).map(\.text), [], what)
            XCTAssertEqual(SpaceDozable.lifetime(d), "standing", what)
            XCTAssertEqual(str(RecordDocument.view(d), "/lifetime"), "standing", what)
        }
    }

    // MARK: x-dozable in the validator

    static let head = "doz: space/3\nspace: app\nowner: ada\n"

    func testTheXDozableKeysAreAccepted() {
        let yaml = Self.head + """
        x-dozable:
          lifetime: standing
          brief: { text: Fix the build, refs: [https://example.com/1] }
          network: { preset: standard, allow: [api.example.com] }
          about: { title: App, summary: one line, tags: [build], needs: { network: standard } }
          layout: { app: { x: 1, y: 2 } }
        agent_defaults: { x-dozable: { isolation: vm } }
        folders:
          code: { external: ~/work/app, x-dozable: { main: true } }
          scratch: { x-dozable: { lifetime: run } }
        agents:
          helper: { kind: claude-code, folder: code, prompt: help, x-dozable: { restart: on-failure, network: locked } }
          wsa: { role: worker, x-dozable: { external: { sandbox: wsa } } }
        sandboxes:
          box: { x-dozable: { lifetime: run } }
        chat:
          rooms:
            app: { main: true, x-dozable: { lifetime: run } }
        x-other: { anything: goes }
        """
        let (p, m) = check(yaml)
        XCTAssertEqual(p.filter(\.isError).map(\.text), [])
        XCTAssertEqual(m.lifetime, "standing")
        XCTAssertEqual(m.briefText, "Fix the build")
        XCTAssertEqual(m.briefRefs, ["https://example.com/1"])
        XCTAssertEqual(m.brief, "", "no brief file")
        XCTAssertEqual(m.resource("wsa")?.lifetime, "external")
        // The brief as a file under x-dozable.
        let f = check(Self.head + "x-dozable: { brief: { file: BRIEF.md } }\n")
        XCTAssertEqual(f.problems.filter(\.isError).map(\.text), [])
        XCTAssertEqual(f.model.brief, "BRIEF.md")
    }

    func testTheXDozableKeysAreCheckedStrictly() {
        func one(_ yaml: String, _ want: String, file: StaticString = #filePath, line: UInt = #line) {
            let e = errors(Self.head + yaml)
            XCTAssertTrue(e.contains { $0.contains(want) }, "wanted \(want) in \(e)", file: file, line: line)
        }
        one("x-dozable: { brief: { text: x }, lifetme: standing }\n", "unknown key \"lifetme\" in x-dozable (did you mean \"lifetime\"?)")
        one("x-dozable: { brief: { text: x }, lifetime: forever }\n", "is not a valid \"lifetime\"")
        one("brief: B.md\nx-dozable: { brief: { text: x } }\n", "the brief is written twice: brief: and x-dozable.brief")
        one("x-dozable: { brief: { text: x, file: B.md } }\n", "x-dozable.brief is its text or its file, not both")
        one("x-dozable: { brief: {} }\n", "x-dozable.brief needs its text or its file")
        one("x-dozable: { lifetime: standing }\n", "the file is missing \"brief\"")
        one("brief: B.md\nfolders:\n  a: { external: /a, x-dozable: { main: true } }\n  b: { external: /b, x-dozable: { main: true } }\n", "two main folders: \"a\" and \"b\"")
        one("brief: B.md\nfolders:\n  a: { external: /a, x-dozable: { main: yes } }\n", "expected true or false")
        one("brief: B.md\nagents:\n  w: { prompt: x, x-dozable: { restart: always } }\n", "is not a valid \"restart\"")
        one("brief: B.md\nagents:\n  w: { external: { bot: b }, x-dozable: { external: { sandbox: s } } }\n", "\"w\" is external twice")
        one("brief: B.md\nagents:\n  w: { kind: claude-code, x-dozable: { external: { sandbox: s } } }\n", "\"w\" is external, so \"kind\" can't apply")
        one("brief: B.md\nagents:\n  w: { x-dozable: { external: { sandbox: box } } }\nsandboxes:\n  box: {}\n", "\"box\" is a sandbox of this space")
        one("brief: B.md\nx-dozable: { network: wide }\n", "is not a valid \"network\"")
        // Without x-dozable.brief, space/3's rule stands; another x- key is still ignored.
        XCTAssertEqual(errors(Self.head + "brief: B.md\nx-editor: { layout: {} }\nx-whatever: 1\n"), [])
    }

    // MARK: lifetime

    func testLifetimeIsReadAsRunsWhenAFileSaysNone() {
        let (p, m) = check(Self.head + "brief: B.md\n")
        XCTAssertEqual(p.filter(\.isError).count, 0)
        XCTAssertNil(m.lifetime)
        let doc = SpaceResolver.parse(Self.head + "brief: B.md\n", name: "t").0!
        let i = SpaceIntent.compile(m, doc, SpaceLocator(sources: [], origins: [:]))
        XCTAssertEqual(i.effectiveLifetime, "runs")
        // A space file's document: `runs` written at the top (the document is space/3.1); a written one kept.
        let g = RecordDocument.merge(spec: doc, record: record())
        XCTAssertEqual(SpaceDozable.lifetime(g.document), "runs")
        XCTAssertEqual(str(RecordDocument.view(g.document), "/lifetime"), "runs")
        XCTAssertTrue(g.notes.contains { $0.contains("read as runs") })
        let standing = SpaceResolver.parse(Self.head + "x-dozable: { lifetime: standing, brief: { text: x } }\n", name: "t").0!
        let s = RecordDocument.merge(spec: standing, record: record())
        XCTAssertEqual(str(RecordDocument.view(s.document), "/lifetime"), "standing")
        XCTAssertNil(SpaceDozable.of(s.document), "lifted: the x-dozable form of first-class keys is gone")
        XCTAssertEqual(SpaceDoc.members(s.document).map(\.key), ["doz", "space", "owner", "lifetime", "brief"], "nothing added twice")
        XCTAssertEqual(str(s.document, "/doz"), "space/3.1")
        XCTAssertEqual(str(s.document, "/brief/text"), "x")
        // The file holds the lifetime too (space/3.1).
        XCTAssertEqual(str(RecordDocument.fileForm(RecordDocument.view(s.document)), "/lifetime"), "standing")
        XCTAssertEqual(problems(s.document).filter(\.isError).map(\.text), [])
    }

    /// A space file's document carries the record's extras: an agent added or adopted since the last up.
    func testASpaceFilesDocumentMergesTheRecordsExtras() {
        let spec = SpaceResolver.parse(Self.head + "brief: B.md\nagents:\n  manager: { external: { bot: mira }, role: manager }\n  w1: { kind: claude-code, prompt: one }\n", name: "t").0!
        let r = record(agents: [
            WorkspaceAgent(name: "mira", role: "manager", place: .macSession("app"), startedAt: t0, bot: "mira"),
            { var a = WorkspaceAgent(name: "w1", place: .macSession("app-w1"), startedAt: t0, isolation: "fenced"); a.task = "one"; a.anonymous = true; return a }(),
            { var a = WorkspaceAgent(name: "bot3", place: .macSession("app-bot3"), startedAt: t0, isolation: "fenced"); a.task = "later"; a.anonymous = true; return a }(),
            WorkspaceAgent(name: "wsu", place: .macSession("wsu"), startedAt: t0),
        ])
        let g = RecordDocument.merge(spec: spec, record: r)
        XCTAssertEqual(SpaceDoc.members(at(g.document, "/agents")).map(\.key), ["manager", "w1", "bot3", "wsu"])
        XCTAssertEqual(str(g.document, "/agents/bot3/prompt"), "later")
        XCTAssertEqual(str(g.document, "/agents/wsu/external/session"), "wsu")
        XCTAssertEqual(str(g.document, "/brief"), "B.md", "the file's own keys as they are")
        XCTAssertEqual(problems(g.document).filter(\.isError).map(\.text), [])
    }

    // MARK: the answer and its text

    func testTheJSONShape() throws {
        let doc = generate(record()).document
        let a = WorkspaceDocumentAnswer(workspace: "app", from: "record", document: SpaceDoc.text(RecordDocument.view(doc)), notes: [])
        let j = try a.answer()
        XCTAssertEqual(SpaceDoc.members(j).map(\.key), ["kind", "schema", "workspace", "from", "document"])
        XCTAssertEqual(str(j, "/kind"), "Document")
        XCTAssertEqual(SpaceDoc.int(at(j, "/schema")), 1)
        XCTAssertEqual(str(j, "/document/lifetime"), "standing")
        XCTAssertEqual(SpaceDoc.members(at(j, "/document")).map(\.key).prefix(4), ["doz", "space", "owner", "lifetime"])
        XCTAssertEqual(str(j, "/document/doz"), "space/3.1")
        // Through the wire: the answer's struct round-trips.
        let back = try JSONDecoder().decode(WorkspaceDocumentAnswer.self, from: JSONEncoder().encode(a))
        XCTAssertEqual(back, a)
    }

    /// The YAML `--write` writes reads back (the CLI's own parser) as exactly the file form, and that validates.
    func testTheTextReadsBackAsTheSameDocument() throws {
        var r = record(agents: [
            WorkspaceAgent(name: "mira", role: "manager", place: .macSession("app"), startedAt: t0, bot: "mira"),
            { var a = WorkspaceAgent(name: "bot1", place: .macSession("app-bot1"), startedAt: t0, isolation: "fenced"); a.task = "a task: with \"quotes\", # and\ntwo lines\n"; a.anonymous = true; return a }(),
        ])
        r.brief.refs = ["/Users/ada/notes/one two.md"]
        let view = RecordDocument.view(generate(r, brief: "Line one\n\n  indented: yes\n# not a comment\n").document)
        let a = WorkspaceDocumentAnswer(workspace: "app", from: "record", document: SpaceDoc.text(view), notes: ["a note"])
        let text = WorkspaceDocYAML.text(a, view)
        XCTAssertTrue(text.hasPrefix("# The document of the workspace app"))
        XCTAssertTrue(text.contains("\ndoz: space/3.1\n") && text.contains("\nlifetime: standing\n"), text)
        XCTAssertNil(SpaceRecordFile.formatRefusal(text), "a space file's format line first")
        let (back, _, problems) = SpaceResolver.parse(text, name: "out.space.yaml")
        XCTAssertEqual(problems.map(\.text), [])
        XCTAssertEqual(back, RecordDocument.fileForm(view))
        XCTAssertEqual(check(text).problems.filter(\.isError).map(\.text), [])
    }

    // MARK: --write

    func testWriteRefusesTheStoreClaudeLibraryAndAnExistingFile() throws {
        let home = WorkspaceStore.resolved("/tmp") + "/doz-doc-\(UUID().uuidString.prefix(8))"
        let store = home + "/store"
        try FileManager.default.createDirectory(atPath: store, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: home + "/work", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }
        let text = "doz: space/3\nspace: app\n"
        for bad in [store + "/out.space.yaml", home + "/.claude/out.space.yaml", home + "/Library/out.space.yaml", "/etc/out.space.yaml"] {
            XCTAssertThrowsError(try SpaceRecordFile.writeNew(text, to: bad, replace: true, store: store, home: home), bad) { e in
                XCTAssertEqual((e as? HostError)?.code, .invalidValue, bad)
                XCTAssertEqual(DozableExit.code(for: e as! HostError), 65)
            }
        }
        let p = home + "/work/out.space.yaml"
        try SpaceRecordFile.writeNew(text, to: p, replace: false, store: store, home: home)
        XCTAssertEqual(try String(contentsOfFile: p, encoding: .utf8), text)
        XCTAssertThrowsError(try SpaceRecordFile.writeNew(text + "x: 1\n", to: p, replace: false, store: store, home: home)) { e in
            XCTAssertEqual((e as? HostError)?.code, .alreadyExists)
            XCTAssertEqual(DozableExit.code(for: e as! HostError), 4)
        }
        XCTAssertEqual(try String(contentsOfFile: p, encoding: .utf8), text, "nothing written over it")
        try SpaceRecordFile.writeNew(text + "x: 1\n", to: p, replace: true, store: store, home: home)
        XCTAssertEqual(try String(contentsOfFile: p, encoding: .utf8), text + "x: 1\n")
        // A link in the path, and a link as the file: refused, never written through.
        try FileManager.default.createSymbolicLink(atPath: home + "/linked", withDestinationPath: home + "/work")
        XCTAssertThrowsError(try SpaceRecordFile.writeNew(text, to: home + "/linked/new.space.yaml", replace: false, store: store, home: home))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home + "/work/new.space.yaml"))
        try FileManager.default.createSymbolicLink(atPath: home + "/work/l.space.yaml", withDestinationPath: p)
        XCTAssertThrowsError(try SpaceRecordFile.writeNew("doz: space/3\n", to: home + "/work/l.space.yaml", replace: true, store: store, home: home))
        XCTAssertEqual(try String(contentsOfFile: p, encoding: .utf8), text + "x: 1\n")
    }

    /// No secret value or token in a document: a space file's secret stays a reference; nothing token-shaped.
    func testNoSecretValueOrTokenInADocument() throws {
        let spec = SpaceResolver.parse(Self.head + "brief: B.md\nsecrets:\n  api-key: { external: { keychain: doz-test-api-key }, to: api.example.com }\n", name: "t").0!
        let r = record(agents: [WorkspaceAgent(name: "mira", role: "manager", place: .macSession("app"), startedAt: t0, bot: "mira")])
        for doc in [RecordDocument.merge(spec: spec, record: r).document, generate(r).document] {
            let text = SpaceDoc.text(RecordDocument.view(doc))
            XCTAssertFalse(text.range(of: "dzc_[A-Za-z0-9]|sk-[A-Za-z0-9]|ghp_|fingerprint|CHAT_TOKEN", options: .regularExpression) != nil, text)
        }
        let doc = RecordDocument.merge(spec: spec, record: r).document
        XCTAssertEqual(str(doc, "/secrets/api-key/external/keychain"), "doz-test-api-key", "the reference is kept")
    }
}

/// 755: a space file's `~` in a guarded run.
extension TestSafetyTests {
    func testASpaceFilesHome() {
        let real = TestSafety.realHome.path
        XCTAssertEqual(TestSafety.spaceHome(["DOZ_TEST_HOME": "/tmp/h"]), real, "not guarded: the real home")
        XCTAssertEqual(TestSafety.spaceHome(["DOZ_TEST_HOME": "/tmp/h", "DOZ_TEST_GUARD": "1"]), "/tmp/h")
        XCTAssertEqual(TestSafety.spaceHome(["DOZ_TEST_HOME": "/tmp/h", "DOZ_TEST_GUARD": "1", "DOZ_TEST_REAL_MAC": "1"]), real)
        XCTAssertEqual(TestSafety.spaceHome(["DOZ_TEST_HOME": "rel", "DOZ_TEST_GUARD": "1"]), real, "only an absolute path")
        XCTAssertEqual(TestSafety.spaceHome(["DOZ_TEST_GUARD": "1"]), real)
        XCTAssertEqual(TestSafety.expandSpaceTilde("~/work/app", home: "/tmp/h"), "/tmp/h/work/app")
        XCTAssertEqual(TestSafety.expandSpaceTilde("~", home: "/tmp/h"), "/tmp/h")
        XCTAssertEqual(TestSafety.expandSpaceTilde("/abs", home: "/tmp/h"), "/abs")
        XCTAssertEqual(TestSafety.expandSpaceTilde("~other/x", home: "/tmp/h"), "~other/x")
        // The recorded files' home follows it (after the older seam).
        XCTAssertEqual(SpaceRecordFile.home(["DOZ_TEST_HOME": "/tmp/h", "DOZ_TEST_GUARD": "1"]), "/tmp/h")
        XCTAssertEqual(SpaceRecordFile.home(["DOZ_TEST_HOME": "/tmp/h", "DOZ_TEST_BRIEF_HOME": "/tmp/b", "DOZ_TEST_GUARD": "1"]), "/tmp/b")
    }
}

/// 755 through an in-process daemon core: `workspace-doc` for a record workspace (no daemon too), a missing one not found,
/// and a space file whose brief is held in the file (`x-dozable.brief.text`): up keeps it in brief.md, `show --brief` reads
/// it, the document says `standing`.
extension WorkspaceLifecycleHostTests {
    func testWorkspaceDocForEveryWorkspace() async throws {
        try await withBriefHome {
            let c = await lcore()
            try await started(c)
            let ro = await lcore(readOnly: true)
            for core in [c, ro] {
                let m = await ws(core, .workspaceDoc, "demo")
                XCTAssertNil(m.error, m.error?.message ?? "")
                let a = try XCTUnwrap(m.result).decode(WorkspaceDocumentAnswer.self)
                XCTAssertEqual(a.from, "record")
                let doc = try ChatJSON.parse(Data(a.document.utf8))
                XCTAssertEqual(SpaceDoc.string(SpaceDoc.member(doc, "lifetime")), "standing")
                XCTAssertEqual(SpaceDoc.string(SpaceDoc.at(doc, "/brief/text")), "Make the launch video.\n")
                XCTAssertNotNil(SpaceDoc.at(doc, "/agents/mira/external"))
                let checked = SpaceValidator.checkMerged(RecordDocument.fileForm(doc), SpaceLocator(sources: [SpaceSource(path: "/x", name: "x", kind: "space", sha256: "")], origins: [:]))
                XCTAssertEqual(checked.problems.filter(\.isError).map(\.text), [])
                XCTAssertFalse(a.document.contains("dzc_"))
            }
            var m = await ws(ro, .workspaceDoc, "nosuch")
            XCTAssertEqual(m.error?.code, .notFound)
            // A space file whose brief is held in the file, standing, its folder main.
            let dir = root.appendingPathComponent("spaces-held")
            try FileManager.default.createDirectory(at: dir.appendingPathComponent("app"), withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("held.space.yaml")
            try """
            doz: space/3
            space: held
            owner: ada
            x-dozable:
              lifetime: standing
              brief: { text: Fix the build }
            folders:
              app: { external: \(dir.appendingPathComponent("app").path), x-dozable: { main: true } }
            chat:
              rooms:
                held: { main: true, members: [owner] }
            """.write(to: file, atomically: true, encoding: .utf8)
            let r = SpaceResolver().resolve(file.path)
            let (problems, model) = r.check()
            XCTAssertEqual(problems.filter(\.isError).map(\.text), [])
            XCTAssertEqual(model?.brief, "")
            let q = r.request(profiles: [], brief: spaceBriefLook(model?.brief ?? "", file: r.file))
            XCTAssertNil(q.brief)
            _ = try acted(try await spaceUpAct(c, q))
            m = await ws(c, .workspaceShow, "held") { $0.withBrief = true }
            XCTAssertNil(m.error, m.error?.message ?? "")
            XCTAssertEqual(try XCTUnwrap(m.result).decode(WorkspaceDetail.self).briefText, "Fix the build")
            let posted = rooms.lock.withLock { rooms.msgs["held"] ?? [] }.map { SpaceDoc.string(SpaceDoc.member($0, "content")) ?? "" }
            XCTAssertTrue(posted.contains { $0.contains("Fix the build") }, "up posted it: \(posted)")
            m = await ws(c, .workspaceDoc, "held")
            let a = try XCTUnwrap(m.result).decode(WorkspaceDocumentAnswer.self)
            XCTAssertEqual(a.from, "space-file")
            let doc = try ChatJSON.parse(Data(a.document.utf8))
            XCTAssertEqual(SpaceDoc.string(SpaceDoc.member(doc, "lifetime")), "standing")
            XCTAssertEqual(SpaceDoc.bool(SpaceDoc.at(doc, "/folders/app/main")), true, "the x-dozable form lifted: space/3.1")
            XCTAssertEqual(SpaceDoc.string(SpaceDoc.member(doc, "doz")), "space/3.1")
        }
    }
}
