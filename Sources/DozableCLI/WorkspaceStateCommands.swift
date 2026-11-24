import ArgumentParser
import DozableChat
import DozableHost
import Foundation

// `doz workspace state W [--json]`: what is true about a workspace now — for EVERY workspace (751): one made from a space file
// beside what its file says, any other from its record — each thing with its state, each agent's condition, what is there but
// not in the file, and what waits for you (`workspace-state`). Read from the store and, while one runs, the daemon: looking
// never starts it (then every state is "not known").

struct WorkspaceStateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "state", abstract: "What is true about a workspace now: each thing, each agent's condition.",
        discussion: """
        For every workspace: each agent (and its chat member), sandbox, folder and room with its state now (running, asleep, \
        gone, missing, not known), each agent's condition (running, asleep, stopped, crashed, not started — with why), and \
        what waits for you (a permission prompt, a crash, a failed sandbox, an open ask). For a workspace made from a space \
        file, each thing the file declares, what the workspace or the chat server holds that the file does not name, and an \
        up that stopped at a failure. Never a chat message's text. With no daemon running none is started: every state is \
        then "not known". --json is {kind: WorkspaceState, schema: 1, …the document the dashboard's space view reads, with \
        its sha, from, agents: {NAME: {condition, reason, role, place, since}}, conditions: {ready, allocated, hot, run, archived}, \
        places: [{name, isolation, view, network, credentials, sessions: [{identity, session, state, fence}]}] — a fenced \
        place gives each session a fence of its own —, revision}; a workspace \
        that does not exist exits 2 (not-found).
        """)
    @OptionGroup var g: GlobalOptions
    @Argument(help: "The workspace.") var name: String

    func run() async throws {
        var req = WorkspaceRequest(name: name)
        req.withConditions = true
        let s = try decode(try await query(workspaceRequest(.workspaceState, req), g), SpaceState.self, g)
        if g.json {
            Out.stdout(String(decoding: ChatJSON.encodeIndented(s.stateAnswer(), indent: "  "), as: UTF8.self) + "\n")
            return
        }
        Out.stdout(spaceStateText(s))
    }
}

func spaceStateText(_ s: SpaceState) -> String {
    let fromRecord = s.agentConditions?.from == "record"
    var out = (fromRecord ? "workspace" : "space") + " \(s.space) on \(s.host)"
    if let r = s.run { out += " · run \(r.id) (\(r.phase))" }
    out += s.factsKnown ? "\n" : "\n  no daemon is running: every state is not known (none was started)\n"
    func rows(_ items: [SpaceState.Item]) -> String {
        var t: [[String]] = [["  TYPE", "NAME", "LIFETIME", "STATE", "NOTE"]]
        for i in items {
            var state = i.state == "unknown" ? "not known" : i.state
            if let a = i.activity, a != "unknown", i.state == "running" { state += " · \(a)" }
            var note = i.detail ?? ""
            if let d = i.drift { note += (note.isEmpty ? "" : "; ") + d.text }
            t.append(["  " + i.type, DisplayPath.tilde(i.subject), i.lifetime, state, note])
        }
        return Out.table(t)
    }
    out += rows(s.items)
    if !s.extras.isEmpty { out += "not in the file:\n" + rows(s.extras) }
    if let c = s.agentConditions, !c.agents.isEmpty {
        var t: [[String]] = [["  AGENT", "ROLE", "PLACE", "CONDITION", "WHY"]]
        for k in c.agents.keys.sorted() {
            let a = c.agents[k]!
            t.append(["  " + k, a.role, a.place, a.condition == "unknown" ? "not known" : a.condition.replacingOccurrences(of: "-", with: " "), a.reason ?? ""])
        }
        out += "agents" + (c.ready ? " (every one running)" : "") + ":\n" + Out.table(t)
    }
    if !s.attention.isEmpty {
        out += "waiting for you:\n"
        for a in s.attention { out += "  \(a.kind): \(a.text)\n" }
    }
    out += "sha \(s.sha)\n"
    return out
}
