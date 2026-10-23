import Darwin
import Foundation
import DozableKit

// 644 (624.B1 part 2; owner, 2026-10-19: "expanded / collapsed state is persisted; CRUD operations"): the file explorer
// panel's writes, beside 643's reads (WorkspaceFileList.swift). Four changes — a new folder, a new (empty) file, a move
// (a rename is a move within its folder), a delete — and the panel's open folders, kept by the host per sandbox.
//
// Where the bytes live decides, as for a listing:
//   · a SHARED workspace is changed ON THE MAC, in the process that asks (the host when one runs, else in-process — a
//     file change needs no VM, so it never starts a host and never wakes the sandbox). The path discipline is the
//     listing's: the PARENT folder resolved by `MacFolderListing.resolve` (lexical under /workspace, mapped from the
//     record, realpath inside the share's realpath), the item ONE name in it, and every change made with descriptor-
//     relative calls on that parent opened O_NOFOLLOW (`mkdirat`, `openat(O_EXCL|O_NOFOLLOW)`, `renameatx_np(RENAME_EXCL)`,
//     `unlinkat`) — a link put in the way is never followed. Nothing is ever replaced. The workspace rules apply as the
//     guest's view applies them: a hidden item is not there, a locked or read-only one is refused, a new name the rules
//     would hide, lock or make read-only is refused, a folder holding something the rules protect is not moved or deleted.
//   · an ISOLATED sandbox is changed by one utility exec as the image's user, only while it runs.

/// 644: which folders of /workspace the panel shows open — kept beside `doz.json` like the terminal layout.
public struct FileTreeState: Codable, Equatable, Sendable {
    /// /workspace itself is always open; with it, the watch's 64.
    public static let maximumExpanded = FileWatchCoalescer.maximumFolders - 1

    /// Folders relative to /workspace ("src", "src/lib"), each once.
    public var expanded: [String]
    public var updatedAt: Date?

    public init(expanded: [String], updatedAt: Date? = nil) {
        self.expanded = expanded
        self.updatedAt = updatedAt
    }

    public func validate() throws {
        guard expanded.count <= Self.maximumExpanded else {
            throw HostError(.invalid, "at most \(Self.maximumExpanded) folders are open at once")
        }
        var seen = Set<String>()
        for p in expanded {
            guard let f = FileListPaths.folder(p), !f.rel.isEmpty, f.rel == p else {
                throw HostError(.invalid, "an open folder is a path relative to /workspace (src, src/lib)")
            }
            guard seen.insert(p).inserted else { throw HostError(.invalid, "an open folder is listed once") }
        }
    }

    /// The stored state (nil: none, or one that no longer validates).
    public static func read(_ store: DozableStore, _ name: String) -> FileTreeState? {
        guard let d = try? Data(contentsOf: store.fileTreeFile(name)),
              let s = try? HostWire.decoder.decode(FileTreeState.self, from: d), (try? s.validate()) != nil else { return nil }
        return s
    }

    /// Write it (nil: remove it) — atomically, 0600, and only into a sandbox `doz create` made (never re-creates the
    /// directory of a removed sandbox).
    public static func write(_ state: FileTreeState?, _ store: DozableStore, _ name: String) throws {
        let url = store.fileTreeFile(name)
        guard FileManager.default.fileExists(atPath: store.configFile(name).path) else {
            throw HostError(.notFound, "no sandbox \(name) (doz ls)")
        }
        guard var s = state else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try s.validate()
        s.updatedAt = Date()
        let data = try HostWire.encoder.encode(s)
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".file-tree.\(getpid()).\(UInt32.random(in: 0...UInt32.max)).tmp")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw HostError(.failed, "cannot write the open folders of \(name)") }
        let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }
        close(fd)
        guard written == data.count, rename(tmp.path, url.path) == 0 else {
            unlink(tmp.path)
            throw HostError(.failed, "cannot write the open folders of \(name)")
        }
    }
}

