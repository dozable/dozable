import XCTest
@testable import DozableKit
@testable import DozableHost

/// 674: keeping an agent's conversations — the recipe's `launch@1 history.keep` is written by the host as a python3 script
/// at every session open (never baked). The script runs here on temp files, as `RecipeEachRunTests` runs the launcher's.
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
    private func run(_ h: History, in home: URL) throws -> String {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else { throw XCTSkip("no python3") }
        let script = try XCTUnwrap(AgentHistory.script(h))
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

    // MARK: the recipe's declaration

    func testClaudeCodeMapsItsRetentionAndTheHomeIsTheAgentsHome() throws {
        let claude = try XCTUnwrap(AgentRecipes.recipe("claude-code"))
        let h = try XCTUnwrap(claude.launch.history)
        XCTAssertEqual(h.keep?.first?.file, "~/.claude/settings.json")
        XCTAssertEqual(h.keep?.first?.set["cleanupPeriodDays"], .number(36500))
        XCTAssertEqual(claude.state.env["CLAUDE_CONFIG_DIR"], "/home/agent/.claude", "= ~/.claude for the agent user")
        for r in AgentRecipes.all where r.id != "claude-code" { XCTAssertNil(r.launch.history, r.id) }
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
        refused("a file that is not JSON") { $0.keep![0].file = "~/.claude/settings.toml" }
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
