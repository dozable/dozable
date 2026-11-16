import Darwin
import Foundation
import DozableKit
import DozableHost

// `make test-cli-host` (`doz-vmtest cli-host --doz PATH`): sessions on THIS Mac (`@mac`) through the real signed doz, its
// host and the real `deckhold-mac` — no VM, so a runner without the virtualization entitlement can run it. A store of its
// own (`/tmp/dzo-PID-mh`), so the socket folder is that store's (its hash): it cannot meet a real host's. Only harmless
// programs (`sh`, `sleep`, a fake agent that writes OSC 7501), only in a scratch folder; every process it kills is one it
// started (its own host, its own holders). The doz processes run with CLAUDECODE / CLAUDE_CODE_* set — none may reach a
// session. Since fenced became the default for a new session (683 M6) every open here passes --unfenced: this suite is
// the unfenced session exactly as before the fence (the agent-relay team's shape); the default itself and a session
// keeping its mode across restart and adoption are make test-cli-fence's rows.

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

/// A FAKE claude with the real one's refusals (685 M1): `--session-id` beside `--continue`/`--resume` without
/// `--fork-session` exits 1 with Claude's message; `--resume X` without `X.jsonl` exits 1 "No conversation found with session
/// ID"; `--continue` without a conversation (no `has-conversation` file in its folder) exits 1. Otherwise it records which
/// conversation it holds as Claude does (`<sessions>/<its pid>.json`, unless its folder has `no-pidfile`), writes a
/// transcript for `--session-id X` (it talked), says how it was started and waits. `@PROJECTS@`/`@SESSIONS@`: the suite's
/// scratch folders (never `$HOME`).
private let fakeClaude = #"""
#!/bin/sh
P='@PROJECTS@'; S='@SESSIONS@'
sid=""; res=""; cont=""; fork=""; prev=""
for a in "$@"; do
  case "$prev" in --session-id) sid="$a" ;; --resume|-r) case "$a" in -*) ;; *) res="$a" ;; esac ;; esac
  case "$a" in --continue|-c) cont=1 ;; --fork-session) fork=1 ;; --session-id=*) sid="${a#--session-id=}" ;; --resume=*) res="${a#--resume=}" ;; esac
  prev="$a"
done
if [ -n "$sid" ] && { [ -n "$cont" ] || [ -n "$res" ]; } && [ -z "$fork" ]; then
  echo "Error: --session-id can only be used with --continue or --resume if --fork-session is also specified."; exit 1
