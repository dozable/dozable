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
        for s in live where macFenceWatches[s] == nil {
            guard let rec = recs[s], let f = rec.fence else { continue }
            let w = makeFenceWatch(s, workdir: rec.workdir, roots: [rec.workdir] + f.writable, sentinel: f.sentinel, anti: f.antiSentinel)
            w.pid = rec.pid.map { pid_t($0) }
            macFenceWatches[s] = w
            let found = w.guardian.adopt()          // the baseline, the watch, then a full check
            if !found.isEmpty { note(MacPlace.name, "session \(s) on this Mac: its git config changed while no host ran — dealt with now") }
        }
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

    /// The fenced sessions this host keeps up (their git guard needs a host).
    public func fencedMacSessions() async -> [String] {
        for s in macFenceWatches.keys.sorted() where !(await mac.isRunning(s)) { dropFenceWatch(s) }
        return macFenceWatches.keys.sorted()
    }

    func dropFenceWatch(_ s: String) {
        macFenceWatches[s]?.guardian.cancel()
        macFenceWatches[s] = nil
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
        let fenceRead = MacFencePaths.fenceReadEntries(DozableSettings.load().string(SettingKey.macFenceRead) ?? "")
        let prep = try await mac.prepareFence(session: name, workdir: wd, request: request, fenceRead: fenceRead, previous: previous)
        let f = prep.fence
        dropFenceWatch(name)
        let t1 = ContinuousClock.now
        let w = makeFenceWatch(name, workdir: f.workdir, roots: f.writableRoots, sentinel: f.sentinel, anti: f.antiSentinel)
        let baseline = try w.guardian.recordBaseline()
        let t2 = ContinuousClock.now
        let o = try await mac.open(session: name, argv: argv, workdir: f.workdir, extra: extra, size: size, holder: holder,
                                   recordedArgv: recordedArgv, fence: f, gitBaseline: baseline)
        let t3 = ContinuousClock.now
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
        let o = try await mac.open(session: r.session, argv: r.argv, workdir: r.workdir, extra: r.environment, size: size, holder: holder)
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
        if let f = fence {
            for p in MacFenceStop.members(sentinel: f.sentinel, anti: f.antiSentinel, program: nil).pids { kill(p, SIGKILL) }
        }
        switch how {
        case .notRunning:
            // Not running: an ended or gone one is forgotten (its record and exit) — nothing else to end.
            var known = mac.records().sessions[s] != nil
            if !known, case .ended = await mac.state(s) { known = true }
            guard known else { throw HostError(.notFound, "no session \(s) on this Mac (doz sessions @mac)") }
            dropFenceWatch(s)
            await mac.forget(s)
        case .stuck:
            throw HostError(.failed, "session \(s) on this Mac did not end, even after SIGKILL — a program stuck in the kernel")
        default:
            dropFenceWatch(s)
            note(MacPlace.name, "session \(s) on this Mac ended (\(how.rawValue))")
        }
        return SessionEnded(name: MacPlace.name, session: s, how: how.rawValue)
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
        // claude --continue with no conversation in the folder exits at once — and the session with it: start fresh.
        if !resume.isEmpty, !MacPlace.claudeHasConversation(workdir: rec.workdir, projects: MacPlace.claudeProjects(mac.hostEnvironment)) {
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
            o = try await mac.open(session: s, argv: rec.argv + resume, workdir: rec.workdir, extra: nil, size: openSize,
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
