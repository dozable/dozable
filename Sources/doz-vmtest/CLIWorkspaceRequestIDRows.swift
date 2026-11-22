import Darwin
import Foundation
import DozableKit
import DozableHost

// `make test-cli-workspace`, idempotent creates (WS.06): `--request-id`, black-box through the signed doz, its daemon and the
// chat server it runs — the worker as the STUB AGENT (`DOZ_TEST_STUB_AGENT=1`, this guarded run), fenced on this Mac, a scratch
// fence home, no claude on the sessions' PATH, no VM.
//
//  I1. workspace new … --request-id r-1 --json twice → exit 0 both, the second with replayed: true and the same workspace;
//      the workspace's log unchanged by the replay
//  I2. the same id with other arguments (another --brief) → exit 3, error.code request-id-reused, the message naming --brief
//      and never the brief; nothing changed
//  I3. worker add W reviewer --task … --request-id r-2 --json twice on a running stub workspace → exit 0 both, the second
//      replayed: true; worker ls shows ONE reviewer
//  I4. after a daemon restart the id still replays (kept in the store); the same id for another command kind is another id
//  I5. an invalid id → 65 invalid-value, nothing made
func cliWorkspaceRequestIDRows(_ h: CLIHarness, root: URL, store: DozableStore, started: inout Set<String>) {
    print("cli: idempotent creates — --request-id")
    let fm = FileManager.default
    let home = URL(fileURLWithPath: "/private/tmp/dzo-\(getpid())-wsi-home")
    try? fm.removeItem(at: home)
    try? fm.createDirectory(at: home, withIntermediateDirectories: true)
    let repos = URL(fileURLWithPath: "/private/tmp/dzo-\(getpid())-wsi-repos")
    try? fm.removeItem(at: repos)
    func folder(_ n: String) -> URL {
        let u = URL(fileURLWithPath: WorkspaceStore.resolved(repos.appendingPathComponent(n).path))
        try? fm.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    let ws = WorkspaceStore(store: store)
    var sessions: [String] = []
    defer {
        for s in sessions { h.run(["sessions", "end", "@mac", s, "--yes"], timeout: 30) }
        h.env[StubAgent.variable] = nil
        try? fm.removeItem(at: home)
        try? fm.removeItem(at: repos)
    }
    func object(_ r: CLIRun) -> [String: Any] { ((try? JSONSerialization.jsonObject(with: r.outData)) as? [String: Any]) ?? [:] }
    func agents(_ w: String) -> [[String: Any]] {
        (object(h.run(["worker", "ls", w, "--json"], timeout: 60))["agents"] as? [[String: Any]]) ?? []
    }

    // The daemon again with the stub agent on, the fence's scratch home, a PATH with no claude on it, and chat on.
    h.run(["daemon", "stop"], timeout: 60)
    _ = h.waitFor(20) { !h.hostRunning }
    h.env["DOZ_TEST_FENCE_HOME"] = home.path
    h.env["DOZ_TEST_MAC_PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
    h.env[StubAgent.variable] = "1"
    h.run(["config", "set", "mac.account", "none"])
    var r = h.run(["chat", "on", "--name", "ada"], timeout: 60)
    check(r.code == 0, "I0 chat on with the stub agent (\(r.code) \(r.err.prefix(160)))")

    // I1. new twice with one id: the second is the first answer, replayed.
    let repo = folder("rid-repo")
    let newArgs = ["workspace", "new", "rid", "--preset", "blank", "--brief", "Fix the build", "--folder", repo.path, "--json"]
    r = h.run(newArgs + ["--request-id", "r-1"], timeout: 60)
    let first = object(r)
    check(r.code == 0 && first["name"] as? String == "rid" && first["replayed"] == nil,
          "I1 new rid … --request-id r-1 --json: exit 0, not a replay (\(r.code) \(r.out.prefix(200)) \(r.err.prefix(200)))")
    let logBefore = (try? ws.log("rid").count) ?? -1
    r = h.run(newArgs + ["--request-id", "r-1"], timeout: 60)
    var again = object(r)
    check(r.code == 0 && again["replayed"] as? Bool == true, "I1 …the same again: exit 0, replayed: true (\(r.code) \(r.out.prefix(300)) \(r.err.prefix(200)))")
    again["replayed"] = nil
    check(NSDictionary(dictionary: again).isEqual(to: first), "I1 …exactly the first answer, replayed added")
    check(((try? ws.log("rid").count) ?? -2) == logBefore, "I1 …nothing done again (the workspace's log unchanged)")
    r = h.run(newArgs, timeout: 60)
    check(r.code == 4, "I1 …and without the id it is refused as it always was: it exists (\(r.code))")

    // I2. the same id with other arguments.
    let secretish = "BRIEF-\(UUID().uuidString.prefix(8))"
    r = h.run(["workspace", "new", "rid", "--preset", "blank", "--brief", secretish, "--folder", repo.path, "--json", "--request-id", "r-1"], timeout: 60)
    let err = object(r)["error"] as? [String: Any]
    let message = err?["message"] as? String ?? ""
    check(r.code == 3 && err?["code"] as? String == "request-id-reused" && err?["exit"] as? Int == 3,
          "I2 the same id, another --brief: exit 3, request-id-reused (\(r.code) \(r.out.prefix(300)))")
    check(message.contains("--brief") && !message.contains(secretish) && !message.contains("Fix the build"),
          "I2 …the message names --brief and never a value (\(message))")
    let briefNow = object(h.run(["workspace", "show", "rid", "--brief", "--json"], timeout: 60))["briefText"] as? String
    check(briefNow == "Fix the build" && ((try? ws.log("rid").count) ?? -2) == logBefore, "I2 …nothing changed (\(briefNow ?? "nil"))")

    // I3. worker add twice with one id on a running stub workspace: one reviewer.
    let repo3 = folder("rid-repo-w")
    r = h.run(["workspace", "new", "ridw", "--preset", "blank", "--brief", "Fix the build", "--folder", repo3.path, "--json"], timeout: 60)
    check(r.code == 0, "I3 new ridw (\(r.code) \(r.err.prefix(200)))")
    r = h.run(["workspace", "start", "ridw", "--json"], timeout: 180)
    check(r.code == 0, "I3 start ridw (\(r.code) \(r.out.prefix(200)) \(r.err.prefix(200)))")
    let addArgs = ["worker", "add", "ridw", "reviewer", "--task", "Review the fix", "--json", "--request-id", "r-2"]
    r = h.run(addArgs, timeout: 120)
    let added = object(r)
    sessions.append(WorkerLaunch.placeName(workspace: "ridw", name: "reviewer"))
    started.formUnion(sessions)
    check(r.code == 0 && added["replayed"] == nil && (added["worker"] as? [String: Any])?["name"] as? String == "reviewer",
          "I3 worker add ridw reviewer --task … --request-id r-2: exit 0 (\(r.code) \(r.out.prefix(300)) \(r.err.prefix(300)))")
    check(h.waitFor(30) { agents("ridw").contains { $0["name"] as? String == "reviewer" && $0["condition"] as? String == "running" } },
          "I3 …the stub reviewer runs (\(agents("ridw")))")
    r = h.run(addArgs, timeout: 120)
    check(r.code == 0 && object(r)["replayed"] as? Bool == true, "I3 …the same again: exit 0, replayed: true (\(r.code) \(r.out.prefix(300)) \(r.err.prefix(200)))")
    let reviewers = agents("ridw").filter { $0["name"] as? String == "reviewer" }
    check(reviewers.count == 1, "I3 …worker ls shows ONE reviewer (\(agents("ridw").compactMap { $0["name"] as? String }))")
    r = h.run(["worker", "add", "ridw", "reviewer", "--task", "Another task", "--json", "--request-id", "r-2"], timeout: 60)
    check(r.code == 3 && (object(r)["error"] as? [String: Any])?["code"] as? String == "request-id-reused",
          "I3 …another --task with r-2: exit 3, request-id-reused (\(r.code) \(r.out.prefix(200)))")

    // I4. a daemon restart keeps the ids; another command kind with the same id is another id.
    h.run(["daemon", "stop"], timeout: 60)
    _ = h.waitFor(20) { !h.hostRunning }
    r = h.run(newArgs + ["--request-id", "r-1"], timeout: 60)
    check(r.code == 0 && object(r)["replayed"] as? Bool == true, "I4 after a daemon restart, new with r-1 still replays (\(r.code) \(r.out.prefix(200)) \(r.err.prefix(200)))")
    r = h.run(["worker", "add", "ridw", "second", "--task", "Check the docs", "--json", "--request-id", "r-1"], timeout: 120)
    sessions.append(WorkerLaunch.placeName(workspace: "ridw", name: "second"))
    started.formUnion(sessions)
    check(r.code == 0 && object(r)["replayed"] == nil, "I4 …r-1 for a worker add is another id: it runs (\(r.code) \(r.out.prefix(200)) \(r.err.prefix(200)))")

    // I5. an invalid id.
    r = h.run(["workspace", "new", "rid5", "--brief", "x", "--folder", repo.path, "--json", "--request-id", "has a space"], timeout: 60)
    check(r.code == 65 && (object(r)["error"] as? [String: Any])?["code"] as? String == "invalid-value" && !ws.exists("rid5"),
          "I5 --request-id \"has a space\": 65 invalid-value, nothing made (\(r.code) \(r.out.prefix(200)))")

    for n in ["reviewer", "second"] { h.run(["worker", "end", "ridw", n], timeout: 60) }
    started.subtract(sessions)
}
