import Foundation
import SQLite3

// One room's log: one SQLite file, `rooms/<room>.db`, in the reference's format exactly — the same CREATE TABLE IF NOT
// EXISTS statements and then the same tolerant ALTER TABLEs, in the same order, so a file written by either server opens
// in the other and an older file gains the newer columns. WAL, busy_timeout 5000, ONE connection, used only from the
// store's own serial queue (the system SQLite, as the daemon's metrics use it).

public struct ChatStoreError: Error, Sendable, CustomStringConvertible {
    public var description: String
}

public final class ChatRoomStore: @unchecked Sendable {
    public let path: String
    private var db: OpaquePointer?
    private let queue: DispatchQueue
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// How long the msg_id of a command that is not stored as a message is remembered.
    public static let commandMemory: Double = 30 * 24 * 3600

    /// The schema, statement by statement, as the reference creates it.
    public static let schema = """
        CREATE TABLE IF NOT EXISTS messages(
          seq INTEGER PRIMARY KEY AUTOINCREMENT, msg_id TEXT NOT NULL UNIQUE, sender TEXT NOT NULL,
          recipients TEXT NOT NULL, re_msg_id TEXT NOT NULL DEFAULT '', content TEXT NOT NULL, at REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS states(
          msg_id TEXT NOT NULL, recipient TEXT NOT NULL, state TEXT NOT NULL, at REAL NOT NULL, detail TEXT NOT NULL DEFAULT '',
          PRIMARY KEY(msg_id, recipient, state));
        CREATE TABLE IF NOT EXISTS reactions(
          msg_id TEXT NOT NULL, who TEXT NOT NULL, reaction TEXT NOT NULL, at REAL NOT NULL,
          PRIMARY KEY(msg_id, who, reaction));
        CREATE TABLE IF NOT EXISTS handovers(
          msg_id TEXT NOT NULL, recipient TEXT NOT NULL, handed_at REAL NOT NULL, ver REAL NOT NULL DEFAULT 0,
          PRIMARY KEY(msg_id, recipient));
        CREATE TABLE IF NOT EXISTS notices(
          id INTEGER PRIMARY KEY AUTOINCREMENT, recipient TEXT NOT NULL, msg_id TEXT NOT NULL, kind TEXT NOT NULL,
          item TEXT NOT NULL, at REAL NOT NULL, handed_at REAL NOT NULL DEFAULT 0, UNIQUE(recipient, msg_id));
        CREATE TABLE IF NOT EXISTS commands(
          msg_id TEXT PRIMARY KEY, sender TEXT NOT NULL, state TEXT NOT NULL, detail TEXT NOT NULL DEFAULT '', at REAL NOT NULL);
        """

    /// The columns added to older files; each fails harmlessly when it is there.
    public static let alters = [
        "ALTER TABLE messages ADD COLUMN kind TEXT NOT NULL DEFAULT ''",
        "ALTER TABLE messages ADD COLUMN attachments TEXT NOT NULL DEFAULT '[]'",
        "ALTER TABLE messages ADD COLUMN mentions TEXT NOT NULL DEFAULT '[]'",
        "ALTER TABLE messages ADD COLUMN private INTEGER NOT NULL DEFAULT 0",
        "ALTER TABLE messages ADD COLUMN revealed INTEGER NOT NULL DEFAULT 0",
        "ALTER TABLE messages ADD COLUMN sender_info TEXT NOT NULL DEFAULT ''",
        "ALTER TABLE messages ADD COLUMN edited_at REAL NOT NULL DEFAULT 0",
        "ALTER TABLE messages ADD COLUMN deleted_at REAL NOT NULL DEFAULT 0",
        "ALTER TABLE messages ADD COLUMN deleted_by TEXT NOT NULL DEFAULT ''",
    ]

    public init(path: String, now: Double = chatNow()) throws {
        self.path = path
        queue = DispatchQueue(label: "chat.room." + URL(fileURLWithPath: path).lastPathComponent)
        var h: OpaquePointer?
        guard sqlite3_open_v2(path, &h, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            let msg = h.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            sqlite3_close(h)
            throw ChatStoreError(description: "\(path): \(msg)")
        }
        db = h
        sqlite3_busy_timeout(h, 5000)
        do {
            try exec("PRAGMA journal_mode=WAL")
            try exec(Self.schema)
        } catch {
            sqlite3_close(h)
            db = nil
            throw error
        }
        for a in Self.alters { try? exec(a) }
        _ = try? run("DELETE FROM commands WHERE at<?", [.real(now - Self.commandMemory)])
    }

