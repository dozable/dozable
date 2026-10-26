import ArgumentParser
import Darwin
import DozableHost
import DozableKit
import Foundation

// 653 — `doz recipe …`: your own recipes, the community catalogues you add, and the check of the minimum requirements for
// a community recipe. The files live in the settings dir (RecipeExtras.swift); YAML is read here only (Yams is the CLI's).
// Nothing is swapped under a running process: a change is in use at once when no host runs for the store, else from the
// next host start.

struct RecipeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "recipe",
        abstract: "Your own recipes and community catalogues: make one, check it against the minimum requirements for a community recipe, add a catalogue by its URL and key.",
        discussion: """
        A recipe is the YAML file that says how to install a tool, run it and what it may reach (the format: docs/recipes/RECIPE-FORMAT.md). \
        Yours live in the settings folder (recipes/mine/ID.yaml) and are labelled "yours" everywhere; a community catalogue's are labelled \
        with its name. Neither may use the name of one of Dozable's own recipes. A change is used at once when no host runs, else from the \
        next host start (doz host restart).
        """,
        subcommands: [RecipeList.self, RecipeNew.self, RecipeAdd.self, RecipeShow.self, RecipeCheck.self, RecipeTrust.self, RecipeRemove.self,
                      RecipeSourceCommand.self],
        defaultSubcommand: RecipeList.self)
}

// MARK: - shared

/// The schema line a recipe file starts with (editors check the file against it as you type).
let recipeSchemaURL = "https://raw.githubusercontent.com/\(Distribution.repository)/main/schema/dozable-recipe-2.schema.json"

func recipePaths(_ g: GlobalOptions) throws -> RecipeExtrasPaths {
    guard let p = RecipeExtrasPaths.at() else { throw fail(HostError(.failed, "no settings folder (set HOME or XDG_CONFIG_HOME)"), g) }
    return p
}

/// A recipe named on the command line: a YAML file, or the id of yours or of a community source's.
struct RecipeTarget {
    var id: String
    /// The bytes it came from (YAML for a file or yours; the compiled JSON for a community recipe).
    var bytes: Data
    var compiled: Data
    var origin: RecipeOrigin
    /// Where it is read from (shown with ~).
    var path: String?
    var sha256: String { RecipeExtras.sha256(bytes) }
}

func recipeTarget(_ s: String, _ p: RecipeExtrasPaths, _ g: GlobalOptions) throws -> RecipeTarget {
    let expanded = (s as NSString).expandingTildeInPath
    let isFile = s.contains("/") || s.hasSuffix(".yaml") || s.hasSuffix(".yml") || s.hasSuffix(".json")
    if isFile {
        guard let bytes = try? Data(contentsOf: URL(fileURLWithPath: expanded)) else { throw fail(HostError(.notFound, "\(s): no such file"), g) }
        guard bytes.count <= 256 << 10 else { throw fail(HostError(.invalid, "\(s) is larger than 256 KiB — not a recipe"), g) }
        let compiled = s.hasSuffix(".json") ? bytes : try compileRecipe(bytes, s, g)
        let id = (try? RecipeDocument.decode(compiled)).map { String($0.id.split(separator: "/").last ?? "") }
            ?? URL(fileURLWithPath: expanded).deletingPathExtension().lastPathComponent
        return RecipeTarget(id: id, bytes: bytes, compiled: compiled, origin: .mine, path: expanded)
    }
    if let bytes = try? Data(contentsOf: p.mine(s)) {
        return RecipeTarget(id: s, bytes: bytes, compiled: try compileRecipe(bytes, s, g), origin: .mine, path: p.mine(s).path)
    }
    if let e = RecipeExtras.snapshotEntry(id: s, p), e.source.origin.isCommunity {
        return RecipeTarget(id: s, bytes: e.document, compiled: e.document, origin: e.source.origin, path: nil)
    }
    if AgentRecipes.recipe(s)?.origin.isDozable == true {
        throw fail(HostError(.invalid, "\(s) is one of Dozable's own recipes — its checks are Dozable's (doz search \(s) --details shows it)"), g)
    }
    throw fail(HostError(.notFound, "no recipe of yours or of a community source called \(s) — doz recipe ls lists them"), g)
}

func compileRecipe(_ bytes: Data, _ name: String, _ g: GlobalOptions) throws -> Data {
    do { return try RecipeSource.compile(yaml: String(decoding: bytes, as: UTF8.self)) } catch {
        throw fail(HostError(.invalid, "\(name) is not a recipe's YAML: \(RecipeCatalogue.reason(error))"), g)
    }
}

/// The community requirements for `t`, beside the recipes in use (less any earlier copy of it).
func recipeStaticCheck(_ t: RecipeTarget) -> (results: [CommunityRequirements.Result], recipe: AgentRecipe?) {
    let others = AgentRecipes.all.filter { $0.origin.isDozable || $0.id != t.id }
    return CommunityRequirements.check(t.compiled, others: others, dozableIDs: RecipeCatalogue.dozableNames)
}

func printRequirements(_ results: [CommunityRequirements.Result]) {
    for r in results {
        Out.stdout("  \(r.passed ? "✓" : "✕") \(r.id) — \(r.title)" + (r.detail.map { "\n      \($0)" } ?? "") + "\n")
    }
}

