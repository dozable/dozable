import Foundation
import XCTest
@testable import DozableHost

/// The ONE gate at the daemon's door (`PermissionGate`): the owner is never gated — every HostOp, with every ceiling and an
/// everywhere never on every permission, passes as the owner before anything is read — and an agent caller gets allow, ask
/// ("Asks come later") or never, each logged; another workspace is never; `actAs` only narrows. Scratch roots only.
final class PermissionGateTests: XCTestCase {
    private var root: URL!
    private var store: DozableStore!
    let at = Date(timeIntervalSince1970: 1_900_000_000)

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: "/tmp/doz-gate-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = DozableStore(root: root)
        var rec = WorkspaceRecord(name: "demo", createdAt: at, brief: WorkspaceBrief(refs: [], sha256: "ab", bytes: 2, updatedAt: at), folders: [])
        rec.agents = [WorkspaceAgent(name: "mira", role: "manager", place: .macSession("demo"), startedAt: at, bot: "mira"),
                      WorkspaceAgent(name: "bot1", role: "worker", place: .macSession("demo-bot1"), startedAt: at)]
        let ws = WorkspaceStore(store: store)
        try ws.create(rec, brief: Data("x".utf8), log: [])
        try ws.create(WorkspaceRecord(name: "other", createdAt: at, brief: WorkspaceBrief(refs: [], sha256: "ab", bytes: 2, updatedAt: at), folders: []),
                      brief: Data("x".utf8), log: [])
        try BotStore(store: store).write(BotsFile(bots: [BotRecord(name: "mira", createdAt: at, agent: "claude-code", isolation: BotIsolation(default: "fenced"),
                                                                   kind: "claude-session", token: BotTokenState(keeper: "dozable", fingerprint: nil, at: at))]))
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    /// Every ceiling at never and an everywhere never for every permission, every role and the bot.
    private func neverEverything() throws {
        let all = Dictionary(uniqueKeysWithValues: GrantPermissions.ids.map { ($0, "never") })
        var grants: [Grant] = []
        for p in GrantPermissions.ids {
            for s in [GrantSubject.role("manager"), .role("worker"), .role("member"), .bot("mira"), .agent("demo", "bot1")] {
                grants.append(Grant(subject: s, perm: p, answer: .never, scope: .everywhere, at: at))
            }
        }
        try GrantStore(store: store).write(GrantsFile(grants: grants, ceiling: all))
        let ws = WorkspaceStore(store: store)
        var rec = try XCTUnwrap(try ws.read("demo"))
        rec.permissions = WorkspaceGrants(ceiling: all)
        try ws.write(rec)
        var bots = try BotStore(store: store).read()
        bots.bots[0].ceilingAnswers = all
        try BotStore(store: store).write(bots)
    }

    /// Each HostOp in several shapes: bare, naming the workspace (as each family names it), a sandbox, a session on this Mac.
    private func shapes(_ op: HostOp) -> [HostRequest] {
        var named = HostRequest(op, name: "box")
        named.workspaceRequest = WorkspaceRequest(name: "demo")
        named.workerRequest = WorkerRequest(workspace: "demo")
        named.permissionsRequest = PermissionsRequest(workspace: "demo")
        named.chatRoom = ChatRoomRequest(room: "demo")
        var mac = HostRequest(op, name: MacPlace.name)
        mac.session = "demo-bot1"
        var unfenced = named
        unfenced.workerRequest?.isolation = "unfenced"
        unfenced.workspaceRequest?.managerIsolation = "unfenced"
        return [HostRequest(op), named, mac, unfenced]
    }

    /// THE property: the owner is never gated — not by a ceiling, not by their own never, on no HostOp — and nothing is read
    /// to decide it (the reader is never asked), nothing logged.
    func testTheOwnerIsNeverGated() throws {
        try neverEverything()
        let logBefore = GrantStore(store: store).log()
        var checked = 0
        for op in HostOp.allCases {
            for r in shapes(op) {
                XCTAssertEqual(try Caller.of(r), .owner, op.rawValue)
                XCTAssertEqual(PermissionGate.check(r, caller: .owner, reader: {
                    XCTFail("\(op.rawValue): the owner's request read the grants")
                    return GrantFactsReader(store: self.store)
                }), .pass, op.rawValue)
                XCTAssertNil(PermissionGate.refusal(r, store: store), op.rawValue)
                checked += 1
            }
        }
        XCTAssertEqual(checked, HostOp.allCases.count * 4)
        XCTAssertEqual(GrantStore(store: store).log(), logBefore, "no decision is logged for the owner")
        // …while the same nevers do bind an agent.
        var r = HostRequest(.workspaceShow)
        r.workspaceRequest = WorkspaceRequest(name: "demo")
        r.actAs = "demo/bot1"
        XCTAssertEqual(PermissionGate.refusal(r, store: store)?.code, .notPermitted)
    }

    private func asAgent(_ op: HostOp, _ who: String = "demo/bot1", configure: (inout HostRequest) -> Void = { _ in }) -> HostRequest {
        var r = HostRequest(op)
        r.workspaceRequest = WorkspaceRequest(name: "demo")
        r.workerRequest = WorkerRequest(workspace: "demo")
        r.actAs = who
        configure(&r)
        return r
    }

