import CryptoKit
import Foundation

// A workspace's lifecycle, looked at before it is acted on: "check, then ask". ONE pure builder (`WorkspaceLifecycle.plan`)
// answers what a verb — stop, sleep, wake, finish, reopen, archive, restore, delete — would do to each agent (the table:
// now, after, how it comes back), what is kept and what goes (with sizes), everything it would refuse at once, how many
// changes run at once, how it is confirmed, today's per-agent commands and a `sha`. The read-only HostOp
// `workspace-lifecycle-plan` (`doz workspace VERB W --dry-run`, the dashboard's dialogs) answers it with nothing written and
// no daemon started; the daemon builds the same plan again before it acts, and refuses one that changed since the person
// looked (`ifPlan`). `docs/engineering/workspaces.md` ("The lifecycle").

/// The lifecycle verbs of a workspace.
public enum WorkspaceVerb: String, Codable, CaseIterable, Sendable {
    case stop, sleep, wake, finish, reopen, archive, restore, delete

    /// The HostOp that does it (stop is `workspace-stop`, unchanged: the manager only).
    public var hostOp: HostOp {
        switch self {
        case .stop: .workspaceStop
        case .sleep: .workspaceSleep
        case .wake: .workspaceWake
        case .finish: .workspaceFinish
        case .reopen: .workspaceReopen
        case .archive: .workspaceArchive
        case .restore: .workspaceRestore
        case .delete: .workspaceDelete
        }
    }

    public init?(op: HostOp) {
        guard let v = Self.allCases.first(where: { $0.hostOp == op }) else { return nil }
        self = v
    }

    /// How the person confirms it: archive and delete by typing the name, finish by a plain yes, the rest not at all.
    public var confirm: WorkspaceLifecycle.Confirm {
        switch self {
        case .archive, .delete: .typed
        case .finish: .yes
        default: .none
        }
    }
}

public enum WorkspaceLifecycle {
    public enum Confirm: String, Codable, Sendable { case none, yes, typed }
    /// The finish plan's line when it closes a room (verbatim, the owner's words).
    public static let closesNote = "finish closes the room to new messages until you reopen"

    /// What the plan knows of one agent's place now.
    public struct AgentFacts: Equatable, Sendable {
        public enum Now: String, Codable, Sendable {
            case running, booting, paused, asleep, off, failed, ended, notStarted = "not-started", gone, elsewhere
        }
        public var now: Now
        /// What its program is doing (`working`, `idle`, `blocked`, `error`; nil: not known).
        public var activity: String?
        /// A session on this Mac: fenced (nil: not a session, or not known).
        public var fenced: Bool?
        /// Its program has a conversation to resume (Claude Code); false: it starts fresh on wake.
        public var resumable: Bool
        /// A sandbox's memory, given back while it sleeps.
        public var memoryMiB: Int?
        /// A sandbox's folder on disk (its disks and restore points), in bytes allocated.
        public var diskBytes: Int64?
        /// A sandbox's restore points.
        public var points: Int?
        /// An anonymous worker's token is still held by its place (a sandbox shut down revoked it: a new one on wake).
        public var secretKept: Bool?
        public init(now: Now, activity: String? = nil, fenced: Bool? = nil, resumable: Bool = false, memoryMiB: Int? = nil, diskBytes: Int64? = nil,
                    points: Int? = nil, secretKept: Bool? = nil) {
            self.now = now; self.activity = activity; self.fenced = fenced; self.resumable = resumable; self.memoryMiB = memoryMiB
            self.diskBytes = diskBytes; self.points = points; self.secretKept = secretKept
        }
        public var runs: Bool { [.running, .booting, .paused].contains(now) }
    }

    /// The chat server as the plan sees it.
    public enum Chat: Equatable, Sendable {
        case off
        case notReady(String)
        case ready
    }

