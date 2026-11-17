import CryptoKit
import Foundation

// The chat server's core: the directory, the rooms and their members, posting, the room commands, registered sessions,
// and the files of the data folder. Transport-free: the page port and the line port call it, and it calls nothing of
// theirs. Its state is guarded by one lock; each room's SQLite file has its own serial queue (ChatRoomStore).
//
// Here: posting on every path, the room and membership commands, archive and the hold, registration, and the
// announcement of a new protocol version. Delivery is in ChatLive.swift (a page, a participant that polls) and
// ChatWebhooks.swift (a bot's webhook) and ChatInbox.swift (a Claude Code session on this Mac); reactions in
// ChatReact.swift; edits and deletes in ChatEdits.swift; attachments in ChatAttachments.swift.

public struct ChatLog: Sendable {
    let write: @Sendable (String) -> Void
    public init(_ write: @escaping @Sendable (String) -> Void) { self.write = write }
    public func callAsFunction(_ s: String) { write(s) }
    public static let none = ChatLog { _ in }
}

/// One line of the protocol, or the body of a post, as Go reads it into its Message struct.
public struct ChatLine: Sendable {
    public var msgV = 0
    public var msgID = ""
    public var type = ""
    public var hasBody = false
    public var content = ""
    public var from = ""
    public var room = ""
    public var to: [String] = []
    public var reMsgID = ""
    public var attachments: [JValue] = []
    public var isPrivate = false
    public var id = ""
    public var reaction = ""
    public var action = ""
    public var token = ""
    /// Set by the server, never by a sender: the sender presented its token.
    public var verified = false

    public init() {}

    /// Reads a line. A value of the wrong type for a field is an error, as in Go (the line port then closes).
    public static func read(_ v: JValue) throws -> ChatLine {
        var m = ChatLine()
        if v.isNull { return m }
        guard v.isObject else { throw ChatFieldError(description: "not an object") }
        func s(_ k: String) throws -> String { try v.field(k)?.goString(k) ?? "" }
        m.msgV = try v.field("msgV")?.goInt("msgV") ?? 0
        m.msgID = try s("msg_id"); m.type = try s("type"); m.from = try s("from"); m.room = try s("room")
        m.reMsgID = try s("re_msg_id"); m.id = try s("id"); m.reaction = try s("reaction"); m.action = try s("action")
        m.token = try s("token")
        _ = try s("priority")
        m.to = try v.field("to")?.goStrings("to") ?? []
        m.isPrivate = try v.field("private")?.goBool("private") ?? false
        switch v.field("message") ?? .null {
        case .null: break
        case .object:
            let b = v.field("message")!
            m.hasBody = true
            _ = try b.field("role")?.goString("message.role")
            m.content = try b.field("content")?.goString("message.content") ?? ""
        default: throw ChatFieldError(description: "message: not an object")
        }
        switch v.field("attachments") ?? .null {
        case .null: break
        case .array(let a):
            for e in a where !(e.isObject || e.isNull) { throw ChatFieldError(description: "attachments: not an object") }
            m.attachments = a.filter(\.isObject)
        default: throw ChatFieldError(description: "attachments: not an array")
        }
        return m
    }
}

/// What a post or a command answers: a receipt state and its detail.
public struct ChatReceipt: Sendable, Equatable {
    public var state: String
    public var detail: String
    public init(_ state: String, _ detail: String = "") { self.state = state; self.detail = detail }
    static func refused(_ d: String) -> ChatReceipt { ChatReceipt("refused", d) }
}

/// A refusal of an /agent/ call with its HTTP status.
public struct ChatAPIError: Error, Sendable, CustomStringConvertible {
    public var status: Int
    public var description: String
}

public final class ChatServerCore: @unchecked Sendable {
    public let config: ChatConfig
    public let access: ChatAccess
    let secrets: ChatSecrets
    let release: String
    let log: ChatLog

    let lock = NSLock()
    var participants: [ChatParticipant]
    var rooms: [String: [String]]
    var archived: [String: Bool] = [:]
    var holds: [String: Int] = [:]
    var agentRun: [String: Int] = [:]
    var agentTokens: [String: String] = [:]
    var stores: [String: ChatRoomStore] = [:]
    var startedFor: [String: String] = [:]
    var apps: [String: AppSettings] = [:]
    var live = ChatLiveState()
    var pollWake: [String: ChatWake] = [:]
    /// One hand-over to a polling participant at a time.
    let collectLock = NSLock()
    let bus = ChatEventBus()
    /// When this server started: what was handed over earlier and not confirmed is handed over again.
    let startTime = chatNow()
    /// Where Claude Code keeps its session records (`<pid>.json`, `<pid>.<hash>.key`): read only — for presence, and to
    /// find a running session's inbox socket. A value handed in; by default `$HOME/.claude/sessions`, as the reference.
    let sessionsDir: String

    /// What sends a webhook call (a test may hand in its own), the pause before each try (the reference's schedule:
    /// at once, 5 s later, 20 s after that) and each try's deadline. Set before the server starts.
    public var webhookPoster: any ChatWebhookPoster = ChatURLSessionWebhook()
    public var webhookBackoff: [Double] = [0, 5, 20]
    public var webhookTimeout: Double = 30
    /// How old a message that waited may be and still be handed over at start.
    public var redeliverAfter: Double = 24 * 3600
    /// How long a stop waits for the webhook calls in flight before it closes the rooms' files.
    public var stopDeliveryMax: Double = 2.5
    /// Deliveries running in the background (webhook calls), and whether the server is stopping.
    var deliveries = 0
    var stopping = false
    /// The announcement's webhook calls still out.
    let announcing = DispatchGroup()

    /// The page this server serves at `/`: a shell (the human's page is Dozable's dashboard).
    public static let pageShell = """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Chat</title></head>
        <body><p>This is a chat server. Its rooms are read and written through its API.</p></body></html>

        """

    /// The page version: the first 12 hex characters of the page's SHA-256.
    public static let pageVersion: String = String(SHA256.hash(data: Data(pageShell.utf8)).map { String(format: "%02x", $0) }.joined().prefix(12))

