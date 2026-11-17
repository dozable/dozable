import Darwin
import Foundation

// One chat server's life, under the kept-service contract a supervisor relies on: it takes a lock on its data folder
// (`server.lock`), keeps `status.json` there, logs to standard error only, writes nothing outside the data folder, and
// exits 0 after SIGTERM, SIGHUP or SIGINT. A fault a restart cannot fix — a bad setting or config, a port in use, a data
// folder it cannot write, a second server on the same folder, a secrets file it may not read — is one line on standard
// error and exit 78, so a supervisor does not restart it. It reads no settings file, opens no store, starts no daemon
// and touches no Keychain: everything it needs is in its config, its flags and its secrets file.

public struct ChatServeOptions: Sendable {
    public var configPath: String
    public var overrides = ChatConfig.Overrides()
    public var secretsFile: String?
    public var supervised = false
    /// The release this server reports (Dozable's version).
    public var release: String

    public init(configPath: String, release: String) {
        self.configPath = configPath
        self.release = release
    }
}

public enum ChatExit {
    /// Stopped as asked: SIGTERM, SIGHUP or SIGINT.
    public static let stopped: Int32 = 0
    /// Any other failure: a restart may fix it.
    public static let restartMe: Int32 = 1
    /// A fault a restart cannot fix (EX_CONFIG).
    public static let badSetting: Int32 = 78
}

public enum ChatServer {
    public static let lockFileName = "server.lock"
    public static let statusFileName = "status.json"
    public static let contractVersion = 1

    /// Runs the server; returns only through `exit`.
    public static func run(_ o: ChatServeOptions) async -> Never {
        let log = ChatLog { line in FileHandle.standardError.write(Data((timestamp() + " " + line + "\n").utf8)) }
        func fault(_ code: Int32, _ why: String) -> Never {
            // Once a stop has begun, a failure that comes from the stop itself (a listener it closed) is not an exit:
            // the stop exits 0 when it is done.
            if Stop.isStopping { Stop.park() }
            FileHandle.standardError.write(Data(("chat: " + why + "\n").utf8))
            StatusWriter.current?.remove()
            exit(code)
        }
        // The stop signals are taken first, so a stop during the start is still a clean stop.
        let signals = SignalWatch.install { sig in
            log("chat: \(sig): stopping")
            Stop.begin()
            Stop.run()
            log("chat: stopped")
            exit(ChatExit.stopped)
        }
        _ = signals

        let config: ChatConfig
        do { config = try ChatConfig.resolve(path: o.configPath, o.overrides) } catch { fault(ChatExit.badSetting, "\(error)") }
        let host = config.bind
        guard !host.isEmpty else { fault(ChatExit.badSetting, "no address to listen on: pass --bind ADDR or set bind in the config") }
        guard let addr = ChatAddress(host), addr.isLoopback else {
            fault(ChatExit.badSetting, "--bind \(host): this server listens on a loopback address only")
        }

        // The data folder: made if missing, locked, and the first status written (not ready).
        let dir = config.dataDir
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch { fault(ChatExit.badSetting, "data folder \(dir) cannot be made: \(error.localizedDescription)") }
        switch ServerLock.take(dir) {
        case .taken: break
        case .held(let pid):
            fault(ChatExit.badSetting, "another chat server already runs on the data folder \(dir)" + (pid > 0 ? " (pid \(pid))" : ""))
        case .failed(let why): fault(ChatExit.badSetting, "data folder \(dir) cannot be written: \(why)")
        }
        let started = chatNow()
        let pid = getpid()
        var first = ChatStatus(release: o.release, dataDir: dir)
        first.running = true
        first.pid = Int(pid)
        first.secretsFrom = "file"
        first.procStart = ProcessInfoLite.startTime(pid: pid)
        first.startedAt = started
        do { try StatusWriter.start(dir: dir, first) } catch { fault(ChatExit.badSetting, "data folder \(dir) cannot be written: \(error)") }

        // Secrets: the file handed in, else the data folder's secrets.json when there is one.
        let secretsPath = o.secretsFile ?? (dir as NSString).appendingPathComponent("secrets.json")
        var loaded = ChatSecrets()
        if o.secretsFile != nil || FileManager.default.fileExists(atPath: secretsPath) {
            do { loaded = try ChatSecrets.load(path: secretsPath) } catch { fault(ChatExit.badSetting, "\(error)") }
        }
        let secrets = loaded

        let core = ChatServerCore(config: config, secrets: secrets, release: releaseNumber(o.release), log: log)
        core.load()
        if !config.testOwnedAddresses.isEmpty {
            log("chat: FOR TESTS: test_owned_addresses is set, so only \(config.testOwnedAddresses.joined(separator: ", ")) count as the owner's own machines")
        }
        // What waited when the server last stopped is handed over again, and a new protocol version is announced,
        // before the ports answer: a caller that finds the server ready finds the announcement's webhook calls made
        // (the reference reaches the same order by serving its page only after both).
        let again = core.redeliver()
        if again > 0 { log("chat: handing over \(again) message(s) that were not delivered before the last stop") }
        if core.announceProtocol() {
            log("chat: the message protocol is now version \(ChatProtocol.version); told every room")
            core.waitForAnnouncement(seconds: 2)
        }

        let listeners: ChatListeners
        do {
            listeners = try await ChatListeners.bind(core: core, host: host, linePort: config.linePort, pagePort: config.httpPort, log: log)
        } catch {
            let text = "\(error)"
            let inUse = text.contains("Address already in use") || text.contains("EADDRINUSE") || text.contains("errno: 48")
            let denied = text.contains("Permission denied") || text.contains("errno: 13")
            fault(inUse || denied ? ChatExit.badSetting : ChatExit.restartMe,
                  "cannot listen on \(host) (line port \(config.linePort), page port \(config.httpPort)): " + (inUse ? "a port is in use" : text))
        }
        let presence = core.watchPresence()   // presence to open pages whenever it changes
        Stop.add { presence.cancel(); listeners.close(); core.close(); StatusWriter.current?.remove() }
        log("chat: lines on \(host):\(listeners.linePort), page on http://\(host):\(listeners.pagePort), tokens required from every caller: \(config.requireTokens), data in \(dir)")

        let snapshot: @Sendable () -> Void = {
            let (rooms, people) = core.counts()
            StatusWriter.current?.update { st in
                st.ready = true
                st.ports = .init(line: listeners.linePort, page: listeners.pagePort, https: 0)
                st.pageURLs = ["http://" + joinHostPort(host, listeners.pagePort)]
                st.rooms = rooms
                st.participants = people
                st.problems = problems(config: config, secrets: secrets, core: core)
            }
        }
        snapshot()
        StatusWriter.current?.refreshEvery(5, snapshot)
        await listeners.serve()
        fault(ChatExit.restartMe, "the listeners stopped")
    }

