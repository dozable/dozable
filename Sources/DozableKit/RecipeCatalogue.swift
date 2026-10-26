import CryptoKit
import Foundation

// The recipe catalogue — Dozable's recipe data as signed data of its own, beside the update feed:
//
//     https://updates.dozable.com/v1/recipes.json          (the /v1/ is the FORMAT; a new format is /v2/ beside it)
//     https://updates.dozable.com/v1/recipes/<serial>/…    (the files it names; a new serial is a new folder)
//
//     { "format": 1, "product": "doz-recipes", "serial": 3, "date": "2026-10-26T12:00:00Z",
//       "minimum_doz": "0.37.24", "source_version": "0.37.24", "base": "recipes/3/",
//       "files": [ { "path": "agents/grok.json", "sha256": "…", "size": 2210 }, … ],
//       "signature": "<base64 Ed25519>" }
//
// · ONE signature, with Dozable's update key (`Distribution.updatePublicKey` — no other key), over a DOMAIN-SEPARATED
//   message (`RecipeCatalogueManifest.message`: "dozable-recipe-catalogue-v1\n" + the fields + one line per file). A
//   feed entry's message starts "dozer-sandbox update v1\n": neither signature can ever verify as the other.
// · A process uses ONE recipe set, chosen once at its start (DozableHost's `RecipeCatalogueSelection` decides;
//   `DozableEntry` installs it before anything reads a recipe, then seals it). Nothing is ever swapped under a running
//   process: a new catalogue applies from the next start.
// · A catalogue ADDS or UPDATES (recipes, providers, keyless sources, gateways, tags, kinds, categories, known entries,
//   icons — by id); it never removes what this build has, so every stored name keeps resolving. The built-in three
//   (Claude Code, pi, Codex) are ALWAYS this build's: a catalogue's copy of one is ignored, a new `builtin` refuses it.
// · It is checked as the embedded set is: the merged set must pass every validator, or the WHOLE catalogue is ignored.
// · DozableKit never reads the settings or the network for it: the bytes are handed in.

/// Computed once, on first use, under its own lock (a throwing initialiser keeps its error).
final class Once<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<T, Error>?
    private let make: () throws -> T

    init(_ make: @escaping () throws -> T) { self.make = make }
    init(value: T) {
        self.make = { value }
        self.value = .success(value)
    }

    func get() throws -> T {
        lock.lock(); defer { lock.unlock() }
        if let v = value { return try v.get() }
        let r = Result { try make() }
        value = r
        return try r.get()
    }
}

/// Where a process's recipes came from.
public struct RecipeSource: Codable, Equatable, Sendable {
    /// `embedded` | `catalogue`.
    public var kind: String
    public var serial: Int?
    /// The catalogue's date (ISO 8601).
    public var date: String?
    /// The VERSION of the tree the catalogue was made from.
    public var sourceVersion: String?

    public static let embedded = RecipeSource(kind: "embedded")

    public init(kind: String, serial: Int? = nil, date: String? = nil, sourceVersion: String? = nil) {
        self.kind = kind
        self.serial = serial
        self.date = date
        self.sourceVersion = sourceVersion
    }

    public var isEmbedded: Bool { kind == "embedded" }

    /// "embedded (doz 0.37.24)" or "catalogue 3 from 2026-10-26 (made from 0.37.25)".
    public func describe(dozVersion: String) -> String {
        guard !isEmbedded, let serial else { return "embedded (doz \(dozVersion))" }
        return "catalogue \(serial)" + (date.map { " from \($0.prefix(10))" } ?? "") + (sourceVersion.map { " (made from \($0))" } ?? "")
    }
}

/// One recipe set: its parts, each decoded once. The embedded set decodes lazily (as the compiled-in data always did);
/// a catalogue's set is a MERGE over it, checked before it is used.
public final class RecipeSet: @unchecked Sendable {
    public let source: RecipeSource
    let recipesPart: Once<[AgentRecipe]>
    let providersPart: Once<KeyProviders.File>
    let gatewaysPart: Once<[Gateway]>
    let capabilityTagsPart: Once<[CapabilityTag]>
    let categoriesPart: Once<Categories.File>
    let knownPart: Once<[KnownThing]>
    let iconsPart: Once<[IconEntry]>
    let iconFilesPart: Once<[String: [UInt8]]>

