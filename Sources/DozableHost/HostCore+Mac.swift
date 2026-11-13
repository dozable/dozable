import DozableKit
import Foundation

/// `@mac` in the host: every session operation on THIS Mac, answered by `MacSessions` — never through `Managed` or
/// `Sandbox`. The status watchers, statuses and `session-status` events are the sandboxes' own (`HostCore+Status`, keyed
/// by the place name `@mac`); the attach relay is `HostServer.attachMac`.
extension HostCore {
    /// An operation on `@mac` (`perform` routes every request naming it here first).
    func performMac(_ r: HostRequest) async throws -> JSONValue {
        guard MacPlace.operations.contains(r.op) else { throw MacPlace.refusal(r.op.rawValue) }
        if buildFlavor.isHelper { throw HostError(.notImplemented, BuildFlavor.helperLeavesOut("sessions on this Mac")) }
        switch r.op {
        case .sessions:
            return try JSONValue(encoding: await macRows())
        case .openSession:
            return try JSONValue(encoding: try await macOpen(r))
        case .sessionLive:
            return try JSONValue(encoding: try await macLive(r))
        case .sessionScreen:
            let s = try macSession(r, "doz sessions @mac --screen SESSION")
            guard let saved = mac.savedScreen(s) else {
                throw HostError(.notFound, "no saved screen of \(s) on this Mac — screens are saved every few minutes while it runs, and when the host stops")
            }
            return try JSONValue(encoding: SessionScreen(name: MacPlace.name, saved))
        case .sessionSend:
            return try JSONValue(encoding: try await macSend(r))
        case .sessionEnd:
            return try JSONValue(encoding: try await macEnd(r))
        case .sessionRestart:
            return try JSONValue(encoding: try await macRestart(r))
        case .sessionWait:
            return try JSONValue(encoding: try await sessionWait(r))
        case .sessionResume:
            return try JSONValue(encoding: try await macResume(r))
        case .sessionQuarantine:
            return try JSONValue(encoding: try macQuarantine(r))
        case .netPermissions, .netPolicy, .netLog:
            return try await macNet(r)
        case .sessionBridges:
            return try JSONValue(encoding: try await macBridges(r))
        case .sessionTranscripts:
            return try JSONValue(encoding: try macTranscriptsList(r))
        default:
            throw MacPlace.refusal(r.op.rawValue)
        }
    }

    private func macSession(_ r: HostRequest, _ usage: String) throws -> String {
        guard let s = r.session else { throw HostError(.invalid, "which session? \(usage)") }
        try MacPlace.validateSessionName(s)
        return s
    }

    /// The host start (and every listing from a host): live holders are watched; stale sockets removed.
    public func adoptMacSessions() async {
        guard !readOnly else { return }
        let live = await mac.adopt()
        if !live.isEmpty { note(MacPlace.name, "\(live.count) session\(live.count == 1 ? "" : "s") on this Mac adopted (\(live.joined(separator: ", ")))") }
        for s in live { await watchStatus(MacPlace.name, session: s) }
        // A fenced one's git guard again: its stored baseline, a full check (what changed while no host ran is dealt
        // with now — stripped and stopped), then the watch.
        let recs = mac.records().sessions
        // A fenced one's proxy: the socket its holder holds (connections made while no host ran wait in its backlog).
        for s in live { if let f = recs[s]?.fence { adoptFenceProxy(s, f) } }
        for s in live where macFenceWatches[s] == nil {
            guard let rec = recs[s], let f = rec.fence else { continue }
            let w = makeFenceWatch(s, workdir: rec.workdir, roots: [rec.workdir] + f.writable, sentinel: f.sentinel, anti: f.antiSentinel)
            w.pid = rec.pid.map { pid_t($0) }
            macFenceWatches[s] = w
            let found = w.guardian.adopt()          // the baseline, the watch, then a full check
            if !found.isEmpty { note(MacPlace.name, "session \(s) on this Mac: its git config changed while no host ran — dealt with now") }
        }
        // 683: a fenced one that ended (or is gone) while no host ran: its conversations carried back now (once).
        for (s, rec) in recs where rec.fence?.agentConfig == MacAgentConfig.privateMode && !live.contains(s) {
            if let t = await macCarryBack(s) { note(MacPlace.name, "session \(s) on this Mac ended: \(t)") }
        }
    }

    // MARK: 683 — the agent's conversations, its login, its bridges

    /// Carry a PRIVATE fenced session's conversations back into the person's own folder (and, under `keep`, Dozable's
    /// archive) — at its end, when it is forgotten, and when the host first sees its program ended or gone. Idempotent
    /// (each file's sha256 is recorded). Returns the end message (nil: nothing to say).
    func macCarryBack(_ s: String) async -> String? {
        guard !readOnly, let rec = mac.records().sessions[s], let f = rec.fence, f.agentConfig == MacAgentConfig.privateMode,
              let id = f.agent, let r = AgentRecipes.macAgent(program: id), let m = r.launch.macConfig, let home = mac.fenceHome() else { return nil }
        let setup = MacAgentSetup(recipe: r.id, title: r.title, config: m, mode: MacAgentConfig.privateMode, modeSource: f.agentConfigSource ?? "",
                                  history: f.history ?? AgentHistory.keep, historySource: f.historySource ?? "", agentDefault: r.launch.history?.agentDefault,
                                  historyMap: r.launch.history, personHome: home + "/" + m.homeName, personBeside: nil, agentDir: f.sessionFolder + "/agent")
        let archive = setup.history == AgentHistory.keep
            ? (MacFencePaths.resolve(mac.folder.path) ?? mac.folder.path) + "/transcripts/" + s + "/" + MacTranscripts.stamp(Date()) : nil
        let o = MacTranscripts.carryBack(agentDir: setup.agentDir, personHome: setup.personHome, folder: setup.transcriptsFolder(workdir: rec.workdir),
                                         workdir: rec.workdir, tag: f.tag, archive: archive, already: Set(f.carried ?? []))
        if Set(o.done) != Set(f.carried ?? []) { await mac.updateRecord(s) { $0.fence?.carried = Array(Set(o.done)).sorted() } }
        if !o.carried.isEmpty || !o.renamed.isEmpty || !o.skipped.isEmpty || o.refused != nil {
            HostLog.line("\(MacPlace.name): session \(s): conversations carried back \(o.carried.count + o.renamed.count), archived \(o.archived.count), skipped \(o.skipped.count)")
        }
        return MacTranscripts.message(o, setup: setup, session: s)
    }

