import Foundation

// FEEDS: a notice — a typed message a FEED posts. A feed is a source of facts that is neither a person nor an agent: the
// run journal, the Mac's account, network, health and resource notices, and (a participant of kind `feed`) an outside
// system. A feed may post notices and nothing else: it never asks, decides, runs a command or reads the room.
//
// On the wire and in the room's file a notice is a message of kind `notice` that carries, beside its plain `content` (a
// readable line for a client that knows nothing of notices — the reference's own server shows exactly that), two fields:
// `feed` (who it is from) and `notice` {kind, severity, title, text, source, dedupeKey, action?}. The room's file keeps
// the protocol's schema unchanged: the two fields ride in the row's `sender_info` object, beside the sender's own members
// (`ChatRoomStore`), where a reader that does not know them passes over them.
//
// What a notice may never be: free text typed into a session (`FeedSessionDelivery` types a FIXED sentence per kind), or a
// shell line to run — its `action.command` is one of Dozable's own read or acknowledge commands (`ChatNoticeCommand`).
// Update in place and acknowledge are not part of this: a repeat inside its window is not posted at all.

/// What a person or an agent may run about a notice: a label and one of Dozable's own commands (never a shell line).
public struct ChatNoticeAction: Sendable, Equatable {
    public var label: String
    public var command: String

    public init(label: String = "", command: String) { self.label = label; self.command = command }

    public var json: JValue {
        var o = JObject()
        o.omitEmpty("label", label)
        o.add("command", .string(command))
        return o.value
    }
}

/// One notice.
public struct ChatNotice: Sendable, Equatable {
    /// `FAMILY.WHAT` (`account.expired`, `health.crashed`, `resources.disk`, `journal.outcome`): what happened.
    public var kind: String
    /// `info`, `notice`, `warning` or `critical`.
    public var severity: String
    public var title: String
    public var text: String
    /// What it is about, in words (`helper's journal`, `this Mac`, `the sandbox app-helper`).
    public var source: String
    /// Repeats of one key inside its window are posted once.
    public var dedupeKey: String
    public var action: ChatNoticeAction?

    public init(kind: String, severity: String, title: String, text: String, source: String = "", dedupeKey: String,
                action: ChatNoticeAction? = nil) {
        self.kind = kind; self.severity = severity; self.title = title; self.text = text; self.source = source
        self.dedupeKey = dedupeKey; self.action = action
    }

    public static let severities = ["info", "notice", "warning", "critical"]
    public static let keys = ["kind", "severity", "title", "text", "source", "dedupeKey", "action"]

    /// Limits, in UTF-8 bytes.
    public static let maximumText = 4096
    public static let maximumTitle = 200
    public static let maximumSource = 200
    public static let maximumKey = 200

    /// `^[a-z][a-z0-9-]{0,31}(\.[a-z0-9][a-z0-9._-]{0,63})?$`: a family, then what happened.
    public static func isKind(_ s: String) -> Bool {
        let u = Array(s.utf8)
        guard (1...96).contains(u.count), (0x61...0x7A).contains(u[0]) else { return false }
        var dots = 0
        for (i, c) in u.enumerated() {
            let ok = (0x61...0x7A).contains(c) || (0x30...0x39).contains(c) || c == 0x2D || c == 0x5F || c == 0x2E
            if !ok { return false }
            if c == 0x2E {
                dots += 1
                if i == u.count - 1 { return false }
            }
        }
        return dots <= 3
    }

    /// The family of a kind: its first part (`account.expired` → `account`).
    public var family: String { String(kind.split(separator: ".").first ?? "") }

