import DozableChat
import Foundation

// FEEDS: what streams into a workspace's room, and who is told. A notice (DozableChat's `ChatNotice`) comes from a FEED —
// the run journal, the Mac's own account, network, health and resource notices, or (an outside system) a participant of
// kind `feed` — and goes to whoever can act on it, by the workspace's routes:
//
//   journal                          → the room (on by default; outcomes and failing reviews only, never working notes)
//   accounts, network, health,
//   resources                        → the manager, as a direct message — the owner instead when there is no manager or
//                                      more than one (`fallback` says so); a critical one also to the owner's Needs you
//
// A workspace changes a route in its space file: `x-dozable: { feeds: { journal: { to: off } } }` (room, manager, owner or
// off). `doz workspace feeds W` lists the routes in effect; `--dry-run` says where one notice would go; `--emit` posts one
// from the `test` feed, as Dozable would (the owner's, to check the routes).
//
// The pure parts are here: the routes and the decision (`FeedRoutes`), the fixed sentences a critical notice is typed with
// into an idle session and the atomic step that types it (`FeedSessionDelivery`). The daemon's side is HostCore+Feeds.swift.
// docs/engineering/workspaces.md, "Feeds and notices".

/// The feeds Dozable has, and the family of a notice's kind.
public enum FeedNames {
    /// Dozable's own feeds, in the order the routes list them.
    public static let builtIn = ["journal", "accounts", "network", "health", "resources"]
    /// The feed `doz workspace feeds --emit` posts from.
    public static let test = "test"
    /// Where a route may send a feed's notices.
    public static let destinations = ["room", "manager", "owner", "off"]

    /// The feed whose route a notice of `kind` follows: its family (`account.expired` → accounts, `resources.disk` →
    /// resources); nil when it is none of Dozable's.
    public static func feed(ofKind kind: String) -> String? {
        switch String(kind.split(separator: ".").first ?? "") {
        case "journal": "journal"
        case "account", "accounts": "accounts"
        case "network", "net": "network"
        case "health": "health"
        case "resource", "resources", "disk", "memory": "resources"
        default: nil
        }
    }
}

/// One route as `doz workspace feeds W --json` lists it.
public struct FeedRouteRow: Codable, Equatable, Sendable {
    public var name: String
    /// `room`, `manager`, `owner` or `off`.
    public var to: String
    /// The manager it goes to (`to: manager`).
    public var manager: String?
    /// Why it goes to the owner instead of the manager (no manager, or more than one).
    public var fallback: String?
    /// Where a critical notice of this feed also goes (`needs-you`); a journal entry is never critical.
    public var critical: [String]?
    /// `default` or `space file`.
    public var from: String

    public init(name: String, to: String, manager: String? = nil, fallback: String? = nil, critical: [String]? = nil, from: String) {
        self.name = name; self.to = to; self.manager = manager; self.fallback = fallback; self.critical = critical; self.from = from
    }
}

/// `doz workspace feeds W --json`.
public struct WorkspaceFeeds: Codable, Equatable, Sendable {
    public var kind = "WorkspaceFeeds"
    public var schema = 1
    public var workspace: String
    /// The room room notices go to (nil: the workspace has no room — nothing is posted).
    public var room: String?
    public var feeds: [FeedRouteRow]
    /// The owner's Needs you here: the last day's critical notices (kept in the daemon's memory).
    public var needsYou: [FeedNeedsYou]?
    public var notes: [String]?

    public init(workspace: String, room: String?, feeds: [FeedRouteRow], notes: [String]? = nil) {
        self.workspace = workspace; self.room = room; self.feeds = feeds; self.notes = notes
    }
}

/// Where one notice goes: `doz workspace feeds W --dry-run --kind K --severity S --json`, and the plan `--emit` follows.
public struct FeedPlan: Codable, Equatable, Sendable {
    public var kind = "FeedPlan"
    public var workspace: String
    /// The feed whose route it follows.
    public var feed: String
    public var notice: Notice
    /// Its destinations: `room`, `manager`, `owner`, `needs-you`, `session` — empty when it goes nowhere (`off`).
    public var to: [String]
    /// The participants it is handed to (names), when posted.
    public var recipients: [String]
    /// Whether it is a direct message (manager, owner, a named participant).
    public var direct: Bool
    public var fallback: String?
    public var room: String?
    public var notes: [String]?

