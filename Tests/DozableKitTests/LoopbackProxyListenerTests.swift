import Darwin
import XCTest
@testable import DozableKit

/// 683: a fenced session's proxy on this Mac's loopback — the address guard, and the listener (password, head deadline,
/// connection cap, Proxy-Authorization never forwarded, drain) end to end on 127.0.0.1. Every listener is this test's own.
final class AddressGuardTests: XCTestCase {
    func v6(_ s: String) -> [UInt8] {
        var a = in6_addr()
        XCTAssertEqual(inet_pton(AF_INET6, s, &a), 1, s)
        return withUnsafeBytes(of: a) { Array($0) }
    }

    func testTheStrictGuard() {
        let own: Set<[UInt8]> = [[192, 168, 1, 23], v6("2001:db8::23")]
        let refused: [([UInt8], String)] = [
            ([127, 0, 0, 1], "loopback"), ([127, 9, 9, 9], "loopback"), ([0, 0, 0, 0], "0/8"), ([0, 1, 2, 3], "0/8"),
            ([169, 254, 169, 254], "metadata"), ([169, 254, 1, 1], "link-local"), ([224, 0, 0, 251], "multicast"),
            ([239, 255, 255, 250], "multicast"), ([255, 255, 255, 255], "broadcast"), ([192, 168, 1, 23], "this Mac's own"),
            (v6("::"), "::"), (v6("::1"), "::1"), (v6("fe80::1"), "fe80"), (v6("febf::1"), "fe80/10's end"), (v6("fec0::1"), "site-local"),
            (v6("ff02::1"), "multicast"), (v6("::ffff:127.0.0.1"), "mapped loopback"), (v6("::ffff:169.254.169.254"), "mapped metadata"),
            (v6("::ffff:192.168.1.23"), "mapped own"), (v6("::169.254.169.254"), "compatible metadata"), (v6("::127.0.0.1"), "compatible loopback"),
            (v6("64:ff9b::a9fe:a9fe"), "NAT64 metadata"), (v6("64:ff9b::7f00:1"), "NAT64 loopback"), (v6("64:ff9b:1::1"), "NAT64 local-use"),
            (v6("2001:db8::23"), "this Mac's own v6"),
        ]
        for (ip, what) in refused { XCTAssertNotNil(AddressGuard.strictRefusal(ip, own: own), what) }
        let allowed: [([UInt8], String)] = [
            ([93, 184, 216, 34], "public"), ([10, 0, 0, 5], "another machine on the LAN"), ([192, 168, 1, 24], "the Mac's neighbour"),
            (v6("2606:4700::1111"), "public v6"), (v6("::ffff:93.184.216.34"), "mapped public"), (v6("64:ff9b::5db8:d822"), "NAT64 public"),
        ]
        for (ip, what) in allowed { XCTAssertNil(AddressGuard.strictRefusal(ip, own: own), what) }
        XCTAssertNotNil(AddressGuard.strictRefusal([1, 2, 3], own: []), "an odd length is refused")
        // The sandboxes' rule is unchanged: loopback only.
        XCTAssertNotNil(AddressGuard.loopback.refusal([127, 0, 0, 1]))
        XCTAssertNil(AddressGuard.loopback.refusal([169, 254, 169, 254]))
    }

    func testThisMacsOwnAddressesAreRead() {
        let own = AddressGuard.interfaceAddresses()
        XCTAssertTrue(own.contains([127, 0, 0, 1]), "lo0 is among them")
        XCTAssertNotNil(AddressGuard.strict.refusal(own.first { $0.count == 4 && $0[0] != 127 } ?? [127, 0, 0, 1]))
    }

    func testConnectRefusesWhatTheGuardRefuses() throws {
        let (l, port) = try MacModelServerTests.listen()
        defer { close(l) }
        let r = Wire.connectTCPGuarded("169.254.169.254", 80, timeoutMS: 500, guard: .strict)
        XCTAssertEqual(r.fd, -1)
        XCTAssertTrue(r.refused?.contains("link-local") == true, r.refused ?? "")
        let lo = Wire.connectTCPGuarded("127.0.0.1", port, timeoutMS: 500, guard: .strict)
        XCTAssertEqual(lo.fd, -1)
        XCTAssertNotNil(lo.refused)
        // A guarded test seam's fake upstream skips it.
        let seam = Wire.connectTCPGuarded("127.0.0.1", port, timeoutMS: 500, allowLoopback: true, guard: .strict)
        XCTAssertGreaterThanOrEqual(seam.fd, 0)
        if seam.fd >= 0 { close(seam.fd) }
    }
}

