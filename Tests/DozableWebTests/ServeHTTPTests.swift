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
               interfaces: [WebInterfaceAddress] = [WebInterfaceAddress(name: "lo0", address: WebIP("127.0.0.1")!, prefix: 8)],
               macSessions: String? = nil, chat: String? = nil) async throws {
        // A settings file of the test's own (serve.mac_sessions, serve.chat) — none: every default.
        var env: [String: String] = [:]
        if macSessions != nil || chat != nil {
            let xdg = dir.appendingPathComponent("xdg")
            try FileManager.default.createDirectory(at: xdg.appendingPathComponent("doz"), withIntermediateDirectories: true)
            var toml = "[serve]\n"
            if let macSessions { toml += "mac_sessions = \"\(macSessions)\"\n" }
            if let chat { toml += "chat = \"\(chat)\"\n" }
            try toml.write(to: xdg.appendingPathComponent("doz/doz.toml"), atomically: true, encoding: .utf8)
            env["XDG_CONFIG_HOME"] = xdg.path
        }
        state = WebServeState(config: config, names: WebMacNames(localHostName: "testmac", hostName: nil),
                              devices: WebDeviceStore(file: dir.appendingPathComponent("serve/devices.json")),
                              audit: WebServeAudit(file: dir.appendingPathComponent("serve/audit.jsonl")), interfaces: { interfaces })
        server = try await DozableWebServer.bindServe(data: fake, assets: try WebAssets.load(), version: "test", limits: .standard,
                                                    settings: WebSettingsStore(environment: env), serve: state, capability: capability,
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

    /// Chat is this Mac's own browser's only: every chat route answers another computer 403, admitted or not, whatever
    /// serve.mac_sessions says — before the session is even looked at.
    func testChatIsNeverServedToAnotherComputer() async throws {
        try await start(macSessions: "interactive")
        let (cookie, csrf) = try await admit()
        XCTAssertEqual(try req("/api/v1/overview", ["Cookie": cookie]).status, 200, "the device is signed in")
        let gets = ["/api/v1/chat/status", "/api/v1/chat/state", "/api/v1/chat/presence", "/api/v1/chat/unread", "/api/v1/chat/protocol",
                    "/api/v1/chat/stream", "/api/v1/chat/rooms/general/messages", "/api/v1/chat/files/0123456789abcdef/a.png"]
        for p in gets {
            for h in [["Cookie": cookie], [:]] {
                let r = try req(p, h)
                XCTAssertEqual(r.status, 403, p)
                XCTAssertTrue(r.text.contains("chat-remote"), r.text)
            }
        }
        let r = try req("/api/v1/chat/rooms/general/messages", ["Cookie": cookie, "Origin": own, "X-Doz-CSRF": csrf, "Content-Type": "application/json"],
                        method: "POST", body: #"{"content":"hi"}"#)
        XCTAssertEqual(r.status, 403)
        XCTAssertTrue(r.text.contains("chat-remote"), r.text)
    }

    /// 745: another computer gets the chat window's DOCUMENT either way (it holds nothing); what it may read is decided per
    /// chat route by serve.chat, exactly as on the Chat page: off → 403 chat-remote, read → the reads and never a post.
    func testTheChatWindowsExposureIsTheChatViews() async throws {
        try await start()
        let (offCookie, _) = try await admit()
        for h in [["Cookie": offCookie], [:]] {
            let doc = try req("/chat", h)
            XCTAssertEqual(doc.status, 200, "the document, with or without a session")
            XCTAssertTrue(doc.text.contains("/assets/chat-"))
        }
        let off = try req("/api/v1/chat/status", ["Cookie": offCookie])
        XCTAssertEqual(off.status, 403)
        XCTAssertTrue(off.text.contains("chat-remote"), off.text)
        await server.close()
        _ = try? await serveTask?.value
        try await start(chat: "read")
        let (cookie, csrf) = try await admit()
        XCTAssertEqual(try req("/chat", ["Cookie": cookie]).status, 200)
        let st = try req("/api/v1/chat/status", ["Cookie": cookie])
        XCTAssertEqual(st.status, 200, st.text)
        XCTAssertFalse(st.text.contains("chat-remote"), "read: the chat routes answer (chat itself is off here)")
        let post = try req("/api/v1/chat/rooms/general/messages", ["Cookie": cookie, "Origin": own, "X-Doz-CSRF": csrf, "Content-Type": "application/json"],
                           method: "POST", body: #"{"content":"hi"}"#)
        XCTAssertEqual(post.status, 403)
        XCTAssertTrue(post.text.contains("chat-read-only"), post.text)
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
        for path in ["/api/v1/folder/choose", "/api/v1/settings/projects-dir/choose", "/api/v1/dockerfile/choose", "/api/v1/sandboxes/demo/terminal"] {
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

    /// 714: Restart dashboard — this Mac's own browser only, CSRF-checked, `{}` only; a device on the same port (admitted,
    /// with its own CSRF token) is refused `mac-only` and nothing restarts. The restart runs once, after the answer.
    func testRestartDashboardIsTheMacsBrowserOnly() async throws {
        try await start()
        let restarts = Counter()
        server.restarter = WebControl.Restarter(check: { nil }, restart: { restarts.add() })
        let (macCookie, macCSRF) = try macSignIn()
        let (devCookie, devCSRF) = try await admit()
        let dev = try req("/api/v1/ui/restart", ["Cookie": devCookie, "X-Doz-CSRF": devCSRF, "Origin": own, "Content-Type": "application/json"],
                          method: "POST", body: "{}")
        XCTAssertEqual(dev.status, 403, dev.text)
        XCTAssertTrue(dev.text.contains("mac-only"), dev.text)
        let log = WebServeAudit.recent(dir.appendingPathComponent("serve/audit.jsonl"))
        XCTAssertTrue(log.contains { $0.kind == "refused" && $0.outcome == "mac-only" }, "the device's attempt is audited")
        let noCSRF = try macReq("/api/v1/ui/restart", ["Cookie": macCookie, "Origin": mac, "Content-Type": "application/json"], method: "POST", body: "{}")
        XCTAssertEqual(noCSRF.status, 403, "CSRF-checked like every change")
        let bad = try macReq("/api/v1/ui/restart", ["Cookie": macCookie, "X-Doz-CSRF": macCSRF, "Origin": mac, "Content-Type": "application/json"],
                             method: "POST", body: #"{"port":1}"#)
        XCTAssertEqual(bad.status, 400, bad.text)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(restarts.value, 0, "nothing restarted for a refused request")
        let ok = try macReq("/api/v1/ui/restart", ["Cookie": macCookie, "X-Doz-CSRF": macCSRF, "Origin": mac, "Content-Type": "application/json"],
                            method: "POST", body: "{}")
        XCTAssertEqual(ok.status, 200, ok.text)
        XCTAssertTrue(ok.text.contains("\"restarting\":\"http://127.0.0.1:\(port)\""), ok.text)
        _ = try macReq("/api/v1/ui/restart", ["Cookie": macCookie, "X-Doz-CSRF": macCSRF, "Origin": mac, "Content-Type": "application/json"],
                       method: "POST", body: "{}")
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(restarts.value, 1, "one restart, after the answer, however many clicks")
    }

    /// 714: a restart the UI refuses (its port check) is said, and nothing restarts; no restarter (a test's server) → 503.
    func testRestartDashboardSaysWhyNot() async throws {
        try await start()
        let (macCookie, macCSRF) = try macSignIn()
        let h = ["Cookie": macCookie, "X-Doz-CSRF": macCSRF, "Origin": mac, "Content-Type": "application/json"]
        let none = try macReq("/api/v1/ui/restart", h, method: "POST", body: "{}")
        XCTAssertEqual(none.status, 503, none.text)
        let restarts = Counter()
        server.restarter = WebControl.Restarter(check: { "the dashboard's port would be 9 — doz ui stays" }, restart: { restarts.add() })
        let refused = try macReq("/api/v1/ui/restart", h, method: "POST", body: "{}")
        XCTAssertTrue(refused.status >= 400 && refused.text.contains("doz ui stays"), refused.text)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(restarts.value, 0)
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

    // MARK: the sessions on this Mac (@mac) — never another computer's unless serve.mac_sessions says so

    func macJSON(_ cookie: String, _ csrf: String, _ path: String, _ body: String, remote: Bool) throws -> RawResponse {
        let h = ["Cookie": cookie, "X-Doz-CSRF": csrf, "Origin": remote ? own : mac, "Content-Type": "application/json"]
        return remote ? try req(path, h, method: "POST", body: body) : try macReq(path, h, method: "POST", body: body)
    }

    func testTheSessionsOnThisMacAreTheMacsAloneByDefault() async throws {
        try await start()
        let (macCookie, macCSRF) = try macSignIn()
        let (devCookie, devCSRF) = try await admit()
        // The Mac's own browser: listed (not isolated, said in the answer), a ticket, an action decoded.
        let list = try macReq("/api/v1/mac/sessions", ["Cookie": macCookie])
        XCTAssertEqual(list.status, 200, list.text)
        let j = try XCTUnwrap(try JSONSerialization.jsonObject(with: list.body) as? [String: Any])
        XCTAssertEqual(j["isolated"] as? Bool, false)
        XCTAssertEqual(j["access"] as? String, "interactive")
        let first = try XCTUnwrap((j["sessions"] as? [[String: Any]])?.first)
        XCTAssertEqual(first["bypassed"] as? Bool, true)
        XCTAssertEqual(first["state"] as? String, "running")
        let t = try macJSON(macCookie, macCSRF, "/api/v1/mac/terminal-ticket", #"{"mode":"interactive","session":"build","cols":80,"rows":24}"#, remote: false)
        XCTAssertEqual(t.status, 200, t.text)
        XCTAssertEqual(try macJSON(macCookie, macCSRF, "/api/v1/mac/terminal-ticket", #"{"mode":"watch"}"#, remote: false).status, 400, "a session must be named")
        XCTAssertEqual(try macJSON(macCookie, macCSRF, "/api/v1/mac/terminal-ticket", #"{"mode":"console"}"#, remote: false).status, 400, "no console on the Mac")
        XCTAssertEqual(try macReq("/api/v1/mac/terminal-ticket", ["Cookie": macCookie, "Origin": mac, "Content-Type": "application/json"],
                                  method: "POST", body: #"{"mode":"watch","session":"build"}"#).status, 403, "CSRF-checked")
        // Another computer, with serve.mac_sessions = off (the default): none of it.
        for r in [try req("/api/v1/mac/sessions", ["Cookie": devCookie]), try req("/api/v1/mac/sessions/build/screen", ["Cookie": devCookie]),
                  try macJSON(devCookie, devCSRF, "/api/v1/mac/terminal-ticket", #"{"mode":"watch","session":"build"}"#, remote: true),
                  try macJSON(devCookie, devCSRF, "/api/v1/actions", #"{"action":"mac-session-end","session":"build","confirm":"build"}"#, remote: true),
                  try macJSON(devCookie, devCSRF, "/api/v1/grids", #"{"items":[{"sandbox":"@mac","session":"build","gen":0}]}"#, remote: true)] {
            XCTAssertEqual(r.status, 403, r.text)
            XCTAssertTrue(r.text.contains("mac-session"), r.text)
        }
        // …while a sandbox's tile is still painted for it.
        XCTAssertEqual(try macJSON(devCookie, devCSRF, "/api/v1/grids", #"{"items":[{"sandbox":"demo","session":"shell","gen":0}]}"#, remote: true).status, 200)
    }

    /// The workspace reads: another computer with serve.mac_sessions off gets no session name of this Mac (counted as
    /// hidden); the Mac's own browser and a watching one get them.
    func testTheWorkspaceReadsHideThisMacsSessionsFromAnotherComputer() async throws {
        try await start()
        let (macCookie, _) = try macSignIn()
        let (devCookie, _) = try await admit()
        for p in ["/api/v1/loose", "/api/v1/workspaces"] {
            let dev = try req(p, ["Cookie": devCookie])
            XCTAssertEqual(dev.status, 200, dev.text)
            XCTAssertFalse(dev.text.contains("@mac/build"), dev.text)
            XCTAssertTrue(dev.text.contains("\"hidden\":1"), dev.text)
            XCTAssertTrue(try macReq(p, ["Cookie": macCookie]).text.contains("@mac/build"), "the Mac's own browser")
        }
        XCTAssertEqual(try req("/api/v1/bots", ["Cookie": devCookie]).status, 200)
        XCTAssertEqual(try req("/api/v1/workspaces/demo", ["Cookie": devCookie]).status, 200)
    }

    /// A bot's screen is a read for every browser: another computer gets it (the instructions' text too — your prose), read
    /// only, its key as keeper + fingerprint, and — while serve.mac_sessions is off — nothing naming this Mac's sessions.
    func testABotIsReadRemotelyWithoutThisMacsSessions() async throws {
        try await start()
        let (macCookie, _) = try macSignIn()
        let (devCookie, _) = try await admit()
        let dev = try req("/api/v1/bots/mira", ["Cookie": devCookie])
        XCTAssertEqual(dev.status, 200, dev.text)
        XCTAssertTrue(dev.text.contains("\"instructions\":\"Be brief.\\n\""), dev.text)
        XCTAssertTrue(dev.text.contains("\"fingerprint\":\"3f9a01b2c3c2\"") && dev.text.contains("\"keeper\":\"dozable\""), dev.text)
        XCTAssertFalse(dev.text.contains("build"), "no session of this Mac: \(dev.text)")
        XCTAssertFalse(dev.text.lowercased().contains("token") || dev.text.contains("cccccccc"), dev.text)
        let mac = try macReq("/api/v1/bots/mira", ["Cookie": macCookie])
        XCTAssertTrue(mac.text.contains("\"session\":\"build\""), "the Mac's own browser: \(mac.text)")
        XCTAssertEqual(try req("/api/v1/bots/nobody", ["Cookie": devCookie]).status, 404)
        let bad = try req("/api/v1/bots/Bad_Name", ["Cookie": devCookie])
        XCTAssertEqual(bad.status, 400, bad.text)
        XCTAssertFalse(bad.text.contains("Bad_Name"), "never echoed")
        let retired = try req("/api/v1/bots?retired=1", ["Cookie": devCookie])
        XCTAssertEqual(retired.status, 200, retired.text)
        XCTAssertTrue(retired.text.contains("\"gone\"") && !retired.text.contains("\"mira\""), retired.text)
    }

    /// A workspace's brief is what its agents act on: another computer reads it only with serve.chat read or write (refused,
    /// and audited, while off); its log hides the lines about this Mac's sessions while serve.mac_sessions is off.
    func testTheBriefFollowsServeChatAndTheLogHidesThisMacsSessions() async throws {
        try await start()
        let (macCookie, _) = try macSignIn()
        let (devCookie, _) = try await admit()
        let refused = try req("/api/v1/workspaces/demo/brief", ["Cookie": devCookie])
        XCTAssertEqual(refused.status, 403, refused.text)
        XCTAssertTrue(refused.text.contains("brief-remote") && refused.text.contains("serve.chat"), refused.text)
        XCTAssertFalse(refused.text.contains("the brief's text"))
        XCTAssertEqual(try macReq("/api/v1/workspaces/demo/brief", ["Cookie": macCookie]).status, 200, "the Mac's own browser")
        let log = try req("/api/v1/workspaces/demo/log", ["Cookie": devCookie])
        XCTAssertEqual(log.status, 200, log.text)
        XCTAssertFalse(log.text.contains("build"), log.text)
        XCTAssertTrue(log.text.contains("\"hidden\":1"), log.text)
        XCTAssertTrue(try macReq("/api/v1/workspaces/demo/log", ["Cookie": macCookie]).text.contains("adopted build"))
        let audit = WebServeAudit.recent(dir.appendingPathComponent("serve/audit.jsonl"))
        XCTAssertTrue(audit.contains { $0.kind == "refused" && $0.outcome == "brief-remote" })
    }

    func testTheBriefIsReadWithServeChatRead() async throws {
        try await start(chat: "read")
        let (devCookie, devCSRF) = try await admit()
        let r = try req("/api/v1/workspaces/demo/brief", ["Cookie": devCookie])
        XCTAssertEqual(r.status, 200, r.text)
        XCTAssertTrue(r.text.contains("the brief's text"))
        // …but read is not write: the brief is not edited from there.
        let edit = try macJSON(devCookie, devCSRF, "/api/v1/actions", Self.briefEdit, remote: true)
        XCTAssertEqual(edit.status, 403, edit.text)
        XCTAssertTrue(edit.text.contains("chat-read-only"), edit.text)
        XCTAssertTrue(fake.performedOps.isEmpty, "nothing reached the daemon")
    }

    static let briefEdit = #"{"action":"workspace-brief","workspace":"demo","brief":"Shorter.","ifBrief":"\#(String(repeating: "d", count: 64))"}"#

    /// Editing the brief from another computer: refused while serve.chat is off or read (and audited as a refusal), done
    /// with write and audited as ONE change line (the action's word, never the brief).
    func testTheBriefIsEditedFromAnotherComputerOnlyWithServeChatWrite() async throws {
        try await start()
        let (devCookie, devCSRF) = try await admit()
        let off = try macJSON(devCookie, devCSRF, "/api/v1/actions", Self.briefEdit, remote: true)
        XCTAssertEqual(off.status, 403, off.text)
        XCTAssertTrue(off.text.contains("brief-remote"), off.text)
        XCTAssertTrue(fake.performedOps.isEmpty)
        let log = WebServeAudit.recent(dir.appendingPathComponent("serve/audit.jsonl"))
        XCTAssertTrue(log.contains { $0.kind == "refused" && $0.outcome == "brief-remote" })
    }

    static let filing = [
        #"{"action":"workspace-adopt","workspace":"demo","agent":"gamma"}"#,
        #"{"action":"workspace-new","workspace":"gamma","brief":"The work in gamma.","adopt":["gamma"]}"#,
        #"{"action":"workspace-release","workspace":"demo","agent":"gamma"}"#,
    ]

    /// Filing an agent into a workspace or out of one: another computer gets 403 `mac-only` for each of the three — even with
    /// serve.chat = write and serve.mac_sessions = interactive — nothing reaches the daemon and each is audited; this Mac's
    /// own browser on the same port gets 202 and exactly the one HostOp.
    func testFilingIsThisMacsBrowserOnlyWhateverTheServeSettings() async throws {
        try await start(macSessions: "interactive", chat: "write")
        let (devCookie, devCSRF) = try await admit()
        for body in Self.filing {
            let r = try macJSON(devCookie, devCSRF, "/api/v1/actions", body, remote: true)
            XCTAssertEqual(r.status, 403, r.text)
            XCTAssertTrue(r.text.contains("\"mac-only\""), r.text)
            XCTAssertTrue(r.text.contains("this Mac's own browser"), r.text)
        }
        XCTAssertTrue(fake.performedOps.isEmpty, "nothing reached the daemon")
        let log = WebServeAudit.recent(dir.appendingPathComponent("serve/audit.jsonl"))
        XCTAssertTrue(log.contains { $0.kind == "refused" && $0.outcome == "mac-only" && $0.route == "actions" }, "audited (repeats collapse)")
        let (macCookie, macCSRF) = try macSignIn()
        var want: [HostOp] = []
        for (body, op) in zip(Self.filing, [HostOp.workspaceAdopt, .workspaceNew, .workspaceRelease]) {
            let r = try macJSON(macCookie, macCSRF, "/api/v1/actions", body, remote: false)
            XCTAssertEqual(r.status, 202, r.text)
            want.append(op)
            let deadline = Date().addingTimeInterval(5)
            while fake.performedOps.count < want.count && Date() < deadline { usleep(10_000) }
            XCTAssertEqual(fake.performedOps, want)
        }
    }

    static let wizard = [
        #"{"action":"workspace-new","workspace":"launch","brief":"Make it.\n","folders":[{"path":"/tmp","mode":"ro"}],"manager":"mira","workerIsolation":"vm","network":"open"}"#,
        #"{"action":"workspace-start","workspace":"launch","actsAsYou":true}"#,
    ]

    /// The New workspace wizard: creating and starting are this Mac's own browser's, whatever serve.chat and
    /// serve.mac_sessions say — another computer gets 403 `mac-only` for both actions (one audit line, nothing sent to the
    /// daemon) and the plan route is refused (`mac-screen`); this Mac's browser: 202 for each (exactly its HostOp), 200 for
    /// the plan.
    func testCreatingAndStartingAWorkspaceIsThisMacsBrowserOnly() async throws {
        try await start(macSessions: "interactive", chat: "write")
        let (devCookie, devCSRF) = try await admit()
        for body in Self.wizard {
            let r = try macJSON(devCookie, devCSRF, "/api/v1/actions", body, remote: true)
            XCTAssertEqual(r.status, 403, r.text)
            XCTAssertTrue(r.text.contains("\"mac-only\""), r.text)
            XCTAssertTrue(r.text.contains("this Mac's own browser"), r.text)
        }
        let plan = #"{"workspace":"launch","brief":"","noRoom":true}"#
        let rp = try macJSON(devCookie, devCSRF, "/api/v1/workspace-plan", plan, remote: true)
        XCTAssertEqual(rp.status, 403, rp.text)
        XCTAssertTrue(rp.text.contains("\"mac-screen\""), rp.text)
        XCTAssertTrue(fake.performedOps.isEmpty, "nothing reached the daemon")
        XCTAssertFalse(fake.workspaceCalls.contains { $0.hasPrefix("plan") }, "the plan was not asked")
        let (macCookie, macCSRF) = try macSignIn()
        var want: [HostOp] = []
        for (body, op) in zip(Self.wizard, [HostOp.workspaceNew, .workspaceStart]) {
            let r = try macJSON(macCookie, macCSRF, "/api/v1/actions", body, remote: false)
            XCTAssertEqual(r.status, 202, r.text)
            want.append(op)
            let deadline = Date().addingTimeInterval(5)
            while fake.performedOps.count < want.count && Date() < deadline { usleep(10_000) }
            XCTAssertEqual(fake.performedOps, want)
        }
        let p = try macJSON(macCookie, macCSRF, "/api/v1/workspace-plan", plan, remote: false)
        XCTAssertEqual(p.status, 200, p.text)
        let answer = try JSONDecoder().decode(WebWorkspacePlan.self, from: p.body)
        XCTAssertEqual(answer.gaps.map(\.step), [4], "the room's gap is How they chat's")
        XCTAssertEqual(answer.findings.map(\.step), ["chat"])
        XCTAssertEqual(answer.suggested?.name, "workspace1")
        XCTAssertEqual(answer.managers.map(\.bot), ["mira"])
        XCTAssertTrue(answer.commands.contains("doz workspace new launch --no-room"), answer.commands)
        // 782: a workspace from a template — another computer 403 mac-only; the list is a read anyone gets.
        let tpl = #"{"action":"workspace-from-template","template":"solo","workspace":"w9"}"#
        let rt = try macJSON(devCookie, devCSRF, "/api/v1/actions", tpl, remote: true)
        XCTAssertEqual(rt.status, 403, rt.text)
        XCTAssertTrue(rt.text.contains("\"mac-only\""), rt.text)
        XCTAssertEqual(fake.performedOps, want, "the plan is a read: no operation")
        // Strict: an unknown field, or a project path, is refused before any call.
        XCTAssertEqual(try macJSON(macCookie, macCSRF, "/api/v1/workspace-plan", #"{"workspace":"x","project":"/etc"}"#, remote: false).status, 400)
    }

    static let workerActions = [
        #"{"action":"worker-add","workspace":"launch","task":"list the files"}"#,
        #"{"action":"worker-end","workspace":"launch","name":"bot1","confirm":"bot1"}"#,
    ]

    /// Workers: adding and ending one is this Mac's own browser only, whatever serve.chat and serve.mac_sessions say — another
    /// computer gets 403 `mac-only` for both actions (the family's words; nothing sent to the daemon) and the plan route is
    /// refused (`mac-screen`); this Mac's browser: 202 for each (exactly its HostOp), 200 for the plan.
    func testWorkersAreThisMacsBrowserOnlyWhateverTheServeSettings() async throws {
        try await start(macSessions: "interactive", chat: "write")
        let (devCookie, devCSRF) = try await admit()
        // The serve settings are read per request: the same refusals whatever they say.
        for (ms, chat) in [("interactive", "write"), ("off", "off"), ("watch", "read")] {
            try "[serve]\nmac_sessions = \"\(ms)\"\nchat = \"\(chat)\"\n".write(to: dir.appendingPathComponent("xdg/doz/doz.toml"), atomically: true, encoding: .utf8)
            for body in Self.workerActions {
                let r = try macJSON(devCookie, devCSRF, "/api/v1/actions", body, remote: true)
                XCTAssertEqual(r.status, 403, r.text)
                XCTAssertTrue(r.text.contains("\"mac-only\""), r.text)
                XCTAssertTrue(r.text.contains("Workers are added and ended only in this Mac's own browser"), r.text)
            }
            let rp = try macJSON(devCookie, devCSRF, "/api/v1/worker-plan", #"{"workspace":"launch","task":"x"}"#, remote: true)
            XCTAssertEqual(rp.status, 403, rp.text)
            XCTAssertTrue(rp.text.contains("\"mac-screen\""), rp.text)
            XCTAssertTrue(fake.performedOps.isEmpty, "nothing reached the daemon (\(ms), \(chat))")
            XCTAssertFalse(fake.workspaceCalls.contains { $0.hasPrefix("worker-plan") }, "the plan was not asked")
        }
        let (macCookie, macCSRF) = try macSignIn()
        var want: [HostOp] = []
        for (body, op) in zip(Self.workerActions, [HostOp.workerAdd, .workerEnd]) {
            let r = try macJSON(macCookie, macCSRF, "/api/v1/actions", body, remote: false)
            XCTAssertEqual(r.status, 202, r.text)
            want.append(op)
            let deadline = Date().addingTimeInterval(5)
            while fake.performedOps.count < want.count && Date() < deadline { usleep(10_000) }
            XCTAssertEqual(fake.performedOps, want)
        }
        let p = try macJSON(macCookie, macCSRF, "/api/v1/worker-plan", #"{"workspace":"launch","task":"list the files"}"#, remote: false)
        XCTAssertEqual(p.status, 200, p.text)
        XCTAssertEqual(try JSONDecoder().decode(WebWorkerPlan.self, from: p.body).name, "bot1")
        XCTAssertEqual(fake.performedOps, want, "the plan is a read: no operation")
    }

    static let lifecycleActions = WorkspaceVerb.allCases.map { v in
        #"{"action":"workspace-\#(v.rawValue)","workspace":"launch","ifPlan":"0123456789abcdef"\#(v.confirm == .typed ? #","confirm":"launch""# : "")}"#
    }

    /// A workspace's lifecycle is this Mac's own browser only, whatever serve.chat and serve.mac_sessions say: every verb 403
    /// `mac-only` with the family's words and its plan route 403 `mac-screen` — nothing reaches the daemon. This Mac's browser:
    /// 202, each exactly its HostOp; the plan 200, a read.
    func testTheLifecycleIsThisMacsBrowserOnlyWhateverTheServeSettings() async throws {
        try await start(macSessions: "interactive", chat: "write")
        let (devCookie, devCSRF) = try await admit()
        for (ms, chat) in [("interactive", "write"), ("off", "off"), ("watch", "read")] {
            try "[serve]\nmac_sessions = \"\(ms)\"\nchat = \"\(chat)\"\n".write(to: dir.appendingPathComponent("xdg/doz/doz.toml"), atomically: true, encoding: .utf8)
            for body in Self.lifecycleActions {
                let r = try macJSON(devCookie, devCSRF, "/api/v1/actions", body, remote: true)
                XCTAssertEqual(r.status, 403, r.text)
                XCTAssertTrue(r.text.contains("\"mac-only\""), r.text)
                XCTAssertTrue(r.text.contains("only in this Mac's own browser, or with doz workspace"), r.text)
            }
            let rp = try macJSON(devCookie, devCSRF, "/api/v1/workspace-lifecycle-plan", #"{"workspace":"launch","verb":"sleep"}"#, remote: true)
            XCTAssertEqual(rp.status, 403, rp.text)
            XCTAssertTrue(rp.text.contains("\"mac-screen\""), rp.text)
            XCTAssertTrue(fake.performedOps.isEmpty, "nothing reached the daemon (\(ms), \(chat))")
            XCTAssertFalse(fake.workspaceCalls.contains { $0.hasPrefix("lifecycle-plan") }, "the plan was not asked")
        }
        let (macCookie, macCSRF) = try macSignIn()
        var want: [HostOp] = []
        for (body, v) in zip(Self.lifecycleActions, WorkspaceVerb.allCases) {
            let r = try macJSON(macCookie, macCSRF, "/api/v1/actions", body, remote: false)
            XCTAssertEqual(r.status, 202, r.text)
            want.append(v.hostOp)
            let deadline = Date().addingTimeInterval(5)
            while fake.performedOps.count < want.count && Date() < deadline { usleep(10_000) }
            XCTAssertEqual(fake.performedOps, want)
        }
        let bad = try macJSON(macCookie, macCSRF, "/api/v1/actions", #"{"action":"workspace-delete","workspace":"launch","ifPlan":"0123456789abcdef","confirm":"lunch"}"#, remote: false)
        XCTAssertEqual(bad.status, 400, "a forged body with another name: refused before the daemon (\(bad.text))")
        let p = try macJSON(macCookie, macCSRF, "/api/v1/workspace-lifecycle-plan", #"{"workspace":"launch","verb":"sleep"}"#, remote: false)
        XCTAssertEqual(p.status, 200, p.text)
        XCTAssertEqual(try JSONDecoder().decode(WebWorkspaceLifecyclePlan.self, from: p.body).verb, "sleep")
        XCTAssertEqual(fake.performedOps, want, "the plan is a read: no operation")
    }

    /// A room archived or removed, a run's archive written again: another computer gets 403 `mac-only` whatever the serve
    /// settings say, and the room plan route 403 `mac-screen`; nothing reaches the daemon. This Mac's own browser: each
    /// exactly its HostOp; rm with another name than the room's is refused before the daemon (400).
    func testRoomActionsAreThisMacsBrowserOnlyWhateverTheServeSettings() async throws {
        try await start(macSessions: "interactive", chat: "write")
        let (devCookie, devCSRF) = try await admit()
        let bodies = [#"{"action":"chat-room-archive","room":"launch","ifPlan":"0123456789abcdef"}"#,
                      #"{"action":"chat-room-rm","room":"launch","ifPlan":"0123456789abcdef","confirm":"launch"}"#,
                      #"{"action":"workspace-run-archive","workspace":"launch","run":"2026-11-20-1"}"#]
        for (ms, chat) in [("interactive", "write"), ("off", "off"), ("watch", "read")] {
            try "[serve]\nmac_sessions = \"\(ms)\"\nchat = \"\(chat)\"\n".write(to: dir.appendingPathComponent("xdg/doz/doz.toml"), atomically: true, encoding: .utf8)
            for body in bodies {
                let r = try macJSON(devCookie, devCSRF, "/api/v1/actions", body, remote: true)
                XCTAssertEqual(r.status, 403, r.text)
                XCTAssertTrue(r.text.contains("\"mac-only\""), r.text)
            }
            let rp = try macJSON(devCookie, devCSRF, "/api/v1/chat-room-plan", #"{"room":"launch","verb":"rm"}"#, remote: true)
            XCTAssertEqual(rp.status, 403, rp.text)
            XCTAssertTrue(rp.text.contains("\"mac-screen\""), rp.text)
            XCTAssertTrue(fake.performedOps.isEmpty, "nothing reached the daemon (\(ms), \(chat))")
        }
        let (macCookie, macCSRF) = try macSignIn()
        let forged = try macJSON(macCookie, macCSRF, "/api/v1/actions", #"{"action":"chat-room-rm","room":"launch","ifPlan":"0123456789abcdef","confirm":"lunch"}"#, remote: false)
        XCTAssertEqual(forged.status, 400, "a forged name: refused before the daemon (\(forged.text))")
        let loose = try macJSON(macCookie, macCSRF, "/api/v1/actions", #"{"action":"chat-room-rm","room":"launch","ifPlan":"0123456789abcdef","confirm":"launch","loose":true}"#, remote: false)
        XCTAssertEqual(loose.status, 400, "never --loose from a browser (\(loose.text))")
        var want: [HostOp] = []
        for (body, op) in zip(bodies, [HostOp.chatRoomArchive, .chatRoomRm, .workspaceRunArchive]) {
            let r = try macJSON(macCookie, macCSRF, "/api/v1/actions", body, remote: false)
            XCTAssertEqual(r.status, 202, r.text)
            want.append(op)
            let deadline = Date().addingTimeInterval(5)
            while fake.performedOps.count < want.count && Date() < deadline { usleep(10_000) }
            XCTAssertEqual(fake.performedOps, want)
        }
    }

    /// A space file: another computer reads it and plans it only with serve.chat read or write (403 `space-remote` while off),
    /// never saves it (`canSave` false, the command instead) and its save is 403 `mac-only` whatever the serve settings —
    /// nothing reaches the daemon; its state is a read whose sessions on this Mac follow serve.mac_sessions.
    func testTheSpaceFileIsSavedOnlyInThisMacsBrowserAndReadAsServeChatAllows() async throws {
        try await start()
        let (devCookie, devCSRF) = try await admit()
        let sha = String(repeating: "a", count: 64)
        let save = #"{"action":"workspace-space-save","workspace":"demo","text":"doz: space/3\nspace: demo\n","ifMatch":"\#(sha)"}"#
        for path in ["/api/v1/workspace-space", "/api/v1/workspace-space-plan"] {
            let body = path.hasSuffix("plan") ? #"{"workspace":"demo","text":"doz: space/3\n"}"# : #"{"workspace":"demo"}"#
            let r = try macJSON(devCookie, devCSRF, path, body, remote: true)
            XCTAssertEqual(r.status, 403, r.text)
            XCTAssertTrue(r.text.contains("space-remote") && r.text.contains("serve.chat"), r.text)
        }
        let state = try macJSON(devCookie, devCSRF, "/api/v1/workspace-state", #"{"workspace":"demo"}"#, remote: true)
        XCTAssertEqual(state.status, 200, state.text)
        XCTAssertEqual(fake.workspaceCalls.last, "state demo hidden", "this Mac's sessions hidden while serve.mac_sessions is off")
        let frames = try macJSON(devCookie, devCSRF, "/api/v1/workspace-run-frames", #"{"workspace":"demo","run":"2026-11-20-1"}"#, remote: true)
        XCTAssertEqual(frames.status, 200, frames.text)
        XCTAssertEqual(fake.workspaceCalls.last, "frames demo 2026-11-20-1 hidden")
        for (ms, chat) in [("off", "off"), ("watch", "read"), ("interactive", "write")] {
            try FileManager.default.createDirectory(at: dir.appendingPathComponent("xdg/doz"), withIntermediateDirectories: true)
            try "[serve]\nmac_sessions = \"\(ms)\"\nchat = \"\(chat)\"\n".write(to: dir.appendingPathComponent("xdg/doz/doz.toml"), atomically: true, encoding: .utf8)
            let r = try macJSON(devCookie, devCSRF, "/api/v1/actions", save, remote: true)
            XCTAssertEqual(r.status, 403, r.text)
            XCTAssertTrue(r.text.contains("\"mac-only\"") && r.text.contains("A space file is changed only in this Mac's own browser"), r.text)
        }
        XCTAssertTrue(fake.performedOps.isEmpty, "nothing reached the daemon")
        let log = WebServeAudit.recent(dir.appendingPathComponent("serve/audit.jsonl"))
        XCTAssertTrue(log.contains { $0.kind == "refused" && $0.outcome == "space-remote" })
        XCTAssertTrue(log.contains { $0.kind == "refused" && $0.outcome == "mac-only" })
    }

    func testTheSpaceFileIsReadRemotelyWithServeChatButNeverSaved() async throws {
        try await start(macSessions: "watch", chat: "read")
        let (devCookie, devCSRF) = try await admit()
        let r = try macJSON(devCookie, devCSRF, "/api/v1/workspace-space", #"{"workspace":"demo"}"#, remote: true)
        XCTAssertEqual(r.status, 200, r.text)
        let f = try JSONDecoder().decode(WebSpaceFile.self, from: r.body)
        XCTAssertFalse(f.canSave)
        XCTAssertEqual(f.command, "doz workspace edit demo --space-file ~/work/demo.space.yaml --if-match \(f.sha256)")
        let p = try macJSON(devCookie, devCSRF, "/api/v1/workspace-space-plan", #"{"workspace":"demo","text":"doz: space/3\n"}"#, remote: true)
        XCTAssertEqual(p.status, 200, p.text)
        _ = try macJSON(devCookie, devCSRF, "/api/v1/workspace-state", #"{"workspace":"demo"}"#, remote: true)
        XCTAssertEqual(fake.workspaceCalls.last, "state demo", "serve.mac_sessions watch: shown")
        let (macCookie, macCSRF) = try macSignIn()
        let own = try JSONDecoder().decode(WebSpaceFile.self, from: try macJSON(macCookie, macCSRF, "/api/v1/workspace-space", #"{"workspace":"demo"}"#, remote: false).body)
        XCTAssertTrue(own.canSave, "this Mac's own browser saves")
        XCTAssertTrue(fake.performedOps.isEmpty)
    }

    /// 781: a workspace made without a space file is drawn from its document — read as the space file is (another computer only
    /// with serve.chat read or write), and while serve.mac_sessions keeps this Mac's sessions from it, its agents on this Mac are
    /// left out of the drawing (no session's name), as the workspace's page leaves them out.
    func testTheDocumentIsDrawnForAnotherComputerAsServeChatAndServeMacSessionsAllow() async throws {
        try await start(macSessions: "off", chat: "off")
        let (devCookie, devCSRF) = try await admit()
        let refused = try macJSON(devCookie, devCSRF, "/api/v1/workspace-doc", #"{"workspace":"plain"}"#, remote: true)
        XCTAssertEqual(refused.status, 403, refused.text)
        XCTAssertTrue(refused.text.contains("\"space-remote\""), refused.text)
        XCTAssertFalse(fake.workspaceCalls.contains("doc plain"), "nothing asked of the daemon")
        try "[serve]\nmac_sessions = \"off\"\nchat = \"read\"\n".write(to: dir.appendingPathComponent("xdg/doz/doz.toml"), atomically: true, encoding: .utf8)
        let hidden = try macJSON(devCookie, devCSRF, "/api/v1/workspace-doc", #"{"workspace":"plain"}"#, remote: true)
        XCTAssertEqual(hidden.status, 200, hidden.text)
        let h = try JSONDecoder().decode(WebWorkspaceDoc.self, from: hidden.body)
        XCTAssertFalse(hidden.text.contains("secret-session-name"), hidden.text)
        XCTAssertFalse(h.picture.contains("\"w1\""), "the fenced worker on this Mac is not drawn: \(h.picture)")
        XCTAssertTrue(h.picture.contains("\"vm1\""), "a VM's worker is: \(h.picture)")
        XCTAssertNil(h.subjects["agent:adopted"])
        try "[serve]\nmac_sessions = \"watch\"\nchat = \"read\"\n".write(to: dir.appendingPathComponent("xdg/doz/doz.toml"), atomically: true, encoding: .utf8)
        let shown = try JSONDecoder().decode(WebWorkspaceDoc.self, from: try macJSON(devCookie, devCSRF, "/api/v1/workspace-doc", #"{"workspace":"plain"}"#, remote: true).body)
        XCTAssertTrue(shown.picture.contains("secret-session-name"), "serve.mac_sessions watch: shown")
        XCTAssertNotEqual(shown.sha256, h.sha256, "a different drawing, a different sha")
        XCTAssertTrue(fake.performedOps.isEmpty)
    }

    /// A fenced session's site allowed from another computer: 403 `mac-only` whatever serve.mac_sessions and serve.chat say,
    /// one audit line each, nothing sent to the daemon; this Mac's own browser: 202, exactly `net-policy` on `@mac` with the
    /// session. The wide views read from another computer: held secrets a count only, this Mac's agents per serve.mac_sessions.
    func testMacNetPolicyIsThisMacsBrowserOnlyWhateverTheServeSettings() async throws {
        try await start(macSessions: "interactive", chat: "write")
        let (devCookie, devCSRF) = try await admit()
        let body = #"{"action":"mac-net-policy","session":"agent","grant":["site:fonts.example-cdn.com"]}"#
        var refusals = 0
        for (ms, chat) in [("interactive", "write"), ("off", "off"), ("watch", "read")] {
            try "[serve]\nmac_sessions = \"\(ms)\"\nchat = \"\(chat)\"\n".write(to: dir.appendingPathComponent("xdg/doz/doz.toml"), atomically: true, encoding: .utf8)
            let r = try macJSON(devCookie, devCSRF, "/api/v1/actions", body, remote: true)
            XCTAssertEqual(r.status, 403, r.text)
            XCTAssertTrue(r.text.contains("\"mac-only\""), r.text)
            XCTAssertTrue(r.text.contains("doz net allow @mac --session SESSION"), r.text)
            refusals += 1
            XCTAssertTrue(fake.performedOps.isEmpty, "nothing reached the daemon (\(ms), \(chat))")
            let log = WebServeAudit.recent(dir.appendingPathComponent("serve/audit.jsonl"))
            XCTAssertTrue(log.contains { $0.kind == "refused" && $0.outcome == "mac-only" && $0.route == "actions" }, "audited (\(refusals))")
            // The wide view, from another computer: no held secret's name; this Mac's agent only with serve.mac_sessions on.
            let rr = try macJSON(devCookie, devCSRF, "/api/v1/workspace-reach", #"{"workspace":"demo"}"#, remote: true)
            XCTAssertEqual(rr.status, 200, rr.text)
            XCTAssertFalse(rr.text.contains("MUSIC_API_TOKEN"), rr.text)
            let reach = try JSONDecoder().decode(WebWorkspaceReach.self, from: rr.body)
            XCTAssertEqual(reach.agents.first?.heldCount, 1)
            XCTAssertEqual(reach.agents.map(\.name), ms == "off" ? ["wsa"] : ["wsa", "build"])
            XCTAssertEqual(reach.hidden, ms == "off" ? 1 : 0)
            let act = try macJSON(devCookie, devCSRF, "/api/v1/workspace-activity", #"{"workspace":"demo"}"#, remote: true)
            XCTAssertEqual(try WebServeAudit.decoder.decode(WebWorkspaceActivity.self, from: act.body).hidden, ms == "off" ? 1 : 0)
        }
        let (macCookie, macCSRF) = try macSignIn()
        let r = try macJSON(macCookie, macCSRF, "/api/v1/actions", body, remote: false)
        XCTAssertEqual(r.status, 202, r.text)
        let deadline = Date().addingTimeInterval(5)
        while fake.performedOps.isEmpty && Date() < deadline { usleep(10_000) }
        XCTAssertEqual(fake.performedOps, [.netPolicy])
    }

    /// Turning chat on and making a workspace's room are this Mac's own browser only, whatever serve.chat says: 403
    /// `mac-only` with their words, nothing sent to the daemon.
    func testChatOnAndMakeRoomAreThisMacsBrowserOnly() async throws {
        try await start(macSessions: "interactive", chat: "write")
        let (devCookie, devCSRF) = try await admit()
        for (body, words) in [(#"{"action":"chat-on","name":"ada"}"#, "doz chat on"), (#"{"action":"workspace-make-room","workspace":"demo"}"#, "--make-room")] {
            let r = try macJSON(devCookie, devCSRF, "/api/v1/actions", body, remote: true)
            XCTAssertEqual(r.status, 403, r.text)
            XCTAssertTrue(r.text.contains("\"mac-only\""), r.text)
            XCTAssertTrue(r.text.contains(words), r.text)
        }
        XCTAssertTrue(fake.performedOps.isEmpty, "nothing reached the daemon")
        let (macCookie, macCSRF) = try macSignIn()
        let r = try macJSON(macCookie, macCSRF, "/api/v1/actions", #"{"action":"workspace-make-room","workspace":"demo"}"#, remote: false)
        XCTAssertEqual(r.status, 202, r.text)
        let deadline = Date().addingTimeInterval(5)
        while fake.performedOps.isEmpty && Date() < deadline { usleep(10_000) }
        XCTAssertEqual(fake.performedOps, [.workspaceEdit])
    }

    /// Answering an ask is this Mac's own browser only, whatever serve.chat says (off, read, write): 403 `mac-only` with its
    /// words, one audit line, nothing sent to the daemon — and the answer's words in no audit line. This Mac's browser
    /// sends exactly `chat-decide`.
    func testAnAskIsAnsweredOnlyInThisMacsBrowserWhateverTheServeSettings() async throws {
        try await start(macSessions: "interactive", chat: "write")
        let (devCookie, devCSRF) = try await admit()
        let body = ##"{"action":"chat-decide","room":"demo","ask":"#3","reply":"after lunch","actionId":"0b7e2c4a-1111-4222-8333-444455556666"}"##
        for chat in ["write", "read", "off"] {
            try "[serve]\nmac_sessions = \"interactive\"\nchat = \"\(chat)\"\n".write(to: dir.appendingPathComponent("xdg/doz/doz.toml"), atomically: true, encoding: .utf8)
            let r = try macJSON(devCookie, devCSRF, "/api/v1/actions", body, remote: true)
            XCTAssertEqual(r.status, 403, r.text)
            XCTAssertTrue(r.text.contains("\"mac-only\""), r.text)
            XCTAssertTrue(r.text.contains("doz chat decide"), r.text)
            XCTAssertTrue(fake.performedOps.isEmpty, "nothing reached the daemon (\(chat))")
        }
        let log = WebServeAudit.recent(dir.appendingPathComponent("serve/audit.jsonl"))
        XCTAssertTrue(log.contains { $0.kind == "refused" && $0.outcome == "mac-only" && $0.route == "actions" }, "audited")
        let raw = (try? String(contentsOf: dir.appendingPathComponent("serve/audit.jsonl"), encoding: .utf8)) ?? ""
        XCTAssertFalse(raw.contains("lunch"), "the answer's words in no audit line")
        let (macCookie, macCSRF) = try macSignIn()
        let r = try macJSON(macCookie, macCSRF, "/api/v1/actions", body, remote: false)
        XCTAssertEqual(r.status, 202, r.text)
        XCTAssertFalse(r.text.contains("lunch"), "the operation's label carries no answer")
        let deadline = Date().addingTimeInterval(5)
        while fake.performedOps.isEmpty && Date() < deadline { usleep(10_000) }
        XCTAssertEqual(fake.performedOps, [.chatDecide])
    }

    /// Removing ended sessions on this Mac is this Mac's own browser only, whatever serve.mac_sessions says (off, watch,
    /// interactive): 403 `mac-only` with its words, one audit line, nothing sent to the daemon. And the gap is closed: a remote
    /// `mac-session-end` (interactive) reaches the daemon only as an end of a RUNNING session — never a forget.
    func testForgettingIsThisMacsBrowserOnlyWhateverTheServeSettings() async throws {
        try await start(macSessions: "interactive", chat: "write")
        let (devCookie, devCSRF) = try await admit()
        var refusals = 0
        for ms in ["interactive", "off", "watch"] {
            try "[serve]\nmac_sessions = \"\(ms)\"\n".write(to: dir.appendingPathComponent("xdg/doz/doz.toml"), atomically: true, encoding: .utf8)
            for body in [#"{"action":"mac-session-forget","session":"old"}"#, #"{"action":"mac-sessions-forget-ended","sessions":["old","older"]}"#] {
                let r = try macJSON(devCookie, devCSRF, "/api/v1/actions", body, remote: true)
                XCTAssertEqual(r.status, 403, r.text)
                XCTAssertTrue(r.text.contains("\"mac-only\""), r.text)
                XCTAssertTrue(r.text.contains("doz sessions @mac --forget-ended"), r.text)
                refusals += 1
                XCTAssertTrue(fake.performedOps.isEmpty, "nothing reached the daemon (\(ms))")
                let log = WebServeAudit.recent(dir.appendingPathComponent("serve/audit.jsonl"))
                XCTAssertTrue(log.contains { $0.kind == "refused" && $0.outcome == "mac-only" && $0.route == "actions" }, "audited (\(refusals))")
            }
        }
        // A remote interactive End: the daemon is asked to end a running session only.
        try "[serve]\nmac_sessions = \"interactive\"\n".write(to: dir.appendingPathComponent("xdg/doz/doz.toml"), atomically: true, encoding: .utf8)
        let end = try macJSON(devCookie, devCSRF, "/api/v1/actions", #"{"action":"mac-session-end","session":"old","confirm":"old"}"#, remote: true)
        XCTAssertEqual(end.status, 202, end.text)
        var deadline = Date().addingTimeInterval(5)
        while fake.performed.isEmpty && Date() < deadline { usleep(10_000) }
        XCTAssertEqual(fake.performed.map(\.op), [.sessionEnd])
        XCTAssertEqual(fake.performed.first?.onlyRunning, true, "a remote End can no longer forget an ended session")
        // This Mac's own browser: 202, exactly session-forget.
        let (macCookie, macCSRF) = try macSignIn()
        let r = try macJSON(macCookie, macCSRF, "/api/v1/actions", #"{"action":"mac-session-forget","session":"old"}"#, remote: false)
        XCTAssertEqual(r.status, 202, r.text)
        deadline = Date().addingTimeInterval(5)
        while fake.performedOps.count < 2 && Date() < deadline { usleep(10_000) }
        XCTAssertEqual(fake.performedOps, [.sessionEnd, .sessionForget])
    }

    static let botActions = [
        #"{"action":"bot-new","name":"mira","agent":"claude-code","isolation":"fenced"}"#,
        #"{"action":"bot-set","name":"mira","model":"sonnet"}"#,
        #"{"action":"bot-retire","name":"mira","confirm":"mira"}"#,
        #"{"action":"bot-adopt","name":"olda","agent":"codex","confirm":"olda"}"#,
        #"{"action":"bot-token","name":"mira","confirm":"mira"}"#,
    ]

    /// Every bot change is this Mac's own browser only, whatever serve.chat and serve.mac_sessions say — over http and over
    /// https through a trusted proxy: 403 `mac-only` with the family's words, one audit line, nothing sent to the daemon.
    /// This Mac's browser: 202, each exactly its HostOp, heldOnly.
    func testBotChangesAreThisMacsBrowserOnlyWhateverTheServeSettings() async throws {
        try await start(WebServeConfig(port: 0, bind: .loopback, publicOrigins: [WebPublicOrigin("https://doz.home.example")!],
                                       trustedProxies: [WebCIDR("127.0.0.1")!], advertise: false), macSessions: "interactive", chat: "write")
        let (devCookie, devCSRF) = try await admit()
        for body in Self.botActions {
            let r = try macJSON(devCookie, devCSRF, "/api/v1/actions", body, remote: true)
            XCTAssertEqual(r.status, 403, r.text)
            XCTAssertTrue(r.text.contains("\"mac-only\""), r.text)
            XCTAssertTrue(r.text.contains("Agents / Bots are changed only in this Mac's own browser"), r.text)
        }
        // Over https, through the proxy: the same.
        let viaProxy = ["Host": "doz.home.example", "X-Forwarded-Proto": "https", "X-Forwarded-For": "192.168.86.48"]
        let inv = await server.share(by: "the Mac")
        var h = viaProxy
        h["Origin"] = "https://doz.home.example"
        h["Authorization"] = "Bearer \(inv.testToken)"
        let s = try req("/api/v1/session", h, method: "POST")
        XCTAssertEqual(s.status, 200, s.text)
        let cookie = String(try XCTUnwrap(s.header("set-cookie")).split(separator: ";")[0])
        let csrf = try XCTUnwrap((try JSONSerialization.jsonObject(with: s.body) as? [String: Any])?["csrf"] as? String)
        var post = viaProxy
        post["Cookie"] = cookie; post["X-Doz-CSRF"] = csrf; post["Origin"] = "https://doz.home.example"; post["Content-Type"] = "application/json"
        for body in Self.botActions {
            let r = try req("/api/v1/actions", post, method: "POST", body: body)
            XCTAssertEqual(r.status, 403, r.text)
            XCTAssertTrue(r.text.contains("\"mac-only\""), r.text)
        }
        XCTAssertTrue(fake.performedOps.isEmpty, "nothing reached the daemon")
        let log = WebServeAudit.recent(dir.appendingPathComponent("serve/audit.jsonl"))
        XCTAssertTrue(log.contains { $0.kind == "refused" && $0.outcome == "mac-only" && $0.route == "actions" }, "audited")
        let (macCookie, macCSRF) = try macSignIn()
        var want: [HostOp] = []
        for (body, op) in zip(Self.botActions, [HostOp.botNew, .botSet, .botRetire, .botAdopt, .botToken]) {
            let r = try macJSON(macCookie, macCSRF, "/api/v1/actions", body, remote: false)
            XCTAssertEqual(r.status, 202, r.text)
            want.append(op)
            let deadline = Date().addingTimeInterval(5)
            while fake.performedOps.count < want.count && Date() < deadline { usleep(10_000) }
            XCTAssertEqual(fake.performedOps, want)
        }
        XCTAssertTrue(fake.performedBotRequests.allSatisfy { $0.heldOnly == true }, "every one heldOnly")
        XCTAssertEqual(fake.performedBotRequests.count, 5)
    }

    func testServeChatWriteEditsTheBriefAuditedAsOneLine() async throws {
        try await start(chat: "write")
        let (devCookie, devCSRF) = try await admit()
        let ok = try macJSON(devCookie, devCSRF, "/api/v1/actions", Self.briefEdit, remote: true)
        XCTAssertEqual(ok.status, 202, ok.text)
        let deadline = Date().addingTimeInterval(5)
        while fake.performedOps.isEmpty && Date() < deadline { usleep(10_000) }
        XCTAssertEqual(fake.performedOps, [.workspaceEdit])
        while try req("/api/v1/operations", ["Cookie": devCookie]).text.contains("\"state\":\"running\"") && Date() < deadline { usleep(10_000) }
        let changes = WebServeAudit.recent(dir.appendingPathComponent("serve/audit.jsonl")).filter { $0.kind == "change" }
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes.first?.action, "workspace-brief")
        let raw = (try? String(contentsOf: dir.appendingPathComponent("serve/audit.jsonl"), encoding: .utf8)) ?? ""
        XCTAssertFalse(raw.contains("Shorter."), "never the brief")
    }

    func testWatchLetsAnotherComputerLookButNeverType() async throws {
        try await start(macSessions: "watch")
        let (devCookie, devCSRF) = try await admit()
        let list = try req("/api/v1/mac/sessions", ["Cookie": devCookie])
        XCTAssertEqual(list.status, 200, list.text)
        XCTAssertTrue(list.text.contains("\"access\":\"watch\""), list.text)
        XCTAssertEqual(try macJSON(devCookie, devCSRF, "/api/v1/mac/terminal-ticket", #"{"mode":"watch","session":"build"}"#, remote: true).status, 200)
        let typing = try macJSON(devCookie, devCSRF, "/api/v1/mac/terminal-ticket", #"{"mode":"interactive","session":"build"}"#, remote: true)
        XCTAssertEqual(typing.status, 403, typing.text)
        let end = try macJSON(devCookie, devCSRF, "/api/v1/actions", #"{"action":"mac-session-restart","session":"build","confirm":"build"}"#, remote: true)
        XCTAssertEqual(end.status, 403, end.text)
        XCTAssertEqual(try macJSON(devCookie, devCSRF, "/api/v1/grids", #"{"items":[{"sandbox":"@mac","session":"build","gen":0}]}"#, remote: true).status, 200)
        // The refusals are in the LAN's audit log.
        let log = WebServeAudit.recent(dir.appendingPathComponent("serve/audit.jsonl"))
        XCTAssertTrue(log.contains { $0.kind == "refused" && $0.outcome == "mac-session" })
    }

    func testInteractiveLetsAnotherComputerType() async throws {
        try await start(macSessions: "interactive")
        let (devCookie, devCSRF) = try await admit()
        XCTAssertEqual(try macJSON(devCookie, devCSRF, "/api/v1/mac/terminal-ticket", #"{"mode":"interactive","session":"build"}"#, remote: true).status, 200)
        XCTAssertEqual(try macJSON(devCookie, devCSRF, "/api/v1/actions", #"{"action":"mac-session-end","session":"build","confirm":"build"}"#, remote: true).status, 202)
    }

    /// A sandbox's connection never reaches the routes of the sessions on this Mac either (the accept gate drops it first).
    func testASandboxNeverReachesTheSessionsOnThisMac() async throws {
        try await start(macSessions: "interactive")
        let (macCookie, _) = try macSignIn()
        state.admitOverride = { _, _ in .sandbox }
        XCTAssertThrowsError(try macReq("/api/v1/mac/sessions", ["Cookie": macCookie]), "dropped before a byte is read")
        XCTAssertThrowsError(try req("/api/v1/mac/terminal-socket", ["Cookie": macCookie]))
        state.admitOverride = nil
        XCTAssertEqual(try macReq("/api/v1/mac/sessions", ["Cookie": macCookie]).status, 200)
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
