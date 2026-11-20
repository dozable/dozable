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
    func newAsk(_ st: ChatRoomStore, room: String, asker: String, question: String, spec: ChatAskSpec?) -> Result<ChatAsk, ChatAPIError> {
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
        let most = config.askMaxOpenValue
        if st.openAsksOf(asker) >= most {
            return no("\(asker) already has \(most) open ask(s) in room \(room), the most it may have: withdraw one or wait for its outcome")
        }
        let cd = config.askCooldown
        if cd > 0, let at = st.declinedSince(asker, about: a.about, since: chatNow() - cd) {
            let again = ChatTime(sec: Int64((at + cd).rounded(.down)), nsec: 0).format(fraction: false)
            return no("an ask from \(asker) about the same thing was declined or expired a moment ago: ask again after \(again)")
        }
        a.digest = ChatAskForm.digest(a)
        return .success(a)
    }

    /// The expiry timer for an open ask.
    func scheduleAsk(_ room: String, _ id: String, at: Double) { askTimers.schedule(room, id, at: at) }

    /// Whether a participant may be a decider at all: a human, or one the owner gave the role decider.
    func mayDecide(_ name: String) -> Bool {
        guard let p = participant(name) else { return false }
        return p.isHuman || p.hasRole("decider")
    }

    /// At start (before the ports answer): the numbers' high-water mark. How many open asks it found (none are looked at
    /// yet).
    @discardableResult
    public func startAsks() -> Int {
        loadAskNumbers()
        return 0
    }
}
