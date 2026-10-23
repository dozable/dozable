// css-lint.swift — the dashboard's stylesheet rules, checked without a browser (run by `make test`).
//
// `Sources/DozableWeb/WebSource/app.css` is in cascade layers and built from tokens (CLAUDE.md, "The web layer"). This
// keeps the rules that each cost something to learn — the style guide's and the dashboard review's (selector cost) — so
// a change cannot quietly undo them:
//   1. no `:has(` — a state the page knows is a class the component sets (`.is-active`, `.has-title`, `.is-open`, …);
//      `:has()` is re-evaluated on every change below it and never fast-rejects (the allow-list is empty);
//   2. no universal right-most key (`*`, `> *`, `> :not(x)`, a lone `::placeholder`): every element would be a
//      candidate — give the children a class, or set the property on an inner wrapper. A key inside `:is()`/`:where()`
//      does not count (the engine cannot bucket a list); `:root`, `:focus` and `:focus-visible` have buckets of their own;
//   3. no `text-transform: uppercase` but on an access code's input (codes are typed in capitals);
//   4. no literal colour outside `:root` — every colour is a token defined once with light-dark();
//   5. no literal px spacing (padding, margin, gap) — the `--sp-*` scale or a role token (`--row-py`, `--page-px` …), so
//      the density setting reaches it. 1 px is a hairline or a border's overlap, not spacing, and is allowed;
//   6. no selector list defined twice in the same media context (merge the twins into the layer that wins);
//   7. no run of more than one blank line; every style rule inside an `@layer` block;
//   8. no comment that closes early (`changes/603-*/…` closed one and dropped the whole token block once).
//
// Usage: swift Scripts/css-lint.swift [--css PATH] [--spacing warn|error] [--verbose]   (--verbose lists the warnings)
import Foundation

var cssPath = "Sources/DozableWeb/WebSource/app.css"
var spacingIsError = false
var verbose = false
var args = CommandLine.arguments.dropFirst().makeIterator()
while let a = args.next() {
    switch a {
    case "--css": if let v = args.next() { cssPath = v }
    case "--spacing": spacingIsError = args.next() == "error"
    case "--verbose": verbose = true
    default: FileHandle.standardError.write(Data("css-lint: unknown argument \(a)\n".utf8)); exit(64)
    }
}

/// Selectors allowed a universal right-most key, each with why.
let universalAllowed: [String: String] = [
    "*": "the box-sizing reset in the base layer — the one rule every element needs",
]
/// Rules allowed `text-transform: uppercase`, each with why.
let uppercaseAllowed: [String: String] = [
    ".signin-code": "an access code's input: codes are typed in capitals",
    // Until the list pages' restyle (the review's T5) makes these two section labels sentence case — a visible change
    // that stage owns. Remove both lines with it.
    ".qt-sect h3": "Quick try's section labels — sentence case comes with the list pages' restyle",
    ".guide-sect h3": "the Guide's section labels — sentence case comes with the list pages' restyle",
]
/// Pseudo-classes with an engine bucket of their own: a compound of only these is not universal.
let bucketedPseudos: Set<String> = [":root", ":focus", ":focus-visible", ":link", ":visited"]
let spacingProperties: Set<String> = ["padding", "padding-top", "padding-right", "padding-bottom", "padding-left", "padding-block",
    "padding-inline", "padding-block-start", "padding-block-end", "padding-inline-start", "padding-inline-end", "margin", "margin-top",
    "margin-right", "margin-bottom", "margin-left", "margin-block", "margin-inline", "margin-block-start", "margin-block-end",
    "margin-inline-start", "margin-inline-end", "gap", "row-gap", "column-gap"]
