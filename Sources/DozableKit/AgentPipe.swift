import Containerization
import Foundation

// 676: an agent stream — a structured agent program (Claude Code's stream-json, ACP, …) on a real pipe in the guest, no
// terminal: `Sandbox.openAgentStream`. The host relays it over `host.sock` (`agent-stream`, DozableHost/AgentStream.swift).
//
// The rules it keeps:
//   · back-pressure both ways — the program's output is held in a bounded buffer (`AgentOutputBuffer`, 4 MiB shared by
//     stdout and stderr): when it is full the guest's writer BLOCKS on that handle's own queue, the guest pipe fills and the
//     program blocks writing; its input is a bounded queue (`AgentInputQueue`, 1 MiB): the caller's `send` blocks.
//   · a stream is SEVERED, never hung, when its VM is put away (hibernate, shut down, a quit): its reader sees the end at once
//     with the reason (`severed`), while the program may live on in the guest — as an ORPHAN, recorded
//     (`AgentProgramRecord`, persisted with the sandbox) and ended (HUP, TERM, KILL) by the first after-wake step
//     (`LifecycleStep.reapOrphanedAgentPrograms`) before any new stream can open.
//   · the program is found in the guest by a marker in its environment (`markerVariable`): vmexec makes every exec its own
//     session leader, and the guest's pids are its container's (the exec's own pid is the VM's).

/// 676: what is left of an agent stream's program when its pipe was cut — enough to find it again and end it, after a wake
/// or in a new host. `pid`/`starttime` (from `/proc/PID/stat`, field 22) guard against a reused pid; nil when they were not
/// read yet (then the marker finds it).
public struct AgentProgramRecord: Codable, Sendable, Equatable {
    /// The stream's label.
    public var stream: String
    /// The value of `AgentPipe.markerVariable` in the program's environment.
    public var marker: String
    public var pid: Int?
    public var starttime: UInt64?
    /// The program's name (argv[0]) — never its arguments.
    public var argv0: String
    public var openedAt: Date

    public init(stream: String, marker: String, pid: Int? = nil, starttime: UInt64? = nil, argv0: String, openedAt: Date) {
        self.stream = stream
        self.marker = marker
        self.pid = pid
        self.starttime = starttime
        self.argv0 = argv0
        self.openedAt = openedAt
    }
}

/// 676: one open agent stream, as `inspect` shows it — counts and times, never the program's text.
public struct AgentStreamInfo: Codable, Sendable, Equatable {
    public var stream: String
    public var argv0: String
    /// The program's pid in the guest (nil: not read yet).
    public var pid: Int?
    public var since: Date
    public var stdinBytes: Int64
    public var stdoutBytes: Int64
    public var lastInputAt: Date?
    public var lastOutputAt: Date?

    public init(stream: String, argv0: String, pid: Int?, since: Date, stdinBytes: Int64, stdoutBytes: Int64,
                lastInputAt: Date?, lastOutputAt: Date?) {
        self.stream = stream
        self.argv0 = argv0
        self.pid = pid
        self.since = since
        self.stdinBytes = stdinBytes
        self.stdoutBytes = stdoutBytes
        self.lastInputAt = lastInputAt
        self.lastOutputAt = lastOutputAt
    }
}

/// 676: why an agent stream was refused before its program started.
public enum AgentStreamError: Error, LocalizedError, Equatable, Sendable {
    /// A live stream has this label (`force` ends it first).
    case labelInUse(String)
    /// The sandbox has this many streams open already.
    case tooMany(Int)

    public var errorDescription: String? {
        switch self {
        case .labelInUse(let l): "a stream labelled \(l) is open already"
        case .tooMany(let n): "\(n) agent streams are open in this sandbox already (the most it takes)"
        }
    }
}

/// 676: the program's output on its way to the client — stdout and stderr in the order they arrived, at most `highWater`
/// bytes held. A writer (the guest's, on its handle's own dispatch queue) blocks while the buffer is at the mark; the reader
/// (the host's relay thread) takes chunks as the client's socket takes them. `finish()` (the program ended, or its pipe was
/// severed) lets the reader drain what is held and then see the end; `discard()` (nobody reads any more) drops what is held
/// and never blocks a writer again.
public final class AgentOutputBuffer: @unchecked Sendable {
    public enum Chunk: Equatable, Sendable {
        case stdout(Data)
        case stderr(Data)
        public var data: Data {
            switch self { case .stdout(let d), .stderr(let d): d }
        }
    }

    public let highWater: Int
    private let cond = NSCondition()
    private var chunks: [Chunk] = []
    private var head = 0
    private var held = 0
    private var finished = false
    private var discarding = false
    private var _peak = 0

    public init(highWater: Int = 4 << 20) { self.highWater = highWater }

