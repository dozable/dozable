import CryptoKit
import Foundation

// 657 — the person's DOTFILES in every sandbox (owner, 2026-10-19: "including the user's dotfiles (from their or someone
// else's dotfiles repo) … so that every shell experience in each VM is familiar"). The model, pure and unit-tested:
//
//   · the SOURCE — a git repository over https, or a folder on the Mac that is one (`DotfilesSource`);
//   · the PIN — the commit a sandbox got, recorded in its doz.json (`DotfilesPin`); fetched on the Mac with the Mac's own
//     git (a private repository uses the Mac's login — no credential ever reaches the guest), and only the FILES of that
//     commit enter the guest (a tar on an exec's stdin; no guest network);
//   · the PLAN — what applying them does (`DotfilesPlan`): the repository's own install script, the first of
//     Codespaces' names (install.sh, install, bootstrap.sh, bootstrap, script/bootstrap, setup.sh, setup, script/setup),
//     or, with none, every top-level dotfile and dot-folder symlinked into the home — never over an existing file, never
//     over DOZABLE's own paths (the agents' settings and state, their launchers, Dozable's state);
//   · the guest's side — the scripts the image's user runs (`DotfilesLayer.checkScript` / `applyScript`) and what one
//     run did (`DotfilesRun`).
//
// Applied per sandbox, never baked: at its first start (and again after `doz dotfiles NAME --update`); the guest
// remembers the commit it applied (`~/.local/share/doz/dotfiles.commit`), so a later start or wake does nothing.

/// A dotfiles source as a person gives it — checked and normalised.
public enum DotfilesSource {
    /// "none" (or "") — no dotfiles.
    public static let none = "none"
    public static let maximumLength = 512

    /// `""` and `none` are no dotfiles.
    public static func isNone(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        return t.isEmpty || t == none
    }

    /// A folder on the Mac (absolute, or `~/…`) rather than a URL.
    public static func isLocal(_ s: String) -> Bool { s.hasPrefix("/") || s.hasPrefix("~") }

    /// Why `s` is not a dotfiles source, or nil (`""` and `none` are fine: no dotfiles).
    public static func problem(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespaces)
        if isNone(t) { return nil }
        guard t.utf8.count <= maximumLength else { return "at most \(maximumLength) characters" }
        guard !t.unicodeScalars.contains(where: { $0.value < 0x21 || $0.value == 0x7F || (0x80...0x9F).contains($0.value) }) else {
            return "no spaces or control characters"
        }
        if isLocal(t) {
            guard t == "~" || t.hasPrefix("/") || t.hasPrefix("~/") else { return "a folder is an absolute path or ~/…" }
            guard !t.split(separator: "/").contains("..") else { return "a folder without .. in it" }
            return nil
        }
        guard let u = URLComponents(string: t), u.scheme?.lowercased() == "https", let host = u.host, !host.isEmpty else {
            return "a git repository's https:// URL (like https://github.com/you/dotfiles), or a folder on this Mac"
        }
        guard u.user == nil, u.password == nil else { return "no user name or token in the URL — the Mac's own git login is used" }
        guard u.query == nil, u.fragment == nil else { return "a repository's URL, without ? or #" }
        guard u.path.count > 1 else { return "the repository's path (https://github.com/you/dotfiles)" }
        return nil
    }

    /// The value as stored and compared: a URL as given (no trailing `/`), a folder absolute and standardised (`~`
    /// expanded with `home`). nil: none. Throws the `problem`.
    public static func normalized(_ s: String, home: String) throws -> String? {
        let t = s.trimmingCharacters(in: .whitespaces)
        if isNone(t) { return nil }
        if let p = problem(t) { throw DotfilesError(p) }
        if isLocal(t) {
            let expanded = t == "~" ? home : t.hasPrefix("~/") ? home + "/" + t.dropFirst(2) : t
            var path = URL(fileURLWithPath: expanded).standardizedFileURL.path
            while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
            return path
        }
        var u = t
        while u.hasSuffix("/") { u.removeLast() }
        return u
    }

    /// How a step or a line names it: a URL without its scheme (`github.com/you/dotfiles`), a folder by its name
    /// (`the folder dotfiles`) — the full path is the host's to show (with `~`).
    public static func label(_ normalized: String) -> String {
        if isLocal(normalized) { return "the folder " + (normalized as NSString).lastPathComponent }
        return normalized.hasPrefix("https://") ? String(normalized.dropFirst(8)) : normalized
    }

    /// The cache's directory name for a normalised source: 16 hex of its sha256.
    public static func cacheID(_ normalized: String) -> String {
        SHA256.hash(data: Data(normalized.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// What git fetches from: the URL, or `file://` + the folder (so a shallow fetch works for a folder too).
    public static func fetchURL(_ normalized: String) -> String {
        isLocal(normalized) ? URL(fileURLWithPath: normalized).absoluteString : normalized
    }
}

public struct DotfilesError: Error, Equatable, Sendable, LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// The dotfiles a sandbox has: where from and which commit (recorded in its doz.json at create, moved by `--update`).
public struct DotfilesPin: Codable, Equatable, Sendable {
    /// The normalised source (`DotfilesSource.normalized`).
    public var source: String
    /// The commit, 40 hex.
    public var commit: String
    public var resolvedAt: Date

    public init(source: String, commit: String, resolvedAt: Date = Date()) {
        self.source = source
        self.commit = commit
        self.resolvedAt = resolvedAt
    }

    public var shortCommit: String { String(commit.prefix(12)) }

    /// A commit id as git prints it.
    public static func isCommit(_ s: String) -> Bool {
        s.count == 40 && s.allSatisfy { $0.isHexDigit && ($0.isNumber || $0.isLowercase) }
    }
}

/// One entry of the commit's tree.
public struct DotfilesEntry: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case file, dir, link, submodule }
    /// Relative to the repository's root.
    public var path: String
    public var kind: Kind
    public init(_ path: String, _ kind: Kind) { self.path = path; self.kind = kind }
}

