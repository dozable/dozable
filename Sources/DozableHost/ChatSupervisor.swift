import Darwin
import DozableChat
import Foundation

// The daemon runs the chat server as its child, on this Mac only (docs/engineering/chat.md, "Under the daemon").
//
// Wanted: `chat.enabled`, while the daemon is not stopping and its program has not been replaced (an update's restart in
// place brings a server up from the new build). The daemon's loop calls `tick` every second; a `doz chat …` change calls
// it at once. Each tick: the generated files are brought up to date; a server started with other bytes is restarted; a
// server that exited is judged by `ChatRestartPolicy`; one not ready within 15 s is stopped and counted as a failure.
//
// The child: the daemon's own program (`doz chat serve … --supervised`), started with posix_spawn (never a shell), an
// environment allowlist, stdin /dev/null, stdout and stderr to server.log, no other descriptor, its own process group.
// `--supervised` makes it exit the moment the daemon is gone, even after a SIGKILL. A stop is SIGTERM, 5 s, then SIGKILL,
// and it always happens before the daemon lets go of the store's lock (shutdown, restart in place, hand-over).
//
// Every piece of work runs on ONE serial queue, so the state is never touched twice at once and a stop may block.

/// The supervisor's state, as `doz daemon status --json`, `doz chat status` and `doz doctor` read it (and
/// `supervisor.json`). No token, ever.
public struct ChatServerState: Codable, Equatable, Sendable {
    /// `chat.enabled`.
    public var enabled = false
    /// off · starting · running · restarting · failing · stopped (a fault a restart cannot fix) · waiting (the daemon is
    /// stopping or restarting).
    public var state = "off"
    public var pid: Int32?
    public var ready = false
    public var bind = ChatConfigFile.bind
    public var pagePort = 8790
    public var linePort = 8791
    /// Restarts after the server exited by itself (or was killed) — not the ones for a change of its files.
    public var restarts = 0
    /// How the last server ended: `exit N` or `signal N`.
    public var lastExit: String?
    /// What is wrong, in a person's words (a stopped server's last line, the port to change).
    public var problem: String?
    public var startedAt: Date?
    public var updatedAt: Date?

    public init() {}

    public static func load(_ paths: ChatPaths) -> ChatServerState? {
        guard let d = FileManager.default.contents(atPath: paths.supervisor) else { return nil }
        return try? Self.decoder.decode(ChatServerState.self, from: d)
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]; e.dateEncodingStrategy = .iso8601; return e
    }()
    static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
}

/// How a child ended.
public struct ChatChildExit: Equatable, Sendable {
    public var code: Int32?
    public var signal: Int32?
    public init(code: Int32? = nil, signal: Int32? = nil) { self.code = code; self.signal = signal }
    public var text: String { code.map { "exit \($0)" } ?? signal.map { "signal \($0)" } ?? "ended" }
}

/// What the supervisor asks of the system — a seam: the tests hand it a fake.
public protocol ChatProcesses: Sendable {
    func spawn(executable: String, arguments: [String], environment: [String: String], log: String) throws -> pid_t
    /// nil: still running.
    func reap(_ pid: pid_t) -> ChatChildExit?
    func signal(_ pid: pid_t, _ sig: Int32)
    /// The server on a data folder: who holds its lock, and whether it says it is ready.
    func server(dataDir: String) -> (pid: Int32?, ready: Bool)
    func arguments(of pid: pid_t) -> [String]?
    /// Whether a TCP port on 127.0.0.1 is taken by someone (to say which setting to change).
    func portInUse(_ port: Int) -> Bool
}

/// The settings the supervisor follows.
public struct ChatSettingsView: Equatable, Sendable {
    public var enabled: Bool
    public var pagePort: Int
    public var linePort: Int
    /// The dashboards' ports, which chat must never take (`ui.port`, `serve.port`).
    public var dashboards: [String: Int]

    public init(enabled: Bool, pagePort: Int = 8790, linePort: Int = 8791, dashboards: [String: Int] = [:]) {
        self.enabled = enabled; self.pagePort = pagePort; self.linePort = linePort; self.dashboards = dashboards
    }

