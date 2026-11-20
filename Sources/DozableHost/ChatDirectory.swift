import Darwin
import DozableChat
import Foundation

// The chat server under the daemon: its folder in the store, Dozable's own records of who is in chat, and the files the
// server is started with — all generated here, never edited by hand (docs/engineering/chat.md, "Under the daemon").
//
//   <store>/chat/                0700
//     directory.json             Dozable's record: the human and the participants (names and kinds, never a token)
//     tokens.json                the participants' tokens as SHA-256 only — the server's `--token-hashes`
//     config.json                generated from the settings and directory.json; checked by `ChatConfig.parse` first
//     chat.sock                  the owner's private socket (`--owner-socket`)
//     server.log                 the server's standard error, append-only, kept to one older file at 2 MiB
//     supervisor.json            the supervisor's state, read by `doz chat status` and `doz doctor` without a daemon
//     data/                      the server's data folder, in the protocol's format
//
// Every file is 0600 and written atomically. A plain token never touches a file: it is made by the daemon, hashed at once,
// and its value travels once, in the answer to the command that asked for it.

/// Where everything of the chat server lives in a store.
public struct ChatPaths: Sendable, Equatable {
    public let folder: String

    public init(store: DozableStore) { folder = store.root.appendingPathComponent("chat").path }
    public init(folder: String) { self.folder = folder }

    func path(_ name: String) -> String { (folder as NSString).appendingPathComponent(name) }
    public var directory: String { path("directory.json") }
    public var tokens: String { path("tokens.json") }
    public var config: String { path("config.json") }
    public var socket: String { path("chat.sock") }
    public var serverLog: String { path("server.log") }
    public var supervisor: String { path("supervisor.json") }
    public var data: String { path("data") }

    /// A Unix socket's path must fit in sockaddr_un (103 bytes and its NUL): a store deeper than that cannot have chat.
    public var socketFits: Bool { socket.utf8.count <= ChatOwnerSocket.maximumPathBytes }
    public var socketTooLong: String {
        "the chat server's socket path would be \(socket.utf8.count) bytes (\(socket)); a socket's path can be at most \(ChatOwnerSocket.maximumPathBytes) — use a store with a shorter path"
    }

    /// Makes the folder (0700) when missing; refuses one that is a link, not a folder, or another user's, and closes one
    /// that is open to others.
    public func ensureFolder() throws {
        var st = stat()
        if lstat(folder, &st) != 0 {
            guard mkdir(folder, 0o700) == 0 || errno == EEXIST else {
                throw HostError(.failed, "cannot make \(folder): \(String(cString: strerror(errno)))")
            }
            guard lstat(folder, &st) == 0 else { throw HostError(.failed, "cannot read \(folder)") }
        }
        guard (st.st_mode & S_IFMT) == S_IFDIR else { throw HostError(.failed, "\(folder) is not a folder (a link is refused)") }
        guard st.st_uid == getuid() else { throw HostError(.failed, "\(folder) belongs to another user") }
        if st.st_mode & 0o777 != 0o700 { chmod(folder, 0o700) }
    }

    /// Writes one file of the folder atomically, 0600.
    public func write(_ name: String, _ data: Data) throws {
        let final = path(name)
        let tmp = path(".\(name).\(getpid()).\(UInt32.random(in: 0...UInt32.max))")
        let fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw HostError(.failed, "cannot write \(final): \(String(cString: strerror(errno)))") }
        let ok = data.withUnsafeBytes { b -> Bool in
            var at = 0
            while at < b.count {
                let n = Darwin.write(fd, b.baseAddress! + at, b.count - at)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { return false }
                at += n
            }
            return true
        }
        fchmod(fd, 0o600)
        close(fd)
        guard ok, rename(tmp, final) == 0 else {
            unlink(tmp)
            throw HostError(.failed, "cannot write \(final): \(String(cString: strerror(errno)))")
        }
    }
}

