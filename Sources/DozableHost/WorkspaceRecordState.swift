import DozableChat
import Foundation

// 751 (WS.03): state for EVERY workspace. A workspace made with no space file (`doz workspace new`, the dashboard's wizard)
// has its state derived from its record — the same `SpaceState` document the space-file path produces, shaped on the
// editor's schema (`SpaceStateSchemaTests` validates both), so a drawing could consume it: one item per thing the record
// holds (each agent and its chat member, the sandboxes its agents run in, its folders, its rooms), each agent's condition
// (`WorkspaceConditions`, for both paths: the record is the truth) and what waits for you. Pure and table-tested
// (`WorkspaceRecordStateTests`); `HostCore.workspaceState` gathers the facts. docs/engineering/workspaces.md, "State for every
// workspace".

/// One agent's condition in `doz workspace state --json` (`agents.<name>`).
public struct AgentCondition: Codable, Equatable, Sendable {
    /// Every condition: the five of the contract, and `unknown` (no daemon running, or an agent elsewhere).
    public static let all = ["running", "asleep", "stopped", "crashed", "not-started", "unknown"]

    public var condition: String
    /// Why, in a person's words (nil: nothing to add — it runs).
    public var reason: String?
    /// `manager`, `worker` or `adopted`.
    public var role: String
    /// As a person types it: a sandbox's name or `@mac/SESSION`.
    public var place: String
    /// Since when (ISO 8601), when the record or its log says.
    public var since: String?

    public init(condition: String, reason: String? = nil, role: String, place: String, since: String? = nil) {
        self.condition = condition; self.reason = reason; self.role = role; self.place = place; self.since = since
    }
}

/// Each agent's condition and where the document came from (`SpaceState.conditions`).
public struct WorkspaceConditions: Codable, Equatable, Sendable {
    public static let kind = "WorkspaceState"
    public static let schema = 1

    /// `space-file` or `record`.
    public var from: String
    /// The workspace's agents not ended, by their names in the workspace.
    public var agents: [String: AgentCondition]
    /// Facts known, the workspace neither finished nor archived, at least one agent, and every agent running.
    public var ready: Bool
    /// The workspace's phase (`phases`): from its record's flags, then its agents' conditions (with no daemon, its log).
    public var phase: String?

    /// 764 (COND): one condition per layer, beside `ready` (`LayerConditions`). nil only from an older builder.
    public var layers: LayerConditions?

    /// Every phase, in the order a workspace goes through them.
    public static let phases = ["setting-up", "running", "asleep", "stopped", "finished", "archived"]

    public init(from: String, agents: [String: AgentCondition], ready: Bool, phase: String? = nil, layers: LayerConditions? = nil) {
        self.from = from; self.agents = agents; self.ready = ready; self.phase = phase; self.layers = layers
    }
}

