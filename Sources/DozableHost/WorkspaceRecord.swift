import Foundation

// The workspace record (`<store>/workspaces/<name>/workspace.json`, version 1): an environment, a space for work to be done, for one
// or more projects' folders — its brief, its folders,
// its rooms in the chat server and the agents adopted into it. Additive only: every field this build does not know is
// kept, at the top level and in every element of folders, rooms and agents, and a higher `version` is kept, never
// lowered — an older doz rewrites a newer one's record without losing anything. The brief's text lives in `brief.md`
// beside it; the record keeps its references and a hash. `WorkspaceStore` reads and writes it; `docs/engineering/workspaces.md`.

/// A coding key for any name — the record's own fields and the ones it keeps without knowing them.
public struct DynamicKey: CodingKey, Hashable, ExpressibleByStringLiteral {
    public var stringValue: String
    public var intValue: Int? { nil }
    public init(_ s: String) { stringValue = s }
    public init(stringValue: String) { self.stringValue = stringValue }
    public init?(intValue: Int) { nil }
    public init(stringLiteral value: String) { stringValue = value }
}

/// The fields of an object this build does not know, kept as they were read and written back unchanged.
public struct UnknownFields: Equatable, Sendable {
    public var extra: [String: JSONValue] = [:]
    public init(_ extra: [String: JSONValue] = [:]) { self.extra = extra }

    /// Every key of `c` that is not in `known`.
    public init(_ c: KeyedDecodingContainer<DynamicKey>, known: Set<String>) throws {
        for k in c.allKeys where !known.contains(k.stringValue) {
            extra[k.stringValue] = try c.decode(JSONValue.self, forKey: k)
        }
    }

    /// Written beside the known fields (a known name is never written twice).
    public func encode(_ c: inout KeyedEncodingContainer<DynamicKey>, known: Set<String>) throws {
        for (k, v) in extra where !known.contains(k) { try c.encode(v, forKey: DynamicKey(k)) }
    }
}

/// Workspace names: 1–40 of a-z, 0-9 and -, not starting with - (the sandbox rule — and so also a room's name).
public enum WorkspaceName {
    public static let maximumLength = 40

    public static func isValid(_ s: String) -> Bool {
        guard (1...maximumLength).contains(s.utf8.count), !s.hasPrefix("-") else { return false }
        return s.utf8.allSatisfy { ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2D }
    }

    /// Checked before any path is built from it.
    public static func validate(_ s: String) throws {
        guard isValid(s) else {
            throw HostError(.invalid, "\(s.prefix(60)) is not a workspace name — 1–40 characters of a-z, 0-9 and -, not starting with -")
        }
    }

    /// An agent's name in a workspace: 1–64 of A-Z, a-z, 0-9, _, . and -, not starting with - or . (a sandbox's name and a
    /// session's on this Mac both fit).
    public static func isValidAgent(_ s: String) -> Bool {
        guard (1...64).contains(s.utf8.count), !s.hasPrefix("-"), !s.hasPrefix(".") else { return false }
        return s.utf8.allSatisfy { ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2D || $0 == 0x5F || $0 == 0x2E }
    }
}

/// The brief: its references (paths and http(s) addresses), and the text's hash and size (the text is `brief.md`).
public struct WorkspaceBrief: Codable, Equatable, Sendable {
    public var refs: [String]
    public var sha256: String
    public var bytes: Int
    public var updatedAt: Date
    public init(refs: [String] = [], sha256: String, bytes: Int, updatedAt: Date) {
        self.refs = refs; self.sha256 = sha256; self.bytes = bytes; self.updatedAt = updatedAt
    }
}

/// One of the workspace's folders on this Mac: read-write or read-only; the first is the main one.
public struct WorkspaceFolder: Codable, Equatable, Sendable {
    public var path: String
    /// `rw` or `ro`.
    public var mode: String
    public var main: Bool
    public var unknown = UnknownFields()
    public static let modes = ["rw", "ro"]
    static let known: Set<String> = ["path", "mode", "main"]