/// After a change to your recipes or the sources: in use at once when no host runs for this store, else at its next start.
/// Returns the sentence to say.
@discardableResult
func applyRecipeChange(_ p: RecipeExtrasPaths, _ g: GlobalOptions) -> String {
    if g.dozableStore.hostIsRunning() {
        return "it applies at the next host start — doz host restart"
    }
    RecipeExtras.rebuild(p, compile: RecipeSource.compile, version: DozableCommand.version, promote: true)
    return "in use from now (a running doz ui shows it after doz ui restart)"
}

func recipeWhose(_ r: AgentRecipe, _ p: RecipeExtrasPaths?) -> String { RecipeExtras.whose(r, p) }
func recipeBakeLines(_ r: AgentRecipe) -> [String] { RecipeExtras.bakeLines(r) }

// MARK: - the trust question (community recipes, once per version)

/// The recipes this process has already said or asked about.
nonisolated(unsafe) var recipeTrustSaid = Set<String>()

/// Before a sandbox of a COMMUNITY recipe is made: say whose it is, what its bake installs and reaches, and ask — once per
/// recipe version (its sha256), remembered in `<settings>/recipes/trusted.json`. Your own recipes are said, never asked.
/// No terminal: refused, naming `doz recipe trust ID`.
func confirmRecipeTrust(image: String?, _ g: GlobalOptions) throws {
    guard let image, let r = ImageChoice.parse(DozableImages.canonicalName(image))?.agent.recipe, !r.origin.isDozable else { return }
    let p = RecipeExtrasPaths.at()
    guard recipeTrustSaid.insert(r.id).inserted else { return }
    if r.origin.isMine {
        if !g.json, !g.quiet { Out.stderr("[doz] \(r.title): \(recipeWhose(r, p))\n") }
        return
    }
    guard let p, let e = RecipeExtras.snapshotEntry(id: r.id, p) else { return }
    if RecipeExtras.isTrusted(id: r.id, sha256: e.file.sha256, p) { return }
    var lines = ["\(r.title) is \(recipeWhose(r, p)) — not Dozable's."] + recipeBakeLines(r).map { "  " + $0 }
    lines.append("  its bake runs under the bake policy: only the hosts above and its package registry")
    Out.stderr(lines.joined(separator: "\n") + "\n")
    guard isatty(STDIN_FILENO) == 1, isatty(STDERR_FILENO) == 1 else {
        throw fail(HostError(.failed, "\(r.id) is a community recipe you have not said yes to — read doz recipe show \(r.id), then doz recipe trust \(r.id)"),
                   g, code: DozableExit.declined)
    }
    try confirm("Use \(r.origin.source ?? "this source")'s recipe for \(r.id)?", yes: false, g)
    RecipeExtras.trust(id: r.id, sha256: e.file.sha256, p)
}

// MARK: - doz recipe ls

struct RecipeRow: Codable, Equatable {
    var id: String
    var title: String?
    /// `mine` | `community`.
    var origin: String
    var source: String?
    /// `in use` | `waits for the next host start` | `refused` | `removed — kept for its sandboxes`.
    var state: String
    var why: String?
    /// `full` | `static` | nil — a pass for the bytes in use.
    var checked: String?
    var changedSinceCheck: Bool?
    var sha256: String?
}

struct RecipeList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ls", abstract: "Your recipes and every community source's: where from, whether in use, whether checked.")
    @OptionGroup var g: GlobalOptions
    @Flag(name: .long, help: "Also the removed ones kept for the sandboxes made from them.") var all = false

    func run() async throws {
        let p = try recipePaths(g)
        let rows = Self.rows(p, all: all)
        if g.json { Out.json(rows); return }
        if rows.isEmpty {
            Out.stdout("No recipes of yours or from a community catalogue. doz recipe new ID makes one; doz recipe source add URL --key KEY adds a catalogue.\n")
            return
        }
        var table = [["ID", "FROM", "STATE", "CHECKED"]]
        for r in rows {
            let from = r.origin == "mine" ? "yours" : "community · \(r.source ?? "?")"
            let state = r.state + (r.why.map { ": \($0)" } ?? "")
            let checked = r.checked.map { $0 + (r.changedSinceCheck == true ? " (changed since)" : "") } ?? "—"
            table.append([r.id, from, state, checked])
        }
        Out.stdout(Out.table(table))
        if RecipeExtras.pending(p) { Out.stdout("A change waits for the next host start — doz host restart.\n") }
    }

    static func rows(_ p: RecipeExtrasPaths, all: Bool) -> [RecipeRow] {
        let outcomes = RecipeExtras.startOutcomes
        let u = RecipeExtras.inUse(p)
        let checks = RecipeExtras.checks(p)
        var out: [RecipeRow] = []
        func check(_ id: String, _ sha: String?) -> (String?, Bool?) {
            let mine = checks.filter { $0.id == id }
            guard !mine.isEmpty else { return (nil, nil) }
            if let c = mine.first(where: { $0.sha256 == sha && $0.level == "full" }) ?? mine.first(where: { $0.sha256 == sha }) { return (c.level, false) }
            return (mine.contains { $0.level == "full" } ? "full" : "static", true)
        }
        // Yours, as on disk.
        for id in p.mineIDs() {
            let bytes = try? Data(contentsOf: p.mine(id))
            let sha = bytes.map(RecipeExtras.sha256)
            let inSnap = u?.sources.first { $0.origin.isMine && $0.files.contains { $0.id == id } }
            let o = outcomes.first { $0.origin.isMine && ($0.ids.contains(id) || $0.name == "yours: \(id).yaml") }
            let snapRefused = u?.refused.first { $0.origin.isMine && $0.name == "yours: \(id).yaml" }
            var row = RecipeRow(id: id, title: AgentRecipes.recipe(id).flatMap { $0.origin.isMine ? $0.title : nil }, origin: "mine", source: nil,
                                state: "in use", why: nil, checked: nil, changedSinceCheck: nil, sha256: sha)
            if inSnap?.files.first(where: { $0.id == id })?.sha256 != sha, snapRefused == nil || u.map({ $0.chosen }) == nil {
                row.state = "waits for the next host start"
            }
            if let r = o?.refused ?? snapRefused?.why { row.state = "refused"; row.why = r }
            else if inSnap == nil && snapRefused == nil { row.state = "waits for the next host start" }
            (row.checked, row.changedSinceCheck) = check(id, sha)
            out.append(row)
        }
        // Community, as chosen.
        for s in u?.sources ?? [] where s.origin.isCommunity && s.published {
            let o = outcomes.first { $0.origin == s.origin }
            for f in s.files {
                var row = RecipeRow(id: f.id, title: AgentRecipes.recipe(f.id).flatMap { $0.origin == s.origin ? $0.title : nil }, origin: "community",
                                    source: s.origin.source, state: "in use", why: nil, checked: nil, changedSinceCheck: nil, sha256: f.sha256)
                if let r = o?.refused { row.state = "refused"; row.why = r }
                (row.checked, row.changedSinceCheck) = check(f.id, f.sha256)
                out.append(row)
            }
        }
        for r in u?.refused ?? [] where r.origin.isCommunity {
            out.append(RecipeRow(id: "—", title: nil, origin: "community", source: r.origin.source, state: "refused", why: r.why,
                                 checked: nil, changedSinceCheck: nil, sha256: nil))
        }
        if all {
            for s in u?.sources ?? [] where !s.published {
                for f in s.files {
                    let refused = outcomes.first { $0.name == s.name }?.refused
                    out.append(RecipeRow(id: f.id, title: nil, origin: s.origin.isCommunity ? "community" : "mine", source: s.origin.source,
                                         state: refused == nil ? "removed — kept for its sandboxes" : "refused", why: refused,
                                         checked: nil, changedSinceCheck: nil, sha256: f.sha256))
                }
            }
        }
        return out
    }
}

