import Foundation
import JavaScriptCore
import XCTest
import DozableHost
@testable import DozableWeb

/// 607 — the page script as native ES modules (`WebSource/app.js` + `WebSource/app/<layer>/*.js`): what ships
/// (every module hashed, served immutable, imported by its hashed RELATIVE name, the graph layered and closed),
/// and what the asset compiler refuses (a cycle, an import up a layer, a bare/absolute/missing specifier, a
/// dynamic import(), an orphan, an unprovided upcall, innerHTML in a module).
final class WebModulesTests: XCTestCase {
    static var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    static let layers = ["dom": 0, "core": 1, "components": 2, "views": 3]

    /// The specifiers a served page script imports (static imports only — the compiler allows nothing else).
    static func specifiers(_ text: String) -> [String] {
        let re = try! NSRegularExpression(pattern: #"(?m)^[ \t]*(?:import|export)\b[^'";=()]*?\bfrom[ \t]*'([^'\n]*)'|^[ \t]*import[ \t]*'([^'\n]*)'"#)
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
            ns.substring(with: m.range(at: 1).location != NSNotFound ? m.range(at: 1) : m.range(at: 2))
        }
    }

    /// A specifier resolved like a browser does, against the importing script's public path.
    static func resolve(_ spec: String, against path: String) -> String {
        URL(string: spec, relativeTo: URL(string: "http://127.0.0.1:1" + path)!)!.path
    }

