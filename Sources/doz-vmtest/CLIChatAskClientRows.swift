// `make test-cli-chat`, rows D1–D14: asks for people and bots, after A1–A10 (their bots, rooms and the wsask workspace).
// A person through `doz chat ask | decide | withdraw | asks`; a bot with its own token.
//
//  D1. a person asks naming decbot (decider role): "Asked #N"; doz chat asks and --json list it
//  D2. doz chat withdraw R N — a bare number is #N
//  D4. a bot's ask decided with doz chat decide R #N B: "Answered #N: B. Next (decided by you)."; the asker's receive gets
//      ask-outcome
//  D5. by label, by free words, --decline "not now"
//  D6. Dozable's words for answered, expired (+2 s), withdrawn, not a decider (only a role bot named), the asker — exit 3
//      (751, D10: already-answered, invalid-phase, not-owned)
//  D10. --as W/AGENT chat decide: no role → the gate refuses citing chat.decide; with the role → "with its own token"
//  D11. chat off: exit 6; chat.asks false → "Asks are off…"
//  D12. a finished workspace: "its room is closed" — exit 3
import Darwin
import Foundation
import DozableChat
import DozableHost

func cliChatAskClientRows(h: CLIHarness, root: URL, paths: ChatPaths, page: Int, sh: (_ argv: [String], _ stdin: Data?) -> (Int32, String),
                          server: () -> Int32?, supervisor: () -> ChatServerState?) {
    func token(_ name: String) -> String {
        ((try? String(contentsOfFile: root.appendingPathComponent("\(name).token").path, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func agent(_ token: String, _ method: String, _ path: String, _ body: String? = nil) -> (Int, JValue?) {
        var argv = ["/usr/bin/curl", "-s", "-m", "15", "-X", method, "-w", "\n%{http_code}", "-H", "Authorization: Bearer \(token)"]
        if let body { argv += ["-H", "Content-Type: application/json", "--data-binary", body] }
        let out = sh(argv + ["http://127.0.0.1:\(page)\(path)"], nil).1
        let lines = out.split(separator: "\n", omittingEmptySubsequences: false)
        return (Int(lines.last ?? "") ?? 0, try? ChatJSON.parse(Array(lines.dropLast().joined(separator: "\n").utf8)))
    }
    /// A bot's ask: its number (0: refused).
    func botAsk(_ token: String, room: String = "askroom", _ spec: String, text: String = "When do we ship?") -> Int {
        let (status, body) = agent(token, "POST", "/agent/send", #"{"room":"\#(room)","kind":"ask","message":{"content":"\#(text)"},"ask":\#(spec)}"#)
        guard status == 200, let id = body?.field("msg_id")?.stringValue else {
            check(false, "D a bot's ask (\(status) \(body?.field("detail")?.stringValue ?? ""))")
            return 0
        }
        let a = agent(token, "GET", "/agent/asks/\(id)?room=\(room)").1?.field("ask")
        return Int(((try? a?.field("number")?.goInt("number")) ?? nil) ?? 0)
    }
    func restarted(from pid: Int32?, _ what: String) {
        check(h.waitFor(20) { server().map { $0 != pid } == true && supervisor()?.ready == true }, "\(what): the chat server restarted to take it")
    }
    let asker = token("askbot"), plain = token("plainbot")
    var n = 0
    let days = #"{"questions":[{"options":[{"id":"now","label":"Now"},{"id":"next","label":"Next"}]}],"about":{"d":"%@"}}"#
    func spec(_ about: String) -> String { days.replacingOccurrences(of: "%@", with: about) }

    // D1. a person asks
    var r = h.run(["chat", "ask", "askroom", "Which day suits?", "--option", "mon=Monday", "--option", "tue=Tuesday", "--decider", "decbot"], timeout: 60)
    let asked = r.out.range(of: #"#\d+"#, options: .regularExpression).map { String(r.out[$0]) } ?? ""
    check(r.code == 0 && r.out.hasPrefix("Asked #") && r.out.contains("in askroom; deciders: decbot."), "D1 doz chat ask (\(r.code) \(r.out) \(r.err.prefix(160)))")
    r = h.run(["chat", "asks"])
    check(r.code == 0 && r.out.contains("\(asked) askroom ada") && r.out.contains("Which day suits? (decbot; expires in"), "D1 doz chat asks lists it (\(r.out.prefix(300)))")
    r = h.run(["chat", "asks", "askroom", "--json"])
    let listed = ((try? JSONSerialization.jsonObject(with: Data(r.out.utf8))) as? [String: Any])?["asks"] as? [[String: Any]] ?? []
    check(listed.contains { $0["number"] as? Int == Int(asked.dropFirst()) && $0["deciders"] as? [String] == ["decbot"] }, "D1 …and --json")

    // D2. withdrawn by a bare number
    r = h.run(["chat", "withdraw", "askroom", String(asked.dropFirst())], timeout: 60)
    check(r.code == 0 && r.out == "Withdrew \(asked) in askroom.\n", "D2 doz chat withdraw R N (\(r.code) \(r.out) \(r.err.prefix(160)))")

    // D4. a bot's ask answered by letter; its asker is told
    n = botAsk(plain, spec("4"))
    r = h.run(["chat", "decide", "askroom", "#\(n)", "B"], timeout: 60)
    check(r.code == 0 && r.out == "Answered #\(n): B. Next (decided by you).\n", "D4 doz chat decide R #N B (\(r.code) \(r.out) \(r.err.prefix(160)))")
    let got = agent(plain, "GET", "/agent/receive?wait=5").1
    var told = false
    if case .array(let items)? = got?.field("messages") { told = items.contains { $0.field("event")?.stringValue == "ask-outcome" && $0.field("option") == .string("next") } }
    check(told, "D4 …the asker's receive has ask-outcome")

    // D5. by label, by words, declined with a reason
    n = botAsk(plain, spec("5a"))
    r = h.run(["chat", "decide", "askroom", "\(n)", "now"], timeout: 60)
    check(r.code == 0 && r.out.contains(": A. Now (decided by you)"), "D5 by its id (\(r.out) \(r.err.prefix(120)))")
    n = botAsk(plain, #"{"questions":[{"options":[{"id":"a1","label":"Ship it"}]}],"about":{"d":"5b"}}"#)
    r = h.run(["chat", "decide", "askroom", "#\(n)", "ship", "it"], timeout: 60)
    check(r.code == 0 && r.out.contains(": A. Ship it (decided by you)"), "D5 by its label (\(r.out) \(r.err.prefix(120)))")
    n = botAsk(plain, spec("5c"))
    r = h.run(["chat", "decide", "askroom", "#\(n)", "after", "lunch"], timeout: 60)
    check(r.code == 0 && r.out.contains(": \u{201C}after lunch\u{201D} (decided by you)"), "D5 in words (\(r.out) \(r.err.prefix(120)))")
    n = botAsk(plain, spec("5d"))
    r = h.run(["chat", "decide", "askroom", "#\(n)", "--decline", "not now"], timeout: 60)
    check(r.code == 0 && r.out.contains(": declined: not now (decided by you)"), "D5 --decline \"not now\" (\(r.out) \(r.err.prefix(120)))")

    // D6. refusals in Dozable's words
    n = botAsk(plain, spec("6a"))
    _ = h.run(["chat", "decide", "askroom", "#\(n)", "A"], timeout: 60)
    r = h.run(["chat", "decide", "askroom", "#\(n)", "B"], timeout: 60)
    check(r.code == 3 && r.err == "doz: It was already answered: decided by Ada.\n", "D6 answered (\(r.code) \(r.err))")
    r = h.run(["chat", "decide", "askroom", "#\(n)", "B", "--json"], timeout: 60)
    let answeredErr = ((try? JSONSerialization.jsonObject(with: r.outData)) as? [String: Any])?["error"] as? [String: Any]
    check(r.code == 3 && answeredErr?["code"] as? String == "already-answered" && answeredErr?["exit"] as? Int == 3,
          "D6 …and --json: error code already-answered, exit 3 (\(r.code) \(r.out.prefix(200)))")
    let soon = ISO8601DateFormatter().string(from: Date().addingTimeInterval(2))
    n = botAsk(plain, #"{"questions":[{"options":[{"id":"a1"}]}],"about":{"d":"6b"},"expires_at":"\#(soon)"}"#)
    usleep(3_000_000)
    r = h.run(["chat", "decide", "askroom", "#\(n)", "A"], timeout: 60)
    check(r.code == 3 && r.err == "doz: This ask expired: its answer was decline.\n", "D6 expired (\(r.code) \(r.err))")
    n = botAsk(plain, spec("6c"))
    _ = agent(plain, "POST", "/agent/withdraw", "{\"room\":\"askroom\",\"ask_id\":\"#\(n)\"}")
    r = h.run(["chat", "decide", "askroom", "#\(n)", "A"], timeout: 60)
    check(r.code == 3 && r.err == "doz: It was withdrawn by the one who asked it.\n", "D6 withdrawn (\(r.code) \(r.err))")
    n = botAsk(plain, #"{"questions":[{"options":[{"id":"a1"}]}],"about":{"d":"6d"},"deciders":["decbot"]}"#)
    r = h.run(["chat", "decide", "askroom", "#\(n)", "A"], timeout: 60)
    check(r.code == 3 && r.err == "doz: You are not one of this ask's deciders (only Decbot is).\n", "D6 not a decider (\(r.code) \(r.err))")
    _ = agent(plain, "POST", "/agent/withdraw", "{\"room\":\"askroom\",\"ask_id\":\"#\(n)\"}")
    r = h.run(["chat", "ask", "askroom", "Lunch?", "--decider", "decbot"], timeout: 60)
    let mine = r.out.range(of: #"#\d+"#, options: .regularExpression).map { String(r.out[$0]) } ?? "#0"
    r = h.run(["chat", "decide", "askroom", mine, "yes"], timeout: 60)
    check(r.code == 3 && r.err == "doz: You asked this: the one who asks cannot answer it.\n", "D6 the asker (\(r.code) \(r.err))")
    _ = h.run(["chat", "withdraw", "askroom", mine], timeout: 60)

    // D10. an agent never answers through the daemon
    let open = h.run(["chat", "asks", "wsask", "--json"]).out
    let wsAsk = (((try? JSONSerialization.jsonObject(with: Data(open.utf8))) as? [String: Any])?["asks"] as? [[String: Any]])?.first?["number"] as? Int ?? 0
    check(wsAsk > 0, "D10 wsask has askbot's open ask (\(open.prefix(160)))")
    r = h.run(["chat", "decide", "wsask", "#\(wsAsk)", "A", "--as", "wsask/plainbot"], timeout: 60)
    check(r.code == 9 && r.err.contains("chat.decide for plainbot in wsask"), "D10 no role: the gate refuses citing chat.decide (\(r.code) \(r.err.prefix(200)))")
    var pid = server()
    _ = h.run(["chat", "set", "plainbot", "--role", "decider"], timeout: 60)
    restarted(from: pid, "D10 plainbot a decider")
    r = h.run(["chat", "decide", "wsask", "#\(wsAsk)", "A", "--as", "wsask/plainbot"], timeout: 60)
    check(r.code == 9 && r.err.contains("Dozable never speaks for an agent: it asks and answers with its own token"), "D10 with the role: with its own token (\(r.code) \(r.err.prefix(200)))")
    pid = server()
    _ = h.run(["chat", "set", "plainbot", "--role", "none"], timeout: 60)
    restarted(from: pid, "D10 plainbot's role taken away")

    // D11. chat off; asks off
    pid = server()
    _ = h.run(["config", "set", "chat.asks", "false"])
    restarted(from: pid, "D11 chat.asks false")
    r = h.run(["chat", "ask", "askroom", "Anything?"], timeout: 60)
    check(r.code == 1 && r.err == "doz: Asks are off on this Mac's chat server (the setting chat.asks).\n", "D11 asks off (\(r.code) \(r.err))")
    pid = server()
    _ = h.run(["config", "set", "chat.asks", "true"])
    restarted(from: pid, "D11 chat.asks true")
    _ = h.run(["chat", "off"], timeout: 30)
    r = h.run(["chat", "asks"])
    let r2 = h.run(["chat", "decide", "askroom", "#1", "A"], timeout: 30)
    check(r.code == 6 && r2.code == 6 && r.err.contains("chat is off"), "D11 chat off: exit 6 (\(r.code) \(r2.code) \(r.err))")
    _ = h.run(["chat", "on"], timeout: 60)
    check(h.waitFor(20) { supervisor()?.ready == true }, "D11 chat on again")

    // D12. a finished workspace's room
    r = h.run(["workspace", "finish", "wsask", "--yes"], timeout: 180)
    check(r.code == 0, "D12 finish wsask (\(r.code) \(r.err.prefix(160)))")
    r = h.run(["chat", "ask", "wsask", "Still there?"], timeout: 60)
    check(r.code == 3 && r.err == "doz: Its room is closed: it can still be read, but nothing is asked or answered there.\n", "D12 its room is closed (\(r.code) \(r.err))")
    r = h.run(["workspace", "reopen", "wsask", "--no-start"], timeout: 60)
    check(r.code == 0, "D12 reopen (\(r.code) \(r.err.prefix(160)))")
    _ = asker
}
