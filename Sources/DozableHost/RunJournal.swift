import CryptoKit
import Darwin
import Foundation

// The run journal, journal/1 (767): each run of a workspace has one append-only, ordered list of entries. People and agents
// write them (`doz workspace journal W add KIND …`); anything permitted reads (`journal W [RUN]`), follows (`--follow`) and
// waits on them (`doz workspace wait W --for journal.KIND`). Dozable records entries and guarantees their order and
// integrity — the daemon assigns `id`, `seq`, `at`, `by` and `evidence` — and never enforces a process. This file holds the
// shapes, the kinds registry (journal-kinds/1), the checks (pure: `RunJournalTests`), the store and the follower.
// docs/engineering/journal.md is its public form.
//
// Storage: `<store>/workspaces/<W>/runs/<RUN>/journal.jsonl` (0600, in a 0700 folder; each line fsynced before the answer),
// copied evidence beside it in `evidence/`; at finish both go into the run's archive (`RunArchive`). Every line of a
// workspace follow (`entry`, `run`, `workspace`) is numbered by ONE per-workspace cursor, `wseq`, kept in
// `<store>/workspaces/<W>/follow.jsonl` (an entry's line there names its run and seq; the entry itself is read from its
// journal), so a follow resumes across runs and daemon restarts with nothing missed or repeated.

public enum JournalFormat {
    public static let format = "journal/1"
    public static let kinds = "journal-kinds/1"
}

/// One piece of evidence an entry carries: `{ref, sha256, bytes}` for a copied file (`stored` is the copy's path inside the
/// run's folder or its archive), `copied: false` for one hashed in place (`--attach-ref`). Set by the daemon only.
public struct JournalEvidence: Codable, Equatable, Sendable {
    public var ref: String
    public var sha256: String
    public var bytes: Int64
    /// false: hashed in place, not copied (`--attach-ref`). Absent: copied.
    public var copied: Bool?
    /// The copy, relative to the run's folder (`evidence/…`): what an archive and a reader open. Absent when not copied.
    public var stored: String?
    /// The copy had a chat token replaced (the sweep), so `sha256` is the stored copy's.
    public var swept: Bool?
    public init(ref: String, sha256: String, bytes: Int64, copied: Bool? = nil, stored: String? = nil, swept: Bool? = nil) {
        self.ref = ref; self.sha256 = sha256; self.bytes = bytes; self.copied = copied; self.stored = stored; self.swept = swept
    }
}

/// What the daemon found about one ref when the entry was written (only for the forms that say something): a `commit:`'s
/// `present` (its object in the folder's object store, read without git), a `msg:`'s `sha256`, a `url:`'s `verified: false`.
public struct JournalRefDetail: Codable, Equatable, Sendable {
    public var ref: String
    public var present: Bool?
    public var sha256: String?
    public var verified: Bool?
    public init(ref: String, present: Bool? = nil, sha256: String? = nil, verified: Bool? = nil) {
        self.ref = ref; self.present = present; self.sha256 = sha256; self.verified = verified
    }
}

/// One entry. `id`, `seq`, `at`, `by`, `evidence`, `refDetails` and `swept` are the daemon's; `superseded_by` is computed
/// on reading (never stored).
public struct JournalEntry: Codable, Equatable, Sendable {
    public var id: String
    public var seq: Int
    public var at: String
    public var by: String
    public var kind: String
    public var text: String?
    public var refs: [String]?
    public var data: JSONValue?
    public var evidence: [JournalEvidence]?
    public var refDetails: [JournalRefDetail]?
    public var supersedes: Int?
    public var swept: Bool?
    public var supersededBy: Int?

    enum CodingKeys: String, CodingKey {
        case id, seq, at, by, kind, text, refs, data, evidence, refDetails, supersedes, swept
        case supersededBy = "superseded_by"
    }

    public init(id: String, seq: Int, at: String, by: String, kind: String) {
        self.id = id; self.seq = seq; self.at = at; self.by = by; self.kind = kind
    }
}

/// `doz workspace journal W [RUN] --json`.
public struct WorkspaceJournal: Codable, Equatable, Sendable {
    public static let kind = "WorkspaceJournal"
    public var kind = WorkspaceJournal.kind
    public var schema = 1
    public var format = JournalFormat.format
    public var workspace: String
    /// The run read (nil: the workspace has no run yet).
    public var run: String?
    /// Whether that run is open (entries can be written to it).
    public var open: Bool
    /// In `seq` order; a superseded entry carries `superseded_by`.
    public var entries: [JournalEntry]
    public init(workspace: String, run: String?, open: Bool, entries: [JournalEntry]) {
        self.workspace = workspace; self.run = run; self.open = open; self.entries = entries
    }
}

