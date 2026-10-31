import Foundation

/// 618 (owner: "go with B and one card … make sure there is a way the user can chose an earlier major version"; the first
/// real case of 617.B5's qualified names): what a person types to name a tool —
///
///   · `NAME`            the tool; for a family (`opencode`), its RECOMMENDED major — a pin Dozable checked, never "latest";
///   · `NAME@MAJOR`      that major (`opencode@1`): the family's recipe of that major (any tool: its own major only);
///   · `NAME@VERSION`    an exact release (`opencode@2.0.28`) of the major it belongs to.
///
/// NAME is a recipe's id or alias, or a family's name. Only what a person TYPES goes through here (try/new/create/up, a
/// project file's `agent:`, the web plan, search) — a stored name never does: a sandbox, an image, a setting and a
/// statistics id keep the recipe's own id, so an existing sandbox never changes major. `@` qualifies only a tool's
/// name (`NAME:PATH` stays `doz get/put/cp`'s).
///
/// 654 (617.B5, owner: "like a Docker image reference"): the same name may say whose recipe it is —
///
///   · `VENDOR/PRODUCT[@…]`          Dozable's recipe (`anthropic/claude-code`, `anomalyco/opencode@1`);
///   · `SOURCE/VENDOR/PRODUCT[@…]`   SOURCE `dozable`, `mine` (your own) or a community source's name.
///
/// PRODUCT is the recipe's id or its family's name (never an alias: the short names are the top-level list). The rest
/// resolves exactly as above; the qualification only CONFIRMS — ids are unique, so it never chooses between recipes — and
/// a vendor or source that is not the recipe's is refused with the name that does mean it. A first part with a dot is a
/// directory host: not served yet (doz.sh, a later step), and no digest either.
public struct AgentRef: Equatable, Sendable {
    /// The recipe a create uses.
    public var recipe: AgentRecipe
    /// An exact release asked for (nil: the version the agent's setting gives — latest within its major, or exact).
    public var exact: String?
    /// The name as resolved: the family's name for a family member, else the recipe's id.
    public var name: String
    /// What was asked for after `@` (nil: none).
    public var qualifier: String?
    /// 654: what came before the name when it was qualified — `anthropic`, `mine/acme`, `dozable/anomalyco` (nil: a plain name).
    public var prefix: String? = nil

    public var family: AgentRecipe.Family? { recipe.family }
    /// "opencode", "opencode@1", "opencode@2.0.28" — 654: with its qualification as typed ("anomalyco/opencode@1").
    public var text: String { (prefix.map { $0 + "/" } ?? "") + bare }
    /// The name without its qualification ("opencode@1").
    public var bare: String { qualifier.map { "\(name)@\($0)" } ?? name }
    /// What a file written for later records (a plan's doz_project.yaml, `doz init`, New Sandbox): a family's name keeps
    /// the major it resolved to (`opencode` → `opencode@2`), so the file never changes major when the recommendation
    /// moves; a member's own id becomes the family's name (`opencode2` → `opencode@2`). Anything else: `text`. 654: a
    /// qualified name keeps its qualification (`anomalyco/opencode` → `anomalyco/opencode@2`).
    public var pinned: String {
        guard let f = family else { return text }
        return (prefix.map { $0 + "/" } ?? "") + "\(name)@\(qualifier ?? String(f.major))"
    }

    /// A reference that cannot be served — said with the choices there are.
    public struct Problem: Error, Equatable, CustomStringConvertible {
        public var description: String
    }

    /// The leading number of a release (`2.0.29` → 2, `0.160.1` → 0).
    public static func major(of version: String) -> Int? {
        let d = version.prefix { $0.isNumber }
        guard !d.isEmpty, d.count <= 6 else { return nil }
        return Int(d)
    }

    static let versionPattern = "^[0-9]{1,6}(\\.[0-9]{1,9}){1,3}([-+][0-9A-Za-z.-]{1,40})?$"

    /// `NAME@…` split (nil: not a tool reference's shape).
    public static func split(_ s: String) -> (name: String, qualifier: String?)? {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        guard !t.isEmpty, t.count <= 80 else { return nil }
        let parts = t.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard let n = parts.first, n.range(of: "^[a-z0-9][a-z0-9-]{0,39}$", options: .regularExpression) != nil else { return nil }
        if parts.count == 1 { return (n, nil) }
        let q = parts[1]
        guard !q.isEmpty else { return nil }
        return (n, q)
    }

    /// The majors of a family, oldest first.
    public static func members(_ family: String, in recipes: [AgentRecipe] = AgentRecipes.all) -> [AgentRecipe] {
        recipes.filter { $0.family?.family == family }.sorted { $0.family!.major < $1.family!.major }
    }

