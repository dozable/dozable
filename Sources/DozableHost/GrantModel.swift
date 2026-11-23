import Foundation

// The permissions model for agents (what an agent may do in Dozable — not `doz net permissions`, which is what a sandbox's
// NETWORK may reach): one list of permissions, three answers, roles that bundle answers, grants in a scope and ceilings
// above them. This file holds the words and the stored shapes; `GrantDecision` finds an answer (one pure function),
// `GrantStore` reads and writes them, `PermissionGate` checks an agent's request at the daemon's door. The owner is never a
// subject: nothing here ever constrains the owner. docs/engineering/workspaces.md, "Permissions".

/// An answer: `never < ask < allow`.
public enum GrantAnswer: String, Codable, Sendable, CaseIterable, Comparable {
    case never, ask, allow

    var rank: Int { switch self { case .never: 0; case .ask: 1; case .allow: 2 } }
    public static func < (a: GrantAnswer, b: GrantAnswer) -> Bool { a.rank < b.rank }

    /// ✓ ? ✕ — the mockups' marks.
    public var mark: String { switch self { case .allow: "✓"; case .ask: "?"; case .never: "✕" } }
}

/// The one list of permissions, in the order they are shown.
public enum GrantPermissions {
    public struct Permission: Sendable, Equatable {
        public let id: String
        /// What it lets an agent do, in a few words.
        public let words: String
    }

    public static let list: [Permission] = [
        .init(id: "workspace.read", words: "read its workspace"),
        .init(id: "agent.start", words: "start agents"),
        .init(id: "agent.stop", words: "stop agents"),
        .init(id: "worker.start", words: "add workers"),
        .init(id: "worker.stop", words: "end workers"),
        .init(id: "isolation.unfenced", words: "run unfenced (acts as you)"),
        .init(id: "net.allow", words: "network sites and ports"),
        .init(id: "secret.use", words: "use a secret"),
        .init(id: "keychain.use", words: "use your Keychain"),
        .init(id: "folder.read", words: "read a folder beyond the workspace's"),
        .init(id: "folder.write", words: "write a folder beyond the workspace's"),
        .init(id: "delete", words: "delete files or places"),
        .init(id: "room.manage", words: "manage chat rooms"),
        .init(id: "chat.read", words: "read its rooms"),
        .init(id: "chat.post", words: "post in its rooms"),
        .init(id: "chat.decide", words: "answer an Ask"),
        .init(id: "workspace.sleep", words: "sleep and wake the workspace"),
        .init(id: "workspace.finish", words: "the old name of run.open and run.finish — still honoured for them this release"),
        .init(id: "run.open", words: "open a run (and reopen)"),
        .init(id: "run.finish", words: "finish a run"),
        .init(id: "description.propose", words: "propose a change to the work description (an Ask to the owner)"),
        .init(id: "description.decide", words: "apply or decline a proposal to the work description (its own too)"),
        .init(id: "description.edit", words: "change the work description directly, with no proposal"),
        .init(id: "journal.read", words: "read, follow and wait on a run's journal and its evidence (on by default in its own workspace)"),
        .init(id: "journal.write", words: "write a run's journal, any kind (journal.write:KIND: that kind only)"),
        .init(id: "journal.supersede", words: "correct another's journal entry (same kind, with the write permission for it)"),
        .init(id: "evidence.attach", words: "attach evidence to a journal entry (--attach, --attach-ref)"),
        .init(id: "workspace.archive", words: "archive and restore the workspace"),
        .init(id: "workspace.delete", words: "delete the workspace"),
        .init(id: "bot.manage", words: "make or retire Agents / Bots"),
        .init(id: "grant.give", words: "pass on what it holds, to its workers"),
        .init(id: "spend", words: "spend past the budget"),
        .init(id: "sudo", words: "run as root on this Mac"),
    ]

    public static let ids: [String] = list.map(\.id)
    static let known: Set<String> = Set(ids)

