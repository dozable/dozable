import DozableChat
import Foundation

// A Place (model v3, docs/engineering/workspace-model.md, "Place"): an execution environment with an isolation — `vm`,
// `fenced` or `unfenced` —, its view of the folders (ro or rw), its network policy and its credentials (placeholders);
// owned by the workspace or external (an adopted sandbox: `external: {sandbox: NAME}`, the one shape).
//
// The rules it carries:
// - A fenced place is a POLICY. Each session in it gets its own fence (`MacFence`: its own proxy, placeholders and
//   profile), built from the place: nothing is shared between two sessions of one fenced place, and the fence's own rules
//   are unchanged. A VM place is one VM: its sessions share it, as a sandbox's always have.
// - Grants attach to an identity (an agent) or its session, never to a place (`doz grant PLACE …` is refused).
// - An unfenced place enforces nothing: it declares no view, network or credentials, and says "none: acts as you" for
//   each (never an empty policy).
//
// In space/3.1 a file declares places under `x-dozable.places: {NAME: {isolation, image?, cpus?, memory?, view?, network?,
// credentials?, external?}}`; `sandboxes:` still read as places with isolation vm. A workspace with no declared places
// keeps working: its places are derived from its agents (`WorkspacePlaces.derived`) — a sandbox is a vm place, a session
// on this Mac a fenced or unfenced place of its own.

public struct WorkspacePlace: Codable, Equatable, Sendable {
    public static let isolations = ["vm", "fenced", "unfenced"]
    /// What an unfenced place says of its view, its network and its credentials: it enforces nothing.
    public static let actsAsYou = "none: acts as you"
    /// The keys of a place in `x-dozable.places`.
    public static let keys = ["isolation", "image", "cpus", "memory", "view", "network", "credentials", "external"]
    /// The keys only a VM place may have.
    public static let vmKeys = ["image", "cpus", "memory"]
    /// What an unfenced place may not declare.
    public static let policyKeys = ["view", "network", "credentials"]
    /// Names a place can never take: `where:` reads them as keywords.
    public static let reserved = ["mac", "sandbox"]

    /// An adopted sandbox: only referenced, never made or removed.
    public struct External: Codable, Equatable, Sendable {
        public var sandbox: String
        public init(sandbox: String) { self.sandbox = sandbox }
    }

    /// One policy part as shown: a sentence (`none: acts as you`, a default), a folder → access map, a list, or a network.
    public enum Policy: Codable, Equatable, Sendable {
        case text(String)
        case access([String: String])
        case list([String])
        case network(preset: String, allow: [String])

        public init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) { self = .text(s); return }
            if let l = try? c.decode([String].self) { self = .list(l); return }
            struct Net: Codable { var preset: String; var allow: [String]? }
            if let n = try? c.decode(Net.self) { self = .network(preset: n.preset, allow: n.allow ?? []); return }
            self = .access(try c.decode([String: String].self))
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .text(let s): try c.encode(s)
            case .access(let m): try c.encode(m)
            case .list(let l): try c.encode(l)
            case .network(let p, let a):
                struct Net: Codable { var preset: String; var allow: [String]? }
                try c.encode(Net(preset: p, allow: a.isEmpty ? nil : a))
            }
        }

        public var words: String {
            switch self {
            case .text(let s): s
            case .access(let m): m.keys.sorted().map { "\($0) \(m[$0]!)" }.joined(separator: ", ")
            case .list(let l): l.joined(separator: ", ")
            case .network(let p, let a): p + (a.isEmpty ? "" : ", allowing \(a.joined(separator: ", "))")
            }
        }
    }

    public var name: String
    /// `vm`, `fenced` or `unfenced`.
    public var isolation: String
    public var external: External?
    public var image: String?
    public var cpus: Int?
    public var memory: String?
    public var view: Policy
    public var network: Policy
    public var credentials: Policy
    /// Where it comes from: `declared` (x-dozable.places), `sandboxes` (space/3.1's sandboxes:), `workspace-vm`
    /// (agent_defaults.where: sandbox) or `derived` (from an agent of a workspace with no declared place).
    public var from: String

    public init(name: String, isolation: String, external: External? = nil, image: String? = nil, cpus: Int? = nil, memory: String? = nil,
                view: Policy, network: Policy, credentials: Policy, from: String) {
        self.name = name; self.isolation = isolation; self.external = external; self.image = image; self.cpus = cpus; self.memory = memory
        self.view = view; self.network = network; self.credentials = credentials; self.from = from
    }

    /// An unfenced place: none of the three, ever.
    public static func unfenced(_ name: String, from: String) -> WorkspacePlace {
        WorkspacePlace(name: name, isolation: "unfenced", view: .text(actsAsYou), network: .text(actsAsYou), credentials: .text(actsAsYou), from: from)
    }

    /// Whether a session started here gets a fence of its own.
    public var fencesEachSession: Bool { isolation == "fenced" }
}