/// Dozable's record of who is in chat (`directory.json`). The daemon owns it.
public struct ChatDirectory: Codable, Equatable, Sendable {
    public struct Participant: Codable, Equatable, Sendable {
        public var name: String
        /// The protocol's kind: `agent` (the default), `claude-session` or `grok-bot` — the identity of its new messages.
        public var kind: String
        public var added: String
        /// `webhook`: the server calls its webhook entry with each message for it. `inbox` (a `claude-session` only): the
        /// server writes each message into the inbox of the running Claude Code session of that name on this Mac (its
        /// record in the sessions folder of the person who runs the daemon). nil: it collects them itself, polling with
        /// its own token (`GET /agent/receive`). An older doz ignores the field and treats it as one that polls.
        public var deliver: String?
        /// Its webhook entry's name (nil: its own name). One entry may serve several bots.
        public var webhook: String?
        /// With `inbox`: the Claude Code session's name, as its record says it (nil: its own name).
        public var session: String?
        /// The roles the owner gave it (`doz chat set NAME --role decider`): `decider` lets a participant that is not human be
        /// named as a decider of an ask, and decide it. nil: none. An older doz drops it when it rewrites the file.
        public var roles: [String]?
        public init(name: String, kind: String = "agent", added: String, deliver: String? = nil, webhook: String? = nil, session: String? = nil,
                    roles: [String]? = nil) {
            self.name = name; self.kind = kind; self.added = added; self.deliver = deliver; self.webhook = webhook; self.session = session
            self.roles = roles
        }

        /// Whether the owner made it a decider.
        public var isDecider: Bool { roles?.contains("decider") == true }

        /// The entry its calls use, when it is delivered to by webhook.
        public var webhookEntry: String? { deliver == "webhook" ? (webhook ?? name) : nil }
        /// The Claude Code session it is delivered into, when it is delivered to by inbox.
        public var inboxSession: String? { deliver == "inbox" ? (session ?? name) : nil }
        /// How it is reached, in one word: `inbox`, `webhook` or `poll`.
        public var delivery: String { deliver == "inbox" ? "inbox" : deliver == "webhook" ? "webhook" : "poll" }
    }

    /// The deliveries `doz chat set --deliver` takes.
    public static let deliveries = ["inbox", "poll", "webhook"]
    /// The roles `doz chat set --role` takes (`none` takes every role away).
    public static let roles = ["decider", "none"]

    /// Whether any participant is delivered to by inbox (the server then reads the person's Claude Code session records).
    public var hasInbox: Bool { participants.contains { $0.inboxSession != nil } }

    /// Why this delivery cannot be given to a participant of this kind (nil: it can). Inbox is for a `claude-session` only;
    /// a session's name follows the name rule.
    public static func deliveryRefusal(_ deliver: String, kind: String, session: String?) -> String? {
        guard deliveries.contains(deliver) else { return "\(deliver) is not a delivery: \(deliveries.joined(separator: ", "))" }
        if deliver == "inbox" && kind != "claude-session" {
            return "inbox delivery is for a Claude Code session: its kind must be claude-session (it is \(kind)) — add --kind claude-session"
        }
        if session != nil && deliver != "inbox" { return "--session goes with inbox delivery" }
        if let s = session, !chatIsClaudeSessionName(s) {
            return "\"\(s.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? "?" : String($0) }.joined())\" is not a Claude Code session name chat can match: "
                + "1–100 characters, as the session's name shows it — no line breaks or control characters, no /, no space at either end"
        }
        return nil
    }

    /// The kinds a participant may have.
    public static let kinds = ["agent", "claude-session", "grok-bot"]

    /// The webhook entries in use, each with the participants that use it.
    public var webhookEntries: [String: [String]] {
        var out: [String: [String]] = [:]
        for p in participants { if let e = p.webhookEntry { out[e, default: []].append(p.name) } }
        return out
    }

    public var version = 1
    public var human: String?
    public var participants: [Participant] = []

    public init(human: String? = nil, participants: [Participant] = []) { self.human = human; self.participants = participants }

    public static func load(_ paths: ChatPaths) throws -> ChatDirectory {
        guard let d = FileManager.default.contents(atPath: paths.directory) else { return ChatDirectory() }
        do {
            let r = try JSONDecoder().decode(ChatDirectory.self, from: d)
            guard r.version == 1 else { throw HostError(.failed, "\(paths.directory) is version \(r.version), which this doz does not read") }
            return r
        } catch let e as HostError { throw e } catch {
            throw HostError(.failed, "\(paths.directory) cannot be read: \(error.localizedDescription)")
        }
    }