/// What applying the dotfiles does.
public struct DotfilesPlan: Codable, Equatable, Sendable {
    public struct Skip: Codable, Equatable, Sendable {
        public var path: String
        public var why: String
        public init(_ path: String, _ why: String) { self.path = path; self.why = why }
    }
    /// `script` (the repository's own install script runs) or `links` (its dotfiles are linked into the home).
    public var method: String
    /// The script, relative to the repository (`install.sh`, `script/bootstrap`).
    public var script: String?
    /// Home-relative paths linked to the same path in the repository (`.bashrc`, `.config/nvim`).
    public var links: [String]
    /// Dotfiles the link pass leaves alone, and why.
    public var skipped: [Skip]

    public init(method: String, script: String? = nil, links: [String] = [], skipped: [Skip] = []) {
        self.method = method
        self.script = script
        self.links = links
        self.skipped = skipped
    }

    /// One line: "install.sh runs" / "12 dotfiles linked into ~".
    public var summary: String {
        if let s = script { return "\(s) runs as the sandbox's user" }
        return links.isEmpty ? "nothing to link (no dotfiles at the top of the repository)"
            : "\(links.count) dotfile\(links.count == 1 ? "" : "s") linked into ~ (never over a file that is there)"
    }
}

/// What one apply did in the guest.
public struct DotfilesRun: Codable, Equatable, Sendable {
    public var source: String
    public var commit: String
    public var at: Date
    /// `script` or `links`.
    public var method: String
    public var script: String?
    /// The script's exit code (124: it ran out of time).
    public var exitCode: Int?
    public var linked: [String] = []
    /// Already linked by an earlier apply.
    public var unchanged: [String] = []
    /// There already (yours) — left as it is.
    public var kept: [String] = []
    /// The image's stock copy (`/etc/skel`) replaced — kept beside it as `NAME.doz-stock`.
    public var stock: [String] = []
    /// Links of an earlier commit whose file is gone — removed.
    public var dropped: [String] = []
    public var failedLinks: [String] = []
    /// The script's output, its last lines (inert).
    public var output: [String] = []
    /// The files were unpacked and the method ran to its end (a script's exit code decides `ok`).
    public var ok: Bool
    /// Why it failed (nil: it did not).
    public var failure: String?

