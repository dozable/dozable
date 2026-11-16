import Darwin
import XCTest
@testable import DozableKit

// 692 — a launch secret (`--secret`) in the vault and the proxy, without a VM: the port binding, the plain-HTTP exception
// and everything it still refuses. Every value here is an obviously fake string; the only listeners are this test's own
// (EchoServer: 127.0.0.1, an ephemeral port, the head it received echoed back).

private let fakeSecret = "FAKE-SERVER-TOKEN-0123456789"

/// The binding a launch secret gets (`LaunchSecret.binding` in DozableHost): swap-only, one host, one port.
private func secretBinding(_ variable: String = "SERVER_TOKEN", host: String = "host.dozable.internal", port: UInt16, plainHTTP: Bool = true,
                           header: CredentialHeader = .bearer) -> CredentialBinding {
    CredentialBinding(id: "secret:" + variable, hosts: [host], header: header, environmentVariable: variable, swapOnly: true, port: port, plainHTTP: plainHTTP)
}

private func head(_ s: String) -> [UInt8] { Array(s.replacingOccurrences(of: "\n", with: "\r\n").utf8) }
private func text(_ b: [UInt8]) -> String { String(decoding: b, as: UTF8.self) }

final class CredentialsTests: XCTestCase {
    /// Swapped only for exactly its host and port: another port of the host, another host, the route's alias, an unknown
    /// port — refused, naming host:port. The secret never appears in a refusal.
    func testSecretBindingPort() throws {
        let v = CredentialVault()
        v.set(secretBinding(port: 8780), secret: fakeSecret)
        let t = try XCTUnwrap(v.mint("secret:SERVER_TOKEN"))
        let req = head("GET /rooms HTTP/1.1\nHost: host.dozable.internal:8780\nAuthorization: Bearer \(t)\n\n")
        guard case .swapped(let out, binding: "secret:SERVER_TOKEN") = v.rewrite(head: req, host: "host.dozable.internal", port: 8780) else { return XCTFail("not swapped") }
        XCTAssertTrue(text(out).contains("Authorization: Bearer \(fakeSecret)\r\n"))
        XCTAssertFalse(text(out).contains(t))
        for (host, port, at) in [("host.dozable.internal", UInt16(8781), "host.dozable.internal:8781"),
                                 ("mac.dozable.internal", 8780, "mac.dozable.internal:8780"),
                                 ("other.example.com", 8780, "other.example.com:8780")] {
            guard case .reject(let why) = v.rewrite(head: req, host: host, port: port) else { return XCTFail("\(at) not refused") }
            XCTAssertEqual(why, "a credential placeholder for host.dozable.internal:8780, sent to \(at)")
            XCTAssertFalse(why.contains(fakeSecret))
        }
        // The port unknown (a caller that never says it): never this binding's.
        guard case .reject(let why) = v.rewrite(head: req, host: "host.dozable.internal") else { return XCTFail("no port: not refused") }
        XCTAssertEqual(why, "a credential placeholder for host.dozable.internal:8780, sent to host.dozable.internal")
        // covers(host:port:) — and a binding with no port covers every port, as before.
        XCTAssertTrue(secretBinding(port: 8780).covers(host: "HOST.dozable.internal", port: 8780))
        XCTAssertFalse(secretBinding(port: 8780).covers(host: "host.dozable.internal", port: nil))
        XCTAssertTrue(CredentialBinding.anthropic.covers(host: "api.anthropic.com", port: nil))
        XCTAssertTrue(CredentialBinding.anthropic.covers(host: "api.anthropic.com", port: 8443))
    }

    /// A named header gets the raw value; Authorization gets Bearer.
    func testSecretInANamedHeader() throws {
        let v = CredentialVault()
        v.set(secretBinding("API_TOKEN", host: "svc.example.com", port: 8443, header: .apiKey(name: "x-service-token")), secret: fakeSecret)
        let t = try XCTUnwrap(v.mint("secret:API_TOKEN"))
        let req = head("GET / HTTP/1.1\nHost: svc.example.com\nX-Service-Token: \(t)\n\n")
        guard case .swapped(let out, _) = v.rewrite(head: req, host: "svc.example.com", port: 8443) else { return XCTFail() }
        XCTAssertTrue(text(out).contains("X-Service-Token: \(fakeSecret)\r\n"), text(out))
    }

