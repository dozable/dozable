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
    /// 767: no identity may be named `owner` — it names you in a run's journal (`by`). Refused (65) wherever a name is
    /// given to a new agent; a record that already holds one is read as it is.
    public static let reservedAgentName = "owner"

    /// A new agent's name: refused when it is the reserved one.
    public static func checkNewAgent(_ s: String) throws {
        if s == reservedAgentName { throw HostError(.invalidValue, "\"owner\" can't be an agent's name: it names you in a run's journal — pick another") }
    }

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
    /// The room's id in the room index (`rm_<16 hex>`, `ChatRoomIndex`): a room made again under the same name is another
    /// room. nil: not known yet (a record written before ids). Additive.
    public var id: String?
    /// The workspace made it (true) or linked an existing one (false); nil: read once from the log (`room-made` is owned,
    /// `room-linked` is not — `WorkspaceRuns.owned`). Only an owned room is closed at finish, archived or removed. Additive.
    public var owned: Bool?
    /// When the room was removed for good (`doz chat room rm`): its tombstone is in the room index. Additive.
    public var goneAt: Date?
    public var unknown = UnknownFields()
    static let known: Set<String> = ["label", "chatRoom", "main", "id", "owned", "goneAt"]

    public init(label: String, chatRoom: String, main: Bool, id: String? = nil, owned: Bool? = nil) {
        self.label = label; self.chatRoom = chatRoom; self.main = main; self.id = id; self.owned = owned
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicKey.self)
        label = try c.decode(String.self, forKey: "label")
        chatRoom = try c.decode(String.self, forKey: "chatRoom")
        main = try c.decodeIfPresent(Bool.self, forKey: "main") ?? false
        id = try c.decodeIfPresent(String.self, forKey: "id")
        owned = try c.decodeIfPresent(Bool.self, forKey: "owned")
        goneAt = try c.decodeIfPresent(Date.self, forKey: "goneAt")
        unknown = try UnknownFields(c, known: Self.known)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicKey.self)
        try unknown.encode(&c, known: Self.known)
        try c.encode(label, forKey: "label")
        try c.encode(chatRoom, forKey: "chatRoom")
        try c.encode(main, forKey: "main")
        try c.encodeIfPresent(id, forKey: "id")
        try c.encodeIfPresent(owned, forKey: "owned")
        try c.encodeIfPresent(goneAt, forKey: "goneAt")
    }
}

/// One room's part of a run: the room's last seq when the run opened (`fromSeq`) and when the room was closed at its end
/// (`toSeq`, the close's answer under the chat server's lock). The run's messages are exactly `fromSeq < seq <= toSeq`.
/// Nothing is posted to mark a run: the markers are data.
public struct WorkspaceRunRoom: Codable, Equatable, Sendable {
    public var room: String
    public var id: String?
    public var fromSeq: Int64
    public var toSeq: Int64?
    public var unknown = UnknownFields()
    static let known: Set<String> = ["room", "id", "fromSeq", "toSeq"]

    public init(room: String, id: String? = nil, fromSeq: Int64, toSeq: Int64? = nil) {
        self.room = room; self.id = id; self.fromSeq = fromSeq; self.toSeq = toSeq
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicKey.self)
        room = try c.decode(String.self, forKey: "room")
        id = try c.decodeIfPresent(String.self, forKey: "id")
        fromSeq = try c.decodeIfPresent(Int64.self, forKey: "fromSeq") ?? 0
        toSeq = try c.decodeIfPresent(Int64.self, forKey: "toSeq")
        unknown = try UnknownFields(c, known: Self.known)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicKey.self)
        try unknown.encode(&c, known: Self.known)
        try c.encode(room, forKey: "room")
        try c.encodeIfPresent(id, forKey: "id")
        try c.encode(fromSeq, forKey: "fromSeq")
        try c.encodeIfPresent(toSeq, forKey: "toSeq")
    }
}