// MARK: - doz recipe new / add

struct RecipeNew: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "new",
        abstract: "Start a recipe of your own: a file to fill in (recipes/mine/ID.yaml), or a copy of one of Dozable's under a new name (--from).")
    @OptionGroup var g: GlobalOptions
    @Argument(help: "Its id: a-z, 0-9 and dashes, starting with a letter, at most 24 — and none of Dozable's (doz search lists them).") var id: String
    @Option(name: .long, help: "Copy this published Dozable recipe (an id) — renamed; its maker, link and description left for you to fill in.") var from: String?
    @Flag(name: .long, help: "Replace a recipe of yours with that id.") var force = false

    func run() async throws {
        let p = try recipePaths(g)
        guard RecipeExtras.isRecipeID(id) else { throw fail(HostError(.invalid, "\(id): an id is a-z, 0-9 and dashes, starting with a letter, at most 24"), g) }
        if RecipeCatalogue.dozableNames.contains(id) { throw fail(HostError(.exists, "\(id) is one of Dozable's own recipes — choose another id"), g) }
        let url = p.mine(id)
        if FileManager.default.fileExists(atPath: url.path), !force { throw fail(HostError(.exists, "\(DisplayPath.tilde(url.path)) exists — --force replaces it"), g) }
        let text: String
        if let from {
            guard let r = AgentRecipes.recipe(from), r.origin.isDozable, r.isPublished else {
                throw fail(HostError(.notFound, "\(from) is not a published recipe of Dozable's — doz search lists them"), g)
            }
            guard !r.isBuiltin else { throw fail(HostError(.invalid, "\(r.title) is a built-in agent (Dozable's own installer) — copy a recipe agent instead"), g) }
            text = try Self.copy(r, as: id)
        } else {
            text = Self.scaffold(id)
        }
        try? FileManager.default.createDirectory(at: p.mine, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard FileManager.default.createFile(atPath: url.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw fail(HostError(.failed, "could not write \(url.path)"), g)
        }
        applyRecipeChange(p, g)           // not used until it passes the requirements — then at once (no host), or at the next host start
        if g.json { Out.json(["path": url.path, "id": id]); return }
        Out.stdout("wrote \(DisplayPath.tilde(url.path))\n")
        Out.stdout("Fill in every TODO, then check it: doz recipe check \(id)\n")
    }

    /// A copy of a Dozable recipe under a new id: what makes it Dozable's (its aliases, mark, family, hidden vendor and quiet
    /// hosts, currency) left out, its model permission renamed, and who maintains it left for you.
    static func copy(_ src: AgentRecipe, as id: String) throws -> String {
        var r = src
        r.id = id
        r.title = "My " + src.title
        r.publisher = "TODO who maintains this recipe"
        r.homepage = "https://example.com/TODO"
        r.description = "TODO one sentence: what it is"
        r.aliases = nil
        r.icon = nil
        r.family = nil
        r.published = nil
        r.lifecycle = nil
        r.checked = nil
        r.settings = nil
        r.network.vendor = nil
        r.network.quiet = nil
        if r.network.model.shared != true { r.network.model.id = "model:\(id)" }
        let spdx = src.licence.range(of: "^[A-Za-z0-9.+-]+$", options: .regularExpression) != nil ? src.licence : "LicenseRef-see-source"
        let doc = RecipeDocument(r, vendor: "local", licenses: [spdx])
        return try RecipeSource.yaml(doc, schemaPath: recipeSchemaURL, header: """
            Your recipe \(id) — a copy of Dozable's \(src.title) recipe, renamed. The format: docs/recipes/RECIPE-FORMAT.md.
            Fill in every TODO (who maintains it, its link, one sentence), then: doz recipe check \(id)
            """)
    }

    /// A file to fill in: every field the format needs, TODO where only you can say (it fails `doz recipe check` until then).
    static func scaffold(_ id: String) -> String {
        let arg = id.uppercased().replacingOccurrences(of: "-", with: "_") + "_VERSION"
        return """
        # yaml-language-server: $schema=\(recipeSchemaURL)
        # Your recipe \(id). The format: docs/recipes/RECIPE-FORMAT.md (or copy one of Dozable's: doz recipe new \(id) --from opencode).
        # Fill in every TODO, then: doz recipe check \(id)
        schema: 2
        kind: workload
        id: local/\(id)
        displayName: TODO the tool's name
        description: TODO one sentence — what it is
        author: TODO who maintains this recipe
        sourceUrl: https://example.com/TODO
        licenses:
        - TODO
        args:
          version:
            description: The release Dozable installs (its pin).
            default: 0.0.0
            pattern: '[0-9]+\\.[0-9]+\\.[0-9]+([-+][0-9A-Za-z.-]+)?'
            buildArg: \(arg)
        provides:
        - com.dozable/\(id)@${{ kit.args.version }}
        capabilities:
        - type: com.docker.sandbox/network-policy@1
          config:
            runtime:
              allow:
              - api.x.ai:443
            dozable:
              model:
                id: model:\(id)
                title: Talk to xAI
                hosts:
                - host: api.x.ai
              update: []
              excluded: []
        - type: com.docker.sandbox/credential@1
          config:
            service: xai
            phase: runtime
            apiKey:
              name: XAI_API_KEY
              proxyManaged: true
              inject:
              - domain: api.x.ai
                header: authorization
                format: Bearer %s
            dozable:
              accounts:
              - key
        - type: com.docker.sandbox/volume@1
          config:
            path: /home/agent/.config/\(id)
        - type: com.dozable/install@1
          config:
            kind: npm
            package: TODO-npm-package
            binary: \(id)
            integrity: sha512-TODO
        - type: com.dozable/launch@1
          config:
            command:
            - \(id)
            no_prompts_args: []
            passthrough:
            - --version
            - --help
            env: {}
            state_env: {}
            status: none
            verify:
            - argv:
              - \(id)
              - --version
              expect: ${{ kit.args.version }}
            check:
              argv:
              - \(id)
              - -p
              - say ok
              expect: DOZ_FAKE_OK
        - type: com.dozable/auth@1
          config:
            methods:
            - kind: api-key
              provider: xai
              accounts:
              - key
              keys_page: https://console.x.ai/
        - type: com.dozable/gateways@1
          config:
            entries:
            - gateway: openrouter
              level: unknown
            - gateway: vercel-ai-gateway
              level: unknown
        - type: com.dozable/directory@1
          config:
            kind: coding-agent
            categories:
            - coding-agent
            default_base: debian
            platforms:
              glibc: true
              musl: false
            tags: []
        - type: com.dozable/guide@1
          config:
            intro: TODO one or two sentences — what it is, and how it is used.
            steps:
            - text: Check it answers.
              command: \(id) -p "say ok"

        """
    }
}

