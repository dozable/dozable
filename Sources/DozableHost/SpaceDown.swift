import CryptoKit
import Darwin
import DozableChat
import Foundation

// `down`'s plan, pure: from the record a space file made (its `space` reference), what `doz workspace down` — and with
// `--purge` what also persists — would do, each step `run` or `skip`, the content-bearing things that go with NO copy
// (`archive: off` only, named in the plan and the confirmation), and a sha over what is done to what (never a time).
// The daemon's `workspace-down` acts only on the plan the person saw (`ifPlan`). docs/engineering/workspaces.md
// ("Space files"); `SpaceDownPlanTests`.

public struct SpaceDownPlan: Codable, Equatable, Sendable {
    public struct Step: Codable, Equatable, Sendable {
        public var n: Int
        /// `finish`, `memory`, `worker-end`, `release`, `room-rm`, `scratch-rm`, `memory-rm`, `folder-release`, `record`.
        public var kind: String
        public var subject: String
        public var action: String
        public var text: String
        public var why: String?
        /// What it removes for good, and whether a hash-checked copy is made first (`archived`) or none (`none`).
        public var copy: String?
    }
    public var space: String
    public var purge: Bool
    /// A run is open: down ends it.
    public var up: Bool
    public var run: String?
    public var steps: [Step] = []
    public var summary: [String] = []
    /// `archive: off`: what goes with no copy.
    public var noCopy: [String] = []
    public var refusals: [String] = []
    public var refusalCode: String?
    public var notes: [String] = []
    public var sha: String = ""
}

