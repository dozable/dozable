import CryptoKit
import Darwin
import DozableKit
import Foundation

/// Git inside a fenced session's folder. The fence lets the program write project files — `.git/config` included (git
/// writes it) — but nothing a fenced program writes may later be EXECUTED by an unfenced git the person runs in that
/// folder. So:
///
/// - the hooks folders (`.git/hooks` at any depth, an in-tree `core.hooksPath`, its husky parent) and the git include
///   targets inside the folder are write-, rename- and unlink-denied by the profile (`protectedPaths`, the regexes);
/// - every git config under the folder (each repository's `config` and `config.worktree`, submodules' and worktrees')
///   is held to an ALLOWLIST of keys a fenced program may add or change (`allowed`): anything else — `core.fsmonitor`,
///   `core.hooksPath`, `pager.*`, `url.*.insteadOf`, `remote.*.uploadpack`, an unknown key — is a VIOLATION: the host
///   stops every process of the fence, strips the keys (kept in the store's quarantine, never in the folder) and the
///   session stays stopped until the person resumes it;
/// - a `.git` FILE pointing anywhere but an already-watched worktree or module gitdir, a bare-repository shape outside a
///   `.git` (a folder holding `HEAD`, `objects/` and `config`), and a repository arriving with hooks are violations too.
///
/// The host reads every config SAFELY (`MacFenceHostFS`: no link in its path, a regular file, one link, the user's,
/// ≤ 1 MiB) and parses it with git itself (`git config --file <a private copy> --no-includes --list -z`) — never its own
/// parser, so what is checked is what git reads. `MacFenceGitTests`.
public enum MacFenceGit {
    // MARK: git, run by the host

    /// The git the host runs: the developer tools' own binary (`xcrun --find git`, once) — `/usr/bin/git` is a shim that
    /// runs xcrun every time (~50 ms on a fenced session's start, measured). Falls back to the shim.
    static let gitBinary: String = {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        p.arguments = ["--find", "git"]
        p.environment = ["PATH": "/usr/bin:/bin"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "/usr/bin/git" }
        let d = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let path = String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return p.terminationStatus == 0 && path.hasPrefix("/") && access(path, X_OK) == 0 ? path : "/usr/bin/git"
    }()

