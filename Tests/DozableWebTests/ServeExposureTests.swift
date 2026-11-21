import Foundation
import XCTest
import DozableHost
@testable import DozableWeb

/// 606 — the remote-capability table (`WebExposure`), pinned: every route, three askers (the Mac's doz ui, a remote
/// browser over plain HTTP, a remote browser over https through a trusted proxy).
final class ServeExposureTests: XCTestCase {
    /// One instance of EVERY route. The switch has no default: a new route does not compile here until it is added
    /// (and so pinned below).
    static let samples: [WebRoute] = {
        let all: [WebRoute] = [
            .index, .asset("/assets/x.js"), .terminalFrame, .offline, .serviceWorker, .chatPage, .sessionBootstrap, .sessionInfo, .sessionRenew, .sessionEnd,
            .overview, .sandbox("s"), .sandboxSessions("s"), .sandboxNetwork("s"), .sandboxTools("s"), .images, .imageTree, .accounts,
            .metrics(WebMetricsQuery.parse(nil)!), .metricsCSV(WebMetricsQuery.parse(nil)!), .events, .doctor, .stream, .actions, .operations, .operationsCancel,
            .policyPreview("s"), .terminal("s"), .terminalTicket("s"), .terminalSocket("s"), .settings, .settingsChange, .sessionScreen("s", "shell"),
            .terminalLayout("s"), .terminalLayoutSet("s"), .bootLogs("s"), .bootLog("s", 1), .buildLog("s"), .onboarding, .onboardingConfig, .preparations,
            .accountAdd, .sandboxKey("s"), .workspaceCheck, .workspaceChoose, .quickAdd, .projectsDirChoose, .projectOpen, .projectPreview,
            .projectWrite, .resources, .resourcesPreview, .bases, .tryCatalog, .tryList, .models("openrouter"), .plan, .dockerfileChoose, .access, .accessCheck, .accessGithubKey, .signup, .updatesCheck, .uiRestart,
            .serveStatus, .serveDevices, .serveShare, .serveRevoke("abc123"), .serveRename("abc123"), .serveProbe,
            .files("s", nil), .filesWatch("s", []), .filesTree("s"), .filesTreeSet("s"), .filesOpen("s"), .editors, .grids, .dotfilesResolve, .portOpen("s"),
            .recipes, .macSessions, .macSessionScreen("agent"), .macTerminalTicket, .macTerminalSocket,
            .macSessionNetwork("agent"), .macSessionTranscripts("agent"), .macSessionTranscript("agent", "20261113T101500Z", "x.jsonl"),
            .macSessionQuarantine("agent"), .macSessionPlan, .workspacePlan, .workerPlan, .workspaceLifecyclePlan, .workspaceReach, .workspaceFolders, .workspaceActivity, .workspaceRuns, .workspaceRunChat, .workspaceSpace, .workspaceSpacePlan, .workspaceState, .workspaceRunFrames, .chatRoomPlan, .chat(.status), .workspaces, .workspace("demo"), .workspaceBrief("demo"),
            .workspaceLog("demo", nil), .loose, .bots, .botsRetired, .bot("mira"), .macs,
        ]
        for r in all { _ = covered(r) }
        return all
    }()

    static func covered(_ r: WebRoute) -> Bool {
        switch r {
        case .index, .asset, .terminalFrame, .offline, .serviceWorker, .chatPage, .sessionBootstrap, .sessionInfo, .sessionRenew, .sessionEnd, .overview,
             .sandbox, .sandboxSessions, .sandboxNetwork, .sandboxTools, .images, .imageTree, .accounts, .metrics, .metricsCSV, .events, .doctor,
             .stream, .actions, .operations, .operationsCancel, .policyPreview, .terminal, .terminalTicket, .terminalSocket, .settings, .settingsChange,
             .sessionScreen, .terminalLayout, .terminalLayoutSet, .bootLogs, .bootLog, .buildLog, .onboarding, .onboardingConfig, .preparations,
             .accountAdd, .sandboxKey, .workspaceCheck, .workspaceChoose, .quickAdd, .projectsDirChoose, .projectOpen, .projectPreview,
             .projectWrite, .resources, .resourcesPreview, .bases, .tryCatalog, .tryList, .models, .plan, .dockerfileChoose, .access, .accessCheck, .accessGithubKey, .signup, .updatesCheck, .uiRestart,
             .serveStatus, .serveDevices, .serveShare, .serveRevoke, .serveRename, .serveProbe, .files, .filesWatch, .filesTree, .filesTreeSet, .filesOpen, .editors, .grids,
             .dotfilesResolve, .portOpen, .recipes, .macSessions, .macSessionScreen, .macTerminalTicket, .macTerminalSocket,
             .macSessionNetwork, .macSessionTranscripts, .macSessionTranscript, .macSessionQuarantine, .macSessionPlan, .workspacePlan, .workerPlan, .workspaceLifecyclePlan, .workspaceReach, .workspaceFolders, .workspaceActivity, .workspaceRuns, .workspaceRunChat, .workspaceSpace, .workspaceSpacePlan, .workspaceState, .workspaceRunFrames, .chatRoomPlan, .chat,
             .workspaces, .workspace, .workspaceBrief, .workspaceLog, .loose, .bots, .botsRetired, .bot, .macs:
            return true
        }
    }