/// What a change did.
public struct FileChangeResult: Codable, Equatable, Sendable {
    public var sandbox: String
    /// `mkdir`, `new`, `move`, `rm`, `open`, `reveal`.
    public var action: String
    /// The item, in the guest (`/workspace/…`).
    public var path: String
    /// A move's destination.
    public var to: String?
    /// `file`, `folder`, `link` or `other`.
    public var kind: String?
    /// A delete: how many entries went (the item and everything in it).
    public var items: Int?
    /// The folders whose listing changed (guest paths) — what a panel lists again.
    public var folders: [String]
    /// `mac` or `guest`.
    public var source: String
    /// An open: what was done, in words.
    public var message: String?

    public init(sandbox: String, action: String, path: String, to: String? = nil, kind: String? = nil, items: Int? = nil,
                folders: [String], source: String, message: String? = nil) {
        self.sandbox = sandbox; self.action = action; self.path = path; self.to = to; self.kind = kind; self.items = items
        self.folders = folders; self.source = source; self.message = message
    }
}

/// An item of /workspace — never /workspace itself.
public struct FileItemPath: Equatable, Sendable {
    /// `/workspace/src/a.c`, `src/a.c`, `src`, `a.c`.
    public var guest: String
    public var rel: String
    public var parent: String
    public var name: String

    /// The most bytes one name may have (APFS, ext4).
    public static let maximumNameBytes = 255

    /// As given (relative to /workspace, or `/workspace/…`) → the item; nil: /workspace itself, outside it, a control
    /// character, a name over 255 bytes.
    public static func parse(_ given: String?) -> FileItemPath? {
        guard let f = FileListPaths.folder(given), !f.rel.isEmpty else { return nil }
        let parts = f.rel.split(separator: "/").map(String.init)
        guard let name = parts.last, name != ".", name != "..", name.utf8.count <= maximumNameBytes else { return nil }
        return FileItemPath(guest: f.guest, rel: f.rel, parent: parts.dropLast().joined(separator: "/"), name: name)
    }

    public var parentGuest: String { FileListPaths.guestPath(parent) }
}

// MARK: - the Mac (a shared workspace)

public enum MacFileChange {
    /// How many entries a folder moved or deleted may hold (each is checked against the rules, or deleted, one by one).
    public static let maximumWalk = 100_000

    /// The parent folder, resolved and confined (the listing's rule), opened without following a link.
    struct Parent {
        var fd: Int32
        var resolved: MacFolderListing.Resolved
        func inside(_ name: String) -> String { resolved.inside.isEmpty ? name : resolved.inside + "/" + name }
    }

    static func openParent(workspace: String, rel: String, rules: WorkspaceRules?, writing: Bool) throws -> Parent {
        let r = try MacFolderListing.resolve(workspace: workspace, rel: rel, rules: rules)
        let shown = FileListPaths.guestPath(rel)
        if writing, r.state == "read-only" {
            throw HostError(.failed, "\(shown) is read-only by the workspace rules (.dozreadonly) — nothing in it can be changed")
        }
        let fd = Darwin.open(r.real, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw HostError(.failed, "\(shown) could not be opened on this Mac (\(String(cString: strerror(Darwin.errno))))") }
        return Parent(fd: fd, resolved: r)
    }

    static func verdict(_ rules: WorkspaceRules?, _ inside: String, isDirectory: Bool) -> WorkspaceVerdict {
        guard let rules else { return .visible }
        var e = WorkspaceRules.Evaluator(rules)
        return e.decide(inside) { $0 == inside ? isDirectory : true }.verdict
    }

    /// An item that is there must be one the guest may change.
    static func checkExisting(_ rules: WorkspaceRules?, _ inside: String, isDirectory: Bool, shown: String) throws {
        switch verdict(rules, inside, isDirectory: isDirectory) {
        case .visible: return
        case .hidden: throw HostError(.notFound, "no such file or folder in the workspace: \(shown)")
        case .locked: throw HostError(.failed, "\(shown) is locked by the workspace rules (.dozignore) — it cannot be changed")
        case .readOnly: throw HostError(.failed, "\(shown) is read-only by the workspace rules — it cannot be changed")
        }
    }

