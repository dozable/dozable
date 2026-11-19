import DozableHost
import DozableKit
import Foundation

/// The New workspace wizard's server side: the widened `workspace-new` action's strict fields (also the plan route's body),
/// the plan route `POST /api/v1/workspace-plan` — exactly one read-only HostOp, `workspace-plan`, the one `doz workspace new
/// … --dry-run` sends — and its projection. This Mac's own browser only: the action by `WebExposure.decideFilingAction`, the
/// route by its kind (`mac-screen`: it shows this Mac's folders and bots). A browser never names a project path:
/// `fromProject` is a flag the web layer on the Mac turns into `project` and `network` (`WorkspaceProjectFill`).
public enum WebWorkspaceNew {
    static let fields: Set<String> = ["workspace", "brief", "refs", "folders", "newFolder", "fromProject", "room", "noRoom", "manager",
                                      "managerIsolation", "workerIsolation", "network", "adopt"]
    static let maximumRefs = 16
    static let maximumFolders = 8
    static let maximumAdopt = 4
    static let maximumPathBytes = 1024

    /// The request the plan route sends (the plan reads, never writes).
    public static func planRequest(_ w: WorkspaceRequest) -> HostRequest {
        var r = HostRequest(.workspacePlan)
        r.workspaceRequest = w
        return r
    }

    /// The plan route's body: the action's fields (no `action`), strictly. While the person types, the name and the brief
    /// may be anything a text field holds (the daemon's refusals say what is wrong); every other field as the action's.
    public static func decodePlan(_ body: Data) throws -> (WorkspaceRequest, fromProject: Bool) {
        guard let obj = try? JSONSerialization.jsonObject(with: body), let d = obj as? [String: Any] else {
            throw WebAction.Invalid("the body must be a JSON object")
        }
        let extra = Set(d.keys).subtracting(fields)
        guard extra.isEmpty else { throw WebAction.Invalid("unexpected field(s): \(extra.sorted().joined(separator: ", "))") }
        return try decode(WebAction.Fields(d), forPlan: true)
    }

    /// The fields as `doz workspace new` takes them: the name by `WorkspaceName`, the brief as text, ≤ 16 references and
    /// ≤ 8 folders (each absolute, ≤ 1024 bytes, resolved as the CLI resolves them), `mode` rw|ro, a room by the chat
    /// server's rule (not with `noRoom`), a manager by the bot-name rule and its isolation only with it, new workers fenced
    /// or vm (never unfenced by default), the network preset, 0–4 agents to adopt.
    static func decode(_ f: WebAction.Fields, forPlan: Bool) throws -> (WorkspaceRequest, fromProject: Bool) {
        var w = WorkspaceRequest()
        if forPlan {
            // An empty name while the person types: no name (the daemon's refusal says which is wanted).
            w.name = (f.d["workspace"] as? String) == "" ? nil : try f.string("workspace", max: 64)
            if let v = f.d["brief"], !(v is NSNull) {
                guard let s = v as? String, s.utf8.count <= WorkspaceStore.maximumBriefBytes,
                      !s.unicodeScalars.contains(where: { $0.properties.generalCategory == .control && !["\n", "\r", "\t"].contains($0) }) else {
                    throw WebAction.Invalid("brief: text, no control characters but line breaks and tabs")
                }
                w.brief = s
            }
        } else {
            w.name = try f.workspaceName("workspace")
            w.brief = try f.brief("brief")
        }
        w.refs = try list(f, "refs", maximumRefs)?.map { (x: Any) -> String in
            guard let s = x as? String else { throw WebAction.Invalid("refs: paths or http(s) addresses") }
            return try ref(s)
        } ?? []
        var folders: [WorkspaceFolder] = []
        for x in try list(f, "folders", maximumFolders) ?? [] {
            guard let o = x as? [String: Any], Set(o.keys).isSubset(of: ["path", "mode"]), let p = o["path"] as? String,
                  let m = o["mode"] as? String, WorkspaceFolder.modes.contains(m) else {
                throw WebAction.Invalid("folders: a list of {path, mode} — an absolute path, mode rw or ro")
            }
            folders.append(WorkspaceFolder(path: try path(p, "folders"), mode: m))
        }
        w.folders = folders
        w.newFolder = try f.flag("newFolder")
        let fromProject = try f.flag("fromProject") == true
        w.room = try f.string("room", max: 64).map { r in
            guard WebChatRoute.isRoom(r) else { throw WebAction.Invalid("room: a room's name (a-z, 0-9, _ and -)") }
            return r
        }
        w.noRoom = try f.flag("noRoom")
        if w.room != nil, w.noRoom == true { throw WebAction.Invalid("room or noRoom, not both") }
        w.manager = try f.string("manager", max: 40).map { _ in try f.botName("manager") }
        w.managerIsolation = try f.oneOf("managerIsolation", ["fenced", "vm", "unfenced"])
        if w.managerIsolation != nil, w.manager == nil { throw WebAction.Invalid("managerIsolation goes with manager") }
        if let i = try f.string("workerIsolation", max: 16) {
            guard WorkspaceNetworks.workerIsolations.contains(i) else {
                throw WebAction.Invalid("workerIsolation: vm or fenced — new workers are never unfenced by default")
            }
            w.workerIsolation = i
        }
        w.network = try f.oneOf("network", WorkspaceNetworks.presets)
        let adopt = try list(f, "adopt", maximumAdopt)?.map { (x: Any) -> String in
            guard let s = x as? String else { throw WebAction.Invalid("adopt: a sandbox's name, or @mac/SESSION") }
            return try WebAction.Fields(["agent": s]).agentPlace("agent")
        } ?? []
        w.adopt = adopt.isEmpty ? nil : adopt
        return (w, fromProject)
    }