    /// Run git ARGS with exactly `environment` in `cwd`; its stdout, or nil (it failed or outlived `timeout`).
    static func runGit(_ args: [String], environment: [String: String], cwd: String, timeout: Double = 10) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: gitBinary)
        p.arguments = args
        p.environment = environment
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let reader = out.fileHandleForReading
        final class Box: @unchecked Sendable { var data = Data(); let lock = NSLock() }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            let d = reader.readDataToEndOfFile()
            box.lock.withLock { box.data = d }
            done.signal()
        }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { usleep(5_000) }
        if p.isRunning { p.terminate(); usleep(100_000); if p.isRunning { kill(p.processIdentifier, SIGKILL) } }
        p.waitUntilExit()
        _ = done.wait(timeout: .now() + 2)
        guard p.terminationReason == .exit, p.terminationStatus == 0 else { return nil }
        return box.lock.withLock { String(decoding: box.data, as: UTF8.self) }
    }

    /// The environment git runs with in the host: no system or global config, nothing of the person's.
    static func gitEnvironment(_ scratch: String) -> [String: String] {
        ["HOME": scratch, "PATH": "/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "LANG": "C",
         "XDG_CONFIG_HOME": scratch]
    }

    /// `git config --list -z`'s entries: `key\nvalue\0`, or `key\0` for a key with no value (git's implicit true).
    public static func parseList(_ z: String) -> [(String, String)] {
        z.split(separator: "\0", omittingEmptySubsequences: true).map { e in
            if let nl = e.firstIndex(of: "\n") { return (String(e[..<nl]), String(e[e.index(after: nl)...])) }
            return (String(e), "")
        }
    }

    /// One entry as the baseline keeps it.
    static func entry(_ k: String, _ v: String) -> String { k + "\u{0}" + v }

    // MARK: the allowlist

    /// Whether a fenced program may ADD or CHANGE `key` to `value` in a repository whose working tree is `worktree`, in
    /// the fenced folder `workdir` (removing a key is always allowed).
    public static func allowed(_ key: String, _ value: String, worktree: String, workdir: String) -> Bool {
        let parts = key.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2 else { return false }
        let section = parts[0].lowercased(), name = parts[parts.count - 1].lowercased(), sub = parts.count >= 3
        switch section {
        case "branch":
            return sub && ["remote", "merge", "rebase", "pushremote", "description"].contains(name)
        case "remote":
            guard sub else { return false }
            if ["url", "pushurl"].contains(name) { return urlAllowed(value, worktree: worktree, workdir: workdir) }
            return ["fetch", "push", "tagopt", "prune"].contains(name)
        case "submodule":
            guard sub else { return false }
            if name == "url" { return urlAllowed(value, worktree: worktree, workdir: workdir) }
            return ["active", "branch"].contains(name)
        case "lfs":
            guard !sub else { return false }
            if name == "url" { return urlAllowed(value, worktree: worktree, workdir: workdir) }
            return ["locksverify", "repositoryformatversion"].contains(name)
        case "core":
            guard !sub else { return false }
            if name == "bare" { return value.lowercased() == "false" }
            return ["repositoryformatversion", "filemode", "logallrefupdates", "ignorecase", "precomposeunicode"].contains(name)
        default:
            return false
        }
    }

    /// A remote's URL: `https://`, `ssh://`, `user@host:path`, or a path (relative to the working tree, or absolute)
    /// inside the folder — never a transport helper (`ext::`, `fd::`), another scheme, `file://` outside, or a leading `-`.
    public static func urlAllowed(_ v: String, worktree: String, workdir: String) -> Bool {
        if v.isEmpty || v.hasPrefix("-") || v.contains("::") || v.unicodeScalars.contains(where: { $0.value < 0x20 }) { return false }
        let lower = v.lowercased()
        if lower.hasPrefix("https://") || lower.hasPrefix("ssh://") { return true }
        var path = v
        if lower.hasPrefix("file://") { path = String(v.dropFirst("file://".count)) }
        else if v.range(of: #"^[A-Za-z0-9._-]+@[A-Za-z0-9._-]+:"#, options: .regularExpression) != nil { return true }
        else if v.contains("://") { return false }
        let full = path.hasPrefix("/") ? path : worktree + "/" + path
        let std = MacFencePaths.lexical(full)
        return MacFencePaths.isWithin(std, workdir)
    }

    // MARK: at open: the protected paths

    /// The literal paths inside `workdir` the profile protects: the effective hooks path when it is in the folder (the
    /// repository's `core.hooksPath`, else the person's global one) — and, for husky's layout (`…/_`), its parent — and
    /// every git include target inside the folder. Throws when the folder's own repository has an include that cannot be
    /// verified (a link, not a regular file, or in a closed place).
    public static func protectedPaths(workdir: String, hooksPathGlobal: String?, home: String, scratch: String) throws -> [String] {
        guard MacFenceHostFS.kind(workdir + "/.git") == S_IFDIR else {
            return hooksPathGlobal.flatMap { hooksProtection($0, workdir: workdir) } ?? []
        }
        let gitdir = workdir + "/.git"
        var out: [String] = []
        let entries: [(String, String)]
        switch readConfig(gitdir + "/config", scratch: scratch) {
        case .success(let e): entries = e
        case .failure(let r): throw HostError(.invalid, "a fenced session cannot run here: \(r.description) — refused")
        }
        let repoHooks = entries.last { $0.0 == "core.hookspath" }?.1
        if let h = repoHooks ?? hooksPathGlobal { out += hooksProtection(h, workdir: workdir) ?? [] }
        for (k, v) in entries where k == "include.path" || (k.hasPrefix("includeif.") && k.hasSuffix(".path")) {
            let p = v.hasPrefix("~/") ? home + v.dropFirst(1) : v.hasPrefix("/") ? v : gitdir + "/" + v
            let std = MacFencePaths.lexical(p)
            if MacFencePaths.isWithin(std, workdir) {
                guard MacFenceHostFS.kind(std) == S_IFREG || MacFenceHostFS.kind(std) == nil else {
                    throw HostError(.invalid, "a fenced session cannot run here: the git include \(DisplayPath.tilde(std)) is a link or not a regular file (unverifiable) — refused")
                }
                out.append(std)
            } else if let real = MacFencePaths.resolve(std), real != std {
                throw HostError(.invalid, "a fenced session cannot run here: the git include \(DisplayPath.tilde(std)) is reached through a link (unverifiable) — refused")
            }
        }
        return Array(Set(out)).sorted()
    }

    /// An in-folder hooks path, and husky's parent (`.husky/_` → `.husky`).
    static func hooksProtection(_ hooksPath: String, workdir: String) -> [String]? {
        let p = hooksPath.hasPrefix("/") ? hooksPath : workdir + "/" + hooksPath
        let std = MacFencePaths.lexical(p)
        guard MacFencePaths.isWithin(std, workdir), std != workdir else { return nil }
        if (std as NSString).lastPathComponent == "_" {
            let parent = (std as NSString).deletingLastPathComponent
            if parent != workdir { return [parent] }
        }
        return [std]
    }

    // MARK: reading a config safely

    /// A config's entries: read through `MacFenceHostFS` (no link, a regular file, one link, ≤ 1 MiB) into a private copy
    /// in `scratch`, parsed by git (`--no-includes`).
    public static func readConfig(_ path: String, scratch: String) -> Result<[(String, String)], MacFenceHostFS.Refusal> {
        let data: Data
        do { data = try MacFenceHostFS.readRegular(path, maximum: 1 << 20) } catch let r as MacFenceHostFS.Refusal { return .failure(r) } catch {
            return .failure(.init(path: path, why: "\(error)"))
        }
        return parse(data, scratch: scratch, path: path)
    }

    static func parse(_ data: Data, scratch: String, path: String) -> Result<[(String, String)], MacFenceHostFS.Refusal> {
        let name = "cfg-\(UInt32.random(in: 0...UInt32.max))"
        do { try MacFenceHostFS.writeAtomically(data, dir: scratch, name: name) } catch { return .failure(.init(path: path, why: "could not copy it: \(error)")) }
        defer { unlink(scratch + "/" + name) }
        if data.isEmpty { return .success([]) }
        guard let out = runGit(["config", "--file", scratch + "/" + name, "--no-includes", "--list", "-z"],
                               environment: gitEnvironment(scratch), cwd: scratch) else {
            return .failure(.init(path: path, why: "git cannot read it"))
        }
        return .success(parseList(out))
    }

    /// `data` without the entries in `remove` (key, value), by git (`--fixed-value --unset-all`), or nil.
    static func strip(_ data: Data, remove: [(String, String)], scratch: String) -> Data? {
        let name = "strip-\(UInt32.random(in: 0...UInt32.max))"
        guard (try? MacFenceHostFS.writeAtomically(data, dir: scratch, name: name)) != nil else { return nil }
        defer { unlink(scratch + "/" + name) }
        let file = scratch + "/" + name
        for (k, v) in remove {
            // A key with a value: only that value; a bare key (no `=`): every one of it.
            let args = v.isEmpty ? ["config", "--file", file, "--unset-all", k] : ["config", "--file", file, "--fixed-value", "--unset-all", k, v]
            _ = runGit(args, environment: gitEnvironment(scratch), cwd: scratch)
        }
        return FileManager.default.contents(atPath: file)
    }

    /// A config made from `entries` alone (when the one there cannot be read or is a link).
    static func rebuild(_ entries: [(String, String)], scratch: String) -> Data {
        let name = "rebuild-\(UInt32.random(in: 0...UInt32.max))"
        let file = scratch + "/" + name
        FileManager.default.createFile(atPath: file, contents: Data(), attributes: [.posixPermissions: 0o600])
        defer { unlink(file) }
        for (k, v) in entries { _ = runGit(["config", "--file", file, "--add", k, v.isEmpty ? "true" : v], environment: gitEnvironment(scratch), cwd: scratch) }
        return FileManager.default.contents(atPath: file) ?? Data()
    }
}

