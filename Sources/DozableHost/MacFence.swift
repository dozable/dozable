import CryptoKit
import Darwin
import DozableKit
import Foundation

/// What a client asks for a fenced session on this Mac (`HostRequest.macFence`). Its presence means FENCED; the CLI
/// resolves the mode (flag > `DOZ_MAC_FENCE` > `mac.fence` > default) and sends nothing for an unfenced one.
public struct MacFenceRequest: Codable, Equatable, Sendable {
    /// Open the Keychain's services (signing, notarisation) — default closed.
    public var keychain: Bool?
    /// One more folder read-only / read-write each (absolute; resolved and checked by the host).
    public var read: [String]?
    public var write: [String]?
    /// What its proxy allows: `doz create --permissions` words (standard / locked / open, PERMISSION, -PERMISSION,
    /// site:HOST), from this Mac's Standard (nil: the setting `mac.permissions`).
    public var permissions: [String]?
    /// Ports of this Mac's loopback it may listen on and connect to (`--local-port N`, each 1024–65535).
    public var localPorts: [Int]?
    /// 683: the agent's config folder (`private` | `shared`; nil: the settings), its conversation history (`keep` |
    /// `agent-default`; nil: the settings), its Claude login (an account's name, `mac`, `none`; nil: `mac.account`).
    public var agentConfig: String? = nil
    public var history: String? = nil
    public var account: String? = nil
    /// 683: its bridges (nil: the settings `mac.open_url`, `mac.open_files`, `mac.clipboard`).
    public var openURL: Bool? = nil
    public var openFiles: Bool? = nil
    public var clipboard: Bool? = nil
    /// 683 M4: the Xcode build profile (`--xcode`), and the Simulator's guard rail on top of it (`--simulator` — things it
    /// launches run OUTSIDE the fence). nil/false: the agent profile.
    public var xcode: Bool? = nil
    public var simulator: Bool? = nil
    /// 683 M4: GitHub as the person through its proxy (`off` | `read` | `push`; nil: off) — the token never enters the
    /// fence, the program gets a placeholder.
    public var github: String? = nil
    /// 683 M4: the person's SSH agent, filtered to list + sign (`--ssh-agent`).
    public var sshAgent: Bool? = nil
    /// The profile asked: `agent`, `xcode` or `simulator`.
    public var profile: String { simulator == true ? "simulator" : xcode == true ? "xcode" : "agent" }
    public init(keychain: Bool? = nil, read: [String]? = nil, write: [String]? = nil, permissions: [String]? = nil, localPorts: [Int]? = nil) {
        self.keychain = keychain
        self.read = read
        self.write = write
        self.permissions = permissions
        self.localPorts = localPorts
    }
}

/// 683: a fenced session's bridges (§ "Bridges in a fenced session"): open a URL in the person's browser, open a document
/// from its folder, put text on the clipboard — each announced; changed live with `doz sessions bridges @mac S`.
public struct MacFenceBridges: Codable, Equatable, Sendable {
    public var openURL: Bool
    public var openFiles: Bool
    public var clipboard: Bool
    public init(openURL: Bool = true, openFiles: Bool = true, clipboard: Bool = true) {
        self.openURL = openURL
        self.openFiles = openFiles
        self.clipboard = clipboard
    }

    /// The settings' values, with the request's own over them.
    public static func resolve(_ r: MacFenceRequest?, settings: DozableSettings) -> MacFenceBridges {
        MacFenceBridges(openURL: r?.openURL ?? (settings.string(SettingKey.macOpenURL) != "off"),
                        openFiles: r?.openFiles ?? (settings.string(SettingKey.macOpenFiles) != "off"),
                        clipboard: r?.clipboard ?? (settings.string(SettingKey.macClipboard) != "off"))
    }
}

/// 683: `session-bridges` — a fenced session's bridges now.
public struct SessionBridges: Codable, Equatable, Sendable {
    public var session: String
    public var bridges: MacFenceBridges
    public var changed: String?
}

