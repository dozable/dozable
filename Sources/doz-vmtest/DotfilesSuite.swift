import Darwin
import DozableHost
import DozableKit
import Foundation

// 657: the person's DOTFILES in real VMs — LOCAL scratch repositories only (made here with git, in /tmp; never the owner's
// dotfiles, ~/.gitconfig, keys or GitHub account; git reads a scratch config): a repository WITH an install script and one
// WITHOUT; applied at the first start (steps in the start's output and the boot log); nothing of Dozable's overwritten
// (~/.claude, the agent's launcher, ~/.config/opencode); a file that is there kept; the image's stock .bashrc replaced and
// kept beside it; an untrusted repository refused off a terminal (create and --update); `doz dotfiles NAME --update` (a
// new file linked, a removed one's link dropped); a wake and a cold start do not apply again; the agent still starts.
// Store /tmp/dzo-PID-df; it prepares the claude-code image (the pinned version: the registry is not asked).

@discardableResult
private func sh(_ script: String, in dir: String, env: [String: String]) -> (code: Int32, out: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", script]
    p.environment = env
    p.currentDirectoryURL = URL(fileURLWithPath: dir)
    let o = Pipe()
    p.standardOutput = o
    p.standardError = o
    p.standardInput = FileHandle.nullDevice
    do { try p.run() } catch { return (-1, "\(error)") }
    let d = o.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: d, as: UTF8.self))
}

