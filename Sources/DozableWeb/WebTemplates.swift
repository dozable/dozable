import DozableHost
import DozableKit
import Foundation

/// 782 — workspace templates in the dashboard (docs/engineering/web.md, "The New workspace wizard"): the gallery's list
/// (`GET /api/v1/templates`, a read — what doz carries, nothing of this Mac's) and the action that makes one,
/// `workspace-from-template` — this Mac's own browser only (`WebAction.isFiling`/`isStarting`), exactly one acting HostOp,
/// `workspace-up` (after its read-only plan, `workspace-up-plan`, whose sha it acts on). The files are written and planned
/// in doz ui's process, where the CLI's space resolver lives (`WorkspaceTemplateMaker`, installed by `doz ui` as `maker`):
/// a browser never names a path but its own folder, chosen with this Mac's picker.
public enum WebTemplates {
    /// The action's fields, strictly.
    static let fields: Set<String> = ["template", "workspace", "folder", "manager", "actsAsYou"]

    /// What `workspace-from-template` asks for.
    public struct Request: Codable, Equatable, Sendable {
        public var template: String
        public var workspace: String
        /// A folder of the person's own for the agents (nil: the new empty folder, `~/doz-workspaces/NAME`).
        public var folder: String?
        public var manager: String?
        /// The person ticked "acts as me" for a manager bot that runs unfenced.
        public var actsAsYou: Bool
    }

    /// Makes it: `(request, send)` → the answer as JSON. nil: this server cannot (not `doz ui`).
    public typealias Maker = @Sendable (Request, @escaping @Sendable (HostRequest) async throws -> JSONValue) async throws -> JSONValue
    nonisolated(unsafe) private static var maker: Maker?
    private static let lock = NSLock()
    public static func installMaker(_ m: @escaping Maker) { lock.withLock { maker = m } }
    static var installed: Maker? { lock.withLock { maker } }

    /// The templates, each with its drawing in the renderer's words (its space file rendered with sample names).
    public static func list() -> [WorkspaceTemplate] {
        WorkspaceTemplates.list().map { t in
            var t = t
            let s = WorkspaceTemplates.sample
            if let r = try? WorkspaceTemplates.render(t.id, space: s.space, owner: s.owner, manager: t.needs.manager ? s.manager : nil, folder: s.folder,
                                                       bareNames: true) {
                t.picture = WebSpace.picture(r.space) ?? r.space
            }
            return t
        }
    }

    static func decode(_ f: WebAction.Fields) throws -> Request {
        guard let id = try f.string("template", max: 40), WorkspaceTemplates.isID(id) else { throw WebAction.Invalid("template: a template's id") }
        let folder = try f.string("folder", max: WebWorkspaceNew.maximumPathBytes).map { try WebWorkspaceNew.path($0, "folder") }
        let manager = try f.string("manager", max: 40).map { _ in try f.botName("manager") }
        return Request(template: id, workspace: try f.workspaceName("workspace"), folder: folder, manager: manager,
                       actsAsYou: try f.flag("actsAsYou") == true)
    }

    /// The up as a test's stand-in maker sends it (WebActionHTTPTests): the operation's plumbing, no file.
    public static func hostRequestForTests(_ q: Request) -> HostRequest { hostRequest(q) }

    /// The HostOp it acts through (the up), for the action's table, its label and its key.
    static func hostRequest(_ q: Request) -> HostRequest {
        var r = HostRequest(.workspaceUp)
        r.workspaceRequest = WorkspaceRequest(name: q.workspace)
        return r
    }
}
