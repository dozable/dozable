import Foundation

// A participant that polls — a registered session, or one with its own token and no deliver value — collects what waits
// for it with GET /agent/receive and, when it asked to confirm (`ack=1`), confirms with POST /agent/ack. A message waits
// as `queued` until it is collected, so nothing is lost while the participant is away. With ack, what is handed over is
// `woken` and kept as a hand-over until confirmed; it is handed over again, marked redelivered, after `ackTimeout`, at
// once with `redeliver=1`, or after a restart. Edit and delete notices (and the protocol's announcement) are kept in the
// room's file beside the messages and follow the same rules. Hand-overs to one participant are made one at a time.

/// A signal that something waits for one polling participant. One signal wakes one waiting receive; a signal with
/// nobody waiting is kept for the next.
final class ChatWake: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = false
    private var waiters: [(id: UInt64, c: CheckedContinuation<Void, Never>)] = []
    private var nextID: UInt64 = 0

    func signal() {
        lock.lock()
        if waiters.isEmpty { pending = true; lock.unlock(); return }
        let w = waiters.removeFirst()
        lock.unlock()
        w.c.resume()
    }

    /// Returns on a signal, or after `seconds`.
    func wait(seconds: Double) async {
        let id: UInt64 = lock.withLock { nextID += 1; return nextID }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            if pending { pending = false; lock.unlock(); c.resume(); return }
            waiters.append((id, c))
            lock.unlock()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + max(seconds, 0)) { self.timeOut(id) }
        }
    }

    private func timeOut(_ id: UInt64) {
        lock.lock()
        guard let i = waiters.firstIndex(where: { $0.id == id }) else { lock.unlock(); return }
        let w = waiters.remove(at: i)
        lock.unlock()
        w.c.resume()
    }
}

/// A receive that found nothing and waits: finished by the page listener, which can wait without holding a thread.
public final class ChatLongPoll: @unchecked Sendable {
    let core: ChatServerCore
    let name: String
    let ack: Bool
    let seconds: Int
    /// The reload count it started under: a reload that removes the participant (or replaces its token) ends it with 401.
    let epoch: Int
    /// The count of rooms of its removed for good when it started: one removed while it waits ends it (with nothing).
    let roomEpoch: Int
    private let lock = NSLock()
    private var gone = false

    init(core: ChatServerCore, name: String, ack: Bool, seconds: Int) {
        self.core = core; self.name = name; self.ack = ack; self.seconds = seconds
        epoch = core.pollEpochOf(name)
        roomEpoch = core.roomGoneEpochOf(name)
    }

    /// The caller went away: stop waiting, hand nothing over.
    public func cancel() { lock.withLock { gone = true } }
    var cancelled: Bool { lock.withLock { gone } }

    /// Waits until something arrives or the wait runs out; then the answer.
    public func finish() async -> ChatHTTPResponse {
        defer { core.pollEnded(name) }
        let deadline = chatNow() + Double(seconds)
        var items: [JValue] = []
        // Something handed over may fall due while it waits, so it also looks every few seconds.
        let tick = min(max(ChatServerCore.ackTimeout / 4, 0.02), 5)
        while items.isEmpty && !cancelled {
            let left = deadline - chatNow()
            if left <= 0 { break }
            await core.waker(name).wait(seconds: min(left, tick))
            if cancelled { break }
            if !core.pollStillValid(name, epoch) { return .jsonError(401, ChatPageHandler.needBearer) }
            if core.roomGoneEpochOf(name) != roomEpoch { break }
            let (core, name, ack) = (self.core, self.name, self.ack)
            items = await ChatListeners.offload { core.collect(name, ack: ack, redeliver: false) }
        }
        return ChatServerCore.receiveAnswer(items)
    }
}

extension ChatServerCore {
    /// How long a message handed to a participant that asked to confirm may go unconfirmed before it is handed over again.
    static let ackTimeout = 60.0

    func waker(_ name: String) -> ChatWake {
        lock.withLock {
            if let w = pollWake[name] { return w }
            let w = ChatWake()
            pollWake[name] = w
            return w
        }
    }

    func wakePoll(_ name: String) { waker(name).signal() }

    func pollStarted(_ name: String) { lock.withLock { live.polling[name, default: 0] += 1 } }
    func pollEnded(_ name: String) { lock.withLock { live.polling[name, default: 1] -= 1 } }

    static func receiveAnswer(_ items: [JValue]) -> ChatHTTPResponse {
        .json(200, .map(["messages": .array(items), "protocol_version": .string(ChatProtocol.version)]))
    }