    public static func read(_ s: DozableSettings = .load()) -> ChatSettingsView {
        ChatSettingsView(enabled: s.bool(SettingKey.chatEnabled), pagePort: s.int(SettingKey.chatPagePort), linePort: s.int(SettingKey.chatLinePort),
                         dashboards: [SettingKey.uiPort: s.int(SettingKey.uiPort), SettingKey.servePort: s.int(SettingKey.servePort)])
    }
}

public final class ChatSupervisor: @unchecked Sendable {
    public let paths: ChatPaths
    let executable: String
    let processes: ChatProcesses
    let readSettings: @Sendable () -> ChatSettingsView
    let release: String
    /// The guarded test environment the child keeps (DOZ_TEST_*), when this daemon runs guarded.
    let testEnvironment: [String: String]

    /// Seconds a new server has to say it is ready.
    static let readySeconds: Double = 15
    /// Seconds between SIGTERM and SIGKILL.
    static let stopSeconds: Double = 5
    /// server.log is kept to one older copy at this size.
    static let logLimit = 2 << 20

    private let q = DispatchQueue(label: "doz.chat.supervisor")
    // Everything below is touched on `q` only.
    private var st = ChatServerState()
    private var child: Child?
    private var policy = ChatRestartPolicy()
    private var nextTry: Double?
    /// The files a stopped or failing state was reached with: tried again only when they change (or `doz chat on`).
    private var heldFor: Files?
    private var exiting = false
    private var settings: ChatSettingsView
    private var settingsAt: Double = 0
    private var lastWritten: Data?

    struct Files: Equatable { var config: [UInt8]; var tokens: Data }
    struct Child { var pid: pid_t; var started: Double; var files: Files; var ready: Bool }

    public init(paths: ChatPaths, executable: String, release: String, processes: ChatProcesses = ChatSystemProcesses(),
                environment: [String: String] = ProcessInfo.processInfo.environment,
                readSettings: @escaping @Sendable () -> ChatSettingsView = { ChatSettingsView.read() }) {
        self.paths = paths
        self.executable = executable
        self.release = release
        self.processes = processes
        self.readSettings = readSettings
        settings = ChatSettingsView(enabled: false)
        testEnvironment = TestSafety.guarded(environment) ? environment.filter { $0.key.hasPrefix("DOZ_TEST_") } : [:]
    }

    static func now() -> Double { Date().timeIntervalSince1970 }

    // MARK: the daemon's calls

    /// One look (the daemon's loop, every second). `blocked`: the daemon is stopping, or its program was replaced.
    public func tick(blocked: Bool) async { await run { self.look(blocked: blocked, force: false) } }

    /// Whether chat is on (the setting as last read) — it keeps the daemon running, like a session.
    public var enabledSetting: Bool { q.sync { settings.enabled } }

    /// The state now.
    public func status() async -> ChatServerState { await run { self.current() } }

    /// Before the daemon lets go of the store's lock: the server is stopped and none is started again.
    public func stopForExit() async {
        await run {
            self.exiting = true
            self.stopChild(counted: false)
            self.st.state = "waiting"
            self.st.problem = nil
            self.save()
        }
    }

    /// `doz chat on` / `off` (`chat-sync`): the human named (once — `name` only before there is one), the settings read
    /// now, and with `retry` a stopped or failing server tried again. Answers the state after this look; `waitReady`
    /// waits (up to 15 s) until it is ready, stopped or failing — or, with chat off, until no server runs.
    public func sync(human name: String?, retry: Bool, waitReady: Bool, blocked: Bool) async throws -> ChatServerState {
        try await runThrowing {
            if let name { try self.nameHuman(name) }
            if retry { self.policy.reset(); self.heldFor = nil; self.nextTry = nil }
            self.look(blocked: blocked, force: true)
        }
        let until = Self.now() + Self.readySeconds + 1
        while waitReady {
            let s = await status()
            let settled = s.enabled ? (s.ready || ["stopped", "failing", "waiting"].contains(s.state)) : s.pid == nil
            if settled || Self.now() > until { return s }
            try? await Task.sleep(for: .milliseconds(200))
            await tick(blocked: blocked)
        }
        return await status()
    }

