import Darwin
import Foundation
import DozableKit
import DozableHost

// `make test-cli-tmux38`: Dozable's own tmux (3.8, static — Guest/tmux/, copied in by the tools layer) on a DEBIAN base
// (the distro ships 3.3a) and an ALPINE base (3.4), in a scratch store (`/tmp/dzo-PID-8`), through the seams only:
//   - the session runs in tmux 3.8 (the server's own version), the tools layer lists it, /usr/local/bin/tmux is it;
//   - doz's tmux.conf parses on 3.8 AND on the distro's tmux;
//   - a copy (OSC 52 from the pane, and the xclip shim) reaches the seamed pasteboard (DOZ_TEST_PASTEBOARD);
//   - xdg-open reaches the seamed opener (DOZ_TEST_OPEN_URL);
//   - the theme: tmux asks the terminal (CSI ? 996 n), the terminal's answer (here: this test, as the terminal) is
//     what tmux reports to a pane asking it, light and then dark;
//   - OSC 7501 (what the agent is doing), MEASURED: a plain report inside tmux (Claude Code's and pi's form) and one
//     wrapped for tmux's passthrough, with allow-passthrough off (doz's conf) and then on;
//   - a session already running in the distro's OLDER tmux keeps it: the choice names the distro's, a second open of
//     it is the same session, and ending it ends that server.
// Network: the two base images are prepared here (docker.io), once per run.

private let esc = "\u{1B}"