    /// The hold's limit when the human turns it on without a number.
    public static let defaultHold = 8

    public init(config: ChatConfig, secrets: ChatSecrets, release: String, log: ChatLog = .none, sessionsDir: String? = nil) {
        self.config = config
        self.sessionsDir = sessionsDir ?? ((ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()) as NSString)
            .appendingPathComponent(".claude/sessions")
        access = config.access
        self.secrets = secrets
        self.release = release
        self.log = log
        webhookPoster = ChatURLSessionWebhook(release: release)
        participants = config.participants
        rooms = config.rooms
    }

    var dataDir: String { config.dataDir }
    func file(_ name: String) -> String { (dataDir as NSString).appendingPathComponent(name) }

    // MARK: - Start

    /// Reads what the data folder keeps: holds, registered sessions, archived rooms, room apps, memberships.
    public func load() {
        if let v = readJSON("holds.json"), case .object(let m) = v {
            lock.withLock { for e in m { if let n = try? e.value.goInt("hold") { holds[e.key] = n } } }
        }
        loadAgents()
        if let v = readJSON("archived.json"), case .object(let m) = v {
            lock.withLock { archived = [:]; for e in m { if case .bool(let b) = e.value { archived[e.key] = b } } }
        }
        loadApps()
        loadAvatars()
        if let v = readJSON("rooms.json"), case .object(let m) = v {
            lock.withLock {
                for e in m where chatIsRoomName(e.key) {
                    let names = (try? e.value.goStrings("rooms")) ?? []
                    rooms[e.key] = names.filter { n in participants.contains { $0.name == n } }
                }
            }
        }
    }

    private func loadAgents() {
        guard let v = readJSON("agents.json"), v.isObject else { return }
        let ps: [ChatParticipant]
        if case .array(let a)? = v.field("participants") { ps = a.compactMap { try? ChatParticipant.read($0, strict: false) } } else { ps = [] }
        lock.withLock {
            for var p in ps where !participants.contains(where: { $0.name == p.name }) && chatIsSessionName(p.name)
                && !ChatProtocol.reservedNames.contains(p.name) {
                p.deliver = "poll"
                participants.append(p)
            }
            agentTokens = [:]
            if case .object(let t)? = v.field("tokens") { for e in t { if let h = e.value.stringValue { agentTokens[e.key] = h } } }
        }
    }

    /// At start: a change line in each room that is not archived, and a notice for each registered session, when the
    /// protocol's version differs from the one this data folder last announced. Says whether it announced.
    @discardableResult
    public func announceProtocol() -> Bool {
        let path = file("protocol-version")
        if let s = try? String(contentsOfFile: path, encoding: .utf8),
           s.trimmingCharacters(in: .whitespacesAndNewlines) == ChatProtocol.version { return false }
        do { try writeFile("protocol-version", Array((ChatProtocol.version + "\n").utf8)) } catch { log("chat: protocol-version: \(error)") }
        let text = ChatProtocol.announcement
        for room in roomNames() where !isArchived(room) {
            guard let st = try? store(room) else { continue }
            var ch = ChatStored.change(chatNewID(), from: ChatProtocol.systemName, content: text, at: chatNow())
            if (try? st.insert(&ch)) == false { published(room, ch) }
        }
        for p in people() {
            switch p.route {
            case "poll": protocolNotice(p.name, text)
            case "webhook": protocolWebhook(p)
            case "inbox-socket":
                if let s = claudeSession(p.session) {
                    note(s, "The message protocol was updated. No action is needed unless you want to use what is new.\n\n" + ChatProtocol.markdown)
                }
            default: break
            }
        }
        return true
    }

    /// The announcement kept for a registered session, in the first room it is in that is not archived (else the first
    /// room it is in), once per version.
    private func protocolNotice(_ name: String, _ text: String) {
        var room = ""
        for r in roomNames() where member(r, name) {
            if room.isEmpty || (isArchived(room) && !isArchived(r)) { room = r }
        }
        guard !room.isEmpty, let st = try? store(room) else { return }
        let id = "protocol-" + ChatProtocol.version
        let item = JValue.map(["msgV": .int(Int64(ChatProtocol.msgV)), "type": .string("protocol"), "event": .string("protocol-updated"),
                               "msg_id": .string(id), "room": .string(room), "from": .string(ChatProtocol.systemName),
                               "protocol_version": .string(ChatProtocol.version),
                               "message": .map(["role": .string("user"), "content": .string(text)]),
                               "note": .string("The message protocol was updated. No answer is needed. Use what is new if you want to.")])
        do { try st.addNotice(name: name, msgID: id, kind: "protocol", item: ChatJSON.encodeString(item), at: chatNow()) } catch {
            log("chat: protocol notice to \(name): \(error)")
            return
        }
        wakePoll(name)
    }

    /// Stops: the open streams end, the webhook calls in flight get up to `stopDeliveryMax` to finish (one that does
    /// not is abandoned; its message still waits in the room's file and is handed over at the next start), then the
    /// rooms' files close.
    public func close() {
        closeStreams()
        lock.withLock { stopping = true }
        let until = chatNow() + stopDeliveryMax
        while lock.withLock({ deliveries }) > 0 && chatNow() < until { usleep(20_000) }
        let all = lock.withLock { Array(stores.values) }
        for s in all { s.close() }
    }

    // MARK: - The directory and the rooms

    public func people() -> [ChatParticipant] { lock.withLock { participants } }
    func participant(_ name: String) -> ChatParticipant? { lock.withLock { participants.first { $0.name == name } } }
    func isHuman(_ name: String) -> Bool { participant(name)?.isHuman ?? false }

    /// The first human in the directory: the page's author.
    public func human() -> String { people().first(where: \.isHuman)?.name ?? "" }

    public func members(_ room: String) -> [String] { lock.withLock { rooms[room] ?? [] } }
    public func hasRoom(_ room: String) -> Bool { lock.withLock { rooms[room] != nil } }
    public func member(_ room: String, _ name: String) -> Bool { members(room).contains(name) }
    public func roomNames() -> [String] { lock.withLock { rooms.keys.sorted() } }
    public func allRooms() -> [String: [String]] { lock.withLock { rooms } }
    public func isArchived(_ room: String) -> Bool { lock.withLock { archived[room] ?? false } }
    public func archivedRooms() -> [String] { lock.withLock { archived.filter(\.value).map(\.key).sorted() } }
    public func counts() -> (rooms: Int, participants: Int) { lock.withLock { (rooms.count, participants.count) } }

