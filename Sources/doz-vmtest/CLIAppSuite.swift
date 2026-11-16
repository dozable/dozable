// `doz-vmtest cli-app --doz PATH --app PATH/Dozable.app` (`make test-cli-app`): the menu bar app with NO screen and no VM —
// its executable run only in its non-GUI modes (`--dump-menu`, `--run-action`, in a guarded run: it refuses to show the
// menu), against the signed `make cli` doz and against FAKE ones, in a scratch store, settings, LaunchAgents and
// Applications folder of its own (/tmp/dzo-PID-ap). Never /Applications, never this Mac's own doz.
//
//   1. No doz (the seam pointing nowhere; and no seam at all — a test never finds this Mac's doz): "doz is not
//      installed", the hollow icon, no daemon action. Then the real doz on a fresh store: "Daemon stopped", Start enabled,
//      nothing started, nothing registered (no plist in the scratch LaunchAgents folder).
//   2. `--run-action start` (the app in a process group of its own) → a daemon whose parent is launchd, in neither the
//      app's group nor its session; the app's group killed → the daemon is still up. The menu says it runs.
//   3. `--run-action stop` → stopped and HELD (always on): the header says so.
//   5. A FAKE old doz (0.50.3, `{"running":false}`) → the too-old line, and Start, Stop, Restart and the dashboard still
//      offered as the state allows; the fake's argv log shows doz run with an argv (no shell) and the refreshes marked as
//      not the person's commands.
//   7. Open Dashboard through the browser seam: exactly one `open http://127.0.0.1:N` line, no link or token anywhere —
//      not in the seam's file, the app's output or its log (os_log, when `log show` can read it); `doz ui stop`.
//   8. doz in a scratch prefix replaced BY RENAME (a new file and VERSION) → the next dump shows the new version, and a
//      newer copy of the app beside it → "Update Menu Bar App (X → Y)".
//   9. `doz app install --dest` (the copy beside that doz: verified, its quarantine mark removed, installed; --open with
//      no open seam STOPPED by test safety before anything happens; again with a "running" copy — a stand-in process
//      OUTSIDE any bundle (DOZ_TEST_APP_STANDIN) — and --open: quit, swapped by rename — a new file — and one line in the
//      open seam, nothing opened; a test never asks macOS to open an app, nor runs a program inside a scratch bundle), a tampered copy
//      refused (the installed one unchanged), no destination in a test run refused, `doz app status --json`,
//      `doz app uninstall --dest`, and `doz uninstall` listing and removing it.
//
// Every daemon and UI it starts is stopped at the end; the scratch folders are removed.
import Darwin
import Foundation
import DozableKit
import DozableHost

