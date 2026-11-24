import DozableChat
import Foundation

// The ONE validator of a space file (space/3), pure and without YAML: the CLI runs `checkSource` on each defaults file it
// read and `checkMerged` on the merged document before it sends it; the daemon runs `checkMerged` again on what it
// receives (it never opens a file), with the backstop that refuses anything that starts or owns something coming from a
// defaults file. The words are the reference's (docs/space/spec-v3/validation-errors.json, vendored; the 68 rows are
// `SpaceValidationTableTests`). docs/engineering/workspaces.md, "Space files".

/// Where a pointer of the document was set: answered from the origins the CLI sent (or, for one source, its own lines).
public struct SpaceLocator: Sendable {
    public var sources: [SpaceSource]
    public var origins: [String: SpaceOrigin]
    public init(sources: [SpaceSource], origins: [String: SpaceOrigin]) { self.sources = sources; self.origins = origins }

    var spaceIndex: Int { sources.firstIndex { $0.kind == "space" } ?? 0 }
    var spaceName: String { sources.isEmpty ? "the space file" : sources[spaceIndex].name }

    func source(_ p: String) -> SpaceSource? { origins[p].flatMap { $0.s < sources.count ? sources[$0.s] : nil } }
    /// The source that set exactly this pointer (nil: none did — the space file is meant).
    public func kind(_ p: String) -> String? { p.isEmpty ? "space" : source(p)?.kind }
    /// `NAME:LINE` of the source that set this pointer, or nil.
    public func sourceOf(_ p: String) -> String? {
        guard let o = origins[p], o.s < sources.count else { return nil }
        return "\(sources[o.s].name):\(o.l)"
    }
    /// Set by the space file or its override (not inherited).
    public func written(_ p: String) -> Bool { guard let k = source(p)?.kind else { return false }; return k != "defaults" }

    /// The file and line a problem at `p` points at: the pointer's own origin, else its nearest ancestor's.
    public func place(_ p: String, key: Bool) -> (file: String, line: Int) {
        if p.isEmpty {
            let o = origins[""]
            return (spaceName, o.map { $0.l } ?? 1)
        }
        var q = p
        while true {
            if let o = origins[q], o.s < sources.count { return (sources[o.s].name, key && q == p ? o.k : o.l) }
            guard let i = q.lastIndex(of: "/") else { break }
            q = String(q[..<i])
            if q.isEmpty { break }
        }
        return (spaceName, origins[""]?.l ?? 1)
    }
}

/// What the validator understood of the space: each resource with its lifetime, the agents, what persists, the archive
/// and where each risky setting comes from. `SpaceIntent.compile` builds on it.
public struct SpaceModel: Sendable {
    public struct Resource: Sendable {
        public var name: String
        public var section: SpaceFormat.Section
        public var pointer: String
        public var external: JValue?
        /// `external`, `persisted` or `run`.
        public var lifetime: String
        /// The definition (an owned agent's with `agent_defaults` beneath it).
        public var def: JValue
        public var profiles: [String]
    }
    public struct Agent: Sendable {
        public var name: String
        public var pointer: String
        public var external: JValue?
        public var lifetime: String
        public var def: JValue
        /// nil: on this Mac; else the sandbox's name.
        public var sandbox: String?
        /// 774: where it runs, as the plan shows it — a declared place's name, a sandbox's name, or `mac`.
        public var place: String = "mac"
        public var isolation: String?
        public var permissions: String?
        public var role: String?
        public var transcripts: String
    }
    public struct Persist: Sendable {
        public var entry: String
        public var kind: String
        public var target: String
        public var pointer: String
        public var names: [String]
    }
    public var space = "", title = "", owner = "", brief = ""
    /// 755: `x-dozable.lifetime` as written (nil: none — read as `runs`); `x-dozable.brief.text` (the brief held in the
    /// document itself; `brief` is then empty) and `x-dozable.brief.refs`.
    public var lifetime: String?
    public var briefText: String?
    public var briefRefs: [String] = []
    public var resources: [Resource] = []
    /// space/3.1's `agent_defaults.where: sandbox`: the sandbox name of the workspace's own VM, which every agent that
    /// does not say where runs in (`<space>-vm`, made unique among the resources' names); nil: none.
    public var workspaceVM: String?
    public var agents: [Agent] = []
    /// 774: the places: those `x-dozable.places` declares (in order), then each `sandboxes:` entry and the workspace's own VM
    /// as a vm place.
    public var places: [WorkspacePlace] = []
    public var persist: [Persist] = []
    public var archiveOn = true
    public var archiveTo = SpaceValidator.archiveTo
    public var archiveKeep: [String] = SpaceFormat.archiveKeep
    /// `agents.NAME.permissions` → `FILE:LINE` (or `the default`), `persist.ENTRY`, `archive`.
    public var provenance: [String: String] = [:]
    /// Resources left out: their profile is not active.
    public var skipped: [(name: String, profiles: [String])] = []
    public func resource(_ n: String) -> Resource? { resources.first { $0.name == n } }
}

public enum SpaceValidator {
    public static let archiveTo = "~/Library/Application Support/doz/spaces/{space}/runs/{run}"

    /// A problem before it is placed: whether it points at the key or the value, and which pass found it.
    struct Raw {
        var severity = "error"
        var pointer: String
        var message: String
        var hint: String?
        var key = false
        var schema = false
    }

    // MARK: the passes

    /// One defaults file on its own (`doz: space-defaults/3`): what a defaults file may hold, and its schema. `lines` are its
    /// own pointers' lines.
    /// `spaceV31`: whether the space file that extends it says `doz: space/3.1` (nil: not known — the file alone). A space/3
    /// file reads only space-defaults/3 files: a space-defaults/3.1 one may hold what space/3 has not.
    public static func checkSource(_ doc: JValue, name: String, lines: [String: SpaceOrigin], spaceV31: Bool? = nil) -> [SpaceProblem] {
        let loc = SpaceLocator(sources: [SpaceSource(path: name, name: name, kind: "defaults", sha256: "")], origins: lines)
        var out: [Raw] = []
        let m = SpaceDoc.members(doc)
        let doz = SpaceDoc.string(SpaceDoc.member(doc, "doz")) ?? ""
        if !SpaceFormat.defaultsDozVersions.contains(doz) {
            out.append(Raw(pointer: "/doz", message: "\(name) is not a defaults file", hint: "a defaults file starts with doz: \(SpaceFormat.defaultsDoz)"))
        } else if spaceV31 == false, doz == SpaceFormat.defaultsDoz31 {
            out.append(Raw(pointer: "/doz", message: "\(name) is not a defaults file for a space/3 file",
                           hint: "a doz: space/3 file extends doz: \(SpaceFormat.defaultsDoz) files: change this file's version line to doz: \(SpaceFormat.defaultsDoz), or the space file's to doz: \(SpaceFormat.doz31)"))
        }
        for x in m where !SpaceFormat.defaultsKeys.contains(x.key) && !x.key.hasPrefix("x-") {
            let owns = SpaceFormat.defaultsOwns.contains(x.key)
            out.append(Raw(pointer: SpaceDoc.join("", x.key), message: "a defaults file can't hold \"\(x.key)\"",
                           hint: owns ? "inheriting must never start or own anything: agents, rooms, services, sandboxes, folders and secrets belong in the space file. For settings every agent shares, use agent_defaults:"
                               : "a defaults file holds only persist, archive, approvals, agent_defaults and x-* keys; \"\(x.key)\" belongs in the space file",
                           key: true))
        }
        var s = Schema(defaults: true, v31: SpaceDozable.isV31(doc))
        s.top(doc)
        let ruled = Set(out.map(\.pointer))
        out += s.out.filter { !ruled.contains($0.pointer) }
        return finish(out, loc, mark: false)
    }

    /// The merged document: the schema and every rule, then the backstop. `profiles` are the active ones.
    public static func checkMerged(_ doc: JValue, _ loc: SpaceLocator, profiles: [String] = []) -> (problems: [SpaceProblem], model: SpaceModel) {
        var s = Schema(defaults: false, v31: SpaceDozable.isV31(doc))
        s.top(doc)
        var r = Rules(raw: doc, loc: loc, active: Set(profiles))
        r.run()
        // Where both speak about the same place, the rule's message is the more specific one.
        let ruleErrors = Set(r.out.filter { $0.severity == "error" }.map(\.pointer))
        var all = s.out.filter { !ruleErrors.contains($0.pointer) } + r.out
        all += backstop(doc, loc)
        return (finish(all, loc, mark: true), r.model)
    }

    /// Both passes' problems as one report: a merged schema problem about a place a defaults file's own check already spoke
    /// about is left out, then each message once, in line order.
    public static func report(sourceProblems: [SpaceProblem], merged: [SpaceProblem]) -> [SpaceProblem] {
        let said = Set(sourceProblems.map { $0.file + "|" + $0.pointer })
        var out = sourceProblems + merged.filter { !said.contains($0.file + "|" + $0.pointer) }
        var seen: Set<String> = []
        out = out.filter { seen.insert($0.file + "|" + $0.pointer + "|" + $0.message).inserted }
        return out.enumerated().sorted { ($0.element.line, $0.offset) < ($1.element.line, $1.offset) }.map(\.element)
    }

    /// 774: the names `x-dozable.places` declares, in the file's order.
    public static func declaredPlaceNames(_ doc: JValue?) -> [String] {
        SpaceDoc.members(SpaceDoc.member(SpaceDozable.of(doc), "places")).map(\.key)
    }

    /// The daemon's backstop: nothing that starts or owns something — agents, the owner, rooms, sandboxes, services, folders,
    /// secrets — may come from a defaults file, whatever the CLI checked.
    static func backstop(_ doc: JValue, _ loc: SpaceLocator) -> [Raw] {
        var out: [Raw] = []
        for p in SpaceDoc.pointers(doc) where !p.isEmpty {
            let parts = SpaceDoc.parts(p)
            let owned = ["agents", "owner", "sandboxes", "services", "folders", "secrets"].contains(parts[0])
                || (parts[0] == "chat" && parts.count >= 2 && parts[1] == "rooms")
                || (parts[0] == SpaceDozable.key && parts.count >= 2 && parts[1] == "places")
            guard owned, let o = loc.origins[p], o.s < loc.sources.count, loc.sources[o.s].kind == "defaults" else { continue }
            // One problem per top-level thing: the shallowest pointer that came from a defaults file.
            if out.contains(where: { p.hasPrefix($0.pointer + "/") }) { continue }
            out.append(Raw(pointer: p, message: "\(p) comes from the defaults file \(loc.sources[o.s].name): only the space file may hold agents, the owner, rooms, sandboxes, services, folders or secrets",
                           hint: "inheriting must never start or own anything: write it in the space file", key: true))
        }
        return out
    }

