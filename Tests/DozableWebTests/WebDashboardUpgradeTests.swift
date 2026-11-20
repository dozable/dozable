import Foundation
import XCTest
@testable import DozableWeb

/// A thread-safe count (a restarter's calls).
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func add() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
}

/// 714 — the dashboard follows upgrades and names its Mac: the advice for the older side (no Ctrl-C for a dashboard in
/// the background), the doz installed now, Restart dashboard's route and who may use it, the per-Mac app name.
final class WebDashboardUpgradeTests: XCTestCase {
    // MARK: the version note

    func testAnOlderDashboardIsToldToRestartTheDashboardNeverCtrlC() throws {
        // The owner's case: the dashboard 0.51.8 from an old keg, the daemon 0.51.9.
        let n = try XCTUnwrap(WebVersionNote.make(ui: "0.51.8", host: "0.51.9", installed: "0.51.9"))
        XCTAssertEqual(n.older, "ui")
        XCTAssertTrue(n.text.contains("Restart dashboard") && n.text.contains("doz ui restart"), n.text)
        XCTAssertFalse(n.text.contains("Ctrl-C"), "a dashboard in the background has no Ctrl-C")
    }

    func testANewerInstalledDozIsSaidEvenWhenTheDaemonMatches() throws {
        let n = try XCTUnwrap(WebVersionNote.make(ui: "0.51.8", host: "0.51.8", installed: "0.51.9"))
        XCTAssertEqual(n.older, "ui")
        XCTAssertTrue(n.text.contains("doz 0.51.9 is installed") && n.text.contains("0.51.8"), n.text)
        // No daemon running: the same.
        XCTAssertEqual(WebVersionNote.make(ui: "0.51.8", host: nil, installed: "0.51.9")?.older, "ui")
    }

    func testTheOlderDaemonKeepsItsAdviceAndNothingIsSaidWhenAllMatch() {
        XCTAssertEqual(WebVersionNote.make(ui: "0.51.9", host: "0.51.8", installed: "0.51.9")?.older, "host")
        XCTAssertNil(WebVersionNote.make(ui: "0.51.9", host: "0.51.9", installed: "0.51.9"))
        XCTAssertNil(WebVersionNote.make(ui: "0.51.9", host: "0.51.9", installed: nil), "not known: nothing")
        XCTAssertNil(WebVersionNote.make(ui: "0.51.9", host: nil, installed: "0.51.8"), "an older install is never advice to restart into it")
        XCTAssertNil(WebVersionNote.make(ui: "0.51.9", host: "0.51.9+b", installed: "0.51.9+c"))
        XCTAssertEqual(WebVersionNote.make(ui: "dev", host: "0.51.9")?.older, nil)
    }

    // MARK: updates are judged against the doz installed now

    func testAnUpdateIsJudgedAgainstTheInstalledDoz() {
        XCTAssertEqual(WebUpdateNotice.current(own: "0.51.8", installed: "0.51.9"), "0.51.9", "never offer what is installed")
        XCTAssertEqual(WebUpdateNotice.current(own: "0.51.9", installed: "0.51.8"), "0.51.9")
        XCTAssertEqual(WebUpdateNotice.current(own: "0.51.9", installed: nil), "0.51.9")
        XCTAssertEqual(WebUpdateNotice.current(own: "0.51.9", installed: "garbage"), "0.51.9")
    }

    // MARK: the route and who may use it

    func testRestartDashboardIsAMacOnlyRoute() {
        XCTAssertEqual(WebRoute.parse(method: .post, target: "/api/v1/ui/restart"), .uiRestart)
        XCTAssertNil(WebRoute.parse(method: .get, target: "/api/v1/ui/restart"))
        XCTAssertNil(WebRoute.parse(method: .post, target: "/api/v1/ui/restart/now"))
        XCTAssertEqual(WebExposure.kind(.uiRestart), .macOnly)
        XCTAssertNil(WebExposure.decide(.uiRestart, .mac))
        for s in WebExposure.MacSessions.allCases {
            for c in WebExposure.ChatServe.allCases {
                XCTAssertEqual(WebExposure.decide(.uiRestart, .remote(secure: true), macSessions: s, chat: c), .macOnly, "no setting opens it")
                XCTAssertEqual(WebExposure.decide(.uiRestart, .remote(secure: false), macSessions: s, chat: c), .macOnly)
            }
        }
        XCTAssertEqual(WebRejection.macOnly.status, 403)
        XCTAssertTrue(WebRejection.macOnly.message.contains("doz ui restart"))
    }

    // MARK: the app named for its Mac

