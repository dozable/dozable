import Darwin
import XCTest
@testable import DozableKit

/// `DeckholdSocket`: the frame protocol straight on a holder's unix socket — against a FAKE holder listening in a
/// scratch folder (each test scripts what it answers). No deckhold, no VM.
final class DeckholdSocketTests: XCTestCase {
    private var dir: String!

    override func setUp() {
        // A short folder: a socket path must fit sun_path (104 bytes).
        dir = "/tmp/dhs-\(getpid())-\(UInt32.random(in: 0...UInt32.max))"
        mkdir(dir, 0o700)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: dir)
    }

    /// One client of the fake holder: read frames, write bytes.
    final class Peer: @unchecked Sendable {
        let fd: Int32
        private var buffer = Data()
        init(fd: Int32) { self.fd = fd }
        func frame() -> (UInt8, Data)? {
            while true {
                if buffer.count >= 5 {
                    let b = [UInt8](buffer.prefix(5))
                    let n = Int(b[1]) << 24 | Int(b[2]) << 16 | Int(b[3]) << 8 | Int(b[4])
                    if buffer.count >= 5 + n {
                        let p = buffer.subdata(in: (buffer.startIndex + 5)..<(buffer.startIndex + 5 + n))
                        buffer = Data(buffer.dropFirst(5 + n))
                        return (b[0], p)
                    }
                }
                var buf = [UInt8](repeating: 0, count: 4096)
                let n = Darwin.read(fd, &buf, buf.count)
                if n <= 0 { return nil }
                buffer.append(contentsOf: buf[0..<n])
            }
        }
        func send(_ d: Data) { d.withUnsafeBytes { _ = Darwin.write(fd, $0.baseAddress, $0.count) } }
        func close() { Darwin.close(fd) }
    }

    /// A listener at `dir/NAME.sock` whose every client is handed to `handle` on its own thread.
    final class FakeHolder: @unchecked Sendable {
        let path: String
        let lfd: Int32
        init(_ path: String, handle: @escaping @Sendable (Peer) -> Void) {
            self.path = path
            lfd = socket(AF_UNIX, SOCK_STREAM, 0)
            var a = sockaddr_un()
            a.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &a.sun_path) { r in r.copyBytes(from: Array(path.utf8)); r[path.utf8.count] = 0 }
            _ = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(lfd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            Darwin.listen(lfd, 8)
            let l = lfd
            Thread.detachNewThread {
                while true {
                    let c = Darwin.accept(l, nil, nil)
                    if c < 0 { return }
                    Thread.detachNewThread { handle(Peer(fd: c)) }
                }
            }
        }
        func stop() { Darwin.shutdown(lfd, SHUT_RDWR); Darwin.close(lfd) }
    }

    private func path(_ name: String) -> String { dir + "/" + name + ".sock" }

    private func drain(_ c: SessionConnection) async -> [SessionOutput] {
        var out: [SessionOutput] = []
        for await o in c.output { out.append(o) }
        return out
    }

    func test_attach_helloThenSnapshotDataExit() async {
        let hello = SocketBox<Data>()
        let h = FakeHolder(path("s1")) { p in
            guard let (t, d) = p.frame(), t == UInt8(ascii: "H") else { p.close(); return }
            hello.set(d)
            p.send(DeckholdFrame.snapshot(Data("screen".utf8)).encoded)
            p.send(DeckholdFrame.output(Data("x".utf8)).encoded)
            p.send(DeckholdFrame.exit(3).encoded)
            p.close()
        }
        defer { h.stop() }
        let c = DeckholdSocket.attach(path: path("s1"), size: TermSize(cols: 100, rows: 30))
        XCTAssertEqual(c.session, "s1")
        let out = await drain(c)
        XCTAssertEqual(out, [.snapshot(Data("screen".utf8)), .data(Data("x".utf8)), .ended(exitCode: 3)])
        XCTAssertEqual(hello.get(), Data([0, 100, 0, 30]), "HELLO carries the viewer's size")
    }

    func test_attach_keysReachTheHolder_andCloseHangsUp() async {
        let seen = SocketBox<[UInt8]>()
        let hungUp = expectation(description: "the holder sees the client go")
        let h = FakeHolder(path("s2")) { p in
            _ = p.frame()                                   // HELLO
            p.send(DeckholdFrame.snapshot(Data()).encoded)
            var types: [UInt8] = []
            while let (t, d) = p.frame() {
                types.append(t)
                if t == UInt8(ascii: "D") { seen.set(Array(d)) }
            }
            seen.set((seen.get() ?? []) + types)
            hungUp.fulfill()
            p.close()
        }
        defer { h.stop() }
        let c = DeckholdSocket.attach(path: path("s2"), size: .standard)
        var it = c.output.makeAsyncIterator()
        _ = await it.next()                                  // the snapshot: connected
        c.send(Data("ab".utf8))
        c.resize(TermSize(cols: 90, rows: 20))
        try? await Task.sleep(for: .milliseconds(100))
        c.close()
        await fulfillment(of: [hungUp], timeout: 5)
        XCTAssertEqual(seen.get(), Array("ab".utf8) + [UInt8(ascii: "D"), UInt8(ascii: "R")])
        XCTAssertEqual(c.finalOutput, .detached(.closedByClient))
    }

    func test_goneSocket_answersLikeThePipe() async throws {
        // Never existed: NOSESSION.
        var out = await drain(DeckholdSocket.attach(path: path("none"), size: .standard))
        XCTAssertEqual(out, [.ended(exitCode: nil)])
        // Ended: the code its .exit kept.
        try "7\n".write(toFile: dir + "/done.exit", atomically: true, encoding: .utf8)
        out = await drain(DeckholdSocket.attach(path: path("done"), size: .standard))
        XCTAssertEqual(out, [.ended(exitCode: 7)])
        let q = await DeckholdSocket.query(path: path("done"))
        XCTAssertEqual(q, .ended(7))
        let none = await DeckholdSocket.query(path: path("none"))
        XCTAssertEqual(none, .noSession)
        let sent = try await DeckholdSocket.send(path: path("done"), bytes: Data("x".utf8))
        XCTAssertEqual(sent, .ended(7))
        let noSent = try await DeckholdSocket.send(path: path("none"), bytes: Data("x".utf8))
        XCTAssertEqual(noSent, .noSession)
    }

    func test_queryAndDump() async {
        let h = FakeHolder(path("q")) { p in
            guard let (t, _) = p.frame() else { return }
            if t == UInt8(ascii: "Q") { p.send(DeckholdFrame.info("q\tpid=42\tsize=80x24\tclients=0\tscreen=primary\thistory=0\tbytes=5\tgrid=1\tsh").encoded) }
            if t == UInt8(ascii: "P") { p.send(DeckholdFrame.info("hello\nworld\ncursor=3,1 size=80x24 screen=primary").encoded) }
            p.close()
        }
        defer { h.stop() }
        let q = await DeckholdSocket.query(path: path("q"))
        guard case .info(let line) = q else { return XCTFail("\(q)") }
        let info = SessionInfo.parseList(line).first
        XCTAssertEqual(info?.pid, 42)
        XCTAssertEqual(info?.grid, true)
        XCTAssertEqual(info?.command, "sh")
        let s = await DeckholdSocket.liveScreen(path: path("q"))
        XCTAssertEqual(s?.text, "hello\nworld")
        XCTAssertEqual(s?.cursorX, 3)
        XCTAssertEqual(s?.cursorY, 1)
        XCTAssertEqual(s?.cols, 80)
    }

    func test_send_dataThenQuery_answeredByInfo() async throws {
        let got = SocketBox<[UInt8]>()
        let h = FakeHolder(path("in")) { p in
            var bytes: [UInt8] = []
            while let (t, d) = p.frame() {
                if t == UInt8(ascii: "D") { bytes += Array(d) }
                if t == UInt8(ascii: "Q") { got.set(bytes); p.send(DeckholdFrame.info("in\tpid=1\tsh").encoded); break }
            }
            p.close()
        }
        defer { h.stop() }
        let big = Data(repeating: UInt8(ascii: "z"), count: 40_000)    // three DATA frames
        let r = try await DeckholdSocket.send(path: path("in"), bytes: big)
        guard case .delivered = r else { return XCTFail("\(r)") }
        XCTAssertEqual(got.get()?.count, 40_000)
    }

    /// A 236-byte line and its Enter: the CR reaches the holder as a frame of its own, after a settle — never in the burst.
    func test_send_pieces_theEnterArrivesApart() async throws {
        let arrivals = SocketBox<[(Int, Date)]>()
        let h = FakeHolder(path("tui")) { p in
            var seen: [(Int, Date)] = []
            while let (t, d) = p.frame() {
                if t == UInt8(ascii: "D") { seen.append((d.count, Date())) }
                if t == UInt8(ascii: "Q") { arrivals.set(seen); p.send(DeckholdFrame.info("tui\tpid=1\tsh").encoded); break }
            }
            p.close()
        }
        defer { h.stop() }
        let line = String(repeating: "w", count: 236)
        let pieces = try SessionInput.pieces(text: line, keys: [], enter: true, paste: false)
        let r = try await DeckholdSocket.send(path: path("tui"), pieces: pieces)
        guard case .delivered = r else { return XCTFail("\(r)") }
        let a = arrivals.get() ?? []
        XCTAssertEqual(a.map(\.0), [236, 1], "the text, then the CR alone")
        if a.count == 2 { XCTAssertGreaterThanOrEqual(a[1].1.timeIntervalSince(a[0].1), 0.05, "a settle between them") }
    }

    func test_send_noAnswerInTime_throws() async {
        let h = FakeHolder(path("mute")) { p in
            while p.frame() != nil {}                  // reads, never answers
            p.close()
        }
        defer { h.stop() }
        do {
            _ = try await DeckholdSocket.send(path: path("mute"), bytes: Data("x".utf8), timeout: .milliseconds(300))
            XCTFail("a holder that never answers must not count as delivered")
        } catch {}
    }

    func test_watchStatus_andGrid() async {
        let h = FakeHolder(path("w")) { p in
            guard let (t, _) = p.frame(), t == UInt8(ascii: "W") else { p.close(); return }
            p.send(DeckholdFrame.status("grid=1\tstatus=state=working:app=fake\tstatus_age=0").encoded)
            if let (g, _) = p.frame(), g == UInt8(ascii: "G") {
                p.send(Data([UInt8(ascii: "G"), 0, 0, 0, 6, 1, 0, 0, 0, 9, 2]))    // gen 9, "none"
            }
            p.send(DeckholdFrame.exit(0).encoded)
            p.close()
        }
        defer { h.stop() }
        let c = DeckholdSocket.watchStatus(path: path("w"))
        XCTAssertTrue(c.isStatusWatch)
        var it = c.output.makeAsyncIterator()
        guard case .status(let s)? = await it.next() else { return XCTFail("a STATUS first") }
        XCTAssertEqual(s?.state, .working)
        XCTAssertTrue(c.gridCapable)
        let g = await c.requestGrid(gen: 0)
        XCTAssertNotNil(g, "the GRID answer comes back on the watcher")
        var rest: [SessionOutput] = []
        while let o = await it.next() { rest.append(o) }
        XCTAssertEqual(rest, [.ended(exitCode: 0)])
    }

    func test_capture_helloZeroThenDump() async {
        let asked = SocketBox<[UInt8]>()
        let h = FakeHolder(path("cap")) { p in
            var types: [UInt8] = []
            while let (t, d) = p.frame() {
                types.append(t)
                if t == UInt8(ascii: "H") { XCTAssertEqual(d, Data([0, 0, 0, 0])); p.send(DeckholdFrame.snapshot(Data("VT".utf8)).encoded) }
                if t == UInt8(ascii: "P") { p.send(DeckholdFrame.info("text\ncursor=0,0 size=10x2 screen=primary").encoded); break }
            }
            asked.set(types)
            p.close()
        }
        defer { h.stop() }
        let c = await DeckholdSocket.capture(path: path("cap"), grid: false)
        XCTAssertEqual(c?.snapshot, Data("VT".utf8))
        XCTAssertEqual(c?.dump, "text\ncursor=0,0 size=10x2 screen=primary")
        XCTAssertEqual(asked.get(), [UInt8(ascii: "H"), UInt8(ascii: "P")], "nothing typed, nothing resized")
    }

    func test_list_live_ended_stale() async throws {
        let h = FakeHolder(path("live")) { p in
            _ = p.frame()
            p.send(DeckholdFrame.info("live\tpid=5\tsize=80x24\tclients=1\tscreen=primary\thistory=0\tbytes=0\tsh -l").encoded)
            p.close()
        }
        defer { h.stop() }
        try "0\n".write(toFile: dir + "/old.exit", atomically: true, encoding: .utf8)
        // A socket file nothing listens on (its holder was killed).
        let dead = FakeHolder(path("dead")) { $0.close() }
        dead.stop()
        let l = await DeckholdSocket.list(directory: dir)
        XCTAssertEqual(l.sessions.map(\.name), ["live", "old"])
        XCTAssertEqual(l.sessions.first?.pid, 5)
        XCTAssertEqual(l.sessions.last?.exitCode, 0)
        XCTAssertEqual(l.stale, ["dead"])
    }

    func test_exitFileName() {
        XCTAssertEqual(DeckholdSocket.exitFile(forSocket: "/x/a.sock"), "/x/a.exit")
    }
}

/// A value set from another thread.
final class SocketBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var v: T?
    func set(_ x: T) { lock.lock(); v = x; lock.unlock() }
    func get() -> T? { lock.lock(); defer { lock.unlock() }; return v }
}
