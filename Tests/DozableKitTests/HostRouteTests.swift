import Darwin
import XCTest
@testable import DozableKit

/// 691: the route to this Mac's ports — `host.dozable.internal:PORT` (and its alias `mac.dozable.internal:PORT`) for the
/// ports in a proxy's list, dialled at 127.0.0.1 only; nothing else of this Mac. The proxy end to end WITHOUT a VM (a
/// socketpair stands in for the guest's vsock stream); the only listeners are this test's own, on ephemeral ports.
final class HostRouteTests: XCTestCase {
    override func tearDown() {
        HostRoute.protect(nil)
        super.tearDown()
    }

    // MARK: words and the list

    func testWordsAndPorts() {
        XCTAssertEqual(try HostRoute.parsePort("8780").get(), HostPort(port: 8780))
        XCTAssertEqual(try HostRoute.parsePort("8780:tag").get(), HostPort(port: 8780, tag: true))
        for bad in ["0", "80", "1023", "70000", "8780:named", "", "x", "8780:", ":tag", "8780:tag:tag", "-1", "+8780"] {
            if case .success = HostRoute.parsePort(bad) { XCTFail("\(bad) is not a port of this Mac") }
        }
        XCTAssertEqual(try HostRoute.parseWord("host:8780").get(), [HostPort(port: 8780)])
        XCTAssertEqual(try HostRoute.parseWord("HOST:8780:tag").get(), [HostPort(port: 8780, tag: true)])
        XCTAssertEqual(try HostRoute.parseWord("host:8781,8780,8781").get().map(\.port), [8781, 8780], "each once")
        XCTAssertEqual(try HostRoute.parseWord("host:8780,8781:tag").get().map(\.tag), [true, true], "the tag applies to each")
        for bad in ["host:", "host:22", "host:0", "host:a", "host:8780,", "site:8780", "host:" + (0..<17).map { String(9000 + $0) }.joined(separator: ",")] {
            if case .success = HostRoute.parseWord(bad) { XCTFail("\(bad)") }
        }
        XCTAssertTrue(HostRoute.isHost("host.dozable.internal") && HostRoute.isHost("HOST.dozable.internal.") && HostRoute.isHost("mac.dozable.internal"))
        XCTAssertFalse(HostRoute.isHost("host.dozable.internal.evil.example") || HostRoute.isHost("dozable.internal"))
        // merged: the model server's entry is never replaced or removed — only its tag follows a grant.
        let model = HostPort(port: 11434, origin: .model)
        let m = HostRoute.merged([model, HostPort(port: 8780)], add: [HostPort(port: 11434, tag: true, origin: .live)], remove: [11434, 8780])
        XCTAssertEqual(m, [HostPort(port: 11434, tag: true, origin: .model)])
        XCTAssertEqual(HostRoute.listText([HostPort(port: 11434, origin: .model), HostPort(port: 8780, tag: true)]), "8780 (named), 11434 (model server)")
        XCTAssertEqual(HostRoute.listText([]), "none")
    }

    func testOwnPortsAndPortZeroAreNeverOpened() {
        XCTAssertNotNil(HostRoute.refusal(port: 0))
        XCTAssertNotNil(HostRoute.refusal(port: 80), "a privileged port")
        XCTAssertNil(HostRoute.refusal(port: 8780))
        HostRoute.protect { [8780] }
        XCTAssertTrue(HostRoute.refusal(port: 8780)?.contains("Dozable's own") == true)
        HostRoute.protect(nil)
        HostRoute.registerOwn(8790)
        XCTAssertNotNil(HostRoute.refusal(port: 8790), "a fenced session's proxy port while it is served")
        HostRoute.unregisterOwn(8790)
        XCTAssertNil(HostRoute.refusal(port: 8790))
    }

    // MARK: the verdict and DNS

