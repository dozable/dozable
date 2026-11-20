import DozableKit
import Foundation

// `workspace-reach` (read-only): what each agent of a workspace can reach and hold — its isolation and control, its folders,
// its network (the preset and sites, this Mac's ports, the forwarded ports, what it was refused lately) and the secrets it
// holds as placeholders, BY NAME — and "what it can do" as one table per agent (`AgentCapabilities.rows`). Never a value:
// a secret is a name, where it goes, its header and (a given one only) a fingerprint; a chat token's fingerprint is never
// carried. The field is `held`, never `secrets`. Built from the record, the sandboxes' and sessions' records, the live
// proxies (the daemon's only) — `HostCore+WorkspaceViews`. docs/engineering/workspaces.md, "Workspace-wide views".

/// `workspace-reach`'s answer.
public struct WorkspaceReach: Codable, Equatable, Sendable {
    public struct Defaults: Codable, Equatable, Sendable {
        /// The isolation and network a new worker gets (`defaults.isolation` else fenced; `defaults.network` else locked).
        public var isolation: String
        public var network: String
        public init(isolation: String, network: String) { self.isolation = isolation; self.network = network }
    }
    public var workspace: String
    public var agents: [AgentReach]
    public var defaults: Defaults
    /// Whether the refusals are known: only a running daemon holds its proxies' logs (false in-process: "not known").
    public var refusalsKnown: Bool
    public var notes: [String]?
    public init(workspace: String, agents: [AgentReach], defaults: Defaults, refusalsKnown: Bool, notes: [String]? = nil) {
        self.workspace = workspace; self.agents = agents; self.defaults = defaults; self.refusalsKnown = refusalsKnown; self.notes = notes
    }
}

/// One agent's reach.
public struct AgentReach: Codable, Equatable, Sendable {
    public var name: String
    public var role: String
    /// `vm`, `fenced`, `unfenced` or `elsewhere`.
    public var isolation: String
    /// As a person types it (`wsa`, `@mac/wsu`, `elsewhere`).
    public var place: String
    /// `sandbox`, `mac` or `elsewhere`.
    public var kind: String
    /// What isolates it, as a person reads it (`WorkerLaunch.control`; elsewhere "not run by Dozable · token only").
    public var control: String
    /// An unfenced agent acts as you — said wherever it shows.
    public var actsAsYou: Bool
    /// Its place's state (`running`, `ended`, a phase, `gone`, `not started`, `elsewhere`).
    public var state: String
    /// What it can do, one row per capability (`AgentCapabilities.rows` — for an `@mac` agent `MacFence.capabilities` unchanged).
    public var capabilities: [MacCapability]
    public var network: AgentNetworkReach
    /// The secrets Dozable holds for it (it sees placeholders): by name, never a value.
    public var held: [HeldSecret]
    public var folders: [ReachFolder]
    /// The Claude account it is given, by name (`mac` — this Mac's own login; nil: none, or its own).
    public var account: String?
    /// The chat rooms it is in, by the chat server's names.
    public var rooms: [String]
    public init(name: String, role: String, isolation: String, place: String, kind: String, control: String, actsAsYou: Bool, state: String,
                capabilities: [MacCapability], network: AgentNetworkReach, held: [HeldSecret], folders: [ReachFolder], account: String?, rooms: [String]) {
        self.name = name; self.role = role; self.isolation = isolation; self.place = place; self.kind = kind; self.control = control
        self.actsAsYou = actsAsYou; self.state = state; self.capabilities = capabilities; self.network = network; self.held = held
        self.folders = folders; self.account = account; self.rooms = rooms
    }
}

