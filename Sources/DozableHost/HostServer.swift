import Darwin
import Foundation
import DozableKit

/// `doz host` (585, owner ruling (b): a lazy per-user host). One process per store owns every
/// running VM, the egress proxies, the metrics writer and the shared event-loop group, and serves
/// `<store>/host.sock`.
///
/// Life:
///   · started by the first CLI call that needs it (a detached child, `HostLauncher`), or by hand;
///   · holds `<store>/host.lock` (flock) for its whole life — there is never a second host for a store,
///     and a new one waits for the old one to finish exiting before it loads anything;
///   · 693: stays running with nothing open (`daemon.always_on`, default on); with it off, exits by itself once NO sandbox
///     has a VM (booting, running, paused, asleep) and no client is connected for `idleTimeoutMinutes` (default 0 = never);
///     a daemon whose login keychain is locked is never always on and exits after 5 minutes idle (`IdleDecision`);
///   · when its program is replaced (an update) and nothing is live: an always-on daemon restarts in place from the
///     stable path (`StableExecutable`), any other exits — and fenced sessions are handed over;
///   · `doz host stop`, SIGTERM or SIGINT: Hibernate everything (quit = Hibernate) and exit;
///   · after a crash (kill -9): the next CLI call starts a new host, which restores what was asleep
///     and reports what died (`HostCore.recoverAfterStart`). Hibernated sandboxes wake on demand.
public final class HostServer: @unchecked Sendable {
    public let store: DozableStore
    public let idleTimeoutMinutes: Double
    public let version: String
    /// 693: the arguments a daemon started in its place gets (`--idle-timeout` when this one was given it).
    let restartExtra: [String]
    let core: HostCore
    /// The chat server this daemon runs while `chat.enabled` (`ChatSupervisor`).
    let chat: ChatSupervisor
    let startedAt = Date()

    private let lock = NSLock()
    private var connections = 0
    private var idleSince: Date?
    private var listenFD: Int32 = -1
    private var lockFD: Int32 = -1
    private var formerLockFD: Int32 = -1
    private var stopping = false
    private var signalSources: [DispatchSourceSignal] = []
    private var _recipeCatalogueWaiting = false
    /// A newer recipe catalogue was downloaded (it applies at the next host start).
    var recipeCatalogueWaiting: Bool {
        get { lock.withLock { _recipeCatalogueWaiting } }
        set { lock.withLock { _recipeCatalogueWaiting = newValue } }
    }

    init(store: DozableStore, idleTimeoutMinutes: Double, version: String, restartExtra: [String] = []) {
        self.store = store
        self.idleTimeoutMinutes = idleTimeoutMinutes
        self.version = version
        self.restartExtra = restartExtra
        // 591: the settings' keep-alive for a store that has not chosen (read once, at start).
        let settings = DozableSettings.load()
        core = HostCore(store: store, readOnly: false, version: version, services: .forHost(),
                        newStoreKeepalive: settings.bool(SettingKey.keepalive),
                        newStoreDefaultAccount: settings.string(SettingKey.defaultAccount) ?? "mac",
                        // 594: `latest` agent versions are asked of the npm registry (DOZ_TEST_NPM_REGISTRY: a stub).
                        agentRegistry: .fromEnvironment(),
                        // 618: the gateways' public model lists (DOZ_TEST_MODEL_LIST: offline or a stand-in).
                        modelLists: .fromEnvironment())
        // The webhook entries live in the daemon's keychain seam (the memory one under DOZ_TEST_CREDENTIALS=memory).
        chat = ChatSupervisor(paths: ChatPaths(store: store), executable: HostLauncher.executablePath, release: version,
                              keychain: core.services.keychain, keychainLocked: { HostServer.keychainLocked },
                              daemonSocket: store.socket.path)
    }

    public enum StartError: Error, LocalizedError {
        case alreadyRunning(Int32?)
        case socket(String)
        public var errorDescription: String? {
            switch self {
            case .alreadyRunning(let pid): "a daemon is already running for this store" + (pid.map { " (pid \($0))" } ?? "")
            case .socket(let s): s
            }
        }
    }

    /// 593: this host was started by `HostLauncher` (fully detached), not by a person's `--foreground`.
    nonisolated(unsafe) public static var launchedDetached: Bool = false
    /// 678: this host left a Darwin background state it inherited at its start (`ProcessPriority.liftInheritedBackground`).
    nonisolated(unsafe) public static var priorityRestored: Bool = false
    /// 679 B6: why this host's session cannot read the login keychain (nil: it can) — read at its start.
    nonisolated(unsafe) public static var keychainLocked: String?

