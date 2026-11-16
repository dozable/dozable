import Darwin
import Foundation

/// 694 — launchd, as the login item needs it: `bootstrap` (load the item), `bootout` (unload it), `kickstart` (run it now,
/// in the desktop session — the locked-Keychain guard), `print` (is it loaded? which program does a job run?) and
/// `print-disabled` (did the person switch it off in System Settings › Login Items?), all in the person's own GUI domain
/// (`gui/<uid>`). Nothing else of launchd is used: the daemon is never a launchd job (`DaemonLoginItem`).
///
/// The program is the real `/bin/launchctl`, or — in a GUARDED run only — `DOZ_TEST_LAUNCHCTL` (the Makefile sets a refusing
/// fake for every test target; `make test-cli-daemon` a recording one). A guarded process that would run the real one, for
/// any verb, STOPS (`TestSafety.launchctlViolation`). Unit tests inject a closure (`init(fake:)`) and exec nothing.
public struct Launchctl: Sendable {
    public struct Result: Equatable, Sendable {
        public var code: Int32
        /// stdout and stderr together.
        public var output: String
        public init(code: Int32, output: String) { self.code = code; self.output = output }
        public var ok: Bool { code == 0 }
    }

    /// The program run (`/bin/launchctl`, a test's fake; `(fake)` for an injected closure).
    public let path: String
    let runner: (@Sendable ([String]) -> Result)?
    let uid: uid_t

    public init(path: String, uid: uid_t = getuid()) {
        self.path = path
        self.uid = uid
        runner = nil
    }

    /// A launchctl that runs nothing: `fake` answers each argv (unit tests).
    public init(uid: uid_t = 501, fake: @escaping @Sendable ([String]) -> Result) {
        path = "(fake)"
        self.uid = uid
        runner = fake
    }

    /// This process's launchctl: the seam in a test run (`TestSafety.testRun`), else the real one.
    public static func current(environment env: [String: String] = ProcessInfo.processInfo.environment) -> Launchctl {
        if TestSafety.testRun(env), let p = env["DOZ_TEST_LAUNCHCTL"], !p.isEmpty { return Launchctl(path: p) }
        return Launchctl(path: TestSafety.realLaunchctl)
    }

    /// For a LOOK: nil in a guarded run that has no seam (nothing of launchd is read); else `current`.
    public static func forLooking(environment env: [String: String] = ProcessInfo.processInfo.environment) -> Launchctl? {
        if TestSafety.guarded(env), (env["DOZ_TEST_LAUNCHCTL"] ?? "").isEmpty { return nil }
        return current(environment: env)
    }

    // MARK: argv (pure — LaunchctlTests)

    /// The person's GUI domain.
    public static func domain(uid: uid_t) -> String { "gui/\(uid)" }
    public static func service(_ label: String, uid: uid_t) -> String { "\(domain(uid: uid))/\(label)" }

    public static func bootstrapArguments(plist: String, uid: uid_t) -> [String] { ["bootstrap", domain(uid: uid), plist] }
    public static func bootoutArguments(label: String, uid: uid_t) -> [String] { ["bootout", service(label, uid: uid)] }
    /// No `-k`: a job that runs already is left alone (the login item's job is short; a running one is doing the work).
    public static func kickstartArguments(label: String, uid: uid_t) -> [String] { ["kickstart", service(label, uid: uid)] }
    public static func printArguments(label: String, uid: uid_t) -> [String] { ["print", service(label, uid: uid)] }
    public static func printDisabledArguments(uid: uid_t) -> [String] { ["print-disabled", domain(uid: uid)] }

    // MARK: running it

