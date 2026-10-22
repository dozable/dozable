import Darwin
import Foundation
import DozableHost
import XCTest
@testable import DozableWeb

/// 606 — a REAL `doz serve`-profile listener (bound to loopback: the tests reach it at 127.0.0.1, and the trusted
/// proxy is 127.0.0.1), driven with raw HTTP. The data behind it is the shared fake.
final class ServeHTTPTests: XCTestCase {
    var server: DozableWebServer!
    var serveTask: Task<Void, Error>!
    var state: WebServeState!
    let fake = FakeData()
    var dir: URL!
    /// 645: the Mac's own browser's one-use link (the same server, the Mac principal).
    let capability = try! WebBootstrapCapability(testingValue: "mac-link-capability-645-AAAAAAAAAAAAAAAA")

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("doz-serve-http-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        await server?.close()
        _ = try? await serveTask?.value
        server = nil
        try? FileManager.default.removeItem(at: dir)
    }

    func start(_ config: WebServeConfig = WebServeConfig(port: 0, bind: .loopback, advertise: false),
               interfaces: [WebInterfaceAddress] = [WebInterfaceAddress(name: "lo0", address: WebIP("127.0.0.1")!, prefix: 8)]) async throws {
        state = WebServeState(config: config, names: WebMacNames(localHostName: "testmac", hostName: nil),
                              devices: WebDeviceStore(file: dir.appendingPathComponent("serve/devices.json")),
                              audit: WebServeAudit(file: dir.appendingPathComponent("serve/audit.jsonl")), interfaces: { interfaces })
        server = try await DozableWebServer.bindServe(data: fake, assets: try WebAssets.load(), version: "test", limits: .standard,
                                                    settings: WebSettingsStore(environment: [:]), serve: state, capability: capability,
                                                    pollInterval: .milliseconds(200), sessionsFile: dir.appendingPathComponent("ui.sessions"),
                                                    revokedFile: dir.appendingPathComponent("ui.revoked"))
        let s = server!
        serveTask = Task { try await s.run() }
    }

    var port: Int { state.port }
    /// 645: a REMOTE browser — `localhost` is a device (only the exact 127.0.0.1 Host is the Mac's own browser).
    var own: String { "http://localhost:\(port)" }

    func req(_ path: String, _ headers: [String: String] = [:], method: String = "GET", body: String? = nil) throws -> RawResponse {
        var h = ["Host": "localhost:\(port)"]
        for (k, v) in headers { h[k] = v }
        return try RawHTTP.request(port: port, method: method, path: path, headers: h, body: body)
    }

    /// Admit with a fresh invite; returns (cookie pair, csrf).
    func admit(_ headers: [String: String] = [:]) async throws -> (String, String) {
        let inv = await server.share(by: "the Mac")
        var h = ["Origin": own, "Authorization": "Bearer \(inv.testToken)"]
        for (k, v) in headers { h[k] = v }
        let r = try req("/api/v1/session", h, method: "POST")
        XCTAssertEqual(r.status, 200, r.text)
        let set = try XCTUnwrap(r.header("set-cookie"))
        let csrf = try XCTUnwrap((try JSONSerialization.jsonObject(with: r.body) as? [String: Any])?["csrf"] as? String)
        return (String(set.split(separator: ";")[0]), csrf)
    }

