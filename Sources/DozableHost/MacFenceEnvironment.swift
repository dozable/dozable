import Foundation

/// What a FENCED session's environment adds to the allowlist `MacSessionsEnvironment.build` makes — pure;
/// `MacFenceEnvironmentTests`. Nothing a fenced program writes may be loaded later by something unfenced, so every
/// temp folder and tool cache it knows of points into the session's own folder; git reads a host-written config and an
/// empty template; the person's SSH agent is not passed. `DOZ_*` variables are only `DOZ_TTY` (the holder's) and
/// `DOZ_FENCE`.
public enum MacFenceEnvironment {
    /// The variables a fenced session never inherits from the allowlist.
    public static let removed = ["SSH_AUTH_SOCK"]

    /// Each tool cache, under `<session>/cache/` (they persist across the session's restarts, and are emptied when a
    /// re-open widens its grants).
    public static let caches: [(String, String)] = [
        ("XDG_CACHE_HOME", "xdg"), ("npm_config_cache", "npm"), ("YARN_CACHE_FOLDER", "yarn"), ("npm_config_store_dir", "pnpm"),
        ("BUN_INSTALL_CACHE_DIR", "bun"), ("PIP_CACHE_DIR", "pip"), ("UV_CACHE_DIR", "uv"), ("CARGO_HOME", "cargo"),
        ("GOMODCACHE", "gomod"), ("GOCACHE", "go"), ("PRE_COMMIT_HOME", "pre-commit"), ("PLAYWRIGHT_BROWSERS_PATH", "playwright"),
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
    public static func proxy(port: UInt16, password: String, etc: String?) -> [String: String] {
        var e: [String: String] = [:]
        let url = "http://doz:\(password)@127.0.0.1:\(port)"
        for k in ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy"] { e[k] = url }
        for k in ["NO_PROXY", "no_proxy"] { e[k] = "localhost,127.0.0.1,::1" }
        e["NODE_USE_ENV_PROXY"] = "1"
        e["GIT_CONFIG_COUNT"] = "1"
        e["GIT_CONFIG_KEY_0"] = "http.proxyAuthMethod"
        e["GIT_CONFIG_VALUE_0"] = "basic"
        if let etc {
            e["NODE_EXTRA_CA_CERTS"] = etc + "/ca.pem"
            for k in ["SSL_CERT_FILE", "REQUESTS_CA_BUNDLE", "CURL_CA_BUNDLE", "GIT_SSL_CAINFO"] { e[k] = etc + "/ca-bundle.pem" }
        }
        return e
    }

    /// Add the fenced session's variables to `env` (the allowlist already built); `proxyPassword`: its proxy's (with
    /// `f.proxyPort`), `ca`: the CA copies are in its `etc/`.
    public static func add(_ env: inout [String: String], fence f: MacFence, proxyPassword: String? = nil, ca: Bool = false) {
        if let port = f.proxyPort, let pw = proxyPassword {
            for (k, v) in proxy(port: port, password: pw, etc: ca ? f.etc : nil) { env[k] = v }
        }
        for k in removed { env[k] = nil }
        env["TMPDIR"] = f.tmp + "/"
        for (k, sub) in caches { env[k] = f.cache + "/" + sub }
        // Cargo keeps its programs in CARGO_HOME/bin: the person's ~/.cargo/bin stays first on PATH (read-only).
        env["GIT_CONFIG_GLOBAL"] = f.etc + "/gitconfig"
        env["GIT_CONFIG_NOSYSTEM"] = nil
        env["GIT_TEMPLATE_DIR"] = f.etc + "/git-template"
        env["GIT_SSH_COMMAND"] = "ssh -o UserKnownHostsFile=\(f.ssh)/known_hosts"
        env["ZDOTDIR"] = f.etc + "/shell"
        env["HISTFILE"] = f.tmp + "/history"
        env["DISABLE_AUTOUPDATER"] = "1"
        env["GOTELEMETRY"] = "off"
        env["DOZ_FENCE"] = MacFence.profileKind
    }
}
