import CryptoKit
import Foundation

// The Agent / Bot record (`<store>/bots/bots.json`, version 1): each lasting identity — its name in chat, the agent program
// it runs, its account, model and avatar, where it runs (its isolation), how the chat server reaches it, its skills, its
// instructions' hash and where its token is kept. Never a token: a held bot's token lives only in its own keychain item
// (`BotTokens`), a bot elsewhere's nowhere. Additive only, like the workspace record: every field this build does not know is
// kept, at the top level and in each bot, and a higher `version` is kept. `BotStore` reads and writes it;
// `docs/engineering/workspaces.md` ("Agents / Bots").

/// Where a bot runs: by default, and (later) the most it may ever be given.
public struct BotIsolation: Codable, Equatable, Sendable {
    /// `vm`, `fenced`, `unfenced` or `elsewhere`.
    public var `default`: String
    /// The ceiling (nil: none set).
    public var ceiling: String?
    public var unknown = UnknownFields()
    static let known: Set<String> = ["default", "ceiling"]

    /// The choices, in the order they are offered.
    public static let choices = ["vm", "fenced", "unfenced", "elsewhere"]

    public init(default d: String, ceiling: String? = nil) { self.default = d; self.ceiling = ceiling }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicKey.self)
        self.default = try c.decode(String.self, forKey: "default")
        ceiling = try c.decodeIfPresent(String.self, forKey: "ceiling")
        unknown = try UnknownFields(c, known: Self.known)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicKey.self)
        try unknown.encode(&c, known: Self.known)
        try c.encode(self.default, forKey: "default")
        try c.encodeIfPresent(ceiling, forKey: "ceiling")
    }

    /// Dozable holds the token of a bot that runs here (vm, fenced, unfenced); a bot elsewhere holds its own.
    public var held: Bool { self.default != "elsewhere" }

    /// As a person reads it: an unfenced bot acts as you, and says so wherever it shows.
    public static func words(_ s: String) -> String { s == "unfenced" ? "unfenced (acts as you)" : s }
}

/// The instructions' hash and size (the text is `bots/<name>/instructions.md`).
public struct BotInstructions: Codable, Equatable, Sendable {
    public var sha256: String
    public var bytes: Int
    public var updatedAt: Date
    public init(sha256: String, bytes: Int, updatedAt: Date) { self.sha256 = sha256; self.bytes = bytes; self.updatedAt = updatedAt }
}

/// Where the bot's token is: `dozable` (its keychain item), `elsewhere` (shown once, never kept) or `none` (retired). The
/// fingerprint is 12 hex of the token's SHA-256 — never the token.
public struct BotTokenState: Codable, Equatable, Sendable {
    public var keeper: String
    public var fingerprint: String?
    public var at: Date
    public init(keeper: String, fingerprint: String?, at: Date) { self.keeper = keeper; self.fingerprint = fingerprint; self.at = at }

    public static let keepers = ["dozable", "elsewhere", "none"]
}

/// One Agent / Bot.
public struct BotRecord: Codable, Equatable, Sendable {
    public var name: String
    public var createdAt: Date
    /// `new` (made by `doz bot new`) or `adopted` (an existing participant in chat).
    public var origin: String
    /// The agent program, as resolved (`claude-code`, `codex`, …).
    public var agent: String
    public var model: String?
    /// An account of the store, or `mac`.
    public var account: String?
    public var avatar: String?
    public var isolation: BotIsolation
    /// Its kind in chat (`claude-session`, `agent`, …).
    public var kind: String
    /// How the chat server reaches it: `inbox`, `poll` or `webhook`.
    public var deliver: String
    public var webhookEntry: String?
    public var session: String?
    public var skills: [String]
    public var instructions: BotInstructions?
    public var token: BotTokenState
    public var retiredAt: Date?
    /// Its ceiling: per permission the most it may ever be, `ask` or `never` (`doz bot ceiling`; nil: none set). Additive.
    public var ceilingAnswers: [String: String]?
    public var unknown = UnknownFields()
    static let known: Set<String> = ["name", "createdAt", "origin", "agent", "model", "account", "avatar", "isolation", "kind", "deliver",
                                     "webhookEntry", "session", "skills", "instructions", "token", "retiredAt", "ceilingAnswers"]