    static func finish(_ raws: [Raw], _ loc: SpaceLocator, mark: Bool) -> [SpaceProblem] {
        var seen: Set<String> = []
        let out = raws.filter { seen.insert($0.pointer + "|" + $0.message).inserted }.map { r -> SpaceProblem in
            let (file, line) = loc.place(r.pointer, key: r.key)
            var message = r.message
            if mark {
                switch loc.kind(r.pointer) {
                case "override": message += " (in the override file)"
                case "defaults": message += " (from \(file))"
                default: break
                }
            }
            return SpaceProblem(severity: r.severity, pointer: r.pointer, message: message, hint: r.hint, file: file, line: line)
        }
        return out.enumerated().sorted { ($0.element.line, $0.offset) < ($1.element.line, $1.offset) }.map(\.element)
    }

    // MARK: words

    /// What a pointer is, in the messages' words.
    static func thing(_ p: String) -> String? {
        let parts = SpaceDoc.parts(p)
        if p.isEmpty { return "the file" }
        if parts.count == 2, let s = SpaceFormat.Section(rawValue: parts[0]), s != .rooms { return "\(s.singular) \"\(parts[1])\"" }
        if parts.count == 3, parts[0] == "chat", parts[1] == "rooms" { return "room \"\(parts[2])\"" }
        if parts.last == "chat" { return "chat" }
        return nil
    }

    static func labelOf(_ p: String) -> String {
        let parts = SpaceDoc.parts(p)
        for s in SpaceFormat.Section.allCases {
            let base = s == .rooms ? 2 : 1
            let prefix = s == .rooms ? ["chat", "rooms"] : [s.rawValue]
            if parts.count > base, Array(parts.prefix(base)) == prefix, !parts[base].hasPrefix("x-") {
                if parts.count == base + 1 { return "\(s.singular) \"\(parts[base])\"" }
                return "\(s.singular) \"\(parts[base])\"'s \(parts.dropFirst(base + 1).joined(separator: "."))"
            }
        }
        if parts.count == 2, parts[0] == "persist" { return "persist entry \"\(parts[1])\"" }
        return parts.isEmpty ? "the file" : parts.joined(separator: ".")
    }

    static func describe(_ p: String) -> String { thing(p) ?? labelOf(p) }

    static let typeWords = ["string": "text", "number": "a number", "integer": "a whole number", "boolean": "true or false",
                            "array": "a list", "object": "a map"]

    // MARK: the schema, by hand

    struct Schema {
        let defaults: Bool
        /// 758: the file says `doz: space/3.1` (or `space-defaults/3.1`): its first-class 3.1 keys are the format's.
        let v31: Bool
        var out: [Raw] = []
        /// 774: the places the file declares (`x-dozable.places`): a `where:` may name one.
        var placeNames: Set<String> = []
        init(defaults: Bool, v31: Bool = false) { self.defaults = defaults; self.v31 = v31 }

        mutating func err(_ p: String, _ m: String, _ hint: String? = nil, key: Bool = false) {
            out.append(Raw(pointer: p, message: m, hint: hint, key: key, schema: true))
        }

        mutating func type(_ v: JValue, _ want: String, _ p: String) -> Bool {
            let ok: Bool
            switch want {
            case "string": ok = SpaceDoc.string(v) != nil
            case "boolean": ok = SpaceDoc.bool(v) != nil
            case "integer": ok = SpaceDoc.int(v) != nil && SpaceDoc.isNumber(v)
            case "number": ok = SpaceDoc.isNumber(v)
            case "array": ok = SpaceDoc.array(v) != nil
            default: ok = SpaceDoc.isMap(v)
            }
            if !ok { err(p, "expected \(SpaceValidator.typeWords[want] ?? want), got \(SpaceDoc.typeName(v))") }
            return ok
        }

        mutating func text(_ v: JValue, _ p: String, nonEmpty: Bool = false) {
            guard type(v, "string", p) else { return }
            if nonEmpty, SpaceDoc.string(v) == "" { err(p, "must NOT have fewer than 1 characters") }
        }

