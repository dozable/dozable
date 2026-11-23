import CryptoKit
import DozableChat
import Foundation

// What is true about a space beside what its file says — the SpaceState document (version 1) the space editor renders as
// its state layer, attention list, drift and runs strip. Shaped exactly on the editor's schema (`space-state-1.schema.json`,
// vendored with its fixtures under `Tests/DozableCLITests/Fixtures/space-state/`, PIN): no field the schema does not name,
// the Ask fields only on an attention of kind `ask` (none is made before Asks arrive). `SpaceStateBuilder.build` is pure and
// table-tested; `workspace-state` (`HostCore+SpaceState`) gathers its facts. The rules:
//   - one item per thing the file declares, keyed by (type, subject) — the subject is the thing's name in the file;
//   - not known is an answer (`unknown`, never healthy); `gone` is a run's thing that down removed (no drift); drift only
//     where a thing should exist (an external always, a persisted thing once the space has run, a run's thing while a run
//     is open);
//   - one chat text only: an open Ask's question and its option labels (attention of kind `ask`), live only — for this
//     Mac's browser and the CLI, and for another computer only with `serve.chat` read or write; never in a frame or a run's
//     archive (`SpaceStateFacts.dropMessages`); no other message's text, ever; a program's own status message only for a
//     viewer who may see its session, one line;
//   - no volatile value (no "2m ago"): the `sha` — sha256 of the document without `sha` and `observedAt`, as compact JSON
//     in the editor's key order (`stringify` is JSON.stringify's output, byte for byte) — changes only when a fact does.
// docs/engineering/workspaces.md ("Space files").

