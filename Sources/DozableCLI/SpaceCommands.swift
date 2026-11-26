import ArgumentParser
import DozableChat
import DozableHost
import Foundation

// Space files (`NAME.workspace.yaml`; `NAME.space.yaml` is read too): a workspace described in one file kept beside the work. The CLI reads the file and the
// files it names (`SpaceResolver`); looking — `config`, `plan`, `up --dry-run` — never starts the daemon and writes
// nothing. `doz space …` is the same commands under a shorter name. docs/manual/39-space-files.md.

/// The space file a command is about: `-f FILE`, else the one `*.workspace.yaml` (or `*.space.yaml`) in this folder.
func spaceFile(_ f: String?, _ g: GlobalOptions) throws -> String {
    if let f { return workspaceAbsolute(f) }
    do { return try SpaceResolver.find(in: FileManager.default.currentDirectoryPath) } catch { throw fail(HostError.from(error), g) }
}

/// Every problem, as file:line, the message and its hint; errors exit 65 (an invalid document) and nothing is done.
func reportSpaceProblems(_ problems: [SpaceProblem], _ g: GlobalOptions) throws {
    guard !problems.isEmpty else { return }
    let errors = problems.filter(\.isError).count
    if g.json {
        if errors > 0 {
            let e = spaceDocumentError(problems)
            Out.json(SpaceProblemsAnswer(problems: problems, error: ErrorAnswer(e).error))
            throw ExitCode(DozableExit.code(for: e))
        }
        return
    }
    Out.stderr(problems.map { $0.text + "\n" }.joined())
    if errors > 0 {
        Out.stderr("\(errors) error\(errors == 1 ? "" : "s"): nothing was done\n")
        throw ExitCode(DozableExit.invalid)
    }
}

/// A space file's errors as ONE error: `invalid-document`, the count and the first, as file:line.
func spaceDocumentError(_ problems: [SpaceProblem]) -> HostError {
    let errors = problems.filter(\.isError)
    let first = errors.first.map { ": \($0.file):\($0.line) \($0.message)" } ?? ""
    return HostError(.invalidDocument, "the space file has \(errors.count) error\(errors.count == 1 ? "" : "s")\(first) — nothing was done")
}

struct SpaceProblemsAnswer: Encodable {
    var ok = false
    var problems: [SpaceProblem]
    var error: ErrorAnswer.Body?
}

/// An answer printed whole with `error` beside its own fields (additive: the answer's shape is unchanged).
struct WithError<T: Encodable>: Encodable {
    var value: T
    var error: HostError
    var partial: PartialAnswer? = nil
    enum K: String, CodingKey { case error, partial }
    func encode(to encoder: Encoder) throws {
        try value.encode(to: encoder)
        var c = encoder.container(keyedBy: K.self)
        try c.encode(ErrorAnswer(error).error, forKey: .error)
        try c.encodeIfPresent(partial, forKey: .partial)
    }
}

/// A plan's own failure: its file's errors (65), else its refusal's code — each through the one table.
func spacePlanError(_ p: SpacePlan) -> HostError? {
    if p.problems.contains(where: \.isError) { return spaceDocumentError(p.problems) }
    guard let c = p.refusalCode else { return nil }
    let code = HostError.Code(rawValue: c) ?? .failed
    return HostError(code == .invalid ? .invalidDocument : code, p.refusals.first ?? "refused")
}