    /// Why this notice cannot be posted (nil: it can).
    public func refusal() -> String? {
        if !Self.isKind(kind) { return "a notice's kind is FAMILY.WHAT in lower case (account.expired, health.crashed)" }
        if !Self.severities.contains(severity) { return "a notice's severity is one of \(Self.severities.joined(separator: ", "))" }
        if title.isEmpty && text.isEmpty { return "a notice needs a title or a text" }
        if title.utf8.count > Self.maximumTitle { return "a notice's title is at most \(Self.maximumTitle) bytes" }
        if text.utf8.count > Self.maximumText { return "a notice's text is at most \(Self.maximumText) bytes" }
        if source.utf8.count > Self.maximumSource { return "a notice's source is at most \(Self.maximumSource) bytes" }
        if dedupeKey.isEmpty || dedupeKey.utf8.count > Self.maximumKey { return "a notice's dedupeKey is 1 to \(Self.maximumKey) bytes" }
        if dedupeKey.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) { return "a notice's dedupeKey has a control character" }
        if let a = action {
            if a.label.utf8.count > Self.maximumTitle { return "a notice's action label is at most \(Self.maximumTitle) bytes" }
            if let why = ChatNoticeCommand.refusal(a.command) { return why }
        }
        return nil
    }

    /// The shape on the wire, in field order.
    public var json: JValue {
        var o = JObject()
        o.add("kind", .string(kind))
        o.add("severity", .string(severity))
        o.omitEmpty("title", title)
        o.omitEmpty("text", text)
        o.omitEmpty("source", source)
        o.add("dedupeKey", .string(dedupeKey))
        if let action { o.add("action", action.json) }
        return o.value
    }

    /// Reads one, strictly: every key one of the fields, each of its type.
    public static func read(_ v: JValue) throws -> ChatNotice {
        guard case .object(let members) = v else { throw ChatFieldError(description: "notice: not an object") }
        if let bad = members.first(where: { !keys.contains($0.key) }) { throw ChatFieldError(description: "notice: the unknown key \"\(bad.key)\"") }
        func s(_ k: String) throws -> String { try v.field(k)?.goString("notice." + k) ?? "" }
        var action: ChatNoticeAction?
        if let a = v.field("action"), !a.isNull {
            guard case .object(let am) = a else { throw ChatFieldError(description: "notice.action: not an object") }
            if let bad = am.first(where: { $0.key != "label" && $0.key != "command" }) {
                throw ChatFieldError(description: "notice.action: the unknown key \"\(bad.key)\"")
            }
            action = ChatNoticeAction(label: try a.field("label")?.goString("notice.action.label") ?? "",
                                      command: try a.field("command")?.goString("notice.action.command") ?? "")
        }
        return ChatNotice(kind: try s("kind"), severity: try s("severity"), title: try s("title"), text: try s("text"),
                          source: try s("source"), dedupeKey: try s("dedupeKey"), action: action)
    }

    /// The plain line a client that knows nothing of notices shows: `[notice · warning · health] title — text (source)`.
    public func plainText(feed: String) -> String {
        var s = "[notice · \(severity) · \(feed)] "
        if !title.isEmpty { s += title }
        if !text.isEmpty { s += title.isEmpty ? text : " — " + text }
        if !source.isEmpty { s += " (\(source))" }
        if let a = action { s += "\n" + (a.label.isEmpty ? "Run: " : a.label + ": ") + a.command }
        return s
    }
}

/// The commands a notice's action may name: Dozable's own read and acknowledge commands, as plain words — never a shell
/// line (no quote, pipe, redirection, variable, glob, separator or line break), never a command that changes anything.
public enum ChatNoticeCommand {
    /// The allowed commands, by their first words. A command is allowed when its words start with one of these, every word
    /// is plain (letters, digits and `@ . _ : / = # + , -`) and none of the rest is a verb that changes something.
    public static let allowed: [[String]] = [
        ["doz", "account", "ls"], ["doz", "account", "verify"],
        ["doz", "workspace", "show"], ["doz", "workspace", "state"], ["doz", "workspace", "feeds"], ["doz", "workspace", "journal"],
        ["doz", "workspace", "log"], ["doz", "workspace", "reach"], ["doz", "workspace", "runs"],
        ["doz", "net", "log"], ["doz", "net", "show"], ["doz", "ls"], ["doz", "resources"], ["doz", "doctor"],
        ["doz", "chat", "read"], ["doz", "chat", "rooms"], ["doz", "chat", "who"], ["doz", "chat", "status"],
        ["dozchat", "receive"], ["dozchat", "rooms"], ["dozchat", "journal"], ["dozchat", "ask-show"], ["dozchat", "protocol"],
    ]

