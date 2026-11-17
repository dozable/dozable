import CryptoKit
import Darwin
import Foundation

// What happens after a message is recorded: the live stream of the human's page, delivery to those this server can
// reach now (an open page; a participant that polls is woken to collect it), presence, and the commands that change
// the sender itself (/avatar, /session). Delivery by webhook is in ChatWebhooks.swift; to a Claude Code session's inbox
// is a later step: a message for one stays `queued`.

/// What the server keeps in memory about each participant, for presence: when it was last heard, handed a message,
/// woken, said it was thinking, typed; how many receives it has open.
struct ChatLiveState {
    var seen: [String: Double] = [:]
    var pending: [String: Double] = [:]
    var woken: [String: Double] = [:]
    var thinking: [String: Double] = [:]
    var typing: [String: Double] = [:]
    var polling: [String: Int] = [:]
    var avatars: [String: String] = [:]
    var links: [String: String] = [:]
}

extension ChatServerCore {
    // MARK: - The stream

    /// How many pages have the stream open.
    public var viewers: Int { bus.count }

    /// Opens a page's stream: first what waited for the human is marked delivered (the page reads it with the log), then
    /// the subscription.
    public func subscribe() -> ChatSubscriber {
        pageOpened()
        let s = bus.subscribe()
        DispatchQueue.global(qos: .utility).async { self.pageOpened() }   // what came between the look and the subscription
        return s
    }

    public func unsubscribe(_ s: ChatSubscriber) { bus.unsubscribe(s) }

    /// Ends every open stream (the server stops).
    public func closeStreams() { bus.closeAll() }

    func publish(_ e: ChatEvent) {
        guard viewers > 0, let v = streamView(e) else { return }
        bus.publish(v)
    }

    /// An event as the human's stream may show it: nothing of a room the human is not in; every message as the human
    /// sees it; no state or reaction of a direct message the human may not read.
    func streamView(_ e: ChatEvent) -> ChatEvent? {
        let viewer = human()
        if !e.room.isEmpty && !member(e.room, viewer) { return nil }
        var out = e
        if let m = e.message { out.message = Self.forViewer(m, viewer) }
        var id = e.state?.msgID ?? ""
        if let r = e.reaction, let rid = r.field("msg_id")?.stringValue { id = rid }
        if !id.isEmpty {
            guard let st = try? store(e.room), let v = st.visibility(id) else { return nil }
            var probe = ChatStored(msgID: id, from: v.from, to: v.to, at: 0)
            probe.isPrivate = v.isPrivate; probe.revealed = v.revealed
            if !Self.canSee(probe, viewer) { return nil }
        }
        return out
    }

    /// A message recorded in a room, on the stream.
    func published(_ room: String, _ m: ChatStored, kind: String = "message") {
        publish(ChatEvent(kind: kind, room: room, message: m))
    }

    /// Marks delivered what waited for the human because no page was open: a page that opens reads the log.
    func pageOpened() {
        for room in roomNames() {
            guard let st = try? store(room), let pend = try? st.pending() else { continue }
            for (id, who) in pend where participant(who)?.deliver == "web" {
                guard let m = try? st.one(id) else { continue }
                if m.deleted {
                    setState(room, st, ChatState(msgID: id, recipient: who, state: "cancelled", at: chatNow(), detail: "the message was deleted before it was handed over"))
                } else {
                    setState(room, st, ChatState(msgID: id, recipient: who, state: "delivered", at: chatNow(), detail: "shown when a page opened"))
                }
            }
        }
    }

    // MARK: - Delivery

    /// Hands one recipient a message, as far as this server can at once: an open page shows it; a participant that
    /// polls is woken to collect it. A webhook is called by `deliverInOrder`, off the caller's thread. A Claude
    /// session's inbox comes later: such a message stays queued.
    func deliver(_ room: String, _ st: ChatRoomStore, _ msgID: String, to: String) {
        guard let cur = try? st.one(msgID) else { return }
        if cur.deleted {
            setState(room, st, ChatState(msgID: msgID, recipient: to, state: "cancelled", at: chatNow(), detail: "the message was deleted before it was handed over"))
            return
        }
        guard let p = participant(to) else {
            setState(room, st, ChatState(msgID: msgID, recipient: to, state: "failed", at: chatNow(), detail: "not in the directory"))
            return
        }
        switch p.route {
        case "web":
            guard viewers > 0 else { return }   // stays queued; the page reads the log when it opens
            setState(room, st, ChatState(msgID: msgID, recipient: to, state: "delivered", at: chatNow(), detail: "shown on an open page"))
        case "poll":
            wakePoll(to)   // stays queued until it is collected
        case "inbox-socket", "webhook":
            break   // the inbox is a later step; a webhook is called by deliverInOrder
        default:
            setState(room, st, ChatState(msgID: msgID, recipient: to, state: "failed", at: chatNow(), detail: "unknown delivery \(goQuote(p.deliver))"))
        }
    }

