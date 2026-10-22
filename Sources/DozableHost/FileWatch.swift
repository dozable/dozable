import CoreServices
import Foundation
import DozableKit

// 643 (624.B1 part 1): the low-impact file watcher. A SHARED workspace is watched on the Mac with FSEvents — no guest
// call, no VM, no host: the watch runs in the process that asks (`doz ui`'s server for the page's stream, `doz files
// --watch` for the CLI), against the sandbox's shared folder read from its record. That is deliberate: a host stream is
// a held connection, and the host counts every held connection as in use — an open panel would keep an idle host alive
// (T3), and with no host running a watch would have to start one (looking never starts the host).
//
// Low impact: nothing is watched unless a client names folders (≤ `FileWatchCoalescer.maximumFolders`); one FSEventStream
// per sandbox per process (`FileWatchHub`), shared by every watcher in that process and stopped with the last one; the
// FILE-level events are coalesced — the first opens a `window`, and at its end each watcher gets ONE batch naming the
// watched folders whose listing changed (never a name: a hidden one never travels), or `resync`. The client re-lists.
//
// An isolated sandbox is not watched (its files are inside its own disk): a guest watcher needs a guest helper, which is
// the owner's call — until then it is refreshed on demand (`FileWatchTarget.resolve` says so).
//
// CoreServices (FSEvents) is imported here and the audit allows it in this file only, beside its two LaunchServices uses.

/// Events in, batches out — pure (no FSEvents, no clock), so the rules are unit-tested.
public struct FileWatchCoalescer {
    /// How long changes are gathered before a batch: at most 1 / window batches a second per watcher.
    public static let window: Duration = .milliseconds(250)
    /// Folders a watcher may name, and the most one batch names (more changed at once → `resync`).
    public static let maximumFolders = 64

    /// Folders (relative to the share's realpath; "" the root) whose listing changed since the last drain.
    public private(set) var pending: Set<String> = []
    public private(set) var resync = false
    private var evaluator: WorkspaceRules.Evaluator?
    private var fold = true

    public init(rules: WorkspaceRules?) { setRules(rules) }

    public mutating func setRules(_ rules: WorkspaceRules?) {
        evaluator = rules.map { WorkspaceRules.Evaluator($0) }
        fold = rules?.fold ?? true
    }

    public var isEmpty: Bool { pending.isEmpty && !resync }

    /// Every watched folder must be listed again (events were dropped, the root moved, the rules changed).
    public mutating func addResync() { resync = true }

    /// One changed path (relative to the share's realpath; "" the root itself). `metadataOnly`: nothing was created,
    /// removed or renamed — only contents or attributes changed. A FOLDER's metadata-only event is ignored: it is the
    /// folder's own time moving because a child changed, and the child's event already says so (counting it would also
    /// tell the folder's watchers that a HIDDEN child changed). Returns true when the path is one of the rule files at the
    /// root — the rules must be read again (and everything is listed again).
    @discardableResult
    public mutating func add(_ rel: String, isDirectory: Bool, metadataOnly: Bool = false) -> Bool {
        let rel = rel.hasSuffix("/") ? String(rel.dropLast()) : rel
        if !rel.contains("/"), !rel.isEmpty, WorkspaceRules.ruleFiles.contains(where: { fold ? $0.caseInsensitiveCompare(rel) == .orderedSame : $0 == rel }) {
            resync = true
            return true
        }
        if isDirectory && metadataOnly { return false }
        if rel.isEmpty { pending.insert(""); return false }
        let parent = (rel as NSString).deletingLastPathComponent
        if evaluator != nil {
            // A hidden entry never shows in a listing: its change is not one. A folder that is locked (or hidden) cannot be
            // listed: nothing inside it is a change anyone sees.
            let mine = evaluator!.decide(rel) { $0 == rel ? isDirectory : true }.verdict
            if mine == .hidden { return false }
            let parentVerdict: WorkspaceVerdict = parent.isEmpty ? .visible : evaluator!.decide(parent) { _ in true }.verdict
            if parentVerdict == .hidden || parentVerdict == .locked { return false }
            pending.insert(parent)
            if isDirectory && mine != .locked { pending.insert(rel) }
            return false
        }
        pending.insert(parent)
        if isDirectory { pending.insert(rel) }
        return false
    }

    /// One watcher: its folders, relative to the share's realpath → the guest path it asked for.
    public struct Watcher: Sendable {
        public var id: UUID
        public var folders: [String: String]
        public init(id: UUID, folders: [String: String]) { self.id = id; self.folders = folders }
    }

