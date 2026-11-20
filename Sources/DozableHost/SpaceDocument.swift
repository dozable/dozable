import CryptoKit
import DozableChat
import Foundation

// A space file as the daemon receives it: ONE merged document (an ordered JSON value — the file's order is kept, the
// messages and the plan depend on it), each place's origin (the source and the line that set it), and every source with
// its sha256. The CLI reads the files (`SpaceResolver`, Yams); the daemon never opens a space or a defaults file.

/// Where a place of the merged document was set: the index of its source, the line of its value and of its key.
public struct SpaceOrigin: Codable, Equatable, Sendable {
    public var s: Int
    public var l: Int
    public var k: Int
    public init(s: Int, l: Int, k: Int) { self.s = s; self.l = l; self.k = k }
}

/// One file the space was read from: `space`, `defaults` (an `extends:` file), `override` (`NAME.space.override.yaml`)
/// or `env` (the `.env` beside it). `path` is absolute; `name` its last component.
public struct SpaceSource: Codable, Equatable, Sendable {
    public var path: String
    public var name: String
    public var kind: String
    public var sha256: String
    public init(path: String, name: String, kind: String, sha256: String) {
        self.path = path; self.name = name; self.kind = kind; self.sha256 = sha256
    }
}

/// One problem with a space: an error stops everything, a warning does not. `file` is the source's name, `line` 1-based.
public struct SpaceProblem: Codable, Equatable, Sendable {
    public var severity: String
    public var pointer: String
    public var message: String
    public var hint: String?
    public var file: String
    public var line: Int
    public init(severity: String = "error", pointer: String, message: String, hint: String? = nil, file: String, line: Int) {
        self.severity = severity; self.pointer = pointer; self.message = message; self.hint = hint; self.file = file; self.line = line
    }
    public var isError: Bool { severity == "error" }
    /// As a person reads it: `FILE:LINE  error: MESSAGE` and the hint indented.
    public var text: String {
        "\(file):\(line)  \(severity): \(message)" + (hint.map { "\n    \($0)" } ?? "")
    }
}

/// The brief as the CLI found it beside the file (a look: its sha256 and size, or why it is not usable). Never its text.
public struct SpaceBriefLook: Codable, Equatable, Sendable {
    public var path: String
    public var sha256: String?
    public var bytes: Int?
    public var problem: String?
    public init(path: String, sha256: String? = nil, bytes: Int? = nil, problem: String? = nil) {
        self.path = path; self.sha256 = sha256; self.bytes = bytes; self.problem = problem
    }
}

/// `workspace-up-plan`'s request (`HostRequest.space`). Decoded STRICTLY (an unknown field is refused) and capped at
/// 256 KiB encoded; `spec` is the merged document's JSON text (its order kept).
public struct SpaceRequest: Codable, Equatable, Sendable {
    public static let maximumBytes = 256 << 10
    public var spec: String
    public var sources: [SpaceSource]
    public var origins: [String: SpaceOrigin]
    /// The space file's path as the person named it (shown, never opened).
    public var specPath: String?
    public var brief: SpaceBriefLook?
    /// `--profile`: the profiles whose resources are included.
    public var profiles: [String]?
    /// `workspace-up`: the plan's sha as the person saw it (changed since → refused, nothing done), and the unfenced
    /// agents the person confirmed — exactly the plan's confirm set, or refused.
    public var ifPlan: String?
    public var confirmed: [String]?
    /// An owned agent's `prompt_file`, read by the CLI beside the space file (at most 16 KiB each): agent → its text.
    public var prompts: [String: String]?

    public init(spec: String, sources: [SpaceSource], origins: [String: SpaceOrigin], specPath: String? = nil,
                brief: SpaceBriefLook? = nil, profiles: [String]? = nil) {
        self.spec = spec; self.sources = sources; self.origins = origins; self.specPath = specPath; self.brief = brief
        self.profiles = profiles
    }

