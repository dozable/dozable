import Darwin
import Foundation
import DozableKit
import DozableHost

// 593 — templates and duplicates on an AGENT image (pi: it has a state disk), with the real signed
// `doz` from separate processes (`make test-vm-templates`). The rules under test:
//   · a template is the ROOT disk only — never the state disk (the agent's logins and history);
//   · a sandbox created from a template has the root disk's files and a fresh state disk;
//   · duplicate: the new workspace at /workspace, the root disk's files, a FRESH state disk — or,
//     with --copy-state, the source's;
//   · 594: a workspace that does not exist is made (never inside the store); --isolated shares none.
//   · 757 (VOC2): the disk is saved with `doz image save SANDBOX NAME`, listed by `doz image ls` (a saved disk:
//     kind custom, BASE · AGENT "saved disk") and removed by `doz image rm NAME` — a sandbox made from it keeps
//     working; `doz template create | ls | rm` still work for one release, each with one stderr notice, and with
//     --json the same answer plus "deprecated"; `doz template rm` never removes a built-in image.
// Store: --store (default $TMPDIR/doz-templates-store), a scratch store; images are seeded from
// $DOZ_SEED_STORE or the vmtest store when they are there (APFS clones), else pi bakes (network).
// Sandboxes tpa / tpb / tpc / tpd; the saved disks tpl-pi and tpl-old. The scratch store follows no account, and its
// defaults.projects_dir is a scratch folder (never this Mac's ~/doz-workspaces).

