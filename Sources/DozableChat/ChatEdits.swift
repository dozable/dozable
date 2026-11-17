import Foundation

// A sender may edit and delete its own messages; the human may also delete anyone's. An edit replaces the text and keeps
// nothing of the old one. A delete erases the text, attachments and reactions and leaves a tombstone, so the log keeps
// its order and answers still point at it. /edit, /delete and /react are not stored as messages: each is done
// once per msg_id (the `commands` table), and the page's calls are done once per `X-Chat-Id`. The human may reveal a
// direct message between others; that is recorded in the room.

extension ChatServerCore {
    static let editHelp = "use /edit ^<start of a msg_id> new text, or /edit new text for your own latest message"
    static let deleteHelp = "use /delete ^<start of a msg_id>, or /delete for your own latest message"

    /// Runs a command that is not stored as a message at most once per msg_id: the same id again is answered duplicate,
    /// with what the first did. A refused one is forgotten, so it may be sent again.
    func once(_ st: ChatRoomStore, _ msgID: String, _ sender: String, _ run: () -> ChatReceipt) -> ChatReceipt {
        let claim: (claimed: Bool, state: String, detail: String)
        do { claim = try st.claimCommand(msgID, sender: sender, at: chatNow()) } catch { return .refused("store: \(error)") }
        if !claim.claimed { return Self.duplicateOf(claim.state, claim.detail) }
        let rc = run()
        st.finishCommand(msgID, state: rc.state, detail: rc.detail)
        return rc
    }

    /// A page call done once per X-Chat-Id: none runs it each time; one that is not a uuid is answered 400 (nil here).
    public func pageOnce(id: String, room: String, who: String, _ run: () -> ChatReceipt) -> ChatReceipt? {
        if id.isEmpty { return run() }
        guard chatIsUUID(id) else { return nil }
        let room = room.isEmpty ? config.defaultRoom : room
        guard let st = try? store(room), member(room, who) else { return run() }   // refused by the call itself, in its own words
        return once(st, id, who, run)
    }

    /// What edit and delete share: the room exists, the sender is in it, and it is not archived.
    private func changeGate(_ room: inout String, _ sender: String, _ verb: String) -> Result<ChatRoomStore, ChatAPIError> {
        if room.isEmpty { room = config.defaultRoom }
        let st: ChatRoomStore
        do { st = try store(room) } catch { return .failure(ChatAPIError(status: 422, description: "\(error)")) }
        if !member(room, sender) { return .failure(ChatAPIError(status: 422, description: "\(sender) is not a member of room \(room)")) }
        if isArchived(room) {
            return .failure(ChatAPIError(status: 422, description: "room \(room) is archived: its messages cannot be \(verb). A human can reopen it with /unarchive"))
        }
        return .success(st)
    }

    /// The message an edit or delete names: by the start of its msg_id, or with none the sender's own latest. A direct
    /// message the sender may not read is treated as not there.
    private func changeTarget(_ st: ChatRoomStore, _ room: String, _ sender: String, _ ref: String) -> Result<ChatStored, ChatAPIError> {
        func fail(_ s: String) -> Result<ChatStored, ChatAPIError> { .failure(ChatAPIError(status: 422, description: s)) }
        func seen(_ id: String) -> Bool {
            guard let v = st.visibility(id) else { return false }
            var probe = ChatStored(msgID: id, from: v.from, to: v.to, at: 0)
            probe.isPrivate = v.isPrivate; probe.revealed = v.revealed
            return Self.canSee(probe, sender)
        }
        var id = ref
        if ref.isEmpty {
            id = st.latest(of: sender)
            if id.isEmpty { return fail("you have no message in room \(room) to change") }
        } else if ref.utf8.count < 36 {
            let ids = st.matching(ref, limit: 1000).filter(seen)
            if ids.isEmpty { return fail("no message in room \(room) starts with ^\(ref)") }
            if ids.count > 1 { return fail("more than one message starts with ^\(ref); give more of its id") }
            id = ids[0]
        } else if !seen(id) {
            return fail("no such message in room \(room)")
        }
        guard let m = try? st.one(id) else { return fail("no such message in room \(room)") }
        if !m.kind.isEmpty { return fail("only an ordinary message can be edited or deleted, not a recorded change") }
        if m.deleted { return fail("that message was already deleted") }
        return .success(m)
    }

