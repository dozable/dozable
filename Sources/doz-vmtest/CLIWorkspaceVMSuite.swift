import Darwin
import Foundation
import DozableKit
import DozableHost

// `make test-cli-workspace-vm` (`doz-vmtest cli-workspace-vm --doz PATH`): a workspace's manager in a micro VM, through the
// real signed doz and its daemon — ONE scratch lab VM in a scratch store (/private/tmp/dzo-PID-wsvm), settings beside it, the
// memory keychain, chat ports from freePort(). The guarded seams `DOZ_TEST_MANAGER_IMAGE=lab` (the lab image, not an
// agent's) and `DOZ_TEST_MANAGER_ARGV` (a FAKE manager: a shell script in the shared folder that reads START and says it is
// up with dozchat) stand in for Claude Code; nothing real is run. The rows:
//
//   1. start vmw (--manager-isolation vm): the invite, your brief, then vera's "is up" — in that order
//   2. the guest holds only the placeholder (its variable and its file); no dzc_ in the store, its --json or ps
//   3. stop: the sandbox is off and kept (its disk); the record kept, asleep
//   4. start again: the same sandbox started, vera up again, and your message count stays 1
//
// Then a workspace's workers, with the guarded seams `DOZ_TEST_WORKER_IMAGE=lab` and `DOZ_TEST_WORKER_ARGV` (a FAKE worker
// script, its first prompt appended):
//
//   5. worker add vw v1 --isolation vm --cpus 2 --memory 2G: its own sandbox vw-v1; the invite, then "v1 is up"; the guest
//      holds only the placeholder (its variable and its file)
//   6. worker add vw v2 --sandbox vw-v1: its own variables (CHAT_TOKEN_V2, CHAT_TOKEN_FILE_V2), aliased for its session —
//      CHAT_TOKEN_FILE is its own file — and "v2 is up" as v2; worker ls says "shares vw-v1"
//   7. worker end vw v2: v1 still talks (it posts what it is asked to)
//   8. worker end vw v1: its sandbox stopped, its disk kept; worker end vw v1 --rm deletes it
//
// Then the lifecycle (the same seams; v3 a VM worker of its own, v4 sharing its sandbox):
//
//   9. sleep vw: v3's sandbox hibernated ONCE for both (the plan: one change), its memory given back; wake: running, the
//      same session pids (the same programs and screens)
//  10. finish vw: the sandbox shut down, its disk kept; reopen + wake: a cold boot, both say they are up again (v4, whose
//      token went with the shutdown, with a new one)
//  11. archive vw --remove-sandboxes (its disk saved as an image first): vw-v3 gone, the image there, the workers retired;
//      restore names the image
//  12. delete vmw --remove-sandboxes: only the sandbox Dozable made for it (vmw) removed — an adopted one (vadopt) stays,
//      loose
//  13. (762, F5) a space file's run-lifetime sandbox at down: its disk saved as an image first (vsx-box-tpl, named in the
//      answer's savedDisks and in image ls), then the sandbox removed — never without a copy
func cliWorkspaceVMSuite(binary: String) async {
    print("cli: a workspace's manager in a micro VM (one lab sandbox, a FAKE manager)")
    let fm = FileManager.default
    let root = URL(fileURLWithPath: "/private/tmp/dzo-\(getpid())-wsvm")
    let work = URL(fileURLWithPath: root.path + "-work"), xdg = URL(fileURLWithPath: root.path + "-xdg")
    for u in [root, work, xdg] { try? fm.removeItem(at: u) }
    for u in [root, work] { try? fm.createDirectory(at: u, withIntermediateDirectories: true) }
    let h = CLIHarness(binary: binary, store: root)
    h.env["XDG_CONFIG_HOME"] = xdg.path
    h.env["DOZ_TEST_CREDENTIALS"] = "memory"
    h.env["DOZ_TEST_MANAGER_IMAGE"] = "lab"
    h.env["DOZ_TEST_MANAGER_ARGV"] = #"["/bin/sh", "/workspace/fake-manager.sh"]"#
    h.env["DOZ_TEST_WORKER_IMAGE"] = "lab"
    h.env["DOZ_TEST_WORKER_ARGV"] = #"["/bin/sh", "/workspace/fake-worker.sh"]"#
    let store = DozableStore(root: root)
    defer {
        h.run(["rm", "vmw", "--yes"], timeout: 180)
        h.run(["rm", "vw-v1", "--yes"], timeout: 180)
        h.run(["rm", "vw-v3", "--yes"], timeout: 180)
        h.run(["rm", "vadopt", "--yes"], timeout: 180)
        h.run(["image", "rm", "vw-v3-tpl", "--yes"], timeout: 120)
        h.run(["rm", "vsx-box", "--yes"], timeout: 180)
        h.run(["image", "rm", "vsx-box-tpl", "--yes"], timeout: 120)
        h.run(["chat", "off"], timeout: 30)
        h.run(["daemon", "stop"], timeout: 120)
        _ = h.waitFor(30) { !h.hostRunning }
        check(!h.hostRunning, "workspace-vm: no daemon of this suite left running")
        try? fm.removeItem(atPath: MacPlace.socketDirectory(store: store))
        for u in [root, work, xdg] { try? fm.removeItem(at: u) }
    }
    func freePort() -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var a = sockaddr_in()
        a.sin_family = sa_family_t(AF_INET); a.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        return Int(UInt16(bigEndian: a.sin_port))
    }
    func text(_ p: String) -> String { ((try? String(contentsOfFile: p, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
    func messages(_ room: String) -> [[String: Any]] {
        let r = h.run(["chat", "read", room, "--last", "100", "--json"])
        return ((try? JSONSerialization.jsonObject(with: r.outData)) as? [[String: Any]]) ?? []
    }
    func mine(_ room: String) -> [[String: Any]] { messages(room).filter { $0["from"] as? String == "ada" && ($0["kind"] as? String) != "change" } }
    func ups(_ room: String) -> Int { messages(room).filter { $0["from"] as? String == "vera" && ($0["content"] as? String)?.hasPrefix("vera is up") == true }.count }
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

    // The FAKE manager, run in the guest as the session's program.
    let fake = """
    start="$HOME/.doz-workspace/start.md"
    first=$(head -n 1 "$start")
    room=$(sed -n 's/^Your room in chat: //p' "$start")
    printf '%s' "$CHAT_TOKEN" > /workspace/res-var; cat "$CHAT_TOKEN_FILE" > /workspace/res-file
    dozchat send "$room" "vera is up: $first" > /workspace/res-send 2>&1; echo $? > /workspace/res-send.rc
    exec sleep 3600

    """
    try? fake.write(to: work.appendingPathComponent("fake-manager.sh"), atomically: true, encoding: .utf8)
    // The FAKE worker: its START from its first prompt; what it holds written to the shared folder (placeholders only);
    // then it says it is up, and posts each say-NAME-* file it is given.
    let fakeWorker = """
    start="$1"; start="${start#Read }"; start="${start% and do what it says.}"
    case "$start" in "~/"*) start="$HOME/${start#??}" ;; esac
    first=$(head -n 1 "$start")
    room=$(sed -n 's/^Your room in chat: //p' "$start")
    me=$(printf '%s' "$first" | sed -n 's/^You are \\([^,]*\\),.*/\\1/p')
    printf '%s' "$CHAT_TOKEN" > "/workspace/res-$me-var"; cat "$CHAT_TOKEN_FILE" > "/workspace/res-$me-file"
    printf '%s' "$CHAT_TOKEN_FILE" > "/workspace/res-$me-path"
    env | grep '^CHAT_TOKEN' | sort > "/workspace/res-$me-env"
    dozchat send "$room" "$me is up: $first" > "/workspace/res-$me-send" 2>&1
    # A conversation in Claude Code's folder for /workspace (what a run's archive copies out), with what plant.txt holds,
    # and a link beside it (refused by the copy).
    d="$HOME/.claude/projects/-workspace"; mkdir -p "$d"
    id=$(cat /proc/sys/kernel/random/uuid)
    printf '{"type":"user","cwd":"/workspace","message":{"content":"%s works: %s"}}\\n' "$me" "$(cat /workspace/plant.txt 2>/dev/null)" > "$d/$id.jsonl"
    [ -e "$d/00000000-0000-4000-8000-00000000000$(printf '%s' "$me" | tail -c 1).jsonl" ] || ln -s /etc/hostname "$d/00000000-0000-4000-8000-00000000000$(printf '%s' "$me" | tail -c 1).jsonl"
    while :; do
      for f in /workspace/say-$me-*; do
        [ -f "$f" ] || continue
        dozchat send "$room" "$(cat "$f")" > /dev/null 2>&1; rm -f "$f"
      done
      sleep 2
    done

    """
    try? fakeWorker.write(to: work.appendingPathComponent("fake-worker.sh"), atomically: true, encoding: .utf8)
    // A live chat token for the guest's conversation (V1): a participant's, known to the store by its hash only.
    let vplantFile = root.path + "-vplant.token"
    defer { try? fm.removeItem(atPath: vplantFile) }
    let brief = root.path + "-brief.md"
    try? "Make the VM demo.\n".write(toFile: brief, atomically: true, encoding: .utf8)
    defer { try? fm.removeItem(atPath: brief) }

    h.run(["config", "set", "chat.page_port", String(freePort())])
    h.run(["config", "set", "chat.line_port", String(freePort())])
    var r = h.run(["chat", "on", "--name", "ada"], timeout: 60)
    check(r.code == 0, "chat on (\(r.code))")
    h.run(["chat", "add", "vplant", "--to-file", vplantFile], timeout: 60)
    let vplant = ((try? String(contentsOfFile: vplantFile, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

    r = h.run(["bot", "new", "vera", "--agent", "claude-code", "--isolation", "vm"], timeout: 60)
    check(r.code == 0, "bot new vera --isolation vm (\(r.code) \(r.err.prefix(160)))")
    r = h.run(["workspace", "new", "vmw", "--prompt-file", brief, "--folder", work.path, "--manager", "vera", "--manager-isolation", "vm"], timeout: 60)
    check(r.code == 0, "workspace new vmw --manager vera --manager-isolation vm (\(r.code) \(r.err.prefix(160)))")

    // 1. start
    r = h.run(["workspace", "start", "vmw"], timeout: 900)
    check(r.code == 0 && r.out.contains("in the sandbox vmw"), "1 start vmw: vera in the sandbox vmw (\(r.code): \(r.out.prefix(200)) \(r.err.suffix(400)))")
    check(h.waitFor(120) { ups("vmw") >= 1 }, "1 vera says she is up (send: \(text(work.path + "/res-send")))")
    let ms = messages("vmw")
    let inv = ms.firstIndex { ($0["content"] as? String)?.lowercased().contains("invited vera") == true }
    let b = ms.firstIndex { $0["from"] as? String == "ada" && ($0["content"] as? String)?.contains("Make the VM demo.") == true }
    let up = ms.firstIndex { $0["from"] as? String == "vera" }
    check(inv != nil && b != nil && up != nil && inv! < b! && b! < up!, "1 …the invite, then your brief, then vera (\(inv ?? -1), \(b ?? -1), \(up ?? -1))")

    // 2. only the placeholder in the guest
    let v = text(work.path + "/res-var"), f = text(work.path + "/res-file")
    check(v.hasPrefix("doz_cred_") && v == f, "2 the guest holds only the placeholder (its variable and its file)")
    var jsons = ""
    for a in [["workspace", "show", "vmw"], ["ls"], ["bot", "show", "vera"], ["net", "show", "vmw"]] { jsons += h.run(a + ["--json"]).out }
    let leaks = holders("dzc_", under: root.path) + holders("dzc_", under: work.path)
    check(!jsons.contains("dzc_") && leaks.isEmpty, "2 no dzc_ in the store, the folder or any --json (\(leaks.prefix(3)))")

    // 3. stop keeps the disk
    r = h.run(["workspace", "manager", "stop", "vmw"], timeout: 300)
    check(r.code == 0 && h.row("vmw")?.phase == "off", "3 stop vmw: the sandbox is off, and kept (\(r.code) \(h.row("vmw")?.phase ?? "gone"))")
    check(h.json(["workspace", "show", "vmw"], WorkspaceDetail.self)?.state == "asleep", "3 …asleep")

    // 4. a restart posts nothing
    try? fm.removeItem(atPath: work.path + "/res-send")
    r = h.run(["workspace", "start", "vmw"], timeout: 900)
    check(r.code == 0 && !r.out.contains("posted the brief"), "4 start vmw again (\(r.code) \(r.err.suffix(300)))")
    check(h.waitFor(120) { ups("vmw") >= 2 }, "4 vera is up again")
    check(mine("vmw").count == 1, "4 your message count stays 1 (\(mine("vmw").count))")
    h.run(["workspace", "manager", "stop", "vmw"], timeout: 300)

    // 5. a VM worker of its own
    func says(_ room: String, _ who: String, _ prefix: String) -> Bool {
        messages(room).contains { $0["from"] as? String == who && ($0["content"] as? String)?.hasPrefix(prefix) == true }
    }
    func envOf(_ me: String) -> [String: String] {
        var out: [String: String] = [:]
        for l in text(work.path + "/res-\(me)-env").split(separator: "\n") {
            guard let eq = l.firstIndex(of: "=") else { continue }
            out[String(l[..<eq])] = String(l[l.index(after: eq)...])
        }
        return out
    }
    r = h.run(["workspace", "new", "vw", "--prompt-file", brief, "--folder", work.path], timeout: 60)
    r = h.run(["workspace", "start", "vw"], timeout: 120)
    check(r.code == 0, "5 new and start vw (no manager) (\(r.code) \(r.err.prefix(160)))")
    r = h.run(["worker", "add", "vw", "v1", "--isolation", "vm", "--cpus", "2", "--memory", "2G", "--task", "say hi"], timeout: 900)
    check(r.code == 0 && r.out.contains("in the sandbox vw-v1"), "5 worker add vw v1 --isolation vm: its own sandbox (\(r.code): \(r.out.prefix(200)) \(r.err.suffix(400)))")
    check(h.waitFor(120) { says("vw", "v1", "v1 is up: You are v1") }, "5 v1 says it is up (send: \(text(work.path + "/res-v1-send")))")
    let ms5 = messages("vw")
    let inv5 = ms5.firstIndex { ($0["content"] as? String)?.lowercased().contains("invited v1") == true }
    let up5 = ms5.firstIndex { $0["from"] as? String == "v1" }
    check(inv5 != nil && up5 != nil && inv5! < up5!, "5 …the invite, then v1 (\(inv5 ?? -1), \(up5 ?? -1))")
    let v1var = text(work.path + "/res-v1-var"), v1file = text(work.path + "/res-v1-file")
    check(v1var.hasPrefix("doz_cred_") && v1var == v1file, "5 the guest holds only the placeholder (its variable and its file)")
    check(h.row("vw-v1")?.cpus == 2, "5 …2 CPUs (\(h.row("vw-v1")?.cpus ?? 0))")

    // 6. a second worker in v1's sandbox, as its own participant
    r = h.run(["worker", "add", "vw", "v2", "--sandbox", "vw-v1", "--task", "say hello too"], timeout: 300)
    check(r.code == 0 && r.out.contains("shares vw-v1"), "6 worker add vw v2 --sandbox vw-v1 (\(r.code): \(r.out.prefix(300)) \(r.err.suffix(300)))")
    check(h.waitFor(120) { says("vw", "v2", "v2 is up: You are v2") }, "6 v2 says it is up, as v2 (send: \(text(work.path + "/res-v2-send")))")
    let e2 = envOf("v2")
    check(e2["CHAT_TOKEN_V2"]?.hasPrefix("doz_cred_") == true && e2["CHAT_TOKEN"] == e2["CHAT_TOKEN_V2"]
          && e2["CHAT_TOKEN_FILE"] == e2["CHAT_TOKEN_FILE_V2"] && text(work.path + "/res-v2-path").hasSuffix("/CHAT_TOKEN_V2"),
          "6 its own variables, aliased for its session: CHAT_TOKEN_FILE is its own file (\(e2.keys.sorted()))")
    check(text(work.path + "/res-v2-file") == e2["CHAT_TOKEN_V2"], "6 …its file holds its own placeholder")
    check(h.run(["worker", "ls", "vw"]).out.contains("shares vw-v1: workers there can read each other's placeholders"), "6 worker ls: shares vw-v1")
    jsons = ""
    for a in [["worker", "ls", "vw"], ["workspace", "show", "vw"], ["ls"], ["net", "show", "vw-v1"]] { jsons += h.run(a + ["--json"]).out }
    let leaks6 = holders("dzc_", under: root.path) + holders("dzc_", under: work.path)
    check(!jsons.contains("dzc_") && leaks6.isEmpty, "6 no dzc_ in the store, the folder or any --json (\(leaks6.prefix(3)))")

    // 7. v2 ended: v1 still talks
    r = h.run(["worker", "end", "vw", "v2"], timeout: 120)
    check(r.code == 0, "7 worker end vw v2 (\(r.code) \(r.err.prefix(200)))")
    let word = "still-here-\(UUID().uuidString.prefix(6))"
    try? word.write(toFile: work.path + "/say-v1-\(UUID().uuidString.prefix(6))", atomically: true, encoding: .utf8)
    check(h.waitFor(60) { says("vw", "v1", word) }, "7 v1 still talks")
    check(h.row("vw-v1")?.phase == "running", "7 …its sandbox runs on")

    // 8. v1 ended: stopped, its disk kept; --rm deletes it
    r = h.run(["worker", "end", "vw", "v1"], timeout: 300)
    check(r.code == 0 && h.row("vw-v1")?.phase == "off", "8 worker end vw v1: its sandbox stopped, kept (\(r.code) \(h.row("vw-v1")?.phase ?? "gone"))")
    r = h.run(["worker", "end", "vw", "v1", "--rm"], timeout: 300)
    check(r.code == 0 && h.row("vw-v1") == nil, "8 worker end vw v1 --rm: deleted (\(r.code) \(r.err.prefix(200)))")

    // 9. sleep: one change for a shared sandbox, the same programs after the wake (v3 and v4 also write a conversation with
    // what plant.txt holds — put there only now, after the leak sweeps of rows 2 and 6, and taken away after V1)
    try? vplant.write(to: work.appendingPathComponent("plant.txt"), atomically: true, encoding: .utf8)
    r = h.run(["worker", "add", "vw", "v3", "--isolation", "vm", "--task", "stay"], timeout: 900)
    check(r.code == 0, "9 worker add vw v3 --isolation vm (\(r.code) \(r.err.suffix(300)))")
    r = h.run(["worker", "add", "vw", "v4", "--sandbox", "vw-v3", "--task", "stay too"], timeout: 300)
    check(r.code == 0 && h.waitFor(120) { says("vw", "v4", "v4 is up: You are v4") }, "9 worker add vw v4 --sandbox vw-v3, up (\(r.code))")
    let plan9 = h.json(["workspace", "sleep", "vw", "--dry-run"], WorkspaceLifecyclePlan.self)
    check(plan9?.queue.changes == 1 && plan9?.rows.filter(\.changes).count == 2, "9 the plan: v3 and v4 are one change (\(plan9?.queue.changes ?? -1))")
    func pids() -> [String: Int] {
        var out: [String: Int] = [:]
        for s in h.sessions("vw-v3") { if let p = s.pid { out[s.name] = p } }
        return out
    }
    let before = pids()
    r = h.run(["workspace", "sleep", "vw"], timeout: 600)
    check(r.code == 0 && h.row("vw-v3")?.phase == "hibernated", "9 sleep vw: vw-v3 hibernated (\(r.code) \(h.row("vw-v3")?.phase ?? "?") \(r.err.suffix(300)))")
    r = h.run(["workspace", "wake", "vw"], timeout: 600)
    check(r.code == 0 && h.row("vw-v3")?.phase == "running", "9 wake vw: running (\(r.code) \(r.err.suffix(300)))")
    let after = pids()
    check(!before.isEmpty && before["v3"] != nil && before == after, "9 …the same sessions and pids (\(before) → \(after))")

    // 10. finish, reopen, wake: a cold boot, both up again
    r = h.run(["workspace", "finish", "vw", "--yes", "--json"], timeout: 600)
    check(r.code == 0 && h.row("vw-v3")?.phase == "off", "10 finish vw: the sandbox shut down, kept (\(r.code) \(h.row("vw-v3")?.phase ?? "gone"))")
    // V1–V3: the run's archive holds the shared sandbox's conversations, copied out before it shut down.
    let fin = try? HostWire.decoder.decode(WorkspaceChanged.self, from: r.outData)
    let sroot = WorkspaceStore.resolved(root.path)
    let ver = RunArchive.verify(root: sroot + "/" + (fin?.archive ?? "?"))
    let vt = (ver.manifest?.files ?? []).filter { $0.path.hasPrefix("transcripts/vw-v3/") }
    check(ver.ok && !vt.isEmpty && vt.allSatisfy { $0.source == "sandbox" && $0.sourceSHA256 != nil },
          "V1 finish archives the sandbox's conversations, each with its source's sha256 (\(vt.map(\.path)))")
    var archived = ""
    for f in ver.manifest?.files ?? [] { archived += (fm.contents(atPath: sroot + "/" + (fin?.archive ?? "?") + "/" + f.path)).map { String(decoding: $0, as: UTF8.self) } ?? "" }
    check(!vplant.isEmpty && !archived.contains(vplant) && archived.contains("[a chat token of vplant, removed by doz]"), "V1 …a token planted in the guest's conversation is redacted")
    try? fm.removeItem(at: work.appendingPathComponent("plant.txt"))
    check(ver.manifest?.notes.contains { $0.contains(".jsonl not copied (a link") } == true, "V2 a symlinked guest .jsonl is refused, and said (\(ver.manifest?.notes.prefix(4) ?? []))")
    r = h.run(["workspace", "reopen", "vw"], timeout: 60)
    let woke = h.run(["workspace", "wake", "vw"], timeout: 900)
    func upCount(_ who: String) -> Int { messages("vw").filter { $0["from"] as? String == who && ($0["content"] as? String)?.hasPrefix("\(who) is up") == true }.count }
    check(woke.code == 0 && h.row("vw-v3")?.phase == "running", "10 reopen + wake: a cold boot (\(woke.code) \(woke.err.suffix(300)))")
    check(h.waitFor(120) { upCount("v3") >= 2 && upCount("v4") >= 2 }, "10 …v3 and v4 up again (v4 with a new token: \(woke.out.contains("new token")))")

    // 11. archive with --remove-sandboxes: its disk saved first (757: an image), then the sandbox; restore names the image
    r = h.run(["workspace", "archive", "vw", "--remove-sandboxes", "--yes"], timeout: 900)
    check(r.code == 0 && h.row("vw-v3") == nil, "11 archive vw --remove-sandboxes: vw-v3 removed (\(r.code) \(r.err.suffix(300)))")
    check(h.run(["image", "ls"]).out.contains("vw-v3-tpl"), "11 …its disk saved as the image vw-v3-tpl")
    r = h.run(["workspace", "restore", "vw"], timeout: 120)
    check(r.code == 0 && r.out.contains("vw-v3 is gone — its disk is the image vw-v3-tpl"), "11 restore names the saved disk (\(r.code) \(r.out.suffix(300)))")

    // 12. delete --remove-sandboxes: only what Dozable made for it
    h.run(["create", "vadopt", "--image", "lab"], timeout: 300)
    h.run(["workspace", "adopt", "vmw", "vadopt"], timeout: 60)
    // V3: a sandbox shut down before the finish is never woken: "not running", its conversations stay on its disk.
    h.run(["shutdown", "vmw"], timeout: 300)
    r = h.run(["workspace", "finish", "vmw", "--yes", "--json"], timeout: 600)
    let vfin = try? HostWire.decoder.decode(WorkspaceChanged.self, from: r.outData)
    let vnotes = RunArchive.verify(root: WorkspaceStore.resolved(root.path) + "/" + (vfin?.archive ?? "?")).manifest?.notes ?? []
    check(r.code == 0 && h.row("vmw")?.phase == "off" && vnotes.contains { $0.contains("vmw is not running: its conversations stay on its disk") },
          "V3 a sandbox shut down before finish: not woken, \"not running: its conversations stay on its disk\" (\(vnotes.prefix(3)))")
    r = h.run(["workspace", "delete", "vmw", "--remove-sandboxes", "--yes"], timeout: 900)
    check(r.code == 0 && h.row("vmw") == nil && h.row("vadopt") != nil, "12 delete vmw --remove-sandboxes: vmw removed, the adopted vadopt kept (\(r.code) \(r.err.suffix(300)))")
    check(h.json(["workspace", "ls", "--loose"], WorkspaceListing.self)?.loose.contains { $0.name == "vadopt" } == true, "12 …vadopt loose again")

    // 13. (762, F5) a space's run-lifetime sandbox: down saves its disk as an image first, names it, then removes the sandbox.
    let sx = work.appendingPathComponent("vsx")
    try? fm.createDirectory(at: sx, withIntermediateDirectories: true)
    try? "Say hello.\n".write(to: sx.appendingPathComponent("BRIEF.md"), atomically: true, encoding: .utf8)
    let sxFile = sx.appendingPathComponent("vsx.space.yaml").path
    try? """
    doz: space/3
    space: vsx
    brief: BRIEF.md
    owner: ada
    chat:
      rooms:
        vsx: { main: true, members: [owner] }
    sandboxes:
      box: { image: lab, cpus: 2, memory: 2G }
    agents:
      w1: { kind: claude-code, where: "sandbox:box", prompt: say hi }

    """.write(toFile: sxFile, atomically: true, encoding: .utf8)
    r = h.run(["workspace", "up", "-f", sxFile, "--yes"], timeout: 900)
    check(r.code == 0 && h.row("vsx-box") != nil, "13 up vsx: its sandbox vsx-box made (\(r.code) \(r.err.suffix(300)))")
    r = h.run(["workspace", "down", "vsx", "--yes", "--json"], timeout: 900)
    let sxd = try? HostWire.decoder.decode(SpaceActed.self, from: r.outData)
    check(r.code == 0 && sxd?.savedDisks?["vsx-box"] == "vsx-box-tpl", "13 down vsx: the disk saved as vsx-box-tpl, named (\(r.code) \(String(describing: sxd?.savedDisks)) \(r.err.suffix(300)))")
    check(h.run(["image", "ls"]).out.contains("vsx-box-tpl") && h.row("vsx-box") == nil, "13 …the image there, then the sandbox removed")
}
