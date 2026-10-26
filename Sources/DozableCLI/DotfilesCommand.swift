import ArgumentParser
import Darwin
import Foundation
import DozableKit
import DozableHost

// 657 — `doz dotfiles NAME [--update]` (what a sandbox's dotfiles are, at which commit, how the last apply went; move them
// on) and `doz dotfiles trust SOURCE` (say yes ahead, for scripts) — and the question every create asks before dotfiles
// are applied: they are code that runs in the sandbox, so the CLI asks once per repository + commit (like 653's community
// recipes). Off a terminal it refuses, naming the command that trusts them.

/// The dotfiles a create will apply, fetched by the host and said; asked about once per source + commit (remembered in
/// `<settings dir>/dotfiles-trusted.json`). The create then carries exactly that commit. Nothing when there are none.
func confirmDotfilesTrust(_ o: inout CreateOptions, _ g: GlobalOptions) throws {
    guard o.dotfilesCommit == nil else { return }               // asked already (a quick make, then its key's preflight)
    let raw = o.dotfiles ?? DozableSettings.load().string(SettingKey.dotfiles) ?? ""
    guard !DotfilesSource.isNone(raw) else { return }
    var r = HostRequest(.dotfilesResolve)
    r.dotfilesSource = raw
    let res = try decode(try call(r, g), DotfilesResolved.self, g)
    o.dotfiles = res.source
    o.dotfilesCommit = res.commit
    try confirmTrust(res, g)
}

/// Said, and asked when this source + commit was never trusted.
func confirmTrust(_ res: DotfilesResolved, _ g: GlobalOptions) throws {
    if DotfilesTrust.isTrusted(source: res.source, commit: res.commit) {
        if !g.json, !g.quiet { Out.stderr("[doz] dotfiles: \(res.display) at \(res.commit.prefix(12)) — \(res.plan.summary)\n") }
        return
    }
    Out.stderr(dotfilesLines(res).joined(separator: "\n") + "\n")
    guard isatty(STDIN_FILENO) == 1, isatty(STDERR_FILENO) == 1 else {
        throw fail(HostError(.failed, "dotfiles you have not said yes to (\(res.display) at \(res.commit.prefix(12))) — read them, then: "
                             + "doz dotfiles trust \(DotfilesLayer.quote(res.source)) --commit \(res.commit) (or --dotfiles none)"),
                   g, code: DozableExit.declined)
    }
    try confirm("Apply these dotfiles in the sandbox?", yes: false, g)
    do { try DotfilesTrust.trust(source: res.source, commit: res.commit) } catch {
        throw fail(HostError(.failed, "could not remember the answer: \(error.localizedDescription)"), g)
    }
}

/// What will run, in a few lines.
func dotfilesLines(_ res: DotfilesResolved) -> [String] {
    var lines = ["[doz] dotfiles: \(res.display) at \(res.commit.prefix(12))" + (res.subject.map { " (\($0))" } ?? "")
                 + " — code that runs in the sandbox, as its user, at its first start:"]
    if let s = res.plan.script {
        lines.append("  its \(s) runs (at most \(DotfilesLayer.scriptTimeoutSeconds / 60) minutes; it can do anything the sandbox's user can, through the sandbox's network policy)")
    } else {
        lines.append("  \(res.plan.links.count) dotfile\(res.plan.links.count == 1 ? "" : "s") linked into ~ — never over a file that is there, never over Dozable's own"
                     + (res.plan.links.isEmpty ? "" : ": " + res.plan.links.prefix(8).joined(separator: ", ") + (res.plan.links.count > 8 ? ", …" : "")))
    }
    if res.dirty == true { lines.append("  the folder has changes not committed — only the commit is applied") }
    lines.append("  the files are copied in from this Mac; no credential of yours enters the sandbox")
    return lines
}

struct DotfilesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "dotfiles",
        abstract: "Your dotfiles in a sandbox: what is applied, at which commit, the last run (--update: the newest commit).",
        discussion: """
        A sandbox's dotfiles come from the setting sandbox.dotfiles (or doz create --dotfiles, dotfiles in \
        doz_project.yaml): a git repository fetched on this Mac with its own git login, or a folder on this Mac that is \
        one. A sandbox keeps the commit it was made at. At its first start, as its user, the repository's install script \
        runs (install.sh, install, bootstrap.sh, bootstrap, script/bootstrap, setup.sh, setup, script/setup — the first \
        it has), or its dotfiles are linked into the home, never over a file that is there.
        """,
        subcommands: [DotfilesShow.self, DotfilesTrustCommand.self],
        defaultSubcommand: DotfilesShow.self)
}

