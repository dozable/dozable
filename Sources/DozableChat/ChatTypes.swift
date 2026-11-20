import Foundation

// The chat protocol's shapes: a participant of the directory, a message as stored and returned, its delivery states and
// reactions, and who sent it. Each writes itself in the field order and with the omissions of the protocol's wire shape.

/// One directory entry.
public struct ChatParticipant: Sendable, Equatable {
    public var name: String
    public var kind: String       // human, claude-session, grok-bot
    public var deliver: String    // web, inbox-socket, webhook, poll
    public var session = ""       // inbox-socket: the session's name
    public var webhook = ""       // webhook: the name of its stored address, never the address
    public var launcher = ""      // poll: who registered it
    public var identity = ""      // vendor:product:name; from the kind when empty
    public var avatar = ""        // the avatar it starts with
    /// Roles the owner gives a participant in the config. `decider`: a participant that is not human may decide asks
    /// (ChatAsks.swift). A human is a decider without it.
    public var roles: [String] = []

    public init(name: String, kind: String, deliver: String, session: String = "", webhook: String = "", launcher: String = "",
                identity: String = "", avatar: String = "", roles: [String] = []) {
        self.name = name; self.kind = kind; self.deliver = deliver; self.session = session; self.webhook = webhook
        self.launcher = launcher; self.identity = identity; self.avatar = avatar; self.roles = roles
    }

    public var isHuman: Bool { kind == "human" }
    public func hasRole(_ r: String) -> Bool { roles.contains(r) }

    /// How messages reach it: its deliver value, except that a participant that is not the human and has no deliver
    /// value at all collects what is addressed to it with GET /agent/receive, as a registered session does.
    public var route: String { deliver.isEmpty && !isHuman ? "poll" : deliver }

    /// The participant's fixed identity: its own, else one made from its kind.
    public var fixedIdentity: String {
        if !identity.isEmpty { return identity }
        switch kind {
        case "claude-session": return "anthropic:claude-code:" + name
        case "grok-bot": return "xai:grok-bot:" + name
        case "human": return "human:" + name
        default: return "unknown:agent:" + name
        }
    }

    /// The shape of the directory in the state and the stored files: only the optional fields that are set.
    public var json: JValue {
        var o = JObject()
        o.add("name", .string(name)); o.add("kind", .string(kind)); o.add("deliver", .string(deliver))
        o.omitEmpty("session", session); o.omitEmpty("webhook", webhook); o.omitEmpty("launcher", launcher)
        o.omitEmpty("identity", identity); o.omitEmpty("avatar", avatar)
        if !roles.isEmpty { o.add("roles", .strings(roles)) }
        return o.value
    }

    /// Reads one entry. Strict: every key must be one of the fields, and each a string.
    public static func read(_ v: JValue, strict: Bool) throws -> ChatParticipant {
        guard case .object(let members) = v else { throw ChatFieldError(description: "a participant is not an object") }
        let known: Set<String> = ["name", "kind", "deliver", "session", "webhook", "launcher", "identity", "avatar", "roles"]
        if strict, let bad = members.first(where: { !known.contains($0.key) }) {
            throw ChatFieldError(description: "a participant has the unknown key \"\(bad.key)\"")
        }
        func s(_ k: String) throws -> String { try v.field(k)?.goString(k) ?? "" }
        return ChatParticipant(name: try s("name"), kind: try s("kind"), deliver: try s("deliver"), session: try s("session"),
                               webhook: try s("webhook"), launcher: try s("launcher"), identity: try s("identity"),
                               avatar: try s("avatar"), roles: try v.field("roles")?.goStrings("roles") ?? [])
    }
}

/// Who a message is from, set by the server from its directory.
public struct ChatSender: Sendable, Equatable {
    public var kind: String   // human, or bot
    public var id: String
    public var name: String
    public var verified: Bool

    public init(kind: String, id: String, name: String, verified: Bool) {
        self.kind = kind; self.id = id; self.name = name; self.verified = verified
    }

    public var json: JValue {
        .object([JMember("kind", .string(kind)), JMember("id", .string(id)), JMember("name", .string(name)),
                 JMember("verified", .bool(verified))])
    }