    public struct Notice: Codable, Equatable, Sendable {
        public var kind: String
        public var severity: String
    }

    public init(workspace: String, feed: String, notice: Notice, to: [String], recipients: [String], direct: Bool,
                fallback: String? = nil, room: String? = nil, notes: [String]? = nil) {
        self.workspace = workspace; self.feed = feed; self.notice = notice; self.to = to; self.recipients = recipients
        self.direct = direct; self.fallback = fallback; self.room = room; self.notes = notes
    }
}

/// `doz workspace feeds W --emit …`: what happened to the notice.
public struct FeedEmitted: Codable, Equatable, Sendable {
    public var kind = "FeedNotice"
    public var workspace: String
    public var feed: String
    /// `posted`, `repeated` (its dedupeKey inside its window: not posted), `rate-limited` (not posted) or `off`.
    public var result: String
    public var msgId: String?
    public var plan: FeedPlan
    /// A critical notice typed into an idle session: what came of it.
    public var session: String?
    public var notes: [String]?

    public init(workspace: String, feed: String, result: String, msgId: String? = nil, plan: FeedPlan, session: String? = nil, notes: [String]? = nil) {
        self.workspace = workspace; self.feed = feed; self.result = result; self.msgId = msgId; self.plan = plan
        self.session = session; self.notes = notes
    }
}

/// The routes of one workspace: Dozable's defaults, then what its space file says (`x-dozable.feeds`).
public struct FeedRoutes: Equatable, Sendable {
    /// feed → `room`, `manager`, `owner` or `off`.
    public var to: [String: String]
    /// The feeds the space file set.
    public var fromFile: Set<String>

    public static let defaults: [String: String] = ["journal": "room", "accounts": "manager", "network": "manager", "health": "manager",
                                                    "resources": "manager"]

    public init(file: JValue? = nil) {
        to = Self.defaults
        fromFile = []
        for m in SpaceDoc.members(file) {
            guard let t = SpaceDoc.string(SpaceDoc.member(m.value, "to")), FeedNames.destinations.contains(t) else { continue }
            to[m.key] = t
            fromFile.insert(m.key)
        }
    }

    /// The keys a route's map may hold.
    public static let routeKeys = ["to"]

    /// Why `x-dozable.feeds` is not a feeds map: one problem per entry (pointer suffix, words). Empty: it is one.
    public static func problems(_ v: JValue) -> [(at: String, what: String)] {
        guard SpaceDoc.isMap(v) else { return [("", "feeds is a map: { FEED: { to: room | manager | owner | off } }")] }
        var out: [(String, String)] = []
        for m in SpaceDoc.members(v) {
            guard chatIsSessionName(m.key) else { out.append(("/" + m.key, "a feed's name is a lower-case word (journal, accounts, network, health, resources)")); continue }
            guard SpaceDoc.isMap(m.value) else { out.append(("/" + m.key, "a feed's route is { to: room | manager | owner | off }")); continue }
            for k in SpaceDoc.members(m.value) where !routeKeys.contains(k.key) {
                out.append(("/\(m.key)/\(k.key)", "a feed's route has only to: (room, manager, owner or off)"))
            }
            guard let t = SpaceDoc.member(m.value, "to") else { out.append(("/" + m.key, "a feed's route needs to: (room, manager, owner or off)")); continue }
            if !(SpaceDoc.string(t).map(FeedNames.destinations.contains) ?? false) {
                out.append(("/\(m.key)/to", "to is one of room, manager, owner or off"))
            }
        }
        return out
    }

    /// Who the manager is: the ONE identity holding the manager role in the workspace (`managers`, deduplicated). None or
    /// several → the owner, and why.
    public static func manager(_ managers: [String]) -> (name: String?, fallback: String?) {
        var seen: [String] = []
        for m in managers where !seen.contains(m) { seen.append(m) }
        if seen.count == 1 { return (seen[0], nil) }
        if seen.isEmpty { return (nil, "no manager: notices for the manager go to the owner") }
        return (nil, "\(seen.count) managers (\(seen.joined(separator: ", "))): notices for the manager go to the owner")
    }