/// One run: a start (or a reopen) to its finish (or archive). Sleep, wake, stop and start inside a run never close it.
/// Its id is `YYYY-MM-DD-N` (local day; N unique within the record). Additive.
public struct WorkspaceRun: Codable, Equatable, Sendable {
    public var id: String
    public var startedAt: Date
    public var endedAt: Date?
    /// Its evidence archive, relative to the store (`archives/<workspace>/runs/<id>`); nil: none written.
    public var archive: String?
    public var rooms: [WorkspaceRunRoom]
    /// The archive's `manifest.json` sha256, as written and re-hashed.
    public var archiveSHA256: String?
    /// Why the archive could not be written (`doz workspace runs W --archive RUN` writes it again).
    public var archiveProblem: String?
    /// `finish` or `archive` (the verb that closed it).
    public var closedBy: String?
    /// A run that began before runs were kept: opened at its finish, its start the workspace's first start.
    public var legacy: Bool?
    /// Finish was asked not to write an archive (`--no-archive`).
    public var noArchive: Bool?
    /// A space's run past its frames' bound (2,000 frames or 16 MiB): only `frames/last.json` was rewritten after it.
    public var framesCapped: Bool?
    /// 765 (the run verb): what the run is for — the goal given, else the brief as it read it (`goalFrom`: `given` or
    /// `brief`); what started it (`source`); the run it follows; who opened it (`owner`, or an agent's name); and the
    /// revision of the work description (the brief and its references) it read. A run opened before 765 has none of them —
    /// never filled in after the fact.
    public var goal: String?
    public var goalFrom: String?
    public var source: WorkspaceRunSource?
    public var follows: String?
    public var openedBy: String?
    public var revision: Int?
    /// 771: how many accepted lessons (the work description's addenda) its opening message carried. Additive: a run opened
    /// before has none.
    public var lessons: Int?
    public var unknown = UnknownFields()
    static let known: Set<String> = ["id", "startedAt", "endedAt", "archive", "rooms", "archiveSHA256", "archiveProblem", "closedBy", "legacy", "noArchive",
                                     "framesCapped", "goal", "goalFrom", "source", "follows", "openedBy", "revision", "lessons"]

    public init(id: String, startedAt: Date, rooms: [WorkspaceRunRoom] = []) { self.id = id; self.startedAt = startedAt; self.rooms = rooms }

    public var isOpen: Bool { endedAt == nil }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicKey.self)
        id = try c.decode(String.self, forKey: "id")
        startedAt = try c.decode(Date.self, forKey: "startedAt")
        endedAt = try c.decodeIfPresent(Date.self, forKey: "endedAt")
        archive = try c.decodeIfPresent(String.self, forKey: "archive")
        rooms = try c.decodeIfPresent([WorkspaceRunRoom].self, forKey: "rooms") ?? []
        archiveSHA256 = try c.decodeIfPresent(String.self, forKey: "archiveSHA256")
        archiveProblem = try c.decodeIfPresent(String.self, forKey: "archiveProblem")
        closedBy = try c.decodeIfPresent(String.self, forKey: "closedBy")
        legacy = try c.decodeIfPresent(Bool.self, forKey: "legacy")
        noArchive = try c.decodeIfPresent(Bool.self, forKey: "noArchive")
        framesCapped = try c.decodeIfPresent(Bool.self, forKey: "framesCapped")
        goal = try c.decodeIfPresent(String.self, forKey: "goal")
        goalFrom = try c.decodeIfPresent(String.self, forKey: "goalFrom")
        source = try c.decodeIfPresent(WorkspaceRunSource.self, forKey: "source")
        follows = try c.decodeIfPresent(String.self, forKey: "follows")
        openedBy = try c.decodeIfPresent(String.self, forKey: "openedBy")
        revision = try c.decodeIfPresent(Int.self, forKey: "revision")
        lessons = try c.decodeIfPresent(Int.self, forKey: "lessons")
        unknown = try UnknownFields(c, known: Self.known)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicKey.self)
        try unknown.encode(&c, known: Self.known)
        try c.encode(id, forKey: "id")
        try c.encode(startedAt, forKey: "startedAt")
        try c.encodeIfPresent(endedAt, forKey: "endedAt")
        try c.encodeIfPresent(archive, forKey: "archive")
        try c.encode(rooms, forKey: "rooms")
        try c.encodeIfPresent(archiveSHA256, forKey: "archiveSHA256")
        try c.encodeIfPresent(archiveProblem, forKey: "archiveProblem")
        try c.encodeIfPresent(closedBy, forKey: "closedBy")
        try c.encodeIfPresent(legacy, forKey: "legacy")
        try c.encodeIfPresent(noArchive, forKey: "noArchive")
        try c.encodeIfPresent(framesCapped, forKey: "framesCapped")
        try c.encodeIfPresent(goal, forKey: "goal")
        try c.encodeIfPresent(goalFrom, forKey: "goalFrom")
        try c.encodeIfPresent(source, forKey: "source")
        try c.encodeIfPresent(follows, forKey: "follows")
        try c.encodeIfPresent(openedBy, forKey: "openedBy")
        try c.encodeIfPresent(revision, forKey: "revision")
        try c.encodeIfPresent(lessons, forKey: "lessons")
    }
}