    deinit { if let db { sqlite3_close(db) } }

    public func close() {
        queue.sync {
            if let db { sqlite3_close(db) }
            db = nil
        }
    }

    // MARK: writing

    /// Adds a message; dup is true when the msg_id is already there. The message's seq is set.
    @discardableResult
    public func insert(_ m: inout ChatStored) throws -> Bool {
        let to = ChatJSON.encodeString(.strings(m.to))
        let att = ChatJSON.encodeString(.array(m.attachments))
        let men = ChatJSON.encodeString(.strings(m.mentions))
        let snd = m.sender.map { ChatJSON.encodeString($0.json) } ?? ""
        let (changes, rowid) = try sync {
            let n = try self.run("""
                INSERT INTO messages(msg_id,sender,recipients,re_msg_id,content,at,kind,attachments,mentions,private,sender_info) VALUES(?,?,?,?,?,?,?,?,?,?,?)
                \tON CONFLICT(msg_id) DO NOTHING
                """, [.text(m.msgID), .text(m.from), .text(to), .text(m.reMsgID), .text(m.content), .real(m.at), .text(m.kind),
                      .text(att), .text(men), .int(m.isPrivate ? 1 : 0), .text(snd)])
            return (n, sqlite3_last_insert_rowid(self.db))
        }
        if changes == 0 { return true }
        m.seq = rowid
        return false
    }

    public func setState(_ s: ChatState) throws {
        _ = try sync {
            try self.run("INSERT OR REPLACE INTO states(msg_id,recipient,state,at,detail) VALUES(?,?,?,?,?)",
                         [.text(s.msgID), .text(s.recipient), .text(s.state), .real(s.at), .text(s.detail)])
        }
    }

    /// Puts a reaction on a message, or takes it off when it is there already. Whether it was put on.
    public func toggleReaction(_ msgID: String, who: String, reaction: String, at: Double) throws -> Bool {
        try sync {
            if try self.run("DELETE FROM reactions WHERE msg_id=? AND who=? AND reaction=?", [.text(msgID), .text(who), .text(reaction)]) > 0 {
                return false
            }
            try self.run("INSERT INTO reactions(msg_id,who,reaction,at) VALUES(?,?,?,?)", [.text(msgID), .text(who), .text(reaction), .real(at)])
            return true
        }
    }

    public func addNotice(name: String, msgID: String, kind: String, item: String, at: Double) throws {
        _ = try sync {
            try self.run("INSERT OR REPLACE INTO notices(recipient,msg_id,kind,item,at,handed_at) VALUES(?,?,?,?,?,0)",
                         [.text(name), .text(msgID), .text(kind), .text(item), .real(at)])
        }
    }

    // MARK: reading

    /// Who sent a message, or "" when it is not in this room.
    public func sender(of msgID: String) -> String {
        (try? sync { try self.query("SELECT sender FROM messages WHERE msg_id=?", [.text(msgID)]) { Self.text($0, 0) } })?.first ?? ""
    }

    /// Whether a msg_id was used in this room, by a message or by a command, and by whom; for a command, its answer.
    public func knownID(_ msgID: String) -> (known: Bool, by: String, state: String, detail: String) {
        let by = sender(of: msgID)
        if !by.isEmpty { return (true, by, "", "") }
        let rows = (try? sync {
            try self.query("SELECT sender, state, detail FROM commands WHERE msg_id=?", [.text(msgID)]) {
                (Self.text($0, 0), Self.text($0, 1), Self.text($0, 2))
            }
        }) ?? []
        guard let r = rows.first else { return (false, "", "", "") }
        return (true, r.0, r.1, r.2)
    }

    /// The whole id from its start, when exactly one message matches; else the prefix as given.
    public func fullID(_ prefix: String) -> String {
        // An empty start, or one with % or _, would match messages it does not name: it matches nothing.
        guard Self.isIDStart(prefix) else { return prefix }
        let ids = (try? sync {
            try self.query("SELECT msg_id FROM messages WHERE msg_id LIKE ? ORDER BY seq DESC LIMIT 2", [.text(prefix + "%")]) { Self.text($0, 0) }
        }) ?? []
        return ids.count == 1 ? ids[0] : prefix
    }

