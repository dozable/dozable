import Darwin
import Foundation

/// Stopping (SIGSTOP) and resuming (SIGCONT) EVERY process of one fenced session — the program's group is not enough: a
/// child that `setsid`s or double-forks leaves it. A process belongs to the session when it is this user's, it is
/// sandboxed, it MAY read the session's sentinel (allowed only by this session's profile — every other fence closes the
/// whole fence root) and it may NOT read the anti-sentinel (closed to every fence, open to a broad reader such as an
/// indexer). The test is `sandbox_check` — SPI in libsystem_sandbox (Chromium and WebKit use it), looked up with
/// `dlsym`; without it, the fallback is the program's group and every descendant by parent pid, and `how` says so.
public enum MacFenceStop {
    /// `int sandbox_check(pid_t, const char *operation, int type, ...)` — variadic: on arm64 the path must be on the
    /// STACK, so it is declared with five unused register arguments before it (x3–x7). Verified on this Mac: the same
    /// call with the path in x3 fails with EFAULT.
    typealias SandboxCheck = @convention(c) (pid_t, UnsafePointer<CChar>?, Int32, Int, Int, Int, Int, Int, UnsafePointer<CChar>?) -> Int32

    static let check: SandboxCheck? = {
        #if arch(arm64)
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "sandbox_check") else { return nil }
        return unsafeBitCast(sym, to: SandboxCheck.self)
        #else
        return nil
        #endif
    }()

    static let filterNone: Int32 = 0
    static let filterPath: Int32 = 1
    /// `SANDBOX_CHECK_NO_REPORT`: asking writes no violation line.
    static let noReport: Int32 = 0x4000_0000

    public static var available: Bool { check != nil }

    /// Is `pid` sandboxed?
    public static func sandboxed(_ pid: pid_t) -> Bool? {
        guard let c = check else { return nil }
        return c(pid, nil, filterNone | noReport, 0, 0, 0, 0, 0, nil) == 1
    }

    /// May `pid` read `path`? (nil: cannot tell)
    public static func mayRead(_ pid: pid_t, _ path: String) -> Bool? {
        guard let c = check else { return nil }
        let r = path.withCString { c(pid, "file-read-data", filterPath | noReport, 0, 0, 0, 0, 0, $0) }
        return r < 0 ? nil : r == 0
    }

    static let filterGlobalName: Int32 = 2

    /// May `pid` look up the Mach service `name` (the Keychain's `com.apple.SecurityServer`)? (nil: cannot tell)
    public static func mayLookUp(_ pid: pid_t, _ name: String) -> Bool? {
        guard let c = check else { return nil }
        let r = name.withCString { c(pid, "mach-lookup", filterGlobalName | noReport, 0, 0, 0, 0, 0, $0) }
        return r < 0 ? nil : r == 0
    }

    static let filterPreferenceDomain: Int32 = 6

    /// 683 M4: may `pid` write / read the preferences of `domain` (`user-preference-write`, `-read`)? (nil: cannot tell)
    public static func mayWritePreference(_ pid: pid_t, _ domain: String) -> Bool? { preference(pid, "user-preference-write", domain) }
    public static func mayReadPreference(_ pid: pid_t, _ domain: String) -> Bool? { preference(pid, "user-preference-read", domain) }
    static func preference(_ pid: pid_t, _ op: String, _ domain: String) -> Bool? {
        guard let c = check else { return nil }
        let r = domain.withCString { c(pid, op, filterPreferenceDomain | noReport, 0, 0, 0, 0, 0, $0) }
        return r < 0 ? nil : r == 0
    }

    /// Every process of this user.
    static func userPids() -> [pid_t] {
        var n = proc_listallpids(nil, 0)
        guard n > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(n) + 64)
        n = pids.withUnsafeMutableBufferPointer { proc_listallpids($0.baseAddress, Int32($0.count * MemoryLayout<pid_t>.size)) }
        guard n > 0 else { return [] }
        let me = getuid()
        return pids.prefix(Int(n)).filter { pid in
            guard pid > 1, pid != getpid() else { return false }
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return false }
            return info.pbi_uid == me
        }
    }

    static func parent(_ pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(info.pbi_ppid)
    }

    static func isStopped(_ pid: pid_t) -> Bool {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return false }
        return info.pbi_status == UInt32(SSTOP)
    }

    /// The processes of the session whose sentinel is `sentinel` (and anti-sentinel `anti`); with no `sandbox_check`,
    /// `program`'s group and its descendants.
    public static func members(sentinel: String, anti: String, program: pid_t?) -> (pids: [pid_t], how: String) {
        let all = userPids()
        if available {
            let found = all.filter { pid in
                sandboxed(pid) == true && mayRead(pid, sentinel) == true && mayRead(pid, anti) == false
            }
            return (found, "sandbox_check")
        }
        guard let program, program > 1 else { return ([], "no program pid") }
        var set: Set<pid_t> = [program]
        var grew = true
        while grew {
            grew = false
            for p in all where !set.contains(p) {
                if let pp = parent(p), set.contains(pp) { set.insert(p); grew = true }
                else if getpgid(p) == program { set.insert(p); grew = true }
            }
        }
        return (Array(set), "the program's group and descendants (sandbox_check unavailable)")
    }

    /// SIGSTOP every member, again and again until two passes find nothing new still running. Returns those stopped.
    @discardableResult
    public static func stop(sentinel: String, anti: String, program: pid_t?) -> (pids: [pid_t], how: String) {
        var stopped: Set<pid_t> = []
        var how = ""
        var quiet = 0
        var rounds = 0
        while quiet < 2 && rounds < 50 {
            rounds += 1
            let m = members(sentinel: sentinel, anti: anti, program: program)
            how = m.how
            var fresh = false
            for p in m.pids where !isStopped(p) {
                if kill(p, SIGSTOP) == 0 { fresh = true }
                stopped.insert(p)
            }
            for p in m.pids { stopped.insert(p) }
            quiet = fresh ? 0 : quiet + 1
            if fresh { usleep(20_000) }
        }
        return (stopped.sorted(), how)
    }

    /// SIGCONT the members again (and `also`, the pids recorded at the stop — only while they are still members).
    public static func resume(sentinel: String, anti: String, program: pid_t?, also: [Int]) {
        let m = members(sentinel: sentinel, anti: anti, program: program)
        let set = Set(m.pids)
        for p in m.pids { kill(p, SIGCONT) }
        for p in also.map({ pid_t($0) }) where set.contains(p) { kill(p, SIGCONT) }
    }
}
