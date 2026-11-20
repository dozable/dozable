import DozableChat
import Foundation

// Asks for people: `chat-ask`, `chat-decide`, `chat-withdraw` and `chat-asks` — `doz chat ask|decide|withdraw|asks`, the
// dashboard's decision card and the space diagram all come here. Each is ONE fixed call on the chat server's owner's
// socket, as you, built from checked values (`WorkspaceChat`'s ask calls below): a room name, an ask's `#N` or the start
// of its msg_id, and a decision in one of the protocol's forms. A decision is made once per `actionID` (its `X-Chat-Id`:
// a retry is a duplicate, never a second decision). A refusal is read again — the ask's state AFTER it — and told in
// Dozable's words (`ChatAskRefusal`). Dozable never speaks for an agent: an agent asks and answers with its own token
// (dozchat), so a request made as one (`--as W/AGENT`) that its permissions allowed is still refused here.
// docs/engineering/chat.md, "Asks".

extension WorkspaceChat {
    /// `#N` → `%23N` in a path (the page percent-decodes it); a msg_id's start is hex and dashes already.
    static func askPath(_ ref: String) -> String { ref.replacingOccurrences(of: "#", with: "%23") }

    /// Posts an ask in `room` as you: `content` is its title, `spec` the ask object, `msgID` makes it once.
    public func ask(room: String, content: String, spec: JValue, msgID: String) throws -> (Int, JValue) {
        try ownerCall("POST", "/api/rooms/\(room)/messages", body: .map(["content": .string(content), "kind": .string("ask"), "ask": spec,
                                                                          "msg_id": .string(msgID)]), headers: [])
    }

    /// Decides `ref` in `room` as you, once per `actionID`.
    public func decide(room: String, ref: String, body: JValue, actionID: String) throws -> (Int, JValue) {
        try ownerCall("POST", "/api/rooms/\(room)/messages/\(Self.askPath(ref))/decide", body: body, headers: [("X-Chat-Id", actionID)])
    }

    /// Withdraws your own ask `ref` in `room`, once per `actionID`.
    public func withdraw(room: String, ref: String, actionID: String) throws -> (Int, JValue) {
        try ownerCall("POST", "/api/rooms/\(room)/messages/\(Self.askPath(ref))/withdraw", body: nil, headers: [("X-Chat-Id", actionID)])
    }

    /// The ask `ref` of `room` as you see it now: the whole message.
    public func lookAsk(room: String, ref: String) throws -> (Int, JValue) {
        try ownerCall("GET", "/agent/asks/\(Self.askPath(ref))?room=\(room)", body: nil, headers: [])
    }

    /// The open asks of every room you are in (`[{room, message}]`).
    public func openAsks() throws -> [OpenAsk] {
        let (status, v) = try ownerCall("GET", "/api/asks?state=open", body: nil, headers: [])
        guard status == 200, case .array(let rows) = v else { throw HostError(.failed, "the chat server answered \(status)") }
        return rows.compactMap { row in
            guard let room = row.field("room")?.stringValue, let m = row.field("message") else { return nil }
            return OpenAsk.of(m, room: room)
        }
    }
}

extension OpenAsk {
    /// An open ask read from its message (nil: not an ask).
    public static func of(_ m: JValue, room: String) -> OpenAsk? {
        guard let a = ChatAsk.read(message: m), let id = m.field("msg_id")?.stringValue else { return nil }
        let one = a.questions.count == 1 ? a.questions[0] : nil
        var o = OpenAsk(room: room, msgId: id, from: m.field("from")?.stringValue ?? "", at: m.field("at")?.doubleValue ?? 0, title: a.title,
                        question: one.map { $0.question.isEmpty ? a.question : $0.question } ?? a.title,
                        options: (one?.multi == false) ? one!.options.map { $0.label.isEmpty ? $0.id : $0.label } : [],
                        questions: a.questions.count, multi: one?.multi ?? false, freeText: one?.freeText ?? false, deciders: a.deciders)
        o.number = a.number > 0 ? a.number : nil
        o.reason = a.reason.isEmpty ? nil : a.reason
        o.expiresAt = a.expiresAt.isEmpty ? nil : a.expiresAt
        o.noDecider = a.noDecider ? true : nil
        return o
    }
}

extension HostCore {
    /// What an agent hears instead: the daemon never speaks for one.
    static let neverForAnAgent = "Dozable never speaks for an agent: it asks and answers with its own token (dozchat ask | decide | withdraw)"