/// What widens a fenced session's reach — recorded at each open; a re-open that WIDENS it empties the session's caches
/// first (nothing written under narrower grants is loaded under wider ones).
public struct MacFenceGrants: Codable, Equatable, Sendable {
    public var profile: String
    public var keychain: Bool
    public var readable: [String]
    public var writable: [String]
    /// Its own ports of this Mac's loopback (nil: none — every record before them).
    public var localPorts: [Int]? = nil
    /// Certificate trust (trustd) is open to it — every preset but Locked (nil: an older record, which had it).
    public var trust: Bool? = nil
    /// 683: its agent uses the person's own config folder (`shared`).
    public var sharedConfig: Bool? = nil
    /// 683 M4: GitHub as the person (`read` | `push`; nil: off) and the SSH agent.
    public var github: String? = nil
    public var sshAgent: Bool? = nil

    static func githubRank(_ m: String?) -> Int { ["read": 1, "push": 2][m ?? ""] ?? 0 }

    static func rank(_ profile: String) -> Int { ["agent": 0, "xcode": 1, "simulator": 2][profile] ?? 3 }

    /// `self` reaches something `old` did not.
    public func widens(_ old: MacFenceGrants?) -> Bool {
        guard let old else { return false }
        if keychain && !old.keychain { return true }
        if sharedConfig == true && old.sharedConfig != true { return true }
        if Self.rank(profile) > Self.rank(old.profile) { return true }
        if !Set(readable).subtracting(old.readable).subtracting(old.writable).isEmpty { return true }
        if !Set(writable).subtracting(old.writable).isEmpty { return true }
        if !Set(localPorts ?? []).subtracting(old.localPorts ?? []).isEmpty { return true }
        if trust ?? true, !(old.trust ?? true) { return true }
        if Self.githubRank(github) > Self.githubRank(old.github) { return true }
        if sshAgent == true && old.sshAgent != true { return true }
        return false
    }
}

/// The record of a fenced session (`MacSessionRecord.fence`; nil = unfenced, so every earlier record keeps its mode).
/// Never a password, a token or a config's text.
public struct MacFenceRecord: Codable, Equatable, Sendable {
    public var version = 1
    /// `agent` (this release); `xcode` and `simulator` come later.
    public var profile: String
    public var keychain: Bool
    public var readable: [String]
    public var writable: [String]
    public var sessionFolder: String
    public var grants: MacFenceGrants
    public var tag: String
    public var templateVersion: Int
    public var profileSHA256: String
    /// Per repository known at open (its git folder → the sha256 of its config's keys and values).
    public var gitBaseline: [String: String]?
    /// Why the session is stopped (a git config change outside the allowlist), and the processes stopped.
    public var stoppedForGit: String?
    public var stoppedPids: [Int]?
    /// Its proxy (nil: a record from before fenced sessions had one — no network at all): the loopback port its holder
    /// holds, the SHA-256 of the password (never the password), and the policy (live edits kept here).
    public var proxyPort: Int? = nil
    public var proxySecretSHA256: String? = nil
    public var policy: NetworkPolicy? = nil
    public var localPorts: [Int]? = nil
    /// 683: its agent (the recipe declaring a config folder; nil: none), that folder's mode and where the mode came from,
    /// the conversation-history value and its source.
    public var agent: String? = nil
    public var agentConfig: String? = nil
    public var agentConfigSource: String? = nil
    public var history: String? = nil
    public var historySource: String? = nil
    /// 683: the Claude login swapped in — an account's name, or `none` (nil: not a Claude session).
    public var account: String? = nil
    /// 683: sha256(placeholder) → binding, for the placeholders its program was given (a later host honours them).
    public var placeholderHashes: [String: String]? = nil
    /// 683: its bridges now (nil: a record from before them — off).
    public var bridges: MacFenceBridges? = nil
    /// 683: `name:sha256` of each conversation carried back (nothing is carried twice).
    public var carried: [String]? = nil
    /// 683 M4: GitHub as the person (`read` | `push`; nil: off), the SSH agent, and — for a folder that is a git worktree —
    /// its repository's common git folder (written and watched under the same allowlist; its hooks closed).
    public var github: String? = nil
    public var sshAgent: Bool? = nil
    public var gitCommon: [String]? = nil