    func testTheListIsTheRouteForBothNames() throws {
        let proxy = try EgressProxy(policy: .open, ca: nil)
        XCTAssertEqual(proxy.macRoute(host: "host.dozable.internal", port: 8780)?.kind, .deny, "no port: nothing")
        XCTAssertEqual(proxy.macRoute(host: "host.dozable.internal", port: 8780)?.rule, "no port of this Mac is open to this sandbox")
        proxy.hostPorts = [HostPort(port: 8780)]
        proxy.macModelPort = 11434
        XCTAssertEqual(proxy.hostPorts.map(\.port), [8780, 11434])
        XCTAssertEqual(proxy.hostPorts.last?.origin, .model)
        for name in ["host.dozable.internal", "mac.dozable.internal"] {
            XCTAssertEqual(proxy.macRoute(host: name, port: 8780)?.kind, .allow, name)
            XCTAssertEqual(proxy.macRoute(host: name, port: 8780)?.rule, "this Mac's port 8780")
            XCTAssertEqual(proxy.macRoute(host: name, port: 11434)?.rule, "this Mac's port 11434 (the model server this sandbox was made with)")
            let no = proxy.macRoute(host: name, port: 8781)
            XCTAssertEqual(no?.kind, .deny)
            XCTAssertEqual(no?.rule, "only ports 8780, 11434 of this Mac are open to this sandbox", "the open ports are named")
        }
        // Setting the list never touches the model server's entry; a `.model` entry given there is ignored.
        proxy.hostPorts = [HostPort(port: 9000, origin: .model)]
        XCTAssertEqual(proxy.hostPorts, [HostPort(port: 11434, origin: .model)])
        proxy.policy = .locked
        XCTAssertEqual(proxy.macRoute(host: "host.dozable.internal", port: 11434)?.kind, .allow, "never the policy's")
        // A fenced session's proxy says "this session".
        let fence = try EgressProxy(policy: .open, ca: nil)
        fence.servesFencedSession = true
        fence.hostPorts = [HostPort(port: 8780)]
        XCTAssertEqual(fence.macRoute(host: "host.dozable.internal", port: 8781)?.rule, "only port 8780 of this Mac is open to this session")
    }

    func testDNSAnswersBothNamesOnlyWhileAPortIsOpen() throws {
        func query(_ labels: [String]) -> [UInt8] {
            var q: [UInt8] = [0x00, 0x09, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0]
            for l in labels { q.append(UInt8(l.utf8.count)); q += Array(l.utf8) }
            return q + [0, 0, 1, 0, 1]
        }
        let proxy = try EgressProxy(policy: .open, ca: nil)
        for labels in [["host", "dozable", "internal"], ["mac", "dozable", "internal"]] {
            let none = proxy.answer(query(labels))
            XCTAssertFalse(none.allowed)
            XCTAssertEqual(none.bytes[3] & 0x0f, 3, "NXDOMAIN with no port — even under Open")
        }
        proxy.hostPorts = [HostPort(port: 8780)]
        proxy.policy = .locked
        for labels in [["host", "dozable", "internal"], ["mac", "dozable", "internal"]] {
            let yes = proxy.answer(query(labels))
            XCTAssertTrue(yes.allowed, "answered under Locked too")
            XCTAssertEqual(Array(yes.bytes.suffix(4)), [198, 18, 255, 254])
            XCTAssertEqual(proxy.name(for: "198.18.255.254"), labels.joined(separator: "."), "remembered by the name asked")
        }
        proxy.hostPorts = []
        XCTAssertEqual(proxy.answer(query(["host", "dozable", "internal"])).bytes[3] & 0x0f, 3, "the list emptied: NXDOMAIN again")
    }

    // MARK: end to end through the proxy