/// What the git guard of one fenced session remembers from its open (in the store, never in the folder): each config's
/// entries, each git folder's hooks.
public struct MacFenceGitBaseline: Codable, Equatable, Sendable {
    /// Config path → its entries (`key NUL value`).
    public var configs: [String: [String]] = [:]
    /// Git folder → hook name → sha256.
    public var hooks: [String: [String: String]] = [:]
    public init() {}

    /// Per git folder, the sha256 of its config's entries (the record's `gitBaseline`).
    public var digests: [String: String] {
        configs.mapValues { MacFence.sha256($0.sorted().joined(separator: "\n")) }
    }
}

/// A violation the guard found (and dealt with).
public struct MacFenceGitViolation: Sendable, Equatable {
    public var path: String
    /// What was wrong, in words (`core.fsmonitor added`, `a .git file pointing outside`).
    public var what: [String]
    /// The text kept in the quarantine (the stripped `key = value` lines; never a link's content).
    public var quarantined: String
}

/// The git guard of ONE fenced session: a walk at open (the baseline) or at adoption (a check against the stored
/// baseline), then FSEvents over every folder the program may write. A violation is acted on at once, on the guard's
/// queue: the session is stopped (`stop`), the offending keys stripped, files moved to the store's quarantine, and
/// `report` is called. All file access through `MacFenceHostFS`.
public final class MacFenceGitGuard: @unchecked Sendable {
    public let session: String
    let workdir: String
    let roots: [String]
    /// `<store>/mac-sessions/fence/<session>` (0700): the baseline, git's private copies.
    let stateFolder: String
    /// `<store>/mac-sessions/quarantine/<session>`.
    let quarantine: String
    let stop: @Sendable () -> Void
    let report: @Sendable (MacFenceGitViolation) -> Void
    let queue: DispatchQueue
    private var baseline = MacFenceGitBaseline()
    /// Git folders known (the baseline's and those seen since).
    private var known: Set<String> = []
    /// A config's last (inode, size, mtime) — unchanged ones are not parsed again.
    private var seen: [String: String] = [:]
    private var stream: PathEventStream?