    /// The Claude login of a fenced session: the account asked (else `mac.account`) and a fresh placeholder for its variable
    /// (`CLAUDE_CODE_OAUTH_TOKEN` for this Mac's login or a setup token, `ANTHROPIC_API_KEY` for an API key) — the proxy
    /// swaps it for the real one, which stays in the vault on this Mac. `none`: no login, no placeholder.
    func fenceAccount(_ asked: String?, settings: DozableSettings) throws -> (account: String, placeholders: [String: String]) {
        let name = asked ?? settings.string(SettingKey.macAccount) ?? "mac"
        if name == "none" { return ("none", [:]) }
        let file = accountStore.load()
        let a: AccountRecord
        if let found = file.accounts.first(where: { $0.name == name }) { a = found } else if name == "mac" { a = .mac } else {
            throw HostError(.notFound, "--account \(name): no such account (doz account ls) — or --account mac, or none")
        }
        let variable: String
        switch a.kind {
        case .mac, .setupToken: variable = CredentialBinding.claudeOAuth.environmentVariable ?? "CLAUDE_CODE_OAUTH_TOKEN"
        case .apiKey: variable = CredentialBinding.anthropic.environmentVariable ?? "ANTHROPIC_API_KEY"
        default:
            throw HostError(.invalid, "--account \(name): a \(a.kind.rawValue) account cannot sign Claude Code in — this Mac's login (mac), a setup token or an Anthropic API key")
        }
        let token = CredentialVault.placeholderPrefix + (0..<24).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        return (name, [variable: token])
    }

    /// Bind a fenced session's Claude login into its proxy's vault (at open, and at adoption): its placeholders honoured,
    /// the account's credential bound by the ONE account wiring (`bindAnthropicAccount`), a foreign credential the program
    /// sends refused (never anything injected beside it), no fallback to another account.
    func bindFenceAccount(_ s: String, _ p: MacFenceProxy, _ f: MacFenceRecord) {
        guard let name = f.account, name != "none" else { return }
        let vault = p.proxy.vault
        let file = accountStore.load()
        let a = file.accounts.first { $0.name == name } ?? (name == "mac" ? AccountRecord.mac : nil)
        vault.foreignPolicy = .strict
        let who = "@mac \(s)"
        vault.strictNotice = "\(who) signs in as the account \(name) through Dozable's proxy. It refused this request's own credential (fp {fp}) — "
            + "a /login or a key inside the session. Remove it (unset CLAUDE_CODE_OAUTH_TOKEN / ANTHROPIC_API_KEY overrides), or start it with another --account"
        vault.noSecretNotice = "\(who) has no Claude login behind its placeholder now — doz run @mac --account NAME (doz account ls)"
        vault.setFingerprintLabels(Dictionary(file.accounts.compactMap { a in a.fingerprint.map { ($0, a.name) } }) { a, _ in a })
        guard let a else {
            p.setCredential(.claudeOAuth, secret: nil, expiresAt: nil, environment: [:], notice: "the account \(name) this session uses no longer exists — doz run @mac --account NAME")
            vault.restorePlaceholderHashes(f.placeholderHashes ?? [:])
            return
        }
        // The other binding of the two stays bound and EMPTY (as a sandbox's): its header still counts as "the program's
        // own credential is present" — removed, an x-api-key of the program's would get our bearer injected beside it.
        let other: CredentialBinding = a.kind == .apiKey ? .claudeOAuth : .anthropic
        p.setCredential(other, secret: nil, expiresAt: nil, environment: [:], notice: nil)
        bindAnthropicAccount(a, target: p, name: "\(MacPlace.name) \(s)", file: file)
        vault.restorePlaceholderHashes(f.placeholderHashes ?? [:])
        HostLog.line("\(MacPlace.name): session \(s): its Claude login is the account \(name) (\(a.kind.rawValue)) through its proxy"
                     + (vault.hasSecret(a.kind.binding.id) ? "" : " — no credential behind it now"))
    }

    /// A fenced session's login stops following its account (its proxy is gone).
    func unbindFenceAccount(_ s: String) {
        let n = "\(MacPlace.name) \(s)"
        for (k, w) in watchers where w.subscriberNames.contains(n) {
            w.unsubscribe(n)
            if w.isEmpty { w.stop(); watchers[k] = nil }
        }
    }