    func testNotAdmittedThenALinkOnceThenTheDashboard() async throws {
        try await start()
        XCTAssertEqual(try req("/").status, 200, "the page loads (it signs in inside itself)")
        let r = try req("/api/v1/overview")
        XCTAssertEqual(r.status, 401)
        XCTAssertTrue(r.text.contains("not-admitted"))
        let inv = await server.share(by: "the Mac")
        XCTAssertEqual(try req("/api/v1/session", ["Authorization": "Bearer \(inv.testToken)"], method: "POST").status, 403,
                       "no Origin: refused (and the invite is not spent)")
        let ok = try req("/api/v1/session", ["Origin": own, "Authorization": "Bearer \(inv.testToken)"], method: "POST")
        XCTAssertEqual(ok.status, 200)
        let set = try XCTUnwrap(ok.header("set-cookie"))
        XCTAssertTrue(set.hasPrefix("doz_serve_\(port)="))
        for attr in ["HttpOnly", "SameSite=Strict", "Path=/", "Max-Age=34560000"] { XCTAssertTrue(set.contains(attr), attr) }
        XCTAssertFalse(set.contains("Secure"), "plain http: no Secure")
        let info = try XCTUnwrap(try JSONSerialization.jsonObject(with: ok.body) as? [String: Any])
        let serve = try XCTUnwrap(info["serve"] as? [String: Any])
        XCTAssertEqual(serve["exposure"] as? String, "remote")
        XCTAssertEqual(serve["secure"] as? Bool, false)
        XCTAssertEqual(serve["secretsAllowed"] as? Bool, false)
        let used = try req("/api/v1/session", ["Origin": own, "Authorization": "Bearer \(inv.testToken)"], method: "POST")
        XCTAssertEqual(used.status, 401)
        XCTAssertTrue(used.text.contains("admission-used"))
        let cookie = String(set.split(separator: ";")[0])
        XCTAssertEqual(try req("/api/v1/overview", ["Cookie": cookie]).status, 200)
        // The doz ui cookie name is not this one.
        XCTAssertEqual(try req("/api/v1/overview", ["Cookie": cookie.replacingOccurrences(of: "doz_serve_", with: "doz_ui_")]).status, 401)
    }

