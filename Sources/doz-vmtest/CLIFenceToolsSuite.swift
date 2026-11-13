import Darwin
import Foundation
import DozableKit
import DozableHost

// `make test-cli-fence`, the tools part: git and ssh through the proxy (`doz fence-connect`), GitHub as the person
// (`--github read|push`), the filtered SSH agent (`--ssh-agent`), worktrees and submodules, signed commits, SwiftPM and
// Xcode (`--xcode`, `--simulator`), the capabilities. Through SEAMS only — never the person's GitHub, gh login, ssh keys,
// ssh-agent, git identity, Xcode preferences or the real internet (but in the opt-in `FENCE_NET=1` rows: public sites, no
// credentials):
//   - a FAKE GitHub (the GitHub suite's python3 `git http-backend` over TLS with its own throwaway CA; the proxy's GitHub
//     upstream seam `DOZ_TEST_GITHUB_UPSTREAM` + `_CA`), a FAKE gh for the token (`DOZ_TEST_GH`);
//   - a THROWAWAY ssh-agent with a throwaway key (`DOZ_TEST_SSH_AUTH_SOCK`; the suite's own `SSH_AUTH_SOCK` is removed);
//   - a non-root `/usr/sbin/sshd` on 127.0.0.1 with a throwaway host key, only that key authorised, its shell's own dot
//     files a scratch folder (`SetEnv ZDOTDIR`) — reached as `ssh.doz.test:22` through the fence seam.
// Row numbers are the plan's test table (M4).

/// A command on this Mac outside every fence (no shell unless asked), its exit code and output — never the person's agent.
@discardableResult
private func outside(_ argv: [String], env: [String: String] = [:], cwd: String? = nil) -> (code: Int32, out: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: argv[0])
    p.arguments = Array(argv.dropFirst())
    var e = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "LANG": "C"]
    for (k, v) in env { e[k] = v }
    p.environment = e
    if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
    let o = Pipe()
    p.standardOutput = o
    p.standardError = o
    p.standardInput = FileHandle.nullDevice
    do { try p.run() } catch { return (-1, "\(error)") }
    let data = o.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