    func performChatAsk(_ r: HostRequest) async throws -> JSONValue {
        if r.actAs != nil { throw HostError(.notPermitted, Self.neverForAnAgent) }
        guard !readOnly else { throw HostError(.unavailable, "the chat server runs while the daemon does — doz chat status") }
        guard let chat = workspaceChat else { throw HostError(.unavailable, "chat is off — doz chat on") }
        switch await chat.readiness() {
        case .off: throw HostError(.unavailable, "chat is off — doz chat on")
        case .notReady(let why): throw HostError(.unavailable, why)
        case .ready: break
        }
        let q = r.chatAsk ?? ChatAskRequest()
        if r.op == .chatAsks {
            var asks = try chat.openAsks()
            if let room = q.room { asks = asks.filter { $0.room == room } }
            return try JSONValue(encoding: ChatAsksListing(asks: asks))
        }
        guard let room = q.room, chatIsRoomName(room) else { throw HostError(.invalid, "which room? (doz chat rooms)") }
        let actionID = try Self.actionID(q.actionID)
        switch r.op {
        case .chatAsk: return try JSONValue(encoding: try askPost(chat, room: room, q, msgID: actionID))
        case .chatDecide: return try JSONValue(encoding: try askDecide(chat, room: room, q, actionID: actionID))
        case .chatWithdraw: return try JSONValue(encoding: try askWithdraw(chat, room: room, q, actionID: actionID))
        default: throw HostError(.invalid, "not an ask operation")
        }
    }

