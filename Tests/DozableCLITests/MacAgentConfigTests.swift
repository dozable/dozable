import Darwin
import Foundation
@testable import DozableKit
import XCTest
@testable import DozableHost

/// The agent's config folder in a fenced session on this Mac (`MacAgentConfig`), its recipe declaration (`mac_config`,
/// embedded recipes only), its transcripts (`MacTranscripts`), its facts (`MacAgentPrompt`) and its capabilities — all in
/// scratch homes under /private/tmp (`FenceScratch`), never the real one.
final class MacAgentConfigTests: XCTestCase {
    var w: FenceScratch!
    override func setUpWithError() throws { w = try FenceScratch() }
    override func tearDown() { w.remove() }

    var claude: AgentRecipe { AgentRecipes.recipe("claude-code")! }
    var enc: String { "projects/" + MacPlace.claudeProjectFolderName(w.work) }
    let uuid = "0b1c2d3e-4f50-4a6b-8c7d-8e9fa0b1c2d3"

    /// A twin ~/.claude: settings with keys that must never come, instructions, skills with links in and out.
    func twinClaude() {
        let c = w.home + "/.claude"
        w.write(c + "/settings.json", """
        {"env": {"X": "TWINSECRET"}, "apiKeyHelper": "/bin/echo k", "hooks": {"Stop": []}, "statusLine": {"command": "x"},
         "enabledPlugins": {"p": true}, "model": "opus", "permissions": {"allow": ["Bash(ls)"], "deny": ["Read(.env)"], "additionalDirectories": ["/"]},
         "language": "en"}
        """)
        w.write(c + "/CLAUDE.md", "TWIN INSTRUCTIONS")
        w.write(c + "/skills/one/SKILL.md", "SKILL ONE")
        w.write(c + "/.credentials.json", "{\"token\":\"TWINSECRET\"}")
        w.write(w.home + "/shared-skills/two/SKILL.md", "SKILL TWO")
        symlink(w.home + "/shared-skills/two", c + "/skills/two")          // allowed: an ordinary folder of the home
        symlink(w.home + "/.config/gh", c + "/skills/gh")                   // closed place: not followed
        symlink(w.work, c + "/skills/work")                                 // writable place: not followed
        w.write(c + "/" + enc + "/\(uuid).jsonl", "{\"cwd\":\"\(w.work)\"}\n")
        w.write(w.home + "/.claude.json", "{\"theme\":\"dark\",\"oauthAccount\":{\"x\":\"TWINSECRET\"}}")
    }

    func fence(_ mode: String? = nil, history: String? = nil, settings: String = "") throws -> MacFence {
        var f = try w.fence()
        f.agent = try MacAgentConfig.plan(argv: ["claude"], workdir: f.workdir, sessionFolder: f.sessionFolder, home: w.home, mode: mode,
                                          history: history, settings: DozableSettings(text: settings))
        return f
    }

