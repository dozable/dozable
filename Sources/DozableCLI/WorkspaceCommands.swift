import ArgumentParser
import Foundation
import DozableHost

// `doz workspace …`: workspaces — each an environment set up for getting work done: its agents, its rooms, the brief and
// any folders it works on. Looking (ls, show, log) answers from the store when no daemon runs and never starts one;
// changes go through the daemon (the store's one writer; rooms need the chat server it runs). Exit codes as everywhere:
// 2 not found · 3 not in this state · 4 already exists or already in a workspace · 6 the daemon or chat unavailable · 64 usage.

struct WorkspaceCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "workspace",
        abstract: "Workspaces: environments set up for getting work done — agents, rooms, a brief and any folders.",
        discussion: """
        A workspace is an environment set up for getting work done: its agents, its rooms, the brief that says what the \
        work is for, and any folders it works on (usually projects). Work starts only once it is fully set up.

        Today's sandboxes and sessions on this Mac are loose agents until you adopt them; adopting writes only the \
        workspace's own record. With chat on, a new workspace gets a room of its own name (nothing is posted in it yet).

        A bot can manage it (--manager BOT): doz workspace start runs the set-up check, posts the brief as your first \
        message in its room, and starts the manager — fenced on this Mac by default, in a micro VM, or unfenced (acting as \
        you) only when you say so. doz workspace stop ends the manager and keeps its conversation.

        Its lifecycle — sleep, wake, finish, reopen, archive, restore, delete — shows what it would do to each agent first \
        (--dry-run stops there), then asks: a yes for finish, the name typed for archive and delete. Nothing on disk is \
        removed without its flag.
        """,
        subcommands: [WorkspaceNew.self, WorkspaceList.self, WorkspaceShow.self, WorkspaceStart.self, WorkspaceStop.self, WorkspaceSleep.self,
                      WorkspaceWake.self, WorkspaceFinish.self, WorkspaceReopen.self, WorkspaceArchive.self, WorkspaceRestore.self, WorkspaceDelete.self,
                      WorkspaceAdopt.self, WorkspaceRelease.self, WorkspaceEdit.self, WorkspaceLog.self, WorkspaceRunsCommand.self, WorkspaceRename.self])
}

// MARK: helpers

/// `DIR[:ro|:rw]` → an absolute, resolved folder and its mode.
func workspaceFolder(_ s: String, _ g: GlobalOptions) throws -> WorkspaceFolder {
    var path = s, mode = "rw"
    for m in WorkspaceFolder.modes where s.hasSuffix(":" + m) { path = String(s.dropLast(m.count + 1)); mode = m }
    guard !path.isEmpty else { throw fail(HostError(.invalid, "\(s): which folder?"), g) }
    return WorkspaceFolder(path: workspaceAbsolute(path), mode: mode)
}

func workspaceAbsolute(_ p: String) -> String {
    let expanded = (p as NSString).expandingTildeInPath
    let abs = expanded.hasPrefix("/") ? expanded : FileManager.default.currentDirectoryPath + "/" + expanded
    return WorkspaceStore.resolved(URL(fileURLWithPath: abs).standardizedFileURL.path)
}

/// A reference: an http(s) address as it is, else an absolute path.
func workspaceRef(_ s: String) -> String {
    s.hasPrefix("http://") || s.hasPrefix("https://") ? s : workspaceAbsolute(s)
}

/// The brief from a file, or standard input with `-`.
func workspaceBrief(_ file: String, _ g: GlobalOptions) throws -> String {
    let d: Data
    if file == "-" {
        d = FileHandle.standardInput.readDataToEndOfFile()
    } else {
        guard let x = FileManager.default.contents(atPath: workspaceAbsolute(file)) else {
            throw fail(HostError(.notFound, "cannot read \(file)"), g)
        }
        d = x
    }
    guard d.count <= WorkspaceStore.maximumBriefBytes else {
        throw fail(HostError(.invalid, "the brief is \(d.count) bytes — at most \(WorkspaceStore.maximumBriefBytes >> 10) KiB"), g)
    }
    guard let text = String(data: d, encoding: .utf8) else { throw fail(HostError(.invalid, "the brief is not UTF-8 text"), g) }
    return text
}

func workspaceRequest(_ op: HostOp, _ w: WorkspaceRequest) -> HostRequest {
    var r = HostRequest(op)
    r.workspaceRequest = w
    return r
}