    /// The table (606.02-PLAN.md): route → (doz ui, remote http, remote https). nil = allowed.
    static let pinned: [String: (WebRejection?, WebRejection?, WebRejection?)] = {
        var t: [String: (WebRejection?, WebRejection?, WebRejection?)] = [:]
        for r in samples { t[ServeExposureTests.label(r)] = (nil, nil, nil) }
        for secret in ["accountAdd", "sandboxKey", "accessGithubKey"] { t[secret] = (nil, .secretOverHTTP, nil) }
        for screen in ["terminal", "workspaceChoose", "projectsDirChoose", "dockerfileChoose", "filesOpen", "editors", "portOpen", "macSessionPlan", "workspacePlan", "workerPlan", "workspaceLifecyclePlan", "chatRoomPlan"] { t[screen] = (nil, .macScreen, .macScreen) }
        // A run's archived messages are chat: another computer reads them only with serve.chat read or write.
        t["workspaceRunChat"] = (nil, .chatRemote, .chatRemote)
        t["serveProbe"] = (.notFound, nil, nil)
        t["uiRestart"] = (nil, .macOnly, .macOnly)          // 714: Restart dashboard — this Mac's own browser only
        // The sessions on this Mac: never another computer's by default (serve.mac_sessions = off).
        for mac in ["macSessions", "macSessionScreen", "macTerminalTicket", "macTerminalSocket",
                    "macSessionNetwork", "macSessionTranscripts", "macSessionTranscript", "macSessionQuarantine"] { t[mac] = (nil, .macSession, .macSession) }
        // Chat: this Mac's own browser only unless serve.chat (default off) says otherwise (every chat route and every value of
        // serve.chat — WebChatActRouteTests.testServeChatDecides). Its audit label names the call: chat-status, chat-post, ….
        t["chat-status"] = (nil, .chatRemote, .chatRemote)
        // A workspace's brief follows serve.chat (off by default): what the agents act on.
        t["workspaceBrief"] = (nil, .briefRemote, .briefRemote)
        // A space file and its plan follow serve.chat too (what its agents are set up from); its state is a read.
        t["workspaceSpace"] = (nil, .spaceRemote, .spaceRemote)
        t["workspaceSpacePlan"] = (nil, .spaceRemote, .spaceRemote)
        return t
    }()

    /// serve.mac_sessions: off refuses every route of the sessions on this Mac to another computer; watch lets it list and
    /// watch (a watch ticket) but not type, end or restart; interactive is everything. The Mac's own browser always has them.
    func testTheSessionsOnThisMacFollowTheSetting() {
        let macRoutes: [WebRoute] = [.macSessions, .macSessionScreen("a"), .macTerminalTicket, .macTerminalSocket]
        for r in macRoutes {
            XCTAssertEqual(WebExposure.kind(r), .macSession)
            for setting in WebExposure.MacSessions.allCases { XCTAssertNil(WebExposure.decide(r, .mac, macSessions: setting)) }
            XCTAssertEqual(WebExposure.decide(r, .remote(secure: true), macSessions: .off), .macSession)
            XCTAssertNil(WebExposure.decide(r, .remote(secure: false), macSessions: .watch))
            XCTAssertNil(WebExposure.decide(r, .remote(secure: false), macSessions: .interactive))
        }
        let remote = WebExposure.Principal.remote(secure: true)
        XCTAssertNil(WebExposure.decideMacTerminal(.watch, remote, .watch))
        XCTAssertEqual(WebExposure.decideMacTerminal(.interactive, remote, .watch), .macSession, "watch: no typing")
        XCTAssertEqual(WebExposure.decideMacTerminal(.watch, remote, .off), .macSession)
        XCTAssertNil(WebExposure.decideMacTerminal(.interactive, remote, .interactive))
        XCTAssertNil(WebExposure.decideMacTerminal(.interactive, .mac, .off), "the Mac's own browser")
        XCTAssertEqual(WebExposure.decideMacAction(remote, .watch), .macSession, "watch: no end or restart")
        XCTAssertNil(WebExposure.decideMacAction(remote, .interactive))
        XCTAssertNil(WebExposure.decideMacAction(.mac, .off))
        XCTAssertFalse(WebGridsRequest.macAllowed(remote, .off))
        XCTAssertTrue(WebGridsRequest.macAllowed(remote, .watch))
        XCTAssertTrue(WebGridsRequest.macAllowed(.mac, .off))
        XCTAssertEqual(WebRejection.macSession.status, 403)
        XCTAssertTrue(WebRejection.macSession.message.contains("serve.mac_sessions"))
    }

