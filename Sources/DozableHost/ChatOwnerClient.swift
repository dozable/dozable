import Darwin
import Foundation

/// The person's own way into the chat server: HTTP on its owner's socket (`<store>/chat/chat.sock`), where the server
/// treats the caller as the human with no token. Darwin sockets, one request per connection (HTTP/1.0: the answer ends
/// when the server closes), at most 8 MiB read unless the call says otherwise. `stream` follows `/api/stream`, one `data:`
/// line at a time, and can be cancelled from another thread (`StreamHandle`). Used by the `doz chat` commands and the
/// dashboard's chat routes (`DozableWeb/WebChat.swift`).
public struct ChatOwnerClient: Sendable {
    public let socket: String
    public static let maximumAnswer = 8 << 20

    public init(socket: String) { self.socket = socket }
    public init(paths: ChatPaths) { socket = paths.socket }

    public struct Answer: Sendable {
        public var status: Int
        public var body: Data
        /// The answer's headers, names lower-cased, in order.
        public var headers: [(String, String)] = []
        public var text: String { String(decoding: body, as: UTF8.self) }
        public func header(_ name: String) -> String? { headers.first { $0.0 == name.lowercased() }?.1 }
    }

    public enum Failure: Error, Equatable {
        /// Nothing listens there (chat is off, or the server is not up yet).
        case notListening
        case failed(String)
    }

    /// A stream's way out from another thread: `cancel()` shuts the connection down (both ways), so a blocked read ends
    /// and the server sees the close at once. Safe before the connection exists (it is then shut as soon as it does).
    public final class StreamHandle: @unchecked Sendable {
        private let lock = NSLock()
        private var fd: Int32 = -1
        private var cancelled = false
        public init() {}
        public var isCancelled: Bool { lock.withLock { cancelled } }
        public func cancel() {
            lock.withLock {
                cancelled = true
                if fd >= 0 { _ = Darwin.shutdown(fd, SHUT_RDWR) }
            }
        }
        /// false: cancelled already (the caller closes `fd` and stops).
        func adopt(_ f: Int32) -> Bool {
            lock.withLock {
                guard !cancelled else { return false }
                fd = f
                return true
            }
        }
        func release() { lock.withLock { fd = -1 } }
    }

    /// One request, its whole answer. `headers`: extra request headers (the caller vouches for their names and values —
    /// no CR or LF). `maximum`: the most bytes of the answer read (more is a failure).
    /// `contentType`: the body's type (JSON unless said — an attachment's upload is `application/octet-stream`).
    public func request(_ method: String, _ target: String, json body: Data? = nil, headers: [(String, String)] = [],
                        contentType: String = "application/json",
                        timeout: Double = 20, maximum: Int = ChatOwnerClient.maximumAnswer) throws -> Answer {
        let fd = try connect(timeout: timeout)
        defer { close(fd) }
        try send(fd, head(method, target, body: body, headers: headers, contentType: contentType))
        var buf = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        let cap = maximum + 16384                              // the head's room besides the body
        while buf.count <= cap {
            let n = read(fd, &chunk, chunk.count)
            if n < 0 && errno == EINTR { continue }
            if n < 0 { throw Failure.failed("the chat server did not answer in time") }
            if n == 0 { break }
            buf.append(contentsOf: chunk[0..<n])
        }
        guard buf.count <= cap else { throw Failure.failed("the chat server's answer is larger than \(maximum >> 20) MiB") }
        guard let end = buf.range(of: Data("\r\n\r\n".utf8)) else { throw Failure.failed("the chat server's answer could not be read") }
        let headText = String(decoding: buf[buf.startIndex..<end.lowerBound], as: UTF8.self)
        let lines = headText.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ", maxSplits: 2)
        guard parts.count >= 2, let status = Int(parts[1]) else { throw Failure.failed("the chat server's answer could not be read") }
        var hs: [(String, String)] = []
        for l in lines.dropFirst() {
            guard let c = l.firstIndex(of: ":") else { continue }
            hs.append((l[..<c].trimmingCharacters(in: .whitespaces).lowercased(), l[l.index(after: c)...].trimmingCharacters(in: .whitespaces)))
        }
        return Answer(status: status, body: Data(buf[end.upperBound...]), headers: hs)
    }

    /// Follows `target` (the live stream): each `data:` line's JSON is handed to `onData`, until it returns false, the
    /// server ends the stream, the connection closes, `handle` is cancelled, or a line grows past `maximumLine` bytes.
    public func stream(_ target: String, handle: StreamHandle? = nil, maximumLine: Int = ChatOwnerClient.maximumAnswer,
                       onData: (String) -> Bool) throws {
        let fd = try connect(timeout: 0)
        if let handle, !handle.adopt(fd) { close(fd); return }
        defer { handle?.release(); close(fd) }
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
                guard let end = pending.range(of: Data("\r\n\r\n".utf8)) else {
                    if pending.count > 65536 { return }
                    continue
                }
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
            if pending.count > maximumLine { return }
        }
    }

    private func head(_ method: String, _ target: String, body: Data?, headers: [(String, String)] = [],
                      contentType: String = "application/json") -> Data {
        var h = "\(method) \(target) HTTP/1.0\r\nHost: chat\r\n"
        for (k, v) in headers where !(k + v).contains(where: { $0 == "\r" || $0 == "\n" }) { h += "\(k): \(v)\r\n" }
        if let body { h += "Content-Type: \(contentType)\r\nContent-Length: \(body.count)\r\n" }
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
