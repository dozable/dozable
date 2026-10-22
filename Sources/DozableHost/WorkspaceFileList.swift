import Darwin
import Foundation
import DozableKit

// 643 (624.B1 part 1; owner, 2026-10-19: "a file explorer panel in the ui sidebar ; should be a low-impact file watcher
// that is streaming file / folder changes into the browser"): what a folder of a sandbox's /workspace holds — the reads
// under the panel. Two sources, by where the bytes live:
//
//   · a SHARED workspace is read ON THE MAC — never a guest call, so listing never wakes anything and works with the
//     sandbox off. The path discipline is the open-files bridge's (`WorkspaceFiles`): the asked path normalised
//     LEXICALLY under /workspace, mapped onto the Mac folder from the sandbox's RECORD (never a guest path), `realpath`
//     on the Mac, and the result must be the share's own realpath or inside it. Entries are `lstat`ed: a link is never
//     followed (its target is read for display only). The workspace rules are honoured as the guest's view applies them:
//     a hidden name is absent, a locked one listed `locked` (no size or time), a read-only one marked.
//   · an ISOLATED sandbox is listed from the guest — one utility exec as the image's user, only while it runs.
//
// Names come from inside a sandbox: untrusted text. They are made inert here (`FileListPaths.inert`) before they reach
// any client — no control or bidi-override character, at most 255 characters.

/// One entry of a folder.
public struct FileEntry: Codable, Equatable, Sendable {
    /// The name, made inert (see `altered`).
    public var name: String
    /// `file`, `folder`, `link` or `other` (a device, socket or pipe).
    public var kind: String
    /// A file's size in bytes (nil: a folder, a link, or a locked entry).
    public var size: Int64?
    public var modified: Date?
    /// A link's target as written (display only — never followed), made inert.
    public var target: String?
    /// The workspace rules' verdict: nil (visible), `read-only` or `locked`.
    public var state: String?
    /// The name had characters that cannot be shown (replaced by U+FFFD) or was cut.
    public var altered: Bool?

    public init(name: String, kind: String, size: Int64? = nil, modified: Date? = nil, target: String? = nil, state: String? = nil,
                altered: Bool? = nil) {
        self.name = name; self.kind = kind; self.size = size; self.modified = modified; self.target = target
        self.state = state; self.altered = altered
    }
}

/// `files-list`: one folder.
public struct FileList: Codable, Equatable, Sendable {
    public var sandbox: String
    /// The folder in the sandbox (`/workspace` or below).
    public var path: String
    /// `mac` (the shared folder, read on this Mac) or `guest` (an isolated sandbox, read inside it).
    public var source: String
    /// `mac`: changes can be watched (`doz files --watch`, the web watch stream); `none`: list again to refresh.
    public var watch: String
    /// The workspace rules were applied (a rule file is in the folder and `workspace.view` is on).
    public var rules: Bool
    /// The folder's own verdict (nil: visible; `read-only`).
    public var state: String?
    public var entries: [FileEntry]
    /// More than `FileListPaths.maximumEntries` entries: the first ones (folders first, then by name) are listed.
    public var truncated: Bool
    /// Names that could not be listed (a newline in a name, in the guest).
    public var unlisted: Int?

    public init(sandbox: String, path: String, source: String, watch: String, rules: Bool, state: String? = nil, entries: [FileEntry],
                truncated: Bool, unlisted: Int? = nil) {
        self.sandbox = sandbox; self.path = path; self.source = source; self.watch = watch; self.rules = rules; self.state = state
        self.entries = entries; self.truncated = truncated; self.unlisted = unlisted
    }
}

/// One coalesced batch of a watch: the watched folders whose listing changed (never a name), or `resync` (list every
/// watched folder again).
public struct FileChangeBatch: Codable, Equatable, Sendable {
    public var sandbox: String
    public var folders: [String]
    public var resync: Bool
    public var time: Date

    public init(sandbox: String, folders: [String], resync: Bool, time: Date = Date()) {
        self.sandbox = sandbox; self.folders = folders; self.resync = resync; self.time = time
    }
}

/// The paths and the limits.
public enum FileListPaths {
    public static let root = DozableImages.workspaceGuestPath
    public static let maximumPathBytes = 1024
    /// At most this many entries of one folder are listed.
    public static let maximumEntries = 2000
    /// At most this many names of one folder are looked at (a folder of a million files stays cheap).
    public static let maximumScanned = 50_000
    public static let maximumNameCharacters = 255
    public static let maximumTargetCharacters = 1024

