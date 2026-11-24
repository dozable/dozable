import DozableChat
import DozableKit
import Foundation

// FEEDS in the daemon (Feeds.swift has the pure parts): the routes of a workspace and where one notice would go
// (`workspace-feeds`, read-only), the test door (`workspace-feeds-emit`, the owner's), and posting a notice — the routes
// decided, repeats and floods held back (`ChatNoticeThrottle`), the notice posted under the chat server's own name over its
// control channel (`systemNotice`), a critical one kept in the owner's Needs you and — when it is an agent's — typed into
// its idle session from the fixed template (`FeedSessionDelivery`).
//
// Dozable's own feeds come from what the daemon already sees: a journal entry appended (`journal`), a workspace agent's
// program on this Mac that exited with an error (`health`), a host its proxy refused again and again (`network`), the Mac's
// Claude login expiring or signed out (`accounts`) and the store's disk running low (`resources`) — the last three looked
// at every 30 seconds by `runFeedWatch`; nothing new is measured but the disk's free space.
// docs/engineering/workspaces.md, "Feeds and notices".

/// One critical notice in the owner's Needs you (kept in the daemon's memory for a day).
public struct FeedNeedsYou: Codable, Equatable, Sendable {
    public var at: Date
    public var feed: String
    public var kind: String
    public var title: String
    public var text: String?
    public var source: String?
    public init(at: Date, feed: String, kind: String, title: String, text: String?, source: String?) {
        self.at = at; self.feed = feed; self.kind = kind; self.title = title; self.text = text; self.source = source
    }
    public static let keptFor: TimeInterval = 24 * 3600
}

/// What the Mac's own notices last saw.
public struct FeedWatchState: Sendable {
    /// account → its login state's word (`ok`, `expired`, `signed-out`).
    var logins: [String: String] = [:]
    /// The proxy log records counted already (`PLACE#id`).
    var netCounted: Set<String> = []
    /// `PLACE\u{1F}host` → when it was refused, recently.
    var refusals: [String: [Date]] = [:]
    /// The disk's level last said (`ok`, `low`, `critical`).
    var disk = "ok"
}

/// A workspace agent's session, looked at and typed into for a critical notice (tests give a fake).
public protocol FeedSessionPort: Sendable {
    func look(_ place: AgentPlace) async -> FeedSessionDelivery.Look?
    func type(_ place: AgentPlace, _ text: String) async -> Bool
}

extension HostCore {
    // MARK: the routes

    /// The routes of `rec`: the defaults, then its recorded space file's `x-dozable.feeds`.
    nonisolated func feedRoutes(_ rec: WorkspaceRecord) -> FeedRoutes {
        guard SpaceRecordRef.of(rec) != nil else { return FeedRoutes() }
        let folder = WorkspaceStore.resolved(workspaces.folder(rec.name))
        guard let data = try? MacFenceHostFS.readRegular(folder + "/space.json", maximum: SpaceRequest.maximumBytes),
              let doc = try? ChatJSON.parse(data) else { return FeedRoutes() }
        return FeedRoutes(file: SpaceDoc.member(SpaceDozable.of(doc), "feeds"))
    }

    /// Who holds the manager role in `rec`: its manager agent and every identity given the role in it — each by its
    /// lasting name (its bot's, when it is one).
    nonisolated func feedManagers(_ rec: WorkspaceRecord, now: Date = Date()) -> [String] {
        var out: [String] = []
        func add(_ n: String) { if !out.contains(n) { out.append(n) } }
        for a in rec.agents where a.isManager && a.endedAt == nil && a.retiredAt == nil { add(a.bot ?? a.name) }
        let grants = GrantStore(store: store).readOrEmpty().grants + (rec.permissions?.grants ?? [])
        for g in grants where g.role == "manager" && g.isActive(now) {
            guard GrantScope(stored: g.scope) == .workspace(rec.name), let s = GrantSubject(stored: g.subject) else { continue }
            switch s {
            case .bot(let b): add(b)
            case .agent(let w, let n) where w == rec.name:
                let a = rec.agents.first { $0.name == n && $0.endedAt == nil }
                add(a?.bot ?? n)
            default: break
            }
        }
        return out
    }

    /// The person's chat name (`owner` when chat has none yet).
    nonisolated func feedOwner() -> String { (try? ChatDirectory.load(ChatPaths(store: store)))?.human ?? "owner" }

    /// The chat participant an identity of `rec` is: its record entry's participant (its bot's, or its own name), else the
    /// name itself (a bot).
    nonisolated func feedParticipant(_ rec: WorkspaceRecord, _ name: String) -> String {
        if let a = rec.agents.last(where: { ($0.name == name || $0.bot == name) && $0.endedAt == nil }) { return a.participant ?? a.bot ?? a.name }
        return name
    }

