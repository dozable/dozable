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
        subcommands: [ChatOn.self, ChatOff.self, ChatStatusCommand.self])
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