/// The limits per run (journal/1). Past any: 8 `limited`, naming it.
public enum JournalLimits {
    public static let entriesPerRun = 10_000
    public static let textBytes = 64 << 10
    public static let dataBytes = 64 << 10
    public static let refs = 32
    public static let refBytes = 2048
    public static let copyFileBytes: Int64 = 10 << 20
    public static let copyRunBytes: Int64 = 200 << 20
    public static let attachments = 16
    /// A live follower: lines are read from the store at the follower's own pace (never buffered for it), so this bound is
    /// never reached in this build; `follow-lagged` is reserved for a future in-memory fan-out.
    public static let followerBuffer = 1000
    public static let heartbeatSeconds: Double = 30
}

// MARK: kinds (journal-kinds/1)

public enum JournalKinds {
    /// The ten bare names; frozen — a new known kind comes only as `dozable.KIND`.
    public static let known = ["note", "task", "claim", "criterion", "review", "finding", "outcome", "lesson", "gate", "hook"]
    /// Written by Dozable only (65 from anyone else, the owner included): `gate`, `hook` and every `dozable.` kind.
    public static let reserved: Set<String> = ["gate", "hook"]
    public static let reservedPrefix = "dozable."

    public static func isValid(_ k: String) -> Bool {
        k.range(of: "^[a-z][a-z0-9._-]{0,63}$", options: .regularExpression) != nil
    }

    public static func isReserved(_ k: String) -> Bool { reserved.contains(k) || k.hasPrefix(reservedPrefix) }

    /// The kind as a writer may give it: the pattern, and not reserved. 65 otherwise.
    public static func check(_ k: String) throws {
        guard isValid(k) else {
            throw HostError(.invalidValue, "\(k.prefix(70)) is not a kind: a lower-case letter, then up to 63 of a-z 0-9 . _ -")
        }
        if isReserved(k) {
            throw HostError(.invalidValue, "\(k) is written by Dozable only (gate, hook and every dozable. kind are reserved): pick another kind")
        }
    }

    /// A known kind's documented `data` fields that are present, checked; extra fields allowed. `data` must be an object.
    public static func checkData(_ kind: String, _ data: JSONValue?) throws {
        guard let data else {
            if let req = required[kind] { throw HostError(.invalidValue, "a \(kind) entry needs --data with \(req)") }
            return
        }
        guard case .object(let o) = data else { throw HostError(.invalidValue, "--data is a JSON object") }
        func string(_ f: String) throws {
            if let v = o[f], v.stringValue == nil { throw HostError(.invalidValue, "a \(kind) entry's data.\(f) is a string") }
        }
        func oneOf(_ f: String, _ values: [String]) throws {
            guard let v = o[f] else { return }
            guard let s = v.stringValue, values.contains(s) else {
                throw HostError(.invalidValue, "a \(kind) entry's data.\(f) is one of \(values.joined(separator: ", "))")
            }
        }
        if let req = required[kind], o[req] == nil { throw HostError(.invalidValue, "a \(kind) entry needs data.\(req)") }
        switch kind {
        case "task": try string("identity")
        case "claim": try string("task")
        case "criterion": try string("id"); try string("check")
        case "review": try string("criterion"); try oneOf("met", ["yes", "no", "partly"]); try string("subject")
        case "finding": try oneOf("severity", ["low", "medium", "high"])
        case "outcome": try string("value")
        case "lesson": try string("proposal")
        default: break
        }
    }

    static let required: [String: String] = ["criterion": "id", "outcome": "value"]
}

// MARK: refs

public enum JournalRefs {
    /// The forms: `seq:N`, `entry:RUN#SEQ`, `msg:SEQ`, `commit:SHA[@FOLDER]`, `url:URL`.
    public enum Form: Equatable, Sendable {
        case seq(Int)
        case entry(run: String, seq: Int)
        case msg(Int64)
        case commit(sha: String, folder: String?)
        case url(String)
    }

