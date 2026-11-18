import ArgumentParser
import Foundation
@testable import DozableKit
import XCTest
@testable import DozableCLI
@testable import DozableHost
@testable import DozableWeb

/// 0.51: what a sandbox or a session works on is its FOLDER — never "workspace" or "workdir" in a flag, a `--json` key,
/// a web field or route, a setting, a project key or a placeholder. `/workspace` inside a sandbox keeps its name, and so
/// do the store's own files (an older doz reads them). In-process host, no VM: a lab create never boots.
final class FolderRenameTests: XCTestCase {
    private var root: URL!
    private var projects: URL!
    private var xdg: URL!
    let keychain = FakeKeychain()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("doz-folder-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Outside the store and the system locations ($TMPDIR is under /private/var).
        projects = URL(fileURLWithPath: "/tmp/doz-folder-projects-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        xdg = root.appendingPathComponent("xdg")
        try FileManager.default.createDirectory(at: xdg.appendingPathComponent("doz"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: projects)
    }

    private func parse(_ args: [String]) throws -> ParsableCommand { try DozableCommand.parseAsRoot(args) }

    // MARK: the flags

    /// Every old flag still FAILS as an unknown option (exit 64), and the message gains one hint naming the new flag.
    func testTheOldFlagsFailWithAHint() {
        let cases: [([String], String)] = [
            (["create", "b", "--image", "lab", "--workspace", "/tmp/w"], "--folder DIR"),
            (["up", "b", "--workspace", "/tmp/w"], "--folder DIR"),
            (["try", "grok", "--workspace", "/tmp/w"], "--folder DIR"),
            (["new", "--workspace", "/tmp/w"], "--folder DIR"),
            (["duplicate", "a", "b", "--workspace", "/tmp/w"], "--folder DIR"),
            (["create", "b", "--image", "lab", "--workspace-view", "off"], "--folder-view on|off"),
            (["up", "b", "--workspace-view", "off"], "--folder-view on|off"),
            (["run", "@mac", "--workdir", "/tmp", "--", "sh"], "--folder DIR on doz run @mac, --cwd DIR in a sandbox"),
            (["run", "box", "--workdir", "/work", "--", "sh"], "--cwd DIR in a sandbox"),
            (["exec", "box", "--workdir", "/work", "--", "sh"], "--cwd DIR in a sandbox"),
        ]
        for (argv, hint) in cases {
            XCTAssertThrowsError(try parse(argv), argv.joined(separator: " ")) { e in
                XCTAssertEqual(DozableCommand.exitCode(for: e).rawValue, 64, argv.joined(separator: " "))
                let plain = DozableCommand.fullMessage(for: e)
                XCTAssertTrue(plain.contains("Unknown option"), plain)
                let said = RenamedNames.withOptionHint(plain)
                XCTAssertTrue(said.contains("was renamed: ") && said.contains(hint), said)
                XCTAssertEqual(said.components(separatedBy: "\n").count, plain.components(separatedBy: "\n").count, "the hint is on the error's own line")
            }
        }
        // Another unknown option gets no hint.
        XCTAssertNil(RenamedNames.optionHint("Error: Unknown option '--bogus'"))
        XCTAssertEqual(RenamedNames.withOptionHint("Error: Unknown option '--bogus'"), "Error: Unknown option '--bogus'")
        // `--workspace-view` is not mistaken for `--workspace`.
        XCTAssertEqual(RenamedNames.optionHint("Error: Unknown option '--workspace-view'"), "--workspace-view was renamed: --folder-view on|off")
    }

    /// The new flags parse and reach the request.
    func testTheNewFlags() throws {
        let c = try XCTUnwrap(try parse(["create", "b", "--image", "lab", "--folder", "/tmp/w", "--folder-view", "off"]) as? Create)
        XCTAssertEqual(c.create.folder, "/tmp/w")
        XCTAssertEqual(c.create.folderView, "off")
        let o = try c.create.options()
        XCTAssertEqual(o.folder, "/tmp/w")
        XCTAssertEqual(o.settings?[SettingKey.workspaceView], .string("off"))
        XCTAssertEqual(SettingKey.workspaceView, "folder.view")
        XCTAssertEqual(SettingKey.ignoreMode, "folder.ignore_mode")
        let up = try XCTUnwrap(try parse(["up", "b", "--folder", "/tmp/w"]) as? Up)
        XCTAssertEqual(up.create.folder, "/tmp/w")
        let d = try XCTUnwrap(try parse(["duplicate", "a", "b", "--folder", "/tmp/w"]) as? Duplicate)
        XCTAssertEqual(d.folder, "/tmp/w")
        let r = try XCTUnwrap(try parse(["run", "box", "--cwd", "/work", "--", "sh"]) as? Run)
        XCTAssertEqual(r.cwd, "/work")
        XCTAssertNil(r.folder)
        let m = try XCTUnwrap(try parse(["run", "@mac", "--folder", "/tmp", "--", "sh"]) as? Run)
        XCTAssertEqual(m.folder, "/tmp")
        XCTAssertNil(m.cwd)
        let e = try XCTUnwrap(try parse(["exec", "box", "--cwd", "/work", "--", "sh"]) as? Exec)
        XCTAssertEqual(e.cwd, "/work")
        XCTAssertThrowsError(try parse(["exec", "box", "--folder", "/work", "--", "sh"]), "exec runs in a sandbox: --cwd, never --folder")
        // exec's deadline scan skips --cwd's value (it would read the folder as the command otherwise).
        XCTAssertTrue(ExecDeadline.execValued.contains("--cwd"))
        XCTAssertFalse(ExecDeadline.execValued.contains("--workdir"))
    }

    // MARK: the store's own files keep their keys

    /// A store written by 0.50.x loads unchanged — its sandbox record (`workspace`), a sandbox's session records
    /// (`workdir`, a guest cwd) and the sessions on this Mac (`workdir`, the session's folder) — and writing them again
    /// keeps those keys: an older doz must still read a newer one's store (a missing `workspace` would read as ISOLATED).
    func testA050StoreLoadsAndKeepsItsKeys() throws {
        let dir = Pins.packageRoot.appendingPathComponent("Tests/Fixtures/store-0.50")
        let cfgData = try Data(contentsOf: dir.appendingPathComponent("doz.json"))
        let cfg = try HostWire.decoder.decode(SandboxConfig.self, from: cfgData)
        XCTAssertEqual(cfg.name, "fixture")
        XCTAssertEqual(cfg.workspace, "/tmp/doz-fixture-folder", "the shared folder is read from `workspace`")
        let again = try JSONSerialization.jsonObject(with: HostWire.prettyEncoder.encode(cfg)) as? [String: Any]
        XCTAssertEqual(again?["workspace"] as? String, "/tmp/doz-fixture-folder", "written back under `workspace`")
        XCTAssertNil(again?["folder"])

        let sessData = try Data(contentsOf: dir.appendingPathComponent("sessions.json"))
        let sess = try HostWire.decoder.decode(SessionRecords.self, from: sessData)
        XCTAssertEqual(sess.sessions["claude"]?.workdir, "/workspace/sub")
        let sessAgain = try JSONSerialization.jsonObject(with: HostWire.prettyEncoder.encode(sess)) as? [String: Any]
        XCTAssertEqual(((sessAgain?["sessions"] as? [String: Any])?["claude"] as? [String: Any])?["workdir"] as? String, "/workspace/sub")

        let macData = try Data(contentsOf: dir.appendingPathComponent("mac-sessions.json"))
        let mac = try HostWire.decoder.decode(MacSessionRecords.self, from: macData)
        XCTAssertEqual(mac.sessions["build"]?.workdir, "/tmp/doz-fixture-folder")
        let macAgain = try JSONSerialization.jsonObject(with: HostWire.prettyEncoder.encode(mac)) as? [String: Any]
        XCTAssertEqual(((macAgain?["sessions"] as? [String: Any])?["build"] as? [String: Any])?["workdir"] as? String, "/tmp/doz-fixture-folder")

        // And what the daemon SHOWS of that session says `folder`.
        var row = SessionRow(SessionInfo(name: "build", command: "sh"))
        row.folder = mac.sessions["build"]?.workdir
        let shown = try JSONSerialization.jsonObject(with: HostWire.encoder.encode(row)) as? [String: Any]
        XCTAssertEqual(shown?["folder"] as? String, "/tmp/doz-fixture-folder")
    }

    /// A sandbox made by THIS doz still writes `workspace` in its doz.json.
    func testANewStoreStillWritesTheOldKeys() async throws {
        let c = await core()
        try await create(c, "kept", folder: projects.path)
        let text = try String(contentsOf: store.configFile("kept"), encoding: .utf8)
        XCTAssertTrue(text.contains("\"workspace\" : \"\(projects.path)\""), text)
        XCTAssertFalse(text.contains("\"folder\""), text)
    }

    // MARK: no key of what is shown says workspace or workdir

    /// The recursive key scan: every `--json` / web shape a sandbox, a plan, a session or the rules come in carries no key
    /// containing "workspace" or "workdir" — a guard against one missed. 0.52: exactly the key `workspace` holding a string
    /// (the workspace a sandbox or session was adopted into — the new unit) is allowed; `workspaceCreated`,
    /// `workspaceRules`, `workspaceView` and any `workdir` are still refused. Exempt: `doz show`'s `spec` (the engine's own
    /// record of the VM, persisted in doz.json and part of the image keys: `spec.imageSpec.workdir` is the guest
    /// image's cwd, `/workspace`).
    func testNoShownKeySaysWorkspaceOrWorkdir() async throws {
        // A shared folder with rules, so `folderRules` is filled.
        try Data("secret.env\n".utf8).write(to: projects.appendingPathComponent(".dozignore"))
        let c = await core()
        var r = HostRequest(.create, name: "shown")
        r.create = CreateOptions(image: "lab", folder: projects.path)
        let made = await c.handle(r)
        XCTAssertNil(made.error, made.error?.message ?? "")
        // Adopted into a workspace, so `ls` carries the one allowed key.
        var nw = HostRequest(.workspaceNew)
        nw.workspaceRequest = WorkspaceRequest(name: "demo")
        nw.workspaceRequest?.brief = "b"
        nw.workspaceRequest?.adopt = ["shown"]
        let wsMade = await c.handle(nw)
        XCTAssertNil(wsMade.error, wsMade.error?.message ?? "")
        var shapes: [(String, JSONValue)] = [("create", try XCTUnwrap(made.result))]
        let ls = await c.handle(HostRequest(.ls))
        shapes.append(("ls", try XCTUnwrap(ls.result)))
        let infos = try XCTUnwrap(ls.result).decode([SandboxInfo].self)
        let info = try XCTUnwrap(infos.first { $0.name == "shown" })
        XCTAssertEqual(info.folder, projects.path)
        XCTAssertEqual(info.workspace, "demo")
        XCTAssertNotNil(info.folderRules, "a .dozignore: the rules are said")
        let inspect = await c.handle(HostRequest(.inspect, name: "shown"))
        shapes.append(("inspect", try XCTUnwrap(inspect.result)))
        var rules = HostRequest(.workspaceRules, name: "shown")
        rules.warnings = true
        rules.paths = ["secret.env"]
        let rep = await c.handle(rules)
        XCTAssertNil(rep.error, rep.error?.message ?? "")
        shapes.append(("ignore", try XCTUnwrap(rep.result)))
        var plan = HostRequest(.plan)
        plan.planRequest = PlanRequest(purpose: "create", name: "planned", create: CreateOptions(image: "lab", folder: projects.path))
        let p = await c.handle(plan)
        XCTAssertNil(p.error, p.error?.message ?? "")
        shapes.append(("up --dry-run", try XCTUnwrap(p.result)))
        // A session on this Mac, as `doz sessions @mac --json` and the web show it.
        var row = SessionRow(SessionInfo(name: "s", pid: 1, command: "sh"))
        row.folder = projects.path
        shapes.append(("sessions @mac", try JSONValue(encoding: [row])))
        shapes.append(("web mac session", try JSONValue(encoding: WebMacSession(row))))
        // The web's own shapes of a sandbox.
        shapes.append(("web sandbox", try JSONValue(encoding: WebSandboxRow(info))))
        let detail = try XCTUnwrap(inspect.result).decode(SandboxDetail.self)
        shapes.append(("web sandbox detail", try JSONValue(encoding: WebSandboxDetail(detail, attachCommand: "doz attach shown"))))
        shapes.append(("quick add", try JSONValue(encoding: QuickAddPlan(name: "q", image: "lab", folder: projects.path, projectsDir: projects.path))))
        shapes.append(("settings", try JSONValue(encoding: DozableSettings(text: "").report())))
        for (what, v) in shapes {
            let bad = Self.keys(v, path: "").filter { k in
                if k.hasSuffix(".workspace"), Self.isString(v, k) { return false }
                let l = k.lowercased()
                return (l.contains("workspace") || l.contains("workdir")) && !k.hasPrefix(".spec.") && !k.hasPrefix(".info.spec.") && !k.contains(".spec.imageSpec.")
            }
            XCTAssertEqual(bad, [], "\(what): keys that still say workspace or workdir")
        }
    }

    /// Whether every value at `path` (a `keys` path) is a string.
    static func isString(_ v: JSONValue, _ path: String) -> Bool {
        func at(_ v: JSONValue, _ parts: ArraySlice<String>) -> [JSONValue] {
            guard let p = parts.first else { return [v] }
            if p.hasSuffix("[]") {
                let name = String(p.dropLast(2))
                let inner = name.isEmpty ? [v] : (v[name].map { [$0] } ?? [])
                return inner.flatMap { x -> [JSONValue] in if case .array(let a) = x { return a.flatMap { at($0, parts.dropFirst()) } }; return [] }
            }
            return v[p].map { at($0, parts.dropFirst()) } ?? []
        }
        let found = at(v, path.split(separator: ".", omittingEmptySubsequences: true).map(String.init)[...])
        return !found.isEmpty && found.allSatisfy { $0.stringValue != nil }
    }

    func testTheKeyScanAllowsOnlyAWorkspaceString() {
        let ok: JSONValue = .array([.object(["name": .string("a"), "workspace": .string("demo")])])
        XCTAssertTrue(Self.keys(ok, path: "").filter { $0.hasSuffix(".workspace") }.allSatisfy { Self.isString(ok, $0) })
        let bad: JSONValue = .array([.object(["workspace": .object(["x": .null])])])
        XCTAssertFalse(Self.isString(bad, "[].workspace"))
    }

    static func keys(_ v: JSONValue, path: String) -> [String] {
        switch v {
        case .object(let o): return o.flatMap { k, x in [path + "." + k] + keys(x, path: path + "." + k) }
        case .array(let a): return a.flatMap { keys($0, path: path + "[]") }
        default: return []
        }
    }

    // MARK: the settings file, the project file, the placeholders

    /// No alias: a doz.toml line under an old key is NOT read (its default applies), is kept as it was, and is said —
    /// naming the new key — in the file's warnings, and to every command (`renamedLines`).
    func testAnOldSettingsKeyIsNamedNeverRead() throws {
        let text = "[workspace]\nignore_mode = \"hide\"\nview = \"off\"\n"
        let s = DozableSettings(text: text)
        XCTAssertEqual(s.string(SettingKey.ignoreMode), "lock", "never silently honoured: the default applies")
        XCTAssertEqual(s.string(SettingKey.workspaceView), "on")
        XCTAssertEqual(s.renamedLines.count, 2, s.renamedLines.joined(separator: "\n"))
        XCTAssertTrue(s.renamedLines[0].contains("workspace.ignore_mode was renamed folder.ignore_mode"), s.renamedLines[0])
        XCTAssertTrue(s.renamedLines[1].contains("workspace.view was renamed folder.view"), s.renamedLines[1])
        XCTAssertTrue(s.warnings.contains { $0.contains("line 2: workspace.ignore_mode was renamed folder.ignore_mode — this line is not read") }, s.warnings.joined(separator: "\n"))
        XCTAssertFalse(s.warnings.contains { $0.contains("unknown setting workspace.") }, "named as renamed, not as unknown")
        // The Settings page's report carries the same warnings.
        XCTAssertTrue(s.report().warnings.contains { $0.contains("folder.ignore_mode") })
        // Never silently dropped: a write keeps the old lines (under "not known to this version").
        let rendered = DozableSettings.render(values: [:], unknown: s.unknown)
        XCTAssertTrue(rendered.contains("[workspace]\nignore_mode = \"hide\""), rendered)
        // Once the person has set the NEW name, the old line is finished with: the next write leaves it out, so
        // its warning stops. The other old line (no new value yet) stays.
        let moved = DozableSettings.render(values: ["folder.ignore_mode": .string("hide")], unknown: s.unknown)
        XCTAssertFalse(moved.contains("[workspace]\nignore_mode"), moved)
        XCTAssertTrue(moved.contains("[workspace]\nview = \"off\""), moved)
        XCTAssertEqual(DozableSettings(text: moved).renamedLines.count, 1, "only the line not yet moved is still said")
        let both = DozableSettings.render(values: ["folder.ignore_mode": .string("hide"), "folder.view": .string("off")], unknown: s.unknown)
        XCTAssertFalse(both.contains("[workspace]"), both)
        XCTAssertEqual(DozableSettings(text: both).renamedLines, [])
        // The new key is read.
        XCTAssertEqual(DozableSettings(text: "[folder]\nignore_mode = \"hide\"\n").string(SettingKey.ignoreMode), "hide")
        XCTAssertEqual(DozableSettings(text: "[folder]\nignore_mode = \"hide\"\n").renamedLines, [])
        // doz config set under the old name is refused with the new one.
        XCTAssertThrowsError(try DozableSettings(text: "", url: xdg.appendingPathComponent("doz/doz.toml")).writing("workspace.ignore_mode", .string("hide"))) { e in
            XCTAssertTrue((e as? SettingsError)?.message.contains("it was renamed folder.ignore_mode") == true, "\(e)")
        }
    }

    /// doz_project.yaml: `workspace_view` is an unknown key whose error names `folder_view`.
    func testAnOldProjectKeyIsAnError() throws {
        XCTAssertThrowsError(try DozableProject.parse("name: a\nimage: lab\nworkspace_view: off\n")) { e in
            XCTAssertTrue("\(e.localizedDescription)".contains("unknown key workspace_view — it was renamed folder_view"), e.localizedDescription)
        }
        let p = try DozableProject.parse("name: a\nimage: lab\nfolder_view: off\n")
        XCTAssertEqual(p.settings[SettingKey.workspaceView], .string("off"))
    }

    /// The agent prompt: `{{folder.*}}`; a template that still says `{{workspace.*}}` fails by name — never blank.
    func testTheOldPlaceholdersFailByName() throws {
        let v = AgentPrompt.values(name: "x", image: "claude-code", cpus: 2, memoryMiB: 2048, workspace: "/Users/me/x", network: .none, account: nil, version: "1")
        XCTAssertEqual(v["folder.host_path"], "/Users/me/x")
        XCTAssertEqual(v["folder.guest_path"], "/workspace", "the guest path keeps its name")
        XCTAssertNil(v["workspace.host_path"])
        XCTAssertThrowsError(try AgentPrompt.render("At {{workspace.host_path}}.", v, source: "agent-prompt.md")) { e in
            XCTAssertTrue((e as? AgentPromptError)?.message.contains("{{workspace.host_path}} is not a variable — it was renamed {{folder.host_path}}") == true, "\(e)")
        }
        XCTAssertEqual(try AgentPrompt.render("At {{folder.host_path}}.", v, source: "agent-prompt.md"), "At /Users/me/x.")
        XCTAssertTrue(AgentPrompt.variables.allSatisfy { !$0.name.hasPrefix("workspace.") })
    }

    // MARK: the protocol

    /// A request of the old protocol is refused by this daemon with "version"; one of a NEWER protocol too; ping and
    /// host-stop are answered whatever the protocol (a doz of either side can see and stop the other's daemon). The CLI's
    /// words say which build runs and what to do.
    func testTheProtocolStep() async throws {
        XCTAssertEqual(HostProtocol.version, 3)
        XCTAssertEqual(HostProtocol.minimum, 3)
        XCTAssertEqual(HostRequest(.ls).v, 3)
        let c = await core()
        for v in [1, 2, 4] {
            var r = HostRequest(.create, name: "old")
            r.v = v
            r.create = CreateOptions(image: "lab")
            let m = await c.handle(r)
            XCTAssertEqual(m.error?.code, .version, "v\(v)")
            XCTAssertNil(SandboxConfig.read(store.configFile("old")), "v\(v): nothing made — never an isolated sandbox")
        }
        for op in [HostOp.ping, .hostStop] {
            var r = HostRequest(op)
            r.v = 1
            XCTAssertNil(HostProtocol.refusal(r), "\(op) answers any protocol")
        }
        // What an older daemon (protocol 2: it answers v ≤ 2) does with this doz's request: refuses it, and the refusal is
        // what the CLI turns into its words.
        let older = HostRequest(.create)
        XCTAssertTrue(older.v > 2, "this doz's requests are refused by a protocol-2 daemon")
        XCTAssertEqual(HostProtocol.skewMessage(daemon: "0.50.9", this: "0.51.0"),
                       "the running daemon is 0.50.9, this doz is 0.51.0: doz daemon stop (the next command starts the new one)")
    }

    // MARK: helpers

    var store: DozableStore { DozableStore(root: root) }

    func core() async -> HostCore {
        let s = CredentialServices(keychain: keychain, verifier: FakeVerifier(answer: .verified), claudeBinary: { nil }, home: root,
                                   keepaliveRunner: FakeRunner(), isClaudeRunning: { false }, watchInterval: .seconds(3600))
        let c = HostCore(store: store, readOnly: false, version: "test", services: s)
        await c.load()
        return c
    }

    func create(_ c: HostCore, _ name: String, folder: String?) async throws {
        var r = HostRequest(.create, name: name)
        r.create = CreateOptions(image: "lab", folder: folder)
        let m = await c.handle(r)
        XCTAssertNil(m.error, m.error?.message ?? "")
    }
}
