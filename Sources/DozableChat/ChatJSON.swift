import Foundation

// The chat server's JSON, byte for byte as the reference server writes it, and read as it reads it.
//
// The chat protocol is defined by a server written in Go, and clients (and the conformance runner) see its exact bytes.
// Foundation's JSONSerialization differs from Go's encoder in ways a client can see: Go sorts the keys of a map, keeps
// the field order of a struct, writes `<`, `>` and `&` as \u003c, \u003e and \u0026, U+2028 and U+2029 escaped, never
// escapes `/`, and writes a float in its shortest form without an exponent between 1e-6 and 1e21 (`5`, not `5.0`).
// So the server builds values as `JValue` and writes them here. Reading follows Go's `encoding/json` too: a key matches
// a field case-insensitively, the last one wins, invalid UTF-8 becomes U+FFFD, and a value of the wrong type is an error.

/// One JSON value. An object keeps its members in order: a struct's field order, or (for a map) sorted by `map(_:)`.
public enum JValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    /// A number as it was read (its literal text): kept so an integer field can be read exactly.
    case number(String)
    case string(String)
    case array([JValue])
    case object([JMember])

    /// A Go map: the members sorted by key, as `encoding/json` writes a map.
    public static func map(_ m: [String: JValue]) -> JValue {
        .object(m.keys.sorted().map { JMember($0, m[$0]!) })
    }

    /// A list of strings.
    public static func strings(_ a: [String]) -> JValue { .array(a.map { .string($0) }) }
}

/// One member of an object.
public struct JMember: Sendable, Equatable {
    public var key: String
    public var value: JValue
    public init(_ key: String, _ value: JValue) { self.key = key; self.value = value }
}

/// Builds an object in field order, leaving out the "omitempty" fields that are empty.
public struct JObject {
    public private(set) var members: [JMember] = []
    public init() {}
    public mutating func add(_ key: String, _ value: JValue) { members.append(JMember(key, value)) }
    /// A string field with `omitempty`: left out when empty.
    public mutating func omitEmpty(_ key: String, _ value: String) { if !value.isEmpty { add(key, .string(value)) } }
    public mutating func omitEmpty(_ key: String, _ value: Bool) { if value { add(key, .bool(true)) } }
    public mutating func omitEmpty(_ key: String, _ value: Double) { if value != 0 { add(key, .double(value)) } }
    public var value: JValue { .object(members) }
}

// MARK: - Writing

