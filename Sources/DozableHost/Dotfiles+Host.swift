import Darwin
import Foundation
import DozableKit

// 657 — the person's dotfiles, the host's half: the cache the Mac's own git fetches into (`<store>/dotfiles/<id>/repo.git`
// — a bare repository; a private one is fetched with the Mac's git login, and no credential ever goes near a guest), the
// pin each sandbox records, the ops `dotfiles` / `dotfiles-resolve` / `dotfiles-update`, and the trust record the CLI asks
// against (`<settings dir>/dotfiles-trusted.json`). The model and the guest's side are DozableKit's (`Dotfiles.swift`).

/// What a source's head is, and what applying it does (`dotfiles-resolve`).
public struct DotfilesResolved: Codable, Equatable, Sendable {
    /// Normalised (`DotfilesSource.normalized`).
    public var source: String
    public var commit: String
    /// Its commit message's first line (inert, ≤ 120 characters).
    public var subject: String?
    public var plan: DotfilesPlan
    /// A folder on the Mac (not a URL).
    public var local: Bool
    /// A folder with changes not committed — they are not included (only the commit is).
    public var dirty: Bool?
    /// The source as a person reads it (a folder with `~`).
    public var display: String
}

/// A sandbox's dotfiles as `doz ls --json` and the dashboard see them.
public struct DotfilesState: Codable, Equatable, Sendable {
    public var source: String
    public var display: String
    public var commit: String
    public var resolvedAt: Date
    /// `applied` (the last apply was of this commit and went well), `failed` (it did not), `pending` (not applied yet: at
    /// the next start or wake).
    public var state: String
    /// `script` or `links` (the last apply's), and its one line.
    public var method: String?
    public var script: String?
    public var summary: String?
    public var at: Date?
}

/// `doz dotfiles NAME`.
public struct DotfilesReport: Codable, Equatable, Sendable {
    public var sandbox: String
    public var dotfiles: DotfilesState?
    /// The setting `sandbox.dotfiles` as it is now (normalised; nil: none) — what `--update` takes when the sandbox has none.
    public var setting: String?
    /// What applying the pinned commit does (nil: not in this Mac's cache — read again at the next fetch).
    public var plan: DotfilesPlan?
    /// The last apply, in full.
    public var last: DotfilesRun?
    /// `dotfiles-update`: what it did ("applied now", "at the next start").
    public var changed: String?
}

/// The repositories fetched on this Mac (`<store>/dotfiles`). Every call runs the Mac's `/usr/bin/git`, bounded.
public struct DotfilesCache: Sendable {
    public let root: URL
    public let environment: [String: String]

    public init(root: URL, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.root = root
        self.environment = environment
    }

    public func directory(_ source: String) -> URL { root.appendingPathComponent(DotfilesSource.cacheID(source), isDirectory: true) }
    public func repository(_ source: String) -> URL { directory(source).appendingPathComponent("repo.git", isDirectory: true) }

    /// One fetch per source at a time in this process.
    private static let locksLock = NSLock()
    nonisolated(unsafe) private static var locks: [String: NSLock] = [:]
    private func lock(_ source: String) -> NSLock {
        Self.locksLock.lock(); defer { Self.locksLock.unlock() }
        if let l = Self.locks[source] { return l }
        let l = NSLock()
        Self.locks[source] = l
        return l
    }

    /// git's environment: never a question (no terminal prompt, no askpass — the Mac's credential helper still answers),
    /// and in a guarded test run never this Mac's own git configuration.
    public static func gitEnvironment(_ base: [String: String]) -> [String: String] {
        var e = base
        e["GIT_TERMINAL_PROMPT"] = "0"
        e["GIT_ASKPASS"] = "/usr/bin/false"
        e["SSH_ASKPASS"] = "/usr/bin/false"
        e["GCM_INTERACTIVE"] = "never"
        e["LC_ALL"] = "C"
        if TestSafety.guarded(base) {
            e["GIT_CONFIG_NOSYSTEM"] = "1"
            if e["GIT_CONFIG_GLOBAL"] == nil { e["GIT_CONFIG_GLOBAL"] = "/dev/null" }
        }
        return e
    }

