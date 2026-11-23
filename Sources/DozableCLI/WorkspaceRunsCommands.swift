import ArgumentParser
import Foundation
import DozableHost

// `doz workspace runs W [--json]`: a workspace's runs — each one's window, its length, its archive (written, a problem,
// none) and its size, and the timesheet's totals. Read from the store: with no daemon running, none is started.

/// `doz workspace run W [GOAL]`: open a run — a unit of work (`workspace-run`). One at a time: while one is open it is
/// refused (exit 3, `run-open`, the fix `doz workspace finish W`). `reopen` is its old name.
struct WorkspaceRunVerb: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "run", abstract: "Open a run — a unit of work: its goal, or the brief. One at a time.",
        discussion: """
        A run is one unit of work, from run to finish. GOAL says what this one is for; leave it out and the goal is the \
        brief. The goal is posted in the workspace's room as your message, and then its agents start as doz workspace \
        start starts them (--no-start opens the run and starts nothing). A finished workspace is reopened first: its rooms \
        open to new messages again. Only one run is open at a time: while one is, run is refused (exit 3, run-open) — doz \
        workspace finish W finishes it. An archived workspace is refused too (doz workspace restore W first). The run \
        records its goal, what started it (--source KIND or KIND:REF — given, brief, run:ID, ask:TEXT, schedule:TEXT), \
        the run it follows (--follows RUN, a run of this workspace) and the revision of the brief it read; doz workspace \
        runs W lists them. --json answers {kind: WorkspaceRun, id, state, goal, goalFrom, source, follows, openedAt, \
        openedBy, revision, usage}. You are never gated; an agent acting with --as W/AGENT needs the permission run.open \
        (doz grant AGENT run.open=allow --in W). doz workspace reopen W is the old name of run. (Not Docker Compose's run, \
        which runs a one-off command: this one opens a unit of work.)
        """)
    @OptionGroup var g: GlobalOptions
    @Argument(help: "The workspace.") var name: String
    @Argument(help: "What this run is for (default: the brief).") var goal: String?
    @Option(name: .customLong("source"), help: "What started it: given, brief, run:ID, ask:TEXT or schedule:TEXT.") var source: String?
    @Option(name: .customLong("follows"), help: "The run this one follows (a run of this workspace: doz workspace runs W).") var follows: String?
    @Flag(name: .customLong("no-start"), help: "Open the run and start nothing (doz workspace start W starts its agents).") var noStart = false

    func run() async throws {
        try runWorkspaceRun(name: name, goal: goal, source: source, follows: follows, noStart: noStart, g)
    }
}

/// Open a run of `n` (the run verb, and reopen as its old name): one request; a run that is open is refused with the
/// command that finishes it.
func runWorkspaceRun(name n: String, goal: String?, source: String?, follows: String?, noStart: Bool, _ g: GlobalOptions) throws {
    var w = WorkspaceRequest(name: n)
    w.goal = goal
    w.source = source
    w.follows = follows
    w.noStart = noStart ? true : nil
    let m = try rawCall(workspaceRequest(.workspaceRun, w), g)
    guard m.ok == true else {
        let e = m.error ?? HostError(.failed, "the daemon gave no reason")
        throw fail(e, g, fix: e.code == .runOpen ? ["doz", "workspace", "finish", n] : nil)
    }
    let r = try decode(m.result ?? .null, WorkspaceRunOpened.self, g)
    if g.json { Out.json(r); return }
    var out = "\(n): run \(r.id) is open — " + (r.goalFrom == "given" ? "its goal: \(r.goal.split(separator: "\n").first.map(String.init) ?? "")" : "its goal is the brief")
        + (r.posted ? " (posted in the room)" : "") + "\n"
    if let s = r.started, !s.isEmpty { out += "  started: \(s.joined(separator: ", "))\n" }
    for x in r.notes ?? [] { out += "note: \(x)\n" }
    Out.stdout(out)
}

