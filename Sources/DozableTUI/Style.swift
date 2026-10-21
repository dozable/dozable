import Foundation

/// What a piece of text IS — never which colour it is. A call site names a tone; this file alone maps it to SGR.
public enum Tone: Sendable, CaseIterable {
    /// A title.
    case heading
    /// "Step 2 of 6".
    case step
    /// The thing under the cursor, a highlight.
    case accent
    case ok
    case warn
    case bad
    /// Secondary text: details, defaults, hints.
    case dim
    /// A keyboard hint (↑↓, Enter).
    case key
    /// A command or a path (to copy).
    case code
    /// A value someone chose or that was found.
    case value

    /// The SGR parameters — the 16 basic colours and attributes only (no 256-colour or truecolor: every terminal
    /// draws them, in its own palette, light or dark).
    var sgr: String {
        switch self {
        case .heading: "1"
        case .step: "1;36"
        case .accent: "36"
        case .ok: "32"
        case .warn: "33"
        case .bad: "31"
        case .dim: "2"
        case .key: "1"
        case .code: "36"
        case .value: "1"
        }
    }
}

/// The styles. `Style.ok("✓")` is the text in that style, or the text untouched when colour is off (`colour:` —
/// `Terminal.current.colour` unless the caller knows better, e.g. stderr's decision).
public enum Style {
    public static func paint(_ tone: Tone, _ s: String, colour: Bool = Terminal.current.colour) -> String {
        guard colour, !s.isEmpty else { return s }
        return "\u{1B}[\(tone.sgr)m" + s + "\u{1B}[0m"
    }

    public static func heading(_ s: String, colour: Bool = Terminal.current.colour) -> String { paint(.heading, s, colour: colour) }
    public static func step(_ s: String, colour: Bool = Terminal.current.colour) -> String { paint(.step, s, colour: colour) }
    public static func accent(_ s: String, colour: Bool = Terminal.current.colour) -> String { paint(.accent, s, colour: colour) }
    public static func ok(_ s: String, colour: Bool = Terminal.current.colour) -> String { paint(.ok, s, colour: colour) }
    public static func warn(_ s: String, colour: Bool = Terminal.current.colour) -> String { paint(.warn, s, colour: colour) }
    public static func bad(_ s: String, colour: Bool = Terminal.current.colour) -> String { paint(.bad, s, colour: colour) }
    public static func dim(_ s: String, colour: Bool = Terminal.current.colour) -> String { paint(.dim, s, colour: colour) }
    public static func key(_ s: String, colour: Bool = Terminal.current.colour) -> String { paint(.key, s, colour: colour) }
    public static func code(_ s: String, colour: Bool = Terminal.current.colour) -> String { paint(.code, s, colour: colour) }
    public static func value(_ s: String, colour: Bool = Terminal.current.colour) -> String { paint(.value, s, colour: colour) }

    /// The SGR sequence that starts `tone` (for a caller that styles a stream it does not hold whole, e.g. a line that
    /// is redrawn); "" when colour is off.
    public static func open(_ tone: Tone, colour: Bool = Terminal.current.colour) -> String { colour ? "\u{1B}[\(tone.sgr)m" : "" }
    public static func reset(colour: Bool = Terminal.current.colour) -> String { colour ? "\u{1B}[0m" : "" }

    /// `s` without its SGR sequences.
    public static func strip(_ s: String) -> String {
        guard s.contains("\u{1B}") else { return s }
        var out = "", inEsc = false, inCSI = false
        for u in s.unicodeScalars {
            if inCSI {
                if (0x40...0x7E).contains(u.value) { inCSI = false }
                continue
            }
            if inEsc { inEsc = false; if u == "[" { inCSI = true }; continue }
            if u == "\u{1B}" { inEsc = true; continue }
            out.unicodeScalars.append(u)
        }
        return out
    }

    /// The columns `s` takes (SGR excluded; one per character — the glyphs used here are all narrow).
    public static func visibleWidth(_ s: String) -> Int { strip(s).count }
}

/// Plain-text layout helpers (no styling: wrap first, then style the lines).
public enum Layout {
    /// `text` word-wrapped to `width` columns, every line starting with `indent` (the first with `first` when given).
    /// A word longer than a line is cut. Never returns an empty array.
    public static func wrap(_ text: String, width: Int, indent: String = "", first: String? = nil) -> [String] {
        var lines: [String] = []
        var prefix = first ?? indent
        var line = ""                                   // the current line's words, without its prefix
        func room() -> Int { max(10, width - prefix.count) }
        func flush() { lines.append(prefix + line); line = ""; prefix = indent }
        for (i, paragraph) in text.components(separatedBy: "\n").enumerated() {
            if i > 0 { flush() }
            for word in paragraph.split(separator: " ").map(String.init) {
                var w = word
                if !line.isEmpty, line.count + 1 + w.count > room() { flush() }
                while line.isEmpty, w.count > room() {
                    line = String(w.prefix(room()))
                    w = String(w.dropFirst(room()))
                    flush()
                }
                guard !w.isEmpty else { continue }
                line += (line.isEmpty ? "" : " ") + w
            }
        }
        if !line.isEmpty || lines.isEmpty { flush() }
        return lines
    }

    /// `s` cut to `width` columns with "…" (plain text).
    public static func fit(_ s: String, _ width: Int) -> String {
        guard width > 0 else { return "" }
        return s.count <= width ? s : String(s.prefix(max(0, width - 1))) + "…"
    }

    /// `s` padded with spaces to `width` columns (plain or styled).
    public static func pad(_ s: String, _ width: Int) -> String {
        let n = Style.visibleWidth(s)
        return n >= width ? s : s + String(repeating: " ", count: width - n)
    }
}
