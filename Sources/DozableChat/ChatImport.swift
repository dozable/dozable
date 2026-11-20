import CryptoKit
import Darwin
import Foundation
import SQLite3

// Bringing a chat's history across from another chat server of this protocol (`doz chat import PATH`): its rooms, their
// messages, states and reactions, attachments, memberships, archived rooms, holds, avatars and session links — read from a
// copy made for import (the other server's own copy script: one plain SQLite file per room, the data folder's JSON files,
// `files/<id>/<name>`), and written into a STAGING folder in this server's format. The daemon checks the names against
// Dozable's directory and puts the staged folder in place (`ChatImporter`); this file trusts nothing it reads:
//
// - Every path is looked at with lstat: a link anywhere in what is imported refuses the copy, and only regular files and
//   folders are read. Room files are named by the room-name rule, attachment folders by the file-id rule (16 or 32
//   lower-case hex), attachment files by the name-cleaning rule (`ChatFileRules.cleanName` gives the name back as it is).
// - A copy holding secrets (`secrets.json`, `secrets.lock`, `agents.json`, `tls/`) is refused whole: tokens, webhook
//   entries, registered sessions and keys never come across. A folder a running server holds, or a room file with
//   unsaved changes beside it (a non-empty `-wal`), is refused.
// - A room file is opened read-only and immutable, with `trusted_schema` off, and only after its schema is exactly the
//   protocol's (its six tables, `sqlite_sequence` and the automatic indexes; no trigger, view, virtual table, other index,
//   table or column) is it checked (`PRAGMA integrity_check` must answer ok), its rows read (each JSON column parses, each
//   attachment is a file id and a clean name), and copied (`VACUUM INTO` the staging folder). Nothing is ever written to
//   the copy.
// - The JSON files are at most 4 MiB each, parsed with `ChatJSON` and written again by it, never copied; an entry for a
//   room that does not exist, an avatar or a session link that breaks the server's own rule is dropped and listed.
//   `apps.json`, `appicons/` and anything unknown are ignored and listed, never opened.
// - Waking nobody (done on the staged copy): what was still waiting to be handed over to anyone but the human, and every
//   unconfirmed hand-over, is marked `cancelled` ("imported: not handed over again"); hand-overs and notices are dropped;
//   held messages stay held. `protocol-version` is this build's, so the first start announces nothing.

public struct ChatImportRefusal: Error, Sendable, CustomStringConvertible {
    public var description: String
    public init(_ d: String) { description = d }
}

/// One room of a copy, as the dry run shows it.
public struct ChatImportRoom: Codable, Sendable, Equatable {
    public var name: String
    public var messages: Int
    public var attachments: Int
    public var members: [String]
    public var archived: Bool
    public var hold: Int?
    /// Messages a hold keeps back (for one recipient or more).
    public var held: Int
    /// The copy had no member list for it (a room file only): it comes across with the human alone.
    public var noMemberList: Bool
    /// The room file's SHA-256 (nil: a room with no messages yet, so no file).
    public var sha256: String?
}

/// A name the copy's history uses, other than the human's, and what it looks like there.
public struct ChatImportName: Codable, Sendable, Equatable {
    public var name: String
    /// `claude-session`, `grok-bot` or `agent`, from the identity its messages carry.
    public var kind: String
    /// The other server called it by webhook (seen in its delivery states).
    public var webhook: Bool
    public init(name: String, kind: String, webhook: Bool) { self.name = name; self.kind = kind; self.webhook = webhook }
}

/// What a copy holds and what an import of it does, before anything is written.
public struct ChatImportSummary: Codable, Sendable, Equatable {
    public var rooms: [ChatImportRoom] = []
    public var messages = 0
    /// Attachment files that come across.
    public var files = 0
    /// The person, from the messages a human sent (nil: none did).
    public var human: String?
    /// Every other name the history uses (members, senders, recipients, reactions, avatars, session links).
    public var names: [ChatImportName] = []
    /// Per recipient: what was still waiting to be handed over (or handed over and never confirmed) — marked cancelled
    /// for anyone but the human.
    public var waiting: [String: Int] = [:]
    /// Edit, delete and protocol notices never collected: dropped.
    public var notices = 0
    /// What is dropped (and why) and what is ignored.
    public var dropped: [String] = []
    public var ignored: [String] = []
}

/// A copy read and checked: the summary, and what staging it needs.
public struct ChatImportCopy: Sendable {
    public var source: String
    public var summary: ChatImportSummary
    var roomFiles: [String: String] = [:]          // room → its .db in the copy
    var roomSHA: [String: String] = [:]
    var fileIDs: [String: String] = [:]            // id → the one file's name, for the files that come across
    var rooms: [String: [String]] = [:]
    var archived: [String: Bool] = [:]
    var holds: [String: Int] = [:]
    var avatars: [String: String] = [:]
    var sessions: [String: String] = [:]
}

/// What staging did.
public struct ChatImportStaged: Sendable, Equatable {
    /// Per recipient: marked cancelled.
    public var cancelled: [String: Int] = [:]
    public var notices = 0
    /// Open asks closed as expired on the staged copy (nobody told, no cooldown).
    public var asksExpired = 0
}