        mutating func oneOf(_ v: JValue, _ allowed: [String], _ p: String) {
            if let s = SpaceDoc.string(v), allowed.contains(s) { return }
            let key = SpaceDoc.parts(p).last ?? ""
            let dym = SpaceDoc.string(v).flatMap { SpaceFormat.didYouMean($0, allowed) }
            err(p, "\(SpaceDoc.typeName(v)) is not a valid \(Int(key) == nil && !key.isEmpty ? "\"\(key)\"" : "value")" + (dym.map { " (did you mean \"\($0)\"?)" } ?? ""),
                "expected one of: \(allowed.joined(separator: ", "))")
        }

        /// A map's keys: an unknown key (with a suggestion, or the keys there are), `x-*` always allowed.
        mutating func keys(_ v: JValue, _ p: String, _ known: [String], xOK: Bool = true, place: SpaceDozable.Place? = nil) {
            // 758: the first-class 3.1 keys of this place are the format's in a 3.1 file; in a space/3 one, refused with the fix.
            // (A first-class key that is a space/3 key too — the brief — is named once.)
            let known = known + (v31 ? (place?.firstClass ?? []).filter { !known.contains($0) } : [])
            for m in SpaceDoc.members(v) where !known.contains(m.key) && !(xOK && m.key.hasPrefix("x-")) {
                // Option A: persistence is not a space/3.1 key — the lifetime stays under x-dozable.
                if v31, place == .top, m.key == "lifetime" {
                    let say = SpaceDoc.string(m.value).flatMap { SpaceDozable.lifetimes.contains($0) ? $0 : nil } ?? "standing"
                    err(SpaceDoc.join(p, m.key), "\"lifetime\" is not a space/3.1 key: it stays under x-dozable",
                        "write x-dozable: { lifetime: \(say) } (standing or runs)", key: true)
                    continue
                }
                // …and nor is a resource's own `lifetime: run`: the same words, its own x-dozable form.
                if v31, let place, place != .top, place != .agentDefaults, m.key == "lifetime" {
                    err(SpaceDoc.join(p, m.key), "\"lifetime\" is not a space/3.1 key: it stays under x-dozable",
                        "write x-dozable: { lifetime: run } (run is the one value here)", key: true)
                    continue
                }
                if let place, let (message, hint) = versionFix(place, m.key, m.value, SpaceDoc.join(p, m.key), owner: v) {
                    err(SpaceDoc.join(p, m.key), message, hint, key: true)
                    continue
                }
                let dym = SpaceFormat.didYouMean(m.key, known)
                var hint: String? = dym == nil && !known.isEmpty ? "known keys: \(known.joined(separator: ", "))" : nil
                if m.key.contains(where: \.isWhitespace) { hint = "inside { … } a comma starts a new key: put text with commas in quotes, e.g. label: \"read once, at launch\"" }
                if m.key == "transcripts" && p.isEmpty { hint = "transcripts is set per agent now: on each agent, or for all of them in agent_defaults: { transcripts: discard }" }
                else if m.key == "trust" && p.hasPrefix("/agents/") { hint = "trust belongs to the folder: folders: { NAME: { external: PATH, trust: before } }" }
                else if let h = SpaceFormat.migration[m.key] { hint = h }
                err(SpaceDoc.join(p, m.key), "unknown key \"\(m.key)\" in \(SpaceValidator.describe(p))" + (dym.map { " (did you mean \"\($0)\"?)" } ?? ""), hint, key: true)
            }
        }

        mutating func required(_ v: JValue, _ p: String, _ names: [String]) {
            for n in names where SpaceDoc.member(v, n) == nil { err(p, "\(SpaceValidator.describe(p)) is missing \"\(n)\"") }
        }

        mutating func pattern(_ v: JValue, _ pat: String, _ p: String) {
            guard let s = SpaceDoc.string(v) else { _ = type(v, "string", p); return }
            guard !SpaceFormat.matches(s, pat) else { return }
            let last = SpaceDoc.parts(p).last ?? ""
            let what = ["space": "a space name", "external": "a full name", "where": "a place", "memory": "a memory size", "to": "a destination",
                        "url": "a URL", "http": "a URL"]
            let hints = ["space": "a space name is a lower-case letter, then lower-case letters, digits and -",
                         "external": "a full name is doz://HOST/SPACE/TYPE/NAME (_ for no space), e.g. doz://host-a/_/bot/manager",
                         "where": "write mac, or sandbox:NAME for a sandbox under sandboxes:", "memory": "a size like 4G or 512M",
                         "to": "HOST or HOST:PORT, e.g. api.github.com", "url": "http://… or https://…", "http": "http://… or https://…"]
            if let w = what[last] { err(p, "\"\(s)\" is not \(w)", hints[last]); return }
            if p.range(of: "/profiles/[0-9]+$", options: .regularExpression) != nil {
                err(p, "\"\(s)\" is not a profile name", "profile names are a lower-case letter, then lower-case letters, digits and -"); return
            }
            err(p, "\"\(s)\" is not valid here")
        }

        mutating func strings(_ v: JValue, _ p: String, nonEmpty: Bool = false) {
            guard type(v, "array", p) else { return }
            for (i, x) in (SpaceDoc.array(v) ?? []).enumerated() { text(x, p + "/\(i)", nonEmpty: nonEmpty) }
        }

        /// A section's map of `name: definition`.
        mutating func section(_ v: JValue, _ p: String, _ each: (inout Schema, JValue, String) -> Void) {
            guard type(v, "object", p) else { return }
            for m in SpaceDoc.members(v) {
                let q = SpaceDoc.join(p, m.key)
                if m.key.hasPrefix("x-") { continue }
                if !SpaceFormat.isName(m.key) {
                    err(q, "\"\(m.key)\" can't be a name", "names are a lower-case letter, then lower-case letters, digits and -", key: true)
                    continue
                }
                each(&self, m.value, q)
            }
        }

        /// The value matches none of the forms an `anyOf` allows.
        mutating func noForm(_ v: JValue, _ p: String, _ types: [String]) {
            err(p, "\(SpaceDoc.typeName(v)) is not allowed here" + (types.isEmpty ? "" : "; expected " + types.joined(separator: " or ")))
        }

        mutating func top(_ doc: JValue) {
            placeNames = Set(SpaceValidator.declaredPlaceNames(doc))
            guard SpaceDoc.isMap(doc) else {
                err("", defaults ? "the file must be a YAML map: a defaults file starts with \"doz: space-defaults/3\""
                    : "the file must be a YAML map: a space file starts with \"doz: space/3\" and \"space:\"")
                return
            }
            // 755: `x-dozable.brief` is the brief when it is written: then `brief:` is not required — and not both.
            let dozableBrief = SpaceDoc.member(SpaceDozable.of(doc), "brief") != nil
            required(doc, "", defaults ? ["doz"] : SpaceFormat.requiredTop.filter { !(dozableBrief && $0 == "brief") })
            // 758: in 3.1 the title is about.title; a top-level `title:` still reads (a note), but not both.
            if !defaults, v31, SpaceDoc.member(doc, "title") != nil, SpaceDoc.member(SpaceDoc.member(doc, "about"), "title") != nil {
                err("/title", "the title is written twice: title: and about.title", "keep about: { title: … } — a top-level title: is read for this release only", key: true)
            }
            if !defaults, dozableBrief, SpaceDoc.member(doc, "brief") != nil {
                err("/x-dozable/brief", "the brief is written twice: brief: and x-dozable.brief", "keep one of them: brief: FILE, or x-dozable: { brief: { text: … } }", key: true)
            }
            keys(doc, "", defaults ? SpaceFormat.defaultsKeys : SpaceFormat.topKeys, place: defaults ? nil : .top)
            dozPlace(.top, doc, "")
            for m in SpaceDoc.members(doc) {
                let p = SpaceDoc.join("", m.key), v = m.value
                switch m.key {
                case "doz":
                    let known = defaults ? SpaceFormat.defaultsDozVersions : SpaceFormat.dozVersions
                    if !known.contains(SpaceDoc.string(v) ?? "") { err(p, "\"doz\" must be \"\(known[0])\" (the format this reader knows), got \(SpaceDoc.typeName(v))") }
                case "extends":
                    if let s = SpaceDoc.string(v) { if s.isEmpty { err(p, "must NOT have fewer than 1 characters") } }
                    else if let a = SpaceDoc.array(v), !a.isEmpty { strings(v, p, nonEmpty: true) }
                    else { noForm(v, p, ["text", "a list"]) }
                case "persist": persist(v, p)
                case "archive": archive(v, p)
                case "approvals": approvals(v, p)
                case "agent_defaults": agentDefaults(v, p)
                default: break
                }
                guard !defaults else { continue }
                switch m.key {
                case "space": pattern(v, "name", p)
                case "title": _ = type(v, "string", p)
                case "brief":
                    // 758: in space/3.1 a brief is a file's path, { text } or { file } (with refs); space/3's is a path.
                    if v31 { dozValue(.top, "brief", v, p, owner: doc, ownerPointer: "", form: "first-class") }
                    else if let (message, hint) = versionFix(.top, "brief", v, p, owner: doc), SpaceDoc.isMap(v) { err(p, message, hint) }
                    else { text(v, p, nonEmpty: true) }
                case "owner", "permissions": text(v, p, nonEmpty: true)
                case "trusted_folders": strings(v, p)
                case "folders": section(v, p) { $0.folder($1, $2) }
                case "agents": section(v, p) { $0.agent($1, $2) }
                case "services": section(v, p) { $0.service($1, $2) }
                case "sandboxes": section(v, p) { $0.sandbox($1, $2) }
                case "secrets": section(v, p) { $0.secret($1, $2) }
                case "chat":
                    guard type(v, "object", p) else { break }
                    keys(v, p, SpaceFormat.chatKeys)
                    if let r = SpaceDoc.member(v, "rooms") { section(r, p + "/rooms") { $0.room($1, $2) } }
                case "labels": labels(v, p)
                case "profiles": profiles(v, p)
                default: break
                }
            }
        }

        mutating func labels(_ v: JValue, _ p: String) {
            guard type(v, "object", p) else { return }
            for m in SpaceDoc.members(v) { _ = type(m.value, "string", SpaceDoc.join(p, m.key)) }
        }

        mutating func profiles(_ v: JValue, _ p: String) {
            guard type(v, "array", p) else { return }
            for (i, x) in (SpaceDoc.array(v) ?? []).enumerated() { pattern(x, "name", p + "/\(i)") }
        }

        mutating func approvals(_ v: JValue, _ p: String) {
            guard type(v, "object", p) else { return }
            keys(v, p, SpaceFormat.approvalsKeys)
            if let d = SpaceDoc.member(v, "deciders") { strings(d, p + "/deciders", nonEmpty: true) }
            if let x = SpaceDoc.member(v, "via") { oneOf(x, SpaceFormat.vias, p + "/via") }
        }

        mutating func archive(_ v: JValue, _ p: String) {
            if SpaceDoc.string(v) == "off" { return }
            guard SpaceDoc.isMap(v) else { noForm(v, p, ["a map"]); return }
            keys(v, p, SpaceFormat.archiveKeys)
            if let t = SpaceDoc.member(v, "to") { text(t, p + "/to", nonEmpty: true) }
            if let k = SpaceDoc.member(v, "keep"), type(k, "array", p + "/keep") {
                var seen: Set<String> = []
                for (i, x) in (SpaceDoc.array(k) ?? []).enumerated() {
                    oneOf(x, SpaceFormat.archiveKeep, p + "/keep/\(i)")
                    if let s = SpaceDoc.string(x), !seen.insert(s).inserted { err(p + "/keep", "list must NOT have duplicate items") }
                }
            }
        }

        mutating func persist(_ v: JValue, _ p: String) {
            guard type(v, "object", p) else { return }
            for m in SpaceDoc.members(v) {
                let q = SpaceDoc.join(p, m.key)
                if m.key.hasPrefix("x-") { continue }
                if !SpaceFormat.isName(m.key) {
                    err(q, "\"\(m.key)\" can't be a name", "names are a lower-case letter, then lower-case letters, digits and -", key: true); continue
                }
                if case .null = m.value { continue }
                guard SpaceDoc.isMap(m.value) else { noForm(m.value, q, ["a map"]); continue }
                let ks = SpaceDoc.members(m.value)
                for x in ks where !SpaceFormat.persistKinds.contains(x.key) {
                    err(SpaceDoc.join(q, x.key), "unknown key \"\(x.key)\" in persist entry \"\(m.key)\"", "write { room: NAME }, { sandbox: NAME }, { agent: NAME } or { folder: PATH }", key: true)
                }
                if ks.count != 1 {
                    err(q, "persist entry \"\(m.key)\" names one thing", "write { room: NAME }, { sandbox: NAME }, { agent: NAME } or { folder: PATH }")
                }
                for x in ks where SpaceFormat.persistKinds.contains(x.key) { text(x.value, SpaceDoc.join(q, x.key), nonEmpty: true) }
            }
        }

        /// The settings an agent shares with `agent_defaults`.
        mutating func settings(_ v: JValue, _ p: String) {
            for m in SpaceDoc.members(v) {
                let q = SpaceDoc.join(p, m.key), x = m.value
                switch m.key {
                case "kind": oneOf(x, SpaceFormat.kinds, q)
                case "role":
                    if SpaceDoc.string(x) == "admin" { err(q, "the admin role is requested, never given", "write requests: { role: admin, reason: \"…\" } on the agent: the owner decides") }
                    else { oneOf(x, SpaceFormat.roles, q) }
                case "where":
                    // space/3.1: `agent_defaults.where: sandbox` is the workspace's own VM (`mac` and `sandbox` are the
                    // keywords; `sandbox:NAME` names a sandbox under sandboxes:). On an agent, a place is mac or sandbox:NAME.
                    if p == "/agent_defaults", SpaceDoc.string(x) == SpaceFormat.workspaceVM {
                        if !v31 {
                            err(q, "\"where\" is a space/3.1 key: change the version line to doz: \(defaults ? SpaceFormat.defaultsDoz31 : SpaceFormat.doz31)",
                                "this file says doz: \(defaults ? SpaceFormat.defaultsDoz : SpaceFormat.doz), whose where is mac or sandbox:NAME; where: sandbox (the workspace's own VM) is space/3.1's")
                        }
                    } else if let w = SpaceDoc.string(x), placeNames.contains(w) {
                        // 774: a place the file declares (x-dozable.places).
                    } else if let w = SpaceDoc.string(x), SpaceFormat.isName(w), !WorkspacePlace.reserved.contains(w) {
                        // 774: a bare name that is no place: the rules refuse it, listing the places there are.
                    } else { pattern(x, "where", q) }
                case "isolation": if !(p == "/agent_defaults") { oneOf(x, SpaceFormat.isolations, q) }
                case "permissions": text(x, q, nonEmpty: true)
                case "access": oneOf(x, SpaceFormat.accesses, q)
                case "secrets": strings(x, q)
                case "model": _ = type(x, "string", q)
                case "remote_control": _ = type(x, "boolean", q)
                case "chat":
                    guard type(x, "object", q) else { break }
                    keys(x, q, SpaceFormat.agentChatKeys)
                    if let d = SpaceDoc.member(x, "delivery") { oneOf(d, SpaceFormat.deliveries, q + "/delivery") }
                    if let r = SpaceDoc.member(x, "rooms") { strings(r, q + "/rooms") }
                case "transcripts": oneOf(x, SpaceFormat.transcripts, q)
                case "resume": oneOf(x, SpaceFormat.resumes, q)
                case "approvals": approvals(x, q)
                case "labels": labels(x, q)
                case "profiles": profiles(x, q)
                default: break
                }
            }
        }

        mutating func agentDefaults(_ v: JValue, _ p: String) {
            guard type(v, "object", p) else { return }
            keys(v, p, SpaceFormat.agentDefaultsKeys, place: .agentDefaults)
            settings(v, p)
            dozPlace(.agentDefaults, v, p)
            if let i = SpaceDoc.member(v, "isolation"), SpaceDoc.string(i) != "fenced" {
                if SpaceDoc.string(i) == "unfenced" {
                    err(p + "/isolation", "agent_defaults can't make agents unfenced",
                        "an agent is never unfenced by inheritance: write isolation: unfenced on each agent that needs it. agent_defaults may set isolation: fenced")
                } else { oneOf(i, ["fenced"], p + "/isolation") }
            }
        }

        mutating func externalForbidden(_ v: JValue, _ p: String, _ forbidden: [String]) {
            guard SpaceDoc.member(v, "external") != nil else { return }
            let name = SpaceDoc.parts(p).last ?? ""
            for m in SpaceDoc.members(v) where forbidden.contains(m.key) {
                err(SpaceDoc.join(p, m.key), "\"\(name)\" is external, so \"\(m.key)\" can't apply",
                    "an entry either references something that exists (external:) or describes something the space owns, never both: remove \"\(m.key)\", or remove external: to have the space make \"\(name)\"", key: true)
            }
        }

        mutating func agent(_ v: JValue, _ p: String) {
            // 767 (journal/1): `owner` is the owner's own name in a run's journal (an entry's `by`) — never an identity's.
            if p.split(separator: "/").last.map(String.init) == WorkspaceName.reservedAgentName {
                err(p, "\"owner\" can't be an agent's name", "owner names you in a run's journal: pick another name", key: true)
            }
            guard type(v, "object", p) else { return }
            keys(v, p, SpaceFormat.agentKeys, place: .agent)
            settings(v, p)
            dozPlace(.agent, v, p)
            for m in SpaceDoc.members(v) {
                let q = SpaceDoc.join(p, m.key), x = m.value
                switch m.key {
                case "external":
                    if let s = SpaceDoc.string(x) {
                        if !SpaceFormat.matches(s, "agentExternal") { pattern(x, "agentExternal", q) }
                    } else if SpaceDoc.isMap(x) {
                        let ks = SpaceDoc.members(x).map(\.key)
                        // 758: an agent in an existing sandbox, `external: { sandbox: NAME }`, is a space/3.1 form.
                        if ks == ["sandbox"] {
                            if v31 { dozValue(.agent, "external", x, q, owner: v, ownerPointer: p, form: "first-class") }
                            else if let (message, _) = versionFix(.agent, "external", x, q, owner: v) {
                                err(q, message, "this file says doz: space/3, whose external agent is { bot: NAME }, { session: NAME } or a full name; { sandbox: NAME } is space/3.1's")
                            }
                            else { err(q, "an external agent is { bot: NAME }, { session: NAME } or doz://HOST/_/bot/NAME") }
                        } else if ks == ["bot"] { pattern(SpaceDoc.member(x, "bot")!, "name", q + "/bot") }
                        else if ks == ["session"] { text(SpaceDoc.member(x, "session")!, q + "/session", nonEmpty: true) }
                        else { err(q, "an external agent is { bot: NAME }, { session: NAME } or doz://HOST/_/bot/NAME") }
                    } else { noForm(x, q, ["text", "a map"]) }
                case "folder", "prompt_file": text(x, q, nonEmpty: true)
                case "prompt": _ = type(x, "string", q)
                case "requests":
                    guard type(x, "object", q) else { break }
                    keys(x, q, SpaceFormat.requestsKeys)
                    required(x, q, ["reason"])
                    if let r = SpaceDoc.member(x, "role") { _ = type(r, "string", q + "/role") }
                    if let g = SpaceDoc.member(x, "grants") { strings(g, q + "/grants") }
                    if let r = SpaceDoc.member(x, "reason") { text(r, q + "/reason", nonEmpty: true) }
                default: break
                }
            }
            externalForbidden(v, p, SpaceFormat.agentExternalForbidden)
            // An agent in an existing sandbox (`external: { sandbox }`) is adopted, never started: it has no restart.
            let ext = SpaceDozable.member(v, "external", at: .agent)
            if SpaceDoc.member(ext, "sandbox") != nil {
                let name = SpaceDoc.parts(p).last ?? ""
                for (r, q) in [(SpaceDoc.member(v, "restart"), SpaceDoc.join(p, "restart")),
                               (SpaceDoc.member(SpaceDozable.of(v), "restart"), SpaceDoc.join(SpaceDoc.join(p, SpaceDozable.key), "restart"))] where r != nil {
                    err(q, "\"\(name)\" is external, so \"restart\" can't apply",
                        "an entry either references something that exists (external:) or describes something the space owns, never both: remove \"restart\", or remove external: to have the space make \"\(name)\"", key: true)
                }
            }
        }

        mutating func folder(_ v: JValue, _ p: String) {
            guard type(v, "object", p) else { return }
            keys(v, p, SpaceFormat.folderKeys, place: .folder)
            dozPlace(.folder, v, p)
            for m in SpaceDoc.members(v) {
                let q = SpaceDoc.join(p, m.key)
                switch m.key {
                case "external": text(m.value, q, nonEmpty: true)
                case "access": oneOf(m.value, SpaceFormat.accesses, q)
                case "trust": oneOf(m.value, SpaceFormat.trusts, q)
                case "optional": _ = type(m.value, "boolean", q)
                case "labels": labels(m.value, q)
                case "profiles": profiles(m.value, q)
                default: break
                }
            }
        }

        /// `true`, a full name of `fqn`'s kind, or a name.
        mutating func externalRef(_ x: JValue, _ q: String, _ fqn: String) {
            if SpaceDoc.bool(x) == true { return }
            if let s = SpaceDoc.string(x), SpaceFormat.matches(s, fqn) || SpaceFormat.isName(s) { return }
            if let s = SpaceDoc.string(x), s.hasPrefix("doz://") { err(q, "\"\(s)\" is not a full name"); return }
            noForm(x, q, ["true", "a name or a full name"])
        }

        mutating func room(_ v: JValue, _ p: String) {
            guard type(v, "object", p) else { return }
            keys(v, p, SpaceFormat.roomKeys, place: .room)
            dozPlace(.room, v, p)
            for m in SpaceDoc.members(v) {
                let q = SpaceDoc.join(p, m.key)
                switch m.key {
                case "external": externalRef(m.value, q, "roomExternal")
                case "members": strings(m.value, q, nonEmpty: true)
                case "main": _ = type(m.value, "boolean", q)
                case "labels": labels(m.value, q)
                case "profiles": profiles(m.value, q)
                default: break
                }
            }
        }

        mutating func sandbox(_ v: JValue, _ p: String) {
            guard type(v, "object", p) else { return }
            keys(v, p, SpaceFormat.sandboxKeys, place: .sandbox)
            dozPlace(.sandbox, v, p)
            for m in SpaceDoc.members(v) {
                let q = SpaceDoc.join(p, m.key)
                switch m.key {
                case "external": externalRef(m.value, q, "sandboxExternal")
                case "image", "folder": text(m.value, q, nonEmpty: true)
                case "cpus":
                    if type(m.value, "integer", q), let n = SpaceDoc.int(m.value), n < 1 { err(q, "\(n) is out of range: must be >= 1") }
                case "memory": pattern(m.value, "memory", q)
                case "labels": labels(m.value, q)
                case "profiles": profiles(m.value, q)
                default: break
                }
            }
            externalForbidden(v, p, SpaceFormat.sandboxExternalForbidden)
        }

        mutating func secret(_ v: JValue, _ p: String) {
            guard type(v, "object", p) else { return }
            keys(v, p, SpaceFormat.secretKeys)
            required(v, p, SpaceFormat.secretRequired)
            for m in SpaceDoc.members(v) {
                let q = SpaceDoc.join(p, m.key)
                switch m.key {
                case "external":
                    let ks = SpaceDoc.members(m.value).map(\.key)
                    if ks == ["keychain"] || ks == ["file"] { text(SpaceDoc.member(m.value, ks[0])!, q + "/" + ks[0], nonEmpty: true) }
                    else { err(q, "a secret is external: { keychain: ITEM } or { file: PATH }") }
                case "to": pattern(m.value, "to", q)
                case "labels": labels(m.value, q)
                case "profiles": profiles(m.value, q)
                default: break
                }
            }
        }

        mutating func service(_ v: JValue, _ p: String) {
            guard type(v, "object", p) else { return }
            keys(v, p, SpaceFormat.serviceKeys)
            for m in SpaceDoc.members(v) {
                let q = SpaceDoc.join(p, m.key), x = m.value
                switch m.key {
                case "external":
                    if let s = SpaceDoc.string(x) {
                        if !SpaceFormat.matches(s, "serviceExternal") { err(q, "\"\(s)\" is not a full name") }
                    } else {
                        let ks = SpaceDoc.members(x).map(\.key)
                        if ks == ["url"] { pattern(SpaceDoc.member(x, "url")!, "url", q + "/url") }
                        else if ks == ["session"] { text(SpaceDoc.member(x, "session")!, q + "/session", nonEmpty: true) }
                        else { err(q, "an external service is a full name, { url: http://… } or { session: NAME }") }
                    }
                case "command", "folder": text(x, q, nonEmpty: true)
                case "env":
                    guard type(x, "object", q) else { break }
                    for e in SpaceDoc.members(x) where SpaceDoc.string(e.value) == nil && SpaceDoc.bool(e.value) == nil && !SpaceDoc.isNumber(e.value) {
                        err(SpaceDoc.join(q, e.key), "expected text, a number or true or false, got \(SpaceDoc.typeName(e.value))")
                    }
                case "ports":
                    guard type(x, "array", q) else { break }
                    for (i, e) in (SpaceDoc.array(x) ?? []).enumerated() {
                        if type(e, "integer", q + "/\(i)"), let n = SpaceDoc.int(e), !(1...65535).contains(n) { err(q + "/\(i)", "\(n) is out of range: must be 1 to 65535") }
                    }
                case "health":
                    guard type(x, "object", q) else { break }
                    keys(x, q, SpaceFormat.healthKeys, xOK: false)
                    if let h = SpaceDoc.member(x, "http") { pattern(h, "http", q + "/http") }
                    if let t = SpaceDoc.member(x, "tcp"), type(t, "integer", q + "/tcp"), let n = SpaceDoc.int(t), !(1...65535).contains(n) {
                        err(q + "/tcp", "\(n) is out of range: must be 1 to 65535")
                    }
                    if let c = SpaceDoc.member(x, "command") { text(c, q + "/command", nonEmpty: true) }
                    for k in ["interval", "timeout"] {
                        if let t = SpaceDoc.member(x, k), SpaceDoc.string(t) == nil, !SpaceDoc.isNumber(t) {
                            err(q + "/" + k, "expected text or a number, got \(SpaceDoc.typeName(t))")
                        }
                    }
                case "labels": labels(x, q)
                case "profiles": profiles(x, q)
                default: break
                }
            }
            externalForbidden(v, p, SpaceFormat.serviceExternalForbidden)
        }
    }

    // MARK: the rules (the reference's `rules`, in its order)

    struct Rules {
        let raw: JValue
        let loc: SpaceLocator
        let active: Set<String>
        var out: [Raw] = []
        var model = SpaceModel()
        /// 774: `x-dozable.places` as written, in order.
        let declared: [JMember]
        /// The agents whose isolation their place set.
        var placeIsolated: Set<String> = []

        init(raw: JValue, loc: SpaceLocator, active: Set<String>) {
            self.raw = raw; self.loc = loc; self.active = active
            declared = SpaceDoc.members(SpaceDoc.member(SpaceDozable.of(raw), "places")).filter { SpaceDoc.isMap($0.value) }
        }

        func placeDef(_ n: String) -> JValue? { declared.first { $0.key == n }?.value }
        /// A declared place's isolation (`vm` for an external one; nil: no such place).
        func placeIsolation(_ n: String) -> String? {
            guard let d = placeDef(n) else { return nil }
            if SpaceDoc.member(d, "external") != nil { return "vm" }
            return SpaceDoc.string(SpaceDoc.member(d, "isolation"))
        }

        mutating func err(_ p: String, _ m: String, _ hint: String? = nil, _ severity: String = "error", key: Bool = false) {
            out.append(Raw(severity: severity, pointer: p, message: m, hint: hint, key: key))
        }

        func dym(_ w: String, _ c: [String]) -> String { SpaceFormat.didYouMean(w, c).map { " (did you mean \"\($0)\"?)" } ?? "" }

        func sectionMap(_ s: SpaceFormat.Section) -> [JMember] {
            s == .rooms ? SpaceDoc.members(SpaceDoc.member(SpaceDoc.member(raw, "chat"), "rooms")) : SpaceDoc.members(SpaceDoc.member(raw, s.rawValue))
        }
        func rawDef(_ s: SpaceFormat.Section, _ n: String) -> JValue? { sectionMap(s).last { $0.key == n }?.value }
        func inSection(_ s: SpaceFormat.Section) -> [SpaceModel.Resource] { model.resources.filter { $0.section == s } }
        func owned(_ s: SpaceFormat.Section) -> [SpaceModel.Resource] { inSection(s).filter { $0.lifetime != "external" } }
        func an(_ word: String) -> String { word.first.map { "aeiou".contains($0) } == true ? "an" : "a" }

        mutating func run() {
            let spaceName = SpaceDoc.string(SpaceDoc.member(raw, "space")) ?? ""
            model.space = spaceName
            model.owner = SpaceDoc.string(SpaceDoc.member(raw, "owner")) ?? ""
            model.title = SpaceDoc.string(SpaceDoc.member(SpaceDozable.member(raw, "about", at: .top), "title"))
                ?? SpaceDoc.string(SpaceDoc.member(raw, "title")) ?? spaceName
            let xBrief = SpaceDozable.briefMap(raw)
            model.brief = SpaceDoc.string(SpaceDoc.member(raw, "brief")) ?? SpaceDoc.string(SpaceDoc.member(xBrief, "file")) ?? ""
            model.briefText = SpaceDoc.string(SpaceDoc.member(xBrief, "text"))
            model.briefRefs = SpaceDoc.strings(SpaceDoc.member(xBrief, "refs"))
            model.lifetime = SpaceDozable.lifetime(raw)
            resources()
            if SpaceDoc.string(SpaceDoc.member(SpaceDoc.member(raw, "agent_defaults"), "where")) == SpaceFormat.workspaceVM {
                let base = SpaceIntent.prefixed("vm", spaceName)
                var name = base, k = 2
                while model.resource(name) != nil { name = "\(base)-\(k)"; k += 1 }
                model.workspaceVM = name
            }
            externals()
            folders()
            references()
            persist(spaceName)
            agents()
            places()
            placeRules()
            rooms()
            services()
            archive(spaceName)
            provenance()
        }

        // ---- the resources, with profiles applied; names share one namespace ----
        mutating func resources() {
            let ad = SpaceDoc.member(raw, "agent_defaults")
            let adSafe: JValue = .object(SpaceDoc.members(ad).filter { !($0.key == "isolation" && SpaceDoc.string($0.value) == "unfenced") })
            for s in SpaceFormat.Section.allCases {
                for m in sectionMap(s) where !m.key.hasPrefix("x-") {
                    let p = SpaceDoc.join(s.pointer, m.key)
                    let v: JValue = SpaceDoc.isMap(m.value) ? m.value : .object([])
                    if !SpaceFormat.isName(m.key) {
                        err(p, "\"\(m.key)\" can't be a name", "names are a lower-case letter, then lower-case letters, digits and -", key: true)
                    }
                    let profiles = SpaceDoc.strings(SpaceDoc.member(v, "profiles"))
                    if !profiles.isEmpty && !profiles.contains(where: active.contains) { model.skipped.append((m.key, profiles)); continue }
                    if let prev = model.resource(m.key) {
                        err(p, "\"\(m.key)\" is used twice: as \(prev.section.singular) and as \(s.singular)",
                            "names share one namespace across sections, so a persist entry or a member list can point at any of them", key: true)
                        continue
                    }
                    var external = SpaceDoc.member(v, "external")
                    if SpaceDoc.bool(external) == false { external = nil }
                    // 755: an agent in an existing sandbox (`x-dozable: { external: { sandbox: NAME } }`) is external too.
                    if s == .agents, external == nil, let e = SpaceDozable.member(v, "external", at: .agent), SpaceDoc.string(SpaceDoc.member(e, "sandbox")) != nil {
                        external = e
                    }
                    let def = s == .agents && external == nil ? (SpaceDoc.merge(adSafe, v) ?? v) : v
                    model.resources.append(.init(name: m.key, section: s, pointer: p, external: external,
                                                 lifetime: external != nil ? "external" : "run", def: def, profiles: profiles))
                }
            }
            // 774: a declared place shares the one namespace; a vm place (and an external one, an adopted sandbox) is a
            // sandbox of the space — `where: NAME` and `where: sandbox:NAME` both reach it.
            for m in declared {
                let p = SpaceDoc.join(SpaceDoc.join("/" + SpaceDozable.key, "places"), m.key)
                if let prev = model.resource(m.key) {
                    err(p, "\"\(m.key)\" is used twice: as \(prev.section.singular) and as a place",
                        "names share one namespace across sections and places: rename one of them", key: true)
                    continue
                }
                guard placeIsolation(m.key) == "vm" else { continue }
                let ext = SpaceDoc.string(SpaceDoc.member(SpaceDoc.member(m.value, "external"), "sandbox")).map { JValue.string($0) }
                model.resources.append(.init(name: m.key, section: .sandboxes, pointer: p, external: ext,
                                             lifetime: ext != nil ? "external" : "run", def: m.value, profiles: []))
            }
        }

        /// 774: what a declared place's view and credentials can be, by the mechanism that applies them: a fenced session's
        /// fence takes more folders read-only or read-write (its own folder is always read-write) and the fence's named
        /// credentials (GitHub as you, the SSH agent); a sandbox shares ONE folder, read-write, at /workspace, and holds
        /// GitHub as you and key accounts.
        mutating func placeRules() {
            for m in declared where SpaceDoc.member(m.value, "external") == nil {
                let p = SpaceDoc.join(SpaceDoc.join("/" + SpaceDozable.key, "places"), m.key)
                let iso = placeIsolation(m.key)
                let view = SpaceDoc.members(SpaceDoc.member(m.value, "view"))
                for f in view {
                    guard let hit = model.resource(f.key), hit.section == .folders else {
                        err(SpaceDoc.join(p + "/view", f.key), "place \(m.key)'s view names \"\(f.key)\", which is not a folder"
                            + dym(f.key, inSection(.folders).map(\.name)), "a view names folders under folders:", key: true)
                        continue
                    }
                }
                if iso == "vm", !view.isEmpty, view.count > 1 || SpaceDoc.string(view[0].value) == "ro" {
                    err(p + "/view", "place \(m.key) is a vm: a sandbox shares one folder, read-write, at /workspace — its view can't be \(view.map { "\($0.key) \(SpaceDoc.string($0.value) ?? "")" }.joined(separator: ", "))",
                        "write at most one folder, rw (the workspace's main folder), or use a fenced place for read-only and several folders")
                }
                for (k, c) in SpaceDoc.strings(SpaceDoc.member(m.value, "credentials")).enumerated() {
                    let q = p + "/credentials/\(k)"
                    if iso == "fenced", !WorkspacePlaces.fencedCredentials.contains(c) {
                        err(q, "a fence holds GitHub as you and the SSH agent only, not \"\(c.prefix(40))\"",
                            "write github:read, github:push or ssh-agent — key accounts are a vm place's")
                    }
                    if iso == "vm", c == "ssh-agent" {
                        err(q, "ssh-agent is a fenced session's: a sandbox has no SSH agent of yours", "remove it, or use a fenced place")
                    } else if iso == "vm", !WorkspacePlaces.fencedCredentials.contains(c), !SpaceFormat.isName(c) {
                        err(q, "\"\(c.prefix(40))\" is not a credential", "github:read, github:push, or a key account's name (doz key ls)")
                    }
                }
            }
        }

        /// 774: the places the plan lists — the declared ones, each `sandboxes:` entry, the workspace's own VM when used.
        mutating func places() {
            // What each session's fence (or the VM's proxy) is given today: the workspace's default network, `locked` (a
            // space file's `network:` is recorded, not applied — said in the notes).
            let ws = WorkspacePlace.Policy.text(WorkspacePlaces.networkDefault)
            for m in declared where SpaceDoc.member(m.value, "external") != nil || WorkspacePlace.isolations.contains(SpaceDoc.string(SpaceDoc.member(m.value, "isolation")) ?? "") {
                model.places.append(WorkspacePlaces.declared(m.key, m.value, workspaceNetwork: ws))
            }
            let names = Set(declared.map(\.key))
            for r in inSection(.sandboxes) where !names.contains(r.name) {
                let ext = r.external.map { e -> String in SpaceDoc.string(e).map { SpaceFormat.parseFullName($0)?.name ?? $0 } ?? r.name }
                model.places.append(WorkspacePlaces.vm(r.name, image: SpaceDoc.string(SpaceDoc.member(r.def, "image")), cpus: SpaceDoc.int(SpaceDoc.member(r.def, "cpus")),
                                                       memory: SpaceDoc.string(SpaceDoc.member(r.def, "memory")), external: ext, network: ws, from: "sandboxes"))
            }
            if let vm = model.workspaceVM, model.agents.contains(where: { $0.lifetime != "external" && $0.sandbox == vm }) {
                model.places.append(WorkspacePlaces.vm(vm, image: nil, cpus: nil, memory: nil, external: nil, network: ws, from: "workspace-vm"))
            }
        }

        // ---- external forms the schema can't explain well ----
        mutating func externals() {
            for r in inSection(.agents) {
                let e = r.external
                if SpaceDoc.member(e, "folder") != nil {
                    err(r.pointer + "/external", "an external agent can't be identified by its folder",
                        "two sessions can share a folder, and a folder says nothing about who answers: write { bot: NAME }, { session: NAME } or doz://HOST/_/bot/NAME")
                }
                if let c = SpaceDoc.member(e, "chat") {
                    err(r.pointer + "/external", "an external agent is named by its bot name", "write external: { bot: \(SpaceDoc.string(c) ?? SpaceDoc.text(c)) }")
                }
                if let s = SpaceDoc.string(e), s.hasPrefix("doz://"), SpaceFormat.parseFullName(s) == nil {
                    err(r.pointer + "/external", "\"\(s)\" is not a full name", "a full name is doz://HOST/SPACE/TYPE/NAME, e.g. doz://host-a/_/bot/manager")
                }
            }
            for (s, want) in [(SpaceFormat.Section.rooms, "room"), (.sandboxes, "sandbox"), (.services, "service")] {
                for r in inSection(s) {
                    guard let e = SpaceDoc.string(r.external), e.hasPrefix("doz://") else { continue }
                    if let f = SpaceFormat.parseFullName(e) {
                        if f.type != want { err(r.pointer + "/external", "\"\(e)\" names \(an(f.type)) \(f.type), not \(an(want)) \(want)") }
                    } else {
                        err(r.pointer + "/external", "\"\(e)\" is not a full name", "a full name is doz://HOST/SPACE/\(want)/NAME (_ for no space)")
                    }
                }
            }
            for r in inSection(.secrets) { scanSecret(rawDef(.secrets, r.name), r.pointer) }
            // 755: an agent in an existing sandbox names one the space does not declare (a declared one is the space's).
            for r in inSection(.agents) {
                guard let sb = SpaceDoc.string(SpaceDoc.member(SpaceDozable.member(r.def, "external", at: .agent), "sandbox")) else { continue }
                if model.resource(sb)?.section == .sandboxes {
                    err(r.pointer + (SpaceDoc.member(SpaceDoc.member(r.def, "external"), "sandbox") != nil ? "/external/sandbox" : "/x-dozable/external/sandbox"), "\"\(sb)\" is a sandbox of this space, so \"\(r.name)\" can't be in it as an external agent",
                        "an agent in a sandbox the space declares is written where: sandbox:\(sb); external: { sandbox: NAME } names a sandbox that already exists outside it")
                }
            }
        }

        mutating func scanSecret(_ v: JValue?, _ p: String) {
            if let s = SpaceDoc.string(v), s.contains("${") {
                err(p, "a secret can't use ${VAR}", "resolved values appear in the plan; a secret is an external reference: { keychain: ITEM } or { file: PATH }")
            } else {
                for m in SpaceDoc.members(v) { scanSecret(m.value, SpaceDoc.join(p, m.key)) }
            }
        }

        // ---- folders ----
        mutating func folders() {
            // 755: at most one main folder (`main: true`; `x-dozable: { main: true }` for one release).
            let mains = inSection(.folders).filter { SpaceDoc.bool(SpaceDozable.member($0.def, "main", at: .folder)) == true }
            for r in mains.dropFirst() {
                err(r.pointer + (SpaceDoc.member(r.def, "main") != nil ? "/main" : "/x-dozable/main"), "two main folders: \"\(mains[0].name)\" and \"\(r.name)\"", "a workspace has one main folder")
            }
            let trusted = SpaceDoc.strings(SpaceDoc.member(raw, "trusted_folders"))
            for r in inSection(.folders) {
                let v = r.def
                if r.lifetime != "external" && SpaceDoc.member(v, "optional") != nil {
                    err(r.pointer + "/optional", "\"optional\" is for external folders", "an owned folder is made by up, so it is never missing", key: true)
                }
                if r.lifetime == "external" && SpaceDoc.string(SpaceDoc.member(v, "trust")) == "before" {
                    let p = SpaceDoc.string(r.external) ?? SpaceDoc.text(r.external ?? .null)
                    if !(p.hasPrefix("~/") || p == "~" || trusted.contains(p)) {
                        err(r.pointer + "/trust", "trust: before only applies under your home or in trusted_folders: \"\(p)\" is neither",
                            "add it to trusted_folders:, or remove trust:")
                    }
                }
                if r.lifetime != "external" && SpaceDoc.member(v, "trust") != nil {
                    err(r.pointer + "/trust", "\"trust\" is for external folders", "an owned scratch folder lives inside the run folder", "warning", key: true)
                }
            }
        }

        // ---- references: every name a value uses must exist, in the right section ----
        struct Slot: Sendable {
            var at: [String]
            var targets: [SpaceFormat.Section]
            var extra: [String] = []
            var name: (@Sendable (String) -> String?)?
            var write: (@Sendable (String) -> String)?
            var pathOK = false
            var key = false
            var what: String
        }

        static let viaFullName: @Sendable (String) -> String? = { v in SpaceFormat.parseFullName(v)?.name ?? v }
        static let slots: [Slot] = [
            Slot(at: ["agents", "*", "folder"], targets: [.folders], what: "an agent's folder"),
            Slot(at: ["sandboxes", "*", "folder"], targets: [.folders], what: "a sandbox's folder"),
            Slot(at: ["services", "*", "folder"], targets: [.folders], what: "a service's folder"),
            Slot(at: ["agents", "*", "where"], targets: [.sandboxes], extra: ["mac"],
                 name: { v in v.hasPrefix("sandbox:") && v.count > 8 ? String(v.dropFirst(8)) : nil }, write: { "sandbox:\($0)" }, what: "a place"),
            Slot(at: ["agents", "*", "secrets", "#"], targets: [.secrets], what: "an agent's secret"),
            Slot(at: ["agent_defaults", "secrets", "#"], targets: [.secrets], what: "a secret in agent_defaults"),
            Slot(at: ["agents", "*", "chat", "rooms", "#"], targets: [.rooms], name: viaFullName, what: "an agent's room"),
            Slot(at: ["agent_defaults", "chat", "rooms", "#"], targets: [.rooms], name: viaFullName, what: "a room in agent_defaults"),
            Slot(at: ["chat", "rooms", "*", "members", "#"], targets: [.agents], extra: ["owner"], name: viaFullName, what: "a room member"),
            Slot(at: ["approvals", "deciders", "#"], targets: [.agents], extra: ["owner"], what: "a decider"),
            Slot(at: ["agents", "*", "approvals", "deciders", "#"], targets: [.agents], extra: ["owner"], what: "a decider"),
            Slot(at: ["agent_defaults", "approvals", "deciders", "#"], targets: [.agents], extra: ["owner"], what: "a decider"),
            Slot(at: ["persist", "*", "room"], targets: [.rooms], extra: ["{space}"], what: "a persisted room"),
            Slot(at: ["persist", "*", "sandbox"], targets: [.sandboxes], what: "a persisted sandbox"),
            Slot(at: ["persist", "*", "agent"], targets: [.agents], extra: ["*"], what: "a persisted agent's memory"),
            Slot(at: ["persist", "*", "folder"], targets: [.folders], pathOK: true, what: "a persisted folder"),
            // The diagram's pinned positions: `x-editor` (spec v3). The key this reader took before is still read the same
            // way (the spec gives no fallback rule; any other `x-` key is ignored).
            Slot(at: ["x-editor", "layout", "*"], targets: [.folders, .agents, .services, .sandboxes, .secrets, .rooms], key: true, what: "a pinned position"),
            Slot(at: ["x-worker", "layout", "*"], targets: [.folders, .agents, .services, .sandboxes, .secrets, .rooms], key: true, what: "a pinned position"),
        ]

        struct Ref { var pointer: String; var slot: Slot; var value: String; var name: String? }

        func refs() -> [Ref] {
            var out: [Ref] = []
            let space = SpaceDoc.string(SpaceDoc.member(raw, "space")) ?? ""
            func make(_ slot: Slot, _ p: String, _ v: String) -> Ref {
                if slot.pathOK, let f = v.first, "~/.".contains(f) { return Ref(pointer: p, slot: slot, value: v) }
                if v.contains("{space}") { return Ref(pointer: p, slot: slot, value: v, name: v.replacingOccurrences(of: "{space}", with: space)) }
                if slot.extra.contains(v) { return Ref(pointer: p, slot: slot, value: v) }
                return Ref(pointer: p, slot: slot, value: v, name: slot.name.map { $0(v) } ?? v)
            }
            for slot in Self.slots {
                func walk(_ node: JValue?, _ i: Int, _ p: String) {
                    if i == slot.at.count {
                        if !slot.key, let s = SpaceDoc.string(node) { out.append(make(slot, p, s)) }
                        return
                    }
                    let seg = slot.at[i]
                    if seg == "#" {
                        for (j, x) in (SpaceDoc.array(node) ?? []).enumerated() { walk(x, i + 1, p + "/\(j)") }
                    } else if seg == "*" {
                        for m in SpaceDoc.members(node) where !m.key.hasPrefix("x-") {
                            if slot.key && i == slot.at.count - 1 { out.append(make(slot, SpaceDoc.join(p, m.key), m.key)) }
                            else { walk(m.value, i + 1, SpaceDoc.join(p, m.key)) }
                        }
                    } else if SpaceDoc.isMap(node) {
                        walk(SpaceDoc.member(node, seg), i + 1, SpaceDoc.join(p, seg))
                    }
                }
                walk(raw, 0, "")
            }
            return out
        }

        func isSkipped(_ n: String) -> Bool { model.skipped.contains { $0.name == n } }

        mutating func references() {
            let placeNames = declared.map(\.key)
            for ref in refs() {
                // 774: `where:` names a place (x-dozable.places), `mac`, or `sandbox:NAME`; another bare name is no place.
                if ref.slot.what == "a place", ref.name == nil, !ref.slot.extra.contains(ref.value) {
                    if placeNames.contains(ref.value) { continue }
                    // With no place declared, the space/3 words stand (the format's reference table): write mac, or sandbox:NAME.
                    if !placeNames.isEmpty, SpaceFormat.isName(ref.value), !WorkspacePlace.reserved.contains(ref.value) {
                        let sandboxes = inSection(.sandboxes).filter { !placeNames.contains($0.name) }.map { "sandbox:" + $0.name }
                        err(ref.pointer, "\"\(ref.value)\" is not a place" + dym(ref.value, placeNames),
                            "the places: \(placeNames.joined(separator: ", ")); also: " + (["mac"] + sandboxes + ["sandbox:NAME"]).joined(separator: ", "))
                        continue
                    }
                }
                if ref.slot.key {
                    if model.resource(ref.value) == nil && !isSkipped(ref.value) {
                        err(ref.pointer, "no resource \"\(ref.value)\" to pin" + dym(ref.value, model.resources.map(\.name)), nil, "warning", key: true)
                    }
                    continue
                }
                guard let name = ref.name else {
                    if ref.slot.name != nil && !ref.slot.extra.contains(ref.value) {
                        err(ref.pointer, "\"\(ref.value)\" is not \(ref.slot.what)",
                            ref.slot.write.map { "write \(ref.slot.extra.joined(separator: ", ")), or \($0("NAME"))" })
                    }
                    continue
                }
                if ref.pointer.hasPrefix("/persist/") { continue }
                if isSkipped(name) { continue }
                let hit = model.resource(name)
                if let hit, ref.slot.targets.contains(hit.section) { continue }
                let pool = ref.slot.targets.flatMap { s in inSection(s).map(\.name) } + ref.slot.extra
                let what = ref.slot.targets.map(\.singular).joined(separator: " or ")
                let names = pool.filter { !ref.slot.extra.contains($0) }
                let also = ref.slot.extra.isEmpty ? [] : (ref.slot.write.map { ref.slot.extra + [$0("NAME")] } ?? ref.slot.extra)
                let message = hit.map { "\"\(name)\" is \(an($0.section.singular)) \($0.section.singular), not \(an(what)) \(what)" }
                    ?? "no \(what) \"\(name)\"" + dym(name, pool)
                let hint = !names.isEmpty ? "declared: \(names.joined(separator: ", "))" + (also.isEmpty ? "" : "; also allowed: \(also.joined(separator: ", "))")
                    : "there's no \(what) in the file yet" + (also.isEmpty ? "" : "; allowed: \(also.joined(separator: ", "))")
                err(ref.pointer, message, hint)
            }
        }

        // ---- persist: each entry names something the space owns ----
        mutating func persist(_ spaceName: String) {
            let entries = SpaceDoc.members(SpaceDoc.member(raw, "persist"))
            var persistedSandboxes: Set<String> = []
            for e in entries { if let s = SpaceDoc.string(SpaceDoc.member(e.value, "sandbox")) { persistedSandboxes.insert(s) } }
            func sandboxOf(_ a: SpaceModel.Resource) -> String? {
                let w = SpaceDoc.string(SpaceDoc.member(a.def, "where")) ?? ""
                if placeIsolation(w) == "vm" { return w }   // 774: a vm place is the agent's sandbox
                return w.hasPrefix("sandbox:") ? String(w.dropFirst(8)) : nil
            }
            for e in entries where !e.key.hasPrefix("x-") && SpaceDoc.isMap(e.value) {
                let kinds = SpaceDoc.members(e.value)
                guard kinds.count == 1, SpaceFormat.persistKinds.contains(kinds[0].key) else { continue }
                let kind = kinds[0].key
                let val = SpaceDoc.string(kinds[0].value) ?? SpaceDoc.text(kinds[0].value)
                let p = SpaceDoc.join(SpaceDoc.join("/persist", e.key), kind)
                let inherited = !loc.written(SpaceDoc.join("/persist", e.key))
                let target = val.replacingOccurrences(of: "{space}", with: spaceName)
                let sec: SpaceFormat.Section = kind == "room" ? .rooms : kind == "sandbox" ? .sandboxes : kind == "agent" ? .agents : .folders
                if kind == "agent" && val == "*" {
                    let all = owned(.agents)
                    let fit = all.filter { a in sandboxOf(a).map { persistedSandboxes.contains($0) } ?? true }
                    let left = all.filter { a in !fit.contains { $0.name == a.name } }
                    if !left.isEmpty {
                        err(p, "\"*\" leaves out \(left.map(\.name).joined(separator: ", ")): in a sandbox that isn't persisted",
                            "persist the sandbox too, or that agent starts fresh each run", "warning")
                    }
                    model.persist.append(.init(entry: e.key, kind: kind, target: val, pointer: p, names: fit.map(\.name)))
                    continue
                }
                if kind == "folder", let f = val.first, "~/.".contains(f) {
                    model.persist.append(.init(entry: e.key, kind: kind, target: val, pointer: p, names: [])); continue
                }
                if isSkipped(target) { continue }
                let hit = model.resource(target)
                guard let hit, hit.section == sec else {
                    if inherited {
                        err(p, "persist entry \"\(e.key)\" (inherited) is dropped: no \(kind) \"\(target)\" in this space",
                            "an inherited persist entry that resolves to nothing the space owns is left out; doz space config says so too", "warning")
                        continue
                    }
                    let pool = inSection(sec).map(\.name)
                    err(p, hit.map { "\"\(target)\" is \(an($0.section.singular)) \($0.section.singular), not a \(kind)" } ?? "persist: no \(kind) \"\(target)\"" + dym(target, pool),
                        kind == "folder" ? "a persisted folder is a name from folders: or a path" : "persist names an owned \(kind) under \(kind == "room" ? "chat.rooms" : sec.rawValue):")
                    continue
                }
                if hit.lifetime == "external" {
                    err(p, kind == "agent" && SpaceDoc.member(hit.external, "bot") != nil ? "\"\(target)\" is an external bot: its memory is its own" : "\"\(target)\" is external: it outlives every run already",
                        "persist is for things the space owns; external things are never made, changed or removed")
                    continue
                }
                if kind == "agent", let sb = sandboxOf(hit), !persistedSandboxes.contains(sb) {
                    err(p, "\"\(target)\" runs in sandbox \(sb), which isn't persisted: its Claude data lives on that sandbox's disk",
                        "persist the sandbox too: persist: { \(sb)-disk: { sandbox: \(sb) } }")
                    continue
                }
                model.persist.append(.init(entry: e.key, kind: kind, target: val, pointer: p, names: [hit.name]))
            }
            for p in model.persist {
                for n in p.names {
                    if let i = model.resources.firstIndex(where: { $0.name == n }), model.resources[i].lifetime == "run" { model.resources[i].lifetime = "persisted" }
                }
            }
        }

        // ---- agents: bypass needs a written isolation; transcripts; prompts; one manager ----
        mutating func agents() {
            var manager: String?
            let memoryKept = Set(model.persist.filter { $0.kind == "agent" }.flatMap(\.names))
            let archOff = SpaceDoc.string(SpaceDoc.member(raw, "archive")) == "off"
            for r in inSection(.agents) {
                let v = r.def
                let role = SpaceDoc.string(SpaceDoc.member(v, "role"))
                if role == "manager" {
                    if let manager { err(r.pointer + "/role", "two managers: \"\(manager)\" and \"\(r.name)\"", "a space has at most one manager") }
                    else { manager = r.name }
                }
                let whereS = SpaceDoc.string(SpaceDoc.member(v, "where")) ?? "mac"
                // 774: a declared place — a vm (or external) one is its sandbox; a fenced or unfenced one sets the isolation.
                let placeIso = r.lifetime == "external" ? nil : placeIsolation(whereS)
                let sb = placeIso == "vm" ? whereS
                    : whereS.hasPrefix("sandbox:") ? String(whereS.dropFirst(8)) : whereS == SpaceFormat.workspaceVM ? model.workspaceVM : nil
                let permissions = SpaceDoc.string(SpaceDoc.member(v, "permissions")) ?? SpaceDoc.string(SpaceDoc.member(raw, "permissions"))
                let own = rawDef(.agents, r.name)
                let ownIso = SpaceDoc.member(own, "isolation")
                var isolation = SpaceDoc.string(SpaceDoc.member(v, "isolation"))
                let ownWhere = SpaceDoc.member(own, "where") != nil
                if r.lifetime != "external", let pi = placeIso, pi != "vm" {
                    let wp = r.pointer + (ownWhere ? "/where" : "")
                    if let oi = SpaceDoc.string(ownIso), oi != pi {
                        err(r.pointer + "/isolation", "\"\(r.name)\" is in the place \(whereS), which is \(pi): its isolation is the place's",
                            "remove isolation:, or put \"\(r.name)\" in a place that is \(oi)")
                    }
                    if pi == "unfenced", !ownWhere {
                        err(wp, "\"\(r.name)\" would be unfenced by inheritance: agent_defaults puts it in the unfenced place \(whereS)",
                            "an agent is never unfenced by inheritance: write where: \(whereS) on the agent itself")
                    }
                    isolation = pi
                    placeIsolated.insert(r.name)
                }
                if r.lifetime != "external" {
                    if placeIso != nil && placeIso != "vm" {
                        if permissions == "bypass" && !ownWhere && (ownIso == nil || ownIso == .null) {
                            err(r.pointer, "agent \"\(r.name)\" runs with permissions: bypass, so it must write its own place or isolation",
                                "write where: \(whereS) on the agent itself (it is never inherited)", key: true)
                        }
                    } else if sb != nil {
                        if SpaceDoc.string(ownIso) == "unfenced" {
                            err(r.pointer + "/isolation", "an agent in a sandbox is never unfenced: the VM is the boundary", "remove isolation:")
                        } else if ownIso != nil {
                            err(r.pointer + "/isolation", "isolation doesn't apply in a sandbox: the VM is the boundary", "remove isolation:", "warning", key: true)
                        }
                        isolation = nil
                    } else {
                        if permissions == "bypass" && (ownIso == nil || ownIso == .null) {
                            let pp = r.pointer + "/permissions"
                            let agentSays = SpaceDoc.member(v, "permissions") != nil
                            let from = agentSays ? (loc.sourceOf(pp) ?? loc.sourceOf("/agent_defaults/permissions")) : loc.sourceOf("/permissions")
                            let why = loc.written(pp) ? "" : !agentSays ? " (the space's permissions\(from.map { ", \($0)" } ?? ""))" : from.map { " (from \($0))" } ?? ""
                            err(r.pointer, "agent \"\(r.name)\" runs with permissions: bypass\(why), so it must write its own isolation",
                                "isolation: unfenced gives it full access to your user (as you); isolation: fenced runs it behind Dozable's fence. It is always written on the agent itself, never inherited", key: true)
                        }
                        if isolation == nil { isolation = "fenced" }
                    }
                    if SpaceDoc.member(v, "prompt") != nil && SpaceDoc.member(v, "prompt_file") != nil {
                        err(r.pointer + "/prompt_file", "write prompt or prompt_file, not both", key: true)
                    }
                    agentNetwork(r, own, sandbox: sb, inWorkspaceVM: sb != nil && sb == model.workspaceVM && whereS == SpaceFormat.workspaceVM,
                                 unfenced: sb == nil && isolation == "unfenced", place: placeIso != nil ? whereS : nil)
                }
                let tPath = SpaceDoc.member(own, "transcripts") != nil ? r.pointer + "/transcripts" : "/agent_defaults/transcripts"
                let written = SpaceDoc.string(SpaceDoc.member(v, "transcripts"))
                var transcripts = written ?? (memoryKept.contains(r.name) ? "keep" : archOff ? "keep" : "discard")
                if memoryKept.contains(r.name) && written == "discard" {
                    err(tPath, "\"\(r.name)\" has its memory persisted, so its transcripts can't be discarded",
                        "persisting keeps its conversations (the next run starts it with --continue); discarding would delete them. Remove transcripts: discard, or stop persisting its memory")
                    transcripts = "keep"
                }
                var agent = SpaceModel.Agent(name: r.name, pointer: r.pointer, external: r.external, lifetime: r.lifetime, def: v, sandbox: sb,
                                             isolation: isolation, permissions: permissions, role: role, transcripts: transcripts)
                agent.place = placeIso != nil ? whereS : sb ?? "mac"
                model.agents.append(agent)
            }
        }

        /// A network as compared: its preset (`standard` when a map names none) and its allow list, in order.
        static func network(_ v: JValue?) -> (preset: String, allow: [String])? {
            guard let v else { return nil }
            if let s = SpaceDoc.string(v) { return (s, []) }
            guard SpaceDoc.isMap(v) else { return nil }
            return (SpaceDoc.string(SpaceDoc.member(v, "preset")) ?? "standard", SpaceDoc.strings(SpaceDoc.member(v, "allow")))
        }

        // ---- an agent's own network: only a fenced agent on this Mac has one; in a VM it is the VM's ----
        mutating func agentNetwork(_ r: SpaceModel.Resource, _ own: JValue?, sandbox: String?, inWorkspaceVM: Bool, unfenced: Bool, place: String? = nil) {
            let first = SpaceDoc.member(own, "network")
            guard let net = first ?? SpaceDoc.member(SpaceDozable.of(own), "network") else { return }
            let np = r.pointer + (first != nil ? "/network" : "/x-dozable/network")
            if unfenced {
                err(np, "\"\(r.name)\" is unfenced, so it has no network of its own",
                    "an unfenced agent acts as you: nothing enforces a network for it. Remove network:, or fence it (isolation: fenced)")
                return
            }
            // 774: in a declared place, the format's precedence — workspace default < place < agent: in a fenced place the
            // agent's own network (enforced per session, its own fence) may only narrow the place's; in a vm place it must
            // be the place's (every session of a VM shares its proxy).
            if let pn = place, let pd = placeDef(pn), SpaceDoc.member(pd, "external") == nil {
                let placeNet = WorkspacePlaces.network(SpaceDoc.member(pd, "network"))
                let mine = WorkspacePlaces.network(net)
                let shown = placeNet.map(\.words) ?? WorkspacePlaces.networkDefault
                if placeIsolation(pn) == "fenced" {
                    if let m = mine, !WorkspacePlaces.narrows(m, within: placeNet) {
                        err(np, "\"\(r.name)\"'s network is wider than its place \(pn)'s (\(shown)): an agent's own network may only narrow its place's",
                            "a narrower preset (locked < standard < open) and only hosts the place allows — or widen the place's network")
                    }
                    return
                }
                if placeIsolation(pn) == "vm", SpaceDoc.member(pd, "network") != nil {
                    if mine != placeNet {
                        err(np, "\"\(r.name)\" runs in the vm place \(pn), whose network is \(shown): it can't have its own",
                            "everything in a VM shares its network: remove network:, or change the place's")
                    }
                    return
                }
            }
            guard let sb = sandbox else { return }
            // A VM's network is the workspace's: an agent in it may only repeat it. A sandbox that already exists
            // (external:) keeps its own, which the file does not describe.
            if !inWorkspaceVM, model.resource(sb)?.lifetime == "external" { return }
            let written = SpaceDozable.member(raw, "network", at: .top)
            guard let ws = Self.network(written) ?? Self.network(.string("standard")), let mine = Self.network(net) else { return }
            if mine.preset == ws.preset && mine.allow == ws.allow { return }
            let shown = ws.preset + (ws.allow.isEmpty ? "" : ", allowing \(ws.allow.joined(separator: ", "))") + (written == nil ? ", Dozable's default" : "")
            err(np, "\"\(r.name)\" runs in \(inWorkspaceVM ? "the workspace's VM" : "sandbox \(sb)"), whose network is the workspace's (\(shown)): it can't have its own",
                "everything in a VM shares its network: remove network:, or set the workspace's network:")
        }

        // ---- rooms: at most one main ----
        mutating func rooms() {
            let mains = inSection(.rooms).filter { SpaceDoc.bool(SpaceDoc.member($0.def, "main")) == true }
            for r in mains.dropFirst() { err(r.pointer + "/main", "two main rooms: \"\(mains[0].name)\" and \"\(r.name)\"", "a space has one main room") }
        }

        // ---- services: Dozable has none yet; ports unique ----
        mutating func services() {
            var ports: [Int: String] = [:]
            for r in inSection(.services) {
                if r.lifetime != "external" {
                    err(r.pointer, "Dozable has no services yet: plan refuses an owned service (\"\(r.name)\")",
                        "services arrive after Asks (SPEC-v3 §13); reference a running one with external: { url: … } meanwhile", "warning", key: true)
                }
                for (i, x) in (SpaceDoc.array(SpaceDoc.member(r.def, "ports")) ?? []).enumerated() {
                    guard SpaceDoc.isNumber(x), let p = SpaceDoc.int(x) else { continue }
                    if let prev = ports[p] {
                        err(r.pointer + "/ports/\(i)", prev == r.name ? "port \(p) appears twice in \"\(prev)\"" : "port \(p) appears twice (also in \"\(prev)\")",
                            "each port is reserved for one service")
                    } else { ports[p] = r.name }
                }
                let health = SpaceDoc.member(r.def, "health")
                if SpaceDoc.isMap(health) {
                    let h = ["http", "tcp", "command"].filter { SpaceDoc.member(health, $0) != nil }
                    if h.count != 1 {
                        err(r.pointer + "/health", h.isEmpty ? "health needs one check: http, tcp or command" : "health: one check, not \(h.joined(separator: " and "))")
                    }
                }
            }
        }

        // ---- archive: never inside a folder an agent of the space can write ----
        mutating func archive(_ spaceName: String) {
            let a = SpaceDoc.member(raw, "archive")
            model.archiveOn = SpaceDoc.string(a) != "off"
            let to = SpaceDoc.string(SpaceDoc.member(a, "to"))
            model.archiveTo = to ?? SpaceValidator.archiveTo
            let keep = SpaceDoc.strings(SpaceDoc.member(a, "keep"))
            model.archiveKeep = model.archiveOn ? (keep.isEmpty ? SpaceFormat.archiveKeep : keep) : []
            guard let to else { return }
            let at = to.replacingOccurrences(of: "{space}", with: spaceName)
            for ag in model.agents where ag.lifetime != "external" {
                guard let fname = SpaceDoc.string(SpaceDoc.member(ag.def, "folder")), let f = model.resource(fname), f.section == .folders,
                      f.lifetime == "external" else { continue }
                let access = SpaceDoc.string(SpaceDoc.member(ag.def, "access")) ?? SpaceDoc.string(SpaceDoc.member(f.def, "access")) ?? "rw"
                var dir = SpaceDoc.string(f.external) ?? ""
                while dir.hasSuffix("/") { dir.removeLast() }
                if access != "ro" && (at == dir || at.hasPrefix(dir + "/")) {
                    err("/archive/to", "the archive would be inside \(fname) (\(dir)), which agent \"\(ag.name)\" can write",
                        "the archive is evidence: put it where no agent of the space can write, such as the default in the doz store")
                    break
                }
            }
        }

        // ---- provenance of risky settings ----
        mutating func provenance() {
            for a in model.agents where a.lifetime != "external" {
                for f in ["permissions", "isolation", "remote_control"] {
                    model.provenance["agents.\(a.name).\(f)"] = loc.sourceOf(a.pointer + "/" + f) ?? loc.sourceOf("/agent_defaults/" + f)
                        ?? (f == "permissions" ? loc.sourceOf("/permissions") : nil) ?? "the default"
                }
                // 774: the isolation its place sets comes from the line that puts it there.
                if placeIsolated.contains(a.name) {
                    model.provenance["agents.\(a.name).isolation"] = loc.sourceOf(a.pointer + "/where") ?? loc.sourceOf("/agent_defaults/where") ?? "the default"
                }
                model.provenance["agents.\(a.name).transcripts"] = loc.sourceOf(a.pointer + "/transcripts") ?? loc.sourceOf("/agent_defaults/transcripts") ?? "the default"
            }
            for p in model.persist { model.provenance["persist.\(p.entry)"] = loc.sourceOf(SpaceDoc.join("/persist", p.entry)) ?? "the file" }
            model.provenance["archive"] = loc.sourceOf("/archive") ?? "the default"
        }
    }
}