    /// One ref read (65 when it is none of the forms).
    public static func parse(_ r: String) throws -> Form {
        func bad(_ why: String) -> HostError { HostError(.invalidValue, "--ref \(r.prefix(80)): \(why)") }
        guard !r.isEmpty, r.utf8.count <= JournalLimits.refBytes, !r.contains(where: { $0.isNewline }) else {
            throw bad("a ref is one line of at most \(JournalLimits.refBytes) bytes")
        }
        guard let colon = r.firstIndex(of: ":") else { throw bad("a ref is seq:N, entry:RUN#SEQ, msg:SEQ, commit:SHA[@FOLDER] or url:URL") }
        let form = String(r[..<colon]), rest = String(r[r.index(after: colon)...])
        switch form {
        case "seq":
            guard let n = Int(rest), n >= 1 else { throw bad("seq:N names an entry of this run (N from 1)") }
            return .seq(n)
        case "entry":
            guard let c = JournalCursor.entry(rest) else { throw bad("entry:RUN#SEQ names an entry of another run") }
            return .entry(run: c.run, seq: c.seq)
        case "msg":
            guard let n = Int64(rest), n >= 1 else { throw bad("msg:SEQ names a message of the run's room") }
            return .msg(n)
        case "commit":
            let parts = rest.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            let sha = parts[0].lowercased()
            guard (4...64).contains(sha.count), sha.allSatisfy({ $0.isHexDigit }) else { throw bad("commit:SHA is 4 to 64 hex digits") }
            let folder = parts.count > 1 ? parts[1] : nil
            if let f = folder, f.isEmpty || f.contains("..") { throw bad("commit:SHA@FOLDER names one of the run's folders") }
            return .commit(sha: sha, folder: folder)
        case "url":
            guard !rest.isEmpty else { throw bad("url:URL names an address") }
            return .url(rest)
        default:
            throw bad("\(form.prefix(20)): is not a ref form — seq:N, entry:RUN#SEQ, msg:SEQ, commit:SHA[@FOLDER] or url:URL")
        }
    }

    /// The refs checked against the run: `seq:N` an earlier entry of it (`nextSeq` is the new entry's), `msg:SEQ` inside the
    /// run's room slice; a commit's presence read from its folder's object store, never with git; a URL never fetched.
    public static func check(_ refs: [String], nextSeq: Int, run: WorkspaceRun, folders: [String]) throws -> [JournalRefDetail] {
        guard refs.count <= JournalLimits.refs else { throw HostError(.limited, "an entry carries at most \(JournalLimits.refs) refs (the refs limit)") }
        var details: [JournalRefDetail] = []
        for r in refs {
            switch try parse(r) {
            case .seq(let n):
                guard n < nextSeq else { throw HostError(.invalidValue, "--ref \(r): run \(run.id) has no entry \(n) before this one") }
            case .entry:
                break
            case .msg(let s):
                let inside = run.rooms.contains { s > $0.fromSeq && ($0.toSeq.map { s <= $0 } ?? true) }
                guard inside else { throw HostError(.invalidValue, "--ref \(r): message \(s) is not in run \(run.id)'s room slice") }
            case .commit(let sha, let folder):
                details.append(JournalRefDetail(ref: r, present: commitPresent(sha, folder: folder, folders: folders)))
            case .url:
                details.append(JournalRefDetail(ref: r, verified: false))
            }
        }
        return details
    }

    /// Whether a loose object `sha` (40 or 64 hex) exists in the folder's `.git/objects` — one `lstat`-like look, no link
    /// followed, no packfile parsed, no program run. nil when it cannot be said (a short sha, no such folder, no `.git` folder).
    static func commitPresent(_ sha: String, folder: String?, folders: [String]) -> Bool? {
        guard sha.count == 40 || sha.count == 64 else { return nil }
        let root: String?
        if let f = folder {
            root = folders.first { $0 == f || ($0 as NSString).lastPathComponent == f }
        } else {
            root = folders.first
        }
        guard let root else { return nil }
        let real = WorkspaceStore.resolved(root)
        guard MacFenceHostFS.kind(real + "/.git") == S_IFDIR else { return nil }
        let i = sha.index(sha.startIndex, offsetBy: 2)
        return MacFenceHostFS.kind(real + "/.git/objects/\(sha[..<i])/\(sha[i...])") == S_IFREG
    }
}

/// A follow's cursor as typed: `RUN#SEQ` (an entry), or a `wseq`.
public enum JournalCursor {
    public static func entry(_ s: String) -> (run: String, seq: Int)? {
        let parts = s.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, WorkspaceRuns.isValidID(parts[0]) || isAnyRunName(parts[0]), let n = Int(parts[1]), n >= 0 else { return nil }
        return (parts[0], n)
    }

    /// Any name a run could have been given (an unknown one is then refused as unknown, 65, rather than malformed).
    static func isAnyRunName(_ s: String) -> Bool {
        (1...64).contains(s.utf8.count) && s.utf8.allSatisfy { ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2D || $0 == 0x5F }
    }
}

// MARK: the sweep

public enum JournalSweep {
    /// `text` and every string of `data` with each live chat token replaced (`ExportSweep`, as exports and archives are);
    /// `swept` is true when anything was.
    public static func apply(_ sweep: ExportSweep, text: String?, data: JSONValue?) -> (text: String?, data: JSONValue?, swept: Bool) {
        var any = false
        func clean(_ s: String) -> String {
            let c = sweep.clean(Array(s.utf8), file: "journal")
            if c.findings.isEmpty { return s }
            any = true
            return String(decoding: c.bytes, as: UTF8.self)
        }
        func walk(_ v: JSONValue) -> JSONValue {
            switch v {
            case .string(let s): return .string(clean(s))
            case .array(let a): return .array(a.map(walk))
            case .object(let o): return .object(o.mapValues(walk))
            default: return v
            }
        }
        let t = text.map(clean)
        let d = data.map(walk)
        return (t, d, any)
    }
}

