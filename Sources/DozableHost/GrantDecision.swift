import Foundation

// The ONE decision: what an agent's answer is for one permission, in five steps — pure, no I/O. `doz why`, `doz permissions
// show`, the daemon's gate (`PermissionGate`) and the Can do tab all call it and print its words, so they never disagree.
//
//   1. any never wins — any of the four ceilings (Dozable's own, this Mac's, the bot's, the workspace's), or an explicit
//      never grant for this agent, its bot or a role it holds, in any scope that applies;
//   2. a permission grant — the most specific scope wins (room > workspace > everywhere), within one scope agent > bot > role;
//   3. the roles in the most specific scope that has any, combined to the more permissive answer;
//   4. nothing says anything: ask (`sudo` and `isolation.unfenced` fail closed: never; an unknown permission: ask);
//   5. the cap — the result capped by the strictest ceiling (an ask ceiling turns allow into ask).
//
// The owner is never a subject: nothing here is ever asked about the owner (`PermissionGate` returns first for them).

/// A role an agent holds because its workspace's record says so (an entry's `role`) — never written as a grant.
public struct HeldRole: Equatable, Sendable {
    public var role: String
    public var workspace: String
    public init(role: String, workspace: String) { self.role = role; self.workspace = workspace }
}

/// Who asks, for what, where.
public struct GrantQuery: Equatable, Sendable {
    /// As shown (`bot2`, `mira`).
    public var name: String
    /// The agent's own workspace (nil: it is in none — a bot asked about in general).
    public var home: String?
    /// Its bot (the lasting identity), when it is one.
    public var bot: String?
    public var perm: String
    /// Where the action is: a workspace (nil: outside every workspace) and a room's label in it.
    public var workspace: String?
    public var room: String?
    /// What it is about, shown only (`~/src/SharedKit`).
    public var resource: String?
    /// The roles its workspace's record gives it.
    public var recordRoles: [HeldRole]

    public init(name: String, home: String?, bot: String?, perm: String, workspace: String?, room: String? = nil, resource: String? = nil,
                recordRoles: [HeldRole] = []) {
        self.name = name; self.home = home; self.bot = bot; self.perm = perm; self.workspace = workspace; self.room = room
        self.resource = resource; self.recordRoles = recordRoles
    }

    /// Its subject as an agent of a workspace (nil: not one).
    public var agentSubject: GrantSubject? { home.map { .agent($0, name) } }
}

/// Everything a decision reads, gathered by the caller (`GrantFactsReader`): the grants that may apply, the ceilings, and the
/// names the last line uses.
public struct GrantFacts: Equatable, Sendable {
    public var grants: [Grant]
    public var macCeiling: [String: GrantAnswer]
    public var botCeiling: [String: GrantAnswer]
    /// The bot's isolation ceiling (`fenced` or `vm`: `isolation.unfenced` is never).
    public var botIsolationCeiling: String?
    public var workspaceCeiling: [String: GrantAnswer]
    public var now: Date
    /// The owner's name in chat (nil: not named — "you").
    public var owner: String?
    /// The workspace's manager, and who holds the decider role there.
    public var manager: String?
    public var deciders: [String]

    public init(grants: [Grant] = [], macCeiling: [String: GrantAnswer] = [:], botCeiling: [String: GrantAnswer] = [:],
                botIsolationCeiling: String? = nil, workspaceCeiling: [String: GrantAnswer] = [:], now: Date = Date(), owner: String? = nil,
                manager: String? = nil, deciders: [String] = []) {
        self.grants = grants; self.macCeiling = macCeiling; self.botCeiling = botCeiling; self.botIsolationCeiling = botIsolationCeiling
        self.workspaceCeiling = workspaceCeiling; self.now = now; self.owner = owner; self.manager = manager; self.deciders = deciders
    }
}

/// The answer and how it was found: the five steps' words, the source of the answer, and the lines `doz why` prints.
public struct GrantDecision: Equatable, Sendable, Codable {
    public struct Step: Equatable, Sendable, Codable {
        public var n: Int
        public var label: String
        public var found: String
        /// This step decided (or, step 5, changed the answer).
        public var decided: Bool
    }
    public var answer: GrantAnswer
    public var perm: String
    public var steps: [Step]
    /// The step that decided (1–4; 5 when the cap changed it).
    public var decidedAt: Int
    /// What decided, in words ("bot2's ceiling: sudo=never", "the worker role (myapp-tests)").
    public var winner: String
    /// `ceiling`, `grant`, `role`, `default` or `dozable` — the source column of `doz permissions show`.
    public var source: String
    /// The role's answer came from the workspace's record (not a grant).
    public var fromRecord: Bool
    public var subjectLine: String
    public var outcome: String

