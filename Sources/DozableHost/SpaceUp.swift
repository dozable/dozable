import CryptoKit
import DozableChat
import Foundation

// `up`'s plan, pure: from what the file asks (`SpaceIntent`), the workspace's record (if one has the space's name) and
// the facts the daemon gathered, the steps `up` would run — each `run`, `skip` (already there) or `refuse` — with what
// `down` will do to each, the summary (every risky setting with its file and line), the agents a person must confirm
// (every unfenced one, wherever the setting came from: inheriting never pre-approves) and a sha over all of it. Nothing
// here acts: `workspace-up-plan` answers it, `doz workspace plan -f` and `up --dry-run` print it.
// docs/engineering/workspaces.md, "Space files".

/// The record's reference to the space file that made it (`workspace.json`'s `space`, additive: an older doz keeps it as
/// an unknown field). `up` writes it; `down` and `--purge` act only on what it names as the space's own.
public struct SpaceRecordRef: Codable, Equatable, Sendable {
    /// What the space owns, by its name in the file: `run` (this run only) or `persisted`.
    public struct Owned: Codable, Equatable, Sendable {
        public var agents: [String: String] = [:]
        public var rooms: [String: String] = [:]
        public var sandboxes: [String: String] = [:]
        public var folders: [String: String] = [:]
        public init() {}
    }
    /// A scratch folder `up` made for a run (`<projects_dir>/.runs/<space>/<run>/<name>`): the only kind `down` removes,
    /// and only when it is recorded here.
    public struct Scratch: Codable, Equatable, Sendable {
        public var run: String
        public var name: String
        public var path: String
        public init(run: String, name: String, path: String) { self.run = run; self.name = name; self.path = path }
    }
    /// The space file's name, its path and the merged spec's sha256. The daemon never plans from the path: it opens it only
    /// to read and save the file (`workspace-space`, `-space-save`), under `SpaceRecordFile`'s rules.
    public var file: String?
    public var path: String?
    public var sha256: String?
    public var title: String?
    public var sources: [SpaceSource]?
    /// JSON pointer → `FILE:LINE`, for the values that did not come from the space file itself.
    public var provenance: [String: String]?
    /// The brief: the file the space names (the daemon reads it under `SpaceBriefFile`'s rules), its sha256 at the last up.
    public var brief: SpaceBriefLook?
    public var owned: Owned?
    /// 756: `x-dozable.lifetime` at the last up (nil: none — `runs`): `standing` keeps everything it owns at down (its
    /// scratch folders too), but what `runLifetime` names (`kind:name`, its own `x-dozable.lifetime: run`).
    public var lifetime: String?
    public var runLifetime: [String]?
    /// Standing: its finish removes nothing of its own but what says `lifetime: run`.
    public var isStanding: Bool { lifetime == "standing" }
    /// What `kind:name` lives as at down: as recorded (`run` or `persisted`; nil: not the space's own) — or, standing,
    /// `persisted` unless it says `lifetime: run` itself.
    public func effective(_ kind: String, _ name: String, recorded: String?) -> String? {
        guard let recorded else { return nil }
        guard isStanding else { return recorded }
        return (runLifetime ?? []).contains(kind + ":" + name) ? "run" : "persisted"
    }
    /// A scratch folder `name` goes at down: always in `runs`; standing, only when it says `lifetime: run` itself.
    public func scratchGoes(_ name: String) -> Bool { !isStanding || (runLifetime ?? []).contains("folder:" + name) }
    /// `archive: off` (down keeps no copy) and the archive's `keep:` list.
    public var archiveOff: Bool?
    public var archiveKeep: [String]?
    /// Agent → `discard` (its transcripts deleted at down once their archived copy, or the hashes-only ledger, matches).
    public var transcripts: [String: String]?
    public var scratch: [Scratch]?
    /// Persisted `{folder: PATH}` folders `up` made (never deleted; `--purge` releases them).
    public var persistedPaths: [String]?
    /// Persisted agents' isolation at the last up (776: a switch fenced ↔ unfenced keeps the kept memory, and says so).
    public var memoryIsolation: [String: String]?
    public var planSHA: String?
    public var upAt: Date?
    public var downAt: Date?
    public var purgedAt: Date?
    public init() {}
    /// The record's `space`, if it has one.
    public static func of(_ rec: WorkspaceRecord) -> SpaceRecordRef? {
        guard let v = rec.unknown.extra["space"] else { return nil }
        return try? v.decode(SpaceRecordRef.self)
    }
    /// Written into the record (kept by an older doz as an unknown field).
    public func store(in rec: inout WorkspaceRecord) {
        if let v = try? JSONValue(encoding: self) { rec.unknown.extra["space"] = v }
    }
    /// 762 (F1b): a workspace's lifetime as `show` and `ls` carry it: a space file's as recorded at up (none: `runs`); one made
    /// without a space file is `standing` (its finish removes nothing).
    public static func lifetime(of rec: WorkspaceRecord) -> String {
        guard let ref = of(rec) else { return "standing" }
        return ref.lifetime ?? SpaceDozable.defaultLifetime
    }
    /// Up when the last up is later than the last down.
    public var isUp: Bool { guard let u = upAt else { return false }; return downAt.map { u > $0 } ?? true }
}