public enum SpaceDown {
    /// The plan for `rec` (made by a space file). Pure.
    public static func plan(_ rec: WorkspaceRecord?, space: String, purge: Bool) -> SpaceDownPlan {
        var p = SpaceDownPlan(space: space, purge: purge, up: false)
        guard let rec else {
            p.refusals = ["\(space) is not a workspace (doz workspace ls)"]
            p.refusalCode = HostError.Code.notFound.rawValue
            p.sha = sha(p)
            return p
        }
        guard let ref = SpaceRecordRef.of(rec) else {
            p.refusals = ["\(space) was made without a space file: down takes down only what a space file made (doz workspace finish \(space))"]
            p.refusalCode = HostError.Code.exists.rawValue
            p.sha = sha(p)
            return p
        }
        if rec.flags.archivedAt != nil {
            p.refusals = ["\(space) is archived"]
            p.refusalCode = HostError.Code.invalidPhase.rawValue
        }
        let owned = ref.owned ?? SpaceRecordRef.Owned()
        let off = ref.archiveOff == true
        var steps: [SpaceDownPlan.Step] = []
        func step(_ kind: String, _ subject: String, _ text: String, action: String = "run", why: String? = nil, copy: String? = nil) {
            steps.append(.init(n: steps.count + 1, kind: kind, subject: subject, action: action, text: text, why: why, copy: copy))
        }
        let open = rec.openRun
        p.up = open != nil && rec.flags.finishedAt == nil
        p.run = open?.id ?? rec.runs.last?.id
        let live = rec.agents.filter { $0.endedAt == nil }
        let roomCopy = off ? "none" : "archived"
        if p.up {
            step("finish", "run \(open!.id)", "end the run \(open!.id): its rooms closed, every agent stopped, "
                 + (off ? "no archive (archive: off)" : "its archive written and hash-checked") + ", the run closed")
            for a in live where owned.agents[a.name] == "persisted" && a.isolation == "fenced" {
                step("memory", "agent \(a.name)", "keep \(a.name)'s memory for its next fenced session (in the store)")
            }
            for a in live where a.isWorker && owned.agents[a.name] == "run" {
                let discard = ref.transcripts?[a.name] == "discard"
                step("worker-end", "agent \(a.name)", "end and forget \(a.name)" + (a.place.sandbox.map { owned.sandboxes[$0] == "run" ? "; its sandbox \($0) removed" : "" } ?? "")
                     + (discard ? (off ? "; its transcripts deleted with no copy (archive: off)" : "; its transcripts deleted once the archived copy is hash-checked") : ""),
                     copy: discard ? (off ? "none" : "archived") : nil)
                if discard && off { p.noCopy.append("\(a.name)'s transcripts") }
            }
            for a in live where a.isWorker && owned.agents[a.name] == nil && a.bot != nil {
                step("worker-end", "agent \(a.name)", "end \(a.name) (the bot keeps its token)")
            }
            for a in live where !a.isWorker && !a.isManager {
                step("release", "agent \(a.name)", "release \(a.name) (loose again)")
            }
            for s in ref.scratch ?? [] where s.run == open!.id {
                step("scratch-rm", "folder \(s.name)", "remove the scratch folder \(DisplayPath.tilde(s.path))" + (off ? " with no copy (archive: off)" : ", copied into the archive and hash-checked first"),
                     copy: off ? "none" : "archived")
                if off { p.noCopy.append("the scratch folder \(s.name)") }
            }
        }
        // The run-lifetime rooms (also those a down that failed half-way left behind).
        for r in rec.rooms where r.goneAt == nil && r.owned != false && owned.rooms[r.chatRoom] == "run" {
            step("room-rm", "room \(r.chatRoom)", "delete the room \(r.chatRoom)" + (off ? " with no copy (archive: off)" : ", archived and hash-checked first") + "; a tombstone stays",
                 copy: roomCopy)
            if off { p.noCopy.append("the room \(r.chatRoom)") }
        }
        if !p.up {
            for s in ref.scratch ?? [] where s.run != open?.id {
                step("scratch-rm", "folder \(s.name)", "remove the scratch folder \(DisplayPath.tilde(s.path)) left from run \(s.run)" + (off ? " with no copy (archive: off)" : ", copied and hash-checked first"),
                     copy: off ? "none" : "archived")
            }
        }
        if purge {
            for a in live where owned.agents[a.name] == "persisted" {
                step("worker-end", "agent \(a.name)", "end and forget \(a.name), its kept conversation and memory deleted")
            }
            for (agent, _) in (ref.memoryIsolation ?? [:]).sorted(by: { $0.key < $1.key }) {
                step("memory-rm", "agent \(agent)", "delete \(agent)'s kept memory (in the store)")
            }
            for (s, life) in owned.sandboxes.sorted(by: { $0.key < $1.key }) where life == "persisted" {
                step("sandbox-rm", "sandbox \(s)", "remove the sandbox \(s) and its disk")
            }
            for r in rec.rooms where r.goneAt == nil && r.owned != false && owned.rooms[r.chatRoom] == "persisted" {
                step("room-rm", "room \(r.chatRoom)", "delete the persisted room \(r.chatRoom)" + (off ? " with no copy (archive: off)" : ", archived and hash-checked first") + "; a tombstone stays",
                     copy: roomCopy)
                if off { p.noCopy.append("the room \(r.chatRoom)") }
            }
            for path in ref.persistedPaths ?? [] {
                step("folder-release", "folder \(path)", "release the folder \(DisplayPath.tilde(path)) (off the record; never deleted)")
            }
        }
        if !steps.isEmpty || purge { step("record", "workspace \(space)", purge ? "record the space retired (--purge)" : "record the space down") }
        p.steps = steps
        if steps.isEmpty { p.notes.append("\(space) is down already: nothing to take down") }
        p.summary.append(p.up ? "Down ends run \(open!.id)" + (off ? " with no archive (archive: off, from \(ref.provenance?["/archive"] ?? ref.file ?? "the space file"))." : ", archived in the store before anything is removed.")
                         : "No run is open.")
        if !p.noCopy.isEmpty { p.summary.append("Deleted with no copy (archive: off): " + p.noCopy.joined(separator: ", ") + ".") }
        p.summary.append("Never touched: the space's external folders, rooms, sandboxes and bots; a persisted folder is never deleted.")
        p.sha = sha(p)
        return p
    }

