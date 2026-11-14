import Darwin
import DozableKit
import Foundation

/// What a fenced session's AGENT gets on this Mac — the recipe that declares its config folder (`launch@1 mac_config`,
/// embedded recipes only), the folder's mode and the history value, each with where it came from. Built by the host at
/// every open (`MacAgentConfig.plan`), seeded by `MacAgentConfig.prepare`; nil for a program no embedded recipe declares
/// (no config handling at all).
public struct MacAgentSetup: Sendable, Equatable {
    public var recipe: String
    public var title: String
    public var config: AgentRecipe.Launch.MacConfig
    /// `private` or `shared`, and its source (`flag`, the recipe's setting, `mac.agent_config`, or `recipe` — its default).
    public var mode: String
    public var modeSource: String
    /// The conversation-history value (`keep` | `agent-default`), its source and the setting that decided it.
    public var history: String
    public var historySource: String
    /// What the agent does by itself (`agent-default`'s words, from the recipe).
    public var agentDefault: String?
    /// The recipe's `launch@1 history` mapping (applied to the PRIVATE folder's settings under `keep`).
    public var historyMap: AgentRecipe.Launch.History?
    /// The person's real config home (`<home>/.claude`) and the file beside it (`<home>/.claude.json`).
    public var personHome: String
    public var personBeside: String?
    /// The session's own config home (`<session>/agent`) — private only.
    public var agentDir: String
    /// What the profile opens READ-ONLY for the links (their resolved targets, and every nested link's that passed).
    public var readFolders: [String] = []
    public var readFiles: [String] = []
    /// Names in `agentDir` the host owns (the links, the cleaned settings): write-, rename- and unlink-denied.
    public var hostOwned: [String] = []
    /// What was not brought, and why (said once at the start).
    public var notes: [String] = []

    public var isPrivate: Bool { mode == MacAgentConfig.privateMode }
    /// The folder the agent's transcripts of `workdir` are in, under its config home (`projects/<encoded workdir>`).
    public func transcriptsFolder(workdir: String) -> String { config.transcripts.folder(workdir: workdir) }
}

/// 683 — the agent's config folder in a fenced session on this Mac, per agent (owner, 2026-11-13: "optional and per
/// vendor … read-only links and cleaned settings copy").
///
/// - **private** (the default): the agent's config home is the session's own `<session>/agent` (`CLAUDE_CONFIG_DIR`).
///   At EVERY open, through `MacFenceHostFS` only: everything in it is cleared but the transcripts (`projects/<the
///   folder>/*.jsonl`, regular files) — no planted shell snapshot, statusline script, memory, todo or settings survives
///   into a run with other grants; each `link_read_only` entry becomes a link to the person's own (host-owned: the
///   program can neither write through it nor replace it), its target and every link inside it resolved — a target in a
///   closed place (secrets, configs, the store, the Keychain) or in a place a fence can write (the folder, temp,
///   another session) is NOT followed, and said; the settings file is written from `clean_copy.keys` only, plus the
///   history mapping under `keep` (host-owned: the agent's own settings changes are refused); the first-run file is
///   built (onboarding done, the person's theme, the folder trusted); and on the FIRST open the folder's own
///   conversations are cloned in, so `--continue` finds them. Never brought: plugins, MCP servers, hooks, the
///   statusline, `env`, credentials, other folders' conversations, the prompt history.
/// - **shared**: the person's real config home and the file beside it are readable AND writable — nothing seeded,
///   nothing carried, and the history mapping is never written into it. Less isolated, said wherever it shows.
///
/// The login is never the folder's: the proxy swaps a placeholder (`HostCore.bindAnthropicAccount`).
public enum MacAgentConfig {
    public static let privateMode = "private"
    public static let sharedMode = "shared"
    public static let follow = "follow"
    public static let modes = [privateMode, sharedMode]

    /// The largest settings file read, transcript cloned in, and the most cloned in all.
    static let maximumSettingsBytes = 1 << 20
    static let maximumTranscriptBytes = 64 << 20
    static let maximumCloneBytes = 1 << 30
    /// The link policy's walk of a linked folder.
    static let linkWalkDepth = 8
    static let linkWalkEntries = 4096

