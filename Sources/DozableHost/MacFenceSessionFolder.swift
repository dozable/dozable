import Darwin
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
        let known = FileManager.default.contents(atPath: f.places.home + "/.ssh/known_hosts").flatMap { $0.count <= 4 << 20 ? $0 : nil } ?? Data()
        try MacFenceHostFS.writeAtomically(known, dir: f.ssh, name: "known_hosts", mode: 0o600)
        return out
    }

    /// The fenced login shell's rc: a prompt that says so, nothing of the person's (their rc files often export tokens).
    static let zshrc = """
    # Written by Dozable for a fenced session. Your own ~/.zshrc is closed to it (rc files often export tokens).
    PROMPT='%n@%m (fenced) %1~ %# '

    """
}
