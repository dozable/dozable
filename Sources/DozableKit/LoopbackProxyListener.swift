import CryptoKit
import Darwin
import Foundation
import Security

/// A fenced session's proxy port on this Mac's loopback (683): the HTTP proxy (`EgressProxy`) served on a listening TCP
/// socket this listener is GIVEN — it never binds, listens or closes the socket itself: the session's holder owns it for
/// the session's life (`deckhold-mac serve --hold-fd`), so a host that stops leaves connections waiting in its backlog
/// and the next host serves them (`GETFD`). Only the descriptor this listener was given is closed when it stops.
///
/// Each connection: the request head must arrive within `headDeadline` (5 s) — a connection that sends nothing, or a
/// byte at a time, is closed; it must carry `Proxy-Authorization: Basic …` with the session's password (checked in
/// constant time against its SHA-256 — the password itself is never kept here), else `407`; at most `maximum` (256)
/// connections at once — the next one gets `503` at once. The proxy then judges the request exactly as a sandbox's
/// (`serveProxyRequest`: CONNECT or absolute-form HTTP); the `Proxy-Authorization` field never goes upstream.
public final class LoopbackProxyListener: @unchecked Sendable {
    public static let maximumConnections = 256
    public static let headDeadline: Duration = .seconds(5)

    public let proxy: EgressProxy
    public let maximum: Int
    public let deadline: Duration
    /// What the listener says about itself (a refused 257th connection) — the host's log.
    public var onNote: (@Sendable (String) -> Void)?

    private let lock = NSLock()
    private var fd: Int32
    private let secret: [UInt8]
    private var wake: [Int32] = [-1, -1]
    private var accepting = false
    private var acceptThreadDone = true
    private var nextID = 0
    /// Open connections: their descriptor (shut down only while listed — never a recycled number) and whether the proxy
    /// already serves them (false: still reading the head).
    private var conns: [Int: (fd: Int32, busy: Bool)] = [:]

    /// `fd`: this host's descriptor of the session's listening socket. `secretSHA256`: hex of the password's SHA-256.
    public init(fd: Int32, proxy: EgressProxy, secretSHA256: String, maximum: Int = maximumConnections, headDeadline: Duration = headDeadline) {
        self.fd = fd
        self.proxy = proxy
        self.maximum = maximum
        self.deadline = headDeadline
        self.secret = Self.hexBytes(secretSHA256)
    }