public enum ChatImport {
    public static let cancelDetail = "imported: not handed over again"
    public static let maxJSONBytes = 4 << 20
    public static let maxRoomBytes: Int64 = 2 << 30
    /// Whatever holds a secret or another server's identity: a copy with one of these is refused whole.
    public static let secretEntries = ["secrets.json", "secrets.lock", "agents.json", "tls"]
    static let jsonFiles = ["rooms.json", "archived.json", "holds.json", "avatars.json", "sessions.json"]
    static let ignoredKnown = ["apps.json", "appicons"]

    /// The protocol's tables and their columns, in order. `messages` may lack trailing columns (an older file: the
    /// store's ALTERs add them); the others are exact. Any other table, and every table missing but `messages`, is made
    /// by the store's own CREATE statements when the staged file is opened.
    static let tables: [String: [(String, String)]] = [
        "messages": [("seq", "INTEGER"), ("msg_id", "TEXT"), ("sender", "TEXT"), ("recipients", "TEXT"), ("re_msg_id", "TEXT"),
                     ("content", "TEXT"), ("at", "REAL"), ("kind", "TEXT"), ("attachments", "TEXT"), ("mentions", "TEXT"),
                     ("private", "INTEGER"), ("revealed", "INTEGER"), ("sender_info", "TEXT"), ("edited_at", "REAL"),
                     ("deleted_at", "REAL"), ("deleted_by", "TEXT")],
        "states": [("msg_id", "TEXT"), ("recipient", "TEXT"), ("state", "TEXT"), ("at", "REAL"), ("detail", "TEXT")],
        "reactions": [("msg_id", "TEXT"), ("who", "TEXT"), ("reaction", "TEXT"), ("at", "REAL")],
        "handovers": [("msg_id", "TEXT"), ("recipient", "TEXT"), ("handed_at", "REAL"), ("ver", "REAL")],
        "notices": [("id", "INTEGER"), ("recipient", "TEXT"), ("msg_id", "TEXT"), ("kind", "TEXT"), ("item", "TEXT"),
                    ("at", "REAL"), ("handed_at", "REAL")],
        "commands": [("msg_id", "TEXT"), ("sender", "TEXT"), ("state", "TEXT"), ("detail", "TEXT"), ("at", "REAL")],
        "asks": [("msg_id", "TEXT"), ("ask", "TEXT"), ("state", "TEXT"), ("expires", "REAL"), ("decision", "TEXT"), ("closed_at", "REAL"),
                 ("asker", "TEXT"), ("about", "TEXT"), ("declined", "INTEGER"), ("no_decider", "INTEGER")],
    ]
    static let requiredMessageColumns = 7

    // MARK: - Reading a copy

