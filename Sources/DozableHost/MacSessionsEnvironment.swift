import Darwin
import DozableKit
import Foundation

/// The environment a session on this Mac starts with: an ALLOWLIST, built new — never the host's environment passed on.
/// The host may have been started from inside a Claude Code session, a Cursor worker, a test: none of their markers
/// (`CLAUDECODE`, `CLAUDE_CODE_*`, `DOZ_*`, `ANTHROPIC_*`, `__CF*`, `XPC_*`, `TERM_PROGRAM*`, `VSCODE_*`, `CURSOR_*`, …)
/// reaches the program. Pure — `MacSessionsEnvironmentTests`.
public enum MacSessionsEnvironment {
    /// Taken from the host's environment when set.
    public static let passed = ["HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "SSH_AUTH_SOCK"]

    /// A variable a person may not give (`-e`): the markers that tell a program it runs inside Claude Code.
    public static func isRefusedName(_ k: String) -> Bool { k == "CLAUDECODE" || k.hasPrefix("CLAUDE_CODE_") }

    /// Why `-e NAME=…` is refused, or nil.
    public static func refusal(_ name: String) -> String? {
        if name.isEmpty || name.contains("=") || name.utf8.contains(0) { return "\(name.isEmpty ? "an empty name" : name) is not a variable name" }
        if isRefusedName(name) {
            return "\(name) is not passed to a session on this Mac: it would tell the program it runs inside Claude Code (a session opened from one must not inherit that)"
        }
        return nil
    }

    /// The environment: the allowlist from `host`, `TERM`/`COLORTERM`, `PATH` (`path`), then the person's `extra`.
    public static func build(host: [String: String], path: String, extra: [String: String] = [:]) throws -> [String: String] {
        var env: [String: String] = [:]
        for k in passed { if let v = host[k], !v.isEmpty { env[k] = v } }
        for (k, v) in host where k.hasPrefix("LC_") && !v.isEmpty { env[k] = v }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["PATH"] = path
        for (k, v) in extra {
            if let why = refusal(k) { throw HostError(.invalid, why) }
            env[k] = v
        }
        return env
    }

    /// `path_helper`'s list (`/etc/paths`, then each file of `/etc/paths.d` in name order), then `/opt/homebrew/bin` and
    /// `~/.local/bin` — the fallback when the login shell does not say its PATH.
    public static func pathHelperPath(etc: String = "/etc", home: String) -> String {
        func lines(_ file: String) -> [String] {
            ((try? String(contentsOfFile: file, encoding: .utf8)) ?? "").split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
        }
        var out = lines(etc + "/paths")
        let d = etc + "/paths.d"
        for f in ((try? FileManager.default.contentsOfDirectory(atPath: d)) ?? []).sorted() where !f.hasPrefix(".") { out += lines(d + "/" + f) }
        for extra in ["/opt/homebrew/bin", home + "/.local/bin"] where !out.contains(extra) { out.append(extra) }
        if out.isEmpty { out = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"] }
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }.joined(separator: ":")
    }

    /// A PATH as the login shell prints it, checked: absolute directories only, one line, at most 8 KiB. nil: not usable.
    public static func checkedPath(_ s: String) -> String? {
        let p = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty, p.utf8.count <= 8192, !p.contains("\n"), !p.unicodeScalars.contains(where: { $0.value < 0x20 }) else { return nil }
        let parts = p.split(separator: ":", omittingEmptySubsequences: true)
        guard !parts.isEmpty, parts.allSatisfy({ $0.hasPrefix("/") }) else { return nil }
        return parts.joined(separator: ":")
    }

    /// The login shell's PATH (`$SHELL -lc 'printf %s "$PATH"'`, at most `timeout` seconds), else `pathHelperPath`.
    /// TEST SEAM (guarded runs only — a test never runs the person's login shell): `DOZ_TEST_MAC_PATH`.
    public static func loginPath(host: [String: String], timeout: Double = 5) -> (path: String, source: String) {
        let home = host["HOME"] ?? NSHomeDirectory()
        if TestSafety.guarded(host) {
            if let p = host["DOZ_TEST_MAC_PATH"].flatMap(checkedPath) { return (p, "test") }
            return (pathHelperPath(home: home), "path_helper")
        }
        let shell = host["SHELL"].flatMap { $0.hasPrefix("/") ? $0 : nil } ?? "/bin/zsh"
        let base = (try? build(host: host, path: pathHelperPath(home: home))) ?? [:]
        if let out = run([shell, "-lc", "printf %s \"$PATH\""], environment: base, timeout: timeout), let p = checkedPath(out) {
            return (p, "login shell")
        }
        return (pathHelperPath(home: home), "path_helper")
    }

    /// Run `argv` (no shell of ours: the login shell is the program) with stdin /dev/null; its stdout, or nil when it failed
    /// or outlived `timeout` (then it is killed).
    static func run(_ argv: [String], environment: [String: String], timeout: Double) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: argv[0])
        p.arguments = Array(argv.dropFirst())
        p.environment = environment
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        // Read on a thread of its own: a profile that leaves something running with the pipe open must not hold us.
        final class Collected: @unchecked Sendable { let lock = NSLock(); var data = Data() }
        let got = Collected()
        let reader = out.fileHandleForReading
        Thread.detachNewThread {
            while true {
                let d = reader.availableData
                if d.isEmpty { break }
                got.lock.lock(); if got.data.count < 16_384 { got.data.append(d) }; got.lock.unlock()
            }
        }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { usleep(20_000) }
        if p.isRunning { p.terminate(); usleep(200_000); if p.isRunning { kill(p.processIdentifier, SIGKILL) } }
        p.waitUntilExit()
        usleep(50_000)
        guard p.terminationStatus == 0, p.terminationReason == .exit else { return nil }
        got.lock.lock(); defer { got.lock.unlock() }
        return String(decoding: got.data.prefix(16_384), as: UTF8.self)
    }
}
