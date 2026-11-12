import ArgumentParser
import Foundation
import DozableKit
import DozableHost

/// `@mac` on the command line: the commands that take it as their PLACE, the one refusal for every other, and how its
/// sessions are shown.
enum MacCLI {
    /// The commands that take `@mac`.
    static let takes: Set<ObjectIdentifier> = Set([Run.self, Attach.self, SessionsList.self, SessionsEnd.self, SessionsRestart.self,
                                                   SessionsSend.self, SessionsScreen.self].map { ObjectIdentifier($0 as Any.Type) })

    /// The refusal for a parsed command that names `@mac` (before any `--`) and does not take it; nil otherwise.
    static func refusal(_ command: any ParsableCommand, args: [String]) -> HostError? {
        let before = Array(args.prefix { $0 != "--" })
        guard before.contains(MacPlace.name), !takes.contains(ObjectIdentifier(type(of: command) as Any.Type)) else { return nil }
        let words = before.prefix { $0 != MacPlace.name }.filter { !$0.hasPrefix("-") }
        return MacPlace.refusal("doz " + (words.isEmpty ? "this command" : words.joined(separator: " ")))
    }

    /// "in NAME", or "on this Mac".
    static func inPlace(_ name: String) -> String { MacPlace.isPlace(name) ? "on this Mac" : "in \(name)" }

    /// A session's state in words (`doz sessions @mac`).
    static func state(_ s: SessionRow) -> String {
        var t = s.gone == true ? "gone (the Mac restarted, or its holder was killed)"
            : s.ended ? "ended (exit \(s.exitCode.map(String.init) ?? "?"))" : "running"
        if s.bypassed == true { t += " · " + MacPlace.bypassedMark }
        return t
    }

    /// `doz sessions @mac`'s table.
    static func table(_ rows: [SessionRow]) -> String {
        var t = [["SESSION", "PID", "STATE", "AGENT", "FOLDER", "COMMAND"]]
        for s in rows {
            t.append([s.name, s.pid.map(String.init) ?? "—", state(s), s.status?.label ?? "—",
                      s.workdir.map { DisplayPath.tilde($0) } ?? "—", s.command])
        }
        return Out.table(t)
    }
}
