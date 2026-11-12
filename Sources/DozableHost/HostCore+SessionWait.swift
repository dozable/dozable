import DozableKit
import Foundation

/// `doz sessions wait PLACE SESSION --until STATE…` — block until a session's program reports one of the states (OSC
/// 7501, as its holder keeps it), on a WATCH connection of its own (the holder answers with the status now, then each
/// change). A sandbox must be running (a wait never wakes one); `@mac` needs its holder. Exit 124 at the timeout.
extension HostCore {
    /// At most this long, whatever was asked (a client that went away must not leave a watcher behind for ever).
    static let maximumWaitSeconds: Int64 = 24 * 3600

    func sessionWait(_ r: HostRequest) async throws -> SessionWaited {
        guard let session = r.session else { throw HostError(.invalid, "which session? doz sessions wait PLACE SESSION --until STATE") }
        let words = r.until ?? []
        let wanted = Set(words.compactMap(ProgramStatus.State.init(rawValue:)))
        guard !wanted.isEmpty, wanted.count == Set(words).count else {
            throw HostError(.invalid, "--until takes \(ProgramStatus.State.allCases.map(\.rawValue).joined(separator: ", ")) (one or more)")
        }
        let onMac = MacPlace.isPlace(r.name)
        let place = onMac ? MacPlace.name : (r.name ?? "")
        let conn: SessionConnection
        if onMac {
            try MacPlace.validateSessionName(session)
            conn = mac.watchStatus(session)
        } else {
            let m = try get(r.name)
            try GuestCommand.validateSessionName(session)
            let phase = await effectivePhase(m)
            guard phase == .running else {
                throw HostError(.invalidPhase, "\(m.name) is \(PhaseName.label(phase)) — waiting needs it running (doz wake \(m.name) first; a wait never wakes it)")
            }
            do { conn = try await m.sandbox.watchStatus(session) } catch { throw HostError.from(error) }
        }
        let t0 = ContinuousClock.now
        let seconds = min(max(r.timeoutSeconds ?? 0, 0) == 0 ? Self.maximumWaitSeconds : r.timeoutSeconds!, Self.maximumWaitSeconds)
        let timer = Task.detached {
            try? await Task.sleep(for: .seconds(Double(seconds)))
            conn.close()                                   // → .detached(.closedByClient): the time is up
        }
        defer { timer.cancel(); conn.close() }
        var last: ProgramStatus?
        for await out in conn.output {
            switch out {
            case .status(let p):
                last = p
                if let p, wanted.contains(p.state) {
                    return SessionWaited(place: place, session: session, state: p.state.rawValue, status: SessionStatus(session: session, p),
                                         timedOut: false, milliseconds: ms(since: t0))
                }
            case .ended(let code):
                // done / error outlive the program: the host's last word counts.
                if let kept = statuses[place]?[session], wanted.contains(kept.state) {
                    return SessionWaited(place: place, session: session, state: kept.state.rawValue, status: kept, timedOut: false, milliseconds: ms(since: t0))
                }
                if let last, wanted.contains(last.state) {
                    return SessionWaited(place: place, session: session, state: last.state.rawValue, status: SessionStatus(session: session, last),
                                         timedOut: false, milliseconds: ms(since: t0))
                }
                guard let code else {
                    throw HostError(.notFound, onMac ? "no session \(session) on this Mac (doz sessions @mac lists them)"
                                                     : "no session \(session) in \(place) (doz sessions \(place) lists them)")
                }
                throw HostError(.notFound, "the session \(session) \(onMac ? "on this Mac" : "in \(place)") ended (exit \(code)) before it was \(words.joined(separator: " or "))")
            case .detached(.closedByClient):
                var w = SessionWaited(place: place, session: session, state: last?.state.rawValue, status: last.map { SessionStatus(session: session, $0) },
                                      timedOut: true, milliseconds: ms(since: t0))
                w.timedOut = true
                return w
            case .detached(.sandboxSleeping), .detached(.sandboxStopped):
                throw HostError(.invalidPhase, "\(place) stopped running while waiting for \(session)")
            case .detached(.transportLost):
                if conn.sawStatus { throw HostError(.failed, "the connection to \(session)'s holder was lost while waiting") }
                throw HostError(.failed, "\(session)'s holder does not report its program's status (an older holder — restart the session)")
            case .snapshot, .data:
                break
            }
        }
        throw HostError(.failed, "the wait for \(session) ended without an answer")
    }
}