    /// The batches — at most one per watcher, only for a watcher with something in it — and a fresh start.
    public mutating func drain(_ watchers: [Watcher], sandbox: String, now: Date = Date()) -> [(id: UUID, batch: FileChangeBatch)] {
        defer { pending = []; resync = false }
        var out: [(UUID, FileChangeBatch)] = []
        for w in watchers {
            if resync { out.append((w.id, FileChangeBatch(sandbox: sandbox, folders: [], resync: true, time: now))); continue }
            let hits = w.folders.keys.filter { pending.contains($0) }
            if hits.isEmpty { continue }
            if hits.count > Self.maximumFolders {
                out.append((w.id, FileChangeBatch(sandbox: sandbox, folders: [], resync: true, time: now)))
                continue
            }
            out.append((w.id, FileChangeBatch(sandbox: sandbox, folders: hits.compactMap { w.folders[$0] }.sorted(), resync: false, time: now)))
        }
        return out
    }
}

/// What to watch: a sandbox's shared folder and the folders in it — resolved from the STORE (its record and the
/// settings), never a host. Every folder is confined and ruled exactly as a listing is.
public struct FileWatchTarget: Sendable, Equatable {
    public var sandbox: String
    /// The Mac folder shared at /workspace (from the record) and its realpath.
    public var workspace: String
    public var root: String
    public var mode: WorkspaceRuleMode
    public var viewOn: Bool
    /// Each watched folder: relative to `root` → the guest path as resolved for the asker.
    public var folders: [String: String]

    /// `folders`: as a listing takes them (relative to /workspace, or /workspace/…); none = /workspace.
    public static func resolve(store: DozableStore, sandbox: String, folders: [String]) throws -> FileWatchTarget {
        guard WebNameCheck.isSandboxName(sandbox), let cfg = SandboxConfig.read(store.configFile(sandbox)) else {
            throw HostError(.notFound, "no sandbox \(FileListPaths.inert(sandbox, limit: 40).text) (doz ls)")
        }
        guard let w = cfg.workspace else {
            throw HostError(.invalid, "\(sandbox) is isolated — its files are inside it and are not watched: list them again to refresh (doz files \(sandbox))")
        }
        guard folders.count <= FileWatchCoalescer.maximumFolders else {
            throw HostError(.invalid, "at most \(FileWatchCoalescer.maximumFolders) folders are watched at once")
        }
        let mode = HostCore.ruleMode(cfg).mode, viewOn = HostCore.workspaceViewOn(cfg)
        let rules = MacFolderListing.rules(workspace: w, mode: mode, viewOn: viewOn)
        var map: [String: String] = [:]
        var root = ""
        for f in folders.isEmpty ? [FileListPaths.root] : folders {
            guard let (guest, rel) = FileListPaths.folder(f) else {
                throw HostError(.invalid, "not a folder in /workspace: \(FileListPaths.shown(f))")
            }
            let r = try MacFolderListing.resolve(workspace: w, rel: rel, rules: rules)
            root = r.root
            map[r.inside] = guest
        }
        return FileWatchTarget(sandbox: sandbox, workspace: w, root: root, mode: mode, viewOn: viewOn, folders: map)
    }
}

/// A watcher's handle: `cancel()` stops it (the sandbox's stream stops with its last watcher).
public final class FileWatchSubscription: @unchecked Sendable {
    private let lock = NSLock()
    private var onCancel: (@Sendable () -> Void)?
    init(_ onCancel: @escaping @Sendable () -> Void) { self.onCancel = onCancel }
    public func cancel() {
        let f: (@Sendable () -> Void)? = lock.withLock { let f = onCancel; onCancel = nil; return f }
        f?()
    }
}

/// One FSEventStream per sandbox (per share) in this process, shared by its watchers.
public final class FileWatchHub: @unchecked Sendable {
    private let lock = NSLock()
    private var watches: [String: SandboxFileWatch] = [:]
    let window: Duration

    public init(window: Duration = FileWatchCoalescer.window) { self.window = window }

    /// The FSEventStreams running now (tests: one per sandbox, none after the last watcher).
    public var streams: Int { lock.withLock { watches.values.filter(\.running).count } }

    /// Watch `target`'s folders; `onBatch` is called (on the sandbox's queue — keep it short) with each coalesced batch.
    public func watch(_ target: FileWatchTarget, onBatch: @escaping @Sendable (FileChangeBatch) -> Void) throws -> FileWatchSubscription {
        let key = target.sandbox + "\u{0}" + target.root
        let id = UUID()
        while true {
            let w: SandboxFileWatch = lock.withLock {
                if let w = watches[key] { return w }
                let w = SandboxFileWatch(target: target, window: window)
                watches[key] = w
                return w
            }
            switch try w.add(id, folders: target.folders, onBatch: onBatch) {
            case true:
                return FileWatchSubscription { [weak self, w] in
                    if w.remove(id) { self?.lock.withLock { if self?.watches[key] === w { self?.watches[key] = nil } } }
                }
            case false:
                // It was stopping as this one came: forget it and start a fresh one.
                lock.withLock { if watches[key] === w { watches[key] = nil } }
            }
        }
    }
}

