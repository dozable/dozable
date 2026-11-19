import DozableHost
import DozableKit
import Foundation

/// A workspace's lifecycle from the dashboard — this Mac's own browser only. The plan route `POST
/// /api/v1/workspace-lifecycle-plan` — exactly one read-only HostOp, `workspace-lifecycle-plan`, the one `doz workspace VERB W
/// --dry-run` sends — its strict body and its projection; the eight actions are `WebAction.workspaceLifecycle`
/// (`WebExposure.decideLifecycleAction`: 403 `mac-only` for another computer), the route `mac-screen`.
public enum WebWorkspaceLifecycle {
    static let planFields: Set<String> = ["workspace", "verb", "removeSandboxes", "keepTemplates", "binFolders"]

    /// The request the plan route sends (the plan reads, never writes).
    public static func planRequest(_ w: WorkspaceRequest) -> HostRequest {
        var r = HostRequest(.workspaceLifecyclePlan)
        r.workspaceRequest = w
        return r
    }

    /// The plan route's body, strictly: the workspace by its rule and the verb (400 before any call), and the flags.
    public static func decodePlan(_ body: Data) throws -> WorkspaceRequest {
        guard let obj = try? JSONSerialization.jsonObject(with: body), let d = obj as? [String: Any] else {
            throw WebAction.Invalid("the body must be a JSON object")
        }
        let extra = Set(d.keys).subtracting(planFields)
        guard extra.isEmpty else { throw WebAction.Invalid("unexpected field(s): \(extra.sorted().joined(separator: ", "))") }
        let f = WebAction.Fields(d)
        var w = WorkspaceRequest(name: try f.workspaceName("workspace"))
        guard let v = try f.oneOf("verb", WorkspaceVerb.allCases.map(\.rawValue)) else { throw WebAction.Invalid("verb is required") }
        w.verb = v
        w.removeSandboxes = try f.bool("removeSandboxes") == true ? true : nil
        w.keepTemplates = try f.bool("keepTemplates") == false ? false : nil
        w.binFolders = try f.bool("binFolders") == true ? true : nil
        return w
    }
}

/// `POST /api/v1/workspace-lifecycle-plan`'s answer, field by field: each agent's row, what is kept and what goes (sizes;
/// a folder's path — this Mac's own browser only), the refusals, the queue, the confirmation, the commands and the sha the
/// action carries back. Never a token.
public struct WebWorkspaceLifecyclePlan: Codable, Equatable, Sendable {
    public struct Row: Codable, Equatable, Sendable {
        public var name: String
        public var role: String
        public var place: String
        public var isolation: String
        public var now: String
        public var activity: String?
        public var after: String
        public var back: String
        public var changes: Bool
    }
    public struct Item: Codable, Equatable, Sendable {
        public var text: String
        public var bytes: Int64?
        public var path: String?
    }
    public struct Queue: Codable, Equatable, Sendable {
        public var width: Int
        public var changes: Int
        public var note: String?
    }
    public var workspace: String
    public var verb: String
    public var state: String
    public var rows: [Row]
    public var keeps: [Item]
    public var goes: [Item]
    public var refusals: [String]
    public var refusalCode: String?
    public var queue: Queue
    public var confirm: String
    public var confirmName: String?
    public var command: String
    public var commands: [String]
    public var notes: [String]
    public var factsKnown: Bool
    public var templates: [String: String]?
    public var sha: String

    public init(_ p: WorkspaceLifecyclePlan) {
        workspace = p.workspace; verb = p.verb; state = p.state
        rows = p.rows.map { Row(name: $0.name, role: $0.role, place: $0.place, isolation: $0.isolation, now: $0.now, activity: $0.activity,
                                after: $0.after, back: $0.back, changes: $0.changes) }
        keeps = p.keeps.map { Item(text: $0.text, bytes: $0.bytes, path: $0.path) }
        goes = p.goes.map { Item(text: $0.text, bytes: $0.bytes, path: $0.path) }
        refusals = p.refusals; refusalCode = p.refusalCode
        queue = Queue(width: p.queue.width, changes: p.queue.changes, note: p.queue.note)
        confirm = p.confirm; confirmName = p.confirmName; command = p.command; commands = p.commands; notes = p.notes
        factsKnown = p.factsKnown; templates = p.templates; sha = p.sha
    }
}
