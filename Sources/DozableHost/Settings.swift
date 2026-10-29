import Darwin
import Foundation
import DozableKit

// 591 settings (owner request): ONE closed, typed schema of every user-facing setting, a TOML file
// generated from it (`${XDG_CONFIG_HOME:-~/.config}/doz/doz.toml` — named for
// the command since 0.37), and one resolution rule everywhere:
//
//     a command-line flag  >  its environment variable  >  the file  >  the default
//
// and every value knows which of the four it came from. The file lists every setting, each with a
// `# description` and a commented `# key = <default>`; only the values a person set are uncommented.
// It is written whole (from the schema, never edited in place), atomically, 0600 in a 0700 directory.
// An unknown key or a value of the wrong type is a WARNING (that line is ignored, the default applies),
// never a crash; a file that does not parse is ignored whole, with its error, and is not overwritten.
//
// What is deliberately NOT a setting (`DozableSettings.notSettable`): the web UI's security limits
// (session and link lifetimes, body and connection caps, the Host/Origin/CSRF checks, the CSP), the
// terminal's (one-use tickets, the paste cap and confirmation), the guest-binary overrides, and any
// credential. `ui.terminals` can only take something away (browser terminals off).

/// A setting's type — closed; every value is validated against it before it is used or written.
public enum SettingType: Sendable, Equatable {
    case bool
    case int(ClosedRange<Int>)
    case choice([String])
    /// A host path; `""` = automatic. Never editable from the web UI (it names no host path).
    case path
    /// An IPv4 CIDR for vmnet (`192.168.64.0/24`); `""` = a free one.
    case subnet
    /// 594: a package version — `latest` (resolved when an image is prepared) or an exact `1.2.3`.
    case version
    /// 594 W10: `mac` (follow this Mac's zone) or an IANA zone name (`Australia/Sydney`).
    case timeZone
    /// 597: a preset (`standard`, `locked`, `open`), or permission ids separated by commas, each
    /// optionally `+`/`-` on the Standard set (`+web`, `-error-reports`, `install:python`).
    case permissions

    /// 597: a permissions setting's words, checked (nil: not a valid value).
    public static func permissionWords(_ s: String) -> [String]? {
        let t = s.trimmingCharacters(in: .whitespaces)
        if ["standard", "locked", "open"].contains(t) { return [t] }
        let words = t.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !words.isEmpty, words.count <= 32 else { return nil }
        for w in words {
            let id = (w.hasPrefix("+") || w.hasPrefix("-")) ? String(w.dropFirst()) : w
            guard AgentPermissions.isValid(id) else { return nil }
        }
        return words
    }

    /// 599 (594.B4): a terminal title — text with `{sandbox}` `{session}` `{image}` `{time}` `{phase}`
    /// (a closed set), ≤ 120 characters, no control character; `""` = leave the title alone.
    case titleTemplate
    /// 599b: Mac app names, comma-separated (`Typora, Visual Studio Code`) — `WorkspaceFiles.appNames`;
    /// `""` = none.
    case appList
    /// 606: where `doz serve` listens — `lan`, `loopback`, or the Mac's addresses separated by commas.
    case serveBind
    /// 606: external origins, comma-separated (`https://doz.home.example`); `""` = none.
    case originList
    /// 606: addresses or networks, comma-separated (`127.0.0.1, 192.168.1.0/24, fd00::/8`); `""` = none.
    case addressList
    /// 657: a dotfiles repository — an https:// git URL or a folder on this Mac (`DotfilesSource`); `""` = none.
    case dotfiles

    /// The variables a title may use.
    public static let titleVariables = ["sandbox", "session", "image", "time", "phase"]

    /// Why `s` is not a title template, or nil.
    public static func titleTemplateProblem(_ s: String) -> String? {
        guard s.count <= 120 else { return "at most 120 characters" }
        guard !s.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F || (0x80...0x9F).contains($0.value) }) else {
            return "no control characters"
        }
        var rest = Substring(s)
        while let open = rest.firstIndex(of: "{") {
            guard let close = rest[open...].firstIndex(of: "}") else { return "a { without its }" }
            let name = String(rest[rest.index(after: open)..<close])
            guard titleVariables.contains(name) else { return "{\(name)} is not a variable (they are {\(titleVariables.joined(separator: "} {"))})" }
            rest = rest[rest.index(after: close)...]
        }
        return rest.contains("}") ? "a } without its {" : nil
    }

    /// An IANA zone name this Mac knows (plain characters only — it becomes a guest file's content).
    public static func isTimeZoneName(_ s: String) -> Bool {
        s.count <= 64 && s.range(of: #"^[A-Za-z][A-Za-z0-9_+-]*(/[A-Za-z0-9_+-]+)*$"#, options: .regularExpression) != nil
            && TimeZone(identifier: s) != nil
    }

    public var name: String {
        switch self {
        case .bool: "boolean"
        case .int(let r): "integer \(r.lowerBound)–\(r.upperBound)"
        // 617: a long list (defaults.image: every agent and tool) is not spelled out, so the file does not grow with
        // the recipes; the setting is still checked against all of them.
        // 634: a list of bases (defaults.base) is spelled out — it is the catalogue's, not the recipes'.
        case .choice(let c) where c.count > 8 && !c.allSatisfy({ BaseCatalogue.base($0) != nil }): c.prefix(4).joined(separator: " | ") + ", or an agent or tool's id (doz try lists them)"
        case .choice(let c): c.joined(separator: " | ")
        case .path: "path (\"\" = automatic)"
        case .subnet: "IPv4 subnet, a.b.c.d/nn (\"\" = a free one)"
        case .version: "latest, or an exact version like 2.1.227"
        case .timeZone: "mac, or a time zone like Australia/Sydney"
        case .permissions: "standard | locked | open, or permissions like +web,-error-reports (doz net permissions)"
        case .titleTemplate: "a title with {sandbox} {session} {image} {time} {phase} (\"\" = leave the title alone)"
        case .appList: "app names, comma-separated, like \"Typora, Visual Studio Code\" (\"\" = none)"
        case .serveBind: "lan | loopback | the Mac's addresses, comma-separated"
        case .originList: "origins like https://doz.home.example, comma-separated (\"\" = none)"
        case .addressList: "addresses or networks like 127.0.0.1, 192.168.1.0/24, comma-separated (\"\" = none)"
        case .dotfiles: "a git repository's https:// URL, or a folder on this Mac that is one (\"\" = none)"
        }
    }

    /// `1.2.3`, optionally `-pre.1` / `+build` — what npm publishes (never a range).
    public static func isExactVersion(_ s: String) -> Bool {
        s.count <= 64 && s.range(of: #"^\d+\.\d+\.\d+([-+][0-9A-Za-z.-]+)?$"#, options: .regularExpression) != nil
    }
}

/// Where an effective value came from. 669 (659 §4): one precedence for every setting — the first layer that says
/// something wins: a flag, the environment, the sandbox's own value, its project's (`doz_project.yaml`), this Mac's
/// (`doz.toml`), then the default: a recipe's own for its agent's settings (`recipe`), Dozable's for the rest. `mac` was
/// `file` before 669; the JSON still reads `file` (one release).
public enum SettingSource: String, Sendable, CaseIterable {
    case flag, env, sandbox, project, mac
    /// 669: a recipe's own default (its agent's settings).
    case recipe
    case `default`

    /// The badge's word (the dashboard's, the CLI's SOURCE column).
    public var word: String { self == .mac ? "Mac" : rawValue }
}

extension SettingSource: Codable {
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let s = raw == "file" ? .mac : SettingSource(rawValue: raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "no setting source \(raw)"))
        }
        self = s
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

/// 669 (659 §3): the four kinds of setting — where each may be set.
public enum SettingClass: String, Codable, Sendable {
    /// How this Mac, the host, the CLI and the dashboard behave: the Mac only (and env, flag).
    case mac = "M"
    /// A new sandbox's default: read once when it is made (Mac, project), then recorded in it.
    case newSandbox = "N"
    /// A Mac-wide value one sandbox may override, read while it runs: Mac, project, sandbox.
    case perSandbox = "S"
    /// A recipe's agent's own: the recipe's default, Mac, project, sandbox.
    case recipe = "R"

    /// Whether a sandbox or a project can have its own value of a setting of this kind.
    public var hasSandboxLayers: Bool { self != .mac }
}

/// When a changed value takes effect.
public enum SettingApplies: String, Codable, Sendable, CaseIterable {
    case now = "now"
    case nextCommand = "next-command"
    case nextCreate = "next-create"
    case nextSession = "next-session"
    case hostRestart = "host-restart"
    case newStore = "new-store"
    case nextBoot = "next-boot"
    /// 594 W10: at each sandbox's next start or wake.
    case nextStartOrWake = "next-start-or-wake"
    /// 605: when doz ui starts again (`doz ui restart`).
    case uiRestart = "ui-restart"
    /// 606: when doz serve starts again.
    case serveRestart = "serve-restart"
    /// 608: at each sandbox's next start (a cold boot — never under running programs).
    case nextStart = "next-start"

    public var note: String {
        switch self {
        case .now: "applies at once (the UI re-reads it)"
        case .nextCommand: "applies to the next doz command (a running doz ui keeps its store)"
        case .nextCreate: "applies to sandboxes created from now on (the host reads it at create)"
        case .nextSession: "applies to sessions opened from now on"
        case .hostRestart: "applies after doz host stop (the next host reads it)"
        case .newStore: "the choice for a store that has not made one (doz account keepalive wins)"
        case .nextBoot: "applies when the next boot of a sandbox is kept"
        case .nextStartOrWake: "applies at each sandbox's next start or wake"
        case .uiRestart: "applies when doz ui starts again (doz ui restart)"
        case .serveRestart: "applies when doz serve starts again"
        case .nextStart: "applies at each sandbox's next start (a running one keeps what it has)"
        }
    }
}

public struct SettingDefinition: Sendable {
    public let section: String
    public let name: String
    public let type: SettingType
    public let defaultValue: TOMLValue
    public let summary: String
    /// The environment variable that overrides the file (nil: none).
    public let environment: String?
    /// The command-line flag that overrides both, as a person types it (nil: none).
    public let flag: String?
    public let applies: SettingApplies
    /// False: the web UI shows it read-only (host paths — the UI never names one).
    public let editableInUI: Bool
    /// A recipe's own setting (its agent's id): generated from its recipe, and written into doz.toml only once that
    /// recipe has a value set there (`render`). nil: one of Dozable's own, always listed. 669: the built-in three's too.
    public let agent: String?
    /// 669: the names it had before 669 (`images.claude_code_version`, `claude.permissions`) — read, and taken by
    /// `doz config`, as this key; never written again.
    public let aliases: [String]

    public var key: String { "\(section).\(name)" }

    init(_ section: String, _ name: String, _ type: SettingType, _ defaultValue: TOMLValue, _ summary: String,
         env: String? = nil, flag: String? = nil, applies: SettingApplies, ui: Bool = true, agent: String? = nil,
         aliases: [String] = []) {
        self.section = section
        self.name = name
        self.type = type
        self.defaultValue = defaultValue
        self.summary = summary
        environment = env
        self.flag = flag
        self.applies = applies
        editableInUI = ui
        self.agent = agent
        self.aliases = aliases
    }

