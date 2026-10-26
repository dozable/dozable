import CryptoKit
import Darwin
import DozableKit
import Foundation

// The recipe catalogue, the client half (DozableKit has the format, the merge and the checks — `RecipeCatalogue.swift`).
//
// · WHERE: `<settings dir>/recipes/` — `current.json` (the manifest in use), `next.json` (a newer one downloaded and
//   verified, waiting for the next host start), `files/<serial>/…` (the data), `state.json` (the conditional request's
//   validators, the last check, the problem said once, the refused ones). The settings dir, as the update feed's state:
//   the same host, key and trust — and it is known from the environment alone, before `--store` is parsed.
// · WHICH, once per process, at its start (`RecipeCatalogueSelection.choose` → `RecipeCatalogue.adopt`, then sealed):
//   a guarded test run only with its seam; a development build only with the seam (a recipe edited in the tree wins);
//   else `current.json` — and in the HOST's own start, the waiting `next.json`, promoted when it passes. So a CLI
//   always uses what the running host uses, and a new catalogue applies from the next host start.
// · REFRESH: the host, at most hourly (`RecipeCatalogueRefresh`): conditional GET; 404 = none published (keep what is
//   used, silent); offline silent; a newer one's files fetched and checked by sha256 before `next.json` is written.
// · SEAMS: `DOZ_TEST_RECIPE_CATALOGUE` = `offline` (the cache, never the network) | an http(s) URL of a recipes.json
//   (the host fetches it; http only from 127.0.0.1) | an absolute path to a recipes.json (every process uses THAT,
//   beside its files — no cache, no fetch). `DOZ_TEST_UPDATE_KEY` is the trusted key — for the catalogue only in a
//   guarded run.

/// The catalogue's cache in the settings dir.
public struct RecipeCatalogueCache: Sendable {
    public let dir: URL

    public init(dir: URL) { self.dir = dir }

    public static func at(_ env: [String: String] = ProcessInfo.processInfo.environment) -> RecipeCatalogueCache? {
        DozableSettings.fileURL(environment: env).map { RecipeCatalogueCache(dir: $0.deletingLastPathComponent().appendingPathComponent("recipes")) }
    }

    public var currentURL: URL { dir.appendingPathComponent("current.json") }
    public var nextURL: URL { dir.appendingPathComponent("next.json") }
    public var stateURL: URL { dir.appendingPathComponent("state.json") }
    public func filesDir(serial: Int) -> URL { dir.appendingPathComponent("files/\(serial)", isDirectory: true) }

    /// A manifest file, decoded (never trusted until verified).
    public func manifest(_ url: URL) -> (RecipeCatalogueManifest, Data)? {
        guard let d = try? Data(contentsOf: url), let m = try? RecipeCatalogueManifest.decode(d) else { return nil }
        return (m, d)
    }

    public var current: RecipeCatalogueManifest? { manifest(currentURL)?.0 }
    public var next: RecipeCatalogueManifest? { manifest(nextURL)?.0 }

    /// The files a manifest names, from `folder` (nil when one is missing or too large).
    public static func readFiles(_ m: RecipeCatalogueManifest, from folder: URL) -> [String: Data]? {
        var out: [String: Data] = [:]
        for f in m.files {
            let u = folder.appendingPathComponent(f.path)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: u.path), (attrs[.size] as? Int) == f.size,
                  let d = try? Data(contentsOf: u) else { return nil }
            out[f.path] = d
        }
        return out
    }

    public var state: RecipeCatalogueState { RecipeCatalogueState.load(stateURL) }

    /// Atomically (a temporary beside it, then a rename), 0600 in a 0700 folder.
    static func write(_ d: Data, to url: URL) -> Bool {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(getpid())")
        guard FileManager.default.createFile(atPath: tmp.path, contents: d, attributes: [.posixPermissions: 0o600]) else { return false }
        if rename(tmp.path, url.path) != 0 { unlink(tmp.path); return false }
        return true
    }

    /// Keep only the folders of `serials`.
    func prune(keeping serials: Set<Int>) {
        let files = dir.appendingPathComponent("files")
        for name in (try? FileManager.default.contentsOfDirectory(atPath: files.path)) ?? [] {
            if let n = Int(name), serials.contains(n) { continue }
            try? FileManager.default.removeItem(at: files.appendingPathComponent(name))
        }
    }
}