    /// A room's store, opened at its first use. "no room" for a room that does not exist.
    public func store(_ room: String) throws -> ChatRoomStore {
        lock.lock()
        defer { lock.unlock() }
        if let s = stores[room] { return s }
        guard rooms[room] != nil, chatIsRoomName(room) else { throw ChatStoreError(description: "no room \(goQuote(room))") }
        let dir = file("rooms")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let s = try ChatRoomStore(path: (dir as NSString).appendingPathComponent(room + ".db"))
        stores[room] = s
        return s
    }

    // MARK: - Tokens

    /// The participant a token belongs to (its secrets-file token), or nil.
    public func whoHas(_ token: String) -> String? {
        guard !token.isEmpty else { return nil }
        return secrets.whoHas(token, among: people().map(\.name))
    }

    /// Whose token this is on the /agent/ calls: a registered session's, or a participant's own. nil for an unknown one.
    public func whoHolds(_ token: String) -> String? {
        guard token.utf8.count >= ChatSecrets.minimumTokenLength else { return nil }
        let want = ChatSecrets.hash(token)
        let sessions = lock.withLock { agentTokens }
        for (name, have) in sessions where ChatSecrets.constantTimeEqual(have, want) { return name }
        return secrets.whoHas(token, among: people().filter { $0.deliver != "poll" }.map(\.name))
    }

    /// Whether name may call /agent/receive and /agent/ack: nil when it may (a registered session, or a participant that
    /// is not the human and has no deliver value); otherwise the refusal. One delivered to by webhook is refused with
    /// 409, so that no message is delivered twice; every other caller with 403.
    public func mayPoll(_ name: String) -> ChatAPIError? {
        let p = participant(name)
        if p?.route == "poll" { return nil }
        if p?.deliver == "webhook" {
            return ChatAPIError(status: 409, description: "\(name) is delivered to by webhook and cannot also poll, so that no message is delivered twice")
        }
        return ChatAPIError(status: 403, description: "\(name) is not a registered session; it is delivered to another way")
    }

    // MARK: - Reading

    /// What the page needs to start (`GET /api/state`).
    public func stateJSON() -> JValue {
        .map([
            "rooms": .map(allRooms().mapValues { JValue.strings($0) }),
            "archived": .strings(archivedRooms()),
            "participants": .array(people().map(\.json)),
            "default_room": .string(config.defaultRoom),
            "token_service": .string(config.tokenService),
            "need_token": .bool(config.requireTokens),
            "reactions": .array(ChatReactions.standard.map { .object([JMember("name", .string($0.name)), JMember("emoji", .string($0.emoji))]) }),
            "version": .string(Self.pageVersion),
            "release": .string(release),
            "https_url": .string(""),
            "apps": .map(Dictionary(uniqueKeysWithValues: roomNames().map { ($0, appView($0)) })),
        ])
    }

    public func protocolJSON() -> JValue { ChatProtocol.description(rooms: allRooms(), defaultRoom: config.defaultRoom) }

    /// Whether viewer may read a message: not a direct message, revealed, or the viewer sent it or is one it is for.
    static func canSee(_ m: ChatStored, _ viewer: String) -> Bool {
        !m.isPrivate || m.revealed || m.from == viewer || m.to.contains(viewer)
    }

    /// A message as viewer may see it: a direct message between others is a stub.
    static func forViewer(_ m: ChatStored, _ viewer: String) -> ChatStored {
        if canSee(m, viewer) { return m }
        var s = m
        s.kind = "private"; s.content = ""; s.attachments = []; s.mentions = []; s.reactions = []; s.states = []
        return s
    }

    /// One page of a room's log, oldest first, as viewer sees it ("" sees everything).
    public func messagePage(room: String, after: Int64, before: Int64, limit: Int, viewer: String) throws -> (messages: [ChatStored], more: Bool) {
        let st = try store(room)
        var (ms, more) = try st.page(after: after, before: before, limit: min(max(limit, 1), 500))
        if !viewer.isEmpty { ms = ms.map { Self.forViewer($0, viewer) } }
        return (ms, more)
    }

    // MARK: - Posting

