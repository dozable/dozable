import Darwin
import Foundation

/// A webhook receiver for the tests: an HTTP/1.1 listener on 127.0.0.1, on a free port the system picks, that records
/// every call and answers as the test says. It is the test's own; it touches nothing else and is stopped by the test.
final class TestWebhookListener: @unchecked Sendable {
    enum Answer: Sendable {
        case status(Int)
        /// A 302 to another address.
        case redirect(String)
        /// Takes the call and never answers, until the caller gives up or the listener stops.
        case hang
        /// A 200 whose body never ends: bytes are written until the caller stops reading (at most 64 MiB).
        case endless
    }

    struct Call: Sendable {
        var path: String
        var headers: [String: String]   // names in lower case
        var body: [UInt8]
        var at: Date
        var json: [String: Any]? { (try? JSONSerialization.jsonObject(with: Data(body))) as? [String: Any] }
    }

    let port: Int
    var url: String { "http://127.0.0.1:\(port)" }
    private let fd: Int32
    private let lock = NSLock()
    private var recorded: [Call] = []
    private var accepted = 0
    private var sent = 0
    private var open: [Int32] = []
    private var stopped = false
    private let answer: @Sendable (Int) -> Answer

    /// answer: what to answer the n-th call (0 first).
    init(answer: @escaping @Sendable (Int) -> Answer = { _ in .status(200) }) throws {
        self.answer = answer
        let s = socket(AF_INET, SOCK_STREAM, 0)
        var one: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var a = sockaddr_in()
        a.sin_family = sa_family_t(AF_INET)
        a.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(s, $0, len) } }
        guard bound == 0, listen(s, 16) == 0 else { close(s); throw NSError(domain: "TestWebhookListener", code: Int(errno)) }
        _ = withUnsafeMutablePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(s, $0, &len) } }
        fd = s
        port = Int(UInt16(bigEndian: a.sin_port))
        Thread.detachNewThread { [self] in acceptLoop() }
    }

    deinit { stop() }

    var calls: [Call] { lock.withLock { recorded } }
    /// Connections accepted, whether or not a whole request came on them.
    var connections: Int { lock.withLock { accepted } }
    /// Body bytes written by `.endless`.
    var bytesSent: Int { lock.withLock { sent } }

    func stop() {
        let fds: [Int32] = lock.withLock {
            if stopped { return [] }
            stopped = true
            return open
        }
        shutdown(fd, SHUT_RDWR)
        close(fd)
        for c in fds { shutdown(c, SHUT_RDWR) }
    }

    private var isStopped: Bool { lock.withLock { stopped } }

    private func acceptLoop() {
        while true {
            let c = accept(fd, nil, nil)
            if c < 0 { return }
            var one: Int32 = 1
            setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            let n: Int? = lock.withLock {
                if stopped { return nil }
                accepted += 1
                open.append(c)
                return accepted
            }
            guard n != nil else { close(c); return }
            Thread.detachNewThread { [self] in serve(c) }
        }
    }

    private func serve(_ c: Int32) {
        defer {
            lock.withLock { open.removeAll { $0 == c } }
            close(c)
        }
        guard let call = readRequest(c) else { return }
        let index: Int = lock.withLock { recorded.append(call); return recorded.count - 1 }
        switch answer(index) {
        case .status(let s):
            write(c, "HTTP/1.1 \(s) X\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        case .redirect(let to):
            write(c, "HTTP/1.1 302 Found\r\nLocation: \(to)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        case .hang:
            var b = [UInt8](repeating: 0, count: 1024)
            while !isStopped, read(c, &b, b.count) > 0 {}
        case .endless:
            write(c, "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\n")
            let chunk = [UInt8](repeating: 0x78, count: 65536)
            while !isStopped && bytesSent < 64 << 20 {
                let n = chunk.withUnsafeBytes { Darwin.write(c, $0.baseAddress!, $0.count) }
                if n <= 0 { break }
                lock.withLock { sent += n }
            }
        }
    }

    private func write(_ c: Int32, _ s: String) { _ = s.withCString { Darwin.write(c, $0, strlen($0)) } }

    private func readRequest(_ c: Int32) -> Call? {
        var got = [UInt8](), buf = [UInt8](repeating: 0, count: 65536)
        var headEnd = -1
        while headEnd < 0 {
            let n = read(c, &buf, buf.count)
            if n <= 0 { return nil }
            got += buf[0..<n]
            if let r = find(got, [13, 10, 13, 10]) { headEnd = r }
        }
        let head = String(decoding: got[0..<headEnd], as: UTF8.self).components(separatedBy: "\r\n")
        let path = head.first?.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        var headers: [String: String] = [:]
        for l in head.dropFirst() {
            guard let i = l.firstIndex(of: ":") else { continue }
            headers[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces)
        }
        let want = Int(headers["content-length"] ?? "0") ?? 0
        var body = Array(got[(headEnd + 4)...])
        while body.count < want {
            let n = read(c, &buf, buf.count)
            if n <= 0 { break }
            body += buf[0..<n]
        }
        return Call(path: path, headers: headers, body: body, at: Date())
    }

    private func find(_ hay: [UInt8], _ needle: [UInt8]) -> Int? {
        guard hay.count >= needle.count else { return nil }
        for i in 0...(hay.count - needle.count) where Array(hay[i..<(i + needle.count)]) == needle { return i }
        return nil
    }
}

/// A port nothing listens on: bound, then closed.
func chatTestClosedPort() -> Int {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    defer { close(fd) }
    var a = sockaddr_in()
    a.sin_family = sa_family_t(AF_INET)
    a.sin_addr.s_addr = inet_addr("127.0.0.1")
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, len) } }
    _ = withUnsafeMutablePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
    return Int(UInt16(bigEndian: a.sin_port))
}
