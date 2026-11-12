import DozableHost
import Foundation

/// 679 B6: the running host cannot read the login keychain (it was started from an ssh session, or one with no login)
/// — what `doz account ls|show` and `doz ls` say beside an account it cannot read. nil: no host runs, or it can.
func hostKeychainNote(_ g: GlobalOptions) -> String? {
    let store = g.dozableStore
    guard store.hostIsRunning(), let m = try? HostClient.request(HostRequest(.ping), store: store, autostart: false),
          let st = try? m.result?.decode(HostStatus.self), let why = st.keychainLocked else { return nil }
    return HostSessionKind.hostAdvice(pid: st.pid, startedAt: st.startedAt, reason: why)
}

/// Say it on stderr (never in `--json`'s stdout; `--quiet` keeps it).
func sayHostKeychainNote(_ g: GlobalOptions) {
    guard !g.json, let n = hostKeychainNote(g) else { return }
    Out.stderr("[doz] \(n)\n")
}