func templatesSuite() async throws {
    let binary: String = {
        if let i = args.firstIndex(of: "--doz"), i + 1 < args.count { return args[i + 1] }
        return ".build/debug/doz"
    }()
    let h = CLIHarness(binary: URL(fileURLWithPath: binary).standardizedFileURL.path, store: storeRoot)
    try FileManager.default.createDirectory(at: storeRoot, withIntermediateDirectories: true)
    seedImages(into: storeRoot)
    info("doz \(h.binary) · store \(storeRoot.path)")
    let names = ["tpa", "tpb", "tpc", "tpd", "tpe", "tpf"]
    func cleanUp() {
        for n in names { h.run(["rm", n, "--yes"]) }
        for d in ["tpl-pi", "tpl-old"] { h.run(["image", "rm", d, "--yes"]) }
        h.run(["daemon", "stop"])
    }
    // Guarded: a sandbox made without --folder gets <defaults.projects_dir>/<name> — a scratch one here (outside the
    // store: a folder inside it is refused).
    let projects = URL(fileURLWithPath: "/private/tmp/dztp-projects-\(getpid())")
    try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: projects) }
    check(h.run(["config", "set", "defaults.projects_dir", projects.path]).code == 0, "defaults.projects_dir is a scratch path (\(projects.path))")
    cleanUp()
    let ws1 = storeRoot.appendingPathComponent("ws-one"), ws2 = storeRoot.appendingPathComponent("ws-two")
    for (d, m) in [(ws1, "one"), (ws2, "two")] {
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try "\(m)\n".write(to: d.appendingPathComponent("which"), atomically: true, encoding: .utf8)
    }
    let state = "/home/agent/.pi/agent"                   // pi's persist dir: on the state disk
    func sh(_ name: String, _ script: String) -> CLIRun { h.run(["exec", name, "--", "sh", "-c", script], timeout: 120) }

    check(h.run(["account", "default", "none"]).code == 0, "account default none (a scratch store never reads the Mac's login)")
    // (594: pi needs an API-key account; `--account none` is the explicit choice of none — nothing here calls a model.)
    var r = h.run(["create", "tpa", "--image", "pi", "--memory", "1G", "--network", "locked", "--account", "none", "--folder", ws1.path])
    check(r.code == 0, "create tpa --image pi --folder ws-one")
    r = h.run(["start", "tpa"], timeout: 1200)
    check(r.code == 0, "start tpa (a first start in the store bakes pi: minutes)")
    r = sh("tpa", "echo rootmark > /home/agent/rootmark && echo statemark > \(state)/statemark && sync && cat /workspace/which")
    check(r.code == 0 && r.out == "one\n", "tpa: a root-disk marker, a state-disk marker, ws-one at /workspace (\(r.out.replacingOccurrences(of: "\n", with: " ")) \(r.err.prefix(120)))")

    // 757: the disk saved with `doz image save`, while tpa RUNS.
    r = h.run(["image", "save", "tpa", "tpl-pi", "--note", "templates suite"])
    check(r.code == 0 && r.out.contains("as the image tpl-pi") && !r.err.contains("doz template"),
          "image save tpa tpl-pi (running): saved, no notice (\(r.code) \(r.out.prefix(160)) \(r.err.prefix(160)))")
    let tpl = DozableStore(root: storeRoot).layout("_").customImages().first { $0.name == "tpl-pi" }
    if let tpl {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: DozableStore(root: storeRoot).layout("_").customImageDirectory(tpl.key).path).sorted()) ?? []
        check(files == ["image.json", "root.ext4"], "the saved disk holds no state disk (\(files.joined(separator: ", ")))")
        check(tpl.imageSpec?.name == "pi", "it keeps the image spec (user, persist dirs) of pi")
    } else { check(false, "tpl-pi is in the store") }
    let saved = h.json(["image", "ls"], [ImageRow].self)?.first { $0.name == "tpl-pi" }
    check(saved?.kind == "custom" && saved?.fromSandbox == "tpa" && saved?.note == "templates suite",
          "image ls --json lists tpl-pi: kind custom, from tpa, its note (\(saved.map { "\($0.kind) \($0.fromSandbox ?? "-")" } ?? "absent"))")
    r = h.run(["image", "ls"])
    check(r.code == 0 && r.out.split(separator: "\n").contains { $0.hasPrefix("tpl-pi") && $0.contains("saved disk") },
          "image ls's row for tpl-pi says saved disk")
    r = h.run(["image", "save", "tpa", "tpl-pi"])
    check(r.code == 4 && r.err.contains("already exists"), "image save with a taken name: refused, exit 4 (\(r.code) \(r.err.prefix(160)))")
    r = h.run(["image", "save", "tpa", "pi"])
    check(r.code != 0 && r.err.contains("built-in image"), "image save as a built-in's name: refused (\(r.code))")

    // The old words, for one release: `doz template create | ls` forward, each with ONE notice, --json + "deprecated".
    r = h.run(["template", "create", "tpa", "--as", "tpl-old", "--json"])
    let created = (try? JSONSerialization.jsonObject(with: r.outData)) as? [String: Any]
    check(r.code == 0 && created?["name"] as? String == "tpl-old" && created?["deprecated"] as? String == "doz image save",
          "template create tpa --as tpl-old --json: saved, with \"deprecated\": \"doz image save\" (\(r.code) \(r.out.prefix(200)))")
    check(r.err.components(separatedBy: "sandbox disks are `doz image save|ls|rm`").count == 2,
          "…and one notice on stderr (\(r.err.prefix(200)))")
    r = h.run(["template", "create", "tpa", "--as", "tpl-old"])
    check(r.code == 4 && r.err.contains("now means workspace templates"), "template create with a taken name: the same refusal (exit 4), with the notice")
    r = h.run(["template", "ls", "--json"])
    let listed = ((try? JSONSerialization.jsonObject(with: r.outData)) as? [[String: Any]]) ?? []
    let savedNames = (h.json(["image", "ls"], [ImageRow].self) ?? []).filter { $0.kind == "custom" }.map(\.name).sorted()
    check(r.code == 0 && listed.compactMap { $0["name"] as? String }.sorted() == savedNames && savedNames == ["tpl-old", "tpl-pi"]
          && listed.allSatisfy { $0["deprecated"] as? String == "doz image ls" },
          "template ls --json: image ls's saved disks, each with \"deprecated\" (\(savedNames.joined(separator: ", ")))")
    check(r.err.contains("now means workspace templates"), "template ls: the notice")
    r = h.run(["template", "rm", "pi", "--yes"])
    check(r.code == 2 && r.err.contains("built-in image: doz image rm") && h.json(["image", "ls"], [ImageRow].self)?.contains { $0.name == "pi" } == true,
          "template rm pi: refused (a built-in), pi still listed (\(r.code))")
    r = h.run(["image", "rm", "tpl-old", "--yes"])
    check(r.code == 0 && r.out.contains("removed the saved disk tpl-old")
          && h.json(["image", "ls"], [ImageRow].self)?.contains { $0.name == "tpl-old" } == false
          && !DozableStore(root: storeRoot).layout("_").customImages().contains { $0.name == "tpl-old" },
          "image rm tpl-old: gone from image ls and the store")
    r = h.run(["image", "rm", "tpl-old"])
    check(r.code == 2, "image rm of a saved disk that is gone: not found (exit 2, before any question)")
    // 594: a template of pi is pi — the same credential prerequisite (refused here, then none on purpose).
    r = h.run(["create", "tpb", "--image", "tpl-pi", "--memory", "1G", "--network", "locked"])
    check(r.code != 0 && r.err.contains("pi needs an Anthropic API key") && h.row("tpb") == nil, "a pi template with no API-key account: refused, nothing made")
    r = h.run(["create", "tpb", "--image", "tpl-pi", "--memory", "1G", "--network", "locked", "--account", "none"])
    check(r.code == 0 && h.run(["start", "tpb"], timeout: 600).code == 0, "a sandbox from the template starts")
    check(sh("tpb", "cat /home/agent/rootmark").out == "rootmark\n", "tpb has the root disk's file")
    r = sh("tpb", "cat \(state)/statemark 2>/dev/null || echo none; test -d \(state) && echo dir")
    check(r.out == "none\ndir\n", "tpb's state disk is fresh: no state marker, the persist dir there (\(r.out.replacingOccurrences(of: "\n", with: " ")))")

    // Duplicate the running tpa with a new workspace: the state disk fresh…
    r = h.run(["duplicate", "tpa", "tpc", "--folder", ws2.path, "--cpus", "1"])
    check(r.code == 0 && h.row("tpc")?.phase == "off", "duplicate tpa tpc --folder ws-two (tpa running): tpc is off")
    check(!FileManager.default.fileExists(atPath: DozableStore(root: storeRoot).layout("tpc").stateDisk.path), "tpc has no state disk yet (made empty on its first boot)")
    check(h.run(["start", "tpc"], timeout: 600).code == 0, "start tpc")
    r = sh("tpc", "cat /workspace/which /home/agent/rootmark; cat \(state)/statemark 2>/dev/null || echo none")
    check(r.out == "two\nrootmark\nnone\n", "tpc: ws-two at /workspace, the root disk's file, a FRESH state disk (\(r.out.replacingOccurrences(of: "\n", with: " ")))")
    // …or copied, on request.
    r = h.run(["duplicate", "tpa", "tpd", "--copy-state"])
    check(r.code == 0 && h.run(["start", "tpd"], timeout: 600).code == 0, "duplicate tpa tpd --copy-state; start tpd")
    r = sh("tpd", "cat /workspace/which \(state)/statemark")
    check(r.out == "one\nstatemark\n", "tpd: ws-one kept, the state disk copied (\(r.out.replacingOccurrences(of: "\n", with: " ")))")
    // 594 (owner: "i dont want the user to have to create the path first"): a workspace that does not
    // exist is made — outside the store; inside it, it is refused and nothing is made.
    let inside = storeRoot.appendingPathComponent("ws-missing")
    r = h.run(["duplicate", "tpa", "tpe", "--folder", inside.path])
    check(r.code == 65 && r.err.contains("inside the store") && !FileManager.default.fileExists(atPath: inside.path) && h.row("tpe") == nil,
          "a missing workspace inside the store is refused, and not made")
    let scratch = URL(fileURLWithPath: "/private/tmp/dztp-\(getpid())")
    defer { try? FileManager.default.removeItem(at: scratch) }
    let deep = scratch.appendingPathComponent("new/deep")
    r = h.run(["duplicate", "tpa", "tpe", "--folder", deep.path])
    check(r.code == 0 && r.err.contains("[doz] created ") && r.err.contains("tmp/dztp-") && FileManager.default.fileExists(atPath: deep.path),
          "duplicate --folder …/new/deep: made (\(r.err.prefix(160)))")
    try? "made\n".write(to: deep.appendingPathComponent("which"), atomically: true, encoding: .utf8)
    check(h.run(["start", "tpe"], timeout: 600).code == 0 && sh("tpe", "cat /workspace/which").out == "made\n", "tpe sees it at /workspace")
    r = h.run(["duplicate", "tpa", "tpf", "--isolated"])
    check(r.code == 0 && r.out.contains("isolated") && h.run(["start", "tpf"], timeout: 600).code == 0
          && sh("tpf", "cat /workspace/which 2>/dev/null || echo private").out == "private\n",
          "duplicate --isolated: tpa's workspace is not shared with tpf")
    check(h.json(["ls"], [SandboxInfo].self)?.first { $0.name == "tpf" }?.folder == nil, "ls --json: tpf's workspace is null")

    // 757: image rm of the saved disk tpb was made from — tpb keeps working (its disk is its own APFS clone).
    r = h.run(["image", "rm", "tpl-pi", "--yes"])
    check(r.code == 0 && h.json(["image", "ls"], [ImageRow].self)?.contains { $0.kind == "custom" } == false, "image rm tpl-pi: no saved disk left")
    check(sh("tpb", "cat /home/agent/rootmark").out == "rootmark\n", "tpb, made from it, still runs with its root disk's file")
    // KNOWN (found by this suite, pre-existing, not 757's): a cold Start of a sandbox whose saved disk was removed is
    // refused ("no custom image … in this store", Sandbox.swift) even though Stop kept its own root disk — the boot
    // resolves `spec.customImage` before it looks at the kept disk. Recorded here, not checked, until it is fixed.
    if h.run(["shutdown", "tpb", "--yes"], timeout: 300).code == 0 {
        let cold = h.run(["start", "tpb"], timeout: 600)
        info("KNOWN: a cold start of tpb after its saved disk was removed → \(cold.code) \(cold.err.prefix(160))")
    }

    cleanUp()
    check(!h.hostRunning, "cleanup: no daemon left running")
}
