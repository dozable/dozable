import Darwin
import Foundation
import DozableKit

// 676: `agent-stream` — a structured agent session (Claude Code's stream-json, ACP, …) over a real pipe into a sandbox. A
// terminal cannot carry it (`claude --print` refuses a TTY stdin), and `exec` buffers its output and has no stdin. Modelled
// on `copy`: wake/start as `exec` does (their events first), ONE `ok` line (`AgentStreamReady`), then frames both ways.
//
// Lifecycle: pause and sleep STALL the stream (the VM is frozen in memory; bytes flow again on resume/wake, and a client `D`
// frame wakes it, as a keystroke does). Hibernate, shut down and host stop SEVER it: the last frame is `E {severed}`, never a
// hang. The client resumes the conversation from the agent's own session file (`claude --resume <session_id>`) on a new
// stream — and the old program, still in the guest, is ended before that stream can start (`Sandbox.openAgentStream`).
//
// Rules a client relies on: `E` is always the last frame and carries exactly one of `exitCode` or `severed`; a client skips a
// host → client frame type it does not know (a new one is only ever sent to a client that asked for it with a request field);
// the host refuses a client → host type it does not know (a hang-up); `F` ends the program's input — a client never
// half-closes the socket: the host takes its end of input as a hang-up.

/// The host's answer before the frames.
public struct AgentStreamReady: Codable, Equatable, Sendable {
    /// The stream's label (the request's `stream`, or the one the host made).
    public var stream: String
    /// The guest user it runs as (nil: root).
    public var runAs: String?
    /// Its working directory in the guest.
    public var workdir: String
    /// The program's pid in the guest, when the host knows it already (diagnostics; `inspect` has it later).
    public var pid: Int?
    public var woke: Bool?
    public var started: Bool?

    public init(stream: String, runAs: String?, workdir: String, pid: Int? = nil, woke: Bool? = nil, started: Bool? = nil) {
        self.stream = stream
        self.runAs = runAs
        self.workdir = workdir
        self.pid = pid
        self.woke = woke
        self.started = started
    }
}

/// The last frame: how the program's pipe ended. Exactly one of `exitCode` and `severed` is set.
public struct AgentStreamEnd: Codable, Equatable, Sendable {
    /// The program's exit code (nil when the pipe was severed).
    public var exitCode: Int32?
    /// Why the pipe was cut while the program may live on — an open set (a client treats any word as "resume on a new
    /// stream"): `AgentFrame.severedWords`.
    public var severed: String?
    /// Bytes relayed: the program's stdout to the client, the client's input to the program.
    public var stdoutBytes: Int64
    public var stdinBytes: Int64
    public var milliseconds: Double

    public init(exitCode: Int32?, severed: String?, stdoutBytes: Int64, stdinBytes: Int64, milliseconds: Double) {
        self.exitCode = exitCode
        self.severed = severed
        self.stdoutBytes = stdoutBytes
        self.stdinBytes = stdinBytes
        self.milliseconds = milliseconds
    }
}

/// The connection after `AgentStreamReady`: `CopyFrame`'s shape (a type byte, a 4-byte big-endian length, the payload of at
/// most 1 MiB). Host → client: `D` stdout, `R` stderr, `E` the end (`AgentStreamEnd`). Client → host: `D` stdin, `F` its EOF.
public enum AgentFrame {
    public static let data = CopyFrame.data, end = CopyFrame.end, finish = CopyFrame.finish
    public static let stderr: UInt8 = 0x52
    /// What the host sends.
    public static let hostTypes: Set<UInt8> = [data, stderr, end]
    /// What a client sends.
    public static let clientTypes: Set<UInt8> = [data, finish]

    /// `sleeping`: hibernate (or a future sleep that frees RAM) · `stopped`: shut down, reset, rm, or the stream replaced
    /// (`force`) · `host-stopping`: `doz host stop`, a quit, SIGTERM · `transport-lost`: the pipe died with no reason.
    public static let severedWords = ["sleeping", "stopped", "host-stopping", "transport-lost"]

    public static func encode(_ type: UInt8, _ payload: Data = Data()) -> Data { CopyFrame.encode(type, payload) }

