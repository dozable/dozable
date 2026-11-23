import Foundation
import XCTest
@testable import DozableChat
@testable import DozableHost
@testable import DozableCLI

/// The work description (the brief and its addenda) and proposals to change it: the pure parts (the goal a run takes, the
/// addendum's limits, the proposals' file, the revision, the document's `brief.addenda`), the permissions (the ids, the
/// reviewer role, decide off until granted), the chat server's own ask (in a closed room, answered by the owner, never
/// expired by the closed set, closed with an outcome line), the daemon end to end over a REAL chat core (retro → the Ask →
/// the owner's answer → the addendum; decide; proposal-decided; edit --addendum; a restart keeps them), and a space file's
/// `x-dozable.permissions` (requests in the plan; an unknown name refused). Scratch folders only.
final class WorkDescriptionTests: XCTestCase {
    var dir = ""
    var cores: [ChatServerCore] = []

    override func setUpWithError() throws {
        dir = "/tmp/doz-workdesc-\(getpid())-\(UUID().uuidString.prefix(6))"
        try FileManager.default.createDirectory(atPath: dir + "/data", withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    override func tearDownWithError() throws {
        for c in cores { c.close() }
        try? FileManager.default.removeItem(atPath: dir)
    }

    // MARK: pure

    func testARunWithNoGoalTakesTheBriefAndEveryAddendum() {
        XCTAssertEqual(WorkDescription.goal(brief: "Fix the build\n", addenda: []), "Fix the build\n", "no addenda: the brief as it is")
        let g = WorkDescription.goal(brief: "Fix the build\n", addenda: [
            WorkspaceAddendum(run: "2026-11-24-2", by: "manager", text: "Run the linter before the tests"),
            WorkspaceAddendum(by: "owner", text: "Two lines\nof text"),
        ])
        XCTAssertEqual(g, "Fix the build\n\nAddenda to the work description:\n- Run the linter before the tests (from run 2026-11-24-2)\n- Two lines\n  of text\n")
    }

    func testAnAddendumIsNotEmptyAndBounded() {
        for bad in [nil, "", "  \n "] as [String?] {
            XCTAssertThrowsError(try WorkDescription.checkAddendum(bad)) { XCTAssertEqual(ExitCodes.exit(for: HostError.from($0)), 65) }
        }
        XCTAssertThrowsError(try WorkDescription.checkAddendum(String(repeating: "x", count: WorkDescription.maximumAddendumBytes + 1)))
        XCTAssertEqual(try WorkDescription.checkAddendum("Run the linter"), "Run the linter")
    }

    func testAnAddendumIsARevisionOfTheDescription() {
        let log = [WorkspaceLogEntry(action: "created"), WorkspaceLogEntry(action: "brief-edited"), WorkspaceLogEntry(action: "addendum-added"),
                   WorkspaceLogEntry(action: "proposal-made"), WorkspaceLogEntry(action: "proposal-applied")]
        XCTAssertEqual(WorkspaceRuns.descriptionRevision(log), 3, "the brief edit and the addendum; a proposal alone changes nothing")
        var e = WorkspaceLogEntry(action: "proposal-made", agent: "manager", run: "2026-11-24-1")
        e.proposal = "pr-0000abcd"
        XCTAssertEqual(e.sentence, "manager proposed a change to the work description (pr-0000abcd), from run 2026-11-24-1")
    }

    func testTheProposalsFileRoundTripsAndIDsAreChecked() throws {
        let ws = WorkspaceStore(store: DozableStore(root: URL(fileURLWithPath: dir + "/store")))
        try FileManager.default.createDirectory(atPath: ws.folder("demo"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        XCTAssertEqual(try WorkspaceProposalsFile.read(ws, "demo").proposals, [], "none: empty")
        var p = WorkspaceProposal(id: WorkspaceProposal.newID(existing: []), workspace: "demo", by: "manager", text: "Lint first", run: "2026-11-24-1")
        p.notes = ["said once"]
        XCTAssertTrue(WorkspaceProposal.isValidID(p.id))
        XCTAssertFalse(WorkspaceProposal.isValidID("pr-../x"))
        try WorkspaceProposalsFile(proposals: [p]).write(ws, "demo")
        let back = try WorkspaceProposalsFile.read(ws, "demo").proposals
        XCTAssertEqual(back.count, 1)
        XCTAssertEqual(back[0].id, p.id)
        XCTAssertEqual(back[0].state, "open")
        XCTAssertNil(back[0].notes, "notes are the answer's, never kept")
        let mode = (try FileManager.default.attributesOfItem(atPath: ws.folder("demo") + "/proposals.json")[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(mode, 0o600)
    }

    func testTheDocumentShowsTheAddendaInTheBriefOnlyWhenThereAreSome() throws {
        var rec = WorkspaceRecord(name: "demo", createdAt: Date(), brief: WorkspaceBrief(sha256: "", bytes: 0, updatedAt: Date()), folders: [])
        func brief(_ r: WorkspaceRecord) -> JValue? { RecordDocument.generate(.init(record: r, briefText: "Fix the build")).document.field("brief") }
        XCTAssertNil(brief(rec)?.field("addenda"), "no addenda: absent")
        rec.addenda = [WorkspaceAddendum(run: "2026-11-24-2", at: Date(timeIntervalSince1970: 1_900_000_000), by: "manager", text: "Lint first")]
        let a = try XCTUnwrap(brief(rec)?.field("addenda"))
        guard case .array(let items) = a else { return XCTFail("not a list") }
        XCTAssertEqual(items.first?.field("text")?.stringValue, "Lint first")
        XCTAssertEqual(items.first?.field("run")?.stringValue, "2026-11-24-2")
        XCTAssertEqual(items.first?.field("by")?.stringValue, "manager")
        XCTAssertEqual(brief(rec)?.field("text")?.stringValue, "Fix the build", "the brief's text is never rewritten")
        // The record keeps them (an older doz keeps the key as an unknown field).
        let data = try HostWire.prettyEncoder.encode(rec)
        XCTAssertEqual(try HostWire.decoder.decode(WorkspaceRecord.self, from: data).addenda, rec.addenda)
    }

    // MARK: permissions

    func testTheDescriptionPermissionsAreOffUntilGrantedAndTheReviewerRoleProposes() {
        for id in ["description.propose", "description.decide", "description.edit", "journal.read", "journal.write", "journal.supersede", "evidence.attach"] {
            XCTAssertTrue(GrantPermissions.isKnown(id), id)
        }
        XCTAssertTrue(GrantPermissions.words("journal.write").contains("gates nothing yet"))
        XCTAssertEqual(RoleTable.role("reviewer")?.answers, ["journal.write": .allow, "evidence.attach": .allow, "description.propose": .allow])
        let now = Date()
        func decide(_ perm: String, _ grants: [Grant]) -> GrantAnswer {
            GrantDecision.decide(GrantQuery(name: "manager", home: "app", bot: "manager", perm: perm, workspace: "app",
                                            recordRoles: [HeldRole(role: "manager", workspace: "app")]),
                                 GrantFacts(grants: grants, now: now)).answer
        }
        for p in ["description.propose", "description.decide", "description.edit"] { XCTAssertEqual(decide(p, []), .ask, "\(p): off for an agent") }
        let reviewer = Grant(subject: .bot("manager"), role: "reviewer", scope: .workspace("app"), at: now)
        XCTAssertEqual(decide("description.propose", [reviewer]), .allow)
        XCTAssertEqual(decide("description.decide", [reviewer]), .ask, "the reviewer proposes; it does not decide")
        XCTAssertEqual(decide("description.decide", [reviewer, Grant(subject: .bot("manager"), perm: "description.decide", answer: .allow,
                                                                      scope: .workspace("app"), at: now)]), .allow)
        XCTAssertNil(RoleTable.grantRefusal("reviewer", scope: .workspace("app"), subject: .bot("manager")))
    }

    // MARK: the chat server's own ask

    func chatCore() throws -> ChatServerCore {
        let config = """
            {"line_port": 0, "http_port": 0, "data_dir": "\(dir)/data", "default_room": "room1", "participants": [{"name": "ada", "kind": "human", "deliver": "web"},
             {"name": "bot1", "kind": "agent"}], "rooms": {"room1": ["ada", "bot1"]}, "allow": ["127.0.0.1"], "require_tokens": true,
             "agent_addresses": ["127.0.0.0/8"], "secrets_file_only": true, "bind": "127.0.0.1", "ask_max_open": 1, "ask_cooldown_seconds": -1}
            """
        let c = try ChatConfig.resolve(data: Data(config.utf8), .init())
        let core = ChatServerCore(config: c, secrets: ChatSecrets(), release: "1.2.3", sessionsDir: dir + "/no-sessions")
        core.load()
        core.startAsks()
        cores.append(core)
        return core
    }

    static let spec = try! ChatAskSpec.read(.map(["options": .array([.map(["id": .string("apply"), "label": .string("Apply")])])]))!

    func testDozablesOwnAskLivesInAClosedRoomAndTheOwnerAnswersIt() throws {
        let core = try chatCore()
        core.setClosed(["room1": "demo"], reasons: false)
        let id = chatNewID()
        guard case .success(let made) = core.systemAsk(room: "room1", msgID: id, question: "Apply this lesson?", spec: Self.spec) else { return XCTFail("refused") }
        XCTAssertGreaterThan(made.number, 0)
        // Again: the same ask, not a second one (and no per-asker limit for Dozable's own: a second proposal is asked too).
        guard case .success(let again) = core.systemAsk(room: "room1", msgID: id, question: "Apply this lesson?", spec: Self.spec) else { return XCTFail("refused") }
        XCTAssertEqual(again.number, made.number)
        guard case .success = core.systemAsk(room: "room1", msgID: chatNewID(), question: "Another lesson?", spec: Self.spec) else { return XCTFail("a second refused") }
        let st = try core.store("room1")
        let m = try st.one(id)
        XCTAssertEqual(m.from, ChatProtocol.systemName)
        XCTAssertEqual(m.ask?.deciders, ["ada"], "the room's people decide")
        // The closed set handed again (another workspace finished) does not expire it.
        core.setClosed(["room1": "demo"], reasons: false)
        XCTAssertEqual(st.askOf(id)?.state, "open")
        // A participant's ask in the closed room is still refused, and so is a decision of anything but Dozable's own.
        XCTAssertEqual(core.decide(room: "room1", who: "ada", ref: id, input: ChatDecideInput(option: "apply", text: ""), via: "page", verified: true).state, "decided")
        XCTAssertEqual(st.askOf(id)?.decision?.option, "apply")
        XCTAssertEqual(st.askOf(id)?.decision?.by, "ada")
    }

    func testCloseWithdrawsItAndPostsTheOutcome() throws {
        let core = try chatCore()
        let id = chatNewID()
        guard case .success = core.systemAsk(room: "room1", msgID: id, question: "Apply this lesson?", spec: Self.spec) else { return XCTFail("refused") }
        guard case .success(let s) = core.systemAskClose(room: "room1", msgID: id, outcome: "Proposal pr-00000001 was applied.") else { return XCTFail("refused") }
        XCTAssertEqual(s, "withdrawn")
        let st = try core.store("room1")
        XCTAssertEqual(st.askOf(id)?.state, "withdrawn")
        let (page, _) = try core.messagePage(room: "room1", after: 0, before: 0, limit: 50, viewer: "")
        XCTAssertTrue(page.contains { $0.kind == "change" && $0.content == "Proposal pr-00000001 was applied." && $0.from == ChatProtocol.systemName })
        // Again: closed already, nothing posted twice.
        guard case .success(let s2) = core.systemAskClose(room: "room1", msgID: id, outcome: "again") else { return XCTFail("refused") }
        XCTAssertEqual(s2, "withdrawn")
        XCTAssertFalse(try core.messagePage(room: "room1", after: 0, before: 0, limit: 50, viewer: "").messages.contains { $0.content == "again" })
        // Only Dozable's own: a participant's ask is not closed this way.
        guard case .failure = core.systemAskClose(room: "room1", msgID: chatNewID(), outcome: "") else { return XCTFail("closed an unknown ask") }
        // Over the control channel, as the daemon sends it.
        let line = ChatRoomControl.answer(.map(["version": .int(1), "id": .string("s1"),
                                                "systemAsk": .map(["room": .string("room1"), "msgId": .string(chatNewID()), "question": .string("Q?"),
                                                                   "ask": .map(["options": .array([.map(["id": .string("apply")])])])])]), core: core)
        let v = try ChatJSON.parse(try XCTUnwrap(line).dropLast())
        XCTAssertEqual(v.field("id")?.stringValue, "s1")
        XCTAssertNotNil(v.field("asked")?.field("number"))
    }

    // MARK: the daemon, end to end over a real chat core

    /// The owner's socket and the control channel of a real core, in-process.
    final class RealChat: WorkspaceChat, @unchecked Sendable {
        let core: ChatServerCore
        let handler: ChatPageHandler
        init(_ core: ChatServerCore) { self.core = core; handler = ChatPageHandler(core: core) }
        func readiness() async -> WorkspaceChatReadiness { .ready }
        func rooms() throws -> Set<String> { ["room1"] }
        func makeRoom(_ name: String) throws {}
        func post(room: String, content: String) throws {}
        func invite(room: String, name: String) throws -> Bool { false }
        func ownerCall(_ method: String, _ target: String, body: JValue?, headers: [(String, String)]) throws -> (Int, JValue) {
            var hs: [String: String] = [:]
            for (k, v) in headers { hs[k.lowercased()] = v }
            let res = handler.handle(ChatHTTPRequest(method: method, target: target, headers: hs, body: body.map { ChatJSON.encode($0) } ?? [],
                                                     remoteIP: "", caller: .owner))
            return (res.status, (try? ChatJSON.parse(res.body)) ?? .null)
        }
        func control(_ field: String, _ body: JValue) async throws -> JValue {
            let line = try XCTUnwrap(ChatRoomControl.answer(.map(["version": .int(1), "id": .string("t"), field: body]), core: core))
            let v = try ChatJSON.parse(Array(line.dropLast()))
            if let why = v.field("refused")?.stringValue { throw HostError(.invalidPhase, why) }
            return v
        }
    }

    func host(_ chat: WorkspaceChat?) async throws -> HostCore {
        let store = DozableStore(root: URL(fileURLWithPath: dir + "/store"))
        let ws = WorkspaceStore(store: store)
        if (try ws.read("demo")) == nil {
            var rec = WorkspaceRecord(name: "demo", createdAt: Date(), brief: WorkspaceBrief(sha256: "", bytes: 0, updatedAt: Date()), folders: [],
                                      rooms: [WorkspaceRoom(label: "demo", chatRoom: "room1", main: true, owned: true)])
            var run = WorkspaceRun(id: "2026-11-24-1", startedAt: Date(timeIntervalSinceNow: -60))
            run.endedAt = Date()
            rec.runs = [run]
            try ws.create(rec, brief: Data("Fix the build\n".utf8), log: [WorkspaceLogEntry(action: "created")])
        }
        let c = HostCore(store: store, readOnly: false, version: "test")
        await c.setWorkspaceChat(chat)
        return c
    }

    func send(_ c: HostCore, _ op: HostOp, _ edit: (inout WorkspaceRequest) -> Void) async -> HostMessage {
        var w = WorkspaceRequest(name: "demo")
        edit(&w)
        var r = HostRequest(op)
        r.workspaceRequest = w
        return await c.handle(r)
    }

    func proposal(_ m: HostMessage, file: StaticString = #filePath, line: UInt = #line) throws -> WorkspaceProposal {
        XCTAssertNil(m.error, m.error?.message ?? "", file: file, line: line)
        return try XCTUnwrap(m.result, file: file, line: line).decode(WorkspaceProposal.self)
    }

    func record(_ c: HostCore) throws -> WorkspaceRecord { try XCTUnwrap(try WorkspaceStore(store: DozableStore(root: URL(fileURLWithPath: dir + "/store"))).read("demo")) }

    func testAProposalChangesNothingUntilTheOwnerAnswersItsAskYes() async throws {
        let core = try chatCore()
        core.setClosed(["room1": "demo"], reasons: false)      // the workspace finished: its room is closed
        let c = try await host(RealChat(core))
        let p = try proposal(await send(c, .workspaceRetro) { $0.addendum = "Run the linter before the tests" })
        XCTAssertEqual(p.kind, "WorkspaceProposal")
        XCTAssertEqual(p.origin, "retro")
        XCTAssertEqual(p.state, "open")
        XCTAssertEqual(p.source.run, "2026-11-24-1", "the last run by default")
        XCTAssertEqual(p.by, "owner")
        XCTAssertEqual(p.room, "room1")
        XCTAssertNil(p.notes, p.notes?.joined() ?? "")
        let askID = try XCTUnwrap(p.askId)
        XCTAssertEqual(try record(c).addenda, [], "nothing changes until it is decided")
        // The owner answers Apply with doz chat decide (the daemon's chat-decide): applied at once.
        var r = HostRequest(.chatDecide)
        r.chatAsk = ChatAskRequest(room: "room1", ask: "#\(try XCTUnwrap(p.askNumber))")
        r.chatAsk?.option = "apply"
        let decided = await c.handle(r)
        XCTAssertNil(decided.error, decided.error?.message ?? "")
        let rec = try record(c)
        XCTAssertEqual(rec.addenda.map(\.text), ["Run the linter before the tests"])
        XCTAssertEqual(rec.addenda.first?.run, "2026-11-24-1")
        XCTAssertEqual(rec.addenda.first?.by, "owner")
        XCTAssertEqual(try core.store("room1").askOf(askID)?.state, "decided")
        // The document says it; a run with no goal takes it.
        let doc = await send(c, .workspaceDoc) { _ in }
        let answer = try XCTUnwrap(doc.result).decode(WorkspaceDocumentAnswer.self)
        XCTAssertTrue(answer.document.contains("Run the linter before the tests"))
        XCTAssertTrue(WorkDescription.goal(brief: "Fix the build\n", addenda: rec.addenda).contains("Run the linter before the tests"))
        // Decided: decide refuses (exit 3), and the listing says how it was decided — after a restart too.
        let again = await send(c, .workspaceDecide) { $0.proposal = p.id; $0.decision = "decline" }
        XCTAssertEqual(again.error?.code, .proposalDecided)
        XCTAssertEqual(ExitCodes.exit(for: .proposalDecided), 3)
        let fresh = try await host(RealChat(core))
        let listed = await send(fresh, .workspaceProposals) { _ in }
        let l = try XCTUnwrap(listed.result).decode(WorkspaceProposals.self)
        XCTAssertEqual(l.kind, "WorkspaceProposals")
        XCTAssertEqual(l.proposals.map(\.state), ["applied"])
        XCTAssertEqual(l.proposals.first?.decidedHow, "ask")
    }

    func testDeclinedInChatOrDecidedHereAndTheAskClosesWithTheOutcome() async throws {
        let core = try chatCore()
        let c = try await host(RealChat(core))
        let a = try proposal(await send(c, .workspaceRetro) { $0.addendum = "Skip the tests" })
        var r = HostRequest(.chatDecide)
        r.chatAsk = ChatAskRequest(room: "room1", ask: "#\(a.askNumber ?? 0)")
        r.chatAsk?.decline = true
        let declined = await c.handle(r)
        XCTAssertNil(declined.error)
        XCTAssertEqual(try record(c).addenda, [], "declined: nothing changes")
        // Decided with the verb: applied, its Ask withdrawn with Dozable's line.
        let b = try proposal(await send(c, .workspaceRetro) { $0.addendum = "Lint first"; $0.run = "2026-11-24-1" })
        let d = try proposal(await send(c, .workspaceDecide) { $0.proposal = b.id; $0.decision = "apply" })
        XCTAssertEqual(d.state, "applied")
        XCTAssertEqual(d.decidedHow, "decide")
        XCTAssertEqual(try core.store("room1").askOf(try XCTUnwrap(b.askId))?.state, "withdrawn")
        XCTAssertTrue(try core.messagePage(room: "room1", after: 0, before: 0, limit: 50, viewer: "").messages.contains {
            $0.kind == "change" && $0.content.contains(b.id) && $0.content.contains("applied")
        })
        XCTAssertEqual(try record(c).addenda.map(\.text), ["Lint first"])
        // A bad id, decision or run: refused, nothing written.
        let e1 = await send(c, .workspaceDecide) { $0.proposal = "pr-ffffffff"; $0.decision = "apply" }
        XCTAssertEqual(e1.error?.code, .notFound)
        let e2 = await send(c, .workspaceDecide) { $0.proposal = b.id; $0.decision = "maybe" }
        XCTAssertEqual(e2.error?.code, .invalidValue)
        let e3 = await send(c, .workspaceRetro) { $0.addendum = "x"; $0.run = "2000-01-01-1" }
        XCTAssertEqual(e3.error?.code, .notFound)
        let e4 = await send(c, .workspaceRetro) { $0.addendum = " " }
        XCTAssertEqual(e4.error?.code, .invalidValue)
    }

    func testEditAddsAnAddendumDirectlyWithNoAsk() async throws {
        let core = try chatCore()
        let c = try await host(RealChat(core))
        let m = await send(c, .workspaceAddendum) { $0.addendum = "Keep the changelog"; $0.run = "2026-11-24-1" }
        XCTAssertNil(m.error, m.error?.message ?? "")
        let a = try XCTUnwrap(m.result).decode(WorkspaceAddendumAdded.self)
        XCTAssertEqual(a.kind, "WorkspaceAddendum")
        XCTAssertEqual(a.addendum.text, "Keep the changelog")
        XCTAssertEqual(a.revision, 2)
        XCTAssertEqual(a.addenda, 1)
        XCTAssertTrue(try core.store("room1").openAsks().isEmpty, "no Ask")
        XCTAssertTrue(try WorkspaceStore(store: DozableStore(root: URL(fileURLWithPath: dir + "/store"))).log("demo").contains { $0.action == "addendum-added" && $0.bytes == 18 })
    }

    func testWithNoChatTheProposalIsMadeAndSaysHowToDecideIt() async throws {
        let c = try await host(nil)
        let p = try proposal(await send(c, .workspaceRetro) { $0.addendum = "Lint first" })
        XCTAssertNil(p.askId)
        XCTAssertTrue(p.notes?.first?.contains("doz workspace decide demo \(p.id) apply|decline") == true, p.notes?.joined() ?? "")
    }

    // MARK: x-dozable.permissions

    func spaceFile(_ permissions: String) throws -> String {
        let folder = dir + "/app"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let path = folder + "/app.space.yaml"
        try """
            doz: space/3.1
            space: app
            owner: ada
            x-dozable: {lifetime: standing, permissions: \(permissions)}
            brief: {text: Fix the build}
            folders:
              app: {external: \(folder), access: rw, main: true}
            agents:
              helper: {kind: claude-code, role: worker, isolation: fenced, folder: app}
            chat: {rooms: {team: {members: [owner, helper]}}}
            """.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    func testAWorkspacesOwnPermissionsAreRequestsAndAnUnknownNameIsRefused() throws {
        let r = SpaceResolver().resolve(try spaceFile("{helper: [reviewer, description.decide]}"))
        let (problems, model) = r.check(profiles: [])
        XCTAssertFalse(problems.contains(where: \.isError), "\(problems.map(\.text))")
        let i = SpaceIntent.compile(try XCTUnwrap(model), r.filled, r.locator)
        let req = try XCTUnwrap(i.requests.first { $0.agent == "helper" })
        XCTAssertEqual(req.role, "reviewer")
        XCTAssertEqual(req.grants, ["description.decide"])
        let bad = SpaceResolver().resolve(try spaceFile("{helper: [reviewer, description.rewrite]}"))
        let errors = bad.check(profiles: []).problems.filter(\.isError)
        XCTAssertTrue(errors.contains { $0.text.contains("description.rewrite") && $0.text.contains("description.decide") }, "\(errors.map(\.text))")
    }
}
