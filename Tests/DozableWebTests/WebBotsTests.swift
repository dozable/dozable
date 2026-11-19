import Foundation
import XCTest
import DozableKit
import DozableHost
@testable import DozableWeb

/// The dashboard's Agents / Bots reads: each route is exactly one read-only HostOp the CLI also sends; the answers are
/// projections that never carry a token (who keeps it and a fingerprint of at most 12 hex), never a hash of the
/// instructions; a name off the chat rule is refused before any call, never echoed; another computer that may not see this
/// Mac's sessions gets none of them. (The HTTP side: `ServeHTTPTests.testABotIsReadRemotelyWithoutThisMacsSessions`.)
final class WebBotsTests: XCTestCase {
    func testEveryBotRouteIsExactlyTheCLIsReadOnlyRequest() throws {
        var ls = HostRequest(.botList)
        ls.botRequest = BotRequest()
        var retired = BotRequest()
        retired.retired = true
        var lsRetired = HostRequest(.botList)
        lsRetired.botRequest = retired                                   // doz bot ls --retired
        var shown = BotRequest(name: "mira")
        shown.withInstructions = true
        var show = HostRequest(.botShow)
        show.botRequest = shown                                          // doz bot show mira --instructions
        for (route, want) in [(WebRoute.bots, ls), (.botsRetired, lsRetired), (.bot("mira"), show)] {
            let r = try XCTUnwrap(WebWorkspaceReads.request(for: route))
            XCTAssertEqual(r, want, "\(route)")
            XCTAssertEqual(WebBotReads.request(for: route), want)
            XCTAssertTrue(r.op.isReadOnly, "looking never starts the daemon")
            XCTAssertNil(r.secret)
            XCTAssertNil(r.botRequest?.heldOnly, "a read changes nothing")
            XCTAssertEqual(WebExposure.kind(route), .read)
        }
        XCTAssertNil(WebBotReads.request(for: .workspaces))
    }

    func testTheRoutesParse() {
        XCTAssertEqual(WebRoute.parse(method: .get, target: "/api/v1/bots"), .bots)
        XCTAssertEqual(WebRoute.parse(method: .get, target: "/api/v1/bots?retired=1"), .botsRetired)
        XCTAssertEqual(WebRoute.parse(method: .get, target: "/api/v1/bots/mira"), .bot("mira"))
        for bad in ["/api/v1/bots?retired=1&x=2", "/api/v1/bots?retired=true", "/api/v1/bots/mira/identity", "/api/v1/bots/mira?x", "/api/v1/bots/%7Enew"] {
            XCTAssertNil(WebRoute.parse(method: .get, target: bad), bad)
        }
        for p in ["/api/v1/bots/mira", "/api/v1/bots?retired=1"] {
            XCTAssertNil(WebRoute.parse(method: .post, target: p), "\(p): a read only")
        }
    }

    func testANameOffTheChatRuleIsRefusedWithoutEchoingIt() {
        XCTAssertNoThrow(try WebBotReads.checkName("mira"))
        for bad in ["", "Mira", "-x", "a_b", "chat", "~new", String(repeating: "a", count: 41), "<script>"] {
            XCTAssertThrowsError(try WebBotReads.checkName(bad), bad) { e in
                let m = (e as? WebAction.Invalid)?.message ?? ""
                XCTAssertFalse(bad.count > 1 && m.contains(bad), "never echoed")
            }
        }
    }

    static let t = Date(timeIntervalSince1970: 1_800_000_000)
    static func detail(fingerprint: String? = "3f9a01b2c3c2", keeper: String = "dozable", session: String? = nil) -> BotDetail {
        let rec = BotRecord(name: "mira", createdAt: t, origin: "adopted", agent: "claude-code", model: "opus", account: "mac", avatar: "🦊",
                            isolation: BotIsolation(default: "unfenced", ceiling: "fenced"), kind: "claude-session", deliver: session == nil ? "poll" : "inbox",
                            session: session, skills: ["chat-manager"],
                            instructions: BotInstructions(sha256: String(repeating: "c", count: 64), bytes: 10, updatedAt: t),
                            token: BotTokenState(keeper: keeper, fingerprint: fingerprint, at: t))
        var d = BotDetail(rec, inChat: true, workspaces: ["launch-video"], manages: ["launch-video"],
                          notes: session.map { ["inbox reaches the session \($0) on this Mac"] })
        d.running = "launch-video"
        d.instructionsText = "Be brief.\n"
        return d
    }

