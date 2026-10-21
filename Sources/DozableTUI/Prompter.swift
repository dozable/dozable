import Darwin
import Foundation

/// One option of a `choice`: its label and, under it, what it means.
public struct ChoiceOption: Equatable, Sendable {
    public var label: String
    public var detail: String?
    public init(_ label: String, detail: String? = nil) {
        self.label = label
        self.detail = detail
    }

    /// "Read-only — clone and read …" → label "Read-only", detail "clone and read …" (the typed fallback's one line).
    public init(line: String) {
        if let r = line.range(of: " — ") {
            label = String(line[..<r.lowerBound])
            detail = String(line[r.upperBound...])
        } else {
            label = line
            detail = nil
        }
    }

    /// The typed fallback's line.
    var line: String { detail.map { "\(label) — \($0)" } ?? label }
}

/// Questions on the terminal (594 D10; 637 the key-driven components): asked with the recommended answer pre-selected
/// (Enter accepts it); `--yes` accepts every default; not a terminal or `--json` never asks (a missing answer with no
/// default is an error for the caller). Asked on /dev/tty — never stdin, which may carry data.
///
/// Two ways to ask, the same answers:
/// - **keys** (on a terminal, when the caller asks for them): `choice`/`choose` move with ↑/↓ (or j/k) and pick with
///   Enter or a number; `yesNo` takes y/n or Enter; `text` edits a line with its default shown dim and refuses a bad
///   value inline, under the field; `checklist` moves with ↑/↓ and ticks with Space. The terminal is put in raw mode
///   for the question only and restored on every way out (Ctrl-C included: restored, then the interrupt goes on).
/// - **typed** (everywhere else; the reference): numbered options and typed answers, a line at a time.
public struct Prompter {
    /// True: questions are asked. False: every answer is its default.
    public let interactive: Bool
    /// True: the key-driven components (raw mode); false: typed answers.
    public let keys: Bool
    private let channel: PromptChannel?
    private let colour: Bool
    private let fixedWidth: Int?
    private let fixedHeight: Int?
    /// What Ctrl-C does once the terminal is restored (tests replace it): the process's own interrupt.
    public var onInterrupt: () -> Void = Prompter.interruptProcess

    /// Interactive only when stdin is a terminal, and neither `yes` nor `json`; typed answers need stdout to be one
    /// too (as before). `keys`: the key-driven components when stdout is a terminal, else typed answers — so
    /// `doz onboard | cat` still asks, a line at a time, on the terminal.
    public init(yes: Bool, json: Bool, keys: Bool = false) {
        let stdinTTY = isatty(STDIN_FILENO) == 1, stdoutTTY = isatty(STDOUT_FILENO) == 1
        colour = Terminal.current.colour
        fixedWidth = nil
        fixedHeight = nil
        if yes || json || !stdinTTY || !(stdoutTTY || keys) {
            interactive = false
            self.keys = false
            channel = nil
        } else if let c = TTYChannel() {
            interactive = true
            self.keys = keys && stdoutTTY
            channel = c
        } else {
            interactive = false
            self.keys = false
            channel = nil
        }
    }

    /// Asking through `channel` (tests: a `ScriptedChannel`).
    public init(channel: PromptChannel, keys: Bool, colour: Bool = false, width: Int = 80, height: Int = 60) {
        interactive = true
        self.keys = keys
        self.channel = channel
        self.colour = colour
        fixedWidth = width
        fixedHeight = height
    }

    private var width: Int { max(20, fixedWidth ?? Terminal.current.width) }

    private func write(_ s: String) { channel?.write(s) }

    /// Run `body` with raw keys; nil when they cannot be had (the caller falls back to typed answers).
    private func withKeys<T>(_ body: () -> T) -> T? {
        guard keys, let channel, channel.beginKeys() else { return nil }
        defer {
            write("\u{1B}[?25h")
            channel.endKeys()
        }
        return body()
    }

    /// Ctrl-C while raw: the terminal back as it was, then the interrupt delivered as if raw mode had never been.
    private func interrupted() {
        write("\u{1B}[?25h\n")
        channel?.endKeys()
        onInterrupt()
    }

    public static func interruptProcess() {
        signal(SIGINT, SIG_DFL)
        raise(SIGINT)
        exit(130)
    }

    // MARK: the questions