func stateWords(_ raw: String) -> String { WorkspaceState(rawValue: raw)?.words ?? raw }

/// The workspace as a person reads it.
func printWorkspace(_ d: WorkspaceDetail) {
    var s = "\(d.name) — \(stateWords(d.state)) · \(d.driver)\n"
    let refs = d.brief.refs.count
    s += "  brief    \(d.brief.bytes) bytes" + (refs == 0 ? "" : ", \(refs) reference\(refs == 1 ? "" : "s")") + "\n"
    for r in d.brief.refs { s += "             \(r.hasPrefix("/") ? DisplayPath.tilde(r) : r)\n" }
    if d.folders.isEmpty { s += "  folders  none\n" }
    for (i, f) in d.folders.enumerated() {
        s += (i == 0 ? "  folders  " : "           ") + DisplayPath.tilde(f.path) + " (" + (f.main ? "main, " : "") + (f.mode == "ro" ? "read-only" : "read-write") + ")\n"
    }
    s += "  room     " + (d.rooms.first { $0.main }.map { "#" + $0.chatRoom } ?? "none") + "\n"
    if d.agents.isEmpty { s += "  agents   none yet — doz workspace adopt \(d.name) SANDBOX|@mac/SESSION\n" }
    for (i, a) in d.agents.enumerated() {
        let place = a.place == a.name ? "" : " in \(a.place)"
        var what = a.role
        if let iso = a.isolation { what += ", " + iso + (a.actsAsYou == true ? " · acts as you" : "") }
        s += (i == 0 ? "  agents   " : "           ") + "\(a.name) (\(what)\(place), \(a.state == "not started" ? "not started" : Out.phaseLabel(a.state)))\n"
    }
    if let o = d.origin.project { s += "  from     \(DisplayPath.tilde(o))\n" }
    if let gaps = d.gaps, !gaps.isEmpty {
        s += "  to start " + gaps.map { $0.line }.joined(separator: "\n           ") + "\n"
    }
    for n in d.notes ?? [] { s += "note: \(n)\n" }
    Out.stdout(s)
}

// MARK: commands

