import CryptoKit
import Darwin
import DozableKit
import Foundation

// 653 — the recipes that are NOT Dozable's: your own and the community catalogues you added. DozableKit has the merge and
// the community requirements (`RecipeCatalogue.adoptExtras`, `CommunityRequirements`); this is where they live on the Mac
// and how a process chooses them.
//
// · WHERE (`<settings dir>/recipes/`, beside 652's catalogue cache):
//     mine/<id>.yaml                  your recipes, as you wrote them (`doz recipe new|add`)
//     sources.json                    the community sources: URL, key, its fingerprint, when you confirmed it
//     community/<name>/…              each source's cache — 652's layout (current.json, next.json, files/<serial>/, state.json)
//     kept/<id>.json                  a removed recipe, kept unpublished so the sandboxes made from it keep working
//     in-use/in-use.json + documents  THE SNAPSHOT: what the last host start chose
//     checks.json                     `doz recipe check` passes, by the sha256 of the bytes that passed
//     trusted.json                    the community recipes you said yes to, by id and sha256 (asked once per version)
// · WHICH (once per process, like 652): every process adopts the snapshot; a HOST's own start rebuilds it first (your
//   YAML compiled — the CLI hands in the compiler, Yams stays there — the community caches promoted), and so do the
//   `doz recipe` commands when no host runs. So a command always uses what the running host uses, and a change applies
//   from the next host start.

/// The files.
public struct RecipeExtrasPaths: Sendable {
    public let dir: URL

    public init(dir: URL) { self.dir = dir }

    /// `<settings dir>/recipes` (nil: no settings dir).
    public static func at(_ env: [String: String] = ProcessInfo.processInfo.environment) -> RecipeExtrasPaths? {
        RecipeCatalogueCache.at(env).map { RecipeExtrasPaths(dir: $0.dir) }
    }

    public var mine: URL { dir.appendingPathComponent("mine", isDirectory: true) }
    public func mine(_ id: String) -> URL { mine.appendingPathComponent("\(id).yaml") }
    public var sources: URL { dir.appendingPathComponent("sources.json") }
    public func community(_ name: String) -> RecipeCatalogueCache {
        RecipeCatalogueCache(dir: dir.appendingPathComponent("community/\(name)", isDirectory: true))
    }
    public var kept: URL { dir.appendingPathComponent("kept", isDirectory: true) }
    public func kept(_ id: String) -> URL { kept.appendingPathComponent("\(id).json") }
    public var inUse: URL { dir.appendingPathComponent("in-use", isDirectory: true) }
    public var inUseFile: URL { inUse.appendingPathComponent("in-use.json") }
    public var checks: URL { dir.appendingPathComponent("checks.json") }
    public var trusted: URL { dir.appendingPathComponent("trusted.json") }

    /// The ids of your recipe files (sorted).
    public func mineIDs() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: mine.path)) ?? [])
            .filter { $0.hasSuffix(".yaml") }.map { String($0.dropLast(5)) }.filter(RecipeExtras.isRecipeID).sorted()
    }
}

/// A community source the person added.
public struct CommunitySource: Codable, Equatable, Sendable {
    public var name: String
    /// Its recipes.json (https; http only from 127.0.0.1 in a guarded test run).
    public var url: String
    /// The publisher's Ed25519 public key (base64, 32 bytes).
    public var key: String
    /// `SHA256:<base64>` of the key — what the person compared with the publisher's.
    public var fingerprint: String
    /// When the person confirmed the fingerprint (ISO 8601) — nothing is fetched before.
    public var confirmed: String
    public var added: String

    public init(name: String, url: String, key: String, fingerprint: String, confirmed: String, added: String) {
        self.name = name; self.url = url; self.key = key; self.fingerprint = fingerprint; self.confirmed = confirmed; self.added = added
    }
}

public struct CommunitySources: Codable, Equatable, Sendable {
    public var schema = 1
    public var sources: [CommunitySource] = []
    public init() {}

    public static func load(_ p: RecipeExtrasPaths) -> CommunitySources {
        guard let d = try? Data(contentsOf: p.sources), let s = try? JSONDecoder().decode(CommunitySources.self, from: d), s.schema == 1 else {
            return CommunitySources()
        }
        return s
    }

