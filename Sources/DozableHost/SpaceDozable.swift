import DozableChat
import Foundation

// 755: the space/3.1 keys, accepted under the `x-dozable` extension until the owner's go makes them first-class
// (docs/engineering/workspace-model.md, "The x-dozable keys"). ONE rule spells every one of them: the 3.1 key is written
// one level down, inside an `x-dozable` map at the place where 3.1 puts it, unchanged in name and shape —
//
//     top level        x-dozable: { lifetime, brief, network, about, layout }
//     a folder         x-dozable: { main, lifetime }
//     an agent         x-dozable: { restart, network, external: { sandbox }, lifetime }
//     a room, sandbox  x-dozable: { lifetime }
//     agent_defaults   x-dozable: { isolation }          (`vm`: where a record's new workers run; 3.1 has no key for it yet)
//
// so moving them first-class is a mechanical rename: lift each key out of its `x-dozable` map. Every other `x-` key is
// ignored as before; `x-dozable` itself is checked strictly (an unknown key in it is an error with a suggestion). Nothing
// here changes the meaning of a space/3 key.

public enum SpaceDozable {
    public static let key = "x-dozable"
    public static let topKeys = ["lifetime", "brief", "network", "about", "layout"]
    public static let folderKeys = ["main", "lifetime"]
    public static let agentKeys = ["restart", "network", "external", "lifetime"]
    public static let resourceKeys = ["lifetime"]
    public static let agentDefaultsKeys = ["isolation"]
    public static let briefKeys = ["text", "file", "refs"]
    public static let networkKeys = ["preset", "allow"]
    public static let aboutKeys = ["title", "summary", "description", "icon", "tags", "category", "needs"]
    public static let externalKeys = ["sandbox"]

    /// `standing`: every owned thing persists (scratch folders too); `runs`: the format's run model.
    public static let lifetimes = ["standing", "runs"]
    /// A read document with no lifetime is read as `runs` (today's meaning of a space file).
    public static let defaultLifetime = "runs"
    public static let restarts = ["no", "on-failure"]
    public static let networks = ["locked", "standard", "open"]
    public static let defaultsIsolations = ["fenced", "vm"]

    /// The `x-dozable` map of `v` (nil: none).
    public static func of(_ v: JValue?) -> JValue? { SpaceDoc.member(v, key) }
    public static func member(_ v: JValue?, _ k: String) -> JValue? { SpaceDoc.member(of(v), k) }

    /// The document's lifetime as written (nil: it says none).
    public static func lifetime(_ doc: JValue?) -> String? { SpaceDoc.string(member(doc, "lifetime")) }
    /// What a reader takes it to be: as written, else `runs`.
    public static func effectiveLifetime(_ doc: JValue?) -> String { lifetime(doc) ?? defaultLifetime }
}

extension SpaceValidator.Schema {
    /// `x-dozable` is a map with only these keys (an unknown one named, with a suggestion).
    mutating func dozableMap(_ v: JValue, _ p: String, _ known: [String]) -> Bool {
        guard type(v, "object", p) else { return false }
        for m in SpaceDoc.members(v) where !known.contains(m.key) {
            let dym = SpaceFormat.didYouMean(m.key, known)
            err(SpaceDoc.join(p, m.key), "unknown key \"\(m.key)\" in x-dozable" + (dym.map { " (did you mean \"\($0)\"?)" } ?? ""),
                "x-dozable here holds: \(known.joined(separator: ", "))", key: true)
        }
        return true
    }

    mutating func dozableNetwork(_ v: JValue, _ p: String) {
        if SpaceDoc.string(v) != nil { oneOf(v, SpaceDozable.networks, p); return }
        guard SpaceDoc.isMap(v) else { noForm(v, p, ["text", "a map"]); return }
        _ = dozableMap(v, p, SpaceDozable.networkKeys)
        if let x = SpaceDoc.member(v, "preset") { oneOf(x, SpaceDozable.networks, p + "/preset") }
        if let a = SpaceDoc.member(v, "allow") { strings(a, p + "/allow", nonEmpty: true) }
    }