    public func bytes() -> Data { (try? Self.encoder.encode(self)).map { $0 + Data("\n".utf8) } ?? Data() }

    static let encoder: JSONEncoder = { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]; return e }()

    public func has(_ name: String) -> Bool { human == name || participants.contains { $0.name == name } }
}

/// Where the chat server reads Claude Code's session records when a participant is delivered to by inbox: the sessions
/// folder of the person who runs the daemon, `<their home>/.claude/sessions` (the REAL home, from the user database —
/// never `$HOME`, never guessed). Only an unfenced Claude Code session keeps its record there: a fenced session's
/// Claude Code keeps its own under the session's folder, so it is never an inbox target (it polls with dozchat).
///
/// A test run of any kind reads its seam `DOZ_TEST_CLAUDE_SESSIONS` (an absolute scratch folder the Makefile sets for every
/// test target), and `TestSafety` stops a guarded run that would still name the real folder.
public enum ChatClaudeSessions {
    public static let testSeam = "DOZ_TEST_CLAUDE_SESSIONS"

    public static func folder(environment env: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if TestSafety.testRun(env), let seam = env[testSeam], seam.hasPrefix("/") { return seam }
        let real = TestSafety.realHome.appendingPathComponent(".claude/sessions").path
        TestSafety.enforce(TestSafety.claudeSessionsViolation(real), env: env)
        return real
    }
}

/// The participants' tokens, as SHA-256 only (`tokens.json` — the server reads it with `--token-hashes`).
public struct ChatTokenHashes: Codable, Equatable, Sendable {
    public var version = 1
    public var sha256: [String: String] = [:]

    public init(sha256: [String: String] = [:]) { self.sha256 = sha256 }

    public static func load(_ paths: ChatPaths) throws -> ChatTokenHashes {
        guard let d = FileManager.default.contents(atPath: paths.tokens) else { return ChatTokenHashes() }
        guard let r = try? JSONDecoder().decode(ChatTokenHashes.self, from: d), r.version == 1,
              r.sha256.values.allSatisfy(ChatSecrets.isHashHex) else {
            throw HostError(.failed, "\(paths.tokens) cannot be read (it holds hashes only — doz chat token NAME --new makes another)")
        }
        return r
    }

    public func bytes() -> Data { (try? ChatDirectory.encoder.encode(self)).map { $0 + Data("\n".utf8) } ?? Data() }
}

/// Names in chat: the session-name rule (a lower-case letter, then lower-case letters, digits and `-`, at most 40),
/// and never `chat` (the server's own lines are from it).
public enum ChatNames {
    public static func refusal(_ name: String) -> String? {
        if ChatProtocol.reservedNames.contains(name) { return "\(name) is reserved: the chat server writes its own lines under it" }
        guard chatIsSessionName(name) else {
            return "\(name) is not a name in chat: a lower-case letter, then lower-case letters, digits and -, at most 40"
        }
        return nil
    }

    /// The human's name when none is given: the Mac account's short name, cleaned to the rule (`me` when nothing is left).
    public static func defaultHuman(_ account: String = NSUserName()) -> String {
        var out = ""
        for c in account.lowercased().unicodeScalars {
            if ("a"..."z").contains(c) || ("0"..."9").contains(c) { out.unicodeScalars.append(c) } else if !out.isEmpty, !out.hasSuffix("-") { out += "-" }
        }
        while let f = out.unicodeScalars.first, !("a"..."z").contains(f) { out.removeFirst() }
        out = String(out.prefix(40))
        while out.hasSuffix("-") { out.removeLast() }
        return refusal(out) == nil ? out : "me"
    }
}

/// Tokens: made by the daemon, hashed at once.
public enum ChatTokens {
    /// `dzc_` and 32 random bytes in base64url (47 characters).
    public static func make() -> String {
        var b = [UInt8](repeating: 0, count: 32)
        arc4random_buf(&b, b.count)
        let s = Data(b).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "dzc_" + s
    }

