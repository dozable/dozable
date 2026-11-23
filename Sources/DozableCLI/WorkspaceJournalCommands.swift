import ArgumentParser
import Darwin
import DozableChat
import DozableHost
import Foundation

// The run journal, journal/1: `doz workspace journal W [RUN]` reads a run's entries, `journal W add KIND [TEXT] …` appends
// one to the open run, `journal W --follow` streams the workspace's lines (NDJSON, one flushed per line), and `doz workspace
// wait W --for journal.KIND` waits for an entry (level-triggered). docs/engineering/journal.md.

struct WorkspaceJournalCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "journal", abstract: "Read, write or follow a run's journal.",
        discussion: """
        Each run of a workspace has one journal: an append-only, ordered list of entries. Dozable sets each entry's id \
        (RUN#SEQ), seq, at and by (you are owner); nothing is ever edited.

          doz workspace journal W [RUN] --json     a run's entries (the open run by default, or any run, archived ones \
        included): {kind: WorkspaceJournal, format: journal/1, workspace, run, open, entries}, a corrected entry marked \
        superseded_by.
          doz workspace journal W add KIND [TEXT] [--data JSON] [--ref R]… [--attach FILE]… [--attach-ref FILE]… \
        [--supersedes N] --json     appends an entry to the open run and answers it. KIND is a-z 0-9 . _ - (gate, hook \
        and dozable.* are Dozable's own). A correction (--supersedes N) has the kind of entry N and is its author's, or \
        needs journal.supersede. --attach copies a file from the run's folders into its evidence (10 MiB a file, 200 MiB a \
        run) and hashes it; --attach-ref hashes a large one in place. Refs: seq:N, entry:RUN#SEQ, msg:SEQ, \
        commit:SHA[@FOLDER], url:URL.
          doz workspace journal W --follow [--after-wseq N | --after RUN#SEQ] [--until-finish] --json     the \
        workspace's lines as they happen, one JSON object a line: hello, then entry, run and workspace lines (each with its \
        wseq), a heartbeat every 30 s, end on a clean close. Resume with the last wseq (or entry id) you saw. Needs the \
        daemon running and never starts it (exit 3, no-daemon).

        An agent acting with --as W/AGENT needs journal.read to read (on by default in its own workspace), journal.write \
        or journal.write:KIND to write, evidence.attach to attach. Exit codes: 0 · 2 no such workspace or run · 3 \
        no-open-run, run-closed, no-daemon · 8 limited · 9 not permitted · 64 usage · 65 invalid (a kind, data, ref, \
        correction or an unknown cursor).
        """)
    @OptionGroup var g: GlobalOptions
    @Argument(help: "The workspace.") var name: String
    @Argument(help: "A run (to read), or: add KIND [TEXT] (to write).") var words: [String] = []
    @Option(name: .customLong("data"), help: "add: the entry's data, a JSON object.") var data: String?
    @Option(name: .customLong("ref"), help: "add: a reference (seq:N, entry:RUN#SEQ, msg:SEQ, commit:SHA[@FOLDER], url:URL); repeatable.") var refs: [String] = []
    @Option(name: .customLong("attach"), help: "add: a file in the run's folders, copied into its evidence and hashed; repeatable.") var attach: [String] = []
    @Option(name: .customLong("attach-ref"), help: "add: a large file in the run's folders, hashed in place (not copied); repeatable.") var attachRef: [String] = []
    @Option(name: .customLong("supersedes"), help: "add: the seq of the entry this one corrects (same kind).") var supersedes: Int?
    @Flag(name: .customLong("follow"), help: "Stream the workspace's lines as they happen (needs the daemon running).") var follow = false
    @Option(name: .customLong("after"), help: "--follow: resume after this entry (RUN#SEQ): its entries only.") var after: String?
    @Option(name: .customLong("after-wseq"), help: "--follow: resume after this line of the workspace's follow (its wseq; 0: from the start).") var afterWseq: Int64?
    @Flag(name: .customLong("until-finish"), help: "--follow: end when the run that is open now finishes.") var untilFinish = false

    func run() async throws {
        if words.first == "add" { return try add() }
        if follow { return try followLines() }
        if data != nil || !refs.isEmpty || !attach.isEmpty || !attachRef.isEmpty || supersedes != nil {
            throw fail(HostError(.usage, "--data, --ref, --attach, --attach-ref and --supersedes go with add: doz workspace journal \(name) add KIND [TEXT]"), g)
        }
        if after != nil || afterWseq != nil || untilFinish {
            throw fail(HostError(.usage, "--after, --after-wseq and --until-finish go with --follow"), g)
        }
        guard words.count <= 1 else { throw fail(HostError(.usage, "doz workspace journal W [RUN] — one run at most"), g) }
        var w = WorkspaceRequest(name: name)
        var j = WorkspaceJournalRequest()
        j.run = words.first
        w.journal = j
        let v = try await query(workspaceRequest(.workspaceJournal, w), g)
        let wj = try decode(v, WorkspaceJournal.self, g)
        if g.json { Out.json(wj); return }
        guard let run = wj.run else { Out.stdout("\(wj.workspace) has no run yet\n"); return }
        Out.stdout("\(wj.workspace) · run \(run) (\(wj.open ? "open" : "closed")) · \(wj.entries.count) entr\(wj.entries.count == 1 ? "y" : "ies")\n")
        for e in wj.entries { Out.stdout(journalLine(e)) }
    }

    /// `add KIND [TEXT]`.
    func add() throws {
        if follow || after != nil || afterWseq != nil || untilFinish {
            throw fail(HostError(.usage, "add writes one entry: --follow and its cursors are for reading"), g)
        }
        guard words.count >= 2, words.count <= 3 else {
            throw fail(HostError(.usage, "doz workspace journal \(name) add KIND [TEXT] — a kind, then at most one text (quote it)"), g)
        }
        let kind = words[1]
        do { try JournalKinds.check(kind) } catch let e as HostError { throw fail(e, g) }
        var j = WorkspaceJournalRequest()
        j.kind = kind
        j.text = words.count == 3 ? words[2] : nil
        if let d = data {
            guard let v = try? HostWire.decoder.decode(JSONValue.self, from: Data(d.utf8)), case .object = v else {
                throw fail(HostError(.invalidValue, "--data is a JSON object: '{\"criterion\":\"c1\",\"met\":\"yes\"}'"), g)
            }
            j.data = v
        }
        j.refs = refs.isEmpty ? nil : refs
        j.attach = attach.isEmpty ? nil : attach.map(absolute)
        j.attachRef = attachRef.isEmpty ? nil : attachRef.map(absolute)
        j.supersedes = supersedes
        var w = WorkspaceRequest(name: name)
        w.journal = j
        let e = try decode(try call(workspaceRequest(.workspaceJournalAdd, w), g), JournalEntry.self, g)
        if g.json { Out.json(e); return }
        Out.stdout("\(name): \(e.id) \(e.kind)" + (e.supersedes.map { " (corrects \($0))" } ?? "") + (e.swept == true ? " — a chat token in it was removed" : "") + "\n")
    }

    func absolute(_ p: String) -> String {
        URL(fileURLWithPath: (p as NSString).expandingTildeInPath, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
            .standardizedFileURL.path
    }

    /// `--follow`: the daemon's stream, each line printed and flushed as it comes. Never starts a daemon.
    func followLines() throws {
        if words.count > 0 { throw fail(HostError(.usage, "--follow follows the whole workspace: no RUN (resume with --after RUN#SEQ)"), g) }
        if after != nil, afterWseq != nil { throw fail(HostError(.usage, "--after-wseq or --after, not both"), g) }
        let client = try connectNoStart(g)
        var w = WorkspaceRequest(name: name)
        var j = WorkspaceJournalRequest()
        j.after = after
        j.afterWseq = afterWseq
        j.untilFinish = untilFinish ? true : nil
        w.journal = j
        try client.send(workspaceRequest(.workspaceJournalFollow, w))
        while let m = try client.next() {
            if let e = m.error { throw fail(e, g) }
            guard let v = m.result else { continue }
            if g.json { Out.jsonLine(v); continue }
            Out.stdout(followText(v))
        }
    }
}

