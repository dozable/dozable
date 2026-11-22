import Darwin
import Foundation
import DozableKit
import DozableHost

// `make test-cli-workspace`, the test hooks' rows (749, WS.02): a workspace's manager and one worker run as the STUB AGENT
// (`DOZ_TEST_STUB_AGENT=1` in this guarded run — `doz debug stub-agent`, inside doz) through the real doz, its daemon, the chat
// server it runs and the real deckhold-mac — fenced, a scratch fence home, NO claude anywhere on the sessions' PATH, no VM.
//
//  T1. the hooks refuse outside a guarded run (DOZ_TEST_REAL_MAC=1): doz debug crash and doz debug stub-agent → 9
//  T2. start: "sera is up" (the manager) in the room; the log says "sera joined"
//  T3. worker add --task: "tess is up", then "task: count the files", then "done"; the log says "tess joined"; a VM worker
//      under the stub is refused (65), nothing made
//  T4. "@tess hello" → "ack <the first 8 of its id>"; "@tess /stub ping" → "pong"
//  T5. /stub write: inside its folder "wrote out.txt" (the file written); in the store "refused …: no folder.write grant …";
//      /stub ask → sera's ask (yes/no) in the room
//  T6. sleep: both exit 0 quietly (no crash line); wake: "sera is up" and "tess is up" again, its task not again
//  T7. doz debug crash stb/tess → "tess crashed: exit 70" in workspace log (and --json), tess posts nothing; W or AGENT
//      not found → 2
//  T8. /stub exit 3 (after a wake) → "tess crashed: exit 3"
func cliWorkspaceStubRows(_ h: CLIHarness, root: URL, store: DozableStore, started: inout Set<String>) {
    print("cli: the test hooks — the stub agent as a manager and a worker, fenced on this Mac, no claude")
    let fm = FileManager.default
    let brief = root.appendingPathComponent("stub-brief.md").path
    try? "Count the files.\n".write(toFile: brief, atomically: true, encoding: .utf8)
    let home = URL(fileURLWithPath: "/private/tmp/dzo-\(getpid())-wst-home")
    try? fm.removeItem(at: home)
    try? fm.createDirectory(at: home, withIntermediateDirectories: true)
    let work = URL(fileURLWithPath: "/private/tmp/dzo-\(getpid())-wst-work")
    try? fm.createDirectory(at: work, withIntermediateDirectories: true)
    defer {
        for s in ["stb", "stb-tess"] { h.run(["sessions", "end", "@mac", s, "--yes"], timeout: 30) }
        h.env[StubAgent.variable] = nil
        try? fm.removeItem(at: home)
        try? fm.removeItem(at: work)
    }

    func messages(_ room: String) -> [[String: Any]] {
        let r = h.run(["chat", "read", room, "--last", "200", "--json"])
        return ((try? JSONSerialization.jsonObject(with: r.outData)) as? [[String: Any]]) ?? []
    }
    func said(_ room: String, _ who: String) -> [String] {
        messages(room).filter { $0["from"] as? String == who }.compactMap { $0["content"] as? String }
    }
    func count(_ room: String, _ who: String, _ text: String) -> Int { said(room, who).filter { $0 == text }.count }
    func logText(_ w: String) -> String { h.run(["workspace", "log", w]).out }
    func send(_ room: String, _ text: String) -> String {
        let r = h.run(["chat", "send", room, text, "--json"])
        return ((try? JSONSerialization.jsonObject(with: r.outData)) as? [String: Any])?["msg_id"] as? String ?? ""
    }
    func running(_ s: String) -> Bool { h.sessions("@mac").first { $0.name == s }.map { !$0.ended && $0.gone != true } ?? false }

    // The daemon again with the stub agent on, the fence's scratch home, and a PATH with no claude on it.
    h.run(["daemon", "stop"], timeout: 60)
    _ = h.waitFor(20) { !h.hostRunning }
    h.env["DOZ_TEST_FENCE_HOME"] = home.path
    h.env["DOZ_TEST_MAC_PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
    h.env[StubAgent.variable] = "1"
    h.run(["config", "set", "mac.account", "none"])
    var r = h.run(["chat", "on", "--name", "ada"], timeout: 60)
    check(r.code == 0, "T1 chat on with the stub agent (\(r.code) \(r.err.prefix(160)))")

    // T1. refused unguarded (the guard lifted on purpose): nothing signalled, nothing posted.
    h.env["DOZ_TEST_REAL_MAC"] = "1"
    r = h.run(["debug", "crash", "stb/tess"], timeout: 30)
    check(r.code == 9 && r.err.contains("guarded test run"), "T1 doz debug crash unguarded: not permitted, exit 9 (\(r.code) \(r.err.prefix(160)))")
    r = h.run(["debug", "stub-agent", "--name", "x"], timeout: 30)
    check(r.code == 9 && r.err.contains("test hook"), "T1 doz debug stub-agent unguarded: exit 9 (\(r.code) \(r.err.prefix(160)))")
    h.env["DOZ_TEST_REAL_MAC"] = nil
    check(!h.run(["--help"]).out.split(separator: "\n").contains { $0.hasPrefix("  debug") }, "T1 doz --help does not list debug")

    // T2. the manager
    r = h.run(["bot", "new", "sera", "--agent", "claude-code", "--isolation", "fenced", "--deliver", "poll"], timeout: 60)
    check(r.code == 0, "T2 bot new sera (\(r.code) \(r.err.prefix(160)))")
    r = h.run(["workspace", "new", "stb", "--prompt-file", brief, "--folder", work.path, "--manager", "sera"], timeout: 60)
    check(r.code == 0, "T2 new stb --manager sera (\(r.code) \(r.err.prefix(200)))")
    r = h.run(["workspace", "start", "stb"], timeout: 120)
    if r.code == 0 { started.insert("stb") }
    check(r.code == 0, "T2 start stb with no claude on the PATH (\(r.code) \(r.out.prefix(200)) \(r.err.prefix(300)))")
    check(h.waitFor(30) { count("stb", "sera", "sera is up") == 1 }, "T2 \"sera is up\" in the room (\(said("stb", "sera")))")
    check(logText("stb").contains("sera joined"), "T2 the log says \"sera joined\"")
    let argv = MacSessions(store: store, readOnly: true).records().sessions["stb"]?.argv ?? []
    check(argv.contains("stub-agent") && !argv.contains { ($0 as NSString).lastPathComponent == "claude" }, "T2 the manager's program is the stub agent (\(argv.suffix(4)))")

    // T3. the worker
    r = h.run(["worker", "add", "stb", "tess", "--task", "count the files"], timeout: 120)
    if r.code == 0 { started.insert("stb-tess") }
    check(r.code == 0, "T3 worker add stb tess --task … (\(r.code) \(r.err.prefix(300)))")
    check(h.waitFor(30) { said("stb", "tess").contains("done") }, "T3 tess says done (\(said("stb", "tess")))")
    check(said("stb", "tess") == ["tess is up", "task: count the files", "done"], "T3 …after \"tess is up\" and \"task: count the files\", in order")
    check(logText("stb").contains("tess joined"), "T3 the log says \"tess joined\"")
    r = h.run(["worker", "add", "stb", "vic", "--isolation", "vm", "--task", "x"], timeout: 60)
    check(r.code == 65 && r.err.contains("stub agent") && h.run(["worker", "ls", "stb"]).out.contains("vic") == false,
          "T3 a VM worker under the stub: refused, nothing made (\(r.code) \(r.err.prefix(200)))")
    check(h.run(["worker", "ls", "stb"]).out.contains("tess"), "T3 worker ls shows tess")

    // T4. addressed
    let hello = send("stb", "@tess hello")
    check(!hello.isEmpty && h.waitFor(20) { said("stb", "tess").contains("ack " + hello.prefix(8)) }, "T4 @tess hello → ack \(hello.prefix(8)) (\(said("stb", "tess").suffix(2)))")
    _ = send("stb", "@tess /stub ping")
    check(h.waitFor(20) { said("stb", "tess").contains("pong") }, "T4 /stub ping → pong")
    check(!said("stb", "sera").contains { $0.hasPrefix("ack ") }, "T4 sera answers nothing not addressed to her")

    // T5. a write inside and outside its folder; an ask
    _ = send("stb", "@tess /stub write out.txt")
    check(h.waitFor(20) { said("stb", "tess").contains("wrote out.txt") }, "T5 /stub write out.txt → wrote out.txt (\(said("stb", "tess").suffix(1)))")
    check((try? String(contentsOf: work.appendingPathComponent("out.txt"), encoding: .utf8)) == "written by the stub agent tess\n", "T5 …the file is in its folder")
    let outside = store.root.appendingPathComponent("stub-outside.txt").path
    _ = send("stb", "@tess /stub write \(outside)")
    check(h.waitFor(20) { said("stb", "tess").contains { $0.hasPrefix("refused \(outside): ") && $0.contains("folder.write") } },
          "T5 a write into the store → refused, naming the folder.write grant (\(said("stb", "tess").suffix(1)))")
    check(!fm.fileExists(atPath: outside), "T5 …and nothing written there")
    _ = send("stb", "@sera /stub ask ship it?")
    check(h.waitFor(20) { messages("stb").contains { $0["from"] as? String == "sera" && ($0["kind"] as? String == "ask" || ($0["content"] as? String)?.contains("ship it?") == true) } },
          "T5 /stub ask → sera's ask in the room")

    // T6. sleep and wake
    r = h.run(["workspace", "sleep", "stb"], timeout: 180)
    check(r.code == 0 && h.waitFor(20) { !running("stb") && !running("stb-tess") }, "T6 sleep stb: both ended (\(r.code) \(r.err.prefix(200)))")
    Thread.sleep(forTimeInterval: 2)
    check(!logText("stb").contains("crashed"), "T6 …quietly: no crash line")
    r = h.run(["workspace", "wake", "stb"], timeout: 180)
    check(r.code == 0, "T6 wake stb (\(r.code) \(r.err.prefix(200)))")
    check(h.waitFor(30) { count("stb", "sera", "sera is up") == 2 && count("stb", "tess", "tess is up") == 2 },
          "T6 …\"sera is up\" and \"tess is up\" again (\(said("stb", "tess").suffix(3)))")
    check(count("stb", "tess", "done") == 1, "T6 …its task not again")

    // T7. doz debug crash
    let before = said("stb", "tess").count
    r = h.run(["debug", "crash", "stb/tess"], timeout: 30)
    check(r.code == 0, "T7 doz debug crash stb/tess (\(r.code) \(r.err.prefix(200)))")
    check(h.waitFor(20) { logText("stb").contains("tess crashed: exit 70") }, "T7 workspace log: \"tess crashed: exit 70\" (\(logText("stb").suffix(300)))")
    let j = h.run(["workspace", "log", "stb", "--json"])
    let crashed = ((try? JSONSerialization.jsonObject(with: j.outData)) as? [[String: Any]])?.last { $0["action"] as? String == "agent-crashed" }
    check(crashed?["agent"] as? String == "tess" && crashed?["exitCode"] as? Int == 70, "T7 …and in --json (agent-crashed, exitCode 70)")
    check(said("stb", "tess").count == before, "T7 …tess posted nothing")
    check(h.run(["debug", "crash", "stb/nobody"]).code == 2, "T7 an unknown agent: exit 2")
    check(h.run(["debug", "crash", "nows/tess"]).code == 2, "T7 an unknown workspace: exit 2")

    // T8. /stub exit after a wake
    h.run(["workspace", "sleep", "stb"], timeout: 180)
    r = h.run(["workspace", "wake", "stb"], timeout: 180)
    check(r.code == 0 && h.waitFor(30) { count("stb", "tess", "tess is up") == 3 }, "T8 wake again: tess is up (\(r.code) \(r.err.prefix(200)))")
    _ = send("stb", "@tess /stub exit 3")
    check(h.waitFor(20) { logText("stb").contains("tess crashed: exit 3") }, "T8 /stub exit 3 → \"tess crashed: exit 3\"")

    h.run(["worker", "end", "stb", "tess"], timeout: 60)
    h.run(["workspace", "stop", "stb"], timeout: 60)
    started.remove("stb")
    started.remove("stb-tess")
}
