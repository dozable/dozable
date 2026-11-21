import ArgumentParser
import DozableHost
import Foundation

// 747: `doz timeline` — this Mac's history as the timeline component reads it (the timeline/1 documents). Looking starts
// no daemon: with none running, the catalogue and queries are answered from the store's derived file in this process.

struct TimelineCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "timeline",
        abstract: "This Mac's history: what happened, where and when, kept on this Mac only.",
        discussion: "Every record Dozable keeps (actions, sessions, the daemon's runs and events, each sandbox's network, connections and samples, key use, workspace and permission logs, runs and their frames, chat times and Ask outcomes) as one history. Nothing leaves the Mac. How long each is kept: doz timeline retention.",
        subcommands: [TimelineCatalogCommand.self, TimelineQueryCommand.self, TimelineTailCommand.self, TimelineRetentionCommand.self,
                      TimelinePruneCommand.self, TimelineRebuildCommand.self],
        defaultSubcommand: TimelineCatalogCommand.self)
}

func timelineRequest(_ op: HostOp, _ t: TimelineRequest) throws -> HostRequest {
    var r = HostRequest(op)
    r.timeline = try JSONValue(encoding: t)
    return r
}

/// A query read from a file or stdin (`-`).
func readTimelineQuery(_ path: String, _ g: GlobalOptions) throws -> TimelineQuery {
    let data: Data
    if path == "-" { data = FileHandle.standardInput.readDataToEndOfFile() } else {
        guard let d = FileManager.default.contents(atPath: (path as NSString).expandingTildeInPath) else {
            throw fail(HostError(.notFound, "no file \(path)"), g)
        }
        data = d
    }
    guard data.count <= TimelineRequest.maximumBytes else { throw fail(HostError(.invalid, "a query is at most 256 KiB"), g) }
    do { return try HostWire.decoder.decode(TimelineQuery.self, from: data) } catch {
        throw fail(HostError(.invalid, "not a timeline/1 query: \(error.localizedDescription)"), g)
    }
}

func timelineTime(_ t: Int64) -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f.string(from: Date(timeIntervalSince1970: Double(t) / 1000))
}

func retentionWords(_ r: TimelineRetention) -> String {
    func d(_ x: Int?) -> String { x.map { "\($0)" } ?? "kept" }
    return "\(d(r.events))/\(d(r.m1))/\(d(r.h1))/\(d(r.d1))"
}

struct TimelineCatalogCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "catalog",
        abstract: "What this Mac keeps: its name, each source and how long it is kept.")
    @OptionGroup var g: GlobalOptions

    func run() async throws {
        let c = try decode(try await query(try timelineRequest(.timelineCatalog, TimelineRequest()), g), TimelineCatalog.self, g)
        if g.json { Out.json(c); return }
        Out.stdout("doz timeline — \(c.hosts.joined(separator: ", "))\n\n")
        var t = [["SOURCE", "KEPT", "DAYS (EVENTS/1M/1H/1D)", "SINCE"]]
        for s in c.sources {
            let r = c.retention.first { $0.source == s.name }
            t.append([s.name, s.status == "kept" ? "yes" : "not yet", r.map { retentionWords($0.retention) } ?? "—",
                      r?.keptFrom.events.map(timelineTime) ?? "—"])
        }
        Out.stdout(Out.table(t))
    }
}

struct TimelineQueryCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "query",
        abstract: "Answer a timeline/1 query (a JSON document) from a file, or - for stdin.")
    @OptionGroup var g: GlobalOptions
    @Argument(help: "The query's file, or - for stdin.") var file: String = "-"

    func run() async throws {
        let q = try readTimelineQuery(file, g)
        let res = try decode(try await query(try timelineRequest(.timelineQuery, TimelineRequest(query: q)), g), TimelineResult.self, g)
        if g.json { Out.json(res); return }
        Out.stdout("\(res.total) events · \(res.rows.count) rows" + (res.next == nil ? "" : " · more (pass next as the cursor)") + "\n")
        for w in res.warnings ?? [] { Out.stdout("note: \(w)\n") }
        for e in res.events ?? [] {
            Out.stdout("\(timelineTime(e.t))  \(e.severity.rawValue.padding(toLength: 7, withPad: " ", startingAt: 0))  \(e.kind)  \(TimelineScope.name(e.scope))  \(e.summary)\n")
        }
        for b in res.bins ?? [] { Out.stdout("\(timelineTime(b.t))  \(b.bin.rawValue)  \(TimelineScope.name(b.scope))  \(b.count)\n") }
    }
}

