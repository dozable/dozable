import Foundation
import DozableKit
import DozableHost

// 648 (painted thumbnails) — the live pictures of the dashboard's tiles, as cells:
//
//   POST /api/v1/grids   {items: [{sandbox, session, gen}]}   (CSRF; ≤ 64 items; a read — WebExposure `read`)
//     → {items: [{sandbox, session, state: "grid" | "unchanged" | "unavailable", grid?, reason?}]}   (in the order asked)
//
// The host's `session-grids` (one GRID frame per picture over the status watcher it already holds — never a new guest
// exec, never a wake), projected field by field. With no host running every item is `unavailable`: the route never
// starts one (the page polls it twice a second; it must never keep a host alive or bring a stopped one back). `reason`
// is a sentence the page shows as it is. The grid's text came from inside a sandbox: inert on the host, and capped
// again here.

/// The route's body, decoded STRICTLY: exactly `items`, each exactly `{sandbox, session, gen}`; refusals are fixed
/// messages that never echo a value.
public enum WebGridsRequest {
    public static func decode(_ body: Data) throws -> [SessionGridRequest] {
        guard let obj = try? JSONSerialization.jsonObject(with: body), let d = obj as? [String: Any] else {
            throw WebAction.Invalid("the body must be a JSON object")
        }
        guard Set(d.keys) == ["items"], let raw = d["items"] as? [Any] else { throw WebAction.Invalid("the body is {items: [{sandbox, session, gen}]}") }
        guard raw.count <= HostCore.maximumGridItems else { throw WebAction.Invalid("at most \(HostCore.maximumGridItems) pictures a request") }
        return try raw.map { item in
            guard let o = item as? [String: Any], Set(o.keys) == ["sandbox", "session", "gen"] else {
                throw WebAction.Invalid("an item is {sandbox, session, gen}")
            }
            guard let s = o["sandbox"] as? String, WebRoute.isSandboxName(s) else { throw WebAction.Invalid("sandbox: not a sandbox name") }
            guard let n = o["session"] as? String, WebRoute.isSessionName(n) else { throw WebAction.Invalid("session: not a session name") }
            guard let g = o["gen"] as? NSNumber, CFGetTypeID(g) == CFNumberGetTypeID(), !CFNumberIsFloatType(g),
                  g.int64Value >= 0, g.int64Value <= Int64(UInt32.max) else {
                throw WebAction.Invalid("gen: a whole number from 0 (0: none yet)")
            }
            return SessionGridRequest(sandbox: s, session: n, gen: UInt32(g.int64Value))
        }
    }
}

/// A grid as the page paints it — the contract (ScreenGrid's shape), copied field by field.
public struct WebGrid: Equatable, Sendable, Codable {
    public struct Run: Equatable, Sendable, Codable {
        public var col: Int
        public var text: String
        public var fg: String?
        public var bg: String?
        public var flags: Int
        public var cells: Int

        /// `[col, text, fg|null, bg|null, flags, cells]`.
        public func encode(to encoder: Encoder) throws {
            var c = encoder.unkeyedContainer()
            try c.encode(col)
            try c.encode(text)
            if let fg { try c.encode(fg) } else { try c.encodeNil() }
            if let bg { try c.encode(bg) } else { try c.encodeNil() }
            try c.encode(flags)
            try c.encode(cells)
        }

        public init(col: Int, text: String, fg: String?, bg: String?, flags: Int, cells: Int) {
            self.col = col; self.text = text; self.fg = fg; self.bg = bg; self.flags = flags; self.cells = cells
        }

        public init(from decoder: Decoder) throws {
            let r = try ScreenGrid.Run(from: decoder)
            self.init(col: r.col, text: r.text, fg: r.fg, bg: r.bg, flags: r.flags, cells: r.cells)
        }
    }

    public struct Cursor: Equatable, Sendable, Codable {
        public var x: Int
        public var y: Int
    }