    public func save(_ p: RecipeExtrasPaths) -> Bool { RecipeExtras.writeJSON(self, to: p.sources) }
}

/// The snapshot (`in-use/in-use.json`): the sources a process adopts, in order, and what was refused before adoption.
public struct RecipeInUse: Codable, Equatable, Sendable {
    public struct Source: Codable, Equatable, Sendable {
        public var origin: RecipeOrigin
        public var name: String
        public var published: Bool
        /// A community source's catalogue serial.
        public var serial: Int?
        public var files: [File]
    }
    public struct File: Codable, Equatable, Sendable {
        /// The recipe's id.
        public var id: String
        /// The document beside in-use.json.
        public var file: String
        /// The sha256 of the bytes it came from (your YAML; the community file).
        public var sha256: String
    }
    public struct Refusal: Codable, Equatable, Sendable {
        public var origin: RecipeOrigin
        public var name: String
        public var why: String
    }
    public var schema = 1
    public var chosen: String
    public var doz: String
    public var sources: [Source] = []
    public var refused: [Refusal] = []
}

/// A recipe kept after its removal.
public struct KeptRecipe: Codable, Equatable, Sendable {
    public var origin: RecipeOrigin
    public var id: String
    public var sha256: String
    public var removed: String
    /// The compiled document (JSON text).
    public var document: String
}

/// One `doz recipe check` pass.
public struct RecipeCheckRecord: Codable, Equatable, Sendable {
    public var id: String
    public var sha256: String
    /// `static` | `full`.
    public var level: String
    public var doz: String
    public var date: String
    public init(id: String, sha256: String, level: String, doz: String, date: String) {
        self.id = id; self.sha256 = sha256; self.level = level; self.doz = doz; self.date = date
    }
}

/// One yes to a community recipe's version.
public struct RecipeTrustRecord: Codable, Equatable, Sendable {
    public var id: String
    public var sha256: String
    public var date: String
}

public enum RecipeExtras {
    /// A recipe's id as a file name may carry it.
    public static func isRecipeID(_ s: String) -> Bool { s.range(of: "^[a-z][a-z0-9-]{0,23}$", options: .regularExpression) != nil }

    public static func sha256(_ d: Data) -> String { RecipeCatalogueManifest.sha256(d) }

    static func now(_ d: Date = Date()) -> String { ISO8601DateFormatter().string(from: d) }

    /// `SHA256:<base64, no padding>` of a base64 Ed25519 public key (ssh's form); nil when it is not one.
    public static func fingerprint(_ keyBase64: String) -> String? {
        guard let k = Data(base64Encoded: keyBase64.trimmingCharacters(in: .whitespacesAndNewlines)), k.count == 32,
              (try? Curve25519.Signing.PublicKey(rawRepresentation: k)) != nil else { return nil }
        return "SHA256:" + Data(SHA256.hash(data: k)).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }

    /// Why a community source's URL cannot be used (nil: it can).
    public static func urlProblem(_ s: String, guarded: Bool) -> String? {
        guard let u = URL(string: s), let scheme = u.scheme, u.host != nil else { return "\(s) is not a URL" }
        if scheme == "https" { return nil }
        if scheme == "http", guarded, u.host == "127.0.0.1" { return nil }
        return "a community catalogue is fetched over https"
    }

