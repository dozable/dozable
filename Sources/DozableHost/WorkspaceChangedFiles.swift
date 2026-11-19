import Darwin
import DozableKit
import Foundation

// What changed in a workspace's folder since its work started — a bounded walk, NEVER a program. Dozable never runs a
// program (git included) in a folder an agent writes in order to look at it: `git status` there would run that folder's
// `.git/config` — `core.fsmonitor`, a clean filter — as you. So: a walk by descriptor (`openat` with `O_NOFOLLOW`, `fstatat`
// with `AT_SYMLINK_NOFOLLOW`), no link listed or followed, `.git` skipped, never off the folder's volume, no `Process`; capped
// at `maximumEntries` and `maximumSeconds` per folder, the newest `maximumListed` listed and `truncated` said. A file is
// changed when its mtime is at or after the start: `A` when it was also born after it, else `M`. Deletions are not known.
// A change is attributed to a folder, never to an agent. `WorkspaceChangedFilesTests` (incl. the fsmonitor trap).

public struct WorkspaceFileChange: Codable, Equatable, Sendable {
    /// `A` (born since the start) or `M` (changed since).
    public var kind: String
    /// Relative to its folder, `/`-separated; each name made inert (`FileListPaths.inert`).
    public var path: String
    public init(kind: String, path: String) { self.kind = kind; self.path = path }
}

public enum WorkspaceChangedFiles {
    public static let maximumEntries = 20_000
    public static let maximumSeconds = 3.0
    public static let maximumListed = 200
    public static let maximumDepth = 64

    public struct Result: Equatable, Sendable {
        /// The newest first, at most `listed`.
        public var changes: [WorkspaceFileChange]
        /// How many files changed (of those walked).
        public var count: Int
        /// The walk was cut short (entries, time or depth) or more changed than are listed.
        public var truncated: Bool
        /// Entries walked.
        public var scanned: Int
        /// The folder could be opened (no link in its path, a folder).
        public var exists: Bool
    }