    /// The workspace reads are reads for every browser; another computer while `serve.mac_sessions` is off gets no row
    /// placed on this Mac — no loose session, no agent on this Mac, no note naming one, not who is working — and is told how
    /// many were left out.
    func testTheWorkspaceReadsLeaveThisMacsRowsOut() {
        for r: WebRoute in [.workspaces, .workspace("demo"), .loose, .bots, .botsRetired, .bot("mira")] {
            XCTAssertEqual(WebExposure.kind(r), .read)
            XCTAssertNil(WebExposure.decide(r, .remote(secure: false), macSessions: .off), "a read: the rows are filtered, not the route")
        }
        var row = WorkspaceRow(name: "demo", state: "working", driver: "you", agents: 2, room: "demo", working: ["build", "wsa"])
        row.folders = ["/Users/x/app"]
        let listing = WebWorkspaceListing(WorkspaceListing(workspaces: [row], loose: [
            LooseAgent(name: "lab", kind: "sandbox", state: "running"), LooseAgent(name: "@mac/secret-project", kind: "mac", state: "running"),
        ]))
        let remote = WebWorkspaceReads.forBrowser(listing, macAllowed: WebGridsRequest.macAllowed(.remote(secure: true), .off))
        XCTAssertEqual(remote.loose.map(\.name), ["lab"])
        XCTAssertEqual(remote.hidden, 1)
        XCTAssertNil(remote.workspaces[0].working)
        let json = String(decoding: try! WebJSON.encoder.encode(remote), as: UTF8.self)
        XCTAssertFalse(json.contains("secret-project") || json.contains("build"), json)
        XCTAssertEqual(WebWorkspaceReads.forBrowser(listing, macAllowed: WebGridsRequest.macAllowed(.remote(secure: true), .watch)), listing)
        XCTAssertEqual(WebWorkspaceReads.forBrowser(listing, macAllowed: WebGridsRequest.macAllowed(.mac, .off)), listing, "the Mac's own browser")

        let t = Date(timeIntervalSince1970: 0)
        let detail = WebWorkspaceDetail(WorkspaceDetail(
            name: "demo", state: "working", driver: "you", createdAt: t, brief: WorkspaceBrief(sha256: "x", bytes: 3, updatedAt: t), briefText: "the brief",
            folders: [], rooms: [WorkspaceRoom(label: "demo", chatRoom: "demo", main: true)],
            agents: [WorkspaceAgentRow(name: "wsa", role: "worker", place: "wsa", state: "running", startedAt: t),
                     WorkspaceAgentRow(name: "secret-project", role: "worker", place: "@mac/secret-project", state: "running", startedAt: t)],
            defaults: WorkspaceDefaults(), flags: WorkspaceFlags(), origin: WorkspaceOrigin(), notes: ["@mac/secret-project ended", "post the brief"]))
        let d = WebWorkspaceReads.forBrowser(detail, macAllowed: false)
        XCTAssertEqual(d.agents.map(\.name), ["wsa"])
        XCTAssertEqual(d.hidden, 1)
        XCTAssertEqual(d.notes, ["post the brief"])
        XCTAssertEqual(WebWorkspaceReads.forBrowser(detail, macAllowed: true), detail)
    }

