import ArgumentParser
import Darwin
import Foundation
@testable import DozerKit
import XCTest
@testable import DozerCLI
@testable import DozerHost
@testable import DozerWeb

/// 617 stage C (616.03 D11–D14): one set of choice options for new/create/up/try (+ init's agent/base), the planning
/// op's three outputs, `doz try`'s defaults, naming, card and exit choice, the stoppable keyboard thread, `doz search`
/// and the directory index — without a VM, a real keychain or the network.
final class KitchenTests: XCTestCase {
    private var root: URL!
    let keychain = FakeKeychain()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("doz-kitchen-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func core() async -> HostCore {
        let s = CredentialServices(keychain: keychain, verifier: FakeVerifier(answer: .verified), claudeBinary: { nil }, home: root,
                                   keepaliveRunner: FakeRunner(), isClaudeRunning: { false }, watchInterval: .seconds(3600))
        let c = HostCore(store: DozerStore(root: root), readOnly: false, version: "test", services: s)
        await c.load()
        return c
    }

    private func parse(_ args: [String]) throws -> ParsableCommand { try DozerCommand.parseAsRoot(args) }

    /// The facts a golden plan is made with: no accounts but mac, nothing prepared, a fixed projects folder.
    func facts(_ accounts: AccountsFile = AccountsFile(), taken: Set<String> = []) -> PlanFacts {
        PlanFacts(settings: DozerSettings(text: ""), accounts: accounts, taken: taken, images: [], store: DozerStore(root: root),
                  projectsDir: "/tmp/617-pin-projects")
    }

    // MARK: one set of choice options (D13)

    /// The same choice flags mean the same `CreateOptions` in new, create, up and try.
    func testTheSameChoicesMeanTheSameOptionsEverywhere() throws {
        let lines: [[String]] = [
            ["--agent", "grok", "--base", "alpine"],
            ["--agent", "gemini", "--permissions", "standard,+web", "--account", "g1", "--cpus", "4", "--memory", "4G"],
            ["--agent", "codex", "--allow", "site:api.example.com", "--github", "read", "--key", "ex", "--isolated", "--tmux", "--clipboard", "off"],
            ["--agent", "pi", "--network", "locked", "--no-agent-sudo", "--workspace", "/tmp/617-w"],
        ]
        for l in lines {
            let create = try XCTUnwrap(try parse(["create", "b"] + l) as? Create).create.planChoices()
            let up = try XCTUnwrap(try parse(["up", "b"] + l) as? Up).create.planChoices()
            let new = try XCTUnwrap(try parse(["new", "b"] + l) as? New).choices.planChoices()
            let tried = try XCTUnwrap(try parse(["try"] + l) as? TryCommand).choices.planChoices()
            XCTAssertEqual(create, up, l.joined(separator: " "))
            XCTAssertEqual(create, new, l.joined(separator: " "))
            XCTAssertEqual(create, tried, l.joined(separator: " "))
        }
        // --allow is --permissions (same option); `doz new NAME` is `doz new --name NAME`.
        XCTAssertEqual(try XCTUnwrap(try parse(["create", "b", "--image", "lab", "--allow", "web"]) as? Create).create.options(),
                       try XCTUnwrap(try parse(["create", "b", "--image", "lab", "--permissions", "web"]) as? Create).create.options())
        XCTAssertEqual(try XCTUnwrap(try parse(["new", "mine"]) as? New).name, "mine")
        XCTAssertEqual(try XCTUnwrap(try parse(["new", "--name", "mine"]) as? New).name, "mine")
        XCTAssertThrowsError(try parse(["new", "a", "--name", "b"]))
        XCTAssertThrowsError(try parse(["try", "grok", "--image", "lab"]), "a try runs its agent's own image")
        XCTAssertThrowsError(try parse(["try", "grok", "--rm", "--keep"]))
        // init: --agent/--base write the file's own keys.
        let i = try XCTUnwrap(try parse(["init", "--yes", "--name", "p", "--agent", "grok", "--base", "python"]) as? Init)
        let p = try i.ask(folder: root, existing: nil, asker: Asker(yes: true, json: false))
        XCTAssertEqual(p.agent, "grok")
        XCTAssertEqual(p.base, "python")
        XCTAssertEqual(p.image, "python-grok")
        XCTAssertTrue(p.render().contains("agent: grok"))
        XCTAssertThrowsError(try (try XCTUnwrap(try parse(["init", "--yes", "--name", "p", "--agent", "grok", "--image", "lab"]) as? Init))
            .ask(folder: root, existing: nil, asker: Asker(yes: true, json: false)))
    }