    public static func isKnown(_ p: String) -> Bool { known.contains(p) || kindOf(p) != nil }
    public static func words(_ p: String) -> String {
        if let k = kindOf(p) { return "write a run's journal, entries of kind \(k) only" }
        return list.first { $0.id == p }?.words ?? "not a known permission"
    }

    /// 767: the permissions a parameter narrows — `journal.write:KIND` (a kind of the journal's pattern) is
    /// `journal.write` for entries of that kind only; `journal.write` itself still answers for it.
    public static let parameterised = ["journal.write"]
    /// The kind `journal.write:KIND` names (nil: not that form).
    public static func kindOf(_ p: String) -> String? {
        for base in parameterised where p.hasPrefix(base + ":") {
            let k = String(p.dropFirst(base.count + 1))
            return JournalKinds.isValid(k) ? k : nil
        }
        return nil
    }

    /// 767: answered allow when nothing says anything, for an agent in its OWN workspace (withdrawn by a never or a grant):
    /// agents of a workspace already read its room.
    public static let defaultAllowInOwnWorkspace: Set<String> = ["journal.read"]

    /// 765: the older id a grant, role or ceiling may still name for a permission, honoured for one release so an existing
    /// grant keeps its meaning: `workspace.finish` (finish and reopen) answers for `run.open` and `run.finish`.
    public static let olderIds: [String: [String]] = ["run.open": ["workspace.finish"], "run.finish": ["workspace.finish"]]
    /// A permission and the older ids that still answer for it.
    public static func answeringIds(_ p: String) -> [String] {
        if kindOf(p) != nil, let base = p.split(separator: ":").first.map(String.init) { return [p, base] }   // 767: journal.write:KIND
        return [p] + (olderIds[p] ?? [])
    }

    /// Answered never when nothing says anything (they fail closed): root on this Mac, and running as you.
    public static let failClosed: Set<String> = ["sudo", "isolation.unfenced"]
    /// Given only by the owner, through `doz chat set NAME --role decider` (never a grant, never passed on).
    public static let ownerOnly: Set<String> = ["chat.decide"]

    /// The refusal for a permission this build does not know: with the list.
    public static func unknownRefusal(_ p: String) -> HostError {
        HostError(.invalid, "\(p.prefix(60)) is not a permission — one of: \(ids.joined(separator: ", ")), or journal.write:KIND")
    }
}

/// Where a grant applies: everywhere, a workspace, or one of its rooms (`W/R`, R the room's short label).
public enum GrantScope: Hashable, Sendable {
    case everywhere
    case workspace(String)
    case room(String, String)

    /// Room > workspace > everywhere.
    public var rank: Int { switch self { case .everywhere: 0; case .workspace: 1; case .room: 2 } }

    /// As stored: `everywhere`, `workspace:W`, `room:W/R`.
    public var stored: String {
        switch self {
        case .everywhere: "everywhere"
        case .workspace(let w): "workspace:" + w
        case .room(let w, let r): "room:\(w)/\(r)"
        }
    }

    /// As a person reads it: `everywhere`, `myapp-tests`, `myapp-tests/review`.
    public var display: String {
        switch self {
        case .everywhere: "everywhere"
        case .workspace(let w): w
        case .room(let w, let r): "\(w)/\(r)"
        }
    }

    /// The workspace it is in (nil: everywhere).
    public var workspace: String? {
        switch self {
        case .everywhere: nil
        case .workspace(let w), .room(let w, _): w
        }
    }

    public init?(stored s: String) {
        if s == "everywhere" { self = .everywhere; return }
        if s.hasPrefix("workspace:") {
            let w = String(s.dropFirst(10))
            guard WorkspaceName.isValid(w) else { return nil }
            self = .workspace(w)
            return
        }
        if s.hasPrefix("room:") {
            let rest = s.dropFirst(5).split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard rest.count == 2, WorkspaceName.isValid(rest[0]), WorkspaceName.isValid(rest[1]) else { return nil }
            self = .room(rest[0], rest[1])
            return
        }
        return nil
    }

    /// Whether a grant in this scope speaks for an action in workspace `w` (nil: outside every workspace), room `r`.
    public func applies(workspace w: String?, room r: String?) -> Bool {
        switch self {
        case .everywhere: true
        case .workspace(let x): x == w
        case .room(let x, let y): x == w && y == r
        }
    }
}

