import CryptoKit
import Darwin
import DozableKit
import Foundation

/// The places a fenced session's rules are made of — every one resolved (`realpath`), because Seatbelt matches the
/// resolved path (`/tmp` is `/private/tmp`). `home` is the person's home (in a guarded test, the scratch home of
/// `DOZ_TEST_FENCE_HOME`); `store` the store root; `socketDirectory` the store's holder sockets; `userTemp` the per-user
/// temporary folder macOS keeps (the dashboard's old hand-off, the sockets — never writable by a fence).
public struct MacFencePlaces: Sendable, Equatable {
    public var home: String
    public var store: String
    public var socketDirectory: String
    public var userTemp: String
    /// `${XDG_CONFIG_HOME:-~/.config}/doz` — doz's own settings.
    public var dozConfig: String

    public init(home: String, store: String, socketDirectory: String, userTemp: String, dozConfig: String) {
        self.home = home
        self.store = store
        self.socketDirectory = socketDirectory
        self.userTemp = userTemp
        self.dozConfig = dozConfig
    }

    /// Every fenced session of this store keeps its own folder under here (outside the store, which the fence closes
    /// whole, and outside `/var/folders`, which macOS cleans): `~/Library/Application Support/Dozable/fence/<8 hex of the
    /// store path>`.
    public var fenceRoot: String { home + "/Library/Application Support/Dozable/fence/" + Self.storeHash(store) }

    public static func storeHash(_ store: String) -> String {
        SHA256.hash(data: Data(store.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
    }
}

/// The file model of a fenced session (`MacFence`): which folders may be named with `--read`/`--write` or as its
/// folder, what of the home it may READ (an allowlist), and the links on the PATH resolved read-only. Pure but for the
/// file system it looks at (`MacFencePathsTests` give it scratch homes).
public enum MacFencePaths {
    /// `realpath(3)`, or nil.
    public static func resolve(_ p: String) -> String? {
        guard let r = realpath(p, nil) else { return nil }
        defer { free(r) }
        return String(cString: r)
    }

    /// `.` and `..` taken out of an absolute path, lexically — never `URL.standardizedFileURL`, which also rewrites
    /// `/private/tmp` as `/tmp` (and every containment check with it).
    public static func lexical(_ p: String) -> String {
        var out: [Substring] = []
        for c in p.split(separator: "/", omittingEmptySubsequences: true) {
            if c == "." { continue }
            if c == ".." { if !out.isEmpty { out.removeLast() }; continue }
            out.append(c)
        }
        return "/" + out.joined(separator: "/")
    }

    /// `child` is `parent` or inside it.
    public static func isWithin(_ child: String, _ parent: String) -> Bool {
        child == parent || (parent == "/" ? child.hasPrefix("/") : child.hasPrefix(parent + "/"))
    }

    /// A path a profile can carry: absolute, ≤ 1024 bytes, no control character, no `"` or `\` (the profile's quoting).
    public static func pathProblem(_ p: String) -> String? {
        guard p.hasPrefix("/") else { return "not an absolute path" }
        guard p.utf8.count <= 1024 else { return "longer than 1024 bytes" }
        guard !p.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F || $0 == "\"" || $0 == "\\" }) else {
            return "has a control character, a quote or a backslash"
        }
        return nil
    }

    // MARK: refusals

    /// The places no `--read`/`--write` folder may be or contain, and a fenced session's folder may not be.
    public static func closedRoots(_ places: MacFencePlaces) -> [String] {
        let h = places.home
        return [h + "/.config", h + "/.ssh", h + "/Library", h + "/Library/Keychains", places.store, places.socketDirectory]
    }

    /// Why `dir` (resolved) cannot be a `--read`/`--write` folder (nil: it can) — the home, `/`, a parent of the home, the
    /// store, a socket folder, `~/.config`, `~/.ssh`, `~/Library` itself, `~/Library/Keychains`, or a folder containing one
    /// of those; and nothing inside the store, the socket folder, the fence's own folders or `~/Library/Keychains`.
    public static func folderRefusal(_ dir: String, _ places: MacFencePlaces) -> String? {
        if let p = pathProblem(dir) { return p }
        if dir == "/" { return "/ is the whole Mac" }
        if dir == places.home { return "it is your home" }
        if isWithin(places.home, dir) { return "it contains your home" }
        for c in closedRoots(places) {
            if dir == c { return "\(DisplayPath.tilde(c)) is closed to a fenced session" }
            if isWithin(c, dir) { return "it contains \(DisplayPath.tilde(c)), which is closed to a fenced session" }
        }
        for inside in [places.store, places.socketDirectory, places.fenceRoot, places.home + "/Library/Keychains", places.home + "/.ssh",
                       places.dozConfig] where isWithin(dir, inside) {
            return "it is inside \(DisplayPath.tilde(inside)), which is closed to a fenced session"
        }
        if isWithin(dir, places.userTemp) || dir.hasPrefix(places.userTemp) { return "it is in this user's temporary folder (holders' sockets)" }
        return nil
    }