public struct AgentNetworkReach: Codable, Equatable, Sendable {
    /// Through Dozable's proxy (a VM's or a fenced session's): its sites and refusals are known; unfenced and elsewhere: not.
    public var proxied: Bool
    /// Whether the policy shown is the one a running proxy serves now (else the record's: from its next start).
    public var live: Bool
    /// `locked` · `agent` (Standard) · `open`; nil: custom, or not proxied.
    public var preset: String?
    /// The sites allowed beyond its preset (`site:` rules, as strings: `HOST` or `HOST:PORTS`).
    public var sites: [String]
    /// The ports of this Mac it reaches as `host.dozable.internal:PORT`.
    public var hostPorts: [HostPort]
    /// A sandbox's ports forwarded out to this Mac (`local`: the Mac's port, nil while it does not listen).
    public var forwarded: [ReachForward]
    /// What it was refused lately (the daemon's proxy log; empty in-process), with the grant that would allow it.
    public var refused: [ReachRefusal]
    public init(proxied: Bool, live: Bool, preset: String?, sites: [String], hostPorts: [HostPort], forwarded: [ReachForward], refused: [ReachRefusal]) {
        self.proxied = proxied; self.live = live; self.preset = preset; self.sites = sites; self.hostPorts = hostPorts
        self.forwarded = forwarded; self.refused = refused
    }
    public static let none = AgentNetworkReach(proxied: false, live: false, preset: nil, sites: [], hostPorts: [], forwarded: [], refused: [])
}

public struct ReachForward: Codable, Equatable, Sendable {
    public var port: Int
    public var local: Int?
    public init(port: Int, local: Int?) { self.port = port; self.local = local }
}

public struct ReachRefusal: Codable, Equatable, Sendable {
    public var host: String
    public var port: Int?
    public var count: Int
    public var lastAt: Date?
    /// What `doz net allow` would take (`site:HOST`, `site:HOST:PORT`, a permission's id, `host:PORT`).
    public var grant: String
    public init(host: String, port: Int?, count: Int, lastAt: Date?, grant: String) {
        self.host = host; self.port = port; self.count = count; self.lastAt = lastAt; self.grant = grant
    }
}

/// A secret Dozable holds for an agent: its name, where it goes and its header — never its value.
public struct HeldSecret: Codable, Equatable, Sendable {
    public var name: String
    public var to: String
    public var header: String
    /// The first 12 hex of the value's sha256 — a given secret's only; never a chat token's.
    public var fingerprint: String?
    /// `given` (`--secret`), `chat-bot` (a bot's chat token, held in its own item), `chat-worker` (a worker's, made by the daemon).
    public var kind: String
    public init(name: String, to: String, header: String, fingerprint: String?, kind: String) {
        self.name = name; self.to = to; self.header = header; self.fingerprint = fingerprint; self.kind = kind
    }

    /// The record of a launch secret as held: a chat token (a bot-held one, or a worker's `CHAT_TOKEN…`) carries no fingerprint.
    public init(_ s: LaunchSecret, worker: Bool) {
        let chat = s.bot != nil || (worker && s.variable.hasPrefix("CHAT_TOKEN"))
        self.init(name: s.variable, to: s.destination, header: s.bearer ? "authorization (Bearer)" : s.header,
                  fingerprint: chat ? nil : s.fingerprint, kind: s.bot != nil ? "chat-bot" : chat ? "chat-worker" : "given")
    }
}

public struct ReachFolder: Codable, Equatable, Sendable {
    public var path: String
    /// `rw` or `ro`.
    public var mode: String
    public init(path: String, mode: String) { self.path = path; self.mode = mode }
}

/// "What it can do" for any agent of a workspace — ONE pure function, every view says the same: an `@mac` agent's rows are
/// `MacFence.capabilities` unchanged, then its control and its room; a VM's, an elsewhere one's, built here in the same
/// vocabulary. Each row is live or at the next start. Last, its permissions (allow · ask · never, from `GrantDecision` — the
/// counts `doz permissions show W --agent A` prints) and its ceiling (the effective lid and where each cap comes from):
/// read only — changed in the terminal, and none is enforced yet.
public enum AgentCapabilities {
    public struct Input: Sendable {
        public var name: String
        public var role: String
        /// `vm`, `fenced`, `unfenced`, `elsewhere`.
        public var isolation: String
        public var place: String
        public var folders: [ReachFolder] = []
        public var network: AgentNetworkReach = .none
        public var held: [HeldSecret] = []
        public var account: String?
        public var rooms: [String] = []
        /// An `@mac` agent: its session's capabilities (`MacFence.capabilities`) — taken unchanged.
        public var mac: [MacCapability]?
        /// A VM: its keys by state (`set`, `none`), never a value.
        public var keys: String?
        /// A worker sharing a sandbox.
        public var shares: String?
        /// Its answers to every permission here, and the ceilings that cap it (nil: not asked — no rows).
        public var grants: AgentGrantAnswers?
        public var ceilings: [CeilingRow] = []
        public var workspace: String?
        public init(name: String, role: String, isolation: String, place: String) {
            self.name = name; self.role = role; self.isolation = isolation; self.place = place
        }
    }

