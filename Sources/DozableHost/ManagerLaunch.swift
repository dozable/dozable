import CryptoKit
import DozableKit
import Foundation

/// How a workspace's manager is launched — pure (`ManagerLaunchTests`): its isolation, its session's (or sandbox's) name,
/// its program, and the argv, environment, START file and ports of one launch. The token is never in any of it: a fenced
/// or VM manager gets a bot-held launch secret (a placeholder in `CHAT_TOKEN`, a file named by `CHAT_TOKEN_FILE`), an
/// unfenced one a 0600 file named by `CHAT_TOKEN_FILE` (`HostCore+WorkspaceManager`). `docs/engineering/workspaces.md`.
public enum ManagerIsolation: String, Codable, Equatable, Sendable, CaseIterable {
    case fenced, vm, unfenced

    /// The isolation a manager gets: as asked; else vm when the bot's default is vm; else fenced — never unfenced unless
    /// named (`--manager-isolation unfenced`), whatever the bot's default says.
    public static func resolve(asked: String?, botDefault: String) throws -> ManagerIsolation {
        if let a = asked {
            guard let i = ManagerIsolation(rawValue: a) else {
                throw HostError(.invalid, "--manager-isolation is fenced, vm or unfenced, not \(a.prefix(40))")
            }
            return i
        }
        return botDefault == "vm" ? .vm : .fenced
    }
}

public enum ManagerLaunch {
    /// The chat token's variables, as every chat-room member reads them (dozchat).
    public static let tokenVariable = "CHAT_TOKEN"
    public static let tokenFileVariable = "CHAT_TOKEN_FILE"
    /// The chat server's page port when nothing else is set (dozchat's own default address).
    public static let defaultPagePort = 8790
    /// The session's name inside a VM manager's sandbox.
    public static let vmSession = "manager"
    /// Where a VM manager's START is copied (under the image user's home).
    public static let vmStartFolder = ".doz-workspace"

    /// The manager's session (or sandbox) name: the workspace's name, or — over 32 characters (a session's limit) — its
    /// first 27, `-` and 4 hex of the name's SHA-256.
    public static func sessionName(workspace w: String) -> String {
        guard w.count > MacPlace.maximumSessionName else { return w }
        let h = SHA256.hash(data: Data(w.utf8)).map { String(format: "%02x", $0) }.joined()
        return String(w.prefix(27)) + "-" + h.prefix(4)
    }

    /// The program for an agent (`claude-code` → `claude`, `codex` → `codex`); nil: Dozable does not start a manager
    /// running it yet (its first prompt's form is not known).
    public static func program(agent: String) -> String? {
        var a = agent.lowercased()
        if let slash = a.lastIndex(of: "/") { a = String(a[a.index(after: slash)...]) }
        if let at = a.firstIndex(of: "@") { a = String(a[..<at]) }
        switch a {
        case "claude-code", "claude": return "claude"
        case "codex": return "codex"
        default: return nil
        }
    }

    /// The first prompt: read START and do what it says.
    public static func firstPrompt(start: String) -> String { "Read \(start) and do what it says." }

    /// One launch.
    public struct Plan: Equatable, Sendable {
        public var argv: [String]
        /// The environment it is opened with (never a token).
        public var environment: [String: String]
        /// Where START is put for it (a fenced session's `etc/manager/start.md`, a VM's `~/.doz-workspace/start.md`, an
        /// unfenced one's token folder).
        public var startFile: String
        /// This Mac's ports it reaches (fenced, VM: the chat server's page port).
        public var hostPorts: [UInt16]
        /// The bot-held launch secret (fenced, VM); nil: unfenced (its token is a file).
        public var secret: LaunchSecret?
    }