func cliDotfilesSuite(binary: String) async {
    print("cli: your dotfiles in every sandbox — fetched on the Mac, applied at the first start, Dozable's own untouched (657)")
    let t = onboardingHarness(binary, "df", seed: ["kernels", "content", "state.json", "initfs.ext4", "golden"])
    t.env["DOZ_TEST_NPM_REGISTRY"] = "offline"
    let pid = getpid()
    let w = "/tmp/dzo-\(pid)-dfw"
    let fm = FileManager.default
    try? fm.removeItem(atPath: w)
    try? fm.createDirectory(atPath: w, withIntermediateDirectories: true)
    // git — the suite's and the host's — reads a scratch configuration only.
    try? "[user]\n\tname = doz test\n\temail = doz-test@example.invalid\n[init]\n\tdefaultBranch = main\n".write(toFile: w + "/gitconfig", atomically: true, encoding: .utf8)
    t.env["GIT_CONFIG_GLOBAL"] = w + "/gitconfig"
    t.env["GIT_CONFIG_NOSYSTEM"] = "1"
    var gitEnv = ProcessInfo.processInfo.environment
    gitEnv["GIT_CONFIG_GLOBAL"] = w + "/gitconfig"
    gitEnv["GIT_CONFIG_NOSYSTEM"] = "1"
    gitEnv["HOME"] = w
    defer {
        t.run(["host", "stop"], timeout: 300)
        try? fm.removeItem(at: t.store)
        try? fm.removeItem(atPath: w)
    }

    // ── The two repositories ─────────────────────────────────────────────────────────────────────────────────────
    let scripted = w + "/scripted", linked = w + "/linked"
    var r0 = sh("""
        set -e
        mkdir -p \(scripted) && cd \(scripted)
        cat > install.sh <<'EOF'
        #!/bin/sh
        echo "hello from install.sh as $(id -un)"
        echo "$(pwd)" >> "$HOME/.from-install"
        EOF
        chmod +x install.sh
        echo '# not linked: the script decides' > .bashrc
        git init -q && git add -A && git commit -qm 'a dotfiles repository with an install script'
        mkdir -p \(linked) && cd \(linked)
        mkdir -p .config/nvim .config/opencode .claude .local/bin
        echo '# doz-dotfiles-test bashrc' > .bashrc
        echo 'set number' > .vimrc
        echo '-- nvim' > .config/nvim/init.lua
        echo '{"hijacked": true}' > .config/opencode/opencode.json
        echo '{"hijacked": true}' > .claude/settings.json
        printf '#!/bin/sh\\necho HIJACKED\\n' > .local/bin/claude
        printf '#!/bin/sh\\necho mytool-ran\\n' > .local/bin/mytool
        chmod +x .local/bin/claude .local/bin/mytool
        git init -q && git add -A && git commit -qm 'a dotfiles repository without a script'
        """, in: w, env: gitEnv)
    check(r0.code == 0, "two local scratch dotfiles repositories (\(r0.out.suffix(200)))")

    check(t.run(["onboard", "--no-base", "--yes"], timeout: 120).code == 0, "a scratch store, onboarded")
    check(t.run(["config", "set", "images.claude_code_version", AgentImages.claudeCodePinned.version]).code == 0,
          "images.claude_code_version = the pin — the registry is not asked")

    // ── 1. Untrusted: refused off a terminal, naming the command ─────────────────────────────────────────────────
    var r = t.run(["create", "d0", "--image", "lab", "--isolated", "--memory", "512M", "--dotfiles", scripted])
    check(r.code == 5 && r.err.contains("doz dotfiles trust") && r.err.contains("--commit"),
          "create --dotfiles (never said yes, no terminal): refused, exit 5, naming doz dotfiles trust (\(r.code)): \(r.err.suffix(300))")
    check(r.err.contains("install.sh runs"), "…and it said what would run first")
    check(!fm.fileExists(atPath: t.store.appendingPathComponent("sandboxes/d0/doz.json").path), "…and nothing was made")
    r = t.run(["dotfiles", "trust", scripted])
    check(r.code == 0 && r.out.contains("said yes to"), "doz dotfiles trust (the scripted repository's head) (\(r.code)) \(r.err.suffix(200))")

    // ── 2. The lab (root), the scripted repository: applied at the first start ─────────────────────────────────
    r = t.run(["create", "d1", "--image", "lab", "--isolated", "--memory", "512M", "--dotfiles", scripted, "--start", "--verbose"], timeout: 900)
    let start1 = r.out + r.err
    check(r.code == 0, "create d1 --dotfiles <scripted> --start (exit \(r.code)) \(r.code == 0 ? "" : start1.suffix(400).description)")
    check(start1.contains("dotfiles: the folder scripted at"), "the first start shows the dotfiles step (\(start1.components(separatedBy: "\n").filter { $0.contains("dotfiles") }.joined(separator: " | ").prefix(400)))")
    check(start1.contains("install.sh ran (exit 0)"), "…install.sh ran (exit 0)")
    r = t.run(["exec", "d1", "--", "sh", "-c", "cat /root/.from-install; [ -L /root/.bashrc ] && echo LINKED || echo NOT-LINKED; cat /root/.local/share/doz/dotfiles.commit"])
    let head1 = sh("git rev-parse HEAD", in: scripted, env: gitEnv).out.trimmingCharacters(in: .whitespacesAndNewlines)
    check(r.out.hasPrefix("/root/.local/share/doz/dotfiles\n"), "the script ran FROM the files, as root (the lab's user), its HOME the user's (\(r.out.debugDescription))")
    check(r.out.contains("NOT-LINKED"), "with a script, nothing is linked by Dozable")
    check(r.out.contains(head1), "the guest remembers the commit it applied")
    r = t.run(["console", "d1", "--steps"])
    check(r.out.contains("hello from install.sh as root"), "the script's output is in the boot log (doz console --steps)")
    r = t.run(["dotfiles", "d1"])
    check(r.code == 0 && r.out.contains("✓ applied") && r.out.contains(String(head1.prefix(12))) && r.out.contains("install.sh runs"),
          "doz dotfiles d1: the folder, the commit, applied (\(r.out.prefix(400)))")
    r = t.run(["dotfiles", "d1", "--json"])
    check(r.out.contains("\"state\" : \"applied\"") || r.out.contains("\"state\":\"applied\""), "…--json: state applied")
    check(t.run(["ls", "--json"]).out.contains("\"dotfiles\""), "doz ls --json carries each sandbox's dotfiles")
    // A wake, then a cold start: never applied again.
    check(t.run(["sleep", "d1"], timeout: 120).code == 0, "sleep d1")
    r = t.run(["wake", "d1", "--verbose"], timeout: 120)
    check(r.code == 0 && !(r.out + r.err).contains("dotfiles: the folder"), "wake d1: the dotfiles are NOT applied again")
    check(t.run(["shutdown", "d1", "--yes"], timeout: 120).code == 0, "shutdown d1")
    r = t.run(["start", "d1", "--verbose"], timeout: 300)
    check(r.code == 0 && !(r.out + r.err).contains("dotfiles: the folder"), "start d1 (its kept disk): not applied again")
    r = t.run(["exec", "d1", "--", "sh", "-c", "wc -l < /root/.from-install"])
    check(r.out.trimmingCharacters(in: .whitespacesAndNewlines) == "1", "…the script ran exactly once (\(r.out.trimmingCharacters(in: .whitespacesAndNewlines)))")
    t.run(["rm", "d1", "--yes"], timeout: 120)

    // ── 3. claude-code (the agent user), the repository without a script: the link pass ──────────────────────────
    check(t.run(["dotfiles", "trust", linked]).code == 0, "doz dotfiles trust (the linked repository)")
    r = t.run(["up", "d2", "--image", "claude-code", "--isolated", "--account", "none", "--memory", "1G", "--dotfiles", linked, "--detach", "--verbose"], timeout: 1800)
    let start2 = r.out + r.err
    check(r.code == 0, "up d2 --image claude-code --dotfiles <linked> (prepares the image: exit \(r.code)) \(r.code == 0 ? "" : start2.suffix(400).description)")
    check(start2.contains("dotfiles: the folder linked at") && start2.contains("linked"), "the first start links them (a step)")
    let D = "/home/agent/.local/share/doz/dotfiles"
    r = t.run(["exec", "d2", "--", "sh", "-c", """
        cd ~; for f in .vimrc .config/nvim .local/bin/mytool .bashrc; do printf '%s -> %s\\n' "$f" "$(readlink "$f")"; done
        [ -e .bashrc.doz-stock ] && echo STOCK-KEPT; [ -f /etc/skel/.bashrc ] && echo SKEL-HAS-BASHRC
        echo "CLAUDE-SETTINGS=$(grep -c hijacked .claude/settings.json 2>/dev/null)"; echo "LAUNCHER=$(grep -c HIJACKED .local/bin/claude 2>/dev/null)"
        [ -L .claude ] && echo CLAUDE-LINKED; [ -L .local/bin/claude ] && echo LAUNCHER-LINKED
        [ -L .config/opencode ] && echo OPENCODE-LINKED || echo OPENCODE-NOT-LINKED; [ -L .config ] && echo CONFIG-LINKED || echo CONFIG-DIR
        .local/bin/mytool; id -un
        """])
    let o2 = r.out
    check(o2.contains(".vimrc -> \(D)/.vimrc") && o2.contains(".config/nvim -> \(D)/.config/nvim") && o2.contains(".local/bin/mytool -> \(D)/.local/bin/mytool"),
          "linked into ~ as the agent: .vimrc, .config/nvim, .local/bin/mytool (\(o2.debugDescription))")
    check(o2.contains(".bashrc -> \(D)/.bashrc"), "the image's stock .bashrc replaced by the user's")
    check(!o2.contains("SKEL-HAS-BASHRC") || o2.contains("STOCK-KEPT"), "…the stock copy kept beside it (.bashrc.doz-stock)")
    check((o2.contains("CLAUDE-SETTINGS=0\n") || o2.contains("CLAUDE-SETTINGS=\n")) && o2.contains("LAUNCHER=0\n")
          && !o2.contains("CLAUDE-LINKED") && !o2.contains("LAUNCHER-LINKED"),
          "nothing of Dozable's overwritten: ~/.claude and the claude launcher are not the repository's")
    check(o2.contains("OPENCODE-NOT-LINKED") && o2.contains("CONFIG-DIR"), "…~/.config/opencode never linked; ~/.config is a folder, not linked whole")
    check(o2.contains("mytool-ran\nagent"), "a linked tool runs, as the agent")
    r = t.run(["dotfiles", "d2"])
    check(r.out.contains("skipped") && r.out.contains(".claude (Dozable's own)") && r.out.contains(".config/opencode (Dozable's own)")
          && r.out.contains(".local/bin/claude (Dozable's own)"), "doz dotfiles d2 lists what it left alone and why (\(r.out.suffix(400)))")
    // The agent still starts.
    r = t.run(["exec", "d2", "--", "sh", "-c", "~/.local/bin/claude --version"], timeout: 120)
    check(r.code == 0 && r.out.contains("Claude Code"), "the agent still starts: claude --version through its launcher (\(r.out.prefix(120).debugDescription))")
    r = t.run(["sessions", "d2"])
    check(r.out.contains("claude"), "…and its session is open (\(r.out.prefix(200)))")
    r = t.run(["inspect", "d2", "--prompt"])
    check(r.out.contains("Dotfiles: the user's dotfiles") && r.out.contains("are applied in this home"), "the agent's facts say the dotfiles were applied")

    // ── 4. --update: a new commit — refused until said yes, then applied now ──────────────────────────────────────
    check(t.run(["exec", "d2", "--", "sh", "-c", "echo 'my own' > ~/.mine"]).code == 0, "a file of the user's own in the sandbox (~/.mine)")
    r0 = sh("cd \(linked) && git rm -q .vimrc && echo 'new' > .newrc && echo 'from the repo' > .mine && git add -A && git commit -qm second", in: w, env: gitEnv)
    check(r0.code == 0, "a second commit: .vimrc removed, .newrc and .mine added")
    let head2 = sh("git rev-parse HEAD", in: linked, env: gitEnv).out.trimmingCharacters(in: .whitespacesAndNewlines)
    r = t.run(["dotfiles", "d2", "--update"])
    check(r.code == 5 && r.err.contains("doz dotfiles trust"), "--update to a commit never said yes to: refused off a terminal (\(r.code))")
    check(t.run(["dotfiles", "trust", linked, "--commit", head2]).code == 0, "doz dotfiles trust --commit <the new head>")
    r = t.run(["dotfiles", "d2", "--update", "--verbose"], timeout: 300)
    check(r.code == 0 && r.out.contains("applied now"), "doz dotfiles d2 --update: applied now (exit \(r.code)) \(r.out.prefix(300))")
    r = t.run(["exec", "d2", "--", "sh", "-c", "cd ~; readlink .newrc; [ -e .vimrc ] || [ -L .vimrc ] && echo VIMRC-STILL || echo VIMRC-GONE; cat .mine; cat .local/share/doz/dotfiles.commit"])
    check(r.out.contains("\(D)/.newrc"), "the new file is linked")
    check(r.out.contains("VIMRC-GONE"), "the removed file's link is dropped")
    check(r.out.contains("my own") && !r.out.contains("from the repo"), "a file of the user's own is kept, never overwritten")
    check(r.out.contains(head2), "the guest has the new commit")
    r = t.run(["dotfiles", "d2"])
    check(r.out.contains(String(head2.prefix(12))) && r.out.contains("kept") && r.out.contains(".mine"), "doz dotfiles d2: the new commit, .mine kept (\(r.out.prefix(500)))")
    // A hibernation and a wake: not applied again.
    check(t.run(["hibernate", "d2"], timeout: 180).code == 0, "hibernate d2")
    r = t.run(["wake", "d2", "--verbose"], timeout: 180)
    check(r.code == 0 && !(r.out + r.err).contains("dotfiles: the folder"), "wake d2: not applied again")
    // --update on a sandbox that does not run, at the SAME commit: applied again at its next start.
    check(t.run(["shutdown", "d2", "--yes"], timeout: 120).code == 0, "shutdown d2")
    r = t.run(["dotfiles", "d2", "--update"], timeout: 120)
    check(r.code == 0 && r.out.contains("applied at its next start or wake"), "--update while it is off (the same commit): applied at its next start (\(r.out.prefix(200)))")
    r = t.run(["start", "d2", "--verbose"], timeout: 300)
    check(r.code == 0 && (r.out + r.err).contains("dotfiles: the folder linked at"), "start d2: applied again (asked for by --update)")
    r = t.run(["shutdown", "d2", "--yes"], timeout: 120)
    r = t.run(["start", "d2", "--verbose"], timeout: 300)
    check(r.code == 0 && !(r.out + r.err).contains("dotfiles: the folder linked at"), "…and only once")
    t.run(["rm", "d2", "--yes"], timeout: 120)

    // ── 5. --dotfiles none, and the setting ────────────────────────────────────────────────────────────────────────
    check(t.run(["config", "set", "sandbox.dotfiles", linked]).code == 0, "doz config set sandbox.dotfiles <the linked folder>")
    r = t.run(["create", "d3", "--image", "lab", "--isolated", "--memory", "512M", "--json"])
    check(r.code == 0 && r.out.contains("\"dotfiles\""), "a new sandbox follows the setting (trusted at this commit already: no question) (\(r.code)) \(r.err.suffix(200))")
    r = t.run(["create", "d4", "--image", "lab", "--isolated", "--memory", "512M", "--dotfiles", "none", "--json"])
    check(r.code == 0 && !r.out.contains("\"dotfiles\""), "--dotfiles none wins over the setting")
    for n in ["d3", "d4"] { t.run(["rm", n, "--yes"], timeout: 120) }
    check(t.run(["image", "ls"]).out.contains("older recipe") == false, "no image says \"older recipe\" (dotfiles change no recipe)")
}