    /// Every binding before launch secrets behaves exactly as before: no port, any port; the old refusal text.
    func testOldBindingsUnchanged() throws {
        let v = CredentialVault()
        v.set(.anthropic, secret: "sk-ant-api03-FAKE")
        let t = try XCTUnwrap(v.mint("anthropic"))
        let req = head("POST /v1/messages HTTP/1.1\nHost: api.anthropic.com\nx-api-key: \(t)\n\n")
        for port: UInt16? in [nil, 443, 8443] {
            guard case .swapped = v.rewrite(head: req, host: "api.anthropic.com", port: port) else { return XCTFail("\(String(describing: port))") }
        }
        guard case .reject(let why) = v.rewrite(head: req, host: "evil.example.com", port: 443) else { return XCTFail() }
        XCTAssertEqual(why, "a credential placeholder for api.anthropic.com, sent to evil.example.com")
        // A request with no credential still gets the account injected (the old path), with or without a port.
        let bare = head("POST /v1/messages HTTP/1.1\nHost: api.anthropic.com\n\n")
        guard case .injected = v.rewrite(head: bare, host: "api.anthropic.com", port: 443) else { return XCTFail() }
        XCTAssertNil(CredentialBinding.anthropic.port)
        XCTAssertFalse(CredentialBinding.anthropic.isLaunchSecret)
        XCTAssertNil(CredentialBinding.anthropic.plainHTTP)
        // A record written before 692 decodes with no port and no plain-HTTP flag.
        let old = #"{"id":"custom:x","hosts":["api.example.com"],"header":{"bearer":{}},"swapOnly":true}"#
        let b = try JSONDecoder().decode(CredentialBinding.self, from: Data(old.utf8))
        XCTAssertNil(b.port)
        XCTAssertTrue(b.covers(host: "api.example.com", port: 1234))
    }

    /// Never injected without its placeholder (swap-only); a request carrying its own Authorization passes untouched and
    /// fingerprinted — never our secret beside it.
    func testSecretIsSwapOnly() throws {
        let v = CredentialVault()
        v.set(secretBinding(port: 8780), secret: fakeSecret)
        let bare = head("GET / HTTP/1.1\nHost: host.dozable.internal:8780\n\n")
        guard case .passThrough(let out) = v.rewrite(head: bare, host: "host.dozable.internal", port: 8780) else { return XCTFail("injected") }
        XCTAssertEqual(out, bare)
        let own = head("GET / HTTP/1.1\nHost: host.dozable.internal:8780\nAuthorization: Bearer the-programs-own-token\n\n")
        guard case .foreign(let out2, let f) = v.rewrite(head: own, host: "host.dozable.internal", port: 8780) else { return XCTFail("not flagged") }
        XCTAssertEqual(out2, own, "untouched")
        XCTAssertFalse(text(out2).contains(fakeSecret))
        XCTAssertEqual(f.fingerprint, CredentialFingerprint.of("the-programs-own-token"))
        // isBound: only its port (raw TCP elsewhere on the host is as before).
        XCTAssertTrue(v.isBound(host: "host.dozable.internal", port: 8780))
        XCTAssertFalse(v.isBound(host: "host.dozable.internal", port: 8781))
    }

    /// A secret given again replaces the value — the placeholders already issued stay valid for the new one; removed, the
    /// placeholder answers "unknown or revoked".
    func testReplacedThenRevoked() throws {
        let v = CredentialVault()
        v.set(secretBinding(port: 8780), secret: fakeSecret)
        let t = try XCTUnwrap(v.mint("secret:SERVER_TOKEN"))
        v.set(secretBinding(port: 8780), secret: "FAKE-SECOND-VALUE")
        let req = head("GET / HTTP/1.1\nHost: x\nAuthorization: Bearer \(t)\n\n")
        guard case .swapped(let out, _) = v.rewrite(head: req, host: "host.dozable.internal", port: 8780) else { return XCTFail() }
        XCTAssertTrue(text(out).contains("FAKE-SECOND-VALUE"))
        v.remove("secret:SERVER_TOKEN")
        guard case .reject(let why) = v.rewrite(head: req, host: "host.dozable.internal", port: 8780) else { return XCTFail() }
        XCTAssertEqual(why, "an unknown or revoked credential placeholder")
    }
}

