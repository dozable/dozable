import Foundation
import XCTest
@testable import DozableWeb

/// 606 — the remote-capability table (`WebExposure`), pinned: every route, three askers (the Mac's doz ui, a remote
/// browser over plain HTTP, a remote browser over https through a trusted proxy).
final class ServeExposureTests: XCTestCase {
    /// One instance of EVERY route. The switch has no default: a new route does not compile here until it is added
    /// (and so pinned below).
    static let samples: [WebRoute] = {
        let all: [WebRoute] = [
            .index, .asset("/assets/x.js"), .terminalFrame, .offline, .serviceWorker, .sessionBootstrap, .sessionInfo, .sessionRenew, .sessionEnd,
            .overview, .sandbox("s"), .sandboxSessions("s"), .sandboxNetwork("s"), .sandboxTools("s"), .images, .imageTree, .accounts,
            .metrics(WebMetricsQuery.parse(nil)!), .metricsCSV(WebMetricsQuery.parse(nil)!), .events, .doctor, .stream, .actions, .operations, .operationsCancel,
            .policyPreview("s"), .terminal("s"), .terminalTicket("s"), .terminalSocket("s"), .settings, .settingsChange, .sessionScreen("s", "shell"),
            .terminalLayout("s"), .terminalLayoutSet("s"), .bootLogs("s"), .bootLog("s", 1), .buildLog("s"), .onboarding, .onboardingConfig, .preparations,
            .accountAdd, .sandboxKey("s"), .workspaceCheck, .workspaceChoose, .quickAdd, .projectsDirChoose, .projectOpen, .projectPreview,
            .projectWrite, .resources, .resourcesPreview, .bases, .tryCatalog, .tryList, .models("openrouter"), .plan, .dockerfileChoose, .access, .accessCheck, .accessGithubKey, .signup, .updatesCheck,
            .serveStatus, .serveDevices, .serveShare, .serveRevoke("abc123"), .serveRename("abc123"), .serveProbe,
            .files("s", nil), .filesWatch("s", []), .filesTree("s"), .filesTreeSet("s"), .filesOpen("s"), .editors, .grids, .dotfilesResolve, .portOpen("s"),
            .recipes, .macSessions, .macSessionScreen("agent"), .macTerminalTicket, .macTerminalSocket,
        ]
        for r in all { _ = covered(r) }
        return all
    }()

    static func covered(_ r: WebRoute) -> Bool {
        switch r {
        case .index, .asset, .terminalFrame, .offline, .serviceWorker, .sessionBootstrap, .sessionInfo, .sessionRenew, .sessionEnd, .overview,
             .sandbox, .sandboxSessions, .sandboxNetwork, .sandboxTools, .images, .imageTree, .accounts, .metrics, .metricsCSV, .events, .doctor,
             .stream, .actions, .operations, .operationsCancel, .policyPreview, .terminal, .terminalTicket, .terminalSocket, .settings, .settingsChange,
             .sessionScreen, .terminalLayout, .terminalLayoutSet, .bootLogs, .bootLog, .buildLog, .onboarding, .onboardingConfig, .preparations,
             .accountAdd, .sandboxKey, .workspaceCheck, .workspaceChoose, .quickAdd, .projectsDirChoose, .projectOpen, .projectPreview,
             .projectWrite, .resources, .resourcesPreview, .bases, .tryCatalog, .tryList, .models, .plan, .dockerfileChoose, .access, .accessCheck, .accessGithubKey, .signup, .updatesCheck,
             .serveStatus, .serveDevices, .serveShare, .serveRevoke, .serveRename, .serveProbe, .files, .filesWatch, .filesTree, .filesTreeSet, .filesOpen, .editors, .grids,
             .dotfilesResolve, .portOpen, .recipes, .macSessions, .macSessionScreen, .macTerminalTicket, .macTerminalSocket:
            return true
        }
    }

    /// The table (606.02-PLAN.md): route → (doz ui, remote http, remote https). nil = allowed.
    static let pinned: [String: (WebRejection?, WebRejection?, WebRejection?)] = {
        var t: [String: (WebRejection?, WebRejection?, WebRejection?)] = [:]
        for r in samples { t[ServeExposureTests.label(r)] = (nil, nil, nil) }
        for secret in ["accountAdd", "sandboxKey", "accessGithubKey"] { t[secret] = (nil, .secretOverHTTP, nil) }
        for screen in ["terminal", "workspaceChoose", "projectsDirChoose", "dockerfileChoose", "filesOpen", "editors", "portOpen"] { t[screen] = (nil, .macScreen, .macScreen) }
        t["serveProbe"] = (.notFound, nil, nil)
        // The sessions on this Mac: never another computer's by default (serve.mac_sessions = off).
        for mac in ["macSessions", "macSessionScreen", "macTerminalTicket", "macTerminalSocket"] { t[mac] = (nil, .macSession, .macSession) }
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