/// A connection to a running daemon — none is started (exit 3, `no-daemon`, the fix `doz daemon start`).
func connectNoStart(_ g: GlobalOptions) throws -> HostClient {
    let fix = ["doz", "daemon", "start"]
    guard g.dozableStore.hostIsRunning() else {
        throw fail(HostError(.noDaemon, "the daemon is not running, and following or waiting never starts it — doz daemon start"), g, fix: fix)
    }
    do { return try HostClient.connect(store: g.dozableStore, autostart: false) } catch {
        throw fail(HostError(.noDaemon, "the daemon is not answering — doz daemon start"), g, fix: fix)
    }
}

/// One entry as a person reads it.
func journalLine(_ e: JournalEntry) -> String {
    var s = "  #\(e.seq) \(e.at) \(e.by) \(e.kind)"
    if let t = e.text { s += ": " + (t.count > 160 ? String(t.prefix(160)) + "…" : t).replacingOccurrences(of: "\n", with: " ") }
    if let n = e.supersedes { s += " (corrects #\(n))" }
    if let n = e.supersededBy { s += " [corrected by #\(n)]" }
    if let ev = e.evidence, !ev.isEmpty { s += " · " + ev.map { "\($0.ref) \($0.sha256.prefix(12))" + ($0.copied == false ? " (not copied)" : "") }.joined(separator: ", ") }
    return s + "\n"
}