    static func row(_ id: String, _ name: String, _ state: String, _ sentence: String, live: Bool = false, link: String? = nil) -> MacCapability {
        MacCapability(id: id, name: name, state: state, sentence: sentence, editable: live ? "live" : "restart", link: link)
    }

    /// The control row: what it can drive. A manager fenced or in a VM talks in the room only; an unfenced one acts as you;
    /// one elsewhere is not run by Dozable. A worker: `WorkerLaunch.control`'s words.
    public static func control(role: String, isolation: String, shares: String? = nil) -> MacCapability {
        switch isolation {
        case "unfenced":
            return row("control", "Control", "acts as you", "Acts as you — runs doz and anything else as you; no proxy, no placeholders, no guard.")
        case "elsewhere":
            return row("control", "Control", "not run by Dozable — token only", "Runs where Dozable does not: it holds its chat token and nothing else of this Mac.")
        default:
            if role == "manager" {
                return row("control", "Control", "talks in the room only",
                           "Talks in the room only — it cannot drive Dozable: no doz command reaches this Mac's daemon from it.")
            }
            return row("control", "Control", WorkerLaunch.control(isolation: isolation, shares: shares),
                       "Does its task and talks in the room; it cannot drive Dozable.")
        }
    }

    /// The chat row: the rooms it is in and who holds its token.
    static func chat(_ i: Input) -> MacCapability? {
        guard !i.rooms.isEmpty else { return nil }
        let rooms = i.rooms.joined(separator: ", ")
        switch i.isolation {
        case "unfenced":
            return row("chat", "Chat rooms", rooms, "Talks in \(rooms); its chat token is in a file only it and you can read, gone when it stops.")
        case "elsewhere":
            return row("chat", "Chat rooms", rooms, "Talks in \(rooms) with a token it keeps itself — Dozable never holds it.")
        default:
            return row("chat", "Chat rooms", rooms, "Talks in \(rooms); its chat token is held by Dozable — it sees a placeholder.")
        }
    }

    public static func rows(_ i: Input) -> [MacCapability] {
        var out: [MacCapability] = []
        if let mac = i.mac {
            out = mac
        } else {
            switch i.isolation {
            case "vm": out = vm(i)
            case "elsewhere":
                out.append(row("isolation", "Isolation", "elsewhere", "Runs on another computer or service — not isolated by Dozable."))
            default:
                // An `@mac` agent whose session record is gone: what its isolation says, nothing more.
                out.append(row("isolation", "Isolation", i.isolation, i.isolation == "unfenced"
                               ? "Runs as you: your files, Keychain and network." : "Held to its folder and Dozable's proxy."))
            }
        }
        out.append(control(role: i.role, isolation: i.isolation, shares: i.shares))
        if let c = chat(i) { out.append(c) }
        if let g = i.grants { out += permissions(g, ceilings: i.ceilings, workspace: i.workspace) }
        return out
    }

    /// The two permission rows: its answers (counts, by role and grant) and its ceiling (each cap, the strictest per
    /// permission, with whose it is). Read only; "not enforced yet" said where it shows.
    public static func permissions(_ g: AgentGrantAnswers, ceilings: [CeilingRow], workspace: String?) -> [MacCapability] {
        let show = "doz permissions show " + (workspace.map { $0 + " " } ?? "") + "--agent " + g.name
        let roles = g.roles.isEmpty ? "no role" : g.roles.joined(separator: ", ")
        let p = row("permissions", "Permissions (allow · ask · never)", g.counts,
                    "What it may do in Dozable, by its role (\(roles)) and your grants — not enforced yet: no agent can drive Dozable"
                    + (g.actsAsYou ? "; it acts as you, so what it does is a promise." : "."), live: true, link: show)
        // The strictest cap per permission, and whose.
        var caps: [String: (GrantAnswer, [String])] = [:]
        for c in ceilings {
            guard let a = GrantAnswer(rawValue: c.answer) else { continue }
            if let have = caps[c.perm] {
                if a < have.0 { caps[c.perm] = (a, [c.words]) } else if a == have.0 { caps[c.perm] = (a, have.1 + [c.words]) }
            } else {
                caps[c.perm] = (a, [c.words])
            }
        }
        let own = "Above every ceiling, Dozable's own: never another workspace, Dozable's settings, a new account, key or token."
        guard !caps.isEmpty else {
            return [p, row("ceiling", "Ceiling", "none set: no cap", "Nothing caps what it may be granted. " + own, live: true, link: show)]
        }
        let order = GrantPermissions.ids
        let listed = caps.sorted { (order.firstIndex(of: $0.key) ?? 99) < (order.firstIndex(of: $1.key) ?? 99) }
        let nevers = listed.filter { $0.value.0 == .never }.count, asks = listed.count - nevers
        let whose = Array(Set(listed.flatMap { $0.value.1 })).sorted()
        let state = [nevers > 0 ? "\(nevers) never" : nil, asks > 0 ? "\(asks) ask" : nil].compactMap { $0 }.joined(separator: " · ")
            + " (" + whose.joined(separator: ", ") + ")"
        let words = listed.prefix(6).map { "\($0.key)=\($0.value.0.rawValue) (\($0.value.1.joined(separator: ", ")))" }.joined(separator: ", ")
            + (listed.count > 6 ? " and \(listed.count - 6) more" : "")
        return [p, row("ceiling", "Ceiling", state, "The most it may ever get, whatever it is granted: \(words). " + own, live: true, link: show)]
    }