    /// Puts a message from sender into its room. The receipt state and detail.
    public func post(_ line: ChatLine, sender: String) -> ChatReceipt {
        var m = line
        if (m.content.isEmpty && m.attachments.isEmpty) || !chatIsUUID(m.msgID) {
            return .refused("needs a uuid msg_id, and message.content text or an attachment")
        }
        let room = m.room.isEmpty ? config.defaultRoom : m.room
        let st: ChatRoomStore
        do { st = try store(room) } catch { return .refused("\(error)") }
        // Sent before: nothing is done twice. A repeat by its sender is answered duplicate even after it left the room.
        let known = st.knownID(m.msgID)
        if known.known && (known.by == sender || member(room, sender)) { return Self.duplicateOf(known.state, known.detail) }
        if !member(room, sender) { return .refused("\(sender) is not a member of room \(room)") }
        let words = Self.fields(m.content)
        if let w = words.first, ChatProtocol.isCommandWord(w), w != "/dm" {
            let rc = command(m, room: room, store: st, sender: sender, words: words)
            heard(sender, answered: false)   // every command is a sign of life, whatever its answer
            publishPresence()
            return rc
        }
        if isArchived(room) { return .refused(Self.archivedRefusal(room)) }
        if !m.reMsgID.isEmpty && m.reMsgID.utf8.count < 36 { m.reMsgID = st.fullID(m.reMsgID) }
        // "/dm @name text" is a direct message to those named.
        if words.first == "/dm" {
            var rest = Self.trimSpace(String(Self.trimSpace(m.content).dropFirst(3)))
            while true {
                let w = Self.fields(rest)
                guard let first = w.first, first.hasPrefix("@") || Self.isIDPrefix(first) else { break }
                if first.hasPrefix("^") {
                    m.reMsgID = st.fullID(String(first.dropFirst()))
                } else {
                    let n = Self.nameWord(first)
                    guard Self.isName(n) else { return .refused("\(goQuote(first)) is not a name. Use /dm @name the text") }
                    m.to.append(n)
                }
                rest = Self.trimSpace(rest.hasPrefix(first) ? String(rest.dropFirst(first.count)) : rest)
            }
            m.content = rest
            m.isPrivate = true
            if rest.isEmpty && m.attachments.isEmpty { return .refused("a direct message needs text: /dm @name the text") }
        }
        // to is who the message is addressed to: a hint in a room, the only recipients of a direct message.
        var to: [String] = []
        for n in m.to {
            if !member(room, n) { return .refused("\(n) is not a member of room \(room)") }
            if n != sender && !to.contains(n) { to.append(n) }
        }
        if m.isPrivate && to.isEmpty { return .refused("a direct message must name who it is for") }
        let files: [JValue]
        switch attach(m.attachments) {
        case .success(let f): files = f
        case .failure(let e): return .refused(e.description)
        }
        // Anyone named with @ is mentioned, and so addressed; a mention in a direct message addresses nobody new.
        var mentions: [String] = []
        if !m.isPrivate {
            mentions = mentionsIn(room: room, sender: sender, text: m.content)
            for n in mentions where !to.contains(n) { to.append(n) }
        }
        let recipients = m.isPrivate ? to : members(room).filter { $0 != sender }
        var sm = ChatStored(msgID: m.msgID, from: sender, to: to, reMsgID: m.reMsgID, content: m.content, at: chatNow(),
                            mentions: mentions, sender: senderOf(sender, verified: m.verified), isPrivate: m.isPrivate)
        sm.attachments = files
        do {
            if try st.insert(&sm) { return ChatReceipt("duplicate") }
        } catch { return .refused("store: \(error)") }
        heard(sender, answered: true)
        published(room, sm)
        if !m.reMsgID.isEmpty && st.received(m.reMsgID, by: sender) {   // only someone who was handed it can answer it
            setState(room, st, ChatState(msgID: m.reMsgID, recipient: sender, state: "answered", at: sm.at, detail: "by " + sm.msgID))
        }
        let human = isHuman(sender)
        let (limit, held): (Int, Bool) = lock.withLock {
            let limit = holds[room] ?? config.agentRunCap
            agentRun[room] = human ? 0 : (agentRun[room] ?? 0) + 1
            return (limit, limit > 0 && (agentRun[room] ?? 0) > limit)
        }
        // The human posted: what the hold kept back goes out first, in order.
        var released = human ? releaseHeld(room, st, why: "released: a human posted") : [:]
        for r in recipients {
            if held && !isHuman(r) {
                setState(room, st, ChatState(msgID: sm.msgID, recipient: r, state: "held", at: sm.at,
                                             detail: "more than \(limit) agent messages in a row; waiting for the human to post"))
                continue
            }
            setState(room, st, ChatState(msgID: sm.msgID, recipient: r, state: "queued", at: sm.at))
            deliverInOrder(room, st, (released.removeValue(forKey: r) ?? []) + [sm.msgID], to: r)
        }
        for (r, ids) in released { deliverInOrder(room, st, ids, to: r) }
        return ChatReceipt("queued")
    }

    /// The answer to a msg_id sent again.
    static func duplicateOf(_ state: String, _ detail: String) -> ChatReceipt {
        if state.isEmpty { return ChatReceipt("duplicate") }
        if state == "pending" { return ChatReceipt("duplicate", "already being done") }
        if !detail.isEmpty { return ChatReceipt("duplicate", "already done: \(state): \(detail)") }
        return ChatReceipt("duplicate", "already done: \(state)")
    }

    static func archivedRefusal(_ room: String) -> String {
        "room \(room) is archived: it can be read but not posted to. A human can reopen it with /unarchive"
    }


    private func command(_ m: ChatLine, room: String, store st: ChatRoomStore, sender: String, words f: [String]) -> ChatReceipt {
        switch f[0] {
        case "/edit", "/delete":   // not stored as a message; the gate for an archived room is their own
            let content = m.content
            return once(st, m.msgID, sender) { changeCommand(room, sender, content) }
        case "/react":   // refused in an archived room by react, in the words used for reactions on every path
            if f.count < 2 { return .refused("use /react like. " + ChatReactions.help) }
            let (content, target) = (m.content, m.reMsgID)
            return once(st, m.msgID, sender) { reactCommand(room, sender, target: target, content) }
        default: break
        }
        if isArchived(room) && !["/unarchive", "/leave", "/room", "/rooms"].contains(f[0]) { return .refused(Self.archivedRefusal(room)) }
        switch f[0] {
        case "/protocol":
            guard let p = participant(sender), p.deliver == "inbox-socket" else { return ChatReceipt("info", ChatProtocol.markdown) }
            // A Claude session on this Mac sees no receipt for what it sends, so the text goes to its inbox.
            guard let s = claudeSession(p.session) else { return .refused(Self.noSession) }
            note(s, ChatProtocol.markdown)
            return ChatReceipt("queued")
        case "/rooms":
            if f.count != 1 { return .refused("use /rooms on its own: it lists the rooms you are in") }
            return ChatReceipt("info", roomsOf(sender))
        case "/room" where isArchived(room):
            switch createRoom(sender, Array(f.dropFirst())) {
            case .success(let t): return ChatReceipt("info", t)
            case .failure(let e): return .refused(e.description)
            }
        default: break
        }
        let result: Result<String, ChatAPIError>
        if f[0] == "/hold" { result = setHold(room, sender, Array(f.dropFirst())) } else if Self.isMemberCommand(f[0]) {
            result = setMembers(room, sender, f)
        } else { result = meta(sender, m.content) }   // /avatar, /session
        let text: String
        switch result {
        case .success(let t): text = t
        case .failure(let e): return .refused(e.description)
        }
        var ch = ChatStored.change(m.msgID, from: sender, content: text, at: chatNow())
        do { if try st.insert(&ch) { return ChatReceipt("duplicate") } } catch { return .refused("store: \(error)") }
        published(room, ch)
        if f[0] == "/hold" {   // the count starts again, so what the hold kept back goes out
            for (r, ids) in releaseHeld(room, st, why: "released: a human changed the hold") { deliverInOrder(room, st, ids, to: r) }
        }
        return ChatReceipt("queued")
    }

