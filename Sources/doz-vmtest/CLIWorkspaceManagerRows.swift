import Darwin
import Foundation
import DozableKit
import DozableHost

// `make test-cli-workspace`, the manager rows (after rows 1–11, in the same scratch store): a workspace's manager started
// from its bot through the real doz, its daemon, the chat server it runs and the real deckhold-mac — no VM, no UI, the
// memory keychain, ports from freePort(), `mac.account none`, a scratch fence home, and a FAKE `claude` first on the
// sessions' PATH that reads START and says "BOT is up: <its first line>" with dozchat, then sleeps (never the real claude).
//
//  12. bot new mira (fenced, poll); workspace new mgr --manager mira: fenced, not started, setting up, the room empty
//  13. a gap (a folder removed, chat off): start refused listing every gap; the record unchanged; nothing posted; no session
//  14. start mgr: the room has the invite, then your brief as your first message, then mira's "is up"; sessions @mac --json
//      shows it fenced in workspace mgr; the state idle or working
//  15. the leak sweep: no dzc_ in ps, sessions.json, workspace.json, log.jsonl, daemon.log, server.log or any --json;
//      etc/secrets/CHAT_TOKEN holds a doz_cred_ placeholder; the record's secret has bot mira and no item
//  16. new mgr2 --manager mira; start mgr2 refused with the sentence; nothing posted, no session
//  17. stop mgr: ended, record kept, asleep; bot show mira: its token held; then start mgr2 works; stop mgr2
//  18. start mgr again: your message count stays 1; the session runs again
//  19. unfenced (separable): bot new otto --isolation unfenced; new solo --manager otto → fenced; edit --manager-isolation
//      unfenced → "acts as you" in show, ls and --json; on start the token file is 0600 in 0700 and the only dzc_
//      holder; after stop it is gone
//  20. a VM manager recorded, no VM booted: new vmw --manager vera --manager-isolation vm → vm; a sandbox of its name
//      already there → the check lists it; nothing boots
//  21. refusals: an unknown, retired or elsewhere bot; a fenced inbox bot (the fix named); a webhook bot; releasing a
//      running manager
//  22. the daemon stopped: workspace ls / show give the manager and the state, and no daemon starts
func cliWorkspaceManagerRows(_ h: CLIHarness, root: URL, store: DozableStore, started: inout Set<String>) {
    print("cli: a workspace's manager — fenced on this Mac, a FAKE claude")
    let fm = FileManager.default
    let ws = WorkspaceStore(store: store)
    let marker = "MANAGER-BRIEF-\(UUID().uuidString.prefix(8))"
    let mbrief = root.appendingPathComponent("manager-brief.md").path
    try? "Ship the demo. \(marker)\n".write(toFile: mbrief, atomically: true, encoding: .utf8)
    // The fence's scratch home, and the sessions' PATH: the fake claude, dozchat (beside this doz).
    let home = URL(fileURLWithPath: "/private/tmp/dzo-\(getpid())-wsm-home")
    try? fm.removeItem(at: home)
    try? fm.createDirectory(at: home, withIntermediateDirectories: true)
    // The manager's folder: outside the store (a fenced session never reaches the store).
    let mwork = URL(fileURLWithPath: "/private/tmp/dzo-\(getpid())-wsm-work")
    try? fm.createDirectory(at: mwork, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: home); try? fm.removeItem(at: mwork) }
    // In the fence home's ~/.local/bin: a fenced program reads the PATH's folders of its home (never the store).
    let bin = home.appendingPathComponent(".local/bin")
    try? fm.createDirectory(at: bin, withIntermediateDirectories: true)
    let fake = """
    #!/bin/sh
    # A FAKE claude: finds "Read START and do what it says." among its arguments, says it is up in its room, then sleeps.
    start=""
    for a in "$@"; do
      case "$a" in "Read "*" and do what it says.") start="${a#Read }"; start="${start% and do what it says.}" ;; esac
    done
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
    try? fm.removeItem(atPath: bin.appendingPathComponent("dozchat").path)
    try? fm.createSymbolicLink(atPath: bin.appendingPathComponent("dozchat").path, withDestinationPath: dozchat)

    func text(_ p: String) -> String { (try? String(contentsOfFile: p, encoding: .utf8)) ?? "" }
    func sha(_ p: String) -> String { (try? Data(contentsOf: URL(fileURLWithPath: p))).map(WorkspaceStore.sha256) ?? "" }
    func mode(_ p: String) -> mode_t { var st = stat(); return lstat(p, &st) == 0 ? st.st_mode & 0o777 : 0 }
    func detail(_ n: String) -> WorkspaceDetail? { h.json(["workspace", "show", n], WorkspaceDetail.self) }
    func messages(_ room: String) -> [[String: Any]] {
        let r = h.run(["chat", "read", room, "--last", "100", "--json"])
        return ((try? JSONSerialization.jsonObject(with: r.outData)) as? [[String: Any]]) ?? []
    }
    func mine(_ room: String) -> [[String: Any]] { messages(room).filter { $0["from"] as? String == "ada" && ($0["kind"] as? String) != "change" } }
    func isUp(_ room: String, _ bot: String) -> Bool {
        messages(room).contains { $0["from"] as? String == bot && ($0["content"] as? String)?.hasPrefix("\(bot) is up: You are \(bot)") == true }
    }
    func macRow(_ s: String) -> SessionRow? { h.sessions("@mac").first { $0.name == s } }
    func running(_ s: String) -> Bool { macRow(s).map { !$0.ended && $0.gone != true } ?? false }
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
    /// Every regular file under `dir` holding `needle` (no link followed).
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

    // The daemon again with the fence's seams, chat on, no Claude login for fenced sessions.
    h.run(["daemon", "stop"], timeout: 60)
    _ = h.waitFor(20) { !h.hostRunning }
    h.env["DOZ_TEST_FENCE_HOME"] = home.path
    h.env["DOZ_TEST_MAC_PATH"] = bin.path + ":/usr/bin:/bin:/usr/sbin:/sbin"
    h.run(["config", "set", "mac.account", "none"])
    var r = h.run(["chat", "on", "--name", "ada"], timeout: 60)
    check(r.code == 0, "12 chat on again (\(r.code) \(r.err.prefix(120)))")

    // 12. a manager recorded, not started
    r = h.run(["bot", "new", "mira", "--agent", "claude-code", "--isolation", "fenced", "--deliver", "poll"], timeout: 60)
    check(r.code == 0, "12 bot new mira (fenced, poll) (\(r.code) \(r.err.prefix(160)))")
    r = h.run(["workspace", "new", "mgr", "--prompt-file", mbrief, "--folder", mwork.path, "--manager", "mira"], timeout: 60)
    check(r.code == 0 && r.out.hasPrefix("mgr — setting up · you") && r.out.contains("mira (manager, fenced in @mac/mgr, not started)"),
          "12 new mgr --manager mira: fenced, not started, setting up (\(r.code): \(r.out.prefix(300)) \(r.err.prefix(160)))")
    check(messages("mgr").filter { ($0["kind"] as? String) != "change" }.isEmpty, "12 the room mgr is empty")
    check(detail("mgr")?.agents.first?.isolation == "fenced" && detail("mgr")?.agents.first?.bot == "mira", "12 --json: isolation fenced, bot mira")

    // 13. gaps: every one listed, nothing written, posted or started
    let gone = root.appendingPathComponent("gone-folder")
    try? fm.createDirectory(at: gone, withIntermediateDirectories: true)
    h.run(["workspace", "edit", "mgr", "--add-folder", gone.path])
    try? fm.removeItem(at: gone)
    h.run(["chat", "off"], timeout: 30)
    let recSHA = sha(ws.folder("mgr") + "/workspace.json")
    r = h.run(["workspace", "start", "mgr"], timeout: 60)
    check(r.code == 3 && r.err.contains("a manager needs chat — doz chat on") && r.err.contains("is gone — doz workspace edit mgr --remove-folder"),
          "13 start with gaps: refused, every gap with its fix (\(r.code): \(r.err.prefix(400)))")
    check(sha(ws.folder("mgr") + "/workspace.json") == recSHA, "13 …the record unchanged")
    check(macRow("mgr") == nil, "13 …no session")
    h.run(["chat", "on", "--name", "ada"], timeout: 60)
    check(mine("mgr").isEmpty, "13 …nothing posted")
    h.run(["workspace", "edit", "mgr", "--remove-folder", gone.path])

    // 14. start: the invite, your brief first, then mira's "is up"
    r = h.run(["workspace", "start", "mgr"], timeout: 120)
    if r.code == 0 { started.insert("mgr") }
    check(r.code == 0 && r.out.contains("posted the brief in #mgr") && r.out.contains("started mira (fenced)"),
          "14 start mgr (\(r.code): \(r.out.prefix(200)) \(r.err.prefix(300)))")
    check(h.waitFor(30) { isUp("mgr", "mira") }, "14 mira says she is up in the room")
    let ms = messages("mgr")
    let invited = ms.firstIndex { ($0["content"] as? String)?.lowercased().contains("invited mira") == true }
    let briefAt = ms.firstIndex { $0["from"] as? String == "ada" && ($0["content"] as? String)?.contains(marker) == true }
    let upAt = ms.firstIndex { $0["from"] as? String == "mira" }
    check(invited != nil && briefAt != nil && upAt != nil && invited! < briefAt! && briefAt! < upAt!,
          "14 …the invite, then your brief, then mira (\(invited ?? -1), \(briefAt ?? -1), \(upAt ?? -1))")
    check(mine("mgr").count == 1 && mine("mgr").first.map { ($0["content"] as? String)?.contains(marker) == true } == true,
          "14 …the brief is your first message")
    let row = macRow("mgr")
    check(row?.fence != nil && row?.workspace == "mgr" && row?.ended == false, "14 sessions @mac --json: fenced, in workspace mgr")
    check(h.waitFor(10) { ["idle", "working"].contains(detail("mgr")?.state ?? "") }, "14 state idle or working (\(detail("mgr")?.state ?? "?"))")

    // 15. the leak sweep
    var jsons = ""
    for a in [["workspace", "show", "mgr"], ["workspace", "ls"], ["workspace", "log", "mgr"], ["sessions", "@mac"], ["bot", "show", "mira"],
              ["bot", "ls"], ["net", "show", "@mac", "mgr"]] {
        jsons += h.run(a + ["--json"]).out
    }
    check(!jsons.contains("dzc_"), "15 no dzc_ in any --json")
    let ps = psText()
    check(!ps.contains("dzc_"), "15 no dzc_ in ps")
    check(ps.contains("Read ") && ps.contains("and do what it says."), "15 …(the manager's first prompt is in ps: the sample saw it)")
    let leaks = holders("dzc_", under: store.root.path) + holders("dzc_", under: home.path)
    check(leaks.isEmpty, "15 no dzc_ in any file of the store (sessions.json, workspace.json, log.jsonl, daemon.log, server.log, …) or the fence home (\(leaks.prefix(3)))")
    let placeholders = (holders("doz_cred_", under: store.root.path) + holders("doz_cred_", under: home.path)).filter { $0.hasSuffix("/etc/secrets/CHAT_TOKEN") }
    check(placeholders.count == 1 && text(placeholders[0]).hasPrefix("doz_cred_"), "15 etc/secrets/CHAT_TOKEN holds a placeholder (\(placeholders.count))")
    let sessionsJSON = text(store.root.appendingPathComponent("mac-sessions/sessions.json").path)
    check(sessionsJSON.contains("\"bot\" : \"mira\"") || sessionsJSON.contains("\"bot\":\"mira\""), "15 the record's secret names bot mira")
    check(!sessionsJSON.contains("doz-secret-") && !sessionsJSON.contains("doz-bot-"), "15 …and no keychain item")

    // 16. a second live workspace for mira: refused
    r = h.run(["workspace", "new", "mgr2", "--prompt-file", mbrief, "--folder", mwork.path, "--manager", "mira"], timeout: 60)
    check(r.code == 0, "16 new mgr2 --manager mira (\(r.code) \(r.err.prefix(160)))")
    r = h.run(["workspace", "start", "mgr2"], timeout: 60)
    check(r.code == 4 && r.err.contains("mira already manages mgr, which is running. For now a bot runs in one live workspace at a time — doz workspace stop mgr first."),
          "16 start mgr2: refused with the sentence (\(r.code): \(r.err.prefix(240)))")
    check(mine("mgr2").isEmpty && macRow("mgr2") == nil, "16 …nothing posted, no session")

    // 17. stop: ended, kept, asleep; the token held; then mgr2 starts
    r = h.run(["workspace", "manager", "stop", "mgr"], timeout: 60)
    check(r.code == 0 && !running("mgr") && macRow("mgr") != nil, "17 stop mgr: ended, its record kept (\(r.code) \(r.err.prefix(160)))")
    check(detail("mgr")?.state == "asleep", "17 …asleep (\(detail("mgr")?.state ?? "?"))")
    check(h.json(["bot", "show", "mira"], BotDetail.self)?.token.keeper == "dozable", "17 bot show mira: its token held")
    r = h.run(["workspace", "manager", "stop", "mgr"], timeout: 60)
    check(r.code == 0 && r.out.contains("not running"), "17 stop again: nothing running, exit 0")
    r = h.run(["workspace", "start", "mgr2"], timeout: 120)
    if r.code == 0 { started.insert("mgr2") }
    check(r.code == 0 && h.waitFor(30) { isUp("mgr2", "mira") }, "17 start mgr2 now works, mira is up there (\(r.code) \(r.err.prefix(200)))")
    r = h.run(["workspace", "manager", "stop", "mgr2"], timeout: 60)
    check(r.code == 0 && !running("mgr2"), "17 stop mgr2")

    // 18. start mgr again: nothing posted twice; the session runs again
    let upsBefore = messages("mgr").filter { $0["from"] as? String == "mira" }.count
    r = h.run(["workspace", "start", "mgr"], timeout: 120)
    check(r.code == 0 && !r.out.contains("posted the brief"), "18 start mgr again (\(r.code) \(r.err.prefix(200)))")
    check(h.waitFor(20) { running("mgr") }, "18 …its session runs again")
    check(h.waitFor(30) { messages("mgr").filter { $0["from"] as? String == "mira" }.count > upsBefore }, "18 …mira says she is up again")
    check(mine("mgr").count == 1, "18 your message count stays 1 (\(mine("mgr").count))")
    check(text(ws.folder("mgr") + "/log.jsonl").components(separatedBy: "\"kicked-off\"").count == 2, "18 one kicked-off in the log")

    // 19. unfenced (separable)
    r = h.run(["bot", "new", "otto", "--agent", "claude-code", "--isolation", "unfenced"], timeout: 60)
    check(r.code == 0, "19 bot new otto --isolation unfenced (\(r.code))")
    r = h.run(["workspace", "new", "solo", "--prompt-file", mbrief, "--folder", mwork.path, "--manager", "otto"], timeout: 60)
    check(r.code == 0 && detail("solo")?.agents.first?.isolation == "fenced", "19 new solo --manager otto: fenced (never unfenced by default)")
    r = h.run(["workspace", "edit", "solo", "--manager", "otto", "--manager-isolation", "unfenced"], timeout: 60)
    check(r.code == 0 && r.out.contains("unfenced · acts as you"), "19 edit --manager-isolation unfenced: show says acts as you (\(r.code) \(r.out.prefix(300)))")
    check(h.run(["workspace", "ls"]).out.contains("manager otto (unfenced · acts as you)"), "19 …ls says it")
    check(detail("solo")?.agents.first?.actsAsYou == true, "19 …--json actsAsYou: true")
    check(text(ws.folder("solo") + "/log.jsonl").contains("\"isolation\":\"unfenced\""), "19 …the log says unfenced")
    r = h.run(["workspace", "start", "solo"], timeout: 120)
    if r.code == 0 { started.insert("solo") }
    check(r.code == 0 && r.out.contains("acts as you"), "19 start solo (\(r.code) \(r.err.prefix(240)))")
    let temp = WorkspaceStore.resolved(NSTemporaryDirectory())
    let tokenDirs = ((try? fm.contentsOfDirectory(atPath: temp)) ?? []).filter { $0.hasPrefix("doz-") }
        .map { temp + "/" + $0 + "/manager-solo" }.filter { fm.fileExists(atPath: $0) }
    let tokenFile = tokenDirs.first.map { $0 + "/chat-token" } ?? ""
    check(tokenDirs.count == 1 && mode(tokenFile) == 0o600 && mode(tokenDirs[0]) == 0o700 && text(tokenFile).hasPrefix("dzc_"),
          "19 the token file is 0600 in 0700 (\(tokenDirs.count), \(String(mode(tokenFile), radix: 8)))")
    check(h.waitFor(30) { isUp("solo", "otto") }, "19 otto is up (it read its token file)")
    let unfencedLeaks = holders("dzc_", under: store.root.path) + holders("dzc_", under: home.path)
    check(unfencedLeaks.isEmpty && !psText().contains("dzc_"), "19 …the only dzc_ holder: nothing in the store, the home or ps")
    r = h.run(["workspace", "manager", "stop", "solo"], timeout: 60)
    check(r.code == 0 && !fm.fileExists(atPath: tokenDirs.first ?? "/nonexistent-x"), "19 stop solo: the token file is gone")

    // 20. a VM manager recorded; the check lists its gap; nothing boots
    r = h.run(["bot", "new", "vera", "--agent", "claude-code", "--isolation", "vm"], timeout: 60)
    r = h.run(["workspace", "new", "vmw", "--prompt-file", mbrief, "--folder", mwork.path, "--manager", "vera", "--manager-isolation", "vm"], timeout: 60)
    check(r.code == 0 && detail("vmw")?.agents.first?.isolation == "vm" && detail("vmw")?.agents.first?.place == "vmw", "20 new vmw: isolation vm (\(r.code))")
    h.run(["create", "vmw", "--image", "lab"], timeout: 120)
    r = h.run(["workspace", "start", "vmw"], timeout: 60)
    check(r.code == 3 && r.err.contains("a sandbox called vmw already exists — doz rm vmw, or rename the workspace"),
          "20 start vmw: the check lists the sandbox in the way (\(r.code): \(r.err.prefix(240)))")
    check(h.row("vmw")?.phase == "off" && mine("vmw").isEmpty, "20 …nothing boots, nothing posted")
    h.run(["rm", "vmw", "--yes"], timeout: 120)

    // 21. refusals
    r = h.run(["workspace", "new", "r1", "--prompt-file", mbrief, "--manager", "nosuch"], timeout: 60)
    check(r.code == 2 && !ws.exists("r1"), "21 an unknown bot: exit 2, nothing made (\(r.code))")
    h.run(["bot", "new", "old", "--agent", "codex"], timeout: 60)
    h.run(["bot", "retire", "old", "--yes"], timeout: 60)
    r = h.run(["workspace", "new", "r1", "--prompt-file", mbrief, "--manager", "old"], timeout: 60)
    check(r.code == 4 && r.err.contains("retired"), "21 a retired bot: exit 4 (\(r.code))")
    h.run(["bot", "new", "far", "--agent", "codex", "--isolation", "elsewhere", "--to-file", root.path + "-far.token"], timeout: 60)
    try? fm.removeItem(atPath: root.path + "-far.token")
    r = h.run(["workspace", "new", "r1", "--prompt-file", mbrief, "--manager", "far"], timeout: 60)
    check(r.code == 65 && r.err.contains("Dozable never starts it"), "21 a bot elsewhere: refused (\(r.code) \(r.err.prefix(160)))")
    h.run(["bot", "new", "inby", "--agent", "claude-code", "--deliver", "inbox"], timeout: 60)
    h.run(["workspace", "new", "r2", "--prompt-file", mbrief, "--folder", mwork.path, "--manager", "inby"], timeout: 60)
    r = h.run(["workspace", "start", "r2"], timeout: 60)
    check(r.code == 3 && r.err.contains("doz bot set inby --deliver poll"), "21 a fenced inbox bot: refused, the fix named (\(r.code) \(r.err.prefix(240)))")
    h.run(["bot", "new", "hook", "--agent", "claude-code", "--deliver", "webhook"], timeout: 60)
    h.run(["workspace", "new", "r3", "--prompt-file", mbrief, "--folder", mwork.path, "--manager", "hook"], timeout: 60)
    r = h.run(["workspace", "start", "r3"], timeout: 60)
    check(r.code == 3 && r.err.contains("reached by webhook"), "21 a webhook bot: refused (\(r.code) \(r.err.prefix(240)))")
    check(mine("r2").isEmpty && mine("r3").isEmpty, "21 …nothing posted")
    r = h.run(["workspace", "release", "mgr", "mira"], timeout: 60)
    check(r.code == 3 && r.err.contains("doz workspace stop mgr"), "21 releasing a running manager: refused (\(r.code) \(r.err.prefix(160)))")

    // 22. looking with the daemon stopped
    h.run(["daemon", "stop"], timeout: 60)
    _ = h.waitFor(20) { !h.hostRunning }
    r = h.run(["workspace", "ls"])
    check(r.code == 0 && r.out.contains("manager mira (fenced)"), "22 ls with no daemon: the manager (\(r.out.prefix(400)))")
    let shown = detail("mgr")
    check(shown?.agents.first?.bot == "mira" && ["idle", "working"].contains(shown?.state ?? ""), "22 show with no daemon: the manager and its state (\(shown?.state ?? "?"))")
    check(!h.hostRunning, "22 …and no daemon started")
}