    /// Bytes held now, and the most ever held.
    public var buffered: Int { cond.lock(); defer { cond.unlock() }; return held }
    public var peak: Int { cond.lock(); defer { cond.unlock() }; return _peak }

    /// Hold `chunk` — blocking while it would take the buffer past its mark (a chunk larger than the mark waits for an
    /// empty buffer). False: dropped (the stream is over, or nobody reads).
    @discardableResult
    public func write(_ chunk: Chunk) -> Bool {
        let n = chunk.data.count
        guard n > 0 else { return true }
        cond.lock(); defer { cond.unlock() }
        while !finished && !discarding && held > 0 && held + n > highWater { cond.wait() }
        if finished || discarding { return false }
        chunks.append(chunk)
        held += n
        _peak = max(_peak, held)
        cond.broadcast()
        return true
    }

    /// The next chunk, blocking until there is one; nil once it is finished and drained (or discarded).
    public func next() -> Chunk? {
        cond.lock(); defer { cond.unlock() }
        while head == chunks.count && !finished && !discarding { cond.wait() }
        guard head < chunks.count else { return nil }
        let c = chunks[head]
        head += 1
        if head >= 64 && head * 2 >= chunks.count { chunks.removeFirst(head); head = 0 }
        held -= c.data.count
        cond.broadcast()
        return c
    }

    /// No more output: the reader drains what is held, then sees the end; a blocked writer gives up.
    public func finish() {
        cond.lock(); finished = true; cond.broadcast(); cond.unlock()
    }

    /// Nobody reads any more: drop what is held; writers never block again; the reader sees the end.
    public func discard() {
        cond.lock()
        discarding = true
        chunks = []; head = 0; held = 0
        cond.broadcast()
        cond.unlock()
    }
}

/// 676: bytes for the program's stdin, at most `limit` queued that the guest has not taken: `put` blocks beyond it (the
/// host's socket reader stops reading, so the client's write blocks). The guest's stdin relay takes them one at a time
/// (`stream()`: an unfolding stream — the next chunk is taken only when the last one was written).
public final class AgentInputQueue: ReaderStream, @unchecked Sendable {
    public let limit: Int
    private let cond = NSCondition()
    private var items: [Data] = []
    private var queued = 0
    private var closed = false
    private var taker: CheckedContinuation<Data?, Never>?

    public init(limit: Int = 1 << 20) { self.limit = limit }

    public var queuedBytes: Int { cond.lock(); defer { cond.unlock() }; return queued }

    /// Queue `d`, blocking while `limit` bytes wait already. False: the input is closed (dropped).
    @discardableResult
    public func put(_ d: Data) -> Bool {
        guard !d.isEmpty else { return true }
        cond.lock()
        while !closed && queued > 0 && queued + d.count > limit { cond.wait() }
        if closed { cond.unlock(); return false }
        if let t = taker {
            taker = nil
            cond.unlock()
            t.resume(returning: d)
            return true
        }
        items.append(d)
        queued += d.count
        cond.unlock()
        return true
    }

    /// The end of the input: what is queued is still taken, then EOF. `dropping`: what is queued is thrown away too.
    public func close(dropping: Bool = false) {
        cond.lock()
        closed = true
        if dropping { items = []; queued = 0 }
        let t = items.isEmpty ? taker : nil
        if t != nil { taker = nil }
        cond.broadcast()
        cond.unlock()
        t?.resume(returning: nil)
    }

    /// The next chunk (nil: the input is over).
    public func take() async -> Data? {
        await withCheckedContinuation { (c: CheckedContinuation<Data?, Never>) in
            cond.lock()
            if !items.isEmpty {
                let d = items.removeFirst()
                queued -= d.count
                cond.broadcast()
                cond.unlock()
                c.resume(returning: d)
            } else if closed {
                cond.unlock()
                c.resume(returning: nil)
            } else {
                taker = c
                cond.unlock()
            }
        }
    }

    public func stream() -> AsyncStream<Data> {
        AsyncStream(unfolding: { [self] in await take() })
    }
}

/// 676: one agent stream's pipe (`Sandbox.openAgentStream`): the program's output (`nextOutput`), its input (`send`,
/// `finishInput`), and how it ended — `exitCode` when the program exited, `severed` when the pipe was cut while the
/// program may live on (never both).
public final class AgentPipe: @unchecked Sendable {
    /// The environment variable that marks the program (and what it starts) in the guest.
    public static let markerVariable = "DOZ_AGENT_STREAM_ID"

    public let id = UUID()
    public let label: String
    public let argv0: String
    public let openedAt = Date()
    public var marker: String { id.uuidString.lowercased() }

