import Foundation

// FEEDS: posting a notice (ChatNotice.swift) and handing it to agents. Two ways in: a participant of kind `feed` with its
// own token (`POST /agent/send` with `kind: "notice"` — the server fills in `notice.feed` with its name), and Dozable's
// own feeds — the journal, the Mac's account, network, health and resource notices — which the daemon posts over its
// control channel (`systemNotice`, ChatRoomControl.swift) under the server's own name, the feed named in the call.
//
// Notices are never pushed to an agent: they are not handed over with the messages (`messages` of a receive, `listen`, a
// webhook, an inbox). An agent pulls them, in their own list `notices` beside `messages` in `GET /agent/receive` — by
// default only those addressed to it (each handed once), `notices=all` for the rest of its rooms' notices too (a look),
// `notices=none` for none — or `GET /agent/notices?room=` (a look, for an agent delivered to by webhook). A room notice is
// handed to the room's people on the page like any message. A notice's `to` may never name the participant its source
// names: the journal feed never addresses an identity's own entry back to it.
//
// A notice counts for nothing of the hold, wakes nobody it does not name, and is never a command.

extension ChatServerCore {
    /// Posts `notice` from `from` (a feed participant, or the server's own name) as feed `feed` in `room`, for `to` (each a
    /// member of the room) — a direct message to them when `direct`. The same msgID again is a duplicate.
    public func postNotice(room: String, msgID: String, from: String, feed: String, notice raw: ChatNotice, to: [String],
                           direct: Bool) -> ChatReceipt {
        var notice = raw
        notice.feed = feed
        guard chatIsSessionName(feed) else { return .refused("a feed's name is a lower-case word (journal, health, ci)") }
        if let why = notice.refusal() { return .refused(why) }
        guard chatIsUUID(msgID) else { return .refused("a notice needs a uuid msg_id") }
        if to.contains(notice.source.name) { return .refused("a notice is never addressed to \(notice.source.name), whom its source names") }
        let system = from == ChatProtocol.systemName
        guard hasRoom(room) else { return .refused("no room \(goQuote(room))") }
        if !system && !member(room, from) { return .refused("\(from) is not a member of room \(room)") }
        let st: ChatRoomStore
        do { st = try store(room) } catch { return .refused("\(error)") }
        let known = st.knownID(msgID)
        if known.known && (known.by == from || system || member(room, from)) { return Self.duplicateOf(known.state, known.detail) }
        if isArchived(room) { return .refused(Self.archivedRefusal(room)) }
        closeGate.read()
        defer { closeGate.done() }
        if let no = closedRefusal(room) { return no }
        var named: [String] = []
        for n in to where n != from && !named.contains(n) {
            if !member(room, n) { return .refused("\(n) is not a member of room \(room)") }
            named.append(n)
        }
        if direct && named.isEmpty { return .refused("a direct notice must name who it is for") }
        let sender = ChatSender(kind: "feed", id: system ? "dozable:feed:" + feed : (participant(from)?.fixedIdentity ?? "dozable:feed:" + from),
                                name: system ? feed : from, verified: true)
        var sm = ChatStored(kind: "notice", msgID: msgID, from: from, to: named, content: notice.plainText, at: chatNow(),
                            sender: sender, isPrivate: direct)
        sm.notice = notice
        do {
            if try st.insert(&sm) { return ChatReceipt("duplicate") }
        } catch { return .refused("store: \(error)") }
        if !system { heard(from, answered: true) }
        published(room, sm)
        // The room's people see it on the page; an agent it names pulls it (receive's `notices`) — never pushed.
        var people = direct ? named.filter(isHuman) : []
        if !direct { for p in members(room) where p != from && isHuman(p) { people.append(p) } }
        for n in named where !people.contains(n) { people.append(n) }
        for r in people {
            if isHuman(r) {
                setState(room, st, ChatState(msgID: sm.msgID, recipient: r, state: "queued", at: sm.at))
                deliverInOrder(room, st, [sm.msgID], to: r)
            } else {
                // Never `queued`: that is a message waiting to be handed over. A notice waits to be pulled.
                setState(room, st, ChatState(msgID: sm.msgID, recipient: r, state: "waiting", at: sm.at, detail: "a notice: it pulls it with its notices"))
                wakePoll(r)
            }
        }
        log("chat: notice \(Self.short(msgID)) from feed \(feed) in room \(room) (\(notice.kind), \(notice.severity))")
        return ChatReceipt("queued")
    }

