import DozableChat
import Foundation

// 758: space/3.1 — Dozable's keys, first-class (docs/engineering/workspace-model.md, "The space/3.1 keys"). 755 accepted
// them only under the `x-dozable` extension, one rule for all: the 3.1 key, unchanged in name and shape, one level down
// inside an `x-dozable` map at the place 3.1 puts it —
//
//     top level        x-dozable: { lifetime, brief, network, about, layout }
//     a folder         x-dozable: { main, lifetime }
//     an agent         x-dozable: { restart, network, external: { sandbox }, lifetime }
//     a room, sandbox  x-dozable: { lifetime }
//     agent_defaults   x-dozable: { isolation }
//
// so the 3.1 form is that key lifted out of its map. ONE table says which keys are first-class at each place (`firstClass`);
// the rest are HELD — still only under `x-dozable`, in either version, until their design is settled. space/3.1 is the
// MODEL-NEUTRAL keys only (model v3, option A): `brief`, `about` (its `title` replacing the top-level `title:`, which still
// reads with a note), `layout`, `network`, a folder's `main`, an agent's `restart`, `network` and `external: { sandbox }`.
// Persistence is not in 3.1: `lifetime` (top level and per resource) stays under `x-dozable`, never required; a top-level
// `lifetime:` in a 3.1 file is refused with the fix. (Persistence comes with a later version's own key.) Moving a held key
// first-class is moving it in the table: the validator checks a key by its place and name whichever form it is in
// (`SpaceValidator.Schema.dozValue`), every reader asks `member(_:_:at:)`, and `lift` writes the 3.1 form.
//
// In a `doz: space/3.1` file a first-class key is a key of the format; in a `doz: space/3` file it is refused with the fix
// (change the version line). The `x-dozable` form of a first-class key is read for one release, in either version, each use
// a note (`deprecatedUses`); both forms of one key is an error. Every other `x-` key is ignored as before; `x-dozable` itself
// is checked strictly. Nothing here changes the meaning of a space/3 key.

public enum SpaceDozable {
    public static let key = "x-dozable"

    /// Where a 3.1 key is written.
    public enum Place: String, CaseIterable, Sendable {
        case top, folder, agent, room, sandbox, agentDefaults

        /// What `x-dozable` holds here (the x-dozable form: every 3.1 key, first-class or held).
        public var dozableKeys: [String] {
            switch self {
            case .top: ["lifetime", "brief", "network", "about", "layout", "permissions", "places", "feeds"]
            case .folder: ["main", "lifetime"]
            case .agent: ["restart", "network", "external", "lifetime"]
            case .room, .sandbox: ["lifetime"]
            case .agentDefaults: ["isolation"]
            }
        }

        /// The keys space/3.1 has first-class here. HELD (x-dozable only): the lifetime (top level and the per-resource
        /// `lifetime: run` — persistence is not a 3.1 key), `agent_defaults.isolation: vm`. An agent's `external` is a space/3
        /// key already; its `{ sandbox: NAME }` form is the 3.1 one (checked in `SpaceValidator.Schema.agent`).
        public var firstClass: [String] {
            switch self {
            case .top: ["brief", "about", "layout", "network"]
            case .folder: ["main"]
            case .agent: ["restart", "network", "external"]
            case .room, .sandbox, .agentDefaults: []
            }
        }

        /// What a note calls the place.
        func words(_ name: String?) -> String {
            switch self {
            case .top: "the top level"
            case .folder: "folder \"\(name ?? "")\""
            case .agent: "agent \"\(name ?? "")\""
            case .room: "room \"\(name ?? "")\""
            case .sandbox: "sandbox \"\(name ?? "")\""
            case .agentDefaults: "agent_defaults"
            }
        }
    }

    public static let briefKeys = ["text", "file", "refs", "addenda"]
    /// 766: an addendum of the work description, as the document writes it.
    public static let addendumKeys = ["run", "at", "by", "text"]
    public static let networkKeys = ["preset", "allow"]

    /// 766: the roles `x-dozable.permissions` may ask for (the owner's role is never an agent's).
    public static var requestableRoles: [String] { RoleTable.names.filter { $0 != "owner" } }

