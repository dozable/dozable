import ArgumentParser
import Foundation
import DozableKit
import DozableHost

// 597 (P6) — the CLI speaks permissions: `doz net NAME` (the checklist), `doz net allow|deny NAME
// PERMISSION… | site:HOST…`, `doz net permissions` (every permission and its hosts). `doz net policy`
// stays for raw rules.

func printPermissions(_ r: PermissionReport) {
    Out.stdout("\(r.name): what the agent can do — \(r.preset.map { $0 == "agent" ? "Standard" : $0.capitalized } ?? "Custom")"
               + (r.base.map { " (base \($0))" } ?? "") + (r.inferred ? " — an older policy of rules, shown as permissions" : "") + "\n")
    for p in r.permissions {
        let mark = p.on ? "[x]" : "[ ]"
        let indent = p.group == "install" ? "      " : "  "
        let head = p.group == "install" ? "Install software — " + p.title : p.title
        Out.stdout("\(indent)\(mark) \(head)\(p.locked ? " (always)" : "")  — \(p.summary)\(p.warning.map { " ⚠ " + $0 } ?? "")  [\(p.id)]\n")
    }
    if !r.sites.isEmpty { Out.stdout("  sites you allowed: \(r.sites.joined(separator: ", "))\n") }
    // 691: this Mac's ports — beside the permissions, never one of them.
    if let h = r.hostPorts, !h.isEmpty {
        Out.stdout("This Mac's ports: \(HostRoute.listText(h)) — as \(HostRoute.hostName):PORT"
                   + (r.hostPortsLive == false ? " (fixed when it starts: network.host_ports_live is off)" : "") + "\n")
    }
    // 692: the secrets given at launch — where each goes and its fingerprint, never a value.
    for s in r.secrets ?? [] {
        Out.stdout("Secret \(s.variable) → \(s.to) in \(s.header) (fp \(s.fingerprint)…)" + (s.plainHTTP ? "" : " — never over plain HTTP (network.placeholders_plain_http was off)") + "\n")
    }
    if !r.suggestions.isEmpty {
        Out.stdout("refused lately:\n")
        for s in r.suggestions {
            Out.stdout("  the agent tried to \(s.permission != nil ? s.what : "reach " + s.what) (\(s.hosts.joined(separator: ", ")), \(s.count) time\(s.count == 1 ? "" : "s")) — doz net allow \(r.name) \(s.grant)\n")
        }
    }
}

/// `--session S`: a fenced session on this Mac (`doz net … @mac --session S`) — required with @mac, refused otherwise.
func netSession(_ name: String, _ session: String?) throws -> String? {
    if MacPlace.isPlace(name) {
        guard let session else { throw ValidationError("which session on this Mac? doz net … @mac --session SESSION (a fenced one)") }
        return session
    }
    if session != nil { throw ValidationError("--session is for @mac (a fenced session on this Mac); a sandbox has one network for all its sessions") }
    return nil
}

func netRequest(_ op: HostOp, _ name: String, _ session: String?) -> HostRequest {
    var r = HostRequest(op, name: name)
    r.session = session
    return r
}

struct NetShow: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "show", abstract: "What the agent can do: its permissions as a checklist, its sites, and what it was refused lately (the default: doz net NAME).")
    @OptionGroup var g: GlobalOptions
    @Argument var name: String
    @Option(name: .long, help: "@mac: the fenced session.") var session: String?
    func run() async throws {
        let s = try netSession(name, session)
        let r = try decode(try await query(netRequest(.netPermissions, name, s), g), PermissionReport.self, g)
        if g.json { Out.json(r) } else { printPermissions(r) }
    }
}

/// allow / deny: permission ids (`install:python`, `web`, `install` = every ecosystem), `site:HOST`,
/// or a preset (`standard`, `locked`, `open`).
func changePermissions(_ name: String, session: String? = nil, grant: [String], revoke: [String], preset: String?, _ g: GlobalOptions) throws {
    var r = netRequest(.netPolicy, name, session)
    r.grant = grant.isEmpty ? nil : grant
    r.revoke = revoke.isEmpty ? nil : revoke
    r.preset = preset
    // A port grant lifts the host's whole-host deny — said, so "allow this port" is never a silent surprise.
    let portGrant = grant.contains { $0.hasPrefix("site:") && $0.dropFirst(5).contains(":") }
    let before = portGrant ? (try? decode(try call(netRequest(.netPolicy, name, session), g), NetworkPolicy.self, g)) : nil
    let after = try decode(try call(r, g), NetworkPolicy.self, g)
    if let before, !g.json {
        for l in PermissionPolicy.lifted(before: before, after: after, grant: grant) { Out.stderr("lifted: \(l)\n") }
    }
    let rep = try decode(try call(netRequest(.netPermissions, name, session), g), PermissionReport.self, g)
    if g.json { Out.json(rep) } else { printPermissions(rep) }
}