    /// A folder as asked (nil or "": /workspace; relative: under /workspace; absolute: /workspace or below) → its guest
    /// path and its path relative to /workspace ("" for /workspace itself). nil: not a path in /workspace (`..` never
    /// climbs above it), a control character, or too long.
    public static func folder(_ given: String?) -> (guest: String, rel: String)? {
        let g = given ?? ""
        guard g.utf8.count <= maximumPathBytes, !g.unicodeScalars.contains(where: isControl) else { return nil }
        if g.isEmpty || g == "." { return (root, "") }
        let abs = g.hasPrefix("/") ? g : root + "/" + g
        guard let rel = WorkspaceFiles.lexicalRelative(abs, root: true) else { return nil }
        return (rel.isEmpty ? root : root + "/" + rel, rel)
    }

    /// A path relative to /workspace → its guest path.
    public static func guestPath(_ rel: String) -> String { rel.isEmpty ? root : root + "/" + rel }

    static func isControl(_ u: Unicode.Scalar) -> Bool { u.value < 0x20 || u.value == 0x7F || (0x80...0x9F).contains(u.value) }

    /// Bidi overrides and isolates: a name must not reorder what is drawn around it.
    static func isBidiControl(_ u: Unicode.Scalar) -> Bool { (0x202A...0x202E).contains(u.value) || (0x2066...0x2069).contains(u.value) }

    /// Untrusted text made inert: control and bidi-control characters replaced by U+FFFD, at most `limit` characters
    /// (a cut one ends in …). `altered`: anything was replaced or cut.
    public static func inert(_ s: String, limit: Int = maximumNameCharacters) -> (text: String, altered: Bool) {
        var altered = false
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            if isControl(u) || isBidiControl(u) { out.append("\u{FFFD}"); altered = true } else { out.append(u) }
        }
        var t = String(out)
        if t.count > limit { t = String(t.prefix(limit - 1)) + "…"; altered = true }
        return (t, altered)
    }

    /// The order of a listing: folders first, then by name (case-insensitive, then exact).
    static func sorted(_ e: [FileEntry]) -> [FileEntry] {
        e.sorted { a, b in
            let fa = a.kind == "folder", fb = b.kind == "folder"
            if fa != fb { return fa }
            let c = a.name.caseInsensitiveCompare(b.name)
            return c == .orderedSame ? a.name < b.name : c == .orderedAscending
        }
    }

    /// `/workspace/…` for messages: inert and short.
    static func shown(_ given: String?) -> String {
        let s = inert(given ?? "", limit: 120).text
        return s.isEmpty ? root : s
    }
}

// MARK: - the Mac (a shared workspace)

public enum MacFolderListing {
    /// The rules the guest's view applies to `workspace` (nil: none — no rule file, or the view is off for it).
    public static func rules(workspace: String, mode: WorkspaceRuleMode, viewOn: Bool) -> WorkspaceRules? {
        let folder = URL(fileURLWithPath: workspace)
        guard viewOn, WorkspaceRules.present(in: folder) else { return nil }
        return WorkspaceRules.load(folder: folder, mode: mode)
    }

    /// A folder of the share, resolved and confined: the share's realpath, the folder's, and the folder's path relative
    /// to the share's realpath (what the rules are decided on — the guest's kernel reaches the same place).
    public struct Resolved: Equatable, Sendable {
        public var root: String
        public var real: String
        public var inside: String
        /// The folder's own verdict (nil: visible; `read-only`).
        public var state: String?
    }

