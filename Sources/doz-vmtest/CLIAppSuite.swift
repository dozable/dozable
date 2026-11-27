// `doz-vmtest cli-app --doz PATH --app PATH/Dozable.app` (`make test-cli-app`): the menu bar app with NO screen and no VM —
// its executable run only in its non-GUI modes (`--dump-menu`, `--run-action`, in a guarded run: it refuses to show the
// menu), against the signed `make cli` doz and against FAKE ones, in a scratch store, settings, LaunchAgents and
// Applications folder of its own (/tmp/dzo-PID-ap). Never /Applications, never this Mac's own doz.
//
//   1. No doz (the seam pointing nowhere; and no seam at all — a test never finds this Mac's doz): "doz is not
//      installed", the hollow icon, no daemon action. Then the real doz on a fresh store: "Daemon stopped", Start enabled,
//      nothing started, nothing registered (no plist in the scratch LaunchAgents folder, no "would register" from the
//      app's recording login service, Start at Login unchecked).
//   2. `--run-action start` (the app in a process group of its own) → a daemon whose parent is launchd, in neither the
//      app's group nor its session; the app's group killed → the daemon is still up. The menu says it runs.
//   3. `--run-action stop` → stopped and HELD (always on): the header says so.
//   4. `--launch-daemon` (what launchd runs for the app's agent): with a FAKE doz → it execs it (the same process) with
//      exactly `daemon start --login-item`; no doz → exit 0, nothing run; the team required (the test seam) and an ad hoc
//      doz → exit 0, nothing run. With the real doz: held → nothing; after a "reboot" (DOZ_TEST_BOOT_TIME) → a daemon
//      whose parent is launchd; a second run in < 300 ms, the same pid.
//   5. A FAKE old doz (0.50.3, `{"running":false}`) → the too-old line, and Start, Stop, Restart and the dashboard still
//      offered as the state allows; the fake's argv log shows doz run with an argv (no shell) and the refreshes marked as
//      not the person's commands.
//   6. The workspace section: a FAKE new doz (0.60.8) answering `workspace ls --json` → the rows in the dashboard's order
//      and words, Open + Sleep / Open + Wake under them, All Workspaces…; the argv each runs; a name that is not a
//      workspace's runs nothing; an empty listing → "No workspaces yet"; a failing one → no section. Row 5's old doz is
//      never asked. Then the real doz: a fresh store → "No workspaces yet"; Open through the browser seam (in 7).
//   7. Open Dashboard through the browser seam: exactly one `open http://127.0.0.1:N` line, no link or token anywhere —
//      not in the seam's file, the app's output or its log (os_log, when `log show` can read it); `doz ui stop`.
//   8. doz in a scratch prefix replaced BY RENAME (a new file and VERSION) → the next dump shows the new version, and a
//      newer copy of the app beside it → "Update Menu Bar App (X → Y)".
//  10. Start at Login, guarded (the recording service — never SMAppService; a FAKE launchctl standing in for launchd,
//      which shows the app's job once the recording service says it is registered): doz's own item first → the menu
//      offers the hand-over; `--run-action login-on` → "would register" agent + mainApp, the job seen loaded, THEN
//      `doz config set daemon.login_item on` (launchctl's log: the app's look before doz's bootout of its own) → doz's
//      plist gone, owner app, the row checked; `login-off` → unregistered, the setting off; needs approval → stops there,
//      doz not told; `doz app uninstall` runs the app's --unregister (held, "would unregister").
//   9. `doz app install --dest` (the copy beside that doz: verified, its quarantine mark removed, installed; --open with
//      no open seam STOPPED by test safety before anything happens; again with a "running" copy — a stand-in process
//      OUTSIDE any bundle (DOZ_TEST_APP_STANDIN) — and --open: quit, swapped by rename — a new file — and one line in the
//      open seam, nothing opened; a test never asks macOS to open an app, nor runs a program inside a scratch bundle), a tampered copy
//      refused (the installed one unchanged), no destination in a test run refused, `doz app status --json`,
//      `doz app uninstall --dest`, and `doz uninstall` listing and removing it.
//  11. The DEV app (`--dev-app`, make app-dev) against a fake doz: CLIDevAppChecks.swift.
//
// Every daemon and UI it starts is stopped at the end; the scratch folders are removed.
import Darwin
import Foundation
import DozableKit
import DozableHost