    public init(session: String, workdir: String, roots: [String], stateFolder: String, quarantine: String,
                stop: @escaping @Sendable () -> Void, report: @escaping @Sendable (MacFenceGitViolation) -> Void) {
        self.session = session
        self.workdir = workdir
        self.roots = roots
        self.stateFolder = stateFolder
        self.quarantine = quarantine
        self.stop = stop
        self.report = report
        queue = DispatchQueue(label: "doz.fence.git.\(session)")
    }

    var baselineURL: URL { URL(fileURLWithPath: stateFolder + "/git-baseline.json") }
    var scratch: String { stateFolder + "/git" }

    // MARK: open and adoption

    /// At open: walk the folders and record what is there as the baseline (the person's own repositories are trusted as
    /// they are). Returns the baseline. Throws when the folder's own config cannot be read safely.
    public func recordBaseline() throws -> MacFenceGitBaseline {
        try queue.sync {
            try MacFenceHostFS.ensureDirectory(scratch)
            var b = MacFenceGitBaseline()
            for root in roots {
                for g in discover(root) {
                    for c in [g + "/config", g + "/config.worktree"] where MacFenceHostFS.kind(c) != nil {
                        switch MacFenceGit.readConfig(c, scratch: scratch) {
                        case .success(let e): b.configs[c] = e.map { MacFenceGit.entry($0.0, $0.1) }
                        case .failure(let r):
                            if g == workdir + "/.git" { throw HostError(.invalid, "a fenced session cannot run here: \(r.description)") }
                        }
                        seen[c] = stamp(c)
                    }
                    b.hooks[g] = hooks(g)
                    known.insert(g)
                }
            }
            baseline = b
            try MacFenceHostFS.writeAtomically(try HostWire.encoder.encode(b), dir: stateFolder, name: "git-baseline.json")
            return b
        }
    }

    /// At adoption: the stored baseline, the WATCH, then a full check — in that order, so a change made between the check
    /// and the watch cannot be missed (what changed while no host ran is dealt with by the check).
    public func adopt() -> [MacFenceGitViolation] {
        queue.sync {
            if let d = try? MacFenceHostFS.readRegular(baselineURL.path, maximum: 8 << 20),
               let b = try? HostWire.decoder.decode(MacFenceGitBaseline.self, from: d) { baseline = b }
            try? MacFenceHostFS.ensureDirectory(scratch)
            known = Set(baseline.hooks.keys)
        }
        start()
        return check()
    }

    /// Check everything now (resume asks this first): the violations found — each already dealt with.
    public func check() -> [MacFenceGitViolation] { queue.sync { fullCheckLocked() } }

    private func fullCheckLocked() -> [MacFenceGitViolation] {
        var out: [MacFenceGitViolation] = []
        for root in roots { out += scan(root) }
        for g in known.sorted() { out += checkGitdir(g, force: true) }
        return out
    }