    /// `doz sessions bridges @mac S [--open-url on|off] [--open-files on|off] [--clipboard write|off]`: a fenced session's
    /// bridges, changed live (the next event follows them).
    func macBridges(_ r: HostRequest) async throws -> SessionBridges {
        let s = try macSession(r, "doz sessions bridges @mac SESSION")
        guard let f = mac.records().sessions[s]?.fence else {
            throw HostError(.notFound, "no fenced session \(s) on this Mac — an unfenced session opens things itself (doz sessions @mac)")
        }
        var b = f.bridges ?? MacFenceBridges(openURL: false, openFiles: false, clipboard: false)
        guard let want = r.macBridges, want.openURL != nil || want.openFiles != nil || want.clipboard != nil else {
            return SessionBridges(session: s, bridges: b, changed: nil)
        }
        guard !readOnly else { throw HostError(.unavailable, "session-bridges needs the host") }
        if let v = want.openURL { b.openURL = v }
        if let v = want.openFiles { b.openFiles = v }
        if let v = want.clipboard { b.clipboard = v }
        let now = b
        await mac.updateRecord(s) { $0.fence?.bridges = now }
        let words = "open URL \(b.openURL ? "on" : "off"), open files \(b.openFiles ? "on" : "off"), clipboard \(b.clipboard ? "write" : "off")"
        note(MacPlace.name, "session \(s) on this Mac: bridges \(words) — from the next one")
        return SessionBridges(session: s, bridges: b, changed: words)
    }

    /// `doz sessions @mac --transcripts S`: its archived conversations (newest first).
    func macTranscriptsList(_ r: HostRequest) throws -> MacTranscripts.Listing {
        let s = try macSession(r, "doz sessions @mac --transcripts SESSION")
        let root = (MacFencePaths.resolve(mac.folder.path) ?? mac.folder.path) + "/transcripts/" + s
        let items = MacTranscripts.list(root)
        let rec = mac.records().sessions[s]
        if items.isEmpty, rec?.fence == nil, MacFenceHostFS.kind(root) == nil {
            throw HostError(.notFound, "no fenced session \(s) on this Mac, and no conversations of it kept (doz sessions @mac)")
        }
        var to: String?
        if let f = rec?.fence, let id = f.agent, let m = AgentRecipes.macAgent(program: id)?.launch.macConfig, let home = mac.fenceHome() {
            to = home + "/" + m.homeName + "/" + m.transcripts.folder(workdir: rec!.workdir)
        }
        return MacTranscripts.Listing(session: s, items: items, carriedTo: to)
    }

    /// A fenced session's git guard, its stop wired to every process of the fence.
    func makeFenceWatch(_ s: String, workdir: String, roots: [String], sentinel: String, anti: String) -> MacFenceWatch {
        let w = MacFenceWatch(sentinel: sentinel, anti: anti)
        w.guardian = MacFenceGitGuard(session: s, workdir: workdir, roots: roots, stateFolder: mac.fenceState(s), quarantine: mac.quarantine(s),
                                      stop: { [w] in w.stopNow() },
                                      report: { [weak self, w] v in Task { await self?.macFenceViolated(s, v, pids: w.stopped) } })
        return w
    }

    /// The git guard found a violation and stopped the session: recorded, said.
    func macFenceViolated(_ s: String, _ v: MacFenceGitViolation, pids: [Int]) async {
        let why = v.what.prefix(4).joined(separator: "; ")
        await mac.updateRecord(s) { rec in
            guard var f = rec.fence else { return }
            f.stoppedForGit = why
            f.stoppedPids = Array(Set((f.stoppedPids ?? []) + pids)).sorted()
            rec.fence = f
        }
        note(MacPlace.name, "session \(s) on this Mac STOPPED: a git config change a fenced session may not make (\(why)) in \(DisplayPath.tilde(v.path)) — "
             + "taken out and kept aside (doz sessions @mac --quarantine \(s)); doz sessions resume @mac \(s) continues it")
        metrics?.record(run: metricsRun, action: "mac session stopped (git)", sandbox: MacPlace.name, image: "", startedAt: Date(), durationMs: 0,
                        detail: ["session": s, "processes": String(pids.count)])
    }

    /// The fenced sessions this host keeps up (their git guard and proxy need a host).
    public func fencedMacSessions() async -> [String] {
        for s in Set(macFenceWatches.keys).union(macProxies.keys).sorted() where !(await mac.isRunning(s)) {
            dropFenceWatch(s)
            dropFenceProxy(s)
            macDenials.unwatch(session: s)
            // 683: its program ended by itself (or is gone): its conversations go back now.
            if let t = await macCarryBack(s) { note(MacPlace.name, "session \(s) on this Mac ended: \(t)") }
        }
        return Set(macFenceWatches.keys).union(macProxies.keys).sorted()
    }

    func dropFenceWatch(_ s: String) {
        macFenceWatches[s]?.guardian.cancel()
        macFenceWatches[s] = nil
    }

    /// A proxy made off the open's path takes its place (one already there — a restart raced it — is stopped first).
    func installProxy(_ s: String, _ p: MacFenceProxy) {
        // Only the session's CURRENT socket (a restart in the meantime made a new one).
        guard let f = mac.records().sessions[s]?.fence, f.proxyPort == Int(p.port) else { p.stop(); return }
        macProxies[s]?.stop()
        unbindFenceAccount(s)
        bindFenceAccount(s, p, f)
        p.start()
        macProxies[s] = p
    }

    /// This host stops serving session `s`'s proxy (its holder keeps the socket while it lives).
    func dropFenceProxy(_ s: String) {
        macProxies[s]?.stop()
        macProxies[s] = nil
        unbindFenceAccount(s)
    }

    /// A hand-over (this host's program was replaced and only fenced sessions keep it up): every proxy stops accepting —
    /// new connections wait in the holders' backlogs for the next host — the idle ones are closed and the open tunnels
    /// get up to `timeout` seconds to finish. Returns how many were cut.
    public func drainMacProxies(timeout: Double) async -> Int {
        let all = Array(macProxies.values)
        macProxies = [:]
        let cut = await withTaskGroup(of: Int.self) { g in
            for p in all { g.addTask { await Task.detached { p.listener.drain(timeout: timeout) }.value } }
            return await g.reduce(0, +)
        }
        return cut
    }

