import DozableKit
import Foundation

// 678: `doz exec`'s deadline in the host — the whole exec (a wake, a start, the command) answered at it.

extension HostCore {
    /// TEST SEAM (guarded runs only): `DOZ_TEST_EXEC_LIFECYCLE_DELAY_MS` holds an exec's wake or start back that long
    /// before it begins — a lab boots in under a second, so `make test-cli-exectimeout` needs a lifecycle that
    /// outlasts a deadline for sure. The wake or start still runs, after the answer.
    static let testLifecycleDelayNanoseconds: UInt64 = {
        let env = ProcessInfo.processInfo.environment
        guard TestSafety.guarded(env), let ms = env["DOZ_TEST_EXEC_LIFECYCLE_DELAY_MS"].flatMap(UInt64.init), ms <= 60_000 else { return 0 }
        return ms * 1_000_000
    }()

    /// What an exec has to get through first, in the words its timeout answer uses: `starting` (off, failed, or a cold
    /// start under way), `waking` (paused, asleep, hibernated, busy) or `running`.
    func execPhaseWord(_ m: Managed) async -> String {
        if coldStarts.isRunning(m.name) { return "starting" }
        let p = await effectivePhase(m)
        switch p {
        case .running: return await m.sandbox.status.busy ? "waking" : "running"
        case .off, .failed: return "starting"
        default: return "waking"
        }
    }

    // MARK: 678 B7 — one stuck guest never holds the host's answers

    /// How long a listing waits for one guest's answer, and how long a guest that did not answer is not asked again.
    static let guestReadLimit: Duration = .seconds(3)
    static let unresponsiveRetry: TimeInterval = 30

    enum GuestRead<T: Sendable>: Sendable { case answered(T), unresponsive, failed(Error) }

    /// `guestRead` by the sandbox's name (the tests').
    func guestRead<T: Sendable>(named name: String, _ read: @escaping @Sendable (Sandbox) async throws -> T) async -> GuestRead<T> {
        guard let m = try? get(name) else { return .failed(HostError(.notFound, "no sandbox \(name)")) }
        return await guestRead(m, read)
    }

    /// A read from `m`'s guest for a listing (`ls`, `sessions`): bounded by `guestReadLimit`; a guest that did not answer
    /// in time is `unresponsive` (said once in the log) and not asked again for `unresponsiveRetry` — the read it was
    /// given goes on by itself; nothing waits for it.
    func guestRead<T: Sendable>(_ m: Managed, _ read: @escaping @Sendable (Sandbox) async throws -> T) async -> GuestRead<T> {
        if let since = unresponsive[m.name], Date().timeIntervalSince(since) < Self.unresponsiveRetry { return .unresponsive }
        let sb = m.sandbox
        guard let r = await BalloonPressure.outcome(of: Task { try await read(sb) }, within: Self.guestReadLimit) else {
            if unresponsive[m.name] == nil {
                note(m.name, "does not answer (a read took over \(Self.guestReadLimit.components.seconds) s) — listed as unresponsive; doz shutdown \(m.name) stops it")
            }
            unresponsive[m.name] = Date()
            // A guest that does not answer may be starving: give it its whole allocation back.
            await sb.relieveMemoryPressure("the guest did not answer a read in time")
            return .unresponsive
        }
        if unresponsive.removeValue(forKey: m.name) != nil { note(m.name, "answers again") }
        switch r {
        case .success(let v): return .answered(v)
        case .failure(let e): return .failed(e)
        }
    }

    /// TEST SEAM: forget that `name` did not answer (what a lifecycle request does).
    func clearUnresponsiveForTests(_ name: String) { unresponsive[name] = nil }

    /// `work`'s value — or nil when `deadline` passes first. `work` is never cancelled: it goes on to its end (a wake or
    /// a start must), its result unread.
    static func race<T: Sendable>(until deadline: Date, _ work: Task<T, Error>) async throws -> T? {
        let left = deadline.timeIntervalSinceNow
        guard left > 0 else { return nil }
        let box = RaceBox<T>()
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<T?, Error>) in
            box.hold(c)
            Task { box.finish(await work.result.map { Optional($0) }) }
            box.timer = Task {
                try? await Task.sleep(nanoseconds: UInt64(left * 1_000_000_000))
                box.finish(.success(nil))
            }
        }
    }
}

/// One answer for `HostCore.race`: whichever comes first resumes it.
final class RaceBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T?, Error>?
    private var _timer: Task<Void, Never>?
    var timer: Task<Void, Never>? {
        get { lock.withLock { _timer } }
        set { lock.withLock { _timer = newValue } }
    }

    func hold(_ c: CheckedContinuation<T?, Error>) { lock.withLock { continuation = c } }

    func finish(_ r: Result<T?, Error>) {
        let (c, t): (CheckedContinuation<T?, Error>?, Task<Void, Never>?) = lock.withLock {
            defer { continuation = nil }
            return (continuation, _timer)
        }
        guard let c else { return }
        t?.cancel()
        c.resume(with: r)
    }
}

/// A client's events while its exec waits — closed once the deadline's answer is sent, so a wake that goes on in the
/// background says nothing more to it.
final class EmitGate: @unchecked Sendable {
    private let lock = NSLock()
    private var emit: (@Sendable (HostEvent) -> Void)?
    init(_ emit: @escaping @Sendable (HostEvent) -> Void) { self.emit = emit }
    func send(_ e: HostEvent) { lock.withLock { emit }?(e) }
    func close() { lock.withLock { emit = nil } }
}
