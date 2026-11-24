import DozableChat
import DozableKit
import Foundation

// `workspace-state`: what is true about a space workspace beside what its file says (`SpaceState`), built by
// `SpaceStateBuilder` from the merged spec `up` recorded beside the record (`<store>/workspaces/W/space.json` — never the
// space file, never YAML), the record and its reference, and the facts the daemon holds: each agent's place and its
// program's status, the sandboxes' phases, the folders (looked at, never opened), the chat server's rooms and participants.
// Read-only; answered in-process with no daemon (`factsKnown` false: every item `unknown`). docs/engineering/workspaces.md,
// "Space files".

extension HostCore {
    /// The space a workspace was made from: its record, its reference and what the recorded spec asks — or why there is none.
    func spaceStateInputs(_ n: String) throws -> (WorkspaceRecord, SpaceRecordRef, SpaceIntent) {
        let rec = try workspaceRecord(n)
        guard let ref = SpaceRecordRef.of(rec) else { throw HostError(.notFound, "\(n) was not made from a space file") }
        let folder = WorkspaceStore.resolved(workspaces.folder(n))
        let data: Data
        do { data = try MacFenceHostFS.readRegular(folder + "/space.json", maximum: SpaceRequest.maximumBytes) } catch {
            throw HostError(.notFound, "\(n)'s space was recorded by an older doz — doz workspace up -f FILE records it again")
        }
        guard let doc = try? ChatJSON.parse(data), case .object = doc else { throw HostError(.failed, "\(n)'s recorded space cannot be read") }
        let checked = SpaceValidator.checkMerged(doc, SpaceLocator(sources: ref.sources ?? [], origins: [:]), profiles: [])
        guard !checked.problems.contains(where: \.isError) else { throw HostError(.failed, "\(n)'s recorded space no longer validates — doz workspace up -f FILE") }
        return (rec, ref, SpaceIntent.compile(checked.model, doc, SpaceLocator(sources: ref.sources ?? [], origins: [:])))
    }

    /// `workspace-state` — for EVERY workspace (751): one made from a space file from its recorded spec, any other (and one
    /// whose spec an older doz recorded) from its record (`RecordStateBuilder`). Not found only when there is no such
    /// workspace. Each agent's condition rides along when asked (`withConditions`: the CLI's `--json`).
    func workspaceState(_ w: WorkspaceRequest) async throws -> SpaceState {
        let n = try workspaceName(w)
        let rec0 = try workspaceRecord(n)
        // Who reads it: set by the dashboard's server from the principal (never a browser's field); the person's chat name is
        // the daemon's own directory's.
        let viewer = SpaceStateViewer(macSessions: w.macSessionsHidden != true, askText: w.askTextHidden != true, answerHere: w.asksAnsweredElsewhere != true,
                                      chatName: (try? ChatDirectory.load(chatPaths))?.human)
        let log = (try? workspaces.log(n)) ?? []
        var note: String?
        if SpaceRecordRef.of(rec0) != nil {
            do {
                let (rec, ref, intent) = try spaceStateInputs(n)
                let facts = await spaceStateFacts(rec, intent)
                var s = SpaceStateBuilder.build(intent: intent, ref: ref, record: rec, facts: facts, host: Self.spaceStateHost(), now: Date(), viewer: viewer)
                if w.withConditions == true {
                    s.agentConditions = WorkspaceConditionsBuilder.build(record: rec, facts: facts, log: log, from: "space-file", hidden: !viewer.macSessions)
                    if viewer.macSessions { s.places = placeStates(rec, intent: intent, conditions: s.agentConditions) }
                }
                return s
            } catch let e as HostError where e.code == .notFound {
                note = e.message              // its spec was recorded by an older doz: the record answers
            }
        }
        let facts = await recordStateFacts(rec0)
        let conditions = WorkspaceConditionsBuilder.build(record: rec0, facts: facts, log: log, from: "record")
        var s = RecordStateBuilder.build(record: rec0, facts: facts, conditions: conditions, host: Self.spaceStateHost(), now: Date(), viewer: viewer, note: note)
        if !viewer.macSessions { s = s.hiding(RecordStateBuilder.macSubjects(rec0)) }
        if w.withConditions == true {
            s.agentConditions = viewer.macSessions ? conditions : WorkspaceConditionsBuilder.build(record: rec0, facts: facts, log: log, from: "record", hidden: true)
            if viewer.macSessions { s.places = placeStates(rec0, intent: nil, conditions: conditions) }
        }
        return s
    }

