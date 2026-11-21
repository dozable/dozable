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
    /// A workspace's lifecycle: its modules ship; core/ws-lifecycle.js is pure (no import) — the primary verb a state offers,
    /// how each verb is confirmed (the daemon's `WorkspaceVerb.confirm`), the plan route's and the action's bodies, when its
    /// button may be pressed; one component sends the eight actions, carrying the plan's sha, and asks the plan route first.
    func testTheLifecycleDialogs() throws {
        let src = Self.root.appendingPathComponent("Sources/DozableWeb/WebSource")
        let read = { (f: String) in try String(contentsOf: src.appendingPathComponent(f), encoding: .utf8) }
        let a = try WebAssets.load()
        for m in ["components/ws-lifecycle", "core/ws-lifecycle"] {
            XCTAssertTrue(a.assets.keys.contains { $0.hasPrefix("/assets/app/\(m)-") }, "\(m) is served")
        }
        let ctx = try XCTUnwrap(JSContext())
        var thrown: String?
        ctx.exceptionHandler = { _, e in thrown = e?.toString() }
        let pure = try read("app/core/ws-lifecycle.js")
        XCTAssertTrue(Self.specifiers(pure).isEmpty, "core/ws-lifecycle.js is pure: it imports nothing")
        ctx.evaluateScript(pure.replacingOccurrences(of: "export ", with: ""))
        XCTAssertNil(thrown, thrown ?? "")
        func js(_ expr: String) -> String { ctx.evaluateScript("JSON.stringify(" + expr + ")")?.toString() ?? "?" }
        XCTAssertEqual(js("['setting-up','idle','working','waiting-on-you','starting','asleep','finished','archived'].map(primaryVerb)"),
                       #"["start","sleep","sleep","sleep","sleep","wake","reopen","restore"]"#)
        for v in WorkspaceVerb.allCases {
            XCTAssertEqual(js("confirmKind('\(v.rawValue)')"), "\"" + v.confirm.rawValue + "\"", "\(v.rawValue): confirmed as the daemon says")
        }
        XCTAssertEqual(js("planBody('w','sleep',{removeSandboxes:true, binFolders:true})"), #"{"workspace":"w","verb":"sleep"}"#, "flags only where they belong")
        XCTAssertEqual(js("planBody('w','delete',{removeSandboxes:true, binFolders:true})"), #"{"workspace":"w","verb":"delete","removeSandboxes":true,"binFolders":true}"#)
        let plan = "{workspace:'w', verb:'archive', sha:'0123456789abcdef', refusals:[], confirm:'typed', confirmName:'w'}"
        XCTAssertEqual(js("actionBody(" + plan + ", {removeSandboxes:true, typed:'w', binFolders:true})"),
                       #"{"action":"workspace-archive","workspace":"w","ifPlan":"0123456789abcdef","removeSandboxes":true,"confirm":"w"}"#)
        XCTAssertEqual(js("[canConfirm(" + plan + ", {typed:'w'}), canConfirm(" + plan + ", {typed:'x'}), canConfirm(" + plan + ", {})]"), "[true,false,false]",
                       "the name typed exactly")
        XCTAssertEqual(js("canConfirm({refusals:['no'], confirm:'none'}, {})"), "false", "never while it would be refused")
        XCTAssertEqual(js("[canConfirm({refusals:[], confirm:'none'}, {needsActsAsYou:true}), canConfirm({refusals:[], confirm:'none'}, {needsActsAsYou:true, actsAsYou:true})]"),
                       "[false,true]", "an unfenced manager's wake: the tick")
        XCTAssertEqual(js("[sizeWords(6200000000), sizeWords(420000000), sizeWords(0)]"), #"["6.2 GB","420 MB",""]"#)
        // One component sends them, each its plan's sha; the plan route first; no other module sends a lifecycle action.
        let comp = try read("app/components/ws-lifecycle.js")
        XCTAssertTrue(comp.contains("api('workspace-lifecycle-plan'"), "the plan route")
        XCTAssertTrue(comp.contains("actOrThrow(actionBody(plan, o))"), "the action is the plan's")
        XCTAssertTrue(pure.contains("ifPlan: plan.sha"))
        let files = (FileManager.default.enumerator(atPath: src.appendingPathComponent("app").path)?.allObjects as? [String] ?? [])
            .filter { $0.hasSuffix(".js") }.map { "app/" + $0 } + ["app.js"]
        let verbs = try NSRegularExpression(pattern: #"action: '(workspace-(stop|sleep|wake|finish|reopen|archive|restore|delete))'"#)
        for f in files {
            let t = try read(f)
            XCTAssertEqual(verbs.numberOfMatches(in: t, range: NSRange(t.startIndex..., in: t)), 0, "\(f) sends a lifecycle action by hand")
        }
        for f in ["app/views/workspace.js", "app/views/home.js"] { XCTAssertTrue(try read(f).contains("ws-lifecycle.js"), "\(f) uses the dialogs") }
    }

    /// The wide views: their addresses (three tabs, an agent's Can do), the pure merge of the log and this dashboard's
    /// operations, the tabs enabled, the later rows drawn, and the one module that sends `mac-net-policy`.
    func testTheWorkspaceWideViews() throws {
        let src = Self.root.appendingPathComponent("Sources/DozableWeb/WebSource")
        let read = { (f: String) in try String(contentsOf: src.appendingPathComponent(f), encoding: .utf8) }
        let a = try WebAssets.load()
        for m in ["components/can-do", "core/ws-activity", "views/ws-network", "views/ws-folders", "views/ws-activity"] {
            XCTAssertTrue(a.assets.keys.contains { $0.hasPrefix("/assets/app/\(m)-") }, "\(m) is served")
        }
        let ctx = try XCTUnwrap(JSContext())
        var thrown: String?
        ctx.exceptionHandler = { _, e in thrown = e?.toString() }
        let routes = try read("app/core/routes.js"), act = try read("app/core/ws-activity.js")
        XCTAssertTrue(Self.specifiers(act).isEmpty, "core/ws-activity.js is pure: it imports nothing")
        ctx.evaluateScript(routes.replacingOccurrences(of: "export ", with: ""))
        ctx.evaluateScript(act.replacingOccurrences(of: "export ", with: ""))
        XCTAssertNil(thrown, thrown ?? "")
        func js(_ expr: String) -> String { ctx.evaluateScript("JSON.stringify(" + expr + ")")?.toString() ?? "?" }
        for t in ["network", "folders", "activity"] {
            XCTAssertEqual(js("[parse('#/w/demo/\(t)').view, parse('#/w/demo/\(t)').tab]"), "[\"workspace\",\"\(t)\"]")
            XCTAssertEqual(js("canonical('#/w/demo/\(t)')"), "\"#/w/demo/\(t)\"")
        }
        XCTAssertEqual(js("[networkHash('d'), foldersHash('d'), activityHash('d'), canDoHash('d','mira')]"),
                       ##"["#/w/d/network","#/w/d/folders","#/w/d/activity","#/w/d/agent/mira/can-do"]"##)
        XCTAssertEqual(js("[parse('#/w/demo/agent/mira/can-do').view, parse('#/w/demo/agent/mira/can-do').agent]"), #"["wsagent","mira"]"#)
        XCTAssertEqual(js("parse('#/w/demo/permissions')"), "null", "Permissions has no address yet")
        // The merge: the log's lines and the ring's operations for this workspace's places, newest first, filtered.
        let lines = "[{at:'2026-11-20T10:00:00Z',by:'you',action:'created',text:'created'},{at:'2026-11-20T10:05:00Z',by:'doz',action:'worker-added',agent:'bot1',text:'added the worker bot1'}]"
        let ops = "[{id:'1',action:'net-policy',label:'net-policy wsa',sandbox:'wsa',state:'done',text:'ok',startedAt:'2026-11-20T10:03:00Z'}," +
            "{id:'2',action:'sleep',label:'sleep other',sandbox:'other',state:'done',text:'',startedAt:'2026-11-20T10:04:00Z'}," +
            "{id:'3',action:'mac-net-policy',label:'allow x.example for session wsu on this Mac',state:'done',text:'',startedAt:'2026-11-20T10:06:00Z'}," +
            "{id:'4',action:'workspace-sleep',label:'sleep demo',state:'done',text:'',startedAt:'2026-11-20T10:07:00Z'}]"
        let places = "['wsa','@mac/wsu']"
        XCTAssertEqual(js("mergeActivity(\(lines), \(ops), 'demo', \(places), 'all').map(x => x.kind + ':' + (x.id || x.action))"),
                       #"["op:4","op:3","log:worker-added","op:1","log:created"]"#, "another sandbox's operation is not this workspace's")
        XCTAssertEqual(js("mergeActivity(\(lines), \(ops), 'demo', \(places), 'network').map(x => x.id)"), #"["3","1"]"#)
        XCTAssertEqual(js("mergeActivity(\(lines), \(ops), 'demo', \(places), 'agents').map(x => x.action)"), #"["worker-added"]"#)
        XCTAssertEqual(js("mergeActivity(\(lines), \(ops), 'demo', \(places), 'lifecycle').map(x => x.action)"), #"["workspace-sleep","created"]"#)
        XCTAssertEqual(js("mergeActivity(\(lines), \(ops), 'demo', \(places), 'you').length"), "4")
        // The tabs are enabled; Permissions still coming, saying where its answer is today.
        let ws = try read("app/views/workspace.js")
        for t in ["network", "folders", "activity"] { XCTAssertTrue(ws.contains("{ id: '\(t)', label:") && ws.contains("href: (w) => \(t)Hash(w)"), t) }
        XCTAssertTrue(ws.contains("today: each agent’s Can do"))
        let cando = try read("app/components/can-do.js")
        XCTAssertFalse(cando.contains("LATER_ROWS") || cando.contains("'aria-disabled'") || cando.contains("'later'"),
                       "the permissions and ceiling rows are data now (workspace-reach), drawn like every other row")
        // mac-net-policy is sent by Network & secrets only; the reads are POSTs to their own routes.
        let files = (FileManager.default.enumerator(atPath: src.appendingPathComponent("app").path)?.allObjects as? [String] ?? [])
            .filter { $0.hasSuffix(".js") }.map { "app/" + $0 } + ["app.js"]
        for f in files where f != "app/views/ws-network.js" { XCTAssertFalse(try read(f).contains("'mac-net-policy'"), "\(f) sends mac-net-policy") }
        XCTAssertTrue(try read("app/views/ws-network.js").contains("api('workspace-reach', { method: 'POST'"))
        XCTAssertTrue(try read("app/views/ws-folders.js").contains("api('workspace-folders', { method: 'POST'"))
        XCTAssertTrue(try read("app/views/ws-activity.js").contains("api('workspace-activity', { method: 'POST'"))
    }

    /// The Runs tab: served, its address, its three reads as POSTs to their own routes, the room actions only from it (never
    /// `loose`), rm's name typed, and a closed room's composer off with its notice; the Finish dialog's "without an archive".
    func testTheRunsTabAndTheRoomActions() throws {
        let src = Self.root.appendingPathComponent("Sources/DozableWeb/WebSource")
        let read = { (f: String) in try String(contentsOf: src.appendingPathComponent(f), encoding: .utf8) }
        let a = try WebAssets.load()
        XCTAssertTrue(a.assets.keys.contains { $0.hasPrefix("/assets/app/views/ws-runs-") }, "views/ws-runs is served")
        let ctx = try XCTUnwrap(JSContext())
        ctx.evaluateScript(try read("app/core/routes.js").replacingOccurrences(of: "export ", with: ""))
        func js(_ expr: String) -> String { ctx.evaluateScript("JSON.stringify(" + expr + ")")?.toString() ?? "?" }
        XCTAssertEqual(js("[parse('#/w/demo/runs').view, parse('#/w/demo/runs').tab, runsHash('demo')]"), ##"["workspace","runs","#/w/demo/runs"]"##)
        let runs = try read("app/views/ws-runs.js")
        for route in ["workspace-runs", "workspace-run-chat", "chat-room-plan"] { XCTAssertTrue(runs.contains("api('\(route)', { method: 'POST'"), route) }
        XCTAssertFalse(runs.contains("loose"), "never a loose room from a browser")
        XCTAssertTrue(runs.contains("typed === room") && runs.contains("b.confirm = typed"), "rm only with the name typed")
        let files = (FileManager.default.enumerator(atPath: src.appendingPathComponent("app").path)?.allObjects as? [String] ?? [])
            .filter { $0.hasSuffix(".js") }.map { "app/" + $0 } + ["app.js"]
        for f in files where f != "app/views/ws-runs.js" {
            let t = try read(f)
            for action in ["'chat-room-archive'", "'chat-room-rm'", "'workspace-run-archive'"] { XCTAssertFalse(t.contains(action), "\(f) sends \(action)") }
        }
        let rooms = try read("app/views/chat-rooms.js")
        XCTAssertTrue(rooms.contains("state.chat.srv.closed") && rooms.contains("Reopen it to post"), "a closed room's composer says why it is off")
        XCTAssertTrue(try read("app/components/ws-lifecycle.js").contains("Finish without an archive"))
        XCTAssertTrue(try read("app/core/ws-lifecycle.js").contains("b.noArchive = true"))
    }

    /// Chat on: one component (`components/chat-on.js`) sends `chat-on`, and every place that says chat is off uses it (the
    /// Chat page and a workspace's Room tab, the set-up item, the wizard's room and gap); only a workspace's page sends
    /// `workspace-make-room`.
    func testChatOnIsOneComponent() throws {
        let src = Self.root.appendingPathComponent("Sources/DozableWeb/WebSource")
        let read = { (f: String) in try String(contentsOf: src.appendingPathComponent(f), encoding: .utf8) }
        XCTAssertTrue(try WebAssets.load().assets.keys.contains { $0.hasPrefix("/assets/app/components/chat-on-") })
        let files = (FileManager.default.enumerator(atPath: src.appendingPathComponent("app").path)?.allObjects as? [String] ?? [])
            .filter { $0.hasSuffix(".js") }.map { "app/" + $0 } + ["app.js"]
        var on: [String] = [], room: [String] = []
        for f in files {
            let t = try read(f)
            if t.contains("'chat-on'") { on.append(f) }
            if t.contains("'workspace-make-room'") { room.append(f) }
        }
        XCTAssertEqual(on, ["app/components/chat-on.js"])
        XCTAssertEqual(room, ["app/views/workspace.js"])
        XCTAssertTrue(try read("app/views/chat.js").contains("chatOnForm("))
        XCTAssertTrue(try read("app/components/ws-gaps.js").contains("chatOnInline("))
        XCTAssertTrue(try read("app/views/new-workspace.js").contains("chatOnForm({ onOn: chatCameOn })"))
        XCTAssertTrue(try read("app/views/ws-home.js").contains("gapsList(gaps, { onChatOn: cur.o.onChatOn })"), "Home's setting-up checklist")
        XCTAssertTrue(try read("app/views/workspace.js").contains("onChatOn: chatCameOn"))
    }

    /// Asks: the card and the one answer path ship; only core/asks.js sends `chat-decide` (the card and the space diagram
    /// both call it); the card is drawn by chat-messages for an ask, and chat-live redraws it on the stream's `ask` event.
    func testTheAskCardAndItsOneAnswerPath() throws {
        let src = Self.root.appendingPathComponent("Sources/DozableWeb/WebSource")
        let read = { (f: String) in try String(contentsOf: src.appendingPathComponent(f), encoding: .utf8) }
        let a = try WebAssets.load()
        for m in ["core/asks", "components/chat-ask"] {
            XCTAssertTrue(a.assets.keys.contains { $0.hasPrefix("/assets/app/\(m)-") }, "\(m) is served")
        }
        let files = (FileManager.default.enumerator(atPath: src.appendingPathComponent("app").path)?.allObjects as? [String] ?? [])
            .filter { $0.hasSuffix(".js") }.map { "app/" + $0 } + ["app.js"]
        var senders: [String] = []
        for f in files where try read(f).contains("'chat-decide'") { senders.append(f) }
        XCTAssertEqual(senders, ["app/core/asks.js"], "only core/asks.js sends chat-decide")
        let asks = try read("app/core/asks.js")
        for fn in ["export async function answerAsk", "export async function answerFromDiagram", "export function rememberAttention",
                   "export function onAskChange", "export function canAnswer"] { XCTAssertTrue(asks.contains(fn), fn) }
        XCTAssertTrue(asks.contains("if (isRemote()) return { refused: MAC_ONLY }"), "another computer: no request")
        XCTAssertTrue(try read("app/components/chat-ask.js").contains("answerAsk("))
        XCTAssertTrue(try read("app/views/chat-messages.js").contains("askCard(m)"))
        let live = try read("app/views/chat-live.js")
        XCTAssertTrue(live.contains("e.kind === 'ask'") && live.contains("add(m, true)"))
    }

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
        for m in ["views/workspace", "views/ws-home", "components/ws-card", "components/ws-brief", "components/ws-panel", "core/ws-log"] {
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
        // Home never opens chat's stream: its two reads are plain GETs (the room's last messages, the open asks).
        let home = try read("app/views/ws-home.js")
        XCTAssertTrue(home.contains("api('chat/asks')") && home.contains("'/messages?limit=2'"))
        for f in ["app/views/workspace.js", "app/views/ws-home.js", "app/components/ws-card.js", "app/components/ws-brief.js", "app/components/ws-panel.js", "app/core/ws-log.js"] {
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
        XCTAssertEqual(parsed("#/w/demo")?["tab"] as? String, "home", "a workspace opens on its Home")
        XCTAssertEqual(parsed("#/w/demo")?["room"] as? NSNull, NSNull())
        XCTAssertEqual(js("[parse('#/w/d/room').view, parse('#/w/d/room').tab, parse('#/w/d/room').room, parse('#/w/d/room/x').tab, parse('#/w/d/room/x').room]"),
                       #"["workspace","room",null,"room","x"]"#, "the Room tab: the main room, or another by its label")
        XCTAssertEqual(js("[canonical('#/w/d'), canonical('#/w/d/'), canonical('#/w/d/home'), canonical('#/w/d/room'), canonical('#/w/d/room/'), canonical('#/w/d/room/x')]"),
                       ##"["#/w/d","#/w/d","#/w/d","#/w/d/room","#/w/d/room","#/w/d/room/x"]"##)
        XCTAssertEqual(js("[roomHash('d'), roomHash('d','x'), workspaceHash('d'), workspaceHash('d','x')]"),
                       ##"["#/w/d/room","#/w/d/room/x","#/w/d","#/w/d/room/x"]"##, "workspaceHash is Home; with a label, that room")
        XCTAssertEqual(js("parse('#/w/d/home')"), "null", "Home has one address")
        // The Workspaces page: its address, served, and drawn from the listing alone (no workspace's own read, no message).
        XCTAssertEqual(js("[parse('#/workspaces').view, hashFor('workspaces'), canonical('#/workspaces')]"), ##"["workspaces","#/workspaces","#/workspaces"]"##)
        for m in ["views/workspaces", "components/ws-next"] { XCTAssertTrue(a.assets.keys.contains { $0.hasPrefix("/assets/app/\(m)-") }, "\(m) is served") }
        let wsl = try read("app/views/workspaces.js")
        XCTAssertTrue(wsl.contains("loadWorkspaces(0)") && !wsl.contains("loadWorkspace(") && !wsl.contains("api("), "one listing read")
        XCTAssertTrue(wsl.contains("'doz.workspaces.layout'") && wsl.contains("'doz.workspaces.sort'"))
        XCTAssertTrue(try read("index.html").contains(##"<a class="ng-label" href="#/workspaces" data-nav="workspaces""##), "the sidebar's heading leads there")
        for (hash, session) in [("#/w/demo/agent/gamma", nil), ("#/w/demo/agent/gamma/~home", "~home"), ("#/w/demo/agent/bot_1.a/claude-2", "claude-2")] as [(String, String?)] {
            let p = parsed(hash)
            XCTAssertEqual(p?["view"] as? String, "wsagent", hash)
            XCTAssertEqual(p?["param"] as? String, "demo", hash)
            XCTAssertEqual(p?["agent"] as? String, hash.split(separator: "/")[4].description, hash)
            XCTAssertEqual(p?["session"] as? String, session, hash)
        }
        XCTAssertEqual(js("parse('#/w/demo/agent/gamma/can-do').tab"), #""can-do""#, "Can do: an address of its own")
        XCTAssertEqual(js("canonical('#/w/demo/agent/gamma/can-do')"), "\"#/w/demo/agent/gamma/can-do\"")
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

    /// Add a worker: its modules served; the address parses; core/add-worker.js is pure and builds exactly the request
    /// `doz worker add` takes (only what differs from its defaults; unfenced never from a default; the tools only for a
    /// fenced Claude Code worker of its own place); the pages send exactly `worker-add` (the page) and `worker-end` (End…),
    /// nothing else sends a worker action; the page asks the plan route, the latest answer winning, and confirms unfenced.
    func testTheAddWorkerPage() throws {
        let src = Self.root.appendingPathComponent("Sources/DozableWeb/WebSource")
        let read = { (f: String) in try String(contentsOf: src.appendingPathComponent(f), encoding: .utf8) }
        let a = try WebAssets.load()
        for m in ["views/add-worker", "core/add-worker", "components/worker-end"] {
            XCTAssertTrue(a.assets.keys.contains { $0.hasPrefix("/assets/app/\(m)-") }, "\(m) is served")
        }
        let ctx = try XCTUnwrap(JSContext())
        var thrown: String?
        ctx.exceptionHandler = { _, e in thrown = e?.toString() }
        ctx.evaluateScript(try read("app/core/routes.js").replacingOccurrences(of: "export ", with: ""))
        let pure = try read("app/core/add-worker.js")
        XCTAssertTrue(Self.specifiers(pure).isEmpty, "core/add-worker.js is pure: it imports nothing")
        ctx.evaluateScript(pure.replacingOccurrences(of: "export ", with: ""))
        XCTAssertNil(thrown, thrown ?? "")
        func js(_ expr: String) -> String { ctx.evaluateScript("JSON.stringify(" + expr + ")")?.toString() ?? "?" }
        XCTAssertEqual(js("[parse('#/w/demo/agents/new').view, parse('#/w/demo/agents/new').param]"), #"["addworker","demo"]"#)
        XCTAssertEqual(js("addWorkerHash('demo')"), ##""#/w/demo/agents/new""##)
        XCTAssertEqual(js("parse('#/w/demo/agents').tab"), #""agents""#, "the Agents tab is unchanged")
        XCTAssertEqual(js("parse('#/w/Demo/agents/new')"), "null")
        XCTAssertEqual(js("[defaultColumn(null, null), defaultColumn('vm', null), defaultColumn(null, 'vm'), defaultColumn('unfenced', 'unfenced')]"),
                       #"["fenced","vm","vm","fenced"]"#, "never unfenced from a default")
        let base = "{workspace:'w', task:'list the files', who:'anon', agent:'claude-code', place:'own', column:'fenced', picked:false, rooms:[], tools:[]"
        XCTAssertEqual(js("workerRequestFrom(" + base + "})"), #"{"workspace":"w","task":"list the files"}"#, "the CLI's defaults are not sent")
        XCTAssertEqual(js("workerRequestFrom(" + base + ", name:' carl ', agent:'codex', column:'vm', picked:true, cpus:'4', memory:'4G', rooms:['review']})"),
                       #"{"workspace":"w","task":"list the files","name":"carl","agent":"codex","isolation":"vm","cpus":4,"memory":"4G","rooms":["review"]}"#)
        XCTAssertEqual(js("workerRequestFrom(" + base + ", who:'bot', bot:'otto', name:'x', agent:'codex'})"), #"{"workspace":"w","task":"list the files","fromBot":"otto"}"#)
        XCTAssertEqual(js("workerRequestFrom(" + base + ", place:'wsa', column:'unfenced', picked:true, cpus:'2'})"), #"{"workspace":"w","task":"list the files","sandbox":"wsa"}"#)
        XCTAssertEqual(js("workerRequestFrom(" + base + ", tools:['Edit', 'Bash(dozchat:*)']})"), #"{"workspace":"w","task":"list the files","allowTools":["Edit"]}"#)
        XCTAssertEqual(js("workerRequestFrom(" + base + ", tools:['Edit'], column:'vm'})"), #"{"workspace":"w","task":"list the files"}"#, "tools only fenced")
        XCTAssertEqual(js("['task','name','fromBot','sandbox','isolation','cpus','memory','allowTools','rooms','agent','workspace'].map(fieldSlot)"),
                       #"["task","name","who","in","where","size","size","tools","rooms","agent","top"]"#)
        XCTAssertEqual(js("[fits({workspace:'w', task:'x'.repeat(15360)}), fits({workspace:'w', task:'x'.repeat(15361)}), utf8Length('é🎬')]"), "[true,false,6]")
        XCTAssertEqual(js("FIXED_TOOLS"), #"["Bash(dozchat:*)"]"#)
        XCTAssertEqual(js("FIXED_TOOLS"), "[\"" + WorkerLaunch.defaultAllowedTools.joined(separator: "\",\"") + "\"]", "the default allow-list, one constant")
        XCTAssertEqual(js("UNFENCED_TICK"), #""It acts as you: your files, Keychain and network""#)
        // What the pages send: the page exactly worker-add, End… exactly worker-end; nothing else a worker action.
        let files = (FileManager.default.enumerator(atPath: src.appendingPathComponent("app").path)?.allObjects as? [String] ?? [])
            .filter { $0.hasSuffix(".js") }.map { "app/" + $0 } + ["app.js"]
        let action = try NSRegularExpression(pattern: #"action: '(worker-[a-z]+)'"#)
        func sent(_ f: String) throws -> Set<String> {
            let t = try read(f)
            return Set(action.matches(in: t, range: NSRange(t.startIndex..., in: t)).map { (t as NSString).substring(with: $0.range(at: 1)) })
        }
        XCTAssertEqual(try sent("app/views/add-worker.js"), ["worker-add"])
        XCTAssertEqual(try sent("app/components/worker-end.js"), ["worker-end"])
        // (core/add-worker.js only measures the body it would be: `fits`.)
        for f in files where !["app/views/add-worker.js", "app/components/worker-end.js", "app/core/add-worker.js"].contains(f) {
            XCTAssertEqual(try sent(f), [], "\(f) sends a worker action")
        }
        let page = try read("app/views/add-worker.js")
        XCTAssertTrue(page.contains("api('worker-plan'"), "the plan route")
        XCTAssertTrue(page.contains("new AbortController()"), "the latest plan wins")
        XCTAssertTrue(page.contains("const PLAN_WAIT_MS = 300;"), "debounced 300 ms")
        XCTAssertTrue(page.contains("if (aw.f.place === 'own' && aw.f.column === 'unfenced') body.confirm = 'unfenced';"), "unfenced confirmed, only unfenced")
        XCTAssertTrue(page.contains("isolationChip(c.chip)"), "every column heading is a chip to the guide")
        XCTAssertFalse(page.contains("localStorage") || page.contains("sessionStorage"), "nothing kept in the browser")
        for f in ["app/views/ws-agents.js", "app/components/ws-panel.js"] {
            XCTAssertTrue(try read(f).contains("addWorkerLink("), "\(f): + Add a worker opens the page")
        }
        XCTAssertFalse(try read("app/views/ws-agents.js").contains("End: copy the command"), "End is the action now")
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
        // 742: and the one lazy literal, its hashed vendored path back to what the source names.
        let unhash = { (t: String) in t.replacingOccurrences(of: #"import\('/assets/vendor-space-render-[0-9a-f]{16}\.js'\)"#, with: "import('/vendor/space-editor/space-render.js')", options: .regularExpression)
            .replacingOccurrences(of: #"-[0-9a-f]{16}\.js'"#, with: ".js'", options: .regularExpression) }
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
    // MARK: 742 — the space renderer, vendored at its peer commit, loaded by the ONE lazy import()

    static let peer = "Sources/DozableWeb/WebSource/vendor/space-editor"

    /// What ships: the renderer at its PIN's sha, under one hashed name, loaded only by core/space-pictures.js's one literal
    /// (rewritten); the `.d.ts` never shipped; its licences bundled; the first load (index.html, sw.js) never names it; no
    /// other module holds an import(); ghostty-web and Lucide unchanged.
    func testTheSpaceRendererShipsAtItsPinAndLoadsOnlyLazily() throws {
        let a = try WebAssets.load()
        let pin = try String(contentsOf: Self.root.appendingPathComponent(Self.peer + "/PIN"), encoding: .utf8)
        let sha = try XCTUnwrap(pin.split(separator: "\n").first { $0.hasSuffix("  space-render.js") }.map { String($0.prefix(64)) })
        let path = "/assets/vendor-space-render-\(sha.prefix(16)).js"
        XCTAssertEqual(a.assets[path]?.sha256, sha, "ships at its pin")
        XCTAssertFalse(a.assets.keys.contains { $0.hasSuffix(".d.ts") || $0.contains("space-render.d") }, "the .d.ts is never shipped")
        for doc in ["/", WebAssets.serviceWorker] {
            XCTAssertFalse(String(decoding: a.assets[doc]!.data, as: UTF8.self).contains("vendor-space-render"), "\(doc) never names it")
        }
        var lazy: [String: Int] = [:]
        for (p, asset) in a.assets where p.hasPrefix("/assets/app") && p.hasSuffix(".js") {
            let t = String(decoding: asset.data, as: UTF8.self)
            let n = t.components(separatedBy: "import(").count - 1
            if n > 0 { lazy[p] = n }
            if n > 0 { XCTAssertTrue(t.contains("import('\(path)')"), "\(p) loads the hashed path") }
        }
        XCTAssertEqual(lazy.count, 1, "one module holds an import(): \(lazy.keys.sorted())")
        XCTAssertTrue(lazy.keys.first?.hasPrefix("/assets/app/core/space-pictures-") == true)
        XCTAssertEqual(lazy.values.first, 1, "exactly once")
        let web = Self.root.appendingPathComponent("Sources/DozableWeb/Resources/Web/licences")
        for l in ["space-editor", "yaml", "lucide-static"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: web.appendingPathComponent("space-editor-LICENSES-\(l).txt").path), "\(l)'s licence ships")
        }
        XCTAssertEqual(a.assets.keys.filter { $0.hasPrefix("/assets/vendor-ghostty-") }.count, 2, "ghostty-web unchanged")
        XCTAssertEqual(a.assets.keys.filter { $0.hasPrefix("/assets/vendor-lucide-icons-") }.count, 1, "Lucide unchanged")
    }

    /// Re-pins a changed vendored file in the scratch copy (VENDOR.json, the PIN line, the PIN's sha) — so a refusal is
    /// about what the file holds, not its pin.
    static func repin(_ src: URL, _ file: String, _ data: Data) throws {
        let dir = src.appendingPathComponent("vendor/space-editor")
        let old = WebAssets.sha256Hex(try Data(contentsOf: dir.appendingPathComponent(file)))
        try data.write(to: dir.appendingPathComponent(file))
        let new = WebAssets.sha256Hex(data)
        let pin = try String(contentsOf: dir.appendingPathComponent("PIN"), encoding: .utf8).replacingOccurrences(of: old + "  " + file, with: new + "  " + file)
        try Data(pin.utf8).write(to: dir.appendingPathComponent("PIN"))
        let pinOld = try String(contentsOf: dir.appendingPathComponent("VENDOR.json"), encoding: .utf8)
        let pinSha = WebAssets.sha256Hex(Data(pin.utf8))
        let json = pinOld.replacingOccurrences(of: old, with: new)
            .replacingOccurrences(of: #""pinSha256": "[0-9a-f]{64}""#, with: "\"pinSha256\": \"\(pinSha)\"", options: .regularExpression)
        try Data(json.utf8).write(to: dir.appendingPathComponent("VENDOR.json"))
    }
    static func edit(_ src: URL, _ rel: String, _ f: (String) -> String) throws {
        let u = src.appendingPathComponent(rel)
        try Data(f(try String(contentsOf: u, encoding: .utf8)).utf8).write(to: u)
    }

    func testTheCompilerAdmitsThePeerVendorOnlyAtItsPinAndCommit() throws {
        func refused(_ what: String, _ expect: String, _ change: (URL) throws -> Void) throws {
            let (status, out) = try compileScratch(change)
            XCTAssertNotEqual(status, 0, what)
            XCTAssertTrue(out.contains(expect), "\(what): \(out)")
        }
        let v = "vendor/space-editor/"
        try refused("one changed byte in space-render.js", "is not the pinned file") { src in
            let u = src.appendingPathComponent(v + "space-render.js")
            var d = try Data(contentsOf: u); d[d.count - 2] ^= 0x01; try d.write(to: u)
        }
        try refused("one changed byte in the PIN", "is not the pinned PIN") { src in
            let u = src.appendingPathComponent(v + "PIN")
            var d = try Data(contentsOf: u); d[0] = d[0] == 0x30 ? 0x31 : 0x30; try d.write(to: u)
        }
        try refused("an unlisted LICENSES/x.txt", "does not pin") { src in
            try Data("x\n".utf8).write(to: src.appendingPathComponent(v + "LICENSES/x.txt"))
        }
        try refused("a listed file the PIN lacks", "is not the file its PIN names") { src in
            let x = Data("extra\n".utf8)
            try x.write(to: src.appendingPathComponent(v + "LICENSES/extra.txt"))
            try Self.edit(src, v + "VENDOR.json") { $0.replacingOccurrences(of: "\"files\": [", with: "\"files\": [\n    { \"file\": \"LICENSES/extra.txt\", \"sha256\": \"\(WebAssets.sha256Hex(x))\", \"serve\": \"reference\" },") }
        }
        try refused("a short commit", "the full 40-character hash") { src in
            try Self.edit(src, v + "VENDOR.json") { $0.replacingOccurrences(of: #""commit": "[0-9a-f]{40}""#, with: "\"commit\": \"7d482af\"", options: .regularExpression) }
        }
        try refused("a licence off the allowlist", "is not on the allowlist") { src in
            try Self.edit(src, v + "VENDOR.json") { $0.replacingOccurrences(of: "\"licence\": \"ISC\", \"licenceFile\": \"LICENSES/yaml.txt\"", with: "\"licence\": \"GPL-3.0\", \"licenceFile\": \"LICENSES/yaml.txt\"") }
        }
        try refused("a flat module that imports", "holds an import") { src in
            let d = try Data(contentsOf: src.appendingPathComponent(v + "space-render.js"))
            try Self.repin(src, "space-render.js", Data("import{x}from'./x.js';".utf8) + d)
        }
        try refused("a flat module with import.meta", "holds import.meta") { src in
            let d = try Data(contentsOf: src.appendingPathComponent(v + "space-render.js"))
            try Self.repin(src, "space-render.js", d + Data("\nconst u=import.meta.url;".utf8))
        }
        // Re-pinned whole (file, PIN line, PIN sha), a changed renderer is admitted — the pin is what admits it.
        let ok = try compileScratch { src in
            let d = try Data(contentsOf: src.appendingPathComponent(v + "space-render.js"))
            try Self.repin(src, "space-render.js", d + Data("\n".utf8))
        }
        XCTAssertEqual(ok.0, 0, ok.1)
    }

    /// The one lazy import(): accepted only as the one literal in core/space-pictures.js (rewritten to the hashed path);
    /// refused as a second one, in another module, in a comment, as a template, a variable or another literal, and a
    /// '/vendor/…' string anywhere else.
    func testTheOneLazyImportIsTheCompilersTables() throws {
        func refused(_ what: String, _ expect: String, _ change: (URL) throws -> Void) throws {
            let (status, out) = try compileScratch(change)
            XCTAssertNotEqual(status, 0, what)
            XCTAssertTrue(out.contains(expect), "\(what): \(out)")
        }
        let lit = "import('/vendor/space-editor/space-render.js')"
        let pics = "app/core/space-pictures.js"
        try refused("a second one", "exactly once") { src in try Self.edit(src, pics) { $0 + "\nexport const again = () => \(lit);\n" } }
        try refused("none", "exactly once") { src in try Self.edit(src, pics) { $0.replacingOccurrences(of: lit, with: "Promise.reject(new Error('x'))") } }
        try refused("in another module", "uses import()") { src in try Self.add(src, "core/zz-a.js", "export const a = () => \(lit);\n") }
        try refused("in a comment", "beyond its one lazy literal") { src in try Self.edit(src, pics) { $0 + "\n// later: import('./x.js')\n" } }
        try refused("a template", "beyond its one lazy literal") { src in try Self.edit(src, pics) { $0 + "\nexport const t = () => import(`/vendor/space-editor/space-render.js`);\n" } }
        try refused("a variable", "beyond its one lazy literal") { src in try Self.edit(src, pics) { $0 + "\nexport const v = (p) => import(p);\n" } }
        try refused("another literal", "beyond its one lazy literal") { src in try Self.edit(src, pics) { $0 + "\nexport const o = () => import('/vendor/space-editor/other.js');\n" } }
        try refused("a /vendor/ string in another module", "names a /vendor/ path") { src in try Self.add(src, "core/zz-a.js", "export const a = '/vendor/space-editor/space-render.js';\n") }
        try refused("the table's module missing", "does not exist") { src in
            try FileManager.default.removeItem(at: src.appendingPathComponent(pics))
            try Self.edit(src, "app.js") { $0.replacingOccurrences(of: "import './app/core/space-pictures.js';\n", with: "") }
        }
    }
}