func cliAppSuite(binary: String, app: String, devApp: String? = nil) async {
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
    // The app's recording login service (a test run never reaches SMAppService): what it would do, and its state.
    let loginLog = base.appendingPathComponent("login.log").path
    let loginState = base.appendingPathComponent("login-state.json").path
    h.env["DOZ_TEST_LOGIN_ITEM_LOG"] = loginLog
    h.env["DOZ_TEST_LOGIN_ITEM_STATE"] = loginState
    func loginLines() -> [String] { ((try? String(contentsOfFile: loginLog, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }
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
    let loginRow = items(d).first { ($0["title"] as? String)?.hasPrefix("Start at Login") == true }
    check(plists.isEmpty && loginLines().isEmpty && loginRow?["checked"] as? Bool == false
          && (d["loginItem"] as? [String: Any])?["agent"] as? String == "notRegistered",
          "app 1: nothing registered at first launch — no plist, no \"would register\", Start at Login unchecked (\(plists), \(loginRow?["title"] as? String ?? "no row"))")
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

    // 4. --launch-daemon: what launchd runs for the app's agent.
    let launchDir = base.appendingPathComponent("launch")
    try? fm.createDirectory(at: launchDir, withIntermediateDirectories: true)
    let launchFake = launchDir.appendingPathComponent("doz").path
    let launchLog = launchDir.appendingPathComponent("argv.log").path
    try? "#!/bin/sh\necho \"$$|$*\" >> '\(launchLog)'\nexit 0\n".write(toFile: launchFake, atomically: true, encoding: .utf8)
    chmod(launchFake, 0o755)
    func launchLines() -> [String] { ((try? String(contentsOfFile: launchLog, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }
    let lp = Process()
    lp.executableURL = URL(fileURLWithPath: appExe)
    lp.arguments = ["--launch-daemon"]
    var lenv = h.env
    lenv["DOZ_MENUBAR_DOZ"] = launchFake
    lp.environment = lenv
    lp.standardInput = FileHandle.nullDevice
    lp.standardOutput = FileHandle.nullDevice
    lp.standardError = FileHandle.nullDevice
    if (try? lp.run()) != nil {
        lp.waitUntilExit()
        let ll = launchLines()
        check(lp.terminationStatus == 0 && ll == ["\(lp.processIdentifier)|daemon start --login-item"],
              "app 4: --launch-daemon with a fake doz → exec'd in the same process with exactly `daemon start --login-item` (\(ll), pid \(lp.processIdentifier))")
    } else {
        check(false, "app 4: could not run the app's --launch-daemon")
    }
    r = appRun(["--launch-daemon"], doz: base.appendingPathComponent("nowhere/doz").path, timeout: 20)
    check(r.code == 0 && r.out.isEmpty && launchLines().count == 1, "app 4: no doz → exit 0, nothing run, nothing printed")
    r = appRun(["--launch-daemon"], doz: launchFake, extra: ["DOZ_TEST_MENUBAR_REQUIRE_TEAM": "1"], timeout: 20)
    check(r.code == 0 && launchLines().count == 1, "app 4: Dozable's team required and an ad hoc doz → refused: exit 0, nothing run")
    let selfConfig = (try? JSONSerialization.jsonObject(with: appRun(["--self-config"], doz: nil).outData)) as? [String: Any]
    check(selfConfig?["requireTeam"] as? Bool == false && selfConfig?["agentLabel"] as? String == "com.dozable.app.daemon",
          "app 4: this development build (make app) does not require the team; a release build does (the release checks it)")
    // The real doz: held by row 3's stop → nothing; after a login following a reboot → a daemon, parent launchd.
    r = appRun(["--launch-daemon"], doz: binary, timeout: 60)
    check(r.code == 0 && !h.hostRunning, "app 4: the real doz while held (doz daemon stop) → nothing started")
    let reboot = ["DOZ_TEST_BOOT_TIME": String(Int(Date().timeIntervalSince1970) + 1)]
    sleep(2)
    r = appRun(["--launch-daemon"], doz: binary, extra: reboot, timeout: 120)
    let up = h.waitFor(30) { h.hostRunning }
    let st4 = h.json(["daemon", "status"], HostStatus.self)
    check(r.code == 0 && up && st4?.parentPid == 1, "app 4: the real doz after a reboot → a daemon, parent launchd (\(st4?.parentPid.map(String.init) ?? "none"))")
    let t0 = Date()
    r = appRun(["--launch-daemon"], doz: binary, extra: reboot, timeout: 60)
    let ms = Int(Date().timeIntervalSince(t0) * 1000)
    let st4b = h.json(["daemon", "status"], HostStatus.self)
    check(r.code == 0 && st4b?.pid == st4?.pid && ms < 300,
          "app 4: a second run with a daemon up → \(ms) ms, the same pid \(st4b.map { String($0.pid) } ?? "?")")
    h.run(["daemon", "stop"], timeout: 120)
    _ = h.waitFor(30) { !h.hostRunning }

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
    check(!titles(d).contains("Workspaces") && !argv.contains { $0.hasPrefix("workspace|") },
          "app 5: an old doz → no workspace section, and `workspace ls` never run")

    // 6. the workspace section, against a FAKE new doz.
    let wsDir = base.appendingPathComponent("fakews")
    try? fm.createDirectory(at: wsDir, withIntermediateDirectories: true)
    let wsFake = wsDir.appendingPathComponent("doz").path
    let wsLog = wsDir.appendingPathComponent("argv.log").path
    let wsList = wsDir.appendingPathComponent("list.json").path
    try? """
    #!/bin/sh
    printf '%s|' "$@" >> '\(wsLog)'; echo >> '\(wsLog)'
    case "$1" in
      --version) echo 0.60.8 ;;
      daemon) echo '{"running":false,"held":false,"alwaysOn":true}' ;;
      workspace) case "$2" in ls) [ -f '\(wsList)' ] || exit 1; cat '\(wsList)' ;; sleep|wake) echo '{"name":"'"$3"'"}' ;; *) exit 64 ;; esac ;;
      ui) exit 0 ;;
      *) echo "doz: unknown command $1" >&2; exit 64 ;;
    esac
    """.write(toFile: wsFake, atomically: true, encoding: .utf8)
    chmod(wsFake, 0o755)
    func wsArgv() -> [String] { ((try? String(contentsOfFile: wsLog, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }
    try? #"{"workspaces":[{"name":"beta","state":"asleep","agents":1},{"name":"alpha","state":"waiting-on-you","agents":2}],"loose":[]}"#
        .write(toFile: wsList, atomically: true, encoding: .utf8)
    d = dump(wsFake)
    let rows = items(d).filter { $0["submenu"] != nil }
    let under = rows.map { ($0["submenu"] as? [[String: Any]] ?? []).compactMap { $0["action"] as? String } }
    check(titles(d).contains("Workspaces") && rows.compactMap { $0["title"] as? String } == ["alpha · waiting on you", "beta · asleep"]
          && under == [["open-workspace", "sleep-workspace"], ["open-workspace", "wake-workspace"]] && enabled(d, "all-workspaces") == true,
          "app 6: two workspaces → waiting on you first, the dashboard's words, Open + Sleep / Open + Wake, All Workspaces… (\(rows.compactMap { $0["title"] as? String }), \(under))")
    check(wsArgv().contains("workspace|ls|--json|--no-send-anonymous-usage-stats|"),
          "app 6: the listing is `workspace ls --json`, not counted as the person's command")
    var wsOK = true
    for (action, name, line) in [("open-workspace", "alpha", "ui|open|alpha|-q|"), ("sleep-workspace", "alpha", "workspace|sleep|alpha|--json|"),
                                 ("wake-workspace", "beta", "workspace|wake|beta|--json|"), ("all-workspaces", nil, "ui|open|--workspaces|-q|")] as [(String, String?, String)] {
        r = appRun(["--run-action", action] + (name.map { [$0] } ?? []), doz: wsFake)
        if !(r.code == 0 && wsArgv().last == line) { wsOK = false; info("app 6: \(action) → exit \(r.code), \(wsArgv().last ?? "-")") }
    }
    check(wsOK, "app 6: Open, Sleep, Wake and All Workspaces… run `ui open NAME -q`, `workspace sleep|wake NAME --json`, `ui open --workspaces -q`")
    let wsBefore = wsArgv().count
    r = appRun(["--run-action", "sleep-workspace", "--all"], doz: wsFake)
    check(r.code == 64 && wsArgv().count == wsBefore, "app 6: a name that is not a workspace's is refused, nothing run (exit \(r.code))")
    try? #"{"workspaces":[],"loose":[]}"#.write(toFile: wsList, atomically: true, encoding: .utf8)
    d = dump(wsFake)
    check(titles(d).contains("No workspaces yet") && item(d, "all-workspaces") == nil, "app 6: none → \"No workspaces yet\"")
    try? fm.removeItem(atPath: wsList)
    d = dump(wsFake)
    check(!titles(d).contains("Workspaces") && enabled(d, "dashboard") == true && header(d) == "Daemon stopped",
          "app 6: a failing listing → no section, the rest of the menu as before (\(header(d)))")
    d = dump(binary)
    check(titles(d).contains("No workspaces yet") && !h.hostRunning,
          "app 6: the real doz on a fresh store → \"No workspaces yet\", no daemon started by looking")

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
    // 6/7: a workspace's page through the same seam — one open line naming the page, no link.
    try? fm.removeItem(atPath: browserLog)
    r = appRun(["--run-action", "open-workspace", "alpha"], doz: binary, extra: ["DOZ_TEST_BROWSER_LOG": browserLog])
    let wsOpened = ((try? String(contentsOfFile: browserLog, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    check(r.code == 0 && wsOpened.count == 1 && wsOpened[0].range(of: #"^open http://127\.0\.0\.1:[0-9]+  page w/alpha$"#, options: .regularExpression) != nil
          && !wsOpened.joined().contains("cap=") && !r.out.contains("http"),
          "app 7: Open on a workspace → `doz ui open NAME` → one `open http://127.0.0.1:N  page w/alpha`, no link (\(wsOpened))")
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
    // Without --open while a copy runs (the stand-in again): it says plainly that the running copy must be restarted, and how.
    let sleeper2 = Process()
    sleeper2.executableURL = URL(fileURLWithPath: standin)
    try? sleeper2.run()
    started.append(sleeper2)
    usleep(300_000)
    r = withStandin.run(["app", "install", "--dest", dest.path])
    check(r.code == 0 && r.out.contains("the menu bar app that is running is still the old copy: restart it to use")
          && r.out.contains("Restart to Update") && r.out.contains("doz app install --open") && sleeper2.isRunning,
          "app 9: without --open while a copy runs → it says to restart it (Restart to Update, or --open), and quits nothing (\(r.out.replacingOccurrences(of: "\n", with: " ").prefix(200)))")
    sleeper2.terminate()
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

    // 10. Start at Login, guarded: the recording service, a fake launchctl standing in for launchd.
    let fakeLaunchctl = URL(fileURLWithPath: "Scripts/fake-launchctl.py").standardizedFileURL.path
    let lcState = base.appendingPathComponent("launchctl.json").path
    let lcLog = base.appendingPathComponent("launchctl.log").path
    try? "{}".write(toFile: lcState, atomically: true, encoding: .utf8)
    h.env["DOZ_TEST_LAUNCHCTL"] = fakeLaunchctl
    h.env["FAKE_LAUNCHCTL_STATE"] = lcState
    h.env["FAKE_LAUNCHCTL_LOG"] = lcLog
    func lcLines() -> [String] { ((try? String(contentsOfFile: lcLog, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }
    let dozLabel = DaemonLoginItem.label(store)
    r = h.run(["app", "install", "--json"])
    let installedExe = apTarget.appendingPathComponent("Contents/MacOS/Dozable").path
    check(r.code == 0 && fm.isExecutableFile(atPath: installedExe), "app 10: the app installed in the test run's Applications folder")
    func installedRun(_ args: [String], extra: [String: String] = [:]) -> CLIRun {
        let a = CLIHarness(binary: installedExe, store: root)
        a.env = h.env
        a.env["DOZ_MENUBAR_DOZ"] = binary
        for (k, v) in extra { a.env[k] = v }
        return a.run(args, timeout: 120)
    }
    func installedDump() -> [String: Any] { (try? JSONSerialization.jsonObject(with: installedRun(["--dump-menu"]).outData)) as? [String: Any] ?? [:] }
    func loginRowOf(_ d: [String: Any]) -> [String: Any]? { items(d).first { ($0["title"] as? String)?.hasPrefix("Start at Login") == true } }
    func ownPlists() -> [String] { ((try? fm.contentsOfDirectory(atPath: agents.path)) ?? []).filter { $0.hasPrefix("com.dozable.") } }
    r = h.run(["daemon", "login-item", "on"])
    check(r.code == 0 && ownPlists() == [dozLabel + ".plist"] && h.json(["daemon", "login-item", "status"], LoginItemStatus.self)?.owner == "doz",
          "app 10: doz's own login item first (owner doz)")
    var row = loginRowOf(installedDump())
    check(row?["title"] as? String == "Start at Login (set by doz — click to let this app hold it)" && row?["checked"] as? Bool == true
          && row?["action"] as? String == "login-on" && row?["enabled"] as? Bool == true,
          "app 10: the menu offers the hand-over (\(row?["title"] as? String ?? "no row"))")
    let lcBefore = lcLines().count
    r = installedRun(["--run-action", "login-on"])
    let on = (try? JSONSerialization.jsonObject(with: r.outData)) as? [String: Any]
    let steps = on?["steps"] as? [String] ?? []
    check(r.code == 0 && on?["ok"] as? Bool == true
          && steps == ["would register agent com.dozable.app.daemon", "would register mainApp", "agent enabled, mainApp enabled", "job loaded",
                       "doz config set daemon.login_item on → exit 0"],
          "app 10: login-on → would register agent + mainApp, the job loaded, then doz told (\(steps))")
    check(loginLines().suffix(2) == ["would register agent com.dozable.app.daemon", "would register mainApp"],
          "app 10: the recording service says what it would have registered — and nothing else ran")
    let lcNew = Array(lcLines().dropFirst(lcBefore))
    let look = lcNew.firstIndex(of: "print gui/\(getuid())/com.dozable.app.daemon")
    let bootout = lcNew.firstIndex(of: "bootout gui/\(getuid())/\(dozLabel)")
    check(look != nil && bootout != nil && look! < bootout!,
          "app 10: the app's job seen loaded BEFORE doz removed its own (launchctl: \(lcNew))")
    let owned = h.json(["daemon", "login-item", "status"], LoginItemStatus.self)
    check(ownPlists().isEmpty && owned?.owner == "app" && owned?.setting == "on",
          "app 10: doz's plist gone, owner app, daemon.login_item on — never two login items (\(owned?.owner ?? "?"))")
    row = loginRowOf(installedDump())
    check(row?["title"] as? String == "Start at Login" && row?["checked"] as? Bool == true && row?["action"] as? String == "login-off",
          "app 10: the row is checked; a click turns it off")
    r = installedRun(["--run-action", "login-off"])
    let off = (try? JSONSerialization.jsonObject(with: r.outData)) as? [String: Any]
    let offSteps = off?["steps"] as? [String] ?? []
    check(r.code == 0 && offSteps == ["would unregister agent com.dozable.app.daemon", "would unregister mainApp", "doz config set daemon.login_item off → exit 0"]
          && h.json(["daemon", "login-item", "status"], LoginItemStatus.self)?.setting == "off" && ownPlists().isEmpty,
          "app 10: login-off → would unregister both, then daemon.login_item off (\(offSteps))")
    row = loginRowOf(installedDump())
    check(row?["title"] as? String == "Start at Login" && row?["checked"] as? Bool == false && row?["action"] as? String == "login-on",
          "app 10: the row is unchecked again")
    r = installedRun(["--run-action", "login-on"], extra: ["DOZ_TEST_LOGIN_ITEM_RESULT": "requiresApproval"])
    let pending = (try? JSONSerialization.jsonObject(with: r.outData)) as? [String: Any]
    row = loginRowOf(installedDump())
    check(pending?["needsApproval"] as? Bool == true && !((pending?["steps"] as? [String]) ?? []).contains { $0.hasPrefix("doz config") }
          && h.json(["daemon", "login-item", "status"], LoginItemStatus.self)?.setting == "off"
          && row?["title"] as? String == "Start at Login — needs approval: Open System Settings…" && row?["action"] as? String == "login-settings",
          "app 10: macOS waiting for approval → doz not told; the row opens System Settings (\(row?["title"] as? String ?? "no row"))")
    r = installedRun(["--run-action", "login-on"])
    r = h.run(["app", "uninstall", "-y", "--json"], timeout: 60)
    let removed = ((try? JSONSerialization.jsonObject(with: r.outData)) as? [[String: Any]])?.first
    check(r.code == 0 && (removed?["loginItem"] as? [String: Any])?["held"] as? Bool == true && !fm.fileExists(atPath: apTarget.path)
          && loginLines().suffix(2) == ["would unregister agent com.dozable.app.daemon", "would unregister mainApp"],
          "app 10: doz app uninstall runs the app's --unregister first (it held one) and removes it")
    check(loginLines().allSatisfy { $0.hasPrefix("would ") }, "app 10: the recording service only ever said what it would do")

    // 11. the DEV app (make app-dev), when given.
    if let devApp { cliDevAppChecks(devApp: devApp, env: h.env, base: base, loginLog: loginLog) }
}

/// The installed copy's version (its Info.plist), for the checks above.
enum MenuBarAppInstallProbe {
    static func version(_ app: URL) -> String? {
        guard let d = FileManager.default.contents(atPath: app.appendingPathComponent("Contents/Info.plist").path),
              let p = try? PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any] else { return nil }
        return p["CFBundleShortVersionString"] as? String
    }
}