/// Asks the pane's terminal (tmux) for the theme, prints what came back (`od -c`: ESC is `033`).
private let themeQuery = #"""
#!/bin/sh
stty raw -echo min 0 time 30
printf '\033[?996n'
a=$(dd bs=1 count=9 2>/dev/null | od -An -c | tr -d ' \n')
stty sane
echo "PANE=$a"
"""#

/// A program that speaks OSC 7501 the way Claude Code and pi do (plain), asking first.
private let plainStatus = #"""
#!/bin/sh
stty raw -echo min 0 time 30
printf '\033]7501;?\033\\'
a=$(dd bs=1 count=10 2>/dev/null | od -An -c | tr -d ' \n')
stty sane
case "$a" in *7501*) echo ANSWERED > /tmp/p7.ans;; *) echo "NO-ANSWER [$a]" > /tmp/p7.ans;; esac
while :; do printf '\033]7501;state=working:app=plain-probe\033\\'; sleep 1; done
"""#

/// The same report wrapped for tmux's passthrough (`ESC P tmux; … ESC \`, every ESC inside doubled).
private let wrappedStatus = #"""
#!/bin/sh
while :; do printf '\033Ptmux;\033\033]7501;state=working:app=wrapped-probe\033\033\\\033\\'; sleep 1; done
"""#

func cliTmux38Suite(binary: String) async {
    let t = onboardingHarness(binary, "8", seed: ["kernels", "content", "state.json", "initfs.ext4", "golden"])
    let board = t.store.appendingPathComponent("pasteboard"), opened = t.store.appendingPathComponent("opened.log")
    t.env["DOZ_TEST_PASTEBOARD"] = board.path
    t.env["DOZ_TEST_OPEN_URL"] = opened.path
    t.env["DOZ_TEST_NPM_REGISTRY"] = "offline"
    defer {
        t.run(["host", "stop"], timeout: 300)
        try? FileManager.default.removeItem(at: t.store)
    }
    print("cli: Dozable's tmux \(ToolsLayer.tmuxVersion) on Debian and Alpine — the bridges, the theme, OSC 7501")
    check(t.run(["onboard", "--no-base", "--yes"], timeout: 120).code == 0, "a scratch store, onboarded")
    func pasteboard() -> String { (try? String(contentsOf: board, encoding: .utf8)) ?? "" }
    func openedLog() -> String { (try? String(contentsOf: opened, encoding: .utf8)) ?? "" }

    for (base, distro) in [("debian", "3.3a"), ("alpine", "3.4")] {
        let n = "x8-\(base)"
        print("cli: \(base) (the distro's tmux is \(distro))")
        var r = t.run(["up", n, "--image", base, "--isolated", "--memory", "1G", "--tmux", "--detach", "--verbose"], timeout: 1800)
        check(r.code == 0, "up \(n) --image \(base) --tmux --detach (exit \(r.code)) \(r.code == 0 ? "" : (r.out + r.err).suffix(400).description)")
        check((r.out + r.err).contains("tools: tmux \(ToolsLayer.tmuxVersion) — for tmux sessions"), "the first start: tmux \(ToolsLayer.tmuxVersion) set up as a step")
        r = t.run(["tools", n])
        check(r.out.contains("tmux \(ToolsLayer.tmuxVersion)") && r.out.contains("for tmux sessions"), "doz tools \(n): tmux \(ToolsLayer.tmuxVersion), for tmux sessions (\(r.out.prefix(240).debugDescription))")
        r = t.run(["sessions", n])
        check(r.out.contains("\(GuestCommand.dozTmuxPath) -L doz-shell"), "the shell runs in Dozable's tmux (\(r.out.trimmingCharacters(in: .whitespacesAndNewlines).suffix(160)))")
        func ex(_ script: String, root: Bool = false) -> String {
            t.run(["exec", n] + (root ? ["--user", "root"] : []) + ["--", "sh", "-c", script], timeout: 60).out
        }
        let v = ex("tmux -L doz-shell display-message -p 'SERVER=#{version}'; tmux -V; readlink /usr/local/bin/tmux; /usr/bin/tmux -V")
        check(v.contains("SERVER=\(ToolsLayer.tmuxVersion)"), "the session's tmux server is \(ToolsLayer.tmuxVersion) (\(v.debugDescription))")
        check(v.contains("tmux \(ToolsLayer.tmuxVersion)\n\(GuestCommand.dozTmuxPath)"), "`tmux` on the PATH is Dozable's (/usr/local/bin/tmux → it)")
        check(v.contains("tmux \(distro)"), "the distro's own tmux is untouched (\(distro))")
        // doz's conf parses on both versions (source-file -n: parse only).
        let conf = ex("for x in \(GuestCommand.dozTmuxPath) /usr/bin/tmux; do $x -L ct -f /dev/null new-session -d 'sleep 30'; "
                      + "$x -L ct source-file -n \(GuestCommand.tmuxConfPath) 2>&1; echo \"rc=$?\"; $x -L ct kill-server; done")
        check(conf.components(separatedBy: "rc=0").count == 3 && !conf.lowercased().contains("unknown") && !conf.lowercased().contains("invalid"),
              "doz's tmux.conf parses on \(ToolsLayer.tmuxVersion) and on \(distro) (\(conf.debugDescription))")
        for (name, body) in [("q996", themeQuery), ("p7", plainStatus), ("w7", wrappedStatus)] {
            _ = ex("echo \(Data(body.utf8).base64EncodedString()) | base64 -d > /tmp/\(name).sh; chmod 755 /tmp/\(name).sh", root: true)
        }

        // ── The bridges through tmux 3.8, attached ──
        do {
            let c = try PTYClient(t, ["attach", n])
            defer { c.close() }
            check(c.wait(30) { $0.text.contains("[shell]") }, "attach: tmux's status bar ([shell])")
            c.type("printf '\\033]52;c;%s\\a' \"$(printf 'osc52 \(base)' | base64)\"; echo COPY-$((1+1))\r")
            check(c.wait(10) { $0.text.contains("COPY-2") } && c.wait(5) { _ in pasteboard() == "osc52 \(base)" },
                  "a copy (OSC 52) inside tmux \(ToolsLayer.tmuxVersion) reaches the Mac's clipboard (\(pasteboard().debugDescription))")
            c.type("printf 'xclip \(base)' | xclip -selection clipboard; echo XC-$((1+2))\r")
            check(c.wait(10) { $0.text.contains("XC-3") } && c.wait(5) { _ in pasteboard() == "xclip \(base)" },
                  "a copy with xclip (the shim) inside tmux reaches the Mac's clipboard (\(pasteboard().debugDescription))")
            c.type("xdg-open https://example.com/tmux38-\(base); echo OPEN-$((2+2))\r")
            check(c.wait(10) { $0.text.contains("OPEN-4") } && c.wait(5) { _ in openedLog().contains("open https://example.com/tmux38-\(base)") },
                  "xdg-open inside tmux reaches the Mac's browser")
            usleep(300_000)
            c.type("\u{1D}\u{1D}")
            check(c.exited(within: 10) == 0, "Ctrl-] Ctrl-] detaches")
        } catch { check(false, "pty: \(error)") }

        // ── The theme: tmux started (Dozable's, doz's conf) while this test is attached — this test is the terminal it
        //    asks (a session opened by doz starts its tmux before any viewer is there; deckhold answers nothing then) ──
        check(t.run(["config", "set", "--sandbox", n, "sessions.tmux", "false"]).code == 0, "sessions.tmux off for a plain shell")
        do {
            let c = try PTYClient(t, ["run", n, "--session", "th", "--", "sh"])
            defer { c.close() }
            usleep(1_500_000)
            c.type("tmux -L doz-th -f \(GuestCommand.tmuxConfPath) new-session -s th\r")
            check(c.wait(30) { $0.text.contains("\(esc)[?996n") }, "tmux \(ToolsLayer.tmuxVersion) asks the terminal for its theme (CSI ? 996 n)")
            check(c.text.contains("\(esc)[?2031h"), "…and subscribes to its changes (mode 2031)")
            check(c.wait(30) { $0.text.contains("[th]") }, "the session th, in tmux")
            for (word, code) in [("light", "2"), ("dark", "1")] {
                c.type("\(esc)[?997;\(code)n")                       // the terminal's answer (as Ghostty, kitty… send it)
                usleep(500_000)
                c.type("tmux display-message -p \"THEME-IS-#{client_theme}\"\r")
                check(c.wait(10) { $0.text.contains("THEME-IS-\(word)") }, "tmux took the terminal's \(word) theme")
                c.type("/tmp/q996.sh\r")
                let told = c.wait(10) { $0.text.contains("PANE=033[?997;\(code)n") }
                let seen = c.text.components(separatedBy: "PANE=").dropFirst().map { String($0.prefix(14)) }.joined(separator: " | ")
                check(told, "a program in the pane asking (CSI ? 996 n) is told \(word) (CSI ? 997 ; \(code) n) (\(seen.debugDescription))")
            }
            usleep(300_000)
            c.type("\u{1D}\u{1D}")
            _ = c.exited(within: 10)
        } catch { check(false, "pty: \(error)") }
        _ = t.run(["sessions", "end", n, "th", "--yes"], timeout: 60)
        check(t.run(["config", "set", "--sandbox", n, "sessions.tmux", "true"]).code == 0, "sessions.tmux on again")

        // ── OSC 7501, measured ──
        func status(_ s: String) -> String? { t.sessions(n).first { $0.name == s }?.status.map { "\($0.state.rawValue):\($0.app ?? "")" } }
        check(t.run(["run", n, "-d", "--session", "p7", "--", "/tmp/p7.sh"]).code == 0, "a program reporting OSC 7501 the plain way (Claude Code's, pi's), in tmux")
        check(t.run(["run", n, "-d", "--session", "w7", "--", "/tmp/w7.sh"]).code == 0, "a program reporting it wrapped for tmux's passthrough, in tmux")
        sleep(5)
        let ans = ex("cat /tmp/p7.ans")
        check(ans.hasPrefix("NO-ANSWER"), "inside tmux the program's question (OSC 7501 ; ?) reaches no terminal: tmux drops it (\(ans.trimmingCharacters(in: .whitespacesAndNewlines)))")
        check(status("p7") == nil, "…and its plain reports are dropped too: no status (\(status("p7") ?? "none"))")
        check(status("w7") == nil, "a wrapped report with doz's conf (allow-passthrough off): no status (\(status("w7") ?? "none"))")
        _ = ex("tmux -L doz-w7 set -g allow-passthrough on")
        check(t.waitFor(15) { status("w7") == "working:wrapped-probe" }, "with allow-passthrough on, a WRAPPED report reaches deckhold (\(status("w7") ?? "none")) — none of the agents wraps it")
        _ = ex("tmux -L doz-p7 set -g allow-passthrough on")
        sleep(3)
        check(status("p7") == nil, "…while a plain one is still dropped with passthrough on (\(status("p7") ?? "none"))")

        // ── A session already running in the distro's older tmux keeps it ──
        _ = ex("mv \(GuestCommand.dozTmuxPath) \(GuestCommand.dozTmuxPath).away", root: true)
        check(t.run(["run", n, "-d", "--session", "old", "--", "sleep", "600"]).code == 0, "Dozable's tmux away: a session starts in the distro's")
        r = t.run(["sessions", n])
        check(r.out.contains("/tmux -L doz-old") && !r.out.contains("\(GuestCommand.dozTmuxPath) -L doz-old"), "…by the distro's tmux's path")
        _ = ex("mv \(GuestCommand.dozTmuxPath).away \(GuestCommand.dozTmuxPath)", root: true)
        r = t.run(["exec", n, "--user", "root", "--", "sh", "-c", GuestCommand.tmuxPrepare(session: "old")])
        check(r.out.contains("tmux=sys:/usr/bin/tmux"), "Dozable's tmux back: the running \(distro) server of `old` keeps the distro's tmux (\(r.out.trimmingCharacters(in: .whitespacesAndNewlines)))")
        r = t.run(["exec", n, "--user", "root", "--", "sh", "-c", GuestCommand.tmuxPrepare(session: "fresh")])
        check(r.out.contains("tmux=doz"), "…and a new session gets Dozable's (\(r.out.trimmingCharacters(in: .whitespacesAndNewlines)))")
        r = t.run(["run", n, "-d", "--session", "old", "--", "sleep", "600"])
        check(r.code == 0 && !r.err.contains("already running in"), "opening `old` again is the same session (exit \(r.code)) \(r.err.prefix(200))")
        r = t.run(["sessions", "end", n, "old", "--yes"], timeout: 60)
        check(r.code == 0, "doz sessions end \(n) old (exit \(r.code)) \(r.err.prefix(200))")
        let gone = ex("/usr/bin/tmux -L doz-old ls >/dev/null 2>&1 && echo ALIVE || echo GONE")
        check(gone.contains("GONE"), "…and its \(distro) tmux server is gone (\(gone.trimmingCharacters(in: .whitespacesAndNewlines)))")
        t.run(["rm", n, "--yes"], timeout: 180)
    }
    // The tools layer changes no recipe: no image is stale.
    let r = t.run(["image", "ls"])
    check(r.code == 0 && !r.out.contains("older recipe"), "no image says \"older recipe\"")
}