    func testTheShortNameFitsTwelveCharacters() {
        XCTAssertEqual(WebAppName.names(mac: "john-mac-studio").shortName, "Doz john")
        XCTAssertEqual(WebAppName.names(mac: "john-mac-studio").name, "Dozable – john-mac-studio")
        XCTAssertEqual(WebAppName.short("Johns-MacBook-Pro"), "Johns")
        XCTAssertEqual(WebAppName.short("MacBook-Pro"), "MacBook")
        XCTAssertEqual(WebAppName.short("studiomaxwell"), "studioma")
        XCTAssertEqual(WebAppName.short("Extraordinary-Mac"), "Extraord")
        for m in ["john-mac-studio", "Johns-MacBook-Pro", "studiomaxwell", "a-b", "x"] {
            XCTAssertLessThanOrEqual(WebAppName.names(mac: m).shortName.count, 12, m)
        }
        XCTAssertNil(WebAppName.clean("<script>"))
        XCTAssertNil(WebAppName.clean(""))
        XCTAssertNil(WebAppName.clean(String(repeating: "a", count: 64)))
        XCTAssertEqual(WebAppName.clean(" john-mac-studio "), "john-mac-studio")
    }

    func testTheSeamNamesTheMacOnlyInAGuardedRun() {
        let guarded = ["DOZ_TEST_GUARD": "1", "DOZ_TEST_MAC_NAME": "testmac"]
        XCTAssertEqual(WebAppName.current(guarded), "testmac")
        XCTAssertNil(WebAppName.current(["DOZ_TEST_GUARD": "1"]), "a test never reads the Mac's own name")
    }

    func testTheManifestAndTitleAreNamedForTheMacAndTheAppStaysOne() throws {
        let base = try WebAssets.load()
        let named = base.forMac("john-mac-studio")
        let m = try XCTUnwrap(named.assets.values.first { $0.mimeType == "application/manifest+json" })
        let old = try XCTUnwrap(base.assets.values.first { $0.mimeType == "application/manifest+json" })
        XCTAssertNotEqual(m.publicPath, old.publicPath, "a new hashed path: a copy cached under another name is not reused")
        XCTAssertNil(named.assets[old.publicPath])
        XCTAssertTrue(m.publicPath.hasPrefix("/assets/app-") && m.publicPath.hasSuffix(".webmanifest"))
        XCTAssertEqual(m.cachePolicy, old.cachePolicy)
        XCTAssertEqual(m.sha256, WebAssets.sha256Hex(m.data))
        let j = try XCTUnwrap(try JSONSerialization.jsonObject(with: m.data) as? [String: Any])
        let o = try XCTUnwrap(try JSONSerialization.jsonObject(with: old.data) as? [String: Any])
        XCTAssertEqual(j["name"] as? String, "Dozable – john-mac-studio")
        XCTAssertEqual(j["short_name"] as? String, "Doz john")
        for k in ["id", "start_url", "scope", "display", "background_color", "theme_color", "description"] {
            XCTAssertEqual(j[k] as? String, o[k] as? String, k)
        }
        XCTAssertEqual(j["id"] as? String, "/?app=dozable", "one origin = one app")
        XCTAssertEqual((j["icons"] as? [Any])?.count, (o["icons"] as? [Any])?.count)
        let index = String(decoding: try XCTUnwrap(named.assets["/"]).data, as: UTF8.self)
        XCTAssertTrue(index.contains("<link rel=\"manifest\" href=\"\(m.publicPath)\">"), "the page links the named manifest")
        XCTAssertTrue(index.contains("<title>Dozable – john-mac-studio</title>"))
        XCTAssertEqual(named.pageScript, base.pageScript)
        XCTAssertEqual(named.assets.count, base.assets.count)
        // No name (or one unfit for a title): the build's own files.
        XCTAssertEqual(base.forMac(nil).assets["/"]?.data, base.assets["/"]?.data)
        XCTAssertEqual(base.forMac("<b>").assets["/"]?.data, base.assets["/"]?.data)
    }

    /// The named manifest is served with the static file's headers (type, immutable cache) and the page's CSP unchanged.
    func testTheNamedManifestIsServedAsTheStaticOneWas() async throws {
        let assets = try WebAssets.load().forMac("john-mac-studio")
        let server = try await DozableWebServer.bind(data: FakeData(), assets: assets, version: "test",
                                                     capability: try WebBootstrapCapability(testingValue: "test-capability-abcdefghijklmnopqrstuvwxyz"))
        let task = Task { try await server.run() }
        let m = try XCTUnwrap(assets.assets.values.first { $0.mimeType == "application/manifest+json" })
        let r = try RawHTTP.request(port: server.origin.port, method: "GET", path: m.publicPath, headers: ["Host": server.origin.authority])
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(r.header("content-type"), "application/manifest+json")
        XCTAssertEqual(r.header("cache-control"), WebAssets.immutable)
        XCTAssertTrue(r.text.contains("Dozable – john-mac-studio"))
        let page = try RawHTTP.request(port: server.origin.port, method: "GET", path: "/", headers: ["Host": server.origin.authority])
        XCTAssertTrue(page.header("content-security-policy")?.contains("manifest-src 'self'") == true)
        XCTAssertTrue(page.text.contains("<title>Dozable – john-mac-studio</title>"))
        await server.close()
        _ = try? await task.value
    }
}
