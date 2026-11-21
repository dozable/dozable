import Foundation

// 747: the sources this Mac keeps, as the timeline catalogue names them — the contract's list, with the four records
// Dozable now keeps (the daemon's events, each connection, resource samples, key use) marked kept. Kinds and attrs are
// the contract's: the schema checks that each source's events use only its own. Sensitive attrs (a host, a folder, free
// text) are stored apart (`sattrs`) and never searched as text, summarised or rolled up.

public enum TimelineSources {
    static func days(_ e: Int?, _ m: Int?, _ h: Int?, _ d: Int?) -> TimelineRetention { TimelineRetention(events: e, m1: m, h1: h, d1: d) }
    static let usual = days(30, 30, 365, nil)
    static func counter(_ n: String, _ title: String, _ at: String, _ unit: String = "count") -> TimelineSeriesInfo {
        TimelineSeriesInfo(name: n, unit: unit, type: "counter", at: at, title: title)
    }
    static func gauge(_ n: String, _ title: String, _ at: String, _ unit: String) -> TimelineSeriesInfo {
        TimelineSeriesInfo(name: n, unit: unit, type: "gauge", at: at, title: title)
    }
    typealias K = TimelineKindInfo

    /// The workspace log's own action names the contract lists (any other is `workspace.<action>`, verbatim).
    public static let workspaceActions = ["created", "renamed", "slept", "woke", "finished", "reopened", "archived", "restored", "run-opened",
                                          "run-closed", "run-archive-failed", "worker-added", "space-up", "space-down", "space-purged"]
    public static let messageStates = ["queued", "held", "delivered", "started", "answered", "failed", "cancelled", "woken"]

