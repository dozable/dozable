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

    /// Add the fenced session's variables to `env` (the allowlist already built).
    public static func add(_ env: inout [String: String], fence f: MacFence) {
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
