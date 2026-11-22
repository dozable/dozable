import Darwin
import Foundation
import DozableKit
import DozableHost

// `make test-cli-workspace`, space files (after rows 45–47, in the same scratch store: the daemon stopped there, chat on
// with the human ada). A space file and its brief in a scratch folder beside the store:
//
//  S1. plan -f and up -f --dry-run with the daemon stopped: answered (`factsKnown` false, the summary, the steps), no
//      daemon starts, nothing in the store or the settings changes, no workspace is made
//  S12. doz space plan|up|config are doz workspace plan|up|config (the same answer); without -f, the one *.space.yaml in
//      the folder; two of them refused (exit 64), naming both; config's merged values
func cliSpaceRows(_ h: CLIHarness, root: URL, store: DozableStore) {
    print("cli: space files — the plan, no daemon")
    let fm = FileManager.default
    let dir = URL(fileURLWithPath: root.path + "-space")
    try? fm.removeItem(at: dir)
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: dir) }
    let file = dir.appendingPathComponent("s1.space.yaml")
    try? """
    doz: space/3
    space: s1
    brief: BRIEF.md
    owner: ada
    archive: off
    folders:
      scratch: {}
    agents:
      w1: { kind: claude-code, isolation: fenced, folder: scratch, prompt: Do the task in the brief. }
    chat:
      rooms:
        s1: { members: [owner, w1] }

    """.write(to: file, atomically: true, encoding: .utf8)
    try? "# The brief\n".write(to: dir.appendingPathComponent("BRIEF.md"), atomically: true, encoding: .utf8)

    /// Every file of the store and the settings, with its size and time (the daemon is stopped: nothing should move).
    func tree() -> [String] {
        var out: [String] = []
        for base in [root.path, h.env["XDG_CONFIG_HOME"] ?? ""] where !base.isEmpty {
            for case let p as String in fm.enumerator(atPath: base)?.allObjects ?? [] {
                let a = try? fm.attributesOfItem(atPath: base + "/" + p)
                out.append("\(p) \(a?[.size] ?? 0) \((a?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)")
            }
        }
        return out.sorted()
    }

    // S1. the daemon stopped
    h.run(["daemon", "stop"], timeout: 60)
    _ = h.waitFor(20) { !h.hostRunning }
    let before = tree()
    let plan = h.run(["workspace", "plan", "-f", file.path], timeout: 60)
    check([0, 2, 3, 4].contains(plan.code) && plan.out.contains("plan for space \"s1\"") && plan.out.contains("no daemon is running")
          && plan.out.contains("start w1 fenced on this Mac") && plan.out.contains("Archive: off (from s1.space.yaml:5)"),
          "S1 plan -f with the daemon stopped: answered (\(plan.code) \(plan.out.prefix(400)) \(plan.err.prefix(200)))")
    let pj = h.run(["workspace", "plan", "-f", file.path, "--json"], timeout: 60)
    let p = try? HostWire.decoder.decode(SpacePlan.self, from: pj.outData)
    check(p?.factsKnown == false && p?.space == "s1" && p?.steps.contains { $0.kind == "worker-add" } == true,
          "S1 …--json: factsKnown false, the steps (\(pj.code) \(pj.out.prefix(200)))")
    let dry = h.run(["workspace", "up", "-f", file.path, "--dry-run"], timeout: 60)
    check(dry.code == plan.code && dry.out.contains("space up \"s1\" (dry run: nothing changes)"), "S1 up --dry-run: the same plan (\(dry.code))")
    check(!h.hostRunning, "S1 …no daemon started")
    check(tree() == before, "S1 …nothing in the store or the settings changed")
    check(!WorkspaceStore(store: store).exists("s1"), "S1 …no workspace made")

    // S12. the alias, and the one file
    let sp = h.run(["space", "plan", "-f", file.path, "--json"], timeout: 60)
    let sq = try? HostWire.decoder.decode(SpacePlan.self, from: sp.outData)
    check(sq != nil && sq?.sha == p?.sha && sp.code == pj.code, "S12 space plan -f is workspace plan -f: the same sha (\(sq?.sha.prefix(12) ?? "?"))")
    let here = h.run(["space", "plan", "--json"], timeout: 60, cwd: dir)
    let hq = try? HostWire.decoder.decode(SpacePlan.self, from: here.outData)
    check(hq?.sha == p?.sha && hq?.specPath == file.standardizedFileURL.path, "S12 without -f: the one *.space.yaml in the folder (\(here.code) \(here.err.prefix(200)))")
    let cfgA = h.run(["space", "config", "--json"], timeout: 60, cwd: dir)
    let cfgB = h.run(["workspace", "config", file.path, "--json"], timeout: 60)
    check(cfgA.code == 0 && cfgA.out == cfgB.out && cfgA.out.contains("\"off\"") && cfgA.out.contains("\"s1.space.yaml\"") == false,
          "S12 space config is workspace config (\(cfgA.code) \(cfgA.out.prefix(200)))")
    try? fm.copyItem(at: file, to: dir.appendingPathComponent("s2.space.yaml"))
    let two = h.run(["space", "plan"], timeout: 60, cwd: dir)
    check(two.code == 64 && two.err.contains("s1.space.yaml, s2.space.yaml"), "S12 two space files: refused, naming both (\(two.code) \(two.err.prefix(200)))")
    check(!h.hostRunning && tree() == before, "S12 …still no daemon, nothing changed")

    // X. the exit-code contract: an invalid document is 65 (never 2: 2 is only not found); the table is published.
    func error(_ r: CLIRun) -> (code: String, exit: Int, message: String)? {
        guard let o = try? JSONSerialization.jsonObject(with: r.outData) as? [String: Any], let e = o["error"] as? [String: Any],
              let c = e["code"] as? String, let x = e["exit"] as? Int, let m = e["message"] as? String else { return nil }
        return (c, x, m)
    }
    let bad = dir.appendingPathComponent("bad.space.yaml")
    try? "doz: space/3\nspace: bad\nbrief: BRIEF.md\nowner: ada\nagents:\n  w1: { kind: claude-code, isolation: sideways, prompt: x }\n".write(to: bad, atomically: true, encoding: .utf8)
    var x = h.run(["workspace", "plan", "-f", bad.path, "--json"], timeout: 60)
    check(x.code == 65 && error(x)?.code == "invalid-document" && error(x)?.exit == 65 && error(x)?.message.isEmpty == false,
          "X1 an invalid value in a space file: exit 65, invalid-document (\(x.code) \(x.out.prefix(200)))")
    x = h.run(["workspace", "plan", "-f", bad.path], timeout: 60)
    check(x.code == 65 && x.err.contains("bad.space.yaml:6") && x.err.contains("isolation"), "X1 …as text: 65, the file and line (\(x.code) \(x.err.prefix(200)))")
    try? "doz: space/3\nspace: [broken\n  agents: :\n".write(to: bad, atomically: true, encoding: .utf8)
    x = h.run(["workspace", "plan", "-f", bad.path, "--json"], timeout: 60)
    check(x.code == 65 && error(x)?.code == "invalid-document", "X2 a YAML syntax error: exit 65, invalid-document (\(x.code) \(x.out.prefix(200)))")
    x = h.run(["workspace", "show", "nosuch", "--json"], timeout: 60)
    check(x.code == 2 && error(x)?.code == "not-found" && error(x)?.exit == 2, "X3 a missing workspace: exit 2, not-found (\(x.code) \(x.out.prefix(200)))")
    x = h.run(["help", "exit-codes", "--json"], timeout: 60)
    let table = try? HostWire.decoder.decode(ExitCodesAnswer.self, from: x.outData)
    check(x.code == 0 && table?.kind == "ExitCodes" && table?.schema == 1
          && table?.codes.map(\.exit) == [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 64, 65, 75, 124, 125]
          && table?.codes.first { $0.exit == 2 }?.errorCodes == ["not-found", "ambiguous"],
          "X4 help exit-codes --json: the published table (\(x.code) \(x.out.prefix(200)))")
    check(h.run(["no-such-command"], timeout: 60).code == 64 && h.run(["ls", "--no-such-flag"], timeout: 60).code == 64,
          "X5 an unknown command or flag: still 64")
    check(!h.hostRunning, "X …and no daemon started")
}
