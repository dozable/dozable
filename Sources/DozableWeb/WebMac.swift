import DozableHost
import DozableKit
import Foundation

// The sessions on THIS Mac (`@mac`) in the dashboard — their typed routes (`WebRoute.macSessions`, `macSessionScreen`,
// `macTerminalTicket`, `macTerminalSocket`; 683 M5: `macSessionNetwork`, `macSessionTranscripts`, `macSessionTranscript`,
// `macSessionQuarantine`, `macSessionPlan`), their projections, and the rules a remote browser is held to (`WebExposure`:
// `serve.mac_sessions`). Nothing here opens a session: the page lists, watches, types into (on a click), ends, restarts,
// resumes and switches the bridges of the ones `doz run @mac` opened — and the New session wizard shows the `doz run @mac`
// command (Copy; Open in Terminal for the plainly fenced shapes only: the person's own terminal runs it, never the host).
//
// 683 M5: what each session can do is `MacFence.capabilities` — the ONE source the CLI prints too. The page only draws it:
// the rows (`capabilities`), and the tile's chips, PICKED from those rows here (`WebMacChips`), never worked out anew.

/// One session on this Mac, as the page shows it. Its text (the command, the folder) is the person's own, shown as text.
public struct WebMacSession: Codable, Equatable, Sendable {
    public var name: String
    /// running | ended | gone (its holder is gone: the Mac restarted, or it was killed — its saved screen is what is left).
    public var state: String
    public var pid: Int?
    public var cols: UInt16?
    public var rows: UInt16?
    public var clients: Int
    public var exitCode: Int32?
    public var command: String
    /// The folder it runs in (absolute; the page shows it with `~`).
    public var workdir: String?
    public var openedAt: Date?
    /// Its own command line asked for its permissions to be bypassed (never Dozable): marked on its tile and pane.
    public var bypassed: Bool
    public var status: WebAgentStatus?
    /// 683 M5: whether a fence holds it, what the fence is (nil: unfenced), what it can do (every session — fenced or
    /// not: the same rows, their real states), and the tile's chips (≤ 4, picked from those rows) + how many rows more.
    public var fenced: Bool = false
    public var fence: WebMacFence? = nil
    public var capabilities: [WebMacCapability] = []
    public var chips: [WebMacChip] = []
    public var moreCapabilities: Int = 0

    public init(_ s: SessionRow) {
        name = s.name
        state = s.gone == true ? "gone" : s.ended ? "ended" : "running"
        pid = s.pid
        cols = s.cols
        rows = s.rows
        clients = s.clients
        exitCode = s.exitCode
        command = String(s.command.prefix(1024))
        workdir = s.workdir
        openedAt = s.openedAt
        bypassed = s.bypassed == true
        status = s.status.map(WebAgentStatus.init)
        fenced = s.fenced == true
        fence = s.fence.map(WebMacFence.init)
        capabilities = (s.capabilities ?? []).map(WebMacCapability.init)
        (chips, moreCapabilities) = WebMacChips.pick(capabilities, fenced: fenced)
    }
}

/// A fenced session's fence, field by field — never its proxy's password or port, a placeholder, its profile's text or
/// hash, or its session folder.
public struct WebMacFence: Codable, Equatable, Sendable {
    /// `agent` | `xcode` | `simulator`.
    public var profile: String
    /// The STATE words of `doz sessions @mac` (`fenced · Keychain open`, `stopped: git config`).
    public var state: String
    public var keychain: Bool
    public var agentConfig: String?
    public var history: String?
    public var account: String?
    public var github: String?
    public var sshAgent: Bool
    /// `proxy` (a host serves it), `waiting (no host)`, `none` (an older record), nil (it ended).
    public var network: String?
    public var preset: String?
    public var localPorts: [Int]
    public var readable: [String]
    public var writable: [String]
    public var denialsSeen: Int?
    public var denialLog: String?
    /// Why the git guard stopped it (the keys it took out); nil: not stopped.
    public var stoppedForGit: String?
    public var bridges: WebMacBridges?
    /// When it last put text on the clipboard (never the text).
    public var lastCopyAt: Date?