struct DotfilesShow: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "show",
        abstract: "A sandbox's dotfiles: the repository, the commit, what applying them does, the last run (--update: move them on).")
    @OptionGroup var g: GlobalOptions
    @Argument(help: "The sandbox.") var name: String
    @Flag(name: .long, help: "Move them to the newest commit of their repository (the setting's, when the sandbox has none) and apply them — now when it runs, else at its next start or wake. Asks once per new commit.")
    var update = false

    func run() async throws {
        let rep: DotfilesReport
        if update {
            var r = HostRequest(.dotfilesUpdate, name: name)
            // The newest commit, said and trusted first (the host fetches; the same answer a create gets).
            let current = try decode(try await query(HostRequest(.dotfiles, name: name), g), DotfilesReport.self, g)
            guard let source = current.dotfiles?.source ?? current.setting else {
                throw fail(HostError(.invalid, "\(name) has no dotfiles, and the setting sandbox.dotfiles is empty — doz config set sandbox.dotfiles URL|PATH"), g)
            }
            var q = HostRequest(.dotfilesResolve)
            q.dotfilesSource = source
            let res = try decode(try call(q, g), DotfilesResolved.self, g)
            try confirmTrust(res, g)
            r.dotfilesSource = res.source
            r.dotfilesCommit = res.commit
            rep = try decode(try call(r, g), DotfilesReport.self, g)
        } else {
            rep = try decode(try await query(HostRequest(.dotfiles, name: name), g), DotfilesReport.self, g)
        }
        if g.json { Out.json(rep); return }
        if let c = rep.changed { Out.stdout(c + "\n") }
        guard let d = rep.dotfiles else {
            Out.stdout("\(rep.sandbox) has no dotfiles"
                       + (rep.setting.map { " (the setting sandbox.dotfiles is \(DotfilesSource.isLocal($0) ? DisplayPath.tilde($0) : $0) — doz dotfiles \(rep.sandbox) --update applies it)" }
                          ?? " — doz config set sandbox.dotfiles URL|PATH, then doz dotfiles \(rep.sandbox) --update") + "\n")
            return
        }
        Out.stdout("Dotfiles of \(rep.sandbox): \(d.display)\n")
        Out.stdout("  commit   \(d.commit.prefix(12)) (\(d.resolvedAt.formatted(date: .abbreviated, time: .shortened)))\n")
        if let p = rep.plan { Out.stdout("  applies  \(p.summary)\n") }
        switch d.state {
        case "applied": Out.stdout("  state    ✓ applied \(d.at.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "") — \(d.summary ?? "")\n")
        case "failed": Out.stdout("  state    ✗ \(d.summary ?? "failed")\n")
        default: Out.stdout("  state    · not applied yet — at its next start or wake\n")
        }
        if let last = rep.last, last.commit == d.commit {
            if !last.output.isEmpty {
                Out.stdout("  output   (its last lines; all of it in ~/\(DotfilesLayer.guestLogRelative) in the sandbox)\n")
                for l in last.output.suffix(12) { Out.stdout("           \(l)\n") }
            }
            if !last.linked.isEmpty { Out.stdout("  linked   \(last.linked.joined(separator: ", "))\n") }
            if !last.kept.isEmpty { Out.stdout("  kept     \(last.kept.joined(separator: ", ")) (yours — never overwritten)\n") }
            if !last.stock.isEmpty { Out.stdout("  replaced \(last.stock.joined(separator: ", ")) (the image's stock copy, kept as NAME.doz-stock)\n") }
        }
        if let p = rep.plan, !p.skipped.isEmpty {
            Out.stdout("  skipped  " + p.skipped.map { "\($0.path) (\($0.why))" }.joined(separator: ", ") + "\n")
        }
        if let s = rep.setting, s != d.source { Out.stdout("  (the setting sandbox.dotfiles is now \(DotfilesSource.isLocal(s) ? DisplayPath.tilde(s) : s) — this sandbox keeps its own)\n") }
    }
}

struct DotfilesTrustCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "trust",
        abstract: "Say yes to a dotfiles repository's commit ahead (what a create would otherwise ask once) — for scripts.")
    @OptionGroup var g: GlobalOptions
    @Argument(help: "The repository (https://…) or folder on this Mac; default: the setting sandbox.dotfiles.") var source: String?
    @Option(name: .long, help: "The commit (default: its head now — fetched on this Mac).") var commit: String?

    func run() async throws {
        let raw = source ?? DozableSettings.load().string(SettingKey.dotfiles) ?? ""
        let normalized: String
        do {
            guard let n = try DotfilesSource.normalized(raw, home: TestSafety.realHome.path) else {
                throw fail(HostError(.invalid, "which dotfiles? — doz dotfiles trust URL|PATH (the setting sandbox.dotfiles is empty)"), g)
            }
            normalized = n
        } catch let e as DotfilesError { throw fail(HostError(.invalid, e.message), g) }
        let c: String
        if let commit {
            guard DotfilesPin.isCommit(commit) else { throw fail(HostError(.invalid, "--commit: a full commit id (40 hex)"), g) }
            c = commit
        } else {
            var q = HostRequest(.dotfilesResolve)
            q.dotfilesSource = normalized
            let res = try decode(try call(q, g), DotfilesResolved.self, g)
            if !g.json, !g.quiet { Out.stderr(dotfilesLines(res).joined(separator: "\n") + "\n") }
            c = res.commit
        }
        do { try DotfilesTrust.trust(source: normalized, commit: c) } catch { throw fail(HostError(.failed, error.localizedDescription), g) }
        if g.json { Out.json(["source": normalized, "commit": c]); return }
        let shown = DotfilesSource.isLocal(normalized) ? DisplayPath.tilde(normalized) : normalized
        Out.stdout("said yes to \(shown) at \(c.prefix(12)) — asked again only for another commit\n")
    }
}
