import Foundation
import XCTest
@testable import DozableKit

/// 678 (#386): Claude Code's launcher as the host refreshes it at run time — the facts COMBINED with a caller's
/// `--append-system-prompt`, never twice, `--system-prompt` and subcommands left alone. Run under /bin/sh with a stub
/// `claude` that records its argv (NUL-separated).
final class LauncherScriptTests: XCTestCase {
    var dir: URL!
    let facts = "# Where you are running: a Dozable sandbox\n- You are in `t`, a Dozable sandbox."

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("doz-launcher-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "#!/bin/sh\nprintf '%s\\0' \"$@\" > \"$OUT\"\n".write(to: dir.appendingPathComponent("claude"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.appendingPathComponent("claude").path)
        try (facts + "\n").write(to: dir.appendingPathComponent("agent-prompt.md"), atomically: true, encoding: .utf8)
        var p = AgentImages.LauncherPaths()
        p.claude = dir.appendingPathComponent("claude").path
        p.setupDir = dir.path
        p.prompt = dir.appendingPathComponent("agent-prompt.md").path
        p.setupRunner = "true"
        try AgentImages.launcherRuntimeScript(.node, paths: p).write(to: dir.appendingPathComponent("launcher"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    /// The real claude's argv for the launcher run with `args`.
    func run(_ args: [String], env extra: [String: String] = [:]) throws -> [String] {
        let out = dir.appendingPathComponent("argv")
        try? FileManager.default.removeItem(at: out)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [dir.appendingPathComponent("launcher").path] + args
        var env = ProcessInfo.processInfo.environment
        env["OUT"] = out.path
        env["DOZ_CLAUDE_PERMISSIONS"] = nil
        for (k, v) in extra { env[k] = v }
        p.environment = env
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
        let d = try Data(contentsOf: out)
        var parts = d.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        if parts.last == "" { parts.removeLast() }
        return parts
    }

    let skip = "--dangerously-skip-permissions"

    func testNoFlagGetsTheFacts() throws {
        XCTAssertEqual(try run(["-p", "hi"]), [skip, "--append-system-prompt", facts, "-p", "hi"])
        XCTAssertEqual(try run([]), [skip, "--append-system-prompt", facts])
    }

    func testOneFlagIsCombinedWithTheFacts() throws {
        XCTAssertEqual(try run(["--append-system-prompt", "MARK", "-p", "hi"]), [skip, "--append-system-prompt", facts + "\n\nMARK", "-p", "hi"])
    }

    func testEveryFlagAndTheEqualsFormBecomeOne() throws {
        XCTAssertEqual(try run(["--append-system-prompt", "A b", "--model", "x", "--append-system-prompt=B\nline two"]),
                       [skip, "--append-system-prompt", facts + "\n\nA b\n\nB\nline two", "--model", "x"])
    }

    func testTheFileFormIsCombinedWhenItReads() throws {
        let f = dir.appendingPathComponent("extra.md")
        try "FROM A FILE\n".write(to: f, atomically: true, encoding: .utf8)
        XCTAssertEqual(try run(["--append-system-prompt-file", f.path, "-c"]), [skip, "--append-system-prompt", facts + "\n\nFROM A FILE", "-c"])
        XCTAssertEqual(try run(["--append-system-prompt-file=/nonexistent/x", "-c"]),
                       [skip, "--append-system-prompt", facts, "--append-system-prompt-file=/nonexistent/x", "-c"], "unreadable: left to Claude Code")
    }

    /// A caller that passes the facts itself (`$(cat /run/doz/agent-prompt.md)`) does not get them twice.
    func testAValueThatHoldsTheFactsIsPassedAsItIs() throws {
        XCTAssertEqual(try run(["--append-system-prompt", facts, "-p", "hi"]), [skip, "--append-system-prompt", facts, "-p", "hi"])
        XCTAssertEqual(try run(["--append-system-prompt", facts + "\n\nand mine"]), [skip, "--append-system-prompt", facts + "\n\nand mine"])
        XCTAssertEqual(try run(["--append-system-prompt", "first", "--append-system-prompt", facts]),
                       [skip, "--append-system-prompt", "first\n\n" + facts], "combined, facts not added again")
    }

    func testSystemPromptAndSubcommandsAreLeftAlone() throws {
        XCTAssertEqual(try run(["--system-prompt", "S", "--append-system-prompt", "A"]), [skip, "--system-prompt", "S", "--append-system-prompt", "A"])
        XCTAssertEqual(try run(["--system-prompt=S"]), [skip, "--system-prompt=S"])
        XCTAssertEqual(try run(["mcp", "list"]), [skip, "mcp", "list"])
        XCTAssertEqual(try run(["doctor"]), [skip, "doctor"])
    }

    func testAskModeAndAfterTheTerminator() throws {
        XCTAssertEqual(try run(["--append-system-prompt", "M"], env: ["DOZ_CLAUDE_PERMISSIONS": "ask"]), ["--append-system-prompt", facts + "\n\nM"])
        XCTAssertEqual(try run(["-p", "--", "--append-system-prompt", "x"]), [skip, "--append-system-prompt", facts, "-p", "--", "--append-system-prompt", "x"])
    }

    func testNoFactsFileChangesNothing() throws {
        try "".write(to: dir.appendingPathComponent("agent-prompt.md"), atomically: true, encoding: .utf8)
        XCTAssertEqual(try run(["--append-system-prompt", "A", "-p", "q"]), [skip, "--append-system-prompt", "A", "-p", "q"])
    }

    /// The baked launcher never changes (it is in every Node image's bake key); the runtime one is the same file but for
    /// the combination, and the refresh replaces only the doz launcher, only an older one.
    func testTheBakedLauncherIsUntouchedAndTheRefreshIsSafe() throws {
        let baked = AgentImages.launcherScript(.node)
        XCTAssertTrue(baked.contains(" *) set -- --append-system-prompt \"$(cat \"$p\")\" \"$@\" ;;"), "the baked launcher keeps its skip")
        XCTAssertTrue(baked.contains("\n" + AgentImages.launcherMarkerLine + "\n"), "the baked second line is what the refresh looks for")
        for setup in [AgentImages.LauncherSetup.node, .python] {
            let lines = AgentImages.launcherRuntimeScript(setup).split(separator: "\n", omittingEmptySubsequences: false)
            XCTAssertEqual(lines[0], "#!/bin/sh")
            XCTAssertEqual(String(lines[1]), AgentImages.launcherMarkerLine)
            XCTAssertTrue(lines[2].hasPrefix("# doz-launcher: "))
            XCTAssertTrue(AgentImages.launcherRuntimeScript(setup).contains(setup == .node ? "node /usr/local/lib/doz/claude-setup.js" : "python3 /usr/local/lib/doz/claude-setup.py"))
        }
        let refresh = AgentImages.launcherRefreshScript
        XCTAssertTrue(refresh.contains(AgentImages.launcherRuntimeScript(.node) + "DOZLAUNCHER\n"))
        XCTAssertTrue(refresh.contains(AgentImages.launcherRuntimeScript(.python) + "DOZLAUNCHER\n"))
        XCTAssertTrue(refresh.contains("[ ! -L \"$f\" ]"), "never through a link")
        // The refresh script parses.
        let s = dir.appendingPathComponent("refresh.sh")
        try refresh.write(to: s, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-n", s.path]
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
    }
}