/// What the daemon knows when it plans. `known` false: answered with no daemon — what only a running daemon knows (a
/// session or a manager running, the chat server's rooms) is "not known", and nothing is refused for it.
public struct SpaceFacts: Sendable {
    public struct Bot: Sendable {
        public var exists: Bool
        public var retired: Bool
        public var holdsToken: Bool
        /// The other live workspace it runs in (nil: none, or not known).
        public var liveElsewhere: String?
        public init(exists: Bool, retired: Bool = false, holdsToken: Bool = true, liveElsewhere: String? = nil) {
            self.exists = exists; self.retired = retired; self.holdsToken = holdsToken; self.liveElsewhere = liveElsewhere
        }
    }
    public var known: Bool
    public var home: String
    /// `defaults.projects_dir`.
    public var projectsDir: String
    /// This Mac's owner as the chat server knows it (nil: chat has no one yet).
    public var owner: String?
    public var chatOn: Bool
    /// The workspace with the space's name, if one exists.
    public var record: WorkspaceRecord?
    public var bots: [String: Bot] = [:]
    /// Sessions on this Mac by name: true running, false recorded but not running (nil: not recorded).
    public var sessions: [String: Bool] = [:]
    /// The chat server's rooms (nil: not known), and the room index's rooms and tombstones.
    public var rooms: Set<String>?
    public var indexedRooms: Set<String> = []
    public var goneRooms: Set<String> = []
    /// Existing paths, after `~` (the daemon looks; it opens nothing).
    public var folders: [String: Bool] = [:]
    public var sandboxes: Set<String> = []
    public var brief: SpaceBriefLook?

    public init(known: Bool, home: String, projectsDir: String, owner: String? = nil, chatOn: Bool = true, record: WorkspaceRecord? = nil) {
        self.known = known; self.home = home; self.projectsDir = projectsDir; self.owner = owner; self.chatOn = chatOn; self.record = record
    }

    public func expand(_ p: String) -> String {
        p == "~" ? home : p.hasPrefix("~/") ? home + String(p.dropFirst(1)) : p
    }
}

/// `workspace-up-plan`'s answer.
public struct SpacePlan: Codable, Equatable, Sendable {
    public struct Step: Codable, Equatable, Sendable {
        public var n: Int
        /// `check`, `workspace-new`, `workspace-edit`, `workspace-reopen`, `room`, `folder`, `workspace-start`,
        /// `workspace-adopt`, `worker-add`, `requests`.
        public var kind: String
        public var subject: String
        /// `run`, `skip` (already there, or not known now) or `refuse`.
        public var action: String
        /// `external`, `persisted` or `run`.
        public var lifetime: String
        public var text: String
        public var why: String?
        /// What `down` will do to it.
        public var down: String?
        /// The HostOp `up` sends for it, if it is one.
        public var op: String?
        /// worker-add's request (never a token: a worker's token is made by the daemon).
        public var worker: WorkerRequest?
        /// worker-add's permission mode (`bypass`: in the worker's own argv, marked).
        public var permissionMode: String?
    }
    public var space: String
    public var title: String
    public var specPath: String?
    public var specSHA: String
    public var sources: [SpaceSource]
    /// Answered with a daemon: everything below is known; without one, what only a daemon knows is marked "not known".
    public var factsKnown: Bool
    public var problems: [SpaceProblem] = []
    public var steps: [Step] = []
    public var summary: [String] = []
    public var risks: [SpaceRisk] = []
    /// The owned agents `up` asks a person to confirm: every unfenced one.
    public var confirm: [String] = []
    public var refusals: [String] = []
    /// The first refusal's code (`HostError.Code`), or `invalid` for an error in the file; nil: `up` could run.
    public var refusalCode: String?
    public var notes: [String] = []
    public var sha: String = ""
    public var intent: SpaceIntent?
    /// 774: one agent as the plan places it: its name, where it runs (a place's name, a sandbox's, or `mac`), its isolation.
    public struct PlacedAgent: Codable, Equatable, Sendable {
        public var name: String
        public var `where`: String
        public var isolation: String?
        public var external: Bool
        public init(name: String, where w: String, isolation: String?, external: Bool) {
            self.name = name; self.where = w; self.isolation = isolation; self.external = external
        }
    }
    /// 774: the places (`WorkspacePlace`: name, isolation, external, view, network, credentials) and the agents' places.
    /// Optional: an older daemon's plan has neither.
    public var places: [WorkspacePlace]?
    public var agents: [PlacedAgent]?
    public init(space: String, title: String, specPath: String?, specSHA: String, sources: [SpaceSource], factsKnown: Bool) {
        self.space = space; self.title = title; self.specPath = specPath; self.specSHA = specSHA; self.sources = sources; self.factsKnown = factsKnown
    }
}

public enum SpaceUp {
    /// An agent's task when the file gives it no prompt.
    public static let defaultTask = "Read the brief (BRIEF.md beside the space file, posted in the room) and do the work it describes."

    /// The folders the space keeps across runs: an owned folder named by `persist:` (`<projects_dir>/<space>/<name>`) and a
    /// `persist: { folder: PATH }`. Absolute, `~` expanded.
    public static func keptFolderPaths(_ i: SpaceIntent, _ f: SpaceFacts) -> [(name: String, path: String, source: String)] {
        var out: [(String, String, String)] = []
        for x in i.folders where x.path == nil {
            if let p = x.persisted { out.append((x.name, (f.projectsDir as NSString).appendingPathComponent("\(i.space)/\(x.name)"), p.source)) }
        }
        for x in i.persistedPaths { out.append((x.value, f.expand(x.value), x.source)) }
        return out
    }