    /// `rel` (relative to /workspace, lexically clean) → the folder on this Mac, or why not.
    public static func resolve(workspace: String, rel: String, rules: WorkspaceRules?) throws -> Resolved {
        let shown = FileListPaths.guestPath(rel)
        guard let root = realPath(workspace) else {
            throw HostError(.failed, "the shared folder is not there on this Mac (\(DisplayPath.tilde(workspace)))")
        }
        let asked = rel.isEmpty ? workspace : (workspace.hasSuffix("/") ? workspace : workspace + "/") + rel
        guard let real = realPath(asked) else { throw HostError(.notFound, "no such folder in the workspace: \(shown)") }
        guard real == root || real.hasPrefix(root == "/" ? "/" : root + "/") else {
            throw HostError(.invalid, "\(shown) leads outside the shared folder (a link or ..)")
        }
        let inside = real == root ? "" : String(real.dropFirst(root == "/" ? 1 : root.count + 1))
        var st = stat()
        guard lstat(real, &st) == 0 else { throw HostError(.notFound, "no such folder in the workspace: \(shown)") }
        guard st.st_mode & S_IFMT == S_IFDIR else { throw HostError(.invalid, "\(shown) is not a folder") }
        var state: String?
        if let rules, !inside.isEmpty {
            var e = WorkspaceRules.Evaluator(rules)
            switch e.decide(inside, isDirectory: { _ in true }).verdict {
            case .hidden: throw HostError(.notFound, "no such folder in the workspace: \(shown)")
            case .locked: throw HostError(.failed, "\(shown) is locked by the workspace rules (.dozignore) — nothing in it can be read")
            case .readOnly: state = "read-only"
            case .visible: break
            }
        }
        return Resolved(root: root, real: real, inside: inside, state: state)
    }

