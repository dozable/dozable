// `doz-vmtest cli-daemon --doz PATH` (694, `make test-cli-daemon`; also part of `make test-cli`): the daemon's login item,
// no VM, through SEAMS only — a scratch LaunchAgents folder (DOZ_TEST_LAUNCH_AGENTS_DIR) and a FAKE launchctl
// (Scripts/fake-launchctl.py: it records every argv, keeps its own "loaded" state, and on `kickstart` runs the plist's
// ProgramArguments the way launchd would, in a desktop session — without DOZ_TEST_KEYCHAIN_LOCKED). Never the real
// ~/Library/LaunchAgents or launchctl. A scratch store, settings and HOME of its own under /tmp/dzo-PID-dm; always on (the
// Makefile's guarded "off" is removed for this suite's daemons only).
//
//    1. A command starts the daemon; it is still up after 3× the old idle timeout; NO plist (ask writes nothing); the
//       once-notice (through its test seam): not with --json, said once, then never again.
//    2. `daemon login-item on` → the plist (0644, the stable doz, no KeepAlive) and `bootstrap gui/<uid> …` logged.
//    3. The daemon killed; the plist's ProgramArguments run as launchd would → a daemon with parent 1; the job exits ≤ 2 s.
//    4. The 15-minute look with a daemon up → exit 0 in < 300 ms, the same pid.
//    5. `daemon stop` → held: the look starts nothing; a hold older than the boot (DOZ_TEST_BOOT_TIME) is ignored.
//    6. A DOZ_TEST_KEYCHAIN_LOCKED daemon with nothing live is replaced by the look; with a fenced session it is left.
//    7. A locked client's autostart with the item loaded → kickstart logged, the daemon unlocked.
//    8. A locked `daemon restart` against an unlocked daemon with no item loaded → refused, exit ≠ 0; with it → done there.
//    9. doz in a scratch Homebrew-shaped layout (Cellar + opt): the plist runs the opt path; a new keg linked in → a new
//       daemon within 20 s, from the stable path, running the new build.
//   10. `daemon.always_on off` → removed; on again → added. (With a kept session it stays: kept sessions come later — the
//       unit table pins it.)
//   11. `nuke --yes` and `uninstall --yes` remove only this store's label; another store's and an unrelated agent stay.
//   12. The menu bar app's job loaded → doz removes its own and never writes one; the app's program gone → doz adds its own.
//       The same with the job in the shape SMAppService gives it (a program relative to the bundle): owner app while an
//       installed copy of the app is in its place (a scratch Applications folder), absent once it is deleted.
//
// Every daemon it starts is stopped at the end; the scratch folders are removed.
import Darwin
import Foundation
import DozableKit
import DozableHost

