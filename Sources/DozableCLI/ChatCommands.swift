import ArgumentParser
import Darwin
import DozableChat
import DozableHost
import Foundation

// `doz chat …` — the chat server run by the daemon on this Mac (docs/engineering/chat.md, "Under the daemon"). HIDDEN in
// this release: not in `doz --help`, the completions or the manual; `doz chat --help` lists it all. (`doz chat serve` and
// `doz chat status --data-dir DIR` are the server's own, dispatched before anything else of doz runs:
// `ChatCommandLine.isServerCommand`.)
//
// Who does the work: writes (on, off, add, remove, token) go through the daemon, the store's one owner; rooms, room, send,
// read and who go straight to the owner's socket (`ChatOwnerClient`), where the server takes the caller as you — no token
// for you exists. Reading never starts the daemon. Exit codes: 0 ok · 1 failed · 2 no such participant or room · 4 already
// exists · 6 chat is off or not ready · 64 usage.

struct ChatCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "chat",
        abstract: "An early chat server on this Mac: rooms shared by you and your agents (127.0.0.1 only).",
        discussion: """
            The doz daemon runs the chat server while chat is on (the setting chat.enabled). You take part through your \
            own socket in the store — no token for you exists. An agent takes part with its own token: it polls \
            GET /agent/receive and sends with POST /agent/send on the page port (Authorization: Bearer TOKEN). Nothing \
            on the network acts as you: the page port answers only /agent/ calls, and the line port always needs a token.

            Exit codes: 0 ok · 1 failed · 2 no such participant or room · 4 already exists · 6 chat is off or not ready · 64 usage.
            """,
        shouldDisplay: false,
        subcommands: [ChatOn.self, ChatOff.self, ChatStatusCommand.self, ChatAdd.self, ChatRemove.self, ChatWho.self, ChatTokenCommand.self,
                      ChatRooms.self, ChatRoom.self, ChatSend.self, ChatRead.self])
}

// MARK: - status

/// What `doz chat status` says (its `--json`); read from the store, the settings and the server's own status — it starts
/// nothing. No token, ever.
struct ChatStatusReport: Encodable {
    var enabled: Bool
    /// off · starting · running · restarting · failing · stopped · waiting (no daemon, or it is stopping).
    var state: String
    var ready: Bool
    var pid: Int32?
    var bind: String
    var pagePort: Int
    var linePort: Int
    /// You, in chat (nil before chat was first turned on).
    var human: String?
    var participants: [String]
    var rooms: Int?
    /// Your socket: HTTP with the page's API, as you, no token. nil before chat was first turned on.
    var ownerSocket: String?
    var dataFolder: String
    var daemonRunning: Bool
    var restarts: Int
    var lastExit: String?
    var problem: String?

    static func read(_ store: DozableStore) -> ChatStatusReport {
        let paths = ChatPaths(store: store)
        let view = ChatSettingsView.read()
        let sup = ChatServerState.load(paths)
        let server = ChatServer.status(dataDir: paths.data, release: DozableCommand.version)
        let dir = (try? ChatDirectory.load(paths)) ?? ChatDirectory()
        let daemon = store.hostIsRunning()
        var r = ChatStatusReport(enabled: view.enabled, state: "off", ready: false, pid: nil, bind: ChatConfigFile.bind,
                                 pagePort: view.pagePort, linePort: view.linePort, human: dir.human, participants: dir.participants.map(\.name),
                                 rooms: server.running ? server.rooms : nil,
                                 ownerSocket: FileManager.default.fileExists(atPath: paths.directory) ? paths.socket : nil,
                                 dataFolder: paths.data, daemonRunning: daemon, restarts: sup?.restarts ?? 0, lastExit: sup?.lastExit, problem: nil)
        if server.running { r.pid = Int32(server.pid) }
        if !view.enabled {
            r.state = server.running ? "stopping" : "off"
            return r
        }
        if !daemon {
            r.state = "waiting"
            r.problem = "the doz daemon is not running — doz chat on starts it"
            return r
        }
        r.state = sup?.state ?? "starting"
        r.problem = sup?.problem
        r.ready = server.running && server.ready && (sup?.pid.map { Int($0) == server.pid } ?? true)
        if r.ready { r.state = "running" }
        return r
    }