struct WorkspaceNew: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "new", abstract: "Make a workspace: its brief, any folders, its room and agents to adopt.",
        discussion: """
        The first --folder is the main one (--new-folder makes ~/doz-workspaces/NAME and puts it first). With chat on, the \
        room is named after the workspace (it must not exist yet — or link one with --room). --dry-run shows what would be \
        made, every refusal and what the start would still need, and the commands — nothing is written and no daemon is \
        started. --start starts it once it is made. Example: doz workspace new demo --prompt-file brief.md --folder ~/code/demo
        """)
    @OptionGroup var g: GlobalOptions
    @Argument(help: "Its name: 1–40 characters of a-z, 0-9 and -.") var name: String
    @Option(name: .customLong("prompt-file"), help: "The brief: a file (at most 256 KiB), or - for standard input.") var promptFile: String
    @Option(name: .customLong("ref"), help: "A reference for the brief: a path or an http(s) address (repeatable).") var refs: [String] = []
    @Option(name: .customLong("folder"), help: "A folder it works on, DIR or DIR:ro (repeatable; the first is the main one).") var folders: [String] = []
    @Flag(name: .customLong("new-folder"), help: "Make the empty folder ~/doz-workspaces/NAME (defaults.projects_dir) and use it as the main folder.")
    var newFolder = false
    @Option(name: .long, help: "Link this existing room in the chat server as its room, instead of making one (nothing is posted).") var room: String?
    @Flag(name: .customLong("no-room"), help: "No room, even with chat on.") var noRoom = false
    @Flag(name: .customLong("from-project"), help: "Fill in its network preset from the project file (doz_project.yaml) in the main folder (never written).")
    var fromProject = false
    @Option(name: .customLong("adopt"), help: "Adopt this sandbox or @mac/SESSION at once (repeatable).") var adopt: [String] = []
    @Option(name: .customLong("manager"), help: "The bot that manages it (doz bot ls); started by doz workspace start.") var manager: String?
    @Option(name: .customLong("manager-isolation"), help: "Where the manager runs: fenced (the default), vm, or unfenced (it acts as you — only when named).")
    var managerIsolation: String?
    @Option(name: .customLong("worker-isolation"), help: "Where its new workers run by default: fenced (the default) or vm — never unfenced by default.")
    var workerIsolation: String?
    @Option(name: .long, help: "Its network preset: locked (the default), standard or open; the room is always added.") var network: String?
    @Flag(name: .customLong("dry-run"), help: "Show what would be made, what is refused and what the start would still need, and the commands; make nothing.")
    var dryRun = false
    @Flag(name: .long, help: "Start it once it is made (doz workspace start NAME).") var start = false

    func validate() throws {
        if let i = workerIsolation, !(WorkspaceNetworks.workerIsolations + ["unfenced"]).contains(i) {
            throw ValidationError("--worker-isolation is vm or fenced")
        }
        if let n = network, !WorkspaceNetworks.presets.contains(n) { throw ValidationError("--network is locked, standard or open") }
    }

    /// The request this command sends, with `brief` as its brief (`run` reads it from the file or standard input).
    func request(brief: String, parse: WorkspaceProjectFill.Parser = { try DozableProject.parse($0, file: $1) }) throws -> WorkspaceRequest {
        var w = WorkspaceRequest(name: name)
        w.manager = manager
        w.managerIsolation = managerIsolation
        w.workerIsolation = workerIsolation
        w.network = network
        w.brief = brief
        w.folders = try folders.map { try workspaceFolder($0, g) }
        w.newFolder = newFolder ? true : nil
        w.refs = refs.map(workspaceRef)
        w.room = room
        w.noRoom = noRoom ? true : nil
        w.adopt = adopt.isEmpty ? nil : adopt
        if fromProject {
            do { try WorkspaceProjectFill.apply(&w, parse: parse) } catch { throw fail(HostError.from(error), g) }
        }
        return w
    }

    func run() async throws {
        let w = try request(brief: try workspaceBrief(promptFile, g))
        if dryRun {
            let plan = try decode(try await query(workspaceRequest(.workspacePlan, w), g), WorkspacePlan.self, g)
            if g.json { Out.json(plan) } else { printPlan(plan) }
            if let c = plan.refusalCode { throw ExitCode(DozableExit.code(for: HostError(HostError.Code(rawValue: c) ?? .failed, ""))) }
            return
        }
        let d = try decode(try call(workspaceRequest(.workspaceNew, w), g), WorkspaceDetail.self, g)
        guard start else {
            if g.json { Out.json(d); return }
            printWorkspace(d)
            return
        }
        // Sugar: two requests, as the dashboard's Create and start — a refused start leaves it made, setting up.
        if !g.json { printWorkspace(d) }
        let s = try decode(try call(workspaceRequest(.workspaceStart, WorkspaceRequest(name: name)), g), WorkspaceStarted.self, g)
        if g.json { Out.json(s); return }
        printStarted(s)
    }

    func printPlan(_ p: WorkspacePlan) {
        var s = p.lines.map { "  " + $0 + "\n" }.joined()
        if !p.refusals.isEmpty { s += "\nIt cannot be made yet:\n" + p.refusals.map { "  - " + $0 + "\n" }.joined() }
        if !p.gaps.isEmpty { s += "\nBefore it can start:\n" + p.gaps.map { "  - " + $0.line + "\n" }.joined() }
        for n in p.notes { s += "note: \(n)\n" }
        s += "\nThe commands:\n" + p.commands + (start ? p.startCommand + "\n" : "")
        Out.stdout(s)
    }
}

/// What a start did, as a person reads it.
func printStarted(_ s: WorkspaceStarted) {
    var t = ""
    if s.kickedOff { t += "posted the brief in #\(s.workspace.rooms.first { $0.main }?.chatRoom ?? s.name) as your first message\n" }
    if let m = s.manager {
        let where_ = s.isolation == "vm" ? "in the sandbox \(s.session ?? "?")" : "on this Mac as @mac/\(s.session ?? "?")"
        t += s.alreadyRunning == true ? "\(m) is running already (\(where_))\n"
            : "started \(m) (\(s.isolation == "unfenced" ? "unfenced · acts as you" : s.isolation ?? "fenced")) \(where_)\n"
    } else {
        t += "no manager: you drive\n"
    }
    Out.stdout(t)
    printWorkspace(s.workspace)
    for n in s.notes ?? [] { Out.stdout("note: \(n)\n") }
}

