import Darwin
import DozableChat
import DozableHost
import Foundation

/// `doz chat serve` — the chat server itself (never listed: the daemon runs it; `doz chat …`'s other commands are in
/// `doz --help`). It is dispatched before anything else of doz runs, so a chat server reads no settings file, opens no store,
/// starts no daemon and touches no Keychain: `doz chat serve` needs only its config, its flags and its secrets file.
///
///   doz chat serve --config FILE --bind ADDR [--data-dir DIR] [--secrets-file FILE] [--line-port N] [--page-port N]
///                  [--claude-sessions DIR] [--supervised]
///
/// `--claude-sessions DIR` is where Claude Code's session records are read (default `$HOME/.claude/sessions`).
///   doz chat status [--json] --data-dir DIR
///
/// A flag is written `--name value`, `--name=value`, `-name value` or `-name=value`. A bad flag or setting exits 78.
public enum ChatCommandLine {
    static let usage = """
        usage: doz chat serve --config FILE --bind ADDR [--data-dir DIR] [--secrets-file FILE] [--line-port N] [--page-port N]
                              [--claude-sessions DIR] [--supervised]
               doz chat status [--json] --data-dir DIR

        """

    /// The server's own words, dispatched before anything of doz runs: `serve`, and `status` with `--data-dir` (the
    /// conformance runner's contract). Everything else under `doz chat` is the command group (`ChatCommand`).
    public static func isServerCommand(_ args: [String]) -> Bool {
        guard let sub = args.first else { return false }
        if sub == "serve" { return true }
        return sub == "status" && args.dropFirst().contains { a in ["--data-dir", "-data-dir"].contains { a == $0 || a.hasPrefix($0 + "=") } }
    }

    public static func run(_ args: [String], release: String) async -> Int32 {
        guard let sub = args.first else { FileHandle.standardError.write(Data(usage.utf8)); return 64 }
        switch sub {
        case "serve": return await serve(Array(args.dropFirst()), release: release)
        case "status": return status(Array(args.dropFirst()), release: release)
        case "-h", "--help", "help": FileHandle.standardOutput.write(Data(usage.utf8)); return 0
        default:
            FileHandle.standardError.write(Data("doz chat: unknown command \(sub)\n\(usage)".utf8))
            return 64
        }
    }

    /// Flags as Go's flag package reads them: the value flags given, and the bool flags that were set.
    struct Flags {
        var values: [String: String] = [:]
        var bools: Set<String> = []
    }

    static func parse(_ args: [String], values: Set<String>, bools: Set<String>) throws -> Flags {
        var f = Flags()
        var i = 0
        while i < args.count {
            let a = args[i]
            guard a.hasPrefix("-"), a != "-", a != "--" else { throw ChatConfigError("serve takes no argument \"\(a)\"") }
            var name = String(a.drop(while: { $0 == "-" }))
            var value: String?
            if let eq = name.firstIndex(of: "=") { value = String(name[name.index(after: eq)...]); name = String(name[..<eq]) }
            if bools.contains(name) {
                if let v = value, v != "true" && v != "false" { throw ChatConfigError("invalid boolean value \"\(v)\" for -\(name)") }
                if value != "false" { f.bools.insert(name) }
            } else if values.contains(name) {
                if value == nil {
                    i += 1
                    guard i < args.count else { throw ChatConfigError("flag needs an argument: -\(name)") }
                    value = args[i]
                }
                f.values[name] = value
            } else {
                throw ChatConfigError("flag provided but not defined: -\(name)")
            }
            i += 1
        }
        return f
    }