    /// Reads and checks a copy made for import. Nothing in it is written. Refused, with why, for anything it does not
    /// trust.
    public static func read(_ source: String) throws -> ChatImportCopy {
        var c = ChatImportCopy(source: source, summary: ChatImportSummary())
        try requireFolder(source, "the copy")
        let entries = try list(source)
        for s in secretEntries where entries.contains(s) {
            throw ChatImportRefusal("not a copy made for import: it holds secrets (\(s)) — make a copy that leaves them out")
        }
        if entries.contains(ChatServer.lockFileName) {
            if let pid = lockHolder(source) {
                throw ChatImportRefusal("a running chat server (pid \(pid)) holds this folder — import a copy made for import, never a live data folder")
            }
            c.summary.ignored.append(ChatServer.lockFileName)
        }
        for e in entries.sorted() where !jsonFiles.contains(e) && e != "rooms" && e != "files" && e != ChatServer.lockFileName {
            c.summary.ignored.append(ignoredKnown.contains(e) ? e + (isFolder(join(source, e)) ? "/ (room apps are not here)" : " (room apps are not here)") : e)
        }

        // The JSON files: each optional (absent is empty).
        var roomsJSON: [String: [String]]?
        if entries.contains("rooms.json") {
            var out: [String: [String]] = [:]
            for (k, v) in try objectFile(source, "rooms.json") {
                guard chatIsRoomName(k) else { throw ChatImportRefusal("rooms.json: \(goQuote(k)) is not a room name") }
                guard case .array(let a) = v else { throw ChatImportRefusal("rooms.json: \(k): not a list of names") }
                var names: [String] = []
                for x in a {
                    guard let n = x.stringValue else { throw ChatImportRefusal("rooms.json: \(k): not a list of names") }
                    if !names.contains(n) { names.append(n) }
                }
                out[k] = names
            }
            roomsJSON = out
        }
        func map<T>(_ file: String, _ f: (String, JValue) throws -> T?) throws -> [String: T] {
            guard entries.contains(file) else { return [:] }
            var out: [String: T] = [:]
            for (k, v) in try objectFile(source, file) { if let t = try f(k, v) { out[k] = t } }
            return out
        }
        let archived = try map("archived.json") { k, v -> Bool? in
            guard case .bool(let b) = v else { throw ChatImportRefusal("archived.json: \(goQuote(k)): not true or false") }
            return b
        }
        let holds = try map("holds.json") { k, v -> Int? in
            guard let n = try? v.goInt("hold"), !v.isNull else { throw ChatImportRefusal("holds.json: \(goQuote(k)): not a number") }
            return n
        }
        let avatars = try map("avatars.json") { k, v -> String? in
            guard let s = v.stringValue else { throw ChatImportRefusal("avatars.json: \(goQuote(k)): not a string") }
            return s
        }
        let sessions = try map("sessions.json") { k, v -> String? in
            guard let s = v.stringValue else { throw ChatImportRefusal("sessions.json: \(goQuote(k)): not a string") }
            return s
        }

        // The room files.
        var roomFiles: [String: String] = [:]
        if entries.contains("rooms") {
            let dir = join(source, "rooms")
            try requireFolder(dir, "rooms/")
            for e in try list(dir).sorted() {
                let p = join(dir, e)
                var st = stat()
                guard lstat(p, &st) == 0 else { throw ChatImportRefusal("rooms/\(e) cannot be read") }
                if (st.st_mode & S_IFMT) == S_IFLNK { throw ChatImportRefusal("rooms/\(e) is a link: a copy made for import has none") }
                if e.hasSuffix(".db-wal") || e.hasSuffix(".db-shm") || e.hasSuffix(".db-journal") {
                    if e.hasSuffix(".db-shm") || st.st_size == 0 { c.summary.ignored.append("rooms/\(e)"); continue }
                    throw ChatImportRefusal("rooms/\(e) holds changes not yet in the room file: make the copy with the other server's copy script")
                }
                guard e.hasSuffix(".db") else { c.summary.ignored.append("rooms/\(e)"); continue }
                let room = String(e.dropLast(3))
                guard chatIsRoomName(room) else { throw ChatImportRefusal("rooms/\(e): \(goQuote(room)) is not a room name") }
                guard (st.st_mode & S_IFMT) == S_IFREG else { throw ChatImportRefusal("rooms/\(e) is not a regular file") }
                guard Int64(st.st_size) <= maxRoomBytes else { throw ChatImportRefusal("rooms/\(e) is larger than 2 GiB") }
                roomFiles[room] = p
            }
        }

        // The attachment files: each id a folder holding one regular file with a clean name.
        var files: [String: (name: String, size: Int64)] = [:]
        if entries.contains("files") {
            let dir = join(source, "files")
            try requireFolder(dir, "files/")
            for id in try list(dir).sorted() {
                guard ChatFileRules.isFileID(id) else { throw ChatImportRefusal("files/\(goQuote(id)) is not an attachment id (16 or 32 lower-case hex)") }
                let fdir = join(dir, id)
                try requireFolder(fdir, "files/\(id)")
                let inside = try list(fdir)
                guard inside.count == 1, let name = inside.first else { throw ChatImportRefusal("files/\(id) holds \(inside.count) entries: an attachment is one file") }
                guard ChatFileRules.cleanName(name) == name else { throw ChatImportRefusal("files/\(id)/\(goQuote(name)) is not a clean attachment name") }
                var st = stat()
                guard lstat(join(fdir, name), &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else {
                    throw ChatImportRefusal("files/\(id)/\(name) is not a regular file (a link is refused)")
                }
                guard st.st_size > 0, Int(st.st_size) <= ChatFileRules.maxSize else {
                    throw ChatImportRefusal("files/\(id)/\(name) is \(st.st_size) bytes: an attachment is 1 byte to \(ChatFileRules.maxSize >> 20) MiB")
                }
                files[id] = (name, Int64(st.st_size))
            }
        }

        // Each room file: schema, integrity, rows.
        var names = Names()
        var referenced = Set<String>()
        var perRoom: [String: (messages: Int, attachments: Int, held: Int)] = [:]
        for (room, path) in roomFiles.sorted(by: { $0.key < $1.key }) {
            let r = try readRoom(room, path, names: &names, files: files, referenced: &referenced, summary: &c.summary)
            perRoom[room] = (r.messages, r.attachments, r.held)
            c.roomSHA[room] = try sha256(path)
        }

        // The person.
        let humans = names.humans.sorted()
        if humans.count > 1 { throw ChatImportRefusal("the copy has more than one person (\(humans.joined(separator: ", "))): this chat has one") }
        let human = humans.first
        c.summary.human = human

        // The rooms: rooms.json's, and a room file with no member list there comes across with the human alone.
        var rooms = roomsJSON ?? [:]
        for room in roomFiles.keys where rooms[room] == nil {
            rooms[room] = human.map { [$0] } ?? []
            c.summary.dropped.append("room \(room) had no member list in the copy: it comes across with \(human ?? "you") alone in it")
        }
        for (_, ms) in rooms { for n in ms { names.add(n) } }
        for (k, v) in archived.sorted(by: { $0.key < $1.key }) {
            if rooms[k] == nil { c.summary.dropped.append("archived.json: \(k) (no such room)"); continue }
            c.archived[k] = v
        }
        for (k, v) in holds.sorted(by: { $0.key < $1.key }) {
            if rooms[k] == nil { c.summary.dropped.append("holds.json: \(k) (no such room)"); continue }
            guard (0...1000).contains(v) else { c.summary.dropped.append("holds.json: \(k) (\(v) is not a hold)"); continue }
            c.holds[k] = v
        }
        for (k, v) in avatars.sorted(by: { $0.key < $1.key }) {
            guard ChatServerCore.validAvatar(v) else { c.summary.dropped.append("avatars.json: \(k) (not an avatar this server shows)"); continue }
            names.add(k)
            c.avatars[k] = v
        }
        for (k, v) in sessions.sorted(by: { $0.key < $1.key }) {
            guard ChatServerCore.validSessionLink(v) else { c.summary.dropped.append("sessions.json: \(k) (not an https link this server keeps)"); continue }
            names.add(k)
            c.sessions[k] = v
        }

        // Every name must be one this server can have; none is ever changed.
        for n in names.all.sorted() {
            if ChatProtocol.reservedNames.contains(n) || !chatIsSessionName(n) {
                throw ChatImportRefusal("the copy uses the name \(goQuote(n)), which cannot be a name in chat here (a lower-case letter, then lower-case letters, digits and -; never chat) — names are never rewritten")
            }
        }

        // Attachments: the ones messages name come across; the rest are dropped.
        for (id, f) in files.sorted(by: { $0.key < $1.key }) {
            if referenced.contains(id) { c.fileIDs[id] = f.name } else { c.summary.dropped.append("files/\(id)/\(f.name) (no message names it)") }
        }

        c.rooms = rooms
        c.roomFiles = roomFiles
        c.summary.files = c.fileIDs.count
        c.summary.rooms = rooms.keys.sorted().map { room in
            let p = perRoom[room]
            return ChatImportRoom(name: room, messages: p?.messages ?? 0, attachments: p?.attachments ?? 0, members: rooms[room] ?? [],
                                  archived: c.archived[room] ?? false, hold: c.holds[room], held: p?.held ?? 0,
                                  noMemberList: roomsJSON?[room] == nil && roomFiles[room] != nil, sha256: c.roomSHA[room])
        }
        c.summary.messages = c.summary.rooms.reduce(0) { $0 + $1.messages }
        c.summary.names = names.all.subtracting(human.map { [$0] } ?? []).sorted().map {
            ChatImportName(name: $0, kind: names.kind($0), webhook: names.webhook.contains($0))
        }
        return c
    }

    /// The names a copy's history uses and what it says of them.
    struct Names {
        var all = Set<String>()
        var humans = Set<String>()
        var kinds: [String: String] = [:]
        var webhook = Set<String>()
        var inbox = Set<String>()
        /// The kind: from the identity its messages carry, else a Claude session's when it was delivered into one.
        func kind(_ n: String) -> String { kinds[n] ?? (inbox.contains(n) ? "claude-session" : "agent") }
        mutating func add(_ n: String) { all.insert(n) }
    }

    static func readRoom(_ room: String, _ path: String, names: inout Names, files: [String: (name: String, size: Int64)],
                         referenced: inout Set<String>, summary: inout ChatImportSummary) throws -> (messages: Int, attachments: Int, held: Int) {
        func refuse(_ s: String) -> ChatImportRefusal { ChatImportRefusal("rooms/\(room).db: \(s)") }
        // The header first: a file that is not SQLite's is never handed to it.
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw refuse("cannot be read") }
        var head = [UInt8](repeating: 0, count: 16)
        let n = Darwin.read(fd, &head, 16)
        Darwin.close(fd)
        guard n == 16, head == Array("SQLite format 3\u{0}".utf8) else { throw refuse("not an SQLite file") }

        let db: ImportDB
        do { db = try ImportDB(readOnly: path) } catch { throw refuse("\(error)") }
        defer { db.close() }
        do {
            // Schema: exactly the protocol's.
            let master = try db.query("SELECT type, name, tbl_name, COALESCE(sql,'') FROM sqlite_master") { ($0.text(0), $0.text(1), $0.text(2), $0.text(3)) }
            var present = Set<String>()
            for (type, name, table, sql) in master {
                switch type {
                case "table":
                    if sql.uppercased().contains("VIRTUAL") { throw refuse("a virtual table (\(name)) is not the protocol's") }
                    if name == "sqlite_sequence" { continue }
                    guard tables[name] != nil else { throw refuse("an unknown table (\(name))") }
                    present.insert(name)
                case "index":
                    guard sql.isEmpty, name.hasPrefix("sqlite_autoindex_" + table + "_"), tables[table] != nil else { throw refuse("an index the protocol does not make (\(name))") }
                case "trigger": throw refuse("a trigger (\(name)) — a room file has none")
                case "view": throw refuse("a view (\(name)) — a room file has none")
                default: throw refuse("an unknown schema entry (\(type) \(name))")
                }
            }
            guard present.contains("messages") else { throw refuse("no messages table") }
            for t in present {
                let cols = try db.query("SELECT name, type, hidden FROM pragma_table_xinfo(?)", [t]) { ($0.text(0), $0.text(1), $0.int(2)) }
                let want = tables[t]!
                if cols.contains(where: { $0.2 != 0 }) { throw refuse("table \(t) has a hidden or generated column") }
                let ok = cols.count <= want.count && (t == "messages" ? cols.count >= requiredMessageColumns : cols.count == want.count)
                    && zip(cols, want).allSatisfy { $0.0 == $1.0 && $0.1.uppercased() == $1.1 }
                guard ok else { throw refuse("table \(t) has columns \(cols.map(\.0).joined(separator: ", ")), not the protocol's") }
            }
            let check = try db.query("PRAGMA integrity_check") { $0.text(0) }
            guard check == ["ok"] else { throw refuse("it fails SQLite's integrity check (\(check.prefix(3).joined(separator: "; ")))") }

            // Rows.
            let mcols = Set(try db.query("SELECT name FROM pragma_table_xinfo('messages')") { $0.text(0) })
            func col(_ c: String, _ dflt: String) -> String { mcols.contains(c) ? c : dflt }
            let typed = try db.query("""
                SELECT COUNT(*) FROM messages WHERE typeof(msg_id)<>'text' OR typeof(sender)<>'text' OR typeof(recipients)<>'text'
                \tOR typeof(content)<>'text' OR typeof(\(col("attachments", "'[]'")))<>'text' OR typeof(\(col("mentions", "'[]'")))<>'text'
                \tOR typeof(\(col("sender_info", "''")))<>'text' OR typeof(\(col("kind", "''")))<>'text'
                """) { $0.int(0) }
            guard typed.first == 0 else { throw refuse("a message has a value of the wrong type") }
            var count = 0, attached = 0
            let rows = try db.query("SELECT msg_id, sender, recipients, \(col("kind", "''")), \(col("attachments", "'[]'")), \(col("mentions", "'[]'")), \(col("sender_info", "''")), content FROM messages") {
                ($0.text(0), $0.text(1), $0.text(2), $0.text(3), $0.text(4), $0.text(5), $0.text(6), $0.text(7))
            }
            for (id, sender, recipients, kind, attachments, mentions, info, content) in rows {
                count += 1
                guard !id.isEmpty else { throw refuse("a message has no msg_id") }
                guard kind == "" || kind == "change" || kind == "ask" else { throw refuse("message \(id): an unknown kind \(goQuote(kind))") }
                guard let to = stringList(recipients) else { throw refuse("message \(id): recipients is not a list of names") }
                guard let ment = stringList(mentions) else { throw refuse("message \(id): mentions is not a list of names") }
                guard case .array(let atts)? = try? ChatJSON.parse(Array(attachments.utf8)) else { throw refuse("message \(id): attachments is not a list") }
                for a in atts {
                    guard a.isObject else { throw refuse("message \(id): an attachment is not an object") }
                    let x = ChatAttachment.read(a)
                    guard ChatFileRules.isFileID(x.id) else { throw refuse("message \(id): an attachment id \(goQuote(x.id)) is not 16 or 32 lower-case hex") }
                    guard !x.name.isEmpty, ChatFileRules.cleanName(x.name) == x.name else { throw refuse("message \(id): the attachment name \(goQuote(x.name)) is not clean") }
                    if files[x.id]?.name != x.name { summary.dropped.append("rooms/\(room).db: message \(id) names files/\(x.id)/\(x.name), which is not in the copy") }
                    referenced.insert(x.id)
                    attached += 1
                }
                for fid in files.keys where content.contains("/files/" + fid + "/") { referenced.insert(fid) }
                if !info.isEmpty {
                    guard let v = try? ChatJSON.parse(Array(info.utf8)), let s = ChatSender.read(v) else { throw refuse("message \(id): sender_info is not a sender") }
                    if s.kind == "human" && kind != "change" { names.humans.insert(sender) }
                    if kind != "change" && names.kinds[sender] == nil {
                        if s.id.hasPrefix("anthropic:claude-code:") { names.kinds[sender] = "claude-session" } else if s.id.hasPrefix("xai:grok-bot:") { names.kinds[sender] = "grok-bot" }
                    }
                }
                // A change line is the server's or whoever caused it: shown as it is, never addressed.
                if kind != "change" { names.add(sender) }
                for n in to + ment { names.add(n) }
            }
            // An ask's deciders and whoever decided it are names of the history too.
            if present.contains("asks") {
                guard try db.query("SELECT COUNT(*) FROM asks WHERE typeof(ask)<>'text' OR typeof(state)<>'text' OR typeof(decision)<>'text' OR typeof(asker)<>'text'",
                                   [], { $0.int(0) }).first == 0 else { throw refuse("an ask has a value of the wrong type") }
                for (asker, raw, dec) in try db.query("SELECT asker, ask, decision FROM asks", [], { ($0.text(0), $0.text(1), $0.text(2)) }) {
                    guard let v = try? ChatJSON.parse(Array(raw.utf8)), v.isObject, let ds = try? v.field("deciders")?.goStrings("deciders") ?? [] else {
                        throw refuse("an ask is not an ask object")
                    }
                    if !asker.isEmpty { names.add(asker) }
                    for d in ds { names.add(d) }
                    if !dec.isEmpty, let by = (try? ChatJSON.parse(Array(dec.utf8)))?.field("by")?.stringValue, by != ChatProtocol.systemName { names.add(by) }
                }
            }
            if present.contains("states") {
                for (who, detail) in try db.query("SELECT recipient, detail FROM states WHERE typeof(recipient)='text'", [], { ($0.text(0), $0.text(1)) }) {
                    names.add(who)
                    let low = detail.lowercased()
                    if low.contains("webhook") { names.webhook.insert(who) }
                    // Handed into (or not found as) a Claude Code session on that server's Mac.
                    if low.contains("claude session") || low.contains("session's inbox") { names.inbox.insert(who) }
                }
                guard try db.query("SELECT COUNT(*) FROM states WHERE typeof(recipient)<>'text' OR typeof(state)<>'text' OR typeof(msg_id)<>'text'", [], { $0.int(0) }).first == 0 else {
                    throw refuse("a state has a value of the wrong type")
                }
            }
            if present.contains("reactions") {
                for who in try db.query("SELECT who FROM reactions", [], { $0.text(0) }) { names.add(who) }
            }
            // What would be cancelled: waiting (queued, or released from the hold) or handed over and never confirmed.
            var waiting = Set<String>()
            if present.contains("states") {
                for (id, who) in try db.query(ChatRoomStore.pendingSQL, [], { ($0.text(0), $0.text(1)) }) { waiting.insert(id + "\u{0}" + who) }
            }
            if present.contains("handovers") {
                for (id, who) in try db.query("SELECT msg_id, recipient FROM handovers", [], { ($0.text(0), $0.text(1)) }) {
                    waiting.insert(id + "\u{0}" + who)
                    names.add(who)
                }
            }
            for k in waiting { summary.waiting[String(k.split(separator: "\u{0}", omittingEmptySubsequences: false)[1]), default: 0] += 1 }
            if present.contains("notices") { summary.notices += try db.query("SELECT COUNT(*) FROM notices") { $0.int(0) }.first ?? 0 }
            let held = present.contains("states") ? Set(try db.query(ChatRoomStore.heldSQL) { $0.text(0) }).count : 0
            return (count, attached, held)
        } catch let e as ChatImportRefusal { throw e } catch { throw refuse("\(error)") }
    }

