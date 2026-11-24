import ArgumentParser
import Foundation
import DozableHost

// `doz worker …`: a workspace's workers — agents brought up to do one task in a started workspace, each a participant in its
// room. Looking (ls) answers from the store when no daemon runs and never starts one; add and end go through the daemon (the
// one writer of the record, the chat server's participants, the tokens and the places). A token is never an argument,
// never in --json, never printed. Exit codes: 2 not found · 3 not in this state (setting up, finished, starting, stopped) ·
// 4 already exists, or the bot runs in another live workspace · 6 the daemon or chat unavailable · 64 usage.

struct WorkerCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "worker",
        abstract: "Workers: agents brought up in a started workspace, each to do one task, in its room.",
        discussion: """
        A worker is an agent brought up in a workspace to do one task: it joins the workspace's room, reads its task, says \
        it is up and gets on with it. It is an identity (who it is) with a session (its program, in a place). Named \
        (doz worker add W NAME --task …) it is a lasting identity of the workspace: when its session ends it is kept, with \
        its memory, and doz worker add W NAME starts it again as itself; doz workspace down W keeps it, and only down \
        --purge or doz worker reset W NAME --yes clears its memory. Unnamed (a name like bot1) it is the run's: it goes \
        when its session ends or its run finishes. A bot (--from-bot NAME) is its own identity, token and skills, kept \
        when it ends. Its chat token is new at each start; the old one is refused.

        It runs in the narrowest place unless you say otherwise: fenced on this Mac by default, in a micro VM of its own \
        (--isolation vm, or when the workspace's or the bot's default is vm), in a running sandbox of the workspace \
        (--sandbox X), or unfenced — acting as you — only with --isolation unfenced. doz worker end ends it.
        """,
        subcommands: [WorkerAdd.self, WorkerList.self, WorkerEndCommand.self, WorkerResetCommand.self])
}

func workerRequest(_ op: HostOp, _ q: WorkerRequest) -> HostRequest {
    var r = HostRequest(op)
    r.workerRequest = q
    return r
}

/// One agent as a list shows it.
func workerTable(_ l: WorkerListing) -> String {
    if l.agents.isEmpty { return "\(l.workspace): no agents yet — doz worker add \(l.workspace) --task \"…\"\n" }
    var t = [["NAME", "ROLE", "LIFETIME", "BOT", "PLACE", "ISOLATION", "CONTROL", "NETWORK", "STATE", "TASK"]]
    for a in l.agents {
        t.append([a.name, a.role, a.lifetime ?? "—", a.bot ?? "—", a.place, a.isolation ?? "—", a.control, a.network,
                  a.declared == true ? "declared (the start starts it)"
                      : a.state == "not started" || a.state == "starting" || a.state == "ended" ? a.state : Out.phaseLabel(a.state),
                  a.task.map { WorkerLaunch.shortTask($0) } ?? "—"])
    }
    var s = Out.table(t)
    let shared = Set(l.agents.compactMap(\.shares)).sorted()
    for x in shared { s += "shares \(x): workers there can read each other's placeholders\n" }
    s += keptIdentitiesText(l.identities ?? [], workspace: l.workspace)
    return s
}

/// 776: the lasting identities with no session now — kept, with their memory — as a person reads them.
func keptIdentitiesText(_ ids: [WorkspaceIdentityRow], workspace: String) -> String {
    let kept = ids.filter { !$0.hasSession }
    guard !kept.isEmpty else { return "" }
    var s = "kept with no session (lasting identities):\n"
    for i in kept {
        s += "  \(i.name)  memory: \(identityMemoryWords(i.memory)) — doz worker add \(workspace) \(i.name) --task \"…\" starts it again\n"
    }
    return s
}

/// An identity's kept memory in a few words (never its content).
func identityMemoryWords(_ m: WorkspaceIdentityMemory) -> String {
    m.present ? "\(m.files) file\(m.files == 1 ? "" : "s"), \(ByteCountFormatter.string(fromByteCount: Int64(m.bytes), countStyle: .file))" : "none kept"
}

