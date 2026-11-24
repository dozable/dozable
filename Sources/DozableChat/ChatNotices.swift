import Foundation

// FEEDS: posting a notice (ChatNotice.swift). Two ways in: a participant of kind `feed` with its own token
// (`POST /agent/send` with `kind: "notice"`, `feed` its own name), and Dozable's own feeds — the journal, the Mac's account,
// network, health and resource notices — which the daemon posts over its control channel (`systemNotice`,
// ChatRoomControl.swift) under the server's own name, the feed named in the message.
//
// Who is handed a notice: those it names (`to`), and — in the room, not as a direct message — the room's people. An agent
// is never handed a notice that does not name it, so a manager does not read its own journal back as work, and two agents
// never answer each other's failure notices. Everyone who reads the room sees a room notice; a direct notice is seen by
// those it names (Dozable's own name the owner beside the agent, so the owner sees them all).
//
// A notice counts for nothing an agent's run counts (the hold), wakes nobody it does not name, and is never a command.

extension ChatServerCore {
    /// Posts `notice` from `from` (a feed participant, or the server's own name) as feed `feed` in `room`, for `to` (each a
    /// member of the room) — a direct message to them when `direct`. The same msgID again is a duplicate.
    public func postNotice(room: String, msgID: String, from: String, feed: String, notice: ChatNotice, to: [String],
                           direct: Bool) -> ChatReceipt {
        if let why = notice.refusal() { return .refused(why) }
        guard chatIsUUID(msgID) else { return .refused("a notice needs a uuid msg_id") }
        guard chatIsSessionName(feed) else { return .refused("a feed's name is a lower-case word (journal, health, ci)") }
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
        var sm = ChatStored(kind: "notice", msgID: msgID, from: from, to: named, content: notice.plainText(feed: feed), at: chatNow(),
                            sender: sender, isPrivate: direct)
        sm.feed = feed
        sm.notice = notice
        do {
            if try st.insert(&sm) { return ChatReceipt("duplicate") }
        } catch { return .refused("store: \(error)") }
        if !system { heard(from, answered: true) }
        published(room, sm)
        // Handed to those it names, and (a room notice) to the room's people — never to an agent it does not name.
        var recipients = named
        if !direct { for p in members(room) where p != from && isHuman(p) && !recipients.contains(p) { recipients.append(p) } }
        for r in recipients {
            setState(room, st, ChatState(msgID: sm.msgID, recipient: r, state: "queued", at: sm.at))
            deliverInOrder(room, st, [sm.msgID], to: r)
        }
        log("chat: notice \(Self.short(msgID)) from feed \(feed) in room \(room) (\(notice.kind), \(notice.severity))")
        return ChatReceipt("queued")
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
