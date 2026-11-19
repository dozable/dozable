import DozableHost
import DozableKit
import Foundation

/// A workspace's wide views in the dashboard — Can do, Network & secrets, Folders & points, Activity. Three payload-less POST
/// reads with the workspace in the body (a read that carries its question, like `grids`), each EXACTLY ONE read-only HostOp
/// the CLI also sends: `POST /api/v1/workspace-reach` → `workspace-reach` (`doz workspace show W --can-do | --network`),
/// `POST /api/v1/workspace-folders` → `workspace-folders` (`--folders`), `POST /api/v1/workspace-activity` → `workspace-log`
/// with a page (`doz workspace log W --limit N --before I`). Strict bodies (an unknown field or a bad name → 400, never
/// echoed); CSRF as every POST; answered in-process when no daemon runs. Exposure `read`: another computer gets projections —
/// this Mac's sessions only with `serve.mac_sessions` on, held secrets only as a count. Never a value or a token.
public enum WebWorkspaceViews {
    static let reachFields: Set<String> = ["workspace", "agent"]
    static let foldersFields: Set<String> = ["workspace"]
    static let activityFields: Set<String> = ["workspace", "before", "limit"]
    /// An agent's name in a workspace (the store's rule).
    static let agentPattern = "^[A-Za-z0-9_][A-Za-z0-9._-]{0,63}$"

    static func object(_ body: Data, _ allowed: Set<String>) throws -> WebAction.Fields {
        guard let obj = try? JSONSerialization.jsonObject(with: body), let d = obj as? [String: Any] else {
            throw WebAction.Invalid("the body must be a JSON object")
        }
        let extra = Set(d.keys).subtracting(allowed)
        guard extra.isEmpty else { throw WebAction.Invalid("unexpected field(s): \(extra.sorted().joined(separator: ", "))") }
        return WebAction.Fields(d)
    }

    public static func decodeReach(_ body: Data) throws -> WorkspaceRequest {
        let f = try object(body, reachFields)
        var w = WorkspaceRequest(name: try f.workspaceName("workspace"))
        w.agent = try f.matching("agent", agentPattern, "an agent's name in the workspace")
        return w
    }

    public static func decodeFolders(_ body: Data) throws -> WorkspaceRequest {
        WorkspaceRequest(name: try object(body, foldersFields).workspaceName("workspace"))
    }

    public static func decodeActivity(_ body: Data) throws -> WorkspaceRequest {
        let f = try object(body, activityFields)
        var w = WorkspaceRequest(name: try f.workspaceName("workspace"))
        w.before = try f.int("before", 0...Int(Int32.max))
        w.limit = try f.int("limit", 1...WorkspaceLogPage.maximumLimit) ?? WorkspaceLogPage.defaultLimit
        return w
    }

    /// The request each route sends — the CLI's own.
    public static func request(_ op: HostOp, _ w: WorkspaceRequest) -> HostRequest {
        var r = HostRequest(op)
        r.workspaceRequest = w
        return r
    }
}

/// `POST /api/v1/workspace-reach`'s answer, field by field. For another computer (`forBrowser`): an agent on this Mac only
/// with `serve.mac_sessions` on (else left out and counted), and held secrets only as a count per agent.
public struct WebWorkspaceReach: Codable, Equatable, Sendable {
    public struct Capability: Codable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var state: String
        public var sentence: String
        public var editable: String
        public var link: String?
    }
    public struct Refusal: Codable, Equatable, Sendable {
        public var host: String
        public var port: Int?
        public var count: Int
        public var lastAt: Date?
        public var grant: String
    }
    public struct Forward: Codable, Equatable, Sendable {
        public var port: Int
        public var local: Int?
    }
    public struct Held: Codable, Equatable, Sendable {
        public var name: String
        public var to: String
        public var header: String
        public var fingerprint: String?
        public var kind: String
    }
    public struct Network: Codable, Equatable, Sendable {
        public var proxied: Bool
        public var live: Bool
        public var preset: String?
        public var sites: [String]
        public var hostPorts: [Int]
        public var forwarded: [Forward]
        public var refused: [Refusal]
    }
    public struct Folder: Codable, Equatable, Sendable {
        public var path: String
        public var mode: String
    }
    public struct Agent: Codable, Equatable, Sendable {
        public var name: String
        public var role: String
        public var isolation: String
        public var place: String
        public var kind: String
        public var control: String
        public var actsAsYou: Bool
        public var state: String
        public var capabilities: [Capability]
        public var network: Network
        /// Held for it, by name (this Mac's own browser; empty for another computer, which gets `heldCount` only).
        public var held: [Held]
        public var heldCount: Int
        public var folders: [Folder]
        public var account: String?
        public var rooms: [String]
    }
    public var workspace: String
    public var agents: [Agent]
    public var defaults: WorkspaceReach.Defaults
    public var refusalsKnown: Bool
    public var notes: [String]
    /// Agents on this Mac not shown to this browser.
    public var hidden: Int

    public init(_ r: WorkspaceReach) {
        workspace = r.workspace
        defaults = r.defaults
        refusalsKnown = r.refusalsKnown
        notes = r.notes ?? []
        hidden = 0
        agents = r.agents.map { a in
            Agent(name: a.name, role: a.role, isolation: a.isolation, place: a.place, kind: a.kind, control: a.control, actsAsYou: a.actsAsYou,
                  state: a.state,
                  capabilities: a.capabilities.map { Capability(id: $0.id, name: $0.name, state: $0.state, sentence: $0.sentence, editable: $0.editable, link: $0.link) },
                  network: Network(proxied: a.network.proxied, live: a.network.live, preset: a.network.preset, sites: a.network.sites,
                                   hostPorts: a.network.hostPorts.map { Int($0.port) },
                                   forwarded: a.network.forwarded.map { Forward(port: $0.port, local: $0.local) },
                                   refused: a.network.refused.map { Refusal(host: $0.host, port: $0.port, count: $0.count, lastAt: $0.lastAt, grant: $0.grant) }),
                  held: a.held.map { Held(name: $0.name, to: $0.to, header: $0.header, fingerprint: $0.kind == "given" ? $0.fingerprint : nil, kind: $0.kind) },
                  heldCount: a.held.count,
                  folders: a.folders.map { Folder(path: $0.path, mode: $0.mode) }, account: a.account, rooms: a.rooms)
        }
    }

    /// What another computer sees: no session on this Mac unless `macAllowed` (left out, counted), no held secret's name — a
    /// count only. This Mac's own browser (`remote` false) sees it all.
    public static func forBrowser(_ r: WebWorkspaceReach, remote: Bool, macAllowed: Bool) -> WebWorkspaceReach {
        guard remote else { return r }
        var out = r
        if !macAllowed {
            out.agents = r.agents.filter { $0.kind != "mac" }
            out.hidden = r.agents.count - out.agents.count
        }
        for i in out.agents.indices { out.agents[i].held = [] }
        return out
    }
}