struct WorkerAdd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "add", abstract: "Bring up a worker in a started workspace, to do one task.",
        discussion: """
        It joins the workspace's room (and the rooms named with --room) and is told its task in START, the file its first \
        prompt says to read; it says in the room that it is up. Dozable posts nothing there. Fenced on this Mac unless you \
        say otherwise; its network is the workspace's default, else locked; it reaches only the chat server's page port of \
        this Mac, and opens no URL and copies to no clipboard. Refused while the workspace is setting up — doz workspace start \
        W first, or declare it when you make the workspace (doz workspace new W --worker TASK). --dry-run shows what it would be — its name, place, control and network, or what would be refused — and \
        the command, adding nothing and starting no daemon. Example: doz worker add demo --task "list the files"
        """)
    @OptionGroup var g: GlobalOptions
    @Argument(help: "The workspace.") var workspace: String
    @Argument(help: "Its name in chat (default: the first free botN; with --from-bot, the bot's).") var name: String?
    @Option(name: .long, help: "What it is to do (its START says it in full).") var task: String
    @Option(name: .long, help: "Its agent program: claude-code (the default) or codex.") var agent: String?
    @Option(name: .long, help: "Where it runs: fenced (the default), vm, or unfenced (it acts as you — only when named).") var isolation: String?
    @Option(name: .long, help: "Run it in this running sandbox of the workspace (an adopted agent's or another worker's), as its own participant.")
    var sandbox: String?
    @Option(name: .long, help: "Its session's name on this Mac (default: WORKSPACE-NAME).") var session: String?
    @Option(name: .long, help: "A new sandbox's CPUs (--isolation vm).") var cpus: Int?
    @Option(name: .long, help: "A new sandbox's memory, like 2G (--isolation vm).") var memory: String?
    @Option(name: .customLong("from-bot"), help: "The Agent / Bot it is: its name, token, skills and instructions (doz bot ls).") var fromBot: String?
    @Option(name: .customLong("room"), help: "Also invite it to this room of the workspace, by its label (repeatable).") var rooms: [String] = []
    @Option(name: .customLong("allow-tool"), help: "One more tool a fenced Claude Code worker may use without asking, like Edit (repeatable).")
    var allowTools: [String] = []
    @Option(name: .customLong("permissions"), help: "standard (the default) or bypass: its own command line bypasses its permissions, marked wherever it shows.")
    var permissions: String?
    @Flag(name: .customLong("dry-run"), help: "Show what would be added, or what would be refused, and the command; add nothing.") var dryRun = false
    @Option(name: .customLong("request-id"), help: "An id of yours for this request: sent again with the same id and arguments, it answers the first answer (\"replayed\": true) and adds nothing again (kept 24 h).")
    var requestID: String?

    /// The request this command sends.
    func request() -> WorkerRequest {
        var q = WorkerRequest(workspace: workspace, name: name)
        q.task = task
        q.agent = agent
        q.isolation = isolation
        q.sandbox = sandbox
        q.session = session
        q.cpus = cpus
        q.memory = memory
        q.fromBot = fromBot
        q.rooms = rooms.isEmpty ? nil : rooms
        q.allowTools = allowTools.isEmpty ? nil : allowTools
        q.permissionMode = permissions
        return q
    }

    func run() async throws {
        let q = request()
        if dryRun {
            let plan = try decode(try await query(workerRequest(.workerPlan, q), g), WorkerPlan.self, g)
            if g.json { Out.json(plan) } else { Out.stdout(Self.planText(plan)) }
            if let p = plan.problem { throw ExitCode(DozableExit.code(for: HostError(HostError.Code(rawValue: p.code) ?? .failed, ""))) }
            return
        }
        var r = workerRequest(.workerAdd, q)
        r.requestID = requestID
        let a = try decode(try call(r, g), WorkerAdded.self, g)
        if g.json { Out.json(a); return }
        let w = a.worker
        let place = a.sandbox.map { "in the sandbox \($0)" + (w.shares != nil ? " (session \(a.session))" : "") } ?? "on this Mac as @mac/\(a.session)"
        let identity = a.identity.map { "  identity \($0.lifetime == "workspace" ? "lasting (kept when its session ends; memory \(identityMemoryWords($0.memory)))" : "the run's (gone when its session ends or its run finishes)")\n" } ?? ""
        Out.stdout("added \(w.name) to \(a.workspace) (\(w.actsAsYou == true ? "unfenced · acts as you" : w.isolation ?? "fenced")) \(place)\n"
                   + "  control  \(w.control)\n  network  \(w.network)\n  task     \(WorkerLaunch.shortTask(w.task ?? ""))\n" + identity
                   + (a.notes ?? []).map { "note: \($0)\n" }.joined() + (a.replayed == true ? replayedNote : ""))
    }

    /// A dry run as a person reads it: the lines, what would be refused, the notes, then the command exactly.
    static func planText(_ p: WorkerPlan) -> String {
        var s = p.lines.map { "  " + $0 + "\n" }.joined()
        if let x = p.problem { s += (s.isEmpty ? "" : "\n") + "It cannot be added: \(x.text)\n" }
        for n in p.notes { s += "note: \(n)\n" }
        s += "\nThe command:\n" + p.command + "\n"
        return s
    }
}

