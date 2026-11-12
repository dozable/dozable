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
            throw HostError(.notFound, "no saved screen of \(s) on this Mac")
        case .sessionSend:
            return try JSONValue(encoding: try await macSend(r))
        case .sessionEnd:
            return try JSONValue(encoding: try await macEnd(r))
        case .sessionRestart:
            return try JSONValue(encoding: try await macRestart(r))
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
        let o = try await mac.open(session: r.session, argv: r.argv, workdir: r.workdir, extra: r.environment,
                                   size: TermSize(cols: r.cols ?? 80, rows: r.rows ?? 24), holder: holder)
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
        throw await macNotRunning(s)
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
        do { receipt = try await DeckholdSocket.send(path: mac.socket(s), bytes: bytes) } catch { throw HostError.from(error) }
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
        let how = try await mac.end(s)
        switch how {
        case .notRunning:
            // Not running: an ended or gone one is forgotten (its record and exit) — nothing else to end.
            var known = mac.records().sessions[s] != nil
            if !known, case .ended = await mac.state(s) { known = true }
            guard known else { throw HostError(.notFound, "no session \(s) on this Mac (doz sessions @mac)") }
            await mac.forget(s)
        case .stuck:
            throw HostError(.failed, "session \(s) on this Mac did not end, even after SIGKILL — a program stuck in the kernel")
        default:
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
        let resume = MacPlace.resumeArguments(rec.argv, fresh: r.fresh == true)
        var notes: [String] = []
        if let keys = rec.environmentKeys, !keys.isEmpty {
            notes.append("the variables it was opened with (\(keys.joined(separator: ", "))) are not kept — it runs without them")
        }
        let o = try await mac.open(session: s, argv: rec.argv + resume, workdir: rec.workdir, extra: nil,
                                   size: TermSize(cols: size.cols > 0 ? size.cols : 80, rows: size.rows > 0 ? size.rows : 24),
                                   holder: holder, recordedArgv: rec.argv)
        await watchStatus(MacPlace.name, session: s)
        note(MacPlace.name, "session \(s) on this Mac restarted" + (resume.isEmpty ? "" : " — claude continues the folder's newest conversation"))
        var out = SessionRestarted(name: MacPlace.name, session: s, ended: how.rawValue, resumed: !resume.isEmpty,
                                   command: (rec.argv + resume).joined(separator: " "), notice: notes.isEmpty ? nil : notes.joined(separator: "; "))
        if !o.created { out.notice = (out.notice.map { $0 + "; " } ?? "") + "it was already running again" }
        return out
    }
}