/// 765: what started a run — `given` (a goal typed), `brief` (no goal: the brief, at `revision`), `run` (another run, `ref`
/// its id), `ask` or `schedule` (`ref` free text).
public struct WorkspaceRunSource: Codable, Equatable, Sendable {
    public var kind: String
    public var ref: String?
    public var revision: Int?
    public init(kind: String, ref: String? = nil, revision: Int? = nil) { self.kind = kind; self.ref = ref; self.revision = revision }
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
    /// `worker` (adopted) or `manager` (recorded by `--manager`, started by `doz workspace start`).
    public var role: String
    public var place: AgentPlace
    /// `you` or `doz`.
    public var startedBy: String
    public var startedAt: Date
    /// The Agent / Bot it is (`bots.json`), when it is one; nil: an agent with no lasting identity. Additive: an older doz
    /// keeps it as an unknown field.
    public var bot: String?
    /// A manager's isolation: `fenced`, `vm` or `unfenced` (unfenced only when named — it acts as you). Additive.
    public var isolation: String?
    /// When it was last stopped or put to sleep (`doz workspace stop` — a manager —, `sleep`, `finish` — any agent); nil while it
    /// runs, before its first start, and after a wake. Additive.
    public var stoppedAt: Date?
    /// A worker's task (`doz worker add --task`): what it was brought up to do. Set only on a worker; additive.
    public var task: String?
    /// A worker with no lasting identity: its chat participant is a throwaway one, removed at `doz worker end`. Additive.
    public var anonymous: Bool?
    /// A worker being added: set before anything is made, cleared once it runs (a daemon's start sweeps one left behind).
    public var pendingAt: Date?
    /// When a worker was ended (`doz worker end`): it is no longer an agent of the workspace; its entry is kept. Additive.
    public var endedAt: Date?
    /// The template kept of its sandbox when it was removed at an archive (`--remove-sandboxes --keep-templates`). Additive.
    public var template: String?
    /// 771: an adopted agent's own chat participant (its name), made at adoption: what the chat server's relay knows it by.
    /// A manager or worker is its participant already (its bot's, or the daemon-made one of its name). Additive.
    public var participant: String?
    /// 771: the fingerprint of an adopted agent's chat token, held in its own keychain item (`AdoptedToken`) and delivered
    /// to every session Dozable starts in its place from the adoption on. Never the value. Additive.
    public var tokenFingerprint: String?
    /// 774: the declared place it runs in (a space file's `x-dozable.places` entry, by name): a fenced place is a policy, and
    /// this agent's session has its own fence built from it. nil: no declared place — its place is derived from `place`
    /// (`WorkspacePlaces.derived`). Additive.
    public var placeName: String?
    public var unknown = UnknownFields()
    static let known: Set<String> = ["name", "role", "place", "startedBy", "startedAt", "bot", "isolation", "stoppedAt", "task", "anonymous",
                                     "pendingAt", "endedAt", "template", "participant", "tokenFingerprint", "placeName"]

    public init(name: String, role: String = "worker", place: AgentPlace, startedBy: String = "you", startedAt: Date, bot: String? = nil,
                isolation: String? = nil) {
        self.name = name; self.role = role; self.place = place; self.startedBy = startedBy; self.startedAt = startedAt; self.bot = bot
        self.isolation = isolation
    }