fi
folder="$P/$(pwd -P | sed 's/[^A-Za-z0-9]/-/g')"
if [ -n "$res" ] && [ ! -f "$folder/$res.jsonl" ]; then echo "No conversation found with session ID: $res"; exit 1; fi
if [ -n "$cont" ] && [ ! -e has-conversation ]; then echo "No conversation found to continue"; exit 1; fi
id="${sid:-$res}"; [ -n "$id" ] || id="$(/usr/bin/uuidgen | tr 'A-Z' 'a-z')"
if [ ! -e no-pidfile ]; then mkdir -p "$S"; printf '{"pid":%s,"sessionId":"%s","cwd":"%s"}\n' "$$" "$id" "$(pwd -P)" > "$S/$$.json"; fi
if [ -n "$sid" ]; then mkdir -p "$folder"; [ -f "$folder/$sid.jsonl" ] || echo '{}' > "$folder/$sid.jsonl"; fi
echo "fake-claude $*"
exec sleep 600
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
    t.env["DOZ_DAEMON_IDLE"] = "30"
    t.env["DOZ_TEST_CREDENTIALS"] = "memory"
    // The markers a doz started from inside Claude Code carries — none may reach a session on the Mac.
    t.env["CLAUDECODE"] = "1"
    t.env["CLAUDE_CODE_ENTRYPOINT"] = "cli-host-test"
    // The sessions' PATH, instead of the person's login shell (never run by a test): a scratch bin (a FAKE claude) first.
    let fakeBin = root.appendingPathComponent("bin")
    try? FileManager.default.createDirectory(at: fakeBin, withIntermediateDirectories: true)
    // Claude Code's folders, scratch: its projects (the restart's conversation check reads it) and, beside them, which
    // process holds which conversation (685 M1: the seam's sibling).
    let claudeHome = root.appendingPathComponent("claude-home").resolvingSymlinksInPath()
    let projects = claudeHome.appendingPathComponent("projects")
    let claudeSessions = claudeHome.appendingPathComponent("sessions")
    try? FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    try? fakeClaude.replacingOccurrences(of: "@PROJECTS@", with: realPath(projects.path)).replacingOccurrences(of: "@SESSIONS@", with: realPath(claudeHome.path) + "/sessions")
        .write(to: fakeBin.appendingPathComponent("claude"), atomically: true, encoding: .utf8)
    chmod(fakeBin.appendingPathComponent("claude").path, 0o755)
    t.env["DOZ_TEST_MAC_PATH"] = fakeBin.path + ":/usr/bin:/bin:/usr/sbin:/sbin"
    t.env["DOZ_TEST_CLAUDE_PROJECTS"] = projects.path
    let work = root.appendingPathComponent("work").resolvingSymlinksInPath()
    try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let store = DozableStore(root: root)
    let dir = MacPlace.socketDirectory(store: store)
    var started: Set<String> = []
    defer {
        for s in started { t.run(["sessions", "end", "@mac", s, "--yes"], timeout: 30) }
        t.run(["daemon", "stop"], timeout: 60)
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
        let r = t.run(["run", "@mac", "-d", "--unfenced", "--session", s, "--workdir", work.path] + extra + ["--"] + argv, timeout: 60)
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
    check(leaked.isEmpty, "nothing else of the daemon's environment (DOZ_*, XPC_*, __CF*)\(leaked.isEmpty ? "" : ": \(leaked.joined(separator: ", "))")")
    check(env.contains("TERM=xterm-256color") && env.contains("PATH=\(fakeBin.path):/usr/bin:/bin:/usr/sbin:/sbin") && env.contains("HOME="),
          "TERM, the PATH, HOME are set")
    let pwd = file("pwd.txt").trimmingCharacters(in: .whitespacesAndNewlines)
    check(realPath(pwd) == realPath(work.path), "its folder is --workdir (\(pwd))")
    r = t.run(["run", "@mac", "-d", "--unfenced", "--session", "bad", "-e", "CLAUDECODE=1", "--", "/bin/sh", "-c", "true"])
    check(r.code == 64 && r.err.contains("CLAUDECODE"), "-e CLAUDECODE=… is refused, with the reason (\(r.code))")
    r = t.run(["run", "@mac", "-d", "--unfenced", "--session", String(repeating: "x", count: 33), "--", "/bin/sh"])
    check(r.code == 64, "a session name of 33 characters is refused (\(r.code))")
    r = t.run(["run", "@mac", "-d", "--unfenced", "--session", "nope", "--", "no-such-program-here"])
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
        let c = try PTYClient(t, ["run", "@mac", "--unfenced", "--session", "rr", "--workdir", work.path, "--", "/bin/sh", "-c", "echo hello-rr; sleep 600"])
        started.insert("rr")
        defer { c.close() }
        check(c.wait(10) { $0.text.contains("hello-rr") }, "run @mac (no -d) attaches to its new session")
        c.type("\u{1D}\u{1D}")
        check(c.exited(within: 8) == 0, "…and detaches")
    } catch { check(false, "pty: \(error)") }
    // 687: a foreground `doz run` returns its program's exit code — a program that exits at once (before the attach:
    // it used to be refused, exit 2), one that exits later, a signal death (128+N); a detach is 0 (above) and so is -d.
    for (s, cmd, want, what) in [("x0", "exit 0", Int32(0), "exits 0 at once"), ("x3", "exit 3", 3, "exits 3 at once"),
                                 ("x3l", "echo x3l-said; sleep 1; exit 3", 3, "exits 3 a second later"),
                                 ("xk", "sleep 1; kill -KILL $$", 137, "is killed (SIGKILL)")] {
        do {
            let c = try PTYClient(t, ["run", "@mac", "--unfenced", "--session", s, "--workdir", work.path, "--", "/bin/sh", "-c", cmd])
            started.insert(s)
            defer { c.close() }
            let got = c.exited(within: 20)
            check(got == want, "run @mac (attached), a program that \(what): doz run exits \(want) (\(got.map(String.init) ?? "still running"))")
            if s == "x3l" { check(c.text.contains("x3l-said") && c.text.contains("has ended (exit 3)"), "…its output, then the end with its code") }
        } catch { check(false, "pty: \(error)") }
    }
    r = t.run(["run", "@mac", "-d", "--unfenced", "--session", "xd", "--workdir", work.path, "--", "/bin/sh", "-c", "sleep 1; exit 3"], timeout: 60)
    if r.code == 0 { started.insert("xd") }
    check(r.code == 0, "run @mac -d: returns 0 once it started, whatever the program does later (\(r.code))")
    r = t.run(["attach", "@mac", "nope"], timeout: 30)
    check(r.code == 2 && r.err.contains("no session nope on this Mac"), "attach to a session that is not there: exit 2 (\(r.code))")
    let ls = t.run(["ls"]).out
    check(ls.contains("this Mac: ") && ls.contains("(no isolation) — doz sessions @mac"), "doz ls: the one line for this Mac (\(ls.split(separator: "\n").last ?? ""))")

    // A host stop leaves them running; the next host adopts them (same pid, same screen).
    let pidBefore = row("rd")?.pid
    check(pidBefore != nil, "rd has a pid (\(pidBefore.map(String.init) ?? "none"))")
    r = t.run(["daemon", "stop"], timeout: 60)
    check(r.code == 0 && r.out.contains("on this Mac keep running"), "daemon stop: it says the sessions on this Mac keep running")
    check(t.waitFor(10) { !t.hostRunning }, "the daemon is gone")
    check(row("rd")?.pid == pidBefore && row("rd")?.ended == false, "no daemon: sessions @mac still lists rd, same pid (looked at in-process)")
    check(!t.hostRunning, "…and looking started no daemon")
    r = t.run(["sessions", "send", "@mac", "rd", "--text", "again", "--enter"], timeout: 30)
    check(r.code == 0, "a send starts a host, which adopts the session")
    check(screen("rd", until: "got:again").out.contains("got:hi"), "same screen (got:hi still there) and the new line")
    check(row("rd")?.pid == pidBefore, "same pid after the new daemon")
    check(t.waitFor(10) { row("agent")?.status?.state == .done }, "the new daemon watches the agent again: done")

    // kill -9 of the host: the sessions survive.
    if let hp = t.hostPID() {
        kill(hp, SIGKILL)
        check(t.waitFor(10) { kill(hp, 0) != 0 }, "the daemon (pid \(hp)) killed with SIGKILL")
    } else { check(false, "the daemon's pid") }
    check(row("rd")?.pid == pidBefore && row("rd")?.ended == false, "after kill -9 of the daemon, rd still runs (same pid)")

    // end, then restart from the record.
    r = t.run(["sessions", "end", "@mac", "rd", "--yes"], timeout: 30)
    check(r.code == 0 && r.out.contains("ended session rd on this Mac"), "sessions end @mac rd (\(r.out.trimmingCharacters(in: .whitespacesAndNewlines)))")
    check(t.waitFor(5) { row("rd")?.ended == true }, "rd is ended")
    r = t.run(["sessions", "restart", "@mac", "rd", "--yes", "-d"], timeout: 30)
    check(r.code == 0 && r.out.contains("restarted session rd on this Mac"), "sessions restart @mac rd")
    check(t.waitFor(5) { row("rd")?.ended == false && row("rd")?.pid != pidBefore }, "rd runs again, a new program")
    check(row("rd")?.fenced == nil && row("rd")?.fence == nil, "…still unfenced: a restart keeps the mode it was opened with (the default is fenced)")
    check(row("rd")?.command == "/bin/sh -c while read x; do echo got:$x; done", "…the same command")
    check(t.run(["sessions", "send", "@mac", "rd", "--text", "back", "--enter"], timeout: 30).code == 0
          && screen("rd", until: "got:back").out.contains("got:back"), "and it answers")

    // A FAKE claude (exits at once on --continue in a folder without a conversation, as the real one does): restart
    // appends --continue only when Claude Code has a conversation for the folder, else it starts fresh and says so.
    let cw = work.appendingPathComponent("cl")
    try? FileManager.default.createDirectory(at: cw, withIntermediateDirectories: true)
    // These rows are the folder rule alone: this claude records no conversation of its own (no pid file).
    FileManager.default.createFile(atPath: cw.appendingPathComponent("no-pidfile").path, contents: nil)
    r = t.run(["run", "@mac", "-d", "--unfenced", "--session", "cl", "--workdir", cw.path, "--", "claude"], timeout: 60)
    if r.code == 0 { started.insert("cl") }
    check(r.code == 0 && screen("cl", until: "fake-claude").out.contains("fake-claude"), "the fake claude runs on this Mac")
    r = t.run(["sessions", "restart", "@mac", "cl", "--yes", "--json"], timeout: 30)
    var re = try? HostWire.decoder.decode(SessionRestarted.self, from: r.outData)
    check(r.code == 0 && re?.resumed == false && re?.notice?.contains("no earlier conversation") == true,
          "restart with no conversation in the folder: fresh, and it says so (\(re?.notice ?? "no notice"))")
    usleep(1_500_000)
    check(row("cl")?.ended == false && !screen("cl", until: "fake-claude").out.contains("--continue"), "…and the session is still running (no --continue)")
    let conv = projects.appendingPathComponent(MacPlace.claudeProjectFolderName(realPath(cw.path)))
    try? FileManager.default.createDirectory(at: conv, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: conv.appendingPathComponent("c0ffee.jsonl").path, contents: Data("{}\n".utf8))
    FileManager.default.createFile(atPath: cw.appendingPathComponent("has-conversation").path, contents: nil)
    r = t.run(["sessions", "restart", "@mac", "cl", "--yes", "--json"], timeout: 30)
    re = try? HostWire.decoder.decode(SessionRestarted.self, from: r.outData)
    check(r.code == 0 && re?.resumed == true && re?.command == "claude --continue", "with a conversation: claude --continue (\(re?.command ?? "?"))")
    usleep(1_500_000)
    check(row("cl")?.ended == false && screen("cl", until: "--continue").out.contains("fake-claude --continue"), "…and it runs")

    // 685 M1 — the restart resumes the conversation Claude holds, never --continue beside --session-id.
    func claudeRun(_ s: String, _ dir: URL, _ argv: [String]) -> CLIRun {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let r = t.run(["run", "@mac", "-d", "--unfenced", "--session", s, "--workdir", dir.path, "--"] + argv, timeout: 60)
        if r.code == 0 { started.insert(s) }
        return r
    }
    let U = "0f8fad5b-d9cb-469f-a165-70867728950e"
    // (a) the admin shape: claude --session-id U --remote-control admin.
    r = claudeRun("ka", work.appendingPathComponent("ka"), ["claude", "--session-id", U, "--remote-control", "admin"])
    // (the screen is 80 columns: the line wraps — joined again)
    check(r.code == 0 && screen("ka", until: "fake-claude").out.replacingOccurrences(of: "\n", with: "").contains("fake-claude --session-id \(U) --remote-control admin"),
          "a claude --session-id U --remote-control admin session runs")
    r = t.run(["sessions", "restart", "@mac", "ka", "--yes", "--json"], timeout: 30)
    re = try? HostWire.decoder.decode(SessionRestarted.self, from: r.outData)
    check(r.code == 0 && re?.command == "claude --resume \(U) --remote-control admin" && re?.resumedID == U,
          "restart: claude --resume U --remote-control admin — no --continue beside --session-id (\(re?.command ?? r.err))")
    check(screen("ka", until: "--resume").out.replacingOccurrences(of: "\n", with: "").contains("fake-claude --resume \(U) --remote-control admin") && row("ka")?.ended == false,
          "…and it runs (the fake refuses --session-id with --continue, as Claude does)")
    r = t.run(["sessions", "restart", "@mac", "ka", "--yes", "--json"], timeout: 30)
    re = try? HostWire.decoder.decode(SessionRestarted.self, from: r.outData)
    check(r.code == 0 && re?.command == "claude --resume \(U) --remote-control admin", "a second restart: the same conversation again (\(re?.command ?? r.err))")
    // (a2) an id that never talked (no transcript): opened again by its id — --resume would fail "No conversation found".
    let U2 = "7c9e6679-7425-40de-944b-e07fc1f90ae7"
    let kbDir = work.appendingPathComponent("kb")
    r = claudeRun("kb", kbDir, ["claude", "--session-id", U2])
    check(r.code == 0 && screen("kb", until: "fake-claude").out.contains("fake-claude --session-id"), "a claude --session-id U2 session runs")
    try? FileManager.default.removeItem(atPath: projects.path + "/" + MacPlace.claudeProjectFolderName(realPath(kbDir.path)) + "/\(U2).jsonl")
    r = t.run(["sessions", "restart", "@mac", "kb", "--yes", "--json"], timeout: 30)
    re = try? HostWire.decoder.decode(SessionRestarted.self, from: r.outData)
    check(r.code == 0 && re?.command == "claude --session-id \(U2)" && row("kb")?.ended == false,
          "no transcript for its id: claude --session-id U2 again, not --resume (\(re?.command ?? r.err))")
    // (b) started without an id: the id it holds is learned, and a restart resumes IT, not the folder's newest.
    let kcDir = work.appendingPathComponent("kc")
    r = claudeRun("kc", kcDir, ["claude"])
    check(r.code == 0 && screen("kc", until: "fake-claude").out.contains("fake-claude"), "a claude session started without an id")
    let kcFolder = projects.path + "/" + MacPlace.claudeProjectFolderName(realPath(kcDir.path))
    let held = row("kc")?.pid.flatMap { MacPlace.claudeHeldSessionID(sessions: claudeSessions.path, pid: $0) }
    check(held != nil, "…it recorded its conversation (\(held ?? "none"))")
    if let V = held {
        // It talked (a transcript), and a newer conversation exists in the folder too.
        try? FileManager.default.createDirectory(atPath: kcFolder, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: kcFolder + "/\(V).jsonl", contents: Data("{}\n".utf8))
        usleep(50_000)
        FileManager.default.createFile(atPath: kcFolder + "/newer-0000.jsonl", contents: Data("{}\n".utf8))
        FileManager.default.createFile(atPath: kcDir.appendingPathComponent("has-conversation").path, contents: nil)
        r = t.run(["sessions", "restart", "@mac", "kc", "--yes", "--json"], timeout: 30)
        re = try? HostWire.decoder.decode(SessionRestarted.self, from: r.outData)
        check(r.code == 0 && re?.command == "claude --resume \(V)" && re?.resumedID == V,
              "restart: claude --resume V — its own conversation, not --continue (\(re?.command ?? r.err))")
        let recs = (try? Data(contentsOf: root.appendingPathComponent("mac-sessions/sessions.json")))
            .flatMap { try? HostWire.decoder.decode(MacSessionRecords.self, from: $0) }
        check(recs?.sessions["kc"]?.claudeSessionID == V && recs?.sessions["kc"]?.argv == ["claude"],
              "the record keeps the argv as opened and the learned id (\(recs?.sessions["kc"]?.claudeSessionID ?? "none"))")
    }
    // (c) a restart whose program dies at once: an error with ITS last lines, and its screen replaces an older one.
    let bmDir = work.appendingPathComponent("bm")
    try? FileManager.default.createDirectory(at: bmDir, withIntermediateDirectories: true)
    r = t.run(["run", "@mac", "-d", "--unfenced", "--session", "bm", "--workdir", bmDir.path, "--", "/bin/sh", "-c",
               "if [ -e boom ]; then echo BOOM-NEW; echo second-line; exit 3; fi; echo OLD-MARK; sleep 600"], timeout: 60)
    if r.code == 0 { started.insert("bm") }
    check(r.code == 0 && screen("bm", until: "OLD-MARK").out.contains("OLD-MARK"), "bm says OLD-MARK")
    check(t.run(["daemon", "stop"], timeout: 60).code == 0, "daemon stop (bm's screen, OLD-MARK, is saved)")
    FileManager.default.createFile(atPath: bmDir.appendingPathComponent("boom").path, contents: nil)
    r = t.run(["sessions", "restart", "@mac", "bm", "--yes", "-d"], timeout: 30)
    check(r.code != 0 && r.err.contains("exited at once (exit 3)") && r.err.contains("BOOM-NEW") && r.err.contains("second-line"),
          "restart: it exited at once — nonzero (\(r.code)), the exit code and its own last lines (\(r.err.split(separator: "\n").first ?? ""))")
    r = t.run(["sessions", "screen", "@mac", "bm"], timeout: 30)
    check(r.code == 0 && r.out.contains("BOOM-NEW") && !r.out.contains("OLD-MARK") && r.err.contains("ended (exit 3)"),
          "sessions screen @mac bm: the new run's last screen, not the old one (\(r.err.trimmingCharacters(in: .whitespacesAndNewlines)))")
    // (d) a program that ended by itself keeps its last screen — live host, then host-less (read in-process).
    check(run("ed", ["/bin/sh", "-c", "echo ED-LAST-LINE; sleep 1; exit 4"]).code == 0, "a session that ends by itself (exit 4)")
    check(t.waitFor(10) { row("ed")?.ended == true }, "…it ended")
    r = t.run(["sessions", "screen", "@mac", "ed", "--json"], timeout: 30)
    let edLive = try? HostWire.decoder.decode(SessionLive.self, from: r.outData)
    check(r.code == 0 && edLive?.live == false && edLive?.reason == "ended" && edLive?.exitCode == 4 && edLive?.text.contains("ED-LAST-LINE") == true,
          "sessions screen --json: its last screen, reason ended, exit 4 (\(edLive?.reason ?? r.err))")
    check(t.run(["daemon", "stop"], timeout: 60).code == 0 && t.waitFor(10) { !t.hostRunning }, "daemon stop (the last screen is kept as its saved screen)")
    r = t.run(["sessions", "screen", "@mac", "ed"], timeout: 30)
    check(r.code == 0 && r.out.contains("ED-LAST-LINE") && r.err.contains("ended (exit 4)") && !t.hostRunning,
          "no daemon: sessions screen @mac ed still shows its last screen, and looking started no daemon")
    r = t.run(["sessions", "@mac", "--screen", "ed"], timeout: 30)
    check(r.code == 0 && r.out.contains("ED-LAST-LINE"), "sessions @mac --screen ed: the same")

    // A holder killed (as a restart of the Mac would): gone; restart starts it again.
    check(run("gn", ["/bin/sh", "-c", "echo gn-mark; sleep 600"]).code == 0, "a session gn")
    check(screen("gn", until: "gn-mark").out.contains("gn-mark"), "gn says gn-mark")
    check(t.run(["daemon", "stop"], timeout: 60).code == 0, "daemon stop (its screens are saved once more)")
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

    // Row K (695): the login keep-alive, with a FAKE claude only (DOZ_TEST_CLAUDE_BIN — TestSafety stops a guarded run that
    // would run any other) and a scratch credentials file (DOZ_TEST_CLAUDE_CREDENTIALS_FILE). Never the real `claude -p`.
    cliHostKeepaliveRows(t, root: root, run: { run($0, $1, extra: $2) }, row: row)
    started.remove("kahold")                    // it ended it

    // nuke ends them (a fresh install has none) and removes the socket folder.
    let pids = rows().filter { !$0.ended }.compactMap(\.pid)
    r = t.run(["nuke", "--yes"], timeout: 120)
    check(r.code == 0 && r.out.contains("session") && r.out.contains("on this Mac"),
          "nuke --yes: it ends the sessions on this Mac (\(r.code)\(r.code == 0 ? "" : ": " + r.err.split(separator: "\n").filter { $0.hasPrefix("doz:") }.joined(separator: " | ")))")
    check(t.waitFor(10) { pids.allSatisfy { kill(pid_t($0), 0) != 0 } }, "every program it held is gone (\(pids.count))")
    check(!FileManager.default.fileExists(atPath: dir), "the socket folder is removed")
    started.removeAll()
}

