import DozableChat
import Foundation

// 766: the work description in the daemon (`WorkspaceProposals.swift`): `workspace-retro` (a proposal from a run, and its
// Ask), `workspace-decide`, `workspace-addendum` (a direct change) and `workspace-proposals`. Each change is gated by its
// own permission before it reaches here (`ActionClasses`: description.propose, .decide, .edit — the owner is never gated).
// The proposal's Ask is Dozable's own (`systemAsk` over the chat server's control channel): the owner answers it in chat,
// the dashboard or with `doz chat decide`, and the daemon reads its outcome — at once after a `chat-decide` it served, and
// otherwise whenever the proposals are read (doc, proposals, a run, a decide). docs/engineering/workspaces.md, "The work
// description and proposals".

extension HostCore {
    /// `owner`, or the agent the request acts as.
    func describer(_ r: HostRequest) throws -> String {
        if case .agent(_, let name) = try Caller.of(r) { return name }
        return "owner"
    }

    /// The proposals changed under their own gate; answers what `change` returns.
    func proposalsUpdate<T>(_ n: String, _ change: (inout WorkspaceProposalsFile) async throws -> T) async throws -> T {
        guard !readOnly else { throw HostError(.unavailable, "the proposals are the daemon's to change") }
        await workspaceGate.lock("proposals:" + n)
        defer { workspaceGate.unlock("proposals:" + n) }
        var f = try WorkspaceProposalsFile.read(workspaces, n)
        let before = f
        let out = try await change(&f)
        if f != before { try f.write(workspaces, n) }
        return out
    }

    // MARK: retro --propose

    /// `workspace-retro`: a proposal to add `addendum` to the work description, from run `run` (default: the last, closed or
    /// open), by the caller. Nothing changes until it is decided. Its Ask is posted in the main room (a note says when it
    /// could not be).
    func workspaceRetro(_ r: HostRequest) async throws -> WorkspaceProposal {
        guard !readOnly else { throw HostError(.unavailable, "workspace-retro needs the daemon") }
        let w = r.workspaceRequest ?? WorkspaceRequest()
        let n = try workspaceName(w)
        let by = try describer(r)
        let text = try WorkDescription.checkAddendum(w.addendum)
        let rec = try workspaceRecord(n)
        let run: String
        if let want = w.run {
            guard WorkspaceRuns.isValidID(want), rec.runs.contains(where: { $0.id == want }) else {
                throw HostError(.notFound, "\(n) has no run \(want.prefix(40)) (doz workspace runs \(n))")
            }
            run = want
        } else {
            guard let last = rec.runs.last else {
                throw HostError(.invalidPhase, "\(n) has no run yet: a retrospective is about a run (doz workspace run \(n) opens one)")
            }
            run = last.id
        }
        var p = try await proposalsUpdate(n) { f -> WorkspaceProposal in
            let p = WorkspaceProposal(id: WorkspaceProposal.newID(existing: f.proposals), workspace: n, by: by, text: text, run: run)
            f.proposals.append(p)
            return p
        }
        var e = WorkspaceLogEntry(by: by == "owner" ? "you" : "doz", action: "proposal-made", agent: by,
                                  sha256: WorkspaceStore.sha256(Data(text.utf8)), bytes: text.utf8.count, run: run)
        e.proposal = p.id
        try? workspaces.append(n, e)
        note(nil, "workspace \(n): \(by) proposed \(p.id) from run \(run)")
        var notes: [String] = []
        // Its Ask, Dozable's own, in the main room.
        if let room = rec.mainRoom?.chatRoom, let chat = workspaceChat, await chat.readiness() == .ready {
            let spec: JValue = .map([
                "options": .array([.map(["id": .string("apply"), "label": .string("Apply")])]),
                "about": .map(["proposal": .string(p.id), "workspace": .string(n)]),
                "reason": .string("a proposal to change the work description of \(n)"),
            ])
            do {
                let v = try await chat.control("systemAsk", .map(["room": .string(room), "msgId": .string(chatNewID()),
                                                                 "question": .string(p.question(workspace: n)), "ask": spec]))
                let asked = v.field("asked")
                let id = asked?.field("msgId")?.stringValue
                let number = (try? asked?.field("number")?.goInt("number")) ?? nil
                p = try await proposalsUpdate(n) { f -> WorkspaceProposal in
                    guard let i = f.proposals.firstIndex(where: { $0.id == p.id }) else { return p }
                    f.proposals[i].askId = id
                    f.proposals[i].askNumber = number
                    f.proposals[i].room = room
                    return f.proposals[i]
                }
            } catch {
                notes.append("its Ask was not posted (\(HostError.from(error).message)): doz workspace decide \(n) \(p.id) apply|decline decides it")
            }
        } else {
            notes.append(rec.mainRoom == nil ? "\(n) has no room: no Ask was posted — doz workspace decide \(n) \(p.id) apply|decline decides it"
                         : "chat is not ready: no Ask was posted — doz workspace decide \(n) \(p.id) apply|decline decides it")
        }
        p.notes = notes.isEmpty ? nil : notes
        return p
    }

