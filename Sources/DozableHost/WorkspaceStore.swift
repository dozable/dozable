import CryptoKit
import Darwin
import Foundation

/// The workspaces of a store: `<store>/workspaces/<name>/` holding `workspace.json`, `brief.md` and `log.jsonl`.
///
/// - `workspaces/` and each workspace's folder are 0700, made with no link in their path and owned by this user
///   (`MacFenceHostFS.ensureDirectory`); every file is 0600, written atomically (`MacFenceHostFS.writeAtomically`).
/// - A new workspace is assembled in `workspaces/.new-<name>-<random>/` and renamed into place (`RENAME_EXCL`): it is
///   there whole or not at all, and an existing one is never replaced.
/// - Membership (which workspace holds a sandbox or a session) is read from the records themselves (`membership()`):
///   there is no second index to drift.
/// - `log.jsonl` is appended one line per `write` (`O_APPEND`, `O_NOFOLLOW_ANY`); a torn line is skipped when read.
///
/// Reading never writes: a read-only command uses the same store in-process. The daemon is the one writer (its ops hold
/// the `workspaces` gate). `WorkspaceRecordTests`.
public struct WorkspaceStore: Sendable {
    public let store: DozableStore
    /// `<store>/workspaces`, resolved (no link in it — `/tmp` is one).
    public let root: String
    public static let maximumRecordBytes = 4 << 20
    public static let maximumBriefBytes = 256 << 10
    public static let maximumLogBytes = 16 << 20

    public init(store: DozableStore) {
        self.store = store
        root = Self.resolved(store.root.path) + "/workspaces"
    }

    /// `path` with every link resolved — the longest part that exists, then the rest as given.
    public static func resolved(_ path: String) -> String {
        var head = (path as NSString).standardizingPath, tail: [String] = []
        while head != "/" {
            if let r = realpath(head, nil) {
                defer { free(r) }
                return ([String(cString: r)] + tail.reversed()).joined(separator: "/").replacingOccurrences(of: "//", with: "/")
            }
            tail.append((head as NSString).lastPathComponent)
            head = (head as NSString).deletingLastPathComponent
        }
        return "/" + tail.reversed().joined(separator: "/")
    }

    public func folder(_ name: String) -> String { root + "/" + name }

    // MARK: reading

    /// The workspaces' names, sorted (assembly folders and anything not a workspace name are skipped).
    public func names() -> [String] {
        guard let all = try? FileManager.default.contentsOfDirectory(atPath: root) else { return [] }
        return all.filter { WorkspaceName.isValid($0) && FileManager.default.fileExists(atPath: folder($0) + "/workspace.json") }.sorted()
    }

    public func exists(_ name: String) -> Bool {
        WorkspaceName.isValid(name) && MacFenceHostFS.kind(folder(name)) != nil
    }

    /// The record (nil: no such workspace). A record that cannot be read is an error naming it.
    public func read(_ name: String) throws -> WorkspaceRecord? {
        try WorkspaceName.validate(name)
        guard MacFenceHostFS.kind(folder(name) + "/workspace.json") != nil else { return nil }
        let d: Data
        do { d = try MacFenceHostFS.readRegular(folder(name) + "/workspace.json", maximum: Self.maximumRecordBytes) } catch {
            throw HostError(.failed, "the record of \(name) cannot be read: \(error)")
        }
        do { return try HostWire.decoder.decode(WorkspaceRecord.self, from: d) } catch {
            throw HostError(.failed, "the record of \(name) cannot be read: \(error.localizedDescription)")
        }
    }

    /// Every record that can be read (one that cannot is skipped).
    public func records() -> [WorkspaceRecord] { names().compactMap { try? read($0) } }

    public func readBrief(_ name: String) -> String? {
        guard WorkspaceName.isValid(name), let d = try? MacFenceHostFS.readRegular(folder(name) + "/brief.md", maximum: Self.maximumBriefBytes) else { return nil }
        return String(decoding: d, as: UTF8.self)
    }

    /// Which workspace holds each place: `sandbox:NAME` / `mac:SESSION` → the workspace's name.
    public func membership() -> [String: String] {
        guard FileManager.default.fileExists(atPath: root) else { return [:] }
        var out: [String: String] = [:]
        for r in records() { for a in r.agents { if let k = a.place.key, out[k] == nil { out[k] = r.name } } }
        return out
    }

    /// The log's entries, oldest first, `since` and after; a line that does not parse (a torn tail) is skipped.
    public func log(_ name: String, since: Date? = nil) throws -> [WorkspaceLogEntry] {
        try WorkspaceName.validate(name)
        let path = folder(name) + "/log.jsonl"
        guard MacFenceHostFS.kind(path) != nil else { return [] }
        let d = try MacFenceHostFS.readRegular(path, maximum: Self.maximumLogBytes)
        var out: [WorkspaceLogEntry] = []
        for line in d.split(separator: 0x0A) where !line.isEmpty {
            guard let e = try? HostWire.decoder.decode(WorkspaceLogEntry.self, from: Data(line)) else { continue }
            if let since, e.at < since { continue }
            out.append(e)
        }
        return out
    }