    /// 774: the workspace's places with their sessions: the space file's places (each agent in the one it names — the
    /// record's `placeName`, else the file's `where:`), then a derived place for each other agent. A session on this Mac
    /// shows its own fence's tag when it runs fenced (`MacFenceRecord.tag`: one per session, never shared).
    func placeStates(_ rec: WorkspaceRecord, intent: SpaceIntent?, conditions: WorkspaceConditions?) -> [WorkspacePlaceState] {
        let sessions = mac.records().sessions
        let declared = intent?.places ?? []
        let named = Dictionary((intent?.agents ?? []).compactMap { a in a.place.map { (a.name, $0) } }, uniquingKeysWith: { a, _ in a })
        // A sandbox place of the file runs as `<space>-<name>`: an agent there is in it by its sandbox's place name.
        let bySandbox = Dictionary((intent?.sandboxes ?? []).map { ($0.placeName, $0.name) }, uniquingKeysWith: { a, _ in a })
        func record(_ a: WorkspaceAgent) -> MacSessionRecord? { a.place.mac == true ? a.place.session.flatMap { sessions[$0] } : nil }
        return WorkspacePlaces.states(
            declared: declared, agents: rec.agents,
            placeOf: { a in a.placeName ?? named[a.name].flatMap { n in declared.contains { $0.name == n } ? n : nil } ?? a.place.sandbox.flatMap { bySandbox[$0] } },
            fence: { a in record(a)?.fence.map { "doz-fence:" + $0.tag } },
            fenced: { a in record(a).map { $0.fence != nil } },
            state: { a in conditions?.agents[a.name]?.condition ?? "unknown" })
    }

    /// The facts of a workspace with no space file: what `spaceStateFacts` gathers for its record's agents and rooms, the
    /// phases of the sandboxes its agents run in, and its folders (looked at, never opened).
    func recordStateFacts(_ rec: WorkspaceRecord) async -> SpaceStateFacts {
        let none = SpaceIntent(space: rec.name, title: rec.name, owner: "", brief: "", archive: SpaceIntent.Sourced("off", "the default"))
        var f = await spaceStateFacts(rec, none)
        guard f.known else { return f }
        for a in rec.agents where a.endedAt == nil {
            if let s = a.place.sandbox, f.sandboxes[s] == nil, let m = managed[s] { f.sandboxes[s] = await effectivePhase(m).rawValue }
        }
        for x in rec.folders {
            var d: ObjCBool = false
            f.folders[x.path] = FileManager.default.fileExists(atPath: x.path, isDirectory: &d) && d.boolValue
        }
        return f
    }

    /// This Mac's name as a person reads it: the setting `daemon.mac_name` (`MacDisplayName`) — never its network name.
    nonisolated static func spaceStateHost(_ env: [String: String] = ProcessInfo.processInfo.environment) -> String {
        MacDisplayName.current(env)
    }

