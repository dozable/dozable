import Foundation

// 747 — the timeline's documents, version 1: what this Mac's history looks like to the timeline component (the timeline
// contract, vendored at its pin under Tests/Fixtures/timeline). Every document carries `timeline: 1` and a `type`. The
// same rule as SpaceState everywhere: no message text, prompts, questions, commands, paths, URLs, queries, headers or
// credential values; hosts and other sensitive values only as sensitive attrs (`sattrs`), never in a summary or a rollup.
// Swift needs custom Codable for an attr's value (four scalar types), a Match (by `field`), a metric (point or rollup,
// by `bin`) and a View's range (one of two shapes). `TimelineSchemaTests` checks every shape against the schema.

public enum TimelineSeverity: String, Codable, Sendable, CaseIterable, Comparable {
    case debug, info, notice, warning, error
    public var rank: Int { Self.allCases.firstIndex(of: self)! }
    public static func < (a: Self, b: Self) -> Bool { a.rank < b.rank }
}

public enum TimelineBin: String, Codable, Sendable, CaseIterable {
    case m1 = "1m", h1 = "1h", d1 = "1d"
    /// The nominal width (a local day may be 23 or 25 hours long).
    public var milliseconds: Int64 { switch self { case .m1: return 60_000; case .h1: return 3_600_000; case .d1: return 86_400_000 } }
}

/// An attribute's value: a scalar, never an object; a string is one short line.
public enum TimelineAttr: Codable, Equatable, Sendable, Hashable {
    case string(String), number(Double), bool(Bool), null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else { self = .string(try c.decode(String.self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n):
            if n.rounded() == n, abs(n) < 9_007_199_254_740_992 { try c.encode(Int64(n)) } else { try c.encode(n) }
        case .string(let s): try c.encode(s)
        }
    }

    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    /// The value as a search compares it (`String(a)` in the contract's matcher).
    public var searchText: String? {
        switch self {
        case .null: return nil
        case .bool(let b): return b ? "true" : "false"
        case .number(let n): return n.rounded() == n && abs(n) < 9e15 ? String(Int64(n)) : String(n)
        case .string(let s): return s
        }
    }
}

public struct TimelineLinks: Codable, Equatable, Sendable, Hashable {
    public var run: String?
    public var ask: String?
    public var msg: String?
    public var session: String?
    public var decision: String?
    public init(run: String? = nil, ask: String? = nil, msg: String? = nil, session: String? = nil, decision: String? = nil) {
        self.run = run; self.ask = ask; self.msg = msg; self.session = session; self.decision = decision
    }
    public subscript(_ link: String) -> String? {
        switch link { case "run": return run; case "ask": return ask; case "msg": return msg; case "session": return session
        case "decision": return decision; default: return nil }
    }
}

/// One thing that happened, at `t` (or over [t, t + dur) for a span).
public struct TimelineEvent: Codable, Equatable, Sendable {
    public var id: String
    public var t: Int64
    public var dur: Int64?
    /// An ongoing span (encoded only when true).
    public var open: Bool?
    public var scope: String
    public var source: String
    public var kind: String
    public var severity: TimelineSeverity
    public var summary: String
    public var attrs: [String: TimelineAttr]
    public var links: TimelineLinks

    public init(id: String, t: Int64, dur: Int64? = nil, open: Bool? = nil, scope: String, source: String, kind: String,
                severity: TimelineSeverity, summary: String, attrs: [String: TimelineAttr] = [:], links: TimelineLinks = TimelineLinks()) {
        self.id = id; self.t = t; self.dur = dur; self.open = open == true ? true : nil; self.scope = scope; self.source = source
        self.kind = kind; self.severity = severity; self.summary = summary; self.attrs = attrs; self.links = links
    }