public struct SpaceState: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public struct Run: Codable, Equatable, Sendable {
        public var id: String
        public var startedAt: String
        public var endedAt: String?
        /// `starting`, `up`, `stopping` or `down`.
        public var phase: String
        public init(id: String, startedAt: String, endedAt: String? = nil, phase: String) {
            self.id = id; self.startedAt = startedAt; self.endedAt = endedAt; self.phase = phase
        }
    }

    public struct Drift: Codable, Equatable, Sendable {
        /// `missing`, `extra` or `differs`.
        public var kind: String
        public var text: String
        public init(kind: String, text: String) { self.kind = kind; self.text = text }
    }

    public struct Item: Codable, Equatable, Sendable {
        public var subject: String
        /// `agent`, `service`, `sandbox`, `folder`, `room` or `member`.
        public var type: String
        /// `external`, `persisted` or `run`.
        public var lifetime: String
        /// One of the type's states (`SpaceState.states`).
        public var state: String
        /// Agents only: `working`, `idle`, `waiting` or `unknown`.
        public var activity: String?
        /// One line a person reads — never a message's text, never a volatile value.
        public var detail: String?
        public var since: String?
        public var drift: Drift?
        public init(subject: String, type: String, lifetime: String, state: String, activity: String? = nil, detail: String? = nil,
                    since: String? = nil, drift: Drift? = nil) {
            self.subject = subject; self.type = type; self.lifetime = lifetime; self.state = state; self.activity = activity
            self.detail = detail; self.since = since; self.drift = drift
        }
    }

    /// What waits for a person. The Ask fields (`askId` … `expiresAt`) only on kind `ask`: one per open ask in the
    /// workspace's rooms (`SpaceStateBuilder.askItems`).
    public struct Attention: Codable, Equatable, Sendable {
        public var subject: String
        /// `permission`, `trust`, `confirm`, `health`, `refusal`, `problem` or `ask`.
        public var kind: String
        public var text: String
        public var since: String?
        public var askId: String?
        public var room: String?
        public var from: String?
        public var openedAt: String?
        public var question: String?
        public var options: [String]?
        public var answerers: [String]?
        public var canAnswer: Bool?
        public var expiresAt: String?
        public init(subject: String, kind: String, text: String) { self.subject = subject; self.kind = kind; self.text = text }
    }

    public var version: Int = SpaceState.currentVersion
    public var space: String
    public var observedAt: String
    public var factsKnown: Bool
    /// A display name only.
    public var host: String
    public var run: Run?
    public var items: [Item]
    public var extras: [Item]
    public var attention: [Attention]
    public var sha: String
    /// 751: each agent's condition and where the document came from, carried only when asked
    /// (`WorkspaceRequest.withConditions` — the CLI's `--json`); never in `ordered()`, so the editor's document, its sha and
    /// the frames are unchanged. `stateAnswer()` writes it.
    public var agentConditions: WorkspaceConditions?

    public init(space: String, observedAt: String, factsKnown: Bool, host: String, run: Run? = nil, items: [Item] = [], extras: [Item] = [],
                attention: [Attention] = [], sha: String = "") {
        self.space = space; self.observedAt = observedAt; self.factsKnown = factsKnown; self.host = host; self.run = run
        self.items = items; self.extras = extras; self.attention = attention; self.sha = sha
    }

    /// Each type's states; every type also has `unknown` and `gone`.
    public static let states: [String: [String]] = [
        "agent": ["running", "asleep", "ended", "missing", "gone", "unknown"],
        "service": ["healthy", "unhealthy", "starting", "stopped", "missing", "gone", "unknown"],
        "sandbox": ["running", "hibernated", "stopped", "missing", "gone", "unknown"],
        "folder": ["present", "missing", "gone", "unknown"],
        "room": ["open", "closed", "archived", "missing", "gone", "unknown"],
        "member": ["present", "away", "absent", "gone", "unknown"],
    ]

    // MARK: the document's bytes and its sha

    /// The document as an ordered JSON value, in the editor's key order (the order its producer writes and its fixtures
    /// carry: an Ask's `expiresAt` last). `sha` and `observedAt` left out for the sha.
    public func ordered(sha withSHA: Bool = true, observedAt withObserved: Bool = true) -> JValue {
        func s(_ k: String, _ v: String?) -> [JMember] { v.map { [JMember(k, .string($0))] } ?? [] }
        func itemValue(_ i: Item) -> JValue {
            var m = [JMember("subject", .string(i.subject)), JMember("type", .string(i.type)), JMember("lifetime", .string(i.lifetime)),
                     JMember("state", .string(i.state))]
            m += s("activity", i.activity) + s("detail", i.detail) + s("since", i.since)
            if let d = i.drift { m.append(JMember("drift", .object([JMember("kind", .string(d.kind)), JMember("text", .string(d.text))]))) }
            return .object(m)
        }
        func attentionValue(_ a: Attention) -> JValue {
            var m = [JMember("subject", .string(a.subject)), JMember("kind", .string(a.kind)), JMember("text", .string(a.text))]
            m += s("since", a.since) + s("askId", a.askId) + s("room", a.room) + s("from", a.from) + s("openedAt", a.openedAt)
                + s("question", a.question)
            if let o = a.options { m.append(JMember("options", .array(o.map { .string($0) }))) }
            if let o = a.answerers { m.append(JMember("answerers", .array(o.map { .string($0) }))) }
            if let c = a.canAnswer { m.append(JMember("canAnswer", .bool(c))) }
            m += s("expiresAt", a.expiresAt)
            return .object(m)
        }
        var m = [JMember("version", .int(Int64(version))), JMember("space", .string(space))]
        if withObserved { m.append(JMember("observedAt", .string(observedAt))) }
        m += [JMember("factsKnown", .bool(factsKnown)), JMember("host", .string(host))]
        if let r = run {
            m.append(JMember("run", .object([JMember("id", .string(r.id)), JMember("startedAt", .string(r.startedAt))] + s("endedAt", r.endedAt)
                                             + [JMember("phase", .string(r.phase))])))
        }
        m += [JMember("items", .array(items.map(itemValue))), JMember("extras", .array(extras.map(itemValue))),
              JMember("attention", .array(attention.map(attentionValue)))]
        if withSHA { m.append(JMember("sha", .string(sha))) }
        return .object(m)
    }

    /// 751: `doz workspace state --json` — the JSON contract around the document: `kind` `WorkspaceState` and `schema` 1 first,
    /// then the document exactly as `ordered()` writes it (its `sha` unchanged), then — when carried — `from` (`space-file`
    /// or `record`), `agents` (each agent of the workspace by its name: `condition`, `reason`, `role`, `place`, `since`) and
    /// `conditions` (`ready`; 764: `allocated`, `hot`, `run`, `archived` — `LayerConditions`), and `revision` (empty until the revision store). Additive only within schema 1.
    public func stateAnswer() -> JValue {
        guard case .object(let doc) = ordered() else { return ordered() }
        var m = [JMember("kind", .string(WorkspaceConditions.kind)), JMember("schema", .int(Int64(WorkspaceConditions.schema)))] + doc
        if let c = agentConditions {
            m.append(JMember("from", .string(c.from)))
            // The workspace's phase (setting-up | running | asleep | stopped | finished | archived), top level. Additive.
            if let p = c.phase { m.append(JMember("phase", .string(p))) }
            m.append(JMember("agents", .object(c.agents.keys.sorted().map { k in
                let a = c.agents[k]!
                var o = [JMember("condition", .string(a.condition))]
                if let r = a.reason { o.append(JMember("reason", .string(r))) }
                o += [JMember("role", .string(a.role)), JMember("place", .string(a.place))]
                if let s = a.since { o.append(JMember("since", .string(s))) }
                return JMember(k, .object(o))
            })))
            // 764: one condition per layer beside `ready` (never replacing it).
            m.append(JMember("conditions", .object([JMember("ready", .bool(c.ready))] + (c.layers?.members() ?? []))))
        }
        m.append(JMember("revision", .string("")))
        return .object(m)
    }

    /// The document as a viewer who may not see this Mac's sessions reads it (`SpaceStateBuilder.macSubjects`): those agents'
    /// items and members `unknown`, "not shown to another computer"; their attention and extras left out; sealed again.
    public func hiding(_ subjects: (items: Set<String>, extras: Set<String>)) -> SpaceState {
        var out = self
        out.items = items.map { i in
            guard (i.type == "agent" || i.type == "member"), subjects.items.contains(i.subject) else { return i }
            return Item(subject: i.subject, type: i.type, lifetime: i.lifetime, state: "unknown", activity: i.type == "agent" ? "unknown" : nil,
                        detail: SpaceStateBuilder.hiddenDetail)
        }
        out.extras = extras.filter { !($0.type == "agent" && subjects.extras.contains($0.subject)) }
        out.attention = attention.filter { !subjects.items.contains($0.subject) }
        out.seal()
        return out
    }

    /// The sha of these facts: sha256 of the document without `sha` and `observedAt`.
    public var computedSHA: String { Self.sha256(Self.stringify(ordered(sha: false, observedAt: false))) }

    /// The sha filled in.
    public mutating func seal() { sha = computedSHA }

    /// The sha of any document of this shape as the editor computes it: the document (its own key order kept) without
    /// `sha` and `observedAt` at the top, as JSON.stringify writes it.
    public static func sha(ofDocument v: JValue) -> String {
        guard case .object(let m) = v else { return sha256(stringify(v)) }
        return sha256(stringify(.object(m.filter { $0.key != "sha" && $0.key != "observedAt" })))
    }

    static func sha256(_ s: String) -> String { SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined() }

    /// Compact JSON exactly as ECMAScript's JSON.stringify writes it: `"` `\` and the controls escaped (`\b \f \n \r \t`,
    /// others `\u00xx`), everything else — `/`, `<`, `&`, non-ASCII — as it is; integers plainly.
    public static func stringify(_ v: JValue) -> String {
        var out = ""
        func string(_ s: String) {
            out.append("\"")
            for u in s.unicodeScalars {
                switch u.value {
                case 0x22: out.append("\\\"")
                case 0x5C: out.append("\\\\")
                case 0x08: out.append("\\b")
                case 0x0C: out.append("\\f")
                case 0x0A: out.append("\\n")
                case 0x0D: out.append("\\r")
                case 0x09: out.append("\\t")
                case 0..<0x20: out.append(String(format: "\\u%04x", u.value))
                default: out.unicodeScalars.append(u)
                }
            }
            out.append("\"")
        }
        func value(_ v: JValue) {
            switch v {
            case .null: out.append("null")
            case .bool(let b): out.append(b ? "true" : "false")
            case .int(let n): out.append(String(n))
            case .double(let d):
                if d.isFinite, d == d.rounded(), abs(d) < 1e21 { out.append(String(Int64(d))) } else if d.isFinite { out.append("\(d)") } else { out.append("null") }
            case .number(let raw): out.append(raw)
            case .string(let s): string(s)
            case .array(let a):
                out.append("[")
                for (i, x) in a.enumerated() { if i > 0 { out.append(",") }; value(x) }
                out.append("]")
            case .object(let m):
                out.append("{")
                for (i, x) in m.enumerated() { if i > 0 { out.append(",") }; string(x.key); out.append(":"); value(x.value) }
                out.append("}")
            }
        }
        value(v)
        return out
    }

    /// A time as the document writes it: `2026-11-20T09:30:00Z`.
    public static func time(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: d)
    }
}