    /// The brief: a read, refused to another computer only while serve.chat is off; the log: a read for every browser.
    /// A space workspace's routes are payload-less reads (the workspace in the body): the file and its plan follow serve.chat
    /// (read or write) for another computer; the state is a read (this Mac's sessions as serve.mac_sessions allows); saving is
    /// an action, this Mac's own browser's only whatever the settings.
    func testTheSpaceRoutesFollowServeChatAndSavingIsThisMacsOnly() {
        for r: WebRoute in [.workspaceSpace, .workspaceSpacePlan, .workspaceState, .workspaceRunFrames] { XCTAssertEqual(WebExposure.kind(r), .read) }
        for r: WebRoute in [.workspaceSpace, .workspaceSpacePlan] {
            XCTAssertEqual(WebExposure.decide(r, .remote(secure: true), chat: .off), .spaceRemote)
            XCTAssertNil(WebExposure.decide(r, .remote(secure: true), chat: .read))
            XCTAssertNil(WebExposure.decide(r, .remote(secure: false), chat: .write))
            XCTAssertNil(WebExposure.decide(r, .mac, chat: .off), "the Mac's own browser")
        }
        for chat in WebExposure.ChatServe.allCases {
            for ms in WebExposure.MacSessions.allCases {
                XCTAssertNil(WebExposure.decide(.workspaceState, .remote(secure: true), macSessions: ms, chat: chat))
                XCTAssertNil(WebExposure.decide(.workspaceRunFrames, .remote(secure: true), macSessions: ms, chat: chat))
            }
        }
        XCTAssertEqual(WebExposure.decideSpaceAction(.remote(secure: true)), .macOnlySpace)
        XCTAssertNil(WebExposure.decideSpaceAction(.mac))
        XCTAssertEqual(WebRejection.spaceRemote.status, 403)
        XCTAssertTrue(WebRejection.spaceRemote.message.contains("serve.chat"))
        for (path, route) in [("/api/v1/workspace-space", WebRoute.workspaceSpace), ("/api/v1/workspace-space-plan", .workspaceSpacePlan),
                              ("/api/v1/workspace-state", .workspaceState), ("/api/v1/workspace-run-frames", .workspaceRunFrames)] {
            XCTAssertEqual(WebRoute.parse(method: .post, target: path), route, path)
            XCTAssertNil(WebRoute.parse(method: .get, target: path), "\(path): POST only")
            XCTAssertNil(WebRoute.parse(method: .post, target: path + "/demo"), "\(path): never a payload in the address")
        }
    }

    func testTheBriefFollowsServeChat() {
        XCTAssertEqual(WebExposure.kind(.workspaceBrief("demo")), .read)
        XCTAssertEqual(WebExposure.kind(.workspaceLog("demo", nil)), .read)
        XCTAssertEqual(WebExposure.decide(.workspaceBrief("demo"), .remote(secure: true), chat: .off), .briefRemote)
        XCTAssertNil(WebExposure.decide(.workspaceBrief("demo"), .remote(secure: true), chat: .read))
        XCTAssertNil(WebExposure.decide(.workspaceBrief("demo"), .remote(secure: false), chat: .write))
        XCTAssertNil(WebExposure.decide(.workspaceBrief("demo"), .mac, chat: .off), "the Mac's own browser")
        XCTAssertNil(WebExposure.decide(.workspaceLog("demo", nil), .remote(secure: false), macSessions: .off, chat: .off),
                     "the log's lines are filtered, not the route")
        XCTAssertEqual(WebRejection.briefRemote.status, 403)
        XCTAssertTrue(WebRejection.briefRemote.message.contains("serve.chat"))
    }

