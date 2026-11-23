import DozableChat
import Foundation

// 755: the document of every workspace (docs/engineering/workspace-model.md). A workspace is ONE document (the spec: what
// should exist) plus its record (the status: runtime facts, the phase, the runs) and one controller (the daemon). Until the
// revision store, the document is not stored: it is GENERATED, purely, from what the workspace already is —
//
// - a workspace with no space file: `RecordDocument.generate` maps its record onto a space/3.1 document (758: the
//   first-class keys first-class, the held ones still under `x-dozable` — `SpaceDozable.Place.firstClass`),
//   `x-dozable.lifetime: standing` (the lifetime is not a 3.1 key);
// - a space-file workspace: the merged spec its last `up` recorded (`space.json`, the file as the resolver merged it), in
//   its 3.1 form (`SpaceDozable.lift`), with the record's extras merged in (`RecordDocument.merge`: an agent added or
//   adopted since, which the file does not name), and its lifetime as written under `x-dozable` — `runs` when it says none.
//
// The document never holds a secret's value (a reference only — the space file's own `secrets:` refs are kept as written),
// never a grant (requests only, and a record's grants are not a request: they stay out), never a token or a fingerprint, and
// never the phase (no time, no run, no "running"). It is produced here, in DozableHost, as an ordered JSON value — the merged
// shape the daemon already handles; YAML text is the CLI's rendering (`doz workspace doc --write`): no YAML here.

public enum RecordDocument {
    /// What the generation reads: the record, the brief's text, and the few facts outside the record it needs.
    public struct Inputs: Sendable {
        public var record: WorkspaceRecord
        public var briefText: String
        /// The person's chat name (`owner:`); nil: chat has no one yet — `you`.
        public var owner: String?
        /// This Mac in a full name (`doz://HOST/…`), already a name (`hostSlug`).
        public var host: String
        /// The chat rooms this workspace's own log says it made (`room-made`): owned, when the record does not say.
        public var roomsMade: Set<String>
        /// A room another workspace's log says it made → that workspace (the shared-room rule: one owner, the others link).
        public var roomOwners: [String: String]
        public init(record: WorkspaceRecord, briefText: String, owner: String? = nil, host: String = "this-mac",
                    roomsMade: Set<String> = [], roomOwners: [String: String] = [:]) {
            self.record = record; self.briefText = briefText; self.owner = owner; self.host = host
            self.roomsMade = roomsMade; self.roomOwners = roomOwners
        }
    }

    /// The document and what it could not say (each a sentence: what the record holds that the document does not carry).
    public struct Generated: Sendable, Equatable {
        public var document: JValue
        public var notes: [String]
    }

    /// The names a document gives: `[a-z][a-z0-9-]*`, one namespace across every section, each taken once.
    struct Names {
        var used: Set<String> = []
        mutating func take(_ want: String, fallback: String) -> String {
            var s = ""
            for c in want.lowercased().unicodeScalars {
                let ok = ("a"..."z").contains(c) || ("0"..."9").contains(c)
                s += ok ? String(c) : (s.hasSuffix("-") || s.isEmpty ? "" : "-")
            }
            while s.hasSuffix("-") { s.removeLast() }
            while let f = s.unicodeScalars.first, !("a"..."z").contains(f) { s.removeFirst() }
            if s.isEmpty { s = fallback }
            // A clash (a folder named like the space, whose main room takes its name): `<name>-<kind>` first, then numbers.
            var name = s, n = 2
            if used.contains(name), s != fallback { name = "\(s)-\(fallback)" }
            while used.contains(name) { name = "\(s)-\(n)"; n += 1 }
            used.insert(name)
            return name
        }
    }

    /// A display name as a full name's host (`doz://HOST/…`): lower-case letters, digits and -, never empty.
    public static func hostSlug(_ display: String) -> String {
        var s = ""
        for c in display.lowercased().unicodeScalars {
            let ok = ("a"..."z").contains(c) || ("0"..."9").contains(c)
            s += ok ? String(c) : (s.hasSuffix("-") || s.isEmpty ? "" : "-")
        }
        while s.hasSuffix("-") { s.removeLast() }
        return s.isEmpty ? "this-mac" : s
    }