/// What the client remembers (`state.json` — never a secret).
public struct RecipeCatalogueState: Codable, Equatable, Sendable {
    public var lastCheck: Date?
    public var lastAttempt: Date?
    public var etag: String?
    public var lastModified: String?
    /// The last problem, and the digest of the last one SAID (a problem is said once).
    public var problem: String?
    public var problemAt: Date?
    public var reportedProblem: String?
    /// Catalogues this doz refused — "<version> <serial> <signature>" → why — never tried again by that version.
    public var refused: [String: String]?
    /// Serials the refresh will not download again (refused here).
    public var refusedSerials: [Int]?

    public init() {}

    public static func load(_ url: URL) -> RecipeCatalogueState {
        guard let d = try? Data(contentsOf: url) else { return RecipeCatalogueState() }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode(RecipeCatalogueState.self, from: d)) ?? RecipeCatalogueState()
    }

    public func save(_ url: URL) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys, .prettyPrinted]
        guard let d = try? enc.encode(self) else { return }
        _ = RecipeCatalogueCache.write(d, to: url)
    }

    /// Remember `problem`; true when it was not said before (say it now).
    mutating func record(_ problem: String, now: Date) -> Bool {
        self.problem = problem
        problemAt = now
        let digest = RecipeCatalogueManifest.sha256(Data(problem.utf8))
        guard reportedProblem != digest else { return false }
        reportedProblem = digest
        return true
    }
}

/// The test seam, parsed.
public enum RecipeCatalogueSeam: Equatable, Sendable {
    /// The cache only — never the network.
    case offline
    /// The host fetches this recipes.json (http only from 127.0.0.1).
    case url(URL)
    /// Every process uses THIS recipes.json directly (its files beside it, under its `base`).
    case file(URL)

    public static func from(_ env: [String: String]) -> RecipeCatalogueSeam? {
        guard let v = env["DOZ_TEST_RECIPE_CATALOGUE"], !v.isEmpty else { return nil }
        if v == "offline" { return .offline }
        if v.hasPrefix("/") { return .file(URL(fileURLWithPath: v)) }
        if let u = URL(string: v), ["http", "https"].contains(u.scheme ?? "") { return .url(u) }
        return .offline
    }
}

/// What a process chose, and anything to say about it.
public struct RecipeCatalogueChoice: Equatable, Sendable {
    public var source: RecipeSource
    /// Why the embedded set is used when no catalogue was even looked at (a test run, a development build).
    public var notLooked: String?
    /// A catalogue was refused (said once: `reportNow`).
    public var problem: String?
    public var reportNow = false
    /// `next.json` became `current.json` (the host's start).
    public var promoted = false
}

public enum RecipeCatalogueSelection {
    /// What this process chose at its start (the host's log says it).
    nonisolated(unsafe) public static var startChoice: RecipeCatalogueChoice?

    /// `DozableEntry`'s first step: choose, install, seal — before anything reads a recipe.
    /// 653: `extras` runs between Dozable's own choice and the seal — the recipes that are not Dozable's
    /// (`RecipeExtras.chooseAtStart`).
    public static func chooseAtStart(args: [String], version: String, executable: String, extras: () -> Void = {}) -> RecipeCatalogueChoice {
        let c = choose(args: args, version: version, executable: executable)
        extras()
        RecipeCatalogue.seal()
        startChoice = c
        return c
    }

    /// The key a catalogue must be signed with: Dozable's update key — or, in a guarded run, `DOZ_TEST_UPDATE_KEY`.
    public static func publicKey(_ env: [String: String], guarded: Bool) -> Data? {
        if guarded, let t = env["DOZ_TEST_UPDATE_KEY"], !t.isEmpty { return Data(base64Encoded: t).flatMap { $0.count == 32 ? $0 : nil } }
        return Data(base64Encoded: Distribution.updatePublicKey).flatMap { $0.count == 32 ? $0 : nil }
    }

    /// The host's own process: `doz host start --foreground` (what `HostLauncher` runs) — `host` is the default too.
    public static func isHostStart(_ args: [String]) -> Bool {
        args.first == "host" && args.contains("--foreground")
    }