    /// This session's sentinel and the anti-sentinel (`MacFence.sentinel`, `.antiSentinel`).
    public var sentinel: String { sessionFolder + "/etc/sentinel-" + tag }
    public var antiSentinel: String { (sessionFolder as NSString).deletingLastPathComponent + "/.not-fenced" }
    /// The request that opens it again with the same grants (its permissions come from `policy`). 683: its agent config,
    /// history, account and bridges as they were (a restart never widens them).
    public var request: MacFenceRequest {
        var r = MacFenceRequest(keychain: keychain ? true : nil, read: readable.isEmpty ? nil : readable, write: writable.isEmpty ? nil : writable,
                                localPorts: (localPorts ?? []).isEmpty ? nil : localPorts)
        r.agentConfig = agentConfig
        r.history = historySource == "flag" ? history : nil
        r.account = account
        r.openURL = bridges?.openURL
        r.openFiles = bridges?.openFiles
        r.clipboard = bridges?.clipboard
        r.xcode = profile == "xcode" || profile == "simulator" ? true : nil
        r.simulator = profile == "simulator" ? true : nil
        r.github = github
        r.sshAgent = sshAgent
        return r
    }
}

/// What `doz sessions @mac --json` says of a fenced session.
public struct MacFenceRow: Codable, Equatable, Sendable {
    public var profile: String
    public var keychain: Bool
    public var readable: [String]
    public var writable: [String]
    public var sessionFolder: String
    public var stoppedForGit: String?
    public var templateVersion: Int
    public var profileSHA256: String
    /// Its network: the proxy's port, the permissions and preset (nil: Custom), its own local ports; `network` —
    /// `proxy` (a host serves it), `waiting (no host)` (connections wait in its holder's backlog), `none` (an older
    /// record: no network at all).
    public var proxyPort: Int?
    public var permissions: [String]?
    public var preset: String?
    public var localPorts: [Int]?
    public var network: String?
    /// The fence's refusals seen in the system log (macOS folds repeats), and whether that log can be read
    /// (`on`, `unavailable` — an account that may not read it — or `off` with no host).
    public var denialsSeen: Int?
    public var denialLog: String?
    /// 683: its agent, the config folder (`private` | `shared` — less isolated), the history and where each came from,
    /// the Claude login swapped in, its bridges.
    public var agent: String? = nil
    public var agentConfig: String? = nil
    public var history: String? = nil
    public var historySource: String? = nil
    public var account: String? = nil
    public var bridges: MacFenceBridges? = nil
    /// 683 M4: GitHub as the person (`read` | `push`; nil: off), the SSH agent (list + sign).
    public var github: String? = nil
    public var sshAgent: Bool? = nil

    public init(_ r: MacFenceRecord) {
        profile = r.profile
        keychain = r.keychain
        readable = r.readable
        writable = r.writable
        sessionFolder = r.sessionFolder
        stoppedForGit = r.stoppedForGit
        templateVersion = r.templateVersion
        profileSHA256 = r.profileSHA256
        proxyPort = r.proxyPort
        permissions = r.policy?.permissions
        preset = r.policy.flatMap { $0.permissions.flatMap { AgentPermissions.presetName($0, base: AgentPermissions.macBase) } }
        localPorts = (r.localPorts ?? []).isEmpty ? nil : r.localPorts
        network = r.proxyPort == nil ? "none" : "waiting (no host)"
        agent = r.agent
        agentConfig = r.agentConfig
        history = r.history
        historySource = r.historySource
        account = r.account
        bridges = r.bridges
        github = r.github
        sshAgent = r.sshAgent
    }

    /// The STATE word(s) of `doz sessions @mac`.
    public var state: String {
        if let s = stoppedForGit, !s.isEmpty { return "stopped: git config" }
        var t = ["xcode": "fenced (Xcode)", "simulator": "guard rail (Simulator)"][profile] ?? "fenced"
        if keychain { t += " · Keychain open" }
        if agentConfig == MacAgentConfig.sharedMode { t += " · shared config (less isolated)" }
        return t
    }
}

/// `session-resume`.
public struct SessionResumed: Codable, Equatable, Sendable {
    public var session: String
    public var processes: Int
}