    /// Filing an agent into a workspace or out of one: this Mac's own browser only — no serve setting opens it to another
    /// computer, which gets the `mac-only` code with filing's own words.
    /// Answering an ask (`chat-decide`) is this Mac's own browser only, whatever `serve.chat` says: a decision is made as you.
    func testAnsweringAnAskIsThisMacsOnly() throws {
        XCTAssertNil(WebExposure.decideAskAction(.mac))
        for p: WebExposure.Principal in [.remote(secure: false), .remote(secure: true)] {
            XCTAssertEqual(WebExposure.decideAskAction(p), .macOnlyAsks, "\(p)")
        }
        XCTAssertEqual(WebRejection.macOnlyAsks.code, "mac-only")
        XCTAssertEqual(WebRejection.macOnlyAsks.status, 403)
        XCTAssertTrue(WebRejection.macOnlyAsks.message.contains("doz chat decide"))
        let a = try WebAction.decode(Data(##"{"action":"chat-decide","room":"r","ask":"#1","reply":"A","actionId":"0b7e2c4a-1111-4222-8333-444455556666"}"##.utf8))
        XCTAssertTrue(a.isAsk)
        XCTAssertFalse(a.isWorkspace || a.isFiling || a.isMacSession, "serve.chat never decides it")
    }

    func testFilingIsThisMacsOnly() {
        XCTAssertNil(WebExposure.decideFilingAction(.mac))
        for p: WebExposure.Principal in [.remote(secure: false), .remote(secure: true)] {
            XCTAssertEqual(WebExposure.decideFilingAction(p), .macOnlyFiling, "\(p)")
        }
        XCTAssertEqual(WebRejection.macOnlyFiling.code, WebRejection.macOnly.code)
        XCTAssertEqual(WebRejection.macOnlyFiling.status, 403)
        XCTAssertNotEqual(WebRejection.macOnlyFiling.message, WebRejection.macOnly.message, "each family says what it is")
        XCTAssertTrue(WebRejection.macOnly.message.contains("doz ui restart"))
        XCTAssertTrue(WebRejection.macOnlyFiling.message.contains("doz workspace adopt"))
        // The brief stays decided by serve.chat; filing never is.
        let adopt = try? WebAction.decode(Data(#"{"action":"workspace-adopt","workspace":"demo","agent":"lab"}"#.utf8))
        XCTAssertEqual(adopt?.isFiling, true)
        XCTAssertEqual(adopt?.isWorkspace, false)
    }

    /// The New workspace wizard: starting is this Mac's own browser only (the `mac-only` code, its own words); its plan
    /// route is `mac-screen` — another computer never gets it, whatever the serve settings.
    func testStartingAndPlanningAreThisMacsOnly() {
        XCTAssertNil(WebExposure.decideStartAction(.mac))
        for p: WebExposure.Principal in [.remote(secure: false), .remote(secure: true)] {
            XCTAssertEqual(WebExposure.decideStartAction(p), .macOnlyStart, "\(p)")
            for ms in WebExposure.MacSessions.allCases {
                for c in WebExposure.ChatServe.allCases {
                    XCTAssertEqual(WebExposure.decide(.workspacePlan, p, macSessions: ms, chat: c), .macScreen)
                }
            }
        }
        XCTAssertNil(WebExposure.decide(.workspacePlan, .mac))
        XCTAssertEqual(WebExposure.kind(.workspacePlan), .macScreen)
        XCTAssertEqual(WebRoute.parse(method: .post, target: "/api/v1/workspace-plan"), .workspacePlan)
        XCTAssertEqual(WebRejection.macOnlyStart.code, WebRejection.macOnly.code)
        XCTAssertEqual(WebRejection.macOnlyStart.status, 403)
        XCTAssertTrue(WebRejection.macOnlyStart.message.contains("doz workspace start"))
    }

    /// Agents / Bots: the reads are reads (kind `read`, every browser); every change is this Mac's own browser only, whatever
    /// serve.chat or serve.mac_sessions say — the `mac-only` code, the family's own words.
    func testBotChangesAreThisMacsOnly() throws {
        for r: WebRoute in [.bots, .botsRetired, .bot("mira")] { XCTAssertEqual(WebExposure.kind(r), .read) }
        XCTAssertNil(WebExposure.decideBotAction(.mac))
        for p: WebExposure.Principal in [.remote(secure: false), .remote(secure: true)] {
            XCTAssertEqual(WebExposure.decideBotAction(p), .macOnlyBots, "\(p)")
        }
        XCTAssertEqual(WebRejection.macOnlyBots.code, WebRejection.macOnly.code)
        XCTAssertEqual(WebRejection.macOnlyBots.status, 403)
        XCTAssertEqual(WebRejection.macOnlyBots.message,
                       "Agents / Bots are changed only in this Mac's own browser, or with doz bot … in a terminal on the Mac")
        let token = try WebAction.decode(Data(#"{"action":"bot-token","name":"mira","confirm":"mira"}"#.utf8))
        XCTAssertTrue(token.isBot)
        XCTAssertFalse(token.isWorkspace || token.isFiling || token.isMacSession, "decided by its own family, never a serve setting")
    }

    /// The wide views are reads (`read`, for every browser that may read): projections decide what another computer sees. A
    /// fenced session's site allowed (`mac-net-policy`) is this Mac's own browser only, whatever serve.mac_sessions or serve.chat
    /// say — the `mac-only` code, its own words.
    /// Removing an ended session on this Mac (`mac-session-forget`, `mac-sessions-forget-ended`) is this Mac's own browser
    /// only, whatever serve.mac_sessions says — the `mac-only` code, its own words.
    func testForgettingIsThisMacsOnly() throws {
        XCTAssertNil(WebExposure.decideMacForgetAction(.mac))
        for p: WebExposure.Principal in [.remote(secure: false), .remote(secure: true)] {
            XCTAssertEqual(WebExposure.decideMacForgetAction(p), .macOnlySessions, "\(p)")
        }
        XCTAssertEqual(WebRejection.macOnlySessions.code, WebRejection.macOnly.code)
        XCTAssertEqual(WebRejection.macOnlySessions.status, 403)
        XCTAssertTrue(WebRejection.macOnlySessions.message.contains("doz sessions @mac --forget-ended"))
        for body in [#"{"action":"mac-session-forget","session":"old"}"#, #"{"action":"mac-sessions-forget-ended","sessions":["old"]}"#] {
            let a = try WebAction.decode(Data(body.utf8))
            XCTAssertTrue(a.isMacForget)
            XCTAssertFalse(a.isMacSession || a.isMacNet || a.isWorkspace || a.isFiling || a.isLifecycle, "decided by its own rule, never a serve setting")
        }
    }

    func testMacNetIsThisMacsOnly() throws {
        for r: WebRoute in [.workspaceReach, .workspaceFolders, .workspaceActivity] {
            XCTAssertEqual(WebExposure.kind(r), .read, "\(r)")
            XCTAssertNil(WebExposure.decide(r, .mac))
            XCTAssertNil(WebExposure.decide(r, .remote(secure: true)))
        }
        XCTAssertEqual(WebRoute.parse(method: .post, target: "/api/v1/workspace-reach"), .workspaceReach)
        XCTAssertEqual(WebRoute.parse(method: .post, target: "/api/v1/workspace-folders"), .workspaceFolders)
        XCTAssertEqual(WebRoute.parse(method: .post, target: "/api/v1/workspace-activity"), .workspaceActivity)
        XCTAssertNil(WebRoute.parse(method: .get, target: "/api/v1/workspace-reach"), "a POST only")
        XCTAssertNil(WebExposure.decideMacNetAction(.mac))
        for p: WebExposure.Principal in [.remote(secure: false), .remote(secure: true)] {
            XCTAssertEqual(WebExposure.decideMacNetAction(p), .macOnlyNet, "\(p)")
        }
        XCTAssertEqual(WebRejection.macOnlyNet.code, WebRejection.macOnly.code)
        XCTAssertEqual(WebRejection.macOnlyNet.status, 403)
        let a = try WebAction.decode(Data(#"{"action":"mac-net-policy","session":"agent","grant":["site:x.example"]}"#.utf8))
        XCTAssertTrue(a.isMacNet)
        XCTAssertFalse(a.isMacSession || a.isWorkspace || a.isFiling || a.isLifecycle, "decided by its own rule, never a serve setting")
    }

    /// A workspace's lifecycle: every verb is this Mac's own browser only, whatever serve.chat or serve.mac_sessions say — the
    /// `mac-only` code, its own words; its plan route is `mac-screen`.
    func testTheLifecycleIsThisMacsOnly() throws {
        XCTAssertNil(WebExposure.decideLifecycleAction(.mac))
        for p: WebExposure.Principal in [.remote(secure: false), .remote(secure: true)] {
            XCTAssertEqual(WebExposure.decideLifecycleAction(p), .macOnlyLifecycle, "\(p)")
            for ms in WebExposure.MacSessions.allCases {
                for c in WebExposure.ChatServe.allCases {
                    XCTAssertEqual(WebExposure.decide(.workspaceLifecyclePlan, p, macSessions: ms, chat: c), .macScreen)
                }
            }
        }
        XCTAssertNil(WebExposure.decide(.workspaceLifecyclePlan, .mac))
        XCTAssertEqual(WebExposure.kind(.workspaceLifecyclePlan), .macScreen)
        XCTAssertEqual(WebRoute.parse(method: .post, target: "/api/v1/workspace-lifecycle-plan"), .workspaceLifecyclePlan)
        XCTAssertNil(WebRoute.parse(method: .get, target: "/api/v1/workspace-lifecycle-plan"), "a POST only")
        XCTAssertEqual(WebRejection.macOnlyLifecycle.code, WebRejection.macOnly.code)
        XCTAssertEqual(WebRejection.macOnlyLifecycle.status, 403)
        for verb in WorkspaceVerb.allCases {
            let a = try WebAction.decode(Data(#"{"action":"workspace-\#(verb.rawValue)","workspace":"demo","ifPlan":"0123456789abcdef"\#(verb.confirm == .typed ? #","confirm":"demo""# : "")}"#.utf8))
            XCTAssertTrue(a.isLifecycle, verb.rawValue)
            XCTAssertFalse(a.isWorkspace || a.isFiling || a.isMacSession || a.isStarting || a.isWorker || a.isBot, "decided by its own family, never a serve setting")
        }
    }

    /// Workers: adding and ending one is this Mac's own browser only, whatever serve.chat or serve.mac_sessions say — the
    /// `mac-only` code, the family's own words; the Add a worker page's plan route is `mac-screen`.
    func testWorkersAreThisMacsOnly() throws {
        XCTAssertNil(WebExposure.decideWorkerAction(.mac))
        for p: WebExposure.Principal in [.remote(secure: false), .remote(secure: true)] {
            XCTAssertEqual(WebExposure.decideWorkerAction(p), .macOnlyWorkers, "\(p)")
            for ms in WebExposure.MacSessions.allCases {
                for c in WebExposure.ChatServe.allCases {
                    XCTAssertEqual(WebExposure.decide(.workerPlan, p, macSessions: ms, chat: c), .macScreen)
                }
            }
        }
        XCTAssertNil(WebExposure.decide(.workerPlan, .mac))
        XCTAssertEqual(WebExposure.kind(.workerPlan), .macScreen)
        XCTAssertEqual(WebRoute.parse(method: .post, target: "/api/v1/worker-plan"), .workerPlan)
        XCTAssertNil(WebRoute.parse(method: .get, target: "/api/v1/worker-plan"), "a POST only")
        XCTAssertEqual(WebRejection.macOnlyWorkers.code, WebRejection.macOnly.code)
        XCTAssertEqual(WebRejection.macOnlyWorkers.status, 403)
        XCTAssertEqual(WebRejection.macOnlyWorkers.message,
                       "Workers are added and ended only in this Mac's own browser, or with doz worker … in a terminal on the Mac")
        for body in [#"{"action":"worker-add","workspace":"demo","task":"x"}"#, #"{"action":"worker-end","workspace":"demo","name":"bot1","confirm":"bot1"}"#] {
            let a = try WebAction.decode(Data(body.utf8))
            XCTAssertTrue(a.isWorker)
            XCTAssertFalse(a.isWorkspace || a.isFiling || a.isMacSession || a.isBot || a.isStarting, "decided by its own family, never a serve setting")
        }
    }

    /// Your Macs: a read for every browser — another computer (a phone switching Macs) sees the same list, whatever
    /// `serve.*` says; it is names and origins only.
    func testYourMacsIsAReadForEveryBrowser() {
        XCTAssertEqual(WebExposure.kind(.macs), .read)
        for p: WebExposure.Principal in [.mac, .remote(secure: false), .remote(secure: true)] {
            for m: WebExposure.MacSessions in [.off, .watch, .interactive] {
                XCTAssertNil(WebExposure.decide(.macs, p, macSessions: m), "\(p) \(m)")
            }
        }
    }

    /// The routes of the sessions on this Mac parse exactly, their names by the Mac's rule (≤ 32).
    func testTheMacRoutesParse() {
        XCTAssertEqual(WebRoute.parse(method: .get, target: "/api/v1/mac/sessions"), .macSessions)
        XCTAssertEqual(WebRoute.parse(method: .get, target: "/api/v1/mac/sessions/agent/screen"), .macSessionScreen("agent"))
        XCTAssertEqual(WebRoute.parse(method: .post, target: "/api/v1/mac/terminal-ticket"), .macTerminalTicket)
        XCTAssertEqual(WebRoute.parse(method: .get, target: "/api/v1/mac/terminal-socket"), .macTerminalSocket)
        XCTAssertNil(WebRoute.parse(method: .post, target: "/api/v1/mac/sessions"), "no route opens one")
        XCTAssertNil(WebRoute.parse(method: .get, target: "/api/v1/mac/terminal-ticket"))
        XCTAssertNil(WebRoute.parse(method: .get, target: "/api/v1/mac/sessions/\(String(repeating: "a", count: 33))/screen"))
        XCTAssertNil(WebRoute.parse(method: .get, target: "/api/v1/mac/sessions/.x/screen"))
        XCTAssertNil(WebRoute.parse(method: .get, target: "/api/v1/sandboxes/@mac/sessions"), "@mac is never a sandbox route")
        XCTAssertNil(WebRoute.parse(method: .get, target: "/api/v1/mac/exec"))
    }

    static func label(_ r: WebRoute) -> String { DozableWebServer.routeLabel(r) }

    func testEveryRouteHasItsPinnedDecision() {
        XCTAssertEqual(Self.samples.count, Set(Self.samples.map(Self.label)).count, "one sample per route")
        for r in Self.samples {
            let want = Self.pinned[Self.label(r)]!
            XCTAssertEqual(WebExposure.decide(r, .mac), want.0, "\(Self.label(r)) on doz ui")
            XCTAssertEqual(WebExposure.decide(r, .remote(secure: false)), want.1, "\(Self.label(r)) remote, plain HTTP")
            XCTAssertEqual(WebExposure.decide(r, .remote(secure: true)), want.2, "\(Self.label(r)) remote, https via a trusted proxy")
        }
    }

    func testTheRefusalsSayWhyAndWhatToDo() {
        XCTAssertTrue(WebRejection.secretOverHTTP.message.contains("plain HTTP"))
        XCTAssertTrue(WebRejection.secretOverHTTP.message.contains("doz account add"))
        XCTAssertTrue(WebRejection.secretOverHTTP.message.contains("serve.public_origins"))
        XCTAssertEqual(WebRejection.secretOverHTTP.status, 403)
        XCTAssertTrue(WebRejection.macScreen.message.contains("Mac's own screen"))
        XCTAssertEqual(WebRejection.deviceRevoked.status, 401)
        XCTAssertEqual(WebRejection.tooManyAttempts.status, 429)
    }

    /// 657: what a dotfiles source is at now — POST only, `{}` or `{source: https URL}` (a folder on the Mac is never named
    /// by a page), a change (the host fetches on the Mac).
    func testTheDotfilesResolveRoute() throws {
        XCTAssertEqual(WebRoute.parse(method: .post, target: "/api/v1/dotfiles/resolve"), .dotfilesResolve)
        XCTAssertNil(WebRoute.parse(method: .get, target: "/api/v1/dotfiles/resolve"))
        XCTAssertEqual(WebExposure.kind(.dotfilesResolve), .change)
        XCTAssertNil(try WebDotfilesResolve.decode(Data("{}".utf8)).source)
        XCTAssertEqual(try WebDotfilesResolve.decode(Data(#"{"source":"https://github.com/you/dotfiles"}"#.utf8)).source, "https://github.com/you/dotfiles")
        XCTAssertThrowsError(try WebDotfilesResolve.decode(Data(#"{"source":"/Users/me/secret-repo"}"#.utf8)), "a Mac folder from a page")
        XCTAssertThrowsError(try WebDotfilesResolve.decode(Data(#"{"source":"~/dots"}"#.utf8)))
        XCTAssertThrowsError(try WebDotfilesResolve.decode(Data(#"{"source":"https://u:p@github.com/a/b"}"#.utf8)))
        XCTAssertThrowsError(try WebDotfilesResolve.decode(Data(#"{"source":"none"}"#.utf8)))
        XCTAssertThrowsError(try WebDotfilesResolve.decode(Data(#"{"source":"https://github.com/a/b","x":1}"#.utf8)))
        XCTAssertThrowsError(try WebDotfilesResolve.decode(Data("[]".utf8)))
    }

    /// 647: Check for updates — POST only, a body of {} and nothing else, a change (it asks the network).
    func testTheUpdateCheckRoute() throws {
        XCTAssertEqual(WebRoute.parse(method: .post, target: "/api/v1/updates/check"), .updatesCheck)
        XCTAssertNil(WebRoute.parse(method: .get, target: "/api/v1/updates/check"))
        XCTAssertEqual(WebExposure.kind(.updatesCheck), .change)
        XCTAssertNoThrow(try WebUpdateCheck.decodeRequest(Data("{}".utf8)))
        XCTAssertThrowsError(try WebUpdateCheck.decodeRequest(Data(#"{"force":true}"#.utf8)))
        XCTAssertThrowsError(try WebUpdateCheck.decodeRequest(Data("[]".utf8)))
    }

    func testNewRoutesParse() {
        XCTAssertEqual(WebRoute.parse(method: .get, target: "/api/v1/serve"), .serveStatus)
        XCTAssertEqual(WebRoute.parse(method: .get, target: "/api/v1/serve/devices"), .serveDevices)
        XCTAssertEqual(WebRoute.parse(method: .post, target: "/api/v1/serve/share"), .serveShare)
        XCTAssertEqual(WebRoute.parse(method: .post, target: "/api/v1/serve/devices/abc123/revoke"), .serveRevoke("abc123"))
        XCTAssertEqual(WebRoute.parse(method: .post, target: "/api/v1/serve/devices/abc123/name"), .serveRename("abc123"))
        XCTAssertEqual(WebRoute.parse(method: .get, target: "/api/v1/serve/probe"), .serveProbe)
        XCTAssertNil(WebRoute.parse(method: .post, target: "/api/v1/serve/devices/ABC123/revoke"), "ids are lower case")
        XCTAssertNil(WebRoute.parse(method: .post, target: "/api/v1/serve/devices/abc1234/revoke"))
        XCTAssertNil(WebRoute.parse(method: .get, target: "/api/v1/serve/share"))
    }
}
