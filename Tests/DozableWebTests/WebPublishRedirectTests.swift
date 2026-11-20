import XCTest
import Darwin
@testable import DozableHost
@testable import DozableWeb

/// 715/716: port 80's redirect of a dashboard published on Tailscale — a loopback TCP port (127.0.0.1 only; never a unix
/// socket, which Tailscale serves only for an admin) answering every request with a 308 to the published https address
/// and the request's own path; nothing else (no Host believed, any method, a bad target → `/`). Ports are the OS's pick.
final class WebPublishRedirectTests: XCTestCase {
    func connectLoopback(_ port: Int) -> Int32? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = in_port_t(UInt16(port).bigEndian)
        a.sin_addr.s_addr = inet_addr("127.0.0.1")
        let r = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        if r != 0 { close(fd); return nil }
        return fd
    }

    func ask(_ port: Int, _ request: String) -> String {
        guard let fd = connectLoopback(port) else { return "" }
        defer { close(fd) }
        var tv = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        _ = request.withCString { write(fd, $0, strlen($0)) }
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true { let n = read(fd, &buf, buf.count); if n <= 0 { break }; data.append(buf, count: n) }
        return String(decoding: data, as: UTF8.self)
    }

    func testEveryRequestIsRedirectedToThePublishedAddressOverALoopbackPort() async throws {
        let port = try XCTUnwrap(TailscalePublish.freeLoopbackPort())
        let origin = "https://dozable-john-mac-studio.junco-shaula.ts.net"
        XCTAssertNil(TailscalePublish.askRedirect(port: port), "nothing listens yet")
        let r = try await WebPublishRedirect.start(port: port, origin: origin)
        XCTAssertEqual(r.port, port)

        let a = TailscalePublish.askRedirect(port: port)
        XCTAssertEqual(a?.status, 308)
        XCTAssertEqual(a?.location, origin + "/doctor")

        let b = ask(port, "GET /devices?x=1 HTTP/1.1\r\nHost: evil.example\r\nConnection: close\r\n\r\n")
        XCTAssertTrue(b.hasPrefix("HTTP/1.1 308"), b)
        XCTAssertTrue(b.contains("Location: \(origin)/devices?x=1\r\n"), b)
        XCTAssertFalse(b.contains("evil.example"), "the Host is never believed")

        let c = ask(port, "POST http://evil.example/x HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\nConnection: close\r\n\r\nabc")
        XCTAssertTrue(c.hasPrefix("HTTP/1.1 308"), c)
        XCTAssertTrue(c.contains("Location: \(origin)/\r\n"), c)

        // Loopback only: the listener is bound to 127.0.0.1, not to every address.
        XCTAssertEqual(r.channel.localAddress?.ipAddress, "127.0.0.1")

        // A second one on the same port is refused (never shadows what listens there).
        do { _ = try await WebPublishRedirect.start(port: port, origin: origin); XCTFail("a taken port was bound again") } catch {
            XCTAssertTrue("\(error)".contains("in use"), "\(error)")
        }

        await r.close()
        XCTAssertNil(TailscalePublish.askRedirect(port: port))
        // Bound again after a close (a restarted dashboard).
        let again = try await WebPublishRedirect.start(port: port, origin: origin)
        XCTAssertEqual(TailscalePublish.askRedirect(port: port)?.status, 308)
        await again.close()
    }

    func testAPortAnotherProgramHoldsIsRefused() async throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = 0
        a.sin_addr.s_addr = inet_addr("127.0.0.1")
        XCTAssertEqual(withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }, 0)
        XCTAssertEqual(listen(fd, 4), 0)
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        let port = Int(UInt16(bigEndian: a.sin_port))
        do { _ = try await WebPublishRedirect.start(port: port, origin: "https://n.t.ts.net"); XCTFail("bound over another program's port") } catch {
            XCTAssertTrue("\(error)".contains("127.0.0.1:\(port)"), "\(error)")
        }
    }
}
