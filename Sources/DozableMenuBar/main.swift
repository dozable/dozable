import Foundation
import DozableMenuBarCore

// Dozable.app — the menu bar app. It shows the daemon's state, starts, stops and restarts it, and opens the dashboard —
// all by running the `doz` command (docs/engineering/menu-bar-app.md). With no argument it is the menu (AppKit); the
// arguments below are modes that never start NSApplication, never draw anything and exit:
//
//   --dump-menu            the menu it would show now, as JSON (what a person over ssh, or a test, can look at)
//   --run-action ACTION    run one item's doz command (start|stop|restart|dashboard|all-workspaces, and
//                          open-workspace|sleep-workspace|wake-workspace NAME) or Start at Login's click
//                          (login-on|login-off) and print the outcome — a TEST seam: guarded runs only (DOZ_TEST_GUARD=1),
//                          where Start at Login is the recording service (it never calls SMAppService or launchctl)
//   --launch-daemon        what launchd runs for the app's agent (com.dozable.app.daemon): find doz — Dozable's team
//                          signature required in a release build — and exec `doz daemon start --login-item`; no doz, or
//                          one refused: a log line, exit 0
//   --unregister           take back this copy's Start at Login (the agent and the app) — doz app uninstall and
//                          doz uninstall run it before the bundle goes
//   --login-status         Start at Login as macOS reports it, as JSON (a look: registers nothing)
//   --self-config          what this copy is (identifier, version, the doz it needs, whether the login agent requires
//                          Dozable's team) — the release's check
//   --version, --help

let env = ProcessInfo.processInfo.environment
let arguments = Array(CommandLine.arguments.dropFirst())
let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
/// Release or dev — from the bundle's Info.plist, set when it was assembled (`make app` / `make app-dev`), never from
/// anything typed at run time.
let flavour = MenuBarFlavour.current
/// A release build (`swift build -c release`: what the release ships) requires Dozable's team signature of the doz its
/// login agent runs; a development build (`make app`) does not.
let releaseBuild: Bool = {
    #if DEBUG
    return false
    #else
    return true
    #endif
}()
let requireTeam = LaunchAgent.requiresTeam(releaseBuild: releaseBuild, env: env)

func say(_ s: String) { FileHandle.standardOutput.write(Data((s + "\n").utf8)) }
func complain(_ s: String) { FileHandle.standardError.write(Data(("Dozable: " + s + "\n").utf8)) }

let usage = """
    usage: Dozable                      the menu bar app (opened from Finder or with open -a Dozable)
           Dozable --dump-menu          print the menu it would show now, as JSON
           Dozable --self-config        print what this copy is, as JSON
           Dozable --login-status       print Start at Login as macOS reports it, as JSON
           Dozable --unregister         turn this copy's Start at Login off (doz app uninstall runs it)
           Dozable --version
    Install it with: doz app install
    """

func loginContext() -> SnapshotSource.LoginContext {
    SnapshotSource.LoginContext(service: loginService(env: env, flavour: flavour), look: LaunchdLook(env: env),
                                stablePlace: LoginPlace.isStable(bundlePath: Bundle.main.bundlePath, env: env))
}

func source() -> SnapshotSource {
    let bundlePath = Bundle.main.bundlePath
    return SnapshotSource(locator: .standard(flavour: flavour, env: env),
                          runner: CommandRunner(extraEnvironment: flavour.childEnvironment(env: env)), appVersion: appVersion,
                          login: loginContext(), installedAppVersion: { AppOnDisk.version(bundlePath: bundlePath) }, flavour: flavour)
}