    /// A catalogue that is fine but not for THIS build (it needs a newer doz, or this doz's own recipes are newer) — passed
    /// over quietly: after an upgrade the cached one is simply older than the build, which is no problem to say.
    public static func isNotForThisBuild(_ problem: String) -> Bool {
        problem.hasPrefix("it needs doz") || problem.hasPrefix("it was made from")
    }

    /// Why this doz may not use `m` (nil: it may): signed with `key`, readable by this doz, not older than its own.
    public static func problem(_ m: RecipeCatalogueManifest, key: Data?, version: String) -> String? {
        do { try m.check() } catch { return RecipeCatalogue.reason(error) }
        guard let key, m.verify(publicKey: key) else { return "its signature does not verify" }
        if SemVer.compare(m.minimumDoz, version) == .orderedDescending { return "it needs doz \(m.minimumDoz) or later (this is \(version))" }
        if let c = SemVer.compare(m.sourceVersion, version), c == .orderedAscending {
            return "it was made from \(m.sourceVersion), older than this doz (\(version)) — this doz's own recipes are newer"
        }
        return nil
    }

    /// Choose this process's recipes and INSTALL them (`RecipeCatalogue.adopt`; the caller seals). Writes only the
    /// cache's state (a refusal, said once) and, in the host's start, the promotion of `next.json`.
    @discardableResult
    public static func choose(args: [String], version: String, executable: String,
                              env: [String: String] = ProcessInfo.processInfo.environment,
                              guarded: Bool? = nil, now: Date = Date()) -> RecipeCatalogueChoice {
        let guarded = guarded ?? TestSafety.guarded(env)
        let seam = RecipeCatalogueSeam.from(env)
        var choice = RecipeCatalogueChoice(source: .embedded)
        if seam == nil {
            if guarded { choice.notLooked = "a test run (no DOZ_TEST_RECIPE_CATALOGUE)"; return choice }
            if case .development = InstallMethod.detect(executable: executable) {
                choice.notLooked = "a development build (its own recipes)"
                return choice
            }
        }
        let key = publicKey(env, guarded: guarded)
        // The seam's own file: used directly, nothing cached.
        if case .file(let url)? = seam {
            guard let d = try? Data(contentsOf: url) else { choice.problem = "\(url.path) cannot be read"; choice.reportNow = true; return choice }
            do {
                let m = try RecipeCatalogueManifest.decode(d)
                if let p = problem(m, key: key, version: version) { throw SandboxError.invalidSpec(p) }
                let folder = url.deletingLastPathComponent().appendingPathComponent(m.base, isDirectory: true)
                guard let files = RecipeCatalogueCache.readFiles(m, from: folder) else { throw SandboxError.invalidSpec("a file it names is missing") }
                choice.source = try RecipeCatalogue.adopt(m, files: files)
            } catch {
                choice.problem = "the recipe catalogue \(url.path) was ignored: \(RecipeCatalogue.reason(error))"
                choice.reportNow = true
            }
            return choice
        }
        guard let cache = RecipeCatalogueCache.at(env) else { return choice }
        var state = cache.state
        var stateChanged = false
        let host = isHostStart(args)
        var candidates: [(url: URL, isNext: Bool)] = []
        if host { candidates.append((cache.nextURL, true)) }
        candidates.append((cache.currentURL, false))
        let inUse = cache.current?.serial ?? 0
        for c in candidates {
            guard let (m, _) = cache.manifest(c.url) else { continue }
            // One catalogue, as signed (its signature names it), refused by this version.
            let refusalKey = "\(version) \(m.serial) \(m.signature)"
            if state.refused?[refusalKey] != nil {
                if c.isNext { try? FileManager.default.removeItem(at: c.url) }
                continue
            }
            do {
                if let p = problem(m, key: key, version: version) {
                    if isNotForThisBuild(p) { continue }            // not this build's: its own recipes, nothing said
                    throw SandboxError.invalidSpec(p)
                }
                if c.isNext, m.serial <= inUse { throw SandboxError.invalidSpec("serial \(m.serial) is not newer than \(inUse)") }
                // A file missing is no verdict (a host start may be promoting a newer one this moment): passed over.
                guard let files = RecipeCatalogueCache.readFiles(m, from: cache.filesDir(serial: m.serial)) else { continue }
                choice.source = try RecipeCatalogue.adopt(m, files: files)
                if c.isNext {
                    if rename(cache.nextURL.path, cache.currentURL.path) == 0 {
                        choice.promoted = true
                        cache.prune(keeping: [m.serial])
                    }
                }
                // A newer catalogue applied: an earlier problem is history.
                if choice.promoted, state.problem != nil {
                    state.problem = nil
                    state.problemAt = nil
                    stateChanged = true
                }
                break
            } catch {
                let why = RecipeCatalogue.reason(error)
                var r = state.refused ?? [:]
                r[refusalKey] = why
                state.refused = r
                if c.isNext {
                    state.refusedSerials = Array(Set((state.refusedSerials ?? []) + [m.serial])).sorted()
                    try? FileManager.default.removeItem(at: c.url)
                }
                let line = "the recipe catalogue \(m.serial) was ignored: \(why)"
                choice.problem = line
                if state.record(line, now: now) { choice.reportNow = true }
                stateChanged = true
            }
        }
        if stateChanged { state.save(cache.stateURL) }
        return choice
    }

