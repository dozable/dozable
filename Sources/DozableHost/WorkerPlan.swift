import Foundation

// Adding a worker, looked at before it is added: `worker-plan` (the dashboard's Add a worker page, `doz worker add …
// --dry-run`) answers what `worker-add` would decide with the same `WorkerRequest` — its name, program, account, isolation,
// place, folder, network, control, rooms and allow-list — or the first thing it would refuse, with the field it is about.
// It runs the add's own checks (`HostCore.workerPrepare`), writes nothing, makes no participant, reads no keychain item
// and starts nothing. ONE command source: `WorkerAddCommand` (the plan's `command`, `--dry-run`, the page's Show the
// command). `docs/engineering/workspaces.md` ("Adding one: the plan and the dry run").

/// A refusal of an add, tagged with the request's field it is about (`task`, `name`, `isolation`, …; `workspace` for one
/// about the workspace or chat). `HostError.from` gives back the add's own error, so the add answers exactly as before.
public struct WorkerFieldRefusal: Error, Sendable {
    public var field: String
    public var error: HostError
    public init(_ field: String, _ error: HostError) { self.field = field; self.error = error }
    /// Any error thrown by a check, tagged with `field` (one already tagged keeps its own).
    static func tag(_ field: String, _ error: Error) -> WorkerFieldRefusal {
        if let t = error as? WorkerFieldRefusal { return t }
        return WorkerFieldRefusal(field, HostError.from(error))
    }
}

/// What `worker-plan` refuses: the add's own sentence and code, and the field it is about.
public struct WorkerPlanProblem: Codable, Equatable, Sendable {
    public var field: String
    public var text: String
    /// `HostError.Code`'s raw value, so a dry run exits as the add would.
    public var code: String
    public init(field: String, text: String, code: String) { self.field = field; self.text = text; self.code = code }
}

/// `worker-plan`'s answer. Nothing was written, no participant made, no keychain item read, nothing started. The decided
/// fields are nil when a refusal came before they were decided.
public struct WorkerPlan: Codable, Equatable, Sendable {
    public var workspace: String
    /// Its name in chat (an anonymous worker's first free `botN`, or the bot's).
    public var name: String?
    public var agent: String?
    /// The account it would use, by name only (`mac` = this Mac's own login) — never a value. nil: unfenced (it acts as you).
    public var account: String?
    /// `fenced`, `vm` or `unfenced`.
    public var isolation: String?
    /// As a person types it: `@mac/SESSION` or a sandbox's name.
    public var place: String?
    /// Its session: on this Mac, or in a sandbox (its name).
    public var session: String?
    /// Its sandbox (its own, or the one it shares).
    public var sandbox: String?
    /// Its folder: the workspace's main one, else `<projects_dir>/W/NAME` (made at the add).
    public var folder: String?
    /// Its network permissions (unfenced: `not limited`).
    public var network: String?
    /// What isolates it (`WorkerLaunch.control`).
    public var control: String?
    /// The rooms it is invited to (the main room first), by their chat names.
    public var rooms: [String]
    /// What it may do without asking (a fenced Claude Code worker: the default list, then `allowTools`).
    public var allowTools: [String]
    public var actsAsYou: Bool
    /// The sandbox it shares with other agents of the workspace (they can read each other's placeholders).
    public var shares: String?
    /// Who directs it: the manager's bot while it runs, else `you`.
    public var director: String?
    /// The command that adds the same worker (`WorkerAddCommand.text`).
    public var command: String
    /// What the add would refuse (nil: it would be added).
    public var problem: WorkerPlanProblem?
    public var notes: [String]
    /// The plan as a person reads it, one line each.
    public var lines: [String]
    public init(workspace: String, command: String) {
        self.workspace = workspace; self.command = command
        rooms = []; allowTools = []; actsAsYou = false; notes = []; lines = []
    }
}

/// The command that adds a worker — the ONE source the plan answer, `--dry-run` and the dashboard's Show the command share.
public enum WorkerAddCommand {
    /// A task longer than this goes in a file (`--task="$(cat task.txt)"`) in the command a person copies.
    public static let inlineTaskBytes = 1024
    public static let taskFile = "task.txt"

    /// The argument vector (`doz worker add W [NAME] --task TASK …`), in the parser's order.
    public static func argv(_ q: WorkerRequest) -> [String] {
        var a = ["doz", "worker", "add", q.workspace ?? "WORKSPACE"]
        if let n = q.name, !n.isEmpty { a.append(n) }
        let task = q.task ?? ""
        a += task.hasPrefix("-") ? ["--task=" + task] : ["--task", task]   // a task like "-x" is never read as an option
        if let x = q.agent { a += ["--agent", x] }
        if let x = q.isolation { a += ["--isolation", x] }
        if let x = q.sandbox { a += ["--sandbox", x] }
        if let x = q.session { a += ["--session", x] }
        if let x = q.cpus { a += ["--cpus", String(x)] }
        if let x = q.memory { a += ["--memory", x] }
        if let x = q.fromBot { a += ["--from-bot", x] }
        for r in q.rooms ?? [] { a += ["--room", r] }
        for t in q.allowTools ?? [] { a += ["--allow-tool", t] }
        return a
    }

    /// Whether the command reads the task from `task.txt`.
    public static func taskInFile(_ q: WorkerRequest) -> Bool { (q.task ?? "").utf8.count > inlineTaskBytes }

    /// The command as a person pastes it: the argv quoted for a POSIX shell; a long task read from `task.txt`.
    public static func text(_ q: WorkerRequest) -> String {
        let a = argv(q)
        let long = taskInFile(q)
        var out: [String] = []
        var i = 0
        while i < a.count {
            if long, a[i] == "--task" || a[i].hasPrefix("--task=") {
                out.append("--task=\"$(cat \(taskFile))\"")
                i += a[i] == "--task" ? 2 : 1
                continue
            }
            out.append(WorkspaceNewCommand.quote(a[i]))
            i += 1
        }
        return out.joined(separator: " ")
    }

    /// What to say beside a command whose task is in a file.
    public static func taskFileNote(_ q: WorkerRequest) -> String? {
        taskInFile(q) ? "the task is over \(inlineTaskBytes >> 10) KiB: save it as \(taskFile) in the folder you run the command from" : nil
    }
}

/// The plan's lines (display only: paths with `~`).
enum WorkerPlanLines {
    static func lines(_ p: WorkerPlan) -> [String] {
        guard let name = p.name else { return [] }
        var out: [String] = []
        out.append("worker \(name) in \(p.workspace)" + (p.director.map { " — directed by \($0)" } ?? ""))
        out.append("agent: \(p.agent ?? "claude-code") · account: \(p.account ?? "yours (it acts as you)")")
        let iso = p.isolation == "vm" ? "micro VM" : p.isolation == "unfenced" ? "unfenced · acts as you" : p.isolation ?? "fenced"
        out.append("runs: \(iso) — \(p.place ?? "?")" + (p.shares != nil ? " (shared)" : ""))
        out.append("control: \(p.control ?? "—")")
        out.append("folder: \(DisplayPath.tilde(p.folder ?? "—"))")
        out.append("network: \(p.network ?? "—") + the room")
        out.append("rooms: " + p.rooms.map { "#" + $0 }.joined(separator: ", "))
        if !p.allowTools.isEmpty { out.append("allowed without asking: " + p.allowTools.joined(separator: ", ")) }
        return out
    }
}