    /// Replaces the text of sender's own message (ref: the start of its msg_id, or "" for the latest). edited,
    /// unchanged or refused.
    public func edit(room: String, sender: String, ref: String, text: String) -> ChatReceipt {
        var room = room
        let st: ChatRoomStore, m: ChatStored
        switch changeGate(&room, sender, "edited") {
        case .failure(let e): return .refused(e.description)
        case .success(let s): st = s
        }
        switch changeTarget(st, room, sender, ref) {
        case .failure(let e): return .refused(e.description)
        case .success(let x): m = x
        }
        if m.from != sender { return .refused("only \(m.from) can edit that message") }
        let text = Self.trimSpace(text)
        if let w = Self.fields(text).first, ChatProtocol.isCommandWord(w) {
            return .refused("an edit cannot be a command or a direct message: its kind and its recipients stay as they were")
        }
        if text.isEmpty && m.attachments.isEmpty { return .refused("an edit needs text. To remove the message, delete it") }
        if text == m.content { return ChatReceipt("unchanged") }
        var to = m.to, mentions: [String] = []
        if !m.isPrivate {   // the same rule as a post: whoever the new text names with @ is addressed
            mentions = mentionsIn(room: room, sender: m.from, text: text)
            to = m.to.filter { !m.mentions.contains($0) }
            for n in mentions where !to.contains(n) { to.append(n) }
        }
        do { try st.edit(m.msgID, content: text, to: to, mentions: mentions, at: chatNow()) } catch { return .refused("store: \(error)") }
        heard(sender, answered: true)
        guard let after = try? st.one(m.msgID) else { return .refused("store: no such message") }
        published(room, after, kind: "edited")
        tellHanded(room, st, before: m, after: after, kind: "edited", by: sender)
        return ChatReceipt("edited")
    }

    /// Erases a message and leaves a tombstone: the sender's own, or anyone's by a human. deleted or refused.
    public func delete(room: String, who: String, ref: String) -> ChatReceipt {
        var room = room
        let st: ChatRoomStore, m: ChatStored
        switch changeGate(&room, who, "deleted") {
        case .failure(let e): return .refused(e.description)
        case .success(let s): st = s
        }
        switch changeTarget(st, room, who, ref) {
        case .failure(let e): return .refused(e.description)
        case .success(let x): m = x
        }
        if m.from != who && !isHuman(who) { return .refused("only \(m.from) or a human can delete that message") }
        let at = chatNow()
        do { try st.delete(m.msgID, by: who, at: at) } catch { return .refused("store: \(error)") }
        heard(who, answered: true)
        // whoever has not been handed it is not going to be
        for s in m.states where ["queued", "held", "failed"].contains(s.state) && !handedTo(st, m.msgID, s.recipient) {
            setState(room, st, ChatState(msgID: m.msgID, recipient: s.recipient, state: "cancelled", at: at, detail: "the message was deleted before it was handed over"))
        }
        dropFiles(m)   // its files, unless another message still names them
        guard let after = try? st.one(m.msgID) else { return .refused("store: no such message") }
        published(room, after, kind: "deleted")
        tellHanded(room, st, before: m, after: after, kind: "deleted", by: who)
        return ChatReceipt("deleted")
    }

    /// "/edit [^id] text" and "/delete [^id]". A `^id` a session's prefix handling turned into re_msg_id is not used.
    func changeCommand(_ room: String, _ sender: String, _ text: String) -> ChatReceipt {
        let f = Self.fields(text)
        let t = Self.trimSpace(text)
        var rest = Self.trimSpace(t.hasPrefix(f[0]) ? String(t.dropFirst(f[0].count)) : t)
        var ref = ""
        if let w = Self.fields(rest).first, Self.isIDPrefix(w) {
            ref = String(w.dropFirst())
            rest = Self.trimSpace(rest.hasPrefix(w) ? String(rest.dropFirst(w.count)) : rest)
        }
        if f[0] == "/delete" {
            return rest.isEmpty ? delete(room: room, who: sender, ref: ref) : .refused(Self.deleteHelp)
        }
        return rest.isEmpty ? .refused(Self.editHelp) : edit(room: room, sender: sender, ref: ref, text: rest)
    }

