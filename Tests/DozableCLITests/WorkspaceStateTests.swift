import DozableKit
import Foundation
import XCTest
@testable import DozableHost

/// `WorkspaceState.derive`: the table, and each pair of neighbours in the order (the earlier one wins).
final class WorkspaceStateTests: XCTestCase {
    typealias S = WorkspaceState
    let t = Date(timeIntervalSince1970: 1_800_000_000)

    func testTheTable() {
        let had = WorkspaceFlags(firstAgentAt: t)
        let rows: [(S.Input, S, String)] = [
            (S.Input(agents: []), .draft, "no agents, never had one"),
            (S.Input(agents: [], flags: had), .asleep, "empty, but once had agents"),
            (S.Input(agents: [.starting]), .starting, "a sandbox booting"),
            (S.Input(agents: [.running(sessions: ["blocked"])]), .waitingOnYou, "a session blocked"),
            (S.Input(agents: [.running(sessions: ["error"])]), .waitingOnYou, "a session in error"),
            (S.Input(agents: [.failed]), .waitingOnYou, "a sandbox failed"),
            (S.Input(agents: [.asleep], openAsksForYou: 1), .waitingOnYou, "an open Ask for you"),
            (S.Input(agents: [.running(sessions: ["working"])]), .working, "a program working"),
            (S.Input(agents: [.running(sessions: [])]), .idle, "running, no status"),
            (S.Input(agents: [.running(sessions: ["idle", "done"])]), .idle, "running, idle and done"),
            (S.Input(agents: [.asleep, .asleep]), .asleep, "every agent asleep"),
            (S.Input(agents: [.running(sessions: ["working"])], flags: WorkspaceFlags(finishedAt: t)), .finished, "finished"),
            (S.Input(agents: [.running(sessions: ["working"])], flags: WorkspaceFlags(finishedAt: t, archivedAt: t)), .archived, "archived"),
        ]
        for (input, want, why) in rows { XCTAssertEqual(S.derive(input), want, why) }
    }

    /// Precedence: archived > finished > draft > starting > waiting on you > working > idle > asleep.
    func testPrecedencePairs() {
        XCTAssertEqual(S.derive(S.Input(agents: [], flags: WorkspaceFlags(finishedAt: t, archivedAt: t))), .archived)
        XCTAssertEqual(S.derive(S.Input(agents: [], flags: WorkspaceFlags(finishedAt: t))), .finished, "finished over draft")
        XCTAssertEqual(S.derive(S.Input(agents: [.starting, .failed])), .starting, "starting over waiting on you")
        XCTAssertEqual(S.derive(S.Input(agents: [.failed, .running(sessions: ["working"])])), .waitingOnYou, "waiting over working")
        XCTAssertEqual(S.derive(S.Input(agents: [.running(sessions: ["working"]), .running(sessions: ["idle"])])), .working, "working over idle")
        XCTAssertEqual(S.derive(S.Input(agents: [.running(sessions: []), .asleep])), .idle, "idle over asleep")
        XCTAssertEqual(S.allCases.map(\.rawValue), ["archived", "finished", "draft", "starting", "waiting on you", "working", "idle", "asleep"])
    }

    /// The agents as the daemon sees them.
    func testAgentsFromPhasesAndRows() {
        XCTAssertEqual(S.agent(phase: "booting", statuses: nil), .starting)
        XCTAssertEqual(S.agent(phase: "running", statuses: [SessionStatus(session: "a", state: .working)]), .running(sessions: ["working"]))
        XCTAssertEqual(S.agent(phase: "failed", statuses: nil), .failed)
        for p in ["off", "paused", "asleep", "hibernated"] { XCTAssertEqual(S.agent(phase: p, statuses: nil), .asleep, p) }
        XCTAssertEqual(S.agent(macRow: nil), .asleep, "a pruned record")
        var row = SessionRow(SessionInfo(name: "s", pid: 1, command: "sh"))
        XCTAssertEqual(S.agent(macRow: row), .running(sessions: ["idle"]))
        row.status = SessionStatus(session: "s", state: .blocked)
        XCTAssertEqual(S.agent(macRow: row), .running(sessions: ["blocked"]))
        row.gone = true
        XCTAssertEqual(S.agent(macRow: row), .asleep)
    }
}