    /// `doz chat add`: a new participant (an agent that polls with its own token). Answers its token — the one given
    /// (`--from-stdin`) or a new one — which is kept nowhere but as its hash.
    public func add(_ name: String, token given: String?) async throws -> String {
        try await runThrowing {
            if let why = ChatNames.refusal(name) { throw HostError(.invalid, why) }
            try self.paths.ensureFolder()
            var d = try ChatDirectory.load(self.paths)
            if d.has(name) { throw HostError(.exists, "\(name) is already in chat") }
            let token = try self.tokenToUse(given)
            var h = try ChatTokenHashes.load(self.paths)
            d.participants.append(.init(name: name, added: Self.timestamp()))
            h.sha256[name] = ChatSecrets.hash(token)
            try self.paths.write("tokens.json", h.bytes())
            try self.paths.write("directory.json", d.bytes())
            self.look(blocked: false, force: true)
            return token
        }
    }

    /// `doz chat remove`: it and its token go; it leaves every room (the server keeps no member it does not know).
    public func remove(_ name: String) async throws {
        try await runThrowing {
            var d = try ChatDirectory.load(self.paths)
            if d.human == name { throw HostError(.invalid, "\(name) is you: you stay in chat (doz chat off turns it off)") }
            guard d.participants.contains(where: { $0.name == name }) else { throw HostError(.notFound, "no participant \(name) in chat") }
            var h = try ChatTokenHashes.load(self.paths)
            d.participants.removeAll { $0.name == name }
            h.sha256[name] = nil
            try self.paths.write("tokens.json", h.bytes())
            try self.paths.write("directory.json", d.bytes())
            self.look(blocked: false, force: true)
        }
    }

    /// `doz chat token`: its token replaced (the old one is refused from the restart on).
    public func replaceToken(_ name: String, token given: String?) async throws -> String {
        try await runThrowing {
            let d = try ChatDirectory.load(self.paths)
            if d.human == name { throw HostError(.invalid, "\(name) is you: you need no token (your doz chat commands use your own socket)") }
            guard d.participants.contains(where: { $0.name == name }) else { throw HostError(.notFound, "no participant \(name) in chat") }
            let token = try self.tokenToUse(given)
            var h = try ChatTokenHashes.load(self.paths)
            h.sha256[name] = ChatSecrets.hash(token)
            try self.paths.write("tokens.json", h.bytes())
            self.look(blocked: false, force: true)
            return token
        }
    }

    // MARK: on the queue

    private func run<T: Sendable>(_ f: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { c in q.async { c.resume(returning: f()) } }
    }

    private func runThrowing<T: Sendable>(_ f: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { c in q.async { c.resume(with: Result { try f() }) } }
    }

    private func tokenToUse(_ given: String?) throws -> String {
        guard let t = given else { return ChatTokens.make() }
        if let why = ChatTokens.refusal(t) { throw HostError(.invalid, why) }
        return t
    }

    private func nameHuman(_ name: String) throws {
        if let why = ChatNames.refusal(name) { throw HostError(.invalid, why) }
        try paths.ensureFolder()
        var d = try ChatDirectory.load(paths)
        if let h = d.human {
            if h != name { throw HostError(.exists, "you are already \(h) in chat (a new name for you comes later)") }
            return
        }
        if d.participants.contains(where: { $0.name == name }) { throw HostError(.exists, "\(name) is a participant already") }
        d.human = name
        try paths.write("directory.json", d.bytes())
    }

    private func current() -> ChatServerState {
        var s = st
        s.enabled = settings.enabled
        s.pagePort = settings.pagePort
        s.linePort = settings.linePort
        return s
    }