    /// One line: "install.sh ran (exit 0)", "12 linked, 2 kept (yours)", "failed: …".
    public var summary: String {
        if let f = failure { return "failed: \(f)" }
        if let s = script {
            switch exitCode {
            case 0?: return "\(s) ran (exit 0)"
            case 124?: return "\(s) ran out of time (\(DotfilesLayer.scriptTimeoutSeconds) s)"
            case let c?: return "\(s) failed (exit \(c)) — its output: ~/\(DotfilesLayer.guestLogRelative)"
            case nil: return "\(s) did not run"
            }
        }
        var parts: [String] = []
        if !linked.isEmpty { parts.append("\(linked.count) linked") }
        if !unchanged.isEmpty { parts.append("\(unchanged.count) already linked") }
        if !stock.isEmpty { parts.append("\(stock.count) replacing the image's stock copy (kept as NAME.doz-stock)") }
        if !kept.isEmpty { parts.append("\(kept.count) kept (yours: \(kept.prefix(4).joined(separator: ", "))\(kept.count > 4 ? ", …" : ""))") }
        if !dropped.isEmpty { parts.append("\(dropped.count) old link\(dropped.count == 1 ? "" : "s") removed") }
        if !failedLinks.isEmpty { parts.append("\(failedLinks.count) could not be linked") }
        return parts.isEmpty ? "nothing to link" : parts.joined(separator: ", ")
    }
}

public enum DotfilesLayer {
    /// Codespaces' order: the first of these that the repository has is run instead of the link pass.
    public static let scriptNames = ["install.sh", "install", "bootstrap.sh", "bootstrap", "script/bootstrap", "setup.sh", "setup", "script/setup"]
    /// How long the script may run.
    public static let scriptTimeoutSeconds = 300
    /// The most a repository's files may weigh (the tar sent in).
    public static let maximumArchiveBytes = 64 << 20

    /// Where the files go in the guest, relative to the user's home — Dozable's own place (protected).
    public static let guestDirectoryRelative = ".local/share/doz/dotfiles"
    public static let guestMarkerRelative = ".local/share/doz/dotfiles.commit"
    public static let guestLogRelative = ".local/share/doz/dotfiles.log"

    /// Top-level names that belong to the repository, not to a home.
    public static let repositoryOwnNames: Set<String> = [".git", ".github", ".gitignore", ".gitmodules", ".gitattributes", ".DS_Store", ".travis.yml", ".gitlab-ci.yml", ".pre-commit-config.yaml"]

    /// The home-relative paths the link pass never touches — Dozable's: the agents' settings and state, their launchers,
    /// Dozable's own state. (`/run/doz`, `/etc/doz` and the workspace are outside the home: the link pass cannot reach
    /// them.) Plus every recipe's state folders under `~` and its launcher in `~/.local/bin`. An install script is NOT
    /// policed — it is code the person chose.
    public static var protectedPaths: [String] {
        var p = [".claude", ".claude.json", ".codex", ".pi", ".config/opencode", ".agents", ".local/state/doz", ".local/share/doz",
                 ".local/bin/claude", ".local/bin/codex", ".local/bin/pi"]
        for r in AgentRecipes.all {
            p.append(".local/bin/" + r.install.binary)
            for d in r.state.persist where d.hasPrefix("~/") { p.append(String(d.dropFirst(2))) }
        }
        var seen = Set<String>()
        return p.map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// `path` (home-relative) is Dozable's, or inside something that is. Every `.claude*` at the top is (Claude Code's
    /// settings, its backups).
    public static func isProtected(_ path: String, extra: [String] = []) -> Bool {
        if path.split(separator: "/").first.map({ $0.hasPrefix(".claude") }) == true { return true }
        return (protectedPaths + extra).contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    /// A name the link pass handles: printable, no control characters, not `.`/`..`.
    static func isPlainName(_ path: String) -> Bool {
        !path.isEmpty && path.utf8.count <= 1024 && !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
            && !path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F || (0x80...0x9F).contains($0.value) })
    }

    /// The commit's tree, from `git ls-tree -r -t -z <commit>` (`<mode> <type> <object>\t<path>\0`).
    public static func parseTree(_ out: Data) -> [DotfilesEntry] {
        var entries: [DotfilesEntry] = []
        for rec in out.split(separator: 0) {
            let s = String(decoding: rec, as: UTF8.self)
            guard let tab = s.firstIndex(of: "\t") else { continue }
            let head = s[..<tab].split(separator: " ")
            let path = String(s[s.index(after: tab)...])
            guard head.count == 3, !path.isEmpty else { continue }
            switch head[1] {
            case "tree": entries.append(DotfilesEntry(path, .dir))
            case "commit": entries.append(DotfilesEntry(path, .submodule))
            case "blob": entries.append(DotfilesEntry(path, head[0] == "120000" ? .link : .file))
            default: continue
            }
        }
        return entries
    }

    /// The repository's install script (the first of `scriptNames` it has, as a file or a link), or nil.
    public static func scriptChoice(_ entries: [DotfilesEntry]) -> String? {
        let files = Set(entries.filter { $0.kind == .file || $0.kind == .link }.map(\.path))
        return scriptNames.first { files.contains($0) }
    }

