// 714 — `make test-cli-alwayson` part 4: the dashboard follows an upgrade. No VM, no browser (`--no-open`, and the
// browser seam), the suite's scratch store, a Homebrew-shaped copy of this build in `<store>/brew` (Cellar + opt, each keg
// stamped with its own VERSION):
//
//   a. `doz ui --detach` started from the formula's opt path runs the 0.0.1 keg, its argv the OPT path (not the keg);
//   b. a new keg (0.0.2) linked in with no page open: the dashboard restarts ITSELF (same pid) into the new keg;
//   c. a dashboard that would not restart by itself yet: 0.0.3 linked in, `doz ui restart` → the same pid runs 0.0.3 —
//      the doz installed now, not the keg it came from (the owner's dashboard stayed 0.51.8 through two upgrades);
//   d. `doz ui stop` — no dashboard of this suite left running.
import Darwin
import Foundation
import DozableKit
import DozableHost

func dashboardFollowsUpgradeChecks(_ h: CLIHarness, root: URL, binary: String) {
    print("cli: the dashboard follows an upgrade")
    let fm = FileManager.default
    let brew = root.appendingPathComponent("brew")
    let src = URL(fileURLWithPath: binary).deletingLastPathComponent()
    let entitlements = URL(fileURLWithPath: "Scripts/doz.entitlements").standardizedFileURL.path
    func sh(_ argv: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: argv[0])
        p.arguments = Array(argv.dropFirst())
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }
    /// A signed copy of this build as keg `v` of the formula doz, its own VERSION stamp.
    func keg(_ v: String) -> Bool {
        let dir = brew.appendingPathComponent("Cellar/doz/\(v)/libexec/doz")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for item in (try? fm.contentsOfDirectory(atPath: src.path)) ?? [] where item.hasSuffix(".bundle") || item == "deckhold-mac" {
            try? fm.copyItem(at: src.appendingPathComponent(item), to: dir.appendingPathComponent(item))
        }
        try? "\(v)\n".write(to: dir.appendingPathComponent("VERSION"), atomically: true, encoding: .utf8)
        let t = dir.appendingPathComponent("doz").path
        return sh(["/bin/cp", binary, t]) == 0 && sh(["/usr/bin/codesign", "--force", "--sign", "-", "--entitlements", entitlements, t]) == 0
    }
    /// `opt/doz` → `../Cellar/doz/<v>`, swapped by rename as Homebrew's link is.
    func link(_ v: String) -> Bool {
        try? fm.createDirectory(at: brew.appendingPathComponent("opt"), withIntermediateDirectories: true)
        let tmp = brew.appendingPathComponent("opt/.doz.new").path
        unlink(tmp)
        return symlink("../Cellar/doz/\(v)", tmp) == 0 && rename(tmp, brew.appendingPathComponent("opt/doz").path) == 0
    }
    let opt = brew.appendingPathComponent("opt/doz/libexec/doz/doz").path
    func isOpt(_ p: String?) -> Bool { p == opt || p == "/private" + opt }
    /// The running dashboard's pid (its lock records it).
    func uiPid() -> Int32? {
        (try? String(contentsOf: root.appendingPathComponent("ui.lock"), encoding: .utf8))
            .flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }.flatMap { $0 > 0 && kill($0, 0) == 0 ? $0 : nil }
    }
    /// The file a process runs (resolved by the kernel: the keg's).
    func program(_ pid: Int32) -> String? {
        var b = [CChar](repeating: 0, count: 4096)
        return proc_pidpath(pid, &b, 4096) > 0 ? String(cString: b) : nil
    }
    /// Its argv[0].
    func argv0(_ pid: Int32) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-o", "command=", "-p", String(pid)]
        let o = Pipe()
        p.standardOutput = o
        try? p.run()
        let d = o.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: d, as: UTF8.self).split(separator: " ").first.map(String.init)
    }
    func runs(_ v: String, _ pid: Int32) -> Bool { program(pid)?.contains("/Cellar/doz/\(v)/libexec/doz/doz") == true }
    let log = root.appendingPathComponent("ui.log")

    guard keg("0.0.1"), link("0.0.1") else { check(false, "dashboard: a Homebrew-shaped copy of this build"); return }
    let b = CLIHarness(binary: opt, store: root)
    b.env = h.env
    b.env["DOZ_TEST_BROWSER_LOG"] = root.appendingPathComponent("browser.log").path
    b.env["DOZ_TEST_UI_PROGRAM_CHECK"] = "2"
    defer {
        b.run(["ui", "stop"], timeout: 30)
        check(uiPid() == nil, "dashboard: no doz ui of this suite left running")
    }

    // a. started from the opt path: the 0.0.1 keg runs, argv[0] the opt path.
    var r = b.run(["ui", "--detach", "--no-open"], timeout: 60)
    guard r.code == 0, let pid = uiPid() else { check(false, "dashboard: doz ui --detach --no-open from the opt path (\(r.code))"); return }
    check(runs("0.0.1", pid) && isOpt(argv0(pid)),
          "dashboard a: the detached doz ui runs the 0.0.1 keg, started by the formula's opt path (\(argv0(pid) ?? "?"))")

    // b. a new keg linked in, no page open → it restarts itself (the same process) into it.
    usleep(1_000_000)
    check(keg("0.0.2") && link("0.0.2"), "dashboard b: a new keg linked in (brew upgrade's shape)")
    let t0 = Date()
    let moved = h.waitFor(30) { runs("0.0.2", pid) && uiPid() == pid }
    let said = (try? String(contentsOf: log, encoding: .utf8))?.contains("a new doz was installed") == true
    check(moved && said, String(format: "dashboard b: with no page open it restarted itself into 0.0.2 within %.1f s, same pid %d, its log says why", Date().timeIntervalSince(t0), pid))
    let back = h.waitFor(20) { b.run(["ui", "status"]).out.contains("doz ui is running at") }
    check(back && uiPid() == pid, "dashboard b: doz ui answers again after its restart, the same pid")

    // c. `doz ui restart` runs the doz installed now (a dashboard that would not restart by itself for a while).
    b.run(["ui", "stop"], timeout: 30)
    b.env["DOZ_TEST_UI_PROGRAM_CHECK"] = "600"
    r = b.run(["ui", "--detach", "--no-open"], timeout: 60)
    guard r.code == 0, let pid2 = uiPid() else { check(false, "dashboard c: doz ui --detach again (\(r.code))"); return }
    usleep(1_000_000)
    check(keg("0.0.3") && link("0.0.3"), "dashboard c: another keg linked in")
    check(runs("0.0.2", pid2), "dashboard c: still 0.0.2 before the restart")
    r = b.run(["ui", "restart"], timeout: 60)
    _ = h.waitFor(10) { runs("0.0.3", pid2) }
    check(r.code == 0 && runs("0.0.3", pid2) && uiPid() == pid2 && isOpt(argv0(pid2)),
          "dashboard c: doz ui restart → the same pid runs the 0.0.3 keg through the opt path (\(program(pid2) ?? "?"))")
}