    /// Whether name was handed the message: it has a delivery state for it.
    public func received(_ msgID: String, by name: String) -> Bool {
        let n = (try? sync {
            try self.query("SELECT COUNT(*) FROM states WHERE msg_id=? AND recipient=?", [.text(msgID), .text(name)]) { sqlite3_column_int64($0, 0) }
        })?.first ?? 0
        return n > 0
    }

    /// Each (message, recipient) held and not yet released, oldest message first.
    public func held() throws -> [(String, String)] {
        try sync { try self.query(Self.heldSQL, []) { (Self.text($0, 0), Self.text($0, 1)) } }
    }

    static let heldSQL = """
        SELECT s.msg_id, s.recipient FROM states s JOIN messages m ON m.msg_id=s.msg_id GROUP BY s.msg_id, s.recipient
        \t\tHAVING SUM(CASE WHEN s.state='held' THEN 0 ELSE 1 END)=0 ORDER BY MIN(m.seq)
        """

    public func one(_ msgID: String) throws -> ChatStored {
        let seqs = try sync { try self.query("SELECT seq FROM messages WHERE msg_id=?", [.text(msgID)]) { sqlite3_column_int64($0, 0) } }
        guard let seq = seqs.first else { throw ChatStoreError(description: "no such message") }
        let ms = try page(where: "seq=?", [.int(seq)], ascending: false, limit: 1)
        guard ms.count == 1 else { throw ChatStoreError(description: "no such message") }
        return ms[0]
    }

    /// Up to limit messages with seq > after (after > 0) and seq < before (before > 0), oldest first; forward paging takes
    /// the oldest of them, otherwise the newest. more: there are more in that direction.
    public func page(after: Int64, before: Int64, limit: Int) throws -> (messages: [ChatStored], more: Bool) {
        let limit = max(limit, 1)
        var w = "1=1"
        var args: [SQLValue] = []
        if after > 0 { w += " AND seq>?"; args.append(.int(after)) }
        if before > 0 { w += " AND seq<?"; args.append(.int(before)) }
        let forward = after > 0
        var ms = try page(where: w, args, ascending: forward, limit: limit + 1)
        var more = false
        if ms.count > limit {
            more = true
            if forward { ms = Array(ms.prefix(limit)) } else { ms = Array(ms.dropFirst()) }
        }
        return (ms, more)
    }

    private func page(where w: String, _ args: [SQLValue], ascending: Bool, limit: Int) throws -> [ChatStored] {
        try sync {
            var out = try self.query("""
                SELECT seq,msg_id,sender,recipients,re_msg_id,content,at,kind,attachments,mentions,private,revealed,sender_info,edited_at,deleted_at,deleted_by FROM messages WHERE \(w) ORDER BY seq \(ascending ? "ASC" : "DESC") LIMIT ?
                """, args + [.int(Int64(limit))]) { s -> ChatStored in
                var m = ChatStored(kind: Self.text(s, 7), msgID: Self.text(s, 1), from: Self.text(s, 2), reMsgID: Self.text(s, 4),
                                   content: Self.text(s, 5), at: sqlite3_column_double(s, 6))
                m.seq = sqlite3_column_int64(s, 0)
                m.to = Self.stringList(Self.text(s, 3))
                if case .array(let a)? = try? ChatJSON.parse(Array(Self.text(s, 8).utf8)) { m.attachments = a }
                m.mentions = Self.stringList(Self.text(s, 9))
                m.isPrivate = sqlite3_column_int64(s, 10) != 0
                m.revealed = sqlite3_column_int64(s, 11) != 0
                let snd = Self.text(s, 12)
                if !snd.isEmpty { m.sender = (try? ChatJSON.parse(Array(snd.utf8))).flatMap(ChatSender.read) ?? ChatSender(kind: "", id: "", name: "", verified: false) }
                m.editedAt = sqlite3_column_double(s, 13)
                m.deletedAt = sqlite3_column_double(s, 14)
                m.deletedBy = Self.text(s, 15)
                return m
            }
            if !ascending { out.reverse() }
            for i in out.indices {
                let id = out[i].msgID
                out[i].states = try self.query("SELECT recipient,state,at,detail FROM states WHERE msg_id=? ORDER BY at", [.text(id)]) {
                    ChatState(msgID: id, recipient: Self.text($0, 0), state: Self.text($0, 1), at: sqlite3_column_double($0, 2), detail: Self.text($0, 3))
                }
                out[i].reactions = try self.query("SELECT who,reaction,at FROM reactions WHERE msg_id=? ORDER BY at", [.text(id)]) {
                    let r = Self.text($0, 1)
                    return ChatReaction(msgID: id, who: Self.text($0, 0), reaction: r, emoji: ChatReactions.of(r)?.emoji ?? "",
                                        at: sqlite3_column_double($0, 2))
                }
            }
            return out
        }
    }

