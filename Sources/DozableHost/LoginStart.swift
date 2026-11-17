import Darwin
import Foundation
import DozableKit

/// 694 — `doz daemon start --login-item`: what the login item's job runs, at login and every 15 minutes. It decides
/// (`decide`, pure — `LoginStartTests`), does at most one thing, writes ONE line to `<store>/login-item.log`, and exits 0
/// within seconds (≤ 300 ms when there is nothing to do). It never becomes the daemon: a daemon it starts is started the
/// usual way (`HostLauncher.spawn` — parent launchd, its own session), from the STABLE path.
///
///   (a) `<store>/daemon.held` is newer than this boot: `doz daemon stop` was the person's last word — nothing;
///   (b) a daemon answers: nothing — unless it cannot read the login keychain (started over ssh) and runs nothing (no
///       sandbox, no preparation, no fenced or kept session) while THIS session can: then it is asked to stop, and (d);
///   (c) `daemon.always_on` is off and nothing is kept: nothing;
///   (d) start one, and wait (≤ 90 s) for its socket.
public enum LoginStart {
    public enum Action: Equatable, Sendable {
        case held
        case running(Int32)
        case replaceLocked(Int32)
        case notNeeded
        case start
    }

    /// What a running daemon reports, as far as the decision needs it.
    public struct Daemon: Equatable, Sendable {
        public var pid: Int32
        public var keychainLocked: String?
        public var live: [String]
        public var preparations: [String]
        public var fenced: [String]
        public var keepers: Int
        public init(pid: Int32, keychainLocked: String?, live: [String] = [], preparations: [String] = [], fenced: [String] = [], keepers: Int = 0) {
            self.pid = pid; self.keychainLocked = keychainLocked; self.live = live; self.preparations = preparations
            self.fenced = fenced; self.keepers = keepers
        }
        public init(_ st: HostStatus) {
            self.init(pid: st.pid, keychainLocked: st.keychainLocked, live: st.liveSandboxes, preparations: st.preparations ?? [],
                      fenced: st.fencedSessions ?? [], keepers: st.keepers ?? 0)
        }
        /// Nothing a new daemon would cost: no sandbox with a VM, no preparation, no session on this Mac it serves or keeps.
        public var idle: Bool { live.isEmpty && preparations.isEmpty && fenced.isEmpty && keepers == 0 }
    }

    /// `heldAt`: the held marker's time (nil: none). `selfLocked`: THIS process cannot read the login keychain either (a
    /// person ran it from ssh) — then a locked daemon is not worth replacing.
    public static func decide(heldAt: Date?, bootTime: Date, daemon: Daemon?, alwaysOn: Bool, keepers: Int, selfLocked: Bool = false) -> Action {
        if let h = heldAt, h > bootTime { return .held }
        if let d = daemon {
            if d.keychainLocked != nil, d.idle, !selfLocked { return .replaceLocked(d.pid) }
            return .running(d.pid)
        }
        if !alwaysOn && keepers == 0 { return .notNeeded }
        return .start
    }

    // MARK: the held marker

