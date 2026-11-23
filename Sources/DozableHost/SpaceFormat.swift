import DozableChat
import Foundation

// The space file's format (space/3) as Swift tables: the keys each part may hold, their enums and patterns, the name rule,
// full names (doz://HOST/SPACE/TYPE/NAME), and the words the messages use. The reference's JSON Schemas
// (schema/space-3.schema.json, schema/space-defaults-3.schema.json) are vendored under Tests/DozableCLITests/Fixtures/space3
// and `SpaceSchemaDriftTests` compares every object's keys, enums, consts and patterns with these tables, so a change of
// the format is seen in one test. Hand-written on purpose: 36 of the 68 refusals are rules a schema cannot say, and the
// words are the reader's. docs/engineering/workspaces.md, "Space files".

public enum SpaceFormat {
    public static let doz = "space/3"
    public static let defaultsDoz = "space-defaults/3"
    /// 758: space/3.1 — space/3 with Dozable's keys first-class (`SpaceDozable`); a defaults file's line likewise.
    public static let doz31 = "space/3.1"
    public static let defaultsDoz31 = "space-defaults/3.1"
    /// The version lines this reader knows.
    public static let dozVersions = [doz, doz31]
    public static let defaultsDozVersions = [defaultsDoz, defaultsDoz31]
    /// space/3.1's `agent_defaults.where: sandbox`: every agent that does not say where runs in the workspace's own VM.
    public static let workspaceVM = "sandbox"

    /// `[a-z][a-z0-9-]*`: every resource's name, the space's name, a profile.
    public static func isName(_ s: String) -> Bool {
        guard let f = s.unicodeScalars.first, ("a"..."z").contains(f) else { return false }
        return s.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }

    // MARK: the keys, in the schema's order (the drift test pins them)

    public static let topKeys = ["doz", "space", "title", "brief", "owner", "extends", "agent_defaults", "permissions", "approvals",
                                 "trusted_folders", "folders", "agents", "services", "sandboxes", "secrets", "chat", "persist",
                                 "archive", "labels", "profiles"]
    public static let requiredTop = ["doz", "space", "brief", "owner"]
    /// An agent's own keys (`$defs/agent.properties`), then the settings it shares with `agent_defaults`.
    public static let agentOwnKeys = ["external", "folder", "prompt", "prompt_file", "requests"]
    public static let agentSettingsKeys = ["kind", "role", "where", "isolation", "permissions", "access", "secrets", "model",
                                           "remote_control", "chat", "transcripts", "resume", "approvals", "labels", "profiles"]
    public static var agentKeys: [String] { agentOwnKeys + agentSettingsKeys }
    /// What an external agent may not say (`dependentSchemas.external`).
    public static let agentExternalForbidden = ["kind", "where", "isolation", "permissions", "access", "secrets", "model",
                                                "remote_control", "chat", "transcripts", "resume", "approvals", "folder", "prompt",
                                                "prompt_file", "requests"]
    public static let agentDefaultsOwnKeys = ["isolation"]
    public static var agentDefaultsKeys: [String] { agentDefaultsOwnKeys + agentSettingsKeys }
    public static let requestsKeys = ["role", "grants", "reason"]
    public static let agentChatKeys = ["delivery", "rooms"]
    public static let approvalsKeys = ["deciders", "via"]
    public static let archiveKeys = ["to", "keep"]
    public static let folderKeys = ["external", "access", "trust", "optional", "labels", "profiles"]
    public static let roomKeys = ["external", "members", "main", "labels", "profiles"]
    public static let sandboxKeys = ["external", "image", "folder", "cpus", "memory", "labels", "profiles"]
    public static let sandboxExternalForbidden = ["image", "folder", "cpus", "memory"]
    public static let secretKeys = ["external", "to", "labels", "profiles"]
    public static let secretRequired = ["external", "to"]
    public static let serviceKeys = ["external", "command", "folder", "env", "ports", "health", "labels", "profiles"]
    public static let serviceExternalForbidden = ["command", "folder", "env", "ports"]
    public static let healthKeys = ["http", "tcp", "command", "interval", "timeout"]
    public static let chatKeys = ["rooms"]
    public static let persistKinds = ["room", "sandbox", "agent", "folder"]
    /// A defaults file's keys (`space-defaults-3.schema.json`).
    public static let defaultsKeys = ["doz", "extends", "persist", "archive", "approvals", "agent_defaults"]
    /// Keys that start or own something: a defaults file never holds them (and the daemon refuses them from one).
    public static let defaultsOwns = ["agents", "services", "sandboxes", "folders", "secrets", "chat", "owner"]

    // MARK: enums and patterns