    var headline: String {
        switch state {
        case "off": return "chat: off (doz chat on turns it on)"
        case "running": return "chat: on — running and ready"
        case "starting": return "chat: on — starting"
        case "restarting": return "chat: on — restarting"
        case "failing": return "chat: on — failing"
        case "stopped": return "chat: on — stopped"
        case "stopping": return "chat: off — stopping"
        default: return "chat: on — waiting"
        }
    }

    var text: String {
        var s = headline + "\n"
        if enabled { s += "  \(bind), page port \(pagePort), line port \(linePort)\n" }
        if let h = human {
            let n = participants.count
            s += "  you are \(h); \(n) participant\(n == 1 ? "" : "s")" + (rooms.map { ", \($0) room\($0 == 1 ? "" : "s")" } ?? "") + "\n"
            s += "  data folder: \(DisplayPath.tilde(dataFolder))\n"
        }
        if restarts > 0 { s += "  restarted \(restarts) time\(restarts == 1 ? "" : "s")" + (lastExit.map { " (last: \($0))" } ?? "") + "\n" }
        if let p = problem { s += "  problem: \(p)\n" }
        return s
    }
}

struct ChatStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Whether chat is on and its server ready, its ports, you and the participants. (Starts nothing.)")
    @OptionGroup var g: GlobalOptions
    func run() async throws {
        let r = ChatStatusReport.read(g.dozableStore)
        if g.json { Out.json(r) } else { Out.stdout(r.text) }
    }
}

/// `doz doctor`'s chat row: ok when off or running and ready; warn while it restarts, fails or waits for a daemon; FAIL
/// when it stopped on a fault a restart cannot fix.
func chatDoctorCheck(_ store: DozableStore) -> DoctorCheck {
    let paths = ChatPaths(store: store)
    let r = ChatStatusReport.read(store)
    if !paths.socketFits { return DoctorCheck(check: "chat", status: r.enabled ? .fail : .ok, detail: (r.enabled ? "" : "off — ") + paths.socketTooLong) }
    switch r.state {
    case "off": return DoctorCheck(check: "chat", status: .ok, detail: "off (doz chat on)")
    case "running": return DoctorCheck(check: "chat", status: .ok, detail: "running and ready — 127.0.0.1, page port \(r.pagePort), line port \(r.linePort)")
    case "stopped": return DoctorCheck(check: "chat", status: .fail, detail: "stopped: " + (r.problem ?? "it exited") + " — then doz chat on")
    default: return DoctorCheck(check: "chat", status: .warn, detail: r.state + (r.problem.map { ": " + $0 } ?? ""))
    }
}

/// `doz daemon status`'s chat line (nil while chat is off).
func chatDaemonLine(_ c: ChatServerState?) -> String? {
    guard let c, c.enabled else { return nil }
    let ports = "\(c.bind), page port \(c.pagePort), line port \(c.linePort)"
    if c.ready, let pid = c.pid { return "chat: running (pid \(pid)) — \(ports)" }
    return "chat: \(c.state) — \(ports)" + (c.problem.map { " — \($0)" } ?? "")
}

// MARK: - on / off

func writeChatEnabled(_ on: Bool, _ g: GlobalOptions) throws {
    do { _ = try DozableSettings.load().writing(SettingKey.chatEnabled, .bool(on)) } catch let e as SettingsError {
        throw fail(HostError(.failed, e.message), g)
    }
}

struct ChatOn: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "on",
        abstract: "Turn chat on: the daemon starts the chat server and keeps it running (it waits until it is ready).",
        discussion: "Sets chat.enabled and starts the daemon when it is not running. While chat is on the daemon keeps running, even with daemon.always_on off. The first time, you are named: the Mac account's short name, or --name.")
    @Option(name: .long, help: "Your name in chat (the first time only): a lower-case letter, then lower-case letters, digits and -.")
    var name: String?
    @OptionGroup var g: GlobalOptions
    func run() async throws {
        let store = g.dozableStore
        let paths = ChatPaths(store: store)
        guard paths.socketFits else { throw fail(HostError(.invalid, paths.socketTooLong), g) }
        if let n = name, let why = ChatNames.refusal(n) { throw fail(HostError(.invalid, why), g) }
        // You are named first (chat still off, nothing starts), so the daemon never names you itself meanwhile.
        var first = HostRequest(.chatSync)
        first.chat = ChatRequest(name: name ?? ChatNames.defaultHuman())
        if name != nil || (try? ChatDirectory.load(paths))?.human == nil {
            _ = try call(first, g)
        }
        try writeChatEnabled(true, g)
        var r = HostRequest(.chatSync)
        r.chat = ChatRequest(retry: true, wait: true)
        let st = try decode(try call(r, g), ChatServerState.self, g)
        let report = ChatStatusReport.read(store)
        guard st.ready else {
            if g.json { Out.json(report) }
            throw fail(HostError(.failed, "chat is on, but the chat server is not ready: " + (st.problem ?? st.state) + " (doz chat status)"), g, code: DozableExit.failed)
        }
        if g.json { Out.json(report); return }
        Out.stdout("Chat is on: \(st.bind), page port \(st.pagePort), line port \(st.linePort). You are \(report.human ?? "?").\n")
    }
}

