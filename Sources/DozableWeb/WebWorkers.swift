import DozableHost
import DozableKit
import Foundation

/// Adding and ending a workspace's worker from the dashboard — this Mac's own browser only. The `worker-add` action's
/// strict fields (also the plan route's body), the plan route `POST /api/v1/worker-plan` — exactly one
/// read-only HostOp, `worker-plan`, the one `doz worker add … --dry-run` sends — and its projection. The actions by
/// `WebExposure.decideWorkerAction` (403 `mac-only`), the route by its kind (`mac-screen`: it shows this Mac's bots,
/// sessions and folders). Never a token: a worker's is made by the daemon, or is its bot's own.
public enum WebWorkerAdd {
    /// The action's fields (besides `action`); the plan route takes them without `confirm`.
    static let fields: Set<String> = ["workspace", "name", "task", "agent", "isolation", "sandbox", "session", "cpus", "memory", "fromBot",
                                      "rooms", "allowTools", "confirm"]
    static let planFields: Set<String> = fields.subtracting(["confirm"])
    /// The longest task a browser sends: the JSON body stays within the actions' 16 KiB (beyond it, the page shows the
    /// command with the task in a file).
    public static let maximumTaskBytes = 15 << 10
    static let maximumRooms = 8
    static let maximumTools = 16
    /// What an unfenced worker's `confirm` must say: the person ticked "It acts as you".
    public static let unfencedConfirmation = "unfenced"

    /// The request the plan route sends (the plan reads, never writes).
    public static func planRequest(_ q: WorkerRequest) -> HostRequest {
        var r = HostRequest(.workerPlan)
        r.workerRequest = q
        return r
    }

    /// The plan route's body, strictly: the action's fields but `confirm` — the workspace by its rule (400 before any call).
    /// While the person types, the task and the name may be empty (the daemon's refusals say what is wanted).
    public static func decodePlan(_ body: Data) throws -> WorkerRequest {
        guard let obj = try? JSONSerialization.jsonObject(with: body), let d = obj as? [String: Any] else {
            throw WebAction.Invalid("the body must be a JSON object")
        }
        let extra = Set(d.keys).subtracting(planFields)
        guard extra.isEmpty else { throw WebAction.Invalid("unexpected field(s): \(extra.sorted().joined(separator: ", "))") }
        var q = try decode(WebAction.Fields(d), forPlan: true)
        q.workspace = try WebAction.Fields(d).workspaceName("workspace")
        return q
    }

