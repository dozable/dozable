import Foundation

/// What a FENCED session's environment adds to the allowlist `MacSessionsEnvironment.build` makes — pure;
/// `MacFenceEnvironmentTests`. Nothing a fenced program writes may be loaded later by something unfenced, so every
/// temp folder and tool cache it knows of points into the session's own folder; git reads a host-written config and an
/// empty template; the person's SSH agent is not passed. `DOZ_*` variables are only `DOZ_TTY` (the holder's) and
/// `DOZ_FENCE`.
public enum MacFenceEnvironment {
    /// The variables a fenced session never inherits from the allowlist.
    public static let removed = ["SSH_AUTH_SOCK"]
    /// 683: an agent's own temp-folder variable, pointed at the session's TMPDIR (found by probe: Claude Code 2.1.323 opens
    /// `/tmp/claude-<uid>` at start and exits on EPERM without it).
    public static let agentTempVariables = ["claude-code": "CLAUDE_CODE_TMPDIR"]

    /// Each tool cache, under `<session>/cache/` (they persist across the session's restarts, and are emptied when a
    /// re-open widens its grants).
    public static let caches: [(String, String)] = [
        ("XDG_CACHE_HOME", "xdg"), ("npm_config_cache", "npm"), ("YARN_CACHE_FOLDER", "yarn"), ("npm_config_store_dir", "pnpm"),
        ("BUN_INSTALL_CACHE_DIR", "bun"), ("PIP_CACHE_DIR", "pip"), ("UV_CACHE_DIR", "uv"), ("CARGO_HOME", "cargo"),
        ("GOMODCACHE", "gomod"), ("GOCACHE", "go"),
        // Go keeps its checksum database under GOPATH/pkg/sumdb (found by probe: `go mod download` fails on ~/go): the
        // session's own GOPATH — `go install` then puts programs in the session's caches, not ~/go/bin.
        ("GOPATH", "gopath"), ("PRE_COMMIT_HOME", "pre-commit"), ("PLAYWRIGHT_BROWSERS_PATH", "playwright"),
        ("CLANG_MODULE_CACHE_PATH", "clang"),
        // The read probe on a real Mac: a closed config folder must look ABSENT, not refused (gh dies on EPERM reading
        // ~/.config/gh); xcrun writes the user temp folder directly (TMPDIR ignored); Apple's Python caches bytecode in
        // ~/Library/Caches.
        ("XDG_CONFIG_HOME", "config"), ("xcrun_db", "xcrun_db"), ("PYTHONPYCACHEPREFIX", "python"),
    ]

    /// The proxy variables of a fenced session (`port`, its password): every tool's proxy at the literal loopback address
    /// (DNS is closed inside), the loopback direct (refused unless `--local-port`), Node 22 told to use them, git told
    /// to send the password, and — when the proxy has a CA (`ca`: the session's `etc/` copies) — the CA for the tools that
    /// do not read the system's trust store. Pure.
    public static func proxy(port: UInt16, password: String, etc: String?, github: Bool = false) -> [String: String] {
        var e: [String: String] = [:]
        let url = "http://doz:\(password)@127.0.0.1:\(port)"
        for k in ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy"] { e[k] = url }
        for k in ["NO_PROXY", "no_proxy"] { e[k] = "localhost,127.0.0.1,::1" }
        e["NODE_USE_ENV_PROXY"] = "1"
        for (i, (k, v)) in gitConfig(github: github).enumerated() {
            e["GIT_CONFIG_KEY_\(i)"] = k
            e["GIT_CONFIG_VALUE_\(i)"] = v
        }
        e["GIT_CONFIG_COUNT"] = String(gitConfig(github: github).count)
        if let etc {
            e["NODE_EXTRA_CA_CERTS"] = etc + "/ca.pem"
            for k in ["SSL_CERT_FILE", "REQUESTS_CA_BUNDLE", "CURL_CA_BUNDLE", "GIT_SSL_CAINFO"] { e[k] = etc + "/ca-bundle.pem" }
        }
        return e
    }

