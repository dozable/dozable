import Foundation

// Start at Login — the menu bar app's ONE switch (docs/engineering/menu-bar-app.md, "Start at Login"). It registers two
// things through SMAppService, and only on the person's click: the agent `com.dozable.app.daemon` (its plist sealed inside
// the bundle, `Contents/Library/LaunchAgents/`; launchd runs this app's own executable with `--launch-daemon`, which runs
// `doz daemon start --login-item`) and the app itself (`SMAppService.mainApp`: the menu comes back at login). Then it tells
// doz (`doz config set daemon.login_item on`), which removes its own login item while the app's job is loaded — never two.
//
// ServiceManagement is imported ONLY by the executable target (the audit holds it): this module has the protocol, the
// recording implementation every test run uses, the flow and the menu's states — all without SMAppService.

/// The agent plist inside the bundle: its name, and exactly the keys it carries (no others — `AgentPlistTests`, the
/// release's check). `Label` equals doz's reserved `DaemonLoginItem.appLabel` (a DozableCLITests row reads the file).
public enum AgentPlist {
    public static let label = "com.dozable.app.daemon"
    public static let fileName = label + ".plist"
    /// Where it sits in the bundle (SMAppService.agent(plistName:) looks there).
    public static let bundlePath = "Contents/Library/LaunchAgents/" + fileName
    /// The flag launchd runs this app's executable with.
    public static let launchFlag = "--launch-daemon"

    /// The keys and their values — the same as doz's own login item, but for the program: launchd runs THIS app's
    /// executable (`BundleProgram`, relative to the bundle — a sealed plist cannot name where doz is installed).
    public static var expected: [String: Any] {
        ["Label": label,
         "BundleProgram": "Contents/MacOS/Dozable",
         "ProgramArguments": ["Dozable", launchFlag],
         "RunAtLoad": true,
         "StartInterval": 900,
         "LimitLoadToSessionType": "Aqua",
         "AbandonProcessGroup": true,
         // Interactive, not Standard: a Standard agent's daemon (and every session it holds) ran at utility QoS, pri 20 —
         // mostly the efficiency cores.
         "ProcessType": "Interactive"]
    }

    /// What is wrong with a plist (empty: it is exactly the expected one).
    public static func problems(_ plist: [String: Any]) -> [String] {
        var out: [String] = []
        let want = expected
        let extra = Set(plist.keys).subtracting(want.keys).sorted()
        let missing = Set(want.keys).subtracting(plist.keys).sorted()
        if !extra.isEmpty { out.append("keys it must not have: " + extra.joined(separator: ", ")) }
        if !missing.isEmpty { out.append("keys missing: " + missing.joined(separator: ", ")) }
        for (k, v) in want where plist[k] != nil {
            if !(plist[k].map { equal($0, v) } ?? false) { out.append("\(k) is \(plist[k]!), not \(v)") }
        }
        return out
    }

    /// Plist values compared by kind (a Bool is never a 1, a String never a number).
    static func equal(_ a: Any, _ b: Any) -> Bool {
        switch (a, b) {
        case let (x as String, y as String): return x == y
        case let (x as [String], y as [String]): return x == y
        case let (x as NSNumber, y as Bool):
            return CFGetTypeID(x) == CFBooleanGetTypeID() && x.boolValue == y
        case let (x as NSNumber, y as Int):
            return CFGetTypeID(x) != CFBooleanGetTypeID() && x.intValue == y
        default: return false
        }
    }
}

/// What SMAppService says of one service (its `Status`, by name).
public enum LoginServiceStatus: String, Equatable, Sendable, Encodable {
    case notRegistered, enabled, requiresApproval, notFound

    /// Registered and waiting for, or holding, the person's approval.
    public var registered: Bool { self == .enabled || self == .requiresApproval }
}

/// Both services' states.
public struct LoginServiceState: Equatable, Sendable, Encodable {
    public var agent: LoginServiceStatus
    public var mainApp: LoginServiceStatus
    public init(agent: LoginServiceStatus, mainApp: LoginServiceStatus) { self.agent = agent; self.mainApp = mainApp }
    public static let none = LoginServiceState(agent: .notRegistered, mainApp: .notRegistered)
    /// Either one waits for the person in System Settings › Login Items.
    public var needsApproval: Bool { agent == .requiresApproval || mainApp == .requiresApproval }
}

