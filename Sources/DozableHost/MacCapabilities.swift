import DozableKit
import Foundation

/// 683 (owner: "there will be semantic meaning in the UI for these capabilities as applied to host sessions") — one row of
/// "What this session can do": a named state, the plain sentence of what that state OPENS, and whether it changes live or
/// at the next start. The vocabulary is the sandboxes' where one exists.
public struct MacCapability: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    /// The chip word (`fenced`, `closed`, `through Dozable's proxy (standard)`, `private`, …).
    public var state: String
    public var sentence: String
    /// `live` (changed while it runs) or `restart` (at the next start).
    public var editable: String
    /// How to look or change it (a command), when there is one.
    public var link: String? = nil
}

/// What a session's capabilities are computed from — a record (a running or ended session), or a request with the
/// settings (`doz run @mac … --dry-run`: the session it WOULD open). One shape, so every view says the same.
public struct MacCapabilityShape: Sendable, Equatable {
    public var session: String
    public var workdir: String
    public var fenced: Bool
    public var keychain = false
    public var readable: [String] = []
    public var writable: [String] = []
    public var localPorts: [Int] = []
    /// The network: its preset (nil: custom), whether a host serves it now (`proxy`, `waiting (no host)`, nil), and its
    /// allowed and denied sites (live counts, when a host serves it).
    public var preset: String? = nil
    public var hasNetwork = true
    public var network: String? = nil
    /// Its agent (a recipe's title), the config folder's mode and the person's folder; the history value; the login.
    public var agent: String? = nil
    public var agentConfig: String? = nil
    public var personHome: String? = nil
    public var history: String? = nil
    public var claude = false
    public var account: String? = nil
    public var bridges = MacFenceBridges(openURL: false, openFiles: false, clipboard: false)
    /// 683 M4: its profile (`agent`, `xcode`, `simulator`), GitHub as the person (`read` | `push`; nil: off), the SSH agent.
    public var profile = MacFence.profileKind
    public var github: String? = nil
    public var sshAgent = false
    public init(session: String, workdir: String, fenced: Bool) {
        self.session = session
        self.workdir = workdir
        self.fenced = fenced
    }

    /// A session's shape from its record (`home`: the person's home, for the agent folder's name).
    public init(session: String, record r: MacSessionRecord, home: String?) {
        self.init(session: session, workdir: r.workdir, fenced: r.fence != nil)
        claude = MacPlace.isClaude(r.argv)
        guard let f = r.fence else { return }
        keychain = f.keychain
        readable = f.readable
        writable = f.writable
        localPorts = f.localPorts ?? []
        hasNetwork = f.proxyPort != nil
        preset = f.policy.flatMap { $0.permissions.flatMap { AgentPermissions.presetName($0, base: AgentPermissions.macBase) } }
        network = f.proxyPort == nil ? nil : "waiting (no host)"
        if let id = f.agent, let recipe = AgentRecipes.macAgent(program: id), let m = recipe.launch.macConfig {
            agent = recipe.title
            personHome = home.map { $0 + "/" + m.homeName }
        }
        agentConfig = f.agentConfig
        history = f.history
        account = f.account
        bridges = f.bridges ?? MacFenceBridges(openURL: false, openFiles: false, clipboard: false)
        profile = f.profile
        github = f.github
        sshAgent = f.sshAgent == true
    }

    /// The session a `doz run @mac` WOULD open — `--dry-run`, and the dashboard's New session wizard — from its fence
    /// request (`agentConfig`/`history`/`account` as the flags gave them, nil: the settings) and the settings. One shape
    /// for both, so the page says exactly what the CLI says. `home`: the person's home (the agent folder's name).
    public static func planned(session: String, workdir: String, argv: [String], fenced: Bool, request q: MacFenceRequest?,
                               settings: DozableSettings, home: String) -> MacCapabilityShape {
        var s = MacCapabilityShape(session: session, workdir: workdir, fenced: fenced)
        s.claude = MacPlace.isClaude(argv)
        guard fenced, let q else { return s }
        s.keychain = q.keychain == true
        s.readable = q.read ?? []
        s.writable = q.write ?? []
        s.localPorts = q.localPorts ?? []
        s.preset = (try? MacFenceNetwork.policy(words: q.permissions ?? ["standard"]))
            .flatMap { p in p.permissions.flatMap { AgentPermissions.presetName($0, base: AgentPermissions.macBase) } }
        s.bridges = MacFenceBridges.resolve(q, settings: settings)
        s.profile = q.profile
        s.github = q.github
        s.sshAgent = q.sshAgent == true
        if let program = argv.first, let r = AgentRecipes.macAgent(program: program), let m = r.launch.macConfig {
            s.agent = r.title
            s.agentConfig = MacAgentConfig.resolveMode(flag: q.agentConfig, recipe: r, settings: settings).0
            s.personHome = home + "/" + m.homeName
            s.history = settings.history(agent: r.id, own: q.history.map { TOMLValue.string($0) }).value
            s.account = q.account ?? settings.string(SettingKey.macAccount) ?? "mac"
        }
        return s
    }
}

