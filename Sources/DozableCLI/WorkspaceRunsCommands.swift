import ArgumentParser
import Foundation
import DozableHost

// `doz workspace runs W [--json]`: a workspace's runs — each one's window, its length, its archive (written, a problem,
// none) and its size, and the timesheet's totals. Read from the store: with no daemon running, none is started.

struct WorkspaceRunsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "runs", abstract: "A workspace's runs: each start or reopen to its finish, and its archive.",
        discussion: """
        A run opens when doz workspace start kicks the work off, and again at each reopen; it closes at finish (or archive). \
        Sleep, wake, stop and start inside a run never close it. Each closed run's evidence — its messages, its agents' \
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
