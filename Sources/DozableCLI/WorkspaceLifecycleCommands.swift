import ArgumentParser
import Darwin
import Foundation
import DozableHost

// `doz workspace stop | sleep | wake | finish | down | reopen | archive | restore | delete`: check, then ask. Each looks first —
// `workspace-lifecycle-plan`, answered from the store when no daemon runs — and prints what it would do to each agent,
// what is kept and what goes; `--dry-run` stops there (writing nothing, starting no daemon). Then it asks: nothing for
// sleep, wake, reopen and restore; a [y/N] for stop and finish; the workspace's name typed on the terminal for archive and
// delete. `down` IS finish (`runWorkspaceFinish`): a workspace a space file made goes down by its file's plan (what it made for
// the run removed, each after its archived copy verifies), any other finishes; both answer `WorkspaceFinish` with what they
// removed and what they kept.
// `--yes` skips the question; no terminal (or --json) and no --yes: nothing is done, exit 5. The verb carries the plan's
// sha (`ifPlan`): a workspace that changed since it looked is refused, exit 3. Nothing on disk is removed without its flag:
// a sandbox's disk only with --remove-sandboxes, folders only to the Bin with --bin-folders.

/// What the seven verbs share.
struct LifecycleArguments: ParsableArguments {
    @OptionGroup var g: GlobalOptions
    @Argument(help: "The workspace.") var name: String
    @Flag(name: .customLong("dry-run"), help: "Show what it would do to each agent, what is kept and what goes; do nothing, start no daemon.")
    var dryRun = false
    @Flag(name: .shortAndLong, help: "Do not ask (needed with no terminal, and with --json).") var yes = false
    @Option(name: .customLong("if-plan"), help: "Act only on this plan (its sha, from --dry-run --json): refused, exit 3, if the workspace changed since.")
    var ifPlan: String?
}

/// The archive's and the delete's sandboxes.
struct LifecycleSandboxFlags: ParsableArguments {
    @Flag(name: .customLong("remove-sandboxes"), help: "Also remove the sandboxes Dozable made for it (a manager's or a worker's own; never an adopted one) — each one's disk saved as an image first (doz image ls).")
    var removeSandboxes = false
    @Flag(name: .customLong("keep-templates"), inversion: .prefixedNo, help: "With --remove-sandboxes: save each sandbox's disk as an image first (doz image save).")
    var keepTemplates = true
}

/// Run `verb` on `a.name`: look, print, ask, act.
func runWorkspaceLifecycle(_ verb: WorkspaceVerb, _ a: LifecycleArguments, edit: (inout WorkspaceRequest) -> Void = { _ in }) async throws {
    try await runWorkspaceLifecycle(verb, name: a.name, dryRun: a.dryRun, yes: a.yes, ifPlan: a.ifPlan, a.g, word: verb.rawValue, edit: edit)
}

