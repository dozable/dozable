import DozableHost
import DozableKit
import Foundation

/// The dashboard's workspace and Agents / Bots reads: four typed GET routes, each EXACTLY ONE read-only HostOp the CLI also
/// sends (`doz workspace ls`, `doz workspace show W`, `doz workspace ls --loose`, `doz bot ls`) — answered in-process when no
/// daemon runs (looking never starts one). `request(for:)` is the ONE map from a route to its request (`HostWebData` uses it;
/// `WebWorkspacesTests` pins it). Nothing here changes anything: the actions come in later steps.
public enum WebWorkspaceReads {
    /// The request a read route sends (nil: not one of these routes).
    public static func request(for route: WebRoute) -> HostRequest? {
        switch route {
        case .workspaces:
            return workspaceRequest(.workspaceList, WorkspaceRequest())
        case .workspace(let w):
            return workspaceRequest(.workspaceShow, WorkspaceRequest(name: w))
        case .loose:
            var w = WorkspaceRequest()
            w.loose = true
            return workspaceRequest(.workspaceList, w)
        case .bots:
            var r = HostRequest(.botList)
            r.botRequest = BotRequest()
            return r
        default:
            return nil
        }
    }

    static func workspaceRequest(_ op: HostOp, _ w: WorkspaceRequest) -> HostRequest {
        var r = HostRequest(op)
        r.workspaceRequest = w
        return r
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
    /// (its names may be sessions' names).
    public static func forBrowser(_ l: WebWorkspaceListing, macAllowed: Bool) -> WebWorkspaceListing {
        guard !macAllowed else { return l }
        var out = l
        out.loose = l.loose.filter { $0.kind != "mac" }
        out.hidden = l.loose.count - out.loose.count
        for i in out.workspaces.indices where out.workspaces[i].working != nil {
            out.workspaces[i].working = nil
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
        return out
    }
}
