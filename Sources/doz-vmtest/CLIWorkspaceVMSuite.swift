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
    let store = DozableStore(root: root)
    defer {
        h.run(["rm", "vmw", "--yes"], timeout: 180)
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
    let brief = root.path + "-brief.md"
    try? "Make the VM demo.\n".write(toFile: brief, atomically: true, encoding: .utf8)
    defer { try? fm.removeItem(atPath: brief) }

    h.run(["config", "set", "chat.page_port", String(freePort())])
    h.run(["config", "set", "chat.line_port", String(freePort())])
    var r = h.run(["chat", "on", "--name", "ada"], timeout: 60)
    check(r.code == 0, "chat on (\(r.code))")
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
    r = h.run(["workspace", "stop", "vmw"], timeout: 300)
    check(r.code == 0 && h.row("vmw")?.phase == "off", "3 stop vmw: the sandbox is off, and kept (\(r.code) \(h.row("vmw")?.phase ?? "gone"))")
    check(h.json(["workspace", "show", "vmw"], WorkspaceDetail.self)?.state == "asleep", "3 …asleep")

    // 4. a restart posts nothing
    try? fm.removeItem(atPath: work.path + "/res-send")
    r = h.run(["workspace", "start", "vmw"], timeout: 900)
    check(r.code == 0 && !r.out.contains("posted the brief"), "4 start vmw again (\(r.code) \(r.err.suffix(300)))")
    check(h.waitFor(120) { ups("vmw") >= 2 }, "4 vera is up again")
    check(mine("vmw").count == 1, "4 your message count stays 1 (\(mine("vmw").count))")
    h.run(["workspace", "stop", "vmw"], timeout: 300)
}