    /// The setup for `argv` in `workdir` — nil when no embedded recipe declares a config folder for its program.
    /// `mode`/`history`: the request's own (a flag), else the settings.
    public static func plan(argv: [String], workdir: String, sessionFolder: String, home: String, mode flag: String?, history own: String?,
                            settings: DozableSettings) throws -> MacAgentSetup? {
        guard let program = argv.first, let r = AgentRecipes.macAgent(program: program), let m = r.launch.macConfig else { return nil }
        if let f = flag, !modes.contains(f) { throw HostError(.invalid, "--agent-config \(f): private or shared") }
        if let h = own, !AgentHistory.values.contains(h) { throw HostError(.invalid, "--history \(h): keep or agent-default") }
        let (mode, modeSource) = resolveMode(flag: flag, recipe: r, settings: settings)
        let h = settings.history(agent: r.id, own: own.map { TOMLValue.string($0) }, from: nil)
        let source = own != nil ? "flag" : h.source.rawValue
        let personHome = home + "/" + m.homeName
        return MacAgentSetup(recipe: r.id, title: r.title, config: m, mode: mode, modeSource: modeSource, history: h.value, historySource: source,
                             agentDefault: r.launch.history?.agentDefault, historyMap: r.launch.history, personHome: personHome,
                             personBeside: m.beside?.isEmpty == false ? personHome + ".json" : nil, agentDir: sessionFolder + "/agent")
    }

    /// flag > the recipe's own setting (not `follow`) > `mac.agent_config` (when set) > the recipe's default.
    public static func resolveMode(flag: String?, recipe r: AgentRecipe, settings: DozableSettings) -> (String, String) {
        if let f = flag { return (f, "flag") }
        if let k = SettingKey.macConfig(r.id), DozableSettings.definition(k) != nil {
            let v = settings.resolve(k)
            if case .string(let s) = v.value, s != follow, modes.contains(s) { return (s, v.source.rawValue) }
        }
        let a = settings.resolve(SettingKey.macAgentConfig)
        if a.source != .default, case .string(let s) = a.value, modes.contains(s) { return (s, a.source.rawValue) }
        return (r.launch.macConfig?.default ?? privateMode, "recipe")
    }

    // MARK: seeding

    /// Make the session's agent folder (private) and decide what the profile opens for it. `placeholder`: the API key's
    /// placeholder Claude Code is told to accept (an API-key account), if any.
    public static func prepare(_ s: MacAgentSetup, fence f: MacFence, placeholderTail: String? = nil) throws -> MacAgentSetup {
        var s = s
        guard s.isPrivate else {
            // Shared: the person's own folder — nothing seeded, nothing written. Opened by the profile (MacFenceProfile).
            s.notes.append("shared: this agent uses your own \(DisplayPath.tilde(s.personHome)) — what it writes there (hooks, settings, scripts) runs in your next \(s.title) outside the fence; less isolated, by your choice")
            return s
        }
        let dir = s.agentDir
        if let k = MacFenceHostFS.kind(dir), k != S_IFDIR {
            try MacFenceHostFS.remove(dir)
            s.notes.append("agent/ was not a folder — removed and made again")
        }
        let first = MacFenceHostFS.kind(dir) == nil
        try MacFenceHostFS.ensureDirectory(dir)
        let projects = s.transcriptsFolder(workdir: f.workdir)
        s.notes += try clearKeepingTranscripts(dir, projects: projects)
        s = try link(s, fence: f)
        try writeSettings(&s, home: f.places.home)
        try writeFirstRun(s, workdir: f.workdir, placeholderTail: placeholderTail)
        if first { s.notes += cloneIn(s, workdir: f.workdir) }
        return s
    }

