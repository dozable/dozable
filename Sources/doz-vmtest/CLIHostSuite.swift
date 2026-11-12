import Darwin
import Foundation
import DozableKit
import DozableHost

// `make test-cli-host` (`doz-vmtest cli-host --doz PATH`): sessions on THIS Mac (`@mac`) through the real signed doz, its
// host and the real `deckhold-mac` — no VM, so a runner without the virtualization entitlement can run it. A store of its
// own (`/tmp/dzo-PID-mh`), so the socket folder is that store's (its hash): it cannot meet a real host's. Only harmless
// programs (`sh`, `sleep`, a fake agent that writes OSC 7501), only in a scratch folder; every process it kills is one it
// started (its own host, its own holders). The doz processes run with CLAUDECODE / CLAUDE_CODE_* set — none may reach a
// session.

/// The fake agent: asks for the protocol, waits for deckhold's answer, then idle → working → done, one step per gate file.
private let macFakeAgent = #"""
st() { printf '\033]7501;%s\033\\' "$1"; }
gate() { while [ ! -e "$1" ]; do sleep 0.2; done; }
stty raw -echo
printf '\033]7501;?\033\\'
ans=$(dd bs=1 count=8 2>/dev/null | od -An -c | tr -d ' \n')
stty sane
case "$ans" in *7501*) echo "ANSWERED";; *) echo "NO-ANSWER [$ans]";; esac
st "state=idle:app=fake-agent"
gate go1
st "state=working:app=fake-agent:msg=$(printf 'thinking' | base64)"
gate go2
st "state=done:app=fake-agent"
echo AGENT-DONE
sleep 600
"""#

/// A program that reads its terminal in raw mode and prints how many bytes each read brought (`R:N`) — a send's Enter
/// must arrive as a read of its own. (Also used by the sandbox suite.)
let fakeTUI = #"stty raw -echo; while :; do n=$(dd bs=4096 count=1 2>/dev/null | wc -c | tr -d ' '); printf 'R:%s\r\n' "$n"; done"#

func cliHostSuite(binary: String) async {
    let root = URL(fileURLWithPath: "/tmp/dzo-\(getpid())-mh")
    try? FileManager.default.removeItem(at: root)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let t = CLIHarness(binary: binary, store: root)
    // The settings beside the store, not in it (nuke removes both, one after the other).
    let xdg = URL(fileURLWithPath: root.path + "-xdg")
    try? FileManager.default.removeItem(at: xdg)
    t.env["XDG_CONFIG_HOME"] = xdg.path
    t.env["DOZ_HOST_IDLE"] = "30"
    t.env["DOZ_TEST_CREDENTIALS"] = "memory"
    // The markers a doz started from inside Claude Code carries — none may reach a session on the Mac.
    t.env["CLAUDECODE"] = "1"
    t.env["CLAUDE_CODE_ENTRYPOINT"] = "cli-host-test"
    // The sessions' PATH, instead of the person's login shell (never run by a test).
    t.env["DOZ_TEST_MAC_PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
    let work = root.appendingPathComponent("work").resolvingSymlinksInPath()
    try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let store = DozableStore(root: root)
    let dir = MacPlace.socketDirectory(store: store)
    var started: Set<String> = []
    defer {
        for s in started { t.run(["sessions", "end", "@mac", s, "--yes"], timeout: 30) }
        t.run(["host", "stop"], timeout: 60)
        try? FileManager.default.removeItem(atPath: dir)
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: xdg)
    }
    func file(_ name: String) -> String { (try? String(contentsOf: work.appendingPathComponent(name), encoding: .utf8)) ?? "" }
    func rows() -> [SessionRow] { t.json(["sessions", "@mac"], [SessionRow].self) ?? [] }
    func row(_ s: String) -> SessionRow? { rows().first { $0.name == s } }
    func screen(_ s: String, until want: String) -> CLIRun {
        var r = CLIRun(code: -1, out: "", err: "", outData: Data())
        let t0 = Date()
        repeat {
            r = t.run(["sessions", "screen", "@mac", s], timeout: 30)
            if r.out.contains(want) { break }
            usleep(200_000)
        } while Date().timeIntervalSince(t0) < 8
        return r
    }
    func run(_ s: String, _ argv: [String], extra: [String] = []) -> CLIRun {
        let r = t.run(["run", "@mac", "-d", "--session", s, "--workdir", work.path] + extra + ["--"] + argv, timeout: 60)
        if r.code == 0 { started.insert(s) }
        return r
    }

    print("cli: sessions on this Mac (@mac) — no VM")
    guard MacDeckhold.locate(executable: binary).url != nil else {
        check(false, "deckhold-mac beside \(binary) (make cli builds it when the pinned toolchain is in .tools)")
        return
    }

    // Every other command refuses @mac, with one plain message.
    var r = t.run(["exec", "@mac", "--", "true"])
    check(r.code == 64 && r.err.contains("@mac is this Mac, not a sandbox"), "exec @mac is refused plainly (\(r.code))")
    r = t.run(["start", "@mac"])
    check(r.code == 64 && r.err.contains("@mac is this Mac"), "start @mac is refused (\(r.code))")
    r = t.run(["pause", "@mac"])
    check(r.code == 64 && r.err.contains("@mac is this Mac"), "pause @mac is refused (\(r.code))")

    // A session: the clean environment, the folder, the label.
    r = run("envs", ["/bin/sh", "-c", "env > env.txt; pwd > pwd.txt; sleep 600"], extra: ["-e", "MARK=yes"])
    check(r.code == 0 && r.err.contains("[doz] @mac is this Mac: no sandbox, no proxy"), "run @mac -d: started, the no-isolation line said (\(r.code))")
    check(t.waitFor(10) { file("env.txt").contains("MARK=yes") }, "the program ran in --workdir with -e MARK=yes")
    let env = file("env.txt")
    check(!env.contains("CLAUDECODE") && !env.contains("CLAUDE_CODE_"), "no CLAUDECODE / CLAUDE_CODE_* reached it, though doz ran with them")
    // DOZ_TTY is deckhold's own (the session's pty, for a helper with no controlling terminal) — not the host's.
    let leaked = env.split(separator: "\n").filter { ($0.hasPrefix("DOZ_") && !$0.hasPrefix("DOZ_TTY=")) || $0.hasPrefix("XPC_") || $0.hasPrefix("__CF") }
    check(leaked.isEmpty, "nothing else of the host's environment (DOZ_*, XPC_*, __CF*)\(leaked.isEmpty ? "" : ": \(leaked.joined(separator: ", "))")")
    check(env.contains("TERM=xterm-256color") && env.contains("PATH=/usr/bin:/bin:/usr/sbin:/sbin") && env.contains("HOME="),
          "TERM, the PATH, HOME are set")
    let pwd = file("pwd.txt").trimmingCharacters(in: .whitespacesAndNewlines)
    check(realPath(pwd) == realPath(work.path), "its folder is --workdir (\(pwd))")
    r = t.run(["run", "@mac", "-d", "--session", "bad", "-e", "CLAUDECODE=1", "--", "/bin/sh", "-c", "true"])
    check(r.code == 64 && r.err.contains("CLAUDECODE"), "-e CLAUDECODE=… is refused, with the reason (\(r.code))")
    r = t.run(["run", "@mac", "-d", "--session", String(repeating: "x", count: 33), "--", "/bin/sh"])
    check(r.code == 64, "a session name of 33 characters is refused (\(r.code))")
    r = t.run(["run", "@mac", "-d", "--session", "nope", "--", "no-such-program-here"])
    check(r.code == 125 && r.err.contains("no program no-such-program-here"), "a program that is not there: doz's failure, 125 (\(r.code))")

    // The socket folder.
    var st = stat()
    check(lstat(dir, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR && (st.st_mode & 0o777) == 0o700 && st.st_uid == getuid(),
          "the socket folder is a folder, 0700, mine (\(dir))")
    check(dir.hasPrefix(MacPlace.userTempDirectory()) && MacPlace.socketPath(dir, String(repeating: "x", count: 32)).utf8.count < 104,
          "it is in the user's temporary folder, and a 32-character session's socket path fits (< 104 bytes)")

    // The fake agent: its status through deckhold, the host and the CLI.
    try? macFakeAgent.write(to: work.appendingPathComponent("agent.sh"), atomically: true, encoding: .utf8)
    check(run("agent", ["/bin/sh", "agent.sh"]).code == 0, "the fake agent runs on this Mac, detached")
    check(t.waitFor(15) { row("agent")?.status?.state == .idle }, "sessions @mac: idle (\(row("agent")?.status?.label ?? "nothing"))")
    r = t.run(["sessions", "wait", "@mac", "agent", "--until", "idle", "--timeout", "10"], timeout: 30)
    check(r.code == 0 && r.out.contains("idle"), "sessions wait --until idle: answered at once (the state now counts)")
    let waiter = try? AttachedClient(t, ["sessions", "wait", "@mac", "agent", "--until", "done", "--until", "error", "--timeout", "30", "--json"])
    usleep(500_000)
    check(waiter?.process.isRunning == true, "sessions wait --until done: still waiting while it is idle")
    FileManager.default.createFile(atPath: work.appendingPathComponent("go1").path, contents: nil)
    check(t.waitFor(10) { row("agent")?.status?.state == .working }, "…working")
    usleep(500_000)
    check(waiter?.process.isRunning == true, "…and while it is working")
    FileManager.default.createFile(atPath: work.appendingPathComponent("go2").path, contents: nil)
    check(t.waitFor(10) { row("agent")?.status?.state == .done }, "…done")
    let waited = waiter?.exited(within: 10)
    let wj = (try? HostWire.decoder.decode(SessionWaited.self, from: waiter?.out.bytes ?? Data()))
    check(waited == 0 && wj?.state == "done" && wj?.timedOut == false, "sessions wait returns when it is done (exit \(waited.map(String.init) ?? "none"), \(wj?.state ?? "?"))")
    r = t.run(["sessions", "wait", "@mac", "agent", "--until", "idle,done,blocked,error", "--timeout", "5", "--json"], timeout: 30)
    let any = try? HostWire.decoder.decode(SessionWaited.self, from: r.outData)
    check(r.code == 0 && any?.state == "done", "--until idle,done,blocked,error (a comma list): has it stopped working? — done (\(r.code))")
    r = t.run(["sessions", "wait", "@mac", "agent", "--until", "blocked", "--timeout", "2"], timeout: 30)
    check(r.code == 124 && r.err.contains("did not become blocked"), "--timeout passes first: exit 124 (\(r.code))")
    r = t.run(["sessions", "wait", "@mac", "nope", "--until", "done", "--timeout", "5"], timeout: 30)
    check(r.code == 2, "wait on a session that is not there: exit 2 (\(r.code))")
    r = t.run(["sessions", "wait", "@mac", "agent", "--until", "asleep"], timeout: 30)
    check(r.code == 64, "an unknown state is a usage error (\(r.code))")
    let text = t.run(["sessions", "@mac"]).out
    check(text.contains("this Mac — no isolation") && text.contains("agent") && text.contains("done"), "the text: the no-isolation header, the session and its status")
    let a = row("agent")
    check(a?.workdir == work.path && a?.argv == ["/bin/sh", "agent.sh"] && a?.openedAt != nil, "--json: workdir, argv, openedAt")

    // send + screen.
    check(run("rd", ["/bin/sh", "-c", "while read x; do echo got:$x; done"]).code == 0, "a session that echoes every line")
    r = t.run(["sessions", "send", "@mac", "rd", "--text", "hi", "--enter"], timeout: 30)
    check(r.code == 0 && r.out.contains("sent 3 bytes to rd on this Mac"), "sessions send @mac: acknowledged (\(r.out.trimmingCharacters(in: .whitespacesAndNewlines)))")
    r = screen("rd", until: "got:hi")
    check(r.code == 0 && r.out.contains("got:hi"), "sessions screen @mac: the program's answer, live")
    r = t.run(["sessions", "screen", "@mac", "rd", "--json"], timeout: 30)
    let live = try? HostWire.decoder.decode(SessionLive.self, from: r.outData)
    check(live?.live == true && live?.cols != nil && live?.cursorX != nil, "screen --json: live, with the size and the cursor")
    // A TUI reads in raw mode: a 236-byte line and its Enter must come as two reads (in one, a TUI takes the CR as pasted).
    check(run("tui", ["/bin/sh", "-c", fakeTUI]).code == 0, "a fake TUI that prints the size of each read")
    usleep(500_000)
    r = t.run(["sessions", "send", "@mac", "tui", "--text", String(repeating: "w", count: 236), "--enter"], timeout: 30)
    check(r.code == 0, "send a 236-byte line --enter")
    r = screen("tui", until: "R:1\n")
    let reads = r.out.split(separator: "\n").map(String.init)
    check(reads.contains("R:236") && reads.contains("R:1") && !reads.contains("R:237"),
          "the Enter is a read of its own, after the text (\(reads.filter { $0.hasPrefix("R:") }.joined(separator: " ")))")
    // The control: the CR inside the text is ONE write — the TUI reads it in the same burst (what --enter used to do).
    r = t.run(["sessions", "send", "@mac", "tui", "--text", String(repeating: "w", count: 236) + "\r"], timeout: 30)
    check(r.code == 0 && screen("tui", until: "R:237\n").out.contains("R:237\n"), "control: a CR inside the text arrives in the same read (R:237)")
    r = t.run(["sessions", "send", "@mac", "nope", "--text", "x"], timeout: 30)
    check(r.code == 2 && r.err.contains("no session nope on this Mac"), "a session that is not there: exit 2 (\(r.code))")

    // attach through a pty: typing, the Ctrl-] menu's d, a reattach, two viewers at once; run without -d attaches.
    check(run("at", ["/bin/sh", "-c", "while read x; do echo at:$x; done"]).code == 0, "a session to attach to")
    do {
        let c = try PTYClient(t, ["attach", "@mac", "at"])
        defer { c.close() }
        usleep(800_000)
        c.type("one\r")
        check(c.wait(10) { $0.text.contains("at:one") }, "attach @mac at: typing reaches the program, its output comes back")
        usleep(700_000)
        c.type("\u{1D}")
        check(c.wait(5) { $0.text.contains("Esc back") }, "Ctrl-] opens the menu")
        c.type("d")
        check(c.exited(within: 8) == 0, "d detaches (exit 0)")
        check(c.text.contains("detached") && c.text.contains("doz attach @mac at"), "the detach line names doz attach @mac at")
    } catch { check(false, "pty: \(error)") }
    check(row("at")?.ended == false, "the session keeps running after the detach")
    do {
        let a = try PTYClient(t, ["attach", "@mac", "at"])
        let b = try PTYClient(t, ["attach", "@mac", "at"])
        defer { a.close(); b.close() }
        check(a.wait(10) { $0.text.contains("at:one") }, "reattached: the screen comes back (at:one)")
        usleep(800_000)
        a.type("two\r")
        check(a.wait(10) { $0.text.contains("at:two") } && b.wait(10) { $0.text.contains("at:two") }, "a second viewer sees what the first typed")
        a.type("\u{1D}\u{1D}")
        b.type("\u{1D}\u{1D}")
        check(a.exited(within: 8) == 0 && b.exited(within: 8) == 0, "both detach (Ctrl-] twice)")
    } catch { check(false, "pty: \(error)") }
    do {
        let c = try PTYClient(t, ["run", "@mac", "--session", "rr", "--workdir", work.path, "--", "/bin/sh", "-c", "echo hello-rr; sleep 600"])
        started.insert("rr")
        defer { c.close() }
        check(c.wait(10) { $0.text.contains("hello-rr") }, "run @mac (no -d) attaches to its new session")
        c.type("\u{1D}\u{1D}")
        check(c.exited(within: 8) == 0, "…and detaches")
    } catch { check(false, "pty: \(error)") }
    r = t.run(["attach", "@mac", "nope"], timeout: 30)
    check(r.code == 2 && r.err.contains("no session nope on this Mac"), "attach to a session that is not there: exit 2 (\(r.code))")
    let ls = t.run(["ls"]).out
    check(ls.contains("this Mac: ") && ls.contains("(no isolation) — doz sessions @mac"), "doz ls: the one line for this Mac (\(ls.split(separator: "\n").last ?? ""))")

    // A host stop leaves them running; the next host adopts them (same pid, same screen).
    let pidBefore = row("rd")?.pid
    check(pidBefore != nil, "rd has a pid (\(pidBefore.map(String.init) ?? "none"))")
    r = t.run(["host", "stop"], timeout: 60)
    check(r.code == 0 && r.out.contains("on this Mac keep running"), "host stop: it says the sessions on this Mac keep running")
    check(t.waitFor(10) { !t.hostRunning }, "the host is gone")
    check(row("rd")?.pid == pidBefore && row("rd")?.ended == false, "no host: sessions @mac still lists rd, same pid (looked at in-process)")
    check(!t.hostRunning, "…and looking started no host")
    r = t.run(["sessions", "send", "@mac", "rd", "--text", "again", "--enter"], timeout: 30)
    check(r.code == 0, "a send starts a host, which adopts the session")
    check(screen("rd", until: "got:again").out.contains("got:hi"), "same screen (got:hi still there) and the new line")
    check(row("rd")?.pid == pidBefore, "same pid after the new host")
    check(t.waitFor(10) { row("agent")?.status?.state == .done }, "the new host watches the agent again: done")

    // kill -9 of the host: the sessions survive.
    if let hp = t.hostPID() {
        kill(hp, SIGKILL)
        check(t.waitFor(10) { kill(hp, 0) != 0 }, "the host (pid \(hp)) killed with SIGKILL")
    } else { check(false, "the host's pid") }
    check(row("rd")?.pid == pidBefore && row("rd")?.ended == false, "after kill -9 of the host, rd still runs (same pid)")

    // end, then restart from the record.
    r = t.run(["sessions", "end", "@mac", "rd", "--yes"], timeout: 30)
    check(r.code == 0 && r.out.contains("ended session rd on this Mac"), "sessions end @mac rd (\(r.out.trimmingCharacters(in: .whitespacesAndNewlines)))")
    check(t.waitFor(5) { row("rd")?.ended == true }, "rd is ended")
    r = t.run(["sessions", "restart", "@mac", "rd", "--yes", "-d"], timeout: 30)
    check(r.code == 0 && r.out.contains("restarted session rd on this Mac"), "sessions restart @mac rd")
    check(t.waitFor(5) { row("rd")?.ended == false && row("rd")?.pid != pidBefore }, "rd runs again, a new program")
    check(row("rd")?.command == "/bin/sh -c while read x; do echo got:$x; done", "…the same command")
    check(t.run(["sessions", "send", "@mac", "rd", "--text", "back", "--enter"], timeout: 30).code == 0
          && screen("rd", until: "got:back").out.contains("got:back"), "and it answers")

    // A holder killed (as a restart of the Mac would): gone; restart starts it again.
    check(run("gn", ["/bin/sh", "-c", "echo gn-mark; sleep 600"]).code == 0, "a session gn")
    check(screen("gn", until: "gn-mark").out.contains("gn-mark"), "gn says gn-mark")
    check(t.run(["host", "stop"], timeout: 60).code == 0, "host stop (its screens are saved once more)")
    if let child = row("gn")?.pid, let holder = parentPID(child) {
        kill(pid_t(holder), SIGKILL)
        check(t.waitFor(10) { row("gn")?.gone == true }, "its holder killed: sessions @mac says gone")
        check(t.run(["sessions", "@mac"]).out.contains("gone"), "…in the text too")
        r = t.run(["sessions", "screen", "@mac", "gn"], timeout: 30)
        check(r.code == 0 && r.out.contains("gn-mark") && r.err.contains("is gone") && r.err.contains("not live"),
              "sessions screen @mac gn: its saved screen, and it says it is gone")
        r = t.run(["sessions", "@mac", "--screen", "gn"], timeout: 30)
        check(r.code == 0 && r.out.contains("gn-mark"), "sessions @mac --screen gn: the saved screen")
        r = t.run(["sessions", "restart", "@mac", "gn", "--yes", "-d"], timeout: 30)
        check(r.code == 0 && t.waitFor(5) { row("gn")?.ended == false }, "restart @mac gn starts it again from its record")
    } else { check(false, "gn's holder pid") }

    // A bypass flag in the session's own argv is allowed, and marked.
    r = run("byp", ["/bin/sh", "-c", "sleep 600", "--dangerously-skip-permissions"])
    check(r.code == 0 && r.err.contains("permissions bypassed"), "a bypass flag in its own argv: started, and said on stderr")
    check(row("byp")?.bypassed == true, "sessions @mac --json: bypassed")
    check(t.run(["sessions", "@mac"]).out.contains("permissions bypassed"), "sessions @mac: marked")
    check(row("envs")?.bypassed == nil, "a session without one is not marked")

    // nuke ends them (a fresh install has none) and removes the socket folder.
    let pids = rows().filter { !$0.ended }.compactMap(\.pid)
    r = t.run(["nuke", "--yes"], timeout: 120)
    check(r.code == 0 && r.out.contains("session") && r.out.contains("on this Mac"),
          "nuke --yes: it ends the sessions on this Mac (\(r.code)\(r.code == 0 ? "" : ": " + r.err.split(separator: "\n").filter { $0.hasPrefix("doz:") }.joined(separator: " | ")))")
    check(t.waitFor(10) { pids.allSatisfy { kill(pid_t($0), 0) != 0 } }, "every program it held is gone (\(pids.count))")
    check(!FileManager.default.fileExists(atPath: dir), "the socket folder is removed")
    started.removeAll()
}

/// `realpath(3)` (`/tmp` is `/private/tmp`).
private func realPath(_ p: String) -> String {
    guard let r = realpath(p, nil) else { return p }
    defer { free(r) }
    return String(cString: r)
}

/// The parent of `pid` (`ps -o ppid=`).
private func parentPID(_ pid: Int) -> Int? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/ps")
    p.arguments = ["-o", "ppid=", "-p", String(pid)]
    let o = Pipe()
    p.standardOutput = o
    try? p.run()
    p.waitUntilExit()
    return Int(String(decoding: o.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
}
