import Foundation

// A room's state as its members see it: `open`, `closed` (its workspace is finished: readable, posts refused until it is
// reopened), `archived` (read-only, put away by the owner — it outranks closed) or `gone` (removed for good: a tombstone
// remains). An asleep workspace's room stays open. One pure function, `RoomStateTests`.

public enum RoomState: String, Codable, CaseIterable, Sendable {
    case open, closed, archived, gone

    /// `exists`: the chat server has the room; `archived`: it says so; `closedBy`: the workspace whose finish closed it (nil:
    /// not in the closed set); `tombstone`: the room index has one for this name.
    public static func derive(exists: Bool, archived: Bool, closedBy: String?, tombstone: Bool) -> RoomState {
        if !exists { return tombstone ? .gone : .open }
        if archived { return .archived }
        if closedBy != nil { return .closed }
        return .open
    }

    /// What a member reads about it.
    public func words(workspace: String? = nil) -> String {
        switch self {
        case .open: return "open"
        case .closed: return "closed: \(workspace.map { "its workspace \($0) is finished" } ?? "its workspace is finished") — readable, posts refused"
        case .archived: return "archived: read-only"
        case .gone: return "gone: removed for good"
        }
    }

    /// The refusal a post, edit, reaction or command in a closed room gets (the chat server's own words).
    public static func closedRefusal(room: String, workspace: String) -> String {
        "room \(room) is closed: its workspace \(workspace) is finished. It can still be read; the owner can reopen it with doz workspace reopen \(workspace)"
    }
}