    /// The fields as `doz worker add` takes them: the workspace by `WorkspaceName`; NAME and the bot by the chat rule; the
    /// task as text (line breaks and tabs) of at most 15 KiB; the agent claude-code or codex; the isolation fenced, vm or
    /// unfenced; a sandbox's name; a session on this Mac's name; 1–64 CPUs and a memory size (vm); ≤ 8 rooms by label;
    /// ≤ 16 allowed tools (1–200 characters, not starting with -). Which go together is the daemon's check, as for the CLI.
    static func decode(_ f: WebAction.Fields, forPlan: Bool) throws -> WorkerRequest {
        var q = WorkerRequest()
        if !forPlan { q.workspace = try f.workspaceName("workspace") }
        if !(forPlan && (f.d["name"] as? String) == "") { q.name = try f.string("name", max: 40).map { _ in try f.botName("name") } }
        q.task = try task(f, required: !forPlan)
        q.agent = try f.oneOf("agent", ["claude-code", "codex"])
        q.isolation = try f.oneOf("isolation", ["fenced", "vm", "unfenced"])
        q.sandbox = try f.string("sandbox", max: 40).map { _ in try f.sandbox("sandbox") }
        q.session = try f.string("session", max: 64).map { s in
            guard WebRoute.isMacSessionName(s) else { throw WebAction.Invalid("session: a session on this Mac — 1–32 of letters, digits . _ - (not starting with .)") }
            return s
        }
        q.cpus = try f.int("cpus", 1...64)
        q.memory = try f.string("memory", max: 16).map { m in
            guard m.range(of: "^[0-9]{1,7}(\\.[0-9]{1,2})?[MGmg]?$", options: .regularExpression) != nil, DozableImages.parseMemory(m) != nil else {
                throw WebAction.Invalid("memory: a size like 2G or 2048M")
            }
            return m
        }
        if !(forPlan && (f.d["fromBot"] as? String) == "") { q.fromBot = try f.string("fromBot", max: 40).map { _ in try f.botName("fromBot") } }
        let rooms = try WebWorkspaceNew.list(f, "rooms", maximumRooms)?.map { (x: Any) -> String in
            guard let s = x as? String, WebChatRoute.isRoom(s) else { throw WebAction.Invalid("rooms: room labels (a-z, 0-9, _ and -)") }
            return s
        } ?? []
        q.rooms = rooms.isEmpty ? nil : rooms
        let tools = try WebWorkspaceNew.list(f, "allowTools", maximumTools)?.map { (x: Any) -> String in
            guard let s = x as? String, (1...200).contains(s.count), !s.hasPrefix("-"),
                  !s.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
                throw WebAction.Invalid("allowTools: tool rules like Edit or Bash(git status:*), 1–200 characters each")
            }
            return s
        } ?? []
        q.allowTools = tools.isEmpty ? nil : tools
        return q
    }

    /// The task: text (line breaks and tabs, no other control character), at most 15 KiB; the action's not blank.
    static func task(_ f: WebAction.Fields, required: Bool) throws -> String? {
        guard let v = f.d["task"], !(v is NSNull) else {
            if required { throw WebAction.Invalid("task is required: what the worker is to do") }
            return nil
        }
        guard let s = v as? String else { throw WebAction.Invalid("task: text") }
        guard s.utf8.count <= maximumTaskBytes else {
            throw WebAction.Invalid("task: at most 15 KiB from the dashboard — longer, use the command with the task in a file")
        }
        guard !s.unicodeScalars.contains(where: { $0.properties.generalCategory == .control && !["\n", "\r", "\t"].contains($0) }) else {
            throw WebAction.Invalid("task: no control characters but line breaks and tabs")
        }
        if required, s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw WebAction.Invalid("task: what is it to do?") }
        return s
    }
}

/// `POST /api/v1/worker-plan`'s answer, field by field: what the add would do, or the first thing it would
/// refuse with the field it is about, and the command. The account by its name only; never a token.
public struct WebWorkerPlan: Codable, Equatable, Sendable {
    public struct Problem: Codable, Equatable, Sendable {
        public var field: String
        public var text: String
    }
    public var workspace: String
    public var name: String?
    public var agent: String?
    public var account: String?
    public var isolation: String?
    public var place: String?
    public var session: String?
    public var sandbox: String?
    public var folder: String?
    public var network: String?
    public var control: String?
    public var rooms: [String]
    public var allowTools: [String]
    public var actsAsYou: Bool
    public var shares: String?
    public var director: String?
    public var command: String
    /// The command reads the task from `task.txt` (over 1 KiB).
    public var taskInFile: Bool
    public var problem: Problem?
    public var notes: [String]
    public var lines: [String]

    public init(_ p: WorkerPlan, taskInFile: Bool) {
        workspace = p.workspace; name = p.name; agent = p.agent; account = p.account; isolation = p.isolation; place = p.place
        session = p.session; sandbox = p.sandbox; folder = p.folder; network = p.network; control = p.control; rooms = p.rooms
        allowTools = p.allowTools; actsAsYou = p.actsAsYou; shares = p.shares; director = p.director; command = p.command
        self.taskInFile = taskInFile
        problem = p.problem.map { Problem(field: $0.field, text: $0.text) }
        notes = p.notes; lines = p.lines
    }
}
