import DozableKit
import Foundation

/// 683 — the facts a Claude Code session on this Mac gets about where it runs: ONE `--append-system-prompt`, combined with
/// every one the person's own argv gives (Claude Code keeps only the last — the sandbox launcher's rule): never for a
/// subcommand, never when the argv replaces the prompt (`--system-prompt…`) or names a prompt file (it is not read here),
/// and not again when a value already holds the facts. `mac.agent_prompt`: `fenced` (default — fenced sessions only),
/// `always` (every session on this Mac), `off`. The recorded argv is the person's; the facts are added at each open.
public enum MacAgentPrompt {
    public static let values = ["fenced", "always", "off"]
    /// The facts' first line (how a value that already holds them is recognised).
    public static let firstLine = "You are running on the person's own Mac, in a session Dozable holds (doz run @mac)."
    static let subcommands: Set<String> = ["mcp", "plugin", "plugins", "setup-token", "doctor", "update", "upgrade", "install", "config",
                                           "migrate-installer", "auth", "agents"]

    /// Whether a session gets the facts: its program is Claude Code, and the setting says so for its mode.
    public static func applies(argv: [String], fenced: Bool, setting: String) -> Bool {
        guard MacPlace.isClaude(argv) else { return false }
        switch setting {
        case "off": return false
        case "always": return true
        default: return fenced
        }
    }

    /// The facts for a session — fenced (`fence`, its agent setup) or not.
    public static func facts(fence f: MacFence?, agent: MacAgentSetup?, workdir: String) -> String {
        var l: [String] = [firstLine]
        guard let f else {
            l.append("- Nothing is around it: it runs as the person — their files, Keychain and network. Work in \(DisplayPath.tilde(workdir)).")
            return l.joined(separator: "\n")
        }
        l.append("- It is FENCED (macOS Seatbelt). It may read and write \(DisplayPath.tilde(f.workdir))"
                 + (f.writable.isEmpty ? "" : " and " + f.writable.map { DisplayPath.tilde($0) }.joined(separator: ", "))
                 + (f.readable.isEmpty ? "" : "; read " + f.readable.map { DisplayPath.tilde($0) }.joined(separator: ", "))
                 + "; read the system and the person's tools. The rest of the home (secrets, configs, other projects) is closed.")
        l.append("- Its own temp folder ($TMPDIR) and caches are per session (they start empty); write nothing to /tmp. Use `swift build --disable-sandbox --cache-path \"$XDG_CACHE_HOME/swiftpm\"` for Swift packages.")
        l.append("- The Keychain is " + (f.keychain ? "OPEN (signing works)." : "closed: code signing, notarisation and saved logins are not available."))
        if f.proxyPort != nil {
            let words = f.presetName ?? "custom"
            l.append("- The network goes only through Dozable's proxy (HTTPS_PROXY is set), by its permissions (\(words)); a refused site answers 403 with the reason. DNS is closed (the proxy resolves names). This Mac's own addresses are never reachable"
                     + (f.localPorts.isEmpty ? "; it may not listen on any port." : "; it may listen on and connect to localhost:" + f.localPorts.map(String.init).joined(separator: ", ") + " only."))
        } else {
            l.append("- It has no network.")
        }
        l.append("- Not available: sudo, open, osascript, launchctl, ps, Docker and other container tools; a headless browser needs --no-sandbox.")
        l.append("- A git config change outside a short list (remotes, branches, a few core keys) stops the session until the person resumes it; git hooks cannot be written.")
        if let a = agent {
            l.append(a.isPrivate
                     ? "- Its settings folder is its own (\(a.config.homeEnv)): the person's instructions and skills are read-only, and changes to its settings are refused. Its conversations are copied back to the person's when it ends."
                     : "- Its settings folder is the person's own \(DisplayPath.tilde(a.personHome)) (shared, by the person's choice).")
        }
        l.append(openLine(f))
        return l.joined(separator: "\n")
    }

    /// `{{mac.open}}` — which bridges a fenced session has.
    public static func openLine(_ f: MacFence) -> String {
        var on: [String] = []
        if f.bridges.openURL { on.append("`open URL` (or $BROWSER) asks the person's browser to open an http(s) page — announced to them") }
        if f.bridges.openFiles { on.append("`open FILE` opens a document from its folder in the person's app (`open -R` shows it in the Finder)") }
        if f.bridges.clipboard { on.append("a copy (OSC 52) reaches the person's clipboard, announced; reading it never works") }
        let callback = f.localPorts.isEmpty ? "a sign-in that calls back to localhost needs the session started with --local-port PORT"
            : "a sign-in may call back to localhost:" + f.localPorts.map(String.init).joined(separator: ", ")
        return "- Bridges: " + (on.isEmpty ? "none (opening pages and files, and the clipboard, are off)" : on.joined(separator: "; ")) + "; " + callback + "."
    }

    /// `argv` with the facts added (the combine rule above).
    public static func argv(_ argv: [String], facts: String) -> [String] {
        guard argv.count >= 1 else { return argv }
        let rest = Array(argv.dropFirst())
        if let first = rest.first, subcommands.contains(first) { return argv }
        var own: [String] = [], kept: [String] = []
        var i = 0
        while i < rest.count {
            let a = rest[i]
            if a == "--" { kept += rest[i...]; break }
            if a == "--system-prompt" || a.hasPrefix("--system-prompt=") || a.hasPrefix("--system-prompt-file") || a.hasPrefix("--append-system-prompt-file") {
                return argv
            }
            if a == "--append-system-prompt", i + 1 < rest.count { own.append(rest[i + 1]); i += 2; continue }
            if a.hasPrefix("--append-system-prompt=") { own.append(String(a.dropFirst("--append-system-prompt=".count))); i += 1; continue }
            kept.append(a)
            i += 1
        }
        let prompt: String
        if own.contains(where: { $0.contains(firstLine) }) { prompt = own.joined(separator: "\n\n") }
        else { prompt = ([facts] + own).joined(separator: "\n\n") }
        return [argv[0], "--append-system-prompt", prompt] + kept
    }
}