    /// Run git (no shell): exit code, stdout, stderr's last line. At most `timeout` seconds.
    func git(_ args: [String], timeout: TimeInterval = 120) -> (code: Int32, out: Data, err: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        p.environment = Self.gitEnvironment(environment)
        p.currentDirectoryURL = FileManager.default.temporaryDirectory
        let out = Pipe()
        let errFile = FileManager.default.temporaryDirectory.appendingPathComponent("doz-git-\(UUID().uuidString).err")
        FileManager.default.createFile(atPath: errFile.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: errFile) }
        guard let errHandle = try? FileHandle(forWritingTo: errFile) else { return (-1, Data(), "could not run git") }
        p.standardOutput = out
        p.standardError = errHandle
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch {
            try? errHandle.close()
            return (-1, Data(), "could not run /usr/bin/git: \(error.localizedDescription)")
        }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        try? errHandle.close()
        let err = (try? String(contentsOf: errFile, encoding: .utf8)) ?? ""
        let last = err.split(separator: "\n").map { InertText.line($0, limit: 240) }.last { !$0.isEmpty } ?? ""
        return (p.terminationStatus, data, last)
    }

    private func gitDir(_ source: String) -> String { "--git-dir=" + repository(source).path }

    /// A folder on the Mac must be a git repository (its commit is what is applied).
    func checkLocal(_ source: String) throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source, isDirectory: &isDir), isDir.boolValue else {
            throw DotfilesError("\(DisplayPath.tilde(source)) is not a folder on this Mac")
        }
        let r = git(["-C", source, "rev-parse", "--git-dir"], timeout: 20)
        guard r.code == 0 else {
            throw DotfilesError("\(DisplayPath.tilde(source)) is not a git repository — dotfiles are applied at a commit: git init, git add, git commit there")
        }
    }

    /// A folder with changes not committed (they are not included).
    func isDirty(_ source: String) -> Bool {
        let r = git(["-C", source, "status", "--porcelain", "--untracked-files=no"], timeout: 20)
        return r.code == 0 && !r.out.isEmpty
    }

    private func ensureRepository(_ source: String) throws {
        let repo = repository(source)
        if FileManager.default.fileExists(atPath: repo.appendingPathComponent("HEAD").path) { return }
        try FileManager.default.createDirectory(at: directory(source), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let r = git(["init", "--bare", "--quiet", repo.path], timeout: 20)
        guard r.code == 0 else { throw DotfilesError("could not make the cache for the dotfiles: \(r.err)") }
        try? source.write(to: directory(source).appendingPathComponent("source"), atomically: true, encoding: .utf8)
    }

    private func fetchFailure(_ source: String, _ err: String) -> DotfilesError {
        DotfilesError("could not fetch \(DotfilesSource.isLocal(source) ? DisplayPath.tilde(source) : source) with this Mac's git" + (err.isEmpty ? "" : ": \(err)"))
    }

    /// Fetch the source's default branch (its head) — the commit.
    public func resolve(_ source: String) throws -> String {
        if DotfilesSource.isLocal(source) { try checkLocal(source) }
        let l = lock(source); l.lock(); defer { l.unlock() }
        try ensureRepository(source)
        let f = git([gitDir(source), "fetch", "--quiet", "--no-tags", "--depth=1", DotfilesSource.fetchURL(source), "HEAD"])
        guard f.code == 0 else { throw fetchFailure(source, f.err) }
        let h = git([gitDir(source), "rev-parse", "FETCH_HEAD^{commit}"], timeout: 20)
        let commit = String(decoding: h.out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard h.code == 0, DotfilesPin.isCommit(commit) else { throw DotfilesError("could not read the head of \(source): \(h.err)") }
        _ = git([gitDir(source), "update-ref", "refs/doz/\(commit)", commit], timeout: 20)
        return commit
    }

    /// The commit is in the cache (fetched by its id — or the whole history — when it is not).
    public func ensure(_ source: String, commit: String) throws {
        guard DotfilesPin.isCommit(commit) else { throw DotfilesError("\(commit) is not a commit id") }
        let l = lock(source); l.lock(); defer { l.unlock() }
        try ensureRepository(source)
        if has(source, commit) { return }
        let url = DotfilesSource.fetchURL(source)
        var f = git([gitDir(source), "fetch", "--quiet", "--no-tags", "--depth=1", url, commit])
        if f.code != 0 || !has(source, commit) {
            f = git([gitDir(source), "fetch", "--quiet", "--no-tags", url, "+refs/heads/*:refs/doz-heads/*"])
        }
        guard has(source, commit) else {
            throw f.code != 0 ? fetchFailure(source, f.err) : DotfilesError("\(source) has no commit \(commit.prefix(12)) any more")
        }
        _ = git([gitDir(source), "update-ref", "refs/doz/\(commit)", commit], timeout: 20)
    }

    public func has(_ source: String, _ commit: String) -> Bool {
        FileManager.default.fileExists(atPath: repository(source).path)
            && git([gitDir(source), "cat-file", "-e", commit + "^{commit}"], timeout: 20).code == 0
    }

    /// The commit's tree.
    public func entries(_ source: String, commit: String) throws -> [DotfilesEntry] {
        let r = git([gitDir(source), "ls-tree", "-r", "-t", "-z", commit], timeout: 60)
        guard r.code == 0 else { throw DotfilesError("could not list the files of \(commit.prefix(12)): \(r.err)") }
        return DotfilesLayer.parseTree(r.out)
    }

    /// The commit's files as a tar (of its TREE: no pax header naming the commit — every tar reads it).
    public func archive(_ source: String, commit: String) throws -> Data {
        let r = git([gitDir(source), "archive", "--format=tar", commit + "^{tree}"], timeout: 120)
        guard r.code == 0 else { throw DotfilesError("could not pack the files of \(commit.prefix(12)): \(r.err)") }
        guard r.out.count <= DotfilesLayer.maximumArchiveBytes else {
            throw DotfilesError("the dotfiles are \(r.out.count >> 20) MiB — at most \(DotfilesLayer.maximumArchiveBytes >> 20) MiB")
        }
        return r.out
    }

    public func subject(_ source: String, commit: String) -> String? {
        let r = git([gitDir(source), "log", "-1", "--format=%s", commit], timeout: 20)
        let s = String(decoding: r.out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return r.code == 0 && !s.isEmpty ? InertText.line(Substring(s), limit: 120) : nil
    }

    /// What is cached (for doctor): each source and its directory's size.
    public func cached() -> [(source: String, bytes: Int64)] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return dirs.compactMap { d in
            guard let s = try? String(contentsOf: d.appendingPathComponent("source"), encoding: .utf8) else { return nil }
            return (s, allocatedBytes(d))
        }.sorted { $0.source < $1.source }
    }
}

/// The dotfiles a person said yes to, by source and commit (`<settings dir>/dotfiles-trusted.json`) — asked once each.
public enum DotfilesTrust {
    public struct Record: Codable, Equatable, Sendable {
        public var source: String
        public var commit: String
        public var at: Date
    }

    public static func file(_ env: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        DozableSettings.fileURL(environment: env)?.deletingLastPathComponent().appendingPathComponent("dotfiles-trusted.json")
    }

    public static func records(_ env: [String: String] = ProcessInfo.processInfo.environment) -> [Record] {
        guard let f = file(env), let d = try? Data(contentsOf: f) else { return [] }
        return (try? HostWire.decoder.decode([Record].self, from: d)) ?? []
    }

    public static func isTrusted(source: String, commit: String, _ env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        records(env).contains { $0.source == source && $0.commit == commit }
    }

    /// Record a yes (the file 0600 in its 0700 directory). Throws when it cannot be written.
    public static func trust(source: String, commit: String, _ env: [String: String] = ProcessInfo.processInfo.environment) throws {
        guard let f = file(env) else { throw DotfilesError("no settings folder to keep the answer in (HOME is not set)") }
        var all = records(env).filter { !($0.source == source && $0.commit == commit) }
        all.append(Record(source: source, commit: commit, at: Date()))
        try FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try HostWire.prettyEncoder.encode(all).write(to: f, options: .atomic)
        chmod(f.path, 0o600)
    }
}

extension HostCore {
    public nonisolated var dotfilesCache: DotfilesCache { DotfilesCache(root: store.root.appendingPathComponent("dotfiles")) }

    /// The setting `sandbox.dotfiles`, normalised (nil: none, or a value that does not check).
    static func settingDotfiles(_ settings: DozableSettings = .load()) -> String? {
        guard let v = settings.string(SettingKey.dotfiles) else { return nil }
        return try? DotfilesSource.normalized(v, home: TestSafety.realHome.path)
    }

    /// Home-relative paths under the sandbox's shares (none today: /workspace is not in the home) — Dozable's too.
    static func dotfilesExtraProtected(_ cfg: SandboxConfig) -> [String] {
        let home = cfg.spec.imageSpec?.home ?? "/root"
        return cfg.spec.shares.compactMap { s in s.guestPath.hasPrefix(home + "/") ? String(s.guestPath.dropFirst(home.count + 1)) : nil }
    }

    /// Give the sandbox its dotfiles (its pin, and the cache to read them from). Called when it is loaded, created or
    /// moved on.
    func applyDotfilesInput(_ m: Managed) {
        guard !readOnly else { return }
        guard let pin = m.config.dotfiles else { m.sandbox.setDotfiles(nil); return }
        let cache = dotfilesCache
        let extra = Self.dotfilesExtraProtected(m.config)
        m.sandbox.setDotfiles(DotfilesInput(pin: pin) {
            await Task.detached { () -> Result<DotfilesPayload, DotfilesError> in
                do {
                    try cache.ensure(pin.source, commit: pin.commit)
                    let plan = DotfilesLayer.plan(try cache.entries(pin.source, commit: pin.commit), extraProtected: extra)
                    return .success(DotfilesPayload(archive: try cache.archive(pin.source, commit: pin.commit), plan: plan))
                } catch let e as DotfilesError {
                    return .failure(e)
                } catch {
                    return .failure(DotfilesError(error.localizedDescription))
                }
            }.value
        })
    }

    /// `SandboxInfo.dotfiles`.
    func dotfilesState(_ m: Managed) -> DotfilesState? {
        guard let pin = m.config.dotfiles else { return nil }
        let last = m.sandbox.lastDotfilesRun.flatMap { $0.commit == pin.commit && $0.source == pin.source ? $0 : nil }
        return DotfilesState(source: pin.source, display: Self.dotfilesDisplay(pin.source), commit: pin.commit, resolvedAt: pin.resolvedAt,
                             state: last.map { $0.ok ? "applied" : "failed" } ?? "pending",
                             method: last?.method, script: last?.script, summary: last?.summary, at: last?.at)
    }

    static func dotfilesDisplay(_ source: String) -> String { DotfilesSource.isLocal(source) ? DisplayPath.tilde(source) : source }

    func dotfilesReport(_ m: Managed, changed: String? = nil) async -> DotfilesReport {
        let cache = dotfilesCache
        let pin = m.config.dotfiles
        let extra = Self.dotfilesExtraProtected(m.config)
        let plan: DotfilesPlan? = await Task.detached {
            guard let pin, cache.has(pin.source, pin.commit), let e = try? cache.entries(pin.source, commit: pin.commit) else { return nil }
            return DotfilesLayer.plan(e, extraProtected: extra)
        }.value
        return DotfilesReport(sandbox: m.name, dotfiles: dotfilesState(m), setting: Self.settingDotfiles(), plan: plan,
                              last: m.sandbox.lastDotfilesRun, changed: changed)
    }

    /// `dotfiles-resolve`: fetch a source (nil: the setting) and say its head and what applying it does.
    func resolveDotfiles(_ given: String?, extraProtected: [String] = []) async throws -> DotfilesResolved {
        let raw = given ?? DozableSettings.load().string(SettingKey.dotfiles) ?? ""
        let source: String
        do {
            guard let s = try DotfilesSource.normalized(raw, home: TestSafety.realHome.path) else {
                throw HostError(.invalid, given == nil ? "no dotfiles are set (the setting sandbox.dotfiles is empty)" : "none: no dotfiles")
            }
            source = s
        } catch let e as DotfilesError { throw HostError(.invalid, "dotfiles: \(e.message)") }
        let cache = dotfilesCache
        return try await Task.detached { () throws -> DotfilesResolved in
            do {
                let commit = try cache.resolve(source)
                let plan = DotfilesLayer.plan(try cache.entries(source, commit: commit), extraProtected: extraProtected)
                let local = DotfilesSource.isLocal(source)
                return DotfilesResolved(source: source, commit: commit, subject: cache.subject(source, commit: commit), plan: plan, local: local,
                                        dirty: local && cache.isDirty(source) ? true : nil, display: Self.dotfilesDisplay(source))
            } catch let e as DotfilesError { throw HostError(.failed, e.message) }
        }.value
    }

    /// The pin a new sandbox gets (nil: none) — the create's own choice (`none`: none), else the setting; at the commit
    /// the CLI had the person trust, else the head.
    func dotfilesPinForCreate(_ o: CreateOptions, name: String, emit: @escaping @Sendable (HostEvent) -> Void) async throws -> DotfilesPin? {
        let raw = o.dotfiles ?? DozableSettings.load().string(SettingKey.dotfiles) ?? ""
        let source: String
        do {
            guard let s = try DotfilesSource.normalized(raw, home: TestSafety.realHome.path) else { return nil }
            source = s
        } catch let e as DotfilesError { throw HostError(.invalid, "dotfiles: \(e.message)") }
        let cache = dotfilesCache
        let commit: String = try await Task.detached { () throws -> String in
            do {
                if let c = o.dotfilesCommit {
                    try cache.ensure(source, commit: c)
                    return c
                }
                return try cache.resolve(source)
            } catch let e as DotfilesError {
                throw HostError(.failed, "\(e.message) — or make it without them: --dotfiles none")
            }
        }.value
        emit(HostEvent(kind: .note, sandbox: name, text: "dotfiles: \(Self.dotfilesDisplay(source)) at \(commit.prefix(12)) — applied at its first start"))
        return DotfilesPin(source: source, commit: commit)
    }

    /// `dotfiles-update`: move the sandbox to `commit` (nil: its source's head — the setting's when it has none) and apply
    /// it now when it runs (as steps), else at its next start or wake.
    func updateDotfiles(_ r: HostRequest, emit: @escaping @Sendable (HostEvent) -> Void) async throws -> DotfilesReport {
        let m = try get(r.name)
        let source: String
        if let given = r.dotfilesSource {
            guard let s = try? DotfilesSource.normalized(given, home: TestSafety.realHome.path) else {
                throw HostError(.invalid, "dotfiles: \(DotfilesSource.problem(given) ?? "none: no dotfiles")")
            }
            source = s
        } else if let s = m.config.dotfiles?.source ?? Self.settingDotfiles() {
            source = s
        } else {
            throw HostError(.invalid, "\(m.name) has no dotfiles, and the setting sandbox.dotfiles is empty — doz config set sandbox.dotfiles URL|PATH")
        }
        let cache = dotfilesCache
        let commit: String = try await Task.detached { () throws -> String in
            do {
                if let c = r.dotfilesCommit { try cache.ensure(source, commit: c); return c }
                return try cache.resolve(source)
            } catch let e as DotfilesError { throw HostError(.failed, e.message) }
        }.value
        m.config.dotfiles = DotfilesPin(source: source, commit: commit)
        try m.config.write(store.configFile(m.name))
        applyDotfilesInput(m)
        let phase = await m.sandbox.status.phase
        var changed = "\(m.name)'s dotfiles: \(Self.dotfilesDisplay(source)) at \(commit.prefix(12))"
        if phase == .running {
            let events = m.sandbox.events()
            let name = m.name
            let relay = Task {
                for await e in events {
                    switch e {
                    case .step(let s, _), .stepStarted(let s), .stepFailed(let s, _, _):
                        if s.hasPrefix("dotfiles: "), let h = HostEvent(e, sandbox: name) { emit(h) }
                    case .note(let s):
                        if s.hasPrefix("dotfiles"), let h = HostEvent(e, sandbox: name) { emit(h) }
                    default: break
                    }
                }
            }
            let run = await m.sandbox.applyDotfilesNow()
            try? await Task.sleep(for: .milliseconds(50))
            relay.cancel()
            changed += run.map { " — applied now: \($0.summary)" } ?? " — not applied (see the host log)"
        } else {
            changed += " — applied at its next start or wake"
        }
        note(m.name, changed)
        return await dotfilesReport(m, changed: changed)
    }
}