    /// `payload` as frames of at most `CopyFrame.maximumPayload`.
    public static func chunked(_ type: UInt8, _ payload: Data) -> [Data] {
        var out: [Data] = []
        var at = payload.startIndex
        while at < payload.endIndex {
            let end = min(at + CopyFrame.maximumPayload, payload.endIndex)
            out.append(encode(type, payload.subdata(in: at..<end)))
            at = end
        }
        return out
    }

    /// A client's parser of the host's frames: an unknown type is skipped.
    public static func clientParser() -> CopyFrame.Parser { CopyFrame.Parser(types: hostTypes, skippingUnknown: true) }
    /// The host's parser of a client's frames: an unknown type is an error (a hang-up).
    public static func hostParser() -> CopyFrame.Parser { CopyFrame.Parser(types: clientTypes) }

    /// The end of a stream: the exit code, or the severed word — `host-stopping` while the host stops, `transport-lost` when
    /// the pipe ended with neither. Never both, never neither.
    public static func end(exitCode: Int32?, severed: DetachReason?, hostStopping: Bool,
                           stdoutBytes: Int64, stdinBytes: Int64, milliseconds: Double) -> AgentStreamEnd {
        var word: String?
        if exitCode == nil || severed != nil {
            if hostStopping { word = "host-stopping" } else {
                switch severed {
                case .sandboxSleeping?: word = "sleeping"
                case .sandboxStopped?, .closedByClient?: word = "stopped"
                case .transportLost?, nil: word = "transport-lost"
                }
            }
        }
        return AgentStreamEnd(exitCode: word == nil ? exitCode : nil, severed: word, stdoutBytes: stdoutBytes, stdinBytes: stdinBytes,
                              milliseconds: milliseconds)
    }
}

/// 676: what the relay needs of a pipe (`AgentPipe`; a fake in the tests).
protocol AgentPipeIO: AnyObject, Sendable {
    func nextOutput() -> AgentOutputBuffer.Chunk?
    @discardableResult func send(_ d: Data) -> Bool
    func finishInput()
    func hangUp()
    func endProgram() async
    var exitCode: Int32? { get }
    var severed: DetachReason? { get }
    var hasEnded: Bool { get }
}

extension AgentPipe: AgentPipeIO {}

/// 676: one stream's frame pump on its connection. Program → client on the calling thread (a blocking write to the socket —
/// a client that reads slowly holds the program's output in its bounded buffer, then the program); client → program on a
/// thread of its own (a blocking `send` — 1 MiB not yet taken stops the reading, and the client's write blocks). A client
/// that hangs up gets its program's stdin closed, and after `grace` the program is ended (`endProgram`) unless it exited.
final class AgentStreamRelay: @unchecked Sendable {
    let conn: HostConnection
    let pipe: any AgentPipeIO
    let grace: Duration
    let sleep: @Sendable (Duration) async -> Void
    let onInput: @Sendable () -> Void
    let hostStopping: @Sendable () -> Bool
    let log: @Sendable (String) -> Void

    private let lock = NSLock()
    private var _over = false
    private var _clientGone = false
    private var _graceTask: Task<Void, Never>?
    /// The grace task after a hang-up (tests wait for it).
    var graceTask: Task<Void, Never>? { lock.withLock { _graceTask } }

    init(conn: HostConnection, pipe: any AgentPipeIO, grace: Duration = .seconds(5),
         sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
         onInput: @escaping @Sendable () -> Void = {}, hostStopping: @escaping @Sendable () -> Bool = { false },
         log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.conn = conn
        self.pipe = pipe
        self.grace = grace
        self.sleep = sleep
        self.onInput = onInput
        self.hostStopping = hostStopping
        self.log = log
    }

    struct Outcome {
        var end: AgentStreamEnd
        /// The `E` frame reached the client.
        var delivered: Bool
        /// The client hung up first (nobody was sent `E`).
        var clientGone: Bool
    }