    func testAnAgentGetsAllowAskOrNever() throws {
        // allow: a worker reads its workspace.
        XCTAssertNil(PermissionGate.refusal(asAgent(.workspaceShow), store: store))
        // ask: a worker adding a worker — refused for now, saying so.
        let ask = PermissionGate.refusal(asAgent(.workerAdd), store: store)
        XCTAssertEqual(ask?.code, .notPermitted)
        XCTAssertEqual(ask?.message, "worker.start for bot1 in demo would ask; Asks come later. See: doz why bot1 worker.start --in demo")
        // allow for the manager.
        XCTAssertNil(PermissionGate.refusal(asAgent(.workerAdd, "demo/mira"), store: store))
        // never, with its reason: unfenced, by the role; Dozable's own.
        let unfenced = PermissionGate.refusal(asAgent(.workerAdd, "demo/mira") { $0.workerRequest?.isolation = "unfenced" }, store: store)
        XCTAssertTrue(unfenced?.message.hasPrefix("isolation.unfenced for mira in demo is never: ") == true, unfenced?.message ?? "")
        let own = PermissionGate.refusal(asAgent(.exec, "demo/mira"), store: store)
        XCTAssertEqual(own?.message, "exec is Dozable's own: never for an agent (mira in demo)")
        // Every decision is logged, the allows too.
        let log = GrantStore(store: store).log().filter { $0.action == "permission-decided" }
        XCTAssertEqual(log.map(\.answer), ["allow", "ask", "allow", "never", "never"])
        XCTAssertEqual(log[1].reason, "refused: Asks come later")
        XCTAssertEqual(log[1].op, "worker-add")
        XCTAssertEqual(((try? WorkspaceStore(store: store).log("demo")) ?? []).filter { $0.action == "permission-decided" }.count, 5)
    }

    /// A role in chat (decider) is the owner's alone to give: an agent's chat-set carrying roles is refused whatever it
    /// holds, even with every grant there is; the owner's passes; the directory's deciders are the facts' deciders.
    func testOnlyTheOwnerGivesTheDeciderRole() throws {
        try GrantStore(store: store).write(GrantsFile(grants: GrantPermissions.ids.filter { !GrantPermissions.ownerOnly.contains($0) }.map {
            Grant(subject: .agent("demo", "mira"), perm: $0, answer: .allow, scope: .everywhere, at: at)
        }))
        let role = asAgent(.chatSet, "demo/mira") { $0.chat = ChatRequest(name: "bot1", roles: ["decider"]) }
        let e = PermissionGate.refusal(role, store: store)
        XCTAssertEqual(e?.code, .notPermitted)
        XCTAssertTrue(e?.message.hasPrefix("only the owner gives a role in chat (chat.decide)") == true, e?.message ?? "")
        XCTAssertNil(PermissionGate.refusal(asAgent(.chatSet, "demo/mira") { $0.chat = ChatRequest(name: "bot1", deliver: "poll") }, store: store),
                     "without a role, chat-set is room.manage as before")
        var owner = HostRequest(.chatSet)
        owner.chat = ChatRequest(name: "bot1", roles: ["decider"])
        XCTAssertNil(PermissionGate.refusal(owner, store: store))
        let paths = ChatPaths(store: store)
        try FileManager.default.createDirectory(atPath: paths.folder, withIntermediateDirectories: true)
        try paths.write("directory.json", ChatDirectory(human: "ada", participants: [.init(name: "bot1", added: "x", roles: ["decider"]),
                                                                                    .init(name: "bot2", added: "x")]).bytes())
        XCTAssertEqual(GrantFactsReader(store: store).facts(GrantWho(name: "mira", home: "demo", bot: "mira"), workspace: "demo").deciders, ["bot1"])
    }

    func testAnotherWorkspaceIsNever() throws {
        let r = asAgent(.workspaceShow) { $0.workspaceRequest = WorkspaceRequest(name: "other") }
        let e = PermissionGate.refusal(r, store: store)
        XCTAssertEqual(e?.code, .notPermitted)
        XCTAssertTrue(e?.message.contains("Dozable's own: another workspace") == true, e?.message ?? "")
        // …unless an everywhere grant reaches it.
        try GrantStore(store: store).write(GrantsFile(grants: [Grant(subject: .agent("demo", "bot1"), perm: "workspace.read", answer: .allow, scope: .everywhere)]))
        XCTAssertNil(PermissionGate.refusal(r, store: store))
    }

    /// `actAs` only narrows: what the owner may do, the agent may not; a narrowing that does not parse is refused, never the
    /// owner's.
    func testActAsOnlyNarrows() {
        var r = HostRequest(.botNew)
        XCTAssertNil(PermissionGate.refusal(r, store: store), "the owner makes a bot")
        r.actAs = "demo/mira"
        XCTAssertEqual(PermissionGate.refusal(r, store: store)?.code, .notPermitted, "the manager may not")
        for bad in ["demo", "/mira", "Demo/mira", "demo/", "demo/a b"] {
            r.actAs = bad
            XCTAssertEqual(PermissionGate.refusal(r, store: store)?.code, .invalid, bad)
        }
        XCTAssertEqual(try Caller.of(asAgent(.ping)), .agent(workspace: "demo", name: "bot1"))
    }
}