/// The same, from its parts (`word`: the command as typed — `down` is finish's twin).
func runWorkspaceLifecycle(_ verb: WorkspaceVerb, name: String, dryRun: Bool, yes: Bool, ifPlan: String?, _ g: GlobalOptions, word: String,
                           edit: (inout WorkspaceRequest) -> Void = { _ in }) async throws {
    struct A { var name: String; var dryRun: Bool; var yes: Bool; var ifPlan: String? }
    let a = A(name: name, dryRun: dryRun, yes: yes, ifPlan: ifPlan)
    var w = WorkspaceRequest(name: a.name)
    w.verb = verb.rawValue
    edit(&w)
    let plan = try decode(try await query(workspaceRequest(.workspaceLifecyclePlan, w), g), WorkspaceLifecyclePlan.self, g)
    let refusal = plan.refusals.first.map { HostError(HostError.Code(rawValue: plan.refusalCode ?? "") ?? .invalidPhase, $0) }
    if a.dryRun {
        if g.json { Out.json(plan) } else { Out.stdout(workspaceLifecycleText(plan)) }
        if let refusal { throw ExitCode(DozableExit.code(for: refusal)) }
        return
    }
    if !g.json { Out.stdout(workspaceLifecycleText(plan, commands: false)) }
    if let refusal { throw fail(refusal, g) }
    // The command again with --yes: what a question nobody could answer says to run.
    let fix = ["doz", "workspace", word, a.name, "--yes"] + (g.json ? ["--json"] : [])
    switch verb.confirm {
    case .none: break
    case .yes:
        // A stop with nothing running asks nothing: it does nothing.
        if verb == .stop && plan.queue.changes == 0 { break }
        if g.json && !a.yes { throw fail(HostError(.needsConfirmation, "\(word) \(a.name) asks first — --json asks nothing: pass --yes"), g, fix: fix) }
        try confirm("\(capitalised(word)) \(a.name)?", yes: a.yes, g, fix: fix)
    case .typed:
        try confirmTypedName(a.name, verb: verb.rawValue, yes: a.yes, g)
    }
    w.ifPlan = a.ifPlan ?? plan.sha
    w.verb = nil
    let r = try call(workspaceRequest(verb.hostOp, w), g)
    let c = try decode(r, WorkspaceChanged.self, g)
    // The verb did everything, but its run's archive could not be written: said, and exit 1.
    let archiveFailed = c.archiveProblem.map { HostError(.failed, "\(c.name) is \(verb == .archive ? "archived" : "finished"), but run \(c.run ?? "?")'s archive was not written: \($0) — doz workspace runs \(c.name) --archive \(c.run ?? "RUN") writes it again") }
    if g.json {
        Out.json(c)
        if archiveFailed != nil { throw ExitCode(DozableExit.failed) }
        return
    }
    var out = ""
    for x in c.results { out += "  \(x.name): \(x.text)\n" }
    if let b = c.binned { for p in b { out += "  moved to the Bin: \(DisplayPath.tilde(p))\n" } }
    out += lifecycleDone(verb, c) + "\n"
    // A finish always says what it removed and what it kept (a workspace made without a space file is standing).
    if verb == .finish, let kept = c.kept {
        for l in WorkspaceFinishInventory.lines(removed: c.removed ?? [], kept: kept, standing: true, archive: nil) { out += "  \(l)\n" }
    }
    for n in c.notes ?? [] { out += "note: \(n)\n" }
    Out.stdout(out)
    if let archiveFailed { throw fail(archiveFailed, g) }
}

/// Finish's and archive's evidence archive.
struct LifecycleArchiveFlag: ParsableArguments {
    @Flag(name: .customLong("no-archive"), help: "Write no evidence archive of the run (its messages, conversations, screens, usage and timesheet).")
    var noArchive = false
}

func capitalised(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }

func lifecycleDone(_ verb: WorkspaceVerb, _ c: WorkspaceChanged) -> String {
    switch verb {
    case .stop: c.results.isEmpty ? "\(c.name): nothing runs — nothing to stop" : "\(c.name) is stopped: every agent's process ended, nothing removed"
    case .sleep: "\(c.name) is asleep"
    case .wake: "\(c.name) is awake — \(c.workspace?.state.replacingOccurrences(of: "-", with: " ") ?? "running")"
    case .finish: "\(c.name) is finished"
    case .reopen: "\(c.name) is reopened (asleep until you wake it)"
    case .archive: "\(c.name) is archived"
    case .restore: "\(c.name) is restored (finished)"
    case .delete: "\(c.name) is deleted"
    }
}