    /// The routes as listed: Dozable's feeds, then any other the file names.
    public func rows(managers: [String]) -> [FeedRouteRow] {
        let (manager, fallback) = Self.manager(managers)
        var names = FeedNames.builtIn
        for n in to.keys.sorted() where !names.contains(n) { names.append(n) }
        return names.map { n in
            let t = to[n] ?? "room"
            let from = fromFile.contains(n) ? "space file" : "default"
            let critical: [String]? = n == "journal" || t == "off" ? nil : ["needs-you"]
            if t == "manager" {
                if let manager { return FeedRouteRow(name: n, to: "manager", manager: manager, critical: critical, from: from) }
                return FeedRouteRow(name: n, to: "owner", fallback: fallback, critical: critical, from: from)
            }
            return FeedRouteRow(name: n, to: t, critical: critical, from: from)
        }
    }

    /// Where a notice of `kind` and `severity` from `feed` goes. `toName`: a participant named by the caller (`--to`, the
    /// test door) — then it goes to that one alone (`owner`: the owner). A critical notice also goes to the owner's Needs you,
    /// and — when it is a participant's — into that participant's session when it is idle (`session`).
    public func plan(workspace: String, feed: String, kind: String, severity: String, managers: [String], toName: String? = nil,
                     owner: String, room: String?) -> FeedPlan {
        let route = FeedNames.feed(ofKind: kind) ?? feed
        let notice = FeedPlan.Notice(kind: kind, severity: severity)
        let critical = severity == "critical" && route != "journal"
        func done(_ to: [String], _ recipients: [String], direct: Bool, fallback: String? = nil, notes: [String]? = nil) -> FeedPlan {
            var t = to
            if critical && !t.contains("needs-you") { t.append("needs-you") }
            return FeedPlan(workspace: workspace, feed: route, notice: notice, to: t, recipients: recipients, direct: direct,
                            fallback: fallback, room: room, notes: notes)
        }
        if let n = toName {
            if n == "owner" || n == owner { return done(["owner"], [owner], direct: true) }
            return done(critical ? [n, "session"] : [n], [n, owner], direct: true)
        }
        switch to[route] ?? "room" {
        case "off":
            return FeedPlan(workspace: workspace, feed: route, notice: notice, to: [], recipients: [], direct: false, room: room,
                            notes: ["the \(route) feed is off in this workspace"])
        case "owner":
            return done(["owner"], [owner], direct: true)
        case "manager":
            let (m, fallback) = Self.manager(managers)
            if let m { return done(critical ? ["manager", "session"] : ["manager"], [m, owner], direct: true) }
            return done(["owner"], [owner], direct: true, fallback: fallback)
        default:
            return done(["room"], [], direct: false)
        }
    }
}

/// A journal entry as the journal feed posts it — or nil when it is not one the room is shown: outcomes and failing reviews
/// only (never working notes); its text and data redacted (credential-shaped text, Dozable's placeholders), never critical.
public enum JournalFeed {
    public static func notice(_ e: JournalEntry, run: String) -> ChatNotice? {
        let failing = e.kind == "review" && ["no", "partly"].contains(e.data?["met"]?.stringValue ?? "")
        guard e.kind == "outcome" || failing else { return nil }
        let who = e.by == "owner" ? "the owner" : e.by
        var text = BuildLogs.redact(e.text ?? "")
        if text.isEmpty, let v = e.data?["value"]?.stringValue { text = BuildLogs.redact(v) }
        if text.utf8.count > 1000 { text = String(decoding: Array(text.utf8.prefix(1000)), as: UTF8.self) + " …" }
        let criterion = e.data?["criterion"]?.stringValue.map { " (\(BuildLogs.redact($0)))" } ?? ""
        let title = e.kind == "outcome" ? "Outcome of \(run)" : "A review is not met\(criterion)"
        return ChatNotice(kind: "journal.\(e.kind)", severity: e.kind == "outcome" ? "info" : "warning",
                          title: title, text: text, source: "from \(who)'s journal", dedupeKey: "journal:\(e.id)")
    }
}