    // MARK: - Presence

    func mark(_ name: String, _ which: WritableKeyPath<ChatLiveState, [String: Double]>) {
        lock.withLock { live[keyPath: which][name] = chatNow() }
    }

    /// A participant was just heard from: it posted, polled or sent a heartbeat. answered clears that it was woken.
    public func heard(_ name: String, answered: Bool) {
        lock.withLock {
            live.seen[name] = chatNow()
            if answered { live.pending[name] = nil; live.woken[name] = nil; live.thinking[name] = nil }
        }
    }

    /// The seconds a typing signal lasts, a bot counts as present after it was heard, a woken bot counts as thinking,
    /// and a Claude session with an unanswered message counts as thinking while busy.
    static let typingFor = 4.0, presentFor = 15.0, thinkingFor = 180.0, pendingFor = 900.0

    /// Every participant with what is known about it now.
    public func presence() -> [JValue] {
        let now = chatNow()
        let (l, views) = lock.withLock { (live, bus.count) }
        return people().map { p in
            var o = JObject()
            var state = "", activity = "", detail = ""
            switch true {
            case p.isHuman:
                (state, detail) = views > 0 ? ("here", "a page is open") : ("away", "no page is open")
                if let t = l.typing[p.name], now - t < Self.typingFor { activity = "typing" }
            case p.deliver == "inbox-socket":
                let (running, status) = sessionStatus(p.session)
                if !running {
                    (state, detail) = ("not running", "no running Claude session is called " + p.session)
                } else if status == "busy" {
                    (state, detail) = ("working", "the session reports it is busy")
                    if let t = l.pending[p.name], now - t < Self.pendingFor { activity = "thinking" }
                } else {
                    (state, detail) = ("idle", "the session reports it is idle")
                }
            case p.route == "poll":
                if (l.polling[p.name] ?? 0) > 0 {
                    (state, detail) = ("present", "its session is connected and waiting for messages")
                } else if let t = l.seen[p.name], now - t < Self.presentFor {
                    (state, detail) = ("present", "heard from in the last few seconds")
                } else {
                    (state, detail) = ("quiet", "its session is not connected; messages wait for it")
                }
            default:   // a bot reached by webhook: only what it sends, and what the server did, is known
                let seen = l.seen[p.name], w = l.woken[p.name], th = l.thinking[p.name]
                if let th, now - th < Self.thinkingFor {
                    (state, activity, detail) = ("present", "thinking", "it said it is working on a message")
                } else if let w, now - w < Self.thinkingFor {
                    (state, activity, detail) = ("woken", "thinking", "woken by webhook, no answer yet")
                } else if let seen, now - seen < Self.presentFor {
                    (state, detail) = ("present", "heard from in the last few seconds")
                } else if w != nil {
                    (state, detail) = ("quiet", "woken by webhook and did not answer")
                } else if seen != nil {
                    (state, detail) = ("quiet", "nothing heard lately; a bot is usually paused when idle")
                } else {
                    (state, detail) = ("quiet", "not heard from since the switchboard server started")
                }
            }
            o.add("name", .string(p.name)); o.add("kind", .string(p.kind)); o.add("identity", .string(p.fixedIdentity))
            o.add("avatar", .string(l.avatars[p.name].flatMap { $0.isEmpty ? nil : $0 } ?? Self.defaultAvatar(p)))
            o.omitEmpty("session_url", l.links[p.name] ?? "")
            o.add("state", .string(state)); o.omitEmpty("activity", activity); o.add("detail", .string(detail))
            if let t = l.seen[p.name] { o.omitEmpty("last_seen", t) }
            return o.value
        }
    }