    /// The workspace's manager (one at most).
    public var isManager: Bool { role == "manager" }
    /// A worker brought up by `doz worker add` (it has a task) — not an adopted agent.
    public var isWorker: Bool { role == "worker" && task != nil }
    /// A worker that has not been ended (pending or running).
    public var isLiveWorker: Bool { isWorker && endedAt == nil }
    /// An unfenced manager or worker acts as you: said wherever it shows.
    public var actsAsYou: Bool { (isManager || isWorker) && isolation == "unfenced" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicKey.self)
        name = try c.decode(String.self, forKey: "name")
        role = try c.decodeIfPresent(String.self, forKey: "role") ?? "worker"
        place = try c.decode(AgentPlace.self, forKey: "place")
        startedBy = try c.decodeIfPresent(String.self, forKey: "startedBy") ?? "you"
        startedAt = try c.decode(Date.self, forKey: "startedAt")
        bot = try c.decodeIfPresent(String.self, forKey: "bot")
        isolation = try c.decodeIfPresent(String.self, forKey: "isolation")
        stoppedAt = try c.decodeIfPresent(Date.self, forKey: "stoppedAt")
        task = try c.decodeIfPresent(String.self, forKey: "task")
        anonymous = try c.decodeIfPresent(Bool.self, forKey: "anonymous")
        pendingAt = try c.decodeIfPresent(Date.self, forKey: "pendingAt")
        endedAt = try c.decodeIfPresent(Date.self, forKey: "endedAt")
        template = try c.decodeIfPresent(String.self, forKey: "template")
        participant = try c.decodeIfPresent(String.self, forKey: "participant")
        tokenFingerprint = try c.decodeIfPresent(String.self, forKey: "tokenFingerprint")
        placeName = try c.decodeIfPresent(String.self, forKey: "placeName")
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
        try c.encodeIfPresent(isolation, forKey: "isolation")
        try c.encodeIfPresent(stoppedAt, forKey: "stoppedAt")
        try c.encodeIfPresent(task, forKey: "task")
        try c.encodeIfPresent(anonymous, forKey: "anonymous")
        try c.encodeIfPresent(pendingAt, forKey: "pendingAt")
        try c.encodeIfPresent(endedAt, forKey: "endedAt")
        try c.encodeIfPresent(template, forKey: "template")
        try c.encodeIfPresent(participant, forKey: "participant")
        try c.encodeIfPresent(tokenFingerprint, forKey: "tokenFingerprint")
        try c.encodeIfPresent(placeName, forKey: "placeName")
    }
}

/// A worker declared at `doz workspace new --worker TASK`: recorded while the workspace is setting up and started by
/// `doz workspace start` (as `doz worker add W NAME --task TASK` would, with the workspace's default isolation); its entry
/// goes once it runs. `name` is the one it is meant to get — the first free `botN` when it was declared; a start that finds
/// it taken by then gives it the next free one. Additive: an older doz keeps the list as an unknown field.
public struct WorkspaceDeclaredWorker: Codable, Equatable, Sendable {
    public var name: String
    public var task: String
    public var declaredAt: Date
    public init(name: String, task: String, declaredAt: Date) { self.name = name; self.task = task; self.declaredAt = declaredAt }
}

/// What a new agent of the workspace gets unless it says otherwise.
public struct WorkspaceDefaults: Codable, Equatable, Sendable {
    public var isolation: String?
    public var network: String?
    public init(isolation: String? = nil, network: String? = nil) { self.isolation = isolation; self.network = network }
}

/// What an archive put away, so a restore undoes exactly that: the rooms it archived (by their chat names), the sandboxes it
/// removed, and the template kept of each (sandbox → template).
public struct WorkspaceArchive: Codable, Equatable, Sendable {
    public var rooms: [String]
    public var removed: [String]
    public var templates: [String: String]
    public init(rooms: [String] = [], removed: [String] = [], templates: [String: String] = [:]) {
        self.rooms = rooms; self.removed = removed; self.templates = templates
    }
}

/// The states that are recorded rather than derived. Additive: a field this build does not know is kept.
public struct WorkspaceFlags: Codable, Equatable, Sendable {
    public var finishedAt: Date?
    public var archivedAt: Date?
    /// When it first had a RUNNING agent (adopted while it ran): it is past setting up.
    public var firstAgentAt: Date?
    /// When `doz workspace start` first kicked it off (the brief posted as your first message): it is past setting up, and
    /// the brief is never posted again. Additive.
    public var startedAt: Date?
    /// When it was last reopened after a finish (`doz workspace reopen`). Additive.
    public var reopenedAt: Date?
    /// What its archive put away (nil: never archived, or restored). Additive.
    public var archive: WorkspaceArchive?
    public var unknown = UnknownFields()
    static let known: Set<String> = ["finishedAt", "archivedAt", "firstAgentAt", "startedAt", "reopenedAt", "archive"]