struct WorkspaceList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ls", abstract: "The workspaces — state, who drives, agents, room — and the loose agents.")
    @OptionGroup var g: GlobalOptions
    @Flag(name: .long, help: "Only the loose agents: the sandboxes and sessions on this Mac not adopted into any workspace.") var loose = false
    func run() async throws {
        var w = WorkspaceRequest()
        w.loose = loose ? true : nil
        let l = try decode(try await query(workspaceRequest(.workspaceList, w), g), WorkspaceListing.self, g)
        if g.json { Out.json(l); return }
        var s = ""
        if !loose {
            if l.workspaces.isEmpty { s += "Workspaces: none yet — doz workspace new NAME --prompt-file FILE\n" } else {
                s += Out.table([["NAME", "STATE", "AGENTS", "ROOM"]] + l.workspaces.map {
                    [$0.name, "\(stateWords($0.state)) · \($0.driver)" + ($0.manager.map { " · manager " + $0.words } ?? ""), String($0.agents),
                     $0.room.map { "#" + $0 } ?? "—"]
                }, rightAligned: [2])
            }
            s += "\n"
        }
        if l.loose.isEmpty { s += "Loose agents: none\n" } else {
            s += "Loose agents\n" + Out.table([["NAME", "KIND", "STATE"]] + l.loose.map {
                [$0.name, $0.kind == "mac" ? "session on this Mac" : "sandbox", Out.phaseLabel($0.state)]
            })
        }
        Out.stdout(s)
    }
}

struct WorkspaceShow: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "show", abstract: "A workspace: its state, brief, folders, room and agents.")
    @OptionGroup var g: GlobalOptions
    @Argument(help: "The workspace.") var name: String
    @Flag(name: .long, help: "Print the brief's text too.") var brief = false
    @Flag(name: .customLong("can-do"), help: "What each agent can do: its isolation and control, folders, network, secrets by name, its room — each live or at the next start.")
    var canDo = false
    @Flag(name: .long, help: "What it can reach and hold: each agent's network, what it was refused lately, this Mac's ports, the secrets held for it (by name) and the accounts used.")
    var network = false
    @Flag(name: .long, help: "Its folders, the files changed in each since the start (looked at without running anything there) and each micro VM agent's restore points.")
    var folders = false
    @Option(name: .long, help: "With --can-do or --network: one agent only.") var agent: String?
    func run() async throws {
        if [canDo, network, folders].filter({ $0 }).count > 1 { throw fail(HostError(.invalid, "one of --can-do, --network and --folders"), g) }
        if agent != nil, !canDo, !network { throw fail(HostError(.invalid, "--agent goes with --can-do or --network"), g) }
        var w = WorkspaceRequest(name: name)
        w.withBrief = brief ? true : nil
        let d = try decode(try await query(workspaceRequest(.workspaceShow, w), g), WorkspaceDetail.self, g)
        var reach: WorkspaceReach?, view: WorkspaceFolders?
        if canDo || network {
            var q = WorkspaceRequest(name: name)
            q.agent = agent
            reach = try await workspaceViewAnswer(.workspaceReach, q, WorkspaceReach.self, g)
        }
        if folders { view = try await workspaceViewAnswer(.workspaceFolders, WorkspaceRequest(name: name), WorkspaceFolders.self, g) }
        if g.json {
            if reach == nil && view == nil { Out.json(d) } else { Out.json(WorkspaceShowJSON(detail: d, reach: reach, folders: view)) }
            return
        }
        if let reach {
            Out.stdout("\(d.name) — \(stateWords(d.state)) · \(d.driver)\n\n")
            if canDo { printCanDo(reach) } else { printNetwork(reach) }
            for n in reach.notes ?? [] { Out.stdout("note: \(n)\n") }
            return
        }
        if let view {
            Out.stdout("\(d.name) — \(stateWords(d.state)) · \(d.driver)\n\n")
            printFolders(view)
            return
        }
        printWorkspace(d)
        if let t = d.briefText { Out.stdout("\n" + t + (t.hasSuffix("\n") ? "" : "\n")) }
    }
}

