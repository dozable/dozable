import Foundation

// Delivery by webhook (the protocol's 7.1, 7.3, 7.4, 7.6, 7.7 and its webhook document): a bot whose `deliver` is
// `webhook` is woken by a POST of one JSON object to the address of its webhook entry. The call runs off the poster's
// thread and off every other recipient's, so a slow or dead webhook delays nobody else: tried at once, 5 s later and
// 20 s after that (`webhookBackoff`), each try with its deadline; a 2xx answer marks the message woken and delivered,
// three failures mark it failed with the last reason. Edits and deletes of a message a bot was handed are told to it
// the same way; the protocol's announcement is tried once. At start, what was recorded but not handed over when the
// server last stopped is handed over again (at least once: a recipient tells a repeat by its msg_id), unless it is a
// day old. A stop abandons a call that is still waiting to be tried; its message stays queued for the next start.

extension ChatServerCore {
    enum WebhookOutcome { case accepted(String), failed(String), abandoned }

    /// Runs work off the caller's thread, counted, so a stop can wait for it; nothing new starts once a stop has begun.
    @discardableResult
    func background(_ work: @escaping @Sendable () async -> Void) -> Bool {
        let go = lock.withLock { () -> Bool in
            if stopping { return false }
            deliveries += 1
            return true
        }
        guard go else { return false }
        Task.detached {
            await work()
            self.lock.withLock { self.deliveries -= 1 }
        }
        return true
    }

    var isStopping: Bool { lock.withLock { stopping } }

    /// Hands one recipient several messages, one after the other: at once for a page or a participant that polls, in
    /// the background for a webhook.
    func deliverInOrder(_ room: String, _ st: ChatRoomStore, _ ids: [String], to: String) {
        guard !ids.isEmpty else { return }
        let route = participant(to)?.route ?? ""
        guard route == "webhook" || route == "inbox-socket" else {
            for id in ids { deliver(room, st, id, to: to) }
            return
        }
        background {
            for id in ids {
                if route == "inbox-socket" {
                    self.deliverInbox(room, st, id, to: to)
                } else if await !self.deliverWebhook(room, st, id, to: to) { break }
            }
        }
    }

    /// Calls a bot's webhook for one message and records what came of it. false when the server is stopping and the
    /// call was abandoned (the message stays queued).
    func deliverWebhook(_ room: String, _ st: ChatRoomStore, _ msgID: String, to: String) async -> Bool {
        // what is handed over is what the log says now: a message edited while it waited goes out with its new text,
        // and one deleted while it waited is not handed over at all
        guard let m = try? st.one(msgID) else { return true }
        if m.deleted {
            setState(room, st, ChatState(msgID: msgID, recipient: to, state: "cancelled", at: chatNow(), detail: "the message was deleted before it was handed over"))
            return true
        }
        guard let p = participant(to) else {
            setState(room, st, ChatState(msgID: msgID, recipient: to, state: "failed", at: chatNow(), detail: "not in the directory"))
            return true
        }
        switch await postWebhook(p, messageBody(room, m, p)) {
        case .abandoned:
            return false
        case .failed(let why):
            log("chat: deliver \(msgID) to \(to): \(why)")
            setState(room, st, ChatState(msgID: msgID, recipient: to, state: "failed", at: chatNow(), detail: why))
        case .accepted(let detail):
            mark(to, \.woken)
            setState(room, st, ChatState(msgID: msgID, recipient: to, state: "woken", at: chatNow(), detail: detail))
            setState(room, st, ChatState(msgID: msgID, recipient: to, state: "delivered", at: chatNow(), detail: detail))
            // an edit or delete that landed while it was being handed over: the bot has the old text
            if let cur = try? st.one(msgID), cur.deleted || cur.content != m.content, Self.addressed(cur, to) {
                notify(room, cur, to: to, kind: cur.deleted ? "deleted" : "edited", by: cur.deleted ? cur.deletedBy : cur.from)
            }
        }
        return true
    }

