import Foundation
import os

/// One `doz` command the menu bar app runs. The app talks to doz ONLY this way — never its socket, never its engine — so
/// every rule lives in the command (looking never starts the daemon, the held marker, the locked-Keychain refusal) and an
/// app built today works with every later doz (`--json` only gains fields).
public struct DozCommand: Equatable, Sendable {
    /// The command words and flags, without the executable (`["daemon", "status", "--json"]`).
    public let arguments: [String]
    /// Killed after this long (SIGTERM, then SIGKILL two seconds later).
    public let timeout: TimeInterval
    /// `.discard`: stdout and stderr go to /dev/null — never into this process (the dashboard's command).
    public let output: Output
    /// What the log may say about it: the command words only (never a value).
    public let label: String

    public enum Output: Equatable, Sendable { case capture, discard }

    public init(_ arguments: [String], timeout: TimeInterval, output: Output = .capture, label: String) {
        self.arguments = arguments; self.timeout = timeout; self.output = output; self.label = label
    }

    /// A look the app makes by itself (a refresh) is not the person's command: it says so to doz's usage statistics
    /// (an official build counts commands; the 60-second refresh would otherwise count 1,440 a day).
    static let notCounted = "--no-send-anonymous-usage-stats"

    public static let version = DozCommand(["--version"], timeout: 10, label: "--version")
    public static let status = DozCommand(["daemon", "status", "--json", notCounted], timeout: 10, label: "daemon status")
    public static let appStatus = DozCommand(["app", "status", "--json", notCounted], timeout: 10, label: "app status")
    public static let start = DozCommand(["daemon", "start", "--json"], timeout: 100, label: "daemon start")
    public static let stop = DozCommand(["daemon", "stop", "--json"], timeout: 300, label: "daemon stop")
    public static let restart = DozCommand(["daemon", "restart", "--json"], timeout: 300, label: "daemon restart")
    /// The dashboard: doz starts (or finds) its detached UI and opens the one-use link through LaunchServices itself.
    /// The link never passes through this app: no `--print-url`, and both outputs go to /dev/null, unread.
    public static let dashboard = DozCommand(["ui", "--detach", "--open", "-q"], timeout: 30, output: .discard, label: "ui --detach")
    /// Install the copy of this app that came with doz over the running one, and open the new one.
    public static let updateApp = DozCommand(["app", "install", "--open", "--json"], timeout: 60, label: "app install")
    /// Start at Login, told to doz once the app's job is loaded: doz then removes its own login item (never two).
    public static let loginItemOn = DozCommand(["config", "set", "daemon.login_item", "on", "--json"], timeout: 30,
                                               label: "config set daemon.login_item on")
    public static let loginItemOff = DozCommand(["config", "set", "daemon.login_item", "off", "--json"], timeout: 30,
                                                label: "config set daemon.login_item off")
}

/// What a command did.
public struct CommandResult: Equatable, Sendable {
    /// Its exit status; nil when it could not be started.
    public var exit: Int32?
    /// stdout (at most `CommandRunner.outputCap` bytes; empty for `.discard`).
    public var stdout: Data
    public var timedOut: Bool
    /// stdout was longer than the cap (the rest was read and dropped).
    public var truncated: Bool
    public var launchError: String?
    public var milliseconds: Int

    public init(exit: Int32?, stdout: Data = Data(), timedOut: Bool = false, truncated: Bool = false, launchError: String? = nil, milliseconds: Int = 0) {
        self.exit = exit; self.stdout = stdout; self.timedOut = timedOut; self.truncated = truncated
        self.launchError = launchError; self.milliseconds = milliseconds
    }

    public var ok: Bool { exit == 0 && !timedOut }
}

/// Runs doz. A protocol so the model and its tests never start a process.
public protocol CommandRunning: Sendable {
    func run(_ command: DozCommand, doz: String) -> CommandResult
}

/// The real runner: doz by ABSOLUTE path with an argv array — no shell, ever — stdin /dev/null, stdout read up to a cap
/// (1 MB), stderr discarded, a timeout per command. The log line names the command words and the exit, nothing else.
public struct CommandRunner: CommandRunning {
    public static let outputCap = 1 << 20
    public static let logger = Logger(subsystem: "com.dozable.app", category: "doz")

    /// Where the log line goes (os_log by default; a test collects it).
    public var log: @Sendable (String) -> Void

    public init(log: @escaping @Sendable (String) -> Void = { line in CommandRunner.logger.notice("\(line, privacy: .public)") }) {
        self.log = log
    }

    /// The process this runner would start for `command` — the executable and its arguments, nothing else decided here.
    public static func process(_ command: DozCommand, doz: String) -> Process? {
        guard doz.hasPrefix("/") else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: doz)
        p.arguments = command.arguments
        p.standardInput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        if command.output == .discard { p.standardOutput = FileHandle.nullDevice }
        return p
    }

    /// The log line for a finished command: its words and how it ended.
    public static func logLine(_ command: DozCommand, _ r: CommandResult) -> String {
        let end: String
        if let e = r.launchError { end = "could not start (\(e))" }
        else if r.timedOut { end = "timed out after \(Int(command.timeout)) s" }
        else { end = "exit \(r.exit.map(String.init) ?? "?")" }
        return "doz \(command.label) → \(end) in \(r.milliseconds) ms"
    }

    public func run(_ command: DozCommand, doz: String) -> CommandResult {
        let started = Date()
        func ms() -> Int { Int(Date().timeIntervalSince(started) * 1000) }
        guard let p = Self.process(command, doz: doz) else {
            let r = CommandResult(exit: nil, launchError: "not an absolute path", milliseconds: 0)
            log(Self.logLine(command, r))
            return r
        }
        let collector = OutputCollector(cap: Self.outputCap)
        var pipe: Pipe?
        if command.output == .capture {
            let out = Pipe()
            p.standardOutput = out
            pipe = out
        }
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch {
            let r = CommandResult(exit: nil, launchError: error.localizedDescription, milliseconds: ms())
            log(Self.logLine(command, r))
            return r
        }
        let reader = pipe.map { collector.drain($0.fileHandleForReading) }
        var timedOut = false
        if done.wait(timeout: .now() + command.timeout) == .timedOut {
            timedOut = true
            p.terminate()
            if done.wait(timeout: .now() + 2) == .timedOut {
                kill(p.processIdentifier, SIGKILL)
                done.wait()
            }
        }
        _ = reader?.wait(timeout: .now() + 2)
        let r = CommandResult(exit: p.terminationStatus, stdout: collector.data, timedOut: timedOut, truncated: collector.truncated, milliseconds: ms())
        log(Self.logLine(command, r))
        return r
    }
}

/// Reads a pipe to its end, keeping at most `cap` bytes (the rest is read and dropped, so the writer never blocks).
final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var over = false
    let cap: Int

    init(cap: Int) { self.cap = cap }

    func drain(_ h: FileHandle) -> DispatchSemaphore {
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            while true {
                let d = h.availableData
                if d.isEmpty { break }
                self.append(d)
            }
            finished.signal()
        }
        return finished
    }

    private func append(_ d: Data) {
        lock.lock(); defer { lock.unlock() }
        let room = cap - buffer.count
        if room <= 0 { over = true; return }
        if d.count > room { buffer.append(d.prefix(room)); over = true } else { buffer.append(d) }
    }

    var data: Data { lock.lock(); defer { lock.unlock() }; return buffer }
    var truncated: Bool { lock.lock(); defer { lock.unlock() }; return over }
}