/// Who reads the document: this Mac's own browser and the CLI see everything; another computer sees the agents on this Mac
/// only as `serve.mac_sessions` allows — a hidden one keeps its item (stable keys), `unknown`, "not shown to another
/// computer", and nothing else about it.
public struct SpaceStateViewer: Equatable, Sendable {
    public var macSessions: Bool
    /// An open ask's question is shown (this Mac's browser and the CLI; another computer with `serve.chat` read or write).
    public var askText: Bool
    /// Asks may be answered where this viewer is (this Mac's browser and the CLI; never another computer, for now).
    public var answerHere: Bool
    /// The person's name in chat (the daemon's own directory — never a request's): who `canAnswer` is about.
    public var chatName: String?
    public init(macSessions: Bool, askText: Bool = true, answerHere: Bool = true, chatName: String? = nil) {
        self.macSessions = macSessions; self.askText = askText; self.answerHere = answerHere; self.chatName = chatName
    }
    public static let owner = SpaceStateViewer(macSessions: true)
}

/// What the builder knows, gathered by the daemon (`known`) — with none running, nothing (every item `unknown`).
public struct SpaceStateFacts: Sendable {
    public struct Agent: Equatable, Sendable {
        /// `running`, `asleep`, `ended`, `missing` or `unknown`.
        public var state: String
        public var status: SessionStatus?
        public var detail: String?
        /// Its sandbox failed (attention `health`).
        public var failed: Bool
        public init(state: String, status: SessionStatus? = nil, detail: String? = nil, failed: Bool = false) {
            self.state = state; self.status = status; self.detail = detail; self.failed = failed
        }
    }
    public var known: Bool
    public var home: String
    public var projectsDir: String
    /// The record's agents not ended, by their name in the workspace.
    public var agents: [String: Agent] = [:]
    /// Sessions on this Mac by name (an external session not adopted yet).
    public var sessions: [String: Agent] = [:]
    /// Sandboxes by name → their phase (`Phase`'s words); absent: no such sandbox.
    public var sandboxes: [String: String] = [:]
    /// Paths (after `~`) → a folder is there.
    public var folders: [String: Bool] = [:]
    /// The chat server's rooms (nil: not known — chat off or not ready), archived ones, the closed set's, the tombstones'.
    public var rooms: Set<String>?
    public var archivedRooms: Set<String> = []
    public var closedRooms: Set<String> = []
    public var goneRooms: Set<String> = []
    /// The chat server's participants (nil: not known).
    public var participants: Set<String>?
    /// The last up stopped at a failure (the record's log says so).
    public var upStopped: Bool = false
    /// The open asks of the workspace's rooms (nil: not known — chat off or not ready).
    public var asks: [OpenAsk]?
    /// Asks' texts dropped (a frame): no question, and nothing answerable.
    public var asksDropped = false
    public init(known: Bool, home: String, projectsDir: String) { self.known = known; self.home = home; self.projectsDir = projectsDir }
    /// The programs' own messages left out (a frame keeps states, never a program's text).
    /// An ask's question and options too: a frame never carries a chat text, and nothing in it is answerable.
    public mutating func dropMessages() {
        for k in agents.keys { agents[k]?.status?.message = nil; agents[k]?.status?.title = nil }
        for k in sessions.keys { sessions[k]?.status?.message = nil; sessions[k]?.status?.title = nil }
        asks = asks?.map { a in
            var a = a
            a.question = ""; a.title = ""; a.reason = nil
            return a
        }
        asksDropped = true
    }
    public func expand(_ p: String) -> String { p == "~" ? home : p.hasPrefix("~/") ? home + String(p.dropFirst(1)) : p }
}

