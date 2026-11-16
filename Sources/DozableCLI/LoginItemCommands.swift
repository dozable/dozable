import ArgumentParser
import Darwin
import Foundation
import DozableKit
import DozableHost
import DozableTUI

// 694 — the daemon's login item from the command line: `doz daemon login-item on|off|status`, the sync after a change of
// the daemon's settings (`doz config set|unset`), and the one-time notice after an upgrade. The rules are
// `DaemonLoginItem`'s (DozableHost); this file only asks and says.

struct HostLoginItemCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "login-item",
        abstract: "Start the daemon when you log in, from your desktop session (one login item in ~/Library/LaunchAgents, only when you say on).",
        discussion: """
            on: sets daemon.login_item = on and adds ONE login item for this store, which runs doz daemon start \
            --login-item when you log in (and every 15 minutes): it starts the daemon the usual way and exits — launchd \
            never runs the daemon itself. macOS may show "Background Items Added". off: removes it and sets \
            daemon.login_item = off. status (the default): what is there. doz uninstall removes it too.
            """,
        subcommands: [LoginItemOn.self, LoginItemOff.self, LoginItemStatusCommand.self],
        defaultSubcommand: LoginItemStatusCommand.self)
}

/// What `login-item on|off --json` prints.
struct LoginItemChange: Encodable {
    var setting: String
    var action: String
    var reason: String
    var loaded: Bool?
    var problem: String?
    var loginItem: LoginItemStatus
}

/// Write `daemon.login_item` (refused when the settings file does not parse — it is the person's), then sync this store's
/// item; the line says what happened.
func setLoginItem(_ value: String, _ g: GlobalOptions) throws {
    let store = g.dozableStore
    let now: DozableSettings
    do { now = try DozableSettings.load().writing(SettingKey.loginItem, .string(value)) } catch let e as SettingsError {
        throw fail(HostError(.failed, e.message), g)
    }
    let r = DaemonLoginItem.sync(store: store, mode: .command, settings: now)
    let st = DaemonLoginItem.status(store: store, settings: now)
    if g.json {
        Out.json(LoginItemChange(setting: value, action: r.decision.action.rawValue, reason: r.decision.reason, loaded: r.loaded,
                                 problem: r.problem, loginItem: st))
        return
    }
    Out.stdout("daemon.login_item = \(value)\n")
    Out.stdout(r.line + "\n")
    if value == "on", st.owner == "app" { Out.stdout("the Dozable menu bar app starts the daemon at login — doz adds no login item of its own\n") }
}

struct LoginItemOn: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "on", abstract: "Add the login item: the daemon starts when you log in.")
    @OptionGroup var g: GlobalOptions
    func run() async throws {
        try setLoginItem("on", g)
        offerKeepaliveAlways(g)
    }
}

/// 695: after `login-item on` — "Also keep this Mac's Claude login renewed when no sandbox uses it? [y/N]" on a terminal
/// (never --json, never a test run); off a terminal the command is printed. Nothing when the keep-alive is already always.
func offerKeepaliveAlways(_ g: GlobalOptions) {
    let terminal = isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1
    switch KeepaliveOffer.decide(mode: KeepaliveOffer.mode(g), terminal: terminal, json: g.json, quiet: g.quiet) {
    case .none: return
    case .hint: Out.stdout(KeepaliveOffer.hint + "\n")
    case .ask:
        let p = Prompter(yes: false, json: false)
        guard p.interactive else { Out.stdout(KeepaliveOffer.hint + "\n"); return }
        guard p.yesNo(KeepaliveOffer.question.trimmingCharacters(in: .whitespaces), default: false) else { return }
        do { Out.stdout("keep-alive \(KeepaliveMode.of(try setKeepaliveMode(.always, g)).rawValue)\n") }
        catch { Out.stderr("doz: the keep-alive was not changed — doz account keepalive always sets it\n") }
    }
}

struct LoginItemOff: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "off", abstract: "Remove the login item (and say no to it: daemon.login_item = off).")
    @OptionGroup var g: GlobalOptions
    func run() async throws { try setLoginItem("off", g) }
}

