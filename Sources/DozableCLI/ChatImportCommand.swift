import ArgumentParser
import Darwin
import DozableChat
import DozableHost
import Foundation

// `doz chat import PATH` — another chat server's rooms and messages brought into this store's chat, from a copy made for
// import, so a conversation resumes here (docs/engineering/chat.md, "Importing a chat's history"). The import itself is
// the daemon's (`chat-import`, with chat off); `--dry-run` reads the copy here, in this process, and writes nothing.

struct ChatImportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "import",
        abstract: "Bring another chat server's rooms and messages in, from a copy made for import (chat must be off).",
        discussion: """
            PATH is a folder made by the other server's copy script: one file per room, the member lists, archived rooms, \
            holds, avatars, session links and attachments. A copy that holds tokens, webhook entries, registered sessions or \
            keys is refused, and nothing in the copy is ever changed.

            Names are never rewritten: you are the person the history names (a store whose person has another name is \
            refused), and everyone else it names must be in chat already (doz chat add NAME), or comes in without a token \
            with --add-missing. Nobody is woken: what was still waiting to be handed over is marked cancelled, and the \
            first start announces nothing. Held messages stay held until you post.

            This store's chat history is never merged or overwritten: an import over history needs --replace, which keeps \
            the earlier folder aside (data.before-import-…). Try it first with --dry-run.
            """)
    @Argument(help: "The copy made for import (a folder).") var path: String
    @Flag(name: .customLong("dry-run"), help: "Say what the import would do, and what stops it; write nothing and start nothing.") var dryRun = false
    @Flag(name: .customLong("add-missing"), help: "Add the names the history uses that are not in chat yet, without a token (doz chat token NAME --new gives one).") var addMissing = false
    @Flag(name: .long, help: "Import over this store's chat history: the earlier folder is kept aside, never deleted.") var replace = false
    @OptionGroup var g: GlobalOptions

    func run() async throws {
        let source = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
        let paths = ChatPaths(store: g.dozableStore)
        let report: ChatImportReport
        if dryRun {
            let on = ChatSettingsView.read().enabled || ChatServer.status(dataDir: paths.data, release: DozableCommand.version).running
            do { report = try ChatImporter.plan(paths: paths, source: source, addMissing: addMissing, replace: replace, chatOn: on).1 } catch let e as ChatImportRefusal {
                throw fail(HostError(.failed, ChatImporter.refusedText(e)), g)
            } catch let e as HostError { throw fail(e, g) }
        } else {
            var r = HostRequest(.chatImport)
            r.chat = ChatRequest(path: source, addMissing: addMissing ? true : nil, replace: replace ? true : nil)
            report = try decode(try call(r, g), ChatImportReport.self, g)
        }
        if g.json { Out.json(report) } else { Out.stdout(Self.text(report)) }
        if dryRun, let p = report.problems.first { throw ExitCode(DozableExit.code(for: p.error)) }
    }

    /// The report in a person's words: no token, no secret, no path but the copy's and the folder kept aside.
    static func text(_ r: ChatImportReport) -> String {
        let s = r.summary
        var o = (r.dryRun ? "A dry run — nothing was written. " : "") + "A copy made for import: \(DisplayPath.tilde(r.source))\n"
        func n(_ k: Int, _ w: String) -> String { "\(k) \(w)\(k == 1 ? "" : "s")" }
        for room in s.rooms {
            o += "  \(room.name)\(room.archived ? " (archived)" : ""): \(n(room.messages, "message")), \(n(room.attachments, "attachment"))"
            o += room.members.isEmpty ? ", no members" : ", members \(room.members.joined(separator: ", "))"
            if let h = room.hold { o += h == 0 ? "; hold off" : "; hold \(h)" }
            if room.held > 0 { o += "; \(n(room.held, "message")) held back until you post" }
            o += "\n"
        }
        o += "  \(n(s.rooms.count, "room")), \(n(s.messages, "message")), \(n(s.files, "attachment file"))\n"
        if let h = r.human {
            o += r.namesYou ? "  You are \(h) in chat — the name the history has.\n" : "  You: \(h)\n"
        }
        if !r.missing.isEmpty {
            if r.added.isEmpty {
                o += "  Not in chat here yet: \(r.missing.map(\.name).joined(separator: ", ")). Add them first:\n"
                for c in r.addCommands { o += "    \(c)\n" }
                o += "  (or --add-missing: added without a token; doz chat token NAME --new gives one later)\n"
            } else {
                o += "  Added without a token: \(r.added.joined(separator: ", ")) (doz chat token NAME --new gives one)\n"
            }
        }
        let cancelled = r.cancelled.filter { $0.value > 0 }.sorted { $0.key < $1.key }
        if !cancelled.isEmpty {
            o += "  Not handed over again, marked cancelled: " + cancelled.map { "\(n($0.value, "message")) for \($0.key)" }.joined(separator: ", ") + "\n"
        }
        for d in s.dropped { o += "  Dropped: \(d)\n" }
        if !s.ignored.isEmpty { o += "  Ignored: \(s.ignored.joined(separator: ", "))\n" }
        switch r.existing {
        case "history": o += "  This store's chat has history (\(n(r.existingMessages, "message")), \(n(r.existingFiles, "attachment")))" + (r.imported ? "" : (r.problems.contains { $0.kind == "history" } ? "" : ": kept aside with --replace")) + "\n"
        case "empty": o += "  This store's chat has no history yet.\n"
        case "unknown": o += "  This store's chat: not looked at while chat is on.\n"
        default: break
        }
        for p in r.problems { o += "  Stops the import: \(p.text)\n" }
        if r.imported {
            o += "Imported \(n(s.rooms.count, "room")), \(n(s.messages, "message")) and \(n(s.files, "attachment file")).\n"
            if let k = r.keptAs { o += "The earlier chat data is kept in \(DisplayPath.tilde(k)).\n" }
            o += "Turn chat on with doz chat on.\n"
        } else if r.dryRun && r.problems.isEmpty {
            o += "The import would go ahead: doz chat import \(DisplayPath.tilde(r.source))\(r.added.isEmpty ? "" : " --add-missing")\(r.existing == "history" ? " --replace" : "")\n"
        }
        return o
    }
}