    /// A lower-case v4 UUID, or a new one.
    static func actionID(_ s: String?) throws -> String {
        guard let s else { return UUID().uuidString.lowercased() }
        let u = Array(s.utf8)
        let hex: (UInt8) -> Bool = { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
        let ok = u.count == 36 && u.enumerated().allSatisfy { i, c in [8, 13, 18, 23].contains(i) ? c == 0x2D : hex(c) } && u[14] == 0x34
            && [0x38, 0x39, 0x61, 0x62].contains(u[19])
        guard ok else { throw HostError(.invalid, "actionID must be a lower-case v4 UUID") }
        return s
    }

    static func askRef(_ s: String?) throws -> String {
        let ref = ChatAskRef.normalise(s ?? "")
        guard ChatAskRef.isValid(ref) else { throw HostError(.invalid, "which ask? #N, or the start of its id (doz chat asks)") }
        return ref
    }

    /// The server's words for a refusal.
    static func detail(_ v: JValue, _ status: Int) -> String {
        v.field("detail")?.stringValue ?? v.field("error")?.stringValue ?? "refused (\(status))"
    }

    /// The ask now, or nil.
    func askNow(_ chat: WorkspaceChat, room: String, ref: String) -> (ChatAsk, JValue)? {
        guard let (status, m) = try? chat.lookAsk(room: room, ref: ref), status == 200, let a = ChatAsk.read(message: m) else { return nil }
        return (a, m)
    }

    /// A refusal in Dozable's words: the ask read again decides which.
    func refusal(_ chat: WorkspaceChat, room: String, ref: String, _ v: JValue, _ status: Int) -> HostError {
        let d = Self.detail(v, status)
        let r = ChatAskRefusal.classify(detail: d, ask: askNow(chat, room: room, ref: ref)?.0)
        return HostError(.failed, r.words)
    }

    func outcome(_ chat: WorkspaceChat, room: String, ref: String, state: String) -> ChatAskOutcome {
        guard let (a, m) = askNow(chat, room: room, ref: ref) else { return ChatAskOutcome(room: room, ask: ref, msgId: "", state: state) }
        let id = m.field("msg_id")?.stringValue ?? ""
        var o = ChatAskOutcome(room: room, ask: ChatAsk.label(number: a.number, msgID: id), msgId: id, state: state)
        o.deciders = a.deciders
        o.askState = a.state
        if let d = a.decision {
            o.summary = ChatAskReply.summary(a, d)
            o.decidedBy = d.by
        }
        return o
    }

    func askPost(_ chat: WorkspaceChat, room: String, _ q: ChatAskRequest, msgID: String) throws -> ChatAskOutcome {
        let question = (q.question ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { throw HostError(.invalid, "say the question") }
        guard question.utf8.count <= 64 * 1024 else { throw HostError(.invalid, "the question is too long") }
        let spec: JValue
        do {
            let data = try JSONEncoder().encode(q.spec ?? .object([:]))
            guard data.count <= 64 * 1024 else { throw HostError(.invalid, "the ask is too long (at most 64 KiB)") }
            spec = try ChatJSON.parse(Array(data))
        } catch let e as HostError { throw e } catch { throw HostError(.invalid, "the ask is not JSON") }
        guard spec.isObject else { throw HostError(.invalid, "the ask must be a JSON object") }
        let (status, v) = try chat.ask(room: room, content: question, spec: spec, msgID: msgID)
        if status == 404 || status == 403 { throw HostError(.notFound, Self.detail(v, status)) }
        guard status == 200 else {
            let d = Self.detail(v, status)
            throw HostError(.failed, ChatAskRefusal.classify(detail: d, ask: nil).words)
        }
        let state = v.field("state")?.stringValue == "duplicate" ? "duplicate" : "asked"
        return outcome(chat, room: room, ref: msgID, state: state)
    }

    func askDecide(_ chat: WorkspaceChat, room: String, _ q: ChatAskRequest, actionID: String) throws -> ChatAskOutcome {
        let ref = try Self.askRef(q.ask)
        let forms = [q.answers != nil, q.decline == true, q.option != nil, q.reply != nil].filter { $0 }.count
        guard forms == 1 else { throw HostError(.invalid, "give exactly one of: the answers, decline, an option, or your answer in words") }
        if q.decline != true && q.option == nil && q.text != nil { throw HostError(.invalid, "text goes with decline or an option") }
        var input: ChatDecideInput
        if let answers = q.answers {
            input = ChatDecideInput(answers: answers.map { ChatAnswerIn(questionID: $0.questionId, options: $0.options ?? [], text: $0.text ?? "",
                                                                        skipped: $0.skipped ?? false) })
        } else if q.decline == true {
            input = ChatDecideInput(text: q.text ?? "", decline: true)
        } else if let o = q.option {
            input = ChatDecideInput(option: o, text: q.text ?? "")
        } else {
            guard let (status, m) = try? chat.lookAsk(room: room, ref: ref) else { throw HostError(.unavailable, "the chat server did not answer") }
            if status != 200 { throw HostError(status == 404 || status == 403 ? .notFound : .failed, Self.detail(m, status)) }
            guard let a = ChatAsk.read(message: m) else { throw HostError(.notFound, "\(ref) is not an ask") }
            // A closed ask is still sent: the same action id again is a duplicate, anything else the server's refusal.
            switch ChatAskReply.resolve(a, words: q.reply ?? "") {
            case .success(let i): input = i
            case .failure(let why): throw HostError(.failed, why.words)
            }
        }
        let (status, v) = try chat.decide(room: room, ref: ref, body: Self.decideBody(input), actionID: actionID)
        if status == 404 || status == 403 { throw HostError(.notFound, ChatAskRefusal.classify(detail: Self.detail(v, status), ask: nil).words) }
        if status == 400 { throw HostError(.invalid, Self.detail(v, status)) }
        guard status == 200 else { throw refusal(chat, room: room, ref: ref, v, status) }
        return outcome(chat, room: room, ref: ref, state: v.field("state")?.stringValue == "duplicate" ? "duplicate" : "decided")
    }

    func askWithdraw(_ chat: WorkspaceChat, room: String, _ q: ChatAskRequest, actionID: String) throws -> ChatAskOutcome {
        let ref = try Self.askRef(q.ask)
        let (status, v) = try chat.withdraw(room: room, ref: ref, actionID: actionID)
        if status == 404 || status == 403 { throw HostError(.notFound, ChatAskRefusal.classify(detail: Self.detail(v, status), ask: nil).words) }
        guard status == 200 else { throw refusal(chat, room: room, ref: ref, v, status) }
        return outcome(chat, room: room, ref: ref, state: v.field("state")?.stringValue == "duplicate" ? "duplicate" : "withdrawn")
    }

    /// The body of the page's decide, in the form the input has.
    static func decideBody(_ i: ChatDecideInput) -> JValue {
        if i.decline { return .map(["decline": .bool(true), "text": .string(i.text)]) }
        if !i.answers.isEmpty {
            return .map(["answers": .array(i.answers.map { a in
                var o = JObject()
                o.add("question_id", .string(a.questionID)); o.add("options", .strings(a.options)); o.add("text", .string(a.text))
                if a.skipped { o.add("skipped", .bool(true)) }
                return o.value
            })])
        }
        return .map(["option": .string(i.option), "text": .string(i.text)])
    }
}
