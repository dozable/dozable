import Foundation

/// 678 B7: the memory balloon's safety rules, as pure decisions (`BalloonPressureTests`).
///
/// An 8 GiB sandbox woke, the balloon took 5817 MiB ("keeps 2048" — a quarter), three `npm install`s and two Chromium
/// renders started, and the guest ran out of atomic allocations (`page allocation failure: order:1, GFP_ATOMIC`, no
/// swap) without its OOM killer ever running — so virtio-balloon's deflate-on-OOM never fired. The guest wedged: every
/// exec failed, the VM spun at ~400% CPU for 50 minutes, `doz ls` hung. So: a larger reserve; no inflate while a
/// session works; and the HOST watches the guest while the balloon holds anything and deflates early — from its own
/// side (VZ's balloon target needs no guest answer), also when the guest is too slow to answer a read.
public enum BalloonPressure {
    /// The free memory an inflate leaves the guest, MiB: at least half its allocation, and never below what it already
    /// uses (`MemTotal - MemAvailable`: its programs and sessions) plus 2 GiB — or, in a sandbox under 4 GiB, plus half
    /// its allocation (a flat 2 GiB would leave a 1 or 2 GiB sandbox no balloon at all; above 4 GiB it is exactly 2 GiB).
    public static func reserveMiB(memoryMiB: UInt64, usedMiB: UInt64) -> UInt64 {
        max(memoryMiB / 2, usedMiB + min(2048, memoryMiB / 2))
    }

    /// How often the host reads the guest while the balloon holds something, and how long a read may take before the
    /// guest counts as too starved to answer.
    public static let interval: Duration = .seconds(2)
    public static let readLimit: Duration = .seconds(3)

    public enum Decision: Equatable, Sendable {
        case hold
        /// Deflate fully, at once — and why (a note in the sandbox's log).
        case deflate(String)
    }

    /// One look at the guest (`meminfo`: its /proc/meminfo in kB; nil — the read failed or took too long).
    public static func decide(meminfo: [String: UInt64]?, reserveKiB: UInt64) -> Decision {
        guard let m = meminfo, let available = m["MemAvailable"] else {
            return .deflate("the guest did not answer a memory read within \(readLimit.components.seconds) s")
        }
        if available < reserveKiB {
            return .deflate("the guest's available memory fell to \(available / 1024) MiB, under the \(reserveKiB / 1024) MiB it keeps")
        }
        return .hold
    }

    /// `task`'s value — or nil when it fails or `limit` passes first (the task is not cancelled: a guest call that
    /// hangs ends by itself).
    public static func value<T: Sendable>(of task: Task<T, Error>, within limit: Duration) async -> T? {
        try? await outcome(of: task, within: limit)?.get()
    }

    /// `task`'s result — or nil when `limit` passes first (the task goes on, uncancelled).
    public static func outcome<T: Sendable>(of task: Task<T, Error>, within limit: Duration) async -> Result<T, Error>? {
        let box = FirstAnswer<Result<T, Error>>()
        return await withCheckedContinuation { (c: CheckedContinuation<Result<T, Error>?, Never>) in
            box.hold(c)
            Task { box.answer(await task.result) }
            box.timer = Task {
                try? await Task.sleep(for: limit)
                box.answer(nil)
            }
        }
    }
}

/// Whichever answers first resumes `BalloonPressure.value`.
final class FirstAnswer<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T?, Never>?
    private var _timer: Task<Void, Never>?
    var timer: Task<Void, Never>? {
        get { lock.withLock { _timer } }
        set { lock.withLock { _timer = newValue } }
    }

    func hold(_ c: CheckedContinuation<T?, Never>) { lock.withLock { continuation = c } }

    func answer(_ v: T?) {
        let (c, t): (CheckedContinuation<T?, Never>?, Task<Void, Never>?) = lock.withLock {
            defer { continuation = nil }
            return (continuation, _timer)
        }
        guard let c else { return }
        t?.cancel()
        c.resume(returning: v)
    }
}