    /// Publishes presence to open pages whenever it changes (the last-seen times alone are no change). Every second.
    public func watchPresence() -> DispatchSourceTimer {
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "chat.presence"))
        nonisolated(unsafe) var last: [UInt8] = []
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in
            guard let self, self.viewers > 0 else { return }
            let p = self.presence()
            let key = ChatJSON.encode(.array(p.map { $0.removing("last_seen") }))
            if key != last {
                last = key
                self.publish(ChatEvent(kind: "presence", presence: p))
            }
        }
        t.resume()
        return t
    }

    func publishPresence() { publish(ChatEvent(kind: "presence", presence: presence())) }

    // MARK: - Claude Code sessions on this Mac (read only)

    /// What a running Claude Code session with this name says about itself: whether it runs and its status. Read from
    /// the session records in `sessionsDir`; never written.
    func sessionStatus(_ name: String) -> (running: Bool, status: String) {
        guard let r = sessionRecord(name) else { return (false, "") }
        return (true, r.status)
    }

    func sessionRecord(_ name: String) -> (pid: Int32, status: String)? {
        guard !name.isEmpty, let files = try? FileManager.default.contentsOfDirectory(atPath: sessionsDir) else { return nil }
        for f in files.sorted() where f.hasSuffix(".json") {
            guard let pid = Int32(f.dropLast(5)), let d = FileManager.default.contents(atPath: (sessionsDir as NSString).appendingPathComponent(f)),
                  let v = try? ChatJSON.parse(d), v.isObject, v.field("name")?.stringValue == name else { continue }
            if kill(pid, 0) == 0 { return (pid, v.field("status")?.stringValue ?? "") }
        }
        return nil
    }

    // MARK: - /avatar and /session

    static let avatarHelp = "for a Gravatar picture send /avatar gravatar:you@example.com (only a hash of the address is kept). Otherwise an avatar is vendor:shape:variation, for example anthropic:claude:default, grokbot:sphere:default, grokbot:diamond:blue or emoji:thumbs-up:default. " +
        "Shapes: claude, claude-code, sphere, circle, hexagon, square, diamond, triangle, pill, flower, cloud, blob, star, heart, drop, clover, gem, initial. Variations: default, blue, green, purple, orange, red, pink, teal, grey, yellow, white, brown. " +
        "With the vendor emoji the shape is the emoji's name: thumbs-up, rocket, robot, fire, star, heart, wave, eyes, sparkles, bulb, check, cat, dog, owl, fox, ghost, alien, brain, gear, bolt."

    static let avatarShapes: Set<String> = ["claude", "sphere", "diamond", "square", "circle", "hexagon", "initial", "flower", "pill", "triangle", "cloud",
                                            "blob", "star", "heart", "drop", "clover", "gem", "claude-code"]
    static let avatarColours: Set<String> = ["default", "blue", "green", "purple", "orange", "red", "pink", "teal", "grey", "yellow", "white", "brown"]
    static let avatarEmoji: Set<String> = ["thumbs-up", "rocket", "robot", "fire", "star", "heart", "wave", "eyes", "sparkles", "bulb", "check", "cat", "dog",
                                           "owl", "fox", "ghost", "alien", "brain", "gear", "bolt"]

    /// `vendor:shape:variation` with a known shape and variation (an emoji's variation is default), or a Gravatar hash.
    static func validAvatar(_ spec: String) -> Bool {
        let parts = spec.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3 else { return false }
        if parts[0] == "gravatar" {
            return parts[1].utf8.count == 64 && parts[1].utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) } && parts[2] == "default"
        }
        for p in parts {
            guard (1...24).contains(p.utf8.count), p.utf8.allSatisfy({ (0x61...0x7A).contains($0) || (0x30...0x39).contains($0) || $0 == 0x2D }) else { return false }
        }
        if parts[0] == "emoji" { return avatarEmoji.contains(parts[1]) && parts[2] == "default" }
        return avatarShapes.contains(parts[1]) && avatarColours.contains(parts[2])
    }

    /// What a participant shows until it picks one, from its vendor.
    static func defaultAvatar(_ p: ChatParticipant) -> String {
        if validAvatar(p.avatar) { return p.avatar }
        let vendor = String(p.fixedIdentity.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        switch vendor {
        case "anthropic": return "anthropic:claude:default"
        case "grokbot", "xai": return "grokbot:sphere:default"
        case "human": return "human:initial:default"
        default: return vendor + ":hexagon:default"
        }
    }

    /// `^gravatar:[^\s:@]+@[^\s:@]+\.[^\s:@]+$`: an address with one @ and, after it, a dot with something on each side.
    static func isGravatarAddress(_ spec: String) -> Bool {
        guard spec.hasPrefix("gravatar:") else { return false }
        let a = spec.dropFirst(9)
        guard !a.unicodeScalars.contains(where: { $0 == ":" || $0.properties.isWhitespace }) else { return false }
        let at = a.split(separator: "@", omittingEmptySubsequences: false)
        guard at.count == 2, !at[0].isEmpty else { return false }
        let d = Array(at[1].utf8)
        return d.indices.contains { d[$0] == 0x2E && $0 > 0 && $0 < d.count - 1 }
    }

    /// An https address with a host, an optional port and a path of the characters a link may have.
    static func validSessionLink(_ s: String) -> Bool {
        guard s.hasPrefix("https://"), s.utf8.count <= 500 else { return false }
        let rest = Array(s.utf8.dropFirst(8))
        var i = 0
        func host(_ c: UInt8) -> Bool { (0x41...0x5A).contains(c) || (0x61...0x7A).contains(c) || (0x30...0x39).contains(c) || c == 0x2E || c == 0x2D }
        while i < rest.count, host(rest[i]) { i += 1 }
        guard i > 0 else { return false }
        if i < rest.count, rest[i] == 0x3A {
            var j = i + 1
            while j < rest.count, (0x30...0x39).contains(rest[j]) { j += 1 }
            guard j > i + 1 else { return false }
            i = j
        }
        if i == rest.count { return true }
        guard rest[i] == 0x2F else { return false }
        let path = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._~:/?#@!$&'()*+,;=%-".utf8)
        return rest[i...].allSatisfy { path.contains($0) }
    }

    /// /avatar and /session: the commands that change the sender itself. The text to record in the room, or the refusal.
    func meta(_ sender: String, _ text: String) -> Result<String, ChatAPIError> {
        let f = Self.fields(text)
        func fail(_ s: String) -> Result<String, ChatAPIError> { .failure(ChatAPIError(status: 422, description: s)) }
        if f[0] == "/avatar" {
            guard f.count == 2 else { return fail(Self.avatarHelp) }
            var spec = f[1].lowercased(), shown = ""
            if Self.isGravatarAddress(spec) {
                // Only a hash of the address is kept; the address is not stored or recorded.
                let addr = Self.trimSpace(String(spec.dropFirst(9)))
                spec = "gravatar:" + SHA256.hash(data: Data(addr.utf8)).map { String(format: "%02x", $0) }.joined() + ":default"
            }
            guard Self.validAvatar(spec) else { return fail(Self.avatarHelp) }
            let all = lock.withLock { () -> [String: String] in live.avatars[sender] = spec; return live.avatars }
            save("avatars.json", .map(all.mapValues { JValue.string($0) }))
            shown = spec.hasPrefix("gravatar:") ? "a Gravatar picture" : spec
            return .success("\(capitalFirst(sender)) changed \(isHuman(sender) ? "their" : "its") avatar to \(shown)")
        }
        let help = "send /session https://... with the address of your own conversation with the human, or /session off to remove it"
        guard f.count == 2, f[1] == "off" || Self.validSessionLink(f[1]) else { return fail(help) }
        let all = lock.withLock { () -> [String: String] in
            live.links[sender] = f[1] == "off" ? nil : f[1]
            return live.links
        }
        save("sessions.json", .map(all.mapValues { JValue.string($0) }))
        return .success(f[1] == "off" ? capitalFirst(sender) + " removed the link to its own session"
            : capitalFirst(sender) + " set the link to its own session with the human")
    }

    /// Reads the avatars and session links participants picked earlier.
    func loadAvatars() {
        func strings(_ name: String) -> [String: String]? {
            guard let v = readJSON(name), case .object(let m) = v else { return nil }
            var out: [String: String] = [:]
            for e in m { if let s = e.value.stringValue { out[e.key] = s } }
            return out
        }
        let a = strings("avatars.json"), l = strings("sessions.json")
        lock.withLock {
            if let a { live.avatars = a }
            if let l { live.links = l }
        }
    }
}

extension JValue {
    /// An object without one member.
    func removing(_ key: String) -> JValue {
        guard case .object(let ms) = self else { return self }
        return .object(ms.filter { $0.key != key })
    }
}