/// The merged space as YAML, each place set outside the space file annotated with its file and line.
enum SpaceYAML {
    static func emit(_ v: JValue, origins: [String: SpaceOrigin], sources: [SpaceSource]) -> String {
        var out = ""
        /// A value from another file names it; a map or list only where its file differs from its parent's.
        func note(_ p: String, leaf: Bool = true) -> String {
            guard let o = origins[p], o.s < sources.count, sources[o.s].kind != "space" else { return "" }
            if !leaf, let i = p.lastIndex(of: "/"), origins[String(p[..<i])]?.s == o.s { return "" }
            return "  # \(sources[o.s].name):\(o.l)"
        }
        func scalar(_ v: JValue) -> String {
            switch v {
            case .null: return "null"
            case .bool(let b): return b ? "true" : "false"
            case .int(let n): return String(n)
            case .double(let d): return ChatJSON.goFloat(d)
            case .number(let s): return s
            case .string(let s): return quote(s)
            case .array(let a) where a.isEmpty: return "[]"
            case .object(let m) where m.isEmpty: return "{}"
            default: return ""
            }
        }
        func isScalar(_ v: JValue) -> Bool {
            switch v {
            case .array(let a): return a.isEmpty
            case .object(let m): return m.isEmpty
            case .string(let s): return !s.contains("\n")
            default: return true
            }
        }
        func block(_ s: String, _ indent: String) -> String {
            let chomp = s.hasSuffix("\n") ? (s.hasSuffix("\n\n") ? "+" : "") : "-"
            let body = s.hasSuffix("\n") ? String(s.dropLast()) : s
            return "|\(chomp)\n" + body.split(separator: "\n", omittingEmptySubsequences: false).map { $0.isEmpty ? "" : indent + $0 }.joined(separator: "\n")
        }
        func value(_ v: JValue, _ p: String, _ indent: String, _ prefix: String) {
            switch v {
            case .object(let m) where !m.isEmpty:
                for (i, x) in m.enumerated() {
                    let q = SpaceDoc.join(p, x.key)
                    let lead = i == 0 ? prefix : indent
                    let k = quoteKey(x.key)
                    if isScalar(x.value) { out += "\(lead)\(k): \(scalar(x.value))\(note(q))\n" }
                    else if case .string(let s) = x.value { out += "\(lead)\(k): \(block(s, indent + "  "))\(note(q))\n" }
                    else { out += "\(lead)\(k):\(note(q, leaf: false))\n"; value(x.value, q, indent + "  ", indent + "  ") }
                }
            case .array(let a) where !a.isEmpty:
                for (i, x) in a.enumerated() {
                    let q = p + "/\(i)"
                    let lead = i == 0 ? prefix : indent
                    if isScalar(x) { out += "\(lead)- \(scalar(x))\(note(q))\n" }
                    else if case .string(let s) = x { out += "\(lead)- \(block(s, indent + "  "))\(note(q))\n" }
                    else { value(x, q, indent + "  ", lead + "- ") }
                }
            default:
                out += prefix + scalar(v) + "\n"
            }
        }
        value(v, "", "", "")
        return out
    }

    static func quoteKey(_ k: String) -> String { plainOK(k) ? k : json(k) }

    static func quote(_ s: String) -> String { plainOK(s) ? s : json(s) }

    static func json(_ s: String) -> String { ChatJSON.encodeString(.string(s)) }

    /// Text that reads back as the same text, unquoted.
    static func plainOK(_ s: String) -> Bool {
        guard !s.isEmpty, s.range(of: "^[A-Za-z0-9_./~@$(][^\\n#]*$", options: .regularExpression) != nil else { return false }
        if s.contains(": ") || s.hasSuffix(":") || s.hasSuffix(" ") || s.contains(" #") { return false }
        if s.contains("{") || s.contains("}") || s.contains("[") || s.contains("]") || s.contains(",") || s.contains("\"") || s.contains("'") { return false }
        if case .string = SpaceResolver.scalar(.init(s)) { return true }
        return false
    }
}

// MARK: config