    enum K: String, CodingKey { case id, t, dur, open, scope, source, kind, severity, summary, attrs, links }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        id = try c.decode(String.self, forKey: .id)
        t = try Self.ms(c, .t)!
        dur = try Self.ms(c, .dur)
        open = try c.decodeIfPresent(Bool.self, forKey: .open) == true ? true : nil
        scope = try c.decode(String.self, forKey: .scope)
        source = try c.decode(String.self, forKey: .source)
        kind = try c.decode(String.self, forKey: .kind)
        severity = try c.decode(TimelineSeverity.self, forKey: .severity)
        summary = try c.decode(String.self, forKey: .summary)
        attrs = try c.decode([String: TimelineAttr].self, forKey: .attrs)
        links = try c.decode(TimelineLinks.self, forKey: .links)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        try c.encode(id, forKey: .id); try c.encode(t, forKey: .t)
        try c.encodeIfPresent(dur, forKey: .dur)
        if open == true { try c.encode(true, forKey: .open) }
        try c.encode(scope, forKey: .scope); try c.encode(source, forKey: .source); try c.encode(kind, forKey: .kind)
        try c.encode(severity, forKey: .severity); try c.encode(summary, forKey: .summary)
        try c.encode(attrs, forKey: .attrs); try c.encode(links, forKey: .links)
    }
    /// A time in ms: an integer, or a number with a fraction (rounded).
    static func ms(_ c: KeyedDecodingContainer<K>, _ k: K) throws -> Int64? {
        if let i = try? c.decodeIfPresent(Int64.self, forKey: k) { return i }
        return try c.decodeIfPresent(Double.self, forKey: k).map { Int64($0.rounded()) }
    }
}

/// One sample of a series, or a series over one bin.
public enum TimelineMetric: Codable, Equatable, Sendable {
    case point(series: String, scope: String, t: Int64, value: Double)
    case rollup(series: String, scope: String, t: Int64, bin: TimelineBin, min: Double, max: Double, sum: Double, count: Int64)

    enum K: String, CodingKey { case series, scope, t, value, bin, min, max, sum, count }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        let series = try c.decode(String.self, forKey: .series), scope = try c.decode(String.self, forKey: .scope)
        let t = Int64(try c.decode(Double.self, forKey: .t).rounded())
        if let bin = try c.decodeIfPresent(TimelineBin.self, forKey: .bin) {
            self = .rollup(series: series, scope: scope, t: t, bin: bin, min: try c.decode(Double.self, forKey: .min),
                           max: try c.decode(Double.self, forKey: .max), sum: try c.decode(Double.self, forKey: .sum),
                           count: Int64(try c.decode(Double.self, forKey: .count)))
        } else {
            self = .point(series: series, scope: scope, t: t, value: try c.decode(Double.self, forKey: .value))
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        func num(_ v: Double, _ k: K) throws {
            if v.rounded() == v, abs(v) < 9_007_199_254_740_992 { try c.encode(Int64(v), forKey: k) } else { try c.encode(v, forKey: k) }
        }
        switch self {
        case .point(let s, let sc, let t, let v):
            try c.encode(s, forKey: .series); try c.encode(sc, forKey: .scope); try c.encode(t, forKey: .t); try num(v, .value)
        case .rollup(let s, let sc, let t, let bin, let mn, let mx, let sum, let n):
            try c.encode(s, forKey: .series); try c.encode(sc, forKey: .scope); try c.encode(t, forKey: .t)
            try c.encode(bin, forKey: .bin); try num(mn, .min); try num(mx, .max); try num(sum, .sum); try c.encode(n, forKey: .count)
        }
    }
    public var series: String { switch self { case .point(let s, _, _, _), .rollup(let s, _, _, _, _, _, _, _): return s } }
    public var scope: String { switch self { case .point(_, let s, _, _), .rollup(_, let s, _, _, _, _, _, _): return s } }
    public var t: Int64 { switch self { case .point(_, _, let t, _), .rollup(_, _, let t, _, _, _, _, _): return t } }
}