    /// 683 M4: git's command-line config (`GIT_CONFIG_*`, read after every file): the proxy's password sent as Basic, and
    /// github.com's credential helper — the session's placeholder from `$GH_TOKEN` with GitHub as you, else a helper that
    /// says why there is none and stops git asking (`quit=1`). An empty `credential.helper` first drops every helper a
    /// config file named (the system's osxkeychain one: closed with the Keychain — "failed to store" — and, under
    /// `--keychain`, it would write the placeholder into the person's Keychain).
    public static func gitConfig(github: Bool) -> [(String, String)] {
        let helper = github ? githubHelper : noGitHubHelper
        return [("http.proxyAuthMethod", "basic"), ("credential.helper", ""), ("credential.https://github.com.helper", ""),
                ("credential.https://github.com.helper", helper)]
    }
    /// The helper with GitHub as you: the placeholder (the proxy swaps it for the person's token on github.com only).
    public static let githubHelper = #"!f() { test "$1" = get || exit 0; echo username=x-access-token; echo "password=$GH_TOKEN"; }; f"#
    /// The helper without it: the reason on stderr, and git stops (no prompt).
    public static let noGitHubHelper = #"!f() { test "$1" = get || exit 0; echo "doz: this fenced session has no GitHub credential — start it with --github push (or --github read to clone private repositories), or use an ssh remote with --ssh-agent" >&2; echo quit=1; }; f"#

    /// A shell word: `s` in single quotes.
    static func shellQuoted(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// 683 M4: git's ssh (and the `ssh` shim's): every connection through `doz fence-connect` (the proxy judges the host;
    /// DNS is closed inside), host keys in the session's own `known_hosts` (new ones accepted there, a CHANGED one still
    /// refused), never the person's. nil `doz`: no way through (a doz path a profile cannot carry).
    public static func sshOptions(doz: String?, knownHosts: String) -> [String] {
        var o: [String] = []
        if let d = doz, MacFencePaths.pathProblem(d) == nil { o.append("ProxyCommand=\"\(d)\" fence-connect %h %p") }
        o.append("UserKnownHostsFile=\"\(knownHosts)\"")
        o.append("StrictHostKeyChecking=accept-new")
        return o
    }

    public static func sshCommand(doz: String?, knownHosts: String) -> String {
        "ssh" + sshOptions(doz: doz, knownHosts: knownHosts).map { " -o " + shellQuoted($0) }.joined()
    }

    /// Add the fenced session's variables to `env` (the allowlist already built); `proxyPassword`: its proxy's (with
    /// `f.proxyPort`), `ca`: the CA copies are in its `etc/`.
    public static func add(_ env: inout [String: String], fence f: MacFence, proxyPassword: String? = nil, ca: Bool = false) {
        if let port = f.proxyPort, let pw = proxyPassword {
            for (k, v) in proxy(port: port, password: pw, etc: ca ? f.etc : nil, github: f.github != nil) { env[k] = v }
        }
        for k in removed { env[k] = nil }
        env["TMPDIR"] = f.tmp + "/"
        for (k, sub) in caches { env[k] = f.cache + "/" + sub }
        // Cargo keeps its programs in CARGO_HOME/bin: the person's ~/.cargo/bin stays first on PATH (read-only).
        env["GIT_CONFIG_GLOBAL"] = f.etc + "/gitconfig"
        env["GIT_CONFIG_NOSYSTEM"] = nil
        env["GIT_TEMPLATE_DIR"] = f.etc + "/git-template"
        env["GIT_SSH_COMMAND"] = sshCommand(doz: f.dozExecutable, knownHosts: f.ssh + "/known_hosts")
        env["ZDOTDIR"] = f.etc + "/shell"
        env["HISTFILE"] = f.tmp + "/history"
        env["DISABLE_AUTOUPDATER"] = "1"
        env["GOTELEMETRY"] = "off"
        env["DOZ_FENCE"] = f.profile
        // 683 M4: Xcode's DerivedData in the session (`xcodebuild -derivedDataPath "$DOZ_DERIVED"`).
        if f.xcode { env["DOZ_DERIVED"] = f.derived }
        // 683 M4: the filtered SSH agent; gh through its own door (its config in etc/gh names the socket).
        if let a = f.agentSocket { env["SSH_AUTH_SOCK"] = a }
        if f.ghSocket != nil {
            env["GH_CONFIG_DIR"] = f.ghConfigDir
            env["GH_NO_UPDATE_NOTIFIER"] = "1"
        }
        // 683: the agent's own config home (private); the Claude login's placeholder (the proxy swaps it — never a token);
        // the bridges' shims first on PATH, and the browser a program asks for is the `open` shim.
        if let a = f.agent, a.isPrivate { env[a.config.homeEnv] = a.agentDir }
        // Claude Code keeps its own temp under /tmp/claude-<uid> (closed to a fence: it stops at start) unless told.
        if let a = f.agent, let v = agentTempVariables[a.recipe] { env[v] = f.tmp }
        for (k, v) in f.placeholders { env[k] = v }
        env["PATH"] = ([f.bin] + (env["PATH"] ?? "").split(separator: ":").map(String.init).filter { $0 != f.bin }).joined(separator: ":")
        // By name, not path: the session folder is under "Application Support", and many callers split $BROWSER on spaces.
        env["BROWSER"] = "open"
    }
}