    /// 669: which of the four kinds it is.
    public var settingClass: SettingClass {
        if agent != nil { return .recipe }
        if DozableSettings.perSandbox.contains(key) { return .perSandbox }
        if DozableSettings.newSandboxKeys.contains(key) { return .newSandbox }
        return .mac
    }

    /// 669: where its default comes from — the recipe's own (`recipe`) or Dozable's (`default`).
    public var defaultSource: SettingSource { agent != nil ? .recipe : .default }

    /// Check a typed value (from the file, the UI or the CLI). Throws a message that never echoes
    /// more than the value's type.
    public func validate(_ v: TOMLValue) throws -> TOMLValue {
        switch (type, v) {
        case (.bool, .bool): return v
        case (.int(let r), .int(let i)):
            guard r.contains(i) else { throw SettingsError("\(key) is \(r.lowerBound)–\(r.upperBound)") }
            // 605: a fixed dashboard port is an unprivileged one (0 = automatic).
            if key == SettingKey.uiPort, (1...1023).contains(i) { throw SettingsError("\(key) is 0 (automatic) or a port 1024–65535") }
            return v
        case (.choice(let c), .string(let s)):
            guard c.contains(s) else { throw SettingsError("\(key) is one of \(c.joined(separator: ", "))") }
            return v
        case (.path, .string(let s)):
            guard s.utf8.count <= 1024, !s.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
                throw SettingsError("\(key) is a path (at most 1024 bytes, no control characters)")
            }
            guard s.isEmpty || s.hasPrefix("/") || s.hasPrefix("~") else { throw SettingsError("\(key) is an absolute path (or ~/…), or \"\"") }
            return v
        case (.subnet, .string(let s)):
            guard s.isEmpty || Self.isSubnet(s) else { throw SettingsError("\(key) is an IPv4 subnet like 192.168.64.0/24, or \"\"") }
            return v
        case (.version, .string(let s)):
            // 617: a pinned-only recipe (pypi, release-binary) takes its own pin too, which may have two parts (llm 0.36).
            let pin = agent.flatMap(AgentRecipes.recipe).flatMap { !$0.isBuiltin && $0.isPinnedOnly ? $0.install.pinned.version : nil }
            guard s == "latest" || SettingType.isExactVersion(s) || s == pin else { throw SettingsError("\(key) is latest, or an exact version like 2.1.227") }
            return v
        case (.timeZone, .string(let s)):
            guard s == "mac" || SettingType.isTimeZoneName(s) else { throw SettingsError("\(key) is mac, or a time zone like Australia/Sydney") }
            return v
        case (.permissions, .string(let s)):
            guard SettingType.permissionWords(s) != nil else { throw SettingsError("\(key) is standard, locked, open, or permissions like +web,-error-reports (doz net permissions)") }
            return v
        case (.titleTemplate, .string(let s)):
            if let why = SettingType.titleTemplateProblem(s) { throw SettingsError("\(key): \(why)") }
            return v
        case (.serveBind, .string(let s)):
            guard ServeSettingValues.isBind(s) else { throw SettingsError("\(key) is lan, loopback, or the Mac's own addresses separated by commas (no wildcard, no link-local address)") }
            return v
        case (.originList, .string(let s)):
            guard ServeSettingValues.isOriginList(s) else { throw SettingsError("\(key) is origins like https://doz.home.example (no path), separated by commas, or \"\"") }
            return v
        case (.addressList, .string(let s)):
            guard ServeSettingValues.isAddressList(s) else { throw SettingsError("\(key) is addresses or networks like 127.0.0.1 or 192.168.1.0/24, separated by commas, or \"\"") }
            return v
        case (.dotfiles, .string(let s)):
            if let why = DotfilesSource.problem(s) { throw SettingsError("\(key): \(why)") }
            return v
        case (.appList, .string(let s)):
            guard WorkspaceFiles.appNames(s) != nil else {
                throw SettingsError("\(key) is app names separated by commas (at most 16, each 1–64 characters, no / or ;), or \"\"")
            }
            return v
        default:
            throw SettingsError("\(key) is a \(type.name), not a \(v.typeName)")
        }
    }

    /// A value as a person types it (`doz config set`, an environment variable) → typed + checked.
    public func parse(_ text: String) throws -> TOMLValue {
        let t = text.trimmingCharacters(in: .whitespaces)
        switch type {
        case .bool:
            switch t.lowercased() {
            case "true", "on", "yes", "1": return .bool(true)
            case "false", "off", "no", "0": return .bool(false)
            default: throw SettingsError("\(key) is true or false")
            }
        case .int:
            guard let i = Int(t) else { throw SettingsError("\(key) is a whole number") }
            return try validate(.int(i))
        case .choice, .path, .subnet, .version, .timeZone, .permissions, .appList, .serveBind, .originList, .addressList, .dotfiles:
            return try validate(.string(t))
        case .titleTemplate:
            return try validate(.string(text))          // its spaces are its own
        }
    }

    static func isSubnet(_ s: String) -> Bool {
        let parts = s.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let bits = Int(parts[1]), (8...30).contains(bits) else { return false }
        let octets = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        return octets.count == 4 && octets.allSatisfy { o in
            !o.isEmpty && o.count <= 3 && o.allSatisfy(\.isASCII) && Int(o).map { (0...255).contains($0) } == true
        }
    }
}

public struct SettingsError: Error, Equatable, Sendable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// A setting's effective value and where it came from.
public struct ResolvedSetting: Sendable {
    public let definition: SettingDefinition
    public let value: TOMLValue
    public let source: SettingSource
    /// What the file sets, when it sets a valid value (even when a flag or the environment wins).
    public let fileValue: TOMLValue?
    /// 669: the file's value was read under this old name (`images.claude_code_version`); the next write moves it.
    public var migratedFrom: String? = nil
    public var key: String { definition.key }
}

/// One setting as `doz config show --json` and the UI's Settings page see it. Never a secret:
/// the schema has none.
public struct SettingRow: Codable, Equatable, Sendable {
    public var key: String
    public var section: String
    public var name: String
    public var value: TOMLValue
    public var defaultValue: TOMLValue
    public var source: SettingSource
    public var fileValue: TOMLValue?
    /// bool · int · choice · path · subnet
    public var type: String
    public var typeName: String
    public var choices: [String]?
    public var min: Int?
    public var max: Int?
    public var description: String
    public var environment: String?
    public var flag: String?
    public var applies: SettingApplies
    public var appliesNote: String
    /// The UI may change it: not a host path, not set by the environment or a flag, the file parses.
    public var editable: Bool
    /// Why it is read-only in the UI, when it is.
    public var note: String?
    /// 669: M (Mac), N (a new sandbox's default), S (per sandbox, live) or R (a recipe's agent's).
    public var kind: SettingClass? = nil
    /// 669: a recipe's own setting — the recipe (`anthropic/claude-code`) and its agent's id.
    public var recipe: String? = nil
    public var agent: String? = nil
    /// 669: read from the file under this name from before 669 (the next write moves it).
    public var migratedFrom: String? = nil
    /// 669: the names it had before 669 (still taken by doz config).
    public var aliases: [String]? = nil
}

public struct SettingsReport: Codable, Equatable, Sendable {
    public var path: String?
    public var exists: Bool
    public var warnings: [String]
    public var error: String?
    public var settings: [SettingRow]
    public var notSettable: [String]
    /// 669: one line per value read under its old name (the next write moves it to its new one).
    public var notes: [String]? = nil
}