/// A follow line as a person reads it.
func followText(_ v: JSONValue) -> String {
    switch v["type"]?.stringValue {
    case "hello": return "following \(v["workspace"]?.stringValue ?? "") (\(JournalFormat.format))\n"
    case "entry":
        if let e = try? v["entry"]?.decode(JournalEntry.self) { return journalLine(e) }
        return ""
    case "run": return "run \(v["run"]?.stringValue ?? "") \(v["event"]?.stringValue ?? "")\n"
    case "workspace": return "\(v["event"]?.stringValue ?? "")" + (v["proposal"]?.stringValue.map { " \($0)" } ?? "") + "\n"
    case "end": return "end: \(v["reason"]?.stringValue ?? "")\n"
    case "error": return "error: \(v["code"]?.stringValue ?? "")\n"
    default: return ""
    }
}

struct WorkspaceWaitCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "wait", abstract: "Wait for a journal entry, or for a workspace to be ready.",
        discussion: """
        --for journal.KIND waits for an entry of that kind in the open run, and is level-triggered: one already written \
        matches at once (corrected entries do not count — their correction does). With --after RUN#SEQ only entries after \
        that point match, so an action and the wait after it never race. It prints the entry (--json: the entry itself) and \
        exits 0; on --timeout it exits 124. --for ready waits until every agent of the workspace is running and prints its \
        state. Waiting on the journal needs the daemon running and never starts it (exit 3, no-daemon); an agent acting with \
        --as W/AGENT needs journal.read. Exit codes: 0 · 2 no such workspace · 3 no-daemon · 9 not permitted · 64 usage · \
        65 an unknown --after or kind · 124 timed out.
        """)
    @OptionGroup var g: GlobalOptions
    @Argument(help: "The workspace.") var name: String
    @Option(name: .customLong("for"), help: "journal.KIND (an entry of that kind), or ready (every agent running).") var what: String
    @Option(name: .customLong("after"), help: "journal.KIND: only entries after this one (RUN#SEQ).") var after: String?
    @Option(name: .customLong("timeout"), help: "Give up after this many seconds (exit 124).") var timeout: Double?

    func run() async throws {
        if let t = timeout, t < 0 { throw fail(HostError(.usage, "--timeout is a number of seconds"), g) }
        let deadline = timeout.map { Date().addingTimeInterval($0) }
        if what == "ready" {
            if after != nil { throw fail(HostError(.usage, "--after goes with --for journal.KIND"), g) }
            return try await waitReady(deadline)
        }
        guard what.hasPrefix("journal.") else {
            throw fail(HostError(.usage, "--for journal.KIND (an entry of that kind) or --for ready"), g)
        }
        let kind = String(what.dropFirst("journal.".count))
        guard JournalKinds.isValid(kind) else { throw fail(HostError(.invalidValue, "\(kind.prefix(70)) is not a kind"), g) }
        _ = try connectNoStart(g)
        var w = WorkspaceRequest(name: name)
        var j = WorkspaceJournalRequest()
        j.kind = kind
        j.after = after
        w.journal = j
        while true {
            let v = try call(workspaceRequest(.workspaceJournal, w), g, autostart: false)
            let wj = try decode(v, WorkspaceJournal.self, g)
            if let e = wj.entries.first {
                if g.json { Out.json(e); return }
                Out.stdout(journalLine(e))
                return
            }
            if let d = deadline, Date() >= d {
                throw fail(HostError(.timedOut, "no \(kind) entry in \(name)'s open run within \(timeout.map { String(format: "%g", $0) } ?? "") s"), g)
            }
            usleep(250_000)
        }
    }

    /// `--for ready`: every agent running (the state's `ready`).
    func waitReady(_ deadline: Date?) async throws {
        var req = WorkspaceRequest(name: name)
        req.withConditions = true
        while true {
            let s = try decode(try await query(workspaceRequest(.workspaceState, req), g), SpaceState.self, g)
            let ready = s.agentConditions?.ready == true
            if ready || (deadline.map { Date() >= $0 } ?? false) {
                if !ready {
                    if g.json {
                        Out.stdout(String(decoding: ChatJSON.encodeIndented(s.stateAnswer(), indent: "  "), as: UTF8.self) + "\n")
                        throw ExitCode(ExitCodes.timedOut)
                    }
                    throw fail(HostError(.timedOut, "\(name) is not ready: not every agent is running"), g)
                }
                if g.json { Out.stdout(String(decoding: ChatJSON.encodeIndented(s.stateAnswer(), indent: "  "), as: UTF8.self) + "\n"); return }
                Out.stdout("\(name) is ready: every agent is running\n")
                return
            }
            usleep(500_000)
        }
    }
}