    public init(path: String, mode: String = "rw", main: Bool = false) { self.path = path; self.mode = mode; self.main = main }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicKey.self)
        path = try c.decode(String.self, forKey: "path")
        mode = try c.decodeIfPresent(String.self, forKey: "mode") ?? "rw"
        main = try c.decodeIfPresent(Bool.self, forKey: "main") ?? false
        unknown = try UnknownFields(c, known: Self.known)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicKey.self)
        try unknown.encode(&c, known: Self.known)
        try c.encode(path, forKey: "path")
        try c.encode(mode, forKey: "mode")
        try c.encode(main, forKey: "main")
    }
}

/// A room of the workspace in the chat server: its short label, the server's room and whether it is the main one. Nothing
/// is posted there when it is made: the work starts later.
public struct WorkspaceRoom: Codable, Equatable, Sendable {
    public var label: String
    public var chatRoom: String
    public var main: Bool
    public var unknown = UnknownFields()
    static let known: Set<String> = ["label", "chatRoom", "main"]

    public init(label: String, chatRoom: String, main: Bool) {
        self.label = label; self.chatRoom = chatRoom; self.main = main
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicKey.self)
        label = try c.decode(String.self, forKey: "label")
        chatRoom = try c.decode(String.self, forKey: "chatRoom")
        main = try c.decodeIfPresent(Bool.self, forKey: "main") ?? false
        unknown = try UnknownFields(c, known: Self.known)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicKey.self)
        try unknown.encode(&c, known: Self.known)
        try c.encode(label, forKey: "label")
        try c.encode(chatRoom, forKey: "chatRoom")
        try c.encode(main, forKey: "main")
    }
}

/// Where an agent runs: a sandbox, a session on this Mac, or elsewhere (a later step).
public struct AgentPlace: Codable, Equatable, Sendable {
    public var sandbox: String?
    public var mac: Bool?
    public var session: String?
    public var elsewhere: String?

    public init(sandbox: String? = nil, mac: Bool? = nil, session: String? = nil, elsewhere: String? = nil) {
        self.sandbox = sandbox; self.mac = mac; self.session = session; self.elsewhere = elsewhere
    }

    public static func sandbox(_ name: String) -> AgentPlace { AgentPlace(sandbox: name) }
    public static func macSession(_ name: String) -> AgentPlace { AgentPlace(mac: true, session: name) }

    /// The membership index's key: `sandbox:NAME` or `mac:SESSION` (nil: elsewhere — not on this Mac).
    public var key: String? {
        if let s = sandbox { return "sandbox:" + s }
        if mac == true, let s = session { return "mac:" + s }
        return nil
    }

    /// As a person types it: `NAME` for a sandbox, `@mac/SESSION` for a session on this Mac.
    public var display: String {
        if let s = sandbox { return s }
        if mac == true, let s = session { return MacPlace.name + "/" + s }
        return elsewhere ?? "elsewhere"
    }
}

/// An agent in the workspace.
public struct WorkspaceAgent: Codable, Equatable, Sendable {
    public var name: String
    /// `worker` (adopted) — `manager` comes with a later step.
    public var role: String
    public var place: AgentPlace
    /// `you` or `doz`.
    public var startedBy: String
    public var startedAt: Date
    /// The Agent / Bot it is (`bots.json`), when it is one; nil: an agent with no lasting identity. Additive: an older doz
    /// keeps it as an unknown field.
    public var bot: String?
    public var unknown = UnknownFields()
    static let known: Set<String> = ["name", "role", "place", "startedBy", "startedAt", "bot"]