    /// The place of the identity `name` in `rec` (nil: none on this Mac).
    nonisolated func feedPlace(_ rec: WorkspaceRecord, _ name: String) -> AgentPlace? {
        rec.agents.last(where: { ($0.name == name || $0.bot == name) && $0.endedAt == nil && $0.stoppedAt == nil })?.place
    }

    /// `workspace-feeds`: the routes in effect, or (`dryRun`) where one notice would go. Read-only.
    func workspaceFeeds(_ w: WorkspaceRequest) throws -> JSONValue {
        let n = try workspaceName(w)
        let rec = try workspaceRecord(n)
        let f = w.feeds ?? FeedsRequest()
        let routes = feedRoutes(rec)
        let managers = feedManagers(rec)
        let room = rec.mainRoom?.chatRoom
        if f.dryRun == true {
            guard let kind = f.kind else { throw HostError(.usage, "--dry-run needs --kind KIND (account.expired, health.crashed, …)") }
            let severity = f.severity ?? "info"
            try Self.checkFeedNotice(kind: kind, severity: severity)
            var plan = routes.plan(workspace: n, feed: FeedNames.feed(ofKind: kind) ?? FeedNames.test, kind: kind, severity: severity,
                                   managers: managers, toName: f.to, owner: feedOwner(), room: room)
            if room == nil { plan.notes = (plan.notes ?? []) + ["\(n) has no room: nothing would be posted"] }
            return try JSONValue(encoding: plan)
        }
        var notes: [String] = []
        if room == nil { notes.append("\(n) has no room: its feeds post nothing") }
        var out = WorkspaceFeeds(workspace: n, room: room, feeds: routes.rows(managers: managers), notes: notes.isEmpty ? nil : notes)
        out.needsYou = feedNeedsYouNow(n)
        return try JSONValue(encoding: out)
    }

    static func checkFeedNotice(kind: String, severity: String) throws {
        guard ChatNotice.isKind(kind) else { throw HostError(.invalidValue, "\(kind.prefix(60)): a notice's kind is FAMILY.WHAT in lower case (account.expired, health.crashed)") }
        guard ChatNotice.severities.contains(severity) else {
            throw HostError(.invalidValue, "--severity is one of \(ChatNotice.severities.joined(separator: ", "))")
        }
    }

    /// The owner's Needs you of `n` now (the last day's critical notices).
    func feedNeedsYouNow(_ n: String) -> [FeedNeedsYou]? {
        let cut = Date().addingTimeInterval(-FeedNeedsYou.keptFor)
        let kept = (feedNeedsYou[n] ?? []).filter { $0.at > cut }
        feedNeedsYou[n] = kept.isEmpty ? nil : kept
        return kept.isEmpty ? nil : kept
    }

    // MARK: the test door

    /// `workspace-feeds-emit`: a notice from the `test` feed, posted as Dozable would post one of its own (the owner's).
    func workspaceFeedsEmit(_ w: WorkspaceRequest) async throws -> FeedEmitted {
        guard !readOnly else { throw HostError(.unavailable, "workspace-feeds-emit needs the daemon") }
        let n = try workspaceName(w)
        let f = w.feeds ?? FeedsRequest()
        guard let kind = f.emit ?? f.kind else { throw HostError(.usage, "--emit KIND (health.silent, resources.disk, …)") }
        let severity = f.severity ?? "info"
        try Self.checkFeedNotice(kind: kind, severity: severity)
        var action: ChatNoticeAction?
        if let c = f.actionCommand {
            if let why = ChatNoticeCommand.refusal(c) { throw HostError(.invalidValue, why) }
            action = ChatNoticeAction(label: "Look", command: c)
        }
        let text = f.text ?? "A test notice (doz workspace feeds \(n) --emit)."
        let notice = ChatNotice(kind: kind, severity: severity, title: "Test: \(kind)", text: text, source: "doz workspace feeds --emit",
                                dedupeKey: f.dedupe ?? "test:" + kind, action: action)
        if let why = notice.refusal() { throw HostError(.invalidValue, why) }
        return try await postFeedNotice(n, feed: FeedNames.test, notice: notice, toName: f.to, strict: true)
    }

    // MARK: posting