    /// The plan for `intent` (from a document whose sha256 is `specSHA`), given the facts. `prompts`: the owned agents'
    /// `prompt_file` texts, read by the CLI. Pure.
    /// `noRun` (765, `up --no-run`): its agents start, no run opens.
    public static func plan(_ i: SpaceIntent, facts f: SpaceFacts, specSHA: String, sources: [SpaceSource], specPath: String? = nil,
                            prompts: [String: String] = [:], noRun: Bool = false) -> SpacePlan {
        var p = SpacePlan(space: i.space, title: i.title, specPath: specPath, specSHA: specSHA, sources: sources, factsKnown: f.known)
        p.intent = i
        p.places = i.places ?? []
        p.agents = i.agents.map { a -> SpacePlan.PlacedAgent in
            let session: String? = a.session.map { MacPlace.name + "/" + $0 }
            let bot: String? = a.bot.map { "bot:" + $0 }
            let w: String = a.place ?? a.sandbox ?? session ?? bot ?? "mac"
            return SpacePlan.PlacedAgent(name: a.name, where: w, isolation: a.isolation?.value, external: a.external)
        }
        p.risks = i.risks
        p.confirm = i.unfenced
        var steps: [SpacePlan.Step] = []
        var refusals: [(String, HostError.Code)] = i.refusals.map { ($0.message, HostError.Code(rawValue: $0.code) ?? .invalid) }
        func step(_ kind: String, _ subject: String, _ lifetime: String, _ text: String, action: String = "run", why: String? = nil,
                  down: String? = nil, op: HostOp? = nil) {
            steps.append(.init(n: steps.count + 1, kind: kind, subject: subject, action: action, lifetime: lifetime, text: text, why: why, down: down, op: op?.rawValue))
        }
        func refuse(_ m: String, _ c: HostError.Code) { refusals.append((m, c)) }
        let rec = f.record
        let ref = rec.flatMap { SpaceRecordRef.of($0) }
        let openRun = rec?.openRun
        let unknown = "not known with no daemon running"

        // The owner: the person deciding must be this Mac's owner.
        if let o = f.owner, o != i.owner {
            refuse("owner: \(i.owner) is not this Mac's owner — the chat server knows you as \(o)", .invalid)
        } else if f.owner == nil {
            p.notes.append("owner: \(i.owner) — chat has no one yet, so it is not checked")
        }

        // 1. The external things: each must exist as declared, or up stops before changing anything.
        for x in i.folders where x.path != nil {
            let path = f.expand(x.path!)
            let exists = f.folders[path] ?? false
            if exists || x.optional {
                step("check", "folder \(x.name)", "external", "folder \(x.name) exists (\(DisplayPath.tilde(path)))",
                     action: exists ? "run" : "skip", why: exists ? nil : "optional and missing: left out", down: "never touched")
            } else {
                step("check", "folder \(x.name)", "external", "folder \(x.name) exists (\(DisplayPath.tilde(path)))", action: "refuse",
                     why: "\(DisplayPath.tilde(path)) doesn't exist", down: "never touched")
                refuse("folder \(x.name): \(DisplayPath.tilde(path)) doesn't exist", .notFound)
            }
        }
        for a in i.agents where a.external {
            if let b = a.bot {
                let fact = f.bots[b]
                var action = "run", why: String?
                if fact?.exists != true { action = "refuse"; why = "no Agent / Bot \(b) on this Mac (doz bot ls)"; refuse("agent \(a.name): \(why!)", .notFound) }
                else if fact?.retired == true { action = "refuse"; why = "\(b) is retired"; refuse("agent \(a.name): \(b) is retired", .invalidPhase) }
                else if let other = fact?.liveElsewhere {
                    action = "refuse"; why = "\(b) already runs in \(other) — a bot runs in one live workspace at a time"
                    refuse("agent \(a.name): \(why!)", .exists)
                } else if !f.known { why = "whether it runs in another workspace is \(unknown)" }
                step("check", "agent \(a.name)", "external", "agent \(a.name) exists (Agent / Bot: \(b))", action: action, why: why, down: "never touched")
            } else if let s = a.session {
                let live = f.sessions[s]
                var action = "run", why: String?
                if live == nil { action = "refuse"; why = "no session \(s) on this Mac"; refuse("agent \(a.name): \(why!)", .notFound) }
                else if live == false && f.known { action = "refuse"; why = "session \(s) is not running"; refuse("agent \(a.name): \(why!)", .invalidPhase) }
                else if !f.known { why = "whether it runs is \(unknown)" }
                step("check", "agent \(a.name)", "external", "agent \(a.name) exists (session \(s) on this Mac, adopted)", action: action, why: why, down: "never touched")
            } else if let sb = a.sandbox {
                // 755: an agent in an existing sandbox (`x-dozable.external`): it must exist; adopted, never started.
                let ok = f.sandboxes.contains(sb)
                step("check", "agent \(a.name)", "external", "agent \(a.name) exists (the sandbox \(sb), adopted)", action: ok ? "run" : "refuse",
                     why: ok ? nil : "no sandbox \(sb)", down: "never touched")
                if !ok { refuse("agent \(a.name): no sandbox \(sb)", .notFound) }
            }
        }
        for r in i.rooms where r.external {
            var action = "run", why: String?
            if f.goneRooms.contains(r.chatRoom) && !(f.rooms?.contains(r.chatRoom) ?? false) {
                action = "refuse"; why = "room \(r.chatRoom) is gone (removed for good)"; refuse("room \(r.name): \(why!)", .notFound)
            } else if let rooms = f.rooms, !rooms.contains(r.chatRoom) {
                action = "refuse"; why = "no room \(r.chatRoom) in the chat server"; refuse("room \(r.name): \(why!)", .notFound)
            } else if f.rooms == nil && !f.indexedRooms.contains(r.chatRoom) {
                why = "whether it exists is \(unknown)"
            }
            step("check", "room \(r.name)", "external", "room \(r.chatRoom) exists", action: action, why: why,
                 down: "never touched (only its messages during the run are archived)")
        }
        for s in i.sandboxes where s.external {
            // 774: an external place no agent runs in is only declared: nothing of it is used, so nothing is checked.
            if s.agents.isEmpty, (i.places ?? []).contains(where: { $0.name == s.name && $0.from == "declared" }) {
                step("check", "sandbox \(s.name)", "external", "sandbox \(s.placeName) exists", action: "skip", why: "no agent runs in the place \(s.name)",
                     down: "never touched")
                continue
            }
            let ok = f.sandboxes.contains(s.placeName)
            step("check", "sandbox \(s.name)", "external", "sandbox \(s.placeName) exists", action: ok ? "run" : "refuse", why: ok ? nil : "no sandbox \(s.placeName)",
                 down: "never touched")
            if !ok { refuse("sandbox \(s.name): no sandbox \(s.placeName)", .notFound) }
        }
        for s in i.services { step("check", "service \(s)", "external", "service \(s) exists", action: "skip", why: "services are not checked in this version", down: "never touched") }
        if !f.chatOn && !i.rooms.isEmpty { refuse("chat is off — a space's rooms need it (doz chat on)", .invalidPhase) }
        if let b = f.brief, let problem = b.problem { refuse("the brief: \(problem)", .notFound) }

        // 2. The folders the space keeps (made when missing, never deleted): before the workspace, which holds them.
        let manager = i.manager
        let keptFolders = keptFolderPaths(i, f)
        for k in keptFolders {
            let exists = f.folders[k.path] ?? false
            step("folder", "folder \(k.name)", "persisted", "the data folder \(DisplayPath.tilde(k.path)) (persisted, from \(k.source))",
                 action: exists ? "skip" : "run", why: exists ? "already there" : nil, down: "kept; never deleted (--purge releases it)")
        }
        let scratchPaths = Set((ref?.scratch ?? []).map(\.path))
        var folderPaths = i.folders.compactMap { x -> WorkspaceFolder? in
            guard let path = x.path, f.folders[f.expand(path)] == true else { return nil }
            return WorkspaceFolder(path: f.expand(path), mode: x.access)
        }
        for k in keptFolders where !folderPaths.contains(where: { $0.path == k.path }) { folderPaths.append(WorkspaceFolder(path: k.path, mode: "rw")) }

        // 3. The workspace: new, or the record this space made; never one made without a space file.
        var reopens = false
        if let rec {
            if ref == nil {
                step("workspace-new", "workspace \(i.space)", "persisted", "the workspace \(i.space)", action: "refuse",
                     why: "\(i.space) was made without a space file")
                refuse("\(i.space) was made without a space file: up manages only a workspace a space file made (rename that one, or give the space another name)", .exists)
            } else {
                var diff: [String] = []
                let have = Set(rec.folders.map(\.path)).subtracting(scratchPaths), want = Set(folderPaths.map(\.path))
                for x in want.subtracting(have).sorted() { diff.append("+ folder \(DisplayPath.tilde(x))") }
                for x in have.subtracting(want).sorted() { diff.append("- folder \(DisplayPath.tilde(x))") }
                if rec.manager?.bot != manager?.bot { diff.append("manager \(rec.manager?.bot ?? "none") → \(manager?.bot ?? "none")") }
                if let a = ref?.brief?.sha256, let b = f.brief?.sha256, a != b { diff.append("the brief changed since the last up") }
                let edits = diff.contains { !$0.hasPrefix("the brief") }
                step("workspace-edit", "workspace \(i.space)", "persisted", diff.isEmpty ? "the workspace \(i.space): as the file says" : "the workspace \(i.space): " + diff.joined(separator: "; "),
                     action: edits ? "run" : "skip", op: edits ? .workspaceEdit : nil)
                if rec.flags.archivedAt != nil {
                    refuse("\(i.space) is archived — doz workspace restore \(i.space) first", .invalidPhase)
                } else if rec.flags.finishedAt != nil {
                    reopens = true
                }
            }
        } else {
            var text = "make the workspace \(i.space)"
            var parts: [String] = []
            if !folderPaths.isEmpty { parts.append("folders " + folderPaths.map { DisplayPath.tilde($0.path) + ($0.mode == "ro" ? " (read-only)" : "") }.joined(separator: ", ")) }
            if let m = i.mainRoom { parts.append(m.external ? "its room: the existing \(m.chatRoom), linked" : "its room \(m.chatRoom), made as you") }
            if let m = manager?.bot { parts.append("managed by \(m)") }
            parts.append(i.briefText != nil ? "the brief written in the file (kept with the workspace)" : "the brief from \(i.brief) (read from the file, never copied)")
            text += ": " + parts.joined(separator: "; ")
            // 762 (F12): the workspace itself outlives every run (its record stays at down), so it is never labelled a run's.
            step("workspace-new", "workspace \(i.space)", "persisted", text,
                 down: i.isStanding ? "the record stays, with everything the space made (standing); --purge retires what persists"
                     : "the record stays: down ends the run; --purge retires what persists", op: .workspaceNew)
        }

        // 4. Rooms: the main one made again when down removed it; the others made (or linked) before the run opens, so the
        // run's markers cover them.
        func liveRoom(_ name: String) -> Bool { rec?.rooms.contains { $0.chatRoom == name && $0.goneAt == nil } ?? false }
        for r in i.rooms {
            // 762 (F1): read through the lifetime — a standing space keeps its rooms at down.
            let life = i.downLifetime("room", r.chatRoom, declared: r.persisted == nil ? "run" : "persisted")
            let downText = life == "run" ? (i.archive.value == "off" ? "closed, then deleted with no copy (a tombstone kept)" : "closed, archived, then deleted (a tombstone kept)")
                : r.persisted == nil ? "closed: kept with its history and id (standing)" : "closed: kept with its history and id until the next up"
            if r.main {
                guard rec != nil, ref != nil, !r.external, !liveRoom(r.chatRoom) else { continue }
                step("room", "room \(r.name)", life, "make the main room \(r.chatRoom) again as you", down: downText)
            } else if r.external {
                step("room", "room \(r.name)", "external", "link the room \(r.chatRoom); invite its missing members",
                     action: liveRoom(r.chatRoom) ? "skip" : "run", why: liveRoom(r.chatRoom) ? "already linked" : nil,
                     down: "never touched; its run-window messages archived")
            } else {
                let had = liveRoom(r.chatRoom)
                step("room", "room \(r.name)", life, "make the room \(r.chatRoom) as you" + (r.persisted.map { " (\($0.words))" } ?? ""),
                     action: had ? "skip" : "run", why: had ? "already there" : nil, down: downText)
            }
        }

        // 5. The run: reopened when it is down (the persisted agents woken: their conversations continue), else started — a
        // new run each time none is open (765), unless --no-run.
        let asleep = (rec?.agents ?? []).filter { $0.endedAt == nil && ($0.isManager || $0.isWorker) }
        if reopens {
            step("workspace-reopen", "workspace \(i.space)", "run",
                 noRun ? "reopen \(i.space) (it is down) with no run (--no-run): its rooms open again" : "reopen \(i.space) (it is down): a new run, its rooms open again",
                 op: .workspaceReopen)
            if !asleep.isEmpty {
                step("workspace-wake", "workspace \(i.space)", "persisted", "wake what it kept: " + asleep.map(\.name).joined(separator: ", "), op: .workspaceWake)
            }
        } else if let openRun {
            step("workspace-start", "run \(openRun.id)", "run", "the run \(openRun.id) is open: up attaches to it and makes only what is missing", action: "skip", why: "already open")
        } else if noRun {
            step("workspace-start", "workspace \(i.space)", "run", "start its agents with no run (--no-run): doz workspace run \(i.space) opens one",
                 down: "nothing to close", op: .workspaceStart)
        } else {
            step("workspace-start", "run {run}", "run", "start: open a new run" + ((rec?.flags.startedAt == nil) ? "; the brief posted as your first message" : ""),
                 down: i.archive.value == "off" ? "the run closed with no archive" : "the run archived (evidence), then closed", op: .workspaceStart)
        }
        if noRun, openRun == nil, let x = i.folders.first(where: { $0.path == nil && $0.persisted == nil }) {
            refuse("--no-run: the scratch folder \(x.name) lives in a run — up without --no-run opens one", .invalidValue)
        }

        // 6. The run's scratch folders.
        let runFolder = (f.projectsDir as NSString).appendingPathComponent(".runs/\(i.space)/{run}")
        for x in i.folders where x.path == nil && x.persisted == nil {
            let made = openRun.map { o in (ref?.scratch ?? []).contains { $0.run == o.id && $0.name == x.name } } ?? false
            let life = i.downLifetime("folder", x.name, declared: "run")
            step("folder", "folder \(x.name)", life, "make the scratch folder \(DisplayPath.tilde(runFolder))/\(x.name)",
                 action: made && !reopens ? "skip" : "run", why: made && !reopens ? "already there" : nil,
                 down: life == "persisted" ? "kept on disk (standing)"
                     : i.archive.value == "off" ? "removed with no copy (archive: off)" : "copied into the run's archive, then removed")
        }

        // 7. Adopt the external sessions; 8. each agent Dozable starts, in file order (a worker from a bot too).
        for a in i.agents where a.external && a.session != nil {
            let have = rec?.agents.contains { $0.place.session == a.session && $0.endedAt == nil } ?? false
            step("workspace-adopt", "agent \(a.name)", "external", "adopt the session @mac/\(a.session!) as \(a.name)",
                 action: have ? "skip" : "run", why: have ? "already adopted" : nil, down: "released; never ended", op: .workspaceAdopt)
        }
        for a in i.agents where a.external && a.bot == nil && a.session == nil && a.sandbox != nil {
            let have = rec?.agents.contains { $0.place.sandbox == a.sandbox && $0.endedAt == nil } ?? false
            step("workspace-adopt", "agent \(a.name)", "external", "adopt the sandbox \(a.sandbox!) as \(a.name)",
                 action: have ? "skip" : "run", why: have ? "already adopted" : nil, down: "released; never stopped", op: .workspaceAdopt)
        }
        for a in i.agents where a.external && a.bot != nil && a.role != "manager" {
            var w = WorkerRequest(workspace: i.space, name: a.bot)
            w.fromBot = a.bot
            w.task = defaultTask
            w.rooms = a.rooms.isEmpty ? nil : a.rooms.compactMap { n in i.rooms.first { $0.name == n }?.chatRoom }
            let live = rec?.agents.contains { $0.bot == a.bot && $0.isLiveWorker } ?? false
            var s = SpacePlan.Step(n: steps.count + 1, kind: "worker-add", subject: "agent \(a.name)", action: live ? "skip" : "run", lifetime: "external",
                                   text: "start \(a.bot!) as a worker (its own identity and token)", why: live ? "already working in this run" : nil,
                                   down: "ended; the bot keeps its token", op: HostOp.workerAdd.rawValue)
            s.worker = w
            steps.append(s)
        }
        var sandboxMade: Set<String> = []
        for a in i.ownedAgents {
            var w = WorkerRequest(workspace: i.space, name: a.name)
            w.agent = "claude-code"
            // 774: the declared place it runs in, recorded on the agent (a fenced place: its own fence, built from the place).
            if let pl = a.place, (i.places ?? []).contains(where: { $0.name == pl && $0.from == "declared" }) { w.placeName = pl }
            w.task = a.prompt ?? prompts[a.name] ?? defaultTask
            let iso = a.isolation?.value ?? "fenced"
            var whereText: String
            if let sb = a.sandbox, let s = i.sandboxes.first(where: { $0.name == sb }) {
                let exists = !s.external && (rec?.agents.contains { $0.place.sandbox == s.placeName && $0.endedAt == nil } ?? false)
                if s.external || sandboxMade.contains(sb) || exists {
                    w.sandbox = s.placeName
                    whereText = "in the sandbox \(s.placeName)"
                } else {
                    w.isolation = "vm"; w.cpus = s.cpus; w.memory = s.memory
                    w.newSandbox = s.placeName
                    whereText = "in a new sandbox \(s.placeName)" + (s.persisted.map { " (\($0.words): its disk kept)" }
                        ?? (i.downLifetime("sandbox", s.placeName, declared: "run") == "persisted" ? " (standing: its disk kept)" : ""))
                    sandboxMade.insert(sb)
                }
            } else {
                w.isolation = iso
                whereText = iso == "unfenced" ? "unfenced on this Mac, with full access to your user (\(a.isolation!.words))" : "fenced on this Mac"
            }
            // 774: its fence (or its new sandbox) is built from the declared place's policy.
            if let pn = w.placeName, let pl = (i.places ?? []).first(where: { $0.name == pn }), pl.isolation != "unfenced" {
                let net = (pl.isolation == "fenced" ? a.network : nil) ?? pl.network
                whereText += pl.isolation == "fenced" ? ", its own fence built from the place \(pn) (network \(net.words); view \(pl.view.words); credentials \(pl.credentials.words))"
                    : sandboxMade.contains(a.sandbox ?? "") && w.newSandbox != nil ? ", made from the place \(pn) (network \(pl.network.words); credentials \(pl.credentials.words))" : ""
            }
            w.rooms = a.rooms.isEmpty ? nil : a.rooms.compactMap { n in i.rooms.first { $0.name == n }?.chatRoom }
            let bypass = a.permissions?.value == "bypass"
            if bypass { w.permissionMode = "bypass" }
            var text = "start \(a.name) " + whereText
            if bypass { text += ", bypassing permissions (\(a.permissions!.words))" }
            if let m = a.memory { text += "; its memory persisted (\(m.source)): it continues its conversation" }
            let entry = rec?.agents.last { $0.name == a.name && $0.isWorker && $0.endedAt == nil }
            var action = "run", why: String?, lifetime = a.memory == nil ? i.downLifetime("agent", a.name, declared: "run") : "persisted"
            if let e = entry {
                let was = e.isolation ?? "fenced", now = w.isolation ?? "vm"
                if a.memory != nil, was != now, (was == "unfenced") != (now == "unfenced") {
                    why = "its isolation changed (\(was) → \(now)): it starts fresh in its new place; its kept memory is kept (doz worker reset clears it)"
                    lifetime = "persisted"
                } else {
                    action = "skip"
                    why = reopens ? "kept from the last run: woken, its conversation continues" : "already running in this run"
                }
            }
            var down: String
            switch (a.memory != nil, a.transcripts?.value) {
            case (true, _): down = "ended; its conversation and memory kept for the next run"
            case (false, _) where lifetime == "persisted":
                down = "stopped; kept with its conversation (standing) — --purge ends and forgets it"
            case (false, "discard"): down = "ended and forgotten; its transcripts " + (i.archive.value == "off" ? "deleted with no copy" : "deleted once the archived copy is hash-checked")
            default: down = "ended and forgotten; its transcripts kept"
            }
            var s = SpacePlan.Step(n: steps.count + 1, kind: "worker-add", subject: "agent \(a.name)", action: action,
                                   lifetime: lifetime, text: text, why: why, down: down, op: HostOp.workerAdd.rawValue)
            s.worker = w
            s.permissionMode = bypass ? "bypass" : (a.permissions?.value ?? nil)
            steps.append(s)
        }
        if !i.requests.isEmpty {
            func key(_ agent: String, _ role: String?, _ grants: [String], _ reason: String) -> String { ([agent, role ?? "", reason] + grants).joined(separator: "\u{1E}") }
            let have = Set((rec?.permissions?.requests ?? []).compactMap { try? $0.decode(SpaceRequestRow.self) }.map { key($0.agent, $0.role, $0.grants, $0.reason) })
            let same = have == Set(i.requests.map { key($0.agent, $0.role, $0.grants, $0.reason) })
            step("requests", "requests", "run", "record \(i.requests.count) request\(i.requests.count == 1 ? "" : "s") in the workspace's permissions (none granted)",
                 action: same ? "skip" : "run", why: same ? "recorded already" : nil, down: "kept with the record")
        }

        // Refusals make every step that has not run a refusal's consequence: nothing changes.
        p.refusals = refusals.map(\.0)
        p.refusalCode = refusals.first?.1.rawValue
        p.steps = steps
        p.summary = summary(i, f: f, ref: ref)
        p.notes += i.notes
        p.sha = sha(p)
        return p
    }

