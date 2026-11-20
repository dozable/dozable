import ArgumentParser
import DozableChat
import DozableHost
import Foundation

// `doz workspace state W [--json]`: what is true about a space workspace beside what its file says — each thing the file
// declares with its state, what is there but not in the file, and what waits for you (`workspace-state`). Read from the
// store and, while one runs, the daemon: looking never starts it (then every state is "not known").

struct WorkspaceStateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "state", abstract: "What is true about a space workspace beside what its file says.",
        discussion: """
        For a workspace made from a space file: each agent, member, service, sandbox, folder and room the file declares with \
        its state now (running, asleep, gone — removed by down, as it should be —, missing, not known), what the workspace or \
        the chat server holds that the file does not name, and what waits for you (a permission prompt, a failed sandbox, \
        an up that stopped at a failure). Never a chat message's text. With no daemon running none is started: every state \
        is then "not known". --json is the document the dashboard's space view reads, with its sha.
        """)
    @OptionGroup var g: GlobalOptions
    @Argument(help: "The workspace.") var name: String

    func run() async throws {
        let s = try decode(try await query(workspaceRequest(.workspaceState, WorkspaceRequest(name: name)), g), SpaceState.self, g)
        if g.json {
            Out.stdout(String(decoding: ChatJSON.encodeIndented(s.ordered(), indent: "  "), as: UTF8.self) + "\n")
            return
        }
        Out.stdout(spaceStateText(s))
    }
}

func spaceStateText(_ s: SpaceState) -> String {
    var out = "space \(s.space) on \(s.host)"
    if let r = s.run { out += " · run \(r.id) (\(r.phase))" }
    out += s.factsKnown ? "\n" : "\n  no daemon is running: every state is not known (none was started)\n"
    func rows(_ items: [SpaceState.Item]) -> String {
        var t: [[String]] = [["  TYPE", "NAME", "LIFETIME", "STATE", "NOTE"]]
        for i in items {
            var state = i.state == "unknown" ? "not known" : i.state
            if let a = i.activity, a != "unknown", i.state == "running" { state += " · \(a)" }
            var note = i.detail ?? ""
            if let d = i.drift { note += (note.isEmpty ? "" : "; ") + d.text }
            t.append(["  " + i.type, i.subject, i.lifetime, state, note])
        }
        return Out.table(t)
    }
    out += rows(s.items)
    if !s.extras.isEmpty { out += "not in the file:\n" + rows(s.extras) }
    if !s.attention.isEmpty {
        out += "waiting for you:\n"
        for a in s.attention { out += "  \(a.kind): \(a.text)\n" }
    }
    out += "sha \(s.sha)\n"
    return out
}
