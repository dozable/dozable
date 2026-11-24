import Darwin
import Foundation

// 776: a workspace's identities and sessions (the model's L1 and L2). An identity is who an agent is — its name, role, kind,
// bot or participant, its token (by reference), its memory, its default place — and who owns it: the workspace (a lasting
// identity: `worker add W NAME`, a bot, the manager, an adopted agent) or the run (`worker add W --task …` with no name, a
// worker declared at `new`). A session is its running program in a place. The record keeps the two apart (`identities[]`,
// `sessions[]`; `WorkspaceIdentityHalf`, `WorkspaceSessionHalf`).
//
// What each verb does to an identity:
//   - `worker end` ends the SESSION: a run-owned identity goes with it (its participant removed); a lasting one stays, with
//     its memory, and its token is revoked (no session holds it).
//   - each start (`workspace start`, `run`, `wake` of a stopped session) ROTATES a daemon-made token: a new one issued, the
//     old one refused (`tokenIssuedAt`).
//   - `down` (finish, for a workspace made without a space file) stops every session, revokes every lasting identity's token,
//     and ends the run's identities; their memory and the lasting identities are KEPT.
//   - `down --purge` retires the lasting identities: each one's kept memory copied into the store's archive and hash-checked,
//     then removed; its participant removed.
//   - `worker reset W NAME --yes` clears a lasting identity's kept memory — the only other way it goes.
//
// Memory is what Dozable keeps of an identity's own: a fenced session's private agent folder is cleared at each open but its
// transcripts, so its memory (`projects/*/memory/`) is captured into `<store>/workspaces/W/memory/NAME/` when its session
// stops, sleeps or ends, and seeded back into its next fenced session (`SpaceMemory`). An unfenced session's memory is the
// person's own (`~/.claude`) and a sandbox's is on its disk: Dozable never copies or removes either.
// docs/engineering/workspace-model.md ("Identity and Session"); `WorkspaceIdentityTests`.

extension HostCore {
    /// Where an identity's kept memory is: `<store>/workspaces/W/memory/NAME` (resolved).
    func identityMemoryFolder(_ n: String, _ name: String) -> String {
        WorkspaceStore.resolved(workspaces.folder(n)) + "/memory/" + name
    }