    static func list(_ f: WebAction.Fields, _ key: String, _ max: Int) throws -> [Any]? {
        guard let v = f.d[key], !(v is NSNull) else { return nil }
        guard let a = v as? [Any], a.count <= max else { throw WebAction.Invalid("\(key): a list of at most \(max)") }
        return a
    }

    /// An absolute path (or ~/…), one line, ≤ 1024 bytes — resolved as the CLI resolves it (`workspaceAbsolute`).
    static func path(_ s: String, _ key: String) throws -> String {
        guard !s.isEmpty, s.utf8.count <= maximumPathBytes, !s.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }),
              s.hasPrefix("/") || s.hasPrefix("~/") else {
            throw WebAction.Invalid("\(key): an absolute path (or ~/…), one line, at most 1024 bytes")
        }
        let expanded = (s as NSString).expandingTildeInPath
        return WorkspaceStore.resolved(URL(fileURLWithPath: expanded).standardizedFileURL.path)
    }

    /// A reference: an http(s) address with a host, or a path.
    static func ref(_ s: String) throws -> String {
        if s.hasPrefix("http://") || s.hasPrefix("https://") {
            guard s.utf8.count <= maximumPathBytes, !s.unicodeScalars.contains(where: { $0.value <= 0x20 || $0.value == 0x7f }),
                  let u = URL(string: s), u.host?.isEmpty == false else {
                throw WebAction.Invalid("refs: an http(s) address with a host, or an absolute path")
            }
            return s
        }
        return try path(s, "refs")
    }

    /// `fromProject` on the Mac: `project` and `network` filled from the main folder's doz_project.yaml (never written). A
    /// refusal is one of a few fixed sentences (a browser's paths are never echoed).
    static func fill(_ w: inout WorkspaceRequest) throws {
        guard WorkspaceProjectFill.mainFolder(w) != nil else { throw WebAction.Invalid("fromProject: give a main folder first") }
        do {
            try WorkspaceProjectFill.apply(&w, parse: { try WebProjectFiles.parse($0, file: $1) })
        } catch {
            let e = HostError.from(error)
            if e.code == .notFound { throw WebAction.Invalid("fromProject: there is no doz_project.yaml in the main folder") }
            if e.message.hasPrefix("--network") { throw WebAction.Invalid("fromProject: the network chosen differs from the project's preset") }
            throw WebAction.Invalid("fromProject: the main folder's doz_project.yaml cannot be read")
        }
    }

    /// The main folder's project file, as the wizard says it ("Found doz_project.yaml in DIR: its network preset …"): read
    /// on the Mac, never written; nil when there is none.
    static func project(_ w: WorkspaceRequest) -> WebWorkspacePlan.Project? {
        guard let main = WorkspaceProjectFill.mainFolder(w), let file = try? DozableProject.find(in: URL(fileURLWithPath: main)) else { return nil }
        var probe = WorkspaceRequest(name: w.name)
        probe.folders = [WorkspaceFolder(path: main)]
        let read = (try? WorkspaceProjectFill.apply(&probe, parse: { try WebProjectFiles.parse($0, file: $1) })) != nil
        return WebWorkspacePlan.Project(folder: DisplayPath.tilde(main), file: file.lastPathComponent, preset: read ? probe.network : nil,
                                        readable: read)
    }
}

/// `POST /api/v1/workspace-plan`'s answer, field by field.
public struct WebWorkspacePlan: Codable, Equatable, Sendable {
    public struct Gap: Codable, Equatable, Sendable {
        public var item: String
        public var why: String
        public var fix: String
        /// The wizard's step it belongs to: 1 the work (brief, folder, agent), 2 who manages, 4 grants & when (chat, room).
        public var step: Int
    }
    public struct Project: Codable, Equatable, Sendable {
        public var folder: String
        public var file: String
        public var preset: String?
        public var readable: Bool
    }
    public var name: String
    public var refusals: [String]
    public var gaps: [Gap]
    public var notes: [String]
    public var lines: [String]
    public var commands: String
    public var startCommand: String
    public var presets: [WorkspacePreset]
    public var project: Project?

    public static func step(_ item: String) -> Int {
        switch item {
        case "manager": 2
        case "chat", "room": 4
        default: 1
        }
    }

    public init(_ p: WorkspacePlan, project: Project? = nil) {
        name = p.name
        refusals = p.refusals
        gaps = p.gaps.map { Gap(item: $0.item, why: $0.why, fix: $0.fix, step: Self.step($0.item)) }
        notes = p.notes
        lines = p.lines
        commands = p.commands
        startCommand = p.startCommand
        presets = p.presets
        self.project = project
    }
}
