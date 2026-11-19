import Foundation
import XCTest
import DozableKit
import DozableHost
@testable import DozableWeb

/// The dashboard's workspace and Agents / Bots reads: each route is exactly one read-only HostOp the CLI also sends, the
/// answers are projections (never the brief's text, no secret-shaped field), and a name off the rule is refused before any
/// call. (The HTTP side: `WebHTTPIntegrationTests.testTheWorkspaceReads`; what another computer sees: `ServeExposureTests`.)
final class WebWorkspacesTests: XCTestCase {
    func testEveryReadRouteIsExactlyOneReadOnlyHostOp() throws {
        let want: [(WebRoute, HostOp, String)] = [
            (.workspaces, .workspaceList, "doz workspace ls"),
            (.workspace("demo"), .workspaceShow, "doz workspace show demo"),
            (.loose, .workspaceList, "doz workspace ls --loose"),
            (.bots, .botList, "doz bot ls"),
        ]
        for (route, op, cli) in want {
            let r = try XCTUnwrap(WebWorkspaceReads.request(for: route), cli)
            XCTAssertEqual(r.op, op, cli)
            XCTAssertTrue(r.op.isReadOnly, "\(cli): answered in-process with no daemon — looking never starts one")
            XCTAssertEqual(r.v, HostProtocol.version)
            XCTAssertNil(r.secret)
            XCTAssertNil(r.name, "the workspace travels in its own request, as the CLI sends it")
        }
        // Exactly the CLI's requests (WorkspaceCommands / BotCommands build the same).
        var cliShow = HostRequest(.workspaceShow)
        cliShow.workspaceRequest = WorkspaceRequest(name: "demo")
        XCTAssertEqual(WebWorkspaceReads.request(for: .workspace("demo")), cliShow)
        var looseReq = WorkspaceRequest()
        looseReq.loose = true
        var cliLoose = HostRequest(.workspaceList)
        cliLoose.workspaceRequest = looseReq
        XCTAssertEqual(WebWorkspaceReads.request(for: .loose), cliLoose)
        var cliLs = HostRequest(.workspaceList)
        cliLs.workspaceRequest = WorkspaceRequest()
        XCTAssertEqual(WebWorkspaceReads.request(for: .workspaces), cliLs)
        var cliBots = HostRequest(.botList)
        cliBots.botRequest = BotRequest()
        XCTAssertEqual(WebWorkspaceReads.request(for: .bots), cliBots)
        XCTAssertNil(WebWorkspaceReads.request(for: .overview))
    }

    func testTheRoutesParse() {
        XCTAssertEqual(WebRoute.parse(method: .get, target: "/api/v1/workspaces"), .workspaces)
        XCTAssertEqual(WebRoute.parse(method: .get, target: "/api/v1/workspaces/launch-video"), .workspace("launch-video"))
        XCTAssertEqual(WebRoute.parse(method: .get, target: "/api/v1/loose"), .loose)
        XCTAssertEqual(WebRoute.parse(method: .get, target: "/api/v1/bots"), .bots)
        for bad in ["/api/v1/workspaces/", "/api/v1/workspaces/a/b", "/api/v1/workspaces/..", "/api/v1/workspaces/a%2fb", "/api/v1/bots/mira"] {
            XCTAssertNil(WebRoute.parse(method: .get, target: bad), bad)
        }
        for p in ["/api/v1/workspaces", "/api/v1/workspaces/demo", "/api/v1/loose", "/api/v1/bots"] {
            XCTAssertNil(WebRoute.parse(method: .post, target: p), "\(p): reads only")
        }
    }

    func testANameOffTheRuleIsRefusedWithoutEchoingIt() {
        XCTAssertNoThrow(try WebWorkspaceReads.checkName("launch-video"))
        for bad in ["", "Demo", "-x", "a_b", "a.b", String(repeating: "a", count: 41), "<script>"] {
            XCTAssertThrowsError(try WebWorkspaceReads.checkName(bad), bad) { e in
                let m = (e as? WebAction.Invalid)?.message ?? ""
                XCTAssertFalse(bad.count > 1 && m.contains(bad), "never echoed")
            }
        }
    }