    /// A NEW name must come out as one the guest sees and may change.
    static func checkNew(_ rules: WorkspaceRules?, _ inside: String, isDirectory: Bool, shown: String) throws {
        switch verdict(rules, inside, isDirectory: isDirectory) {
        case .visible: return
        case .hidden: throw HostError(.failed, "the workspace rules hide that name (\(shown)) — choose another")
        case .locked: throw HostError(.failed, "the workspace rules would lock \(shown) — choose another name")
        case .readOnly: throw HostError(.failed, "the workspace rules would make \(shown) read-only — choose another name")
        }
    }

    static func lstatAt(_ fd: Int32, _ name: String) -> stat? {
        var st = stat()
        return fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 ? st : nil
    }

    static func kind(_ st: stat) -> String {
        switch st.st_mode & S_IFMT {
        case S_IFREG: "file"
        case S_IFDIR: "folder"
        case S_IFLNK: "link"
        default: "other"
        }
    }

    static func failure(_ what: String, _ shown: String) -> HostError {
        let e = Darwin.errno
        switch e {
        case EEXIST: return HostError(.exists, "\(shown) is there already — nothing was replaced")
        case ENOENT: return HostError(.notFound, "no such file or folder in the workspace: \(shown)")
        case ENOTEMPTY: return HostError(.failed, "\(shown) is not empty — delete it with everything in it (doz files rm -r)")
        case EACCES, EPERM: return HostError(.failed, "\(what) \(shown): permission denied on this Mac")
        case EINVAL: return HostError(.invalid, "\(what) \(shown): a folder cannot go into itself")
        default: return HostError(.failed, "\(what) \(shown): \(String(cString: strerror(e)))")
        }
    }

    /// The names in an open folder (never `.` or `..`). Takes ownership of `fd`.
    static func names(_ fd: Int32) -> [String]? {
        guard let dir = fdopendir(fd) else { close(fd); return nil }
        defer { closedir(dir) }
        var out: [String] = []
        while let ent = readdir(dir) {
            let name = withUnsafeBytes(of: ent.pointee.d_name) { raw -> String in
                let bytes = raw.bindMemory(to: UInt8.self)
                return String(decoding: UnsafeBufferPointer(rebasing: bytes.prefix(Int(ent.pointee.d_namlen))), as: UTF8.self)
            }
            if name != "." && name != ".." { out.append(name) }
        }
        return out
    }

    /// Every entry under the folder `name` of `parent` (relative to it, folders flagged), never through a link.
    static func walk(_ parent: Int32, _ name: String, shown: String) throws -> [(rel: String, isDirectory: Bool)] {
        var out: [(String, Bool)] = []
        func visit(_ dirfd: Int32, _ entry: String, _ base: String) throws {
            let fd = openat(dirfd, entry, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw HostError(.failed, "\(shown): a folder in it could not be read on this Mac") }
            let keep = dup(fd)
            defer { close(keep) }
            guard let list = names(fd) else { throw HostError(.failed, "\(shown): a folder in it could not be read on this Mac") }
            for n in list {
                guard out.count < maximumWalk else { throw HostError(.failed, "\(shown) holds more than \(maximumWalk) entries — not changed here") }
                let rel = base.isEmpty ? n : base + "/" + n
                let isDir = lstatAt(keep, n).map { $0.st_mode & S_IFMT == S_IFDIR } ?? false
                out.append((rel, isDir))
                if isDir { try visit(keep, n, rel) }
            }
        }
        try visit(parent, name, "")
        return out
    }

    /// Nothing in the folder may be something the rules protect — at `inside` (and at `movedTo`, for a move).
    static func checkSubtree(_ rules: WorkspaceRules?, _ entries: [(rel: String, isDirectory: Bool)], inside: String,
                             movedTo: String?, shown: String) throws {
        guard let rules else { return }
        var e = WorkspaceRules.Evaluator(rules)
        for (rel, isDir) in entries {
            for base in [inside] + (movedTo.map { [$0] } ?? []) {
                let p = base + "/" + rel
                if e.decide(p, isDirectory: { $0 == p ? isDir : true }).verdict != .visible {
                    let first = FileListPaths.inert(rel, limit: 80).text
                    throw HostError(.failed, base == inside
                        ? "\(shown) holds \(first), which the workspace rules protect — not changed"
                        : "moved there, \(first) in it would fall under the workspace rules — not moved")
                }
            }
        }
    }