    /// One page of the log, newest first: at most `limit` entries ending before the line at byte offset `before` (nil: the
    /// end). Read BACKWARDS in 64 KiB blocks, so a page costs its own lines, never the whole log; a line that does not parse
    /// (a torn one) is skipped, and so is a last line with no line break (a write under way) — the same way every time.
    /// `first` is the oldest returned line's offset (stable: the log is only appended to, and an append after a torn line
    /// starts on a line of its own), `more` whether anything lies before it.
    public func logPage(_ name: String, before: Int? = nil, limit: Int = WorkspaceLogPage.defaultLimit) throws -> WorkspaceLogPage {
        try WorkspaceName.validate(name)
        let path = folder(name) + "/log.jsonl"
        guard MacFenceHostFS.kind(path) != nil else { return WorkspaceLogPage(entries: [], first: nil, more: false) }
        let fd = try MacFenceHostFS.open(path, O_RDONLY | O_NONBLOCK)
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw HostError(.failed, "the log of \(name): \(String(cString: strerror(errno)))") }
        try MacFenceHostFS.checkRegular(st, path: path, uid: getuid())
        let want = max(1, min(limit, WorkspaceLogPage.maximumLimit))
        let end = min(Int(st.st_size), max(0, before ?? Int(st.st_size)))
        let block = 64 << 10
        var out: [WorkspaceLogEntry] = []
        var first: Int?
        // The newline that ends the line being looked for (nil: none seen yet — bytes after the last newline are not a line).
        var lineEnd: Int?
        var pos = end
        func take(_ start: Int, _ stop: Int) {
            guard stop > start else { return }
            var buf = [UInt8](repeating: 0, count: stop - start)
            let n = buf.withUnsafeMutableBytes { pread(fd, $0.baseAddress!, stop - start, off_t(start)) }
            guard n == stop - start, let e = try? HostWire.decoder.decode(WorkspaceLogEntry.self, from: Data(buf)) else { return }
            out.append(e)
            first = start
        }
        var chunk = [UInt8](repeating: 0, count: block)
        scan: while pos > 0 {
            let start = max(0, pos - block)
            let n = chunk.withUnsafeMutableBytes { pread(fd, $0.baseAddress!, pos - start, off_t(start)) }
            guard n == pos - start else { throw HostError(.failed, "the log of \(name): a short read") }
            var i = n - 1
            while i >= 0 {
                if chunk[i] == 0x0A {
                    let at = start + i
                    if let e = lineEnd { take(at + 1, e); if out.count == want { break scan } }
                    lineEnd = at
                }
                i -= 1
            }
            pos = start
        }
        if pos == 0, out.count < want, let e = lineEnd { take(0, e) }
        return WorkspaceLogPage(entries: out, first: first, more: (first ?? 0) > 0)
    }

    // MARK: writing

    /// `workspaces/` itself: 0700, no link, ours.
    func ensureRoot() throws {
        try Self.ensureOwnedDirectory(root)
    }

    static func ensureOwnedDirectory(_ path: String) throws {
        do { try MacFenceHostFS.ensureDirectory(path, mode: 0o700) } catch { throw HostError(.failed, "cannot make \(DisplayPath.tilde(path)): \(error)") }
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { throw HostError(.failed, "\(DisplayPath.tilde(path)) is not a folder") }
        guard st.st_uid == getuid() else { throw HostError(.failed, "\(DisplayPath.tilde(path)) is not yours — refused") }
        if st.st_mode & 0o077 != 0 { chmod(path, 0o700) }
    }

    /// Make a new workspace whole: its record, brief and first log lines, assembled aside and renamed into place. An
    /// existing workspace of that name is refused (and left as it is).
    public func create(_ record: WorkspaceRecord, brief: Data, log: [WorkspaceLogEntry]) throws {
        try WorkspaceName.validate(record.name)
        try ensureRoot()
        guard !exists(record.name) else { throw HostError(.exists, "there is already a workspace \(record.name)") }
        let temp = root + "/.new-\(record.name)-\(UInt32.random(in: 0...UInt32.max))"
        try Self.ensureOwnedDirectory(temp)
        var placed = false
        defer { if !placed { try? MacFenceHostFS.remove(temp) } }
        try MacFenceHostFS.writeAtomically(brief, dir: temp, name: "brief.md")
        try MacFenceHostFS.writeAtomically(try Self.encode(record), dir: temp, name: "workspace.json")
        try MacFenceHostFS.writeAtomically(Data(log.map { Self.line($0) }.joined().utf8), dir: temp, name: "log.jsonl")
        guard renamex_np(temp, folder(record.name), UInt32(RENAME_EXCL)) == 0 else {
            let e = errno
            if e == EEXIST { throw HostError(.exists, "there is already a workspace \(record.name)") }
            throw HostError(.failed, "could not make the workspace \(record.name): \(String(cString: strerror(e)))")
        }
        placed = true
        TimelineSignal.poke(store.root.path, .workspace)
    }

    /// Replace the record (atomically; every field this build does not know kept as read).
    public func write(_ record: WorkspaceRecord) throws {
        try WorkspaceName.validate(record.name)
        try Self.ensureOwnedDirectory(folder(record.name))
        try MacFenceHostFS.writeAtomically(try Self.encode(record), dir: folder(record.name), name: "workspace.json")
        TimelineSignal.poke(store.root.path, .workspace)          // 747: its runs, rooms and membership
    }

    public func writeBrief(_ name: String, _ text: Data) throws {
        try WorkspaceName.validate(name)
        try MacFenceHostFS.writeAtomically(text, dir: folder(name), name: "brief.md")
    }

    /// Append one entry: ONE write of one line.
    public func append(_ name: String, _ entry: WorkspaceLogEntry) throws {
        try WorkspaceName.validate(name)
        let fd = try MacFenceHostFS.open(folder(name) + "/log.jsonl", O_RDWR | O_CREAT | O_APPEND, 0o600)   // no link anywhere in its path (O_NOFOLLOW_ANY)
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw HostError(.failed, "the log of \(name): \(String(cString: strerror(errno)))") }
        try MacFenceHostFS.checkRegular(st, path: folder(name) + "/log.jsonl", uid: getuid())
        // After a torn line (a write cut short) the new one starts on a line of its own.
        var last: UInt8 = 0x0A
        if st.st_size > 0 { _ = pread(fd, &last, 1, st.st_size - 1) }
        let d = Data(((last == 0x0A ? "" : "\n") + Self.line(entry)).utf8)
        let n = d.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }
        guard n == d.count else { throw HostError(.failed, "the log of \(name): a short write") }
        TimelineSignal.poke(store.root.path, .workspace)          // 747: the timeline reads the new line
        // 767: a run opened or finished, the work description changed, a proposal made or decided — a line of the
        // workspace's follow (its `wseq`), in order with the journal's entries. Best effort: the log line stands.
        if let line = RunJournalStore.followLine(for: entry, revision: WorkspaceRuns.descriptionRevision((try? self.log(name)) ?? [])) {
            _ = try? RunJournalStore.shared(store.root.path).appendFollow(name, line)
        }
    }

    /// The workspace's folder renamed (`RENAME_EXCL`) and its record's name with it.
    public func rename(_ old: String, to new: String) throws {
        try WorkspaceName.validate(old)
        try WorkspaceName.validate(new)
        guard var r = try read(old) else { throw HostError(.notFound, "\(old) is not a workspace (doz workspace ls)") }
        guard !exists(new) else { throw HostError(.exists, "there is already a workspace \(new)") }
        guard renamex_np(folder(old), folder(new), UInt32(RENAME_EXCL)) == 0 else {
            let e = errno
            if e == EEXIST { throw HostError(.exists, "there is already a workspace \(new)") }
            throw HostError(.failed, "could not rename \(old): \(String(cString: strerror(e)))")
        }
        r.name = new
        do { try write(r) } catch {
            _ = renamex_np(folder(new), folder(old), UInt32(RENAME_EXCL))
            throw error
        }
    }

    /// The workspace gone: its folder (record, brief, log) renamed aside, then removed — never a path outside `workspaces/`.
    public func remove(_ name: String) throws {
        try WorkspaceName.validate(name)
        guard MacFenceHostFS.kind(folder(name)) != nil else { return }
        let aside = root + "/.gone-\(name)-\(UInt32.random(in: 0...UInt32.max))"
        guard Darwin.rename(folder(name), aside) == 0 else {
            throw HostError(.failed, "could not delete the workspace \(name): \(String(cString: strerror(errno)))")
        }
        do { try MacFenceHostFS.remove(aside) } catch { throw HostError(.failed, "the workspace \(name) is gone, but \(aside) was left: \(error)") }
    }

    static func encode(_ r: WorkspaceRecord) throws -> Data {
        var d = try HostWire.prettyEncoder.encode(r)
        d.append(0x0A)
        return d
    }

    static func line(_ e: WorkspaceLogEntry) -> String {
        ((try? HostWire.encoder.encode(e)).map { String(decoding: $0, as: UTF8.self) } ?? "{}") + "\n"
    }

    public static func sha256(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    /// `--since`: an ISO 8601 time, or an age — `30m`, `2h`, `3d` (also `45s`).
    public static func since(_ s: String, now: Date = Date()) -> Date? {
        let t = s.trimmingCharacters(in: .whitespaces)
        if let last = t.last, let n = Double(t.dropLast()), n >= 0 {
            switch last {
            case "s": return now.addingTimeInterval(-n)
            case "m": return now.addingTimeInterval(-n * 60)
            case "h": return now.addingTimeInterval(-n * 3600)
            case "d": return now.addingTimeInterval(-n * 86_400)
            default: break
            }
        }
        let f = ISO8601DateFormatter()
        if let d = f.date(from: t) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: t) { return d }
        f.formatOptions = [.withFullDate]
        return f.date(from: t)
    }
}
