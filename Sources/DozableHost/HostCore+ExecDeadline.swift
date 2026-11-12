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