/// 764 (COND, model v3 D7): one condition per layer of a workspace, in `doz workspace state --json`'s `conditions` beside
/// `ready` (never replacing it), and in short form on each `ls --json` row. `phase` stays, derived as before, for one release.
///   - `allocated` (L1): the workspace's own room and the places it provisions are held. Read from the record's lifecycle,
///     never from a guest: true from new (or up) until archive, delete, or — for a space file whose lifetime is `runs`, or
///     any `down --purge` — down. A finish ends the run, not the allocation. `since` is when it began or ended; `reason`
///     (`down`, `archived`) says why it is false.
///   - `hot` (L2): each session (an agent not ended, by its name) `starting`, `running`, `asleep`, `stopped` or `ended`
///     (`unknown` when nothing is known: no daemon, or a session this viewer may not see); `all` / `some` / `none` running.
///   - `run` (L3): the open run (`open`, its `id`, `since` it opened) — or the last one, closed, `since` it closed.
///   - `archived` (L0): `value`, and `at` when it was.
public struct LayerConditions: Codable, Equatable, Sendable {
    public struct Allocated: Codable, Equatable, Sendable {
        public var value: Bool
        public var since: String
        /// Why it is not allocated: `down` or `archived` (nil while allocated).
        public var reason: String?
        public init(value: Bool, since: String, reason: String? = nil) { self.value = value; self.since = since; self.reason = reason }
    }
    public struct Session: Codable, Equatable, Sendable {
        public static let all = ["starting", "running", "asleep", "stopped", "ended", "unknown"]
        public var condition: String
        public var since: String
        public init(condition: String, since: String) { self.condition = condition; self.since = since }
    }
    public struct Hot: Codable, Equatable, Sendable {
        /// `all`, `some` or `none` of the sessions running (`none` when there is none).
        public var value: String
        /// nil in an `ls` row (the short form).
        public var sessions: [String: Session]?
        public init(value: String, sessions: [String: Session]? = nil) { self.value = value; self.sessions = sessions }
    }
    public struct Run: Codable, Equatable, Sendable {
        public var open: Bool
        public var id: String?
        public var since: String?
        public init(open: Bool, id: String? = nil, since: String? = nil) { self.open = open; self.id = id; self.since = since }
    }
    public struct Archived: Codable, Equatable, Sendable {
        public var value: Bool
        public var at: String?
        public init(value: Bool, at: String? = nil) { self.value = value; self.at = at }
    }

    public var allocated: Allocated
    public var hot: Hot
    public var run: Run
    public var archived: Archived

    public init(allocated: Allocated, hot: Hot, run: Run, archived: Archived) {
        self.allocated = allocated; self.hot = hot; self.run = run; self.archived = archived
    }

    /// The short form an `ls` row carries: `allocated`, `hot` without its sessions, `run`.
    public var short: WorkspaceRowConditions { WorkspaceRowConditions(allocated: allocated, hot: Hot(value: hot.value), run: run) }

    /// As `state --json` writes them, after `ready`, in this order.
    public func members() -> [JMember] {
        func s(_ k: String, _ v: String?) -> [JMember] { v.map { [JMember(k, .string($0))] } ?? [] }
        var hotMembers = [JMember("value", .string(hot.value))]
        if let ss = hot.sessions {
            hotMembers.append(JMember("sessions", .object(ss.keys.sorted().map { k in
                JMember(k, .object([JMember("condition", .string(ss[k]!.condition)), JMember("since", .string(ss[k]!.since))]))
            })))
        }
        return [
            JMember("allocated", .object([JMember("value", .bool(allocated.value)), JMember("since", .string(allocated.since))] + s("reason", allocated.reason))),
            JMember("hot", .object(hotMembers)),
            JMember("run", .object([JMember("open", .bool(run.open))] + s("id", run.id) + s("since", run.since))),
            JMember("archived", .object([JMember("value", .bool(archived.value))] + s("at", archived.at))),
        ]
    }
}

/// An `ls --json` row's conditions (764): `LayerConditions.short`.
public struct WorkspaceRowConditions: Codable, Equatable, Sendable {
    public var allocated: LayerConditions.Allocated
    public var hot: LayerConditions.Hot
    public var run: LayerConditions.Run
    public init(allocated: LayerConditions.Allocated, hot: LayerConditions.Hot, run: LayerConditions.Run) {
        self.allocated = allocated; self.hot = hot; self.run = run
    }
}

public enum LayerConditionsBuilder {
    /// L1 from the record alone. Pure.
    public static func allocated(_ rec: WorkspaceRecord) -> LayerConditions.Allocated {
        if let at = rec.flags.archivedAt { return .init(value: false, since: SpaceState.time(at), reason: "archived") }
        if let ref = SpaceRecordRef.of(rec) {
            // Down releases a `runs` space's allocation (and any purge's); a standing space keeps it. An up after it allocates again.
            if let down = ref.downAt, !ref.isUp, ref.purgedAt != nil || !ref.isStanding {
                return .init(value: false, since: SpaceState.time(down), reason: "down")
            }
            if !ref.isStanding, let up = ref.upAt, ref.downAt != nil { return .init(value: true, since: SpaceState.time(up)) }
        }
        return .init(value: true, since: SpaceState.time(rec.createdAt))
    }

