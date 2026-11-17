import DozableChat
import Foundation
import XCTest

/// Who may call what (the protocol's access rules), as one table per port, and `agent_addresses`.
final class ChatAccessTests: XCTestCase {
    func access(owned: [String] = ["127.0.0.1"], allow: [String] = [], requireTokens: Bool = false, from: [String] = [],
                agents: [String] = []) -> ChatAccess {
        var c = ChatConfig()
        c.testOwnedAddresses = owned
        c.allow = allow
        c.requireTokens = requireTokens
        c.requireTokensFrom = from
        c.agentAddresses = agents
        return c.access
    }

    let notOwned = ChatAccess.notOwned
    let agentOnly = ChatAccess.agentOnly

    func testTheTwoTextsAreExact() {
        XCTAssertEqual(notOwned, "only the owner's own tailnet machines may connect")
        XCTAssertEqual(agentOnly, "this machine must use a token: only /agent/ calls are served to it")
    }

    /// The page port: nil serves; otherwise the 403 text.
    func testThePagePortTable() {
        struct Row { let name: String; let a: ChatAccess; let ip: String; let agentPath: Bool; let want: String? }
        let rows: [Row] = [
            Row(name: "owned, a page call", a: access(), ip: "127.0.0.1", agentPath: false, want: nil),
            Row(name: "owned, an agent call", a: access(), ip: "127.0.0.1", agentPath: true, want: nil),
            Row(name: "not owned, a page call", a: access(owned: ["127.0.0.2"]), ip: "127.0.0.1", agentPath: false, want: notOwned),
            Row(name: "not owned, an agent call", a: access(owned: ["127.0.0.2"]), ip: "127.0.0.1", agentPath: true, want: notOwned),
            Row(name: "allowed but not owned", a: access(owned: ["127.0.0.2"], allow: ["127.0.0.1"]), ip: "127.0.0.1", agentPath: false, want: notOwned),
            Row(name: "nothing owned (production)", a: access(owned: []), ip: "127.0.0.1", agentPath: false, want: notOwned),
            Row(name: "owned, on require_tokens_from, a page call", a: access(from: ["127.0.0.1"]), ip: "127.0.0.1", agentPath: false, want: agentOnly),
            Row(name: "owned, on require_tokens_from, an agent call", a: access(from: ["127.0.0.1"]), ip: "127.0.0.1", agentPath: true, want: nil),
            Row(name: "require_tokens_from as a range", a: access(from: ["127.0.0.0/8"]), ip: "127.0.0.1", agentPath: false, want: agentOnly),
            Row(name: "require_tokens_from another address", a: access(from: ["127.0.0.2"]), ip: "127.0.0.1", agentPath: false, want: nil),
            Row(name: "an IPv4-mapped caller is its IPv4 address", a: access(), ip: "::ffff:127.0.0.1", agentPath: false, want: nil),
        ]
        for r in rows { XCTAssertEqual(r.a.page(remote: r.ip, agentPath: r.agentPath), r.want, r.name) }
    }

    /// The line port: nil closes at once; otherwise whether a token is required.
    func testTheLinePortTable() {
        struct Row { let name: String; let a: ChatAccess; let ip: String; let want: Bool? }
        let rows: [Row] = [
            Row(name: "owned: no token needed", a: access(), ip: "127.0.0.1", want: false),
            Row(name: "owned, require_tokens on", a: access(requireTokens: true), ip: "127.0.0.1", want: true),
            Row(name: "owned, on require_tokens_from", a: access(from: ["127.0.0.1"]), ip: "127.0.0.1", want: true),
            Row(name: "not owned, not allowed: closed", a: access(owned: ["127.0.0.2"]), ip: "127.0.0.1", want: nil),
            Row(name: "allowed, not owned: a token", a: access(owned: ["127.0.0.2"], allow: ["127.0.0.1"]), ip: "127.0.0.1", want: true),
            Row(name: "nothing owned, loopback allowed (production): a token", a: access(owned: [], allow: ["127.0.0.1"]), ip: "127.0.0.1", want: true),
        ]
        for r in rows { XCTAssertEqual(r.a.line(remote: r.ip), r.want, r.name) }
    }

    /// The exact path check: what a router would tidy is refused, not followed.
    func testTheAgentPathIsExact() {
        let yes = ["/agent/receive", "/agent/register", "/agent/send?x=1".components(separatedBy: "?")[0]]
        let no = ["/agent/../api/state", "/agent//receive", "/Agent/receive", "/agent/./receive", "/agent/receive/", "/agent",
                  "/api/state", "/", "/agent/%2e%2e/api/state", "/%61gent/receive"]
        for p in yes { XCTAssertTrue(ChatPath.isAgentPath(rawPath: p), p) }
        for p in no { XCTAssertFalse(ChatPath.isAgentPath(rawPath: p), p) }
    }

    func testGoPathClean() {
        for (p, want) in [("/a/b/../c", "/a/c"), ("/a//b", "/a/b"), ("/a/./b/", "/a/b"), ("/../a", "/a"), ("/", "/"), ("", "."), ("a/../..", "..")] {
            XCTAssertEqual(ChatPath.clean(p), want, p)
        }
    }