    public static let kinds = ["claude-code"]
    public static let roles = ["manager", "worker", "reviewer"]
    public static let isolations = ["fenced", "unfenced"]
    public static let accesses = ["rw", "ro"]
    public static let deliveries = ["inbox", "poll"]
    public static let transcripts = ["keep", "discard"]
    public static let resumes = ["none", "summary"]
    public static let vias = ["ask"]
    public static let trusts = ["before"]
    public static let archiveKeep = ["plan", "commands", "status", "chat", "transcripts", "screens", "usage", "git"]
    /// The schema's patterns, as written there (the drift test compares the text; the checks below implement them).
    public static let patterns: [String: String] = [
        "name": "^[a-z][a-z0-9-]*$",
        "where": "^(mac|sandbox:[a-z][a-z0-9-]*)$",
        "memory": "^[0-9]+[MG]$",
        "to": "^[A-Za-z0-9.-]+(:[0-9]+)?$",
        "url": "^https?://",
        "agentExternal": "^doz://[a-z0-9][a-z0-9-]*/(_/bot|[a-z][a-z0-9-]*/agent)/[A-Za-z0-9][A-Za-z0-9._-]*$",
        "roomExternal": "^doz://[a-z0-9][a-z0-9-]*/(_|[a-z][a-z0-9-]*)/room/[A-Za-z0-9][A-Za-z0-9._-]*$",
        "sandboxExternal": "^doz://[a-z0-9][a-z0-9-]*/(_|[a-z][a-z0-9-]*)/sandbox/[A-Za-z0-9][A-Za-z0-9._-]*$",
        "serviceExternal": "^doz://[a-z0-9][a-z0-9-]*/[a-z][a-z0-9-]*/service/[A-Za-z0-9][A-Za-z0-9._-]*$",
        "sectionName": "^([a-z][a-z0-9-]*|x-.*)$",
    ]

    static func matches(_ s: String, _ pattern: String) -> Bool {
        s.range(of: patterns[pattern] ?? pattern, options: .regularExpression) != nil
    }

    // MARK: sections and full names

    /// The sections that hold named resources, in the reference's order: one namespace across all.
    public enum Section: String, CaseIterable, Sendable {
        case folders, agents, services, sandboxes, secrets, rooms
        public var pointer: String { self == .rooms ? "/chat/rooms" : "/" + rawValue }
        public var singular: String {
            switch self {
            case .folders: "folder"
            case .agents: "agent"
            case .services: "service"
            case .sandboxes: "sandbox"
            case .secrets: "secret"
            case .rooms: "room"
            }
        }
    }

    public static let fqnTypes = ["room", "agent", "sandbox", "service", "run", "bot"]

    /// `doz://HOST/SPACE/TYPE/NAME`.
    public struct FullName: Equatable, Sendable {
        public var host: String, space: String, type: String, name: String
        public var text: String { "doz://\(host)/\(space)/\(type)/\(name)" }
    }

    public static func parseFullName(_ s: String) -> FullName? {
        guard s.range(of: "^doz://[a-z0-9][a-z0-9-]*/(_|[a-z][a-z0-9-]*)/[a-z]+/[A-Za-z0-9][A-Za-z0-9._-]*$", options: .regularExpression) != nil
        else { return nil }
        let p = s.dropFirst("doz://".count).split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard p.count == 4, fqnTypes.contains(p[2]) else { return nil }
        return FullName(host: p[0], space: p[1], type: p[2], name: p[3])
    }

    // MARK: words

    /// Keys of space/2 (or drafts) that space/3 does not have, with what to write instead (the reference's table).
    public static let migration: [String: String] = [
        "lifetime": "persistence is declared under the top-level persist:, e.g. persist: { team-chat: { room: NAME } }; anything not listed lasts one run",
        "path": "an owned folder has no path: it is a scratch folder made inside the run folder. For a folder that exists, write external: PATH; for data that outlives runs, persist: { NAME: { folder: PATH } }",
        "start": "every owned agent is started; leave the agent out (or give it a profile) to not start it",
        "network": "network access is a grant: request it with requests: { grants: [\"network: HOST\"], reason: … }",
        "account": "the account is Dozable's choice for the agent; remove account:",
        "session": "an owned agent's session is named after it; an existing session is external: { session: NAME }",
        "label": "labels: { … } holds free metadata; the display name is the key",
        "depends_on": "depends_on is deferred: Dozable starts the manager, then workers in the order written",
        "grants": "a file can't grant: ask for grants with requests: { grants: [...], reason: … }, and the owner decides",
        "preset": "name the preset with permissions: NAME (on the space or the agent)",
        "request": "ask for grants on the agent: requests: { grants: [...], reason: … }",
        "as": "an agent's chat name is its key",
    ]

    /// Edit distance where swapping two neighbouring letters counts as one edit (optimal string alignment).
    public static func distance(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        let m = x.count, n = y.count
        if m == 0 { return n }
        if n == 0 { return m }
        var d = [[Int]](repeating: [Int](repeating: 0, count: n + 1), count: m + 1)
        for i in 0...m { d[i][0] = i }
        for j in 0...n { d[0][j] = j }
        for i in 1...m {
            for j in 1...n {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
                if i > 1 && j > 1 && x[i - 1] == y[j - 2] && x[i - 2] == y[j - 1] { d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1) }
            }
        }
        return d[m][n]
    }

    /// The closest candidate, if it is close enough to be a likely typo.
    public static func didYouMean(_ word: String, _ candidates: [String]) -> String? {
        var best: String?, bd = Int.max
        let w = word.lowercased()
        for c in candidates {
            let d = distance(w, c.lowercased())
            if d < bd { bd = d; best = c }
        }
        guard let best else { return nil }
        let limit = max(1, min(3, max(word.count, best.count) / 3))
        return bd <= limit ? best : nil
    }
}