/// Who a grant is for: an Agent / Bot (the lasting identity), one agent of a workspace (anonymous workers included), or every
/// agent holding a role.
public enum GrantSubject: Hashable, Sendable {
    case bot(String)
    case agent(String, String)
    case role(String)

    /// As stored: `bot:NAME`, `agent:W/NAME`, `role:ROLE`.
    public var stored: String {
        switch self {
        case .bot(let n): "bot:" + n
        case .agent(let w, let n): "agent:\(w)/\(n)"
        case .role(let r): "role:" + r
        }
    }

    /// As a person reads it: `otto`, `demo/bot1`, `every worker`.
    public var display: String {
        switch self {
        case .bot(let n): n
        case .agent(let w, let n): "\(w)/\(n)"
        case .role(let r): "every \(r)"
        }
    }

    public init?(stored s: String) {
        if s.hasPrefix("bot:"), ChatNames.refusal(String(s.dropFirst(4))) == nil { self = .bot(String(s.dropFirst(4))); return }
        if s.hasPrefix("role:"), RoleTable.isRole(String(s.dropFirst(5))) { self = .role(String(s.dropFirst(5))); return }
        if s.hasPrefix("agent:") {
            let rest = s.dropFirst(6).split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            if rest.count == 2, WorkspaceName.isValid(rest[0]), WorkspaceName.isValidAgent(rest[1]) { self = .agent(rest[0], rest[1]); return }
        }
        return nil
    }
}

/// One grant: a role, or one permission's answer, for a subject in a scope — optionally until a date (then it ends, stays
/// listed "ended DATE" and never answers again). `by` is `you` in this version. Additive: fields this build does not know
/// are kept; an answer word this build does not know makes the grant say nothing.
public struct Grant: Codable, Equatable, Sendable {
    public var id: String
    public var subject: String
    public var role: String?
    public var perm: String?
    /// `allow`, `ask` or `never` (a permission grant's).
    public var answer: String?
    public var scope: String
    public var until: Date?
    public var by: String
    public var at: Date
    public var note: String?
    public var unknown = UnknownFields()
    static let known: Set<String> = ["id", "subject", "role", "perm", "answer", "scope", "until", "by", "at", "note"]

    public init(id: String = Grant.newID(), subject: GrantSubject, role: String? = nil, perm: String? = nil, answer: GrantAnswer? = nil,
                scope: GrantScope, until: Date? = nil, by: String = "you", at: Date = Date(), note: String? = nil) {
        self.id = id; self.subject = subject.stored; self.role = role; self.perm = perm; self.answer = answer?.rawValue
        self.scope = scope.stored; self.until = until; self.by = by; self.at = at; self.note = note
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicKey.self)
        id = try c.decodeIfPresent(String.self, forKey: "id") ?? ""
        subject = try c.decode(String.self, forKey: "subject")
        role = try c.decodeIfPresent(String.self, forKey: "role")
        perm = try c.decodeIfPresent(String.self, forKey: "perm")
        answer = try c.decodeIfPresent(String.self, forKey: "answer")
        scope = try c.decodeIfPresent(String.self, forKey: "scope") ?? "everywhere"
        until = try c.decodeIfPresent(Date.self, forKey: "until")
        by = try c.decodeIfPresent(String.self, forKey: "by") ?? "you"
        at = try c.decode(Date.self, forKey: "at")
        note = try c.decodeIfPresent(String.self, forKey: "note")
        unknown = try UnknownFields(c, known: Self.known)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicKey.self)
        try unknown.encode(&c, known: Self.known)
        try c.encode(id, forKey: "id")
        try c.encode(subject, forKey: "subject")
        try c.encodeIfPresent(role, forKey: "role")
        try c.encodeIfPresent(perm, forKey: "perm")
        try c.encodeIfPresent(answer, forKey: "answer")
        try c.encode(scope, forKey: "scope")
        try c.encodeIfPresent(until, forKey: "until")
        try c.encode(by, forKey: "by")
        try c.encode(at, forKey: "at")
        try c.encodeIfPresent(note, forKey: "note")
    }

    public var subjectValue: GrantSubject? { GrantSubject(stored: subject) }
    public var scopeValue: GrantScope? { GrantScope(stored: scope) }
    public var answerValue: GrantAnswer? { answer.flatMap(GrantAnswer.init(rawValue:)) }
    /// It still answers: no `until`, or `until` not yet passed.
    public func isActive(_ now: Date) -> Bool { until.map { $0 > now } ?? true }

    /// What it grants, as a person reads it: `worker` or `folder.read=ask`.
    public var what: String { role ?? "\(perm ?? "?")=\(answer ?? "?")" }

    public static func newID() -> String { String(format: "g%08x", UInt32.random(in: 0...UInt32.max)) }
}

