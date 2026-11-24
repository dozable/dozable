import ArgumentParser
import DozableChat
import DozableHost
import Foundation

// FEEDS: `doz workspace feeds W` — the routes in effect (where each feed's notices go), `--dry-run --kind K --severity S`
// (where one notice would go), and `--emit KIND …` (a notice from the `test` feed, posted as Dozable would: a way to check
// the routes). The routes are the owner's; the emit needs the daemon. Feeds.swift, HostCore+Feeds.swift.

struct WorkspaceFeedsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "feeds", abstract: "Where a workspace's notices go: its feeds and their routes.",
        discussion: """
        A feed posts notices: the run journal (an outcome or a failing review — never working notes), this Mac's accounts, \
        network, health and resources. By default the journal goes to the room; the others go to the manager as a direct \
        message — to you instead when there is no manager or more than one (fallback says why) — and a critical one also \
        to your Needs you. A space file changes a route: x-dozable: { feeds: { journal: { to: off } } } (room, manager, \
        owner or off).

        --dry-run --kind KIND --severity S says where one notice would go, and posts nothing. --emit KIND posts a notice \
        from the test feed as Dozable would post one of its own (with --severity, --dedupe, --to NAME or owner, --text, \
        --action-command): the same dedupe inside its window posts once, and a feed posts at most 5 notices a minute. \
        An action's command is one of Dozable's own read commands (doz workspace feeds W, doz account ls, dozchat \
        receive, …) — never a shell line.

        --json answers {kind: WorkspaceFeeds, workspace, room, feeds: [{name, to, manager?, fallback?, critical?, from}], \
        needsYou?}; a dry run {kind: FeedPlan, feed, notice, to, recipients, direct, fallback?}; an emit {kind: FeedNotice, \
        result: posted | repeated | rate-limited | off, msgId?, plan, session?}. Looking never starts the daemon. Exit \
        codes: 0 · 2 no such workspace · 3 no room · 6 chat is not ready, or no daemon (--emit) · 64 usage · 65 a kind, \
        severity or command that is not one.
        """)
    @OptionGroup var g: GlobalOptions
    @Argument(help: "The workspace.") var name: String
    @Flag(name: .customLong("dry-run"), help: "Say where one notice would go (with --kind and --severity); post nothing.") var dryRun = false
    @Option(name: .long, help: "With --dry-run: the notice's kind, FAMILY.WHAT (account.expired, health.crashed, resources.disk).") var kind: String?
    @Option(name: .long, help: "The notice's severity: info, notice, warning or critical.") var severity: String?
    @Option(name: .long, help: "Post a notice of this kind from the test feed, as Dozable would.") var emit: String?
    @Option(name: .long, help: "With --emit: its dedupe (the same one inside its window posts once).") var dedupe: String?
    @Option(name: .long, help: "With --emit or --dry-run: the participant it is for alone (owner: you).") var to: String?
    @Option(name: .long, help: "With --emit: its text.") var text: String?
    @Option(name: .customLong("action-command"), help: "With --emit: a command to look further (Dozable's own read commands only).") var actionCommand: String?

    func validate() throws {
        if dryRun && emit != nil { throw ValidationError("one of --dry-run or --emit") }
        if dryRun && kind == nil { throw ValidationError("--dry-run needs --kind KIND") }
        if emit == nil && (dedupe != nil || text != nil || actionCommand != nil) { throw ValidationError("--dedupe, --text and --action-command go with --emit") }
        if !dryRun && emit == nil && (kind != nil || severity != nil || to != nil) { throw ValidationError("--kind, --severity and --to go with --dry-run or --emit") }
    }

    func run() async throws {
        var w = WorkspaceRequest(name: name)
        var f = FeedsRequest()
        f.severity = severity
        f.to = to
        if let e = emit {
            f.emit = e
            f.dedupe = dedupe
            f.text = text
            f.actionCommand = actionCommand
            if let c = actionCommand, let why = ChatNoticeCommand.refusal(c) { throw fail(HostError(.invalidValue, why), g) }
            w.feeds = f
            let out = try decode(try call(workspaceRequest(.workspaceFeedsEmit, w), g), FeedEmitted.self, g)
            if g.json { Out.json(out); return }
            switch out.result {
            case "posted": Out.stdout("\(name): the notice was posted → \(out.plan.to.joined(separator: ", "))\(out.plan.fallback.map { " (\($0))" } ?? "")\n")
            case "off": Out.stdout("\(name): the \(out.plan.feed) feed is off here: nothing was posted\n")
            default: Out.stdout("\(name): not posted (\(out.result))\n")
            }
            if let s = out.session { Out.stdout("its session: \(s)\n") }
            for n in out.notes ?? [] { Out.stdout("note: \(n)\n") }
            return
        }
        if dryRun {
            f.dryRun = true
            f.kind = kind
            w.feeds = f
            let p = try decode(try await query(workspaceRequest(.workspaceFeeds, w), g), FeedPlan.self, g)
            if g.json { Out.json(p); return }
            Out.stdout(p.to.isEmpty ? "\(name): a \(p.notice.kind) notice would go nowhere (the \(p.feed) feed is off)\n"
                       : "\(name): a \(p.notice.severity) \(p.notice.kind) notice would go to \(p.to.joined(separator: ", "))"
                       + (p.recipients.isEmpty ? "" : " (\(p.recipients.joined(separator: ", ")))") + "\n")
            if let fb = p.fallback { Out.stdout("fallback: \(fb)\n") }
            for n in p.notes ?? [] { Out.stdout("note: \(n)\n") }
            return
        }
        let l = try decode(try await query(workspaceRequest(.workspaceFeeds, w), g), WorkspaceFeeds.self, g)
        if g.json { Out.json(l); return }
        var t = [["FEED", "TO", "CRITICAL ALSO", "FROM"]]
        for r in l.feeds {
            t.append([r.name, r.to == "manager" ? "manager (\(r.manager ?? "?"))" : r.to, (r.critical ?? []).joined(separator: ", "), r.from])
        }
        Out.stdout(Out.table(t))
        let fallbacks = Set(l.feeds.compactMap(\.fallback))
        for fb in fallbacks.sorted() { Out.stdout("fallback: \(fb)\n") }
        for n in l.notes ?? [] { Out.stdout("note: \(n)\n") }
        if let ny = l.needsYou, !ny.isEmpty {
            Out.stdout("Needs you:\n")
            for x in ny { Out.stdout("  \(x.title)\(x.text.map { " — \($0)" } ?? "")\n") }
        }
    }
}
