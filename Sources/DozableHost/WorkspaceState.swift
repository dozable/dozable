import DozableKit
import Foundation

/// A workspace's lifecycle state — derived from what its agents are doing, except finished and archived, which are
/// recorded (`WorkspaceFlags`), and setting up (no agent yet, never started). ONE pure function (`derive`), table-tested
/// (`WorkspaceStateTests`). Who drives it sits beside the state (always "you" in this version): `setting up · you`.
/// The JSON value is the raw value (`setting-up`); a person reads `words`.
public enum WorkspaceState: String, Codable, Equatable, Sendable, CaseIterable {
    case archived, finished
    case settingUp = "setting-up"
    case starting
    case waitingOnYou = "waiting-on-you"
    case working, idle, asleep

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
    }

    public struct Input: Equatable, Sendable {
        public var agents: [Agent]
        public var flags: WorkspaceFlags
        /// Open Asks addressed to you (none until Asks exist).
        public var openAsksForYou: Int
        public init(agents: [Agent], flags: WorkspaceFlags = WorkspaceFlags(), openAsksForYou: Int = 0) {
            self.agents = agents; self.flags = flags; self.openAsksForYou = openAsksForYou
        }
    }

    /// archived → finished → setting up (no agents, never had one) → starting → waiting on you (a session blocked or in error,
    /// a sandbox failed, an open Ask for you) → working → idle → asleep. The first that holds wins.
    public static func derive(_ i: Input) -> WorkspaceState {
        if i.flags.archivedAt != nil { return .archived }
        if i.flags.finishedAt != nil { return .finished }
        if i.agents.isEmpty && i.flags.firstAgentAt == nil { return .settingUp }
        if i.agents.contains(.starting) { return .starting }
        let sessions = i.agents.flatMap { if case .running(let s) = $0 { return s } else { return [] } }
        if i.openAsksForYou > 0 || i.agents.contains(.failed) || sessions.contains("blocked") || sessions.contains("error") {
            return .waitingOnYou
        }
        if sessions.contains("working") { return .working }
        if i.agents.contains(where: { if case .running = $0 { return true } else { return false } }) { return .idle }
        return .asleep
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

    /// A session on this Mac as an agent (nil row: its record is gone).
    public static func agent(macRow row: SessionRow?) -> Agent {
        guard let row, row.gone != true else { return .asleep }
        if row.ended { return row.status?.state == .error ? .failed : .asleep }
        return .running(sessions: [row.status?.state.rawValue ?? "idle"])
    }
}
