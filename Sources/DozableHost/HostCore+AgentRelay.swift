import Foundation

// 771: `agent-relay` in the daemon — an agent's journal and work-description call, relayed by the chat server (`HostServer`
// checked the connection is the chat server it supervises first). The participant is mapped to the workspace identity it is
// (`AgentRelay.identity`), the call made into the operation `--as W/NAME` would send (`AgentRelay.request`), decided by the
// ONE gate (`PermissionGate.check`, the same decision, log and words), then served by the core as that agent's request: the
// entry's `by`, the proposal's proposer and the addendum's author are the identity's name. AgentRelay.swift has the trust
// argument; docs/engineering/journal.md, "Agents' own access".

extension HostCore {
    func agentRelay(_ a: AgentRelayRequest?) async -> AgentRelayAnswer {
        guard let a else { return .failure(HostError(.invalidValue, "agent-relay: which call?")) }
        guard !readOnly else { return .failure(HostError(.unavailable, "agent-relay needs the daemon")) }
        do {
            guard AgentRelayRequest.routes.contains(a.route) else { throw HostError(.invalidValue, "\(a.route.prefix(40)) is not a call of the agent relay") }
            guard !a.participant.isEmpty, a.participant != "owner" else {
                throw HostError(.notPermitted, "the owner never goes through the relay: an agent's own token decides who it is")
            }
            var body = try AgentRelay.body(a)
            let named = try AgentRelay.namedWorkspace(a, body)
            let (w, name) = try AgentRelay.identity(participant: a.participant, workspace: named, records: workspaces.records())
            // Evidence: the paths as the agent's place sees them, as this Mac's.
            if a.route == "journal-add", (body?.attach ?? []) + (body?.attachRef ?? []) != [] {
                guard let agent = try workspaces.read(w)?.agents.first(where: { $0.name == name && $0.endedAt == nil }) else {
                    throw HostError(.notPermitted, "\(name) is no longer an agent of \(w)")
                }
                let shares = agent.place.sandbox.flatMap { s in (try? get(s))?.config.spec.shares.map { (host: $0.hostPath, guest: $0.guestPath) } }
                let attach = try (body?.attach ?? []).map { try AgentRelay.hostPath($0, place: agent.place, shares: shares) }
                let attachRef = try (body?.attachRef ?? []).map { try AgentRelay.hostPath($0, place: agent.place, shares: shares) }
                body?.attach = attach.isEmpty ? nil : attach
                body?.attachRef = attachRef.isEmpty ? nil : attachRef
            }
            let inner = try AgentRelay.request(a, workspace: w, name: name, body: body)
            // The ONE gate, as for `--as W/NAME`: decided, logged, refused in its own words.
            if case .refused(let e, let d) = PermissionGate.check(inner, caller: .agent(workspace: w, name: name), reader: { GrantFactsReader(store: self.store) }) {
                return .failure(e, permission: d?.perm)
            }
            note(nil, "workspace \(w): \(name) — \(a.route) through chat")
            if a.route == "journal-wait" { return try await relayWait(inner, seconds: try AgentRelay.waitSeconds(a)) }
            return Self.relayAnswer(await handle(inner))
        } catch {
            return .failure(HostError.from(error))
        }
    }

    /// `journal-wait`, level-triggered as `doz workspace wait --for journal.KIND`: the first effective entry of the kind (after
    /// `after` when given) — at once when one is there — else, every 250 ms, until `seconds` pass (timed-out, 124: dozchat
    /// asks again until its own `--timeout`).
    func relayWait(_ inner: HostRequest, seconds: Int) async throws -> AgentRelayAnswer {
        let deadline = Date().addingTimeInterval(Double(seconds))
        while true {
            let m = await handle(inner)
            if m.ok != true { return Self.relayAnswer(m) }
            let j = try m.result.map { try HostWire.decoder.decode(WorkspaceJournal.self, from: try HostWire.encoder.encode($0)) }
            if let e = j?.entries.first { return .success(try JSONValue(encoding: e)) }
            if Date() >= deadline {
                return .failure(HostError(.timedOut, "no \(inner.workspaceRequest?.journal?.kind ?? "") entry within \(seconds) s"))
            }
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    static func relayAnswer(_ m: HostMessage) -> AgentRelayAnswer {
        if m.ok == true { return .success(m.result ?? .null) }
        let e = m.error ?? HostError(.failed, "no answer")
        // A correction of another's entry is decided once the entry is read: its refusal names journal.supersede.
        let perm = e.code == .notPermitted && e.message.contains("journal.supersede") ? "journal.supersede" : nil
        return .failure(e, permission: perm)
    }
}
