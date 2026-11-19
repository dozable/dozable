import DozableHost
import DozableKit
import Foundation

/// The dashboard's workspace and Agents / Bots reads: six typed GET routes, each EXACTLY ONE read-only HostOp the CLI also
/// sends (`doz workspace ls`, `doz workspace show W`, `doz workspace show W --brief`, `doz workspace log W --since …`,
/// `doz workspace ls --loose`, `doz bot ls`) — answered in-process when no daemon runs (looking never starts one). `request(for:)` is the ONE map from a route to its request (`HostWebData` uses it;
/// `WebWorkspacesTests` pins it). Nothing here changes anything.
public enum WebWorkspaceReads {
    /// The request a read route sends (nil: not one of these routes).
    public static func request(for route: WebRoute) -> HostRequest? {
        switch route {
        case .workspaces:
            return workspaceRequest(.workspaceList, WorkspaceRequest())
        case .workspace(let w):
            return workspaceRequest(.workspaceShow, WorkspaceRequest(name: w))
        case .workspaceBrief(let w):
            var r = WorkspaceRequest(name: w)
            r.withBrief = true
            return workspaceRequest(.workspaceShow, r)
        case .workspaceLog(let w, let since):
            var r = WorkspaceRequest(name: w)
            r.since = since
            return workspaceRequest(.workspaceLog, r)
        case .loose:
            var w = WorkspaceRequest()
            w.loose = true
            return workspaceRequest(.workspaceList, w)
        case .bots, .botsRetired, .bot:
            return WebBotReads.request(for: route)
        default:
            return nil
        }
    }

    static func workspaceRequest(_ op: HostOp, _ w: WorkspaceRequest) -> HostRequest {
        var r = HostRequest(op)
        r.workspaceRequest = w
        return r
    }

    /// The log route's query: exactly `since=EPOCH` (seconds, a fraction allowed — the page sends the last line's time back),
    /// else not a route.
    public static func since(_ query: String) -> Date? {
        guard query.hasPrefix("since="), !query.contains("&") else { return nil }
        let v = query.dropFirst(6)
        guard (1...24).contains(v.count), v.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }), v.filter({ $0 == "." }).count <= 1,
              let t = Double(v), t.isFinite, t >= 0, t < 32_503_680_000 else { return nil }
        return Date(timeIntervalSince1970: t)
    }

    /// A workspace's name in the address, checked before any call (the store's own rule); the refusal never echoes it.
    public static func checkName(_ w: String) throws {
        guard WorkspaceName.isValid(w) else {
            throw WebAction.Invalid("workspace: 1–40 characters of a-z, 0-9 and -, not starting with -")
        }
    }

    // MARK: what another computer sees

    /// A listing for a browser that may not see the sessions on this Mac (`macAllowed` false: another computer while
    /// `serve.mac_sessions` is off): the loose sessions on this Mac are left out and counted, and who is working is not said
    /// (its names may be sessions' names), nor any place on this Mac.
    public static func forBrowser(_ l: WebWorkspaceListing, macAllowed: Bool) -> WebWorkspaceListing {
        guard !macAllowed else { return l }
        var out = l
        out.loose = l.loose.filter { $0.kind != "mac" }
        out.hidden = l.loose.count - out.loose.count
        for i in out.workspaces.indices {
            out.workspaces[i].working = nil
            // A session's name on this Mac is not this browser's to see.
            out.workspaces[i].places = out.workspaces[i].places.filter { !$0.hasPrefix(MacPlace.name) }
        }
        return out
    }

    /// A workspace for such a browser: its agents on this Mac are left out and counted, and so are the notes that name one.
    public static func forBrowser(_ d: WebWorkspaceDetail, macAllowed: Bool) -> WebWorkspaceDetail {
        guard !macAllowed else { return d }
        var out = d
        out.agents = d.agents.filter { $0.kind != "mac" }
        out.hidden = d.agents.count - out.agents.count
        out.notes = d.notes.filter { !$0.contains(MacPlace.name) }
        // A gap about a session on this Mac names it: not this browser's to see.
        out.gaps = d.gaps?.filter { !$0.why.contains(MacPlace.name) && !$0.why.contains("session") && !$0.fix.contains(MacPlace.name) }
        return out
    }
}
