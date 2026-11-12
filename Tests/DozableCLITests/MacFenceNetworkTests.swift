import Darwin
import Foundation
@testable import DozableKit
import XCTest
@testable import DozableHost

/// 683: a fenced session's network — its permissions (this Mac's Standard), its proxy variables, the profile's network
/// rules (only its proxy port and its own --local-ports; Locked closes certificate trust), the loopback socket, and that
/// sandbox-exec enforces those rules.
final class MacFenceNetworkTests: XCTestCase {
    var w: FenceScratch!
    override func setUpWithError() throws { w = try FenceScratch() }
    override func tearDown() { w.remove() }

    func testPermissions() throws {
        let std = try MacFenceNetwork.policy(words: ["standard"])
        XCTAssertEqual(std.permissions, AgentPermissions.normalized(["model", "update", "github", "error-reports", "install:node", "install:python",
                                                                     "install:go", "install:rust", "install:swift"]))
        XCTAssertFalse(std.permissions!.contains("install:system"), "this Mac has no apt/apk")
        XCTAssertEqual(AgentPermissions.presetName(std.permissions!, base: AgentPermissions.macBase), "agent")
        XCTAssertEqual(try MacFenceNetwork.policy(words: ["locked"]).permissions, ["model"])
        XCTAssertTrue(try MacFenceNetwork.policy(words: ["open"]).permissions!.contains("web"))
        let custom = try MacFenceNetwork.policy(words: ["standard,-install:rust", "web", "site:api.example.com"])
        XCTAssertFalse(custom.permissions!.contains("install:rust"))
        XCTAssertTrue(custom.permissions!.contains("web"))
        let site = try MacFenceNetwork.policy(words: ["locked", "site:api.example.com"])
        XCTAssertTrue(site.rules.contains { $0.host == "api.example.com" && $0.action == .allow })
        XCTAssertEqual(site.evaluateConnection(host: "api.example.com", port: 443).kind, .allow)
        XCTAssertThrowsError(try MacFenceNetwork.policy(words: ["no-such-permission"]))
        XCTAssertThrowsError(try MacFenceNetwork.policy(words: ["site:"]))
        XCTAssertFalse(MacFenceNetwork.trust(try MacFenceNetwork.policy(words: ["locked"])), "Locked: no certificate trust on its behalf")
        XCTAssertTrue(MacFenceNetwork.trust(std))
        // Swift's hosts are allowed under this Mac's Standard; a stored Open sandbox without install:swift is still Open.
        XCTAssertEqual(std.evaluateConnection(host: "download.swift.org", port: 443).kind, .allow)
        let oldOpen = AgentPermissions.preset("open", base: nil)!.filter { $0 != "install:swift" }
        XCTAssertEqual(AgentPermissions.presetName(oldOpen, base: nil), "open")
    }