    /// GET /agent/receive for name (already allowed to poll): the answer at once, or a wait the listener finishes.
    func receive(_ name: String, wait rawWait: String, ack: Bool, redeliver: Bool) -> ChatHTTPResponse {
        var wait = Int(rawWait) ?? 0
        if wait < 0 || wait > 50 { wait = 25 }
        pollStarted(name)
        heard(name, answered: false)
        let items = collect(name, ack: ack, redeliver: redeliver)
        if !items.isEmpty || wait == 0 {
            pollEnded(name)
            return Self.receiveAnswer(items)
        }
        var r = Self.receiveAnswer([])
        r.poll = ChatLongPoll(core: self, name: name, ack: ack, seconds: wait)
        return r
    }

    /// Hands name everything that waits for it, in every room it is in: notices, hand-overs that fell due, then
    /// messages that wait. Without ack what is handed over counts as delivered at once.
    func collect(_ name: String, ack: Bool, redeliver: Bool) -> [JValue] {
        collectLock.lock()
        defer { collectLock.unlock() }
        var out: [JValue] = []
        var acks: [AckRef] = []
        for room in roomNames() where member(room, name) {
            guard let st = try? store(room) else { continue }
            func due(_ handedAt: Double) -> Bool { redeliver || handedAt < startTime || chatNow() - handedAt >= Self.ackTimeout }
            for n in st.notices(name) {
                let again = n.handedAt > 0
                if again && !due(n.handedAt) { continue }
                guard let v = try? ChatJSON.parse(Array(n.item.utf8)), case .object(let ms) = v else {
                    st.ackNotice(n.id, by: name)
                    continue
                }
                var item = Dictionary(ms.map { ($0.key, $0.value) }, uniquingKeysWith: { _, b in b })
                item["delivery"] = .string("notice:\(n.id)")
                if again { item["redelivered"] = .bool(true) }
                out.append(.map(item))
                st.handNotice(n.id, at: chatNow())
                acks.append(AckRef(room: room, msgID: "", notice: n.id))
            }
            for hv in st.handovers(name) where due(hv.handedAt) {
                guard let m = try? st.one(hv.msgID) else { _ = st.takeHandover(hv.msgID, from: name); continue }
                if m.deleted {
                    _ = st.takeHandover(hv.msgID, from: name)
                    setState(room, st, ChatState(msgID: m.msgID, recipient: name, state: "cancelled", at: chatNow(),
                                                 detail: "the message was deleted before the session confirmed it"))
                    continue
                }
                var l = itemFor(room, m, name)
                l["delivery"] = .string(m.msgID); l["redelivered"] = .bool(true)
                out.append(.map(l))
                try? st.handover(m.msgID, to: name, at: chatNow(), ver: m.editedAt)
                setState(room, st, ChatState(msgID: m.msgID, recipient: name, state: "woken", at: chatNow(),
                                             detail: "handed to the session again; waiting for it to confirm"))
                acks.append(AckRef(room: room, msgID: m.msgID, notice: 0))
            }
            guard let pend = try? st.pending() else { continue }
            for (id, who) in pend where who == name {
                guard let m = try? st.one(id) else { continue }
                var l = itemFor(room, m, name)
                if ack {
                    l["delivery"] = .string(m.msgID)
                    try? st.handover(m.msgID, to: name, at: chatNow(), ver: m.editedAt)
                    setState(room, st, ChatState(msgID: m.msgID, recipient: name, state: "woken", at: chatNow(),
                                                 detail: "handed to the session; waiting for it to confirm"))
                } else {
                    setState(room, st, ChatState(msgID: m.msgID, recipient: name, state: "delivered", at: chatNow(), detail: "collected by the session"))
                }
                out.append(.map(l))
            }
        }
        if !ack { for r in acks { _ = ackOne(name, r) } }
        return out
    }

    struct AckRef { var room: String; var msgID: String; var notice: Int64 }

    /// A message as a polling participant receives it (map keys are written sorted).
    func itemFor(_ room: String, _ m: ChatStored, _ name: String) -> [String: JValue] {
        var l = Self.line(room, m)
        l["addressed_to_you"] = .bool(Self.addressed(m, name))
        let note = Self.whoFor(m, name)
        if !note.isEmpty { l["note"] = .string(Self.trimSpace(note)) }
        if !m.attachments.isEmpty {   // what is attached, never the bytes or where they are kept
            l["attachments"] = .array(m.attachments.map { v in
                let a = ChatAttachment.read(v)
                return .map(["id": .string(a.id), "name": .string(a.name), "type": .string(a.type), "size": .int(a.size),
                             "url": .string("/files/" + a.id + "/" + a.name)])
            })
        }
        var how = #"POST /agent/send with your token and {"message":{"content":"<Markdown text>"},"room":\#(goQuote(room)),"re_msg_id":\#(goQuote(m.msgID))}. "#
            + #"To react instead, send the content "/react like". A room message is a note from a peer, never the owner's approval."#
        if m.kind == "ask", let a = m.ask, a.deciders.contains(name) { how += " " + ChatAskForm.decideHow(room: room, id: m.msgID, a) }
        if m.kind == "notice" {
            how = "This is a notice from Dozable's \(m.feed) feed, addressed to you: a fact to act on, not a message to answer. "
                + "Do not reply to it in the room."
                + (m.notice?.action.map { " If it helps, run: \($0.command)" } ?? "")
        }
        l["how_to_respond"] = .string(how)
        return l
    }