    /// Everything the builder reads besides the record.
    public struct Facts: Equatable, Sendable {
        /// A daemon answered (else the store and the sessions' holders were read in-process; checked again when acting).
        public var known: Bool
        /// By the agent's name.
        public var agents: [String: AgentFacts]
        public var chat: Chat
        /// `ui.batch_concurrency`: how many agents change at once.
        public var width: Int
        /// A start or another lifecycle change of this workspace is under way.
        public var busy: Bool
        /// This Mac's home and the store, resolved: never moved to the Bin.
        public var home: String
        public var store: String
        /// Folders something else uses: path → who ("the workspace X", "the sandbox Y").
        public var foldersInUse: [String: String]
        /// The image and template names taken (a kept template gets a free one).
        public var imagesTaken: Set<String>
        /// Finish (and archive of a workspace not finished): what the run's archive would hold (nil: not looked at).
        public var archive: ArchiveFacts?
        /// The rooms the workspace made (owns): only these are closed at finish (nil: as the record says).
        public var ownedRooms: Set<String>?
        public init(known: Bool = true, agents: [String: AgentFacts] = [:], chat: Chat = .ready, width: Int = 3, busy: Bool = false,
                    home: String = "/Users/nobody", store: String = "/tmp/store", foldersInUse: [String: String] = [:], imagesTaken: Set<String> = []) {
            self.known = known; self.agents = agents; self.chat = chat; self.width = width; self.busy = busy; self.home = home; self.store = store
            self.foldersInUse = foldersInUse; self.imagesTaken = imagesTaken
        }
    }

    /// What the run's archive would hold, as the plan sees it.
    public struct ArchiveFacts: Equatable, Sendable {
        /// The run's id (the open one, or the one its finish would record) and where its archive goes (relative to the store).
        public var run: String
        public var path: String
        /// Each room of the run → its messages so far (nil: not known — chat is not ready).
        public var rooms: [String: Int?]
        /// Each agent → where its conversations come from, how many and their bytes (nil: not known until it stops).
        public var transcripts: [String: (source: String, files: Int?, bytes: Int64?)]
        /// The agents with a screen kept.
        public var screens: [String]
        /// Free bytes on the store's disk (nil: not known).
        public var freeBytes: Int64?
        public init(run: String, path: String, rooms: [String: Int?] = [:], transcripts: [String: (source: String, files: Int?, bytes: Int64?)] = [:],
                    screens: [String] = [], freeBytes: Int64? = nil) {
            self.run = run; self.path = path; self.rooms = rooms; self.transcripts = transcripts; self.screens = screens; self.freeBytes = freeBytes
        }
        public static func == (a: ArchiveFacts, b: ArchiveFacts) -> Bool {
            a.run == b.run && a.path == b.path && a.rooms == b.rooms && a.screens == b.screens && a.freeBytes == b.freeBytes
                && a.transcripts.mapValues { "\($0.source)|\($0.files.map(String.init) ?? "")|\($0.bytes.map(String.init) ?? "")" }
                == b.transcripts.mapValues { "\($0.source)|\($0.files.map(String.init) ?? "")|\($0.bytes.map(String.init) ?? "")" }
        }

        /// A rough size: each message about 2 KiB, the conversations' bytes, 64 KiB a screen and the small files.
        public var estimateBytes: Int64 {
            let msgs = rooms.values.compactMap { $0 }.reduce(0, +)
            let tr = transcripts.values.compactMap(\.bytes).reduce(0, +)
            return Int64(msgs) * 2048 + tr + Int64(screens.count) * 65_536 + 262_144
        }
    }

    /// The flags of a verb (archive and delete).
    public struct Options: Equatable, Sendable {
        /// Remove the sandboxes Dozable made for this workspace (archive, delete).
        public var removeSandboxes: Bool
        /// With `removeSandboxes`: a template of each first (on unless turned off).
        public var keepTemplates: Bool
        /// Delete: move its folders to the Bin.
        public var binFolders: Bool
        /// Finish, archive: no evidence archive (`--no-archive`).
        public var noArchive: Bool
        public init(removeSandboxes: Bool = false, keepTemplates: Bool = true, binFolders: Bool = false, noArchive: Bool = false) {
            self.removeSandboxes = removeSandboxes; self.keepTemplates = keepTemplates; self.binFolders = binFolders; self.noArchive = noArchive
        }
        public init(_ w: WorkspaceRequest) {
            self.init(removeSandboxes: w.removeSandboxes == true, keepTemplates: w.keepTemplates != false, binFolders: w.binFolders == true,
                      noArchive: w.noArchive == true)
        }
    }

    // MARK: building