/// Events over one bin on one row.
public struct TimelineEventBin: Codable, Equatable, Sendable {
    public var scope: String
    public var t: Int64
    public var bin: TimelineBin
    public var count: Int64
    public var severity: [String: Int64]
    public var kinds: [String: Int64]?
    public var kindsTruncated: Bool?
    public init(scope: String, t: Int64, bin: TimelineBin, count: Int64, severity: [String: Int64], kinds: [String: Int64]? = nil,
                kindsTruncated: Bool? = nil) {
        self.scope = scope; self.t = t; self.bin = bin; self.count = count; self.severity = severity; self.kinds = kinds
        self.kindsTruncated = kindsTruncated
    }
}

// MARK: search — the component parses; the query carries the parse

/// One test of an event (told apart by `field`).
public enum TimelineMatch: Codable, Equatable, Sendable {
    case text(String)
    case kind(String, prefix: Bool)
    case source(String, prefix: Bool)
    case severity(op: String, value: TimelineSeverity)
    case scope(String, fromTop: Bool)
    case link(String, value: String)
    case attr(key: String, value: String)

    static let ops: Set<String> = ["eq", "ge", "gt", "le", "lt"]
    static let links: Set<String> = ["run", "ask", "msg", "session", "decision"]

    enum K: String, CodingKey { case field, value, prefix, op, from, link, key }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        let allowed: Set<String>
        let field = try c.decode(String.self, forKey: .field)
        let value = try c.decode(String.self, forKey: .value)
        switch field {
        case "text": self = .text(value); allowed = ["field", "value"]
        case "kind", "source":
            let p = try c.decodeIfPresent(Bool.self, forKey: .prefix)
            if p == false { throw DecodingError.dataCorruptedError(forKey: .prefix, in: c, debugDescription: "prefix is true or absent") }
            self = field == "kind" ? .kind(value, prefix: p == true) : .source(value, prefix: p == true); allowed = ["field", "value", "prefix"]
        case "severity":
            let op = try c.decode(String.self, forKey: .op)
            guard Self.ops.contains(op), let s = TimelineSeverity(rawValue: value) else {
                throw DecodingError.dataCorruptedError(forKey: .op, in: c, debugDescription: "not a severity test")
            }
            self = .severity(op: op, value: s); allowed = ["field", "value", "op"]
        case "scope":
            let from = try c.decode(String.self, forKey: .from)
            guard from == "top" || from == "segments" else { throw DecodingError.dataCorruptedError(forKey: .from, in: c, debugDescription: "top or segments") }
            self = .scope(value, fromTop: from == "top"); allowed = ["field", "value", "from"]
        case "link":
            let l = try c.decode(String.self, forKey: .link)
            guard Self.links.contains(l) else { throw DecodingError.dataCorruptedError(forKey: .link, in: c, debugDescription: "not a link") }
            self = .link(l, value: value); allowed = ["field", "value", "link"]
        case "attr":
            let key = try c.decode(String.self, forKey: .key)
            guard TimelineAttrs.isKeyName(key) else { throw DecodingError.dataCorruptedError(forKey: .key, in: c, debugDescription: "not an attr name") }
            self = .attr(key: key, value: value); allowed = ["field", "value", "key"]
        default:
            throw DecodingError.dataCorruptedError(forKey: .field, in: c, debugDescription: "no field \(field)")
        }
        // Strict: nothing else in a match.
        for k in c.allKeys where !allowed.contains(k.rawValue) {
            throw DecodingError.dataCorruptedError(forKey: k, in: c, debugDescription: "\(k.rawValue) is not part of a \(field) match")
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        switch self {
        case .text(let v): try c.encode("text", forKey: .field); try c.encode(v, forKey: .value)
        case .kind(let v, let p), .source(let v, let p):
            if case .kind = self { try c.encode("kind", forKey: .field) } else { try c.encode("source", forKey: .field) }
            try c.encode(v, forKey: .value); if p { try c.encode(true, forKey: .prefix) }
        case .severity(let op, let v): try c.encode("severity", forKey: .field); try c.encode(op, forKey: .op); try c.encode(v, forKey: .value)
        case .scope(let v, let top): try c.encode("scope", forKey: .field); try c.encode(v, forKey: .value); try c.encode(top ? "top" : "segments", forKey: .from)
        case .link(let l, let v): try c.encode("link", forKey: .field); try c.encode(l, forKey: .link); try c.encode(v, forKey: .value)
        case .attr(let k, let v): try c.encode("attr", forKey: .field); try c.encode(k, forKey: .key); try c.encode(v, forKey: .value)
        }
    }
}