    init(source: RecipeSource, recipes: Once<[AgentRecipe]>, providers: Once<KeyProviders.File>, gateways: Once<[Gateway]>,
         capabilityTags: Once<[CapabilityTag]>, categories: Once<Categories.File>, known: Once<[KnownThing]>,
         icons: Once<[IconEntry]>, iconFiles: Once<[String: [UInt8]]>) {
        self.source = source
        recipesPart = recipes
        providersPart = providers
        gatewaysPart = gateways
        capabilityTagsPart = capabilityTags
        categoriesPart = categories
        knownPart = known
        iconsPart = icons
        iconFilesPart = iconFiles
    }

    /// The compiled-in set — what every process uses unless a catalogue was chosen at its start.
    public static let embedded = RecipeSet(
        source: .embedded,
        recipes: Once(AgentRecipes.embedded), providers: Once(KeyProviders.embeddedFile), gateways: Once(Gateways.embedded),
        capabilityTags: Once(CapabilityTags.embedded), categories: Once(Categories.embeddedFile), known: Once(KnownThings.embedded),
        icons: Once(AgentIcons.embedded), iconFiles: Once(value: AgentIcons.embeddedFiles))

    // A part that failed to build is refused before the set is ever used (`RecipeCatalogue.adopt` validates it whole),
    // so these never fail on a set in use — the embedded set's own decoders stop the process, as they always did.
    private static func use<T>(_ o: Once<T>, _ what: String) -> T {
        do { return try o.get() } catch { fatalError("recipe set: \(what) did not build: \(error)") }
    }
    var recipes: [AgentRecipe] { Self.use(recipesPart, "recipes") }
    var providers: KeyProviders.File { Self.use(providersPart, "providers") }
    var gateways: [Gateway] { Self.use(gatewaysPart, "gateways") }
    var capabilityTags: [CapabilityTag] { Self.use(capabilityTagsPart, "tags") }
    var categories: Categories.File { Self.use(categoriesPart, "kinds and categories") }
    var known: [KnownThing] { Self.use(knownPart, "known entries") }
    var icons: [IconEntry] { Self.use(iconsPart, "icons") }
    var iconFiles: [String: [UInt8]] { Self.use(iconFilesPart, "icon files") }
}

/// The catalogue's signed manifest (`v1/recipes.json`).
public struct RecipeCatalogueManifest: Codable, Equatable, Sendable {
    public struct File: Codable, Equatable, Sendable {
        public var path: String
        public var sha256: String
        public var size: Int
        public init(path: String, sha256: String, size: Int) {
            self.path = path
            self.sha256 = sha256
            self.size = size
        }
    }

    public var format: Int
    public var product: String
    public var serial: Int
    public var date: String
    public var minimumDoz: String
    public var sourceVersion: String
    public var base: String
    public var files: [File]
    public var signature: String

    enum CodingKeys: String, CodingKey {
        case format, product, serial, date, base, files, signature
        case minimumDoz = "minimum_doz", sourceVersion = "source_version"
    }

    public static let currentFormat = 1
    public static let productName = "doz-recipes"
    /// What the signed message starts with — a feed entry's starts "dozer-sandbox update v1\n".
    public static let messagePrefix = "dozable-recipe-catalogue-v1\n"
    public static let maxManifestBytes = 256 << 10
    public static let maxFileBytes = 1 << 20
    public static let maxTotalBytes = 8 << 20
    public static let maxFiles = 400
    /// The data files a catalogue must carry (plus at least one agent).
    public static let requiredFiles = ["gateways.json", "icons/icons.json", "known.json", "providers.json", "tags.json"]
    static let pathPattern = #"^(agents/[a-z0-9][a-z0-9-]*\.json|providers\.json|gateways\.json|tags\.json|known\.json|icons/icons\.json|icons/[a-z0-9-]+\.svg)$"#
    static let versionPattern = #"^\d{1,3}\.\d{1,3}\.\d{1,4}(-[0-9A-Za-z][0-9A-Za-z.]{0,19})?$"#