    /// When `doz daemon stop` held the daemon (nil: not held).
    public static func heldAt(_ store: DozableStore) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: store.heldFile.path))?[.modificationDate] as? Date
    }

    /// `doz daemon stop` while always on: the 15-minute look starts nothing until the next boot or any command's start.
    public static func hold(_ store: DozableStore) {
        try? store.ensureDirectory()
        try? Data("held by doz daemon stop — removed by the next command that starts the daemon\n".utf8).write(to: store.heldFile, options: .atomic)
    }

    /// Any start of a daemon lets go of the hold.
    public static func release(_ store: DozableStore) { unlink(store.heldFile.path) }

    // MARK: the boot time

    /// This boot's time (`kern.boottime`); in a test run, `DOZ_TEST_BOOT_TIME` (seconds since 1970) stands in for it.
    public static func bootTime(environment env: [String: String] = ProcessInfo.processInfo.environment) -> Date {
        if TestSafety.testRun(env), let s = env["DOZ_TEST_BOOT_TIME"], let t = Double(s) { return Date(timeIntervalSince1970: t) }
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &tv, &size, nil, 0) == 0 else { return .distantPast }
        return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6)
    }

    // MARK: the log

    /// One line in `<store>/login-item.log` (the menu bar app's job has no StandardOutPath: doz writes its own line). Cut back
    /// to empty above 256 KiB.
    public static func log(_ store: DozableStore, _ line: String, now: Date = Date()) {
        let url = store.loginItemLog
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > DaemonLoginItem.logLimit {
            _ = truncate(url.path, 0)
        }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return }
        defer { close(fd) }
        let d = Data("\(f.string(from: now)) doz daemon start --login-item (pid \(getpid())): \(line)\n".utf8)
        _ = d.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }

    // MARK: the job

    /// Run the job for `store`. Always returns 0 (launchd needs no exit code; what happened is in the log).
    public static func run(store: DozableStore, environment env: [String: String] = ProcessInfo.processInfo.environment) -> Int32 {
        TestSafety.checkStore(store.root)
        try? store.ensureDirectory()
        let settings = DozableSettings.load(environment: env)
        let alwaysOn = settings.bool(SettingKey.alwaysOn)
        // Kept sessions come later (then the store's kept records count here); chat on counts as one: it needs the daemon.
        let keepers = settings.bool(SettingKey.chatEnabled) ? 1 : 0
        var daemon: Daemon?
        if HostClient.connectAny(store).map({ close($0); return true }) == true,
           let m = try? HostClient.request(HostRequest(.ping), store: store, autostart: false), m.ok == true,
           let st = try? m.result?.decode(HostStatus.self) {
            daemon = Daemon(st)
        }
        let selfLocked = HostSessionKind.lockedReason(environment: env) != nil
        let action = decide(heldAt: heldAt(store), bootTime: bootTime(environment: env), daemon: daemon, alwaysOn: alwaysOn,
                            keepers: keepers, selfLocked: selfLocked)
        switch action {
        case .held:
            log(store, "held — doz daemon stop was the last word; nothing started (until a doz command, or the next login)")
            return 0
        case .running(let pid):
            if daemon?.keychainLocked != nil {
                log(store, "a daemon runs (pid \(pid)); it cannot read the login keychain, but it serves something — left running")
            } else {
                log(store, "a daemon runs (pid \(pid)) — nothing to do")
            }
            return 0
        case .notNeeded:
            log(store, "daemon.always_on is off and nothing is kept — nothing to start")
            return 0
        case .replaceLocked(let pid):
            log(store, "the running daemon (pid \(pid)) cannot read the login keychain and runs nothing — replacing it with one started here")
            _ = try? HostClient.request(HostRequest(.hostStop), store: store, autostart: false)
            let deadline = Date().addingTimeInterval(30)
            while store.hostIsRunning() && Date() < deadline { usleep(50_000) }
            if store.hostIsRunning() {
                log(store, "the locked daemon (pid \(pid)) did not stop within 30 s — left as it is")
                return 0
            }
        case .start:
            break
        }
        let program = StableExecutable.path()
        do {
            let pid = try HostLauncher.spawn(store: store, executable: FileManager.default.isExecutableFile(atPath: program) ? program : HostLauncher.executablePath)
            if HostClient.waitForHost(store: store, seconds: 90) {
                log(store, "started the daemon (pid \(pid), \(program))")
            } else {
                log(store, "started the daemon (pid \(pid)) but it did not answer within 90 s — see \(store.logFile.path)")
            }
        } catch {
            log(store, "could not start the daemon: \(error)")
        }
        return 0
    }
}

/// 694 — how a CLIENT starts a daemon (`HostClient.connect(autostart:)`, `doz daemon start`, `doz daemon restart`): the
/// held marker goes (any start lets go of it); from a session where the login keychain is locked (ssh), while a login item
/// is LOADED (this store's, or the menu bar app's), launchd is asked to run it now in the desktop session (`kickstart`), so
/// the daemon can read the login keychain — waited for 15 s, said, and on failure today's start with today's warning.
public enum DaemonStarter {
    public enum How: Equatable, Sendable {
        case spawned(Int32)
        case kickstarted(String)
    }

    /// The loaded login item a locked client can kickstart (its label; nil: none loaded, or a guarded run without seams).
    public static func loadedItem(_ store: DozableStore, launchctl: Launchctl? = Launchctl.forLooking(),
                                  folder: URL? = LaunchAgentsFolder.forLooking()) -> String? {
        guard let launchctl, let folder else { return nil }
        let mine = DaemonLoginItem.label(store)
        if FileManager.default.fileExists(atPath: DaemonLoginItem.plistURL(store, folder: folder).path), launchctl.printJob(label: mine) != nil {
            return mine
        }
        if DaemonLoginItem.appJob(launchctl).loaded { return DaemonLoginItem.appLabel }
        return nil
    }

    /// Start a daemon for `store`. With `.kickstarted`, the daemon already answers its socket; with `.spawned`, the caller
    /// waits for it as before.
    public static func start(store: DozableStore, extra: [String] = [],
                             environment env: [String: String] = ProcessInfo.processInfo.environment) throws -> How {
        LoginStart.release(store)
        if HostSessionKind.lockedReason(environment: env) != nil, let label = loadedItem(store) {
            if let lc = Launchctl.forLooking(environment: env), lc.kickstart(label: label).ok, HostClient.waitForHost(store: store, seconds: 15) {
                FileHandle.standardError.write(Data("doz: started the daemon in your desktop session (login item)\n".utf8))
                return .kickstarted(label)
            }
            FileHandle.standardError.write(Data("doz: the login item did not start the daemon in your desktop session within 15 s — starting one here\n".utf8))
        }
        return .spawned(try HostLauncher.spawn(store: store, extra: extra))
    }
}
