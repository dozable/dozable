// `make test-cli-app`'s rows for the DEV menu bar app ("Dozable Dev.app", `make app-dev`) — its non-GUI modes only,
// against a FAKE doz, in the suite's guarded environment (never the real dev doz: a guarded run uses only the seam
// DOZ_MENUBAR_DOZ; never the real dev settings: only the seam DOZ_MENUBAR_CONFIG_HOME):
//
//  11. --self-config → com.dozable.app.dev, flavour dev; the bundle carries no login agent. --dump-menu → "Dozable Dev"
//      first, the DEV badge, Start at Login "not in the dev build" (disabled, no action); every doz call the fake saw
//      carried the dev settings' XDG_CONFIG_HOME. No seam → no doz (the real dev doz is never run in a test).
//      --run-action login-on → refused, the recording login service never asked; --launch-daemon → exit 0, the fake not
//      run; --unregister → nothing held, nothing unregistered; no argument → refused the menu (exit 70).
import Darwin
import Foundation

func cliDevAppChecks(devApp: String, env: [String: String], base: URL, loginLog: String) {
    let fm = FileManager.default
    let exe = URL(fileURLWithPath: devApp).appendingPathComponent("Contents/MacOS/Dozable").path
    guard fm.isExecutableFile(atPath: exe) else { check(false, "app 11: the dev app is at \(exe) (make app-dev)"); return }
    let dir = base.appendingPathComponent("dev")
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let fake = dir.appendingPathComponent("doz").path
    let fakeLog = dir.appendingPathComponent("calls.log").path
    let devConfig = dir.appendingPathComponent("dev-config").path
    let script = """
    #!/bin/sh
    echo "$XDG_CONFIG_HOME|$*" >> '\(fakeLog)'
    case "$1" in
      --version) echo 0.52.16 ;;
      daemon) case "$2" in status) echo '{"running":false,"held":false,"alwaysOn":true,"store":"/tmp/x"}' ;; *) echo '{}' ;; esac ;;
      app) echo '{"bundled":{"version":"99.0.0"}}' ;;
      *) echo '{}' ;;
    esac
    """
    try? script.write(toFile: fake, atomically: true, encoding: .utf8)
    chmod(fake, 0o755)
    func fakeCalls() -> [String] { ((try? String(contentsOfFile: fakeLog, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }
    func loginLines() -> [String] { ((try? String(contentsOfFile: loginLog, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }

    func devRun(_ args: [String], doz: String?) -> CLIRun {
        let a = CLIHarness(binary: exe, store: base.appendingPathComponent("s"))
        a.env = env
        if let doz { a.env["DOZ_MENUBAR_DOZ"] = doz } else { a.env.removeValue(forKey: "DOZ_MENUBAR_DOZ") }
        a.env["DOZ_MENUBAR_CONFIG_HOME"] = devConfig
        return a.run(args, timeout: 60)
    }
    func json(_ r: CLIRun) -> [String: Any] { (try? JSONSerialization.jsonObject(with: r.outData)) as? [String: Any] ?? [:] }

    let sc = json(devRun(["--self-config"], doz: nil))
    check(sc["bundleIdentifier"] as? String == "com.dozable.app.dev" && sc["flavour"] as? String == "dev"
          && !fm.fileExists(atPath: URL(fileURLWithPath: devApp).appendingPathComponent("Contents/Library").path),
          "app 11: the dev app is com.dozable.app.dev, flavour dev, and carries no login agent (\(sc["bundleIdentifier"] ?? "?"))")

    let d = json(devRun(["--dump-menu"], doz: fake))
    let items = d["items"] as? [[String: Any]] ?? []
    let titles = items.compactMap { $0["title"] as? String }
    let login = items.first { ($0["title"] as? String)?.hasPrefix("Start at Login") == true }
    let update = items.first { ($0["title"] as? String)?.hasPrefix("Update Menu Bar App") == true }
    check(titles.first == "Dozable Dev" && titles.dropFirst().first == "Daemon stopped" && d["badge"] as? String == "DEV"
          && d["flavour"] as? String == "dev",
          "app 11: the dev menu names itself first, with the DEV badge (\(titles.prefix(2)))")
    check(login?["title"] as? String == "Start at Login — not in the dev build" && login?["enabled"] as? Bool == false && login?["action"] == nil
          && update?["title"] as? String == "Update Menu Bar App — not in the dev build" && update?["action"] == nil,
          "app 11: Start at Login and the app update say \"not in the dev build\" and do nothing")
    let calls = fakeCalls()
    check(!calls.isEmpty && calls.allSatisfy { $0.hasPrefix(devConfig + "|") },
          "app 11: every doz call carried the dev settings' XDG_CONFIG_HOME (\(calls))")

    let none = json(devRun(["--dump-menu"], doz: nil))
    check(((none["items"] as? [[String: Any]])?.dropFirst().first?["title"] as? String) == "doz is not installed",
          "app 11: a test run without the seam never finds the real dev doz")

    let before = loginLines().count
    let callsBefore = fakeCalls().count
    var r = devRun(["--run-action", "login-on"], doz: fake)
    check(r.code == 1 && json(r)["error"] as? String == "Start at Login is not in the dev build" && loginLines().count == before
          && fakeCalls().count == callsBefore,
          "app 11: login-on refused — the login service never asked, no doz config set (exit \(r.code), \(r.out.prefix(120)))")
    let launchLog = dir.appendingPathComponent("launch.log").path
    let launchFake = dir.appendingPathComponent("launch-doz").path
    try? "#!/bin/sh\necho \"$*\" >> '\(launchLog)'\n".write(toFile: launchFake, atomically: true, encoding: .utf8)
    chmod(launchFake, 0o755)
    r = devRun(["--launch-daemon"], doz: launchFake)
    check(r.code == 0 && !fm.fileExists(atPath: launchLog), "app 11: --launch-daemon in the dev build starts nothing (exit \(r.code))")
    r = devRun(["--unregister"], doz: fake)
    check(r.code == 0 && json(r)["held"] as? Bool == false && loginLines().count == before,
          "app 11: --unregister holds nothing and asks no service (\(r.out.prefix(120)))")
    r = devRun([], doz: fake)
    check(r.code == 70, "app 11: a test run is refused the dev menu itself (exit \(r.code))")
}