    /// The plan of `verb` for `rec` (its derived `state`), from `facts` and `options`. Pure.
    public static func plan(verb: WorkspaceVerb, record rec: WorkspaceRecord, state: String, facts: Facts, options o: Options) -> WorkspaceLifecyclePlan {
        let n = rec.name
        var refusals: [(HostError.Code, String)] = []
        func refuse(_ c: HostError.Code, _ s: String) { refusals.append((c, s)) }
        let archived = rec.flags.archivedAt != nil, finished = rec.flags.finishedAt != nil
        let settingUp = rec.flags.startedAt == nil && rec.flags.firstAgentAt == nil
        if facts.busy { refuse(.invalidPhase, "\(n) is busy: a start or another change is under way — try again when it ends") }
        switch verb {
        case .stop:
            if archived { refuse(.invalidPhase, "\(n) is archived — doz workspace restore \(n) first") }
        case .sleep, .wake:
            if archived { refuse(.invalidPhase, "\(n) is archived — doz workspace restore \(n), then doz workspace wake \(n)") }
            else if finished { refuse(.invalidPhase, "\(n) is finished — doz workspace reopen \(n) first") }
            else if settingUp { refuse(.invalidPhase, "\(n) is still setting up — doz workspace start \(n) first") }
        case .finish:
            if archived { refuse(.invalidPhase, "\(n) is archived — it is finished already") }
            else if finished { refuse(.invalidPhase, "\(n) is finished already — doz workspace reopen \(n) to work on it again") }
        case .reopen:
            if archived { refuse(.invalidPhase, "\(n) is archived — doz workspace restore \(n) first") }
            else if !finished { refuse(.invalidPhase, "\(n) is not finished — nothing to reopen") }
        case .archive:
            if archived { refuse(.invalidPhase, "\(n) is archived already") }
        case .restore:
            if !archived { refuse(.invalidPhase, "\(n) is not archived — nothing to restore") }
        case .delete:
            if !archived && !finished { refuse(.invalidPhase, "\(n) is not finished — finish it first: doz workspace finish \(n)") }
        }
        // Rooms are archived and opened again as you: the chat server must answer.
        if (verb == .archive || verb == .restore), !rec.rooms.isEmpty {
            switch facts.chat {
            case .off: refuse(.unavailable, "chat is off, and \(n)'s rooms are \(verb == .archive ? "archived" : "opened again") as you — doz chat on")
            case .notReady(let why): refuse(.unavailable, "chat is on but its server is not ready (\(why)) — doz chat status")
            case .ready: break
            }
        }
        var rows: [WorkspaceLifecycleRow] = []
        var roomRows: [WorkspaceLifecycleRoomRow] = []
        var commands: [String] = []
        var notes: [String] = []
        var keeps: [WorkspaceLifecycleItem] = []
        var goes: [WorkspaceLifecycleItem] = []
        var running: [String] = []
        var freedMiB = 0
        var removedBytes: Int64 = 0
        var removedNames: [String] = []
        var templates: [String: String] = [:]
        var taken = facts.imagesTaken
        func add(_ c: String) { if !commands.contains(c) { commands.append(c) } }
        for a in rec.agents where a.endedAt == nil {
            let f = facts.agents[a.name] ?? AgentFacts(now: a.place.key == nil ? .elsewhere : .gone)
            let role = a.isManager ? "manager" : a.isWorker ? "worker" : "adopted"
            let vm = a.place.sandbox != nil
            let shared = a.isWorker && a.place.sandbox != nil && a.place.session != nil
            let iso = a.place.key == nil ? "elsewhere" : vm ? "vm" : a.isolation ?? (f.fenced == true ? "fenced" : "unfenced")
            let place = a.place.display
            let key = a.place.key ?? "elsewhere:" + a.name
            var r = WorkspaceLifecycleRow(name: a.name, role: role, place: place, isolation: iso, now: nowWords(f), activity: f.activity,
                                          after: "unchanged", back: "—", changes: false, change: key, bot: a.bot)
            if f.runs, a.place.key != nil { running.append(a.name) }
            // Dozable made this sandbox for the workspace (a manager's or a worker's own) — the only kind --remove-sandboxes removes.
            let ours = vm && (a.isManager || a.isWorker) && !shared
            let sbx = a.place.sandbox ?? ""
            let session = a.place.session ?? ""
            let unfenced = iso == "unfenced"
            let anonymous = a.isWorker && a.anonymous == true
            switch (verb, f.now) {
            case (_, .elsewhere):
                r.after = verb == .sleep ? "untouched" : "untouched; stays in the room"
                r.back = verb == .sleep ? "runs on its own machine; Dozable cannot sleep it" : "runs on its own machine"
            case (_, .gone):
                r.after = "gone"
                r.back = "doz workspace release \(n) \(a.name)"
            case (.stop, _):
                guard a.isManager, f.runs else { r.after = a.isManager ? "stays stopped" : "untouched"; break }
                r.changes = true
                r.after = vm ? "shut down, its disk kept" : "stopped, its conversation kept" + (unfenced ? "; its token file deleted" : "")
                r.back = "doz workspace start \(n)"
                add("doz workspace stop \(n)")
            case (.sleep, _):
                guard f.runs else { r.after = f.now == .notStarted ? "not started" : "stays " + nowWords(f); break }
                r.changes = true
                if vm {
                    r.after = "hibernated: its memory given back"
                    r.back = "the same sessions and screens"
                    if !rows.contains(where: { $0.change == key && $0.changes }) { freedMiB += f.memoryMiB ?? 0 }
                    add("doz hibernate \(sbx)")
                } else {
                    r.after = (f.resumable ? "ended, its conversation kept" : "ended") + (unfenced && (a.isManager || a.isWorker) ? "; its token file deleted" : "")
                    r.back = f.resumable ? "resumes its conversation" : "starts fresh"
                    if unfenced && anonymous { r.back += ", with a new token" }
                    add("doz sessions end @mac \(session)")
                }
            case (.wake, _):
                if f.runs { r.after = "stays running"; break }
                if f.now == .notStarted {
                    guard a.isManager else { break }
                    r.changes = true
                    r.after = "started"
                    r.back = "as doz workspace start does"
                    add("doz workspace start \(n)")
                    break
                }
                // An adopted agent the person stopped themselves stays as it is; what Dozable put to sleep wakes.
                guard a.isManager || a.isWorker || a.stoppedAt != nil else { r.after = "stays " + nowWords(f) + " (not put to sleep by Dozable)"; break }
                r.changes = true
                if vm {
                    if f.now == .off || f.now == .failed {
                        r.after = a.isManager || a.isWorker ? "started: a cold boot, its agent continues its conversation" : "started: a cold boot"
                        r.back = "its disk as it was"
                        if anonymous && f.secretKept != true { r.after += ", with a new token" }
                        add("doz start \(sbx)")
                    } else {
                        r.after = "woken"
                        r.back = "the same sessions and screens"
                        add("doz wake \(sbx)")
                    }
                } else {
                    r.after = f.resumable ? "running again, in the same conversation" : "running again, started fresh"
                    r.back = f.resumable ? "its conversation resumed" : "a new run of its program"
                    if unfenced && a.isWorker { r.after += anonymous ? "; a new token, in its file again" : "; its token file written again" }
                    if unfenced && a.isManager { r.after += "; its token file written again" }
                    add(a.isManager ? "doz workspace start \(n)" : "doz sessions restart @mac \(session)")
                }
                if a.isManager && unfenced { notes.append("\(a.name) runs unfenced: it acts as you") }
            case (.finish, _), (.archive, _), (.delete, _):
                var after: [String] = []
                if verb == .delete, f.runs { after.append("still runs") }
                if verb != .delete, f.runs || (vm && f.now == .asleep) {
                    r.changes = true
                    if vm {
                        after.append("shut down, its disk kept")
                        add("doz shutdown \(sbx)")
                    } else {
                        after.append(f.resumable ? "ended, its conversation kept" : "ended")
                        if unfenced && (a.isManager || a.isWorker) { after.append("its token file deleted") }
                        add("doz sessions end @mac \(session)")
                    }
                }
                if verb == .archive || verb == .delete {
                    if anonymous {
                        r.changes = true
                        after.append("retired: its token is refused from now on")
                        add("doz worker end \(n) \(a.name)")
                    } else if a.isWorker, let b = a.bot {
                        after.append("\(b) keeps its token")
                    }
                    if ours && o.removeSandboxes {
                        r.changes = true
                        if o.keepTemplates, verb == .archive || verb == .delete {
                            let t = templateName(sbx, taken: taken)
                            taken.insert(t)
                            templates[sbx] = t
                            after.append("a template kept: \(t)")
                            add("doz template create \(sbx) --as \(t)")
                        }
                        after.append("its sandbox removed")
                        removedBytes += f.diskBytes ?? 0
                        removedNames.append(sbx)
                        add("doz rm \(sbx)")
                    }
                    if verb == .delete {
                        if !vm && (a.isManager || a.isWorker) {
                            r.changes = true
                            after.append("its session's record forgotten")
                        } else if !(ours && o.removeSandboxes) {
                            r.changes = true
                            after.append("released: loose again" + (vm ? ", its disk kept" : ""))
                            add("doz workspace release \(n) \(a.name)")
                        }
                    }
                }
                r.after = after.isEmpty ? (f.now == .notStarted ? "not started" : "stays " + nowWords(f)) : after.joined(separator: "; ")
                r.back = verb == .delete ? "—" : verb == .archive ? (anonymous ? "—" : "doz workspace restore \(n), then reopen and wake")
                    : "doz workspace reopen \(n), then wake"
                if verb == .delete && a.isManager, let b = a.bot { r.after += (r.after.isEmpty ? "" : "; ") + "\(b) keeps its token" }
            case (.reopen, _), (.restore, _):
                r.after = verb == .reopen ? "asleep until you wake it" : "finished; doz workspace reopen \(n), then wake"
                r.back = verb == .reopen ? "doz workspace wake \(n)" : "—"
            }
            rows.append(r)
        }
        // What is kept and what goes, verb by verb.
        let roomList = rec.rooms.map { "#" + $0.chatRoom }.joined(separator: ", ")
        switch verb {
        case .stop:
            keeps = [.init("its manager's conversation, record and room"), .init("every worker, untouched")]
        case .sleep:
            keeps = [.init("every conversation, screen and disk"), .init("the room\(rec.rooms.count == 1 ? "" : "s") — messages wait there"), .init("every token")]
            if freedMiB > 0 { goes.append(.init("memory given back", bytes: Int64(freedMiB) << 20)) }
            notes.append("it stays asleep until you wake it: doz workspace wake \(n)")
        case .wake:
            keeps = [.init("the brief is not posted again")]
        case .finish:
            keeps = [.init(rec.rooms.isEmpty ? "no room" : "the room\(rec.rooms.count == 1 ? "" : "s") \(roomList) and \(rec.rooms.count == 1 ? "its" : "their") history — members can read"),
                     .init("every token (reopen works)"), .init("every disk and conversation"), .init("every folder, untouched")]
            var closes = false
            for room in rec.rooms where room.goneAt == nil {
                let owned = facts.ownedRooms?.contains(room.chatRoom) ?? (room.owned == true)
                roomRows.append(WorkspaceLifecycleRoomRow(room: room.chatRoom, label: room.label, owned: owned,
                                                          after: owned ? "closed: members can read it, posts refused (space-down)" : "linked: not closed"))
                if owned { closes = true }
            }
            if closes {
                goes.append(.init("new messages in \(roomRows.filter(\.owned).map { "#" + $0.room }.joined(separator: ", ")) (closed until you reopen)"))
                notes.append(WorkspaceLifecycle.closesNote)
            }
            notes.append("nothing runs afterwards; doz workspace reopen \(n), then wake, to work on it again")
        case .reopen:
            keeps = [.init("everything as it was finished")]
            if rec.runs.last.map({ !$0.isOpen }) == true, !(facts.ownedRooms ?? []).isEmpty {
                notes.append("its rooms open to new messages again, and a new run begins")
            }
            notes.append("nothing runs yet: doz workspace wake \(n) brings its agents back")
        case .archive:
            keeps = [.init(rec.rooms.isEmpty ? "no room" : "the history and files of \(roomList) (read-only)"), .init("the brief, its log and the conversations"),
                     .init("every bot and its token"), .init("every folder, untouched")]
            if o.removeSandboxes, o.keepTemplates, !templates.isEmpty { keeps.append(.init("a template of each sandbox removed: " + templates.values.sorted().joined(separator: ", "))) }
            if !rec.rooms.isEmpty { goes.append(.init("writing in \(roomList) (archived: read-only)")) }
            let anon = rec.agents.filter { $0.endedAt == nil && $0.isWorker && $0.anonymous == true }.map(\.name)
            if !anon.isEmpty { goes.append(.init("the tokens of \(anon.joined(separator: ", ")) (retired)")) }
            if o.removeSandboxes, !removedNames.isEmpty { goes.append(.init("the sandboxes \(removedNames.joined(separator: ", ")): their disks and restore points", bytes: removedBytes)) }
            else if rows.contains(where: { $0.isolation == "vm" }) {
                let bytes = rec.agents.compactMap { a -> Int64? in
                    guard a.endedAt == nil, (a.isManager || a.isWorker), a.place.sandbox != nil, a.place.session == nil else { return nil }
                    return facts.agents[a.name]?.diskBytes
                }.reduce(0, +)
                if bytes > 0 { notes.append("its sandboxes keep their disks — --remove-sandboxes would free them") }
            }
        case .restore:
            keeps = [.init("finished: you choose when it runs (reopen, then wake)")]
            goes = []
            if !rec.rooms.isEmpty { notes.append("its rooms \(roomList) are opened again as you") }
            let retired = rec.agents.filter { $0.isWorker && $0.anonymous == true && $0.endedAt != nil }.map(\.name)
            if !retired.isEmpty { notes.append("retired workers stay ended: \(retired.joined(separator: ", "))") }
            for s in rec.flags.archive?.removed ?? [] {
                notes.append("\(s) is gone" + (rec.flags.archive?.templates[s].map { " — its template \($0)" } ?? " — no template was kept"))
            }
        case .delete:
            keeps = [.init(rec.rooms.isEmpty ? "no room" : "\(roomList), archived, with their history"), .init("every bot and its token"), .init("templates"),
                     .init("adopted sandboxes and sessions — loose again")]
            if !o.binFolders { keeps.append(.init(rec.folders.isEmpty ? "no folder" : "every folder, untouched")) }
            goes = [.init("the workspace's record, brief and log — this cannot be undone")]
            if o.removeSandboxes, !removedNames.isEmpty { goes.append(.init("the sandboxes \(removedNames.joined(separator: ", ")): their disks and restore points", bytes: removedBytes)) }
            if o.binFolders {
                for fo in rec.folders {
                    if let why = binRefusal(fo.path, workspace: n, facts: facts) { refuse(.invalid, why) }
                    else { goes.append(.init("moved to the Bin", path: fo.path)) }
                }
                if rec.folders.isEmpty { notes.append("it has no folder: nothing goes to the Bin") }
            }
            if !running.isEmpty { refuse(.invalidPhase, "\(running.joined(separator: ", ")) still run\(running.count == 1 ? "s" : "") — doz workspace finish \(n) stops \(running.count == 1 ? "it" : "them") first") }
            if !rec.rooms.isEmpty, facts.chat != .ready, rec.flags.archivedAt == nil { notes.append("chat is not running: its rooms stay as they are") }
            notes.append("its rooms stay, archived, with their history — doz chat room rm R removes a room for good")
            if !rec.runs.isEmpty { keeps.append(.init("its run archives (\(rec.runs.filter { $0.archive != nil }.count)) in the store")) }
        }
        // The run's evidence archive: what it will hold, and what would keep it from being written.
        var archivePlan: WorkspaceArchivePlan?
        if verb == .finish || (verb == .archive && !finished) {
            if o.noArchive {
                archivePlan = WorkspaceArchivePlan(off: true)
                notes.append("no archive of the run is written (--no-archive)")
            } else if let a = facts.archive {
                var ap = WorkspaceArchivePlan(off: false)
                ap.run = a.run
                ap.path = a.path
                ap.rooms = a.rooms.keys.sorted().map { WorkspaceArchivePlan.Room(room: $0, messages: a.rooms[$0] ?? nil) }
                ap.transcripts = a.transcripts.keys.sorted().map { k in
                    let t = a.transcripts[k]!
                    return WorkspaceArchivePlan.Transcripts(agent: k, source: t.source, files: t.files)
                }
                ap.screens = a.screens.sorted()
                ap.estimateBytes = a.estimateBytes
                archivePlan = ap
                if !a.rooms.isEmpty, facts.chat != .ready {
                    refuse(.unavailable, "chat is not ready, and the run's messages go into its archive — doz chat status, or --no-archive to finish without one")
                }
                if let free = a.freeBytes, a.estimateBytes > free {
                    refuse(.unavailable, "the run's archive needs about \(DozableImages.formatBytes(a.estimateBytes)) and the store's disk has \(DozableImages.formatBytes(free)) free — free some space, or --no-archive")
                }
            }
        }
        if (verb == .archive || verb == .delete), o.removeSandboxes, removedNames.isEmpty {
            notes.append("no sandbox was made for it by Dozable: --remove-sandboxes removes nothing (adopted sandboxes are never removed)")
        }
        if !facts.known { notes.append("no daemon runs: what runs is read from the store and the sessions' holders, and checked again when you act") }
        let changes = Set(rows.filter(\.changes).map { $0.change ?? $0.name })
        var q = WorkspaceLifecycleQueue(width: max(1, facts.width), changes: changes.count)
        if changes.count > q.width {
            q.note = "at most \(q.width) agents change at once (ui.batch_concurrency); the others wait their turn — queued, N ahead"
        }
        var p = WorkspaceLifecyclePlan(workspace: n, verb: verb.rawValue, state: state)
        p.rows = rows
        p.keeps = keeps
        p.goes = goes
        p.refusals = refusals.map(\.1)
        p.refusalCode = refusals.first?.0.rawValue
        p.queue = q
        p.confirm = verb.confirm.rawValue
        p.confirmName = verb.confirm == .typed ? n : nil
        p.command = command(verb, n, o)
        p.commands = commands
        p.notes = notes
        p.factsKnown = facts.known
        p.templates = templates.isEmpty ? nil : templates
        p.archive = archivePlan
        p.rooms = roomRows.isEmpty ? nil : roomRows
        p.sha = sha(p, options: o)
        return p
    }

    /// The command that does it: `doz workspace VERB W [--remove-sandboxes [--no-keep-templates]] [--bin-folders]`.
    public static func command(_ verb: WorkspaceVerb, _ n: String, _ o: Options) -> String {
        var a = ["doz", "workspace", verb.rawValue, n]
        if verb == .archive || verb == .delete, o.removeSandboxes {
            a.append("--remove-sandboxes")
            if !o.keepTemplates { a.append("--no-keep-templates") }
        }
        if verb == .delete, o.binFolders { a.append("--bin-folders") }
        if verb == .finish || verb == .archive, o.noArchive { a.append("--no-archive") }
        return a.joined(separator: " ")
    }

    static func nowWords(_ f: AgentFacts) -> String {
        switch f.now {
        case .running: "running"
        case .booting: "starting"
        case .paused: "paused"
        case .asleep: "asleep"
        case .off: "shut down"
        case .failed: "failed"
        case .ended: "ended"
        case .notStarted: "not started"
        case .gone: "gone"
        case .elsewhere: "elsewhere"
        }
    }

    /// A free template name for sandbox `s`: `S-tpl`, else `S-tpl-2`… (1–40 of a-z 0-9 -).
    static func templateName(_ s: String, taken: Set<String>) -> String {
        let base = String(s.prefix(34)) + "-tpl"
        if !taken.contains(base) { return base }
        var i = 2
        while taken.contains(base + "-\(i)") { i += 1 }
        return base + "-\(i)"
    }

    /// Why folder `p` must not go to the Bin (nil: it may): `/`, this Mac's home or a folder above it, the store or a folder
    /// around or inside it, or a folder another workspace or a sandbox uses (or one inside or around it) — named.
    public static func binRefusal(_ p: String, workspace n: String, facts: Facts) -> String? {
        func within(_ a: String, _ b: String) -> Bool { a == b || a.hasPrefix(b.hasSuffix("/") ? b : b + "/") }
        let path = p.count > 1 && p.hasSuffix("/") ? String(p.dropLast()) : p
        let shown = DisplayPath.tilde(path)
        if path == "/" || path.isEmpty { return "\(shown) is the disk's root — never moved to the Bin" }
        if within(facts.home, path) { return "\(shown) is your home folder\(path == facts.home ? "" : " or holds it") — never moved to the Bin" }
        if within(path, facts.store) || within(facts.store, path) { return "\(shown) holds Dozable's store — never moved to the Bin" }
        for (other, who) in facts.foldersInUse.sorted(by: { $0.key < $1.key }) where within(path, other) || within(other, path) {
            return "\(shown) is used by \(who) — never moved to the Bin while it is"
        }
        return nil
    }

    /// The plan's identity: what it does to whom, its flags and its refusals — never sizes, activity or wording that moves
    /// by itself — so a plan read a moment later has the same sha unless something that matters changed. Order-independent.
    static func sha(_ p: WorkspaceLifecyclePlan, options o: Options) -> String {
        var parts = ["v1", p.workspace, p.verb, o.removeSandboxes ? "rm" : "", o.keepTemplates ? "tpl" : "", o.binFolders ? "bin" : ""]
        parts += p.rows.sorted { $0.name < $1.name }.map { [$0.name, $0.role, $0.place, $0.isolation, $0.now, $0.after, $0.changes ? "1" : "0"].joined(separator: "\u{1F}") }
        parts += p.goes.map { $0.text + ($0.path ?? "") }.sorted()
        parts += p.refusals.sorted()
        parts += (p.rooms ?? []).map { "room:\($0.room):\($0.after)" }
        // The archive's shape — never its counts or sizes, which move by themselves.
        if let a = p.archive {
            parts += ["archive", a.off ? "off" : "on", a.path ?? "", a.rooms.map(\.room).joined(separator: ","),
                      a.transcripts.map { "\($0.agent):\($0.source)" }.joined(separator: ",")]
        }
        let d = Data(parts.joined(separator: "\u{1E}").utf8)
        return SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined().prefix(16).description
    }
}

/// One agent in a lifecycle plan: what it is now, what it becomes, how it comes back.
public struct WorkspaceLifecycleRow: Codable, Equatable, Sendable {
    public var name: String
    /// `manager`, `worker` or `adopted`.
    public var role: String
    public var place: String
    /// `vm`, `fenced`, `unfenced` or `elsewhere`.
    public var isolation: String
    public var now: String
    public var activity: String?
    public var after: String
    public var back: String
    /// The verb changes it.
    public var changes: Bool
    /// The change it is part of (its place: two workers sharing a sandbox are one change).
    public var change: String?
    public var bot: String?
    public init(name: String, role: String, place: String, isolation: String, now: String, activity: String? = nil, after: String, back: String,
                changes: Bool, change: String? = nil, bot: String? = nil) {
        self.name = name; self.role = role; self.place = place; self.isolation = isolation; self.now = now; self.activity = activity
        self.after = after; self.back = back; self.changes = changes; self.change = change; self.bot = bot
    }
}

/// Something kept or gone, with its size or path when it has one.
public struct WorkspaceLifecycleItem: Codable, Equatable, Sendable {
    public var text: String
    public var bytes: Int64?
    public var path: String?
    public init(_ text: String, bytes: Int64? = nil, path: String? = nil) { self.text = text; self.bytes = bytes; self.path = path }
}

/// How many changes run at once.
public struct WorkspaceLifecycleQueue: Codable, Equatable, Sendable {
    public var width: Int
    public var changes: Int
    public var note: String?
    public init(width: Int, changes: Int, note: String? = nil) { self.width = width; self.changes = changes; self.note = note }
}

/// `workspace-lifecycle-plan`'s answer — nothing was written, no daemon started, no keychain item read.
public struct WorkspaceLifecyclePlan: Codable, Equatable, Sendable {
    public var workspace: String
    public var verb: String
    /// The workspace's state now (`WorkspaceState`'s raw value).
    public var state: String
    public var rows: [WorkspaceLifecycleRow] = []
    public var keeps: [WorkspaceLifecycleItem] = []
    public var goes: [WorkspaceLifecycleItem] = []
    /// Everything it would refuse, at once; the first one's code (`HostError.Code`) — a dry run exits as the verb would.
    public var refusals: [String] = []
    public var refusalCode: String?
    public var queue = WorkspaceLifecycleQueue(width: 3, changes: 0)
    /// `none`, `yes` or `typed` (the name: `confirmName`).
    public var confirm = "none"
    public var confirmName: String?
    /// The command that does it, and today's per-agent equivalents.
    public var command = ""
    public var commands: [String] = []
    public var notes: [String] = []
    /// A daemon answered (false: read in-process — checked again when acting).
    public var factsKnown = true
    /// Archive and delete with `--remove-sandboxes --keep-templates`: sandbox → the template kept of it.
    public var templates: [String: String]?
    /// Finish (and archive of a workspace not finished): the run's evidence archive. Additive.
    public var archive: WorkspaceArchivePlan?
    /// Finish: each room and what becomes of it (an owned room is closed, a linked one is not). Additive.
    public var rooms: [WorkspaceLifecycleRoomRow]?
    /// The plan's identity: a verb sent with `ifPlan` is refused when the plan it builds has another.
    public var sha = ""
    public init(workspace: String, verb: String, state: String) { self.workspace = workspace; self.verb = verb; self.state = state }
}

/// The archive section of a finish's plan: where the run's archive goes, the messages per room, each agent's
/// conversations and where they come from, the screens kept, and a size estimate.
public struct WorkspaceArchivePlan: Codable, Equatable, Sendable {
    public struct Room: Codable, Equatable, Sendable { public var room: String; public var messages: Int? }
    public struct Transcripts: Codable, Equatable, Sendable { public var agent: String; public var source: String; public var files: Int? }
    /// `--no-archive`: none is written.
    public var off: Bool
    public var run: String?
    /// Relative to the store.
    public var path: String?
    public var rooms: [Room] = []
    public var transcripts: [Transcripts] = []
    public var screens: [String] = []
    public var estimateBytes: Int64?
    public init(off: Bool) { self.off = off }
}

/// A room in a finish's plan: what becomes of it.
public struct WorkspaceLifecycleRoomRow: Codable, Equatable, Sendable {
    public var room: String
    public var label: String
    public var owned: Bool
    public var after: String
    public init(room: String, label: String, owned: Bool, after: String) { self.room = room; self.label = label; self.owned = owned; self.after = after }
}