public enum SpaceStateBuilder {
    public static let hiddenDetail = "not shown to another computer"
    public static let missingText = "the file has it, but it isn't there"
    /// A program's own status message in an attention line: one line, at most this many characters.
    public static let messageLimit = 120

    /// The document for a space workspace, from what the file asks (`intent`), its record and reference, and the facts.
    /// Pure.
    public static func build(intent i: SpaceIntent, ref: SpaceRecordRef?, record rec: WorkspaceRecord?, facts f: SpaceStateFacts,
                             host: String, now: Date, viewer: SpaceStateViewer) -> SpaceState {
        var doc = SpaceState(space: i.space, observedAt: SpaceState.time(now), factsKnown: f.known, host: host)
        let runOpen = rec?.openRun != nil
        let hasRun = ref?.upAt != nil || !(rec?.runs.isEmpty ?? true)
        if let r = rec?.openRun {
            doc.run = SpaceState.Run(id: r.id, startedAt: SpaceState.time(r.startedAt), phase: "up")
        } else if let r = rec?.runs.last {
            doc.run = SpaceState.Run(id: r.id, startedAt: SpaceState.time(r.startedAt), endedAt: r.endedAt.map(SpaceState.time), phase: "down")
        }
        func should(_ lifetime: String) -> Bool { lifetime == "external" ? true : lifetime == "persisted" ? hasRun : runOpen }
        func unknown(_ subject: String, _ type: String, _ lifetime: String, detail: String? = nil) -> SpaceState.Item {
            SpaceState.Item(subject: subject, type: type, lifetime: lifetime, state: "unknown", activity: type == "agent" ? "unknown" : nil, detail: detail)
        }
        /// "gone" for a run's thing with no run open; drift where it should exist and does not.
        func settle(_ it: SpaceState.Item, missing text: String = missingText, optional: Bool = false) -> SpaceState.Item {
            var it = it
            if it.lifetime == "run", !runOpen, ["missing", "ended", "stopped", "absent"].contains(it.state) {
                return SpaceState.Item(subject: it.subject, type: it.type, lifetime: it.lifetime, state: "gone")
            }
            if it.state == "missing", should(it.lifetime), !optional { it.drift = SpaceState.Drift(kind: "missing", text: text) }
            return it
        }
        var items: [SpaceState.Item] = []
        var attention: [SpaceState.Attention] = []
        var matched = Set<String>()
        let owned = ref?.owned
        func life(_ kind: String, _ name: String, external: Bool, persisted: Bool) -> String {
            if external { return "external" }
            let o: [String: String]?
            switch kind {
            case "agent": o = owned?.agents
            case "room": o = owned?.rooms
            case "sandbox": o = owned?.sandboxes
            default: o = owned?.folders
            }
            return (o?[name] ?? (persisted ? "persisted" : "run")) == "persisted" ? "persisted" : "run"
        }

        // Agents, each followed by its chat member.
        for a in i.agents {
            let entry = recordAgent(a, rec)
            if let e = entry { matched.insert(e.name) }
            let lifetime = life("agent", a.name, external: a.external, persisted: a.memory != nil)
            let onMac = Self.onMac(a, entry)
            let hidden = onMac && !viewer.macSessions
            let chatName: String? = a.session != nil ? nil : a.external ? a.bot : a.name
            let wantsMember = chatName != nil && !i.rooms.isEmpty
            if !f.known || hidden {
                items.append(unknown(a.name, "agent", lifetime, detail: hidden ? hiddenDetail : nil))
                if wantsMember { items.append(unknown(a.name, "member", lifetime, detail: hidden ? hiddenDetail : nil)) }
                continue
            }
            var fact: SpaceStateFacts.Agent
            if let e = entry, e.endedAt == nil {
                fact = f.agents[e.name] ?? SpaceStateFacts.Agent(state: "missing")
            } else if let s = a.session, entry == nil || entry?.endedAt != nil {
                fact = f.sessions[s] ?? SpaceStateFacts.Agent(state: "missing")
            } else {
                fact = SpaceStateFacts.Agent(state: entry?.endedAt != nil ? "ended" : "missing")
            }
            var it = SpaceState.Item(subject: a.name, type: "agent", lifetime: lifetime, state: fact.state, detail: fact.detail)
            if fact.state == "running" { it.activity = activity(fact.status) }
            if fact.state == "unknown" { it.activity = "unknown" }
            items.append(settle(it, missing: a.external ? "the file names it, but it isn't there" : "the file has it, but its session isn't there"))
            if fact.state == "running", let s = fact.status, s.state == .blocked {
                var line = "\(a.name): \(s.label)"
                if let m = oneLine(s.message) { line += " — " + m }
                attention.append(SpaceState.Attention(subject: a.name, kind: blockedKind(s), text: line))
            }
            if fact.failed { attention.append(SpaceState.Attention(subject: a.name, kind: "health", text: "\(a.name): its sandbox failed")) }
            if wantsMember, let n = chatName {
                var state = "unknown"
                if let p = f.participants { state = p.contains(n) ? (fact.state == "running" || fact.state == "asleep" ? "present" : "away") : "absent" }
                items.append(settle(SpaceState.Item(subject: a.name, type: "member", lifetime: lifetime, state: state)))
            }
        }

        // Services: declared, never checked by this Mac.
        for s in i.services {
            let name = s.components(separatedBy: " (").first ?? s
            items.append(f.known ? SpaceState.Item(subject: name, type: "service", lifetime: "external", state: "unknown", detail: "not checked by this Mac")
                         : unknown(name, "service", "external"))
        }

        // Sandboxes.
        for s in i.sandboxes {
            let lifetime = life("sandbox", s.placeName, external: s.external, persisted: s.persisted != nil)
            guard f.known else { items.append(unknown(s.name, "sandbox", lifetime)); continue }
            var it = SpaceState.Item(subject: s.name, type: "sandbox", lifetime: lifetime, state: "missing")
            if let p = f.sandboxes[s.placeName] {
                switch p {
                case "running", "booting": it.state = "running"
                case "paused", "asleep", "hibernated": it.state = "hibernated"
                case "failed":
                    it.state = "stopped"; it.detail = "failed"
                    attention.append(SpaceState.Attention(subject: s.name, kind: "health", text: "\(s.name): the sandbox \(s.placeName) failed"))
                default: it.state = "stopped"
                }
            }
            if s.placeName != s.name, it.detail == nil { it.detail = "the sandbox \(s.placeName)" }
            items.append(settle(it))
        }

        // Folders.
        let planFacts = SpaceFacts(known: true, home: f.home, projectsDir: f.projectsDir)
        let kept = SpaceUp.keptFolderPaths(i, planFacts)
        for x in i.folders {
            let lifetime = life("folder", x.name, external: x.path != nil, persisted: x.persisted != nil)
            guard f.known else { items.append(unknown(x.name, "folder", lifetime)); continue }
            var path: String?
            if let p = x.path { path = f.expand(p) }
            else if let k = kept.first(where: { $0.name == x.name }) { path = k.path }
            else if let o = rec?.openRun { path = ref?.scratch?.last { $0.run == o.id && $0.name == x.name }?.path }
            let there = path.map { f.folders[$0] ?? false } ?? false
            items.append(settle(SpaceState.Item(subject: x.name, type: "folder", lifetime: lifetime, state: there ? "present" : "missing"), optional: x.optional))
        }

        // Rooms.
        let fileRooms = Set(i.rooms.map(\.chatRoom))
        for r in i.rooms {
            let lifetime = life("room", r.chatRoom, external: r.external, persisted: r.persisted != nil)
            guard f.known else { items.append(unknown(r.name, "room", lifetime)); continue }
            var it = SpaceState.Item(subject: r.name, type: "room", lifetime: lifetime, state: roomState(r.chatRoom, f),
                                     detail: r.chatRoom != r.name ? "the room \(r.chatRoom)" : nil)
            if it.state == "gone" { it.detail = nil }
            items.append(it.state == "unknown" || it.state == "gone" ? it : settle(it))
        }

        // Extras: what the record or the chat server holds, named like the space, that the file does not name.
        var extras: [SpaceState.Item] = []
        if f.known, let rec {
            for a in rec.agents where a.endedAt == nil && !matched.contains(a.name) {
                if a.place.mac == true && !viewer.macSessions { continue }
                let fact = f.agents[a.name] ?? SpaceStateFacts.Agent(state: "unknown")
                var it = SpaceState.Item(subject: a.name, type: "agent", lifetime: "run", state: fact.state, detail: "in the workspace, not in the file",
                                         drift: SpaceState.Drift(kind: "extra", text: fact.state == "running" ? "running, but not in the file" : "in the workspace, but not in the file"))
                if fact.state == "running" { it.activity = activity(fact.status) }
                extras.append(it)
            }
            var seen = fileRooms
            for room in rec.rooms where room.goneAt == nil && !seen.contains(room.chatRoom) {
                seen.insert(room.chatRoom)
                extras.append(SpaceState.Item(subject: room.chatRoom, type: "room", lifetime: "run", state: roomState(room.chatRoom, f),
                                              detail: "in the workspace, not in the file",
                                              drift: SpaceState.Drift(kind: "extra", text: "a room of the workspace, not in the file")))
            }
            for room in (f.rooms ?? []).sorted() where (room == i.space || room.hasPrefix(i.space + "-")) && !seen.contains(room) {
                extras.append(SpaceState.Item(subject: room, type: "room", lifetime: "run", state: roomState(room, f), detail: "a room named like this space",
                                              drift: SpaceState.Drift(kind: "extra", text: "a room named like this space, not in the file")))
            }
        }
        attention += askItems(intent: i, record: rec, facts: f, viewer: viewer)
        if f.upStopped {
            attention.append(SpaceState.Attention(subject: i.space, kind: "refusal",
                                                  text: "up stopped at a failure: the rest was not run — doz workspace up again makes only what is missing"))
        }
        doc.items = items
        doc.extras = extras.sorted { ($0.type, $0.subject) < ($1.type, $1.subject) }
        doc.attention = attention.sorted { ($0.subject, $0.kind, $0.text, $0.askId ?? "") < ($1.subject, $1.kind, $1.text, $1.askId ?? "") }
        doc.seal()
        return doc
    }

