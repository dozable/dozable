import DozableChat
@testable import DozableHost
import Foundation
import XCTest

/// 771: agents keep the journal themselves — the chat server's relay (`agent-relay`): who a participant is (a manager by its
/// bot, a worker by its name, an adopted agent only by the participant made at its adoption; a stranger refused), each route
/// made into the operation `--as W/NAME` would send, the SAME gate per kind (journal.read on, journal.write:KIND,
/// evidence.attach, description.propose/decide/edit off until granted, the reviewer role), the trust check (only the chat
/// server's pid), the HTTP status dozchat's table reads, an attach mapped from the place's view, a journal wait, the run's
/// opening message (brief, lessons, goal) and CHAT_URL from the store's port in a workspace's place. Scratch folders only.
final class AgentRelayTests: XCTestCase {
    var dir = ""
    var storeRoot: String { dir + "/store" }
    var store: DozableStore { DozableStore(root: URL(fileURLWithPath: storeRoot)) }
    var project: String { dir + "/project" }

    override func setUpWithError() throws {
        dir = WorkspaceStore.resolved("/tmp") + "/doz-relay-\(getpid())-\(UUID().uuidString.prefix(6))"
        try FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(atPath: dir) }

    // MARK: pure

    func record(_ name: String, agents: [WorkspaceAgent], archived: Bool = false) -> WorkspaceRecord {
        var r = WorkspaceRecord(name: name, createdAt: Date(), brief: WorkspaceBrief(sha256: "", bytes: 0, updatedAt: Date()), folders: [], rooms: [])
        r.agents = agents
        if archived { r.flags.archivedAt = Date() }
        return r
    }

    func worker(_ n: String, ended: Bool = false) -> WorkspaceAgent {
        var a = WorkspaceAgent(name: n, place: .macSession("w-" + n), startedAt: Date())
        a.task = "work"
        if ended { a.endedAt = Date() }
        return a
    }

    func testTheParticipantIsMappedToTheIdentityItIsAndAStrangerIsRefused() throws {
        let manager = WorkspaceAgent(name: "mira", role: "manager", place: .macSession("app"), startedAt: Date(), bot: "mira")
        var adopted = WorkspaceAgent(name: "box", place: .sandbox("box"), startedAt: Date())
        let recs = [record("app", agents: [manager, worker("helper"), adopted, worker("gone", ended: true)])]
        XCTAssertTrue(try AgentRelay.identity(participant: "mira", workspace: nil, records: recs) == ("app", "mira"), "a manager by its bot")
        XCTAssertTrue(try AgentRelay.identity(participant: "helper", workspace: nil, records: recs) == ("app", "helper"), "a worker by its name")
        func refused(_ p: String, _ w: String? = nil, _ rs: [WorkspaceRecord]) -> HostError.Code? {
            do { _ = try AgentRelay.identity(participant: p, workspace: w, records: rs); return nil } catch { return HostError.from(error).code }
        }
        XCTAssertEqual(refused("box", nil, recs), .notPermitted, "an adopted agent with no participant of its own is no one's name")
        XCTAssertEqual(refused("gone", nil, recs), .notPermitted, "an ended worker is no identity")
        XCTAssertEqual(refused("stranger", nil, recs), .notPermitted, "a stranger")
        XCTAssertEqual(refused("helper", "other", recs), .notPermitted, "the workspace named narrows it")
        adopted.participant = "box"
        let withBox = [record("app", agents: [manager, worker("helper"), adopted])]
        XCTAssertTrue(try AgentRelay.identity(participant: "box", workspace: nil, records: withBox) == ("app", "box"), "adopted, by its participant")
        // A bot that is an agent of two live workspaces: name one (65); one of them archived: the live one.
        let two = [record("app", agents: [manager]), record("b", agents: [WorkspaceAgent(name: "mira", role: "manager", place: .macSession("b"), startedAt: Date(), bot: "mira")])]
        XCTAssertEqual(refused("mira", nil, two), .invalidValue)
        XCTAssertTrue(try AgentRelay.identity(participant: "mira", workspace: "b", records: two) == ("b", "mira"))
        let oneArchived = [two[0], record("b", agents: two[1].agents, archived: true)]
        XCTAssertTrue(try AgentRelay.identity(participant: "mira", workspace: nil, records: oneArchived) == ("app", "mira"))
    }