    /// Relay until the stream is over; returns its end. `early`: bytes the client sent behind its request line.
    func run(early: Data = Data()) -> Outcome {
        let t0 = ContinuousClock.now
        let stdin = ByteCount()
        let inputDone = DispatchSemaphore(value: 0)
        let fd = conn.fd
        Thread.detachNewThread { [self] in
            let parser = AgentFrame.hostParser()
            var buf = [UInt8](repeating: 0, count: 65_536)
            var pending = early
            reading: while true {
                if !pending.isEmpty {
                    let frames: [(type: UInt8, payload: Data)]
                    do { frames = try parser.feed(pending) } catch {
                        log("refused a frame (\(error)) — taken as a hang-up")
                        break reading
                    }
                    pending = Data()
                    for f in frames {
                        if f.type == AgentFrame.data {
                            stdin.add(f.payload.count)
                            onInput()
                            pipe.send(f.payload)
                        } else if f.type == AgentFrame.finish {
                            pipe.finishInput()
                        }
                    }
                }
                let n = read(fd, &buf, buf.count)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { break reading }
                pending = Data(buf[0..<n])
            }
            // The connection's input is over: our own shutdown after `E`, or a client that hung up.
            let hungUp: Bool = lock.withLock {
                if _over { return false }
                _clientGone = true
                return true
            }
            if hungUp { clientLeft() }
            inputDone.signal()
        }
        var stdout: Int64 = 0
        while let c = pipe.nextOutput() {
            if lock.withLock({ _clientGone }) { continue }        // dropped: nobody reads (hangUp discards the rest)
            let type: UInt8
            switch c {
            case .stdout(let d): stdout += Int64(d.count); type = AgentFrame.data
            case .stderr: type = AgentFrame.stderr
            }
            for f in AgentFrame.chunked(type, c.data) where !conn.write(f) {
                let first: Bool = lock.withLock { let was = _clientGone; _clientGone = true; return !was }
                if first { clientLeft() }
                break
            }
        }
        let gone: Bool = lock.withLock { _over = true; return _clientGone }
        let d = ContinuousClock.now - t0
        let end = AgentFrame.end(exitCode: pipe.exitCode, severed: pipe.severed, hostStopping: hostStopping(), stdoutBytes: stdout,
                                 stdinBytes: stdin.value,
                                 milliseconds: Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15)
        var delivered = false
        if !gone, let e = try? HostWire.encoder.encode(end) { delivered = conn.write(AgentFrame.encode(AgentFrame.end, e)) }
        conn.shutdownIO()
        inputDone.wait()
        return Outcome(end: end, delivered: delivered, clientGone: gone)
    }

    /// The client is gone: its program's stdin ends now (it sees EOF), its output is dropped, and after the grace period the
    /// program is ended unless it exited by then. No `E`: nobody is listening.
    private func clientLeft() {
        pipe.hangUp()
        let pipe = self.pipe, grace = self.grace, sleep = self.sleep, log = self.log
        let t = Task.detached {
            await sleep(grace)
            guard !pipe.hasEnded else { return }
            log("the client hung up and the program had not ended after the grace period — ending it")
            await pipe.endProgram()
        }
        lock.withLock { _graceTask = t }
    }
}

/// 676: a client `D` frame wakes a paused or asleep sandbox, once at a time — the keystroke rule (both keep the VM, and the
/// stream, in memory).
final class WakeOnInput: @unchecked Sendable {
    private let lock = NSLock()
    private var waking = false
    private let wake: @Sendable () async -> Void
    init(_ wake: @escaping @Sendable () async -> Void) { self.wake = wake }
    func input() {
        let go: Bool = lock.withLock { if waking { return false }; waking = true; return true }
        guard go else { return }
        Task.detached { [self] in
            await wake()
            lock.withLock { waking = false }
        }
    }
}

extension HostCore {
    /// The labels the host makes: `s-` and 8 hex digits.
    static func newStreamLabel() -> String { "s-" + UUID().uuidString.prefix(8).lowercased() }

