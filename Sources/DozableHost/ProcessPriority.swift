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

    /// 788: at the utility QoS (or, read only by its priority, at pri 20 or below) without being clamped to background —
    /// macOS then runs it mostly on the efficiency cores. Kept apart from `clamped`: utility is ordinary for a tool, but
    /// not for the daemon or a session a person's agent works in (a launchd `Standard` daemon held every session at 20).
    public var belowNormal: Bool {
        guard !clamped else { return false }
        // The QoS is the reading thread's; the priority is the task's — either says it.
        return qos == "utility" || (pri.map { $0 <= Self.utilityPri } ?? false)
    }

    /// The scheduling priority of a task at the utility QoS (`ps -o pri`: 20; 31 normally, 4 under background).
    public static let utilityPri: Int32 = 20

    /// 788: doctor's words for `belowNormal` (nil: it is not). `who`: "doz", "the daemon".
    public func utilityWarning(_ who: String) -> String? {
        guard belowNormal else { return nil }
        let p = pri.map { " (pri \($0))" } ?? ""
        return "\(who) runs at utility QoS\(p) — mostly the efficiency cores, so it and everything it starts run slower than from a terminal"
    }

    /// 788: doctor's words for held sessions whose programs run at pri 20 or below (nil: none do). `pris`: session → pri.
    public static func heldSessionsWarning(_ pris: [String: Int32]) -> String? {
        let low = pris.filter { $0.value <= utilityPri }.keys.sorted()
        guard !low.isEmpty else { return nil }
        let names = low.prefix(3).joined(separator: ", ") + (low.count > 3 ? " and \(low.count - 3) more" : "")
        let lowest = pris.values.min().map { "pri \($0)" } ?? ""
        return "\(low.count == 1 ? "a session" : "\(low.count) sessions") on this Mac (\(names)) run\(low.count == 1 ? "s" : "") at utility QoS or below (\(lowest)) — mostly the efficiency cores, so the agent's builds and tests run slower than from a terminal; restart the daemon from a normal terminal (doz daemon stop, then any doz command), then the session"
    }

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

    /// 788: the daemon's start: when the calling thread runs at the utility or background QoS (inherited from a launchd
    /// job or a `taskpolicy -c utility` parent), ask for user-initiated. Best effort — a clamp on the process wins and the
    /// call then changes nothing. Returns true when it was below and no longer is.
    @discardableResult
    public static func liftInheritedUtility() -> Bool {
        let before = qos_class_self()
        guard before == QOS_CLASS_UTILITY || before == QOS_CLASS_BACKGROUND else { return false }
        guard pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0) == 0 else { return false }
        let after = qos_class_self()
        return after != QOS_CLASS_UTILITY && after != QOS_CLASS_BACKGROUND
    }
}
