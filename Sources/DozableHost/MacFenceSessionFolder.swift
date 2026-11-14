import Darwin
import DozableKit
import Foundation

/// A fenced session's own folder, `<fence root>/<session>/` (0700) — made, and RE-SEEDED at every open, only through
/// `MacFenceHostFS`:
///
/// - `etc/` (host-owned; the fence may read it, never write, rename or unlink it): `gitconfig` (the person's identity and
///   a few behaviour keys from an ALLOWLIST — never credentials, aliases, includes, hooks, fsmonitor, pager, editor or
///   sshCommand), `excludes` (the person's global ignore file, copied), an empty `git-template/` (no hooks folder on
///   init/clone), `shell/.zshrc` (the person's rc files often export tokens and stay closed), and the sentinel;
/// - `tmp/` (its TMPDIR) emptied;
/// - `cache/` (every tool cache) and `derived/` (Xcode's) kept across restarts — emptied when the open WIDENS the grants
///   recorded last time;
/// - `ssh/known_hosts` seeded again from the person's (public keys; new ones stay in the session).
public enum MacFenceSessionFolder {
    /// The person's git keys a fenced session gets (lower-cased as `git config --list` prints them).
    public static let gitKeys = ["user.name", "user.email", "init.defaultbranch", "pull.rebase", "push.autosetupremote",
                                 "core.autocrlf", "merge.conflictstyle"]
    /// git-lfs's standard filter, carried only with exactly these values.
    public static let lfsFilter = ["filter.lfs.clean": "git-lfs clean -- %f", "filter.lfs.smudge": "git-lfs smudge -- %f",
                                   "filter.lfs.process": "git-lfs filter-process", "filter.lfs.required": "true"]

    /// What the person's own git config says (read by the host, outside the fence).
    public struct PersonGit: Equatable, Sendable {
        public var values: [(String, String)] = []
        /// The text of their global excludes file (nil: none).
        public var excludes: String?
        /// Their global `core.hooksPath` (expanded), when set.
        public var hooksPath: String?
        public init() {}
        public static func == (a: PersonGit, b: PersonGit) -> Bool {
            a.values.map { $0.0 + "=" + $0.1 } == b.values.map { $0.0 + "=" + $0.1 } && a.excludes == b.excludes && a.hooksPath == b.hooksPath
        }
    }

    /// The person's global git config (`git config --global --includes --list -z`, HOME = `home`), the allowlisted keys.
    public static func personGit(home: String) -> PersonGit {
        var out = PersonGit()
        let env = ["HOME": home, "PATH": "/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM": "1", "LANG": "C"]
        guard let text = MacFenceGit.runGit(["config", "--global", "--includes", "--list", "-z"], environment: env, cwd: home) else { return out }
        var excludesFile: String?
        for (k, v) in MacFenceGit.parseList(text) {
            if gitKeys.contains(k) { out.values.append((k, v)) }
            if let want = lfsFilter[k], want == v { out.values.append((k, v)) }
            if k == "core.excludesfile" { excludesFile = expand(v, home: home) }
            if k == "core.hookspath" { out.hooksPath = expand(v, home: home) }
        }
        let file = excludesFile ?? home + "/.config/git/ignore"
        if let d = FileManager.default.contents(atPath: file), d.count <= 1 << 20 { out.excludes = String(decoding: d, as: UTF8.self) }
        return out
    }

    static func expand(_ v: String, home: String) -> String {
        v == "~" ? home : v.hasPrefix("~/") ? home + v.dropFirst(1) : v
    }

    /// A value as git's config file needs it: quoted, `\` and `"` escaped, no newline.
    static func quoted(_ v: String) -> String {
        "\"" + v.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ") + "\""
    }

    /// `etc/gitconfig`'s text.
    public static func gitconfig(_ person: PersonGit, etc: String) -> String {
        var sections: [String: [(String, String)]] = [:]
        var order: [String] = []
        func put(_ key: String, _ value: String) {
            let parts = key.split(separator: ".").map(String.init)
            let name = parts.last!
            let section = parts.count == 3 ? "\(parts[0]) \"\(parts[1])\"" : parts[0]
            if sections[section] == nil { order.append(section) }
            sections[section, default: []].append((name, value))
        }
        for (k, v) in person.values { put(k, v) }
        put("core.excludesfile", etc + "/excludes")
        var out = "# Written by Dozable for a fenced session at every start — your identity and a few keys from your global config.\n"
        for s in order {
            out += "[\(s)]\n"
            for (n, v) in sections[s]! { out += "\t\(n) = \(quoted(v))\n" }
        }
        return out
    }

    public struct Seeded: Sendable {
        public var cachesCleared = false
        public var notes: [String] = []
    }