    /// One session's L2 condition from its agent's condition (`AgentCondition`).
    public static func session(_ c: AgentCondition, agent a: WorkspaceAgent?, record rec: WorkspaceRecord) -> LayerConditions.Session {
        let word: String
        switch c.condition {
        case "running", "asleep", "stopped", "unknown": word = c.condition
        case "crashed": word = "ended"
        case "not-started": word = a?.pendingAt != nil ? "starting" : "stopped"
        default: word = "unknown"
        }
        // Since: what the condition says, else when the agent last changed (stopped, else started), else the workspace's creation.
        let fallback = word == "running" || word == "starting" ? (a?.pendingAt ?? a?.startedAt) : (a?.stoppedAt ?? a?.startedAt)
        return .init(condition: word, since: c.since ?? SpaceState.time(fallback ?? rec.createdAt))
    }

    /// Every layer, from the record and the agents' conditions (`WorkspaceConditionsBuilder.build`'s). Pure.
    public static func build(record rec: WorkspaceRecord, agents: [String: AgentCondition]) -> LayerConditions {
        var sessions: [String: LayerConditions.Session] = [:]
        for (name, c) in agents {
            sessions[name] = session(c, agent: rec.agents.last { $0.name == name && $0.endedAt == nil }, record: rec)
        }
        let running = sessions.values.filter { $0.condition == "running" }.count
        let hot = running == 0 ? "none" : running == sessions.count ? "all" : "some"
        let run: LayerConditions.Run
        if let r = rec.openRun {
            run = .init(open: true, id: r.id, since: SpaceState.time(r.startedAt))
        } else if let r = rec.runs.last {
            run = .init(open: false, id: r.id, since: r.endedAt.map(SpaceState.time))
        } else {
            run = .init(open: false)
        }
        return LayerConditions(allocated: allocated(rec), hot: .init(value: hot, sessions: sessions), run: run,
                               archived: .init(value: rec.flags.archivedAt != nil, at: rec.flags.archivedAt.map(SpaceState.time)))
    }
}

public enum WorkspaceConditionsBuilder {
    /// The log actions that say what last happened to one agent.
    static let agentEvents: Set<String> = ["agent-crashed", "agent-slept", "agent-stopped", "agent-woke", "manager-started", "manager-stopped", "worker-added",
                                           "adopted", "restored", "reopened"]

    /// The last line of `log` about each agent (by name).
    public static func lastEvents(_ log: [WorkspaceLogEntry]) -> [String: WorkspaceLogEntry] {
        var out: [String: WorkspaceLogEntry] = [:]
        for e in log where agentEvents.contains(e.action) { if let a = e.agent { out[a] = e } }
        return out
    }

    public static func role(_ a: WorkspaceAgent) -> String { a.isManager ? "manager" : a.isWorker ? "worker" : "adopted" }