    func testItDialsTheLoopbackOnlyAndNoAddressOfThisMacOpens() throws {
        let server = try EchoServer(any: true)
        defer { server.stop() }
        let proxy = try EgressProxy(policy: .open, ca: nil)
        XCTAssertEqual(proxy.addressGuard, .strict)
        proxy.hostPorts = [HostPort(port: server.port)]
        // The name reaches it — plain HTTP, CONNECT, and redirected TCP to the synthetic address.
        var reply = Self.ask(proxy, "GET http://host.dozable.internal:\(server.port)/a HTTP/1.1\r\nHost: host.dozable.internal:\(server.port)\r\n\r\n")
        XCTAssertTrue(reply.hasPrefix("HTTP/1.1 200") && reply.contains("GET /a HTTP/1.1"), reply)
        XCTAssertEqual(server.peers.last, "127.0.0.1", "dialled at 127.0.0.1")
        reply = Self.ask(proxy, "CONNECT host.dozable.internal:\(server.port) HTTP/1.1\r\nHost: host.dozable.internal:\(server.port)\r\n\r\nGET /t HTTP/1.1\r\nHost: x\r\n\r\n")
        XCTAssertTrue(reply.hasPrefix("HTTP/1.1 200 Connection established") && reply.contains("GET /t"), reply)
        let t = MacModelServerTests.open(proxy, "DOZ1 T 198.18.255.254 \(server.port)\nGET /r HTTP/1.1\r\nHost: x\r\n\r\n")
        reply = MacModelServerTests.readAll(t)
        close(t)
        XCTAssertTrue(reply.contains("GET /r"), reply)
        XCTAssertEqual(server.peers.filter { $0 != "127.0.0.1" }, [], "only ever from 127.0.0.1")
        let before = server.count
        // The SAME open port by an address of this Mac: refused — only the name is the route.
        var targets = ["127.0.0.1", "localhost", "[::1]", "[::ffff:127.0.0.1]"]
        if let own = AddressGuard.interfaceAddresses().first(where: { $0.count == 4 && $0[0] != 127 && !($0[0] == 169 && $0[1] == 254) }) {
            targets.append(own.map(String.init).joined(separator: "."))
        } else {
            print("SKIP: this Mac has no IPv4 address but its loopback — the LAN-address row is not run")
        }
        for host in targets {
            for request in ["GET http://\(host):\(server.port)/ HTTP/1.1\r\nHost: \(host):\(server.port)\r\n\r\n",
                            "CONNECT \(host):\(server.port) HTTP/1.1\r\nHost: \(host):\(server.port)\r\n\r\n"] {
                let r = Self.ask(proxy, request)
                XCTAssertTrue(r.hasPrefix("HTTP/1.1 403"), "\(request.prefix(50)): \(r.prefix(160))")
            }
        }
        XCTAssertEqual(server.count, before, "nothing reached it by an address")
        // Another port of the name: 403 naming the open one.
        reply = Self.ask(proxy, "GET http://host.dozable.internal:\(server.port &+ 1)/ HTTP/1.1\r\nHost: host.dozable.internal\r\n\r\n")
        XCTAssertTrue(reply.hasPrefix("HTTP/1.1 403") && reply.contains("only port \(server.port) of this Mac"), reply)
    }

    /// The destination is the request's authority (or the CONNECT target) — a `Host:` field never retargets.
    func testAHostFieldNeverRetargets() throws {
        let server = try EchoServer()
        defer { server.stop() }
        let proxy = try EgressProxy(policy: .locked, ca: nil)
        proxy.hostPorts = [HostPort(port: server.port)]
        // The route with a Host naming somewhere else: still the route (to this port), the field passed as it is.
        var reply = Self.ask(proxy, "GET http://host.dozable.internal:\(server.port)/h HTTP/1.1\r\nHost: example.com\r\n\r\n")
        XCTAssertTrue(reply.hasPrefix("HTTP/1.1 200") && reply.contains("Host: example.com"), reply)
        let n = server.count
        // Somewhere else with a Host naming the route: judged as that somewhere else (Locked: refused), never routed.
        reply = Self.ask(proxy, "GET http://example.com:\(server.port)/ HTTP/1.1\r\nHost: host.dozable.internal:\(server.port)\r\n\r\n")
        XCTAssertTrue(reply.hasPrefix("HTTP/1.1 403"), reply)
        reply = Self.ask(proxy, "CONNECT example.com:\(server.port) HTTP/1.1\r\nHost: host.dozable.internal:\(server.port)\r\n\r\n")
        XCTAssertTrue(reply.hasPrefix("HTTP/1.1 403"), reply)
        // Under Open, the loopback by address with the route in Host: refused.
        proxy.policy = .open
        reply = Self.ask(proxy, "GET http://127.0.0.1:\(server.port)/ HTTP/1.1\r\nHost: host.dozable.internal:\(server.port)\r\n\r\n")
        XCTAssertTrue(reply.hasPrefix("HTTP/1.1 403"), reply)
        XCTAssertEqual(server.count, n, "none of them reached it")
    }

