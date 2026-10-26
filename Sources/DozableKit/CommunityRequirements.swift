import Foundation

// 653 (owner: "allow the end-user to create their own with the option to verify as meeting the minimum requirements
// for a community recipe") — the MINIMUM REQUIREMENTS for a recipe that is not Dozable's: a closed list, checked in a
// fixed order, each with the words a person reads. They are the bar for every non-Dozable recipe at the static level:
// one that fails any is never adopted (`RecipeCatalogue.adoptExtras`), and `doz recipe check` prints them item by item.
// The FULL check (a real build and try) is `doz recipe check --full` — the CLI's, not this file's.

public enum CommunityRequirements {
    /// One requirement's outcome.
    public struct Result: Codable, Equatable, Sendable {
        public var id: String
        /// The requirement, in a person's words.
        public var title: String
        public var passed: Bool
        /// Why it failed (nil when it passed).
        public var detail: String?
    }

    /// The closed list, in order: id → what it requires.
    public static let items: [(id: String, title: String)] = [
        ("document", "a schema 2 recipe, read strictly (no unknown key; its derived parts as Dozable derives them)"),
        ("validators", "every rule Dozable's own recipes pass (its own, and among all recipes: ids, aliases, model permissions)"),
        ("not-dozable", "its id and aliases are none of Dozable's recipes"),
        ("not-builtin", "not a built-in agent (Dozable's own installer)"),
        ("about", "author, sourceUrl (https), licenses and description filled in"),
        ("pinned", "every download pinned with its integrity, installed at exactly that release"),
        ("guide", "a guide (guide@1) and a check turn (launch@1.check)"),
        ("no-credential", "no credential named: no variable a credential lives in, no key-shaped value"),
        ("no-quiet", "no quiet hosts (they would hide a refusal from you)"),
        ("reach-shown", "it reaches the network only through permissions you see (no hidden vendor hosts)"),
        ("no-mark", "no mark from Dozable's icon registry"),
        ("no-family", "not part of a family of majors"),
    ]