    // MARK: the plan (§6 2b)

    func plan(_ purpose: String, _ args: [String], name: String? = nil, facts f: PlanFacts? = nil) throws -> CreatePlan {
        let choices = try ChoiceOptions.from(args).planChoices()
        return CreatePlanner.plan(PlanRequest(purpose: purpose, name: name, create: choices), facts: f ?? facts())
    }

    /// The plan's three outputs (command, project file, reach) and its image/account/problems — pinned.
    func test_planOutputs() throws {
        var accounts = AccountsFile()
        var xai = AccountRecord(name: "work-xai", kind: .key, plan: nil)
        xai.provider = "xai"
        xai.source = .onePassword(reference: "op://Dev/xAI/credential")
        accounts.accounts.append(xai)
        accounts.providerDefaults = ["xai": "work-xai"]
        var ex = AccountRecord(name: "ex", kind: .key, plan: nil)
        ex.provider = "custom"
        ex.custom = CustomKey(hosts: ["api.example.test"], header: "authorization", format: "Bearer %s", env: "EX_KEY")
        accounts.accounts.append(ex)
        let withKey = PlanFacts(settings: DozerSettings(text: ""), accounts: accounts, taken: ["try-grok"], images: [], sourceLabels: ["work-xai": "1Password: op://Dev/xAI/credential"],
                                store: DozerStore(root: root), projectsDir: "/tmp/617-pin-projects")
        let cases: [(String, String, [String], String?, PlanFacts)] = [
            ("try grok, no key", "try", ["--agent", "grok"], nil, facts()),
            ("try grok, a key, try-grok taken", "try", ["--agent", "grok"], nil, withKey),
            ("try gemini on python, standard", "try", ["--agent", "gemini", "--base", "python", "--permissions", "standard"], nil, facts()),
            ("new, every default", "new", [], nil, facts()),
            ("new grok, named, a custom key not allowed", "new", ["--agent", "grok", "--key", "ex"], "g1", withKey),
            ("new grok, the custom key's host allowed", "new", ["--agent", "grok", "--key", "ex", "--allow", "site:api.example.test"], "g1", withKey),
            ("create codex, choices", "create", ["--agent", "codex", "--base", "python", "--cpus", "4", "--memory", "4G", "--network", "locked",
                                                 "--github", "read", "--tmux", "--isolated"], "c1", facts()),
            ("create lab nat", "create", ["--image", "lab", "--network", "nat"], "l1", facts()),
            ("a try of no agent", "try", ["--agent", "none", "--base", "debian"], nil, facts()),
        ]
        var out: [String] = []
        for (title, purpose, args, name, f) in cases {
            let p = try plan(purpose, args, name: name, facts: f)
            out.append("== \(title): \(purpose) \(args.joined(separator: " "))")
            out.append("command: \(p.command)")
            out.append("name: \(p.name) · image: \(p.imageState.name) (\(p.imageState.title ?? "-"), \(p.imageState.state)) · workspace: \(p.workspace ?? "isolated") · trial: \(p.trial.map(String.init) ?? "-")")
            if let a = p.account { out.append("account: \(a.name ?? "none") · \(a.kind ?? "-") · \(a.provider ?? "-") · \(a.sourceLabel ?? "-")") }
            for r in p.reach { out.append("reach \(r.kind): \(r.text)") }
            out.append("yaml: " + p.yaml.split(separator: "\n").filter { !$0.hasPrefix("#") }.joined(separator: " | "))
            if let n = p.yamlNote { out.append("yaml note: \(n)") }
            for pr in p.problems { out.append("problem \(pr.code): \(pr.text) [fix: \(pr.fix ?? "-")]") }
        }
        Pins.check(#function, out.joined(separator: "\n"))
    }

    /// The command's argv parses back to the same choices (the round trip), and the yaml reads back.
    func testThePlansCommandAndFileReadBack() throws {
        for (purpose, args) in [("try", ["--agent", "gemini", "--base", "python", "--memory", "4G", "--permissions", "+web"]),
                                ("new", ["--agent", "grok", "--cpus", "3", "--github", "push", "--no-agent-sudo", "--clipboard", "off"]),
                                ("create", ["--agent", "codex", "--base", "go", "--network", "locked", "--isolated"])] {
            let p = try plan(purpose, args, name: purpose == "try" ? nil : "x1")
            let cmd = try parse(Array(p.argv.dropFirst()))
            let back: CreateOptions
            switch cmd {
            case let t as TryCommand:
                var c = t.choices
                c.agent = t.thing
                back = try c.planChoices()
            case let n as New: back = try n.choices.planChoices()
            case let c as Create: back = try c.create.planChoices()
            default: return XCTFail("\(p.command) is not a making command")
            }
            let again = CreatePlanner.plan(PlanRequest(purpose: purpose, name: purpose == "try" ? nil : "x1", create: back), facts: facts())
            XCTAssertEqual(again.create, p.create, p.command)
            XCTAssertEqual(again.command, p.command)
            let file = try DozerProject.parse(p.yaml)
            XCTAssertEqual(file.image, p.image, p.command)
            XCTAssertEqual(file.network, p.create.network)
            XCTAssertEqual(file.cpus, p.create.cpus)
        }
    }

    /// The op itself: read-only, answered by an in-process host, the same plan.
    func testThePlanOpIsReadOnlyAndTheSame() async throws {
        XCTAssertTrue(HostOp.plan.isReadOnly)
        let s = CredentialServices(keychain: keychain, verifier: FakeVerifier(answer: .verified), claudeBinary: { nil }, home: root,
                                   keepaliveRunner: FakeRunner(), isClaudeRunning: { false }, watchInterval: .seconds(3600))
        let c = HostCore(store: DozerStore(root: root), readOnly: true, version: "test", services: s)
        await c.load()
        var r = HostRequest(.plan)
        r.planRequest = PlanRequest(purpose: "try", create: try ChoiceOptions.from(["--agent", "grok"]).planChoices())
        let m = await c.handle(r)
        XCTAssertNil(m.error, m.error?.message ?? "")
        let p = try XCTUnwrap(m.result).decode(CreatePlan.self)
        XCTAssertEqual(p.name, "try-grok")
        XCTAssertEqual(p.command, "doz try grok")
        XCTAssertEqual(p.create.network, "locked")
        XCTAssertEqual(p.create.trial, true)
        XCTAssertEqual(p.create.isolated, true)
        r.planRequest?.purpose = "nonsense"
        let bad = await c.handle(r)
        XCTAssertNotNil(bad.error)
        // The web projection carries no secret-shaped field.
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: WebJSON.encoder.encode(WebPlan(p))) as? [String: Any])
        func keys(_ o: Any) -> [String] {
            if let d = o as? [String: Any] { return d.keys + d.values.flatMap(keys) }
            if let a = o as? [Any] { return a.flatMap(keys) }
            return []
        }
        for k in keys(obj) {
            XCTAssertFalse(["secret", "token", "password", "apikey", "api_key", "bearer", "authorization", "cookie", "csrf"].contains { k.lowercased().contains($0) }, k)
        }
    }

    // MARK: doz try (D14)

    func testATriesDefaultsAndItsName() throws {
        let p = try plan("try", ["--agent", "grok"])
        XCTAssertEqual(p.create.image, "grok")
        XCTAssertEqual(p.create.network, "locked")
        XCTAssertNil(p.workspace)
        XCTAssertEqual(p.trial, true)
        XCTAssertEqual(CreatePlanner.tryName(agent: AgentKind(rawValue: "grok")!, taken: []), "try-grok")
        XCTAssertEqual(CreatePlanner.tryName(agent: AgentKind(rawValue: "grok")!, taken: ["try-grok", "try-grok-2"]), "try-grok-3")
        XCTAssertEqual(CreatePlanner.tryName(agent: .claudeCode, taken: []), "try-claude")
        // Every choice still works: a base, a network, a folder.
        let q = try plan("try", ["--agent", "gemini", "--base", "python", "--network", "agent", "--workspace", "/tmp/617-w"])
        XCTAssertEqual(q.create.image, "python-gemini")
        XCTAssertEqual(q.create.network, "agent")
        XCTAssertEqual(q.workspace, "/tmp/617-w")
        XCTAssertEqual(q.command, "doz try gemini --base python --workspace /tmp/617-w --network agent")
    }

    /// `doz ls` says a try (SandboxInfo's own coding carries the marker and the custom keys — the VM proof found it didn't).
    func testSandboxInfoCarriesTheTryAndItsKeys() throws {
        var i = SandboxInfo(name: "try-grok", image: "grok", phase: "off", busy: false, cpus: 2, memoryMiB: 2048, ramHeldMiB: 0, memoryReturnedMiB: 0,
                            diskBytes: 1, sessions: nil, network: "locked", deniedConnections: nil, workspace: nil, createdAt: nil, diedWithHost: nil,
                            account: nil, credentialState: nil, credentialPolicy: nil, foreignCredentials: nil)
        i.trial = true
        i.extraKeys = ["ex"]
        let back = try JSONDecoder().decode(SandboxInfo.self, from: JSONEncoder().encode(i))
        XCTAssertEqual(back.trial, true)
        XCTAssertEqual(back.extraKeys, ["ex"])
    }

    func testTheWhatYouNeedCard() throws {
        let grok = try XCTUnwrap(AgentRecipes.recipe("grok")), gemini = try XCTUnwrap(AgentRecipes.recipe("gemini"))
        XCTAssertNil(TryCard.build(grok, haveKey: "work-xai"), "a key there: no card at all")
        let card = try XCTUnwrap(TryCard.build(grok, haveKey: nil))
        XCTAssertEqual(card.title, "What you need — Grok Build talks to xAI")
        XCTAssertEqual(card.options.map(\.kind), ["paste", "source"])
        XCTAssertTrue(card.options[0].label.contains("xAI API key"))
        XCTAssertTrue(card.options[0].consequence.contains("placeholder"))
        XCTAssertEqual(card.getKey, "Get a key: https://console.x.ai/")
        XCTAssertEqual(card.notOffered.count, 1, "Grok's own sign-in cannot work in a sandbox (its hosts are kept out) — said, not offered")
        XCTAssertTrue(card.notOffered[0].contains("an x.ai or X account"))
        let g = try XCTUnwrap(TryCard.build(gemini, haveKey: nil))
        XCTAssertEqual(g.options.map(\.kind), ["paste", "source"])
        XCTAssertEqual(g.getKey, "Get a key: https://aistudio.google.com/apikey")
        // A recipe whose agent signs in inside the sandbox: offered, labelled.
        var r = grok
        r.auth.methods[1].inSandbox = true
        let signIn = try XCTUnwrap(TryCard.build(r, haveKey: nil))
        XCTAssertEqual(signIn.options.map(\.kind), ["paste", "source", "sign-in"])
        XCTAssertTrue(signIn.options[2].consequence.contains("the sign-in lives in this sandbox"))
    }

    func testKeepThisTry() {
        XCTAssertEqual(TryExitChoice.parse(""), .sleep, "Enter = Sleep")
        XCTAssertEqual(TryExitChoice.parse("S"), .sleep)
        XCTAssertEqual(TryExitChoice.parse("d"), .delete)
        XCTAssertEqual(TryExitChoice.parse("Delete"), .delete)
        XCTAssertEqual(TryExitChoice.parse("k"), .keep)
        XCTAssertNil(TryExitChoice.parse("x"))
        XCTAssertEqual(TryExitChoice.decided(rm: true, keep: false, interactive: true), .delete)
        XCTAssertEqual(TryExitChoice.decided(rm: false, keep: true, interactive: true), .keep)
        XCTAssertEqual(TryExitChoice.decided(rm: false, keep: false, interactive: false), .keep, "off a terminal a try is kept")
        XCTAssertNil(TryExitChoice.decided(rm: false, keep: false, interactive: true), "asked")
    }

    /// The keyboard thread's read stops when the self-pipe is written — so the next prompt gets its first key.
    func testTheKeyboardThreadIsStoppable() throws {
        var input: [Int32] = [-1, -1], stop: [Int32] = [-1, -1]
        XCTAssertEqual(pipe(&input), 0)
        XCTAssertEqual(pipe(&stop), 0)
        defer { for fd in input + stop { close(fd) } }
        var buf = [UInt8](repeating: 0, count: 16)
        var k: UInt8 = 0x61
        _ = write(input[1], &k, 1)
        XCTAssertEqual(stoppableRead(&buf, stop: stop[0], input: input[0]), 1, "a key is read")
        let done = expectation(description: "stopped")
        let box = Box()
        let fds = (input[0], stop[0])
        Thread.detachNewThread {
            var b = [UInt8](repeating: 0, count: 16)
            let r = stoppableRead(&b, stop: fds.1, input: fds.0)
            box.append(r == nil ? "stopped" : "read")
            done.fulfill()
        }
        usleep(100_000)
        var one: UInt8 = 1
        _ = write(stop[1], &one, 1)
        wait(for: [done], timeout: 2)
        XCTAssertEqual(box.items, ["stopped"])
        // Nothing was read from the terminal by the stopped thread: the next key is still there for the prompt.
        _ = write(input[1], &k, 1)
        XCTAssertEqual(read(input[0], &buf, 16), 1)
    }

    // MARK: doz search

    func testSearchMatchesLevelsTagsAndSuggests() throws {
        let index = DirectoryIndex.build(version: "0.34.0")
        func ids(_ words: [String], tags: [String] = [], level: String? = nil, base: String? = nil) -> [String] {
            DirectorySearch.search(SearchQuery.parse(words, tags: tags, level: level, base: base), in: index).hits.map { "\($0.entry.kind):\($0.entry.id)" }
        }
        XCTAssertEqual(ids(["grok"]).first, "agent:grok")
        XCTAssertEqual(ids(["claude"]).first, "agent:claude-code", "an alias")
        XCTAssertEqual(ids(["gemini cli"]), ["agent:gemini"], "the title's words")
        XCTAssertTrue(ids(["xai"]).contains("provider:xai"))
        XCTAssertTrue(ids(["alpine"]).contains("base:alpine"))
        XCTAssertEqual(DirectorySearch.search(SearchQuery.parse(["grokk"]), in: index).suggestion, "grok")
        XCTAssertEqual(DirectorySearch.search(SearchQuery.parse(["grokk"]), in: index).verdict, "unknown")
        XCTAssertEqual(DirectorySearch.search(SearchQuery.parse(["opencode"]), in: index).verdict, "coming")
        XCTAssertEqual(DirectorySearch.search(SearchQuery.parse(["grok"]), in: index).verdict, "supported")
        // Tags: tag: terms and --tag, filtered by level.
        let multi = ids(["tag:multi-vendor-models"])
        for id in multi { XCTAssertTrue(AgentRecipes.recipe(String(id.dropFirst(6)))?.hasTag("multi-vendor-models") == true, id) }
        XCTAssertEqual(Set(ids([], tags: ["api-key"])), Set(AgentRecipes.all.filter { $0.hasTag("api-key") }.map { "agent:\($0.id)" }))
        XCTAssertEqual(Set(ids([], tags: ["multi-vendor-models"], level: "any")), Set(AgentRecipes.all.map { "agent:\($0.id)" }),
                       "every recipe has every tag at some level")
        // Limited: a recipe with no musl build, asked for Alpine.
        var r = try XCTUnwrap(AgentRecipes.recipe("grok"))
        r.id = "noglibc-agent"
        r.title = "No Musl Agent"
        r.aliases = nil
        r.platforms.musl = false
        let limited = DirectoryIndex.build(version: "0.34.0", recipes: AgentRecipes.all + [r])
        let res = DirectorySearch.search(SearchQuery.parse(["noglibc-agent"], base: "alpine"), in: limited)
        XCTAssertEqual(res.verdict, "limited")
        XCTAssertTrue(res.hits.first?.limit?.contains("no musl build") == true)
        XCTAssertEqual(DirectorySearch.distance("grokk", "grok"), 1)
        XCTAssertEqual(DirectorySearch.distance("", "abc"), 3)
    }

    /// The exit codes a script reads.
    func testSearchExitCodes() async throws {
        func code(_ args: [String]) async -> Int32 {
            do {
                var s = try XCTUnwrap(try parse(["search"] + args + ["--json", "--store", root.path]) as? SearchCommand)
                s.g.json = true
                try await s.run()
                return 0
            } catch let e as ExitCode { return e.rawValue } catch { return -1 }
        }
        let a = await code(["grok"])
        XCTAssertEqual(a, 0)
        let b = await code(["opencode"])
        XCTAssertEqual(b, DozerExit.unavailable)
        let c = await code(["grokk"])
        XCTAssertEqual(c, DozerExit.notFound)
        let d = await code([])
        XCTAssertEqual(d, 0, "everything")
        XCTAssertThrowsError(try parse(["search", "--tag", "nonsense"]))
    }
}