    /// The recommended major of a family (nil: not a family).
    public static func recommended(_ family: String, in recipes: [AgentRecipe] = AgentRecipes.all) -> AgentRecipe? {
        members(family, in: recipes).first { $0.family!.isRecommended }
    }

    /// What `s` names — nil when it names no tool at all (a base, a template, `none`: the caller's), a Problem when it
    /// names one that cannot be served as asked. 629: an unpublished recipe is a Problem — only typed input comes here
    /// (a NEW sandbox's tool), never a stored name, so an existing sandbox of it keeps working.
    public static func resolve(_ s: String, in recipes: [AgentRecipe] = AgentRecipes.all) throws -> AgentRef? {
        guard let ref = try resolveAny(s, in: recipes) else { return nil }
        if let p = AgentRecipes.unpublishedProblem(ref.recipe) { throw Problem(description: p) }
        return ref
    }

    /// `resolve` without the 629 refusal — only to say WHY a typed name is refused, never to serve one.
    public static func resolveAny(_ s: String, in recipes: [AgentRecipe]) throws -> AgentRef? {
        if s.contains("/") { return try resolveQualified(s, in: recipes) }
        guard let (name, q) = split(s) else {
            if s.contains("@") { throw Problem(description: "\(s) is not a tool's name — NAME, NAME@MAJOR (opencode@1) or NAME@VERSION (opencode@2.0.28)") }
            return nil
        }
        let family = members(name, in: recipes)
        let base: AgentRecipe
        let shown: String
        if !family.isEmpty {
            shown = name
            if let q, let m = Int(q), q.allSatisfy(\.isNumber) {
                guard let r = family.first(where: { $0.family!.major == m }) else { throw Self.noMajor(name, q, family) }
                return AgentRef(recipe: r, exact: nil, name: name, qualifier: q)
            }
            base = family.first { $0.family!.isRecommended } ?? family.last!
        } else {
            let k = name
            guard let r = recipes.first(where: { $0.id == k || ($0.aliases ?? []).contains(k) }) else {
                if q != nil { throw Problem(description: "no tool is named \(name) (doz search \(name))") }
                return nil
            }
            base = r
            shown = r.family?.family ?? r.id
            if r.family != nil, q == nil {
                // A member named by its own id (`opencode2`) is that major — never the family's recommended one.
                return AgentRef(recipe: r, exact: nil, name: shown, qualifier: "\(r.family!.major)")
            }
            if let q, q.allSatisfy(\.isNumber) {
                guard let m = Int(q), m == major(of: r.install.pinned.version) else {
                    throw Problem(description: "\(name) has only \(name)@\(major(of: r.install.pinned.version).map(String.init) ?? "?") — not @\(q)")
                }
                return AgentRef(recipe: r, exact: nil, name: shown, qualifier: q)
            }
        }
        guard let q else { return AgentRef(recipe: base, exact: nil, name: shown, qualifier: nil) }
        guard q.range(of: versionPattern, options: .regularExpression) != nil, let m = major(of: q) else {
            throw Problem(description: "\(name)@\(q): after @ comes a major (\(name)@1) or a release (\(name)@\(base.install.pinned.version))")
        }
        let r: AgentRecipe
        if !family.isEmpty {
            guard let x = family.first(where: { $0.family!.major == m }) else { throw Self.noMajor(name, q, family) }
            r = x
        } else {
            guard major(of: base.install.pinned.version) == m else {
                throw Problem(description: "\(base.title) \(q) is not a release Dozable installs — its recipe is for \(name)@\(major(of: base.install.pinned.version) ?? 0)")
            }
            r = base
        }
        if r.isPinnedOnly, q != r.install.pinned.version {
            throw Problem(description: "\(r.title) is installed at the release its recipe pins (\(r.install.pinned.version)) — not \(q)")
        }
        return AgentRef(recipe: r, exact: q, name: shown, qualifier: q)
    }

    // MARK: 654 — qualified names

    /// The longest qualified reference taken (a source, a vendor, a product and a release, with room).
    public static let maxQualifiedLength = 160

    /// A vendor's slug: lower-case letters, digits and dashes, starting and ending with a letter or digit (the recipe
    /// file's `VENDOR/`), at most 40.
    public static func isVendor(_ s: String) -> Bool {
        s.count <= 40 && s.range(of: "^[a-z0-9]([a-z0-9-]*[a-z0-9])?$", options: .regularExpression) != nil
    }