    /// A line of text; Enter keeps `default`. `valid` returns an error message to ask again.
    public func text(_ question: String, default def: String, valid: (String) -> String? = { _ in nil }) -> String {
        guard interactive else { return def }
        if let v = withKeys({ keyText(question, default: def, valid: valid) }) { return v }
        while true {
            write("\(question) [\(def)]: ")
            guard let line = readLine() else { write("\n"); return def }
            let v = line.isEmpty ? def : line
            if let why = valid(v) { write("  \(why)\n"); continue }
            return v
        }
    }

    /// One of `options` (each "label — detail"); Enter keeps `preferred`.
    public func choose(_ question: String, _ options: [String], preferred: Int) -> Int {
        choice(question, options.map { ChoiceOption(line: $0) }, default: preferred)
    }

    /// One of `options`; Enter keeps `default`.
    public func choice(_ question: String, _ options: [ChoiceOption], default preferred: Int) -> Int {
        guard interactive, !options.isEmpty else { return preferred }
        if let i = withKeys({ keyChoice(question, options, default: preferred) }) { return i }
        write("\(question)\n")
        for (i, o) in options.enumerated() { write("  \(i + 1)) \(o.line)\(i == preferred ? "   ← recommended" : "")\n") }
        while true {
            write("Choose 1–\(options.count) [\(preferred + 1)]: ")
            guard let line = readLine() else { write("\n"); return preferred }
            if line.isEmpty { return preferred }
            if let n = Int(line), (1...options.count).contains(n) { return n - 1 }
            write("  a number from 1 to \(options.count)\n")
        }
    }

    /// A checklist (numbered, ticked ones marked); Enter keeps the ticks; else the numbers wanted (`1,3`), or `0` for
    /// none. Keys: Space ticks, Enter confirms.
    public func checklist(_ question: String, _ items: [(label: String, ticked: Bool)]) -> [Bool] {
        let def = items.map(\.ticked)
        guard interactive else { return def }
        if let t = withKeys({ keyChecklist(question, items) }) { return t }
        write("\(question)\n")
        for (i, it) in items.enumerated() { write("  [\(it.ticked ? "x" : " ")] \(i + 1)) \(it.label)\n") }
        while true {
            write("Enter keeps the ticked ones; or type the numbers you want (e.g. 1,3), 0 for none: ")
            guard let line = readLine() else { write("\n"); return def }
            if line.isEmpty { return def }
            if line == "0" { return items.map { _ in false } }
            let parts = line.split(whereSeparator: { $0 == "," || $0 == " " }).map { Int($0) }
            if parts.allSatisfy({ $0 != nil && (1...items.count).contains($0!) }) {
                let set = Set(parts.map { $0! - 1 })
                return items.indices.map { set.contains($0) }
            }
            write("  numbers from 1 to \(items.count), separated by commas\n")
        }
    }

    /// 634: one of `words`, typed (`Use Node.js …? [Y/n/other]`, `[claude/pi/opencode/no]`): the default is shown
    /// capitalised and Enter keeps it; `also` are accepted without being shown. A word is matched case-insensitively,
    /// and `y`/`n` stand for `yes`/`no` when those are the words. Keys: a choice of `words` (`also` are typed-only).
    public func pick(_ question: String, _ words: [String], default def: String, also: [String] = []) -> String {
        guard interactive else { return def }
        if let i = withKeys({ keyChoice(question, words.map { ChoiceOption($0) }, default: words.firstIndex(of: def) ?? 0) }) { return words[i] }
        let shown = words.map { $0 == def ? $0.prefix(1).uppercased() + $0.dropFirst() : $0 }.joined(separator: "/")
        let all = words + also
        while true {
            write("\(question) [\(shown)]: ")
            guard let line = readLine()?.lowercased() else { write("\n"); return def }
            if line.isEmpty { return def }
            if let w = all.first(where: { $0.lowercased() == line }) { return w }
            if line == "y", let w = all.first(where: { $0 == "yes" }) { return w }
            if line == "n", let w = all.first(where: { $0 == "no" }) { return w }
            write("  one of: \(all.joined(separator: ", "))\n")
        }
    }

    /// 637 (owner: "pause at doctor step to allow review and continue"): wait for Enter before going on — `text` says what
    /// Enter does ("continue", "start"). Only with keys (a person at a terminal): typed answers — a script, or output
    /// that is not a terminal — go on at once, so no scripted run needs an extra line. Ctrl-C stops as anywhere else.
    public func pause(_ indent: String = "  ", _ text: String = "continue") {
        guard interactive else { return }
        let line = indent + Style.dim("Press ", colour: colour) + Style.key("Enter", colour: colour) + Style.dim(" to \(text)", colour: colour)
        _ = withKeys({ keyPause(line) })
    }