    public init(format: Int = currentFormat, product: String = productName, serial: Int, date: String, minimumDoz: String,
                sourceVersion: String, base: String? = nil, files: [File], signature: String = "") {
        self.format = format
        self.product = product
        self.serial = serial
        self.date = date
        self.minimumDoz = minimumDoz
        self.sourceVersion = sourceVersion
        self.base = base ?? "recipes/\(serial)/"
        self.files = files
        self.signature = signature
    }

    /// From its JSON — strictly: a key this build does not know is refused (a new field is a new format).
    public static func decode(_ data: Data) throws -> RecipeCatalogueManifest {
        guard data.count <= maxManifestBytes else { throw SandboxError.invalidSpec("the catalogue is larger than \(maxManifestBytes >> 10) KiB") }
        let m: RecipeCatalogueManifest
        do { m = try JSONDecoder().decode(RecipeCatalogueManifest.self, from: data) } catch {
            throw SandboxError.invalidSpec("the catalogue is not the JSON doz expects")
        }
        if let unknown = AgentRecipes.unknownKey(try JSONSerialization.jsonObject(with: data),
                                                 try JSONSerialization.jsonObject(with: JSONEncoder().encode(m)), path: "") {
            throw SandboxError.invalidSpec("the catalogue has a field this doz does not know (\(unknown)) — a newer doz reads it")
        }
        return m
    }

    /// 653: a COMMUNITY catalogue's product — the same format, signed with its publisher's own key, carrying recipes only.
    /// A Dozable catalogue is never read as a community one, nor the other way round.
    public static let communityProductName = "doz-community-recipes"
    static let communityPathPattern = #"^agents/[a-z0-9][a-z0-9-]*\.json$"#

    /// Its shape, before anything else is believed: the format, the closed set of paths (sorted, once each), digests,
    /// sizes and limits, the required files. 653: `community` — a community catalogue's: its own product, `agents/` only.
    public func check(community: Bool = false) throws {
        func bad(_ s: String) -> Error { SandboxError.invalidSpec("the catalogue: \(s)") }
        let wantProduct = community ? Self.communityProductName : Self.productName
        guard format == Self.currentFormat else { throw bad("format \(format) — this doz reads format \(Self.currentFormat)") }
        guard product == wantProduct else { throw bad("it is for \(product), not \(wantProduct)") }
        guard serial >= 1 else { throw bad("serial \(serial)") }
        guard date.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$"#, options: .regularExpression) != nil else { throw bad("date is not ISO 8601 UTC") }
        for v in [minimumDoz, sourceVersion] where v.range(of: Self.versionPattern, options: .regularExpression) == nil {
            throw bad("\(v) is not a version")
        }
        guard base == "recipes/\(serial)/" else { throw bad("base is recipes/\(serial)/") }
        guard !files.isEmpty, files.count <= Self.maxFiles else { throw bad("1 to \(Self.maxFiles) files") }
        guard files.map(\.path) == files.map(\.path).sorted(), Set(files.map(\.path)).count == files.count else {
            throw bad("its files are sorted by path, each once")
        }
        var total = 0
        for f in files {
            guard f.path.range(of: community ? Self.communityPathPattern : Self.pathPattern, options: .regularExpression) != nil else {
                throw bad("\(f.path) is not a recipe data file" + (community ? " (a community catalogue carries agents/<id>.json only)" : ""))
            }
            guard f.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else { throw bad("\(f.path): sha256 is 64 lower-case hex") }
            guard f.size > 0, f.size <= Self.maxFileBytes else { throw bad("\(f.path): size 1 B to \(Self.maxFileBytes >> 10) KiB") }
            total += f.size
        }
        guard total <= Self.maxTotalBytes else { throw bad("over \(Self.maxTotalBytes >> 20) MiB in all") }
        let paths = Set(files.map(\.path))
        if !community { for r in Self.requiredFiles where !paths.contains(r) { throw bad("no \(r)") } }
        guard paths.contains(where: { $0.hasPrefix("agents/") }) else { throw bad("no agent") }
    }

    /// The bytes the signature covers (`Scripts/recipe-catalogue.py` writes the same).
    public var message: Data {
        var s = Self.messagePrefix
        s += "format: \(format)\nproduct: \(product)\nserial: \(serial)\ndate: \(date)\nminimum_doz: \(minimumDoz)\n"
        s += "source_version: \(sourceVersion)\nbase: \(base)\n"
        for f in files { s += "file: \(f.path) \(f.sha256) \(f.size)\n" }
        return Data(s.utf8)
    }

