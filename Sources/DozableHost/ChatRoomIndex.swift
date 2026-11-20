import CryptoKit
import Foundation

// The room index (`<store>/chat/room-index.json`, version 1, 0600, written atomically, read in-process): each room the
// daemon made or first saw gets an id (`rm_<16 hex>`) — a room made again under the same name is another room, with
// another id — and its owner (the workspace that made it); a room archived by `doz chat room archive` records where its
// copy is; a room removed for good leaves a tombstone `{name, id, deletedAt, run, archive, owner}`. Data only: nothing of
// it travels on the chat protocol. Additive (an unknown field is kept). `ChatRoomIndexTests`.

public struct ChatRoomIndex: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    /// Where a room's archived copy is and what it held: the folder (relative to the store), the room's last seq when it
    /// was written, and its manifest's sha256.
    public struct ArchiveRef: Codable, Equatable, Sendable {
        public var path: String
        /// The room's last seq the copy holds (every message up to it).
        public var lastSeq: Int64
        public var sha256: String
        public var at: Date
        public init(path: String, lastSeq: Int64, sha256: String, at: Date) { self.path = path; self.lastSeq = lastSeq; self.sha256 = sha256; self.at = at }
    }

    public struct Entry: Codable, Equatable, Sendable {
        public var id: String
        public var since: Date
        /// The workspace that made it (nil: none — a loose room, or one a workspace only linked).
        public var owner: String?
        public var archive: ArchiveRef?
        public var unknown = UnknownFields()
        static let known: Set<String> = ["id", "since", "owner", "archive"]
        public init(id: String, since: Date, owner: String? = nil) { self.id = id; self.since = since; self.owner = owner }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: DynamicKey.self)
            id = try c.decode(String.self, forKey: "id")
            since = try c.decode(Date.self, forKey: "since")
            owner = try c.decodeIfPresent(String.self, forKey: "owner")
            archive = try c.decodeIfPresent(ArchiveRef.self, forKey: "archive")
            unknown = try UnknownFields(c, known: Self.known)
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: DynamicKey.self)
            try unknown.encode(&c, known: Self.known)
            try c.encode(id, forKey: "id")
            try c.encode(since, forKey: "since")
            try c.encodeIfPresent(owner, forKey: "owner")
            try c.encodeIfPresent(archive, forKey: "archive")
        }
    }

    /// What is left of a room removed for good. Its archive (relative to the store) is where it can still be read.
    public struct Tombstone: Codable, Equatable, Sendable {
        public var name: String
        public var id: String
        public var deletedAt: Date
        /// The run whose archive covers it, when that was the copy checked (nil: the room's own archive).
        public var run: String?
        public var archive: String
        public var owner: String?
        public init(name: String, id: String, deletedAt: Date, run: String?, archive: String, owner: String?) {
            self.name = name; self.id = id; self.deletedAt = deletedAt; self.run = run; self.archive = archive; self.owner = owner
        }
    }

    public var version: Int
    public var rooms: [String: Entry]
    public var tombstones: [Tombstone]
    public var unknown = UnknownFields()
    static let known: Set<String> = ["version", "rooms", "tombstones"]

    public init() { version = Self.currentVersion; rooms = [:]; tombstones = [] }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicKey.self)
        version = try c.decodeIfPresent(Int.self, forKey: "version") ?? 1
        rooms = try c.decodeIfPresent([String: Entry].self, forKey: "rooms") ?? [:]
        tombstones = try c.decodeIfPresent([Tombstone].self, forKey: "tombstones") ?? []
        unknown = try UnknownFields(c, known: Self.known)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicKey.self)
        try unknown.encode(&c, known: Self.known)
        try c.encode(max(version, Self.currentVersion), forKey: "version")
        try c.encode(rooms, forKey: "rooms")
        try c.encode(tombstones, forKey: "tombstones")
    }

    /// A new room id: `rm_` and 16 lower-case hex.
    public static func newID() -> String {
        var g = SystemRandomNumberGenerator()
        return "rm_" + (0..<8).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &g)) }.joined()
    }

    public static func isID(_ s: String) -> Bool { s.range(of: "^rm_[0-9a-f]{16}$", options: .regularExpression) != nil }

    /// The room's id, made now when it has none (`owner` recorded when given and none is). Answers whether it changed.
    @discardableResult
    public mutating func ensure(_ name: String, owner: String? = nil, now: Date = Date()) -> (id: String, changed: Bool) {
        if var e = rooms[name] {
            if e.owner == nil, let owner { e.owner = owner; rooms[name] = e; return (e.id, true) }
            return (e.id, false)
        }
        let e = Entry(id: Self.newID(), since: now, owner: owner)
        rooms[name] = e
        return (e.id, true)
    }

    /// The room removed: its entry goes, its tombstone stays.
    public mutating func bury(_ name: String, at: Date, run: String?, archive: String) {
        guard let e = rooms.removeValue(forKey: name) else { return }
        tombstones.append(Tombstone(name: name, id: e.id, deletedAt: at, run: run, archive: archive, owner: e.owner))
    }

    /// The newest tombstone of `name` (nil: none).
    public func tombstone(_ name: String) -> Tombstone? { tombstones.last { $0.name == name } }

    // MARK: the file

    public static func path(_ paths: ChatPaths) -> String { WorkspaceStore.resolved((paths.folder as NSString).appendingPathComponent("room-index.json")) }

    /// Read in-process (never writes). No file: empty. A file that cannot be read is an error naming it.
    public static func load(_ paths: ChatPaths) throws -> ChatRoomIndex {
        let p = path(paths)
        guard MacFenceHostFS.kind(p) != nil else { return ChatRoomIndex() }
        let d = try MacFenceHostFS.readRegular(p, maximum: 16 << 20)
        do { return try HostWire.decoder.decode(ChatRoomIndex.self, from: d) } catch {
            throw HostError(.failed, "the room index cannot be read: \(error.localizedDescription)")
        }
    }

    /// Written atomically, 0600, in the chat folder (made 0700 when missing).
    public func write(_ paths: ChatPaths) throws {
        try paths.ensureFolder()
        try paths.write("room-index.json", try HostWire.prettyEncoder.encode(self) + Data("\n".utf8))
    }
}