    static func stringList(_ json: String) -> [String]? {
        guard case .array(let a)? = try? ChatJSON.parse(Array(json.utf8)) else { return nil }
        var out: [String] = []
        for x in a { guard let s = x.stringValue else { return nil }; out.append(s) }
        return out
    }

    // MARK: - Staging

    /// Writes the copy into `staging` (a folder that must not exist yet; made 0700, every file 0600) in this server's
    /// format, the waiting messages of everyone but `human` cancelled. The copy is read again as it is copied: a room file
    /// whose bytes changed since `read` is refused.
    public static func stage(_ c: ChatImportCopy, into staging: String, human: String) throws -> ChatImportStaged {
        guard mkdir(staging, 0o700) == 0 else { throw ChatImportRefusal("cannot make \(staging): \(String(cString: strerror(errno)))") }
        let roomsDir = join(staging, "rooms"), filesDir = join(staging, "files")
        guard mkdir(roomsDir, 0o700) == 0, mkdir(filesDir, 0o700) == 0 else { throw ChatImportRefusal("cannot make the staging folder's parts") }
        var out = ChatImportStaged()
        let now = chatNow()
        for (room, path) in c.roomFiles.sorted(by: { $0.key < $1.key }) {
            let dst = join(roomsDir, room + ".db")
            do {
                let db = try ImportDB(readOnly: path)
                defer { db.close() }
                try db.exec("VACUUM INTO ?", [dst])
            }
            guard (try? sha256(path)) == c.roomSHA[room] else { throw ChatImportRefusal("rooms/\(room).db changed while it was imported: make a new copy") }
            chmod(dst, 0o600)
            let st = try ChatRoomStore(path: dst)
            defer { st.close() }
            let q = try st.quietForImport(human: human, detail: cancelDetail, at: now)
            for (k, v) in q.cancelled { out.cancelled[k, default: 0] += v }
            out.notices += q.notices
            out.asksExpired += try st.expireOpenAsksForImport(at: now)
        }
        for (id, name) in c.fileIDs.sorted(by: { $0.key < $1.key }) {
            let d = join(filesDir, id)
            guard mkdir(d, 0o700) == 0 else { throw ChatImportRefusal("cannot make files/\(id) in the staging folder") }
            try copyFile(join(join(join(c.source, "files"), id), name), to: join(d, name))
        }
        func write(_ name: String, _ v: JValue) throws {
            do { try ChatFiles.writeAtomically(join(staging, name), ChatJSON.encodeIndented(v, indent: " ")) } catch { throw ChatImportRefusal("\(error)") }
        }
        try write("rooms.json", .map(c.rooms.mapValues { JValue.strings($0) }))
        if !c.archived.isEmpty { try write("archived.json", .map(c.archived.mapValues { JValue.bool($0) })) }
        if !c.holds.isEmpty { try write("holds.json", .map(c.holds.mapValues { JValue.int(Int64($0)) })) }
        if !c.avatars.isEmpty { try write("avatars.json", .map(c.avatars.mapValues { JValue.string($0) })) }
        if !c.sessions.isEmpty { try write("sessions.json", .map(c.sessions.mapValues { JValue.string($0) })) }
        // This build's protocol version: the first start announces nothing (and calls no webhook, notifies no session).
        do { try ChatFiles.writeAtomically(join(staging, "protocol-version"), Array((ChatProtocol.version + "\n").utf8)) } catch { throw ChatImportRefusal("\(error)") }
        return out
    }