/// `POST /api/v1/workspace-folders`'s answer, field by field. Another computer: the changes in a folder that only a session on
/// this Mac works in are not shown unless `serve.mac_sessions` is on (`hidden`); points as today.
public struct WebWorkspaceFolders: Codable, Equatable, Sendable {
    public struct Change: Codable, Equatable, Sendable {
        public var kind: String
        public var path: String
    }
    public struct Folder: Codable, Equatable, Sendable {
        public var path: String
        public var mode: String
        public var main: Bool
        public var workspace: Bool
        public var exists: Bool
        public var ignoreRules: Int?
        public var readonlyRules: Int?
        public var agents: [String]
        public var changes: [Change]
        public var count: Int
        public var truncated: Bool
        public var scanned: Int
        public var hidden: Bool
    }
    public struct Point: Codable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var note: String
        public var createdAt: Date
        public var automatic: Bool
    }
    public struct Points: Codable, Equatable, Sendable {
        public var agent: String
        public var sandbox: String
        public var rows: [Point]
    }
    public var workspace: String
    public var since: Date
    public var folders: [Folder]
    public var points: [Points]

    public init(_ f: WorkspaceFolders) {
        workspace = f.workspace
        since = f.since
        folders = f.folders.map { x in
            Folder(path: x.path, mode: x.mode, main: x.main, workspace: x.workspace, exists: x.exists, ignoreRules: x.rules.ignore,
                   readonlyRules: x.rules.readonly, agents: x.agents, changes: x.changes.map { Change(kind: $0.kind, path: $0.path) },
                   count: x.count, truncated: x.truncated, scanned: x.scanned, hidden: x.hidden == true)
        }
        points = f.points.map { p in
            Points(agent: p.agent, sandbox: p.sandbox, rows: p.rows.sorted { $0.createdAt > $1.createdAt }.map {
                Point(id: $0.id, name: $0.name, note: $0.note, createdAt: $0.createdAt, automatic: $0.automatic)
            })
        }
    }

    /// For another computer while `serve.mac_sessions` is off: a folder worked in only by agents on this Mac (`macAgents`)
    /// keeps its path (the side panel shows it today) but not what changed in it, nor who works in it.
    public static func forBrowser(_ f: WebWorkspaceFolders, macAllowed: Bool, macAgents: Set<String>) -> WebWorkspaceFolders {
        guard !macAllowed else { return f }
        var out = f
        for i in out.folders.indices {
            let names = out.folders[i].agents
            out.folders[i].agents = names.filter { !macAgents.contains($0) }
            if !names.isEmpty, names.allSatisfy({ macAgents.contains($0) }) || !out.folders[i].workspace {
                out.folders[i].changes = []
                out.folders[i].count = 0
                out.folders[i].hidden = true
            }
        }
        return out
    }
}

/// `POST /api/v1/workspace-activity`'s answer: one page of the log, newest first — the sentences (never a hash, fingerprint,
/// place key or size field), `first` to ask the page before, and how many lines about this Mac's sessions were left out for
/// another computer while `serve.mac_sessions` is off.
public struct WebWorkspaceActivity: Codable, Equatable, Sendable {
    public var lines: [WebWorkspaceLogLine]
    public var first: Int?
    public var more: Bool
    public var hidden: Int

    public init(_ p: WorkspaceLogPage, macAllowed: Bool) {
        var kept = p.entries
        hidden = 0
        if !macAllowed {
            kept = p.entries.filter { !WebWorkspaceLog.aboutThisMac($0) }
            hidden = p.entries.count - kept.count
        }
        lines = kept.map(WebWorkspaceLogLine.init)
        first = p.first
        more = p.more
    }
}