    /// Clear `dir` except its transcripts: every top-level entry but the transcripts' top folder; inside it, every folder
    /// but this workdir's; inside that, everything that is not a regular `*.jsonl` file (no folder, no link, no memory).
    static func clearKeepingTranscripts(_ dir: String, projects: String) throws -> [String] {
        let parts = projects.split(separator: "/").map(String.init)          // ["projects", "<enc>"]
        guard parts.count == 2 else { return try MacFenceHostFS.clearContents(dir) }
        var notes = try MacFenceHostFS.clearContents(dir) { $0 == parts[0] }
        let top = dir + "/" + parts[0]
        if let k = MacFenceHostFS.kind(top), k != S_IFDIR { try MacFenceHostFS.remove(top) }
        guard MacFenceHostFS.kind(top) == S_IFDIR else { return notes }
        notes += try MacFenceHostFS.clearContents(top) { $0 == parts[1] }
        let mine = top + "/" + parts[1]
        if let k = MacFenceHostFS.kind(mine), k != S_IFDIR { try MacFenceHostFS.remove(mine) }
        guard MacFenceHostFS.kind(mine) == S_IFDIR else { return notes }
        let dfd = try MacFenceHostFS.openDirectory(mine)
        defer { close(dfd) }
        for name in try MacFenceHostFS.entries(dfd, path: mine) {
            var st = stat()
            guard fstatat(dfd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            if (st.st_mode & S_IFMT) == S_IFREG, name.hasSuffix(".jsonl") { continue }
            do { try MacFenceHostFS.remove(mine + "/" + name) } catch let r as MacFenceHostFS.Refusal { notes.append(r.description) }
        }
        return notes
    }

    /// Why a link target (resolved) is not followed (nil: it may be read). Closed: the home itself or a parent of it,
    /// the secret places (but the config home's own entries), the store, the sockets, doz's settings, the Keychain, the
    /// fence's folders, this user's temp. Writable by a fence: the folder, `--write` folders, temp folders.
    static func linkRefusal(_ target: String, setup s: MacAgentSetup, fence f: MacFence) -> String? {
        let p = f.places, home = p.home
        if target == home || MacFencePaths.isWithin(home, target) { return "it is your home" }
        let configHome = MacFencePaths.resolve(s.personHome) ?? s.personHome
        let insideConfig = MacFencePaths.isWithin(target, configHome)
        if !insideConfig {
            for c in MacFencePaths.secretPlaces where MacFencePaths.isWithin(target, home + "/" + c) { return "\(DisplayPath.tilde(home + "/" + c)) is closed" }
        } else {
            // Inside the config home only what the recipe links is brought — never its other files (a credentials file,
            // its own projects and history).
            let rel = String(target.dropFirst(configHome.count)).drop { $0 == "/" }
            let first = rel.split(separator: "/").first.map(String.init) ?? ""
            if !s.config.linkReadOnly.contains(where: { $0 == first || $0.hasPrefix(first + "/") }) { return "\(DisplayPath.tilde(target)) is not one of the entries brought" }
        }
        for c in [p.store, p.socketDirectory, p.dozConfig, home + "/Library/Keychains", p.fenceRoot] where MacFencePaths.isWithin(target, c) {
            return "\(DisplayPath.tilde(c)) is closed"
        }
        // The user temp folder holds the holders' sockets (closed to every fence).
        if target.hasPrefix(p.userTemp) { return "this user's temporary folder is closed" }
        for w in f.writableRoots where MacFencePaths.isWithin(target, w) || MacFencePaths.isWithin(w, target) {
            return "\(DisplayPath.tilde(w)) is writable by this session"
        }
        return nil
    }

    /// The links: each `link_read_only` entry that exists in the person's config home, by the link policy.
    static func link(_ s: MacAgentSetup, fence f: MacFence) throws -> MacAgentSetup {
        var s = s
        for name in s.config.linkReadOnly {
            let source = s.personHome + "/" + name
            guard MacFencePaths.lstatKind(source) != nil else { continue }          // not there: nothing linked
            guard let target = MacFencePaths.resolve(source) else { s.notes.append("\(name): its link leads nowhere — not brought"); continue }
            if let why = linkRefusal(target, setup: s, fence: f) {
                s.notes.append("\(s.config.homeName)/\(name) points into \(DisplayPath.tilde(target)) — not brought (\(why))")
                continue
            }
            if let p = MacFencePaths.pathProblem(target) { s.notes.append("\(name): \(p) — not brought"); continue }
            let at = s.agentDir + "/" + name
            let parent = (at as NSString).deletingLastPathComponent
            if parent != s.agentDir { try MacFenceHostFS.ensureDirectory(parent) }
            let dfd = try MacFenceHostFS.openDirectory(parent)
            let made = symlinkat(target, dfd, (at as NSString).lastPathComponent) == 0
            close(dfd)
            guard made else { s.notes.append("\(name): could not link it (\(String(cString: strerror(errno))))"); continue }
            s.hostOwned.append(name)
            if MacFencePaths.lstatKind(target) == S_IFDIR {
                s.readFolders.append(target)
                // Every link inside it: followed only when its target passes the same policy.
                let complete = MacFenceHostFS.walk(target, maximum: linkWalkEntries, maxDepth: linkWalkDepth) { path, mode in
                    guard mode == S_IFLNK else { return true }
                    let shown = name + String(path.dropFirst(target.count))
                    guard let t = MacFencePaths.resolve(path) else { return false }
                    if let why = linkRefusal(t, setup: s, fence: f) ?? MacFencePaths.pathProblem(t) {
                        s.notes.append("\(s.config.homeName)/\(shown) points into \(DisplayPath.tilde(t)) — not brought (\(why))")
                    } else if MacFencePaths.lstatKind(t) == S_IFDIR {
                        if !s.readFolders.contains(where: { MacFencePaths.isWithin(t, $0) }) { s.readFolders.append(t) }
                    } else if !s.readFiles.contains(t) {
                        s.readFiles.append(t)
                    }
                    return false
                }
                if !complete { s.notes.append("\(name): more than \(linkWalkEntries) entries or \(linkWalkDepth) folders deep — links past that are not brought") }
            } else {
                s.readFiles.append(target)
            }
        }
        return s
    }

    /// The cleaned settings: the person's values of `clean_copy.keys` only (dotted), plus — under `keep` — the recipe's
    /// history keys for that file (only where absent). Written read-only; host-owned.
    static func writeSettings(_ s: inout MacAgentSetup, home: String) throws {
        for c in s.config.cleanCopy {
            var person: [String: Any] = [:]
            let path = s.personHome + "/" + c.file
            if MacFencePaths.lstatKind(path) != nil {
                if let real = MacFencePaths.resolve(path), let d = try? MacFenceHostFS.readRegular(real, maximum: maximumSettingsBytes),
                   let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
                    person = o
                } else {
                    s.notes.append("\(s.config.homeName)/\(c.file) could not be read as JSON — none of its settings brought")
                }
            }
            var out: [String: Any] = [:]
            for k in c.keys { if let v = value(person, k) { put(&out, k, v) } }
            if s.history == AgentHistory.keep {
                for keep in s.historyMap?.keep ?? [] where keep.file == s.config.home + "/" + c.file {
                    for (k, v) in keep.set where value(out, k) == nil { put(&out, k, v.jsonPlain) }
                }
            }
            let data = try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try MacFenceHostFS.writeAtomically(data + Data("\n".utf8), dir: s.agentDir, name: c.file, mode: 0o444)
            s.hostOwned.append(c.file)
        }
    }