    static func sha(_ p: SpaceDownPlan) -> String {
        var parts = ["space=\(p.space)", "purge=\(p.purge)", "up=\(p.up)", "run=\(p.run ?? "")"]
        for s in p.steps { parts.append("\(s.kind)|\(s.subject)|\(s.action)|\(s.copy ?? "")") }
        parts += p.refusals.map { "refusal=\($0)" }
        return SHA256.hash(data: Data(parts.joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// `workspace-down-plan` / `workspace-down`'s arguments.
public struct SpaceDownRequest: Codable, Equatable, Sendable {
    public var workspace: String
    public var purge: Bool?
    /// down: the plan's sha as the person saw it (changed since → refused, nothing done).
    public var ifPlan: String?
    public init(workspace: String, purge: Bool? = nil, ifPlan: String? = nil) { self.workspace = workspace; self.purge = purge; self.ifPlan = ifPlan }
}

extension RunArchive {
    /// A scratch folder copied into `<store>/archives/<workspace>/folders/<run>/<name>/` before it is removed: every regular
    /// file (no link followed, at most 256 MiB and 10,000 files — more refuses the copy, and the folder is kept), swept,
    /// hashed, the manifest written and every file hashed again. Answers the copy's folder relative to the store.
    public static func writeFolder(source: String, name: String, workspace: String, run: String, store: DozableStore, sweep: ExportSweep) throws -> String {
        try WorkspaceName.validate(workspace)
        guard WorkspaceRuns.isValidID(run), WorkspaceName.isValidAgent(name) || WorkspaceName.isValid(name) else { throw HostError(.invalid, "not a scratch folder's name") }
        var items: [(rel: String, data: Data)] = []
        var total = 0
        var problem: String?
        let ok = MacFenceHostFS.walk(source, maximum: 20_000, maxDepth: 32) { path, mode in
            guard problem == nil else { return false }
            if mode == S_IFDIR { return true }
            if mode == S_IFLNK { problem = "\(DisplayPath.tilde(path)) is a link — not followed, and not copied"; return false }
            guard mode == S_IFREG else { return false }
            guard items.count < 10_000 else { problem = "more than 10,000 files"; return false }
            do {
                let d = try MacFenceHostFS.readRegular(path, maximum: 256 << 20)
                total += d.count
                if total > 256 << 20 { problem = "more than 256 MiB"; return false }
                items.append((String(path.dropFirst(source.count + 1)), d))
            } catch { problem = "\(error)" }
            return false
        }
        if !ok { problem = problem ?? "too many entries" }
        if let problem { throw HostError(.failed, "the scratch folder \(name) was not copied (\(problem)) — it is kept") }
        let place = try RunArchiveFolder(store: store, parts: [workspace, "folders", run], name: name, what: "the scratch folder \(name)")
        do {
            let folder = place.folder
            var files: [File] = []
            var findings: [ExportSweep.Finding] = []
            for it in items {
                let c = sweep.clean(Array(it.data), file: it.rel)
                findings += c.findings
                let rel = "files/" + it.rel
                let sha = try folder.write(rel, c.bytes)
                files.append(File(path: rel, sha256: sha, sourceSHA256: WorkspaceStore.sha256(it.data), bytes: c.bytes.count, agent: nil, source: "scratch", session: nil))
            }
            let now = Date()
            let m = Manifest(run: run, workspace: workspace, window: RunWindow(from: now, to: now), versions: [:], rooms: [:], labels: ["folder": name],
                             notes: ["the scratch folder \(name) of run \(run), copied before it was removed"],
                             sweep: Sweep(at: now, findings: findings, redacted: findings.count), files: files.sorted { $0.path < $1.path }, messages: [:])
            _ = try folder.write("manifest.json", Array(try HostWire.prettyEncoder.encode(m)) + [0x0A])
            let check = verify(folder)
            guard check.problems.isEmpty else { throw HostError(.failed, "the copy did not verify: " + check.problems.prefix(3).joined(separator: "; ")) }
            try place.finish()
            return "archives/\(workspace)/folders/\(run)/\(name)"
        } catch {
            place.discard()
            throw error
        }
    }
}