/// `doz workspace config FILE` / `doz space config FILE`: the merged space — every `extends:` file in order, the file, its
/// override and `${VAR}` — each value set outside the space file annotated with its file and line; the sources with their
/// sha256 and every risky setting with where it comes from. Changes nothing; never asks the daemon.
struct SpaceConfig: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "config", abstract: "Print a space file merged: its defaults files, the file, its override and ${VAR}, each value with its source.",
        discussion: """
        Reads FILE (or the one *.workspace.yaml in this folder), every defaults file it extends, NAME.workspace.override.yaml beside \
        it and ${VAR} from the environment or the .env beside it, and prints the result, each value from another file \
        annotated with that file and line. The header lists the sources with their sha256 and every risky setting with \
        where it comes from. Changes nothing and never starts the daemon. Problems are printed as file:line; an error exits 65.
        """)
    @OptionGroup var g: GlobalOptions
    @Argument(help: "The space file (default: the one *.workspace.yaml in this folder).") var file: String?
    @Option(name: .customLong("profile"), help: "Include the resources of this profile (repeatable).") var profiles: [String] = []

    func run() async throws {
        let path = try spaceFile(file, g)
        let r = SpaceResolver().resolve(path)
        let (problems, model) = r.check(profiles: profiles)
        try reportSpaceProblems(problems, g)
        let risks = model?.risks ?? []
        if g.json {
            let doc: JValue = .object([
                JMember("space", .string(r.spaceName)),
                JMember("file", .string(r.file)),
                JMember("sources", .array(r.sources.map { s in .object([JMember("kind", .string(s.kind)), JMember("path", .string(s.path)), JMember("sha256", .string(s.sha256))]) })),
                JMember("risky", .array(risks.map { .object([JMember("setting", .string($0.setting)), JMember("source", .string($0.source))]) })),
                JMember("merged", r.merged),
                JMember("problems", .array(problems.map { p in .object([JMember("severity", .string(p.severity)), JMember("pointer", .string(p.pointer)),
                                                                         JMember("message", .string(p.message)), JMember("file", .string(p.file)),
                                                                         JMember("line", .int(Int64(p.line)))] + (p.hint.map { [JMember("hint", .string($0))] } ?? [])) })),
            ])
            Out.stdout(String(decoding: ChatJSON.encodeIndented(doc, indent: "  "), as: UTF8.self) + "\n")
            return
        }
        var s = "# the merged space \"\(r.spaceName)\" (doz space config): defaults, then the space file, then the override file, then ${VAR}\n"
        s += "# sources, lowest first:\n"
        for src in r.sources { s += "#   \(src.kind.padding(toLength: 8, withPad: " ", startingAt: 0)) \(DisplayPath.tilde(src.path))  sha256 \(src.sha256.prefix(16))…\n" }
        if !risks.isEmpty {
            s += "# risky settings and where they come from:\n"
            for k in risks { s += "#   \(k.line)\n" }
        }
        for sk in model?.skipped ?? [] { s += "# left out: \(sk.name) (only with --profile \(sk.profiles.joined(separator: " or --profile ")))\n" }
        s += SpaceYAML.emit(r.merged, origins: r.origins, sources: r.sources)
        Out.stdout(s)
    }
}

// MARK: doz space

/// `doz space …`: the space-file commands of `doz workspace` under a shorter name (the same command types).
struct SpaceCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "space",
        abstract: "Space files (NAME.workspace.yaml): doz workspace plan, up and config under a shorter name.",
        discussion: """
        A space file describes a workspace in one YAML file kept beside the work: its agents, rooms, folders and brief, \
        each made by the space or only referenced (external:). doz space plan -f FILE shows what up would do; doz space \
        config FILE prints it merged with the files it extends. Looking never starts the daemon and changes nothing. \
        A file called NAME.space.yaml (the older name) is read too; with both beside each other, NAME.workspace.yaml is \
        read and the other is ignored, said as a warning.
        """,
        subcommands: [SpacePlanCommand.self, SpaceUpCommand.self, SpaceDownCommand.self, SpaceConfig.self])
}

// MARK: plan, up --dry-run

/// The daemon's problems with the resolver's one note of its own added first: the `NAME.space.yaml` beside a
/// `NAME.workspace.yaml` that is not read (787). The daemon plans the merged document and never sees the file's name.
func withIgnoredWarning(_ problems: [SpaceProblem], _ r: SpaceResolver.Resolved) -> [SpaceProblem] {
    guard let w = SpaceResolver.ignoredWarning(r.file), !problems.contains(w) else { return problems }
    return [w] + problems
}