    /// One agent's condition from what the daemon holds of it (`fact`: `SpaceStateFacts.agents`) and the last line of the
    /// log about it. Pure.
    public static func condition(_ a: WorkspaceAgent, fact: SpaceStateFacts.Agent?, last: WorkspaceLogEntry?, flags: WorkspaceFlags,
                                 known: Bool) -> AgentCondition {
        var c = AgentCondition(condition: "unknown", role: role(a), place: a.place.display)
        guard known else {
            c.reason = "no daemon is running: nothing is known (none was started)"
            return c
        }
        if a.pendingAt != nil {
            c.condition = "not-started"; c.reason = "being added"; c.since = SpaceState.time(a.pendingAt!)
            return c
        }
        let fact = fact ?? SpaceStateFacts.Agent(state: "missing")
        let since = last.map { SpaceState.time($0.at) }
        switch fact.state {
        case "running":
            c.condition = "running"
            if last?.action != "agent-crashed" { c.since = since }
        case "asleep":
            c.condition = "asleep"; c.reason = fact.detail; c.since = a.stoppedAt.map(SpaceState.time) ?? since
        case "unknown":
            c.reason = fact.detail ?? "not known"
        case "ended" where fact.failed:
            c.condition = "crashed"; c.reason = "its sandbox failed" + (fact.detail.map { " (\($0))" } ?? "")
        case "ended" where fact.detail == "not started" && a.stoppedAt == nil && last?.action != "agent-stopped":
            c.condition = "not-started"; c.reason = a.isManager ? "doz workspace start starts it" : "not started"
        default:
            // Ended or missing: why it is not running, from what last happened to it.
            if last?.action == "agent-crashed" {
                c.condition = "crashed"; c.reason = "its program exited with \(last?.exitCode.map(String.init) ?? "an error")"; c.since = since
            } else if flags.archivedAt != nil || flags.finishedAt != nil {
                c.condition = "stopped"; c.reason = flags.archivedAt != nil ? "the workspace is archived" : "the workspace is finished"
                c.since = (flags.archivedAt ?? flags.finishedAt).map(SpaceState.time)
            } else if last?.action == "agent-stopped" {
                c.condition = "stopped"; c.reason = "stopped: doz workspace wake brings it back"; c.since = a.stoppedAt.map(SpaceState.time) ?? since
            } else if last?.action == "agent-slept" {
                c.condition = "asleep"; c.reason = "put to sleep: doz workspace wake wakes it"; c.since = since
            } else if fact.state == "missing" {
                c.condition = "stopped"; c.reason = a.place.sandbox != nil ? "its sandbox is gone" : "its session is gone"
            } else {
                c.condition = "stopped"; c.reason = fact.detail ?? (last?.action == "manager-stopped" ? "stopped" : "its program ended")
                c.since = a.stoppedAt.map(SpaceState.time) ?? since
            }
        }
        return c
    }

    /// Every agent of the workspace not ended. `hidden`: the record's agents on this Mac a viewer may not see — `unknown`.
    public static func build(record rec: WorkspaceRecord, facts f: SpaceStateFacts, log: [WorkspaceLogEntry], from: String,
                             hidden: Bool = false) -> WorkspaceConditions {
        let last = lastEvents(log)
        var agents: [String: AgentCondition] = [:]
        for a in rec.agents where a.endedAt == nil {
            if hidden, a.place.mac == true {
                agents[a.name] = AgentCondition(condition: "unknown", reason: SpaceStateBuilder.hiddenDetail, role: role(a), place: a.place.display)
                continue
            }
            agents[a.name] = condition(a, fact: f.agents[a.name], last: last[a.name], flags: rec.flags, known: f.known)
        }
        // The workers declared at new: the record says they have not started, daemon or not.
        for d in rec.declaredWorkers where agents[d.name] == nil {
            let place = WorkerLaunch.placeName(workspace: rec.name, name: d.name)
            agents[d.name] = AgentCondition(condition: "not-started", reason: "declared: doz workspace start starts it", role: "worker",
                                            place: rec.defaults.isolation == "vm" ? place : MacPlace.name + "/" + place,
                                            since: SpaceState.time(d.declaredAt))
        }
        let ready = f.known && rec.flags.finishedAt == nil && rec.flags.archivedAt == nil && !agents.isEmpty
            && agents.values.allSatisfy { $0.condition == "running" }
        return WorkspaceConditions(from: from, agents: agents, ready: ready, phase: phase(rec, agents: agents, known: f.known, log: log),
                                   layers: LayerConditionsBuilder.build(record: rec, agents: agents))
    }