    /// Why `dir` (resolved) cannot be a fenced session's folder: the `--write` refusals, and a folder whose own
    /// `.git/config` is not a regular file (a link, a folder, a FIFO — the host would never read it safely).
    public static func workdirRefusal(_ dir: String, _ places: MacFencePlaces) -> String? {
        if let why = folderRefusal(dir, places) { return why }
        if let k = MacFenceHostFS.kind(dir + "/.git"), k == S_IFDIR, let c = MacFenceHostFS.kind(dir + "/.git/config"), c != S_IFREG {
            return "its .git/config is not a regular file (a link or something else) — refused"
        }
        if MacFenceHostFS.kind(dir + "/.git") == S_IFLNK { return "its .git is a link — refused" }
        return nil
    }

    // MARK: the home's read allowlist

    /// Toolchain roots read-only (where installed): their programs run, nothing else of the home is opened.
    public static let toolchainRoots = [
        ".nvm", ".volta", ".bun/bin", ".deno/bin", ".local/bin", ".local/share/uv", ".local/share/mise", ".local/pipx",
        ".asdf", ".tool-versions", ".config/mise", ".pyenv", ".rbenv", ".cargo/bin", ".rustup", "go/bin",
        ".sdkman/candidates", "Library/pnpm", "Library/Developer/Toolchains",
    ]

    /// Places a link on the PATH is never followed into (secrets, configs, the person's caches, browsers' and mail data).
    public static let secretPlaces = [
        ".ssh", ".config", ".aws", ".gnupg", ".claude", ".cursor", ".gemini", ".snowflake", ".docker", ".kube",
        ".codex",   // the Mac's ~/.codex is closed to a fence like the rest (a path rule only — Dozable never reads it)
        ".claude.json", ".netrc", ".npmrc", ".pypirc", ".gitconfig", ".git-credentials", ".cache", ".npm",
        "Library/Keychains", "Library/Application Support", "Library/Preferences", "Library/Cookies", "Library/Mail",
        "Library/Messages", "Library/Caches", "Library/Containers", "Library/Group Containers", "Library/Safari",
    ]

    /// What of the home a fenced session reads, beyond its folders.
    public struct HomeReads: Equatable, Sendable {
        /// Folders, read-only.
        public var folders: [String] = []
        /// Single files, read-only.
        public var files: [String] = []
        /// What was not opened, and why (said once).
        public var notes: [String] = []
    }