    /// Make and re-seed the session folder of `f`. `previous`: the grants recorded at its last open (nil: none).
    public static func prepare(_ f: MacFence, previous: MacFenceGrants?, person: PersonGit) throws -> Seeded {
        var out = Seeded()
        try MacFenceHostFS.ensureDirectory(f.places.fenceRoot)
        if MacFenceHostFS.kind(f.antiSentinel) == nil {
            try MacFenceHostFS.writeAtomically(Data(), dir: f.places.fenceRoot, name: (f.antiSentinel as NSString).lastPathComponent, mode: 0o400)
        }
        try MacFenceHostFS.ensureDirectory(f.sessionFolder)
        chmod(f.sessionFolder, 0o700)
        for d in [f.tmp, f.cache, f.derived, f.etc, f.ssh] {
            // The program may have put a link (or a file) where a folder was: it goes, as itself — never followed.
            if let k = MacFenceHostFS.kind(d), k != S_IFDIR {
                try MacFenceHostFS.remove(d)
                out.notes.append("\((d as NSString).lastPathComponent)/ was not a folder — removed and made again")
            }
            try MacFenceHostFS.ensureDirectory(d)
        }
        out.notes += try MacFenceHostFS.clearContents(f.tmp)
        if f.grants.widens(previous) {
            out.notes += try MacFenceHostFS.clearContents(f.cache)
            out.notes += try MacFenceHostFS.clearContents(f.derived)
            out.cachesCleared = true
        }
        out.notes += try MacFenceHostFS.clearContents(f.etc)
        try MacFenceHostFS.writeAtomically(Data(gitconfig(person, etc: f.etc).utf8), dir: f.etc, name: "gitconfig", mode: 0o400)
        try MacFenceHostFS.writeAtomically(Data((person.excludes ?? "").utf8), dir: f.etc, name: "excludes", mode: 0o400)
        try MacFenceHostFS.ensureDirectory(f.etc + "/git-template")
        try MacFenceHostFS.ensureDirectory(f.etc + "/shell")
        try MacFenceHostFS.writeAtomically(Data(zshrc.utf8), dir: f.etc + "/shell", name: ".zshrc", mode: 0o400)
        try MacFenceHostFS.writeAtomically(Data("this session's sentinel\n".utf8), dir: f.etc, name: (f.sentinel as NSString).lastPathComponent, mode: 0o400)
        // 683: the bridges' shims — `open` and `xdg-open` (also $BROWSER), host-owned like the rest of etc/.
        try MacFenceHostFS.ensureDirectory(f.bin)
        for name in ["open", "xdg-open"] {
            try MacFenceHostFS.writeAtomically(Data(openShim(workdir: f.workdir).utf8), dir: f.bin, name: name, mode: 0o555)
        }
        // 683 M4: `ssh` itself goes through the proxy too (git's own ssh is GIT_SSH_COMMAND); gh reaches GitHub through its
        // door into the proxy (`http_unix_socket`: gh speaks plain HTTP there and the proxy swaps the placeholder — Go on
        // macOS trusts only the system's certificates, never a session's CA, so the decrypting tunnel cannot serve it).
        try MacFenceHostFS.writeAtomically(Data(sshShim(f).utf8), dir: f.bin, name: "ssh", mode: 0o555)
        if let sock = f.ghSocket {
            for d in [f.cache + "/config", f.ghConfigDir] {
                if let k = MacFenceHostFS.kind(d), k != S_IFDIR { try MacFenceHostFS.remove(d) }
                try MacFenceHostFS.ensureDirectory(d)
            }
            try MacFenceHostFS.writeAtomically(Data(ghConfig(socket: sock).utf8), dir: f.ghConfigDir, name: "config.yml", mode: 0o600)
        }
        let known = FileManager.default.contents(atPath: f.places.home + "/.ssh/known_hosts").flatMap { $0.count <= 4 << 20 ? $0 : nil } ?? Data()
        try MacFenceHostFS.writeAtomically(known, dir: f.ssh, name: "known_hosts", mode: 0o600)
        return out
    }

    /// 683 M4: the session's `ssh` (first on its PATH): `/usr/bin/ssh` with the fence's options — through `doz fence-connect`,
    /// the session's own `known_hosts`.
    public static func sshShim(_ f: MacFence) -> String {
        let opts = MacFenceEnvironment.sshOptions(doz: f.dozExecutable, knownHosts: f.ssh + "/known_hosts")
        return "#!/bin/sh\n# doz:fence-ssh-shim:v1 — written by Dozable for a fenced session on this Mac at every start.\n"
            + "exec /usr/bin/ssh" + opts.map { " -o " + MacFenceEnvironment.shellQuoted($0) }.joined() + " \"$@\"\n"
    }

    /// 683 M4: gh's config in a session with GitHub as the person (`GH_CONFIG_DIR`, in its caches — gh rewrites it).
    public static func ghConfig(socket: String) -> String {
        "# Written by Dozable for a fenced session at every start: gh reaches GitHub through Dozable's proxy, signed in as you.\n"
            + "http_unix_socket: \(socket)\ngit_protocol: https\nprompt: disabled\n"
    }