    public init(finishedAt: Date? = nil, archivedAt: Date? = nil, firstAgentAt: Date? = nil, startedAt: Date? = nil) {
        self.finishedAt = finishedAt; self.archivedAt = archivedAt; self.firstAgentAt = firstAgentAt; self.startedAt = startedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicKey.self)
        finishedAt = try c.decodeIfPresent(Date.self, forKey: "finishedAt")
        archivedAt = try c.decodeIfPresent(Date.self, forKey: "archivedAt")
        firstAgentAt = try c.decodeIfPresent(Date.self, forKey: "firstAgentAt")
        startedAt = try c.decodeIfPresent(Date.self, forKey: "startedAt")
        reopenedAt = try c.decodeIfPresent(Date.self, forKey: "reopenedAt")
        archive = try c.decodeIfPresent(WorkspaceArchive.self, forKey: "archive")
        unknown = try UnknownFields(c, known: Self.known)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicKey.self)
        try unknown.encode(&c, known: Self.known)
        try c.encodeIfPresent(finishedAt, forKey: "finishedAt")
        try c.encodeIfPresent(archivedAt, forKey: "archivedAt")
        try c.encodeIfPresent(firstAgentAt, forKey: "firstAgentAt")
        try c.encodeIfPresent(startedAt, forKey: "startedAt")
        try c.encodeIfPresent(reopenedAt, forKey: "reopenedAt")
        try c.encodeIfPresent(archive, forKey: "archive")
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
    /// Its runs, oldest first (`WorkspaceRuns`). Additive: written only once there is one.
    public var runs: [WorkspaceRun] = []
    /// Its own grants and ceiling (`GrantModel`; nil: none ever set). Additive: an older doz keeps it as an unknown field.
    public var permissions: WorkspaceGrants?
    /// The workers declared at `new` that `start` has not started yet (`WorkspaceDeclaredWorker`). Additive: written only
    /// while there is one.
    public var declaredWorkers: [WorkspaceDeclaredWorker] = []
    /// The folders this workspace MADE on this Mac (resolved paths): `new --new-folder`'s `<projects_dir>/NAME`, recorded
    /// only when `new` made it (one already there is the person's). With a space file's scratch folders (its reference's
    /// `scratch`) these are the only folders `delete --bin-folders` may move to the Bin (`WorkspaceLifecycle.binDecision`).
    /// Written only by the daemon, never taken from a request (a `WorkspaceFolder` in a request carries no such claim).
    /// Additive: written only while there is one; a record from before it has none, so its folders are all kept.
    public var madeFolders: [String] = []
    /// 766: the work description's addenda — lessons and notes appended to the brief without rewriting it, oldest first
    /// (`WorkspaceAddendum`; the document shows them as `brief.addenda`). Additive: written only while there is one; an
    /// older doz keeps it as an unknown field.
    public var addenda: [WorkspaceAddendum] = []
    public var unknown = UnknownFields()
    static let known: Set<String> = ["version", "name", "createdAt", "brief", "folders", "rooms", "agents", "defaults", "flags", "driver", "origin", "runs",
                                     "permissions", "declaredWorkers", "madeFolders", "addenda"]

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
        runs = try c.decodeIfPresent([WorkspaceRun].self, forKey: "runs") ?? []
        permissions = try c.decodeIfPresent(WorkspaceGrants.self, forKey: "permissions")
        declaredWorkers = try c.decodeIfPresent([WorkspaceDeclaredWorker].self, forKey: "declaredWorkers") ?? []
        madeFolders = try c.decodeIfPresent([String].self, forKey: "madeFolders") ?? []
        addenda = try c.decodeIfPresent([WorkspaceAddendum].self, forKey: "addenda") ?? []
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
        if !runs.isEmpty { try c.encode(runs, forKey: "runs") }
        try c.encodeIfPresent(permissions, forKey: "permissions")
        if !declaredWorkers.isEmpty { try c.encode(declaredWorkers, forKey: "declaredWorkers") }
        if !madeFolders.isEmpty { try c.encode(madeFolders, forKey: "madeFolders") }
        if !addenda.isEmpty { try c.encode(addenda, forKey: "addenda") }
    }

    /// The open run's index (nil: none open).
    public var openRunIndex: Int? { runs.lastIndex { $0.isOpen } }
    public var openRun: WorkspaceRun? { openRunIndex.map { runs[$0] } }

    /// The main room (nil: none).
    public var mainRoom: WorkspaceRoom? { rooms.first { $0.main } ?? rooms.first }
    /// The main folder.
    public var mainFolder: WorkspaceFolder? { folders.first { $0.main } ?? folders.first }

    /// The manager's entry (nil: none).
    public var managerIndex: Int? { agents.firstIndex { $0.isManager } }
    public var manager: WorkspaceAgent? { managerIndex.map { agents[$0] } }

    /// The agent a person names: by its name, else by its place as typed (`wsa`, `@mac/wsu`). An ended worker's entry
    /// is found only when nothing else answers to the name.
    public func agentIndex(_ s: String) -> Int? {
        agents.firstIndex { $0.name == s && $0.endedAt == nil } ?? agents.firstIndex { $0.name == s }
            ?? agents.firstIndex { $0.place.display == s }
    }

    /// The live worker called `name` (nil: none).
    public func liveWorkerIndex(_ name: String) -> Int? { agents.firstIndex { $0.name == name && $0.isLiveWorker } }
}

