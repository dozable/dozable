import Foundation
import DozerKit
import DozerHost

// 617 stage D (616.03, the owner's ruling: Quick try is in phase 1) — the dashboard's half of `doz try`:
//
//   · `POST /api/v1/plan` {purpose, name?, agent?, base?, isolated?} — changes nothing: the host's read-only `plan` (the
//     ONE planner `--dry-run` prints) for those choices, as `WebPlan` (the command, the project file, what it can reach,
//     the image's readiness, the problems, and the `create` fields the ordinary create action takes).
//   · `GET /api/v1/try` — the Quick try page's list: every agent this build has a recipe for with its try plan and, when
//     no key of its provider is there, its "What you need" card (`TryCard`, the CLI's); the agents that are coming,
//     dimmed with why.

/// The plan's question, decoded strictly.
public struct WebPlanQuery: Equatable, Sendable {
    public var purpose = "try"
    public var name: String?
    public var agent: String?
    public var base: String?
    public var isolated = false

    public static func decode(_ body: Data) throws -> WebPlanQuery {
        guard let obj = try? JSONSerialization.jsonObject(with: body), let d = obj as? [String: Any] else {
            throw WebAction.Invalid("the body must be a JSON object")
        }
        guard Set(d.keys).isSubset(of: ["purpose", "name", "agent", "base", "isolated"]) else {
            throw WebAction.Invalid("only purpose, name, agent, base and isolated")
        }
        var q = WebPlanQuery()
        if let v = d["purpose"], !(v is NSNull) {
            guard let s = v as? String, ["try", "new"].contains(s) else { throw WebAction.Invalid("purpose: try or new") }
            q.purpose = s
        }
        if let v = d["name"], !(v is NSNull) {
            guard let s = v as? String, WebRoute.isSandboxName(s) else { throw WebAction.Invalid("name: a sandbox name") }
            q.name = s
        }
        if let v = d["agent"], !(v is NSNull) {
            guard let s = v as? String, s.count <= 40, s == "none" || AgentRecipes.matching(s) != nil else {
                throw WebAction.Invalid("agent: an agent this Dozer has (doz search lists them)")
            }
            q.agent = s
        }
        if let v = d["base"], !(v is NSNull) {
            guard let s = v as? String, s.count <= 40, BaseCatalogue.base(s) != nil else { throw WebAction.Invalid("base: a recommended base") }
            q.base = s
        }
        if let v = d["isolated"], !(v is NSNull) {
            guard let b = v as? Bool, CFGetTypeID(v as CFTypeRef) == CFBooleanGetTypeID() else { throw WebAction.Invalid("isolated: true or false") }
            q.isolated = b
        }
        if q.purpose == "try", q.agent == nil || q.agent == "none" { throw WebAction.Invalid("agent: a try is of an agent") }
        return q
    }

    /// The planner's request: the agent and base as `ImageChoice` names them (the CLI's `--agent/--base`).
    public var request: PlanRequest {
        var o = CreateOptions(image: "")
        if agent != nil || base != nil {
            let kind: AgentKind = agent == "none" || agent == nil ? .none
                : AgentRecipes.matching(agent!).flatMap { AgentKind(rawValue: $0.id) } ?? .none
            o.image = ImageChoice(base: base ?? kind.recipe?.defaultBase ?? "node", agent: kind).name
        }
        if isolated { o.isolated = true }
        return PlanRequest(purpose: purpose, name: name, create: o)
    }
}

extension WebTryCatalog {
    /// The list from each agent's plan (`plan` answers it — the host's op, the same as the CLI's).
    public static func build(plan: (PlanRequest) async throws -> WebPlan, secretEntry: Bool,
                             currency: [String: AgentCurrency] = [:]) async -> WebTryCatalog {
        var agents: [Agent] = []
        for kind in AgentKind.allCases where kind != .none {
            guard let r = kind.recipe else { continue }
            let q = WebPlanQuery(purpose: "try", agent: r.id)
            guard let p = try? await plan(q.request) else { continue }
            let keyProblem = p.problems.first { $0.code == "key" }
            var card: Card?
            if keyProblem != nil, let c = TryCard.build(r, haveKey: nil) {
                card = Card(title: c.title, options: c.options.map { Option(kind: $0.kind, label: $0.label, consequence: $0.consequence) },
                            notOffered: c.notOffered, getKey: c.getKey, addCommand: keyProblem?.fix)
            }
            var a = Agent(id: r.id, title: r.title, publisher: r.publisher, provider: r.provider,
                          providerTitle: r.provider.flatMap { KeyProviders.provider($0)?.title },
                          base: BaseCatalogue.base(r.defaultBase)?.title, plan: p, card: card)
            a.latest = currency[r.id]?.line
            if let l = r.lifecycle, !l.isCurrent { a.standing = l.note ?? l.status; a.supersededBy = l.by }
            a.icon = AgentIcons.resolve(r)
            a.aliases = (r.aliases ?? []).sorted()
            a.tags = r.capabilityTags.filter { ["documented", "verified"].contains($0.level) }.map(\.tag)
            a.openSource = r.hasTag("open-source")
            a.headless = r.hasTag("headless")
            a.gateway = r.gateways.contains { ["documented", "verified"].contains($0.level) }
            a.current = r.lifecycle?.isCurrent ?? true
            a.ready = card == nil && !p.problems.contains { $0.code != "key" }
            a.version = r.install.pinned.version.split(separator: "+").first.map(String.init)
            a.age = currency[r.id]?.ageDays.map(Self.age)
            agents.append(a)
        }
        // 617: a superseded or retired agent comes after the current ones (still selectable).
        agents = agents.filter { $0.standing == nil } + agents.filter { $0.standing != nil }
        let coming = KnownThings.all.filter { $0.status != "supported" }
            .map { Coming(id: $0.id, title: $0.title, publisher: $0.publisher ?? "", reason: $0.reason, aliases: ($0.aliases ?? []).sorted(),
                          icon: AgentIcons.resolve(icon: nil, publisher: $0.publisher, title: $0.title)) }
        return WebTryCatalog(agents: agents, coming: coming, secretEntry: secretEntry)
    }

    /// "today", "1 day", "12 days", "5 weeks", "3 months" — how long ago a release came out.
    static func age(_ days: Int) -> String {
        switch days {
        case ..<1: return "today"
        case 1: return "1 day"
        case ..<28: return "\(days) days"
        case ..<70: return "\(days / 7) weeks"
        default: return "\(days / 30) months"
        }
    }
}

extension HostWebData {
    /// The host's read-only `plan` (in-process when no host runs — looking never starts one).
    public func plan(_ r: PlanRequest) async throws -> WebPlan {
        var q = HostRequest(.plan)
        q.planRequest = r
        return WebPlan(try await query(q).0.decode(CreatePlan.self))
    }
}