    let output: AgentOutputBuffer
    let input: AgentInputQueue
    /// Its stderr (the first 64 KiB) — why it failed, for the host's log on a failure.
    let errors = CappedCollector(limit: 65_536)
    public var errorOutput: String { String(decoding: errors.data, as: UTF8.self) }

    private let lock = NSLock()
    private var _exitCode: Int32?
    private var _severed: DetachReason?
    private var _ended = false
    private var _pid: Int?
    private var _starttime: UInt64?
    private var stdinCount: Int64 = 0
    private var stdoutCount: Int64 = 0
    private var lastIn: Date?
    private var lastOut: Date?
    private var _onEndProgram: (@Sendable () async -> Void)?

    public init(label: String, argv0: String, highWater: Int = 4 << 20, inputLimit: Int = 1 << 20) {
        self.label = label
        self.argv0 = argv0
        output = AgentOutputBuffer(highWater: highWater)
        input = AgentInputQueue(limit: inputLimit)
    }

    // MARK: the client's side

    /// The program's next output, blocking until there is some; nil once the stream is over (exited or severed).
    public func nextOutput() -> AgentOutputBuffer.Chunk? {
        let c = output.next()
        if case .stdout(let d)? = c {
            lock.lock(); stdoutCount += Int64(d.count); lastOut = Date(); lock.unlock()
        } else if c != nil {
            lock.lock(); lastOut = Date(); lock.unlock()
        }
        return c
    }

    /// Bytes for the program's stdin — blocking while 1 MiB the guest has not taken waits. False: dropped (the input is over).
    @discardableResult
    public func send(_ d: Data) -> Bool {
        guard !d.isEmpty else { return true }
        lock.lock(); stdinCount += Int64(d.count); lastIn = Date(); lock.unlock()
        return input.put(d)
    }

    /// The program's stdin reaches its end (it sees EOF).
    public func finishInput() { input.close() }

    /// The client is gone: its stdin ends, and its output is dropped from now on (never blocking the guest). The program is
    /// NOT ended here — the caller gives it a grace period, then `endProgram()`.
    public func hangUp() {
        input.close()
        output.discard()
    }

    /// End the program now (HUP, TERM, KILL) when its sandbox runs; otherwise it becomes an orphan, ended at the next wake —
    /// a sandbox is never woken to clean up. Nothing when it has ended already.
    public func endProgram() async {
        let f = lock.withLock { _onEndProgram }
        await f?()
    }

    public var exitCode: Int32? { lock.withLock { _exitCode } }
    public var severed: DetachReason? { lock.withLock { _severed } }
    /// The program exited, or the pipe was severed.
    public var hasEnded: Bool { lock.withLock { _ended } }
    public var guestPID: Int? { lock.withLock { _pid } }

    public var info: AgentStreamInfo {
        lock.withLock {
            AgentStreamInfo(stream: label, argv0: argv0, pid: _pid, since: openedAt, stdinBytes: stdinCount, stdoutBytes: stdoutCount,
                            lastInputAt: lastIn, lastOutputAt: lastOut)
        }
    }

    public var record: AgentProgramRecord {
        lock.withLock { AgentProgramRecord(stream: label, marker: marker, pid: _pid, starttime: _starttime, argv0: argv0, openedAt: openedAt) }
    }

    // MARK: the library's side

    func setOnEndProgram(_ f: @escaping @Sendable () async -> Void) { lock.withLock { _onEndProgram = f } }

    func setGuestProcess(pid: Int, starttime: UInt64) { lock.withLock { _pid = pid; _starttime = starttime } }

    func write(stdout d: Data) { _ = output.write(.stdout(d)) }

    func write(stderr d: Data) {
        try? errors.write(d)
        _ = output.write(.stderr(d))
    }

    /// The program exited (`code`; nil: the transport died without one). Never overwrites a sever.
    func ended(_ code: Int32?) {
        lock.lock()
        if !_ended { _ended = true; _exitCode = code }
        lock.unlock()
        input.close(dropping: true)
        output.finish()
    }

    /// Cut it now — its reader sees the end, with `reason`, instead of hanging on a VM that is going away. False: it had
    /// ended already (an exit is never re-labelled as a sever).
    @discardableResult
    func sever(_ reason: DetachReason) -> Bool {
        lock.lock()
        let live = !_ended
        if live { _ended = true; _severed = reason }
        lock.unlock()
        input.close(dropping: true)
        output.finish()
        return live
    }
}

/// The program's stdout / stderr → its pipe (on the handle's own queue — a full buffer blocks it: back-pressure).
struct AgentPipeWriter: Writer {
    let pipe: AgentPipe
    let stderr: Bool
    func write(_ data: Data) throws {
        if stderr { pipe.write(stderr: data) } else { pipe.write(stdout: data) }
    }
    func close() throws {}
}