    func json(_ p: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: p)))) as? [String: Any] ?? [:]
    }

    // MARK: the recipe's declaration (3.10a)

    func testClaudeCodeDeclaresItsFolder_andOnlyEmbeddedRecipesAreAsked() throws {
        let m = try XCTUnwrap(claude.launch.macConfig)
        XCTAssertEqual(m.homeEnv, "CLAUDE_CONFIG_DIR")
        XCTAssertEqual(m.home, "~/.claude")
        XCTAssertEqual(m.default, "private")
        XCTAssertEqual(AgentRecipes.macAgent(program: "/Users/x/.local/bin/claude")?.id, "claude-code")
        XCTAssertNil(AgentRecipes.macAgent(program: "sh"), "a program no embedded recipe declares has no config handling")
        XCTAssertNil(AgentRecipes.macAgent(program: "pi"), "an embedded recipe without mac_config is not an @mac agent")
    }

    func testTheShapeIsFixed() throws {
        var m = try XCTUnwrap(claude.launch.macConfig)
        func refused(_ change: (inout AgentRecipe.Launch.MacConfig) -> Void, _ what: String) {
            var x = m
            change(&x)
            XCTAssertThrowsError(try AgentRecipe.validateMacConfig(x) { SandboxError.invalidSpec($0) }, what)
        }
        XCTAssertNoThrow(try AgentRecipe.validateMacConfig(m) { SandboxError.invalidSpec($0) })
        refused({ $0.home = "~/.ssh" }, "home ~/.ssh")
        refused({ $0.home = "~/.config" }, "home ~/.config")
        refused({ $0.home = "~/Library" }, "home ~/Library (not a dot-folder)")
        refused({ $0.home = "~/.a/.b" }, "home two levels deep")
        refused({ $0.homeEnv = "PATH" }, "home_env PATH")
        refused({ $0.homeEnv = "LD_PRELOAD" }, "home_env LD_PRELOAD")
        refused({ $0.beside = ["~/.zshrc"] }, "beside another file")
        refused({ $0.transcripts.files = "*" }, "transcripts *")
        refused({ $0.transcripts.dir = "../{workdir}" }, "transcripts elsewhere")
        refused({ $0.linkReadOnly = ["../.ssh"] }, "a link out of the home")
        refused({ $0.cleanCopy[0].keys = ["apiKeyHelper"] }, "apiKeyHelper copied")
        refused({ $0.cleanCopy[0].keys = ["hooks.Stop"] }, "hooks copied")
        refused({ $0.cleanCopy[0].keys = ["env"] }, "env copied")
        refused({ $0.default = "open" }, "default open")
        m.linkReadOnly = ["projects"]
        XCTAssertThrowsError(try AgentRecipe.validateMacConfig(m) { SandboxError.invalidSpec($0) }, "the transcripts' folder linked")
    }

    func testACommunityOrPersonalRecipeCarryingItIsRefused() throws {
        // Dozable's own claude-code document under another id: everything else of it passes nothing a community recipe may
        // be — but the item that matters here is mac_config, refused on its own.
        let doc = try XCTUnwrap(AgentRecipes.embeddedDocuments.first { $0.0 == "claude-code.json" }?.1)
        let (results, _) = CommunityRequirements.check(Data(doc), others: AgentRecipes.all, dozableIDs: [])
        XCTAssertEqual(results.first { $0.id == "no-mac-config" }?.passed, false, "a recipe that is not Dozable's own may not declare mac_config")
        XCTAssertTrue(CommunityRequirements.items.contains { $0.id == "no-mac-config" })
    }

    // MARK: private (3.8)

    func testPrivate_linksSettingsFirstRunAndCloneIn() throws {
        twinClaude()
        var f = try fence()
        try MacFenceSessionFolder.prepare(f, previous: nil, person: .init())
        f.agent = try MacAgentConfig.prepare(f.agent!, fence: f)
        let a = try XCTUnwrap(f.agent)
        XCTAssertTrue(a.isPrivate)
        XCTAssertEqual(a.modeSource, "recipe")
        // settings: the allowlist only, plus keep's mapping.
        let s = json(a.agentDir + "/settings.json")
        XCTAssertEqual(Set(s.keys), ["model", "permissions", "language", "cleanupPeriodDays"], "\(s)")
        XCTAssertEqual(s["cleanupPeriodDays"] as? Int, 36500)
        XCTAssertEqual(Set((s["permissions"] as? [String: Any] ?? [:]).keys), ["allow", "deny"], "never additionalDirectories")
        XCTAssertFalse(String(decoding: try Data(contentsOf: URL(fileURLWithPath: a.agentDir + "/settings.json")), as: UTF8.self).contains("TWINSECRET"))
        // first run: onboarding done, the folder trusted, the person's theme — nothing else of ~/.claude.json.
        let c = json(a.agentDir + "/.claude.json")
        XCTAssertEqual(c["hasCompletedOnboarding"] as? Bool, true)
        XCTAssertEqual(c["theme"] as? String, "dark")
        XCTAssertEqual(((c["projects"] as? [String: Any])?[w.work] as? [String: Any])?["hasTrustDialogAccepted"] as? Bool, true)
        XCTAssertNil(c["oauthAccount"])
        // links: CLAUDE.md and skills, to the person's own; the nested links into a closed and a writable place not brought.
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: a.agentDir + "/CLAUDE.md"), w.home + "/.claude/CLAUDE.md")
        XCTAssertEqual(MacFencePaths.lstatKind(a.agentDir + "/skills"), S_IFLNK)
        XCTAssertNil(MacFencePaths.lstatKind(a.agentDir + "/agents"), "not there in the person's: nothing linked")
        XCTAssertTrue(a.readFolders.contains(w.home + "/shared-skills/two"), "a nested link to an ordinary folder is followed: \(a.readFolders)")
        XCTAssertFalse(a.readFolders.contains { $0.hasPrefix(w.home + "/.config") || $0.hasPrefix(w.work) })
        XCTAssertTrue(a.notes.contains { $0.contains("skills/gh") && $0.contains("not brought") }, "\(a.notes)")
        XCTAssertTrue(a.notes.contains { $0.contains("skills/work") && $0.contains("not brought") }, "\(a.notes)")
        XCTAssertEqual(Set(a.hostOwned), ["CLAUDE.md", "skills", "settings.json"])
        // clone-in on the first open.
        XCTAssertEqual(w.read(a.agentDir + "/" + enc + "/\(uuid).jsonl"), "{\"cwd\":\"\(w.work)\"}\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.agentDir + "/.credentials.json"))
        // agent-default: no history key.
        var g = try fence(history: "agent-default")
        g.agent = try MacAgentConfig.prepare(g.agent!, fence: g)
        XCTAssertNil(json(g.agent!.agentDir + "/settings.json")["cleanupPeriodDays"])
        XCTAssertEqual(g.agent?.historySource, "flag")
    }

    func testTheModeResolves_flagRecipeMacDefault() throws {
        XCTAssertEqual(try fence().agent?.mode, "private")
        XCTAssertEqual(try fence("shared").agent?.modeSource, "flag")
        XCTAssertEqual(try fence(settings: "[mac]\nagent_config = \"shared\"\n").agent?.mode, "shared")
        let both = try fence(settings: "[mac]\nagent_config = \"shared\"\n[recipes.anthropic.claude-code]\nmac_config = \"private\"\n").agent
        XCTAssertEqual(both?.mode, "private", "the recipe's own wins over mac.agent_config")
        XCTAssertEqual(try fence(settings: "[agent]\nhistory = \"agent-default\"\n").agent?.history, "agent-default")
        XCTAssertThrowsError(try fence("open"))
    }

    /// 3.8a: a re-open clears everything a run planted but its transcripts, and writes the settings again.
    func testReseedKeepsOnlyTranscripts() throws {
        twinClaude()
        var f = try fence()
        try MacFenceSessionFolder.prepare(f, previous: nil, person: .init())
        f.agent = try MacAgentConfig.prepare(f.agent!, fence: f)
        let d = f.agent!.agentDir
        w.write(d + "/shell-snapshots/x.sh", "evil")
        w.write(d + "/statusline.sh", "evil")
        w.write(d + "/" + enc + "/memory/x.md", "evil")
        w.write(d + "/" + enc + "/notes.txt", "evil")
        w.write(d + "/projects/other/\(uuid).jsonl", "{}\n")
        w.write(d + "/" + enc + "/11111111-2222-4333-8444-555555555555.jsonl", "{}\n")
        symlink(w.home + "/.aws/credentials", d + "/" + enc + "/22222222-2222-4333-8444-555555555555.jsonl")
        chmod(d + "/settings.json", 0o644)
        w.write(d + "/settings.json", "{\"hooks\":{}}")
        var g = try fence()
        g.agent = try MacAgentConfig.prepare(g.agent!, fence: g)
        for gone in ["/shell-snapshots", "/statusline.sh", "/\(enc)/memory", "/\(enc)/notes.txt", "/projects/other",
                     "/\(enc)/22222222-2222-4333-8444-555555555555.jsonl"] {
            XCTAssertNil(MacFencePaths.lstatKind(d + gone), "\(gone) cleared")
        }
        XCTAssertNotNil(MacFencePaths.lstatKind(d + "/" + enc + "/11111111-2222-4333-8444-555555555555.jsonl"), "its transcript kept")
        XCTAssertNil(json(d + "/settings.json")["hooks"], "settings written again")
        XCTAssertEqual(w.read(w.home + "/.aws/credentials"), "[default]\naws_secret_access_key=SECRET\n", "the link's target untouched")
    }

    func testAnAgentFolderSwappedForALinkIsNeverFollowed() throws {
        var f = try fence()
        try MacFenceSessionFolder.prepare(f, previous: nil, person: .init())
        f.agent = try MacAgentConfig.prepare(f.agent!, fence: f)
        try FileManager.default.removeItem(atPath: f.agent!.agentDir)
        symlink(w.home + "/Documents", f.agent!.agentDir)
        var g = try fence()
        g.agent = try MacAgentConfig.prepare(g.agent!, fence: g)
        XCTAssertEqual(MacFencePaths.lstatKind(g.agent!.agentDir), S_IFDIR)
        XCTAssertEqual(w.read(w.home + "/Documents/doc.txt"), "mine", "the person's Documents untouched (1.26)")
    }

    /// 3.8 under the real profile: links readable, not writable, not replaceable; the settings host-owned; ~/.claude closed.
    func testThePrivateProfileHolds() throws {
        twinClaude()
        var f = try fence()
        try MacFenceSessionFolder.prepare(f, previous: nil, person: .init())
        f.agent = try MacAgentConfig.prepare(f.agent!, fence: f)
        let p = MacFenceProfile.render(f)
        let d = f.agent!.agentDir
        XCTAssertEqual(w.sandboxed(p, ["/bin/cat", d + "/CLAUDE.md"]).code, 0, "an instruction file through its link")
        XCTAssertEqual(w.sandboxed(p, ["/bin/cat", d + "/skills/one/SKILL.md"]).code, 0, "a skill through its link")
        XCTAssertEqual(w.sandboxed(p, ["/bin/cat", d + "/skills/two/SKILL.md"]).code, 0, "a skill through a nested link that was brought")
        XCTAssertNotEqual(w.sandboxed(p, ["/bin/cat", d + "/skills/gh/hosts.yml"]).code, 0, "a nested link into ~/.config is not followed")
        XCTAssertNotEqual(w.sandboxed(p, ["/bin/sh", "-c", "echo x >> \"$1\"", "sh", d + "/CLAUDE.md"]).code, 0, "not writable through the link")
        XCTAssertNotEqual(w.sandboxed(p, ["/bin/rm", d + "/skills"]).code, 0, "a link cannot be removed")
        XCTAssertNotEqual(w.sandboxed(p, ["/bin/mv", d + "/skills", d + "/s2"]).code, 0, "a link cannot be renamed")
        XCTAssertNotEqual(w.sandboxed(p, ["/bin/sh", "-c", "echo {} > \"$1\"", "sh", d + "/settings.json"]).code, 0, "its settings are refused")
        XCTAssertNotEqual(w.sandboxed(p, ["/bin/mv", d, d + "2"]).code, 0, "the folder stays where it is")
        XCTAssertEqual(w.sandboxed(p, ["/bin/sh", "-c", "echo x > \"$1/new.txt\"", "sh", d]).code, 0, "its own files are writable")
        XCTAssertEqual(w.sandboxed(p, ["/bin/sh", "-c", "echo {} > \"$1/.claude.json\"", "sh", d]).code, 0, "its first-run file is its own")
        XCTAssertNotEqual(w.sandboxed(p, ["/bin/cat", w.home + "/.claude/settings.json"]).code, 0, "the person's ~/.claude stays closed")
        XCTAssertNotEqual(w.sandboxed(p, ["/bin/cat", w.home + "/.claude/.credentials.json"]).code, 0)
        XCTAssertNotEqual(w.sandboxed(p, ["/bin/cat", w.home + "/.claude.json"]).code, 0)
    }

    /// 3.8b: shared — the person's own folder read and written; nothing seeded; no history key ever written there.
    func testShared() throws {
        twinClaude()
        var f = try fence("shared")
        try MacFenceSessionFolder.prepare(f, previous: nil, person: .init())
        f.agent = try MacAgentConfig.prepare(f.agent!, fence: f)
        XCTAssertFalse(f.agent!.isPrivate)
        XCTAssertTrue(f.agent!.notes.contains { $0.contains("less isolated") })
        XCTAssertNil(MacFencePaths.lstatKind(f.agent!.agentDir), "nothing seeded")
        XCTAssertNil(json(w.home + "/.claude/settings.json")["cleanupPeriodDays"], "no history key in the person's own")
        let narrow = try w.fence().grants
        XCTAssertTrue(f.grants.sharedConfig == true && f.grants.widens(narrow), "shared widens the grants")
        let p = MacFenceProfile.render(f)
        XCTAssertEqual(w.sandboxed(p, ["/bin/cat", w.home + "/.claude/settings.json"]).code, 0)
        XCTAssertEqual(w.sandboxed(p, ["/bin/sh", "-c", "echo x > \"$1\"", "sh", w.home + "/.claude/new"]).code, 0, "writable")
        XCTAssertEqual(w.sandboxed(p, ["/bin/sh", "-c", "echo {} > \"$1.tmp.1\" && mv \"$1.tmp.1\" \"$1\"", "sh", w.home + "/.claude.json"]).code, 0,
                       "the file beside it, written through a temp name")
        XCTAssertNotEqual(w.sandboxed(p, ["/bin/sh", "-c", "echo x > \"$1\"", "sh", w.home + "/.zshrc"]).code, 0, "nothing else of the home")
        XCTAssertNotEqual(w.sandboxed(p, ["/bin/cat", w.home + "/.aws/credentials"]).code, 0)
    }

    func testTheEnvironmentNamesTheFolder_thePlaceholder_andTheShims() throws {
        var f = try fence()
        f.placeholders = ["CLAUDE_CODE_OAUTH_TOKEN": "doz_cred_" + String(repeating: "a", count: 48)]
        var env = ["PATH": "/usr/bin:/bin"]
        MacFenceEnvironment.add(&env, fence: f)
        XCTAssertEqual(env["CLAUDE_CONFIG_DIR"], f.sessionFolder + "/agent")
        XCTAssertEqual(env["CLAUDE_CODE_TMPDIR"], f.tmp, "its own temp, not /tmp/claude-<uid>")
        XCTAssertEqual(env["CLAUDE_CODE_OAUTH_TOKEN"]?.hasPrefix("doz_cred_"), true)
        XCTAssertEqual(env["PATH"], f.bin + ":/usr/bin:/bin")
        XCTAssertEqual(env["BROWSER"], "open", "by name — etc/bin is first on PATH")
        let s = try fence("shared")
        var e2: [String: String] = [:]
        MacFenceEnvironment.add(&e2, fence: s)
        XCTAssertNil(e2["CLAUDE_CONFIG_DIR"], "shared: the agent's own default folder")
    }

    // MARK: the shim

    func testTheOpenShimSendsOnlyTheMarker() throws {
        let f = try w.fence()
        try MacFenceSessionFolder.prepare(f, previous: nil, person: .init())
        w.write(w.work + "/doc.md", "# doc")
        w.write(w.root + "/outside.md", "# out")
        func run(_ args: [String]) -> (String, Int32) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: f.bin + "/open")
            p.arguments = args
            p.currentDirectoryURL = URL(fileURLWithPath: w.work)
            p.environment = ["PATH": "/usr/bin:/bin", "DOZ_TTY": w.root + "/tty"]
            FileManager.default.createFile(atPath: w.root + "/tty", contents: nil)
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            p.standardInput = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
            return (w.read(w.root + "/tty") ?? "", p.terminationStatus)
        }
        XCTAssertEqual(run(["https://example.com/x?state=S"]).0, "\u{1B}]6340;doz-open;https://example.com/x?state=S\u{07}")
        XCTAssertEqual(run(["doc.md"]).0, "\u{1B}]6340;doz-file;;\(w.work)/doc.md\u{07}")
        XCTAssertEqual(run(["-R", "doc.md"]).0, "\u{1B}]6340;doz-reveal;\(w.work)/doc.md\u{07}")
        let out = run([w.root + "/outside.md"])
        XCTAssertEqual(out.0, "")
        XCTAssertNotEqual(out.1, 0, "outside its folder: refused by the shim")
        XCTAssertNotEqual(run(["file:///etc/passwd"]).1, 0)
    }

    // MARK: the facts (3.7)

    func testThePromptCombines() {
        let facts = MacAgentPrompt.firstLine + "\n- facts"
        XCTAssertEqual(MacAgentPrompt.argv(["claude"], facts: facts), ["claude", "--append-system-prompt", facts])
        XCTAssertEqual(MacAgentPrompt.argv(["claude", "--append-system-prompt", "mine", "-p", "hi"], facts: facts),
                       ["claude", "--append-system-prompt", facts + "\n\nmine", "-p", "hi"])
        XCTAssertEqual(MacAgentPrompt.argv(["claude", "--append-system-prompt=a", "--append-system-prompt", "b"], facts: facts),
                       ["claude", "--append-system-prompt", facts + "\n\na\n\nb"], "every one combined (Claude Code keeps only the last)")
        XCTAssertEqual(MacAgentPrompt.argv(["claude", "--append-system-prompt", facts], facts: facts), ["claude", "--append-system-prompt", facts],
                       "a value that holds the facts gets nothing more")
        XCTAssertEqual(MacAgentPrompt.argv(["claude", "mcp", "list"], facts: facts), ["claude", "mcp", "list"], "a subcommand: unchanged")
        XCTAssertEqual(MacAgentPrompt.argv(["claude", "--system-prompt", "x"], facts: facts), ["claude", "--system-prompt", "x"], "a replaced prompt: unchanged")
        XCTAssertEqual(MacAgentPrompt.argv(["claude", "-p", "--", "--append-system-prompt"], facts: facts),
                       ["claude", "--append-system-prompt", facts, "-p", "--", "--append-system-prompt"], "nothing after -- is read")
        XCTAssertTrue(MacAgentPrompt.applies(argv: ["claude"], fenced: true, setting: "fenced"))
        XCTAssertFalse(MacAgentPrompt.applies(argv: ["claude"], fenced: false, setting: "fenced"), "unfenced: none by default")
        XCTAssertTrue(MacAgentPrompt.applies(argv: ["claude"], fenced: false, setting: "always"))
        XCTAssertFalse(MacAgentPrompt.applies(argv: ["claude"], fenced: true, setting: "off"))
        XCTAssertFalse(MacAgentPrompt.applies(argv: ["sh"], fenced: true, setting: "always"))
    }

    func testTheFactsSayWhatTheFenceIs() throws {
        var f = try fence()
        f.proxyPort = 4321
        f.presetName = "standard"
        f.localPorts = [8765]
        let t = MacAgentPrompt.facts(fence: f, agent: f.agent, workdir: f.workdir)
        XCTAssertTrue(t.hasPrefix(MacAgentPrompt.firstLine))
        for want in ["FENCED", "Keychain is closed", "Dozable's proxy", "localhost:8765", "Bridges:", "sudo", "CLAUDE_CONFIG_DIR"] {
            XCTAssertTrue(t.contains(want), "\(want) in:\n\(t)")
        }
        f.bridges = MacFenceBridges(openURL: false, openFiles: false, clipboard: false)
        XCTAssertTrue(MacAgentPrompt.openLine(f).contains("none"))
    }

    // MARK: capabilities (one source)

    func testCapabilities() throws {
        var r = MacSessionRecord(argv: ["claude"], workdir: w.work, environmentKeys: nil, openedAt: Date())
        let unfenced = MacFence.capabilities(MacCapabilityShape(session: "s", record: r, home: w.home))
        XCTAssertEqual(unfenced.first { $0.id == "fence" }?.state, "no isolation")
        XCTAssertEqual(unfenced.first { $0.id == "keychain" }?.state, "open")
        var f = try fence("shared")
        f.account = "mac"
        f.proxyPort = 1
        r.fence = f.record(profileSHA256: "x", gitBaseline: nil)
        r.fence?.policy = try MacFenceNetwork.policy(words: ["standard"])
        let c = MacFence.capabilities(MacCapabilityShape(session: "s", record: r, home: w.home))
        XCTAssertEqual(c.map(\.id), ["fence", "keychain", "network", "agent-config", "history", "claude-login", "github", "ssh-agent",
                                     "open-url", "open-files", "clipboard", "writable", "readable"])
        XCTAssertEqual(c.first { $0.id == "agent-config" }?.state, "shared (less isolated)")
        XCTAssertEqual(c.first { $0.id == "claude-login" }?.state, "swapped in (account mac)")
        XCTAssertEqual(c.first { $0.id == "open-url" }?.editable, "live")
        XCTAssertEqual(c.first { $0.id == "keychain" }?.editable, "restart")
        XCTAssertTrue(MacFence.capabilitiesText(c).contains("Agent config"))
    }
}

