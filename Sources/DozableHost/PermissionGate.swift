import Foundation

/// Who sent a request. Every request that exists today is the OWNER's: the CLI on the owner's socket, this Mac's browser and
/// every web action, the in-process core. An agent caller is made only by narrowing — `HostRequest.actAs` (`--as W/AGENT`,
/// a hidden preview and test path on the owner's socket) — and, later, only by the manager's control route in-process; never
/// from a wire field of an agent's own.
public enum Caller: Equatable, Sendable {
    case owner
    case agent(workspace: String, name: String)

    /// The caller of `r`: the owner, unless it narrows itself to an agent. A narrowing that does not parse is refused — it
    /// never falls back to the owner.
    public static func of(_ r: HostRequest) throws -> Caller {
        guard let a = r.actAs else { return .owner }
        let parts = a.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, WorkspaceName.isValid(parts[0]), WorkspaceName.isValidAgent(parts[1]) else {
            throw HostError(.invalid, "--as W/AGENT: a workspace and one of its agents (\(a.prefix(60)))")
        }
        return .agent(workspace: parts[0], name: parts[1])
    }
}

/// The ONE gate, at the top of `HostServer.serve`, before any routing (the core, chat and the streams all pass it). The owner
/// returns at once — before any grant, ceiling or record is read: the owner is never gated, not even by their own nevers and
/// ceilings. An agent's request is classified (`ActionClasses`), each need decided (`GrantDecision`, the one decision), and
/// the strictest answer taken: allow runs; ask is refused for now ("Asks come later"); never is refused with what decided.
/// Every agent decision is logged (`permission-decided`, in `<store>/grants/log.jsonl` and its workspace's log).
public enum PermissionGate {
    public enum Outcome: Equatable, Sendable {
        case pass
        case refused(HostError, GrantDecision?)
    }

    /// `reader` is asked for only when the caller is an agent.
    public static func check(_ r: HostRequest, caller: Caller, reader: () -> GrantFactsReader, log: Bool = true, now: Date = Date()) -> Outcome {
        guard case .agent(let home, let name) = caller else { return .pass }
        // A role in chat (decider: `chat.decide`) is given by the owner alone, never by an agent, whatever it holds.
        if r.op == .chatSet, r.chat?.roles != nil {
            let perm = GrantPermissions.ownerOnly.sorted().joined(separator: ", ")
            let d = GrantDecision.dozableOwn(name: name, op: r.op.rawValue, workspace: home)
            return .refused(HostError(.notPermitted, "only the owner gives a role in chat (\(perm)): never \(name) in \(home)"), d)
        }
        let facts = reader()
        let op = r.op.rawValue
        let workspaces = WorkspaceStore(store: facts.store)
        let rec = try? workspaces.read(home)
        let who: GrantWho
        if let rec, let a = rec.agents.first(where: { ($0.name == name || $0.bot == name) && $0.endedAt == nil }) {
            who = GrantFactsReader.who(a, in: rec)
        } else {
            let isBot = BotStore(store: facts.store).readOrEmpty().bot(name).map { !$0.retired } ?? false
            who = GrantWho(name: name, home: home, bot: isBot ? name : nil)
        }
        let subject = GrantSubject.agent(home, name).stored
        func record(_ perm: String, _ d: GrantDecision, _ reason: String?) {
            guard log else { return }
            let e = GrantLogEntry(at: now, by: subject, action: "permission-decided", subject: subject, perm: perm, answer: d.answer.rawValue,
                                  op: op, reason: reason)
            try? GrantStore(store: facts.store).append(e)
            if rec != nil {
                var l = WorkspaceLogEntry(at: now, by: "doz", action: "permission-decided", agent: name, reason: reason)
                l.subject = subject; l.perm = perm; l.answer = d.answer.rawValue; l.op = op
                try? workspaces.append(home, l)
            }
        }
        switch ActionClasses.classify(r) {
        case .dozableOwn:
            let d = GrantDecision.dozableOwn(name: name, op: op, workspace: home)
            record(op, d, "refused: Dozable's own")
            return .refused(HostError(.notPermitted, "\(op) is Dozable's own: never for an agent (\(name) in \(home))"), d)
        case .needs(let perms, let target):
            let w: String?
            switch target {
            case .workspace(let x): w = x
            case .place(let key): w = key.flatMap { workspaces.membership()[$0] }
            case .room(let room): w = room.flatMap { room in workspaces.records().first { $0.rooms.contains { $0.chatRoom == room } }?.name }
            case .nowhere: w = nil
            }
            var worst: (String, GrantDecision)?
            for p in perms {
                let d = facts.decide(who, perm: p, workspace: w, now: now)
                if worst == nil || d.answer < worst!.1.answer { worst = (p, d) }
            }
            let (perm, d) = worst!
            let see = "See: doz why \(name) \(perm) --in \(w ?? home)"
            switch d.answer {
            case .allow:
                record(perm, d, nil)
                return .pass
            case .ask:
                record(perm, d, "refused: Asks come later")
                return .refused(HostError(.notPermitted, "\(perm) for \(name) in \(home) would ask; Asks come later. \(see)"), d)
            case .never:
                record(perm, d, "refused: " + d.winner)
                return .refused(HostError(.notPermitted, "\(perm) for \(name) in \(home) is never: \(d.winner). \(see)"), d)
            }
        }
    }

    /// The daemon's door: nil when the request goes on, else why it is refused. The owner's request — every request that
    /// carries no `actAs` — returns nil before anything is read.
    public static func refusal(_ r: HostRequest, store: DozableStore) -> HostError? {
        guard r.actAs != nil else { return nil }
        let caller: Caller
        do { caller = try Caller.of(r) } catch { return HostError.from(error) }
        if case .refused(let e, _) = check(r, caller: caller, reader: { GrantFactsReader(store: store) }) { return e }
        return nil
    }
}