/// The names of the settings, for the code that reads them.
public enum SettingKey {
    public static let bootViewOnStart = "ui.boot_view_on_start"
    public static let confirmShutdown = "ui.confirm_shutdown"
    public static let splitDefault = "ui.split_default"
    public static let terminals = "ui.terminals"
    /// 599 (594.B4): the terminal title template.
    public static let terminalTitle = "ui.terminal_title"
    public static let terminalFontSize = "ui.terminal_font_size"
    public static let theme = "ui.theme"
    /// 647: the dashboard's spacing — comfortable or compact.
    public static let density = "ui.density"
    /// 647: where the dashboard's notifications show — cards, pills or bell.
    public static let notifications = "ui.notifications"
    public static let detailsOpen = "ui.details_open"
    public static let gridLiveTiles = "ui.grid_live_tiles"
    public static let gridTileSize = "ui.grid_tile_size"
    /// 648: how often the painted session pictures are brought up to date.
    public static let gridRefreshMs = "ui.grid_refresh_ms"
    /// 650: how many lifecycle operations (start, wake, sleep …) the dashboard runs at once; the rest wait their turn.
    public static let batchConcurrency = "ui.batch_concurrency"
    public static let progress = "ui.progress"
    /// 637: colour in the CLI — auto, always, never.
    public static let color = "ui.color"
    public static let idleTimeout = "host.idle_timeout_minutes"
    public static let screenCapture = "host.screen_capture_minutes"
    public static let bootLogsKept = "host.boot_logs_kept"
    public static let keepalive = "host.keepalive"
    public static let storePath = "store.path"
    public static let cpus = "defaults.cpus"
    /// 669 (659 Q8): a new sandbox's memory and network when its image has no agent (a python or go base) — Dozable's
    /// own, seeded by the migration from claude-code's, which such an image followed before.
    public static let defaultMemory = "defaults.memory_mib"
    public static let defaultNetwork = "defaults.network"
    public static let natSubnet = "defaults.nat_subnet"
    /// 594: the image `doz up`/`doz init`/the UI's create form use when none is named; the account
    /// a store that has not chosen one defaults to (`doz account default` wins once it has).
    public static let defaultImage = "defaults.image"
    public static let defaultAccount = "defaults.account"
    /// 634: the store's ONE base — the base a quick-made sandbox's tool is added to (Quick try, `doz try`, the
    /// onboarding's First sandbox) when none is named. `doz onboard` sets it; a project file never follows it.
    public static let defaultBase = "defaults.base"
    /// 594 (D16): the environment prompt (the facts block and the doz skill) — on, or off.
    public static let agentPrompt = "agent.prompt"
    /// 594 W23: the agent's passwordless sudo inside its sandbox (default on).
    public static let agentSudo = "sandbox.agent_sudo"
    /// 594 W10: the sandboxes' time zone (`mac` or an IANA name).
    public static let timeZone = "sandbox.timezone"
    /// 597: the permissions of a new proxied sandbox.
    public static let permissions = "defaults.permissions"
    /// 599 (594.B1): the clipboard bridge — `write` or `off`.
    public static let clipboard = "sandbox.clipboard"
    /// 599 (594.B2): the browser bridge (open a URL on the Mac; a sign-in's callback) — `on` or `off`.
    public static let browserBridge = "sandbox.browser_bridge"
    /// 599 (594.B3): new sessions run inside tmux.
    public static let tmux = "sessions.tmux"
    /// 599b: the file bridge — a /workspace document opened on the Mac — `on` or `off`.
    public static let openFiles = "sandbox.open_files"
    /// 599b: the apps a sandbox may name to open a workspace file in (`doz-open --app NAME`).
    public static let openApps = "bridges.open_apps"
    /// 599d: where "Use GitHub as you" gets the user's token — `gh` (the Mac's gh login), `key` (only a
    /// token given with `doz key set NAME --github`), `off`.
    public static let githubCredentials = "github.credentials"
    /// 599d (G4): forward the Mac's SSH agent into the sandbox — `off` or `on` (per sandbox).
    public static let sshAgent = "sandbox.ssh_agent"
    /// 599g: what a workspace's `.dozignore` does to the paths it selects — `lock` or `hide` (per sandbox).
    public static let ignoreMode = "workspace.ignore_mode"
    /// 608: every share through the live view (on) or the plain share without rules (off).
    public static let workspaceView = "workspace.view"
    /// 657: the person's dotfiles — a git repository (https) or a folder on this Mac; "" = none.
    public static let dotfiles = "sandbox.dotfiles"
    /// 667: sound — `off`, `speakers` (the Mac's speakers) or `on` (speakers and the Mac's microphone). Per sandbox.
    public static let audio = "sandbox.audio"
    /// 667: when doz asks macOS about the microphone — `first_recording` (default) or `first_start` (`MicrophoneAsk`).
    public static let microphoneAsk = "sandbox.microphone_ask"
    /// 599e: "Use GitHub as you" for NEW sandboxes — `off`, `read` or `push` (the Access step's choice).
    public static let defaultGithub = "defaults.github"
    /// 594 (owner ruling): the web UI may take an API key or a setup token (a masked field).
    public static let allowSecretEntry = "ui.allow_secret_entry"
    /// 594 W19 (owner: "a new web page opening up every time i run doz ui"): when `doz ui` opens a tab.
    public static let openBrowser = "ui.open_browser"
    /// 605 (owner Q10): the port `doz ui` listens on — 0 = automatic (the last one, when free). 645: the ONE port (the LAN's too).
    public static let uiPort = "ui.port"
    /// 645: the dashboard's LAN option — also serve the other browsers of the network (`doz serve` before).
    public static let uiLAN = "ui.lan"
    /// 606: `doz serve`, the dashboard for the other browsers of the LAN.
    public static let servePort = "serve.port"
    public static let serveBind = "serve.bind"
    public static let servePublicOrigins = "serve.public_origins"
    public static let serveTrustedProxies = "serve.trusted_proxies"
    public static let serveAdvertise = "serve.advertise"
    /// 594: where the UI's new sandboxes get their workspace by default (`<projects_dir>/<name>`).
    public static let projectsDir = "defaults.projects_dir"
    public static let kernelPath = "kernel.path"
    public static let kernelCache = "kernel.cache"
    /// 595 (R4): Clean up removes a prepared image no sandbox was created from in this many days.
    public static let resourcesUnusedDays = "resources.clean_unused_days"
    /// 611: updates — off | notify | auto, and the channel (stable | beta | canary).
    public static let updatesMode = "updates.mode"
    public static let updatesChannel = "updates.channel"
    /// Anonymous usage statistics of an official build (on by default; a build from the repository sends nothing).
    public static let sendUsageStats = "telemetry.send_anonymous_usage_stats"
    /// The lab's memory and network (`images.lab.*` — the lab is Dozable's own image, not a recipe's).
    public static let labMemory = "images.lab.memory_mib"
    public static let labNetwork = "images.lab.network"

    /// 669: a recipe's own setting — `recipes.VENDOR.PRODUCT.OPTION` (nil: no such recipe).
    public static func recipe(_ agent: String, _ option: String) -> String? {
        AgentRecipes.recipe(agent).map { "\($0.settingsSection).\(option)" }
    }
    /// 594 (owner: "install (optionally) latest claude code (default true)"): the agent's version an image is prepared
    /// with — `latest` (resolved at preparation time) or an exact one. 669: `recipes.anthropic.claude-code.version`
    /// (before: `images.claude_code_version`, an alias now).
    public static func agentVersion(_ image: String) -> String? { recipe(image, RecipeSettings.version) }
    /// 669: whether an agent's approval prompts are skipped (`claude.permissions` before) — nil for an agent with none.
    public static func approvals(_ agent: String) -> String? {
        AgentRecipes.recipe(agent).flatMap { $0.permissionsSettingKey == nil ? nil : "\($0.settingsSection).\(RecipeSettings.approvals)" }
    }
    public static var claudeCodeVersion: String { agentVersion("claude-code")! }
    public static var piVersion: String { agentVersion("pi")! }
    /// 599i: Codex — its version, and whether its approvals and own sandbox are skipped (the VM is the sandbox).
    public static var codexVersion: String { agentVersion("codex")! }
    public static var claudePermissions: String { approvals("claude-code")! }
    public static var codexPermissions: String { approvals("codex")! }
    /// rc.3: run the Mac's own codex near its login's expiry while a sandbox uses it (`mac` for Codex). 669: Codex's
    /// recipe declares it (`com.dozable/settings@1`); `codex.keep_alive` before.
    public static var codexKeepAlive: String { recipe("codex", "keep_alive")! }

    /// 669: the per-sandbox form of a recipe's approvals (`doz config set --sandbox NAME approvals ask`, `approvals:` in
    /// doz_project.yaml): a sandbox's recipe never changes, so its own value is kept under this one word.
    public static let sandboxApprovals = RecipeSettings.approvals
}

public struct DozableSettings: Sendable {
    public static let directoryName = "doz"
    public static let fileName = "doz.toml"

    // MARK: the schema

    static let networks = ["agent", "bake", "locked", "open", "nat", "none"]

    /// Every setting, in file order. CLOSED: a key not here is unknown everywhere (file, CLI, UI). 617: still a fixed
    /// list per build — the keys of the recipe agents (`images.<id>_version`, `<id>.permissions`, `images.<id>.*`) are
    /// generated from the compiled-in recipes (and, in tests, a registered one).
    public static var schema: [SettingDefinition] { indexed.schema }

    /// The schema with its lookups: key → definition, an old name → its key.
    struct Indexed {
        let schema: [SettingDefinition]
        let byKey: [String: Int]
        let aliases: [String: String]
    }
    static var indexed: Indexed {
        let g = AgentRecipes.generation
        schemaLock.lock(); defer { schemaLock.unlock() }
        if let c = schemaCache, c.generation == g { return c.indexed }
        let s = buildSchema()
        var byKey: [String: Int] = [:], aliases: [String: String] = [:]
        for (i, d) in s.enumerated() { byKey[d.key] = i }
        for d in s { for a in d.aliases where byKey[a] == nil { aliases[a] = d.key } }
        let x = Indexed(schema: s, byKey: byKey, aliases: aliases)
        schemaCache = (g, x)
        return x
    }
    nonisolated(unsafe) private static var schemaCache: (generation: Int, indexed: Indexed)?
    private static let schemaLock = NSLock()

    /// The recipe agents (not the built-in three).
    static var recipeAgents: [AgentRecipe] { AgentRecipes.all.filter { !$0.isBuiltin } }

    /// 669: the settings of a new sandbox that it records when it is made (class N, 659 §3).
    public static let newSandboxKeys: Set<String> = [SettingKey.cpus, SettingKey.natSubnet, SettingKey.permissions, SettingKey.defaultGithub,
                                                     SettingKey.dotfiles, SettingKey.labMemory, SettingKey.labNetwork,
                                                     SettingKey.defaultMemory, SettingKey.defaultNetwork]

    /// 669: a 0.37 name of a key (`images.claude_code_version`) → its key; a key → itself; nil: unknown.
    public static func canonicalKey(_ key: String) -> String? {
        let x = indexed
        return x.byKey[key] != nil ? key : x.aliases[key]
    }

    /// 669: the old names the migration ALSO seeds a Dozable key from — a base with no agent followed claude-code's
    /// memory and network before 669, and keeps what it had (659 Q8).
    static let seeds = ["images.claude-code.memory_mib": SettingKey.defaultMemory, "images.claude-code.network": SettingKey.defaultNetwork]

    /// 669: every recipe's own settings (659 §3), generated from the active recipe set, under `recipes.VENDOR.PRODUCT`:
    /// version, approvals (a recipe with prompts to skip), memory and network, then what its `settings@1` declares.
    /// Each keeps its 0.37 name as an alias.
    static func recipeSchema(_ r: AgentRecipe) -> [SettingDefinition] {
        let sec = r.settingsSection
        var s: [SettingDefinition] = []
        let pin = r.install.pinned.version
        let latest = r.isPinnedOnly && !r.isBuiltin
            ? "latest means its pin (\(pin)): this kind is prepared at its pin only"
            : "latest (looked up when its image is baked, then installed at that exact version, integrity-checked; a newer one is only said — doz image bake rebuilds when you choose)"
        s.append(.init(sec, RecipeSettings.version, .version, .string("latest"),
                       "The \(r.title) a new sandbox of this recipe gets (and every base's baked image of it): \(latest), or an exact version like \(pin). A sandbox keeps the version it was made with; doz reset NAME moves it to the current one.",
                       flag: "doz create --agent \(r.id)@VERSION", applies: .nextCreate, agent: r.id, aliases: [r.versionSettingKey]))
        if let old = r.permissionsSettingKey {
            s.append(.init(sec, RecipeSettings.approvals, .choice(["skip", "ask"]), .string("skip"),
                           "\(r.title)'s own approval prompts: skip them (the sandbox is the boundary) or ask, as on a Mac. A sandbox (doz config set --sandbox NAME approvals ask) or its project (approvals: in doz_project.yaml) can choose its own.",
                           flag: "-e \(r.permissionsVariable)=… on run/exec, --approvals on create", applies: .nextSession, agent: r.id, aliases: [old]))
        }
        s.append(.init(sec, RecipeSettings.memory, .int(256...262_144), .int(2048),
                       "Memory (MiB) of a new sandbox of this recipe (a template follows the image it was saved from).",
                       flag: "doz create --memory", applies: .nextCreate, agent: r.id, aliases: ["images.\(r.id).memory_mib"]))
        s.append(.init(sec, RecipeSettings.network, .choice(networks), .string("agent"),
                       "The network of a new sandbox of this recipe: agent, bake, locked, open (proxied presets), nat or none.",
                       flag: "doz create --network", applies: .nextCreate, agent: r.id, aliases: ["images.\(r.id).network"]))
        for o in r.ownSettings ?? [] {
            let type: SettingType, value: TOMLValue
            switch (o.type, o.default) {
            case ("bool", .bool(let b)): type = .bool; value = .bool(b)
            case ("int", .number(let n)): type = .int((o.min ?? 0)...(o.max ?? 0)); value = .int(Int(n))
            case ("choice", .string(let w)): type = .choice(o.choices ?? [w]); value = .string(w)
            default: continue          // RecipeSettings.problem refused it when the recipe was read
            }
            s.append(.init(sec, o.name, type, value, o.summary, applies: SettingApplies(rawValue: o.applies) ?? .now,
                           agent: r.id, aliases: ["\(r.id).\(o.name)"]))
        }
        return s
    }