    // MARK: agent_addresses — callers that are never the human

    func testAgentAddressesGetOnlyTheAgentCallsOnThePagePort() {
        let a = access(owned: ["127.0.0.1"], agents: ["127.0.0.1/8", "::1"])
        XCTAssertEqual(a.page(remote: "127.0.0.1", agentPath: false), agentOnly, "owned AND an agent address: an agent address")
        XCTAssertNil(a.page(remote: "127.0.0.1", agentPath: true), "the token-checked /agent/ calls are served")
        XCTAssertEqual(a.page(remote: "::1", agentPath: false), agentOnly)
        XCTAssertFalse(a.isOwned("127.0.0.1"), "an agent address is never the owner's own machine")
    }

    func testAgentAddressesAreServedTheAgentCallsEvenWhenNotOwned() {
        let a = access(owned: [], agents: ["127.0.0.1"])
        XCTAssertNil(a.page(remote: "127.0.0.1", agentPath: true))
        XCTAssertEqual(a.page(remote: "127.0.0.1", agentPath: false), agentOnly)
        XCTAssertEqual(a.page(remote: "127.0.0.2", agentPath: false), notOwned, "an address outside the list keeps the usual rule")
    }

    func testAgentAddressesAlwaysNeedATokenOnTheLinePort() {
        XCTAssertNil(access(owned: ["127.0.0.1"], agents: ["127.0.0.1"]).line(remote: "127.0.0.1"),
                     "an agent address is not owned, so without allow it is closed")
        XCTAssertEqual(access(owned: [], allow: ["127.0.0.1"], agents: ["127.0.0.1"]).line(remote: "127.0.0.1"), true)
        XCTAssertEqual(access(owned: ["127.0.0.1"], allow: ["127.0.0.1"], agents: ["127.0.0.1/8"]).line(remote: "127.0.0.1"), true)
    }

    func testNoAgentAddressesIsTodaysBehaviour() {
        let a = access(owned: ["127.0.0.1"], agents: [])
        XCTAssertNil(a.page(remote: "127.0.0.1", agentPath: false))
        XCTAssertEqual(a.line(remote: "127.0.0.1"), false)
        XCTAssertFalse(a.isAgentAddress("127.0.0.1"))
    }

    // MARK: the same rules through the page handler

    func core(_ extra: String) throws -> ChatServerCore {
        var c = try ChatConfig.parse(Data(ChatConfigTests.contract(extra).utf8))
        c.dataDir = FileManager.default.temporaryDirectory.appendingPathComponent("chat-access-\(UUID().uuidString)").path
        addTeardownBlock { [dir = c.dataDir] in try? FileManager.default.removeItem(atPath: dir) }
        // Never the person's own Claude folder: a scratch one that does not exist.
        return ChatServerCore(config: c, secrets: ChatSecrets(), release: "1.2.3",
                              sessionsDir: (c.dataDir as NSString).appendingPathComponent("no-sessions"))
    }

    /// The served protocol text is the reference's, byte for byte, so both servers announce the same version
    /// (the reference's 0.13.2). A change here is a protocol change agents are told about.
    func testTheProtocolVersionIsTheReferences() {
        XCTAssertEqual(ChatProtocol.version, "da04ef349a")
    }

    func testThePageHandlerAppliesTheRulesAndTheHeader() throws {
        let h = ChatPageHandler(core: try core(#", "agent_addresses": ["127.0.0.1"]"#))
        let r = h.handle(ChatHTTPRequest(method: "GET", target: "/api/state", remoteIP: "127.0.0.1"))
        XCTAssertEqual(r.status, 403)
        XCTAssertEqual(r.text, agentOnly + "\n")
        XCTAssertEqual(r.header("Strict-Transport-Security"), "max-age=0")
        XCTAssertEqual(r.header("Content-Type"), "text/plain; charset=utf-8")
        let agent = h.handle(ChatHTTPRequest(method: "GET", target: "/agent/receive", remoteIP: "127.0.0.1"))
        XCTAssertEqual(agent.status, 401)
        XCTAssertEqual(agent.text, #"{"error":"these calls need a token: Authorization: Bearer \u003ctoken\u003e"}"# + "\n")
        let tidy = h.handle(ChatHTTPRequest(method: "GET", target: "/agent/../api/state", remoteIP: "127.0.0.1"))
        XCTAssertEqual(tidy.status, 403, "an untidy /agent/ path is refused, not followed")

        let owned = ChatPageHandler(core: try core(""))
        let state = owned.handle(ChatHTTPRequest(method: "GET", target: "/api/state", remoteIP: "127.0.0.1"))
        XCTAssertEqual(state.status, 200)
        XCTAssertEqual(state.header("Strict-Transport-Security"), "max-age=0")
        let notOwnedCaller = owned.handle(ChatHTTPRequest(method: "GET", target: "/api/state", remoteIP: "127.0.0.2"))
        XCTAssertEqual(notOwnedCaller.text, notOwned + "\n")
    }
}