    func testTheProxyVariables() {
        let e = MacFenceEnvironment.proxy(port: 41234, password: "PW", etc: "/s/etc")
        for k in ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy"] {
            XCTAssertEqual(e[k], "http://doz:PW@127.0.0.1:41234", k)
        }
        XCTAssertEqual(e["NO_PROXY"], "localhost,127.0.0.1,::1")
        XCTAssertEqual(e["NODE_USE_ENV_PROXY"], "1")
        XCTAssertEqual(e["GIT_CONFIG_KEY_0"], "http.proxyAuthMethod")
        XCTAssertEqual(e["NODE_EXTRA_CA_CERTS"], "/s/etc/ca.pem")
        XCTAssertEqual(e["SSL_CERT_FILE"], "/s/etc/ca-bundle.pem")
        XCTAssertNil(MacFenceEnvironment.proxy(port: 1, password: "x", etc: nil)["NODE_EXTRA_CA_CERTS"], "no CA: no CA variables")
    }

    func testTheProfilesNetworkRules() throws {
        var f = try w.fence()
        XCTAssertFalse(MacFenceProfile.render(f).contains("network-"), "no proxy: no network at all")
        f.proxyPort = 41234
        f.localPorts = [3000, 8765]
        let p = MacFenceProfile.render(f)
        let net = p.split(separator: "\n").filter { $0.contains("network-") }.map(String.init)
        XCTAssertEqual(net, [
            "(allow network-outbound (remote tcp \"localhost:41234\"))",
            "(allow network-bind network-inbound (local tcp \"localhost:3000\"))",
            "(allow network-outbound (remote tcp \"localhost:3000\"))",
            "(allow network-bind network-inbound (local tcp \"localhost:8765\"))",
            "(allow network-outbound (remote tcp \"localhost:8765\"))",
        ], "the proxy's port and its own ports — nothing else (no DNS, no other bind)")
        XCTAssertTrue(p.contains("com.apple.trustd"))
        f.trust = false
        let locked = MacFenceProfile.render(f)
        XCTAssertFalse(locked.contains("com.apple.trustd") || locked.contains("com.apple.ocspd"), "Locked: trustd closed")
        XCTAssertTrue(f.line().contains("network through Dozable's proxy"))
    }

    func testLocalPortsAreChecked() {
        XCTAssertEqual(try MacFence.localPorts([3000, 3000, 8080]), [3000, 8080])
        XCTAssertThrowsError(try MacFence.localPorts([80]), "below 1024")
        XCTAssertThrowsError(try MacFence.localPorts([70000]))
        XCTAssertThrowsError(try MacFence.localPorts(Array(4000...4008)), "at most 8")
    }

    func testTheLoopbackSocket() throws {
        let (fd, port) = try MacFenceNetwork.bindLoopback()
        defer { close(fd) }
        XCTAssertGreaterThan(port, 0)
        XCTAssertEqual(MacFenceNetwork.port(of: fd), port)
        // Nobody else can take the port while it is held (± SO_REUSEADDR / SO_REUSEPORT).
        for opt in [Int32(0), SO_REUSEADDR, SO_REUSEPORT] {
            let s = socket(AF_INET, SOCK_STREAM, 0)
            var one: Int32 = 1
            if opt != 0 { setsockopt(s, SOL_SOCKET, opt, &one, 4) }
            var a = sockaddr_in()
            a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            a.sin_family = sa_family_t(AF_INET)
            a.sin_port = port.bigEndian
            a.sin_addr.s_addr = inet_addr("127.0.0.1")
            let r = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            XCTAssertNotEqual(r, 0, "bind on the held port refused (option \(opt))")
            close(s)
        }
    }

    /// sandbox-exec enforces the network rules: its proxy port only; DNS closed; its own port to listen on.
    func testTheProfileHoldsItsNetwork() throws {
        let (proxyFD, proxyPort) = try MacFenceNetwork.bindLoopback()
        defer { close(proxyFD) }
        let (otherFD, otherPort) = try MacFenceNetwork.bindLoopback()
        defer { close(otherFD) }
        var f = try w.fence()
        _ = try MacFenceSessionFolder.prepare(f, previous: nil, person: .init())
        f.proxyPort = proxyPort
        f.localPorts = [UInt16(47_000 + getpid() % 500)]
        let rendered = MacFenceProfile.render(f)
        // The xcrun shim in front of python3 keeps its cache where the fence lets it (as the session's environment does).
        let env = ["xcrun_db": f.cache + "/xcrun_db", "TMPDIR": f.tmp + "/", "PYTHONPYCACHEPREFIX": f.cache + "/python"]
        let scratch = self.w!
        func sandboxed(_ p: String, _ argv: [String]) -> (code: Int32, err: String) { scratch.sandboxed(p, argv, env: env) }
        let p = rendered
        XCTAssertEqual(sandboxed(p, ["/usr/bin/nc", "-z", "-w", "2", "127.0.0.1", String(proxyPort)]).code, 0, "its proxy's port")
        XCTAssertNotEqual(sandboxed(p, ["/usr/bin/nc", "-z", "-w", "2", "127.0.0.1", String(otherPort)]).code, 0, "another port of this Mac")
        XCTAssertNotEqual(sandboxed(p, ["/usr/bin/python3", "-c", "import socket; socket.getaddrinfo('example.com', 443)"]).code, 0, "DNS closed")
        XCTAssertEqual(sandboxed(p, ["/usr/bin/python3", "-c", "import socket; socket.getaddrinfo('localhost', 443)"]).code, 0, "localhost resolves")
        let port = f.localPorts[0]
        XCTAssertEqual(sandboxed(p, ["/usr/bin/python3", "-c", "import socket; s=socket.socket(); s.bind(('127.0.0.1', \(port))); s.listen(1)"]).code, 0,
                       "its own --local-port")
        XCTAssertNotEqual(sandboxed(p, ["/usr/bin/python3", "-c", "import socket; s=socket.socket(); s.bind(('127.0.0.1', \(port + 1))); s.listen(1)"]).code, 0,
                          "any other port")
        XCTAssertNotEqual(sandboxed(p, ["/usr/bin/python3", "-c", "import socket; socket.socket(socket.AF_INET, socket.SOCK_DGRAM).sendto(b'x', ('127.0.0.1', 9))"]).code, 0,
                          "UDP")
    }

    func testTheSeamIsGuarded() {
        XCTAssertTrue(MacFenceNetwork.upstreamsForTests(["DOZ_TEST_REAL_MAC": "1", "DOZ_TEST_FENCE_UPSTREAMS": "a.doz.test=127.0.0.1:9"]).isEmpty,
                      "not in an unguarded run")
        let m = MacFenceNetwork.upstreamsForTests(["DOZ_TEST_GUARD": "1", "DOZ_TEST_FENCE_UPSTREAMS": "A.doz.test=127.0.0.1:9,b=10.0.0.1:9,c"])
        XCTAssertEqual(m, ["a.doz.test": EgressProxy.UpstreamAddress(host: "127.0.0.1", port: 9)], "only 127.0.0.1, only well-formed")
    }
}