    /// The twelve sources kept here, then the two the contract names that are not kept yet.
    public static let all: [TimelineSourceInfo] = [
        TimelineSourceInfo(name: "actions", title: "Actions (metrics: events)", status: "kept", at: ["host", "workspace", "sandbox", "session"],
                           kinds: [K("action.ok", "An action that finished", span: true), K("action.error", "An action that failed", span: true),
                                   K("action.open", "An action begun, not yet finished", span: true), K("step.ok", "A step of an action", span: true),
                                   K("step.error", "A step that failed", span: true), K("step.open", "A step begun", span: true)],
                           kindPattern: nil, series: [gauge("action.duration", "Action duration", "workspace", "ms")],
                           attrs: ["action", "phase_before", "phase_after", "image", "bytes", "parent", "error"], sensitive: ["error"], people: nil,
                           defaultRetention: usual),
        TimelineSourceInfo(name: "sessions", title: "Sessions (metrics: sessions)", status: "kept", at: ["host", "workspace", "sandbox", "session"],
                           kinds: [K("session", "A session, open to end", span: true), K("session.open", "Opening (open_ms long)", span: true),
                                   K("session.end", "Ended")],
                           kindPattern: nil, series: [], attrs: ["program", "image", "exit_code", "open_ms", "first_attach_ms", "first_screen_ms"],
                           sensitive: nil, people: nil, defaultRetention: usual),
        TimelineSourceInfo(name: "daemon", title: "Daemon runs (metrics: runs)", status: "kept", at: ["host"],
                           kinds: [K("daemon.run", "The daemon, from its start to the next", span: true), K("daemon.start", "Started"),
                                   K("daemon.stop", "Stopped", notYet: true)],
                           kindPattern: nil, series: [], attrs: ["run_kind", "app_version", "build", "machine", "chip", "macos", "pid"],
                           sensitive: ["machine"], people: nil, defaultRetention: usual),
        TimelineSourceInfo(name: "network", title: "Network, per minute (metrics: network)", status: "kept", at: ["sandbox"], kinds: [],
                           kindPattern: nil,
                           series: [counter("net.allowed", "Connections allowed", "sandbox"), counter("net.denied", "Connections denied", "sandbox"),
                                    counter("net.failed", "Connections failed", "sandbox"), counter("net.bytes_up", "Bytes up", "sandbox", "bytes"),
                                    counter("net.bytes_down", "Bytes down", "sandbox", "bytes")],
                           attrs: [], sensitive: nil, people: nil, defaultRetention: usual),
        TimelineSourceInfo(name: "workspace", title: "Workspace log", status: "kept", at: ["workspace", "sandbox", "session", "room", "run"],
                           kinds: workspaceActions.map { K("workspace.\($0)", $0.replacingOccurrences(of: "-", with: " ")) },
                           kindPattern: "^workspace\\.[a-z][a-z0-9-]*$", series: [],
                           attrs: ["action", "by", "agent", "place", "room", "run", "from", "to", "reason", "isolation", "added", "removed", "bytes", "folder"],
                           sensitive: ["reason", "folder"], people: ["by"], defaultRetention: days(90, 90, 365, nil)),
        TimelineSourceInfo(name: "grants", title: "Permission decisions (grants log)", status: "kept", at: ["workspace", "sandbox", "session"],
                           kinds: [K("decision.allow", "Allowed"), K("decision.ask", "Asked a person (refused today)"), K("decision.never", "Refused (never)"),
                                   K("grant.add", "A grant given"), K("grant.revoke", "A grant revoked"), K("grant.request", "A request recorded"),
                                   K("ceiling.set", "A ceiling set")],
                           kindPattern: nil, series: [],
                           attrs: ["action", "by", "subject", "perm", "role", "answer", "scope", "until", "op", "grant", "reason"],
                           sensitive: ["reason"], people: ["by"], defaultRetention: days(365, 365, 365, nil)),
        TimelineSourceInfo(name: "runs", title: "Workspace runs and space frames", status: "kept", at: ["run"],
                           kinds: [K("run", "A run, start (or reopen) to finish (or archive)", span: true), K("run.open", "Started or reopened"),
                                   K("run.frame", "A frame: the space's state, recorded"), K("run.close", "Finished or archived")],
                           kindPattern: nil, series: [], attrs: ["how", "closed_by", "archived", "frames", "frames_capped", "legacy", "label"],
                           sensitive: nil, people: nil, defaultRetention: days(nil, nil, nil, nil)),
        TimelineSourceInfo(name: "chat", title: "Chat times and Ask outcomes", status: "kept", at: ["room"],
                           kinds: [K("chat.message", "A message sent (its time, never its text)")]
                            + messageStates.map { K("chat.\($0)", "A message \($0) (one per recipient)") }
                            + [K("chat.handover", "A message handed over"), K("chat.edited", "A message edited"), K("chat.deleted", "A message deleted"),
                               K("ask.open", "An Ask, open to its outcome", span: true), K("ask.decided", "An Ask decided"),
                               K("ask.expired", "An Ask expired"), K("ask.withdrawn", "An Ask withdrawn")],
                           kindPattern: nil, series: [],
                           attrs: ["from", "to", "to_count", "msg_kind", "private", "re_msg_id", "seq", "ms_to_deliver", "decider", "option", "declined", "no_decider"],
                           sensitive: nil, people: ["from", "to", "decider"], defaultRetention: usual),
        TimelineSourceInfo(name: "daemon-events", title: "The daemon's event stream", status: "kept", at: ["host", "workspace", "sandbox", "session"],
                           kinds: [K("daemon.event", "An event")], kindPattern: nil, series: [], attrs: ["event", "subject"],
                           sensitive: nil, people: nil, defaultRetention: days(7, 30, 365, nil)),
        TimelineSourceInfo(name: "egress", title: "Egress, per connection", status: "kept", at: ["sandbox", "session"],
                           kinds: [K("egress.allowed", "A connection allowed", span: true), K("egress.denied", "A connection denied"),
                                   K("egress.failed", "A connection failed")],
                           kindPattern: nil,
                           series: [counter("egress.allowed", "Connections allowed", "sandbox"), counter("egress.denied", "Connections denied", "sandbox"),
                                    counter("egress.bytes", "Bytes", "sandbox", "bytes")],
                           attrs: ["dest", "port", "protocol", "bytes_up", "bytes_down", "rule"], sensitive: ["dest", "rule"], people: nil,
                           defaultRetention: days(7, 7, 90, 365)),
        TimelineSourceInfo(name: "net-permissions", title: "Sandbox network permissions", status: "not-yet", at: ["sandbox"],
                           kinds: [K("net.permit", "A permission added"), K("net.unpermit", "A permission removed")], kindPattern: nil, series: [],
                           attrs: ["permission", "by", "reason"], sensitive: ["permission", "reason"], people: ["by"], defaultRetention: days(7, 7, 90, 365)),
        TimelineSourceInfo(name: "resources", title: "CPU, memory and disk samples", status: "kept", at: ["host", "sandbox"], kinds: [],
                           kindPattern: nil,
                           series: [gauge("cpu", "CPU", "sandbox", "%"), gauge("memory", "Memory", "sandbox", "bytes"), gauge("disk", "Disk", "sandbox", "bytes")],
                           attrs: [], sensitive: nil, people: nil, defaultRetention: days(7, 7, 365, nil)),
        TimelineSourceInfo(name: "keys", title: "Key and proxy use", status: "kept", at: ["sandbox", "session"],
                           kinds: [K("key.use", "A key used (by name, never its value)"), K("proxy.use", "The proxy used", notYet: true)],
                           kindPattern: nil, series: [counter("keys.uses", "Key uses", "sandbox")], attrs: ["key", "via", "ok"],
                           sensitive: nil, people: nil, defaultRetention: usual),
        TimelineSourceInfo(name: "chat-metrics", title: "Chat metrics", status: "not-yet", at: ["room"], kinds: [], kindPattern: nil,
                           series: [counter("chat.messages", "Messages", "room"), gauge("chat.delivery", "Delivery time", "room", "ms")],
                           attrs: [], sensitive: nil, people: nil, defaultRetention: usual),
    ]