/// The brief beside the file, as a look: its sha256 and size, or why it cannot be used. Never its text, never written.
func spaceBriefLook(_ brief: String, file: String) -> SpaceBriefLook? {
    guard !brief.isEmpty else { return nil }
    let dir = (file as NSString).deletingLastPathComponent
    let expanded = TestSafety.expandSpaceTilde(brief)
    let path = URL(fileURLWithPath: expanded, relativeTo: URL(fileURLWithPath: dir, isDirectory: true)).standardizedFileURL.path
    var st = stat()
    guard lstat(path, &st) == 0 else { return SpaceBriefLook(path: path, problem: "\(DisplayPath.tilde(path)) doesn't exist") }
    guard (st.st_mode & S_IFMT) == S_IFREG else { return SpaceBriefLook(path: path, problem: "\(DisplayPath.tilde(path)) is not a regular file (no link)") }
    guard st.st_size <= Int64(WorkspaceStore.maximumBriefBytes) else {
        return SpaceBriefLook(path: path, problem: "\(DisplayPath.tilde(path)) is over \(WorkspaceStore.maximumBriefBytes >> 10) KiB")
    }
    guard let d = FileManager.default.contents(atPath: path), String(data: d, encoding: .utf8) != nil else {
        return SpaceBriefLook(path: path, problem: "\(DisplayPath.tilde(path)) is not UTF-8 text")
    }
    return SpaceBriefLook(path: path, sha256: SpaceDoc.sha256(String(decoding: d, as: UTF8.self)), bytes: d.count)
}

/// Resolve, validate, then ask `workspace-up-plan` (in-process when no daemon runs: nothing is started or written).
func spacePlan(file: String?, profiles: [String], noRun: Bool = false, _ g: GlobalOptions) async throws -> SpacePlan {
    let path = try spaceFile(file, g)
    let r = SpaceResolver().resolve(path)
    let (problems, model) = r.check(profiles: profiles)
    if problems.contains(where: \.isError) || model == nil { try reportSpaceProblems(problems, g) }
    var q = HostRequest(.workspaceUpPlan)
    q.space = r.request(profiles: profiles, brief: spaceBriefLook(model?.brief ?? "", file: r.file))
    if noRun { q.space?.noRun = true }
    var plan = try decode(try await query(q, g), SpacePlan.self, g)
    plan.problems = withIgnoredWarning(plan.problems, r)
    if !g.json { try reportSpaceProblems(plan.problems, g) }
    return plan
}

/// The plan as a person reads it.
func printSpacePlan(_ p: SpacePlan, dryRun: Bool, acting: Bool = false) {
    var s = dryRun ? "space up \"\(p.space)\" (dry run: nothing changes)\n" : acting ? "space up \"\(p.space)\"\n" : "plan for space \"\(p.space)\": \(p.steps.count) step\(p.steps.count == 1 ? "" : "s")\n"
    if let f = p.specPath { s += "  file: \(DisplayPath.tilde(f))\n" }
    if !p.factsKnown { s += "  no daemon is running: what only a running daemon knows is marked not known (none was started)\n" }
    for line in p.summary { s += "  \(line)\n" }
    s += "\n"
    let width = String(p.steps.count).count
    for st in p.steps {
        let mark = st.action == "run" ? "" : " (\(st.action)" + (st.why.map { ": \($0)" } ?? "") + ")"
        s += String(repeating: " ", count: width - String(st.n).count + 1) + "\(st.n). \(st.text)  [\(st.kind) · \(st.lifetime)]\(mark)\n"
        if let w = st.worker {
            var a = ["doz worker add \(p.space) \(w.name ?? "")"]
            if let i = w.isolation { a.append("--isolation \(i)") }
            if let x = w.sandbox { a.append("--sandbox \(x)") }
            if let c = w.cpus { a.append("--cpus \(c)") }
            if let m = w.memory { a.append("--memory \(m)") }
            if let pm = st.permissionMode { a.append("(permissions: \(pm))") }
            s += String(repeating: " ", count: width + 5) + "up:   " + a.joined(separator: " ") + "\n"
        } else if let op = st.op {
            s += String(repeating: " ", count: width + 5) + "up:   " + op + "\n"
        }
        if let d = st.down { s += String(repeating: " ", count: width + 5) + "down: " + d + "\n" }
    }
    for n in p.notes { s += "note: \(n)\n" }
    if !p.refusals.isEmpty {
        s += "\nstopped before changing anything:\n" + p.refusals.map { "  - \($0)\n" }.joined() + "nothing was changed\n"
    } else {
        s += dryRun ? "dry run done: nothing was changed\n" : acting ? "\n" : "the plan's sha: \(p.sha)\n"
    }
    Out.stdout(s)
}