    /// Words that change something: never after an allowed start (`doz resources clean`, `dozchat journal add`,
    /// `doz workspace feeds W --emit`).
    public static let changing: Set<String> = ["add", "rm", "remove", "clean", "send", "end", "delete", "set", "new", "kill", "stop", "start",
                                               "restart", "reset", "forget", "decide", "apply", "grant", "revoke", "token", "on", "off",
                                               "wait", "--emit", "--fix", "--prune", "--new", "--yes", "-y"]

    /// Why `command` may not be a notice's action (nil: it may).
    public static func refusal(_ command: String) -> String? {
        let why = "a notice's action is one of Dozable's own read commands (doz workspace feeds W, doz account ls, dozchat receive, …), never a shell line"
        guard !command.isEmpty, command.utf8.count <= 300 else { return why }
        let words = command.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard !words.contains(where: \.isEmpty) else { return why }
        for w in words where !w.unicodeScalars.allSatisfy(isPlain) { return why }
        guard let a = allowed.first(where: { a in words.count >= a.count && Array(words.prefix(a.count)) == a }) else { return why }
        if words.dropFirst(a.count).contains(where: { changing.contains($0) || $0.hasPrefix("--emit=") }) { return why }
        return nil
    }

    static func isPlain(_ c: Unicode.Scalar) -> Bool {
        switch c {
        case "a"..."z", "A"..."Z", "0"..."9", "@", ".", "_", ":", "/", "=", "#", "+", ",", "-": true
        default: false
        }
    }
}

/// Repeats and floods, per feed: a notice whose dedupeKey was posted inside its window is not posted again (counted, so a
/// later line can say how many were held back), and a feed posts at most `limit` notices per `per` seconds. Pure: the
/// clock is the caller's. Not thread-safe: its owner serialises it.
public struct ChatNoticeThrottle: Sendable {
    public var window: Double
    public var limit: Int
    public var per: Double
    private var lastPosted: [String: Double] = [:]
    private var recent: [String: [Double]] = [:]
    private var held: [String: Int] = [:]

    public init(window: Double = 600, limit: Int = 5, per: Double = 60) { self.window = window; self.limit = limit; self.per = per }

    public enum Decision: Equatable, Sendable {
        /// Post it; `heldBefore`: how many of this feed were held back since its last post (say it once).
        case post(heldBefore: Int)
        /// The same key inside its window.
        case repeated
        /// The feed is over its rate.
        case rateLimited
    }

    /// Whether to post the notice `key` of `feed` (in `scope` — a workspace) at `now`; a post is recorded.
    public mutating func decide(scope: String, feed: String, key: String, now: Double) -> Decision {
        let k = scope + "\u{1F}" + feed + "\u{1F}" + key
        let f = scope + "\u{1F}" + feed
        if let t = lastPosted[k], now - t < window {
            held[f, default: 0] += 1
            return .repeated
        }
        var times = (recent[f] ?? []).filter { now - $0 < per }
        if times.count >= limit {
            recent[f] = times
            held[f, default: 0] += 1
            return .rateLimited
        }
        times.append(now)
        recent[f] = times
        lastPosted[k] = now
        let before = held[f] ?? 0
        held[f] = 0
        // Old keys go: nothing is kept past its window.
        if lastPosted.count > 4096 { lastPosted = lastPosted.filter { now - $0.value < window } }
        return .post(heldBefore: before)
    }
}