    // MARK: the changes

    public static func mkdir(workspace: String, item: FileItemPath, rules: WorkspaceRules?) throws -> String {
        let p = try openParent(workspace: workspace, rel: item.parent, rules: rules, writing: true)
        defer { close(p.fd) }
        try checkNew(rules, p.inside(item.name), isDirectory: true, shown: item.guest)
        guard mkdirat(p.fd, item.name, 0o755) == 0 else { throw failure("cannot make", item.guest) }
        return "folder"
    }

    public static func create(workspace: String, item: FileItemPath, rules: WorkspaceRules?) throws -> String {
        let p = try openParent(workspace: workspace, rel: item.parent, rules: rules, writing: true)
        defer { close(p.fd) }
        try checkNew(rules, p.inside(item.name), isDirectory: false, shown: item.guest)
        let fd = openat(p.fd, item.name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw failure("cannot make", item.guest) }
        close(fd)
        return "file"
    }

    public static func move(workspace: String, item: FileItemPath, to: FileItemPath, rules: WorkspaceRules?) throws -> String {
        let from = try openParent(workspace: workspace, rel: item.parent, rules: rules, writing: true)
        defer { close(from.fd) }
        guard let st = lstatAt(from.fd, item.name) else { throw HostError(.notFound, "no such file or folder in the workspace: \(item.guest)") }
        let k = kind(st), isDir = k == "folder"
        let src = from.inside(item.name)
        try checkExisting(rules, src, isDirectory: isDir, shown: item.guest)
        let into = try openParent(workspace: workspace, rel: to.parent, rules: rules, writing: true)
        defer { close(into.fd) }
        let dst = into.inside(to.name)
        if dst == src { throw HostError(.invalid, "\(item.guest) is already there") }
        if isDir, dst.hasPrefix(src + "/") { throw HostError(.invalid, "\(item.guest) cannot go into itself") }
        try checkNew(rules, dst, isDirectory: isDir, shown: to.guest)
        if isDir, rules != nil {
            try checkSubtree(rules, try walk(from.fd, item.name, shown: item.guest), inside: src, movedTo: dst, shown: item.guest)
        }
        guard renameatx_np(from.fd, item.name, into.fd, to.name, UInt32(RENAME_EXCL)) == 0 else { throw failure("cannot move", to.guest) }
        return k
    }

    public static func remove(workspace: String, item: FileItemPath, recursive: Bool, rules: WorkspaceRules?) throws -> (kind: String, items: Int) {
        let p = try openParent(workspace: workspace, rel: item.parent, rules: rules, writing: true)
        defer { close(p.fd) }
        guard let st = lstatAt(p.fd, item.name) else { throw HostError(.notFound, "no such file or folder in the workspace: \(item.guest)") }
        let k = kind(st)
        let inside = p.inside(item.name)
        try checkExisting(rules, inside, isDirectory: k == "folder", shown: item.guest)
        guard k == "folder" else {
            guard unlinkat(p.fd, item.name, 0) == 0 else { throw failure("cannot delete", item.guest) }
            return (k, 1)
        }
        let entries = try walk(p.fd, item.name, shown: item.guest)
        try checkSubtree(rules, entries, inside: inside, movedTo: nil, shown: item.guest)
        if !entries.isEmpty && !recursive {
            throw HostError(.failed, "\(item.guest) is not empty (\(entries.count) item\(entries.count == 1 ? "" : "s")) — delete it with everything in it (doz files rm -r)")
        }
        try removeTree(p.fd, item.name, shown: item.guest)
        return (k, entries.count + 1)
    }