    /// Why `w` cannot be asked for in `x-dozable.permissions` (nil: a role, or a permission id).
    public static func permissionRefusal(_ w: String) -> String? {
        if requestableRoles.contains(w) || GrantPermissions.isKnown(w) { return nil }
        return "not a role or a permission"
    }

    /// `x-dozable.permissions` read: identity → its roles and its permissions, in the file's order.
    public static func permissions(_ doc: JValue?) -> [(identity: String, roles: [String], grants: [String])] {
        SpaceDoc.members(SpaceDoc.member(of(doc), "permissions")).map { m in
            let words = SpaceDoc.strings(m.value)
            return (m.key, words.filter { requestableRoles.contains($0) }, words.filter { GrantPermissions.isKnown($0) })
        }
    }
    public static let aboutKeys = ["title", "summary", "description", "icon", "tags", "category", "needs"]
    public static let externalKeys = ["sandbox"]

    /// `standing`: every owned thing persists (scratch folders too); `runs`: the format's run model.
    public static let lifetimes = ["standing", "runs"]
    /// A read document with no lifetime is read as `runs` (today's meaning of a space file).
    public static let defaultLifetime = "runs"
    public static let restarts = ["no", "on-failure"]
    public static let networks = ["locked", "standard", "open"]
    public static let defaultsIsolations = ["fenced", "vm"]

    // MARK: the version line

    public static func isV31(_ doc: JValue?) -> Bool {
        let d = SpaceDoc.string(SpaceDoc.member(doc, "doz"))
        return d == SpaceFormat.doz31 || d == SpaceFormat.defaultsDoz31
    }

    // MARK: reading — both forms

    /// The `x-dozable` map of `v` (nil: none).
    public static func of(_ v: JValue?) -> JValue? { SpaceDoc.member(v, key) }

    /// A 3.1 key of the map `v` at `place`: the first-class key when it is one there and written, else its `x-dozable` form.
    public static func member(_ v: JValue?, _ k: String, at place: Place) -> JValue? {
        if place.firstClass.contains(k), let x = SpaceDoc.member(v, k) { return x }
        return SpaceDoc.member(of(v), k)
    }

    /// The document's lifetime as written (nil: it says none).
    public static func lifetime(_ doc: JValue?) -> String? { SpaceDoc.string(member(doc, "lifetime", at: .top)) }
    /// What a reader takes it to be: as written, else `runs`.
    public static func effectiveLifetime(_ doc: JValue?) -> String { lifetime(doc) ?? defaultLifetime }

    /// The brief's map form (`{text}` / `{file}`, with `refs`): the first-class `brief:` when it is a map, else
    /// `x-dozable.brief`. A first-class string brief is space/3's brief file (`SpaceDoc.string(member(doc, "brief"))`).
    public static func briefMap(_ doc: JValue?) -> JValue? {
        if let b = SpaceDoc.member(doc, "brief"), SpaceDoc.isMap(b) { return b }
        return SpaceDoc.member(of(doc), "brief")
    }

    // MARK: the places of a document

    /// Every map a 3.1 key may be written in: its place, its pointer, the resource's name, the map.
    public static func places(_ doc: JValue?) -> [(place: Place, pointer: String, name: String?, map: JValue)] {
        var out: [(Place, String, String?, JValue)] = []
        guard let doc, SpaceDoc.isMap(doc) else { return out }
        out.append((.top, "", nil, doc))
        if let ad = SpaceDoc.member(doc, "agent_defaults"), SpaceDoc.isMap(ad) { out.append((.agentDefaults, "/agent_defaults", nil, ad)) }
        let sections: [(Place, String, JValue?)] = [
            (.folder, "/folders", SpaceDoc.member(doc, "folders")), (.agent, "/agents", SpaceDoc.member(doc, "agents")),
            (.sandbox, "/sandboxes", SpaceDoc.member(doc, "sandboxes")),
            (.room, "/chat/rooms", SpaceDoc.member(SpaceDoc.member(doc, "chat"), "rooms")),
        ]
        for (place, base, section) in sections {
            for m in SpaceDoc.members(section) where !m.key.hasPrefix("x-") && SpaceDoc.isMap(m.value) {
                out.append((place, SpaceDoc.join(base, m.key), m.key, m.value))
            }
        }
        return out
    }

