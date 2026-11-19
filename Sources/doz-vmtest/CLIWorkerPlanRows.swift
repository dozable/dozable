import Darwin
import Foundation
import DozableKit
import DozableHost

// `make test-cli-workspace`, adding a worker with a look first (after rows 1–44, in the same scratch store: wk started,
// chat on, the participant pat):
//
//  45. worker add wk --task … --dry-run: exit 0, the plan's lines, and the command printed exactly as --json's `command`;
//      nothing changes — worker ls --all --json, chat who and the sessions on this Mac as they were
//  46. a refused dry run (NAME a participant) gives the real add's code and sentence
//  47. the daemon stopped: the dry run answers (the checks that need a daemon "checked again when you add"), changes
//      nothing, and starts no daemon
func cliWorkerPlanRows(_ h: CLIHarness, root: URL, store: DozableStore) {
    print("cli: adding a worker — the dry run and the one command source")
    func state() -> String {
        h.run(["worker", "ls", "wk", "--all", "--json"]).out + h.run(["chat", "who"]).out
            + h.sessions("@mac").map { "\($0.name):\($0.ended)" }.sorted().joined(separator: ",")
    }

    // 45. the dry run, the daemon running
    h.run(["chat", "on", "--name", "ada"], timeout: 60)
    let before = state()
    let args = ["worker", "add", "wk", "--task", "check the plan's words", "--dry-run"]
    let r = h.run(args, timeout: 60)
    let plan = h.json(args, WorkerPlan.self)
    check(r.code == 0 && plan?.problem == nil && r.out.contains("worker \(plan?.name ?? "?") in wk") && r.out.contains("control: proxy · placeholders · guard"),
          "45 worker add --dry-run: the plan's lines, exit 0 (\(r.code) \(r.out.prefix(300)) \(r.err.prefix(200)))")
    check(plan.map { r.out.hasSuffix("The command:\n" + $0.command + "\n") } == true && plan?.command.hasPrefix("doz worker add wk --task ") == true,
          "45 …and the command exactly as --json's (\(plan?.command ?? "?"))")
    check(state() == before, "45 …nothing changes: worker ls, chat who, the sessions on this Mac")

    // 46. refused: the real add's code and sentence
    let rj = h.run(["worker", "add", "wk", "pat", "--task", "x", "--dry-run", "--json"], timeout: 60)
    let refused = try? HostWire.decoder.decode(WorkerPlan.self, from: rj.outData)
    let dry = h.run(["worker", "add", "wk", "pat", "--task", "x", "--dry-run"], timeout: 60)
    let real = h.run(["worker", "add", "wk", "pat", "--task", "x"], timeout: 60)
    check(dry.code == 4 && real.code == 4 && refused?.problem?.field == "name" && refused.map { real.err.contains($0.problem?.text ?? "~") } == true
          && dry.out.contains("It cannot be added: " + (refused?.problem?.text ?? "~")),
          "46 a refused dry run: the add's code and sentence, beside its field (\(dry.code), \(real.code), \(refused?.problem?.text ?? "?"))")

    // 47. the daemon stopped
    h.run(["daemon", "stop"], timeout: 60)
    _ = h.waitFor(20) { !h.hostRunning }
    let rec = try? Data(contentsOf: URL(fileURLWithPath: WorkspaceStore(store: store).folder("wk") + "/workspace.json"))
    let off = h.run(["worker", "add", "wk", "--task", "x", "--dry-run"], timeout: 60)
    check(off.code == 0 && off.out.contains("checked again when you add") && off.out.contains("The command:\ndoz worker add wk --task x\n"),
          "47 the dry run with the daemon stopped answers (\(off.code) \(off.out.prefix(300)) \(off.err.prefix(200)))")
    check(!h.hostRunning, "47 …and no daemon started")
    check(rec == (try? Data(contentsOf: URL(fileURLWithPath: WorkspaceStore(store: store).folder("wk") + "/workspace.json"))), "47 …nothing written")
}