    /// An identity's kept memory: present, files and bytes, and its folder — never its content.
    func identityMemory(_ n: String, _ name: String) -> WorkspaceIdentityMemory {
        let dir = identityMemoryFolder(n, name)
        guard MacFenceHostFS.kind(dir + "/" + SpaceMemory.manifestName) == S_IFREG,
              let d = try? MacFenceHostFS.readRegular(dir + "/" + SpaceMemory.manifestName, maximum: 1 << 20),
              let m = try? HostWire.decoder.decode(SpaceMemory.Manifest.self, from: d) else { return WorkspaceIdentityMemory() }
        var bytes = 0
        for f in m.files {
            var st = stat()
            if lstat(dir + "/" + f.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG { bytes += Int(st.st_size) }
        }
        return WorkspaceIdentityMemory(present: true, files: m.files.count, bytes: bytes, path: dir)
    }

    /// One identity as the CLI and the state show it.
    func workspaceIdentityRow(_ rec: WorkspaceRecord, _ a: WorkspaceAgent) -> WorkspaceIdentityRow {
        let role = a.isManager ? "manager" : a.isWorker ? "worker" : "adopted"
        var token: WorkspaceIdentityToken?
        if let b = a.bot, let br = bots.readOrEmpty().bot(b), br.token.keeper == "dozable" {
            token = WorkspaceIdentityToken(issuedAt: SpaceState.time(br.token.at))
        } else if let at = a.tokenIssuedAt {
            token = WorkspaceIdentityToken(issuedAt: SpaceState.time(at), revokedAt: a.tokenRevokedAt.map(SpaceState.time),
                                           heldBy: a.tokenTakenAt != nil ? "you" : nil)
        }
        let kind = a.kind ?? a.bot.flatMap { bots.readOrEmpty().bot($0)?.agent }
        return WorkspaceIdentityRow(name: a.name, id: a.id, role: role, kind: kind, lifetime: a.effectiveLifetime, bot: a.bot,
                                    place: a.place.display, memory: identityMemory(rec.name, a.name), token: token,
                                    hasSession: a.endedAt == nil)
    }

    /// Every identity of the workspace, in the record's order: one per name — its live entry, else its last (a lasting
    /// identity whose session ended). A retired one, and a run-owned one whose session ended, is not an identity any more.
    func workspaceIdentities(_ rec: WorkspaceRecord) -> [WorkspaceIdentityRow] {
        WorkspaceIdentities.current(rec).map { workspaceIdentityRow(rec, $0) }
    }

    /// Every session the workspace has now (not ended): its identity, its place, its state and since when.
    func workspaceSessions(_ rec: WorkspaceRecord, conditions: WorkspaceConditions?) -> [WorkspaceSessionRow] {
        WorkspaceIdentities.sessions(rec, conditions: conditions)
    }

    /// A lasting identity's memory kept: its fenced session's private agent folder's memory captured into the store. Nothing
    /// for a run-owned identity, an unfenced session (its memory is the person's own), a sandbox (its disk keeps it) or a
    /// folder with no memory in it (what is kept is never replaced by nothing). Best effort: a failure is a note.
    func keepIdentityMemory(_ n: String, _ a: WorkspaceAgent) -> [String] {
        guard a.isLasting, a.retiredAt == nil, a.isolation != "unfenced", a.place.mac == true, let s = a.place.session, !buildFlavor.isHelper else { return [] }
        guard let fence = mac.records().sessions[s]?.fence, fence.agentConfig == MacAgentConfig.privateMode,
              let places = try? mac.fencePlaces() else { return [] }
        let agentDir = MacFence.sessionFolder(places, session: s) + "/agent"
        guard MacFenceHostFS.kind(agentDir) == S_IFDIR else { return [] }
        do {
            guard !(try SpaceMemory.listing(agentDir)).isEmpty else { return [] }
            let count = try SpaceMemory.capture(agentDir: agentDir, into: identityMemoryFolder(n, a.name))
            try? workspaces.append(n, WorkspaceLogEntry(action: "memory-kept", agent: a.name, added: count))
            return []
        } catch {
            return ["\(a.name)'s memory was not kept: \(HostError.from(error).message)"]
        }
    }

    /// Each of `names`' lasting identities' memory kept (after a stop, a sleep or a finish).
    func keepIdentitiesMemory(_ n: String, _ names: [String]) {
        guard let rec = try? workspaceRecord(n) else { return }
        for a in rec.agents where names.contains(a.name) && a.endedAt == nil {
            for line in keepIdentityMemory(n, a) { note(nil, "workspace \(n): \(line)") }
        }
    }

    /// A daemon-made token revoked: its participant's token replaced by one nobody holds, the time recorded. Answers a note
    /// when chat could not take it.
    func revokeIdentityToken(_ n: String, _ name: String) async -> String? {
        guard let participants = botChat, (try? participants.directory().has(name)) == true else { return nil }
        do {
            try await participants.replaceToken(name, token: ChatTokens.make())
        } catch {
            return "\(name)'s token could not be revoked now (\(HostError.from(error).message)) — its next start replaces it"
        }
        let at = Date()
        _ = try? await workspaceUpdate(n) { r in
            for i in r.agents.indices where r.agents[i].name == name && r.agents[i].bot == nil { r.agents[i].tokenRevokedAt = at }
            return []
        }
        return nil
    }

    /// `down`: every lasting identity's daemon-made token revoked (a bot's is the bot's; an adopted agent's is its own).
    func revokeLastingTokens(_ n: String) async -> [String] {
        guard let rec = try? workspaceRecord(n) else { return [] }
        var notes: [String] = [], revoked: [String] = []
        for a in WorkspaceIdentities.current(rec) where a.isWorker && a.bot == nil && a.isLasting && a.tokenRevokedAt == nil && a.tokenTakenAt == nil {
            if let why = await revokeIdentityToken(n, a.name) { notes.append(why) } else { revoked.append(a.name) }
        }
        if !revoked.isEmpty { try? workspaces.append(n, WorkspaceLogEntry(action: "tokens-revoked", agent: revoked.joined(separator: ", "))) }
        return notes
    }

    /// `down` (finish): each run-owned worker still running ended — its identity goes with its session (its participant
    /// removed). Its place is kept (`doz worker end W NAME --rm` deletes it); nothing on disk goes.
    func endRunIdentities(_ n: String) async -> (ended: [String], notes: [String]) {
        guard let rec = try? workspaceRecord(n) else { return ([], []) }
        var ended: [String] = [], notes: [String] = []
        for a in rec.agents where a.isLiveWorker && !a.isLasting && a.bot == nil && a.pendingAt == nil {
            do {
                _ = try await workerEnd(WorkerRequest(workspace: n, name: a.name))
                ended.append(a.name)
            } catch {
                notes.append("\(a.name) (the run's) was not ended: \(HostError.from(error).message) — doz worker end \(n) \(a.name)")
            }
        }
        return (ended, notes)
    }

    /// An identity's kept memory removed — only after its copy in the store's archive (`archives/W/folders/RUN/memory-NAME`)
    /// verifies; a copy that does not verify keeps it (thrown). Answers the copy's path (nil: there was no memory).
    func removeIdentityMemoryAfterCopy(_ n: String, _ name: String, run: String?) throws -> String? {
        let dir = identityMemoryFolder(n, name)
        guard MacFenceHostFS.kind(dir) != nil else { return nil }
        let runID = run ?? WorkspaceRuns.nextID([], at: Date())
        let copy = try RunArchive.writeFolder(source: dir, name: "memory-" + name, workspace: n, run: runID, store: store, sweep: ExportSweep.forStore(store))
        try MacFenceHostFS.remove(dir)
        try? workspaces.append(n, WorkspaceLogEntry(action: "memory-reset", agent: name, reason: "--purge"))
        return copy
    }

    /// A lasting worker's identity retired: its participant removed (its token refused for good), its session ended, the
    /// identity marked retired. A bot's identity is never retired here (its token is the bot's).
    func retireIdentity(_ n: String, _ name: String) async throws {
        if let participants = botChat, (try? participants.directory().has(name)) == true { try await participants.remove(name) }
        let at = Date()
        _ = try await workspaceUpdate(n) { r in
            for i in r.agents.indices where r.agents[i].name == name && r.agents[i].retiredAt == nil && r.agents[i].bot == nil {
                r.agents[i].retiredAt = at
                if r.agents[i].endedAt == nil { r.agents[i].endedAt = at; r.agents[i].pendingAt = nil }
            }
            return [WorkspaceLogEntry(action: "identity-retired", agent: name, reason: "--purge")]
        }
    }

    /// `down --purge` (a workspace made without a space file): what it keeps of each lasting identity goes — its kept memory
    /// copied into the store's archive (hash-checked) and then removed — and a lasting worker whose participant the daemon
    /// made is retired (`retireIdentity`). A bot keeps its token and its place in chat (it is the bot's), an adopted agent its
    /// own. Only what Dozable keeps for this workspace goes — never the person's folders, a session's transcripts or a
    /// sandbox's disk. A memory whose copy does not verify is kept, and said, and its identity is not retired. Answers each
    /// identity purged (`agent/NAME`).
    func purgeIdentities(_ n: String, run: String?) async -> (purged: [String], notes: [String]) {
        guard let rec = try? workspaceRecord(n) else { return ([], []) }
        var purged: [String] = [], notes: [String] = []
        for a in WorkspaceIdentities.current(rec) where a.isLasting && (a.isWorker || a.isManager) {
            if a.pendingAt != nil { notes.append("\(a.name) is being added — not purged"); continue }
            var did = false
            do {
                if let copy = try removeIdentityMemoryAfterCopy(n, a.name, run: run) {
                    notes.append("\(a.name)'s memory removed; its copy is \(DisplayPath.tilde(storeRoot + "/" + copy))")
                    did = true
                }
            } catch {
                notes.append("\(a.name)'s memory is kept: \(HostError.from(error).message)")
                continue
            }
            if a.isWorker, a.bot == nil {
                do { try await retireIdentity(n, a.name); did = true } catch {
                    notes.append("\(a.name) was not retired: \(HostError.from(error).message)")
                }
            }
            if did { purged.append("agent/" + a.name) }
        }
        return (purged, notes)
    }

    /// 776: you took a worker identity's token yourself (`doz chat token NAME --new`): its new time recorded, and the token
    /// marked yours — Dozable no longer rotates or revokes it (taking it again replaces it). Its running session keeps the
    /// token it was given (refused from now on), as before.
    func workerTokenTaken(_ name: String) async {
        guard !readOnly else { return }
        let at = Date()
        for rec in workspaces.records() where rec.agents.contains(where: { $0.name == name && $0.isWorker && $0.bot == nil && $0.identityExists }) {
            _ = try? await workspaceUpdate(rec.name) { r in
                guard let i = r.agents.lastIndex(where: { $0.name == name && $0.isWorker && $0.bot == nil && $0.identityExists }) else { return [] }
                r.agents[i].tokenIssuedAt = at
                r.agents[i].tokenTakenAt = at
                r.agents[i].tokenRevokedAt = nil
                return []
            }
        }
    }

    /// `worker-reset`: a lasting identity's kept memory cleared (only its own folder in the store). Refused while its
    /// session runs, and for an identity that is not the workspace's.
    func workerReset(_ q: WorkerRequest) async throws -> WorkerEnded {
        let n = try workspaceName(WorkspaceRequest(name: q.workspace))
        guard let name = q.name, !name.isEmpty else { throw HostError(.invalid, "which identity? (doz worker ls \(n) --all)") }
        let rec = try workspaceRecord(n)
        guard let a = WorkspaceIdentities.current(rec).first(where: { $0.name == name }) else {
            throw HostError(.notFound, "\(name) is not an identity of \(n) (doz workspace state \(n))")
        }
        guard a.isLasting else { throw HostError(.invalid, "\(name) is the run's: it has no kept memory (a run-owned identity starts fresh each run)") }
        if a.endedAt == nil, a.stoppedAt == nil {
            throw HostError(.invalidPhase, "\(name) is running — doz workspace stop \(n) (or doz worker end \(n) \(name)) first")
        }
        let dir = identityMemoryFolder(n, name)
        guard MacFenceHostFS.kind(dir) != nil else {
            return WorkerEnded(workspace: n, name: name, removed: false, notes: ["\(name) has no kept memory: nothing to reset"])
        }
        try MacFenceHostFS.remove(dir)
        try? workspaces.append(n, WorkspaceLogEntry(action: "memory-reset", agent: name, reason: "doz worker reset"))
        note(nil, "workspace \(n): \(name)'s kept memory reset")
        return WorkerEnded(workspace: n, name: name, removed: true, notes: ["\(name)'s kept memory is cleared: its next session starts with none"])
    }
}

/// The identities and sessions of a record, pure (`WorkspaceIdentityTests`).
public enum WorkspaceIdentities {
    /// The current identities, in the record's order: per name its live entry, else its last entry that is still an
    /// identity (a lasting one whose session ended). Retired ones and ended run-owned ones are not.
    public static func current(_ rec: WorkspaceRecord) -> [WorkspaceAgent] {
        var out: [WorkspaceAgent] = []
        var seen = Set<String>()
        for a in rec.agents.reversed() where !seen.contains(a.name) {
            if let live = rec.agents.last(where: { $0.name == a.name && $0.endedAt == nil && $0.retiredAt == nil }) {
                out.append(live)
                seen.insert(a.name)
            } else if a.identityExists {
                out.append(a)
                seen.insert(a.name)
            }
        }
        let order = Dictionary(rec.agents.enumerated().map { ($0.element.name, $0.offset) }, uniquingKeysWith: { a, _ in a })
        return out.sorted { (order[$0.name] ?? 0) < (order[$1.name] ?? 0) }
    }

    /// The sessions not ended: each with its identity, place, state (the agent's condition when known, else what the
    /// record says) and since when.
    public static func sessions(_ rec: WorkspaceRecord, conditions: WorkspaceConditions?) -> [WorkspaceSessionRow] {
        rec.agents.filter { $0.endedAt == nil && $0.retiredAt == nil }.map { a in
            let c = conditions?.agents[a.name]
            var state = c?.condition ?? (a.sessionRecordState == "running" ? "unknown" : a.sessionRecordState)
            if a.pendingAt != nil { state = "pending" }
            let since = c?.since ?? SpaceState.time(a.stoppedAt ?? a.startedAt)
            return WorkspaceSessionRow(identity: a.name, place: a.place.display, state: state, since: since)
        }
    }
}