    public init(_ f: MacFenceRow) {
        profile = f.profile
        state = f.state
        keychain = f.keychain
        agentConfig = f.agentConfig
        history = f.history
        account = f.account
        github = f.github
        sshAgent = f.sshAgent == true
        network = f.network
        preset = f.preset == "agent" ? "standard" : f.preset
        localPorts = f.localPorts ?? []
        readable = f.readable
        writable = f.writable
        denialsSeen = f.denialsSeen
        denialLog = f.denialLog
        stoppedForGit = f.stoppedForGit.flatMap { $0.isEmpty ? nil : String($0.prefix(512)) }
        bridges = f.bridges.map(WebMacBridges.init)
        lastCopyAt = f.lastCopyAt
    }
}

public struct WebMacBridges: Codable, Equatable, Sendable {
    public var openURL: Bool
    public var openFiles: Bool
    public var clipboard: Bool
    public init(_ b: MacFenceBridges) {
        openURL = b.openURL
        openFiles = b.openFiles
        clipboard = b.clipboard
    }
}

/// One row of "What this session can do" — `MacCapability` as it is (one source).
public struct WebMacCapability: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var state: String
    public var sentence: String
    /// `live` (changes while it runs) | `restart` (at the next start).
    public var editable: String
    /// The command that looks at or changes it (`doz net log @mac --session S`), when there is one.
    public var link: String?
    public init(_ c: MacCapability) {
        id = c.id
        name = c.name
        state = c.state
        sentence = c.sentence
        editable = c.editable
        link = c.link
    }
}

/// A tile's chip: a capability row's state, as a word.
public struct WebMacChip: Codable, Equatable, Sendable {
    /// The capability row it stands for.
    public var id: String
    public var word: String
    /// `ok` | `warn` | `info` — the colour; never the only sign (the word says it).
    public var tone: String
}

/// §2.7's tile chips, in this order, at most four: the fence's word; `Keychain open` when open; `Shared config` when the
/// agent uses the person's own folder; `GitHub: push` when it may push — the latter three for a FENCED session (an
/// unfenced one has them all: its one chip, No isolation, says so). Then "+N": the panel's other rows. PICKED from the
/// capability rows (their states), never derived from the record a second time.
public enum WebMacChips {
    public static let maximum = 4

    public static func pick(_ caps: [WebMacCapability], fenced: Bool) -> ([WebMacChip], Int) {
        func row(_ id: String) -> WebMacCapability? { caps.first { $0.id == id } }
        var out: [WebMacChip] = []
        if let f = row("fence") {
            let word = f.state.prefix(1).uppercased() + f.state.dropFirst()
            out.append(WebMacChip(id: "fence", word: word, tone: f.state.hasPrefix("fenced") ? "ok" : "warn"))
        }
        if fenced {
            if row("keychain")?.state == "open" { out.append(WebMacChip(id: "keychain", word: "Keychain open", tone: "warn")) }
            if row("agent-config")?.state.hasPrefix("shared") == true { out.append(WebMacChip(id: "agent-config", word: "Shared config", tone: "warn")) }
            if row("github")?.state == "push" { out.append(WebMacChip(id: "github", word: "GitHub: push", tone: "info")) }
        }
        out = Array(out.prefix(maximum))
        return (out, max(0, caps.count - out.count))
    }
}

/// `GET /api/v1/mac/sessions`.
public struct WebMacSessions: Codable, Equatable, Sendable {
    /// Always false — said in the answer itself, so no client can take these for sandboxes (a fenced session is held to
    /// its folder and Dozable's proxy; it is still no sandbox: `fenced` says which are).
    public var isolated = false
    public var sessions: [WebMacSession]
    /// What this browser may do with them: `interactive` | `watch` (a remote browser under `serve.mac_sessions`).
    public var access: String
    /// 683 M5: whether this browser may use the New session wizard (the Mac's own browser only).
    public var plan: Bool = false

