import XCTest
@testable import DozableKit
@testable import DozableHost

/// 674: keeping an agent's conversations — the recipe's `launch@1 history.keep` is a python3 script the sandbox runs ONCE in
/// its guest set-up (never baked, never at a session open), remembered by a marker. The script and the once-only layer run
/// here on temp files, as `RecipeEachRunTests` runs the launcher's.
final class AgentHistoryTests: XCTestCase {
    typealias History = AgentRecipe.Launch.History

    func history(file: String = "~/.claude/settings.json", set: [String: RecipeValue] = ["cleanupPeriodDays": .number(36500)]) -> History {
        History(keep: [.init(file: file, set: set)], agentDefault: "the agent deletes conversations older than 30 days",
                source: "https://example.com/docs#x", checked: "2026-11-04")
    }

    /// A scratch HOME; `run()` executes the script there and returns what it printed.
    private func scratchHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("agenthistory-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        return home
    }

    @discardableResult
    private func run(_ h: History, in home: URL, value: String = AgentHistory.keep) throws -> String {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else { throw XCTSkip("no python3") }
        let script = try XCTUnwrap(AgentHistory.script(h, value: value))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = ["-c", script]
        p.environment = ["HOME": home.path]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
        return String(decoding: data, as: UTF8.self)
    }

