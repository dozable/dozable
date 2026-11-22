import ArgumentParser
import Foundation
import DozableHost

// `doz permissions …`, `doz why`, and the aliases `doz grant …` and `doz bot ceiling`: what agents may do in Dozable — one list
// of permissions, each answered allow, ask or never; roles that bundle answers; grants in a scope; ceilings above them. NOT
// `doz net permissions`, which is what a sandbox's network may reach. Looking (show, why) answers from the store when no
// daemon runs and never starts one; changes are yours, through the daemon. Nothing here constrains you: permissions are for
// agents only, and none is enforced yet — no agent can drive Dozable. Exit codes: 2 not found · 6 the daemon unavailable ·
// 64 usage.

struct PermissionsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "permissions",
        abstract: "What agents may do in Dozable: permissions, roles, grants and ceilings (not a sandbox's network — that is doz net permissions).",
        discussion: """
        Every permission is answered allow, ask or never. A role bundles answers (manager, worker, member, decider, admin, and \
        the presets cautious-manager and trusted-manager); an agent's role in a workspace is the one the workspace gives it. A \
        grant gives a role, or one permission's answer, everywhere, in a workspace or in one of its rooms, optionally until a \
        date. A ceiling — this Mac's, a bot's, a workspace's, and Dozable's own above them — is the most an agent may ever get. \
        doz why AGENT PERM says which step decided.

        Permissions constrain agents, never you. None is enforced yet: no agent can drive Dozable.
        """,
        subcommands: [PermissionsShow.self, PermissionsWhy.self, PermissionsGrant.self, PermissionsRevoke.self, PermissionsCeiling.self])
}

/// `doz grant …`: the same commands, by the words the design's screens use.
struct GrantCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "grant",
        abstract: "Give an agent or bot a role or an answer (doz grant otto worker --in demo); ls, why and revoke as in doz permissions.",
        subcommands: [GrantGive.self, GrantList.self, GrantWhy.self, GrantRevoke.self], defaultSubcommand: GrantGive.self)
}

func permissionsRequest(_ op: HostOp, _ p: PermissionsRequest) -> HostRequest {
    var r = HostRequest(op)
    r.permissionsRequest = p
    return r
}

/// `--until`: a date (2026-12-01, or an ISO 8601 time), or a time from now (`45m`, `2h`, `3d`).
func grantUntil(_ s: String?, _ g: GlobalOptions) throws -> Date? {
    guard let s else { return nil }
    let t = s.trimmingCharacters(in: .whitespaces)
    if let last = t.last, let n = Double(t.dropLast()), n > 0 {
        switch last {
        case "s": return Date().addingTimeInterval(n)
        case "m": return Date().addingTimeInterval(n * 60)
        case "h": return Date().addingTimeInterval(n * 3600)
        case "d": return Date().addingTimeInterval(n * 86_400)
        default: break
        }
    }
    if let d = WorkspaceStore.since(t, now: Date()), t.contains("-") { return d }
    throw fail(HostError(.invalid, "--until \(t.prefix(40)): a date (2026-12-01), a time (ISO 8601) or a time from now (45m, 2h, 3d)"), g)
}

// MARK: text

