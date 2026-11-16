import Foundation
import DozableKit

// 597 — Dozable Agent Permissions in the host: what a sandbox's agent may do, as a checklist (P1), its
// presets (P2), suggestions from denied connections (P3), edits by permission or site (P6), the
// default for new sandboxes (P4), and the plain words of the facts block (P7). The definitions live
// in the library (`AgentPermissions`); a policy stores their NAMES (P5).

/// One permission as a client shows it.
public struct PermissionRow: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var summary: String
    public var on: Bool
    public var locked: Bool
    public var warning: String?
    /// `install` for the per-ecosystem sub-switches.
    public var group: String?
    /// The hosts behind it (this build's), for "details".
    public var hosts: [String]
    /// Default on for this sandbox's base (Standard).
    public var standard: Bool
}

/// P3: the agent was refused something a permission (or a site) would allow.
public struct PermissionSuggestion: Codable, Equatable, Sendable {
    /// A permission id, or nil for an unknown host ("Allow this site").
    public var permission: String?
    /// "install Python packages (PyPI)" / the host.
    public var what: String
    public var hosts: [String]
    public var count: Int
    /// What to send: `install:python`, or `site:api.example.com`.
    public var grant: String
}

/// A sandbox's permissions: the checklist, the preset (nil: Custom), its own sites, suggestions.
public struct PermissionReport: Codable, Equatable, Sendable {
    public var name: String
    public var base: String?
    /// `locked` · `agent` (Standard) · `open`; nil: Custom.
    public var preset: String?
    public var permissions: [PermissionRow]
    public var sites: [String]
    public var denied: [String]
    public var suggestions: [PermissionSuggestion]
    /// A pre-597 policy of rules, shown as the permissions it amounts to (stored as names at its first change).
    public var inferred: Bool
    /// 691: the ports of this Mac it may reach as `host.dozable.internal:PORT` (nil: none — and every older daemon's
    /// answer), and whether `doz net allow NAME host:PORT` may open one while it runs (`network.host_ports_live`).
    public var hostPorts: [HostPort]? = nil
    public var hostPortsLive: Bool? = nil
    /// 692: the secrets it was given at launch (`--secret`) — where each goes, never a value (nil: none).
    public var secrets: [LaunchSecretRow]? = nil
}

public enum PermissionPolicy {
    /// A catalogue base id for a sandbox's image (nil: a Dockerfile's, a template of one, the lab).
    public static func base(of config: SandboxConfig) -> String? {
        config.imageChoice.flatMap { BaseCatalogue.base($0.base) != nil ? $0.base : nil }
    }

    /// The names a setting's words (or `--allow`'s) give, from Standard for `base`: `standard` / `locked`
    /// / `open`, a list of ids (`+id` adds, `-id` removes; a bare id adds).
    public static func names(from words: [String], base: String?, start: [String]? = nil) -> [String] {
        var set = Set(start ?? AgentPermissions.preset("agent", base: base) ?? [])
        for w in words {
            switch w {
            case "standard": set = Set(AgentPermissions.preset("agent", base: base) ?? [])
            case "locked", "open": set = Set(AgentPermissions.preset(w, base: base) ?? [])
            default:
                if w.hasPrefix("-") { set.remove(String(w.dropFirst())) } else { set.insert(w.hasPrefix("+") ? String(w.dropFirst()) : w) }
            }
        }
        return AgentPermissions.normalized(Array(set))
    }