    /// A source's default name: its URL's host, made a name.
    public static func defaultName(_ url: String) -> String {
        let h = URL(string: url)?.host?.lowercased() ?? "source"
        var s = h.replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return String(s.prefix(32)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    // MARK: small files

    static func writeJSON<T: Encodable>(_ v: T, to url: URL) -> Bool {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        guard let d = try? enc.encode(v) else { return false }
        return RecipeCatalogueCache.write(d, to: url)
    }

    public static func checks(_ p: RecipeExtrasPaths) -> [RecipeCheckRecord] {
        (try? Data(contentsOf: p.checks)).flatMap { try? JSONDecoder().decode([RecipeCheckRecord].self, from: $0) } ?? []
    }

    /// Record a pass (the newest per id and level).
    @discardableResult
    public static func recordCheck(_ r: RecipeCheckRecord, _ p: RecipeExtrasPaths) -> Bool {
        var all = checks(p).filter { !($0.id == r.id && $0.level == r.level) }
        all.append(r)
        return writeJSON(all.sorted { ($0.id, $0.level) < ($1.id, $1.level) }, to: p.checks)
    }

    public static func trusted(_ p: RecipeExtrasPaths) -> [RecipeTrustRecord] {
        (try? Data(contentsOf: p.trusted)).flatMap { try? JSONDecoder().decode([RecipeTrustRecord].self, from: $0) } ?? []
    }

    public static func isTrusted(id: String, sha256: String, _ p: RecipeExtrasPaths) -> Bool {
        trusted(p).contains { $0.id == id && $0.sha256 == sha256 }
    }

    @discardableResult
    public static func trust(id: String, sha256: String, _ p: RecipeExtrasPaths, now: Date = Date()) -> Bool {
        var all = trusted(p).filter { !($0.id == id && $0.sha256 == sha256) }
        all.append(RecipeTrustRecord(id: id, sha256: sha256, date: Self.now(now)))
        return writeJSON(all, to: p.trusted)
    }

    public static func inUse(_ p: RecipeExtrasPaths) -> RecipeInUse? {
        (try? Data(contentsOf: p.inUseFile)).flatMap { try? JSONDecoder().decode(RecipeInUse.self, from: $0) }
    }

    public static func kept(_ p: RecipeExtrasPaths) -> [KeptRecipe] {
        ((try? FileManager.default.contentsOfDirectory(atPath: p.kept.path)) ?? []).filter { $0.hasSuffix(".json") }.sorted().compactMap {
            (try? Data(contentsOf: p.kept.appendingPathComponent($0))).flatMap { try? JSONDecoder().decode(KeptRecipe.self, from: $0) }
        }
    }

    /// Keep a removed recipe (its compiled document) so the sandboxes made from it keep working.
    @discardableResult
    public static func keep(id: String, origin: RecipeOrigin, document: Data, sha256: String, _ p: RecipeExtrasPaths, now: Date = Date()) -> Bool {
        writeJSON(KeptRecipe(origin: origin, id: id, sha256: sha256, removed: Self.now(now), document: String(decoding: document, as: UTF8.self)), to: p.kept(id))
    }

    /// The sha256 and the compiled document of a recipe in the snapshot.
    public static func snapshotEntry(id: String, _ p: RecipeExtrasPaths) -> (source: RecipeInUse.Source, file: RecipeInUse.File, document: Data)? {
        guard let u = inUse(p) else { return nil }
        for s in u.sources {
            if let f = s.files.first(where: { $0.id == id }), let d = try? Data(contentsOf: p.inUse.appendingPathComponent(f.file)) { return (s, f, d) }
        }
        return nil
    }

    // MARK: - what a person reads about one

    /// "your own recipe (~/.config/doz/recipes/mine/x.yaml)" / "a community recipe from NAME (URL, key SHA256:…, confirmed
    /// DATE)" / "Dozable's own recipe".
    public static func whose(_ r: AgentRecipe, _ p: RecipeExtrasPaths? = RecipeExtrasPaths.at()) -> String {
        switch r.origin.kind {
        case "mine":
            if r.published == false { return "your own recipe (removed — kept for the sandboxes made from it)" }
            return "your own recipe" + (p.map { " (" + DisplayPath.tilde($0.mine(r.id).path) + ")" } ?? "")
        case "community":
            let s = p.flatMap { p in CommunitySources.load(p).sources.first { $0.name == r.origin.source } }
            return "a community recipe from \(r.origin.source ?? "?")"
                + (s.map { " (\($0.url), key \($0.fingerprint), confirmed \($0.confirmed.prefix(10)))" } ?? " (its source was removed — kept for the sandboxes made from it)")
        default: return "Dozable's own recipe"
        }
    }

    /// What its bake installs and reaches, and what it may reach when it runs — inert lines.
    public static func bakeLines(_ r: AgentRecipe) -> [String] {
        let i = r.install
        var what = i.kind
        let pkgs = [i.package, i.platformPackage].compactMap { $0 }
        if !pkgs.isEmpty { what += " " + pkgs.joined(separator: " + ") }
        if let u = i.url { what += " " + u.replacingOccurrences(of: "{version}", with: i.pinned.version) }
        what += " \(i.pinned.version)" + (i.pinned.integrity.map { " (integrity \($0.prefix(18))…)" } ?? "")
        var lines = ["installs: \(what)"]
        let hosts = Array(Set((i.bakeHosts ?? []) + (i.extras ?? []).compactMap { URL(string: $0.url)?.host })).sorted()
        lines.append("its bake reaches: the base's package registries" + (hosts.isEmpty ? "" : " and " + hosts.joined(separator: ", ")))
        let model = (r.network.model.hosts ?? []).map(\.host)
        if !model.isEmpty {
            lines.append("it may reach: " + model.joined(separator: ", ") + " (its model)"
                         + (r.network.update.isEmpty ? "" : "; " + r.network.update.map(\.host).joined(separator: ", ") + " (to update itself, when allowed)"))
        }
        return lines
    }

    // MARK: - the snapshot

    /// What a rebuild did.
    public struct Rebuilt: Sendable {
        public var inUse: RecipeInUse
        /// Community serials promoted (name → serial).
        public var promoted: [String: Int] = [:]
    }

    /// Rebuild the snapshot from your files, the confirmed community sources' caches and the kept recipes. `compile`:
    /// a YAML recipe's text → its compiled JSON (the CLI's `RecipeSource.compile`). `promote`: a community `next.json`
    /// becomes `current.json` (a host's start, or a `doz recipe` command with no host running).
    @discardableResult
    public static func rebuild(_ p: RecipeExtrasPaths, compile: (String) throws -> Data, version: String, promote: Bool,
                               env: [String: String] = ProcessInfo.processInfo.environment, now: Date = Date()) -> Rebuilt {
        var u = RecipeInUse(chosen: Self.now(now), doz: version)
        var out = Rebuilt(inUse: u)
        var documents: [String: Data] = [:]
        var seen = Set<String>()
        // Yours — each file its own source.
        for id in p.mineIDs() {
            let url = p.mine(id)
            guard let bytes = try? Data(contentsOf: url) else { continue }
            let name = "yours: \(id).yaml"
            do {
                let compiled = try compile(String(decoding: bytes, as: UTF8.self))
                let doc = try RecipeDocument.decode(compiled)
                let rid = String(doc.id.split(separator: "/").last ?? "")
                guard rid == id else { throw SandboxError.invalidSpec("the file is \(id).yaml but the recipe is \(rid)") }
                let file = "mine-\(id).json"
                documents[file] = compiled
                seen.insert(id)
                u.sources.append(.init(origin: .mine, name: name, published: true, serial: nil,
                                       files: [.init(id: id, file: file, sha256: sha256(bytes))]))
            } catch {
                u.refused.append(.init(origin: .mine, name: name, why: RecipeCatalogue.reason(error)))
            }
        }
        // Community — in the order added, each catalogue one source (chosen here, placed after the kept ones below).
        let guarded = TestSafety.guarded(env)
        var community: [RecipeInUse.Source] = []
        for s in CommunitySources.load(p).sources {
            let origin = RecipeOrigin.community(s.name)
            switch communityChoice(s, p, version: version, promote: promote, guarded: guarded, now: now) {
            case .none: continue
            case .refused(let why):
                u.refused.append(.init(origin: origin, name: "community \(s.name)", why: why))
            case .use(let m, let files, let promoted):
                if promoted { out.promoted[s.name] = m.serial }
                var entries: [RecipeInUse.File] = []
                for f in m.files {
                    let id = String(f.path.dropFirst("agents/".count).dropLast(".json".count))
                    let file = "community-\(s.name)-\(id).json"
                    documents[file] = files[f.path]
                    entries.append(.init(id: id, file: file, sha256: f.sha256))
                }
                community.append(.init(origin: origin, name: "community \(s.name)", published: true, serial: m.serial, files: entries))
            }
        }
        // Kept — removed recipes, unpublished — BEFORE the community sources: a kept id stays the sandboxes' (another
        // source offering it is refused, never put under an existing sandbox). Only its own origin back takes it again
        // (yours re-added, or the same source offering it).
        for k in kept(p) {
            if k.origin.isMine, seen.contains(k.id) { continue }
            if community.contains(where: { $0.origin == k.origin && $0.files.contains { $0.id == k.id } }) { continue }
            let file = "kept-\(k.id).json"
            documents[file] = Data(k.document.utf8)
            u.sources.append(.init(origin: k.origin, name: "kept \(k.id)", published: false, serial: nil,
                                   files: [.init(id: k.id, file: file, sha256: k.sha256)]))
        }
        u.sources += community
        out.inUse = u
        writeSnapshot(u, documents: documents, p)
        return out
    }

    /// The snapshot written whole: a new folder beside it, then swapped in by renames.
    static func writeSnapshot(_ u: RecipeInUse, documents: [String: Data], _ p: RecipeExtrasPaths) {
        let fm = FileManager.default
        try? fm.createDirectory(at: p.dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let tmp = p.dir.appendingPathComponent(".in-use.\(getpid())", isDirectory: true)
        try? fm.removeItem(at: tmp)
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for (name, d) in documents { _ = fm.createFile(atPath: tmp.appendingPathComponent(name).path, contents: d, attributes: [.posixPermissions: 0o600]) }
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        _ = fm.createFile(atPath: tmp.appendingPathComponent("in-use.json").path, contents: (try? enc.encode(u)) ?? Data(),
                          attributes: [.posixPermissions: 0o600])
        let old = p.dir.appendingPathComponent(".in-use.old.\(getpid())", isDirectory: true)
        try? fm.removeItem(at: old)
        if fm.fileExists(atPath: p.inUse.path) { _ = rename(p.inUse.path, old.path) }
        if rename(tmp.path, p.inUse.path) != 0, fm.fileExists(atPath: old.path) { _ = rename(old.path, p.inUse.path) }
        try? fm.removeItem(at: old)
        try? fm.removeItem(at: tmp)
    }

    enum CommunityChoice {
        case none
        case refused(String)
        case use(RecipeCatalogueManifest, [String: Data], promoted: Bool)
    }

    /// A source's catalogue to use: its waiting `next.json` (when promoting and newer), else `current.json` — signed with
    /// ITS key, a community catalogue, readable by this doz, every file present with its sha256.
    static func communityChoice(_ s: CommunitySource, _ p: RecipeExtrasPaths, version: String, promote: Bool, guarded: Bool, now: Date) -> CommunityChoice {
        let cache = p.community(s.name)
        var state = cache.state
        var said: String?
        defer { if let said { _ = state.record(said, now: now); state.save(cache.stateURL) } }
        let current = cache.current
        if promote, let (m, _) = cache.manifest(cache.nextURL) {
            if let why = manifestProblem(m, s, version: version) ?? (m.serial <= (current?.serial ?? 0) ? "serial \(m.serial) is not newer than \(current?.serial ?? 0)" : nil) {
                try? FileManager.default.removeItem(at: cache.nextURL)
                state.refusedSerials = Array(Set((state.refusedSerials ?? []) + [m.serial])).sorted()
                said = "catalogue \(m.serial) was ignored: \(why)"
            } else if let files = RecipeCatalogueCache.readFiles(m, from: cache.filesDir(serial: m.serial)), m.filesProblem(files) == nil {
                if rename(cache.nextURL.path, cache.currentURL.path) == 0 {
                    cache.prune(keeping: [m.serial])
                    state.problem = nil
                    return .use(m, files, promoted: true)
                }
            }
        }
        guard let m = cache.current else { return .none }
        if let why = manifestProblem(m, s, version: version) { said = "catalogue \(m.serial) was ignored: \(why)"; return .refused(said!) }
        guard let files = RecipeCatalogueCache.readFiles(m, from: cache.filesDir(serial: m.serial)) else { return .refused("catalogue \(m.serial): a file it names is missing") }
        if let why = m.filesProblem(files) { return .refused("catalogue \(m.serial): \(why)") }
        return .use(m, files, promoted: false)
    }

    /// Why this doz may not use a community catalogue (nil: it may).
    public static func manifestProblem(_ m: RecipeCatalogueManifest, _ s: CommunitySource, version: String) -> String? {
        do { try m.check(community: true) } catch { return RecipeCatalogue.reason(error) }
        guard let key = Data(base64Encoded: s.key), m.verify(publicKey: key, community: true) else { return "its signature does not verify with \(s.name)'s key" }
        if SemVer.compare(m.minimumDoz, version) == .orderedDescending { return "it needs doz \(m.minimumDoz) or later (this is \(version))" }
        return nil
    }

    // MARK: - the choice, at a process's start

    /// What this process adopted (doctor, `doz recipe ls`).
    nonisolated(unsafe) public static var startOutcomes: [RecipeCatalogue.ExtraOutcome] = []
    /// What the snapshot refused before adoption.
    nonisolated(unsafe) public static var startRefused: [RecipeInUse.Refusal] = []

    /// `DozableEntry`'s second step (after Dozable's own set, before the seal): a host's start rebuilds the snapshot; every
    /// process adopts it.
    @discardableResult
    public static func chooseAtStart(args: [String], version: String, compile: (String) throws -> Data,
                                     env: [String: String] = ProcessInfo.processInfo.environment) -> [RecipeCatalogue.ExtraOutcome] {
        guard let p = RecipeExtrasPaths.at(env) else { return [] }
        if RecipeCatalogueSelection.isHostStart(args) { rebuild(p, compile: compile, version: version, promote: true, env: env) }
        return adopt(p)
    }

    /// Adopt the snapshot (`RecipeCatalogue.adoptExtras`).
    @discardableResult
    public static func adopt(_ p: RecipeExtrasPaths) -> [RecipeCatalogue.ExtraOutcome] {
        guard let u = inUse(p) else { return [] }
        startRefused = u.refused
        let sources = u.sources.map { s in
            RecipeCatalogue.ExtraSource(origin: s.origin, name: s.name, documents: s.files.compactMap { f in
                (try? Data(contentsOf: p.inUse.appendingPathComponent(f.file))).map { (name: "\(f.id).json", data: $0) }
            }, published: s.published)
        }
        guard !sources.isEmpty else { return [] }
        startOutcomes = RecipeCatalogue.adoptExtras(sources)
        return startOutcomes
    }

    /// The `doz doctor` line (nil: nothing that is not Dozable's).
    public static func describe() -> String? {
        let o = startOutcomes, refused = startRefused
        guard !o.isEmpty || !refused.isEmpty else { return nil }
        let mine = o.filter { $0.origin.isMine && $0.refused == nil && $0.published }.flatMap(\.ids)
        let community = o.filter { $0.origin.isCommunity && $0.refused == nil }
        var parts: [String] = []
        if !mine.isEmpty { parts.append("yours: " + mine.joined(separator: ", ")) }
        for c in community { parts.append("community \(c.origin.source ?? "?"): \(c.ids.joined(separator: ", "))") }
        let kept = o.filter { !$0.published && $0.refused == nil }.flatMap(\.ids)
        if !kept.isEmpty { parts.append("kept for their sandboxes: " + kept.joined(separator: ", ")) }
        let problems = o.compactMap { x in x.refused.map { "\(x.name) refused: \($0)" } } + refused.map { "\($0.name) refused: \($0.why)" }
        parts += problems
        return parts.joined(separator: " · ")
    }

    /// Whether anything in the settings dir differs from the snapshot (a change that waits for the next host start).
    public static func pending(_ p: RecipeExtrasPaths) -> Bool {
        let u = inUse(p)
        let inSnapshot = Set((u?.sources ?? []).filter { $0.origin.isMine && $0.published }.flatMap { $0.files.map { "\($0.id) \($0.sha256)" } })
        let onDisk = Set(p.mineIDs().compactMap { id in (try? Data(contentsOf: p.mine(id))).map { "\(id) \(sha256($0))" } })
        let refusedMine = Set((u?.refused ?? []).filter(\.origin.isMine).map(\.name))
        let unseen = onDisk.subtracting(inSnapshot).filter { !refusedMine.contains("yours: \($0.split(separator: " ")[0]).yaml") }
        if !unseen.isEmpty || !inSnapshot.subtracting(onDisk).isEmpty { return true }
        let sourcesNow = Set(CommunitySources.load(p).sources.filter { p.community($0.name).current != nil || p.community($0.name).next != nil }.map(\.name))
        let sourcesUsed = Set((u?.sources ?? []).compactMap { $0.origin.isCommunity && $0.published ? $0.origin.source : nil } + (u?.refused ?? []).compactMap { $0.origin.isCommunity ? $0.origin.source : nil })
        if sourcesNow != sourcesUsed { return true }
        return CommunitySources.load(p).sources.contains { p.community($0.name).next != nil }
    }
}

// MARK: - the community refresh

/// A community source's look for a newer catalogue — 652's refresh, for one source: its URL, ITS key, its cache.
public enum CommunityRefresh {
    public static let interval: TimeInterval = 3600

    public static func refresh(_ s: CommunitySource, _ p: RecipeExtrasPaths, version: String,
                               env: [String: String] = ProcessInfo.processInfo.environment, now: Date = Date(), force: Bool = false,
                               fetch: UpdateFetch = UpdateChecker.urlSessionFetch) async -> RecipeCatalogueRefresh.Outcome {
        let guarded = TestSafety.guarded(env)
        if let why = RecipeExtras.urlProblem(s.url, guarded: guarded) { return .disabled(why) }
        guard let url = URL(string: s.url) else { return .disabled("not a URL") }
        let cache = p.community(s.name)
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
            let said = state.record("catalogue ignored: \(RecipeCatalogue.reason(error))", now: now)
            return .refused(state.problem ?? "", reportNow: said)
        }
        let have = max(current?.serial ?? 0, next?.serial ?? 0)
        guard m.serial > have, !(state.refusedSerials ?? []).contains(m.serial) else {
            state.etag = resp.value(forHTTPHeaderField: "ETag")
            state.lastModified = resp.value(forHTTPHeaderField: "Last-Modified")
            return .unchanged
        }
        if let why = RecipeExtras.manifestProblem(m, s, version: version) {
            let said = state.record("catalogue \(m.serial) was ignored: \(why)", now: now)
            return .refused(state.problem ?? why, reportNow: said)
        }
        let tmp = cache.dir.appendingPathComponent("files/.tmp-\(m.serial)-\(getpid())", isDirectory: true)
        try? FileManager.default.removeItem(at: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        for f in m.files {
            guard let fu = URL(string: m.base + f.path, relativeTo: url)?.absoluteURL, fu.scheme == url.scheme, fu.host == url.host else { return .offline }
            var r = URLRequest(url: fu)
            r.setValue("doz/\(version)", forHTTPHeaderField: "User-Agent")
            let d: Data
            do {
                let (data, h) = try await fetch(r)
                guard h.statusCode == 200 else { return .offline }
                d = data
            } catch { return .offline }
            guard d.count == f.size, RecipeCatalogueManifest.sha256(d) == f.sha256 else {
                state.refusedSerials = Array(Set((state.refusedSerials ?? []) + [m.serial])).sorted()
                let said = state.record("catalogue \(m.serial) was ignored: \(f.path) does not match its sha256", now: now)
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

    /// Every confirmed source, in the order added (the host's hourly loop).
    public static func refreshAll(version: String, env: [String: String] = ProcessInfo.processInfo.environment) async -> [(String, RecipeCatalogueRefresh.Outcome)] {
        guard let p = RecipeExtrasPaths.at(env) else { return [] }
        var out: [(String, RecipeCatalogueRefresh.Outcome)] = []
        for s in CommunitySources.load(p).sources { out.append((s.name, await refresh(s, p, version: version, env: env))) }
        return out
    }
}