    /// Why a token someone already has may not be used (nil: it may): 16 to 256 characters, no white space.
    public static func refusal(_ t: String) -> String? {
        guard (ChatSecrets.minimumTokenLength...256).contains(t.count) else { return "a token is 16 to 256 characters" }
        guard !t.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || $0.value < 0x20 }) else {
            return "a token has no spaces or line breaks"
        }
        return nil
    }
}

/// The asks settings the generated config carries (`chat.asks`, `chat.ask_max_open`, `chat.ask_expiry_seconds`,
/// `chat.ask_cooldown_seconds`); the defaults are the server's own.
public struct ChatAskSettings: Equatable, Sendable {
    public var enabled = true
    public var maxOpen = 1
    public var expirySeconds = 86400
    public var cooldownSeconds = 600
    public init(enabled: Bool = true, maxOpen: Int = 1, expirySeconds: Int = 86400, cooldownSeconds: Int = 600) {
        self.enabled = enabled; self.maxOpen = maxOpen; self.expirySeconds = expirySeconds; self.cooldownSeconds = cooldownSeconds
    }
}

/// The server's `config.json`, generated: the human's and the participants' entries, the first room, and an access
/// profile in which no TCP caller is ever the human — loopback only (`bind` and `allow`), tokens required from every
/// caller, and every loopback address an agent address (the page port serves it /agent/… and nothing else). The human
/// comes in through the owner's socket only.
public enum ChatConfigFile {
    public static let bind = "127.0.0.1"
    public static let defaultRoom = "general"

    /// `remoteBind`: this Mac's Tailscale addresses the server also listens on (the ones of `chat.remote_listen` it has
    /// now); `remoteAgents`: the machines let in there — each in `allow` (the line port) and an agent address.
    /// `asks`: the asks settings (`chat.asks`, `chat.ask_*`), each written only when it is not the server's default — a
    /// store with no roles and default settings gets the same bytes as before asks.
    public static func bytes(_ d: ChatDirectory, paths: ChatPaths, pagePort: Int, linePort: Int, remoteBind: [String] = [],
                             remoteAgents: [String] = [], asks: ChatAskSettings = ChatAskSettings()) throws -> [UInt8] {
        guard let human = d.human else { throw HostError(.failed, "chat has no human yet (doz chat on names you)") }
        var people: [JValue] = [.object([JMember("name", .string(human)), JMember("kind", .string("human")), JMember("deliver", .string("web"))])]
        // No deliver value: a participant that is not the human collects what is addressed to it by polling, with its own
        // token (the server's `ChatParticipant.route`; a `poll` value is a registered session's and takes no own token).
        // A webhook bot: the server calls its entry (the address and the header come on the daemon's pipe, never here).
        // A Claude Code session delivered to by inbox: `inbox-socket` and the session's name (the server finds its record by
        // that name in the sessions folder the supervisor hands it with --claude-sessions — never a guessed path).
        for p in d.participants {
            var fields = [JMember("name", .string(p.name)), JMember("kind", .string(p.kind))]
            if let e = p.webhookEntry { fields += [JMember("deliver", .string("webhook")), JMember("webhook", .string(e))] }
            if let s = p.inboxSession { fields += [JMember("deliver", .string("inbox-socket")), JMember("session", .string(s))] }
            if p.isDecider { fields.append(JMember("roles", .strings(["decider"]))) }
            people.append(.object(fields))
        }
        var members = [
            JMember("line_port", .int(Int64(linePort))),
            JMember("http_port", .int(Int64(pagePort))),
            JMember("data_dir", .string(paths.data)),
            JMember("default_room", .string(defaultRoom)),
            JMember("participants", .array(people)),
            JMember("rooms", .object([JMember(defaultRoom, .strings([human]))])),
            JMember("allow", .strings(["127.0.0.1", "::1"] + remoteAgents)),
            JMember("require_tokens", .bool(true)),
            JMember("agent_addresses", .strings(["127.0.0.0/8", "::1"] + remoteAgents)),
            JMember("secrets_file_only", .bool(true)),
            JMember("bind", .string(bind)),
        ]
        if !remoteBind.isEmpty { members.append(JMember("remote_bind", .strings(remoteBind))) }
        if !asks.enabled { members.append(JMember("no_asks", .bool(true))) }
        let def = ChatAskSettings()
        if asks.expirySeconds != def.expirySeconds { members.append(JMember("ask_expiry_seconds", .int(Int64(asks.expirySeconds)))) }
        if asks.cooldownSeconds != def.cooldownSeconds { members.append(JMember("ask_cooldown_seconds", .int(Int64(asks.cooldownSeconds)))) }
        if asks.maxOpen != def.maxOpen { members.append(JMember("ask_max_open", .int(Int64(asks.maxOpen)))) }
        let v = JValue.object(members)
        let out = ChatJSON.encodeIndented(v, indent: " ") + [0x0A]
        // The server's own loader judges it before it is written, and the profile is asserted, not assumed.
        let c: ChatConfig
        do { c = try ChatConfig.parse(Data(out)); try c.check() } catch { throw HostError(.failed, "the generated chat config is refused: \(error)") }
        // Every address `allow` lets in that is not loopback is a Tailscale address and an agent address; every address
        // listened on besides loopback is a Tailscale address (and the config's own check refuses anything else).
        let access = c.access
        guard c.bind == bind, c.requireTokens, c.testOwnedAddresses.isEmpty,
              c.allow.allSatisfy({ e in
                  guard let a = ChatAddress(e) else { return false }
                  return a.isLoopback || (ChatWebhookAddress.tailnet.contains(a) && access.isAgentAddress(e) && !access.isOwned(e))
              }),
              c.remoteBind.allSatisfy({ ChatAddress($0).map(ChatWebhookAddress.tailnet.contains) == true }),
              c.agentAddresses.contains("127.0.0.0/8"),
              // inbox-socket only for a Claude Code session, with a session name of the rule (never a path)
              c.participants.allSatisfy({ $0.isHuman || $0.deliver.isEmpty || ($0.deliver == "webhook" && ChatWebhookEntries.nameRefusal($0.webhook) == nil)
                  || ($0.deliver == "inbox-socket" && $0.kind == "claude-session" && chatIsClaudeSessionName($0.session)) }) else {
            throw HostError(.failed, "the generated chat config is not loopback-only with tokens required")
        }
        return out
    }

