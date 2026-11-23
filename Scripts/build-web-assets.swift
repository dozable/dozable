#!/usr/bin/env swift
// build-web-assets.swift — `doz ui`'s front end compiler (590; the technique of DeckStack 503's
// Scripts/build-web-assets.swift). Dependency-free and deterministic: no Node, no package manager,
// no network.
//
//   Sources/DozableWeb/WebSource/{index.html, app.css, app.js}   the page's OWN code (what people edit)
//   Sources/DozableWeb/WebSource/{offline.html, offline.css, offline.js}  605: the page shown while doz ui is down
//   Sources/DozableWeb/WebSource/{sw.js, app.webmanifest}        605: the service worker (served at /sw.js) and the
//                                                               web app manifest (hashed, like the css/js)
//   Sources/DozableWeb/WebSource/icons/                          605: the app icons — SVG masters + PNGs rendered
//                                                               from them, admitted by icons/PROVENANCE.json
//   Sources/DozableWeb/WebSource/vendor/<package>/               591: VENDORED third-party files, each
//                                                               byte-identical to its registry tarball
//                                                               and pinned in that directory's VENDOR.json —
//                                                               742: or a peer's build at one commit, admitted by
//                                                               that build's PIN (PeerVendor), loaded lazily only
//                                                               through the lazy-import table
//   Sources/DozableWeb/Resources/Web/                           what ships (COMMITTED, generated):
//       index.html                  referencing the hashed names
//       assets/app-<sha16>.css      content-hashed
//       assets/app-<sha16>.js
//       assets/<publicName>-<sha16>.{js,wasm}   vendored, content-hashed, bytes unchanged
//       licences/<package>-<file>   each vendored package's licence (in the bundle, not served)
//       manifest.json               every served file's public path, type, cache policy, sha256, class
//
//   swift Scripts/build-web-assets.swift           regenerate Resources/Web (make web-assets)
//   swift Scripts/build-web-assets.swift --check   fail when Resources/Web is not exactly what the
//                                                  sources produce (make web-assets-check — run by
//                                                  make test and Scripts/audit.sh)
//
// Two classes of file, two sets of rules (591.01-DESIGN.md §3):
//   · the page's own code must be what the CSP and the XSS rule allow: no inline script, inline
//     style or event-handler attribute in index.html, no external URL anywhere, no innerHTML in app.js;
//   · a vendored file is admitted by PROVENANCE, not content: its sha256 must equal VENDOR.json's
//     pin, its licence must be on the allowlist, and no unlisted file may sit in its directory. Its
//     bytes are never rewritten. The page's rules are not applied to it (minified third-party code
//     would fail them) and are not loosened for the page's own files either.
import CryptoKit
import Foundation

enum Failure: Error, CustomStringConvertible {
    case usage, source(String), stale(String)
    var description: String {
        switch self {
        case .usage: "usage: build-web-assets.swift [--check]"
        case .source(let s), .stale(let s): s
        }
    }
}

struct Asset: Codable {
    let publicPath: String
    let resourcePath: String
    let mimeType: String
    let sha256: String
    let cachePolicy: String
    /// `page` (this package's own code) or `vendor` (a pinned third-party file).
    let `class`: String
}

struct Manifest: Codable {
    let version: Int
    let assets: [Asset]
}

/// `WebSource/vendor/<package>/VENDOR.json`.
struct Vendor: Decodable {
    struct File: Decodable {
        let file: String
        let fromTarball: String
        let sha256: String
        /// `script` (served as JavaScript), `wasm` (served as application/wasm), `licence` (bundled only),
        /// `icon` (593: an SVG icon, served only inside the package's generated sprite).
        let serve: String
        let publicName: String?
        /// What index.html writes for it (rewritten to the hashed public path).
        let indexReference: String?
    }
    /// 593: the package's `icon` files, as ONE generated SVG sprite (a `<symbol id="NAME">` per
    /// file, holding that file's drawing elements byte for byte) — `assets/<publicName>-<sha16>.svg`.
    struct Sprite: Decodable {
        let publicName: String
        let indexReference: String
    }
    let sprite: Sprite?
    let package: String
    let version: String
    let tarball: String
    let tarballIntegrity: String
    let tarballSha256: String
    let licence: String
    let licenceFile: String
    let files: [File]
}

/// 742: a package vendored BY PEER COMMIT (`"provenance": "peer-commit"` — code that comes from no registry): the files of
/// one commit's build, byte for byte, admitted by that build's own `PIN` (`sha256  path` per line) and the commit's full
/// hash. Every listed file's sha256 is VENDOR.json's AND its PIN line's; the PIN itself is pinned by `pinSha256`; the
/// PIN may name files not vendored; nothing unlisted may sit in the directory (sub-folders allowed, each part a plain
/// name). Serve kinds: `module` (an ES module loaded ONLY by the one lazy `import()` the compiler's table allows — flat
/// at `assets/<publicName>-<sha16>.js`, and only with no import of its own), `reference` (kept in source, never shipped)
/// and `licence` (bundled as `licences/<package>-<path with / as ->`). Each component's licence on the allowlist, its
/// file listed `licence`; a notice or index file (`licence` too) is named by a component's `notices` or the package's
/// `licenceIndex`. `publish` is `flat` (one file per module) or (744) `tree`: every shipped file at
/// `assets/vendor-<package>-<pin16>/<path>` (its layout kept, at most one sub-folder), so the build's own relative imports,
/// worker and style URLs resolve unrewritten — admitted only by the structural checks (`treeScriptCheck`, `treeStyleCheck`);
/// kinds `module`, `worker` (JavaScript), `style` (CSS) and `font` (TrueType), besides `reference` and `licence`.
struct PeerVendor: Decodable {
    struct Component: Decodable {
        let name: String; let version: String; let licence: String; let licenceFile: String
        let notices: [String]?
    }
    struct File: Decodable {
        let file: String
        let sha256: String
        let serve: String
        let publicName: String?
        /// What the one lazy `import('…')` names for it (rewritten to the hashed public path).
        let lazyReference: String?
    }
    let package: String
    let provenance: String
    let commit: String
    let source: String
    let pinFile: String
    let pinSha256: String
    let publish: String
    let licenceIndex: String?
    let components: [Component]
    let files: [File]
}

