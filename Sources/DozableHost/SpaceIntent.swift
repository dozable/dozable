import DozableChat
import Foundation

// What a valid space file asks of Dozable, in Dozable's terms (pure): which agents, rooms, folders and sandboxes, each
// external (only referenced) or owned (made by `up`) and, if owned, run-lifetime or persisted; which settings are risky and
// which file and line set each; what this version refuses or does not apply yet. `SpaceUp.plan` turns it, with the record
// and the facts, into the steps `up` would run. docs/engineering/workspaces.md, "Space files".

public struct SpaceIntent: Codable, Equatable, Sendable {
    /// A setting and the place that set it (`FILE:LINE`, or `the default`).
    public struct Sourced: Codable, Equatable, Sendable {
        public var value: String
        public var source: String
        public init(_ value: String, _ source: String) { self.value = value; self.source = source }
        public var words: String { "\(value) from \(source)" }
    }

    public struct Agent: Codable, Equatable, Sendable {
        public var name: String
        /// `manager`, `worker` or `reviewer` (nil: worker).
        public var role: String?
        /// External: `bot`, `session` or a full name's text.
        public var bot: String?
        public var session: String?
        public var external: Bool
        /// Owned: `fenced`, `unfenced` (on this Mac) or `vm` (in `sandbox`).
        public var isolation: Sourced?
        public var sandbox: String?
        /// `standard` or `bypass` (nil: the owner's default).
        public var permissions: Sourced?
        public var folder: String?
        public var access: String?
        public var prompt: String?
        public var promptFile: String?
        public var model: String?
        public var remoteControl: Sourced?
        public var delivery: String?
        /// Rooms besides the main one, by their names in the file.
        public var rooms: [String]
        public var transcripts: Sourced?
        public var resume: String?
        /// `persist: { agent: … }` names it (with where that is written).
        public var memory: Sourced?
        public var secrets: [String]
        /// 755: `restart` (758: first-class; `x-dozable.restart` for one release) (`no`, `on-failure`; nil: not written). Recorded, not applied in this version.
        public var restart: String? = nil
    }

    public struct Room: Codable, Equatable, Sendable {
        public var name: String
        /// Its name in the chat server: the main room is the space's name; another owned room `<space>-<name>`.
        public var chatRoom: String
        public var main: Bool
        public var external: Bool
        public var members: [String]
        public var persisted: Sourced?
    }

    public struct Folder: Codable, Equatable, Sendable {
        public var name: String
        /// External: its path as written (`~` not expanded); nil: an owned scratch folder.
        public var path: String?
        public var access: String
        public var trust: Bool
        public var optional: Bool
        public var persisted: Sourced?
    }

    public struct Sandbox: Codable, Equatable, Sendable {
        public var name: String
        /// Its sandbox's name: the external one's, or `<space>-<name>`.
        public var placeName: String
        public var external: Bool
        public var image: String?
        public var folder: String?
        public var cpus: Int?
        public var memory: String?
        public var persisted: Sourced?
        /// The owned agents that run in it, in file order.
        public var agents: [String]
    }

    public struct Request: Codable, Equatable, Sendable {
        public var agent: String
        public var role: String?
        public var grants: [String]
        public var reason: String
        public var source: String
    }

    public struct Refusal: Codable, Equatable, Sendable {
        public var pointer: String
        public var message: String
        public var code: String
    }

    public var space: String
    public var title: String
    public var owner: String
    /// The brief's file as written (empty: the brief is held in the document — `briefText`).
    public var brief: String
    /// 755: `x-dozable.lifetime` as written (nil: none, read as `runs` — `effectiveLifetime`); the brief held in the
    /// document (`x-dozable.brief.text`) and its references. Optional, so an older daemon's plan still decodes.
    public var lifetime: String? = nil
    public var briefText: String? = nil
    public var briefRefs: [String]? = nil
    /// 756: the owned resources whose own `x-dozable.lifetime` is `run` — inside a standing workspace, the ones its finish
    /// removes (archived first): `agent:NAME`, `room:CHATROOM`, `sandbox:PLACE`, `folder:NAME`. Optional (an older plan decodes).
    public var runLifetime: [String]? = nil
    public var agents: [Agent] = []
    public var rooms: [Room] = []
    public var folders: [Folder] = []
    public var sandboxes: [Sandbox] = []
    /// External services, by name and what they are (`session: S`, `url: U`, a full name).
    public var services: [String] = []
    public var secrets: [String] = []
    /// `persist:` folders named by path (made on the first up if missing, recorded, never deleted).
    public var persistedPaths: [Sourced] = []
    public var archive: Sourced
    public var archiveKeep: [String] = []
    public var requests: [Request] = []
    public var deciders: [String] = []
    public var risks: [SpaceRisk] = []
    public var refusals: [Refusal] = []
    /// What this version does not apply (each named, never silently).
    public var notes: [String] = []
    /// Left out: their profile is not active.
    public var skipped: [String] = []

