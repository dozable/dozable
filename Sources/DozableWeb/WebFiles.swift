import Foundation
import DozableHost

// 643 (624.B1 part 1): the file watcher's two typed routes — a folder of a sandbox's /workspace (the host's read-only
// `files-list`, in-process when no host runs) and a server-sent stream of which watched folders changed (watched in THIS
// process on the Mac — FileWatch.swift — never through the host, never in the guest). No generic file-read route: a
// listing carries names, kinds, sizes and times, never a file's content.

/// The routes' query: `path=` only — exactly `%XX` escapes (no `+` for a space), valid UTF-8, no control character, at
/// most 1024 bytes each. Anything else is not a route (404 before any session is looked at), like the metrics query.
public enum WebFilesQuery {
    /// The watch route's most folders (the coalescer's limit).
    public static let maximumPaths = FileWatchCoalescer.maximumFolders

    /// The `path` values in order; nil: not a route (an unknown key, a bad escape, a raw byte outside printable ASCII,
    /// a control character, too long, more than `maximum`).
    public static func parse(_ query: String?, maximum: Int) -> [String]? {
        guard let query, !query.isEmpty else { return [] }
        var out: [String] = []
        for pair in query.split(separator: "&", omittingEmptySubsequences: false) {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard kv.count == 2, kv[0] == "path", let v = decode(kv[1]) else { return nil }
            out.append(v)
            guard out.count <= maximum else { return nil }
        }
        return out
    }

    static func decode(_ s: Substring) -> String? {
        var bytes: [UInt8] = []
        let u = Array(s.utf8)
        var i = 0
        func hex(_ b: UInt8) -> UInt8? {
            switch b {
            case 0x30...0x39: b - 0x30
            case 0x41...0x46: b - 0x41 + 10
            case 0x61...0x66: b - 0x61 + 10
            default: nil
            }
        }
        while i < u.count {
            let b = u[i]
            if b == 0x25 {                                   // %XX
                guard i + 2 < u.count, let h = hex(u[i + 1]), let l = hex(u[i + 2]) else { return nil }
                bytes.append(h << 4 | l)
                i += 3
                continue
            }
            guard (0x21...0x7E).contains(b), b != 0x2B else { return nil }    // printable ASCII; `+` is ambiguous: escaped only
            bytes.append(b)
            i += 1
        }
        guard bytes.count <= FileListPaths.maximumPathBytes, let str = String(bytes: bytes, encoding: .utf8),
              !str.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F || (0x80...0x9F).contains($0.value) }) else { return nil }
        return str
    }
}

/// One entry, field by field (the host made the name and the target inert already).
public struct WebFileEntry: Codable, Equatable, Sendable {
    public var name: String
    public var kind: String
    public var size: Int64?
    public var modified: Date?
    public var target: String?
    public var state: String?
    public var altered: Bool?

    public init(_ e: FileEntry) {
        name = e.name
        kind = e.kind
        size = e.size
        modified = e.modified
        target = e.target
        state = e.state
        altered = e.altered
    }
}

/// `GET /api/v1/sandboxes/NAME/files?path=P`.
public struct WebFileList: Codable, Equatable, Sendable {
    public var sandbox: String
    public var path: String
    public var source: String
    public var watch: String
    public var rules: Bool
    public var state: String?
    public var entries: [WebFileEntry]
    public var truncated: Bool
    public var unlisted: Int?

    public init(_ l: FileList) {
        sandbox = l.sandbox
        path = l.path
        source = l.source
        watch = l.watch
        rules = l.rules
        state = l.state
        entries = l.entries.map(WebFileEntry.init)
        truncated = l.truncated
        unlisted = l.unlisted
    }
}

/// The watch stream's first event: what is watched (the folders as resolved, guest paths).
public struct WebFilesReady: Codable, Equatable, Sendable {
    public var sandbox: String
    public var folders: [String]
}