    /// Tells those who were handed a message, and whom it addresses, that it was edited or deleted.
    func tellHanded(_ room: String, _ st: ChatRoomStore, before: ChatStored, after: ChatStored, kind: String, by: String) {
        for r in members(room) {
            if r == after.from || (after.isPrivate && !after.to.contains(r)) { continue }
            if handedTo(st, after.msgID, r) && (Self.addressed(before, r) || Self.addressed(after, r)) {
                notify(room, after, to: r, kind: kind, by: by)
            }
        }
    }

    /// Hands one recipient a notice of an edit or delete, the way it takes messages. A page needs none (the stream
    /// tells it).
    func notify(_ room: String, _ m: ChatStored, to: String, kind: String, by: String) {
        guard let p = participant(to) else { return }
        switch p.route {
        case "webhook": notifyWebhook(room, m, p, kind: kind, by: by)
        case "inbox-socket": notifyInbox(room, m, p, kind: kind, by: by)
        case "poll": if let st = try? store(room) { queueNotice(room, st, m, to: to, kind: kind, by: by) }
        default: break
        }
    }

    /// Whether a recipient has the message for an edit or delete notice: a polling one once it confirmed it.
    func handedTo(_ st: ChatRoomStore, _ msgID: String, _ name: String) -> Bool {
        if participant(name)?.route == "poll" { return st.acked(msgID, by: name) }
        return st.handed(msgID, to: name)
    }

    static func editedNote(_ id: String) -> String { "This edits msg \(short(id)) and replaces the text you were given before." }

    func deletedNote(_ m: ChatStored, by: String) -> String {
        let who = by == m.from ? "its sender" : capitalFirst(by) + ", the owner"
        return "Msg \(Self.short(m.msgID)) from \(m.from) was deleted by \(who). Disregard it."
    }

    static func short(_ id: String) -> String { id.utf8.count > 8 ? String(decoding: Array(id.utf8.prefix(8)), as: UTF8.self) : id }

    /// The human reads a direct message between others; recorded in the room once.
    public func reveal(room: String, msgID: String, who: String) -> Result<ChatStored, ChatAPIError> {
        func fail(_ s: String) -> Result<ChatStored, ChatAPIError> { .failure(ChatAPIError(status: 400, description: s)) }
        let st: ChatRoomStore
        do { st = try store(room) } catch { return fail("\(error)") }
        if !isHuman(who) { return fail("only the human can reveal a direct message") }
        if !member(room, who) { return fail("\(who) is not a member of room \(room)") }
        let id = msgID.utf8.count < 36 ? st.fullID(msgID) : msgID
        guard var m = try? st.one(id), m.isPrivate else { return fail("no such direct message") }
        if !m.revealed {
            do { try st.setRevealed(id) } catch { return fail("\(error)") }
            m.revealed = true
            var ch = ChatStored.change(chatNewID(), from: who, content: "\(capitalFirst(who)) revealed a direct message from \(m.from) to \(m.to.joined(separator: ", "))", at: chatNow())
            if (try? st.insert(&ch)) == false { published(room, ch) }
            published(room, m, kind: "revealed")
        }
        return .success(m)
    }

    /// GET /api/unread: for every room the human is in, the newest seq and what came after the page's marker.
    public func unread(markers: (String) -> String) -> JValue {
        let who = human()
        var out: [String: JValue] = [:]
        for room in roomNames() where member(room, who) {
            guard let st = try? store(room) else { continue }
            let v = markers(room)
            let marker: Int64? = v.isEmpty ? nil : Int64(v).flatMap { $0 >= 0 ? $0 : nil }
            guard var u = try? st.unread(after: marker ?? 0, viewer: who) else { continue }
            if marker == nil { u.count = 0; u.mentions = 0 }   // no marker yet: read
            var o = JObject()
            o.add("last", .int(u.last)); o.add("count", .int(u.count)); o.add("mentions", .int(u.mentions))
            if let p = st.preview(viewer: who) {
                o.add("preview", .object([JMember("msg_id", .string(p.msgID)), JMember("sender", .string(p.from)),
                                          JMember("text", .string(p.text)), JMember("at", .double(p.at))]))
            }
            out[room] = o.value
        }
        return .map(out)
    }
}
