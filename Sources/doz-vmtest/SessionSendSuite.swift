import Foundation
import DozableHost

/// 678 B5 (`make test-cli-sessions`, and alone `doz-vmtest cli-sessionsend`): `doz sessions send` types into a held
/// session and returns only after deckhold's acknowledgement; `doz sessions screen` reads the screen now — or the last
/// saved one, said so, waking nothing (unless --wake). A lab sandbox in a store of its own (`/tmp/dzo-PID-sn`).
func cliSessionSendSuite(binary: String) async {
    let t = onboardingHarness(binary, "sn", seed: ["kernels", "content", "state.json", "initfs.ext4", "golden"])
    defer {
        t.run(["host", "stop"], timeout: 300)
        try? FileManager.default.removeItem(at: t.store)
    }
    print("cli: sessions send / sessions screen (678)")
    check(t.run(["onboard", "--no-base", "--yes"], timeout: 120).code == 0, "a scratch store, onboarded")
    check(t.run(["create", "sn", "--image", "lab", "--isolated", "--memory", "512M", "--start"], timeout: 900).code == 0, "create sn --start")
    func screen(_ s: String, until want: String, wake: Bool = false) -> CLIRun {
        var r = CLIRun(code: -1, out: "", err: "", outData: Data())
        let t0 = Date()
        repeat {
            r = t.run(["sessions", "screen", "sn", s] + (wake ? ["--wake"] : []), timeout: 120)
            if r.out.contains(want) { break }
            usleep(250_000)
        } while Date().timeIntervalSince(t0) < 8
        return r
    }

    check(t.run(["run", "sn", "-d", "--session", "rd", "--", "sh", "-c", "read x; echo got:$x; sleep 600"]).code == 0, "a session that reads one line")
    var r = t.run(["sessions", "send", "sn", "rd", "--text", "hi", "--enter"], timeout: 60)
    check(r.code == 0 && r.out.contains("sent 3 bytes to rd in sn"), "send --text hi --enter: acknowledged (\(r.out.trimmingCharacters(in: .whitespacesAndNewlines)))")
    r = screen("rd", until: "got:hi")
    check(r.code == 0 && r.out.contains("got:hi") && !r.err.contains("not live"), "screen shows the program's answer, live")
    r = t.run(["sessions", "screen", "sn", "rd", "--json"], timeout: 60)
    let live = try? HostWire.decoder.decode(SessionLive.self, from: r.outData)
    check(live?.live == true && live?.cols != nil && live?.cursorX != nil && live?.screen == "primary" && live?.text.contains("got:hi") == true,
          "--json: live, with the size, the cursor and the screen (\(live.map { "\($0.cols ?? 0)x\($0.rows ?? 0) cursor \($0.cursorX ?? 0),\($0.cursorY ?? 0)" } ?? "none"))")
    check(!r.out.contains("cursor="), "the dump's cursor line is parsed out of the text")
    r = t.run(["sessions", "send", "sn", "nope", "--text", "x"], timeout: 60)
    check(r.code == 2 && r.err.contains("no session nope"), "a session that is not there: exit 2 (\(r.code))")
    r = t.run(["sessions", "send", "sn", "rd", "--keys", "hyper"], timeout: 60)
    check(r.code == 64, "an unknown key is a usage error (\(r.code))")

    // A line-at-a-time reader: --then-screen reads the screen back in the same call.
    check(t.run(["run", "sn", "-d", "--session", "loop", "--", "sh", "-c", "while read x; do echo got:$x; done"]).code == 0, "a session that echoes every line")
    r = t.run(["sessions", "send", "sn", "loop", "--text", "yo", "--enter", "--then-screen"], timeout: 60)
    check(r.code == 0 && r.out.contains("got:yo"), "--then-screen: the screen after the send, in the same call")
    r = t.run(["sessions", "send", "sn", "loop", "--text", "js", "--enter", "--then-screen=800", "--json"], timeout: 60)
    let j = (try? JSONSerialization.jsonObject(with: r.outData)) as? [String: Any]
    check(r.code == 0 && (j?["bytes"] as? Int) == 3 && ((j?["screen"] as? [String: Any])?["text"] as? String)?.contains("got:js") == true,
          "--json: the receipt and, under screen, the screen")

    // A TUI in raw mode: a 236-byte line and its Enter come as two reads (in one, a TUI takes the CR as pasted).
    check(t.run(["run", "sn", "-d", "--session", "tui", "--", "sh", "-c", fakeTUI]).code == 0, "a fake TUI that prints the size of each read")
    usleep(500_000)
    r = t.run(["sessions", "send", "sn", "tui", "--text", String(repeating: "w", count: 236), "--enter"], timeout: 60)
    check(r.code == 0, "send a 236-byte line --enter")
    r = screen("tui", until: "R:1\n")
    let reads = r.out.split(separator: "\n").map(String.init)
    check(reads.contains("R:236") && reads.contains("R:1") && !reads.contains("R:237"),
          "the Enter is a read of its own, after the text (\(reads.filter { $0.hasPrefix("R:") }.joined(separator: " ")))")
    t.run(["sessions", "end", "sn", "tui", "--yes"], timeout: 60)

    // sessions wait: a program that reports done (OSC 7501) a moment after it starts.
    check(t.run(["run", "sn", "-d", "--session", "rep", "--", "sh", "-c", "sleep 2; printf '\\033]7501;state=done:app=fake\\033\\\\'; sleep 600"]).code == 0,
          "a session that reports done after 2 s")
    r = t.run(["sessions", "wait", "sn", "rep", "--until", "done", "--timeout", "30"], timeout: 60)
    check(r.code == 0 && r.out.contains("done"), "sessions wait sn rep --until done: returns when it reports done (\(r.code))")
    r = t.run(["sessions", "wait", "sn", "rep", "--until", "blocked", "--timeout", "2"], timeout: 60)
    check(r.code == 124, "--timeout passes first: exit 124 (\(r.code))")
    t.run(["sessions", "end", "sn", "rep", "--yes"], timeout: 60)

    // Into a HIBERNATED sandbox: it wakes and the text arrives — 5 of 5.
    var ok = 0
    for i in 1...5 {
        guard t.run(["hibernate", "sn"], timeout: 180).code == 0 else { continue }
        let s = t.run(["sessions", "send", "sn", "loop", "--text", "w\(i)", "--enter", "--json"], timeout: 180)
        let w = (try? JSONSerialization.jsonObject(with: s.outData)) as? [String: Any]
        if s.code == 0, w?["woke"] as? Bool == true, screen("loop", until: "got:w\(i)").out.contains("got:w\(i)") { ok += 1 }
    }
    check(ok == 5, "a send into a hibernated sandbox wakes it and the text arrives: \(ok) of 5")

    // Asleep: screen says so and wakes nothing; --no-wake refuses; --wake reads it live.
    check(t.run(["hibernate", "sn"], timeout: 180).code == 0, "hibernate sn")
    r = t.run(["sessions", "screen", "sn", "loop"], timeout: 60)
    check(r.code == 0 && r.err.contains("not live") && r.out.contains("got:w5"), "screen while hibernated: the saved screen, and it says so")
    check(t.row("sn")?.phase == "hibernated", "…and nothing was woken (\(t.row("sn")?.phase ?? "?"))")
    r = t.run(["sessions", "send", "sn", "loop", "--text", "x", "--no-wake"], timeout: 60)
    check(r.code == 3, "--no-wake on a hibernated sandbox: exit 3 (\(r.code))")
    r = t.run(["sessions", "screen", "sn", "loop", "--wake", "--json"], timeout: 180)
    let woken = try? HostWire.decoder.decode(SessionLive.self, from: r.outData)
    check(woken?.live == true && woken?.woke == true && t.row("sn")?.phase == "running", "screen --wake: woken, read live")

    check(t.run(["shutdown", "sn", "--yes"], timeout: 120).code == 0, "shutdown sn")
    r = t.run(["sessions", "screen", "sn", "loop"], timeout: 60)
    check(r.code == 3, "a shut-down sandbox has no sessions: exit 3 (\(r.code))")
    t.run(["rm", "sn", "--yes"], timeout: 120)
}