/// SMAppService, as this app uses it. The real one is in the executable target (the only place ServiceManagement is
/// imported); every test run gets `RecordingLoginItemService`, which records what it would do and calls nothing.
public protocol LoginItemService: Sendable {
    func state() -> LoginServiceState
    /// Register the agent, then the app. Lines saying what was done; an error (one line) when it failed.
    func register() -> (lines: [String], error: String?)
    /// Unregister both.
    func unregister() -> (lines: [String], error: String?)
    /// System Settings › General › Login Items & Extensions.
    func openSystemSettings() -> [String]
}

/// The test run's LoginItemService: it NEVER calls SMAppService or launchctl. It appends "would register …" / "would
/// unregister …" lines to `DOZ_TEST_LOGIN_ITEM_LOG` and keeps the two states in `DOZ_TEST_LOGIN_ITEM_STATE` (JSON
/// `{"agent": …, "mainApp": …}`), so a later run of the app (and the suite's fake launchctl) sees what a registration
/// would have left. `DOZ_TEST_LOGIN_ITEM_RESULT=requiresApproval` makes a registration end there, as when the person
/// has switched Dozable off in System Settings.
public struct RecordingLoginItemService: LoginItemService {
    public let env: [String: String]
    public init(env: [String: String]) { self.env = env }

    var logPath: String? { env["DOZ_TEST_LOGIN_ITEM_LOG"].flatMap { $0.hasPrefix("/") ? $0 : nil } }
    var statePath: String? { env["DOZ_TEST_LOGIN_ITEM_STATE"].flatMap { $0.hasPrefix("/") ? $0 : nil } }

    func record(_ lines: [String]) {
        guard let logPath, !lines.isEmpty else { return }
        let d = Data(lines.map { $0 + "\n" }.joined().utf8)
        if let h = FileHandle(forWritingAtPath: logPath) { h.seekToEndOfFile(); h.write(d); try? h.close() }
        else { FileManager.default.createFile(atPath: logPath, contents: d) }
    }

    func save(_ s: LoginServiceState) {
        guard let statePath, let d = try? JSONEncoder().encode(s) else { return }
        try? d.write(to: URL(fileURLWithPath: statePath), options: .atomic)
    }

    public func state() -> LoginServiceState {
        guard let statePath, let d = FileManager.default.contents(atPath: statePath),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: String] else { return .none }
        return LoginServiceState(agent: o["agent"].flatMap(LoginServiceStatus.init) ?? .notRegistered,
                                 mainApp: o["mainApp"].flatMap(LoginServiceStatus.init) ?? .notRegistered)
    }

    public func register() -> (lines: [String], error: String?) {
        let lines = ["would register agent \(AgentPlist.label)", "would register mainApp"]
        record(lines)
        let result = env["DOZ_TEST_LOGIN_ITEM_RESULT"].flatMap(LoginServiceStatus.init) ?? .enabled
        save(LoginServiceState(agent: result, mainApp: result))
        return (lines, nil)
    }

    public func unregister() -> (lines: [String], error: String?) {
        let lines = ["would unregister agent \(AgentPlist.label)", "would unregister mainApp"]
        record(lines)
        save(.none)
        return (lines, nil)
    }

    public func openSystemSettings() -> [String] {
        let lines = ["would open System Settings › Login Items"]
        record(lines)
        return lines
    }
}

/// Whether launchd has the agent loaded in the person's GUI domain — `launchctl print gui/<uid>/<label>`, a LOOK only (the
/// app never runs any other launchctl verb). In a test run (`DOZ_TEST_GUARD=1` or `DOZ_TEST_REAL_MAC=1`) only the seam
/// `DOZ_TEST_LAUNCHCTL` is run, never /bin/launchctl; without it the job is not loaded.
public struct LaunchdLook: Sendable {
    public var program: String?
    public init(env: [String: String]) {
        if MenuBarSeams.testRun(env) {
            program = env["DOZ_TEST_LAUNCHCTL"].flatMap { $0.hasPrefix("/") ? $0 : nil }
        } else {
            program = "/bin/launchctl"
        }
    }
    public init(program: String?) { self.program = program }

    public func loaded(_ label: String = AgentPlist.label) -> Bool {
        guard let program else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: program)
        p.arguments = ["print", "gui/\(getuid())/\(label)"]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        let deadline = Date().addingTimeInterval(10)
        while p.isRunning, Date() < deadline { usleep(10_000) }
        if p.isRunning { p.terminate(); p.waitUntilExit(); return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}

/// What a click on Start at Login did, step by step (`--run-action login-on|login-off` prints it).
public struct LoginOutcome: Equatable, Sendable, Encodable {
    public var steps: [String]
    /// nil: done. Else one line for the menu.
    public var error: String?
    /// macOS waits for the person's approval (System Settings › Login Items).
    public var needsApproval: Bool
}

/// The two clicks. The order is the design's: ON registers (agent, then the app), and only once SMAppService says
/// `.enabled` AND launchd shows the job loaded does doz hear `daemon.login_item on` (it then removes its own item — never
/// two); OFF unregisters both, then `daemon.login_item off`.
public enum LoginItemFlow {
    public static let loadedWait: TimeInterval = 10