    private func save() {
        // Chat never turned on: no folder is made for it.
        if !settings.enabled && !FileManager.default.fileExists(atPath: paths.folder) { return }
        var s = current()
        s.updatedAt = nil
        guard let d = try? ChatServerState.encoder.encode(s), d != lastWritten else { return }
        s.updatedAt = Date()
        guard let out = try? ChatServerState.encoder.encode(s), (try? paths.ensureFolder()) != nil else { return }
        if (try? paths.write("supervisor.json", out + Data("\n".utf8))) != nil { lastWritten = d }
    }

    /// One look. Never throws: what goes wrong is the state's problem.
    private func look(blocked: Bool, force: Bool) {
        defer { save() }
        let t = Self.now()
        if force || t - settingsAt >= 5 {
            settings = readSettings()
            settingsAt = t
        }
        if let c = child, let end = processes.reap(c.pid) { exited(c, end) }
        let wanted = settings.enabled && !blocked && !exiting
        guard wanted else {
            stopChild(counted: false)
            st.state = settings.enabled ? "waiting" : "off"
            st.ready = false
            st.problem = nil
            if !settings.enabled { policy.reset(); heldFor = nil; nextTry = nil }
            return
        }
        // The files, generated from the settings and the records.
        let files: Files
        do {
            if !paths.socketFits { throw HostError(.invalid, paths.socketTooLong) }
            if let why = ChatConfigFile.portClash(pagePort: settings.pagePort, linePort: settings.linePort,
                                                  dashboards: settings.dashboards.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }) {
                throw HostError(.invalid, why)
            }
            try paths.ensureFolder()
            var d = try ChatDirectory.load(paths)
            if d.human == nil {                             // chat.enabled set by hand: the human is named as `on` would
                d.human = ChatNames.defaultHuman()
                try paths.write("directory.json", d.bytes())
            }
            var h = try ChatTokenHashes.load(paths)
            h.sha256 = h.sha256.filter { k, _ in d.participants.contains { $0.name == k } }
            files = Files(config: try ChatConfigFile.bytes(d, paths: paths, pagePort: settings.pagePort, linePort: settings.linePort),
                          tokens: h.bytes())
            if FileManager.default.contents(atPath: paths.config).map(Array.init) != files.config { try paths.write("config.json", Data(files.config)) }
            if FileManager.default.contents(atPath: paths.tokens) != files.tokens { try paths.write("tokens.json", files.tokens) }
        } catch {
            stopChild(counted: false)
            st.state = "stopped"
            st.ready = false
            st.problem = (error as? HostError)?.message ?? "\(error)"
            return
        }
        if let c = child {
            if c.files != files {                           // a participant, a token or a port changed: restart now
                stopChild(counted: false)
            } else {
                if !c.ready {
                    let s = processes.server(dataDir: paths.data)
                    if s.pid == c.pid && s.ready {
                        child?.ready = true
                        st.state = "running"
                        st.ready = true
                        st.problem = nil
                    } else if t - c.started > Self.readySeconds {
                        stopChild(counted: false)
                        failed(c, ChatChildExit(), why: "it did not say it was ready within \(Int(Self.readySeconds)) s")
                    }
                }
                return
            }
        }
        // No server runs.
        if let held = heldFor {
            if held == files { return }                     // stopped or failing: only new files (or `doz chat on`) try again
            heldFor = nil
            policy.reset()
            nextTry = nil
        }
        if let n = nextTry, t < n { st.state = "restarting"; return }
        nextTry = nil
        start(files)
    }

    private func start(_ files: Files) {
        // A server already on the data folder: ours from before (the daemon was killed and it has not noticed yet) is
        // stopped; anyone else's is a fault — two servers never share a data folder.
        if let other = processes.server(dataDir: paths.data).pid, other != child?.pid {
            let args = processes.arguments(of: pid_t(other)) ?? []
            guard let i = args.firstIndex(of: "--config"), i + 1 < args.count, args[i + 1] == paths.config else {
                st.state = "stopped"
                st.problem = "another chat server holds \(DisplayPath.tilde(paths.data)) (pid \(other))"
                heldFor = files
                return
            }
            HostLog.line("chat: an earlier chat server of this store still runs (pid \(other)) — stopping it")
            stopProcess(pid_t(other), reapable: false)
        }
        rotateLog()
        let args = ["chat", "serve", "--config", paths.config, "--bind", ChatConfigFile.bind, "--token-hashes", paths.tokens,
                    "--owner-socket", paths.socket, "--supervised"]
        var env = ["PATH": "/usr/bin:/bin"]
        for k in ["HOME", "LANG", "TMPDIR"] { if let v = ProcessInfo.processInfo.environment[k] { env[k] = v } }
        for (k, v) in testEnvironment { env[k] = v }
        do {
            let pid = try processes.spawn(executable: executable, arguments: args, environment: env, log: paths.serverLog)
            child = Child(pid: pid, started: Self.now(), files: files, ready: false)
            st.pid = pid
            st.state = "starting"
            st.ready = false
            st.startedAt = Date()
            HostLog.line("chat: the chat server started (pid \(pid)) — 127.0.0.1, page port \(settings.pagePort), line port \(settings.linePort)")
        } catch {
            st.state = "stopped"
            st.problem = "the chat server could not be started: \(error)"
            heldFor = files
        }
    }

    /// The child exited by itself (or was killed by someone else).
    private func exited(_ c: Child, _ end: ChatChildExit) {
        child = nil
        st.pid = nil
        st.ready = false
        st.lastExit = end.text
        HostLog.line("chat: the chat server (pid \(c.pid)) ended: \(end.text)")
        failed(c, end, why: nil)
    }

    private func failed(_ c: Child, _ end: ChatChildExit, why: String?) {
        let line = why ?? lastLogLine()
        switch policy.exited(code: end.code, upSeconds: Self.now() - c.started, now: Self.now()) {
        case .stopped:
            st.state = "stopped"
            st.problem = portHint(line) ?? line
            heldFor = c.files
        case .failing:
            st.state = "failing"
            st.problem = "it failed \(ChatRestartPolicy.failingAfter) times in 10 minutes (doz chat on tries again)" + (line.isEmpty ? "" : ": " + line)
            heldFor = c.files
        case .retry(let after):
            st.state = "restarting"
            st.restarts += 1
            st.problem = line.isEmpty ? nil : line
            nextTry = Self.now() + after
        }
    }

    /// "a port is in use" said with the setting to change.
    private func portHint(_ line: String) -> String? {
        guard line.contains("a port is in use") else { return nil }
        if processes.portInUse(settings.linePort) {
            return "line port \(settings.linePort) is in use by another program — doz config set chat.line_port N"
        }
        if processes.portInUse(settings.pagePort) {
            return "page port \(settings.pagePort) is in use by another program — doz config set chat.page_port N"
        }
        return line
    }

    /// Stops our child: SIGTERM, then SIGKILL after 5 s; reaped. `counted`: never (only exits it chose count).
    private func stopChild(counted: Bool) {
        guard let c = child else { return }
        child = nil
        st.pid = nil
        st.ready = false
        let end = stopProcess(c.pid, reapable: true)
        if let end { st.lastExit = end.text }
        HostLog.line("chat: the chat server (pid \(c.pid)) stopped")
    }

    @discardableResult
    private func stopProcess(_ pid: pid_t, reapable: Bool) -> ChatChildExit? {
        processes.signal(pid, SIGTERM)
        let until = Self.now() + Self.stopSeconds
        while Self.now() < until {
            if reapable, let e = processes.reap(pid) { return e }
            if !reapable, kill(pid, 0) != 0 { return nil }
            usleep(50_000)
        }
        processes.signal(pid, SIGKILL)
        let kill2 = Self.now() + 2
        while Self.now() < kill2 {
            if reapable, let e = processes.reap(pid) { return e }
            if !reapable, kill(pid, 0) != 0 { return nil }
            usleep(20_000)
        }
        return nil
    }

    /// The server's last line on standard error, without its time and its `chat: ` (never a secret: it logs none).
    private func lastLogLine() -> String {
        guard let fh = FileHandle(forReadingAtPath: paths.serverLog) else { return "" }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        try? fh.seek(toOffset: size > 4096 ? size - 4096 : 0)
        let text = String(decoding: (try? fh.readToEnd()) ?? Data(), as: UTF8.self)
        guard var l = text.split(separator: "\n").last.map(String.init) else { return "" }
        if let r = l.range(of: #"^\d{4}/\d\d/\d\d \d\d:\d\d:\d\d "#, options: .regularExpression) { l.removeSubrange(r) }
        if l.hasPrefix("chat: ") { l.removeFirst(6) }
        return String(l.prefix(300))
    }

    private func rotateLog() {
        var s = stat()
        if stat(paths.serverLog, &s) == 0, s.st_size > Self.logLimit { rename(paths.serverLog, paths.serverLog + ".1") }
    }

    static func timestamp() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: Date())
    }
}