    /// Run launchctl with `args` (at most `timeout` seconds). In a guarded run the real one is never run: the process stops.
    public func run(_ args: [String], timeout: Double = 15,
                    environment env: [String: String] = ProcessInfo.processInfo.environment) -> Result {
        if let runner { return runner(args) }
        TestSafety.enforce(TestSafety.launchctlViolation(path), env: env)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return Result(code: -1, output: "could not run \(path): \(error.localizedDescription)") }
        let collected = LaunchctlOutput()
        let reader = Thread { collected.data = out.fileHandleForReading.readDataToEndOfFile() }
        reader.start()
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { usleep(5_000) }
        if p.isRunning { p.terminate(); usleep(200_000); if p.isRunning { kill(p.processIdentifier, SIGKILL) } }
        p.waitUntilExit()
        let readDeadline = Date().addingTimeInterval(2)
        while !collected.done && Date() < readDeadline { usleep(2_000) }
        return Result(code: p.terminationStatus, output: String(decoding: collected.data ?? Data(), as: UTF8.self))
    }

    public func bootstrap(plist: String) -> Result { run(Self.bootstrapArguments(plist: plist, uid: uid)) }
    public func bootout(label: String) -> Result { run(Self.bootoutArguments(label: label, uid: uid)) }
    public func kickstart(label: String) -> Result { run(Self.kickstartArguments(label: label, uid: uid)) }

    /// What `print` says of a job (nil: launchd has no such job loaded in the person's GUI domain).
    public func printJob(label: String) -> String? {
        let r = run(Self.printArguments(label: label, uid: uid))
        return r.ok ? r.output : nil
    }

    /// Whether the person switched `label` off (System Settings › Login Items — `print-disabled`); nil: not known.
    public func disabled(label: String) -> Bool? {
        let r = run(Self.printDisabledArguments(uid: uid))
        guard r.ok else { return nil }
        return Self.parseDisabled(r.output, label: label)
    }

    // MARK: parsing (pure — LaunchctlTests)

    /// `print-disabled`'s line for `label`: `"label" => disabled|true` (switched off) or `=> enabled|false`. nil: not listed.
    public static func parseDisabled(_ output: String, label: String) -> Bool? {
        for line in output.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("\"\(label)\"") else { continue }
            guard let arrow = t.range(of: "=>") else { continue }
            let v = t[arrow.upperBound...].trimmingCharacters(in: .whitespaces).lowercased()
            if v.hasPrefix("disabled") || v.hasPrefix("true") { return true }
            if v.hasPrefix("enabled") || v.hasPrefix("false") { return false }
        }
        return nil
    }

    /// The plist a loaded job came from, from `print`'s `path = …` line — only when it is an absolute path (an SMAppService
    /// job says `path = (submitted by …)`, which is not).
    public static func parsePath(_ output: String) -> String? {
        for line in output.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("path = ") {
                let p = String(t.dropFirst("path = ".count))
                return p.hasPrefix("/") ? p : nil
            }
        }
        return nil
    }

    /// The program a loaded job runs, from `print`'s output: its `program = …` line, else the first of its `arguments = {`.
    public static func parseProgram(_ output: String) -> String? {
        var inArguments = false
        for line in output.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if inArguments {
                if t == "}" { inArguments = false; continue }
                if !t.isEmpty { return t }
                continue
            }
            if t.hasPrefix("program = ") { return String(t.dropFirst("program = ".count)) }
            if t.hasPrefix("arguments = {") { inArguments = true }
        }
        return nil
    }
}

/// 694 — the per-user LaunchAgents folder a login item lives in: `~/Library/LaunchAgents` of the real home, or — in a test
/// run only — `DOZ_TEST_LAUNCH_AGENTS_DIR` (the Makefile's scratch folder). A guarded process that would still reach the
/// real one (read, write or remove) STOPS here, before anything is touched.
public enum LaunchAgentsFolder {
    /// For a LOOK (status, doctor, a daemon's start): nil in a guarded run that has no seam — then nothing is looked at
    /// (said as such), rather than the real folder read. Anything that WRITES or REMOVES uses `current`, which stops.
    public static func forLooking(environment env: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        if TestSafety.guarded(env), (env["DOZ_TEST_LAUNCH_AGENTS_DIR"] ?? "").isEmpty { return nil }
        return current(environment: env)
    }

    public static func current(environment env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if TestSafety.testRun(env), let d = env["DOZ_TEST_LAUNCH_AGENTS_DIR"], !d.isEmpty {
            let u = URL(fileURLWithPath: (d as NSString).expandingTildeInPath).standardizedFileURL
            TestSafety.enforce(TestSafety.launchAgentsViolation(u), env: env)
            return u
        }
        let real = TestSafety.realLaunchAgents()
        TestSafety.enforce(TestSafety.launchAgentsViolation(real), env: env)
        return real
    }
}

/// launchctl's output, read on its own thread.
final class LaunchctlOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var _data: Data?
    var data: Data? {
        get { lock.withLock { _data } }
        set { lock.withLock { _data = newValue } }
    }
    var done: Bool { lock.withLock { _data != nil } }
}