    static func buildSchema() -> [SettingDefinition] {
        var s: [SettingDefinition] = [
            // 617 (owner, the start sequence): the boot console is tab zero on every start; this only decides whether the
            // page stays on it. Off by default — the agent's tab is what a start is for.
            .init("ui", "boot_view_on_start", .bool, .bool(false),
                  "After Start the page stays on its Console tab (the kernel and vminitd), and marks the agent's tab when it is ready; false (the default): it switches to the agent's tab as soon as that has drawn its screen.",
                  applies: .now),
            .init("ui", "confirm_shutdown", .bool, .bool(true),
                  "Shut Down asks first (its dialog's \"don't ask again\" sets this to false). Reset and Remove always ask with a box to tick.",
                  applies: .now),
            // 635 (owner: closing a tool's tab should not look like stopping it): the note on Home after the agent's tab
            // is closed — every time, until "Don't say this again" turns it off.
            .init("ui", "explain_tab_close", .bool, .bool(true),
                  "Closing an agent's tab returns to the sandbox's Home, which says the agent is still running and that End stops it (its \"Don't say this again\" sets this to false). false: Home does not say it.",
                  applies: .now),
            // 635 (owner): a session's live picture from the sidebar — a screen icon on the row's hover, held half a second.
            .init("ui", "nav_thumbnails", .bool, .bool(true),
                  "Hovering a session in the sidebar shows a screen icon; resting on it for half a second shows the session's live picture (moving to another session then shows its picture at once). false: no icon, no picture.",
                  applies: .now),
            .init("ui", "split_default", .choice(["shell", "watch", "attach", "dialog"]), .string("shell"),
                  "What a terminal's Split opens: shell (a new shell session), watch (a read-only view of the left terminal's session), attach (a second, shared view of it), dialog (choose each time).",
                  applies: .now),
            .init("ui", "terminals", .bool, .bool(true),
                  "Terminals in the browser. false: the UI opens none and refuses a terminal ticket (Terminal.app still works).",
                  applies: .now),
            .init("ui", "terminal_title", .titleTemplate, .string("{sandbox} · {session} · {time}"),
                  "The title doz attach gives your terminal (window or tab) while attached, and a doz ui terminal's tab: {sandbox} {session} {image} {time} (this Mac's, HH:MM, refreshed each minute) {phase}. The terminal's own title comes back when you detach (where the terminal keeps a title stack: iTerm2, Ghostty, kitty, xterm). While doz sets it, a session's own title is not shown; \"\" leaves the title to the session.",
                  applies: .now),
            .init("ui", "terminal_font_size", .int(9...32), .int(13),
                  "The browser terminal's font size, in points (a terminal opened from now on).",
                  applies: .now),
            .init("ui", "theme", .choice(["auto", "light", "dark"]), .string("auto"),
                  "The UI's colours: auto follows macOS.",
                  applies: .now),
            // 647 (owner, the dashboard review's decision 1): the dashboard's density — the same structure and type, less
            // space. The page applies it as data-density on <html>, beside data-theme.
            .init("ui", "density", .choice(["comfortable", "compact"]), .string("comfortable"),
                  "The UI's spacing: comfortable, or compact — tighter rows, tabs, controls and page margins; the text stays the same size.",
                  applies: .now),
            // 647 (owner: "implement all three, switch with a setting"): where the dashboard's notifications show in its header.
            .init("ui", "notifications", .choice(["cards", "pills", "bell"]), .string("cards"),
                  "Where the UI shows its notifications, in its top right corner: cards (a bell, and a column hanging below it, each with its full text and buttons and, for a success, a countdown that waits while the pointer is on any card), pills (one line each along the top, the newest at the right; click one for the rest), or bell (a count; the newest shows beside it for a few seconds; click for the list). Successes go by themselves; a failure stays until you close it. The Notifications page lists every one this tab showed.",
                  applies: .now),
            .init("ui", "details_open", .bool, .bool(true),
                  "A sandbox's page shows its details panel (restore points, network, keys) beside the terminals; false: collapsed.",
                  applies: .now),
            .init("ui", "allow_secret_entry", .bool, .bool(true),
                  "The web UI takes an Anthropic API key or a Claude setup token in a masked field — an account (the setup wizard, Accounts & keys: stored exactly as doz account add stores it, the login keychain) or a sandbox's own key (its page: exactly as doz key set does, held by the host) — sent once, in a request body. false: the pages show the command instead. The UI can turn this off, never on.",
                  applies: .now),
            .init("ui", "open_browser", .choice(["auto", "always", "never"]), .string("auto"),
                  "When doz ui opens a browser tab: auto (only when no page of this store's UI is open — an open page reconnects by itself instead), always (every start), never (it prints the address; doz ui link opens a page). --open and --no-open override it.",
                  applies: .nextCommand),
            .init("ui", "port", .int(0...65_535), .int(0),
                  "The ONE port the dashboard (doz ui) listens on — this Mac's browser at http://127.0.0.1:<port>, and with ui.lan your other browsers at http://<this Mac>.local:<port>. 0 = automatic: without ui.lan, the port this store's last doz ui had when it is free (else one the system picks, and doz ui says so); with ui.lan, serve.port (7443), which never moves. Or a fixed port 1024–65535 (doz ui refuses to start, naming the program, when another holds it). An installed dashboard app belongs to one port: keep it fixed for one.",
                  env: "DOZ_UI_PORT", flag: "--port N", applies: .uiRestart),
            // 645 (owner, one dashboard command): the LAN is an option of doz ui, off by default — outward-facing, so only
            // ever turned on from the Mac (never from the web page).
            .init("ui", "lan", .bool, .bool(false),
                  "Also serve the dashboard to the other browsers of your network (every network interface of this Mac and Tailscale, never a sandbox's network) on the same port: each gets in once with an invite (doz ui share). false (the default): this Mac only. Where it listens and your reverse proxy: the serve.* settings.",
                  env: "DOZ_UI_LAN", flag: "doz ui --lan | --no-lan", applies: .uiRestart, ui: false),
            .init("ui", "grid_live_tiles", .int(1...12), .int(12),
                  "No longer used — every session picture is live (painted from its screen, no terminal per picture). Kept so that an older settings file still reads without a warning.",
                  applies: .now),
            .init("ui", "grid_tile_size", .choice(["small", "medium", "large"]), .string("medium"),
                  "All sessions: the size of a tile.",
                  applies: .now),
            // 648 (owner: "keep at 500ms but make it a setting"): the one feed's period and Home's tab poll.
            .init("ui", "grid_refresh_ms", .int(200...10_000), .int(500),
                  "How often the session pictures (All sessions, All sandboxes, a sandbox's Home) are brought up to date, in milliseconds. Only pictures on screen are asked for, only while the browser tab is shown, and a screen that did not change costs almost nothing. Lower looks livelier and costs more.",
                  applies: .now),
            // 650 (owner: waking 12 at once made each slow, and past 8 the rest were refused): the dashboard's lifecycle
            // lane. Part B measures the default.
            .init("ui", "batch_concurrency", .int(1...8), .int(3),
                  "How many starts, wakes, resumes, sleeps, hibernations and shut-downs the dashboard runs at once; the others wait their turn, shown as queued with a Cancel. One you start on a single sandbox (or by typing in its terminal) goes ahead of those started for many at once. A pause, and a resume from a pause, never wait. A change applies as soon as one ends.",
                  applies: .now),
            .init("ui", "progress", .choice(["animated", "plain"]), .string("animated"),
                  "How a start, wake or bake shows its progress — in the web UI's boot view and in the CLI on a terminal: animated (a spinner on the step under way, download bars, the output's last lines) or plain (one line per step, and a summary line per download). Not a terminal, --json or NO_COLOR: always plain.",
                  env: "DOZ_PROGRESS", flag: "--progress auto|plain", applies: .now),
            // 637 (owner: "colour should be able to be turned off with a flag and setting"): every colour the CLI draws.
            .init("ui", "color", .choice(["auto", "always", "never"]), .string("auto"),
                  "Colour in the CLI's output: auto (on a terminal, unless NO_COLOR is set, TERM is dumb, or with --json or -q), always (even into a pipe or a file), never (plain text; the layout and the symbols stay the same). The dashboard has its own theme (ui.theme).",
                  env: "DOZ_COLOR", flag: "--color auto|always|never, --no-color", applies: .now),
            // 606/645: the dashboard's LAN option (ui.lan). Read-only in the web UI (they decide who reaches the dashboard):
            // doz config set on the Mac. The section keeps its name (`doz serve` was the LAN dashboard's command).
            .init("serve", "port", .int(1024...65_535), .int(7443),
                  "The dashboard's port with ui.lan while ui.port is 0 (automatic) — an earlier name for it: ui.port, when set, wins. It stays the same (devices, an installed app and a bookmark belong to it): when another program holds it, doz ui refuses and names it.",
                  env: "DOZ_SERVE_PORT", flag: "doz ui --lan --port N", applies: .uiRestart, ui: false),
            .init("serve", "bind", .serveBind, .string("lan"),
                  "Where the dashboard listens for your other browsers with ui.lan: lan (every network interface of this Mac and Tailscale — never a sandbox's network), loopback (127.0.0.1 and ::1 only: for a reverse proxy on this Mac), or this Mac's own addresses separated by commas (for a reverse proxy elsewhere on your network). This Mac's own browser is served at 127.0.0.1 in every case.",
                  env: "DOZ_SERVE_BIND", flag: "doz ui --lan --bind lan|loopback|ADDRESSES", applies: .uiRestart, ui: false),
            .init("serve", "public_origins", .originList, .string(""),
                  "The addresses your reverse proxy serves the dashboard at, like https://doz.home.example (comma-separated). A browser may use one only through a proxy listed in serve.trusted_proxies. Over https, keys and tokens may be typed in the dashboard; over plain http they never are (except in this Mac's own browser).",
                  applies: .uiRestart, ui: false),
            .init("serve", "trusted_proxies", .addressList, .string(""),
                  "The reverse proxies whose X-Forwarded-Proto, X-Forwarded-Host and X-Forwarded-For the dashboard believes — their addresses or networks, comma-separated (a proxy on this Mac: 127.0.0.1, ::1). From anyone else those headers are ignored.",
                  applies: .uiRestart, ui: false),
            .init("serve", "advertise", .bool, .bool(true),
                  "With ui.lan, announce the dashboard on your network with Bonjour (\"Dozable on <this Mac>\", http://<this Mac>.local:<port>), so other Macs and phones can find it.",
                  applies: .uiRestart, ui: false),
            .init("host", "idle_timeout_minutes", .int(0...10_080), .int(5),
                  "Minutes with nothing running before the host exits; 0 = never.",
                  env: "DOZ_HOST_IDLE", flag: "doz host start --idle-timeout", applies: .hostRestart),
            .init("host", "screen_capture_minutes", .int(0...1440), .int(5),
                  "Every this many minutes, save the screen of each running sandbox's sessions that printed something since (what a sleep or hibernation falls back on); 0 = only when it pauses, sleeps or hibernates.",
                  env: "DOZ_SCREEN_CAPTURE", applies: .hostRestart),
            .init("host", "boot_logs_kept", .int(1...50), .int(BootLogs.defaultKept),
                  "How many boots of each sandbox to keep (its steps and kernel console — the web UI's Boot log, doz console --boot N); the oldest goes.",
                  env: "DOZ_BOOT_LOGS", applies: .nextBoot),
            .init("host", "keepalive", .bool, .bool(false),
                  "Near a Mac login's expiry, while a sandbox uses it and no Claude Code runs, the host runs the Mac's claude once to renew it.",
                  applies: .newStore),
            .init("store", "path", .path, .string("~/Library/Application Support/doz"),
                  "The store: images, kernels, sandboxes and the host's files.",
                  env: "DOZ_STORE", flag: "--store", applies: .nextCommand, ui: false),
            .init("defaults", "cpus", .int(1...64), .int(2),
                  "CPUs of a new sandbox.",
                  flag: "doz create --cpus", applies: .nextCreate),
            // 669 (659 Q8): a base image with no agent (python, go) had claude-code's memory and network; now Dozable's own.
            .init("defaults", "memory_mib", .int(256...262_144), .int(2048),
                  "Memory (MiB) of a new sandbox whose image has no agent (a base alone: python, go). A recipe's sandboxes have their recipe's own (doz config show --agent ID), the lab its own (images.lab).",
                  flag: "doz create --memory", applies: .nextCreate),
            .init("defaults", "network", .choice(networks), .string("agent"),
                  "The network of a new sandbox whose image has no agent: agent, bake, locked, open (proxied presets), nat or none.",
                  flag: "doz create --network", applies: .nextCreate),
            .init("defaults", "nat_subnet", .subnet, .string(""),
                  "The vmnet subnet of a new --network nat sandbox.",
                  env: "DOZ_SUBNET", flag: "doz create --subnet", applies: .nextCreate),
            .init("defaults", "image", .choice(["lab", "claude-code", "pi", "codex"] + recipeAgents.map(\.id)), .string("lab"),
                  "The image of a new sandbox when none is named (doz up NAME, doz init, the UI's New sandbox). doz onboard writes the one you chose.",
                  flag: "doz create --image", applies: .nextCreate),
            .init("defaults", "base", .choice(BaseCatalogue.ids), .string("node"),
                  "The base image of this store: every tool you try (Quick try, doz try, the setup's first sandbox) is added to it as a layer when no base is named, so a second tool downloads nothing more. doz onboard sets it. New sandbox and doz_project.yaml keep a tool's own default base unless you choose one.",
                  flag: "doz try --base", applies: .nextCreate),
            .init("defaults", "projects_dir", .path, .string(Workspace.projectsDirDefault),
                  "The base folder of new sandboxes' workspaces: the web UI's New sandbox and Quick add, and doz new, share <projects_dir>/<sandbox name> (created when missing, like any workspace). doz create is isolated unless --workspace; doz init uses the folder it runs in. In the web UI, Settings › Choose… sets it with the Mac's folder picker.",
                  applies: .nextCreate, ui: false),
            .init("defaults", "account", .choice(["mac", "none"]), .string("mac"),
                  "The Anthropic account of a store that has not chosen one: mac (this Mac's Claude Code login) or none. doz account default decides for a store once it has.",
                  applies: .newStore),
            .init("agent", "prompt", .bool, .bool(true),
                  "Tell the agent where it runs: a short facts block appended to its system prompt (the sandbox, its /workspace share, the network, credentials) and the doz skill, written at every session start. Your own template: agent-prompt.md beside this file.",
                  applies: .nextSession),
            // 611: updates — the feed is updates.dozable.com/v1/feed.json (signed; Distribution in Updates.swift).
            .init("updates", "mode", .choice(["off", "notify", "auto"]), .string("notify"),
                  "Updates: notify (at most once a day, and when doz ui opens, look for a newer doz and say how to upgrade — one line on a terminal, a banner on the dashboard), auto (also install it: brew upgrade, or the signed download for a tarball install — only while no sandbox runs and no session is attached, else it notifies; then: restart to apply, doz host restart), or off (never look). Never a downgrade; a feed that does not verify is ignored.",
                  env: "DOZ_UPDATES", applies: .nextCommand),
            .init("updates", "channel", .choice(["stable", "beta", "canary"]), .string("stable"),
                  "Which releases you are offered: stable, beta (beta and stable) or canary (every build, first). A Homebrew install's own formula (doz, doz-beta, doz-canary) decides while this is not set; doz upgrade --channel switches both.",
                  applies: .nextCommand),
            // Anonymous usage statistics (Usage.swift): the off switch — with DO_NOT_TRACK and the flags, checked before anything is recorded.
            .init("telemetry", "send_anonymous_usage_stats", .bool, .bool(true),
                  "Official builds send anonymous usage statistics: at most once a day, counts and ranges about how Dozable itself is used (commands by name, failures by exit code, which agents, bases and network presets new sandboxes use, setup sizes as ranges, start and wake times rounded to 50 ms, how long sandboxes ran and slept as ranges, which features were used, this Mac's macOS version, chip family, memory and cores as ranges) with a random install id — never a name, path, host, command argument, file or anything from inside a sandbox. false (or DO_NOT_TRACK=1, or --no-send-anonymous-usage-stats on one command) sends nothing and records nothing. doz telemetry show prints exactly what would be sent. Builds from the open-source repository send nothing whatever this says.",
                  env: "DOZ_SEND_ANONYMOUS_USAGE_STATS", flag: "--no-send-anonymous-usage-stats / --send-anonymous-usage-stats", applies: .nextCommand),
            .init("resources", "clean_unused_days", .int(1...3650), .int(30),
                  "Clean up (the Resources page, doz resources clean) removes a prepared image no sandbox was created from in this many days; it is prepared again when next needed.",
                  applies: .now),
            .init("sandbox", "agent_sudo", .bool, .bool(true),
                  "The agent (the image's user in claude-code and pi sandboxes) has passwordless sudo inside its sandbox, so it can install system packages (sudo apt-get install …). The VM, the network policy and the absent credentials are the boundary — root inside reaches no more than the agent does. Applied at every boot and every agent session start (no image is rebuilt); a sandbox's own choice (doz create --no-agent-sudo, agent_sudo in doz_project.yaml) wins over this.",
                  flag: "doz create --no-agent-sudo / --agent-sudo", applies: .nextSession),
            .init("sandbox", "timezone", .timeZone, .string("mac"),
                  "The sandboxes' time zone: mac (this Mac's, read again at every boot and wake — a laptop that travels while a sandbox sleeps is followed) or a zone like Australia/Sydney. Written to the guest's /etc/localtime; the agent's facts say it.",
                  applies: .nextStartOrWake),
            // 597 (P4): what a new proxied sandbox's agent may do.
            .init("defaults", "permissions", .permissions, .string("standard"),
                  "What a new sandbox's agent may do (its network, as permissions — doz net permissions): standard (talk to its AI model, update itself, install system packages and its base's language packages, use GitHub, send error reports), locked (its AI model only), open (everything, the web included), or standard with changes like +web,-error-reports. Stored by name: a Dozable update that adds a host to a permission reaches every sandbox that has it.",
                  flag: "doz create --allow / --network", applies: .nextCreate),
            .init("sandbox", "clipboard", .choice(["write", "off"]), .string("write"),
                  "The clipboard bridge: a program in a sandbox that copies (OSC 52 — Claude Code, vim, tmux) puts the text on this Mac's clipboard, and every copy shows a notice (SANDBOX copied N chars) in doz attach and doz ui. At most 1 MiB a copy and 10 copies in 10 s. A sandbox can never READ the Mac clipboard. The risk: an agent could put a command there for you to paste — off turns the bridge off (copies are dropped, and said). A sandbox's own choice (doz config set --sandbox NAME, clipboard in doz_project.yaml) wins over this.",
                  flag: "doz create --clipboard write|off", applies: .now),
            .init("sandbox", "browser_bridge", .choice(["on", "off"]), .string("on"),
                  "The browser bridge: xdg-open (and $BROWSER, open, sensible-browser) in a sandbox opens an http or https URL in this Mac's default browser, with a notice every time (at most 3 in 10 s). A sign-in whose redirect is the sandbox's localhost (Claude Code's /login) gets that port forwarded from the Mac into the sandbox for up to 10 minutes, so the login completes. Never file: or other schemes, never the Mac's own localhost. off: nothing opens (said). A sandbox's own choice (doz config set --sandbox NAME, browser_bridge in doz_project.yaml) wins over this.",
                  flag: "doz create --browser-bridge on|off", applies: .now),
            .init("sandbox", "open_files", .choice(["on", "off"]), .string("on"),
                  "Open workspace files on this Mac: xdg-open PATH (and open PATH, doz-open PATH) in a sandbox opens a document from its /workspace in the Mac's default app — an html page in your browser, markdown in your editor — or a folder (the workspace itself, open .) in the Finder, and doz-open --reveal PATH shows a file selected in its folder; a notice every time (at most 3 in 10 s). Only the shared folder's own files (a link or .. that leads out is refused), only documents (html, md, pdf, images, txt, csv, json, yaml, xml…) — never an app or package folder, a script, an installer or an executable. An isolated sandbox has no file to open. An app other than the default only when it is in bridges.open_apps. off: nothing opens (said). A sandbox's own choice (doz config set --sandbox NAME, open_files in doz_project.yaml) wins over this.",
                  flag: "doz create --open-files on|off", applies: .now),
            .init("sessions", "tmux", .bool, .bool(false),
                  "Run each new session inside tmux (within Dozable's own session holder, so saved screens, sleep and wake, browser terminals and Ctrl-] detach keep working): tmux's windows, panes and copy mode, its status bar and prefix key (Ctrl-b). tmux takes the mouse, and the kitty keyboard protocol and modifyOtherKeys do not fully pass through it; the session's exit code is tmux's. It is Dozable's own tmux 3.8, copied into the sandbox on every base (the image's tmux is left as it is), so tmux reports your terminal's light or dark theme to the programs in it; a session already running in the image's tmux keeps it until it ends. A sandbox's own choice (doz create --tmux, tmux: true in doz_project.yaml, doz config set --sandbox) wins over this.",
                  flag: "doz create --tmux / --no-tmux", applies: .nextSession),
            .init("bridges", "open_apps", .appList, .string(""),
                  "The Mac apps a sandbox may name to open a workspace file in (doz-open --app NAME FILE, or open -a NAME FILE in the sandbox), comma-separated — e.g. \"Typora, Visual Studio Code\". Empty: a file opens only in its default app, and naming an app is refused. Never a path, only an app's name. For every sandbox.",
                  applies: .now),
            .init("sandbox", "ssh_agent", .choice(["off", "on"]), .string("off"),
                  "Forward this Mac's SSH agent into the sandbox (proxied sandboxes): ssh and git over SSH there can ask your agent to sign — your keys never enter the sandbox — and only github.com:22 is reachable over SSH. A notice on first use. While it is on, the agent can authenticate as you to github.com. A sandbox's own choice (doz create --ssh-agent on, ssh_agent in doz_project.yaml, doz config set --sandbox NAME) wins over this.",
                  flag: "doz create --ssh-agent on|off", applies: .now),
            .init("workspace", "ignore_mode", .choice(["lock", "hide"]), .string("lock"),
                  "What a .dozignore at the root of a sandbox's workspace folder does to the paths it lists (Docker's .dockerignore syntax): lock (they stay listed, shown with no permissions, and every read, write, rename or delete of them is refused — so a program that bumps into one by name sees why) or hide (they are not there at all). A .dozreadonly beside it (same syntax) makes paths visible but read-only; doz_project.yaml, .git/hooks and the two rule files are read-only too. Without either file the folder is shared as it is. A convenience mask, not a security boundary: root in the sandbox can get around it. A sandbox's own choice (doz create --ignore-mode, ignore_mode in doz_project.yaml, doz config set --sandbox NAME) wins over this.",
                  flag: "doz create --ignore-mode lock|hide", applies: .nextStartOrWake),
            .init("workspace", "view", .choice(["on", "off"]), .string("on"),
                  "How a sandbox's workspace folder reaches it. on: through Dozable's live view of the folder, so a program working in /workspace (an agent, a shell) keeps its folder when the sandbox wakes from hibernation or after a host restart. The view costs a little: the first scan of a big folder after a start or a wake is slower (e.g. git status on a large repository, or find), later ones are about as fast as without it. off: the folder is shared directly (a little faster) — but a program working inside /workspace loses its folder at such a wake and must be restarted (Codex says \"invalid cwd\"). A folder with a .dozignore or .dozreadonly always uses the view. Changes take effect at the sandbox's next start. A sandbox's own choice (doz create --workspace-view, workspace_view in doz_project.yaml, doz config set --sandbox NAME) wins over this.",
                  flag: "doz create --workspace-view on|off", applies: .nextStart),
            // 657 (owner: "the user's dotfiles … so that every shell experience in each VM is familiar").
            .init("sandbox", "dotfiles", .dotfiles, .string(""),
                  "Your dotfiles in every new sandbox: a git repository (https://github.com/you/dotfiles — fetched on this Mac with its own git login, so a private one works and no credential enters the sandbox) or a folder on this Mac that is a git repository. A sandbox gets the commit it was made at, recorded; doz dotfiles NAME --update moves it on. At its first start, as its user: the repository's install script runs (the first of install.sh, install, bootstrap.sh, bootstrap, script/bootstrap, setup.sh, setup, script/setup — at most 5 minutes, its output in the boot log), or, with none, every dotfile and dot-folder at the top of the repository is linked into the home — never over a file that is there (only over the image's stock copy, kept as NAME.doz-stock), never over Dozable's own (the agents' settings and launchers). doz asks once per repository and commit before it is applied — it is code that runs in the sandbox. \"\" (the default): none. A sandbox's own choice (doz create --dotfiles, dotfiles in doz_project.yaml) wins over this.",
                  flag: "doz create --dotfiles URL|PATH|none", applies: .nextCreate),
            // 667 (owner: "sound as a real per-sandbox setting"; 604's experiment was the --audio flag alone).
            .init("sandbox", "audio", .choice(SoundMode.allCases.map(\.rawValue)), .string("off"),
                  "Sound in new sandboxes: off, speakers (this Mac's speakers) or on (its speakers and microphone). A sandbox with sound has a sound device and boots Dozable's sound kernel, so it is chosen at create; its own choice (doz create --sound, New sandbox › Sound) wins over this. Later a sandbox can move between speakers and on (doz config set --sandbox NAME sandbox.audio on), from its next start. It records from the Mac's microphone only if macOS allowed it before the sandbox started (else silence); sandbox.microphone_ask says when doz asks.",
                  flag: "doz create --sound off|speakers|on (--audio = on)", applies: .nextCreate),
            // 667 (owner, 2026-10-27: "make it configurable (default to when first records)").
            .init("sandbox", "microphone_ask", .choice(MicrophoneAsk.allCases.map(\.rawValue)), .string(MicrophoneAsk.firstRecording.rawValue),
                  "When doz asks macOS about the microphone for a sandbox whose sound is on, while macOS has no answer: first_recording (when a program in it first records — that recording is silent; allow, then Shut Down and Start the sandbox) or first_start (when it starts, waiting for your answer).",
                  applies: .nextStartOrWake),
            .init("defaults", "github", .choice(["off", "read", "push"]), .string("off"),
                  "\"Use GitHub as you\" for new sandboxes: off, read (git and gh signed in as you on GitHub, read-only) or push (also push and make changes) — the Access step's choice (doz access set --github). A sandbox can differ: doz create --github, github: in doz_project.yaml, or its permissions later (doz net allow|deny NAME github:as-you). Proxied sandboxes only.",
                  flag: "doz create --github off|read|push", applies: .nextCreate),
            .init("github", "credentials", .choice(["gh", "key", "off"]), .string("gh"),
                  "Where \"Use GitHub as you\" (a permission, off by default) gets your GitHub login: gh (this Mac's gh login, read when used — gh auth token — and kept in memory a few minutes, never written anywhere; gh auth logout revokes it), key (only a token you give a sandbox with doz key set NAME --github — a fine-grained token limited to some repositories is best), or off (never, even with the permission on). The sandbox only ever sees a placeholder; Dozable's proxy puts the real token in on the way to GitHub.",
                  applies: .now),
        ]
        // The lab is Dozable's own image: its memory and network stay Dozable's settings.
        s.append(.init("images.lab", "memory_mib", .int(256...262_144), .int(1024),
                       "Memory (MiB) of a new lab sandbox (a template follows the image it was saved from).",
                       flag: "doz create --memory", applies: .nextCreate))
        s.append(.init("images.lab", "network", .choice(networks), .string("bake"),
                       "The network of a new lab sandbox: agent, bake, locked, open (proxied presets), nat or none.",
                       flag: "doz create --network", applies: .nextCreate))
        s.append(.init("kernel", "path", .path, .string(""),
                       "An explicit Linux kernel for new sandboxes (\"\": the pinned kernel, fetched into the cache).",
                       env: "DOZ_KERNEL", applies: .nextCreate, ui: false))
        s.append(.init("kernel", "cache", .path, .string(""),
                       "Where the pinned kernel is cached (\"\": the store's own); share one between stores.",
                       env: "DOZ_KERNEL_CACHE", applies: .nextCreate, ui: false))
        // 669: every recipe's own settings — the built-in three's too (no hand-written key is left for them).
        for r in AgentRecipes.all { s += recipeSchema(r) }
        return s
    }