    func testTheDetailProjection() throws {
        let p = WebBotDetail(Self.detail())
        XCTAssertEqual(p.name, "mira")
        XCTAssertEqual(p.avatar, "🦊")
        XCTAssertEqual(p.origin, "adopted")
        XCTAssertEqual(p.instructions, "Be brief.\n")
        XCTAssertEqual(p.instructionsBytes, 10)
        XCTAssertEqual(p.isolation, "unfenced")
        XCTAssertTrue(p.actsAsYou)
        XCTAssertEqual(p.ceiling, "fenced", "read only")
        XCTAssertEqual(p.keeper, "dozable")
        XCTAssertEqual(p.fingerprint, "3f9a01b2c3c2")
        XCTAssertEqual(p.running, "launch-video")
        XCTAssertEqual(p.skills, ["chat-manager"])
        // A fingerprint not of the shape — longer, upper case, a token — is never passed on.
        for odd in ["3f9a01b2c3c2ff", "ABCDEF123456", "dzc_0123456789", ""] {
            XCTAssertNil(WebBotDetail(Self.detail(fingerprint: odd)).fingerprint, odd)
        }
        XCTAssertEqual(WebBotDetail(Self.detail(keeper: "something-new")).keeper, "none")
        // The text only when the record has instructions.
        var none = Self.detail()
        none.instructions = nil
        XCTAssertNil(WebBotDetail(none).instructions)
    }

    func testNoAnswerHasASecretShapedField() throws {
        var row = BotRow(name: "m", agent: "codex", model: nil, isolation: "vm", kind: "agent", deliver: "inbox", inChat: false,
                         manages: [], retiredAt: Self.t, avatar: "x", account: "mac", tokenKeeper: "dozable")
        let values: [any Encodable] = [WebBotDetail(Self.detail(session: "build")), WebBotListing(BotListing(bots: [row]))]
        for v in values {
            let text = String(decoding: try WebJSON.encoder.encode(v), as: UTF8.self)
            for word in ["token", "secret", "password", "key\"", "sha256", "hash"] {
                XCTAssertFalse(text.lowercased().contains(word), "\(word) in \(text)")
            }
            XCTAssertFalse(text.contains("dzc_"))
            XCTAssertFalse(text.contains("cccccccc"), "never the instructions' hash")
        }
        XCTAssertEqual(WebBotRow(row).keeper, "dozable")
        XCTAssertEqual(WebBotRow(row).account, "mac")
        row.tokenKeeper = "dzc_not-a-keeper"
        XCTAssertNil(WebBotRow(row).keeper, "only a known keeper word")
        row.tokenKeeper = nil
        XCTAssertNil(WebBotRow(row).keeper, "an older daemon: not known")
    }

    func testAnotherComputerGetsNoSessionOfThisMac() throws {
        let d = WebBotDetail(Self.detail(session: "secret-project"))
        XCTAssertEqual(d.session, "secret-project")
        let remote = WebBotReads.forBrowser(d, macAllowed: WebGridsRequest.macAllowed(.remote(secure: true), .off))
        XCTAssertNil(remote.session)
        XCTAssertEqual(remote.notes, [])
        XCTAssertEqual(remote.instructions, "Be brief.\n", "the instructions are your prose: read only, but shown")
        XCTAssertEqual(remote.fingerprint, d.fingerprint)
        let json = String(decoding: try WebJSON.encoder.encode(remote), as: UTF8.self)
        XCTAssertFalse(json.contains("secret-project"), json)
        XCTAssertEqual(WebBotReads.forBrowser(d, macAllowed: WebGridsRequest.macAllowed(.remote(secure: true), .watch)), d)
        XCTAssertEqual(WebBotReads.forBrowser(d, macAllowed: WebGridsRequest.macAllowed(.mac, .off)), d, "the Mac's own browser")
    }
}