    /// The kept sources, in the catalogue's order (their retention settings are `timeline.<name>` with `-` as `_`).
    public static var kept: [TimelineSourceInfo] { all.filter { $0.status == "kept" } }
    public static func source(_ name: String) -> TimelineSourceInfo? { all.first { $0.name == name } }
    /// `source.attr` of every sensitive attr: never in free-text search, a summary or a rollup.
    public static let sensitive: Set<String> = Set(all.flatMap { s in (s.sensitive ?? []).map { "\(s.name).\($0)" } })
    public static func isSensitive(_ source: String, _ attr: String) -> Bool { sensitive.contains("\(source).\(attr)") }
    /// Which source a series belongs to.
    public static let seriesSource: [String: String] = {
        var out: [String: String] = [:]
        for s in all { for x in s.series { out[x.name] = s.name } }
        return out
    }()
    public static let seriesType: [String: String] = {
        var out: [String: String] = [:]
        for s in all { for x in s.series { out[x.name] = x.type } }
        return out
    }()
}

/// The contract's reference matcher (`matchAst`), ported: how a parsed search applies to one event. The SQL compiler
/// (`TimelineQueryEngine`) must agree with it on every vector (`TimelineMatchTests`).
public enum TimelineMatcher {
    public static func matches(_ ast: TimelineSearchAst?, _ e: TimelineEvent, sensitive: Set<String> = TimelineSources.sensitive) -> Bool {
        guard let all = ast?.all, !all.isEmpty else { return true }
        return all.allSatisfy { t in t.any.contains { test($0, e, sensitive) } != (t.not == true) }
    }

    static func test(_ m: TimelineMatch, _ e: TimelineEvent, _ sensitive: Set<String>) -> Bool {
        switch m {
        case .text(let v):
            let v = v.lowercased()
            if e.summary.lowercased().contains(v) || e.kind.lowercased().contains(v) || e.source.lowercased().contains(v)
                || e.scope.lowercased().contains(v) { return true }
            for (k, a) in e.attrs {
                if case .string(let s) = a, !sensitive.contains("\(e.source).\(k)"), s.lowercased().contains(v) { return true }
            }
            return false
        case .kind(let v, let p): return p ? e.kind.hasPrefix(v) : e.kind == v
        case .source(let v, let p): return p ? e.source.hasPrefix(v) : e.source == v
        case .severity(let op, let v):
            let a = e.severity.rank, b = v.rank
            switch op { case "ge": return a >= b; case "gt": return a > b; case "le": return a <= b; case "lt": return a < b; default: return a == b }
        case .scope(let v, let top): return top ? TimelineScope.within(e.scope, v) : "/\(e.scope)/".contains("/\(v)/")
        case .link(let l, let value):
            let v = e.links[l]
            if l != "run" { return v == value }
            let slash = value.lastIndex(of: "/")
            let id = slash.map { String(value[value.index(after: $0)...]) } ?? value
            let ws = slash.flatMap { $0 > value.startIndex ? String(value[..<$0]) : nil }
            if let v, v == value || (ws == nil && v.hasSuffix("/\(id)")) { return true }
            return "/\(e.scope)/".contains("/\(ws.map { "workspace:\($0)/" } ?? "")run:\(id)/")
        case .attr(let k, let value):
            guard let a = e.attrs[k], let s = a.searchText else { return false }
            return s.lowercased() == value.lowercased()
        }
    }
}