struct WorkspaceRunsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "runs", abstract: "A workspace's runs: each start or reopen to its finish, and its archive.",
        discussion: """
        A run opens when doz workspace start kicks the work off, at doz workspace run (reopen is its old name) and at an up \
        with none open; it closes at finish (or archive). Sleep, wake, stop and start inside a run never close it. --json \
        gives each run its goal, goalFrom, source, follows, revision, openedBy and usage.durationMs (a closed run's length, \
        an open one's so far); a run opened before runs recorded them has none of the first six. Each closed run's evidence — its messages, its agents' \
        conversations and screens, its usage and a timesheet — is archived in Dozable's store.
        """)
    @OptionGroup var g: GlobalOptions
    @Argument(help: "The workspace.") var name: String
    @Option(name: .customLong("archive"), help: "Write this closed run's archive again (when it could not be written at its finish).")
    var archive: String?
    @Option(name: .customLong("frames"), help: "A space's run in frames: its state each time it changed, and its archive checked now.")
    var frames: String?

    func run() async throws {
        if archive != nil, frames != nil { throw fail(HostError(.invalid, "--archive or --frames, not both"), g) }
        if let run = frames {
            var w = WorkspaceRequest(name: name)
            w.run = run
            let d = try decode(try await query(workspaceRequest(.workspaceRunFrames, w), g), SpaceRunDetail.self, g)
            if g.json { Out.json(d); return }
            Out.stdout(spaceRunFramesText(d))
            return
        }
        if let run = archive {
            var w = WorkspaceRequest(name: name)
            w.run = run
            let c = try decode(try call(workspaceRequest(.workspaceRunArchive, w), g), WorkspaceChanged.self, g)
            if g.json { Out.json(c); return }
            var out = "run \(run)'s archive written: \(DisplayPath.tilde(g.dozableStore.root.path + "/" + (c.archive ?? "")))\n"
            for n in c.notes ?? [] { out += "note: \(n)\n" }
            Out.stdout(out)
            return
        }
        let l = try decode(try await query(workspaceRequest(.workspaceRuns, WorkspaceRequest(name: name)), g), WorkspaceRunsListing.self, g)
        if g.json { Out.json(l); return }
        Out.stdout(workspaceRunsText(l))
    }
}

func workspaceRunsText(_ l: WorkspaceRunsListing) -> String {
    var s = ""
    if l.runs.isEmpty { return "\(l.workspace): \(l.note ?? "no runs")\n" }
    var t = [["RUN", "STARTED", "ENDED", "LENGTH", "ARCHIVE", "SIZE", "MESSAGES", "CALLS", "TOKENS IN / OUT"]]
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd HH:mm"
    for r in l.runs {
        let archive: String
        switch r.archiveStatus {
        case "open": archive = "open"
        case "written": archive = "written"
        case "problem": archive = "not written"
        case "missing": archive = "missing"
        default: archive = "none"
        }
        t.append([r.id + (r.legacy == true ? " (before runs)" : ""), f.string(from: r.startedAt), r.endedAt.map { f.string(from: $0) } ?? "—",
                  runLength(r.minutes), archive, r.archiveBytes.map { DozableImages.formatBytes($0) } ?? "—",
                  r.messages.map(String.init) ?? "—", r.calls.map(String.init) ?? "—",
                  r.tokensIn.map { "\($0) / \(r.tokensOut ?? 0)" } ?? "—"])
    }
    s += Out.table(t)
    for r in l.runs {
        if let p = r.archiveProblem { s += "note: run \(r.id)'s archive was not written: \(p) — doz workspace runs \(l.workspace) --archive \(r.id) writes it again\n" }
        if r.archiveStatus == "missing" { s += "note: run \(r.id)'s archive is not in the store any more\n" }
    }
    if let n = l.note { s += "note: \(n)\n" }
    return s
}

func runLength(_ minutes: Int) -> String { "\(minutes / 60) h \(String(format: "%02d", minutes % 60)) min" }

/// A run's frames as a person reads them: each frame's time, what changed, and what waited; then its archive checked now.
func spaceRunFramesText(_ d: SpaceRunDetail) -> String {
    var s = "run \(d.id) of \(d.workspace): \(d.frames.count) frame\(d.frames.count == 1 ? "" : "s")\(d.capped == true ? " (past the bound: the last state kept after it)" : "")\n"
    var t = [["FRAME", "AT", "WHAT CHANGED", "STATE"]]
    for f in d.frames {
        let running = f.state.items.filter { $0.type == "agent" && $0.state == "running" }.count
        let agents = f.state.items.filter { $0.type == "agent" }.count
        var state = "\(running)/\(agents) agents running"
        if !f.state.attention.isEmpty { state += ", \(f.state.attention.count) waiting for you" }
        if let r = f.state.run { state += ", run \(r.phase)" }
        t.append([f.file, f.at, f.label, state])
    }
    s += Out.table(t)
    if let a = d.archive {
        s += "archive: \(a.path) — " + (a.verified ? "verified (\(a.files.count) files)" : "does not verify: " + a.mismatched.joined(separator: ", ")) + "\n"
    }
    if let n = d.note { s += "note: \(n)\n" }
    return s
}
