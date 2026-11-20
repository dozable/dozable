import DozableChat
import DozableHost
import Foundation

/// A workspace's runs and its rooms' archive and removal in the dashboard. Three payload-less read routes (each its name in
/// the body, strictly decoded — never a generic route): `POST /api/v1/workspace-runs` (`workspace-runs`, a read),
/// `POST /api/v1/workspace-run-chat` (`workspace-run-chat`: a run's archived messages and timesheet — another computer only as
/// `serve.chat` lets it read chat; conversations and screens are never served) and `POST /api/v1/chat-room-plan`
/// (`chat-room-plan`, `mac-screen`: this Mac's own browser only). The three actions — `chat-room-archive`, `chat-room-rm`
/// (owned rooms only: never `loose` from a browser; the name typed, checked by the daemon) and `workspace-run-archive` — are
/// each exactly one HostOp, this Mac's own browser only (`WebAction.isRoomLifecycle`, `WebExposure.decideRoomAction`).
public enum WebRuns {
    static let runsFields: Set<String> = ["workspace"]
    static let chatFields: Set<String> = ["workspace", "run", "room", "before", "limit"]
    static let planFields: Set<String> = ["room", "verb"]

    public static func decodeRuns(_ body: Data) throws -> WorkspaceRequest {
        let f = try WebWorkspaceViews.object(body, runsFields)
        return WorkspaceRequest(name: try f.workspaceName("workspace"))
    }

    public static func decodeChat(_ body: Data) throws -> WorkspaceRequest {
        let f = try WebWorkspaceViews.object(body, chatFields)
        var w = WorkspaceRequest(name: try f.workspaceName("workspace"))
        w.run = try f.required(f.matching("run", "^[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{1,6}$", "a run's id"), "run")
        w.runRoom = try f.required(f.matching("room", "^[a-z0-9][a-z0-9_-]{0,63}$", "a room's name"), "room")
        w.before = try f.int("before", 0...Int(Int32.max))
        w.limit = try f.int("limit", 1...500)
        return w
    }

    public static func decodePlan(_ body: Data) throws -> ChatRoomRequest {
        let f = try WebWorkspaceViews.object(body, planFields)
        let room = try f.required(f.matching("room", "^[a-z0-9][a-z0-9_-]{0,63}$", "a room's name"), "room")
        guard chatIsRoomName(room) else { throw WebAction.Invalid("room: not a room's name") }
        guard let v = try f.oneOf("verb", ["archive", "rm"]) else { throw WebAction.Invalid("verb is required") }
        return ChatRoomRequest(room: room, verb: v)
    }

    public static func request(_ op: HostOp, _ w: WorkspaceRequest) -> HostRequest {
        var r = HostRequest(op)
        r.workspaceRequest = w
        return r
    }

    public static func planRequest(_ q: ChatRoomRequest) -> HostRequest {
        var r = HostRequest(.chatRoomPlan)
        r.chatRoom = q
        return r
    }
}