/// One session of a place, as `doz workspace state --json` shows it: the identity (agent) it runs, its session, its state
/// and — in a fenced place — its own fence (never shared: distinct per session).
public struct WorkspacePlaceSession: Codable, Equatable, Sendable {
    public var identity: String
    /// `@mac/SESSION` on this Mac, the sandbox's name in a VM.
    public var session: String
    /// The agent's condition (`running`, `asleep`, `stopped`, `crashed`, `not-started`, `unknown`).
    public var state: String
    /// Its fence's tag (`doz-fence:TAG`, the one in its profile's denials); nil: no fence (a VM or an unfenced place).
    public var fence: String?
    public init(identity: String, session: String, state: String, fence: String? = nil) {
        self.identity = identity; self.session = session; self.state = state; self.fence = fence
    }
}

/// A place with its sessions now (`doz workspace state --json`'s `places[]`).
public struct WorkspacePlaceState: Codable, Equatable, Sendable {
    public var name: String
    public var isolation: String
    public var external: WorkspacePlace.External?
    public var view: WorkspacePlace.Policy
    public var network: WorkspacePlace.Policy
    public var credentials: WorkspacePlace.Policy
    public var from: String
    public var sessions: [WorkspacePlaceSession]
    public init(_ p: WorkspacePlace, sessions: [WorkspacePlaceSession]) {
        name = p.name; isolation = p.isolation; external = p.external; view = p.view; network = p.network; credentials = p.credentials
        from = p.from; self.sessions = sessions
    }
}

public enum WorkspacePlaces {
    /// A default part as shown for a fenced or VM place that declares none.
    static let folderDefault = "the agent's folder"
    static let credentialsDefault = "none"
    /// The network a place's sessions get when it declares none: the workspace's default (`WorkerPrepared.permissions`).
    public static let networkDefault = "locked (the workspace's default)"

    /// The place a space file's `x-dozable.places` entry declares (`network`: the workspace's, shown when the place says none).
    public static func declared(_ name: String, _ v: JValue?, workspaceNetwork: WorkspacePlace.Policy) -> WorkspacePlace {
        if let s = SpaceDoc.string(SpaceDoc.member(SpaceDoc.member(v, "external"), "sandbox")) {
            return WorkspacePlace(name: name, isolation: "vm", external: .init(sandbox: s), view: .text("its own (an external sandbox)"),
                                  network: .text("its own (an external sandbox)"), credentials: .text("its own (an external sandbox)"), from: "declared")
        }
        let iso = SpaceDoc.string(SpaceDoc.member(v, "isolation")) ?? "fenced"
        if iso == "unfenced" { return .unfenced(name, from: "declared") }
        var view: WorkspacePlace.Policy = .text(folderDefault)
        if let m = SpaceDoc.member(v, "view"), SpaceDoc.isMap(m) {
            var a: [String: String] = [:]
            for x in SpaceDoc.members(m) { a[x.key] = SpaceDoc.string(x.value) ?? "rw" }
            view = .access(a)
        }
        let creds = SpaceDoc.strings(SpaceDoc.member(v, "credentials"))
        return WorkspacePlace(name: name, isolation: iso, image: iso == "vm" ? SpaceDoc.string(SpaceDoc.member(v, "image")) : nil,
                              cpus: iso == "vm" ? SpaceDoc.int(SpaceDoc.member(v, "cpus")) : nil,
                              memory: iso == "vm" ? SpaceDoc.string(SpaceDoc.member(v, "memory")) : nil,
                              view: view, network: network(SpaceDoc.member(v, "network")) ?? workspaceNetwork,
                              credentials: creds.isEmpty ? .text(credentialsDefault) : .list(creds), from: "declared")
    }