/// 744: what a tree's script may hold — checked on every `module` and `worker`, whatever its size. Each static `import` /
/// `export … from` and each `import("…")` a literal `./` path (no `..`) to a listed module of the tree; no bare, absolute,
/// URL or computed `import(`; `import.meta` only as `new URL("<literal>", import.meta.url)` naming a listed worker or style;
/// `new Worker(` only over such a URL (no `blob:` or `data:` worker); no `eval(`, `Function(` or string timer. The tree's
/// own text is never rewritten.
func treeScriptCheck(_ file: String, _ raw: String, sha: String, pkg: String, modules: Set<String>, urlTargets: Set<String>) throws {
    let at = "vendor/\(pkg)/\(file)"
    var text = raw
    // Each allowance (the compiler's table, bound to this exact file) occurs exactly once; its text is then not checked.
    for a in vendorAllowances[sha] ?? [] {
        guard text.components(separatedBy: a.text).count == 2 else { throw Failure.source("\(at): an allowance of the compiler's table is not in it exactly once") }
        if let n = a.names { guard urlTargets.contains(try treeResolve(n, from: file, at)) else { throw Failure.source("\(at): an allowance names \(n), which the tree does not list") } }
        text = text.replacingOccurrences(of: a.text, with: " ")
    }
    func scan(_ pattern: String, _ body: (NSTextCheckingResult, NSString) throws -> Void) throws {
        let re = try NSRegularExpression(pattern: pattern)
        let ns = text as NSString
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) { try body(m, ns) }
    }
    for (pattern, what) in [(#"\beval\s*\("#, "eval("), (#"\bFunction\s*\("#, "the Function constructor"),
                            (#"\bset(?:Timeout|Interval)\s*\(\s*["'`]"#, "a string timer"), (#"\bimportScripts\s*\("#, "an importScripts call")]
    where text.range(of: pattern, options: .regularExpression) != nil {
        throw Failure.source("\(at) holds \(what) — a vendored tree runs only its own listed files")
    }
    // new URL("<literal>", import.meta.url): a listed worker or style. Then no other import.meta, and every Worker over one.
    let urlForm = #"new\s+URL\(\s*(["'])([^"'\n]*)\1\s*,\s*import\.meta\.url\s*\)"#
    try scan(urlForm) { m, ns in
        let lit = ns.substring(with: m.range(at: 2))
        guard urlTargets.contains(try treeResolve(lit, from: file, at)) else { throw Failure.source("\(at): new URL(\"\(lit)\", import.meta.url) names no listed worker or style") }
    }
    let workerFree = text.replacingOccurrences(of: #"new\s+Worker\(\s*"# + urlForm, with: " ", options: .regularExpression)
    if workerFree.range(of: #"\bnew\s+Worker\s*\("#, options: .regularExpression) != nil {
        throw Failure.source("\(at): new Worker( over anything but new URL(\"<listed worker>\", import.meta.url) — no blob:, data: or computed worker")
    }
    if text.replacingOccurrences(of: urlForm, with: " ", options: .regularExpression).range(of: #"\bimport\s*\.\s*meta\b"#, options: .regularExpression) != nil {
        throw Failure.source("\(at): import.meta only as new URL(\"<literal>\", import.meta.url)")
    }
    // import("./x.js"): a literal, a listed module.
    let dynamicForm = #"\bimport\s*\(\s*(["'])([^"'\n]*)\1\s*\)"#
    try scan(dynamicForm) { m, ns in
        let lit = ns.substring(with: m.range(at: 2))
        guard lit.hasPrefix("./") else { throw Failure.source("\(at): import(\"\(lit)\") — a vendored module imports only by './…', a file of its tree") }
        guard modules.contains(try treeResolve(lit, from: file, at)) else { throw Failure.source("\(at): import(\"\(lit)\") names no listed module of the tree") }
    }
    if text.replacingOccurrences(of: dynamicForm, with: " ", options: .regularExpression).range(of: #"\bimport\s*\("#, options: .regularExpression) != nil {
        throw Failure.source("\(at): a computed import( — only import(\"./<listed module>\")")
    }
    // Static imports and re-exports, at a statement's start.
    try scan(#"(?:^|[;}\n])\s*(?:import\s*(?:[\w$*{][^;"'`]*?\bfrom\s*)?|export\s*(?:\*(?:\s*as\s*[\w$]+)?|\{[^}]*\})\s*from\s*)(["'])([^"'\n]*)\1"#) { m, ns in
        let spec = ns.substring(with: m.range(at: 2))
        guard spec.hasPrefix("./") else { throw Failure.source("\(at) imports '\(spec)' — a vendored module imports only by './…', a file of its tree") }
        guard modules.contains(try treeResolve(spec, from: file, at)) else { throw Failure.source("\(at) imports '\(spec)', which is no listed module of the tree") }
    }
}

/// 744: a tree's stylesheet: `@import` and `url()` only to a listed file of the tree, a `data:` URL or a `#id`.
func treeStyleCheck(_ file: String, _ text: String, pkg: String, listed: Set<String>) throws {
    let at = "vendor/\(pkg)/\(file)"
    let re = try NSRegularExpression(pattern: #"@import\s*(?:url\(\s*)?(["']?)([^"')\s;]*)\1|url\(\s*(["']?)([^"')]*)\3\s*\)"#)
    let ns = text as NSString
    for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
        let isImport = m.range(at: 2).location != NSNotFound
        let ref = ns.substring(with: isImport ? m.range(at: 2) : m.range(at: 4)).trimmingCharacters(in: .whitespaces)
        if !isImport, ref.hasPrefix("data:") || ref.hasPrefix("#") { continue }
        guard listed.contains(try treeResolve(ref, from: file, at)) else { throw Failure.source("\(at): \(isImport ? "@import" : "url()") of \(ref), which is no listed file of the tree") }
    }
}

/// A tree's relative reference (`./x`, `x`, `./monaco/x` — never `..`, `/`, a scheme or a query) → its path in the tree.
func treeResolve(_ ref: String, from file: String, _ at: String) throws -> String {
    let dir = file.split(separator: "/").dropLast().map(String.init)
    let r = ref.hasPrefix("./") ? String(ref.dropFirst(2)) : ref
    let parts = r.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    guard !ref.hasPrefix("/"), !ref.contains(":"), !ref.contains("?"), !ref.contains("#"), parts.allSatisfy(isPlainName) else {
        throw Failure.source("\(at) names '\(ref)' — a vendored tree refers only to its own files, by a plain relative path")
    }
    return (dir + parts).joined(separator: "/")
}

/// 744: sites in a vendored tree's file the structural checks would refuse that are known inert, each bound to the file's
/// exact bytes (its sha256) and present exactly once — a new build is a new entry here, on purpose. `names`: the listed
/// worker or style the allowed text names.
let vendorAllowances: [String: [(text: String, names: String?, why: String)]] = [
    // space-chunk-J6HC5EPZ.js (the text view, 0.8.0): the worker's URL is held in a variable two words before it.
    "f67ebf409dc62b3b87d72b8575c29973eb43387e8e26bb9a07cf07cbba84c356": [
        (#"F="monaco/editor.worker.js",k=new Set;self.MonacoEnvironment={getWorker:()=>{let a=new Worker(new URL(F,import.meta.url))"#,
         "monaco/editor.worker.js", "the listed worker, named by a literal the worker's URL is built from"),
    ],
    // monaco/monaco.js (monaco-editor 0.57.0, as the space editor's build makes it).
    "eb27774481b147571cec23d8ceda42b9f53b1fdfdfb25b43167a846dbb476435": [
        (#"esmModuleLocationBundler:()=>new URL("../../common/services/editorWebWorkerMain.js",import.meta.url)"#, nil,
         "never called: the host gives MonacoEnvironment.getWorker, so Monaco never asks a bundler for a worker URL"),
        (#"referenced by "new URL('...?esm', import.meta.url)""#, nil, "words in an error message"),
        (#"return new Worker(oAe?oAe.createScriptURL(o):o,{...e,type:"module"})"#, nil,
         "reached only with a blob: URL (it throws otherwise), and this build's blob maker throws before it"),
    ],
]

/// 742: the ONE way a module loads code lazily — `import('LITERAL')` (single quotes, exactly that form), exactly once per
/// literal, only in the module this table names, the literal a peer-commit `module`'s `lazyReference` (rewritten to its
/// public path). Any other `import(` — in a comment, a template, a variable, another module — is refused, and so is a
/// `'/vendor/…'` string anywhere else in the modules. 744: a `.css` literal is a `style`'s lazyReference, written exactly
/// once as `'LITERAL'` (the page links it). A new entry is a change to this table, on purpose.
let lazyImports: [String: [String]] = [
    "core/space-pictures.js": ["/vendor/space-editor/space-render.js"],
    "views/space-page.js": ["/vendor/space-editor/space-core.js", "/vendor/space-editor/space-editor.css"],
]
/// The form a lazy literal takes in its module.
func lazyForm(_ lit: String) -> String { lit.hasSuffix(".css") ? "'\(lit)'" : "import('\(lit)')" }

/// Licences a vendored file may carry (SPDX). Anything else needs this list changed on purpose.
let allowedLicences: Set<String> = ["MIT", "BSD-2-Clause", "BSD-3-Clause", "Apache-2.0", "ISC"]

func sha256(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

/// 593: an icon file's drawing, checked: an optional `<!-- @license … -->`, then ONE `<svg …
/// viewBox="0 0 24 24" …>` whose children are only path / circle / ellipse / line / polyline /
/// polygon / rect elements with geometry attributes — no script, style, link, event handler or
/// reference of any kind. Returns the children as they are in the file.
func iconBody(_ file: String, _ text: String) throws -> String {
    var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if t.hasPrefix("<!--") {
        guard let end = t.range(of: "-->") else { throw Failure.source("\(file): an unclosed comment") }
        guard t[..<end.lowerBound].contains("@license") else { throw Failure.source("\(file): only the licence comment is expected") }
        t = String(t[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard t.hasPrefix("<svg"), t.hasSuffix("</svg>"), let open = t.range(of: ">") else { throw Failure.source("\(file): not one <svg> element") }
    guard t[..<open.lowerBound].contains("viewBox=\"0 0 24 24\"") else { throw Failure.source("\(file): the viewBox is not 0 0 24 24") }
    let body = String(t[open.upperBound..<t.index(t.endIndex, offsetBy: -6)]).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !body.isEmpty else { throw Failure.source("\(file): an empty drawing") }
    let allowedTags: Set<String> = ["path", "circle", "ellipse", "line", "polyline", "polygon", "rect"]
    let allowedAttributes: Set<String> = ["d", "cx", "cy", "r", "rx", "ry", "x", "y", "x1", "y1", "x2", "y2", "width", "height", "points"]
    let tag = try NSRegularExpression(pattern: #"<\s*(/?)\s*([A-Za-z:-]+)([^<>]*)>"#)
    // (635: a name may hold a digit after its first letter — x1 y1 x2 y2 of a <line>, which this never admitted before.)
    let attr = try NSRegularExpression(pattern: #"([A-Za-z:_-][A-Za-z0-9:_-]*)\s*=\s*"([^"]*)""#)
    let ns = body as NSString
    var covered = 0
    for m in tag.matches(in: body, range: NSRange(location: 0, length: ns.length)) {
        guard ns.substring(with: NSRange(location: covered, length: m.range.location - covered)).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure.source("\(file): text outside an element")
        }
        covered = m.range.location + m.range.length
        let name = ns.substring(with: m.range(at: 2))
        guard allowedTags.contains(name) else { throw Failure.source("\(file): <\(name)> is not an allowed drawing element") }
        let attrs = ns.substring(with: m.range(at: 3)).replacingOccurrences(of: "/", with: " ")
        let an = attrs as NSString
        // What the matched attributes do not cover must be blank (by position — `x="2"` is also inside `rx="2"`).
        var rest = ""
        var at = 0
        for a in attr.matches(in: attrs, range: NSRange(location: 0, length: an.length)) {
            rest += an.substring(with: NSRange(location: at, length: a.range.location - at))
            at = a.range.location + a.range.length
            let key = an.substring(with: a.range(at: 1)), value = an.substring(with: a.range(at: 2))
            // A dot drawn filled (key-round's) takes the icon's colour: currentColor, or none.
            if key == "fill", value == "currentColor" || value == "none" { continue }
            guard allowedAttributes.contains(key) else { throw Failure.source("\(file): attribute \(key) is not allowed") }
            guard value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || " .,-".contains($0)) }) else {
                throw Failure.source("\(file): \(key) holds more than geometry")
            }
        }
        rest += an.substring(from: at)
        guard rest.trimmingCharacters(in: .whitespaces).isEmpty else { throw Failure.source("\(file): an attribute that is not name=\"value\"") }
    }
    guard ns.substring(from: covered).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure.source("\(file): text after the drawing") }
    return body
}

/// 605: an app icon master (`icons/*.svg`): ONE `<svg>` holding only rect / circle / ellipse / path /
/// polygon / g elements with geometry, literal colours (#rgb / #rrggbb, or none) and stroke widths —
/// no text (no font), script, style, link, image, reference or event handler.
func appIconCheck(_ file: String, _ text: String) throws {
    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard t.hasPrefix("<svg"), t.hasSuffix("</svg>") else { throw Failure.source("\(file): not one <svg> element") }
    let allowedTags: Set<String> = ["svg", "rect", "circle", "ellipse", "path", "polygon", "g"]
    let allowedAttributes: Set<String> = ["xmlns", "viewBox", "width", "height", "x", "y", "rx", "ry", "cx", "cy", "r", "d", "points",
                                          "fill", "stroke", "stroke-width", "opacity", "fill-opacity", "transform"]
    let tag = try NSRegularExpression(pattern: #"<\s*(/?)\s*([A-Za-z:-]+)([^<>]*)>"#)
    let attr = try NSRegularExpression(pattern: #"([A-Za-z:_-]+)\s*=\s*"([^"]*)""#)
    let ns = t as NSString
    var covered = 0
    for m in tag.matches(in: t, range: NSRange(location: 0, length: ns.length)) {
        guard ns.substring(with: NSRange(location: covered, length: m.range.location - covered)).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure.source("\(file): text outside an element")
        }
        covered = m.range.location + m.range.length
        let name = ns.substring(with: m.range(at: 2))
        guard allowedTags.contains(name) else { throw Failure.source("\(file): <\(name)> is not allowed in an app icon") }
        let attrs = ns.substring(with: m.range(at: 3))
        let an = attrs as NSString
        var rest = "", at = 0
        for a in attr.matches(in: attrs, range: NSRange(location: 0, length: an.length)) {
            rest += an.substring(with: NSRange(location: at, length: a.range.location - at))
            at = a.range.location + a.range.length
            let key = an.substring(with: a.range(at: 1)), value = an.substring(with: a.range(at: 2))
            guard allowedAttributes.contains(key) else { throw Failure.source("\(file): attribute \(key) is not allowed") }
            switch key {
            case "xmlns": guard value == "http://www.w3.org/2000/svg" else { throw Failure.source("\(file): xmlns is the SVG namespace") }
            case "fill", "stroke":
                guard value == "none" || value.range(of: #"^#([0-9a-fA-F]{3}|[0-9a-fA-F]{6})$"#, options: .regularExpression) != nil else {
                    throw Failure.source("\(file): \(key) is a literal colour or none")
                }
            default:
                guard value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || " .,-()".contains($0)) }) else {
                    throw Failure.source("\(file): \(key) holds more than geometry")
                }
            }
        }
        rest += an.substring(from: at)
        guard rest.replacingOccurrences(of: "/", with: "").trimmingCharacters(in: .whitespaces).isEmpty else {
            throw Failure.source("\(file): an attribute that is not name=\"value\"")
        }
    }
    guard ns.substring(from: covered).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure.source("\(file): text after the drawing") }
}

/// 607: the page script's native ES modules — `WebSource/app.js` (the entry, loaded `type="module"`) and every
/// `WebSource/app/<layer>/<name>.js`. The graph is CLOSED and checked here:
///   · an import is a static `import … from './x.js'` / `import './x.js'` (or `export … from`) with a RELATIVE
///     specifier naming a module that exists under app/ — no bare or absolute specifier, no dynamic import();
///   · layers: dom < core < components < views < app.js — a module imports from its own layer or below, never up;
///   · no cycle; no module the entry does not reach;
///   · every `upcall('name')` (core/hooks.js: a call UP the layers) is provided by app.js's `provide({ … })`,
///     and app.js provides nothing that nobody upcalls.
struct ModuleGraph {
    static let layers = ["dom": 0, "core": 1, "components": 2, "views": 3]
    static let entryLayer = 4
    var files: [String: String] = [:]          // "dom/h.js" → its text (paths relative to app/)
    var imports: [String: [String]] = [:]      // a module → the modules it imports
    var entryImports: [String: [String]] = [:]  // an entry (app.js, chat.js) → the modules it imports
    var closure: [String: Set<String>] = [:]   // an entry → every module it reaches
    var order: [String] = []                   // dependencies first (each module after everything it imports)

    static let importPattern = try! NSRegularExpression(
        pattern: #"(?m)^[ \t]*(?:import|export)\b[^'";=()]*?\bfrom[ \t]*(['"])([^'"\n]*)\1|^[ \t]*import[ \t]*(['"])([^'"\n]*)\3"#)

    /// The specifiers a module's text imports, with their ranges.
    static func specifiers(_ text: String) -> [(spec: String, range: NSRange)] {
        let ns = text as NSString
        return importPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
            let r = m.range(at: 2).location != NSNotFound ? m.range(at: 2) : m.range(at: 4)
            return (ns.substring(with: r), r)
        }
    }

    /// A specifier resolved against the importing file (nil = the entry, in WebSource/) to a path relative to app/.
    static func resolve(_ spec: String, from: String?, file: String) throws -> String {
        guard spec.hasPrefix("./") || spec.hasPrefix("../") else {
            throw Failure.source("\(file) imports '\(spec)' — a module imports only by a relative specifier ('./x.js', '../core/x.js')")
        }
        guard spec.hasSuffix(".js") else { throw Failure.source("\(file) imports '\(spec)' — a module specifier names a .js file") }
        var parts = from.map { ["app"] + $0.split(separator: "/").dropLast().map(String.init) } ?? []
        for p in spec.split(separator: "/", omittingEmptySubsequences: false).map(String.init) {
            switch p {
            case ".": continue
            case "..": guard !parts.isEmpty else { throw Failure.source("\(file) imports '\(spec)', outside WebSource") }; parts.removeLast()
            case "": throw Failure.source("\(file) imports '\(spec)' — not a plain path")
            default: parts.append(p)
            }
        }
        guard parts.first == "app", parts.count >= 3 else { throw Failure.source("\(file) imports '\(spec)', which is not a module under app/") }
        return parts.dropFirst().joined(separator: "/")
    }

    static func layer(_ rel: String) -> Int { layers[String(rel.split(separator: "/").first ?? "")] ?? -1 }

    /// The text with every import specifier rewritten to its module's hashed name (same relative path).
    func rewrite(_ text: String, from: String?, hashed: [String: String]) throws -> String {
        let ns = NSMutableString(string: text)
        for (spec, range) in Self.specifiers(text).reversed() {
            let target = try Self.resolve(spec, from: from, file: from.map { "app/" + $0 } ?? "app.js")
            guard let h = hashed[target] else { throw Failure.source("app/\(target) is not hashed before \(from ?? "app.js")") }
            let base = String(target.split(separator: "/").last!), hbase = String(h.split(separator: "/").last!)
            ns.replaceCharacters(in: range, with: String(spec.dropLast(base.count)) + hbase)
        }
        return ns as String
    }
}

/// 745: one graph, several ENTRIES (`app.js` the dashboard's, `chat.js` the chat window's) — each in WebSource/, layer 4;
/// "unreached" is a module no entry reaches; the calls up the layers are checked per entry over its own closure.
func loadModules(sources: URL, entries: [String: String]) throws -> ModuleGraph {
    let fm = FileManager.default
    var g = ModuleGraph()
    let root = sources.appendingPathComponent("app")
    if let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey]) {
        let base = root.resolvingSymlinksInPath().path + "/"
        while let u = e.nextObject() as? URL {
            let path = u.resolvingSymlinksInPath().path
            guard path.hasPrefix(base) else { throw Failure.source("unexpected path \(path)") }
            let rel = String(path.dropFirst(base.count))
            if u.lastPathComponent == ".DS_Store" { continue }
            if (try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                guard !rel.contains("/"), ModuleGraph.layers[rel] != nil else {
                    throw Failure.source("app/\(rel): a module lives in app/dom, app/core, app/components or app/views")
                }
                continue
            }
            let comps = rel.split(separator: "/")
            guard comps.count == 2, ModuleGraph.layers[String(comps[0])] != nil, rel.hasSuffix(".js"),
                  comps[1].dropLast(3).allSatisfy({ ($0.isLowercase && $0.isASCII) || $0.isNumber || $0 == "-" }) else {
                throw Failure.source("app/\(rel): only app/<dom|core|components|views>/<a-z0-9->.js lives in app/")
            }
            guard let d = try? Data(contentsOf: u), let t = String(data: d, encoding: .utf8) else { throw Failure.source("app/\(rel) is not UTF-8") }
            g.files[rel] = t
        }
    }
    let dynamic = try NSRegularExpression(pattern: #"\bimport\s*\("#)
    let vendorString = try NSRegularExpression(pattern: #"['"`]/vendor/"#)
    func checked(_ text: String, _ from: String?, entry: String = "app.js") throws -> [String] {
        let file = from.map { "app/" + $0 } ?? entry
        // 742: the lazy literals this module may hold (the compiler's table) — each exactly once, in exactly that form.
        var rest = text
        for lit in lazyImports[from ?? ""] ?? [] {
            let form = lazyForm(lit)
            guard text.components(separatedBy: form).count == 2 else {
                throw Failure.source("\(file) must load \(lit) exactly once, as \(form) (the compiler's lazy-import table)")
            }
            rest = rest.replacingOccurrences(of: form, with: "")
        }
        let restRange = NSRange(location: 0, length: (rest as NSString).length)
        if dynamic.firstMatch(in: rest, range: restRange) != nil {
            throw Failure.source(lazyImports[from ?? ""] == nil
                ? "\(file) uses import() — the module graph is static (the compiler hashes every module; the one lazy import is its table's)"
                : "\(file) uses import() beyond its one lazy literal (the compiler's lazy-import table)")
        }
        if vendorString.firstMatch(in: rest, range: restRange) != nil {
            throw Failure.source("\(file) names a /vendor/ path — vendored code is loaded only by the compiler's lazy-import table")
        }
        var out: [String] = []
        for (spec, _) in ModuleGraph.specifiers(text) {
            let target = try ModuleGraph.resolve(spec, from: from, file: file)
            guard g.files[target] != nil else { throw Failure.source("\(file) imports '\(spec)', which does not exist") }
            let to = ModuleGraph.layer(target), at = from.map(ModuleGraph.layer) ?? ModuleGraph.entryLayer
            guard to <= at else {
                throw Failure.source("\(file) imports app/\(target) — up a layer (dom < core < components < views < app.js); call up with upcall('name') (core/hooks.js)")
            }
            if !out.contains(target) { out.append(target) }
        }
        return out
    }
    for (name, text) in entries { g.entryImports[name] = try checked(text, nil, entry: name) }
    for (rel, text) in g.files { g.imports[rel] = try checked(text, rel) }
    // No cycle; dependencies first; every module reached from the entry.
    var state: [String: Int] = [:]          // 1 visiting, 2 done
    var stack: [String] = []
    func visit(_ m: String) throws {
        if state[m] == 2 { return }
        if state[m] == 1 {
            let cycle = stack[stack.firstIndex(of: m)!...] + [m]
            throw Failure.source("an import cycle: \(cycle.map { "app/" + $0 }.joined(separator: " → ")) — break it with upcall('name') (core/hooks.js)")
        }
        state[m] = 1; stack.append(m)
        for d in g.imports[m] ?? [] { try visit(d) }
        stack.removeLast(); state[m] = 2
        g.order.append(m)
    }
    for name in entries.keys.sorted() { for m in g.entryImports[name] ?? [] { try visit(m) } }
    let unreached = Set(g.files.keys).subtracting(g.order)
    guard unreached.isEmpty else { throw Failure.source("app.js never loads \(unreached.sorted().map { "app/" + $0 }) — a module nothing imports is a mistake") }
    // Each entry's closure: the modules it reaches.
    for name in entries.keys {
        var seen = Set<String>(), queue = g.entryImports[name] ?? []
        while let m = queue.popLast() { if seen.insert(m).inserted { queue += g.imports[m] ?? [] } }
        g.closure[name] = seen
    }
    // 745: the chat window loads only chat's code — no view of the dashboard's but chat's own.
    if let c = g.closure["chat.js"], let v = c.filter({ $0.hasPrefix("views/") && !$0.hasPrefix("views/chat") }).sorted().first {
        throw Failure.source("chat.js reaches app/\(v) — the chat window loads only chat's code")
    }
    // Calls up the layers, per entry over its closure: each upcall('x') its modules make provided by that entry's
    // provide({…}), and nothing provided that none of them upcalls.
    let upcall = try NSRegularExpression(pattern: #"\bupcall\(\s*'([A-Za-z_$][\w$]*)'\s*\)"#)
    var upcalls: [String: [String]] = [:]          // a module → the names it upcalls
    let lineComment = try NSRegularExpression(pattern: #"(?m)^[ \t]*//[^\n]*$"#)
    for (rel, raw) in g.files {
        let text = lineComment.stringByReplacingMatches(in: raw, range: NSRange(location: 0, length: (raw as NSString).length), withTemplate: "")
        upcalls[rel] = upcall.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)).map { (text as NSString).substring(with: $0.range(at: 1)) }
    }
    for (name, entry) in entries.sorted(by: { $0.key < $1.key }) {
        var upcalled: [String: String] = [:]
        for rel in g.closure[name] ?? [] { for n in upcalls[rel] ?? [] { upcalled[n] = "app/" + rel } }
        var provided = Set<String>()
        if let m = try NSRegularExpression(pattern: #"\bprovide\(\{([^}]*)\}\)"#).firstMatch(in: entry, range: NSRange(location: 0, length: (entry as NSString).length)) {
            let list = (entry as NSString).substring(with: m.range(at: 1))
            provided = Set(list.components(separatedBy: CharacterSet(charactersIn: ", \n\t")).filter { !$0.isEmpty })
        }
        for (n, file) in upcalled.sorted(by: { $0.key < $1.key }) where !provided.contains(n) {
            throw Failure.source("\(file) calls upcall('\(n)'), which \(name) does not provide")
        }
        if let extra = provided.subtracting(upcalled.keys).sorted().first {
            throw Failure.source("\(name) provides \(extra), which no module it loads upcalls")
        }
    }
    return g
}

func isPlainName(_ s: String) -> Bool {
    !s.isEmpty && s != "." && s != ".." && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || ".-_".contains($0)) }
}