    /// The first-run file (written at every open, then the agent's): the recipe's keys, the person's theme, the folder
    /// trusted, and an API key's placeholder accepted (Claude Code asks once per key otherwise).
    static func writeFirstRun(_ s: MacAgentSetup, workdir: String, placeholderTail: String?) throws {
        guard let fr = s.config.firstRun else { return }
        var out: [String: Any] = [:]
        for (k, v) in fr.set { out[k] = v.jsonPlain }
        if let beside = s.personBeside, let real = MacFencePaths.resolve(beside),
           let d = try? MacFenceHostFS.readRegular(real, maximum: 16 << 20),
           let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any], let theme = o["theme"] as? String,
           theme.count <= 64, theme.unicodeScalars.allSatisfy({ $0.isASCII && $0.value >= 0x20 }) {
            out["theme"] = theme
        }
        if let t = fr.trustWorkdir { out[t] = [workdir: ["hasTrustDialogAccepted": true]] }
        if let tail = placeholderTail { out["customApiKeyResponses"] = ["approved": [tail], "rejected": [String]()] }
        let data = try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try MacFenceHostFS.writeAtomically(data + Data("\n".utf8), dir: s.agentDir, name: fr.file, mode: 0o600)
    }

    /// The FIRST open: the folder's own conversations (regular `*.jsonl` files of the person's) cloned in, so the agent's
    /// `--continue` finds them. Returns what was not.
    static func cloneIn(_ s: MacAgentSetup, workdir: String) -> [String] {
        let rel = s.transcriptsFolder(workdir: workdir)
        let from = s.personHome + "/" + rel, to = s.agentDir + "/" + rel
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: from) else { return [] }
        var notes: [String] = [], total = 0
        for n in names.sorted() where n.hasSuffix(".jsonl") && !n.hasPrefix(".") {
            do {
                let d = try MacFenceHostFS.readRegular(from + "/" + n, maximum: maximumTranscriptBytes)
                total += d.count
                guard total <= maximumCloneBytes else { notes.append("your conversations of this folder are over 1 GiB — the rest not brought"); break }
                try MacFenceHostFS.ensureDirectory(to)
                try MacFenceHostFS.writeAtomically(d, dir: to, name: n, mode: 0o600)
            } catch let r as MacFenceHostFS.Refusal {
                notes.append("conversation \(n) not brought: \(r.why)")
            } catch {
                notes.append("conversation \(n) not brought: \(error)")
            }
        }
        return notes
    }

    // MARK: JSON by dotted key

    static func value(_ o: [String: Any], _ dotted: String) -> Any? {
        var node: Any = o
        for p in dotted.split(separator: ".").map(String.init) {
            guard let d = node as? [String: Any], let next = d[p] else { return nil }
            node = next
        }
        return node
    }

    static func put(_ o: inout [String: Any], _ dotted: String, _ v: Any) {
        let parts = dotted.split(separator: ".").map(String.init)
        guard let first = parts.first else { return }
        if parts.count == 1 { o[first] = v; return }
        var child = o[first] as? [String: Any] ?? [:]
        put(&child, parts.dropFirst().joined(separator: "."), v)
        o[first] = child
    }
}

extension RecipeValue {
    /// The value as JSONSerialization takes it.
    var jsonPlain: Any {
        switch self {
        case .string(let s): return s
        case .bool(let b): return b
        case .number(let n): return n == n.rounded() && abs(n) < 1e15 ? Int(n) : n
        case .object(let o): return o.mapValues(\.jsonPlain)
        case .array(let a): return a.map(\.jsonPlain)
        case .null: return NSNull()
        }
    }
}