    public init(sessions: [WebMacSession], access: String, plan: Bool = false) {
        self.sessions = sessions
        self.access = access
        self.plan = plan
    }
}

/// The body of `POST /api/v1/mac/terminal-ticket`, decoded STRICTLY: a session must be named (there is no "own" session
/// on the Mac to open), and the mode is interactive or watch (no console: the Mac has no boot).
public enum WebMacTicket {
    public static func decode(_ body: Data) throws -> WebTerminalTicketRequest {
        let r = try WebTerminalTicketRequest.decode(body)
        guard r.mode != .console else { throw WebAction.Invalid("mode: interactive or watch") }
        guard let s = r.session, WebRoute.isMacSessionName(s) else {
            throw WebAction.Invalid("session: a session on this Mac — 1–32 of letters, digits . _ - (not starting with .)")
        }
        guard !r.quiet else { throw WebAction.Invalid("quiet: not for a session on this Mac") }
        return r
    }
}

extension WebGridsRequest {
    /// `@mac` tiles are the sessions on this Mac: a remote browser gets them only when `serve.mac_sessions` allows watching.
    static func macAllowed(_ who: WebExposure.Principal, _ allowed: WebExposure.MacSessions) -> Bool {
        !who.isRemote || allowed != .off
    }
}

// MARK: 683 M5 — the Network tab, the conversations, the quarantine view

/// `GET /api/v1/mac/sessions/{s}/network`: a fenced session's permissions (the sandbox page's checklist, shown read-only
/// here — the changes are `doz net … @mac --session S`, the command beside it), its policy and connection log (the
/// sandbox page's own shape, `WebNetwork`), and what its FENCE refused (the system log's kernel lines).
public struct WebMacNetwork: Codable, Equatable, Sendable {
    public var session: String
    public var network: WebNetwork
    /// `on` | `unavailable` (this account may not read the system log) | `off` (no host).
    public var denialLog: String
    public var denials: [WebFenceDenial]
    /// The commands that change it (a person's terminal; the page edits none of it).
    public var commands: [String]
}

public struct WebFenceDenial: Codable, Equatable, Sendable {
    public var time: Date
    public var process: String
    public var operation: String
    public var target: String
    public init(_ d: FenceDenial) {
        time = d.time
        process = String(d.process.prefix(128))
        operation = String(d.operation.prefix(64))
        target = String(d.target.prefix(1024))
    }
}

/// `GET /api/v1/mac/sessions/{s}/transcripts`: a fenced session's archived conversations — their names, when the session
/// ended, their sizes; never their content (that is the export route, a download) and never the archive's paths.
public struct WebMacTranscripts: Codable, Equatable, Sendable {
    public struct Item: Codable, Equatable, Sendable {
        /// `<uuid>.jsonl`.
        public var name: String
        /// The end it was archived at (`20261113T101500Z`) — with `name`, the export route's address.
        public var endedAt: String
        public var bytes: Int
    }
    public var session: String
    public var items: [Item]
    /// Where they were also carried (the person's own folder), when known.
    public var carriedTo: String?

    public init(_ l: MacTranscripts.Listing) {
        session = l.session
        items = l.items.filter { WebMacTranscripts.isStamp($0.endedAt) && MacTranscripts.isTranscriptName($0.name) }
            .map { Item(name: $0.name, endedAt: $0.endedAt, bytes: $0.bytes) }
        carriedTo = l.carriedTo
    }

    /// An archive folder's name (`MacTranscripts.stamp`): `yyyyMMddTHHmmssZ`.
    public static func isStamp(_ s: String) -> Bool {
        s.count == 16 && s.range(of: "^[0-9]{8}T[0-9]{6}Z$", options: .regularExpression) != nil
    }