    /// A network as written (`standard`, or `{preset?, allow?}`); nil: none written.
    public static func network(_ v: JValue?) -> WorkspacePlace.Policy? {
        guard let v else { return nil }
        if let s = SpaceDoc.string(v) { return .network(preset: s, allow: []) }
        guard SpaceDoc.isMap(v) else { return nil }
        return .network(preset: SpaceDoc.string(SpaceDoc.member(v, "preset")) ?? "standard", allow: SpaceDoc.strings(SpaceDoc.member(v, "allow")))
    }

    /// A VM place for a space/3.1 `sandboxes:` entry (or the workspace's own VM).
    public static func vm(_ name: String, image: String?, cpus: Int?, memory: String?, external: String?, network: WorkspacePlace.Policy,
                          from: String) -> WorkspacePlace {
        if let e = external {
            return WorkspacePlace(name: name, isolation: "vm", external: .init(sandbox: e), view: .text("its own (an external sandbox)"),
                                  network: .text("its own (an external sandbox)"), credentials: .text("its own (an external sandbox)"), from: from)
        }
        return WorkspacePlace(name: name, isolation: "vm", image: image, cpus: cpus, memory: memory, view: .text(folderDefault), network: network,
                              credentials: .text(credentialsDefault), from: from)
    }

    /// The place of an agent of a workspace that declares none: its sandbox (a vm place — external when it was adopted
    /// there, `external: {sandbox}`), or its session on this Mac (fenced or unfenced, as the agent runs), named as a
    /// person types it.
    public static func derived(_ a: WorkspaceAgent, fenced: Bool?) -> WorkspacePlace? {
        if let s = a.place.sandbox {
            // An agent adopted into a sandbox (no task, not a manager): the sandbox is external — the workspace never made it.
            let adopted = !a.isManager && !a.isWorker
            return WorkspacePlace(name: s, isolation: "vm", external: adopted ? .init(sandbox: s) : nil,
                                  view: .text(adopted ? "its own (an external sandbox)" : folderDefault),
                                  network: .text(adopted ? "its own (an external sandbox)" : "the sandbox's"),
                                  credentials: .text(adopted ? "its own (an external sandbox)" : credentialsDefault), from: "derived")
        }
        guard a.place.mac == true, a.place.session != nil else { return nil }
        let isFenced = fenced ?? (a.isolation != "unfenced")
        if !isFenced { return .unfenced(a.place.display, from: "derived") }
        return WorkspacePlace(name: a.place.display, isolation: "fenced", view: .text(folderDefault), network: .text("its fence's own"),
                              credentials: .text(credentialsDefault), from: "derived")
    }

    /// The places with their sessions: each declared place (`declared`, in order) with the agents in it (`placeOf`: agent →
    /// place name), then a derived place for every other agent (sharing one when they share a sandbox). `fence`: an agent's
    /// fence tag (nil: no fence); `state`: its condition.
    public static func states(declared: [WorkspacePlace], agents: [WorkspaceAgent], placeOf: (WorkspaceAgent) -> String?,
                              fence: (WorkspaceAgent) -> String?, fenced: (WorkspaceAgent) -> Bool?, state: (WorkspaceAgent) -> String) -> [WorkspacePlaceState] {
        var out = declared.map { WorkspacePlaceState($0, sessions: []) }
        for a in agents where a.endedAt == nil {
            let session = WorkspacePlaceSession(identity: a.name, session: a.place.display, state: state(a), fence: fence(a))
            if let n = placeOf(a), let k = out.firstIndex(where: { $0.name == n }) {
                out[k].sessions.append(session); continue
            }
            guard let p = derived(a, fenced: fenced(a)) else { continue }
            if p.isolation == "vm", let k = out.firstIndex(where: { $0.name == p.name && $0.isolation == "vm" }) {
                out[k].sessions.append(session); continue
            }
            out.append(WorkspacePlaceState(p, sessions: [session]))
        }
        return out
    }
}