/// The stream of one share and its watchers. Everything mutable is touched on `queue` only (FSEvents delivers there).
final class SandboxFileWatch: @unchecked Sendable {
    let sandbox: String
    let root: String
    let workspace: String
    let mode: WorkspaceRuleMode
    let viewOn: Bool
    let window: Duration
    let queue: DispatchQueue
    private var stream: FSEventStreamRef?
    private var watchers: [UUID: (folders: [String: String], onBatch: @Sendable (FileChangeBatch) -> Void)] = [:]
    private var coalescer: FileWatchCoalescer
    private var flushScheduled = false
    private var retired = false
    private let runningFlag = NSLock()
    private var _running = false
    var running: Bool { runningFlag.withLock { _running } }

    init(target: FileWatchTarget, window: Duration) {
        sandbox = target.sandbox
        root = target.root
        workspace = target.workspace
        mode = target.mode
        viewOn = target.viewOn
        self.window = window
        queue = DispatchQueue(label: "doz.files.\(target.sandbox)")
        coalescer = FileWatchCoalescer(rules: MacFolderListing.rules(workspace: target.workspace, mode: target.mode, viewOn: target.viewOn))
        queue.setSpecific(key: Self.onQueue, value: ObjectIdentifier(self))
    }

    /// false: this watch is retiring (its last watcher left) — make a new one.
    func add(_ id: UUID, folders: [String: String], onBatch: @escaping @Sendable (FileChangeBatch) -> Void) throws -> Bool {
        try queue.sync {
            if retired { return false }
            watchers[id] = (folders, onBatch)
            if stream == nil {
                do { try start() } catch { watchers[id] = nil; retired = watchers.isEmpty; throw error }
            }
            return true
        }
    }

    /// Returns true when it was the last watcher (the stream is stopped and this watch retired). Safe from a watcher's own
    /// `onBatch` (already on `queue`: done in place, never a `sync` onto itself).
    func remove(_ id: UUID) -> Bool {
        let work = { [self] () -> Bool in
            watchers[id] = nil
            guard watchers.isEmpty, !retired else { return false }
            stop()
            retired = true
            return true
        }
        return DispatchQueue.getSpecific(key: Self.onQueue) == ObjectIdentifier(self) ? work() : queue.sync(execute: work)
    }

    private static let onQueue = DispatchSpecificKey<ObjectIdentifier>()

    private func start() throws {
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
                                             | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot)
        guard let s = FSEventStreamCreate(kCFAllocatorDefault, { _, info, count, paths, flags, _ in
            guard let info else { return }
            let me = Unmanaged<SandboxFileWatch>.fromOpaque(info).takeUnretainedValue()
            let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as NSArray
            var events: [(String, FSEventStreamEventFlags)] = []
            for i in 0..<min(count, list.count) { if let p = list[i] as? String { events.append((p, flags[i])) } }
            me.received(events)
        }, &ctx, [root] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.05, flags) else {
            throw HostError(.failed, "could not watch \(DisplayPath.tilde(workspace)) on this Mac")
        }
        FSEventStreamSetDispatchQueue(s, queue)
        guard FSEventStreamStart(s) else {
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            throw HostError(.failed, "could not watch \(DisplayPath.tilde(workspace)) on this Mac")
        }
        stream = s
        runningFlag.withLock { _running = true }
    }

    private func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
        runningFlag.withLock { _running = false }
    }

    /// On `queue` (FSEvents' callback).
    private func received(_ events: [(String, FSEventStreamEventFlags)]) {
        guard stream != nil else { return }
        let lost = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                                           | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged)
        for (path, f) in events {
            if f & lost != 0 { coalescer.addResync(); continue }
            let p = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
            let rel: String
            if p == root { rel = "" } else if p.hasPrefix(root == "/" ? "/" : root + "/") { rel = String(p.dropFirst(root == "/" ? 1 : root.count + 1)) } else { continue }
            let isDir = f & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0
            let structural = f & FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved
                                                         | kFSEventStreamEventFlagItemRenamed) != 0
            if coalescer.add(rel, isDirectory: isDir, metadataOnly: !structural) {
                coalescer.setRules(MacFolderListing.rules(workspace: workspace, mode: mode, viewOn: viewOn))
            }
        }
        if !coalescer.isEmpty && !flushScheduled {
            flushScheduled = true
            let ms = Int(window.components.seconds * 1000) + Int(window.components.attoseconds / 1_000_000_000_000_000)
            queue.asyncAfter(deadline: .now() + .milliseconds(ms)) { [self] in flush() }
        }
    }

    private func flush() {
        flushScheduled = false
        guard stream != nil else { return }
        let ws = watchers.map { FileWatchCoalescer.Watcher(id: $0.key, folders: $0.value.folders) }
        for (id, batch) in coalescer.drain(ws, sandbox: sandbox) { watchers[id]?.onBatch(batch) }
    }
}