    /// Well formed AND signed by `publicKey` (a 32-byte Ed25519 key). 653: `community` — as a community catalogue.
    public func verify(publicKey: Data, community: Bool = false) -> Bool {
        guard (try? check(community: community)) != nil, let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey),
              let sig = Data(base64Encoded: signature), sig.count == 64 else { return false }
        return key.isValidSignature(sig, for: message)
    }

    /// Every file named, with its size and sha256 — nil when one is missing or differs (said).
    public func filesProblem(_ files: [String: Data]) -> String? {
        for f in self.files {
            guard let d = files[f.path] else { return "\(f.path) is missing" }
            guard d.count == f.size, Self.sha256(d) == f.sha256 else { return "\(f.path) does not match its sha256" }
        }
        if let extra = Set(files.keys).subtracting(self.files.map(\.path)).sorted().first { return "\(extra) is not in the catalogue" }
        return nil
    }

    public static func sha256(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    public var source: RecipeSource { RecipeSource(kind: "catalogue", serial: serial, date: date, sourceVersion: sourceVersion) }
}

public enum RecipeCatalogue {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _active: RecipeSet?
    nonisolated(unsafe) private static var _sealed = false
    nonisolated(unsafe) private static var _generation = 0

    /// The recipe set this process uses: the embedded one, or the catalogue chosen at its start.
    public static var active: RecipeSet {
        lock.lock(); defer { lock.unlock() }
        return _active ?? .embedded
    }

    public static var source: RecipeSource { active.source }

    /// Bumped by every set installed (in a shipped process: at most once, at its start).
    static var generation: Int {
        lock.lock(); defer { lock.unlock() }
        return _generation
    }

    private static func install(_ s: RecipeSet?) {
        lock.lock()
        _active = s
        _generation += 1
        lock.unlock()
    }

    /// At a process's START only, before anything has read a recipe: use this catalogue — its files checked against the
    /// manifest, MERGED over the embedded set, and the result checked by every validator the embedded set passes. On any
    /// failure nothing changes (the embedded set stays) and the reason is thrown. The signature, the minimum doz and the
    /// floor are the caller's (DozableHost: the key and this doz's version live there).
    @discardableResult
    public static func adopt(_ manifest: RecipeCatalogueManifest, files: [String: Data]) throws -> RecipeSource {
        lock.lock()
        let sealed = _sealed, chosen = _active != nil
        lock.unlock()
        precondition(!sealed, "the recipe set is chosen once, at the start — never swapped under a running process")
        guard !chosen else { throw SandboxError.invalidSpec("a recipe catalogue was already chosen for this process") }
        try manifest.check()
        if let p = manifest.filesProblem(files) { throw SandboxError.invalidSpec("the catalogue: \(p)") }
        let candidate = try merged(manifest, files: files)
        install(candidate)
        do {
            // Built here, with the candidate active (a recipe's derived parts read its providers); a part that fails
            // is the catalogue's refusal, never a stop.
            _ = try candidate.recipesPart.get()
            _ = try candidate.knownPart.get()
            try validateActive()
        } catch {
            install(nil)
            throw error
        }
        return candidate.source
    }

    /// An error as one plain sentence (a check's own words, not the enum's).
    public static func reason(_ e: Error) -> String {
        if case SandboxError.invalidSpec(let s) = e { return s }
        if let d = e as? DecodingError {
            // 653: where — a person fixing their own recipe needs the field.
            func at(_ c: DecodingError.Context) -> String {
                let path = c.codingPath.map { $0.intValue.map { "[\($0)]" } ?? "." + $0.stringValue }.joined().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                return path.isEmpty ? "" : " (at \(path))"
            }
            switch d {
            case .keyNotFound(let k, let c): return "it is not the JSON this doz reads: \(k.stringValue) is missing\(at(c))"
            case .typeMismatch(_, let c), .valueNotFound(_, let c), .dataCorrupted(let c): return "it is not the JSON this doz reads\(at(c))"
            @unknown default: return "it is not the JSON this doz reads"
            }
        }
        return e.localizedDescription
    }

    // MARK: - 653: recipes that are not Dozable's