    /// The `doz doctor` line: what this process uses, what waits, the last refusal.
    public static func describe(version: String, env: [String: String] = ProcessInfo.processInfo.environment) -> String {
        var s = "recipes: " + RecipeCatalogue.source.describe(dozVersion: version)
        if let cache = RecipeCatalogueCache.at(env) {
            if let n = cache.next { s += " · catalogue \(n.serial) is downloaded and applies at the next host start (doz host restart)" }
            let st = cache.state
            if let p = st.problem { s += " · last problem: \(p)" }
            if let c = st.lastCheck { s += " · last checked \(ISO8601DateFormatter().string(from: c))" }
        }
        return s
    }
}

/// The host's look for a newer catalogue.
public enum RecipeCatalogueRefresh {
    public static let interval: TimeInterval = 3600

    public enum Outcome: Equatable, Sendable {
        /// Not looked for (why).
        case disabled(String)
        /// Asked within the hour.
        case notDue
        /// Not reachable, or a server error: silent, asked again in an hour.
        case offline
        /// Nothing published (404), or unchanged (304), or nothing newer this doz may use.
        case unchanged
        /// A newer catalogue's files are here and `next.json` names it: it applies at the next host start.
        case downloaded(serial: Int)
        /// It was not one this doz takes (said once: `reportNow`).
        case refused(String, reportNow: Bool)
    }

    /// The URL to ask, or why not.
    public static func target(version: String, executable: String, env: [String: String], guarded: Bool) -> Result<URL, RefreshDisabled> {
        switch RecipeCatalogueSeam.from(env) {
        case .offline?: return .failure(RefreshDisabled("DOZ_TEST_RECIPE_CATALOGUE=offline"))
        case .file?: return .failure(RefreshDisabled("DOZ_TEST_RECIPE_CATALOGUE names a file"))
        case .url(let u)?:
            if u.scheme == "http", u.host != "127.0.0.1" { return .failure(RefreshDisabled("a test catalogue over http only from 127.0.0.1")) }
            return .success(u)
        case nil:
            if guarded { return .failure(RefreshDisabled("not in a test run (no DOZ_TEST_RECIPE_CATALOGUE)")) }
            if case .development = InstallMethod.detect(executable: executable) { return .failure(RefreshDisabled("a development build uses its own recipes")) }
            return .success(URL(string: Distribution.recipeCatalogueURL)!)
        }
    }

    public struct RefreshDisabled: Error, Equatable { public var why: String; init(_ w: String) { why = w } }