func finishSpacePlan(_ p: SpacePlan, dryRun: Bool, _ g: GlobalOptions) throws {
    let e = spacePlanError(p)
    if g.json { if let e { Out.json(WithError(value: p, error: e)) } else { Out.json(p) } } else { printSpacePlan(p, dryRun: dryRun) }
    if let e { throw ExitCode(DozableExit.code(for: e)) }
}

/// `doz workspace plan -f FILE` / `doz space plan`: what `up` would do — every step, the summary with each risky setting's
/// file and line, what `down` will do. Changes nothing; never starts the daemon.
struct SpacePlanCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "plan", abstract: "Show what doz workspace up would do with a space file: every step, the summary, what down will do.",
        discussion: """
        Reads FILE (or the one *.workspace.yaml in this folder) and the files it extends, checks it — every problem at once, \
        as file:line —, and prints the steps up would run in order: the external things it checks, the workspace it \
        makes, its rooms and folders, the start, each agent. The summary names every risky setting (unfenced, bypass, \
        what persists, archive: off, transcripts discarded) with the file and line that set it. --json adds the places \
        (x-dozable.places, the sandboxes: each name, isolation, view, network, credentials) and where each agent runs. \
        Changes nothing and never starts the daemon. Exit codes: 0 up could run · 65 a problem in the file · 2 something external missing · 4 a \
        workspace of that name made without a space file · 7 something this version does not do yet.
        """)
    @OptionGroup var g: GlobalOptions
    @Option(name: [.customShort("f"), .customLong("file")], help: "The space file (default: the one *.workspace.yaml in this folder).") var file: String?
    @Option(name: .customLong("profile"), help: "Include the resources of this profile (repeatable).") var profiles: [String] = []

    func run() async throws {
        try finishSpacePlan(try await spacePlan(file: file, profiles: profiles, g), dryRun: false, g)
    }
}

/// The owned agents' `prompt_file`s, read beside the space file (a regular file, at most 16 KiB of UTF-8): agent → text.
func spacePrompts(_ r: SpaceResolver.Resolved) throws -> [String: String] {
    var out: [String: String] = [:]
    let dir = (r.file as NSString).deletingLastPathComponent
    for m in SpaceDoc.members(SpaceDoc.member(r.filled, "agents")) {
        guard let pf = SpaceDoc.string(SpaceDoc.member(m.value, "prompt_file")) else { continue }
        let expanded = TestSafety.expandSpaceTilde(pf)
        let path = URL(fileURLWithPath: expanded, relativeTo: URL(fileURLWithPath: dir, isDirectory: true)).standardizedFileURL.path
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { throw HostError(.notFound, "agent \(m.key): its prompt_file \(DisplayPath.tilde(path)) is not a file (no link)") }
        guard st.st_size <= Int64(WorkerLaunch.maximumTaskBytes), let d = FileManager.default.contents(atPath: path), let t = String(data: d, encoding: .utf8) else {
            throw HostError(.invalid, "agent \(m.key): its prompt_file \(DisplayPath.tilde(path)) is not UTF-8 text of at most \(WorkerLaunch.maximumTaskBytes >> 10) KiB")
        }
        out[m.key] = t
    }
    return out
}

