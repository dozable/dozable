import CryptoKit
import Darwin
import DozableChat
import Foundation

// A run's evidence archive: `<store>/archives/<workspace>/runs/<run>/` — outside `workspaces/W/`, so a delete keeps it.
// Written into `<run>.partial/` (0700 folders, 0600 files, each `O_CREAT|O_EXCL|O_NOFOLLOW`, only ever under
// `<store>/archives/`), every file swept as it is written (`ExportSweep`), then the whole archive swept again — it must find
// nothing, or the archive fails —, then `manifest.json`, then every file hashed again through the folder's descriptor, then
// renamed into place. A failure removes the partial (Dozable's own) and nothing else. No program is run to build it (git
// included: the timesheet says commits are not collected). `RunArchiveTests`; `docs/engineering/workspaces.md` ("The archive").
//
// What it holds: `manifest.json` (`{run, workspace, window, versions, rooms {name: id}, labels, notes, sweep, files [{path,
// sha256, sourceSHA256?, bytes}], messages}`), `run.json` (the run and the plan that was confirmed), `brief.md`,
// `chat/<room>.jsonl` (the slice `fromSeq < seq <= toSeq`) and `attachments/<room>/<id>/<name>`, `transcripts/<agent>/…`
// (each with its source's sha256), `screens/<agent>.txt`, `usage.json`, `timesheet.md`.

/// One transcript to archive: who, where it came from, its bytes as read (checked by `TranscriptCopy`'s rules) and their sha256.
public struct RunTranscript: Sendable {
    public var agent: String
    /// The name under `transcripts/<agent>/`.
    public var name: String
    /// `archive` (Dozable's kept copy), `carried` (a fenced session's copy in your folder), `conversation` (an unfenced
    /// session's recorded one), `sandbox` (copied out of its VM).
    public var source: String
    public var data: Data
    public var sourceSHA256: String
    /// The session it belongs to (a discard later names it) and the file's path at its source (never written to the archive).
    public var session: String?
    public var sourcePath: String?
    public init(agent: String, name: String, source: String, data: Data, session: String? = nil, sourcePath: String? = nil) {
        self.agent = agent; self.name = name; self.source = source; self.data = data; self.sourceSHA256 = TranscriptCopy.sha256(data)
        self.session = session; self.sourcePath = sourcePath
    }
}

/// Everything gathered for a run's archive.
public struct RunEvidence: Sendable {
    public var workspace: String
    public var run: WorkspaceRun
    public var endedAt: Date
    /// The confirmed plan (`run.json`), as JSON.
    public var plan: JSONValue?
    public var brief: Data
    public var rooms: [String: String]
    public var chat: [String: [JValue]]
    public var transcripts: [RunTranscript]
    public var screens: [String: String]
    /// Every agent of the run: name → role, and why it has nothing (not started, elsewhere, …).
    public var agents: [(name: String, role: String, note: String?)]
    public var notes: [String]
    public var you: String
    public var versions: [String: String]
    public init(workspace: String, run: WorkspaceRun, endedAt: Date, brief: Data) {
        self.workspace = workspace; self.run = run; self.endedAt = endedAt; self.brief = brief
        plan = nil; rooms = [:]; chat = [:]; transcripts = []; screens = [:]; agents = []; notes = []; you = "you"; versions = [:]
    }
}

public enum RunArchive {
    public struct File: Codable, Equatable, Sendable {
        public var path: String
        public var sha256: String
        public var sourceSHA256: String?
        public var bytes: Int
        /// A transcript's: whose and from where.
        public var agent: String?
        public var source: String?
        public var session: String?
    }

    public struct Sweep: Codable, Equatable, Sendable {
        public var at: Date
        public var findings: [ExportSweep.Finding]
        public var redacted: Int
    }

    /// `manifest.json` (version 1). Never a token.
    public struct Manifest: Codable, Equatable, Sendable {
        public var version = 1
        public var run: String
        public var workspace: String
        public var window: RunWindow
        public var versions: [String: String]
        public var rooms: [String: String]
        public var labels: [String: String]
        public var notes: [String]
        public var sweep: Sweep
        public var files: [File]
        /// Messages in the slice, by room.
        public var messages: [String: Int]
    }

    public static let gitNote = "commits: not collected — Dozable does not run git in a folder an agent writes"

