import Darwin
import Foundation
import DozableKit
import DozableHost

// `make test-cli-workspace`, the worker rows (after rows 1–22, in the same scratch store): workers brought up in a started
// workspace through the real doz, its daemon, the chat server it runs and the real deckhold-mac — no VM, no UI, the memory
// keychain, ports from freePort(), `mac.account none`, a scratch fence home, and the FAKE `claude` (first on the sessions'
// PATH) that reads START and says "NAME is up: <its first line>" with dozchat, then sleeps (never the real claude).
//
//  23. wk setting up: worker add refused ("doz workspace start wk first"); no participant, no entry, no session
//  24. start wk (no manager: you drive); worker add wk --task "list the files" → bot1, fenced, in chat who; the room has its
//      invite, then "bot1 is up: … list the files"; sessions @mac --json: fenced, in workspace wk
//  25. the leak sweep: no dzc_ in ps, any file of the store (sessions.json, workspace.json, log.jsonl, daemon.log, server.log,
//      …) or the fence home, or any --json; etc/secrets/CHAT_TOKEN holds a doz_cred_ placeholder; one ledger line
//  26. worker ls wk (and --json): its place, fenced, "proxy · placeholders · guard", locked, its task
//  27. worker add wk carl --isolation unfenced: "acts as you"; its token file 0600 in 0700; with defaults.isolation unfenced
//      and no flag a worker is still fenced
//  28. carl's token works (dozchat rooms), then worker end wk carl: the file and the participant gone; dozchat rooms with
//      the same token → 401
//  29. bot new oscar; worker add wk --from-bot oscar → bot ls "works in: wk"; workspace start w2 (oscar its manager) and
//      worker add w3 --from-bot oscar refused with the sentence; nothing posted
//  30. worker end wk oscar: its token still held; start w2 now works; stop w2
//  31. worker end wk bot1: ended, its entry kept, gone from chat who, its ledger line gone; a new add gives bot1 again
//  32. refusals: chat off, an unknown workspace, NAME a bot or a participant, --cpus fenced, --sandbox with --isolation,
//      --sandbox the manager's, --sandbox an adopted lab sandbox never booted
//  33. the daemon stopped: worker ls answers, and no daemon starts
func cliWorkspaceWorkerRows(_ h: CLIHarness, root: URL, store: DozableStore, started: inout Set<String>) {
    print("cli: a workspace's workers — fenced and unfenced on this Mac, a FAKE claude")
    let fm = FileManager.default
    let ws = WorkspaceStore(store: store)
    let brief = root.appendingPathComponent("worker-brief.md").path
    try? "Tidy the demo.\n".write(toFile: brief, atomically: true, encoding: .utf8)
    let home = URL(fileURLWithPath: "/private/tmp/dzo-\(getpid())-wsw-home")
    try? fm.removeItem(at: home)
    try? fm.createDirectory(at: home, withIntermediateDirectories: true)
    let wwork = URL(fileURLWithPath: "/private/tmp/dzo-\(getpid())-wsw-work")
    try? fm.createDirectory(at: wwork, withIntermediateDirectories: true)
    let scratch = URL(fileURLWithPath: "/private/tmp/dzo-\(getpid())-wsw-scratch")
    try? fm.createDirectory(at: scratch, withIntermediateDirectories: true)
    chmod(scratch.path, 0o700)
    defer { try? fm.removeItem(at: home); try? fm.removeItem(at: wwork); try? fm.removeItem(at: scratch) }
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
    \(fakeClaudeReadCheck)
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
    func mode(_ p: String) -> mode_t { var st = stat(); return lstat(p, &st) == 0 ? st.st_mode & 0o777 : 0 }
    func messages(_ room: String) -> [[String: Any]] {
        let r = h.run(["chat", "read", room, "--last", "100", "--json"])
        return ((try? JSONSerialization.jsonObject(with: r.outData)) as? [[String: Any]]) ?? []
    }
    func mine(_ room: String) -> [[String: Any]] { messages(room).filter { $0["from"] as? String == "ada" && ($0["kind"] as? String) != "change" } }
    func isUp(_ room: String, _ who: String) -> Bool {
        messages(room).contains { $0["from"] as? String == who && ($0["content"] as? String)?.hasPrefix("\(who) is up: You are \(who)") == true }
    }
    func inChat(_ who: String) -> Bool { h.run(["chat", "who"]).out.split(separator: "\n").contains { $0.hasPrefix(who + " ") } }
    func macRow(_ s: String) -> SessionRow? { h.sessions("@mac").first { $0.name == s } }
    func listing(_ w: String, all: Bool = false) -> WorkerListing? { h.json(["worker", "ls", w] + (all ? ["--all"] : []), WorkerListing.self) }
    func record(_ w: String) -> WorkspaceRecord? { try? ws.read(w) }
    func ledger() -> [String: String] { LaunchSecretLedger.load(store).items }
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
    /// `dozchat rooms` as the holder of the token in `file` (never on its command line): its exit code.
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

    // The daemon again with the fence's seams (its home and PATH are this file's), chat on.
    h.run(["daemon", "stop"], timeout: 60)
    _ = h.waitFor(20) { !h.hostRunning }
    h.env["DOZ_TEST_FENCE_HOME"] = home.path
    h.env["DOZ_TEST_MAC_PATH"] = bin.path + ":/usr/bin:/bin:/usr/sbin:/sbin"
    var r = h.run(["chat", "on", "--name", "ada"], timeout: 60)
    check(r.code == 0, "23 chat on again (\(r.code) \(r.err.prefix(120)))")
    let port = h.run(["config", "get", "chat.page_port"]).out.trimmingCharacters(in: .whitespacesAndNewlines)

    // 23. setting up: refused, nothing made
    r = h.run(["workspace", "new", "wk", "--prompt-file", brief, "--folder", wwork.path], timeout: 60)
    check(r.code == 0 && r.out.hasPrefix("wk — setting up · you"), "23 new wk: setting up (\(r.code) \(r.err.prefix(160)))")
    r = h.run(["worker", "add", "wk", "--task", "list the files"], timeout: 60)
    check(r.code == 3 && r.err.contains("wk is still setting up — doz workspace start wk first"),
          "23 worker add while setting up: refused, says to start it first (\(r.code): \(r.err.prefix(200)))")
    check(!inChat("bot1") && record("wk")?.agents.isEmpty == true && macRow("wk-bot1") == nil, "23 …no participant, no entry, no session")

    // 24. a worker, fenced, in the room
    r = h.run(["workspace", "start", "wk"], timeout: 120)
    check(r.code == 0 && r.out.contains("no manager: you drive"), "24 start wk (no manager) (\(r.code) \(r.err.prefix(160)))")
    r = h.run(["worker", "add", "wk", "--task", "list the files"], timeout: 120)
    if r.code == 0 { started.insert("wk-bot1") }
    check(r.code == 0 && r.out.contains("added bot1 to wk (fenced) on this Mac as @mac/wk-bot1"),
          "24 worker add wk --task …: bot1, fenced (\(r.code): \(r.out.prefix(240)) \(r.err.prefix(300)))")
    check(inChat("bot1"), "24 bot1 is in chat who")
    check(h.waitFor(30) { isUp("wk", "bot1") }, "24 bot1 says it is up in the room")
    let ms = messages("wk")
    let invited = ms.firstIndex { ($0["content"] as? String)?.lowercased().contains("invited bot1") == true }
    let up = ms.firstIndex { $0["from"] as? String == "bot1" && ($0["content"] as? String)?.contains("Your task: list the files") == true }
    check(invited != nil && up != nil && invited! < up!, "24 …the invite, then \"bot1 is up: … list the files\" (\(invited ?? -1), \(up ?? -1))")
    let row = macRow("wk-bot1")
    check(row?.fence != nil && row?.workspace == "wk" && row?.ended == false, "24 sessions @mac --json: fenced, in workspace wk")

    // 25. the leak sweep
    var jsons = ""
    for a in [["worker", "ls", "wk"], ["workspace", "show", "wk"], ["workspace", "log", "wk"], ["sessions", "@mac"], ["bot", "ls"], ["net", "show", "@mac", "wk-bot1"]] {
        jsons += h.run(a + ["--json"]).out
    }
    check(!jsons.contains("dzc_"), "25 no dzc_ in any --json")
    check(!psText().contains("dzc_"), "25 no dzc_ in ps")
    let leaks = holders("dzc_", under: store.root.path) + holders("dzc_", under: home.path)
    check(leaks.isEmpty, "25 no dzc_ in any file of the store (sessions.json, workspace.json, log.jsonl, daemon.log, server.log, …) or the fence home (\(leaks.prefix(3)))")
    let placeholders = (holders("doz_cred_", under: store.root.path) + holders("doz_cred_", under: home.path))
        .filter { $0.contains("wk-bot1") && $0.hasSuffix("/etc/secrets/CHAT_TOKEN") }
    check(placeholders.count == 1 && text(placeholders.first ?? "").hasPrefix("doz_cred_"), "25 etc/secrets/CHAT_TOKEN holds a placeholder (\(placeholders.count))")
    check(ledger().values.filter { $0 == "mac.wk-bot1" }.count == 1, "25 one ledger line for its token")

    // 26. worker ls
    r = h.run(["worker", "ls", "wk"])
    check(r.code == 0 && r.out.contains("bot1") && r.out.contains("@mac/wk-bot1") && r.out.contains("proxy · placeholders · guard")
          && r.out.contains("locked") && r.out.contains("list the files"), "26 worker ls wk: place, fenced, control, locked, task (\(r.out.prefix(400)))")
    let b1 = listing("wk")?.agents.first { $0.name == "bot1" }
    check(b1?.isolation == "fenced" && b1?.control == "proxy · placeholders · guard" && b1?.network == "locked" && b1?.task == "list the files"
          && b1?.role == "worker", "26 …and --json (\(String(describing: b1)))")

    // 27. unfenced only when named
    r = h.run(["worker", "add", "wk", "carl", "--isolation", "unfenced", "--task", "say hello"], timeout: 120)
    if r.code == 0 { started.insert("wk-carl") }
    check(r.code == 0 && r.out.contains("acts as you"), "27 worker add wk carl --isolation unfenced: acts as you (\(r.code) \(r.err.prefix(240)))")
    let temp = WorkspaceStore.resolved(NSTemporaryDirectory())
    let carlDirs = ((try? fm.contentsOfDirectory(atPath: temp)) ?? []).filter { $0.hasPrefix("doz-") }
        .map { temp + "/" + $0 + "/manager-wk-carl" }.filter { fm.fileExists(atPath: $0) }
    let carlFile = carlDirs.first.map { $0 + "/chat-token" } ?? "/nonexistent-x"
    check(carlDirs.count == 1 && mode(carlFile) == 0o600 && mode(carlDirs[0]) == 0o700 && text(carlFile).hasPrefix("dzc_"),
          "27 its token file is 0600 in 0700 (\(carlDirs.count), \(String(mode(carlFile), radix: 8)))")
    check(h.waitFor(30) { isUp("wk", "carl") }, "27 carl is up (it read its token file)")
    check(listing("wk")?.agents.first { $0.name == "carl" }?.control == "no proxy · no placeholders · no guard · acts as you", "27 worker ls: acts as you")
    // defaults.isolation unfenced, no flag: still fenced.
    let recPath = ws.folder("wk") + "/workspace.json"
    var obj = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: recPath)))) as? [String: Any] ?? [:]
    obj["defaults"] = ["isolation": "unfenced"]
    try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]).write(to: URL(fileURLWithPath: recPath), options: .atomic)
    r = h.run(["worker", "add", "wk", "dora", "--task", "wait"], timeout: 120)
    if r.code == 0 { started.insert("wk-dora") }
    check(r.code == 0 && r.out.contains("(fenced)"), "27 defaults.isolation unfenced, no flag: still fenced (\(r.code) \(r.out.prefix(160)) \(r.err.prefix(160)))")
    h.run(["worker", "end", "wk", "dora", "--rm"], timeout: 60)
    obj = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: recPath)))) as? [String: Any] ?? [:]
    obj["defaults"] = [String: Any]()
    try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]).write(to: URL(fileURLWithPath: recPath), options: .atomic)

    // 28. carl's token works, then is refused after end
    let copy = scratch.appendingPathComponent("carl-token").path
    try? fm.removeItem(atPath: copy)
    if let d = fm.contents(atPath: carlFile) { fm.createFile(atPath: copy, contents: d, attributes: [.posixPermissions: 0o600]) }
    check(dozchatRooms(tokenFile: copy, port: port) == 0, "28 dozchat rooms with carl's token: answered")
    r = h.run(["worker", "end", "wk", "carl"], timeout: 60)
    check(r.code == 0 && !fm.fileExists(atPath: carlDirs.first ?? "/nonexistent-x"), "28 worker end wk carl: its token file is gone (\(r.code) \(r.err.prefix(160)))")
    // 776: carl was added with a name — a lasting identity: it stays a participant (with its memory), its token refused.
    check(inChat("carl"), "28 …and its participant stays (a lasting identity)")
    check(dozchatRooms(tokenFile: copy, port: port) == 4, "28 dozchat rooms with the same token: 401 (exit 4)")
    try? fm.removeItem(atPath: copy)

    // 29. a bot as a worker; one live workspace
    r = h.run(["bot", "new", "oscar", "--agent", "claude-code", "--deliver", "poll"], timeout: 60)
    check(r.code == 0, "29 bot new oscar (\(r.code) \(r.err.prefix(160)))")
    r = h.run(["worker", "add", "wk", "--from-bot", "oscar", "--task", "review the demo"], timeout: 120)
    if r.code == 0 { started.insert("wk-oscar") }
    check(r.code == 0 && r.out.contains("added oscar to wk"), "29 worker add wk --from-bot oscar (\(r.code) \(r.err.prefix(240)))")
    check(h.run(["bot", "ls"]).out.contains("works in: wk"), "29 bot ls: works in: wk")
    check(h.waitFor(30) { isUp("wk", "oscar") }, "29 oscar is up in wk")
    let sentence = "oscar already works in wk, which is running. For now a bot runs in one live workspace at a time — doz worker end wk oscar first."
    h.run(["workspace", "new", "w2", "--prompt-file", brief, "--folder", wwork.path, "--manager", "oscar"], timeout: 60)
    r = h.run(["workspace", "start", "w2"], timeout: 60)
    check(r.code == 4 && r.err.contains(sentence), "29 start w2 (oscar its manager): refused with the sentence (\(r.code): \(r.err.prefix(240)))")
    check(mine("w2").isEmpty && macRow("w2") == nil, "29 …nothing posted, no session")
    h.run(["workspace", "new", "w3", "--prompt-file", brief, "--folder", wwork.path], timeout: 60)
    h.run(["workspace", "start", "w3"], timeout: 60)
    let w3Before = messages("w3").count
    r = h.run(["worker", "add", "w3", "--from-bot", "oscar", "--task", "x"], timeout: 60)
    check(r.code == 4 && r.err.contains(sentence), "29 worker add w3 --from-bot oscar: refused with the sentence (\(r.code): \(r.err.prefix(240)))")
    check(messages("w3").count == w3Before && macRow("w3-oscar") == nil, "29 …nothing posted, no session")

    // 30. oscar ended: its token held; then w2 starts
    r = h.run(["worker", "end", "wk", "oscar"], timeout: 60)
    check(r.code == 0 && r.out.contains("oscar's token is kept"), "30 worker end wk oscar (\(r.code) \(r.err.prefix(160)))")
    check(h.json(["bot", "show", "oscar"], BotDetail.self)?.token.keeper == "dozable" && inChat("oscar"), "30 …its token still held, still in chat")
    r = h.run(["workspace", "start", "w2"], timeout: 120)
    if r.code == 0 { started.insert("w2") }
    check(r.code == 0 && h.waitFor(30) { isUp("w2", "oscar") }, "30 start w2 now works, oscar is up there (\(r.code) \(r.err.prefix(200)))")
    r = h.run(["workspace", "manager", "stop", "w2"], timeout: 60)
    check(r.code == 0, "30 stop w2")

    // 31. bot1 ended: kept, gone from chat, its ledger line gone; the name free again
    r = h.run(["worker", "end", "wk", "bot1"], timeout: 60)
    check(r.code == 0, "31 worker end wk bot1 (\(r.code) \(r.err.prefix(160)))")
    check(listing("wk", all: true)?.agents.first { $0.name == "bot1" }?.state == "ended" && record("wk")?.agents.contains { $0.name == "bot1" } == true,
          "31 …ended, its entry kept")
    check(!inChat("bot1"), "31 …gone from chat who")
    check(!ledger().values.contains("mac.wk-bot1"), "31 …its ledger line gone (its item deleted)")
    check(listing("wk")?.agents.contains { $0.name == "bot1" } == false, "31 …and left out of worker ls without --all")
    // 31a. (the peer's EDGE 6) after the worker's end: a loose ended session is forgotten; the workspace's own is kept, with why.
    let loose = scratch.appendingPathComponent("loose-6")
    try? fm.createDirectory(at: loose, withIntermediateDirectories: true)
    r = h.run(["run", "@mac", "-d", "--unfenced", "--session", "loose6", "--folder", loose.path, "--", "/bin/sh", "-c", "echo loose"], timeout: 60)
    _ = h.waitFor(10) { macRow("loose6")?.ended == true }
    r = h.run(["sessions", "@mac", "--forget-ended", "--dry-run", "--json"], timeout: 60)
    let plan6 = try? HostWire.decoder.decode(SessionsForgotten.self, from: r.outData)
    check(plan6?.forgotten.contains("loose6") == true && plan6?.kept.contains { $0.name == "wk-bot1" && $0.why.contains("in workspace wk") } == true,
          "31a --forget-ended --dry-run: loose6 would go, wk-bot1 is kept (in workspace wk) (\(plan6?.kept.map(\.name) ?? []))")
    r = h.run(["sessions", "@mac", "--forget", "wk-bot1", "--yes"], timeout: 60)
    check(r.code == 0 && r.out.contains("in workspace wk") && macRow("wk-bot1") != nil, "31a --forget wk-bot1: kept with its reason")
    r = h.run(["sessions", "@mac", "--forget", "loose6", "--yes"], timeout: 60)
    check(r.code == 0 && macRow("loose6") == nil, "31a --forget loose6: forgotten (\(r.out.prefix(120)))")
    r = h.run(["worker", "add", "wk", "--task", "list the files again"], timeout: 120)
    check(r.code == 0 && r.out.contains("added bot1 to wk"), "31 a new add gives bot1 again (\(r.code) \(r.out.prefix(160)) \(r.err.prefix(200)))")
    h.run(["worker", "end", "wk", "bot1", "--rm"], timeout: 60)

    // 32. refusals
    h.run(["chat", "off"], timeout: 30)
    r = h.run(["worker", "add", "wk", "--task", "x"], timeout: 60)
    check(r.code == 6 && r.err.contains("a worker needs chat — doz chat on"), "32 chat off: refused (\(r.code): \(r.err.prefix(160)))")
    h.run(["chat", "on", "--name", "ada"], timeout: 60)
    r = h.run(["worker", "add", "nosuch", "--task", "x"], timeout: 60)
    check(r.code == 2, "32 an unknown workspace: exit 2 (\(r.code))")
    r = h.run(["worker", "add", "wk", "mira", "--task", "x"], timeout: 60)
    check(r.code == 4 && r.err.contains("--from-bot mira"), "32 NAME a bot: refused (\(r.code): \(r.err.prefix(160)))")
    r = h.run(["chat", "add", "pat", "--to-file", scratch.appendingPathComponent("pat.token").path], timeout: 60)
    try? fm.removeItem(atPath: scratch.appendingPathComponent("pat.token").path)
    r = h.run(["worker", "add", "wk", "pat", "--task", "x"], timeout: 60)
    check(r.code == 4 && r.err.contains("already in chat"), "32 NAME a participant: refused (\(r.code): \(r.err.prefix(160)))")
    r = h.run(["worker", "add", "wk", "--cpus", "2", "--task", "x"], timeout: 60)
    check(r.code == 65 && r.err.contains("--isolation sandbox"), "32 --cpus fenced: refused (\(r.code): \(r.err.prefix(160)))")
    r = h.run(["worker", "add", "wk", "--sandbox", "x", "--isolation", "vm", "--task", "x"], timeout: 60)
    check(r.code == 65 && r.err.contains("--sandbox or --isolation"), "32 --sandbox with --isolation: refused (\(r.code))")
    // The manager's sandbox: vmm (a VM manager, recorded, never booted) marked started by adopting a running session.
    h.run(["workspace", "new", "vmm", "--prompt-file", brief, "--folder", wwork.path, "--manager", "vera", "--manager-isolation", "vm"], timeout: 60)
    r = h.run(["run", "@mac", "-d", "--unfenced", "--session", "wsx", "--folder", wwork.path, "--", "/bin/sleep", "600"], timeout: 60)
    if r.code == 0 { started.insert("wsx") }
    h.run(["workspace", "adopt", "vmm", "@mac/wsx"], timeout: 60)
    r = h.run(["worker", "add", "vmm", "--sandbox", "vmm", "--task", "x"], timeout: 60)
    check(r.code == 65 && r.err.contains("vmm is the manager's sandbox"), "32 --sandbox the manager's: refused (\(r.code): \(r.err.prefix(160)))")
    h.run(["create", "wkl", "--image", "lab"], timeout: 120)
    h.run(["workspace", "adopt", "wk", "wkl"], timeout: 60)
    r = h.run(["worker", "add", "wk", "--sandbox", "wkl", "--task", "x"], timeout: 60)
    check(r.code == 3 && r.err.contains("wkl is stopped — doz start wkl"), "32 --sandbox an adopted lab sandbox never booted: refused (\(r.code): \(r.err.prefix(160)))")
    check(h.row("wkl")?.phase == "off", "32 …and it was not booted")
    h.run(["workspace", "release", "wk", "wkl"], timeout: 60)
    h.run(["rm", "wkl", "--yes"], timeout: 120)

    // 33. looking with the daemon stopped
    h.run(["daemon", "stop"], timeout: 60)
    _ = h.waitFor(20) { !h.hostRunning }
    r = h.run(["worker", "ls", "wk", "--all"])
    check(r.code == 0 && r.out.contains("oscar") && r.out.contains("ended"), "33 worker ls with no daemon: answered (\(r.code) \(r.out.prefix(300)))")
    check(!h.hostRunning, "33 …and no daemon started")
}