    /// Walk `root` (an absolute, resolved path) for files changed at or after `since`.
    public static func walk(_ root: String, since: Date, maximumEntries: Int = maximumEntries, maximumSeconds: Double = maximumSeconds,
                            listed: Int = maximumListed, clock: () -> Date = Date.init) -> Result {
        guard let fd = try? MacFenceHostFS.openDirectory(root) else {
            return Result(changes: [], count: 0, truncated: false, scanned: 0, exists: false)
        }
        var top = stat()
        guard fstat(fd, &top) == 0 else { close(fd); return Result(changes: [], count: 0, truncated: false, scanned: 0, exists: false) }
        let started = clock()
        let cut = since.timeIntervalSince1970
        var found: [(Double, WorkspaceFileChange)] = []
        var scanned = 0, cutShort = false

        func seconds(_ t: timespec) -> Double { Double(t.tv_sec) + Double(t.tv_nsec) / 1e9 }

        func go(_ dfd: Int32, _ rel: String, _ depth: Int) {
            guard let names = try? MacFenceHostFS.entries(dfd, path: rel) else { return }
            for n in names.sorted() {
                if cutShort { return }
                scanned += 1
                if scanned > maximumEntries || clock().timeIntervalSince(started) > maximumSeconds { cutShort = true; return }
                if n == ".git" { continue }                        // never looked into, whatever it is (a folder, a worktree's file)
                var e = stat()
                guard fstatat(dfd, n, &e, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
                let p = rel.isEmpty ? FileListPaths.inert(n).text : rel + "/" + FileListPaths.inert(n).text
                switch e.st_mode & S_IFMT {
                case S_IFREG:
                    let m = seconds(e.st_mtimespec)
                    guard m >= cut else { continue }
                    found.append((m, WorkspaceFileChange(kind: seconds(e.st_birthtimespec) >= cut ? "A" : "M", path: p)))
                case S_IFDIR:
                    guard e.st_dev == top.st_dev else { continue }   // never off the folder's volume
                    guard depth < maximumDepth else { cutShort = true; return }
                    let c = openat(dfd, n, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard c >= 0 else { continue }
                    go(c, p, depth + 1)
                    close(c)
                default:
                    continue                                        // a link (never followed or listed), a socket, a device
                }
            }
        }
        go(fd, "", 0)
        close(fd)
        found.sort { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1.path < $1.1.path }
        return Result(changes: Array(found.prefix(listed).map(\.1)), count: found.count, truncated: cutShort || found.count > listed,
                      scanned: scanned, exists: true)
    }

    /// How many rules a rule file holds (`.dozignore`, `.dozreadonly` at the folder's root): its lines that are not empty or a
    /// comment. nil: no such file (read with no link in its path, at most the rules' size).
    public static func ruleCount(_ folder: String, _ file: String) -> Int? {
        guard let d = try? MacFenceHostFS.readRegular(folder + "/" + file, maximum: WorkspaceRules.maximumFileBytes) else { return nil }
        return String(decoding: d, as: UTF8.self).split(whereSeparator: \.isNewline).filter {
            let t = $0.trimmingCharacters(in: .whitespaces)
            return !t.isEmpty && !t.hasPrefix("#")
        }.count
    }
}

/// `workspace-folders`' answer: each folder (the workspace's, then each agent's own working folder not among them) with what
/// changed in it since the start — by folder, never by agent — and the restore points of each VM agent.
public struct WorkspaceFolders: Codable, Equatable, Sendable {
    public struct Rules: Codable, Equatable, Sendable {
        /// The rules in `.dozignore` and `.dozreadonly` (nil: no such file).
        public var ignore: Int?
        public var readonly: Int?
        public init(ignore: Int?, readonly: Int?) { self.ignore = ignore; self.readonly = readonly }
    }
    public struct Folder: Codable, Equatable, Sendable {
        public var path: String
        public var mode: String
        public var main: Bool
        /// Whether it is one of the workspace's folders (else an agent's own working folder).
        public var workspace: Bool
        public var exists: Bool
        public var rules: Rules
        /// The agents that work in it (attribution by folder only).
        public var agents: [String]
        public var changes: [WorkspaceFileChange]
        public var count: Int
        public var truncated: Bool
        public var scanned: Int
        /// Its changes were not looked at for this browser (a session on this Mac's folder, `serve.mac_sessions` off).
        public var hidden: Bool?
        public init(path: String, mode: String, main: Bool, workspace: Bool, exists: Bool, rules: Rules, agents: [String],
                    changes: [WorkspaceFileChange], count: Int, truncated: Bool, scanned: Int, hidden: Bool?) {
            self.path = path; self.mode = mode; self.main = main; self.workspace = workspace; self.exists = exists; self.rules = rules
            self.agents = agents; self.changes = changes; self.count = count; self.truncated = truncated; self.scanned = scanned; self.hidden = hidden
        }
    }
    public struct Points: Codable, Equatable, Sendable {
        public var agent: String
        public var sandbox: String
        public var rows: [RestorePoint]
        public init(agent: String, sandbox: String, rows: [RestorePoint]) { self.agent = agent; self.sandbox = sandbox; self.rows = rows }
    }
    public var workspace: String
    /// The start the changes are counted from (`flags.startedAt`, else `firstAgentAt`, else `createdAt`).
    public var since: Date
    public var folders: [Folder]
    public var points: [Points]
    public init(workspace: String, since: Date, folders: [Folder], points: [Points]) {
        self.workspace = workspace; self.since = since; self.folders = folders; self.points = points
    }
}

/// `workspace-log` with `before` or `limit`: one page of the log, newest first. `first` is the oldest line's position in
/// `log.jsonl` (its byte offset — stable: the log is only appended to); `before: first` asks the page before it.
public struct WorkspaceLogPage: Codable, Equatable, Sendable {
    public var entries: [WorkspaceLogEntry]
    public var first: Int?
    public var more: Bool
    public init(entries: [WorkspaceLogEntry], first: Int?, more: Bool) { self.entries = entries; self.first = first; self.more = more }
    public static let defaultLimit = 200
    public static let maximumLimit = 500
}