    /// The definition of a key — or of a 0.37 name of one (669: `images.claude_code_version` is
    /// `recipes.anthropic.claude-code.version`).
    public static func definition(_ key: String) -> SettingDefinition? {
        let x = indexed
        if let i = x.byKey[key] { return x.schema[i] }
        return x.aliases[key].flatMap { x.byKey[$0] }.map { x.schema[$0] }
    }

    /// 669: one recipe's settings (its agent's id).
    public static func recipeDefinitions(_ agent: String) -> [SettingDefinition] { schema.filter { $0.agent == agent } }

    /// 669: the recipe a person names for its settings (`--agent`): its id or an alias (`claude`), an `AgentRef`
    /// (`opencode@2`), or its qualified name (`anthropic/claude-code`). An unpublished recipe's settings stay reachable
    /// (a stored value of it must be), so this never refuses one.
    public static func recipe(named s: String) -> AgentRecipe? {
        let t = s.lowercased()
        if let r = AgentRecipes.recipe(t) ?? AgentRecipes.matching(t) { return r }
        if let r = AgentRecipes.all.first(where: { $0.qualifiedID == t }) { return r }
        return (try? AgentRef.resolveAny(t, in: AgentRecipes.all))?.recipe
    }

    /// 669: a recipe's option as a key (`--agent claude-code version` → `recipes.anthropic.claude-code.version`); a full
    /// key (or a 0.37 name) of that recipe is taken too.
    public static func recipeKey(_ r: AgentRecipe, _ name: String) -> String? {
        let mine = recipeDefinitions(r.id)
        if let d = mine.first(where: { $0.name == name }) { return d.key }
        if let k = canonicalKey(name), mine.contains(where: { $0.key == k }) { return k }
        return nil
    }