public enum ChatJSON {
    /// The compact encoding (`json.Marshal`).
    public static func encode(_ v: JValue) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(256)
        write(v, into: &out, indent: nil, level: 0)
        return out
    }

    public static func encodeString(_ v: JValue) -> String { String(decoding: encode(v), as: UTF8.self) }

    /// `json.MarshalIndent(v, "", indent)`.
    public static func encodeIndented(_ v: JValue, indent: String) -> [UInt8] {
        var out: [UInt8] = []
        write(v, into: &out, indent: Array(indent.utf8), level: 0)
        return out
    }

    private static func newline(_ out: inout [UInt8], _ indent: [UInt8], _ level: Int) {
        out.append(0x0A)
        for _ in 0..<level { out.append(contentsOf: indent) }
    }

    private static func write(_ v: JValue, into out: inout [UInt8], indent: [UInt8]?, level: Int) {
        switch v {
        case .null: out.append(contentsOf: Array("null".utf8))
        case .bool(let b): out.append(contentsOf: Array((b ? "true" : "false").utf8))
        case .int(let n): out.append(contentsOf: Array(String(n).utf8))
        case .double(let d): out.append(contentsOf: Array(goFloat(d).utf8))
        case .number(let raw): out.append(contentsOf: Array(raw.utf8))
        case .string(let s): writeString(s, into: &out)
        case .array(let a):
            if a.isEmpty { out.append(contentsOf: [0x5B, 0x5D]); return }
            out.append(0x5B)
            for (i, e) in a.enumerated() {
                if i > 0 { out.append(0x2C) }
                if let indent { newline(&out, indent, level + 1) }
                write(e, into: &out, indent: indent, level: level + 1)
            }
            if let indent { newline(&out, indent, level) }
            out.append(0x5D)
        case .object(let m):
            if m.isEmpty { out.append(contentsOf: [0x7B, 0x7D]); return }
            out.append(0x7B)
            for (i, e) in m.enumerated() {
                if i > 0 { out.append(0x2C) }
                if let indent { newline(&out, indent, level + 1) }
                writeString(e.key, into: &out)
                out.append(0x3A)
                if indent != nil { out.append(0x20) }
                write(e.value, into: &out, indent: indent, level: level + 1)
            }
            if let indent { newline(&out, indent, level) }
            out.append(0x7D)
        }
    }

    private static let hex = Array("0123456789abcdef".utf8)

    /// Go's string encoding with HTML escaping (the default of `json.Marshal` and `json.Encoder`).
    static func writeString(_ s: String, into out: inout [UInt8]) {
        out.append(0x22)
        for u in s.unicodeScalars {
            switch u.value {
            case 0x22: out.append(contentsOf: [0x5C, 0x22])
            case 0x5C: out.append(contentsOf: [0x5C, 0x5C])
            case 0x08: out.append(contentsOf: [0x5C, 0x62])
            case 0x0C: out.append(contentsOf: [0x5C, 0x66])
            case 0x0A: out.append(contentsOf: [0x5C, 0x6E])
            case 0x0D: out.append(contentsOf: [0x5C, 0x72])
            case 0x09: out.append(contentsOf: [0x5C, 0x74])
            case 0x00..<0x20, 0x3C, 0x3E, 0x26:
                let b = UInt8(u.value)
                out.append(contentsOf: [0x5C, 0x75, 0x30, 0x30, hex[Int(b >> 4)], hex[Int(b & 0xF)]])
            case 0x2028: out.append(contentsOf: Array("\\u2028".utf8))
            case 0x2029: out.append(contentsOf: Array("\\u2029".utf8))
            default: out.append(contentsOf: Array(String(u).utf8))
            }
        }
        out.append(0x22)
    }

    /// A float64 as Go's encoder writes it: the shortest digits that read back the same, in plain decimal for
    /// 1e-6 <= |x| < 1e21 (and 0), else with an exponent (`1e-7`, `1e+21`).
    public static func goFloat(_ d: Double) -> String {
        guard d.isFinite else { return "null" }   // Go refuses these; the server never writes one
        if d == 0 { return d.sign == .minus ? "-0" : "0" }
        // Swift's description is also the shortest round-trip form; only its notation differs.
        let (neg, digits, exp10) = decompose(d)
        let a = abs(d)
        if a < 1e-6 || a >= 1e21 {
            var s = neg ? "-" : ""
            s += String(digits.first!)
            if digits.count > 1 { s += "." + digits.dropFirst() }
            let e = exp10 - 1
            if e < 0 { s += "e-" + (e > -10 ? "0" : "") + String(-e) } else { s += "e+" + (e < 10 ? "0" : "") + String(e) }
            // Go then drops the leading zero of a negative two-digit exponent: e-07 → e-7.
            if let r = s.range(of: "e-0") { s.replaceSubrange(r, with: "e-") }
            return s
        }
        var s = neg ? "-" : ""
        if exp10 <= 0 {
            s += "0." + String(repeating: "0", count: -exp10) + digits
        } else if exp10 >= digits.count {
            s += digits + String(repeating: "0", count: exp10 - digits.count)
        } else {
            let i = digits.index(digits.startIndex, offsetBy: exp10)
            s += digits[..<i] + "." + digits[i...]
        }
        return s
    }

    /// The significant digits of d (no leading or trailing zeros) and where the decimal point goes: d = 0.DIGITS × 10^exp10.
    static func decompose(_ d: Double) -> (Bool, String, Int) {
        var text = "\(abs(d))"
        var exp = 0
        if let e = text.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            exp = Int(text[text.index(after: e)...]) ?? 0
            text = String(text[..<e])
        }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        let intPart = String(parts[0]), frac = parts.count > 1 ? String(parts[1]) : ""
        var digits = intPart + frac
        var point = intPart.count + exp
        while digits.hasPrefix("0") && digits.count > 1 { digits.removeFirst(); point -= 1 }
        while digits.hasSuffix("0") && digits.count > 1 { digits.removeLast() }
        return (d.sign == .minus, digits, point)
    }
}

// MARK: - Reading

public struct ChatJSONError: Error, Sendable, Equatable, CustomStringConvertible {
    public var description: String
    public init(_ d: String) { description = d }
}

extension ChatJSON {
    /// Reads one JSON value. `trailing: false` refuses anything but white space after it (`json.Unmarshal`); `true`
    /// ignores what follows (`json.Decoder.Decode`, which reads the first value of a body).
    public static func parse(_ bytes: [UInt8], trailing: Bool = false) throws -> JValue {
        try bytes.withUnsafeBufferPointer { buf in
            var p = Parser(b: buf)
            p.skipSpace()
            let v = try p.value(depth: 0)
            if !trailing {
                p.skipSpace()
                if p.i != buf.count { throw ChatJSONError("invalid character after top-level value") }
            }
            return v
        }
    }

    public static func parse(_ data: Data, trailing: Bool = false) throws -> JValue { try parse([UInt8](data), trailing: trailing) }