struct RecipeAdd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "add",
        abstract: "Copy a recipe file in as one of yours (recipes/mine/ID.yaml) — after it passes the minimum requirements for a community recipe.")
    @OptionGroup var g: GlobalOptions
    @Argument(help: "The recipe's YAML file.") var file: String
    @Flag(name: .long, help: "Replace a recipe of yours with that id.") var force = false

    func run() async throws {
        let p = try recipePaths(g)
        guard file.contains("/") || file.hasSuffix(".yaml") || file.hasSuffix(".yml") else {
            throw fail(HostError(.invalid, "\(file): name the YAML file (./\(file) for one in this folder)"), g)
        }
        let t = try recipeTarget(file, p, g)
        let (results, _) = recipeStaticCheck(t)
        guard results.allSatisfy(\.passed) else {
            if !g.json { Out.stdout("\(file):\n"); printRequirements(results) }
            throw fail(HostError(.invalid, "\(file) " + CommunityRequirements.verdict(results) + " — nothing added"), g)
        }
        let url = p.mine(t.id)
        if FileManager.default.fileExists(atPath: url.path), !force { throw fail(HostError(.exists, "a recipe of yours called \(t.id) exists — --force replaces it"), g) }
        try? FileManager.default.createDirectory(at: p.mine, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard FileManager.default.createFile(atPath: url.path, contents: t.bytes, attributes: [.posixPermissions: 0o600]) else {
            throw fail(HostError(.failed, "could not write \(url.path)"), g)
        }
        RecipeExtras.recordCheck(RecipeCheckRecord(id: t.id, sha256: t.sha256, level: "static", doz: DozableCommand.version,
                                                   date: ISO8601DateFormatter().string(from: Date())), p)
        let when = applyRecipeChange(p, g)
        if g.json { Out.json(["id": t.id, "path": url.path, "applies": when]); return }
        Out.stdout("added \(t.id) as yours (\(DisplayPath.tilde(url.path))) — \(when)\n")
    }
}