    // MARK: decide

    /// `workspace-decide`: applies or declines an open proposal (`proposal-decided`, exit 3, when it is decided already —
    /// in chat, or before). Its Ask closes with the outcome, posted by Dozable.
    func workspaceDecide(_ r: HostRequest) async throws -> WorkspaceProposal {
        guard !readOnly else { throw HostError(.unavailable, "workspace-decide needs the daemon") }
        let w = r.workspaceRequest ?? WorkspaceRequest()
        let n = try workspaceName(w)
        let by = try describer(r)
        guard let id = w.proposal, WorkspaceProposal.isValidID(id) else {
            throw HostError(.invalidValue, "which proposal? pr- and 8 hex digits (doz workspace proposals \(n))")
        }
        guard let d = w.decision, d == "apply" || d == "decline" else { throw HostError(.invalidValue, "apply or decline") }
        _ = try workspaceRecord(n)
        await syncProposals(n)
        guard let before = try WorkspaceProposalsFile.read(workspaces, n).proposals.first(where: { $0.id == id }) else {
            throw HostError(.notFound, "\(n) has no proposal \(id) (doz workspace proposals \(n))")
        }
        guard before.isOpen else { throw HostError(.proposalDecided, "proposal \(id) is \(before.state) already") }
        guard var p = try await decideProposal(n, id, apply: d == "apply", by: by, how: "decide") else {
            throw HostError(.proposalDecided, "proposal \(id) was decided just now, another way")
        }
        var notes: [String] = []
        if let room = p.room, let ask = p.askId, let chat = workspaceChat {
            do {
                _ = try await chat.control("systemAskClose", .map(["room": .string(room), "msgId": .string(ask), "outcome": .string(p.outcomeLine())]))
            } catch {
                notes.append("its Ask in \(room) could not be closed (\(HostError.from(error).message)): it expires by itself, and an answer to it changes nothing now")
            }
        }
        p.notes = notes.isEmpty ? nil : notes
        return p
    }

    /// Decides proposal `id` of `n` once: applied (its addendum added to the record — `{run: source.run, by: proposer}` — and
    /// logged) or declined. nil: it is not open (decided already).
    func decideProposal(_ n: String, _ id: String, apply: Bool, by: String, how: String, reason: String? = nil) async throws -> WorkspaceProposal? {
        try await proposalsUpdate(n) { f -> WorkspaceProposal? in
            guard let i = f.proposals.firstIndex(where: { $0.id == id }), f.proposals[i].isOpen else { return nil }
            let p = f.proposals[i]
            let now = Date()
            let who = by == "owner" ? "you" : "doz"
            if apply {
                let a = WorkspaceAddendum(run: p.source.run, at: now, by: p.by, text: p.change.addendum)
                _ = try await workspaceUpdate(n) { rec in
                    rec.addenda.append(a)
                    var added = WorkspaceLogEntry(by: who, action: "addendum-added", agent: p.by, sha256: WorkspaceStore.sha256(Data(a.text.utf8)),
                                                  bytes: a.text.utf8.count, run: a.run)
                    added.proposal = p.id
                    var applied = WorkspaceLogEntry(by: who, action: "proposal-applied", agent: by, run: a.run)
                    applied.proposal = p.id
                    return [added, applied]
                }
            } else {
                var e = WorkspaceLogEntry(by: who, action: "proposal-declined", agent: by, reason: reason, run: p.source.run)
                e.proposal = p.id
                try? workspaces.append(n, e)
            }
            f.proposals[i].state = apply ? "applied" : "declined"
            f.proposals[i].decidedBy = by
            f.proposals[i].decidedAt = now
            f.proposals[i].decidedHow = how
            note(nil, "workspace \(n): proposal \(id) \(apply ? "applied" : "declined") (\(how), by \(by))")
            return f.proposals[i]
        }
    }