func cliDaemonSuite(binary: String) async {
    print("cli: the daemon's login item (a scratch LaunchAgents folder, a fake launchctl)")
    let fm = FileManager.default
    let base = URL(fileURLWithPath: "/tmp/dzo-\(getpid())-dm")
    try? fm.removeItem(at: base)
    let root = base.appendingPathComponent("s")
    let agents = base.appendingPathComponent("agents")
    let statePath = base.appendingPathComponent("launchctl.json").path
    let lcLogPath = base.appendingPathComponent("launchctl.log").path
    let home = base.appendingPathComponent("home")
    for d in [root, agents, home, base.appendingPathComponent("w")] { try? fm.createDirectory(at: d, withIntermediateDirectories: true) }
    let fake = URL(fileURLWithPath: "Scripts/fake-launchctl.py").standardizedFileURL.path
    guard fm.isExecutableFile(atPath: fake) else { check(false, "the fake launchctl is at \(fake) (run from the repository)"); return }

    let h = CLIHarness(binary: binary, store: root)
    h.env.removeValue(forKey: "DOZ_DAEMON_ALWAYS_ON")                      // the default: on
    h.env.removeValue(forKey: "DOZ_TEST_KEYCHAIN_LOCKED")
    h.env["DOZ_DAEMON_IDLE"] = "0.05"                                        // 3 s: it would exit at once were it not always on
    h.env["DOZ_TEST_LAUNCH_AGENTS_DIR"] = agents.path
    h.env["DOZ_TEST_LAUNCHCTL"] = fake
    h.env["FAKE_LAUNCHCTL_STATE"] = statePath
    h.env["FAKE_LAUNCHCTL_LOG"] = lcLogPath
    h.env["DOZ_TEST_FENCE_HOME"] = home.path
    // The settings beside the store, not in it (nuke and uninstall remove both: one inside the other fails the second).
    h.env["XDG_CONFIG_HOME"] = base.appendingPathComponent("xdg").path
    let locked = CLIHarness(binary: binary, store: root)
    locked.env = h.env
    locked.env["DOZ_TEST_KEYCHAIN_LOCKED"] = "1"
    let store = DozableStore(root: root)
    let label = DaemonLoginItem.label(store)
    let plist = DaemonLoginItem.plistURL(store, folder: agents)
    let uid = getuid()

    func lcLog() -> [String] { ((try? String(contentsOfFile: lcLogPath, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }
    func state() -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: statePath)))) as? [String: Any] ?? [:]
    }
    func setState(_ s: [String: Any]) {
        if let d = try? JSONSerialization.data(withJSONObject: s) { try? d.write(to: URL(fileURLWithPath: statePath), options: .atomic) }
    }
    func loaded() -> [String: String] { state()["loaded"] as? [String: String] ?? [:] }
    func setLoaded(_ l: [String: String]) { var s = state(); s["loaded"] = l; setState(s) }
    func setApps(_ a: [String: String]) { var s = state(); s["apps"] = a; setState(s) }
    func pidFile() -> Int32? {
        (try? String(contentsOf: store.pidFile, encoding: .utf8)).flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
    func status() -> HostStatus? { h.json(["daemon", "status"], HostStatus.self) }
    /// The login item as `doz daemon login-item status --json` reads it (with or without a daemon).
    func item() -> LoginItemStatus? { h.json(["daemon", "login-item", "status"], LoginItemStatus.self) }
    func ourPlists() -> [String] { ((try? fm.contentsOfDirectory(atPath: agents.path)) ?? []).filter { $0.hasPrefix("com.dozable.") }.sorted() }
    func plistDict() -> [String: Any]? {
        (try? PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil)) as? [String: Any]
    }
    /// Kill the running daemon outright (no `daemon stop`: that would hold it) and wait for its lock to go.
    func killDaemon() {
        if let p = pidFile(), kill(p, 0) == 0 { kill(p, SIGKILL) }
        _ = h.waitFor(20) { !h.hostRunning }
    }
    /// The plist's ProgramArguments run as launchd would (a child of this suite here; its own session), env without the
    /// locked seam. Returns (exit, seconds).
    func runJob(extraEnv: [String: String] = [:]) -> (Int32, Double) {
        guard let argv = plistDict()?["ProgramArguments"] as? [String], let exe = argv.first else { return (-1, 0) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = Array(argv.dropFirst())
        var e = h.env
        e.removeValue(forKey: "DOZ_TEST_KEYCHAIN_LOCKED")
        for (k, v) in extraEnv { e[k] = v }
        p.environment = e
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        let t0 = Date()
        do { try p.run() } catch { return (-1, 0) }
        while p.isRunning && Date().timeIntervalSince(t0) < 120 { usleep(5_000) }
        if p.isRunning { p.terminate() }
        p.waitUntilExit()
        return (p.terminationStatus, Date().timeIntervalSince(t0))
    }
    func jobLog() -> String { (try? String(contentsOf: store.loginItemLog, encoding: .utf8)) ?? "" }
    var fenced: [String] = []
    defer {
        for s in fenced { h.run(["sessions", "end", "@mac", s, "--yes"], timeout: 30) }
        if h.hostRunning { h.run(["daemon", "stop"], timeout: 120) }
        killDaemon()
        check(!h.hostRunning, "login item: no daemon of this suite left running")
        try? fm.removeItem(at: base)
    }

    // 1. A command starts the daemon; always on; NO plist; the once-notice.
    var r = h.run(["daemon", "start"], timeout: 60)
    check(r.code == 0 && h.hostRunning, "login item 1: daemon start with default settings")
    let pid1 = pidFile()
    usleep(9_000_000)                                                       // 3× its old idle timeout
    check(h.hostRunning && pidFile() == pid1, "login item 1: still up after 9 s — 3× the idle timeout (pid \(pid1.map(String.init) ?? "?"))")
    check(ourPlists().isEmpty && !lcLog().contains { $0.hasPrefix("bootstrap") }, "login item 1: ask (the default) wrote nothing to LaunchAgents and loaded nothing (\(ourPlists()))")
    var st = status()
    check(st?.loginItem?.setting == "ask" && st?.loginItem?.installed == false && st?.held == false,
          "login item 1: daemon status --json carries loginItem (ask, not installed) and held false")
    let notice = CLIHarness(binary: binary, store: root)
    notice.env = h.env
    notice.env["DOZ_TEST_LOGIN_ITEM_NOTICE"] = "1"
    r = notice.run(["ls", "--json"])
    check(!r.err.contains("the daemon now stays running"), "login item 1: the once-notice is never said with --json")
    r = notice.run(["ls"])
    check(r.err.contains(LoginItemNoticeText.text), "login item 1: the once-notice on the first command (\(r.err.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80)))")
    r = notice.run(["ls"])
    check(!r.err.contains("the daemon now stays running"), "login item 1: …and never again")
    r = h.run(["ls"])
    check(!r.err.contains("the daemon now stays running"), "login item 1: a guarded run never says it (without its seam)")

    // 2. login-item on → the plist and `bootstrap gui/<uid> …`.
    r = h.run(["daemon", "login-item", "on"])
    let dict = plistDict()
    let argv = dict?["ProgramArguments"] as? [String]
    let mode = ((try? fm.attributesOfItem(atPath: plist.path))?[.posixPermissions] as? NSNumber)?.intValue
    check(r.code == 0 && ourPlists() == [label + ".plist"], "login item 2: login-item on → exactly one \(label).plist (\(r.out.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160)))")
    check(argv == [StableExecutable.path(for: binary), "daemon", "start", "--login-item", "--store", root.path] && mode == 0o644
            && dict?["KeepAlive"] == nil && dict?["Sockets"] == nil && dict?["MachServices"] == nil && dict?["RunAtLoad"] as? Bool == true
            && dict?["StartInterval"] as? Int == 900 && dict?["LimitLoadToSessionType"] as? String == "Aqua",
          "login item 2: the stable doz, 0644, RunAtLoad, every 900 s, Aqua, no KeepAlive/Sockets/MachServices (\(argv?.first ?? "none"), \(mode.map { String($0, radix: 8) } ?? "?"))")
    check(lcLog().contains("bootstrap gui/\(uid) \(plist.path)"), "login item 2: bootstrap gui/\(uid) <plist> logged")
    st = status()
    check(st?.loginItem?.owner == "doz" && st?.loginItem?.installed == true && st?.loginItem?.loaded == true && st?.loginItem?.stale == false,
          "login item 2: daemon status says installed, loaded, not stale")
    r = h.run(["daemon", "status"])
    check(r.out.contains("login item: ") && r.out.contains("loaded"), "login item 2: daemon status says it in words")

    // 3. The job as launchd runs it: a daemon with parent 1; the job exits within 2 s.
    killDaemon()
    var (code, took) = runJob()
    st = status()
    check(code == 0 && took <= 2.0, String(format: "login item 3: the job exited 0 in %.2f s", took))
    check(st?.parentPid == 1 && st?.launchedDetached == true, "login item 3: the daemon it started has parent launchd (1) (\(st?.parentPid.map(String.init) ?? "none"))")
    check(jobLog().contains("started the daemon (pid"), "login item 3: login-item.log says it started the daemon")

    // 4. The look with a daemon up: exit 0, < 300 ms, the same pid.
    let pid4 = pidFile()
    var times: [Double] = []
    for _ in 0..<3 { let (c, t) = runJob(); if c == 0 { times.append(t) } }
    times.sort()
    check(times.count == 3 && times[1] < 0.3 && pidFile() == pid4,
          String(format: "login item 4: the look with a daemon up — exit 0, median %.0f ms (< 300), the same pid", (times.count == 3 ? times[1] : 9) * 1000))

    // 5. daemon stop → held; the look starts nothing; a hold older than the boot is ignored.
    r = h.run(["daemon", "stop"], timeout: 120)
    check(r.code == 0 && r.out.contains("it stays stopped until a doz command or your next login") && fm.fileExists(atPath: store.heldFile.path),
          "login item 5: daemon stop while always on — held, and says so")
    (code, took) = runJob()
    usleep(1_500_000)
    check(code == 0 && !h.hostRunning && jobLog().contains("held"), "login item 5: the look starts nothing while held")
    let absent = h.run(["daemon", "status", "--json"])
    let a = (try? JSONSerialization.jsonObject(with: absent.outData)) as? [String: Any]
    check(a?["running"] as? Bool == false && a?["held"] as? Bool == true && a?["store"] as? String == root.path && a?["alwaysOn"] as? Bool == true
            && (a?["loginItem"] as? [String: Any])?["installed"] as? Bool == true,
          "login item 5: daemon status --json with NO daemon: store, held, alwaysOn, loginItem")
    (code, took) = runJob(extraEnv: ["DOZ_TEST_BOOT_TIME": String(Date().timeIntervalSince1970 + 5)])
    check(code == 0 && h.hostRunning && !fm.fileExists(atPath: store.heldFile.path),
          "login item 5: a hold from before the boot (DOZ_TEST_BOOT_TIME) is ignored — started, and the hold is gone")

    // 6. A locked daemon with nothing live is replaced by the look; with a fenced session it is left.
    killDaemon()
    let saved = loaded()
    setLoaded([:])                                                          // no item loaded: the locked client spawns as before
    r = locked.run(["daemon", "start"], timeout: 60)
    st = status()
    let lockedPid = st?.pid
    check(r.code == 0 && st?.keychainLocked == "ssh", "login item 6: a daemon started where the keychain is locked (\(st?.keychainLocked ?? "nil"))")
    setLoaded(saved)
    (code, took) = runJob()
    st = status()
    check(code == 0 && st != nil && st?.pid != lockedPid && st?.keychainLocked == nil,
          "login item 6: the look replaced the locked idle daemon (pid \(lockedPid.map(String.init) ?? "?") → \(st.map { String($0.pid) } ?? "none"), keychainLocked \(st?.keychainLocked ?? "nil"))")
    killDaemon()
    setLoaded([:])
    locked.run(["daemon", "start"], timeout: 60)
    setLoaded(saved)
    let lockedPid2 = status()?.pid
    r = locked.run(["run", "@mac", "-d", "--fenced", "--session", "lk", "--workdir", base.appendingPathComponent("w").path, "--", "/bin/sleep", "300"], timeout: 90)
    if r.code == 0 { fenced.append("lk") }
    st = status()
    if r.code == 0, st?.fencedSessions?.contains("lk") == true {
        (code, took) = runJob()
        check(status()?.pid == lockedPid2, "login item 6: with a fenced session the locked daemon is left (pid \(lockedPid2.map(String.init) ?? "?"))")
        h.run(["sessions", "end", "@mac", "lk", "--yes"], timeout: 30)
        fenced.removeAll()
    } else {
        check(false, "login item 6: a fenced session on the locked daemon (exit \(r.code): \(r.err.trimmingCharacters(in: .whitespacesAndNewlines).suffix(200)))")
    }

    // 7. A locked client's autostart with the item loaded → kickstart, an unlocked daemon.
    killDaemon()
    r = locked.run(["daemon", "start"], timeout: 60)
    st = status()
    check(r.code == 0 && r.err.contains("started the daemon in your desktop session (login item)") && lcLog().contains("kickstart gui/\(uid)/\(label)"),
          "login item 7: a locked client's start → kickstart gui/\(uid)/\(label), said (\(r.err.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120)))")
    check(st?.keychainLocked == nil && st?.parentPid == 1, "login item 7: the daemon is unlocked, parent launchd")

    // 8. A locked restart against an unlocked daemon: refused with no item loaded; done through the item with one.
    let pid8 = pidFile()
    setLoaded([:])
    r = locked.run(["daemon", "restart"], timeout: 60)
    check(r.code != 0 && r.err.contains("not restarted") && pidFile() == pid8,
          "login item 8: a locked daemon restart against an unlocked daemon, no item → refused (exit \(r.code)), the same pid")
    setLoaded(saved)
    r = locked.run(["daemon", "restart"], timeout: 120)
    st = status()
    check(r.code == 0 && st?.pid != pid8 && st?.keychainLocked == nil,
          "login item 8: with the item loaded the restart goes on — a new daemon, started there (keychainLocked \(st?.keychainLocked ?? "nil"))")

    // 10. always_on off → removed; on → added again.
    r = h.run(["config", "set", "daemon.always_on", "off"])
    check(r.code == 0 && ourPlists().isEmpty && lcLog().contains("bootout gui/\(uid)/\(label)") && r.out.contains("removed the login item"),
          "login item 10: daemon.always_on off (nothing kept) → removed, booted out, said")
    r = h.run(["config", "set", "daemon.always_on", "on"])
    check(r.code == 0 && ourPlists() == [label + ".plist"], "login item 10: daemon.always_on on → added again (daemon.login_item is on)")
    info("login item 10: with a kept session it stays — kept sessions come in a later release (DaemonLoginItemTests pins the rule)")

    // 12. The menu bar app's job.
    let appProgram = base.appendingPathComponent("Dozable.app-doz")
    fm.createFile(atPath: appProgram.path, contents: Data("#!/bin/sh\nexit 0\n".utf8), attributes: [.posixPermissions: 0o755])
    setApps([DaemonLoginItem.appLabel: appProgram.path])
    r = h.run(["daemon", "login-item", "on"])
    check(r.code == 0 && ourPlists().isEmpty && r.out.contains("the Dozable menu bar app starts the daemon at login") && item()?.owner == "app",
          "login item 12: the app's job loaded → doz removes its own, says the app starts it, owner app")
    r = h.run(["daemon", "login-item", "on"])
    check(ourPlists().isEmpty, "login item 12: …and never writes its own again")
    try? fm.removeItem(at: appProgram)
    r = h.run(["daemon", "login-item", "on"])
    check(ourPlists() == [label + ".plist"] && item()?.owner == "doz", "login item 12: the app's program gone → its job counts as absent; doz adds its own")
    // The shape launchd prints for the app's real job (SMAppService, a BundleProgram: no absolute program — `arguments`
    // start with the bare `Dozable`): it counts while an installed copy of the app is in its place, and not once it is gone.
    let appsDir = base.appendingPathComponent("Applications")
    let installedApp = appsDir.appendingPathComponent("Dozable.app")
    try? fm.createDirectory(at: installedApp.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
    if let info = try? PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.dozable.app"], format: .xml, options: 0) {
        try? info.write(to: installedApp.appendingPathComponent("Contents/Info.plist"))
    }
    fm.createFile(atPath: installedApp.appendingPathComponent("Contents/MacOS/Dozable").path, contents: Data("#!/bin/sh\nexit 0\n".utf8),
                  attributes: [.posixPermissions: 0o755])
    let appsBefore = h.env["DOZ_TEST_APPLICATIONS_DIR"]
    h.env["DOZ_TEST_APPLICATIONS_DIR"] = appsDir.path
    setApps([DaemonLoginItem.appLabel: "(bundle)"])
    r = h.run(["daemon", "login-item", "on"])
    var smappItem = item()
    check(r.code == 0 && ourPlists().isEmpty && smappItem?.owner == "app"
          && smappItem?.note?.contains(installedApp.appendingPathComponent("Contents/MacOS/Dozable").path) == true,
          "login item 12: the app's SMAppService job (program relative to its bundle) with the app installed → doz removes its own, owner app (\(smappItem?.note ?? "no note"))")
    try? fm.removeItem(at: installedApp)
    r = h.run(["daemon", "login-item", "on"])
    smappItem = item()
    check(ourPlists() == [label + ".plist"] && smappItem?.owner == "doz",
          "login item 12: …the app deleted without unregistering → its job counts as absent; doz adds its own again")
    h.env["DOZ_TEST_APPLICATIONS_DIR"] = appsBefore
    setApps([:])

    // 9. A Homebrew-shaped layout: the plist runs the opt path; a new keg linked in → the daemon restarts from it.
    await loginItemStablePathChecks(h, binary: binary, base: base, store: store, plist: plist, killDaemon: killDaemon, pidFile: pidFile)

    // 11. nuke and uninstall remove only this label.
    killDaemon()
    let decoyStore = agents.appendingPathComponent("com.dozable.daemon.deadbeef.plist")
    let unrelated = agents.appendingPathComponent("com.example.other.plist")
    try? Data("other store".utf8).write(to: decoyStore)
    try? Data("unrelated".utf8).write(to: unrelated)
    r = h.run(["daemon", "login-item", "on"])
    check(fm.fileExists(atPath: plist.path), "login item 11: in place before nuke")
    r = h.run(["nuke", "--yes"], timeout: 180)
    check(r.code == 0 && !fm.fileExists(atPath: plist.path) && fm.fileExists(atPath: decoyStore.path) && fm.fileExists(atPath: unrelated.path),
          "login item 11: nuke --yes removed this store's item only (\(r.code))")
    check(!lcLog().contains { $0.contains("deadbeef") || $0.contains("com.example") }, "login item 11: another store's label never named to launchd")
    try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    r = h.run(["daemon", "login-item", "on"])
    h.run(["daemon", "start"], timeout: 60)                               // a store uninstall recognises (and a daemon it stops)
    check(fm.fileExists(atPath: plist.path), "login item 11: in place before uninstall")
    r = h.run(["uninstall", "--yes"], timeout: 180)
    check(r.code == 0 && !fm.fileExists(atPath: plist.path) && fm.fileExists(atPath: decoyStore.path) && fm.fileExists(atPath: unrelated.path)
            && r.out.contains("this store's login item") && r.out.contains("another store's login item"),
          "login item 11: uninstall --yes listed and removed this store's item only; the other store's listed, kept (\(r.code))")
}