// MARK: reading

public enum JournalRead {
    /// Each superseded entry marked with the seq of its (latest) correction; chains are allowed, and the effective entry is
    /// the last in its chain.
    public static func markSuperseded(_ entries: [JournalEntry]) -> [JournalEntry] {
        var by: [Int: Int] = [:]
        for e in entries { if let n = e.supersedes { by[n] = max(by[n] ?? 0, e.seq) } }
        return entries.map { e in var e = e; e.supersededBy = by[e.seq]; return e }
    }

    /// The entries no correction supersedes (what a gate reads).
    public static func effective(_ entries: [JournalEntry]) -> [JournalEntry] { markSuperseded(entries).filter { $0.supersededBy == nil } }

    /// The lines of a journal file, in order (a torn last line, from a write cut short, is skipped).
    public static func parse(_ d: Data) -> [JournalEntry] {
        var out: [JournalEntry] = []
        for line in d.split(separator: 0x0A) where !line.isEmpty {
            if var e = try? HostWire.decoder.decode(JournalEntry.self, from: Data(line)) { e.supersededBy = nil; out.append(e) }
        }
        return out.sorted { $0.seq < $1.seq }
    }
}

// MARK: the correction rules (pure)

public enum JournalCorrection {
    /// A correction `supersedes: n` written by `by` for a new entry of `kind`, with `mayCorrectOthers` (the owner, or
    /// `journal.supersede` held): nil when it may be appended, else the refusal — 65 for the wrong shape (no such earlier
    /// entry, another kind), 9 naming `journal.supersede` for another's entry.
    public static func refusal(supersedes n: Int, kind: String, by: String, entries: [JournalEntry], mayCorrectOthers: Bool) -> HostError? {
        let nextSeq = (entries.last?.seq ?? 0) + 1
        guard n >= 1, n < nextSeq, let orig = entries.first(where: { $0.seq == n }) else {
            return HostError(.invalidValue, "--supersedes \(n): there is no earlier entry \(n) in this run")
        }
        guard orig.kind == kind else {
            return HostError(.invalidValue, "--supersedes \(n): a correction has the kind of the entry it corrects (\(orig.kind), not \(kind))")
        }
        if orig.by != by, !mayCorrectOthers {
            return HostError(.notPermitted, "--supersedes \(n): entry \(n) is \(orig.by)'s — correcting another's entry needs journal.supersede")
        }
        return nil
    }
}

// MARK: the store

/// The journal's files: each run's `journal.jsonl` (and `evidence/`), and the workspace's `follow.jsonl` (the `wseq` lines).
/// The daemon is the one writer; its appends are serialised here (one lock), and `wseq` is read back from the file once
/// per workspace (re-read when the file is not the one it read: another inode or size), so it never repeats or skips.
public final class RunJournalStore: @unchecked Sendable {
    public let storeRoot: String
    private let lock = NSLock()
    private var wseqs: [String: (ino: UInt64, size: Int64, last: Int64)] = [:]

    /// `storeRoot`: the store's root, resolved (no link in it). One per store in a process (`shared`): its lock is what
    /// keeps `wseq` from repeating.
    init(storeRoot: String) { self.storeRoot = storeRoot }

    nonisolated(unsafe) private static var instances: [String: RunJournalStore] = [:]
    private static let instancesLock = NSLock()

    /// The one store of `root` (resolved here) in this process.
    public static func shared(_ root: String) -> RunJournalStore {
        let r = WorkspaceStore.resolved(root)
        instancesLock.lock(); defer { instancesLock.unlock() }
        if let s = instances[r] { return s }
        let s = RunJournalStore(storeRoot: r)
        instances[r] = s
        return s
    }

    public func workspaceFolder(_ w: String) -> String { storeRoot + "/workspaces/" + w }
    public func runFolder(_ w: String, _ run: String) -> String { workspaceFolder(w) + "/runs/" + run }
    public func journalPath(_ w: String, _ run: String) -> String { runFolder(w, run) + "/journal.jsonl" }
    public func followPath(_ w: String) -> String { workspaceFolder(w) + "/follow.jsonl" }
    public func archiveFolder(_ w: String, _ run: String) -> String { storeRoot + "/" + WorkspaceRuns.archivePath(workspace: w, run: run) }