struct ChatOff: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "off", abstract: "Turn chat off: the chat server stops. Rooms and messages are kept.")
    @OptionGroup var g: GlobalOptions
    func run() async throws {
        let store = g.dozableStore
        try writeChatEnabled(false, g)
        if store.hostIsRunning() {
            var r = HostRequest(.chatSync)
            r.chat = ChatRequest(wait: true)
            _ = try call(r, g, autostart: false)
        }
        if g.json { Out.json(ChatStatusReport.read(store)); return }
        Out.stdout("Chat is off. Rooms and messages are kept.\n")
    }
}

// MARK: - participants

/// Where a new token goes: the terminal (printed once) or a new file (`--to-file`, 0600, never over an existing one).
/// Anything else is refused before anything is changed — a token is never printed into a pipe or a log.
struct TokenDestination {
    var file: String?
    var fd: Int32 = -1

    static func open(_ toFile: String?, _ g: GlobalOptions) throws -> TokenDestination {
        guard let f = toFile else {
            guard !g.json, isatty(STDOUT_FILENO) == 1 else {
                throw fail(HostError(.invalid, "a new token is printed only on a terminal: give --to-file FILE (a new file only you can read)\(g.json ? " with --json" : "")"), g)
            }
            return TokenDestination()
        }
        let path = URL(fileURLWithPath: (f as NSString).expandingTildeInPath).standardizedFileURL.path
        let fd = Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            throw fail(HostError(errno == EEXIST ? .exists : .failed, "\(DisplayPath.tilde(path)): " + (errno == EEXIST ? "it exists already (a token file is never written over)" : String(cString: strerror(errno)))), g)
        }
        return TokenDestination(file: path, fd: fd)
    }

    /// Puts the token where it goes and says so (it is never in --json).
    func deliver(_ token: String, name: String) {
        if let file {
            _ = token.withCString { write(fd, $0, strlen($0)) }
            _ = write(fd, "\n", 1)
            close(fd)
            Out.stdout("Its token is in \(DisplayPath.tilde(file)) (only you can read it).\n")
        } else {
            Out.stdout("Its token: \(token)\nThis token is not kept; doz chat token \(name) --new makes another.\n")
        }
    }

    /// Nothing was made: the empty file goes.
    func abandon() { if let file { close(fd); unlink(file) } }
}

/// What `add` / `token --json` print — never the token.
struct ChatParticipantChange: Encodable {
    var name: String
    var kind: String
    var tokenFile: String?
    var tokenGiven: Bool?
    var chat: ChatServerState
}

/// A token given on standard input (`--from-stdin`): one line.
func tokenFromStdin(_ g: GlobalOptions) throws -> String {
    let d = FileHandle.standardInput.readDataToEndOfFile()
    let t = String(decoding: d, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))
    if let why = ChatTokens.refusal(t) { throw fail(HostError(.invalid, "--from-stdin: \(why)"), g) }
    return t
}

func chatTokenCall(_ op: HostOp, name: String, toFile: String?, fromStdin: Bool, _ g: GlobalOptions) throws -> (ChatAnswer, TokenDestination?) {
    if let why = ChatNames.refusal(name) { throw fail(HostError(.invalid, why), g) }
    let given = fromStdin ? try tokenFromStdin(g) : nil
    let dest = given == nil ? try TokenDestination.open(toFile, g) : nil
    var r = HostRequest(op)
    r.chat = ChatRequest(name: name, token: given)
    do {
        let a = try decode(try call(r, g), ChatAnswer.self, g)
        return (a, dest)
    } catch {
        dest?.abandon()
        throw error
    }
}