    /// The download's name: `<stamp>-<uuid>.jsonl` (the CLI's `--export` names).
    public static func fileName(endedAt: String, name: String) -> String { endedAt + "-" + name }
}

/// `GET /api/v1/mac/sessions/{s}/quarantine`: what the git guard took out of a stopped session's git configs (text the
/// host wrote — keys and values the session put there; shown as text).
public struct WebMacQuarantine: Codable, Equatable, Sendable {
    public struct Item: Codable, Equatable, Sendable {
        public var name: String
        public var text: String
    }
    public var session: String
    public var items: [Item]
    public init(_ q: SessionQuarantine) {
        session = q.session
        items = q.items.prefix(50).map { Item(name: String($0.name.prefix(128)), text: String($0.text.prefix(16 << 10))) }
    }
}

// MARK: 683 M5 — the New session wizard's plan

/// The body of `POST /api/v1/mac/session-plan`, decoded STRICTLY (unknown field, wrong type, a value outside its rule → 400
/// with a fixed message): the case and its toggles, never a program or an argument of the browser's own.
public struct WebMacPlanRequest: Equatable, Sendable {
    /// The five cases the owner approved (§2.5).
    public enum Case: String, CaseIterable, Sendable {
        case plain, web, xcode, signing, unfenced
        public var fenced: Bool { self == .plain || self == .web || self == .xcode }
    }
    /// Claude Code, or the person's login shell (Codex waits until its recipe declares its config folder).
    public enum Program: String, CaseIterable, Sendable { case claude, shell }

    public var kind: Case
    public var program: Program
    public var workdir: String
    public var session: String?
    public var preset: String?
    public var account: String?
    public var github: String?
    public var agentConfig: String?
    public var simulator = false
    public var keychain = false
    public var ports: [Int] = []
    public var open = false

    public static let fields: Set<String> = ["case", "program", "workdir", "session", "preset", "account", "github", "agentConfig",
                                             "simulator", "keychain", "ports", "open"]
    public static let maximumPorts = 8

    public init(kind: Case, program: Program, workdir: String) {
        self.kind = kind
        self.program = program
        self.workdir = workdir
    }