    /// Each use of the `x-dozable` form of a first-class key, as a note naming the 3.1 key (read for one release), and a 3.1
    /// file's top-level `title:` (space/3.1's `about.title`). `x-dozable.lifetime` is no such use: the lifetime is not a
    /// 3.1 key, so it gets no note.
    public static func deprecatedUses(_ doc: JValue?) -> [String] {
        let v31 = isV31(doc)
        var out: [String] = []
        for p in places(doc) {
            for m in SpaceDoc.members(of(p.map)) where p.place.firstClass.contains(m.key) {
                let at = p.place == .top ? "at the top level" : "on \(p.place.words(p.name))"
                out.append("\(p.place == .top ? "" : "\(p.place.words(p.name)): ")x-dozable.\(m.key) is read for this release only: write \(m.key): \(at)"
                           + (v31 ? "" : ", with the version line doz: space/3.1"))
            }
        }
        // The held `agent_defaults.x-dozable.isolation: vm` is space/3.1's `where: sandbox` under another name (a note only:
        // isolation stays fenced or unfenced, and the held key is read as before).
        if SpaceDoc.string(SpaceDoc.member(of(SpaceDoc.member(doc, "agent_defaults")), "isolation")) == "vm" {
            out.append("x-dozable.isolation: vm is space/3.1's agent_defaults.where: sandbox")
        }
        if v31, SpaceDoc.member(doc, "title") != nil, SpaceDoc.member(SpaceDoc.member(doc, "about"), "title") == nil {
            out.append("title is read for this release only: space/3.1 writes it as about.title (about: { title: … })")
        }
        return out
    }

    // MARK: writing — the 3.1 form

    /// The document in its 3.1 form: the version line `space/3.1` (a `space/3` one; a defaults file's likewise), every
    /// first-class key lifted out of its `x-dozable` map, in that map's place (an empty map then goes), and a top-level
    /// `title:` moved into `about.title`. A key already written first-class is kept and its `x-dozable` copy dropped. Held
    /// keys (the lifetime among them) stay under `x-dozable`. Pure.
    public static func lift(_ doc: JValue) -> JValue {
        func liftMap(_ v: JValue, _ place: Place) -> JValue {
            guard case .object(let ms) = v, let x = of(v), case .object(let xs) = x else { return v }
            let lifted = xs.filter { place.firstClass.contains($0.key) }
            guard !lifted.isEmpty else { return v }
            let kept = xs.filter { !place.firstClass.contains($0.key) }
            var out: [JMember] = []
            for m in ms {
                if m.key == key {
                    for l in lifted where SpaceDoc.member(v, l.key) == nil { out.append(l) }
                    if !kept.isEmpty { out.append(JMember(key, .object(kept))) }
                } else { out.append(m) }
            }
            return .object(out)
        }
        func section(_ v: JValue?, _ place: Place) -> JValue? {
            guard case .object(let ms) = v else { return v }
            return .object(ms.map { m in m.key.hasPrefix("x-") ? m : JMember(m.key, liftMap(m.value, place)) })
        }
        guard case .object = doc else { return doc }
        var top = liftMap(doc, .top)
        guard case .object(var ms) = top else { return top }
        for i in ms.indices {
            switch ms[i].key {
            case "doz":
                if SpaceDoc.string(ms[i].value) == SpaceFormat.doz { ms[i].value = .string(SpaceFormat.doz31) }
                if SpaceDoc.string(ms[i].value) == SpaceFormat.defaultsDoz { ms[i].value = .string(SpaceFormat.defaultsDoz31) }
            case "agent_defaults": ms[i].value = liftMap(ms[i].value, .agentDefaults)
            case "folders": ms[i].value = section(ms[i].value, .folder) ?? ms[i].value
            case "agents": ms[i].value = section(ms[i].value, .agent) ?? ms[i].value
            case "sandboxes": ms[i].value = section(ms[i].value, .sandbox) ?? ms[i].value
            case "chat":
                if case .object(var c) = ms[i].value, let r = c.firstIndex(where: { $0.key == "rooms" }) {
                    c[r].value = section(c[r].value, .room) ?? c[r].value
                    ms[i].value = .object(c)
                }
            default: break
            }
        }
        // A top-level `title:` is about.title in 3.1 (a title about already says wins; the other is dropped).
        if let t = ms.firstIndex(where: { $0.key == "title" }) {
            let title = ms[t].value
            ms.remove(at: t)
            if let a = ms.firstIndex(where: { $0.key == "about" }), case .object(var about) = ms[a].value {
                if !about.contains(where: { $0.key == "title" }) { about.insert(JMember("title", title), at: 0) }
                ms[a].value = .object(about)
            } else {
                let at = (ms.firstIndex { $0.key == "brief" } ?? ms.firstIndex { $0.key == "owner" } ?? ms.firstIndex { $0.key == "space" }).map { $0 + 1 } ?? ms.count
                ms.insert(JMember("about", .object([JMember("title", title)])), at: at)
            }
        }
        top = .object(ms)
        return top
    }
}