    static let known: Set<String> = ["spec", "sources", "origins", "specPath", "brief", "profiles", "ifPlan", "confirmed", "prompts"]
    enum CodingKeys: String, CodingKey { case spec, sources, origins, specPath, brief, profiles, ifPlan, confirmed, prompts }

    public init(from decoder: Decoder) throws {
        let any = try decoder.container(keyedBy: DynamicKey.self)
        if let k = any.allKeys.first(where: { !Self.known.contains($0.stringValue) }) {
            throw HostError(.invalid, "space: unknown field \(k.stringValue)")
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        spec = try c.decode(String.self, forKey: .spec)
        sources = try c.decode([SpaceSource].self, forKey: .sources)
        origins = try c.decode([String: SpaceOrigin].self, forKey: .origins)
        specPath = try c.decodeIfPresent(String.self, forKey: .specPath)
        brief = try c.decodeIfPresent(SpaceBriefLook.self, forKey: .brief)
        profiles = try c.decodeIfPresent([String].self, forKey: .profiles)
        ifPlan = try c.decodeIfPresent(String.self, forKey: .ifPlan)
        confirmed = try c.decodeIfPresent([String].self, forKey: .confirmed)
        prompts = try c.decodeIfPresent([String: String].self, forKey: .prompts)
    }

    /// The request's own limits, checked before anything is read from it (the daemon's and the in-process core's).
    public func check() throws -> JValue {
        let size = (try? JSONEncoder().encode(self).count) ?? Int.max
        guard size <= Self.maximumBytes else {
            throw HostError(.invalid, "the merged space is \(size >> 10) KiB — at most \(Self.maximumBytes >> 10) KiB")
        }
        guard !sources.isEmpty, sources.filter({ $0.kind == "space" }).count == 1,
              sources.allSatisfy({ ["space", "defaults", "override", "env"].contains($0.kind) }) else {
            throw HostError(.invalid, "space: one space source, and only space, defaults, override or env sources")
        }
        for o in origins.values where o.s < 0 || o.s >= sources.count { throw HostError(.invalid, "space: an origin names no source") }
        for (k, v) in prompts ?? [:] where !WorkspaceName.isValidAgent(k) || v.utf8.count > WorkerLaunch.maximumTaskBytes {
            throw HostError(.invalid, "space: the prompt of \(k.prefix(40)) is not one an agent can take (at most \(WorkerLaunch.maximumTaskBytes >> 10) KiB)")
        }
        let doc: JValue
        do { doc = try ChatJSON.parse(Data(spec.utf8)) } catch { throw HostError(.invalid, "space: the merged document is not JSON") }
        guard case .object = doc else { throw HostError(.invalid, "space: the merged document is not a map") }
        try SpaceDoc.refuseDuplicateKeys(doc)
        return doc
    }
}

/// The ordered document's helpers: JSON pointers, members, the merge, the text the sha covers.
public enum SpaceDoc {
    public static func escape(_ k: String) -> String { k.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1") }
    public static func unescape(_ k: String) -> String { k.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~") }
    public static func join(_ base: String, _ k: String) -> String { base + "/" + escape(k) }
    public static func parts(_ p: String) -> [String] { p.split(separator: "/", omittingEmptySubsequences: false).dropFirst().map { unescape(String($0)) } }

    public static func member(_ v: JValue?, _ key: String) -> JValue? {
        guard case .object(let m)? = v else { return nil }
        return m.last { $0.key == key }?.value
    }
    public static func members(_ v: JValue?) -> [JMember] {
        if case .object(let m)? = v { return m }
        return []
    }
    public static func string(_ v: JValue?) -> String? { if case .string(let s)? = v { return s }; return nil }
    public static func bool(_ v: JValue?) -> Bool? { if case .bool(let b)? = v { return b }; return nil }
    public static func int(_ v: JValue?) -> Int? {
        switch v {
        case .int(let n)?: return Int(n)
        case .number(let s)?: return Int(s)
        case .double(let d)? where d == d.rounded(): return Int(d)
        default: return nil
        }
    }
    public static func isNumber(_ v: JValue?) -> Bool {
        switch v { case .int?, .double?, .number?: return true; default: return false }
    }
    public static func array(_ v: JValue?) -> [JValue]? { if case .array(let a)? = v { return a }; return nil }
    public static func strings(_ v: JValue?) -> [String] { (array(v) ?? []).compactMap { string($0) } }
    public static func isMap(_ v: JValue?) -> Bool { if case .object? = v { return true }; return false }

    /// The value at a pointer.
    public static func at(_ doc: JValue, _ pointer: String) -> JValue? {
        var v: JValue? = doc
        for p in parts(pointer) {
            switch v {
            case .object(let m)?: v = m.last { $0.key == p }?.value
            case .array(let a)?: guard let i = Int(p), i >= 0, i < a.count else { return nil }; v = a[i]
            default: return nil
            }
        }
        return v
    }

    /// Maps merge key by key (a key keeps its place; a new one goes last); anything else, lists included, is replaced;
    /// `null` removes a key.
    public static func merge(_ base: JValue?, _ over: JValue?) -> JValue? {
        guard let over else { return base }
        guard case .object(var out)? = base, case .object(let o) = over else { return over }
        for m in o {
            if case .null = m.value { out.removeAll { $0.key == m.key }; continue }
            if let i = out.firstIndex(where: { $0.key == m.key }) {
                out[i].value = merge(out[i].value, m.value) ?? m.value
            } else {
                out.append(JMember(m.key, merge(nil, m.value) ?? m.value))
            }
        }
        return .object(out)
    }

    /// Every pointer in the document (the root `""` first), in order.
    public static func pointers(_ v: JValue, _ base: String = "") -> [String] {
        var out = [base]
        switch v {
        case .object(let m): for x in m { out += pointers(x.value, join(base, x.key)) }
        case .array(let a): for (i, x) in a.enumerated() { out += pointers(x, base + "/\(i)") }
        default: break
        }
        return out
    }

    /// `{space}` filled in every text but under `/secrets` (`{run}` stays).
    public static func fillSpace(_ v: JValue, space: String, at p: String = "") -> JValue {
        if p == "/secrets" { return v }
        switch v {
        case .string(let s): return .string(s.replacingOccurrences(of: "{space}", with: space))
        case .array(let a): return .array(a.enumerated().map { fillSpace($0.element, space: space, at: p + "/\($0.offset)") })
        case .object(let m): return .object(m.map { JMember($0.key, fillSpace($0.value, space: space, at: join(p, $0.key))) })
        default: return v
        }
    }

    /// The document's JSON text: its order kept, nothing else added (what the request carries and the sha covers).
    public static func text(_ v: JValue) -> String { ChatJSON.encodeString(v) }
    public static func sha256(_ s: String) -> String { SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined() }

    static func refuseDuplicateKeys(_ v: JValue, _ p: String = "") throws {
        switch v {
        case .object(let m):
            var seen: Set<String> = []
            for x in m {
                guard seen.insert(x.key).inserted else { throw HostError(.invalid, "space: \(join(p, x.key)) is given twice") }
                try refuseDuplicateKeys(x.value, join(p, x.key))
            }
        case .array(let a): for (i, x) in a.enumerated() { try refuseDuplicateKeys(x, p + "/\(i)") }
        default: break
        }
    }

    /// A value in words, for messages: `the text "x"`, `a map`, `boolean false`.
    static func typeName(_ v: JValue?) -> String {
        switch v {
        case nil, .null?: return "nothing"
        case .array?: return "a list"
        case .object?: return "a map"
        case .string(let s)?: return "the text \"\(s)\""
        case .bool(let b)?: return "boolean \(b)"
        case .int(let n)?: return "number \(n)"
        case .double(let d)?: return "number \(ChatJSON.goFloat(d))"
        case .number(let s)?: return "number \(s)"
        }
    }
}