    /// One source of non-Dozable recipes, adopted whole or not at all: one of the person's own files, a community
    /// catalogue, or a recipe kept after its removal (unpublished — `published: false` — so its sandboxes keep working).
    public struct ExtraSource: Sendable {
        public var origin: RecipeOrigin
        /// What it is called when it is refused ("yours: mytool.yaml", "community example").
        public var name: String
        /// Each recipe's compiled document (`agents/<id>.json` / a YAML compiled), by the name it came under.
        public var documents: [(name: String, data: Data)]
        /// false: kept after removal — adopted unpublished (offered nowhere; every stored name still resolves).
        public var published: Bool
        public init(origin: RecipeOrigin, name: String, documents: [(name: String, data: Data)], published: Bool = true) {
            self.origin = origin; self.name = name; self.documents = documents; self.published = published
        }
    }

    /// What became of one extra source.
    public struct ExtraOutcome: Codable, Equatable, Sendable {
        public var origin: RecipeOrigin
        public var name: String
        /// The recipe ids adopted (empty when refused).
        public var ids: [String]
        public var published: Bool
        /// Why the whole source was refused (nil: adopted).
        public var refused: String?
    }

    nonisolated(unsafe) private static var _extras: [ExtraOutcome] = []

    /// What `adoptExtras` did in this process.
    public static var extras: [ExtraOutcome] {
        lock.lock(); defer { lock.unlock() }
        return _extras
    }

    /// Every id and alias of Dozable's own recipes in the active set (embedded, or merged with Dozable's catalogue).
    public static var dozableNames: Set<String> {
        Set(active.recipes.filter(\.origin.isDozable).flatMap { [$0.id] + ($0.aliases ?? []) })
    }

    /// At a process's START, after Dozable's set is chosen and before `seal()`: add the recipes that are not Dozable's,
    /// source by source, in the order given (yours, then each community source in the order it was added, then the kept
    /// ones). Each source is adopted WHOLE or not at all: every recipe must meet the community requirements, no id or alias
    /// may be Dozable's or an earlier source's, and the set with it must pass every validator — else the previous set
    /// stays and the source is refused, with the reason. Only recipes are added: providers, gateways, tags, known entries'
    /// vocabulary and marks stay Dozable's.
    @discardableResult
    public static func adoptExtras(_ sources: [ExtraSource]) -> [ExtraOutcome] {
        lock.lock()
        let sealed = _sealed
        lock.unlock()
        precondition(!sealed, "the recipe set is chosen once, at the start — never swapped under a running process")
        var outcomes: [ExtraOutcome] = []
        let dozable = dozableNames
        for s in sources {
            let before = active
            var taken = Set(before.recipes.flatMap { [$0.id] + ($0.aliases ?? []) })
            var adopted: [AgentRecipe] = []
            var refusal: String?
            for (name, data) in s.documents {
                let (results, recipe) = CommunityRequirements.check(data, others: before.recipes + adopted, dozableIDs: dozable)
                if let f = CommunityRequirements.firstFailure(results) { refusal = "\(name): \(f)"; break }
                guard var r = recipe else { refusal = "\(name): it does not read"; break }
                let names = [r.id] + (r.aliases ?? [])
                if let n = names.first(where: taken.contains) { refusal = "\(name): \(n) is already another recipe's (\(owner(of: n, in: before.recipes + adopted)))"; break }
                taken.formUnion(names)
                r.origin = s.origin
                if !s.published { r.published = false }
                adopted.append(r)
            }
            if refusal == nil, !adopted.isEmpty {
                let names = Set(adopted.flatMap { [$0.id] + ($0.aliases ?? []) })
                let recipes = before.recipes + adopted
                let known = before.known.filter { !names.contains($0.id) && !($0.aliases ?? []).contains(where: names.contains) }
                let candidate = RecipeSet(source: before.source, recipes: Once(value: recipes), providers: before.providersPart,
                                          gateways: before.gatewaysPart, capabilityTags: before.capabilityTagsPart,
                                          categories: before.categoriesPart, known: Once(value: known), icons: before.iconsPart,
                                          iconFiles: before.iconFilesPart)
                install(candidate)
                do { try validateActive() } catch {
                    install(before === RecipeSet.embedded ? nil : before)
                    refusal = reason(error)
                }
            }
            outcomes.append(ExtraOutcome(origin: s.origin, name: s.name, ids: refusal == nil ? adopted.map(\.id) : [],
                                         published: s.published, refused: refusal))
        }
        lock.lock()
        _extras = outcomes
        lock.unlock()
        return outcomes
    }