    public init(name: String, createdAt: Date, origin: String = "new", agent: String, model: String? = nil, account: String? = nil,
                avatar: String? = nil, isolation: BotIsolation, kind: String, deliver: String = "poll", webhookEntry: String? = nil,
                session: String? = nil, skills: [String] = [], instructions: BotInstructions? = nil, token: BotTokenState, retiredAt: Date? = nil) {
        self.name = name; self.createdAt = createdAt; self.origin = origin; self.agent = agent; self.model = model; self.account = account
        self.avatar = avatar; self.isolation = isolation; self.kind = kind; self.deliver = deliver; self.webhookEntry = webhookEntry
        self.session = session; self.skills = skills; self.instructions = instructions; self.token = token; self.retiredAt = retiredAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicKey.self)
        name = try c.decode(String.self, forKey: "name")
        createdAt = try c.decode(Date.self, forKey: "createdAt")
        origin = try c.decodeIfPresent(String.self, forKey: "origin") ?? "new"
        agent = try c.decode(String.self, forKey: "agent")
        model = try c.decodeIfPresent(String.self, forKey: "model")
        account = try c.decodeIfPresent(String.self, forKey: "account")
        avatar = try c.decodeIfPresent(String.self, forKey: "avatar")
        isolation = try c.decode(BotIsolation.self, forKey: "isolation")
        kind = try c.decodeIfPresent(String.self, forKey: "kind") ?? "agent"
        deliver = try c.decodeIfPresent(String.self, forKey: "deliver") ?? "poll"
        webhookEntry = try c.decodeIfPresent(String.self, forKey: "webhookEntry")
        session = try c.decodeIfPresent(String.self, forKey: "session")
        skills = try c.decodeIfPresent([String].self, forKey: "skills") ?? []
        instructions = try c.decodeIfPresent(BotInstructions.self, forKey: "instructions")
        token = try c.decode(BotTokenState.self, forKey: "token")
        retiredAt = try c.decodeIfPresent(Date.self, forKey: "retiredAt")
        ceilingAnswers = try c.decodeIfPresent([String: String].self, forKey: "ceilingAnswers")
        unknown = try UnknownFields(c, known: Self.known)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicKey.self)
        try unknown.encode(&c, known: Self.known)
        try c.encode(name, forKey: "name")
        try c.encode(createdAt, forKey: "createdAt")
        try c.encode(origin, forKey: "origin")
        try c.encode(agent, forKey: "agent")
        try c.encodeIfPresent(model, forKey: "model")
        try c.encodeIfPresent(account, forKey: "account")
        try c.encodeIfPresent(avatar, forKey: "avatar")
        try c.encode(isolation, forKey: "isolation")
        try c.encode(kind, forKey: "kind")
        try c.encode(deliver, forKey: "deliver")
        try c.encodeIfPresent(webhookEntry, forKey: "webhookEntry")
        try c.encodeIfPresent(session, forKey: "session")
        try c.encode(skills, forKey: "skills")
        try c.encodeIfPresent(instructions, forKey: "instructions")
        try c.encode(token, forKey: "token")
        try c.encodeIfPresent(retiredAt, forKey: "retiredAt")
        if let a = ceilingAnswers, !a.isEmpty { try c.encode(a, forKey: "ceilingAnswers") }
    }

    public var retired: Bool { retiredAt != nil }
    /// A token Dozable keeps in the keychain right now.
    public var holdsToken: Bool { !retired && token.keeper == "dozable" }
}

/// `bots.json`.
public struct BotsFile: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    /// Kept as read — a newer doz's file keeps its version.
    public var version: Int
    public var bots: [BotRecord]
    public var unknown = UnknownFields()
    static let known: Set<String> = ["version", "bots"]

    public init(bots: [BotRecord] = []) { version = Self.currentVersion; self.bots = bots }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicKey.self)
        version = try c.decodeIfPresent(Int.self, forKey: "version") ?? 1
        bots = try c.decodeIfPresent([BotRecord].self, forKey: "bots") ?? []
        unknown = try UnknownFields(c, known: Self.known)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicKey.self)
        try unknown.encode(&c, known: Self.known)
        try c.encode(max(version, Self.currentVersion), forKey: "version")
        try c.encode(bots, forKey: "bots")
    }

    public func bot(_ name: String) -> BotRecord? { bots.first { $0.name == name } }
    public func index(_ name: String) -> Int? { bots.firstIndex { $0.name == name } }
    /// The bots still in service (not retired).
    public var active: [BotRecord] { bots.filter { !$0.retired } }
}