    func testACodeAdmitsOnce() async throws {
        try await start()
        let inv = await server.share(by: "the Mac")
        let r = try req("/api/v1/session", ["Origin": own, "Content-Type": "application/json"], method: "POST", body: #"{"code":"\#(inv.code)"}"#)
        XCTAssertEqual(r.status, 200, r.text)
        let again = try req("/api/v1/session", ["Origin": own, "Content-Type": "application/json"], method: "POST", body: #"{"code":"\#(inv.code)"}"#)
        XCTAssertEqual(again.status, 401)
        let junk = try req("/api/v1/session", ["Origin": own, "Content-Type": "application/json"], method: "POST", body: #"{"code":"x","extra":1}"#)
        XCTAssertEqual(junk.status, 401, "strict body")
    }

    func testHostAndOriginForTheLANNames() async throws {
        try await start()
        let (cookie, csrf) = try await admit()
        for h in ["evil.example:\(port)", "127.0.0.1", "testmac.local:\(port)", "127.0.0.2:\(port)"] {
            let r = try req("/api/v1/overview", ["Host": h, "Cookie": cookie])
            XCTAssertEqual(r.status, 403, h)
            XCTAssertFalse(r.text.contains(h), "never reflected")
        }
        XCTAssertEqual(try req("/api/v1/overview", ["Host": "localhost:\(port)", "Cookie": cookie]).status, 200, "a loopback-bound serve answers to localhost")
        // Origin must equal the request's OWN origin — another of this server's names is refused.
        XCTAssertEqual(try req("/api/v1/overview", ["Cookie": cookie, "Origin": "http://127.0.0.1:\(port)"]).status, 403)
        XCTAssertEqual(try req("/api/v1/serve/share", ["Cookie": cookie, "X-Doz-CSRF": csrf, "Origin": "http://127.0.0.1:\(port)",
                                                         "Content-Type": "application/json"], method: "POST", body: "{}").status, 403)
        XCTAssertEqual(try req("/api/v1/overview", ["Cookie": cookie, "Sec-Fetch-Site": "same-site"]).status, 403)
        let ok = try req("/api/v1/serve/share", ["Cookie": cookie, "X-Doz-CSRF": csrf, "Origin": own, "Content-Type": "application/json"], method: "POST", body: "{}")
        XCTAssertEqual(ok.status, 200, ok.text)
        let inv = try XCTUnwrap(try JSONSerialization.jsonObject(with: ok.body) as? [String: Any])
        XCTAssertTrue((inv["link"] as? String)?.hasPrefix(own + "/#cap=") == true, "the share link is for the asker's own origin")
        XCTAssertNotNil((inv["qr"] as? [String: Any])?["rows"])
        XCTAssertNotNil(inv["code"])
        XCTAssertFalse(ok.headers.keys.contains { $0.hasPrefix("access-control") })
    }

    func testBehindATrustedProxyHttpsSecureCookieAndSecrets() async throws {
        try await start(WebServeConfig(port: 0, bind: .loopback, publicOrigins: [WebPublicOrigin("https://doz.home.example")!],
                                       trustedProxies: [WebCIDR("127.0.0.1")!], advertise: false))
        let viaProxy = ["Host": "doz.home.example", "X-Forwarded-Proto": "https", "X-Forwarded-For": "192.168.86.48"]
        let inv = await server.share(by: "the Mac")
        var h = viaProxy
        h["Origin"] = "https://doz.home.example"
        h["Authorization"] = "Bearer \(inv.testToken)"
        let r = try req("/api/v1/session", h, method: "POST")
        XCTAssertEqual(r.status, 200, r.text)
        let set = try XCTUnwrap(r.header("set-cookie"))
        XCTAssertTrue(set.hasPrefix("__Host-doz_serve_\(port)="), set)
        XCTAssertTrue(set.hasSuffix("; Secure"))
        let info = try XCTUnwrap(try JSONSerialization.jsonObject(with: r.body) as? [String: Any])
        XCTAssertEqual((info["serve"] as? [String: Any])?["secure"] as? Bool, true)
        XCTAssertEqual(((info["serve"] as? [String: Any])?["device"] as? [String: Any])?["lastAddress"] as? String, "192.168.86.48", "the client, from X-Forwarded-For")
        let cookie = String(set.split(separator: ";")[0])
        let csrf = try XCTUnwrap(info["csrf"] as? String)
        // Over https through the proxy a key may be typed (the fake host takes it).
        var post = viaProxy
        post["Cookie"] = cookie; post["X-Doz-CSRF"] = csrf; post["Origin"] = "https://doz.home.example"; post["Content-Type"] = "application/json"
        let body = #"{"name":"work","kind":"api-key","secret":"sk-ant-api03-\#(String(repeating: "k", count: 40))"}"#
        let key = try req("/api/v1/accounts", post, method: "POST", body: body)
        XCTAssertEqual(key.status, 200, key.text)
        // The same request without the proxy's https: refused, with the reason — the http cookie name differs anyway,
        // so present the device's cookie under the http name to reach the exposure check.
        let httpCookie = cookie.replacingOccurrences(of: "__Host-doz_serve_", with: "doz_serve_")
        var plain = post
        plain["X-Forwarded-Proto"] = "http"; plain["Origin"] = "http://doz.home.example"; plain["Cookie"] = httpCookie
        let refused = try req("/api/v1/accounts", plain, method: "POST", body: body)
        XCTAssertEqual(refused.status, 403, refused.text)
        XCTAssertTrue(refused.text.contains("secret-over-http") || refused.text.contains("host-rejected"), refused.text)
        // Directly on loopback (not through the proxy's https): the device's cookie, plain http → secret-over-http.
        let direct = try req("/api/v1/accounts", ["Cookie": httpCookie, "X-Doz-CSRF": csrf, "Origin": own, "Content-Type": "application/json"], method: "POST", body: body)
        XCTAssertEqual(direct.status, 403)
        XCTAssertTrue(direct.text.contains("secret-over-http"), direct.text)
        XCTAssertFalse(direct.text.contains("sk-ant-api03"), "never echoed")
    }

    func testForwardedHeadersFromAnUntrustedPeerAreIgnored() async throws {
        try await start(WebServeConfig(port: 0, bind: .loopback, publicOrigins: [WebPublicOrigin("https://doz.home.example")!], trustedProxies: [],
                                       advertise: false))
        let r = try req("/", ["Host": "doz.home.example", "X-Forwarded-Proto": "https"])
        XCTAssertEqual(r.status, 403, "the public name without a trusted proxy: refused")
        XCTAssertTrue(r.text.contains("host-rejected"))
    }

    func testRevokeEndsTheStreamAndRefusesTheCookie() async throws {
        try await start()
        let (cookie, csrf) = try await admit()
        let (other, _) = try await admit()
        let stream = try RawStream(port: port, path: "/api/v1/stream", headers: ["Host": "localhost:\(port)", "Cookie": other])
        defer { stream.close() }
        _ = try stream.read(until: "event: hello", seconds: 5)
        let list = try req("/api/v1/serve/devices", ["Cookie": cookie])
        let devices = try XCTUnwrap((try JSONSerialization.jsonObject(with: list.body) as? [String: Any])?["devices"] as? [[String: Any]])
        XCTAssertEqual(devices.count, 2)
        XCTAssertEqual(devices.filter { $0["current"] as? Bool == true }.count, 1)
        let otherID = try XCTUnwrap(devices.first { $0["current"] as? Bool == false }?["id"] as? String)
        let rv = try req("/api/v1/serve/devices/\(otherID)/revoke", ["Cookie": cookie, "X-Doz-CSRF": csrf, "Origin": own, "Content-Type": "application/json"],
                         method: "POST", body: "{}")
        XCTAssertEqual(rv.status, 200, rv.text)
        let seen = try stream.read(until: "\"reason\":\"revoked\"", seconds: 5)
        XCTAssertTrue(seen.contains("event: end"))
        let after = try req("/api/v1/overview", ["Cookie": other])
        XCTAssertEqual(after.status, 401)
        XCTAssertTrue(after.text.contains("device-revoked"))
        // The audit log says who removed whom.
        let log = WebServeAudit.recent(dir.appendingPathComponent("serve/audit.jsonl"))
        XCTAssertTrue(log.contains { $0.kind == "revoke" && $0.device == otherID })
    }

    func testMacScreenRoutesAreRefusedRemotely() async throws {
        try await start()
        let (cookie, csrf) = try await admit()
        for path in ["/api/v1/workspace/choose", "/api/v1/settings/projects-dir/choose", "/api/v1/dockerfile/choose", "/api/v1/sandboxes/demo/terminal"] {
            let r = try req(path, ["Cookie": cookie, "X-Doz-CSRF": csrf, "Origin": own, "Content-Type": "application/json"], method: "POST", body: "{}")
            XCTAssertEqual(r.status, 403, path)
            XCTAssertTrue(r.text.contains("mac-screen"), path)
        }
    }

    func testTheDoctorsProbeIsOneUse() async throws {
        try await start()
        XCTAssertEqual(try req("/api/v1/serve/probe").status, 404, "no token")
        let t = state.issueProbe()
        XCTAssertEqual(try req("/api/v1/serve/probe", ["X-Doz-Probe": "wrong"]).status, 404)
        let r = try req("/api/v1/serve/probe", ["X-Doz-Probe": t])
        XCTAssertEqual(r.status, 200, r.text)
        XCTAssertTrue(r.text.contains("\"scheme\":\"http\""))
        XCTAssertEqual(try req("/api/v1/serve/probe", ["X-Doz-Probe": t]).status, 404, "once")
    }

    func testASandboxNetworksConnectionIsDroppedBeforeAByte() async throws {
        // This "Mac" says 127.0.0.0/8 is a vmnet bridge: every connection the test makes comes from a sandbox network.
        try await start(interfaces: [WebInterfaceAddress(name: "bridge100", address: WebIP("127.0.0.1")!, prefix: 8)])
        XCTAssertThrowsError(try req("/"), "the connection is closed without an answer")
        try await Task.sleep(for: .milliseconds(100))
        let log = WebServeAudit.recent(dir.appendingPathComponent("serve/audit.jsonl"))
        XCTAssertTrue(log.contains { $0.kind == "dropped" && $0.outcome == "sandbox" }, "said in the audit log")
    }

    /// rc.1 bug: never a silent drop but a sandbox's — a connection to an address doz serve does not serve is TOLD why.
    func testANotServedAddressIsAnsweredNeverSilentlyDropped() async throws {
        try await start()
        state.admitOverride = { _, _ in .notServed }
        let r = try req("/")
        XCTAssertEqual(r.status, 403)
        XCTAssertTrue(r.text.contains("not-served"), r.text)
        XCTAssertTrue(r.text.contains("the dashboard does not answer on this network address"))
        state.admitOverride = { _, _ in .sandbox }
        XCTAssertThrowsError(try req("/"), "a sandbox's connection: dropped, nothing answered")
        state.admitOverride = nil
        XCTAssertEqual(try req("/").status, 200)
    }

    /// Loopback on a lan-bound dashboard: served by 127.0.0.1 (645: the Mac's own browser, signed in by the link) and by
    /// name / localhost (a device like any other: an invite).
    func testTheMacsOwnBrowserIsServedOnLoopback() async throws {
        try await start(WebServeConfig(port: 0, bind: .lan, advertise: false),
                        interfaces: [WebInterfaceAddress(name: "en0", address: WebIP("192.0.2.10")!, prefix: 24)])
        for host in ["127.0.0.1:\(port)", "localhost:\(port)", "testmac.local:\(port)"] {
            XCTAssertEqual(try req("/", ["Host": host]).status, 200, host)
            let r = try req("/api/v1/overview", ["Host": host])
            XCTAssertEqual(r.status, 401, host)
            XCTAssertTrue(r.text.contains(host.hasPrefix("127.") ? "\"unauthenticated\"" : "not-admitted"), "\(host): \(r.text)")
        }
        let inv = await server.share(by: "the Mac")
        let ok = try req("/api/v1/session", ["Host": "testmac.local:\(port)", "Origin": "http://testmac.local:\(port)", "Authorization": "Bearer \(inv.testToken)"], method: "POST")
        XCTAssertEqual(ok.status, 200, ok.text)
    }

    func testTheCLIsInviteNamesTheAddressesToo() async throws {
        try await start(WebServeConfig(port: 0, bind: .lan, advertise: false),
                        interfaces: [WebInterfaceAddress(name: "en0", address: WebIP("192.0.2.10")!, prefix: 24)])
        let a = await server.share(by: "the Mac").answer(origin: state.preferredOrigin, alsoAt: state.addressOrigins)
        XCTAssertTrue(a.link.hasPrefix("http://testmac.local:\(port)/#cap="))
        XCTAssertEqual(a.alternates?.count, 1)
        XCTAssertTrue(a.alternates?[0].hasPrefix("http://192.0.2.10:\(port)/#cap=") == true)
        XCTAssertEqual(a.alternates?[0].split(separator: "#").last, a.link.split(separator: "#").last, "the same invite")
    }

    // MARK: 645 — one dashboard: the Mac's browser (the link) and the LAN's (devices) on ONE port

    var mac: String { "http://127.0.0.1:\(port)" }

    /// The Mac's own browser signs in with the link: (cookie pair, csrf).
    func macSignIn() throws -> (String, String) {
        let r = try req("/api/v1/session", ["Host": "127.0.0.1:\(port)", "Origin": mac,
                                            "Authorization": "Bearer mac-link-capability-645-AAAAAAAAAAAAAAAA"], method: "POST")
        XCTAssertEqual(r.status, 200, r.text)
        let set = try XCTUnwrap(r.header("set-cookie"))
        XCTAssertTrue(set.hasPrefix("doz_ui_\(port)="), set)
        let info = try XCTUnwrap(try JSONSerialization.jsonObject(with: r.body) as? [String: Any])
        XCTAssertNil(info["serve"], "the Mac's page is not a remote one")
        return (String(set.split(separator: ";")[0]), try XCTUnwrap(info["csrf"] as? String))
    }

    func macReq(_ path: String, _ headers: [String: String] = [:], method: String = "GET", body: String? = nil) throws -> RawResponse {
        var h = ["Host": "127.0.0.1:\(port)"]
        for (k, v) in headers { h[k] = v }
        return try RawHTTP.request(port: port, method: method, path: path, headers: h, body: body)
    }

    func testOneProcessServesTheMacByTheLinkAndADeviceByAnInvite() async throws {
        try await start()
        let (macCookie, _) = try macSignIn()
        let (devCookie, _) = try await admit()
        XCTAssertTrue(devCookie.hasPrefix("doz_serve_\(port)="))
        XCTAssertEqual(try macReq("/api/v1/overview", ["Cookie": macCookie]).status, 200, "the Mac's browser")
        XCTAssertEqual(try req("/api/v1/overview", ["Cookie": devCookie]).status, 200, "a device, same port")
        // A cookie of one store never signs a request of the other in — whatever name it is presented under.
        let macValue = macCookie.split(separator: "=", maxSplits: 1)[1], devValue = devCookie.split(separator: "=", maxSplits: 1)[1]
        let a = try req("/api/v1/overview", ["Cookie": "doz_serve_\(port)=\(macValue)"])
        XCTAssertEqual(a.status, 401); XCTAssertTrue(a.text.contains("not-admitted"), a.text)
        let b = try macReq("/api/v1/overview", ["Cookie": "doz_ui_\(port)=\(devValue)"])
        XCTAssertEqual(b.status, 401); XCTAssertTrue(b.text.contains("\"unauthenticated\""), b.text)
        // The Mac's link on a remote Host is an invite attempt — refused (the link is not an invite).
        let c = try req("/api/v1/session", ["Origin": own, "Authorization": "Bearer mac-link-capability-645-BBBBBBBBBBBBBBBB"], method: "POST")
        XCTAssertEqual(c.status, 401)
        // The Mac's own requests are not in the audit log; the device's admission is.
        let log = WebServeAudit.recent(dir.appendingPathComponent("serve/audit.jsonl"))
        XCTAssertEqual(log.filter { $0.kind == "admit" }.count, 1)
    }

    func testMacOnlyAbilitiesAreDecidedPerRequest() async throws {
        try await start()
        let (macCookie, macCSRF) = try macSignIn()
        let (devCookie, devCSRF) = try await admit()
        let key = #"{"name":"work","kind":"api-key","secret":"sk-ant-api03-\#(String(repeating: "k", count: 40))"}"#
        // The Mac's browser over plain http: Open in Terminal and typing a key work (the Mac's own screen, no network).
        let t = try macReq("/api/v1/sandboxes/demo/terminal", ["Cookie": macCookie, "X-Doz-CSRF": macCSRF, "Origin": mac,
                                                                "Content-Type": "application/json"], method: "POST", body: "{}")
        XCTAssertEqual(t.status, 200, t.text)
        let k = try macReq("/api/v1/accounts", ["Cookie": macCookie, "X-Doz-CSRF": macCSRF, "Origin": mac, "Content-Type": "application/json"],
                           method: "POST", body: key)
        XCTAssertEqual(k.status, 200, k.text)
        // A device on the same port: refused, each with its reason.
        let t2 = try req("/api/v1/sandboxes/demo/terminal", ["Cookie": devCookie, "X-Doz-CSRF": devCSRF, "Origin": own,
                                                             "Content-Type": "application/json"], method: "POST", body: "{}")
        XCTAssertEqual(t2.status, 403); XCTAssertTrue(t2.text.contains("mac-screen"))
        let k2 = try req("/api/v1/accounts", ["Cookie": devCookie, "X-Doz-CSRF": devCSRF, "Origin": own, "Content-Type": "application/json"],
                         method: "POST", body: key)
        XCTAssertEqual(k2.status, 403); XCTAssertTrue(k2.text.contains("secret-over-http"))
        // The device's change is audited; the Mac's are not.
        let log = WebServeAudit.recent(dir.appendingPathComponent("serve/audit.jsonl"))
        XCTAssertFalse(log.contains { $0.kind == "change" && $0.route == "accountAdd" }, "the Mac's own key is not in the LAN's audit log")
        XCTAssertTrue(log.contains { $0.kind == "refused" && $0.outcome == "secret-over-http" }, "the device's refusal is")
    }

    /// A reverse proxy on this Mac connects from loopback: what it forwards is never the Mac's browser, even when it
    /// rewrites Host to 127.0.0.1.
    func testAForwardedRequestIsNeverTheMac() async throws {
        try await start()
        let (macCookie, _) = try macSignIn()
        for h in ["X-Forwarded-For", "X-Forwarded-Proto", "X-Forwarded-Host", "Forwarded", "X-Real-IP"] {
            let r = try macReq("/api/v1/overview", ["Cookie": macCookie, h: "203.0.113.9"])
            XCTAssertEqual(r.status, 401, h)
        }
        // The Mac's own browser by another name (localhost) is a device: it needs an invite.
        let n = try req("/api/v1/overview", ["Cookie": macCookie.replacingOccurrences(of: "doz_ui_", with: "doz_serve_")])
        XCTAssertEqual(n.status, 401)
    }

    /// The accept gate runs BEFORE the principal: a sandbox's connection is dropped even with the Mac's exact Host.
    func testASandboxNeverReachesItEvenAsTheMacsHost() async throws {
        try await start()
        state.admitOverride = { _, _ in .sandbox }
        XCTAssertThrowsError(try macReq("/"), "dropped before a byte is read")
        XCTAssertThrowsError(try macReq("/api/v1/session", ["Origin": mac, "Authorization": "Bearer mac-link-capability-645-AAAAAAAAAAAAAAAA"], method: "POST"))
        state.admitOverride = nil
        _ = try macSignIn()                                  // the link was not spent by the dropped attempt
    }

    /// `doz ui link --rotate` signs the Mac's pages out; the LAN's devices stay signed in (another store).
    func testRotateSignsOutTheMacsPagesOnly() async throws {
        try await start()
        let (macCookie, _) = try macSignIn()
        let (devCookie, _) = try await admit()
        let macStream = try RawStream(port: port, path: "/api/v1/stream", headers: ["Host": "127.0.0.1:\(port)", "Cookie": macCookie])
        defer { macStream.close() }
        let devStream = try RawStream(port: port, path: "/api/v1/stream", headers: ["Host": "localhost:\(port)", "Cookie": devCookie])
        defer { devStream.close() }
        _ = try macStream.read(until: "event: hello", seconds: 5)
        _ = try devStream.read(until: "event: hello", seconds: 5)
        let link = await server.rotate()
        XCTAssertTrue(link.absoluteString.hasPrefix(mac + "/#cap="), "a new link for the Mac's browser")
        XCTAssertTrue(try macStream.read(until: "\"reason\":\"rotated\"", seconds: 5).contains("event: end"))
        let after = try macReq("/api/v1/overview", ["Cookie": macCookie])
        XCTAssertEqual(after.status, 401); XCTAssertTrue(after.text.contains("session-rotated"))
        XCTAssertEqual(try req("/api/v1/overview", ["Cookie": devCookie]).status, 200, "the device stays in")
    }

    func testDozUIStillAnswersOnlyItsLoopbackOriginAndNotTheProbe() async throws {
        let ui = try await DozableWebServer.bind(data: fake, assets: try WebAssets.load(), version: "test", pollInterval: .milliseconds(200))
        let t = Task { try await ui.run() }
        defer { Task { await ui.close(); _ = try? await t.value } }
        XCTAssertEqual(ui.origin.host, "127.0.0.1")
        XCTAssertNil(ui.serveState)
        let r = try RawHTTP.request(port: ui.origin.port, method: "GET", path: "/api/v1/serve/probe", headers: ["Host": ui.origin.authority, "X-Doz-Probe": "x"])
        XCTAssertEqual(r.status, 404)
    }
}