struct LoginItemStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Show the login item: set up or not, loaded, switched off, out of date. (Starts nothing.)")
    @OptionGroup var g: GlobalOptions
    func run() async throws {
        let st = DaemonLoginItem.status(store: g.dozableStore)
        if g.json { Out.json(st); return }
        Out.stdout(st.line + "\n")
        if st.installed, let p = st.program { Out.stdout("runs: \(DisplayPath.tilde(p)) daemon start --login-item (log: \(DisplayPath.tilde(g.dozableStore.loginItemLog.path)))\n") }
    }
}

/// After `doz config set|unset` (and the web settings route) of a daemon setting: the login item follows the rule.
func syncLoginItemAfterSettingChange(_ key: String, _ settings: DozableSettings, _ g: GlobalOptions) {
    guard [SettingKey.loginItem, SettingKey.alwaysOn, SettingKey.idleTimeout].contains(key) else { return }
    let r = DaemonLoginItem.sync(store: g.dozableStore, mode: .command, settings: settings)
    guard r.decision.action != .none, !g.json, !g.quiet else { return }
    Out.stdout("note: " + r.line + "\n")
}

/// 694 (decision 2): the one-time notice after the upgrade that made the daemon stay running — on the first interactive
/// command of a person (a terminal, not --json or -q, not a test run), while `daemon.login_item` is still `ask`. Its marker
/// sits beside the usage notice's (the settings folder), so it is said once per settings folder.
enum LoginItemNotice {
    static let text = "doz: the daemon now stays running. To also start it when you log in (sandboxes and kept sessions come back after the Mac restarts): doz daemon login-item on"
    static let markerName = "login-item-notice"

    /// The words of a command that never shows it: doz's own re-launches, help and version, the login item's own commands
    /// and the ones that ask about it themselves (onboard), and the ones that remove Dozable.
    static func applies(_ args: [String], env: [String: String] = ProcessInfo.processInfo.environment,
                        stderrTTY: Bool = isatty(STDERR_FILENO) == 1) -> Bool {
        if args.contains(where: { ["--json", "-q", "--quiet", "--help", "-h", "--version", "--launched", "--launch-detached", "--login-item"].contains($0) }) { return false }
        let w = UpdateHook.words(args)
        guard let first = w.first, !["help", "onboard", "uninstall", "nuke", "telemetry", "fence-connect"].contains(first) else { return false }
        if w.starts(with: ["daemon", "login-item"]) || w.starts(with: ["daemon", "upgrade-check"]) { return false }
        if w.contains(SettingKey.loginItem) { return false }
        // A guarded run never shows it — unless the test asks for it (DOZ_TEST_LOGIN_ITEM_NOTICE=1, guarded only).
        if TestSafety.guarded(env) { return env["DOZ_TEST_LOGIN_ITEM_NOTICE"] == "1" }
        return stderrTTY
    }

    /// Say it, once — when it applies and the setting is still `ask` with the daemon always on.
    static func afterCommand(_ args: [String], env: [String: String] = ProcessInfo.processInfo.environment) {
        guard applies(args, env: env) else { return }
        let s = DozableSettings.load(environment: env)
        guard (s.string(SettingKey.loginItem) ?? "ask") == "ask", s.bool(SettingKey.alwaysOn) || env["DOZ_TEST_LOGIN_ITEM_NOTICE"] == "1",
              let dir = DozableSettings.fileURL(environment: env)?.deletingLastPathComponent() else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // O_EXCL: the first process to make the marker says it; every other (and every later run) does not.
        let fd = open(dir.appendingPathComponent(markerName).path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return }
        close(fd)
        Out.stderr(text + "\n")
    }

    /// The question was asked (onboarding) or the person chose: the notice would only repeat it.
    static func markShown(env: [String: String] = ProcessInfo.processInfo.environment) {
        guard let dir = DozableSettings.fileURL(environment: env)?.deletingLastPathComponent() else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(dir.appendingPathComponent(markerName).path, O_WRONLY | O_CREAT | O_CLOEXEC, 0o600)
        if fd >= 0 { close(fd) }
    }
}