    /// 683: a fenced session's `open` / `xdg-open` (and `$BROWSER`): `open`, `osascript` and LaunchServices are closed to
    /// it, so a URL, or a document or folder in its folder, is handed to the Mac as the guest shim does — ONLY the marker
    /// `ESC]6340;doz-open;URL BEL` (`doz-file;APP;PATH`, `doz-reveal;PATH`) on its terminal (`/dev/tty`, else `$DOZ_TTY`,
    /// else stdout when it is one), never a line a person sees. The host decides (http/https, the folder only, the
    /// switches, a notice to every viewer); these checks only tell the agent why at once.
    public static func openShim(workdir: String) -> String {
        let wd = "'" + workdir.replacingOccurrences(of: "'", with: "'\\''") + "'"
        func patterns(_ t: [String]) -> String { t.map { "*.\($0)" }.joined(separator: "|") }
        return #"""
        #!/bin/sh
        # doz:fence-open-shim:v1 — written by Dozable for a fenced session on this Mac at every start.
        # A URL opens in your browser, a document or folder of the session's folder in your app or the Finder (--reveal
        # shows it in its folder) — asked through the session's terminal; doz announces each one. Nothing else opens.
        me=${0##*/}
        wd=\#(wd)
        reveal=""
        app=""
        status=0
        refuse() { echo "$me: $*" >&2; status=1; }
        send() {
            if [ -w /dev/tty ] 2>/dev/null && printf '\033]6340;%s\007' "$1" 2>/dev/null > /dev/tty; then return 0; fi
            if [ -n "${DOZ_TTY:-}" ] && [ -w "$DOZ_TTY" ] && printf '\033]6340;%s\007' "$1" 2>/dev/null > "$DOZ_TTY"; then return 0; fi
            if [ -t 1 ]; then printf '\033]6340;%s\007' "$1"; return 0; fi
            refuse "no terminal of a Dozable session to reach your Mac through"
        }
        while [ $# -gt 0 ]; do
            case "$1" in
                -R|--reveal) reveal=1; shift ;;
                -a|--app) [ $# -ge 2 ] || { refuse "-a needs an app's name"; exit 1; }; app="$2"; shift 2 ;;
                -h|--help) echo "usage: $me URL | PATH...   (a PATH in $wd; -R shows it in its folder; -a APP: an app you allowed)" >&2; exit 0 ;;
                --) shift; break ;;
                -?*) refuse "unknown option $1 (in a fenced session $me opens a URL, or a file of its folder, on your Mac)"; exit 1 ;;
                *) break ;;
            esac
        done
        [ $# -ge 1 ] || { refuse "what to open? a URL or a path"; exit 1; }
        case "$app" in -*|.*|*/*|*';'*|*,*) refuse "\"$app\" is not an app name"; exit 1 ;; esac
        for t in "$@"; do
            if [ "${#t}" -gt 2048 ]; then refuse "longer than 2048 bytes: not sent"; continue; fi
            clean=$(printf '%s' "$t" | tr -d '\000-\037\177')
            [ "$clean" = "$t" ] || { refuse "control characters: not sent"; continue; }
            case "$t" in
                http://*|https://*)
                    [ -z "$reveal$app" ] || { refuse "-R and -a are for files, not a URL"; continue; }
                    send "doz-open;$t"; continue ;;
            esac
            if [ ! -e "$t" ]; then
                if printf '%s' "$t" | grep -Eq '^[A-Za-z][A-Za-z0-9+.-]*:'; then refuse "only http and https URLs go to your browser: $t"; else refuse "no such file: $t"; fi
                continue
            fi
            case "$t" in /*) p=$t ;; *) p=./$t ;; esac
            abs=$(cd "$(dirname "$p")" 2>/dev/null && printf '%s/%s' "$(pwd -P)" "$(basename "$p")")
            [ -d "$p" ] && abs=$(cd "$p" 2>/dev/null && pwd -P)
            case "$abs" in
                "$wd"|"$wd"/*) ;;
                *) refuse "only files and folders in $wd (this session's folder) are opened on your Mac, not $t"; continue ;;
            esac
            if [ -n "$reveal" ]; then send "doz-reveal;$abs"; continue; fi
            lower=$(printf '%s' "${abs##*/}" | tr 'A-Z' 'a-z')
            if [ -d "$abs" ]; then
                case "$lower" in \#(patterns(GuestCommand.openFileNeverTypes))) refuse "${abs##*/} is an app or package: never opened ($me -R shows it)"; continue ;; esac
                send "doz-file;;$abs"; continue
            fi
            case "$lower" in
                \#(patterns(GuestCommand.openFileNeverTypes))) refuse "${abs##*/} is a program, script or installer: never opened"; continue ;;
                \#(patterns(GuestCommand.openFileDocumentTypes))) ;;
                *) refuse "only documents are opened on your Mac (html, md, pdf, images, txt, csv, json, yaml, xml...), not ${abs##*/}"; continue ;;
            esac
            [ -x "$abs" ] && { refuse "${abs##*/} is executable: never opened"; continue; }
            send "doz-file;$app;$abs"
        done
        exit $status
        """# + "\n"
    }

    /// The fenced login shell's rc: a prompt that says so, nothing of the person's (their rc files often export tokens).
    static let zshrc = """
    # Written by Dozable for a fenced session. Your own ~/.zshrc is closed to it (rc files often export tokens).
    PROMPT='%n@%m (fenced) %1~ %# '

    """
}
