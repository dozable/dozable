import ArgumentParser
import Darwin
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

    /// `doz ls`'s last line — nil when this Mac holds no session (read from the socket folder: no host is asked).
    static func summaryLine(_ store: DozableStore) async -> String? {
        let rows = await MacSessions(store: store, readOnly: true).rows()
        guard !rows.isEmpty else { return nil }
        let running = rows.filter { !$0.ended }.count
        let gone = rows.filter { $0.gone == true }.count
        let ended = rows.count - running - gone
        var parts = ["\(running) session\(running == 1 ? "" : "s") running"]
        if gone > 0 { parts.append("\(gone) gone") }
        if ended > 0 { parts.append("\(ended) ended") }
        return "this Mac: " + parts.joined(separator: ", ") + " (no isolation) — doz sessions @mac"
    }

    /// The sessions on this Mac that run now (read from the socket folder; no host asked).
    static func running(_ store: DozableStore) async -> [String] {
        await MacSessions(store: store, readOnly: true).rows().filter { !$0.ended }.map(\.name)
    }

    /// End each through the host (`session-end`; a host is started when none runs). Returns the ones that ended.
    static func endAll(_ names: [String], _ g: GlobalOptions) -> [String] {
        var ended: [String] = []
        for s in names {
            var r = HostRequest(.sessionEnd, name: MacPlace.name)
            r.session = s
            if let m = try? HostClient.request(r, store: g.dozableStore, autostart: true), m.ok == true { ended.append(s) }
        }
        return ended
    }

    /// Remove the store's socket folder — only when it is ours (a folder, not a link, our own, 0700).
    static func removeSocketFolder(_ store: DozableStore) {
        let dir = MacPlace.socketDirectory(store: store)
        guard MacPlace.folderProblem(dir) == nil else { return }
        try? FileManager.default.removeItem(atPath: dir)
    }

    /// Ask on the terminal; no terminal: no.
    static func ask(_ question: String) -> Bool {
        let fd = open("/dev/tty", O_RDWR)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        let prompt = "\(question) [y/N] "
        _ = prompt.withCString { write(fd, $0, strlen($0)) }
        var buf = [UInt8](repeating: 0, count: 64)
        let n = read(fd, &buf, buf.count)
        let a = n > 0 ? String(decoding: buf[0..<n], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() : ""
        return a == "y" || a == "yes"
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