/// CSS's named colours (and the system ones a stylesheet could reach for) — any of them as a word in a value is literal.
let namedColours: Set<String> = Set(("aliceblue antiquewhite aqua aquamarine azure beige bisque black blanchedalmond blue blueviolet brown " +
    "burlywood cadetblue chartreuse chocolate coral cornflowerblue cornsilk crimson cyan darkblue darkcyan darkgoldenrod darkgray " +
    "darkgreen darkgrey darkkhaki darkmagenta darkolivegreen darkorange darkorchid darkred darksalmon darkseagreen darkslateblue " +
    "darkslategray darkslategrey darkturquoise darkviolet deeppink deepskyblue dimgray dimgrey dodgerblue firebrick floralwhite " +
    "forestgreen fuchsia gainsboro ghostwhite gold goldenrod gray green greenyellow grey honeydew hotpink indianred indigo ivory khaki " +
    "lavender lavenderblush lawngreen lemonchiffon lightblue lightcoral lightcyan lightgoldenrodyellow lightgray lightgreen lightgrey " +
    "lightpink lightsalmon lightseagreen lightskyblue lightslategray lightslategrey lightsteelblue lightyellow lime limegreen linen " +
    "magenta maroon mediumaquamarine mediumblue mediumorchid mediumpurple mediumseagreen mediumslateblue mediumspringgreen " +
    "mediumturquoise mediumvioletred midnightblue mintcream mistyrose moccasin navajowhite navy oldlace olive olivedrab orange " +
    "orangered orchid palegoldenrod palegreen paleturquoise palevioletred papayawhip peachpuff peru pink plum powderblue purple " +
    "rebeccapurple red rosybrown royalblue saddlebrown salmon sandybrown seagreen seashell sienna silver skyblue slateblue slategray " +
    "slategrey snow springgreen steelblue tan teal thistle tomato turquoise violet wheat white whitesmoke yellow yellowgreen " +
    "canvas canvastext linktext visitedtext activetext buttonface buttontext buttonborder field fieldtext highlight highlighttext " +
    "selecteditem selecteditemtext mark marktext graytext accentcolor accentcolortext").split(separator: " ").map(String.init))

struct Rule {
    let line: Int
    let prelude: String          // the selector list as written (whitespace collapsed)
    let selectors: [String]
    let media: String            // the @media / @supports context ("" at the layer's top)
    let layer: String?
    let declarations: [(property: String, value: String, line: Int)]
}

guard let raw = try? String(contentsOfFile: cssPath, encoding: .utf8) else {
    FileHandle.standardError.write(Data("css-lint: cannot read \(cssPath)\n".utf8)); exit(66)
}
var problems: [String] = []
var warnings: [String] = []

// ── comments out, line numbers kept ──────────────────────────────────────────────────────────────────────────────────
let source = Array(raw.unicodeScalars)
var text: [Unicode.Scalar] = []
text.reserveCapacity(source.count)
var lineAt: [Int] = []           // the line of each scalar of `text`
do {
    var i = 0, line = 1
    while i < source.count {
        if source[i] == "/", i + 1 < source.count, source[i + 1] == "*" {
            var j = i + 2
            while j + 1 < source.count, !(source[j] == "*" && source[j + 1] == "/") { j += 1 }
            if j + 1 >= source.count { problems.append("line \(line): a comment is never closed"); break }
            for k in i...(j + 1) { let c = source[k]; text.append(c == "\n" ? "\n" : " "); lineAt.append(line); if c == "\n" { line += 1 } }
            i = j + 2
            continue
        }
        text.append(source[i]); lineAt.append(line)
        if source[i] == "\n" { line += 1 }
        i += 1
    }
}
func str(_ s: ArraySlice<Unicode.Scalar>) -> String { var o = String.UnicodeScalarView(); o.append(contentsOf: s); return String(o) }
func collapse(_ s: String) -> String { s.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).joined(separator: " ") }

/// Splits at `separator` where no (, [ or quote is open.
func splitTop(_ s: String, _ separator: Character) -> [String] {
    var parts: [String] = [], cur = "", depth = 0
    var quote: Character? = nil
    for c in s {
        if let q = quote { cur.append(c); if c == q { quote = nil }; continue }
        if c == "\"" || c == "'" { quote = c; cur.append(c); continue }
        if c == "(" || c == "[" { depth += 1 } else if c == ")" || c == "]" { depth -= 1 }
        if c == separator && depth == 0 { parts.append(cur); cur = "" } else { cur.append(c) }
    }
    parts.append(cur)
    return parts
}