    /// Run the host in this process until it exits (never returns). `launched`: started by
    /// `HostLauncher` (its parent is launchd); false: a person ran `doz host start --foreground`. `restartExtra`: the
    /// arguments a daemon started in its place (a hand-over, a restart in place) gets — `--idle-timeout` when given.
    public static func run(store: DozableStore, idleTimeoutMinutes: Double, version: String, launched: Bool = false,
                           restartExtra: [String] = []) async throws -> Never {
        TestSafety.checkStore(store.root)          // 611
        launchedDetached = launched
        // 678 (the plan's default, owner to confirm): a host a client started inherits that client's background
        // state (a `taskpolicy -b` tool, a background agent worker) — and every wake it runs crawls. A launched host
        // leaves it; a person's `--foreground` host keeps what they chose.
        if launched { priorityRestored = ProcessPriority.liftInheritedBackground() }
        setvbuf(stdout, nil, _IOLBF, 0)
        signal(SIGPIPE, SIG_IGN)
        signal(SIGHUP, SIG_IGN)
        try store.ensureDirectory()
        guard store.socketPathFits else { throw StartError.socket(UnixSocket.Failure.pathTooLong(store.socket.path).localizedDescription) }
        let server = HostServer(store: store, idleTimeoutMinutes: idleTimeoutMinutes, version: version, restartExtra: restartExtra)
        try server.takeLock(waitSeconds: 60)
        // 694: a daemon started lets go of `doz daemon stop`'s hold (the login item's look starts one again from now on).
        LoginStart.release(store)
        // 606: the proxy never connects a sandbox to one of Dozable's own dashboards on this Mac.
        LocalDashboards.protect(DashboardPorts(store: store).current)
        // 691: nor, through the route to this Mac's ports, to a sandbox's forwarded web port (fenced sessions' proxy ports
        // register themselves while served; the dashboards are `LocalDashboards`').
        let table = server.core.portTable
        HostRoute.protect { table.macPorts }
        HostLog.enabled = true
        HostLog.line("doz daemon \(version) (pid \(getpid())) — store \(store.root.path), idle timeout \(idleTimeoutMinutes) min")
        HostLog.line(launched ? "detached: parent \(getppid())\(getppid() == 1 ? " (launchd)" : " — NOT launchd"), session \(getsid(0))"
                              : "in the foreground (parent \(getppid())): it lives in that terminal's process tree")
        if priorityRestored { HostLog.line("started at background priority (inherited from the client that started it) — moved to normal priority") }
        keychainLocked = HostSessionKind.lockedReason()
        if let why = keychainLocked {
            HostLog.line("started from a session where the login keychain is locked (\(why)): this Mac's Claude login (and anything else in the keychain) cannot be read — doz daemon restart from a logged-in session")
        }
        // 693: always on (the setting, re-read at each idle look) — never for a daemon whose login keychain is locked.
        let alwaysOnSetting = DozableSettings.load().bool(SettingKey.alwaysOn)
        let timeout = IdleDecision.effectiveTimeout(alwaysOnSetting: alwaysOnSetting, keychainLocked: keychainLocked, timeoutMinutes: idleTimeoutMinutes)
        HostLog.line(IdleDecision.alwaysOn(setting: alwaysOnSetting, keychainLocked: keychainLocked)
                     ? "always on (daemon.always_on): it keeps running with nothing open"
                     : (keychainLocked != nil ? "not kept running (the login keychain is locked here): " : "daemon.always_on is off: ")
                        + (timeout.map { "it exits after \($0.formatted()) min with nothing running" } ?? "daemon.idle_timeout_minutes is 0 — it never exits by itself"))
        // EXPERIMENTAL (604): which app macOS asks about the microphone for, for this host's audio sandboxes.
        HostLog.line("microphone (audio sandboxes, experimental): macOS asks on behalf of "
                     + (HostCore.microphoneApp.map { "\($0.description) — \($0.path)" } ?? "an app it could not name"))
        if ProcessInfo.processInfo.environment["DOZ_TEST_CREDENTIALS"] == "memory" {
            HostLog.line("TEST: DOZ_TEST_CREDENTIALS=memory — accounts' secrets live in this daemon's memory, never the keychain; nothing is verified")
        }
        // 599i: a test's fake OpenAI — said, so a test can check its host has it before anything reaches OpenAI.
        if let o = OpenAISeam.upstream() {
            HostLog.line("TEST: DOZ_TEST_OPENAI_UPSTREAM — OpenAI's hosts (sign-in, refresh, the proxy's leg) go to \(o.host):\(o.port), trusting only its CA")
        }
        // 591: the VM layouts this host records name it; and it remembers the file it runs from, to
        // tell a later "Internal Virtualization error" caused by an update underneath it.
        VMLayout.recorder = "doz \(version)"
        let exe = ExecutableIdentity.of(path: HostLauncher.executablePath)
        // 693: and the path a daemon started in its place runs (a Homebrew keg's formula `opt` link — the keg goes at cleanup).
        let stable = StableExecutable.path(for: HostLauncher.executablePath)
        await server.core.setExecutable(exe, stablePath: stable)
        HostLog.line("running from \(exe?.path ?? HostLauncher.executablePath)\(exe?.cdhash.map { " (cdhash \($0.prefix(12)))" } ?? "")"
                     + (stable != (exe?.path ?? HostLauncher.executablePath) ? " — installed as \(stable)" : ""))
        // 694: the login item, when there is one: its program path rewritten when out of date, or removed when the rule no
        // longer holds (the setting, always on, an app's job). A daemon's start never INSTALLS one (only `on` does).
        Task.detached {
            // Chat on counts as one keeper: it needs the daemon at login like a kept session.
            let chatOn = ChatSettingsView.read().enabled
            let r = DaemonLoginItem.sync(store: store, mode: .daemonStart, keepers: server.keepers + (chatOn ? 1 : 0), program: stable)
            if r.decision.action != .none { HostLog.line("login item: " + r.line) }
        }
        // The recipes this host (and every command while it runs) uses — chosen once, at this process's start.
        let recipes = RecipeCatalogueSelection.startChoice
        HostLog.line("recipes: \(RecipeCatalogue.source.describe(dozVersion: version))"
                     + (recipes?.promoted == true ? " — the catalogue downloaded earlier, applied now" : "")
                     + (recipes?.notLooked.map { " (\($0))" } ?? ""))
        if let p = recipes?.problem { HostLog.line(p) }
        // 653: the recipes that are not Dozable's (yours, the community catalogues) — chosen at this start too.
        if let x = RecipeExtras.describe() { HostLog.line("recipes not Dozable's: \(x)") }
        await server.core.load()
        // The workspaces make their rooms in the chat server this daemon runs, as you.
        await server.core.setWorkspaceChat(OwnerWorkspaceChat(ready: { [weak server] in
            guard let server, ChatSettingsView.read().enabled else { return .off }
            do {
                let st = try await server.chat.sync(human: nil, retry: false, waitReady: true, blocked: await server.chatBlocked())
                return st.ready ? .ready : .notReady(st.problem ?? st.state)
            } catch { return .notReady(HostError.from(error).message) }
        }, owner: ChatOwnerRooms(client: ChatOwnerClient(paths: server.chat.paths)),
           closed: { [weak server] set in await server?.chat.setClosed(set, reasons: DozableSettings.load().bool(SettingKey.chatRefusalReasons)) },
           remove: { [weak server] room, id, last in
               guard let server else { throw HostError(.unavailable, "the daemon is stopping") }
               try await server.chat.removeRoom(room, id: id, lastSeq: last)
           },
           control: { [weak server] field, body in
               guard let server else { throw HostError(.unavailable, "the daemon is stopping") }
               return try await server.chat.control(field, body)
           }))
        // The closed set, worked out from the records, handed to the chat server (kept for its every start).
        Task.detached { await server.core.pushClosedSet() }
        // The bots change the chat server's participants through the supervisor (its one writer of directory.json and
        // tokens.json); their tokens' keychain items of no bot are swept once (never in the read-only core).
        await server.core.setBotChat(SupervisorBotChat(supervisor: server.chat, blocked: { [weak server] in await server?.chatBlocked() ?? true }))
        Task.detached { await server.core.sweepBotTokens() }
        // An unfenced workspace manager's token folders whose session does not run (a daemon that died before a stop).
        Task.detached { await server.core.sweepManagerTokenFiles() }
        // A worker left pending by a daemon that stopped mid-add: undone when its place does not run.
        Task.detached { await server.core.sweepPendingWorkers() }
        do {
            server.listenFD = try UnixSocket.listen(store.socket.path)
        } catch {
            throw StartError.socket(error.localizedDescription)
        }
        let lfd = server.listenFD
        Thread.detachNewThread { server.acceptLoop(lfd) }
        server.installSignalHandlers()
        Task.detached { await server.core.recoverAfterStart() }
        // 747: the resource samples (timeline.sample_seconds).
        Task.detached { await server.core.runSampler() }
        // 747: the timeline's derived store — caught up now (a first start fills it in the background), then kept so.
        Task.detached { await server.core.startTimeline() }
        // The sessions held on this Mac outlive any host: this one adopts what runs (and drops stale sockets).
        Task.detached { await server.core.adoptMacSessions() }
        // 695: keep-alive always — a watcher on each Mac login with nothing using it (after the adoption: its fenced sessions
        // are then known to its look at the holders).
        Task.detached { await server.core.ensureStandingWatchers() }
        Task.detached { await server.idleLoop() }
        // 715: a published dashboard is kept running (it comes back at login with the daemon, and after a crash) — never
        // after the person stopped it (`PublishedDashboard`).
        Task.detached {
            try? await Task.sleep(for: .seconds(1))
            while true {
                if let line = PublishedDashboard.ensure(store, program: stable) { HostLog.line(line) }
                try? await Task.sleep(for: .seconds(PublishedDashboard.interval()))
            }
        }
        // The chat server: looked at every second (the settings every 5 s; a `doz chat` command at once). Never one while
        // the daemon stops or after its program was replaced — the restart in place brings one up from the new build.
        Task.detached {
            while true {
                await server.chat.tick(blocked: await server.chatBlocked())
                try? await Task.sleep(for: .seconds(1))
            }
        }
        // 593 §9 (S2): the periodic screen capture (read once, at start — like the idle timeout).
        let captureMinutes = DozableSettings.load().int(SettingKey.screenCapture)
        HostLog.line(captureMinutes > 0 ? "saving session screens every \(captureMinutes) min while a sandbox runs (daemon.screen_capture_minutes)"
                                        : "periodic screen capture off (daemon.screen_capture_minutes = 0)")
        if captureMinutes > 0 {
            Task.detached {
                while true {
                    try? await Task.sleep(for: .seconds(Double(captureMinutes) * 60))
                    await server.core.captureScreensPeriodically()
                }
            }
        }
        // 617 (owner: "record the latest version and how old it is"): every agent's latest release, hourly while a host
        // runs (the same hourly cache as a preparation's check) — so a look (doz search, doz try, the Quick try) can say it.
        Task.detached {
            while true {
                await server.core.refreshAgentVersions()
                try? await Task.sleep(for: .seconds(3600))
            }
        }
        // The recipe catalogue: a newer one looked for at most daily while a host runs (672; the loop wakes hourly to see
        // whether a look is due); it applies at the next start.
        Task.detached {
            while true {
                let outcome = await RecipeCatalogueRefresh.refresh(version: version, executable: HostLauncher.executablePath)
                switch outcome {
                case .downloaded(let serial):
                    HostLog.line("recipe catalogue \(serial) downloaded and verified — it applies at the next daemon start")
                    server.recipeCatalogueWaiting = true
                case .refused(let why, let reportNow): if reportNow { HostLog.line(why) }
                default: break
                }
                // 653: and each community catalogue you added — it too applies at the next start.
                for (name, o) in await CommunityRefresh.refreshAll(version: version) {
                    switch o {
                    case .downloaded(let serial):
                        HostLog.line("community recipes \(name): catalogue \(serial) downloaded and verified — it applies at the next daemon start")
                        server.recipeCatalogueWaiting = true
                    case .refused(let why, let reportNow): if reportNow { HostLog.line("community recipes \(name): \(why)") }
                    default: break
                    }
                }
                try? await Task.sleep(for: .seconds(RecipeCatalogueRefresh.tick))
            }
        }
        HostLog.line("listening on \(store.socket.path)")
        while true { try? await Task.sleep(for: .seconds(3600)) }
    }

