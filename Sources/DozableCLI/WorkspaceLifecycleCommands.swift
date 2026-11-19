import ArgumentParser
import Darwin
import Foundation
import DozableHost

// `doz workspace sleep | wake | finish | reopen | archive | restore | delete`: check, then ask. Each looks first —
// `workspace-lifecycle-plan`, answered from the store when no daemon runs — and prints what it would do to each agent,
// what is kept and what goes; `--dry-run` stops there (writing nothing, starting no daemon). Then it asks: nothing for
// sleep, wake, reopen and restore; a [y/N] for finish; the workspace's name typed on the terminal for archive and delete.
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
    @Flag(name: .customLong("remove-sandboxes"), help: "Also remove the sandboxes Dozable made for it (a manager's or a worker's own; never an adopted one) — a template of each first.")
    var removeSandboxes = false
    @Flag(name: .customLong("keep-templates"), inversion: .prefixedNo, help: "With --remove-sandboxes: keep a template of each sandbox first.")
    var keepTemplates = true
}

/// Run `verb` on `a.name`: look, print, ask, act.
func runWorkspaceLifecycle(_ verb: WorkspaceVerb, _ a: LifecycleArguments, edit: (inout WorkspaceRequest) -> Void = { _ in }) async throws {
    let g = a.g
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
    switch verb.confirm {
    case .none: break
    case .yes:
        if g.json && !a.yes { throw fail(HostError(.failed, "\(verb.rawValue) \(a.name) asks first — --json asks nothing: pass --yes"), g, code: DozableExit.declined) }
        try confirm("\(capitalised(verb.rawValue)) \(a.name)?", yes: a.yes, g)
    case .typed:
        try confirmTypedName(a.name, verb: verb.rawValue, yes: a.yes, g)
    }
    w.ifPlan = a.ifPlan ?? plan.sha
    w.verb = nil
    let r = verb == .stop ? try call(workspaceRequest(.workspaceStop, w), g) : try call(workspaceRequest(verb.hostOp, w), g)
    if verb == .stop { if g.json { Out.json(try decode(r, WorkspaceStopped.self, g)) }; return }
    let c = try decode(r, WorkspaceChanged.self, g)
    if g.json { Out.json(c); return }
    var out = ""
    for x in c.results { out += "  \(x.name): \(x.text)\n" }
    if let b = c.binned { for p in b { out += "  moved to the Bin: \(DisplayPath.tilde(p))\n" } }
    out += lifecycleDone(verb, c) + "\n"
    for n in c.notes ?? [] { out += "note: \(n)\n" }
    Out.stdout(out)
}

func capitalised(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }

func lifecycleDone(_ verb: WorkspaceVerb, _ c: WorkspaceChanged) -> String {
    switch verb {
    case .stop: "\(c.name): its manager stopped"
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
    if g.json { throw fail(HostError(.failed, "\(verb) \(name) asks for its name to be typed — --json asks nothing: pass --yes"), g, code: DozableExit.declined) }
    let fd = open("/dev/tty", O_RDWR)
    guard fd >= 0 else {
        throw fail(HostError(.failed, "\(verb) \(name) asks for its name to be typed — there is no terminal to ask; pass --yes"), g, code: DozableExit.declined)
    }
    defer { close(fd) }
    let prompt = "Type \(name) to \(verb) it: "
    _ = prompt.withCString { write(fd, $0, strlen($0)) }
    var buf = [UInt8](repeating: 0, count: 128)
    let n = read(fd, &buf, buf.count)
    let answer = n > 0 ? String(decoding: buf[0..<n], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) : ""
    guard answer == name else { throw fail(HostError(.failed, "not confirmed — nothing done"), g, code: DozableExit.declined) }
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
    static let configuration = CommandConfiguration(commandName: "finish", abstract: "The work is done: everything stops; the rooms, tokens, disks and folders are kept.",
        discussion: """
        Every sandbox shut down (its disk kept), every session ended (its conversation kept). Its rooms stay writable and \
        every token is kept, so doz workspace reopen W, then wake, works on it again. No worker can be added while it is \
        finished. Asks first (--yes skips).
        """)
    @OptionGroup var a: LifecycleArguments
    func run() async throws { try await runWorkspaceLifecycle(.finish, a) }
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
        --remove-sandboxes: then each sandbox Dozable made for it is removed, a template of it kept first (--no-keep-templates \
        to skip). Asks for its name to be typed (--yes skips). doz workspace restore W brings it back, finished.
        """)
    @OptionGroup var a: LifecycleArguments
    @OptionGroup var s: LifecycleSandboxFlags
    func run() async throws {
        try await runWorkspaceLifecycle(.archive, a) { w in
            w.removeSandboxes = s.removeSandboxes ? true : nil
            w.keepTemplates = s.removeSandboxes && !s.keepTemplates ? false : nil
        }
    }
}

struct WorkspaceRestore: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "restore", abstract: "Bring an archived workspace back, finished: its rooms writable again.",
        discussion: "Retired workers stay ended; a removed sandbox is not made again (its template is named). Then reopen and wake it.")
    @OptionGroup var a: LifecycleArguments
    func run() async throws { try await runWorkspaceLifecycle(.restore, a) }
}

struct WorkspaceDelete: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete a finished or archived workspace's record, brief and log. Cannot be undone.",
        discussion: """
        Refused unless it is finished or archived (doz workspace finish W first) and while anything of it runs. Its rooms \
        stay — archived, with their history (the chat server cannot delete a room); its bots and their tokens, templates, \
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