    public init(name: String, role: String = "worker", place: AgentPlace, startedBy: String = "you", startedAt: Date, bot: String? = nil) {
        self.name = name; self.role = role; self.place = place; self.startedBy = startedBy; self.startedAt = startedAt; self.bot = bot
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicKey.self)
        name = try c.decode(String.self, forKey: "name")
        role = try c.decodeIfPresent(String.self, forKey: "role") ?? "worker"
        place = try c.decode(AgentPlace.self, forKey: "place")
        startedBy = try c.decodeIfPresent(String.self, forKey: "startedBy") ?? "you"
        startedAt = try c.decode(Date.self, forKey: "startedAt")
        bot = try c.decodeIfPresent(String.self, forKey: "bot")
        unknown = try UnknownFields(c, known: Self.known)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicKey.self)
        try unknown.encode(&c, known: Self.known)
        try c.encode(name, forKey: "name")
        try c.encode(role, forKey: "role")
        try c.encode(place, forKey: "place")
        try c.encode(startedBy, forKey: "startedBy")
        try c.encode(startedAt, forKey: "startedAt")
        try c.encodeIfPresent(bot, forKey: "bot")
    }
}

/// What a new agent of the workspace gets unless it says otherwise.
public struct WorkspaceDefaults: Codable, Equatable, Sendable {
    public var isolation: String?
    public var network: String?
    public init(isolation: String? = nil, network: String? = nil) { self.isolation = isolation; self.network = network }
}

/// The states that are recorded rather than derived.
public struct WorkspaceFlags: Codable, Equatable, Sendable {
    public var finishedAt: Date?
    public var archivedAt: Date?
    /// When it first had an agent: an empty workspace that once had agents is asleep, not setting up.
    public var firstAgentAt: Date?
    public init(finishedAt: Date? = nil, archivedAt: Date? = nil, firstAgentAt: Date? = nil) {
        self.finishedAt = finishedAt; self.archivedAt = archivedAt; self.firstAgentAt = firstAgentAt
    }
}

/// How it came to be: `new`, `adopted` or `project` (from a doz_project.yaml — its path).
public struct WorkspaceOrigin: Codable, Equatable, Sendable {
    public var kind: String
    public var project: String?
    public init(kind: String = "new", project: String? = nil) { self.kind = kind; self.project = project }
}

/// `workspace.json`.
public struct WorkspaceRecord: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    /// Kept as read — a newer doz's record keeps its version.
    public var version: Int
    public var name: String
    public var createdAt: Date
    public var brief: WorkspaceBrief
    public var folders: [WorkspaceFolder]
    public var rooms: [WorkspaceRoom]
    public var agents: [WorkspaceAgent]
    public var defaults: WorkspaceDefaults
    public var flags: WorkspaceFlags
    /// Who drives it: always `you` in this version.
    public var driver: String
    public var origin: WorkspaceOrigin
    public var unknown = UnknownFields()
    static let known: Set<String> = ["version", "name", "createdAt", "brief", "folders", "rooms", "agents", "defaults", "flags", "driver", "origin"]

    public init(name: String, createdAt: Date, brief: WorkspaceBrief, folders: [WorkspaceFolder], rooms: [WorkspaceRoom] = [],
                agents: [WorkspaceAgent] = [], defaults: WorkspaceDefaults = WorkspaceDefaults(), flags: WorkspaceFlags = WorkspaceFlags(),
                driver: String = "you", origin: WorkspaceOrigin = WorkspaceOrigin()) {
        version = Self.currentVersion
        self.name = name; self.createdAt = createdAt; self.brief = brief; self.folders = folders; self.rooms = rooms
        self.agents = agents; self.defaults = defaults; self.flags = flags; self.driver = driver; self.origin = origin
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicKey.self)
        version = try c.decodeIfPresent(Int.self, forKey: "version") ?? 1
        name = try c.decode(String.self, forKey: "name")
        createdAt = try c.decode(Date.self, forKey: "createdAt")
        brief = try c.decode(WorkspaceBrief.self, forKey: "brief")
        folders = try c.decodeIfPresent([WorkspaceFolder].self, forKey: "folders") ?? []
        rooms = try c.decodeIfPresent([WorkspaceRoom].self, forKey: "rooms") ?? []
        agents = try c.decodeIfPresent([WorkspaceAgent].self, forKey: "agents") ?? []
        defaults = try c.decodeIfPresent(WorkspaceDefaults.self, forKey: "defaults") ?? WorkspaceDefaults()
        flags = try c.decodeIfPresent(WorkspaceFlags.self, forKey: "flags") ?? WorkspaceFlags()
        driver = try c.decodeIfPresent(String.self, forKey: "driver") ?? "you"
        origin = try c.decodeIfPresent(WorkspaceOrigin.self, forKey: "origin") ?? WorkspaceOrigin()
        unknown = try UnknownFields(c, known: Self.known)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicKey.self)
        try unknown.encode(&c, known: Self.known)
        try c.encode(max(version, Self.currentVersion), forKey: "version")
        try c.encode(name, forKey: "name")
        try c.encode(createdAt, forKey: "createdAt")
        try c.encode(brief, forKey: "brief")
        try c.encode(folders, forKey: "folders")
        try c.encode(rooms, forKey: "rooms")
        try c.encode(agents, forKey: "agents")
        try c.encode(defaults, forKey: "defaults")
        try c.encode(flags, forKey: "flags")
        try c.encode(driver, forKey: "driver")
        try c.encode(origin, forKey: "origin")
    }

    /// The main room (nil: none).
    public var mainRoom: WorkspaceRoom? { rooms.first { $0.main } ?? rooms.first }
    /// The main folder.
    public var mainFolder: WorkspaceFolder? { folders.first { $0.main } ?? folders.first }

    /// The agent a person names: by its name, else by its place as typed (`wsa`, `@mac/wsu`).
    public func agentIndex(_ s: String) -> Int? {
        agents.firstIndex { $0.name == s } ?? agents.firstIndex { $0.place.display == s }
    }
}

