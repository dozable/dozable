import Foundation

// FEEDS: a notice — a typed message a FEED posts. A feed is a source of facts that is neither a person nor an agent: the
// run journal, the Mac's account, network, health and resource notices, and (a participant of kind `feed`) an outside
// system. A feed may post notices and nothing else: it never asks, decides, runs a command or reads the room.
//
// The shape is the chat protocol reference's (its feeds design note) — the reference leads, Dozable follows: a message
// `{kind: "notice", notice: {feed, kind, severity, subject, source, text, action?, dedupe?, ttl?, at, title?}}` beside a
// plain `content` for a client that knows nothing of notices: `[FEED · SEVERITY] Title: text (from NAME's LOG)`. `feed`
// is filled in by the server (the poster's name, or the daemon's feed for Dozable's own), never taken from the poster.
// Unknown fields are refused; no field is added without the reference. The room's file keeps the protocol's schema: the
// notice rides in the row's `sender_info` object beside the sender's own members (`ChatRoomStore`).
//
// What a notice may never be: free text typed into a session (`FeedSessionDelivery` types a FIXED sentence per feed), or a
// shell line to run — its action's command and args are one of Dozable's own read commands (`ChatNoticeCommand`).
// Update in place and acknowledge are not part of this: a repeat inside its window is not posted at all.

/// What a person or an agent may run about a notice: a label, a command and its arguments — Dozable's own read commands only.
public struct ChatNoticeAction: Sendable, Equatable {
    public var label: String
    public var command: String
    public var args: [String]

    public init(label: String, command: String, args: [String] = []) { self.label = label; self.command = command; self.args = args }

    /// The command line as words (the allowlist judges these).
    public var words: [String] { command.split(separator: " ", omittingEmptySubsequences: false).map(String.init) + args }
    public var line: String { words.joined(separator: " ") }

    public var json: JValue { .object([JMember("label", .string(label)), JMember("command", .string(command)), JMember("args", .strings(args))]) }
}

/// What a notice is about: `{type: identity | place | run | workspace, name}`.
public struct ChatNoticeSubject: Sendable, Equatable {
    public var type: String
    public var name: String
    public init(type: String, name: String) { self.type = type; self.name = name }
    public static let types = ["identity", "place", "run", "workspace"]
    public var json: JValue { .object([JMember("type", .string(type)), JMember("name", .string(name))]) }
}

/// Where a notice comes from: `{name, log}`, shown as "from NAME's LOG" (the journal's: the identity, `journal`).
public struct ChatNoticeSource: Sendable, Equatable {
    public var name: String
    public var log: String
    public init(name: String, log: String) { self.name = name; self.log = log }
    public var words: String { "from \(name)'s \(log)" }
    public var json: JValue { .object([JMember("name", .string(name)), JMember("log", .string(log))]) }
}

/// One notice.
public struct ChatNotice: Sendable, Equatable {
    /// Who posted it — filled in by the server.
    public var feed: String
    /// `FAMILY.WHAT` (`account.expired`, `health.crashed`, `resources.disk`, `journal.outcome`): what happened.
    public var kind: String
    /// `info`, `notice`, `warning` or `critical`.
    public var severity: String
    public var subject: ChatNoticeSubject
    public var source: ChatNoticeSource
    public var text: String
    public var action: ChatNoticeAction?
    /// Repeats of one dedupe inside its window are posted once.
    public var dedupe: String?
    /// Seconds it stays relevant.
    public var ttl: Int?
    /// RFC 3339, UTC.
    public var at: String
    /// Optional, plain text, one line, at most 120 characters.
    public var title: String?

    public init(feed: String = "", kind: String, severity: String, subject: ChatNoticeSubject, source: ChatNoticeSource, text: String,
                action: ChatNoticeAction? = nil, dedupe: String? = nil, ttl: Int? = nil, at: String = ChatNotice.now(), title: String? = nil) {
        self.feed = feed; self.kind = kind; self.severity = severity; self.subject = subject; self.source = source; self.text = text
        self.action = action; self.dedupe = dedupe; self.ttl = ttl; self.at = at; self.title = title
    }

    public static let severities = ["info", "notice", "warning", "critical"]
    public static let keys = ["feed", "kind", "severity", "subject", "source", "text", "action", "dedupe", "ttl", "at", "title"]

    /// Limits.
    public static let maximumText = 4096
    public static let maximumTitle = 120
    public static let maximumName = 200
    public static let maximumDedupe = 200
    public static let maximumTTL = 30 * 24 * 3600