    public static func decode(_ body: Data) throws -> WebMacPlanRequest {
        typealias Invalid = WebAction.Invalid
        guard let obj = try? JSONSerialization.jsonObject(with: body), let d = obj as? [String: Any] else { throw Invalid("the body must be a JSON object") }
        let extra = Set(d.keys).subtracting(fields)
        guard extra.isEmpty else { throw Invalid("unexpected field(s): \(extra.sorted().joined(separator: ", "))") }
        func string(_ k: String, max: Int) throws -> String? {
            guard let v = d[k], !(v is NSNull) else { return nil }
            guard let s = v as? String, !s.isEmpty, s.utf8.count <= max,
                  !s.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
                throw Invalid("\(k): 1–\(max) characters, no control characters")
            }
            return s
        }
        func flag(_ k: String) throws -> Bool {
            guard let v = d[k], !(v is NSNull) else { return false }
            guard let b = v as? Bool, CFGetTypeID(v as CFTypeRef) == CFBooleanGetTypeID() else { throw Invalid("\(k): true or false") }
            return b
        }
        guard let c = try string("case", max: 16).flatMap(Case.init(rawValue:)) else {
            throw Invalid("case: plain, web, xcode, signing or unfenced")
        }
        guard let p = try string("program", max: 16).flatMap(Program.init(rawValue:)) else { throw Invalid("program: claude or shell") }
        // Absolute, no `.`/`..` part, no empty part (`//`, a trailing `/`) — checked by its parts: `standardizedFileURL`
        // would also rewrite `/private/tmp` to `/tmp` and refuse a folder that is fine.
        guard let wd = try string("workdir", max: 1024), wd.hasPrefix("/"), wd != "/",
              !wd.dropFirst().split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw Invalid("workdir: a folder on this Mac — an absolute path (no . or .. parts), at most 1024 bytes")
        }
        var r = WebMacPlanRequest(kind: c, program: p, workdir: wd)
        if let s = try string("session", max: 64) {
            guard WebRoute.isMacSessionName(s) else { throw Invalid("session: 1–32 of letters, digits . _ - (not starting with .)") }
            r.session = s
        }
        r.preset = try string("preset", max: 16)
        if let v = r.preset, !["standard", "locked", "open"].contains(v) { throw Invalid("preset: standard, locked or open") }
        r.github = try string("github", max: 8)
        if let v = r.github, !["off", "read", "push"].contains(v) { throw Invalid("github: off, read or push") }
        r.agentConfig = try string("agentConfig", max: 16)
        if let v = r.agentConfig, !MacAgentConfig.modes.contains(v) { throw Invalid("agentConfig: private or shared") }
        if let a = try string("account", max: 40) {
            guard a == "mac" || a == "none" || (try? AccountStore.validateName(a)) != nil else {
                throw Invalid("account: an account's name (1–40 of a-z 0-9 -), mac or none")
            }
            r.account = a
        }
        r.simulator = try flag("simulator")
        r.keychain = try flag("keychain")
        r.open = try flag("open")
        if let v = d["ports"], !(v is NSNull) {
            guard let a = v as? [Any], a.count <= maximumPorts else { throw Invalid("ports: at most \(maximumPorts) ports") }
            for x in a {
                guard let n = x as? Int, CFGetTypeID(x as CFTypeRef) != CFBooleanGetTypeID(), (1024...65535).contains(n) else {
                    throw Invalid("ports: whole numbers 1024–65535")
                }
                if !r.ports.contains(n) { r.ports.append(n) }
            }
        }
        // What belongs to which case — anything else is refused, never quietly dropped.
        if !c.fenced, r.preset != nil || r.github != nil || r.agentConfig != nil || r.account != nil {
            throw Invalid("preset, github, agentConfig and account are for a fenced session (plain, web or xcode)")
        }
        if c != .xcode, r.simulator || r.keychain { throw Invalid("simulator and keychain are the Swift / Xcode case's toggles") }
        if c != .web, !r.ports.isEmpty { throw Invalid("ports are the Web / Node case's") }
        if c == .web, r.ports.isEmpty { throw Invalid("ports: the Web / Node case opens at least one (its dev server's)") }
        if p == .shell, r.account != nil { throw Invalid("account: for Claude Code (a login shell has no Claude login)") }
        return r
    }
}

/// What the wizard shows for a plan: the exact command (to Copy), what the session it opens could do (the ONE source:
/// `MacFence.capabilities` of `MacCapabilityShape.planned`, as `doz run @mac … --dry-run` prints it), and whether Open in
/// Terminal is offered — only for a fenced case with neither of Swift's toggles on and the agent's config private (owner,
/// round 2 M4: anything near-unfenced is copy-only, so no single POST from a page starts it).
public struct WebMacPlan: Codable, Equatable, Sendable {
    public var command: String
    public var capabilities: [WebMacCapability]
    /// `MacFence.capabilitiesText` of the same rows (the CLI's `--dry-run` text).
    public var describe: String
    public var fenced: Bool
    public var openable: Bool
    /// Why Open in Terminal is not offered (nil: it is).
    public var copyOnly: String?
    /// The config mode and history the session will use (the card shows them).
    public var agentConfig: String?
    public var history: String?
    /// Set when this request opened it in Terminal: a line for the page.
    public var opened: String?

