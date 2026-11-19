import DozableHost
import Foundation
import XCTest
@testable import DozableWeb

/// The wide views' web side: each route is exactly one read-only HostOp the CLI also sends; strict bodies; no key shaped like a
/// secret in any answer; what another computer is shown (held secrets a count only, this Mac's sessions per serve.mac_sessions).
final class WebWorkspaceViewsTests: XCTestCase {
    func testEachRouteIsExactlyOneReadOnlyHostOpTheCLISends() throws {
        let reach = try WebWorkspaceViews.decodeReach(Data(#"{"workspace":"demo","agent":"mira"}"#.utf8))
        var want = WorkspaceRequest(name: "demo")
        want.agent = "mira"
        XCTAssertEqual(reach, want)
        let folders = try WebWorkspaceViews.decodeFolders(Data(#"{"workspace":"demo"}"#.utf8))
        XCTAssertEqual(folders, WorkspaceRequest(name: "demo"))
        let act = try WebWorkspaceViews.decodeActivity(Data(#"{"workspace":"demo"}"#.utf8))
        XCTAssertEqual(act.limit, WorkspaceLogPage.defaultLimit)
        XCTAssertNil(act.before)
        for (op, w) in [(HostOp.workspaceReach, reach), (.workspaceFolders, folders), (.workspaceLog, act)] {
            let r = WebWorkspaceViews.request(op, w)
            XCTAssertEqual(r.op, op)
            XCTAssertTrue(r.op.isReadOnly, "\(op.rawValue) is answered in-process with no daemon")
            XCTAssertNil(r.name, "the workspace never travels as a sandbox's name")
            XCTAssertEqual(r.workspaceRequest, w)
        }
    }

    func testStrictBodies() {
        for b in [#"{}"#, #"{"workspace":"-x"}"#, #"{"workspace":"demo","agent":".hidden"}"#, #"{"workspace":"demo","agent":"a b"}"#,
                  #"{"workspace":"demo","agent":"mira","x":1}"#, "[]", "not json", #"{"workspace":3}"#] {
            XCTAssertThrowsError(try WebWorkspaceViews.decodeReach(Data(b.utf8)), b)
        }
        for b in [#"{"workspace":"demo","agent":"mira"}"#, #"{}"#] { XCTAssertThrowsError(try WebWorkspaceViews.decodeFolders(Data(b.utf8)), b) }
        for b in [#"{"workspace":"demo","limit":501}"#, #"{"workspace":"demo","limit":"2"}"#, #"{"workspace":"demo","before":-3}"#,
                  #"{"workspace":"demo","since":0}"#] {
            XCTAssertThrowsError(try WebWorkspaceViews.decodeActivity(Data(b.utf8)), b)
        }
        // A refusal never echoes the value.
        do { _ = try WebWorkspaceViews.decodeReach(Data(#"{"workspace":"demo","agent":"<script>"}"#.utf8)) } catch let e as WebAction.Invalid {
            XCTAssertFalse(e.message.contains("<script>"))
        } catch { XCTFail("\(error)") }
    }

    static func reach() -> WorkspaceReach {
        let held = [HeldSecret(name: "MUSIC_API_TOKEN", to: "api.music.example:443", header: "authorization (Bearer)", fingerprint: "abcdef012345", kind: "given"),
                    HeldSecret(name: "CHAT_TOKEN", to: "host.dozable.internal:4000", header: "authorization (Bearer)", fingerprint: "c0ffee000111", kind: "chat-bot")]
        func a(_ n: String, _ kind: String) -> AgentReach {
            AgentReach(name: n, role: "manager", isolation: kind == "mac" ? "fenced" : "vm", place: kind == "mac" ? "@mac/" + n : n, kind: kind,
                       control: "x", actsAsYou: false, state: "running", capabilities: [], network: .none, held: held, folders: [], account: "mac", rooms: ["demo"])
        }
        return WorkspaceReach(workspace: "demo", agents: [a("vmw", "sandbox"), a("mira", "mac")], defaults: .init(isolation: "fenced", network: "locked"),
                              refusalsKnown: true)
    }

    func testNoAnswerHasASecretShapedKeyAndNoChatTokensFingerprint() throws {
        let page = WorkspaceLogPage(entries: [WorkspaceLogEntry(action: "manager-started", agent: "mira", sha256: "deadbeef", fingerprint: "c0ffee000111")], first: 0, more: false)
        let f = WorkspaceFolders(workspace: "demo", since: Date(), folders: [], points: [])
        let values: [any Encodable] = [WebWorkspaceReach(Self.reach()), WebWorkspaceFolders(f), WebWorkspaceActivity(page, macAllowed: true)]
        for v in values {
            let obj = try JSONSerialization.jsonObject(with: try WebJSON.encoder.encode(v))
            var keys: [String] = []
            func walk(_ x: Any) {
                if let d = x as? [String: Any] { for (k, v) in d { keys.append(k.lowercased()); walk(v) } }
                if let a = x as? [Any] { a.forEach(walk) }
            }
            walk(obj)
            for k in keys { for word in ["token", "secret", "password", "value", "sha256", "hash"] { XCTAssertFalse(k.contains(word), "\(k)") } }
            let text = String(decoding: try WebJSON.encoder.encode(v), as: UTF8.self)
            XCTAssertFalse(text.contains("c0ffee000111"), "a chat token's fingerprint: \(text)")
            XCTAssertFalse(text.contains("deadbeef"))
        }
    }

    func testAnotherComputerSeesHeldSecretsAsACountAndThisMacsAgentsPerTheSetting() throws {
        let r = WebWorkspaceReach(Self.reach())
        XCTAssertEqual(r.agents[0].held.map(\.name), ["MUSIC_API_TOKEN", "CHAT_TOKEN"])
        XCTAssertEqual(WebWorkspaceReach.forBrowser(r, remote: false, macAllowed: false), r, "this Mac's own browser sees it all")
        let watch = WebWorkspaceReach.forBrowser(r, remote: true, macAllowed: true)
        XCTAssertEqual(watch.agents.map(\.name), ["vmw", "mira"])
        XCTAssertTrue(watch.agents.allSatisfy { $0.held.isEmpty && $0.heldCount == 2 })
        let off = WebWorkspaceReach.forBrowser(r, remote: true, macAllowed: false)
        XCTAssertEqual(off.agents.map(\.name), ["vmw"])
        XCTAssertEqual(off.hidden, 1)
        let text = String(decoding: try WebJSON.encoder.encode(off), as: UTF8.self)
        XCTAssertFalse(text.contains("MUSIC_API_TOKEN") || text.contains("@mac"), text)
        // Folders: a folder only this Mac's session works in keeps its path, not its changes.
        let f = WorkspaceFolders(workspace: "demo", since: Date(), folders: [
            .init(path: "/w/main", mode: "rw", main: true, workspace: true, exists: true, rules: .init(ignore: nil, readonly: nil), agents: ["vmw"],
                  changes: [WorkspaceFileChange(kind: "A", path: "a")], count: 1, truncated: false, scanned: 1, hidden: nil),
            .init(path: "/w/side", mode: "rw", main: false, workspace: false, exists: true, rules: .init(ignore: nil, readonly: nil), agents: ["mira"],
                  changes: [WorkspaceFileChange(kind: "M", path: "private-name")], count: 1, truncated: false, scanned: 1, hidden: nil),
        ], points: [])
        let wf = WebWorkspaceFolders.forBrowser(WebWorkspaceFolders(f), macAllowed: false, macAgents: ["mira"])
        XCTAssertEqual(wf.folders[0].changes.count, 1)
        XCTAssertTrue(wf.folders[1].hidden)
        XCTAssertEqual(wf.folders[1].changes, [])
        XCTAssertEqual(wf.folders[1].agents, [])
        XCTAssertEqual(WebWorkspaceFolders.forBrowser(WebWorkspaceFolders(f), macAllowed: true, macAgents: ["mira"]), WebWorkspaceFolders(f))
        // Activity: the lines about this Mac's sessions counted, not shown.
        let page = WorkspaceLogPage(entries: [WorkspaceLogEntry(action: "adopted", agent: "s", place: "mac:s"), WorkspaceLogEntry(action: "created")], first: 5, more: true)
        let act = WebWorkspaceActivity(page, macAllowed: false)
        XCTAssertEqual(act.lines.map(\.action), ["created"])
        XCTAssertEqual(act.hidden, 1)
        XCTAssertEqual(act.first, 5)
        XCTAssertTrue(act.more)
    }
}