struct ChatAdd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "add",
        abstract: "Add a participant: an agent that polls with its own token (shown once).",
        discussion: "The token is printed once on a terminal, or written to a new file with --to-file (only you can read it); doz keeps only its hash. The agent sends it as Authorization: Bearer TOKEN on the page port's /agent/ calls. The chat server restarts to take it (under a second).")
    @Argument(help: "Its name: a lower-case letter, then lower-case letters, digits and -.") var name: String
    @Option(name: .customLong("to-file"), help: "Write its token to this new file instead of the terminal.") var toFile: String?
    @Flag(name: .customLong("from-stdin"), help: "Use a token it already has, read from standard input (16 to 256 characters).") var fromStdin = false
    @OptionGroup var g: GlobalOptions
    func run() async throws {
        let (a, dest) = try chatTokenCall(.chatAdd, name: name, toFile: toFile, fromStdin: fromStdin, g)
        if g.json {
            if let t = a.token { dest?.deliver(t, name: name) }
            Out.json(ChatParticipantChange(name: name, kind: "agent", tokenFile: dest?.file, tokenGiven: fromStdin ? true : nil, chat: a.chat))
            return
        }
        Out.stdout("Added \(name) (an agent that polls with its own token).\n")
        if let t = a.token { dest?.deliver(t, name: name) } else { Out.stdout("It uses the token you gave.\n") }
    }
}

struct ChatTokenCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "token",
        abstract: "Replace a participant's token (the old one is refused at once).")
    @Argument(help: "The participant.") var name: String
    @Flag(name: .customLong("new"), help: "Make a new token (shown once, or --to-file).") var new = false
    @Flag(name: .customLong("from-stdin"), help: "Use a token it already has, read from standard input.") var fromStdin = false
    @Option(name: .customLong("to-file"), help: "Write the new token to this new file instead of the terminal.") var toFile: String?
    @OptionGroup var g: GlobalOptions
    func validate() throws {
        guard new != fromStdin else { throw ValidationError("one of --new or --from-stdin") }
    }
    func run() async throws {
        let (a, dest) = try chatTokenCall(.chatToken, name: name, toFile: toFile, fromStdin: fromStdin, g)
        if g.json {
            if let t = a.token { dest?.deliver(t, name: name) }
            Out.json(ChatParticipantChange(name: name, kind: "agent", tokenFile: dest?.file, tokenGiven: fromStdin ? true : nil, chat: a.chat))
            return
        }
        Out.stdout("Replaced \(name)'s token: the old one is refused from now on.\n")
        if let t = a.token { dest?.deliver(t, name: name) }
    }
}

struct ChatRemove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "remove", abstract: "Remove a participant and its token; it leaves every room.")
    @Argument(help: "The participant.") var name: String
    @OptionGroup var g: GlobalOptions
    func run() async throws {
        var r = HostRequest(.chatRemove)
        r.chat = ChatRequest(name: name)
        let a = try decode(try call(r, g), ChatAnswer.self, g)
        if g.json { Out.json(ChatParticipantChange(name: name, kind: "agent", chat: a.chat)); return }
        Out.stdout("Removed \(name).\n")
    }
}

// MARK: - the owner's socket

/// Your way into the running chat server (its owner's socket). Chat off, or no server listening: exit 6.
func chatOwner(_ g: GlobalOptions) throws -> ChatOwnerClient {
    guard ChatSettingsView.read().enabled else { throw fail(HostError(.unavailable, "chat is off — doz chat on"), g) }
    return ChatOwnerClient(paths: ChatPaths(store: g.dozableStore))
}

/// One request on your socket, its JSON answer (any status); a server that does not answer is exit 6.
func chatAsk(_ c: ChatOwnerClient, _ method: String, _ target: String, body: JValue? = nil, _ g: GlobalOptions) throws -> (Int, JValue) {
    do {
        let a = try c.request(method, target, json: body.map { Data(ChatJSON.encode($0)) })
        return (a.status, (try? ChatJSON.parse(a.body)) ?? .null)
    } catch ChatOwnerClient.Failure.notListening {
        throw fail(HostError(.unavailable, "chat is on but its server is not ready — doz chat status"), g)
    } catch ChatOwnerClient.Failure.failed(let why) {
        throw fail(HostError(.unavailable, why), g)
    }
}