    /// One attention item per open ask: its subject the asker's name in the file (the record agent whose name or bot is
    /// the asker), else the space; the text never the message's; the question only for a viewer who may read it; the
    /// options the one question's labels and "Decline" (none for several questions or several options at once); the
    /// answerers its deciders; `canAnswer` only where it may be answered, by one of its deciders who did not ask it, with
    /// one string.
    static func askItems(intent i: SpaceIntent, record rec: WorkspaceRecord?, facts f: SpaceStateFacts, viewer: SpaceStateViewer) -> [SpaceState.Attention] {
        askItems(facts: f, viewer: viewer) { from in
            for a in i.agents {
                if a.name == from { return a.name }
                if let e = recordAgent(a, rec), e.name == from || e.bot == from { return a.name }
            }
            return i.space
        }
    }

    /// The same, with the asker's subject named by `subject` (751: a workspace with no space file names its record's agents).
    static func askItems(facts f: SpaceStateFacts, viewer: SpaceStateViewer, subject: (String) -> String) -> [SpaceState.Attention] {
        guard let asks = f.asks else { return [] }
        let iso = ISO8601DateFormatter()
        func when(_ s: String?) -> String? {
            guard let s, !s.isEmpty else { return nil }
            for o in [ISO8601DateFormatter.Options.withInternetDateTime, [.withInternetDateTime, .withFractionalSeconds]] {
                iso.formatOptions = o
                if let d = iso.date(from: s) { return SpaceState.time(d) }
            }
            return nil
        }
        return asks.sorted { ($0.room, $0.at, $0.msgId) < ($1.room, $1.at, $1.msgId) }.map { a in
            var x = SpaceState.Attention(subject: subject(a.from), kind: "ask", text: "\(a.from) asks a question")
            x.askId = a.msgId
            x.room = a.room
            x.from = a.from
            x.openedAt = SpaceState.time(Date(timeIntervalSince1970: a.at.rounded(.down)))
            let q = a.question.isEmpty ? a.title : a.question
            if viewer.askText, !f.asksDropped, !q.isEmpty { x.question = q }
            let one = a.questions == 1 && !a.multi
            x.options = one && !f.asksDropped ? a.options + ["Decline"] : []
            x.answerers = a.deciders
            let me = viewer.chatName ?? ""
            x.canAnswer = viewer.answerHere && !f.asksDropped && one && a.noDecider != true && !me.isEmpty && a.deciders.contains(me) && a.from != me
            x.expiresAt = when(a.expiresAt)
            return x
        }
    }