/// `session-quarantine`: what was taken out of a fenced session's git configs, newest first.
public struct SessionQuarantine: Codable, Equatable, Sendable {
    public struct Item: Codable, Equatable, Sendable {
        public var name: String
        public var text: String
    }
    public var session: String
    public var items: [Item]
}

/// A fenced session on this Mac: everything its Seatbelt profile, environment and session folder are made from — built
/// by the host at each open from the request, the store and the person's home (`MacFence.make`). Paths are resolved.
public struct MacFence: Sendable, Equatable {
    public static let templateVersion = 1
    /// The profile every fenced session had before the Xcode ones (and the default).
    public static let profileKind = "agent"
    public static let profiles = ["agent", "xcode", "simulator"]

    public var places: MacFencePlaces
    public var session: String
    public var workdir: String
    public var sessionFolder: String
    public var readable: [String]
    public var writable: [String]
    public var homeReads: MacFencePaths.HomeReads
    public var keychain: Bool
    public var tag: String
    /// Literal paths inside the folder that are write- and rename-protected (an in-tree `core.hooksPath`, its husky
    /// parent, a git include target).
    public var protectedPaths: [String] = []
    /// The folder's own `.git`: absent, a folder or a file (a worktree's pointer).
    public var workdirGit: mode_t?
    /// Its proxy's port on this Mac's loopback — the ONLY outbound connection its profile allows (nil: no network).
    public var proxyPort: UInt16?
    /// Ports of this Mac's loopback it may listen on and connect to (`--local-port`).
    public var localPorts: [UInt16] = []
    /// Certificate trust (trustd) open — every preset but Locked.
    public var trust = true
    /// Its permissions' preset name for the line it says (nil: custom).
    public var presetName: String?
    /// 683: its agent's config folder (nil: its program declares none), its bridges, and the placeholders its program gets
    /// (variable → placeholder; the proxy swaps them) with the account behind them (an account's name, `none`).
    public var agent: MacAgentSetup? = nil
    public var bridges = MacFenceBridges()
    public var placeholders: [String: String] = [:]
    public var account: String? = nil
    /// 683 M4: `agent`, `xcode` (Xcode's build services) or `simulator` (also LaunchServices and the Simulator — a guard
    /// rail, not a boundary).
    public var profile = MacFence.profileKind
    /// 683 M4: GitHub as the person (nil: off), the SSH agent; the host's two sockets the program may connect to — the
    /// filtered agent relay and `gh`'s plain-HTTP door into its proxy (`<socket folder>/NAME.agent`, `NAME.gh`).
    public var github: GitHubAccess.Mode? = nil
    public var sshAgent = false
    public var agentSocket: String? = nil
    public var ghSocket: String? = nil
    /// 683 M4: doz itself, readable so `doz fence-connect` (git's and ssh's way through the proxy) runs inside.
    public var dozExecutable: String? = nil
    /// 683 M4: the folder is a git worktree — its repository's common git folder (resolved), writable but its hooks.
    public var gitCommon: [String] = []

    /// 683 M4: gh's config folder with GitHub as the person (gh rewrites its config, so it is the session's own, written
    /// again by the host at every open).
    public var ghConfigDir: String { cache + "/config/gh" }

    /// 683: the bridges' shims (`open`, `xdg-open`), host-owned, first on its PATH.
    public var bin: String { etc + "/bin" }

    /// The most `--local-port`s one session may have.
    public static let maximumLocalPorts = 8

    public var tmp: String { sessionFolder + "/tmp" }
    public var cache: String { sessionFolder + "/cache" }
    public var derived: String { sessionFolder + "/derived" }
    public var etc: String { sessionFolder + "/etc" }
    public var ssh: String { sessionFolder + "/ssh" }
    /// Readable ONLY by this session's profile (every other fence closes the whole fence root): how the host tells this
    /// session's processes apart (`MacFenceStop`).
    public var sentinel: String { etc + "/sentinel-" + tag }
    /// Closed to every fence and open to a broad reader — the second half of that test.
    public var antiSentinel: String { places.fenceRoot + "/.not-fenced" }
    /// Every folder the program may write.
    public var writableRoots: [String] { [workdir] + writable }