/// A ceiling: per permission, the most it may ever be (`ask` or `never`; a permission not named has no cap). Stored as
/// `{perm: answer}` words; a word this build does not know caps nothing.
public enum GrantCeiling {
    /// The caps this build understands (`allow` is no cap, and is dropped).
    public static func caps(_ raw: [String: String]?) -> [String: GrantAnswer] {
        var out: [String: GrantAnswer] = [:]
        for (p, a) in raw ?? [:] { if let v = GrantAnswer(rawValue: a), v != .allow { out[p] = v } }
        return out
    }

    /// `perm=ask|never` as a person types it: the answer, else a refusal naming what is wrong.
    public static func parse(_ s: String) throws -> (String, GrantAnswer) {
        let parts = s.split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { throw HostError(.invalid, "\(s.prefix(60)): PERM=ask or PERM=never") }
        guard GrantPermissions.isKnown(parts[0]) else { throw GrantPermissions.unknownRefusal(parts[0]) }
        guard let a = GrantAnswer(rawValue: parts[1]), a != .allow else {
            throw HostError(.invalid, "\(parts[0]): a ceiling is ask or never (no ceiling means no cap — --clear \(parts[0]))")
        }
        return (parts[0], a)
    }
}

/// `PERM=allow|ask|never` as a person types it in a grant.
public enum GrantWords {
    public static func parse(_ s: String) throws -> (String, GrantAnswer) {
        let parts = s.split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { throw HostError(.invalid, "\(s.prefix(60)): a role, or PERM=allow|ask|never") }
        guard GrantPermissions.isKnown(parts[0]) else { throw GrantPermissions.unknownRefusal(parts[0]) }
        guard let a = GrantAnswer(rawValue: parts[1]) else { throw HostError(.invalid, "\(parts[0]): allow, ask or never — not \(parts[1].prefix(20))") }
        return (parts[0], a)
    }
}

/// A workspace's own grants and ceiling (`workspace.json`, key `permissions`). `requests` is what a space file asks for —
/// recorded, never consulted by a decision. Versioned and additive.
public struct WorkspaceGrants: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public var version: Int
    public var grants: [Grant]
    /// `{perm: ask|never}`.
    public var ceiling: [String: String]
    public var requests: [JSONValue]
    public var unknown = UnknownFields()
    static let known: Set<String> = ["version", "grants", "ceiling", "requests"]

    public init(grants: [Grant] = [], ceiling: [String: String] = [:], requests: [JSONValue] = []) {
        version = Self.currentVersion; self.grants = grants; self.ceiling = ceiling; self.requests = requests
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicKey.self)
        version = try c.decodeIfPresent(Int.self, forKey: "version") ?? 1
        grants = try c.decodeIfPresent([Grant].self, forKey: "grants") ?? []
        ceiling = try c.decodeIfPresent([String: String].self, forKey: "ceiling") ?? [:]
        requests = try c.decodeIfPresent([JSONValue].self, forKey: "requests") ?? []
        unknown = try UnknownFields(c, known: Self.known)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicKey.self)
        try unknown.encode(&c, known: Self.known)
        try c.encode(max(version, Self.currentVersion), forKey: "version")
        try c.encode(grants, forKey: "grants")
        try c.encode(ceiling, forKey: "ceiling")
        try c.encode(requests, forKey: "requests")
    }

    public var isEmpty: Bool { grants.isEmpty && ceiling.isEmpty && requests.isEmpty && unknown.extra.isEmpty }
}