    func testDozablesOwnPortsAreRefusedAtConnectTime() throws {
        let server = try EchoServer()
        defer { server.stop() }
        let proxy = try EgressProxy(policy: .open, ca: nil)
        proxy.hostPorts = [HostPort(port: server.port)]
        XCTAssertTrue(Self.ask(proxy, "GET http://host.dozable.internal:\(server.port)/ HTTP/1.1\r\nHost: x\r\n\r\n").hasPrefix("HTTP/1.1 200"))
        // A dashboard (or a proxy) starts later on the granted port: refused from then on.
        HostRoute.protect { [server.port] }
        let n = server.count
        let reply = Self.ask(proxy, "GET http://host.dozable.internal:\(server.port)/ HTTP/1.1\r\nHost: x\r\n\r\n")
        XCTAssertTrue(reply.hasPrefix("HTTP/1.1 403") && reply.contains("Dozable's own"), reply)
        let c = Self.ask(proxy, "CONNECT host.dozable.internal:\(server.port) HTTP/1.1\r\nHost: x\r\n\r\n")
        XCTAssertTrue(c.hasPrefix("HTTP/1.1 403"), c)
        XCTAssertEqual(server.count, n)
    }

    func testOneProxysListIsNotAnothers() throws {
        let a = try EchoServer(), b = try EchoServer()
        defer { a.stop(); b.stop() }
        let pa = try EgressProxy(policy: .open, ca: nil), pb = try EgressProxy(policy: .open, ca: nil)
        pa.hostPorts = [HostPort(port: a.port)]
        pb.hostPorts = [HostPort(port: b.port)]
        XCTAssertTrue(Self.ask(pa, "GET http://host.dozable.internal:\(a.port)/ HTTP/1.1\r\nHost: x\r\n\r\n").hasPrefix("HTTP/1.1 200"))
        XCTAssertTrue(Self.ask(pa, "GET http://host.dozable.internal:\(b.port)/ HTTP/1.1\r\nHost: x\r\n\r\n").hasPrefix("HTTP/1.1 403"), "B's port is not A's")
        XCTAssertTrue(Self.ask(pb, "GET http://host.dozable.internal:\(a.port)/ HTTP/1.1\r\nHost: x\r\n\r\n").hasPrefix("HTTP/1.1 403"), "A's port is not B's")
        XCTAssertTrue(Self.ask(pb, "GET http://host.dozable.internal:\(b.port)/ HTTP/1.1\r\nHost: x\r\n\r\n").hasPrefix("HTTP/1.1 200"))
    }

    // MARK: the session-naming header

    func testATaggedPortNamesTheSessionAndASpoofIsReplaced() throws {
        let server = try EchoServer()
        defer { server.stop() }
        let proxy = try EgressProxy(policy: .open, ca: nil)
        proxy.sessionLabel = "hub-client"
        proxy.hostPorts = [HostPort(port: server.port, tag: true)]
        let spoof = "GET http://host.dozable.internal:\(server.port)/s HTTP/1.1\r\nHost: x\r\nX-Dozable-Session: evil\r\n"
            + "x-dozable-session: evil2\r\nX-DOZABLE-SESSION:evil3\r\nAccept: */*\r\n\r\n"
        var reply = Self.ask(proxy, spoof)
        XCTAssertTrue(reply.hasPrefix("HTTP/1.1 200"), reply)
        let head = server.heads.last ?? ""
        XCTAssertEqual(head.lowercased().components(separatedBy: "x-dozable-session").count - 1, 1, "exactly one copy: \(head)")
        XCTAssertTrue(head.contains("X-Dozable-Session: hub-client\r\n"), head)
        XCTAssertFalse(head.contains("evil"), "every copy the program sent is removed")
        XCTAssertTrue(head.contains("Accept: */*"), "the other fields pass")
        // Without the tag: the route is transparent — the program's own field passes untouched, nothing is added.
        proxy.hostPorts = [HostPort(port: server.port)]
        reply = Self.ask(proxy, "GET http://host.dozable.internal:\(server.port)/u HTTP/1.1\r\nHost: x\r\nX-Dozable-Session: mine\r\n\r\n")
        XCTAssertTrue(reply.hasPrefix("HTTP/1.1 200"), reply)
        XCTAssertTrue(server.heads.last?.contains("X-Dozable-Session: mine\r\n") == true)
        XCTAssertFalse(server.heads.last?.contains("hub-client") == true)
        // CONNECT: the proxy does not read the tunnel — nothing removed or added, even for a tagged port.
        proxy.hostPorts = [HostPort(port: server.port, tag: true)]
        reply = Self.ask(proxy, "CONNECT host.dozable.internal:\(server.port) HTTP/1.1\r\nHost: x\r\n\r\nGET /c HTTP/1.1\r\nHost: x\r\nX-Dozable-Session: inside\r\n\r\n")
        XCTAssertTrue(reply.contains("GET /c"), reply)
        XCTAssertTrue(server.heads.last?.contains("X-Dozable-Session: inside") == true && server.heads.last?.contains("hub-client") == false)
        // A label that could inject a field is never written.
        proxy.sessionLabel = "a\r\nX-Evil: 1"
        _ = Self.ask(proxy, "GET http://host.dozable.internal:\(server.port)/i HTTP/1.1\r\nHost: x\r\nX-Dozable-Session: s\r\n\r\n")
        XCTAssertFalse(server.heads.last?.contains("X-Evil") == true)
        XCTAssertFalse(server.heads.last?.lowercased().contains("x-dozable-session") == true, "removed, and nothing unsafe added")
    }

