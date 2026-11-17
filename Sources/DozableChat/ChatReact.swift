import Foundation

// A reaction is a small mark one participant puts on a message: like, love, lol, … or an emoji of its own. The same
// reaction again takes it off. A reaction wakes nobody: no recipient is handed anything, no webhook is called. Three
// ways in, refused in the same words: a reaction line on the line port (done once per its own msg_id), "/react" in a
// message (done once per the message's msg_id) and the page's call (done once per X-Chat-Id).

extension ChatServerCore {
    /// Puts sender's reaction on a message, or takes it off. added, removed or refused. msgID may be the start of one.
    public func react(room: String, sender: String, msgID: String, what: String) -> ChatReceipt {
        let room = room.isEmpty ? config.defaultRoom : room
        let st: ChatRoomStore
        do { st = try store(room) } catch { return .refused("\(error)") }
        if !member(room, sender) { return .refused("\(sender) is not a member of room \(room)") }
        if isArchived(room) {
            return .refused("room \(room) is archived: its messages cannot be reacted to. A human can reopen it with /unarchive")
        }
        guard let r = ChatReactions.of(what) else { return .refused(ChatReactions.help) }
        let id = msgID.utf8.count < 36 ? st.fullID(msgID) : msgID
        if id.isEmpty || st.sender(of: id).isEmpty { return .refused("no such message in room \(room)") }
        if let m = try? st.one(id) {
            // a direct message the reactor may not read: the same answer as for an id that matches nothing
            if !Self.canSee(m, sender) { return .refused("no such message in room \(room)") }
            if m.deleted { return .refused("that message was deleted") }
        }
        let at = chatNow()
        let added: Bool
        do { added = try st.toggleReaction(id, who: sender, reaction: r.name, at: at) } catch { return .refused("store: \(error)") }
        heard(sender, answered: true)   // a reaction is an acknowledgement: whoever reacted is no longer thinking
        var e = ChatEvent(kind: "reaction", room: room)
        e.reaction = ChatReaction(msgID: id, who: sender, reaction: r.name, emoji: r.emoji, at: at, removed: !added).json
        publish(e)
        return ChatReceipt(added ? "added" : "removed")
    }

    /// A reaction line: its own msg_id makes it happen once, so a line sent again does not take the reaction off. A line
    /// with no msg_id is not remembered.
    public func reactOnce(room: String, sender: String, lineID: String, msgID: String, what: String) -> ChatReceipt {
        if lineID.isEmpty { return react(room: room, sender: sender, msgID: msgID, what: what) }
        let room = room.isEmpty ? config.defaultRoom : room
        guard let st = try? store(room), member(room, sender) else {
            return react(room: room, sender: sender, msgID: msgID, what: what)   // refused in its own words; nothing kept
        }
        return once(st, lineID, sender) { react(room: room, sender: sender, msgID: msgID, what: what) }
    }

    /// "/react [message] reaction" inside a message. target is the message the sender was answering, used when the
    /// command names none; with neither, the message last handed to the sender's Claude Code session.
    func reactCommand(_ room: String, _ sender: String, target: String, _ text: String) -> ChatReceipt {
        var f = Array(Self.fields(text).dropFirst())
        var target = target
        switch f.count {
        case 1: break
        case 2:
            target = f[0].hasPrefix("^") ? String(f[0].dropFirst()) : f[0]
            f = Array(f.dropFirst())
        default:
            return .refused("use /react like, or /react <start of a msg_id> like. " + ChatReactions.help)
        }
        if target.isEmpty { target = lastHanded(sender) }
        if target.isEmpty { return .refused("say which message: /react <start of its msg_id> like") }
        return react(room: room, sender: sender, msgID: target, what: f[0])
    }
}