    /// The phase: archived, finished, setting up (never started) from the flags; then running while any agent runs, asleep
    /// while any sleeps and none runs, else stopped. With no daemon (nothing known) the log's last workspace-wide change says.
    public static func phase(_ rec: WorkspaceRecord, agents: [String: AgentCondition], known: Bool, log: [WorkspaceLogEntry]) -> String {
        if rec.flags.archivedAt != nil { return "archived" }
        if rec.flags.finishedAt != nil { return "finished" }
        if rec.flags.startedAt == nil && rec.flags.firstAgentAt == nil { return "setting-up" }
        let conditions = agents.values.map(\.condition)
        if known && !conditions.isEmpty {
            if conditions.contains("running") { return "running" }
            if conditions.contains("asleep") { return "asleep" }
            return "stopped"
        }
        let words = ["slept": "asleep", "reopened": "asleep", "stopped": "stopped", "woke": "running", "kicked-off": "running",
                     "manager-started": "running", "worker-added": "running", "run-opened": "running"]
        return log.last { words[$0.action] != nil }.flatMap { words[$0.action] } ?? "running"
    }
}

/// A workspace made with no space file as the `SpaceState` document: what its record holds, with the facts.
public enum RecordStateBuilder {
    /// The item state of an agent (`SpaceState.states["agent"]`) from its condition.
    static func agentState(_ c: AgentCondition, fact: SpaceStateFacts.Agent?) -> String {
        switch c.condition {
        case "running": return "running"
        case "asleep": return "asleep"
        case "unknown": return "unknown"
        default: return fact?.state == "missing" ? "missing" : "ended"
        }
    }