extension MacFence {
    /// "What this session can do" — the ONE source of the capability list: `doz sessions @mac --json`'s `capabilities`,
    /// `--capabilities`, `doz run @mac --dry-run` and the dashboard all show this.
    public static func capabilities(_ s: MacCapabilityShape) -> [MacCapability] {
        func c(_ id: String, _ name: String, _ state: String, _ sentence: String, live: Bool = false, link: String? = nil) -> MacCapability {
            MacCapability(id: id, name: name, state: state, sentence: sentence, editable: live ? "live" : "restart", link: link)
        }
        let folder = DisplayPath.tilde(s.workdir)
        guard s.fenced else {
            return [
                c("fence", "Fence", "no isolation", "Runs as you: your files, Keychain and network."),
                c("keychain", "Keychain", "open", "Can use your Keychain — signing works, and so could reading your saved logins."),
                c("network", "Network", "direct", "Reaches the network as you do; nothing is logged."),
                c("agent-config", "Agent config", "your own", "Uses your own settings folder, as you would."),
                c("history", "History", "the agent's own", "Its conversations stay where the agent keeps them."),
                c("claude-login", "Claude login", s.claude ? "its own Keychain login" : "none", s.claude ? "Signs in with this Mac's Claude Code login, read by the program itself." : "Not a Claude session."),
                c("github", "GitHub as you", "as you", "Uses whatever GitHub login this Mac has."),
                c("ssh-agent", "SSH agent", "yours", "Can use your SSH agent and keys."),
                c("open-url", "Open a URL", "off", "Opens pages itself (it runs as you) — Dozable does not announce them.", live: true),
                c("open-files", "Open files", "off", "Opens files itself (it runs as you).", live: true),
                c("clipboard", "Clipboard", "write on", "Can put text on your clipboard (never read it through Dozable); each copy is announced.", live: true),
                c("writable", "Writable", "everything you can write", "Can change any file you can."),
                c("readable", "Readable extras", "everything you can read", "Can read any file you can."),
            ]
        }
        var out: [MacCapability] = []
        switch s.profile {
        case "xcode":
            out.append(c("fence", "Fence", "fenced (Xcode)", "Held to its folder and Dozable's proxy; Xcode's build services open, LaunchServices and the Simulator closed."))
        case "simulator":
            out.append(c("fence", "Fence", "guard rail (Simulator)",
                         "Held to its folder and Dozable's proxy — but the Simulator and what it launches run outside it: a guard rail, not a boundary."))
        default:
            out.append(c("fence", "Fence", "fenced", "Held to its folder and Dozable's proxy."))
        }
        out.append(s.keychain
                   ? c("keychain", "Keychain", "open", "Can use your Keychain — signing works, and so could reading your saved logins.")
                   : c("keychain", "Keychain", "closed", "Cannot read your passwords, keys or signing identities."))
        let ports = s.localPorts.isEmpty ? "" : "; local ports opened: " + s.localPorts.map(String.init).joined(separator: ", ")
        if !s.hasNetwork {
            out.append(c("network", "Network", "none", "Has no network (opened before fenced sessions had one) — a restart gives it one."))
        } else if s.preset == "locked" {
            out.append(c("network", "Network", "none beyond its model (locked)" + ports, "Reaches only its AI model; every connection is logged.",
                         live: true, link: "doz net log @mac --session \(s.session)"))
        } else {
            let wait = s.network == "waiting (no host)" ? " — waiting for a host" : ""
            // The preset by the name a person reads (`agent` is Standard's stored name).
            let preset = s.preset == "agent" ? "standard" : s.preset ?? "custom"
            out.append(c("network", "Network", "through Dozable's proxy (\(preset))" + ports + wait,
                         "Reaches only what its permissions allow; every connection is logged; never this Mac's own addresses.",
                         live: true, link: "doz net log @mac --session \(s.session)"))
        }
        if let a = s.agent {
            let home = s.personHome.map { DisplayPath.tilde($0) } ?? "its usual folder"
            out.append(s.agentConfig == MacAgentConfig.sharedMode
                       ? c("agent-config", "Agent config", "shared (less isolated)", "Uses your own \(home) — what it writes there runs in your next \(a) outside the fence.")
                       : c("agent-config", "Agent config", "private", "Its own \(a) settings folder; your instructions and skills read-only, its settings changes refused."))
            let h = s.history ?? AgentHistory.keep
            let dest = s.personHome.map { DisplayPath.tilde($0) + "/projects/…" } ?? "your own folder"
            if s.agentConfig == MacAgentConfig.sharedMode {
                out.append(c("history", "History", h, "Its conversations are written straight into your own folder; \(a) keeps them by its own rule there."))
            } else {
                out.append(c("history", "History", h, h == AgentHistory.keep
                             ? "Its conversations are copied to \(dest) and kept in Dozable's archive when it ends."
                             : "Its conversations are copied to \(dest) when it ends; \(a)'s own rule decides how long they stay there."))
            }
        } else {
            out.append(c("agent-config", "Agent config", "none", "Its program keeps no config Dozable knows of; your settings folders stay closed."))
            out.append(c("history", "History", "none", "Nothing of its conversations is carried back."))
        }
        if s.claude {
            if let acc = s.account, acc != "none" {
                out.append(c("claude-login", "Claude login", "swapped in (account \(acc))", "Signs in as \(acc) through the proxy; the program never sees the token."))
            } else {
                out.append(c("claude-login", "Claude login", "none", "No Claude login is given to it (doz run @mac --account NAME gives one)."))
            }
        } else {
            out.append(c("claude-login", "Claude login", "none", "Not a Claude session: no login is given to it."))
        }
        switch s.github {
        case "push"?: out.append(c("github", "GitHub as you", "push", "Clones, reads and pushes as you through the proxy; the program never sees the token."))
        case "read"?: out.append(c("github", "GitHub as you", "read", "Clones and reads as you; pushes are refused."))
        default: out.append(c("github", "GitHub as you", "off", "Cannot use your GitHub login; a push over https has no credential."))
        }
        out.append(s.sshAgent
                   ? c("ssh-agent", "SSH agent", "on (list + sign only)", "Can sign with your SSH keys, never read or add them; ssh goes through the proxy.")
                   : c("ssh-agent", "SSH agent", "off", "Cannot use your SSH keys."))
        out.append(s.bridges.openURL
                   ? c("open-url", "Open a URL", "on", "Can open web pages in your browser — each one is announced.", live: true, link: "doz sessions bridges @mac \(s.session)")
                   : c("open-url", "Open a URL", "off", "Cannot open pages in your browser.", live: true, link: "doz sessions bridges @mac \(s.session)"))
        out.append(s.bridges.openFiles
                   ? c("open-files", "Open files", "on (scoped to the folder)", "Can open documents from \(folder) in your apps — each one is announced.", live: true, link: "doz sessions bridges @mac \(s.session)")
                   : c("open-files", "Open files", "off", "Cannot open files in your apps.", live: true, link: "doz sessions bridges @mac \(s.session)"))
        out.append(s.bridges.clipboard
                   ? c("clipboard", "Clipboard", "write on", "Can put text on your clipboard (never read it); each copy is announced.", live: true, link: "doz sessions bridges @mac \(s.session)")
                   : c("clipboard", "Clipboard", "off", "Cannot put anything on your clipboard.", live: true, link: "doz sessions bridges @mac \(s.session)"))
        let w = [folder] + s.writable.map { DisplayPath.tilde($0) }
        out.append(c("writable", "Writable", w.joined(separator: ", "), "Can change files in \(w.joined(separator: " and ")) (and its own temp and caches)."))
        out.append(s.readable.isEmpty
                   ? c("readable", "Readable extras", "none", "Reads only its folders, the system and your tools.")
                   : c("readable", "Readable extras", s.readable.map { DisplayPath.tilde($0) }.joined(separator: ", "), "Can read \(s.readable.map { DisplayPath.tilde($0) }.joined(separator: " and "))."))
        return out
    }

    /// The capabilities as text (`--capabilities`, `--dry-run`): one line per capability.
    public static func capabilitiesText(_ list: [MacCapability]) -> String {
        let width = list.map(\.name.count).max() ?? 0
        return list.map { c in
            c.name.padding(toLength: width, withPad: " ", startingAt: 0) + "  " + c.state + " — " + c.sentence
                + (c.editable == "live" ? " (live)" : " (at the next start)")
        }.joined(separator: "\n") + "\n"
    }
}