    func testAModelPortSandboxIsAsBefore() throws {
        // A sandbox with only its model server: the texts are exactly the earlier ones.
        let proxy = try EgressProxy(policy: .open, ca: nil)
        proxy.macModelPort = 11434
        XCTAssertEqual(proxy.macRoute(host: "mac.dozable.internal", port: 11435)?.rule, "only port 11434 of this Mac is open to this sandbox (its model server)")
        XCTAssertEqual(proxy.macRoute(host: "mac.dozable.internal", port: 11434)?.rule, "this Mac's port 11434 (the model server this sandbox was made with)")
        proxy.macModelPort = nil
        XCTAssertEqual(proxy.hostPorts, [])
    }

    // MARK: helpers

    static func ask(_ proxy: EgressProxy, _ request: String) -> String {
        let fd = MacModelServerTests.open(proxy, "DOZ1 P\n" + request)
        defer { close(fd) }
        return MacModelServerTests.readAll(fd)
    }
}

/// A listener on this Mac (127.0.0.1, or every interface with `any`) on an ephemeral port: each connection's head is kept
/// (and its peer address), answered 200 with the head as the body.
final class EchoServer: @unchecked Sendable {
    let fd: Int32
    let port: UInt16
    private let lock = NSLock()
    private var _heads: [String] = []
    private var _peers: [String] = []
    var heads: [String] { lock.withLock { _heads } }
    var peers: [String] { lock.withLock { _peers } }
    var count: Int { lock.withLock { _heads.count } }

    init(any: Bool = false) throws {
        let s = socket(AF_INET, SOCK_STREAM, 0)
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_addr.s_addr = any ? INADDR_ANY : inet_addr("127.0.0.1")
        guard withUnsafePointer(to: &a, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }) == 0,
              Darwin.listen(s, 16) == 0 else { close(s); throw XCTSkip("no listener") }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(s, $0, &len) } }
        fd = s
        port = UInt16(bigEndian: a.sin_port)
        Thread.detachNewThread { [self] in
            while true {
                var peer = sockaddr_in()
                var plen = socklen_t(MemoryLayout<sockaddr_in>.size)
                let c = withUnsafeMutablePointer(to: &peer) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(s, $0, &plen) } }
                if c < 0 { if errno == EINTR { continue }; return }
                let ip = String(cString: inet_ntoa(peer.sin_addr))
                var acc = [UInt8]()
                var buf = [UInt8](repeating: 0, count: 8192)
                var tv = timeval(tv_sec: 5, tv_usec: 0)
                setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                while !String(decoding: acc, as: UTF8.self).contains("\r\n\r\n") {
                    let n = read(c, &buf, buf.count)
                    if n <= 0 { break }
                    acc += buf[0..<n]
                }
                let head = String(decoding: acc, as: UTF8.self)
                lock.withLock { _heads.append(head); _peers.append(ip) }
                _ = Wire.writeAll(c, Array("HTTP/1.1 200 OK\r\nContent-Length: \(acc.count)\r\nConnection: close\r\n\r\n\(head)".utf8))
                close(c)
            }
        }
    }

    func stop() { Darwin.shutdown(fd, SHUT_RDWR); close(fd) }
}
