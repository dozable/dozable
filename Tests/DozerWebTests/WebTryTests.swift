import Foundation
import XCTest
@testable import DozerWeb
@testable import DozerHost
import DozerKit

/// 617 stage D: the Quick try page's server half — `POST /api/v1/plan` (strict), `GET /api/v1/try`, the create action's
/// `trial`, a provider's key on `POST /api/v1/accounts`, and the review's plan.
final class WebTryTests: XCTestCase {
    func q(_ json: String) throws -> WebPlanQuery { try WebPlanQuery.decode(Data(json.utf8)) }

    func testThePlanQuestionIsStrict() throws {
        let t = try q(#"{"purpose":"try","agent":"grok"}"#)
        XCTAssertEqual(t.request.purpose, "try")
        XCTAssertEqual(t.request.create.image, "grok", "the agent's own base (Debian for Grok) names the image as the CLI does")
        XCTAssertEqual(try q(#"{"agent":"gemini","base":"python"}"#).request.create.image, "python-gemini")
        XCTAssertEqual(try q(#"{"agent":"claude"}"#).request.create.image, "claude-code", "an alias")
        XCTAssertEqual(try q(#"{"agent":"grok","isolated":true}"#).request.create.isolated, true)
        XCTAssertEqual(try q(#"{"purpose":"new"}"#).request.create.image, "", "new with no agent: the defaults decide")
        for bad in [#"{"agent":"grok","shell":"rm -rf /"}"#, #"{"purpose":"create","agent":"grok"}"#, #"{"agent":"nope"}"#,
                    #"{"agent":"grok","base":"windows"}"#, #"{"agent":"grok","name":"Bad Name"}"#, #"{"agent":"grok","isolated":"yes"}"#,
                    #"{"purpose":"try"}"#, #"[1]"#] {
            XCTAssertThrowsError(try q(bad), bad)
        }
    }

    func testTheRoutesAreTypedAndAllowed() {
        XCTAssertEqual(WebRoute.parse(method: .post, target: "/api/v1/plan"), .plan)
        XCTAssertEqual(WebRoute.parse(method: .get, target: "/api/v1/try"), .tryCatalog)
        XCTAssertNil(WebRoute.parse(method: .get, target: "/api/v1/plan"), "the plan is a POST (CSRF)")
        XCTAssertEqual(WebExposure.kind(.plan), .change)
        XCTAssertEqual(WebExposure.kind(.tryCatalog), .read)
    }

    func testTheCatalogComesFromThePlansAndTheRecipes() async throws {
        var asked: [PlanRequest] = []
        let catalog = await WebTryCatalog.build(plan: { r in
            asked.append(r)
            var p = CreatePlan.sample(name: "try-" + r.create.image, image: r.create.image)
            // Grok has no key in this store; the others have one.
            p.problems = r.create.image == "grok"
                ? [PlanProblem(code: "key", text: "Grok Build needs an xAI API key", fix: "doz account add NAME --provider xai")] : []
            return WebPlan(p)
        }, secretEntry: true)
        XCTAssertTrue(asked.allSatisfy { $0.purpose == "try" })
        let ids = catalog.agents.map(\.id)
        XCTAssertTrue(ids.contains("grok") && ids.contains("gemini") && ids.contains("claude-code"), "\(ids)")
        XCTAssertFalse(ids.contains("none"))
        let grok = try XCTUnwrap(catalog.agents.first { $0.id == "grok" })
        XCTAssertEqual(grok.providerTitle, "xAI")
        XCTAssertEqual(grok.base, "Debian")
        let card = try XCTUnwrap(grok.card, "no key: the card")
        XCTAssertEqual(card.title, "What you need — Grok Build talks to xAI")
        XCTAssertEqual(card.options.map(\.kind), ["paste", "source"])
        XCTAssertEqual(card.addCommand, "doz account add NAME --provider xai")
        XCTAssertTrue(card.notOffered.first?.contains("an x.ai or X account") == true, "the vendor sign-in: labelled, not offered")
        XCTAssertNil(catalog.agents.first { $0.id == "gemini" }?.card, "a key there: no card")
        XCTAssertFalse(catalog.coming.isEmpty)
        XCTAssertTrue(catalog.coming.allSatisfy { !$0.reason.isEmpty }, "each coming agent says why")
        XCTAssertTrue(catalog.secretEntry)
    }

    func testATryIsMadeByTheOrdinaryCreateAction() throws {
        let a = try WebAction.decode(Data(#"{"action":"create","sandbox":"try-grok","image":"grok","network":"locked","trial":true}"#.utf8))
        guard case .create(let name, let o) = a else { return XCTFail("not create") }
        XCTAssertEqual(name, "try-grok")
        XCTAssertEqual(o.trial, true)
        XCTAssertEqual(a.hostOp, .create, "one HostOp, as ever")
        XCTAssertThrowsError(try WebAction.decode(Data(#"{"action":"create","sandbox":"x","image":"grok","trial":"yes"}"#.utf8)))
    }

    func testAProvidersKeyMayBePastedNeverACustomOne() throws {
        let k = try WebAccountAdd.decode(Data(#"{"name":"xai","kind":"key","provider":"xai","secret":"xai-0123456789abcdefghijkl"}"#.utf8))
        XCTAssertEqual(k.provider, "xai")
        XCTAssertFalse("\(k)".contains("xai-0123"), "redacted")
        for bad in [#"{"name":"x","kind":"key","secret":"xai-0123456789abcdefghijkl"}"#,
                    #"{"name":"x","kind":"key","provider":"custom","secret":"xai-0123456789abcdefghijkl"}"#,
                    #"{"name":"x","kind":"key","provider":"anthropic","secret":"xai-0123456789abcdefghijkl"}"#,
                    #"{"name":"x","kind":"api-key","provider":"xai","secret":"sk-ant-0123456789abcdefghijkl"}"#] {
            XCTAssertThrowsError(try WebAccountAdd.decode(Data(bad.utf8)), bad)
        }
    }

    /// `doz try --ui`: the control socket's `show` line points open pages at the Quick try — that page only.
    func testTheShowLineNamesOnlyTheQuickTry() {
        XCTAssertEqual(WebControl.showPage("show try"), "try")
        XCTAssertEqual(WebControl.showPage("show try/grok"), "try/grok")
        for bad in ["show settings", "show try/../x", "show try/Grok", "show #/try", "show try/grok?x", "try", "show try/", "link"] {
            XCTAssertNil(WebControl.showPage(bad), bad)
        }
    }

    func testNoPlanFieldIsSecretShaped() throws {
        let catalog = WebTryCatalog(agents: [], coming: [], secretEntry: false)
        let p = WebPlan(CreatePlan.sample(name: "try-grok", image: "grok"))
        for v in [try JSONEncoder().encode(catalog), try JSONEncoder().encode(p)] {
            let s = String(decoding: v, as: UTF8.self).lowercased()
            // Field NAMES only (a reach line may well say "1Password" — a word a person reads).
            for word in ["\"secret\"", "\"token\"", "\"password\"", "\"apikey\"", "\"key\":"] { XCTAssertFalse(s.contains(word), "\(word) in \(s.prefix(300))") }
        }
    }
}

extension CreatePlan {
    /// A plan as the planner makes one (for the page's projections).
    static func sample(name: String, image: String) -> CreatePlan {
        let r = PlanRequest(purpose: "try", name: name, create: CreateOptions(image: image))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("webtry-\(UUID().uuidString.prefix(6))")
        return CreatePlanner.plan(r, facts: PlanFacts(settings: DozerSettings(text: ""), accounts: AccountsFile(), taken: [], images: [],
                                                     store: DozerStore(root: root), projectsDir: "/tmp/617-webtry"))
    }
}