/// A critical notice typed into an agent's idle session (review A — safe by construction): the text is Dozable's own, a
/// FIXED sentence per feed, never free text from an agent, a journal or a feed; typed only when the session is idle AND has
/// no unsent input, the look and the typing one step under the session's input gate (nothing else of the daemon types
/// into it in between); once per dedupeKey per window. The details come through `dozchat receive`, where an agent already
/// treats them as messages.
public final class FeedSessionDelivery: @unchecked Sendable {
    /// The fixed sentence of each feed. Anything else gets the generic one.
    public static let sentences: [String: String] = [
        "accounts": "An account this workspace uses needs attention",
        "network": "The network refused a host you tried, more than once",
        "health": "An agent of this workspace crashed or is restarting",
        "resources": "This Mac is running low on a resource",
        "test": "A test notice was sent to you",
    ]

    /// The one text a session is typed: `[dozable notice · critical · FEED] SENTENCE. Details: dozchat receive`. `feed` is
    /// one of the fixed names or it is `other` — nothing a notice carries is ever part of it.
    public static func text(feed: String) -> String {
        let f = sentences[feed] != nil ? feed : "other"
        let sentence = sentences[feed] ?? "A notice needs your attention"
        return "[dozable notice · critical · \(f)] \(sentence). Details: dozchat receive"
    }

    /// What the session looks like now.
    public struct Look: Equatable, Sendable {
        public var idle: Bool
        /// nil: not known (then nothing is typed).
        public var unsentInput: Bool?
        public init(idle: Bool, unsentInput: Bool?) { self.idle = idle; self.unsentInput = unsentInput }
    }

    public enum Outcome: String, Equatable, Sendable {
        case typed, notCritical = "not-critical", busy, unsentInput = "unsent-input", inputUnknown = "input-unknown",
             repeated, noSession = "no-session", failed
    }

    public let window: Double
    public let gate: KeyedGate
    private let lock = NSLock()
    private var typedAt: [String: Double] = [:]

    /// `gate`: the sessions' input gate the daemon's own typing takes too (`doz sessions send`).
    public init(window: Double = 600, gate: KeyedGate = KeyedGate()) { self.window = window; self.gate = gate }

    /// Types the fixed text of `feed` into `session` when `notice` is critical and the session is idle with no unsent input,
    /// once per dedupeKey per window: the look and the typing are one step under the session's gate. `look` answers nil
    /// when there is no such session; `type` answers whether every byte was taken.
    public func deliver(_ notice: ChatNotice, feed: String, session: String, now: Double,
                        look: @Sendable () async -> Look?, type: @Sendable (String) async -> Bool) async -> Outcome {
        guard notice.severity == "critical", feed != "journal" else { return .notCritical }
        let key = session + "\u{1F}" + notice.dedupeKey
        if lock.withLock({ typedAt[key].map { now - $0 < window } ?? false }) { return .repeated }
        await gate.lock(session)
        defer { gate.unlock(session) }
        // Looked at again under the gate: another delivery of the same key may have typed while this one waited.
        if lock.withLock({ typedAt[key].map { now - $0 < window } ?? false }) { return .repeated }
        guard let l = await look() else { return .noSession }
        guard l.idle else { return .busy }
        guard let unsent = l.unsentInput else { return .inputUnknown }
        guard !unsent else { return .unsentInput }
        guard await type(Self.text(feed: feed)) else { return .failed }
        lock.withLock { typedAt[key] = now }
        return .typed
    }

    /// Whether the line the cursor is on holds text a person or a program typed and did not send: the cursor's row with any
    /// prompt or box drawing around it taken away. nil: the screen does not say where the cursor is.
    public static func unsentInput(_ s: LiveScreenText) -> Bool? {
        guard let y = s.cursorY else { return nil }
        let rows = s.text.components(separatedBy: "\n")
        guard Int(y) < rows.count else { return nil }
        let frame = CharacterSet(charactersIn: " \t>❯›$%#│┃|╭╮╰╯─━·•▌▐").union(.whitespaces)
        let line = rows[Int(y)].trimmingCharacters(in: frame)
        return !line.isEmpty
    }

    /// A screen's text and cursor (DozableKit's `LiveScreen`'s fields this needs).
    public struct LiveScreenText: Sendable {
        public var text: String
        public var cursorY: UInt16?
        public init(text: String, cursorY: UInt16?) { self.text = text; self.cursorY = cursorY }
    }
}