    /// The store's lock, for the life of the process. A daemon that is exiting still holds it: wait.
    /// TEMPORARY (the host→daemon migration; without it there is no former lock): then the lock an older build's daemon
    /// takes too, AFTER this one and the same way — an older daemon still running (or starting) on this store is never a
    /// second owner, and one that is exiting (its idle exit after an update, a hand-over of fenced sessions to this build)
    /// is waited for. Both are held for this process's whole life.
    private func takeLock(waitSeconds: Double) throws {
        let held = try Self.takeStoreLocks(store, waitSeconds: waitSeconds)
        lockFD = held[0]
        if held.count > 1 { formerLockFD = held[1] }
        try? "\(getpid())\n".write(to: store.pidFile, atomically: true, encoding: .utf8)
    }

    /// The lock(s) `takeLock` holds, in order (the daemon's, then — migration only — the former one); each a descriptor
    /// whose flock is held until it is closed or unlocked.
    static func takeStoreLocks(_ store: DozableStore, waitSeconds: Double) throws -> [Int32] {
        let deadline = Date().addingTimeInterval(waitSeconds)
        var held: [Int32] = []
        for file in [store.lockFile] + (store.formerLockFile.map { [$0] } ?? []) {
            let fd = open(file.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
            guard fd >= 0 else {
                for h in held { close(h) }
                throw StartError.socket("cannot open \(file.path): \(String(cString: strerror(errno)))")
            }
            while flock(fd, LOCK_EX | LOCK_NB) != 0 {
                // A live daemon that is not exiting answers its socket (an older build's: its old one): then this one is not needed.
                if Date() > deadline || HostClient.connectAny(store).map({ close($0); return true }) == true {
                    close(fd)
                    for h in held { close(h) }
                    throw StartError.alreadyRunning(store.hostPID())
                }
                usleep(100_000)
            }
            held.append(fd)
        }
        // The older daemon is gone (its lock is ours): a pid it left would read as a daemon killed.
        if held.count > 1, let f = store.formerPidFile { try? FileManager.default.removeItem(at: f) }
        return held
    }

    private func releaseLocks() {
        if lockFD >= 0 { flock(lockFD, LOCK_UN) }
        if formerLockFD >= 0 { flock(formerLockFD, LOCK_UN) }
    }

    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            src.setEventHandler { [weak self] in
                guard let self else { return }
                HostLog.line("signal \(sig): hibernating every sandbox, then exiting")
                Task.detached { await self.shutdown(prepare: true, reply: nil) }
            }
            src.resume()
            signalSources.append(src)
        }
    }

    // MARK: idle

    /// 693: the setting `daemon.always_on`, re-read at each look (it applies at once).
    var alwaysOnSetting: Bool { DozableSettings.load().bool(SettingKey.alwaysOn) }
    /// Whether this daemon is always on now (never when its login keychain is locked).
    var alwaysOn: Bool { IdleDecision.alwaysOn(setting: alwaysOnSetting, keychainLocked: Self.keychainLocked) }
    /// The idle timeout in effect now (minutes; 0 = never) — what `daemon status` reports.
    var effectiveIdleTimeoutMinutes: Double {
        IdleDecision.effectiveTimeout(alwaysOnSetting: alwaysOnSetting, keychainLocked: Self.keychainLocked, timeoutMinutes: idleTimeoutMinutes) ?? 0
    }
    /// 693: the kept sessions on this Mac (none yet: kept sessions come later). They keep the daemon up like fenced ones.
    var keepers: Int { 0 }

    /// No chat server while this daemon stops, nor once its program was replaced.
    func chatBlocked() async -> Bool {
        if lock.withLock({ stopping }) { return true }
        return await core.executableChange() != nil
    }

    /// 693 (decision 6): `IdleDecision` decides; this loop gathers its inputs and acts. It never skips its look — a daemon
    /// that never idles out (always on, or a timeout of 0) must still pick up a new build (`restartInPlace`) or a newer
    /// recipe catalogue.
    func idleLoop() async {
        while true {
            let setting = alwaysOnSetting
            let timeout = IdleDecision.effectiveTimeout(alwaysOnSetting: setting, keychainLocked: Self.keychainLocked, timeoutMinutes: idleTimeoutMinutes)
            try? await Task.sleep(for: .milliseconds(Int(IdleDecision.interval(effectiveTimeout: timeout) * 1000)))
            // 594: an image being prepared keeps the host up like a live sandbox (nobody need be attached).
            let live = await core.liveSandboxes() + (await core.runningPreparations()).map { "prepare \($0)" }
            // A fenced session on this Mac keeps the host up (its git guard and proxy are the host's); unfenced ones never do.
            let fenced = await core.fencedMacSessions()
            // 591: its program changed under it. (Nothing is lost by a new daemon: no VM runs; sandboxes asleep keep their
            // snapshots — a failed wake's too, e1af862.)
            let change = await core.executableChange()
            let chatOn = chat.enabledSetting
            let now = Date()
            let d: IdleDecision = lock.withLock {
                var d = IdleDecision(alwaysOnSetting: setting, keychainLocked: Self.keychainLocked, timeoutMinutes: idleTimeoutMinutes,
                                     live: live, fenced: fenced, keepers: keepers, chatOn: chatOn, connections: connections, stopping: stopping,
                                     executableChange: change, recipeCatalogueWaiting: _recipeCatalogueWaiting, launched: Self.launchedDetached)
                if d.isIdle && !stopping {
                    if idleSince == nil { idleSince = now }
                    d.idleSeconds = now.timeIntervalSince(idleSince!)
                } else {
                    idleSince = nil
                }
                return d
            }
            switch d.action {
            case .stay:
                continue
            case .exit(let why):
                HostLog.line(why)
                await shutdown(prepare: false, reply: nil)
            case .restartInPlace(let why):
                await restartInPlace(why)
            case .handOver(let why):
                await handOver(why, fenced: fenced)
            }
        }
    }

    /// 693 (decision 6): an always-on daemon whose program changed (or that has a newer recipe catalogue to load), with
    /// nothing live and no client connected, starts a daemon of the installed build in its place — from the STABLE path,
    /// detached as every daemon is (`HostLauncher.spawn`: parent launchd, never this process's child) — and exits. One owner
    /// always: the decision is re-checked under the lock as this one stops taking clients (a client that came meanwhile
    /// cancels it); its socket goes first, so the new daemon never mistakes it for a live one; the new daemon waits for the
    /// store's lock, which this one holds until its last line. A new program that cannot be started: it exits anyway (as
    /// a daemon that is not always on does) — nothing is live, and the next command starts the installed doz.
    func restartInPlace(_ why: String) async {
        let first: Bool = lock.withLock {
            if stopping || connections > 0 { return false }
            stopping = true
            return true
        }
        guard first else { return }
        let fd = lock.withLock { () -> Int32 in let f = listenFD; listenFD = -1; return f }
        if fd >= 0 { Darwin.shutdown(fd, SHUT_RDWR); close(fd) }
        unlink(store.socket.path)
        HostLog.line(why)
        let stable = await core.stableExecutable ?? HostLauncher.executablePath
        if FileManager.default.isExecutableFile(atPath: stable) {
            do {
                let pid = try HostLauncher.spawn(store: store, executable: stable, extra: restartExtra)
                HostLog.line("the new daemon (pid \(pid), \(stable)) waits for the store's lock")
            } catch {
                HostLog.line("could not start the new daemon (\(error)) — the next command starts one")
            }
        } else {
            HostLog.line("there is no program at \(stable) to start — the next command starts the installed doz")
        }
        try? FileManager.default.removeItem(at: store.pidFile)
        await chat.stopForExit()
        HostLog.line("daemon exiting (restarted in place)")
        releaseLocks()
        exit(0)
    }

    /// The hand-over of fenced sessions on this Mac to a host of the build now installed — one host per store, always:
    /// this one stops taking clients (its socket goes, so the new one does not mistake it for a live host), starts the
    /// new host (which waits for `host.lock`, as every host does), and — STILL holding the lock, still the only owner of
    /// the records, logs, policies and git guards — stops accepting on every session's proxy (new connections wait in
    /// the holders' backlogs), closes the idle ones and lets open tunnels finish for up to 30 s, cuts the rest, then
    /// releases the lock and exits. The new host takes the lock, adopts each session (`GETFD` from its holder) and serves.
    /// No hand-over file: the lock is the hand-over. 693: the new daemon is started from the STABLE path (a Homebrew keg's
    /// `opt` link — `brew cleanup` may already have deleted this one's keg), and a newer recipe catalogue hands over too.
    func handOver(_ why: String, fenced: [String]) async {
        let first: Bool = lock.withLock {
            if stopping || connections > 0 { return false }
            stopping = true
            return true
        }
        guard first else { return }
        let fd = lock.withLock { () -> Int32 in let f = listenFD; listenFD = -1; return f }
        if fd >= 0 { Darwin.shutdown(fd, SHUT_RDWR); close(fd) }
        unlink(store.socket.path)
        HostLog.line("\(why) — handing them to a new daemon of the installed build")
        let stable = await core.stableExecutable ?? HostLauncher.executablePath
        do {
            let pid = try HostLauncher.spawn(store: store, executable: stable, extra: restartExtra)
            HostLog.line("the new daemon (pid \(pid), \(stable)) waits for the store's lock")
        } catch {
            HostLog.line("could not start the new daemon (\(error)) — the next command starts one; the sessions' connections wait until then")
        }
        let t0 = Date()
        let cut = await core.drainMacProxies(timeout: 30)
        await core.captureMacScreens(reason: "hand-over")
        HostLog.line(String(format: "proxies drained in %.1f s%@ — exiting; the new daemon takes over", Date().timeIntervalSince(t0),
                            cut > 0 ? " (\(cut) connection\(cut == 1 ? "" : "s") still open were cut)" : ""))
        try? FileManager.default.removeItem(at: store.pidFile)
        await chat.stopForExit()
        releaseLocks()
        exit(0)
    }

    var idleSeconds: Double? { lock.withLock { idleSince.map { Date().timeIntervalSince($0) } } }
    var connectionCount: Int { lock.withLock { connections } }

    /// Stop serving, (optionally) Hibernate everything, answer the `host stop` that asked, exit.
    func shutdown(prepare: Bool, reply: HostConnection?) async {
        let first: Bool = lock.withLock {
            if stopping { return false }
            stopping = true
            return true
        }
        guard first else { return }
        // 767: every journal follow ends cleanly (`end`, reason daemon-stopping) — a bare EOF would mean "reconnect".
        JournalFollower.stopping = true
        try? await Task.sleep(for: .milliseconds(300))
        // New clients start a new host, which waits for this one's lock before it loads anything.
        let fd = lock.withLock { () -> Int32 in let f = listenFD; listenFD = -1; return f }
        if fd >= 0 { Darwin.shutdown(fd, SHUT_RDWR); close(fd) }
        unlink(store.socket.path)
        // 594 W22: the caller of `host stop` sees each sandbox hibernate (and the host's last step) as
        // it happens, then what was done — the progress every stopping client shows.
        let t0 = ContinuousClock.now
        var rows: [HostStopRow] = []
        if prepare {
            rows = await core.prepareAllForExit { e in
                if let reply { reply.send(HostMessage(event: e)) }
                HostLog.line(e.line)
            }
        }
        // 751: a guarded test run's stop of a scratch store ends that store's sessions on this Mac first (their holders
        // exit), so a test that forgets `workspace finish` leaks none. Never outside a test.
        if prepare, TestSafety.endsHeldSessionsAtStop(store: store.root) {
            let ended = await core.macEndHeldAtTestStop()
            if ended > 0 { HostLog.line("a guarded test run: ended \(ended) session(s) on this Mac this store held") }
        }
        // The sessions on this Mac are not the host's to stop: their screens are saved once more, and they keep running.
        let macLive = prepare ? await core.macSessionsAtExit() : 0
        if macLive > 0 { HostLog.line("\(macLive) session(s) on this Mac keep running (their holders outlive the daemon)") }
        if let reply {
            let d = ContinuousClock.now - t0
            var result = HostStopResult(sandboxes: rows, milliseconds: Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15,
                                        version: version)
            result.macSessions = macLive > 0 ? macLive : nil
            reply.send((try? JSONValue(encoding: result)).map { HostMessage.success($0) } ?? .success(.string("stopped")))
            reply.close()
        }
        try? FileManager.default.removeItem(at: store.pidFile)
        await chat.stopForExit()
        HostLog.line("daemon exiting")
        releaseLocks()
        exit(0)
    }

    // MARK: connections

    private func acceptLoop(_ lfd: Int32) {
        while true {
            let c = accept(lfd, nil, nil)
            if c < 0 {
                if errno == EINTR { continue }
                return                                       // the listener was closed
            }
            _ = fcntl(c, F_SETFD, FD_CLOEXEC)
            let conn = HostConnection(fd: c)
            let accepted: Bool = lock.withLock {
                if stopping { return false }
                // Counted while open (an attach or a stream keeps the host up); a short request that
                // came and went — `ls`, `host status` — does not restart the idle clock.
                connections += 1
                return true
            }
            guard accepted else { conn.close(); continue }
            Thread.detachNewThread { [self] in self.serve(conn) }
        }
    }

    private func finished(_ conn: HostConnection) {
        conn.close()
        lock.withLock { connections -= 1 }
    }

    /// One connection: its request line, then the operation.
    private func serve(_ conn: HostConnection) {
        let reader = LineReader(fd: conn.fd)
        guard let line = reader.readLine(limit: 1 << 20) else { finished(conn); return }
        let req: HostRequest
        do { req = try HostWire.decoder.decode(HostRequest.self, from: line) } catch {
            conn.send(.failure(HostError(.invalid, "a request this daemon cannot read (\(error.localizedDescription)) — is the CLI newer than the daemon? (doz daemon stop)")))
            finished(conn)
            return
        }
        // The streaming operations below bypass `HostCore.handle`: the protocol's range is checked here too.
        if let refused = HostProtocol.refusal(req) {
            conn.send(.failure(refused))
            finished(conn)
            return
        }
        // The ONE permission gate, before any routing (the core, chat and the streams): the owner's request — every request
        // with no `actAs` — passes before anything is read; an agent's is decided (`PermissionGate`, docs/engineering/workspaces.md).
        if let refused = PermissionGate.refusal(req, store: store) {
            conn.send(.failure(refused))
            finished(conn)
            return
        }
        switch req.op {
        case .attach:
            attach(conn, reader: reader, request: req)
        case .events:
            stream(conn, reader: reader) { [core] in
                let name = req.name
                // 612: `session-status` only to a client that asked (an older one cannot decode the kind).
                let statuses = req.sessionStatus == true
                return core.subscribe().filter { (name == nil || $0.sandbox == name) && (statuses || $0.kind != .sessionStatus) }
                    .map { HostMessage(event: $0) }
            }
        case .timelineSubscribe:
            stream(conn, reader: reader) { [core] in core.timelineBatches(req) }
        case .workspaceJournalFollow:
            journalFollow(conn, reader: reader, request: req)
        case .copy:
            copy(conn, reader: reader, request: req)
        case .netLog where req.follow == true:
            netLogFollow(conn, reader: reader, request: req)
        case .console where req.follow == true:
            consoleFollow(conn, reader: reader, request: req)
        case .chatSync, .chatAdd, .chatSet, .chatRemove, .chatToken, .chatMembers, .chatWebhookSet, .chatWebhookRemove, .chatWebhookStatus, .chatImport:
            Task.detached { [self] in
                let m = await chatRequest(req)
                conn.send(m)
                finished(conn)
            }
        case .agentRelay:
            // 771: only the chat server this daemon supervises relays an agent's call (its peer pid is the child's); any other
            // caller of the owner's socket is refused before anything is read (AgentRelay.swift: the trust argument).
            let peer = AgentRelayTrust.peerPID(conn.fd)
            Task.detached { [self] in
                let child = await chat.childPID()
                guard AgentRelayTrust.accepts(peer: peer, chatServer: child) else {
                    conn.send(.failure(HostError(.notPermitted, "agent-relay is the chat server's own: only the chat server this daemon runs relays an agent's call")))
                    finished(conn)
                    return
                }
                let answer = await core.agentRelay(req.agentRelay)
                conn.send((try? JSONValue(encoding: answer)).map { HostMessage.success($0) } ?? .failure(HostError(.failed, "agent-relay")))
                finished(conn)
            }
        case .hostStop:
            // 594 W18: the web UI reads why the last host exited from this log (`HostExitReason`).
            HostLog.line("daemon stop requested: hibernating every sandbox, then exiting")
            Task.detached { [self] in await self.shutdown(prepare: true, reply: conn) }
        case .ping:
            Task.detached { [self] in
                var st = await core.status(connections: connectionCount, idleSeconds: idleSeconds,
                                           idleTimeoutMinutes: effectiveIdleTimeoutMinutes, startedAt: startedAt,
                                           alwaysOn: alwaysOn, keepers: keepers)
                // 694: what replacing this daemon would cost (the login item's look at a locked daemon).
                st.fencedSessions = await core.fencedMacSessions()
                st.preparations = await core.runningPreparations()
                st.chat = await chat.status()
                conn.send((try? JSONValue(encoding: st)).map { HostMessage.success($0) } ?? .failure(HostError(.failed, "status")))
                finished(conn)
            }
        default:
            Task.detached { [self] in
                let msg = await core.handle(req) { e in conn.send(HostMessage(event: e)) }
                conn.send(msg)
                finished(conn)
            }
        }
    }

    /// The `chat-*` requests: the supervisor's. Nothing of the request is logged (a `chat-token` may carry a token).
    private func chatRequest(_ req: HostRequest) async -> HostMessage {
        let c = req.chat ?? ChatRequest()
        // A bot's name: changed through `doz bot`, never `doz chat` (a retired one is never taken again).
        let bots = BotStore(store: store).readOrEmpty()
        // A bot's role is the owner's to give in chat (doz chat set BOT --role decider): only how it is reached is doz bot's.
        let roleOnly = req.op == .chatSet && c.roles != nil && c.deliver == nil && c.kind == nil && c.entry == nil && c.session == nil
        if let refused = BotGuards.chatRefusal(req.op, name: c.name, bots: bots, roleOnly: roleOnly) { return .failure(refused) }
        // A batch: every name judged as its own add or remove would be, before anything is changed.
        for a in c.add ?? [] { if let refused = BotGuards.chatRefusal(.chatAdd, name: a.name, bots: bots) { return .failure(refused) } }
        for n in c.remove ?? [] { if let refused = BotGuards.chatRefusal(.chatRemove, name: n, bots: bots) { return .failure(refused) } }
        do {
            switch req.op {
            case .chatMembers:
                let made = try await chat.members(add: c.add ?? [], remove: c.remove ?? [])
                // The running server took it (or restarted to): answered once it is ready again (or stopped), at most 15 s.
                _ = try await chat.sync(human: nil, retry: false, waitReady: true, blocked: await chatBlocked())
                return .success(try JSONValue(encoding: ChatMembersAnswer(added: made.map { .init(name: $0.name, token: $0.token) },
                                                                          removed: c.remove ?? [], chat: await chat.status())))
            case .chatSync:
                let st = try await chat.sync(human: c.name, retry: c.retry ?? false, waitReady: c.wait ?? false, blocked: await chatBlocked())
                return .success(try JSONValue(encoding: st))
            case .chatAdd, .chatToken:
                guard let n = c.name else { throw HostError(.invalid, "which participant?") }
                let token = req.op == .chatAdd
                    ? try await chat.add(n, token: c.token, kind: c.kind ?? "agent", webhook: c.webhook ?? false, entry: c.entry,
                                         inbox: c.inbox ?? false, session: c.session)
                    : try await chat.replaceToken(n, token: c.token)
                // 771: an adopted agent's new token goes into its own item (its sessions from now on carry it).
                if req.op == .chatToken { await core.adoptedTokenReplaced(n, token: token) }
                // 776: a workspace worker's token you took: yours from now on (never rotated or revoked by Dozable).
                if req.op == .chatToken { await core.workerTokenTaken(n) }
                // The server restarted to take it: answered once it is ready again (or stopped), at most 15 s.
                _ = try await chat.sync(human: nil, retry: false, waitReady: true, blocked: await chatBlocked())
                // A token the person gave is not sent back: they have it.
                return .success(try JSONValue(encoding: ChatAnswer(name: n, token: c.token == nil ? token : nil, chat: await chat.status())))
            case .chatSet:
                guard let n = c.name, c.deliver != nil || c.roles != nil else { throw HostError(.invalid, "which participant, and how is it reached or its role?") }
                let p = try await chat.set(n, deliver: c.deliver, kind: c.kind, entry: c.entry, session: c.session, roles: c.roles)
                // The server restarted to take it: answered once it is ready again (or stopped), at most 15 s.
                _ = try await chat.sync(human: nil, retry: false, waitReady: true, blocked: await chatBlocked())
                return .success(try JSONValue(encoding: ChatSetAnswer(name: n, kind: p.kind, delivery: p.delivery, webhookEntry: p.webhookEntry,
                                                                      session: p.inboxSession, roles: p.roles, chat: await chat.status())))
            case .chatRemove:
                guard let n = c.name else { throw HostError(.invalid, "which participant?") }
                try await chat.remove(n)
                _ = try await chat.sync(human: nil, retry: false, waitReady: true, blocked: await chatBlocked())
                return .success(try JSONValue(encoding: ChatAnswer(name: n, token: nil, chat: await chat.status())))
            case .chatWebhookSet:
                guard let e = c.entry, let url = c.url else { throw HostError(.invalid, "which entry, and its address?") }
                let info = try await chat.setWebhook(e, url: url, authorization: c.authorization ?? "")
                // The server restarted to take it: answered once it is ready again (or stopped), at most 15 s.
                _ = try await chat.sync(human: nil, retry: false, waitReady: true, blocked: await chatBlocked())
                return .success(try JSONValue(encoding: [info]))
            case .chatWebhookRemove:
                guard let e = c.entry else { throw HostError(.invalid, "which entry?") }
                let info = try await chat.removeWebhook(e)
                _ = try await chat.sync(human: nil, retry: false, waitReady: true, blocked: await chatBlocked())
                return .success(try JSONValue(encoding: [info]))
            case .chatWebhookStatus:
                return .success(try JSONValue(encoding: try await chat.webhookStatus(c.entry)))
            case .chatImport:
                guard let p = c.path, p.hasPrefix("/") else { throw HostError(.invalid, "which copy (an absolute path)?") }
                return .success(try JSONValue(encoding: try await chat.importCopy(p, addMissing: c.addMissing ?? false, replace: c.replace ?? false)))
            default:
                throw HostError(.invalid, "not a chat request")
            }
        } catch {
            return .failure(HostError.from(error))
        }
    }

    /// 617: doz get / put — the check and its answer (`CopyReady`, after any wake/start events), then `CopyFrame`s on this
    /// connection: get relays the guest tar's stdout as `D` frames; put feeds the client's `D` frames to the guest tar's
    /// stdin until `F`. Both end with `E` (`CopyDone`). This runs on the connection's own thread, which may block.
    private func copy(_ conn: HostConnection, reader: LineReader, request req: HostRequest) {
        let opened = DispatchSemaphore(value: 0)
        let box = CopyBox()
        Task.detached { [core] in
            do { box.result = .success(try await core.copyOpen(req) { e in conn.send(HostMessage(event: e)) }) } catch { box.result = .failure(error) }
            opened.signal()
        }
        opened.wait()
        guard case .success(let (ready, stream))? = box.result else {
            if case .failure(let e)? = box.result { conn.send(.failure(HostError.from(e))) }
            finished(conn)
            return
        }
        guard let answer = try? JSONValue(encoding: ready), conn.send(.success(answer)) else { stream.finishInput(); finished(conn); return }
        let t0 = ContinuousClock.now
        let direction = req.fileCopy?.direction ?? .get
        let done = DispatchSemaphore(value: 0)
        let counted = ByteCount()
        switch direction {
        case .get:
            Task.detached {
                for await d in stream.output {
                    counted.add(d.count)
                    var at = 0
                    while at < d.count {
                        let end = min(at + CopyFrame.maximumPayload, d.count)
                        if !conn.write(CopyFrame.encode(CopyFrame.data, d.subdata(in: at..<end))) { break }
                        at = end
                    }
                }
                done.signal()
            }
            done.wait()
        case .put:
            Task.detached { for await _ in stream.output {}; done.signal() }    // put's tar prints nothing; this ends with it
            let parser = CopyFrame.Parser()
            var buf = [UInt8](repeating: 0, count: 65536)
            var finishedInput = false
            if !reader.buffer.isEmpty { _ = reader.takeRemainder() }            // nothing is sent before the answer
            reading: while !finishedInput {
                let n = read(conn.fd, &buf, buf.count)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { break }
                guard let frames = try? parser.feed(Data(buf[0..<n])) else { break }
                for f in frames {
                    if f.type == CopyFrame.data { counted.add(f.payload.count); stream.send(f.payload) }
                    else if f.type == CopyFrame.finish { finishedInput = true; break reading }
                }
            }
            stream.finishInput()
            if !finishedInput { HostLog.line("\(req.name ?? "?"): a copy into it was cut off by the client") }
            done.wait()
        }
        // The exit code is set before the output ends (GuestStream.ended).
        let end = HostCore.copyDone(stream, bytes: counted.value, since: t0, direction: direction)
        if let d = try? HostWire.encoder.encode(end) { _ = conn.write(CopyFrame.encode(CopyFrame.end, d)) }
        HostLog.line("\(req.name ?? "?"): \(direction.rawValue) \(ready.path) — \(end.ok ? "copied" : "FAILED: \(end.error ?? "")") (\(counted.value) bytes)")
        finished(conn)
    }

    /// Stream messages until the client hangs up.
    private func stream<S: AsyncSequence & Sendable>(_ conn: HostConnection, reader: LineReader,
                                                     _ make: @escaping @Sendable () -> S) where S.Element == HostMessage {
        let task = Task.detached {
            do { for try await m in make() { if !conn.send(m) { break } } } catch {}
        }
        watchHangup(conn, reader: reader) { task.cancel() }
    }

    /// Blocks this connection's thread until the peer closes (or shutdownIO), then cleans up.
    private func watchHangup(_ conn: HostConnection, reader: LineReader, _ onHangup: () -> Void) {
        var buf = [UInt8](repeating: 0, count: 1024)
        while true {
            let n = read(conn.fd, &buf, buf.count)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break }
        }
        onHangup()
        finished(conn)
    }

    private func netLogFollow(_ conn: HostConnection, reader: LineReader, request req: HostRequest) {
        Task.detached { [core] in
            do {
                let (log, name) = try await core.connectionLog(req.name, session: req.session)
                let denied = req.deniedOnly == true
                let live = log.stream()
                for r in log.records where !denied || r.verdict == .denied {
                    conn.send(HostMessage(event: HostEvent(kind: .connection, sandbox: name, connection: r, time: r.time)))
                }
                for await r in live where !r.open && (!denied || r.verdict == .denied) {
                    if !conn.send(HostMessage(event: HostEvent(kind: .connection, sandbox: name, connection: r, time: r.time))) { break }
                }
            } catch {
                conn.send(.failure(HostError.from(error)))
                conn.shutdownIO()
            }
        }
        watchHangup(conn, reader: reader) {}
    }

    /// 767 `doz workspace journal W --follow`: the follow's lines (hello first), read from the store at the follower's own
    /// pace on a thread of its own (never the cooperative pool — a follow lasts as long as its reader), until the reader
    /// goes, the run finishes under `--until-finish`, or the daemon stops (`end`). An unknown cursor is the one failure.
    private func journalFollow(_ conn: HostConnection, reader: LineReader, request req: HostRequest) {
        let gone = FollowFlag()
        let core = self.core
        Thread.detachNewThread {
            do {
                let f = try core.journalFollower(req)
                f.run(send: { conn.send(HostMessage(result: $0)) }, cancelled: { gone.isSet })
            } catch {
                conn.send(.failure(HostError.from(error)))
            }
            conn.shutdownIO()
        }
        watchHangup(conn, reader: reader) { gone.set() }
    }

    /// 591 `console --follow`: the boot console's lines (its newest 256 KiB first), then each new
    /// line as it is written — across a cold boot's recreated log — until the client hangs up.
    private func consoleFollow(_ conn: HostConnection, reader: LineReader, request req: HostRequest) {
        let task = Task.detached { [core] in
            do {
                let (url, name) = try await core.bootLogURL(req.name)
                var tail = BootConsoleTail(url: url)
                while !Task.isCancelled {
                    for line in tail.poll() {
                        if !conn.send(HostMessage(event: HostEvent(kind: .console, sandbox: name, text: line))) { return }
                    }
                    try? await Task.sleep(for: .milliseconds(200))
                }
            } catch {
                conn.send(.failure(HostError.from(error)))
                conn.shutdownIO()
            }
        }
        watchHangup(conn, reader: reader) { task.cancel() }
    }

    // MARK: attach relay

    /// One attached (or held) terminal. Identity is this object — never its fd.
    final class AttachState: @unchecked Sendable {
        private let lock = NSLock()
        private var _size: TermSize
        private var _session: SessionConnection?
        private var _key: String?
        private var _gone = false
        init(size: TermSize) { _size = size }
        var size: TermSize { lock.withLock { _size } }
        var gone: Bool { lock.withLock { _gone } }
        var session: SessionConnection? { lock.withLock { _session } }
        /// 609: "sandbox|session" once attached (the size registry's key).
        var key: String? { lock.withLock { _key } }
        func setSize(_ s: TermSize) -> SessionConnection? { lock.withLock { _size = s; return _session } }
        /// False when the client left meanwhile.
        func adopt(_ c: SessionConnection, key: String) -> Bool {
            lock.withLock { if _gone { return false }; _session = c; _key = key; return true }
        }
        func release(_ c: SessionConnection) { lock.withLock { if _session === c { _session = nil } } }
        func markGone() -> SessionConnection? { lock.withLock { _gone = true; let s = _session; _session = nil; return s } }
    }

    /// `attach`: answer `{state: attached|held}`, then relay the terminal. A client that attaches
    /// while the sandbox is not running (and did not ask to wake it) is HELD until it runs, then
    /// attached with the size it last sent. Hibernate closes the connection (the guest session
    /// survives; the client reconnects and is held); the end of the session sends the notice.
    private func attach(_ conn: HostConnection, reader: LineReader, request req: HostRequest) {
        let state = AttachState(size: TermSize(cols: req.cols ?? 80, rows: req.rows ?? 24))
        let core = self.core
        let t0 = ContinuousClock.now
        Task.detached {
            // A session on this Mac: no sandbox, no phase, never held — its holder answers, or it is not there.
            if MacPlace.isPlace(req.name) {
                await Self.attachMac(conn, state: state, core: core, request: req)
                return
            }
            let sandbox: Sandbox, session: String
            do {
                (sandbox, session) = try await core.sandboxForAttach(req.name, session: req.session, wake: req.wake ?? true)
            } catch {
                conn.send(.failure(await core.explain(error)))
                conn.shutdownIO()
                return
            }
            let name = sandbox.spec.name
            // 594 (W17): the client's detach line names the shortest command that reattaches.
            let defaultSession: JSONValue = (await core.defaultSessionName(name)).map { .string($0) } ?? .null
            // 599 (594.B4): the terminal title's {image}.
            let imageName: JSONValue = (await core.imageName(of: name)).map { .string($0) } ?? .null
            var announced = false
            var opened = false
            while !state.gone {
                guard let phase = await core.phase(of: name) else {
                    if announced { conn.write(ClientWire.endedNotice(.stopped, text: "\(name) was removed")) }
                    else { conn.send(.failure(HostError(.notFound, "no sandbox \(name)"))) }
                    conn.shutdownIO()
                    return
                }
                let busy = await core.busy(name)
                if phase == .running && !busy {
                    if !announced {
                        // The first attach checks the session is there (a later one gets `ended` from deckhold).
                        var list = (try? await sandbox.sessions()) ?? []
                        // 617 (owner: `doz create … --start` then `doz attach NAME` hung): with NO session named, the
                        // image's own session is opened when it is not running (as `doz up` and `doz new` do), then
                        // attached — never a "no session" for the session the person did not name. Only for a client
                        // that asks (`openDefault`: `doz attach`) — the dashboard's panes never open one by arriving.
                        if req.session == nil, req.openDefault == true, !opened, !list.contains(where: { $0.name == session && !$0.isEnded }) {
                            var o = HostRequest(.openSession, name: name)
                            o.wake = false
                            o.cols = req.cols
                            o.rows = req.rows
                            let m = await core.handle(o)
                            guard m.ok == true else {
                                conn.send(.failure(m.error ?? HostError(.failed, "could not open \(name)'s session \(session)")))
                                conn.shutdownIO()
                                return
                            }
                            opened = true
                            list = (try? await sandbox.sessions()) ?? []
                        }
                        if let s = list.first(where: { $0.name == session }), s.isEnded {
                            conn.send(.failure(HostError(.notFound, "session \(session) in \(name) has ended (exit \(s.exitCode.map(String.init) ?? "?"))")))
                            conn.shutdownIO()
                            return
                        } else if !list.contains(where: { $0.name == session }) {
                            let live = list.filter { !$0.isEnded }.map(\.name)
                            conn.send(.failure(HostError(.notFound, "no session \(session) in \(name)" + (live.isEmpty ? "" : " — sessions: \(live.joined(separator: ", "))"))))
                            conn.shutdownIO()
                            return
                        }
                    }
                    do {
                        let c = try await sandbox.attach(session, size: state.size)
                        // Adopted BEFORE the answer: the client sends what it typed ahead as soon as it reads it.
                        guard state.adopt(c, key: name + "|" + session) else { c.close(); return }
                        // 609: its HELLO sized the session (a watcher's 0×0 keeps the size — it never owns it).
                        if state.size.cols > 0, state.size.rows > 0 { core.sizeOwners.claim(name + "|" + session, ObjectIdentifier(state)) }
                        if !announced {
                            conn.send(.success(.object(["state": .string("attached"), "session": .string(session), "sandbox": .string(name),
                                                        "defaultSession": defaultSession, "image": imageName, "opened": .bool(opened)])))
                            announced = true
                        }
                        await core.sessionAttached(name, session: session, ms: ms(since: t0))
                        await Self.pump(c, to: conn, state: state, core: core, sandbox: name, session: session)
                        return
                    } catch {
                        let nowPhase = await core.phase(of: name)
                        let nowBusy = await core.busy(name)
                        if nowPhase == .running && !nowBusy {
                            if !announced { conn.send(.failure(HostError.from(error))) }
                            conn.shutdownIO()
                            return
                        }
                        continue                                  // it went to sleep under us: hold
                    }
                }
                switch phase {
                case .off, .failed:
                    if announced { conn.write(ClientWire.endedNotice(.stopped, text: "\(name) is \(PhaseName.label(phase)) — the session is gone")) }
                    else { conn.send(.failure(HostError(.invalidPhase, "\(name) is \(PhaseName.label(phase)) — `doz start \(name)` boots it"))) }
                    conn.shutdownIO()
                    return
                default:
                    if !announced {
                        conn.send(.success(.object(["state": .string("held"), "session": .string(session), "sandbox": .string(name),
                                                    "defaultSession": defaultSession, "image": imageName,
                                                    "phase": .string(phase.rawValue)])))
                        announced = true
                    }
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
        }
        // Client → session, on this thread, for the life of the connection.
        var parser = ClientWire.Parser()
        func feed(_ bytes: [UInt8]) {
            for f in parser.feed(bytes) {
                switch f {
                case .hello(let s), .resize(let s):
                    let c = state.setSize(s)
                    c?.resize(s)
                    if c != nil, s.cols > 0, s.rows > 0, let key = state.key { core.sizeOwners.claim(key, ObjectIdentifier(state)) }
                case .input(let d):
                    // 609: a session has ONE size — the last viewer to send one set it. When another viewer
                    // (`doz attach` from another terminal, another pane) resized it since this one did, this
                    // viewer's keys would reach a program drawing for the OTHER size: an agent's TUI then
                    // draws past this screen's edge and leaves stale glyphs where it means blanks (the web
                    // pane's "space doesn't work"). The viewer a person types in owns the size: re-apply it.
                    let size = state.size
                    if let c = state.session, size.cols > 0, size.rows > 0, let key = state.key,
                       core.sizeOwners.takeForInput(key, ObjectIdentifier(state)) {
                        c.resize(size)
                    }
                    state.session?.send(d)       // dropped while held: nobody to type to
                case .repaint: state.session?.repaint()           // 599: a fresh snapshot (a notice or menu drawn over it)
                }
            }
        }
        let early = reader.takeRemainder()
        if !early.isEmpty { feed(Array(early)) }
        var buf = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = read(conn.fd, &buf, buf.count)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break }
            feed(Array(buf[0..<n]))
        }
        state.markGone()?.close()
        finished(conn)
    }

    /// `attach` to a session on this Mac (`@mac`): its holder's socket directly (`MacSessions.attach`), through the same
    /// pump — size owners, the end notice, OSC 52 — with the open-URL and workspace-file bridges off (`HostCore.bridge`).
    /// No session named: the one that runs, when exactly one does.
    private static func attachMac(_ conn: HostConnection, state: AttachState, core: HostCore, request req: HostRequest) async {
        let place = MacPlace.name
        func refuse(_ e: HostError) { conn.send(.failure(e)); conn.shutdownIO() }
        var named = req.session
        if named == nil {
            let live = (await core.mac.rows()).filter { !$0.ended }.map(\.name)
            guard live.count == 1 else {
                return refuse(live.isEmpty ? HostError(.notFound, "no sessions on this Mac — doz run @mac -- CMD opens one")
                                           : HostError(.invalid, "which session? doz attach @mac SESSION (\(live.joined(separator: ", ")))"))
            }
            named = live[0]
        }
        guard let session = named else { return }
        do { try MacPlace.validateSessionName(session) } catch { return refuse(HostError.from(error)) }
        switch await core.mac.state(session) {
        case .info:
            break
        case .ended(let code?):
            // 687: its program ended before this viewer came (`doz run` of a program that exits at once — the code was
            // lost: the attach was refused, exit 2). Answered as a sandbox's pipe answers an ended session: its last
            // screen (the holder's `.final`, when kept), then the end with its code — which `doz run` returns.
            conn.send(.success(.object(["state": .string("attached"), "session": .string(session), "sandbox": .string(place),
                                        "defaultSession": .null, "image": .null, "opened": .bool(false)])))
            if let last = core.mac.endedScreen(session), !last.vt.isEmpty { conn.write(last.vt) }
            conn.write(ClientWire.endedNotice(.exited(code), text: "the \(session) session has ended (exit \(code))"))
            conn.shutdownIO()
            return
        default:
            return refuse(await core.macNotRunning(session))
        }
        let c = core.mac.attach(session, size: state.size)
        // Adopted BEFORE the answer, as a sandbox's: the client sends what it typed ahead once it reads it.
        guard state.adopt(c, key: place + "|" + session) else { c.close(); return }
        if state.size.cols > 0, state.size.rows > 0 { core.sizeOwners.claim(place + "|" + session, ObjectIdentifier(state)) }
        conn.send(.success(.object(["state": .string("attached"), "session": .string(session), "sandbox": .string(place),
                                    "defaultSession": .null, "image": .null, "opened": .bool(false)])))
        await core.watchStatus(place, session: session)
        await pump(c, to: conn, state: state, core: core, sandbox: place, session: session)
    }

    /// Session → client, until the session connection ends.
    private static func pump(_ c: SessionConnection, to conn: HostConnection, state: AttachState, core: HostCore,
                             sandbox: String, session: String) async {
        // 599 (594.B1/B2): the bridges' sequences are read here, once for every kind of viewer, and removed.
        var scanner = SessionBridgeScanner()
        // 599d: this terminal hears the notices that come from elsewhere (the GitHub login, the SSH agent).
        core.bridgeState.addViewer(sandbox, conn)
        defer { core.bridgeState.removeViewer(sandbox, conn) }
        for await out in c.output {
            switch out {
            case .snapshot(let d):
                scanner.reset()                     // a replayed screen never copies or opens anything
                conn.write(d)
            case .data(let d):
                let (bytes, events) = scanner.feed(d)
                if !bytes.isEmpty { conn.write(Data(bytes)) }
                for e in events {
                    if let n = await core.bridge(e, sandbox: sandbox, session: session) { conn.write(ClientWire.notice(n)) }
                }
            case .ended(let code):
                let text = code.map { "the \(session) session has ended (exit \($0))" } ?? "there is no \(session) session in \(sandbox)"
                conn.write(ClientWire.endedNotice(code.map { .exited($0) } ?? .noSession, text: text))
                await core.sessionEnded(sandbox, session: session, exitCode: code)
                conn.shutdownIO()
            case .detached(.sandboxStopped):
                conn.write(ClientWire.endedNotice(.stopped, text: "\(sandbox) shut down — the \(session) session is gone"))
                conn.shutdownIO()
            case .detached(.sandboxSleeping), .detached(.transportLost):
                // The guest session lives on: close; the client reconnects and is held until it runs.
                conn.shutdownIO()
            case .detached(.closedByClient):
                break
            case .status:
                break                               // 612: a viewer never gets one (only a status watcher)
            }
        }
        state.release(c)
    }
}

