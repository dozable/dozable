import Foundation

// The `permissions-*` operations' request and answers (HostProtocol.swift, `HostOp.permissions*`). Additive, never a token.

/// `permissions-show | -why | -grant | -revoke | -ceiling`: what a person typed, as typed — the daemon resolves it.
public struct PermissionsRequest: Codable, Equatable, Sendable {
    /// The workspace (`show W`, `--in W`).
    public var workspace: String?
    /// A room: its label in `workspace`, or `W/R`.
    public var room: String?
    /// `--everywhere`.
    public var everywhere: Bool?
    /// The agent or bot asked about or given a grant (`--agent A`, `why AGENT`, `grant SUBJECT`): a name, `bot:NAME`,
    /// `agent:W/NAME` or `role:ROLE`.
    public var agent: String?
    /// `--bot B` (show, ceiling).
    public var bot: String?
    /// `--mac` (show, ceiling): this Mac's ceiling.
    public var mac: Bool?
    /// `show --roles`: the role table.
    public var roles: Bool?
    /// `why … PERM`.
    public var perm: String?
    /// grant: `ROLE` or `PERM=allow|ask|never` …; revoke: `ROLE` or `PERM`; ceiling: `PERM=ask|never` ….
    public var words: [String]?
    /// ceiling `--clear PERM` ….
    public var clear: [String]?
    /// grant `--until DATE`.
    public var until: Date?
    /// grant: `--until` as typed (`2h`) — what a `--request-id` retry is compared by, since `until` moves with the clock. Additive.
    public var untilTyped: String?

    public init(workspace: String? = nil, agent: String? = nil, perm: String? = nil) {
        self.workspace = workspace; self.agent = agent; self.perm = perm
    }
}

/// One grant as listed.
public struct GrantRow: Codable, Equatable, Sendable {
    public var id: String
    /// As a person reads it (`otto`, `demo/bot1`, `every worker`) and as stored (`bot:otto`).
    public var subject: String
    public var subjectStored: String
    /// `worker` or `folder.read=ask`.
    public var what: String
    /// `everywhere`, `demo`, `demo/review`.
    public var scope: String
    public var until: Date?
    /// Its `until` has passed: it is listed "ended DATE" and never answers again.
    public var ended: Bool
    public var by: String
    public var at: Date

    public init(_ g: Grant, now: Date) {
        id = g.id; subject = g.subjectValue?.display ?? g.subject; subjectStored = g.subject; what = g.what
        scope = g.scopeValue?.display ?? g.scope; until = g.until; ended = !g.isActive(now); by = g.by; at = g.at
    }
}

/// A ceiling's cap on one permission: whose ceiling (`mac`, `bot:NAME`, `workspace:W`, as read `this Mac's`…), and the cap.
public struct CeilingRow: Codable, Equatable, Sendable {
    public var lid: String
    public var words: String
    public var perm: String
    public var answer: String
    public init(lid: String, words: String, perm: String, answer: String) { self.lid = lid; self.words = words; self.perm = perm; self.answer = answer }
}

/// One permission's answer for one agent: the answer, its source, and where it is enforced.
public struct GrantAnswerRow: Codable, Equatable, Sendable {
    public var perm: String
    public var words: String
    public var answer: String
    /// `role`, `grant`, `ceiling`, `default` or `dozable`.
    public var source: String
    /// As a person reads it: "the worker role (demo) — from the workspace", "✎ your grant …", "▲ this Mac's ceiling …".
    public var sourceText: String
    /// "yes — through dozchat" (the journal's and the work description's), "not yet — …" (every other), or "promise — acts as
    /// you" for an unfenced agent.
    public var enforced: String
    /// The step that decided (1–5).
    public var step: Int

    public init(_ d: GrantDecision, enforced: String) {
        perm = d.perm; words = GrantPermissions.words(d.perm); answer = d.answer.rawValue; source = d.source; step = d.decidedAt
        self.enforced = enforced
        switch d.source {
        case "role": sourceText = d.winner + (d.fromRecord ? " — from the workspace" : " ✎")
        case "grant": sourceText = "✎ " + d.winner.replacingOccurrences(of: "your grant ✎ ", with: "your grant ").replacingOccurrences(of: "your never ✎ ", with: "your never ")
        case "ceiling", "dozable": sourceText = "▲ " + d.winner
        default: sourceText = "default — " + d.winner
        }
    }
}

/// One agent's answers (`permissions show W --agent A`, and each agent of `show W`).
public struct AgentGrantAnswers: Codable, Equatable, Sendable {
    public var name: String
    public var workspace: String?
    public var bot: String?
    /// Its roles, as read: "worker (from the workspace)", "decider ✎ (demo/review)".
    public var roles: [String]
    public var actsAsYou: Bool
    public var rows: [GrantAnswerRow]