    public var grants: MacFenceGrants {
        var g = MacFenceGrants(profile: profile, keychain: keychain, readable: readable.sorted(), writable: (writable + gitCommon).sorted())
        g.localPorts = localPorts.isEmpty ? nil : localPorts.map(Int.init).sorted()
        g.trust = trust
        if agent?.isPrivate == false { g.sharedConfig = true }
        g.github = github?.rawValue
        g.sshAgent = sshAgent ? true : nil
        return g
    }

    /// Xcode's build services are open to it (`xcode` and `simulator`).
    public var xcode: Bool { profile != Self.profileKind }

    /// A fresh tag: 16 hex.
    public static func newTag() -> String { (0..<8).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined() }

    public static func sessionFolder(_ places: MacFencePlaces, session: String) -> String { places.fenceRoot + "/" + session }

    /// Build the fence for `session` in `workdir` (both checked here): the extra folders resolved and refused where they
    /// must be, the home's read allowlist for `path`, the folder's git protections. Throws a plain `HostError(.invalid)`.
    public static func make(session: String, workdir given: String, request: MacFenceRequest, places: MacFencePlaces,
                            path: String, fenceRead: [String], hooksPathGlobal: String?, scratch: String) throws -> MacFence {
        if let p = MacFencePaths.pathProblem(places.home) { throw HostError(.invalid, "this Mac's home cannot be fenced: \(p)") }
        guard let wd = MacFencePaths.resolve(given) else { throw HostError(.invalid, "--workdir \(given): not a folder on this Mac") }
        if let why = MacFencePaths.workdirRefusal(wd, places) {
            throw HostError(.invalid, "a fenced session cannot run in \(DisplayPath.tilde(wd)): \(why) — choose a project folder (--workdir DIR), or doz run @mac --unfenced")
        }
        func folders(_ list: [String]?, _ flag: String) throws -> [String] {
            var out: [String] = []
            for d in list ?? [] {
                guard let r = MacFencePaths.resolve(d) else { throw HostError(.invalid, "\(flag) \(d): not on this Mac") }
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: r, isDirectory: &isDir), isDir.boolValue else { throw HostError(.invalid, "\(flag) \(d): not a folder") }
                if let why = MacFencePaths.folderRefusal(r, places) { throw HostError(.invalid, "\(flag) \(DisplayPath.tilde(r)): refused — \(why)") }
                if !out.contains(r) { out.append(r) }
            }
            return out
        }
        let writable = try folders(request.write, "--write").filter { $0 != wd }
        let readable = try folders(request.read, "--read").filter { r in r != wd && !writable.contains(r) }
        var fence = MacFence(places: places, session: session, workdir: wd, sessionFolder: sessionFolder(places, session: session),
                             readable: readable, writable: writable,
                             homeReads: MacFencePaths.homeReads(places, path: path, extra: fenceRead, keychain: request.keychain == true,
                                                                         profile: request.profile),
                             keychain: request.keychain == true, tag: newTag())
        fence.localPorts = try localPorts(request.localPorts)
        fence.workdirGit = MacFenceHostFS.kind(wd + "/.git")
        fence.profile = request.profile
        switch request.github ?? "off" {
        case "off": fence.github = nil
        case "read": fence.github = .read
        case "push": fence.github = .push
        case let g: throw HostError(.invalid, "--github \(g): off, read or push")
        }
        fence.sshAgent = request.sshAgent == true
        // A worktree: its repository's common git folder (where its commits, refs and config live) is written too.
        if fence.workdirGit == S_IFREG {
            let common = try MacFenceGit.worktreeCommon(workdir: wd)
            if let why = MacFencePaths.folderRefusal(common, places) {
                throw HostError(.invalid, "a fenced session cannot run in this worktree: its repository's git folder \(DisplayPath.tilde(common)) is refused — \(why)")
            }
            if !writable.contains(where: { MacFencePaths.isWithin(common, $0) }) && !MacFencePaths.isWithin(common, wd) { fence.gitCommon = [common] }
        }
        fence.protectedPaths = try MacFenceGit.protectedPaths(workdir: wd, hooksPathGlobal: hooksPathGlobal, home: places.home, scratch: scratch,
                                                              gitCommon: fence.gitCommon.first)
        return fence
    }

    /// `--local-port`s checked: 1024–65535, at most `maximumLocalPorts`, never a port of Dozable's own dashboard.
    static func localPorts(_ given: [Int]?) throws -> [UInt16] {
        var out: [UInt16] = []
        for p in given ?? [] {
            guard (1024...65535).contains(p) else { throw HostError(.invalid, "--local-port \(p): a port from 1024 to 65535") }
            if LocalDashboards.refuses(host: "127.0.0.1", port: UInt16(p)) {
                throw HostError(.invalid, "--local-port \(p): that is Dozable's own dashboard on this Mac — a fenced session never reaches it")
            }
            if !out.contains(UInt16(p)) { out.append(UInt16(p)) }
        }
        guard out.count <= maximumLocalPorts else { throw HostError(.invalid, "at most \(maximumLocalPorts) --local-port ports for one session") }
        return out.sorted()
    }

    /// The one line `doz run @mac --fenced` says on stderr.
    public func line() -> String {
        var reach = DisplayPath.tilde(workdir)
        if !writable.isEmpty { reach += " and " + writable.map { DisplayPath.tilde($0) }.joined(separator: ", ") }
        let words = ["agent": "standard"][presetName ?? ""] ?? presetName ?? "custom"
        let net = proxyPort == nil ? "no network" : "network through Dozable's proxy (\(words) permissions)"
            + (localPorts.isEmpty ? "" : "; its own ports \(localPorts.map(String.init).joined(separator: ", ")) on this Mac")
        var own = "its own temp and caches"
        if xcode { own += " and DerivedData" }
        if let a = agent {
            own = a.isPrivate ? "its own temp, caches and \(a.title) settings" : "its own temp and caches; your own \(DisplayPath.tilde(a.personHome)) (shared — less isolated)"
        }
        var extra = ""
        if let g = github { extra += "GitHub as you (\(g == .push ? "read and push" : "read-only")) through the proxy; " }
        if sshAgent { extra += "your SSH agent (list + sign only); " }
        let head = ["xcode": "fenced (Xcode)", "simulator": "guard rail (Simulator: it and what it launches run OUTSIDE the fence — a guard rail, not a boundary)"][profile] ?? "fenced"
        return "\(head): reads and writes \(reach); \(own); \(net); " + extra
            + (keychain ? "your Keychain OPEN; " : "your Keychain, ")
            + "secrets and other folders closed — doz run @mac --unfenced for none of this"
    }

    public func record(profileSHA256: String, gitBaseline: [String: String]?) -> MacFenceRecord {
        var r = MacFenceRecord(profile: profile, keychain: keychain, readable: readable, writable: writable, sessionFolder: sessionFolder,
                               grants: grants, tag: tag, templateVersion: Self.templateVersion, profileSHA256: profileSHA256,
                               gitBaseline: gitBaseline, stoppedForGit: nil, stoppedPids: nil)
        r.proxyPort = proxyPort.map(Int.init)
        r.localPorts = localPorts.isEmpty ? nil : localPorts.map(Int.init)
        r.agent = agent?.recipe
        r.agentConfig = agent?.mode
        r.agentConfigSource = agent?.modeSource
        r.history = agent?.history
        r.historySource = agent?.historySource
        r.account = account
        r.placeholderHashes = placeholders.isEmpty ? nil
            : Dictionary(placeholders.map { (k, t) in (CredentialFingerprint.placeholderHash(t), Self.binding(ofVariable: k)) }) { a, _ in a }
        r.bridges = bridges
        r.github = github?.rawValue
        r.sshAgent = sshAgent ? true : nil
        r.gitCommon = gitCommon.isEmpty ? nil : gitCommon
        return r
    }

    /// The binding a placeholder variable stands for (`GH_TOKEN` → github; `ANTHROPIC_API_KEY` → anthropic; the Claude
    /// login's otherwise).
    static func binding(ofVariable k: String) -> String {
        switch k {
        case "GH_TOKEN": return CredentialBinding.github.id
        case "ANTHROPIC_API_KEY": return CredentialBinding.anthropic.id
        default: return CredentialBinding.claudeOAuth.id
        }
    }

    static func sha256(_ s: String) -> String { SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined() }
}