    /// The body of a `chan-message` call: the message as a recipient receives it, and what a bot woken with no memory
    /// of its last run needs to answer, react or say it started. Written with its keys sorted, as every JSON map.
    func messageBody(_ room: String, _ m: ChatStored, _ p: ChatParticipant) -> [String: JValue] {
        var body = Self.line(room, m)
        let scalars = m.content.unicodeScalars
        let text = scalars.count > 600 ? String(String.UnicodeScalarView(scalars.prefix(600))) + " … (cut)" : m.content
        body["event"] = .string("chan-message")
        body["text"] = .string(text)
        body["protocol_version"] = .string(ChatProtocol.version)
        body["addressed_to_you"] = .bool(Self.addressed(m, p.name))
        let note = Self.whoFor(m, p.name)
        if !note.isEmpty { body["note"] = .string(Self.trimSpace(note)) }
        if !m.attachments.isEmpty {   // what is attached, never the bytes
            body["attachments"] = .array(m.attachments.map { a in
                let id = a.field("id")?.stringValue ?? ""
                return .map(["id": .string(id), "name": a.field("name") ?? .string(""), "type": a.field("type") ?? .string(""),
                             "size": a.field("size") ?? .int(0),
                             "fetch": .string(#"{"msgV":1,"msg_id":"<new uuid>","type":"control","action":"file","id":\#(goQuote(id))}"#)])
            })
        }
        var head = "[switchboard] room \(room), message \(m.msgID) from \(m.from)"
        if !m.reMsgID.isEmpty { head += ", answering " + m.reMsgID }
        body["message_text"] = .string(head + "\n\n" + m.content)
        let (r, id) = (goQuote(room), goQuote(m.msgID))
        // Every wake names this server and its line address: a bot may be in several chat servers that share its webhook,
        // and must answer the one that woke it, never a default.
        let at = lineAddress
        body["server"] = .map(["version": .string(release), "line": .string(at)])
        body["how_to_respond"] = .map([
            "rule": .string("Answer THIS server (line port \(at)), in room \(r), with re_msg_id \(id), using the token this server gave you. Never a default server, port or room: you may be in other chat servers that share this webhook."),
            "where": .string("one TCP connection to this server's line port \(at): an auth line with this server's token, then one line below, then read one receipt line and close"),
            "answer": .string(#"{"msgV":1,"msg_id":"<new uuid>","type":"user","message":{"role":"user","content":"<Markdown text>"},"room":\#(r),"re_msg_id":\#(id)}"#),
            "react": .string(#"{"msgV":1,"msg_id":"<new uuid>","type":"reaction","room":\#(r),"re_msg_id":\#(id),"reaction":"like"}"#),
            "reactions": .string("like, love, lol, wow, sad, thanks, yes, no, eyes, party, or any emoji. The same reaction again takes it off. React when no words are needed."),
            "attach": .string(#"To send a file, add "attachments":[{"name":"<file name>","data_base64":"<the bytes, base64>"}] to the answer line. At most 10 files of 20 MB each. To read an attachment, send its fetch line; the reply carries data_base64."#),
            "started": .string(#"{"msgV":1,"msg_id":"<new uuid>","type":"control","action":"thinking","room":\#(r),"re_msg_id":\#(id)}"#),
        ])
        if m.kind == "ask", let a = m.ask, a.deciders.contains(p.name), case .object(var how)? = body["how_to_respond"] {
            let decide = a.questions.count == 1
                ? #"{"msgV":1,"msg_id":"<new uuid>","type":"user","message":{"role":"user","content":"/decide \#(m.msgID) <option id or letter, A for the first> [text]"},"room":\#(r)}"#
                : #"This ask has \#(a.questions.count) questions, so it is decided with decide_answers, not a line; the line {"msgV":1,"msg_id":"<new uuid>","type":"user","message":{"role":"user","content":"/decide \#(m.msgID) decline [text]"},"room":\#(r)} declines it"#
            how.append(JMember("decide", .string(decide)))
            how.append(JMember("decide_answers", .string("POST /agent/decide on this server's page port, with this server's token, and " + ChatAskForm.decideBody(room: room, id: m.msgID, a)
                + #" (an answer for every question); or {"room":\#(r),"ask_id":\#(id),"decline":true,"text":"<why>"} to decline"#)))
            body["how_to_respond"] = .map(Dictionary(how.map { ($0.key, $0.value) }, uniquingKeysWith: { _, b in b }))
        }
        return body
    }

    /// Sends a body to a participant's webhook, trying again as `webhookBackoff` says. The detail of a 2xx answer, or
    /// the last failure — the status, or why it could not be reached; never the address or the header.
    func postWebhook(_ p: ChatParticipant, _ body: [String: JValue]) async -> WebhookOutcome {
        guard let w = secrets.webhook(for: p.webhook) else {
            return .failed("no webhook address for \(p.name) in the file store or the Keychain")
        }
        let raw = ChatJSON.encode(.map(body))
        var last = "webhook: not tried"
        for (i, wait) in webhookBackoff.enumerated() {
            guard await pause(wait) else { return .abandoned }
            switch await webhookPoster.post(url: w.url, authorization: w.header, body: raw, timeout: webhookTimeout) {
            case .answered(let status, let ms) where (200..<300).contains(status):
                return .accepted("its webhook accepted it (\(status)) in \(ms) ms")
            case .answered(let status, _):
                last = "webhook try \(i + 1): status \(status)"
            case .unreachable(let why):
                last = "webhook try \(i + 1): could not reach the webhook (\(why))"
            }
        }
        return .failed(last)
    }

    /// Waits before a try; false when the server began to stop (then nothing more is tried).
    func pause(_ seconds: Double) async -> Bool {
        let until = chatNow() + seconds
        while true {
            if isStopping { return false }
            let left = until - chatNow()
            if left <= 0 { return true }
            try? await Task.sleep(nanoseconds: UInt64(min(left, 0.05) * 1e9))
        }
    }

    /// A notice of an edit or delete to a bot by webhook: `chan-message-edited` with the new text (not cut), or
    /// `chan-message-deleted` with who deleted it.
    func notifyWebhook(_ room: String, _ m: ChatStored, _ p: ChatParticipant, kind: String, by: String) {
        var body: [String: JValue] = ["event": .string("chan-message-" + kind), "protocol_version": .string(ChatProtocol.version),
                                      "room": .string(room), "msg_id": .string(m.msgID), "from": .string(m.from)]
        if kind == "edited" {
            let note = Self.editedNote(m.msgID)
            body["text"] = .string(m.content); body["note"] = .string(note)
            body["message_text"] = .string("[switchboard] room \(room), message \(m.msgID) from \(m.from), edited\n\n\(m.content)\n\n\(note)")
        } else {
            let note = deletedNote(m, by: by)
            body["note"] = .string(note); body["deleted_by"] = .string(by)
            body["message_text"] = .string("[switchboard] room \(room): " + note)
        }
        let (id, to, sent) = (m.msgID, p.name, body)
        background {
            if case .failed(let why) = await self.postWebhook(p, sent) { self.log("chat: notice of \(kind) \(id) to \(to): \(why)") }
        }
    }

    /// The protocol's announcement to a bot: one try, whatever its answer.
    func protocolWebhook(_ p: ChatParticipant) {
        guard let w = secrets.webhook(for: p.webhook) else { return }
        let news = ChatProtocol.news, v = ChatProtocol.version
        let body: JValue = .map([
            "event": .string("protocol-updated"), "protocol_version": .string(v), "protocol": protocolJSON(),
            "text": .string("The switchboard's message protocol was updated to version \(v). \(news)"),
            "message_text": .string("[switchboard] The message protocol was updated to version \(v). \(news)"
                + " The full description is in this body under protocol. Update how you send if you want to use what is new. No answer is needed."),
        ])
        let raw = ChatJSON.encode(body)
        let (poster, timeout, name, group) = (webhookPoster, webhookTimeout, p.name, announcing)
        group.enter()
        let started = background {
            switch await poster.post(url: w.url, authorization: w.header, body: raw, timeout: timeout) {
            case .answered(let status, _): self.log("chat: protocol notice to \(name): \(status)")
            case .unreachable(let why): self.log("chat: protocol notice to \(name): could not reach the webhook (\(why))")
            }
            group.leave()
        }
        if !started { group.leave() }
    }

    /// Waits up to seconds for the announcement's webhook calls to be answered (or to fail).
    public func waitForAnnouncement(seconds: Double) {
        _ = announcing.wait(timeout: .now() + seconds)
    }

    /// At start: hands over again what was recorded and not handed over when the server last stopped — to a webhook,
    /// in order per recipient. A page reads what waited for it when it opens, and a participant that polls collects it;
    /// what is held stays held; a message queued more than `redeliverAfter` ago is left as it is. How many.
    @discardableResult
    public func redeliver() -> Int {
        var n = 0
        let now = chatNow()
        for room in roomNames() {
            guard let st = try? store(room) else { continue }
            let pend: [(String, String)]
            do { pend = try st.pending() } catch { log("chat: redeliver \(room): \(error)"); continue }
            var order: [String] = []
            var lists: [String: [String]] = [:]
            for (id, who) in pend {
                // a page reads what waited when it opens, and a participant that polls collects it
                guard let p = participant(who), p.route == "webhook" || p.route == "inbox-socket" else { continue }
                guard let m = try? st.one(id), now - Self.queuedAt(m, who) <= redeliverAfter else { continue }
                if lists[who] == nil { order.append(who) }
                lists[who, default: []].append(id)
                n += 1
            }
            for who in order { deliverInOrder(room, st, lists[who] ?? [], to: who) }
        }
        return n
    }

    /// When a message was last queued for a recipient: when it was sent, or, for one the hold kept back, when it was
    /// released. The limit on redelivery counts from then.
    static func queuedAt(_ m: ChatStored, _ to: String) -> Double {
        var at = m.at
        for s in m.states where s.recipient == to && s.state == "queued" && s.at > at { at = s.at }
        return at
    }
}