/// The real system: posix_spawn, waitpid, kill, the server's own status, KERN_PROCARGS2.
public struct ChatSystemProcesses: ChatProcesses {
    public init() {}

    public func spawn(executable: String, arguments: [String], environment: [String: String], log: String) throws -> pid_t {
        let logFD = open(log, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard logFD >= 0 else { throw HostError(.failed, "cannot open \(log): \(String(cString: strerror(errno)))") }
        defer { close(logFD) }
        var fa: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fa)
        defer { posix_spawn_file_actions_destroy(&fa) }
        posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&fa, logFD, 1)
        posix_spawn_file_actions_adddup2(&fa, logFD, 2)
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // Only 0, 1 and 2 reach the child; its own process group (a signal to the daemon's group never reaches it).
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attr, 0)
        var none = sigset_t(), all = sigset_t()
        sigemptyset(&none); sigfillset(&all)
        posix_spawnattr_setsigmask(&attr, &none)
        posix_spawnattr_setsigdefault(&attr, &all)
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        defer { for p in argv { free(p) } }
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { for p in envp { free(p) } }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, executable, &fa, &attr, argv, envp)
        guard rc == 0 else { throw HostError(.failed, "posix_spawn \(executable): \(String(cString: strerror(rc)))") }
        return pid
    }

    public func reap(_ pid: pid_t) -> ChatChildExit? {
        var status: Int32 = 0
        let r = waitpid(pid, &status, WNOHANG)
        if r == 0 { return nil }
        if r < 0 { return errno == ECHILD ? ChatChildExit() : nil }
        let sig = status & 0x7f
        if sig == 0 { return ChatChildExit(code: (status >> 8) & 0xff) }
        return ChatChildExit(signal: sig)
    }

    public func signal(_ pid: pid_t, _ sig: Int32) { kill(pid, sig) }

    public func server(dataDir: String) -> (pid: Int32?, ready: Bool) {
        let s = ChatServer.status(dataDir: dataDir, release: "")
        return (s.running ? Int32(s.pid) : nil, s.ready)
    }

    public func arguments(of pid: pid_t) -> [String]? { ProcessArguments.of(pid) }

    public func portInUse(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var a = sockaddr_in()
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = in_port_t(UInt16(port).bigEndian)
        a.sin_addr.s_addr = inet_addr("127.0.0.1")
        let r = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        return r != 0 && errno == EADDRINUSE
    }
}

/// A process's arguments (KERN_PROCARGS2) — only to tell our own chat server from another program on the data folder.
public enum ProcessArguments {
    public static func of(_ pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 4 else { return nil }
        let argc = Int(buf.withUnsafeBytes { $0.load(as: Int32.self) })
        var i = 4
        while i < size, buf[i] != 0 { i += 1 }            // the executable's path
        while i < size, buf[i] == 0 { i += 1 }            // its padding
        var out: [String] = []
        while out.count < argc, i < size {
            let start = i
            while i < size, buf[i] != 0 { i += 1 }
            out.append(String(decoding: buf[start..<i], as: UTF8.self))
            i += 1
        }
        return out
    }
}