    public static func turnOn(service: LoginItemService, look: LaunchdLook, runner: CommandRunning, doz: String?,
                              wait: TimeInterval = loadedWait) -> LoginOutcome {
        var o = LoginOutcome(steps: [], error: nil, needsApproval: false)
        guard let doz else { o.error = "Start at Login needs doz — it is not installed"; return o }
        let r = service.register()
        o.steps += r.lines
        if let e = r.error { o.error = "Could not turn on Start at Login: \(e)"; return o }
        let st = service.state()
        o.steps.append("agent \(st.agent.rawValue), mainApp \(st.mainApp.rawValue)")
        if st.needsApproval {
            o.needsApproval = true
            o.error = "Start at Login needs your approval in System Settings › Login Items"
            return o
        }
        guard st.agent == .enabled else {
            o.error = "Start at Login did not turn on (macOS says \(st.agent.rawValue))"
            return o
        }
        let deadline = Date().addingTimeInterval(wait)
        var loaded = look.loaded()
        while !loaded, Date() < deadline { usleep(250_000); loaded = look.loaded() }
        guard loaded else {
            o.steps.append("job not loaded")
            o.error = "Start at Login is on, but launchd has not loaded it yet — doz keeps its own login item until it has (choose Start at Login again later)"
            return o
        }
        o.steps.append("job loaded")
        let c = runner.run(.loginItemOn, doz: doz)
        o.steps.append("doz \(DozCommand.loginItemOn.label) → \(c.ok ? "exit 0" : SnapshotSource.failure(c))")
        if !c.ok { o.error = "Start at Login is on, but doz did not take it (\(SnapshotSource.failure(c)))" }
        return o
    }

    public static func turnOff(service: LoginItemService, runner: CommandRunning, doz: String?) -> LoginOutcome {
        var o = LoginOutcome(steps: [], error: nil, needsApproval: false)
        let r = service.unregister()
        o.steps += r.lines
        if let e = r.error { o.error = "Could not turn off Start at Login: \(e)"; return o }
        guard let doz else { return o }
        let c = runner.run(.loginItemOff, doz: doz)
        o.steps.append("doz \(DozCommand.loginItemOff.label) → \(c.ok ? "exit 0" : SnapshotSource.failure(c))")
        if !c.ok { o.error = "Start at Login is off, but doz did not take it (\(SnapshotSource.failure(c)))" }
        return o
    }
}

/// What the menu knows about Start at Login.
public struct LoginSnapshot: Equatable, Sendable {
    public var service: LoginServiceState
    /// This copy runs from a place SMAppService can keep (Applications) — see `LoginPlace`.
    public var stablePlace: Bool
    public init(service: LoginServiceState, stablePlace: Bool) { self.service = service; self.stablePlace = stablePlace }
}

/// Where a copy of the app may hold a login item: directly in /Applications or ~/Applications (where `doz app install`
/// puts it — Background Task Management records the bundle's path, and doz looks for the app there). In a test run the
/// seam `DOZ_TEST_APPLICATIONS_DIR` is the one place.
public enum LoginPlace {
    public static func places(env: [String: String], home: String = NSHomeDirectory()) -> [String] {
        if MenuBarSeams.testRun(env) {
            return env["DOZ_TEST_APPLICATIONS_DIR"].flatMap { $0.hasPrefix("/") ? [$0] : nil } ?? []
        }
        return ["/Applications", (home as NSString).appendingPathComponent("Applications")]
    }

    public static func isStable(bundlePath: String?, env: [String: String], home: String = NSHomeDirectory()) -> Bool {
        guard let bundlePath, bundlePath.hasSuffix(".app") else { return false }
        let parent = canonical((bundlePath as NSString).deletingLastPathComponent)
        return places(env: env, home: home).contains { canonical($0) == parent }
    }

    static func canonical(_ p: String) -> String {
        guard let r = realpath(p, nil) else { return (p as NSString).standardizingPath }
        defer { free(r) }
        return String(cString: r)
    }
}