func printPermissionsShown(_ s: PermissionsShown) {
    var out = ""
    func grants(_ title: String, _ rows: [GrantRow]) {
        out += "\(title)\n"
        if rows.isEmpty { out += "  none\n"; return }
        var t = [["SUBJECT", "GRANT", "WHERE", "UNTIL", "BY"]]
        for r in rows {
            t.append([r.subject, r.what, r.scope, r.until.map { (r.ended ? "ended " : "") + BotName.day($0) } ?? "—", r.by])
        }
        out += Out.table(t).split(separator: "\n").map { "  " + $0 }.joined(separator: "\n") + "\n"
    }
    func ceilings(_ title: String, _ rows: [CeilingRow]) {
        out += "\(title)\n"
        if rows.isEmpty { out += "  none set: no cap\n"; return }
        for r in rows { out += "  ▲ \(r.words) \(r.perm)=\(r.answer)\n" }
    }
    switch s.view {
    case "roles":
        let roles = s.roleTable ?? []
        var t = [["PERMISSION"] + roles.map(\.name)]
        for p in GrantPermissions.ids {
            t.append([p] + roles.map { r in r.answers[p].flatMap(GrantAnswer.init(rawValue:))?.mark ?? "·" })
        }
        out += "The roles — ✓ allow · ? ask · ✕ never · · says nothing\n" + Out.table(t)
        for r in roles { out += "  \(r.name): \(r.words)\n" }
    case "mac":
        ceilings("This Mac's ceiling", s.ceilings)
        out += "\n"
        grants("Grants everywhere", s.grants)
    case "bot":
        out += "\(s.subject ?? "?") — an Agent / Bot\n"
        ceilings("Its ceiling", s.ceilings)
        out += "Its roles\n" + ((s.botRoles ?? []).isEmpty ? "  not an agent of any workspace\n" : (s.botRoles ?? []).map { "  \($0)\n" }.joined())
        grants("Its grants", s.grants)
    case "agent":
        for a in s.agents {
            out += "\(a.name)" + (a.workspace.map { " in \($0)" } ?? "") + " — " + (a.roles.isEmpty ? "no role" : a.roles.joined(separator: ", "))
                + (a.actsAsYou ? " · unfenced, acts as you" : "") + "\n"
            var t = [["PERMISSION", "ANSWER", "SOURCE", "ENFORCED"]]
            for r in a.rows { t.append([r.perm, r.answer, r.sourceText, r.enforced]) }
            out += Out.table(t)
            out += "  \(a.counts)\n"
        }
        out += "\n"
        ceilings("Ceilings", s.ceilings)
        grants("Grants", s.grants)
    case "workspace":
        out += "\(s.workspace ?? "?") — what each agent may do (✎ a grant · ▲ a ceiling)\n"
        if s.agents.isEmpty { out += "  no agents yet\n" } else {
            var t = [["PERMISSION"] + s.agents.map(\.name)]
            for (i, p) in GrantPermissions.ids.enumerated() {
                t.append([p] + s.agents.map { a in
                    let r = a.rows[i]
                    return r.answer + (r.source == "grant" ? " ✎" : r.source == "ceiling" || r.source == "dozable" ? " ▲" : "")
                })
            }
            out += Out.table(t)
            for a in s.agents { out += "  \(a.name): " + (a.roles.isEmpty ? "no role" : a.roles.joined(separator: ", ")) + " · \(a.counts)\n" }
        }
        out += "\n"
        ceilings("Ceilings", s.ceilings)
        grants("Grants", s.grants)
    default:
        ceilings("Ceilings", s.ceilings)
        out += "\n"
        grants("Grants", s.grants)
    }
    out += "\nEnforced: \(s.enforced). " + PermissionWords.footer.replacingOccurrences(of: "Grants are not enforced yet — no agent can drive Dozable. ", with: "") + "\n"
    for n in s.notes { out += "note: \(n)\n" }
    Out.stdout(out)
}

func printPermissionsChanged(_ c: PermissionsChanged, _ g: GlobalOptions) {
    if g.json { Out.json(c); return }
    var s = c.lines.map { $0 + "\n" }.joined()
    for n in c.notes { s += n + "\n" }
    if c.replayed == true { s += replayedNote }
    Out.stdout(s)
}

// MARK: the commands (shared bodies)

struct ShowOptions: ParsableArguments {
    @Argument(help: "A workspace: each of its agents' answers, its grants and its ceiling.") var workspace: String?
    @Option(name: .long, help: "One agent (or bot) — every permission's answer, where it comes from and where it is enforced.") var agent: String?
    @Option(name: .long, help: "A bot: its ceiling, its roles in each workspace and its grants.") var bot: String?
    @Flag(name: .long, help: "This Mac's ceiling and the grants that apply everywhere.") var mac = false
    @Flag(name: .long, help: "The role table: what each role answers.") var roles = false

    func run(_ g: GlobalOptions) async throws {
        if [agent != nil, bot != nil, mac].filter({ $0 }).count > 1 {
            throw fail(HostError(.invalid, "one of --agent, --bot and --mac"), g)
        }
        var p = PermissionsRequest(workspace: workspace, agent: agent)
        p.bot = bot
        p.mac = mac ? true : nil
        p.roles = roles ? true : nil
        let s = try decode(try await query(permissionsRequest(.permissionsShow, p), g), PermissionsShown.self, g)
        if g.json { Out.json(s); return }
        printPermissionsShown(s)
    }
}

struct WhyOptions: ParsableArguments {
    @Argument(help: "The agent or bot (a name, bot:NAME or agent:W/NAME).") var agent: String
    @Argument(help: "The permission (doz permissions show --roles lists them).") var perm: String
    @Option(name: .customLong("in"), help: "The workspace the action is in (default: the agent's own).") var workspace: String?
    @Option(name: .long, help: "A room of it: its label, or W/R.") var room: String?