final class LoopbackProxyListenerTests: XCTestCase {
    /// A fake upstream on 127.0.0.1: answers each request with 200 and the request head it got (so a test sees what was
    /// forwarded), or, for CONNECT tunnels, echoes.
    final class Upstream: @unchecked Sendable {
        let fd: Int32
        let port: UInt16
        init() throws {
            (fd, port) = try MacModelServerTests.listen()
            Thread.detachNewThread { [fd] in
                while true {
                    let c = accept(fd, nil, nil)
                    if c < 0 { return }
                    Thread.detachNewThread {
                        var buf = [UInt8](repeating: 0, count: 8192)
                        var acc: [UInt8] = []
                        while HTTPRequestReader.find(acc, [13, 10, 13, 10]) == nil {
                            let n = read(c, &buf, buf.count)
                            if n <= 0 { break }
                            acc += buf[0..<n]
                        }
                        let body = Array("GOT ".utf8) + acc
                        _ = Wire.writeAll(c, Array("HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8) + body)
                        close(c)
                    }
                }
            }
        }
        deinit { close(fd) }
    }

    var upstream: Upstream!
    var proxy: EgressProxy!
    var listener: LoopbackProxyListener!
    var port: UInt16 = 0
    let password = "pw-" + LoopbackProxyListener.newPassword()

    func start(maximum: Int = 256, deadline: Duration = .seconds(5)) throws {
        upstream = try Upstream()
        var p = NetworkPolicy(defaultAction: .deny, rules: [])
        p.allow(host: "allowed.doz.test", note: "test")
        proxy = try EgressProxy(policy: p, ca: nil)
        proxy.addressGuard = .strict
        proxy.fenceUpstreamsForTests = ["allowed.doz.test": .init(host: "127.0.0.1", port: upstream.port)]
        let (fd, pt) = try MacModelServerTests.listen()
        port = pt
        held = dup(fd)                     // the holder's copy
        listener = LoopbackProxyListener(fd: fd, proxy: proxy, secretSHA256: LoopbackProxyListener.sha256(password), maximum: maximum, headDeadline: deadline)
        listener.start()
    }

    var held: Int32 = -1

    override func tearDown() {
        listener?.drain(timeout: 0)
        if held >= 0 { close(held) }
    }

    func connect() -> Int32 {
        let fd = Wire.connectTCP("127.0.0.1", port, timeoutMS: 2000, allowLoopback: true)
        var tv = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        return fd
    }

    func ask(_ text: String) -> String {
        let fd = connect()
        defer { close(fd) }
        _ = Wire.writeAll(fd, Array(text.utf8))
        return MacModelServerTests.readAll(fd)
    }

    func auth(_ pw: String) -> String { "Proxy-Authorization: Basic " + Data("doz:\(pw)".utf8).base64EncodedString() + "\r\n" }

    func testThePasswordAndWhatGoesUpstream() throws {
        try start()
        let req = "GET http://allowed.doz.test/x HTTP/1.1\r\nHost: allowed.doz.test\r\n"
        XCTAssertTrue(ask(req + "\r\n").hasPrefix("HTTP/1.1 407"), "no password")
        XCTAssertTrue(ask(req + auth("wrong") + "\r\n").hasPrefix("HTTP/1.1 407"), "a wrong password")
        let ok = ask(req + auth(password) + "\r\n")
        XCTAssertTrue(ok.hasPrefix("HTTP/1.1 200"), ok)
        XCTAssertTrue(ok.contains("GOT GET /x HTTP/1.1"), "the origin-form request went upstream: \(ok)")
        XCTAssertFalse(ok.lowercased().contains("proxy-authorization"), "the password never goes upstream")
        let denied = ask("GET http://denied.doz.test/ HTTP/1.1\r\nHost: denied.doz.test\r\n" + auth(password) + "\r\n")
        XCTAssertTrue(denied.hasPrefix("HTTP/1.1 403"), "a host the policy does not allow: \(denied.prefix(60))")
        // CONNECT: the tunnel to the allowed name; the password checked first.
        XCTAssertTrue(ask("CONNECT allowed.doz.test:443 HTTP/1.1\r\n\r\n").hasPrefix("HTTP/1.1 407"))
    }

    func testThisMacsAddressesAreRefusedWhateverThePolicy() throws {
        try start()
        proxy.policy = .open
        for target in ["127.0.0.1:\(upstream.port)", "169.254.169.254:80", "[::ffff:127.0.0.1]:\(upstream.port)", "localhost:\(upstream.port)"] {
            let r = ask("CONNECT \(target) HTTP/1.1\r\n" + auth(password) + "\r\n")
            XCTAssertTrue(r.hasPrefix("HTTP/1.1 403"), "\(target): \(r.prefix(80))")
        }
        let own = AddressGuard.interfaceAddresses().first { $0.count == 4 && $0[0] != 127 }
        if let own {
            let ip = own.map(String.init).joined(separator: ".")
            let r = ask("GET http://\(ip):\(upstream.port)/ HTTP/1.1\r\nHost: \(ip)\r\n" + auth(password) + "\r\n")
            XCTAssertTrue(r.hasPrefix("HTTP/1.1 403") && r.contains("this Mac's own"), "this Mac's own address \(ip): \(r.prefix(120))")
        }
    }

    func testTheHeadDeadline() throws {
        try start(deadline: .milliseconds(400))
        let fd = connect()
        defer { close(fd) }
        let t0 = Date()
        _ = Wire.writeAll(fd, Array("GET http://allowed.doz.test/ HTTP/1.1\r\n".utf8))      // and never the rest
        var b = [UInt8](repeating: 0, count: 64)
        let n = read(fd, &b, b.count)
        XCTAssertLessThanOrEqual(n, 0, "closed, nothing answered")
        XCTAssertLessThan(Date().timeIntervalSince(t0), 3, "closed at the deadline")
        XCTAssertTrue(ask("GET http://allowed.doz.test/ HTTP/1.1\r\n" + auth(password) + "\r\n").hasPrefix("HTTP/1.1 200"), "others still served")
    }

    func testTheConnectionCap() throws {
        try start(maximum: 3)
        let idle = (0..<3).map { _ in connect() }
        defer { for f in idle { close(f) } }
        usleep(200_000)
        XCTAssertEqual(listener.active, 3)
        let r = ask("GET http://allowed.doz.test/ HTTP/1.1\r\n" + auth(password) + "\r\n")
        XCTAssertTrue(r.hasPrefix("HTTP/1.1 503"), "the 4th: \(r.prefix(60))")
        for f in idle { Darwin.shutdown(f, SHUT_RDWR) }
        usleep(300_000)
        XCTAssertTrue(ask("GET http://allowed.doz.test/ HTTP/1.1\r\n" + auth(password) + "\r\n").hasPrefix("HTTP/1.1 200"), "served again once they went")
    }

    func testDrainStopsAcceptingButLeavesTheSocketListening() throws {
        try start()
        let idle = connect()
        defer { close(idle) }
        usleep(100_000)
        let cut = listener.drain(timeout: 1)
        XCTAssertEqual(cut, 0, "an idle connection (no head yet) is closed at once, not cut at the end")
        var b = [UInt8](repeating: 0, count: 8)
        XCTAssertLessThanOrEqual(read(idle, &b, b.count), 0, "the idle one was closed")
        XCTAssertFalse(listener.isAccepting)
        // The holder's copy keeps it listening: a request waits in the backlog, and the next listener serves it.
        let waiting = connect()
        defer { close(waiting) }
        XCTAssertGreaterThanOrEqual(waiting, 0, "the port still takes connections")
        _ = Wire.writeAll(waiting, Array(("GET http://allowed.doz.test/w HTTP/1.1\r\n" + auth(password) + "\r\n").utf8))
        let next = LoopbackProxyListener(fd: dup(held), proxy: proxy, secretSHA256: LoopbackProxyListener.sha256(password))
        next.start()
        defer { next.drain(timeout: 0) }
        XCTAssertTrue(MacModelServerTests.readAll(waiting).hasPrefix("HTTP/1.1 200"), "served by the next listener")
    }
}