    /// A pre-597 policy of rules as the permissions it allows (every host of a permission allowed by
    /// it), and the rules no permission covers (kept as the user's own). Behaviour is kept: what it
    /// allowed stays allowed.
    public static func inferred(_ p: NetworkPolicy) -> (names: [String], rules: [EgressRule]) {
        if let names = p.permissions { return (names, p.rules) }
        var names: [String] = []
        // 599d: never inferred — the user's GitHub login is only ever on because it was switched on by name.
        for perm in AgentPermissions.all where perm.id != "web" && perm.group != "github" && !AgentPermissions.isAgentOwn(perm.id) {
            let covered = perm.hosts.allSatisfy { h in
                let host = h.host.hasPrefix("*.") ? "x" + h.host.dropFirst(1) : h.host
                return p.evaluateConnection(host: host, port: h.ports?.first ?? 443).kind != .deny
            }
            if covered || perm.locked { names.append(perm.id) }
        }
        if p.defaultAction == .allow { names.append("web") }
        let hostsOf = Set(AgentPermissions.all.filter { names.contains($0.id) }.flatMap { $0.hosts.map(\.host) })
        let rest = p.rules.filter { !($0.action == .allow && hostsOf.contains($0.host)) }
        return (AgentPermissions.normalized(names), rest)
    }

    /// The same policy as permissions (a pre-597 one converted; a permissions one as it is).
    public static func asPermissions(_ p: NetworkPolicy, base: String?) -> NetworkPolicy {
        guard p.permissions == nil else { return p }
        let (names, rest) = inferred(p)
        var q = NetworkPolicy.permissions(names, preset: AgentPermissions.presetName(names, base: base))
        q.rules = rest
        return q
    }

