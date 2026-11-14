import Darwin
import Foundation

/// `doz fence-connect HOST PORT` — git's and ssh's way out of a FENCED session on this Mac (its `GIT_SSH_COMMAND` and its
/// `ssh` shim give it as ssh's `ProxyCommand`): one CONNECT through the session's own proxy — `$HTTPS_PROXY`
/// (`http://doz:PASSWORD@127.0.0.1:PORT`, the only connection its fence allows; DNS is closed inside, so the proxy resolves
/// and judges the host by its permissions) — then stdin and stdout relayed both ways. It runs before anything else of doz
/// (no settings, no store, no host, no recipes): `DozableEntry.main` hands it over first.
public enum FenceConnect {
    public struct Proxy: Equatable, Sendable {
        public var port: UInt16
        public var user: String
        public var password: String
    }

    /// The session's proxy from its variables: only `http://USER:PASSWORD@127.0.0.1:PORT` (what a fenced session is given)
    /// — nil for anything else (never another host: the fence would refuse it anyway).
    public static func proxy(from env: [String: String]) -> Proxy? {
        for k in ["HTTPS_PROXY", "https_proxy", "ALL_PROXY", "all_proxy", "HTTP_PROXY", "http_proxy"] {
            guard let v = env[k], let u = URLComponents(string: v), u.scheme == "http", u.host == "127.0.0.1",
                  let port = u.port, (1...65535).contains(port) else { continue }
            return Proxy(port: UInt16(port), user: u.user?.removingPercentEncoding ?? "", password: u.password?.removingPercentEncoding ?? "")
        }
        return nil
    }

    /// Why `host`/`port` cannot be asked for (nil: they can) — a name or address without spaces or control characters.
    public static func targetProblem(host: String, port: String) -> String? {
        guard !host.isEmpty, host.utf8.count <= 253,
              !host.unicodeScalars.contains(where: { $0.value <= 0x20 || $0.value == 0x7F || "/@?#\\\"".unicodeScalars.contains($0) }) else {
            return "a host name, e.g. github.com"
        }
        guard let p = Int(port), (1...65535).contains(p) else { return "a port from 1 to 65535" }
        return nil
    }

    /// The CONNECT request.
    public static func request(host: String, port: String, proxy: Proxy) -> String {
        let target = host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
        let auth = Data("\(proxy.user):\(proxy.password)".utf8).base64EncodedString()
        return "CONNECT \(target) HTTP/1.1\r\nHost: \(target)\r\nProxy-Authorization: Basic \(auth)\r\nUser-Agent: doz-fence-connect\r\n\r\n"
    }

    /// What a refusal says: the proxy's own text (its first lines), never more than a few hundred bytes.
    static func refusal(_ reply: [UInt8]) -> String {
        let text = String(decoding: reply.prefix(4096), as: UTF8.self)
        let status = text.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? "no answer"
        var body = ""
        if let r = text.range(of: "\r\n\r\n") { body = String(text[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines) }
        let why = body.split(separator: "\n").first.map(String.init) ?? status
        return String(why.prefix(400))
    }

    public static func run(_ args: [String], environment env: [String: String]) -> Int32 {
        func fail(_ s: String, _ code: Int32 = 1) -> Int32 {
            FileHandle.standardError.write(Data("doz fence-connect: \(s)\n".utf8))
            return code
        }
        guard args.count == 2 else { return fail("usage: doz fence-connect HOST PORT (ssh's ProxyCommand inside a fenced session on this Mac)", 64) }
        if let p = targetProblem(host: args[0], port: args[1]) { return fail("\(args[0]):\(args[1]) — \(p)", 64) }
        guard let proxy = proxy(from: env) else {
            return fail("no proxy — this runs inside a fenced session on this Mac (doz run @mac --fenced), where HTTPS_PROXY names its proxy")
        }
        signal(SIGPIPE, SIG_IGN)
        let s = socket(AF_INET, SOCK_STREAM, 0)
        guard s >= 0 else { return fail("socket: \(String(cString: strerror(errno)))") }
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = proxy.port.bigEndian
        a.sin_addr.s_addr = inet_addr("127.0.0.1")
        let ok = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } == 0
        guard ok else { return fail("this session's proxy (127.0.0.1:\(proxy.port)) did not answer: \(String(cString: strerror(errno)))") }
        guard writeAll(s, Array(request(host: args[0], port: args[1], proxy: proxy).utf8)) else { return fail("the proxy closed the connection") }
        // Its answer's head (and whatever came after it, which is the far end's first bytes).
        var got: [UInt8] = []
        var buf = [UInt8](repeating: 0, count: 16384)
        var tv = timeval(tv_sec: 60, tv_usec: 0)
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var end: Int?
        while end == nil {
            let n = buf.withUnsafeMutableBytes { read(s, $0.baseAddress, $0.count) }
            if n <= 0 { break }
            got += buf[0..<n]
            end = headEnd(got)
            if got.count > 64 << 10 { break }
        }
        guard let e = end else { return fail("\(args[0]):\(args[1]) — the proxy gave no answer") }
        let status = String(decoding: got.prefix(e), as: UTF8.self).split(separator: " ").dropFirst().first.map(String.init) ?? ""
        guard status == "200" else {
            // The rest of a refusal (its body) for the reason.
            while got.count < 8192 {
                let n = buf.withUnsafeMutableBytes { read(s, $0.baseAddress, $0.count) }
                if n <= 0 { break }
                got += buf[0..<n]
            }
            close(s)
            return fail("\(args[0]):\(args[1]) refused by this session's proxy — \(refusal(got))")
        }
        tv = timeval(tv_sec: 0, tv_usec: 0)
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let rest = Array(got[(e + 4)...])
        if !rest.isEmpty, !writeAll(STDOUT_FILENO, rest) { return 0 }
        relay(s)
        close(s)
        return 0
    }

    static func headEnd(_ a: [UInt8]) -> Int? {
        guard a.count >= 4 else { return nil }
        for i in 0...(a.count - 4) where a[i] == 13 && a[i + 1] == 10 && a[i + 2] == 13 && a[i + 3] == 10 { return i }
        return nil
    }

    static func writeAll(_ fd: Int32, _ b: [UInt8]) -> Bool {
        var off = 0
        while off < b.count {
            let n = b[off...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if n < 0, errno == EINTR { continue }
            if n <= 0 { return false }
            off += n
        }
        return true
    }

    /// stdin → the tunnel, the tunnel → stdout, until the far end closes (stdin's end half-closes the tunnel).
    static func relay(_ s: Int32) {
        var buf = [UInt8](repeating: 0, count: 65536)
        var inOpen = true
        while true {
            var p = [pollfd(fd: inOpen ? STDIN_FILENO : -1, events: Int16(POLLIN), revents: 0), pollfd(fd: s, events: Int16(POLLIN), revents: 0)]
            if poll(&p, 2, -1) < 0 { if errno == EINTR { continue }; return }
            if inOpen, p[0].revents != 0 {
                let n = buf.withUnsafeMutableBytes { read(STDIN_FILENO, $0.baseAddress, $0.count) }
                if n <= 0 { inOpen = false; shutdown(s, SHUT_WR) } else if !writeAll(s, Array(buf[0..<n])) { return }
            }
            if p[1].revents != 0 {
                let n = buf.withUnsafeMutableBytes { read(s, $0.baseAddress, $0.count) }
                if n <= 0 { return }
                if !writeAll(STDOUT_FILENO, Array(buf[0..<n])) { return }
            }
        }
    }
}