    /// The SHA-256 (hex) of a password — what a record keeps.
    public static func sha256(_ password: String) -> String {
        SHA256.hash(data: Data(password.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// A new password: 32 random bytes, URL-safe base64 without padding (it goes in a proxy URL's userinfo as it is).
    public static func newPassword() -> String {
        var b = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, b.count, &b)
        return Data(b).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func hexBytes(_ s: String) -> [UInt8] {
        var out: [UInt8] = []
        var i = s.startIndex
        while i < s.endIndex, let j = s.index(i, offsetBy: 2, limitedBy: s.endIndex) {
            if let b = UInt8(s[i..<j], radix: 16) { out.append(b) }
            i = j
        }
        return out
    }

    /// Open connections now (head readers included).
    public var active: Int { lock.withLock { conns.count } }
    public var isAccepting: Bool { lock.withLock { accepting } }

    /// Accept on the given descriptor, one thread per connection.
    public func start() {
        lock.lock()
        guard !accepting, fd >= 0 else { lock.unlock(); return }
        var p: [Int32] = [-1, -1]
        guard pipe(&p) == 0 else { lock.unlock(); return }
        for x in p { _ = fcntl(x, F_SETFD, FD_CLOEXEC) }
        wake = p
        accepting = true
        acceptThreadDone = false
        let lfd = fd
        lock.unlock()
        _ = fcntl(lfd, F_SETFD, FD_CLOEXEC)
        Thread.detachNewThread { [self] in acceptLoop(lfd, wake: p[0]) }
    }

    private func acceptLoop(_ lfd: Int32, wake w: Int32) {
        defer { lock.withLock { acceptThreadDone = true } }
        while true {
            var p = [pollfd(fd: lfd, events: Int16(POLLIN), revents: 0), pollfd(fd: w, events: Int16(POLLIN), revents: 0)]
            if poll(&p, 2, -1) < 0 { if errno == EINTR { continue }; return }
            if p[1].revents != 0 { return }
            guard p[0].revents != 0 else { continue }
            // Never block in accept: another connection may have gone between poll and accept.
            let fl = fcntl(lfd, F_GETFL)
            _ = fcntl(lfd, F_SETFL, fl | O_NONBLOCK)
            let c = accept(lfd, nil, nil)
            _ = fcntl(lfd, F_SETFL, fl)
            if c < 0 { if errno == EINTR || errno == EAGAIN || errno == ECONNABORTED { continue }; usleep(10_000); continue }
            _ = fcntl(c, F_SETFD, FD_CLOEXEC)
            _ = fcntl(c, F_SETFL, fcntl(c, F_GETFL) & ~O_NONBLOCK)
            var one: Int32 = 1
            setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, 4)
            let id: Int? = lock.withLock {
                guard accepting, conns.count < maximum else { return nil }
                nextID += 1
                conns[nextID] = (c, false)
                return nextID
            }
            guard let id else {
                let full = lock.withLock { accepting }
                if full {
                    onNote?("a fenced session's proxy refused a connection: \(maximum) are open already (the most one session may have)")
                    _ = Wire.writeAll(c, Self.answer(503, "Service Unavailable", "too many connections through this session's proxy (at most \(maximum) at once)"))
                }
                close(c)
                continue
            }
            Thread.detachNewThread { [self] in serve(c, id: id) }
        }
    }

    private func serve(_ c: Int32, id: Int) {
        defer {
            lock.withLock { conns[id] = nil }
            close(c)
        }
        var pending: [UInt8] = []
        guard let head = Wire.readHead(c, into: &pending, deadline: .now + deadline), let h = HTTPHead(head) else { return }
        guard authorized(h) else {
            _ = Wire.writeAll(c, Self.answer(407, "Proxy Authentication Required", "this proxy belongs to one session on this Mac — its password is in that session's proxy variables",
                                             extra: "Proxy-Authenticate: Basic realm=\"doz\"\r\n"))
            return
        }
        let still: Bool = lock.withLock {
            guard conns[id] != nil, accepting else { return false }
            conns[id]?.busy = true
            return true
        }
        guard still else {
            _ = Wire.writeAll(c, Self.answer(503, "Service Unavailable", "this session's proxy is being handed to a new host — try again"))
            return
        }
        proxy.serveProxyRequest(c, head: head, parsed: h, pending: pending)
    }

    /// The request carries the session's password (Basic; any user name), compared in constant time by digest.
    func authorized(_ h: HTTPHead) -> Bool {
        guard secret.count == 32, let v = h.value("proxy-authorization") else { return false }
        let parts = v.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[0].lowercased() == "basic", let d = Data(base64Encoded: parts[1].trimmingCharacters(in: .whitespaces)),
              let colon = d.firstIndex(of: UInt8(ascii: ":")) else { return false }
        let pass = d[d.index(after: colon)...]
        let got = Array(SHA256.hash(data: pass))
        var diff: UInt8 = 0
        for i in 0..<32 { diff |= got[i] ^ secret[i] }
        return diff == 0
    }

    static func answer(_ code: Int, _ reason: String, _ body: String, extra: String = "") -> [UInt8] {
        let b = Array((body + "\n").utf8)
        return Array("HTTP/1.1 \(code) \(reason)\r\nContent-Type: text/plain\r\n\(extra)X-Sandbox-Policy: proxy\r\nConnection: close\r\nContent-Length: \(b.count)\r\n\r\n".utf8) + b
    }

    /// Stop accepting and close THIS host's descriptor (the holder keeps the socket listening; new connections wait in
    /// its backlog). Connections already open go on.
    public func stopAccepting() {
        lock.lock()
        let was = accepting
        accepting = false
        let w = wake
        wake = [-1, -1]
        lock.unlock()
        if was, w[1] >= 0 { var b: UInt8 = 1; _ = write(w[1], &b, 1) }
        // Wait for the accept thread to let go of the descriptor before closing it.
        let until = Date().addingTimeInterval(2)
        while !lock.withLock({ acceptThreadDone }) && Date() < until { usleep(2_000) }
        lock.lock()
        let f = fd
        fd = -1
        lock.unlock()
        if f >= 0 { close(f) }
        for x in w where x >= 0 { close(x) }
    }

    /// A hand-over (or the end): stop accepting, close the connections still waiting for their head at once, let the
    /// ones the proxy serves finish for at most `timeout`, then cut the rest. Returns how many were cut.
    @discardableResult
    public func drain(timeout: Double) -> Int {
        stopAccepting()
        lock.withLock { for (_, c) in conns where !c.busy { Darwin.shutdown(c.fd, SHUT_RDWR) } }
        let until = Date().addingTimeInterval(timeout)
        while active > 0 && Date() < until { usleep(50_000) }
        return lock.withLock {
            let n = conns.count
            for (_, c) in conns { Darwin.shutdown(c.fd, SHUT_RDWR) }
            return n
        }
    }
}