    /// Copies one attachment: read without following a link (a regular file, at most the limit), written with O_EXCL and
    /// O_NOFOLLOW, 0600.
    static func copyFile(_ from: String, to: String) throws {
        let i = open(from, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard i >= 0 else { throw ChatImportRefusal("\(from) cannot be read") }
        defer { Darwin.close(i) }
        var st = stat()
        guard fstat(i, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_size > 0, Int(st.st_size) <= ChatFileRules.maxSize else {
            throw ChatImportRefusal("\(from) is no longer an attachment file")
        }
        let o = open(to, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard o >= 0 else { throw ChatImportRefusal("cannot write \(to): \(String(cString: strerror(errno)))") }
        defer { Darwin.close(o) }
        var buf = [UInt8](repeating: 0, count: 1 << 16), total = 0
        while true {
            let n = Darwin.read(i, &buf, buf.count)
            if n < 0 { throw ChatImportRefusal("\(from) cannot be read") }
            if n == 0 { break }
            total += n
            if total > ChatFileRules.maxSize { throw ChatImportRefusal("\(from) grew past the limit") }
            var off = 0
            while off < n {
                let w = buf.withUnsafeBytes { Darwin.write(o, $0.baseAddress! + off, n - off) }
                if w <= 0 { throw ChatImportRefusal("cannot write \(to)") }
                off += w
            }
        }
    }

    // MARK: - A data folder's history

    /// Whether a data folder holds history: a message in a room file that is not the server's own (`chat`), or an
    /// attachment. A room file that cannot be read counts as history (nothing is ever put aside unseen as empty).
    public static func hasHistory(_ data: String) -> (history: Bool, messages: Int, files: Int) {
        var messages = 0, files = 0, history = false
        let filesDir = join(data, "files")
        files = ((try? FileManager.default.contentsOfDirectory(atPath: filesDir)) ?? []).filter { !$0.hasPrefix(".") }.count
        if files > 0 { history = true }
        for e in (try? FileManager.default.contentsOfDirectory(atPath: join(data, "rooms"))) ?? [] where e.hasSuffix(".db") {
            guard let db = try? ImportDB(ownFile: join(data, "rooms/" + e)),
                  let n = (try? db.query("SELECT COUNT(*) FROM messages WHERE sender<>?", [ChatProtocol.systemName]) { $0.int(0) })?.first else {
                history = true
                continue
            }
            db.close()
            messages += n
            if n > 0 { history = true }
        }
        return (history, messages, files)
    }

    // MARK: - Files

    static func join(_ a: String, _ b: String) -> String { (a as NSString).appendingPathComponent(b) }

    static func isFolder(_ p: String) -> Bool {
        var st = stat()
        return lstat(p, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }

    static func requireFolder(_ p: String, _ what: String) throws {
        var st = stat()
        guard lstat(p, &st) == 0 else { throw ChatImportRefusal("\(what): \(String(cString: strerror(errno)))") }
        if (st.st_mode & S_IFMT) == S_IFLNK { throw ChatImportRefusal("\(what) is a link: a copy made for import has none") }
        guard (st.st_mode & S_IFMT) == S_IFDIR else { throw ChatImportRefusal("\(what) is not a folder") }
    }

    static func list(_ p: String) throws -> [String] {
        do { return try FileManager.default.contentsOfDirectory(atPath: p).filter { $0 != ".DS_Store" } } catch {
            throw ChatImportRefusal("\(p) cannot be listed")
        }
    }

    /// A JSON file of the copy: a regular file (never a link), at most 4 MiB, an object; its members in order. A key twice
    /// is refused.
    static func objectFile(_ dir: String, _ name: String) throws -> [(String, JValue)] {
        let p = join(dir, name)
        let fd = open(p, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ChatImportRefusal("\(name) cannot be read" + (errno == ELOOP ? " (a link is refused)" : "")) }
        defer { Darwin.close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { throw ChatImportRefusal("\(name) is not a regular file") }
        guard st.st_size <= maxJSONBytes else { throw ChatImportRefusal("\(name) is larger than 4 MiB") }
        var bytes = [UInt8](), buf = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let n = Darwin.read(fd, &buf, buf.count)
            if n < 0 { throw ChatImportRefusal("\(name) cannot be read") }
            if n == 0 { break }
            bytes += buf[0..<n]
            if bytes.count > maxJSONBytes { throw ChatImportRefusal("\(name) is larger than 4 MiB") }
        }
        guard let v = try? ChatJSON.parse(bytes), case .object(let ms) = v else { throw ChatImportRefusal("\(name) is not a JSON object") }
        var seen = Set<String>()
        for m in ms { guard seen.insert(m.key).inserted else { throw ChatImportRefusal("\(name) has \(goQuote(m.key)) twice") } }
        return ms.map { ($0.key, $0.value) }
    }

    static func lockHolder(_ dir: String) -> Int? {
        var st = stat()
        guard lstat(join(dir, ChatServer.lockFileName), &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        return ServerLock.holder(dir)
    }

    static func sha256(_ path: String) throws -> String {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ChatImportRefusal("\(path) cannot be read") }
        defer { Darwin.close(fd) }
        var h = SHA256()
        var buf = [UInt8](repeating: 0, count: 1 << 20)
        while true {
            let n = Darwin.read(fd, &buf, buf.count)
            if n < 0 { throw ChatImportRefusal("\(path) cannot be read") }
            if n == 0 { break }
            h.update(data: buf[0..<n])
        }
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// One SQLite connection for reading a copy: `file:…?mode=ro&immutable=1`, `trusted_schema` off — nothing the file says
/// is run, and nothing is written to it. `ownFile`: a file of this server's own data folder (chat off), opened read-write
/// without creating (SQLite cannot open a WAL file read-only once its -shm is gone).
final class ImportDB {
    private var db: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(readOnly path: String) throws {
        let uri = "file:" + Self.uriPath(path) + "?mode=ro&immutable=1"
        try open(uri, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX)
    }

    init(ownFile path: String) throws {
        try open(path, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX)
    }

    private func open(_ name: String, _ flags: Int32) throws {
        var h: OpaquePointer?
        guard sqlite3_open_v2(name, &h, flags, nil) == SQLITE_OK, let h else {
            sqlite3_close(h)
            throw ChatStoreError(description: "cannot be opened")
        }
        db = h
        sqlite3_busy_timeout(h, 2000)
        do {
            try exec("PRAGMA trusted_schema=OFF")
            try exec("PRAGMA cell_size_check=ON")
            guard try query("PRAGMA trusted_schema", [], { $0.int(0) }).first == 0 else { throw ChatStoreError(description: "trusted_schema stayed on") }
        } catch { close(); throw error }
    }

    func close() { if let db { sqlite3_close(db) }; db = nil }
    deinit { close() }

    /// Percent-encodes a path for a `file:` URI: everything but unreserved characters and `/`.
    static func uriPath(_ p: String) -> String {
        var out = ""
        for b in p.utf8 {
            let ok = (0x41...0x5A).contains(b) || (0x61...0x7A).contains(b) || (0x30...0x39).contains(b) || [0x2D, 0x2E, 0x5F, 0x7E, 0x2F].contains(b)
            out += ok ? String(UnicodeScalar(b)) : String(format: "%%%02X", b)
        }
        return out
    }

    struct Row {
        let st: OpaquePointer
        func text(_ i: Int32) -> String {
            guard let p = sqlite3_column_text(st, i) else { return "" }
            return String(decoding: UnsafeBufferPointer(start: p, count: Int(sqlite3_column_bytes(st, i))), as: UTF8.self)
        }
        func int(_ i: Int32) -> Int { Int(sqlite3_column_int64(st, i)) }
    }

    private func prepare(_ sql: String, _ args: [String]) throws -> OpaquePointer {
        var st: OpaquePointer?
        guard let db, sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK, let st else {
            throw ChatStoreError(description: db.map { String(cString: sqlite3_errmsg($0)) } ?? "closed")
        }
        for (i, a) in args.enumerated() { sqlite3_bind_text(st, Int32(i + 1), a, -1, Self.transient) }
        return st
    }

    func exec(_ sql: String, _ args: [String] = []) throws {
        let st = try prepare(sql, args)
        defer { sqlite3_finalize(st) }
        let rc = sqlite3_step(st)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw ChatStoreError(description: String(cString: sqlite3_errmsg(db))) }
    }

    func query<T>(_ sql: String, _ args: [String] = [], _ row: (Row) throws -> T) throws -> [T] {
        let st = try prepare(sql, args)
        defer { sqlite3_finalize(st) }
        var out: [T] = []
        while true {
            let rc = sqlite3_step(st)
            if rc == SQLITE_ROW { out.append(try row(Row(st: st))); continue }
            if rc == SQLITE_DONE { return out }
            throw ChatStoreError(description: String(cString: sqlite3_errmsg(db)))
        }
    }
}