    /// Writes the archive of `e` and answers its manifest, the manifest file's sha256 and its folder relative to the store.
    /// `verifySweep`: the second, whole-archive pass (the same sweep unless a test gives another).
    public static func write(_ e: RunEvidence, store: DozableStore, sweep: ExportSweep, verifySweep: ExportSweep? = nil,
                             fetch: ChatExport.Fetch?) throws -> (manifest: Manifest, sha256: String, path: String) {
        let place = try RunArchiveFolder(store: store, workspace: e.workspace, run: e.run.id)
        do {
            let out = try fill(place.folder, e, sweep: sweep, verifySweep: verifySweep ?? sweep, fetch: fetch)
            try place.finish()
            return (out.0, out.1, WorkspaceRuns.archivePath(workspace: e.workspace, run: e.run.id))
        } catch {
            place.discard()
            throw error
        }
    }

    static func fill(_ folder: ExportFolder, _ e: RunEvidence, sweep: ExportSweep, verifySweep: ExportSweep,
                     fetch: ChatExport.Fetch?) throws -> (Manifest, String) {
        var files: [File] = []
        var findings: [ExportSweep.Finding] = []
        func put(_ path: String, _ bytes: [UInt8], source: String? = nil, agent: String? = nil, from: String? = nil, session: String? = nil) throws {
            let c = sweep.clean(bytes, file: path)
            findings += c.findings
            let sha = try folder.write(path, c.bytes)
            files.append(File(path: path, sha256: sha, sourceSHA256: source, bytes: c.bytes.count, agent: agent, source: from, session: session))
        }
        // run.json: the run and the plan that was confirmed.
        var runJSON: [String: JSONValue] = ["run": try JSONValue(encoding: e.run)]
        if let p = e.plan { runJSON["plan"] = p }
        try put("run.json", Array(try HostWire.prettyEncoder.encode(runJSON)) + [0x0A])
        try put("brief.md", Array(e.brief))
        // The chat slice per room, and its attachments.
        var messages: [String: Int] = [:]
        for room in e.chat.keys.sorted() {
            let ms = e.chat[room] ?? []
            messages[room] = ms.count
            if let fetch {
                let w = try ChatExport.writeMessages(ms, room: room, jsonl: "chat/\(room).jsonl", attachments: "attachments/\(room)", into: folder,
                                                     sweep: sweep, fetch: fetch)
                findings += w.findings
                files += w.files.map { File(path: $0.path, sha256: $0.sha256, bytes: $0.bytes) }
            } else {
                var lines: [UInt8] = []
                for m in ms { lines += ChatJSON.encode(m) + [0x0A] }
                try put("chat/\(room).jsonl", lines)
            }
        }
        // Transcripts, each with its source's sha256.
        var byAgent: [String: [Data]] = [:]
        var names = Set<String>()
        for t in e.transcripts {
            var rel = "transcripts/\(t.agent)/\(t.name)"
            var k = 2
            while names.contains(rel) { rel = "transcripts/\(t.agent)/\(k)-\(t.name)"; k += 1 }
            names.insert(rel)
            try put(rel, Array(t.data), source: t.sourceSHA256, agent: t.agent, from: t.source, session: t.session)
            byAgent[t.agent, default: []].append(Data(try folder.read(rel)))
        }
        for (agent, text) in e.screens.sorted(by: { $0.key < $1.key }) { try put("screens/\(agent).txt", Array(text.utf8)) }
        // Usage and the timesheet, from the archived copies.
        let window = RunWindow(from: e.run.startedAt, to: e.endedAt)
        var agents: [TranscriptUsage.Agent] = []
        for a in e.agents {
            var u = TranscriptUsage.agent(a.name, role: a.role, files: byAgent[a.name] ?? [], since: e.run.startedAt, until: e.endedAt)
            if (byAgent[a.name] ?? []).isEmpty { u.note = a.note ?? "no conversation kept" }
            agents.append(u)
        }
        let usage = TranscriptUsage.report(run: e.run.id, window: window, agents: agents)
        try put("usage.json", Array(try HostWire.prettyEncoder.encode(usage)) + [0x0A])
        var yours: [String: Int] = [:]
        for (room, ms) in e.chat { yours[room] = ms.filter { $0.field("from")?.stringValue == e.you && ($0.field("kind")?.stringValue ?? "").isEmpty }.count }
        try put("timesheet.md", Array(Timesheet.markdown(.init(workspace: e.workspace, run: e.run.id, window: window, usage: usage, you: e.you,
                                                                 yourMessages: yours)).utf8))
        // The whole archive swept again: it must find nothing, and every file must still be what was written.
        var second = 0
        for f in files {
            let back = try folder.read(f.path)
            guard sha(back) == f.sha256 else { throw HostError(.failed, "\(f.path) changed while the archive was written") }
            second += verifySweep.clean(back, file: f.path).findings.count
        }
        if second > 0 { throw HostError(.failed, "the archive's second sweep found \(second) secret\(second == 1 ? "" : "s") — it was not kept") }
        let manifest = Manifest(run: e.run.id, workspace: e.workspace, window: window, versions: e.versions, rooms: e.rooms, labels: [:],
                                notes: e.notes + [gitNote], sweep: Sweep(at: Date(), findings: findings, redacted: findings.count),
                                files: files.sorted { $0.path < $1.path }, messages: messages)
        let mbytes = Array(try HostWire.prettyEncoder.encode(manifest)) + [0x0A]
        guard verifySweep.clean(mbytes, file: "manifest.json").findings.isEmpty else { throw HostError(.failed, "the manifest holds a secret — not kept") }
        let msha = try folder.write("manifest.json", mbytes)
        // Every file hashed again through the folder's descriptor, now that the manifest names them.
        let check = verify(folder)
        guard check.problems.isEmpty else { throw HostError(.failed, "the archive did not verify: " + check.problems.prefix(3).joined(separator: "; ")) }
        return (manifest, msha)
    }