    // MARK: watching

    public func start() {
        queue.sync {
            guard stream == nil else { return }
            let s = PathEventStream(paths: roots, queue: queue) { [weak self] events in self?.received(events) }
            if s.start() { stream = s }
        }
    }

    public func cancel() {
        queue.sync {
            stream?.stop()
            stream = nil
        }
    }

    public var watching: Bool { queue.sync { stream != nil } }

    /// On `queue`.
    private func received(_ events: [PathEventStream.Event]) {
        guard stream != nil else { return }
        var full = false
        var subtrees = Set<String>()
        for e in events {
            if e.lost { full = true; continue }
            let raw = e.path
            let p = raw.count > 1 && raw.hasSuffix("/") ? String(raw.dropLast()) : raw
            let name = (p as NSString).lastPathComponent
            // A folder that arrived (made, or renamed in with everything inside it): walk it.
            if e.isDirectory && e.structural { subtrees.insert(p) }
            if [".git", "HEAD", "objects", "config", "config.worktree", "hooks"].contains(name) || p.contains("/.git/") || p.hasSuffix("/.git") {
                subtrees.insert((p as NSString).deletingLastPathComponent)
            }
        }
        var found: [MacFenceGitViolation] = []
        if full { found = fullCheckLocked() } else {
            for g in known.sorted() { found += checkGitdir(g, force: false) }
            for t in reduce(subtrees) where roots.contains(where: { MacFencePaths.isWithin(t, $0) }) { found += scan(t) }
        }
        _ = found
    }

    /// The outermost of `paths` (a path inside another is covered by its walk).
    private func reduce(_ paths: Set<String>) -> [String] {
        let sorted = paths.sorted { $0.count < $1.count }
        var out: [String] = []
        for p in sorted where !out.contains(where: { MacFencePaths.isWithin(p, $0) }) { out.append(p) }
        return out
    }

    // MARK: the checks (on `queue`)

    /// Every git folder under `root`: `.git` folders, and inside them module and worktree git folders.
    private func discover(_ root: String) -> [String] {
        var out: [String] = []
        MacFenceHostFS.walk(root) { p, mode in
            guard (p as NSString).lastPathComponent == ".git" else { return true }
            if mode == S_IFDIR { out += Self.gitdirs(inside: p) }
            return false
        }
        return out
    }

    /// A `.git` folder and the git folders inside it: `worktrees/*` and `modules/**` (any folder there with a HEAD).
    static func gitdirs(inside g: String) -> [String] {
        var out = [g]
        if let fd = try? MacFenceHostFS.openDirectory(g + "/worktrees") {
            for n in ((try? MacFenceHostFS.entries(fd, path: g + "/worktrees")) ?? []).sorted() where MacFenceHostFS.kind(g + "/worktrees/" + n) == S_IFDIR {
                out.append(g + "/worktrees/" + n)
            }
            close(fd)
        }
        MacFenceHostFS.walk(g + "/modules") { q, m in
            guard m == S_IFDIR else { return false }
            if MacFenceHostFS.kind(q + "/HEAD") == S_IFREG { out.append(q) }
            return !["objects", "refs", "logs", "lfs", "hooks", "info"].contains((q as NSString).lastPathComponent)
        }
        return out
    }