/// `<store>/grants/grants.json`: the grants that apply everywhere and this Mac's ceiling. Versioned and additive.
public struct GrantsFile: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public var version: Int
    public var grants: [Grant]
    /// This Mac's ceiling, `{perm: ask|never}`.
    public var ceiling: [String: String]
    public var unknown = UnknownFields()
    static let known: Set<String> = ["version", "grants", "ceiling"]

    public init(grants: [Grant] = [], ceiling: [String: String] = [:]) {
        version = Self.currentVersion; self.grants = grants; self.ceiling = ceiling
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicKey.self)
        version = try c.decodeIfPresent(Int.self, forKey: "version") ?? 1
        grants = try c.decodeIfPresent([Grant].self, forKey: "grants") ?? []
        ceiling = try c.decodeIfPresent([String: String].self, forKey: "ceiling") ?? [:]
        unknown = try UnknownFields(c, known: Self.known)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicKey.self)
        try unknown.encode(&c, known: Self.known)
        try c.encode(max(version, Self.currentVersion), forKey: "version")
        try c.encode(grants, forKey: "grants")
        try c.encode(ceiling, forKey: "ceiling")
    }
}

/// The roles: each a named bundle of answers (a permission it does not name, it says nothing about). A preset is a role.
/// `owner` belongs to people and is never granted; `decider` (`chat.decide`) is given only by the owner, in chat; `admin` only
/// by the owner, everywhere only.
public enum RoleTable {
    public struct Role: Sendable, Equatable {
        public let name: String
        public let words: String
        public let answers: [String: GrantAnswer]
    }

    private static let a = GrantAnswer.allow, q = GrantAnswer.ask, n = GrantAnswer.never

    private static let managerAnswers: [String: GrantAnswer] = [
        "workspace.read": a, "agent.start": q, "agent.stop": q, "worker.start": a, "worker.stop": a, "isolation.unfenced": n,
        "net.allow": q, "secret.use": q, "keychain.use": q, "folder.read": q, "folder.write": q, "delete": q, "room.manage": q,
        "chat.read": a, "chat.post": a, "chat.decide": n, "workspace.sleep": q, "workspace.finish": q, "workspace.archive": q,
        "workspace.delete": n, "bot.manage": n, "grant.give": a, "spend": q, "sudo": n,
    ]

