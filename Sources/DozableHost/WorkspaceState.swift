import DozableKit
import Foundation

/// A workspace's lifecycle state — derived from what its agents are doing, except finished and archived, which are
/// recorded (`WorkspaceFlags`), and setting up (never started and never had a running agent). ONE pure function (`derive`), table-tested
/// (`WorkspaceStateTests`). Who drives it sits beside the state (always "you" in this version): `setting up · you`.
/// The JSON value is the raw value (`setting-up`); a person reads `words`.
public enum WorkspaceState: String, Codable, Equatable, Sendable, CaseIterable {
    case archived, finished
    case settingUp = "setting-up"
    case starting
    case waitingOnYou = "waiting-on-you"
    case working, idle, asleep
    /// 762 (F3): nothing runs because a `doz workspace stop` stopped it (`Input.stopped`) — not asleep: `wake` or `start`
    /// brings every agent back.
    case stopped

    /// As a person reads it: "setting up", "waiting on you".
    public var words: String { rawValue.replacingOccurrences(of: "-", with: " ") }

    /// What one agent is doing, as the daemon sees it (never a guest call).
    public enum Agent: Equatable, Sendable {
        /// A sandbox booting.
        case starting
        /// Running, with each session's program state (`ProgramStatus.State` words; none known: idle).
        case running(sessions: [String])
        /// Paused, asleep, hibernated, off, an ended session, or gone.
        case asleep
        /// A sandbox that failed, or a session whose program ended in error.
        case failed
        /// A manager recorded but never started (no session or sandbox yet).
        case notStarted
    }

    public struct Input: Equatable, Sendable {
        public var agents: [Agent]
        public var flags: WorkspaceFlags
        /// Open Asks addressed to you (none until Asks exist).
        public var openAsksForYou: Int
        /// `doz workspace start` is under way for it.
        public var starting: Bool
        /// 762 (F3): what last put it down was a stop (`doz workspace stop`), not a sleep — the log's newest workspace-wide
        /// change (`HostCore.lastDownWasStop`). Nothing running then reads stopped, not asleep.
        public var stopped: Bool
        public init(agents: [Agent], flags: WorkspaceFlags = WorkspaceFlags(), openAsksForYou: Int = 0, starting: Bool = false,
                    stopped: Bool = false) {
            self.agents = agents; self.flags = flags; self.openAsksForYou = openAsksForYou; self.starting = starting; self.stopped = stopped
        }
    }

    /// archived → finished → starting (`doz workspace start` under way) → setting up (never started and never had a running agent: `startedAt` and `firstAgentAt` both
    /// nil — a recorded manager is `notStarted`) → starting (a sandbox booting) → waiting on you (a
    /// session blocked or in error, a sandbox failed, an open Ask for you) → working → idle → asleep (a manager stopped, its
    /// sandbox stopped, or no agent at all once started) — or, 762, stopped when a `doz workspace stop` put it down
    /// (`Input.stopped`). The first that holds wins. A `notStarted` agent counts as asleep.
    public static func derive(_ i: Input) -> WorkspaceState {
        if i.flags.archivedAt != nil { return .archived }
        if i.flags.finishedAt != nil { return .finished }
        if i.starting { return .starting }
        if i.flags.startedAt == nil && i.flags.firstAgentAt == nil { return .settingUp }
        if i.agents.contains(.starting) { return .starting }
        let sessions = i.agents.flatMap { if case .running(let s) = $0 { return s } else { return [] } }
        if i.openAsksForYou > 0 || i.agents.contains(.failed) || sessions.contains("blocked") || sessions.contains("error") {
            return .waitingOnYou
        }
        if sessions.contains("working") { return .working }
        if i.agents.contains(where: { if case .running = $0 { return true } else { return false } }) { return .idle }
        return i.stopped ? .stopped : .asleep
    }

    /// A sandbox as an agent: from its phase and the statuses the daemon holds.
    public static func agent(phase: String, statuses: [SessionStatus]?) -> Agent {
        switch Phase(rawValue: phase) {
        case .booting?: return .starting
        case .running?: return .running(sessions: (statuses ?? []).map { $0.state.rawValue })
        case .failed?: return .failed
        default: return .asleep
        }
    }

    /// A worker (`doz worker add`) as an agent: one being added is starting; an ended one is no agent at all (nil);
    /// otherwise what its place says (`place`: its session's row, or its sandbox with ONLY its own session's status).
    public static func worker(pending: Bool, ended: Bool, place: Agent) -> Agent? {
        if ended { return nil }
        if pending { return .starting }
        return place
    }

    /// What one agent's program is doing, as the dashboard says it: `blocked` or `error` before `working`, then `idle`; a
    /// failed sandbox is `error`; nil when it does not run (starting, asleep, not started, or no agent).
    public static func activity(_ a: Agent?) -> String? {
        switch a {
        case .running(let s)?:
            for w in ["blocked", "error", "working"] where s.contains(w) { return w }
            return "idle"
        case .failed?: return "error"
        default: return nil
        }
    }

    /// The agents working now, by name (`WorkspaceRow.working`): those whose activity is `working`.
    public static func working(_ rows: [WorkspaceAgentRow]) -> [String] { rows.filter { $0.activity == "working" }.map(\.name) }

    /// A session on this Mac as an agent (nil row: its record is gone).
    public static func agent(macRow row: SessionRow?) -> Agent {
        guard let row, row.gone != true else { return .asleep }
        if row.ended { return row.status?.state == .error ? .failed : .asleep }
        return .running(sessions: [row.status?.state.rawValue ?? "idle"])
    }
}