    /// A recipe's document bytes (compiled JSON) checked against the list. `others`: the recipes it must live beside (the
    /// set in use, less any earlier copy of this recipe); `dozableIDs`: every id and alias of Dozable's set.
    /// Returns every item's result and, when the document reads, the recipe.
    public static func check(_ data: Data, others: [AgentRecipe], dozableIDs: Set<String>) -> (results: [Result], recipe: AgentRecipe?) {
        var out: [String: Result] = [:]
        func set(_ id: String, _ ok: Bool, _ why: String? = nil) {
            let t = items.first { $0.id == id }!.title
            out[id] = Result(id: id, title: t, passed: ok, detail: ok ? nil : why)
        }
        let doc: RecipeDocument, r: AgentRecipe
        do {
            doc = try RecipeDocument.decode(data)
            r = try doc.recipe()
            set("document", true)
        } catch {
            set("document", false, RecipeCatalogue.reason(error))
            let results = items.map { i in out[i.id] ?? Result(id: i.id, title: i.title, passed: false, detail: "not checked — the recipe does not read") }
            return (results, nil)
        }
        let names = Set([r.id] + (r.aliases ?? []))
        // validators — its own rules, then the rules among recipes (beside the others, never against a copy of itself)
        do {
            try r.validate()
            try AgentRecipes.validate(others.filter { Set([$0.id] + ($0.aliases ?? [])).isDisjoint(with: names) } + [r])
            set("validators", true)
        } catch { set("validators", false, RecipeCatalogue.reason(error)) }
        let clash = names.intersection(dozableIDs).sorted()
        set("not-dozable", clash.isEmpty, "\(clash.joined(separator: ", ")) is Dozable's — choose another id")
        set("not-builtin", !r.isBuiltin && r.install.kind != "builtin", "a built-in agent is Dozable's own")
        // about
        var missing: [String] = []
        func filled(_ s: String) -> Bool { !s.trimmingCharacters(in: .whitespaces).isEmpty && s.range(of: "todo", options: .caseInsensitive) == nil }
        if !filled(doc.author) { missing.append("author") }
        if !filled(doc.sourceUrl) || !doc.sourceUrl.hasPrefix("https://") { missing.append("sourceUrl (https)") }
        if doc.licenses.isEmpty || !doc.licenses.allSatisfy(filled) { missing.append("licenses") }
        if !filled(doc.description) { missing.append("description") }
        if !filled(doc.displayName) { missing.append("displayName") }
        set("about", missing.isEmpty, "fill in " + missing.joined(separator: ", "))
        // pinned
        var loose: [String] = []
        if r.install.pinned.version.lowercased() == "latest" { loose.append("its version is latest") }
        if (r.install.pinned.integrity ?? "").isEmpty { loose.append("no integrity") }
        for e in r.install.extras ?? [] where e.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) == nil {
            loose.append("extra \(e.url) has no sha256")
        }
        set("pinned", loose.isEmpty, loose.joined(separator: "; "))
        var guideMissing: [String] = []
        if r.guide == nil { guideMissing.append("a guide (guide@1)") }
        if r.smoke == nil { guideMissing.append("a check turn (launch@1.check)") }
        set("guide", guideMissing.isEmpty, "add " + guideMissing.joined(separator: " and "))
        // no-credential
        let named = credentialNamed(r)
        let shaped = keyShaped(data)
        let credWhy = (named.isEmpty ? [] : ["it sets \(named.joined(separator: ", "))"]) + (shaped.map { ["a key-shaped value (\($0))"] } ?? [])
        set("no-credential", named.isEmpty && shaped == nil, credWhy.joined(separator: "; "))
        let quiet = (r.network.quiet ?? []).map(\.host)
        set("no-quiet", quiet.isEmpty, "quiet: \(quiet.joined(separator: ", "))")
        let vendor = (r.network.vendor ?? []).map(\.host)
        set("reach-shown", vendor.isEmpty, "vendor hosts are a hidden permission: \(vendor.joined(separator: ", ")) — put what it needs in its model or update hosts")
        set("no-mark", r.icon == nil, "icon \(r.icon ?? "") is from Dozable's registry — leave it out (a lettermark is drawn)")
        set("no-family", r.family == nil, "family@1 is Dozable's for now — leave it out")
        return (items.map { out[$0.id]! }, r)
    }

    /// The verdict line.
    public static func verdict(_ results: [Result]) -> String {
        let failed = results.filter { !$0.passed }.count
        return failed == 0 ? "meets the minimum requirements for a community recipe"
                           : "does not meet the minimum requirements for a community recipe: \(failed) of \(results.count) failed"
    }

    /// The first failure, as one line (what an adoption's refusal says).
    public static func firstFailure(_ results: [Result]) -> String? {
        results.first { !$0.passed }.map { "\($0.id): \($0.detail ?? $0.title)" }
    }

    /// Variables the recipe SETS whose names are a credential's (where it reads the placeholder — `key_env`,
    /// `env_aliases` — is a different thing, and allowed).
    static func credentialNamed(_ r: AgentRecipe) -> [String] {
        var keys = Set(r.launch.env.keys).union(r.state.env.keys).union((r.launch.sessionEnv ?? [:]).keys).union((r.launch.noPromptsEnv ?? [:]).keys)
        for o in r.network.offWithout ?? [] { keys.formUnion(o.env.keys) }
        for e in (r.models?.shapes ?? []).map(\.env) + (r.models?.native ?? []).map(\.env) { keys.formUnion(e.keys) }
        for f in r.launch.firstRun ?? [] where f.file.hasSuffix("/.env") { keys.formUnion(f.set.keys) }
        return keys.filter(BakeEnvironment.isCredential).sorted()
    }

    /// Shapes of real keys (and of Dozable's own placeholders) — never in a recipe.
    static let keyPatterns = [
        #"sk-(ant-|proj-|or-v1-)?[A-Za-z0-9_-]{20,}"#, #"xai-[A-Za-z0-9]{20,}"#, #"AIza[0-9A-Za-z_-]{30,}"#,
        #"gh[pousr]_[A-Za-z0-9]{20,}"#, #"github_pat_[A-Za-z0-9_]{20,}"#, #"vck_[A-Za-z0-9]{20,}"#, #"AKIA[0-9A-Z]{16}"#,
        #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#, #"doz_cred_[A-Za-z0-9_-]+"#,
    ]

    /// The first key-shaped value in the document's text, shortened (nil: none).
    static func keyShaped(_ data: Data) -> String? {
        let s = String(decoding: data, as: UTF8.self)
        for p in keyPatterns {
            if let r = s.range(of: p, options: .regularExpression) { return String(s[r].prefix(8)) + "…" }
        }
        return nil
    }
}