/// 695: a FAKE claude for the login keep-alive. `hold`: it waits, as a running Claude Code would (its shell stays, so its
/// command line names it); any other argv is a keep-alive run (1 s long): it records its argv, folder, folder's mode and
/// entries and its environment's NAMES, then — as the real one — renews the scratch credentials file by 8 hours only when its
/// token HAS EXPIRED (exit 0 either way). With the FAIL file it says a token-shaped error on stderr and exits 1; with
/// FAIL.never it never renews. @LOG@, @CREDS@, @FAIL@: the suite's scratch files.
let fakeKeepaliveClaude = #"""
#!/bin/sh
if [ "$1" = hold ]; then sleep 600; exit 0; fi
{
  echo "=== keepalive run"
  echo "begin"
  printf 'argv:'; for a in "$@"; do printf ' [%s]' "$a"; done; echo
  echo "cwd: $(pwd -P)"
  echo "mode: $(/usr/bin/stat -f %Lp .)"
  echo "entries: $(ls -A | wc -l | tr -d ' ')"
  echo "env: $(env | sed 's/=.*//' | sort | tr '\n' ' ')"
} >> '@LOG@'
sleep 1
echo "end" >> '@LOG@'
if [ -e '@FAIL@' ]; then echo "Error: OAuth token refresh failed: sk-ant-ort01-SHOULDNEVERBESTORED0123456789" >&2; exit 1; fi
[ -e '@FAIL@.never' ] && exit 0
# As Claude Code: a token that has not expired is left as it is.
exp=$(grep -o '"expiresAt":[0-9]*' '@CREDS@' | cut -d: -f2)
now=$(( $(date +%s) * 1000 ))
[ -n "$exp" ] && [ "$exp" -gt "$now" ] && exit 0
exp=$(( ($(date +%s) + 28800) * 1000 ))
printf '{"claudeAiOauth":{"accessToken":"sk-ant-oat01-RENEWED-FAKE","refreshToken":"sk-ant-ort01-FAKE-NEVER-READ","expiresAt":%s,"scopes":["user:inference"],"subscriptionType":"max"}}' "$exp" > '@CREDS@.tmp' && mv '@CREDS@.tmp' '@CREDS@'
exit 0
"""#


/// 695: a scratch Claude credentials file expiring `seconds` from now (a made-up access token; the refresh token is never read).
func writeFakeCredentials(_ path: String, expiresIn seconds: Double) {
    let ms = Int64((Date().timeIntervalSince1970 + seconds) * 1000)
    let json = #"{"claudeAiOauth":{"accessToken":"sk-ant-oat01-FAKE-\#(ms)","refreshToken":"sk-ant-ort01-FAKE-NEVER-READ","expiresAt":\#(ms),"scopes":["user:inference"],"subscriptionType":"max"}}"#
    try? json.write(toFile: path + ".tmp", atomically: false, encoding: .utf8)
    rename(path + ".tmp", path)
    chmod(path, 0o600)
}

/// 695: the fake's log — one entry per keep-alive run.
struct FakeKeepaliveLog {
    struct Run { var argv: [String]; var cwd: String; var mode: String; var entries: String; var env: [String] }
    let path: String
    /// Every run ended before the next began (begin/end alternate).
    var sequential: Bool {
        let marks = ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").split(separator: "\n").filter { $0 == "begin" || $0 == "end" }
        return marks.enumerated().allSatisfy { $0.element == ($0.offset % 2 == 0 ? "begin" : "end") }
    }
    var runs: [Run] {
        let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        return text.components(separatedBy: "=== keepalive run\n").dropFirst().map { block in
            var r = Run(argv: [], cwd: "", mode: "", entries: "", env: [])
            for line in block.split(separator: "\n").map(String.init) {
                if line.hasPrefix("argv:") {
                    r.argv = line.dropFirst(5).components(separatedBy: " [").dropFirst().map { $0.hasSuffix("]") ? String($0.dropLast()) : $0 }
                }
                if line.hasPrefix("cwd: ") { r.cwd = String(line.dropFirst(5)) }
                if line.hasPrefix("mode: ") { r.mode = String(line.dropFirst(6)) }
                if line.hasPrefix("entries: ") { r.entries = String(line.dropFirst(9)) }
                if line.hasPrefix("env: ") { r.env = line.dropFirst(5).split(separator: " ").map(String.init) }
            }
            return r
        }
    }
}

/// 695 row K: `doz account keepalive always` with no subscriber renews (one run, the minimal argv, a fresh empty 0700 folder,
/// the env allowlist), `account ls --json` says renewed; a failed run is said by doctor without its token; an UNFENCED
/// Claude Code running is a skip naming its session, and the run follows once it ends; looking needs no daemon.
private func cliHostKeepaliveRows(_ t: CLIHarness, root: URL, run: (String, [String], [String]) -> CLIRun, row: (String) -> SessionRow?) {
    let ka = root.appendingPathComponent("keepalive-test")
    try? FileManager.default.createDirectory(at: ka, withIntermediateDirectories: true)
    let bin = ka.appendingPathComponent("claude-ka-fake").path, log = ka.appendingPathComponent("runs.log").path
    let creds = ka.appendingPathComponent("credentials.json").path, failFile = ka.appendingPathComponent("FAIL").path
    try? fakeKeepaliveClaude.replacingOccurrences(of: "@LOG@", with: log).replacingOccurrences(of: "@CREDS@", with: creds)
        .replacingOccurrences(of: "@FAIL@", with: failFile).write(toFile: bin, atomically: true, encoding: .utf8)
    chmod(bin, 0o755)
    let runs = FakeKeepaliveLog(path: log)
    t.run(["daemon", "stop"], timeout: 60)
    t.env["DOZ_TEST_CLAUDE_BIN"] = bin
    t.env["DOZ_TEST_CLAUDE_CREDENTIALS_FILE"] = creds
    t.env["DOZ_TEST_LOGIN_WATCH_SECONDS"] = "1"
    t.env["DOZ_TEST_KEEPALIVE_SCHEDULE"] = "0,3,6"          // the retries in seconds (a person's: 1, 5, 15 min, then 30)
    defer {
        t.run(["account", "keepalive", "off"], timeout: 30)
        t.run(["daemon", "stop"], timeout: 60)
        for k in ["DOZ_TEST_CLAUDE_BIN", "DOZ_TEST_CLAUDE_CREDENTIALS_FILE", "DOZ_TEST_LOGIN_WATCH_SECONDS", "DOZ_TEST_KEEPALIVE_SCHEDULE"] { t.env[k] = nil }
    }
    func keepalive() -> KeepaliveStatus? { t.json(["account", "ls"], [AccountRow].self)?.first { $0.name == "mac" }?.keepalive }
    func waitOutcome(_ o: String, _ more: (KeepaliveStatus) -> Bool = { _ in true }) -> KeepaliveStatus? {
        var k: KeepaliveStatus?
        _ = t.waitFor(25) { k = keepalive(); return k?.outcome == o && more(k!) }
        return k
    }
    // (1) Claude Code renews only an expired token: nothing runs before the expiry.
    writeFakeCredentials(creds, expiresIn: 8)
    var r = t.run(["account", "keepalive", "always"], timeout: 60)
    check(r.code == 0 && r.out.contains("keep-alive always"), "K: doz account keepalive always (\(r.code)\(r.code == 0 ? "" : ": " + r.err))")
    usleep(3_000_000)
    var k = keepalive()
    check(runs.runs.isEmpty && k?.outcome == nil && k?.nextTryAt != nil,
          "K: no run before the expiry — next try at the expiry (\(runs.runs.count) runs, next \(k?.nextTryAt.map { "\($0)" } ?? "none"))")
    // (2) At the expiry: one run, renewed.
    k = waitOutcome("renewed")
    check(k?.mode == "always" && k?.outcome == "renewed" && (k?.renewedUntil ?? .distantPast) > Date().addingTimeInterval(7 * 3600),
          "K: no sandbox, nothing subscribed — renewed near expiry (account ls --json: \(k?.outcome ?? "none"))")
    let first = runs.runs
    check(first.count == 1, "K: exactly one run for that expiry (\(first.count))")
    if let f = first.first {
        check(f.argv == ["-p", "ok", "--model", "haiku", "--max-turns", "1", "--no-session-persistence", "--tools", "", "--strict-mcp-config",
                         "--settings", #"{"disableAllHooks":true}"#], "K: the fixed argv (\(f.argv))")
        check(f.cwd == realPath(root.path) + "/keepalive/run" && f.mode == "700" && f.entries == "0",
              "K: a fresh, empty 0700 folder in the store (\(f.cwd), \(f.mode), \(f.entries) entries)")
        let shell: Set<String> = ["PWD", "SHLVL", "_", "OLDPWD"]
        let allowed: Set<String> = ["PATH", "HOME", "USER", "LOGNAME", "LANG", "TMPDIR", "SHELL", "CLAUDE_CONFIG_DIR"]
        let extra = Set(f.env).subtracting(shell).subtracting(allowed)
        check(extra.isEmpty, "K: only the env allowlist reaches the run (no CLAUDECODE, CLAUDE_CODE_*, ANTHROPIC_*, DOZ_*: \(extra.sorted()))")
    }
    r = t.run(["account", "ls"], timeout: 30)
    check(r.out.contains("keep-alive always · last renewed") && r.out.contains("next try"), "K: account ls says it (\(r.out.split(separator: "\n").last ?? ""))")
    r = t.run(["daemon", "status"], timeout: 30)
    check(r.out.contains("Claude login keep-alive always · last renewed"), "K: daemon status says it")
    let recordPath = root.appendingPathComponent("keepalive.json").path
    let recMode = ((try? FileManager.default.attributesOfItem(atPath: recordPath))?[.posixPermissions] as? NSNumber)?.intValue
    check(recMode == 0o600, "K: keepalive.json is 0600 (\(recMode.map { String($0, radix: 8) } ?? "none"))")

    // A failed run: its exit and Claude's last line, never a token — in the record, doctor and the daemon's log.
    FileManager.default.createFile(atPath: failFile, contents: nil)
    writeFakeCredentials(creds, expiresIn: 2)
    k = waitOutcome("failed")
    check(k?.exit == 1 && k?.reason?.contains("exit 1: Error: OAuth token refresh failed: …") == true, "K: a failed run is recorded (\(k?.reason ?? "none"))")
    r = t.run(["doctor", "--json"], timeout: 60)
    let drow = (try? JSONSerialization.jsonObject(with: r.outData) as? [[String: Any]])?.first { $0["check"] as? String == "Claude login keep-alive" }
    check(drow?["status"] as? String == "warn" && (drow?["detail"] as? String)?.contains("FAILED (exit 1:") == true,
          "K: doctor warns with the failure (\(drow?["detail"] as? String ?? "no row"))")
    let everywhere = [r.out, (try? String(contentsOfFile: recordPath, encoding: .utf8)) ?? "",
                      (try? String(contentsOf: root.appendingPathComponent("daemon.log"), encoding: .utf8)) ?? "",
                      t.run(["account", "ls", "--json"], timeout: 30).out]
    check(!everywhere.contains { $0.contains("SHOULDNEVERBESTORED") || $0.contains("FAKE-NEVER-READ") || $0.contains("sk-ant-oat01") },
          "K: no token in doctor, keepalive.json, the daemon's log or account ls --json")
    try? FileManager.default.removeItem(atPath: failFile)

    // (3) A Claude Code that leaves the login as it is: `unchanged`, retried on the schedule (here 0, 3, 6 s after the expiry),
    // then `failed` after the last; (4) the record's next try is the retry. Never two runs at once.
    FileManager.default.createFile(atPath: failFile + ".never", contents: nil)
    let neverFrom = runs.runs.count
    let expiryMs = Int64((Date().timeIntervalSince1970 + 2) * 1000)
    writeFakeCredentials(creds, expiresIn: 2)
    k = waitOutcome("unchanged")
    let wantNext = Date(timeIntervalSince1970: Double(expiryMs) / 1000 + 3)
    check(k?.reason?.contains("Claude Code did not renew the login (the token had not expired yet)") == true
          && k.flatMap { $0.nextTryAt }.map { abs($0.timeIntervalSince(wantNext)) < 1.5 } == true,
          "K: unchanged — said, and the next try is the retry 3 s after the expiry (\(k?.nextTryAt.map { "\($0)" } ?? "none"))")
    k = waitOutcome("failed")
    check(k?.reason?.contains("gave up after 3 tries") == true && runs.runs.count == neverFrom + 3,
          "K: after the last retry: failed (\(runs.runs.count - neverFrom) runs: \(k?.reason ?? "none"))")
    check(runs.sequential, "K: never two runs at once")
    try? FileManager.default.removeItem(atPath: failFile + ".never")

    // An UNFENCED Claude Code running holds its own copy: skipped, naming it; the run follows once it ends.
    let rr = run("kahold", [bin, "hold"], [])
    check(rr.code == 0 && t.waitFor(10) { row("kahold")?.pid != nil }, "K: an unfenced (fake) Claude Code running in session kahold")
    let holderPid = row("kahold")?.pid ?? -1
    let before = runs.runs.count
    writeFakeCredentials(creds, expiresIn: 2)
    k = waitOutcome("skipped") { $0.reason?.contains("session kahold on this Mac") == true }
    check(k?.reason?.contains("Claude Code (pid \(holderPid), session kahold on this Mac) holds its own copy of this Mac's login") == true,
          "K: skipped, naming its pid and session (\(k?.reason ?? "none"))")
    check(runs.runs.count == before, "K: …and nothing ran")
    t.run(["sessions", "end", "@mac", "kahold", "--yes"], timeout: 30)
    k = waitOutcome("renewed")
    check(k?.outcome == "renewed" && runs.runs.count == before + 1, "K: once it ended, the next look renewed (a skip never used up the expiry)")

    // Looking needs no daemon: the record, from the store.
    t.run(["daemon", "stop"], timeout: 60)
    r = t.run(["account", "ls"], timeout: 30)
    check(r.out.contains("keep-alive always · last renewed") && !t.hostRunning, "K: account ls with no daemon reads the record (and starts none)")
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