    /// Now, as `at` is written.
    public static func now(_ d: Date = Date()) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: d)
    }

    /// Whether `s` is an RFC 3339 time in UTC (`Z`), with or without fractional seconds.
    public static func isUTCTime(_ s: String) -> Bool {
        guard s.hasSuffix("Z") else { return false }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if f.date(from: s) != nil { return true }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) != nil
    }

    /// `^[a-z][a-z0-9._-]*$`, at most 96 bytes, no trailing dot: a family, then what happened.
    public static func isKind(_ s: String) -> Bool {
        let u = Array(s.utf8)
        guard (1...96).contains(u.count), (0x61...0x7A).contains(u[0]), u.last != 0x2E else { return false }
        return u.allSatisfy { (0x61...0x7A).contains($0) || (0x30...0x39).contains($0) || $0 == 0x2D || $0 == 0x5F || $0 == 0x2E }
    }

    /// The family of a kind: its first part (`account.expired` → `account`).
    public var family: String { String(kind.split(separator: ".").first ?? "") }

    static func oneLine(_ s: String) -> Bool { !s.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) || $0 == "\u{2028}" || $0 == "\u{2029}" } }

    /// Why this notice cannot be posted (nil: it can). `feed` is not judged: the server fills it.
    public func refusal() -> String? {
        if !Self.isKind(kind) { return "a notice's kind is FAMILY.WHAT in lower case (account.expired, health.crashed)" }
        if !Self.severities.contains(severity) { return "a notice's severity is one of \(Self.severities.joined(separator: ", "))" }
        if !ChatNoticeSubject.types.contains(subject.type) { return "a notice's subject.type is one of \(ChatNoticeSubject.types.joined(separator: ", "))" }
        for (what, v) in [("subject.name", subject.name), ("source.name", source.name), ("source.log", source.log)] {
            if v.isEmpty || v.count > Self.maximumName || !Self.oneLine(v) { return "a notice's \(what) is one line of 1 to \(Self.maximumName) characters" }
        }
        if text.isEmpty { return "a notice needs its text" }
        if text.utf8.count > Self.maximumText { return "a notice's text is at most \(Self.maximumText) bytes" }
        if let t = title, t.isEmpty || t.count > Self.maximumTitle || !Self.oneLine(t) {
            return "a notice's title is plain text, one line, at most \(Self.maximumTitle) characters"
        }
        if let d = dedupe, d.isEmpty || d.count > Self.maximumDedupe || !Self.oneLine(d) { return "a notice's dedupe is 1 to \(Self.maximumDedupe) characters, one line" }
        if let t = ttl, t < 1 || t > Self.maximumTTL { return "a notice's ttl is 1 to \(Self.maximumTTL) seconds" }
        if !Self.isUTCTime(at) { return "a notice's at is an RFC 3339 time in UTC (2026-11-25T03:12:09Z)" }
        if let a = action {
            if a.label.isEmpty || a.label.count > Self.maximumTitle || !Self.oneLine(a.label) { return "a notice's action needs a one-line label" }
            if let why = ChatNoticeCommand.refusal(a.words) { return why }
        }
        return nil
    }

    /// The shape on the wire, in field order (empty optional fields left out).
    public var json: JValue {
        var o = JObject()
        o.add("feed", .string(feed))
        o.add("kind", .string(kind))
        o.add("severity", .string(severity))
        o.add("subject", subject.json)
        o.add("source", source.json)
        o.add("text", .string(text))
        if let action { o.add("action", action.json) }
        if let dedupe { o.add("dedupe", .string(dedupe)) }
        if let ttl { o.add("ttl", .int(Int64(ttl))) }
        o.add("at", .string(at))
        if let title { o.add("title", .string(title)) }
        return o.value
    }

    /// Reads one, strictly: every key one of the fields (and of the nested objects), each of its type. A `feed` sent is read
    /// but the server replaces it.
    public static func read(_ v: JValue) throws -> ChatNotice {
        func strict(_ x: JValue, _ what: String, _ allowed: [String]) throws {
            guard case .object(let ms) = x else { throw ChatFieldError(description: "\(what): not an object") }
            if let bad = ms.first(where: { !allowed.contains($0.key) }) { throw ChatFieldError(description: "\(what): the unknown field \"\(bad.key)\"") }
        }
        try strict(v, "notice", keys)
        func s(_ x: JValue?, _ k: String) throws -> String { try x?.field(k)?.goString(k) ?? "" }
        guard let sub = v.field("subject"), !sub.isNull else { throw ChatFieldError(description: "notice: a subject is required") }
        try strict(sub, "notice.subject", ["type", "name"])
        guard let src = v.field("source"), !src.isNull else { throw ChatFieldError(description: "notice: a source is required") }
        try strict(src, "notice.source", ["name", "log"])
        var action: ChatNoticeAction?
        if let a = v.field("action"), !a.isNull {
            try strict(a, "notice.action", ["label", "command", "args"])
            action = ChatNoticeAction(label: try s(a, "label"), command: try s(a, "command"), args: try a.field("args")?.goStrings("notice.action.args") ?? [])
        }
        var ttl: Int?
        if let t = v.field("ttl"), !t.isNull { ttl = try t.goInt("notice.ttl") }
        func opt(_ k: String) throws -> String? {
            guard let x = v.field(k), !x.isNull else { return nil }
            return try x.goString("notice." + k)
        }
        return ChatNotice(feed: try s(v, "feed"), kind: try s(v, "kind"), severity: try s(v, "severity"),
                          subject: ChatNoticeSubject(type: try s(sub, "type"), name: try s(sub, "name")),
                          source: ChatNoticeSource(name: try s(src, "name"), log: try s(src, "log")),
                          text: try s(v, "text"), action: action, dedupe: try opt("dedupe"), ttl: ttl, at: try s(v, "at"), title: try opt("title"))
    }

    /// The plain line a client that knows nothing of notices shows: `[FEED · SEVERITY] Title: text (from NAME's LOG)`, and
    /// with no title `[FEED · SEVERITY] text (from NAME's LOG)`.
    public var plainText: String {
        "[\(feed) · \(severity)] " + (title.map { $0 + ": " } ?? "") + text + " (\(source.words))"
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
        refusal(command.split(separator: " ", omittingEmptySubsequences: false).map(String.init))
    }

    /// The same for a command and its arguments as words (an action's `command` split on spaces, then its `args`).
    public static func refusal(_ words: [String]) -> String? {
        let why = "a notice's action is one of Dozable's own read commands (doz workspace feeds W, doz account ls, dozchat receive, …), never a shell line"
        guard !words.isEmpty, words.joined(separator: " ").utf8.count <= 300 else { return why }
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