    /// 599: the settings a sandbox can also have its own value of (`doz config set --sandbox NAME KEY V`,
    /// `doz create`, `doz_project.yaml`) — the sandbox's value wins over the file's.
    public static let perSandbox: [String] = [SettingKey.clipboard, SettingKey.browserBridge, SettingKey.openFiles, SettingKey.sshAgent,
                                              SettingKey.tmux, SettingKey.agentSudo, SettingKey.ignoreMode,
                                              SettingKey.workspaceView, SettingKey.audio]

    /// 669 (659 Q7): every key a sandbox (and its project) can have its own value of — Dozable's own per-sandbox
    /// settings, and `approvals`: its recipe's (`recipes.V.P.approvals`), kept under the one word because a sandbox's
    /// recipe never changes.
    public static var sandboxKeys: [String] { perSandbox + [SettingKey.sandboxApprovals] }

    /// 669: a per-sandbox key's definition — `approvals` is the recipe's of `image` (an image whose agent has no
    /// prompts to skip: nil); with no image, any recipe's (they are one type: skip | ask), to check a value.
    public static func sandboxDefinition(_ key: String, image: String? = nil) -> SettingDefinition? {
        guard key == SettingKey.sandboxApprovals else { return perSandbox.contains(key) ? definition(key) : nil }
        guard let image else { return definition(SettingKey.claudePermissions) }
        return approvalsKey(image: image).flatMap(definition)
    }

    /// 669: the approvals setting of an image's agent (`recipes.anthropic.claude-code.approvals`); nil: none.
    public static func approvalsKey(image: String?) -> String? {
        guard let image, let r = (ImageChoice.parse(image)?.agent ?? AgentKind(rawValue: image))?.recipe else { return nil }
        return SettingKey.approvals(r.id)
    }

    /// 669: a per-sandbox key's value for a sandbox of `image`: flag (a session's own `-e`), its own (`sandbox`, or
    /// `project` when doz up synced it), then this Mac's, then the default — one `resolve`.
    public func resolveForSandbox(_ key: String, image: String?, own: TOMLValue?, from: String?) -> ResolvedSetting? {
        let k = key == SettingKey.sandboxApprovals ? Self.approvalsKey(image: image) : key
        guard let k, Self.definition(k) != nil else { return nil }
        return from == "project" ? resolve(k, project: own) : resolve(k, sandbox: own)
    }