    /// The command a terminal app runs from the one-shot `.command` file (`exec '<this doz>' run @mac … --store '<store>'`).
    /// Never in the answer: the page has the person's command.
    public var terminalCommand: String { _terminal }
    private var _terminal: String = ""
    enum CodingKeys: String, CodingKey { case command, capabilities, describe, fenced, openable, copyOnly, agentConfig, history, opened }

    /// Build the plan on the Mac, from the enums alone. `home`: the person's home; `shell`: their login shell (`$SHELL`);
    /// `executable`, `store`: this doz and its store (the `.command` file names both); `defaultStore`: the store a plain
    /// `doz` would use (the copied command adds `--store` only when it differs).
    public static func make(_ r: WebMacPlanRequest, settings: DozableSettings, home: String, shell: String,
                            executable: String, store: DozableStore, defaultStore: DozableStore) -> WebMacPlan {
        var flags: [String] = []
        let fenced = r.kind.fenced
        if fenced {
            flags.append("--fenced")
            if r.kind == .xcode { flags.append(r.simulator ? "--simulator" : "--xcode") }
            if r.keychain { flags.append("--keychain") }
        } else {
            flags.append("--unfenced")
        }
        flags += ["--workdir", shellQuote(r.workdir)]
        if let s = r.session { flags += ["--session", s] }
        if fenced {
            if let p = r.preset, p != "standard" { flags += ["--permissions", p] }
            for n in r.ports { flags += ["--local-port", String(n)] }
            if let a = r.agentConfig { flags += ["--agent-config", a] }
            if let a = r.account { flags += ["--account", a] }
            if let g = r.github, g != "off" { flags += ["--github", g] }
        }
        let argv = r.program == .claude ? ["claude"] : [shell, "-l"]
        let tail = r.program == .claude ? ["--", "claude"] : []
        let storeFlag = store == defaultStore ? [] : ["--store", shellQuote(store.root.path)]
        let command = (["doz", "run", "@mac"] + flags + storeFlag + tail).joined(separator: " ")
        let terminal = (["exec", shellQuote(executable), "run", "@mac"] + flags + ["--store", shellQuote(store.root.path)] + tail).joined(separator: " ")

        // What it could do: the CLI's --dry-run shape, from the same request the command sends.
        var q: MacFenceRequest?
        if fenced {
            var f = MacFenceRequest(keychain: r.keychain ? true : (settings.string(SettingKey.macKeychain) == "on" ? true : nil),
                                    permissions: [r.preset ?? settings.string(SettingKey.macPermissions) ?? "standard"],
                                    localPorts: r.ports.isEmpty ? nil : r.ports)
            f.agentConfig = r.agentConfig
            f.account = r.account
            f.xcode = r.kind == .xcode ? true : nil
            f.simulator = r.simulator ? true : nil
            f.github = r.github.flatMap { $0 == "off" ? nil : $0 }
            q = f
        }
        let shape = MacCapabilityShape.planned(session: r.session ?? (r.program == .claude ? "claude" : (shell as NSString).lastPathComponent),
                                               workdir: r.workdir, argv: argv, fenced: fenced, request: q, settings: settings, home: home)
        let caps = MacFence.capabilities(shape)
        // Copy-only shapes: an unfenced case, Swift's toggles, the person's own agent config (or a Keychain the settings open).
        let why: String?
        if !fenced { why = "it runs with no fence — run it yourself in a terminal" }
        else if r.simulator { why = "the Simulator and what it launches run outside the fence — run it yourself" }
        else if shape.keychain { why = "it opens your Keychain — run it yourself" }
        else if shape.agentConfig == MacAgentConfig.sharedMode { why = "it uses your own agent settings folder — run it yourself" }
        else { why = nil }
        var p = WebMacPlan(command: command, capabilities: caps.map(WebMacCapability.init), describe: MacFence.capabilitiesText(caps),
                           fenced: fenced, openable: why == nil, copyOnly: why, agentConfig: shape.agentConfig, history: shape.history, opened: nil)
        p._terminal = terminal
        return p
    }
}