    /// The facts of one space workspace now. With no daemon: nothing known but the record's own (its last up).
    func spaceStateFacts(_ rec: WorkspaceRecord, _ i: SpaceIntent) async -> SpaceStateFacts {
        let base = spaceFactsHome()
        var f = SpaceStateFacts(known: !readOnly, home: base.home, projectsDir: base.projectsDir)
        let log = (try? workspaces.log(rec.name)) ?? []
        if let last = log.last(where: { $0.action == "space-up" || $0.action == "space-down" }), last.action == "space-up",
           last.reason?.contains("stopped at a failure") == true { f.upStopped = true }
        guard !readOnly else { return f }

        let wantsMac = rec.agents.contains { $0.place.mac == true && $0.endedAt == nil } || i.agents.contains { $0.session != nil }
        let macs = wantsMac ? await workspaceMacRows() : [:]
        func mac(_ row: SessionRow?, manager: Bool) -> SpaceStateFacts.Agent { Self.macAgentFact(row, manager: manager) }
        f.agents = await workspaceAgentFacts(rec, macs: macs)
        for a in i.agents { if let s = a.session { f.sessions[s] = mac(macs[s], manager: false) } }
        for s in i.sandboxes { if let m = managed[s.placeName] { f.sandboxes[s.placeName] = await effectivePhase(m).rawValue } }

        var paths: [String] = i.folders.compactMap(\.path).map { f.expand($0) }
        paths += SpaceUp.keptFolderPaths(i, spaceFactsHome()).map(\.path)
        paths += (SpaceRecordRef.of(rec)?.scratch ?? []).map(\.path)
        for p in paths {
            var d: ObjCBool = false
            f.folders[p] = FileManager.default.fileExists(atPath: p, isDirectory: &d) && d.boolValue
        }

        if let idx = try? ChatRoomIndex.load(chatPaths) {
            f.goneRooms = Set(idx.tombstones.map(\.name))
            for (room, e) in idx.rooms where e.closedAt != nil { f.closedRooms.insert(room) }
        }
        if rec.flags.finishedAt != nil, rec.flags.archivedAt == nil, let last = rec.runs.last, !last.isOpen {
            for r in ownedRooms(rec) { f.closedRooms.insert(r) }
        }
        if let chat = workspaceChat, await chat.readiness() == .ready {
            f.rooms = try? chat.rooms()
            f.archivedRooms = (try? chat.archivedRooms()) ?? []
            if let d = try? ChatDirectory.load(chatPaths) { f.participants = Set(d.participants.map(\.name) + (d.human.map { [$0] } ?? [])) }
            // The open asks of the workspace's own rooms (one look on the owner's socket, as `chat-asks`).
            let mine = Set(rec.rooms.filter { $0.goneAt == nil }.map(\.chatRoom))
            f.asks = (try? chat.openAsks())?.filter { mine.contains($0.room) }
        }
        return f
    }
}

// MARK: frames during a run (`SpaceStateRecorder`)

/// `workspace-run-frames`' answer: a run's frames in order and, once it is archived, its archive checked now.
public struct SpaceRunDetail: Codable, Equatable, Sendable {
    public struct Frame: Codable, Equatable, Sendable {
        /// `NNNNNN.json`, `last.json`, or `record` (a run from before frames were kept: its last state, built now).
        public var file: String
        public var label: String
        public var at: String
        public var state: SpaceState
    }
    public struct ArchiveFile: Codable, Equatable, Sendable {
        public var path: String
        public var bytes: Int
        public var sha256: String
    }
    public struct Archive: Codable, Equatable, Sendable {
        /// Where it is kept, with `~`.
        public var path: String
        public var files: [ArchiveFile]
        /// Every file the manifest lists is there with the sha256 it lists.
        public var verified: Bool
        public var mismatched: [String]
    }
    public var workspace: String
    public var id: String
    public var frames: [Frame]
    /// Past the frames' bound: only the last state was kept after it.
    public var capped: Bool?
    public var archive: Archive?
    public var note: String?
    public init(workspace: String, id: String, frames: [Frame], capped: Bool? = nil, archive: Archive? = nil, note: String? = nil) {
        self.workspace = workspace; self.id = id; self.frames = frames; self.capped = capped; self.archive = archive; self.note = note
    }
}

extension HostCore {
    static let noFramesLabel = "the last state (no frames were kept before this version)"

    nonisolated func spaceRunFolder(_ n: String, _ run: String) -> String { WorkspaceStore.resolved(workspaces.folder(n)) + "/runs/\(run)" }
    nonisolated func spaceFrameFolder(_ n: String, _ run: String) -> String { spaceRunFolder(n, run) + "/frames" }