    /// The summary: what starts, where, with which risky settings and where each was set; externals; what persists;
    /// the archive; transcripts; requests. Every risky setting names its file and line.
    static func summary(_ i: SpaceIntent, f: SpaceFacts, ref: SpaceRecordRef?) -> [String] {
        var out: [String] = []
        func plural(_ n: Int, _ w: String) -> String { "\(n) \(w)\(n == 1 ? "" : "s")" }
        var starts: [String] = []
        let owned = i.ownedAgents
        let unfenced = owned.filter { $0.isolation?.value == "unfenced" }
        let fenced = owned.filter { $0.isolation?.value == "fenced" }
        let vm = owned.filter { $0.isolation?.value == "vm" }
        func risky(_ a: SpaceIntent.Agent) -> String {
            var r: [String] = []
            if let x = a.isolation, x.value == "unfenced" { r.append("unfenced from \(x.source)") }
            if let x = a.permissions, x.value == "bypass" { r.append("bypass from \(x.source)") }
            if let x = a.remoteControl { r.append("Remote Control from \(x.source)") }
            return r.joined(separator: ", ")
        }
        func group(_ list: [SpaceIntent.Agent], _ words: String, _ each: (SpaceIntent.Agent) -> String) {
            guard !list.isEmpty else { return }
            starts.append("\(plural(list.count, words)) (" + list.map(each).joined(separator: "; ") + ")")
        }
        if !unfenced.isEmpty {
            let allBypass = unfenced.allSatisfy { $0.permissions?.value == "bypass" }
            starts.append("\(unfenced.count) unfenced\(allBypass ? " bypass" : "") agent\(unfenced.count == 1 ? "" : "s") with full access to your user ("
                          + unfenced.map { "\($0.name): \(risky($0))" }.joined(separator: "; ") + ")")
        }
        group(fenced, "fenced agent") { a in let r = risky(a); return a.name + (r.isEmpty ? "" : ": " + r) }
        group(vm, "sandboxed agent") { a in
            let r = risky(a)
            return "\(a.name): in \(a.sandbox ?? "?")" + (r.isEmpty ? "" : ", " + r)
        }
        let ownedSandboxes = i.sandboxes.filter { !$0.external }
        if !ownedSandboxes.isEmpty {
            starts.append(plural(ownedSandboxes.count, "sandbox").replacingOccurrences(of: "sandboxs", with: "sandboxes") + " ("
                          + ownedSandboxes.map { "\($0.name): \($0.persisted == nil && i.downLifetime("sandbox", $0.placeName, declared: "run") == "run" ? "this run only" : "persisted")" }.joined(separator: "; ") + ")")
        }
        let ownedRooms = i.rooms.filter { !$0.external }
        if !ownedRooms.isEmpty {
            starts.append(plural(ownedRooms.count, "room") + " (" + ownedRooms.map { "\($0.chatRoom): \($0.persisted == nil && i.downLifetime("room", $0.chatRoom, declared: "run") == "run" ? "this run only" : "persisted")" }.joined(separator: "; ") + ")")
        }
        var s = starts.isEmpty ? "Starts nothing." : "Starts " + starts.joined(separator: ", ") + "."
        var ext: [String] = []
        for a in i.agents where a.external {
            ext.append("\(a.name) (" + (a.bot.map { "bot: \($0)" } ?? a.session.map { "session: \($0)" } ?? "sandbox: \(a.sandbox ?? "?")") + ")")
        }
        for x in i.folders where x.path != nil { ext.append("\(x.name) (\(x.path!))") }
        for r in i.rooms where r.external { ext.append("\(r.name) (room \(r.chatRoom))") }
        for x in i.sandboxes where x.external { ext.append("\(x.name) (sandbox \(x.placeName))") }
        ext += i.services
        if !ext.isEmpty { s += " Externals: " + ext.joined(separator: ", ") + "." }
        out.append(s)

        var kept: [String] = []
        for r in i.rooms { if let p = r.persisted { kept.append("room \(r.chatRoom) (from \(p.source))") } }
        for a in i.agents { if let m = a.memory { kept.append("agent \(a.name)'s memory (from \(m.source))") } }
        for x in i.sandboxes { if let p = x.persisted { kept.append("sandbox \(x.name)'s disk (from \(p.source))") } }
        for x in i.folders { if let p = x.persisted { kept.append("folder \(x.name) (from \(p.source))") } }
        for x in i.persistedPaths { kept.append("folder \(x.value) (from \(x.source))") }
        if i.isStanding {
            // 762 (F1): a standing space's down removes nothing it owns but what says `lifetime: run` itself — say what it keeps.
            var standing: [String] = []
            var goes: [String] = []
            for r in i.rooms where !r.external && r.persisted == nil {
                if i.downLifetime("room", r.chatRoom, declared: "run") == "run" { goes.append("room \(r.chatRoom)") } else { standing.append("room \(r.chatRoom)") }
            }
            for a in owned where a.memory == nil {
                if i.downLifetime("agent", a.name, declared: "run") == "run" { goes.append("agent \(a.name)") } else { standing.append("agent \(a.name) and its conversation") }
            }
            for x in i.sandboxes where !x.external && x.persisted == nil {
                if i.downLifetime("sandbox", x.placeName, declared: "run") == "run" { goes.append("sandbox \(x.name)") } else { standing.append("sandbox \(x.name)'s disk") }
            }
            for x in i.folders where x.path == nil && x.persisted == nil {
                if i.downLifetime("folder", x.name, declared: "run") == "run" { goes.append("scratch folder \(x.name)") } else { standing.append("scratch folder \(x.name)") }
            }
            let all = standing + kept
            var line = "Standing (x-dozable.lifetime): down stops the run and keeps " + (all.isEmpty ? "the workspace and its record" : all.joined(separator: ", "))
            line += goes.isEmpty ? "." : "; it removes only what says lifetime: run (" + goes.joined(separator: ", ") + ")" + (i.archive.value == "off" ? ", with no copy (archive: off)." : ", archived first.")
            out.append(line)
        } else {
            out.append(kept.isEmpty ? "Nothing persisted: down removes everything the space made." : "Persisted: " + kept.joined(separator: ", ") + ".")
        }

        if i.archive.value == "off" {
            out.append("Archive: off (from \(i.archive.source)): down keeps no copy — rooms, scratch folders and discarded transcripts are deleted with no copy.")
        } else {
            out.append("Archive: on (\(i.archiveKeep.joined(separator: ", "))), written by down into the store before anything is removed.")
        }
        var t: [String] = []
        for a in owned {
            guard let x = a.transcripts else { continue }
            if a.memory != nil { t.append("kept for \(a.name) (persisted: the next run continues them)") }
            else if x.value == "discard" { t.append("discarded for \(a.name) " + (i.archive.value == "off" ? "with no copy" : "after the archived copy is hash-checked") + " (from \(x.source))") }
            else { t.append("kept for \(a.name) (from \(x.source))") }
        }
        if !t.isEmpty { out.append("Transcripts: " + t.joined(separator: "; ") + ".") }
        if !i.requests.isEmpty {
            out.append("Requested, not granted: " + i.requests.map { r in
                "\(r.agent) — " + ([r.role.map { "role \($0)" }].compactMap { $0 } + r.grants).joined(separator: ", ") + " (\(r.reason); \(r.source))"
            }.joined(separator: "; ") + ". The owner grants with doz permissions grant.")
        }
        if let a = ref?.brief?.sha256, let b = f.brief?.sha256, a != b { out.append("The brief changed since the last up.") }
        if i.unfenced.count > 0 {
            out.append("Up asks you to confirm \(i.unfenced.joined(separator: ", ")) (unfenced) at every up; --yes answers on a terminal only.")
        }
        if !i.isStanding && owned.allSatisfy({ $0.memory == nil && $0.transcripts?.value == "discard" }) && i.archive.value == "off"
            && i.rooms.allSatisfy({ $0.persisted == nil }) && i.sandboxes.allSatisfy({ $0.persisted == nil }) && i.persistedPaths.isEmpty {
            out.append("A clean room: down leaves nothing behind but Dozable's own logs and the rooms' tombstones.")
        }
        return out
    }

    /// The sha over what would be done to whom: the merged spec's sha, each step's kind, subject, action and request,
    /// the confirm set, the refusals. Never a time.
    static let sortedEncoder: JSONEncoder = { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return e }()

    static func sha(_ p: SpacePlan) -> String {
        var parts = ["space=\(p.space)", "spec=\(p.specSHA)", "confirm=\(p.confirm.joined(separator: ","))"]
        for s in p.steps {
            let w = s.worker.flatMap { try? sortedEncoder.encode($0) }.map { String(decoding: $0, as: UTF8.self) } ?? ""
            parts.append("\(s.kind)|\(s.subject)|\(s.action)|\(s.op ?? "")|\(s.permissionMode ?? "")|\(w)")
        }
        parts += p.refusals.map { "refusal=\($0)" }
        return SHA256.hash(data: Data(parts.joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