    /// The read allowlist of `places.home` for a session whose PATH is `path`: the toolchain roots, every PATH entry
    /// (resolved) and, for each link in a PATH folder, its target — the target's folder, or its install root when that
    /// folder is a `bin/` (`.hermes/node/bin/node` → `.hermes/node`), never a folder directly in the home (then the file
    /// alone), never into a secret place or a refused folder; `~/.ssh/config` and `~/.ssh/*.pub`; `mac.fence_read`'s
    /// entries (`extra`, home-relative). The person's caches are NOT read (every cache is the session's own).
    public static func homeReads(_ places: MacFencePlaces, path: String, extra: [String] = [], keychain: Bool = false) -> HomeReads {
        let home = places.home
        var out = HomeReads()
        func covered(_ p: String) -> Bool { out.folders.contains { isWithin(p, $0) } }
        func secret(_ p: String) -> Bool {
            secretPlaces.contains { isWithin(p, home + "/" + $0) } && !toolchainRoots.contains { isWithin(p, home + "/" + $0) }
        }
        func topLevel(_ p: String) -> Bool { isWithin(p, home) && !String(p.dropFirst(home.count + 1)).contains("/") }
        func addFolder(_ p: String) { if !covered(p) { out.folders.removeAll { isWithin($0, p) }; out.folders.append(p) } }

        for r in toolchainRoots {
            let p = home + "/" + r
            guard let real = resolve(p) else { continue }
            if real == p { if MacFenceHostFS.kind(p) == S_IFREG { out.files.append(p) } else { addFolder(p) } }
            else if isWithin(real, home), !secret(real), folderRefusal(real, places) == nil { addFolder(real) }
        }
        // A link target: its folder (or install root), else the file alone.
        func addTarget(_ target: String, from: String) {
            guard isWithin(target, home), !covered(target) else { return }       // outside the home: the system roots decide
            if secret(target) { out.notes.append("\(DisplayPath.tilde(from)) points into \(DisplayPath.tilde(target)) — not followed"); return }
            let dir = (target as NSString).deletingLastPathComponent
            var root = (dir as NSString).lastPathComponent == "bin" ? (dir as NSString).deletingLastPathComponent : dir
            func bad(_ d: String) -> Bool { d == home || topLevel(d) || secret(d) || folderRefusal(d, places) != nil }
            if bad(root) { root = dir }
            if bad(root) { if !out.files.contains(target) { out.files.append(target) }; return }
            addFolder(root)
        }
        for entry in path.split(separator: ":").map(String.init) where entry.hasPrefix("/") {
            guard let real = resolve(entry) else { continue }
            if isWithin(real, home) || isWithin(home, real) {
                if let why = folderRefusal(real, places) { out.notes.append("PATH entry \(DisplayPath.tilde(entry)) not opened: \(why)"); continue }
                if secret(real) { out.notes.append("PATH entry \(DisplayPath.tilde(entry)) is in a closed place — not opened"); continue }
                addFolder(real)
            }
            // Each link in the folder: its target, read-only. A folder this user cannot write (`/usr/bin`, `/bin`: root's) has
            // no link the person made into their home — not scanned (it cost a fenced start ~15 ms).
            var st = stat()
            guard stat(real, &st) == 0, st.st_uid == getuid() || access(real, W_OK) == 0 else { continue }
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: real) else { continue }
            for n in names.sorted() {
                let e = real + "/" + n
                guard lstatKind(e) == S_IFLNK, let t = resolve(e), access(t, X_OK) == 0 else { continue }
                addTarget(t, from: e)
            }
        }
        if MacFenceHostFS.kind(home + "/.ssh/config") == S_IFREG { out.files.append(home + "/.ssh/config") }
        for n in ((try? FileManager.default.contentsOfDirectory(atPath: home + "/.ssh")) ?? []).sorted() where n.hasSuffix(".pub") {
            if MacFenceHostFS.kind(home + "/.ssh/" + n) == S_IFREG { out.files.append(home + "/.ssh/" + n) }
        }
        for rel in extra {
            let p = home + "/" + rel
            guard let real = resolve(p) else { out.notes.append("mac.fence_read: \(rel) is not there"); continue }
            if let why = folderRefusal(real, places) { out.notes.append("mac.fence_read: \(rel) refused — \(why)"); continue }
            if MacFenceHostFS.kind(real) == S_IFREG { out.files.append(real) } else { addFolder(real) }
        }
        if keychain { addFolder(home + "/Library/Keychains") }
        out.files = out.files.filter { !covered($0) }
        return out
    }

    static func lstatKind(_ p: String) -> mode_t? {
        var st = stat()
        guard lstat(p, &st) == 0 else { return nil }
        return st.st_mode & S_IFMT
    }

    /// `mac.fence_read`'s value: home-relative paths separated by commas (≤ 32, each without `..`, not absolute). Why it is
    /// not one (nil: it is).
    public static func fenceReadProblem(_ s: String) -> String? {
        let parts = fenceReadEntries(s)
        guard parts.count <= 32 else { return "at most 32 paths" }
        for p in parts {
            if p.hasPrefix("/") || p.hasPrefix("~") { return "\(p): a path relative to your home (like notes or src/lib)" }
            if p.split(separator: "/").contains("..") { return "\(p): no .." }
            if p.unicodeScalars.contains(where: { $0.value < 0x20 || $0 == "\"" || $0 == "\\" }) { return "\(p): no control character, quote or backslash" }
            if [".ssh", ".config", "Library", "Library/Keychains"].contains(p) || p.hasPrefix(".ssh/") || p.hasPrefix("Library/Keychains") {
                return "\(p) stays closed to a fenced session"
            }
        }
        return nil
    }

    public static func fenceReadEntries(_ s: String) -> [String] {
        s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            .map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
    }
}