    /// "Dozable's", "yours", "community NAME" — who has a name.
    static func owner(of name: String, in recipes: [AgentRecipe]) -> String {
        guard let r = recipes.first(where: { $0.id == name || ($0.aliases ?? []).contains(name) }) else { return "another source's" }
        return r.origin.label ?? "Dozable's"
    }

    /// After the choice: no other set, for the life of the process.
    public static func seal() {
        lock.lock()
        _sealed = true
        lock.unlock()
    }

    /// TEST SEAM: back to the embedded set, unsealed (like `registerForTests`, no environment variable reaches it).
    public static func resetForTests() {
        lock.lock()
        _sealed = false
        _extras = []
        lock.unlock()
        install(nil)
    }

    /// Every check the embedded set passes (its tests run these same validators on it).
    public static func validateActive() throws {
        let recipes = AgentRecipes.all
        try AgentRecipes.validate(recipes)
        try KeyProviders.validate(KeyProviders.all)
        try KeyProviders.validate(keyless: KeyProviders.keyless, providers: KeyProviders.all)
        try Gateways.validate(Gateways.all)
        try CapabilityTags.validate(CapabilityTags.all)
        try Categories.validate()
        try KnownThings.validate(KnownThings.all, recipes: recipes)
        try AgentIcons.validate(AgentIcons.all, files: AgentIcons.files)
        // The built-in three are this build's, unchanged.
        let builtins = RecipeSet.embedded.recipes.filter(\.isBuiltin).map(\.id)
        guard recipes.filter(\.isBuiltin).map(\.id) == builtins else {
            throw SandboxError.invalidSpec("the catalogue changes the built-in agents (\(builtins.joined(separator: ", ")))")
        }
    }

    // MARK: - the merge

    /// tags.json as a whole (the capability tags and the kinds and categories share it).
    struct TagsFile: Codable { var schema: Int; var tags: [CapabilityTag]; var kinds: [CatalogWord]; var categories: [CatalogWord] }

    /// `base` with `over`'s entry for every id they share, then `over`'s new ones in their order.
    static func mergeByID<T>(_ base: [T], _ over: [T], id: (T) -> String) -> [T] {
        let overIDs = Dictionary(over.map { (id($0), $0) }, uniquingKeysWith: { a, _ in a })
        let baseIDs = Set(base.map(id))
        return base.map { overIDs[id($0)] ?? $0 } + over.filter { !baseIDs.contains(id($0)) }
    }

    /// A catalogue file decoded STRICTLY: a key this build does not know is refused (it needs a newer doz).
    static func strict<T: Codable>(_ type: T.Type, _ data: Data?, _ path: String) throws -> T {
        guard let data else { throw SandboxError.invalidSpec("the catalogue has no \(path)") }
        do {
            let v = try JSONDecoder().decode(T.self, from: data)
            if let unknown = AgentRecipes.unknownKey(try JSONSerialization.jsonObject(with: data),
                                                     try JSONSerialization.jsonObject(with: JSONEncoder().encode(v)), path: "") {
                throw SandboxError.invalidSpec("unknown key \(unknown) — a newer doz reads it")
            }
            return v
        } catch let e as SandboxError { throw SandboxError.invalidSpec("\(path): \(reason(e))") } catch {
            throw SandboxError.invalidSpec("\(path) does not decode: \(reason(error))")
        }
    }