/// `doz workspace up -f FILE`: the plan, then — every unfenced agent confirmed on a terminal — the space set up through the
/// daemon (`workspace-up`). With --dry-run, the plan only.
struct SpaceUpCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "up", abstract: "Set a workspace up from a space file: its rooms, folders, the run and its agents.",
        discussion: """
        Reads FILE (or the one *.workspace.yaml in this folder) and the files it extends, shows the plan — every step and the \
        summary naming each risky setting with the file and line that set it — and then sets the workspace up through the \
        daemon: the workspace (made, or changed to match the file), its rooms, the run (started, or reopened when the \
        space is down — a new run each time none is open; --no-run opens none, and doz workspace run W opens one later), \
        its scratch folders and each agent. A second up in an open run makes only what is missing. An \
        unfenced agent acts with full access to your user: up asks you to confirm it on the terminal at every up, \
        whatever set it — --yes answers that question on a terminal, and with no terminal up stops (exit 5). Up records \
        what the file requests for its agents and grants nothing (doz permissions grant does). With --dry-run, the plan \
        only: nothing is started or written. Exit codes: 0 done · 75 a step failed after others were done (the rest not \
        run; up again makes what is missing — --json's partial names what remains and the command) · 1 a step failed \
        before anything was done · 65 a problem in the file · 2 something external missing · 3 changed since the plan · \
        4 a workspace of that name made without a space file · 5 not confirmed · 7 something this version does not do yet.
        """)
    @OptionGroup var g: GlobalOptions
    @Option(name: [.customShort("f"), .customLong("file")], help: "The space file (default: the one *.workspace.yaml in this folder).") var file: String?
    @Option(name: .customLong("profile"), help: "Include the resources of this profile (repeatable).") var profiles: [String] = []
    @Flag(name: .customLong("dry-run"), help: "Show the plan and stop: nothing is started or written.") var dryRun = false
    @Flag(name: .long, help: "Answer the unfenced agents' question yes — on a terminal only.") var yes = false
    @Flag(name: .customLong("no-run"), help: "Set it up and start its agents, but open no run (doz workspace run W opens one).") var noRun = false

    func run() async throws {
        if dryRun { try finishSpacePlan(try await spacePlan(file: file, profiles: profiles, noRun: noRun, g), dryRun: true, g); return }
        let path = try spaceFile(file, g)
        let r = SpaceResolver().resolve(path)
        let (problems, model) = r.check(profiles: profiles)
        if problems.contains(where: \.isError) || model == nil { try reportSpaceProblems(problems, g) }
        var q = HostRequest(.workspaceUpPlan)
        var space = r.request(profiles: profiles, brief: spaceBriefLook(model?.brief ?? "", file: r.file))
        do { space.prompts = try spacePrompts(r) } catch { throw fail(HostError.from(error), g) }
        if noRun { space.noRun = true }
        q.space = space
        // Acting needs the daemon: the plan is the daemon's (started now), so its sha is the one up checks.
        var plan = try decode(try call(q, g), SpacePlan.self, g)
        plan.problems = withIgnoredWarning(plan.problems, r)
        if !g.json { try reportSpaceProblems(plan.problems, g); printSpacePlan(plan, dryRun: false, acting: true) }
        if let e = spacePlanError(plan) {
            if g.json { Out.json(WithError(value: plan, error: e)) }
            throw ExitCode(DozableExit.code(for: e))
        }
        // Every unfenced agent, at every up: asked on the terminal — never stdin, never without one.
        var confirmed: [String] = []
        if !plan.confirm.isEmpty {
            let fd = open("/dev/tty", O_RDWR)
            guard fd >= 0 else {
                throw fail(HostError(.needsConfirmation, "\(plan.confirm.joined(separator: ", ")) would run unfenced, with full access to your user — up asks you on a terminal, and there is none: nothing was done"),
                           g)
            }
            defer { close(fd) }
            if !yes {
                let prompt = "Start \(plan.confirm.joined(separator: ", ")) unfenced, with full access to your user? [y/N] "
                _ = prompt.withCString { write(fd, $0, strlen($0)) }
                var buf = [UInt8](repeating: 0, count: 64)
                let n = read(fd, &buf, buf.count)
                let answer = n > 0 ? String(decoding: buf[0..<n], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() : ""
                guard answer == "y" || answer == "yes" else { throw fail(HostError(.needsConfirmation, "not confirmed — nothing done"), g) }
            }
            confirmed = plan.confirm
        }
        var up = HostRequest(.workspaceUp)
        space.ifPlan = plan.sha
        space.confirmed = confirmed
        up.space = space
        var done = try decode(try call(up, g), SpaceActed.self, g)
        // 758: each use of the x-dozable form of a first-class 3.1 key, in --json's notes too (the text printed the plan's).
        if g.json { done.notes = SpaceDozable.deprecatedUses(r.merged) + done.notes }
        try finishSpaceActed(done, retry: ["doz", "workspace", "up", "-f", r.file] + profiles.flatMap { ["--profile", $0] }, g)
    }
}