final class PlainHTTPSecretRuleTests: XCTestCase {
    func testTheTailscaleRangeAndThisMacOnIt() {
        XCTAssertTrue(TailscaleRange.contains([100, 64, 0, 1]))
        XCTAssertTrue(TailscaleRange.contains([100, 127, 255, 254]))
        XCTAssertFalse(TailscaleRange.contains([100, 63, 255, 255]))
        XCTAssertFalse(TailscaleRange.contains([100, 128, 0, 0]))
        XCTAssertFalse(TailscaleRange.contains([10, 64, 0, 1]))
        XCTAssertFalse(TailscaleRange.contains([UInt8](repeating: 0, count: 16)), "never an IPv6 address")
        XCTAssertTrue(TailscaleRange.contains(literal: "100.100.1.2"))
        XCTAssertFalse(TailscaleRange.contains(literal: "tail.example.ts.net"))
        // This Mac on Tailscale — an injected interface list.
        XCTAssertTrue(TailscaleRange.macIsOn([[192, 168, 1, 4], [100, 101, 2, 3]]))
        XCTAssertFalse(TailscaleRange.macIsOn([[192, 168, 1, 4], [127, 0, 0, 1]]))
        XCTAssertFalse(TailscaleRange.macIsOn([]))
    }

    func testTheDecision() {
        let s = secretBinding(port: 8780)
        let ts = secretBinding("TS", host: "100.64.0.9", port: 8080)
        let msg = PlainHTTPSecretRule.message(host: "x", port: 1)
        XCTAssertTrue(msg.contains("never sent over plain HTTP") && msg.contains("network.placeholders_plain_http") && msg.contains("use https"))
        // (a) another binding's placeholder, even beside a secret's: the old refusal.
        XCTAssertEqual(PlainHTTPSecretRule.judge(bindings: [.anthropic], host: "host.dozable.internal", port: 8780, macOnTailscale: true), .notSecrets)
        XCTAssertEqual(PlainHTTPSecretRule.judge(bindings: [s, .github], host: "host.dozable.internal", port: 8780, macOnTailscale: true), .notSecrets)
        // Unknown: the vault's leak guard answers.
        XCTAssertEqual(PlainHTTPSecretRule.judge(bindings: [s, nil], host: "host.dozable.internal", port: 8780, macOnTailscale: true), .unknown)
        // (c) bound while the setting was off.
        XCTAssertEqual(PlainHTTPSecretRule.judge(bindings: [secretBinding(port: 8780, plainHTTP: false)], host: "host.dozable.internal", port: 8780, macOnTailscale: true),
                       .refuse(PlainHTTPSecretRule.message(host: "host.dozable.internal", port: 8780)))
        // (d) the route; a Tailscale literal; a name (judged at the dial); anything else refused.
        XCTAssertEqual(PlainHTTPSecretRule.judge(bindings: [s], host: "host.dozable.internal", port: 8780, macOnTailscale: false), .swap(tailscale: false))
        XCTAssertEqual(PlainHTTPSecretRule.judge(bindings: [ts], host: "100.64.0.9", port: 8080, macOnTailscale: true), .swap(tailscale: true))
        XCTAssertEqual(PlainHTTPSecretRule.judge(bindings: [ts], host: "box.tail1234.ts.net", port: 8080, macOnTailscale: true), .swap(tailscale: true))
        XCTAssertEqual(PlainHTTPSecretRule.judge(bindings: [ts], host: "10.0.0.5", port: 8080, macOnTailscale: true),
                       .refuse(PlainHTTPSecretRule.message(host: "10.0.0.5", port: 8080)))
        // The extra condition: this Mac must be on Tailscale now.
        XCTAssertEqual(PlainHTTPSecretRule.judge(bindings: [ts], host: "100.64.0.9", port: 8080, macOnTailscale: false),
                       .refuse(PlainHTTPSecretRule.message(host: "100.64.0.9", port: 8080) + " (this Mac is not on a Tailscale network now)"))
        XCTAssertEqual(PlainHTTPSecretRule.judge(bindings: [ts], host: "box.tail1234.ts.net", port: 8080, macOnTailscale: false),
                       .refuse(PlainHTTPSecretRule.message(host: "box.tail1234.ts.net", port: 8080) + " (this Mac is not on a Tailscale network now)"))
        // Through a test seam only a literal qualifies; an IPv6 literal never.
        XCTAssertEqual(PlainHTTPSecretRule.judge(bindings: [ts], host: "plain.example", port: 8080, macOnTailscale: true, throughSeam: true),
                       .refuse(PlainHTTPSecretRule.message(host: "plain.example", port: 8080)))
        if case .swap = PlainHTTPSecretRule.judge(bindings: [ts], host: "[fd7a:115c::1]", port: 8080, macOnTailscale: true) { XCTFail("IPv6") }
    }