    // MARK: the record's document

    /// The record as a space/3.1 document (the held keys under `x-dozable`). Pure.
    public static func generate(_ i: Inputs) -> Generated {
        let rec = i.record
        var names = Names()
        var notes: [String] = []
        let space = rec.name
        names.used.insert(space)            // the main room takes the space's name

        // The brief held here, the network default; x-dozable: the lifetime (always written; held — not a 3.1 key).
        var brief: [JMember] = [JMember("text", .string(i.briefText))]
        if !rec.brief.refs.isEmpty { brief.append(JMember("refs", .strings(rec.brief.refs))) }
        if !rec.addenda.isEmpty { brief.append(JMember("addenda", addendaValue(rec.addenda))) }

        var top: [JMember] = [
            JMember("doz", .string(SpaceFormat.doz31)),
            JMember("space", .string(space)),
            JMember("owner", .string(i.owner.flatMap { $0.isEmpty ? nil : $0 } ?? "you")),
            JMember("brief", .object(brief)),
        ]
        if let n = rec.defaults.network {
            if SpaceDozable.networks.contains(n) { top.append(JMember("network", .string(n))) }
            else { notes.append("its network default \(n) is not a preset the document can name") }
        }
        top.append(JMember(SpaceDozable.key, .object([JMember("lifetime", .string("standing"))])))

        // agent_defaults: where its new workers run.
        if let iso = rec.defaults.isolation {
            if iso == "fenced" { top.append(JMember("agent_defaults", .object([JMember("isolation", .string("fenced"))]))) }
            else if iso == "vm" {
                top.append(JMember("agent_defaults", .object([JMember(SpaceDozable.key, .object([JMember("isolation", .string("vm"))]))])))
            }
        }

        // Folders: each external, the main one marked.
        var folders: [JMember] = []
        var mainFolder: String?
        let mainPath = rec.mainFolder?.path
        for f in rec.folders {
            let key = names.take((f.path as NSString).lastPathComponent, fallback: "folder")
            var def: [JMember] = [JMember("external", .string(f.path))]
            if f.mode == "ro" { def.append(JMember("access", .string("ro"))) }
            if f.path == mainPath {
                def.append(JMember("main", .bool(true)))
                mainFolder = key
            }
            folders.append(JMember(key, .object(def)))
        }
        if !folders.isEmpty { top.append(JMember("folders", .object(folders))) }

        // Agents (and the sandboxes the workspace's own workers run in).
        var sandboxes: [JMember] = []
        var sandboxKeys: [String: String] = [:]
        for a in rec.agents where a.endedAt == nil && a.isWorker && !(a.bot != nil && a.anonymous != true) {
            guard let s = a.place.sandbox, sandboxKeys[s] == nil else { continue }
            let k = names.take(s, fallback: "sandbox")
            sandboxKeys[s] = k
            sandboxes.append(JMember(k, .object([])))
            if k != s { notes.append("the sandbox \(s) is named \(k) in the document") }
        }
        var agents: [JMember] = []
        for a in rec.agents where a.endedAt == nil {
            guard let (key, def) = agent(a, names: &names, mainFolder: mainFolder, host: i.host, sandboxKeys: sandboxKeys, notes: &notes) else { continue }
            agents.append(JMember(key, def))
        }
        for d in rec.declaredWorkers {
            let key = names.take(d.name, fallback: "worker")
            var def: [JMember] = [JMember("kind", .string("claude-code")), JMember("role", .string("worker")), JMember("prompt", .string(d.task))]
            if let m = mainFolder { def.append(JMember("folder", .string(m))) }
            agents.append(JMember(key, .object(def)))
        }
        if !agents.isEmpty { top.append(JMember("agents", .object(agents))) }
        if !sandboxes.isEmpty { top.append(JMember("sandboxes", .object(sandboxes))) }

        // Rooms: owned, or linked by the shared-room rule (another workspace made it → its full name; none → `_`).
        var rooms: [JMember] = []
        for r in rec.rooms where r.goneAt == nil {
            let owned = r.owned ?? i.roomsMade.contains(r.chatRoom)
            if owned {
                let key = r.main && r.chatRoom == space ? space : names.take(r.main ? r.chatRoom : r.label, fallback: "room")
                if r.main && r.chatRoom != space { notes.append("its main room \(r.chatRoom) is not named after the workspace") }
                var def: [JMember] = []
                if r.main { def.append(JMember("main", .bool(true))) }
                rooms.append(JMember(key, .object(def)))
            } else {
                let key = names.take(r.main ? r.chatRoom : r.label, fallback: "room")
                let owner = i.roomOwners[r.chatRoom].flatMap { SpaceFormat.isName($0) ? $0 : nil } ?? "_"
                var def: [JMember] = [JMember("external", .string("doz://\(i.host)/\(owner)/room/\(r.chatRoom)"))]
                if r.main { def.append(JMember("main", .bool(true))) }
                rooms.append(JMember(key, .object(def)))
            }
        }
        if !rooms.isEmpty { top.append(JMember("chat", .object([JMember("rooms", .object(rooms))]))) }
        return Generated(document: .object(top), notes: notes)
    }