    /// The plan for `isolation`. `startFile`: where START goes (the core knows the session folder); `pagePort`: the chat
    /// server's; `tokenFile`: an unfenced manager's token file; `fingerprint`: the bot's token's.
    public static func plan(isolation: ManagerIsolation, agent: String, model: String?, bot: String, startFile: String, pagePort: Int,
                            fingerprint: String, tokenFile: String? = nil) throws -> Plan {
        try AgentLaunch.plan(role: .manager, isolation: isolation, agent: agent, model: model, bot: bot, startFile: startFile, pagePort: pagePort,
                             fingerprint: fingerprint, tokenFile: tokenFile, allowedTools: ["Bash(dozchat:*)"])
    }

    /// A VM manager started again after a stop: its program continues the conversation it had.
    public static func vmResumeArgv(agent: String) -> [String]? {
        guard let p = program(agent: agent) else { return nil }
        return p == "claude" ? ["claude", "--continue"] : [p, "resume", "--last"]
    }
}

/// One launch of an agent Dozable starts in a workspace — its manager or a worker: the same argv, environment, START and
/// ports, by role. Pure (`ManagerLaunchTests`, `WorkerLaunchTests`); the manager's plan is `ManagerLaunch.plan`, a worker's
/// `WorkerLaunch.plan`.
public enum AgentLaunch {
    public enum Role: String, Sendable { case manager, worker }

    /// `variable` / `fileVariable`: the token's (a worker sharing a sandbox has its own, `WorkerLaunch.tokenVariables`);
    /// `bot`: the bot whose token it is (nil: a worker's throwaway token, a daemon-made launch secret); `allowedTools`: a
    /// Claude Code allow-list (last in argv — it takes every word after it; never on a VM, whose approvals are skipped).
    public static func plan(role: Role, isolation: ManagerIsolation, agent: String, model: String?, bot: String?, startFile: String,
                            pagePort: Int, fingerprint: String, tokenFile: String? = nil,
                            variable: String = ManagerLaunch.tokenVariable, fileVariable: String = ManagerLaunch.tokenFileVariable,
                            allowedTools: [String], permissionMode: String? = nil) throws -> ManagerLaunch.Plan {
        guard let program = ManagerLaunch.program(agent: agent) else {
            throw HostError(.invalid, "Dozable does not start \(role == .manager ? "a manager" : "a worker") running \(agent) yet")
        }
        let prompt = ManagerLaunch.firstPrompt(start: startFile)
        let port = UInt16(clamping: pagePort)
        var argv = [program]
        if let model, isolation != .vm { argv += ["--model", model] }
        argv.append(prompt)
        if program == "claude", isolation != .vm {
            // `bypass` (a space file's `permissions: bypass`): the worker's own argv, marked wherever its session shows
            // (`MacPlace.bypassesPermissions`); a VM's approvals are skipped already.
            if permissionMode == "bypass" { argv += ["--permission-mode", "bypassPermissions"] }
            else if isolation == .fenced { argv += ["--permission-mode", "dontAsk"] }
            // The allow-list takes every word after it: it goes last.
            argv += ["--allowedTools"] + allowedTools
        }
        var env: [String: String] = [:]
        var secret: LaunchSecret?
        var ports: [UInt16] = []
        switch isolation {
        case .fenced, .vm:
            env["CHAT_URL"] = "http://\(HostRoute.hostName):\(pagePort)"
            ports = [port]
            secret = LaunchSecret(variable: variable, fileVariable: fileVariable, host: HostRoute.hostName, port: port,
                                  fingerprint: fingerprint, keychainService: nil, bot: bot)
        case .unfenced:
            guard let tokenFile else { throw HostError(.invalid, "an unfenced \(role.rawValue) needs its token file") }
            env[ManagerLaunch.tokenFileVariable] = tokenFile
            if pagePort != ManagerLaunch.defaultPagePort { env["CHAT_URL"] = "http://127.0.0.1:\(pagePort)" }
        }
        return ManagerLaunch.Plan(argv: argv, environment: env, startFile: startFile, hostPorts: ports, secret: secret)
    }
}