/// The server's state: rooms → members, and the participants.
struct ChatStateView {
    var rooms: [String: [String]] = [:]
    var participants: [(name: String, kind: String)] = []
    var defaultRoom = ChatConfigFile.defaultRoom

    init(_ v: JValue) {
        if case .object(let m)? = v.field("rooms") { for e in m { rooms[e.key] = (try? e.value.goStrings("rooms")) ?? [] } }
        if case .array(let a)? = v.field("participants") {
            participants = a.compactMap { p in p.field("name")?.stringValue.map { ($0, p.field("kind")?.stringValue ?? "") } }
        }
        if let d = v.field("default_room")?.stringValue, !d.isEmpty { defaultRoom = d }
    }

    var human: String? { participants.first { $0.kind == "human" }?.name }
}

func chatState(_ c: ChatOwnerClient, _ g: GlobalOptions) throws -> ChatStateView {
    let (status, v) = try chatAsk(c, "GET", "/api/state", g)
    guard status == 200 else { throw fail(HostError(.failed, "the chat server answered \(status)"), g) }
    return ChatStateView(v)
}

func requireRoomName(_ room: String, _ g: GlobalOptions) throws {
    guard chatIsRoomName(room) else { throw fail(HostError(.invalid, "\(room) is not a room name: lower-case letters, digits, - and _"), g) }
}

struct ChatRooms: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rooms", abstract: "The rooms and their members.")
    @OptionGroup var g: GlobalOptions
    func run() async throws {
        let s = try chatState(try chatOwner(g), g)
        if g.json { Out.json(s.rooms); return }
        for r in s.rooms.keys.sorted() { Out.stdout("\(r) — \(s.rooms[r]!.joined(separator: ", "))\n") }
    }
}

struct ChatRoom: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "room", abstract: "Make a room with these members (and you).",
        discussion: "Example: doz chat room room1 @bot1 @bot2. Add someone later by sending /invite @NAME in the room (doz chat send room1 \"/invite @bot2\").")
    @Argument(help: "The room's name: lower-case letters, digits, - and _.") var name: String
    @Argument(help: "Its members, each @NAME (or NAME).") var members: [String] = []
    @OptionGroup var g: GlobalOptions
    func run() async throws {
        try requireRoomName(name, g)
        let c = try chatOwner(g)
        let s = try chatState(c, g)
        if s.rooms[name] != nil { throw fail(HostError(.exists, "there is already a room \(name)"), g) }
        let names = members.map { $0.hasPrefix("@") ? String($0.dropFirst()) : $0 }
        for n in names where !s.participants.contains(where: { $0.name == n }) {
            throw fail(HostError(.notFound, "no participant \(n) in chat (doz chat add \(n))"), g)
        }
        guard let me = s.human else { throw fail(HostError(.failed, "chat has no human"), g) }
        // The command is sent as a message in a room you are in: the first room, else any.
        let at = s.rooms[s.defaultRoom]?.contains(me) == true ? s.defaultRoom : (s.rooms.keys.sorted().first { s.rooms[$0]!.contains(me) } ?? s.defaultRoom)
        let content = (["/room", name] + names.map { "@" + $0 }).joined(separator: " ")
        let (status, v) = try chatAsk(c, "POST", "/api/rooms/\(at)/messages", body: .map(["content": .string(content)]), g)
        guard status == 200 else { throw fail(HostError(.failed, v.field("detail")?.stringValue ?? v.field("error")?.stringValue ?? "refused (\(status))"), g) }
        let after = try chatState(c, g)
        let got = after.rooms[name] ?? []
        if g.json { Out.json(["room": name, "members": got.joined(separator: ",")]); return }
        Out.stdout("Made \(name) with \(got.joined(separator: ", ")).\n")
    }
}

/// How a delivery state reads to a person.
func chatStateWord(_ s: String) -> String {
    switch s {
    case "queued": "waiting"
    case "held": "held back (too many agent messages in a row)"
    default: s
    }
}