    /// Lets go of what the hold kept back in a room: each held message moves on to queued and is returned per
    /// recipient, oldest first, to be handed over; one for a recipient no longer in the room is cancelled.
    func releaseHeld(_ room: String, _ st: ChatRoomStore, why: String) -> [String: [String]] {
        guard let held = try? st.held() else { return [:] }
        let at = chatNow()
        var out: [String: [String]] = [:]
        for (id, who) in held {
            if !member(room, who) {
                setState(room, st, ChatState(msgID: id, recipient: who, state: "cancelled", at: at, detail: "it left the room before the hold was lifted"))
                continue
            }
            setState(room, st, ChatState(msgID: id, recipient: who, state: "queued", at: at, detail: why))
            out[who, default: []].append(id)
        }
        return out
    }

    /// Records a delivery state and puts it on the stream.
    func setState(_ room: String, _ st: ChatRoomStore, _ s: ChatState) {
        do { try st.setState(s) } catch { log("chat: state \(s.msgID) \(s.recipient) \(s.state): \(error)"); return }
        publish(ChatEvent(kind: "state", room: room, state: s))
    }

    /// A recipient began work on a message (the line's `thinking` with re_msg_id): recorded once per message.
    public func started(_ name: String, room: String, msgID: String, detail: String) {
        guard let st = try? store(room), st.received(msgID, by: name) else { return }
        let done: Bool = lock.withLock {
            defer { startedFor[name] = msgID }
            return startedFor[name] == msgID
        }
        if !done { setState(room, st, ChatState(msgID: msgID, recipient: name, state: "started", at: chatNow(), detail: detail)) }
    }

    func senderOf(_ name: String, verified: Bool) -> ChatSender {
        guard let p = participant(name) else { return ChatSender(kind: "bot", id: "unknown:agent:" + name, name: name, verified: verified) }
        return ChatSender(kind: p.isHuman ? "human" : "bot", id: p.fixedIdentity, name: name, verified: verified)
    }

    // MARK: - Membership, rooms, archive, hold

    static func isMemberCommand(_ w: String) -> Bool { ["/invite", "/remove", "/leave", "/room", "/archive", "/unarchive"].contains(w) }

    private func setMembers(_ room: String, _ sender: String, _ f: [String]) -> Result<String, ChatAPIError> {
        let names = f.dropFirst().map(Self.nameWord).filter { !$0.isEmpty }
        if f[0] == "/room" { return createRoom(sender, Array(f.dropFirst())) }
        if f[0] == "/archive" || f[0] == "/unarchive" { return setArchived(room, sender, f[0] == "/archive") }
        func fail(_ s: String) -> Result<String, ChatAPIError> { .failure(ChatAPIError(status: 422, description: s)) }
        let senderHuman = isHuman(sender)
        let known = people().map(\.name)
        let humans = Set(people().filter(\.isHuman).map(\.name))
        let text: String
        lock.lock()
        var list = rooms[room] ?? []
        switch f[0] {
        case "/leave":
            if !names.isEmpty { lock.unlock(); return fail("/leave takes no name: it is how you leave this room yourself") }
            if senderHuman { lock.unlock(); return fail("a human does not leave a room: the page shows every room") }
            list.removeAll { $0 == sender }
            text = capitalFirst(sender) + " left the room"
        default: // /invite, /remove
            let verb = String(f[0].dropFirst())
            if !senderHuman { lock.unlock(); return fail("only a human can \(verb)") }
            if names.isEmpty { lock.unlock(); return fail("say who: \(f[0]) @name") }
            for n in names {
                if !known.contains(n) {
                    lock.unlock()
                    return fail("the switchboard server does not know \(n). It knows: \(known.joined(separator: ", ")). A new participant is added on the server's Mac with: switchboard add NAME")
                }
                if f[0] == "/invite" && list.contains(n) { lock.unlock(); return fail("\(n) is already in this room") }
                if f[0] == "/remove" && !list.contains(n) { lock.unlock(); return fail("\(n) is not in this room") }
                if f[0] == "/remove" && humans.contains(n) { lock.unlock(); return fail("a human is not removed from a room") }
            }
            var shown: [String] = []
            for n in names {
                if f[0] == "/invite" { if !list.contains(n) { list.append(n) } } else { list.removeAll { $0 == n } }
                shown.append(capitalFirst(n))
            }
            text = f[0] == "/invite" ? "\(capitalFirst(sender)) invited \(shown.joined(separator: ", ")) to the room"
                : "\(capitalFirst(sender)) removed \(shown.joined(separator: ", ")) from the room"
        }
        rooms[room] = list
        let all = rooms
        lock.unlock()
        saveRooms(all)
        return .success(text)
    }

    /// "/room <name> @member…": a long-lived room with its maker, every human and everyone named.
    private func createRoom(_ sender: String, _ args: [String]) -> Result<String, ChatAPIError> {
        // The protocol's own wording, example included: conformance asserts it byte for byte.
        let help = "use /room <name> @member @member. A name is lower-case letters, digits, - and _, such as build-notes"
        func fail(_ s: String) -> Result<String, ChatAPIError> { .failure(ChatAPIError(status: 422, description: s)) }
        if participant(sender)?.deliver == "poll" { return fail("a launched session cannot make rooms. Ask your launcher or a human to make one") }
        guard let name = args.first else { return fail(help) }
        guard chatIsRoomName(name) else { return fail("\(goQuote(name)) is not a room name. \(help)") }
        var list = [sender]
        for p in people() where p.isHuman && !list.contains(p.name) { list.append(p.name) }
        for w in args.dropFirst() {
            let n = Self.nameWord(w)
            if n.isEmpty { continue }
            guard participant(n) != nil else { return fail("the switchboard server does not know \(n), so the room was not made") }
            if !list.contains(n) { list.append(n) }
        }
        lock.lock()
        if rooms[name] != nil { lock.unlock(); return fail("there is already a room \(name)") }
        rooms[name] = list
        let all = rooms
        lock.unlock()
        saveRooms(all)
        let shown = list.map(capitalFirst).joined(separator: ", ")
        if let st = try? store(name) {
            var first = ChatStored.change(chatNewID(), from: sender, content: "\(capitalFirst(sender)) created this room with \(shown)", at: chatNow())
            if (try? st.insert(&first)) == false { published(name, first) }
        }
        return .success("\(capitalFirst(sender)) created room \(name) with \(shown)")
    }

