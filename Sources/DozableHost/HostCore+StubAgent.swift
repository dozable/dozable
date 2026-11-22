import Foundation

// 749 (WS.02): the test hooks inside Dozable — the stub agent in place of a workspace agent's program on this Mac (guarded
// runs with DOZ_TEST_STUB_AGENT=1 only; `StubAgent`), and the two log lines every workspace gets: `<name> joined` (an agent
// became a member of the main room) and `<name> crashed: exit <code>` (its program on this Mac exited non-zero, no end asked).
// docs/engineering/workspaces.md ("Test hooks").
extension HostCore {
    /// The program a workspace agent on this Mac is opened with: the plan's, or — under the stub — `doz debug stub-agent`
    /// (this doz, the one file a fence may read and run), its environment marked, and no Claude account (it is not Claude).
    func agentMacProgram(argv: [String], environment: [String: String], account: String?, workspace w: String, name: String,
                         task: String?) -> (argv: [String], environment: [String: String], account: String?) {
        guard TestSafety.stubAgent() else { return (argv, environment, account) }
        let room = (try? workspaceRecord(w))?.mainRoom?.chatRoom
        let doz = MacFencePaths.resolve(HostLauncher.executablePath) ?? HostLauncher.executablePath
        return (StubAgent.argv(doz: doz, name: name, room: room, task: task),
                StubAgent.environment(environment, resumed: false), nil)
    }

    /// The environment of a re-open (a wake, a start after a stop): under the stub, marked as resumed.
    func agentMacReopenEnvironment(_ environment: [String: String]) -> [String: String] {
        TestSafety.stubAgent() ? StubAgent.environment(environment, resumed: true) : environment
    }

    /// A VM manager or worker under the stub: refused before anything is made.
    func stubVMRefusal(_ who: String, isolation: ManagerIsolation) -> HostError? {
        isolation == .vm && TestSafety.stubAgent() ? StubAgent.vmRefusal(who) : nil
    }

    /// `<name> joined`: `agent` is a member of `w`'s main room now (it was invited, or made one).
    func logAgentJoined(_ w: String, agent: String, room: String) {
        try? workspaces.append(w, WorkspaceLogEntry(by: "doz", action: "agent-joined", agent: agent, room: room))
    }

    /// A program on this Mac ended (its status watcher saw it): a workspace agent's that exited non-zero when no end was asked
    /// is its crash — `<name> crashed: exit <code>` in its workspace's log, and a line in the daemon's.
    func macProgramEnded(_ session: String, exitCode: Int32?) async {
        let asked = await mac.takeRequestedEnd(session)
        guard !asked, let code = exitCode, code != 0 else { return }
        let key = "mac:" + session
        for rec in workspaces.records() {
            guard let a = rec.agents.last(where: { $0.place.key == key && $0.endedAt == nil && $0.pendingAt == nil }) else { continue }
            var e = WorkspaceLogEntry(by: "doz", action: "agent-crashed", agent: a.name, place: key)
            e.exitCode = Int(code)
            try? workspaces.append(rec.name, e)
            note(nil, "workspace \(rec.name): \(a.name) crashed: exit \(code)")
            return
        }
    }
}