    /// One agent of the record as the document says it (nil: nothing the document can say — an agent elsewhere).
    static func agent(_ a: WorkspaceAgent, names: inout Names, mainFolder: String?, host: String, sandboxKeys: [String: String],
                      notes: inout [String]) -> (String, JValue)? {
        func bot(_ b: String) -> JValue {
            SpaceFormat.isName(b) ? .object([JMember("bot", .string(b))]) : .string("doz://\(host)/_/bot/\(b)")
        }
        if a.place.key == nil {
            notes.append("\(a.name) runs elsewhere: the document cannot name it yet")
            return nil
        }
        let key = names.take(a.name, fallback: "agent")
        if key != a.name { notes.append("the agent \(a.name) is named \(key) in the document") }
        if a.isManager {
            // A manager is an Agent / Bot: external, never owned.
            if let iso = a.isolation, iso != "fenced" { notes.append("its manager's isolation (\(iso)) is the record's: the document does not carry it yet") }
            return (key, .object([JMember("external", bot(a.bot ?? a.name)), JMember("role", .string("manager"))]))
        }
        if a.isWorker {
            if let b = a.bot, a.anonymous != true {
                notes.append("the worker \(a.name) is the bot \(b): its task is the record's, an external agent has no prompt")
                return (key, .object([JMember("external", bot(b)), JMember("role", .string("worker"))]))
            }
            var def: [JMember] = [JMember("kind", .string("claude-code")), JMember("role", .string("worker"))]
            if let s = a.place.sandbox {
                def.append(JMember("where", .string("sandbox:" + (sandboxKeys[s] ?? s))))
            } else {
                def.append(JMember("isolation", .string(a.isolation == "unfenced" ? "unfenced" : "fenced")))
            }
            if let m = mainFolder { def.append(JMember("folder", .string(m))) }
            def.append(JMember("prompt", .string(a.task ?? "")))
            return (key, .object(def))
        }
        // Adopted: a session on this Mac, or a sandbox — only referenced.
        if a.place.mac == true, let s = a.place.session {
            return (key, .object([JMember("external", .object([JMember("session", .string(s))]))]))
        }
        if let s = a.place.sandbox {
            return (key, .object([JMember("external", .object([JMember("sandbox", .string(s))]))]))
        }
        return nil
    }

    // MARK: a space file's document