    /// A fenced session's proxy from its holder (`GETFD`) — at adoption: the record's policy and password hash, the CA
    /// in the store. Nothing when the record has no proxy (an older one) or the holder holds nothing.
    func adoptFenceProxy(_ s: String, _ f: MacFenceRecord) {
        guard macProxies[s] == nil, let port = f.proxyPort, let secret = f.proxySecretSHA256 else { return }
        guard let fd = DeckholdSocket.heldSocket(path: mac.socket(s)) else {
            HostLog.line("\(MacPlace.name): session \(s): its holder handed no proxy socket — its network waits")
            return
        }
        guard MacFenceNetwork.port(of: fd) == UInt16(port) else {
            close(fd)
            HostLog.line("\(MacPlace.name): session \(s): its holder's socket is not its recorded port \(port) — not served")
            return
        }
        let ca = try? SandboxCA.loadOrCreate(in: URL(fileURLWithPath: mac.fenceState(s)), sandbox: "mac-\(s)")
        do {
            let p = try MacFenceProxy(session: s, fd: fd, port: UInt16(port), policy: f.policy ?? .permissions(["model"], preset: "locked"),
                                      secretSHA256: secret, ca: ca, environment: mac.hostEnvironment)
            bindFenceAccount(s, p, f)
            p.start()
            macProxies[s] = p
        } catch {
            close(fd)
            HostLog.line("\(MacPlace.name): session \(s): its proxy did not start (\(error))")
        }
        macDenials.watch(session: s, tag: f.tag)
    }

    // MARK: the network of a fenced session (`doz net … @mac --session S`)

    /// `net-permissions`, `net-policy`, `net-log` for one fenced session.
    func macNet(_ r: HostRequest) async throws -> JSONValue {
        let s = try macSession(r, "doz net \(r.op == .netLog ? "log" : "show") @mac --session SESSION")
        guard let rec = mac.records().sessions[s], let f = rec.fence else {
            throw HostError(.notFound, "no fenced session \(s) on this Mac — only a fenced session has a proxy and permissions (doz sessions @mac)")
        }
        guard let stored = f.policy else {
            throw HostError(.invalid, "session \(s) on this Mac was opened before fenced sessions had a network — doz sessions restart @mac \(s) gives it one")
        }
        let live = macProxies[s]
        let policy = live?.proxy.policy ?? stored
        let records = live?.proxy.log.records ?? []
        switch r.op {
        case .netPermissions:
            var rep = PermissionPolicy.report(name: "@mac \(s)", policy: policy, base: AgentPermissions.macBase, log: records)
            rep.base = nil
            return try JSONValue(encoding: rep)
        case .netLog:
            if r.denials == true {
                return try JSONValue(encoding: FenceDenials(session: s, denialLog: readOnly ? "off" : macDenials.status, denials: macDenials.denials(s)))
            }
            return try JSONValue(encoding: records.filter { r.deniedOnly != true || $0.verdict == .denied })
        default:
            if isPolicyQuery(r) { return try JSONValue(encoding: policy) }
            guard !readOnly else { throw HostError(.unavailable, "net-policy needs the host") }
            let p = try Self.editedPolicy(policy, r, base: AgentPermissions.macBase, agent: nil)
            live?.proxy.policy = p
            await mac.updateRecord(s) { $0.fence?.policy = p }
            note(MacPlace.name, "session \(s) on this Mac: network policy \(p.preset ?? "custom") (\(p.rules.count) rules) — from its next connection")
            return try JSONValue(encoding: p)
        }
    }

    /// `doz sessions resume @mac S`: a session stopped for a git config change continues — refused while a change outside
    /// the allowlist is there again.
    func macResume(_ r: HostRequest) async throws -> SessionResumed {
        guard !readOnly else { throw HostError(.unavailable, "session-resume needs the host") }
        let s = try macSession(r, "doz sessions resume @mac SESSION")
        guard let rec = mac.records().sessions[s], let f = rec.fence else {
            throw HostError(.notFound, "no fenced session \(s) on this Mac (doz sessions @mac)")
        }
        guard f.stoppedForGit != nil else { throw HostError(.invalid, "session \(s) on this Mac is not stopped") }
        let w: MacFenceWatch
        if let have = macFenceWatches[s] { w = have } else {
            w = makeFenceWatch(s, workdir: rec.workdir, roots: [rec.workdir] + f.writable, sentinel: f.sentinel, anti: f.antiSentinel)
            w.pid = rec.pid.map { pid_t($0) }
            macFenceWatches[s] = w
            _ = w.guardian.adopt()
        }
        let again = w.guardian.check()
        if !again.isEmpty {
            throw HostError(.failed, "session \(s) stays stopped: a git config change a fenced session may not make is there again ("
                            + again.flatMap(\.what).prefix(3).joined(separator: "; ") + ") — taken out again; doz sessions @mac --quarantine \(s)")
        }
        let pids = (f.stoppedPids ?? []) + w.stopped
        MacFenceStop.resume(sentinel: f.sentinel, anti: f.antiSentinel, program: rec.pid.map { pid_t($0) }, also: pids)
        w.clearStopped()
        await mac.updateRecord(s) { rec in
            rec.fence?.stoppedForGit = nil
            rec.fence?.stoppedPids = nil
        }
        note(MacPlace.name, "session \(s) on this Mac resumed")
        return SessionResumed(session: s, processes: Set(pids).count)
    }