extension HostCore {
    /// The proxy's log of a sandbox (for `net log --follow`).
    func connectionLog(_ name: String?, session: String? = nil) throws -> (ConnectionLog, String) {
        // A fenced session on this Mac: its own proxy's log (this host's, from when it began serving it).
        if MacPlace.isPlace(name) {
            guard let s = session else { throw HostError(.invalid, "which session? doz net log @mac --session SESSION") }
            guard let p = macProxies[s] else {
                throw HostError(.notFound, "this daemon does not serve a proxy for \(s) on this Mac (doz sessions @mac: only a running fenced session has one)")
            }
            return (p.proxy.log, MacPlace.name)
        }
        let m = try get(name)
        guard let log = m.sandbox.egress?.log else {
            throw HostError(.invalid, "\(m.name) is not proxied (network \(m.config.networkName)) — it has no connection log")
        }
        return (log, m.name)
    }
}

/// 617: a copy's opening, handed from its task to the connection's thread.
final class CopyBox: @unchecked Sendable {
    var result: Result<(CopyReady, GuestStream), Error>?
}

/// 617: bytes counted across threads.
final class ByteCount: @unchecked Sendable {
    private let lock = NSLock()
    private var n: Int64 = 0
    func add(_ k: Int) { lock.lock(); n += Int64(k); lock.unlock() }
    var value: Int64 { lock.lock(); defer { lock.unlock() }; return n }
}