    /// A label a client may choose: 1–64 of letters, digits, `.`, `_`, `-`, `:`.
    static func validStreamLabel(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 64 && s.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || "._-:".unicodeScalars.contains($0) }
    }

    /// Wake/start as exec does, then the program on a guest pipe with exec's environment, user and folder.
    func agentStreamOpen(_ r: HostRequest, emit: @escaping @Sendable (HostEvent) -> Void) async throws -> (AgentStreamReady, AgentPipe) {
        let m = try get(r.name)
        guard let argv = r.argv, !argv.isEmpty, !argv[0].isEmpty else {
            throw HostError(.invalid, "agent-stream needs a command (doz agent-stream NAME -- CMD…)")
        }
        let label = r.stream ?? Self.newStreamLabel()
        guard Self.validStreamLabel(label) else {
            throw HostError(.invalid, "a stream label is 1–64 letters, digits, '.', '_', '-' or ':' — not \(label.debugDescription)")
        }
        let first = try await ensureRunning(m, wake: r.wake ?? true, start: r.start ?? false, emit: emit)
        if m.config.imageChoice?.agent == .codex, (argv.first as NSString?)?.lastPathComponent == "codex" { await deliverCodexAuth(m) }
        let ctx = Self.execContext(config: m.config,
                                   environment: recipeEnvironment(Self.withClaudePermissions(r.environment ?? [:], imageSpec: m.config.spec.imageSpec?.name,
                                                                                             own: m.config.settings?[SettingKey.sandboxApprovals]), m),
                                   workdir: r.workdir, user: r.user)
        let pipe: AgentPipe
        do {
            pipe = try await m.sandbox.openAgentStream(argv, environment: ctx.environment, workingDirectory: ctx.workdir, user: ctx.user,
                                                       label: label, force: r.force == true)
        } catch let e as AgentStreamError {
            switch e {
            case .labelInUse(let l):
                throw HostError(.exists, "a stream labelled \(l) is open in \(m.name) — --force ends it first")
            case .tooMany(let n):
                throw HostError(.unavailable, "\(m.name) has \(n) agent streams open — the most one sandbox takes")
            }
        } catch {
            if let plain = Self.missingProgramMessage(error, argv: argv, runsAs: ctx.user, command: "doz agent-stream") { throw HostError(.notFound, plain) }
            throw error
        }
        var ready = AgentStreamReady(stream: label, runAs: ctx.user, workdir: ctx.workdir, pid: pipe.guestPID)
        if first.started { ready.started = true }
        if first.woke { ready.woke = true }
        // The program's name, never its arguments (they may hold a prompt).
        HostLog.line("\(m.name): agent-stream \(label) opened — \((argv[0] as NSString).lastPathComponent) as \(ctx.user ?? "root") in \(ctx.workdir)")
        metrics?.record(run: metricsRun, action: "agent-stream", sandbox: m.name, image: m.config.image, startedAt: Date(), durationMs: 0)
        return (ready, pipe)
    }

    /// Whether a client's input wakes a sandbox in `phase`: paused or asleep (the VM, and the stream, are in memory). A
    /// hibernated or stopped one cannot be reached: its stream was severed.
    static func agentInputWakes(_ phase: Phase) -> Bool { phase == .paused || phase == .asleep }

    /// A client frame arrived: wake the sandbox when it is paused or asleep.
    func agentStreamInput(_ name: String?) async {
        guard let m = try? get(name), Self.agentInputWakes(await m.sandbox.phase) else { return }
        _ = try? await ensureRunning(m, wake: true)
    }

    /// For `inspect`: the streams open now (nil: none).
    func agentStreamsOpen(_ m: Managed) async -> [AgentStreamInfo]? {
        let s = await m.sandbox.agentStreamInfo()
        return s.isEmpty ? nil : s
    }

    /// One line for host.log at a stream's end — the counts, never the program's text.
    static func agentStreamEndLine(_ name: String, label: String, _ o: AgentStreamRelay.Outcome) -> String {
        let how = o.clientGone ? "the client hung up (its program gets stdin EOF, then is ended after the grace period)"
            : o.end.severed.map { "SEVERED (\($0))" } ?? "exit \(o.end.exitCode.map(String.init) ?? "?")"
        return "\(name): agent-stream \(label) ended — \(how) (\(o.end.stdoutBytes) bytes out, \(o.end.stdinBytes) in, "
            + String(format: "%.0f ms)", o.end.milliseconds)
    }
}