/// One `files` event: the watched folders whose listing changed (list them again), or `resync` (list every one again).
public struct WebFileBatch: Codable, Equatable, Sendable {
    public var sandbox: String
    public var folders: [String]
    public var resync: Bool
    public var time: Date

    public init(_ b: FileChangeBatch) {
        sandbox = b.sandbox
        folders = b.folders
        resync = b.resync
        time = b.time
    }
}

// MARK: 644 — the file explorer panel

/// `GET|POST /api/v1/sandboxes/NAME/files/tree` — the panel's open folders, kept by the host (`FileTreeState`).
public struct WebFileTree: Codable, Equatable, Sendable {
    public var expanded: [String]
    public var updatedAt: Date?

    public init(_ s: FileTreeState) {
        expanded = s.expanded
        updatedAt = s.updatedAt
    }

    /// The page's body, STRICTLY: `{expanded: [string]}` and nothing else; then the host's own rule (`validate`). Every
    /// refusal is a fixed message that never echoes a value.
    public static func decode(_ body: Data) throws -> FileTreeState {
        guard let obj = try? JSONSerialization.jsonObject(with: body), let d = obj as? [String: Any] else {
            throw WebAction.Invalid("the body must be a JSON object")
        }
        guard Set(d.keys) == ["expanded"], let raw = d["expanded"] as? [Any] else { throw WebAction.Invalid("the body is {expanded: [folder, …]}") }
        guard raw.count <= FileTreeState.maximumExpanded else { throw WebAction.Invalid("expanded: at most \(FileTreeState.maximumExpanded) folders") }
        var out: [String] = []
        for x in raw {
            guard let s = x as? String, s.utf8.count <= FileListPaths.maximumPathBytes else { throw WebAction.Invalid("expanded: folder paths (strings)") }
            out.append(s)
        }
        let state = FileTreeState(expanded: out)
        do { try state.validate() } catch let e as HostError { throw WebAction.Invalid(e.message) }
        return state
    }
}

/// `POST /api/v1/sandboxes/NAME/files/open` — `{path, reveal?}`: a file of a shared workspace opened on the Mac (or shown
/// in the Finder). Opens a window on the Mac's own screen, so `WebExposure` keeps it from a doz serve browser.
public struct WebFileOpen: Equatable, Sendable {
    public var path: String
    public var reveal: Bool

    public static func decode(_ body: Data) throws -> WebFileOpen {
        guard let obj = try? JSONSerialization.jsonObject(with: body), let d = obj as? [String: Any] else {
            throw WebAction.Invalid("the body must be a JSON object")
        }
        guard Set(d.keys).isSubset(of: ["path", "reveal"]), let p = d["path"] as? String, p.utf8.count <= FileListPaths.maximumPathBytes,
              FileListPaths.folder(p) != nil else { throw WebAction.Invalid("the body is {path, reveal?} — a path in /workspace") }
        var reveal = false
        if let v = d["reveal"], !(v is NSNull) {
            guard let b = v as? Bool, CFGetTypeID(v as CFTypeRef) == CFBooleanGetTypeID() else { throw WebAction.Invalid("reveal: true or false") }
            reveal = b
        }
        return WebFileOpen(path: FileListPaths.folder(p)!.guest, reveal: reveal)
    }
}

/// A running watch for one stream: its batches, and `cancel()` (the share's FSEventStream stops with its last watcher).
public final class WebFileWatch: @unchecked Sendable {
    public let sandbox: String
    public let folders: [String]
    public let batches: AsyncStream<FileChangeBatch>
    private let lock = NSLock()
    private var onCancel: (@Sendable () -> Void)?

    public init(sandbox: String, folders: [String], batches: AsyncStream<FileChangeBatch>, cancel: @escaping @Sendable () -> Void) {
        self.sandbox = sandbox
        self.folders = folders
        self.batches = batches
        onCancel = cancel
    }

    public func cancel() {
        let f: (@Sendable () -> Void)? = lock.withLock { let f = onCancel; onCancel = nil; return f }
        f?()
    }
}
