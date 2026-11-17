import Darwin
import Foundation

/// The person's own way into the chat server: HTTP on its owner's socket (`<store>/chat/chat.sock`), where the server
/// treats the caller as the human with no token. Darwin sockets, one request per connection (HTTP/1.0: the answer ends
/// when the server closes), at most 8 MiB read. `stream` follows `/api/stream`, one `data:` line at a time.
public struct ChatOwnerClient: Sendable {
    public let socket: String
    public static let maximumAnswer = 8 << 20

    public init(socket: String) { self.socket = socket }
    public init(paths: ChatPaths) { socket = paths.socket }

    public struct Answer: Sendable {
        public var status: Int
        public var body: Data
        public var text: String { String(decoding: body, as: UTF8.self) }
    }

    public enum Failure: Error, Equatable {
        /// Nothing listens there (chat is off, or the server is not up yet).
        case notListening
        case failed(String)
    }

    /// One request, its whole answer.
    public func request(_ method: String, _ target: String, json body: Data? = nil, timeout: Double = 20) throws -> Answer {
        let fd = try connect(timeout: timeout)
        defer { close(fd) }
        try send(fd, head(method, target, body: body))
        var buf = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while buf.count <= Self.maximumAnswer {
            let n = read(fd, &chunk, chunk.count)
            if n < 0 && errno == EINTR { continue }
            if n < 0 { throw Failure.failed("the chat server did not answer in time") }
            if n == 0 { break }
            buf.append(contentsOf: chunk[0..<n])
        }
        guard buf.count <= Self.maximumAnswer else { throw Failure.failed("the chat server's answer is larger than 8 MiB") }
        guard let end = buf.range(of: Data("\r\n\r\n".utf8)) else { throw Failure.failed("the chat server's answer could not be read") }
        let headText = String(decoding: buf[buf.startIndex..<end.lowerBound], as: UTF8.self)
        let parts = headText.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2, let status = Int(parts[1]) else { throw Failure.failed("the chat server's answer could not be read") }
        return Answer(status: status, body: buf[end.upperBound...])
    }

    /// Follows `target` (the live stream): each `data:` line's JSON is handed to `onData`, until it returns false, the
    /// server ends the stream, or the connection closes.
    public func stream(_ target: String, onData: (String) -> Bool) throws {
        let fd = try connect(timeout: 0)
        defer { close(fd) }
        try send(fd, head("GET", target, body: nil))
        var pending = Data()
        var inBody = false
        var chunk = [UInt8](repeating: 0, count: 16384)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return }
            pending.append(contentsOf: chunk[0..<n])
            if !inBody {
                guard let end = pending.range(of: Data("\r\n\r\n".utf8)) else { continue }
                let head = String(decoding: pending[pending.startIndex..<end.lowerBound], as: UTF8.self)
                guard head.split(separator: " ", maxSplits: 2).dropFirst().first == "200" else { throw Failure.failed("the chat server refused the stream") }
                pending = Data(pending[end.upperBound...])
                inBody = true
            }
            while let nl = pending.firstIndex(of: 0x0A) {
                let line = String(decoding: pending[pending.startIndex..<nl], as: UTF8.self)
                pending = Data(pending[pending.index(after: nl)...])
                if line.hasPrefix("data: "), !onData(String(line.dropFirst(6))) { return }
            }
            if pending.count > Self.maximumAnswer { return }
        }
    }

    private func head(_ method: String, _ target: String, body: Data?) -> Data {
        var h = "\(method) \(target) HTTP/1.0\r\nHost: chat\r\n"
        if let body { h += "Content-Type: application/json\r\nContent-Length: \(body.count)\r\n" }
        return Data((h + "\r\n").utf8) + (body ?? Data())
    }

    private func send(_ fd: Int32, _ d: Data) throws {
        try d.withUnsafeBytes { (b: UnsafeRawBufferPointer) in
            var at = 0
            while at < b.count {
                let n = write(fd, b.baseAddress! + at, b.count - at)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw Failure.failed("the chat server closed the connection") }
                at += n
            }
        }
    }

    private func connect(timeout: Double) throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.failed("socket: \(String(cString: strerror(errno)))") }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var nosig: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosig, socklen_t(MemoryLayout<Int32>.size))
        if timeout > 0 {
            var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socket.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { close(fd); throw Failure.failed("the socket's path is too long") }
        withUnsafeMutableBytes(of: &addr.sun_path) { p in for (i, c) in bytes.enumerated() { p[i] = c }; p[bytes.count] = 0 }
        let r = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard r == 0 else {
            let e = errno
            close(fd)
            if e == ENOENT || e == ECONNREFUSED { throw Failure.notListening }
            throw Failure.failed("cannot reach the chat server: \(String(cString: strerror(e)))")
        }
        return fd
    }
}