    private func keyPause(_ line: String) -> Bool {
        write("\u{1B}[?25l")
        let block = LiveBlock(write: write)
        block.draw([line])
        while true {
            guard let k = Key.read(channel!) else { block.clear(); return true }
            switch k {
            case .enter, .endOfInput: block.clear(); return true
            case .interrupt:
                block.clear()
                interrupted()
                return true
            default: break
            }
        }
    }

    /// Yes or no; Enter keeps `default`.
    public func yesNo(_ question: String, default def: Bool) -> Bool {
        guard interactive else { return def }
        if let v = withKeys({ keyYesNo(question, default: def) }) { return v }
        while true {
            write("\(question) [\(def ? "Y/n" : "y/N")]: ")
            guard let line = readLine()?.lowercased() else { write("\n"); return def }
            if line.isEmpty { return def }
            if ["y", "yes"].contains(line) { return true }
            if ["n", "no"].contains(line) { return false }
        }
    }

    // MARK: typed

    private func readLine() -> String? {
        guard let channel else { return nil }
        var buf = [UInt8]()
        while true {
            guard let c = channel.read(timeout: nil) else { return buf.isEmpty ? nil : String(decoding: buf, as: UTF8.self) }
            if c == 10 { break }
            buf.append(c)
            if buf.count > 4096 { break }
        }
        return String(decoding: buf, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: keys

    /// The question's own indentation (the callers indent questions inside a step) and its words.
    private func split(_ question: String) -> (indent: String, words: String) {
        let indent = String(question.prefix { $0 == " " })
        return (indent, String(question.dropFirst(indent.count)))
    }

    /// The question above a block, wrapped; written once (only the block under it is redrawn).
    private func ask(_ question: String) {
        let (indent, words) = split(question)
        for l in Layout.wrap(words, width: width - 1, indent: indent + "  ", first: indent) {
            let ind = String(l.prefix { $0 == " " })
            write(ind + Style.heading(String(l.dropFirst(ind.count)), colour: colour) + "\n")
        }
    }

    private func hint(_ indent: String, _ s: String) -> String { indent + "  " + Style.dim(s, colour: colour) }

    /// 637 (owner: a choice taller than the window redrew itself too far up): the rows a live block may use — the
    /// window's height less the question above it and a spare row — so a redraw never has to reach above the screen.
    private var blockRows: Int { max(5, (fixedHeight ?? Terminal.measureHeight()) - 3) }

    /// The options' lines (`groups[i]`: option i's label line and its detail lines) cut to `blockRows`: the selected one
    /// always shown, as many neighbours as fit around it, "↑ N more" / "↓ N more" where some are hidden, then `last`.
    private func windowed(_ groups: [[String]], sel: Int, indent: String, last: String) -> [String] {
        let budget = blockRows
        if groups.reduce(1, { $0 + $1.count }) <= budget { return groups.flatMap { $0 } + [last] }
        let room = budget - 3                                   // the hint and the two "more" lines
        var start = sel, end = sel, used = groups[sel].count
        var grew = true
        while grew {
            grew = false
            if end + 1 < groups.count, used + groups[end + 1].count <= room { end += 1; used += groups[end].count; grew = true }
            if start > 0, used + groups[start - 1].count <= room { start -= 1; used += groups[start].count; grew = true }
        }
        var out: [String] = []
        out.append(start > 0 ? indent + "  " + Style.dim("↑ \(start) more", colour: colour) : "")
        out += groups[start...end].flatMap { $0 }
        out.append(end < groups.count - 1 ? indent + "  " + Style.dim("↓ \(groups.count - 1 - end) more", colour: colour) : "")
        out.append(last)
        return out
    }

    private func keyChoice(_ question: String, _ options: [ChoiceOption], default def: Int) -> Int {
        let (indent, _) = split(question)
        ask(question)
        write("\u{1B}[?25l")
        let block = LiveBlock(write: write)
        let n = options.count
        var sel = min(max(0, def), n - 1)
        var digits = ""
        func lines() -> [String] {
            var groups: [[String]] = []
            for (i, o) in options.enumerated() {
                var out: [String] = []
                let here = i == sel
                let mark = here ? Style.accent("❯", colour: colour) : " "
                let num = Style.dim("\(i + 1).", colour: colour)
                let rec = i == def ? "  (recommended)" : ""
                let head = indent + "  " + "x" + " " + "\(i + 1)." + " "
                let label = Layout.fit(o.label, width - 1 - head.count - rec.count)
                out.append(indent + "  " + mark + " " + num + " " + (here ? Style.accent(label, colour: colour) : label) + Style.dim(rec, colour: colour))
                if let d = o.detail, !d.isEmpty {
                    let pad = String(repeating: " ", count: head.count)
                    out += Layout.wrap(d, width: width - 1, indent: pad).map { pad + Style.dim(String($0.dropFirst(pad.count)), colour: colour) }
                }
                groups.append(out)
            }
            return windowed(groups, sel: sel, indent: indent, last: hint(indent, "↑↓ move · Enter choose · 1–\(n)"))
        }
        func done(_ i: Int) -> Int {
            block.finish([indent + "  " + Style.ok("✓", colour: colour) + " " + Style.value(Layout.fit(options[i].label, width - 6 - indent.count), colour: colour)])
            return i
        }
        while true {
            block.draw(lines())
            guard let k = Key.read(channel!) else { return done(def) }
            if case .char(let c) = k, let d = c.wholeNumberValue, c.isASCII {
                digits += String(d)
                if let v = Int(digits), (1...n).contains(v) {
                    sel = v - 1
                    if v * 10 > n { return done(sel) }          // no longer number starts with it
                } else if d >= 1 && d <= n {
                    digits = String(d)
                    sel = d - 1
                    if d * 10 > n { return done(sel) }
                } else {
                    digits = ""
                }
                continue
            }
            digits = ""
            switch k {
            case .up, .char("k"): sel = (sel + n - 1) % n
            case .down, .char("j"), .tab: sel = (sel + 1) % n
            case .home: sel = 0
            case .end: sel = n - 1
            case .enter: return done(sel)
            case .endOfInput: return done(def)
            case .interrupt:
                block.clear()
                interrupted()
                return def
            default: break
            }
        }
    }

    private func keyChecklist(_ question: String, _ items: [(label: String, ticked: Bool)]) -> [Bool] {
        let (indent, _) = split(question)
        ask(question)
        write("\u{1B}[?25l")
        let block = LiveBlock(write: write)
        var ticks = items.map(\.ticked)
        var sel = 0
        let n = items.count
        func lines() -> [String] {
            let groups = items.enumerated().map { i, it -> [String] in
                let here = i == sel
                let mark = here ? Style.accent("❯", colour: colour) : " "
                let box = ticks[i] ? Style.ok("[x]", colour: colour) : "[ ]"
                let label = Layout.fit(it.label, width - 1 - indent.count - 8)
                return [indent + "  " + mark + " " + box + " " + (here ? Style.accent(label, colour: colour) : label)]
            }
            return windowed(groups, sel: sel, indent: indent, last: hint(indent, "↑↓ move · Space tick · Enter done"))
        }
        func done() -> [Bool] {
            let chosen = items.indices.filter { ticks[$0] }.map { items[$0].label }
            let said = chosen.isEmpty ? "none" : chosen.joined(separator: ", ")
            block.finish([indent + "  " + Style.ok("✓", colour: colour) + " " + Style.value(Layout.fit(said, width - 6 - indent.count), colour: colour)])
            return ticks
        }
        while true {
            block.draw(lines())
            guard let k = Key.read(channel!) else { return done() }
            switch k {
            case .up, .char("k"): sel = (sel + n - 1) % n
            case .down, .char("j"), .tab: sel = (sel + 1) % n
            case .space: ticks[sel].toggle()
            case .char(let c) where c.isASCII && (c.wholeNumberValue.map { (1...n).contains($0) } ?? false):
                sel = c.wholeNumberValue! - 1
                ticks[sel].toggle()
            case .enter, .endOfInput: return done()
            case .interrupt:
                block.clear()
                interrupted()
                return items.map(\.ticked)
            default: break
            }
        }
    }

    private func keyYesNo(_ question: String, default def: Bool) -> Bool {
        let (indent, words) = split(question)
        write("\u{1B}[?25l")
        let block = LiveBlock(write: write)
        var sel = def
        let q = indent + Style.heading(words, colour: colour)
        func toggles() -> String {
            let yes = sel ? Style.accent("❯ Yes", colour: colour) : Style.dim("  Yes", colour: colour)
            let no = !sel ? Style.accent("❯ No", colour: colour) : Style.dim("  No", colour: colour)
            return yes + "  " + no + Style.dim("   y/n · Enter", colour: colour)
        }
        // On the question's line when it fits; else the question above.
        let oneLine = Style.visibleWidth(q) + 2 + 22 < width
        if !oneLine { ask(question) }
        func done(_ v: Bool) -> Bool {
            let answer = Style.value(v ? "Yes" : "No", colour: colour)
            block.finish([oneLine ? q + "  " + answer : indent + "  " + Style.ok("✓", colour: colour) + " " + answer])
            return v
        }
        while true {
            block.draw([oneLine ? q + "  " + toggles() : indent + "  " + toggles()])
            guard let k = Key.read(channel!) else { return done(def) }
            switch k {
            case .char("y"), .char("Y"): return done(true)
            case .char("n"), .char("N"): return done(false)
            case .left, .right, .tab, .up, .down, .char("h"), .char("l"), .char("j"), .char("k"): sel.toggle()
            case .enter: return done(sel)
            case .endOfInput: return done(def)
            case .interrupt:
                block.clear()
                interrupted()
                return def
            default: break
            }
        }
    }

    private func keyText(_ question: String, default def: String, valid: (String) -> String?) -> String {
        let (indent, words) = split(question)
        let block = LiveBlock(write: write)
        let q = indent + Style.heading(words, colour: colour)
        // On the question's line when it leaves room to type; else the question above and the field under it.
        let oneLine = Style.visibleWidth(q) + 3 + 24 < width
        if !oneLine { ask(question) }
        let prefix = oneLine ? q + Style.accent(" › ", colour: colour) : indent + "  " + Style.accent("›", colour: colour) + " "
        let room = max(8, width - 1 - Style.visibleWidth(prefix))
        var buf = ""
        var error: String?
        func field() -> (line: String, col: Int) {
            if buf.isEmpty { return (prefix + Style.dim(Layout.fit(def, room), colour: colour), Style.visibleWidth(prefix)) }
            let shown = buf.count < room ? buf : "…" + String(buf.suffix(room - 2))
            return (prefix + shown, Style.visibleWidth(prefix) + shown.count)
        }
        func done(_ v: String) -> String {
            block.finish([prefix + Style.value(Layout.fit(v, room), colour: colour)])
            return v
        }
        while true {
            let f = field()
            var lines = [f.line]
            if let error { lines.append(indent + "    " + Style.bad(Layout.fit("✕ " + error, width - 5 - indent.count), colour: colour)) }
            block.draw(lines, cursor: (0, f.col))
            guard let k = Key.read(channel!) else { return done(def) }
            switch k {
            case .char(let c): buf.append(c); error = nil
            case .space: buf.append(" "); error = nil
            case .backspace: if !buf.isEmpty { buf.removeLast() }; error = nil
            case .clearLine: buf = ""; error = nil
            case .tab: if buf.isEmpty { buf = def }
            case .enter:
                let typed = buf.trimmingCharacters(in: .whitespaces)
                let v = typed.isEmpty ? def : typed
                if let why = valid(v) { error = why; continue }
                return done(v)
            case .endOfInput: if buf.isEmpty { return done(def) }
            case .interrupt:
                block.clear()
                interrupted()
                return def
            default: break
            }
        }
    }
}

/// A block of lines drawn under the cursor and redrawn in place: each redraw goes back to the block's first line and
/// erases to the end of the screen. Every line must fit one row (the callers cut and wrap them), so the block's height
/// in rows is its number of lines.
final class LiveBlock {
    private let write: (String) -> Void
    private var rows = 0
    private var cursorRow = 0

    init(write: @escaping (String) -> Void) { self.write = write }

    private func erase() -> String {
        guard rows > 0 else { return "" }
        return (cursorRow > 0 ? "\u{1B}[\(cursorRow)A" : "") + "\r\u{1B}[J"
    }

    /// Draw `lines` (replacing the last drawing); the cursor is left at the end of the last line, or at `cursor`.
    func draw(_ lines: [String], cursor: (row: Int, col: Int)? = nil) {
        var s = erase() + lines.joined(separator: "\n")
        rows = lines.count
        cursorRow = rows - 1
        if let c = cursor {
            let up = rows - 1 - c.row
            if up > 0 { s += "\u{1B}[\(up)A" }
            s += "\r" + (c.col > 0 ? "\u{1B}[\(c.col)C" : "")
            cursorRow = c.row
        }
        write(s)
    }

    /// The last drawing, gone.
    func clear() {
        write(erase())
        rows = 0
        cursorRow = 0
    }

    /// Replace the block with `lines` for good (they stay in the scrollback), and move under them.
    func finish(_ lines: [String]) {
        draw(lines)
        write("\n")
        rows = 0
        cursorRow = 0
    }
}