    /// Posts `notice` from `feed` in workspace `n` by its routes (or to `toName` alone). `strict`: a notice that cannot be
    /// posted (no room, chat not ready, refused) throws; otherwise it is said in the daemon's log and dropped.
    @discardableResult
    func postFeedNotice(_ n: String, feed: String, notice: ChatNotice, toName: String? = nil, strict: Bool = false) async throws -> FeedEmitted {
        let rec = try workspaceRecord(n)
        let owner = feedOwner()
        let room = rec.mainRoom?.chatRoom
        var plan = feedRoutes(rec).plan(workspace: n, feed: feed, kind: notice.kind, severity: notice.severity,
                                        managers: feedManagers(rec), toName: toName, owner: owner, room: room)
        if plan.to.isEmpty { return FeedEmitted(workspace: n, feed: feed, result: "off", plan: plan) }
        guard let room else {
            if strict { throw HostError(.invalidPhase, "\(n) has no room: a notice is posted in a workspace's room") }
            return FeedEmitted(workspace: n, feed: feed, result: "no-room", plan: plan)
        }
        guard let chat = workspaceChat, await chat.readiness() == .ready else {
            if strict { throw HostError(.unavailable, "chat is not ready — doz chat status") }
            note(nil, "workspace \(n): a \(feed) notice (\(notice.kind)) was not posted: chat is not ready")
            return FeedEmitted(workspace: n, feed: feed, result: "chat-off", plan: plan)
        }
        var post = notice
        switch feedThrottle.decide(scope: n, feed: feed, key: notice.dedupeKey, now: Date().timeIntervalSince1970) {
        case .repeated:
            return FeedEmitted(workspace: n, feed: feed, result: "repeated", plan: plan,
                               notes: ["the same notice (\(notice.dedupeKey)) was posted inside its window: not posted again"])
        case .rateLimited:
            return FeedEmitted(workspace: n, feed: feed, result: "rate-limited", plan: plan,
                               notes: ["the \(feed) feed posted \(feedThrottle.limit) notices in the last minute: this one is held back"])
        case .post(let held) where held > 0:
            let more = " (\(held) more from this feed were held back since its last notice)"
            if post.text.utf8.count + more.utf8.count <= ChatNotice.maximumText { post.text += more }
        case .post:
            break
        }
        let msgID = chatNewID()
        var recipients = plan.recipients.map { $0 == owner ? owner : feedParticipant(rec, $0) }
        let noticeJSON = post.json, direct = plan.direct
        let body = { (to: [String]) -> JValue in
            .map(["room": .string(room), "msgId": .string(msgID), "feed": .string(feed), "notice": noticeJSON, "to": .strings(to),
                  "direct": .bool(direct)])
        }
        do {
            _ = try await chat.control("systemNotice", body(recipients))
        } catch let e as HostError where e.code == .invalidPhase && e.message.contains("is not a member of room") && plan.direct
                    && !(plan.to == ["owner"] || plan.to == ["owner", "needs-you"]) {
            // The manager (or the one named) is not in the room: the owner gets it instead, and the plan says so.
            plan.fallback = "\(recipients.first ?? "the manager") is not a member of room \(room): the owner gets it instead"
            plan.to = plan.to.filter { $0 != "manager" && $0 != "session" && !$0.isEmpty && $0 != recipients.first }
            plan.to.insert("owner", at: 0)
            recipients = [owner]
            plan.recipients = recipients
            do { _ = try await chat.control("systemNotice", body(recipients)) } catch {
                if strict { throw error }
                note(nil, "workspace \(n): a \(feed) notice was not posted: \(HostError.from(error).message)")
                return FeedEmitted(workspace: n, feed: feed, result: "refused", plan: plan)
            }
        } catch {
            if strict { throw error }
            note(nil, "workspace \(n): a \(feed) notice was not posted: \(HostError.from(error).message)")
            return FeedEmitted(workspace: n, feed: feed, result: "refused", plan: plan)
        }
        note(nil, "workspace \(n): notice \(notice.kind) (\(notice.severity)) from the \(feed) feed → \(plan.to.joined(separator: ", "))")
        var out = FeedEmitted(workspace: n, feed: feed, result: "posted", msgId: msgID, plan: plan)
        if plan.to.contains("needs-you") {
            var kept = feedNeedsYou[n] ?? []
            kept.append(FeedNeedsYou(at: Date(), feed: feed, kind: notice.kind, title: post.title, text: post.text.isEmpty ? nil : post.text,
                                     source: post.source.isEmpty ? nil : post.source))
            feedNeedsYou[n] = Array(kept.suffix(20))
        }
        // A critical notice for an agent: typed into its session when it is idle — the fixed sentence, never this text.
        if plan.to.contains("session"), let who = plan.recipients.first, who != owner, let place = feedPlace(rec, who) {
            let outcome = await feedTypeIntoSession(place, notice: post, feed: FeedNames.feed(ofKind: notice.kind) ?? feed)
            out.session = outcome.rawValue
        }
        return out
    }