    func testEachRouteIsTheOperationAsTheIdentityWouldSendIt() throws {
        func req(_ route: String, query: [String: String]? = nil, body: JSONValue? = nil, id: String? = nil) throws -> HostRequest {
            let r = AgentRelayRequest(participant: "helper", route: route, query: query, body: body, id: id)
            return try AgentRelay.request(r, workspace: "app", name: "helper", body: try AgentRelay.body(r))
        }
        var r = try req("journal", query: ["run": "2026-11-24-1"])
        XCTAssertEqual(r.op, .workspaceJournal); XCTAssertEqual(r.actAs, "app/helper"); XCTAssertEqual(r.workspaceRequest?.journal?.run, "2026-11-24-1")
        r = try req("journal-add", body: .object(["kind": .string("note"), "text": .string("hi"), "supersedes": .number(2), "attach": .array([.string("/p/a")])]))
        XCTAssertEqual(r.op, .workspaceJournalAdd); XCTAssertEqual(r.workspaceRequest?.journal?.kind, "note")
        XCTAssertEqual(r.workspaceRequest?.journal?.supersedes, 2); XCTAssertEqual(r.workspaceRequest?.journal?.attach, ["/p/a"])
        r = try req("journal-wait", query: ["kind": "outcome", "after": "2026-11-24-1#3"])
        XCTAssertEqual(r.op, .workspaceJournal); XCTAssertEqual(r.workspaceRequest?.journal?.kind, "outcome"); XCTAssertEqual(r.workspaceRequest?.journal?.after, "2026-11-24-1#3")
        r = try req("propose", body: .object(["addendum": .string("lint first")]))
        XCTAssertEqual(r.op, .workspaceRetro); XCTAssertEqual(r.workspaceRequest?.addendum, "lint first")
        r = try req("decide", body: .object(["decision": .string("apply")]), id: "pr-0000abcd")
        XCTAssertEqual(r.op, .workspaceDecide); XCTAssertEqual(r.workspaceRequest?.proposal, "pr-0000abcd"); XCTAssertEqual(r.workspaceRequest?.decision, "apply")
        r = try req("addendum", body: .object(["addendum": .string("x"), "run": .string("2026-11-24-1")]))
        XCTAssertEqual(r.op, .workspaceAddendum); XCTAssertEqual(r.workspaceRequest?.run, "2026-11-24-1")
        XCTAssertThrowsError(try req("journal-wait")) { XCTAssertEqual(HostError.from($0).code, .invalidValue, "a wait names its kind") }
        XCTAssertThrowsError(try req("journal-add", body: .object(["by": .string("owner")]))) {
            XCTAssertEqual(HostError.from($0).code, .invalidValue, "no field of another's: never `by`")
        }
        XCTAssertThrowsError(try req("journal-add", body: .string("x")))
        XCTAssertThrowsError(try req("shell"))
        // The relay's own op is Dozable's: never an agent's --as.
        XCTAssertEqual(ActionClasses.classify(HostRequest(.agentRelay)), .dozableOwn)
    }

    func testOnlyTheChatServersPidIsTrustedAndTheStatusKeepsDozchatsTable() {
        XCTAssertTrue(AgentRelayTrust.accepts(peer: 4242, chatServer: 4242))
        XCTAssertFalse(AgentRelayTrust.accepts(peer: 4243, chatServer: 4242))
        XCTAssertFalse(AgentRelayTrust.accepts(peer: 4242, chatServer: nil), "no chat server: nobody")
        XCTAssertFalse(AgentRelayTrust.accepts(peer: nil, chatServer: 4242))
        func status(_ c: HostError.Code) -> Int { AgentRelayAnswer.failure(HostError(c, "x")).httpStatus }
        XCTAssertEqual(status(.notPermitted), 403)
        XCTAssertEqual(status(.proposalDecided), 409)
        XCTAssertEqual(status(.runClosed), 422); XCTAssertEqual(status(.noOpenRun), 422); XCTAssertEqual(status(.invalidValue), 422)
        XCTAssertEqual(status(.timedOut), 408)
        XCTAssertEqual(status(.unavailable), 503)
        XCTAssertEqual(AgentRelayAnswer.success(.null).httpStatus, 200)
    }