struct WorkerList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ls", abstract: "Every agent of a workspace: where it runs, what isolates it, its state and task.")
    @OptionGroup var g: GlobalOptions
    @Argument(help: "The workspace.") var workspace: String
    @Flag(name: .long, help: "The ended workers too.") var all = false
    func run() async throws {
        var q = WorkerRequest(workspace: workspace)
        q.all = all ? true : nil
        let l = try decode(try await query(workerRequest(.workerList, q), g), WorkerListing.self, g)
        if g.json { Out.json(l); return }
        Out.stdout(workerTable(l))
    }
}

struct WorkerEndCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "end", abstract: "End a worker's session: the run's identity goes with it; a lasting one is kept.",
        discussion: """
        Its session ends. A run-owned worker (added with no name) goes with it: it leaves every room and its token is \
        refused from now on (its messages keep its name); its name is free again. A lasting one (added with a name) is \
        kept — an identity of the workspace, a member of its rooms, with its memory — and its token is no longer held by \
        anything; doz worker add W NAME --task … starts it again as itself, with a new token. A bot's token is kept and \
        it stays in the room. Its session's record (or its own sandbox, stopped, with its disk) is kept unless --rm. In a \
        sandbox it shares, only its session ends.
        """)
    @OptionGroup var g: GlobalOptions
    @Argument(help: "The workspace.") var workspace: String
    @Argument(help: "The worker.") var name: String
    @Flag(name: .long, help: "Delete its place too: its session's record, or its own sandbox.") var rm = false
    func run() async throws {
        var q = WorkerRequest(workspace: workspace, name: name)
        q.rm = rm ? true : nil
        let e = try decode(try call(workerRequest(.workerEnd, q), g), WorkerEnded.self, g)
        if g.json { Out.json(e); return }
        Out.stdout("ended \(e.name) in \(e.workspace)\(e.removed ? "; its place is deleted" : "")\n" + (e.notes ?? []).map { "note: \($0)\n" }.joined())
    }
}

/// 776: `doz worker reset W NAME --yes` — a lasting identity's kept memory cleared. The only way it goes but `down --purge`.
struct WorkerResetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "reset", abstract: "Clear a lasting identity's kept memory (its next session starts with none).",
        discussion: """
        A lasting identity's memory — what Dozable keeps of its fenced sessions' memory, in the store — is cleared; nothing \
        else (never your folders, its transcripts, an unfenced session's own agent folder or a sandbox's disk). Refused \
        while its session runs: doz workspace stop W (or doz worker end W NAME) first. Asks first (--yes skips).
        """)
    @OptionGroup var g: GlobalOptions
    @Argument(help: "The workspace.") var workspace: String
    @Argument(help: "The identity.") var name: String
    @Flag(name: .long, help: "Do not ask.") var yes = false
    func run() async throws {
        try confirm("Clear \(name)'s kept memory in \(workspace)? It cannot be undone.", yes: yes, g,
                    fix: ["doz", "worker", "reset", workspace, name, "--yes"] + (g.json ? ["--json"] : []))
        let e = try decode(try call(workerRequest(.workerReset, WorkerRequest(workspace: workspace, name: name)), g), WorkerEnded.self, g)
        if g.json { Out.json(e); return }
        Out.stdout((e.notes ?? []).map { $0 + "\n" }.joined())
    }
}