/// One risky setting and where it comes from (`FILE:LINE`, or `the default`): bypass, unfenced, Remote Control, what
/// persists, `archive: off`, transcripts discarded. `config` lists them; the plan's summary names each with its source.
public struct SpaceRisk: Codable, Equatable, Sendable {
    public var setting: String
    public var source: String
    public init(setting: String, source: String) { self.setting = setting; self.source = source }
    public var line: String { "\(setting): \(source)" }
}

extension SpaceModel {
    /// The owned agents `up` would start (their profile active).
    public var ownedAgents: [Agent] { agents.filter { $0.lifetime != "external" } }

    public var risks: [SpaceRisk] {
        var out: [SpaceRisk] = []
        for a in ownedAgents {
            let src = { (f: String) in provenance["agents.\(a.name).\(f)"] ?? "the default" }
            if a.permissions == "bypass" { out.append(.init(setting: "agents.\(a.name).permissions", source: src("permissions"))) }
            if a.isolation == "unfenced" { out.append(.init(setting: "agents.\(a.name).isolation", source: src("isolation"))) }
            if SpaceDoc.bool(SpaceDoc.member(a.def, "remote_control")) == true {
                out.append(.init(setting: "agents.\(a.name).remote_control", source: src("remote_control")))
            }
        }
        for p in persist { out.append(.init(setting: "persist.\(p.entry)", source: provenance["persist.\(p.entry)"] ?? "the file")) }
        if !archiveOn { out.append(.init(setting: "archive", source: provenance["archive"] ?? "the default")) }
        let discarding = ownedAgents.filter { $0.transcripts == "discard" }
        if !discarding.isEmpty && discarding.count == ownedAgents.count {
            out.append(.init(setting: "transcripts", source: "every agent discards"))
        } else {
            for a in discarding { out.append(.init(setting: "agents.\(a.name).transcripts", source: provenance["agents.\(a.name).transcripts"] ?? "the default")) }
        }
        return out
    }
}