func cliAppSuite(binary: String, app: String) async {
    print("cli: the menu bar app (no screen — --dump-menu and --run-action only)")
    let fm = FileManager.default
    let base = URL(fileURLWithPath: "/tmp/dzo-\(getpid())-ap")
    try? fm.removeItem(at: base)
    let root = base.appendingPathComponent("s")
    let agents = base.appendingPathComponent("agents")
    let apps = base.appendingPathComponent("Applications")
    for d in [root, agents, apps] { try? fm.createDirectory(at: d, withIntermediateDirectories: true) }
    let appExe = URL(fileURLWithPath: app).appendingPathComponent("Contents/MacOS/Dozable").path
    guard fm.isExecutableFile(atPath: appExe) else { check(false, "the menu bar app is at \(appExe) (make app)"); return }

    let h = CLIHarness(binary: binary, store: root)
    h.env.removeValue(forKey: "DOZ_DAEMON_ALWAYS_ON")                       // the default: on (a stop is then held)
    h.env["DOZ_TEST_LAUNCH_AGENTS_DIR"] = agents.path
    h.env["XDG_CONFIG_HOME"] = base.appendingPathComponent("xdg").path
    h.env["DOZ_TEST_APPLICATIONS_DIR"] = apps.path
    h.env["DOZ_TEST_GUARD"] = "1"
    h.env.removeValue(forKey: "DOZ_TEST_REAL_MAC")
    let version = h.run(["--version"]).out.trimmingCharacters(in: .whitespacesAndNewlines)
    let store = DozableStore(root: root)

    /// The app's executable with this suite's environment; `doz` is the seam DOZ_MENUBAR_DOZ (nil: unset).
    func appRun(_ args: [String], doz: String?, extra: [String: String] = [:], timeout: Double = 120) -> CLIRun {
        let a = CLIHarness(binary: appExe, store: root)
        a.env = h.env
        if let doz { a.env["DOZ_MENUBAR_DOZ"] = doz } else { a.env.removeValue(forKey: "DOZ_MENUBAR_DOZ") }
        for (k, v) in extra { a.env[k] = v }
        return a.run(args, timeout: timeout)
    }
    func dump(_ doz: String?, extra: [String: String] = [:]) -> [String: Any] {
        let r = appRun(["--dump-menu"], doz: doz, extra: extra)
        return (try? JSONSerialization.jsonObject(with: r.outData)) as? [String: Any] ?? [:]
    }
    func items(_ d: [String: Any]) -> [[String: Any]] { d["items"] as? [[String: Any]] ?? [] }
    func header(_ d: [String: Any]) -> String { items(d).first?["title"] as? String ?? "?" }
    func item(_ d: [String: Any], _ action: String) -> [String: Any]? { items(d).first { $0["action"] as? String == action } }
    func enabled(_ d: [String: Any], _ action: String) -> Bool? { item(d, action)?["enabled"] as? Bool }
    func titles(_ d: [String: Any]) -> [String] { items(d).compactMap { $0["title"] as? String }.filter { !$0.isEmpty } }
    func sh(_ argv: [String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: argv[0])
        p.arguments = Array(argv.dropFirst())
        let o = Pipe()
        p.standardOutput = o
        p.standardError = o
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return (127, "\(error)") }
        let d = o.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: d, as: UTF8.self))
    }
    var started: [Process] = []
    defer {
        for p in started where p.isRunning { p.terminate() }
        h.run(["ui", "stop"], timeout: 30)
        h.run(["daemon", "stop"], timeout: 120)
        _ = h.waitFor(30) { !h.hostRunning }
        check(!h.hostRunning, "app: no daemon of this suite left running")
        try? fm.removeItem(at: base)
    }

    // 1. no doz; then a fresh store.
    var d = dump(base.appendingPathComponent("nowhere/doz").path)
    check(header(d) == "doz is not installed" && d["icon"] as? String == "cube.transparent" && item(d, "start") == nil
          && enabled(d, "installHelp") == true && enabled(d, "quit") == true,
          "app 1: no doz → \"doz is not installed\", the hollow icon, How to Install, Quit — no daemon action (\(header(d)))")
    d = dump(nil)
    check(header(d) == "doz is not installed", "app 1: a test run without the seam never finds this Mac's own doz (\(header(d)))")
    d = dump(binary)
    let dozSeen = (d["doz"] as? [String: Any])?["version"] as? String
    check(header(d) == "Daemon stopped" && dozSeen == version && enabled(d, "start") == true && enabled(d, "stop") == false
          && enabled(d, "dashboard") == true && d["icon"] as? String == "cube",
          "app 1: the real doz on a fresh store → \"Daemon stopped\", doz \(dozSeen ?? "?"), Start enabled (\(header(d)))")
    check(!h.hostRunning, "app 1: looking started no daemon")
    let plists = (try? fm.contentsOfDirectory(atPath: agents.path)) ?? []
    check(plists.isEmpty && !titles(d).contains(where: { $0.lowercased().contains("login") }),
          "app 1: nothing registered at first launch — no login item, no login line (\(plists))")
    let gui = appRun([], doz: binary)
    check(gui.code == 70 && gui.err.contains("never shows the menu bar app"), "app 1: a test run is refused the menu itself (exit \(gui.code))")

    // 2. start, in a process group of its own; the group killed; the daemon stays.
    let perl = Process()
    perl.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
    perl.arguments = ["-e", "setpgrp(0,0); exec @ARGV", appExe, "--run-action", "start"]
    var penv = h.env
    penv["DOZ_MENUBAR_DOZ"] = binary
    perl.environment = penv
    let po = Pipe()
    perl.standardOutput = po
    perl.standardError = FileHandle.nullDevice
    perl.standardInput = FileHandle.nullDevice
    var startOut = ""
    if (try? perl.run()) != nil {
        let group = perl.processIdentifier
        let data = po.fileHandleForReading.readDataToEndOfFile()
        perl.waitUntilExit()
        startOut = String(decoding: data, as: UTF8.self)
        kill(-group, SIGKILL)                                           // whatever is left of the app's group
        usleep(500_000)
        let st = h.json(["daemon", "status"], HostStatus.self)
        let pid = st?.pid ?? 0
        check(perl.terminationStatus == 0 && startOut.contains("\"ok\":true") && h.hostRunning,
              "app 2: --run-action start → a daemon (\(startOut.trimmingCharacters(in: .whitespacesAndNewlines)))")
        check(st?.parentPid == 1 && pid > 0 && getpgid(pid) != group && getsid(pid) != getsid(group) && getsid(pid) != getsid(0),
              "app 2: its parent is launchd (\(st?.parentPid.map(String.init) ?? "?")), in neither the app's process group nor its session")
        check(pid > 0 && kill(pid, 0) == 0 && h.hostRunning, "app 2: the app's process group killed — the daemon is still up (pid \(pid))")
        if st?.keychainLocked == nil { check(true, "app 2: the daemon it started can read the login Keychain (keychainLocked null)") }
        else { info("app 2: this run's session cannot read the Keychain (\(st?.keychainLocked ?? "")) — the daemon says so too (run from ssh?)") }
    } else {
        check(false, "app 2: could not run the app in its own process group")
    }
    d = dump(binary)
    check(header(d) == "Daemon running · \(version)" && enabled(d, "stop") == true && enabled(d, "restart") == true && enabled(d, "start") == false,
          "app 2: the menu says it runs — Stop and Restart enabled (\(header(d)))")

    // 3. stop → held.
    var r = appRun(["--run-action", "stop"], doz: binary)
    check(r.code == 0 && !h.hostRunning, "app 3: --run-action stop → no daemon")
    d = dump(binary)
    check(header(d) == "Daemon stopped until a doz command starts it" && fm.fileExists(atPath: store.heldFile.path),
          "app 3: held (always on) — \(header(d))")

    // 5. a FAKE old doz.
    let fakeDir = base.appendingPathComponent("fake")
    try? fm.createDirectory(at: fakeDir, withIntermediateDirectories: true)
    let fake = fakeDir.appendingPathComponent("doz").path
    let argvLog = fakeDir.appendingPathComponent("argv.log").path
    let script = """
    #!/bin/sh
    printf '%s|' "$@" >> '\(argvLog)'; echo >> '\(argvLog)'
    case "$1" in
      --version) echo 0.50.3 ;;
      daemon) case "$2" in status) echo '{"running":false}' ;; start) echo '{"pid":4242}' ;; *) echo '{}' ;; esac ;;
      *) echo "doz: unknown command $1" >&2; exit 64 ;;
    esac
    """
    try? script.write(toFile: fake, atomically: true, encoding: .utf8)
    chmod(fake, 0o755)
    d = dump(fake)
    check(header(d) == "Daemon stopped" && titles(d).contains("doz 0.50.3 is older than this app needs (\("0.50.5") or later) — upgrade doz")
          && enabled(d, "start") == true && enabled(d, "dashboard") == true && enabled(d, "stop") == false,
          "app 5: an old doz → the too-old line; Start and the dashboard still offered (\(titles(d).prefix(3)))")
    r = appRun(["--run-action", "start"], doz: fake)
    let argv = ((try? String(contentsOfFile: argvLog, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    check(argv.contains("--version|") && argv.contains("daemon|status|--json|--no-send-anonymous-usage-stats|")
          && argv.contains("daemon|start|--json|") && argv.allSatisfy { !$0.contains("-c|") },
          "app 5: doz run with an argv — the refreshes not counted as the person's commands, start as typed (\(argv))")

    // 7. the dashboard through the browser seam.
    let browserLog = base.appendingPathComponent("browser.log").path
    r = appRun(["--run-action", "dashboard"], doz: binary, extra: ["DOZ_TEST_BROWSER_LOG": browserLog])
    let opened = ((try? String(contentsOfFile: browserLog, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    let one = opened.count == 1 && opened[0].range(of: #"^open http://127\.0\.0\.1:[0-9]+$"#, options: .regularExpression) != nil
    check(r.code == 0 && one, "app 7: Open Dashboard → exactly one `open http://127.0.0.1:N` (\(opened))")
    check(!r.out.contains("http") && !r.err.contains("http") && !r.out.contains("#") && !opened.joined().contains("#"),
          "app 7: no link or token in the seam's file or the app's output")
    let log = sh(["/usr/bin/log", "show", "--style", "compact", "--last", "3m", "--predicate", "subsystem == \"com.dozable.app\""])
    if log.0 == 0 {
        let lines = log.1.split(separator: "\n").filter { $0.contains("doz ") }
        check(lines.contains { $0.contains("doz ui --detach") } && !lines.contains { $0.contains("http") || $0.contains("#") },
              "app 7: the app's log names `doz ui --detach` and its exit — no link, no token (\(lines.count) lines)")
    } else {
        info("app 7: log show could not read the unified log (exit \(log.0)) — the log line's content is pinned by CommandRunnerTests")
    }
    r = h.run(["ui", "stop"], timeout: 30)
    check(r.code == 0, "app 7: doz ui stop")
    h.run(["daemon", "stop"], timeout: 120)
    _ = h.waitFor(30) { !h.hostRunning }

    // 8. doz in a scratch prefix, replaced by rename.
    let prefix = base.appendingPathComponent("prefix")
    let libexec = prefix.appendingPathComponent("libexec/doz")
    try? fm.createDirectory(at: libexec, withIntermediateDirectories: true)
    try? fm.createDirectory(at: prefix.appendingPathComponent("bin"), withIntermediateDirectories: true)
    let src = URL(fileURLWithPath: binary).deletingLastPathComponent()
    for item in (try? fm.contentsOfDirectory(atPath: src.path)) ?? [] where item.hasSuffix(".bundle") {
        _ = sh(["/bin/cp", "-cR", src.appendingPathComponent(item).path, libexec.path + "/"])
    }
    let pdoz = libexec.appendingPathComponent("doz").path
    let entitlements = URL(fileURLWithPath: "Scripts/doz.entitlements").standardizedFileURL.path
    /// A signed copy of this build renamed over libexec/doz/doz, with VERSION `v` renamed in beside it.
    func installDoz(_ v: String) -> Bool {
        try? (v + "\n").write(toFile: libexec.appendingPathComponent(".VERSION.new").path, atomically: false, encoding: .utf8)
        return sh(["/bin/cp", binary, pdoz + ".new"]).0 == 0
            && sh(["/usr/bin/codesign", "--force", "--sign", "-", "--entitlements", entitlements, pdoz + ".new"]).0 == 0
            && rename(pdoz + ".new", pdoz) == 0
            && rename(libexec.appendingPathComponent(".VERSION.new").path, libexec.appendingPathComponent("VERSION").path) == 0
    }
    let link = prefix.appendingPathComponent("bin/doz").path
    try? fm.createSymbolicLink(atPath: link, withDestinationPath: "../libexec/doz/doz")
    check(installDoz(version), "app 8: doz \(version) in a scratch prefix")
    d = dump(link)
    check((d["doz"] as? [String: Any])?["version"] as? String == version && (d["doz"] as? [String: Any])?["path"] as? String == link,
          "app 8: the dump names the prefix's bin/doz (a link, kept as is) at \(version)")
    let inode0 = (try? fm.attributesOfItem(atPath: pdoz)[.systemFileNumber]) as? Int
    let newer = "9.9.9"
    check(installDoz(newer), "app 8: a new doz renamed over it (VERSION \(newer))")
    d = dump(link)
    let inode1 = (try? fm.attributesOfItem(atPath: pdoz)[.systemFileNumber]) as? Int
    check((d["doz"] as? [String: Any])?["version"] as? String == newer && inode0 != inode1,
          "app 8: the next dump shows doz \(newer) (a new file: inode \(inode0 ?? 0) → \(inode1 ?? 0))")
    // The copy of the app that came with the new doz: newer than the running app → offered.
    let bundled = libexec.appendingPathComponent("Dozable.app")
    _ = sh(["/usr/bin/ditto", app, bundled.path])
    _ = sh(["/usr/bin/plutil", "-replace", "CFBundleShortVersionString", "-string", newer, bundled.appendingPathComponent("Contents/Info.plist").path])
    _ = sh(["/usr/bin/plutil", "-replace", "CFBundleVersion", "-string", newer, bundled.appendingPathComponent("Contents/Info.plist").path])
    let signed = sh(["/usr/bin/codesign", "--force", "--sign", "-", "--options", "runtime", "--identifier", "com.dozable.app", bundled.path])
    check(signed.0 == 0, "app 8: a copy of the app at \(newer) beside it (signed ad hoc)")
    d = dump(link)
    let update = item(d, "updateApp")
    check(update?["title"] as? String == "Update Menu Bar App (\(version) → \(newer))" && update?["enabled"] as? Bool == true,
          "app 8: the menu offers \(update?["title"] as? String ?? "nothing")")

    // 9. doz app install / status / uninstall, into a scratch folder.
    let p = CLIHarness(binary: link, store: root)
    p.env = h.env
    p.env["DOZ_TEST_APP_OPEN_LOG"] = base.appendingPathComponent("open.log").path
    _ = sh(["/usr/bin/xattr", "-w", "com.apple.quarantine", "0081;00000000;Safari;", bundled.appendingPathComponent("Contents/MacOS/Dozable").path])
    let dest = base.appendingPathComponent("dest")
    let target = dest.appendingPathComponent("Dozable.app")
    r = p.run(["app", "install", "--dest", dest.path, "--json"])
    let quarantined = sh(["/usr/bin/xattr", "-lr", target.path]).1.contains("com.apple.quarantine")
    check(r.code == 0 && sh(["/usr/bin/codesign", "--verify", "--strict", target.path]).0 == 0 && !quarantined
          && MenuBarAppInstallProbe.version(target) == newer,
          "app 9: doz app install --dest → verified, installed at \(newer), no quarantine mark (\(r.err.trimmingCharacters(in: .whitespacesAndNewlines)))")
    let noDest = CLIHarness(binary: link, store: root)
    noDest.env = p.env
    noDest.env.removeValue(forKey: "DOZ_TEST_APPLICATIONS_DIR")
    r = noDest.run(["app", "install"])
    check(r.code != 0 && r.err.contains("only into --dest DIR or DOZ_TEST_APPLICATIONS_DIR") && !fm.fileExists(atPath: "/Applications/Dozable.app.new"),
          "app 9: a test run with no destination is refused — never /Applications (exit \(r.code))")
    // A test run never asks macOS to open an app: --open without the seam is STOPPED before anything is installed.
    let noSeam = CLIHarness(binary: link, store: root)
    noSeam.env = p.env
    noSeam.env.removeValue(forKey: "DOZ_TEST_APP_OPEN_LOG")
    let inodeUntouched = (try? fm.attributesOfItem(atPath: target.appendingPathComponent("Contents/MacOS/Dozable").path)[.systemFileNumber]) as? Int
    r = noSeam.run(["app", "install", "--dest", dest.path, "--open", "--json"])
    let inodeStill = (try? fm.attributesOfItem(atPath: target.appendingPathComponent("Contents/MacOS/Dozable").path)[.systemFileNumber]) as? Int
    check(r.code != 0 && r.err.contains("TEST SAFETY") && r.err.contains("open an app") && inodeUntouched == inodeStill
          && !fm.fileExists(atPath: base.appendingPathComponent("open.log").path),
          "app 9: --open in a test run without the open seam → stopped by test safety, nothing installed or opened (exit \(r.code))")
    // A "running" copy: a STAND-IN process outside any bundle (DOZ_TEST_APP_STANDIN — in a test run only it counts as a
    // running copy; a program is never run from inside a scratch bundle, which Gatekeeper would judge), then --open:
    // the stand-in quit, the new copy swapped in by rename, and "opened" through the seam (one line, nothing opened).
    let runningExe = target.appendingPathComponent("Contents/MacOS/Dozable").path
    let holdC = base.appendingPathComponent("hold.c").path
    let standin = base.appendingPathComponent("standin-hold").path
    try? "#include <unistd.h>\nint main(void) { sleep(120); return 0; }\n".write(toFile: holdC, atomically: true, encoding: .utf8)
    let cc = sh(["/usr/bin/cc", "-o", standin, holdC])
    if cc.0 != 0 { info("app 9: cc failed: \(cc.1.prefix(200))") }
    let sleeper = Process()
    sleeper.executableURL = URL(fileURLWithPath: standin)
    try? sleeper.run()
    started.append(sleeper)
    usleep(300_000)
    let inodeBefore = (try? fm.attributesOfItem(atPath: runningExe)[.systemFileNumber]) as? Int
    let withStandin = CLIHarness(binary: link, store: root)
    withStandin.env = p.env
    withStandin.env["DOZ_TEST_APP_STANDIN"] = standin
    r = withStandin.run(["app", "install", "--dest", dest.path, "--open", "--json"])
    let quitOK = h.waitFor(6) { !sleeper.isRunning }
    let inodeAfter = (try? fm.attributesOfItem(atPath: runningExe)[.systemFileNumber]) as? Int
    let openLog = (try? String(contentsOfFile: base.appendingPathComponent("open.log").path, encoding: .utf8)) ?? ""
    check(r.code == 0 && quitOK && inodeBefore != inodeAfter && openLog == "open \(target.path)\n"
          && sh(["/usr/bin/codesign", "--verify", "--strict", target.path]).0 == 0,
          "app 9: again with a running copy (the stand-in) and --open → it was quit, the new copy swapped in by rename (a new file), exactly one line in the open seam, nothing opened "
          + "(exit \(r.code), quit \(quitOK), inode \(inodeBefore ?? 0) → \(inodeAfter ?? 0), open log \(openLog.debugDescription), \(r.out.replacingOccurrences(of: "\n", with: " ").prefix(160)))")
    check(!fm.fileExists(atPath: dest.appendingPathComponent(".Dozable.app.new").path), "app 9: nothing left at the staged name")
    // Tampered: a file added to the copy beside doz after it was signed.
    try? fm.createDirectory(at: bundled.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
    try? Data("x".utf8).write(to: bundled.appendingPathComponent("Contents/Resources/added"))
    let before = sh(["/usr/bin/shasum", "-a", "256", runningExe]).1
    r = p.run(["app", "install", "--dest", dest.path])
    check(r.code != 0 && r.err.contains("does not verify") && sh(["/usr/bin/shasum", "-a", "256", runningExe]).1 == before,
          "app 9: a tampered copy is refused — the installed one unchanged (\(r.err.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120)))")
    try? fm.removeItem(at: bundled.appendingPathComponent("Contents/Resources/added"))
    // status
    let ps = CLIHarness(binary: link, store: root)
    ps.env = p.env
    ps.env["DOZ_TEST_APPLICATIONS_DIR"] = dest.path
    r = ps.run(["app", "status", "--json"])
    let st = (try? JSONSerialization.jsonObject(with: r.outData)) as? [String: Any]
    let inst = (st?["installed"] as? [[String: Any]])?.first
    check((st?["bundled"] as? [String: Any])?["version"] as? String == newer && inst?["version"] as? String == newer
          && inst?["running"] as? Bool == false && (st?["installed"] as? [Any])?.count == 1,
          "app 9: doz app status --json — the copy with doz and the installed one (\(r.out.replacingOccurrences(of: "\n", with: " ").prefix(200)))")
    // uninstall
    r = p.run(["app", "uninstall", "--dest", dest.path, "-y"])
    check(r.code == 0 && !fm.fileExists(atPath: target.path), "app 9: doz app uninstall --dest removes it")
    // doz uninstall lists and removes an installed copy (the scratch Applications folder; the store and settings kept).
    let apTarget = apps.appendingPathComponent("Dozable.app")
    r = p.run(["app", "install", "--json"])
    check(r.code == 0 && fm.fileExists(atPath: apTarget.path), "app 9: doz app install with no --dest → the test run's Applications folder")
    r = h.run(["uninstall", "--yes", "--keep-store", "--keep-config", "--json"], timeout: 120)
    check(r.code == 0 && r.out.contains(apTarget.path) && !fm.fileExists(atPath: apTarget.path),
          "app 9: doz uninstall lists the menu bar app and removes it")
}

/// The installed copy's version (its Info.plist), for the checks above.
enum MenuBarAppInstallProbe {
    static func version(_ app: URL) -> String? {
        guard let d = FileManager.default.contents(atPath: app.appendingPathComponent("Contents/Info.plist").path),
              let p = try? PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any] else { return nil }
        return p["CFBundleShortVersionString"] as? String
    }
}
