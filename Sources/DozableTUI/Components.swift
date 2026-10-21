import Foundation

/// Something drawn as text: `render` gives its lines (no final newline), styled when `colour`. Every component renders
/// the same words with colour on and off — colour never carries a meaning on its own (the glyphs are text).
public protocol Component {
    func render(width: Int, colour: Bool) -> String
}

extension Component {
    /// Rendered for this process's terminal (stdout's width and colour).
    public func render() -> String { render(width: Terminal.current.width, colour: Terminal.current.colour) }
}

/// The widest a rule or a wrapped paragraph gets, however wide the terminal.
let maximumWidth = 100

/// A horizontal rule across the terminal (at most `maximumWidth`).
public struct Rule: Component {
    public init() {}
    public func render(width: Int, colour: Bool) -> String {
        Style.dim(String(repeating: "─", count: max(10, min(width, maximumWidth) - 1)), colour: colour)
    }
}

/// "Step 2 of 6 · Models & keys", then a rule. Preceded by an empty line.
public struct StepHeader: Component {
    public let index: Int, total: Int, title: String
    public init(index: Int, total: Int, title: String) {
        self.index = index
        self.total = total
        self.title = title
    }
    public func render(width: Int, colour: Bool) -> String {
        "\n" + Style.step("Step \(index) of \(total)", colour: colour) + Style.dim(" · ", colour: colour) + Style.heading(title, colour: colour)
            + "\n" + Rule().render(width: width, colour: colour)
    }
}

/// A heading inside a step ("Sign-ins on this Mac").
public struct Section: Component {
    public let title: String
    public init(_ title: String) { self.title = title }
    public func render(width: Int, colour: Bool) -> String { Style.heading(title, colour: colour) }
}

/// An empty line.
public struct Spacer: Component {
    public init() {}
    public func render(width: Int, colour: Bool) -> String { "" }
}

/// One finding: "✓ macOS 27.0", "! vmnet — only --network nat needs it", "✕ disk — …". The glyph is the meaning; its
/// colour only repeats it.
public struct StatusLine: Component {
    public enum Kind: Sendable {
        case ok, warn, bad, info, busy

        public var glyph: String {
            switch self {
            case .ok: "✓"
            case .warn: "!"
            case .bad: "✕"
            case .info: "·"
            case .busy: "…"
            }
        }

        var tone: Tone {
            switch self {
            case .ok: .ok
            case .warn: .warn
            case .bad: .bad
            case .info, .busy: .dim
            }
        }
    }

    public let kind: Kind
    public let text: String
    public let detail: String?
    /// The text's column width (aligns a list of them); nil: as long as it is.
    public var column: Int?
    /// Without a detail: wrap the text under itself (for a person); false keeps it on one line (a script reads it).
    public var wrap: Bool

    public init(_ kind: Kind, _ text: String, detail: String? = nil, column: Int? = nil, wrap: Bool = false) {
        self.kind = kind
        self.text = text
        self.detail = detail
        self.column = column
        self.wrap = wrap
    }

    public func render(width: Int, colour: Bool) -> String {
        let head = "  " + Style.paint(kind.tone, kind.glyph, colour: colour) + " "
        guard let detail, !detail.isEmpty else {
            guard wrap else { return head + text }
            let lines = Layout.wrap(text, width: min(width, maximumWidth), indent: "    ")
            return head + ([String(lines[0].dropFirst(4))] + lines.dropFirst()).joined(separator: "\n")
        }
        let label = column.map { Layout.pad(text, $0) } ?? text
        // The detail wraps under itself, so a long one stays readable.
        let start = 4 + max(column ?? 0, text.count) + 1
        let pad = String(repeating: " ", count: start)
        let lines = Layout.wrap(detail, width: min(width, maximumWidth), indent: pad)
        return head + label + " " + lines.enumerated().map { i, l in
            let body = Style.dim(String(l.dropFirst(start)), colour: colour)
            return i == 0 ? body : pad + body
        }.joined(separator: "\n")
    }
}

/// Aligned pairs, keys dim: a summary.
public struct KeyValues: Component {
    public let pairs: [(key: String, value: String)]
    public init(_ pairs: [(key: String, value: String)]) { self.pairs = pairs }
    public func render(width: Int, colour: Bool) -> String {
        let w = pairs.map(\.key.count).max() ?? 0
        return pairs.map { p in
            "  " + Style.dim(p.key.padding(toLength: w, withPad: " ", startingAt: 0), colour: colour) + "  " + Style.value(p.value, colour: colour)
        }.joined(separator: "\n")
    }
}

/// An indented paragraph, wrapped to the terminal (a lead, a hint, a warning).
public struct Note: Component {
    public enum Kind: Sendable { case plain, info, warn, bad }
    public let text: String
    public let tone: Kind
    public init(_ text: String, tone: Kind = .info) {
        self.text = text
        self.tone = tone
    }
    public func render(width: Int, colour: Bool) -> String {
        let lines = Layout.wrap(text, width: min(width, maximumWidth), indent: "  ")
        let t: Tone? = switch tone {
        case .plain: nil
        case .info: .dim
        case .warn: .warn
        case .bad: .bad
        }
        guard let t else { return lines.joined(separator: "\n") }
        return lines.map { "  " + Style.paint(t, String($0.dropFirst(2)), colour: colour) }.joined(separator: "\n")
    }
}

/// A command to copy: indented, in the code style, never a prompt sign — the line pastes as it is.
public struct Command: Component {
    public let command: String
    public init(_ command: String) { self.command = command }
    public func render(width: Int, colour: Bool) -> String { "    " + Style.code(command, colour: colour) }
}