    /// The fixed sentence typed into the session at `place`, when it is idle and holds no unsent input (FeedSessionDelivery).
    func feedTypeIntoSession(_ place: AgentPlace, notice: ChatNotice, feed: String) async -> FeedSessionDelivery.Outcome {
        guard let key = Self.sessionInputKey(place) else { return .noSession }
        let port: any FeedSessionPort = feedSessionPortOverride ?? DaemonFeedSessionPort(core: self)
        return await feedSessions.deliver(notice, feed: feed, session: key, now: Date().timeIntervalSince1970,
                                          look: { await port.look(place) }, type: { await port.type(place, $0) })
    }

    /// The key of a session's input gate: `SANDBOX/SESSION` (`@mac/SESSION` on this Mac) — the one `doz sessions send` takes.
    nonisolated static func sessionInputKey(_ place: AgentPlace) -> String? {
        if let s = place.sandbox, let ss = place.session { return s + "/" + ss }
        if place.mac == true, let s = place.session { return MacPlace.name + "/" + s }
        return nil
    }

    /// The daemon's own look at a session: its program's status (idle or done is idle) and its screen's cursor line.
    func feedLook(_ place: AgentPlace) async -> FeedSessionDelivery.Look? {
        if place.mac == true, let s = place.session {
            guard let screen = await mac.liveScreen(s) else { return nil }
            let idle = [.idle, .done].contains(statuses[MacPlace.name]?[s]?.state)
            return .init(idle: idle, unsentInput: FeedSessionDelivery.unsentInput(.init(text: screen.text, cursorY: screen.cursorY)))
        }
        guard let name = place.sandbox, let s = place.session, let m = try? get(name), await effectivePhase(m) == .running else { return nil }
        guard case .answered(let screen?) = await guestRead(m, { try await $0.liveScreen(s) }) else { return nil }
        let idle = [.idle, .done].contains(statuses[name]?[s]?.state)
        return .init(idle: idle, unsentInput: FeedSessionDelivery.unsentInput(.init(text: screen.text, cursorY: screen.cursorY)))
    }

    /// The daemon's own typing: the text, then Enter on its own (as `doz sessions send --text … --enter`).
    func feedType(_ place: AgentPlace, _ text: String) async -> Bool {
        let pieces = [Data(text.utf8), Data([0x0D])]
        if place.mac == true, let s = place.session {
            guard case .delivered? = try? await DeckholdSocket.send(path: mac.socket(s), pieces: pieces) else { return false }
            return true
        }
        guard let name = place.sandbox, let s = place.session, let m = try? get(name) else { return false }
        guard case .delivered? = try? await m.sandbox.sendInput(s, pieces: pieces) else { return false }
        return true
    }

    // MARK: Dozable's own feeds

    /// The journal feed: an entry just appended, posted to the room when it is one the room is shown (outcomes and failing
    /// reviews; never working notes), in the background.
    nonisolated func feedJournalEntry(_ n: String, run: String, _ e: JournalEntry) {
        guard let notice = JournalFeed.notice(e, run: run) else { return }
        Task { [weak self] in _ = try? await self?.postFeedNotice(n, feed: "journal", notice: notice) }
    }

    /// The health feed: a workspace agent's program on this Mac exited with an error.
    func feedAgentCrashed(_ n: String, agent: String, exitCode: Int32) {
        let notice = ChatNotice(kind: "health.crashed", severity: "warning", title: "\(agent) crashed",
                                text: "Its program on this Mac exited with \(exitCode).", source: "this Mac",
                                dedupeKey: "health.crashed:\(agent)", action: ChatNoticeAction(label: "See", command: "doz workspace state \(n)"))
        Task { [weak self] in _ = try? await self?.postFeedNotice(n, feed: "health", notice: notice) }
    }

    /// The workspaces whose agents are live now (not finished, archived or every agent stopped), each with its records.
    nonisolated func feedLiveWorkspaces() -> [WorkspaceRecord] {
        workspaces.records().filter { rec in
            rec.flags.finishedAt == nil && rec.flags.archivedAt == nil
                && rec.agents.contains { $0.endedAt == nil && $0.stoppedAt == nil && $0.pendingAt == nil }
        }
    }

    /// Every 30 seconds while the daemon runs: the Mac's own notices — an account's login, a host refused again and again,
    /// the disk. Only changes are posted (and each through its dedupe window).
    public nonisolated func runFeedWatch() async {
        try? await Task.sleep(for: .seconds(20))
        while !Task.isCancelled {
            await feedWatchOnce()
            try? await Task.sleep(for: .seconds(30))
        }
    }