extension SpaceValidator.Schema {
    /// A map with only these keys (an unknown one named, with a suggestion); `label` is what the message calls the map.
    mutating func strictMap(_ v: JValue, _ p: String, _ known: [String], _ label: String) -> Bool {
        guard type(v, "object", p) else { return false }
        for m in SpaceDoc.members(v) where !known.contains(m.key) {
            let dym = SpaceFormat.didYouMean(m.key, known)
            let hint = m.key == "params" ? "params: belongs to a template, never to a stored document"
                : "\(label) holds: \(known.joined(separator: ", "))"
            err(SpaceDoc.join(p, m.key), "unknown key \"\(m.key)\" in \(label)" + (dym.map { " (did you mean \"\($0)\"?)" } ?? ""), hint, key: true)
        }
        return true
    }

    /// 774: `x-dozable.places: {NAME: {isolation, image?, cpus?, memory?, view?, network?, credentials?, external?}}` — each a
    /// Place (`WorkspacePlace`). A fenced place is a policy each session gets its own fence of; an unfenced one enforces
    /// nothing, so it declares no view, network or credentials ("none: acts as you"); an external one is an adopted sandbox,
    /// `external: {sandbox: NAME}`, and says nothing else. `mac` and `sandbox` are `where:`'s keywords, never a place.
    mutating func places(_ x: JValue, _ q: String) {
        guard type(x, "object", q) else { return }
        for m in SpaceDoc.members(x) {
            let r = SpaceDoc.join(q, m.key), v = m.value
            if !SpaceFormat.isName(m.key) {
                err(r, "\"\(m.key)\" can't be a place's name", "names are a lower-case letter, then lower-case letters, digits and -", key: true); continue
            }
            if WorkspacePlace.reserved.contains(m.key) {
                err(r, "\"\(m.key)\" can't be a place's name: where: reads it as a keyword", "pick another name (mac is this Mac; sandbox is the workspace's own VM)", key: true)
                continue
            }
            guard strictMap(v, r, WorkspacePlace.keys, "place \"\(m.key)\"") else { continue }
            if let e = SpaceDoc.member(v, "external") {
                guard strictMap(e, r + "/external", SpaceDozable.externalKeys, "an external place") else { continue }
                guard let s = SpaceDoc.member(e, "sandbox") else { err(r + "/external", "an external place is { sandbox: NAME }"); continue }
                text(s, r + "/external/sandbox", nonEmpty: true)
                if let i = SpaceDoc.member(v, "isolation"), SpaceDoc.string(i) != "vm" {
                    err(r + "/isolation", "place \"\(m.key)\" is an external sandbox, so its isolation is vm", "remove isolation:, or write isolation: vm")
                }
                for k in WorkspacePlace.keys where k != "external" && k != "isolation" && SpaceDoc.member(v, k) != nil {
                    err(SpaceDoc.join(r, k), "place \"\(m.key)\" is an external sandbox, so \"\(k)\" can't apply",
                        "an external place is only referenced: it keeps its own \(k == "view" ? "folders" : k); remove \"\(k)\"", key: true)
                }
                continue
            }
            guard let iso = SpaceDoc.member(v, "isolation") else {
                err(r, "place \"\(m.key)\" needs its isolation", "write isolation: vm, fenced or unfenced — or external: { sandbox: NAME } for a sandbox that exists already")
                continue
            }
            oneOf(iso, WorkspacePlace.isolations, r + "/isolation")
            let isolation = SpaceDoc.string(iso) ?? ""
            if isolation != "vm" {
                for k in WorkspacePlace.vmKeys where SpaceDoc.member(v, k) != nil {
                    err(SpaceDoc.join(r, k), "place \"\(m.key)\" is \(isolation), so \"\(k)\" can't apply", "only a vm place has an image, cpus and memory", key: true)
                }
            }
            if isolation == "unfenced" {
                for k in WorkspacePlace.policyKeys where SpaceDoc.member(v, k) != nil {
                    err(SpaceDoc.join(r, k), "place \"\(m.key)\" is unfenced, so it can't declare \(k): it enforces nothing (\(WorkspacePlace.actsAsYou))",
                        "remove \(k):, or fence the place (isolation: fenced) to have one", key: true)
                }
                continue
            }
            if let i = SpaceDoc.member(v, "image") { text(i, r + "/image", nonEmpty: true) }
            if let c = SpaceDoc.member(v, "cpus"), type(c, "integer", r + "/cpus"), let n = SpaceDoc.int(c), n < 1 { err(r + "/cpus", "\(n) is out of range: must be >= 1") }
            if let mem = SpaceDoc.member(v, "memory") { pattern(mem, "memory", r + "/memory") }
            if let vw = SpaceDoc.member(v, "view"), type(vw, "object", r + "/view") {
                for f in SpaceDoc.members(vw) { oneOf(f.value, SpaceFormat.accesses, SpaceDoc.join(r + "/view", f.key)) }
            }
            if let n = SpaceDoc.member(v, "network") { dozableNetwork(n, r + "/network") }
            if let c = SpaceDoc.member(v, "credentials") { strings(c, r + "/credentials", nonEmpty: true); notEmpty(c, r + "/credentials", "credentials") }
        }
    }