struct NetAllow: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "allow",
        abstract: "Switch permissions on (install:python, web, update, …; install = every ecosystem), allow a site (site:api.example.com, or one port: site:10.0.0.5:8780 — site:HOST:P1,P2 for several), open a port of this Mac (host:8780 — reached as host.dozable.internal:8780; host:8780:tag names it to that service), or set a preset (standard, locked, open). Live.")
    @OptionGroup var g: GlobalOptions
    @Argument var name: String
    @Argument(help: "Permission ids (doz net permissions), site:HOST or site:HOST:PORT[,PORT], host:PORT[:tag], or standard / locked / open.") var what: [String]
    @Flag(name: [.short, .long], help: "Do not ask (Browse the web warns first).") var yes = false
    @Option(name: .long, help: "@mac: the fenced session.") var session: String?
    func run() async throws {
        let s = try netSession(name, session)
        guard !what.isEmpty else { throw ValidationError("allow what? a permission (doz net permissions) or site:HOST") }
        let presets = what.filter { ["standard", "locked", "open"].contains($0) }
        if what.contains("web") || presets.contains("open"), let w = AgentPermissions.permission("web")?.warning {
            if !g.json { Out.stderr("Browse the web: \(w)\n") }
            try confirm("Let the agent reach any website?", yes: yes, g)
        }
        // 599d: the user's GitHub login is said before it is switched on.
        if what.contains(AgentPermissions.gitHubPush) || what.contains(AgentPermissions.gitHubAsYou) {
            let push = what.contains(AgentPermissions.gitHubPush)
            if let w = AgentPermissions.permission(push ? AgentPermissions.gitHubPush : AgentPermissions.gitHubAsYou)?.warning, !g.json {
                Out.stderr("\(push ? "Push to GitHub" : "Use GitHub as you"): \(w) The token never enters the sandbox; doz net deny \(name) github:as-you revokes it at once.\n")
            }
            try confirm(push ? "Let the agent push and act on GitHub as you?" : "Sign the agent in to GitHub as you (read-only)?", yes: yes, g)
        }
        try changePermissions(name, session: s, grant: what.filter { !presets.contains($0) }, revoke: [], preset: presets.last.map { $0 == "standard" ? "agent" : $0 }, g)
    }
}

struct NetDeny: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "deny",
        abstract: "Switch permissions off (web, update, install:node, …), deny a site (site:HOST, or just a port of it: site:HOST:PORT), or close a port of this Mac (host:PORT). Live.")
    @OptionGroup var g: GlobalOptions
    @Argument var name: String
    @Argument(help: "Permission ids (doz net permissions), site:HOST or site:HOST:PORT[,PORT], or host:PORT.") var what: [String]
    @Option(name: .long, help: "@mac: the fenced session.") var session: String?
    func run() async throws {
        let s = try netSession(name, session)
        guard !what.isEmpty else { throw ValidationError("deny what? a permission (doz net permissions) or site:HOST") }
        try changePermissions(name, session: s, grant: [], revoke: what, preset: nil, g)
    }
}

struct NetPermissionsList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "permissions", abstract: "Every permission, what it means, and the hosts behind it (this doz's).")
    @OptionGroup var g: GlobalOptions
    func run() async throws {
        if g.json { Out.json(AgentPermissions.all); return }
        var t = [["PERMISSION", "WHAT IT MEANS", "HOSTS"]]
        for p in AgentPermissions.all {
            t.append([p.id, (p.group == "install" ? "Install software — " : "") + p.title + ": " + p.summary + (p.warning.map { " ⚠ " + $0 } ?? ""),
                      p.hosts.map { $0.host + ($0.pathPrefixes != nil ? " (its own package)" : "") }.joined(separator: ", ")])
        }
        Out.stdout(Out.table(t))
        Out.stdout("\nPresets: locked (model only), standard (model, update, system + the base's packages, github, error-reports), open (everything but your GitHub login — github:as-you and github:push are only ever switched on by name).\n"
                   + "Sites: site:HOST (every port), site:HOST:PORT or site:HOST:P1,P2 (just those ports). This Mac's ports: host:PORT (reached as \(HostRoute.hostName):PORT; host:PORT:tag names the sandbox or session to it) — never part of a preset, Open included.\n"
                   + "doz net allow NAME PERMISSION|site:HOST[:PORT]|host:PORT · doz net deny NAME … · doz create NAME --allow web,site:…,host:… (or --host-port PORT) · the setting defaults.permissions\n")
    }
}