    /// A room's whole history archived (`doz chat room archive`): `chat/<room>.jsonl`, its attachments and `manifest.json`,
    /// swept, swept again, verified and put in place. Answers the manifest, its sha256 and the folder relative to the store.
    public static func writeRoom(room: String, id: String, owner: String?, messages ms: [JValue], store: DozableStore, sweep: ExportSweep,
                                 fetch: @escaping ChatExport.Fetch) throws -> (manifest: Manifest, sha256: String, path: String) {
        let place = try RunArchiveFolder(store: store, owner: owner, room: room, id: id)
        do {
            let folder = place.folder
            let w = try ChatExport.writeMessages(ms, room: room, jsonl: "chat/\(room).jsonl", attachments: "attachments/\(room)", into: folder,
                                                 sweep: sweep, fetch: fetch)
            let files = w.files.map { File(path: $0.path, sha256: $0.sha256, bytes: $0.bytes) }
            var second = 0
            for f in files {
                let back = try folder.read(f.path)
                guard sha(back) == f.sha256 else { throw HostError(.failed, "\(f.path) changed while the archive was written") }
                second += sweep.clean(back, file: f.path).findings.count
            }
            if second > 0 { throw HostError(.failed, "the archive's second sweep found \(second) secret\(second == 1 ? "" : "s") — it was not kept") }
            let at = ms.compactMap { $0.field("at")?.doubleValue }
            let window = RunWindow(from: Date(timeIntervalSince1970: at.min() ?? Date().timeIntervalSince1970),
                                   to: Date(timeIntervalSince1970: at.max() ?? Date().timeIntervalSince1970))
            let lastSeq = ms.compactMap { (try? $0.field("seq")?.goInt("seq")) ?? nil }.max() ?? 0
            let m = Manifest(run: "room", workspace: owner ?? "_", window: window, versions: [:], rooms: [room: id], labels: [:],
                             notes: ["the room's whole history, up to its last message \(lastSeq)"],
                             sweep: Sweep(at: Date(), findings: w.findings, redacted: w.findings.count), files: files.sorted { $0.path < $1.path },
                             messages: [room: ms.count])
            let msha = try folder.write("manifest.json", Array(try HostWire.prettyEncoder.encode(m)) + [0x0A])
            let check = verify(folder)
            guard check.problems.isEmpty else { throw HostError(.failed, "the archive did not verify: " + check.problems.prefix(3).joined(separator: "; ")) }
            try place.finish()
            return (m, msha, "archives/\(owner ?? "_")/rooms/\(room)-\(id)")
        } catch {
            place.discard()
            throw error
        }
    }

    public static func sha(_ b: [UInt8]) -> String { SHA256.hash(data: b).map { String(format: "%02x", $0) }.joined() }

    public struct Verified: Equatable, Sendable {
        public var manifest: Manifest?
        public var manifestSHA256: String?
        public var problems: [String]
        public var ok: Bool { problems.isEmpty && manifest != nil }
    }

    /// The archive at `root` (absolute) checked now: its manifest read, every file it names hashed again (no link followed).
    public static func verify(root: String) -> Verified {
        let fd = open(root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return Verified(problems: ["\(DisplayPath.tilde(root)) is not there"]) }
        return verify(ExportFolder(adopting: fd, path: root))
    }

    static func verify(_ folder: ExportFolder) -> Verified {
        guard let m = try? folder.read("manifest.json", maximum: 64 << 20) else { return Verified(problems: ["no manifest.json"]) }
        guard let manifest = try? HostWire.decoder.decode(Manifest.self, from: Data(m)) else { return Verified(problems: ["manifest.json cannot be read"]) }
        var problems: [String] = []
        for f in manifest.files {
            guard let b = try? folder.read(f.path) else { problems.append("\(f.path) is missing"); continue }
            if sha(b) != f.sha256 || b.count != f.bytes { problems.append("\(f.path) changed since it was archived") }
        }
        return Verified(manifest: manifest, manifestSHA256: sha(m), problems: problems)
    }
}