    /// `x-dozable` is a map with only these keys.
    mutating func dozableMap(_ v: JValue, _ p: String, _ known: [String]) -> Bool { strictMap(v, p, known, "x-dozable") }

    mutating func dozableNetwork(_ v: JValue, _ p: String) {
        if SpaceDoc.string(v) != nil { oneOf(v, SpaceDozable.networks, p); return }
        guard SpaceDoc.isMap(v) else { noForm(v, p, ["text", "a map"]); return }
        _ = strictMap(v, p, SpaceDozable.networkKeys, "network")
        if let x = SpaceDoc.member(v, "preset") { oneOf(x, SpaceDozable.networks, p + "/preset") }
        if let a = SpaceDoc.member(v, "allow") {
            strings(a, p + "/allow", nonEmpty: true)
            notEmpty(a, p + "/allow", "network.allow", "omit allow, or use preset: locked")
        }
    }

    /// A list that, when written, holds at least one item.
    mutating func notEmpty(_ v: JValue, _ p: String, _ label: String, _ hint: String = "list at least one, or leave it out") {
        if let a = SpaceDoc.array(v), a.isEmpty { err(p, "\(label) can't be empty", hint) }
    }

    /// The brief's map form; `label` is how the file writes it (`brief`, `x-dozable.brief`).
    mutating func briefMap(_ x: JValue, _ q: String, _ label: String) {
        guard strictMap(x, q, SpaceDozable.briefKeys, label) else { return }
        let forms = ["text", "file"].filter { SpaceDoc.member(x, $0) != nil }
        if forms.count != 1 {
            err(q, forms.isEmpty ? "\(label) needs its text or its file" : "\(label) is its text or its file, not both",
                "write brief: { text: \"…\" } or brief: { file: BRIEF.md }")
        }
        if let t = SpaceDoc.member(x, "text") { _ = type(t, "string", q + "/text") }
        if let f = SpaceDoc.member(x, "file") { text(f, q + "/file", nonEmpty: true) }
        if let r = SpaceDoc.member(x, "refs") { strings(r, q + "/refs", nonEmpty: true); notEmpty(r, q + "/refs", "\(label).refs") }
        // 766: the work description's addenda (the document writes them; up keeps the record's own — they are not applied).
        if let ad = SpaceDoc.member(x, "addenda"), type(ad, "array", q + "/addenda"), case .array(let items) = ad {
            for (k, item) in items.enumerated() {
                let r = q + "/addenda/\(k)"
                guard strictMap(item, r, SpaceDozable.addendumKeys, "\(label).addenda[\(k)]") else { continue }
                if let t = SpaceDoc.member(item, "text") { text(t, r + "/text", nonEmpty: true) } else { err(r, "an addendum needs its text") }
                for f in ["run", "at", "by"] { if let v = SpaceDoc.member(item, f) { _ = type(v, "string", r + "/" + f) } }
            }
        }
    }

