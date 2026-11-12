import DozableKit
import Foundation

// 678 B5: `doz sessions send` and `doz sessions screen` — typing into a held session and reading its screen now, from a
// script (the agent-relay skill drives sessions this way).

extension HostCore {
    /// The writes of a send: the client's pieces when they are exactly `input` (each written apart — a TUI must read the
    /// Enter after a long line on its own); else `input` as one (an older client), Enter-terminated input split off
    /// its trailing CR all the same.
    static func sendPieces(_ r: HostRequest, _ bytes: Data) -> [Data] {
        if let p = r.inputPieces, !p.isEmpty, p.reduce(Data(), +) == bytes { return p }
        if bytes.count > 1, bytes.last == 0x0D { return [bytes.dropLast(), Data([0x0D])] }
        return [bytes]
    }

    /// `session-send`: wake (unless `wake` is false; never a cold start — an off sandbox has no sessions), wait for the
    /// wake's background steps, then type — answered once deckhold acknowledged every byte.
    func sessionSend(_ r: HostRequest, emit: @escaping @Sendable (HostEvent) -> Void) async throws -> SessionSent {
        let m = try get(r.name)
        guard let session = r.session else { throw HostError(.invalid, "which session? doz sessions send \(m.name) SESSION …") }
        try GuestCommand.validateSessionName(session)
        guard let bytes = r.input, !bytes.isEmpty else { throw HostError(.invalid, "nothing to send — --text, --keys or --enter") }
        guard bytes.count <= SessionInput.maximumBytes else {
            throw HostError(.invalid, "at most \(SessionInput.maximumBytes / 1024) KiB in one send (this is \(bytes.count) bytes)")
        }
        let t0 = ContinuousClock.now
        let phase = await effectivePhase(m)
        if phase == .off || phase == .failed {
            throw HostError(.invalidPhase, "\(m.name) is \(PhaseName.label(phase)) — it has no sessions (doz start \(m.name) boots it fresh)")
        }
        let first = try await ensureRunning(m, wake: r.wake ?? true, start: false, emit: emit)
        await m.sandbox.afterWakeSettled()
        await m.sandbox.relieveMemoryPressure("a session was sent input")        // B7: input is work to come
        let receipt: SessionInput.Receipt
        do { receipt = try await m.sandbox.sendInput(session, pieces: Self.sendPieces(r, bytes)) } catch { throw HostError.from(error) }
        switch receipt {
        case .delivered:
            metrics?.record(run: metricsRun, action: "session send", sandbox: m.name, image: m.config.image, startedAt: Date(), durationMs: 0)
            return SessionSent(sandbox: m.name, session: session, bytes: bytes.count, woke: first.woke, milliseconds: ms(since: t0))
        case .noSession:
            throw HostError(.notFound, "no session \(session) in \(m.name) (doz sessions \(m.name) lists them)")
        case .ended(let code):
            throw HostError(.notFound, "the session \(session) in \(m.name) has ended (exit \(code.map(String.init) ?? "?")) — doz sessions restart \(m.name) \(session) starts it again")
        }
    }

    /// `session-live`: running — the screen now (bounded: a guest that does not answer is said, never waited on);
    /// sleeping — the last saved screen, flagged, unless `wake` (then woken first and read live); off — refused.
    func sessionLive(_ r: HostRequest, emit: @escaping @Sendable (HostEvent) -> Void) async throws -> SessionLive {
        let m = try get(r.name)
        guard let session = r.session else { throw HostError(.invalid, "which session? doz sessions screen \(m.name) SESSION") }
        try GuestCommand.validateSessionName(session)
        var phase = await effectivePhase(m)
        if phase == .off || phase == .failed {
            throw HostError(.invalidPhase, "\(m.name) is \(PhaseName.label(phase)) — it has no sessions (doz start \(m.name) boots it fresh)")
        }
        var woke: Bool?
        if phase != .running, r.wake == true, !readOnly {
            let first = try await ensureRunning(m, wake: true, start: false, emit: emit)
            await m.sandbox.afterWakeSettled()
            woke = first.woke
            phase = await effectivePhase(m)
        }
        if phase == .running, !readOnly {
            switch await guestRead(m, { try await $0.liveScreen(session) }) {
            case .answered(let s?):
                var out = SessionLive(sandbox: m.name, session: session, live: true, text: s.text, cols: s.cols, rows: s.rows,
                                      cursorX: s.cursorX, cursorY: s.cursorY, screen: s.screen)
                out.status = statuses[m.name]?[session]
                out.woke = woke
                return out
            case .answered(nil):
                throw HostError(.notFound, "no session \(session) in \(m.name) (doz sessions \(m.name) lists them)")
            case .failed(let e):
                throw HostError.from(e)
            case .unresponsive:
                break                                   // its last saved screen, said so
            }
        }
        guard let saved = SavedScreens.read(m.sandbox.layout, session: session) else {
            throw HostError(.notFound, phase == .running
                ? "\(m.name) does not answer, and no screen of \(session) is saved"
                : "no saved screen of \(session) in \(m.name) — doz sessions screen \(m.name) \(session) --wake wakes it and reads it live")
        }
        var out = SessionLive(sandbox: m.name, session: session, live: false, text: saved.text, cols: saved.info.cols, rows: saved.info.rows,
                              cursorX: nil, cursorY: nil, screen: saved.info.screen)
        out.savedAt = saved.info.savedAt
        out.reason = phase == .running ? "unresponsive" : saved.info.reason
        out.status = statuses[m.name]?[session]
        return out
    }
}