    static func serve(_ args: [String], release: String) async -> Int32 {
        if args.contains("-h") || args.contains("--help") { FileHandle.standardOutput.write(Data(usage.utf8)); return 0 }
        func bad(_ why: String) -> Int32 {
            FileHandle.standardError.write(Data("chat: \(why)\n".utf8))
            return ChatExit.badSetting
        }
        let f: Flags
        do {
            f = try parse(args, values: ["config", "bind", "data-dir", "secrets-file", "line-port", "page-port", "claude-sessions",
                                          "token-hashes", "owner-socket", "webhooks-fd", "control-fd", "daemon-socket"], bools: ["supervised"])
        } catch { return bad("\(error) (doz chat serve -h lists the settings)") }
        guard let config = f.values["config"], !config.isEmpty else { return bad("--config FILE is required") }
        var o = ChatServeOptions(configPath: absolute(config), release: release)
        o.supervised = f.bools.contains("supervised")
        o.overrides.bind = f.values["bind"]
        o.overrides.dataDir = f.values["data-dir"].map(absolute)
        o.secretsFile = f.values["secrets-file"].map(absolute)
        o.claudeSessions = f.values["claude-sessions"].map(absolute)
        // The daemon's own flags (never the conformance runner's): token hashes only, and the owner's private socket.
        o.tokenHashesFile = f.values["token-hashes"].map(absolute)
        o.ownerSocket = f.values["owner-socket"].map(absolute)
        // The daemon's pipe of webhook entries: a descriptor number only, never a value; only from the daemon.
        if let v = f.values["webhooks-fd"] {
            guard o.supervised, o.tokenHashesFile != nil else { return bad("--webhooks-fd is the daemon's: only with --supervised and --token-hashes") }
            guard let n = Int32(v), n >= 3 else { return bad("--webhooks-fd: \"\(v)\" is not a descriptor (3 or more)") }
            o.webhooksFD = n
        }
        // The daemon's control channel (participant changes without a restart): a descriptor number only; only from the daemon.
        if let v = f.values["control-fd"] {
            guard o.supervised, o.tokenHashesFile != nil else { return bad("--control-fd is the daemon's: only with --supervised and --token-hashes") }
            guard let n = Int32(v), n >= 3, n != o.webhooksFD else { return bad("--control-fd: \"\(v)\" is not a descriptor (3 or more)") }
            o.controlFD = n
        }
        // 771: the daemon's own socket, where an agent's journal and work-description calls are relayed — the daemon's flag
        // only; nothing else of the daemon is read, and no daemon is ever started from here.
        if let v = f.values["daemon-socket"] {
            guard o.supervised, o.tokenHashesFile != nil else { return bad("--daemon-socket is the daemon's: only with --supervised and --token-hashes") }
            guard v.hasPrefix("/") else { return bad("--daemon-socket: an absolute path") }
            o.relay = ChatDaemonRelay.relay(socket: v)
        }
        for flag in ["line-port", "page-port"] {
            guard let v = f.values[flag] else { continue }
            guard let n = Int(v), (0...65535).contains(n) else { return bad("--\(flag): \"\(v)\" is not a port (0 to 65535)") }
            if flag == "line-port" { o.overrides.linePort = n } else { o.overrides.pagePort = n }
        }
        await ChatServer.run(o)
    }

    static func status(_ args: [String], release: String) -> Int32 {
        let f: Flags
        do { f = try parse(args, values: ["data-dir"], bools: ["json"]) } catch {
            FileHandle.standardError.write(Data("doz chat status: \(error)\n".utf8))
            return 64
        }
        guard let dir = f.values["data-dir"], !dir.isEmpty else {
            FileHandle.standardError.write(Data("doz chat status: --data-dir DIR is required\n".utf8))
            return 64
        }
        let st = ChatServer.status(dataDir: absolute(dir), release: release)
        if f.bools.contains("json") {
            FileHandle.standardOutput.write(Data(st.text.utf8))
        } else {
            var t = st.running ? (st.ready ? "chat server: running and ready\n" : "chat server: running, not ready yet\n") : "chat server: not running\n"
            t += "  data folder: \(st.dataDir)\n"
            if let p = st.ports { t += "  line port \(p.line), page port \(p.page)\n" }
            for p in st.problems { t += "  problem: \(p.what)\n" }
            FileHandle.standardOutput.write(Data(t.utf8))
        }
        return 0
    }