    /// ONE 3.1 key's value at its place, whichever form it is written in. `owner` is the map the key belongs to (the
    /// agent's own, for an external sandbox's rules), `ownerPointer` its pointer; `form` is `x-dozable` or `first-class`.
    mutating func dozValue(_ place: SpaceDozable.Place, _ k: String, _ x: JValue, _ q: String, owner: JValue, ownerPointer: String, form: String) {
        let label = form == "x-dozable" ? "x-dozable.\(k)" : k
        switch (place, k) {
        case (.top, "lifetime"): oneOf(x, SpaceDozable.lifetimes, q)
        case (.top, "brief"):
            if form != "x-dozable", SpaceDoc.string(x) != nil { text(x, q, nonEmpty: true) } else { briefMap(x, q, label) }
        case (.top, "network"), (.agent, "network"): dozableNetwork(x, q)
        case (.top, "about"):
            guard strictMap(x, q, SpaceDozable.aboutKeys, label) else { break }
            // One problem per key: a key strictMap refused is not checked again for its value.
            for a in SpaceDoc.members(x) where SpaceDozable.aboutKeys.contains(a.key) {
                let r = SpaceDoc.join(q, a.key)
                switch a.key {
                case "tags": strings(a.value, r, nonEmpty: true); notEmpty(a.value, r, "\(label).tags")
                case "needs": _ = type(a.value, "object", r)
                default: _ = type(a.value, "string", r)
                }
            }
        case (.top, "layout"): _ = type(x, "object", q)
        case (.top, "permissions"):
            // 766: `{IDENTITY: [ROLE or PERMISSION, …]}` — what the workspace asks for its agents; shown in the plan as a
            // request, never granted by up (the owner grants).
            guard type(x, "object", q) else { break }
            for m in SpaceDoc.members(x) {
                let r = SpaceDoc.join(q, m.key)
                guard type(m.value, "array", r), case .array(let items) = m.value else { continue }
                for (k, item) in items.enumerated() {
                    guard let w = SpaceDoc.string(item) else { _ = type(item, "string", r + "/\(k)"); continue }
                    if SpaceDozable.permissionRefusal(w) != nil {
                        err(r + "/\(k)", "\(w.prefix(60)) is not a role or a permission",
                            "roles: \(SpaceDozable.requestableRoles.joined(separator: ", ")); permissions: \(GrantPermissions.ids.joined(separator: ", "))")
                    }
                }
            }
        case (.top, "places"): places(x, q)
        // FEEDS: `{FEED: {to: room | manager | owner | off}}` — where a feed's notices go in this workspace (Feeds.swift).
        case (.top, "feeds"):
            for p in FeedRoutes.problems(x) { err(q + p.at, p.what) }
        case (.folder, "main"): _ = type(x, "boolean", q)
        case (.folder, "lifetime"), (.agent, "lifetime"), (.room, "lifetime"), (.sandbox, "lifetime"): oneOf(x, ["run"], q)
        case (.agent, "restart"): oneOf(x, SpaceDozable.restarts, q)
        case (.agent, "external"):
            guard strictMap(x, q, SpaceDozable.externalKeys, label) else { return }
            guard let s = SpaceDoc.member(x, "sandbox") else { err(q, "an external agent in x-dozable is { sandbox: NAME }"); return }
            text(s, q + "/sandbox", nonEmpty: true)
            // First-class, `external:` is the key itself: what an external agent may not say is `agent`'s check.
            guard form == "x-dozable" else { return }
            let name = SpaceDoc.parts(ownerPointer).last ?? ""
            if SpaceDoc.member(owner, "external") != nil {
                err(q, "\"\(name)\" is external twice: external: and x-dozable.external", "an agent is one external thing: keep one of them")
            }
            for m in SpaceDoc.members(owner) where SpaceFormat.agentExternalForbidden.contains(m.key) {
                err(SpaceDoc.join(ownerPointer, m.key), "\"\(name)\" is external, so \"\(m.key)\" can't apply",
                    "an agent in an existing sandbox (x-dozable.external) is only referenced: remove \"\(m.key)\"", key: true)
            }
        case (.agentDefaults, "isolation"): oneOf(x, SpaceDozable.defaultsIsolations, q)
        default: break
        }
    }

