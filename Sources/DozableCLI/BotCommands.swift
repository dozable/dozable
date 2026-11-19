import ArgumentParser
import Darwin
import Foundation
import DozableChat
import DozableHost

// `doz bot …`: Agents / Bots — lasting identities, each a participant in chat with its agent program, where it runs and its
// own token. Looking (ls, show) answers from the store when no daemon runs and never starts one; changes go through the
// daemon (the one writer of the record, the chat server's participants and the bots' keychain items). A token is never an
// argument, never in --json, never printed into a pipe: a held bot's stays in the login keychain, a bot elsewhere's is shown
// once on a terminal or written to a new file (--to-file). Exit codes: 2 not found · 4 already exists, or a retired name ·
// 6 the daemon or the keychain unavailable · 64 usage (a missing --yes included).

struct BotCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bot",
        abstract: "Agents / Bots: lasting identities in chat — each with its agent, where it runs, and its own token.",
        discussion: """
        An Agent / Bot is a participant in chat that keeps its name: its agent program (--agent), its model and account, \
        where it runs (--isolation: vm, fenced — the default —, unfenced, which acts as you, or elsewhere) and how the chat \
        server reaches it (--deliver: poll — the default —, inbox or webhook).

        Dozable keeps the token of a bot that runs on this Mac in your login keychain and never shows it. A bot elsewhere \
        gets its token once, on a terminal or in a new file (--to-file); Dozable never keeps it. Retiring a bot keeps its \
        name with its old messages: nobody can take it again.
        """,
        subcommands: [BotNew.self, BotList.self, BotShow.self, BotSet.self, BotRetire.self, BotAdopt.self, BotTokenCommand.self])
}

// MARK: helpers

func botRequest(_ op: HostOp, _ b: BotRequest) -> HostRequest {
    var r = HostRequest(op)
    r.botRequest = b
    return r
}

/// The instructions from a file, or standard input with `-`: UTF-8, at most 256 KiB.
func botInstructions(_ file: String, _ g: GlobalOptions) throws -> String {
    let d: Data
    if file == "-" {
        d = FileHandle.standardInput.readDataToEndOfFile()
    } else {
        guard let x = FileManager.default.contents(atPath: workspaceAbsolute(file)) else { throw fail(HostError(.notFound, "cannot read \(file)"), g) }
        d = x
    }
    do { try BotFields.checkInstructions(d) } catch let e as HostError { throw fail(e, g) }
    return String(decoding: d, as: UTF8.self)
}

/// `a,b` → `[a, b]` (spaces trimmed, empties dropped).
func botSkills(_ s: String) -> [String] {
    s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
}

/// Ask before a change that cannot be undone: `--yes`, else a terminal. With `--json`, or with no terminal, `--yes` is
/// required (exit 64) — and nothing is changed.
func botConfirm(_ question: String, yes: Bool, _ g: GlobalOptions) throws {
    if yes { return }
    guard !g.json, isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1 else {
        throw fail(HostError(.invalid, "\(question) — pass --yes\(g.json ? " (required with --json)" : " (there is no terminal to ask)"); nothing was changed"), g)
    }
    try confirm(question, yes: false, g)
}

/// The bot as it is now (check, then ask).
func botLook(_ name: String, _ g: GlobalOptions) async throws -> BotDetail {
    if let why = ChatNames.refusal(name) { throw fail(HostError(.invalid, why), g) }
    return try decode(try await query(botRequest(.botShow, BotRequest(name: name)), g), BotDetail.self, g)
}

/// Its rooms, asked of the running chat server over your socket (nil: chat is off or not answering).
func botRooms(_ name: String, _ g: GlobalOptions) -> [String]? {
    guard ChatSettingsView.read().enabled else { return nil }
    let c = ChatOwnerClient(paths: ChatPaths(store: g.dozableStore))
    guard let a = try? c.request("GET", "/api/state"), a.status == 200, let v = try? ChatJSON.parse(a.body) else { return nil }
    let rooms = ChatStateView(v).rooms
    return rooms.keys.sorted().filter { rooms[$0]!.contains(name) }
}

