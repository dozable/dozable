import Darwin
import Foundation
import DozableKit
import DozableHost

// `make test-cli-workspace` (`doz-vmtest cli-workspace --doz PATH`): workspaces through the real signed doz, its daemon and
// the chat server it runs — no VM (a lab sandbox is made, never booted), a store of its own (/tmp/dzo-PID-ws), settings
// beside it, the memory keychain, a FAKE claude first on the sessions' PATH, ports from freePort(). Only harmless programs
// (sh, sleep, printf) in a scratch folder; every process it stops is one it started. The rows:
//
//   1. ls with no daemon: answered, and no daemon starts
//   2. today's sandbox and session on this Mac are listed as loose agents
//   3. chat on: new makes the room named for it, nothing posted by you; prints "setting up · you"; the brief's text in no
//      log, no folder path in the workspace's log
//   4. a room that exists: refused (exit 4, nothing made); --room links it, nothing posted
//   5. adopt the sandbox and @mac/wsu: doz.json unchanged, `workspace` in ls/sessions --json, state working; refusals
//      (already in one, missing, bare @mac)
//   6. release: loose again, and the log says so
//   7. show and log with the daemon stopped: answered, no daemon starts
//   8. an unknown field survives edit; folders 0700, files 0600
//   9. bad names; rename keeps the room's name; doz rename and doz rm move and remove the agent
//  10. chat off: no room, the note names --make-room
//  11. no folders: made, shown and listed; --from-project without a folder refused
//  12–22. a workspace's manager, started from its bot (CLIWorkspaceManagerRows.swift)
func cliWorkspaceSuite(binary: String) async {
    print("cli: workspaces — no VM")
    let fm = FileManager.default
    let root = URL(fileURLWithPath: "/tmp/dzo-\(getpid())-ws")
    try? fm.removeItem(at: root)
    try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    let h = CLIHarness(binary: binary, store: root)
    let xdg = URL(fileURLWithPath: root.path + "-xdg")
    try? fm.removeItem(at: xdg)
    h.env["XDG_CONFIG_HOME"] = xdg.path
    h.env["DOZ_TEST_CREDENTIALS"] = "memory"
    let fakeBin = root.appendingPathComponent("bin")
    try? fm.createDirectory(at: fakeBin, withIntermediateDirectories: true)
    try? "#!/bin/sh\necho fake-claude\nexec sleep 600\n".write(to: fakeBin.appendingPathComponent("claude"), atomically: true, encoding: .utf8)
    chmod(fakeBin.appendingPathComponent("claude").path, 0o755)
    h.env["DOZ_TEST_MAC_PATH"] = fakeBin.path + ":/usr/bin:/bin:/usr/sbin:/sbin"
    let work = URL(fileURLWithPath: WorkspaceStore.resolved(root.appendingPathComponent("work").path))
    try? fm.createDirectory(at: work, withIntermediateDirectories: true)
    let store = DozableStore(root: root)
    let ws = WorkspaceStore(store: store)
    let paths = ChatPaths(store: store)
    var started: Set<String> = []

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
    func serversOfStore() -> [Int32] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axo", "pid=,command="]
        let o = Pipe()
        p.standardOutput = o
        try? p.run()
        let d = o.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: d, as: UTF8.self).split(separator: "\n").compactMap { l in
            let t = l.trimmingCharacters(in: .whitespaces)
            guard t.contains("chat serve"), t.contains(paths.config) else { return nil }
            return Int32(t.split(separator: " ").first ?? "")
        }
    }
    func sha(_ path: String) -> String { (try? Data(contentsOf: URL(fileURLWithPath: path))).map(WorkspaceStore.sha256) ?? "" }
    func mode(_ p: String) -> mode_t { var st = stat(); return lstat(p, &st) == 0 ? st.st_mode & 0o777 : 0 }
    func text(_ p: String) -> String { (try? String(contentsOfFile: p, encoding: .utf8)) ?? "" }
    func detail(_ n: String) -> WorkspaceDetail? { h.json(["workspace", "show", n], WorkspaceDetail.self) }
    func listing() -> WorkspaceListing? { h.json(["workspace", "ls"], WorkspaceListing.self) }
    func stopDaemon() {
        h.run(["daemon", "stop"], timeout: 60)
        _ = h.waitFor(20) { !h.hostRunning }
    }

    defer {
        for s in started { h.run(["sessions", "end", "@mac", s, "--yes"], timeout: 30) }
        h.run(["chat", "off"], timeout: 30)
        stopDaemon()
        for p in serversOfStore() { kill(p, SIGKILL) }
        check(serversOfStore().isEmpty && !h.hostRunning, "workspace: no daemon or chat server of this suite left running")
        try? fm.removeItem(atPath: MacPlace.socketDirectory(store: store))
        try? fm.removeItem(at: root)
        try? fm.removeItem(at: xdg)
    }
    guard MacDeckhold.locate(executable: binary).url != nil else {
        check(false, "deckhold-mac beside \(binary) (make cli builds it when the pinned toolchain is in .tools)")
        return
    }

    let marker = "BRIEF-TEXT-\(UUID().uuidString.prefix(8))"
    let brief = root.appendingPathComponent("brief.md").path
    try? "Make the launch video. \(marker)\n".write(toFile: brief, atomically: true, encoding: .utf8)

    // 1. ls with no daemon
    var r = h.run(["workspace", "ls"])
    check(r.code == 0 && r.out.contains("Workspaces: none yet") && r.out.contains("Loose agents: none"), "1 ls with nothing: answered (\(r.code))")
    check(!h.hostRunning, "1 …and no daemon started")
    r = h.run(["workspace", "--help"])
    check(["new", "ls", "show", "adopt", "release", "edit", "log", "rename"].allSatisfy { r.out.contains("  \($0)") }, "1 doz workspace --help lists every command")

    // 2. loose agents
    r = h.run(["create", "wsa", "--image", "lab"], timeout: 120)
    check(r.code == 0, "2 create wsa (lab, not started) (\(r.code))")
    let docSHA = sha(store.configFile("wsa").path)
    r = h.run(["run", "@mac", "-d", "--unfenced", "--session", "wsu", "--folder", work.path, "--",
               "/bin/sh", "-c", #"printf '\033]7501;?\033\\'; sleep 1; printf '\033]7501;state=working:app=fake\033\\'; exec sleep 600"#], timeout: 60)
    if r.code == 0 { started.insert("wsu") }
    check(r.code == 0, "2 a session on this Mac, wsu (\(r.code))")
    let sessionsSHA = sha(root.appendingPathComponent("mac-sessions/sessions.json").path)
    var l = listing()
    check(l?.loose.map(\.name).sorted() == ["@mac/wsu", "wsa"], "2 ls lists wsa and @mac/wsu as loose agents (\(l?.loose.map(\.name) ?? []))")
    r = h.run(["workspace", "ls"])
    check(r.out.contains("Loose agents") && r.out.contains("@mac/wsu") && r.out.contains("session on this Mac"), "2 …in the text too")

    // 3. chat on; new makes the room and posts nothing
    h.run(["config", "set", "chat.page_port", String(freePort())])
    h.run(["config", "set", "chat.line_port", String(freePort())])
    r = h.run(["chat", "on", "--name", "ada"], timeout: 60)
    check(r.code == 0, "3 chat on (\(r.code))")
    r = h.run(["workspace", "new", "demo", "--prompt-file", brief, "--folder", work.path], timeout: 60)
    check(r.code == 0 && r.out.hasPrefix("demo — setting up · you") && r.out.contains("#demo"), "3 new demo: made, setting up · you, its room (\(r.code): \(r.out.prefix(80)))")
    check(h.run(["chat", "rooms"]).out.contains("demo —"), "3 the room demo exists")
    r = h.run(["chat", "read", "demo"])
    check(r.code == 0 && !r.out.contains("ada:") && !r.out.contains(marker), "3 …with nothing posted by you (\(r.out.prefix(120)))")
    r = h.run(["workspace", "ls"])
    check(r.out.contains("setting up · you") && r.out.contains("#demo"), "3 ls shows it setting up · you")
    let logText = text(ws.folder("demo") + "/log.jsonl")
    check(logText.contains("\"room-made\"") && !logText.contains(marker) && !logText.contains(work.path), "3 its log: room-made; no brief text, no folder path")
    check(!text(store.logFile.path).contains(marker), "3 the brief's text is not in daemon.log")

    // 4. a room that exists
    h.run(["chat", "room", "taken"])
    r = h.run(["workspace", "new", "taken", "--prompt-file", brief], timeout: 60)
    check(r.code == 4 && r.err.contains("--room taken") && !ws.exists("taken"), "4 a room taken exists: refused, nothing made (\(r.code))")
    r = h.run(["workspace", "new", "taken", "--prompt-file", brief, "--room", "taken"], timeout: 60)
    check(r.code == 0 && r.out.contains("#taken"), "4 --room taken links it (\(r.code))")
    check(!h.run(["chat", "read", "taken"]).out.contains(marker), "4 …and posts nothing")
    check(text(ws.folder("taken") + "/log.jsonl").contains("\"room-linked\""), "4 …logged room-linked")

    // 5. adopt
    r = h.run(["workspace", "adopt", "demo", "wsa"])
    check(r.code == 0, "5 adopt demo wsa (\(r.code))")
    r = h.run(["workspace", "adopt", "demo", "@mac/wsu"])
    check(r.code == 0, "5 adopt demo @mac/wsu (\(r.code))")
    check(sha(store.configFile("wsa").path) == docSHA, "5 wsa's doz.json is unchanged")
    check(sha(root.appendingPathComponent("mac-sessions/sessions.json").path) == sessionsSHA, "5 sessions.json is unchanged")
    check(h.row("wsa")?.workspace == "demo", "5 doz ls --json: wsa has workspace demo")
    check(h.sessions("@mac").first { $0.name == "wsu" }?.workspace == "demo", "5 doz sessions @mac --json: wsu has workspace demo")
    check(h.waitFor(10) { detail("demo")?.state == "working" }, "5 demo is working (wsu's program says so) — \(detail("demo")?.state ?? "?")")
    r = h.run(["workspace", "adopt", "taken", "wsa"])
    check(r.code == 4 && r.err.contains("wsa is already in demo — doz workspace release demo wsa first."), "5 adopting it into another: refused (\(r.code))")
    check(h.run(["workspace", "adopt", "demo", "nosuch"]).code == 2, "5 a missing sandbox: exit 2")
    check(h.run(["workspace", "adopt", "demo", "@mac/nosuch"]).code == 2, "5 a missing session: exit 2")
    r = h.run(["workspace", "adopt", "demo", "@mac"])
    check(r.code == 64 && r.err.contains("@mac/SESSION"), "5 bare @mac: refused, name the session (\(r.code))")
    check(listing()?.loose.isEmpty == true, "5 no loose agents left")

    // 6. release
    r = h.run(["workspace", "release", "demo", "wsa"])
    check(r.code == 0 && h.row("wsa")?.workspace == nil, "6 release demo wsa: loose again (\(r.code))")
    r = h.run(["workspace", "log", "demo"])
    check(r.out.contains("released wsa") && r.out.contains("adopted wsu"), "6 the log says adopted and released")

    // 7. looking with the daemon stopped
    stopDaemon()
    started.remove("wsu")          // its holder outlives the daemon; ended at the end through a new one
    r = h.run(["workspace", "show", "demo"])
    check(r.code == 0 && r.out.hasPrefix("demo — "), "7 show with no daemon (\(r.code))")
    r = h.run(["workspace", "log", "demo", "--since", "1h"])
    check(r.code == 0 && r.out.contains("created"), "7 log --since 1h with no daemon (\(r.code))")
    check(h.run(["workspace", "ls"]).code == 0, "7 ls with no daemon")
    check(!h.hostRunning, "7 …and none started")
    started.insert("wsu")

    // 8. an unknown field survives an edit; modes
    let recPath = ws.folder("demo") + "/workspace.json"
    if var obj = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: recPath)))) as? [String: Any] {
        obj["later"] = ["kept": true]
        try? JSONSerialization.data(withJSONObject: obj).write(to: URL(fileURLWithPath: recPath))
    }
    r = h.run(["workspace", "edit", "demo", "--add-ref", "https://example.com/spec"], timeout: 60)
    let after = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: recPath)))) as? [String: Any]
    check(r.code == 0 && (after?["later"] as? [String: Any])?["kept"] as? Bool == true, "8 an unknown field survives edit (\(r.code))")
    check(mode(ws.root) == 0o700 && mode(ws.folder("demo")) == 0o700, "8 the folders are 0700")
    check(["workspace.json", "brief.md", "log.jsonl"].allSatisfy { mode(ws.folder("demo") + "/" + $0) == 0o600 }, "8 the files are 0600")

    // 9. names, rename, the hooks
    check(h.run(["workspace", "new", "Bad_Name", "--prompt-file", brief]).code == 64, "9 a bad name: exit 64")
    r = h.run(["workspace", "rename", "demo", "demo2"])
    check(r.code == 0 && r.out.contains("#demo") && r.out.contains("keeps its name"), "9 rename demo demo2: the room keeps its name (\(r.code))")
    r = h.run(["create", "wsb", "--image", "lab"], timeout: 120)
    r = h.run(["workspace", "adopt", "demo2", "wsb"])
    check(r.code == 0, "9 adopt demo2 wsb (\(r.code))")
    r = h.run(["rename", "wsb", "wsc"])
    check(r.code == 0 && detail("demo2")?.agents.contains { $0.place == "wsc" } == true, "9 doz rename wsb wsc: the agent follows (\(r.code))")
    r = h.run(["rm", "wsc", "--yes"], timeout: 120)
    check(r.code == 0 && detail("demo2")?.agents.contains { $0.place == "wsc" } == false, "9 doz rm wsc: the agent is let go (\(r.code))")
    r = h.run(["workspace", "log", "demo2", "--json"])
    let acts = ((try? JSONSerialization.jsonObject(with: r.outData)) as? [[String: Any]])?.map { "\($0["action"] ?? "")/\($0["by"] ?? "")" } ?? []
    check(acts.suffix(3) == ["adopted/you", "agent-renamed/doz", "agent-removed/doz"], "9 …logged by doz (\(acts.suffix(3)))")

    // 10. chat off
    h.run(["chat", "off"], timeout: 30)
    r = h.run(["workspace", "new", "quiet", "--prompt-file", brief, "--folder", work.path + ":ro"], timeout: 60)
    check(r.code == 0 && r.out.contains("room     none") && r.out.contains("--make-room") && r.out.contains("read-only"), "10 chat off: no room, the note names --make-room (\(r.code))")

    // 11. no folders
    r = h.run(["workspace", "new", "bare", "--prompt-file", brief], timeout: 60)
    check(r.code == 0 && r.out.contains("folders  none"), "11 new with no folder (\(r.code))")
    check(detail("bare")?.folders.isEmpty == true && listing()?.workspaces.contains { $0.name == "bare" } == true, "11 shown and listed")
    r = h.run(["workspace", "new", "proj", "--prompt-file", brief, "--from-project"])
    check(r.code == 64 && r.err.contains("--folder") && !ws.exists("proj"), "11 --from-project with no folder: refused (\(r.code))")

    // 12–22. a workspace's manager (CLIWorkspaceManagerRows.swift)
    cliWorkspaceManagerRows(h, root: root, store: store, started: &started)
}
