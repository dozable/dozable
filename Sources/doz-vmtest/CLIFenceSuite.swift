import Darwin
import Foundation
import DozableKit
import DozableHost

// `make test-cli-fence` (`doz-vmtest cli-fence --doz PATH`): FENCED sessions on this Mac through the real signed doz, its
// host and the real `deckhold-mac` — no VM. Everything is scratch: a store, a folder and a HOME with twins of the person's
// secrets (`DOZ_TEST_FENCE_HOME` — the profile's home, the session folders and the program's HOME), under
// /private/tmp/dzo-PID-mf. Only harmless programs (sh, cat, git in scratch repositories, sleep, perl); every process it
// kills is one it started. The doz processes run with CLAUDECODE / CLAUDE_CODE_* / a fake ANTHROPIC_API_KEY and
// GITHUB_TOKEN — none may reach a session. Row numbers are the plan's test table (M1).

func cliFenceSuite(binary: String) async {
    let root = "/private/tmp/dzo-\(getpid())-mf"
    try? FileManager.default.removeItem(atPath: root)
    let store = root + "/store", home = root + "/home", work = root + "/work", bin = root + "/bin", xdg = root + "/xdg"
    for d in [store, home, work, bin, xdg] { try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true) }
    let t = CLIHarness(binary: binary, store: URL(fileURLWithPath: store))
    t.env["XDG_CONFIG_HOME"] = xdg
    t.env["DOZ_HOST_IDLE"] = "30"
    t.env["DOZ_TEST_CREDENTIALS"] = "memory"
    t.env["CLAUDECODE"] = "1"
    t.env["CLAUDE_CODE_ENTRYPOINT"] = "cli-fence-test"
    t.env["ANTHROPIC_API_KEY"] = "sk-ant-fake-cli-fence"
    t.env["GITHUB_TOKEN"] = "ghp_fakeclifence"
    t.env["DOZ_TEST_FENCE_HOME"] = home
    t.env["DOZ_TEST_MAC_PATH"] = "\(home)/.local/bin:\(bin):/usr/bin:/bin:/usr/sbin:/sbin"
    // The fake upstreams of the network rows (M2), on this Mac's loopback — the host's guarded seam names them.
    let allowed = FenceUpstream(), streamer = FenceUpstream(stream: true)
    defer { allowed.stop(); streamer.stop() }
    t.env["DOZ_TEST_FENCE_UPSTREAMS"] = "allowed.doz.test=127.0.0.1:\(allowed.port),denied.doz.test=127.0.0.1:\(allowed.port),stream.doz.test=127.0.0.1:\(streamer.port)"
    let dozStore = DozableStore(root: URL(fileURLWithPath: store))
    let sockets = MacPlace.socketDirectory(store: dozStore)
    var started: Set<String> = []
    var bystanders: [Process] = []
    defer {
        for s in started { t.run(["sessions", "end", "@mac", s, "--yes"], timeout: 30) }
        t.run(["host", "stop"], timeout: 60)
        for b in bystanders where b.isRunning { b.terminate() }
        try? FileManager.default.removeItem(atPath: sockets)
        try? FileManager.default.removeItem(atPath: root)
        try? FileManager.default.removeItem(atPath: "/private/tmp/dzo-fence-escape-\(getpid())")
    }
    func put(_ p: String, _ s: String, mode: mode_t = 0o644) {
        try? FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: p, contents: Data(s.utf8))
        chmod(p, mode)
    }
    func get(_ p: String) -> String { (try? String(contentsOfFile: p, encoding: .utf8)) ?? "" }
    func git(_ args: [String], in dir: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", dir] + args
        p.environment = ["HOME": home, "PATH": "/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }
    // The twins (scratch — never the real home).
    put(home + "/.ssh/id_x", "PRIVATE-KEY-TWIN", mode: 0o600)
    put(home + "/.ssh/id_x.pub", "ssh-ed25519 AAAATWIN")
    put(home + "/.ssh/config", "Host twin\n")
    put(home + "/.ssh/known_hosts", "twin.example ssh-ed25519 AAAAKNOWN\n")
    put(home + "/.aws/credentials", "[default]\naws_secret_access_key=TWINSECRET\n")
    put(home + "/.zsh_history", "TWINHISTORY\n")
    put(home + "/.zshrc", "export TOKEN=TWIN\n")
    put(home + "/.config/gh/hosts.yml", "oauth_token: TWINSECRET\n")
    put(home + "/.claude/settings.json", "{\"env\":{\"X\":\"TWINSECRET\"}}\n")
    put(home + "/.claude.json", "{}\n")
    put(home + "/Library/Caches/x", "TWINCACHE")
    put(home + "/Documents/doc.txt", "TWINDOC")
    put(home + "/notes/n.txt", "TWINNOTE")
    put(home + "/other-repo/.env", "TOKEN=TWINSECRET\n")
    put(home + "/.gitconfig", "[user]\n\tname = Twin Person\n\temail = twin@example.com\n[credential]\n\thelper = TWINHELPER\n[core]\n\tfsmonitor = TWINFSMON\n")
    put(home + "/.config/git/ignore", "*.ignored\n")
    put(home + "/.local/share/tool/v1/tool", "#!/bin/sh\necho TOOL-RAN\n", mode: 0o755)
    put(home + "/.config/cfgtool", "#!/bin/sh\necho CFG\n", mode: 0o755)
    put(home + "/loose", "#!/bin/sh\necho LOOSE\n", mode: 0o755)
    try? FileManager.default.createDirectory(atPath: home + "/.local/bin", withIntermediateDirectories: true)
    symlink(home + "/.local/share/tool/v1/tool", home + "/.local/bin/tool")
    symlink(home + "/.config/cfgtool", home + "/.local/bin/cfg")
    symlink(home + "/loose", home + "/.local/bin/loose")
    git(["init", "-q"], in: work)
    git(["-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-q", "--allow-empty", "-m", "start"], in: work)

    func rows() -> [SessionRow] { t.json(["sessions", "@mac"], [SessionRow].self) ?? [] }
    func row(_ s: String) -> SessionRow? { rows().first { $0.name == s } }
    func run(_ s: String, _ argv: [String], extra: [String] = [], workdir: String? = nil) -> CLIRun {
        let r = t.run(["run", "@mac", "-d", "--fenced", "--session", s, "--workdir", workdir ?? work] + extra + ["--"] + argv, timeout: 90)
        if r.code == 0 { started.insert(s) }
        return r
    }
    func stopped(_ pid: Int) -> Bool {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid_t(pid), PROC_PIDTBSDINFO, 0, &info, size) == size && info.pbi_status == UInt32(SSTOP)
    }

    print("cli: fenced sessions on this Mac — no VM")
    guard MacDeckhold.locate(executable: binary).url != nil else {
        check(false, "deckhold-mac beside \(binary) (make cli builds it when the pinned toolchain is in .tools)")
        return
    }

    // A listening unix socket in the twin home (a Docker socket's stand-in) — reachable from outside, not from inside.
    let dockerSock = home + "/.docker/run/docker.sock"
    try? FileManager.default.createDirectory(atPath: (dockerSock as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    let lfd = socket(AF_UNIX, SOCK_STREAM, 0)
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(dockerSock.utf8.prefix(MemoryLayout.size(ofValue: addr.sun_path) - 1)) + [0]
    withUnsafeMutableBytes(of: &addr.sun_path) { b in for (i, c) in pathBytes.enumerated() { b[i] = c } }
    let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(lfd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } } == 0
    listen(lfd, 4)
    defer { close(lfd) }
    // An unfenced bystander (never stopped, never signalled).
    let by = Process()
    by.executableURL = URL(fileURLWithPath: "/bin/sleep")
    by.arguments = ["600"]
    by.environment = ["DOZFENCEMARK": "bystander-secret", "PATH": "/usr/bin:/bin"]
    try? by.run()
    bystanders.append(by)

    // FENCE_PART=agent: the agent's rows alone (a quicker loop while working on them).
    if ProcessInfo.processInfo.environment["FENCE_PART"] == "agent" {
        await cliFenceAgentChecks(t, root: root, home: home, store: store, started: &started)
        return
    }
    // FENCE_PART=tools: the tools' rows alone (git/ssh, GitHub, the SSH agent, worktrees, submodules, Swift, Xcode).
    if ProcessInfo.processInfo.environment["FENCE_PART"] == "tools" {
        await cliFenceToolsChecks(t, root: root, home: home, store: store, started: &started)
        return
    }

    // MARK: refusals before anything runs (1.19, 2.1)
    var r = t.run(["run", "@mac", "-d", "--fenced", "--session", "h", "--workdir", home, "--", "/bin/sh"])
    check(r.code == 64 && r.err.contains("your home"), "1.19 a fenced session in the home is refused (\(r.code))")
    r = t.run(["run", "@mac", "-d", "--fenced", "--session", "h", "--workdir", store, "--", "/bin/sh"])
    check(r.code == 64, "1.19 …in the store (\(r.code))")
    let linked = root + "/linked"
    try? FileManager.default.createDirectory(atPath: linked + "/.git", withIntermediateDirectories: true)
    symlink(home + "/.aws/credentials", linked + "/.git/config")
    r = t.run(["run", "@mac", "-d", "--fenced", "--session", "h", "--workdir", linked, "--", "/bin/sh"])
    check(r.code == 64 && r.err.contains(".git/config"), "1.19 …in a folder whose .git/config is a link (\(r.code))")
    r = t.run(["run", "@mac", "-d", "--unfenced", "--keychain", "--session", "h", "--", "/bin/sh"])
    check(r.code == 64, "--keychain with --unfenced is refused (\(r.code))")
    r = t.run(["run", "@mac", "-d", "--fenced", "--write", home + "/.ssh", "--session", "h", "--workdir", work, "--", "/bin/sh"])
    check(r.code == 64 && r.err.contains("--write"), "1.3b --write ~/.ssh is refused (\(r.code))")
    r = t.run(["run", "@mac", "-d", "--fenced", "--read", home, "--session", "h", "--workdir", work, "--", "/bin/sh"])
    check(r.code == 64, "1.3b --read ~ is refused (\(r.code))")

    // MARK: one session runs the probes (1.1–1.18)
    let escape = "/private/tmp/dzo-fence-escape-\(getpid())"
    let probes = """
    r() { n=$1; shift; ( "$@" ) >/dev/null 2>&1; echo $? > "res/$n"; }
    mkdir -p res
    r w_work sh -c 'echo x > a'
    r w_tmp sh -c 'echo x > "$TMPDIR/b"'
    r w_npmcache sh -c 'mkdir -p "$npm_config_cache" && echo x > "$npm_config_cache/x"'
    r w_usertemp sh -c 'echo x > "$(getconf DARWIN_USER_TEMP_DIR)doz-fence-x"'
    r w_usercache sh -c 'echo x > "$(getconf DARWIN_USER_CACHE_DIR)doz-fence-x"'
    r w_privtmp sh -c 'echo x > \(escape)'
    r w_caches sh -c 'echo x > ~/Library/Caches/x2'
    r w_npm sh -c 'mkdir -p ~/.npm && echo x > ~/.npm/x'
    r w_home sh -c 'echo x > ~/x'
    r w_zshrc sh -c 'echo x >> ~/.zshrc'
    r w_launch sh -c 'mkdir -p ~/Library/LaunchAgents && echo x > ~/Library/LaunchAgents/x.plist'
    r r_ssh cat ~/.ssh/id_x
    r r_aws cat ~/.aws/credentials
    r r_hist cat ~/.zsh_history
    r r_gh cat ~/.config/gh/hosts.yml
    r r_claude cat ~/.claude/settings.json
    r r_claudejson cat ~/.claude.json
    r r_env cat ~/other-repo/.env
    r r_caches cat ~/Library/Caches/x
    r r_docs cat ~/Documents/doc.txt
    r r_lshome ls ~
    r r_sshconfig cat ~/.ssh/config
    r r_pub cat ~/.ssh/id_x.pub
    r x_tool tool
    r x_cfg cfg
    r x_loose loose
    r g_status git status
    r g_commit sh -c 'echo y > tracked && git add tracked && git commit -qm c'
    r g_ident sh -c 'test "$(git log -1 --format=%an)" = "Twin Person"'
    r g_excl sh -c 'echo z > junk.ignored && test -z "$(git status --porcelain junk.ignored)"'
    r g_noglobal sh -c 'git config --global --list | grep -q -e TWINHELPER -e TWINFSMON'
    r h_hooks sh -c 'echo x > .git/hooks/pre-commit'
    r h_mvgit mv .git g2
    r h_mvin sh -c 'echo x > y && mv y .git/hooks/y'
    r s_store ls "\(store)"
    r s_sock ls "\(sockets)"
    r s_toml ls "\(xdg)/doz"
    DOZ_STORE="\(store)" "\(binary)" sessions @mac --json > dozls.txt 2>&1
    r s_hostsock nc -U -z "\(store)/host.sock"
    r s_dock nc -U -z "\(dockerSock)"
    r p_sudo sudo -n true
    r p_open open -a NoSuchAppDozFenceTest
    r p_osa osascript -e 'return 1'
    r p_lctl launchctl list
    r p_copy sh -c 'cp /bin/launchctl ./lc && ./lc list'
    r p_sbx sandbox-exec -p '(version 1)(allow default)' /usr/bin/true
    r k_signal kill -0 \(getpid())
    r k_bystander kill -0 \(by.processIdentifier)
    r k_ps ps
    r k_procargs /usr/bin/python3 pa.py \(by.processIdentifier)
    r n_nc nc -z -w 3 1.1.1.1 443
    r n_curl curl -sS -m 5 https://example.com
    r c_nested sh -c 'sh -c "cat ~/.zsh_history"'
    sh -c 'nohup sh -c "cat ~/.zsh_history > nh.txt 2>/dev/null" >/dev/null 2>&1 &'; sleep 1
    r t_tty sh -c 'echo tty-ok > /dev/tty'
    r t_doztty sh -c 'test -w "$DOZ_TTY"'
    env > env.txt
    kh="${TMPDIR%/tmp/}/ssh/known_hosts"; cat "$kh" > kh.txt; echo new.example ssh-ed25519 AAAANEW >> "$kh"; echo "$GIT_SSH_COMMAND" > gsc.txt
    r r_kh cat ~/.ssh/known_hosts
    echo done > res/DONE
    sleep 600
    """
    put(work + "/probes.sh", probes)
    // Another process's environment through sysctl kern.procargs2 — exit 0 only when the bystander's marker variable is
    // in what came back. (Its ARGV is readable from inside the fence: Seatbelt does not govern kern.procargs2 for a
    // same-user process — a stated residual; the kernel itself never returns another process's environment.)
    put(work + "/pa.py", """
    import os, ctypes, sys
    libc = ctypes.CDLL(None)
    mib = (ctypes.c_int * 3)(1, 49, int(sys.argv[1]))
    size = ctypes.c_size_t(0)
    if libc.sysctl(mib, 3, None, ctypes.byref(size), None, 0) != 0 or size.value == 0: sys.exit(1)
    buf = ctypes.create_string_buffer(size.value)
    if libc.sysctl(mib, 3, buf, ctypes.byref(size), None, 0) != 0: sys.exit(1)
    sys.exit(0 if b"DOZFENCEMARK" in buf.raw[:size.value] else 1)
    """)
    r = run("probe", ["/bin/sh", "probes.sh"])
    check(r.code == 0 && r.err.contains("[doz] fenced:"), "run @mac --fenced: started, the fenced line said (\(r.code))\(r.code == 0 ? "" : ": " + r.err)")
    check(!r.err.contains("no sandbox, no proxy"), "…not the no-isolation line")
    check(t.waitFor(60) { FileManager.default.fileExists(atPath: work + "/res/DONE") }, "the probes ran")
    func res(_ n: String) -> Int? { Int(get(work + "/res/" + n).trimmingCharacters(in: .whitespacesAndNewlines)) }
    func ok(_ n: String, _ what: String) { check(res(n) == 0, "\(what) — works (\(res(n).map(String.init) ?? "no result"))") }
    func no(_ n: String, _ what: String) { check(res(n).map { $0 != 0 } ?? false, "\(what) — refused (\(res(n).map(String.init) ?? "no result"))") }
    ok("w_work", "1.1 write in the folder")
    ok("w_tmp", "1.1 write its own TMPDIR")
    ok("w_npmcache", "1.1 write a cache through npm_config_cache (its own)")
    no("w_usertemp", "1.1a write the user temp folder (confstr)")
    no("w_usercache", "1.1a write the user cache folder (…/C)")
    no("w_privtmp", "1.1a write /private/tmp")
    check(!FileManager.default.fileExists(atPath: escape), "…and nothing landed there")
    no("w_caches", "1.1a write ~/Library/Caches")
    no("w_npm", "1.1a write ~/.npm")
    no("w_home", "1.2 write ~/x")
    no("w_zshrc", "1.2 write ~/.zshrc")
    no("w_launch", "1.2 write ~/Library/LaunchAgents/x.plist")
    check(get(home + "/.zshrc") == "export TOKEN=TWIN\n", "…the twin .zshrc unchanged")
    for (n, what) in [("r_ssh", "~/.ssh/id_x"), ("r_aws", "~/.aws/credentials"), ("r_hist", "the shell history"), ("r_gh", "~/.config/gh"),
                      ("r_claude", "~/.claude"), ("r_claudejson", "~/.claude.json"), ("r_env", "another repository's .env"),
                      ("r_caches", "~/Library/Caches"), ("r_docs", "~/Documents"), ("r_lshome", "ls ~")] {
        no(n, "1.3 read \(what)")
    }
    ok("r_sshconfig", "1.3 read ~/.ssh/config")
    ok("r_pub", "1.3 read ~/.ssh/*.pub")
    ok("x_tool", "1.3a a PATH tool linked into ~/.local/share runs")
    no("x_cfg", "1.3a a PATH link into ~/.config is not followed")
    ok("x_loose", "1.3a a PATH link to a file directly in the home runs (that file only)")
    ok("g_status", "1.3c git status")
    ok("g_commit", "1.3c git commit")
    ok("g_ident", "1.3c the commit is the person's identity (from the session's gitconfig)")
    ok("g_excl", "1.3c the person's global excludes are honoured")
    no("g_noglobal", "1.3c no credential helper or fsmonitor of the person's global config is carried")
    no("h_hooks", "1.4 write .git/hooks")
    no("h_mvgit", "1.4a rename .git away")
    no("h_mvin", "1.4b rename into .git/hooks")
    no("s_store", "1.6 the store")
    no("s_sock", "1.6 the holders' socket folder")
    no("s_toml", "1.6 doz's settings folder")
    let dozls = get(work + "/dozls.txt")
    check(!dozls.contains("probes.sh") && !dozls.contains("\"probe\""), "1.7 doz from inside (DOZ_STORE given) lists nothing of the store's sessions")
    no("s_hostsock", "1.7 the host's socket")
    check(bound, "the Docker socket stand-in listens (outside)")
    no("s_dock", "1.9 a unix socket in the home (Docker's stand-in)")
    no("p_sudo", "1.8 sudo")
    no("p_open", "1.8 open")
    no("p_osa", "1.8 osascript")
    no("p_lctl", "1.8 launchctl")
    no("p_copy", "1.8 a COPY of launchctl (no launchd service)")
    no("p_sbx", "1.8 a nested sandbox-exec")
    no("k_signal", "1.11 a signal to the test (outside the fence)")
    no("k_bystander", "1.11 a signal to an unfenced bystander")
    no("k_ps", "1.11b ps (unavailable)")
    no("k_procargs", "1.11c another process's environment (kern.procargs2) — its argv stays readable: a stated residual")
    no("n_nc", "2.3 no direct connection (nc to an address)")
    no("n_curl", "2.2 curl https://example.com — through the proxy, not in Standard: refused")
    no("c_nested", "1.12 a nested shell inherits the fence")
    check(get(work + "/nh.txt").isEmpty, "1.12 a nohup'd grandchild inherits the fence (it read nothing)")
    ok("t_tty", "1.13 /dev/tty")
    ok("t_doztty", "1.13 its own pty ($DOZ_TTY)")
    // 1.14: asked of the kernel (sandbox_check, mach-lookup) — no Keychain item is touched.
    if let pid = row("probe")?.pid {
        check(MacFenceStop.mayLookUp(pid_t(pid), "com.apple.SecurityServer") == false && MacFenceStop.mayLookUp(pid_t(pid), "com.apple.secd") == false,
              "1.14 the Keychain's services are closed to a fenced program")
        check(MacFenceStop.mayLookUp(pid_t(pid), "com.apple.trustd") == true, "…while certificate trust (trustd) is open")
        check(MacFenceStop.mayLookUp(pid_t(pid), "com.apple.coreservices.launchservicesd") == false, "1.8 LaunchServices is closed")
    } else { check(false, "the probe session's pid") }
    let env = get(work + "/env.txt")
    let leaked = env.split(separator: "\n").filter { l in
        l.hasPrefix("CLAUDE") || l.hasPrefix("ANTHROPIC") || l.hasPrefix("GITHUB_TOKEN") || l.hasPrefix("SSH_AUTH_SOCK") || l.hasPrefix("XPC_")
            || l.hasPrefix("__CF") || l.hasPrefix("DECKHOLD_DIR") || (l.hasPrefix("DOZ_") && !l.hasPrefix("DOZ_TTY=") && !l.hasPrefix("DOZ_FENCE="))
    }
    check(leaked.isEmpty && env.contains("DOZ_FENCE=agent") && env.contains("HOME=\(home)"),
          "1.17 the environment: nothing of the host's (CLAUDE*, ANTHROPIC_*, GITHUB_TOKEN, SSH_AUTH_SOCK, XPC_*, __CF*, DECKHOLD_DIR, DOZ_*)\(leaked.isEmpty ? "" : ": " + leaked.joined(separator: ", "))")
    let sessionKnown = (row("probe")?.fence?.sessionFolder ?? "/nonexistent") + "/ssh/known_hosts"
    check(get(work + "/kh.txt") == "twin.example ssh-ed25519 AAAAKNOWN\n", "1.28 the session's known_hosts is seeded from the person's")
    check(get(sessionKnown).contains("AAAANEW") && get(home + "/.ssh/known_hosts") == "twin.example ssh-ed25519 AAAAKNOWN\n",
          "1.28 a new host key lands in the session's copy, never the person's")
    no("r_kh", "1.28 the person's own known_hosts is not read")
    check(get(work + "/gsc.txt").contains("UserKnownHostsFile="), "1.28 git's ssh uses the session's own known_hosts")

    // MARK: the session's record and its listing
    let pr = row("probe")
    check(pr?.fenced == true && pr?.fence?.profile == "agent" && pr?.fence?.keychain == false, "sessions @mac --json: fenced, agent, Keychain closed")
    let text = t.run(["sessions", "@mac"]).out
    check(text.contains("fenced") && text.contains("probe"), "sessions @mac: the session and its state (fenced)")
    check(t.run(["ls"]).out.contains("(fenced)"), "doz ls: this Mac's line says fenced")

    // MARK: @DOZ_PTY@ in the PROGRAM's argv stays literal (1.13)
    r = run("pty", ["/bin/sh", "-c", "printf %s \"$0\" > pty.txt; sleep 600", "@DOZ_PTY@"])
    check(r.code == 0 && t.waitFor(10) { get(work + "/pty.txt") == "@DOZ_PTY@" }, "1.13 @DOZ_PTY@ in the program's own argv is left as given (\(get(work + "/pty.txt")))")

    // MARK: git: the allowlist kept, a violation stops every process of the fence (1.5, 1.5a, 1.5b)
    try? FileManager.default.removeItem(atPath: work + "/res")
    let gitWork = root + "/gw"
    try? FileManager.default.createDirectory(atPath: gitWork, withIntermediateDirectories: true)
    git(["init", "-q"], in: gitWork)
    put(gitWork + "/ok.sh", "git config branch.x.remote origin; git config remote.o.url https://example.com/r.git; echo ok > ok.txt; sleep 600\n")
    r = run("gok", ["/bin/sh", "ok.sh"], workdir: gitWork)
    check(r.code == 0 && t.waitFor(10) { FileManager.default.fileExists(atPath: gitWork + "/ok.txt") }, "1.5 allowlisted keys added")
    usleep(1_500_000)
    check(row("gok")?.fence?.stoppedForGit == nil, "1.5 …kept, the session still runs")
    check(get(gitWork + "/.git/config").contains("https://example.com/r.git"), "1.5 …and the keys are there")
    t.run(["sessions", "end", "@mac", "gok", "--yes"], timeout: 30)
    // The detached re-adder: setsid + a double fork, re-adding core.fsmonitor every 100 ms.
    put(gitWork + "/bad.sh", """
    ( perl -MPOSIX -e 'POSIX::setsid(); exit 0 if fork; while (1) { system("git", "config", "core.fsmonitor", "touch \(gitWork)/PWNED"); select(undef,undef,undef,0.1) }' & )
    sleep 600
    """)
    let t0 = Date()
    r = run("gbad", ["/bin/sh", "bad.sh"], workdir: gitWork)
    check(r.code == 0, "1.5b a session whose detached child keeps re-adding core.fsmonitor")
    check(t.waitFor(10) { row("gbad")?.fence?.stoppedForGit != nil }, "1.5a stopped: git config (\(String(format: "%.1f", Date().timeIntervalSince(t0))) s after start)")
    usleep(800_000)
    let fenceMembers = MacFenceStop.members(sentinel: (row("gbad")?.fence?.sessionFolder ?? "") + "/etc/sentinel-" + (sessionTag(store, "gbad") ?? ""),
                                            anti: ((row("gbad")?.fence?.sessionFolder ?? "") as NSString).deletingLastPathComponent + "/.not-fenced", program: nil).pids
    check(fenceMembers.count >= 2 && fenceMembers.allSatisfy { stopped(Int($0)) }, "1.5b every process of the fence is stopped — the detached one included (\(fenceMembers.count))")
    check(!stopped(Int(by.processIdentifier)), "1.5b the unfenced bystander is not stopped")
    check(row("probe").map { $0.pid.map { !stopped($0) } ?? false } ?? false, "1.5b another session (not in this folder) is not stopped")
    usleep(1_000_000)
    check(!get(gitWork + "/.git/config").contains("fsmonitor"), "1.5b the key is absent, and stays absent")
    check(!FileManager.default.fileExists(atPath: gitWork + "/PWNED"), "…nothing ran it")
    r = t.run(["sessions", "@mac"])
    check(r.out.contains("stopped: git config") && r.err.contains("doz sessions resume @mac gbad"), "sessions @mac: STATE stopped: git config, and how to resume")
    r = t.run(["sessions", "@mac", "--quarantine", "gbad"])
    check(r.code == 0 && r.out.contains("core.fsmonitor = touch"), "the stripped line is in the store's quarantine (--quarantine)")
    check(!FileManager.default.fileExists(atPath: gitWork + "/.git/config.orig"), "…never in the folder")
    r = t.run(["sessions", "restart", "@mac", "gbad", "--yes", "-d"], timeout: 30)
    check(r.code != 0 && r.err.contains("resume"), "a stopped session is not restarted until resumed (\(r.code))")
    r = t.run(["sessions", "resume", "@mac", "gbad"], timeout: 30)
    check(r.code != 0 || t.waitFor(5) { row("gbad")?.fence?.stoppedForGit != nil }, "1.5b resumed: the re-adder adds it again at once — stopped again")
    usleep(1_000_000)
    check(!get(gitWork + "/.git/config").contains("fsmonitor"), "…and the key is still absent")
    r = t.run(["sessions", "end", "@mac", "gbad", "--yes"], timeout: 60)
    check(r.code == 0, "a stopped session can be ended")
    usleep(500_000)
    check(fenceMembers.allSatisfy { kill($0, 0) != 0 }, "…and every process of its fence is gone, the detached one too")

    // MARK: 1.5e a .git FILE pointing at an ordinary folder
    put(gitWork + "/gd/config", "[core]\n\tfsmonitor = touch \(gitWork)/PWNED2\n")
    put(gitWork + "/dotgit.sh", "sleep 1; mkdir -p sub; printf 'gitdir: \(gitWork)/gd\\n' > sub/.git; sleep 600\n")
    r = run("gfile", ["/bin/sh", "dotgit.sh"], workdir: gitWork)
    check(r.code == 0 && t.waitFor(10) { row("gfile")?.fence?.stoppedForGit != nil }, "1.5e a .git file pointing outside a worktree or module: a violation, stopped")
    check(!FileManager.default.fileExists(atPath: gitWork + "/sub/.git"), "1.5e …the .git file is taken out")
    git(["status"], in: gitWork + "/sub")
    check(!FileManager.default.fileExists(atPath: gitWork + "/PWNED2"), "1.5e an unfenced git in sub/ afterwards runs nothing")
    t.run(["sessions", "end", "@mac", "gfile", "--yes"], timeout: 60)

    // MARK: 1.5d a change while the host is down → dealt with at adoption
    put(gitWork + "/wait.sh", "while [ ! -e go ]; do sleep 0.2; done; git config core.pager PAGERX; sleep 600\n")
    r = run("gdown", ["/bin/sh", "wait.sh"], workdir: gitWork)
    check(r.code == 0, "a session that changes its config later")
    if let hp = t.hostPID() { kill(hp, SIGKILL); check(t.waitFor(10) { kill(hp, 0) != 0 }, "the host killed (SIGKILL)") }
    FileManager.default.createFile(atPath: gitWork + "/go", contents: nil)
    check(t.waitFor(10) { get(gitWork + "/.git/config").contains("PAGERX") }, "1.5d the change is made while no host runs")
    r = t.run(["sessions", "send", "@mac", "gdown", "--text", "x"], timeout: 30)          // starts a host, which adopts
    check(t.waitFor(15) { row("gdown")?.fence?.stoppedForGit != nil }, "1.5d the next host strips it and stops the session at adoption")
    check(!get(gitWork + "/.git/config").contains("PAGERX"), "1.5d …stripped")
    t.run(["sessions", "end", "@mac", "gdown", "--yes"], timeout: 60)

    // MARK: restart re-seeds (1.21), grants widen (1.27), the host's file rules on its folder (1.26)
    put(work + "/seed.sh", "echo t > \"$TMPDIR/marker\"; mkdir -p \"$npm_config_cache\"; echo c > \"$npm_config_cache/kept\"; echo started >> seed.txt; sleep 600\n")
    r = run("seed", ["/bin/sh", "seed.sh"])
    check(r.code == 0 && t.waitFor(10) { get(work + "/seed.txt").contains("started") }, "a session that writes its temp and a cache")
    let folder = row("seed")?.fence?.sessionFolder ?? "/nonexistent"
    check(FileManager.default.fileExists(atPath: folder + "/tmp/marker"), "…its temp is in its own folder")
    // The program swaps its tmp/ for a link to the person's Documents before the restart.
    try? FileManager.default.removeItem(atPath: folder + "/tmp")
    symlink(home + "/Documents", folder + "/tmp")
    r = t.run(["sessions", "restart", "@mac", "seed", "--yes", "-d"], timeout: 60)
    check(r.code == 0, "1.21 restart (\(r.code))\(r.code == 0 ? "" : ": " + r.err)")
    check(t.waitFor(10) { get(work + "/seed.txt").components(separatedBy: "started").count == 3 }, "1.21 …it runs again, fenced")
    check(get(home + "/Documents/doc.txt") == "TWINDOC", "1.26 the person's Documents untouched by the re-seed")
    check(row("seed")?.fenced == true, "1.21 still fenced")
    check(FileManager.default.fileExists(atPath: folder + "/cache/npm/kept"), "1.27 the same grants keep the caches")
    t.run(["sessions", "end", "@mac", "seed", "--yes"], timeout: 60)
    r = t.run(["run", "@mac", "-d", "--fenced", "--keychain", "--session", "seed", "--workdir", work, "--", "/bin/sh", "-c", "sleep 600"], timeout: 60)
    if r.code == 0 { started.insert("seed") }
    check(r.code == 0 && r.err.contains("Keychain OPEN"), "a re-open with --keychain says the Keychain is open")
    check(!FileManager.default.fileExists(atPath: folder + "/cache/npm/kept"), "1.27 …and the WIDER grants emptied its caches")
    if let pid = row("seed")?.pid {
        check(MacFenceStop.mayLookUp(pid_t(pid), "com.apple.SecurityServer") == true, "1.15 --keychain opens the Keychain's services to it (no item touched)")
    }
    t.run(["sessions", "end", "@mac", "seed", "--yes"], timeout: 60)

    // MARK: --read / --write / mac.fence_read (1.3b)
    let lib = root + "/lib"
    try? FileManager.default.createDirectory(atPath: lib, withIntermediateDirectories: true)
    check(t.run(["config", "set", "mac.fence_read", "notes"]).code == 0, "1.3b doz config set mac.fence_read notes")
    put(work + "/rw.sh", """
    r() { n=$1; shift; ( "$@" ) >/dev/null 2>&1; echo $? > "rw-$n"; }
    r lib sh -c 'echo x > "\(lib)/y"'
    r docs cat ~/Documents/doc.txt
    r docsw sh -c 'echo x > ~/Documents/z'
    r notes cat ~/notes/n.txt
    echo done > rw-DONE; sleep 600
    """)
    r = run("rw", ["/bin/sh", "rw.sh"], extra: ["--write", lib, "--read", home + "/Documents"])
    check(r.code == 0 && t.waitFor(10) { FileManager.default.fileExists(atPath: work + "/rw-DONE") }, "a session with --write and --read")
    func rw(_ n: String) -> Int? { Int(get(work + "/rw-" + n).trimmingCharacters(in: .whitespacesAndNewlines)) }
    check(rw("lib") == 0, "1.3b --write folder writable")
    check(rw("docs") == 0 && rw("docsw") != 0, "1.3b --read folder readable, not writable")
    check(rw("notes") == 0, "1.3b mac.fence_read's entry readable")
    t.run(["sessions", "end", "@mac", "rw", "--yes"], timeout: 60)

    // MARK: 1.20 odd folder names: spaces, parentheses, brackets, a quote-free unicode name, regex characters
    let odd = root + "/odd dir (é) [1]+$.x"
    try? FileManager.default.createDirectory(atPath: odd, withIntermediateDirectories: true)
    git(["init", "-q"], in: odd)
    put(odd + "/odd.sh", """
    r() { n=$1; shift; ( "$@" ) >/dev/null 2>&1; echo $? > "odd-$n"; }
    r write sh -c 'echo x > a'
    r hooks sh -c 'echo x > .git/hooks/pre-commit'
    r mvgit mv .git g2
    r home ls ~
    echo done > odd-DONE; sleep 600
    """)
    r = run("odd", ["/bin/sh", "odd.sh"], workdir: odd)
    check(r.code == 0 && t.waitFor(10) { FileManager.default.fileExists(atPath: odd + "/odd-DONE") }, "1.20 a fenced session in '\((odd as NSString).lastPathComponent)'")
    func oddRes(_ n: String) -> Int? { Int(get(odd + "/odd-" + n).trimmingCharacters(in: .whitespacesAndNewlines)) }
    check(oddRes("write") == 0 && oddRes("hooks").map { $0 != 0 } == true && oddRes("mvgit").map { $0 != 0 } == true && oddRes("home").map { $0 != 0 } == true,
          "1.20 …its rules hold (writes yes; hooks, renaming .git, the home no)")
    let quoted = root + "/a\"b"
    try? FileManager.default.createDirectory(atPath: quoted, withIntermediateDirectories: true)
    r = t.run(["run", "@mac", "-d", "--fenced", "--session", "q", "--workdir", quoted, "--", "/bin/sh"], timeout: 30)
    check(r.code == 64, "1.20 a folder name with a quote is refused (a profile cannot carry it) (\(r.code))")
    t.run(["sessions", "end", "@mac", "odd", "--yes"], timeout: 60)

    // MARK: 1.22 a host stop and kill leave a fenced session running, fenced, watched again
    if let p = row("probe")?.pid {
        check(t.run(["host", "stop"], timeout: 60).code == 0, "host stop")
        check(row("probe")?.pid == p && row("probe")?.ended == false, "1.22 the fenced session keeps running without a host")
        r = t.run(["sessions", "send", "@mac", "probe", "--text", "x"], timeout: 30)
        check(r.code == 0, "1.22 a new host adopts it")
        git(["config", "core.fsmonitor", "LATER"], in: work)               // the folder's config changed (by anyone)
        check(t.waitFor(10) { row("probe")?.fence?.stoppedForGit != nil }, "1.22 the watch is armed again after adoption")
        t.run(["sessions", "end", "@mac", "probe", "--yes"], timeout: 60)
    } else { check(false, "the probe session's pid") }

    // MARK: 1.25 the cost of a fenced start
    func median(_ xs: [Double]) -> Double { let s = xs.sorted(); return s.isEmpty ? 0 : s[s.count / 2] }
    let perf = root + "/perf"
    try? FileManager.default.createDirectory(atPath: perf, withIntermediateDirectories: true)
    var plain: [Double] = [], fenced: [Double] = []
    for i in 0..<10 {
        for f in [false, true] {
            let s = "pf\(f ? "f" : "u")\(i)"
            let a = Date()
            let rr = t.run(["run", "@mac", "-d", f ? "--fenced" : "--unfenced", "--session", s, "--workdir", perf, "--", "/bin/sleep", "600"], timeout: 60)
            let ms = Date().timeIntervalSince(a) * 1000
            if rr.code == 0 { started.insert(s); if f { fenced.append(ms) } else { plain.append(ms) } }
            t.run(["sessions", "end", "@mac", s, "--yes"], timeout: 60)
            started.remove(s)
        }
    }
    let added = median(fenced) - median(plain)
    print(String(format: "  INFO  start: unfenced median %.0f ms, fenced %.0f ms, added %.0f ms (%d/%d runs)", median(plain), median(fenced), added, plain.count, fenced.count))
    check(fenced.count == 10 && added < 50, String(format: "1.25 a fenced start adds < 50 ms (median %.0f ms)", added))

    // The unfenced path is unchanged (1.23's run is make test-cli-host): the no-isolation line, no fence.
    r = t.run(["run", "@mac", "-d", "--unfenced", "--session", "plain", "--workdir", work, "--", "/bin/sleep", "600"], timeout: 60)
    if r.code == 0 { started.insert("plain") }
    check(r.code == 0 && r.err.contains("no sandbox, no proxy") && row("plain")?.fenced == nil, "--unfenced: as before (no fence, the no-isolation line)")
    r = t.run(["run", "@mac", "-d", "--unfenced", "--local-port", "4000", "--session", "plain2", "--", "/bin/sleep", "1"])
    check(r.code == 64, "--local-port with --unfenced is refused (\(r.code))")
    t.run(["sessions", "end", "@mac", "plain", "--yes"], timeout: 60)
    started.remove("plain")

    // M2: the network.
    await cliFenceNetworkChecks(t, root: root, home: home, store: store, binary: binary, allowed: allowed, streamer: streamer, started: &started)

    // M3: the agent — its config folder, conversations, the swapped login, the facts, capabilities, bridges.
    await cliFenceAgentChecks(t, root: root, home: home, store: store, started: &started)

    // M4: the tools — git/ssh through the proxy, GitHub as you, the SSH agent, worktrees, submodules, Swift, Xcode.
    await cliFenceToolsChecks(t, root: root, home: home, store: store, started: &started)
}

/// A fenced session's tag, read from its record in the store (the test runs outside every fence).
private func sessionTag(_ store: String, _ s: String) -> String? {
    guard let d = FileManager.default.contents(atPath: store + "/mac-sessions/sessions.json"),
          let r = try? HostWire.decoder.decode(MacSessionRecords.self, from: d) else { return nil }
    return r.sessions[s]?.fence?.tag
}