func botTokenWords(_ t: BotTokenState) -> String {
    switch t.keeper {
    case "dozable": "held by Dozable · fp \(t.fingerprint ?? "?")"
    case "elsewhere": "held elsewhere · shown once (fp \(t.fingerprint ?? "?"))"
    default: "none (retired)"
    }
}

/// The bot as a person reads it.
func printBot(_ d: BotDetail) {
    let model = d.model.map { " · \($0)" } ?? ""
    var s = "\(d.name) — \(d.agent)\(model), \(BotIsolation.words(d.isolation.default)), \(d.deliver == "poll" ? "polls" : d.deliver)"
    if let at = d.retiredAt { s += " — retired \(BotName.day(at))" }
    s += "\n"
    s += "  kind          \(d.kind)\(d.origin == "adopted" ? " (adopted from chat)" : "")\n"
    if let a = d.account { s += "  account       \(a)\n" }
    if let a = d.avatar { s += "  avatar        \(a)\n" }
    s += "  token         \(botTokenWords(d.token))\n"
    if d.retiredAt == nil {
        s += "  in chat       " + (d.inChat ? (d.rooms.map { $0.isEmpty ? "yes, in no room" : "yes, in " + $0.map { "#" + $0 }.joined(separator: ", ") } ?? "yes") : "no") + "\n"
    }
    if let e = d.webhookEntry { s += "  webhook entry \(e)\n" }
    if let x = d.session { s += "  session       \(x)\n" }
    s += "  skills        \(d.skills.isEmpty ? "none" : d.skills.joined(separator: ", "))\n"
    s += "  instructions  \(d.instructions.map { "\($0.bytes) bytes" } ?? "none")\n"
    s += "  workspaces    \(d.workspaces.isEmpty ? "none" : d.workspaces.joined(separator: ", "))"
        + (d.manages.isEmpty ? "" : " (manages \(d.manages.map { $0 == d.running ? $0 + ", running" : $0 }.joined(separator: "; ")))")
        + (d.worksIn.map { " (works in: \($0))" } ?? "") + "\n"
    for n in d.notes ?? [] { s += "note: \(n)\n" }
    Out.stdout(s)
}

/// What a change's `--json` prints — never the token (`tokenFile` names the file it went to).
struct BotChangeOutput: Encodable {
    var bot: BotDetail
    var tokenFile: String?
}

/// A change that may come back with a bot elsewhere's token: where it goes is opened first (a terminal, or a new file only
/// you can read) — refused before anything changes when there is neither. The token is written there and then dropped.
func botChangeCall(_ op: HostOp, _ b: BotRequest, tokenComes: Bool, toFile: String?, _ g: GlobalOptions) throws -> (BotChange, TokenDestination?) {
    if toFile != nil && !tokenComes {
        throw fail(HostError(.invalid, "--to-file is for a bot elsewhere: a held bot's token stays in your login keychain"), g)
    }
    let dest = tokenComes ? try TokenDestination.open(toFile, g) : nil
    do {
        let c = try decode(try call(botRequest(op, b), g), BotChange.self, g)
        if c.oneTimeToken == nil { dest?.abandon() }
        return (c, c.oneTimeToken == nil ? nil : dest)
    } catch {
        dest?.abandon()
        throw error
    }
}

/// Prints the change (or its --json), and the token, once, where it was asked to go.
func botFinish(_ c: BotChange, _ dest: TokenDestination?, _ g: GlobalOptions, said: String) {
    let name = c.bot.name
    if g.json {
        if let t = c.oneTimeToken { dest?.deliver(t, name: name, again: "doz bot token \(name) --new") }
        Out.json(BotChangeOutput(bot: c.bot, tokenFile: c.oneTimeToken == nil ? nil : dest?.file))
        return
    }
    Out.stdout(said + "\n")
    printBot(c.bot)
    if let t = c.oneTimeToken { dest?.deliver(t, name: name, again: "doz bot token \(name) --new") }
}

// MARK: commands