// MARK: - doz recipe show

struct RecipeShow: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "show", abstract: "One recipe of yours or of a community source: whose, what its bake installs and reaches, its check.")
    @OptionGroup var g: GlobalOptions
    @Argument(help: "An id (yours or a community source's) or a YAML file.") var recipe: String
    @Flag(name: .long, help: "Print the compiled document (JSON) — what a community catalogue carries as agents/ID.json.") var document = false

    func run() async throws {
        let p = try recipePaths(g)
        let t = try recipeTarget(recipe, p, g)
        if document {
            guard (try? RecipeDocument.decode(t.compiled)) != nil else { throw fail(HostError(.invalid, "\(recipe) does not read as a recipe — doz recipe check \(recipe) says why"), g) }
            FileHandle.standardOutput.write(t.compiled)
            return
        }
        let (results, r) = recipeStaticCheck(t)
        let checks = RecipeExtras.checks(p).filter { $0.id == t.id }
        if g.json {
            Out.json(["id": .string(t.id), "origin": .string(t.origin.kind), "source": t.origin.source.map(JSONValue.string) ?? .null,
                      "sha256": .string(t.sha256), "meets": .bool(results.allSatisfy(\.passed)),
                      "checked": .array(checks.filter { $0.sha256 == t.sha256 }.map { .string($0.level) })] as [String: JSONValue])
            return
        }
        var lines = ["\(r?.title ?? t.id) (\(t.id))"]
        if let r { lines.append("  " + recipeWhose(r.origin.isDozable ? { var x = r; x.origin = t.origin; return x }() : r, p)) }
        if let path = t.path { lines.append("  file: \(DisplayPath.tilde(path))") }
        lines.append("  sha256: \(t.sha256)")
        if let r { lines += recipeBakeLines(r).map { "  " + $0 } }
        let passed = checks.filter { $0.sha256 == t.sha256 }.map { "\($0.level) \($0.date.prefix(10))" }
        lines.append("  checked: " + (passed.isEmpty ? (checks.isEmpty ? "never — doz recipe check \(t.id)" : "not these bytes (changed since its check)") : passed.joined(separator: ", ")))
        lines.append("  " + CommunityRequirements.verdict(results))
        Out.stdout(lines.joined(separator: "\n") + "\n")
    }
}

// MARK: - doz recipe check

struct RecipeCheck: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "check",
        abstract: "Does a recipe meet the minimum requirements for a community recipe? Item by item, then one verdict; --full also builds and tries it for real.",
        discussion: """
        Always: the schema and the strict read, every rule Dozable's own recipes pass, and the community rules (not one of Dozable's names, \
        filled in, every download pinned with its integrity, a guide and a check turn, no credential, nothing hidden). \
        --full: also, in a scratch store with fake keys and a stand-in model provider on this Mac — the image built at its pin, its verify \
        commands, a fresh try's first screen, its check turn (the fake key swapped in by Dozable's proxy, only a placeholder in the sandbox), \
        its guide's steps, no key in the sandbox, and the leak guard. It does not check the agent's status reports, web ports, every model \
        source it can use, or an agent that answers only through a tool call. A pass is recorded with the sha256 of the bytes that passed. \
        Exit 0: it meets them · 1: it does not.
        """)
    @OptionGroup var g: GlobalOptions
    @Argument(help: "An id (yours or a community source's) or a YAML file.") var recipe: String
    @Flag(name: .long, help: "Also build and try it for real, in a scratch store (minutes the first time; needs the network for the build).") var full = false
    @Option(name: .long, help: "The scratch folder for --full (default: a short folder under $TMPDIR; built images are kept there for the next run).") var scratch: String?

    func run() async throws {
        let p = try recipePaths(g)
        let t = try recipeTarget(recipe, p, g)
        let (results, r) = recipeStaticCheck(t)
        let staticOK = results.allSatisfy(\.passed)
        let now = ISO8601DateFormatter().string(from: Date())
        if staticOK { RecipeExtras.recordCheck(RecipeCheckRecord(id: t.id, sha256: t.sha256, level: "static", doz: DozableCommand.version, date: now), p) }
        // Yours, checked: in use at once when no host runs (or from the next host start) — a failing one stays unused.
        var applies: String?
        if t.origin.isMine, t.path == p.mine(t.id).path { applies = applyRecipeChange(p, g) }
        if !g.json {
            Out.stdout("\(r?.title ?? t.id) (\(t.id)) — the minimum requirements for a community recipe:\n")
            printRequirements(results)
        }
        guard full, staticOK, let r else {
            if g.json { Out.json(RecipeCheckJSON(id: t.id, sha256: t.sha256, meets: staticOK, results: results, full: nil)) }
            else {
                Out.stdout(CommunityRequirements.verdict(results) + (full && !staticOK ? " — the full check runs once these pass" : "") + "\n")
                if staticOK, let a = applies { Out.stdout("yours: \(a)\n") }
            }
            if !staticOK { throw ExitCode(DozableExit.failed) }
            return
        }
        if !g.json { Out.stdout("The full check (a scratch store, fake keys, a stand-in model provider):\n") }
        let report = await RecipeFullCheck(recipe: r, yaml: t.origin.isMine ? t.bytes : nil, compiled: t.compiled, g: g, scratch: scratch).run()
        let ok = report.failures.isEmpty
        if ok { RecipeExtras.recordCheck(RecipeCheckRecord(id: t.id, sha256: t.sha256, level: "full", doz: DozableCommand.version, date: now), p) }
        if g.json { Out.json(RecipeCheckJSON(id: t.id, sha256: t.sha256, meets: ok, results: results, full: report)); if !ok { throw ExitCode(DozableExit.failed) }; return }
        if ok { Out.stdout("meets the minimum requirements for a community recipe, built and tried for real (recorded for sha256 \(t.sha256.prefix(12))…)\n") }
        else { Out.stdout("does not meet the minimum requirements for a community recipe: the full check failed\n") }
        if !ok { throw ExitCode(DozableExit.failed) }
    }
}