/// The name typed on the terminal (never stdin, which may carry data). No terminal, or --json, and no --yes: refused.
func confirmTypedName(_ name: String, verb: String, yes: Bool, _ g: GlobalOptions) throws {
    if yes { return }
    if g.json { throw fail(HostError(.needsConfirmation, "\(verb) \(name) asks for its name to be typed — --json asks nothing: pass --yes"), g) }
    let fd = open("/dev/tty", O_RDWR)
    guard fd >= 0 else {
        throw fail(HostError(.needsConfirmation, "\(verb) \(name) asks for its name to be typed — there is no terminal to ask; pass --yes"), g)
    }
    defer { close(fd) }
    let prompt = "Type \(name) to \(verb) it: "
    _ = prompt.withCString { write(fd, $0, strlen($0)) }
    var buf = [UInt8](repeating: 0, count: 128)
    let n = read(fd, &buf, buf.count)
    let answer = n > 0 ? String(decoding: buf[0..<n], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) : ""
    guard answer == name else { throw fail(HostError(.needsConfirmation, "not confirmed — nothing done"), g) }
}

/// A plan as a person reads it: the table (agent · role · where · now → after · back), what is kept and what goes (with
/// sizes), the queue, what would be refused, the notes, and the commands.
func workspaceLifecycleText(_ p: WorkspaceLifecyclePlan, commands: Bool = true) -> String {
    var s = "\(capitalised(p.verb)) \(p.workspace)? — \(p.state.replacingOccurrences(of: "-", with: " ")) now\n"
    if p.rows.isEmpty {
        s += "  no agents\n"
    } else {
        var t = [["AGENT", "ROLE", "WHERE", "NOW", "AFTER", "BACK"]]
        for r in p.rows {
            let iso = r.isolation == "vm" ? "micro VM" : r.isolation == "unfenced" ? "unfenced · acts as you" : r.isolation
            t.append([r.name, r.role, "\(r.place) (\(iso))", r.now + (r.activity.map { " · \($0)" } ?? ""), r.after, r.back])
        }
        s += Out.table(t)
    }
    if !p.keeps.isEmpty { s += "Kept:\n" + p.keeps.map { "  " + lifecycleItem($0) + "\n" }.joined() }
    if !p.goes.isEmpty { s += "Goes:\n" + p.goes.map { "  " + lifecycleItem($0) + "\n" }.joined() }
    if let rooms = p.rooms, !rooms.isEmpty {
        s += "Rooms:\n" + rooms.map { "  #\($0.room) → \($0.after)\n" }.joined()
    }
    if let a = p.archive, !a.off {
        s += "The run's archive" + (a.run.map { " (run \($0))" } ?? "") + (a.path.map { ": the store's \($0)" } ?? "") + "\n"
        for r in a.rooms { s += "  #\(r.room): " + (r.messages.map { "\($0) message\($0 == 1 ? "" : "s")" } ?? "its messages") + "\n" }
        for t in a.transcripts {
            let from = t.source == "sandbox" ? "copied out of its sandbox before it shuts down" : t.source == "fenced" ? "a fenced session's" : "an unfenced session's"
            s += "  \(t.agent)'s conversations: " + (t.files.map { "\($0) file\($0 == 1 ? "" : "s"), " } ?? "") + from + "\n"
        }
        if !a.screens.isEmpty { s += "  last screens: \(a.screens.joined(separator: ", "))\n" }
        s += "  usage and a timesheet" + (a.estimateBytes.map { "; about \(DozableImages.formatBytes($0))" } ?? "") + "\n"
    }
    if let q = p.queue.note { s += "note: \(q)\n" }
    if !p.refusals.isEmpty { s += "It cannot be done:\n" + p.refusals.map { "  - \($0)\n" }.joined() }
    for n in p.notes { s += "note: \(n)\n" }
    if commands {
        s += "\nThe command:\n\(p.command)\n"
        if !p.commands.isEmpty { s += "\nToday, one agent at a time:\n" + p.commands.joined(separator: "\n") + "\n" }
    }
    return s
}

func lifecycleItem(_ i: WorkspaceLifecycleItem) -> String {
    var t = i.text
    if let p = i.path { t = DisplayPath.tilde(p) + " — " + t }
    if let b = i.bytes, b > 0 { t += " (" + DozableImages.formatBytes(b) + ")" }
    return t
}