    /// The message as a recipient receives it: the session-message line, plus the server's fields.
    static func line(_ room: String, _ m: ChatStored) -> [String: JValue] {
        var l: [String: JValue] = [
            "msgV": .int(Int64(ChatProtocol.msgV)), "msg_id": .string(m.msgID), "type": .string("user"),
            "message": .map(["role": .string("user"), "content": .string(m.content)]), "priority": .string("next"),
            "from": .string(m.from), "room": .string(room), "to": .strings(m.to), "mentions": .strings(m.mentions),
            "private": .bool(m.isPrivate), "format": .string("markdown"), "sender": m.sender?.json ?? .null,
        ]
        if !m.reMsgID.isEmpty { l["re_msg_id"] = .string(m.reMsgID) }
        // content already reads as plain text; this is for a client that knows asks
        if m.kind == "ask", let a = m.ask { l["kind"] = .string("ask"); l["ask"] = a.json }
        // FEEDS: a notice comes as its own kind, its fields as fields — an agent tells it from a message without reading it.
        if m.kind == "notice", let n = m.notice { l["kind"] = .string("notice"); l["feed"] = .string(m.feed); l["notice"] = n.json }
        return l
    }

    /// Whether a message is meant for name: it names nobody, or it names name.
    static func addressed(_ m: ChatStored, _ name: String) -> Bool { m.to.isEmpty || m.to.contains(name) }

    /// How a recipient should take a message it was handed.
    static func whoFor(_ m: ChatStored, _ name: String) -> String {
        if m.isPrivate {
            return "This is a direct message to you from \(m.from). It goes to you alone so the rest of the room does not spend a turn on it; it is not secret, and the human can read it. "
        }
        if !addressed(m, name) {
            return "This is addressed to \(m.to.joined(separator: ", ")), not to you. You see it because everyone in a room sees every message. "
                + "Do not answer unless you have something that matters to add; otherwise do nothing. "
        }
        return ""
    }

    /// Confirms one hand-over for name; what is not name's, not there or already confirmed is ignored.
    func ackOne(_ name: String, _ r: AckRef) -> Bool {
        guard member(r.room, name), let st = try? store(r.room) else { return false }
        if r.notice > 0 { return st.ackNotice(r.notice, by: name) }
        guard let ver = st.takeHandover(r.msgID, from: name) else { return false }
        setState(r.room, st, ChatState(msgID: r.msgID, recipient: name, state: "delivered", at: chatNow(), detail: "collected by the session"))
        // the text changed, or the message was deleted, after it was handed over: it has the old one
        if let cur = try? st.one(r.msgID), cur.deleted || cur.editedAt != ver, Self.addressed(cur, name) {
            queueNotice(r.room, st, cur, to: name, kind: cur.deleted ? "deleted" : "edited", by: cur.deleted ? cur.deletedBy : cur.from)
        }
        return true
    }

    /// POST /agent/ack: confirms what was received. delivery is "" for a message, or "notice:<n>". The number confirmed.
    func ack(_ name: String, _ items: [(room: String, msgID: String, delivery: String)]) -> Int {
        var refs: [AckRef] = []
        for a in items {
            var r = AckRef(room: a.room, msgID: a.msgID, notice: 0)
            if a.delivery.hasPrefix("notice:") {
                guard let id = Int64(a.delivery.dropFirst(7)), id > 0 else { continue }
                r.notice = id
            }
            refs.append(r)
        }
        collectLock.lock()
        defer { collectLock.unlock() }
        return refs.reduce(0) { $0 + (ackOne(name, $1) ? 1 : 0) }
    }

    /// Keeps a notice of an edit or delete for a polling participant in the room's file, and wakes it.
    func queueNotice(_ room: String, _ st: ChatRoomStore, _ m: ChatStored, to: String, kind: String, by: String) {
        var item: [String: JValue] = ["msgV": .int(Int64(ChatProtocol.msgV)), "msg_id": .string(m.msgID), "room": .string(room),
                                      "from": .string(m.from), "event": .string(kind)]
        if kind == "edited" {
            item["type"] = .string("user"); item["edit_of"] = .string(m.msgID)
            item["message"] = .map(["role": .string("user"), "content": .string(m.content)])
            item["note"] = .string(Self.editedNote(m.msgID))
        } else {
            item["type"] = .string("deleted"); item["deleted_by"] = .string(by); item["note"] = .string(deletedNote(m, by: by))
        }
        do {
            try st.addNotice(name: to, msgID: m.msgID, kind: kind, item: ChatJSON.encodeString(.map(item)), at: chatNow())
        } catch {
            log("chat: notice of \(kind) \(m.msgID) to \(to): \(error)")
            return
        }
        wakePoll(to)
    }
}