    /// The dial's rule on the very addresses it resolves: a name resolving outside 100.64/10, or a mixed answer, refused.
    func testEveryResolvedAddressMustBeTailscale() {
        let why = "outside"
        let req: ([UInt8]) -> Bool = { TailscaleRange.contains($0) }
        XCTAssertNil(Wire.requireRefusal([[100, 64, 0, 9]], require: req, why: why))
        XCTAssertNil(Wire.requireRefusal([[100, 64, 0, 9], [100, 100, 1, 1]], require: req, why: why))
        XCTAssertEqual(Wire.requireRefusal([[93, 184, 216, 34]], require: req, why: why), why, "outside")
        XCTAssertEqual(Wire.requireRefusal([[100, 64, 0, 9], [93, 184, 216, 34]], require: req, why: why), why, "a mixed answer")
        XCTAssertEqual(Wire.requireRefusal([[100, 64, 0, 9], nil], require: req, why: why), why, "an unreadable address")
        XCTAssertEqual(Wire.requireRefusal([], require: req, why: why), why, "no answer")
        // Through the resolver itself (a literal resolves to itself): refused before any dial.
        let r = Wire.connectTCPGuarded("192.0.2.1", 9, timeoutMS: 200, guard: .strict, require: req, requireWhy: why)
        XCTAssertEqual(r.fd, -1)
        XCTAssertEqual(r.refused, why)
        let loop = Wire.connectTCPGuarded("localhost", 9, timeoutMS: 200, guard: .strict, require: req, requireWhy: why)
        XCTAssertEqual(loop.refused, why, "localhost resolves outside the range")
    }
}

final class EgressProxyPlainHTTPTests: XCTestCase {
    static func ask(_ proxy: EgressProxy, _ request: String) -> String { HostRouteTests.ask(proxy, request) }