/// Bot names: the chat name rule (a lower-case letter, then lower-case letters, digits and -, at most 40; never `chat`), never
/// the human's, and never a retired bot's — its old messages keep the name.
public enum BotName {
    /// Why `name` cannot be a new bot's (nil: it can). `human`: chat's human (nil: none named yet).
    public static func refusal(_ name: String, human: String?, file: BotsFile) -> HostError? {
        if let why = ChatNames.refusal(name) { return HostError(.invalid, why) }
        if name == human { return HostError(.invalid, "\(name) is you in chat — a bot needs a name of its own") }
        if let b = file.bot(name) {
            if let at = b.retiredAt { return retiredRefusal(name, at) }
            return HostError(.exists, "there is already a bot \(name) (doz bot show \(name))")
        }
        return nil
    }

    public static func validate(_ name: String, human: String?, file: BotsFile) throws {
        if let e = refusal(name, human: human, file: file) { throw e }
    }

    /// The words for a retired name, wherever it is refused.
    public static func retiredRefusal(_ name: String, _ at: Date) -> HostError {
        HostError(.exists, "\(name) was a bot, retired \(day(at)) — the name stays with its old messages")
    }

    /// A day as `2026-11-19`.
    public static func day(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }
}

/// A bot's kind in chat, from its agent program: Claude Code is a `claude-session`; every other agent is an `agent`.
public enum BotKinds {
    public static func kind(forAgent agent: String) -> String {
        var a = agent.lowercased()
        if let slash = a.lastIndex(of: "/") { a = String(a[a.index(after: slash)...]) }
        if let at = a.firstIndex(of: "@") { a = String(a[..<at]) }
        return a == "claude-code" ? "claude-session" : "agent"
    }
}

/// What a person may set on a bot: each checked before anything is written.
public enum BotFields {
    public static let maximumSkills = 32

    public static func checkModel(_ s: String) throws {
        guard (1...120).contains(s.count), !s.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || $0.value < 0x20 }) else {
            throw HostError(.invalid, "--model: 1–120 characters, no spaces")
        }
    }

    public static func checkAvatar(_ s: String) throws {
        guard (1...64).contains(s.count), !s.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
            throw HostError(.invalid, "--avatar: 1–64 characters, no line breaks")
        }
    }

    public static func checkSkills(_ skills: [String]) throws {
        guard skills.count <= maximumSkills else { throw HostError(.invalid, "--skills: at most \(maximumSkills)") }
        for s in skills {
            guard (1...64).contains(s.utf8.count), !s.hasPrefix("-"),
                  s.utf8.allSatisfy({ ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2D || $0 == 0x5F }) else {
                throw HostError(.invalid, "--skills: \(s.prefix(60)) is not a skill's name — a-z, 0-9, - and _")
            }
        }
        guard Set(skills).count == skills.count else { throw HostError(.invalid, "--skills: a skill is named twice") }
    }

    public static func checkIsolation(_ s: String) throws {
        guard BotIsolation.choices.contains(s) else {
            throw HostError(.invalid, "--isolation is sandbox, fenced, unfenced or elsewhere, not \(s.prefix(40))")
        }
    }

    /// The instructions' text: UTF-8, at most 256 KiB.
    public static func checkInstructions(_ d: Data) throws {
        guard d.count <= BotStore.maximumInstructionsBytes else {
            throw HostError(.invalid, "the instructions are \(d.count) bytes — at most \(BotStore.maximumInstructionsBytes >> 10) KiB")
        }
        guard String(data: d, encoding: .utf8) != nil else { throw HostError(.invalid, "the instructions are not UTF-8 text") }
    }

    public static func sha256(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }
}