    public init(name: String, workspace: String?, bot: String?, roles: [String], actsAsYou: Bool, rows: [GrantAnswerRow]) {
        self.name = name; self.workspace = workspace; self.bot = bot; self.roles = roles; self.actsAsYou = actsAsYou; self.rows = rows
    }

    /// "allow N · ask N · never N".
    public var counts: String {
        let c = Dictionary(grouping: rows, by: \.answer).mapValues(\.count)
        return "allow \(c["allow"] ?? 0) · ask \(c["ask"] ?? 0) · never \(c["never"] ?? 0)"
    }
}

/// A role as the table shows it: each permission's answer (`allow`, `ask`, `never`; missing: says nothing).
public struct RoleRow: Codable, Equatable, Sendable {
    public var name: String
    public var words: String
    public var answers: [String: String]
    public init(_ r: RoleTable.Role) { name = r.name; words = r.words; answers = r.answers.mapValues(\.rawValue) }
}

/// `permissions-show`'s answer.
public struct PermissionsShown: Codable, Equatable, Sendable {
    /// What was asked: `all`, `workspace`, `agent`, `bot`, `mac` or `roles`.
    public var view: String
    public var workspace: String?
    /// `--agent` / `--bot`: whom.
    public var subject: String?
    /// The agents' answers (one for `--agent`, every agent for `show W`).
    public var agents: [AgentGrantAnswers]
    public var grants: [GrantRow]
    public var ceilings: [CeilingRow]
    /// `--bot`: its role in each workspace, as read ("demo: manager (from the workspace)").
    public var botRoles: [String]?
    public var roleTable: [RoleRow]?
    /// Which agents' grants are enforced, as read (`PermissionWords.overall`).
    public var enforced: String
    public var notes: [String]

    public init(view: String, workspace: String? = nil, subject: String? = nil, agents: [AgentGrantAnswers] = [], grants: [GrantRow] = [],
                ceilings: [CeilingRow] = [], botRoles: [String]? = nil, roleTable: [RoleRow]? = nil, notes: [String] = []) {
        self.view = view; self.workspace = workspace; self.subject = subject; self.agents = agents; self.grants = grants
        self.ceilings = ceilings; self.botRoles = botRoles; self.roleTable = roleTable; enforced = PermissionWords.overall; self.notes = notes
    }
}

/// `permissions-grant | -revoke | -ceiling`'s answer: what changed, as lines, and the grants and ceilings now.
public struct PermissionsChanged: Codable, Equatable, Sendable {
    public var lines: [String]
    public var grants: [GrantRow]
    public var ceilings: [CeilingRow]
    public var notes: [String]
    /// grant with `--request-id`: the first answer to that id, given again — nothing was granted now. Additive.
    public var replayed: Bool?
    public init(lines: [String], grants: [GrantRow] = [], ceilings: [CeilingRow] = [], notes: [String] = []) {
        self.lines = lines; self.grants = grants; self.ceilings = ceilings; self.notes = notes
    }
}

/// The words every view of permissions shares.
public enum PermissionWords {
    /// 771: a permission no agent's request reaches yet (every one but the journal's and the work description's).
    public static let notYet = "not yet — an agent reaches only the journal and the work description"
    /// 771: the journal's and the work description's: an agent reaches them through dozchat, with its own token, and the
    /// daemon decides them.
    public static let enforcedNow = "yes — through dozchat"
    public static let promise = "promise — acts as you"
    /// What `permissions show` says of every agent's grants together.
    public static let overall = "for the run journal and the work description (through dozchat); nothing else yet"
    /// The sentence under every table: what is enforced, what this is, and that it is not `doz net permissions`.
    public static let footerLead = "Grants are enforced for the run journal and the work description, which an agent reaches through dozchat with "
        + "its own chat token; no other Dozable action is an agent's yet. "
    public static let footerRest = "They say what an agent may do in Dozable; what a sandbox's network may reach is doz net permissions."
    public static let footer = footerLead + footerRest
    /// The permissions an agent's request reaches today (`AgentRelay`): the journal's and the work description's.
    public static func reached(_ perm: String) -> Bool {
        let base = perm.split(separator: ":", maxSplits: 1).first.map(String.init) ?? perm
        return ["journal.read", "journal.write", "journal.supersede", "evidence.attach", "description.propose", "description.decide",
                "description.edit"].contains(base)
    }
    public static func enforced(_ perm: String, actsAsYou: Bool) -> String { actsAsYou ? promise : reached(perm) ? enforcedNow : notYet }
}