    /// What `doz why` prints: the subject line, the five steps, the outcome.
    public var lines: [String] {
        var out = [subjectLine]
        for s in steps {
            if s.n == 4 && !s.decided { out.append("4 —"); continue }
            out.append((s.label as NSString).padding(toLength: s.n == 1 ? 26 : 27, withPad: " ", startingAt: 0) + s.found)
        }
        out.append(outcome)
        if answer == .ask { out.append("  Asks come later: for now an agent's request that would ask is refused.") }
        return out
    }

    public var text: String { lines.joined(separator: "\n") + "\n" }

    // MARK: the decision

    struct Lid {
        let name: String
        let caps: [String: GrantAnswer]
        /// The strictest cap this lid puts on a permission, an older id's included (765).
        func cap(_ perm: String) -> GrantAnswer? { GrantPermissions.answeringIds(perm).compactMap { caps[$0] }.min() }
    }

    /// A role's answer for a permission, else for an older id of it (765).
    static func roleAnswer(_ role: String, _ perm: String) -> GrantAnswer? {
        for id in GrantPermissions.answeringIds(perm) { if let a = RoleTable.answer(role, id) { return a } }
        return nil
    }

    /// The decision for `q` over `f`. Pure.
    public static func decide(_ q: GrantQuery, _ f: GrantFacts) -> GrantDecision {
        let perm = q.perm
        let ids = Set(GrantPermissions.answeringIds(perm))   // 765: an older id still answers for one release
        let now = f.now
        let active = f.grants.filter { $0.isActive(now) && $0.scopeValue?.applies(workspace: q.workspace, room: q.room) == true }
        let agentSubject = q.agentSubject
        let botSubject = q.bot.map(GrantSubject.bot)

        // The roles it holds where the action is: its record's (in its own workspace) and role grants to it.
        struct Held { let role: String; let scope: GrantScope; let fromRecord: Bool }
        var held: [Held] = q.recordRoles.filter { $0.workspace == q.workspace }.map { Held(role: $0.role, scope: .workspace($0.workspace), fromRecord: true) }
        for g in active {
            guard let r = g.role, RoleTable.isRole(r), r != "owner", let s = g.subjectValue, let sc = g.scopeValue else { continue }
            if s == agentSubject || s == botSubject { held.append(Held(role: r, scope: sc, fromRecord: false)) }
        }
        let heldNames = Set(held.map(\.role))
        func applies(_ g: Grant) -> Bool {
            guard let s = g.subjectValue else { return false }
            if s == agentSubject || s == botSubject { return true }
            if case .role(let r) = s { return heldNames.contains(r) }
            return false
        }
        func subjectRank(_ g: Grant) -> Int {
            switch g.subjectValue {
            case .agent?: 2
            case .bot?: 1
            default: 0
            }
        }

        // The four lids.
        var dozable: [String: GrantAnswer] = [:]
        let outside = q.home != nil && q.workspace != q.home
        if outside {
            // Another workspace is Dozable's own — unless an everywhere grant reaches it.
            let reaches = active.contains { g in
                g.scopeValue == .everywhere && applies(g)
                    && ((g.perm.map(ids.contains) == true && g.answerValue != nil && g.answerValue != .never) || (g.role.map { Self.roleAnswer($0, perm) != nil } ?? false))
            }
            if !reaches { dozable[perm] = .never }
        }
        var bot = f.botCeiling
        if let iso = f.botIsolationCeiling, iso == "fenced" || iso == "vm" { bot["isolation.unfenced"] = .never }
        let who = q.name
        let lids = [Lid(name: "Dozable's own", caps: dozable), Lid(name: "this Mac's ceiling", caps: f.macCeiling),
                    Lid(name: "\(q.bot ?? who)'s ceiling", caps: bot), Lid(name: "\(q.workspace ?? "the workspace")'s ceiling", caps: f.workspaceCeiling)]

        var steps: [Step] = []
        var answer: GrantAnswer?
        var decidedAt = 0
        var winner = ""
        var source = "default"
        var fromRecord = false

        // 1. any never.
        var nevers: [String] = []
        for l in lids where l.cap(perm) == .never {
            nevers.append(l.name == "Dozable's own" ? (outside ? "Dozable's own: another workspace" : "Dozable's own") : "\(l.name): \(perm)=never")
        }
        let explicitNevers = active.filter { $0.perm.map(ids.contains) == true && $0.answerValue == .never && applies($0) }
            .sorted { ($0.scopeValue?.rank ?? 0, subjectRank($0)) > ($1.scopeValue?.rank ?? 0, subjectRank($1)) }
        for g in explicitNevers { nevers.append("your never ✎ (\(g.subjectValue?.display ?? g.subject), \(g.scopeValue?.display ?? g.scope))") }
        let anyCap = lids.contains { $0.cap(perm) != nil }
        if let first = nevers.first {
            answer = .never
            decidedAt = 1
            winner = first
            source = lids.contains(where: { $0.cap(perm) == .never }) ? (dozable[perm] == .never ? "dozable" : "ceiling") : "grant"
            steps.append(Step(n: 1, label: "1 any never", found: "never: " + nevers.joined(separator: "; "), decided: true))
        } else {
            steps.append(Step(n: 1, label: "1 any never", found: anyCap ? "none (no never in any ceiling or scope)" : "none (no ceiling, no never in any scope)",
                              decided: false))
        }

        // 2. a permission grant, most specific scope first; within it agent > bot > role.
        if answer == nil {
            let perms = active.filter { $0.perm.map(ids.contains) == true && $0.answerValue != nil && applies($0) }
            if let top = perms.map({ $0.scopeValue?.rank ?? 0 }).max() {
                let inScope = perms.filter { ($0.scopeValue?.rank ?? 0) == top }
                let bestSubject = inScope.map(subjectRank).max() ?? 0
                let chosen = inScope.filter { subjectRank($0) == bestSubject }
                let a = chosen.compactMap(\.answerValue).max() ?? .ask
                let g = chosen.first { $0.answerValue == a }!
                answer = a
                decidedAt = 2
                source = "grant"
                winner = "your grant ✎ \(perm)=\(a.rawValue) (\(g.subjectValue?.display ?? g.subject), \(g.scopeValue?.display ?? g.scope))"
                steps.append(Step(n: 2, label: "2 permission grants", found: "\(perm)=\(a.rawValue) ✎ (\(g.subjectValue?.display ?? g.subject), \(g.scopeValue?.display ?? g.scope))", decided: true))
            } else {
                steps.append(Step(n: 2, label: "2 permission grants", found: "none (room, workspace, everywhere)", decided: false))
            }
        } else {
            steps.append(Step(n: 2, label: "2 permission grants", found: "—", decided: false))
        }

        // 3. the roles in the most specific scope that has any, combined to the more permissive answer.
        // The decider role is given in chat, by the owner alone (`doz chat set NAME --role decider`): it is added to the
        // roles held wherever the action is (its words: "added to another role").
        let chatDecider = f.deciders.contains(q.name) || (q.bot.map { f.deciders.contains($0) } ?? false)
        if answer == nil {
            let top = held.map({ $0.scope.rank }).max()
            if top != nil || chatDecider {
                let here = top.map { t in held.filter { $0.scope.rank == t } } ?? []
                var names: [String] = []
                for h in here where !names.contains(h.role) { names.append(h.role) }
                if chatDecider && !names.contains("decider") { names.append("decider") }
                let where_ = here.first.map { $0.scope.display } ?? "chat"
                let answers = names.compactMap { Self.roleAnswer($0, perm) }
                if let a = answers.max() {
                    answer = a
                    decidedAt = 3
                    source = "role"
                    fromRecord = here.contains { $0.fromRecord && Self.roleAnswer($0.role, perm) == a }
                    winner = "the \(names.joined(separator: " + ")) role\(names.count == 1 ? "" : "s") (\(where_))"
                    steps.append(Step(n: 3, label: "3 roles here", found: "\(names.joined(separator: " + ")) (\(where_)): \(a.rawValue)", decided: true))
                } else {
                    steps.append(Step(n: 3, label: "3 roles here", found: "\(names.joined(separator: " + ")) (\(where_)): says nothing", decided: false))
                }
            } else {
                steps.append(Step(n: 3, label: "3 roles here", found: "none", decided: false))
            }
        } else {
            steps.append(Step(n: 3, label: "3 roles here", found: "—", decided: false))
        }

        // 4. nothing says anything.
        if answer == nil {
            // 767: journal.read is on by default for an agent in its own workspace.
            let ownDefault = GrantPermissions.defaultAllowInOwnWorkspace.contains(perm) && q.home != nil && q.workspace == q.home
            let a: GrantAnswer = GrantPermissions.failClosed.contains(perm) ? .never : ownDefault ? .allow : .ask
            answer = a
            decidedAt = 4
            source = "default"
            let why = !GrantPermissions.isKnown(perm) ? " (not a known permission)" : a == .never ? " (\(perm) fails closed)"
                : ownDefault ? " (\(perm) is on by default in its own workspace)" : ""
            winner = "nothing says anything: \(a.rawValue)\(why)"
            steps.append(Step(n: 4, label: "4 nothing says anything", found: a.rawValue + why, decided: true))
        } else {
            steps.append(Step(n: 4, label: "4 —", found: "", decided: false))
        }

        // 5. the cap: the strictest ceiling.
        var result = answer!
        let capLabel = "5 \(who)'s ceiling"
        if decidedAt == 1 {
            steps.append(Step(n: 5, label: capLabel, found: "—", decided: false))
        } else if let (lid, cap) = lids.compactMap({ l in l.cap(perm).map { (l, $0) } }).min(by: { $0.1 < $1.1 }) {
            if cap < result {
                steps.append(Step(n: 5, label: capLabel, found: "\(cap.rawValue) (\(lid.name)): \(result.rawValue) → \(cap.rawValue)", decided: true))
                winner = "\(lid.name): \(perm)=\(cap.rawValue), capping \(result.rawValue)"
                result = cap
                decidedAt = 5
                source = "ceiling"
            } else {
                steps.append(Step(n: 5, label: capLabel, found: "\(cap.rawValue) (\(lid.name)): no change", decided: false))
            }
        } else {
            steps.append(Step(n: 5, label: capLabel, found: "none set: no cap", decided: false))
        }

        let place = q.workspace.map { w in q.room.map { "\(w)/\($0)" } ?? w }
        let subjectLine = "\(who) · \(perm)\(q.resource.map { " " + $0 } ?? "") · " + (place.map { "in " + $0 } ?? "outside every workspace")
        let outcome: String
        switch result {
        case .allow:
            outcome = "→ allow · it runs"
        case .ask:
            let m = f.manager.flatMap { $0 == who || f.deciders.contains($0) ? nil : "; \($0) is not a decider here" } ?? ""
            outcome = "→ ask · an Ask to \(f.owner ?? "you") (owner)\(m)"
        case .never:
            outcome = "→ never · refused: \(winner)"
        }
        return GrantDecision(answer: result, perm: perm, steps: steps, decidedAt: decidedAt, winner: winner, source: source, fromRecord: fromRecord,
                             subjectLine: subjectLine, outcome: outcome)
    }

    /// The decision for an operation no agent may ask for at all (Dozable's own: an account, a key, a token, the daemon,
    /// the settings, the ceilings themselves, a terminal…): never, in the same five steps.
    public static func dozableOwn(name: String, op: String, workspace: String?) -> GrantDecision {
        let what = "\(op) is Dozable's own"
        let steps = [Step(n: 1, label: "1 any never", found: "never: Dozable's own — \(op) is never for an agent", decided: true),
                     Step(n: 2, label: "2 permission grants", found: "—", decided: false),
                     Step(n: 3, label: "3 roles here", found: "—", decided: false),
                     Step(n: 4, label: "4 —", found: "", decided: false),
                     Step(n: 5, label: "5 \(name)'s ceiling", found: "—", decided: false)]
        return GrantDecision(answer: .never, perm: op, steps: steps, decidedAt: 1, winner: what, source: "dozable", fromRecord: false,
                             subjectLine: "\(name) · \(op) · " + (workspace.map { "in " + $0 } ?? "outside every workspace"),
                             outcome: "→ never · refused: \(what)")
    }
}
