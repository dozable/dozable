import Foundation

/// 678: which lazily built parts a process built — the seam `make test-cli-startup` reads to prove that a start builds
/// no recipe part it does not need. Off unless a sink is installed; DozableHost installs one only in a guarded test run
/// with `DOZ_TEST_STARTUP_TRACE=1` (it prints each note on stderr). A note is a fixed sentence, never a value.
public enum StartupTrace {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var sink: (@Sendable (String) -> Void)?

    /// Send every later note to `s` (nil: off).
    public static func install(_ s: (@Sendable (String) -> Void)?) { lock.withLock { sink = s } }

    /// One part was built.
    public static func note(_ what: String) {
        let s = lock.withLock { sink }
        s?(what)
    }
}