struct WorkspaceSleep: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "sleep", abstract: "Put every agent to sleep: a sandbox hibernated, a session on this Mac ended with its conversation kept.",
        discussion: """
        A micro VM hibernates — its memory given back, its programs and screens kept; a session on this Mac ends, its record \
        and conversation kept (an unfenced one's token file deleted). An agent elsewhere runs on its own machine: untouched. \
        It stays asleep until you wake it: doz workspace wake W. Messages wait in the room.
        """)
    @OptionGroup var a: LifecycleArguments
    func run() async throws { try await runWorkspaceLifecycle(.sleep, a) }
}

struct WorkspaceWake: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "wake", abstract: "Wake every agent it put to sleep: the same sandboxes, the same conversations.",
        discussion: """
        A hibernated sandbox wakes with the same programs and screens; one shut down boots again and its agent continues its \
        conversation. A session on this Mac opens again in the same conversation (a program with none starts fresh). The \
        manager comes back as doz workspace start brings it; the brief is never posted again.
        """)
    @OptionGroup var a: LifecycleArguments
    func run() async throws { try await runWorkspaceLifecycle(.wake, a) }
}

struct WorkspaceFinish: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "finish", abstract: "The work is done: everything stops; the run is archived; it says what it removed and what it kept.",
        discussion: """
        Every sandbox shut down (its disk kept), every session ended (its conversation kept). The run closes and its \
        evidence is archived in Dozable's store: its messages, each agent's conversations and last screen, the usage and a \
        timesheet (--no-archive writes none). Every token is kept, so doz workspace reopen W, then wake, works on it again. \
        No worker can be added while it is finished. doz workspace down W is the same command.

        What it removes depends on the workspace's lifetime. A workspace made without a space file, or by one that says \
        x-dozable.lifetime: standing, is standing: finish removes nothing, its scratch folders included ("finished; nothing \
        removed (standing)"), but what says x-dozable.lifetime: run itself — archived and hash-checked first. A space file \
        with lifetime runs (the default for one that says none) removes what it made for the run, each after its archived \
        copy verifies; nothing content-bearing goes when the archive failed. External folders are never touched. --json \
        answers {kind: WorkspaceFinish, schema: 1, removed, kept, archive, …}: folders by their absolute path, rooms \
        room/NAME, agents agent/NAME, sandboxes sandbox/NAME. Asks first (--yes skips; no terminal and no --yes: exit 5 with \
        the command to run as fix). If the archive cannot be written, everything else is still done and it exits 1: doz \
        workspace runs W --archive RUN writes it again.
        """)
    @OptionGroup var a: LifecycleArguments
    @OptionGroup var x: LifecycleArchiveFlag
    func run() async throws {
        try await runWorkspaceFinish(name: a.name, purge: false, noArchive: x.noArchive, yes: a.yes, dryRun: a.dryRun, ifPlan: a.ifPlan, word: "finish", a.g)
    }
}

/// `doz workspace stop W`: every agent's process ends — a sandbox shut down (its disk kept), a session on this Mac ended (its
/// conversation kept). Nothing is removed; wake brings them back. The manager alone: `doz workspace manager stop W`.
struct WorkspaceStop: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "stop", abstract: "Stop everything: every agent's process ends; conversations, disks, rooms and folders are kept.",
        discussion: """
        Every agent that runs is stopped: a micro VM shut down (its disk kept), a session on this Mac ended (its record and \
        conversation kept; an unfenced one's token file deleted). Unlike sleep nothing is held in memory: each agent is \
        stopped, not asleep. What is asleep or stopped already is left as it is, so a stop of a stopped or asleep workspace \
        does nothing and exits 0. Nothing is removed. doz workspace wake W brings every agent back in its conversation. Shows \
        its plan, then asks (--yes skips; no terminal and no --yes: exit 5 with the command to run as fix). The manager \
        alone, as stop used to do: doz workspace manager stop W.
        """)
    @OptionGroup var a: LifecycleArguments
    func run() async throws {
        if !a.g.quiet { Out.stderr(Self.notice(a.name)) }
        try await runWorkspaceLifecycle(.stop, a)
    }
    /// The one line that says what changed (stderr: the answer on stdout stays as it is).
    static func notice(_ n: String) -> String {
        "doz: note: workspace stop now stops every agent; for the manager alone: doz workspace manager stop \(n)\n"
    }
}

