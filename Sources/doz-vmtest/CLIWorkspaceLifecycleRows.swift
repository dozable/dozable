import Darwin
import Foundation
import DozableKit
import DozableHost

// `make test-cli-workspace`, the lifecycle rows (after rows 1–47, in the same scratch store): a workspace's lifecycle through
// the real doz, its daemon, the chat server and the real deckhold-mac — no VM, the memory keychain, `freePort()` chat ports, a
// scratch fence home, a scratch Bin (DOZ_TEST_TRASH_DIR: never the real one), scratch Claude folders, and a FAKE `claude`
// (first on the sessions' PATH) that says it is up in its room and, in a fenced session, records the conversation it holds
// as Claude Code does (`$CLAUDE_CONFIG_DIR/sessions/<pid>.json` and a transcript) — never the real claude. `life`: a fenced
// manager (lena), an anonymous fenced worker (lw1), an anonymous unfenced worker (lw2), a worker from a bot (remy), and an
// adopted session on this Mac running a harmless program (lshell).
//
//  L1. sleep --dry-run: the table (each agent, lshell "starts fresh"), exit 0; nothing written, nothing slept
//  L2. sleep: the manager and the workers ended, their records kept, asleep; lw1's launch secret kept (its ledger line);
//      no dzc_ in ps, the store's files or the fence home
//  L3. wake: lena and lw1 back in the same conversations (`--resume <the id each held>`), awake; lw1's ledger line kept
//  L4. lw2's token file gone while asleep and back 0600 in 0700 after the wake
//  L5. lshell, a program with no conversation: ended at sleep, running again after wake
//  L6. delete while it runs → exit 3; finish with no terminal and no --yes → exit 5, nothing done; with --yes finished,
//      the room still takes a post, worker add refused
//  L7. reopen, then wake: running again
//  L8. archive: the typed name refused under --json without --yes (exit 5); with --yes archived, the room read-only, lw2's
//      old token 401, remy's token held
//  L9. restore: the room writable, finished, the retired workers listed ended
//  L10. delete: the record gone, its folder untouched, lshell loose, the room archived and readable
//  L11. --bin-folders: a scratch folder moved into the test's Bin; the store (and your home, in a dry run) refused by name
//  L12. --if-plan with an old plan → exit 3, nothing done
//  L13. chat off: archive refused naming doz chat on
//  L14. the daemon stopped: every verb's --dry-run answers, and no daemon starts
func cliWorkspaceLifecycleRows(_ h: CLIHarness, root: URL, store: DozableStore, started: inout Set<String>) {
    print("cli: a workspace's lifecycle — sleep, wake, finish, reopen, archive, restore, delete")
    let fm = FileManager.default
    let ws = WorkspaceStore(store: store)
    let pid = getpid()
    let home = URL(fileURLWithPath: "/private/tmp/dzo-\(pid)-wsl-home")
    let lwork = URL(fileURLWithPath: "/private/tmp/dzo-\(pid)-wsl-work")
    let trash = URL(fileURLWithPath: "/private/tmp/dzo-\(pid)-wsl-bin")
    let scratch = URL(fileURLWithPath: "/private/tmp/dzo-\(pid)-wsl-scratch")
    let projects = URL(fileURLWithPath: "/private/tmp/dzo-\(pid)-wsl-claude/projects")
    for d in [home, lwork, trash, scratch, projects] { try? fm.removeItem(at: d); try? fm.createDirectory(at: d, withIntermediateDirectories: true) }
    chmod(scratch.path, 0o700)
    defer {
        for d in [home, lwork, trash, scratch, projects.deletingLastPathComponent()] { try? fm.removeItem(at: d) }
        try? fm.removeItem(atPath: "/private/tmp/dzo-\(pid)-wsl-binme")
    }
    let brief = root.appendingPathComponent("life-brief.md").path
    try? "Look after the launch.\n".write(toFile: brief, atomically: true, encoding: .utf8)
    let bin = home.appendingPathComponent(".local/bin")
    try? fm.createDirectory(at: bin, withIntermediateDirectories: true)
    // The FAKE claude: in a fenced session (CLAUDE_CONFIG_DIR, its own agent folder) it records the conversation it holds —
    // a new one, or the one it was resumed with — as Claude Code does; then it says it is up and sleeps.
    let fake = """
    #!/bin/sh
    start=""; res=""; prev=""
    for a in "$@"; do
      case "$prev" in --resume|-r) res="$a" ;; esac
      case "$a" in "Read "*" and do what it says.") start="${a#Read }"; start="${start% and do what it says.}" ;; esac
      prev="$a"
    done
    if [ -n "$CLAUDE_CONFIG_DIR" ]; then
      id="${res:-$(/usr/bin/uuidgen | tr 'A-Z' 'a-z')}"
      mkdir -p "$CLAUDE_CONFIG_DIR/sessions"
      printf '{"pid":%s,"sessionId":"%s","cwd":"%s"}\\n' "$$" "$id" "$(pwd -P)" > "$CLAUDE_CONFIG_DIR/sessions/$$.json"
      folder="$CLAUDE_CONFIG_DIR/projects/$(pwd -P | sed 's/[^A-Za-z0-9]/-/g')"
      mkdir -p "$folder"; [ -f "$folder/$id.jsonl" ] || echo '{}' > "$folder/$id.jsonl"
    fi
    [ -n "$start" ] || exec sleep 600
    first=$(head -n 1 "$start")
    room=$(sed -n 's/^Your room in chat: //p' "$start")
    bot=$(printf '%s' "$first" | sed -n 's/^You are \\([^,]*\\),.*/\\1/p')
    dozchat send "$room" "$bot is up: $first" > /dev/null 2>&1
    exec sleep 600

    """
    try? fake.write(to: bin.appendingPathComponent("claude"), atomically: true, encoding: .utf8)
    chmod(bin.appendingPathComponent("claude").path, 0o755)
    let dozchat = (h.binary as NSString).deletingLastPathComponent + "/dozchat-mac"
    try? fm.createSymbolicLink(atPath: bin.appendingPathComponent("dozchat").path, withDestinationPath: dozchat)

    func text(_ p: String) -> String { (try? String(contentsOfFile: p, encoding: .utf8)) ?? "" }
    func sha(_ p: String) -> String { (try? Data(contentsOf: URL(fileURLWithPath: p))).map(WorkspaceStore.sha256) ?? "" }
    func mode(_ p: String) -> mode_t { var st = stat(); return lstat(p, &st) == 0 ? st.st_mode & 0o777 : 0 }
    func detail(_ n: String) -> WorkspaceDetail? { h.json(["workspace", "show", n], WorkspaceDetail.self) }
    func macRow(_ s: String) -> SessionRow? { h.sessions("@mac").first { $0.name == s } }
    func runs(_ s: String) -> Bool { macRow(s).map { !$0.ended && $0.gone != true } ?? false }
    func ended(_ s: String) -> Bool { macRow(s).map { $0.ended } ?? false }
    func records() -> [String: MacSessionRecord] { MacSessions(store: store, readOnly: true).records().sessions }
    func ledger() -> [String: String] { LaunchSecretLedger.load(store).items }
    func plan(_ args: [String]) -> WorkspaceLifecyclePlan? { h.json(["workspace"] + args + ["--dry-run"], WorkspaceLifecyclePlan.self) }
    func psText() -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axww", "-o", "command="]
        let o = Pipe()
        p.standardOutput = o
        try? p.run()
        let d = o.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: d, as: UTF8.self)
    }
    func holders(_ needle: String, under dir: String) -> [String] {
        guard let e = fm.enumerator(atPath: dir) else { return [] }
        var out: [String] = []
        while let rel = e.nextObject() as? String {
            let p = dir + "/" + rel
            var st = stat()
            guard lstat(p, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_size < 32 << 20 else { continue }
            if let d = fm.contents(atPath: p), d.range(of: Data(needle.utf8)) != nil { out.append(p) }
        }
        return out
    }
    let temp = WorkspaceStore.resolved(NSTemporaryDirectory())
    func tokenDirs(_ session: String) -> [String] {
        ((try? fm.contentsOfDirectory(atPath: temp)) ?? []).filter { $0.hasPrefix("doz-") }.map { temp + "/" + $0 + "/manager-" + session }
            .filter { fm.fileExists(atPath: $0) }
    }
    func dozchatRooms(tokenFile: String, port: String) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: dozchat)
        p.arguments = ["rooms"]
        p.environment = ["CHAT_TOKEN_FILE": tokenFile, "CHAT_URL": "http://127.0.0.1:\(port)", "PATH": "/usr/bin:/bin", "NO_PROXY": "*"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
    func stopDaemon() {
        h.run(["daemon", "stop"], timeout: 60)
        _ = h.waitFor(20) { !h.hostRunning }
    }
    let sessions = ["life", "life-lw1", "life-lw2", "life-remy", "lshell"]

    // The daemon again with this file's seams: its fence home and PATH, the Claude folders, the Bin.
    stopDaemon()
    h.env["DOZ_TEST_FENCE_HOME"] = home.path
    h.env["DOZ_TEST_MAC_PATH"] = bin.path + ":/usr/bin:/bin:/usr/sbin:/sbin"
    h.env["DOZ_TEST_CLAUDE_PROJECTS"] = projects.path
    h.env["DOZ_TEST_TRASH_DIR"] = trash.path
    var r = h.run(["chat", "on", "--name", "ada"], timeout: 60)
    check(r.code == 0, "L chat on again (\(r.code) \(r.err.prefix(120)))")
    let port = h.run(["config", "get", "chat.page_port"]).out.trimmingCharacters(in: .whitespacesAndNewlines)
    h.run(["bot", "new", "lena", "--agent", "claude-code", "--isolation", "fenced"], timeout: 60)
    h.run(["bot", "new", "remy", "--agent", "claude-code", "--isolation", "fenced"], timeout: 60)
    r = h.run(["workspace", "new", "life", "--prompt-file", brief, "--folder", lwork.path, "--manager", "lena"], timeout: 60)
    check(r.code == 0, "L new life --manager lena (\(r.code) \(r.err.prefix(200)))")
    r = h.run(["workspace", "start", "life"], timeout: 120)
    if r.code == 0 { started.insert("life") }
    check(r.code == 0, "L start life (\(r.code) \(r.err.prefix(200)))")
    for (args, s) in [(["lw1", "--task", "list the files"], "life-lw1"), (["lw2", "--isolation", "unfenced", "--task", "say hello"], "life-lw2"),
                      (["--from-bot", "remy", "--task", "watch"], "life-remy")] {
        r = h.run(["worker", "add", "life"] + args, timeout: 120)
        if r.code == 0 { started.insert(s) }
        check(r.code == 0, "L worker add life \(args[0]) (\(r.code) \(r.err.prefix(200)))")
    }
    r = h.run(["run", "@mac", "-d", "--unfenced", "--session", "lshell", "--folder", lwork.path, "--", "/bin/sh", "-c", "exec sleep 600"], timeout: 60)
    if r.code == 0 { started.insert("lshell") }
    r = h.run(["workspace", "adopt", "life", "@mac/lshell"])
    check(r.code == 0, "L adopt life @mac/lshell (\(r.code) \(r.err.prefix(160)))")
    // The fenced ones have said who they are and which conversation they hold (learned at the latest when they end).
    check(h.waitFor(30) { ["life", "life-lw1", "life-lw2", "life-remy", "lshell"].allSatisfy(runs) }, "L every agent of life runs")

    // L1. the dry run
    let recSHA = sha(ws.folder("life") + "/workspace.json"), logSHA = sha(ws.folder("life") + "/log.jsonl")
    r = h.run(["workspace", "sleep", "life", "--dry-run"], timeout: 60)
    let p1 = plan(["sleep", "life"])
    check(r.code == 0 && r.out.contains("lena") && r.out.contains("AFTER") && r.out.contains("The command:\ndoz workspace sleep life"),
          "L1 sleep --dry-run: the table and the command, exit 0 (\(r.code) \(r.out.prefix(300)))")
    check(p1?.rows.first { $0.name == "lshell" }?.back == "starts fresh" && p1?.rows.first { $0.name == "lena" }?.back == "resumes its conversation",
          "L1 …lshell starts fresh, lena resumes her conversation")
    check(sha(ws.folder("life") + "/workspace.json") == recSHA && sha(ws.folder("life") + "/log.jsonl") == logSHA && sessions.allSatisfy(runs),
          "L1 …nothing written, nothing slept")

    // L2. sleep
    let lw2Dirs = tokenDirs("life-lw2")
    check(lw2Dirs.count == 1 && text(lw2Dirs.first.map { $0 + "/chat-token" } ?? "").hasPrefix("dzc_"), "L4 lw2's token file is there while it runs")
    r = h.run(["workspace", "sleep", "life"], timeout: 180)
    check(r.code == 0 && r.out.contains("life is asleep"), "L2 sleep life (\(r.code) \(r.out.suffix(300)) \(r.err.prefix(300)))")
    check(sessions.allSatisfy(ended), "L2 …every session ended, its record kept (\(sessions.map { "\($0):\(macRow($0).map { $0.ended ? "ended" : "running" } ?? "gone")" }))")
    check(detail("life")?.state == "asleep", "L2 …asleep (\(detail("life")?.state ?? "?"))")
    let held = records()
    let lenaID = held["life"]?.claudeSessionID, lw1ID = held["life-lw1"]?.claudeSessionID
    check(lenaID != nil && lw1ID != nil, "L2 …the conversations lena and lw1 held are recorded (\(lenaID ?? "nil"), \(lw1ID ?? "nil"))")
    check(ledger().values.contains("mac.life-lw1"), "L2 …lw1's launch secret survived its session's end (its ledger line)")
    check(!psText().contains("dzc_") && holders("dzc_", under: store.root.path).isEmpty && holders("dzc_", under: home.path).isEmpty,
          "L2 the leak sweep: no dzc_ in ps, the store's files or the fence home")
    // L4. lw2's token file gone while asleep
    check(tokenDirs("life-lw2").isEmpty, "L4 lw2's token file is gone while it sleeps")

    // L3. wake: the same conversations
    r = h.run(["workspace", "wake", "life"], timeout: 180)
    check(r.code == 0, "L3 wake life (\(r.code) \(r.out.suffix(300)) \(r.err.prefix(300)))")
    check(h.waitFor(30) { sessions.allSatisfy(runs) }, "L3 …every agent runs again")
    let ps = psText()
    check(lenaID.map { ps.contains("--resume \($0)") } == true && lw1ID.map { ps.contains("--resume \($0)") } == true,
          "L3 …lena and lw1 resumed the same conversations")
    check(ledger().values.contains("mac.life-lw1") && h.run(["chat", "who"]).out.contains("lw1"), "L3 …lw1 kept its token (its ledger line, still in chat)")
    check(detail("life").map { $0.state != "asleep" && $0.agents.allSatisfy { $0.state == "running" } } == true, "L3 …awake (\(detail("life")?.state ?? "?"))")
    // L4. back 0600 in 0700
    let back = tokenDirs("life-lw2")
    let lw2File = back.first.map { $0 + "/chat-token" } ?? "/nonexistent-x"
    check(back.count == 1 && mode(back[0]) == 0o700 && mode(lw2File) == 0o600 && text(lw2File).hasPrefix("dzc_"), "L4 …and back 0600 in 0700 after the wake")
    let lw2Copy = scratch.appendingPathComponent("lw2-token").path
    if let d = fm.contents(atPath: lw2File) { fm.createFile(atPath: lw2Copy, contents: d, attributes: [.posixPermissions: 0o600]) }
    check(dozchatRooms(tokenFile: lw2Copy, port: port) == 0, "L4 …its new token works")
    // L5. lshell
    check(runs("lshell") && (p1?.rows.first { $0.name == "lshell" }?.changes == true), "L5 lshell, no conversation: ended at sleep, running again")

    // L6. delete while running; finish asks
    r = h.run(["workspace", "delete", "life", "--yes"], timeout: 60)
    check(r.code == 3 && r.err.contains("finish it first"), "L6 delete while it runs: exit 3 (\(r.code) \(r.err.prefix(200)))")
    r = h.run(["workspace", "finish", "life"], timeout: 60)
    check(r.code == 5 && detail("life")?.flags.finishedAt == nil && sessions.allSatisfy(runs), "L6 finish with no terminal and no --yes: exit 5, nothing done (\(r.code))")
    r = h.run(["workspace", "finish", "life", "--yes"], timeout: 180)
    check(r.code == 0 && detail("life")?.state == "finished", "L6 finish --yes: finished (\(r.code) \(r.err.prefix(300)))")
    check(sessions.allSatisfy(ended), "L6 …everything stopped")
    r = h.run(["chat", "send", "life", "still here"])
    check(r.code == 0, "L6 …the room still takes a post (\(r.code) \(r.err.prefix(160)))")
    r = h.run(["worker", "add", "life", "--task", "more"], timeout: 60)
    check(r.code == 3, "L6 …worker add refused (\(r.code))")

    // L7. reopen, then wake
    r = h.run(["workspace", "reopen", "life"], timeout: 60)
    check(r.code == 0 && detail("life")?.state == "asleep", "L7 reopen: asleep until woken (\(r.code) \(detail("life")?.state ?? "?"))")
    r = h.run(["workspace", "wake", "life"], timeout: 180)
    check(r.code == 0 && h.waitFor(30) { sessions.allSatisfy(runs) }, "L7 …wake: running again (\(r.code) \(r.err.prefix(300)))")

    // L12. an old plan
    let old = plan(["sleep", "life"])?.sha ?? "?"
    h.run(["sessions", "end", "@mac", "lshell", "--yes"], timeout: 30)
    r = h.run(["workspace", "sleep", "life", "--if-plan", old], timeout: 60)
    check(r.code == 3 && r.err.contains("changed since you looked") && runs("life"), "L12 --if-plan with an old plan: exit 3, nothing done (\(r.code) \(r.err.prefix(200)))")

    // L13. chat off: archive refused with the fix
    h.run(["chat", "off"], timeout: 30)
    r = h.run(["workspace", "archive", "life", "--yes"], timeout: 60)
    check(r.code == 6 && r.err.contains("doz chat on"), "L13 chat off: archive refused naming doz chat on (\(r.code) \(r.err.prefix(200)))")
    h.run(["chat", "on", "--name", "ada"], timeout: 60)

    // L8. archive
    r = h.run(["workspace", "archive", "life", "--json"], timeout: 60)
    check(r.code == 5 && detail("life")?.flags.archivedAt == nil, "L8 archive --json without --yes: the typed name refused, exit 5 (\(r.code))")
    r = h.run(["workspace", "archive", "life", "--yes"], timeout: 240)
    check(r.code == 0 && detail("life")?.state == "archived", "L8 archive --yes: archived (\(r.code) \(r.err.prefix(300)))")
    r = h.run(["chat", "send", "life", "after the archive"])
    check(r.code != 0, "L8 …the room is read-only (\(r.code))")
    check(h.run(["chat", "read", "life"]).code == 0, "L8 …and readable")
    check(dozchatRooms(tokenFile: lw2Copy, port: port) == 4, "L8 …lw2's old token: 401")
    let remy = h.json(["bot", "show", "remy"], BotDetail.self)
    check(remy?.token.keeper == "dozable", "L8 …remy's token held (\(remy?.token.keeper ?? "?"))")
    check(!h.run(["chat", "who"]).out.split(separator: "\n").contains { $0.hasPrefix("lw1 ") }, "L8 …lw1 retired: out of chat")

    // L9. restore
    r = h.run(["workspace", "restore", "life"], timeout: 60)
    check(r.code == 0 && detail("life")?.state == "finished", "L9 restore: finished (\(r.code) \(r.err.prefix(200)))")
    check(h.run(["chat", "send", "life", "back again"]).code == 0, "L9 …the room is writable")
    let all = h.json(["worker", "ls", "life", "--all"], WorkerListing.self)
    check(["lw1", "lw2"].allSatisfy { n in all?.agents.contains { $0.name == n && $0.state == "ended" } == true }, "L9 …the retired workers are listed ended")

    // L10. delete
    r = h.run(["workspace", "delete", "life", "--yes"], timeout: 120)
    check(r.code == 0 && !ws.exists("life"), "L10 delete: the record gone (\(r.code) \(r.err.prefix(300)))")
    check(fm.fileExists(atPath: lwork.path), "L10 …its folder untouched")
    check(h.json(["workspace", "ls", "--loose"], WorkspaceListing.self)?.loose.contains { $0.name == "@mac/lshell" } == true, "L10 …lshell is loose again")
    check(h.run(["chat", "read", "life"]).code == 0 && h.run(["chat", "send", "life", "gone"]).code != 0, "L10 …the room archived and readable")
    for s in ["life", "life-lw1", "life-lw2", "life-remy"] { started.remove(s) }

    // L11. the Bin
    let binme = URL(fileURLWithPath: "/private/tmp/dzo-\(pid)-wsl-binme")
    try? fm.createDirectory(at: binme, withIntermediateDirectories: true)
    try? "x\n".write(to: binme.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
    h.run(["workspace", "new", "binw", "--prompt-file", brief, "--folder", binme.path, "--no-room"], timeout: 60)
    h.run(["workspace", "finish", "binw", "--yes"], timeout: 60)
    r = h.run(["workspace", "delete", "binw", "--bin-folders", "--yes"], timeout: 60)
    check(r.code == 0 && !fm.fileExists(atPath: binme.path) && fm.fileExists(atPath: trash.appendingPathComponent(binme.lastPathComponent + "/note.txt").path),
          "L11 --bin-folders: moved into the test's Bin, never deleted (\(r.code) \(r.err.prefix(200)))")
    h.run(["workspace", "new", "binx", "--prompt-file", brief, "--folder", WorkspaceStore.resolved(store.root.path), "--no-room"], timeout: 60)
    h.run(["workspace", "finish", "binx", "--yes"], timeout: 60)
    r = h.run(["workspace", "delete", "binx", "--bin-folders", "--yes"], timeout: 60)
    check(r.code == 64 && r.err.contains("holds Dozable's store") && ws.exists("binx") && fm.fileExists(atPath: store.root.path),
          "L11 the store refused by name, nothing moved (\(r.code) \(r.err.prefix(200)))")
    let realHome = TestSafety.realHome.path
    h.run(["workspace", "new", "binh", "--prompt-file", brief, "--folder", realHome, "--no-room"], timeout: 60)
    h.run(["workspace", "finish", "binh", "--yes"], timeout: 60)
    r = h.run(["workspace", "delete", "binh", "--bin-folders", "--dry-run"], timeout: 60)
    check(r.code == 64 && r.out.contains("your home folder"), "L11 your home refused by name (a dry run only) (\(r.code) \(r.out.suffix(200)))")
    for n in ["binx", "binh"] { h.run(["workspace", "delete", n, "--yes"], timeout: 60) }

    // L14. the daemon stopped: every verb's dry run answers, none starts.
    h.run(["workspace", "new", "idle", "--prompt-file", brief, "--no-room"], timeout: 60)
    stopDaemon()
    var answered: [String] = []
    for v in WorkspaceVerb.allCases where v != .stop {
        let x = h.run(["workspace", v.rawValue, "idle", "--dry-run", "--json"], timeout: 60)
        if (try? HostWire.decoder.decode(WorkspaceLifecyclePlan.self, from: x.outData))?.verb == v.rawValue { answered.append(v.rawValue) }
    }
    check(answered.count == 7, "L14 the daemon stopped: every verb's --dry-run answers (\(answered))")
    check(!h.hostRunning, "L14 …and no daemon started")
}
