import ArgumentParser
import Foundation
import DozableHost

// The work description: a workspace's brief plus its addenda. `doz workspace retro W [RUN] --propose --addendum TEXT`
// proposes a lesson (its Ask goes to you in the workspace's room), `doz workspace decide W PROPOSAL apply|decline` decides
// one, `doz workspace proposals W` lists them; `doz workspace edit W --addendum TEXT` (WorkspaceCommands.swift) adds one
// directly. Each is the owner's, or an agent's holding description.propose, .decide or .edit.

struct WorkspaceRetroCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "retro", abstract: "Propose a lesson from a run for the work description.",
        discussion: """
        A retrospective looks back at a run. --propose --addendum TEXT proposes adding TEXT to the work description (the \
        brief's addenda): nothing changes until it is decided. Dozable asks you in the workspace's room ("Apply this \
        lesson to the work description?"): answer Apply or decline there, in the dashboard, with doz chat decide, or with \
        doz workspace decide W PROPOSAL apply|decline. RUN is the run it comes from (default: the last one, closed or \
        open). An applied lesson is part of every later run with no goal of its own. --json answers {kind: \
        WorkspaceProposal, id, workspace, origin: retro, state: open, change: {addendum}, by, at, source: {run}, askId}. \
        An agent acting with --as W/AGENT needs the permission description.propose (the role reviewer has it: doz grant \
        AGENT reviewer --in W). Exit codes: 0 · 2 no such workspace or run · 3 no run yet · 9 not permitted · 64 usage · \
        65 the addendum is empty or too long.
        """)
    @OptionGroup var g: GlobalOptions
    @Argument(help: "The workspace.") var name: String
    @Argument(help: "The run it looks back at (default: the last one).") var run: String?
    @Flag(name: .customLong("propose"), help: "Propose a change to the work description (an Ask to you).") var propose = false
    @Option(name: .customLong("addendum"), help: "The lesson or note to add to the work description.") var addendum: String?

    func run() async throws {
        guard propose, let text = addendum else {
            throw fail(HostError(.usage, "doz workspace retro W [RUN] --propose --addendum TEXT — a proposal is what a retrospective makes for now"), g)
        }
        var w = WorkspaceRequest(name: name)
        w.run = run
        w.addendum = text
        let p = try decode(try call(workspaceRequest(.workspaceRetro, w), g), WorkspaceProposal.self, g)
        if g.json { Out.json(p); return }
        Out.stdout(proposalText(p, verb: "proposed"))
    }
}

struct WorkspaceDecideCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "decide", abstract: "Apply or decline a proposal to the work description.",
        discussion: """
        apply adds the proposal's lesson to the work description (the brief's addenda, from its run, by who proposed it); \
        decline changes nothing. Its Ask in the room closes with the outcome. A proposal is decided once: one already \
        applied or declined — in chat or here — is refused (exit 3, proposal-decided). doz workspace proposals W lists \
        them. An agent acting with --as W/AGENT needs the permission description.decide (its own proposals too). Exit \
        codes: 0 · 2 no such workspace or proposal · 3 decided already · 9 not permitted · 65 not apply or decline.
        """)
    @OptionGroup var g: GlobalOptions
    @Argument(help: "The workspace.") var name: String
    @Argument(help: "The proposal (pr-…: doz workspace proposals W).") var proposal: String
    @Argument(help: "apply or decline.") var decision: String

    func run() async throws {
        var w = WorkspaceRequest(name: name)
        w.proposal = proposal
        w.decision = decision
        let p = try decode(try call(workspaceRequest(.workspaceDecide, w), g), WorkspaceProposal.self, g)
        if g.json { Out.json(p); return }
        Out.stdout(proposalText(p, verb: p.state))
    }
}

struct WorkspaceProposalsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "proposals", abstract: "A workspace's proposals to change its work description.",
        discussion: """
        Every proposal, oldest first: open, applied or declined, who made it, from which run, and how it was decided (its \
        Ask answered in chat, doz workspace decide, or the Ask expired — declined). --json answers {kind: \
        WorkspaceProposals, workspace, proposals}. Looking never starts the daemon.
        """)
    @OptionGroup var g: GlobalOptions
    @Argument(help: "The workspace.") var name: String

    func run() async throws {
        let l = try decode(try await query(workspaceRequest(.workspaceProposals, WorkspaceRequest(name: name)), g), WorkspaceProposals.self, g)
        if g.json { Out.json(l); return }
        if l.proposals.isEmpty { Out.stdout("\(l.workspace): no proposals\n"); return }
        var t = [["PROPOSAL", "STATE", "BY", "RUN", "LESSON"]]
        for p in l.proposals {
            let lesson = p.change.addendum.split(separator: "\n").first.map(String.init) ?? ""
            t.append([p.id, p.state + (p.decidedHow.map { " (\($0))" } ?? ""), p.by, p.source.run ?? "—",
                      lesson.count > 60 ? String(lesson.prefix(59)) + "…" : lesson])
        }
        Out.stdout(Out.table(t))
    }
}

func proposalText(_ p: WorkspaceProposal, verb: String) -> String {
    var s = "\(p.workspace): proposal \(p.id) \(verb)"
    if p.state == "open" {
        s += p.askNumber.map { " — your Ask #\($0) is in \(p.room ?? "the room")" } ?? ""
    }
    s += "\n  \(p.change.addendum.split(separator: "\n").first.map(String.init) ?? "")\n"
    for n in p.notes ?? [] { s += "note: \(n)\n" }
    return s
}