/// What the notice says (the CLI's own text; kept here so a change to it is a change to this check too).
enum LoginItemNoticeText {
    static let text = "doz: the daemon now stays running. To also start it when you log in (sandboxes and kept sessions come back after the Mac restarts): doz daemon login-item on"
}

/// Row 9: doz in `<base>/brew/Cellar/doz/0.0.1/libexec/doz/doz` with `<base>/brew/opt/doz` linked to it — a Homebrew install's
/// shape. `login-item on` from it writes the opt path; a new keg (0.0.2) linked in its place → the always-on daemon restarts
/// in place from the opt path, running the new build, within 20 s.
func loginItemStablePathChecks(_ h: CLIHarness, binary: String, base: URL, store: DozableStore, plist: URL,
                               killDaemon: () -> Void, pidFile: () -> Int32?) async {
    let fm = FileManager.default
    let brew = base.appendingPathComponent("brew")
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
    func keg(_ v: String) -> Bool {
        let dir = brew.appendingPathComponent("Cellar/doz/\(v)/libexec/doz")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for item in (try? fm.contentsOfDirectory(atPath: src.path)) ?? [] where item.hasSuffix(".bundle") || item == "VERSION" || item == "deckhold-mac" {
            try? fm.copyItem(at: src.appendingPathComponent(item), to: dir.appendingPathComponent(item))
        }
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
    killDaemon()
    guard keg("0.0.1"), link("0.0.1") else { check(false, "login item 9: a Homebrew-shaped copy of this build"); return }
    let opt = brew.appendingPathComponent("opt/doz/libexec/doz/doz").path
    // doz resolves its own path (/tmp is /private/tmp), then maps the keg to its formula's opt link above it.
    let optPrivate = opt.hasPrefix("/tmp/") ? "/private" + opt : opt
    func isOpt(_ p: String?) -> Bool { p == opt || p == optPrivate }
    let b = CLIHarness(binary: opt, store: store.root)
    b.env = h.env
    var r = b.run(["daemon", "login-item", "on"])
    let argv = ((try? PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil)) as? [String: Any])?["ProgramArguments"] as? [String]
    check(r.code == 0 && isOpt(argv?.first), "login item 9: from a keg, the plist runs the formula's opt path, not the keg (\(argv?.first ?? "none"))")
    r = b.run(["daemon", "start"], timeout: 60)
    let before = b.json(["daemon", "status"], HostStatus.self)
    check(r.code == 0 && before?.executable?.contains("/Cellar/doz/0.0.1/") == true, "login item 9: a daemon runs from the 0.0.1 keg (\(before?.executable ?? "?"))")
    guard let oldPid = before?.pid else { return }
    usleep(1_000_000)
    check(keg("0.0.2") && link("0.0.2"), "login item 9: a new keg linked in (brew upgrade's shape)")
    let t0 = Date()
    let moved = h.waitFor(20) { kill(oldPid, 0) != 0 && pidFile().map { $0 != oldPid && kill($0, 0) == 0 } == true }
    usleep(1_000_000)
    let after = b.json(["daemon", "status"], HostStatus.self)
    check(moved && after?.executable?.contains("/Cellar/doz/0.0.2/") == true && after?.parentPid == 1,
          String(format: "login item 9: a new daemon within %.1f s, from the stable path, running the new keg (%@)", Date().timeIntervalSince(t0), after?.executable ?? "none"))
    check(after?.loginItem?.stale == false && isOpt(after?.loginItem?.program), "login item 9: the plist is not stale after the upgrade (it names the opt path)")
    killDaemon()
}
