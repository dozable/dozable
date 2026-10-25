import Foundation

// 648 (painted thumbnails): a session's screen as CELLS — the one shape every painted picture is drawn from (the
// host's `session-grids` for a running session, a saved screen's `NAME.grid.json`, a tab's frame on Home). deckhold
// answers a GRID frame with it in binary (`Guest/deckhold/deckhold.c`, WIRE: 'G'); `ScreenGrid.decode` reads that,
// checks every length and bound, and makes every run's text INERT — the text came from inside a sandbox.
//
// JSON (the contract the page paints from):
//
//     { cols, rows, gen, fg: "#rrggbb", bg: "#rrggbb", cursor: {x, y} | null, lines: [[Run]] }
//     Run = [col, text, fg "#rrggbb" | null, bg "#rrggbb" | null, flags, cells]
//
// `lines` has exactly `rows` entries (a blank default row is []); a run is `cells` columns of one style from `col`
// (a wide character's tail column adds no text); null colour = the screen's default; flags 1 bold, 2 italic,
// 4 underline, 8 faint, 16 inverse (already applied to the colours — informational).

/// A session's screen as cells (648).
public struct ScreenGrid: Equatable, Sendable {
    /// One run of cells of one style.
    public struct Run: Equatable, Sendable {
        public var col: Int
        /// Inert text: no C0/C1/DEL, no bidi control (`ScreenGrid.inert`).
        public var text: String
        /// "#rrggbb", or nil: the screen's default.
        public var fg: String?
        public var bg: String?
        public var flags: Int
        /// The columns it covers (≥ 1).
        public var cells: Int

        public init(col: Int, text: String, fg: String? = nil, bg: String? = nil, flags: Int = 0, cells: Int) {
            self.col = col
            self.text = text
            self.fg = fg
            self.bg = bg
            self.flags = flags
            self.cells = cells
        }
    }

    public struct Cursor: Codable, Equatable, Sendable {
        public var x: Int
        public var y: Int
        public init(x: Int, y: Int) { self.x = x; self.y = y }
    }

    public var cols: Int
    public var rows: Int
    /// The holder's change counter (opaque: equal = unchanged).
    public var gen: UInt32
    /// The screen's default colours, "#rrggbb".
    public var fg: String
    public var bg: String
    /// nil: hidden.
    public var cursor: Cursor?
    /// Exactly `rows` entries, top to bottom.
    public var lines: [[Run]]

    public static let maximumCols = 1000
    public static let maximumRows = 500
    /// UTF-8 bytes of text a row; the runs past it are left out.
    public static let maximumRowText = 4096
    /// Flags a run may carry (bold, italic, underline, faint, inverse).
    public static let flagMask = 31

    public init(cols: Int, rows: Int, gen: UInt32, fg: String, bg: String, cursor: Cursor?, lines: [[Run]]) {
        self.cols = cols
        self.rows = rows
        self.gen = gen
        self.fg = fg
        self.bg = bg
        self.cursor = cursor
        self.lines = lines
    }

    /// What a GRID frame says.
    public enum Answer: Equatable, Sendable {
        /// The screen is the one of the asked gen.
        case unchanged(gen: UInt32)
        case grid(ScreenGrid)
        /// The holder has no grid to give (larger than the contract allows).
        case none(gen: UInt32)
    }

    public enum DecodeError: Error, Equatable {
        case truncated, version(UInt8), changed(UInt8), size, run, trailing
    }

    /// A GRID frame's payload (deckhold's binary, big-endian — WIRE in deckhold.c), every length and bound checked.
    public static func decode(_ payload: Data) throws -> Answer {
        var r = Reader(bytes: [UInt8](payload))
        let version = try r.u8()
        guard version == 1 else { throw DecodeError.version(version) }
        let gen = try r.u32()
        let changed = try r.u8()
        switch changed {
        case 0: guard r.atEnd else { throw DecodeError.trailing }; return .unchanged(gen: gen)
        case 2: guard r.atEnd else { throw DecodeError.trailing }; return .none(gen: gen)
        case 1: break
        default: throw DecodeError.changed(changed)
        }
        let cols = Int(try r.u16()), rows = Int(try r.u16())
        guard (1...maximumCols).contains(cols), (1...maximumRows).contains(rows) else { throw DecodeError.size }
        let visible = try r.u8() != 0
        let cx = Int(try r.u16()), cy = Int(try r.u16())
        let fg = hex(try r.rgb()), bg = hex(try r.rgb())
        var lines: [[Run]] = []
        lines.reserveCapacity(rows)
        for _ in 0..<rows {
            let count = Int(try r.u16())
            guard count <= cols else { throw DecodeError.run }
            var runs: [Run] = []
            var end = 0, text = 0, full = false
            for _ in 0..<count {
                let col = Int(try r.u16()), cells = Int(try r.u16())
                let flags = Int(try r.u8()) & flagMask
                let hasFg = try r.u8() != 0, f = try r.rgb()
                let hasBg = try r.u8() != 0, b = try r.rgb()
                let bytes = try r.bytes(Int(try r.u16()))
                guard cells >= 1, col >= end, col + cells <= cols else { throw DecodeError.run }
                end = col + cells
                guard !full else { continue }
                let t = inert(String(decoding: bytes, as: UTF8.self))
                guard text + t.utf8.count <= maximumRowText else { full = true; continue }
                text += t.utf8.count
                runs.append(Run(col: col, text: t, fg: hasFg ? hex(f) : nil, bg: hasBg ? hex(b) : nil, flags: flags, cells: cells))
            }
            lines.append(runs)
        }
        guard r.atEnd else { throw DecodeError.trailing }
        let cursor = visible && cx < cols && cy < rows ? Cursor(x: cx, y: cy) : nil
        return .grid(ScreenGrid(cols: cols, rows: rows, gen: gen, fg: fg, bg: bg, cursor: cursor, lines: lines))
    }