    public static func refresh(version: String, executable: String, env: [String: String] = ProcessInfo.processInfo.environment,
                               guarded: Bool? = nil, now: Date = Date(), force: Bool = false,
                               fetch: UpdateFetch = UpdateChecker.urlSessionFetch) async -> Outcome {
        let guarded = guarded ?? TestSafety.guarded(env)
        let url: URL
        switch target(version: version, executable: executable, env: env, guarded: guarded) {
        case .failure(let d): return .disabled(d.why)
        case .success(let u): url = u
        }
        guard let cache = RecipeCatalogueCache.at(env) else { return .disabled("no settings dir") }
        var state = cache.state
        if !force, let a = state.lastAttempt, a <= now, now.timeIntervalSince(a) < interval { return .notDue }
        state.lastAttempt = now
        defer { state.save(cache.stateURL) }
        let current = cache.current, next = cache.next
        var req = URLRequest(url: url)
        req.setValue("doz/\(version)", forHTTPHeaderField: "User-Agent")
        if current != nil || next != nil {
            if let e = state.etag { req.setValue(e, forHTTPHeaderField: "If-None-Match") }
            if let m = state.lastModified { req.setValue(m, forHTTPHeaderField: "If-Modified-Since") }
        }
        let body: Data, resp: HTTPURLResponse
        do { (body, resp) = try await fetch(req) } catch { return .offline }
        switch resp.statusCode {
        case 200: break
        case 304, 404:
            state.lastCheck = now
            return .unchanged
        default: return .offline
        }
        state.lastCheck = now
        let m: RecipeCatalogueManifest
        do { m = try RecipeCatalogueManifest.decode(body) } catch {
            let said = state.record("the recipe catalogue was ignored: \(RecipeCatalogue.reason(error))", now: now)
            return .refused(state.problem ?? "", reportNow: said)
        }
        let key = RecipeCatalogueSelection.publicKey(env, guarded: guarded)
        // Newer than what is here, and one this doz may use — else nothing to do (a doz too old for it waits for an update).
        let have = max(current?.serial ?? 0, next?.serial ?? 0)
        guard m.serial > have, !(state.refusedSerials ?? []).contains(m.serial) else {
            state.etag = resp.value(forHTTPHeaderField: "ETag")
            state.lastModified = resp.value(forHTTPHeaderField: "Last-Modified")
            return .unchanged
        }
        if let p = RecipeCatalogueSelection.problem(m, key: key, version: version) {
            if RecipeCatalogueSelection.isNotForThisBuild(p) {
                state.etag = resp.value(forHTTPHeaderField: "ETag")
                state.lastModified = resp.value(forHTTPHeaderField: "Last-Modified")
                return .unchanged
            }
            let said = state.record("the recipe catalogue \(m.serial) was ignored: \(p)", now: now)
            return .refused(state.problem ?? p, reportNow: said)
        }
        // Its files, each checked, into a temporary folder — then renamed into place, then next.json.
        let tmp = cache.dir.appendingPathComponent("files/.tmp-\(m.serial)-\(getpid())", isDirectory: true)
        try? FileManager.default.removeItem(at: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        for f in m.files {
            guard let fu = URL(string: m.base + f.path, relativeTo: url)?.absoluteURL,
                  fu.scheme == url.scheme, fu.host == url.host else { return .offline }
            var r = URLRequest(url: fu)
            r.setValue("doz/\(version)", forHTTPHeaderField: "User-Agent")
            let d: Data
            do {
                let (data, h) = try await fetch(r)
                guard h.statusCode == 200 else { return .offline }
                d = data
            } catch { return .offline }
            guard d.count == f.size, RecipeCatalogueManifest.sha256(d) == f.sha256 else {
                let said = state.record("the recipe catalogue \(m.serial) was ignored: \(f.path) does not match its sha256", now: now)
                return .refused(state.problem ?? "", reportNow: said)
            }
            let dest = tmp.appendingPathComponent(f.path)
            try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            guard FileManager.default.createFile(atPath: dest.path, contents: d, attributes: [.posixPermissions: 0o600]) else { return .offline }
        }
        let final = cache.filesDir(serial: m.serial)
        try? FileManager.default.removeItem(at: final)
        guard (try? FileManager.default.moveItem(at: tmp, to: final)) != nil else { return .offline }
        guard RecipeCatalogueCache.write(body, to: cache.nextURL) else { return .offline }
        cache.prune(keeping: Set([current?.serial, m.serial].compactMap { $0 }))
        state.etag = resp.value(forHTTPHeaderField: "ETag")
        state.lastModified = resp.value(forHTTPHeaderField: "Last-Modified")
        return .downloaded(serial: m.serial)
    }

    /// A newer catalogue waits for the next host start.
    public static func waiting(env: [String: String] = ProcessInfo.processInfo.environment) -> Int? {
        RecipeCatalogueCache.at(env)?.next?.serial
    }
}
