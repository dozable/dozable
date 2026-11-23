// `make test-cli-chat`, rows A1–A10: asks — a message that waits for a decision — under the daemon, end to end. Bots with
// their own tokens on the real chat server; the human through the owner's socket; settings with doz config set.
//
//  A1. doz chat set BOT --role decider: who and --json show it, the server restarts, the generated config carries it; a
//      person is refused; --role none takes it away
//  A2. a bot posts an ask: kind ask, number 1, its plain text, the room's human addressed as its decider
//  A3. a second from the same bot is refused with the limit's words; after chat.ask_max_open 2 it is taken
//  A4. a bot without the role cannot be named a decider; with it, it decides on /agent/decide (decider_role)
//  A5. the human decides from the owner's socket (the page's route); the asker's receive gets ask-outcome
//  A6. an ask expires on its own after its time; one whose time passes while chat is off is expired at the next start
//  A7. /withdraw #N, and POST /agent/withdraw with the start of its id
//  A8. chat.asks false: an ask is refused (asks are off on this server), the protocol lists no feature; on again, it works
//  A9. a workspace's finish expires its room's open ask; deciding it is refused with the closed room's words; after reopen
//      the same about is taken at once (no cooldown)
//  A10. --as W/AGENT chat set … --role decider is refused: only the owner gives a role
import Darwin
import Foundation
import DozableChat
import DozableHost

