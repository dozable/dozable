import ArgumentParser
import DozableChat
import DozableHost
import Foundation

// Space files (`NAME.space.yaml`): a workspace described in one file kept beside the work. The CLI reads the file and the
// files it names (`SpaceResolver`); looking — `config`, `plan`, `up --dry-run` — never starts the daemon and writes
// nothing. `doz space …` is the same commands under a shorter name. docs/manual/39-space-files.md.

/// The space file a command is about: `-f FILE`, else the one `*.space.yaml` in this folder.
func spaceFile(_ f: String?, _ g: GlobalOptions) throws -> String {
    if let f { return workspaceAbsolute(f) }
    do { return try SpaceResolver.find(in: FileManager.default.currentDirectoryPath) } catch { throw fail(HostError.from(error), g) }
}

/// Every problem, as file:line, the message and its hint; errors exit 2 and nothing is done.
func reportSpaceProblems(_ problems: [SpaceProblem], _ g: GlobalOptions) throws {
    guard !problems.isEmpty else { return }
    let errors = problems.filter(\.isError).count
    if g.json {
        if errors > 0 {
            Out.json(SpaceProblemsAnswer(problems: problems))
            throw ExitCode(DozableExit.notFound)
        }
        return
    }
    Out.stderr(problems.map { $0.text + "\n" }.joined())
    if errors > 0 {
        Out.stderr("\(errors) error\(errors == 1 ? "" : "s"): nothing was done\n")
        throw ExitCode(DozableExit.notFound)
    }
}

struct SpaceProblemsAnswer: Encodable {
    var ok = false
    var problems: [SpaceProblem]
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
        Reads FILE (or the one *.space.yaml in this folder), every defaults file it extends, NAME.space.override.yaml beside \
        it and ${VAR} from the environment or the .env beside it, and prints the result, each value from another file \
        annotated with that file and line. The header lists the sources with their sha256 and every risky setting with \
        where it comes from. Changes nothing and never starts the daemon. Problems are printed as file:line; an error exits 2.
        """)
    @OptionGroup var g: GlobalOptions
    @Argument(help: "The space file (default: the one *.space.yaml in this folder).") var file: String?
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
        abstract: "Space files (NAME.space.yaml): doz workspace plan, up and config under a shorter name.",
        discussion: """
        A space file describes a workspace in one YAML file kept beside the work: its agents, rooms, folders and brief, \
        each made by the space or only referenced (external:). doz space plan -f FILE shows what up would do; doz space \
        config FILE prints it merged with the files it extends. Looking never starts the daemon and changes nothing.
        """,
        subcommands: [SpacePlanCommand.self, SpaceUpCommand.self, SpaceConfig.self])
}

// MARK: plan, up --dry-run

/// The brief beside the file, as a look: its sha256 and size, or why it cannot be used. Never its text, never written.
func spaceBriefLook(_ brief: String, file: String) -> SpaceBriefLook? {
    guard !brief.isEmpty else { return nil }
    let dir = (file as NSString).deletingLastPathComponent
    let expanded = brief == "~" ? NSHomeDirectory() : brief.hasPrefix("~/") ? NSHomeDirectory() + String(brief.dropFirst(1)) : brief
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
func spacePlan(file: String?, profiles: [String], _ g: GlobalOptions) async throws -> SpacePlan {
    let path = try spaceFile(file, g)
    let r = SpaceResolver().resolve(path)
    let (problems, model) = r.check(profiles: profiles)
    if problems.contains(where: \.isError) || model == nil { try reportSpaceProblems(problems, g) }
    var q = HostRequest(.workspaceUpPlan)
    q.space = r.request(profiles: profiles, brief: spaceBriefLook(model?.brief ?? "", file: r.file))
    let plan = try decode(try await query(q, g), SpacePlan.self, g)
    if !g.json { try reportSpaceProblems(plan.problems, g) }
    return plan
}

/// The plan as a person reads it.
func printSpacePlan(_ p: SpacePlan, dryRun: Bool) {
    var s = dryRun ? "space up \"\(p.space)\" (dry run: nothing changes)\n" : "plan for space \"\(p.space)\": \(p.steps.count) step\(p.steps.count == 1 ? "" : "s")\n"
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
        s += dryRun ? "dry run done: nothing was changed\n" : "the plan's sha: \(p.sha)\n"
    }
    Out.stdout(s)
}

func finishSpacePlan(_ p: SpacePlan, dryRun: Bool, _ g: GlobalOptions) throws {
    if g.json { Out.json(p) } else { printSpacePlan(p, dryRun: dryRun) }
    if p.problems.contains(where: \.isError) { throw ExitCode(DozableExit.notFound) }
    if let c = p.refusalCode { throw ExitCode(DozableExit.code(for: HostError(HostError.Code(rawValue: c) ?? .failed, ""))) }
}

/// `doz workspace plan -f FILE` / `doz space plan`: what `up` would do — every step, the summary with each risky setting's
/// file and line, what `down` will do. Changes nothing; never starts the daemon.
struct SpacePlanCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "plan", abstract: "Show what doz workspace up would do with a space file: every step, the summary, what down will do.",
        discussion: """
        Reads FILE (or the one *.space.yaml in this folder) and the files it extends, checks it — every problem at once, \
        as file:line —, and prints the steps up would run in order: the external things it checks, the workspace it \
        makes, its rooms and folders, the start, each agent. The summary names every risky setting (unfenced, bypass, \
        what persists, archive: off, transcripts discarded) with the file and line that set it. Changes nothing and never \
        starts the daemon. Exit codes: 0 up could run · 2 a problem in the file or something external missing · 4 a \
        workspace of that name made without a space file · 7 something this version does not do yet.
        """)
    @OptionGroup var g: GlobalOptions
    @Option(name: [.customShort("f"), .customLong("file")], help: "The space file (default: the one *.space.yaml in this folder).") var file: String?
    @Option(name: .customLong("profile"), help: "Include the resources of this profile (repeatable).") var profiles: [String] = []

    func run() async throws {
        try finishSpacePlan(try await spacePlan(file: file, profiles: profiles, g), dryRun: false, g)
    }
}

/// `doz workspace up -f FILE --dry-run`: the plan as `up` would show it. `up` itself acts in a later version.
struct SpaceUpCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "up", abstract: "Set a workspace up from a space file (this version: --dry-run, the plan only).",
        discussion: """
        With --dry-run, prints what up would do — the same as doz workspace plan — and changes nothing. Setting the \
        workspace up from the file comes in the next version.
        """)
    @OptionGroup var g: GlobalOptions
    @Option(name: [.customShort("f"), .customLong("file")], help: "The space file (default: the one *.space.yaml in this folder).") var file: String?
    @Option(name: .customLong("profile"), help: "Include the resources of this profile (repeatable).") var profiles: [String] = []
    @Flag(name: .customLong("dry-run"), help: "Show the plan and stop: nothing is started or written.") var dryRun = false

    func run() async throws {
        guard dryRun else {
            throw fail(HostError(.notImplemented, "doz workspace up sets a workspace up from its file in the next version — --dry-run shows what it would do"), g)
        }
        try finishSpacePlan(try await spacePlan(file: file, profiles: profiles, g), dryRun: true, g)
    }
}