    static func checkNames(_ w: String, _ run: String?) throws {
        try WorkspaceName.validate(w)
        if let run, !JournalCursor.isAnyRunName(run) { throw HostError(.invalidValue, "\(run.prefix(40)) is not a run") }
    }

    /// The journal's bytes: the run's own file, else its archive's (a finished run whose folder went once its archive
    /// verified). Empty when neither exists.
    public func journalData(_ w: String, _ run: String) throws -> Data {
        try Self.checkNames(w, run)
        for p in [journalPath(w, run), archiveFolder(w, run) + "/journal.jsonl"] where MacFenceHostFS.kind(p) == S_IFREG {
            return try MacFenceHostFS.readRegular(p, maximum: 512 << 20)
        }
        return Data()
    }

    public func entries(_ w: String, _ run: String) throws -> [JournalEntry] { JournalRead.parse(try journalData(w, run)) }

    /// Where a copied piece of evidence is: in the run's folder, else in its archive.
    public func evidencePath(_ w: String, _ run: String, stored: String) -> String? {
        guard stored.hasPrefix("evidence/"), !stored.contains(".."), !stored.dropFirst(9).contains("/") else { return nil }
        for base in [runFolder(w, run), archiveFolder(w, run)] where MacFenceHostFS.kind(base + "/" + stored) == S_IFREG {
            return base + "/" + stored
        }
        return nil
    }

    /// The run's folder (and its `evidence/`), 0700, no link in its path.
    public func ensureRunFolder(_ w: String, _ run: String) throws {
        try Self.checkNames(w, run)
        for p in [workspaceFolder(w) + "/runs", runFolder(w, run), runFolder(w, run) + "/evidence"] {
            try WorkspaceStore.ensureOwnedDirectory(p)
        }
    }