struct BotNew: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "new", abstract: "Make an Agent / Bot: a new participant in chat with its own token.",
        discussion: """
        Its token is made by the daemon. For a bot that runs on this Mac (--isolation vm, fenced or unfenced) it is kept in \
        your login keychain and never shown; for a bot elsewhere it is shown once on a terminal, or written to a new file \
        with --to-file. Example: doz bot new mira --agent claude-code --deliver inbox
        """)
    @OptionGroup var g: GlobalOptions
    @Argument(help: "Its name in chat: a lower-case letter, then lower-case letters, digits and -.") var name: String
    @Option(name: .long, help: "Its agent program: claude-code, codex, … (doz search).") var agent: String
    @Option(name: .long, help: "Its model.") var model: String?
    @Option(name: .long, help: "Where it runs: vm, fenced (the default), unfenced (acts as you — only when named) or elsewhere.") var isolation: String?
    @Option(name: .long, help: "How the chat server reaches it: poll (the default), inbox (a Claude Code bot) or webhook.") var deliver: String?
    @Option(name: .customLong("webhook-entry"), help: "With --deliver webhook: the entry it uses (default: its own name).") var webhookEntry: String?
    @Option(name: .long, help: "With --deliver inbox: the Claude Code session's name (default: its own name).") var session: String?
    @Option(name: .long, help: "Its skills, comma-separated (chat-manager,…).") var skills: String?
    @Option(name: .customLong("instructions-file"), help: "Its instructions: a file (at most 256 KiB), or - for standard input; copied into the store.") var instructionsFile: String?
    @Option(name: .long, help: "Its account: one of doz account ls, or mac.") var account: String?
    @Option(name: .long, help: "Its avatar (a short text or an emoji).") var avatar: String?
    @Option(name: .customLong("to-file"), help: "A bot elsewhere: write its token to this new file instead of the terminal.") var toFile: String?

    func run() async throws {
        if let why = ChatNames.refusal(name) { throw fail(HostError(.invalid, why), g) }
        var b = BotRequest(name: name)
        b.agent = agent; b.model = model; b.isolation = isolation; b.deliver = deliver; b.webhookEntry = webhookEntry; b.session = session
        b.skills = skills.map(botSkills); b.account = account; b.avatar = avatar
        if let f = instructionsFile { b.instructions = try botInstructions(f, g) }
        let (c, dest) = try botChangeCall(.botNew, b, tokenComes: isolation == "elsewhere", toFile: toFile, g)
        botFinish(c, dest, g, said: "Made the Agent / Bot \(name).")
    }
}

struct BotList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ls", abstract: "The Agents / Bots: agent and model, where each runs, how it is reached, what it manages.")
    @OptionGroup var g: GlobalOptions
    @Flag(name: .long, help: "The retired bots instead (their names stay with their old messages).") var retired = false
    func run() async throws {
        var b = BotRequest()
        b.retired = retired ? true : nil
        let l = try decode(try await query(botRequest(.botList, b), g), BotListing.self, g)
        if g.json { Out.json(l); return }
        if l.bots.isEmpty {
            Out.stdout(retired ? "No retired bots.\n" : "Agents / Bots: none yet — doz bot new NAME --agent AGENT\n")
            return
        }
        var t = [["NAME", "AGENT · MODEL", "ISOLATION", "REACHED", "MANAGES"] + (retired ? ["RETIRED"] : [])]
        for r in l.bots {
            t.append([r.name, r.agent + (r.model.map { " · \($0)" } ?? ""), BotIsolation.words(r.isolation),
                      (r.deliver == "poll" ? "polls" : r.deliver) + (r.inChat || retired ? "" : " (not in chat)"),
                      botWhere(r)] + (retired ? [r.retiredAt.map(BotName.day) ?? "?"] : []))
        }
        Out.stdout(Out.table(t))
    }
}

/// `bot ls`'s MANAGES column: what it manages ("demo (running)"), and where it works now as a worker ("works in: wk").
func botWhere(_ r: BotRow) -> String {
    let parts = r.manages.map { $0 == r.running ? $0 + " (running)" : $0 } + (r.worksIn.map { ["works in: " + $0] } ?? [])
    return parts.isEmpty ? "—" : parts.joined(separator: ", ")
}