struct RecipeCheckJSON: Codable {
    var id: String
    var sha256: String
    var meets: Bool
    var results: [CommunityRequirements.Result]
    var full: RecipeFullCheck.Report?
}

// MARK: - doz recipe trust

struct RecipeTrust: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "trust",
        abstract: "Say yes to a community recipe's current version ahead (what a sandbox of it would otherwise ask once) — for scripts.")
    @OptionGroup var g: GlobalOptions
    @Argument(help: "The community recipe's id.") var id: String

    func run() async throws {
        let p = try recipePaths(g)
        guard let e = RecipeExtras.snapshotEntry(id: id, p), e.source.origin.isCommunity, let r = AgentRecipes.recipe(id), r.origin.isCommunity else {
            throw fail(HostError(.notFound, "no community recipe called \(id) in use — doz recipe ls lists them"), g)
        }
        RecipeExtras.trust(id: id, sha256: e.file.sha256, p)
        if g.json { Out.json(["id": id, "sha256": e.file.sha256]); return }
        Out.stdout("said yes to \(r.title) from \(r.origin.source ?? "?") (sha256 \(e.file.sha256.prefix(12))…) — asked again only for another version\n")
    }
}

// MARK: - doz recipe rm

struct RecipeRemove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rm",
        abstract: "Remove a recipe of yours. It is kept, unpublished, so the sandboxes made from it keep working; --forget drops a kept one.")
    @OptionGroup var g: GlobalOptions
    @Argument(help: "The id.") var id: String
    @Flag(name: .long, help: "Forget a removed recipe entirely (refused while a sandbox in this store was made from it).") var forget = false
    @Flag(name: [.short, .long], help: "Do not ask.") var yes = false

    func run() async throws {
        let p = try recipePaths(g)
        let url = p.mine(id)
        if forget {
            guard FileManager.default.fileExists(atPath: p.kept(id).path) else { throw fail(HostError(.notFound, "no removed recipe called \(id) is kept"), g) }
            let users = try await recipeUsers(id, g)
            guard users.isEmpty else { throw fail(HostError(.invalid, "\(users.joined(separator: ", ")) was made from \(id) — remove it first"), g) }
            try confirm("Forget the removed recipe \(id)?", yes: yes, g)
            try? FileManager.default.removeItem(at: p.kept(id))
            let when = applyRecipeChange(p, g)
            Out.stdout("forgot \(id) — \(when)\n")
            return
        }
        guard let bytes = try? Data(contentsOf: url) else { throw fail(HostError(.notFound, "no recipe of yours called \(id) — doz recipe ls lists them"), g) }
        try confirm("Remove your recipe \(id)? (kept, unpublished, for the sandboxes made from it)", yes: yes, g)
        if let compiled = try? RecipeSource.compile(yaml: String(decoding: bytes, as: UTF8.self)), (try? RecipeDocument.decode(compiled)) != nil {
            RecipeExtras.keep(id: id, origin: .mine, document: compiled, sha256: RecipeExtras.sha256(bytes), p)
        }
        try? FileManager.default.removeItem(at: url)
        let when = applyRecipeChange(p, g)
        if g.json { Out.json(["id": id, "applies": when]); return }
        Out.stdout("removed \(id) — kept unpublished for the sandboxes made from it; \(when)\n")
    }
}

/// The sandboxes in this store made from recipe `id`.
func recipeUsers(_ id: String, _ g: GlobalOptions) async throws -> [String] {
    let rows = (try? decode(try await query(HostRequest(.ls), g), [SandboxInfo].self, g)) ?? []
    return rows.filter { ImageChoice.parse(DozableImages.canonicalName($0.image))?.agent.rawValue == id }.map(\.name)
}

// MARK: - doz recipe source

struct RecipeSourceCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "source",
        abstract: "Community catalogues: add one by its URL and its publisher's key (you confirm the key's fingerprint first), list them, remove one.",
        subcommands: [RecipeSourceAdd.self, RecipeSourceList.self, RecipeSourceRemove.self, RecipeSourceVerify.self],
        defaultSubcommand: RecipeSourceList.self)
}