    /// Each (message, recipient) that is queued and was never handed over, failed or cancelled: recorded and waiting,
    /// or held and then released. Oldest message first.
    public func pending() throws -> [(String, String)] {
        try sync { try self.query(Self.pendingSQL, []) { (Self.text($0, 0), Self.text($0, 1)) } }
    }

    static let pendingSQL = """
        SELECT s.msg_id, s.recipient FROM states s JOIN messages m ON m.msg_id=s.msg_id GROUP BY s.msg_id, s.recipient
        \t\tHAVING SUM(CASE WHEN s.state IN ('queued','held') THEN 0 ELSE 1 END)=0 AND SUM(CASE WHEN s.state='queued' THEN 1 ELSE 0 END)>0
        \t\tORDER BY MIN(m.seq)
        """

    /// An import's quiet (`ChatImport.stage`, on a staged copy only — never a live room): every (message, recipient) still
    /// waiting to be handed over (`pendingSQL`) and every unconfirmed hand-over, for anyone but the human, gets a
    /// `cancelled` state with `detail`; every hand-over and notice row goes. Held messages stay held. In one transaction.
    /// Who was cancelled, how many each; how many notices went.
    public func quietForImport(human: String, detail: String, at: Double) throws -> (cancelled: [String: Int], notices: Int) {
        try sync {
            try self.exec("BEGIN IMMEDIATE")
            do {
                var pairs: [(String, String)] = try self.query(Self.pendingSQL, []) { (Self.text($0, 0), Self.text($0, 1)) }
                pairs += try self.query("SELECT msg_id, recipient FROM handovers ORDER BY handed_at", []) { (Self.text($0, 0), Self.text($0, 1)) }
                var seen = Set<String>(), out: [String: Int] = [:]
                for (id, who) in pairs where who != human && seen.insert(id + "\u{0}" + who).inserted {
                    try self.run("INSERT OR REPLACE INTO states(msg_id,recipient,state,at,detail) VALUES(?,?,'cancelled',?,?)",
                                 [.text(id), .text(who), .real(at), .text(detail)])
                    out[who, default: 0] += 1
                }
                try self.run("DELETE FROM handovers", [])
                let notices = Int(try self.run("DELETE FROM notices", []))
                try self.exec("COMMIT")
                return (out, notices)
            } catch {
                try? self.exec("ROLLBACK")
                throw error
            }
        }
    }

    /// Whether name has the message as far as an edit or delete notice goes: handed over, or beyond.
    public func handed(_ msgID: String, to name: String) -> Bool {
        count("SELECT COUNT(*) FROM states WHERE msg_id=? AND recipient=? AND state IN ('woken','delivered','started','answered')", msgID, name) > 0
    }

    /// Whether name has confirmed the message: delivered, or beyond.
    public func acked(_ msgID: String, by name: String) -> Bool {
        count("SELECT COUNT(*) FROM states WHERE msg_id=? AND recipient=? AND state IN ('delivered','started','answered')", msgID, name) > 0
    }

    private func count(_ sql: String, _ a: String, _ b: String) -> Int64 {
        (try? sync { try self.query(sql, [.text(a), .text(b)]) { sqlite3_column_int64($0, 0) } })?.first ?? 0
    }

    /// What decides who may see a message: direct, revealed, its sender and those it is for. nil when not in this room.
    public func visibility(_ msgID: String) -> (isPrivate: Bool, revealed: Bool, from: String, to: [String])? {
        (try? sync {
            try self.query("SELECT private, revealed, sender, recipients FROM messages WHERE msg_id=?", [.text(msgID)]) {
                (sqlite3_column_int64($0, 0) != 0, sqlite3_column_int64($0, 1) != 0, Self.text($0, 2), Self.stringList(Self.text($0, 3)))
            }
        })?.first
    }