func main() throws {
    let args = Array(CommandLine.arguments.dropFirst())
    guard args.isEmpty || args == ["--check"] else { throw Failure.usage }
    let check = args == ["--check"]
    let package = URL(fileURLWithPath: #filePath).standardizedFileURL.deletingLastPathComponent().deletingLastPathComponent()
    let sources = package.appendingPathComponent("Sources/DozableWeb/WebSource")
    let output = package.appendingPathComponent("Sources/DozableWeb/Resources/Web")
    let fm = FileManager.default

    // The page's own documents, each with its one stylesheet and one script (591: the terminal
    // engine's sandboxed frame is the second document).
    // `page`: a document a person navigates to (the service worker's PAGES — its navigation fallback).
    let documents: [(file: String, publicPath: String, css: String, js: String, page: Bool)] = [
        ("index.html", "/", "app", "app", true),
        ("terminal.html", "/terminal-frame", "frame", "frame", false),
        // 605: what the service worker shows while doz ui is not running (an installed app opened, a reload).
        ("offline.html", "/offline", "offline", "offline", false),
        // 745: the chat window — the dashboard's stylesheet, its own module entry (chat.js: only chat's modules).
        ("chat.html", "/chat", "app", "chat", true),
    ]
    /// 745: the module entries — each document's script that is an ES module entry, with its own closure.
    let moduleEntries = ["app", "chat"]
    // Nothing but those files, the service worker, the manifest, icons/, vendor/ and (607) app/ — the page
    // script's modules — lives in WebSource: a stray file is a mistake.
    let top = Set((try? fm.contentsOfDirectory(atPath: sources.path)) ?? []).subtracting([".DS_Store"])
    let known = Set(documents.flatMap { [$0.file, $0.css + ".css", $0.js + ".js"] } + ["vendor", "icons", "sw.js", "app.webmanifest", "app"])
    let unexpectedTop = top.subtracting(known)
    guard unexpectedTop.isEmpty else { throw Failure.source("unexpected files in WebSource: \(unexpectedTop.sorted())") }

    func read(_ name: String) throws -> Data {
        guard let d = try? Data(contentsOf: sources.appendingPathComponent(name)) else { throw Failure.source("missing \(sources.path)/\(name)") }
        guard String(data: d, encoding: .utf8) != nil else { throw Failure.source("\(name) is not UTF-8") }
        return d
    }

    // ── The page's own code: CSP conformance (`script-src 'self'; style-src 'self'`), nothing inline,
    //    nothing external, no innerHTML.
    var docText: [String: String] = [:]
    var styles: [String: Data] = [:], scripts: [String: Data] = [:]
    let inline: [(String, String)] = [
        ("<script>", "an inline <script>"), ("<style", "a <style> element"), (" style=", "a style= attribute"),
        ("javascript:", "a javascript: URL"),
    ]
    for d in documents {
        let text = String(decoding: try read(d.file), as: UTF8.self)
        guard text.contains("href=\"/\(d.css).css\""), text.contains("src=\"/\(d.js).js\"") else {
            throw Failure.source("\(d.file) must reference /\(d.css).css and /\(d.js).js exactly")
        }
        for (needle, what) in inline where text.lowercased().contains(needle) {
            throw Failure.source("\(d.file) has \(what) — the CSP refuses it")
        }
        if text.range(of: #"\son[a-z]+\s*="#, options: .regularExpression) != nil {
            throw Failure.source("\(d.file) has an event-handler attribute (on…=) — the CSP refuses it; use addEventListener")
        }
        docText[d.file] = text
        styles[d.css] = try read(d.css + ".css")
        scripts[d.js] = try read(d.js + ".js")
    }
    // 605: the service worker is page code (the same rules) — and a worker loads nothing else: no
    // importScripts, no eval, no Function constructor. The manifest is page text too (no external URL).
    let swText = String(decoding: try read("sw.js"), as: UTF8.self)
    for (needle, what) in [("importScripts", "importScripts"), ("eval(", "eval"), ("Function(", "the Function constructor"), ("innerHTML", "innerHTML")]
    where swText.contains(needle) {
        throw Failure.source("sw.js uses \(what) — the service worker runs only its own code")
    }
    var manifestText = String(decoding: try read("app.webmanifest"), as: UTF8.self)
    guard (try? JSONSerialization.jsonObject(with: Data(manifestText.utf8))) is [String: Any] else {
        throw Failure.source("app.webmanifest is not a JSON object")
    }
    // 607: the page script's modules (WebSource/app/**) — every one is page code under the same rules.
    let modules = try loadModules(sources: sources, entries: Dictionary(uniqueKeysWithValues: moduleEntries.map { ($0 + ".js", String(decoding: scripts[$0]!, as: UTF8.self)) }))
    for d in documents where moduleEntries.contains(d.js) {
        guard modules.files.isEmpty || docText[d.file]!.contains("<script type=\"module\" src=\"/\(d.js).js\"></script>") else {
            throw Failure.source("\(d.file) must load \(d.js).js as a module: <script type=\"module\" src=\"/\(d.js).js\"></script>")
        }
    }
    let pageFiles = docText.map { ($0.key, $0.value) } + styles.map { ($0.key + ".css", String(decoding: $0.value, as: UTF8.self)) }
        + scripts.map { ($0.key + ".js", String(decoding: $0.value, as: UTF8.self)) } + [("sw.js", swText), ("app.webmanifest", manifestText)]
        + modules.files.map { ("app/" + $0.key, $0.value) }
    for (name, text) in pageFiles {
        // 593: the SVG namespace is a name, not a URL anything loads (createElementNS).
        let scanned = text.replacingOccurrences(of: "\"http://www.w3.org/2000/svg\"", with: "\"svg-ns\"")
            .replacingOccurrences(of: "'http://www.w3.org/2000/svg'", with: "'svg-ns'")
        if scanned.range(of: #"(https?:)?//[a-z0-9.-]+\.[a-z]{2,}/"#, options: [.regularExpression, .caseInsensitive]) != nil {
            throw Failure.source("\(name) references an external URL — the UI loads nothing from outside its own origin")
        }
        if name.hasSuffix(".js"), text.contains("innerHTML") || text.contains("insertAdjacentHTML") {
            throw Failure.source("\(name) uses innerHTML — render with textContent only (590.01-DESIGN.md: sandbox-controlled text is untrusted)")
        }
    }

    let immutable = "public, max-age=31536000, immutable"
    var expected: [String: Data] = [:]
    var assets: [Asset] = []

    // ── Vendored packages (591): provenance, not content.
    let vendorRoot = sources.appendingPathComponent("vendor")
    let packages = ((try? fm.contentsOfDirectory(atPath: vendorRoot.path)) ?? []).filter { $0 != ".DS_Store" }.sorted()
    var lazyTargets: [String: String] = [:]      // 742: a lazyReference → its hashed public path
    /// 742: a package vendored by peer commit (`PeerVendor` says what is checked).
    func admitPeerCommit(_ pkg: String, dir: URL, _ vd: Data) throws {
        let v: PeerVendor
        do { v = try JSONDecoder().decode(PeerVendor.self, from: vd) } catch { throw Failure.source("vendor/\(pkg)/VENDOR.json: \(error)") }
        guard v.package == pkg else { throw Failure.source("vendor/\(pkg)/VENDOR.json names package \(v.package)") }
        guard v.commit.count == 40, v.commit.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
            throw Failure.source("vendor/\(pkg): the commit must be the full 40-character hash")
        }
        guard v.pinFile == "PIN", let pin = try? Data(contentsOf: dir.appendingPathComponent("PIN")) else { throw Failure.source("vendor/\(pkg): its PIN is missing") }
        guard sha256(pin) == v.pinSha256 else { throw Failure.source("vendor/\(pkg)/PIN is not the pinned PIN (sha256 differs from VENDOR.json)") }
        var pinned: [String: String] = [:]
        for line in String(decoding: pin, as: UTF8.self).split(separator: "\n") where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[0].count == 64 else { throw Failure.source("vendor/\(pkg)/PIN: a line is not \"sha256  path\"") }
            pinned[parts[1].trimmingCharacters(in: .whitespaces)] = parts[0]
        }
        guard v.publish == "flat" || v.publish == "tree" else { throw Failure.source("vendor/\(pkg): publish must be flat or tree") }
        let tree = v.publish == "tree"
        // 744: a tree is served under its PIN's sha, so every file of one build shares one folder.
        let treeRoot = "assets/vendor-\(pkg)-\(v.pinSha256.prefix(16))/"
        let treeModules = Set(v.files.filter { $0.serve == "module" }.map(\.file))
        let treeURLs = Set(v.files.filter { $0.serve == "worker" || $0.serve == "style" }.map(\.file))
        let treeShipped = Set(v.files.filter { ["module", "worker", "style", "font"].contains($0.serve) }.map(\.file))
        // Every file present (recursively) is listed, but VENDOR.json and the PIN.
        var present = Set<String>()
        let base = dir.resolvingSymlinksInPath().path + "/"
        if let e = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) {
            while let u = e.nextObject() as? URL {
                guard u.lastPathComponent != ".DS_Store", (try? u.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
                present.insert(String(u.resolvingSymlinksInPath().path.dropFirst(base.count)))
            }
        }
        let listed = Set(v.files.map(\.file))
        let unlisted = present.subtracting(listed).subtracting(["VENDOR.json", "PIN"])
        guard unlisted.isEmpty else { throw Failure.source("vendor/\(pkg) holds files VENDOR.json does not pin: \(unlisted.sorted())") }
        for c in v.components {
            guard allowedLicences.contains(c.licence) else { throw Failure.source("vendor/\(pkg): \(c.name)'s licence \(c.licence) is not on the allowlist") }
            for lf in [c.licenceFile] + (c.notices ?? []) {
                guard v.files.contains(where: { $0.file == lf && $0.serve == "licence" }) else {
                    throw Failure.source("vendor/\(pkg): \(c.name)'s licence file \(lf) must be listed (serve: licence)")
                }
            }
        }
        if let ix = v.licenceIndex, !v.files.contains(where: { $0.file == ix && $0.serve == "licence" }) {
            throw Failure.source("vendor/\(pkg): the licence index \(ix) must be listed (serve: licence)")
        }
        guard !v.components.isEmpty else { throw Failure.source("vendor/\(pkg): no component — each needs its licence") }
        for f in v.files {
            guard f.file.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ isPlainName(String($0)) }) else {
                throw Failure.source("vendor/\(pkg): bad file name \(f.file)")
            }
            if tree, treeShipped.contains(f.file) {
                guard f.file.split(separator: "/").count <= 2 else { throw Failure.source("vendor/\(pkg)/\(f.file): a tree keeps at most one sub-folder") }
            }
            guard f.lazyReference == nil || f.serve == "module" || (tree && f.serve == "style") else {
                throw Failure.source("vendor/\(pkg)/\(f.file): only a module (or a tree's style) has a lazyReference")
            }
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(f.file)) else { throw Failure.source("vendor/\(pkg)/\(f.file) is missing") }
            guard sha256(data) == f.sha256 else {
                throw Failure.source("vendor/\(pkg)/\(f.file) is not the pinned file (sha256 differs from VENDOR.json) — vendored bytes are never edited")
            }
            guard pinned[f.file] == f.sha256 else { throw Failure.source("vendor/\(pkg)/\(f.file) is not the file its PIN names") }
            switch f.serve {
            case "licence":
                guard v.components.contains(where: { $0.licenceFile == f.file || ($0.notices ?? []).contains(f.file) }) || v.licenceIndex == f.file else {
                    throw Failure.source("vendor/\(pkg)/\(f.file): a licence or notice no component names (licenceFile, notices) and not the licenceIndex")
                }
                expected["licences/\(pkg)-\(f.file.replacingOccurrences(of: "/", with: "-"))"] = data
            case "reference":
                continue
            case let kind where tree && ["module", "worker", "style", "font"].contains(kind):
                let text = String(decoding: data, as: UTF8.self)
                if f.serve == "module" || f.serve == "worker" {
                    guard f.file.hasSuffix(".js") else { throw Failure.source("vendor/\(pkg)/\(f.file): a module or worker is a .js file") }
                    try treeScriptCheck(f.file, text, sha: f.sha256, pkg: pkg, modules: treeModules, urlTargets: treeURLs)
                } else if f.serve == "style" {
                    guard f.file.hasSuffix(".css") else { throw Failure.source("vendor/\(pkg)/\(f.file): a style is a .css file") }
                    try treeStyleCheck(f.file, text, pkg: pkg, listed: treeShipped)
                } else {
                    guard f.file.hasSuffix(".ttf"), data.starts(with: [0x00, 0x01, 0x00, 0x00]) else { throw Failure.source("vendor/\(pkg)/\(f.file): a font is a TrueType .ttf") }
                }
                if let ref = f.lazyReference {
                    guard ref == "/vendor/\(pkg)/\(f.file)", !f.file.contains("/") else { throw Failure.source("vendor/\(pkg)/\(f.file): its lazyReference is /vendor/\(pkg)/\(f.file)") }
                }
                let path = treeRoot + f.file
                if let ref = f.lazyReference { lazyTargets[ref] = "/" + path }
                expected[path] = data
                let type = ["module": "application/javascript; charset=utf-8", "worker": "application/javascript; charset=utf-8",
                            "style": "text/css; charset=utf-8", "font": "font/ttf"][f.serve]!
                assets.append(Asset(publicPath: "/" + path, resourcePath: path, mimeType: type, sha256: f.sha256, cachePolicy: immutable, class: "vendor"))
            case "module":
                guard let name = f.publicName, isPlainName(name), name.hasPrefix("vendor-"), f.file.hasSuffix(".js"),
                      let ref = f.lazyReference, ref == "/vendor/\(pkg)/\(f.file)" else {
                    throw Failure.source("vendor/\(pkg)/\(f.file): a module needs publicName (vendor-…) and lazyReference /vendor/\(pkg)/\(f.file)")
                }
                // Flat: one file, so it may import nothing (no static import, re-export, import() or import.meta).
                let text = String(decoding: data, as: UTF8.self)
                for (pattern, what) in [(#"(?:^|[;}\n])\s*import\b"#, "an import"), (#"\bexport\s*(?:\*|\{[^}]*\})\s*from\b"#, "a re-export"),
                                        (#"\bimport\s*\("#, "an import()"), (#"\bimport\.meta\b"#, "import.meta")]
                where text.range(of: pattern, options: .regularExpression) != nil {
                    throw Failure.source("vendor/\(pkg)/\(f.file) holds \(what) — a flat module loads nothing else")
                }
                let path = "assets/\(name)-\(f.sha256.prefix(16)).js"
                lazyTargets[ref] = "/" + path
                expected[path] = data
                assets.append(Asset(publicPath: "/" + path, resourcePath: path, mimeType: "application/javascript; charset=utf-8",
                                    sha256: f.sha256, cachePolicy: immutable, class: "vendor"))
            default:
                throw Failure.source(tree ? "vendor/\(pkg)/\(f.file): serve must be module, worker, style, font, reference or licence"
                                          : "vendor/\(pkg)/\(f.file): serve must be module, reference or licence (a flat package)")
            }
        }
    }
    for pkg in packages {
        guard isPlainName(pkg) else { throw Failure.source("vendor/\(pkg): not a plain directory name") }
        let dir = vendorRoot.appendingPathComponent(pkg)
        guard let vd = try? Data(contentsOf: dir.appendingPathComponent("VENDOR.json")) else {
            throw Failure.source("vendor/\(pkg) has no VENDOR.json — a vendored file is admitted only with its pin")
        }
        struct Probe: Decodable { let provenance: String? }
        if (try? JSONDecoder().decode(Probe.self, from: vd))?.provenance == "peer-commit" {
            try admitPeerCommit(pkg, dir: dir, vd)
            continue
        }
        let v: Vendor
        do { v = try JSONDecoder().decode(Vendor.self, from: vd) } catch { throw Failure.source("vendor/\(pkg)/VENDOR.json: \(error)") }
        guard v.package == pkg else { throw Failure.source("vendor/\(pkg)/VENDOR.json names package \(v.package)") }
        guard allowedLicences.contains(v.licence) else { throw Failure.source("vendor/\(pkg): licence \(v.licence) is not on the allowlist") }
        guard v.tarball.hasPrefix("https://registry.npmjs.org/"), v.tarballIntegrity.hasPrefix("sha512-"), v.tarballSha256.count == 64 else {
            throw Failure.source("vendor/\(pkg): the tarball must be the registry's, with its sha512 integrity and sha256")
        }
        guard v.files.contains(where: { $0.file == v.licenceFile && $0.serve == "licence" }) else {
            throw Failure.source("vendor/\(pkg): the licence file must be listed (serve: licence)")
        }
        var symbols: [String] = []
        let listed = Set(v.files.map(\.file))
        let present = Set(((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0 != ".DS_Store" })
        let unlisted = present.subtracting(listed).subtracting(["VENDOR.json"])
        guard unlisted.isEmpty else { throw Failure.source("vendor/\(pkg) holds files VENDOR.json does not pin: \(unlisted.sorted())") }
        for f in v.files {
            guard isPlainName(f.file) else { throw Failure.source("vendor/\(pkg): bad file name \(f.file)") }
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(f.file)) else { throw Failure.source("vendor/\(pkg)/\(f.file) is missing") }
            guard sha256(data) == f.sha256 else {
                throw Failure.source("vendor/\(pkg)/\(f.file) is not the pinned file (sha256 differs from VENDOR.json) — vendored bytes are never edited")
            }
            switch f.serve {
            case "licence":
                expected["licences/\(pkg)-\(f.file)"] = data
            case "script", "wasm":
                guard let name = f.publicName, isPlainName(name), name.hasPrefix("vendor-"), let ref = f.indexReference, ref.hasPrefix("/vendor/") else {
                    throw Failure.source("vendor/\(pkg)/\(f.file): a served file needs publicName (vendor-…) and indexReference (/vendor/…)")
                }
                guard docText.values.contains(where: { $0.contains("\"\(ref)\"") }) else { throw Failure.source("no document references \(ref)") }
                let ext = f.serve == "script" ? "js" : "wasm"
                let path = "assets/\(name)-\(f.sha256.prefix(16)).\(ext)"
                for (k, v) in docText { docText[k] = v.replacingOccurrences(of: "\"\(ref)\"", with: "\"/\(path)\"") }
                expected[path] = data
                assets.append(Asset(publicPath: "/" + path, resourcePath: path,
                                    mimeType: f.serve == "script" ? "application/javascript; charset=utf-8" : "application/wasm",
                                    sha256: f.sha256, cachePolicy: immutable, class: "vendor"))
            case "icon":
                guard f.file.hasSuffix(".svg"), v.sprite != nil else { throw Failure.source("vendor/\(pkg)/\(f.file): an icon is an .svg of a package with a sprite") }
                let id = String(f.file.dropLast(4))
                guard id.allSatisfy({ ($0.isLowercase && $0.isASCII) || $0.isNumber || $0 == "-" }) else { throw Failure.source("vendor/\(pkg)/\(f.file): an icon name is a-z 0-9 -") }
                symbols.append("<symbol id=\"\(id)\" viewBox=\"0 0 24 24\">\(try iconBody("vendor/\(pkg)/\(f.file)", String(decoding: data, as: UTF8.self)))</symbol>")
            default:
                throw Failure.source("vendor/\(pkg)/\(f.file): serve must be script, wasm, icon or licence")
            }
        }
        if let s = v.sprite {
            guard !symbols.isEmpty, isPlainName(s.publicName), s.publicName.hasPrefix("vendor-"), s.indexReference.hasPrefix("/vendor/") else {
                throw Failure.source("vendor/\(pkg): a sprite needs icons, a publicName (vendor-…) and an indexReference (/vendor/…)")
            }
            guard docText.values.contains(where: { $0.contains("\"\(s.indexReference)\"") }) else { throw Failure.source("no document references \(s.indexReference)") }
            // Generated from the pinned files (sorted by name), deterministic: a changed pin is a changed sprite.
            let sprite = Data(("<svg xmlns=\"http://www.w3.org/2000/svg\">\n<!-- \(v.package) \(v.version) (\(v.licence)), generated by Scripts/build-web-assets.swift from the files VENDOR.json pins -->\n"
                + symbols.sorted().joined(separator: "\n") + "\n</svg>\n").utf8)
            let digest = sha256(sprite)
            let path = "assets/\(s.publicName)-\(digest.prefix(16)).svg"
            for (k, t) in docText { docText[k] = t.replacingOccurrences(of: "\"\(s.indexReference)\"", with: "\"/\(path)\"") }
            expected[path] = sprite
            assets.append(Asset(publicPath: "/" + path, resourcePath: path, mimeType: "image/svg+xml", sha256: digest, cachePolicy: immutable, class: "vendor"))
        }
    }
    for (file, text) in docText {
        if let stray = text.range(of: #""/vendor/[^"]*""#, options: .regularExpression) {
            throw Failure.source("\(file) references \(text[stray]), which no VENDOR.json serves")
        }
    }

    // ── 605: the app icons — admitted by PROVENANCE (the PNGs were rendered from the SVG masters by
    //    Scripts/render-web-icons.mjs; a master or a PNG that is not the recorded one fails), the SVGs
    //    by their content (drawing elements and literal colours only). `refs` maps what the sources
    //    write ("/icons/icon-192.png") to the hashed public path.
    var refs: [String: String] = [:]
    let iconDir = sources.appendingPathComponent("icons")
    struct Provenance: Decodable {
        struct Source: Decodable { let file: String; let served: Bool; let sha256: String }
        struct Rendered: Decodable { let file: String; let from: String; let size: Int; let sha256: String }
        let renderer: String
        let sources: [Source]
        let files: [Rendered]
    }
    guard let pd = try? Data(contentsOf: iconDir.appendingPathComponent("PROVENANCE.json")) else { throw Failure.source("icons/ has no PROVENANCE.json") }
    let prov: Provenance
    do { prov = try JSONDecoder().decode(Provenance.self, from: pd) } catch { throw Failure.source("icons/PROVENANCE.json: \(error)") }
    let iconListed = Set(prov.sources.map(\.file) + prov.files.map(\.file) + ["PROVENANCE.json"])
    let iconPresent = Set(((try? fm.contentsOfDirectory(atPath: iconDir.path)) ?? []).filter { $0 != ".DS_Store" })
    guard iconPresent == iconListed else {
        throw Failure.source("icons/ holds \(iconPresent.subtracting(iconListed).sorted()) unlisted / misses \(iconListed.subtracting(iconPresent).sorted()) — PROVENANCE.json lists every file")
    }
    for src in prov.sources {
        guard isPlainName(src.file), src.file.hasPrefix("icon"), src.file.hasSuffix(".svg") else { throw Failure.source("icons/\(src.file): a master is icon….svg") }
        let data = try Data(contentsOf: iconDir.appendingPathComponent(src.file))
        guard sha256(data) == src.sha256 else {
            throw Failure.source("icons/\(src.file) is not the master the PNGs were rendered from — run node Scripts/render-web-icons.mjs")
        }
        try appIconCheck("icons/\(src.file)", String(decoding: data, as: UTF8.self))
        guard src.served else { continue }
        let path = "assets/\(src.file.dropLast(4))-\(sha256(data).prefix(16)).svg"
        refs["/icons/\(src.file)"] = "/" + path
        expected[path] = data
        assets.append(Asset(publicPath: "/" + path, resourcePath: path, mimeType: "image/svg+xml", sha256: sha256(data), cachePolicy: immutable, class: "page"))
    }
    for f in prov.files {
        guard isPlainName(f.file), f.file.hasPrefix("icon-"), f.file.hasSuffix(".png"), prov.sources.contains(where: { $0.file == f.from }) else {
            throw Failure.source("icons/\(f.file): a rendered icon is icon-….png from a listed master")
        }
        let data = try Data(contentsOf: iconDir.appendingPathComponent(f.file))
        guard sha256(data) == f.sha256 else { throw Failure.source("icons/\(f.file) is not the PNG PROVENANCE.json records — run node Scripts/render-web-icons.mjs") }
        // A PNG (its signature) of exactly the recorded size (IHDR: width and height, big-endian).
        let b = [UInt8](data)
        let be = { (i: Int) in Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3]) }
        guard b.count > 24, b.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]), be(16) == f.size, be(20) == f.size else {
            throw Failure.source("icons/\(f.file) is not a \(f.size)×\(f.size) PNG")
        }
        let path = "assets/\(f.file.dropLast(4))-\(f.sha256.prefix(16)).png"
        refs["/icons/\(f.file)"] = "/" + path
        expected[path] = data
        assets.append(Asset(publicPath: "/" + path, resourcePath: path, mimeType: "image/png", sha256: f.sha256, cachePolicy: immutable, class: "page"))
    }
    func rewrite(_ text: String, _ what: String) throws -> String {
        var t = text
        for (k, v) in refs { t = t.replacingOccurrences(of: "\"\(k)\"", with: "\"\(v)\"") }
        if let stray = t.range(of: #""/(icons/[^"]*|app\.webmanifest)""#, options: .regularExpression) {
            throw Failure.source("\(what) references \(t[stray]), which nothing serves")
        }
        return t
    }
    // ── 605: the web app manifest — its icons rewritten, then content-hashed like the css/js (its `id` is
    //    fixed, so a new hashed URL is the same app).
    manifestText = try rewrite(manifestText, "app.webmanifest")
    let manifestData = Data(manifestText.utf8)
    let manifestPath = "assets/app-\(sha256(manifestData).prefix(16)).webmanifest"
    expected[manifestPath] = manifestData
    assets.append(Asset(publicPath: "/" + manifestPath, resourcePath: manifestPath, mimeType: "application/manifest+json",
                        sha256: sha256(manifestData), cachePolicy: immutable, class: "page"))
    refs["/app.webmanifest"] = "/" + manifestPath
    for (k, t) in docText { docText[k] = try rewrite(t, k) }

    // ── 607: the modules, dependencies first: each one's import specifiers are rewritten to its dependencies'
    //    hashed names (relative, so they resolve beside it), then it is hashed itself — and so is the entry, so
    //    app-<h>.js changes whenever any module does (605's `hello.script` still names "this build's page").
    var moduleHashed: [String: String] = [:]          // "dom/h.js" → "dom/h-<sha16>.js"
    // 742: the lazy imports' literals → their modules' hashed paths (every literal a declared lazyReference; every
    // lazyReference loaded by the table — a vendored module nothing loads is a mistake).
    for (rel, lits) in lazyImports {
        guard modules.files[rel] != nil else { throw Failure.source("the lazy-import table names app/\(rel), which does not exist") }
        for lit in lits where lazyTargets[lit] == nil { throw Failure.source("app/\(rel) loads \(lit), which no VENDOR.json declares as a lazyReference") }
    }
    if let unused = Set(lazyTargets.keys).subtracting(lazyImports.values.flatMap { $0 }).sorted().first {
        throw Failure.source("\(unused) is vendored as a module, but the lazy-import table loads it nowhere")
    }
    for rel in modules.order {
        var text = try modules.rewrite(modules.files[rel]!, from: rel, hashed: moduleHashed)
        for lit in lazyImports[rel] ?? [] { text = text.replacingOccurrences(of: lazyForm(lit), with: lazyForm(lit).replacingOccurrences(of: lit, with: lazyTargets[lit]!)) }
        let data = Data(text.utf8)
        let name = "\(rel.dropLast(3))-\(sha256(data).prefix(16)).js"
        moduleHashed[rel] = name
        let path = "assets/app/" + name
        expected[path] = data
        assets.append(Asset(publicPath: "/" + path, resourcePath: path, mimeType: "application/javascript; charset=utf-8",
                            sha256: sha256(data), cachePolicy: immutable, class: "page"))
    }
    for e in moduleEntries { scripts[e] = Data(try modules.rewrite(String(decoding: scripts[e]!, as: UTF8.self), from: nil, hashed: moduleHashed).utf8) }

    // ── The page's own files.
    var hashed: [String: String] = [:]      // "/offline.css" → "/assets/offline-….css"
    for d in documents {
        let css = styles[d.css]!, js = scripts[d.js]!
        let cssPath = "assets/\(d.css)-\(sha256(css).prefix(16)).css"
        let jsPath = "assets/\(d.js)-\(sha256(js).prefix(16)).js"
        let docData = Data(docText[d.file]!
            .replacingOccurrences(of: "href=\"/\(d.css).css\"", with: "href=\"/\(cssPath)\"")
            .replacingOccurrences(of: "src=\"/\(d.js).js\"", with: "src=\"/\(jsPath)\"").utf8)
        // 745: a stylesheet two documents share (the chat window's is the dashboard's) is one asset.
        for a in [
            Asset(publicPath: d.publicPath, resourcePath: d.file, mimeType: "text/html; charset=utf-8", sha256: sha256(docData), cachePolicy: "no-store", class: "page"),
            Asset(publicPath: "/" + cssPath, resourcePath: cssPath, mimeType: "text/css; charset=utf-8", sha256: sha256(css), cachePolicy: immutable, class: "page"),
            Asset(publicPath: "/" + jsPath, resourcePath: jsPath, mimeType: "application/javascript; charset=utf-8", sha256: sha256(js), cachePolicy: immutable, class: "page"),
        ] where !assets.contains(where: { $0.publicPath == a.publicPath }) { assets.append(a) }
        expected[d.file] = docData
        expected[cssPath] = css
        expected[jsPath] = js
        hashed["/\(d.css).css"] = "/" + cssPath
        hashed["/\(d.js).js"] = "/" + jsPath
        hashed[d.publicPath] = d.publicPath
    }

    // ── 605: the service worker, at its STABLE path /sw.js (no-store — a browser checks it for an update
    //    on every navigation). Its precache list (the offline page, its css/js, the icon) is written here
    //    with the hashed names, and its cache's name carries their digest: a new build is a new worker.
    var sw = swText
    var precacheDigest = ""
    for ref in ["/offline.css", "/offline.js", "/icons/icon.svg"] {
        guard sw.contains("\"\(ref)\""), let to = hashed[ref] ?? refs[ref] else { throw Failure.source("sw.js must precache \"\(ref)\"") }
        sw = sw.replacingOccurrences(of: "\"\(ref)\"", with: "\"\(to)\"")
        precacheDigest += to
    }
    guard sw.contains("\"/offline\""), sw.contains("@build@") else { throw Failure.source("sw.js must precache \"/offline\" and name its cache with @build@") }
    // 745: its navigation fallback covers exactly the pages a person opens (`page` documents, each at its own path).
    let pageList = documents.filter(\.page).map(\.publicPath)
    guard let pm = sw.range(of: #"const PAGES = \[[^\]]*\];"#, options: .regularExpression),
          Set(sw[pm].split(separator: "\"").enumerated().filter { $0.offset % 2 == 1 }.map { String($0.element) }) == Set(pageList) else {
        throw Failure.source("sw.js must list its pages exactly: const PAGES = [\(pageList.map { "\"\($0)\"" }.joined(separator: ", "))];")
    }
    precacheDigest += sha256(expected["offline.html"]!)
    sw = sw.replacingOccurrences(of: "@build@", with: String(sha256(Data(precacheDigest.utf8)).prefix(16)))
    if let stray = sw.range(of: #""/(icons/[^"]*|[a-z]+\.(css|js))""#, options: .regularExpression) {
        throw Failure.source("sw.js references \(sw[stray]), which is not precached")
    }
    let swData = Data(sw.utf8)
    expected["sw.js"] = swData
    assets.append(Asset(publicPath: "/sw.js", resourcePath: "sw.js", mimeType: "application/javascript; charset=utf-8",
                        sha256: sha256(swData), cachePolicy: "no-store", class: "page"))
    assets.sort { $0.publicPath < $1.publicPath }
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    var manifest = try enc.encode(Manifest(version: 1, assets: assets))
    manifest.append(10)
    expected["manifest.json"] = manifest

    var existing: [String: Data] = [:]
    let base = output.resolvingSymlinksInPath().path + "/"
    if let e = fm.enumerator(at: output, includingPropertiesForKeys: [.isRegularFileKey]) {
        while let u = e.nextObject() as? URL {
            guard (try? u.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let path = u.resolvingSymlinksInPath().path
            guard path.hasPrefix(base) else { throw Failure.source("unexpected path \(path)") }
            existing[String(path.dropFirst(base.count))] = try Data(contentsOf: u)
        }
    }
    if check {
        guard existing == expected else {
            let want = Set(expected.keys), have = Set(existing.keys)
            let changed = want.intersection(have).filter { expected[$0] != existing[$0] }.sorted()
            throw Failure.stale("x web assets are stale (missing \(want.subtracting(have).sorted()), changed \(changed), unexpected \(have.subtracting(want).sorted())) — run make web-assets and commit Sources/DozableWeb/Resources/Web")
        }
        print("ok web assets: Resources/Web is exactly what WebSource/ builds (\(expected.count) files, \(packages.count) vendored package(s) at their pins)")
        return
    }
    let tmp = output.deletingLastPathComponent().appendingPathComponent(".Web.generating-\(UUID().uuidString)")
    try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tmp) }
    for (path, data) in expected {
        let dest = tmp.appendingPathComponent(path)
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: dest, options: .atomic)
    }
    if fm.fileExists(atPath: output.path) { try fm.removeItem(at: output) }
    try fm.moveItem(at: tmp, to: output)
    print("generated \(expected.count) web assets in \(output.path)")
}

do { try main() } catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
