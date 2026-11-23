import Foundation

// 766: Dozable's own asks — a proposal to change a workspace's work description, asked of the owner. Dozable never speaks
// for an agent and the one who asks cannot answer, so such an ask is posted under the server's own name
// (`ChatProtocol.systemName`), which no participant can have: the room's people are its deciders, as for any ask. Only the
// daemon makes one, over its control channel (`ChatRoomControl`: `systemAsk`, `systemAskClose`) — never an HTTP route, a
// file or a slash command.
//
// A proposal is about a run that is over, so its room is usually closed (its workspace finished): a closed room refuses
// every post and every decision, and expires its open asks, EXCEPT Dozable's own ask — it is posted, answered and kept open
// there (an archived room still refuses it). It expires like any ask (to decline). `systemAskClose` closes one Dozable
// decided by another way (`doz workspace decide`): withdrawn, and the outcome posted as a change line under the same name.

extension ChatServerCore {
    /// Posts Dozable's own ask in `room`: `question` is its text, `spec` its ask object, `msgID` makes it once (the same id
    /// again answers the ask already made). Answers its number and its msg_id.
    public func systemAsk(room: String, msgID: String, question: String, spec: ChatAskSpec) -> Result<(number: Int, msgID: String), ChatAPIError> {
        func no(_ status: Int, _ s: String) -> Result<(number: Int, msgID: String), ChatAPIError> { .failure(ChatAPIError(status: status, description: s)) }
        if !asksOn { return no(409, Self.askOff) }
        guard chatIsUUID(msgID) else { return no(400, "a system ask needs a uuid msg_id") }
        guard hasRoom(room) else { return no(404, "no room \(goQuote(room))") }
        if isArchived(room) { return no(409, Self.archivedRefusal(room)) }
        let st: ChatRoomStore
        do { st = try store(room) } catch { return no(404, "\(error)") }
        if st.knownID(msgID).known {
            guard let a = st.askOf(msgID) else { return no(409, "msg \(Self.short(msgID)) is not an ask") }
            return .success((a.number, msgID))
        }
        // Not refused in a closed room (above): the read of the close gate keeps the order of the lock (close gate → askLock).
        closeGate.read()
        defer { closeGate.done() }
        askLock.lock()
        defer { askLock.unlock() }
        var ask: ChatAsk
        switch newAsk(st, room: room, asker: ChatProtocol.systemName, question: question, spec: spec, system: true) {
        case .failure(let e): return .failure(e)
        case .success(let a): ask = a
        }
        ask.number = takeAskNumber()
        let content = ChatAskForm.text(id: msgID, asker: ChatProtocol.systemName, ask)
        var sm = ChatStored(msgID: msgID, from: ChatProtocol.systemName, to: ask.deciders, content: content, at: chatNow())
        sm.kind = "ask"
        sm.ask = ask
        do {
            if try st.insert(&sm) { return .success((ask.number, msgID)) }
        } catch { return no(500, "store: \(error)") }
        scheduleAsk(room, sm.msgID, at: ask.expires)
        published(room, sm)
        for r in members(room) {
            setState(room, st, ChatState(msgID: sm.msgID, recipient: r, state: "queued", at: sm.at))
            deliverInOrder(room, st, [sm.msgID], to: r)
        }
        log("chat: ask audit: Dozable asked \(Self.short(msgID)) in room \(room) (#\(ask.number))")
        return .success((ask.number, msgID))
    }

    /// Closes Dozable's own ask `msgID` in `room` that was decided another way: withdrawn (no cooldown, no decision), and
    /// `outcome` posted in the room as a change line under the server's name (not in an archived room). An ask already
    /// closed is left as it is. Answers its state after.
    public func systemAskClose(room: String, msgID: String, outcome: String) -> Result<String, ChatAPIError> {
        func no(_ status: Int, _ s: String) -> Result<String, ChatAPIError> { .failure(ChatAPIError(status: status, description: s)) }
        guard hasRoom(room) else { return no(404, "no room \(goQuote(room))") }
        let st: ChatRoomStore
        do { st = try store(room) } catch { return no(404, "\(error)") }
        guard let m = try? st.one(msgID), m.ask != nil else { return no(404, "no ask \(Self.short(msgID)) in room \(room)") }
        guard m.from == ChatProtocol.systemName else { return no(403, "ask \(Self.short(msgID)) is not Dozable's own") }
        let (state, closedNow): (String, Bool) = askLock.withLock {
            guard let a = st.askOf(msgID) else { return ("", false) }
            if a.state != "open" { return (a.state, false) }
            guard (try? st.closeAsk(msgID, state: "withdrawn", decision: nil, at: chatNow(), declined: false)) == true else {
                return (st.askOf(msgID)?.state ?? "", false)
            }
            askChanged(room, st, msgID, tell: false)
            return ("withdrawn", true)
        }
        if closedNow, !outcome.isEmpty, !isArchived(room) {
            var ch = ChatStored.change(chatNewID(), from: ChatProtocol.systemName, content: outcome, at: chatNow())
            if (try? st.insert(&ch)) == false { published(room, ch) }
        }
        return .success(state)
    }
}