    /// One line appended to `path` (0600, no link in its path, a regular file of ours) and fsynced before it returns.
    static func appendLine(_ path: String, _ line: Data) throws {
        let fd = try MacFenceHostFS.open(path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw HostError(.failed, "\(DisplayPath.tilde(path)): \(String(cString: strerror(errno)))") }
        try MacFenceHostFS.checkRegular(st, path: path, uid: getuid())
        var d = line
        if st.st_size > 0 {
            var last: UInt8 = 0x0A
            _ = pread(fd, &last, 1, st.st_size - 1)
            if last != 0x0A { d.insert(0x0A, at: 0) }        // after a torn line the new one starts on its own
        }
        d.append(0x0A)
        let n = d.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }
        guard n == d.count else { throw HostError(.failed, "\(DisplayPath.tilde(path)): a short write") }
        guard fsync(fd) == 0 else { throw HostError(.failed, "\(DisplayPath.tilde(path)): fsync: \(String(cString: strerror(errno)))") }
    }

    /// Append one entry to its run's journal (fsynced).
    public func appendEntry(_ w: String, _ run: String, _ e: JournalEntry) throws {
        try ensureRunFolder(w, run)
        var stored = e
        stored.supersededBy = nil
        try Self.appendLine(journalPath(w, run), try HostWire.encoder.encode(stored))
    }

    // MARK: wseq

    /// The last `wseq` written to `w`'s follow file (0: none).
    public func lastWseq(_ w: String) -> Int64 {
        lock.lock(); defer { lock.unlock() }
        return (try? currentWseq(w)) ?? 0
    }

    /// Under the lock: the cached value while the file is the one read, else read again.
    private func currentWseq(_ w: String) throws -> Int64 {
        let p = followPath(w)
        guard MacFenceHostFS.kind(p) == S_IFREG else { wseqs[w] = nil; return 0 }
        let fd = try MacFenceHostFS.open(p, O_RDONLY | O_NONBLOCK)
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { return 0 }
        if let c = wseqs[w], c.ino == UInt64(st.st_ino), c.size == Int64(st.st_size) { return c.last }
        let d = try MacFenceHostFS.readRegular(p, maximum: 1 << 30)
        var last: Int64 = 0
        for line in d.split(separator: 0x0A).reversed() where !line.isEmpty {
            if case .object(let o)? = try? HostWire.decoder.decode(JSONValue.self, from: Data(line)), case .number(let n)? = o["wseq"] { last = Int64(n); break }
        }
        wseqs[w] = (UInt64(st.st_ino), Int64(st.st_size), last)
        return last
    }

    /// One follow line appended with the next `wseq` (fsynced); answers that wseq.
    @discardableResult
    public func appendFollow(_ w: String, _ body: [String: JSONValue]) throws -> Int64 {
        try WorkspaceName.validate(w)
        lock.lock(); defer { lock.unlock() }
        let next = (try currentWseq(w)) + 1
        var line = body
        line["wseq"] = .number(Double(next))
        try WorkspaceStore.ensureOwnedDirectory(workspaceFolder(w))
        try Self.appendLine(followPath(w), try HostWire.encoder.encode(JSONValue.object(line)))
        var st = stat()
        if lstat(followPath(w), &st) == 0 { wseqs[w] = (UInt64(st.st_ino), Int64(st.st_size), next) }
        return next
    }

    /// The follow lines after byte `offset` (whole lines only) and the offset after them.
    public func followLines(_ w: String, from offset: Int64) -> (lines: [[String: JSONValue]], next: Int64) {
        let p = followPath(w)
        guard let fd = try? MacFenceHostFS.open(p, O_RDONLY | O_NONBLOCK) else { return ([], offset) }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, Int64(st.st_size) > offset else { return ([], offset) }
        let want = Int(min(Int64(st.st_size) - offset, 8 << 20))
        var buf = [UInt8](repeating: 0, count: want)
        let n = pread(fd, &buf, want, off_t(offset))
        guard n > 0 else { return ([], offset) }
        guard let lastNL = buf[0..<n].lastIndex(of: 0x0A) else { return ([], offset) }
        var out: [[String: JSONValue]] = []
        for line in buf[0..<lastNL].split(separator: 0x0A) where !line.isEmpty {
            if case .object(let o)? = try? HostWire.decoder.decode(JSONValue.self, from: Data(line)) { out.append(o) }
        }
        return (out, offset + Int64(lastNL) + 1)
    }

    /// Every follow line of `w`, in order.
    public func allFollowLines(_ w: String) -> [[String: JSONValue]] {
        var out: [[String: JSONValue]] = []
        var off: Int64 = 0
        while true {
            let (ls, next) = followLines(w, from: off)
            if next == off { break }
            out += ls
            off = next
        }
        return out
    }

    // MARK: workspace events (from the workspace's log)

    /// The follow line a log entry makes, if any: a run opened or finished, the work description changed, a proposal made
    /// or decided. `revision` is the description's after the entry.
    public static func followLine(for e: WorkspaceLogEntry, revision: @autoclosure () -> Int) -> [String: JSONValue]? {
        let at = JSONValue.string(JournalTime.string(e.at))
        switch e.action {
        case "run-opened":
            guard let r = e.run else { return nil }
            return ["type": .string("run"), "event": .string("opened"), "run": .string(r), "at": at]
        case "run-closed":
            guard let r = e.run else { return nil }
            var l: [String: JSONValue] = ["type": .string("run"), "event": .string("finished"), "run": .string(r), "at": at]
            if let v = e.reason { l["by"] = .string(v) }
            return l
        case "brief-edited", "refs-edited", "addendum-added":
            var l: [String: JSONValue] = ["type": .string("workspace"), "event": .string("description.changed"), "at": at,
                                          "revision": .number(Double(revision())), "change": .string(e.action)]
            if let p = e.proposal { l["proposal"] = .string(p) }
            return l
        case "proposal-made":
            var l: [String: JSONValue] = ["type": .string("workspace"), "event": .string("proposal.made"), "at": at]
            if let p = e.proposal { l["proposal"] = .string(p) }
            if let r = e.run { l["run"] = .string(r) }
            return l
        case "proposal-applied", "proposal-declined":
            var l: [String: JSONValue] = ["type": .string("workspace"), "event": .string("proposal.decided"), "at": at,
                                          "decision": .string(e.action == "proposal-applied" ? "applied" : "declined")]
            if let p = e.proposal { l["proposal"] = .string(p) }
            if e.action == "proposal-applied" { l["revision"] = .number(Double(revision())) }
            return l
        default:
            return nil
        }
    }
}

/// `at` as the journal writes it: ISO 8601, UTC, milliseconds.
public enum JournalTime {
    public static func string(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
    }
}

// MARK: evidence

public enum JournalEvidenceFiles {
    /// The file `path` (absolute, as typed after `~`) inside one of `folders` (the run's places' folders): its folder's real
    /// path joined with the part inside it — no `..`, and no link in that part (each open is `O_NOFOLLOW_ANY` from the
    /// folder's real path). nil when it is in none of them.
    public static func resolve(_ path: String, folders: [String]) -> (real: String, inside: String, folder: String)? {
        let clean = (path as NSString).standardizingPath
        guard clean.hasPrefix("/") else { return nil }
        for f in folders {
            let real = WorkspaceStore.resolved(f)
            for base in Set([(f as NSString).standardizingPath, real]) {
                let b = base.hasSuffix("/") ? String(base.dropLast()) : base
                guard clean.hasPrefix(b + "/") else { continue }
                let inside = String(clean.dropFirst(b.count + 1))
                guard !inside.isEmpty, !inside.split(separator: "/").contains("..") else { continue }
                return (real + "/" + inside, inside, f)
            }
        }
        return nil
    }