    public var cols: Int
    public var rows: Int
    public var gen: UInt32
    public var fg: String
    public var bg: String
    public var cursor: Cursor?
    public var lines: [[Run]]

    /// nil when it is not a grid the contract allows (the host's is; this is the projection's own check).
    public init?(_ g: ScreenGrid) {
        guard let v = g.validated() else { return nil }
        cols = v.cols
        rows = v.rows
        gen = v.gen
        fg = v.fg
        bg = v.bg
        cursor = v.cursor.map { Cursor(x: $0.x, y: $0.y) }
        lines = v.lines.map { $0.map { Run(col: $0.col, text: $0.text, fg: $0.fg, bg: $0.bg, flags: $0.flags, cells: $0.cells) } }
    }

    enum CodingKeys: String, CodingKey { case cols, rows, gen, fg, bg, cursor, lines }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cols = try c.decode(Int.self, forKey: .cols)
        rows = try c.decode(Int.self, forKey: .rows)
        gen = try c.decode(UInt32.self, forKey: .gen)
        fg = try c.decode(String.self, forKey: .fg)
        bg = try c.decode(String.self, forKey: .bg)
        cursor = try c.decodeIfPresent(Cursor.self, forKey: .cursor)
        lines = try c.decode([[Run]].self, forKey: .lines)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(cols, forKey: .cols)
        try c.encode(rows, forKey: .rows)
        try c.encode(gen, forKey: .gen)
        try c.encode(fg, forKey: .fg)
        try c.encode(bg, forKey: .bg)
        if let cursor { try c.encode(cursor, forKey: .cursor) } else { try c.encodeNil(forKey: .cursor) }
        try c.encode(lines, forKey: .lines)
    }
}

/// The route's answer.
public struct WebGrids: Equatable, Sendable, Codable {
    public struct Item: Equatable, Sendable, Codable {
        public var sandbox: String
        public var session: String
        /// `grid`, `unchanged` or `unavailable`.
        public var state: String
        public var grid: WebGrid?
        /// Why there is no picture — words the page shows as they are.
        public var reason: String?
    }

    public var items: [Item]

    public init(_ answers: [SessionGridAnswer]) {
        items = answers.map { a in
            switch a.state {
            case .grid:
                guard let g = a.grid.flatMap(WebGrid.init) else {
                    return Item(sandbox: a.sandbox, session: a.session, state: "unavailable", grid: nil, reason: Self.sentence(.tooLarge))
                }
                return Item(sandbox: a.sandbox, session: a.session, state: "grid", grid: g, reason: nil)
            case .unchanged:
                return Item(sandbox: a.sandbox, session: a.session, state: "unchanged", grid: nil, reason: nil)
            case .unavailable:
                return Item(sandbox: a.sandbox, session: a.session, state: "unavailable", grid: nil, reason: Self.sentence(a.reason))
            }
        }
    }

    /// Every item unavailable, for one reason (no host, or the host could not be asked).
    public static func unavailable(_ items: [SessionGridRequest], _ why: String) -> WebGrids {
        var g = WebGrids([])
        g.items = items.map { Item(sandbox: $0.sandbox, session: $0.session, state: "unavailable", grid: nil, reason: why) }
        return g
    }

    /// The host could not be asked (an older host that has no such request, or a failure).
    public static let hostNotAsked = "the host could not be asked for this picture"

    /// The page shows these as they are (≤ 120 characters, no internal word).
    public static func sentence(_ r: SessionGridAnswer.Reason?) -> String {
        switch r {
        case .notFound: "there is no such sandbox"
        case .notRunning: "the sandbox is not running"
        case .noWatcher: "no live picture of this session — one started before an update gets it when it restarts"
        case .busy: "too many pictures asked at once — asked again in a moment"
        case .timeout: "the session did not answer in time"
        case .tooLarge: "the screen is too large to paint"
        case .noHost: "Dozable's host is not running"
        case .invalid: "not a session name"
        case nil: hostNotAsked
        }
    }
}