struct ChatSend: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "send", abstract: "Send a message to a room, as you.",
        discussion: "The text is the rest of the line, or standard input with -. @NAME mentions a participant; a /command (like /invite @bot2) works as on the page.")
    @Argument(help: "The room.") var room: String
    @Argument(help: "The message (- reads it from standard input).") var text: [String] = []
    @OptionGroup var g: GlobalOptions
    func run() async throws {
        try requireRoomName(room, g)
        var content = text.joined(separator: " ")
        if text == ["-"] { content = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self) }
        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw fail(HostError(.invalid, "nothing to send: give the text, or - to read it from standard input"), g) }
        let c = try chatOwner(g)
        let s = try chatState(c, g)
        guard s.rooms[room] != nil else { throw fail(HostError(.notFound, "no room \(room) (doz chat rooms)"), g) }
        let (status, v) = try chatAsk(c, "POST", "/api/rooms/\(room)/messages", body: .map(["content": .string(content)]), g)
        let state = v.field("state")?.stringValue ?? ""
        guard status == 200 else { throw fail(HostError(.failed, v.field("detail")?.stringValue ?? v.field("error")?.stringValue ?? "refused (\(status))"), g) }
        let id = v.field("msg_id")?.stringValue ?? ""
        // Who it went to, and how far it got.
        var states: [(String, String)] = []
        let (ps, page) = try chatAsk(c, "GET", "/api/rooms/\(room)/messages?limit=50", g)
        if ps == 200, case .array(let ms) = page, let m = ms.first(where: { $0.field("msg_id")?.stringValue == id }), case .array(let sts)? = m.field("states") {
            for x in sts { if let r = x.field("recipient")?.stringValue, let st = x.field("state")?.stringValue { states.append((r, st)) } }
        }
        if g.json { Out.json(["room": room, "msg_id": id, "state": state]); return }
        if state == "info" || state == "duplicate" {
            Out.stdout((v.field("detail")?.stringValue).map { $0 + "\n" } ?? "Sent to \(room).\n")
            return
        }
        Out.stdout("Sent to \(room)" + (states.isEmpty ? "" : " — " + states.map { "\($0.0): \(chatStateWord($0.1))" }.joined(separator: ", ")) + ".\n")
    }
}

struct ChatRead: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "read", abstract: "Read a room as you see it; --follow keeps showing what comes.")
    @Argument(help: "The room.") var room: String
    @Option(name: .long, help: "How many of the latest messages (1 to 500).") var last = 20
    @Flag(name: .long, help: "Keep showing new messages until interrupted (Ctrl-C).") var follow = false
    @OptionGroup var g: GlobalOptions

    func validate() throws { guard (1...500).contains(last) else { throw ValidationError("--last is 1 to 500") } }

    func run() async throws {
        try requireRoomName(room, g)
        let c = try chatOwner(g)
        let s = try chatState(c, g)
        guard s.rooms[room] != nil else { throw fail(HostError(.notFound, "no room \(room) (doz chat rooms)"), g) }
        var seen = try page(c, after: 0)
        guard follow else { return }
        // Follow: the stream, from where the page left off; a server that restarts (a participant added) is reconnected
        // to, and what came meanwhile is read first.
        var lost: Date?
        while true {
            do {
                try c.stream("/api/stream") { data in
                    lost = nil
                    guard let v = try? ChatJSON.parse(Array(data.utf8)), v.field("kind")?.stringValue == "message",
                          v.field("room")?.stringValue == room, let m = v.field("message") else { return true }
                    let seq = Int64(((try? m.field("seq")?.goInt("seq")) ?? nil) ?? 0)
                    if seq > seen { show(m); seen = seq }
                    return true
                }
            } catch {}
            if lost == nil { lost = Date() }
            if Date().timeIntervalSince(lost!) > 60 { throw fail(HostError(.unavailable, "the chat server went away"), g) }
            try? await Task.sleep(for: .seconds(1))
            if let n = try? page(c, after: seen) { seen = n }
        }
    }

    /// Prints a page (the latest `last`, or everything after `after`); answers the last seq shown.
    func page(_ c: ChatOwnerClient, after: Int64) throws -> Int64 {
        let target = after > 0 ? "/api/rooms/\(room)/messages?after=\(after)&limit=500" : "/api/rooms/\(room)/messages?limit=\(last)"
        let (status, v) = try chatAsk(c, "GET", target, g)
        guard status == 200, case .array(let ms) = v else {
            throw fail(HostError(status == 403 ? .notFound : .failed, v.field("error")?.stringValue ?? "the chat server answered \(status)"), g)
        }
        var top = after
        if g.json && !follow { Out.stdout(String(decoding: ChatJSON.encodeIndented(v, indent: "  "), as: UTF8.self) + "\n") }
        for m in ms {
            if !(g.json && !follow) { show(m) }
            top = max(top, Int64(((try? m.field("seq")?.goInt("seq")) ?? nil) ?? 0))
        }
        return top
    }

    /// One message as a line: `14:02 ada: hello @bot1` (no ids; --json keeps them).
    func show(_ m: JValue) {
        if g.json { Out.stdout(String(decoding: ChatJSON.encode(m), as: UTF8.self) + "\n"); return }
        let at = m.field("at")?.doubleValue ?? 0
        let f = DateFormatter()
        f.dateFormat = Date().timeIntervalSince1970 - at > 86_400 ? "yyyy-MM-dd HH:mm" : "HH:mm"
        let when = f.string(from: Date(timeIntervalSince1970: at))
        let from = m.field("from")?.stringValue ?? "?"
        let kind = m.field("kind")?.stringValue ?? ""
        var text = m.field("content")?.stringValue ?? ""
        if m.field("deleted") == .bool(true) { text = "(deleted)" }
        if kind == "private" { text = "(a direct message between others)" }
        if case .array(let files)? = m.field("attachments"), !files.isEmpty {
            text += " [" + files.compactMap { $0.field("name")?.stringValue }.joined(separator: ", ") + "]"
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let lead = kind == "change" ? "\(when) — " : "\(when) \(from): "
        Out.stdout(lead + (lines.first.map(String.init) ?? "") + "\n")
        for l in lines.dropFirst() { Out.stdout(String(repeating: " ", count: lead.count) + l + "\n") }
    }
}