    /// How deep values may nest. Go allows 10000; the server's lines and bodies never nest beyond a handful, and a
    /// deeper value is refused as malformed rather than risk the stack of a worker thread.
    static let maxDepth = 512

    struct Parser {
        let b: UnsafeBufferPointer<UInt8>
        var i = 0

        mutating func skipSpace() {
            while i < b.count, b[i] == 0x20 || b[i] == 0x09 || b[i] == 0x0A || b[i] == 0x0D { i += 1 }
        }

        mutating func value(depth: Int) throws -> JValue {
            guard depth < ChatJSON.maxDepth else { throw ChatJSONError("exceeded max depth") }
            guard i < b.count else { throw ChatJSONError("unexpected end of JSON input") }
            switch b[i] {
            case 0x7B: // {
                i += 1
                var members: [JMember] = []
                skipSpace()
                if i < b.count, b[i] == 0x7D { i += 1; return .object(members) }
                while true {
                    skipSpace()
                    guard i < b.count, b[i] == 0x22 else { throw ChatJSONError("looking for beginning of object key string") }
                    let k = try string()
                    skipSpace()
                    guard i < b.count, b[i] == 0x3A else { throw ChatJSONError("after object key") }
                    i += 1
                    skipSpace()
                    let v = try value(depth: depth + 1)
                    members.append(JMember(k, v))
                    skipSpace()
                    guard i < b.count else { throw ChatJSONError("unexpected end of JSON input") }
                    if b[i] == 0x2C { i += 1; continue }
                    if b[i] == 0x7D { i += 1; return .object(members) }
                    throw ChatJSONError("after object key:value pair")
                }
            case 0x5B: // [
                i += 1
                var items: [JValue] = []
                skipSpace()
                if i < b.count, b[i] == 0x5D { i += 1; return .array(items) }
                while true {
                    skipSpace()
                    items.append(try value(depth: depth + 1))
                    skipSpace()
                    guard i < b.count else { throw ChatJSONError("unexpected end of JSON input") }
                    if b[i] == 0x2C { i += 1; continue }
                    if b[i] == 0x5D { i += 1; return .array(items) }
                    throw ChatJSONError("after array element")
                }
            case 0x22: return .string(try string())
            case 0x74: try literal("true"); return .bool(true)
            case 0x66: try literal("false"); return .bool(false)
            case 0x6E: try literal("null"); return .null
            default: return .number(try number())
            }
        }

        mutating func literal(_ word: StaticString) throws {
            let w = UnsafeBufferPointer(start: word.utf8Start, count: word.utf8CodeUnitCount)
            guard i + w.count <= b.count else { throw ChatJSONError("unexpected end of JSON input") }
            for k in 0..<w.count where b[i + k] != w[k] { throw ChatJSONError("invalid character in literal") }
            i += w.count
        }

        mutating func number() throws -> String {
            let start = i
            if i < b.count, b[i] == 0x2D { i += 1 }
            guard i < b.count else { throw ChatJSONError("unexpected end of JSON input") }
            if b[i] == 0x30 { i += 1 } else if (0x31...0x39).contains(b[i]) {
                while i < b.count, (0x30...0x39).contains(b[i]) { i += 1 }
            } else { throw ChatJSONError("invalid character looking for beginning of value") }
            if i < b.count, b[i] == 0x2E {
                i += 1
                guard i < b.count, (0x30...0x39).contains(b[i]) else { throw ChatJSONError("in numeric literal") }
                while i < b.count, (0x30...0x39).contains(b[i]) { i += 1 }
            }
            if i < b.count, b[i] == 0x65 || b[i] == 0x45 {
                i += 1
                if i < b.count, b[i] == 0x2B || b[i] == 0x2D { i += 1 }
                guard i < b.count, (0x30...0x39).contains(b[i]) else { throw ChatJSONError("in exponent of numeric literal") }
                while i < b.count, (0x30...0x39).contains(b[i]) { i += 1 }
            }
            return String(decoding: UnsafeBufferPointer(rebasing: b[start..<i]), as: UTF8.self)
        }