/// `doz workspace manager …`: the manager alone.
struct WorkspaceManagerCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "manager", abstract: "The workspace's manager alone.",
        subcommands: [WorkspaceManagerStop.self])
}

struct WorkspaceManagerStop: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "stop", abstract: "Stop its manager alone; its conversation, record and room are kept.",
        discussion: "Nothing is posted; every worker runs on. doz workspace start wakes it again (the brief is not posted twice). Nothing running: said, and exit 0.")
    @OptionGroup var g: GlobalOptions
    @Argument(help: "The workspace.") var name: String
    func run() async throws {
        var w = WorkspaceRequest(name: name)
        w.managerOnly = true
        let s = try decode(try call(workspaceRequest(.workspaceStop, w), g), WorkspaceStopped.self, g)
        if g.json { Out.json(s); return }
        if !s.stopped { Out.stdout((s.notes?.first ?? "nothing to stop") + "\n"); return }
        printWorkspace(s.workspace)
        for n in s.notes ?? [] { Out.stdout("note: \(n)\n") }
    }
}

/// Finish, and its twin down: a workspace a space file made goes down by its file's plan (`workspace-down`); any other
/// finishes (`workspace-finish`). Both answer `WorkspaceFinish` and say what they removed and what they kept.
func runWorkspaceFinish(name n: String, purge: Bool, noArchive: Bool, yes: Bool, dryRun: Bool, ifPlan: String?, word: String, _ g: GlobalOptions) async throws {
    var q = HostRequest(.workspaceDownPlan)
    q.spaceDown = SpaceDownRequest(workspace: n, purge: purge ? true : nil)
    let plan = try decode(try await query(q, g), SpaceDownPlan.self, g)
    // Made without a space file: finish (it removes nothing — standing).
    if plan.refusalCode == HostError.Code.exists.rawValue {
        if purge { throw fail(HostError(.invalid, "--purge: \(n) was made without a space file — nothing of it persists beyond its finish"), g) }
        try await runWorkspaceLifecycle(.finish, name: n, dryRun: dryRun, yes: yes, ifPlan: ifPlan, g, word: word) { w in w.noArchive = noArchive ? true : nil }
        return
    }
    if noArchive, plan.refusalCode == nil {
        throw fail(HostError(.invalid, "--no-archive: \(n)'s space file says whether its run is archived (archive: off)"), g)
    }
    if g.json && dryRun { Out.json(plan) } else if !g.json { Out.stdout(spaceDownText(plan, dryRun: dryRun)) }
    if let c = plan.refusalCode {
        let e = HostError(HostError.Code(rawValue: c) ?? .failed, plan.refusals.first ?? "refused")
        if g.json && !dryRun { Out.json(WithError(value: plan, error: e)) }
        throw ExitCode(DozableExit.code(for: e))
    }
    if dryRun { return }
    if plan.steps.isEmpty {
        if g.json {
            let rec = try? decode(try await query(workspaceRequest(.workspaceShow, WorkspaceRequest(name: n)), g), WorkspaceDetail.self, g)
            var d = SpaceActed(space: n, verb: purge ? "purge" : "down")
            d.kind = WorkspaceFinishInventory.kind; d.schema = WorkspaceFinishInventory.schema
            d.removed = []; d.kept = nil; d.workspace = rec
            Out.json(d)
        }
        return
    }
    let question = (purge ? "Purge \(n): take it down and remove what persists?" : "\(capitalised(word)) \(n)?")
        + (plan.noCopy.isEmpty ? "" : " Deleted with no copy (archive: off): " + plan.noCopy.joined(separator: ", ") + ".")
    try confirm(question, yes: yes, g, fix: ["doz", "workspace", word, n] + (purge ? ["--purge"] : []) + ["--yes"] + (g.json ? ["--json"] : []))
    var a = HostRequest(.workspaceDown)
    a.spaceDown = SpaceDownRequest(workspace: n, purge: purge ? true : nil, ifPlan: ifPlan ?? plan.sha)
    let done = try decode(try call(a, g), SpaceActed.self, g)
    try finishSpaceActed(done, retry: ["doz", "workspace", word, n] + (purge ? ["--purge"] : []), g)
}