struct RecipeSourceAdd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "add",
        abstract: "Add a community catalogue: its recipes.json URL and its publisher's Ed25519 public key. Nothing is fetched before you confirm the key's fingerprint.")
    @OptionGroup var g: GlobalOptions
    @Argument(help: "The catalogue's recipes.json (https).") var url: String
    @Option(name: .long, help: "The publisher's Ed25519 public key (base64).") var key: String
    @Option(name: .long, help: "What to call it (a-z, 0-9, dashes; default: the URL's host).") var name: String?
    @Option(name: .long, help: "The key's fingerprint as the publisher gave it (SHA256:…) — confirms it without a question (for scripts).") var fingerprint: String?

    func run() async throws {
        let p = try recipePaths(g)
        let guarded = TestSafety.guarded()
        if let why = RecipeExtras.urlProblem(url, guarded: guarded) { throw fail(HostError(.invalid, why), g) }
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let fp = RecipeExtras.fingerprint(k) else { throw fail(HostError(.invalid, "--key is a base64 Ed25519 public key (32 bytes)"), g) }
        if k == Distribution.updatePublicKey { throw fail(HostError(.invalid, "that is Dozable's own key — it signs Dozable's recipes, never a community catalogue"), g) }
        let n = name ?? RecipeExtras.defaultName(url)
        guard RecipeOrigin.isSourceName(n) else { throw fail(HostError(.invalid, "\(n): a source's name is a-z, 0-9 and dashes (--name)"), g) }
        var all = CommunitySources.load(p)
        if all.sources.contains(where: { $0.name == n }) { throw fail(HostError(.exists, "a source called \(n) exists — doz recipe source rm \(n) first, or --name"), g) }
        if !g.json { Out.stdout("The publisher's key fingerprint: \(fp)\n") }
        // Confirmed before anything is fetched.
        if let f = fingerprint {
            guard f.trimmingCharacters(in: .whitespaces) == fp else {
                throw fail(HostError(.failed, "the fingerprint you gave is not this key's (\(fp)) — nothing added"), g)
            }
        } else if isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1 {
            try confirm("Is \(fp) the fingerprint \(n)'s publisher gave you?", yes: false, g)
        } else {
            throw fail(HostError(.failed, "confirm the key first: compare \(fp) with the fingerprint the publisher gave you, then add --fingerprint \(fp) — nothing added, nothing fetched"),
                       g, code: DozableExit.declined)
        }
        let now = ISO8601DateFormatter().string(from: Date())
        let s = CommunitySource(name: n, url: url, key: k, fingerprint: fp, confirmed: now, added: now)
        all.sources.append(s)
        guard all.save(p) else { throw fail(HostError(.failed, "could not write \(p.sources.path)"), g) }
        // Fetched now (and by the host hourly).
        let outcome = await CommunityRefresh.refresh(s, p, version: DozableCommand.version, force: true)
        var said = "added \(n) (\(url))"
        switch outcome {
        case .downloaded(let serial):
            said += " — catalogue \(serial) downloaded and verified"
            let when = applyRecipeChange(p, g)
            said += "; " + when
            if let trial = Self.trial(s, p) { said += "\n  but it would not be used: \(trial)" }
        case .refused(let why, _): said += " — its catalogue was refused: \(why)"
        case .unchanged: said += " — nothing published there yet (404); the host looks again hourly"
        case .offline: said += " — not reachable now; the host looks again hourly"
        case .disabled(let why): said += " — not fetched: \(why)"
        case .notDue: break
        }
        if g.json { Out.json(["name": n, "fingerprint": fp, "outcome": said]); return }
        Out.stdout(said + "\n")
    }

    /// Would the catalogue just fetched be refused whole? (The definitive word is the next process's — doz recipe source ls.)
    static func trial(_ s: CommunitySource, _ p: RecipeExtrasPaths) -> String? {
        let cache = p.community(s.name)
        guard let m = cache.current ?? cache.next, let files = RecipeCatalogueCache.readFiles(m, from: cache.filesDir(serial: m.serial)) else { return nil }
        var taken = Set(AgentRecipes.all.filter { $0.origin != .community(s.name) }.flatMap { [$0.id] + ($0.aliases ?? []) })
        for f in m.files {
            guard let d = files[f.path] else { continue }
            let others = AgentRecipes.all.filter { $0.origin != .community(s.name) }
            let (results, r) = CommunityRequirements.check(d, others: others, dozableIDs: RecipeCatalogue.dozableNames)
            if let x = CommunityRequirements.firstFailure(results) { return "\(f.path): \(x)" }
            if let r, let clash = ([r.id] + (r.aliases ?? [])).first(where: taken.contains) { return "\(f.path): \(clash) is already another recipe's" }
            if let r { taken.formUnion([r.id] + (r.aliases ?? [])) }
        }
        return nil
    }
}

struct SourceRow: Codable {
    var name: String
    var url: String
    var fingerprint: String
    var confirmed: String
    var serial: Int?
    var waiting: Int?
    var recipes: [String]
    var state: String
    var problem: String?
}