    /// A micro VM's rows: isolation, folders, network, this Mac's ports, forwarded ports, secrets, the account, keys.
    static func vm(_ i: Input) -> [MacCapability] {
        let link = "doz net show \(i.place)"
        var out = [row("isolation", "Isolation", "micro VM", "Its own Linux VM with no network card: Dozable's proxy is its only way out.")]
        if i.folders.isEmpty {
            out.append(row("folders", "Folders", "none (isolated)", "Has no folder of this Mac — only its own disk."))
        } else {
            let words = i.folders.map { DisplayPath.tilde($0.path) + " " + $0.mode }
            out.append(row("folders", "Folders", words.joined(separator: ", "),
                           "Sees " + i.folders.map { DisplayPath.tilde($0.path) + ($0.mode == "ro" ? " read-only" : "") }.joined(separator: " and ")
                           + " at /workspace; nothing else of this Mac."))
        }
        out.append(network(i, link: link))
        if !i.network.hostPorts.isEmpty {
            out.append(row("host-ports", "This Mac's ports", HostRoute.listText(i.network.hostPorts),
                           "Reaches only these ports of this Mac, through the proxy, as \(HostRoute.hostName):PORT; nothing else of this Mac.",
                           live: true, link: link))
        }
        if !i.network.forwarded.isEmpty {
            out.append(row("forwarded", "Forwarded ports", i.network.forwarded.map { f in "\(f.port)" + (f.local.map { " → localhost:\($0)" } ?? "") }.joined(separator: ", "),
                           "Its own ports, forwarded out to this Mac's loopback while it runs: your browser reaches them, nothing on your network does.",
                           live: true, link: "doz ports \(i.place)"))
        }
        let given = i.held.filter { $0.kind == "given" }
        if !given.isEmpty {
            out.append(row("secrets", "Secrets", given.map { "\($0.name) → \($0.to)" }.joined(separator: ", "),
                           "Holds placeholders Dozable swaps for these secrets on requests to their one destination; the values stay on this Mac.",
                           link: link))
        }
        out.append(row("claude-login", "Claude login", i.account.map { "account \($0)" } ?? "none",
                       i.account.map { "Signs in as \($0) through the proxy; the program never sees the token." } ?? "No Claude login is given to it."))
        out.append(row("keys", "Keys", i.keys ?? "none", "Keys never enter the VM: the proxy swaps a placeholder for each on its way out."))
        return out
    }

    static func network(_ i: Input, link: String) -> MacCapability {
        let n = i.network
        guard n.proxied else {
            return row("network", "Network", "not limited, not logged", "Reaches the network as you do; nothing is limited or logged.")
        }
        let preset = n.preset == "agent" ? "standard" : n.preset ?? "custom"
        let sites = n.sites.isEmpty ? "" : " + " + n.sites.joined(separator: ", ")
        return row("network", "Network", "through Dozable's proxy (\(preset))" + sites,
                   "Reaches only what its permissions allow; every connection is logged; never this Mac's own addresses.",
                   live: n.live, link: link)
    }
}