public struct TimelineAstTerm: Codable, Equatable, Sendable {
    public var not: Bool?
    public var any: [TimelineMatch]
    public init(not: Bool? = nil, any: [TimelineMatch]) { self.not = not == true ? true : nil; self.any = any }
    enum K: String, CodingKey { case not, any }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        not = try c.decodeIfPresent(Bool.self, forKey: .not) == true ? true : nil
        any = try c.decode([TimelineMatch].self, forKey: .any)
        guard !any.isEmpty else { throw DecodingError.dataCorruptedError(forKey: .any, in: c, debugDescription: "a term needs a match") }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        if not == true { try c.encode(true, forKey: .not) }
        try c.encode(any, forKey: .any)
    }
}

public struct TimelineSearchAst: Codable, Equatable, Sendable {
    public var all: [TimelineAstTerm]
    public init(all: [TimelineAstTerm] = []) { self.all = all }
}

// MARK: the catalogue

public struct TimelineRetention: Codable, Equatable, Sendable {
    /// Days of single events (nil: kept until the user deletes it).
    public var events: Int?
    public var m1: Int?
    public var h1: Int?
    public var d1: Int?
    public init(events: Int?, m1: Int?, h1: Int?, d1: Int?) { self.events = events; self.m1 = m1; self.h1 = h1; self.d1 = d1 }
    public func days(_ b: TimelineBin) -> Int? { switch b { case .m1: return m1; case .h1: return h1; case .d1: return d1 } }

    enum K: String, CodingKey { case events, rollups }
    struct R: Codable { var m: Int?; var h: Int?; var d: Int?
        enum K: String, CodingKey { case m = "1m", h = "1h", d = "1d" }
        init(m: Int?, h: Int?, d: Int?) { self.m = m; self.h = h; self.d = d }
        init(from decoder: Decoder) throws { let c = try decoder.container(keyedBy: K.self)
            m = try c.decodeIfPresent(Int.self, forKey: .m); h = try c.decodeIfPresent(Int.self, forKey: .h); d = try c.decodeIfPresent(Int.self, forKey: .d) }
        func encode(to encoder: Encoder) throws { var c = encoder.container(keyedBy: K.self)
            try c.encode(m, forKey: .m); try c.encode(h, forKey: .h); try c.encode(d, forKey: .d) }
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        events = try c.decodeIfPresent(Int.self, forKey: .events)
        let r = try c.decode(R.self, forKey: .rollups)
        m1 = r.m; h1 = r.h; d1 = r.d
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        try c.encode(events, forKey: .events)
        try c.encode(R(m: m1, h: h1, d: d1), forKey: .rollups)
    }
}

public struct TimelineSeriesInfo: Codable, Equatable, Sendable {
    public var name: String, unit: String, type: String, at: String, title: String
    public init(name: String, unit: String, type: String, at: String, title: String) {
        self.name = name; self.unit = unit; self.type = type; self.at = at; self.title = title
    }
}

public struct TimelineKindInfo: Codable, Equatable, Sendable {
    public var name: String, title: String
    public var span: Bool?
    public var notYet: Bool?
    public init(_ name: String, _ title: String, span: Bool = false, notYet: Bool = false) {
        self.name = name; self.title = title; self.span = span ? true : nil; self.notYet = notYet ? true : nil
    }
}

