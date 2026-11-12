import Darwin
import Foundation

/// A deckhold holder reached DIRECTLY on its unix socket — no `deckhold pipe` in between. The frame protocol is the
/// same one a guest session speaks over `deckhold pipe` (`DeckholdProtocol.swift`), and the answers are the same:
/// a socket that is gone answers like the pipe does — EXIT with the code its `NAME.exit` file kept, else NOSESSION.
///
/// The library knows nothing here of whose holder this is: it is a transport (`attach`, `watchStatus`) and the
/// one-shot requests (`query`, `dump`, `send`, `capture`, `list`). One reader thread per connection; a connection
/// never writes or delivers after it closed, and its descriptor is closed ONCE, by its reader, after the writer
/// has let go of it (identity is the object, never the descriptor number).
public enum DeckholdSocket {
    /// `NAME.sock` → `NAME.exit` (written by the holder when its program exits).
    public static func exitFile(forSocket path: String) -> String {
        path.hasSuffix(".sock") ? String(path.dropLast(5)) + ".exit" : path + ".exit"
    }

    /// The exit code an ended session left (`NAME.exit`), or nil.
    public static func recordedExit(socket path: String) -> Int32? {
        guard let s = try? String(contentsOfFile: exitFile(forSocket: path), encoding: .utf8) else { return nil }
        return Int32(s.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Connect to the socket at `path`: a descriptor, or nil (nothing listens there — gone, or stale).
    public static func dial(_ path: String) -> Int32? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let cap = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < cap else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: Array(path.utf8))
            raw[path.utf8.count] = 0
        }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if ok != 0 { close(fd); return nil }
        return fd
    }

    /// What a socket that is not there answers (as `deckhold pipe` does): the recorded EXIT, else NOSESSION.
    static func goneFrame(_ path: String) -> Data {
        if let code = recordedExit(socket: path) { return DeckholdFrame.exit(code).encoded }
        return DeckholdFrame.noSession.encoded
    }

    // MARK: connections

    /// A viewer of the session at `path`, at `size` (0×0: keep the session's size). See `SessionConnection`.
    public static func attach(path: String, size: TermSize) -> SessionConnection {
        let name = sessionName(path)
        return open(path, SessionConnection(session: name, size: size))
    }

    /// A status watcher (WATCH): `.status` now and at each change, then the final `ended`/`detached`.
    public static func watchStatus(path: String) -> SessionConnection {
        open(path, SessionConnection(statusOf: sessionName(path)))
    }

    static func sessionName(_ path: String) -> String {
        let base = (path as NSString).lastPathComponent
        return base.hasSuffix(".sock") ? String(base.dropLast(5)) : base
    }

    private static func open(_ path: String, _ conn: SessionConnection) -> SessionConnection {
        guard let fd = dial(path) else {
            conn.receive(goneFrame(path))
            if !conn.isClosed { conn.detach(.transportLost) }
            return conn
        }
        let t = Transport(fd: fd)
        // Client → holder: the connection's frames (HELLO/WATCH first), until it closes; then let the reader go.
        Task.detached {
            for await d in conn.input { if !t.write(d) { break } }
            t.shutdown()
        }
        // Holder → client: on its own thread; at the end the transport is lost (an EXIT already ended it).
        Thread.detachNewThread {
            var buf = [UInt8](repeating: 0, count: 65_536)
            while true {
                let n = t.read(&buf)
                if n <= 0 { break }
                conn.receive(Data(buf[0..<n]))
            }
            conn.detach(.transportLost)
            t.close()
        }
        return conn
    }

    /// One socket, shared by a writer and a reader: writes stop once it is shut down or closed, and only the reader
    /// closes it — after the writer can no longer touch the number.
    final class Transport: @unchecked Sendable {
        private let lock = NSLock()
        private var fd: Int32
        private var down = false
        init(fd: Int32) { self.fd = fd }

        func write(_ d: Data) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !down, fd >= 0 else { return false }
            return d.withUnsafeBytes { raw -> Bool in
                var at = 0
                while at < raw.count {
                    let n = Darwin.write(fd, raw.baseAddress! + at, raw.count - at)
                    if n < 0 { if errno == EINTR { continue }; return false }
                    at += n
                }
                return true
            }
        }

        func read(_ buf: inout [UInt8]) -> Int {
            lock.lock(); let f = fd; lock.unlock()
            guard f >= 0 else { return 0 }
            while true {
                let n = buf.withUnsafeMutableBytes { Darwin.read(f, $0.baseAddress, $0.count) }
                if n < 0 && errno == EINTR { continue }
                return n
            }
        }

        func shutdown() {
            lock.lock(); defer { lock.unlock() }
            guard !down, fd >= 0 else { return }
            down = true
            Darwin.shutdown(fd, SHUT_RDWR)
        }

        func close() {
            lock.lock(); defer { lock.unlock() }
            down = true
            if fd >= 0 { Darwin.close(fd); fd = -1 }
        }
    }

    // MARK: one-shot requests

    /// Write `request` on a new connection and read until `done` says the answer is complete, the holder closes, or
    /// `timeout` passes. nil: nothing listens there. Runs off the caller's thread.
    static func exchange(_ path: String, _ request: Data, timeout: Duration,
                         done: @escaping @Sendable (Data) -> Bool) async -> Data? {
        await withCheckedContinuation { (c: CheckedContinuation<Data?, Never>) in
            Thread.detachNewThread {
                guard let fd = dial(path) else { c.resume(returning: nil); return }
                defer { Darwin.close(fd) }
                let t = Transport(fd: fd)
                guard t.write(request) else { c.resume(returning: Data()); return }
                let ms = Int(timeout.components.seconds) * 1000 + Int(timeout.components.attoseconds / 1_000_000_000_000_000)
                let deadline = Date().addingTimeInterval(Double(ms) / 1000)
                var got = Data()
                var buf = [UInt8](repeating: 0, count: 65_536)
                while !done(got) {
                    let left = Int32(max(0, deadline.timeIntervalSinceNow * 1000))
                    if left <= 0 { break }
                    var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                    let r = poll(&p, 1, left)
                    if r < 0 { if errno == EINTR { continue }; break }
                    if r == 0 { break }
                    let n = buf.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
                    if n < 0 && errno == EINTR { continue }
                    if n <= 0 { break }
                    got.append(contentsOf: buf[0..<n])
                }
                c.resume(returning: got)
            }
        }
    }

    /// The answer of a holder to QUERY.
    public enum Answer: Equatable, Sendable {
        /// The INFO line (as `deckhold ls` prints it).
        case info(String)
        /// It has ended: the code its `NAME.exit` kept (nil: none was kept).
        case ended(Int32?)
        /// No socket and no exit record: there is no such session.
        case noSession
        /// A socket is there, but nothing answered (a stale socket, or a holder that did not answer in time).
        case stale
    }

    /// QUERY: the holder's INFO line.
    public static func query(path: String, timeout: Duration = .seconds(3)) async -> Answer {
        guard let got = await exchange(path, DeckholdFrame.queryRequest, timeout: timeout, done: { firstInfo($0) != nil }) else {
            if let code = recordedExit(socket: path) { return .ended(code) }
            return FileManager.default.fileExists(atPath: path) ? .stale : .noSession
        }
        return firstInfo(got).map(Answer.info) ?? .stale
    }

    /// DUMP: the holder's active screen as text plus its `cursor=… size=… screen=…` line. nil: no answer.
    public static func dump(path: String, timeout: Duration = .seconds(3)) async -> String? {
        guard let got = await exchange(path, DeckholdFrame.dumpRequest, timeout: timeout, done: { firstInfo($0) != nil }) else { return nil }
        return firstInfo(got)
    }

    /// The screen now (`dump`, parsed) — nil when there is no such session or it did not answer.
    public static func liveScreen(path: String, timeout: Duration = .seconds(3)) async -> LiveScreen? {
        await dump(path: path, timeout: timeout).flatMap(LiveScreen.parse)
    }

    /// Type `bytes` into the session (DATA frames, then QUERY) — answered once its INFO arrived: every byte is in the
    /// program's input buffer (`SessionInput`). A socket that is not there answers as the pipe does.
    public static func send(path: String, bytes: Data, timeout: Duration = .seconds(15)) async throws -> SessionInput.Receipt {
        guard bytes.count <= SessionInput.maximumBytes else { throw SandboxError.invalidSpec("at most \(SessionInput.maximumBytes) bytes in one send") }
        guard let got = await exchange(path, SessionInput.frames(bytes), timeout: timeout, done: { SessionInput.receipt($0) != nil }) else {
            return SessionInput.receipt(goneFrame(path)) ?? .noSession
        }
        guard let r = SessionInput.receipt(got) else {
            throw SandboxError.commandFailed(command: "send to session \(sessionName(path))", exitCode: 124,
                                             output: "the session did not answer within \(timeout.components.seconds) s")
        }
        return r
    }

    /// A momentary attach that disturbs nothing — HELLO 0×0, (GRID 0,) DUMP — for a saved screen.
    public struct Capture: Sendable {
        public var snapshot: Data
        public var dump: String
        public var grid: ScreenGrid?
    }

    /// nil: no such session, it ended, or no answer in time.
    public static func capture(path: String, grid: Bool, timeout: Duration = .seconds(3)) async -> Capture? {
        let request = (grid ? DeckholdFrame.captureWithGridRequest : DeckholdFrame.hello(TermSize(cols: 0, rows: 0)).encoded)
            + DeckholdFrame.dumpRequest
        guard let got = await exchange(path, request, timeout: timeout, done: { d in
            var dec = DeckholdFrameDecoder()
            return ((try? dec.feed(d)) ?? []).contains { if case .info = $0 { return true }; if case .exit = $0 { return true }; return false }
        }) else { return nil }
        var dec = DeckholdFrameDecoder()
        var snapshot: Data?, dump: String?, g: ScreenGrid?
        for f in (try? dec.feed(got)) ?? [] {
            switch f {
            case .snapshot(let d): if snapshot == nil { snapshot = d }
            case .info(let s): dump = s
            case .grid(let d): if g == nil, case .grid(let s)? = try? ScreenGrid.decode(d) { g = s }
            default: break
            }
        }
        guard let snapshot, let dump else { return nil }
        return Capture(snapshot: snapshot, dump: dump, grid: g)
    }

    /// Every session in `directory` as `deckhold ls` lists them: live ones by their INFO line, ended ones (a `.exit`
    /// with no socket) as ended; `stale` names a socket nothing answers.
    public struct Listing: Sendable {
        public var sessions: [SessionInfo]
        public var stale: [String]
    }

    public static func list(directory: String, timeout: Duration = .seconds(3)) async -> Listing {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        var lines: [String] = []
        var stale: [String] = []
        for n in names.sorted() {
            if n.hasSuffix(".exit") {
                let base = String(n.dropLast(5))
                let sock = directory + "/" + base + ".sock"
                if !FileManager.default.fileExists(atPath: sock), let code = recordedExit(socket: sock) { lines.append("\(base)\tended=\(code)") }
                continue
            }
            guard n.hasSuffix(".sock"), n.count > 5 else { continue }
            switch await query(path: directory + "/" + n, timeout: timeout) {
            case .info(let line): lines.append(line)
            case .stale, .noSession, .ended: stale.append(String(n.dropLast(5)))
            }
        }
        return Listing(sessions: SessionInfo.parseList(lines.joined(separator: "\n")), stale: stale)
    }

    /// The first INFO frame's text in `data` (nil while incomplete).
    static func firstInfo(_ data: Data) -> String? {
        var i = data.startIndex
        while data.endIndex - i >= 5 {
            let n = Int(data[i + 1]) << 24 | Int(data[i + 2]) << 16 | Int(data[i + 3]) << 8 | Int(data[i + 4])
            guard data.endIndex - (i + 5) >= n else { return nil }
            if data[i] == UInt8(ascii: "I") { return String(decoding: data[(i + 5)..<(i + 5 + n)], as: UTF8.self) }
            i += 5 + n
        }
        return nil
    }
}
