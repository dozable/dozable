import Darwin
import Foundation
import DozableKit
import DozableHost

// `make test-cli-workspace`, one-shot `new` (WS.04): the six locked scenarios, black-box through the signed doz, its daemon and
// the chat server it runs — the workers as the STUB AGENT (`DOZ_TEST_STUB_AGENT=1`, this guarded run), fenced on this Mac, a
// scratch fence home, no claude on the sessions' PATH, no VM. `doz create` is never run (it makes a sandbox VM): only its help.
//
//  O1. new app --preset blank --brief "Fix the build" --folder DIR --worker "Fix the failing test" --json → 0; show --brief
//      --json → briefText "Fix the build"; worker ls --json → an agents entry with that task, not-started, before any start
//  O2. --brief - reads standard input: "Fix the build\n" → briefText "Fix the build"
//  O3. two --worker at new, then workspace start --json → 0, and worker ls lists both tasks, each running
//  O4. --preset nosuch → 65 invalid-value, error.message names the real presets (blank among them); nothing made
//  O5. doz workspace create … behaves as new (0, then show 0); its help names the alias
//  O6. doz create --help → 0, "doz workspace new" within its first 15 lines
//  O7. the dry run's command carries the --worker flags; --brief with --prompt-file refused (65), nothing made
//  N1–N7. no name, the isolation words, retired presets, the templates, a workspace from a template
//  N8–N10. --template with --dry-run (the plan, nothing written), --brief (its description) and --json; its agent's session
//      named once (NAME-agent); what a template decides still refused
//  N11. doz sessions with no name: every place's sessions
func cliWorkspaceOneShotRows(_ h: CLIHarness, root: URL, store: DozableStore, started: inout Set<String>) {
    print("cli: one-shot workspace new — --preset, --brief, --worker; workspace create")
    let fm = FileManager.default
    let home = URL(fileURLWithPath: "/private/tmp/dzo-\(getpid())-wso-home")
    try? fm.removeItem(at: home)
    try? fm.createDirectory(at: home, withIntermediateDirectories: true)
    // The folders: outside the store (a fenced session never runs in it), one per workspace.
    let repos = URL(fileURLWithPath: "/private/tmp/dzo-\(getpid())-wso-repos")
    try? fm.removeItem(at: repos)
    func folder(_ n: String) -> URL {
        let u = URL(fileURLWithPath: WorkspaceStore.resolved(repos.appendingPathComponent(n).path))
        try? fm.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    let repo = folder("example-repo")
    let ws = WorkspaceStore(store: store)
    var sessions: [String] = []
    defer {
        for s in sessions { h.run(["sessions", "end", "@mac", s, "--yes"], timeout: 30) }
        h.env[StubAgent.variable] = nil
        try? fm.removeItem(at: home)
        try? fm.removeItem(at: repos)
    }

    func record(_ n: String) -> WorkspaceRecord? { (try? ws.read(n)) ?? nil }
    func object(_ r: CLIRun) -> [String: Any] { ((try? JSONSerialization.jsonObject(with: r.outData)) as? [String: Any]) ?? [:] }
    func agents(_ w: String) -> [[String: Any]] {
        (object(h.run(["worker", "ls", w, "--json"], timeout: 60))["agents"] as? [[String: Any]]) ?? []
    }
    func briefText(_ w: String) -> String? {
        let r = h.run(["workspace", "show", w, "--brief", "--json"], timeout: 60)
        return object(r)["briefText"] as? String
    }

    // The daemon again with the stub agent on, the fence's scratch home, a PATH with no claude on it, and chat on.
    h.run(["daemon", "stop"], timeout: 60)
    _ = h.waitFor(20) { !h.hostRunning }
    h.env["DOZ_TEST_FENCE_HOME"] = home.path
    h.env["DOZ_TEST_MAC_PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
    h.env[StubAgent.variable] = "1"
    h.run(["config", "set", "mac.account", "none"])
    var r = h.run(["chat", "on", "--name", "ada"], timeout: 60)
    check(r.code == 0, "O0 chat on with the stub agent (\(r.code) \(r.err.prefix(160)))")

    // O1. one command: preset, brief, folder and a worker.
    r = h.run(["workspace", "new", "app", "--preset", "blank", "--brief", "Fix the build", "--folder", repo.path,
               "--worker", "Fix the failing test", "--json"], timeout: 60)
    let made = object(r)
    check(r.code == 0 && made["name"] as? String == "app" && made["kind"] as? String == "Workspace" && made["schema"] as? Int == 1,
          "O1 new app --preset blank --brief … --folder … --worker … --json: exit 0, kind Workspace, schema 1 (\(r.code) \(r.out.prefix(200)) \(r.err.prefix(200)))")
    check(briefText("app") == "Fix the build", "O1 show app --brief --json: briefText \"Fix the build\" (\(briefText("app") ?? "nil"))")
    var a = agents("app")
    let declared = a.first { $0["task"] as? String == "Fix the failing test" }
    check(declared != nil && declared?["condition"] as? String == "not-started" && declared?["declared"] as? Bool == true
          && declared?["isolation"] as? String == "fenced",
          "O1 worker ls app --json before the start: an agents entry with task \"Fix the failing test\", not-started, declared, fenced (\(a))")
    let listing = object(h.run(["worker", "ls", "app", "--json"], timeout: 60))
    check(listing["kind"] as? String == "WorkerListing" && listing["schema"] as? Int == 1, "O1 …the listing carries kind WorkerListing, schema 1")
    check(record("app").map { $0.flags.startedAt == nil && $0.declaredWorkers.map(\.task) == ["Fix the failing test"] } == true,
          "O1 …recorded on the workspace while it is setting up, nothing started")
    let state = object(h.run(["workspace", "state", "app", "--json"], timeout: 60))
    let conds = ((state["agents"] as? [String: [String: Any]]) ?? [:]).compactMapValues { $0["condition"] as? String }
    check(conds.values.contains("not-started") && conds.count == 1, "O1 …and workspace state --json says it is not started (\(conds))")
    r = h.run(["worker", "add", "app", "--task", "x"], timeout: 60)
    check(r.code == 3 && r.err.contains("--worker"), "O1 worker add while setting up: refused (3), pointing at --worker (\(r.code) \(r.err.prefix(200)))")

    // O2. --brief - from standard input, the trailing line break dropped.
    let repo2 = folder("example-repo-2")
    r = h.run(["workspace", "new", "app2", "--brief", "-", "--folder", repo2.path, "--json"], stdin: Data("Fix the build\n".utf8), timeout: 60)
    check(r.code == 0 && briefText("app2") == "Fix the build",
          "O2 new app2 --brief - < \"Fix the build\\n\": briefText \"Fix the build\" (\(r.code) \(briefText("app2") ?? "nil") \(r.err.prefix(200)))")

    // O3. two workers declared at new, then started by the start — the stub agent, fenced.
    let repo3 = folder("example-repo-3")
    r = h.run(["workspace", "new", "app3", "--preset", "blank", "--brief", "Fix the build", "--folder", repo3.path,
               "--worker", "Fix the failing test", "--worker", "Review the fix", "--json"], timeout: 60)
    check(r.code == 0, "O3 new app3 with two --worker (\(r.code) \(r.err.prefix(200)))")
    a = agents("app3")
    check(Set(a.compactMap { $0["task"] as? String }) == ["Fix the failing test", "Review the fix"] && a.allSatisfy { $0["condition"] as? String == "not-started" },
          "O3 worker ls app3 before the start: both tasks, not-started (\(a))")
    r = h.run(["workspace", "start", "app3", "--json"], timeout: 180)
    let startedAnswer = object(r)
    let names = (startedAnswer["workers"] as? [String]) ?? []
    for n in names { sessions.append(WorkerLaunch.placeName(workspace: "app3", name: n)) }
    started.formUnion(sessions)
    check(r.code == 0 && names.count == 2 && startedAnswer["kind"] as? String == "WorkspaceStarted",
          "O3 workspace start app3 --json: exit 0, both workers started (\(r.code) \(names) \(r.out.prefix(300)) \(r.err.prefix(300)))")
    check(h.waitFor(30) {
        let now = agents("app3")
        return Set(now.compactMap { $0["task"] as? String }) == ["Fix the failing test", "Review the fix"]
            && now.filter { $0["role"] as? String == "worker" }.allSatisfy { $0["condition"] as? String == "running" && $0["declared"] == nil }
    }, "O3 worker ls app3 after the start: both tasks, running (\(agents("app3")))")
    check(record("app3")?.declaredWorkers.isEmpty == true, "O3 …the declarations are gone once they run")
    let isolations = agents("app3").compactMap { $0["isolation"] as? String }
    check(isolations == ["fenced", "fenced"], "O3 …each fenced, the workspace's default (\(isolations))")
    let argvs = names.map { MacSessions(store: store, readOnly: true).records().sessions[WorkerLaunch.placeName(workspace: "app3", name: $0)]?.argv ?? [] }
    check(argvs.count == 2 && argvs.allSatisfy { $0.contains("stub-agent") }, "O3 …each the stub agent (\(argvs.map { $0.suffix(3) }))")

    // O4. an unknown preset: 65 invalid-value naming the real presets; nothing made.
    let before = ws.records().map(\.name).sorted()
    r = h.run(["workspace", "new", "app4", "--preset", "nosuch", "--brief", "Fix the build", "--folder", repo.path, "--json"], timeout: 60)
    let error = object(r)["error"] as? [String: Any]
    let message = error?["message"] as? String ?? ""
    check(r.code == 65 && error?["code"] as? String == "invalid-value" && message.contains("blank") && message.contains("remotion-video"),
          "O4 --preset nosuch: exit 65, invalid-value, the message names the presets (\(r.code) \(r.out.prefix(300)))")
    check(ws.records().map(\.name).sorted() == before && !ws.exists("app4"), "O4 …nothing changed")
    r = h.run(["workspace", "new", "app4", "--preset", "nosuch", "--brief", "x", "--dry-run", "--json"], timeout: 60)
    check(r.code == 65 && !ws.exists("app4"), "O4 …the dry run refuses it the same way (\(r.code))")

    // O5. doz workspace create is new.
    let repo5 = folder("example-repo-5")
    r = h.run(["workspace", "create", "app5", "--preset", "blank", "--brief", "Fix the build", "--folder", repo5.path,
               "--worker", "Fix the failing test", "--json"], timeout: 60)
    check(r.code == 0 && object(r)["name"] as? String == "app5", "O5 workspace create app5 …: exit 0 (\(r.code) \(r.err.prefix(200)))")
    r = h.run(["workspace", "show", "app5", "--json"], timeout: 60)
    check(r.code == 0 && briefText("app5") == "Fix the build" && agents("app5").contains { $0["task"] as? String == "Fix the failing test" },
          "O5 …then show app5: exit 0, the same brief and declared worker as new (\(r.code))")
    let help = h.run(["workspace", "--help"]).out
    check(help.contains("  new, create "), "O5 doz workspace --help shows create as new's alias")

    // O6. doz create --help names doz workspace new in its first 15 lines (doz create itself is never run here).
    r = h.run(["create", "--help"])
    let first15 = r.out.split(separator: "\n", omittingEmptySubsequences: false).prefix(15).joined(separator: "\n")
    check(r.code == 0 && first15.contains("doz workspace new"), "O6 doz create --help: exit 0, \"doz workspace new\" in its first 15 lines (\(r.code) \(first15.prefix(300)))")

    // O7. the dry run's reproducing command carries the workers; --brief and --prompt-file exclude each other.
    r = h.run(["workspace", "new", "app7", "--brief", "Fix the build", "--folder", repo.path, "--worker", "Fix the failing test",
               "--worker", "it's 'quoted'", "--dry-run", "--json"], timeout: 60)
    let commands = object(r)["commands"] as? String ?? ""
    check(r.code == 0 && commands.contains("--worker 'Fix the failing test'") && commands.contains(#"--worker 'it'\''s '\''quoted'\'''"#)
          && !ws.exists("app7"), "O7 the dry run's command carries both --worker flags; nothing made (\(r.code) \(commands.prefix(300)))")
    let promptFile = root.appendingPathComponent("o7-brief.md").path
    try? "x\n".write(toFile: promptFile, atomically: true, encoding: .utf8)
    r = h.run(["workspace", "new", "app7", "--brief", "x", "--prompt-file", promptFile, "--json"], timeout: 60)
    check(r.code == 65 && !ws.exists("app7"), "O7 --brief with --prompt-file: refused (65), nothing made (\(r.code) \(r.out.prefix(200)))")
    // 782: the description is optional — none at all makes it, with an empty one.
    r = h.run(["workspace", "new", "app7", "--json"], timeout: 60)
    check(r.code == 0 && ws.exists("app7") && (record("app7")?.brief.bytes ?? -1) == 0, "O7 no description at all: made, empty (\(r.code) \(r.err.prefix(200)))")

    // N1–N6 (782): no name — the next free workspaceN, printed; `sandbox` is the workers' isolation (vm its alias, stored vm);
    // the retired presets refused; the templates listed.
    r = h.run(["workspace", "new", "--brief", "First", "--folder", repo.path, "--json"], timeout: 60)
    let w1 = object(r)["name"] as? String ?? ""
    check(r.code == 0 && w1.hasPrefix("workspace") && ws.exists(w1), "N1 no name: the next free one, \(w1) (\(r.code) \(r.err.prefix(200)))")
    r = h.run(["workspace", "new", "--brief", "Second", "--folder", repo.path, "--json"], timeout: 60)
    let w2 = object(r)["name"] as? String ?? ""
    check(r.code == 0 && w2.hasPrefix("workspace") && w2 != w1, "N1 …again: the next one, \(w2) (\(r.code))")
    for (word, n) in [("sandbox", "sbx"), ("vm", "sbxold")] {
        r = h.run(["workspace", "new", n, "--brief", "Build it", "--folder", repo.path, "--worker", "Build", "--worker-isolation", word, "--dry-run", "--json"], timeout: 60)
        check(r.code == 0 && !ws.exists(n), "N2 --worker-isolation \(word): the dry run accepts it (\(r.code) \(r.out.prefix(200)))")
    }
    for p in ["swift-tests", "research", "mac-admin"] {
        r = h.run(["workspace", "new", "old-\(p)", "--preset", p, "--brief", "x", "--folder", repo.path, "--dry-run", "--json"], timeout: 60)
        check(r.code == 65 && r.out.contains("was retired"), "N3 --preset \(p): retired, refused (\(r.code))")
    }
    for args in [["workspace", "new", "--help"], ["bot", "new", "--help"], ["--help"]] {
        check(!h.run(args).out.contains("micro VM"), "N4 no \"micro VM\" in doz \(args.joined(separator: " "))")
    }
    r = h.run(["workspace", "templates", "--json"], timeout: 60)
    let ids = ((try? JSONSerialization.jsonObject(with: Data(r.out.utf8))) as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
    check(r.code == 0 && ids == ["solo", "solo-sandbox", "build-review", "fix-it", "video"], "N5 doz workspace templates: the five (\(ids))")
    // N6: a workspace from a template (One agent: fenced, the stub agent) — its files in <projects_dir>/NAME, set up and started.
    r = h.run(["workspace", "new", "tsolo", "--template", "solo", "--json"], timeout: 180)
    let madeW6 = object(r)
    let file = madeW6["file"] as? String ?? ""
    check(r.code == 0 && ws.exists("tsolo") && file.hasSuffix("/tsolo/tsolo.space.yaml") && FileManager.default.fileExists(atPath: file),
          "N6 new tsolo --template solo: made from its file, set up (\(r.code) \(r.out.prefix(300)) \(r.err.prefix(300)))")
    r = h.run(["workspace", "new", "tbr", "--template", "build-review", "--json"], timeout: 60)
    check(r.code != 0 && !ws.exists("tbr") && r.out.contains("needs a manager"), "N6 …a template that needs a manager, given none: refused, nothing made (\(r.code))")
    // N8–N10 (a first-run report: --template refused --brief, --dry-run and --json, which the manual and skill say work).
    // N8: --dry-run plans and writes nothing — no workspace, no folder, no file — and --json answers the plan.
    let projects = ((file as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
    r = h.run(["workspace", "new", "tdry", "--template", "solo", "--folder", repo.path, "--dry-run", "--json"], timeout: 120)
    let dryPlan = object(r)
    check(r.code == 0 && !ws.exists("tdry") && (dryPlan["steps"] as? [Any])?.isEmpty == false && dryPlan["space"] as? String == "tdry"
          && !fm.fileExists(atPath: projects + "/tdry"),
          "N8 new tdry --template solo --folder DIR --dry-run --json: the plan (0), nothing made or written (\(r.code) \(r.out.prefix(200)) \(r.err.prefix(200)))")
    r = h.run(["workspace", "new", "tdry", "--template", "solo", "--dry-run"], timeout: 120)
    check(r.code == 0 && r.out.contains("dry run") && !ws.exists("tdry") && !fm.fileExists(atPath: projects + "/tdry"),
          "N8 …as text: the plan, \"dry run\", nothing written (\(r.code))")
    // N9: --brief is the workspace's description (its DESCRIPTION.md); its agent's session is named once: tbrief-agent.
    r = h.run(["workspace", "new", "tbrief", "--template", "solo", "--folder", folder("tbrief").path, "--brief", "Write NOTES.md", "--json"], timeout: 180)
    sessions.append("tbrief-agent")
    let shownBrief = h.run(["workspace", "show", "tbrief", "--json", "--brief"], timeout: 60)
    check(r.code == 0 && object(r)["workspace"] as? String == "tbrief" && shownBrief.out.contains("Write NOTES.md"),
          "N9 new tbrief --template solo --brief \"Write NOTES.md\" --json → 0; show --json --brief holds it (\(r.code) \(r.err.prefix(200)))")
    let macNames = (h.sessions("@mac")).map(\.name)
    check(macNames.contains("tbrief-agent") && !macNames.contains("tbrief-tbrief-agent"),
          "N9 …its agent's session is tbrief-agent, never tbrief-tbrief-agent (\(macNames.filter { $0.hasPrefix("tbrief") }))")
    // N10: what a template decides is still refused with it, and nothing is made.
    r = h.run(["workspace", "new", "tnope", "--template", "solo", "--worker", "x", "--json"], timeout: 60)
    check(r.code != 0 && !ws.exists("tnope") && r.out.contains("--template takes only"), "N10 --template with --worker: refused, nothing made (\(r.code))")
    // N11: doz sessions --json with no name lists every place's sessions (this Mac's included) — never "Missing expected argument".
    r = h.run(["sessions", "ls", "--json"], timeout: 60)
    let places = ((try? JSONSerialization.jsonObject(with: Data(r.out.utf8))) as? [[String: Any]]) ?? []
    check(r.code == 0 && places.contains { $0["place"] as? String == "@mac" && (($0["sessions"] as? [[String: Any]]) ?? []).contains { $0["name"] as? String == "tbrief-agent" } },
          "N11 doz sessions ls --json, no name: every place's sessions, @mac's with tbrief-agent (\(r.code) \(r.err.prefix(160)))")
    r = h.run(["sessions"], timeout: 60)
    check(r.code == 0 && r.out.contains("PLACE") && r.out.contains("tbrief-agent"), "N11 …and doz sessions as text (\(r.code))")
    // N7: defaults.projects_dir NOT under your home (a space file must be): the agents' folder is still <projects_dir>/NAME,
    // made empty; the template's two files go in ~/doz-workspaces/NAME instead — decided before anything is written. The
    // daemon is started again with that home (the CLI and the daemon must agree on it), and stopped after.
    let savedBrief = h.env["DOZ_TEST_BRIEF_HOME"], savedHome = h.env["DOZ_TEST_HOME"]
    h.run(["daemon", "stop"], timeout: 60)
    _ = h.waitFor(20) { !h.hostRunning }
    // (the home in Foundation's spelling, /tmp/…, the one a standardized path under it has — as the space rules compare)
    let home7 = URL(fileURLWithPath: home.path).standardizedFileURL.path
    h.env["DOZ_TEST_BRIEF_HOME"] = home7
    h.env["DOZ_TEST_HOME"] = home7
    r = h.run(["workspace", "new", "tsolo2", "--template", "solo", "--json"], timeout: 180)
    let file7 = object(r)["file"] as? String ?? ""
    let expected7 = WorkspaceStore.resolved(home.appendingPathComponent("doz-workspaces/tsolo2/tsolo2.space.yaml").path)
    let file7Resolved = WorkspaceStore.resolved(file7)
    // The agents' folder as the record says it (the suite's projects_dir, outside that home).
    let shown7 = object(h.run(["workspace", "show", "tsolo2", "--json"], timeout: 60))
    let projectsDir = ((shown7["folders"] as? [[String: Any]])?.first?["path"] as? String) ?? ""
    let failed7 = (((object(r)["acted"] as? [String: Any])?["results"] as? [[String: Any]]) ?? []).filter { $0["status"] as? String == "failed" }
        .map { ($0["text"] as? String ?? "") + " " + (($0["notes"] as? [String])?.joined(separator: "; ") ?? "") }
    if !failed7.isEmpty { print("        N7 a step failed: \(failed7.joined(separator: " | ").prefix(400))") }
    check(r.code == 0 && ws.exists("tsolo2") && file7Resolved == expected7 && fm.fileExists(atPath: expected7) && projectsDir.hasSuffix("/tsolo2")
          && !projectsDir.hasPrefix(home.path) && !projectsDir.hasPrefix(home7) && fm.fileExists(atPath: projectsDir) && !fm.fileExists(atPath: projectsDir + "/tsolo2.space.yaml"),
          "N7 projects_dir outside your home: made; its files in ~/doz-workspaces/tsolo2, its agents' folder <projects_dir>/tsolo2 (\(r.code) \(file7) \(r.out.prefix(200)) \(r.err.prefix(300)))")
    h.run(["daemon", "stop"], timeout: 60)
    _ = h.waitFor(20) { !h.hostRunning }
    h.env["DOZ_TEST_BRIEF_HOME"] = savedBrief
    h.env["DOZ_TEST_HOME"] = savedHome

    for n in names { h.run(["worker", "end", "app3", n], timeout: 60) }
    started.subtract(sessions)

    // O8. chat off: a worker is still declared at new (intent, recorded as it is); the start refuses as it does for a manager
    // (3, the gap named), nothing started and the worker still declared. --no-room with --worker is the one contradiction (65).
    r = h.run(["chat", "off"], timeout: 60)
    check(r.code == 0, "O8 chat off (\(r.code) \(r.err.prefix(160)))")
    let repo8 = folder("example-repo-8")
    r = h.run(["workspace", "new", "app8", "--brief", "Fix the build", "--folder", repo8.path, "--worker", "Fix the failing test", "--json"], timeout: 60)
    check(r.code == 0 && agents("app8").contains { $0["task"] as? String == "Fix the failing test" && $0["condition"] as? String == "not-started" },
          "O8 chat off: new app8 --worker … exit 0, the worker declared, not-started (\(r.code) \(r.out.prefix(200)) \(r.err.prefix(200)))")
    r = h.run(["workspace", "start", "app8", "--json"], timeout: 60)
    let startError = object(r)["error"] as? [String: Any]
    check(r.code == 3 && (startError?["message"] as? String)?.contains("declared worker needs chat") == true,
          "O8 …start app8: refused (3), saying the declared worker needs chat (\(r.code) \(r.out.prefix(300)))")
    check(record("app8").map { $0.flags.startedAt == nil && $0.declaredWorkers.count == 1 } == true, "O8 …nothing started, the worker still declared")
    r = h.run(["workspace", "new", "app9", "--brief", "x", "--no-room", "--worker", "y", "--json"], timeout: 60)
    check(r.code == 65 && !ws.exists("app9"), "O8 --no-room with --worker: refused (65), nothing made (\(r.code))")
}