    /// P6: grants and revokes — permission ids, or `site:HOST` (allowed first; revoked = denied).
    /// "model" cannot be revoked (the agent could not work). The preset is re-derived for `base`.
    /// 599i: `agent` — the sandbox's agent: its own model permission ("Talk to OpenAI" for Codex) is kept
    /// and cannot be revoked.
    public static func edited(_ current: NetworkPolicy, grant: [String], revoke: [String], base: String?, agent: AgentKind? = nil) throws -> NetworkPolicy {
        var p = asPermissions(current, base: base)
        var names = Set(p.permissions ?? [])
        for g in grant {
            if g.hasPrefix("site:") {
                let (host, ports) = try site(g)
                // 617: a host the sandbox's agent is known to call and Dozable keeps out — whatever is chosen.
                if AgentPermissions.excludedHosts((p.permissions ?? []) + AgentPermissions.agentPermissions(agent)).contains(host) {
                    throw HostError(.invalid, "\(host) is kept out of a \(agent?.title ?? "this agent's") sandbox (Dozable never lets the agent reach it) — it cannot be allowed")
                }
                grantSite(&p, host: host, ports: ports)
            } else if g == "install" {
                for e in AgentPermissions.ecosystems { names.insert("install:" + e.id) }
            } else {
                guard AgentPermissions.isValid(g) else { throw HostError(.invalid, "no permission \(g) — doz net permissions lists them (or site:HOST)") }
                // 617 (D5): a recipe agent talks to its own model only.
                if g == "model", AgentPermissions.hasOwnModel(AgentPermissions.agentPermissions(agent)) {
                    throw HostError(.invalid, "\(agent?.title ?? "this agent") talks to its own model — Anthropic's (model) is not part of its sandbox")
                }
                names.insert(g)
                // 599d: "Push to GitHub" is a step of "Use GitHub as you" — granting it grants both.
                if g == AgentPermissions.gitHubPush { names.insert(AgentPermissions.gitHubAsYou) }
            }
        }
        for r in revoke {
            if r.hasPrefix("site:") {
                let (host, ports) = try site(r)
                revokeSite(&p, host: host, ports: ports, names: AgentPermissions.normalized(Array(names) + AgentPermissions.agentPermissions(agent)))
            } else if r == "install" {
                for e in AgentPermissions.ecosystems { names.remove("install:" + e.id) }
            } else {
                guard let perm = AgentPermissions.permission(r) else { throw HostError(.invalid, "no permission \(r) — doz net permissions lists them (or site:HOST)") }
                guard !perm.locked else { throw HostError(.invalid, "\(perm.title) cannot be switched off — the agent needs it to work (use --network locked for nothing else)") }
                guard !AgentPermissions.agentPermissions(agent).contains(r) else {
                    throw HostError(.invalid, "\(perm.title) cannot be switched off — \(agent?.title ?? "the agent") needs it to work")
                }
                names.remove(r)
            }
        }
        let n = AgentPermissions.normalized(Array(names) + AgentPermissions.agentPermissions(agent))
        p.permissions = n
        p.preset = p.rules.isEmpty ? AgentPermissions.presetName(n, base: base) : nil
        return p
    }

    /// The one `site:` parser: `site:HOST`, `site:HOST:PORT`, `site:HOST:P1,P2,…`. HOST is a name (`api.example.com`), a
    /// wildcard (`*.example.com`) or an IPv4 address; ports are 1–65535, at most 16, each once, sorted. nil ports: every port.
    public static func site(_ s: String) throws -> (host: String, ports: [UInt16]?) {
        let form = "site: HOST or HOST:PORT — api.example.com, *.example.com:443, 100.64.0.5:8780"
        let body = String(s.hasPrefix("site:") ? s.dropFirst(5) : Substring(s)).lowercased()
        let parts = body.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count <= 2, !body.hasPrefix("[") else {
            throw HostError(.invalid, "site: an IPv6 address is not supported in site rules yet (and a site takes one port list) — \(form)")
        }
        let host = parts[0]
        // 691: this Mac's route is never a site — a site rule could not open it anyway (the route is judged first).
        if HostRoute.isHost(host) {
            throw HostError(.invalid, "site: \(host) is this Mac's own route — open a port of it with host:PORT (host:8780), not a site")
        }
        guard host.range(of: #"^(\*\.)?[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$"#, options: .regularExpression) != nil,
              host.count <= 253 else { throw HostError(.invalid, "site: a host name like api.example.com (or *.example.com), or an IPv4 address — \(form)") }
        guard parts.count == 2 else { return (host, nil) }
        let words = parts[1].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard !words.isEmpty, words.count <= 16 else { throw HostError(.invalid, "site: at most 16 ports — \(form)") }
        var ports = Set<UInt16>()
        for w in words {
            guard !w.isEmpty, w.count <= 5, w.allSatisfy({ $0 >= "0" && $0 <= "9" }), let n = UInt16(w), n >= 1 else {
                throw HostError(.invalid, "site: \"\(w)\" is not a port (1–65535) — \(form)")
            }
            ports.insert(n)
        }
        return (host, ports.sorted())
    }

    /// `--allow` / `--permissions` words: each item split at commas — except that a bare number after a `site:HOST:PORT`
    /// word is that site's next port (`site:h:80,443` is one word, not a site and a permission called `443`).
    public static func splitWords(_ items: [String]) -> [String] {
        var out: [String] = []
        for item in items {
            for raw in item.split(separator: ",", omittingEmptySubsequences: true) {
                let w = raw.trimmingCharacters(in: .whitespaces)
                if w.isEmpty { continue }
                if w.allSatisfy({ $0 >= "0" && $0 <= "9" }), let last = out.last, last.hasPrefix("site:"),
                   last.dropFirst(5).contains(":") { out[out.count - 1] = last + "," + w; continue }
                out.append(w)
            }
        }
        return out
    }

    /// Whether `rule` is one of a person's site rules (unconditional) for `host`.
    private static func ownSite(_ r: EgressRule, _ host: String) -> Bool { r.host == host && !r.hasHTTPConditions }

    /// The ordering invariant of a person's site rules, for the hosts in `hosts` (nil: every host): for one host, a
    /// whole-host deny first, then port denies, then allows (whole-host and port) — so a deny always wins and an allow
    /// can never hide behind a later deny. Identical rules collapse; a port allow under a whole-host allow (or a port deny
    /// under a whole-host deny) is folded into it. Rules keep the slots the host's rules held; rules with HTTP
    /// conditions and other hosts' rules are never moved. Pure.
    public static func normalizedSiteRules(_ rules: [EgressRule], hosts: Set<String>? = nil) -> [EgressRule] {
        var out = rules
        for host in hosts ?? Set(rules.filter { !$0.hasHTTPConditions }.map(\.host)) {
            let idx = out.indices.filter { ownSite(out[$0], host) }
            guard idx.count > 1 else { continue }
            let group = idx.map { out[$0] }
            let wholeAllow = group.contains { $0.action == .allow && $0.ports == nil }
            let wholeDeny = group.contains { $0.action == .deny && $0.ports == nil }
            var kept: [EgressRule] = []
            for r in group {
                if r.ports != nil, (r.action == .allow && wholeAllow) || (r.action == .deny && wholeDeny) { continue }
                if kept.contains(where: { $0.action == r.action && $0.ports == r.ports }) { continue }
                kept.append(r)
            }
            func rank(_ r: EgressRule) -> Int { r.action == .deny ? (r.ports == nil ? 0 : 1) : 2 }
            kept = kept.enumerated().sorted { rank($0.element) != rank($1.element) ? rank($0.element) < rank($1.element) : $0.offset < $1.offset }.map(\.element)
            for (n, i) in idx.enumerated() where n < kept.count { out[i] = kept[n] }
            for i in idx.dropFirst(kept.count).reversed() { out.remove(at: i) }
        }
        return out
    }

    /// A rule's host as `evaluateConnection` takes it (a wildcard as a name under it).
    private static func probe(_ host: String) -> String { host.hasPrefix("*.") ? "x" + host.dropFirst(1) : host }

    /// `site:HOST[:PORTS]` allowed. A port grant: lifts the whole-host deny of that host (a person who allows a port means
    /// it — `lifted(before:after:grant:)` says so), takes the granted ports out of the host's port denies, and adds the
    /// ports to the host's allow (one rule, first) unless a whole-host allow already covers them. A whole-host grant:
    /// lifts the host's whole-host deny (port denies stay — they are narrower), folds the host's port allows into it.
    static func grantSite(_ p: inout NetworkPolicy, host: String, ports: [UInt16]?) {
        p.rules.removeAll { ownSite($0, host) && $0.action == .deny && $0.ports == nil }
        if let ports {
            var rules: [EgressRule] = []
            for r in p.rules {
                if ownSite(r, host), r.action == .deny, let rp = r.ports {
                    let rest = rp.filter { !ports.contains($0) }
                    if rest.isEmpty { continue }
                    var c = r; c.ports = rest; rules.append(c); continue
                }
                rules.append(r)
            }
            p.rules = rules
            if !p.rules.contains(where: { ownSite($0, host) && $0.action == .allow && $0.ports == nil }) {
                let have = p.rules.filter { ownSite($0, host) && $0.action == .allow }.compactMap(\.ports)
                let merged = Set(have.flatMap { $0 } + ports).sorted()
                if !(have.count == 1 && have[0] == merged) {
                    p.rules.removeAll { ownSite($0, host) && $0.action == .allow }
                    p.rules.insert(EgressRule(host: host, ports: merged, note: "site you allowed"), at: 0)
                }
            }
        } else {
            p.rules.removeAll { ownSite($0, host) && $0.action == .allow && $0.ports != nil }
            if !p.rules.contains(where: { ownSite($0, host) && $0.action == .allow && $0.ports == nil }) {
                p.rules.insert(EgressRule(host: host, note: "site you allowed"), at: 0)
            }
        }
        p.rules = normalizedSiteRules(p.rules, hosts: [host])
    }

    /// `site:HOST[:PORTS]` denied. No ports: every rule of the host goes and a whole-host deny comes first (as ever). Ports:
    /// they leave the host's port allows; and the ports something still lets through (a whole-host allow, a permission,
    /// browsing the web) are denied by a `deny HOST:PORTS` first — just those ports. `names`: the permissions the policy
    /// will have.
    static func revokeSite(_ p: inout NetworkPolicy, host: String, ports: [UInt16]?, names: [String]) {
        guard let ports else {
            p.rules.removeAll { ownSite($0, host) }
            p.rules.insert(EgressRule(.deny, host: host, note: "site you denied"), at: 0)
            return
        }
        var rules: [EgressRule] = []
        for r in p.rules {
            if ownSite(r, host), r.action == .allow, let rp = r.ports {
                let rest = rp.filter { !ports.contains($0) }
                if rest.isEmpty { continue }
                var c = r; c.ports = rest; rules.append(c); continue
            }
            rules.append(r)
        }
        p.rules = rules
        var probeP = p
        probeP.permissions = names
        let open = ports.filter { probeP.evaluateConnection(host: probe(host), port: $0).kind != .deny }
        if !open.isEmpty {
            let have = p.rules.filter { ownSite($0, host) && $0.action == .deny }.compactMap(\.ports)
            let merged = Set(have.flatMap { $0 } + open).sorted()
            p.rules.removeAll { ownSite($0, host) && $0.action == .deny && $0.ports != nil }
            p.rules.insert(EgressRule(.deny, host: host, ports: merged, note: "site you denied"), at: 0)
        }
        p.rules = normalizedSiteRules(p.rules, hosts: [host])
    }

    /// The whole-host denies a `site:HOST:PORTS` grant lifted (`before` → `after`), for the command's answer.
    public static func lifted(before: NetworkPolicy, after: NetworkPolicy, grant: [String]) -> [String] {
        var out: [String] = []
        for g in grant where g.hasPrefix("site:") {
            guard let (host, ports) = try? site(g), ports != nil else { continue }
            let had = before.rules.contains { ownSite($0, host) && $0.action == .deny && $0.ports == nil }
            let has = after.rules.contains { ownSite($0, host) && $0.action == .deny && $0.ports == nil }
            if had, !has { out.append("deny \(host)") }
        }
        return out
    }

    /// The host a DNS service lookup is about: its leading `_service._proto.` labels dropped (apt asks for
    /// `_http._tcp.deb.debian.org` before `deb.debian.org`). Owner, 2026-10-21: "Allow this site" on such a name failed
    /// — a site rule takes no `_` label — and the suggestion belongs to the host's own permission anyway.
    public static func serviceHost(_ host: String) -> String {
        var labels = host.split(separator: ".", omittingEmptySubsequences: false)
        while labels.count > 2, labels[0].hasPrefix("_") { labels.removeFirst() }
        return labels.joined(separator: ".")
    }

    /// The domain a host belongs to, as one approval allows it: its last two labels (`frame.claudeusercontent.com` →
    /// `claudeusercontent.com`), three under a two-part country suffix (`api.example.com.au` → `example.com.au`) or a
    /// shared host where every customer is a subdomain (`me.github.io` stays itself). An IP address stays itself.
    public static func siteDomain(_ host: String) -> String {
        let labels = host.split(separator: ".").map(String.init)
        guard labels.count > 2, !labels.allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return host }
        let last2 = labels.suffix(2).joined(separator: ".")
        let keep = sharedSuffixes.contains(last2) || (labels[labels.count - 1].count == 2 && countrySeconds.contains(labels[labels.count - 2])) ? 3 : 2
        return labels.suffix(keep).joined(separator: ".")
    }
    /// The second labels of a two-part country suffix (`com.au`, `co.uk`, `ac.jp`).
    static let countrySeconds: Set<String> = ["com", "co", "net", "org", "edu", "gov", "ac", "or", "ne", "go"]
    /// Shared hosts: one customer per subdomain, so the domain is the customer's, not the host's.
    static let sharedSuffixes: Set<String> = ["github.io", "amazonaws.com", "cloudfront.net", "herokuapp.com", "vercel.app",
                                              "netlify.app", "pages.dev", "workers.dev", "azurewebsites.net", "appspot.com",
                                              "web.app", "firebaseapp.com", "fly.dev", "onrender.com"]

    /// A permission's host as a person reads it: a host limited to some paths says which kind — an agent model
    /// permission's are its model requests (OpenCode Zen, Grok's API paths), any other's the agent's own package.
    public static func hostLabel(_ h: PermissionHost, permission id: String) -> String {
        guard h.pathPrefixes != nil else { return h.host }
        return h.host + (AgentPermissions.isAgentModel(id) ? " (model requests only)" : " (the agent's own package)")
    }

    /// The checklist, the preset, the sites and the suggestions from `log` (denied connections).
    public static func report(name: String, policy: NetworkPolicy, base: String?, log: [ConnectionRecord],
                              hostPorts: [HostPort]? = nil, hostPortsLive: Bool = true) -> PermissionReport {
        let inferredMode = policy.permissions == nil
        let (names, own) = inferred(policy)
        let standard = Set(AgentPermissions.preset("agent", base: base) ?? [])
        // 599i: an agent's own model permission is listed only where it is on (a Codex sandbox). 617: an agent's own
        // update hosts are never a switch; Anthropic's model is not listed where a recipe agent has its own.
        let ownModel = AgentPermissions.hasOwnModel(names)
        let rows = AgentPermissions.all.filter {
            (!AgentPermissions.isAgentModel($0.id) || names.contains($0.id)) && !AgentPermissions.isAgentUpdate($0.id) && !AgentPermissions.isAgentVendor($0.id) && !AgentPermissions.isAgentSources($0.id) && !(ownModel && $0.id == "model")
        }.map { p in
            PermissionRow(id: p.id, title: p.title, summary: p.summary, on: names.contains(p.id),
                          locked: p.locked || AgentPermissions.isAgentModel(p.id), warning: p.warning,
                          group: p.group, hosts: p.hosts.map { hostLabel($0, permission: p.id) },
                          standard: standard.contains(p.id) || AgentPermissions.isAgentModel(p.id))
        }
        var tmp = policy
        tmp.permissions = names
        tmp.rules = own
        let sites = own.filter { $0.action == .allow && !$0.hasHTTPConditions }.map(\.siteSpec)
        // 617: what the agent is expected to be refused (its recipe's quiet list) is no refusal to report.
        let quiet = Set(AgentPermissions.quietHosts(names))
        let deniedRecs = log.filter { $0.verdict == .denied && !quiet.contains($0.host.lowercased()) }
        var byGrant: [String: PermissionSuggestion] = [:]
        var order: [String] = []
        let excluded = Set(AgentPermissions.excludedHosts(names))
        for r in deniedRecs {
            let host = serviceHost(r.host.lowercased())          // 635: `_http._tcp.deb.debian.org` is deb.debian.org's
            if excluded.contains(host) { continue }              // 617: kept out on purpose — never suggested
            // 691: this Mac's route — suggested as host:PORT while live changes are on (never as a site); nothing when off.
            if HostRoute.isHost(host) {
                guard hostPortsLive, let port = r.port, HostRoute.refusal(port: Int(port)) == nil else { continue }
                let grant = "host:\(port)"
                if byGrant[grant] == nil {
                    order.append(grant)
                    byGrant[grant] = PermissionSuggestion(permission: nil, what: "this Mac's port \(port)", hosts: [], count: 0, grant: grant)
                }
                if !byGrant[grant]!.hosts.contains(host) { byGrant[grant]!.hosts.append(host) }
                byGrant[grant]!.count += 1
                continue
            }
            // Allowed since (a site or a permission granted after the refusal): nothing left to ask for.
            if policy.evaluateConnection(host: host, port: r.port ?? 443).kind != .deny { continue }
            let grant: String, what: String, perm: String?
            if let p = AgentPermissions.permission(forHost: host) {
                guard !names.contains(p.id) else { continue }       // on, but a rule of the user's denied it
                grant = p.id; what = p.phrase; perm = p.id
            } else {
                // Owner, 2026-10-23: "i dont want to have to approve each URL" — one approval per domain: a host under
                // it is suggested as `*.domain` (claude.ai's artifact frames are a new `<uuid>.frame.claudeusercontent.com`
                // each time), the domain itself as itself.
                // Any port but 80 and 443 is a narrower grant: that host, that port (a message server's agent port, a dev server).
                let domain = siteDomain(host)
                if let port = r.port, port != 80, port != 443 { grant = "site:\(host):\(port)"; what = "\(host):\(port)" }
                else if domain == host { grant = "site:" + host; what = host } else { grant = "site:*." + domain; what = "*." + domain }
                perm = nil
            }
            if byGrant[grant] == nil { order.append(grant); byGrant[grant] = PermissionSuggestion(permission: perm, what: what, hosts: [], count: 0, grant: grant) }
            if !byGrant[grant]!.hosts.contains(host) { byGrant[grant]!.hosts.append(host) }
            byGrant[grant]!.count += 1
        }
        var rep = PermissionReport(name: name, base: base, preset: inferredMode ? AgentPermissions.presetName(names, base: base) : policy.preset,
                                   permissions: rows, sites: sites, denied: Array(Set(deniedRecs.map(\.host))).sorted(),
                                   suggestions: order.prefix(12).compactMap { byGrant[$0] }, inferred: inferredMode)
        // 691: an open port that was refused before it was opened is no longer a suggestion.
        let open = Set((hostPorts ?? []).map { "host:\($0.port)" })
        rep.suggestions.removeAll { open.contains($0.grant) }
        rep.hostPorts = (hostPorts ?? []).isEmpty ? nil : hostPorts
        rep.hostPortsLive = hostPortsLive
        return rep
    }

    /// P7: the facts block's line — "You may talk to your AI model, update yourself, …; you may not
    /// browse the web (any site), sign in …. A refused action needs the user to switch its permission
    /// on — ask for it by name (e.g. "Browse the web": doz net allow NAME web)."
    public static func facts(_ policy: NetworkPolicy, sandbox: String) -> String {
        let (names, own) = inferred(policy)
        // 617: an agent's own update hosts are part of "update yourself"; Anthropic's model is not a recipe agent's.
        let ownModel = AgentPermissions.hasOwnModel(names)
        let on = AgentPermissions.all.filter { names.contains($0.id) && !AgentPermissions.isAgentUpdate($0.id) && !AgentPermissions.isAgentVendor($0.id) && !AgentPermissions.isAgentSources($0.id) }.map(\.phrase)
        let off = AgentPermissions.all.filter { !names.contains($0.id) && !AgentPermissions.isAgentOwn($0.id) && !(ownModel && $0.id == "model") }
        var s = "You may " + list(on) + "."
        let sites = own.filter { $0.action == .allow && !$0.hasHTTPConditions }.map(\.siteSpec)
        if !sites.isEmpty { s += " Sites the user allowed: " + sites.prefix(20).joined(separator: ", ") + "." }
        if !off.isEmpty {
            s += " You may not " + list(off.map(\.phrase)) + "."
            s += " A refused connection needs the user to switch its permission on — ask for it by its name, e.g. \"\(off[0].title)\" (`doz net allow \(sandbox) \(off[0].id)`), or a site (`doz net allow \(sandbox) site:HOST`); do not try to get around it."
        }
        return s
    }

    // MARK: 691 — this Mac's ports (`host:PORT`), beside the permissions and never one of them

    /// `--allow` / `--permissions` / `doz net allow|deny` words split into `host:` words (the ports) and the rest.
    public static func hostWords(_ words: [String]) throws -> (ports: [HostPort], rest: [String]) {
        var ports: [HostPort] = []
        var rest: [String] = []
        for w in words {
            guard HostRoute.isWord(w) else { rest.append(w); continue }
            switch HostRoute.parseWord(w) {
            case .success(let ps): ports = HostRoute.merged(ports, add: ps)
            case .failure(let e): throw HostError(.invalid, e.description)
            }
        }
        return (ports, rest)
    }

    /// Ports given at launch, checked: never one of Dozable's own, port 0 or a privileged one; at most
    /// `HostRoute.maximumPorts` with the model server's (`model`). Origin `launch`, sorted, each once.
    public static func checkedLaunchPorts(_ given: [HostPort], model: Int? = nil, flag: String = "--host-port") throws -> [HostPort] {
        var out: [HostPort] = []
        for var p in given {
            if let why = HostRoute.refusal(port: Int(p.port)) { throw HostError(.invalid, "\(flag) \(p.port): \(why)") }
            if p.origin != .live { p.origin = .launch }          // a restart keeps what was added live as live
            out = HostRoute.merged(out, add: [p])
        }
        let total = Set(out.map(\.port) + (model.map { [UInt16(clamping: $0)] } ?? [])).count
        guard total <= HostRoute.maximumPorts else { throw HostError(.invalid, "at most \(HostRoute.maximumPorts) ports of this Mac for one sandbox or session") }
        return out
    }

    /// The stored list (launch and live — never the model server's) after `doz net allow|deny … host:PORT`. A grant needs
    /// `live` (`network.host_ports_live`); a deny always works; the model server's port cannot be taken away by `host:` (it
    /// belongs to the model source). Each granted port is checked like a launch one; added ports are `live`.
    public static func editedHostPorts(_ stored: [HostPort], model: UInt16?, grant: [HostPort], revoke: [HostPort], live: Bool) throws -> [HostPort] {
        if !grant.isEmpty, !live {
            let have = Set(stored.map(\.port) + (model.map { [$0] } ?? []))
            // Asking again for exactly what is open (same tag) changes nothing — not refused.
            let changes = grant.contains { g in !have.contains(g.port) || (stored.first { $0.port == g.port }?.tag ?? false) != g.tag }
            if changes {
                throw HostError(.invalid, "this Mac's ports are fixed when a sandbox or session starts (network.host_ports_live is off) — start it with --host-port")
            }
        }
        if let m = model, revoke.contains(where: { $0.port == m }) {
            throw HostError(.invalid, "port \(m) is the model server this sandbox was made with — it belongs to its model source, not to host:PORT (doz net deny cannot take it away)")
        }
        var out = stored.filter { $0.origin != .model }
        for g in grant {
            if let why = HostRoute.refusal(port: Int(g.port)) { throw HostError(.invalid, "host:\(g.port): \(why)") }
            let origin = out.first { $0.port == g.port }?.origin ?? .live
            out = HostRoute.merged(out, add: [HostPort(port: g.port, tag: g.tag, origin: origin)])
        }
        out = HostRoute.merged(out, remove: revoke.map(\.port))
        let total = Set(out.map(\.port) + (model.map { [$0] } ?? [])).count
        guard total <= HostRoute.maximumPorts else { throw HostError(.invalid, "at most \(HostRoute.maximumPorts) ports of this Mac for one sandbox or session") }
        return out
    }

    /// The facts block's line for this Mac's ports (empty when none).
    public static func hostPortsFacts(_ ports: [HostPort], whom: String = "you") -> String {
        guard !ports.isEmpty else { return "" }
        let items = ports.sorted { $0.port < $1.port }.map { p in
            "port \(p.port) as http://\(HostRoute.hostName):\(p.port)" + (p.origin == .model ? " (the model server you use)" : "")
        }
        return "Of the user's Mac \(whom) may reach only " + Self.list(items) + "; nothing else of the Mac — its localhost or any other address of it — is reachable."
    }

    static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: return "nothing"
        case 1: return items[0]
        default: return items.dropLast().joined(separator: ", ") + " and " + items.last!
        }
    }
}