    func testTheProjections() throws {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        var row = WorkspaceRow(name: "launch-video", state: "waiting-on-you", driver: "you", agents: 3, room: "launch-video",
                               manager: WorkspaceManagerRow(bot: "otto", isolation: "unfenced", actsAsYou: true, state: "running"),
                               working: ["cutter"], folders: ["/Users/x/video", "/Users/x/assets"])
        let p = WebWorkspaceRow(row)
        XCTAssertEqual(p.words, "waiting on you")
        XCTAssertEqual(p.manager?.words, "otto (unfenced · acts as you)")
        XCTAssertEqual(p.working, ["cutter"])
        XCTAssertEqual(p.folders, ["/Users/x/video", "/Users/x/assets"])
        row.folders = nil
        row.working = nil
        XCTAssertEqual(WebWorkspaceRow(row).folders, [], "no folder")
        XCTAssertNil(WebWorkspaceRow(row).working, "not known (no daemon)")

        let loose = WebLooseAgent(LooseAgent(name: "@mac/build", kind: "mac", state: "running"))
        XCTAssertEqual(loose.macSession, "build")
        XCTAssertNil(WebLooseAgent(LooseAgent(name: "lab", kind: "sandbox", state: "off")).macSession)

        let d = WebWorkspaceDetail(WorkspaceDetail(
            name: "demo", state: "setting-up", driver: "you", createdAt: t,
            brief: WorkspaceBrief(refs: ["/Users/x/notes.md"], sha256: "abc", bytes: 42, updatedAt: t), briefText: "SECRET BRIEF TEXT",
            folders: [WorkspaceFolder(path: "/Users/x/video", main: true)],
            rooms: [WorkspaceRoom(label: "demo", chatRoom: "demo", main: true), WorkspaceRoom(label: "review", chatRoom: "demo-review", main: false)],
            agents: [WorkspaceAgentRow(name: "wsa", role: "worker", place: "wsa", state: "running", startedAt: t, activity: "working"),
                     WorkspaceAgentRow(name: "wsu", role: "worker", place: "@mac/wsu", state: "ended", startedAt: t),
                     WorkspaceAgentRow(name: "mira", role: "manager", place: "elsewhere", state: "elsewhere", startedAt: t, bot: "mira")],
            defaults: WorkspaceDefaults(), flags: WorkspaceFlags(), origin: WorkspaceOrigin(), notes: ["no brief posted yet"]))
        XCTAssertEqual(d.words, "setting up")
        XCTAssertEqual(d.briefBytes, 42)
        XCTAssertEqual(d.refs, 1)
        XCTAssertEqual(d.rooms.map(\.label), ["demo", "review"])
        XCTAssertEqual(d.rooms.map(\.room), ["demo", "demo-review"])
        XCTAssertEqual(d.agents.map(\.kind), ["sandbox", "mac", "elsewhere"])
        XCTAssertEqual(d.agents.map(\.sandbox), ["wsa", nil, nil])
        XCTAssertEqual(d.agents.map(\.session), [nil, "wsu", nil])
        XCTAssertEqual(d.agents[0].activity, "working")
        let json = String(decoding: try WebJSON.encoder.encode(d), as: UTF8.self)
        XCTAssertFalse(json.contains("SECRET BRIEF TEXT"), "never the brief's text")
        XCTAssertFalse(json.contains("abc\""), "never the brief's hash")

        let b = WebBotListing(BotListing(bots: [BotRow(name: "mira", agent: "claude-code", model: "opus", isolation: "fenced", kind: "agent",
                                                       deliver: "poll", inChat: true, manages: ["demo"], running: "demo", retiredAt: nil, worksIn: nil)]))
        XCTAssertEqual(b.bots.map(\.name), ["mira"])
        XCTAssertEqual(b.bots[0].manages, ["demo"])
    }

    func testNoAnswerHasASecretShapedField() throws {
        let t = Date(timeIntervalSince1970: 0)
        let values: [any Encodable] = [
            WebWorkspaceListing(WorkspaceListing(workspaces: [WorkspaceRow(name: "a", state: "idle", driver: "you", agents: 0, room: nil)],
                                                 loose: [LooseAgent(name: "b", kind: "sandbox", state: "off")])),
            WebWorkspaceDetail(WorkspaceDetail(name: "a", state: "idle", driver: "you", createdAt: t, brief: WorkspaceBrief(sha256: "x", bytes: 1, updatedAt: t),
                                               folders: [], rooms: [], agents: [], defaults: WorkspaceDefaults(), flags: WorkspaceFlags(),
                                               origin: WorkspaceOrigin())),
            WebBotListing(BotListing(bots: [BotRow(name: "m", agent: "codex", model: nil, isolation: "vm", kind: "agent", deliver: "inbox", inChat: false,
                                                   manages: [], retiredAt: t)])),
        ]
        for v in values {
            let text = String(decoding: try WebJSON.encoder.encode(v), as: UTF8.self).lowercased()
            for word in ["token", "secret", "password", "key\"", "sha256", "hash"] {
                XCTAssertFalse(text.contains(word), "\(word) in \(text)")
            }
        }
    }
}
