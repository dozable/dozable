import Darwin
import XCTest
@testable import DozableKit

/// 660: a model server on this Mac — the ONE port of it a sandbox was made with, reached as `mac.dozable.internal:PORT`,
/// and nothing else of this Mac's loopback, whatever the policy. The proxy end to end WITHOUT a VM (a socketpair stands in
/// for the guest's vsock stream); the only listeners are this test's own, on 127.0.0.1.
final class MacModelServerTests: XCTestCase {
    func testTheNameThePortsAndTheKnownServers() {
        XCTAssertEqual(MacModelServer.baseURL(port: 11434), "http://mac.dozable.internal:11434")
        XCTAssertTrue(MacModelServer.isHost("mac.dozable.internal") && MacModelServer.isHost("MAC.dozable.internal."))
        XCTAssertFalse(MacModelServer.isHost("mac.dozable.internal.evil.example"))
        XCTAssertNil(MacModelServer.portProblem(11434))
        XCTAssertNotNil(MacModelServer.portProblem(nil))
        XCTAssertNotNil(MacModelServer.portProblem(80), "never a privileged port")
        XCTAssertNotNil(MacModelServer.portProblem(70_000))
        XCTAssertEqual(MacModelServer.servers.first { $0.id == "ollama" }?.port, 11434)
        XCTAssertEqual(MacModelServer.servers.filter { !$0.native }.map(\.id), ["mlx-lm"], "an OpenAI-only server is not yet")
        XCTAssertTrue(MacModelServer.servers.allSatisfy { $0.source.hasPrefix("https://") })
        XCTAssertTrue(MacModelServer.isLoopbackOrUnspecified([127, 0, 0, 1]) && MacModelServer.isLoopbackOrUnspecified([127, 9, 9, 9]))
        XCTAssertTrue(MacModelServer.isLoopbackOrUnspecified([0, 0, 0, 0]))
        XCTAssertTrue(MacModelServer.isLoopbackOrUnspecified([UInt8](repeating: 0, count: 15) + [1]))
        XCTAssertFalse(MacModelServer.isLoopbackOrUnspecified([198, 18, 255, 254]))
        // IPv4-mapped IPv6 (::ffff:a.b.c.d) is its IPv4 address: ::ffff:127.x.x.x IS this Mac's loopback.
        let mapped = { (v4: [UInt8]) in [UInt8](repeating: 0, count: 10) + [0xFF, 0xFF] + v4 }
        XCTAssertTrue(MacModelServer.isLoopbackOrUnspecified(mapped([127, 0, 0, 1])), "::ffff:127.0.0.1")
        XCTAssertTrue(MacModelServer.isLoopbackOrUnspecified(mapped([127, 1, 2, 3])), "::ffff:127.1.2.3")
        XCTAssertTrue(MacModelServer.isLoopbackOrUnspecified(mapped([0, 0, 0, 0])), "::ffff:0.0.0.0")
        XCTAssertFalse(MacModelServer.isLoopbackOrUnspecified(mapped([93, 184, 216, 34])), "a mapped public address stays allowed")
        XCTAssertFalse(MacModelServer.isLoopbackOrUnspecified([0x20, 0x01, 0x0d, 0xb8] + [UInt8](repeating: 0, count: 11) + [1]), "2001:db8::1")
        XCTAssertTrue(MacModelServer.resolvesToLoopback("::ffff:127.0.0.1"))
        XCTAssertFalse(MacModelServer.resolvesToLoopback("::ffff:192.0.2.1"))
        XCTAssertTrue(MacModelServer.resolvesToLoopback("localhost"))
        XCTAssertTrue(MacModelServer.resolvesToLoopback("127.0.0.1"))
        XCTAssertFalse(MacModelServer.resolvesToLoopback("192.0.2.1"))
    }

    func testTheRouteIsThatPortOnlyAndNeverThePolicys() throws {
        let proxy = try EgressProxy(policy: .open, ca: nil)
        XCTAssertEqual(proxy.macRoute(host: "mac.dozable.internal", port: 11434)?.kind, .deny, "made without a port: nothing")
        XCTAssertNil(proxy.macRoute(host: "example.com", port: 443), "any other name: the policy's")
        proxy.macModelPort = 11434
        XCTAssertEqual(proxy.macRoute(host: "mac.dozable.internal", port: 11434)?.kind, .allow)
        XCTAssertEqual(proxy.macRoute(host: "mac.dozable.internal", port: 11435)?.kind, .deny, "another port of it: refused")
        proxy.policy = .locked
        XCTAssertEqual(proxy.macRoute(host: "mac.dozable.internal", port: 11434)?.kind, .allow, "a per-sandbox allow, not a policy rule")
    }

    func testTheNameResolvesOnlyForASandboxMadeWithAPort() throws {
        var q: [UInt8] = [0x00, 0x09, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0]
        for label in ["mac", "dozable", "internal"] { q.append(UInt8(label.utf8.count)); q += Array(label.utf8) }
        q += [0, 0, 1, 0, 1]
        let proxy = try EgressProxy(policy: .open, ca: nil)
        let none = proxy.answer(q)
        XCTAssertFalse(none.allowed)
        XCTAssertEqual(none.bytes[3] & 0x0f, 3, "NXDOMAIN — even under Open")
        proxy.macModelPort = 1234
        proxy.policy = .locked
        let yes = proxy.answer(q)
        XCTAssertTrue(yes.allowed, "answered under Locked too: never the policy's")
        XCTAssertEqual(Array(yes.bytes.suffix(4)), [198, 18, 255, 254], "the synthetic address")
        XCTAssertEqual(proxy.name(for: "198.18.255.254"), MacModelServer.hostName)
    }