    /// A file read through no link (`O_NOFOLLOW_ANY`): a regular file of yours with one name. With `copyMaximum`, its bytes
    /// (more is 8 `limited`); without, only hashed. Answers the sha256, the size and (copying) the bytes.
    public static func read(_ real: String, shown: String, copyMaximum: Int64?) throws -> (sha256: String, bytes: Int64, data: Data?) {
        let fd: Int32
        do { fd = try MacFenceHostFS.open(real, O_RDONLY | O_NONBLOCK) } catch {
            throw HostError(.invalidValue, "\(shown): \(error) — a file is attached only through no link, inside the run's folders")
        }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw HostError(.failed, "\(shown): \(String(cString: strerror(errno)))") }
        do { try MacFenceHostFS.checkRegular(st, path: shown, uid: getuid()) } catch { throw HostError(.invalidValue, "\(error)") }
        if let m = copyMaximum, Int64(st.st_size) > m {
            throw HostError(.limited, "\(shown) is \(st.st_size) bytes — at most \(m) bytes are copied (the per-file evidence limit); --attach-ref records its hash without copying it")
        }
        var h = SHA256()
        var copy = copyMaximum == nil ? nil : Data()
        var total: Int64 = 0
        var buf = [UInt8](repeating: 0, count: 1 << 20)
        while true {
            let n = Darwin.read(fd, &buf, buf.count)
            if n < 0 { if errno == EINTR { continue }; throw HostError(.failed, "\(shown): \(String(cString: strerror(errno)))") }
            if n == 0 { break }
            total += Int64(n)
            if let m = copyMaximum, total > m { throw HostError(.limited, "\(shown) grew past \(m) bytes while it was read (the per-file evidence limit)") }
            h.update(data: buf[0..<n])
            copy?.append(contentsOf: buf[0..<n])
        }
        return (h.finalize().map { String(format: "%02x", $0) }.joined(), total, copy)
    }

    /// A stored copy's name: the content's hash prefix and the file's own name (only safe characters kept).
    public static func storedName(sha256: String, inside: String) -> String {
        let base = (inside as NSString).lastPathComponent
        let safe = String(base.unicodeScalars.map { c -> Character in
            let v = c.value
            let ok = (v >= 0x61 && v <= 0x7A) || (v >= 0x41 && v <= 0x5A) || (v >= 0x30 && v <= 0x39) || v == 0x2E || v == 0x2D || v == 0x5F
            return ok ? Character(c) : "_"
        }).prefix(100)
        let name = safe.isEmpty || safe.hasPrefix(".") ? "file" + safe : String(safe)
        return "evidence/\(sha256.prefix(12))-\(name)"
    }
}

// MARK: following

/// A follow: the lines after a cursor, then live ones, read from the store at the follower's own pace (so a slow follower
/// never makes the daemon buffer or block a writer). Ends with `end` on a graceful close (`daemon-stopping`, or
/// `run-finished` under `untilFinish`); a bare EOF means "reconnect with the cursor you last saw".
public final class JournalFollower: @unchecked Sendable {
    /// Set when the daemon stops: every follow sends `end` (reason `daemon-stopping`) and closes.
    nonisolated(unsafe) public static var stopping = false

    public enum Mode: Equatable, Sendable {
        /// Every line (entries, runs, workspace events), resumed by `wseq`.
        case workspace
        /// Entries only, resumed by `RUN#SEQ`.
        case entries
    }

    let store: RunJournalStore
    let workspace: String
    let mode: Mode
    /// The wseq the follow starts after.
    let startWseq: Int64
    /// What `hello.after` says: the wseq (workspace) or the entry id (entries).
    let startAfter: JSONValue
    let openRun: String?
    let untilFinish: Bool
    let poll: Double
    let heartbeat: Double

    public init(store: RunJournalStore, workspace: String, mode: Mode, startWseq: Int64, startAfter: JSONValue, openRun: String?,
                untilFinish: Bool, poll: Double = 0.2, heartbeat: Double = JournalLimits.heartbeatSeconds) {
        self.store = store; self.workspace = workspace; self.mode = mode; self.startWseq = startWseq; self.startAfter = startAfter
        self.openRun = openRun; self.untilFinish = untilFinish; self.poll = poll; self.heartbeat = heartbeat
    }

