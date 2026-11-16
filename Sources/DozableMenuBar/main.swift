import Foundation
import DozableMenuBarCore

// Dozable.app — the menu bar app. It shows the daemon's state, starts, stops and restarts it, and opens the dashboard —
// all by running the `doz` command (docs/engineering/menu-bar-app.md). With no argument it is the menu (AppKit); the
// arguments below are modes that never start NSApplication, never draw anything and exit:
//
//   --dump-menu            the menu it would show now, as JSON (what a person over ssh, or a test, can look at)
//   --run-action ACTION    run one item's doz command (start|stop|restart|dashboard) and print the outcome — a TEST seam:
//                          guarded runs only (DOZ_TEST_GUARD=1)
//   --self-config          what this copy is (identifier, version, the doz it needs) — the release's check
//   --version, --help

let env = ProcessInfo.processInfo.environment
let arguments = Array(CommandLine.arguments.dropFirst())
let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String

func say(_ s: String) { FileHandle.standardOutput.write(Data((s + "\n").utf8)) }
func complain(_ s: String) { FileHandle.standardError.write(Data(("Dozable: " + s + "\n").utf8)) }

let usage = """
    usage: Dozable                      the menu bar app (opened from Finder or with open -a Dozable)
           Dozable --dump-menu          print the menu it would show now, as JSON
           Dozable --self-config        print what this copy is, as JSON
           Dozable --version
    Install it with: doz app install
    """

func source() -> SnapshotSource {
    SnapshotSource(locator: .standard(env: env), runner: CommandRunner(), appVersion: appVersion)
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
    runMenuBarApp(source: source())
case "--dump-menu"?:
    say(MenuDump(source().snapshot()).json())
    exit(0)
case "--run-action"?:
    guard MenuBarSeams.guarded(env) else {
        complain("--run-action is a test seam (guarded runs only); a person uses the menu, or doz itself")
        exit(64)
    }
    guard let i = arguments.firstIndex(of: "--run-action"), i + 1 < arguments.count,
          let action = MenuAction(rawValue: arguments[i + 1]), [.start, .stop, .restart, .dashboard].contains(action) else {
        complain("--run-action start|stop|restart|dashboard")
        exit(64)
    }
    let error = source().perform(action)
    say(jsonLine(["action": action.rawValue, "ok": error == nil, "error": error ?? NSNull()]))
    exit(error == nil ? 0 : 1)
case "--self-config"?:
    say(jsonLine(["bundleIdentifier": Bundle.main.bundleIdentifier ?? NSNull(), "version": appVersion ?? NSNull(),
                  "minimumDoz": MenuBarApp.minimumDoz, "executable": Bundle.main.executablePath ?? NSNull()]))
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
