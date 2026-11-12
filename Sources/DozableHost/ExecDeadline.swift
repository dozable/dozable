import Darwin
import Foundation

/// 678: when this process started — the kernel's own record (`kp_proc.p_starttime`), so it counts the loader and
/// everything before `main` too. nil only when the kernel will not say.
public enum ProcessStart {
    public static let date: Date? = of(getpid())

    public static func of(_ pid: pid_t) -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let tv = info.kp_proc.p_un.__p_starttime
        guard tv.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000)
    }
}

/// 678: `doz exec`'s deadline — `--timeout N` seconds (default 120) from when doz STARTED, however long the start, the
/// host's wake or boot, or the command take. The host answers at the deadline (`HostRequest.deadline`); this watchdog
/// covers a client that never hears it (a host that does not answer, an older host, a client that was stopped): a
/// dedicated thread — not a dispatch queue or Swift concurrency, which a starved pool could hold back — ends the
/// process with 124 a little after the deadline.
public enum ExecDeadline {
    public static let defaultSeconds: Int64 = 120
    /// How long after the deadline the watchdog waits for the host's own answer.
    public static let grace: TimeInterval = 2

    /// The global options that take a value (`doz --store DIR exec …`), and exec's own.
    static let globalValued: Set<String> = ["--store", "--progress", "--color"]
    static let execValued: Set<String> = ["--workdir", "--user", "-e", "--env", "--timeout", "--store", "--progress", "--color"]

    /// The seconds of an `exec` command line (nil: not exec, or no deadline — `--timeout 0` or less). A cheap scan of
    /// argv (no parser): the first word that is not an option or an option's value is the command; its `--timeout N` /
    /// `--timeout=N` before `--` (a value that does not read as a number leaves the default — the parser refuses it).
    public static func seconds(_ args: [String]) -> Int64? {
        var i = 0
        while i < args.count {
            let a = args[i]
            if a == "--" { return nil }
            guard a.hasPrefix("-") else { break }
            i += globalValued.contains(a) ? 2 : 1
        }
        guard i < args.count, args[i] == "exec" else { return nil }
        var n = defaultSeconds
        var j = i + 1
        while j < args.count, args[j] != "--" {
            let a = args[j]
            if a == "--timeout" {
                if j + 1 < args.count, let v = Int64(args[j + 1]) { n = v }
                j += 2
                continue
            }
            if a.hasPrefix("--timeout="), let v = Int64(a.dropFirst("--timeout=".count)) { n = v }
            j += execValued.contains(a) ? 2 : 1
        }
        return n > 0 ? n : nil
    }

    /// The deadline of `seconds` from `start`.
    public static func deadline(seconds: Int64, start: Date) -> Date { start.addingTimeInterval(TimeInterval(seconds)) }

    /// The seconds left until `deadline` for an older host's `timeoutSeconds` (at least 1).
    public static func remaining(_ deadline: Date, now: Date = Date()) -> Int64 {
        max(1, Int64(deadline.timeIntervalSince(now).rounded(.up)))
    }

    /// The watchdog's line.
    public static func message(_ seconds: Int64) -> String { "doz: exec timed out after \(seconds) s (counted from when doz started)" }

    /// `DozableEntry`'s first step: for an exec command line, start the watchdog.
    public static func arm(_ args: [String], start: Date? = ProcessStart.date) {
        guard let n = seconds(args) else { return }
        let fire = deadline(seconds: n, start: start ?? Date()).addingTimeInterval(grace)
        let line = message(n) + "\n"
        let t = Thread {
            // Short sleeps against the wall clock: a process stopped (SIGSTOP) past its deadline ends as soon as it runs.
            while true {
                let left = fire.timeIntervalSinceNow
                if left <= 0 { break }
                usleep(useconds_t(min(left, 0.25) * 1_000_000))
            }
            line.withCString { _ = Darwin.write(STDERR_FILENO, $0, strlen($0)) }
            _exit(DozableExitCode.timedOut)
        }
        t.name = "doz-exec-deadline"
        t.start()
    }
}