    /// Deletes the folder `name` of `dirfd` and everything in it — every step relative to an open folder, never through a
    /// link (a link inside is removed, never followed).
    static func removeTree(_ dirfd: Int32, _ name: String, shown: String) throws {
        let fd = openat(dirfd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw failure("cannot delete", shown) }
        let keep = dup(fd)
        defer { close(keep) }
        guard let list = names(fd) else { throw HostError(.failed, "cannot delete \(shown): a folder in it could not be read") }
        for n in list {
            if let st = lstatAt(keep, n), st.st_mode & S_IFMT == S_IFDIR {
                try removeTree(keep, n, shown: shown)
            } else if unlinkat(keep, n, 0) != 0, Darwin.errno != ENOENT {
                throw failure("cannot delete", shown)
            }
        }
        guard unlinkat(dirfd, name, AT_REMOVEDIR) == 0 else { throw failure("cannot delete", shown) }
    }

    /// 644: open a file of the shared workspace on the Mac (its default app), a folder in the Finder, or `reveal` one
    /// selected in its folder — the open-files bridge's decision (`WorkspaceFiles.decide`: the setting, the document types,
    /// the content) plus the rules (a hidden or locked item is refused). Returns what was done, in words.
    public static func open(workspace: String, guestPath: String, reveal: Bool, enabled: Bool, rules: WorkspaceRules?,
                            environment: [String: String] = ProcessInfo.processInfo.environment) throws -> String {
        // The rules FIRST, on the resolved path: a hidden item is "no such file" before anything else is said about it
        // (its type, its content) — the answer must not tell that it is there.
        if let rules, enabled, case .success(let r) = WorkspaceFiles.resolve(guestPath: guestPath, workspace: workspace, reveal: true),
           let root = MacFolderListing.realPath(workspace), r.macPath != root {
            let inside = String(r.macPath.dropFirst(root == "/" ? 1 : root.count + 1))
            var st = stat()
            let isDir = lstat(r.macPath, &st) == 0 && st.st_mode & S_IFMT == S_IFDIR
            switch verdict(rules, inside, isDirectory: isDir) {
            case .hidden: throw HostError(.notFound, "no such file or folder in the workspace: \(FileListPaths.shown(guestPath))")
            case .locked: throw HostError(.failed, "\(FileListPaths.shown(guestPath)) is locked by the workspace rules — not opened")
            case .readOnly, .visible: break
            }
        }
        switch WorkspaceFiles.decide(guestPath: guestPath, app: nil, reveal: reveal, workspace: workspace, enabled: enabled, allowedApps: []) {
        case .refused(_, let why):
            throw HostError(.failed, "\(FileListPaths.shown(guestPath)) — \(why)")
        case .open(let macPath, let shown, _, let how):
            guard WorkspaceFiles.open(macPath, app: nil, how: how, environment: environment) else {
                throw HostError(.failed, "this Mac could not open \(shown)")
            }
            switch how {
            case .finder: return "opened \(shown) in the Finder"
            case .reveal: return "showed \(shown) in the Finder"
            case .app: return "opened \(shown) in \(MacDefaultApp.name(forFile: macPath) ?? "its default app")"
            }
        }
    }
}

// MARK: - the guest (an isolated sandbox)

/// The utility exec that changes an isolated sandbox's /workspace — run as the image's user (`sh -c`, never a session).
/// Every folder it acts in is `cd`'d into and must resolve (`pwd -P`) to /workspace or below; names are passed as `./NAME`.
public enum GuestFileChange {
    static func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static let prelude = """
    LC_ALL=C; export LC_ALL
    inws() { case "$(pwd -P)" in /workspace|/workspace/*) return 0 ;; esac; return 1; }
    kindof() { if [ -L "$1" ]; then echo link; elif [ -d "$1" ]; then echo folder; elif [ -f "$1" ]; then echo file; elif [ -e "$1" ]; then echo other; else echo none; fi; }
    """

    static func enter(_ dir: String) -> String {
        """
        d=\(q(dir))
        if [ ! -e "$d" ]; then echo 'doz-change missing-parent'; exit 0; fi
        cd "$d" 2>/dev/null || { echo 'doz-change denied'; exit 0; }
        inws || { echo 'doz-change outside'; exit 0; }
        """
    }