    /// The 3.1 keys of one map at its place, in both forms: its `x-dozable` map (strict; every key it may hold), each
    /// first-class key the version allows, both forms of one key refused. A first-class key under `doz: space/3` is
    /// refused by `keys` (`versionFix`).
    mutating func dozPlace(_ place: SpaceDozable.Place, _ v: JValue, _ p: String) {
        if let x = SpaceDozable.of(v) {
            let q = SpaceDoc.join(p, SpaceDozable.key)
            if dozableMap(x, q, place.dozableKeys) {
                for m in SpaceDoc.members(x) where place.dozableKeys.contains(m.key) {
                    dozValue(place, m.key, m.value, SpaceDoc.join(q, m.key), owner: v, ownerPointer: p, form: "x-dozable")
                    if place.firstClass.contains(m.key), SpaceDoc.member(v, m.key) != nil, !(place == .top && m.key == "brief"),
                       !(place == .agent && m.key == "external") {   // external twice: `dozValue`'s own words
                        err(SpaceDoc.join(q, m.key), "\"\(m.key)\" is written twice: \(m.key): and x-dozable.\(m.key)",
                            "keep \(m.key): — the x-dozable form is read for this release only", key: true)
                    }
                }
            }
        }
        guard v31 else { return }
        // The brief and an agent's external are space/3 keys too: their 3.1 forms are checked where the key is.
        for k in place.firstClass where !(place == .top && k == "brief") && !(place == .agent && k == "external") {
            if let x = SpaceDoc.member(v, k) { dozValue(place, k, x, SpaceDoc.join(p, k), owner: v, ownerPointer: p, form: "first-class") }
        }
    }

    /// A first-class 3.1 key in a `doz: space/3` file, whose value 3.1 would take: the refusal that names the fix (nil: it
    /// is not one — the key is unknown as before, with its old hint).
    func versionFix(_ place: SpaceDozable.Place, _ k: String, _ x: JValue, _ q: String, owner: JValue) -> (String, String)? {
        guard !v31, place.firstClass.contains(k) else { return nil }
        var probe = SpaceValidator.Schema(defaults: defaults, v31: true)
        probe.dozValue(place, k, x, q, owner: owner, ownerPointer: "", form: "first-class")
        guard probe.out.isEmpty else { return nil }
        return ("\"\(k)\" is a space/3.1 key: change the version line to doz: \(defaults ? SpaceFormat.defaultsDoz31 : SpaceFormat.doz31)",
                "this file says doz: \(defaults ? SpaceFormat.defaultsDoz : SpaceFormat.doz), which has no \"\(k)\" here; space/3.1 reads every space/3 key the same")
    }
}
