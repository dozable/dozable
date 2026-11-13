import CryptoKit
import Darwin
import DozableKit
import Foundation

/// What the host opened a session on this Mac with — never an environment VALUE, only the names.
public struct MacSessionRecord: Codable, Equatable, Sendable {
    public var argv: [String]
    public var workdir: String
    public var environmentKeys: [String]?
    public var openedAt: Date
    /// The holder that runs it: its version (this doz's) and its file's sha256.
    public var holderVersion: String?
    public var holderSHA256: String?
    /// The program's pid when it was last seen.
    public var pid: Int?
    /// Its own argv bypasses its permissions (never added by Dozable).
    public var bypassed: Bool?
    /// It runs FENCED, with these grants (nil: unfenced — every record before fenced sessions keeps its mode).
    public var fence: MacFenceRecord?
}

/// `<store>/mac-sessions/sessions.json` (0600 in a 0700 folder) — fields only ever added. It outlives the holders (a
/// restart after a reboot reads it).
public struct MacSessionRecords: Codable, Equatable, Sendable {
    public var version = 1
    public var sessions: [String: MacSessionRecord] = [:]
    public init() {}
    /// The most records kept (the oldest dropped first).
    public static let maximum = 64
}

/// The sessions held on THIS Mac (`@mac`) — an actor owned by `HostCore`; never a `Managed`, never a `Sandbox`.
///
/// Each session is a `deckhold-mac serve` holder, a process of its own (its parent is launchd once `serve` returns), in
/// the store's socket folder (`MacPlace.socketDirectory`). Holders outlive the host by design: a host that starts
/// ADOPTS what it finds (`adopt`): a live socket is a session, a socket nothing answers is removed, a record with no
/// socket is ended (its `.exit`) or gone (the Mac restarted, or its holder was killed). Looking reads the folder
/// directly — in-process too: it never starts a host.
public actor MacSessions {
    public nonisolated let store: DozableStore
    nonisolated let readOnly: Bool
    /// The socket folder.
    public nonisolated let directory: String
    /// The login shell's PATH, read once (`MacSessionsEnvironment.loginPath`).
    private var loginPath: (path: String, source: String)?
    /// The host's own environment (tests set one).
    nonisolated let hostEnvironment: [String: String]

    /// `directory`: TESTS only (a short scratch folder) — otherwise the store's own (`MacPlace.socketDirectory`).
    public init(store: DozableStore, readOnly: Bool, environment: [String: String] = ProcessInfo.processInfo.environment,
                directory: String? = nil) {
        self.store = store
        self.readOnly = readOnly
        self.hostEnvironment = environment
        self.directory = directory ?? MacPlace.socketDirectory(store: store)
    }

    /// `<store>/mac-sessions`.
    public nonisolated var folder: URL { store.root.appendingPathComponent("mac-sessions") }
    nonisolated var recordsURL: URL { folder.appendingPathComponent("sessions.json") }
    public nonisolated func socket(_ s: String) -> String { MacPlace.socketPath(directory, s) }

    // MARK: records

    public nonisolated func records() -> MacSessionRecords {
        guard let d = try? Data(contentsOf: recordsURL), let r = try? HostWire.decoder.decode(MacSessionRecords.self, from: d) else { return MacSessionRecords() }
        return r
    }

    /// `<store>/mac-sessions`, 0700.
    func ensureStoreFolder() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    func writeRecords(_ r: MacSessionRecords) {
        guard !readOnly else { return }
        ensureStoreFolder()
        guard let data = try? HostWire.encoder.encode(r) else { return }
        try? SavedScreens.writePrivate(data, to: recordsURL)
    }

    func record(_ s: String, _ rec: MacSessionRecord?) {
        var r = records()
        r.sessions[s] = rec
        while r.sessions.count > MacSessionRecords.maximum,
              let oldest = r.sessions.min(by: { $0.value.openedAt < $1.value.openedAt })?.key { r.sessions[oldest] = nil }
        writeRecords(r)
    }

    // MARK: looking

    /// What the socket folder holds now (nothing when it is not there, or not ours to read).
    public func listing() async -> DeckholdSocket.Listing {
        guard MacPlace.folderProblem(directory) == nil else { return DeckholdSocket.Listing(sessions: [], stale: []) }
        return await DeckholdSocket.list(directory: directory)
    }

    /// Every session: live and ended ones from the folder, and the recorded ones whose holder is gone.
    public func rows() async -> [SessionRow] {
        let l = await listing()
        let recs = records().sessions
        var out: [SessionRow] = []
        var seen = Set<String>()
        for s in l.sessions {
            seen.insert(s.name)
            var row = SessionRow(s)
            if !s.isEnded { row.status = s.status.map { SessionStatus(session: s.name, $0) } }
            if let rec = recs[s.name] { Self.fill(&row, rec) }
            out.append(row)
        }
        for (name, rec) in recs where !seen.contains(name) {
            var row = SessionRow(SessionInfo(name: name, command: rec.argv.joined(separator: " ")))
            row.ended = true
            row.gone = true
            Self.fill(&row, rec)
            row.pid = nil
            out.append(row)
        }
        // 683: what each can do — every session on this Mac, fenced or not, from one source.
        let home = fenceHome()
        for i in out.indices {
            if let rec = recs[out[i].name] {
                out[i].capabilities = MacFence.capabilities(MacCapabilityShape(session: out[i].name, record: rec, home: home))
            }
        }
        return out.sorted { $0.name < $1.name }
    }

    static func fill(_ row: inout SessionRow, _ rec: MacSessionRecord) {
        row.workdir = rec.workdir
        row.argv = rec.argv
        row.openedAt = rec.openedAt
        row.bypassed = rec.bypassed == true ? true : nil
        if !rec.argv.isEmpty { row.command = rec.argv.joined(separator: " ") }
        if let f = rec.fence {
            row.fenced = true
            row.fence = MacFenceRow(f)
        }
    }

    /// Change one session's record (nothing when it has none).
    func updateRecord(_ s: String, _ change: (inout MacSessionRecord) -> Void) {
        var r = records()
        guard var rec = r.sessions[s] else { return }
        change(&rec)
        r.sessions[s] = rec
        writeRecords(r)
    }

    /// Whether session `s`'s holder answers now.
    public func isRunning(_ s: String) async -> Bool {
        if case .info = await DeckholdSocket.query(path: socket(s)) { return true }
        return false
    }

    // MARK: the fence

    /// The places a fenced session's rules are made of, resolved. The home is the person's (`TestSafety.realHome`);
    /// TEST SEAM (guarded runs only): `DOZ_TEST_FENCE_HOME`, a scratch home — and a guarded run without it is refused,
    /// so a test never makes a session folder in the real home.
    /// The fence's home alone (resolved; nil in a guarded run without its seam) — for what a listing says. Makes nothing.
    public nonisolated func fenceHome() -> String? {
        if TestSafety.guarded(hostEnvironment) {
            return hostEnvironment["DOZ_TEST_FENCE_HOME"].flatMap { $0.hasPrefix("/") ? MacFencePaths.resolve($0) : nil }
        }
        return MacFencePaths.resolve(TestSafety.realHome.path)
    }

    public nonisolated func fencePlaces() throws -> MacFencePlaces {
        let env = hostEnvironment
        var home = TestSafety.realHome.path
        if TestSafety.guarded(env) {
            guard let h = env["DOZ_TEST_FENCE_HOME"], h.hasPrefix("/") else {
                throw HostError(.unavailable, "a test opening a fenced session must give it a scratch home (DOZ_TEST_FENCE_HOME)")
            }
            home = h
        }
        guard let rh = MacFencePaths.resolve(home) else { throw HostError(.failed, "the home \(home) is not there") }
        let storeRoot = MacFencePaths.resolve(store.root.path) ?? store.root.standardizedFileURL.path
        try? MacPlace.ensureFolder(directory)
        let sockets = MacFencePaths.resolve(directory) ?? directory
        var temp = MacFencePaths.resolve(MacPlace.userTempDirectory()) ?? MacPlace.userTempDirectory()
        if !temp.hasSuffix("/") { temp += "/" }
        let xdg = env["XDG_CONFIG_HOME"].flatMap { $0.hasPrefix("/") ? $0 : nil } ?? (home + "/.config")
        let xdgReal = MacFencePaths.resolve(xdg) ?? xdg
        return MacFencePlaces(home: rh, store: storeRoot, socketDirectory: sockets, userTemp: temp, dozConfig: xdgReal + "/doz")
    }

    /// The person's git keys, read again only when their global config or ignore file changed (or after a minute) — a git
    /// run is most of a fenced start's cost.
    private var personGitCache: (key: String, at: Date, value: MacFenceSessionFolder.PersonGit)?
    func personGit(home: String) -> MacFenceSessionFolder.PersonGit {
        func stamp(_ p: String) -> String {
            var st = stat()
            return stat(p, &st) == 0 ? "\(st.st_ino):\(st.st_size):\(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec)" : "-"
        }
        let key = [home, stamp(home + "/.gitconfig"), stamp(home + "/.config/git/config"), stamp(home + "/.config/git/ignore")].joined(separator: "|")
        if let c = personGitCache, c.key == key, Date().timeIntervalSince(c.at) < 60 { return c.value }
        let v = MacFenceSessionFolder.personGit(home: home)
        personGitCache = (key, Date(), v)
        return v
    }

    /// `<store>/mac-sessions/fence/<session>` (0700): the session's profile, its git baseline and git's private copies —
    /// in the store, which no fence can read.
    public nonisolated func fenceState(_ s: String) -> String {
        (MacFencePaths.resolve(folder.path) ?? folder.path) + "/fence/" + s
    }

    /// `<store>/mac-sessions/quarantine/<session>`: what the git guard took out.
    public nonisolated func quarantine(_ s: String) -> String {
        (MacFencePaths.resolve(folder.path) ?? folder.path) + "/quarantine/" + s
    }

    /// Build a fenced session's fence and re-seed its folder (`previous`: its record at its last open, for the grants).
    /// 683: `argv` (its program decides its agent: `AgentRecipes.macAgent`), the bridges, the Claude login's placeholders
    /// (variable → placeholder) and the account behind them.
    public func prepareFence(session: String, workdir: String, request: MacFenceRequest, fenceRead: [String],
                             previous: MacFenceRecord?, trust: Bool = true, argv: [String]? = nil, bridges: MacFenceBridges = MacFenceBridges(),
                             placeholders: [String: String] = [:], account: String? = nil,
                             settings: DozableSettings = .load()) throws -> (fence: MacFence, seeded: MacFenceSessionFolder.Seeded, notes: [String]) {
        guard !readOnly else { throw HostError(.unavailable, "opening a session on this Mac needs the host") }
        let places = try fencePlaces()
        if loginPath == nil { loginPath = MacSessionsEnvironment.loginPath(host: hostEnvironment) }
        let person = personGit(home: places.home)
        ensureStoreFolder()
        try MacFenceHostFS.ensureDirectory(fenceState(session))
        var fence = try MacFence.make(session: session, workdir: workdir, request: request, places: places, path: loginPath!.path,
                                      fenceRead: fenceRead, hooksPathGlobal: person.hooksPath, scratch: fenceState(session))
        fence.trust = trust
        fence.bridges = bridges
        fence.placeholders = placeholders
        fence.account = account
        // The agent's config folder (decided before the folder is seeded: `shared` widens the grants).
        if let a = try MacAgentConfig.plan(argv: argv ?? [], workdir: fence.workdir, sessionFolder: fence.sessionFolder, home: places.home,
                                           mode: request.agentConfig, history: request.history, settings: settings) {
            if !a.isPrivate {
                if let k = MacFencePaths.lstatKind(a.personHome), k != S_IFDIR {
                    throw HostError(.invalid, "--agent-config shared: \(DisplayPath.tilde(a.personHome)) is a link or not a folder — refused (private works)")
                }
                if let p = MacFencePaths.pathProblem(a.personHome) { throw HostError(.invalid, "--agent-config shared: \(p)") }
            }
            fence.agent = a
        } else if request.agentConfig != nil || request.history != nil {
            throw HostError(.invalid, "--agent-config and --history are for an agent that declares its settings folder (Claude Code: doz run @mac --fenced -- claude)")
        }
        let seeded = try MacFenceSessionFolder.prepare(fence, previous: previous?.grants, person: person)
        if let a = fence.agent {
            fence.agent = try MacAgentConfig.prepare(a, fence: fence, placeholderTail: placeholders["ANTHROPIC_API_KEY"].map { String($0.suffix(20)) })
        }
        return (fence, seeded, fence.homeReads.notes + seeded.notes + (fence.agent?.notes ?? []))
    }

    /// QUERY of one session.
    public func state(_ s: String) async -> DeckholdSocket.Answer {
        guard MacPlace.folderProblem(directory) == nil else { return .noSession }
        return await DeckholdSocket.query(path: socket(s))
    }

    /// The live session's screen (nil: not running).
    public func liveScreen(_ s: String) async -> LiveScreen? {
        guard MacPlace.folderProblem(directory) == nil else { return nil }
        return await DeckholdSocket.liveScreen(path: socket(s))
    }

    // MARK: adoption

    /// At host start (and when asked): live sockets are this host's sessions; a socket nothing answers is removed (only a
    /// socket this user owns, in our own folder); a record's pid follows what the holder says. Returns the live names.
    @discardableResult
    public func adopt() async -> [String] {
        guard !readOnly, MacPlace.folderProblem(directory) == nil else { return [] }
        let l = await DeckholdSocket.list(directory: directory)
        for s in l.stale {
            let p = socket(s)
            if MacPlace.isOwnSocket(p), case .stale = await DeckholdSocket.query(path: p, timeout: .milliseconds(500)) { unlink(p) }
        }
        var r = records()
        var changed = false
        for s in l.sessions where !s.isEnded {
            if let pid = s.pid, r.sessions[s.name] != nil, r.sessions[s.name]?.pid != pid { r.sessions[s.name]?.pid = pid; changed = true }
        }
        if changed { writeRecords(r) }
        return l.sessions.filter { !$0.isEnded }.map(\.name)
    }

    // MARK: opening

    public struct Opened: Sendable {
        public var session: String
        public var created: Bool
        public var bypassed: Bool
        public var pid: Int?
        public var pathSource: String?
    }

    /// Start session `session` (default: the program's name) running `argv` (default: the login shell) in `workdir`
    /// (default: home), with the clean environment plus `extra` — `deckhold-mac serve`, by posix_spawn, never a shell.
    /// A fenced session's proxy as `open` hands it on: the socket the holder will hold (its descriptor here), the
    /// password (to the program's environment only), its SHA-256 and the policy (to the record), whether its CA copies are
    /// in the session's `etc/`.
    public struct FenceProxyOpen: Sendable {
        public var fd: Int32
        public var password: String
        public var secretSHA256: String
        public var policy: NetworkPolicy
        public var ca: Bool
    }

    public func open(session: String?, argv given: [String]?, workdir: String?, extra: [String: String]?,
                     size: TermSize, holder: URL, recordedArgv: [String]? = nil,
                     fence: MacFence? = nil, gitBaseline: MacFenceGitBaseline? = nil, proxy: FenceProxyOpen? = nil) async throws -> Opened {
        guard !readOnly else { throw HostError(.unavailable, "opening a session on this Mac needs the host") }
        let home = hostEnvironment["HOME"].flatMap { $0.hasPrefix("/") ? $0 : nil } ?? NSHomeDirectory()
        let argv = given.flatMap { $0.isEmpty ? nil : $0 }
            ?? [hostEnvironment["SHELL"].flatMap { $0.hasPrefix("/") ? $0 : nil } ?? "/bin/zsh", "-l"]
        let name = try session ?? Self.defaultName(argv)
        try MacPlace.validateSessionName(name)
        try MacPlace.checkPathBudget(directory, name)
        let dir = workdir ?? home
        var isDir: ObjCBool = false
        guard dir.hasPrefix("/"), FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else {
            throw HostError(.invalid, "--workdir \(dir): not a folder on this Mac (an absolute path to an existing folder)")
        }
        try MacPlace.ensureFolder(directory)
        // A session of that name runs already: it is not opened twice.
        if case .info(let line) = await DeckholdSocket.query(path: socket(name)) {
            let info = SessionInfo.parseList(line).first
            return Opened(session: name, created: false, bypassed: records().sessions[name]?.bypassed == true, pid: info?.pid)
        }
        if loginPath == nil { loginPath = MacSessionsEnvironment.loginPath(host: hostEnvironment) }
        var env = try MacSessionsEnvironment.build(host: hostEnvironment, path: loginPath!.path, extra: extra ?? [:])
        guard Self.findProgram(argv[0], path: env["PATH"] ?? "") != nil else {
            throw HostError(.notFound, "no program \(argv[0]) on this Mac's PATH (\(DisplayPath.tilde(env["PATH"] ?? "")))")
        }
        ensureStoreFolder()
        var prefix: [String] = []
        var fenceRecord: MacFenceRecord?
        if let f = fence {
            // The fence: its profile in the store (no fence can read it), its environment over the allowlist, and
            // sandbox-exec between the holder (unfenced: its socket is in the closed socket folder) and the program.
            env["HOME"] = f.places.home
            MacFenceEnvironment.add(&env, fence: f, proxyPassword: proxy?.password, ca: proxy?.ca ?? false)
            let profile = MacFenceProfile.render(f)
            let state = fenceState(name)
            try MacFenceHostFS.ensureDirectory(state)
            try MacFenceHostFS.writeAtomically(Data(profile.utf8), dir: state, name: "profile.sb", mode: 0o600)
            fenceRecord = f.record(profileSHA256: MacFence.sha256(profile), gitBaseline: gitBaseline?.digests)
            fenceRecord?.proxySecretSHA256 = proxy?.secretSHA256
            fenceRecord?.policy = proxy?.policy
            // The holder puts its pty's path in place of @DOZ_PTY@ — only in sandbox-exec's own arguments.
            prefix = ["/usr/bin/sandbox-exec", "-f", state + "/profile.sb", "-D", "TTY=@DOZ_PTY@", "--"]
        }
        env["DECKHOLD_DIR"] = directory
        let log = folder.appendingPathComponent("\(name).log").path
        let cols = size.cols > 0 ? size.cols : 80, rows = size.rows > 0 ? size.rows : 24
        // A fenced session's proxy socket: the holder's fd 3 for its whole life (never the program's).
        let hold = fence != nil ? proxy?.fd : nil
        let args = [holder.path, "serve"] + (hold != nil ? ["--hold-fd", "3"] : []) + ["-s", name, "-x", String(cols), "-y", String(rows), "--"] + prefix + argv
        let code = try await Self.spawnAndWait(args, environment: env, workdir: fence?.workdir ?? dir, log: log, holdFD: hold)
        guard code == 0 else {
            let tail = ((try? String(contentsOfFile: log, encoding: .utf8)) ?? "").split(separator: "\n").suffix(3).joined(separator: " | ")
            throw HostError(.failed, "the holder for \(name) did not start (exit \(code))" + (tail.isEmpty ? "" : ": \(tail)"))
        }
        var pid: Int?
        if case .info(let line) = await DeckholdSocket.query(path: socket(name)) { pid = SessionInfo.parseList(line).first?.pid }
        let bypassed = MacPlace.bypassesPermissions(argv)
        // A restart records the argv it was OPENED with (what it appended to resume is not kept).
        record(name, MacSessionRecord(argv: recordedArgv ?? argv, workdir: fence?.workdir ?? dir, environmentKeys: (extra ?? [:]).keys.sorted().nilIfEmpty,
                                      openedAt: Date(), holderVersion: nil, holderSHA256: Self.sha256(holder), pid: pid,
                                      bypassed: bypassed ? true : nil, fence: fenceRecord))
        return Opened(session: name, created: true, bypassed: bypassed, pid: pid, pathSource: loginPath?.source)
    }

    /// The session's name: as given, else the program's (checked).
    public nonisolated func sessionName(_ session: String?, argv given: [String]?) throws -> String {
        let argv = given.flatMap { $0.isEmpty ? nil : $0 }
            ?? [hostEnvironment["SHELL"].flatMap { $0.hasPrefix("/") ? $0 : nil } ?? "/bin/zsh", "-l"]
        let name = try session ?? Self.defaultName(argv)
        try MacPlace.validateSessionName(name)
        return name
    }

    /// The session's default name: the program's own, made a name.
    static func defaultName(_ argv: [String]) throws -> String {
        let base = (argv[0] as NSString).lastPathComponent
        let cleaned = String(base.unicodeScalars.filter { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0)) })
            .drop { $0 == "." || $0 == "-" }
        guard !cleaned.isEmpty, cleaned.count <= MacPlace.maximumSessionName else {
            throw HostError(.invalid, "name the session (--session NAME) — \(base) does not make one")
        }
        return String(cleaned)
    }

    /// Where `program` is found: a path as given (executable), else the first PATH folder that has it.
    static func findProgram(_ program: String, path: String) -> String? {
        if program.contains("/") { return access(program, X_OK) == 0 ? program : nil }
        for d in path.split(separator: ":") {
            let p = "\(d)/\(program)"
            var st = stat()
            if stat(p, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, access(p, X_OK) == 0 { return p }
        }
        return nil
    }

    static func sha256(_ url: URL) -> String? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
    }

    /// posix_spawn `args` in a session of its own (SETSID), every other descriptor closed, stdin /dev/null, stdout +
    /// stderr appended to `log`, in `workdir`, with exactly `environment`; wait for it (`serve` returns once its socket
    /// listens). Off the actor.
    static func spawnAndWait(_ args: [String], environment: [String: String], workdir: String, log: String, holdFD: Int32? = nil) async throws -> Int32 {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Int32, Error>) in
            Thread.detachNewThread {
                var attr: posix_spawnattr_t?
                posix_spawnattr_init(&attr)
                defer { posix_spawnattr_destroy(&attr) }
                posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
                var def = sigset_t()
                sigfillset(&def)
                posix_spawnattr_setsigdefault(&attr, &def)
                var none = sigset_t()
                sigemptyset(&none)
                posix_spawnattr_setsigmask(&attr, &none)
                var fa: posix_spawn_file_actions_t?
                posix_spawn_file_actions_init(&fa)
                defer { posix_spawn_file_actions_destroy(&fa) }
                posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0)
                posix_spawn_file_actions_addopen(&fa, 1, log, O_WRONLY | O_CREAT | O_APPEND, 0o600)
                posix_spawn_file_actions_adddup2(&fa, 1, 2)
                if let h = holdFD {
                    // dup2 onto 3 clears close-on-exec; a descriptor that IS 3 is inherited explicitly.
                    if h == 3 { posix_spawn_file_actions_addinherit_np(&fa, 3) } else { posix_spawn_file_actions_adddup2(&fa, h, 3) }
                }
                posix_spawn_file_actions_addchdir_np(&fa, workdir)
                let cargs: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
                let cenv: [UnsafeMutablePointer<CChar>?] = environment.keys.sorted().map { strdup("\($0)=\(environment[$0]!)") } + [nil]
                defer { for p in cargs { free(p) }; for p in cenv { free(p) } }
                var pid: pid_t = 0
                let rc = cargs.withUnsafeBufferPointer { a in
                    cenv.withUnsafeBufferPointer { e in
                        posix_spawn(&pid, args[0], &fa, &attr, UnsafeMutablePointer(mutating: a.baseAddress!), UnsafeMutablePointer(mutating: e.baseAddress!))
                    }
                }
                guard rc == 0 else {
                    c.resume(throwing: HostError(.failed, "could not start \(args[0]): \(String(cString: strerror(rc)))"))
                    return
                }
                var status: Int32 = 0
                while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
                let exited = (status & 0x7F) == 0
                c.resume(returning: exited ? (status >> 8) & 0xFF : 128 + (status & 0x7F))
            }
        }
    }

    // MARK: ending

    /// End session `s`'s program the way a terminal hangup does, then harder — HUP, TERM, KILL to its process group (the
    /// pid its own holder says; the program leads its own group under the holder's pty). `Sandbox.SessionEnd`'s words.
    public func end(_ s: String, hupSeconds: Double = 3, termSeconds: Double = 3, killSeconds: Double = 3) async throws -> Sandbox.SessionEnd {
        guard !readOnly else { throw HostError(.unavailable, "ending a session needs the host") }
        guard case .info(let line) = await state(s), let pid = SessionInfo.parseList(line).first?.pid, pid > 1, pid != Int(getpid()) else {
            return .notRunning
        }
        let target = pid_t(pid)
        for (sig, how, wait) in [(SIGHUP, Sandbox.SessionEnd.hangup, hupSeconds), (SIGTERM, .terminate, termSeconds), (SIGKILL, .kill, killSeconds)] {
            // Only the group the holder named — and only while it is still that group.
            if getpgid(target) == target { killpg(target, sig) } else { kill(target, sig) }
            let deadline = Date().addingTimeInterval(wait)
            while Date() < deadline {
                if case .info = await DeckholdSocket.query(path: socket(s), timeout: .milliseconds(500)) {
                    try? await Task.sleep(for: .milliseconds(100))
                    continue
                }
                return how
            }
        }
        return .stuck
    }

    /// Forget a session that does not run (its record, its `.exit`, its log, its saved screen).
    public func forget(_ s: String) {
        guard !readOnly else { return }
        // A fenced one: its own folder (by the host's file rules — the program could write there) and its state.
        if let f = records().sessions[s]?.fence {
            try? MacFenceHostFS.remove(f.sessionFolder)
            try? MacFenceHostFS.remove(fenceState(s))
        }
        record(s, nil)
        unlink(DeckholdSocket.exitFile(forSocket: socket(s)))
        unlink(folder.appendingPathComponent("\(s).log").path)
        let keep = Set(SavedScreens.list(directory: screens).map(\.session)).subtracting([s])
        SavedScreens.remove(directory: screens, keeping: keep)
    }

    // MARK: saved screens

    /// `<store>/mac-sessions/screens` (0700): the sessions' saved screens — what `screen` shows when a holder is gone.
    public nonisolated var screens: URL { folder.appendingPathComponent("screens") }

    public nonisolated func savedScreen(_ s: String) -> SavedScreen? { SavedScreens.read(directory: screens, session: s) }

    /// Save each live session's screen (with `changedOnly`, only those that wrote since their last one) — a momentary
    /// attach (HELLO 0×0, DUMP) that disturbs nothing. A session that ended has none (removed); a gone one keeps its last.
    @discardableResult
    public func captureScreens(changedOnly: Bool, reason: String) async -> ScreenCaptureReport {
        var report = ScreenCaptureReport()
        guard !readOnly, MacPlace.folderProblem(directory) == nil else { return report }
        let t0 = ContinuousClock.now
        let l = await DeckholdSocket.list(directory: directory)
        report.listed = l.sessions
        let saved = Dictionary(SavedScreens.list(directory: screens).map { ($0.session, $0) }, uniquingKeysWith: { a, _ in a })
        let ended = Set(l.sessions.filter(\.isEnded).map(\.name))
        report.removed = SavedScreens.remove(directory: screens, keeping: Set(saved.keys).subtracting(ended))
        ensureStoreFolder()
        for s in l.sessions.filter({ !$0.isEnded }).prefix(SavedScreens.maximumSessions) {
            if changedOnly, let i = saved[s.name], i.bytesOut == s.bytesOut { report.unchanged.append(s.name); continue }
            guard let shot = await DeckholdSocket.capture(path: socket(s.name), grid: s.grid,
                                                          timeout: .seconds(SavedScreens.perSessionTimeoutSeconds)) else {
                report.failed.append(s.name)
                continue
            }
            let d = SavedScreens.parseDump(shot.dump)
            let info = SavedScreenInfo(session: s.name, savedAt: Date(), reason: reason, cols: d.cols ?? s.size?.cols, rows: d.rows ?? s.size?.rows,
                                       screen: d.screen ?? s.screen, command: s.command, pid: s.pid, bytesOut: s.bytesOut)
            do {
                try SavedScreens.write(directory: screens, info: info, vt: shot.snapshot, text: d.text, grid: shot.grid)
                report.captured.append(s.name)
            } catch { report.failed.append(s.name) }
        }
        let d = ContinuousClock.now - t0
        report.milliseconds = Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
        return report
    }

    // MARK: connections

    public nonisolated func attach(_ s: String, size: TermSize) -> SessionConnection { DeckholdSocket.attach(path: socket(s), size: size) }
    public nonisolated func watchStatus(_ s: String) -> SessionConnection { DeckholdSocket.watchStatus(path: socket(s)) }
}

extension Array {
    var nilIfEmpty: [Element]? { isEmpty ? nil : self }
}