    private func setArchived(_ room: String, _ sender: String, _ on: Bool) -> Result<String, ChatAPIError> {
        guard isHuman(sender) else { return .failure(ChatAPIError(status: 422, description: "only a human can archive a room or reopen it")) }
        lock.lock()
        if (archived[room] ?? false) == on {
            lock.unlock()
            return .failure(ChatAPIError(status: 422, description: on ? "this room is already archived" : "this room is not archived"))
        }
        archived[room] = on
        let all = archived
        lock.unlock()
        save("archived.json", .map(all.mapValues { JValue.bool($0) }))
        return .success(on ? "\(capitalFirst(sender)) archived the room: it can be read but not posted to" : "\(capitalFirst(sender)) reopened the room")
    }

    private func setHold(_ room: String, _ sender: String, _ args: [String]) -> Result<String, ChatAPIError> {
        guard isHuman(sender) else { return .failure(ChatAPIError(status: 422, description: "only a human can change the hold")) }
        var n = -1
        if args == ["off"] { n = 0 } else if args.isEmpty || args == ["on"] { n = Self.defaultHold } else if args.count == 1, let v = Int(args[0]), (1...1000).contains(v) { n = v }
        guard n >= 0 else { return .failure(ChatAPIError(status: 422, description: "use /hold on, /hold <number from 1 to 1000>, or /hold off")) }
        let all: [String: Int] = lock.withLock {
            holds[room] = n
            agentRun[room] = 0
            return holds
        }
        save("holds.json", .map(all.mapValues { JValue.int(Int64($0)) }))
        let who = capitalFirst(sender)
        if n == 0 { return .success("\(who) turned the hold off: agents can talk among themselves without limit") }
        return .success("\(who) turned the hold on: after \(n) agent messages in a row, messages to agents wait until a human posts")
    }

    /// The answer to /rooms: the rooms this participant is in, with who else is in each.
    func roomsOf(_ name: String) -> String {
        var lines: [String] = []
        let all = allRooms()
        for room in roomNames() where member(room, name) {
            let others = (all[room] ?? []).filter { $0 != name }
            var line = "#" + room
            if isArchived(room) { line += " (archived, read-only)" }
            if !others.isEmpty { line += " with " + others.joined(separator: ", ") }
            lines.append(line)
        }
        if lines.isEmpty { return "You are in no room." }
        return "You are in: " + lines.joined(separator: "; ") + ". Start a message with #room to post in one."
    }

    // MARK: - Registered sessions

    /// Adds a session to the directory and to a room, and returns its new token (shown once, kept only as a hash).
    public func register(launcher: String, name: String, room: String) throws -> String {
        guard chatIsSessionName(name) else {
            throw ChatAPIError(status: 400, description: "a session name is lower-case letters, digits and hyphens, starting with a letter")
        }
        guard hasRoom(room) else { throw ChatAPIError(status: 404, description: "no room \(goQuote(room)). Make it first with /room \(room)") }
        guard member(room, launcher) else { throw ChatAPIError(status: 422, description: "\(launcher) is not in room \(room), so cannot add a session to it") }
        if ChatProtocol.reservedNames.contains(name) { throw ChatAPIError(status: 409, description: "the name \(name) is taken") }
        var again = false
        if let p = participant(name) {
            guard p.deliver == "poll", p.launcher == launcher else { throw ChatAPIError(status: 409, description: "the name \(name) is taken") }
            again = true
        } else {
            lock.withLock {
                participants.append(ChatParticipant(name: name, kind: "claude-session", deliver: "poll", launcher: launcher,
                                                    identity: "anthropic:claude-code:" + name))
            }
        }
        var raw = [UInt8](repeating: 0, count: 24)
        var rng = SystemRandomNumberGenerator()
        for i in raw.indices { raw[i] = UInt8.random(in: 0...255, using: &rng) }
        let token = raw.map { String(format: "%02x", $0) }.joined()
        lock.withLock { agentTokens[name] = ChatSecrets.hash(token) }
        saveAgents()
        if !member(room, name) {
            let all: [String: [String]] = lock.withLock { rooms[room, default: []].append(name); return rooms }
            saveRooms(all)
        }
        let text = again ? "\(capitalFirst(name)) rejoined the room with a new token from \(capitalFirst(launcher))"
            : "\(capitalFirst(launcher)) added the session \(capitalFirst(name)) to the room"
        if let st = try? store(room) {
            var ch = ChatStored.change(chatNewID(), from: launcher, content: text, at: chatNow())
            if (try? st.insert(&ch)) == false { published(room, ch) }
        }
        return token
    }

    /// Takes a registered session out of every room and the directory, and ends its token: its launcher or a human.
    public func unregister(by: String, name: String) throws {
        guard let p = participant(name), p.deliver == "poll" else { throw ChatAPIError(status: 404, description: "\(name) is not a registered session") }
        guard p.launcher == by || isHuman(by) else { throw ChatAPIError(status: 422, description: "\(name) was registered by \(p.launcher)") }
        let (was, all): ([String], [String: [String]]) = lock.withLock {
            participants.removeAll { $0.name == name }
            agentTokens[name] = nil
            var was: [String] = []
            for (room, list) in rooms where list.contains(name) {
                was.append(room)
                rooms[room] = list.filter { $0 != name }
            }
            return (was, rooms)
        }
        saveAgents()
        saveRooms(all)
        for room in was {
            if let st = try? store(room) {
                var ch = ChatStored.change(chatNewID(), from: by, content: "The session \(capitalFirst(name)) was taken out of the room by \(capitalFirst(by)) and removed", at: chatNow())
                if (try? st.insert(&ch)) == false { published(room, ch) }
            }
        }
    }