    func run(_ g: GlobalOptions) async throws {
        var p = PermissionsRequest(workspace: workspace, agent: agent, perm: perm)
        p.room = room
        let d = try decode(try await query(permissionsRequest(.permissionsWhy, p), g), GrantDecision.self, g)
        if g.json { Out.json(d); return }
        Out.stdout(d.text)
    }
}

struct ScopeOptions: ParsableArguments {
    @Option(name: .customLong("in"), help: "In this workspace.") var workspace: String?
    @Option(name: .long, help: "In one room of a workspace: W/R (or R with --in W).") var room: String?
    @Flag(name: .long, help: "Everywhere.") var everywhere = false

    func into(_ p: inout PermissionsRequest) {
        p.workspace = workspace; p.room = room; p.everywhere = everywhere ? true : nil
    }
}

struct GrantOptions: ParsableArguments {
    @Argument(help: "Whom: an agent or bot (bot:NAME, agent:W/NAME), or role:ROLE for every agent with that role.") var subject: String
    @Argument(help: "A role (manager, worker, member, admin, cautious-manager, trusted-manager), or PERM=allow|ask|never …") var words: [String] = []
    @OptionGroup var scope: ScopeOptions
    @Option(name: .long, help: "It ends then: a date (2026-12-01) or a time from now (45m, 2h, 3d); it stays listed, ended.") var until: String?
    @Option(name: .customLong("request-id"), help: "An id of yours for this request: sent again with the same id and arguments, it answers the first answer and grants nothing again (kept 24 h).")
    var requestID: String?

    func run(_ g: GlobalOptions) async throws {
        var p = PermissionsRequest(agent: subject)
        scope.into(&p)
        p.words = words
        p.until = try grantUntil(until, g)
        p.untilTyped = requestID == nil ? nil : until?.trimmingCharacters(in: .whitespaces)
        var r = permissionsRequest(.permissionsGrant, p)
        r.requestID = requestID
        printPermissionsChanged(try decode(try call(r, g), PermissionsChanged.self, g), g)
    }
}

struct RevokeOptions: ParsableArguments {
    @Argument(help: "Whom (as granted).") var subject: String
    @Argument(help: "The ROLE or PERM to take back.") var words: [String] = []
    @OptionGroup var scope: ScopeOptions

    func run(_ g: GlobalOptions) async throws {
        var p = PermissionsRequest(agent: subject)
        scope.into(&p)
        p.words = words
        printPermissionsChanged(try decode(try call(permissionsRequest(.permissionsRevoke, p), g), PermissionsChanged.self, g), g)
    }
}

/// `ceiling (--mac | --in W | --bot B) PERM=ask|never … | --clear PERM`.
func runCeiling(mac: Bool, workspace: String?, bot: String?, words: [String], clear: [String], _ g: GlobalOptions) async throws {
    var p = PermissionsRequest(workspace: workspace)
    p.bot = bot
    p.mac = mac ? true : nil
    if words.isEmpty && clear.isEmpty {
        // No change asked: the ceiling as it is.
        var look = PermissionsRequest(workspace: bot == nil && !mac ? workspace : nil)
        look.bot = bot
        look.mac = mac ? true : nil
        let s = try decode(try await query(permissionsRequest(.permissionsShow, look), g), PermissionsShown.self, g)
        if g.json { Out.json(s.ceilings); return }
        let want = bot.map { "bot:" + $0 } ?? (mac ? "mac" : "workspace:" + (workspace ?? ""))
        let mine = s.ceilings.filter { $0.lid == want }
        Out.stdout(mine.isEmpty ? "none set: no cap\n" : mine.map { "▲ \($0.words) \($0.perm)=\($0.answer)\n" }.joined())
        return
    }
    p.words = words
    p.clear = clear.isEmpty ? nil : clear
    printPermissionsChanged(try decode(try call(permissionsRequest(.permissionsCeiling, p), g), PermissionsChanged.self, g), g)
}

// MARK: doz permissions …

struct PermissionsShow: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "show", abstract: "What agents may do: each permission's answer, where it comes from, and that none is enforced yet.",
        discussion: "Without W: every grant and ceiling. Looking never starts the daemon. Example: doz permissions show demo --agent bot1")
    @OptionGroup var g: GlobalOptions
    @OptionGroup var o: ShowOptions
    func run() async throws { try await o.run(g) }
}