        /// A string literal; `i` is at its opening quote. Invalid UTF-8 and lone surrogates become U+FFFD, as in Go.
        mutating func string() throws -> String {
            i += 1
            let start = i
            // The common case: no escape. Scan to the closing quote, refusing control characters.
            while i < b.count {
                let c = b[i]
                if c == 0x22 {
                    let s = String(decoding: UnsafeBufferPointer(rebasing: b[start..<i]), as: UTF8.self)
                    i += 1
                    return s
                }
                if c == 0x5C { break }
                if c < 0x20 { throw ChatJSONError("invalid character in string literal") }
                i += 1
            }
            guard i < b.count else { throw ChatJSONError("unexpected end of JSON input") }
            // With escapes: collect bytes, decode once at the end.
            var bytes = [UInt8](UnsafeBufferPointer(rebasing: b[start..<i]))
            while i < b.count {
                let c = b[i]
                if c == 0x22 { i += 1; return String(decoding: bytes, as: UTF8.self) }
                if c < 0x20 { throw ChatJSONError("invalid character in string literal") }
                if c != 0x5C { bytes.append(c); i += 1; continue }
                i += 1
                guard i < b.count else { throw ChatJSONError("unexpected end of JSON input") }
                let e = b[i]
                i += 1
                switch e {
                case 0x22, 0x5C, 0x2F: bytes.append(e)
                case 0x62: bytes.append(0x08)
                case 0x66: bytes.append(0x0C)
                case 0x6E: bytes.append(0x0A)
                case 0x72: bytes.append(0x0D)
                case 0x74: bytes.append(0x09)
                case 0x75:
                    var u = try hex4()
                    if (0xD800..<0xDC00).contains(u) {
                        // a high surrogate: a low one must follow, else U+FFFD
                        if i + 1 < b.count, b[i] == 0x5C, b[i + 1] == 0x75 {
                            let save = i
                            i += 2
                            let lo = try hex4()
                            if (0xDC00..<0xE000).contains(lo) {
                                u = 0x10000 + ((u - 0xD800) << 10) + (lo - 0xDC00)
                            } else { u = 0xFFFD; i = save }
                        } else { u = 0xFFFD }
                    } else if (0xDC00..<0xE000).contains(u) { u = 0xFFFD }
                    bytes.append(contentsOf: Array(String(Unicode.Scalar(u) ?? "\u{FFFD}").utf8))
                default: throw ChatJSONError("invalid character in string escape code")
                }
            }
            throw ChatJSONError("unexpected end of JSON input")
        }

        mutating func hex4() throws -> UInt32 {
            guard i + 4 <= b.count else { throw ChatJSONError("unexpected end of JSON input") }
            var v: UInt32 = 0
            for _ in 0..<4 {
                let c = b[i]
                let d: UInt32
                switch c {
                case 0x30...0x39: d = UInt32(c - 0x30)
                case 0x61...0x66: d = UInt32(c - 0x61 + 10)
                case 0x41...0x46: d = UInt32(c - 0x41 + 10)
                default: throw ChatJSONError("invalid character in \\u hexadecimal character escape")
                }
                v = v << 4 | d
                i += 1
            }
            return v
        }
    }
}

// MARK: - Reading into fields, as Go fills a struct

/// A type mismatch while reading a field: Go's `UnmarshalTypeError`. The line port closes a connection on it.
public struct ChatFieldError: Error, Sendable, CustomStringConvertible {
    public var description: String
}

extension JValue {
    /// The member Go would put in the struct field `name`: a key equal to it, or equal ignoring case; the last one wins.
    public func field(_ name: String) -> JValue? {
        guard case .object(let m) = self else { return nil }
        var found: JValue?
        let folded = name.lowercased()
        for e in m where e.key == name || e.key.lowercased() == folded { found = e.value }
        return found
    }

    public var isNull: Bool { if case .null = self { return true }; return false }
    public var isObject: Bool { if case .object = self { return true }; return false }

    /// The string, for a field of type string: null leaves it empty; another type is an error.
    public func goString(_ what: String) throws -> String {
        switch self {
        case .null: return ""
        case .string(let s): return s
        default: throw ChatFieldError(description: "\(what): not a string")
        }
    }

    public func goBool(_ what: String) throws -> Bool {
        switch self {
        case .null: return false
        case .bool(let b): return b
        default: throw ChatFieldError(description: "\(what): not a bool")
        }
    }

    /// An integer field: a number with no fraction or exponent that fits.
    public func goInt(_ what: String) throws -> Int {
        switch self {
        case .null: return 0
        case .int(let n): return Int(n)
        case .number(let raw):
            guard let n = Int(raw) else { throw ChatFieldError(description: "\(what): not an integer") }
            return n
        default: throw ChatFieldError(description: "\(what): not a number")
        }
    }

    public func goStrings(_ what: String) throws -> [String] {
        switch self {
        case .null: return []
        case .array(let a): return try a.map { try $0.goString(what) }
        default: throw ChatFieldError(description: "\(what): not an array")
        }
    }

    /// A number as a Double (the `at` of stored shapes).
    public var doubleValue: Double? {
        switch self {
        case .int(let n): return Double(n)
        case .double(let d): return d
        case .number(let raw): return Double(raw)
        default: return nil
        }
    }

    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
}