    static func read(_ v: JValue) -> ChatSender? {
        guard v.isObject else { return nil }
        func s(_ k: String) -> String { ((try? v.field(k)?.goString(k)) ?? nil) ?? "" }
        return ChatSender(kind: s("kind"), id: s("id"), name: s("name"),
                          verified: ((try? v.field("verified")?.goBool("verified")) ?? nil) ?? false)
    }
}

/// One delivery state of one message for one recipient.
public struct ChatState: Sendable, Equatable {
    public var msgID: String
    public var recipient: String
    public var state: String
    public var at: Double
    public var detail = ""

    public init(msgID: String, recipient: String, state: String, at: Double, detail: String = "") {
        self.msgID = msgID; self.recipient = recipient; self.state = state; self.at = at; self.detail = detail
    }

    public var json: JValue {
        var o = JObject()
        o.add("msg_id", .string(msgID)); o.add("recipient", .string(recipient)); o.add("state", .string(state))
        o.add("at", .double(at)); o.omitEmpty("detail", detail)
        return o.value
    }
}

/// One participant's reaction on a message.
public struct ChatReaction: Sendable, Equatable {
    public var msgID: String
    public var who: String
    public var reaction: String
    public var emoji: String
    public var at: Double
    /// In a live event only: it was taken off.
    public var removed = false

    public init(msgID: String, who: String, reaction: String, emoji: String, at: Double, removed: Bool = false) {
        self.msgID = msgID; self.who = who; self.reaction = reaction; self.emoji = emoji; self.at = at; self.removed = removed
    }

    public var json: JValue {
        var o = JObject()
        o.add("msg_id", .string(msgID)); o.add("who", .string(who)); o.add("reaction", .string(reaction))
        o.add("emoji", .string(emoji)); o.add("at", .double(at)); o.omitEmpty("removed", removed)
        return o.value
    }
}

/// The standard reactions, in the order a client shows them.
public enum ChatReactions {
    /// The answer to a reaction that is none of these and not an emoji of its own.
    public static let help = "a reaction is one of like, love, lol, wow, sad, thanks, yes, no, eyes, party, or an emoji of your own"

    public static let standard: [(name: String, emoji: String)] = [
        ("like", "\u{1F44D}"), ("love", "\u{2764}\u{FE0F}"), ("lol", "\u{1F602}"), ("wow", "\u{1F62E}"), ("sad", "\u{1F622}"),
        ("thanks", "\u{1F64F}"), ("yes", "\u{2705}"), ("no", "\u{274C}"), ("eyes", "\u{1F440}"), ("party", "\u{1F389}"),
    ]

    /// What a sender wrote as a reaction: the stored name and the emoji to show, or nil when it is not one.
    public static func of(_ text: String) -> (name: String, emoji: String)? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let low = s.lowercased()
        for r in standard where low == r.name || s == r.emoji { return r }
        guard !s.isEmpty, s.unicodeScalars.count <= 8 else { return nil }
        for u in s.unicodeScalars {
            if u.value < 0x80 || u.properties.isAlphabetic || u.properties.numericType != nil || u.properties.isWhitespace {
                return nil
            }
        }
        return (s, s)
    }
}

/// A message as kept in a room's log.
public struct ChatStored: Sendable, Equatable {
    public var seq: Int64 = 0
    public var kind = ""                 // "" for a message, "change" for a recorded change, "private" for a stub
    public var msgID: String
    public var from: String
    public var to: [String] = []
    public var reMsgID = ""
    public var content = ""
    public var at: Double
    public var states: [ChatState] = []
    public var reactions: [ChatReaction] = []
    /// Attachments as stored (their JSON objects, unchanged).
    public var attachments: [JValue] = []
    public var mentions: [String] = []
    public var sender: ChatSender?
    public var isPrivate = false
    public var revealed = false
    public var editedAt: Double = 0
    public var deletedAt: Double = 0
    public var deletedBy = ""
    /// An ask (kind `ask`): its questions, deciders, state and decision. Absent on a tombstone.
    public var ask: ChatAsk?

    public init(kind: String = "", msgID: String, from: String, to: [String] = [], reMsgID: String = "", content: String = "",
                at: Double, mentions: [String] = [], sender: ChatSender? = nil, isPrivate: Bool = false) {
        self.kind = kind; self.msgID = msgID; self.from = from; self.to = to; self.reMsgID = reMsgID; self.content = content
        self.at = at; self.mentions = mentions; self.sender = sender; self.isPrivate = isPrivate
    }

