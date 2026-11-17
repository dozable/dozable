import Darwin
import DozableChat
import Foundation

// `doz chat import PATH`: another chat server's history brought into this store's chat (docs/engineering/chat.md,
// "Importing a chat's history"). `ChatImport` (DozableChat) reads and checks the copy and stages it; this side compares
// its names with Dozable's directory and puts the staged folder in place — run by the daemon on the supervisor's queue,
// with chat off (`ChatSupervisor.importCopy`); the dry run is the same plan, in-process, writing nothing.
//
// - Names are never rewritten. The person is the one the history's human messages name: the store's human when it has
//   one (another name refuses the import), else it becomes the store's human. Every other name the history uses must be
//   a participant already — or, with `--add-missing`, is added as a TOKENLESS participant of the kind its messages show
//   (it keeps its rooms and cannot connect until `doz chat token NAME --new`).
// - The store's data folder is never deleted and never merged: one that holds history refuses the import unless
//   `--replace`; then (or when it holds nothing but the first start's own lines) it is renamed aside to
//   `data.before-import-<UTC>`, and the staged folder (`<store>/chat/.import-<random>`) is renamed into its place.
// - `imported.json` in the chat folder records when, the counts and each room file's SHA-256 — nothing secret.

/// Something that stops a real import (a dry run lists them all).
public struct ChatImportProblem: Codable, Sendable, Equatable {
    /// `chat-on`, `person`, `missing` or `history`.
    public var kind: String
    public var text: String

    public var error: HostError {
        switch kind {
        case "chat-on": HostError(.unavailable, text)
        case "missing": HostError(.notFound, text)
        case "history": HostError(.exists, text)
        default: HostError(.failed, text)
        }
    }
}

/// What an import of a copy does (`--dry-run`) or did. Never a token or a secret.
public struct ChatImportReport: Codable, Sendable, Equatable {
    public var dryRun: Bool
    public var source: String
    public var summary: ChatImportSummary
    /// You, in chat, after it: the history's person (or the store's, when the history names none).
    public var human: String?
    /// The import names you: this store had no one yet.
    public var namesYou = false
    /// Names the history uses that are not in this store's chat, each with the command that adds it.
    public var missing: [ChatImportName] = []
    public var addCommands: [String] = []
    /// `--add-missing`: added without a token.
    public var added: [String] = []
    /// Per recipient (never you): what is marked cancelled — it was waiting, and is not handed over again.
    public var cancelled: [String: Int] = [:]
    public var chatOn = false
    /// This store's data folder: `none` (no folder), `empty` (the first start's lines only), `history`, or `unknown`
    /// (chat is on).
    public var existing = "none"
    public var existingMessages = 0
    public var existingFiles = 0
    /// The earlier data folder, renamed aside (an import that replaced one).
    public var keptAs: String?
    public var problems: [ChatImportProblem] = []
    public var imported = false
}

/// `imported.json`: the last import's record.
public struct ChatImportRecord: Codable, Sendable, Equatable {
    public struct Room: Codable, Sendable, Equatable { public var name: String; public var messages: Int; public var sha256: String? }
    public var version = 1
    public var at: String
    public var source: String
    public var human: String
    public var rooms: [Room]
    public var messages: Int
    public var files: Int
    public var cancelled: [String: Int]
    public var notices: Int
    public var added: [String]
    public var keptAs: String?
}

public enum ChatImporter {
    /// Reads the copy and compares it with this store's chat. A copy that is refused throws (`ChatImportRefusal`); what
    /// would stop the import is in `problems`.
    public static func plan(paths: ChatPaths, source: String, addMissing: Bool, replace: Bool, chatOn: Bool) throws -> (ChatImportCopy, ChatImportReport) {
        let copy = try ChatImport.read(source)
        let s = copy.summary
        var r = ChatImportReport(dryRun: true, source: source, summary: s)
        r.chatOn = chatOn
        if chatOn {
            r.problems.append(ChatImportProblem(kind: "chat-on", text: "chat is on — doz chat off first (an import never runs beside the chat server)"))
        }
        let d = try ChatDirectory.load(paths)
        // The person.
        switch (s.human, d.human) {
        case let (h?, mine?) where h != mine:
            r.problems.append(ChatImportProblem(kind: "person", text: "names are never rewritten; this store's chat is yours as \(mine), and the history's person is \(h)"))
            r.human = mine
        case let (h?, mine):
            r.human = h
            if mine == nil {
                if d.participants.contains(where: { $0.name == h }) {
                    r.problems.append(ChatImportProblem(kind: "person", text: "\(h) is the history's person, but here \(h) is a participant, not you — names are never rewritten"))
                } else if let why = ChatNames.refusal(h) {
                    r.problems.append(ChatImportProblem(kind: "person", text: why))
                } else {
                    r.namesYou = true
                }
            }
        case let (nil, mine?):
            r.human = mine
        case (nil, nil):
            r.problems.append(ChatImportProblem(kind: "person", text: "the copy names no person (no message in it is from a human): turn chat on once with doz chat on --name NAME (your name in the history), then doz chat off, and import again"))
        }
        // Everyone else.
        r.missing = s.names.filter { $0.name != r.human && !d.has($0.name) }
        r.addCommands = r.missing.map { n in
            "doz chat add \(n.name)" + (n.kind == "agent" ? "" : " --kind \(n.kind)") + (n.webhook ? " --webhook" : "") + " --to-file \(n.name).token"
        }
        if !r.missing.isEmpty && !addMissing {
            r.problems.append(ChatImportProblem(kind: "missing", text: "the history names \(r.missing.map(\.name).joined(separator: ", ")), not in chat here: add them first (\(r.addCommands.joined(separator: "; "))), or import with --add-missing to add them without a token"))
        }
        if addMissing { r.added = r.missing.map(\.name) }
        r.cancelled = s.waiting.filter { $0.key != r.human }
        // This store's data folder.
        var st = stat()
        if lstat(paths.data, &st) == 0 {
            if chatOn {
                r.existing = "unknown"
            } else {
                let h = ChatImport.hasHistory(paths.data)
                r.existing = h.history ? "history" : "empty"
                r.existingMessages = h.messages
                r.existingFiles = h.files
                if h.history && !replace {
                    r.problems.append(ChatImportProblem(kind: "history", text: "this store's chat already has history (\(h.messages) message\(h.messages == 1 ? "" : "s"), \(h.files) attachment\(h.files == 1 ? "" : "s")): it is never merged or overwritten — import with --replace to keep it aside as data.before-import-… and bring the copy in"))
                }
            }
        }
        return (copy, r)
    }

