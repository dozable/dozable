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
            (.workspaceBrief("demo"), .workspaceShow, "doz workspace show demo --brief"),
            (.workspaceLog("demo", nil), .workspaceLog, "doz workspace log demo"),
            (.workspaceLog("demo", Date(timeIntervalSince1970: 1_800_000_000.5)), .workspaceLog, "doz workspace log demo --since …"),
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
        // The brief and the log: exactly what `doz workspace show W --brief` and `doz workspace log W --since …` send.
        var brief = WorkspaceRequest(name: "demo")
        brief.withBrief = true
        var cliBrief = HostRequest(.workspaceShow)
        cliBrief.workspaceRequest = brief
        XCTAssertEqual(WebWorkspaceReads.request(for: .workspaceBrief("demo")), cliBrief)
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        var log = WorkspaceRequest(name: "demo")
        log.since = t
        var cliLog = HostRequest(.workspaceLog)
        cliLog.workspaceRequest = log
        XCTAssertEqual(WebWorkspaceReads.request(for: .workspaceLog("demo", t)), cliLog)
    }

    func testTheBriefAndLogRoutesParse() {
        XCTAssertEqual(WebRoute.parse(method: .get, target: "/api/v1/workspaces/demo/brief"), .workspaceBrief("demo"))
        XCTAssertEqual(WebRoute.parse(method: .get, target: "/api/v1/workspaces/demo/log"), .workspaceLog("demo", nil))
        XCTAssertEqual(WebRoute.parse(method: .get, target: "/api/v1/workspaces/demo/log?since=1800000000.25"),
                       .workspaceLog("demo", Date(timeIntervalSince1970: 1_800_000_000.25)))
        for bad in ["/api/v1/workspaces/demo/log?since=", "/api/v1/workspaces/demo/log?since=-1", "/api/v1/workspaces/demo/log?since=1e9",
                    "/api/v1/workspaces/demo/log?since=1&x=2", "/api/v1/workspaces/demo/log?until=1", "/api/v1/workspaces/demo/log?since=1.2.3",
                    "/api/v1/workspaces/demo/brief?x=1", "/api/v1/workspaces/demo/notes", "/api/v1/workspaces/demo/brief/x"] {
            XCTAssertNil(WebRoute.parse(method: .get, target: bad), bad)
        }
        for p in ["/api/v1/workspaces/demo/brief", "/api/v1/workspaces/demo/log"] {
            XCTAssertNil(WebRoute.parse(method: .post, target: p), "\(p): a read only")
        }
    }

    func testTheBriefProjection() throws {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        let sha = String(repeating: "b", count: 64)
        let b = WebWorkspaceBrief(WorkspaceDetail(
            name: "demo", state: "idle", driver: "you", createdAt: t,
            brief: WorkspaceBrief(refs: ["/Users/x/notes.md", "https://example.com"], sha256: sha, bytes: 9, updatedAt: t), briefText: "the brief",
            folders: [WorkspaceFolder(path: "/Users/x/video", main: true)], rooms: [], agents: [], defaults: WorkspaceDefaults(),
            flags: WorkspaceFlags(), origin: WorkspaceOrigin()))
        XCTAssertEqual(b.text, "the brief")
        XCTAssertEqual(b.refs, ["/Users/x/notes.md", "https://example.com"])
        XCTAssertEqual(b.bytes, 9)
        XCTAssertEqual(b.sha256, sha, "what an edit sends back as ifBrief")
        let json = String(decoding: try WebJSON.encoder.encode(b), as: UTF8.self)
        XCTAssertEqual(Set(((try JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any])?.keys ?? [:].keys),
                       ["text", "refs", "bytes", "updatedAt", "sha256"], "field by field: no folder, agent or token")
        for word in ["token", "secret", "password"] { XCTAssertFalse(json.lowercased().contains(word), word) }
    }

    func testTheLogProjection() throws {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        let entries = [
            WorkspaceLogEntry(at: t, action: "created"),
            WorkspaceLogEntry(at: t, action: "kicked-off", room: "demo", sha256: String(repeating: "c", count: 64), bytes: 40),
            WorkspaceLogEntry(at: t, action: "manager-started", agent: "mira", place: "mac:demo", isolation: "fenced", fingerprint: "abcdef123456"),
            WorkspaceLogEntry(at: t, action: "adopted", agent: "wsa", place: "sandbox:wsa"),
            WorkspaceLogEntry(at: t, by: "doz", action: "worker-ended", agent: "bot1"),
        ]
        let l = WebWorkspaceLog(entries, macAllowed: true)
        XCTAssertEqual(l.lines.map(\.text), entries.map(\.sentence), "the CLI's words")
        XCTAssertEqual(l.lines[1].room, "demo")
        XCTAssertEqual(l.lines[4].by, "doz")
        XCTAssertFalse(l.more)
        XCTAssertEqual(l.hidden, 0)
        let json = String(decoding: try WebJSON.encoder.encode(l), as: UTF8.self)
        for word in ["sha256", "fingerprint", "\"place\"", "\"bytes\"", "ccccccc", "abcdef123456", "token", "secret", "password"] {
            XCTAssertFalse(json.contains(word), "\(word) in \(json)")
        }
        // Another computer while serve.mac_sessions is off: the lines about a session on this Mac are left out and counted.
        let remote = WebWorkspaceLog(entries, macAllowed: false)
        XCTAssertEqual(remote.lines.map(\.action), ["created", "kicked-off", "adopted", "worker-ended"])
        XCTAssertEqual(remote.hidden, 1)
        XCTAssertFalse(String(decoding: try WebJSON.encoder.encode(remote), as: UTF8.self).contains("mac:demo"))
        // At most the newest 500.
        let many = (0..<620).map { WorkspaceLogEntry(at: t.addingTimeInterval(Double($0)), action: "refs-edited", added: $0, removed: 0) }
        let capped = WebWorkspaceLog(many, macAllowed: true)
        XCTAssertEqual(capped.lines.count, WebWorkspaceLog.maximumLines)
        XCTAssertTrue(capped.more)
        XCTAssertEqual(capped.lines.first?.at, t.addingTimeInterval(120), "the newest kept")
        XCTAssertEqual(capped.lines.last?.at, t.addingTimeInterval(619))
    }

    func testTheDetailCarriesNetworkStartAndControl() {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        var flags = WorkspaceFlags()
        flags.startedAt = t
        let d = WebWorkspaceDetail(WorkspaceDetail(
            name: "demo", state: "working", driver: "you", createdAt: t, brief: WorkspaceBrief(sha256: "x", bytes: 1, updatedAt: t),
            folders: [], rooms: [],
            agents: [WorkspaceAgentRow(name: "bot1", role: "worker", place: "@mac/demo-bot1", state: "running", startedAt: t, isolation: "fenced",
                                       task: "list", control: "proxy · placeholders · guard")],
            defaults: WorkspaceDefaults(network: "standard"), flags: flags, origin: WorkspaceOrigin()))
        XCTAssertEqual(d.startedAt, t)
        XCTAssertEqual(d.network, "standard")
        XCTAssertEqual(d.agents[0].control, "proxy · placeholders · guard")
    }

    /// The set-up check's gaps reach the page only while it is setting up (`workspace-show`'s), each with the wizard's step;
    /// another computer that may not see this Mac's sessions gets none that names one.
    func testTheGapsWhileSettingUp() {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        func detail(_ state: String, _ gaps: [WorkspaceSetupCheck.Gap]?) -> WebWorkspaceDetail {
            WebWorkspaceDetail(WorkspaceDetail(
                name: "demo", state: state, driver: "you", createdAt: t, brief: WorkspaceBrief(sha256: "x", bytes: 1, updatedAt: t),
                folders: [], rooms: [], agents: [], defaults: WorkspaceDefaults(isolation: "vm"), flags: WorkspaceFlags(), origin: WorkspaceOrigin(), gaps: gaps))
        }
        let gaps = [WorkspaceSetupCheck.Gap(item: "brief", why: "the brief is empty", fix: "doz workspace edit demo --prompt-file F"),
                    WorkspaceSetupCheck.Gap(item: "manager", why: "a session called demo already exists on this Mac", fix: "doz sessions end @mac demo, or rename the workspace"),
                    WorkspaceSetupCheck.Gap(item: "chat", why: "a manager needs chat", fix: "doz chat on")]
        let d = detail("setting-up", gaps)
        XCTAssertEqual(d.gaps?.map(\.step), [1, 2, 4])
        XCTAssertEqual(d.workerIsolation, "vm")
        XCTAssertNil(detail("idle", nil).gaps, "started: no gaps")
        let remote = WebWorkspaceReads.forBrowser(d, macAllowed: false)
        XCTAssertEqual(remote.gaps?.map(\.item), ["brief", "chat"], "a gap naming a session on this Mac is left out")
        XCTAssertEqual(WebWorkspaceReads.forBrowser(d, macAllowed: true).gaps?.count, 3)
    }

    /// The Agents tab's fields: who brought an agent in and when, a shared sandbox's session, and each workspace's places —
    /// which another computer that may not see this Mac's sessions never gets for `@mac/…`.
    func testStartedBySessionAndPlaces() {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        let d = WebWorkspaceDetail(WorkspaceDetail(
            name: "demo", state: "working", driver: "you", createdAt: t, brief: WorkspaceBrief(sha256: "x", bytes: 1, updatedAt: t),
            folders: [], rooms: [],
            agents: [WorkspaceAgentRow(name: "bot1", role: "worker", place: "wsa", state: "running", startedAt: t, task: "list",
                                       startedBy: "doz", session: "bot1"),
                     WorkspaceAgentRow(name: "wsu", role: "worker", place: "@mac/wsu", state: "running", startedAt: t, startedBy: "you"),
                     WorkspaceAgentRow(name: "old", role: "worker", place: "wsb", state: "off", startedAt: t)],
            defaults: WorkspaceDefaults(), flags: WorkspaceFlags(), origin: WorkspaceOrigin()))
        XCTAssertEqual(d.agents.map(\.startedBy), ["doz", "you", nil], "nil from an older daemon")
        XCTAssertEqual(d.agents.map(\.startedAt), [t, t, t])
        XCTAssertEqual(d.agents.map(\.session), ["bot1", "wsu", nil])
        XCTAssertEqual(d.agents.map(\.sandbox), ["wsa", nil, "wsb"])
        let remote = WebWorkspaceReads.forBrowser(d, macAllowed: false)
        XCTAssertEqual(remote.agents.map(\.name), ["bot1", "old"])
        XCTAssertEqual(remote.hidden, 1)

        let l = WebWorkspaceListing(WorkspaceListing(workspaces: [
            WorkspaceRow(name: "demo", state: "working", driver: "you", agents: 3, room: nil, places: ["wsa", "@mac/wsu", "wsb"]),
            WorkspaceRow(name: "empty", state: "setting-up", driver: "you", agents: 0, room: nil),
        ], loose: []))
        XCTAssertEqual(l.workspaces.map(\.places), [["wsa", "@mac/wsu", "wsb"], []])
        XCTAssertEqual(WebWorkspaceReads.forBrowser(l, macAllowed: true).workspaces[0].places, ["wsa", "@mac/wsu", "wsb"])
        let hid = WebWorkspaceReads.forBrowser(l, macAllowed: false)
        XCTAssertEqual(hid.workspaces[0].places, ["wsa", "wsb"], "no session on this Mac is named to such a browser")
        let json = String(decoding: (try? WebJSON.encoder.encode(hid)) ?? Data(), as: UTF8.self)
        XCTAssertFalse(json.contains("wsu"), json)
    }

    func testTheRoutesParse() {
        XCTAssertEqual(WebRoute.parse(method: .get, target: "/api/v1/workspaces"), .workspaces)
        XCTAssertEqual(WebRoute.parse(method: .get, target: "/api/v1/workspaces/launch-video"), .workspace("launch-video"))
        XCTAssertEqual(WebRoute.parse(method: .get, target: "/api/v1/loose"), .loose)
        XCTAssertEqual(WebRoute.parse(method: .get, target: "/api/v1/bots"), .bots)
        for bad in ["/api/v1/workspaces/", "/api/v1/workspaces/a/b", "/api/v1/workspaces/..", "/api/v1/workspaces/a%2fb", "/api/v1/bots/mira/x", "/api/v1/bots?retired=0", "/api/v1/bots/mira?x=1"] {
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