func jsonLine(_ dict: [String: Any]) -> String {
    let d = (try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
    return String(decoding: d, as: UTF8.self)
}

// The modes. macOS may hand a GUI launch arguments of its own (`-psn_…`, `-NS… value`): those are not modes.
let modeArguments = arguments.filter { $0.hasPrefix("--") }
switch modeArguments.first {
case nil:
    // The menu. Never in a test run: a guarded run (every make test* target) is not allowed to show anything on screen.
    if MenuBarSeams.guarded(env) {
        complain("a test run never shows the menu bar app (DOZ_TEST_GUARD=1) — use --dump-menu or --run-action")
        exit(70)
    }
    runMenuBarApp(source: source(), flavour: flavour)
case "--dump-menu"?:
    say(MenuDump(source().snapshot()).json())
    exit(0)
case "--run-action"?:
    guard MenuBarSeams.guarded(env) else {
        complain("--run-action is a test seam (guarded runs only); a person uses the menu, or doz itself")
        exit(64)
    }
    guard let i = arguments.firstIndex(of: "--run-action"), i + 1 < arguments.count,
          let action = MenuAction(rawValue: arguments[i + 1]),
          [.start, .stop, .restart, .dashboard, .loginOn, .loginOff, .allWorkspaces, .openWorkspace, .sleepWorkspace, .wakeWorkspace]
            .contains(action) else {
        complain("--run-action start|stop|restart|dashboard|login-on|login-off|all-workspaces|open-workspace NAME|sleep-workspace NAME|wake-workspace NAME")
        exit(64)
    }
    var workspace: String?
    if action.needsWorkspace {
        guard i + 2 < arguments.count, WorkspaceName.isValid(arguments[i + 2]) else {
            complain("--run-action \(action.rawValue) NAME — a workspace's name")
            exit(64)
        }
        workspace = arguments[i + 2]
    }
    if action == .loginOn || action == .loginOff {
        let o = source().performLogin(action)
        say(jsonLine(["action": action.rawValue, "ok": o.error == nil, "error": o.error ?? NSNull(), "steps": o.steps,
                      "needsApproval": o.needsApproval]))
        exit(o.error == nil ? 0 : 1)
    }
    let error = source().perform(action, workspace: workspace)
    say(jsonLine(["action": action.rawValue, "ok": error == nil, "error": error ?? NSNull()]))
    exit(error == nil ? 0 : 1)
case "--launch-daemon"?:
    // launchd's job: no NSApplication, nothing drawn. Never returns (exec, or exit 0).
    LaunchAgent.run(locator: .forLaunchAgent(env: env, requireTeam: requireTeam), flavour: flavour)
case "--unregister"?:
    // doz app uninstall / doz uninstall: this copy takes back what it registered (only on a person's command).
    let service = loginService(env: env, flavour: flavour)
    let before = service.state()
    let held = before.agent.registered || before.mainApp.registered
    let r = service.unregister()
    say(jsonLine(["ok": r.error == nil, "held": held, "steps": r.lines, "error": r.error ?? NSNull()]))
    exit(0)
case "--login-status"?:
    let st = loginService(env: env, flavour: flavour).state()
    say(jsonLine(["agent": st.agent.rawValue, "mainApp": st.mainApp.rawValue, "label": AgentPlist.label,
                  "jobLoaded": LaunchdLook(env: env).loaded(), "bundle": Bundle.main.bundlePath,
                  "stablePlace": LoginPlace.isStable(bundlePath: Bundle.main.bundlePath, env: env)]))
    exit(0)
case "--self-config"?:
    var config: [String: Any] = ["bundleIdentifier": Bundle.main.bundleIdentifier ?? NSNull(), "version": appVersion ?? NSNull(),
                                 "minimumDoz": MenuBarApp.minimumDoz, "minimumDozForLogin": MenuBarApp.minimumDozForLogin,
                                 "requireTeam": requireTeam, "agentLabel": AgentPlist.label,
                                 "executable": Bundle.main.executablePath ?? NSNull(), "flavour": flavour.rawName]
    if flavour.isDev {
        for (field, key) in [("devDoz", MenuBarFlavour.devDozKey), ("devConfigHome", MenuBarFlavour.devConfigHomeKey),
                             ("devStore", MenuBarFlavour.devStoreKey), ("devCommit", MenuBarFlavour.devCommitKey)] {
            config[field] = Bundle.main.object(forInfoDictionaryKey: key) ?? NSNull()
        }
    }
    say(jsonLine(config))
    exit(0)
case "--version"?:
    say(appVersion ?? "unknown (not inside Dozable.app)")
    exit(0)
case "--help"?:
    say(usage)
    exit(0)
case let other?:
    complain("unknown option \(other)\n" + usage)
    exit(64)
}