/// One line of `log.jsonl`: what happened, when and by whom (`you` or `doz`). Never the brief's text, a token or a path
/// outside the store — counts, hashes and names only.
public struct WorkspaceLogEntry: Codable, Equatable, Sendable {
    public var v: Int
    public var at: Date
    /// `you` or `doz`.
    public var by: String
    /// created · room-made · room-linked · adopted · released · brief-edited ·
    /// folders-edited · refs-edited · renamed · agent-renamed · agent-removed · manager-set · manager-removed ·
    /// bot-invited · agent-joined (749: an agent became a member of the main room — `<name> joined`) · agent-crashed (749: its
    /// program on this Mac exited non-zero with no end asked — `<name> crashed: exit <code>`) · kicked-off · manager-started · manager-stopped · worker-added · worker-ended · worker-add-undone ·
    /// brief-announced (an edit after the start, posted as you in `room`) · bot-changed (a running bot's instructions, model or
    /// account changed — `reason` says which —, told as you in `room`) · the lifecycle: slept · woke · agent-slept · agent-woke ·
    /// finished · reopened · archived · room-archived · room-unarchived · worker-retired · sandbox-removed · template-kept ·
    /// restored (`reason` says what did not reach its target) · runs: run-opened · run-closed · run-archived ·
    /// run-archive-failed · room-closed · room-opened · room-removed · transcripts-discarded (`run` names the run).
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
    /// A manager's isolation (`manager-set`, `manager-started`).
    public var isolation: String?
    /// The fingerprint of the token a manager or worker was started with (12 hex — never the token).
    public var fingerprint: String?
    /// The run a run-, room- or transcripts- line is about. Additive.
    public var run: String?
    /// A permissions line (`granted`, `revoked`, `ceiling-set`, `request-recorded`, `permission-decided`): whom (`bot:otto`,
    /// `agent:demo/bot1`, `role:worker`), the permission or role, the answer, the scope, until when, the operation. Additive.
    public var subject: String?
    public var perm: String?
    public var role: String?
    public var answer: String?
    public var scope: String?
    public var until: Date?
    public var op: String?
    /// 749: the code an agent's program exited with (`agent-crashed`). Additive.
    public var exitCode: Int?
    /// 766: the proposal a `proposal-*` line is about. Additive.
    public var proposal: String?

    public init(at: Date = Date(), by: String = "you", action: String, agent: String? = nil, place: String? = nil, room: String? = nil,
                from: String? = nil, to: String? = nil, sha256: String? = nil, bytes: Int? = nil, added: Int? = nil, removed: Int? = nil,
                reason: String? = nil, isolation: String? = nil, fingerprint: String? = nil, run: String? = nil) {
        v = 1
        self.at = at; self.by = by; self.action = action; self.agent = agent; self.place = place; self.room = room
        self.from = from; self.to = to; self.sha256 = sha256; self.bytes = bytes; self.added = added; self.removed = removed
        self.reason = reason; self.isolation = isolation; self.fingerprint = fingerprint; self.run = run
    }