func cliFenceToolsChecks(_ t: CLIHarness, root: String, home: String, store: String, started: inout Set<String>) async {
    print("cli: a fenced session's tools — git/ssh through the proxy, GitHub as you, the SSH agent, worktrees, submodules, Xcode")
    let fm = FileManager.default
    let base = (MacFencePaths.resolve(root) ?? root) + "/tools"
    let ws = base + "/seams"
    try? fm.createDirectory(atPath: ws, withIntermediateDirectories: true)
    func put(_ p: String, _ s: String, mode: mode_t = 0o644) {
        try? fm.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        fm.createFile(atPath: p, contents: Data(s.utf8))
        chmod(p, mode)
    }
    func get(_ p: String) -> String { (try? String(contentsOfFile: p, encoding: .utf8)) ?? "" }
    func folder(_ n: String) -> String {
        let d = base + "/" + n
        try? fm.createDirectory(atPath: d, withIntermediateDirectories: true)
        return d
    }
    func rows() -> [SessionRow] { t.json(["sessions", "@mac"], [SessionRow].self) ?? [] }
    func row(_ s: String) -> SessionRow? { rows().first { $0.name == s } }
    func run(_ s: String, _ wd: String, _ extra: [String], _ script: String) -> CLIRun {
        let r = t.run(["run", "@mac", "-d", "--fenced", "--session", s, "--workdir", wd] + extra + ["--", "/bin/sh", script], timeout: 90)
        if r.code == 0 { started.insert(s) }
        return r
    }
    @discardableResult func end(_ s: String) -> CLIRun {
        let r = t.run(["sessions", "end", "@mac", s, "--yes"], timeout: 60)
        started.remove(s)
        return r
    }
    // Every script's helpers: o NAME CMD… → its exit code in res/NAME and its output in res/NAME.out.
    let helpers = """
    R="$PWD/res"; mkdir -p "$R"
    o() { n=$1; shift; ( "$@" ) > "$R/$n.out" 2>&1; echo $? > "$R/$n"; }

    """
    func res(_ wd: String, _ n: String) -> Int? { Int(get(wd + "/res/" + n).trimmingCharacters(in: .whitespacesAndNewlines)) }
    func out(_ wd: String, _ n: String) -> String { get(wd + "/res/" + n + ".out") }
    func done(_ wd: String, _ s: String) -> Bool { t.waitFor(120) { fm.fileExists(atPath: wd + "/res/DONE") || row(s)?.ended == true } }

    // ── The seams (all scratch) ───────────────────────────────────────────────────────────────────
    let pid = getpid()
    let token = "ghp_FAKEfenceM4SEAM\(pid)aBcDeF0123456789"            // the "person's" token — fake, never in a session
    try? (token + "\n").write(toFile: ws + "/tokens", atomically: true, encoding: .utf8)
    put(ws + "/gh", "#!/bin/sh\n[ \"$1 $2\" = 'auth token' ] && { echo \(token); exit 0; }\nexit 1\n", mode: 0o755)
    put(ws + "/server.py", fakeGitHubServer)
    put(ws + "/ca.ext", "basicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\n")
    put(ws + "/leaf.ext", "subjectAltName=DNS:github.com,DNS:api.github.com,DNS:uploads.github.com,DNS:codeload.github.com\nextendedKeyUsage=serverAuth\nbasicConstraints=CA:FALSE\n")
    var m = outside(["/bin/sh", "-c", """
        set -e
        openssl req -new -newkey rsa:2048 -nodes -keyout ca.key -out ca.csr -subj '/CN=Dozable test GitHub CA' 2>&1
        openssl x509 -req -in ca.csr -signkey ca.key -out ca.pem -days 2 -extfile ca.ext 2>&1
        openssl req -new -newkey rsa:2048 -nodes -keyout leaf.key -out leaf.csr -subj '/CN=github.com' 2>&1
        openssl x509 -req -in leaf.csr -CA ca.pem -CAkey ca.key -CAcreateserial -out leaf.pem -days 2 -extfile leaf.ext 2>&1
        mkdir -p repos/o && git init -q --bare -b main repos/o/r.git
        git init -q -b main seed && cd seed && echo 'hello from the fake GitHub' > README.md && git add README.md
        git -c user.name=Seed -c user.email=seed@example.invalid commit -q -m seed && git push -q ../repos/o/r.git main
        """], env: ["HOME": ws], cwd: ws)
    check(m.code == 0, "a throwaway CA, a fake GitHub's certificate and a bare repository o/r.git (\(m.code)) \(m.code == 0 ? "" : String(m.out.suffix(300)))")
    let srv = Process()
    srv.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    srv.arguments = [ws + "/server.py", ws + "/repos", ws + "/leaf.pem", ws + "/leaf.key", ws + "/requests.log", ws + "/tokens", ws + "/port"]
    srv.environment = ["PATH": "/usr/bin:/bin", "HOME": ws]
    srv.standardOutput = FileHandle.nullDevice
    srv.standardError = FileHandle.nullDevice
    try? srv.run()
    var ghPort = ""
    for _ in 0..<50 where ghPort.isEmpty { usleep(100_000); ghPort = get(ws + "/port") }
    check(!ghPort.isEmpty, "the fake GitHub listens on 127.0.0.1:\(ghPort) (TLS, its own CA)")
    func requests() -> String { get(ws + "/requests.log") }
    // The throwaway ssh-agent and key; a second key that is never added.
    let agentSock = ws + "/agent.sock"
    var agentPID: pid_t = 0
    m = outside(["/usr/bin/ssh-agent", "-a", agentSock])
    if let r = m.out.range(of: #"SSH_AGENT_PID=(\d+)"#, options: .regularExpression) {
        agentPID = pid_t(m.out[r].dropFirst("SSH_AGENT_PID=".count).prefix { $0.isNumber }) ?? 0
    }
    outside(["/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "doz-fence-test@example.invalid", "-f", ws + "/id_test"])
    outside(["/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "never-added@example.invalid", "-f", ws + "/id_other"])
    m = outside(["/usr/bin/ssh-add", ws + "/id_test"], env: ["SSH_AUTH_SOCK": agentSock])
    check(m.code == 0 && agentPID > 0, "a throwaway ssh-agent with a throwaway key")
    // A non-root sshd: a throwaway host key, only the throwaway key authorised, a scratch ZDOTDIR for its shell.
    outside(["/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", ws + "/hostkey"])
    try? fm.copyItem(atPath: ws + "/id_test.pub", toPath: ws + "/authorized_keys")
    try? fm.createDirectory(atPath: ws + "/zdot", withIntermediateDirectories: true)
    let sshPort = 45_000 + Int(pid % 1000)
    put(ws + "/sshd_config", """
    Port \(sshPort)
    ListenAddress 127.0.0.1
    HostKey \(ws)/hostkey
    PidFile \(ws)/sshd.pid
    AuthorizedKeysFile \(ws)/authorized_keys
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    UsePAM no
    StrictModes no
    SetEnv ZDOTDIR=\(ws)/zdot
    """)
    let sshd = Process()
    sshd.executableURL = URL(fileURLWithPath: "/usr/sbin/sshd")
    sshd.arguments = ["-D", "-e", "-f", ws + "/sshd_config"]
    sshd.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
    sshd.standardOutput = FileHandle.nullDevice
    sshd.standardError = FileHandle(forWritingAtPath: "/dev/null")
    try? sshd.run()
    m = outside(["/bin/sh", "-c", "git init -q --bare -b main srv.git && git init -q -b main s0 && cd s0 && echo ssh-seed > S && git add S && git -c user.name=S -c user.email=s@example.invalid commit -q -m s && git push -q ../srv.git main"], cwd: ws)
    check(m.code == 0 && sshd.isRunning, "a scratch sshd on 127.0.0.1:\(sshPort) (throwaway keys) and a bare repository over ssh")
    let hostKeyLine = get(ws + "/hostkey.pub").split(separator: " ").prefix(2).joined(separator: " ")
    defer {
        srv.terminate()
        sshd.terminate()
        if agentPID > 0 { kill(agentPID, SIGTERM) }
    }

    // The host again, with these seams (a host reads them at its start).
    t.run(["host", "stop"], timeout: 60)
    let savedSSH = t.env["SSH_AUTH_SOCK"], savedUp = t.env["DOZ_TEST_FENCE_UPSTREAMS"]
    t.env["SSH_AUTH_SOCK"] = nil
    t.env["DOZ_TEST_GH"] = ws + "/gh"
    t.env["DOZ_TEST_GITHUB_UPSTREAM"] = "127.0.0.1:\(ghPort)"
    t.env["DOZ_TEST_GITHUB_CA"] = ws + "/ca.pem"
    t.env["DOZ_TEST_SSH_AUTH_SOCK"] = agentSock
    t.env["DOZ_TEST_FENCE_UPSTREAMS"] = (savedUp.map { $0 + "," } ?? "") + "ssh.doz.test=127.0.0.1:\(sshPort)"
    defer {
        t.run(["host", "stop"], timeout: 60)
        for k in ["DOZ_TEST_GH", "DOZ_TEST_GITHUB_UPSTREAM", "DOZ_TEST_GITHUB_CA", "DOZ_TEST_SSH_AUTH_SOCK"] { t.env[k] = nil }
        t.env["SSH_AUTH_SOCK"] = savedSSH
        t.env["DOZ_TEST_FENCE_UPSTREAMS"] = savedUp
    }

    // MARK: capabilities and --dry-run (one source)
    var r = t.run(["run", "@mac", "--dry-run", "--fenced", "--xcode", "--github", "read", "--ssh-agent", "--", "/bin/sh"])
    check(r.code == 0 && r.out.contains("fenced (Xcode)") && r.out.contains("GitHub as you") && r.out.contains("pushes are refused") && r.out.contains("on (list + sign only)"),
          "--dry-run: fenced (Xcode), GitHub read, SSH agent on (\(r.out.prefix(120)))")
    r = t.run(["run", "@mac", "--dry-run", "--fenced", "--simulator", "--github", "push", "--", "/bin/sh"])
    check(r.code == 0 && r.out.contains("guard rail (Simulator)") && r.out.contains("a guard rail, not a boundary") && r.out.contains("pushes as you"),
          "--dry-run --simulator: labelled a guard rail; GitHub push")
    r = t.run(["run", "@mac", "-d", "--unfenced", "--github", "read", "--session", "x", "--", "/bin/sh"])
    check(r.code == 64, "--github with --unfenced is refused (\(r.code))")
    r = t.run(["run", "@mac", "-d", "--fenced", "--github", "write", "--session", "x", "--", "/bin/sh"])
    check(r.code == 64, "--github write: refused (off, read or push) (\(r.code))")

    // MARK: 4.2a GitHub as you — read
    let gr = folder("gr")
    put(gr + "/s.sh", helpers + """
    env > res/env
    o clone git clone -q https://github.com/o/r.git c1
    cd c1
    o ident git log -1 --format=%an
    git checkout -q -b feat && echo x > f && git add f && git -c user.name=T -c user.email=t@example.invalid commit -q -m x
    o push git push -u origin feat
    cd ..
    o remoteadd git -C c1 remote add up https://github.com/o/r.git
    o track git -C c1 branch -q --set-upstream-to=origin/main feat
    o ghuser /opt/homebrew/bin/gh api user
    o ghpost /opt/homebrew/bin/gh api -X POST repos/o/r/issues -f title=x
    o ghtoken /bin/sh -c 'printf "protocol=https\\nhost=github.com\\n" | git credential fill'
    o fc "\(MacFencePaths.resolve(t.binary) ?? t.binary)" fence-connect denied.doz.test 22
    echo done > res/DONE
    while [ ! -e go ]; do sleep 0.2; done
    o after /opt/homebrew/bin/gh api user
    echo done > res/AGAIN
    sleep 600
    """)
    r = run("gr", gr, ["--github", "read"], "s.sh")
    check(r.code == 0 && r.err.contains("GitHub as you (read-only)"), "run @mac --fenced --github read (\(r.code)) — the line says it")
    if done(gr, "gr") {
        let env = get(gr + "/res/env")
        let ph = env.split(separator: "\n").first { $0.hasPrefix("GH_TOKEN=") }.map { String($0.dropFirst(9)) } ?? ""
        check(ph.hasPrefix("doz_cred_") && !env.contains(token), "4.2a the program has a placeholder in GH_TOKEN (doz_cred_…), never the token")
        check(res(gr, "clone") == 0 && fm.fileExists(atPath: gr + "/c1/README.md"), "4.2a --github read: git clone over https through the proxy (\(out(gr, "clone").prefix(200)))")
        check(requests().contains(token) && requests().contains("git-upload-pack"), "4.2a …the fake GitHub saw the person's token swapped in (Basic), never a placeholder")
        check(!requests().contains("doz_cred_"), "4.2a …and never the placeholder")
        check(res(gr, "push").map { $0 != 0 } == true && out(gr, "push").contains("read-only"), "4.2a --github read: a push is refused by the proxy, saying why (\(out(gr, "push").suffix(200)))")
        // git's first try carries no credential (the fake answers 401); the one with the person's token is refused here.
        check(!requests().split(separator: "\n").contains { $0.contains("receive-pack") && $0.contains(token) }, "4.2a …no push with the person's login reached GitHub")
        check(res(gr, "remoteadd") == 0 && res(gr, "track") == 0 && row("gr")?.fence?.stoppedForGit == nil, "4.1/4.2 remote add and --set-upstream-to (allowlisted keys): the session is not stopped")
        check(res(gr, "ghuser") == 0 && out(gr, "ghuser").contains("fake-user"), "4.2a gh api user through its door into the proxy (\(out(gr, "ghuser").prefix(160)))")
        check(res(gr, "ghpost").map { $0 != 0 } == true && !requests().contains("/repos/o/r/issues"), "4.2a --github read: gh api POST is refused (never reached GitHub)")
        check(out(gr, "ghtoken").contains("password=doz_cred_") && !out(gr, "ghtoken").contains(token), "4.2a git's helper answers the placeholder")
        check(res(gr, "fc") == 1 && out(gr, "fc").contains("refused by this session's proxy"), "4.7 doz fence-connect to a host the permissions do not allow: refused, saying why (\(out(gr, "fc").prefix(160)))")
        let caps = row("gr")?.capabilities ?? []
        check(caps.first { $0.id == "github" }?.state == "read" && row("gr")?.fence?.github == "read", "capabilities and --json: GitHub as you read")
        // Live down: taking github:as-you away turns it off at once.
        r = t.run(["net", "deny", "@mac", "--session", "gr", "github:as-you"])
        check(r.code == 0, "doz net deny @mac --session gr github:as-you (\(r.err.prefix(160)))")
        let before = requests().components(separatedBy: token).count
        put(gr + "/go", "")
        if t.waitFor(30, { fm.fileExists(atPath: gr + "/res/AGAIN") }) {
            check(res(gr, "after").map { $0 != 0 } == true && requests().components(separatedBy: token).count == before,
                  "GitHub as you follows the policy down live: gh api user refused, the token never sent (\(out(gr, "after").prefix(160)))")
        } else { check(false, "the second gh api user") }
    }
    end("gr")

    // MARK: 4.2a GitHub as you — push (and no --github)
    let gp = folder("gp")
    put(gp + "/s.sh", helpers + """
    o clone git clone -q https://github.com/o/r.git c1
    cd c1 && git checkout -q -b pushed && echo y > g && git add g && git -c user.name=T -c user.email=t@example.invalid commit -q -m y
    o push git push -u origin pushed
    o upstream git config branch.pushed.remote
    cd ..
    echo done > res/DONE
    sleep 600
    """)
    r = run("gp", gp, ["--github", "push"], "s.sh")
    check(r.code == 0, "run @mac --fenced --github push")
    if done(gp, "gp") {
        check(res(gp, "push") == 0, "4.2a --github push: git push -u through the proxy (\(out(gp, "push").suffix(200)))")
        check(outside(["/usr/bin/git", "--git-dir", ws + "/repos/o/r.git", "rev-parse", "--verify", "pushed"]).code == 0, "4.2a …the branch is on the fake GitHub")
        check(out(gp, "upstream").contains("origin") && row("gp")?.fence?.stoppedForGit == nil, "4.1 push -u wrote branch.pushed.* (allowlisted): not stopped")
    }
    end("gp")
    let gn = folder("gn")
    put(gn + "/s.sh", helpers + """
    env > res/env
    o fill /bin/sh -c 'printf "protocol=https\\nhost=github.com\\n" | git credential fill'
    o agent ssh-add -l
    echo done > res/DONE
    sleep 600
    """)
    r = run("gn", gn, ["--permissions", "locked"], "s.sh")
    if r.code == 0, done(gn, "gn") {
        check(res(gn, "fill").map { $0 != 0 } == true && out(gn, "fill").contains("--github push"), "4.2a without --github: git gets no credential for github.com, and is told how (\(out(gn, "fill").prefix(200)))")
        check(!get(gn + "/res/env").contains("GH_TOKEN") && !get(gn + "/res/env").contains("SSH_AUTH_SOCK"), "without --github / --ssh-agent: no GH_TOKEN, no SSH_AUTH_SOCK")
        check(res(gn, "agent").map { $0 != 0 } == true, "4.8 without --ssh-agent: no agent")
    } else { check(false, "the session without --github (\(r.err.prefix(160)))") }
    end("gn")

    // MARK: 4.6–4.8 ssh through fence-connect, the filtered agent, signed commits
    let ss = folder("ss")
    try? fm.copyItem(atPath: ws + "/id_other", toPath: ss + "/id_other")
    try? fm.copyItem(atPath: ws + "/id_test.pub", toPath: ss + "/id_test.pub")
    put(ss + "/s.sh", helpers + """
    env > res/env
    o list ssh-add -l
    o add ssh-add id_other
    o delete ssh-add -D
    o list2 ssh-add -l
    o clone git clone -q ssh://ssh.doz.test\(ws)/srv.git sc
    o shim ssh -o BatchMode=yes ssh.doz.test true
    git init -q sig && cd sig
    o sshsign git -c user.name=T -c user.email=t@example.invalid -c gpg.format=ssh -c user.signingKey="key::$(cat ../id_test.pub)" commit -q -S --allow-empty -m signed
    git cat-file -p HEAD > "$R/sigobj"
    o gpgsign git -c user.name=T -c user.email=t@example.invalid commit -q -S --allow-empty -m gpg
    cd ..
    echo done > res/DONE
    sleep 600
    """)
    let personKnown = get(home + "/.ssh/known_hosts")
    r = run("ss", ss, ["--ssh-agent", "--permissions", "standard,site:ssh.doz.test"], "s.sh")
    check(r.code == 0 && r.err.contains("your SSH agent (list + sign only)"), "run @mac --fenced --ssh-agent (\(r.code))")
    if done(ss, "ss") {
        let env = get(ss + "/res/env")
        let sock = env.split(separator: "\n").first { $0.hasPrefix("SSH_AUTH_SOCK=") }.map { String($0.dropFirst(14)) } ?? ""
        check(sock.hasSuffix("/ss.agent") && !sock.contains(agentSock), "4.8 SSH_AUTH_SOCK is the session's own relay (\(DisplayPath.tilde(sock))), never the agent's own socket")
        check(res(ss, "list") == 0 && out(ss, "list").contains("doz-fence-test@example.invalid"), "4.8 --ssh-agent: ssh-add -l lists the key through the relay")
        check(res(ss, "add").map { $0 != 0 } == true && res(ss, "delete").map { $0 != 0 } == true && out(ss, "list2").contains("doz-fence-test"),
              "4.8 …adding and removing keys are refused; the key is still there")
        check(!outside(["/usr/bin/ssh-add", "-l"], env: ["SSH_AUTH_SOCK": agentSock]).out.contains("never-added"), "4.8 …nothing was added to the agent")
        check(res(ss, "clone") == 0 && fm.fileExists(atPath: ss + "/sc/S"), "4.7 git clone over ssh through doz fence-connect (\(out(ss, "clone").suffix(200)))")
        let folderSSH = (row("ss")?.fence?.sessionFolder ?? "/nonexistent") + "/ssh/known_hosts"
        check(get(folderSSH).contains("ssh.doz.test") && get(folderSSH).contains(hostKeyLine), "4.7 the new host key is in the session's own known_hosts")
        check(get(home + "/.ssh/known_hosts") == personKnown, "4.7 …never in the person's")
        check(res(ss, "shim") == 0, "4.7 plain ssh (the session's shim) goes through the proxy too (\(out(ss, "shim").suffix(160)))")
        check(res(ss, "sshsign") == 0 && get(ss + "/res/sigobj").contains("BEGIN SSH SIGNATURE"), "4.6 an ssh-signed commit with the agent's key (\(out(ss, "sshsign").suffix(160)))")
        check(res(ss, "gpgsign").map { $0 != 0 } == true, "4.6 a gpg-signed commit fails (gpg's home is closed) (\(out(ss, "gpgsign").suffix(120)))")
        check(row("ss")?.capabilities?.first { $0.id == "ssh-agent" }?.state == "on (list + sign only)", "capabilities: SSH agent on (list + sign only)")
    }
    end("ss")
    check(!fm.fileExists(atPath: MacPlace.socketDirectory(store: DozableStore(root: URL(fileURLWithPath: store))) + "/ss.agent"), "4.8 the relay's socket is gone with the session")

    // MARK: 4.3 a worktree of an unfenced repository
    let main = folder("main"), wt = base + "/wt"
    m = outside(["/bin/sh", "-c", "git init -q -b main . && echo m > M && git add M && git -c user.name=M -c user.email=m@example.invalid commit -q -m m && git worktree add -q -b wtb \(wt)"], cwd: main)
    check(m.code == 0, "an unfenced repository and a worktree of it (\(m.out.prefix(160)))")
    put(wt + "/s.sh", helpers + """
    o commit sh -c 'echo w > W && git add W && git -c user.name=T -c user.email=t@example.invalid commit -q -m w'
    o mainwrite sh -c 'echo x > \(main)/M'
    o mainread cat \(main)/M
    o mainhook sh -c 'echo x > \(main)/.git/hooks/pre-commit'
    echo done > res/DONE
    while [ ! -e go ]; do sleep 0.2; done
    git config core.fsmonitor TWINFSMON
    sleep 600
    """)
    r = run("wt", wt, [], "s.sh")
    check(r.code == 0, "run @mac --fenced in a worktree (\(r.err.prefix(160)))")
    if r.code == 0, done(wt, "wt") {
        check(res(wt, "commit") == 0 && outside(["/usr/bin/git", "-C", main, "rev-parse", "--verify", "wtb"]).out.count > 30, "4.3 a commit in the worktree (its repository's common git folder written)")
        check(res(wt, "mainwrite").map { $0 != 0 } == true && res(wt, "mainread").map { $0 != 0 } == true, "4.3 the main repository's working tree stays closed")
        check(res(wt, "mainhook").map { $0 != 0 } == true, "4.3 the main repository's hooks: EPERM")
        put(wt + "/go", "")
        check(t.waitFor(10) { row("wt")?.fence?.stoppedForGit != nil }, "4.3 the common config is under the allowlist: core.fsmonitor stops the session")
        check(!get(main + "/.git/config").contains("TWINFSMON"), "4.3 …and is taken out of it")
    }
    end("wt")

    // MARK: 4.4 submodules
    let sm = folder("sm")
    m = outside(["/bin/sh", "-c", """
        git init -q -b main . && git -c user.name=S -c user.email=s@example.invalid commit -q --allow-empty -m s
        mkdir subsrc && cd subsrc && git init -q -b main . && echo sub > X && git add X && git -c user.name=S -c user.email=s@example.invalid commit -q -m x
        """], cwd: sm)
    check(m.code == 0, "a repository with a repository inside it (a submodule's source)")
    put(sm + "/s.sh", helpers + """
    o add git -c protocol.file.allow=always submodule add -q ./subsrc sub
    o modhook sh -c 'echo x > .git/modules/sub/hooks/post-checkout'
    echo done > res/DONE
    while [ ! -e go ]; do sleep 0.2; done
    git config submodule.sub.update '!touch PWNED'
    sleep 600
    """)
    r = run("sm", sm, [], "s.sh")
    if r.code == 0, done(sm, "sm") {
        check(res(sm, "add") == 0 && fm.fileExists(atPath: sm + "/sub/X") && row("sm")?.fence?.stoppedForGit == nil, "4.4 git submodule add inside the folder: not a violation (\(out(sm, "add").suffix(160)))")
        check(res(sm, "modhook").map { $0 != 0 } == true, "4.4 .git/modules/*/hooks: EPERM")
        put(sm + "/go", "")
        check(t.waitFor(10) { row("sm")?.fence?.stoppedForGit != nil }, "4.4 submodule.*.update → a violation (stopped)")
    } else { check(false, "the submodule session (\(r.err.prefix(160)))") }
    end("sm")

    // MARK: 4.10/4.11 SwiftPM; 4.12–4.14 Xcode
    let hasSwift = fm.isExecutableFile(atPath: "/usr/bin/swift") && outside(["/usr/bin/xcrun", "--find", "swift"]).code == 0
    let hasXcode = outside(["/usr/bin/xcodebuild", "-version"]).out.contains("Xcode")
    if hasSwift {
        let appwd = folder("sw")
        let dep = appwd + "/swdep", app = appwd + "/swapp"
        try? fm.createDirectory(atPath: dep, withIntermediateDirectories: true)
        put(dep + "/Package.swift", "// swift-tools-version:5.9\nimport PackageDescription\nlet package = Package(name: \"Dep\", products: [.library(name: \"Dep\", targets: [\"Dep\"])], targets: [.target(name: \"Dep\")])\n")
        put(dep + "/Sources/Dep/Dep.swift", "public let greeting = \"hello from a git dependency\"\n")
        m = outside(["/bin/sh", "-c", "git init -q -b main . && git add . && git -c user.name=D -c user.email=d@example.invalid commit -q -m d"], cwd: dep)
        // The dependency is a git repository inside the folder (a URL to a local path: SwiftPM clones it with git).
        // (the manifest's import is spelt out of two pieces: a line beginning "import" is read by the audit as a Swift import)
        put(app + "/Package.swift", "// swift-tools-version:5.9\n" + "im" + "port PackageDescription\n" + """
        let package = Package(name: "App", dependencies: [.package(url: "\(dep)", branch: "main")],
                              targets: [.executableTarget(name: "App", dependencies: [.product(name: "Dep", package: "swdep")])])
        """)
        put(app + "/Sources/App/main.swift", "import Dep\nprint(greeting)\n")
        put(appwd + "/sw.sh", helpers + """
        cd swapp
        o build swift build --disable-sandbox --cache-path "$XDG_CACHE_HOME/swiftpm"
        o runit .build/debug/App
        cd ..
        echo done > res/DONE
        sleep 600
        """)
        let tw = Date()
        r = run("sw", appwd, [], "sw.sh")
        if r.code == 0, t.waitFor(600, { fm.fileExists(atPath: appwd + "/res/DONE") }) {
            print(String(format: "  INFO  a fenced swift build with a git dependency: %.0f s", Date().timeIntervalSince(tw)))
            check(res(appwd, "build") == 0 && out(appwd, "runit").contains("hello from a git dependency"),
                  "4.10/4.11 swift build --disable-sandbox fenced, with a git dependency (\(out(appwd, "build").suffix(240)))")
            check(row("sw")?.fence?.stoppedForGit == nil, "4.11 …SwiftPM's own repository copies are not a violation (\(row("sw")?.fence?.stoppedForGit ?? ""))")
        } else { check(false, "the swift build session (\(r.err.prefix(160)))") }
        end("sw")
    } else { print("  SKIP  4.10/4.11 swift build (no Swift toolchain)") }
    if hasXcode {
        let xp = folder("xp")
        put(xp + "/Hello/main.swift", "print(\"hello from a fenced Xcode project\")\n")
        put(xp + "/Hello.xcodeproj/project.pbxproj", scratchXcodeProject)
        put(xp + "/s.sh", helpers + """
        env > res/env
        o build xcodebuild -project Hello.xcodeproj -scheme Hello -derivedDataPath "$DOZ_DERIVED" -scmProvider system build
        o runit "$DOZ_DERIVED"/Build/Products/Debug/Hello
        o noderived xcodebuild -project Hello.xcodeproj -scheme Hello build
        echo done > res/DONE
        sleep 600
        """)
        let tx = Date()
        r = run("xp", xp, ["--xcode"], "s.sh")
        check(r.code == 0 && r.err.contains("fenced (Xcode)"), "run @mac --fenced --xcode (\(r.code))")
        if r.code == 0, t.waitFor(600, { fm.fileExists(atPath: xp + "/res/DONE") }) {
            print(String(format: "  INFO  a fenced xcodebuild (twice): %.0f s", Date().timeIntervalSince(tx)))
            let derived = (row("xp")?.fence?.sessionFolder ?? "/nonexistent") + "/derived"
            check(get(xp + "/res/env").contains("DOZ_DERIVED=" + derived) && get(xp + "/res/env").contains("DOZ_FENCE=xcode"), "4.12 DOZ_DERIVED is the session's DerivedData; DOZ_FENCE=xcode")
            check(res(xp, "build") == 0 && out(xp, "runit").contains("hello from a fenced Xcode project"), "4.12 xcodebuild build into the session's DerivedData, and it runs (\(out(xp, "build").suffix(200)))")
            check(res(xp, "noderived").map { $0 != 0 } == true, "4.12 without -derivedDataPath it fails (Xcode's own DerivedData is closed)")
            if let p = row("xp")?.pid {
                check(MacFenceStop.mayLookUp(pid_t(p), "com.apple.lsd.mapdb") == false && MacFenceStop.mayLookUp(pid_t(p), "com.apple.coreservices.launchservicesd") == false,
                      "4.13 --xcode: LaunchServices closed")
                check(MacFenceStop.mayLookUp(pid_t(p), "com.apple.CoreSimulator.CoreSimulatorService") == false, "4.14 --xcode: the Simulator's service closed (simctl spawn cannot reach it)")
                check(MacFenceStop.mayWritePreference(pid_t(p), "com.apple.dt.Xcode") == false && MacFenceStop.mayReadPreference(pid_t(p), "com.apple.dt.Xcode") == true,
                      "4.12 no write to Xcode's preferences (reads yes)")
            } else { check(false, "the Xcode session's pid") }
            check(row("xp")?.fence?.state == "fenced (Xcode)", "sessions @mac: STATE fenced (Xcode)")
        } else { check(false, "the Xcode session") }
        end("xp")
        put(xp + "/sim.sh", "sleep 600\n")
        r = run("xs", xp, ["--simulator"], "sim.sh")
        check(r.code == 0 && r.err.contains("a guard rail, not a boundary"), "run @mac --fenced --simulator: the line says a guard rail, not a boundary")
        if let p = row("xs")?.pid {
            check(MacFenceStop.mayLookUp(pid_t(p), "com.apple.lsd.mapdb") == true && MacFenceStop.mayLookUp(pid_t(p), "com.apple.CoreSimulator.CoreSimulatorService") == true,
                  "4.13/4.14 --simulator: LaunchServices and the Simulator open")
            check(MacFenceStop.mayWritePreference(pid_t(p), "com.apple.dt.Xcode") == false, "--simulator: still no write to Xcode's preferences")
            check(MacFenceStop.mayLookUp(pid_t(p), "com.apple.SecurityServer") == false, "--simulator: the Keychain still closed")
        }
        check(row("xs")?.fence?.state == "guard rail (Simulator)" && row("xs")?.capabilities?.first?.state == "guard rail (Simulator)", "STATE and capabilities: guard rail (Simulator)")
        end("xs")
    } else { print("  SKIP  4.12–4.14 xcodebuild (no Xcode)") }

    // MARK: opt-in: the real internet (FENCE_NET=1) — public sites, no credentials of any kind
    if ProcessInfo.processInfo.environment["FENCE_NET"] == "1" {
        let nt = folder("net")
        let lfs = ProcessInfo.processInfo.environment["FENCE_NET_LFS_REPO"] ?? "https://github.com/TomFinley/LFSToy.git"
        put(nt + "/s.sh", helpers + """
        export PATH="/opt/homebrew/bin:$PATH"
        o lfsversion git lfs version
        o lfs sh -c 'git -c filter.lfs.process="git-lfs filter-process" -c filter.lfs.required=true -c filter.lfs.clean="git-lfs clean -- %f" -c filter.lfs.smudge="git-lfs smudge -- %f" clone -q --depth 1 \(lfs) l1 && cd l1 && git lfs ls-files | head -3'
        o go sh -c 'mkdir -p gm && cd gm && printf "module x\\n\\ngo 1.21\\n" > go.mod && GOFLAGS=-mod=mod go mod download -x golang.org/x/text@v0.14.0'
        o pip /usr/bin/python3 -m pip download --no-deps --dest pipdl six==1.16.0
        o spm sh -c 'mkdir -p spm/Sources/A && cd spm && printf "// swift-tools-version:5.9\\nimport PackageDescription\\nlet package = Package(name: \\"A\\", dependencies: [.package(url: \\"https://github.com/apple/swift-argument-parser\\", exact: \\"1.3.0\\")], targets: [.executableTarget(name: \\"A\\", dependencies: [.product(name: \\"ArgumentParser\\", package: \\"swift-argument-parser\\")])])\\n" > Package.swift && echo "print(1)" > Sources/A/main.swift && swift package --disable-sandbox --cache-path "$XDG_CACHE_HOME/swiftpm" resolve'
        o sshgh ssh -o BatchMode=yes -T git@github.com
        echo done > res/DONE
        sleep 600
        """)
        // GitHub keeps LFS objects on github-cloud.githubusercontent.com — not in Standard (sandboxes' neither): allowed by name.
        r = run("fnet", nt, ["--permissions", "standard,site:github-cloud.githubusercontent.com"], "s.sh")
        if r.code == 0, t.waitFor(600, { fm.fileExists(atPath: nt + "/res/DONE") }) {
            for n in ["lfsversion", "lfs", "go", "pip", "spm", "sshgh"] {
                print("  INFO  [FENCE_NET] \(n): exit \(res(nt, n).map(String.init) ?? "?") — \(out(nt, n).suffix(200).replacingOccurrences(of: "\n", with: " ⏎ "))")
            }
            check(res(nt, "go") == 0, "[FENCE_NET] go mod download through the proxy (Go's TLS on a tunnel: real certificates)")
            check(res(nt, "pip") == 0, "[FENCE_NET] pip download from PyPI")
            check(res(nt, "spm") == 0 || !hasSwift, "[FENCE_NET] swift package resolve of a public GitHub dependency")
            check(res(nt, "sshgh").map { $0 != 0 } == true, "[FENCE_NET] ssh to github.com without --ssh-agent: refused by the proxy")
            if res(nt, "lfsversion") == 0 {
                check(res(nt, "lfs") == 0 && out(nt, "lfs").contains(" * "), "[FENCE_NET] git lfs clone of a public repository, its objects downloaded (\(lfs))")
            } else { print("  SKIP  [FENCE_NET] git lfs (not installed)") }
            print("  INFO  [FENCE_NET] its proxy refused: " + t.run(["net", "log", "@mac", "--session", "fnet", "--denied"]).out.split(separator: "\n").suffix(12).joined(separator: " ⏎ "))
        } else { check(false, "[FENCE_NET] the session (\(r.err.prefix(160)))") }
        end("fnet")
    } else {
        print("  SKIP  the tools on the real internet (FENCE_NET=1 runs them: LFS, Go, pip, SwiftPM, ssh to github.com)")
    }
}

/// A trivial macOS command-line tool as an Xcode project (no signing): `Hello/main.swift`.
let scratchXcodeProject = """
// !$*UTF8*$!
{
	archiveVersion = 1;
	classes = {};
	objectVersion = 56;
	objects = {
		A1000000000000000000000A = {isa = PBXBuildFile; fileRef = A1000000000000000000000B; };
		A1000000000000000000000B = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = main.swift; sourceTree = "<group>"; };
		A1000000000000000000000C = {isa = PBXFileReference; explicitFileType = "compiled.mach-o.executable"; includeInIndex = 0; path = Hello; sourceTree = BUILT_PRODUCTS_DIR; };
		A1000000000000000000000D = {isa = PBXGroup; children = (A1000000000000000000000E, A1000000000000000000000F); sourceTree = "<group>"; };
		A1000000000000000000000E = {isa = PBXGroup; children = (A1000000000000000000000B); path = Hello; sourceTree = "<group>"; };
		A1000000000000000000000F = {isa = PBXGroup; children = (A1000000000000000000000C); name = Products; sourceTree = "<group>"; };
		A10000000000000000000010 = {isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (A1000000000000000000000A); runOnlyForDeploymentPostprocessing = 0; };
		A10000000000000000000011 = {isa = PBXNativeTarget; buildConfigurationList = A10000000000000000000014; buildPhases = (A10000000000000000000010); buildRules = (); dependencies = (); name = Hello; productName = Hello; productReference = A1000000000000000000000C; productType = "com.apple.product-type.tool"; };
		A10000000000000000000012 = {isa = PBXProject; buildConfigurationList = A10000000000000000000013; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base); mainGroup = A1000000000000000000000D; productRefGroup = A1000000000000000000000F; projectDirPath = ""; projectRoot = ""; targets = (A10000000000000000000011); };
		A10000000000000000000013 = {isa = XCConfigurationList; buildConfigurations = (A10000000000000000000015); defaultConfigurationIsVisible = 0; defaultConfigurationName = Debug; };
		A10000000000000000000014 = {isa = XCConfigurationList; buildConfigurations = (A10000000000000000000016); defaultConfigurationIsVisible = 0; defaultConfigurationName = Debug; };
		A10000000000000000000015 = {isa = XCBuildConfiguration; buildSettings = {SDKROOT = macosx; MACOSX_DEPLOYMENT_TARGET = 14.0; SWIFT_VERSION = 5.0; ONLY_ACTIVE_ARCH = YES; }; name = Debug; };
		A10000000000000000000016 = {isa = XCBuildConfiguration; buildSettings = {PRODUCT_NAME = "$(TARGET_NAME)"; CODE_SIGNING_ALLOWED = NO; CODE_SIGN_IDENTITY = ""; }; name = Debug; };
	};
	rootObject = A10000000000000000000012;
}
"""
