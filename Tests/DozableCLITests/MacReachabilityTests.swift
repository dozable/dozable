import Darwin
import Foundation
import XCTest
@testable import DozableHost

/// The one reachability check against LOCAL listeners on ports the system chooses (never another Mac, never the
/// internet): a Dozable dashboard's 200, another page's 200, a 308 to https, a closed port, a silent socket timing out
/// within the deadline. Each listener checks what it was sent: exactly `GET /`, no Cookie, Authorization or Referer.
final class MacReachabilityTests: XCTestCase {
    static let livePorts: Set<Int> = [7443, 8765, 8766, 8780, 8782, 8790, 8890, 8891, 8443]

    /// One connection's worth of a server on 127.0.0.1:<OS-chosen>: answers `reply` (nil: never answers).
    final class Listener: @unchecked Sendable {
        let fd: Int32
        let port: Int
        private let lock = NSLock()
        private var heads: [String] = []
        private var held: [Int32] = []
        var requests: [String] { lock.withLock { heads } }

        init(reply: String?) throws {
            let sock = socket(AF_INET, SOCK_STREAM, 0)
            var on: Int32 = 1
            setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
            var a = sockaddr_in()
            a.sin_family = sa_family_t(AF_INET); a.sin_addr.s_addr = inet_addr("127.0.0.1"); a.sin_port = 0
            let b = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            guard b == 0, listen(sock, 8) == 0 else { throw HostError(.failed, "listen") }
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(sock, $0, &len) } }
            fd = sock
            port = Int(UInt16(bigEndian: a.sin_port))
            let fd = self.fd
            Thread.detachNewThread { [self] in
                while true {
                    let c = accept(fd, nil, nil)
                    if c < 0 { return }
                    var data = Data(), buf = [UInt8](repeating: 0, count: 4096)
                    while !data.contains("\r\n\r\n".data(using: .utf8)!) {
                        let n = read(c, &buf, buf.count)
                        if n <= 0 { break }
                        data.append(contentsOf: buf[0..<n])
                    }
                    lock.withLock { heads.append(String(decoding: data, as: UTF8.self)) }
                    if let reply {
                        _ = reply.withCString { write(c, $0, strlen($0)) }
                        close(c)
                    } else {
                        lock.withLock { held.append(c) }          // a silent socket: kept open, never answered
                    }
                }
            }
        }

        func stop() {
            shutdown(fd, SHUT_RDWR)
            close(fd)
            lock.withLock { for c in held { close(c) } }
        }

        var origin: MacOrigin { MacOrigin(scheme: "http", host: "127.0.0.1", port: port) }
    }

    static func page(_ status: String, _ body: String, headers: String = "") -> String {
        "HTTP/1.1 \(status)\r\nContent-Type: text/html\r\nContent-Length: \(body.utf8.count)\r\n\(headers)Connection: close\r\n\r\n\(body)"
    }

    private func assertPlain(_ l: Listener, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(Self.livePorts.contains(l.port), "an OS-chosen port, never a live one", file: file, line: line)
        XCTAssertEqual(l.requests.count, 1, "one request", file: file, line: line)
        guard let head = l.requests.first else { return }
        let lines = head.components(separatedBy: "\r\n")
        XCTAssertEqual(lines.first, "GET / HTTP/1.1", "exactly GET /", file: file, line: line)
        for h in lines.dropFirst() {
            let name = h.split(separator: ":").first.map { $0.lowercased() } ?? ""
            XCTAssertFalse(["cookie", "authorization", "referer", "proxy-authorization"].contains(name), "sent \(name)", file: file, line: line)
        }
        XCTAssertTrue(lines.contains("Host: 127.0.0.1:\(l.port)"), "the Host is the origin's", file: file, line: line)
    }

    func testADozableDashboardAnswers() async throws {
        let l = try Listener(reply: Self.page("200 OK", "<!doctype html><html><head><title>Dozable – m1mini</title></head><body></body></html>"))
        defer { l.stop() }
        let r = await MacReachability.check(l.origin)
        XCTAssertEqual(r, MacReachability.Result(.reachable, reportedName: "m1mini"))
        assertPlain(l)
    }

    func testAnUnnamedDozableDashboardAnswers() async throws {
        let l = try Listener(reply: Self.page("200 OK", "<html><head><title>Dozable</title></head></html>"))
        defer { l.stop() }
        let r = await MacReachability.check(l.origin)
        XCTAssertEqual(r, MacReachability.Result(.reachable))
        assertPlain(l)
    }

    func testAnotherPageIsNotDozable() async throws {
        let l = try Listener(reply: Self.page("200 OK", "<html><head><title>Router admin</title></head></html>"))
        defer { l.stop() }
        let r = await MacReachability.check(l.origin)
        XCTAssertEqual(r.outcome, .notDozable)
        assertPlain(l)
    }

    func testA308IsNotFollowed() async throws {
        let target = try Listener(reply: Self.page("200 OK", "<title>Dozable</title>"))
        defer { target.stop() }
        let l = try Listener(reply: Self.page("308 Permanent Redirect", "", headers: "Location: https://127.0.0.1:\(target.port)/\r\n"))
        defer { l.stop() }
        let r = await MacReachability.check(l.origin)
        XCTAssertEqual(r.outcome, .redirected)
        assertPlain(l)
        XCTAssertEqual(target.requests.count, 0, "the redirect was not followed")
    }

    func testAClosedPortIsRefused() async throws {
        let l = try Listener(reply: nil)
        let o = l.origin
        l.stop()
        let r = await MacReachability.check(o)
        XCTAssertEqual(r.outcome, .refused)
    }

    func testASilentSocketTimesOutWithinTheDeadline() async throws {
        let l = try Listener(reply: nil)
        defer { l.stop() }
        let t0 = Date()
        let r = await MacReachability.check(l.origin)
        let took = Date().timeIntervalSince(t0)
        XCTAssertEqual(r.outcome, .timeout)
        XCTAssertLessThan(took, MacReachability.deadline + 1.5, "within the 3 s deadline (took \(took))")
        assertPlain(l)
    }

    func testTheTitle() {
        XCTAssertEqual(MacReachability.title(Data("<TITLE>Dozable – studio</TITLE>".utf8))?.name, "studio")
        XCTAssertEqual(MacReachability.title(Data("<title>Dozable - studio</title>".utf8))?.name, "studio")
        XCTAssertNotNil(MacReachability.title(Data("<title> Dozable </title>".utf8)))
        XCTAssertNil(MacReachability.title(Data("<title>Dozable – <script></title>".utf8)), "a name with anything else is not taken")
        XCTAssertNil(MacReachability.title(Data("<title>Not Dozable</title>".utf8)))
        XCTAssertNil(MacReachability.title(Data("no title".utf8)))
    }
}
