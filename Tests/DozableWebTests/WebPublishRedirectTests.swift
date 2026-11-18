import XCTest
import Darwin
@testable import DozableHost
@testable import DozableWeb

/// 715: port 80's redirect of a dashboard published on Tailscale — a unix socket answering every request with a 308 to
/// the published https address and the request's own path; nothing else (no Host believed, any method, a bad target → `/`).
final class WebPublishRedirectTests: XCTestCase {
    func ask(_ path: String, _ request: String) -> String {
        guard let fd = UnixSocket.connect(path) else { return "" }
        defer { close(fd) }
        var tv = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        _ = request.withCString { write(fd, $0, strlen($0)) }
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true { let n = read(fd, &buf, buf.count); if n <= 0 { break }; data.append(buf, count: n) }
        return String(decoding: data, as: UTF8.self)
    }

    func testEveryRequestIsRedirectedToThePublishedAddress() async throws {
        let dir = "/tmp/dzr-\(getpid())"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/http.sock"
        let origin = "https://dozable-m1max.junco-shaula.ts.net"
        // A file there that is not a socket is never removed: refused.
        FileManager.default.createFile(atPath: path, contents: Data("not a socket".utf8))
        do { _ = try await WebPublishRedirect.start(path: path, origin: origin); XCTFail("a regular file was replaced") } catch {}
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "not a socket")
        unlink(path)
        let r = try await WebPublishRedirect.start(path: path, origin: origin)
        var st = stat()
        XCTAssertEqual(stat(path, &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o600)

        let a = TailscalePublish.askRedirect(path)
        XCTAssertEqual(a?.status, 308)
        XCTAssertEqual(a?.location, origin + "/doctor")

        let b = ask(path, "GET /devices?x=1 HTTP/1.1\r\nHost: evil.example\r\nConnection: close\r\n\r\n")
        XCTAssertTrue(b.hasPrefix("HTTP/1.1 308"), b)
        XCTAssertTrue(b.contains("Location: \(origin)/devices?x=1\r\n"), b)
        XCTAssertFalse(b.contains("evil.example"), "the Host is never believed")

        let c = ask(path, "POST http://evil.example/x HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\nConnection: close\r\n\r\nabc")
        XCTAssertTrue(c.hasPrefix("HTTP/1.1 308"), c)
        XCTAssertTrue(c.contains("Location: \(origin)/\r\n"), c)

        await r.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertNil(TailscalePublish.askRedirect(path))
    }
}