    public static let actions: Set<String> = ["created", "room-made", "room-linked", "adopted",
                                              "released", "brief-edited", "folders-edited", "refs-edited", "renamed", "agent-renamed",
                                              "agent-removed", "manager-set", "manager-removed", "bot-invited", "kicked-off",
                                              "manager-started", "manager-stopped", "worker-added", "worker-ended", "worker-add-undone",
                                              "brief-announced", "bot-changed", "slept", "woke", "agent-slept", "agent-woke", "stopped", "agent-stopped",
                                              "finished", "reopened", "archived", "room-archived", "room-unarchived", "worker-retired",
                                              "sandbox-removed", "template-kept", "restored", "run-opened", "run-closed", "run-archived",
                                              "run-archive-failed", "room-closed", "room-opened", "room-removed", "transcripts-discarded",
                                              "granted", "revoked", "ceiling-set", "request-recorded", "permission-decided",
                                              "agent-joined", "agent-crashed", "worker-declared",
                                              "addendum-added", "proposal-made", "proposal-applied", "proposal-declined"]

    /// The line as a person reads it.
    public var sentence: String {
        switch action {
        case "created": return "created"
        case "room-made": return "made the room \(room ?? "?")"
        case "room-linked": return "linked the room \(room ?? "?")"
        case "adopted": return "adopted \(agent ?? "?")" + (place.map { " (\($0))" } ?? "")
        case "released": return "released \(agent ?? "?")"
        case "brief-edited": return "edited the work (\(bytes ?? 0) bytes)"
        case "brief-announced": return "announced the edit in \(room ?? "the room")"
        case "bot-changed": return "told \(room ?? "the room") that \(agent ?? "?")'s \(reason ?? "settings") apply from its next session"
        case "folders-edited": return "folders: \(added ?? 0) added, \(removed ?? 0) removed"
        case "refs-edited": return "references: \(added ?? 0) added, \(removed ?? 0) removed"
        case "renamed": return "renamed from \(from ?? "?") to \(to ?? "?")"
        case "agent-renamed": return "agent \(from ?? "?") is now \(to ?? "?")"
        case "agent-removed": return "agent \(agent ?? "?") removed (its sandbox was deleted)"
        case "manager-set": return "the manager is \(agent ?? "?") (\(BotIsolation.words(isolation ?? "fenced")))"
        case "manager-removed": return "no manager now (was \(agent ?? "?"))"
        case "bot-invited": return "invited \(agent ?? "?") to \(room ?? "the room")"
        case "agent-joined": return "\(agent ?? "?") joined"
        case "agent-crashed": return "\(agent ?? "?") crashed: exit \(exitCode.map(String.init) ?? "?")"
        case "kicked-off": return "started the work: posted the brief in \(room ?? "the room") (\(bytes ?? 0) bytes)"
        case "manager-started": return "started the manager \(agent ?? "?") (\(BotIsolation.words(isolation ?? "fenced"))" + (place.map { ", \($0)" } ?? "") + ")"
        case "manager-stopped": return "stopped the manager \(agent ?? "?")"
        case "worker-added": return "added the worker \(agent ?? "?") (\(BotIsolation.words(isolation ?? "fenced"))" + (place.map { ", \($0)" } ?? "")
            + "; its task \(bytes ?? 0) bytes)"
        case "worker-declared": return "declared the worker \(agent ?? "?") (its task \(bytes ?? 0) bytes) — the start starts it"
        case "worker-ended": return "ended the worker \(agent ?? "?")"
        case "worker-add-undone": return "undid adding the worker \(agent ?? "?") (\(reason ?? "its place did not run"))"
        case "slept": return "put the workspace to sleep" + (reason.map { " — \($0)" } ?? "")
        case "woke": return "woke the workspace" + (reason.map { " — \($0)" } ?? "")
        case "agent-slept": return "\(agent ?? "?") is asleep" + (reason.map { " (\($0))" } ?? "")
        case "stopped": return "stopped every agent" + (reason.map { " — \($0)" } ?? "")
        case "agent-stopped": return "\(agent ?? "?") is stopped" + (reason.map { " (\($0))" } ?? "")
        case "agent-woke": return "\(agent ?? "?") is awake" + (reason.map { " (\($0))" } ?? "")
        case "finished": return "finished the work" + (reason.map { " — \($0)" } ?? "")
        case "reopened": return "reopened the workspace"
        case "archived": return "archived the workspace" + (reason.map { " — \($0)" } ?? "")
        case "room-archived": return "archived the room \(room ?? "?") (it stays readable)"
        case "room-unarchived": return "opened the room \(room ?? "?") again"
        case "worker-retired": return "retired the worker \(agent ?? "?") (its token is refused from now on)"
        case "sandbox-removed": return "removed the sandbox \(place.map { $0.hasPrefix("sandbox:") ? String($0.dropFirst(8)) : $0 } ?? agent ?? "?")"
        case "template-kept": return "saved the disk of \(from ?? "?") as the image \(to ?? "?")"   // 757: the action keeps its name
        case "restored": return "restored the workspace (finished)"
        case "addendum-added":
            return "added to the work description (\(bytes ?? 0) bytes)" + (agent.map { ", by \($0)" } ?? "") + (run.map { ", from run \($0)" } ?? "")
        case "proposal-made":
            return "\(agent ?? "?") proposed a change to the work description (\(proposal ?? "?"))" + (run.map { ", from run \($0)" } ?? "")
        case "proposal-applied": return "applied the proposal \(proposal ?? "?")" + (agent.map { " (decided by \($0))" } ?? "")
        case "proposal-declined": return "declined the proposal \(proposal ?? "?")" + (agent.map { " (decided by \($0))" } ?? "") + (reason.map { " — \($0)" } ?? "")
        case "run-opened": return "opened the run \(run ?? "?")"
        case "run-closed": return "closed the run \(run ?? "?")"
        case "run-archived": return "wrote the archive of run \(run ?? "?") (\(added ?? 0) file\(added == 1 ? "" : "s"))"
        case "run-archive-failed": return "could not write the archive of run \(run ?? "?")" + (reason.map { ": \($0)" } ?? "")
        case "room-closed": return "closed the room \(room ?? "?") to new messages (it stays readable)"
        case "room-opened": return "opened the room \(room ?? "?") to new messages again"
        case "room-removed": return "removed the room \(room ?? "?") for good (its archive is kept)"
        case "granted", "revoked":
            let who = subject.flatMap(GrantSubject.init(stored:))?.display ?? subject ?? "?"
            let what = role ?? "\(perm ?? "?")=\(answer ?? "?")"
            let scopeWords = scope.flatMap(GrantScope.init(stored:)).map { $0 == .everywhere ? "everywhere" : "in " + $0.display } ?? ""
            let till = until.map { " until " + BotName.day($0) } ?? ""
            return action == "granted" ? "granted \(who) \(what) \(scopeWords)\(till)" : "revoked \(who)'s \(role ?? perm ?? "?") \(scopeWords)"
        case "ceiling-set":
            return answer == "none" ? "cleared the workspace's ceiling on \(perm ?? "?")" : "set the workspace's ceiling: \(perm ?? "?")=\(answer ?? "?")"
        case "request-recorded": return "recorded a request for \(perm ?? role ?? "?")"
        case "permission-decided":
            let who = subject.flatMap(GrantSubject.init(stored:))?.display ?? subject ?? "?"
            return "\(who): \(perm ?? "?") → \(answer ?? "?")" + (reason.map { " (\($0))" } ?? "")
        case "transcripts-discarded":
            if let r = reason { return "discarded \(agent ?? "?")'s conversations (\(removed ?? 0) file\(removed == 1 ? "" : "s")): \(r)" }
            return "discarded \(agent ?? "?")'s conversations (\(removed ?? 0) file\(removed == 1 ? "" : "s"); the run's archive keeps them)"
        case "space-up": return "set it up from its space file" + (reason.map { " — \($0)" } ?? "")
        case "space-down": return "took it down (its space file)" + (reason.map { " — \($0)" } ?? "")
        case "space-purged": return "retired what its space file kept (--purge)"
        case "space-saved": return "saved its space file (\(bytes ?? 0) bytes) — not applied: up applies it"
        case "memory-kept": return "kept \(agent ?? "?")'s memory (\(added ?? 0) file\(added == 1 ? "" : "s")) for its next fenced session"
        case "memory-reset": return "reset \(agent ?? "?")'s kept memory" + (reason.map { " (\($0))" } ?? "")
        case "scratch-removed": return "removed a scratch folder" + (reason.map { " — \($0)" } ?? "")
        case "folder-released": return "released a folder the space kept" + (reason.map { " (\($0))" } ?? "")
        default: return action
        }
    }
}
