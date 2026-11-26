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
        if let a = IsolationWord.stored(asked) {
            guard let i = ManagerIsolation(rawValue: a) else {
                throw HostError(.invalid, "--manager-isolation is fenced, sandbox or unfenced, not \(a.prefix(40))")
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
    /// `session`: its session's name on this Mac (an unfenced Claude Code is named after it — `AgentLaunch.plan`).
    public static func plan(isolation: ManagerIsolation, agent: String, model: String?, bot: String, startFile: String, pagePort: Int,
                            fingerprint: String, tokenFile: String? = nil, session: String? = nil, readFiles: [String] = []) throws -> Plan {
        try AgentLaunch.plan(role: .manager, isolation: isolation, agent: agent, model: model, bot: bot, startFile: startFile, pagePort: pagePort,
                             fingerprint: fingerprint, tokenFile: tokenFile, allowedTools: ["Bash(dozchat:*)"], session: session,
                             readFiles: readFiles)
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
    /// Claude Code allow-list (last in argv — it takes every word after it; never on a VM, whose approvals are skipped);
    /// `readFiles`: the other files START tells it to read (the chat skills' — `AgentSkillFiles.paths`), each allowed by an
    /// exact `Read` rule beside START's own (`readRules`).
    public static func plan(role: Role, isolation: ManagerIsolation, agent: String, model: String?, bot: String?, startFile: String,
                            pagePort: Int, fingerprint: String, tokenFile: String? = nil,
                            variable: String = ManagerLaunch.tokenVariable, fileVariable: String = ManagerLaunch.tokenFileVariable,
                            allowedTools: [String], permissionMode: String? = nil, session: String? = nil,
                            readFiles: [String] = []) throws -> ManagerLaunch.Plan {
        guard let program = ManagerLaunch.program(agent: agent) else {
            throw HostError(.invalid, "Dozable does not start \(role == .manager ? "a manager" : "a worker") running \(agent) yet")
        }
        let prompt = ManagerLaunch.firstPrompt(start: startFile)
        let port = UInt16(clamping: pagePort)
        var argv = [program]
        if isolation == .unfenced, let session { argv = namedArgv(argv, session: session) }
        if let model, isolation != .vm { argv += ["--model", model] }
        argv.append(prompt)
        if program == "claude", isolation != .vm {
            // `bypass` (a space file's `permissions: bypass`): the worker's own argv, marked wherever its session shows
            // (`MacPlace.bypassesPermissions`); a VM's approvals are skipped already.
            if permissionMode == "bypass" { argv += ["--permission-mode", "bypassPermissions"] }
            else if isolation == .fenced { argv += ["--permission-mode", "dontAsk"] }
            // The allow-list takes every word after it: it goes last. Its START and the skill files START names are
            // outside its folder: under dontAsk an unlisted Read is refused (and unfenced it would stop to ask), so the
            // agent sat idle without its instructions — each gets an exact Read rule, nothing wider.
            argv += ["--allowedTools"] + allowedTools + readRules([startFile] + readFiles)
        }
        var env: [String: String] = [:]
        var secret: LaunchSecret?
        var ports: [UInt16] = []
        switch isolation {
        case .fenced, .vm:
            env["CHAT_URL"] = chatURL(isolation: isolation, pagePort: pagePort)
            ports = [port]
            secret = LaunchSecret(variable: variable, fileVariable: fileVariable, host: HostRoute.hostName, port: port,
                                  fingerprint: fingerprint, keychainService: nil, bot: bot)
        case .unfenced:
            guard let tokenFile else { throw HostError(.invalid, "an unfenced \(role.rawValue) needs its token file") }
            env[ManagerLaunch.tokenFileVariable] = tokenFile
            // 771: always — on the default port too: dozchat without it guesses, and says so.
            env["CHAT_URL"] = chatURL(isolation: isolation, pagePort: pagePort)
        }
        return ManagerLaunch.Plan(argv: argv, environment: env, startFile: startFile, hostPorts: ports, secret: secret)
    }

    /// Claude Code's rule that lets it Read exactly the file at each absolute path, and nothing else: `Read(//ABS)` — in a
    /// Read rule `//` starts an absolute path (a single `/` is relative to the project; probed against Claude Code 2.1.332:
    /// `Read(/ABS)` was refused, `Read(//ABS)` allowed, a path with a space included, and a sibling file still refused). A
    /// path that is not absolute, or that carries a character a rule would read as a pattern or its end, gets no rule (it
    /// would not match exactly); the paths Dozable writes are resolved and never carry one. In order, once each.
    public static func readRules(_ paths: [String]) -> [String] {
        let special: Set<Character> = ["*", "?", "[", "]", "{", "}", "(", ")", "\\", "!", "#"]
        var seen = Set<String>(), out: [String] = []
        for p in paths where p.hasPrefix("/") && !p.hasPrefix("//") && !p.contains(where: { special.contains($0) || $0.isNewline }) {
            if seen.insert(p).inserted { out.append("Read(/" + p + ")") }
        }
        return out
    }

    /// An unfenced Claude Code named after its session on this Mac (`--name S` right after the program, unless its argv
    /// names one already; any other program, or an empty name, unchanged). The chat server finds an inbox participant's
    /// session by the NAME in its record under ~/.claude/sessions, and a Claude Code started without one records a name it
    /// derives (its folder's name and a few hex), never the session's — so an inbox bot's messages failed "no running
    /// Claude session with that name", its presence said not running and its `/protocol` was refused.
    public static func namedArgv(_ argv: [String], session: String) -> [String] {
        guard !session.isEmpty, MacPlace.isClaude(argv), let p = MacPlace.programIndex(argv) else { return argv }
        let own = argv[(p + 1)...]
        if own.contains(where: { $0 == "--name" || $0 == "-n" || $0.hasPrefix("--name=") }) { return argv }
        return Array(argv[...p]) + ["--name", session] + Array(own)
    }

    /// 771: the chat server's address for an agent Dozable starts in a workspace place — THIS store's page port, never the
    /// default's guess: a fenced session or a VM reaches it by `host.dozable.internal`, an unfenced session on this Mac's
    /// loopback. Every session started in a workspace's place gets it (a manager, a worker, an adopted agent's place).
    public static func chatURL(isolation: ManagerIsolation, pagePort: Int) -> String {
        isolation == .unfenced ? "http://127.0.0.1:\(pagePort)" : "http://\(HostRoute.hostName):\(pagePort)"
    }

    /// The environment a session opened in a workspace's place gets beside what was asked: `CHAT_URL` (this store's page
    /// port) unless the session's own environment names one. nil: nothing to add (not a workspace's place, or chat off).
    public static func workspacePlaceEnvironment(member: Bool, chatOn: Bool, isolation: ManagerIsolation, pagePort: Int,
                                                 asked: [String: String]?) -> [String: String]? {
        guard member, chatOn, asked?["CHAT_URL"] == nil else { return nil }
        return ["CHAT_URL": chatURL(isolation: isolation, pagePort: pagePort)]
    }
}