    /// The import itself — the daemon's, with chat off. Throws the first problem; nothing is changed then.
    public static func run(paths: ChatPaths, source: String, addMissing: Bool, replace: Bool, now: Date = Date()) throws -> ChatImportReport {
        try paths.ensureFolder()
        let copy: ChatImportCopy, planned: ChatImportReport
        do { (copy, planned) = try plan(paths: paths, source: source, addMissing: addMissing, replace: replace, chatOn: false) } catch let e as ChatImportRefusal {
            throw HostError(.failed, refusedText(e))
        }
        var r = planned
        r.dryRun = false
        if let p = r.problems.first { throw p.error }
        guard let human = r.human else { throw HostError(.failed, "no person") }

        // Stage.
        let staging = (paths.folder as NSString).appendingPathComponent(".import-" + String(format: "%08x%08x", arc4random(), arc4random()))
        let staged: ChatImportStaged
        do { staged = try ChatImport.stage(copy, into: staging, human: human) } catch {
            try? FileManager.default.removeItem(atPath: staging)
            throw HostError(.failed, "the copy could not be staged: \(error)")
        }
        r.cancelled = staged.cancelled

        // The directory: you, and (--add-missing) the names added without a token.
        let oldDirectory = FileManager.default.contents(atPath: paths.directory)
        var d = try ChatDirectory.load(paths)
        if d.human == nil { d.human = human }
        let at = isoTime(now)
        for n in r.missing where addMissing { d.participants.append(.init(name: n.name, kind: n.kind, added: at)) }
        func undoDirectory() {
            if let oldDirectory { try? paths.write("directory.json", oldDirectory) } else { unlink(paths.directory) }
        }
        do { try paths.write("directory.json", d.bytes()) } catch {
            try? FileManager.default.removeItem(atPath: staging)
            throw error
        }

        // The earlier data folder aside (never deleted), the staged one in its place.
        var keptAs: String?
        var st = stat()
        if lstat(paths.data, &st) == 0 {
            let base = "data.before-import-" + compactTime(now)
            var name = base, i = 2
            while lstat((paths.folder as NSString).appendingPathComponent(name), &st) == 0 { name = base + "-\(i)"; i += 1 }
            let aside = (paths.folder as NSString).appendingPathComponent(name)
            guard rename(paths.data, aside) == 0 else {
                let why = String(cString: strerror(errno))
                undoDirectory()
                try? FileManager.default.removeItem(atPath: staging)
                throw HostError(.failed, "the chat data folder could not be put aside: \(why)")
            }
            keptAs = aside
        }
        guard rename(staging, paths.data) == 0 else {
            let why = String(cString: strerror(errno))
            if let keptAs { rename(keptAs, paths.data) }
            undoDirectory()
            try? FileManager.default.removeItem(atPath: staging)
            throw HostError(.failed, "the imported folder could not be put in place: \(why)")
        }
        r.keptAs = keptAs
        r.imported = true

        let record = ChatImportRecord(at: at, source: source, human: human,
                                      rooms: r.summary.rooms.map { .init(name: $0.name, messages: $0.messages, sha256: $0.sha256) },
                                      messages: r.summary.messages, files: r.summary.files, cancelled: staged.cancelled, notices: staged.notices,
                                      added: addMissing ? r.added : [], keptAs: keptAs.map { ($0 as NSString).lastPathComponent })
        if let data = try? ChatDirectory.encoder.encode(record) { try? paths.write("imported.json", data + Data("\n".utf8)) }
        return r
    }

    /// A refused copy, in the words every command says it.
    public static func refusedText(_ e: ChatImportRefusal) -> String { "the copy is refused, nothing was written: \(e.description)" }

    static func isoTime(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }

    /// `20261117T231500Z`.
    static func compactTime(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f.string(from: d)
    }
}
