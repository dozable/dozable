import Foundation

/// 782 — the workspace templates doz carries (the New workspace wizard's gallery, `doz workspace templates`, `doz workspace
/// new --template ID`): each a folder `templates/ID/` in the package's resource bundle beside `skills/`, found the way the
/// skills are (`ShippedSkills`), read-only — the next install replaces them. A template is three files:
/// - `template.json` — what the gallery reads (`WorkspaceTemplate`: the page never parses YAML);
/// - `space.yaml` — a space/3.1 file with four placeholders, `{{space}}`, `{{owner}}` (your name in chat), `{{manager}}` and
///   `{{folder}}` (not `${…}`: that is a space file's own environment substitution), rendered by
///   `render` (each value JSON-quoted, so a path never changes the YAML around it);
/// - `DESCRIPTION.md` — what is posted in the room when it starts.
/// No template runs an agent unfenced (a built-in never acts as you); one that needs a manager takes your bot
/// (`external: {bot: …}` — space files refuse an owned manager). docs/engineering/workspaces.md, "Workspace templates".
public struct WorkspaceTemplate: Codable, Equatable, Sendable {
    public struct Needs: Codable, Equatable, Sendable {
        public var manager: Bool
        public init(manager: Bool) { self.manager = manager }
    }
    /// One agent as the full view lists it: its name, its role, where it runs (`manager`: where your bot runs; `sandbox`;
    /// `fenced`), and whether it only reads.
    public struct Agent: Codable, Equatable, Sendable {
        public var name: String
        public var role: String
        public var `where`: String
        public var readOnly: Bool?
        public init(name: String, role: String, where w: String, readOnly: Bool? = nil) {
            self.name = name; self.role = role; self.where = w; self.readOnly = readOnly
        }
    }
    public var id: String
    public var version: Int
    public var title: String
    public var summary: String
    public var needs: Needs
    public var agents: [Agent]
    /// The room in words ("you and all 3 agents"); the network in one line ("Standard + npm").
    public var room: String
    public var network: String
    /// The drawing, in the dashboard's renderer's words — filled by `doz ui` from `space.yaml` (never in the file).
    public var picture: String?
}

public enum WorkspaceTemplates {
    public static let folder = "templates"
    public static let placeholders = ["space", "owner", "manager", "folder", "who"]
    /// The longest agent name a template gives (`reviewer`, `renderer`): a prefix leaves room for it under chat's 40.
    static let longestAgent = 8

    /// `{{who}}`: the prefix of the template's own agents' names — chat names are global, so two workspaces from one
    /// template must not share them. The workspace's name, cut to leave room for `-reviewer` under chat's 40 characters, and
    /// starting with a letter (a chat name's rule).
    public static func who(_ space: String) -> String {
        var w = String(space.prefix(40 - longestAgent - 1))
        while w.hasSuffix("-") { w.removeLast() }
        if let f = w.unicodeScalars.first, !("a"..."z").contains(f) { w = "w" + w.prefix(40 - longestAgent - 2) }
        return w.isEmpty ? "w" : w
    }
    /// The names a gallery's drawing is rendered with.
    public static let sample = (space: "workspace", owner: "you", manager: "manager", folder: "/work")

    /// The `templates` folder of the first resource bundle that has one (nil: this build carries none).
    public static func directory() -> URL? {
        let fm = FileManager.default
        for bundle in DeckholdBinary.candidateBundleDirectories() {
            for rel in ["Contents/Resources/\(folder)", folder] {
                let url = bundle.appendingPathComponent(rel)
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue { return url.standardizedFileURL }
            }
        }
        return nil
    }

    /// An id is a plain folder name (a-z, 0-9, -), never a path.
    public static func isID(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 40 && s.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }

    /// Every template this build carries, in the gallery's order (`order` in the folder, else by id).
    public static func list(in dir: URL? = directory()) -> [WorkspaceTemplate] {
        guard let dir, let items = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        let order = (try? String(contentsOf: dir.appendingPathComponent("ORDER"), encoding: .utf8))?
            .split(separator: "\n").map(String.init).filter { !$0.isEmpty } ?? []
        let ids = items.filter { isID($0) && FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).appendingPathComponent("template.json").path) }
        return ids.sorted { (order.firstIndex(of: $0) ?? Int.max, $0) < (order.firstIndex(of: $1) ?? Int.max, $1) }
            .compactMap { try? read($0, in: dir) }
    }

    /// One template's `template.json`.
    public static func read(_ id: String, in dir: URL? = directory()) throws -> WorkspaceTemplate {
        guard isID(id), let dir else { throw TemplateError.notFound(id) }
        let url = dir.appendingPathComponent(id).appendingPathComponent("template.json")
        guard let d = FileManager.default.contents(atPath: url.path) else { throw TemplateError.notFound(id) }
        let t = try JSONDecoder().decode(WorkspaceTemplate.self, from: d)
        guard t.id == id else { throw TemplateError.invalid("\(id)/template.json names \(t.id)") }
        return t
    }

    /// A template's space file and description, rendered: `{{space}}`, `{{manager}}`, `{{folder}}` each replaced by its
    /// value as a JSON string (YAML reads it). A placeholder left over, or a template that needs a manager given none, throws.
    /// `bareNames`: the agents' names without their prefix (`{{who}}-` left out) — the gallery's drawing, never a workspace.
    public static func render(_ id: String, space: String, owner: String, manager: String?, folder: String, bareNames: Bool = false,
                              in dir: URL? = directory()) throws -> (space: String, description: String) {
        let t = try read(id, in: dir)
        if t.needs.manager, manager == nil { throw TemplateError.invalid("\(t.title) needs a manager: one of your bots") }
        let base = dir!.appendingPathComponent(id)
        guard let yaml = try? String(contentsOf: base.appendingPathComponent("space.yaml"), encoding: .utf8),
              let desc = try? String(contentsOf: base.appendingPathComponent("DESCRIPTION.md"), encoding: .utf8) else {
            throw TemplateError.invalid("\(id) is missing a file")
        }
        func q(_ s: String) -> String {
            let d = (try? JSONEncoder().encode(s)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
            return d.replacingOccurrences(of: "\\/", with: "/")
        }
        var out = yaml
        // `{{who}}` raw (a chat name's characters only), before the quoted ones.
        out = bareNames ? out.replacingOccurrences(of: "{{who}}-", with: "") : out.replacingOccurrences(of: "{{who}}", with: who(space))
        out = out.replacingOccurrences(of: "{{space}}", with: q(space))
        out = out.replacingOccurrences(of: "{{owner}}", with: q(owner))
        out = out.replacingOccurrences(of: "{{manager}}", with: q(manager ?? ""))
        out = out.replacingOccurrences(of: "{{folder}}", with: q(folder))
        guard !out.contains("{{") else { throw TemplateError.invalid("\(id)/space.yaml has a placeholder doz does not fill") }
        return (out, desc)
    }

    public enum TemplateError: Error, CustomStringConvertible, Equatable {
        case notFound(String)
        case invalid(String)
        public var description: String {
            switch self {
            case .notFound(let id): "no template \(id.prefix(40)) — doz workspace templates lists them"
            case .invalid(let why): why
            }
        }
    }
}