/// `MacTranscripts`: carried back safely, only conversations (3.9, 3.9c, 3.9d).
final class MacTranscriptsTests: XCTestCase {
    var w: FenceScratch!
    override func setUpWithError() throws { w = try FenceScratch() }
    override func tearDown() { w.remove() }
    let u1 = "0b1c2d3e-4f50-4a6b-8c7d-8e9fa0b1c2d3", u2 = "1b1c2d3e-4f50-4a6b-8c7d-8e9fa0b1c2d3"
    var rel: String { "projects/" + MacPlace.claudeProjectFolderName(w.work) }
    var agent: String { w.root + "/sess/agent" }
    var person: String { w.home + "/.claude" }
    func line(_ s: String = "hi") -> String { "{\"type\":\"user\",\"cwd\":\"\(w.work)\",\"text\":\"\(s)\"}\n" }
    func carry(archive: String? = nil, already: Set<String> = []) -> MacTranscripts.Outcome {
        MacTranscripts.carryBack(agentDir: agent, personHome: person, folder: rel, workdir: w.work, tag: "t1", archive: archive, already: already)
    }

    func testNames_andContent() {
        XCTAssertTrue(MacTranscripts.isTranscriptName(u1 + ".jsonl"))
        XCTAssertFalse(MacTranscripts.isTranscriptName("notes.jsonl"))
        XCTAssertFalse(MacTranscripts.isTranscriptName(u1.uppercased() + ".jsonl"))
        XCTAssertFalse(MacTranscripts.isTranscriptName("../" + u1 + ".jsonl"))
        XCTAssertNil(MacTranscripts.contentProblem(Data((line() + line("b")).utf8), workdir: w.work))
        XCTAssertNotNil(MacTranscripts.contentProblem(Data("not json\n".utf8), workdir: w.work))
        XCTAssertNotNil(MacTranscripts.contentProblem(Data("[1]\n".utf8), workdir: w.work))
        XCTAssertNotNil(MacTranscripts.contentProblem(Data("{\"cwd\":\"/elsewhere\"}\n".utf8), workdir: w.work))
    }