struct PermissionsWhy: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "why", abstract: "Which of the five steps decided an agent's answer (the same as doz why).",
        discussion: "Example: doz permissions why bot2 folder.read --in myapp-tests")
    @OptionGroup var g: GlobalOptions
    @OptionGroup var o: WhyOptions
    func run() async throws { try await o.run(g) }
}

struct PermissionsGrant: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "grant", abstract: "Give an agent or bot a role, or one permission's answer, in exactly one scope.",
        discussion: """
        Exactly one of --in W, --room W/R and --everywhere. A grant in a room beats one in its workspace, which beats one \
        everywhere; a never from you wins over everything; a ceiling caps it. The owner role is never granted; admin only \
        --everywhere; deciders are made in chat, by you only. Example: doz permissions grant mira keychain.use=never --in myapp-tests
        """)
    @OptionGroup var g: GlobalOptions
    @OptionGroup var o: GrantOptions
    func run() async throws { try await o.run(g) }
}

struct PermissionsRevoke: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "revoke", abstract: "Take back a grant: a role or a permission's answer.",
        discussion: "A role the workspace gives (its manager, its workers) is not a grant: change the workspace. Example: doz permissions revoke otto sudo --in X")
    @OptionGroup var g: GlobalOptions
    @OptionGroup var o: RevokeOptions
    func run() async throws { try await o.run(g) }
}

struct PermissionsCeiling: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ceiling", abstract: "Set the most an agent may ever get: this Mac's, a workspace's or a bot's ceiling.",
        discussion: "Each PERM=ask or PERM=never; --clear PERM takes a cap away. With no PERM, the ceiling as it is. Example: doz permissions ceiling --mac sudo=never")
    @OptionGroup var g: GlobalOptions
    @Flag(name: .long, help: "This Mac's ceiling (every agent).") var mac = false
    @Option(name: .customLong("in"), help: "A workspace's ceiling (its agents).") var workspace: String?
    @Option(name: .long, help: "A bot's ceiling (wherever it works).") var bot: String?
    @Argument(help: "PERM=ask or PERM=never …") var words: [String] = []
    @Option(name: .long, help: "Take this permission's cap away (repeatable).") var clear: [String] = []
    func run() async throws { try await runCeiling(mac: mac, workspace: workspace, bot: bot, words: words, clear: clear, g) }
}

// MARK: doz why, doz grant …, doz bot ceiling

struct WhyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "why", abstract: "Why an agent's answer is allow, ask or never: the five steps, and what decided.",
        discussion: "Example: doz why bot2 folder.read --in myapp-tests")
    @OptionGroup var g: GlobalOptions
    @OptionGroup var o: WhyOptions
    func run() async throws { try await o.run(g) }
}

struct GrantGive: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "give", abstract: "Give a role or an answer (doz grant SUBJECT … is this command).",
        discussion: "The same as doz permissions grant. Example: doz grant otto worker.start=ask --in mac-admin")
    @OptionGroup var g: GlobalOptions
    @OptionGroup var o: GrantOptions
    func run() async throws { try await o.run(g) }
}

struct GrantList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ls", abstract: "Who holds what, where (the same as doz permissions show).")
    @OptionGroup var g: GlobalOptions
    @OptionGroup var o: ShowOptions
    func run() async throws { try await o.run(g) }
}

struct GrantWhy: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "why", abstract: "Which step decided (the same as doz why).")
    @OptionGroup var g: GlobalOptions
    @OptionGroup var o: WhyOptions
    func run() async throws { try await o.run(g) }
}

struct GrantRevoke: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "revoke", abstract: "Take one back (the same as doz permissions revoke).")
    @OptionGroup var g: GlobalOptions
    @OptionGroup var o: RevokeOptions
    func run() async throws { try await o.run(g) }
}

struct BotCeiling: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ceiling", abstract: "The most a bot may ever get, wherever it works: PERM=ask|never ….",
        discussion: "The same as doz permissions ceiling --bot NAME. Example: doz bot ceiling otto sudo=never keychain.use=never")
    @OptionGroup var g: GlobalOptions
    @Argument(help: "The bot.") var name: String
    @Argument(help: "PERM=ask or PERM=never …") var words: [String] = []
    @Option(name: .long, help: "Take this permission's cap away (repeatable).") var clear: [String] = []
    func run() async throws { try await runCeiling(mac: false, workspace: nil, bot: name, words: words, clear: clear, g) }
}