    /// A space-file workspace's document: the spec its last up recorded in its 3.1 form (`SpaceDozable.lift`), the record's
    /// extras merged in — each agent the record holds (not ended) that the file names nowhere: by its name, its bot, its
    /// session or its sandbox — and its lifetime written (`runs` when the file says none). Pure.
    public static func merge(spec: JValue, record: WorkspaceRecord, host: String = "this-mac") -> Generated {
        var notes: [String] = []
        let lifted = SpaceDozable.lift(spec)
        var top = SpaceDoc.members(lifted)
        // The lifetime, always written (under x-dozable: not a space/3.1 key).
        if SpaceDozable.lifetime(lifted) == nil {
            top = SpaceDoc.members(withLifetime(.object(top), SpaceDozable.defaultLifetime))
            notes.append("the space file says no lifetime: it is read as runs")
        }
        // The record's extras.
        let declared = SpaceDoc.members(SpaceDoc.member(spec, "agents"))
        var names = Names()
        for s in SpaceFormat.Section.allCases {
            let section = s == .rooms ? SpaceDoc.members(SpaceDoc.member(SpaceDoc.member(spec, "chat"), "rooms")) : SpaceDoc.members(SpaceDoc.member(spec, s.rawValue))
            for m in section { names.used.insert(m.key) }
        }
        func named(_ a: WorkspaceAgent) -> Bool {
            declared.contains { m in
                let e = SpaceDoc.member(m.value, "external")
                if m.key == a.name { return true }
                if let b = SpaceDoc.string(SpaceDoc.member(e, "bot")), b == a.bot || b == a.name { return true }
                if let s = SpaceDoc.string(e), let f = SpaceFormat.parseFullName(s), f.name == a.bot || f.name == a.name { return true }
                if let s = SpaceDoc.string(SpaceDoc.member(e, "session")), s == a.place.session { return true }
                if let s = SpaceDoc.string(SpaceDoc.member(SpaceDozable.member(m.value, "external", at: .agent), "sandbox")), s == a.place.sandbox { return true }
                return false
            }
        }
        var extras: [JMember] = []
        var sandboxes: [JMember] = []
        let declaredSandboxes = SpaceDoc.members(SpaceDoc.member(spec, "sandboxes")).map(\.key)
        var sandboxKeys: [String: String] = [:]
        let extraAgents = record.agents.filter { $0.endedAt == nil && !named($0) }
        for a in extraAgents where a.isWorker {
            guard let s = a.place.sandbox, sandboxKeys[s] == nil else { continue }
            // A sandbox the file declares under its own name, or `<space>-<name>` as up makes it; else a new entry.
            if let k = declaredSandboxes.first(where: { $0 == s || SpaceIntent.prefixed($0, record.name) == s }) { sandboxKeys[s] = k; continue }
            let k = names.take(s, fallback: "sandbox")
            sandboxKeys[s] = k
            sandboxes.append(JMember(k, .object([])))
        }
        for a in extraAgents {
            guard let (key, def) = agent(a, names: &names, mainFolder: nil, host: host, sandboxKeys: sandboxKeys, notes: &notes) else { continue }
            extras.append(JMember(key, def))
            notes.append("\(a.name) is the record's, not the file's: added or adopted since the last up")
        }
        func append(_ section: String, _ add: [JMember]) {
            guard !add.isEmpty else { return }
            if let i = top.firstIndex(where: { $0.key == section }), case .object(let m) = top[i].value { top[i].value = .object(m + add) }
            else { top.append(JMember(section, .object(add))) }
        }
        append("agents", extras)
        append("sandboxes", sandboxes)
        // 766: the work description's addenda are the record's — in the brief's map (a brief written as a file's path
        // becomes `{file: PATH}`, the same brief).
        if !record.addenda.isEmpty {
            let add = JMember("addenda", addendaValue(record.addenda))
            if let i = top.firstIndex(where: { $0.key == "brief" }) {
                if case .object(var m) = top[i].value { m.removeAll { $0.key == "addenda" }; m.append(add); top[i].value = .object(m) }
                else if let path = SpaceDoc.string(top[i].value) { top[i].value = .object([JMember("file", .string(path)), add]) }
            } else if let i = top.firstIndex(where: { $0.key == SpaceDozable.key }), case .object(var x) = top[i].value,
                      let j = x.firstIndex(where: { $0.key == "brief" }), case .object(var m) = x[j].value {
                m.removeAll { $0.key == "addenda" }
                m.append(add)
                x[j].value = .object(m)
                top[i].value = .object(x)
            }
        }
        return Generated(document: .object(top), notes: notes)
    }