    /// Who may call the server directly: `fetch` only in these modules (core/api.js is THE request; the others fetch static
    /// files of this origin — the sprite, the engine, the offline check), and a live stream (`EventSource`) only in these
    /// three. Chat's modules go through core/chat-api.js (→ apiFetch) and core/chat-stream.js only.
    func testFetchAndEventSourceOnlyWhereTheyAreAllowed() throws {
        let src = Self.root.appendingPathComponent("Sources/DozableWeb/WebSource")
        var fetchers: Set<String> = [], streams: Set<String> = []
        let files = (FileManager.default.enumerator(atPath: src.appendingPathComponent("app").path)?.allObjects as? [String] ?? [])
            .filter { $0.hasSuffix(".js") }.map { "app/" + $0 } + ["app.js"]
        for f in files {
            let text = try String(contentsOf: src.appendingPathComponent(f), encoding: .utf8)
            if text.contains("fetch(") && text.range(of: #"(?<![A-Za-z])fetch\("#, options: .regularExpression) != nil { fetchers.insert(f) }
            if text.contains("EventSource(") { streams.insert(f) }
        }
        XCTAssertEqual(fetchers, ["app/core/api.js", "app/core/reconnect.js", "app/components/terminal.js", "app/dom/icons.js"])
        XCTAssertEqual(streams, ["app/core/events.js", "app/core/chat-stream.js", "app/views/sandbox-files.js"])
        for f in files where f.contains("/chat") {
            let text = try String(contentsOf: src.appendingPathComponent(f), encoding: .utf8)
            for never in ["innerHTML", "outerHTML", "insertAdjacentHTML", "document.write", "X-Doz-CSRF", "localStorage.setItem('sb", "/api/v1/chat/stream'", "eval("] where !(never == "/api/v1/chat/stream'" && f == "app/core/chat-stream.js") {
                XCTAssertFalse(text.contains(never), "\(f): \(never)")
            }
        }
    }

    /// A workspace's page: its modules ship; the permissions tab's name is ONE constant; `core/ws-log.js` is pure (no
    /// import) with its `interleave`; and there is ONE chat client — only views/chat.js makes the composer (`chat-text`), only
    /// core/chat-stream.js opens chat's stream, and the workspace's modules neither fetch nor stream (they MOVE the Chat
    /// page's surface with `mountChat`).
    func testTheWorkspacePageIsOneChatClient() throws {
        let src = Self.root.appendingPathComponent("Sources/DozableWeb/WebSource")
        let read = { (f: String) in try String(contentsOf: src.appendingPathComponent(f), encoding: .utf8) }
        let a = try WebAssets.load()
        for m in ["views/workspace", "components/ws-brief", "components/ws-panel", "core/ws-log"] {
            XCTAssertTrue(a.assets.keys.contains { $0.hasPrefix("/assets/app/\(m)-") }, "\(m) is served")
        }
        let ws = try read("app/views/workspace.js")
        XCTAssertTrue(ws.contains("export const PERMISSIONS_TAB = 'Permissions';"))
        let files = (FileManager.default.enumerator(atPath: src.appendingPathComponent("app").path)?.allObjects as? [String] ?? [])
            .filter { $0.hasSuffix(".js") }.map { "app/" + $0 } + ["app.js"]
        var named: [String] = [], composers: [String] = []
        for f in files {
            let text = try read(f)
            if text.contains("'Permissions'") { named.append(f) }
            if text.contains("id: 'chat-text'") { composers.append(f) }
        }
        XCTAssertEqual(named, ["app/views/workspace.js"], "the tab's name is written once")
        XCTAssertEqual(ws.components(separatedBy: "'Permissions'").count, 2, "…exactly once")
        XCTAssertEqual(composers, ["app/views/chat.js"], "one composer")
        let log = try read("app/core/ws-log.js")
        XCTAssertTrue(Self.specifiers(log).isEmpty, "core/ws-log.js is pure: it imports nothing")
        XCTAssertTrue(log.contains("export function interleave("))
        for f in ["app/views/workspace.js", "app/components/ws-brief.js", "app/components/ws-panel.js", "app/core/ws-log.js"] {
            let text = try read(f)
            for never in ["fetch(", "EventSource(", "openChatStream", "chat/stream", "innerHTML", "chat-text"] {
                XCTAssertFalse(text.contains(never), "\(f): \(never)")
            }
        }
        XCTAssertTrue(ws.contains("mountChat("), "the page moves the Chat page's surface")
        // Every tab in the mockups' order; only Room works.
        let order = ["'Room'", "'Agents'", "PERMISSIONS_TAB", "'Network & secrets'", "'Folders & points'", "'Activity'", "'Settings'"]
        let at = order.map { ws.range(of: "label: " + $0)?.lowerBound }
        XCTAssertFalse(at.contains(nil), "every tab")
        XCTAssertEqual(at.compactMap { $0 }, at.compactMap { $0 }.sorted(), "in the mockups' order")
    }

    /// The Agents tab and an agent's screen: their modules ship; `core/routes.js` (pure — no import) parses #/w/W/agents and
    /// #/w/W/agent/A[/S|~home] (run here in JavaScriptCore) and `placeHash` keeps a framed address only for the frame's
    /// place; and no module writes a place's address (`#/sandbox/…`, `#/mac/here/…` into the location) but through it.
    func testTheAgentsTabAndTheFramedAddresses() throws {
        let src = Self.root.appendingPathComponent("Sources/DozableWeb/WebSource")
        let read = { (f: String) in try String(contentsOf: src.appendingPathComponent(f), encoding: .utf8) }
        let a = try WebAssets.load()
        for m in ["views/ws-agents", "components/put-in-workspace", "components/agent-frame"] {
            XCTAssertTrue(a.assets.keys.contains { $0.hasPrefix("/assets/app/\(m)-") }, "\(m) is served")
        }
        let routes = try read("app/core/routes.js")
        XCTAssertTrue(Self.specifiers(routes).isEmpty, "core/routes.js is pure: it imports nothing")
        let ctx = try XCTUnwrap(JSContext())
        var thrown: String?
        ctx.exceptionHandler = { _, e in thrown = e?.toString() }
        ctx.evaluateScript(routes.replacingOccurrences(of: "export ", with: ""))
        XCTAssertNil(thrown, thrown ?? "")
        func js(_ expr: String) -> String { ctx.evaluateScript("JSON.stringify(" + expr + ")")?.toString() ?? "?" }
        func parsed(_ hash: String) -> [String: Any]? {
            (try? JSONSerialization.jsonObject(with: Data(js("parse('\(hash)')").utf8))) as? [String: Any]
        }
        XCTAssertEqual(parsed("#/w/demo/agents")?["view"] as? String, "workspace")
        XCTAssertEqual(parsed("#/w/demo/agents")?["tab"] as? String, "agents")
        XCTAssertEqual(parsed("#/w/demo")?["tab"] as? NSNull, NSNull(), "the room: no tab")
        for (hash, session) in [("#/w/demo/agent/gamma", nil), ("#/w/demo/agent/gamma/~home", "~home"), ("#/w/demo/agent/bot_1.a/claude-2", "claude-2")] as [(String, String?)] {
            let p = parsed(hash)
            XCTAssertEqual(p?["view"] as? String, "wsagent", hash)
            XCTAssertEqual(p?["param"] as? String, "demo", hash)
            XCTAssertEqual(p?["agent"] as? String, hash.split(separator: "/")[4].description, hash)
            XCTAssertEqual(p?["session"] as? String, session, hash)
        }
        XCTAssertEqual(js("parse('#/w/demo/agent/gamma/can-do')"), "null", "Can do: not an address yet")
        XCTAssertEqual(js("canonical('#/w/demo/agent/gamma/can-do')"), "\"#/w/demo/agent/gamma\"", "…it lands on the agent")
        for bad in ["#/w/demo/agent/", "#/w/demo/agent/-x", "#/w/demo/agent/.x", "#/w/Demo/agents", "#/w/demo/agent/a/b/c"] {
            XCTAssertEqual(js("parse('\(bad)')"), "null", bad)
        }
        let frame = "{workspace:'demo',agent:'gamma',kind:'sandbox',place:'gamma'}"
        XCTAssertEqual(js("placeHash('sandbox','gamma','claude-2',\(frame))"), "\"#/w/demo/agent/gamma/claude-2\"", "a session tab keeps the frame")
        XCTAssertEqual(js("placeHash('sandbox','gamma','~home',\(frame))"), "\"#/w/demo/agent/gamma/~home\"")
        XCTAssertEqual(js("placeHash('sandbox','gamma',null,\(frame))"), "\"#/w/demo/agent/gamma\"")
        XCTAssertEqual(js("placeHash('sandbox','other','claude',\(frame))"), "\"#/sandbox/other/claude\"", "another place leaves it")
        XCTAssertEqual(js("placeHash('mac','gamma',null,\(frame))"), "\"#/mac/here/gamma\"", "another kind leaves it")
        XCTAssertEqual(js("placeHash('sandbox','gamma',null,null)"), "\"#/sandbox/gamma\"")
        XCTAssertEqual(js("placeHash('mac','wsu',null,{workspace:'d',agent:'wsu',kind:'mac',place:'wsu'})"), "\"#/w/d/agent/wsu\"")
        XCTAssertEqual(js("placeHash('mac','wsu',null,null)"), "\"#/mac/here/wsu\"")
        // No module writes a place's address into the location but through placeHash (links — href — stay plain).
        let files = (FileManager.default.enumerator(atPath: src.appendingPathComponent("app").path)?.allObjects as? [String] ?? [])
            .filter { $0.hasSuffix(".js") }.map { "app/" + $0 } + ["app.js"]
        let writer = try NSRegularExpression(pattern: #"(location\.hash\s*=|replaceState\()[^;\n]*'#/(sandbox|mac/here)/"#)
        for f in files where f != "app/core/routes.js" {
            let text = try read(f)
            XCTAssertEqual(writer.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text)), 0, "\(f) writes a place's address itself")
        }
        // The tab row: Room and Agents work; the permissions tab's name is still the one constant.
        let ws = try read("app/views/workspace.js")
        XCTAssertTrue(ws.contains("{ id: 'agents', label: 'Agents', href:"), "Agents is enabled")
        // Filing: only the three typed actions, never another workspace-* one.
        let piw = try read("app/components/put-in-workspace.js")
        let sent = Set(try NSRegularExpression(pattern: #"action: '(workspace-[a-z]+)'"#).matches(in: piw, range: NSRange(piw.startIndex..., in: piw))
            .map { (piw as NSString).substring(with: $0.range(at: 1)) })
        XCTAssertEqual(sent, ["workspace-adopt", "workspace-new", "workspace-release"])
    }

    /// The New workspace wizard: its modules ship; `#/new-workspace[?bot=NAME]` is a modal address (routes.js in JavaScriptCore);
    /// `core/ws-new.js` is pure and its `slugFrom`, `gapStep`, `briefText` and `requestFrom` do what the wizard relies on; the
    /// two actions it sends are exactly `workspace-new` and `workspace-start`, and only the wizard and a workspace's page start
    /// one.
    func testTheNewWorkspaceWizard() throws {
        let src = Self.root.appendingPathComponent("Sources/DozableWeb/WebSource")
        let read = { (f: String) in try String(contentsOf: src.appendingPathComponent(f), encoding: .utf8) }
        let a = try WebAssets.load()
        for m in ["views/new-workspace", "components/ws-gaps", "core/ws-new"] {
            XCTAssertTrue(a.assets.keys.contains { $0.hasPrefix("/assets/app/\(m)-") }, "\(m) is served")
        }
        let ctx = try XCTUnwrap(JSContext())
        var thrown: String?
        ctx.exceptionHandler = { _, e in thrown = e?.toString() }
        ctx.evaluateScript(try read("app/core/routes.js").replacingOccurrences(of: "export ", with: ""))
        let pure = try read("app/core/ws-new.js")
        XCTAssertTrue(Self.specifiers(pure).isEmpty, "core/ws-new.js is pure: it imports nothing")
        ctx.evaluateScript(pure.replacingOccurrences(of: "export ", with: ""))
        XCTAssertNil(thrown, thrown ?? "")
        func js(_ expr: String) -> String { ctx.evaluateScript("JSON.stringify(" + expr + ")")?.toString() ?? "?" }
        XCTAssertEqual(js("parse('#/new-workspace').view"), "\"new-workspace\"")
        XCTAssertEqual(js("parse('#/new-workspace').modal"), "true")
        XCTAssertEqual(js("parse('#/new-workspace?bot=mira').param"), "\"mira\"")
        XCTAssertEqual(js("parse('#/new-workspace?bot=Mira')"), "null", "a bot's name by the chat rule")
        XCTAssertEqual(js("MODAL_VIEWS.has('new-workspace')"), "true")
        XCTAssertEqual(js("parse('#/new').view"), "\"new\"", "#/new stays New sandbox")
        XCTAssertEqual(js("slugFrom('A 60-second launch video for MyApp 2.0 in Remotion')"), "\"a-60-second-launch-video\"")
        XCTAssertEqual(js("slugFrom('  Écrire la doc!  ')"), "\"ecrire-la-doc\"")
        XCTAssertEqual(js("slugFrom('')"), "\"\"")
        XCTAssertEqual(js("slugFrom('x'.repeat(60))"), "\"\"", "a first word over 40 makes no name")
        XCTAssertEqual(js("slugFrom('aaaaaaaaaa bbbbbbbbbb cccccccccc dddddddddd eeeeee').length <= 40"), "true")
        XCTAssertEqual(js("[gapStep('brief'), gapStep('folder'), gapStep('manager'), gapStep('chat'), gapStep('room')]"), "[0,0,1,3,3]")
        XCTAssertEqual(js("[briefText('a'), briefText('a\\n'), briefText('')]"), #"["a\n","a\n",""]"#)
        let r = js("requestFrom({name:'w', brief:'b', refs:[], folders:[{path:'/x', mode:'ro'}], newFolder:true, fromProject:true, network:'open', manager:'mira', managerIsolation:'vm', workerIsolation:'fenced', noRoom:true})")
        XCTAssertEqual(r, #"{"workspace":"w","brief":"b\n","folders":[{"path":"/x","mode":"ro"}],"newFolder":true,"fromProject":true,"noRoom":true,"manager":"mira","managerIsolation":"vm","workerIsolation":"fenced"}"#,
                       "the project fills the network in: none sent with fromProject")
        XCTAssertEqual(js("requestFrom({name:'w', brief:'b', managerIsolation:'unfenced', network:'locked'})"), #"{"workspace":"w","brief":"b\n","network":"locked"}"#,
                       "an isolation only with a manager")
        XCTAssertTrue(pure.contains("export const WORKSPACE_DEFINITION = 'A workspace is an environment set up for getting work done: its agents, its rooms, the brief that says what the work is for, and any folders it works on (usually projects). Work starts only once it is fully set up.';"))
        // What the pages send: the wizard exactly new and start; a workspace's page start; no other module starts one.
        let files = (FileManager.default.enumerator(atPath: src.appendingPathComponent("app").path)?.allObjects as? [String] ?? [])
            .filter { $0.hasSuffix(".js") }.map { "app/" + $0 } + ["app.js"]
        let action = try NSRegularExpression(pattern: #"action: '(workspace-[a-z]+)'"#)
        func sent(_ f: String) throws -> Set<String> {
            let t = try read(f)
            return Set(action.matches(in: t, range: NSRange(t.startIndex..., in: t)).map { (t as NSString).substring(with: $0.range(at: 1)) })
        }
        XCTAssertEqual(try sent("app/views/new-workspace.js"), ["workspace-new", "workspace-start"])
        for f in files where !["app/views/new-workspace.js", "app/views/workspace.js"].contains(f) {
            XCTAssertFalse(try sent(f).contains("workspace-start"), "\(f) starts a workspace")
        }
        let wiz = try read("app/views/new-workspace.js")
        XCTAssertTrue(wiz.contains("api('workspace-plan'"), "the plan route")
        XCTAssertTrue(wiz.contains("new AbortController()"), "the latest plan wins")
        XCTAssertTrue(wiz.contains("sessionStorage"), "its choices kept for the trip to the bot editor")
        XCTAssertFalse(wiz.lowercased().contains("'draft") || wiz.contains("as draft"), "the state is setting up")
    }

    /// The isolation guide: its modules served; both addresses parse (and nothing else under #/guide/); core/isolation.js is
    /// pure, lists the four choices in order of isolation, and its control words are exactly `doz worker ls`'s
    /// (WorkerLaunch.control); every view that draws an isolation chip draws it through components/iso-chip.js, which links
    /// to the guide at that choice.
    func testTheIsolationGuide() throws {
        let src = Self.root.appendingPathComponent("Sources/DozableWeb/WebSource")
        let read = { (f: String) in try String(contentsOf: src.appendingPathComponent(f), encoding: .utf8) }
        let a = try WebAssets.load()
        for m in ["views/isolation-guide", "core/isolation", "components/iso-chip"] {
            XCTAssertTrue(a.assets.keys.contains { $0.hasPrefix("/assets/app/\(m)-") }, "\(m) is served")
        }
        let ctx = try XCTUnwrap(JSContext())
        var thrown: String?
        ctx.exceptionHandler = { _, e in thrown = e?.toString() }
        ctx.evaluateScript(try read("app/core/routes.js").replacingOccurrences(of: "export ", with: ""))
        let pure = try read("app/core/isolation.js")
        XCTAssertTrue(Self.specifiers(pure).isEmpty, "core/isolation.js is pure: it imports nothing")
        ctx.evaluateScript(pure.replacingOccurrences(of: "export ", with: ""))
        XCTAssertNil(thrown, thrown ?? "")
        func js(_ expr: String) -> String { ctx.evaluateScript("JSON.stringify(" + expr + ")")?.toString() ?? "?" }
        XCTAssertEqual(js("[parse('#/guide/isolation').view, parse('#/guide/isolation').param]"), #"["guide",null]"#)
        for id in ["vm", "fenced", "unfenced", "elsewhere"] {
            XCTAssertEqual(js("parse('#/guide/isolation/\(id)').param"), "\"\(id)\"")
            XCTAssertEqual(js("guideHash('\(id)')"), "\"#/guide/isolation/\(id)\"")
            XCTAssertEqual(js("canonical('#/guide/isolation/\(id)')"), "\"#/guide/isolation/\(id)\"")
        }
        XCTAssertEqual(js("parse('#/guide/isolation/cloud')"), "null")
        XCTAssertEqual(js("parse('#/guide')"), "null")
        XCTAssertEqual(js("ISOLATIONS.map((x) => x.id)"), #"["vm","fenced","unfenced","elsewhere"]"#, "in order of isolation")
        XCTAssertEqual(js("GUIDE_ISOLATIONS"), js("ISOLATIONS.map((x) => x.id)"))
        for iso in ["vm", "fenced", "unfenced"] {
            XCTAssertEqual(js("isolationById('\(iso)').control"), "\"\(WorkerLaunch.control(isolation: iso))\"", "\(iso): worker ls's words")
        }
        XCTAssertEqual(js("[isolationIdOf('micro VM'), isolationIdOf('fenced'), isolationIdOf('on this Mac')]"), #"["vm","fenced",null]"#)
        XCTAssertEqual(js("isolationById('unfenced').rows.manager"), #""✕ always asks you""#)
        XCTAssertEqual(js("CLOUD.later"), "true")
        let guide = try read("app/views/isolation-guide.js")
        XCTAssertTrue(pure.contains("not isolated by Dozable") && guide.contains("Not isolated by Dozable."), "elsewhere named honestly")
        // Every chip builder: no module but the chip's own (and the guide's heading) builds a `ws-iso` chip by hand.
        let files = (FileManager.default.enumerator(atPath: src.appendingPathComponent("app").path)?.allObjects as? [String] ?? [])
            .filter { $0.hasSuffix(".js") }.map { "app/" + $0 }
        for f in files where !["app/components/iso-chip.js", "app/views/isolation-guide.js"].contains(f) {
            XCTAssertFalse(try read(f).contains("'ws-iso ws-iso-"), "\(f) draws an isolation chip by hand — use isolationChip")
        }
        for f in ["app/components/agent-frame.js", "app/components/ws-panel.js", "app/views/bot.js"] {
            XCTAssertTrue(try read(f).contains("isolationChip("), "\(f) draws its chips through isolationChip")
        }
        let chip = try read("app/components/iso-chip.js")
        XCTAssertTrue(chip.contains("href: guideHash(id)"), "the chip links to the guide at its choice")
        XCTAssertEqual(try read("app.js").components(separatedBy: "viewIsolationGuide").count - 1, 2, "imported and provided")
    }

    func testEveryModuleIsServedHashedAndImportedOnlyFromItsOwnLayerOrBelow() throws {
        let a = try WebAssets.load()
        let src = Self.root.appendingPathComponent("Sources/DozableWeb/WebSource/app")
        let sources = (FileManager.default.enumerator(atPath: src.path)?.allObjects as? [String] ?? []).filter { $0.hasSuffix(".js") }
        let modules = a.assets.keys.filter { $0.hasPrefix("/assets/app/") }
        XCTAssertEqual(modules.count, sources.count, "one served module per source module")
        let entry = try XCTUnwrap(a.pageScript)
        var reached = Set<String>()
        var queue = [entry]
        while let p = queue.popLast() {
            let asset = try XCTUnwrap(a.assets[p], p)
            XCTAssertEqual(asset.mimeType, "application/javascript; charset=utf-8", p)
            XCTAssertEqual(asset.cachePolicy, WebAssets.immutable, p)
            let text = String(decoding: asset.data, as: UTF8.self)
            XCTAssertFalse(text.contains("innerHTML") || text.contains("insertAdjacentHTML"), p)
            for spec in Self.specifiers(text) {
                XCTAssertTrue(spec.hasPrefix("./") || spec.hasPrefix("../"), "\(p) imports \(spec) relatively")
                let target = Self.resolve(spec, against: p)
                XCTAssertTrue(target.hasPrefix("/assets/app/"), "\(p) → \(target)")
                XCTAssertNotNil(a.assets[target], "\(p) imports \(target), which is served")
                XCTAssertTrue(target.range(of: #"-[0-9a-f]{16}\.js$"#, options: .regularExpression) != nil, "\(target) is a hashed name")
                if p != entry {
                    let from = p.split(separator: "/")[2], to = target.split(separator: "/")[2]
                    XCTAssertLessThanOrEqual(Self.layers[String(to)]!, Self.layers[String(from)]!, "\(p) imports \(target): never up a layer")
                }
                if reached.insert(target).inserted { queue.append(target) }
            }
        }
        XCTAssertEqual(reached, Set(modules), "the entry reaches every module, and nothing else")
        if !modules.isEmpty {
            let index = String(decoding: a.assets["/"]!.data, as: UTF8.self)
            XCTAssertTrue(index.contains("<script type=\"module\" src=\"\(entry)\"></script>"), "index.html loads the entry as a module")
        }
    }

    /// A served module is its source with ONLY the import specifiers changed (to the hashed names).
    func testAServedModuleIsItsSourceWithHashedSpecifiersOnly() throws {
        let a = try WebAssets.load()
        let src = Self.root.appendingPathComponent("Sources/DozableWeb/WebSource")
        let unhash = { (t: String) in t.replacingOccurrences(of: #"-[0-9a-f]{16}\.js'"#, with: ".js'", options: .regularExpression) }
        for (path, asset) in a.assets where path.hasPrefix("/assets/app/") {
            let rel = String(path.dropFirst("/assets/app/".count)).replacingOccurrences(of: #"-[0-9a-f]{16}\.js$"#, with: ".js", options: .regularExpression)
            let source = try String(contentsOf: src.appendingPathComponent("app/" + rel), encoding: .utf8)
            XCTAssertEqual(unhash(String(decoding: asset.data, as: UTF8.self)), source, rel)
        }
        let entry = String(decoding: a.assets[a.pageScript!]!.data, as: UTF8.self)
        XCTAssertEqual(unhash(entry), try String(contentsOf: src.appendingPathComponent("app.js"), encoding: .utf8))
    }

    // MARK: the compiler's refusals, on a scratch copy of the sources

    func compileScratch(_ change: (URL) throws -> Void) throws -> (Int32, String) {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("doz-webm-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        try fm.createDirectory(at: tmp.appendingPathComponent("Scripts"), withIntermediateDirectories: true)
        try fm.createDirectory(at: tmp.appendingPathComponent("Sources/DozableWeb"), withIntermediateDirectories: true)
        try fm.copyItem(at: Self.root.appendingPathComponent("Scripts/build-web-assets.swift"), to: tmp.appendingPathComponent("Scripts/build-web-assets.swift"))
        try fm.copyItem(at: Self.root.appendingPathComponent("Sources/DozableWeb/WebSource"), to: tmp.appendingPathComponent("Sources/DozableWeb/WebSource"))
        try fm.copyItem(at: Self.root.appendingPathComponent("Sources/DozableWeb/Resources"), to: tmp.appendingPathComponent("Sources/DozableWeb/Resources"))
        try change(tmp.appendingPathComponent("Sources/DozableWeb/WebSource"))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["swift", tmp.appendingPathComponent("Scripts/build-web-assets.swift").path]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        let d = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: d, as: UTF8.self))
    }

    /// Writes app/<rel> and makes the entry import it (index.html loads the entry as a module).
    static func add(_ src: URL, _ rel: String, _ text: String, importFromEntry: Bool = true) throws {
        let u = src.appendingPathComponent("app/" + rel)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: u)
        let index = src.appendingPathComponent("index.html")
        let html = try String(contentsOf: index, encoding: .utf8)
        try Data(html.replacingOccurrences(of: "<script src=\"/app.js\" defer></script>", with: "<script type=\"module\" src=\"/app.js\"></script>").utf8).write(to: index)
        if importFromEntry {
            let entry = src.appendingPathComponent("app.js")
            try Data(("import './app/\(rel)';\n" + (try String(contentsOf: entry, encoding: .utf8))).utf8).write(to: entry)
        }
    }

    func testTheCompilerRefusesABadModuleGraph() throws {
        func refused(_ what: String, _ expect: String, _ change: (URL) throws -> Void) throws {
            let (status, out) = try compileScratch(change)
            XCTAssertNotEqual(status, 0, what)
            XCTAssertTrue(out.contains(expect), "\(what): \(out)")
        }
        // A good graph compiles (a layered pair, imported by its hashed name).
        let ok = try compileScratch { src in
            try Self.add(src, "core/zz-b.js", "export const b = 1;\n", importFromEntry: false)
            try Self.add(src, "views/zz-a.js", "import { b } from '../core/zz-b.js';\nexport const a = b;\n")
        }
        XCTAssertEqual(ok.0, 0, ok.1)
        try refused("a cycle", "an import cycle") { src in
            try Self.add(src, "core/zz-a.js", "import { b } from './zz-b.js';\nexport function a() { return b(); }\n")
            try Self.add(src, "core/zz-b.js", "import { a } from './zz-a.js';\nexport function b() { return a(); }\n", importFromEntry: false)
        }
        try refused("an import up a layer", "up a layer") { src in
            try Self.add(src, "views/zz-v.js", "export const v = 1;\n", importFromEntry: false)
            try Self.add(src, "components/zz-c.js", "import { v } from '../views/zz-v.js';\nexport const c = v;\n")
        }
        try refused("a bare specifier", "only by a relative specifier") { src in
            try Self.add(src, "core/zz-a.js", "import x from 'lodash';\nexport const a = x;\n")
        }
        try refused("an absolute specifier", "only by a relative specifier") { src in
            try Self.add(src, "core/zz-a.js", "import { x } from '/assets/app/core/x.js';\nexport const a = x;\n")
        }
        try refused("a missing module", "which does not exist") { src in
            try Self.add(src, "core/zz-a.js", "import { x } from './zz-nope.js';\nexport const a = x;\n")
        }
        try refused("a dynamic import", "uses import()") { src in
            try Self.add(src, "core/zz-a.js", "export const a = () => import('./zz-a.js');\n")
        }
        try refused("an orphan module", "never loads") { src in
            try Self.add(src, "core/zz-a.js", "export const a = 1;\n", importFromEntry: false)
        }
        try refused("a module outside the layers", "only app/<dom|core|components|views>") { src in
            try Self.add(src, "core/Bad_Name.js", "export const a = 1;\n")
        }
        try refused("an unprovided upcall", "which app.js does not provide") { src in
            try Self.add(src, "core/zz-a.js", "const nowhere = upcall('nowhere');\nexport const a = nowhere;\n")
        }
        try refused("innerHTML in a module", "uses innerHTML") { src in
            try Self.add(src, "views/zz-a.js", "export function a(el, s) { el.innerHTML = s; }\n")
        }
        try refused("an external URL in a module", "references an external URL") { src in
            try Self.add(src, "views/zz-a.js", "export const a = 'https://example.com/x.js';\n")
        }
        try refused("a module loaded as a classic script", "must load app.js as a module") { src in
            try Self.add(src, "core/zz-a.js", "export const a = 1;\n")
            let index = src.appendingPathComponent("index.html")
            let html = try String(contentsOf: index, encoding: .utf8)
            try Data(html.replacingOccurrences(of: "<script type=\"module\" src=\"/app.js\"></script>", with: "<script src=\"/app.js\" defer></script>").utf8).write(to: index)
        }
    }
}