    /// What cannot be set here, by design, and why — printed in the file and the docs.
    public static let notSettable: [String] = [
        "the web UI's limits: session lifetime (14 days unused), link lifetime (5 min), request body, connection and stream caps",
        "the web UI's checks: exact Host, Origin + CSRF on every change, the Content-Security-Policy",
        "the browser terminal's safety: one-use 30 s tickets, the 1 MiB paste cap and the unsafe-paste confirmation",
        "the guest binaries (DOZ_DECKHOLD / DOZ_DOZNET are developer overrides, environment only)",
        "credentials: keys and tokens live in the Keychain or the host's memory, never in this file (ui.allow_secret_entry only decides whether the web UI may take one)",
    ]

    // MARK: the file

    /// `${XDG_CONFIG_HOME:-$HOME/.config}/doz/doz.toml`. XDG_CONFIG_HOME counts only when
    /// absolute (the XDG rule). Nil when neither is set (then there is no file: defaults only).
    public static func fileURL(environment env: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        let base: URL
        if let x = env["XDG_CONFIG_HOME"], x.hasPrefix("/") {
            base = URL(fileURLWithPath: x, isDirectory: true)
        } else if let h = env["HOME"], h.hasPrefix("/") {
            base = URL(fileURLWithPath: h, isDirectory: true).appendingPathComponent(".config", isDirectory: true)
        } else {
            return nil
        }
        return base.appendingPathComponent(directoryName, isDirectory: true).appendingPathComponent(fileName)
    }

    public let url: URL?
    public let environment: [String: String]
    /// The file's valid, known values (key → value).
    public let fileValues: [String: TOMLValue]
    /// Keys the schema does not know, kept as they were when the file is rewritten.
    public let unknown: [TOMLEntry]
    public let warnings: [String]
    /// The file did not parse: none of it applies, and it is not overwritten.
    public let fileError: String?
    public let fileExists: Bool
    /// What `defaults.projects_dir` means while unset: `~/doz-workspaces` (`Workspace.unsetProjectsDir`;
    /// tests inject another).
    public let unsetProjectsDir: String
    /// 669: the values read under a 0.37 name — key → that name (`recipes.anthropic.claude-code.version` →
    /// `images.claude_code_version`). The first write after the upgrade moves them (`writingAll`).
    public let migrated: [String: String]
    /// 669: the file still has lines under a 0.37 name (moved, or kept because the new name disagrees).
    public let hasOldNames: Bool
    /// The file's text as it was read (the one-off `doz.toml.0.37.bak` of the first write after the upgrade).
    let text: String?
    /// 669: set on what `writingAll` returns when that write moved the file's 0.37 names: what it said.
    public internal(set) var migrationNotice: String? = nil

    /// 669: the one-off copy of the file the first write after the upgrade leaves beside it.
    public static let backupName = "doz.toml.0.37.bak"