/// What `up` or `down` did, and its exit: 0 every step done or skipped; 75 (partial) when a step failed after others
/// were done — `--json` adds `partial` {done, remaining, retry} and `error`; 1 when a step failed before anything was done.
func finishSpaceActed(_ d: SpaceActed, retry: [String], word: String? = nil, _ g: GlobalOptions) throws {
    let done = d.results.filter { $0.status == "done" || $0.status == "skipped" }.map(\.subject)
    let remaining = d.results.filter { $0.status == "failed" || $0.status == "not-run" }.map(\.subject)
    let e: HostError? = d.ok ? nil
        : done.isEmpty ? HostError(.failed, "\(d.verb) \(d.space): a step failed — nothing was done")
        : HostError(.partial, "\(d.verb) \(d.space): \(done.count) step\(done.count == 1 ? "" : "s") done, \(remaining.count) not — \(retry.joined(separator: " ")) does the rest")
    if g.json {
        if let e { Out.json(WithError(value: d, error: e, partial: e.code == .partial ? PartialAnswer(done: done, remaining: remaining, retry: retry) : nil)) }
        else { Out.json(d) }
    } else { Out.stdout(spaceActedText(d, word: word)) }
    if let e { throw ExitCode(DozableExit.code(for: e)) }
}

/// What `up` or `down` did, as a person reads it. `word`: the command typed, in place of the daemon's verb for a down (a
/// finish says finish).
func spaceActedText(_ d: SpaceActed, word: String? = nil) -> String {
    var s = ""
    for x in d.results {
        let mark = x.status == "done" ? "done   " : x.status == "skipped" ? "skip   " : x.status == "failed" ? "FAILED " : "not run"
        s += "  \(mark) \(x.n). \(x.text)\n"
        for n in x.notes ?? [] { s += "           \(n)\n" }
    }
    for n in d.notes { s += "note: \(n)\n" }
    let done = d.results.filter { $0.status == "done" }.count, skipped = d.results.filter { $0.status == "skipped" }.count
    s += "\(d.verb == "down" ? (word ?? d.verb) : d.verb): \(d.space)" + (d.run.map { ", run \($0)" } ?? "") + ": \(done) step\(done == 1 ? "" : "s") done, \(skipped) already there or nothing to do"
        + (d.ok ? "" : "; stopped at a failure") + "\n"
    // Down (which is finish) always says what it removed and what it kept.
    if let kept = d.kept {
        for l in WorkspaceFinishInventory.lines(removed: d.removed ?? [], kept: kept, untouched: d.untouched ?? [], released: d.released ?? [],
                                                standing: d.lifetime == "standing", archive: d.archive) { s += "  \(l)\n" }
        for (sb, image) in (d.savedDisks ?? [:]).sorted(by: { $0.key < $1.key }) { s += "  saved: sandbox/\(sb)'s disk as the image \(image)\n" }
    }
    return s
}