    /// What applying `entries` does: the install script, or the links (with what is skipped and why). `extraProtected`:
    /// more home-relative paths that are Dozable's (a share under the home).
    public static func plan(_ entries: [DotfilesEntry], extraProtected: [String] = []) -> DotfilesPlan {
        if let s = scriptChoice(entries) { return DotfilesPlan(method: "script", script: s) }
        var links: [String] = []
        var skipped: [DotfilesPlan.Skip] = []
        let protected = protectedPaths + extraProtected
        var children: [String: [DotfilesEntry]] = [:]
        for e in entries {
            let parent = (e.path as NSString).deletingLastPathComponent
            children[parent, default: []].append(e)
        }
        func consider(_ e: DotfilesEntry, top: Bool) {
            if top, repositoryOwnNames.contains(e.path) { skipped.append(.init(e.path, "the repository's own file")); return }
            guard isPlainName(e.path) else { skipped.append(.init(e.path, "an unusual name")); return }
            if e.kind == .submodule { skipped.append(.init(e.path, "a submodule (not fetched)")); return }
            if isProtected(e.path, extra: extraProtected) { skipped.append(.init(e.path, "Dozable's own")); return }
            // A folder that holds something of Dozable's (`.config` holds `.config/opencode`, `.local` the launchers):
            // never linked whole — its entries are, one by one.
            if e.kind == .dir, protected.contains(where: { $0.hasPrefix(e.path + "/") }) {
                for c in (children[e.path] ?? []).sorted(by: { $0.path < $1.path }) { consider(c, top: false) }
                return
            }
            links.append(e.path)
        }
        for e in (children[""] ?? []).sorted(by: { $0.path < $1.path }) where e.path.hasPrefix(".") && e.path != "." {
            consider(e, top: true)
        }
        return DotfilesPlan(method: "links", links: links, skipped: skipped)
    }

    // MARK: the guest's side (the image's user runs these)

    /// `'…'` for sh.
    public static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// The commit the guest applied last (`applied=<commit>`), cheap.
    public static func checkScript(home: String) -> String {
        "f=\(quote(home + "/" + guestMarkerRelative)); [ -f \"$f\" ] && echo \"applied=$(head -c 64 \"$f\" | tr -d '\\n')\"; exit 0"
    }

    /// The commit in `checkScript`'s answer (nil: none applied).
    public static func appliedCommit(_ out: String) -> String? {
        for line in out.split(separator: "\n") where line.hasPrefix("applied=") {
            let c = String(line.dropFirst(8)).trimmingCharacters(in: .whitespaces)
            return c.isEmpty ? nil : c
        }
        return nil
    }