struct WorkspaceAdopt: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "adopt", abstract: "Adopt a sandbox or a session on this Mac into a workspace, as a worker.",
        discussion: "Only the workspace's record changes: the sandbox and the session are left as they are. Each is in one workspace at most.")
    @OptionGroup var g: GlobalOptions
    @Argument(help: "The workspace.") var name: String
    @Argument(help: "A sandbox's name, or @mac/SESSION.") var agent: String
    @Option(name: .customLong("as"), help: "Its name in the workspace (default: the sandbox's or the session's).") var asName: String?
    func run() async throws {
        var w = WorkspaceRequest(name: name)
        w.agent = agent
        w.asName = asName
        let d = try decode(try call(workspaceRequest(.workspaceAdopt, w), g), WorkspaceDetail.self, g)
        if g.json { Out.json(d); return }
        printWorkspace(d)
    }
}

struct WorkspaceRelease: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "release", abstract: "Let an agent go: it is loose again (it keeps running as it was).")
    @OptionGroup var g: GlobalOptions
    @Argument(help: "The workspace.") var name: String
    @Argument(help: "The agent: its name in the workspace, its sandbox, or @mac/SESSION.") var agent: String
    func run() async throws {
        var w = WorkspaceRequest(name: name)
        w.agent = agent
        let d = try decode(try call(workspaceRequest(.workspaceRelease, w), g), WorkspaceDetail.self, g)
        if g.json { Out.json(d); return }
        printWorkspace(d)
    }
}

struct WorkspaceEdit: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "edit", abstract: "Change a workspace's brief, references, folders or manager, or make its room.",
        discussion: "Once the work has started, a new brief is announced in its room as your message (\"I edited the work:\" and the new text); while it is setting up nothing is posted.")
    @OptionGroup var g: GlobalOptions
    @Argument(help: "The workspace.") var name: String
    @Option(name: .customLong("prompt-file"), help: "A new brief: a file, or - for standard input.") var promptFile: String?
    @Option(name: .customLong("add-ref"), help: "Add a reference: a path or an http(s) address (repeatable).") var addRefs: [String] = []
    @Option(name: .customLong("remove-ref"), help: "Remove a reference (repeatable).") var removeRefs: [String] = []
    @Option(name: .customLong("add-folder"), help: "Add a folder, DIR or DIR:ro (repeatable).") var addFolders: [String] = []
    @Option(name: .customLong("remove-folder"), help: "Remove a folder (repeatable).") var removeFolders: [String] = []
    @Flag(name: .customLong("make-room"), help: "Make its room in the chat server now (chat on), named after the workspace.") var makeRoom = false
    @Option(name: .customLong("manager"), help: "Make this bot its manager (replacing any; not while one runs).") var manager: String?
    @Option(name: .customLong("manager-isolation"), help: "Where the manager runs: fenced (the default), vm, or unfenced (it acts as you — only when named).")
    var managerIsolation: String?
    @Flag(name: .customLong("no-manager"), help: "Remove its manager (not while it runs).") var noManager = false
    @Option(name: .customLong("if-brief"), help: "Change it only if the brief is still this one: its sha256 (doz workspace show W --json). Otherwise nothing is written.")
    var ifBrief: String?
    func run() async throws {
        var w = WorkspaceRequest(name: name)
        if let ifBrief {
            guard ifBrief.count == 64, ifBrief.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
                throw fail(HostError(.invalid, "--if-brief: the brief's sha256, 64 lower-case hex digits"), g)
            }
            w.ifBrief = ifBrief
        }
        w.manager = manager
        w.managerIsolation = managerIsolation
        w.noManager = noManager ? true : nil
        if let f = promptFile { w.brief = try workspaceBrief(f, g) }
        w.addRefs = addRefs.isEmpty ? nil : addRefs.map(workspaceRef)
        w.removeRefs = removeRefs.isEmpty ? nil : removeRefs.map(workspaceRef)
        w.addFolders = addFolders.isEmpty ? nil : try addFolders.map { try workspaceFolder($0, g) }
        w.removeFolders = removeFolders.isEmpty ? nil : removeFolders.map(workspaceAbsolute)
        w.makeRoom = makeRoom ? true : nil
        let d = try decode(try call(workspaceRequest(.workspaceEdit, w), g), WorkspaceDetail.self, g)
        if g.json { Out.json(d); return }
        printWorkspace(d)
    }
}