    func waitForRecord(_ log: ConnectionLog, _ match: (ConnectionRecord) -> Bool) -> ConnectionRecord? {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let r = log.records.last(where: match), !r.open { return r }
            usleep(20_000)
        }
        return nil
    }

    /// The host route + the setting on → swapped: the service receives the real value; the log says which binding, never
    /// the value. Another port of this Mac → 403 naming host:port; the alias → 403.
    func testTheRouteSwapsOverPlainHTTP() throws {
        let server = try EchoServer()
        defer { server.stop() }
        let other = try EchoServer()
        defer { other.stop() }
        let proxy = try EgressProxy(policy: .open, ca: nil)
        proxy.hostPorts = [HostPort(port: server.port), HostPort(port: other.port)]
        proxy.vault.set(secretBinding(port: server.port), secret: fakeSecret)
        let t = try XCTUnwrap(proxy.vault.mint("secret:SERVER_TOKEN"))
        let ok = Self.ask(proxy, "GET http://host.dozable.internal:\(server.port)/rooms HTTP/1.1\r\nHost: host.dozable.internal\r\nAuthorization: Bearer \(t)\r\n\r\n")
        XCTAssertTrue(ok.hasPrefix("HTTP/1.1 200"), ok)
        XCTAssertTrue(server.heads.last?.contains("Authorization: Bearer \(fakeSecret)\r\n") == true, server.heads.last ?? "")
        XCTAssertFalse(server.heads.last?.contains(t) == true)
        let rec = try XCTUnwrap(waitForRecord(proxy.log) { $0.port == server.port })
        XCTAssertEqual(rec.credential, "swapped secret:SERVER_TOKEN")
        XCTAssertFalse(proxy.log.records.contains { ($0.credential ?? "").contains(fakeSecret) || ($0.detail ?? "").contains(fakeSecret) })
        // Another port: refused by the leak guard; the other service never sees anything.
        let wrong = Self.ask(proxy, "GET http://host.dozable.internal:\(other.port)/ HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer \(t)\r\n\r\n")
        XCTAssertTrue(wrong.hasPrefix("HTTP/1.1 403") && wrong.contains("sent to host.dozable.internal:\(other.port)"), wrong)
        XCTAssertEqual(other.count, 0)
        let alias = Self.ask(proxy, "GET http://mac.dozable.internal:\(server.port)/ HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer \(t)\r\n\r\n")
        XCTAssertTrue(alias.hasPrefix("HTTP/1.1 403"), alias)
        XCTAssertEqual(server.count, 1)
        // Raw TCP to the bound destination (the proxy ignored): refused — the swap needs the HTTP proxy.
        let raw = MacModelServerTests.open(proxy, "DOZ1 T 198.18.255.254 \(server.port)\nGET / HTTP/1.1\r\nAuthorization: Bearer \(t)\r\n\r\n")
        _ = MacModelServerTests.readAll(raw)
        close(raw)
        XCTAssertEqual(server.count, 1, "raw TCP to the bound port never reaches it")
        // …while raw TCP to another open port of this Mac is as before.
        let rawOther = MacModelServerTests.open(proxy, "DOZ1 T 198.18.255.254 \(other.port)\nGET /raw HTTP/1.1\r\nHost: x\r\n\r\n")
        XCTAssertTrue(MacModelServerTests.readAll(rawOther).contains("GET /raw"))
        close(rawOther)
    }

    /// Bound while network.placeholders_plain_http was off → 403 with the message; nothing reaches the service.
    func testSettingOffRefuses() throws {
        let server = try EchoServer()
        defer { server.stop() }
        let proxy = try EgressProxy(policy: .open, ca: nil)
        proxy.hostPorts = [HostPort(port: server.port)]
        proxy.vault.set(secretBinding(port: server.port, plainHTTP: false), secret: fakeSecret)
        let t = try XCTUnwrap(proxy.vault.mint("secret:SERVER_TOKEN"))
        let reply = Self.ask(proxy, "GET http://host.dozable.internal:\(server.port)/ HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer \(t)\r\n\r\n")
        XCTAssertTrue(reply.hasPrefix("HTTP/1.1 403") && reply.contains("never sent over plain HTTP"), reply)
        XCTAssertFalse(reply.contains(fakeSecret))
        XCTAssertEqual(server.count, 0)
    }

    /// A Tailscale literal through the fence's seam → swapped (this Mac on Tailscale, by the seam); not on Tailscale →
    /// refused; a plain-HTTP site that is not Tailscale → refused.
    func testTailscaleLiteralThroughTheSeam() throws {
        let server = try EchoServer()
        defer { server.stop() }
        let proxy = try EgressProxy(policy: .open, ca: nil)
        proxy.fenceUpstreamsForTests = ["100.64.0.9": .init(host: "127.0.0.1", port: server.port),
                                        "plain.example": .init(host: "127.0.0.1", port: server.port)]
        proxy.vault.set(secretBinding("TS", host: "100.64.0.9", port: 8080), secret: fakeSecret)
        proxy.vault.set(secretBinding("PLAIN", host: "plain.example", port: 8080), secret: "FAKE-PLAIN-VALUE")
        let t = try XCTUnwrap(proxy.vault.mint("secret:TS"))
        let p = try XCTUnwrap(proxy.vault.mint("secret:PLAIN"))
        proxy.tailscaleUpForTests = false
        var reply = Self.ask(proxy, "GET http://100.64.0.9:8080/ HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer \(t)\r\n\r\n")
        XCTAssertTrue(reply.hasPrefix("HTTP/1.1 403") && reply.contains("not on a Tailscale network"), reply)
        XCTAssertEqual(server.count, 0)
        proxy.tailscaleUpForTests = true
        reply = Self.ask(proxy, "GET http://100.64.0.9:8080/ HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer \(t)\r\n\r\n")
        XCTAssertTrue(reply.hasPrefix("HTTP/1.1 200"), reply)
        XCTAssertTrue(server.heads.last?.contains("Authorization: Bearer \(fakeSecret)") == true)
        reply = Self.ask(proxy, "GET http://plain.example:8080/ HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer \(p)\r\n\r\n")
        XCTAssertTrue(reply.hasPrefix("HTTP/1.1 403") && reply.contains("never sent over plain HTTP to plain.example:8080"), reply)
        XCTAssertEqual(server.count, 1)
        // The TS placeholder sent to the other (seam) site: refused before any swap.
        reply = Self.ask(proxy, "GET http://plain.example:8080/ HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer \(t)\r\n\r\n")
        XCTAssertTrue(reply.hasPrefix("HTTP/1.1 403"), reply)
        XCTAssertEqual(server.count, 1)
    }

    /// A real (non-seam) name outside 100.64/10: the swap is refused at the dial — nothing is sent.
    func testANameResolvingOutsideTheRangeIsRefusedAtTheDial() throws {
        let proxy = try EgressProxy(policy: .open, ca: nil)
        proxy.tailscaleUpForTests = true
        // `broadcasthost` (macOS's /etc/hosts: 255.255.255.255 — not the loopback, not Tailscale; when absent the name
        // does not resolve, which is refused the same way): the swap is judged a candidate, the dial refuses it.
        proxy.vault.set(secretBinding("TS", host: "broadcasthost", port: 9), secret: fakeSecret)
        let t = try XCTUnwrap(proxy.vault.mint("secret:TS"))
        let reply = Self.ask(proxy, "GET http://broadcasthost:9/ HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer \(t)\r\n\r\n")
        XCTAssertTrue(reply.hasPrefix("HTTP/1.1 403") && reply.contains("never sent over plain HTTP")
                      && reply.contains("resolves to an address outside 100.64.0.0/10"), reply)
        XCTAssertFalse(reply.contains(fakeSecret))
        let rec = try XCTUnwrap(waitForRecord(proxy.log) { $0.host == "broadcasthost" })
        XCTAssertTrue(rec.credential?.hasPrefix("rejected:") == true, rec.credential ?? "")
        // A literal outside the range is refused before anything is swapped.
        proxy.vault.set(secretBinding("TS2", host: "192.0.2.1", port: 9), secret: fakeSecret)
        let t2 = try XCTUnwrap(proxy.vault.mint("secret:TS2"))
        let lit = Self.ask(proxy, "GET http://192.0.2.1:9/ HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer \(t2)\r\n\r\n")
        XCTAssertTrue(lit.hasPrefix("HTTP/1.1 403") && lit.contains("never sent over plain HTTP"), lit)
    }

    /// Other placeholders (Anthropic, GitHub) over plain HTTP are still refused — even beside a secret's, even to the route.
    func testOtherPlaceholdersStillRefused() throws {
        let server = try EchoServer()
        defer { server.stop() }
        let proxy = try EgressProxy(policy: .open, ca: nil)
        proxy.hostPorts = [HostPort(port: server.port)]
        proxy.vault.set(secretBinding(port: server.port), secret: fakeSecret)
        proxy.vault.set(.anthropic, secret: "sk-ant-api03-FAKE-REAL")
        proxy.vault.set(.github, secret: "ghp_FAKEFAKEFAKE")
        let s = try XCTUnwrap(proxy.vault.mint("secret:SERVER_TOKEN"))
        let a = try XCTUnwrap(proxy.vault.mint("anthropic"))
        let g = try XCTUnwrap(proxy.vault.mint("github"))
        for (label, extra) in [("anthropic alone", "x-api-key: \(a)\r\n"), ("github alone", "Authorization: token \(g)\r\n"),
                               ("anthropic beside a secret", "Authorization: Bearer \(s)\r\nx-api-key: \(a)\r\n")] {
            let reply = Self.ask(proxy, "GET http://host.dozable.internal:\(server.port)/ HTTP/1.1\r\nHost: x\r\n\(extra)\r\n")
            XCTAssertTrue(reply.hasPrefix("HTTP/1.1 403") && reply.contains("(plain HTTP)"), "\(label): \(reply)")
            XCTAssertFalse(reply.contains("FAKE-REAL") || reply.contains(fakeSecret), label)
        }
        XCTAssertEqual(server.count, 0)
    }
}