struct TimelineTailCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "tail",
        abstract: "Follow a query live: what is new or changed, as it happens (needs the daemon; starts none).")
    @OptionGroup var g: GlobalOptions
    @Argument(help: "The query's file, or - for stdin.") var file: String = "-"
    @Option(name: .long, help: "Resume after this token (a batch's resume).") var resume: String?

    func run() async throws {
        let q = try readTimelineQuery(file, g)
        guard g.dozableStore.hostIsRunning() else { throw fail(HostError(.unavailable, "the daemon is not running — doz daemon start"), g) }
        let client: HostClient
        do { client = try HostClient.connect(store: g.dozableStore, autostart: false) } catch {
            throw fail(HostError(.unavailable, error.localizedDescription), g)
        }
        try client.send(try timelineRequest(.timelineSubscribe, TimelineRequest(query: q, resume: resume)))
        while let m = try client.next() {
            if let e = m.error { throw fail(e, g) }
            guard let v = m.result else { continue }
            if v["reset"] != nil { if !g.json { Out.stdout("reset: query afresh\n") } else { Out.jsonLine(v) }; return }
            guard let b = try? v.decode(TimelineBatch.self) else { continue }
            if g.json { Out.jsonLine(b); continue }
            for e in b.events { Out.stdout("\(timelineTime(e.t))  \(e.kind)  \(TimelineScope.name(e.scope))  \(e.summary)\n") }
        }
    }
}

struct TimelineRetentionCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "retention",
        abstract: "How long each source is kept, what is held now, and the history file's size.",
        discussion: "Set a source's days with doz config set timeline.SOURCE EVENTS/1M/1H/1D (each a number of days, or kept).")
    @OptionGroup var g: GlobalOptions

    func run() async throws {
        let rep = try decode(try await query(try timelineRequest(.timelineRetention, TimelineRequest()), g), TimelineRetentionReport.self, g)
        if g.json { Out.json(rep); return }
        printRetention(rep)
    }
}

func printRetention(_ rep: TimelineRetentionReport) {
    var t = [["SOURCE", "SETTING", "DAYS (EVENTS/1M/1H/1D)", "SET BY", "SINCE"] + (rep.sources.contains { $0.removed != nil } ? ["REMOVED"] : [])]
    for s in rep.sources {
        var row = [s.source, s.setting, retentionWords(s.retention.retention), s.retention.setBy, s.retention.keptFrom.events.map(timelineTime) ?? "—"]
        if let r = s.removed { row.append(r.isEmpty ? "nothing" : r.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }.joined(separator: ", ")) }
        else if rep.sources.contains(where: { $0.removed != nil }) { row.append("nothing") }
        t.append(row)
    }
    Out.stdout(Out.table(t))
    Out.stdout("the history file: \(DozableImages.formatBytes(rep.bytes))" + (rep.indexing.map { " · indexing \($0)%" } ?? "") + "\n")
}

struct TimelinePruneCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "prune",
        abstract: "Remove what each source's retention no longer keeps (the daemon does this hourly); --dry-run shows it first.")
    @OptionGroup var g: GlobalOptions
    @Flag(name: .long, help: "Say what would be removed, and remove nothing.") var dryRun = false

    func run() async throws {
        let req = TimelineRequest(dryRun: dryRun ? true : nil, prune: dryRun ? nil : true)
        let v = dryRun ? try await query(try timelineRequest(.timelineRetention, req), g) : try call(try timelineRequest(.timelineRetention, req), g, autostart: false)
        let rep = try decode(v, TimelineRetentionReport.self, g)
        if g.json { Out.json(rep); return }
        printRetention(rep)
    }
}

struct TimelineRebuildCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rebuild",
        abstract: "Read every record again into the history file (needs the daemon). Removes nothing.",
        discussion: "--clean starts from an empty history file: what retention already removed from the records themselves is gone for good, and the counts kept for it are lost.")
    @OptionGroup var g: GlobalOptions
    @Flag(name: .long, help: "Start from an empty history file (asks first).") var clean = false
    @Flag(name: .long, help: "Do not ask.") var yes = false

    func run() async throws {
        guard g.dozableStore.hostIsRunning() else { throw fail(HostError(.unavailable, "a rebuild needs the daemon — doz daemon start"), g) }
        if clean {
            try confirm("Start the history file again from the records? The counts kept for time whose records are gone are lost.", yes: yes, g)
        }
        let rep = try decode(try call(try timelineRequest(.timelineRebuild, TimelineRequest(clean: clean ? true : nil)), g, autostart: false),
                             TimelineRetentionReport.self, g)
        if g.json { Out.json(rep); return }
        Out.stdout("rebuilt\n")
        printRetention(rep)
    }
}