    /// The parts of a qualified reference (nil: not that shape). `source` nil: none typed.
    public struct Qualified: Equatable, Sendable {
        public var source: String?
        /// 670: the directory host typed in front (`doz.sh`) — Dozable's own directory, so `source` is `dozable` then.
        public var host: String?
        public var vendor: String
        public var product: String
        public var qualifier: String?
        /// What came before the product as typed (`anthropic`, `mine/acme`).
        public var prefix: String { ((host ?? source).map { $0 + "/" } ?? "") + vendor }
    }

    static let grammarHelp = "VENDOR/PRODUCT (anthropic/claude-code) or SOURCE/VENDOR/PRODUCT (mine/acme/tool), each with @MAJOR or @VERSION if you like"

    /// `[SOURCE/]VENDOR/PRODUCT[@…]` split and checked, each refusal in its own words.
    public static func parseQualified(_ s: String) throws -> Qualified {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        guard t.count <= maxQualifiedLength else { throw Problem(description: "\(s.prefix(40))… is longer than a tool's name can be (\(maxQualifiedLength) characters)") }
        let at = t.firstIndex(of: "@")
        let path = at.map { String(t[..<$0]) } ?? t
        let q = at.map { String(t[t.index(after: $0)...]) }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        // 670: `doz.sh/VENDOR/PRODUCT` is Dozable's directory — the same as `dozable/VENDOR/PRODUCT` and `VENDOR/PRODUCT`.
        // It names a recipe this doz already has; nothing is fetched. No other host is a recipe directory.
        var host: String?
        if let first = parts.first, first.contains(".") {
            guard first == RecipeOrigin.directoryHost else {
                throw Problem(description: "\(s): only \(RecipeOrigin.directoryHost) is a recipe directory — add a community catalogue with `doz recipe source add` and name it by its source (\(grammarHelp))")
            }
            guard parts.count == 3 else {
                throw Problem(description: "\(s): a name in \(RecipeOrigin.directoryHost) is \(RecipeOrigin.directoryHost)/VENDOR/PRODUCT (\(RecipeOrigin.directoryHost)/anthropic/claude-code), each with @MAJOR or @VERSION if you like")
            }
            host = first
        }
        if let q, q.hasPrefix("sha256:") || q.hasPrefix("sha512:") {
            throw Problem(description: "\(s): a digest is not a way to name a tool here — after @ comes a major or a release")
        }
        if path.contains(":") || (q?.contains(":") ?? false) {
            throw Problem(description: "\(s): after a tool's name comes @ (\(path.split(separator: ":").first.map(String.init) ?? path)@2), never : — NAME:PATH is doz get, put and cp's")
        }
        guard (2...3).contains(parts.count) else { throw Problem(description: "\(s) is not a tool's name — \(grammarHelp)") }
        let source = host != nil ? "dozable" : (parts.count == 3 ? parts[0] : nil)
        let vendor = parts[parts.count - 2], product = parts[parts.count - 1]
        if let source, !RecipeOrigin.isSourceName(source) { throw Problem(description: "\(s): \(source.isEmpty ? "an empty source" : source) is not a recipe source — dozable, mine or a community source's name (doz recipe source ls)") }
        guard isVendor(vendor) else { throw Problem(description: "\(s): \(vendor.isEmpty ? "an empty vendor" : vendor) is not a vendor's name — lower-case letters, digits and dashes (\(grammarHelp))") }
        guard product.range(of: "^[a-z0-9][a-z0-9-]{0,39}$", options: .regularExpression) != nil else {
            throw Problem(description: "\(s): \(product.isEmpty ? "no product" : product) is not a tool's name — \(grammarHelp)")
        }
        if let q, q.isEmpty { throw Problem(description: "\(s): nothing after @ — a major (\(path)@1) or a release") }
        if let q, q.contains("/") || q.contains("@") { throw Problem(description: "\(s): after @ comes a major (\(path)@1) or a release, once") }
        return Qualified(source: source, host: host, vendor: vendor, product: product, qualifier: q)
    }

