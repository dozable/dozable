import Darwin
import Foundation
import DozableKit
import DozableHost

// `make test-cli-fence`, a daemon stop and start under running fenced sessions (`FENCE_PART=daemonstop` runs these
// rows alone). Harmless programs only: a shell script that records every hang-up, terminate or interrupt it is sent (it
// traps them and goes on), keeps a slow download open through its proxy while the daemon stops, and asks the fake
// upstream once a second — fenced as itself, fenced as a FAKE `claude` (the agent's path: its config folder, its login's
// placeholder), and unfenced as the control. The real `claude` never runs.

func cliFenceDaemonStopRows(_ t: CLIHarness, root: String, started: inout Set<String>) {
    print("cli: a daemon stop and start under running fenced sessions")
    let base = root + "/dstop"
    func put(_ p: String, _ s: String, mode: mode_t = 0o644) {
        try? FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: p, contents: Data(s.utf8))
        chmod(p, mode)
    }
    func get(_ p: String) -> String { (try? String(contentsOfFile: p, encoding: .utf8)) ?? "" }
    func rows() -> [SessionRow] { t.json(["sessions", "@mac"], [SessionRow].self) ?? [] }
    func row(_ s: String) -> SessionRow? { rows().first { $0.name == s } }
    func alive(_ pid: Int) -> Bool { kill(pid_t(pid), 0) == 0 }
    // The program, Claude Code's own watch over its terminal in small: every hang-up, terminate or interrupt it is sent is
    // written to sig.txt (and it goes on); every second it reads its terminal (an end or an error there is what Claude
    // Code takes for "orphaned" and exits 129 on) and writes to it, and asks the fake upstream (the count and the last
    // answer's code); a 20 s download is open from its start.
    let probe = """
    import os, select, signal, subprocess, sys, time
    def note(what):
        with open('sig.txt', 'a') as f: f.write(what + '\\n')
    for n in ('SIGHUP', 'SIGTERM', 'SIGINT'):
        signal.signal(getattr(signal, n), lambda s, _f, n=n: note(n[3:]))
    open('pid.txt', 'w').write(str(os.getpid()))
    open('env.txt', 'w').write('\\n'.join('%s=%s' % kv for kv in sorted(os.environ.items())))
    dl = subprocess.Popen(['curl', '-s', '-o', '/dev/null', '-m', '60', 'http://stream.doz.test/s'], stderr=subprocess.DEVNULL)
    i = 0
    while True:
        i += 1
        try:
            r, _, _ = select.select([0], [], [], 0)
            if r and os.read(0, 4096) == b'': note('STDIN-EOF')
        except OSError as e: note('STDIN-' + str(e.errno))
        try: os.write(1, b'.')
        except OSError as e: note('STDOUT-' + str(e.errno))
        try: code = subprocess.run(['curl', '-s', '-o', '/dev/null', '-w', '%{http_code}', '-m', '4', 'http://allowed.doz.test/%d' % i],
                                   capture_output=True, text=True).stdout
        except Exception as e: code = 'x'
        open('last.tmp', 'w').write('%d %s' % (i, code)); os.rename('last.tmp', 'last.txt')
        time.sleep(1)

    """
    let sites = "standard,site:allowed.doz.test,site:stream.doz.test"
    var dirs: [String: String] = [:]
    for (s, argv, extra) in [("dsfence", ["/usr/bin/python3", "probe.py"], ["--fenced", "--permissions", sites]),
                             ("dsclaude", [base + "/dsclaude/claude"], ["--fenced", "--permissions", sites]),
                             ("dsenv", ["/usr/bin/env", "CHAT_URL=http://x.example", base + "/dsenv/claude"], ["--fenced", "--permissions", sites]),
                             ("dsplain", ["/usr/bin/python3", "probe.py"], ["--unfenced"])] {
        let d = base + "/" + s
        put(d + "/probe.py", probe)
        // The fake claude (by its path: the agent's recipe is found by the program's name).
        put(d + "/claude", "#!/bin/sh\nexec /usr/bin/python3 probe.py\n", mode: 0o755)
        dirs[s] = MacFencePaths.resolve(d) ?? d
        let r = t.run(["run", "@mac", "-d", "--session", s, "--folder", d] + extra + ["--"] + argv, timeout: 90)
        check(r.code == 0, "D.0 \(s) started (\(r.code)) \(r.err.split(separator: "\n").last ?? "")")
        if r.code == 0 { started.insert(s) }
    }
    func last(_ s: String) -> (n: Int, code: String) {
        let w = get(dirs[s]! + "/last.txt").split(separator: " ").map(String.init)
        return (Int(w.first ?? "") ?? 0, w.count > 1 ? w[1].trimmingCharacters(in: .whitespacesAndNewlines) : "")
    }
    let names = ["dsfence", "dsclaude", "dsenv", "dsplain"]
    func env(_ s: String) -> [String: String] {
        var e: [String: String] = [:]
        for l in get(dirs[s]! + "/env.txt").split(separator: "\n") {
            let kv = l.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { e[kv[0]] = kv[1] }
        }
        return e
    }
    check(t.waitFor(30) { names.allSatisfy { last($0).n >= 2 } }, "D.0 each program runs and asks once a second")
    check(["dsfence", "dsclaude", "dsenv"].allSatisfy { last($0).code == "200" }, "D.0 the fenced ones are answered through their proxies (\(last("dsfence").code), \(last("dsclaude").code), \(last("dsenv").code))")
    // The agent is found through a leading `env NAME=VALUE`; every fenced program gets Claude Code's temp folder.
    for s in ["dsclaude", "dsenv"] {
        check(env(s)["CLAUDE_CONFIG_DIR"]?.hasSuffix("/agent") == true && env(s)["CLAUDE_CODE_OAUTH_TOKEN"] != nil,
              "D.0 \(s): Claude Code's own config folder and its login's placeholder")
    }
    check(env("dsenv")["CHAT_URL"] == "http://x.example", "D.0 dsenv: env's own variable reached the program")
    for s in ["dsfence", "dsclaude", "dsenv"] {
        check(env(s)["CLAUDE_CODE_TMPDIR"].map { $0 == env(s)["TMPDIR"] || $0 + "/" == env(s)["TMPDIR"] } == true,
              "D.0 \(s): CLAUDE_CODE_TMPDIR is its own temp folder (\(env(s)["CLAUDE_CODE_TMPDIR"] ?? "none"))")
    }
    check(env("dsfence")["CLAUDE_CONFIG_DIR"] == nil, "D.0 dsfence: a program that is not the agent gets no agent folder")
    var pids: [String: Int] = [:]
    for s in names { pids[s] = row(s)?.pid }
    check(names.allSatisfy { pids[$0] != nil }, "D.0 their pids (\(pids))")

    // A viewer attached to the agent's session through the daemon (a terminal, a dashboard tab) across the stop.
    let viewer = try? PTYClient(t, ["attach", "@mac", "dsclaude"])
    defer { viewer?.close() }
    check(viewer != nil, "D.0 a viewer attached to dsclaude")
    usleep(1_000_000)
    // The stop, while the downloads are open.
    let stop = t.run(["daemon", "stop"], timeout: 60)
    check(stop.code == 0, "D.1 daemon stop (\(stop.code))")
    usleep(6_000_000)
    for s in names {
        let p = pids[s] ?? -1
        check(p > 0 && alive(p) && row(s)?.ended == false, "D.1 \(s): its program (pid \(p)) still runs with no daemon")
        check(get(dirs[s]! + "/sig.txt").isEmpty, "D.1 \(s): it was sent no hang-up, terminate or interrupt, and its terminal neither ended nor failed (\(get(dirs[s]! + "/sig.txt").split(separator: "\n").joined(separator: ",")))")
    }
    // The next daemon.
    let start = t.run(["daemon", "start"], timeout: 60)
    check(start.code == 0, "D.2 daemon start (\(start.code))")
    let before = (last("dsfence").n, last("dsclaude").n, last("dsenv").n)
    check(t.waitFor(30) { last("dsfence").n > before.0 + 1 && last("dsfence").code == "200" }, "D.2 dsfence: its network works again (\(last("dsfence")))")
    check(t.waitFor(30) { last("dsclaude").n > before.1 + 1 && last("dsclaude").code == "200" }, "D.2 dsclaude: its network works again (\(last("dsclaude")))")
    check(t.waitFor(30) { last("dsenv").n > before.2 + 1 && last("dsenv").code == "200" }, "D.2 dsenv: its network works again (\(last("dsenv")))")
    for s in names {
        let p = pids[s] ?? -1
        check(alive(p) && row(s)?.pid == p && row(s)?.ended == false, "D.2 \(s): the same program (pid \(p)) still runs after the next daemon adopts it")
        check(get(dirs[s]! + "/sig.txt").isEmpty, "D.2 \(s): still no signal (\(get(dirs[s]! + "/sig.txt").split(separator: "\n").joined(separator: ",")))")
    }
    for s in names {
        t.run(["sessions", "end", "@mac", s, "--yes"], timeout: 60)
        started.remove(s)
    }
}