struct WorkspaceReopen: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "reopen", abstract: "Reopen a finished workspace: nothing runs until you wake it.")
    @OptionGroup var a: LifecycleArguments
    func run() async throws { try await runWorkspaceLifecycle(.reopen, a) }
}

struct WorkspaceArchive: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "archive", abstract: "Put it away: finished, its rooms read-only, its anonymous workers retired.",
        discussion: """
        Finish's steps, then its rooms archived as you (read-only, their history kept) and each anonymous worker retired (its \
        token refused from now on); a bot keeps its token and its place in the rooms. Nothing on disk goes unless \
        --remove-sandboxes: then each sandbox Dozable made for it is removed, its disk saved as an image first (doz image ls; \
        --no-keep-templates to skip). Asks for its name to be typed (--yes skips). doz workspace restore W brings it back, finished.
        """)
    @OptionGroup var a: LifecycleArguments
    @OptionGroup var s: LifecycleSandboxFlags
    @OptionGroup var x: LifecycleArchiveFlag
    func run() async throws {
        try await runWorkspaceLifecycle(.archive, a) { w in
            w.noArchive = x.noArchive ? true : nil
            w.removeSandboxes = s.removeSandboxes ? true : nil
            w.keepTemplates = s.removeSandboxes && !s.keepTemplates ? false : nil
        }
    }
}

struct WorkspaceRestore: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "restore", abstract: "Bring an archived workspace back, finished: its rooms writable again.",
        discussion: "Retired workers stay ended; a removed sandbox is not made again (the image its disk was saved as is named). Then reopen and wake it.")
    @OptionGroup var a: LifecycleArguments
    func run() async throws { try await runWorkspaceLifecycle(.restore, a) }
}

struct WorkspaceDelete: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete a finished or archived workspace's record, brief and log. Cannot be undone.",
        discussion: """
        Refused unless it is finished or archived (doz workspace finish W first) and while anything of it runs. Its rooms \
        stay — archived, with their history (the chat server cannot delete a room); its bots and their tokens, saved disks, \
        and its adopted sandboxes and sessions (loose again) are kept; its anonymous workers are retired. Nothing on disk goes \
        unless asked: --remove-sandboxes removes the sandboxes Dozable made for it, --bin-folders moves its folders to the \
        Bin (never your home, the store, or a folder another workspace or sandbox uses). Asks for its name to be typed (--yes \
        skips).
        """)
    @OptionGroup var a: LifecycleArguments
    @OptionGroup var s: LifecycleSandboxFlags
    @Flag(name: .customLong("bin-folders"), help: "Also move its folders on this Mac to the Bin (never deleted).") var binFolders = false
    func run() async throws {
        try await runWorkspaceLifecycle(.delete, a) { w in
            w.removeSandboxes = s.removeSandboxes ? true : nil
            w.keepTemplates = s.removeSandboxes && !s.keepTemplates ? false : nil
            w.binFolders = binFolders ? true : nil
        }
    }
}