    /// `doz sessions @mac --quarantine S`: what the git guard took out, newest first (text the host wrote — never a
    /// link's content).
    func macQuarantine(_ r: HostRequest) throws -> SessionQuarantine {
        let s = try macSession(r, "doz sessions @mac --quarantine SESSION")
        let dir = mac.quarantine(s)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".txt") }.sorted(by: >)
        var items: [SessionQuarantine.Item] = []
        for n in names.prefix(50) {
            guard let d = try? MacFenceHostFS.readRegular(dir + "/" + n, maximum: 64 << 10) else { continue }
            items.append(.init(name: n, text: String(decoding: d, as: UTF8.self)))
        }
        if items.isEmpty, mac.records().sessions[s]?.fence == nil {
            throw HostError(.notFound, "no fenced session \(s) on this Mac (doz sessions @mac)")
        }
        return SessionQuarantine(session: s, items: items)
    }

    /// Open a FENCED session (`r.macFence`): its fence and folder made, its git guard's baseline recorded BEFORE the
    /// program starts, then the holder with sandbox-exec in front of the program; then the watch, followed by a full
    /// check (so a change made before the watch began is dealt with too — the order adoption uses), off the start's path.
    func macOpenFenced(_ r: HostRequest, request: MacFenceRequest, holder: URL, name: String, argv: [String]?, workdir: String?,
                       recordedArgv: [String]?, previous: MacFenceRecord?, size: TermSize, extra: [String: String]?) async throws -> (MacSessions.Opened, MacFence, [String]) {
        guard let wd = workdir else { throw HostError(.invalid, "a fenced session needs its folder (--workdir DIR; doz run sends the folder you are in)") }
        let t0 = ContinuousClock.now
        let settings = DozableSettings.load()
        let fenceRead = MacFencePaths.fenceReadEntries(settings.string(SettingKey.macFenceRead) ?? "")
        // Its permissions: as asked; a restart keeps its policy (live edits included); else the setting.
        let policy: NetworkPolicy
        if let words = request.permissions { policy = try MacFenceNetwork.policy(words: words) }
        else if let kept = previous?.policy { policy = kept }
        else { policy = try MacFenceNetwork.policy(words: [settings.string(SettingKey.macPermissions) ?? "standard"]) }
        // 683: a key in the environment would sit beside the swapped login — refused (an account gives it).
        for k in (extra ?? [:]).keys where ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN"].contains(k) {
            throw HostError(.invalid, "-e \(k): a fenced session gets its Claude login through Dozable's proxy — doz run @mac --account NAME (doz account ls), never a key in its environment")
        }
        // 683: its agent's login (only a program whose embedded recipe declares a config folder: Claude Code).
        var login: (account: String?, placeholders: [String: String]) = (nil, [:])
        if let program = argv?.first, AgentRecipes.macAgent(program: program) != nil {
            let a = try fenceAccount(request.account, settings: settings)
            login = (a.account, a.placeholders)
        } else if request.account != nil {
            throw HostError(.invalid, "--account is for Claude Code (doz run @mac --fenced --account NAME -- claude)")
        }
        let prep = try await mac.prepareFence(session: name, workdir: wd, request: request, fenceRead: fenceRead, previous: previous,
                                              trust: MacFenceNetwork.trust(policy), argv: argv, bridges: MacFenceBridges.resolve(request, settings: settings),
                                              placeholders: login.placeholders, account: login.account, settings: settings)
        var f = prep.fence
        f.presetName = AgentPermissions.presetName(policy.permissions ?? [], base: AgentPermissions.macBase)
        dropFenceWatch(name)
        dropFenceProxy(name)
        // The proxy: a new socket on this Mac's loopback (its holder will hold it), a new password, the session's CA.
        let (lfd, port) = try MacFenceNetwork.bindLoopback()
        f.proxyPort = port
        let password = LoopbackProxyListener.newPassword()
        let secret = LoopbackProxyListener.sha256(password)
        var ca: SandboxCA?
        do {
            let c = try SandboxCA.loadOrCreate(in: URL(fileURLWithPath: mac.fenceState(name)), sandbox: "mac-\(name)")
            try MacFenceNetwork.writeCA(c, etc: f.etc)
            ca = c
        } catch {
            HostLog.line("\(MacPlace.name): fenced session \(name): no CA (\(error)) — hosts that need request inspection are refused")
        }
        let t1 = ContinuousClock.now
        let w = makeFenceWatch(name, workdir: f.workdir, roots: f.writableRoots, sentinel: f.sentinel, anti: f.antiSentinel)
        let baseline: MacFenceGitBaseline
        do { baseline = try w.guardian.recordBaseline() } catch { close(lfd); throw error }
        let t2 = ContinuousClock.now
        // 683: Claude Code's facts about where it runs — one combined --append-system-prompt (the record keeps the argv).
        var launch = argv
        if let a = argv, MacAgentPrompt.applies(argv: a, fenced: true, setting: settings.string(SettingKey.macAgentPrompt) ?? "fenced") {
            launch = MacAgentPrompt.argv(a, facts: MacAgentPrompt.facts(fence: f, agent: f.agent, workdir: f.workdir))
        }
        let o: MacSessions.Opened
        do {
            o = try await mac.open(session: name, argv: launch, workdir: f.workdir, extra: extra, size: size, holder: holder,
                                   recordedArgv: recordedArgv ?? argv, fence: f, gitBaseline: baseline,
                                   proxy: .init(fd: lfd, password: password, secretSHA256: secret, policy: policy, ca: ca != nil))
        } catch {
            close(lfd)
            throw error
        }
        let t3 = ContinuousClock.now
        // The holder holds its copy now; this host serves its own — made off the start's path (the proxy's TLS context
        // costs tens of ms): until it accepts, the program's connections wait in the socket's backlog.
        let env = mac.hostEnvironment
        let made = Task.detached { () -> MacFenceProxy? in
            do {
                let p = try MacFenceProxy(session: name, fd: lfd, port: port, policy: policy, secretSHA256: secret, ca: ca, environment: env)
                // 683: started by installProxy, once its login is bound (a request before that would pass unswapped).
                return p
            } catch {
                close(lfd)
                HostLog.line("\(MacPlace.name): fenced session \(name): its proxy did not start (\(error)) — its connections wait until the next host")
                return nil
            }
        }
        Task { [weak self] in
            if let p = await made.value { await self?.installProxy(name, p) }
        }
        macDenials.watch(session: name, tag: f.tag)
        func ms(_ a: ContinuousClock.Instant, _ b: ContinuousClock.Instant) -> String {
            let d = b - a
            return String(format: "%.1f", Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15)
        }
        HostLog.line("\(MacPlace.name): fenced open of \(name): fence and folder \(ms(t0, t1)) ms, git baseline \(ms(t1, t2)) ms, holder \(ms(t2, t3)) ms")
        w.pid = o.pid.map { pid_t($0) }
        macFenceWatches[name] = w
        let guardian = w.guardian!
        Task.detached {
            guardian.start()
            _ = guardian.check()
        }
        return (o, f, prep.notes)
    }

    func macRows() async -> [SessionRow] {
        var rows = await mac.rows()
        for i in rows.indices where rows[i].ended {
            rows[i].status = statuses[MacPlace.name]?[rows[i].name]          // done/error outlive the program
        }
        for i in rows.indices where !rows[i].ended {
            if let kept = statuses[MacPlace.name]?[rows[i].name], let now = rows[i].status, kept.sameReport(as: now) { rows[i].status = kept }
        }
        // A fenced one's network as this host serves it, and the refusals its fence logged.
        for i in rows.indices where rows[i].fence != nil {
            let s = rows[i].name
            if let p = macProxies[s] {
                rows[i].fence?.network = "proxy"
                rows[i].fence?.permissions = p.proxy.policy.permissions
                rows[i].fence?.preset = AgentPermissions.presetName(p.proxy.policy.permissions ?? [], base: AgentPermissions.macBase)
            } else if rows[i].ended, rows[i].fence?.network != "none" {
                rows[i].fence?.network = nil
            }
            if !readOnly {
                rows[i].fence?.denialLog = macDenials.status
                rows[i].fence?.denialsSeen = macDenials.denials(s).count
            }
        }
        if !readOnly {
            for r in rows where !r.ended { await watchStatus(MacPlace.name, session: r.name) }
        }
        return rows
    }

    func macOpen(_ r: HostRequest) async throws -> SessionOpened {
        guard !readOnly else { throw HostError(.unavailable, "open-session needs the host") }
        if r.user != nil { throw HostError(.invalid, "--user does not apply on this Mac: its sessions run as you") }
        let located = MacDeckhold.locate()
        guard let holder = located.url else {
            throw HostError(.unavailable, "sessions on this Mac need deckhold-mac beside doz — \(located.why ?? "it is not there")")
        }
        await sessionGate.lock(MacPlace.name)
        defer { sessionGate.unlock(MacPlace.name) }
        let size = TermSize(cols: r.cols ?? 80, rows: r.rows ?? 24)
        if let req = r.macFence {
            let name = try mac.sessionName(r.session, argv: r.argv)
            // A session of that name runs already: it is not opened twice (and its folder is not re-seeded under it).
            if await mac.isRunning(name) {
                let rec = mac.records().sessions[name]
                var s = SessionOpened(name: MacPlace.name, session: name, created: false)
                s.bypassed = rec?.bypassed
                s.fenced = rec?.fence != nil
                s.notice = rec?.fence == nil ? "\(name) already runs on this Mac UNFENCED — doz sessions end @mac \(name) first" : nil
                return s
            }
            let (o, f, notes) = try await macOpenFenced(r, request: req, holder: holder, name: name, argv: r.argv, workdir: r.workdir,
                                                        recordedArgv: nil, previous: mac.records().sessions[name]?.fence, size: size, extra: r.environment)
            note(MacPlace.name, "session \(o.session) opened on this Mac, fenced" + (f.keychain ? " (Keychain open)" : "")
                 + (o.bypassed ? " — its own argv bypasses permissions" : ""))
            metrics?.record(run: metricsRun, action: "mac session open", sandbox: MacPlace.name, image: "", startedAt: Date(), durationMs: 0,
                            detail: ["session": o.session, "bypassed": o.bypassed ? "yes" : "no", "fenced": "yes"])
            await watchStatus(MacPlace.name, session: o.session)
            var s = SessionOpened(name: MacPlace.name, session: o.session, created: o.created)
            s.bypassed = o.bypassed ? true : nil
            s.fenced = true
            s.fenceLine = f.line()
            s.fenceNotes = notes.isEmpty ? nil : notes
            return s
        }
        let o = try await mac.open(session: r.session, argv: Self.macPromptArgv(r.argv, workdir: r.workdir), workdir: r.workdir, extra: r.environment,
                                   size: size, holder: holder, recordedArgv: r.argv)
        if o.created {
            note(MacPlace.name, "session \(o.session) opened on this Mac (no isolation)" + (o.bypassed ? " — its own argv bypasses permissions" : "")
                 + (o.pathSource.map { "; PATH from the \($0)" } ?? ""))
            metrics?.record(run: metricsRun, action: "mac session open", sandbox: MacPlace.name, image: "", startedAt: Date(), durationMs: 0,
                            detail: ["session": o.session, "bypassed": o.bypassed ? "yes" : "no"])
        }
        await watchStatus(MacPlace.name, session: o.session)
        var s = SessionOpened(name: MacPlace.name, session: o.session, created: o.created)
        s.bypassed = o.bypassed ? true : nil
        return s
    }

    /// 683: an UNFENCED Claude Code session's facts, only with `mac.agent_prompt = always` (nil argv: unchanged).
    static func macPromptArgv(_ argv: [String]?, workdir: String?) -> [String]? {
        guard let a = argv, MacAgentPrompt.applies(argv: a, fenced: false, setting: DozableSettings.load().string(SettingKey.macAgentPrompt) ?? "fenced") else { return argv }
        return MacAgentPrompt.argv(a, facts: MacAgentPrompt.facts(fence: nil, agent: nil, workdir: workdir ?? NSHomeDirectory()))
    }

    func macLive(_ r: HostRequest) async throws -> SessionLive {
        let s = try macSession(r, "doz sessions screen @mac SESSION")
        if let l = await mac.liveScreen(s) {
            var out = SessionLive(sandbox: MacPlace.name, session: s, live: true, text: l.text, cols: l.cols, rows: l.rows,
                                  cursorX: l.cursorX, cursorY: l.cursorY, screen: l.screen)
            out.status = statuses[MacPlace.name]?[s]
            return out
        }
        // Its holder is gone (not ended): the screen saved last, said so.
        let state = await mac.state(s)
        if state == .stale || state == .noSession, let saved = mac.savedScreen(s) {
            var out = SessionLive(sandbox: MacPlace.name, session: s, live: false, text: saved.text, cols: saved.info.cols, rows: saved.info.rows,
                                  cursorX: nil, cursorY: nil, screen: saved.info.screen)
            out.savedAt = saved.info.savedAt
            out.reason = "gone"
            out.status = statuses[MacPlace.name]?[s]
            return out
        }
        throw await macNotRunning(s)
    }

    /// The periodic capture's part for this Mac (`host.screen_capture_minutes`).
    func captureMacScreens(reason: String = "periodic") async {
        let r = await mac.captureScreens(changedOnly: true, reason: reason)
        if !r.captured.isEmpty || !r.failed.isEmpty {
            HostLog.line("\(MacPlace.name): \(reason) screen capture — saved \(r.captured.joined(separator: ", "))"
                         + (r.failed.isEmpty ? "" : "; failed \(r.failed.joined(separator: ", "))") + String(format: " (%.0f ms)", r.milliseconds))
        }
    }

    /// A host stop: the sessions on this Mac keep running (their screens saved once more) — how many.
    public func macSessionsAtExit() async -> Int {
        guard !readOnly else { return 0 }
        await captureMacScreens(reason: "host stop")
        return (await mac.rows()).filter { !$0.ended }.count
    }

    /// Why session `s` cannot be read or typed into now.
    func macNotRunning(_ s: String) async -> HostError {
        switch await mac.state(s) {
        case .ended(let code):
            return HostError(.notFound, "the session \(s) on this Mac has ended (exit \(code.map(String.init) ?? "?")) — doz sessions restart @mac \(s) starts it again")
        case .info:
            return HostError(.failed, "the session \(s) on this Mac did not answer in time")
        case .stale, .noSession:
            if mac.records().sessions[s] != nil {
                return HostError(.notFound, "the session \(s) on this Mac is gone (the Mac restarted, or its holder was killed) — doz sessions restart @mac \(s) starts it again")
            }
            return HostError(.notFound, "no session \(s) on this Mac (doz sessions @mac lists them)")
        }
    }

    func macSend(_ r: HostRequest) async throws -> SessionSent {
        let s = try macSession(r, "doz sessions send @mac SESSION …")
        guard let bytes = r.input, !bytes.isEmpty else { throw HostError(.invalid, "nothing to send — --text, --keys or --enter") }
        guard bytes.count <= SessionInput.maximumBytes else {
            throw HostError(.invalid, "at most \(SessionInput.maximumBytes / 1024) KiB in one send (this is \(bytes.count) bytes)")
        }
        let t0 = ContinuousClock.now
        let receipt: SessionInput.Receipt
        do { receipt = try await DeckholdSocket.send(path: mac.socket(s), pieces: Self.sendPieces(r, bytes)) } catch { throw HostError.from(error) }
        switch receipt {
        case .delivered:
            return SessionSent(sandbox: MacPlace.name, session: s, bytes: bytes.count, woke: false, milliseconds: ms(since: t0))
        case .noSession, .ended:
            throw await macNotRunning(s)
        }
    }

    func macEnd(_ r: HostRequest) async throws -> SessionEnded {
        guard !readOnly else { throw HostError(.unavailable, "session-end needs the host") }
        let s = try macSession(r, "doz sessions end @mac SESSION")
        await sessionGate.lock(MacPlace.name)
        defer { sessionGate.unlock(MacPlace.name) }
        let fence = mac.records().sessions[s]?.fence
        // A stopped fenced session: continued first, so its program can hang up like any other.
        if let f = fence, f.stoppedForGit != nil {
            MacFenceStop.resume(sentinel: f.sentinel, anti: f.antiSentinel, program: mac.records().sessions[s]?.pid.map { pid_t($0) }, also: f.stoppedPids ?? [])
        }
        let how = try await mac.end(s)
        // Whatever of the fence outlived its program (a detached child) ends with it: nothing would watch it any more.
        // Its proxy ends too (its holder, gone, closed its copy of the socket; this host closes its own).
        if let f = fence {
            for p in MacFenceStop.members(sentinel: f.sentinel, anti: f.antiSentinel, program: nil).pids { kill(p, SIGKILL) }
            dropFenceProxy(s)
            macDenials.unwatch(session: s)
        }
        // 683: a private agent folder's conversations go back to the person's own (and the archive) — before anything
        // of the session folder is forgotten.
        let carried = how == .stuck ? nil : await macCarryBack(s)
        switch how {
        case .notRunning:
            // Not running: an ended or gone one is forgotten (its record and exit) — nothing else to end.
            var known = mac.records().sessions[s] != nil
            if !known, case .ended = await mac.state(s) { known = true }
            guard known else { throw HostError(.notFound, "no session \(s) on this Mac (doz sessions @mac)") }
            dropFenceWatch(s)
            macDenials.forget(session: s)
            await mac.forget(s)
        case .stuck:
            throw HostError(.failed, "session \(s) on this Mac did not end, even after SIGKILL — a program stuck in the kernel")
        default:
            dropFenceWatch(s)
            note(MacPlace.name, "session \(s) on this Mac ended (\(how.rawValue))" + (carried.map { " — " + $0 } ?? ""))
        }
        var out = SessionEnded(name: MacPlace.name, session: s, how: how.rawValue)
        out.notice = carried
        return out
    }

    func macRestart(_ r: HostRequest) async throws -> SessionRestarted {
        guard !readOnly else { throw HostError(.unavailable, "session-restart needs the host") }
        let s = try macSession(r, "doz sessions restart @mac SESSION")
        guard let rec = mac.records().sessions[s] else {
            throw HostError(.notFound, "session \(s) on this Mac was not opened by doz, so its program is not known — doz sessions end @mac \(s), then doz run @mac --session \(s) -- CMD")
        }
        if let f = rec.fence, let why = f.stoppedForGit {
            throw HostError(.invalid, "session \(s) on this Mac is stopped for a git config change (\(why)) — doz sessions resume @mac \(s) first")
        }
        let located = MacDeckhold.locate()
        guard let holder = located.url else {
            throw HostError(.unavailable, "sessions on this Mac need deckhold-mac beside doz — \(located.why ?? "it is not there")")
        }
        await sessionGate.lock(MacPlace.name)
        defer { sessionGate.unlock(MacPlace.name) }
        var size = TermSize(cols: r.cols ?? 0, rows: r.rows ?? 0)
        if case .info(let line) = await mac.state(s), let was = SessionInfo.parseList(line).first?.size, r.cols == nil { size = was }
        let how = try await mac.end(s)
        if how == .stuck { throw HostError(.failed, "session \(s) on this Mac did not end, even after SIGKILL") }
        var resume = MacPlace.resumeArguments(rec.argv, fresh: r.fresh == true)
        var notes: [String] = []
        // 683: its conversations so far go back to the person's own first (a private agent folder keeps them too).
        if let t = await macCarryBack(s) { notes.append(t) }
        // claude --continue with no conversation in the folder exits at once — and the session with it: start fresh.
        // 683: a fenced session with its own (private) config folder continues from THAT folder's conversations.
        let projects = rec.fence?.agentConfig == MacAgentConfig.privateMode ? (rec.fence!.sessionFolder + "/agent/projects") : MacPlace.claudeProjects(mac.hostEnvironment)
        if !resume.isEmpty, !MacPlace.claudeHasConversation(workdir: rec.workdir, projects: projects) {
            resume = []
            notes.append("no earlier conversation in \(DisplayPath.tilde(rec.workdir)) — claude starts a new one")
        }
        if let keys = rec.environmentKeys, !keys.isEmpty {
            notes.append("the variables it was opened with (\(keys.joined(separator: ", "))) are not kept — it runs without them")
        }
        let openSize = TermSize(cols: size.cols > 0 ? size.cols : 80, rows: size.rows > 0 ? size.rows : 24)
        let o: MacSessions.Opened
        if let f = rec.fence {
            // The same grants, this build's template, a new tag; the session's folder re-seeded.
            dropFenceWatch(s)
            for p in MacFenceStop.members(sentinel: f.sentinel, anti: f.antiSentinel, program: nil).pids { kill(p, SIGKILL) }
            o = try await macOpenFenced(r, request: f.request, holder: holder, name: s, argv: rec.argv + resume, workdir: rec.workdir,
                                        recordedArgv: rec.argv, previous: f, size: openSize, extra: nil).0
        } else {
            o = try await mac.open(session: s, argv: Self.macPromptArgv(rec.argv + resume, workdir: rec.workdir), workdir: rec.workdir, extra: nil, size: openSize,
                                   holder: holder, recordedArgv: rec.argv)
        }
        await watchStatus(MacPlace.name, session: s)
        note(MacPlace.name, "session \(s) on this Mac restarted" + (resume.isEmpty ? "" : " — claude continues the folder's newest conversation"))
        var out = SessionRestarted(name: MacPlace.name, session: s, ended: how.rawValue, resumed: !resume.isEmpty,
                                   command: (rec.argv + resume).joined(separator: " "), notice: notes.isEmpty ? nil : notes.joined(separator: "; "))
        if !o.created { out.notice = (out.notice.map { $0 + "; " } ?? "") + "it was already running again" }
        return out
    }
}

/// One fenced session's git guard and how it stops the session (`MacFenceStop`, on the guard's own queue — at once,
/// before anything is reported).
final class MacFenceWatch: @unchecked Sendable {
    let sentinel: String
    let anti: String
    var guardian: MacFenceGitGuard!
    private let lock = NSLock()
    private var _pid: pid_t?
    private var _stopped: Set<Int> = []

    init(sentinel: String, anti: String) {
        self.sentinel = sentinel
        self.anti = anti
    }

    /// The program's pid (the fallback's group leader).
    var pid: pid_t? {
        get { lock.withLock { _pid } }
        set { lock.withLock { _pid = newValue } }
    }

    /// Every process stopped so far.
    var stopped: [Int] { lock.withLock { _stopped.sorted() } }

    func clearStopped() { lock.withLock { _stopped = [] } }

    func stopNow() {
        let r = MacFenceStop.stop(sentinel: sentinel, anti: anti, program: pid)
        lock.withLock { _stopped.formUnion(r.pids.map(Int.init)) }
        if r.how != "sandbox_check" { HostLog.line("@mac: a fenced session was stopped by its group (\(r.how))") }
    }
}
