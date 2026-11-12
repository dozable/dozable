import DozableHost
import DozableKit
import Foundation

/// 678: `doz exec --timeout` counts from when doz started and covers the whole exec — the wake or the start included —
/// and the host enforces it: a running command is killed; a start or a wake under way goes on to its end; a client
/// that was stopped past its deadline still ends with 124. A lab sandbox in a store of its own (`/tmp/dzo-PID-x`).
func cliExecTimeoutSuite(binary: String) async {
    let t = onboardingHarness(binary, "x", seed: ["kernels", "content", "state.json", "initfs.ext4", "golden"])
    defer {
        t.run(["host", "stop"])
        try? FileManager.default.removeItem(at: t.store)
    }
    print("cli: exec --timeout — counted from the start, enforced by the host, the command killed, a wake or start goes on")
    check(t.run(["onboard", "--no-base", "--yes"], timeout: 120).code == 0, "a scratch store, onboarded")
    var r = t.run(["create", "xt", "--image", "lab", "--isolated", "--memory", "512M", "--start", "--json"], timeout: 600)
    check(r.code == 0 && t.row("xt")?.phase == "running", "create --start: xt running")

    func guestSleeps() -> String {
        // BusyBox ps lists each command line; the bracket keeps grep from finding itself.
        t.run(["exec", "xt", "--", "sh", "-c", "ps | grep -c '[s]leep 3[0-9]' || true"], timeout: 60).out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // A running command: 124 at the deadline, and it is gone from the guest.
    var t0 = Date()
    r = t.run(["exec", "xt", "--timeout", "3", "--", "sleep", "30"], timeout: 60)
    var took = Date().timeIntervalSince(t0)
    check(r.code == 124 && took < 5, String(format: "exec --timeout 3 -- sleep 30: exit %d after %.1f s (124 in < 5 s)", r.code, took))
    check(r.err.contains("timed out after 3 s (counted from when doz started)") && r.err.contains("killed"), "it says so: \(r.err.trimmingCharacters(in: .whitespacesAndNewlines).suffix(200))")
    check(guestSleeps() == "0", "the guest's sleep is gone (killed, not left running)")
    r = t.run(["exec", "xt", "--timeout", "2", "--json", "--", "sleep", "31"], timeout: 60)
    let j = (try? JSONSerialization.jsonObject(with: r.outData)) as? [String: Any]
    check(r.code == 124 && j?["timedOut"] as? Bool == true && j?["timedOutDuring"] as? String == "running",
          "--json: 124 with timedOut true, during running (\(r.out.prefix(200)))")
    r = t.run(["exec", "xt", "--timeout", "20", "--json", "--", "sh", "-c", "exit 124"], timeout: 60)
    let own = (try? JSONSerialization.jsonObject(with: r.outData)) as? [String: Any]
    check(r.code == 124 && own?["timedOut"] == nil, "a program's own 124: no timedOut in --json")
    check(guestSleeps() == "0", "no sleep left after the --json one either")

    // A cold start that outlasts the deadline: 124 from the host, and the start goes on to its end. A lab boots in
    // under a second, so the host is restarted with its guarded seam holding each wake or start back 3 s.
    t.env["DOZ_TEST_EXEC_LIFECYCLE_DELAY_MS"] = "3000"
    check(t.run(["host", "stop"], timeout: 120).code == 0, "host stop (the next one holds a wake or start back 3 s)")
    check(t.run(["shutdown", "xt", "--yes"], timeout: 120).code == 0, "shutdown xt")
    t0 = Date()
    r = t.run(["exec", "xt", "--timeout", "1", "--json", "--", "true"], timeout: 60)
    took = Date().timeIntervalSince(t0)
    let s = (try? JSONSerialization.jsonObject(with: r.outData)) as? [String: Any]
    check(r.code == 124 && s?["timedOutDuring"] as? String == "starting" && took < 3,
          String(format: "exec --timeout 1 on an off sandbox: %d, during %@, after %.1f s", r.code, (s?["timedOutDuring"] as? String) ?? "?", took))
    var running = false
    for _ in 0..<120 where !running { if t.row("xt")?.phase == "running" { running = true } else { usleep(500_000) } }
    check(running, "the start went on: xt runs")

    // A wake that outlasts the deadline (a hibernated sandbox).
    check(t.run(["hibernate", "xt"], timeout: 120).code == 0, "hibernate xt")
    t0 = Date()
    r = t.run(["exec", "xt", "--timeout", "1", "--json", "--", "true"], timeout: 60)
    took = Date().timeIntervalSince(t0)
    let w = (try? JSONSerialization.jsonObject(with: r.outData)) as? [String: Any]
    check(r.code == 124 && w?["timedOutDuring"] as? String == "waking" && took < 3,
          String(format: "exec --timeout 1 on a hibernated sandbox: %d, during %@, after %.1f s", r.code, (w?["timedOutDuring"] as? String) ?? "?", took))
    running = false
    for _ in 0..<120 where !running { if t.row("xt")?.phase == "running" { running = true } else { usleep(500_000) } }
    check(running, "the wake went on: xt runs")

    // A client stopped past its deadline: 124 when it runs again (the host's answer, or its own watchdog).
    let p = t.process(["exec", "xt", "--timeout", "3", "--", "sleep", "32"])
    let o = Pipe(), e = Pipe()
    p.standardOutput = o
    p.standardError = e
    p.standardInput = FileHandle.nullDevice
    let oc = PipeCollector(o.fileHandleForReading), ec = PipeCollector(e.fileHandleForReading)
    do {
        try p.run()
        usleep(500_000)
        kill(p.processIdentifier, SIGSTOP)
        sleep(10)
        t0 = Date()
        kill(p.processIdentifier, SIGCONT)
        let until = Date().addingTimeInterval(10)
        while p.isRunning && Date() < until { usleep(20_000) }
        if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        p.waitUntilExit()
        oc.wait(5); ec.wait(5)
        took = Date().timeIntervalSince(t0)
        check(p.terminationStatus == 124 && took < 4,
              String(format: "a client stopped 10 s with --timeout 3: exit %d %.1f s after it ran again", p.terminationStatus, took))
        check(ec.text.contains("timed out after 3 s"), "…and says so: \(ec.text.trimmingCharacters(in: .whitespacesAndNewlines).suffix(160))")
    } catch { check(false, "could not run the client: \(error)") }
    check(guestSleeps() == "0", "the stopped client's sleep is gone too")

    // An ordinary exec is unchanged.
    r = t.run(["exec", "xt", "--json", "--", "echo", "ok"], timeout: 120)
    let ok = (try? JSONSerialization.jsonObject(with: r.outData)) as? [String: Any]
    check(r.code == 0 && ok?["stdout"] as? String == "ok\n" && ok?["timedOut"] == nil, "an exec inside its deadline: as before")
}