    public static let roles: [Role] = [
        Role(name: "owner", words: "you — never granted to an agent", answers: Dictionary(uniqueKeysWithValues: GrantPermissions.ids.map { ($0, a) })),
        Role(name: "manager", words: "runs a workspace", answers: managerAnswers),
        Role(name: "worker", words: "one task", answers: [
            "workspace.read": a, "agent.start": n, "agent.stop": n, "worker.start": q, "worker.stop": q, "isolation.unfenced": n,
            "net.allow": q, "secret.use": q, "keychain.use": q, "folder.read": q, "folder.write": q, "delete": q, "room.manage": n,
            "chat.read": a, "chat.post": a, "chat.decide": n, "workspace.sleep": n, "workspace.finish": q, "workspace.archive": n,
            "workspace.delete": n, "bot.manage": n, "grant.give": n, "spend": q, "sudo": n,
        ]),
        Role(name: "member", words: "a room member, often elsewhere", answers: [
            "workspace.read": n, "agent.start": n, "agent.stop": n, "worker.start": n, "worker.stop": n, "isolation.unfenced": n,
            "net.allow": n, "secret.use": n, "keychain.use": n, "folder.read": n, "folder.write": n, "delete": n, "room.manage": n,
            "chat.read": a, "chat.post": a, "chat.decide": n, "workspace.sleep": n, "workspace.finish": n, "workspace.archive": n,
            "workspace.delete": n, "bot.manage": n, "grant.give": n, "spend": n, "sudo": n,
        ]),
        Role(name: "decider", words: "added to another role: answers Asks", answers: ["chat.decide": a]),
        Role(name: "admin", words: "this Mac's helper, everywhere only", answers: [
            "workspace.read": a, "agent.start": a, "agent.stop": a, "worker.start": a, "worker.stop": a, "workspace.sleep": a,
            "chat.read": a, "chat.post": a,
            "net.allow": q, "folder.read": q, "folder.write": q, "secret.use": q, "room.manage": q, "workspace.finish": q,
            "workspace.archive": q, "workspace.delete": q, "bot.manage": q, "grant.give": q, "spend": q, "delete": q,
            "sudo": n, "isolation.unfenced": n, "keychain.use": n, "chat.decide": n,
        ]),
        Role(name: "reviewer", words: "a preset: writes the run's journal, attaches evidence and proposes changes to the work description",
             answers: ["journal.write": a, "evidence.attach": a, "description.propose": a]),
        Role(name: "cautious-manager", words: "a preset: a manager that asks before it starts or ends workers", answers:
            managerAnswers.merging(["worker.start": q, "worker.stop": q, "grant.give": q]) { _, b in b }),
        Role(name: "trusted-manager", words: "a preset: a manager that also sleeps, wakes and finishes without asking", answers:
            managerAnswers.merging(["agent.start": a, "agent.stop": a, "workspace.sleep": a, "workspace.finish": a, "run.finish": a,
                                    "room.manage": a]) { _, b in b }),
    ]

    public static let names: [String] = roles.map(\.name)
    public static func isRole(_ r: String) -> Bool { names.contains(r) }
    public static func role(_ r: String) -> Role? { roles.first { $0.name == r } }
    /// What role `r` says about `perm` (nil: nothing).
    public static func answer(_ r: String, _ perm: String) -> GrantAnswer? { role(r)?.answers[perm] }

    /// Why `r` cannot be granted to `subject` in `scope` (nil: it can).
    public static func grantRefusal(_ r: String, scope: GrantScope, subject: GrantSubject) -> HostError? {
        guard isRole(r) else {
            return HostError(.invalid, "\(r.prefix(40)) is not a role or PERM=answer — roles: \(names.filter { $0 != "owner" }.joined(separator: ", "))")
        }
        if r == "owner" { return HostError(.invalid, "the owner role is yours: it is never granted to an agent") }
        if r == "decider" { return HostError(.invalid, "deciders are made in chat, by you only: doz chat set NAME --role decider") }
        if r == "admin", scope != .everywhere { return HostError(.invalid, "the admin role is given everywhere only: doz permissions grant NAME admin --everywhere") }
        if case .role = subject { return HostError(.invalid, "a role is given to an Agent / Bot or an agent, not to a role") }
        return nil
    }
}

/// One line of `<store>/grants/log.jsonl` (and, for a workspace's, of its `log.jsonl`): `granted`, `revoked`, `ceiling-set`,
/// `request-recorded`, `permission-decided`. Never a token or a secret: names, permissions and answers only.
public struct GrantLogEntry: Codable, Equatable, Sendable {
    public var v: Int
    public var at: Date
    /// `you`, or the agent a decision was about.
    public var by: String
    public var action: String
    public var subject: String?
    public var perm: String?
    public var role: String?
    public var answer: String?
    public var scope: String?
    public var until: Date?
    public var id: String?
    public var op: String?
    public var reason: String?

    public init(at: Date = Date(), by: String = "you", action: String, subject: String? = nil, perm: String? = nil, role: String? = nil,
                answer: String? = nil, scope: String? = nil, until: Date? = nil, id: String? = nil, op: String? = nil, reason: String? = nil) {
        v = 1
        self.at = at; self.by = by; self.action = action; self.subject = subject; self.perm = perm; self.role = role
        self.answer = answer; self.scope = scope; self.until = until; self.id = id; self.op = op; self.reason = reason
    }

    public static let actions: Set<String> = ["granted", "revoked", "ceiling-set", "request-recorded", "permission-decided"]
}