    /// The candidate set: every part merged over the embedded one's (read here, while the embedded set is active).
    /// Its recipes and known entries are built lazily — with the candidate active, so a recipe's derived parts use the
    /// candidate's providers — and `adopt` forces them through the validators before the set is used.
    static func merged(_ m: RecipeCatalogueManifest, files: [String: Data]) throws -> RecipeSet {
        let e = RecipeSet.embedded
        let eRecipes = e.recipes, eProviders = e.providers, eGateways = e.gateways, eTags = e.capabilityTags
        let eCategories = e.categories, eKnown = e.known, eIcons = e.icons, eIconFiles = e.iconFiles

        let p = try strict(KeyProviders.File.self, files["providers.json"], "providers.json")
        guard p.schema == eProviders.schema else { throw SandboxError.invalidSpec("providers.json: schema \(p.schema) — this doz reads \(eProviders.schema)") }
        let keyless = mergeByID(eProviders.keyless ?? [], p.keyless ?? [], id: \.id)
        let providers = KeyProviders.File(schema: p.schema, providers: mergeByID(eProviders.providers, p.providers, id: \.id),
                                          keyless: keyless.isEmpty && eProviders.keyless == nil ? nil : keyless)
        let g = try strict(Gateways.File.self, files["gateways.json"], "gateways.json")
        let t = try strict(TagsFile.self, files["tags.json"], "tags.json")
        let k = try strict(KnownThings.File.self, files["known.json"], "known.json")
        for (what, schema) in [("gateways.json", g.schema), ("tags.json", t.schema), ("known.json", k.schema)] where schema != 1 {
            throw SandboxError.invalidSpec("\(what): schema \(schema) — this doz reads 1")
        }
        let categories = Categories.File(schema: t.schema, kinds: mergeByID(eCategories.kinds, t.kinds, id: \.id),
                                         categories: mergeByID(eCategories.categories, t.categories, id: \.id))

        // Icons: the catalogue's entries and files; this build's other entries keep their own files.
        guard let iconsJSON = files["icons/icons.json"] else { throw SandboxError.invalidSpec("the catalogue has no icons/icons.json") }
        let catIcons: [IconEntry]
        do { catIcons = try AgentIcons.decodeManifest(iconsJSON) } catch { throw SandboxError.invalidSpec("icons/icons.json: \(reason(error))") }
        let catIconIDs = Set(catIcons.map(\.id))
        let icons = mergeByID(eIcons, catIcons, id: \.id)
        var iconFiles: [String: [UInt8]] = [:]
        for i in icons where !catIconIDs.contains(i.id) {
            for f in [i.variants.mono, i.variants.color, i.variants.colorDark].compactMap({ $0 }) { iconFiles[f] = eIconFiles[f] }
        }
        for (path, d) in files where path.hasPrefix("icons/") && path.hasSuffix(".svg") {
            iconFiles[String(path.dropFirst("icons/".count))] = [UInt8](d)
        }

        // Recipes: the built-in three stay this build's; every other is the catalogue's when it has one.
        let builtinIDs = Set(eRecipes.filter(\.isBuiltin).map(\.id))
        let agentFiles = files.filter { $0.key.hasPrefix("agents/") }.sorted { $0.key < $1.key }
        let recipes = Once<[AgentRecipe]> {
            var fromCatalogue: [AgentRecipe] = []
            for (path, bytes) in agentFiles {
                let r: AgentRecipe
                do { r = try RecipeDocument.decode(bytes).recipe() } catch { throw SandboxError.invalidSpec("\(path): \(reason(error))") }
                guard path == "agents/\(r.id).json" else { throw SandboxError.invalidSpec("\(path) holds the recipe \(r.id)") }
                if builtinIDs.contains(r.id) { continue }            // never replaced from a catalogue
                if r.isBuiltin { throw SandboxError.invalidSpec("\(path): a catalogue cannot add a built-in agent") }
                fromCatalogue.append(r)
            }
            return mergeByID(eRecipes, fromCatalogue, id: \.id)
        }
        // Known entries: merged; one whose id (or alias) a recipe now has is dropped — the recipe wins.
        let known = Once<[KnownThing]> {
            let all = try recipes.get()
            let ids = Set(all.map(\.id) + all.flatMap { $0.aliases ?? [] })
            return mergeByID(eKnown, k.known, id: \.id).filter { !ids.contains($0.id) && !($0.aliases ?? []).contains(where: ids.contains) }
        }
        return RecipeSet(source: m.source, recipes: recipes, providers: Once(value: providers),
                         gateways: Once(value: mergeByID(eGateways, g.gateways, id: \.id)),
                         capabilityTags: Once(value: mergeByID(eTags, t.tags, id: \.id)), categories: Once(value: categories),
                         known: known, icons: Once(value: icons), iconFiles: Once(value: iconFiles))
    }
}