    /// Guest text made inert: every C0/C1 control, DEL and bidi control (embeddings, overrides, isolates and the
    /// marks: U+202A–202E, U+2066–2069, U+200E/200F, U+061C) becomes U+FFFD. Nothing in it can move, recolour or
    /// reorder what a page draws around it.
    public static func inert(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            let v = u.value
            let bad = v < 0x20 || (0x7F...0x9F).contains(v) || (0x202A...0x202E).contains(v) || (0x2066...0x2069).contains(v)
                || v == 0x200E || v == 0x200F || v == 0x061C
            out.append(bad ? "\u{FFFD}" : u)
        }
        return String(out)
    }

    /// "#rrggbb", or nil when it is not one.
    public static func isColor(_ s: String) -> Bool {
        s.utf8.count == 7 && s.hasPrefix("#") && s.utf8.dropFirst().allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }

    static func hex(_ c: (UInt8, UInt8, UInt8)) -> String {
        let d = Array("0123456789abcdef".utf8)
        let bytes: [UInt8] = [UInt8(ascii: "#"), d[Int(c.0 >> 4)], d[Int(c.0 & 15)], d[Int(c.1 >> 4)], d[Int(c.1 & 15)], d[Int(c.2 >> 4)], d[Int(c.2 & 15)]]
        return String(decoding: bytes, as: UTF8.self)
    }

    /// The grid as the contract allows it — what a reader of a stored grid (a saved screen's file) gets: nil when
    /// it is not one (sizes, colours, a run out of its row); every text inert again and each row capped.
    public func validated() -> ScreenGrid? {
        guard (1...Self.maximumCols).contains(cols), (1...Self.maximumRows).contains(rows), lines.count == rows,
              Self.isColor(fg), Self.isColor(bg) else { return nil }
        var g = self
        if let c = cursor, !(0..<cols).contains(c.x) || !(0..<rows).contains(c.y) { g.cursor = nil }
        for (y, runs) in lines.enumerated() {
            var end = 0, text = 0
            var kept: [Run] = []
            for var run in runs {
                guard run.cells >= 1, run.col >= end, run.col + run.cells <= cols, run.fg.map(Self.isColor) ?? true,
                      run.bg.map(Self.isColor) ?? true else { return nil }
                end = run.col + run.cells
                run.text = Self.inert(run.text)
                run.flags &= Self.flagMask
                guard text + run.text.utf8.count <= Self.maximumRowText else { break }
                text += run.text.utf8.count
                kept.append(run)
            }
            g.lines[y] = kept
        }
        return g
    }

    private struct Reader {
        let bytes: [UInt8]
        var at = 0
        var atEnd: Bool { at == bytes.count }
        mutating func u8() throws -> UInt8 {
            guard at < bytes.count else { throw DecodeError.truncated }
            defer { at += 1 }
            return bytes[at]
        }
        mutating func u16() throws -> UInt16 { UInt16(try u8()) << 8 | UInt16(try u8()) }
        mutating func u32() throws -> UInt32 { UInt32(try u16()) << 16 | UInt32(try u16()) }
        mutating func rgb() throws -> (UInt8, UInt8, UInt8) { (try u8(), try u8(), try u8()) }
        mutating func bytes(_ n: Int) throws -> ArraySlice<UInt8> {
            guard n >= 0, bytes.count - at >= n else { throw DecodeError.truncated }
            defer { at += n }
            return bytes[at..<(at + n)]
        }
    }
}

extension ScreenGrid: Codable {
    enum CodingKeys: String, CodingKey { case cols, rows, gen, fg, bg, cursor, lines }

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
}

/// A run is an ARRAY on the wire: `[col, text, fg|null, bg|null, flags, cells]`.
extension ScreenGrid.Run: Codable {
    public func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(col)
        try c.encode(text)
        if let fg { try c.encode(fg) } else { try c.encodeNil() }
        if let bg { try c.encode(bg) } else { try c.encodeNil() }
        try c.encode(flags)
        try c.encode(cells)
    }

    public init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        col = try c.decode(Int.self)
        text = try c.decode(String.self)
        fg = try c.decodeNil() ? nil : try c.decode(String.self)
        bg = try c.decodeNil() ? nil : try c.decode(String.self)
        flags = try c.decode(Int.self)
        cells = try c.decode(Int.self)
        guard c.isAtEnd else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "a run has six elements"))
        }
    }
}