    /// Something changed that a space's state may show (`workspace` nil: any). One recompute per second at most; never a timer.
    nonisolated func spaceFramesPoke(_ workspace: String?, _ label: String) {
        guard !readOnly, spaceFrames.poke(workspace, label) else { return }
        let wait = spaceFrames.debounce
        Task { try? await Task.sleep(for: wait); await self.spaceFramesFlush() }
    }

    func spaceFramesFlush() async {
        let (targets, labels) = spaceFrames.take()
        let names = targets.map { $0.sorted() } ?? workspaces.records().filter { $0.openRun != nil && SpaceRecordRef.of($0) != nil }.map(\.name)
        for n in names { await spaceFrameRecord(n, label: labels[n] ?? labels["*"] ?? "a change") }
    }

    /// One frame of `n`'s open run — or of `closed`, the run finish just closed (its final frame, always written) — when its
    /// sha differs from the last frame's. Answers whether one was written.
    @discardableResult
    func spaceFrameRecord(_ n: String, label: String, closed: WorkspaceRun? = nil) async -> Bool {
        guard !readOnly, WorkspaceName.isValid(n), let (rec, ref, intent) = try? spaceStateInputs(n) else { return false }
        guard let run = closed ?? rec.openRun, WorkspaceRuns.isValidID(run.id) else { return false }
        var facts = await spaceStateFacts(rec, intent)
        facts.dropMessages()
        let s = SpaceStateBuilder.build(intent: intent, ref: ref, record: rec, facts: facts, host: Self.spaceStateHost(), now: Date(), viewer: .owner)
        // The run may have closed while the facts were gathered: a frame only ever lands in its own run's folder.
        if closed == nil, (try? workspaceRecord(n))?.openRun?.id != run.id { return false }
        let key = n + "/" + run.id
        let folder = spaceFrameFolder(n, run.id)
        var m = spaceFrames.memo(key) { Self.frameMemo(folder) }
        guard closed != nil || s.sha != m.lastSHA else { return false }
        let data = SpaceStateRecorder.Frame(at: SpaceState.time(Date()), label: label, state: s).bytes
        do {
            try MacFenceHostFS.ensureDirectory(folder, mode: 0o700)
            if m.capped || m.count >= SpaceStateRecorder.maximumFrames || m.bytes + data.count > SpaceStateRecorder.maximumBytes {
                try MacFenceHostFS.writeAtomically(data, dir: folder, name: SpaceStateRecorder.lastName, mode: 0o600)
                if !m.capped {
                    m.capped = true
                    _ = try? await workspaceUpdate(n) { r in
                        if let i = r.runs.firstIndex(where: { $0.id == run.id }) { r.runs[i].framesCapped = true }
                        return []
                    }
                }
            } else {
                m.count += 1
                try MacFenceHostFS.writeAtomically(data, dir: folder, name: String(format: "%06d.json", m.count), mode: 0o600)
                m.bytes += data.count
            }
            TimelineSignal.poke(store.root.path, .runs)               // 747: the timeline reads the frame
            m.lastSHA = s.sha
            spaceFrames.setMemo(key, m)
            return true
        } catch {
            note(nil, "workspace \(n): a frame of run \(run.id) could not be written: \(error)")
            return false
        }
    }