    /// The document. `conditions` are the agents' (`WorkspaceConditionsBuilder.build`, never hidden here — a hidden viewer's
    /// document is `hiding` this one). Pure.
    public static func build(record rec: WorkspaceRecord, facts f: SpaceStateFacts, conditions: WorkspaceConditions, host: String, now: Date,
                             viewer: SpaceStateViewer, note: String? = nil) -> SpaceState {
        var doc = SpaceState(space: rec.name, observedAt: SpaceState.time(now), factsKnown: f.known, host: host)
        if let r = rec.openRun {
            doc.run = SpaceState.Run(id: r.id, startedAt: SpaceState.time(r.startedAt), phase: "up")
        } else if let r = rec.runs.last {
            doc.run = SpaceState.Run(id: r.id, startedAt: SpaceState.time(r.startedAt), endedAt: r.endedAt.map(SpaceState.time), phase: "down")
        }
        let hasRun = !rec.runs.isEmpty || rec.flags.startedAt != nil
        func unknown(_ subject: String, _ type: String, _ lifetime: String) -> SpaceState.Item {
            SpaceState.Item(subject: subject, type: type, lifetime: lifetime, state: "unknown", activity: type == "agent" ? "unknown" : nil)
        }
        /// Drift where a thing should exist and does not: an external always, a persisted one once the workspace has run.
        func settle(_ it: SpaceState.Item) -> SpaceState.Item {
            var it = it
            if it.state == "missing", it.lifetime == "external" || hasRun {
                it.drift = SpaceState.Drift(kind: "missing", text: "the workspace has it, but it isn't there")
            }
            return it
        }
        var items: [SpaceState.Item] = []
        var attention: [SpaceState.Attention] = []
        let live = rec.agents.filter { $0.endedAt == nil }

        // Agents, each followed by its chat member (a manager or worker: its bot, else its own name).
        for a in live {
            let lifetime = a.isManager || a.isWorker ? "persisted" : "external"
            let chatName = a.bot ?? (a.isManager || a.isWorker ? a.name : nil)
            let wantsMember = chatName != nil && rec.mainRoom != nil
            guard f.known else {
                items.append(unknown(a.name, "agent", lifetime))
                if wantsMember { items.append(unknown(a.name, "member", lifetime)) }
                continue
            }
            let fact = f.agents[a.name]
            let c = conditions.agents[a.name] ?? WorkspaceConditionsBuilder.condition(a, fact: fact, last: nil, flags: rec.flags, known: true)
            var it = SpaceState.Item(subject: a.name, type: "agent", lifetime: lifetime, state: agentState(c, fact: fact), detail: c.reason)
            it.activity = it.state == "running" ? SpaceStateBuilder.activity(fact?.status) : it.state == "unknown" ? "unknown" : nil
            items.append(settle(it))
            if it.state == "running", let s = fact?.status, s.state == .blocked {
                var line = "\(a.name): \(s.label)"
                if let m = SpaceStateBuilder.oneLine(s.message) { line += " — " + m }
                attention.append(SpaceState.Attention(subject: a.name, kind: SpaceStateBuilder.blockedKind(s), text: line))
            }
            if c.condition == "crashed" {
                attention.append(SpaceState.Attention(subject: a.name, kind: "health", text: "\(a.name): \(c.reason ?? "crashed")"))
            }
            if wantsMember, let n = chatName {
                var state = "unknown"
                if let p = f.participants { state = p.contains(n) ? (it.state == "running" || it.state == "asleep" ? "present" : "away") : "absent" }
                items.append(SpaceState.Item(subject: a.name, type: "member", lifetime: lifetime, state: state, detail: n != a.name ? "as \(n)" : nil))
            }
        }

        // The sandboxes its agents run in, each once.
        var seen = Set<String>()
        for a in live {
            guard let s = a.place.sandbox, seen.insert(s).inserted else { continue }
            let lifetime = a.isManager || a.isWorker ? "persisted" : "external"
            guard f.known else { items.append(unknown(s, "sandbox", lifetime)); continue }
            var it = SpaceState.Item(subject: s, type: "sandbox", lifetime: lifetime, state: "missing")
            if let p = f.sandboxes[s] {
                switch p {
                case "running", "booting": it.state = "running"
                case "paused", "asleep", "hibernated": it.state = "hibernated"
                case "failed":
                    it.state = "stopped"; it.detail = "failed"
                    attention.append(SpaceState.Attention(subject: s, kind: "health", text: "\(s): the sandbox failed"))
                default: it.state = "stopped"
                }
            }
            items.append(settle(it))
        }

        // Folders: by their paths (absolute — a JSON field is never shown with `~`).
        for x in rec.folders {
            guard f.known else { items.append(unknown(x.path, "folder", "external")); continue }
            let there = f.folders[x.path] ?? false
            items.append(settle(SpaceState.Item(subject: x.path, type: "folder", lifetime: "external", state: there ? "present" : "missing",
                                                detail: x.main ? "the main folder" : nil)))
        }

        // Rooms: by their names in chat; one the workspace made persists, a linked one is external.
        for r in rec.rooms where r.goneAt == nil {
            let lifetime = r.owned == false ? "external" : "persisted"
            guard f.known else { items.append(unknown(r.chatRoom, "room", lifetime)); continue }
            var it = SpaceState.Item(subject: r.chatRoom, type: "room", lifetime: lifetime, state: SpaceStateBuilder.roomState(r.chatRoom, f),
                                     detail: r.main ? "the main room" : r.label != r.chatRoom ? r.label : nil)
            if it.state == "gone" { it.detail = nil }
            items.append(it.state == "unknown" || it.state == "gone" ? it : settle(it))
        }

        attention += SpaceStateBuilder.askItems(facts: f, viewer: viewer) { from in
            live.first { $0.name == from || $0.bot == from }?.name ?? rec.name
        }
        if let note { attention.append(SpaceState.Attention(subject: rec.name, kind: "problem", text: note)) }
        doc.items = items
        doc.attention = attention.sorted { ($0.subject, $0.kind, $0.text, $0.askId ?? "") < ($1.subject, $1.kind, $1.text, $1.askId ?? "") }
        doc.seal()
        return doc
    }

    /// The record's agents on this Mac: what a viewer who may not see this Mac's sessions is not told (`SpaceState.hiding`).
    public static func macSubjects(_ rec: WorkspaceRecord) -> (items: Set<String>, extras: Set<String>) {
        (Set(rec.agents.filter { $0.endedAt == nil && $0.place.mac == true }.map(\.name)), [])
    }
}