// ── the rules, with their layer and media context ────────────────────────────────────────────────────────────────────
var rules: [Rule] = []
do {
    enum Context { case layer(String), media(String), other }
    var stack: [Context] = []
    var i = 0, preludeStart = 0
    func matchingBrace(_ from: Int) -> Int? {
        var depth = 0, k = from
        while k < text.count {
            if text[k] == "{" { depth += 1 } else if text[k] == "}" { depth -= 1; if depth == 0 { return k } }
            k += 1
        }
        return nil
    }
    while i < text.count {
        let c = text[i]
        if c == "{" {
            let prelude = collapse(str(text[preludeStart..<i]))
            let line = lineAt[min(preludeStart + (str(text[preludeStart..<i]).prefix(while: { $0 == " " || $0 == "\n" }).unicodeScalars.count), i)]
            if prelude.hasPrefix("@layer") {
                stack.append(.layer(collapse(String(prelude.dropFirst(6)))))
                i += 1; preludeStart = i; continue
            }
            if prelude.hasPrefix("@media") || prelude.hasPrefix("@supports") || prelude.hasPrefix("@container") {
                stack.append(.media(prelude)); i += 1; preludeStart = i; continue
            }
            if prelude.hasPrefix("@") {      // @keyframes, @font-face …: not style rules
                guard let end = matchingBrace(i) else { problems.append("line \(line): \(prelude) is never closed"); break }
                i = end + 1; preludeStart = i; continue
            }
            guard let end = matchingBrace(i) else { problems.append("line \(line): a rule is never closed"); break }
            let body = str(text[(i + 1)..<end])
            if body.contains("{") { problems.append("line \(line): a nested rule in \(prelude) — not used in this sheet") }
            if prelude.contains("*/") || body.contains("*/") {
                problems.append("line \(line): a comment closed early (\"*/\" left in the sheet) — a comment never contains */")
            }
            var decls: [(String, String, Int)] = []
            var offset = i + 1
            for d in splitTop(body, ";") {
                let n = d.unicodeScalars.count
                defer { offset += n + 1 }
                let parts = d.split(separator: ":", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { if !collapse(d).isEmpty { problems.append("line \(lineAt[offset]): not a declaration: \(collapse(d))") }; continue }
                let lead = d.unicodeScalars.prefix(while: { $0 == " " || $0 == "\n" || $0 == "\t" }).count
                decls.append((collapse(parts[0]).lowercased(), collapse(parts[1]), lineAt[min(offset + lead, text.count - 1)]))
            }
            var layer: String? = nil, media: [String] = []
            for s in stack { switch s { case .layer(let l): layer = l; case .media(let m): media.append(m); case .other: break } }
            rules.append(Rule(line: line, prelude: prelude, selectors: splitTop(prelude, ",").map(collapse), media: media.joined(separator: " "),
                              layer: layer, declarations: decls))
            i = end + 1; preludeStart = i; continue
        }
        if c == ";" { preludeStart = i + 1 }           // an at-statement (@layer a, b;)
        if c == "}" { if !stack.isEmpty { stack.removeLast() }; preludeStart = i + 1 }
        i += 1
    }
}

// ── the selector checks ──────────────────────────────────────────────────────────────────────────────────────────────
/// The right-most compound of one complex selector.
func rightmostCompound(_ sel: String) -> String {
    var depth = 0, cut = sel.endIndex
    var quote: Character? = nil
    var idx = sel.endIndex
    while idx > sel.startIndex {
        let p = sel.index(before: idx)
        let c = sel[p]
        if let q = quote { if c == q { quote = nil } } else if c == "\"" || c == "'" { quote = c }
        else if c == ")" || c == "]" { depth += 1 } else if c == "(" || c == "[" { depth -= 1 }
        else if depth == 0 && (c == " " || c == ">" || c == "+" || c == "~") { cut = idx; break }
        idx = p
        if idx == sel.startIndex { cut = sel.startIndex }
    }
    return String(sel[cut...]).trimmingCharacters(in: .whitespaces)
}
/// The compound with its pseudo-classes and pseudo-elements taken out (functional ones whole), and the plain
/// pseudo-classes it had.
func keysOf(_ compound: String) -> (rest: String, pseudos: [String]) {
    var rest = "", pseudos: [String] = []
    var s = Substring(compound)
    while let c = s.first {
        if c == ":" {
            var name = ":"
            s = s.dropFirst()
            if s.first == ":" { name += ":"; s = s.dropFirst() }
            while let d = s.first, d.isLetter || d.isNumber || d == "-" || d == "_" { name.append(d); s = s.dropFirst() }
            if s.first == "(" {
                var depth = 0
                while let d = s.first { s = s.dropFirst(); if d == "(" { depth += 1 } else if d == ")" { depth -= 1; if depth == 0 { break } } }
            } else if !name.hasPrefix("::") { pseudos.append(name) }
            continue
        }
        if c == "[" {     // an attribute selector is a key; keep it whole
            var depth = 0
            while let d = s.first { rest.append(d); s = s.dropFirst(); if d == "[" { depth += 1 } else if d == "]" { depth -= 1; if depth == 0 { break } } }
            continue
        }
        rest.append(c); s = s.dropFirst()
    }
    return (rest, pseudos)
}
for r in rules {
    for sel in r.selectors {
        if sel.contains(":has(") { problems.append("line \(r.line): \(sel) — no :has() (a state class the component sets instead)") }
        if universalAllowed[sel] != nil { continue }
        let (rest, pseudos) = keysOf(rightmostCompound(sel))
        let keyed = rest.contains(".") || rest.contains("#") || rest.contains("[") || (rest.first.map { $0.isLetter } ?? false)
        if !keyed && !(rest.isEmpty || rest == "*" ? pseudos.contains(where: { bucketedPseudos.contains($0) }) : false) {
            problems.append("line \(r.line): \(sel) — a universal right-most key (every element is a candidate): give it a class or a tag")
        }
    }
    let isRoot = r.selectors.allSatisfy { $0.hasPrefix(":root") }
    for d in r.declarations {
        if d.property == "text-transform" && d.value.lowercased().contains("uppercase") && !r.selectors.allSatisfy({ uppercaseAllowed[$0] != nil }) {
            problems.append("line \(d.line): \(r.prelude) — no capitals-only labels (text-transform: uppercase is for an access code's input)")
        }
        if !isRoot && !d.property.hasPrefix("--") {
            let v = d.value
            let hex = v.range(of: "#[0-9a-fA-F]{3,8}(?![0-9a-zA-Z_-])", options: .regularExpression) != nil
            let fn = v.range(of: "(?<![a-z-])(rgba?|hsla?|hwb|lab|lch|oklab|oklch|color)\\(", options: [.regularExpression, .caseInsensitive]) != nil
            let words = v.lowercased().split(whereSeparator: { !($0.isLetter) }).map(String.init)
            let named = words.first(where: { namedColours.contains($0) })
            if hex || fn || named != nil {
                problems.append("line \(d.line): \(r.prelude) { \(d.property): \(v) } — a literal colour outside :root (use a token)")
            }
        }
        if spacingProperties.contains(d.property) {
            let literal = d.value.range(of: "(?<![0-9a-zA-Z.-])-?([2-9]|[1-9][0-9]+|[0-9]*\\.[0-9]+)px", options: .regularExpression)
            if let lit = literal {
                let msg = "line \(d.line): \(r.prelude) { \(d.property): \(d.value) } — literal px spacing \(d.value[lit]) (a --sp-* or role token)"
                if spacingIsError { problems.append(msg) } else { warnings.append(msg) }
            }
        }
    }
}

// ── twins, blank runs, rules outside a layer ─────────────────────────────────────────────────────────────────────────
var seen: [String: Int] = [:]
for r in rules {
    let key = r.media + " | " + r.selectors.joined(separator: ", ")
    if let first = seen[key] { problems.append("line \(r.line): \(r.prelude) is defined twice (first at line \(first)) — merge them") }
    else { seen[key] = r.line }
    if r.layer == nil { problems.append("line \(r.line): \(r.prelude) is outside every @layer block (a new rule goes in its layer's block)") }
}
do {
    var blank = 0, line = 0
    for l in raw.split(separator: "\n", omittingEmptySubsequences: false) {
        line += 1
        if l.trimmingCharacters(in: .whitespaces).isEmpty { blank += 1; if blank == 2 { problems.append("line \(line): more than one blank line in a row") } }
        else { blank = 0 }
    }
}

if verbose { for w in warnings { print("warning: \(w)") } }
else if !warnings.isEmpty { print("css-lint: \(warnings.count) warnings — swift Scripts/css-lint.swift --verbose lists them") }
for p in problems { print("error: \(p)") }
print("css-lint: \(rules.count) rules in \(cssPath) — \(problems.count) problem\(problems.count == 1 ? "" : "s"), \(warnings.count) warning\(warnings.count == 1 ? "" : "s")")
exit(problems.isEmpty ? 0 : 1)