    /// The lifetime a reader takes: as written, else `runs` (today's meaning of a space file).
    public var effectiveLifetime: String { lifetime ?? SpaceDozable.defaultLifetime }
    public var mainRoom: Room? { rooms.first { $0.main } }
    public var manager: Agent? { agents.first { $0.role == "manager" } }
    public var ownedAgents: [Agent] { agents.filter { !$0.external } }
    public var unfenced: [String] { ownedAgents.filter { $0.isolation?.value == "unfenced" }.map(\.name) }
}

extension SpaceIntent {
    /// The permission presets Dozable holds for a space's agents in this version.
    public static let presets = ["standard", "bypass"]

    /// `model` of a VALID merged document (no error from `SpaceValidator.checkMerged`) in Dozable's terms. Pure.
    public static func compile(_ model: SpaceModel, _ doc: JValue, _ loc: SpaceLocator) -> SpaceIntent {
        func src(_ p: String) -> String { loc.sourceOf(p) ?? "the default" }
        var i = SpaceIntent(space: model.space, title: model.title, owner: model.owner, brief: model.brief,
                            archive: Sourced(model.archiveOn ? "on" : "off", model.provenance["archive"] ?? "the default"))
        i.lifetime = model.lifetime
        var run: [String] = []
        i.briefText = model.briefText
        i.briefRefs = model.briefRefs.isEmpty ? nil : model.briefRefs
        i.archiveKeep = model.archiveKeep
        i.risks = model.risks
        i.skipped = model.skipped.map(\.name)
        let persisted = { (kind: String, name: String) -> Sourced? in
            guard let p = model.persist.first(where: { $0.kind == kind && $0.names.contains(name) }) else { return nil }
            return Sourced("persisted", model.provenance["persist.\(p.entry)"] ?? "the file")
        }
        for p in model.persist where p.kind == "folder" && p.names.isEmpty {
            i.persistedPaths.append(Sourced(p.target, model.provenance["persist.\(p.entry)"] ?? "the file"))
        }

        // Folders.
        for r in model.resources where r.section == .folders {
            i.folders.append(Folder(name: r.name, path: SpaceDoc.string(r.external), access: SpaceDoc.string(SpaceDoc.member(r.def, "access")) ?? "rw",
                                    trust: SpaceDoc.string(SpaceDoc.member(r.def, "trust")) == "before",
                                    optional: SpaceDoc.bool(SpaceDoc.member(r.def, "optional")) == true, persisted: persisted("folder", r.name)))
            if SpaceDoc.string(SpaceDoc.member(r.def, "trust")) == "before" {
                i.notes.append("folder \(r.name): trust: before is not applied in this version (an agent answers its folder-trust question itself)")
            }
        }

        // Sandboxes.
        for r in model.resources where r.section == .sandboxes {
            let ext = r.external.map { e -> String in
                if let s = SpaceDoc.string(e) { return SpaceFormat.parseFullName(s)?.name ?? s }
                return r.name
            }
            i.sandboxes.append(Sandbox(name: r.name, placeName: ext ?? prefixed(r.name, model.space), external: ext != nil,
                                       image: SpaceDoc.string(SpaceDoc.member(r.def, "image")), folder: SpaceDoc.string(SpaceDoc.member(r.def, "folder")),
                                       cpus: SpaceDoc.int(SpaceDoc.member(r.def, "cpus")), memory: SpaceDoc.string(SpaceDoc.member(r.def, "memory")),
                                       persisted: persisted("sandbox", r.name), agents: []))
        }
        // space/3.1's `agent_defaults.where: sandbox`: the workspace's own VM, an owned sandbox of the run, made by the first
        // agent in it — when one is.
        if let vm = model.workspaceVM, model.agents.contains(where: { $0.lifetime != "external" && $0.sandbox == vm }) {
            i.sandboxes.append(Sandbox(name: vm, placeName: vm, external: false, image: nil, folder: nil, cpus: nil, memory: nil,
                                       persisted: nil, agents: []))
        }

        // Agents.
        for a in model.agents {
            var x = Agent(name: a.name, role: a.role, external: a.lifetime == "external", rooms: [], secrets: [])
            let p = a.pointer
            if x.external {
                if let s = SpaceDoc.string(a.external), let f = SpaceFormat.parseFullName(s) {
                    if f.type == "bot" { x.bot = f.name } else { x.session = f.name }
                } else {
                    x.bot = SpaceDoc.string(SpaceDoc.member(a.external, "bot"))
                    x.session = SpaceDoc.string(SpaceDoc.member(a.external, "session"))
                    // 755: an agent in an existing sandbox (`x-dozable.external`): adopted, never started.
                    x.sandbox = SpaceDoc.string(SpaceDoc.member(a.external, "sandbox"))
                }
                i.agents.append(x)
                continue
            }
            let d = a.def
            x.restart = SpaceDoc.string(SpaceDozable.member(d, "restart", at: .agent))
            if let r = x.restart { i.notes.append("agent \(a.name): restart: \(r) is not applied in this version") }
            if let sb = a.sandbox {
                x.sandbox = sb
                x.isolation = Sourced("vm", loc.sourceOf(p + "/where") ?? src("/agent_defaults/where"))
                if let k = i.sandboxes.firstIndex(where: { $0.name == sb }) { i.sandboxes[k].agents.append(a.name) }
            } else {
                x.isolation = Sourced(a.isolation ?? "fenced", model.provenance["agents.\(a.name).isolation"] ?? "the default")
            }
            if let perm = a.permissions {
                x.permissions = Sourced(perm, model.provenance["agents.\(a.name).permissions"] ?? "the default")
                if !presets.contains(perm) {
                    i.refusals.append(Refusal(pointer: p, message: "agent \(a.name): permissions: \(perm) is not a preset Dozable holds yet (standard or bypass)", code: "not-implemented"))
                }
            }
            x.folder = SpaceDoc.string(SpaceDoc.member(d, "folder"))
            x.access = SpaceDoc.string(SpaceDoc.member(d, "access"))
            x.prompt = SpaceDoc.string(SpaceDoc.member(d, "prompt"))
            x.promptFile = SpaceDoc.string(SpaceDoc.member(d, "prompt_file"))
            x.model = SpaceDoc.string(SpaceDoc.member(d, "model"))
            if SpaceDoc.bool(SpaceDoc.member(d, "remote_control")) == true {
                x.remoteControl = Sourced("on", model.provenance["agents.\(a.name).remote_control"] ?? "the default")
            }
            x.delivery = SpaceDoc.string(SpaceDoc.member(SpaceDoc.member(d, "chat"), "delivery"))
            x.rooms = SpaceDoc.strings(SpaceDoc.member(SpaceDoc.member(d, "chat"), "rooms")).map { SpaceFormat.parseFullName($0)?.name ?? $0 }
            x.transcripts = Sourced(a.transcripts, model.provenance["agents.\(a.name).transcripts"] ?? "the default")
            x.resume = SpaceDoc.string(SpaceDoc.member(d, "resume"))
            x.memory = persisted("agent", a.name)
            x.secrets = SpaceDoc.strings(SpaceDoc.member(d, "secrets"))
            if a.role == "manager" {
                i.refusals.append(Refusal(pointer: p, message: "a manager is an Agent / Bot: write external: { bot: NAME } for \(a.name)", code: "invalid"))
            }
            if !x.secrets.isEmpty {
                i.refusals.append(Refusal(pointer: p + "/secrets", message: "agent \(a.name): secrets for an agent Dozable starts come in a later version", code: "not-implemented"))
            }
            var notApplied: [String] = []
            if let m = x.model { notApplied.append("model \(m)") }
            if let r = x.remoteControl { notApplied.append("Remote Control (\(r.source))") }
            if let dl = x.delivery { notApplied.append("chat delivery \(dl)") }
            if x.resume == "summary" { notApplied.append("resume: summary") }
            if !notApplied.isEmpty { i.notes.append("agent \(a.name): \(notApplied.joined(separator: ", ")) not applied in this version") }
            if let r = SpaceDoc.member(d, "requests") {
                i.requests.append(Request(agent: a.name, role: SpaceDoc.string(SpaceDoc.member(r, "role")), grants: SpaceDoc.strings(SpaceDoc.member(r, "grants")),
                                          reason: SpaceDoc.string(SpaceDoc.member(r, "reason")) ?? "", source: src(p + "/requests")))
            }
            i.agents.append(x)
        }

        // Rooms: the main one is the space's name; another owned room `<space>-<name>`; an external one keeps its own.
        let roomResources = model.resources.filter { $0.section == .rooms }
        let mainName = roomResources.first { SpaceDoc.bool(SpaceDoc.member($0.def, "main")) == true }?.name
            ?? roomResources.first { $0.name == model.space }?.name
            ?? roomResources.first { $0.lifetime != "external" }?.name
        for r in roomResources {
            let isMain = r.name == mainName
            var chatRoom: String
            if let e = r.external {
                if SpaceDoc.bool(e) == true { chatRoom = r.name }
                else if let s = SpaceDoc.string(e) { chatRoom = SpaceFormat.parseFullName(s)?.name ?? s } else { chatRoom = r.name }
            } else {
                chatRoom = isMain ? model.space : prefixed(r.name, model.space)
            }
            i.rooms.append(Room(name: r.name, chatRoom: chatRoom, main: isMain, external: r.external != nil,
                                members: SpaceDoc.strings(SpaceDoc.member(r.def, "members")).map { SpaceFormat.parseFullName($0)?.name ?? $0 },
                                persisted: persisted("room", r.name)))
            if r.external == nil, SpaceDoc.string(SpaceDozable.member(r.def, "lifetime", at: .room)) == "run" { run.append("room:" + chatRoom) }
        }
        // 756: what says `x-dozable.lifetime: run` of itself (the agents' maps carry `agent_defaults` beneath them).
        for r in model.resources where r.external == nil
            && SpaceDoc.string(SpaceDozable.member(r.def, "lifetime", at: r.section == .folders ? .folder : .sandbox)) == "run" {
            switch r.section {
            case .folders: run.append("folder:" + r.name)
            case .sandboxes: if let x = i.sandboxes.first(where: { $0.name == r.name }) { run.append("sandbox:" + x.placeName) }
            default: break
            }
        }
        for a in model.agents where a.external == nil && SpaceDoc.string(SpaceDozable.member(a.def, "lifetime", at: .agent)) == "run" { run.append("agent:" + a.name) }
        i.runLifetime = run.isEmpty ? nil : run

        // Services and secrets: external only in this version.
        for r in model.resources where r.section == .services {
            if r.external == nil {
                i.refusals.append(Refusal(pointer: r.pointer, message: "Dozable has no services yet: plan refuses an owned service (\"\(r.name)\")", code: "not-implemented"))
            } else if let s = SpaceDoc.string(SpaceDoc.member(r.external, "session")) {
                i.services.append("\(r.name) (session: \(s))")
            } else if let u = SpaceDoc.string(SpaceDoc.member(r.external, "url")) {
                i.services.append("\(r.name) (\(u))")
            } else { i.services.append("\(r.name) (\(SpaceDoc.string(r.external) ?? r.name))") }
        }
        i.secrets = model.resources.filter { $0.section == .secrets }.map(\.name)

        // Approvals: a decider other than the owner is a request; `owner` is the default.
        let deciders = SpaceDoc.strings(SpaceDoc.at(doc, "/approvals/deciders"))
        i.deciders = deciders
        for d in deciders where d != "owner" {
            i.requests.append(Request(agent: d, role: "decider", grants: [], reason: "named a decider in approvals", source: src("/approvals/deciders")))
        }
        if !model.skipped.isEmpty {
            for s in model.skipped { i.notes.append("\(s.name) is only in profile \(s.profiles.joined(separator: ", ")): left out (--profile \(s.profiles[0]))") }
        }
        // 758: each use of the x-dozable form of a first-class 3.1 key, named (read for one release).
        i.notes += SpaceDozable.deprecatedUses(doc)
        if SpaceDoc.member(doc, "profiles") != nil || SpaceDoc.member(doc, "labels") != nil {
            i.notes.append("the space's labels and profiles are kept with the file; nothing else reads them in this version")
        }
        return i
    }

    /// `<space>-<name>`, unless the name already starts with `<space>-`.
    public static func prefixed(_ name: String, _ space: String) -> String {
        name == space || name.hasPrefix(space + "-") ? name : space + "-" + name
    }
}