    /// Read the file named by `environment` (defaults only when there is none).
    public static func load(environment: [String: String] = ProcessInfo.processInfo.environment) -> DozableSettings {
        let url = fileURL(environment: environment)
        guard let url else { return DozableSettings(text: nil, url: nil, environment: environment) }
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return DozableSettings(text: nil, url: url, environment: environment) }
        guard (st.st_mode & S_IFMT) == S_IFREG || (st.st_mode & S_IFMT) == S_IFLNK else {
            return DozableSettings(text: nil, url: url, environment: environment, readError: "\(url.path) is not a file")
        }
        guard st.st_size <= off_t(TOML.maximumBytes), let data = FileManager.default.contents(atPath: url.path) else {
            return DozableSettings(text: nil, url: url, environment: environment, readError: "\(url.path) could not be read (or is over \(TOML.maximumBytes / 1024) KiB)")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            return DozableSettings(text: nil, url: url, environment: environment, readError: "\(url.path) is not UTF-8")
        }
        return DozableSettings(text: text, url: url, environment: environment)
    }

    /// From a file's text (nil: no file).
    public init(text: String?, url: URL? = nil, environment: [String: String] = [:], readError: String? = nil,
                unsetProjectsDir: String = Workspace.unsetProjectsDir()) {
        self.unsetProjectsDir = unsetProjectsDir
        self.url = url
        self.environment = environment
        self.text = text
        var values: [String: TOMLValue] = [:]
        var unknown: [TOMLEntry] = []
        var warnings: [String] = []
        var migrated: [String: String] = [:]
        var oldNames = false
        var fileError = readError
        if let text {
            do {
                let entries = try TOML.parse(text)
                let x = Self.indexed
                // The keys under their own names first: a 0.37 name never overrides its new one (669, 659 §5).
                var old: [TOMLEntry] = []
                for e in entries {
                    guard let i = x.byKey[e.path] else {
                        if x.aliases[e.path] != nil { old.append(e) } else {
                            unknown.append(e)
                            warnings.append("line \(e.line): unknown setting \(e.path) — ignored")
                        }
                        continue
                    }
                    do { values[e.path] = try x.schema[i].validate(e.value) } catch let err as SettingsError {
                        warnings.append("line \(e.line): \(err.message) — ignored, the default applies")
                    } catch {}
                }
                // 669: a 0.37 name (`images.claude_code_version`, `claude.permissions`) is read as its new key, sourced
                // from the Mac, with a note; the first write moves it. Both set and different: the new one wins, the old
                // line is kept as it was, and a warning names both.
                let own = Set(values.keys)
                for e in old {
                    oldNames = true
                    guard let key = x.aliases[e.path], let d = Self.definition(key) else { continue }
                    let v: TOMLValue
                    do { v = try d.validate(e.value) } catch let err as SettingsError {
                        warnings.append("line \(e.line): \(e.path) (now \(key)): \(err.message) — ignored, the default applies")
                        continue
                    } catch { continue }
                    if own.contains(key) {
                        if values[key] != v {
                            unknown.append(e)
                            warnings.append("line \(e.line): \(e.path) = \(v.plain) is the old name of \(key), which this file sets to \(values[key]!.plain) — \(key) wins; the old line is kept as it was")
                        }
                    } else {
                        values[key] = v
                        migrated[key] = e.path
                    }
                    // 659 Q8: a base with no agent keeps the memory and network it followed (claude-code's).
                    if let seed = Self.seeds[e.path], !own.contains(seed), values[seed] == nil,
                       let sd = Self.definition(seed), let sv = try? sd.validate(v) {
                        values[seed] = sv
                        migrated[seed] = e.path
                    }
                }
            } catch let e as TOMLError {
                fileError = "\(url?.lastPathComponent ?? Self.fileName) \(e.description)"
            } catch {
                fileError = "\(error)"
            }
        }
        if let fileError {
            values = [:]
            unknown = []
            migrated = [:]
            oldNames = false
            warnings.insert("\(fileError) — the file is ignored until it is fixed (or removed)", at: 0)
        }
        fileValues = values
        self.unknown = unknown
        self.warnings = warnings
        self.fileError = fileError
        self.migrated = migrated
        hasOldNames = oldNames
        fileExists = text != nil || readError != nil
    }

    /// 669: one line per value read under its 0.37 name.
    public var migrationNotes: [String] {
        migrated.sorted { $0.key < $1.key }.map { "\($0.value) is now \($0.key) — read under its old name; the next write of doz.toml moves it" }
    }

    // MARK: resolution

    /// A setting's effective value (669, 659 §4 — one precedence for every setting): `flag`, else its environment
    /// variable, else the sandbox's own value, else its project's, else the file (this Mac's), else the default — the
    /// recipe's own (`recipe`) or Dozable's (`default`). A setting of the Mac's kind (class M) has no sandbox or project
    /// layer: those are ignored for it. An environment value that does not parse is skipped (as if unset). A fractional
    /// environment value of an integer setting (`DOZ_HOST_IDLE=0.5`) is kept as its text — the host reads it so. A 0.37
    /// name of a key resolves that key.
    public func resolve(_ key: String, flag: TOMLValue? = nil, sandbox: TOMLValue? = nil, project: TOMLValue? = nil) -> ResolvedSetting {
        guard let d = Self.definition(key) else { preconditionFailure("unknown setting \(key)") }
        let file = fileValues[d.key]
        let from = migrated[d.key]
        func r(_ v: TOMLValue, _ s: SettingSource) -> ResolvedSetting {
            ResolvedSetting(definition: d, value: v, source: s, fileValue: file, migratedFrom: s == .mac ? from : nil)
        }
        if let flag { return r(flag, .flag) }
        if let name = d.environment, let raw = environment[name], !raw.isEmpty {
            if let v = try? d.parse(raw) { return r(v, .env) }
            if case .int = d.type, let x = Double(raw), x >= 0 { return r(.string(raw), .env) }
        }
        if d.settingClass.hasSandboxLayers {
            if let sandbox { return r(sandbox, .sandbox) }
            if let project { return r(project, .project) }
        }
        if let file { return r(file, .mac) }
        if d.key == SettingKey.projectsDir { return r(.string(unsetProjectsDir), .default) }
        return r(d.defaultValue, d.defaultSource)
    }

    /// Every setting, resolved, in file order.
    public var all: [ResolvedSetting] { Self.schema.map { resolve($0.key) } }

    public func bool(_ key: String) -> Bool {
        if case .bool(let b) = resolve(key).value { return b }
        if case .bool(let b) = Self.definition(key)?.defaultValue { return b }
        return false
    }

    public func int(_ key: String) -> Int {
        let r = resolve(key)
        if case .int(let i) = r.value { return i }
        if case .string(let s) = r.value, let x = Double(s) { return Int(x) }
        if case .int(let i) = r.definition.defaultValue { return i }
        return 0
    }

    /// A string setting; nil when empty (`""` = automatic).
    public func string(_ key: String) -> String? {
        if case .string(let s) = resolve(key).value, !s.isEmpty { return s }
        return nil
    }

    /// The host's idle timeout in minutes: `--idle-timeout`, else `$DOZ_HOST_IDLE` (fractions
    /// allowed, as always), else the file, else 5.
    public func idleTimeoutMinutes(flag: Double?) -> Double {
        if let flag { return flag }
        if let raw = environment["DOZ_HOST_IDLE"], let x = Double(raw), x >= 0 { return x }
        return Double(int(SettingKey.idleTimeout))
    }

    /// The keys a new sandbox's memory and network come from, by its imageSpec (a custom image follows the image it
    /// was saved from): the lab's own (`images.lab.*`) without one; 596: a base × agent image follows its AGENT —
    /// 669: its recipe's (`recipes.V.P.memory_mib`); a base with no agent (python, go) Dozable's `defaults.*` (it
    /// followed claude-code's before 669, and the migration seeds them from it).
    public static func imageKeys(imageSpecName: String?) -> (memory: String, network: String) {
        guard let n = imageSpecName else { return (SettingKey.labMemory, SettingKey.labNetwork) }
        let agent = ImageChoice.parse(n)?.agent ?? AgentKind(rawValue: n)
        if let r = agent?.recipe, let m = SettingKey.recipe(r.id, RecipeSettings.memory), let w = SettingKey.recipe(r.id, RecipeSettings.network) {
            return (m, w)
        }
        return (SettingKey.defaultMemory, SettingKey.defaultNetwork)
    }

    // MARK: reporting (doz config show --json, the UI's Settings page)

    /// Every setting with its value, default, source and description. `flags`: the values this
    /// process was given on its command line (only `store.path` can be: `--store`).
    /// 629: `offered` (the dashboard's Settings page): an unpublished agent's own settings are listed only once one of
    /// them is set here, and defaults.image offers the published agents — every key stays accepted. `doz config show`
    /// lists the whole schema.
    public func report(flags: [String: TOMLValue] = [:], offered: Bool = false) -> SettingsReport {
        let held = Set(Self.schema.compactMap { d in d.agent.flatMap { fileValues[d.key] != nil ? $0 : nil } })
        let listed = !offered ? Self.schema : Self.schema.filter { d in d.agent.map { AgentRecipes.isPublished($0) || held.contains($0) } ?? true }
        let rows = listed.map { d -> SettingRow in
            let r = resolve(d.key, flag: flags[d.key])
            var kind = "string", choices: [String]?, lo: Int?, hi: Int?
            switch d.type {
            case .bool: kind = "bool"
            case .int(let range): kind = "int"; lo = range.lowerBound; hi = range.upperBound
            case .choice(let c):
                kind = "choice"; choices = c
                // 629: defaults.image offers the published agents (and keeps showing the value it has).
                if offered, d.key == SettingKey.defaultImage {
                    let have: String? = { if case .string(let v) = r.value { return v }; return nil }()
                    choices = c.filter { AgentRecipes.isPublished($0) || $0 == have }
                }
            case .path: kind = "path"
            case .subnet: kind = "subnet"
            case .version: kind = "version"
            case .timeZone: kind = "timezone"
            case .permissions: kind = "permissions"
            case .titleTemplate: kind = "template"
            case .appList: kind = "apps"
            case .serveBind: kind = "bind"
            case .originList: kind = "origins"
            case .addressList: kind = "addresses"
            case .dotfiles: kind = "dotfiles"
            }
            var note: String?
            switch r.source {
            case .env: note = "set by $\(d.environment ?? "?") in this process's environment — change it there (the file's value, if any, is overridden)"
            case .flag: note = "set on this process's command line (\(d.flag ?? "a flag"))"
            case .mac, .default, .recipe, .sandbox, .project: break
            }
            if !d.editableInUI, note == nil {
                // 599c: the projects folder has the web UI's Choose… (the Mac's folder picker) too.
                note = d.key == SettingKey.projectsDir
                    ? "a host path — Choose… (this Mac's folder picker), or doz config set \(d.key) PATH"
                    : d.section == "serve" || d.key == SettingKey.uiLAN ? "who reaches the dashboard is set on the Mac: doz config set \(d.key) VALUE"
                    : "a host path — set it with: doz config set \(d.key) PATH"
            }
            if fileError != nil, note == nil { note = "the settings file does not parse — fix it (or remove it) first" }
            return SettingRow(key: d.key, section: d.section, name: d.name, value: r.value, defaultValue: d.defaultValue,
                              source: r.source, fileValue: r.fileValue, type: kind, typeName: d.type.name, choices: choices,
                              min: lo, max: hi, description: d.summary, environment: d.environment, flag: d.flag,
                              applies: d.applies, appliesNote: d.applies.note,
                              editable: d.editableInUI && r.source != .env && r.source != .flag && fileError == nil, note: note,
                              kind: d.settingClass, recipe: d.agent.flatMap(AgentRecipes.recipe)?.qualifiedID, agent: d.agent,
                              migratedFrom: r.migratedFrom, aliases: d.aliases.isEmpty ? nil : d.aliases)
        }
        return SettingsReport(path: url?.path, exists: fileExists, warnings: warnings, error: fileError, settings: rows,
                              notSettable: Self.notSettable, notes: migrated.isEmpty ? nil : migrationNotes)
    }

    // MARK: writing

    /// Set (`value`) or clear (nil) one key and write the file. Refuses an unknown key, a bad value,
    /// or a file that does not parse (it is the person's, and would be lost).
    /// 669: a key may be given by its 0.37 name (it is written under its new one).
    @discardableResult
    public func writing(_ key: String, _ value: TOMLValue?) throws -> DozableSettings {
        guard let d = Self.definition(key) else { throw SettingsError("unknown setting \(key) — doz config show lists them") }
        var values = fileValues
        if let value { values[d.key] = try d.validate(value) } else { values[d.key] = nil }
        return try writingAll(values)
    }

    /// Write the file as the schema generates it, with these values (and the unknown keys kept).
    /// 669 (659 §5, M1): the first write after the upgrade of a file with 0.37 names first keeps the file as it was in
    /// `doz.toml.0.37.bak` beside it (once, 0600 — never over one that is there), then writes the new shape, and says so
    /// (`migrationNotice`). A read never writes; a file that does not parse is never touched.
    @discardableResult
    public func writingAll(_ values: [String: TOMLValue]) throws -> DozableSettings {
        guard let url else { throw SettingsError("no settings file: neither XDG_CONFIG_HOME nor HOME is set") }
        if let fileError { throw SettingsError("\(fileError) — fix it or remove it first; it was not changed") }
        var notice: String?
        if hasOldNames, let text {
            let bak = url.deletingLastPathComponent().appendingPathComponent(Self.backupName)
            var st = stat()
            if lstat(bak.path, &st) != 0 { try Self.writeAtomically(text, to: bak) }
            let n = Set(migrated.values).count
            notice = "doz.toml moved \(n) setting\(n == 1 ? "" : "s") to \(n == 1 ? "its" : "their") new name\(n == 1 ? "" : "s") ([recipes.*]) — the old file is \(Self.backupName)"
        }
        try Self.writeAtomically(Self.render(values: values, unknown: unknown), to: url)
        var now = Self.load(environment: environment)
        now.migrationNotice = notice
        return now
    }

    /// 669: how many settings a file with these values lists — Dozable's own, and each recipe's block with a value set.
    public static func listedCount(values: [String: TOMLValue]) -> Int {
        let active = Set(schema.compactMap { d in d.agent.flatMap { values[d.key] != nil ? $0 : nil } })
        return schema.filter { d in d.agent.map(active.contains) ?? true }.count
    }

    /// The comment that stands for every recipe's settings not written out (`render`).
    static let agentSettingsNote = "A recipe's own settings (its agent's version, approvals, memory_mib, network) are written in a [recipes.VENDOR.PRODUCT] block only once one of them is set: `doz config show --agent ID` lists them, `doz config set --agent ID NAME VALUE` writes them."

    /// The file's text: a header, then every section and setting of the schema, each with its
    /// description and its default commented out, unless `values` sets it. 617 (owner: the file grew ~1.5 KiB per
    /// recipe): a recipe agent's own settings are written only when that agent has a value set — its whole block then,
    /// defaults commented as usual; otherwise nothing, and one comment says where they are listed. Reading is unchanged:
    /// any agent's key set by hand parses and applies.
    public static func render(values: [String: TOMLValue], unknown: [TOMLEntry] = []) -> String {
        var out = """
        # Dozable settings (doz.toml)
        #
        # Every setting is listed with its default, commented out: `# key = default`. Uncomment a line
        # to set it. A recipe's own settings appear once one of them is set (see the end of the header).
        # `doz config set KEY VALUE` and the UI's Settings page write this file for you;
        # they regenerate it from the settings list, so comments you add are not kept.
        #
        # Precedence: a command-line flag, then the environment variable named, then a sandbox's own
        # value, then its project's (doz_project.yaml), then this file, then the default (a recipe's
        # own, or Dozable's). `doz config show` prints every value and where it came from.
        #
        # Not settable, by design:

        """
        for n in notSettable { out += "#   - \(n)\n" }
        out += "#\n" + wrapComment(agentSettingsNote)
        let all = schema
        let active = Set(all.compactMap { d in d.agent.flatMap { values[d.key] != nil ? $0 : nil } })
        let shown = all.filter { d in d.agent.map(active.contains) ?? true }
        var sections: [String] = []
        for d in all where !sections.contains(d.section) { sections.append(d.section) }
        for section in sections {
            let defs = shown.filter { $0.section == section }
            let extra = unknown.filter { $0.section == section }
            guard !defs.isEmpty || !extra.isEmpty else { continue }
            out += "\n[\(section)]\n"
            for d in defs {
                out += "\n" + wrapComment(d.summary)
                var facts: [String] = [d.type.name]
                if let e = d.environment { facts.append("env \(e)") }
                if let f = d.flag { facts.append("flag \(f)") }
                facts.append(d.applies.note)
                out += "# (\(facts.joined(separator: "; ")))\n"
                if let v = values[d.key] {
                    out += "\(d.name) = \(TOML.render(v))\n"
                } else {
                    out += "# \(d.name) = \(TOML.render(d.defaultValue))\n"
                }
            }
            if !extra.isEmpty {
                out += "\n# not known to this version (kept as they were):\n"
                for e in extra { out += "\(e.key) = \(TOML.render(e.value))\n" }
            }
        }
        var others: [String] = []
        for e in unknown where !sections.contains(e.section) && !others.contains(e.section) { others.append(e.section) }
        for section in others {
            // A top-level unknown key cannot follow a section header; it becomes [unknown].
            let header = section.isEmpty ? "unknown" : section
            out += "\n# not known to this version (kept as they were):\n[\(header)]\n"
            for e in unknown where e.section == section { out += "\(e.key) = \(TOML.render(e.value))\n" }
        }
        return out
    }

    static func wrapComment(_ text: String, width: Int = 98) -> String {
        var lines: [String] = []
        var line = "#"
        for word in text.split(separator: " ") {
            if line.count + 1 + word.count > width, line != "#" {
                lines.append(line)
                line = "#"
            }
            line += " " + word
        }
        lines.append(line)
        return lines.joined(separator: "\n") + "\n"
    }

    /// temp file (0600, O_EXCL) in the same directory → fsync → rename; the directory is 0700.
    static func writeAtomically(_ text: String, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            throw SettingsError("could not create \(dir.path): \(error.localizedDescription)")
        }
        guard chmod(dir.path, 0o700) == 0 else { throw SettingsError("could not make \(dir.path) private (0700)") }
        let tmp = dir.appendingPathComponent(".\(fileName).\(getpid()).\(UInt32.random(in: .min ... .max)).tmp")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw SettingsError("could not write in \(dir.path): \(String(cString: strerror(errno)))") }
        var ok = fchmod(fd, 0o600) == 0
        let bytes = Array(text.utf8)
        var written = 0
        while ok, written < bytes.count {
            let n = bytes[written...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if n <= 0 { ok = false } else { written += n }
        }
        ok = ok && fsync(fd) == 0
        ok = close(fd) == 0 && ok
        guard ok, rename(tmp.path, url.path) == 0 else {
            unlink(tmp.path)
            throw SettingsError("could not write \(url.path): \(String(cString: strerror(errno)))")
        }
    }
}
