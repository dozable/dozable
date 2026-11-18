import XCTest
@testable import DozableHost

/// 715: `doz ui publish tailscale`'s plan — the node's name, the paths under the store, every argv (tailscaled and each
/// tailscale command, always naming Dozable's own socket), the LaunchAgent's plist (round-tripped), what the node and its
/// serve config say, port 80's redirect target, the settings written and put back (through the settings code, in a
/// scratch file), Homebrew's tailscale found only through the seam in a test, and the agent installed/removed against a
/// scratch folder and a fake launchctl (a closure: nothing is run).
final class TailscalePublishTests: XCTestCase {
    let store = DozableStore(root: URL(fileURLWithPath: "/tmp/doz-ts--store"))
    var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("doz-tspub-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    // MARK: the name

    func testTheDefaultNameIsDozableAndTheMacsLocalHostNameAsOneDNSLabel() {
        XCTAssertEqual(TailscalePublish.defaultName(mac: "m1max"), "dozable-m1max")
        XCTAssertEqual(TailscalePublish.defaultName(mac: "Johns-MacBook-Pro"), "dozable-johns-macbook-pro")
        XCTAssertEqual(TailscalePublish.defaultName(mac: "John's MacBook  Pro (2)"), "dozable-john-s-macbook-pro-2")
        XCTAssertEqual(TailscalePublish.defaultName(mac: "--Mac--"), "dozable-mac")
        XCTAssertEqual(TailscalePublish.defaultName(mac: nil), "dozable")
        XCTAssertEqual(TailscalePublish.defaultName(mac: "!!!"), "dozable")
        let long = TailscalePublish.defaultName(mac: String(repeating: "a", count: 70))
        XCTAssertEqual(long.count, 63)
        XCTAssertTrue(long.hasPrefix("dozable-a"))
        // Cut at 63 never leaves a hyphen at the end.
        let cut = TailscalePublish.defaultName(mac: String(repeating: "a", count: 54) + "-bbbb")
        XCTAssertFalse(cut.hasSuffix("-"))
        XCTAssertLessThanOrEqual(cut.count, 63)
    }

    func testANameGivenIsCheckedNeverChanged() {
        XCTAssertEqual(TailscalePublish.validName("Doz-Studio"), "doz-studio")
        XCTAssertEqual(TailscalePublish.validName("a"), "a")
        XCTAssertNil(TailscalePublish.validName(""))
        XCTAssertNil(TailscalePublish.validName("-doz"))
        XCTAssertNil(TailscalePublish.validName("doz-"))
        XCTAssertNil(TailscalePublish.validName("doz studio"))
        XCTAssertNil(TailscalePublish.validName("doz.studio"))
        XCTAssertNil(TailscalePublish.validName(String(repeating: "a", count: 64)))
    }

    // MARK: paths and argv

    func testThePathsAreUnderTheStore() {
        let p = TailscalePublish.paths(store)
        XCTAssertEqual(p.stateDir.path, "/tmp/doz-ts--store/tailscale/state")
        XCTAssertEqual(p.socket.path, "/tmp/doz-ts--store/tailscale/tailscaled.sock")
        XCTAssertEqual(p.redirectSocket.path, "/tmp/doz-ts--store/tailscale/http.sock")
        XCTAssertEqual(p.log.path, "/tmp/doz-ts--store/tailscale/tailscaled.log")
        XCTAssertEqual(p.marker.path, "/tmp/doz-ts--store/tailscale/published.json")
        XCTAssertTrue(TailscalePublish.socketFits(p.socket))
        XCTAssertFalse(TailscalePublish.socketFits(URL(fileURLWithPath: "/" + String(repeating: "x", count: 110))))
        XCTAssertEqual(TailscalePublish.label(store), "com.dozable.tailscale." + MacPlace.storeHash(store))
        XCTAssertNotEqual(TailscalePublish.label(store), TailscalePublish.label(DozableStore(root: URL(fileURLWithPath: "/tmp/other"))))
    }

    func testEveryArgvIsHomebrewsFormulaAndNamesDozablesOwnSocket() {
        let b = TailscalePublish.Binaries(prefix: "/opt/homebrew")
        let p = TailscalePublish.paths(store)
        XCTAssertEqual(b.tailscale, "/opt/homebrew/opt/tailscale/bin/tailscale")
        XCTAssertEqual(b.tailscaled, "/opt/homebrew/opt/tailscale/bin/tailscaled")
        XCTAssertEqual(TailscalePublish.daemonArguments(b, p), [
            "/opt/homebrew/opt/tailscale/bin/tailscaled", "--tun=userspace-networking", "--statedir=/tmp/doz-ts--store/tailscale/state",
            "--socket=/tmp/doz-ts--store/tailscale/tailscaled.sock", "--port=0"])
        XCTAssertEqual(TailscalePublish.cli(b, p, TailscalePublish.statusArguments()),
                       ["/opt/homebrew/opt/tailscale/bin/tailscale", "--socket=/tmp/doz-ts--store/tailscale/tailscaled.sock", "status", "--json"])
        XCTAssertEqual(TailscalePublish.upArguments(name: "dozable-m1max", timeout: 300), ["up", "--hostname=dozable-m1max", "--timeout=300s"])
        XCTAssertEqual(TailscalePublish.setArguments(name: "dozable-m1max"), ["set", "--hostname=dozable-m1max"])
        XCTAssertEqual(TailscalePublish.serveHTTPSArguments(port: 7443), ["serve", "--bg", "--yes", "--https=443", "http://127.0.0.1:7443"])
        XCTAssertEqual(TailscalePublish.serveHTTPArguments(p), ["serve", "--bg", "--yes", "--http=80", "unix:/tmp/doz-ts--store/tailscale/http.sock"])
        XCTAssertEqual(TailscalePublish.serveResetArguments(), ["serve", "reset"])
        XCTAssertEqual(TailscalePublish.serveStatusArguments(), ["serve", "status", "--json"])
        XCTAssertEqual(TailscalePublish.logoutArguments(), ["logout"])
        XCTAssertEqual(TailscalePublish.httpsTarget(port: 7443), "http://127.0.0.1:7443")
        XCTAssertEqual(TailscalePublish.httpTarget(p), "unix:/tmp/doz-ts--store/tailscale/http.sock")
    }

    func testThePlistKeepsTailscaledRunning() throws {
        let b = TailscalePublish.Binaries(prefix: "/opt/homebrew")
        let text = TailscalePublish.renderPlist(store, b)
        let p = try XCTUnwrap(try PropertyListSerialization.propertyList(from: Data(text.utf8), format: nil) as? [String: Any])
        XCTAssertEqual(p["Label"] as? String, TailscalePublish.label(store))
        XCTAssertEqual(p["ProgramArguments"] as? [String], TailscalePublish.daemonArguments(b, TailscalePublish.paths(store)))
        XCTAssertEqual(p["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(p["KeepAlive"] as? Bool, true)
        XCTAssertEqual(p["StandardErrorPath"] as? String, "/tmp/doz-ts--store/tailscale/tailscaled.log")
        XCTAssertEqual(p["StandardOutPath"] as? String, "/tmp/doz-ts--store/tailscale/tailscaled.log")
        XCTAssertNil(p["EnvironmentVariables"])
        XCTAssertEqual(Set(p.keys), ["Label", "ProgramArguments", "RunAtLoad", "KeepAlive", "ProcessType", "StandardOutPath", "StandardErrorPath"])
    }

    // MARK: what the node says

    func testStatusSignedInAndNot() throws {
        let running = #"{"Version":"1.104.7","BackendState":"Running","AuthURL":"","Self":{"HostName":"dozable-m1max","DNSName":"dozable-m1max.junco-shaula.ts.net.","Online":true},"MagicDNSSuffix":"junco-shaula.ts.net"}"#
        let s = try XCTUnwrap(TailscalePublish.parseStatus(Data(running.utf8)))
        XCTAssertTrue(s.signedIn)
        XCTAssertEqual(s.dnsName, "dozable-m1max.junco-shaula.ts.net")
        XCTAssertEqual(s.hostName, "dozable-m1max")
        XCTAssertNil(s.authURL)
        XCTAssertEqual(TailscalePublish.origin(dnsName: s.dnsName!), "https://dozable-m1max.junco-shaula.ts.net")
        let login = #"{"BackendState":"NeedsLogin","AuthURL":"https://login.tailscale.com/a/abc","Self":{"HostName":"localhost","DNSName":""}}"#
        let n = try XCTUnwrap(TailscalePublish.parseStatus(Data(login.utf8)))
        XCTAssertFalse(n.signedIn)
        XCTAssertNil(n.dnsName)
        XCTAssertEqual(n.authURL, "https://login.tailscale.com/a/abc")
        XCTAssertNil(TailscalePublish.parseStatus(Data("failed to connect".utf8)))
        XCTAssertNil(TailscalePublish.parseStatus(Data("{}".utf8)))
    }

    func testServeConfigFor443And80() throws {
        let json = #"{"TCP":{"443":{"HTTPS":true},"80":{"HTTP":true}},"Web":{"dozable-m1max.junco-shaula.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:7443"}}},"dozable-m1max.junco-shaula.ts.net:80":{"Handlers":{"/":{"Proxy":"unix:/x/http.sock"}}}}}"#
        let c = try XCTUnwrap(TailscalePublish.parseServe(Data(json.utf8)))
        XCTAssertEqual(c, .init(https: "http://127.0.0.1:7443", http: "unix:/x/http.sock"))
        XCTAssertEqual(TailscalePublish.parseServe(Data("{}".utf8)), .init(https: nil, http: nil))
        XCTAssertNil(TailscalePublish.parseServe(Data("no".utf8)))
    }

    func testTheLoginLinkIsFoundInWhatUpPrints() {
        XCTAssertEqual(TailscalePublish.link(in: "\thttps://login.tailscale.com/a/1f2e3d"), "https://login.tailscale.com/a/1f2e3d")
        XCTAssertEqual(TailscalePublish.link(in: "To authenticate, visit: https://login.tailscale.com/a/x."), "https://login.tailscale.com/a/x")
        XCTAssertNil(TailscalePublish.link(in: "To authenticate, visit:"))
        XCTAssertNil(TailscalePublish.link(in: "http://plain.example"))
    }

    // MARK: port 80's redirect

    func testTheRedirectGoesToThePublishedAddressWithThePathOnly() {
        let o = "https://dozable-m1max.junco-shaula.ts.net"
        XCTAssertEqual(TailscalePublish.redirectLocation(origin: o, target: "/"), o + "/")
        XCTAssertEqual(TailscalePublish.redirectLocation(origin: o, target: "/devices?x=1#f"), o + "/devices?x=1#f")
        // Never another host: an absolute-form target, a scheme-relative one stays a path of the published host.
        XCTAssertEqual(TailscalePublish.redirectLocation(origin: o, target: "http://evil.example/"), o + "/")
        XCTAssertEqual(TailscalePublish.redirectLocation(origin: o, target: "//evil.example/x"), o + "//evil.example/x")
        XCTAssertEqual(TailscalePublish.redirectLocation(origin: o, target: "/a\r\nSet-Cookie: x"), o + "/")
        XCTAssertEqual(TailscalePublish.redirectLocation(origin: o, target: "/a b"), o + "/")
        XCTAssertEqual(TailscalePublish.redirectLocation(origin: o, target: "/\\evil"), o + "/")
        XCTAssertEqual(TailscalePublish.redirectLocation(origin: o, target: "/" + String(repeating: "a", count: 3000)), o + "/")
    }

    // MARK: the settings

    func testPublishingSetsTheDashboardUpAndUnpublishingPutsItBack() throws {
        let xdg = root.appendingPathComponent("xdg")
        let env = ["XDG_CONFIG_HOME": xdg.path]
        var s = DozableSettings.load(environment: env)
        s = try s.writing(SettingKey.serveChat, .string("read"))
        s = try TailscalePublish.apply(TailscalePublish.publishSettings(port: 7443, origin: "https://dozable-m1max.junco-shaula.ts.net"), to: s)
        XCTAssertEqual(s.int(SettingKey.uiPort), 7443)
        XCTAssertTrue(s.bool(SettingKey.uiLAN))
        XCTAssertEqual(s.string(SettingKey.serveBind), "loopback")
        XCTAssertEqual(s.string(SettingKey.servePublicOrigins), "https://dozable-m1max.junco-shaula.ts.net")
        XCTAssertEqual(s.string(SettingKey.serveTrustedProxies), "127.0.0.1,::1")
        XCTAssertEqual(s.string(SettingKey.serveChat), "read", "serve.chat is never touched")
        XCTAssertFalse(TailscalePublish.publishSettings(port: 1, origin: "https://x").contains { $0.key == SettingKey.serveChat })
        s = try TailscalePublish.apply(TailscalePublish.unpublishSettings(), to: DozableSettings.load(environment: env))
        XCTAssertEqual(s.int(SettingKey.uiPort), 7443, "ui.port is kept")
        XCTAssertFalse(s.bool(SettingKey.uiLAN))
        XCTAssertNil(s.fileValues[SettingKey.servePublicOrigins])
        XCTAssertNil(s.fileValues[SettingKey.serveTrustedProxies])
        XCTAssertNil(s.fileValues[SettingKey.serveBind])
        XCTAssertEqual(s.string(SettingKey.serveBind), "lan")
        XCTAssertEqual(s.string(SettingKey.serveChat), "read")
    }

    func testASettingsFileThatDoesNotParseIsRefusedAndKept() throws {
        let xdg = root.appendingPathComponent("xdg2")
        let file = xdg.appendingPathComponent("doz/doz.toml")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "this is [not toml\n".write(to: file, atomically: true, encoding: .utf8)
        let s = DozableSettings.load(environment: ["XDG_CONFIG_HOME": xdg.path])
        XCTAssertThrowsError(try TailscalePublish.apply(TailscalePublish.publishSettings(port: 7443, origin: "https://x.ts.net"), to: s))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "this is [not toml\n")
    }

    // MARK: Homebrew's tailscale, only through the seam in a test

    func testATestFindsOnlyTheSeamsTailscale() throws {
        let guarded = ["DOZ_TEST_GUARD": "1"]
        XCTAssertEqual(TailscalePublish.prefixCandidates(env: guarded), [])
        XCTAssertNil(TailscalePublish.locate(env: guarded))
        let prefix = root.appendingPathComponent("brew")
        let bin = prefix.appendingPathComponent("opt/tailscale/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let env = ["DOZ_TEST_GUARD": "1", "DOZ_TEST_BREW_PREFIX": prefix.path]
        XCTAssertNil(TailscalePublish.locate(env: env), "nothing there yet")
        for n in ["tailscale", "tailscaled"] {
            FileManager.default.createFile(atPath: bin.appendingPathComponent(n).path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        }
        XCTAssertEqual(TailscalePublish.locate(env: env)?.tailscale, (prefix.path as NSString).standardizingPath + "/opt/tailscale/bin/tailscale")
        // A guarded run never runs a real one.
        XCTAssertNotNil(TailscalePublish.runViolation("/opt/homebrew/opt/tailscale/bin/tailscale", env: env))
        XCTAssertNotNil(TailscalePublish.runViolation("/opt/homebrew/opt/tailscale/bin/tailscale", env: guarded))
        XCTAssertNil(TailscalePublish.runViolation((prefix.path as NSString).standardizingPath + "/opt/tailscale/bin/tailscale", env: env))
        // A person's doz: $HOMEBREW_PREFIX first, then the two standard prefixes — never the Tailscale app's CLI.
        let real = TailscalePublish.prefixCandidates(env: ["DOZ_TEST_REAL_MAC": "1", "HOMEBREW_PREFIX": "/opt/homebrew"])
        XCTAssertEqual(real, ["/opt/homebrew", "/usr/local"])
    }

    // MARK: the LaunchAgent, against a scratch folder and a fake launchctl

    func testTheAgentIsWrittenLoadedReplacedAndRemoved() throws {
        let folder = root.appendingPathComponent("LaunchAgents")
        let store = DozableStore(root: root.appendingPathComponent("store"))
        let b = TailscalePublish.Binaries(prefix: "/opt/homebrew")
        let loaded = Box()
        let lc = Launchctl(fake: { args in
            loaded.calls.append(args)
            switch args.first {
            case "print": return .init(code: loaded.loaded ? 0 : 113, output: loaded.loaded ? "program = x" : "")
            case "bootstrap": loaded.loaded = true; return .init(code: 0, output: "")
            case "bootout": loaded.loaded = false; return .init(code: 0, output: "")
            default: return .init(code: 1, output: "?")
            }
        })
        XCTAssertNil(try TailscalePublish.installAgent(store, b, launchctl: lc, folder: folder))
        let url = TailscalePublish.plistURL(store, folder: folder)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(loaded.calls.map(\.first), ["print", "bootstrap"])
        XCTAssertEqual(loaded.calls.last, ["bootstrap", "gui/501", url.path])
        var st = try XCTUnwrap(TailscalePublish.agentState(store, binaries: b, launchctl: lc, folder: folder))
        XCTAssertTrue(st.installed && st.loaded && st.current)
        XCTAssertFalse(try XCTUnwrap(TailscalePublish.agentState(store, binaries: .init(prefix: "/usr/local"), launchctl: lc, folder: folder)).current)
        // Again: the loaded one is booted out first, then loaded anew.
        loaded.calls = []
        XCTAssertNil(try TailscalePublish.installAgent(store, b, launchctl: lc, folder: folder))
        XCTAssertEqual(loaded.calls.map(\.first), ["print", "bootout", "bootstrap"])
        XCTAssertTrue(TailscalePublish.removeAgent(store, launchctl: lc, folder: folder))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(loaded.loaded)
        st = try XCTUnwrap(TailscalePublish.agentState(store, binaries: b, launchctl: lc, folder: folder))
        XCTAssertFalse(st.installed || st.loaded)
        XCTAssertFalse(TailscalePublish.removeAgent(store, launchctl: lc, folder: folder))
        // launchd refusing is said.
        let refusing = Launchctl(fake: { args in args.first == "bootstrap" ? .init(code: 5, output: "Bootstrap failed: 5: Input/output error\n") : .init(code: 113, output: "") })
        XCTAssertEqual(try TailscalePublish.installAgent(store, b, launchctl: refusing, folder: folder), "Bootstrap failed: 5: Input/output error")
    }

    func testTheMarkerRoundTrips() throws {
        let store = DozableStore(root: root.appendingPathComponent("store2"))
        XCTAssertNil(TailscalePublish.readMarker(store))
        let m = TailscalePublish.Marker(name: "dozable-m1max", origin: "https://dozable-m1max.junco-shaula.ts.net", port: 7443,
                                        published: Date(timeIntervalSince1970: 1_800_000_000))
        try TailscalePublish.writeMarker(store, m)
        XCTAssertEqual(TailscalePublish.readMarker(store), m)
        var st = stat()
        XCTAssertEqual(stat(TailscalePublish.paths(store).root.path, &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o700)
    }

    func testTheDaemonStartsAPublishedDashboardOnlyWhenNothingHoldsItAndNobodyStoppedIt() throws {
        let store = DozableStore(root: root.appendingPathComponent("store3"))
        try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
        XCTAssertEqual(PublishedDashboard.decide(store), .notPublished)
        XCTAssertNil(PublishedDashboard.ensure(store, program: "/nonexistent/doz"), "not published: nothing started")
        try TailscalePublish.writeMarker(store, .init(name: "n", origin: "https://n.t.ts.net", port: 7443, published: Date()))
        XCTAssertEqual(PublishedDashboard.decide(store), .start)
        // A doz ui holds ui.lock: running.
        let fd = open(store.root.appendingPathComponent("ui.lock").path, O_RDWR | O_CREAT, 0o600)
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        XCTAssertEqual(PublishedDashboard.decide(store), .running)
        close(fd)
        XCTAssertEqual(PublishedDashboard.decide(store), .start)
        PublishedDashboard.markStopped(store)
        XCTAssertEqual(PublishedDashboard.decide(store), .stoppedByPerson)
        XCTAssertNil(PublishedDashboard.ensure(store, program: "/nonexistent/doz"), "the person's stop: nothing started")
        PublishedDashboard.clearStopped(store)
        XCTAssertEqual(PublishedDashboard.decide(store), .start)
        XCTAssertEqual(PublishedDashboard.interval([:]), 60)
        XCTAssertEqual(PublishedDashboard.interval(["DOZ_TEST_GUARD": "1", "DOZ_TEST_UI_KEEP_INTERVAL": "2"]), 2)
        XCTAssertEqual(PublishedDashboard.interval(["DOZ_TEST_REAL_MAC": "1", "DOZ_TEST_UI_KEEP_INTERVAL": "2"], ), 60)
    }

    final class Box: @unchecked Sendable {
        var calls: [[String]] = []
        var loaded = false
    }
}