public struct TimelineSourceInfo: Codable, Equatable, Sendable {
    public var name: String
    public var title: String
    public var status: String
    public var at: [String]
    public var kinds: [TimelineKindInfo]
    public var kindPattern: String?
    public var series: [TimelineSeriesInfo]
    public var attrs: [String]
    public var sensitive: [String]?
    public var people: [String]?
    public var defaultRetention: TimelineRetention
}

public struct TimelineKeptFrom: Codable, Equatable, Sendable {
    public var events: Int64?
    public var m1: Int64?
    public var h1: Int64?
    public var d1: Int64?
    public init(events: Int64? = nil, m1: Int64? = nil, h1: Int64? = nil, d1: Int64? = nil) {
        self.events = events; self.m1 = m1; self.h1 = h1; self.d1 = d1
    }
    enum K: String, CodingKey { case events, rollups }
    enum RK: String, CodingKey { case m = "1m", h = "1h", d = "1d" }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        events = try c.decodeIfPresent(Double.self, forKey: .events).map { Int64($0) }
        let r = try c.nestedContainer(keyedBy: RK.self, forKey: .rollups)
        m1 = try r.decodeIfPresent(Double.self, forKey: .m).map { Int64($0) }
        h1 = try r.decodeIfPresent(Double.self, forKey: .h).map { Int64($0) }
        d1 = try r.decodeIfPresent(Double.self, forKey: .d).map { Int64($0) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        try c.encodeIfPresent(events, forKey: .events)
        var r = c.nestedContainer(keyedBy: RK.self, forKey: .rollups)
        try r.encodeIfPresent(m1, forKey: .m); try r.encodeIfPresent(h1, forKey: .h); try r.encodeIfPresent(d1, forKey: .d)
    }
}

public struct TimelineEffectiveRetention: Codable, Equatable, Sendable {
    public var source: String
    public var retention: TimelineRetention
    /// `user` or `default`.
    public var setBy: String
    public var keptFrom: TimelineKeptFrom
    public init(source: String, retention: TimelineRetention, setBy: String, keptFrom: TimelineKeptFrom) {
        self.source = source; self.retention = retention; self.setBy = setBy; self.keptFrom = keptFrom
    }
    enum K: String, CodingKey { case source, setBy, keptFrom }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        source = try c.decode(String.self, forKey: .source)
        setBy = try c.decode(String.self, forKey: .setBy)
        keptFrom = try c.decode(TimelineKeptFrom.self, forKey: .keptFrom)
        retention = try TimelineRetention(from: decoder)
    }
    public func encode(to encoder: Encoder) throws {
        try retention.encode(to: encoder)
        var c = encoder.container(keyedBy: K.self)
        try c.encode(source, forKey: .source); try c.encode(setBy, forKey: .setBy); try c.encode(keptFrom, forKey: .keptFrom)
    }
}

public struct TimelineScopeName: Codable, Equatable, Sendable {
    public var scope: String
    public var label: String
    public var space: Bool?
    public var aliases: [String]?
    public init(scope: String, label: String, space: Bool? = nil, aliases: [String]? = nil) {
        self.scope = scope; self.label = label; self.space = space == true ? true : nil; self.aliases = aliases?.isEmpty == true ? nil : aliases
    }
}

public struct TimelineCatalog: Codable, Equatable, Sendable {
    public var timeline = 1
    public var type = "catalog"
    public var hosts: [String]
    public var sources: [TimelineSourceInfo]
    public var retention: [TimelineEffectiveRetention]
    public var names: [TimelineScopeName]?
    public var now: Int64
    public init(hosts: [String], sources: [TimelineSourceInfo], retention: [TimelineEffectiveRetention], names: [TimelineScopeName]?, now: Int64) {
        self.hosts = hosts; self.sources = sources; self.retention = retention; self.names = names; self.now = now
    }
}