    func testTheLoopbackIsNeverASandboxsUnlessItIsItsPort() throws {
        let (listener, port) = try Self.listen()
        defer { close(listener) }
        XCTAssertEqual(Wire.connectTCP("127.0.0.1", port, timeoutMS: 1000), -1, "by address: never")
        XCTAssertEqual(Wire.connectTCP("localhost", port, timeoutMS: 1000), -1, "by name: never")
        XCTAssertEqual(Wire.connectTCP("::ffff:127.0.0.1", port, timeoutMS: 1000), -1, "an IPv4-mapped loopback: never")
        let ok = Wire.connectTCP("127.0.0.1", port, timeoutMS: 1000, allowLoopback: true)
        XCTAssertGreaterThanOrEqual(ok, 0)
        if ok >= 0 { close(ok) }
        XCTAssertTrue(MacModelServer.answers(port: Int(port)), "doz doctor's look")
    }

    func testThroughTheProxyOpenRefusesTheLoopbackAndTheNamedPortAnswers() throws {
        let (listener, port) = try Self.listen()
        defer { close(listener) }
        // Something on this Mac's loopback answers one request with "hello".
        Thread.detachNewThread {
            let c = accept(listener, nil, nil)
            guard c >= 0 else { return }
            var buf = [UInt8](repeating: 0, count: 4096)
            _ = read(c, &buf, buf.count)
            _ = Wire.writeAll(c, Array("HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello".utf8))
            close(c)
        }
        let proxy = try EgressProxy(policy: .open, ca: nil)
        // Open: 127.0.0.1 and localhost through the proxy are refused (plain HTTP and CONNECT).
        for target in ["127.0.0.1", "localhost"] {
            let fd = Self.open(proxy, "DOZ1 P\nGET http://\(target):\(port)/ HTTP/1.1\r\nHost: \(target):\(port)\r\n\r\n")
            let reply = Self.readAll(fd)
            close(fd)
            XCTAssertTrue(reply.hasPrefix("HTTP/1.1 403"), "\(target): \(reply.prefix(80))")
            XCTAssertTrue(reply.contains("loopback"), reply)
        }
        let c = Self.open(proxy, "DOZ1 P\nCONNECT 127.0.0.1:\(port) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\n")
        XCTAssertTrue(Self.readAll(c).hasPrefix("HTTP/1.1 403"), "CONNECT to the loopback: refused")
        close(c)
        // Made with that port: its one name reaches it.
        proxy.macModelPort = port
        let other = Self.open(proxy, "DOZ1 P\nGET http://mac.dozable.internal:\(port &+ 1)/ HTTP/1.1\r\nHost: mac.dozable.internal\r\n\r\n")
        XCTAssertTrue(Self.readAll(other).hasPrefix("HTTP/1.1 403"), "another port of the name: refused")
        close(other)
        let fd = Self.open(proxy, "DOZ1 P\nGET http://mac.dozable.internal:\(port)/v1/models HTTP/1.1\r\nHost: mac.dozable.internal:\(port)\r\n\r\n")
        let reply = Self.readAll(fd)
        close(fd)
        XCTAssertTrue(reply.hasPrefix("HTTP/1.1 200") && reply.hasSuffix("hello"), reply)
        let rec = proxy.log.records.last { $0.host == "mac.dozable.internal" && $0.port == port }
        XCTAssertEqual(rec?.verdict, .allowed)
        XCTAssertTrue(rec?.rule.contains("this Mac's port \(port)") == true, rec?.rule ?? "")
    }

    func testAPlaceholderNeverGoesToTheMacsServer() throws {
        let proxy = try EgressProxy(policy: .open, ca: nil)
        proxy.macModelPort = 11434
        let fd = Self.open(proxy, "DOZ1 P\nPOST http://mac.dozable.internal:11434/v1/messages HTTP/1.1\r\nHost: mac.dozable.internal:11434\r\n"
                           + "Authorization: Bearer \(CredentialVault.placeholderPrefix)0123456789abcdef0123456789abcdef\r\nContent-Length: 0\r\n\r\n")
        let reply = Self.readAll(fd)
        close(fd)
        XCTAssertTrue(reply.hasPrefix("HTTP/1.1 403"), "a placeholder over plain HTTP is refused: \(reply.prefix(80))")
    }

    // MARK: helpers

    static func listen() throws -> (Int32, UInt16) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_addr.s_addr = inet_addr("127.0.0.1")
        guard withUnsafePointer(to: &a, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }) == 0,
              Darwin.listen(fd, 4) == 0 else { throw XCTSkip("no loopback listener") }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        return (fd, UInt16(bigEndian: a.sin_port))
    }

    static func open(_ proxy: EgressProxy, _ text: String) -> Int32 {
        var fds: [Int32] = [0, 0]
        _ = socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
        var one: Int32 = 1
        setsockopt(fds[0], SOL_SOCKET, SO_NOSIGPIPE, &one, 4)
        let server = fds[1]
        Thread.detachNewThread { proxy.handle(server) }
        _ = Wire.writeAll(fds[0], Array(text.utf8))
        var tv = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fds[0], SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        return fds[0]
    }

    static func readAll(_ fd: Int32) -> String {
        var out: [UInt8] = []
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            out += buf[0..<n]
        }
        return String(decoding: out, as: UTF8.self)
    }
}