    /// The top level's `x-dozable`.
    mutating func dozableTop(_ v: JValue, _ p: String) {
        guard dozableMap(v, p, SpaceDozable.topKeys) else { return }
        for m in SpaceDoc.members(v) {
            let q = SpaceDoc.join(p, m.key), x = m.value
            switch m.key {
            case "lifetime": oneOf(x, SpaceDozable.lifetimes, q)
            case "brief":
                guard dozableMap(x, q, SpaceDozable.briefKeys) else { break }
                let forms = ["text", "file"].filter { SpaceDoc.member(x, $0) != nil }
                if forms.count != 1 {
                    err(q, forms.isEmpty ? "x-dozable.brief needs its text or its file" : "x-dozable.brief is its text or its file, not both",
                        "write brief: { text: \"…\" } or brief: { file: BRIEF.md }")
                }
                if let t = SpaceDoc.member(x, "text") { _ = type(t, "string", q + "/text") }
                if let f = SpaceDoc.member(x, "file") { text(f, q + "/file", nonEmpty: true) }
                if let r = SpaceDoc.member(x, "refs") { strings(r, q + "/refs", nonEmpty: true) }
            case "network": dozableNetwork(x, q)
            case "about":
                guard dozableMap(x, q, SpaceDozable.aboutKeys) else { break }
                for a in SpaceDoc.members(x) {
                    let r = SpaceDoc.join(q, a.key)
                    switch a.key {
                    case "tags": strings(a.value, r, nonEmpty: true)
                    case "needs": _ = type(a.value, "object", r)
                    default: _ = type(a.value, "string", r)
                    }
                }
            case "layout": _ = type(x, "object", q)
            default: break
            }
        }
    }

    /// A folder's `x-dozable`.
    mutating func dozableFolder(_ v: JValue, _ p: String) {
        guard dozableMap(v, p, SpaceDozable.folderKeys) else { return }
        if let m = SpaceDoc.member(v, "main") { _ = type(m, "boolean", p + "/main") }
        if let l = SpaceDoc.member(v, "lifetime") { oneOf(l, ["run"], p + "/lifetime") }
    }

    /// An agent's `x-dozable`; `agent` is the agent's own map (an external sandbox forbids what an external agent may not say).
    mutating func dozableAgent(_ v: JValue, _ p: String, agent: JValue, agentPointer: String) {
        guard dozableMap(v, p, SpaceDozable.agentKeys) else { return }
        if let r = SpaceDoc.member(v, "restart") { oneOf(r, SpaceDozable.restarts, p + "/restart") }
        if let n = SpaceDoc.member(v, "network") { dozableNetwork(n, p + "/network") }
        if let l = SpaceDoc.member(v, "lifetime") { oneOf(l, ["run"], p + "/lifetime") }
        if let e = SpaceDoc.member(v, "external") {
            let q = p + "/external"
            guard dozableMap(e, q, SpaceDozable.externalKeys) else { return }
            guard let s = SpaceDoc.member(e, "sandbox") else { err(q, "an external agent in x-dozable is { sandbox: NAME }"); return }
            text(s, q + "/sandbox", nonEmpty: true)
            let name = SpaceDoc.parts(agentPointer).last ?? ""
            if SpaceDoc.member(agent, "external") != nil {
                err(q, "\"\(name)\" is external twice: external: and x-dozable.external", "an agent is one external thing: keep one of them")
            }
            for m in SpaceDoc.members(agent) where SpaceFormat.agentExternalForbidden.contains(m.key) {
                err(SpaceDoc.join(agentPointer, m.key), "\"\(name)\" is external, so \"\(m.key)\" can't apply",
                    "an agent in an existing sandbox (x-dozable.external) is only referenced: remove \"\(m.key)\"", key: true)
            }
        }
    }

    /// A room's or a sandbox's `x-dozable`.
    mutating func dozableResource(_ v: JValue, _ p: String) {
        guard dozableMap(v, p, SpaceDozable.resourceKeys) else { return }
        if let l = SpaceDoc.member(v, "lifetime") { oneOf(l, ["run"], p + "/lifetime") }
    }

    /// `agent_defaults`' `x-dozable`.
    mutating func dozableAgentDefaults(_ v: JValue, _ p: String) {
        guard dozableMap(v, p, SpaceDozable.agentDefaultsKeys) else { return }
        if let i = SpaceDoc.member(v, "isolation") { oneOf(i, SpaceDozable.defaultsIsolations, p + "/isolation") }
    }
}