// MARK: queries and results

public struct TimelineFilters: Codable, Equatable, Sendable {
    public var source: [String]?
    public var kind: [String]?
    public var severity: [TimelineSeverity]?
    public var scope: [String]?
    public init(source: [String]? = nil, kind: [String]? = nil, severity: [TimelineSeverity]? = nil, scope: [String]? = nil) {
        self.source = source; self.kind = kind; self.severity = severity; self.scope = scope
    }
}

public struct TimelineQuery: Codable, Equatable, Sendable {
    public var timeline = 1
    public var type = "query"
    public var scope: String
    public var depth: Int
    public var from: Int64
    public var to: Int64
    public var bin: TimelineBin?
    public var tz: String?
    public var `where`: TimelineSearchAst?
    public var q: String?
    public var filters: TimelineFilters?
    public var series: [String]?
    public var limit: Int?
    public var cursor: String?
    public init(scope: String, depth: Int, from: Int64, to: Int64, bin: TimelineBin? = nil, tz: String? = nil, where w: TimelineSearchAst? = nil,
                filters: TimelineFilters? = nil, series: [String]? = nil, limit: Int? = nil, cursor: String? = nil) {
        self.scope = scope; self.depth = depth; self.from = from; self.to = to; self.bin = bin; self.tz = tz; self.where = w
        self.filters = filters; self.series = series; self.limit = limit; self.cursor = cursor
    }
    enum K: String, CodingKey { case timeline, type, scope, depth, from, to, bin, tz, `where`, q, filters, series, limit, cursor }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        timeline = try c.decode(Int.self, forKey: .timeline)
        type = try c.decode(String.self, forKey: .type)
        guard timeline == 1, type == "query" else { throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "not a timeline/1 query") }
        scope = try c.decode(String.self, forKey: .scope)
        depth = try c.decode(Int.self, forKey: .depth)
        from = Int64(try c.decode(Double.self, forKey: .from))
        to = Int64(try c.decode(Double.self, forKey: .to))
        bin = try c.decodeIfPresent(TimelineBin.self, forKey: .bin)
        tz = try c.decodeIfPresent(String.self, forKey: .tz)
        self.where = try c.decodeIfPresent(TimelineSearchAst.self, forKey: .where)
        q = try c.decodeIfPresent(String.self, forKey: .q)
        filters = try c.decodeIfPresent(TimelineFilters.self, forKey: .filters)
        series = try c.decodeIfPresent([String].self, forKey: .series)
        limit = try c.decodeIfPresent(Int.self, forKey: .limit)
        cursor = try c.decodeIfPresent(String.self, forKey: .cursor)
    }
}

public struct TimelineRow: Codable, Equatable, Sendable {
    public var scope: String
    public var label: String
    public var kind: String
    public var space: Bool?
    public var depth: Int
    public var own: Bool?
    public var children: Int
    public var count: Int64
    public var first: Int64?
    public var last: Int64?
    public init(scope: String, label: String, kind: String, space: Bool? = nil, depth: Int, own: Bool? = nil, children: Int, count: Int64,
                first: Int64? = nil, last: Int64? = nil) {
        self.scope = scope; self.label = label; self.kind = kind; self.space = space == true ? true : nil; self.depth = depth
        self.own = own == true ? true : nil; self.children = children; self.count = count; self.first = first; self.last = last
    }
}