    /// The addenda as the document holds them: `[{run?, at, by, text}]`, oldest first.
    static func addendaValue(_ addenda: [WorkspaceAddendum]) -> JValue {
        .array(addenda.map { a in
            var m: [JMember] = []
            if let r = a.run { m.append(JMember("run", .string(r))) }
            m.append(JMember("at", .string(HostWire.isoFormatter().string(from: a.at))))
            m.append(JMember("by", .string(a.by)))
            m.append(JMember("text", .string(a.text)))
            return .object(m)
        })
    }

    // MARK: the two forms

    /// What `doc --json` shows: the document with its lifetime always said — `x-dozable.lifetime` (758, option A: the
    /// lifetime is not a space/3.1 key; never a top-level `lifetime`).
    public static func view(_ doc: JValue) -> JValue {
        if SpaceDozable.lifetime(doc) != nil { return doc }
        return withLifetime(doc, SpaceDozable.effectiveLifetime(doc))
    }

    /// `doc` with `x-dozable.lifetime` set to `lifetime` (first in its x-dozable map; a new map goes after `brief`, `about`,
    /// `network`, `owner` or `space`, whichever comes last of the first found).
    static func withLifetime(_ doc: JValue, _ lifetime: String) -> JValue {
        var top = SpaceDoc.members(doc).filter { $0.key != "lifetime" }
        if let i = top.firstIndex(where: { $0.key == SpaceDozable.key }), case .object(var m) = top[i].value {
            m.removeAll { $0.key == "lifetime" }
            m.insert(JMember("lifetime", .string(lifetime)), at: 0)
            top[i].value = .object(m)
        } else {
            let after = ["network", "layout", "about", "brief", "owner", "title", "space"]
            let at = after.lazy.compactMap { k in top.firstIndex { $0.key == k } }.first.map { $0 + 1 } ?? top.count
            top.insert(JMember(SpaceDozable.key, .object([JMember("lifetime", .string(lifetime))])), at: at)
        }
        return .object(top)
    }

    /// What a file holds (`doc --write`): the document itself — space/3.1, its lifetime under `x-dozable`.
    public static func fileForm(_ view: JValue) -> JValue { view }
}

/// `workspace-doc`'s answer: the document as ordered JSON text (its order is the document's), where it came from, and what
/// it could not say. The CLI prints it as `{kind: Document, schema: 1, workspace, from, document, notes}`.
public struct WorkspaceDocumentAnswer: Codable, Equatable, Sendable {
    public var workspace: String
    /// `record` (generated from the record) or `space-file` (the recorded spec with the record's extras).
    public var from: String
    /// The document's JSON text (the `view` form: `x-dozable.lifetime` always said).
    public var document: String
    public var notes: [String]
    public init(workspace: String, from: String, document: String, notes: [String]) {
        self.workspace = workspace; self.from = from; self.document = document; self.notes = notes
    }

    public static let kind = "Document"
    public static let schema = 1

    /// The `--json` answer.
    public func answer() throws -> JValue {
        let doc = try ChatJSON.parse(Data(document.utf8))
        var m: [JMember] = [JMember("kind", .string(Self.kind)), JMember("schema", .int(Int64(Self.schema))),
                            JMember("workspace", .string(workspace)), JMember("from", .string(from)), JMember("document", doc)]
        if !notes.isEmpty { m.append(JMember("notes", .strings(notes))) }
        return .object(m)
    }
}
