import Foundation

// Asks, the server's side (the protocol's section 13; the shapes and checks are ChatAsk.swift). An ask is a message that
// puts questions to named deciders and waits for a decision; the first valid decision wins; it may also expire or be
// withdrawn by its asker. Every change of state is an `ask` event on the stream, and the outcome is handed to the asker
// the way it takes messages. It fails closed: every ask can be declined, every ask expires, and on expiry the answer is
// decline.
//
// Locks, in the one order they are taken: the close gate (a post reads it) → `askLock` (one post of an ask, decide,
// withdraw or expiry at a time: the limits hold until an ask is stored, and the first decision wins) → the core's lock
// (short) → the expiry index's own lock (`ChatAskTimers`, innermost). Nothing that holds `askLock` takes the close gate,
// and the expiry timer takes `askLock` only after it has let go of its own; the closed set expires its rooms' asks after
// it let go of the close gate.
//
// Dozable's additions, each a deviation the engineering doc lists: a number per Mac (`#12`, accepted wherever an ask id
// is), a closed room (its asks expire at once and cannot be decided), the human's `GET /api/asks`, and the room removed
// for good taking its timers with it.

/// The expiry index: (room, msg_id) → when, and ONE timer armed for the earliest. Its lock is the innermost of all.
final class ChatAskTimers: @unchecked Sendable {
    private let lock = NSLock()
    private var due: [String: (room: String, id: String, at: Double)] = [:]
    private var timer: DispatchSourceTimer?
    private var closed = false
    private let queue = DispatchQueue(label: "chat.asks.expiry")
    /// What runs for each ask that falls due: set once, before anything is scheduled.
    var fire: (@Sendable (String, String) -> Void)?

    private static func key(_ room: String, _ id: String) -> String { room + "\u{0}" + id }

    func schedule(_ room: String, _ id: String, at: Double) {
        guard at > 0 else { return }
        lock.withLock {
            guard !closed else { return }
            due[Self.key(room, id)] = (room, id, at)
            rearmLocked()
        }
    }

    func cancel(_ room: String, _ id: String) { lock.withLock { if due.removeValue(forKey: Self.key(room, id)) != nil { rearmLocked() } } }

    func cancelRoom(_ room: String) {
        lock.withLock {
            due = due.filter { $0.value.room != room }
            rearmLocked()
        }
    }

    /// The server is closing: nothing fires any more.
    func stop() {
        lock.withLock {
            closed = true
            timer?.cancel(); timer = nil
            due = [:]
        }
    }

    var scheduled: [(room: String, id: String, at: Double)] { lock.withLock { Array(due.values) } }

    private func rearmLocked() {
        timer?.cancel(); timer = nil
        guard !closed, let next = due.values.map(\.at).min() else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + max(0, next - chatNow()), leeway: .milliseconds(20))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func tick() {
        let now = chatNow()
        let ready: [(String, String)] = lock.withLock {
            guard !closed else { return [] }
            let r = due.filter { $0.value.at <= now }
            for k in r.keys { due[k] = nil }
            return r.values.map { ($0.room, $0.id) }
        }
        for (room, id) in ready { fire?(room, id) }
        lock.withLock { rearmLocked() }
    }
}

extension ChatServerCore {
    static let askOff = "asks are off on this server"

    var asksOn: Bool { config.asksOn }

    // MARK: - Numbers (`#12`)

    static let askNumbersFile = "ask-numbers.json"

    /// At start: the next number is one more than the highest ever given — the data folder's high-water mark, or the
    /// highest a room's asks carry, whichever is higher. A number is never given twice, even after its room is removed.
    func loadAskNumbers() {
        var high = 0
        if let v = readJSON(Self.askNumbersFile), let n = (try? v.field("last")?.goInt("last")) ?? nil { high = n }
        for room in roomNames() { if let st = try? store(room) { high = max(high, st.maxAskNumber()) } }
        askLock.withLock { askNumberHigh = high }
    }