public struct TimelineResult: Codable, Equatable, Sendable {
    public var timeline = 1
    public var type = "result"
    public var rows: [TimelineRow]
    public var events: [TimelineEvent]?
    public var bins: [TimelineEventBin]?
    public var spans: [TimelineEvent]?
    public var metrics: [TimelineMetric]
    public var total: Int64
    public var totalEstimated: Bool?
    public var retention: [TimelineEffectiveRetention]
    public var warnings: [String]?
    public var next: String?
    public init(rows: [TimelineRow], events: [TimelineEvent]? = nil, bins: [TimelineEventBin]? = nil, spans: [TimelineEvent]? = nil,
                metrics: [TimelineMetric], total: Int64, totalEstimated: Bool? = nil, retention: [TimelineEffectiveRetention],
                warnings: [String]? = nil, next: String? = nil) {
        self.rows = rows; self.events = events; self.bins = bins; self.spans = spans; self.metrics = metrics; self.total = total
        self.totalEstimated = totalEstimated; self.retention = retention; self.warnings = warnings?.isEmpty == true ? nil : warnings; self.next = next
    }
}

public struct TimelineBatch: Codable, Equatable, Sendable {
    public var timeline = 1
    public var type = "batch"
    public var events: [TimelineEvent]
    public var metrics: [TimelineMetric]
    public var rows: [TimelineRow]?
    public var now: Int64
    public var retention: [TimelineEffectiveRetention]?
    public var resume: String?
    public init(events: [TimelineEvent], metrics: [TimelineMetric], rows: [TimelineRow]? = nil, now: Int64,
                retention: [TimelineEffectiveRetention]? = nil, resume: String? = nil) {
        self.events = events; self.metrics = metrics; self.rows = rows?.isEmpty == true ? nil : rows; self.now = now
        self.retention = retention; self.resume = resume
    }
}

public struct TimelineView: Codable, Equatable, Sendable {
    public enum Range: Codable, Equatable, Sendable {
        case fixed(from: Int64, to: Int64)
        case last(String)
        enum K: String, CodingKey { case from, to, last }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: K.self)
            if let l = try c.decodeIfPresent(String.self, forKey: .last) {
                guard ["15m", "1h", "1d", "1w", "run"].contains(l) else {
                    throw DecodingError.dataCorruptedError(forKey: .last, in: c, debugDescription: "not a quick range")
                }
                self = .last(l)
            } else {
                self = .fixed(from: Int64(try c.decode(Double.self, forKey: .from)), to: Int64(try c.decode(Double.self, forKey: .to)))
            }
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: K.self)
            switch self {
            case .fixed(let f, let t): try c.encode(f, forKey: .from); try c.encode(t, forKey: .to)
            case .last(let l): try c.encode(l, forKey: .last)
            }
        }
    }
    public var timeline = 1
    public var type = "view"
    public var name: String
    public var scope: String
    public var depth: Int
    public var range: Range
    public var q: String?
    public var filters: TimelineFilters?
    public var live: Bool?
}

public struct TimelineRecording: Codable, Equatable, Sendable {
    public var timeline = 1
    public var type = "recording"
    public var catalog: TimelineCatalog
    public var events: [TimelineEvent]
    public var metrics: [TimelineMetric]
}

// MARK: scopes — kind:name segments from the fleet down

public enum TimelineScope {
    public static let kinds = ["host", "workspace", "sandbox", "session", "room", "run"]

    /// A name escaped for a segment: `/`, `:`, `%` and white space as %XX.
    public static func escape(_ name: String) -> String {
        var out = ""
        for ch in name.unicodeScalars {
            if ch == "/" || ch == ":" || ch == "%" || CharacterSet.whitespacesAndNewlines.contains(ch) {
                out += "%" + String(format: "%02X", ch.value & 0xFF)
            } else { out.unicodeScalars.append(ch) }
        }
        return out
    }
    public static func unescape(_ s: String) -> String { s.removingPercentEncoding ?? s }