    func testAnAttachIsMappedFromWhereThePlaceSeesIt() throws {
        let shares = [(host: "/srv/x/app", guest: "/workspace"), (host: "/srv/x/lib", guest: "/workspace/lib")]
        XCTAssertEqual(try AgentRelay.hostPath("/srv/x/app/a.png", place: .macSession("s"), shares: nil), "/srv/x/app/a.png", "this Mac's own path")
        XCTAssertEqual(try AgentRelay.hostPath("/workspace/shots/a.png", place: .sandbox("b"), shares: shares), "/srv/x/app/shots/a.png")
        XCTAssertEqual(try AgentRelay.hostPath("/workspace/lib/x", place: .sandbox("b"), shares: shares), "/srv/x/lib/x", "the longest match")
        for (p, place, sh) in [("/etc/passwd", AgentPlace.sandbox("b"), shares), ("/workspace/a", .sandbox("b"), []), ("rel/a", .macSession("s"), nil),
                               ("/workspace/../etc", .sandbox("b"), shares)] as [(String, AgentPlace, [(host: String, guest: String)]?)] {
            XCTAssertThrowsError(try AgentRelay.hostPath(p, place: place, shares: sh), p) { XCTAssertEqual(HostError.from($0).code, .invalidValue) }
        }
    }

    // MARK: the daemon end to end

    func makeWorkspace() throws {
        var rec = WorkspaceRecord(name: "demo", createdAt: Date(), brief: WorkspaceBrief(sha256: "", bytes: 0, updatedAt: Date()),
                                  folders: [WorkspaceFolder(path: project, main: true)],
                                  rooms: [WorkspaceRoom(label: "demo", chatRoom: "room1", main: true, owned: true)])
        rec.agents = [WorkspaceAgent(name: "mira", role: "manager", place: .macSession("demo"), startedAt: Date(), bot: "mira"), worker("helper")]
        var run = WorkspaceRun(id: "2026-11-24-1", startedAt: Date(timeIntervalSinceNow: -60))
        run.rooms = [WorkspaceRunRoom(room: "room1", fromSeq: 10)]
        rec.runs = [run]
        try WorkspaceStore(store: store).create(rec, brief: Data("Fix the build\n".utf8), log: [WorkspaceLogEntry(action: "created")])
    }

    func grant(_ g: Grant) throws {
        var f = GrantStore(store: store).readOrEmpty()
        f.grants.append(g)
        try GrantStore(store: store).write(f)
    }