    /// Walk `top` for new git shapes: a `.git` folder not known (a new repository — its config and hooks checked), a
    /// `.git` file (its pointer checked), a bare-repository shape outside any `.git`.
    private func scan(_ top: String) -> [MacFenceGitViolation] {
        var out: [MacFenceGitViolation] = []
        func visit(_ p: String, _ mode: mode_t) -> Bool {
            let name = (p as NSString).lastPathComponent
            if name == ".git" {
                if mode == S_IFREG { if let v = checkDotGitFile(p) { out.append(v) } }
                else if mode == S_IFDIR {
                    for g in Self.gitdirs(inside: p) where !known.contains(g) {
                        known.insert(g)
                        out += checkGitdir(g, force: true)
                    }
                } else if mode == S_IFLNK {
                    out.append(act(p, what: ["a .git that is a link"], quarantineItems: [p], text: ""))
                }
                return false
            }
            if mode == S_IFDIR, !p.contains("/.git/"), MacFenceHostFS.kind(p + "/HEAD") == S_IFREG,
               MacFenceHostFS.kind(p + "/objects") == S_IFDIR, MacFenceHostFS.kind(p + "/config") != nil {
                out.append(act(p, what: ["a bare repository's shape (HEAD, objects/, config)"],
                               quarantineItems: [p + "/config", p + "/hooks"].filter { MacFenceHostFS.kind($0) != nil }, text: ""))
            }
            return true
        }
        let topName = (top as NSString).lastPathComponent
        var mode = MacFenceHostFS.kind(top) ?? 0
        if topName == ".git" || top.contains("/.git/") {
            // An event inside a .git: its repository (the nearest .git) is checked.
            var g = top
            while !g.hasSuffix("/.git") && g != "/" && !g.isEmpty { g = (g as NSString).deletingLastPathComponent }
            if g.hasSuffix("/.git") { _ = visit(g, MacFenceHostFS.kind(g) ?? 0) }
            return out
        }
        if mode == S_IFDIR { _ = visit(top, mode); MacFenceHostFS.walk(top, visit: visit) } else if mode != 0 { mode = 0 }
        return out
    }

    /// A `.git` FILE: allowed only when its `gitdir:` resolves into a watched `.git/worktrees/*` or `.git/modules/*`.
    private func checkDotGitFile(_ p: String) -> MacFenceGitViolation? {
        let text = (try? MacFenceHostFS.readRegular(p, maximum: 4096)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        if line.hasPrefix("gitdir: ") {
            let raw = String(line.dropFirst("gitdir: ".count)).trimmingCharacters(in: .whitespaces)
            let target = raw.hasPrefix("/") ? raw : (p as NSString).deletingLastPathComponent + "/" + raw
            if let real = MacFencePaths.resolve(target),
               known.contains(where: { g in g.hasSuffix("/.git") && (MacFencePaths.isWithin(real, g + "/worktrees") || MacFencePaths.isWithin(real, g + "/modules")) && real != g + "/worktrees" && real != g + "/modules" }) {
                return nil
            }
        }
        return act(p, what: ["a .git file pointing outside a watched worktree or submodule"], quarantineItems: [p], text: "")
    }

    /// A git folder's configs against the baseline and the allowlist, and its hooks against the baseline.
    private func checkGitdir(_ g: String, force: Bool) -> [MacFenceGitViolation] {
        guard MacFenceHostFS.kind(g) == S_IFDIR else { return [] }
        var out: [MacFenceGitViolation] = []
        let worktree = g.hasSuffix("/.git") ? (g as NSString).deletingLastPathComponent : g
        for c in [g + "/config", g + "/config.worktree"] {
            guard let k = MacFenceHostFS.kind(c) else { continue }
            let st = stamp(c)
            if !force, st == seen[c], k == S_IFREG { continue }
            seen[c] = st
            let base = Set(baseline.configs[c] ?? [])
            let data: Data
            do { data = try MacFenceHostFS.readRegular(c, maximum: 1 << 20) } catch let r as MacFenceHostFS.Refusal {
                // A link, a hard link, not a regular file: never read; replaced by the baseline's entries.
                let rebuilt = MacFenceGit.rebuild((baseline.configs[c] ?? []).map(split), scratch: scratch)
                var v = act(c, what: ["\((c as NSString).lastPathComponent) \(r.why)"], quarantineItems: [c], text: "")
                do { try MacFenceHostFS.writeAtomically(rebuilt, dir: g, name: (c as NSString).lastPathComponent, mode: 0o644, sync: true) }
                catch { v.what.append("could not write it again: \(error)") }
                out.append(v)
                continue
            } catch { continue }
            switch MacFenceGit.parse(data, scratch: scratch, path: c) {
            case .failure:
                let rebuilt = MacFenceGit.rebuild((baseline.configs[c] ?? []).map(split), scratch: scratch)
                var v = act(c, what: ["\((c as NSString).lastPathComponent) git cannot read"], quarantineItems: [], text: String(decoding: data.prefix(64 << 10), as: UTF8.self))
                do { try MacFenceHostFS.writeAtomically(rebuilt, dir: g, name: (c as NSString).lastPathComponent, mode: 0o644, sync: true) }
                catch { v.what.append("could not write it again: \(error)") }
                out.append(v)
            case .success(let entries):
                let bad = entries.filter { !base.contains(MacFenceGit.entry($0.0, $0.1)) && !MacFenceGit.allowed($0.0, $0.1, worktree: worktree, workdir: workdir) }
                guard !bad.isEmpty else { continue }
                stop()
                let text = bad.map { "\($0.0) = \($0.1)" }.joined(separator: "\n")
                var v = MacFenceGitViolation(path: c, what: bad.map { "\($0.0) added" }, quarantined: text)
                if let stripped = MacFenceGit.strip(data, remove: bad, scratch: scratch) {
                    do {
                        try MacFenceHostFS.writeAtomically(stripped, dir: g, name: (c as NSString).lastPathComponent, mode: 0o644, sync: true)
                        seen[c] = stamp(c)
                    } catch { v.what.append("could not strip it: \(error)") }
                } else { v.what.append("git could not strip it") }
                keep(text, about: c)
                stop()
                report(v)
                out.append(v)
            }
        }
        // Hooks: nothing new, nothing changed (the profile denies writes there: a change arrives only with a renamed-in
        // tree, which a walk sees — `force`).
        guard force else { return out }
        let now = hooks(g)
        let was = baseline.hooks[g] ?? [:]
        let changed = now.filter { was[$0.key] != $0.value }.keys.sorted()
        if !changed.isEmpty {
            out.append(act(g + "/hooks", what: changed.map { "hook \($0) arrived" }, quarantineItems: changed.map { g + "/hooks/" + $0 }, text: ""))
        }
        return out
    }

    /// Stop the session, move `quarantineItems` into the quarantine (as links or files — never their targets' content),
    /// keep `text`, report it.
    private func act(_ path: String, what: [String], quarantineItems: [String], text: String) -> MacFenceGitViolation {
        stop()
        var v = MacFenceGitViolation(path: path, what: what, quarantined: text)
        let stamp = Self.timestamp()
        try? MacFenceHostFS.ensureDirectory(quarantine)
        for (i, item) in quarantineItems.enumerated() {
            let name = "\(stamp)-\(i)-" + item.replacingOccurrences(of: "/", with: "_").suffix(120)
            do { try MacFenceHostFS.move(item, into: quarantine, newName: String(name)) } catch { v.what.append("could not move \(DisplayPath.tilde(item)) aside: \(error)") }
        }
        keep(([what.joined(separator: "; ")] + (text.isEmpty ? [] : [text])).joined(separator: "\n"), about: path)
        stop()
        report(v)
        return v
    }

    private func keep(_ text: String, about path: String) {
        try? MacFenceHostFS.ensureDirectory(quarantine)
        let body = "# \(path)\n" + text + "\n"
        try? MacFenceHostFS.writeAtomically(Data(body.utf8), dir: quarantine, name: Self.timestamp() + "-\(UInt16.random(in: 0...UInt16.max)).txt")
    }

    static func timestamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss.SSS"
        return f.string(from: Date())
    }

