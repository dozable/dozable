import Darwin
import Foundation
import DozableKit
import DozableHost

// `make test-cli-workspace`, stop and down (756, WS.08 VOC1): the six locked rows and the deletion-safety rows, black-box through
// the signed doz, its daemon and the chat server it runs — the agents as the STUB AGENT (`DOZ_TEST_STUB_AGENT=1`, this guarded
// run), fenced on this Mac, a scratch fence home, no claude on the sessions' PATH, no VM. `doz create` is never run.
//
//  V1. workspace stop sd --yes --json → 0, then within 30 s every agent `stopped` (not asleep); the notice names manager stop
//  V2. (the ratchet) sleep → every agent asleep within 30 s
//  V3. stop with no terminal and no --yes (--json) → 5 needs-confirmation, `fix` the argv with --yes; nothing stopped
//  V4. stop --yes on an asleep workspace → 0, still asleep; without --yes too (nothing to do, nothing asked)
//  V5. finish --yes --json on a long-lived (record-made) workspace → 0, kind WorkspaceFinish, schema 1, removed empty, kept the
//      folder's ABSOLUTE path and room/sd; the folder byte-for-byte; then state's phase finished
//  V6. workspace down on a record-made workspace → 0, kind WorkspaceFinish, kept lists the folder; the text says
//      "finished; nothing removed (standing)"
//  V7. a runs-lifetime space's scratch folder is under removed (its absolute path), gone, its archived copy verifies
//  V8. a standing space's scratch folder is kept: removed empty, the folder byte-for-byte
//  V9. doz workspace manager stop: the manager alone, a worker runs on
//  G1. a guarded space up whose settings leave defaults.projects_dir unset refuses rather than make a folder in the real
//      ~/doz-workspaces (TestSafety.projectsDirViolation); a listing of it before and after is the same
func cliWorkspaceStopDownRows(_ h: CLIHarness, root: URL, store: DozableStore, started: inout Set<String>) {
    print("cli: stop stops everything; down is finish and says what it kept")
    let fm = FileManager.default
    let pid = getpid()
    let home = URL(fileURLWithPath: "/private/tmp/dzo-\(pid)-wsd-home")
    let repos = URL(fileURLWithPath: "/private/tmp/dzo-\(pid)-wsd-repos")
    let files = URL(fileURLWithPath: "/private/tmp/dzo-\(pid)-wsd-files")
    // Scratch folders are made under defaults.projects_dir: a scratch one, never this Mac's own (a standing space keeps its).
    let projects = URL(fileURLWithPath: "/private/tmp/dzo-\(pid)-wsd-projects")
    for d in [home, repos, files, projects] { try? fm.removeItem(at: d); try? fm.createDirectory(at: d, withIntermediateDirectories: true) }
    var sessions: Set<String> = []
    defer {
        for s in sessions { h.run(["sessions", "end", "@mac", s, "--yes"], timeout: 30) }
        h.env[StubAgent.variable] = nil
        h.env["DOZ_TEST_BRIEF_HOME"] = nil
        for d in [home, repos, files, projects] { try? fm.removeItem(at: d) }
    }
    func folder(_ n: String) -> String {
        let p = WorkspaceStore.resolved(repos.appendingPathComponent(n).path)
        try? fm.createDirectory(atPath: p, withIntermediateDirectories: true)
        return p
    }
    func object(_ r: CLIRun) -> [String: Any] { ((try? JSONSerialization.jsonObject(with: r.outData)) as? [String: Any]) ?? [:] }
    func conditions(_ w: String) -> [String: String] {
        let o = object(h.run(["workspace", "state", w, "--json"], timeout: 60))
        return ((o["agents"] as? [String: [String: Any]]) ?? [:]).compactMapValues { $0["condition"] as? String }
    }
    func phase(_ w: String) -> String? { object(h.run(["workspace", "state", w, "--json"], timeout: 60))["phase"] as? String }
    func all(_ w: String, _ c: String) -> Bool { let x = conditions(w); return !x.isEmpty && x.values.allSatisfy { $0 == c } }
    func sha(_ p: String) -> String { (try? Data(contentsOf: URL(fileURLWithPath: p))).map(WorkspaceStore.sha256) ?? "none" }
    func track(_ w: String) { for s in MacSessions(store: store, readOnly: true).records().sessions.keys where s == w || s.hasPrefix(w + "-") { sessions.insert(s) } }

    check(h.run(["config", "set", "defaults.projects_dir", projects.path]).code == 0, "V0 defaults.projects_dir is a scratch path")
    // The daemon again with the stub agent on, the fence's scratch home, a PATH with no claude on it, and chat on.
    h.run(["daemon", "stop"], timeout: 60)
    _ = h.waitFor(20) { !h.hostRunning }
    h.env["DOZ_TEST_FENCE_HOME"] = home.path
    h.env["DOZ_TEST_MAC_PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
    h.env["DOZ_TEST_BRIEF_HOME"] = "/tmp"
    h.env[StubAgent.variable] = "1"
    h.run(["config", "set", "mac.account", "none"])
    var r = h.run(["chat", "on", "--name", "ada"], timeout: 60)
    check(r.code == 0, "V0 chat on with the stub agent (\(r.code) \(r.err.prefix(160)))")

    // A record-made workspace with a worker, started.
    let repo = folder("example-repo")
    let keep = repo + "/keep.txt"
    try? "the work\n".write(toFile: keep, atomically: true, encoding: .utf8)
    let keepSHA = sha(keep)
    r = h.run(["workspace", "new", "sd", "--preset", "blank", "--brief", "Fix the build", "--folder", repo, "--worker", "Fix the failing test", "--json"], timeout: 60)
    check(r.code == 0, "V0 new sd --worker … (\(r.code) \(r.err.prefix(200)))")
    r = h.run(["workspace", "start", "sd", "--json"], timeout: 120)
    if r.code == 0 { started.insert("sd") }
    track("sd")
    check(r.code == 0 && h.waitFor(30) { all("sd", "running") }, "V0 start sd: every agent running (\(r.code) \(conditions("sd")))")

    // V3. no terminal, no --yes: 5, with the command as fix; nothing stopped.
    r = h.run(["workspace", "stop", "sd", "--json"], timeout: 60)
    let e3 = object(r)["error"] as? [String: Any]
    check(r.code == 5 && e3?["code"] as? String == "needs-confirmation", "V3 stop sd --json with no --yes: exit 5, needs-confirmation (\(r.code) \(r.out.prefix(200)))")
    check(e3?["fix"] as? [String] == ["doz", "workspace", "stop", "sd", "--yes", "--json"], "V3 …fix is the argv (\(String(describing: e3?["fix"])))")
    check(all("sd", "running"), "V3 …nothing stopped (\(conditions("sd")))")

    // V1. stop --yes: every agent stopped within 30 s, not asleep; the notice on stderr.
    r = h.run(["workspace", "stop", "sd", "--yes", "--json"], timeout: 120)
    let s1 = object(r)
    check(r.code == 0 && s1["verb"] as? String == "stop", "V1 stop sd --yes --json: exit 0 (\(r.code) \(r.err.prefix(200)))")
    check(h.waitFor(30) { all("sd", "stopped") }, "V1 …within 30 s every agent stopped (\(conditions("sd")))")
    check(r.err.contains("doz workspace manager stop sd"), "V1 …the notice names the manager's own stop (\(r.err.prefix(200)))")
    check(phase("sd") == "stopped", "V1 …state's phase stopped (\(phase("sd") ?? "nil"))")
    check(sha(keep) == keepSHA, "V1 …its folder byte-for-byte")
    print("cli: V1 the answer, for the record:\n" + r.out)

    // V2. the ratchet: sleep → asleep.
    r = h.run(["workspace", "wake", "sd"], timeout: 180)
    check(r.code == 0 && h.waitFor(30) { all("sd", "running") }, "V2 wake sd: every agent running again (\(r.code) \(conditions("sd")))")
    r = h.run(["workspace", "sleep", "sd", "--json"], timeout: 180)
    check(r.code == 0 && h.waitFor(30) { all("sd", "asleep") }, "V2 sleep sd: within 30 s every agent asleep (\(r.code) \(conditions("sd")))")

    // V4. stop on an asleep workspace: 0, harmless.
    r = h.run(["workspace", "stop", "sd", "--yes", "--json"], timeout: 60)
    check(r.code == 0 && all("sd", "asleep"), "V4 stop --yes on an asleep workspace: exit 0, still asleep (\(r.code) \(conditions("sd")))")
    r = h.run(["workspace", "stop", "sd", "--json"], timeout: 60)
    check(r.code == 0, "V4 …without --yes too: nothing to do, nothing asked (\(r.code) \(r.out.prefix(160)))")

    // V5. finish a long-lived workspace: nothing removed, the folder and the room kept, then phase finished.
    r = h.run(["workspace", "finish", "sd", "--yes", "--json"], timeout: 180)
    let f5 = object(r)
    let kept5 = (f5["kept"] as? [String]) ?? []
    check(r.code == 0 && f5["kind"] as? String == "WorkspaceFinish" && f5["schema"] as? Int == 1,
          "V5 finish sd --yes --json: exit 0, kind WorkspaceFinish, schema 1 (\(r.code) \(r.out.prefix(200)) \(r.err.prefix(200)))")
    check((f5["removed"] as? [String]) == [], "V5 …removed empty (\(String(describing: f5["removed"])))")
    check(kept5.contains(repo) && repo.hasPrefix("/") && kept5.contains("room/sd"), "V5 …kept the folder's absolute path and room/sd (\(kept5))")
    check(f5["archive"] as? String != nil, "V5 …and the run's archive")
    check(sha(keep) == keepSHA && fm.fileExists(atPath: repo), "V5 …the folder on disk, byte-for-byte")
    check(phase("sd") == "finished", "V5 …then state's phase finished (\(phase("sd") ?? "nil"))")
    print("cli: V5 the finish answer, for the record:\n" + r.out)

    // V6. down on a record-made workspace is finish.
    let repo2 = folder("second-repo")
    r = h.run(["workspace", "new", "sd2", "--preset", "blank", "--brief", "Tidy", "--folder", repo2, "--json"], timeout: 60)
    _ = h.run(["workspace", "start", "sd2"], timeout: 120)
    track("sd2")
    r = h.run(["workspace", "down", "sd2", "--yes", "--json"], timeout: 180)
    let d6 = object(r)
    check(r.code == 0 && d6["kind"] as? String == "WorkspaceFinish", "V6 down sd2 --yes --json (record-made): exit 0, kind WorkspaceFinish (\(r.code) \(r.out.prefix(200)) \(r.err.prefix(200)))")
    check(((d6["kept"] as? [String]) ?? []).contains(repo2) && (d6["removed"] as? [String]) == [], "V6 …kept lists the folder, nothing removed (\(String(describing: d6["kept"])))")
    let repo3 = folder("third-repo")
    _ = h.run(["workspace", "new", "sd3", "--preset", "blank", "--brief", "Tidy", "--folder", repo3], timeout: 60)
    _ = h.run(["workspace", "start", "sd3"], timeout: 120)
    track("sd3")
    r = h.run(["workspace", "down", "sd3", "--yes"], timeout: 180)
    check(r.code == 0 && r.out.contains("finished; nothing removed (standing)") && r.out.contains(DisplayPath.tilde(repo3)),
          "V6 …its text says what it kept: \"finished; nothing removed (standing)\" (\(r.code) \(r.out.suffix(300)))")

    // V7. a runs-lifetime space: its scratch folder is under removed, after its copy verifies.
    func space(_ name: String, lifetime: String?) -> String {
        let d = files.appendingPathComponent(name)
        try? fm.createDirectory(at: d, withIntermediateDirectories: true)
        try? "Make the thing.\n".write(to: d.appendingPathComponent("BRIEF.md"), atomically: true, encoding: .utf8)
        let life = lifetime.map { "x-dozable:\n  lifetime: \($0)\n" } ?? ""
        let text = "doz: space/3\nspace: \(name)\nbrief: BRIEF.md\nowner: ada\n\(life)folders:\n  scratch: {}\nchat:\n  rooms:\n    \(name): { members: [owner] }\n"
        let f = d.appendingPathComponent("\(name).space.yaml").path
        try? text.write(toFile: f, atomically: true, encoding: .utf8)
        return f
    }
    func scratchOf(_ w: String) -> SpaceRecordRef.Scratch? {
        ((try? WorkspaceStore(store: store).read(w)) ?? nil).flatMap { SpaceRecordRef.of($0)?.scratch?.first }
    }
    r = h.run(["workspace", "up", "-f", space("rs", lifetime: nil), "--yes"], timeout: 180)
    let sc7 = scratchOf("rs")
    check(sc7.map { $0.path.hasPrefix(WorkspaceStore.resolved(projects.path) + "/") } ?? false, "V7 …its scratch folder under the scratch projects folder (\(sc7?.path ?? "none"))")
    check(r.code == 0 && sc7 != nil, "V7 up a runs-lifetime space with a scratch folder (\(r.code) \(r.err.prefix(200)))")
    if let sc = sc7 {
        try? "notes\n".write(toFile: sc.path + "/n.txt", atomically: true, encoding: .utf8)
        r = h.run(["workspace", "down", "rs", "--yes", "--json"], timeout: 300)
        let d7 = object(r)
        let removed = (d7["removed"] as? [String]) ?? []
        check(r.code == 0 && d7["kind"] as? String == "WorkspaceFinish" && removed.contains(sc.path),
              "V7 down rs: the scratch folder under removed, by its absolute path (\(r.code) \(removed) \(r.err.prefix(200)))")
        check(!fm.fileExists(atPath: sc.path), "V7 …gone from disk")
        let copy = store.root.path + "/archives/rs/folders/\(sc.run)/scratch"
        check(RunArchive.verify(root: WorkspaceStore.resolved(copy)).ok, "V7 …only after its archived copy verifies")
    }

    // V8. a standing space keeps its scratch folder.
    r = h.run(["workspace", "up", "-f", space("st", lifetime: "standing"), "--yes"], timeout: 180)
    let sc8 = scratchOf("st")
    check(sc8.map { $0.path.hasPrefix(WorkspaceStore.resolved(projects.path) + "/") } ?? false, "V8 …its scratch folder under the scratch projects folder (\(sc8?.path ?? "none"))")
    check(r.code == 0 && sc8 != nil, "V8 up a standing space with a scratch folder (\(r.code) \(r.err.prefix(200)))")
    if let sc = sc8 {
        try? "notes\n".write(toFile: sc.path + "/n.txt", atomically: true, encoding: .utf8)
        let before = sha(sc.path + "/n.txt")
        r = h.run(["workspace", "finish", "st", "--yes", "--json"], timeout: 300)
        let d8 = object(r)
        check(r.code == 0 && (d8["removed"] as? [String]) == [] && ((d8["kept"] as? [String]) ?? []).contains(sc.path),
              "V8 finish st (standing): removed empty, the scratch folder kept (\(r.code) \(String(describing: d8["removed"])) \(r.err.prefix(200)))")
        check(sha(sc.path + "/n.txt") == before, "V8 …byte-for-byte")
    }

    // V9. the manager alone.
    r = h.run(["bot", "new", "sdv", "--agent", "claude-code", "--isolation", "fenced", "--deliver", "poll"], timeout: 60)
    r = h.run(["workspace", "new", "sdm", "--preset", "blank", "--brief", "Lead", "--folder", folder("sdm"), "--manager", "sdv", "--worker", "help"], timeout: 60)
    r = h.run(["workspace", "start", "sdm"], timeout: 120)
    if r.code == 0 { started.insert("sdm") }
    track("sdm")
    check(r.code == 0 && h.waitFor(30) { all("sdm", "running") }, "V9 start sdm: the manager and a worker running (\(r.code) \(conditions("sdm")))")
    r = h.run(["workspace", "manager", "stop", "sdm"], timeout: 60)
    let c9 = conditions("sdm")
    check(r.code == 0 && h.waitFor(20) { conditions("sdm")["sdv"] != "running" } && conditions("sdm").filter { $0.key != "sdv" }.values.allSatisfy { $0 == "running" },
          "V9 workspace manager stop sdm: the manager alone, the worker runs on (\(r.code) \(c9))")
    h.run(["workspace", "stop", "sdm", "--yes"], timeout: 120)
    track("sdm")
    started.remove("sd")
    started.remove("sdm")

    // G1. A guarded space up in a scratch store whose settings leave defaults.projects_dir UNSET (it resolves the real
    // ~/doz-workspaces, whatever HOME says) refuses to make its scratch folder there — the daemon stops with the reason —
    // and nothing is written under the real ~/doz-workspaces (a listing before and after; nothing there is ever deleted).
    let real = TestSafety.realHome.appendingPathComponent("doz-workspaces").path
    func listing() -> [String] {
        guard let e = fm.enumerator(atPath: real) else { return [] }
        var out: [String] = []
        while let p = e.nextObject() as? String {
            out.append(p)
            if e.level >= 3 { e.skipDescendants() }
        }
        return out.sorted()
    }
    let g1 = URL(fileURLWithPath: "/private/tmp/dzo-\(pid)-g1")
    try? fm.removeItem(at: g1)
    try? fm.createDirectory(at: g1.appendingPathComponent("space"), withIntermediateDirectories: true)
    let g = CLIHarness(binary: h.binary, store: g1.appendingPathComponent("store"))
    g.env["HOME"] = g1.appendingPathComponent("home").path
    g.env["DOZ_TEST_HOME"] = g1.appendingPathComponent("home").path
    g.env["DOZ_TEST_BRIEF_HOME"] = "/tmp"
    g.env["DOZ_TEST_FENCE_HOME"] = g1.appendingPathComponent("fence").path
    try? fm.createDirectory(at: g1.appendingPathComponent("home"), withIntermediateDirectories: true)
    try? "Make it.\n".write(to: g1.appendingPathComponent("space/BRIEF.md"), atomically: true, encoding: .utf8)
    let gfile = g1.appendingPathComponent("space/gx.space.yaml").path
    try? "doz: space/3\nspace: gx\nbrief: BRIEF.md\nowner: ada\nfolders:\n  scratch: {}\n".write(toFile: gfile, atomically: true, encoding: .utf8)
    let toml = (try? String(contentsOf: g1.appendingPathComponent("store/xdg/doz/doz.toml"), encoding: .utf8)) ?? ""
    check(!toml.split(separator: "\n").contains { $0.hasPrefix("projects_dir") }, "G1 the scratch store's settings leave defaults.projects_dir unset")
    let before = listing()
    r = g.run(["workspace", "up", "-f", gfile, "--yes"], timeout: 180)
    let after = listing()
    let glog = (try? String(contentsOf: g1.appendingPathComponent("store/daemon.log"), encoding: .utf8)) ?? ""
    check(r.code != 0, "G1 a guarded up with projects_dir unset refuses (\(r.code) \(r.out.suffix(200)) \(r.err.suffix(200)))")
    check(glog.contains("TEST SAFETY: a test would make the folder \(real)/.runs/gx/") && glog.contains("defaults.projects_dir"),
          "G1 …the daemon stopped, naming the folder and the fix (\(glog.split(separator: "\n").last { $0.contains("TEST SAFETY") } ?? "no line"))")
    check(before == after && !fm.fileExists(atPath: real + "/.runs/gx"), "G1 …and nothing was written under the real ~/doz-workspaces (\(Set(after).subtracting(before).sorted().prefix(5)))")
    g.run(["daemon", "stop"], timeout: 60)
    _ = g.waitFor(20) { !g.hostRunning }
    try? fm.removeItem(at: g1)
}