    /// `[SOURCE/]VENDOR/PRODUCT[@…]` → the recipe, through `resolveAny`'s own NAME[@…] rules; the qualification must be
    /// the recipe's (its vendor, its origin — `dozable` when no source is typed).
    static func resolveQualified(_ s: String, in recipes: [AgentRecipe]) throws -> AgentRef? {
        let p = try parseQualified(s)
        let at = p.qualifier.map { "@" + $0 } ?? ""
        let ofVendor = recipes.filter { $0.vendor == p.vendor }
        // The product: a recipe's own id or a family's name (an alias is a short name, not a product).
        guard ofVendor.contains(where: { $0.id == p.product || $0.family?.family == p.product }) else {
            if let other = recipes.first(where: { $0.id == p.product || $0.family?.family == p.product }) {
                throw Problem(description: "\(s): \(p.product) is not \(p.vendor)'s — its name is \(qualifiedName(other, product: p.product))\(at)")
            }
            if let r = recipes.first(where: { ($0.aliases ?? []).contains(p.product) }) {
                throw Problem(description: "\(s): \(p.product) is a short name (doz try \(p.product)) — with its vendor it is \(qualifiedName(r))\(at)")
            }
            if ofVendor.isEmpty { throw Problem(description: "\(s): no tool here is \(p.vendor)'s (doz search lists every tool with its full name)") }
            let names = ofVendor.filter { $0.family.map(\.isRecommended) ?? true }.map { qualifiedName($0, product: $0.family?.family ?? $0.id) }
            throw Problem(description: "\(s): \(p.vendor) has no tool called \(p.product) — \(p.vendor)'s: \(names.sorted().joined(separator: ", "))")
        }
        guard var ref = try resolveAny(p.product + at, in: recipes) else { return nil }
        let r = ref.recipe
        // A family's majors share one vendor (validated), so this holds; said plainly should a recipe set ever differ.
        guard r.vendor == p.vendor else { throw Problem(description: "\(s): \(r.title) is \(r.vendor ?? "no vendor")'s — \(qualifiedName(r))\(at)") }
        let want = p.source ?? "dozable"
        guard want == r.origin.sourceWord else {
            let whose = r.origin.isDozable ? "Dozable's" : (r.origin.label ?? r.origin.kind)
            throw Problem(description: "\(s): \(r.title) is \(whose) — \(qualifiedName(r, product: p.product))\(at)")
        }
        ref.prefix = p.prefix
        return ref
    }

    /// A recipe's qualified name — the one that means exactly it when typed: `VENDOR/` + `typed(r)` for Dozable's
    /// (`anthropic/claude-code`, `anomalyco/opencode` for the recommended major, `anomalyco/opencode@1` for another), with
    /// its source first for any other (`mine/acme/tool`, `NAME/vendor/tool`). `product`: that name instead of `typed(r)`
    /// (a refusal says the name as it was typed). No vendor (a test's recipe): the name alone.
    public static func qualifiedName(_ r: AgentRecipe, product: String? = nil) -> String {
        let n = product ?? typed(r)
        guard let v = r.vendor else { return n }
        return r.origin.isDozable ? "\(v)/\(n)" : "\(r.origin.sourceWord)/\(v)/\(n)"
    }

    /// The reference a sandbox records (display only): always with its source, and the release when known —
    /// `dozable/anomalyco/opencode@2.0.29` (a family's name with the release, as `recorded`), `dozable/anthropic/claude-code`.
    public static func fullyQualified(_ r: AgentRecipe, version: String? = nil) -> String {
        let src = r.vendor.map { "\(r.origin.sourceWord)/\($0)/" } ?? ""
        guard let v = version?.split(separator: "+").first.map(String.init), !v.isEmpty else { return src + typed(r) }
        return src + "\(r.family?.family ?? r.id)@\(v)"
    }

    static func noMajor(_ name: String, _ q: String, _ family: [AgentRecipe]) -> Problem {
        let have = family.map { "\(name)@\($0.family!.major)" + ($0.family!.isRecommended ? " (recommended)" : "") }
        return Problem(description: "\(name) has \(have.joined(separator: " and ")) — not @\(q)")
    }

    /// The name that means exactly `recipe` when typed: a family's name for its recommended major, `family@major` for any
    /// other (its id alone would be the family's), else its id.
    public static func typed(_ recipe: AgentRecipe) -> String {
        guard let f = recipe.family else { return recipe.id }
        return f.isRecommended ? f.family : "\(f.family)@\(f.major)"
    }

    /// What a sandbox records: `opencode@2.0.29` — the family's (or tool's) name and the exact release it was made with.
    public static func recorded(_ recipe: AgentRecipe, version: String?) -> String {
        let n = recipe.family?.family ?? recipe.id
        guard let v = version?.split(separator: "+").first.map(String.init), !v.isEmpty else { return n }
        return "\(n)@\(v)"
    }

    /// "OpenCode 2 (recommended; also @1)" — how a family's choice reads in a list.
    public static func choicesLine(_ recipe: AgentRecipe, in recipes: [AgentRecipe] = AgentRecipes.all) -> String? {
        guard let f = recipe.family else { return nil }
        let others = members(f.family, in: recipes).filter { $0.id != recipe.id }.map { "@\($0.family!.major)" }
        let head = f.isRecommended ? "recommended" : "@\(f.major)"
        return others.isEmpty ? head : "\(head); also \(others.joined(separator: ", "))"
    }
}