    func feedWatchOnce(now: Date = Date()) async {
        guard !readOnly else { return }
        let live = feedLiveWorkspaces()
        guard !live.isEmpty else { return }
        // accounts: the Mac login's state, per account, on a change to expired or signed out.
        for (account, w) in watchers {
            let word = w.state.label
            let before = feedWatch.logins[account]
            feedWatch.logins[account] = word
            guard word != before, word == "expired" || word == "signed-out" else { continue }
            let critical = word == "signed-out"
            let notice = ChatNotice(kind: critical ? "account.signed-out" : "account.expired", severity: critical ? "critical" : "warning",
                                    title: critical ? "Claude Code signed out on this Mac" : "This Mac's Claude login expired",
                                    text: critical ? "Agents using the \(account) account cannot work until you sign in again with claude on the Mac."
                                        : "It renews while Claude Code runs on the Mac: open it (any prompt), and agents carry on.",
                                    source: "this Mac", dedupeKey: "account:\(account):\(word)",
                                    action: ChatNoticeAction(label: "Check", command: "doz account ls"))
            for rec in live { _ = try? await postFeedNotice(rec.name, feed: "accounts", notice: notice) }
        }
        // network: a host refused 3 times in 10 minutes for one agent's place.
        for rec in live {
            for a in rec.agents where a.endedAt == nil && a.stoppedAt == nil {
                let place: String
                let log: ConnectionLog?
                if let s = a.place.sandbox { place = s; log = (try? get(s))?.sandbox.egress?.log }
                else if a.place.mac == true, let s = a.place.session { place = MacPlace.name + "/" + s; log = macProxies[s]?.proxy.log }
                else { continue }
                guard let log else { continue }
                for r in log.records where r.verdict == .denied && !r.open {
                    let id = place + "#" + r.id.uuidString
                    guard feedWatch.netCounted.insert(id).inserted else { continue }
                    let k = place + "\u{1F}" + r.host.lowercased()
                    // Counted by when each was refused: an old refusal found at a daemon's start is not a new one now.
                    guard now.timeIntervalSince(r.time) < 600 else { continue }
                    feedWatch.refusals[k] = (feedWatch.refusals[k] ?? []).filter { now.timeIntervalSince($0) < 600 } + [r.time]
                    guard feedWatch.refusals[k]!.count == 3 else { continue }
                    let host = String(r.host.prefix(120))
                    let notice = ChatNotice(kind: "network.refused", severity: "warning", title: "\(host) was refused for \(a.name)",
                                            text: "The network refused \(a.name)'s connections to \(host) 3 times in 10 minutes: it is not on the allow list.",
                                            source: a.place.display, dedupeKey: "network.refused:\(a.name):\(host)",
                                            action: ChatNoticeAction(label: "See", command: "doz workspace reach \(rec.name)"))
                    _ = try? await postFeedNotice(rec.name, feed: "network", notice: notice)
                }
            }
        }
        if feedWatch.netCounted.count > 20000 { feedWatch.netCounted.removeAll() }
        // resources: the store's disk.
        var fs = statfs()
        if statfs(store.root.path, &fs) == 0 {
            let free = Int64(fs.f_bavail) * Int64(fs.f_bsize)
            let level = free < 2 << 30 ? "critical" : free < 10 << 30 ? "low" : "ok"
            let before = feedWatch.disk
            feedWatch.disk = level
            if level != before, level != "ok" {
                let gib = String(format: "%.1f", Double(free) / Double(1 << 30))
                let notice = ChatNotice(kind: "resources.disk", severity: level == "critical" ? "critical" : "warning",
                                        title: "This Mac's disk is low: \(gib) GiB free",
                                        text: level == "critical" ? "Sandboxes and sessions may stop working: free some space."
                                            : "Below 10 GiB free: free some space before it runs out.",
                                        source: "this Mac", dedupeKey: "resources.disk:\(level)",
                                        action: ChatNoticeAction(label: "See", command: "doz resources"))
                for rec in live { _ = try? await postFeedNotice(rec.name, feed: "resources", notice: notice) }
            }
        }
    }
}

/// The daemon's own look and typing (HostCore's `feedLook`, `feedType`).
struct DaemonFeedSessionPort: FeedSessionPort {
    let core: HostCore
    func look(_ place: AgentPlace) async -> FeedSessionDelivery.Look? { await core.feedLook(place) }
    func type(_ place: AgentPlace, _ text: String) async -> Bool { await core.feedType(place, text) }
}