struct BotShow: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "show", abstract: "An Agent / Bot: its agent, isolation, delivery, where its token is, its rooms.")
    @OptionGroup var g: GlobalOptions
    @Argument(help: "The bot.") var name: String
    @Flag(name: .long, help: "Print its instructions' text (with --json: the instructionsText field).") var instructions = false
    func run() async throws {
        if instructions {
            if let why = ChatNames.refusal(name) { throw fail(HostError(.invalid, why), g) }
            var b = BotRequest(name: name)
            b.withInstructions = true
            let d = try decode(try await query(botRequest(.botShow, b), g), BotDetail.self, g)
            if g.json { Out.json(d); return }
            guard let text = d.instructionsText else { Out.stdout("\(name) has no instructions.\n"); return }
            Out.stdout(text.hasSuffix("\n") || text.isEmpty ? text : text + "\n")
            return
        }
        var d = try await botLook(name, g)
        if d.retiredAt == nil, d.inChat { d.rooms = botRooms(name, g) }
        if g.json { Out.json(d); return }
        printBot(d)
    }
}

struct BotSet: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "set", abstract: "Change an Agent / Bot: model, account, avatar, skills, instructions, isolation or delivery.",
        discussion: """
        --deliver changes how the chat server reaches it, keeping its token, rooms and history. Moving it to or from \
        elsewhere replaces its token: to elsewhere, the new one is shown once (or --to-file); to this Mac, it is kept in your \
        login keychain.
        """)
    @OptionGroup var g: GlobalOptions
    @Argument(help: "The bot.") var name: String
    @Option(name: .long, help: "Its model.") var model: String?
    @Option(name: .long, help: "Its account: one of doz account ls, or mac.") var account: String?
    @Option(name: .long, help: "Its avatar.") var avatar: String?
    @Option(name: .long, help: "Its skills, comma-separated (replaces the list).") var skills: String?
    @Option(name: .customLong("instructions-file"), help: "New instructions: a file, or - for standard input.") var instructionsFile: String?
    @Option(name: .long, help: "Where it runs: vm, fenced, unfenced (acts as you) or elsewhere.") var isolation: String?
    @Option(name: .long, help: "How the chat server reaches it: poll, inbox or webhook.") var deliver: String?
    @Option(name: .customLong("webhook-entry"), help: "With --deliver webhook: the entry it uses (default: its own name).") var webhookEntry: String?
    @Option(name: .long, help: "With --deliver inbox: the Claude Code session's name (default: its own name).") var session: String?
    @Option(name: .customLong("to-file"), help: "Moving it elsewhere: write its new token to this new file instead of the terminal.") var toFile: String?

    func run() async throws {
        let now = try await botLook(name, g)
        var b = BotRequest(name: name)
        b.model = model; b.account = account; b.avatar = avatar; b.skills = skills.map(botSkills); b.isolation = isolation
        b.deliver = deliver; b.webhookEntry = webhookEntry; b.session = session
        if let f = instructionsFile { b.instructions = try botInstructions(f, g) }
        let toElsewhere = isolation == "elsewhere" && now.isolation.default != "elsewhere" && now.retiredAt == nil
        let (c, dest) = try botChangeCall(.botSet, b, tokenComes: toElsewhere, toFile: toFile, g)
        botFinish(c, dest, g, said: "Changed \(name).")
    }
}

struct BotRetire: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "retire", abstract: "Retire an Agent / Bot: it leaves chat, its token is refused, its name stays with its old messages.",
        discussion: "A retired name is never taken again — not by doz bot new, doz bot adopt or doz chat add. A bot in a workspace is released from it first.")
    @OptionGroup var g: GlobalOptions
    @Argument(help: "The bot.") var name: String
    @Flag(name: .long, help: "Do not ask (required with --json, or with no terminal).") var yes = false
    func run() async throws {
        let d = try await botLook(name, g)
        if let at = d.retiredAt { throw fail(HostError(.exists, "\(name) was retired \(BotName.day(at)) already"), g) }
        try botConfirm("Retire \(name)? It leaves chat and its token is refused; its name stays with its old messages and is never used again", yes: yes, g)
        let c = try decode(try call(botRequest(.botRetire, BotRequest(name: name)), g), BotChange.self, g)
        if g.json { Out.json(BotChangeOutput(bot: c.bot)); return }
        Out.stdout("Retired \(name): it left chat and its token is refused. Its old messages keep its name.\n")
    }
}