    func testTheRelayDecidesWithTheSameGrantsAndTheEntryIsTheAgentsOwn() async throws {
        try makeWorkspace()
        let c = HostCore(store: store, readOnly: false, version: "test")
        func call(_ who: String, _ route: String, query: [String: String]? = nil, body: [String: JSONValue]? = nil, id: String? = nil) async -> AgentRelayAnswer {
            await c.agentRelay(AgentRelayRequest(participant: who, route: route, query: query, body: body.map { .object($0) }, id: id))
        }
        // Nothing granted: a note is refused (journal.write:note), nothing written; reading is on by default.
        var a = await call("helper", "journal-add", body: ["kind": .string("note"), "text": .string("hi")])
        XCTAssertEqual(a.error?.code, "not-permitted"); XCTAssertEqual(a.error?.permission, "journal.write:note"); XCTAssertEqual(a.httpStatus, 403)
        a = await call("helper", "journal")
        XCTAssertTrue(a.ok, a.error?.message ?? "")
        XCTAssertEqual(try a.result?.decode(WorkspaceJournal.self).entries.count, 0)
        // A stranger is no identity (9), the owner never comes this way.
        a = await call("stranger", "journal")
        XCTAssertEqual(a.error?.code, "not-permitted")
        a = await call("owner", "journal")
        XCTAssertEqual(a.error?.code, "not-permitted")
        // A note granted by kind: written, `by` the identity — never the request's.
        try grant(Grant(subject: .agent("demo", "helper"), perm: "journal.write:note", answer: .allow, scope: .workspace("demo"), at: Date()))
        a = await call("helper", "journal-add", body: ["kind": .string("note"), "text": .string("hi")])
        XCTAssertTrue(a.ok, a.error?.message ?? "")
        XCTAssertEqual(try a.result?.decode(JournalEntry.self).by, "helper")
        // That kind only; attaching needs evidence.attach.
        a = await call("helper", "journal-add", body: ["kind": .string("review")])
        XCTAssertEqual(a.error?.permission, "journal.write:review")
        try "evidence\n".write(toFile: project + "/n.txt", atomically: true, encoding: .utf8)
        a = await call("helper", "journal-add", body: ["kind": .string("note"), "attach": .array([.string(project + "/n.txt")])])
        XCTAssertEqual(a.error?.permission, "evidence.attach")
        // The reviewer role (the manager, by its bot): write any kind, attach — and a file outside the folders is refused (422).
        try grant(Grant(subject: .agent("demo", "mira"), role: "reviewer", scope: .workspace("demo"), at: Date()))
        a = await call("mira", "journal-add", body: ["kind": .string("review"), "attach": .array([.string(project + "/n.txt")])])
        XCTAssertTrue(a.ok, a.error?.message ?? "")
        XCTAssertEqual(try a.result?.decode(JournalEntry.self).evidence?.count, 1)
        a = await call("mira", "journal-add", body: ["kind": .string("note"), "attach": .array([.string(dir + "/elsewhere.txt")])])
        XCTAssertEqual(a.httpStatus, 422)
        // A wait: a timeout when none, at once when there is one.
        a = await call("helper", "journal-wait", query: ["kind": "outcome", "timeout": "0"])
        XCTAssertEqual(a.error?.code, "timed-out"); XCTAssertEqual(a.httpStatus, 408)
        a = await call("mira", "journal-wait", query: ["kind": "review", "timeout": "5"])
        XCTAssertEqual(try a.result?.decode(JournalEntry.self).kind, "review")
        // The work description: propose needs description.propose (the reviewer has it), decide and edit their own.
        a = await call("helper", "propose", body: ["addendum": .string("lint first")])
        XCTAssertEqual(a.error?.permission, "description.propose")
        a = await call("mira", "propose", body: ["addendum": .string("lint first")])
        XCTAssertTrue(a.ok, a.error?.message ?? "")
        let p = try XCTUnwrap(a.result?.decode(WorkspaceProposal.self))
        XCTAssertEqual(p.by, "mira")
        a = await call("mira", "decide", body: ["decision": .string("apply")], id: p.id)
        XCTAssertEqual(a.error?.permission, "description.decide")
        try grant(Grant(subject: .agent("demo", "mira"), perm: "description.decide", answer: .allow, scope: .workspace("demo"), at: Date()))
        a = await call("mira", "decide", body: ["decision": .string("apply")], id: p.id)
        XCTAssertTrue(a.ok, a.error?.message ?? "")
        a = await call("mira", "decide", body: ["decision": .string("apply")], id: p.id)
        XCTAssertEqual(a.error?.code, "proposal-decided"); XCTAssertEqual(a.httpStatus, 409)
        a = await call("mira", "addendum", body: ["addendum": .string("keep the changelog")])
        XCTAssertEqual(a.error?.permission, "description.edit")
        let rec = try XCTUnwrap(WorkspaceStore(store: store).read("demo"))
        XCTAssertEqual(rec.addenda.map(\.text), ["lint first"])
        XCTAssertEqual(rec.addenda.first?.by, "mira")
    }

    // MARK: the opening message, CHAT_URL

    func testEveryRunOpensWithTheBriefThenTheLessonsThenItsGoal() {
        let lessons = [WorkspaceAddendum(run: "2026-11-24-1", at: Date(), by: "mira", text: "Run the linter before the tests")]
        let withGoal = WorkDescription.openingMessage(brief: "Fix the build\n", refs: ["https://x.example/1"], addenda: lessons, goal: "Ship the release")
        XCTAssertEqual(withGoal, "Fix the build\n\nReferences:\n- https://x.example/1\n\nLessons to apply:\n- Run the linter before the tests (from run 2026-11-24-1)\n\nThis run's goal: Ship the release")
        let noGoal = WorkDescription.openingMessage(brief: "Fix the build", refs: [], addenda: lessons, goal: nil)
        XCTAssertEqual(noGoal, "Fix the build\n\nLessons to apply:\n- Run the linter before the tests (from run 2026-11-24-1)")
        XCTAssertEqual(WorkDescription.openingMessage(brief: "Fix the build", refs: [], addenda: [], goal: "Go"), "Fix the build\n\nThis run's goal: Go",
                       "no lessons: no heading")
    }

