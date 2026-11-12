import Darwin
import Foundation

/// 678: how macOS schedules a process — `doz doctor` warns when doz (or its host) runs clamped to background priority,
/// where everything it does, a sandbox's wake included, runs many times slower (a 69 s hibernate was seen from a host
/// that a background-priority client had started, and inherited it).
public struct ProcessPriority: Codable, Equatable, Sendable {
    /// The Darwin background state (`taskpolicy -b`, launchd's `ProcessType=Background`, a background-QoS spawner).
    public var background: Bool
    /// The main thread's QoS class: `user-interactive`, `user-initiated`, `default`, `utility`, `background`,
    /// `unspecified`.
    public var qos: String
    /// The scheduling priority (what `ps -o pri` shows; 4 under background, 31 normally). nil: not read.
    public var pri: Int32?

    public init(background: Bool, qos: String, pri: Int32?) {
        self.background = background
        self.qos = qos
        self.pri = pri
    }

    /// Clamped: in the Darwin background state, or at the background QoS (`taskpolicy -c background`). Utility is left
    /// alone: many ordinary tools run there.
    public var clamped: Bool { background || qos == "background" }

    /// This process.
    public static func current() -> ProcessPriority {
        ProcessPriority(background: getpriority(PRIO_DARWIN_PROCESS, 0) > 0, qos: name(qos_class_self()), pri: pri(of: getpid()))
    }

    /// The scheduling priority of `pid` (`proc_pidinfo` PROC_PIDTASKINFO); nil when it cannot be read.
    public static func pri(of pid: pid_t) -> Int32? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return nil }
        return info.pti_priority
    }

    public static func name(_ q: qos_class_t) -> String {
        switch q {
        case QOS_CLASS_USER_INTERACTIVE: "user-interactive"
        case QOS_CLASS_USER_INITIATED: "user-initiated"
        case QOS_CLASS_DEFAULT: "default"
        case QOS_CLASS_UTILITY: "utility"
        case QOS_CLASS_BACKGROUND: "background"
        default: "unspecified"
        }
    }

    /// What it means, for doctor (nil: not clamped). `who`: "doz" or "the host".
    public func warning(_ who: String, pid: pid_t) -> String? {
        guard clamped else { return nil }
        var why: [String] = []
        if background { why.append("background priority") }
        if qos == "background" { why.append("background QoS") }
        let p = pri.map { " (pri \($0))" } ?? ""
        return "\(who) runs at \(why.joined(separator: ", "))\(p) — it and everything it starts run slowly; start it from a normal terminal, or move it out: taskpolicy -B -p \(pid)"
    }

    /// The host's own start: leave a Darwin background state it inherited from the client that started it (a wake from
    /// it would crawl). Returns true when it was in one and is no longer.
    @discardableResult
    public static func liftInheritedBackground() -> Bool {
        guard getpriority(PRIO_DARWIN_PROCESS, 0) > 0 else { return false }
        return setpriority(PRIO_DARWIN_PROCESS, 0, 0) == 0 && getpriority(PRIO_DARWIN_PROCESS, 0) <= 0
    }
}