    /// Whether an agent of the file runs as a session on this Mac (its record's place; with none, an external session or an
    /// owned agent not in a sandbox).
    static func onMac(_ a: SpaceIntent.Agent, _ entry: WorkspaceAgent?) -> Bool {
        entry.map { $0.place.mac == true } ?? (a.session != nil || (!a.external && a.sandbox == nil))
    }

    /// What a viewer who may not see this Mac's sessions must not be told: the file's agents on this Mac (their items and
    /// members keep their keys), and the record's agents on this Mac the file does not name (left out of extras).
    public static func macSubjects(intent i: SpaceIntent, record rec: WorkspaceRecord?) -> (items: Set<String>, extras: Set<String>) {
        var items = Set<String>(), matched = Set<String>()
        for a in i.agents {
            let e = recordAgent(a, rec)
            if let e { matched.insert(e.name) }
            if onMac(a, e) { items.insert(a.name) }
        }
        let extras = Set((rec?.agents ?? []).filter { $0.endedAt == nil && $0.place.mac == true && !matched.contains($0.name) }.map(\.name))
        return (items, extras)
    }

    /// The record's entry for an agent of the file: an owned one by its name (a worker); an external bot as the manager or a
    /// worker from it; an external session by the session it adopted. The newest; one not ended first.
    static func recordAgent(_ a: SpaceIntent.Agent, _ rec: WorkspaceRecord?) -> WorkspaceAgent? {
        guard let rec else { return nil }
        let all: [WorkspaceAgent]
        if !a.external {
            all = rec.agents.filter { $0.name == a.name && $0.isWorker }
        } else if let b = a.bot {
            all = rec.agents.filter { $0.bot == b && (a.role == "manager" ? $0.isManager : $0.isWorker) }
        } else if let s = a.session {
            all = rec.agents.filter { $0.place.mac == true && $0.place.session == s }
        } else { all = [] }
        return all.last { $0.endedAt == nil } ?? all.last
    }

