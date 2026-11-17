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

/// A fake running Claude Code session, entirely the test's own: a session record and a key file in a SCRATCH sessions
/// folder the test hands the server (never the person's `~/.claude`), naming this test process's pid (so it runs) and an
/// inbox socket this object listens on in a short scratch folder it makes under /tmp (never `/tmp/cc-socks`). Every line
/// written to the socket is recorded. `stop()` closes the socket and removes the scratch socket folder.
final class TestClaudeSession: @unchecked Sendable {
    let name: String
    let sessionsDir: String
    let socketDir: String
    var socket: String { socketDir + "/inbox.sock" }
    let token: String
    let record: String
    private let fd: Int32
    private let lock = NSLock()
    private var got: [[String: Any]] = []
    private var stopped = false

    init(name: String, sessionsDir: String, status: String = "idle", token: String = "peer-token-0123456789abcdef") throws {
        let home = NSHomeDirectory()
        precondition(!sessionsDir.hasPrefix(home + "/.claude") && !sessionsDir.hasPrefix("/tmp/cc-socks"), "a test never uses a real sessions folder")
        self.name = name; self.sessionsDir = sessionsDir; self.token = token
        var template = Array("/tmp/dzc-XXXXXX".utf8CString)
        guard let made = mkdtemp(&template) else { throw NSError(domain: "TestClaudeSession", code: Int(errno)) }
        socketDir = String(cString: made)
        record = (sessionsDir as NSString).appendingPathComponent("\(getpid()).json")
        let s = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let p = Array((socketDir + "/inbox.sock").utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in for (i, b) in p.enumerated() { raw[i] = b } }
        let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard ok == 0, listen(s, 16) == 0 else { close(s); throw NSError(domain: "TestClaudeSession", code: Int(errno)) }
        fd = s
        try FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let key = #"{"peerToken":"\#(token)"}"#
        try Data(key.utf8).write(to: URL(fileURLWithPath: (sessionsDir as NSString).appendingPathComponent("\(getpid()).0a1b2c3d.key")))
        setStatus(status)
        Thread.detachNewThread { [self] in acceptLoop() }
    }

    deinit { stop() }

    /// Rewrites the record with a status, stamped now, as Claude Code writes it.
    func setStatus(_ status: String) {
        let ms = Int64(Date().timeIntervalSince1970 * 1000)
        let rec = #"{"pid":\#(getpid()),"name":"\#(name)","messagingSocketPath":"\#(socket)","status":"\#(status)","statusUpdatedAt":\#(ms),"updatedAt":\#(ms),"kind":"interactive","peerProtocol":1}"#
        try? Data(rec.utf8).write(to: URL(fileURLWithPath: record))
    }

    /// Every line written so far, in order (auth lines included).
    var lines: [[String: Any]] { lock.withLock { got } }

    /// The message lines' texts (auth lines skipped).
    var texts: [String] {
        lines.filter { $0["type"] as? String == "user" }.compactMap { (($0["message"] as? [String: Any])?["content"] as? String) }
    }

    /// Waits until at least n message lines came.
    @discardableResult
    func waitTexts(_ n: Int, seconds: Double = 10) -> [String] {
        let deadline = Date().addingTimeInterval(seconds)
        while texts.count < n && Date() < deadline { usleep(10_000) }
        return texts
    }

    func stop() {
        let first: Bool = lock.withLock { defer { stopped = true }; return !stopped }
        guard first else { return }
        shutdown(fd, SHUT_RDWR)
        close(fd)
        try? FileManager.default.removeItem(atPath: socketDir)
    }

    private func acceptLoop() {
        while true {
            let c = accept(fd, nil, nil)
            if c < 0 { return }
            Thread.detachNewThread { [self] in
                defer { close(c) }
                var buf = [UInt8](repeating: 0, count: 65536), pending = [UInt8]()
                while true {
                    let n = read(c, &buf, buf.count)
                    if n <= 0 { break }
                    pending += buf[0..<n]
                    while let i = pending.firstIndex(of: 0x0A) {
                        let line = Array(pending[..<i])
                        pending.removeSubrange(...i)
                        if let v = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] { lock.withLock { got.append(v) } }
                    }
                }
            }
        }
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