    /// What a run's folder of frames holds now (read once per run).
    nonisolated static func frameMemo(_ folder: String) -> SpaceStateRecorder.Memo {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).filter(SpaceStateRecorder.isFrameName).sorted()
        var m = SpaceStateRecorder.Memo(count: 0, bytes: 0, lastSHA: nil, capped: names.contains(SpaceStateRecorder.lastName))
        for f in names where f != SpaceStateRecorder.lastName {
            m.count = max(m.count, Int(f.prefix(6)) ?? 0)
            var st = stat()
            if lstat(folder + "/" + f, &st) == 0 { m.bytes += Int(st.st_size) }
        }
        let last = m.capped ? SpaceStateRecorder.lastName : names.last { $0 != SpaceStateRecorder.lastName }
        if let last, let d = try? MacFenceHostFS.readRegular(folder + "/" + last, maximum: 4 << 20),
           let f = try? JSONDecoder().decode(SpaceStateRecorder.Frame.self, from: d) { m.lastSHA = f.state.sha }
        return m
    }

    /// The frames of a run's folder, in order (`last.json` last), for its archive or a reader: name and bytes.
    func spaceFrameFiles(_ n: String, _ run: String) -> [(name: String, data: Data)] {
        let folder = spaceFrameFolder(n, run)
        guard MacFenceHostFS.kind(folder) == S_IFDIR else { return [] }
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).filter(SpaceStateRecorder.isFrameName).sorted {
            ($0 == SpaceStateRecorder.lastName ? 1 : 0, $0) < ($1 == SpaceStateRecorder.lastName ? 1 : 0, $1)
        }
        var out: [(String, Data)] = []
        var total = 0
        for f in names {
            guard let d = try? MacFenceHostFS.readRegular(folder + "/" + f, maximum: 4 << 20) else { continue }
            total += d.count
            if total > SpaceStateRecorder.maximumBytes + (4 << 20) { break }
            out.append((f, d))
        }
        return out
    }

    /// Once a run's archive verifies (it holds the frames), its folder of frames is removed — never before.
    func spaceFramesArchived(_ n: String, _ run: String, archive: String) {
        let root = storeRoot + "/" + archive
        guard MacFenceHostFS.kind(spaceRunFolder(n, run)) == S_IFDIR, RunArchive.verify(root: root).ok else { return }
        do { try MacFenceHostFS.remove(spaceRunFolder(n, run)) } catch {
            note(nil, "workspace \(n): the frames of run \(run) are archived but their folder could not be removed: \(error)")
        }
        spaceFrames.forget(n + "/" + run)
    }

    /// `workspace-run-frames`.
    func workspaceRunFrames(_ w: WorkspaceRequest) async throws -> SpaceRunDetail {
        let n = try workspaceName(w)
        let rec = try workspaceRecord(n)
        guard let id = w.run, WorkspaceRuns.isValidID(id), let run = rec.runs.first(where: { $0.id == id }) else {
            throw HostError(.notFound, "\(n) has no such run (doz workspace runs \(n))")
        }
        var d = SpaceRunDetail(workspace: n, id: id, frames: [], capped: run.framesCapped)
        func frames(_ files: [(name: String, data: Data)]) -> [SpaceRunDetail.Frame] {
            files.compactMap { f in
                (try? JSONDecoder().decode(SpaceStateRecorder.Frame.self, from: f.data)).map { SpaceRunDetail.Frame(file: f.name, label: $0.label, at: $0.at, state: $0.state) }
            }
        }
        let own = spaceFrameFiles(n, id)
        if !own.isEmpty { d.frames = frames(own) }
        if let a = run.archive {
            let root = storeRoot + "/" + a
            let v = RunArchive.verify(root: root)
            let files = v.manifest?.files ?? []
            d.archive = SpaceRunDetail.Archive(path: DisplayPath.tilde(root), files: files.map { .init(path: $0.path, bytes: $0.bytes, sha256: $0.sha256) },
                                               verified: v.ok, mismatched: v.mismatched)
            if own.isEmpty, v.manifest != nil {
                let fd = open(root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if fd >= 0 {
                    let folder = ExportFolder(adopting: fd, path: root)
                    var archived: [(name: String, data: Data)] = []
                    for f in files where f.path.hasPrefix("frames/") && !v.mismatched.contains(f.path) {
                        if let b = try? folder.read(f.path) { archived.append((String(f.path.dropFirst(7)), Data(b))) }
                    }
                    d.frames = frames(archived)
                }
            }
        }
        // A run from before frames were kept: its last state, built now from the record.
        if d.frames.isEmpty, let (r, ref, intent) = try? spaceStateInputs(n) {
            var facts = await spaceStateFacts(r, intent)
            facts.dropMessages()
            let s = SpaceStateBuilder.build(intent: intent, ref: ref, record: r, facts: facts, host: Self.spaceStateHost(), now: Date(), viewer: .owner)
            d.frames = [SpaceRunDetail.Frame(file: "record", label: Self.noFramesLabel, at: s.observedAt, state: s)]
            d.note = Self.noFramesLabel
        }
        if w.macSessionsHidden == true, let (r, _, intent) = try? spaceStateInputs(n) {
            let hide = SpaceStateBuilder.macSubjects(intent: intent, record: r)
            for i in d.frames.indices { d.frames[i].state = d.frames[i].state.hiding(hide) }
        }
        return d
    }

    /// How many frames a run kept (its folder's, else its archive's), for its row; nil: none.
    func spaceFrameCount(_ n: String, _ run: WorkspaceRun) -> Int? {
        let own = Self.frameMemo(spaceFrameFolder(n, run.id))
        if own.count > 0 || own.capped { return own.count + (own.capped ? 1 : 0) }
        // The archive's manifest only (a row never re-hashes an archive: `--frames` does).
        guard let a = run.archive, let d = try? MacFenceHostFS.readRegular(storeRoot + "/" + a + "/manifest.json", maximum: 64 << 20),
              let m = try? HostWire.decoder.decode(RunArchive.Manifest.self, from: d) else { return nil }
        let k = m.files.filter { $0.path.hasPrefix("frames/") }.count
        return k > 0 ? k : nil
    }

    /// A session on this Mac as a fact: none (a manager's: not started), gone, ended or running.
    nonisolated static func macAgentFact(_ row: SessionRow?, manager: Bool) -> SpaceStateFacts.Agent {
        guard let row else { return SpaceStateFacts.Agent(state: manager ? "ended" : "missing", detail: manager ? "not started" : nil) }
        if row.gone == true { return SpaceStateFacts.Agent(state: "missing") }
        if row.ended { return SpaceStateFacts.Agent(state: "ended") }
        return SpaceStateFacts.Agent(state: "running", status: row.status)
    }

    /// What the daemon holds of each agent of `rec` not ended (`SpaceStateFacts.agents`): its sandbox's phase and its
    /// program's status, or its session on this Mac (`macs`). Never a guest call — `ls` reads it for every workspace (764).
    func workspaceAgentFacts(_ rec: WorkspaceRecord, macs: [String: SessionRow]) async -> [String: SpaceStateFacts.Agent] {
        var out: [String: SpaceStateFacts.Agent] = [:]
        func mac(_ row: SessionRow?, manager: Bool) -> SpaceStateFacts.Agent { Self.macAgentFact(row, manager: manager) }
        for a in rec.agents where a.endedAt == nil {
            if let s = a.place.sandbox {
                guard let m = managed[s] else {
                    out[a.name] = SpaceStateFacts.Agent(state: a.isManager ? "ended" : "missing", detail: a.isManager ? "not started" : nil)
                    continue
                }
                let phase = await effectivePhase(m)
                let mine: SessionStatus? = a.isWorker && a.place.session != nil ? statuses[s]?[a.place.session!]
                    : SessionStatus.mostUrgent(Array((statuses[s] ?? [:]).values))
                switch phase {
                case .running, .booting: out[a.name] = SpaceStateFacts.Agent(state: "running", status: mine)
                case .paused, .asleep, .hibernated: out[a.name] = SpaceStateFacts.Agent(state: "asleep", detail: "in \(s), \(phase.rawValue)")
                case .failed: out[a.name] = SpaceStateFacts.Agent(state: "ended", detail: "in \(s), failed", failed: true)
                case .off: out[a.name] = SpaceStateFacts.Agent(state: "ended", detail: "in \(s), shut down")
                }
            } else if a.place.mac == true, let s = a.place.session {
                out[a.name] = mac(macs[s], manager: a.isManager)
            } else {
                out[a.name] = SpaceStateFacts.Agent(state: "unknown", detail: "elsewhere: not run by Dozable")
            }
        }
        return out
    }
}