    func testOnlyConversationsAreCarried_andArchivedUnderKeep() throws {
        let d = agent + "/" + rel
        w.write(d + "/\(u1).jsonl", line())
        w.write(d + "/memory/x.md", "memory")
        w.write(agent + "/todos/y.json", "{}")
        w.write(d + "/notes.jsonl", line())
        w.write(d + "/\(u2).jsonl", "not json\n")
        w.write(d + "/2b1c2d3e-4f50-4a6b-8c7d-8e9fa0b1c2d3.jsonl", "{\"cwd\":\"/elsewhere\"}\n")
        w.write(d + "/3b1c2d3e-4f50-4a6b-8c7d-8e9fa0b1c2d3/x.jsonl", line())
        symlink(w.home + "/.aws/credentials", d + "/4b1c2d3e-4f50-4a6b-8c7d-8e9fa0b1c2d3.jsonl")
        mkfifo(d + "/5b1c2d3e-4f50-4a6b-8c7d-8e9fa0b1c2d3.jsonl", 0o600)
        let big = d + "/6b1c2d3e-4f50-4a6b-8c7d-8e9fa0b1c2d3.jsonl"
        FileManager.default.createFile(atPath: big, contents: nil)
        truncate(big, 65 << 20)
        w.write(w.home + "/secret.txt", line())
        link(w.home + "/secret.txt", d + "/7b1c2d3e-4f50-4a6b-8c7d-8e9fa0b1c2d3.jsonl")
        let archive = w.store + "/transcripts/s/20261113T000000Z"
        let o = carry(archive: archive)
        XCTAssertEqual(o.carried, [u1 + ".jsonl"], "\(o)")
        XCTAssertEqual(o.archived, [u1 + ".jsonl"])
        XCTAssertEqual(w.read(person + "/" + rel + "/\(u1).jsonl"), line())
        XCTAssertEqual(w.read(archive + "/\(u1).jsonl"), line())
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: person + "/" + rel))
        XCTAssertEqual(names, [u1 + ".jsonl"], "nothing else carried — no memory/, no todos")
        XCTAssertNil(MacFencePaths.lstatKind(person + "/todos"))
        XCTAssertEqual(o.skipped.count, 9, "\(o.skipped)")
        for n in ["memory/", "notes.jsonl", u2, "2b1c", "3b1c", "4b1c", "5b1c", "6b1c", "7b1c"] {
            XCTAssertTrue(o.skipped.contains { $0.contains(n) }, "\(n) named: \(o.skipped)")
        }
        let s = MacAgentConfigTestsSupport.setup(w, history: "keep")
        let m = MacTranscripts.message(o, setup: s, session: "s") ?? ""
        XCTAssertTrue(m.contains("written by a fenced session") && m.contains("archive"), m)
        // Again: nothing done twice.
        let again = carry(archive: archive + "x", already: Set(o.done))
        XCTAssertTrue(again.carried.isEmpty && again.archived.isEmpty)
        XCTAssertNil(MacFencePaths.lstatKind(archive + "x"))
        // agent-default: the vendor's own rule said.
        let d2 = MacTranscripts.message(o, setup: MacAgentConfigTestsSupport.setup(w, history: "agent-default"), session: "s") ?? ""
        XCTAssertTrue(d2.contains("older than 30 days"), d2)
    }

    func testAGrownCopyReplacesItsPrefix_aDifferentOneIsKeptBeside() throws {
        let d = agent + "/" + rel
        w.write(person + "/" + rel + "/\(u1).jsonl", line("a"))
        w.write(d + "/\(u1).jsonl", line("a") + line("b"))
        w.write(person + "/" + rel + "/\(u2).jsonl", line("mine"))
        w.write(d + "/\(u2).jsonl", line("theirs"))
        let o = carry()
        XCTAssertEqual(o.carried, [u1 + ".jsonl"])
        XCTAssertEqual(w.read(person + "/" + rel + "/\(u1).jsonl"), line("a") + line("b"))
        XCTAssertEqual(o.renamed, ["\(u2).doz-t1.jsonl"])
        XCTAssertEqual(w.read(person + "/" + rel + "/\(u2).jsonl"), line("mine"), "the person's own kept")
    }

    func testALinkedDestinationIsRefused() throws {
        w.write(agent + "/" + rel + "/\(u1).jsonl", line())
        try FileManager.default.createDirectory(atPath: w.home + "/Documents", withIntermediateDirectories: true)
        symlink(w.home + "/Documents", person)
        let o = carry()
        XCTAssertNotNil(o.refused)
        XCTAssertFalse(FileManager.default.fileExists(atPath: w.home + "/Documents/projects"), "nothing written through the link")
    }
}

enum MacAgentConfigTestsSupport {
    static func setup(_ w: FenceScratch, history: String) -> MacAgentSetup {
        let r = AgentRecipes.recipe("claude-code")!
        return MacAgentSetup(recipe: r.id, title: r.title, config: r.launch.macConfig!, mode: "private", modeSource: "recipe", history: history,
                             historySource: "default", agentDefault: r.launch.history?.agentDefault, historyMap: r.launch.history,
                             personHome: w.home + "/.claude", personBeside: nil, agentDir: w.root + "/sess/agent")
    }
}