/// 606: the ports Dozable's dashboards listen on — `doz ui`'s (`<store>/ui.port`), `doz serve`'s (`<store>/serve/port`
/// while it runs) and the setting `serve.port` (another store's doz serve) — re-read at most every 5 s.
final class DashboardPorts: @unchecked Sendable {
    let store: DozableStore
    private let lock = NSLock()
    private var cached: (at: Date, ports: Set<UInt16>) = (.distantPast, [])
    init(store: DozableStore) { self.store = store }

    @Sendable func current() -> Set<UInt16> {
        lock.lock(); defer { lock.unlock() }
        if Date().timeIntervalSince(cached.at) < 5 { return cached.ports }
        var p = Set<UInt16>()
        for f in [store.root.appendingPathComponent("ui.port"), store.root.appendingPathComponent("serve/port")] {
            if let s = try? String(contentsOf: f, encoding: .utf8), let n = UInt16(s.trimmingCharacters(in: .whitespacesAndNewlines)), n > 0 { p.insert(n) }
        }
        let sp = DozableSettings.load().int(SettingKey.servePort)
        if (1...65_535).contains(sp) { p.insert(UInt16(sp)) }
        cached = (Date(), p)
        return p
    }
}

/// The bots' way to the chat server's participants: the supervisor's own add / set / token / remove, each followed by the
/// wait for the restarted server (ready again, or stopped — at most 15 s), as `doz chat` does.
struct SupervisorBotChat: BotChat {
    let supervisor: ChatSupervisor
    let blocked: @Sendable () async -> Bool

    func directory() throws -> ChatDirectory { try ChatDirectory.load(supervisor.paths) }
    func enabled() -> Bool { ChatSettingsView.read().enabled }

    func add(_ name: String, token: String, kind: String, deliver: String, entry: String?, session: String?) async throws {
        _ = try await supervisor.add(name, token: token, kind: kind, webhook: deliver == "webhook", entry: deliver == "webhook" ? entry : nil,
                                     inbox: deliver == "inbox", session: deliver == "inbox" ? session : nil)
        await settle()
    }

    func set(_ name: String, deliver: String, entry: String?, session: String?) async throws {
        _ = try await supervisor.set(name, deliver: deliver, entry: entry, session: session)
        await settle()
    }

    func replaceToken(_ name: String, token: String) async throws {
        _ = try await supervisor.replaceToken(name, token: token)
        await settle()
    }

    func remove(_ name: String) async throws {
        try await supervisor.remove(name)
        await settle()
    }

    private func settle() async { _ = try? await supervisor.sync(human: nil, retry: false, waitReady: true, blocked: await blocked()) }
}

/// A flag one thread sets and another reads (767: a follow's reader went).
final class FollowFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}
