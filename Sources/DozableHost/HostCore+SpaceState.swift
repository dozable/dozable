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

    /// `workspace-state`.
    func workspaceState(_ w: WorkspaceRequest) async throws -> SpaceState {
        let n = try workspaceName(w)
        let (rec, ref, intent) = try spaceStateInputs(n)
        let facts = await spaceStateFacts(rec, intent)
        return SpaceStateBuilder.build(intent: intent, ref: ref, record: rec, facts: facts, host: Self.spaceStateHost(), now: Date(),
                                       viewer: SpaceStateViewer(macSessions: w.macSessionsHidden != true))
    }

    /// This Mac's name as a person reads it (its host name's first label); in a guarded test run `DOZ_TEST_MAC_NAME`.
    nonisolated static func spaceStateHost(_ env: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if TestSafety.guarded(env) { return env["DOZ_TEST_MAC_NAME"].flatMap { $0.isEmpty ? nil : $0 } ?? "this Mac" }
        var buf = [CChar](repeating: 0, count: 256)
        guard gethostname(&buf, buf.count) == 0 else { return "this Mac" }
        let first = String(cString: buf).split(separator: ".").first.map(String.init) ?? ""
        return first.isEmpty ? "this Mac" : first
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
        func mac(_ row: SessionRow?, manager: Bool) -> SpaceStateFacts.Agent {
            guard let row else { return SpaceStateFacts.Agent(state: manager ? "ended" : "missing", detail: manager ? "not started" : nil) }
            if row.gone == true { return SpaceStateFacts.Agent(state: "missing") }
            if row.ended { return SpaceStateFacts.Agent(state: "ended") }
            return SpaceStateFacts.Agent(state: "running", status: row.status)
        }
        for a in rec.agents where a.endedAt == nil {
            if let s = a.place.sandbox {
                guard let m = managed[s] else {
                    f.agents[a.name] = SpaceStateFacts.Agent(state: a.isManager ? "ended" : "missing", detail: a.isManager ? "not started" : nil)
                    continue
                }
                let phase = await effectivePhase(m)
                let mine: SessionStatus? = a.isWorker && a.place.session != nil ? statuses[s]?[a.place.session!]
                    : SessionStatus.mostUrgent(Array((statuses[s] ?? [:]).values))
                switch phase {
                case .running, .booting: f.agents[a.name] = SpaceStateFacts.Agent(state: "running", status: mine)
                case .paused, .asleep, .hibernated: f.agents[a.name] = SpaceStateFacts.Agent(state: "asleep", detail: "in \(s), \(phase.rawValue)")
                case .failed: f.agents[a.name] = SpaceStateFacts.Agent(state: "ended", detail: "in \(s), failed", failed: true)
                case .off: f.agents[a.name] = SpaceStateFacts.Agent(state: "ended", detail: "in \(s), shut down")
                }
            } else if a.place.mac == true, let s = a.place.session {
                f.agents[a.name] = mac(macs[s], manager: a.isManager)
            } else {
                f.agents[a.name] = SpaceStateFacts.Agent(state: "unknown", detail: "elsewhere: not run by Dozable")
            }
        }
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
        }
        return f
    }
}