    /// Apply `plan` at `commit` — the files arrive as a tar on stdin. Run as the image's user, `home` its home. One line
    /// per thing done (`doz-dotfiles …`, `doz-dotfile STATE PATH`, `doz-out TEXT`). Never fails the caller.
    public static func applyScript(plan: DotfilesPlan, commit: String, home: String, timeout: Int = scriptTimeoutSeconds) -> String {
        var s = """
        H=\(quote(home)); S="$H/.local/share/doz"; D="$S/dotfiles"; L="$S/dotfiles.log"
        export HOME="$H"; umask 022
        say() { printf 'doz-dotfile %s %s\\n' "$1" "$2"; }
        mkdir -p "$S" 2>/dev/null || { echo "doz-dotfiles failed could not make $S"; exit 0; }
        rm -rf "$D.new" "$D.old"; mkdir "$D.new" || { echo "doz-dotfiles failed could not make $D.new"; exit 0; }
        if ! tar -x -f - -C "$D.new" 2>"$S/unpack.err"; then echo "doz-dotfiles failed could not unpack the files: $(head -c 200 "$S/unpack.err" | tr '\\n' ' ')"; rm -rf "$D.new"; exit 0; fi
        rm -f "$S/unpack.err"
        if [ -e "$D" ]; then mv "$D" "$D.old"; fi; mv "$D.new" "$D"; rm -rf "$D.old"
        echo "doz-dotfiles files"
        find "$H" -xdev -maxdepth 4 -type l 2>/dev/null | while IFS= read -r l; do case "$(readlink "$l")" in "$D"/*) [ -e "$l" ] || { rm -f "$l" && say dropped "${l#"$H"/}"; };; esac; done

        """
        if let script = plan.script {
            s += """
            cd "$D" || { echo "doz-dotfiles failed the files are not there"; exit 0; }
            f=\(quote(script)); T=""; command -v timeout >/dev/null 2>&1 && T="timeout \(timeout)"
            if head -n 1 "$f" 2>/dev/null | grep -q '^#!'; then chmod u+x "$f" 2>/dev/null; $T "./$f" </dev/null >"$L" 2>&1; rc=$?
            else $T sh "./$f" </dev/null >"$L" 2>&1; rc=$?; fi
            echo "doz-dotfiles script $rc"
            tail -n 40 "$L" 2>/dev/null | while IFS= read -r x; do printf 'doz-out %s\\n' "$x"; done

            """
        } else {
            s += """
            l() { t="$H/$1"; f="$D/$1"
              if [ -L "$t" ] && [ "$(readlink "$t")" = "$f" ]; then say ok "$1"; return; fi
              if [ -e "$t" ] || [ -L "$t" ]; then
                if [ -f "$t" ] && [ ! -L "$t" ] && [ -f "/etc/skel/$1" ] && [ ! -e "$t.doz-stock" ] && cmp -s "/etc/skel/$1" "$t" 2>/dev/null; then
                  if mv "$t" "$t.doz-stock" && ln -s "$f" "$t"; then say stock "$1"; return; fi
                fi
                say kept "$1"; return
              fi
              mkdir -p "$(dirname "$t")" 2>/dev/null
              if ln -s "$f" "$t" 2>/dev/null; then say linked "$1"; else say failed "$1"; fi
            }

            """
            for p in plan.links { s += "l \(quote(p))\n" }
        }
        s += "printf '%s\\n' \(quote(commit)) > \"$S/dotfiles.commit\"; echo \"doz-dotfiles done\"; exit 0\n"
        return s
    }

    /// What `applyScript` printed, as a run.
    public static func results(_ out: String, pin: DotfilesPin, plan: DotfilesPlan, at: Date = Date()) -> DotfilesRun {
        var r = DotfilesRun(source: pin.source, commit: pin.commit, at: at, method: plan.method, script: plan.script, ok: false)
        var unpacked = false, done = false
        for raw in out.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("doz-out ") {
                r.output.append(InertText.line(raw.dropFirst(8)))
            } else if line.hasPrefix("doz-dotfile ") {
                let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
                guard parts.count == 3 else { continue }
                switch parts[1] {
                case "linked": r.linked.append(parts[2])
                case "ok": r.unchanged.append(parts[2])
                case "kept": r.kept.append(parts[2])
                case "stock": r.stock.append(parts[2])
                case "dropped": r.dropped.append(parts[2])
                default: r.failedLinks.append(parts[2])
                }
            } else if line == "doz-dotfiles files" {
                unpacked = true
            } else if line == "doz-dotfiles done" {
                done = true
            } else if line.hasPrefix("doz-dotfiles script ") {
                r.exitCode = Int(line.dropFirst("doz-dotfiles script ".count))
            } else if line.hasPrefix("doz-dotfiles failed ") {
                r.failure = InertText.line(raw.dropFirst("doz-dotfiles failed ".count))
            }
        }
        if r.output.count > 40 { r.output = Array(r.output.suffix(40)) }
        if r.failure == nil, !unpacked { r.failure = "no answer from the guest" }
        if r.failure == nil, !done { r.failure = "it stopped before its end" }
        if r.failure == nil, plan.script != nil, r.exitCode == nil { r.failure = "the script did not run" }
        r.ok = r.failure == nil && (plan.script == nil ? r.failedLinks.isEmpty : r.exitCode == 0)
        return r
    }
}

/// What a sandbox applies (the host sets it): the pin, and how the files and the plan are had (the Mac's cache —
/// fetched once; the plan computed from the commit's tree).
public struct DotfilesInput: Sendable {
    public var pin: DotfilesPin
    public var fetch: @Sendable () async -> Result<DotfilesPayload, DotfilesError>
    public init(pin: DotfilesPin, fetch: @escaping @Sendable () async -> Result<DotfilesPayload, DotfilesError>) {
        self.pin = pin
        self.fetch = fetch
    }
}

/// The files of the pinned commit (a tar) and what applying them does.
public struct DotfilesPayload: Sendable {
    public var archive: Data
    public var plan: DotfilesPlan
    public init(archive: Data, plan: DotfilesPlan) { self.archive = archive; self.plan = plan }
}