    func saveAgents() {
        let (ps, tokens) = lock.withLock { (participants.filter { $0.deliver == "poll" }, agentTokens) }
        // The reference writes a nil list as null.
        save("agents.json", .object([JMember("participants", ps.isEmpty ? .null : .array(ps.map(\.json))),
                                     JMember("tokens", .map(tokens.mapValues { JValue.string($0) }))]))
    }

    func saveRooms(_ all: [String: [String]]) { save("rooms.json", .map(all.mapValues { JValue.strings($0) })) }

    // MARK: - Room apps (the settings shown in the state; changing them comes later)

    struct AppSettings { var name = "", icon = "", ver: Int64 = 0, sig = "" }

    private func loadApps() {
        guard let v = readJSON("apps.json"), case .object(let m) = v else { return }
        var out: [String: AppSettings] = [:]
        for e in m where chatIsRoomName(e.key) && e.value.isObject {
            var a = AppSettings()
            a.name = ((try? e.value.field("name")?.goString("name")) ?? nil) ?? ""
            a.icon = ((try? e.value.field("icon")?.goString("icon")) ?? nil) ?? ""
            a.ver = Int64(((try? e.value.field("ver")?.goInt("ver")) ?? nil) ?? 0)
            a.sig = ((try? e.value.field("sig")?.goString("sig")) ?? nil) ?? ""
            let picture = file("appicons/\(e.key).png")
            if (a.icon != "avatars" && a.icon != "image") || !FileManager.default.fileExists(atPath: picture) {
                a.icon = ""; a.ver = 0; a.sig = ""
            }
            a.name = Self.cleanAppName(a.name) ?? ""
            out[e.key] = a
        }
        lock.withLock { apps = out }
    }