    /// Why these ports cannot be used (nil: they can): the two the same, or one of them a dashboard's.
    public static func portClash(pagePort: Int, linePort: Int, dashboards: [(String, Int)]) -> String? {
        if pagePort == linePort { return "chat.page_port and chat.line_port are both \(pagePort) — doz config set chat.line_port N" }
        for (key, p) in dashboards where p > 0 {
            if p == pagePort { return "chat.page_port \(p) is the dashboard's port (\(key)) — doz config set chat.page_port N" }
            if p == linePort { return "chat.line_port \(p) is the dashboard's port (\(key)) — doz config set chat.line_port N" }
        }
        return nil
    }
}

/// What the supervisor does after its server exits — pure (`ChatRestartPolicyTests`).
///   · exit 78 (a fault a restart cannot fix): never tried again until the generated files change or `doz chat on`;
///   · anything else (another code, a signal): tried again after 1, 2, 4, 8, 16, 32, then 60 s; a server that stayed up
///     10 minutes starts the count again; 5 failures within 10 minutes is `failing` (until `doz chat on`).
public struct ChatRestartPolicy: Equatable, Sendable {
    public static let backoff: [Double] = [1, 2, 4, 8, 16, 32, 60]
    public static let window: Double = 600
    public static let failingAfter = 5

    public enum Next: Equatable, Sendable {
        case retry(after: Double)
        case stopped
        case failing
    }

    /// Failures in a row (reset by 10 minutes up).
    public var consecutive = 0
    /// When the recent failures happened (seconds, any clock), within the window.
    public var recent: [Double] = []

    public init() {}

    public mutating func exited(code: Int32?, upSeconds: Double, now: Double) -> Next {
        if code == ChatExit.badSetting { return .stopped }
        if upSeconds >= Self.window { consecutive = 0 }
        consecutive += 1
        recent = recent.filter { now - $0 < Self.window } + [now]
        if recent.count >= Self.failingAfter { return .failing }
        return .retry(after: Self.backoff[min(consecutive - 1, Self.backoff.count - 1)])
    }

    /// `doz chat on` (or new files): start afresh.
    public mutating func reset() { consecutive = 0; recent = [] }
}