    /// What the running server finds wrong with itself (never a secret value).
    static func problems(config: ChatConfig, secrets: ChatSecrets, core: ChatServerCore) -> [ChatStatus.Problem] {
        var out: [ChatStatus.Problem] = []
        for p in core.people() {
            if config.requireTokens && !secrets.hasToken(p.name) && p.deliver != "poll" {
                out.append(.init(code: "token-missing", what: "no token for " + p.name, blocking: false))
            }
            if p.deliver == "webhook" && (secrets.webhooks[p.webhook.isEmpty ? "default" : p.webhook]?.url ?? "").isEmpty {
                out.append(.init(code: "secret-missing", what: "no webhook address for " + p.name, blocking: false))
            }
        }
        return out
    }

    /// The release as `major.minor.patch` (a pre-release suffix is left out).
    static func releaseNumber(_ r: String) -> String {
        String(r.prefix { $0 != "-" && $0 != "+" })
    }

    static func joinHostPort(_ h: String, _ p: Int) -> String { h.contains(":") ? "[\(h)]:\(p)" : "\(h):\(p)" }

    static func timestamp() -> String {
        var t = time(nil)
        var tmv = tm()
        localtime_r(&t, &tmv)
        var buf = [Int8](repeating: 0, count: 32)
        let n = strftime(&buf, buf.count, "%Y/%m/%d %H:%M:%S", &tmv)
        return String(decoding: buf.prefix(n).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    // MARK: - `doz chat status`

    /// The status of the server on a data folder. A server runs when something holds the folder's lock; status.json
    /// tells the rest and is believed only when its pid holds the lock and that process started when the file says.
    public static func status(dataDir dir: String, release: String) -> ChatStatus {
        var st = ChatStatus(release: release, dataDir: dir)
        let holder = ServerLock.holder(dir)
        let data = FileManager.default.contents(atPath: (dir as NSString).appendingPathComponent(statusFileName))
        let file = data.flatMap { try? ChatJSON.parse($0) }.flatMap(ChatStatus.read)
        guard let pid = holder else {
            if file != nil {
                st.problems.append(.init(code: "last-stop-unclean", what: "the last server on this data folder ended without a clean stop (it was killed or it crashed)", blocking: true))
            }
            return st
        }
        st.running = true
        st.pid = pid
        guard let f = file, f.pid == pid, f.procStart.isEmpty || ProcessInfoLite.startTime(pid: pid_t(pid)) == f.procStart else {
            if file != nil {
                st.problems.append(.init(code: "status-file-stale", what: "status.json is not from the server that holds this data folder", blocking: false))
            }
            return st
        }
        st.ready = f.ready; st.ports = f.ports; st.pageURLs = f.pageURLs; st.rooms = f.rooms; st.participants = f.participants
        st.problems = f.problems; st.secretsFrom = f.secretsFrom; st.version = f.version; st.protocolVersion = f.protocolVersion
        if f.startedAt > 0 { st.uptimeSeconds = max(0, Int(chatNow() - f.startedAt)) }
        return st
    }
}

/// The status object of the kept-service contract.
public struct ChatStatus: Sendable, Equatable {
    public struct Ports: Sendable, Equatable { public var line, page, https: Int }
    public struct Problem: Sendable, Equatable { public var code, what: String; public var blocking: Bool }

    public var contract = ChatServer.contractVersion
    public var version: String
    public var protocolVersion = ChatProtocol.version
    public var running = false
    public var ready = false
    public var pid = 0
    public var uptimeSeconds: Int?
    public var ports: Ports?
    public var pageURLs: [String] = []
    public var rooms: Int?
    public var participants: Int?
    public var problems: [Problem] = []
    public var dataDir: String
    public var secretsFrom = ""
    public var procStart = ""
    public var startedAt: Double = 0

    public init(release: String, dataDir: String) { version = release; self.dataDir = dataDir }

    public var json: JValue {
        var o = JObject()
        o.add("contract", .int(Int64(contract))); o.add("version", .string(version)); o.add("protocol", .string(protocolVersion))
        o.add("running", .bool(running)); o.add("ready", .bool(ready))
        if pid != 0 { o.add("pid", .int(Int64(pid))) }
        if let u = uptimeSeconds { o.add("uptime_seconds", .int(Int64(u))) }
        if let p = ports { o.add("ports", .object([JMember("line", .int(Int64(p.line))), JMember("page", .int(Int64(p.page))), JMember("https", .int(Int64(p.https)))])) }
        o.add("page_urls", .strings(pageURLs))
        if let r = rooms { o.add("rooms", .int(Int64(r))) }
        if let p = participants { o.add("participants", .int(Int64(p))) }
        o.add("problems", .array(problems.map { .object([JMember("code", .string($0.code)), JMember("what", .string($0.what)), JMember("blocking", .bool($0.blocking))]) }))
        o.add("data_dir", .string(dataDir))
        o.omitEmpty("secrets_from", secretsFrom); o.omitEmpty("proc_start", procStart); o.omitEmpty("started_at", startedAt)
        return o.value
    }

    /// The object as `status --json` prints it: two-space indent and a newline.
    public var text: String { String(decoding: ChatJSON.encodeIndented(json, indent: "  "), as: UTF8.self) + "\n" }

    static func read(_ v: JValue) -> ChatStatus? {
        guard v.isObject else { return nil }
        func s(_ k: String) -> String { v.field(k)?.stringValue ?? "" }
        func i(_ k: String) -> Int? { (try? v.field(k)?.goInt(k)) ?? nil }
        var st = ChatStatus(release: s("version"), dataDir: s("data_dir"))
        st.protocolVersion = s("protocol")
        st.running = v.field("running") == .bool(true)
        st.ready = v.field("ready") == .bool(true)
        st.pid = i("pid") ?? 0
        if let p = v.field("ports"), p.isObject {
            st.ports = Ports(line: ((try? p.field("line")?.goInt("line")) ?? nil) ?? 0, page: ((try? p.field("page")?.goInt("page")) ?? nil) ?? 0,
                             https: ((try? p.field("https")?.goInt("https")) ?? nil) ?? 0)
        }
        st.pageURLs = ((try? v.field("page_urls")?.goStrings("page_urls")) ?? nil) ?? []
        st.rooms = i("rooms"); st.participants = i("participants")
        if case .array(let a)? = v.field("problems") {
            st.problems = a.compactMap { p in
                guard let c = p.field("code")?.stringValue, let w = p.field("what")?.stringValue else { return nil }
                return Problem(code: c, what: w, blocking: p.field("blocking") == .bool(true))
            }
        }
        st.secretsFrom = s("secrets_from"); st.procStart = s("proc_start")
        st.startedAt = v.field("started_at")?.doubleValue ?? 0
        return st
    }
}

// MARK: - The lock on the data folder

enum ServerLock {
    enum Outcome { case taken, held(Int), failed(String) }

    /// Kept open for the life of the process: a POSIX record lock is dropped when any descriptor of the file closes.
    nonisolated(unsafe) static var fd: Int32 = -1

    static func take(_ dir: String) -> Outcome {
        let path = (dir as NSString).appendingPathComponent(ChatServer.lockFileName)
        let f = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard f >= 0 else { return .failed(String(cString: strerror(errno))) }
        var lk = flock()
        lk.l_type = Int16(F_WRLCK)
        lk.l_whence = Int16(SEEK_SET)
        if fcntl(f, F_SETLK, &lk) != 0 {
            let e = errno
            var q = flock()
            q.l_type = Int16(F_WRLCK)
            q.l_whence = Int16(SEEK_SET)
            let pid = fcntl(f, F_GETLK, &q) == 0 && q.l_type != Int16(F_UNLCK) ? Int(q.l_pid) : 0
            close(f)
            if e == EAGAIN || e == EACCES { return .held(pid) }
            return .failed(String(cString: strerror(e)))
        }
        fd = f
        return .taken
    }

    /// The pid that holds the folder's lock, or nil when nobody does.
    static func holder(_ dir: String) -> Int? {
        let path = (dir as NSString).appendingPathComponent(ChatServer.lockFileName)
        let f = open(path, O_RDONLY | O_CLOEXEC)
        guard f >= 0 else { return nil }
        defer { close(f) }
        var q = flock()
        q.l_type = Int16(F_RDLCK)
        q.l_whence = Int16(SEEK_SET)
        guard fcntl(f, F_GETLK, &q) == 0, q.l_type != Int16(F_UNLCK) else { return nil }
        return Int(q.l_pid)
    }
}

// MARK: - status.json

final class StatusWriter: @unchecked Sendable {
    nonisolated(unsafe) static var current: StatusWriter?

    private let path: String
    private let lock = NSLock()
    private var cur: ChatStatus
    private var last: [UInt8] = []
    private var gone = false
    private var timer: DispatchSourceTimer?

    private init(path: String, _ s: ChatStatus) { self.path = path; cur = s }

    static func start(dir: String, _ s: ChatStatus) throws {
        let w = StatusWriter(path: (dir as NSString).appendingPathComponent(ChatServer.statusFileName), s)
        try w.write()
        current = w
    }

    func update(_ f: (inout ChatStatus) -> Void) {
        lock.withLock {
            f(&cur)
            try? write()
        }
    }

    func refreshEvery(_ seconds: Int, _ f: @escaping @Sendable () -> Void) {
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now() + .seconds(seconds), repeating: .seconds(seconds))
        t.setEventHandler(handler: f)
        t.resume()
        timer = t
    }

    private func write() throws {
        guard !gone else { return }
        let b = Array(cur.text.utf8)
        if b == last { return }
        try ChatFiles.writeAtomically(path, b)
        last = b
    }

    func remove() {
        lock.withLock {
            gone = true
            timer?.cancel()
            unlink(path)
        }
    }
}

// MARK: - Stop and signals

/// What a stop does, in the reverse of the order it was added.
enum Stop {
    nonisolated(unsafe) private static var steps: [() -> Void] = []
    private static let lock = NSLock()