/// `doz workspace down [W]` / `doz space down`: the same as `doz workspace finish W` for every workspace. One a space file
/// made: its run ended and what it made for the run removed — archived and hash-checked first — and with --purge what persists
/// too (standing: nothing it owns but what says lifetime: run). Any other: finished, nothing removed. Asks on the terminal;
/// --dry-run shows the plan only.
struct SpaceDownCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "down", abstract: "The same as finish: end the run, archive it, and say what it removed and what it kept.",
        discussion: """
        doz workspace down W is doz workspace finish W, for every workspace. For one a space file made it ends the run — \
        its rooms closed, every agent stopped, the run's archive written into the store and hash-checked, the run closed — \
        then, by the workspace's lifetime: runs (a space file's default) removes what the space made for this run, each only \
        after its archived copy is hash-checked: the agents (ended and forgotten; their transcripts deleted only where the \
        file says transcripts: discard, and only files unchanged since), the run's scratch folders and its rooms (a \
        tombstone stays); standing (x-dozable.lifetime: standing) removes nothing it owns — its scratch folders are kept — \
        but what says x-dozable.lifetime: run itself. A persisted agent's memory is kept in the store for its next fenced \
        session. With archive: off nothing is copied: what goes with no copy is listed before you confirm. --purge also \
        removes what persists — its rooms, sandboxes and kept memory — and releases its folders (never deleted). A sandbox \
        is never removed without a copy: its disk is saved as an image first (doz image ls), named in the answer. External \
        folders, rooms, sandboxes and bots are never touched. A workspace made without a space file finishes and removes \
        nothing. Always says what it removed, what it kept and what it left untouched (--json: kind WorkspaceFinish, \
        removed, kept, untouched, savedDisks, archive). Asks \
        on the terminal (--yes answers it; no terminal and no --yes: exit 5). A failed step is said and down carries on; \
        down again does what is left. Exit codes: 0 done · 75 a step failed after others were done (--json's partial names \
        what remains) · 1 a step failed before anything was done · 2 no such workspace · 3 changed since the plan · 5 not \
        confirmed.
        """)
    @OptionGroup var g: GlobalOptions
    @Argument(help: "The workspace (default: the space in FILE, or in the one *.workspace.yaml in this folder).") var workspace: String?
    @Option(name: [.customShort("f"), .customLong("file")], help: "The space file whose workspace to take down.") var file: String?
    @Flag(name: .long, help: "Also remove what persists: its rooms, sandboxes and kept memory; release its folders (never deleted).") var purge = false
    @Flag(name: .customLong("no-archive"), help: "A workspace made without a space file: write no evidence archive of the run.") var noArchive = false
    @Flag(name: [.customShort("y"), .long], help: "Answer the question yes.") var yes = false
    @Flag(name: .customLong("dry-run"), help: "Show the plan and stop: nothing is changed.") var dryRun = false
    @Option(name: .customLong("if-plan"), help: "Act only on this plan (its sha, from --dry-run --json): refused, exit 3, if the workspace changed since.")
    var ifPlan: String?

    func run() async throws {
        let n: String
        if let w = workspace { n = w } else {
            let r = SpaceResolver().resolve(try spaceFile(file, g))
            n = r.spaceName
        }
        try await runWorkspaceFinish(name: n, purge: purge, noArchive: noArchive, yes: yes, dryRun: dryRun, ifPlan: ifPlan, word: "down", g)
    }
}

/// The down plan as a person reads it. `word`: the command the person typed (finish says finish, never "space down").
func spaceDownText(_ p: SpaceDownPlan, dryRun: Bool, word: String = "down") -> String {
    let verb = word == "down" ? "space down" : word
    var s = "\(verb)\(p.purge ? " --purge" : "") \"\(p.space)\"" + (dryRun ? " (dry run: nothing changes)" : "") + "\n"
    for line in p.summary { s += "  \(line)\n" }
    let width = String(max(p.steps.count, 1)).count
    for st in p.steps {
        s += String(repeating: " ", count: width - String(st.n).count + 1) + "\(st.n). \(st.text)" + (st.action == "run" ? "" : " (\(st.action))") + "\n"
    }
    for n in p.notes { s += "note: \(n)\n" }
    if !p.refusals.isEmpty { s += "It cannot be done:\n" + p.refusals.map { "  - \($0)\n" }.joined() }
    if dryRun { s += "dry run done: nothing was changed\n" }
    return s
}