    static func absolute(_ p: String) -> String {
        var s = p
        if s.hasPrefix("~/") { s = NSHomeDirectory() + String(s.dropFirst()) }
        return URL(fileURLWithPath: s).standardizedFileURL.path
    }
}

/// 771: the chat server's side of the agent relay — one `agent-relay` request per call on the daemon's own socket (never a
/// daemon started), the daemon's `AgentRelayAnswer` turned into the HTTP answer: 200 with the result, else the doz-shaped
/// error `{"error":{code, message, permission?}}` with its status (dozchat keeps its own exit table).
enum ChatDaemonRelay {
    /// The longest a relayed call waits for the daemon's answer (a journal wait holds it up to 25 s).
    static let answerSeconds = 60

    static func relay(socket: String) -> ChatAgentRelay {
        { call in await Task.detached { answer(call, socket: socket) }.value }
    }

    static func answer(_ call: ChatAgentRelayCall, socket: String) -> ChatHTTPResponse {
        var body: JSONValue?
        if !call.body.isEmpty {
            guard let v = try? JSONDecoder().decode(JSONValue.self, from: Data(call.body)) else {
                return json(400, failure("invalid-value", "the body is not JSON", ExitCodes.invalid))
            }
            body = v
        }
        var r = HostRequest(.agentRelay)
        r.agentRelay = AgentRelayRequest(participant: call.participant, route: call.route, query: call.query.isEmpty ? nil : call.query,
                                         body: body, id: call.id)
        guard let fd = UnixSocket.connect(socket) else {
            return json(503, failure("needs-daemon", "Dozable's daemon does not answer: the journal needs it running", ExitCodes.daemonUnavailable))
        }
        defer { close(fd) }
        var tv = timeval(tv_sec: answerSeconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        guard var line = try? HostWire.encoder.encode(r) else { return json(500, failure("failed", "the call could not be written", ExitCodes.failed)) }
        line.append(10)
        guard UnixSocket.writeAll(fd, line) else {
            return json(503, failure("needs-daemon", "Dozable's daemon closed the connection", ExitCodes.daemonUnavailable))
        }
        let reader = LineReader(fd: fd)
        while let l = reader.readLine(limit: 64 << 20) {
            guard let m = try? HostWire.decoder.decode(HostMessage.self, from: l) else { continue }
            if m.event != nil { continue }
            guard m.ok == true, let v = m.result,
                  let a = try? HostWire.decoder.decode(AgentRelayAnswer.self, from: HostWire.encoder.encode(v)) else {
                let e = m.error ?? HostError(.failed, "no answer")
                return json(e.code == .notPermitted ? 403 : 503, failure(e.code.rawValue, e.message, ExitCodes.exit(for: e)))
            }
            if a.ok { return json(200, a.result ?? .null) }
            let f = a.error ?? AgentRelayAnswer.Failure(code: "failed", message: "no answer", exit: ExitCodes.failed)
            var e: [String: JSONValue] = ["code": .string(relayCode(f.code)), "message": .string(f.message)]
            if let p = f.permission { e["permission"] = .string(p) }
            return json(a.httpStatus, .object(["error": .object(e)]))
        }
        return json(503, failure("needs-daemon", "Dozable's daemon did not answer", ExitCodes.daemonUnavailable))
    }

    /// The reason a refusal names: doz's code, with a value refused (the 65 group) said as `invalid`.
    static func relayCode(_ code: String) -> String {
        ["invalid", "invalid-value", "invalid-document", "usage"].contains(code) ? "invalid" : code
    }

    static func failure(_ code: String, _ message: String, _ exit: Int32) -> JSONValue {
        .object(["error": .object(["code": .string(relayCode(code)), "message": .string(message)])])
    }

    static func json(_ status: Int, _ v: JSONValue) -> ChatHTTPResponse {
        let data = (try? HostWire.encoder.encode(v)) ?? Data("null".utf8)
        return ChatHTTPResponse(status: status, headers: [("Content-Type", "application/json")], body: Array(data) + [0x0A])
    }
}