    /// The script for `action` (`mkdir`, `new`, `move`, `rm`). Lines: `doz-change ok KIND [COUNT]` or `doz-change WHY`
    /// (missing, missing-parent, exists, denied, outside, notempty, into-itself).
    public static func script(_ action: String, item: FileItemPath, to: FileItemPath? = nil, recursive: Bool = false) -> String {
        var s = prelude + "\n" + enter(item.parentGuest) + "\nn=\(q(item.name))\nk=$(kindof \"./$n\")\n"
        switch action {
        case "mkdir":
            s += """
            [ "$k" = none ] || { echo 'doz-change exists'; exit 0; }
            mkdir "./$n" 2>/dev/null && echo 'doz-change ok folder' || echo 'doz-change denied'
            """
        case "new":
            s += """
            [ "$k" = none ] || { echo 'doz-change exists'; exit 0; }
            ( set -C; : > "./$n" ) 2>/dev/null && echo 'doz-change ok file' || echo 'doz-change denied'
            """
        case "move":
            let t = to ?? item
            s += """
            [ "$k" = none ] && { echo 'doz-change missing'; exit 0; }
            src="$(pwd -P)/$n"
            t=\(q(t.parentGuest))
            [ -d "$t" ] || { echo 'doz-change missing-parent'; exit 0; }
            tp=$(cd "$t" 2>/dev/null && inws && pwd -P) || { echo 'doz-change outside'; exit 0; }
            m=\(q(t.name))
            case "$tp/" in "$src"/*) echo 'doz-change into-itself'; exit 0 ;; esac
            if [ -e "$tp/$m" ] || [ -L "$tp/$m" ]; then echo 'doz-change exists'; exit 0; fi
            mv "./$n" "$tp/$m" 2>/dev/null && echo "doz-change ok $k" || echo 'doz-change denied'
            """
        default:   // rm
            s += """
            [ "$k" = none ] && { echo 'doz-change missing'; exit 0; }
            if [ "$k" = folder ]; then
              c=$(find "./$n" 2>/dev/null | wc -l | tr -d ' ')
              if [ \(recursive ? "1" : "0") = 1 ]; then
                rm -rf "./$n" 2>/dev/null; [ -e "./$n" ] && echo 'doz-change denied' || echo "doz-change ok folder $c"
              else
                rmdir "./$n" 2>/dev/null && echo 'doz-change ok folder 1' || { [ -n "$(ls -A "./$n" 2>/dev/null)" ] && echo 'doz-change notempty' || echo 'doz-change denied'; }
              fi
            else
              rm -f "./$n" 2>/dev/null && echo "doz-change ok $k 1" || echo 'doz-change denied'
            fi
            """
        }
        return s
    }

    public enum Outcome: Equatable {
        case ok(kind: String, count: Int?)
        case refused(String)
        case unreadable
    }

    public static func parse(_ output: String) -> Outcome {
        guard let line = output.split(separator: "\n").map(String.init).last(where: { $0.hasPrefix("doz-change ") }) else { return .unreadable }
        let w = line.split(separator: " ").map(String.init)
        guard w.count >= 2 else { return .unreadable }
        if w[1] == "ok" {
            guard w.count >= 3 else { return .unreadable }
            return .ok(kind: w[2], count: w.count >= 4 ? Int(w[3]) : nil)
        }
        return .refused(w[1])
    }

    /// A refusal's words.
    public static func explain(_ why: String, item: FileItemPath, to: FileItemPath?, sandbox: String, user: String?) -> HostError {
        switch why {
        case "missing": return HostError(.notFound, "no such file or folder in \(sandbox): \(item.guest)")
        case "missing-parent": return HostError(.notFound, "no such folder in \(sandbox): \((to ?? item).parentGuest)")
        case "exists": return HostError(.exists, "\((to ?? item).guest) is there already in \(sandbox) — nothing was replaced")
        case "outside": return HostError(.invalid, "that folder leads outside /workspace in \(sandbox) (a link)")
        case "notempty": return HostError(.failed, "\(item.guest) is not empty — delete it with everything in it (doz files rm -r)")
        case "into-itself": return HostError(.invalid, "\(item.guest) cannot go into itself")
        default: return HostError(.failed, "\(user ?? "root") may not change that in \(sandbox)")
        }
    }
}
