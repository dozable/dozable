import Foundation
import DozableHost

// `doz workspace show W --can-do | --network | --folders`: the workspace-wide views as text — each one more read-only
// request beside `workspace-show` (`workspace-reach`, `workspace-folders`), answered from the store when no daemon runs and
// never starting one. Never a secret's value or a token: a held secret is a name, where it goes and a fingerprint.

/// `show --json` with a view: the detail's own fields, plus `reach` or `folders`.
struct WorkspaceShowJSON: Encodable {
    let detail: WorkspaceDetail
    let reach: WorkspaceReach?
    let folders: WorkspaceFolders?
    enum K: String, CodingKey { case reach, folders }
    func encode(to encoder: Encoder) throws {
        try detail.encode(to: encoder)
        var c = encoder.container(keyedBy: K.self)
        try c.encodeIfPresent(reach, forKey: .reach)
        try c.encodeIfPresent(folders, forKey: .folders)
    }
}

/// A view's answer from a daemon that does not know it (an older one): said, with what to do.
func workspaceViewAnswer<T: Decodable>(_ op: HostOp, _ w: WorkspaceRequest, _ t: T.Type, _ g: GlobalOptions) async throws -> T {
    // An older daemon cannot read the request at all (it says so: "is the CLI newer than the daemon?"), or answers the older
    // shape (a log's entries, its paging ignored).
    let v = try await query(workspaceRequest(op, w), g)
    do { return try v.decode(T.self) } catch {
        throw fail(HostError(.unavailable, "\(op.rawValue) needs the daemon of this version — doz daemon restart"), g)
    }
}

/// The command that allows a refused site for one agent (a fenced session's names its session).
func workspaceAllowCommand(_ a: AgentReach, _ grant: String) -> String {
    a.kind == "mac" ? "doz net allow @mac --session \(a.place.dropFirst(MacPlace.name.count + 1)) \(grant)" : "doz net allow \(a.place) \(grant)"
}

func printCanDo(_ r: WorkspaceReach) {
    var s = ""
    for a in r.agents {
        s += "\(a.name) — \(a.role) · \(a.actsAsYou ? "unfenced · acts as you" : BotIsolation.words(a.isolation)) · \(a.place)\n"
        s += MacFence.capabilitiesText(a.capabilities).split(separator: "\n").map { "  " + $0 }.joined(separator: "\n") + "\n"
    }
    if r.agents.isEmpty { s += "no agents yet\n" }
    Out.stdout(s)
}

func printNetwork(_ r: WorkspaceReach) {
    func preset(_ p: String?) -> String { p == "agent" ? "standard" : p ?? "custom" }
    var s = "The workspace's permissions\n"
    var rows = [["AGENT", "NETWORK", "PLUS", "REFUSED"]]
    for a in r.agents {
        let n = a.network
        rows.append([a.name, n.proxied ? preset(n.preset) + (n.live ? "" : " (next start)") : a.isolation == "elsewhere" ? "not run by Dozable" : "not limited, not logged",
                     n.sites.isEmpty ? "—" : n.sites.joined(separator: ", "),
                     !n.proxied ? "—" : r.refusalsKnown ? String(n.refused.reduce(0) { $0 + $1.count }) : "not known"])
    }
    rows.append(["new workers", r.defaults.network, "", ""])
    s += Out.table(rows) + "  new workers are \(r.defaults.isolation) — the default stays as it is\n"
    s += "\nRefused lately\n"
    if !r.refusalsKnown {
        s += "  not known: no daemon is running\n"
    } else {
        let all = r.agents.flatMap { a in a.network.refused.map { (a, $0) } }
        if all.isEmpty { s += "  nothing\n" }
        for (a, x) in all {
            s += "  \(a.name) → \(x.host)\(x.port.map { ":\($0)" } ?? "") ×\(x.count)   \(workspaceAllowCommand(a, x.grant))\n"
        }
    }
    s += "\nThis Mac's ports\n"
    var any = false
    for a in r.agents where !a.network.hostPorts.isEmpty {
        any = true
        s += "  \(a.name): \(a.network.hostPorts.map { "\($0.port)" }.joined(separator: ", ")) (as host.dozable.internal:PORT)\n"
    }
    for a in r.agents where !a.network.forwarded.isEmpty {
        any = true
        s += "  \(a.name) forwards out: " + a.network.forwarded.map { "\($0.port)" + ($0.local.map { " → this Mac's localhost:\($0)" } ?? "") }.joined(separator: ", ") + "\n"
    }
    if !any { s += "  none\n" }
    s += "\nHeld for agents (they see placeholders)\n"
    let held = r.agents.flatMap { a in a.held.map { (a, $0) } }
    if held.isEmpty { s += "  none\n" } else {
        s += Out.table([["NAME", "FOR", "TO", "KIND", "FINGERPRINT"]] + held.map { a, h in
            [h.name, a.name, h.kind == "given" ? h.to : "the room (\(h.to))", h.kind, h.fingerprint.map { $0 + "…" } ?? "—"]
        }).split(separator: "\n").map { "  " + $0 }.joined(separator: "\n") + "\n"
    }
    s += "\nAccounts used here\n"
    var byAccount: [String: [String]] = [:]
    for a in r.agents { if let acc = a.account { byAccount[acc, default: []].append(a.name) } }
    if byAccount.isEmpty { s += "  none given by Dozable\n" }
    for (acc, names) in byAccount.sorted(by: { $0.key < $1.key }) {
        s += "  \(acc == "mac" ? "this Mac's own Claude login" : acc) — \(names.joined(separator: ", "))\n"
    }
    s += "\nNothing here shows a secret: a name, where it goes and a fingerprint. The values stay in your keychain.\n"
    Out.stdout(s)
}

func printFolders(_ f: WorkspaceFolders) {
    let df = DateFormatter()
    df.dateFormat = "yyyy-MM-dd HH:mm"
    var s = "Changed since \(df.string(from: f.since)) — by folder; deletions are not known; never which agent changed a file\n"
    if f.folders.isEmpty { s += "\nno folders\n" }
    for x in f.folders {
        var rules: [String] = []
        if let n = x.rules.ignore { rules.append(".dozignore (\(n))") }
        if let n = x.rules.readonly { rules.append(".dozreadonly (\(n))") }
        s += "\n\(DisplayPath.tilde(x.path)) · \(x.mode)\(x.main ? " · main" : "")\(x.workspace ? "" : " · an agent's own")"
            + (rules.isEmpty ? "" : " · rules: " + rules.joined(separator: " · ")) + (x.agents.isEmpty ? "" : " · " + x.agents.joined(separator: ", ")) + "\n"
        if !x.exists { s += "  not there (or not a folder this Mac can read without following a link)\n"; continue }
        if x.hidden == true { s += "  not shown to this browser\n"; continue }
        if x.changes.isEmpty { s += "  nothing changed\n" }
        for c in x.changes { s += "  \(c.kind) \(c.path)\n" }
        if x.truncated { s += "  … \(x.count) changed in the \(x.scanned) entries looked at (cut short at its limits)\n" }
    }
    s += "\nRestore points\n"
    if f.points.isEmpty { s += "  none — a restore point is per Sandbox agent (its disk)\n" }
    for p in f.points {
        s += "  \(p.agent) (\(p.sandbox)): " + (p.rows.isEmpty ? "none yet — doz point take \(p.sandbox) NAME" : "") + "\n"
        for r in p.rows.sorted(by: { $0.createdAt > $1.createdAt }) {
            s += "    \(df.string(from: r.createdAt))  \(r.name)\(r.automatic ? " (auto)" : "")\n"
        }
    }
    Out.stdout(s)
}