/// 683: the fence's refusals in the system log — only the kernel's lines, and a line is a session's ONLY when the text
/// after its LAST newline is that session's tag.
final class MacFenceDenialsTests: XCTestCase {
    func line(_ msg: String, pid: Int = 0, image: String = "/kernel") -> Data {
        let o: [String: Any] = ["processID": pid, "processImagePath": image, "eventMessage": msg, "timestamp": "2026-11-13 09:49:09.318022+1100"]
        return try! JSONSerialization.data(withJSONObject: o)
    }

    func testParse() {
        let tag = "0123456789abcdef"
        let got = MacFenceDenials.parse(line("Sandbox: cat(14656) deny(1) file-read-data /Users/x/.ssh/id\ndoz-fence:\(tag)"))
        XCTAssertEqual(got?.0, tag)
        XCTAssertEqual(got?.1.process, "cat")
        XCTAssertEqual(got?.1.pid, 14656)
        XCTAssertEqual(got?.1.operation, "file-read-data")
        XCTAssertEqual(got?.1.target, "/Users/x/.ssh/id")
        XCTAssertNil(MacFenceDenials.parse(line("Sandbox: cat(1) deny(1) file-read-data /x\ndoz-fence:\(tag)", pid: 123, image: "/usr/bin/logger")),
                     "a user process's line is never taken")
        XCTAssertNil(MacFenceDenials.parse(line("Sandbox: cat(1) deny(1) file-read-data /x")), "no tag")
        XCTAssertNil(MacFenceDenials.parse(line("Sandbox: cat(1) deny(1) file-read-data /x\ndoz-fence:short")), "not a tag")
        // A path that holds another session's tag: the line still belongs to the session whose tag is LAST.
        let spoof = MacFenceDenials.parse(line("Sandbox: cat(1) deny(1) file-read-data /x\ndoz-fence:ffffffffffffffff\ndoz-fence:\(tag)"))
        XCTAssertEqual(spoof?.0, tag)
        XCTAssertTrue(spoof?.1.target.contains("ffffffffffffffff") == true)
    }

    func testRingsPerSession() {
        let d = MacFenceDenials(environment: ["DOZ_TEST_GUARD": "1", "DOZ_TEST_FENCE_LOG": "unavailable"])
        d.watch(session: "a", tag: "aaaaaaaaaaaaaaaa")
        d.watch(session: "b", tag: "bbbbbbbbbbbbbbbb")
        XCTAssertEqual(d.status, "unavailable", "the seam: as an account that may not read the log")
        for i in 0..<300 { d.take(line("Sandbox: cat(\(i)) deny(1) file-read-data /p\(i)\ndoz-fence:aaaaaaaaaaaaaaaa")) }
        d.take(line("Sandbox: cat(9) deny(1) file-read-data /x\ndoz-fence:bbbbbbbbbbbbbbbb\ndoz-fence:aaaaaaaaaaaaaaaa"))
        XCTAssertEqual(d.denials("a").count, MacFenceDenials.ringSize)
        XCTAssertEqual(d.denials("b").count, 0, "a's path naming b's tag never reaches b")
        d.take(line("Sandbox: cat(9) deny(1) file-read-data /y\ndoz-fence:cccccccccccccccc"))
        XCTAssertEqual(d.denials("a").count + d.denials("b").count, MacFenceDenials.ringSize, "an unknown tag goes nowhere")
    }
}