    /// A room app's name: trimmed, runs of white space made one, 1 to 30 characters that all print.
    static func cleanAppName(_ s: String) -> String? {
        let t = fields(s).joined(separator: " ")
        guard (1...30).contains(t.unicodeScalars.count) else { return nil }
        for u in t.unicodeScalars {
            if u == " " { continue }
            switch u.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter, .nonspacingMark, .spacingMark,
                 .enclosingMark, .decimalNumber, .letterNumber, .otherNumber, .connectorPunctuation, .dashPunctuation, .openPunctuation,
                 .closePunctuation, .initialPunctuation, .finalPunctuation, .otherPunctuation, .mathSymbol, .currencySymbol,
                 .modifierSymbol, .otherSymbol: continue
            default: return nil
            }
        }
        return t
    }

    /// A room's app as the page sees it, with the defaults filled in.
    func appView(_ room: String) -> JValue {
        let a = lock.withLock { apps[room] }
        let custom = a.map { !$0.name.isEmpty || !$0.icon.isEmpty } ?? false
        let name = (a?.name.isEmpty ?? true) ? chatRoomTitle(room) : a!.name
        let icon = (a?.icon.isEmpty ?? true) ? "bubble" : a!.icon
        return .object([JMember("name", .string(name)), JMember("custom", .bool(custom)), JMember("icon", .string(icon)),
                        JMember("ver", .int(a?.ver ?? 0)), JMember("sig", .string(a?.sig ?? "")), JMember("colour", .string(Self.colour(room)))])
    }

    /// A room's steady colour from its name: a hue from the FNV-1a hash, saturation and lightness 0.62.
    static func colour(_ room: String) -> String {
        var h: UInt32 = 2166136261
        for b in room.utf8 { h ^= UInt32(b); h = h &* 16777619 }
        let hue = Double(h % 360) / 60
        let s = 0.62, l = 0.62
        let c = (1 - abs(2 * l - 1)) * s
        let x = c * (1 - abs(hue.truncatingRemainder(dividingBy: 2) - 1))
        var r = 0.0, g = 0.0, b = 0.0
        switch Int(hue) {
        case 0: r = c; g = x
        case 1: r = x; g = c
        case 2: g = c; b = x
        case 3: g = x; b = c
        case 4: r = x; b = c
        default: r = c; b = x
        }
        let m = l - c / 2
        func byte(_ v: Double) -> UInt8 { UInt8(truncatingIfNeeded: Int((v + m) * 255)) }
        return String(format: "#%02x%02x%02x", byte(r), byte(g), byte(b))
    }

    // MARK: - Mentions and words

    /// The members a text names with @, in order, without the sender; a name inside code is not a mention.
    func mentionsIn(room: String, sender: String, text: String) -> [String] {
        var out: [String] = []
        let ms = members(room)
        for raw in Self.mentionNames(Self.withoutCode(text)) {
            let n = raw.lowercased()
            if n == sender || !ms.contains(n) || out.contains(n) { continue }
            out.append(n)
        }
        return out
    }

    /// Each `@name` that is at the start or after a character that is not a word character, `@`, `/` or `.` — matched
    /// left to right without overlap, as a regular expression finds them.
    static func mentionNames(_ text: String) -> [String] {
        let b = Array(text.utf8)
        var out: [String] = []
        var consumed = 0   // the end of the last match: its characters cannot start another
        var i = 0
        func word(_ c: UInt8) -> Bool { (0x30...0x39).contains(c) || (0x41...0x5A).contains(c) || (0x61...0x7A).contains(c) || c == 0x5F }
        func nameStart(_ c: UInt8) -> Bool { (0x30...0x39).contains(c) || (0x41...0x5A).contains(c) || (0x61...0x7A).contains(c) }
        while i < b.count {
            if b[i] == 0x40, i + 1 < b.count, nameStart(b[i + 1]) {
                let ok: Bool
                if i == 0 { ok = true } else if i - 1 < consumed { ok = false } else {
                    let p = b[i - 1]
                    ok = !(word(p) || p == 0x40 || p == 0x2F || p == 0x2E)
                }
                if ok {
                    var j = i + 1
                    while j < b.count, word(b[j]) || b[j] == 0x2D { j += 1 }
                    out.append(String(decoding: b[(i + 1)..<j], as: UTF8.self))
                    consumed = j
                    i = j
                    continue
                }
            }
            i += 1
        }
        return out
    }

    /// The text with what Markdown shows as code blanked out: fenced blocks and inline spans.
    static func withoutCode(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        var fence = ""
        for (i, l) in lines.enumerated() {
            if !fence.isEmpty {
                if let (run, rest) = fenceOpen(l), run.first == fence.first, run.count >= fence.count, trimSpace(String(rest)).isEmpty { fence = "" }
                lines[i] = ""
                continue
            }
            if let (run, _) = fenceOpen(l) { fence = run; lines[i] = ""; continue }
            lines[i] = blankSpans(l)
        }
        return lines.joined(separator: "\n")
    }

    /// `^ {0,3}(```+|~~~+)`: the run and what follows it.
    static func fenceOpen(_ l: String) -> (String, Substring)? {
        let u = Array(l.utf8)
        var i = 0
        while i < u.count, i < 3, u[i] == 0x20 { i += 1 }
        guard i < u.count, u[i] == 0x60 || u[i] == 0x7E else { return nil }
        let c = u[i]
        var j = i
        while j < u.count, u[j] == c { j += 1 }
        guard j - i >= 3 else { return nil }
        let run = String(repeating: c == 0x60 ? "`" : "~", count: j - i)
        return (run, Substring(String(decoding: u[j...], as: UTF8.self)))
    }

    /// Each inline code span of a line replaced by spaces.
    static func blankSpans(_ l: String) -> String {
        let u = Array(l.utf8)
        var out: [UInt8] = []
        var i = 0
        while i < u.count {
            if u[i] != 0x60 { out.append(u[i]); i += 1; continue }
            var n = 0
            while i + n < u.count, u[i + n] == 0x60 { n += 1 }
            var end = -1
            var j = i + n
            while j < u.count {
                if u[j] != 0x60 { j += 1; continue }
                var k = 0
                while j + k < u.count, u[j + k] == 0x60 { k += 1 }
                if k == n { end = j + k; break }
                j += k
            }
            if end < 0 { out.append(contentsOf: u[i..<(i + n)]); i += n; continue }
            out.append(contentsOf: [UInt8](repeating: 0x20, count: end - i))
            i = end
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// The name a word gives after @: "@Bot1," is bot1.
    static func nameWord(_ w: String) -> String {
        var s = Substring(w)
        if s.hasPrefix("@") { s = s.dropFirst() }
        while let last = s.last, ",.:;!?".contains(last) { s = s.dropLast() }
        return s.lowercased()
    }

    /// `^[A-Za-z0-9][A-Za-z0-9_-]*$`.
    static func isName(_ s: String) -> Bool {
        let u = Array(s.utf8)
        guard let f = u.first, (0x30...0x39).contains(f) || (0x41...0x5A).contains(f) || (0x61...0x7A).contains(f) else { return false }
        return u.allSatisfy { (0x30...0x39).contains($0) || (0x41...0x5A).contains($0) || (0x61...0x7A).contains($0) || $0 == 0x5F || $0 == 0x2D }
    }

    /// `^\^[0-9a-fA-F-]{6,36}$`: the start of a msg_id after ^.
    static func isIDPrefix(_ s: String) -> Bool {
        let u = Array(s.utf8)
        guard (7...37).contains(u.count), u[0] == 0x5E else { return false }
        return u.dropFirst().allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) || (0x41...0x46).contains($0) || $0 == 0x2D }
    }

    /// Go's `strings.Fields`: split on Unicode white space.
    static func fields(_ s: String) -> [String] {
        s.unicodeScalars.split(whereSeparator: { $0.properties.isWhitespace }).map { String(String.UnicodeScalarView($0)) }
    }

    static func trimSpace(_ s: String) -> String {
        var u = Substring(s).unicodeScalars
        while let f = u.first, f.properties.isWhitespace { u = u.dropFirst() }
        while let l = u.last, l.properties.isWhitespace { u = u.dropLast() }
        return String(String.UnicodeScalarView(u))
    }

    // MARK: - Files of the data folder

    func readJSON(_ name: String) -> JValue? {
        guard let d = FileManager.default.contents(atPath: file(name)) else { return nil }
        return try? ChatJSON.parse(d)
    }

    /// Writes a JSON file of the data folder as the reference does: one-space indent, mode 0600 (here atomically).
    func save(_ name: String, _ v: JValue) {
        do { try writeFile(name, ChatJSON.encodeIndented(v, indent: " ")) } catch { log("chat: \(name): \(error)") }
    }

    func writeFile(_ name: String, _ bytes: [UInt8]) throws {
        try FileManager.default.createDirectory(atPath: dataDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try ChatFiles.writeAtomically(file(name), bytes)
    }
}

/// Writing a file of the data folder: a temporary file beside it, mode 0600, renamed over it.
public enum ChatFiles {
    public static func writeAtomically(_ path: String, _ bytes: [UInt8]) throws {
        let dir = (path as NSString).deletingLastPathComponent
        let tmp = (dir as NSString).appendingPathComponent("." + (path as NSString).lastPathComponent + ".\(getpid()).tmp")
        let fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else { throw ChatStoreError(description: "\(path) cannot be written: \(String(cString: strerror(errno)))") }
        var ok = true
        bytes.withUnsafeBytes { p in
            var off = 0
            while off < p.count {
                let n = write(fd, p.baseAddress! + off, p.count - off)
                if n <= 0 { ok = false; break }
                off += n
            }
        }
        close(fd)
        guard ok, rename(tmp, path) == 0 else {
            unlink(tmp)
            throw ChatStoreError(description: "\(path) cannot be written: \(String(cString: strerror(errno)))")
        }
    }
}

/// A string quoted as Go's %q quotes it (for the names in error texts).
func goQuote(_ s: String) -> String {
    var out = "\""
    for u in s.unicodeScalars {
        switch u {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\t": out += "\\t"
        case "\r": out += "\\r"
        default:
            if u.value < 0x20 || u.value == 0x7F { out += String(format: "\\x%02x", u.value) } else { out.unicodeScalars.append(u) }
        }
    }
    return out + "\""
}