    func testASessionInAWorkspacesPlaceGetsTheStoresOwnChatAddress() {
        XCTAssertEqual(AgentLaunch.workspacePlaceEnvironment(member: true, chatOn: true, isolation: .vm, pagePort: 41000, asked: nil),
                       ["CHAT_URL": "http://host.dozable.internal:41000"], "an adopted sandbox: the store's port, never 8790")
        XCTAssertEqual(AgentLaunch.workspacePlaceEnvironment(member: true, chatOn: true, isolation: .fenced, pagePort: 41000, asked: [:]),
                       ["CHAT_URL": "http://host.dozable.internal:41000"])
        XCTAssertEqual(AgentLaunch.workspacePlaceEnvironment(member: true, chatOn: true, isolation: .unfenced, pagePort: 8790, asked: nil),
                       ["CHAT_URL": "http://127.0.0.1:8790"], "the default port is said too: never left to dozchat's guess")
        XCTAssertNil(AgentLaunch.workspacePlaceEnvironment(member: false, chatOn: true, isolation: .vm, pagePort: 41000, asked: nil), "not a workspace's")
        XCTAssertNil(AgentLaunch.workspacePlaceEnvironment(member: true, chatOn: false, isolation: .vm, pagePort: 41000, asked: nil), "chat off")
        XCTAssertNil(AgentLaunch.workspacePlaceEnvironment(member: true, chatOn: true, isolation: .vm, pagePort: 41000, asked: ["CHAT_URL": "http://x:1"]),
                     "the session's own wins")
    }

    // MARK: the chat server's routes

    func testTheAgentRoutesAuthenticateTheTokenAndRelayTheParticipant() async throws {
        let config = """
            {"line_port": 0, "http_port": 0, "data_dir": "\(dir)/data", "default_room": "room1", "participants": [{"name": "you", "kind": "human", "deliver": "web"},
             {"name": "helper", "kind": "agent"}], "rooms": {"room1": ["you", "helper"]}, "allow": ["127.0.0.1"], "require_tokens": true,
             "agent_addresses": ["127.0.0.0/8"], "secrets_file_only": true, "bind": "127.0.0.1"}
            """
        var secrets = ChatSecrets()
        secrets.setTokenHashes(["helper": ChatSecrets.hash("tok-helper-0123456789"), "you": ChatSecrets.hash("tok-human-0123456789")])
        let core = ChatServerCore(config: try ChatConfig.resolve(data: Data(config.utf8), .init()), secrets: secrets, release: "1", sessionsDir: dir + "/none")
        core.load()
        func get(_ target: String, _ token: String, method: String = "GET", body: String = "") -> ChatHTTPResponse {
            ChatPageHandler(core: core).handle(ChatHTTPRequest(method: method, target: target, headers: ["authorization": "Bearer " + token],
                                                               body: Array(body.utf8), remoteIP: "127.0.0.1"))
        }
        XCTAssertEqual(get("/agent/journal", "nope-0123456789abcdef").status, 401)
        XCTAssertEqual(get("/agent/journal", "tok-helper-0123456789").status, 501, "no relay: Dozable's own")
        XCTAssertEqual(get("/agent/journal", "tok-human-0123456789").status, 403, "the human's token is not an agent's")
        let seen = RelaySeen()
        core.agentRelay = { call in seen.call = call; return .jsonError(200, "ok") }
        let res = get("/agent/proposals/pr-0000abcd/decide?workspace=demo&evil=1", "tok-helper-0123456789", method: "POST", body: "{\"decision\":\"apply\"}")
        let pending = try XCTUnwrap(res.relay)
        _ = await pending.finish()
        XCTAssertEqual(seen.call, ChatAgentRelayCall(participant: "helper", route: "decide", query: ["workspace": "demo"],
                                                     body: Array("{\"decision\":\"apply\"}".utf8), id: "pr-0000abcd"),
                       "the participant is the token's; only the known query is passed")
    }
}

private final class RelaySeen: @unchecked Sendable { var call: ChatAgentRelayCall? }
