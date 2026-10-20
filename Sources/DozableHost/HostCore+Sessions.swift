import Foundation
import DozableKit

/// 635: the session registry's hooks (`SessionRegistry` says what feeds it and why). Every call here reads what the
/// host already knows or a guest list it already made — none asks the guest anything.
extension HostCore {
    /// The program a session runs, as recorded when the host opened it, else what the caller gives.
    func recordedProgram(_ name: String, _ session: String, fallback: String?) -> String? {
        SessionRecords.read(store, name).sessions[session]?.argv.first ?? fallback
    }

    /// `openSessionLocked`: a program was started under this name, or the name was found running.
    func registerOpened(_ m: Managed, _ opened: SessionOpened, argv: [String]?) {
        let program = recordedProgram(m.name, opened.session, fallback: argv?.first
                                      ?? (opened.session == m.config.defaultSession.name ? m.config.defaultSession.argv.first : nil))
        if opened.created {
            sessionRegistry.opened(m.name, opened.session, program: program ?? opened.session)
        } else {
            sessionRegistry.seen(m.name, opened.session, program: program)
        }
    }

    /// A list the host made anyway; `mark` is `sessionRegistry.epoch` read before it was asked for.
    func reconcileSessions(_ name: String, _ list: [SessionInfo], mark: UInt64) {
        guard managed[name] != nil else { return }
        sessionRegistry.reconcile(name, live: list, mark: mark)
    }

    /// `ls`'s sessions, from memory and the sandbox's own files.
    func sessionListFields(_ m: Managed, phase: Phase, into i: inout SandboxInfo) {
        guard let v = sessionBriefs(m.name, phase: phase) else { return }
        i.sessionList = v.list
        i.sessionMore = v.more > 0 ? v.more : nil
    }

    /// The sessions `ls` carries for `name` in `phase` (nil: none) — memory, its saved screens, its `sessions.json`.
    func sessionBriefs(_ name: String, phase: Phase) -> (list: [SessionBrief], more: Int)? {
        guard let m = managed[name], [.running, .paused, .asleep, .hibernated].contains(phase) else { return nil }
        let fromSaved = phase != .running || !sessionRegistry.hasListed(name)
        if !fromSaved && sessionRegistry.names(name).isEmpty { return nil }
        let saved = fromSaved ? m.sandbox.savedScreens() : []
        if fromSaved && saved.isEmpty { return nil }
        let v = sessionRegistry.view(name, phase: phase, saved: saved, records: SessionRecords.read(store, name),
                                     defaultSession: m.config.defaultSession.name)
        return v.list.isEmpty ? nil : v
    }

    /// `sessions` / `inspect` rows gain when the host opened each (from `sessions.json`).
    func withOpenedAt(_ name: String, _ rows: [SessionRow]) -> [SessionRow] {
        let recs = SessionRecords.read(store, name).sessions
        guard !recs.isEmpty else { return rows }
        return rows.map { r in var x = r; x.openedAt = recs[r.name]?.openedAt; return x }
    }
}
