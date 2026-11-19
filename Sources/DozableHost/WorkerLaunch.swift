import CryptoKit
import Foundation

/// How a worker (`doz worker add`) is launched — pure (`WorkerLaunchTests`): its isolation, its place's names, its token's
/// variables, an anonymous worker's name, the flags that do not go together, and the argv, environment and ports of one
/// launch (`AgentLaunch.plan`, the manager's builders). The token is never in any of it. `docs/engineering/workspaces.md`
/// ("Workers").
public enum WorkerIsolation {
    /// The isolation a worker gets — the narrowest unless asked: as asked; else vm when the workspace's default or (from a
    /// bot) the bot's default is vm; else fenced. Never unfenced unless named (`--isolation unfenced`), whatever a default
    /// says.
    public static func resolve(asked: String?, workspaceDefault: String?, botDefault: String?) throws -> ManagerIsolation {
        if let a = asked {
            guard let i = ManagerIsolation(rawValue: a) else {
                throw HostError(.invalid, "--isolation is fenced, vm or unfenced, not \(a.prefix(40))")
            }
            return i
        }
        return workspaceDefault == "vm" || botDefault == "vm" ? .vm : .fenced
    }
}

public enum WorkerLaunch {
    /// What a fenced Claude Code worker may do without asking: talk in chat. `--allow-tool` adds to it.
    /// OPEN WITH THE OWNER (a default set — edit, write, a shell inside the fence — instead): this ONE constant is the change.
    public static let defaultAllowedTools = ["Bash(dozchat:*)"]
    /// The longest task (`--task`), in bytes.
    public static let maximumTaskBytes = 16 << 10
    /// Where a VM worker's START is copied (under the image user's home): `~/.doz-workspace/NAME/start.md`.
    public static let vmStartFolder = ManagerLaunch.vmStartFolder

    /// A worker's own place: `W-NAME` (a session on this Mac, or a new sandbox), or — over 32 characters (a session's limit)
    /// — its first 27, `-` and 4 hex of the whole name's SHA-256.
    public static func placeName(workspace w: String, name: String) -> String {
        let full = w + "-" + name
        guard full.count > MacPlace.maximumSessionName else { return full }
        let h = SHA256.hash(data: Data(full.utf8)).map { String(format: "%02x", $0) }.joined()
        return String(full.prefix(27)) + "-" + h.prefix(4)
    }

    /// The token's variables: `CHAT_TOKEN` / `CHAT_TOKEN_FILE` in a place of its own; in a shared sandbox its own pair,
    /// `CHAT_TOKEN_<NAME>` / `CHAT_TOKEN_FILE_<NAME>` (upper case, `-` → `_`) — aliased to the plain pair for its session only.
    public static func tokenVariables(name: String, shared: Bool) -> (variable: String, fileVariable: String) {
        guard shared else { return (ManagerLaunch.tokenVariable, ManagerLaunch.tokenFileVariable) }
        let suffix = name.uppercased().replacingOccurrences(of: "-", with: "_")
        return (ManagerLaunch.tokenVariable + "_" + suffix, ManagerLaunch.tokenFileVariable + "_" + suffix)
    }

    /// An anonymous worker's name: the first free `botN` (N from 1).
    public static func nextAnonymousName(taken: Set<String>) -> String {
        var n = 1
        while taken.contains("bot\(n)") { n += 1 }
        return "bot\(n)"
    }

    /// What was asked, as the flags give it.
    public struct Flags: Equatable, Sendable {
        public var isolation: String?
        public var sandbox: String?
        public var session: String?
        public var cpus: Int?
        public var memory: String?
        public var agent: String?
        public var fromBot: String?
        public var name: String?
        public var allowTools: [String]
        public init(isolation: String? = nil, sandbox: String? = nil, session: String? = nil, cpus: Int? = nil, memory: String? = nil,
                    agent: String? = nil, fromBot: String? = nil, name: String? = nil, allowTools: [String] = []) {
            self.isolation = isolation; self.sandbox = sandbox; self.session = session; self.cpus = cpus; self.memory = memory
            self.agent = agent; self.fromBot = fromBot; self.name = name; self.allowTools = allowTools
        }
    }

    /// The flags that do not go together (nil: none), given the isolation they resolve to and the program it runs.
    public static func flagProblems(_ f: Flags, isolation: ManagerIsolation, program: String?) -> String? {
        if f.sandbox != nil {
            if f.isolation != nil { return "--sandbox or --isolation, not both: a worker in a sandbox has the sandbox's isolation" }
            if f.cpus != nil || f.memory != nil { return "--cpus and --memory are for a new sandbox, not --sandbox (it keeps its own)" }
            if f.session != nil { return "--session names a session on this Mac; in --sandbox X the worker's session is its name" }
        }
        else if isolation != .vm, f.cpus != nil || f.memory != nil {
            return "--cpus and --memory go with --isolation vm (a sandbox of its own)"
        } else if isolation == .vm, f.session != nil {
            return "--session names a session on this Mac; a VM worker's sandbox is named for it"
        }
        if let b = f.fromBot {
            if f.agent != nil { return "--agent goes with an anonymous worker; \(b) runs its own agent" }
            if let n = f.name, n != b { return "a worker from a bot takes the bot's name: leave NAME out, or give \(b)" }
        }
        if !f.allowTools.isEmpty {
            guard f.sandbox == nil, isolation == .fenced, program == "claude" else {
                return "--allow-tool goes with a fenced Claude Code worker (on this Mac)"
            }
            for t in f.allowTools {
                guard (1...200).contains(t.count), !t.hasPrefix("-"), !t.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
                    return "--allow-tool \(t.prefix(40)): a tool rule like Edit or \"Bash(git status:*)\" (1–200 characters)"
                }
            }
        }
        return nil
    }

    /// One worker's launch: `AgentLaunch.plan` with its role, its token's variables and its allow-list (the default list,
    /// then `--allow-tool`; only a fenced one takes any beyond the default).
    public static func plan(isolation: ManagerIsolation, agent: String, model: String?, bot: String?, startFile: String, pagePort: Int,
                            fingerprint: String, tokenFile: String? = nil, name: String, shared: Bool,
                            allowTools: [String] = []) throws -> ManagerLaunch.Plan {
        let v = tokenVariables(name: name, shared: shared)
        return try AgentLaunch.plan(role: .worker, isolation: isolation, agent: agent, model: model, bot: bot, startFile: startFile,
                                    pagePort: pagePort, fingerprint: fingerprint, tokenFile: tokenFile, variable: v.variable,
                                    fileVariable: v.fileVariable, allowedTools: defaultAllowedTools + (isolation == .fenced ? allowTools : []))
    }

    /// What isolates it, as a person reads it (`doz worker ls`'s CONTROL).
    public static func control(isolation: String?, shares: String? = nil) -> String {
        let base: String
        switch isolation {
        case "vm": base = "micro VM · proxy · placeholders"
        case "unfenced": base = "no proxy · no placeholders · no guard · acts as you"
        case "fenced": base = "proxy · placeholders · guard"
        default: base = "—"
        }
        return base + (shares.map { " · shares \($0)" } ?? "")
    }

    /// The task as a list shows it: its first line, at most `limit` characters.
    public static func shortTask(_ t: String, limit: Int = 48) -> String {
        let first = t.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        return first.count > limit ? String(first.prefix(limit - 1)) + "…" : first
    }
}
