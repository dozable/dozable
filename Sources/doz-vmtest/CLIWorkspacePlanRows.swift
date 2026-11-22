import Darwin
import Foundation
import DozableKit
import DozableHost

// `make test-cli-workspace`, making one with a look first (after rows 1–37, in the same scratch store, chat on):
//
//  38. new --dry-run with the daemon stopped: exit 0, the lines and the gaps printed ("no main room" with --no-room and a
//      manager), nothing written, and no daemon starts
//  39. a refused dry run gives new's exit code and message (a name taken: 4)
//  40. the printed commands, run by /bin/sh in a FRESH scratch store, make a workspace whose show --json equals the one
//      new makes here from the same choices, apart from times
//  41. --worker-isolation vm, --network open and --new-folder are recorded (the folder made 0700 under a scratch
//      defaults.projects_dir)
//  42. --worker-isolation unfenced: refused, nothing made
//  43. --start with no manager: made and started, the kick-off posted once
//  44. --dry-run --json is the plan: its gaps, commands and the built-in presets
func cliWorkspacePlanRows(_ h: CLIHarness, root: URL, store: DozableStore, started: inout Set<String>) {
    print("cli: making a workspace — the dry run and the one command source")
    let fm = FileManager.default
    let ws = WorkspaceStore(store: store)
    let brief = root.appendingPathComponent("plan-brief.md").path
    try? "Plan the launch.\n".write(toFile: brief, atomically: true, encoding: .utf8)
    let work = WorkspaceStore.resolved(root.appendingPathComponent("work").path)
    let projects = WorkspaceStore.resolved(root.path + "-projects")
    defer { try? fm.removeItem(atPath: projects) }
    func mine(_ room: String) -> [String] {
        let r = h.run(["chat", "read", room, "--last", "100", "--json"])
        let ms = ((try? JSONSerialization.jsonObject(with: r.outData)) as? [[String: Any]]) ?? []
        return ms.filter { $0["from"] as? String == "ada" && ($0["kind"] as? String) != "change" }.compactMap { $0["content"] as? String }
    }
    func mode(_ p: String) -> mode_t { var st = stat(); return lstat(p, &st) == 0 ? st.st_mode & 0o777 : 0 }

    // 38. a dry run with the daemon stopped
    h.run(["daemon", "stop"], timeout: 60)
    _ = h.waitFor(20) { !h.hostRunning }
    var r = h.run(["workspace", "new", "dry1", "--prompt-file", brief, "--manager", "mira", "--no-room", "--dry-run"], timeout: 60)
    check(r.code == 0 && r.out.contains("workspace dry1") && r.out.contains("Before it can start:") && r.out.contains("no main room"),
          "38 new --dry-run: the lines and the gaps, exit 0 (\(r.code) \(r.out.prefix(300)))")
    check(r.out.contains("doz workspace new dry1 --prompt-file - ") && r.out.contains("<<'DOZ_BRIEF_"), "38 …and the commands, the brief as a heredoc")
    check(!ws.exists("dry1"), "38 …nothing written")
    check(!h.hostRunning, "38 …and no daemon started")

    // 39. refused: new's code and message
    r = h.run(["workspace", "new", "demo2", "--prompt-file", brief, "--dry-run"], timeout: 60)
    let real = h.run(["workspace", "new", "demo2", "--prompt-file", brief], timeout: 60)
    check(r.code == 4 && real.code == 4 && r.out.contains("there is already a workspace demo2") && real.err.contains("there is already a workspace demo2"),
          "39 a refused dry run: new's exit code and message (\(r.code), \(real.code))")

    // 40. the printed commands in a fresh store make the same workspace
    let choices = ["--prompt-file", brief, "--folder", work + ":ro", "--ref", "https://example.com/spec", "--worker-isolation", "vm",
                   "--network", "open", "--no-room"]
    let plan = h.json(["workspace", "new", "same"] + choices + ["--dry-run"], WorkspacePlan.self)
    check(plan?.refusals == [] && plan?.commands.contains("--worker-isolation vm") == true, "40 the plan's commands (\(plan?.refusals ?? ["?"]))")
    let fresh = URL(fileURLWithPath: root.path + "-fresh")
    try? fm.removeItem(at: fresh)
    let h2 = CLIHarness(binary: h.binary, store: fresh)
    h2.env["DOZ_TEST_CREDENTIALS"] = "memory"
    let dozBin = root.appendingPathComponent("dozbin")
    try? fm.createDirectory(at: dozBin, withIntermediateDirectories: true)
    try? fm.removeItem(atPath: dozBin.appendingPathComponent("doz").path)
    try? fm.createSymbolicLink(atPath: dozBin.appendingPathComponent("doz").path, withDestinationPath: h.binary)
    var shellCode: Int32 = -1
    if let text = plan?.commands {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", text]
        var e = h2.env
        e["PATH"] = dozBin.path + ":/usr/bin:/bin"
        p.environment = e
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        shellCode = p.terminationStatus
    }
    r = h.run(["workspace", "new", "same"] + choices, timeout: 60)
    func timeless(_ d: WorkspaceDetail?) -> WorkspaceDetail? {
        guard var d else { return nil }
        d.createdAt = .distantPast
        d.brief.updatedAt = .distantPast
        d.notes = nil
        d.gaps = nil
        return d
    }
    let here = timeless(h.json(["workspace", "show", "same"], WorkspaceDetail.self))
    let there = timeless(h2.json(["workspace", "show", "same"], WorkspaceDetail.self))
    check(shellCode == 0 && r.code == 0 && here != nil && here == there,
          "40 the printed commands in a fresh store: the same workspace apart from times (\(shellCode), \(r.code))")
    h2.run(["daemon", "stop"], timeout: 60)
    _ = h2.waitFor(20) { !h2.hostRunning }
    try? fm.removeItem(at: fresh)

    // 41. the new fields recorded
    h.run(["config", "set", "defaults.projects_dir", projects])
    r = h.run(["workspace", "new", "fields", "--prompt-file", brief, "--new-folder", "--worker-isolation", "vm", "--network", "open", "--no-room"],
              timeout: 60)
    let d41 = h.json(["workspace", "show", "fields"], WorkspaceDetail.self)
    check(r.code == 0 && d41?.defaults.isolation == "vm" && d41?.defaults.network == "open", "41 --worker-isolation vm, --network open recorded (\(r.code))")
    check(d41?.folders.first?.path == projects + "/fields" && d41?.folders.first?.main == true && mode(projects + "/fields") == 0o700,
          "41 --new-folder: \(projects)/fields made 0700, the main folder (\(d41?.folders.first?.path ?? "?"))")

    // 42. never unfenced by default
    r = h.run(["workspace", "new", "unfw", "--prompt-file", brief, "--worker-isolation", "unfenced"], timeout: 60)
    check(r.code == 65 && r.err.contains("never unfenced by default") && !ws.exists("unfw"), "42 --worker-isolation unfenced: refused, nothing made (\(r.code))")

    // 43. --start, no manager: the kick-off once
    r = h.run(["workspace", "new", "kick", "--prompt-file", brief, "--start"], timeout: 90)
    let d43 = h.json(["workspace", "show", "kick"], WorkspaceDetail.self)
    check(r.code == 0 && r.out.contains("no manager: you drive") && d43?.flags.startedAt != nil && mine("kick").count == 1,
          "43 new --start: made and started, the brief posted once (\(r.code), \(mine("kick").count))")

    // 44. the plan as JSON
    let p44 = h.json(["workspace", "new", "dry2", "--prompt-file", brief, "--manager", "mira", "--no-room", "--dry-run"], WorkspacePlan.self)
    check(p44?.gaps.contains { $0.item == "room" } == true && p44?.presets.map(\.id).contains("blank") == true && p44?.startCommand == "doz workspace start dry2",
          "44 --dry-run --json: the plan with its gaps, presets and commands")
    check(!ws.exists("dry2"), "44 …nothing written")
}