    public func setRevealed(_ msgID: String) throws {
        _ = try sync { try self.run("UPDATE messages SET revealed=1 WHERE msg_id=?", [.text(msgID)]) }
    }

    /// Up to limit msg_ids that start with prefix, newest first.
    public func matching(_ prefix: String, limit: Int) -> [String] {
        guard Self.isIDStart(prefix) else { return [] }
        return (try? sync {
            try self.query("SELECT msg_id FROM messages WHERE msg_id LIKE ? ORDER BY seq DESC LIMIT ?", [.text(prefix + "%"), .int(Int64(limit))]) { Self.text($0, 0) }
        }) ?? []
    }

    /// `^[0-9A-Fa-f-]+$`: what the start of a msg_id may be — the characters of a uuid, at least one.
    public static func isIDStart(_ s: String) -> Bool {
        !s.isEmpty && s.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x41...0x46).contains($0) || (0x61...0x66).contains($0) || $0 == 0x2D }
    }

    /// The messages whose attachments name a file id: who may read each.
    public func namesFile(_ id: String) -> [(from: String, to: [String], isPrivate: Bool, revealed: Bool)] {
        (try? sync {
            try self.query("SELECT sender, recipients, private, revealed FROM messages WHERE instr(attachments,?)>0", [.text(id)]) {
                (Self.text($0, 0), Self.stringList(Self.text($0, 1)), sqlite3_column_int64($0, 2) != 0, sqlite3_column_int64($0, 3) != 0)
            }
        }) ?? []
    }

    /// Whether a message other than except still refers to a file id, in its attachments or its text.
    public func usesFile(_ id: String, except: String) -> Bool {
        let n = (try? sync {
            try self.query("SELECT COUNT(*) FROM messages WHERE msg_id<>? AND (instr(attachments,?)>0 OR instr(content,?)>0)",
                           [.text(except), .text(id), .text(id)]) { sqlite3_column_int64($0, 0) }
        })?.first ?? 0
        return n > 0
    }

    /// The newest ordinary message sender wrote that is not deleted, or "".
    public func latest(of sender: String) -> String {
        (try? sync {
            try self.query("SELECT msg_id FROM messages WHERE sender=? AND kind='' AND deleted_at=0 ORDER BY seq DESC LIMIT 1", [.text(sender)]) { Self.text($0, 0) }
        })?.first ?? ""
    }

    /// Replaces a message's text, addressing and mentions and records when. The old text is not kept.
    public func edit(_ msgID: String, content: String, to: [String], mentions: [String], at: Double) throws {
        _ = try sync {
            try self.run("UPDATE messages SET content=?, recipients=?, mentions=?, edited_at=? WHERE msg_id=? AND deleted_at=0",
                         [.text(content), .text(ChatJSON.encodeString(.strings(to))), .text(ChatJSON.encodeString(.strings(mentions))), .real(at), .text(msgID)])
        }
    }

    /// Erases a message's text, attachments, mentions and reactions and leaves a tombstone, in one transaction.
    public func delete(_ msgID: String, by: String, at: Double) throws {
        _ = try sync {
            try self.exec("BEGIN")
            do {
                try self.run("UPDATE messages SET content='', attachments='[]', mentions='[]', deleted_at=?, deleted_by=? WHERE msg_id=? AND deleted_at=0",
                             [.real(at), .text(by), .text(msgID)])
                try self.run("DELETE FROM reactions WHERE msg_id=?", [.text(msgID)])
                try self.exec("COMMIT")
            } catch {
                try? self.exec("ROLLBACK")
                throw error
            }
        }
    }

    /// What a viewer has not seen after seq `after`: the newest seq in the log, how many ordinary messages came after it,
    /// and how many of those name the viewer with @. Not counted: the viewer's own, changes, deleted messages, and direct
    /// messages the viewer cannot read.
    public func unread(after: Int64, viewer: String) throws -> (last: Int64, count: Int64, mentions: Int64) {
        let q = "\"" + viewer + "\""
        return try sync {
            try self.query("""
                SELECT COALESCE((SELECT MAX(seq) FROM messages),0),
                \t\tCOUNT(*), COALESCE(SUM(CASE WHEN instr(mentions,?)>0 THEN 1 ELSE 0 END),0)
                \t\tFROM messages WHERE seq>? AND kind='' AND sender<>?
                \t\tAND deleted_at=0 AND (private=0 OR revealed=1 OR instr(recipients,?)>0)
                """, [.text(q), .int(after), .text(viewer), .text(q)]) {
                (sqlite3_column_int64($0, 0), sqlite3_column_int64($0, 1), sqlite3_column_int64($0, 2))
            }
        }.first ?? (0, 0, 0)
    }

    /// The newest ordinary message the viewer may read, its text cut to 140 characters and "…".
    public func preview(viewer: String) -> (msgID: String, from: String, text: String, at: Double)? {
        let q = "\"" + viewer + "\""
        guard var p = (try? sync {
            try self.query("""
                SELECT msg_id, sender, content, at FROM messages WHERE kind='' AND deleted_at=0
                \t\tAND (private=0 OR revealed=1 OR sender=? OR instr(recipients,?)>0) ORDER BY seq DESC LIMIT 1
                """, [.text(viewer), .text(q)]) { (Self.text($0, 0), Self.text($0, 1), Self.text($0, 2), sqlite3_column_double($0, 3)) }
        })?.first else { return nil }
        if p.2.unicodeScalars.count > 140 { p.2 = String(String.UnicodeScalarView(p.2.unicodeScalars.prefix(140))) + "…" }
        return (p.0, p.1, p.2, p.3)
    }

    // MARK: polling sessions' bookkeeping (never read by the page)

    public struct Handover: Sendable { public var msgID: String; public var handedAt: Double; public var ver: Double }
    public struct Notice: Sendable { public var id: Int64; public var item: String; public var handedAt: Double }

    /// Records that a polling session was handed a message and has not confirmed it; ver is its edited_at then.
    public func handover(_ msgID: String, to name: String, at: Double, ver: Double) throws {
        _ = try sync {
            try self.run("INSERT OR REPLACE INTO handovers(msg_id,recipient,handed_at,ver) VALUES(?,?,?,?)", [.text(msgID), .text(name), .real(at), .real(ver)])
        }
    }

    /// What name was handed and has not confirmed, oldest first.
    public func handovers(_ name: String) -> [Handover] {
        (try? sync {
            try self.query("SELECT msg_id,handed_at,ver FROM handovers WHERE recipient=? ORDER BY handed_at", [.text(name)]) {
                Handover(msgID: Self.text($0, 0), handedAt: sqlite3_column_double($0, 1), ver: sqlite3_column_double($0, 2))
            }
        }) ?? []
    }

    /// Removes the record of an unconfirmed hand-over; its ver, or nil when there was none.
    public func takeHandover(_ msgID: String, from name: String) -> Double? {
        try? sync { () -> Double? in
            guard let ver = try self.query("SELECT ver FROM handovers WHERE msg_id=? AND recipient=?", [.text(msgID), .text(name)], { sqlite3_column_double($0, 0) }).first else {
                return nil
            }
            return try self.run("DELETE FROM handovers WHERE msg_id=? AND recipient=?", [.text(msgID), .text(name)]) > 0 ? ver : nil
        } ?? nil
    }

    /// The notices for name not yet confirmed, oldest first.
    public func notices(_ name: String) -> [Notice] {
        (try? sync {
            try self.query("SELECT id,item,handed_at FROM notices WHERE recipient=? ORDER BY id", [.text(name)]) {
                Notice(id: sqlite3_column_int64($0, 0), item: Self.text($0, 1), handedAt: sqlite3_column_double($0, 2))
            }
        }) ?? []
    }

    public func handNotice(_ id: Int64, at: Double) {
        _ = try? sync { try self.run("UPDATE notices SET handed_at=? WHERE id=?", [.real(at), .int(id)]) }
    }

    /// Removes a notice name confirmed; whether there was one.
    @discardableResult
    public func ackNotice(_ id: Int64, by name: String) -> Bool {
        ((try? sync { try self.run("DELETE FROM notices WHERE id=? AND recipient=?", [.int(id), .text(name)]) }) ?? 0) > 0
    }

    // MARK: commands that are not stored as messages (/edit, /delete, /react)

    /// Records that a command with this msg_id is being handled. When the msg_id was used already, by a command or a
    /// message, it is not claimed, and the first command's answer is returned ("pending" while it still runs).
    public func claimCommand(_ msgID: String, sender: String, at: Double) throws -> (claimed: Bool, state: String, detail: String) {
        if !self.sender(of: msgID).isEmpty { return (false, "", "") }
        return try sync {
            let n = try self.run("INSERT INTO commands(msg_id,sender,state,detail,at) VALUES(?,?,'pending','',?) ON CONFLICT(msg_id) DO NOTHING",
                                 [.text(msgID), .text(sender), .real(at)])
            if n == 1 { return (true, "", "") }
            let r = try self.query("SELECT state, detail FROM commands WHERE msg_id=?", [.text(msgID)]) { (Self.text($0, 0), Self.text($0, 1)) }.first
            return (false, r?.0 ?? "", r?.1 ?? "")
        }
    }

    /// Keeps the answer a claimed command gave; a refused one is forgotten, so it may be sent again.
    public func finishCommand(_ msgID: String, state: String, detail: String) {
        _ = try? sync {
            if state == "refused" { return try self.run("DELETE FROM commands WHERE msg_id=?", [.text(msgID)]) }
            return try self.run("UPDATE commands SET state=?, detail=? WHERE msg_id=?", [.text(state), .text(detail), .text(msgID)])
        }
    }

    /// The table names and the columns of `messages`, for checks of the format.
    public func columns(of table: String) throws -> [String] {
        try sync { try self.query("SELECT name FROM pragma_table_info(?)", [.text(table)]) { Self.text($0, 0) } }
    }

    /// Every table and index the file declares, by name, with its SQL (as SQLite keeps it).
    public func schemaSQL() throws -> [String: String] {
        let rows = try sync {
            try self.query("SELECT name, COALESCE(sql,'') FROM sqlite_master WHERE type IN ('table','index')", []) { (Self.text($0, 0), Self.text($0, 1)) }
        }
        return Dictionary(rows, uniquingKeysWith: { a, _ in a })
    }

    public func journalMode() throws -> String {
        try sync { try self.query("PRAGMA journal_mode", []) { Self.text($0, 0) } }.first ?? ""
    }

    // MARK: SQLite

    enum SQLValue { case int(Int64), real(Double), text(String) }

    private func sync<T>(_ f: () throws -> T) throws -> T {
        try queue.sync {
            guard db != nil else { throw ChatStoreError(description: "\(path) is closed") }
            return try f()
        }
    }

    private func error() -> ChatStoreError { ChatStoreError(description: String(cString: sqlite3_errmsg(db))) }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw error() }
    }

    private func prepare(_ sql: String, _ args: [SQLValue]) throws -> OpaquePointer {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK, let st else { throw error() }
        for (i, a) in args.enumerated() {
            let idx = Int32(i + 1)
            switch a {
            case .int(let v): sqlite3_bind_int64(st, idx, v)
            case .real(let v): sqlite3_bind_double(st, idx, v)
            case .text(let v): sqlite3_bind_text(st, idx, v, -1, Self.transient)
            }
        }
        return st
    }

    /// Runs a statement; the number of rows it changed.
    @discardableResult
    private func run(_ sql: String, _ args: [SQLValue]) throws -> Int32 {
        let st = try prepare(sql, args)
        defer { sqlite3_finalize(st) }
        guard sqlite3_step(st) == SQLITE_DONE else { throw error() }
        return sqlite3_changes(db)
    }

    private func query<T>(_ sql: String, _ args: [SQLValue], _ row: (OpaquePointer) throws -> T) throws -> [T] {
        let st = try prepare(sql, args)
        defer { sqlite3_finalize(st) }
        var out: [T] = []
        while true {
            let rc = sqlite3_step(st)
            if rc == SQLITE_ROW { out.append(try row(st)); continue }
            if rc == SQLITE_DONE { return out }
            throw error()
        }
    }

    private static func text(_ s: OpaquePointer, _ i: Int32) -> String {
        guard let p = sqlite3_column_text(s, i) else { return "" }
        let n = Int(sqlite3_column_bytes(s, i))
        return String(decoding: UnsafeBufferPointer(start: p, count: n), as: UTF8.self)
    }

    private static func stringList(_ json: String) -> [String] {
        guard case .array(let a)? = try? ChatJSON.parse(Array(json.utf8)) else { return [] }
        return a.compactMap(\.stringValue)
    }
}