    private func json(_ home: URL, _ path: String = ".claude/settings.json") throws -> [String: Any] {
        let data = try Data(contentsOf: home.appendingPathComponent(path))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func write(_ text: String, _ home: URL, _ path: String = ".claude/settings.json") throws {
        let url = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func testKeepWritesAnAbsentKey() throws {
        let home = try scratchHome()
        try write(#"{"theme": "dark", "env": {"A": "1"}}"#, home)
        try run(history(), in: home)
        let c = try json(home)
        XCTAssertEqual(c["cleanupPeriodDays"] as? Int, 36500)
        XCTAssertEqual(c["theme"] as? String, "dark", "what was there stays")
        XCTAssertEqual((c["env"] as? [String: Any])?["A"] as? String, "1")
    }

    func testKeepLeavesThePersonsOwnValue() throws {
        let home = try scratchHome()
        try write(#"{"cleanupPeriodDays": 7}"#, home)
        let before = try Data(contentsOf: home.appendingPathComponent(".claude/settings.json"))
        try run(history(), in: home)
        XCTAssertEqual(try json(home)["cleanupPeriodDays"] as? Int, 7)
        XCTAssertEqual(try Data(contentsOf: home.appendingPathComponent(".claude/settings.json")), before, "not even rewritten")
    }

    func testKeepNeverWritesAFileThatDoesNotParse() throws {
        let home = try scratchHome()
        let broken = "{ \"theme\": \"dark\", // a hand edit that is not JSON\n"
        try write(broken, home)
        let out = try run(history(), in: home)
        XCTAssertEqual(try String(contentsOf: home.appendingPathComponent(".claude/settings.json"), encoding: .utf8), broken)
        XCTAssertTrue(out.contains("note: ") && out.contains("does not parse"), out)
        // A JSON file that is not an object is left too.
        try write("[1, 2]", home)
        try run(history(), in: home)
        XCTAssertEqual(try String(contentsOf: home.appendingPathComponent(".claude/settings.json"), encoding: .utf8), "[1, 2]")
        // No temp file is left behind.
        let left = try FileManager.default.contentsOfDirectory(atPath: home.appendingPathComponent(".claude").path)
        XCTAssertEqual(left, ["settings.json"])
    }

    func testKeepCreatesAMissingFile0600() throws {
        let home = try scratchHome()
        try run(history(), in: home)
        XCTAssertEqual(try json(home)["cleanupPeriodDays"] as? Int, 36500)
        let attrs = try FileManager.default.attributesOfItem(atPath: home.appendingPathComponent(".claude/settings.json").path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let folder = try FileManager.default.attributesOfItem(atPath: home.appendingPathComponent(".claude").path)
        XCTAssertEqual((folder[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testKeepIsIdempotentAndLeavesMtime() throws {
        let home = try scratchHome()
        try run(history(), in: home)
        let url = home.appendingPathComponent(".claude/settings.json")
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
        let before = try Data(contentsOf: url)
        try run(history(), in: home)
        try run(history(), in: home)
        XCTAssertEqual(try Data(contentsOf: url), before)
        let m = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        XCTAssertEqual(m, old, "nothing changed, so nothing was rewritten")
        // An existing file keeps its own mode when a key is added.
        try write(#"{"a": 1}"#, home, ".claude/other.json")
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: home.appendingPathComponent(".claude/other.json").path)
        try run(history(file: "~/.claude/other.json"), in: home)
        let mode = try FileManager.default.attributesOfItem(atPath: home.appendingPathComponent(".claude/other.json").path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o640)
        XCTAssertEqual(try json(home, ".claude/other.json")["cleanupPeriodDays"] as? Int, 36500)
    }

    func testNestedDottedKey() throws {
        let home = try scratchHome()
        let h = history(file: "~/.gemini/settings.json", set: ["general.sessionRetention.enabled": .bool(false), "general.sessionRetention.maxAge": .string("3650d")])
        try write(#"{"general": {"vimMode": true, "sessionRetention": {"maxAge": "30d"}}}"#, home, ".gemini/settings.json")
        try run(h, in: home)
        let general = try XCTUnwrap(try json(home, ".gemini/settings.json")["general"] as? [String: Any])
        let r = try XCTUnwrap(general["sessionRetention"] as? [String: Any])
        XCTAssertEqual(r["enabled"] as? Bool, false, "an absent key under an existing object is set (false is a value)")
        XCTAssertEqual(r["maxAge"] as? String, "30d", "a present one is the person's")
        XCTAssertEqual(general["vimMode"] as? Bool, true)
        // Made from nothing: every level.
        let fresh = try scratchHome()
        try run(h, in: fresh)
        let made = try XCTUnwrap(((try json(fresh, ".gemini/settings.json")["general"]) as? [String: Any])?["sessionRetention"] as? [String: Any])
        XCTAssertEqual(made["enabled"] as? Bool, false)
        XCTAssertEqual(made["maxAge"] as? String, "3650d")
        // A parent that is not an object stops that key only.
        let odd = try scratchHome()
        try write(#"{"general": 5}"#, odd, ".gemini/settings.json")
        let out = try run(h, in: odd)
        XCTAssertEqual(try json(odd, ".gemini/settings.json")["general"] as? Int, 5)
        XCTAssertTrue(out.contains("not an object"), out)
    }

    func testScriptNamesNoCredential() throws {
        let claude = try XCTUnwrap(AgentRecipes.recipe("claude-code"))
        let script = try XCTUnwrap(AgentHistory.script(claude.launch.history)).lowercased()
        for word in ["token", "secret", "password", "api_key", "apikey", "credential", "doz_cred", "authorization"] {
            XCTAssertFalse(script.contains(word), word)
        }
        XCTAssertNil(AgentHistory.script(nil))
        XCTAssertNil(AgentHistory.script(AgentRecipe.Launch.History(native: "keeps", note: "It keeps them.", source: "https://example.com", checked: "2026-11-04")),
                     "keeps by itself: nothing to write")
    }

    // MARK: applied once

    /// What `Sandbox.applyAgentSettings` does, with the guest's commands run on this Mac in a scratch HOME. `ran` counts the
    /// script's runs.
    private final class Guest: @unchecked Sendable {
        let home: URL
        var scriptRuns = 0
        var failScript = false
        init(_ home: URL) { self.home = home }

        func exec(_ argv: [String]) throws -> (exitCode: Int32, output: String, error: String) {
            let isScript = argv.first == "python3"
            if isScript { scriptRuns += 1 }
            let p = Process()
            if isScript {
                p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
                p.arguments = ["-c", failScript ? "import sys; sys.exit(3)" : argv[2]]
            } else {
                p.executableURL = URL(fileURLWithPath: "/bin/sh")
                p.arguments = Array(argv.dropFirst())
            }
            p.environment = ["HOME": home.path]
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            try p.run()
            let o = out.fileHandleForReading.readDataToEndOfFile()
            let e = err.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return (p.terminationStatus, String(decoding: o, as: UTF8.self), String(decoding: e, as: UTF8.self))
        }
    }

    private func inputs(_ h: History) throws -> AgentSettingsInputs {
        let claude = try XCTUnwrap(AgentRecipes.recipe("claude-code"))
        var r = claude
        r.launch.history = h
        return try XCTUnwrap(AgentHistory.inputs(for: r))
    }

    private func apply(_ i: AgentSettingsInputs, _ g: Guest) async throws -> AgentSettingsRun? {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else { throw XCTSkip("no python3") }
        return await AgentSettingsLayer.apply(i, home: g.home.path) { argv in try g.exec(argv) }
    }

    func testAppliedOnceThenNotAgain() async throws {
        let home = try scratchHome()
        let g = Guest(home)
        let i = try inputs(history())
        let first = try await apply(i, g)
        XCTAssertEqual(first?.state, "applied")
        XCTAssertEqual(first?.fingerprint, i.fingerprint)
        XCTAssertEqual(try json(home)["cleanupPeriodDays"] as? Int, 36500)
        XCTAssertEqual(g.scriptRuns, 1)
        let marker = try String(contentsOf: home.appendingPathComponent(AgentSettingsLayer.markerRelative), encoding: .utf8)
        XCTAssertEqual(marker.trimmingCharacters(in: .whitespacesAndNewlines), i.fingerprint)
        // The marker equals the wanted fingerprint: the script is not run, the file is not touched.
        let url = home.appendingPathComponent(".claude/settings.json")
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
        let again = try await apply(i, g)
        XCTAssertNil(again, "nothing to do: not even a record")
        XCTAssertEqual(g.scriptRuns, 1)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date, old)
    }

    func testADeletedKeyStaysDeleted() async throws {
        let home = try scratchHome()
        let g = Guest(home)
        let i = try inputs(history())
        _ = try await apply(i, g)
        try write(#"{"theme": "dark"}"#, home)          // the person deleted the key
        let again = try await apply(i, g)
        XCTAssertNil(again)
        XCTAssertNil(try json(home)["cleanupPeriodDays"], "Dozable leaves it")
        XCTAssertEqual(g.scriptRuns, 1)
    }

    func testAChangedMappingAppliesAgain() async throws {
        let home = try scratchHome()
        let g = Guest(home)
        let a = try inputs(history())
        _ = try await apply(a, g)
        try write(#"{}"#, home)
        let b = try inputs(history(set: ["cleanupPeriodDays": .number(36500), "other": .bool(true)]))
        XCTAssertNotEqual(a.fingerprint, b.fingerprint)
        XCTAssertNotEqual(a.fingerprint, try inputs(history(set: ["cleanupPeriodDays": .number(3650)])).fingerprint, "a value is part of it")
        XCTAssertNotEqual(a.fingerprint, AgentHistory.fingerprint(history(), value: "agent-default"), "so is the setting's value (a later step)")
        let run = try await apply(b, g)
        XCTAssertEqual(run?.state, "applied")
        XCTAssertEqual(g.scriptRuns, 2)
        let c = try json(home)
        XCTAssertEqual(c["cleanupPeriodDays"] as? Int, 36500)
        XCTAssertEqual(c["other"] as? Bool, true)
    }

    func testAFailedRunIsNotRetried() async throws {
        let home = try scratchHome()
        let g = Guest(home)
        g.failScript = true
        let i = try inputs(history())
        let run = try await apply(i, g)
        XCTAssertEqual(run?.state, "failed")
        XCTAssertTrue(run?.notes.contains { $0.contains("exited 3") } ?? false, "\(String(describing: run?.notes))")
        XCTAssertEqual(g.scriptRuns, 1)
        g.failScript = false
        let again = try await apply(i, g)
        XCTAssertNil(again, "the marker was written anyway: not retried at every wake")
        XCTAssertEqual(g.scriptRuns, 1)
    }

    func testTheRunIsAFileTheMacCanRead() throws {
        let run = AgentSettingsRun(at: Date(timeIntervalSince1970: 1_700_000_000), fingerprint: "abc", state: "applied", notes: ["x"])
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try d.decode(AgentSettingsRun.self, from: try e.encode(run)), run)
    }

    func testOnlyASandboxOfAMappedAgentIsHandedInputsAndNoOtherDoes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agenthistory-sb-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        // A preparation VM, a bake or a helper is a plain Sandbox the host never hands anything: it runs nothing.
        let sb = try Sandbox(spec: SandboxSpec(name: "prep", storeRoot: root))
        XCTAssertNil(sb.agentSettings)
        XCTAssertNil(sb.lastAgentSettingsRun)
        let claude = try XCTUnwrap(AgentRecipes.recipe("claude-code"))
        let i = try XCTUnwrap(AgentHistory.inputs(for: claude))
        XCTAssertEqual(i.title, claude.title)
        XCTAssertEqual(i.fingerprint.count, 64)
        // Step 2: Codex writes too; pi and OpenCode keep by themselves (nothing to write); the rest map nothing.
        XCTAssertNotNil(AgentHistory.inputs(for: try XCTUnwrap(AgentRecipes.recipe("codex"))))
        for r in AgentRecipes.all where !["claude-code", "codex"].contains(r.id) { XCTAssertNil(AgentHistory.inputs(for: r), r.id) }
    }

    /// A session open writes nothing of it (it raced a running agent's own settings file, and brought back a deleted key).
    func testOpenSessionNoLongerWritesIt() throws {
        let host = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/DozableHost")
        guard let files = FileManager.default.enumerator(atPath: host.path) else { throw XCTSkip("no sources here") }
        for case let f as String in files where f.hasSuffix(".swift") {
            let text = try String(contentsOf: host.appendingPathComponent(f), encoding: .utf8)
            XCTAssertFalse(text.contains("deliverAgentHistory"), f)
        }
    }

    // MARK: the recipe's declaration

    func testClaudeCodeMapsItsRetentionAndTheHomeIsTheAgentsHome() throws {
        let claude = try XCTUnwrap(AgentRecipes.recipe("claude-code"))
        let h = try XCTUnwrap(claude.launch.history)
        XCTAssertEqual(h.keep?.first?.file, "~/.claude/settings.json")
        XCTAssertEqual(h.keep?.first?.set["cleanupPeriodDays"], .number(36500))
        XCTAssertEqual(claude.state.env["CLAUDE_CONFIG_DIR"], "/home/agent/.claude", "= ~/.claude for the agent user")
    }

    /// Every published coding agent has a mapping (owner, 2026-11-04): Claude Code and Codex write, pi and OpenCode keep by
    /// themselves; the unpublished ones have none yet (not known — the setting does not apply).
    func testEveryPublishedCodingAgentIsMapped() throws {
        let codex = try XCTUnwrap(AgentRecipes.recipe("codex")?.launch.history)
        XCTAssertEqual(codex.keep?.first?.file, "~/.codex/config.toml")
        XCTAssertEqual(codex.keep?.first?.set["history.persistence"], .string("save-all"))
        XCTAssertEqual(try XCTUnwrap(AgentRecipes.recipe("codex")).state.env["CODEX_HOME"], "/home/agent/.codex", "= ~/.codex for the agent user")
        XCTAssertNotNil(codex.agentDefault)
        for id in ["pi", "opencode", "opencode2"] {
            let h = try XCTUnwrap(AgentRecipes.recipe(id)?.launch.history, id)
            XCTAssertEqual(h.native, "keeps", id)
            XCTAssertNotNil(h.note, id)
            XCTAssertTrue(h.source.hasPrefix("https://"), id)
        }
        let mapped = Set(["claude-code", "codex", "pi", "opencode", "opencode2"])
        for r in AgentRecipes.all where r.published != false && r.catalogKind == "coding-agent" {
            XCTAssertTrue(mapped.contains(r.id), "\(r.id) is a published coding agent without a history mapping")
        }
        for r in AgentRecipes.all where !mapped.contains(r.id) { XCTAssertNil(r.launch.history, r.id) }
    }

    // MARK: agent-default — Dozable takes back only its own value

    func testAgentDefaultRemovesOnlyDozablesValue() throws {
        let home = try scratchHome()
        try write(#"{"theme": "dark", "cleanupPeriodDays": 36500}"#, home)
        try run(history(), in: home, value: AgentHistory.agentDefault)
        let c = try json(home)
        XCTAssertNil(c["cleanupPeriodDays"], "Dozable's value goes")
        XCTAssertEqual(c["theme"] as? String, "dark")
        // Then keep brings it back.
        try run(history(), in: home)
        XCTAssertEqual(try json(home)["cleanupPeriodDays"] as? Int, 36500)
    }

    func testAgentDefaultLeavesAnotherValue() throws {
        let home = try scratchHome()
        try write(#"{"cleanupPeriodDays": 7}"#, home)
        let url = home.appendingPathComponent(".claude/settings.json")
        let before = try Data(contentsOf: url)
        try run(history(), in: home, value: AgentHistory.agentDefault)
        XCTAssertEqual(try Data(contentsOf: url), before, "the person's 7 stays, the file is not rewritten")
        // Not the same type is not the same value (a person's "36500" string, a float).
        try write(#"{"cleanupPeriodDays": "36500"}"#, home)
        try run(history(), in: home, value: AgentHistory.agentDefault)
        XCTAssertEqual(try json(home)["cleanupPeriodDays"] as? String, "36500")
        // A missing file is not made.
        let fresh = try scratchHome()
        try run(history(), in: fresh, value: AgentHistory.agentDefault)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fresh.appendingPathComponent(".claude/settings.json").path))
        // A file that does not parse is never written.
        let broken = "{ \"cleanupPeriodDays\": 36500, // a hand edit\n"
        try write(broken, home)
        let out = try run(history(), in: home, value: AgentHistory.agentDefault)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), broken)
        XCTAssertTrue(out.contains("does not parse"), out)
    }

    func testAgentDefaultRemovesAnEmptiedParentOnly() throws {
        let home = try scratchHome()
        let h = history(file: "~/.gemini/settings.json", set: ["general.sessionRetention.enabled": .bool(false)])
        try write(#"{"general": {"vimMode": true, "sessionRetention": {"enabled": false}}}"#, home, ".gemini/settings.json")
        try run(h, in: home, value: AgentHistory.agentDefault)
        let general = try XCTUnwrap(try json(home, ".gemini/settings.json")["general"] as? [String: Any])
        XCTAssertNil(general["sessionRetention"], "emptied by the removal: gone")
        XCTAssertEqual(general["vimMode"] as? Bool, true, "a parent with something else in it stays")
        // Made by keep from nothing, taken back whole: an empty object is left, nothing of Dozable's.
        let fresh = try scratchHome()
        try run(h, in: fresh)
        try run(h, in: fresh, value: AgentHistory.agentDefault)
        XCTAssertTrue(try json(fresh, ".gemini/settings.json").isEmpty)
        // A sibling kept under the same parent keeps the parent.
        try write(#"{"general": {"sessionRetention": {"enabled": false, "maxAge": "90d"}}}"#, home, ".gemini/settings.json")
        try run(h, in: home, value: AgentHistory.agentDefault)
        let r = try XCTUnwrap(((try json(home, ".gemini/settings.json")["general"]) as? [String: Any])?["sessionRetention"] as? [String: Any])
        XCTAssertNil(r["enabled"])
        XCTAssertEqual(r["maxAge"] as? String, "90d")
    }

    func testAgentDefaultIsIdempotent() throws {
        let home = try scratchHome()
        try write(#"{"theme": "dark", "cleanupPeriodDays": 36500}"#, home)
        try run(history(), in: home, value: AgentHistory.agentDefault)
        let url = home.appendingPathComponent(".claude/settings.json")
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
        try run(history(), in: home, value: AgentHistory.agentDefault)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date, old)
    }

    // MARK: TOML (Codex's config.toml) — a minimal line-based edit that leaves what it does not understand alone

    private let codexFile = ".codex/config.toml"
    private func codexHistory() -> History {
        History(keep: [.init(file: "~/.codex/config.toml", set: ["history.persistence": .string("save-all")])],
                agentDefault: "Codex saves its conversations by itself", source: "https://example.com/codex", checked: "2026-11-04")
    }
    private func text(_ home: URL, _ path: String) throws -> String { try String(contentsOf: home.appendingPathComponent(path), encoding: .utf8) }

    func testTOMLKeepMakesAMissingFile() throws {
        let home = try scratchHome()
        try run(codexHistory(), in: home)
        XCTAssertEqual(try text(home, codexFile), "[history]\npersistence = \"save-all\"\n")
        let attrs = try FileManager.default.attributesOfItem(atPath: home.appendingPathComponent(codexFile).path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testTOMLKeepAppendsATableWhenAbsent() throws {
        let home = try scratchHome()
        let before = """
        model = "gpt-5.5"   # the person's
        approval_policy = "never"

        [projects."/workspace"]
        trust_level = "trusted"

        [tui]
        notifications = true
        """
        try write(before + "\n", home, codexFile)
        try run(codexHistory(), in: home)
        XCTAssertEqual(try text(home, codexFile), before + "\n\n[history]\npersistence = \"save-all\"\n", "appended; the rest byte for byte")
        // A second run changes nothing.
        let url = home.appendingPathComponent(codexFile)
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
        try run(codexHistory(), in: home)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date, old)
    }

    func testTOMLKeepInsertsUnderAnExistingTable() throws {
        let home = try scratchHome()
        try write("[history]\nmax_bytes = 1048576\n\n[tui]\nnotifications = true\n", home, codexFile)
        try run(codexHistory(), in: home)
        XCTAssertEqual(try text(home, codexFile), "[history]\npersistence = \"save-all\"\nmax_bytes = 1048576\n\n[tui]\nnotifications = true\n")
    }

    func testTOMLKeepLeavesThePersonsNone() throws {
        let home = try scratchHome()
        for given in ["[history]\npersistence = \"none\"\n", "history.persistence = 'none'  # mine\n", "[history]\n  persistence=\"save-all\"\n"] {
            try write(given, home, codexFile)
            try run(codexHistory(), in: home)
            XCTAssertEqual(try text(home, codexFile), given, "present with any value: left")
        }
    }

    func testTOMLNeverWritesAFileItDoesNotUnderstand() throws {
        let home = try scratchHome()
        let cases = [
            "model = \"x\"\nthis is not toml\n",                          // a line it does not read
            "[history\npersistence = \"none\"\n",                          // a broken header
            "notes = \"\"\"\nopen multi-line string\n",                   // a string that never ends
            "list = [1,\n2,\n",                                             // an array that never ends
        ]
        for given in cases {
            try write(given, home, codexFile)
            let out = try run(codexHistory(), in: home)
            XCTAssertEqual(try text(home, codexFile), given, given)
            XCTAssertTrue(out.contains("does not parse"), out)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: home.appendingPathComponent(".codex").path), ["config.toml"], "no temp file left")
        }
        // A table made another way is left alone, with a note — never a second [history].
        let refused = [
            "history.max_bytes = 10\n",                                     // made by a dotted key
            "history = { max_bytes = 10 }\n",                              // a value where the table would be
            "[[history]]\npersistence = \"none\"\n",                       // an array of tables
            "[history.sub]\nx = 1\n",                                       // a sub-table already defines it
        ]
        for given in refused {
            try write(given, home, codexFile)
            let out = try run(codexHistory(), in: home)
            XCTAssertEqual(try text(home, codexFile), given, given)
            XCTAssertTrue(out.contains("left as it is"), out)
        }
    }

    func testTOMLReadsMultiLineValuesAndQuotedKeys() throws {
        let home = try scratchHome()
        let before = """
        developer_instructions = \"\"\"
        [history]
        persistence = "none"
        \"\"\"
        args = [
          "a", # [x]
          "b",
        ]
        "quoted key" = 1
        [projects."/workspace/a.b"]
        trust_level = "trusted"
        """
        try write(before + "\n", home, codexFile)
        try run(codexHistory(), in: home)
        XCTAssertEqual(try text(home, codexFile), before + "\n\n[history]\npersistence = \"save-all\"\n",
                       "the [history] inside a string is not a table")
    }

    func testTOMLAgentDefault() throws {
        let home = try scratchHome()
        // Made by keep, taken back whole (the emptied table too).
        try write("model = \"x\"\n", home, codexFile)
        try run(codexHistory(), in: home)
        try run(codexHistory(), in: home, value: AgentHistory.agentDefault)
        XCTAssertEqual(try text(home, codexFile), "model = \"x\"\n")
        // The table keeps what else is in it.
        try write("[history]\npersistence = \"save-all\"\nmax_bytes = 10\n", home, codexFile)
        try run(codexHistory(), in: home, value: AgentHistory.agentDefault)
        XCTAssertEqual(try text(home, codexFile), "[history]\nmax_bytes = 10\n")
        // Another value is the person's.
        for given in ["[history]\npersistence = \"none\"\n", "[history]\npersistence = \"save-all-but\"\n"] {
            try write(given, home, codexFile)
            try run(codexHistory(), in: home, value: AgentHistory.agentDefault)
            XCTAssertEqual(try text(home, codexFile), given)
        }
        // A table with a comment in it is not empty: the header stays.
        try write("[history]\n# mine\npersistence = 'save-all'  # Dozable's\n\n[tui]\nx = 1\n", home, codexFile)
        try run(codexHistory(), in: home, value: AgentHistory.agentDefault)
        XCTAssertEqual(try text(home, codexFile), "[history]\n# mine\n\n[tui]\nx = 1\n")
        // A dotted key at the root.
        try write("history.persistence = \"save-all\"\nmodel = \"x\"\n", home, codexFile)
        try run(codexHistory(), in: home, value: AgentHistory.agentDefault)
        XCTAssertEqual(try text(home, codexFile), "model = \"x\"\n")
    }

    func testCodexScriptRunsOnTheRecipesOwnMapping() throws {
        let home = try scratchHome()
        let codex = try XCTUnwrap(AgentRecipes.recipe("codex")?.launch.history)
        try run(codex, in: home)
        XCTAssertEqual(try text(home, codexFile), "[history]\npersistence = \"save-all\"\n")
        XCTAssertNil(AgentHistory.script(codex, value: "follow"), "follow is never a value a script gets")
    }

    // MARK: the value

    func testTheValueIsPartOfTheFingerprintAndAppliesOnce() async throws {
        let home = try scratchHome()
        let g = Guest(home)
        let claude = try XCTUnwrap(AgentRecipes.recipe("claude-code"))
        let keep = try XCTUnwrap(AgentHistory.inputs(for: claude, value: AgentHistory.keep))
        let back = try XCTUnwrap(AgentHistory.inputs(for: claude, value: AgentHistory.agentDefault))
        XCTAssertNotEqual(keep.fingerprint, back.fingerprint)
        XCTAssertEqual(keep, AgentHistory.inputs(for: claude), "keep is the default")
        _ = try await apply(keep, g)
        XCTAssertEqual(try json(home)["cleanupPeriodDays"] as? Int, 36500)
        // The setting changes: applied once at the next start or wake, then not again.
        let run = try await apply(back, g)
        XCTAssertEqual(run?.state, "applied")
        XCTAssertNil(try json(home)["cleanupPeriodDays"])
        let again = try await apply(back, g)
        XCTAssertNil(again)
        XCTAssertEqual(g.scriptRuns, 2)
        // And back: it returns.
        _ = try await apply(keep, g)
        XCTAssertEqual(try json(home)["cleanupPeriodDays"] as? Int, 36500)
    }

    func testTheMappingInWords() throws {
        let s = DozableSettings(text: nil)
        let claude = AgentHistory.mapping(try XCTUnwrap(AgentRecipes.recipe("claude-code")), settings: s)
        XCTAssertEqual(claude.kind, "writes")
        XCTAssertEqual(claude.writes, [HistoryMapping.Write(file: "~/.claude/settings.json", key: "cleanupPeriodDays", value: "36500")])
        XCTAssertTrue(claude.keep.contains("cleanupPeriodDays = 36500 in ~/.claude/settings.json"), claude.keep)
        XCTAssertTrue(claude.agentDefault.contains("older than 30 days"), claude.agentDefault)
        XCTAssertEqual(claude.effective, "keep")
        XCTAssertEqual(claude.effectiveKey, SettingKey.agentHistory)
        let codex = AgentHistory.mapping(try XCTUnwrap(AgentRecipes.recipe("codex")), settings: s)
        XCTAssertTrue(codex.keep.contains("history.persistence = \"save-all\" in ~/.codex/config.toml"), codex.keep)
        let pi = AgentHistory.mapping(try XCTUnwrap(AgentRecipes.recipe("pi")), settings: s)
        XCTAssertEqual(pi.kind, "keeps")
        XCTAssertEqual(pi.keep, "nothing — it keeps conversations by itself")
        XCTAssertEqual(pi.agentDefault, pi.keep)
        XCTAssertNotNil(pi.source)
        let unknown = try XCTUnwrap(AgentRecipes.all.first { $0.launch.history == nil })
        let u = AgentHistory.mapping(unknown, settings: s)
        XCTAssertEqual(u.kind, "unknown")
        XCTAssertEqual(u.keep, "not known — the setting does not apply")
        // The Dozable-wide list: the mapped agents first, every published coding agent in it.
        let all = AgentHistory.mappings(settings: s).map(\.agent)
        for id in ["claude-code", "codex", "pi", "opencode", "opencode2"] { XCTAssertTrue(all.contains(id), id) }
    }

    func testTheDeclarationIsChecked() throws {
        let base = try XCTUnwrap(AgentRecipes.recipe("claude-code"))
        XCTAssertNoThrow(try base.validate())
        func refused(_ why: String, file: StaticString = #filePath, line: UInt = #line, _ change: (inout History) -> Void) {
            var r = base
            change(&r.launch.history!)
            XCTAssertThrowsError(try r.validate(), why, file: file, line: line)
        }
        func accepted(_ why: String, file: StaticString = #filePath, line: UInt = #line, _ change: (inout History) -> Void) {
            var r = base
            change(&r.launch.history!)
            XCTAssertNoThrow(try r.validate(), why, file: file, line: line)
        }
        accepted("a nested key, a bool, a string") { $0.keep![0].set = ["a.b-c.d_e": .bool(true), "x": .string("y")] }
        accepted("native: keeps, with its note") { $0 = History(native: "keeps", note: "It keeps them itself.", source: "https://example.com/x", checked: "2026-11-04") }
        refused("a file outside the home") { $0.keep![0].file = "/etc/settings.json" }
        accepted("a TOML file") { $0.keep![0].file = "~/.codex/config.toml" }
        refused("a file that is neither JSON nor TOML") { $0.keep![0].file = "~/.claude/settings.yaml" }
        refused("a file that climbs") { $0.keep![0].file = "~/../etc/x.json" }
        refused("a credential's name") { $0.keep![0].set = ["apiKey": .string("x")] }
        refused("a credential's name, nested") { $0.keep![0].set = ["auth.ACCESS_TOKEN": .bool(true)] }
        refused("a key with a space") { $0.keep![0].set = ["a b": .bool(true)] }
        refused("no source") { $0.source = "" }
        refused("a source that is not https") { $0.source = "http://example.com" }
        refused("a bad date") { $0.checked = "yesterday" }
        refused("an object value") { $0.keep![0].set = ["a": .object(["b": .bool(true)])] }
        refused("an array value") { $0.keep![0].set = ["a": .array([])] }
        refused("a value with a quote") { $0.keep![0].set = ["a": .string("it's")] }
        refused("no entries") { $0.keep = [] }
        refused("five entries") { $0.keep = (0..<5).map { .init(file: "~/.f\($0).json", set: ["a": .bool(true)]) } }
        refused("no agent_default") { $0.agentDefault = nil }
        refused("native with keep") { $0.native = "keeps"; $0.note = "x" }
        refused("native that is not keeps") { $0 = History(native: "no", note: "x", source: "https://example.com", checked: "2026-11-04") }
    }
}