    /// The folder `rel` of `workspace`: its entries (rules applied), whether more were left out, and its own state.
    public static func list(workspace: String, rel: String, rules: WorkspaceRules?) throws
        -> (entries: [FileEntry], truncated: Bool, state: String?) {
        let r = try resolve(workspace: workspace, rel: rel, rules: rules)
        guard let names = scan(r.real) else {
            throw HostError(.failed, "\(FileListPaths.guestPath(rel)) could not be read on this Mac")
        }
        var evaluator = rules.map { WorkspaceRules.Evaluator($0) }
        var out: [FileEntry] = []
        for name in names.list {
            let p = r.real + "/" + name
            var st = stat()
            guard lstat(p, &st) == 0 else { continue }          // gone since the scan
            let type = st.st_mode & S_IFMT
            let kind = type == S_IFREG ? "file" : type == S_IFDIR ? "folder" : type == S_IFLNK ? "link" : "other"
            var state: String?
            if evaluator != nil {
                let child = r.inside.isEmpty ? name : r.inside + "/" + name
                let d = evaluator!.decide(child) { $0 == child ? type == S_IFDIR : true }
                switch d.verdict {
                case .hidden: continue
                case .locked: state = "locked"
                case .readOnly: state = "read-only"
                case .visible: break
                }
            }
            let shown = FileListPaths.inert(name)
            var e = FileEntry(name: shown.text, kind: kind, state: state, altered: shown.altered ? true : nil)
            if state != "locked" {
                if type == S_IFREG { e.size = Int64(st.st_size) }
                e.modified = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec) + TimeInterval(st.st_mtimespec.tv_nsec) / 1e9)
                if type == S_IFLNK, let t = readLink(p) { e.target = FileListPaths.inert(t, limit: FileListPaths.maximumTargetCharacters).text }
            }
            out.append(e)
        }
        let sorted = FileListPaths.sorted(out)
        return (Array(sorted.prefix(FileListPaths.maximumEntries)), sorted.count > FileListPaths.maximumEntries || names.cut, r.state)
    }

    /// The names in a folder (never `.` or `..`), at most `maximumScanned` of them; nil: it cannot be read.
    static func scan(_ path: String) -> (list: [String], cut: Bool)? {
        guard let dir = opendir(path) else { return nil }
        defer { closedir(dir) }
        var names: [String] = []
        var cut = false
        while let ent = readdir(dir) {
            let name = withUnsafeBytes(of: ent.pointee.d_name) { raw -> String in
                let bytes = raw.bindMemory(to: UInt8.self)
                let n = Int(ent.pointee.d_namlen)
                return String(decoding: UnsafeBufferPointer(rebasing: bytes.prefix(n)), as: UTF8.self)
            }
            if name == "." || name == ".." { continue }
            if names.count >= FileListPaths.maximumScanned { cut = true; break }
            names.append(name)
        }
        return (names, cut)
    }

    static func realPath(_ p: String) -> String? {
        guard let r = realpath(p, nil) else { return nil }
        defer { free(r) }
        return String(cString: r)
    }

    static func readLink(_ p: String) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        let n = readlink(p, &buf, buf.count - 1)
        guard n >= 0 else { return nil }
        return String(decoding: buf[0..<n].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

// MARK: - the guest (an isolated sandbox)

/// The utility exec that lists a folder inside an isolated sandbox — run as the image's user (`sh -c`, never a session).
/// `stat -c` exists in GNU coreutils and busybox alike; every name is passed as `./NAME`, so none is taken for an option.
public enum GuestFolderListing {
    static func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Lines: `doz-files ok TOTAL UNLISTED` | `doz-files missing` | `doz-files notdir` | `doz-files denied`; then one
    /// `doz-entry TYPE|SIZE|MTIME|./NAME` per entry (the first `limit`), and for each link `doz-link ./NAME` followed by
    /// `doz-target TARGET` (newlines in it made spaces). A name holding a newline is not listed, only counted.
    public static func script(_ guestPath: String, limit: Int = FileListPaths.maximumEntries) -> String {
        """
        LC_ALL=C; export LC_ALL
        d=\(q(guestPath))
        if [ ! -e "$d" ]; then echo 'doz-files missing'; exit 0; fi
        if [ ! -d "$d" ]; then echo 'doz-files notdir'; exit 0; fi
        cd "$d" 2>/dev/null || { echo 'doz-files denied'; exit 0; }
        [ -r . ] && [ -x . ] || { echo 'doz-files denied'; exit 0; }
        nl='
        '
        n=0; u=0
        set --
        for f in * .[!.]* ..?*; do
          [ -e "$f" ] || [ -L "$f" ] || continue
          case "$f" in *"$nl"*) u=$((u+1)); continue ;; esac
          n=$((n+1))
          [ "$n" -le \(limit) ] && set -- "$@" "./$f"
        done
        echo "doz-files ok $n $u"
        [ "$#" -gt 0 ] || exit 0
        stat -c 'doz-entry %F|%s|%Y|%n' "$@" 2>/dev/null
        for f in "$@"; do
          if [ -L "$f" ]; then printf 'doz-link %s\\n' "$f"; printf 'doz-target %s\\n' "$(readlink "$f" 2>/dev/null | tr '\\n' ' ')"; fi
        done
        """
    }

    public enum Outcome: Equatable {
        case ok(entries: [FileEntry], total: Int, unlisted: Int)
        case missing, notDirectory, denied
        case unreadable(String)
    }

    public static func parse(_ output: String) -> Outcome {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard let head = lines.first(where: { $0.hasPrefix("doz-files ") }) else { return .unreadable(output) }
        switch head {
        case "doz-files missing": return .missing
        case "doz-files notdir": return .notDirectory
        case "doz-files denied": return .denied
        default: break
        }
        let h = head.split(separator: " ")
        guard h.count == 4, h[1] == "ok", let total = Int(h[2]), let unlisted = Int(h[3]) else { return .unreadable(output) }
        var targets: [String: String] = [:]
        var pendingLink: String?
        for l in lines {
            if l.hasPrefix("doz-link ./") { pendingLink = String(l.dropFirst(11)); continue }
            if l.hasPrefix("doz-target "), let n = pendingLink { targets[n] = String(l.dropFirst(11)); pendingLink = nil }
        }
        var out: [FileEntry] = []
        for l in lines where l.hasPrefix("doz-entry ") {
            let f = l.dropFirst(10).split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
            guard f.count == 4, f[3].hasPrefix("./") else { continue }
            let raw = String(f[3].dropFirst(2))
            let type = f[0]
            let kind = type == "directory" ? "folder" : type == "symbolic link" ? "link" : type.hasPrefix("regular") ? "file" : "other"
            let shown = FileListPaths.inert(raw)
            var e = FileEntry(name: shown.text, kind: kind, altered: shown.altered ? true : nil)
            if kind == "file" { e.size = Int64(f[1]) }
            if let t = TimeInterval(f[2]) { e.modified = Date(timeIntervalSince1970: t) }
            if kind == "link", let t = targets[raw] {
                e.target = FileListPaths.inert(t.hasSuffix(" ") ? String(t.dropLast()) : t, limit: FileListPaths.maximumTargetCharacters).text
            }
            out.append(e)
        }
        return .ok(entries: FileListPaths.sorted(out), total: total, unlisted: unlisted)
    }
}