    private func split(_ e: String) -> (String, String) {
        guard let i = e.firstIndex(of: "\u{0}") else { return (e, "") }
        return (String(e[..<i]), String(e[e.index(after: i)...]))
    }

    /// A git folder's hooks: name → sha256 (`*.sample` left out; a link or folder recorded as such, never followed).
    private func hooks(_ g: String) -> [String: String] {
        guard let dfd = try? MacFenceHostFS.openDirectory(g + "/hooks") else { return [:] }
        defer { close(dfd) }
        var out: [String: String] = [:]
        for n in (try? MacFenceHostFS.entries(dfd, path: g + "/hooks")) ?? [] where !n.hasSuffix(".sample") {
            let p = g + "/hooks/" + n
            if let d = try? MacFenceHostFS.readRegular(p, maximum: 16 << 20) {
                out[n] = SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
            } else {
                out[n] = "not a regular file"
            }
        }
        return out
    }

    private func stamp(_ p: String) -> String {
        let parent = (p as NSString).deletingLastPathComponent
        guard let dfd = try? MacFenceHostFS.openDirectory(parent) else { return "" }
        defer { close(dfd) }
        var st = stat()
        guard fstatat(dfd, (p as NSString).lastPathComponent, &st, AT_SYMLINK_NOFOLLOW) == 0 else { return "" }
        return "\(st.st_ino):\(st.st_size):\(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec):\(st.st_mode)"
    }
}