struct BotAdopt: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "adopt", abstract: "Make an existing participant in chat an Agent / Bot (its token is replaced).",
        discussion: """
        Its kind, rooms and history are kept. Its token is replaced: Dozable never had the old one. An agent still using the \
        old token stops working the moment this runs (the chat server refuses it).
        """)
    @OptionGroup var g: GlobalOptions
    @Argument(help: "The participant (doz chat who).") var name: String
    @Option(name: .long, help: "Its agent program: claude-code, codex, … (doz search).") var agent: String
    @Option(name: .long, help: "Its model.") var model: String?
    @Option(name: .long, help: "Where it runs: vm, fenced (the default), unfenced (acts as you) or elsewhere.") var isolation: String?
    @Option(name: .long, help: "How the chat server reaches it from now on: poll, inbox or webhook (default: as it is).") var deliver: String?
    @Option(name: .customLong("webhook-entry"), help: "With --deliver webhook: the entry it uses (default: its own name).") var webhookEntry: String?
    @Option(name: .long, help: "With --deliver inbox: the Claude Code session's name (default: its own name).") var session: String?
    @Option(name: .long, help: "Its skills, comma-separated.") var skills: String?
    @Option(name: .customLong("instructions-file"), help: "Its instructions: a file, or - for standard input.") var instructionsFile: String?
    @Option(name: .long, help: "Its account: one of doz account ls, or mac.") var account: String?
    @Option(name: .long, help: "Its avatar.") var avatar: String?
    @Option(name: .customLong("to-file"), help: "A bot elsewhere: write its new token to this new file instead of the terminal.") var toFile: String?
    @Flag(name: .long, help: "Do not ask (required with --json, or with no terminal).") var yes = false

    func run() async throws {
        if let why = ChatNames.refusal(name) { throw fail(HostError(.invalid, why), g) }
        var b = BotRequest(name: name)
        b.agent = agent; b.model = model; b.isolation = isolation; b.deliver = deliver; b.webhookEntry = webhookEntry; b.session = session
        b.skills = skills.map(botSkills); b.account = account; b.avatar = avatar
        if let f = instructionsFile { b.instructions = try botInstructions(f, g) }
        if !g.json {
            Out.stdout("\(name) becomes a bot. Its token is replaced: Dozable never had the old one. An agent still using the old token stops working the moment this runs (the chat server refuses it).\n")
        }
        try botConfirm("Make \(name) a bot and replace its token?", yes: yes, g)
        let (c, dest) = try botChangeCall(.botAdopt, b, tokenComes: isolation == "elsewhere", toFile: toFile, g)
        botFinish(c, dest, g, said: "\(name) is a bot now; its token is replaced.")
    }
}

struct BotTokenCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "token", abstract: "Where an Agent / Bot's token is; --new replaces it (the old one is refused at once).",
        discussion: """
        A held bot's new token goes into your login keychain and is never shown (only its fingerprint). A bot elsewhere's is \
        shown once on a terminal, or written to a new file with --to-file.
        """)
    @OptionGroup var g: GlobalOptions
    @Argument(help: "The bot.") var name: String
    @Flag(name: .customLong("new"), help: "Replace its token.") var new = false
    @Option(name: .customLong("to-file"), help: "A bot elsewhere: write its new token to this new file instead of the terminal.") var toFile: String?

    func run() async throws {
        let d = try await botLook(name, g)
        guard new else {
            if toFile != nil { throw fail(HostError(.invalid, "--to-file goes with --new"), g) }
            if g.json { Out.json(d.token); return }
            Out.stdout("\(name): \(botTokenWords(d.token))\n")
            return
        }
        if let at = d.retiredAt { throw fail(BotName.retiredRefusal(name, at), g) }
        let (c, dest) = try botChangeCall(.botToken, BotRequest(name: name), tokenComes: d.isolation.default == "elsewhere", toFile: toFile, g)
        let held = c.bot.token.keeper == "dozable"
        botFinish(c, dest, g, said: held ? "Replaced \(name)'s token (fp \(c.bot.token.fingerprint ?? "?")), kept in your login keychain: the old one is refused from now on; a running \(name) stops working until it is started again."
                                        : "Replaced \(name)'s token: the old one is refused from now on.")
    }
}