    // MARK: the Asks' outcomes

    /// Each open proposal of `n` whose Ask is closed now takes its outcome: decided Apply → applied; declined, expired or
    /// withdrawn → declined. Best effort (chat not ready: nothing changes); the daemon's only.
    func syncProposals(_ n: String) async {
        guard !readOnly, let chat = workspaceChat, let f = try? WorkspaceProposalsFile.read(workspaces, n) else { return }
        let open = f.proposals.filter { $0.isOpen && $0.askId != nil && $0.room != nil }
        guard !open.isEmpty, await chat.readiness() == .ready else { return }
        for p in open {
            guard let (status, m) = try? chat.lookAsk(room: p.room!, ref: p.askId!), status == 200, let a = ChatAsk.read(message: m) else { continue }
            switch a.state {
            case "decided":
                let d = a.decision
                let applied = d.map { !$0.declined && $0.option == "apply" } ?? false
                _ = try? await decideProposal(n, p.id, apply: applied, by: d?.by ?? "owner", how: "ask")
            case "expired":
                _ = try? await decideProposal(n, p.id, apply: false, by: "doz", how: "expired", reason: "its Ask expired")
            case "withdrawn":
                _ = try? await decideProposal(n, p.id, apply: false, by: "doz", how: "ask", reason: "its Ask was withdrawn")
            default: continue
            }
        }
    }

    /// After a `chat-decide` this daemon served in `room`: the proposals of the workspaces that hold it take their outcomes.
    func proposalsAfterDecision(room: String) async {
        for rec in workspaces.records() where rec.rooms.contains(where: { $0.chatRoom == room }) {
            await syncProposals(rec.name)
        }
    }

    // MARK: edit --addendum

    /// `workspace-addendum`: an addendum added directly (no proposal, no Ask), from run `run` when one is named.
    func workspaceAddendumAdd(_ r: HostRequest) async throws -> WorkspaceAddendumAdded {
        guard !readOnly else { throw HostError(.unavailable, "workspace-addendum needs the daemon") }
        let w = r.workspaceRequest ?? WorkspaceRequest()
        let n = try workspaceName(w)
        let by = try describer(r)
        let text = try WorkDescription.checkAddendum(w.addendum)
        let rec = try workspaceRecord(n)
        if let run = w.run, !rec.runs.contains(where: { $0.id == run }) {
            throw HostError(.notFound, "\(n) has no run \(run.prefix(40)) (doz workspace runs \(n))")
        }
        let a = WorkspaceAddendum(run: w.run, at: Date(), by: by, text: text)
        let now = try await workspaceUpdate(n) { rec in
            rec.addenda.append(a)
            return [WorkspaceLogEntry(by: by == "owner" ? "you" : "doz", action: "addendum-added", agent: by,
                                      sha256: WorkspaceStore.sha256(Data(text.utf8)), bytes: text.utf8.count, run: a.run)]
        }
        note(nil, "workspace \(n): \(by) added to the work description")
        return WorkspaceAddendumAdded(workspace: n, addendum: a, revision: WorkspaceRuns.descriptionRevision((try? workspaces.log(n)) ?? []),
                                      addenda: now.addenda.count)
    }

    // MARK: proposals

    /// `workspace-proposals`: every proposal of `n`, oldest first (their Asks' outcomes taken first, by the daemon).
    func workspaceProposalsList(_ w: WorkspaceRequest) async throws -> WorkspaceProposals {
        let n = try workspaceName(w)
        _ = try workspaceRecord(n)
        await syncProposals(n)
        return WorkspaceProposals(workspace: n, proposals: try WorkspaceProposalsFile.read(workspaces, n).proposals)
    }
}