    /// The follower for `w` after a cursor: `afterWseq` (0 = from the start; past the last one → 65), `after` (`RUN#SEQ`, an
    /// entry the journal holds, or `RUN#0` for a run's start → 65 otherwise), or neither (live from now).
    public static func make(store: RunJournalStore, workspace w: String, record: WorkspaceRecord, afterWseq: Int64?, after: String?,
                            untilFinish: Bool) throws -> JournalFollower {
        let open = record.openRun?.id
        if afterWseq != nil, after != nil { throw HostError(.usage, "--after-wseq or --after, not both") }
        if let n = afterWseq {
            let last = store.lastWseq(w)
            guard n >= 0, n <= last else {
                throw HostError(.invalidValue, "--after-wseq \(n): \(w)'s follow has no line \(n) (its last is \(last)) — not replayed from the start")
            }
            return JournalFollower(store: store, workspace: w, mode: .workspace, startWseq: n, startAfter: .number(Double(n)), openRun: open,
                                   untilFinish: untilFinish)
        }
        if let a = after {
            guard let c = JournalCursor.entry(a), record.runs.contains(where: { $0.id == c.run }) else {
                throw HostError(.invalidValue, "--after \(a.prefix(60)): \(w) has no such entry — not replayed from the start")
            }
            let lines = store.allFollowLines(w)
            var at: Int64?
            if c.seq == 0 {
                // The run's start: just before its opening line (or the start of the follow, when it has none).
                at = 0
                for l in lines where l["type"]?.stringValue == "run" && l["event"]?.stringValue == "opened" && l["run"]?.stringValue == c.run {
                    if case .number(let n)? = l["wseq"] { at = Int64(n) - 1; break }
                }
            } else {
                for l in lines where l["type"]?.stringValue == "entry" && l["run"]?.stringValue == c.run {
                    if case .number(let s)? = l["seq"], Int(s) == c.seq, case .number(let n)? = l["wseq"] { at = Int64(n) }
                }
            }
            guard let start = at else { throw HostError(.invalidValue, "--after \(a.prefix(60)): \(w) has no such entry — not replayed from the start") }
            return JournalFollower(store: store, workspace: w, mode: .entries, startWseq: start, startAfter: .string("\(c.run)#\(c.seq)"),
                                   openRun: open, untilFinish: untilFinish)
        }
        let last = store.lastWseq(w)
        return JournalFollower(store: store, workspace: w, mode: .workspace, startWseq: last, startAfter: .number(Double(last)), openRun: open,
                               untilFinish: untilFinish)
    }

    /// The hello line.
    public var hello: JSONValue {
        .object(["type": .string("hello"), "format": .string(JournalFormat.format), "workspace": .string(workspace),
                 "run": openRun.map(JSONValue.string) ?? .null, "after": startAfter])
    }

    /// Runs the follow: `send` each line (false: the follower went — stop); `cancelled` is asked between polls.
    public func run(send: (JSONValue) -> Bool, cancelled: () -> Bool) {
        guard send(hello) else { return }
        var after = startAfter
        var cursor = startWseq
        var offset: Int64 = 0
        var cache: [String: [Int: JournalEntry]] = [:]
        var lastSent = Date()
        func entry(_ run: String, _ seq: Int) -> JournalEntry? {
            if let e = cache[run]?[seq] { return e }
            let all = (try? store.entries(workspace, run)) ?? []
            cache[run] = Dictionary(all.map { ($0.seq, $0) }, uniquingKeysWith: { a, _ in a })
            return cache[run]?[seq]
        }
        func end(_ reason: String) { _ = send(.object(["type": .string("end"), "reason": .string(reason), "after": after])) }
        while true {
            if cancelled() { return }
            if Self.stopping { end("daemon-stopping"); return }
            let (lines, next) = store.followLines(workspace, from: offset)
            offset = next
            for l in lines {
                guard case .number(let wn)? = l["wseq"] else { continue }
                let w = Int64(wn)
                guard w > cursor else { continue }
                cursor = w
                let type = l["type"]?.stringValue ?? ""
                var out: JSONValue?
                switch type {
                case "entry":
                    guard let run = l["run"]?.stringValue, case .number(let s)? = l["seq"], let e = entry(run, Int(s)),
                          let ev = try? JSONValue(encoding: e) else { break }
                    out = .object(["type": .string("entry"), "wseq": .number(wn), "run": .string(run), "entry": ev])
                    if mode == .entries { after = .string(e.id) }
                case "run", "workspace":
                    if mode == .workspace { out = .object(l) }
                default:
                    break
                }
                if mode == .workspace { after = .number(wn) }
                if let out {
                    guard send(out) else { return }
                    lastSent = Date()
                }
                if untilFinish, type == "run", l["event"]?.stringValue == "finished", let r = l["run"]?.stringValue, openRun == nil || r == openRun {
                    end("run-finished")
                    return
                }
            }
            if Date().timeIntervalSince(lastSent) >= heartbeat {
                guard send(.object(["type": .string("heartbeat"), "at": .string(JournalTime.string(Date())), "after": after])) else { return }
                lastSent = Date()
            }
            if lines.isEmpty { Thread.sleep(forTimeInterval: poll) }
        }
    }
}
