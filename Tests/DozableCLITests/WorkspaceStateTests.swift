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
        let started = WorkspaceFlags(startedAt: t)
        let rows: [(S.Input, S, String)] = [
            (S.Input(agents: []), .settingUp, "no agents, never had one"),
            (S.Input(agents: [], flags: had), .asleep, "empty, but once had a running agent"),
            (S.Input(agents: [.starting], flags: had), .starting, "a sandbox booting"),
            (S.Input(agents: [.running(sessions: ["blocked"])], flags: had), .waitingOnYou, "a session blocked"),
            (S.Input(agents: [.running(sessions: ["error"])], flags: had), .waitingOnYou, "a session in error"),
            (S.Input(agents: [.failed], flags: had), .waitingOnYou, "a sandbox failed"),
            (S.Input(agents: [.asleep], flags: had, openAsksForYou: 1), .waitingOnYou, "an open Ask for you"),
            (S.Input(agents: [.running(sessions: ["working"])], flags: had), .working, "a program working"),
            (S.Input(agents: [.running(sessions: [])], flags: had), .idle, "running, no status"),
            (S.Input(agents: [.running(sessions: ["idle", "done"])], flags: had), .idle, "running, idle and done"),
            (S.Input(agents: [.asleep, .asleep], flags: had), .asleep, "every agent asleep"),
            // The manager.
            (S.Input(agents: [.notStarted]), .settingUp, "a recorded manager before the start"),
            (S.Input(agents: [.notStarted], starting: true), .starting, "its start under way"),
            (S.Input(agents: [.running(sessions: ["blocked"])], flags: started), .waitingOnYou, "the manager blocked: waiting on you"),
            (S.Input(agents: [.running(sessions: ["working"])], flags: started), .working, "the manager working"),
            (S.Input(agents: [.running(sessions: ["idle"])], flags: started), .idle, "the manager idle"),
            (S.Input(agents: [.asleep], flags: started), .asleep, "the manager stopped"),
            (S.Input(agents: [.notStarted], flags: started), .asleep, "started, the manager never came up"),
            (S.Input(agents: [], flags: started), .asleep, "started with no agents (you drive)"),
            (S.Input(agents: [.asleep]), .settingUp, "adopting an agent that does not run: still setting up"),
            (S.Input(agents: [.running(sessions: ["working"])], flags: WorkspaceFlags(finishedAt: t)), .finished, "finished"),
            (S.Input(agents: [.running(sessions: ["working"])], flags: WorkspaceFlags(finishedAt: t, archivedAt: t)), .archived, "archived"),
        ]
        for (input, want, why) in rows { XCTAssertEqual(S.derive(input), want, why) }
    }

    /// Precedence: archived > finished > setting up > starting > waiting on you > working > idle > asleep.
    func testPrecedencePairs() {
        XCTAssertEqual(S.derive(S.Input(agents: [], flags: WorkspaceFlags(finishedAt: t, archivedAt: t))), .archived)
        XCTAssertEqual(S.derive(S.Input(agents: [], flags: WorkspaceFlags(finishedAt: t))), .finished, "finished over setting up")
        let had = WorkspaceFlags(firstAgentAt: t)
        XCTAssertEqual(S.derive(S.Input(agents: [], flags: WorkspaceFlags(finishedAt: t), starting: true)), .finished, "finished over a start")
        XCTAssertEqual(S.derive(S.Input(agents: [], starting: true)), .starting, "a start under way over setting up")
        XCTAssertEqual(S.derive(S.Input(agents: [.starting, .failed], flags: had)), .starting, "starting over waiting on you")
        XCTAssertEqual(S.derive(S.Input(agents: [.failed, .running(sessions: ["working"])], flags: had)), .waitingOnYou, "waiting over working")
        XCTAssertEqual(S.derive(S.Input(agents: [.running(sessions: ["working"]), .running(sessions: ["idle"])], flags: had)), .working, "working over idle")
        XCTAssertEqual(S.derive(S.Input(agents: [.running(sessions: []), .asleep], flags: had)), .idle, "idle over asleep")
        XCTAssertEqual(S.allCases.map(\.rawValue), ["archived", "finished", "setting-up", "starting", "waiting-on-you", "working", "idle", "asleep"])
        XCTAssertEqual(S.settingUp.words, "setting up")
        XCTAssertEqual(S.waitingOnYou.words, "waiting on you")
    }

    /// Workers: one being added is starting; a running one counts by its own session; an ended one is no agent; a stopped
    /// sandbox or an ended session is asleep.
    func testWorkers() {
        let started = WorkspaceFlags(startedAt: t)
        let working = S.Agent.running(sessions: ["working"])
        XCTAssertEqual(S.worker(pending: true, ended: false, place: .asleep), .starting)
        XCTAssertNil(S.worker(pending: false, ended: true, place: working), "an ended worker is not an agent")
        XCTAssertEqual(S.worker(pending: false, ended: false, place: working), working)
        let rows: [([S.Agent?], S, String)] = [
            ([S.worker(pending: true, ended: false, place: .asleep)], .starting, "a worker being added"),
            ([S.worker(pending: false, ended: false, place: working)], .working, "no manager, one working worker: working · you"),
            ([S.worker(pending: false, ended: false, place: .running(sessions: ["blocked"]))], .waitingOnYou, "a worker blocked"),
            ([S.worker(pending: false, ended: true, place: working)], .asleep, "every worker ended, no manager: asleep"),
            ([.asleep, S.worker(pending: false, ended: false, place: .asleep)], .asleep, "a stopped manager, a worker's sandbox stopped"),
            ([.asleep, S.worker(pending: false, ended: false, place: .running(sessions: ["idle"]))], .idle, "a stopped manager, a worker idle"),
        ]
        for (agents, want, why) in rows {
            XCTAssertEqual(S.derive(S.Input(agents: agents.compactMap { $0 }, flags: started)), want, why)
        }
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
