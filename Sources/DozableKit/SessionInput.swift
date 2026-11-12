import Foundation

/// 678 B5: typing into a held session from a script (`doz sessions send`) — the keys as bytes, the frames for deckhold,
/// and its acknowledgement.
///
/// deckhold handles one client's frames IN ORDER (`client_frames`): DATA goes into the program's input buffer, and a
/// QUERY is answered with one INFO line and the connection closed. So one connection sends DATA… then QUERY, and the
/// INFO frame is the receipt: by the time it arrives, every DATA byte before it is in the program's input buffer. (It
/// does not prove a TUI acted on them — a read-back of the screen does.) `deckhold pipe` answers NOSESSION for a session
/// that never existed and EXIT for one that ended.
public enum SessionInput {
    /// The most one send may carry.
    public static let maximumBytes = 65_536

    public static let keyNames = ["enter", "tab", "esc", "backspace", "up", "down", "left", "right", "home", "end", "pgup", "pgdn",
                                  "ctrl-<letter>", "f1…f12"]

    /// One named key as the bytes a terminal sends (xterm's). nil: not a key this knows.
    public static func key(_ name: String) -> [UInt8]? {
        let k = name.lowercased()
        let esc: UInt8 = 0x1B
        func csi(_ s: String) -> [UInt8] { [esc, UInt8(ascii: "[")] + Array(s.utf8) }
        switch k {
        case "enter", "return": return [0x0D]
        case "tab": return [0x09]
        case "esc", "escape": return [esc]
        case "backspace": return [0x7F]
        case "up": return csi("A")
        case "down": return csi("B")
        case "right": return csi("C")
        case "left": return csi("D")
        case "home": return csi("H")
        case "end": return csi("F")
        case "pgup", "pageup": return csi("5~")
        case "pgdn", "pagedown": return csi("6~")
        case "f1": return [esc, UInt8(ascii: "O"), UInt8(ascii: "P")]
        case "f2": return [esc, UInt8(ascii: "O"), UInt8(ascii: "Q")]
        case "f3": return [esc, UInt8(ascii: "O"), UInt8(ascii: "R")]
        case "f4": return [esc, UInt8(ascii: "O"), UInt8(ascii: "S")]
        case "f5": return csi("15~")
        case "f6": return csi("17~")
        case "f7": return csi("18~")
        case "f8": return csi("19~")
        case "f9": return csi("20~")
        case "f10": return csi("21~")
        case "f11": return csi("23~")
        case "f12": return csi("24~")
        default:
            if k.hasPrefix("ctrl-"), k.count == 6, let c = k.last?.asciiValue, c >= UInt8(ascii: "a"), c <= UInt8(ascii: "z") {
                return [c & 0x1F]
            }
            return nil
        }
    }

    public struct InputError: Error, Equatable, Sendable, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// What a send types, in order: `text` (wrapped in bracketed paste with `paste`), then `keys` as given, then Enter.
    public static func bytes(text: String?, keys: [String], enter: Bool, paste: Bool) throws -> Data {
        var out = Data()
        if let text, !text.isEmpty {
            if paste { out.append(contentsOf: [0x1B] + Array("[200~".utf8)) }
            out.append(contentsOf: Array(text.utf8))
            if paste { out.append(contentsOf: [0x1B] + Array("[201~".utf8)) }
        }
        for k in keys {
            guard let b = key(k) else {
                throw InputError(message: "\(k) is not a key doz knows — one of: \(keyNames.joined(separator: ", "))")
            }
            out.append(contentsOf: b)
        }
        if enter { out.append(0x0D) }
        guard !out.isEmpty else { throw InputError(message: "nothing to send — --text, --keys or --enter") }
        guard out.count <= maximumBytes else { throw InputError(message: "at most \(maximumBytes / 1024) KiB in one send (this is \(out.count) bytes)") }
        return out
    }

    /// The frames one send writes to deckhold: DATA (in pieces of at most 16 KiB), then QUERY.
    public static func frames(_ bytes: Data) -> Data {
        var out = Data()
        func frame(_ t: UInt8, _ p: Data) {
            out.append(t)
            let n = UInt32(p.count)
            out.append(contentsOf: [UInt8(n >> 24), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)])
            out.append(p)
        }
        var at = bytes.startIndex
        while at < bytes.endIndex {
            let end = bytes.index(at, offsetBy: 16_384, limitedBy: bytes.endIndex) ?? bytes.endIndex
            frame(UInt8(ascii: "D"), bytes[at..<end])
            at = end
        }
        frame(UInt8(ascii: "Q"), Data())
        return out
    }

    /// deckhold's answer to a send.
    public enum Receipt: Equatable, Sendable {
        /// The INFO line: every byte is in the program's input buffer.
        case delivered(info: String)
        /// No such session (it never existed).
        case noSession
        /// The session has ended (its exit code).
        case ended(Int32?)
    }

    /// The receipt in what deckhold has sent so far — nil while incomplete. Frames before it (none are expected; a
    /// viewer's SNAPSHOT/DATA never reach a QUERY-only client) are skipped.
    public static func receipt(_ data: Data) -> Receipt? {
        var i = data.startIndex
        while data.endIndex - i >= 5 {
            let t = data[i]
            let n = Int(data[i + 1]) << 24 | Int(data[i + 2]) << 16 | Int(data[i + 3]) << 8 | Int(data[i + 4])
            guard data.endIndex - (i + 5) >= n else { return nil }
            let payload = data[(i + 5)..<(i + 5 + n)]
            switch t {
            case UInt8(ascii: "I"): return .delivered(info: String(decoding: payload, as: UTF8.self))
            case UInt8(ascii: "N"): return .noSession
            case UInt8(ascii: "X"):
                guard payload.count >= 4 else { return .ended(nil) }
                let p = Array(payload)
                return .ended(Int32(bitPattern: UInt32(p[0]) << 24 | UInt32(p[1]) << 16 | UInt32(p[2]) << 8 | UInt32(p[3])))
            default: i += 5 + n
            }
        }
        return nil
    }
}

/// 678 B5: a live screen as `deckhold dump` gives it.
public struct LiveScreen: Codable, Equatable, Sendable {
    /// The screen's rows as text (inert: no escape sequences).
    public var text: String
    public var cols: UInt16?
    public var rows: UInt16?
    public var cursorX: UInt16?
    public var cursorY: UInt16?
    /// `primary` or `alt` (deckhold's words).
    public var screen: String?

    /// nil: not a dump (no `cursor=…` line — no such session).
    public static func parse(_ dump: String) -> LiveScreen? {
        var d = dump
        while d.hasSuffix("\n") { d.removeLast() }
        guard let last = d.components(separatedBy: "\n").last, last.hasPrefix("cursor=") else { return nil }
        let p = SavedScreens.parseDump(d)
        var s = LiveScreen(text: p.text, cols: p.cols, rows: p.rows, cursorX: nil, cursorY: nil, screen: p.screen)
        for field in last.split(separator: " ") where field.hasPrefix("cursor=") {
            let xy = field.dropFirst("cursor=".count).split(separator: ",").compactMap { UInt16($0) }
            if xy.count == 2 { s.cursorX = xy[0]; s.cursorY = xy[1] }
        }
        return s
    }
}