    public static func join(_ parent: String, _ kind: String, _ name: String) -> String {
        (parent.isEmpty ? "" : parent + "/") + kind + ":" + escape(name)
    }
    public static func level(_ s: String) -> Int { s.isEmpty ? 0 : s.split(separator: "/", omittingEmptySubsequences: false).count }
    public static func prefix(_ s: String, level: Int) -> String {
        guard level > 0 else { return "" }
        return s.split(separator: "/", omittingEmptySubsequences: false).prefix(level).joined(separator: "/")
    }
    public static func parent(_ s: String) -> String { prefix(s, level: level(s) - 1) }
    /// Segment by segment: a prefix matches itself and everything under it.
    public static func within(_ s: String, _ p: String) -> Bool { p.isEmpty || s == p || s.hasPrefix(p + "/") }
    public static func kind(_ s: String) -> String {
        guard !s.isEmpty else { return "fleet" }
        let last = s.split(separator: "/").last ?? ""
        return String(last.split(separator: ":", maxSplits: 1).first ?? "")
    }
    public static func name(_ s: String) -> String {
        guard !s.isEmpty else { return "all hosts" }
        let last = s.split(separator: "/").last ?? ""
        let parts = last.split(separator: ":", maxSplits: 1)
        return unescape(parts.count > 1 ? String(parts[1]) : "")
    }
    /// A path of `kind:name` segments ("" is the fleet).
    public static func isScope(_ s: String) -> Bool {
        if s.isEmpty { return true }
        for seg in s.split(separator: "/", omittingEmptySubsequences: false) {
            let parts = seg.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, kinds.contains(String(parts[0])), !parts[1].isEmpty else { return false }
            var it = parts[1].unicodeScalars.makeIterator()
            while let c = it.next() {
                if c == "%" {
                    guard let a = it.next(), let b = it.next(), a.properties.isASCIIHexDigit, b.properties.isASCIIHexDigit,
                          !CharacterSet.lowercaseLetters.contains(a), !CharacterSet.lowercaseLetters.contains(b) else { return false }
                } else if c == "/" || c == ":" || CharacterSet.whitespacesAndNewlines.contains(c) { return false }
            }
        }
        return true
    }
}

// MARK: attrs — the one place a forbidden key is refused

public enum TimelineAttrs {
    /// No attr may ever be named one of these (the contract's §6): text, secrets, argv, a request beyond its host and port.
    public static let forbidden: Set<String> = ["text", "body", "message", "prompt", "question", "command", "argv", "token", "secret",
                                                "password", "key_value", "query", "query_string", "url", "path", "headers", "cookie", "hostname"]
    public static func isKeyName(_ k: String) -> Bool {
        guard let f = k.unicodeScalars.first, ("a"..."z").contains(f) else { return false }
        return k.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" }
    }

    /// The builder every source mapper writes through: a forbidden or malformed key is dropped (a debug build stops on
    /// it), a string is one line of at most 200 characters.
    public struct Builder {
        public private(set) var attrs: [String: TimelineAttr] = [:]
        public init() {}
        public mutating func set(_ key: String, _ value: TimelineAttr?) {
            guard let value else { return }
            guard isKeyName(key), !forbidden.contains(key) else {
                assertionFailure("timeline: the attr \(key) is never written")
                return
            }
            if case .string(let s) = value { attrs[key] = .string(TimelineText.line(s)) } else { attrs[key] = value }
        }
        public mutating func set(_ key: String, _ s: String?) { set(key, s.map(TimelineAttr.string)) }
        public mutating func set(_ key: String, _ n: Int64?) { set(key, n.map { TimelineAttr.number(Double($0)) }) }
        public mutating func set(_ key: String, _ n: Int?) { set(key, n.map { TimelineAttr.number(Double($0)) }) }
        public mutating func set(_ key: String, _ n: Double?) { set(key, n.map(TimelineAttr.number)) }
        public mutating func set(_ key: String, _ b: Bool?) { set(key, b.map(TimelineAttr.bool)) }
    }
}

public enum TimelineText {
    /// One line, at most `max` characters (a summary, a string attr).
    public static func line(_ s: String, max: Int = 200) -> String {
        var one = s.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        one = String(one.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : Character($0) })
        if one.count > max { one = String(one.prefix(max - 1)) + "…" }
        return one
    }
}