struct WorkspaceStart: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "start", abstract: "Start the work: the set-up check, the brief posted, the manager started.",
        discussion: """
        Refused, listing every gap and its fix, until it is fully set up: the brief, its room (with chat on), its folders, \
        each agent's place, and its manager's bot (its token held here, polling, its program known). Then the bot is invited \
        to the room, the brief is posted as your first message — once: a start after a stop never posts it again — and the \
        manager is started. For now a bot runs in one live workspace at a time.
        """)
    @OptionGroup var g: GlobalOptions
    @Argument(help: "The workspace.") var name: String
    func run() async throws {
        let s = try decode(try call(workspaceRequest(.workspaceStart, WorkspaceRequest(name: name)), g), WorkspaceStarted.self, g)
        if g.json { Out.json(s); return }
        printStarted(s)
    }
}

struct WorkspaceStop: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "stop", abstract: "Stop its manager; its conversation, record and room are kept.",
        discussion: "Nothing is posted. doz workspace start wakes it again (the brief is not posted twice). Nothing running: said, and exit 0.")
    @OptionGroup var g: GlobalOptions
    @Argument(help: "The workspace.") var name: String
    func run() async throws {
        let s = try decode(try call(workspaceRequest(.workspaceStop, WorkspaceRequest(name: name)), g), WorkspaceStopped.self, g)
        if g.json { Out.json(s); return }
        if !s.stopped { Out.stdout((s.notes?.first ?? "nothing to stop") + "\n"); return }
        printWorkspace(s.workspace)
        for n in s.notes ?? [] { Out.stdout("note: \(n)\n") }
    }
}

struct WorkspaceLog: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "log", abstract: "What happened to a workspace, and who did it.")
    @OptionGroup var g: GlobalOptions
    @Argument(help: "The workspace.") var name: String
    @Option(name: .long, help: "Only since then: a time (2026-11-19T09:00:00Z) or an age (30m, 2h, 3d).") var since: String?
    @Option(name: .long, help: "One page, newest first: at most N lines (1–500).") var limit: Int?
    @Option(name: .long, help: "The page before this one: the `first` of the page you have (--json).") var before: Int?
    func run() async throws {
        var w = WorkspaceRequest(name: name)
        if let since {
            guard let d = WorkspaceStore.since(since) else { throw fail(HostError(.invalid, "--since \(since): a time (ISO 8601) or an age like 30m, 2h, 3d"), g) }
            w.since = d
        }
        if limit != nil || before != nil {
            if since != nil { throw fail(HostError(.invalid, "--since does not go with --limit or --before"), g) }
            if let limit, !(1...WorkspaceLogPage.maximumLimit).contains(limit) { throw fail(HostError(.invalid, "--limit: 1–\(WorkspaceLogPage.maximumLimit) lines"), g) }
            if let before, before < 0 { throw fail(HostError(.invalid, "--before: the first of an earlier page"), g) }
            w.limit = limit
            w.before = before
            let page = try await workspaceViewAnswer(.workspaceLog, w, WorkspaceLogPage.self, g)
            if g.json { Out.json(page); return }
            Out.stdout(Self.lines(page.entries.reversed()) ?? "nothing logged before then\n")
            if page.more, let first = page.first { Out.stdout("older: doz workspace log \(name) --limit \(limit ?? WorkspaceLogPage.defaultLimit) --before \(first)\n") }
            return
        }
        let entries = try decode(try await query(workspaceRequest(.workspaceLog, w), g), [WorkspaceLogEntry].self, g)
        if g.json { Out.json(entries); return }
        Out.stdout(Self.lines(entries) ?? "nothing logged\(since == nil ? "" : " since then")\n")
    }

    static func lines(_ entries: [WorkspaceLogEntry]) -> String? {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var s = ""
        for e in entries { s += "\(f.string(from: e.at))  \(e.by.padding(toLength: 3, withPad: " ", startingAt: 0))  \(e.sentence)\n" }
        return s.isEmpty ? nil : s
    }
}

struct WorkspaceRename: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rename", abstract: "Give a workspace another name (its room keeps its own).")
    @OptionGroup var g: GlobalOptions
    @Argument(help: "The workspace.") var name: String
    @Argument(help: "Its new name: 1–40 characters of a-z, 0-9 and -.") var newName: String
    func run() async throws {
        var w = WorkspaceRequest(name: name)
        w.newName = newName
        let d = try decode(try call(workspaceRequest(.workspaceRename, w), g), WorkspaceDetail.self, g)
        if g.json { Out.json(d); return }
        printWorkspace(d)
    }
}