struct RecipeSourceList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ls", abstract: "The community catalogues you added: URL, key fingerprint, the catalogue in use, its recipes.")
    @OptionGroup var g: GlobalOptions

    func run() async throws {
        let p = try recipePaths(g)
        let u = RecipeExtras.inUse(p)
        let rows = CommunitySources.load(p).sources.map { s -> SourceRow in
            let cache = p.community(s.name)
            let o = RecipeExtras.startOutcomes.first { $0.origin == .community(s.name) }
            let snapRefused = u?.refused.first { $0.origin == .community(s.name) }?.why
            let snap = u?.sources.first { $0.origin == .community(s.name) }
            var state = snap == nil ? (snapRefused == nil ? "nothing fetched yet" : "refused") : "in use"
            if let r = o?.refused { state = "refused: \(r)" } else if let r = snapRefused { state = "refused: \(r)" }
            return SourceRow(name: s.name, url: s.url, fingerprint: s.fingerprint, confirmed: s.confirmed, serial: snap?.serial ?? cache.current?.serial,
                             waiting: cache.next?.serial, recipes: snap?.files.map(\.id) ?? [], state: state, problem: cache.state.problem)
        }
        if g.json { Out.json(rows); return }
        guard !rows.isEmpty else { Out.stdout("No community catalogues. doz recipe source add URL --key KEY adds one.\n"); return }
        for r in rows {
            var s = "\(r.name) — \(r.url)\n  key \(r.fingerprint), confirmed \(r.confirmed.prefix(10))\n  \(r.state)"
            if let n = r.serial { s += " · catalogue \(n)" }
            if !r.recipes.isEmpty { s += " · recipes: \(r.recipes.joined(separator: ", "))" }
            if let w = r.waiting { s += "\n  catalogue \(w) is downloaded and applies at the next host start (doz host restart)" }
            if let pr = r.problem { s += "\n  last problem: \(pr)" }
            Out.stdout(s + "\n")
        }
    }
}

struct RecipeSourceRemove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rm",
        abstract: "Remove a community catalogue. Its recipes are kept, unpublished, so the sandboxes made from them keep working.")
    @OptionGroup var g: GlobalOptions
    @Argument(help: "The source's name (doz recipe source ls).") var name: String
    @Flag(name: [.short, .long], help: "Do not ask.") var yes = false

    func run() async throws {
        let p = try recipePaths(g)
        var all = CommunitySources.load(p)
        guard all.sources.contains(where: { $0.name == name }) else { throw fail(HostError(.notFound, "no community source called \(name) — doz recipe source ls"), g) }
        try confirm("Remove the community catalogue \(name)? (its recipes are kept, unpublished, for the sandboxes made from them)", yes: yes, g)
        // Keep what it gave (the snapshot's documents — what sandboxes were made from).
        if let u = RecipeExtras.inUse(p), let s = u.sources.first(where: { $0.origin == .community(name) }) {
            for f in s.files {
                if let d = try? Data(contentsOf: p.inUse.appendingPathComponent(f.file)) {
                    RecipeExtras.keep(id: f.id, origin: .community(name), document: d, sha256: f.sha256, p)
                }
            }
        }
        all.sources.removeAll { $0.name == name }
        _ = all.save(p)
        try? FileManager.default.removeItem(at: p.community(name).dir)
        let when = applyRecipeChange(p, g)
        if g.json { Out.json(["name": name, "applies": when]); return }
        Out.stdout("removed \(name) — its recipes are kept unpublished for the sandboxes made from them; \(when)\n")
    }
}

struct RecipeSourceVerify: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "verify",
        abstract: "Check a community catalogue on disk as a doz would use it: its signature with the key, its format, every recipe against the minimum requirements (what make publish-recipes COMMUNITY=1 runs before it writes).")
    @OptionGroup var g: GlobalOptions
    @Argument(help: "Its recipes.json (the files it names beside it, under its base).") var file: String
    @Option(name: .long, help: "The publisher's Ed25519 public key (base64).") var key: String

    func run() async throws {
        let url = URL(fileURLWithPath: (file as NSString).expandingTildeInPath)
        guard let d = try? Data(contentsOf: url) else { throw fail(HostError(.notFound, "\(file): no such file"), g) }
        let m: RecipeCatalogueManifest
        do { m = try RecipeCatalogueManifest.decode(d) } catch { throw fail(HostError(.invalid, RecipeCatalogue.reason(error)), g) }
        let s = CommunitySource(name: "check", url: "https://check.invalid/recipes.json", key: key, fingerprint: RecipeExtras.fingerprint(key) ?? "?",
                                confirmed: "", added: "")
        if let why = RecipeExtras.manifestProblem(m, s, version: DozableCommand.version) { throw fail(HostError(.invalid, why), g) }
        guard let files = RecipeCatalogueCache.readFiles(m, from: url.deletingLastPathComponent().appendingPathComponent(m.base, isDirectory: true)) else {
            throw fail(HostError(.invalid, "a file it names is missing"), g)
        }
        if let why = m.filesProblem(files) { throw fail(HostError(.invalid, why), g) }
        var bad = 0
        var taken = Set<String>()
        for f in m.files {
            guard let data = files[f.path] else { continue }
            let (results, r) = CommunityRequirements.check(data, others: AgentRecipes.all.filter(\.origin.isDozable), dozableIDs: RecipeCatalogue.dozableNames)
            var ok = results.allSatisfy(\.passed)
            if let r, ([r.id] + (r.aliases ?? [])).contains(where: taken.contains) { ok = false }
            if let r { taken.formUnion([r.id] + (r.aliases ?? [])) }
            if !ok { bad += 1 }
            if !g.json {
                Out.stdout("\(f.path): " + CommunityRequirements.verdict(results) + "\n")
                if !results.allSatisfy(\.passed) { printRequirements(results.filter { !$0.passed }) }
            }
        }
        if g.json { Out.json(["serial": .number(Double(m.serial)), "recipes": .number(Double(m.files.count)), "ok": .bool(bad == 0)] as [String: JSONValue]) }
        else { Out.stdout("catalogue \(m.serial): signed with the key (\(s.fingerprint)), \(m.files.count) recipe(s)" + (bad == 0 ? " — a doz would use it\n" : " — \(bad) refused: a doz would use none of it\n")) }
        if bad > 0 { throw ExitCode(DozableExit.failed) }
    }
}