struct ChatWho: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "who", abstract: "Who is in chat: name, kind, token, rooms, here or away.")
    @OptionGroup var g: GlobalOptions

    struct Row: Encodable { var name: String; var kind: String; var token: Bool; var rooms: [String]; var here: Bool? }

    func run() async throws {
        let paths = ChatPaths(store: g.dozableStore)
        let dir = (try? ChatDirectory.load(paths)) ?? ChatDirectory()
        let hashes = (try? ChatTokenHashes.load(paths)) ?? ChatTokenHashes()
        var rooms: [String: [String]] = [:]
        var here: [String: Bool] = [:]
        var running = false
        if ChatSettingsView.read().enabled {
            let c = ChatOwnerClient(paths: paths)
            if let a = try? c.request("GET", "/api/state"), a.status == 200, let v = try? ChatJSON.parse(a.body) {
                running = true
                rooms = ChatStateView(v).rooms
                if let p = try? c.request("GET", "/api/presence"), p.status == 200, case .array(let ps)? = try? ChatJSON.parse(p.body) {
                    for x in ps {
                        if let n = x.field("name")?.stringValue { here[n] = ["here", "present", "working", "idle", "woken"].contains(x.field("state")?.stringValue ?? "") }
                    }
                }
            }
        }
        func roomsOf(_ n: String) -> [String] { rooms.keys.sorted().filter { rooms[$0]!.contains(n) } }
        var rows: [Row] = []
        if let h = dir.human { rows.append(Row(name: h, kind: "you", token: false, rooms: roomsOf(h), here: running ? here[h] ?? false : nil)) }
        for p in dir.participants {
            rows.append(Row(name: p.name, kind: p.kind, token: hashes.sha256[p.name] != nil, rooms: roomsOf(p.name), here: running ? here[p.name] ?? false : nil))
        }
        if g.json { Out.json(rows); return }
        if rows.isEmpty { Out.stdout("nobody yet — doz chat on, then doz chat add NAME\n"); return }
        var t = [["NAME", "KIND", "TOKEN", "ROOMS", "HERE"]]
        for r in rows {
            t.append([r.name, r.kind, r.kind == "you" ? "—" : (r.token ? "yes" : "no"), r.rooms.isEmpty ? "—" : r.rooms.joined(separator: ","),
                      r.here.map { $0 ? "here" : "away" } ?? "—"])
        }
        Out.stdout(Out.table(t))
    }
}