    public var deleted: Bool { deletedAt > 0 }

    /// The message shape of the protocol (`seq` … `deleted_by`).
    public var json: JValue {
        var o = JObject()
        o.add("seq", .int(seq))
        o.omitEmpty("kind", kind)
        o.add("msg_id", .string(msgID))
        o.add("from", .string(from))
        o.add("to", .strings(to))
        o.omitEmpty("re_msg_id", reMsgID)
        o.add("content", .string(content))
        o.add("at", .double(at))
        o.add("states", .array(states.map(\.json)))
        o.add("reactions", .array(reactions.map(\.json)))
        o.add("attachments", .array(attachments))
        o.add("mentions", .strings(mentions))
        if let sender { o.add("sender", sender.json) }
        o.omitEmpty("private", isPrivate)
        o.omitEmpty("revealed", revealed)
        o.omitEmpty("edited_at", editedAt)
        o.omitEmpty("deleted", deleted)
        o.omitEmpty("deleted_at", deletedAt)
        o.omitEmpty("deleted_by", deletedBy)
        if let ask { o.add("ask", ask.json) }
        return o.value
    }

    /// A change line: from whoever caused it, to nobody in particular, with no sender.
    public static func change(_ msgID: String, from: String, content: String, at: Double) -> ChatStored {
        ChatStored(kind: "change", msgID: msgID, from: from, content: content, at: at)
    }
}

/// A random version 4 uuid, in lower case.
public func chatNewID() -> String { UUID().uuidString.lowercased() }

/// Seconds since 1970, fractional.
public func chatNow() -> Double { Date().timeIntervalSince1970 }

/// `^[0-9a-f]{8}-…{12}$`, any case: what a msg_id must be.
public func chatIsUUID(_ s: String) -> Bool {
    let u = Array(s.utf8)
    guard u.count == 36 else { return false }
    for (i, c) in u.enumerated() {
        if i == 8 || i == 13 || i == 18 || i == 23 { if c != 0x2D { return false }; continue }
        let hex = (0x30...0x39).contains(c) || (0x61...0x66).contains(c) || (0x41...0x46).contains(c)
        if !hex { return false }
    }
    return true
}

/// A room name: `^[a-z0-9][a-z0-9_-]{0,63}$`.
public func chatIsRoomName(_ s: String) -> Bool {
    let u = Array(s.utf8)
    guard (1...64).contains(u.count) else { return false }
    for (i, c) in u.enumerated() {
        let ok = (0x61...0x7A).contains(c) || (0x30...0x39).contains(c) || (i > 0 && (c == 0x5F || c == 0x2D))
        if !ok { return false }
    }
    return true
}

/// A registered session's name: `^[a-z][a-z0-9-]{0,39}$`.
public func chatIsSessionName(_ s: String) -> Bool {
    let u = Array(s.utf8)
    guard (1...40).contains(u.count), (0x61...0x7A).contains(u[0]) else { return false }
    return u.allSatisfy { (0x61...0x7A).contains($0) || (0x30...0x39).contains($0) || $0 == 0x2D }
}

/// A Claude Code session's name, as its record says it: free text the person sets ("Release review", "ops on m1max"),
/// compared exactly. 1–100 characters; no control characters or line breaks, no `/` (never a path), no space at either end.
public func chatIsClaudeSessionName(_ s: String) -> Bool {
    let u = s.unicodeScalars
    guard (1...100).contains(u.count), let f = u.first, let l = u.last,
          !f.properties.isWhitespace, !l.properties.isWhitespace else { return false }
    return u.allSatisfy { c in
        c != "/" && !CharacterSet.controlCharacters.contains(c) && !CharacterSet.newlines.contains(c)
            && !(0x2028...0x2029).contains(c.value) && !(0x202A...0x202E).contains(c.value) && !(0x2066...0x2069).contains(c.value)
    }
}

/// A room's title: its words, each with a capital (`test-cap` → `Test Cap`).
public func chatRoomTitle(_ room: String) -> String {
    room.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == " " }).map { capitalFirst(String($0)) }.joined(separator: " ")
}

/// The first byte in upper case, as the reference does it for names (ASCII).
func capitalFirst(_ s: String) -> String {
    guard let f = s.first else { return s }
    return f.uppercased() + s.dropFirst()
}