/// `<store>/archives/<workspace>/runs/<run>.partial/` made and opened with no link anywhere in its path — the only place
/// an archive is written — then renamed to `<run>` (never over one), or removed.
final class RunArchiveFolder {
    let runsFD: Int32
    let run: String
    let folder: ExportFolder
    private var done = false

    convenience init(store: DozableStore, workspace: String, run: String) throws {
        try WorkspaceName.validate(workspace)
        guard WorkspaceRuns.isValidID(run) else { throw HostError(.invalid, "\(run) is not a run's id") }
        try self.init(store: store, parts: [workspace, "runs"], name: run, what: "run \(run)")
    }

    /// A room's archive: `<store>/archives/<owner, or _ for a loose room>/rooms/<room>-<id>/`.
    convenience init(store: DozableStore, owner: String?, room: String, id: String) throws {
        if let owner { try WorkspaceName.validate(owner) }
        guard chatIsRoomName(room), ChatRoomIndex.isID(id) else { throw HostError(.invalid, "\(room) is not a room's name") }
        try self.init(store: store, parts: [owner ?? "_", "rooms"], name: room + "-" + id, what: "the room \(room)")
    }

    init(store: DozableStore, parts: [String], name run: String, what: String) throws {
        let root = WorkspaceStore.resolved(store.root.path)
        var dir = open(root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard dir >= 0 else { throw HostError(.failed, "the store cannot be opened: \(String(cString: strerror(errno)))") }
        for p in ["archives"] + parts {
            if mkdirat(dir, p, 0o700) != 0 && errno != EEXIST { let e = errno; close(dir); throw HostError(.failed, "archives: \(String(cString: strerror(e)))") }
            let next = openat(dir, p, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(dir)
            guard next >= 0 else { throw HostError(.failed, "\(p) in the archives is not a folder of Dozable's (a link is never followed)") }
            var st = stat()
            guard fstat(next, &st) == 0, st.st_uid == getuid() else { close(next); throw HostError(.failed, "\(p) in the archives is not yours") }
            if st.st_mode & 0o777 != 0o700 { fchmod(next, 0o700) }
            dir = next
        }
        runsFD = dir
        self.run = run
        var st = stat()
        if fstatat(dir, run, &st, AT_SYMLINK_NOFOLLOW) == 0 {
            close(dir)
            throw HostError(.exists, "the archive of \(what) is written already")
        }
        // A partial left by an earlier attempt is Dozable's own: removed.
        if fstatat(dir, run + ".partial", &st, AT_SYMLINK_NOFOLLOW) == 0 { Self.removeTree(dir, run + ".partial") }
        guard mkdirat(dir, run + ".partial", 0o700) == 0 else {
            let e = errno; close(dir); throw HostError(.failed, "the archive of run \(run) cannot be made: \(String(cString: strerror(e)))")
        }
        let p = openat(dir, run + ".partial", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard p >= 0 else { close(dir); throw HostError(.failed, "the archive of run \(run) cannot be opened") }
        folder = ExportFolder(adopting: p, path: root + "/archives/" + parts.joined(separator: "/") + "/\(run).partial")
    }

    deinit { close(runsFD) }

    /// The partial becomes the archive (never over an existing one).
    func finish() throws {
        guard renameatx_np(runsFD, run + ".partial", runsFD, run, UInt32(RENAME_EXCL)) == 0 else {
            throw HostError(.failed, "the archive of run \(run) could not be put in place: \(String(cString: strerror(errno)))")
        }
        done = true
    }

    /// The partial removed (Dozable's own, made by this attempt).
    func discard() {
        guard !done else { return }
        Self.removeTree(runsFD, run + ".partial")
    }

    /// `name` under `dir` removed, its contents first — through descriptors, a link removed as itself and never followed.
    static func removeTree(_ dir: Int32, _ name: String) {
        let fd = openat(dir, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 { unlinkat(dir, name, 0); return }
        if let d = fdopendir(dup(fd)) {
            var names: [String] = []
            while let e = readdir(d) {
                let n = withUnsafeBytes(of: e.pointee.d_name) { String(decoding: $0.prefix(Int(e.pointee.d_namlen)), as: UTF8.self) }
                if n != "." && n != ".." { names.append(n) }
            }
            closedir(d)
            for n in names {
                var st = stat()
                if fstatat(fd, n, &st, AT_SYMLINK_NOFOLLOW) == 0, (st.st_mode & S_IFMT) == S_IFDIR { removeTree(fd, n) } else { unlinkat(fd, n, 0) }
            }
        }
        close(fd)
        unlinkat(dir, name, AT_REMOVEDIR)
    }
}