    nonisolated(unsafe) private static var stopping = false

    static func add(_ f: @escaping () -> Void) { lock.withLock { steps.append(f) } }

    static func begin() { lock.withLock { stopping = true } }
    static var isStopping: Bool { lock.withLock { stopping } }

    /// Waits for the stop in progress to exit the process.
    static func park() -> Never {
        while true { sleep(60) }
    }

    static func run() {
        let s = lock.withLock { steps }
        for f in s.reversed() { f() }
    }
}

enum SignalWatch {
    nonisolated(unsafe) private static var sources: [DispatchSourceSignal] = []

    /// SIGTERM, SIGHUP and SIGINT all stop the server; the first one wins.
    static func install(_ onStop: @escaping @Sendable (String) -> Void) -> Int {
        let q = DispatchQueue(label: "chat.signals")
        let once = NSLock()
        nonisolated(unsafe) var fired = false
        for (sig, name) in [(SIGTERM, "terminated"), (SIGHUP, "hangup"), (SIGINT, "interrupt")] {
            signal(sig, SIG_IGN)
            let s = DispatchSource.makeSignalSource(signal: sig, queue: q)
            s.setEventHandler {
                let first = once.withLock { () -> Bool in defer { fired = true }; return !fired }
                if first { onStop(name) }
            }
            s.resume()
            sources.append(s)
        }
        return sources.count
    }
}

/// A process's start time, to tell a reused pid from the server that wrote a status file.
enum ProcessInfoLite {
    static func startTime(pid: pid_t) -> String {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return "" }
        let t = info.kp_proc.p_un.__p_starttime
        return "\(t.tv_sec).\(String(format: "%06d", t.tv_usec))"
    }
}