/// One line of `log.jsonl`: what happened, when and by whom (`you` or `doz`). Never the brief's text, a token or a path
/// outside the store — counts, hashes and names only.
public struct WorkspaceLogEntry: Codable, Equatable, Sendable {
    public var v: Int
    public var at: Date
    /// `you` or `doz`.
    public var by: String
    /// created · room-made · room-linked · adopted · released · brief-edited ·
    /// folders-edited · refs-edited · renamed · agent-renamed · agent-removed.
    public var action: String
    public var agent: String?
    /// The agent's place key (`sandbox:NAME`, `mac:SESSION`).
    public var place: String?
    public var room: String?
    public var from: String?
    public var to: String?
    public var sha256: String?
    public var bytes: Int?
    public var added: Int?
    public var removed: Int?
    /// Why, in a person's words (never the brief).
    public var reason: String?

    public init(at: Date = Date(), by: String = "you", action: String, agent: String? = nil, place: String? = nil, room: String? = nil,
                from: String? = nil, to: String? = nil, sha256: String? = nil, bytes: Int? = nil, added: Int? = nil, removed: Int? = nil,
                reason: String? = nil) {
        v = 1
        self.at = at; self.by = by; self.action = action; self.agent = agent; self.place = place; self.room = room
        self.from = from; self.to = to; self.sha256 = sha256; self.bytes = bytes; self.added = added; self.removed = removed
        self.reason = reason
    }

    public static let actions: Set<String> = ["created", "room-made", "room-linked", "adopted",
                                              "released", "brief-edited", "folders-edited", "refs-edited", "renamed", "agent-renamed",
                                              "agent-removed"]

    /// The line as a person reads it.
    public var sentence: String {
        switch action {
        case "created": return "created"
        case "room-made": return "made the room \(room ?? "?")"
        case "room-linked": return "linked the room \(room ?? "?")"
        case "adopted": return "adopted \(agent ?? "?")" + (place.map { " (\($0))" } ?? "")
        case "released": return "released \(agent ?? "?")"
        case "brief-edited": return "edited the brief (\(bytes ?? 0) bytes)"
        case "folders-edited": return "folders: \(added ?? 0) added, \(removed ?? 0) removed"
        case "refs-edited": return "references: \(added ?? 0) added, \(removed ?? 0) removed"
        case "renamed": return "renamed from \(from ?? "?") to \(to ?? "?")"
        case "agent-renamed": return "agent \(from ?? "?") is now \(to ?? "?")"
        case "agent-removed": return "agent \(agent ?? "?") removed (its sandbox was deleted)"
        default: return action
        }
    }
}