func cliChatAskRows(h: CLIHarness, root: URL, paths: ChatPaths, page: Int, sh: (_ argv: [String], _ stdin: Data?) -> (Int32, String),
                    server: () -> Int32?, supervisor: () -> ChatServerState?) {
    let owner = ChatOwnerClient(paths: paths)
    func tokenOf(_ name: String) -> String {
        let file = root.appendingPathComponent("\(name).token").path
        let r = h.run(["chat", "add", name, "--to-file", file], timeout: 60)
        check(r.code == 0, "A1 chat add \(name) (\(r.code) \(r.err.prefix(160)))")
        return ((try? String(contentsOfFile: file, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// An agent's call with its token: the status and the answer.
    func agent(_ token: String, _ method: String, _ path: String, _ body: String? = nil) -> (Int, JValue?) {
        var argv = ["/usr/bin/curl", "-s", "-m", "15", "-X", method, "-w", "\n%{http_code}", "-H", "Authorization: Bearer \(token)"]
        if let body { argv += ["-H", "Content-Type: application/json", "--data-binary", body] }
        let out = sh(argv + ["http://127.0.0.1:\(page)\(path)"], nil).1
        let lines = out.split(separator: "\n", omittingEmptySubsequences: false)
        let status = Int(lines.last ?? "") ?? 0
        return (status, try? ChatJSON.parse(Array(lines.dropLast().joined(separator: "\n").utf8)))
    }
    func ask(_ token: String, room: String, _ spec: String, text: String = "Read the shared folder?") -> (Int, JValue?) {
        agent(token, "POST", "/agent/send", #"{"room":"\#(room)","kind":"ask","message":{"content":"\#(text)"},"ask":\#(spec)}"#)
    }
    func askOf(_ token: String, room: String, _ id: String) -> JValue? {
        agent(token, "GET", "/agent/asks/\(id)?room=\(room)").1?.field("ask")
    }
    /// The roles `doz chat who --json` gives a participant (nil: none).
    func rolesOf(_ name: String) -> [String]? {
        let rows = (try? JSONSerialization.jsonObject(with: Data(h.run(["chat", "who", "--json"]).out.utf8))) as? [[String: Any]] ?? []
        return rows.first { $0["name"] as? String == name }?["roles"] as? [String]
    }
    func restarted(from pid: Int32?, _ what: String) {
        let ok = h.waitFor(20) { server().map { $0 != pid } == true && supervisor()?.ready == true }
        check(ok, "\(what): the chat server restarted to take it")
    }

    // A1. the decider role, given and shown
    let asker = tokenOf("askbot"), decider = tokenOf("decbot"), plain = tokenOf("plainbot")
    var r = h.run(["chat", "room", "askroom", "@askbot", "@decbot", "@plainbot"])
    check(r.code == 0, "A1 a room for asks (\(r.code) \(r.err.prefix(120)))")
    let before = server()
    r = h.run(["chat", "set", "decbot", "--role", "decider"], timeout: 60)
    check(r.code == 0 && r.out.contains("decbot has the decider role"), "A1 chat set decbot --role decider (\(r.code) \(r.out.prefix(120)) \(r.err.prefix(120)))")
    restarted(from: before, "A1")
    check(h.run(["chat", "who"]).out.contains("agent · decider"), "A1 who marks decbot a decider")
    check(rolesOf("decbot") == ["decider"] && rolesOf("askbot") == nil, "A1 who --json carries roles")
    let config = (try? String(contentsOfFile: paths.config, encoding: .utf8)) ?? ""
    check(config.contains("\"roles\": [") && config.contains("\"decider\""), "A1 the generated config carries the role")
    r = h.run(["chat", "set", "ada", "--role", "decider"], timeout: 60)
    check(r.code != 0 && r.err.contains("a person decides without a role"), "A1 the human is refused a role (\(r.code) \(r.err.prefix(120)))")
    r = h.run(["chat", "set", "plainbot", "--role", "none", "--json"], timeout: 60)
    let none = (try? JSONSerialization.jsonObject(with: Data(r.out.utf8))) as? [String: Any]
    check(r.code == 0 && (none?["roles"] as? [String]) == [] && rolesOf("plainbot") == nil, "A1 --role none: no role (\(r.code) \(r.out.prefix(200)))")

    // A2. a bot posts an ask
    var (status, body) = ask(asker, room: "askroom", #"{"options":[{"id":"yes","label":"Yes"},{"id":"no","label":"No"}],"about":{"path":"~/shared"}}"#)
    let first = body?.field("msg_id")?.stringValue ?? ""
    check(status == 200 && body?.field("state")?.stringValue == "queued", "A2 askbot posts an ask (\(status) \(body.map(ChatJSON.encodeString) ?? ""))")
    let page2 = (try? owner.request("GET", "/api/rooms/askroom/messages"))?.body ?? Data()
    let posted = (try? ChatJSON.parse(page2)).flatMap { v -> JValue? in
        if case .array(let a) = v { return a.first { $0.field("msg_id")?.stringValue == first } }
        return nil
    }
    let content = posted?.field("content")?.stringValue ?? ""
    let number = (try? posted?.field("ask")?.field("number")?.goInt("number")) ?? nil
    check(posted?.field("kind")?.stringValue == "ask" && number == 1, "A2 …kind ask, number 1 (\(number.map(String.init) ?? "none"))")
    check(content.contains("A. `yes` Yes") && content.contains("/decide \(first) A"), "A2 …its plain text, for a client that knows no asks")
    check((try? posted?.field("to")?.goStrings("to")) == ["ada"], "A2 …the human, its decider, addressed")

    // A3. the limit
    (status, body) = ask(asker, room: "askroom", #"{"options":[{"id":"yes"}]}"#)
    check(status == 422 && body?.field("detail")?.stringValue == "askbot already has 1 open ask(s) in room askroom, the most it may have: withdraw one or wait for its outcome",
          "A3 a second open ask is refused (\(status) \(body?.field("detail")?.stringValue ?? ""))")
    var pid = server()
    h.run(["config", "set", "chat.ask_max_open", "2"])
    restarted(from: pid, "A3 chat.ask_max_open 2")
    (status, body) = ask(asker, room: "askroom", #"{"options":[{"id":"yes"}]}"#)
    let second = body?.field("msg_id")?.stringValue ?? ""
    check(status == 200, "A3 …then it is taken (\(status) \(body?.field("detail")?.stringValue ?? ""))")

    // A4. the role, at naming and at deciding
    (status, body) = ask(plain, room: "askroom", #"{"options":[{"id":"yes"}],"deciders":["askbot"]}"#)
    check(status == 422 && (body?.field("detail")?.stringValue ?? "").hasPrefix("askbot does not have the decider role"),
          "A4 a bot without the role cannot be named (\(status) \(body?.field("detail")?.stringValue ?? ""))")
    (status, body) = ask(plain, room: "askroom", #"{"options":[{"id":"yes"}],"deciders":["decbot"]}"#)
    let byRole = body?.field("msg_id")?.stringValue ?? ""
    check(status == 200, "A4 …with the role it can (\(status))")
    (status, body) = agent(decider, "POST", "/agent/decide", #"{"room":"askroom","ask_id":"\#(byRole.prefix(8))","option":"yes"}"#)
    check(status == 200 && body?.field("state")?.stringValue == "decided", "A4 decbot decides on /agent/decide (\(status))")
    check(askOf(plain, room: "askroom", byRole)?.field("decision")?.field("decider_role") == .bool(true), "A4 …the decision says decider_role")

    // A5. the human decides from the owner's socket; the asker is told
    let a5 = try? owner.request("POST", "/api/rooms/askroom/messages/\(first)/decide", json: Data(#"{"option":"no"}"#.utf8))
    check(a5?.status == 200 && a5?.text.contains("\"decided\"") == true, "A5 the human decides on the page's route (\(a5?.status ?? 0))")
    let got = agent(asker, "GET", "/agent/receive?wait=5").1
    var outcome: JValue?
    if case .array(let items)? = got?.field("messages") { outcome = items.first { $0.field("event")?.stringValue == "ask-outcome" && $0.field("ask_id")?.stringValue == first } }
    check(outcome?.field("option") == .string("no") && outcome?.field("from") == .string("ada"), "A5 askbot's receive has ask-outcome")

    // A6. expiry while up, and at start after a stop
    let soon = { (s: Double) in ISO8601DateFormatter().string(from: Date().addingTimeInterval(s)) }
    (status, body) = ask(plain, room: "askroom", #"{"options":[{"id":"yes"}],"about":{"n":1},"expires_at":"\#(soon(2))"}"#)
    let expiring = body?.field("msg_id")?.stringValue ?? ""
    check(status == 200, "A6 an ask that expires in 2 s (\(status) \(body?.field("detail")?.stringValue ?? ""))")
    check(h.waitFor(10) { askOf(plain, room: "askroom", expiring)?.field("state") == .string("expired") }, "A6 …expires by itself")
    (status, body) = ask(plain, room: "askroom", #"{"options":[{"id":"yes"}],"about":{"n":2},"expires_at":"\#(soon(3))"}"#)
    let down = body?.field("msg_id")?.stringValue ?? ""
    check(status == 200, "A6 an ask that expires in 3 s (\(status) \(body?.field("detail")?.stringValue ?? ""))")
    h.run(["chat", "off"], timeout: 30)
    usleep(4_000_000)
    h.run(["chat", "on"], timeout: 60)
    check(h.waitFor(20) { askOf(plain, room: "askroom", down)?.field("state") == .string("expired") }, "A6 one due while chat was off is expired at the start")
    let log = (try? String(contentsOfFile: paths.serverLog, encoding: .utf8)) ?? ""
    check(log.contains("open ask(s); those that expired while the server was down are closed"), "A6 …by the start's look (server.log)")

    // A7. withdraw by number and by the start of its id
    let n = askOf(asker, room: "askroom", second)?.field("number").flatMap { try? $0.goInt("n") } ?? 0
    (status, body) = agent(asker, "POST", "/agent/send", #"{"room":"askroom","message":{"content":"/withdraw #\#(n)"}}"#)
    check(status == 200 && body?.field("state")?.stringValue == "withdrawn", "A7 /withdraw #\(n) (\(status) \(body?.field("detail")?.stringValue ?? ""))")
    (status, body) = ask(asker, room: "askroom", #"{"options":[{"id":"yes"}]}"#)
    let third = body?.field("msg_id")?.stringValue ?? ""
    (status, body) = agent(asker, "POST", "/agent/withdraw", #"{"room":"askroom","ask_id":"\#(third.prefix(8))"}"#)
    check(status == 200 && body?.field("state")?.stringValue == "withdrawn", "A7 /agent/withdraw with the start of its id (\(status))")

    // A8. asks off, then on again
    pid = server()
    h.run(["config", "set", "chat.asks", "false"])
    restarted(from: pid, "A8 chat.asks false")
    (status, body) = ask(asker, room: "askroom", #"{"options":[{"id":"yes"}]}"#)
    check(status == 422 && body?.field("detail")?.stringValue == "asks are off on this server", "A8 an ask is refused: asks are off on this server (\(status))")
    let proto = (try? owner.request("GET", "/api/protocol")).flatMap { try? ChatJSON.parse($0.body) }
    check(proto?.field("features") == .array([]) && proto?.field("asks") == nil, "A8 …the protocol lists no feature")
    pid = server()
    h.run(["config", "set", "chat.asks", "true"])
    restarted(from: pid, "A8 chat.asks true")
    (status, body) = ask(asker, room: "askroom", #"{"options":[{"id":"yes"}]}"#)
    check(status == 200, "A8 …on again, it is taken (\(status) \(body?.field("detail")?.stringValue ?? ""))")

    // A9. a finished workspace leaves no ask waiting
    let brief = root.appendingPathComponent("ask-brief.md").path
    FileManager.default.createFile(atPath: brief, contents: Data("Asks.\n".utf8))
    r = h.run(["workspace", "new", "wsask", "--prompt-file", brief], timeout: 60)
    check(r.code == 0, "A9 a workspace wsask (\(r.code) \(r.err.prefix(160)))")
    r = h.run(["workspace", "start", "wsask"], timeout: 60)
    check(r.code == 0, "A9 …started (\(r.code) \(r.err.prefix(160)))")
    _ = try? owner.request("POST", "/api/rooms/wsask/messages", json: Data(ChatJSON.encode(.map(["content": .string("/invite @askbot")]))))
    let about = #""about":{"task":"ship"}"#
    (status, body) = ask(asker, room: "wsask", #"{"options":[{"id":"yes"}],\#(about)}"#)
    let inRun = body?.field("msg_id")?.stringValue ?? ""
    check(status == 200, "A9 askbot asks in wsask (\(status) \(body?.field("detail")?.stringValue ?? ""))")
    r = h.run(["workspace", "finish", "wsask", "--yes"], timeout: 180)
    check(r.code == 0, "A9 finish (\(r.code) \(r.err.prefix(160)))")
    check(h.waitFor(10) { askOf(asker, room: "wsask", inRun)?.field("state") == .string("expired") }, "A9 …its open ask expired at once")
    let a9 = try? owner.request("POST", "/api/rooms/wsask/messages/\(inRun)/decide", json: Data(#"{"option":"yes"}"#.utf8))
    check(a9?.status == 422 && a9?.text.contains(ChatRoomControl.closedText(room: "wsask", workspace: "wsask")) == true,
          "A9 deciding it is refused with the closed room's words (\(a9?.status ?? 0) \(a9?.text.prefix(160) ?? ""))")
    r = h.run(["workspace", "reopen", "wsask", "--no-start"], timeout: 60)
    check(r.code == 0, "A9 reopen (\(r.code) \(r.err.prefix(160)))")
    (status, body) = ask(asker, room: "wsask", #"{"options":[{"id":"yes"}],\#(about)}"#)
    check(status == 200, "A9 …the same about is taken at once: no cooldown (\(status) \(body?.field("detail")?.stringValue ?? ""))")

    // A10. only the owner gives a role
    r = h.run(["chat", "set", "plainbot", "--role", "decider", "--as", "wsask/askbot"], timeout: 60)
    check(r.code != 0 && r.err.contains("only the owner"), "A10 --as wsask/askbot chat set --role is refused: only the owner (\(r.code) \(r.err.prefix(160)))")
    check(rolesOf("plainbot") == nil, "A10 …nothing changed: plainbot has no role")
    h.run(["config", "set", "chat.ask_max_open", "1"])
}