    /// A program's status as the editor's activity: blocked → waiting, working → working, idle or done → idle; else unknown.
    public static func activity(_ s: SessionStatus?) -> String {
        switch s?.state {
        case .blocked?: return "waiting"
        case .working?: return "working"
        case .idle?, .done?: return "idle"
        default: return "unknown"
        }
    }

    /// A blocked program's attention: a permission prompt, a question to confirm, a sign-in (a problem).
    static func blockedKind(_ s: SessionStatus) -> String {
        switch s.kind {
        case .permission?: return "permission"
        case .auth?: return "problem"
        default: return "confirm"
        }
    }

    /// The program's own message as one line of at most `messageLimit` characters (controls dropped); nil when empty.
    static func oneLine(_ m: String?) -> String? {
        guard let m else { return nil }
        let first = m.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let clean = String(String.UnicodeScalarView(first.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }))
            .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        guard !clean.isEmpty else { return nil }
        return clean.count <= messageLimit ? clean : String(clean.prefix(messageLimit - 1)) + "…"
    }

    static func roomState(_ room: String, _ f: SpaceStateFacts) -> String {
        if f.goneRooms.contains(room) && !(f.rooms?.contains(room) ?? false) { return "gone" }
        guard let rooms = f.rooms else { return "unknown" }
        guard rooms.contains(room) else { return "missing" }
        if f.archivedRooms.contains(room) { return "archived" }
        if f.closedRooms.contains(room) { return "closed" }
        return "open"
    }
}