    /// The next number, written down before it is given. Under `askLock` (a post of an ask holds it).
    func takeAskNumber() -> Int {
        askNumberHigh += 1
        save(Self.askNumbersFile, .object([JMember("version", .int(1)), JMember("last", .int(Int64(askNumberHigh)))]))
        return askNumberHigh
    }

    // MARK: - Posting

    /// Checks what an asker sent and makes the ask it will be, in the reference's order and words. Under `askLock`.
    /// `system`: Dozable's own ask (`systemAsk`, from `ChatProtocol.systemName`) — no per-asker limit and no cooldown: it is
    /// one ask per proposal, never a participant's.
    func newAsk(_ st: ChatRoomStore, room: String, asker: String, question: String, spec: ChatAskSpec?, system: Bool = false) -> Result<ChatAsk, ChatAPIError> {
        func no(_ s: String) -> Result<ChatAsk, ChatAPIError> { .failure(ChatAPIError(status: 422, description: s)) }
        guard let spec else { return no(#"an ask needs an ask object: {"questions":[{"options":[{"id":"yes","label":"Yes"}]}]}"#) }
        if Self.trimSpace(question).isEmpty { return no("an ask needs a question: message.content is the question") }
        if ChatAskForm.isCommand(question) { return no("an ask's question cannot be a command") }
        var a = ChatAsk()
        a.question = question
        do { a.questions = try ChatAskForm.questions(content: question, spec: spec) } catch { return no("\(error)") }
        a.reason = Self.trimSpace(spec.reason)
        if ChatAsk.runes(a.reason) > ChatAsk.maxReason { return no("reason is at most \(ChatAsk.maxReason) characters") }
        // deciders: those named, or the room's humans now; never the asker; one that is not human only with the role
        var ds: [String] = []
        if !spec.deciders.isEmpty {
            for raw in spec.deciders {
                let n = Self.nameWord(raw)
                if n == asker { return no("the asker cannot be a decider of its own ask") }
                if !member(room, n) { return no("\(n) is not a member of room \(room), so cannot decide") }
                if !mayDecide(n) {
                    return no("\(n) does not have the decider role: only the owner can give a participant that is not human that role, in the config")
                }
                if !ds.contains(n) { ds.append(n) }
            }
        } else {
            ds = members(room).filter { $0 != asker && isHuman($0) }
            if ds.isEmpty { return no("room \(room) has no human but the asker: name the deciders") }
        }
        a.deciders = ds
        if let about = spec.about, !about.isNull {
            if ChatJSON.encode(about).count > ChatAsk.maxAbout { return no("about is at most \(ChatAsk.maxAbout) bytes") }
            guard about.isObject, let c = try? ChatAsk.canonical(about) else { return no("about must be a JSON object") }
            a.about = c
        }
        // every ask expires; on expiry the answer is decline
        let now = ChatTime.now()
        var t = now.adding(seconds: config.askExpiry)
        if !spec.expiresAt.isEmpty {
            guard let p = ChatTime.parse(spec.expiresAt) else { return no("expires_at must be a time in RFC 3339, such as 2026-11-18T17:00:00Z") }
            if p.seconds <= now.seconds { return no("expires_at is not in the future") }
            if p.seconds - now.seconds > ChatAsk.maxLifetime { return no("expires_at is at most 7 days ahead") }
            t = p
        }
        a.expiresAt = t.format()
        if !spec.onExpiry.isEmpty && spec.onExpiry != "decline" { return no("on_expiry can only be decline for now") }
        a.onExpiry = "decline"
        // against wearing the human down: so many open asks per asker and room, and no asking the same again at once
        expireDue(room, st)
        let most = config.askMaxOpenValue
        if !system, st.openAsksOf(asker) >= most {
            return no("\(asker) already has \(most) open ask(s) in room \(room), the most it may have: withdraw one or wait for its outcome")
        }
        let cd = config.askCooldown
        if !system, cd > 0, let at = st.declinedSince(asker, about: a.about, since: chatNow() - cd) {
            let again = ChatTime(sec: Int64((at + cd).rounded(.down)), nsec: 0).format(fraction: false)
            return no("an ask from \(asker) about the same thing was declined or expired a moment ago: ask again after \(again)")
        }
        a.digest = ChatAskForm.digest(a)
        return .success(a)
    }

    /// The expiry timer for an open ask.
    func scheduleAsk(_ room: String, _ id: String, at: Double) { askTimers.schedule(room, id, at: at) }

    // MARK: - Finding one

    /// The ask a decide, withdraw or look names: `#N` (its number here), its msg_id or the start of it (a leading `^`
    /// allowed). A direct message the caller may not read counts as not there.
    func findAsk(_ st: ChatRoomStore, room: String, who: String, ref raw: String) -> Result<ChatStored, ChatAPIError> {
        func no(_ s: String) -> Result<ChatStored, ChatAPIError> { .failure(ChatAPIError(status: 404, description: s)) }
        var ref = raw
        if ref.hasPrefix("^") { ref.removeFirst() }
        if ref.isEmpty { return no("say which ask: its msg_id, or the start of it") }
        var id = ref
        if ref.hasPrefix("#") {
            guard let n = Int(ref.dropFirst()), n > 0, let found = st.askNumbered(n) else { return no("no ask \(ref) in room \(room)") }
            id = found
        } else if ref.utf8.count < 36 {
            let ids = st.matching(ref, limit: 1000).filter { x in
                guard let v = st.visibility(x) else { return false }
                var probe = ChatStored(msgID: x, from: v.from, to: v.to, at: 0)
                probe.isPrivate = v.isPrivate; probe.revealed = v.revealed
                return Self.canSee(probe, who)
            }
            if ids.isEmpty { return no("no ask in room \(room) starts with \(ref)") }
            if ids.count > 1 { return no("more than one message starts with \(ref); give more of its id") }
            id = ids[0]
        }
        guard let m = try? st.one(id), Self.canSee(m, who) else { return no("no ask in room \(room) starts with \(ref)") }
        if m.kind != "ask" || m.ask == nil {
            return no(m.deleted ? "that message was deleted" : "msg \(Self.short(m.msgID)) is not an ask")
        }
        return .success(m)
    }

    /// What decide and withdraw share: asks are on, the room exists, the caller is in it, it is not archived (nor closed).
    /// `closed` false: the closed check is the caller's, once it knows the ask (Dozable's own is answered in a closed room).
    private func askGate(_ room: inout String, _ who: String, closed: Bool = true) -> (ChatRoomStore?, ChatReceipt) {
        if !asksOn { return (nil, .refused(Self.askOff)) }
        if room.isEmpty { room = config.defaultRoom }
        let st: ChatRoomStore
        do { st = try store(room) } catch { return (nil, .refused("\(error)")) }
        if !member(room, who) { return (nil, .refused("\(who) is not a member of room \(room)")) }
        if isArchived(room) { return (nil, .refused("room \(room) is archived: its asks cannot be answered. A human can reopen it with /unarchive")) }
        if closed, let no = closedRefusal(room) { return (nil, no) }
        return (st, ChatReceipt(""))
    }

    /// Why an ask that is not open cannot be decided or withdrawn.
    static func closedAskRefusal(_ a: ChatAsk?) -> String {
        switch a?.state ?? "" {
        case "decided":
            if let d = a?.decision, !d.option.isEmpty { return "this ask was already decided by \(d.by): \(d.option)" }
            if let d = a?.decision { return "this ask was already decided by " + d.by }
            return "this ask was already decided"
        case "expired": return "this ask has expired"
        case "withdrawn": return "this ask was withdrawn by its asker"
        default: return "this ask is closed"
        }
    }

    /// Whether a participant may be a decider at all: a human, or one the owner gave the role decider.
    func mayDecide(_ name: String) -> Bool {
        guard let p = participant(name) else { return false }
        return p.isHuman || p.hasRole("decider")
    }

    // MARK: - Deciding and withdrawing

    /// Decides an ask with what a decider sent (via: command, agent or page). decided, or refused with why; one line in
    /// the server's log either way.
    public func decide(room: String, who: String, ref: String, input: ChatDecideInput, via: String, verified: Bool) -> ChatReceipt {
        let rc = decideOnce(room, who, ref, input, via, verified)
        askAudit("decide", via, room, who, ref, input.summary, rc)
        return rc
    }

    private func decideOnce(_ roomIn: String, _ who: String, _ ref: String, _ input: ChatDecideInput, _ via: String, _ verified: Bool) -> ChatReceipt {
        var room = roomIn
        let (gate, refusal) = askGate(&room, who, closed: false)
        guard let st = gate else { return refusal }
        let m: ChatStored
        switch findAsk(st, room: room, who: who, ref: ref) {
        case .failure(let e): return .refused(e.description)
        case .success(let x): m = x
        }
        // A closed room answers no ask — but Dozable's own (a proposal about the run that closed it: ChatSystemAsks.swift).
        if m.from != ChatProtocol.systemName, let no = closedRefusal(room) { return no }
        askLock.lock()
        defer { askLock.unlock() }
        guard var a = st.askOf(m.msgID) else { return .refused("msg \(Self.short(m.msgID)) is not an ask") }
        if who == m.from { return .refused("the asker cannot decide its own ask") }
        if !mayDecide(who) {
            checkDecidersLocked(room, st, m.msgID)
            return .refused("\(who) does not have the decider role")
        }
        if !a.deciders.contains(who) { return .refused("\(who) is not a decider of this ask; its deciders are \(a.deciders.joined(separator: ", "))") }
        if a.state == "open" && a.expires > 0 && chatNow() >= a.expires {   // due, and the timer has not run yet
            expireLocked(room, st, m.msgID)
            a = st.askOf(m.msgID) ?? a
        }
        if a.state != "open" { return .refused(Self.closedAskRefusal(a)) }
        var input = input
        if !input.typed.isEmpty {   // a typed /decide: its words are read against the ask's questions
            let (parsed, bad) = ChatAskForm.parseTyped(a, input.typed)
            if !bad.isEmpty { return .refused(bad) }
            input = parsed
        }
        let checked = ChatAskForm.checkAnswers(a, input)
        if !checked.bad.isEmpty { return .refused(checked.bad) }
        let at = chatNow()
        var d = ChatAskDecision(by: who, sender: senderOf(who, verified: verified), declined: checked.declined, answers: checked.answers,
                                text: checked.text, at: at, digest: a.digest, via: via, deciderRole: !isHuman(who))
        ChatAskForm.compatFields(a, &d)
        let ok: Bool
        do { ok = try st.closeAsk(m.msgID, state: "decided", decision: d, at: at, declined: d.option == "decline") } catch {
            return .refused("store: \(error)")
        }
        if !ok { return .refused(Self.closedAskRefusal(st.askOf(m.msgID))) }
        heard(who, answered: true)
        askChanged(room, st, m.msgID, tell: true)
        return ChatReceipt("decided")
    }

    /// Closes an open ask without a decision. Only its asker may; it is told nothing (it did it), and no cooldown starts.
    public func withdraw(room: String, who: String, ref: String, via: String) -> ChatReceipt {
        let rc = withdrawOnce(room, who, ref)
        askAudit("withdraw", via, room, who, ref, "", rc)
        return rc
    }

    private func withdrawOnce(_ roomIn: String, _ who: String, _ ref: String) -> ChatReceipt {
        var room = roomIn
        let (gate, refusal) = askGate(&room, who)
        guard let st = gate else { return refusal }
        let m: ChatStored
        switch findAsk(st, room: room, who: who, ref: ref) {
        case .failure(let e): return .refused(e.description)
        case .success(let x): m = x
        }
        if who != m.from { return .refused("only \(m.from), who asked it, can withdraw this ask") }
        askLock.lock()
        defer { askLock.unlock() }
        if let a = st.askOf(m.msgID), a.state == "open", a.expires > 0, chatNow() >= a.expires { expireLocked(room, st, m.msgID) }
        let ok: Bool
        do { ok = try st.closeAsk(m.msgID, state: "withdrawn", decision: nil, at: chatNow(), declined: false) } catch { return .refused("store: \(error)") }
        if !ok { return .refused(Self.closedAskRefusal(st.askOf(m.msgID))) }
        heard(who, answered: true)
        askChanged(room, st, m.msgID, tell: false)
        return ChatReceipt("withdrawn")
    }

    /// One line in the server's log for every decide and withdraw: who, which ask, how, and what came of it. A refusal is
    /// never written into the room; this line and the refused party's own receipt are its only record.
    private func askAudit(_ verb: String, _ via: String, _ room: String, _ who: String, _ ref: String, _ option: String, _ rc: ChatReceipt) {
        if rc.state == "refused" {
            log("chat: ask audit: \(verb) refused by \(who) via \(via), ask \(ref) in room \(room), option \(goQuote(option)): refused: \(rc.detail)")
        } else {
            log("chat: ask audit: \(verb) by \(who) via \(via), ask \(ref) in room \(room), option \(goQuote(option)): \(rc.state)")
        }
    }

    /// "/decide <ask id> <option> [text]", and "/decide <ask id> <text>" for an answer in words.
    func decideCommand(_ room: String, _ sender: String, _ content: String, verified: Bool) -> ChatReceipt {
        if !asksOn { return .refused(Self.askOff) }
        if !verified { return .refused(Self.unverifiedAskCommand("/decide")) }
        let t = Self.trimSpace(content)
        let rest = Self.trimSpace(t.hasPrefix("/decide") ? String(t.dropFirst(7)) : t)
        let f = Self.fields(rest)
        if f.count < 2 { return .refused(ChatAskForm.decideHelp) }
        var input = ChatDecideInput()
        input.typed = Self.trimSpace(rest.hasPrefix(f[0]) ? String(rest.dropFirst(f[0].count)) : rest)
        return decide(room: room, who: sender, ref: f[0], input: input, via: "command", verified: verified)
    }

    /// "/withdraw <ask id>".
    func withdrawCommand(_ room: String, _ sender: String, _ content: String, verified: Bool) -> ChatReceipt {
        if !asksOn { return .refused(Self.askOff) }
        if !verified { return .refused(Self.unverifiedAskCommand("/withdraw")) }
        let f = Self.fields(content)
        if f.count != 2 { return .refused(ChatAskForm.withdrawHelp) }
        return withdraw(room: room, who: sender, ref: f[1], via: "command")
    }

    /// A /decide or /withdraw whose sender was not verified by its own token could be anyone's, the asker's included.
    static func unverifiedAskCommand(_ cmd: String) -> String {
        cmd + " needs a sender verified by its own token: this one was not, so it could be anyone's. Send it with your token, use the page's buttons, or POST /agent/" + cmd.dropFirst()
    }

    /// A Claude session on this Mac sees no receipt for what it sends: why its /decide or /withdraw was refused goes to its
    /// inbox, to it alone. Nothing of a refusal is written into the room.
    func tellRefused(_ sender: String, _ cmd: String, _ rc: ChatReceipt) {
        guard rc.state == "refused", let p = participant(sender), p.deliver == "inbox-socket", let s = claudeSession(p.session) else { return }
        note(s, "Your \(cmd) was refused, and nothing was written in the room: \(rc.detail)")
    }

    // MARK: - Expiry

    /// Closes an ask whose time has come: expired, with the server's decline as its decision. Takes `askLock`.
    func expire(_ room: String, _ id: String) {
        guard asksOn, let st = try? store(room) else { return }
        askLock.withLock { expireLocked(room, st, id) }
    }

    /// Under `askLock`. `note` replaces the outcome's sentence (a closed room); `declined` false starts no cooldown.
    func expireLocked(_ room: String, _ st: ChatRoomStore, _ id: String, note: String? = nil, declined: Bool = true) {
        guard let a = st.askOf(id), a.state == "open" else { return }
        let at = chatNow()
        let d: ChatAskDecision? = a.onExpiry.isEmpty ? nil : .expiry(digest: a.digest, at: at)
        guard (try? st.closeAsk(id, state: "expired", decision: d, at: at, declined: declined)) == true else { return }
        askChanged(room, st, id, tell: true, note: note)
    }

    /// The open asks of a room whose time has come, expired now (the timer may not have run yet). Under `askLock`.
    func expireDue(_ room: String, _ st: ChatRoomStore) {
        let now = chatNow()
        for (id, at) in st.openAsks() where at > 0 && at <= now { expireLocked(room, st, id) }
    }

    /// Tells the pages an ask's state changed (stream event `ask`), and, with tell, hands the outcome to its asker.
    func askChanged(_ room: String, _ st: ChatRoomStore, _ id: String, tell: Bool, note: String? = nil) {
        askTimers.cancel(room, id)
        guard let m = try? st.one(id) else { return }
        publish(ChatEvent(kind: "ask", room: room, message: m))
        if tell && m.ask != nil { tellAsker(room, m, note: note) }
    }

    /// At start (before the ports answer): every room's open asks — one that expired while the server was down is
    /// expired now (its asker told), the others' timers set, and each looked at for a decider left. Nothing while asks
    /// are off: an open ask then stays as it is until they are on again. How many open asks it found.
    @discardableResult
    public func startAsks() -> Int {
        askTimers.fire = { [weak self] room, id in self?.expire(room, id) }
        loadAskNumbers()
        guard asksOn else { return 0 }
        var n = 0
        for room in roomNames() {
            guard let st = try? store(room) else { continue }
            let open = st.openAsks()
            askLock.withLock { for (id, _) in open { checkDecidersLocked(room, st, id) } }
            for (id, at) in open {
                n += 1
                if at > 0 && at <= chatNow() { expire(room, id) } else { scheduleAsk(room, id, at: at) }
            }
        }
        return n
    }

    /// A closed room (its workspace finished, or closed by the owner) leaves no ask waiting: each open one expires at
    /// once, its asker told the room was closed; no cooldown starts. Again for the same room: nothing is open.
    func expireClosedRooms(_ rooms: [String]) {
        guard asksOn else { return }
        for room in rooms.sorted() {
            guard let st = try? store(room) else { continue }
            askLock.withLock {
                for (id, _) in st.openAsks() {
                    if (try? st.one(id))?.from == ChatProtocol.systemName { continue }   // Dozable's own stays open (ChatSystemAsks.swift)
                    let note = "Your ask \(Self.short(id)) in room \(room) expired: room \(room) was closed, so its answer is the one set for expiry: decline (Decline)."
                    expireLocked(room, st, id, note: note, declined: false)
                }
            }
        }
    }

    // MARK: - No one left to decide

    /// Every open ask of a room: one none of whose deciders may still decide it (a member that is human or has the role)
    /// is marked no_decider, the pages are told, and so is its asker. It stays open and expires to decline as usual.
    func checkDeciders(_ room: String) {
        guard asksOn, let st = try? store(room) else { return }
        askLock.withLock { for (id, _) in st.openAsks() { checkDecidersLocked(room, st, id) } }
    }

    func checkAllDeciders() { for room in roomNames() { checkDeciders(room) } }

    func checkDecidersLocked(_ room: String, _ st: ChatRoomStore, _ id: String) {
        guard let a = st.askOf(id), a.state == "open", !a.noDecider else { return }
        if a.deciders.contains(where: { member(room, $0) && mayDecide($0) }) { return }
        guard st.setNoDecider(id), let m = try? st.one(id) else { return }
        publish(ChatEvent(kind: "ask", room: room, message: m))
        tellAsker(room, m)
    }

    // MARK: - The outcome, to the asker

    /// The sentence that tells an asker how its ask ended.
    static func askOutcome(_ room: String, _ m: ChatStored) -> String {
        guard let a = m.ask else { return "" }
        let head = "Your ask \(short(m.msgID)) in room \(room)"
        let d = a.decision
        if a.state == "decided", let d {
            var who = d.by
            if let s = d.sender { who = "\(d.by) (\(s.kind), \(s.id), \(s.verified ? "verified by token" : "not verified"))" }
            if d.deciderRole { who += ", by the decider role the owner gave it" }
            var s = head + " was decided by " + who
            let answers = d.answers ?? []
            if d.declined {
                s += ": decline (Decline)"
                if !d.text.isEmpty { s += ", with the words: " + d.text }
            } else if a.questions.count == 1 && d.option != ChatAsk.answered {
                s += ": \(d.option) (\(d.label))"
                if !d.text.isEmpty { s += ", with the words: " + d.text }
            } else if a.questions.count == 1 {
                s += ": " + ChatAskForm.summary(a, answers, sep: "")
            } else {
                s += ". The answers:"
                for (i, ans) in answers.enumerated() {
                    var name = ans.questionID
                    if let q = a.question(ans.questionID), !q.header.isEmpty { name += " (" + q.header + ")" }
                    var picked = ans.options.enumerated().map { "\($1) (\(ans.labels[$0]))" }
                    if ans.skipped { picked = ["skipped"] }
                    s += " \(i + 1). \(name): "
                    if ans.text.isEmpty { s += picked.joined(separator: ", ") } else if picked.isEmpty { s += "\u{201C}" + ans.text + "\u{201D}" } else {
                        s += picked.joined(separator: ", ") + ", with the words: " + ans.text
                    }
                    s += ";"
                }
                if s.hasSuffix(";") { s.removeLast() }
            }
            return s + ". A decision is the decider's own; a bot that decides speaks for itself, not for the owner."
        }
        if a.state == "expired", let d { return "\(head) expired with no decision, so its answer is the one set for expiry: \(d.option) (\(d.label))." }
        if a.state == "expired" { return head + " expired with no decision." }
        if a.state == "open" && a.noDecider {
            return head + " has no one left who may decide it (a decider left the room or lost the decider role). It stays open and expires to decline at "
                + a.expiresAt + "; you may withdraw it and ask again."
        }
        return head + " was " + a.state + "."
    }

    /// The outcome as a notice: the fields every route carries (a Go map: written sorted).
    static func askNotice(_ room: String, _ m: ChatStored, note: String) -> [String: JValue] {
        guard let a = m.ask else { return [:] }
        var n: [String: JValue] = ["room": .string(room), "msg_id": .string(m.msgID), "ask_id": .string(m.msgID), "state": .string(a.state),
                                   "digest": .string(a.digest), "no_decider": .bool(a.noDecider), "question": .string(a.question), "note": .string(note)]
        if !a.about.isEmpty, let v = try? ChatJSON.parse(Array(a.about.utf8)) { n["about"] = v }
        if let d = a.decision {
            n["decided_by"] = .string(d.by); n["option"] = .string(d.option); n["label"] = .string(d.label); n["text"] = .string(d.text)
            n["decider_role"] = .bool(d.deciderRole); n["declined"] = .bool(d.declined); n["answers"] = .array((d.answers ?? []).map(\.json))
            if let s = d.sender {
                n["decider"] = .map(["kind": .string(s.kind), "id": .string(s.id), "name": .string(s.name), "verified": .bool(s.verified),
                                     "decider_role": .bool(d.deciderRole)])
            }
        }
        return n
    }

    static func askEvent(_ a: ChatAsk, _ outcome: String, _ none: String) -> String { a.state == "open" && a.noDecider ? none : outcome }

    /// Hands the outcome of an ask to its asker, the way it takes messages: a notice for one that polls (kept until
    /// acknowledged), a webhook call (the tries of a message), a line in a Claude session's inbox. The human's page is
    /// updated live and needs none.
    func tellAsker(_ room: String, _ m: ChatStored, note: String? = nil) {
        guard let a = m.ask, let p = participant(m.from), p.deliver != "web", !p.isHuman else { return }
        let text = note ?? Self.askOutcome(room, m)
        let n = Self.askNotice(room, m, note: text)
        let from = a.decision?.by ?? ChatProtocol.systemName
        switch p.route {
        case "poll":
            guard let st = try? store(room) else { return }
            var item = n
            item["msgV"] = .int(Int64(ChatProtocol.msgV)); item["type"] = .string("ask")
            item["event"] = .string(Self.askEvent(a, "ask-outcome", "ask-no-decider")); item["from"] = .string(from)
            item["message"] = .map(["role": .string("user"), "content": .string(text)])
            do { try st.addNotice(name: p.name, msgID: m.msgID, kind: "ask", item: ChatJSON.encodeString(.map(item)), at: chatNow()) } catch {
                log("chat: ask outcome \(m.msgID) to \(p.name): \(error)")
                return
            }
            wakePoll(p.name)
        case "webhook":
            var body = n
            body["event"] = .string(Self.askEvent(a, "chan-ask-outcome", "chan-ask-no-decider"))
            body["protocol_version"] = .string(ChatProtocol.version); body["from"] = .string(from)
            body["message_text"] = .string("[switchboard] " + text)
            let (id, to, sent) = (m.msgID, p.name, body)
            background {
                if case .failed(let why) = await self.postWebhook(p, sent) { self.log("chat: ask outcome \(id) to \(to): \(why)") }
            }
        case "inbox-socket":
            let line = "[room \(room) · ask \(Self.short(m.msgID)) · \(a.state)] \(text)"
            let (session, id, to) = (p.session, m.msgID, p.name)
            background {
                do {
                    guard let s = self.claudeSession(session) else { throw ChatStoreError(description: Self.noSession) }
                    try Self.writeInbox(s, msgID: chatNewID(), text: line)
                } catch { self.log("chat: ask outcome \(id) to \(to): \(error)") }
            }
        default: break
        }
    }

    // MARK: - Reading

    /// GET /agent/asks/{id}?room=: the whole message with its ask, for a waiter that reconnects. An ask whose time has
    /// come is expired first.
    func askLookup(name: String, room roomIn: String, ref: String) -> ChatHTTPResponse {
        if !asksOn { return .jsonError(404, Self.askOff) }
        let room = roomIn.isEmpty ? config.defaultRoom : roomIn
        let st: ChatRoomStore
        do { st = try store(room) } catch { return .jsonError(404, "\(error)") }
        if !member(room, name) { return .jsonError(403, "\(name) is not a member of room \(room)") }
        heard(name, answered: false)
        switch findAsk(st, room: room, who: name, ref: ref) {
        case .failure(let e): return .jsonError(404, e.description)
        case .success(let m):
            if let a = m.ask, a.state == "open", a.expires > 0, chatNow() >= a.expires {
                askLock.withLock { expireLocked(room, st, m.msgID) }
                return .json(200, ((try? st.one(m.msgID)) ?? m).json)
            }
            return .json(200, m.json)
        }
    }

    /// GET /api/asks?state=open (Dozable's, for the human): the open asks of every room the human is in, as
    /// `[{room, message}]`, by room and then in the order they were asked.
    func openAsksJSON() -> JValue {
        let who = human()
        guard asksOn else { return .array([]) }
        var out: [JValue] = []
        for room in roomNames() where member(room, who) {
            guard let st = try? store(room) else { continue }
            for (id, _) in st.openAsks() {
                guard let m = try? st.one(id), m.ask != nil else { continue }
                out.append(.object([JMember("room", .string(room)), JMember("message", Self.forViewer(m, who).json)]))
            }
        }
        return .array(out)
    }
}