    /// One notice as an agent pulls it: `{type: "notice", room, msg_id, addressed_to_you, source, about_you, notice, content}`.
    func noticeItem(_ room: String, _ m: ChatStored, _ n: ChatNotice, for name: String) -> JValue {
        .map(["type": .string("notice"), "room": .string(room), "msg_id": .string(m.msgID),
              "addressed_to_you": .bool(m.to.contains(name)), "source": n.source.json,
              "about_you": .bool(n.subject.type == "identity" && n.subject.name == name),
              "notice": n.json, "content": .string(m.content)])
    }

    /// The notices `name` pulls now. `mode`: `mine` (the default: those addressed to it not handed yet — each handed once,
    /// then delivered), `all` (those too, and every other notice of its rooms it may read, newest 50 a room — a look) or
    /// `none`. `room`: one room only. `hand`: false for a look (nothing is marked).
    func pullNotices(_ name: String, mode: String, room only: String? = nil, hand: Bool = true) -> [JValue] {
        guard mode != "none" else { return [] }
        var out: [JValue] = []
        for room in roomNames() where member(room, name) && (only == nil || only == room) {
            guard let st = try? store(room) else { continue }
            var others = 0
            for id in st.noticeIDs().reversed() {
                guard let m = try? st.one(id), let n = m.notice, Self.canSee(m, name) else { continue }
                let mine = m.to.contains(name)
                if mine {
                    let handed = m.states.contains { $0.recipient == name && $0.state == "delivered" }
                    if hand && handed && mode == "mine" { continue }
                    out.append(noticeItem(room, m, n, for: name))
                    if hand && !handed {
                        setState(room, st, ChatState(msgID: m.msgID, recipient: name, state: "delivered", at: chatNow(), detail: "pulled with its notices"))
                    }
                } else if mode == "all", others < 50 {
                    others += 1
                    out.append(noticeItem(room, m, n, for: name))
                }
            }
        }
        return out
    }

    /// `POST /agent/send` from a feed participant: a notice, `/rooms` or `/protocol` — anything else is refused as not
    /// permitted (a feed never asks, decides, runs a room command or posts as a person). nil: not a feed's call.
    func feedSend(_ line: ChatLine, body: JValue, sender: String) -> (status: Int, answer: JValue)? {
        guard participant(sender)?.isFeed == true else { return nil }
        let words = Self.fields(line.content)
        if line.kind != "notice", !line.isAsk, let w = words.first, w == "/rooms" || w == "/protocol" { return nil }
        guard line.kind == "notice", !line.isAsk else {
            return (403, Self.notPermitted("\(sender) is a feed: it posts notices only — it never asks, decides or runs a room command"))
        }
        let notice: ChatNotice
        do {
            guard let raw = body.field("notice") else { return (422, Self.refusedJSON("a notice needs its notice object")) }
            notice = try ChatNotice.read(raw)
        } catch {
            return (422, Self.refusedJSON("\(error)"))
        }
        let room = line.room.isEmpty ? config.defaultRoom : line.room
        let rc = postNotice(room: room, msgID: line.msgID, from: sender, feed: sender, notice: notice, to: line.to, direct: line.isPrivate)
        return (rc.state == "refused" ? 422 : 200, rc.members(["msg_id": .string(line.msgID)]))
    }

    /// A refusal a feed gets for what it may not do: `{"error":{"code":"not-permitted","message":…}}`.
    static func notPermitted(_ message: String) -> JValue {
        .map(["error": .map(["code": .string("not-permitted"), "message": .string(message)])])
    }

    static func refusedJSON(_ detail: String) -> JValue { .map(["state": .string("refused"), "detail": .string(detail)]) }
}
