import ArgumentParser
import Darwin
import DozableChat
import DozableHost
import Foundation

// `doz chat ask | decide | withdraw | asks` — asks for a person, as you. Each change is the daemon's HostOp (`chat-ask`,
// `chat-decide`, `chat-withdraw`: one fixed call on the chat server's owner's socket, `HostCore+ChatAsks`), the same one
// the dashboard's card sends; `asks` and `ask --wait` read on your socket. An ask is named `#N`, a bare `N` (made `#N`
// here), or the start of its id. A refusal is told in Dozable's words, exit 1; chat off, exit 6. An agent asks and
// answers with its own token (dozchat ask | decide | withdraw), never through doz. docs/engineering/chat.md, "Asks".

func chatAskRequest(_ op: HostOp, _ q: ChatAskRequest) -> HostRequest {
    var r = HostRequest(op)
    r.chatAsk = q
    return r
}

/// Chat must be on (exit 6 otherwise) — checked before the daemon is asked.
func chatAsksNeedChat(_ g: GlobalOptions) throws {
    guard ChatSettingsView.read().enabled else { throw fail(HostError(.unavailable, "chat is off — doz chat on"), g) }
}

/// `--expires`: `30m`, `2h`, `1d` from now, or a time (ISO 8601, Unix seconds) — as RFC 3339 in UTC.
func chatAskExpiry(_ s: String, now: Date = Date()) -> String? {
    let t = s.trimmingCharacters(in: .whitespaces)
    var at: Double?
    if let last = t.last, "smhd".contains(last), let n = Double(t.dropLast()), n > 0, t.dropLast().allSatisfy({ $0.isNumber || $0 == "." }) {
        let unit: Double = last == "s" ? 1 : last == "m" ? 60 : last == "h" ? 3600 : 86_400
        at = now.timeIntervalSince1970 + n * unit
    } else if let x = ChatTime.parse(t, now: now), x > now.timeIntervalSince1970 {
        at = x
    }
    guard let at else { return nil }
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f.string(from: Date(timeIntervalSince1970: at.rounded(.up)))
}

/// "in 2 h", "in 5 min" — what is left.
func chatAskLeft(_ expiresAt: String?, now: Date = Date()) -> String? {
    guard let e = expiresAt, let at = ChatTime.parse(e) else { return nil }
    let s = max(0, Int(at - now.timeIntervalSince1970))
    if s >= 86_400 { return "in \(s / 86_400) d" }
    if s >= 3600 { return "in \(s / 3600) h" }
    if s >= 60 { return "in \(s / 60) min" }
    return "in \(s) s"
}

func chatAskAge(_ at: Double, now: Date = Date()) -> String {
    let s = max(0, Int(now.timeIntervalSince1970 - at))
    if s >= 86_400 { return "\(s / 86_400)d" }
    if s >= 3600 { return "\(s / 3600)h" }
    if s >= 60 { return "\(s / 60)m" }
    return "\(s)s"
}

struct ChatAskCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ask", abstract: "Ask a question in a room, as you, for deciders to answer.",
        discussion: """
            The question is the rest of the line. Options: --option ID=LABEL (or ID=LABEL::DESCRIPTION), once for each; \
            without one the answer is in words. Every ask can be declined, and it expires (24 hours unless --expires) to \
            decline. Deciders: --decider NAME, once for each (a person, or an Agent / Bot you gave the decider role with \
            doz chat set NAME --role decider); none named: the room's people. --questions FILE (or -) holds a JSON array of \
            questions for an ask of several; the question is then its title. --wait waits for the outcome: exit 0 decided, \
            10 declined, 11 expired, 12 withdrawn, 1 refused.
            """)
    @Argument(help: "The room.") var room: String
    @Argument(help: "The question.") var question: [String] = []
    @Option(name: .customLong("option"), help: "An option: ID=LABEL, ID=LABEL::DESCRIPTION or ID; once for each.") var options: [String] = []
    @Flag(name: .long, help: "The decider may pick several options.") var multi = false
    @Option(name: .long, help: "With --multi: the fewest to pick.") var min: Int?
    @Option(name: .long, help: "With --multi: the most to pick.") var max: Int?
    @Flag(name: .customLong("no-free-text"), help: "Options only: no answer in the decider's own words.") var noFreeText = false
    @Option(name: .customLong("decider"), help: "Who decides; once for each (default: the room's people).") var deciders: [String] = []
    @Option(name: .long, help: "Why you ask; shown with the question.") var reason: String?
    @Option(name: .long, help: "When it expires: 30m, 2h, 1d from now, or a time.") var expires: String?
    @Option(name: .long, help: "What it is about, as a JSON object (at most 4 KiB).") var about: String?
    @Option(name: .long, help: "A JSON file (or -) holding an array of questions.") var questions: String?
    @Flag(name: .long, help: "Wait for the outcome (exit 0 decided, 10 declined, 11 expired, 12 withdrawn).") var wait = false
    @OptionGroup var g: GlobalOptions

    func spec() throws -> JSONValue {
        var o: [String: JSONValue] = [:]
        if let questions {
            if !options.isEmpty || multi || min != nil || max != nil || noFreeText {
                throw ValidationError("--questions holds every question: give --option, --multi, --min, --max and --no-free-text in the file")
            }
            let data = questions == "-" ? FileHandle.standardInput.readDataToEndOfFile() : (FileManager.default.contents(atPath: questions) ?? Data())
            guard data.count <= 64 * 1024, let v = try? JSONDecoder().decode(JSONValue.self, from: data), case .array = v else {
                throw ValidationError("--questions must hold a JSON array of questions (at most 64 KiB)")
            }
            o["questions"] = v
        } else {
            var q: [String: JSONValue] = [:]
            if !options.isEmpty {
                q["options"] = .array(options.map { raw in
                    let parts = raw.split(separator: "=", maxSplits: 1).map(String.init)
                    let rest = parts.count > 1 ? parts[1] : ""
                    let ld = rest.components(separatedBy: "::")
                    var m: [String: JSONValue] = ["id": .string(parts.first ?? ""), "label": .string(ld[0])]
                    if ld.count > 1 { m["description"] = .string(ld.dropFirst().joined(separator: "::")) }
                    return .object(m)
                })
            }
            if multi { q["multi"] = .bool(true) }
            if let min { q["min"] = .number(Double(min)) }
            if let max { q["max"] = .number(Double(max)) }
            if noFreeText { q["free_text"] = .bool(false) }
            o["questions"] = .array([.object(q)])
        }
        if !deciders.isEmpty { o["deciders"] = .array(deciders.map { .string($0.hasPrefix("@") ? String($0.dropFirst()) : $0) }) }
        if let reason { o["reason"] = .string(reason) }
        if let expires {
            guard let e = chatAskExpiry(expires) else { throw ValidationError("--expires \(expires): 30m, 2h, 1d from now, or a time to come") }
            o["expires_at"] = .string(e)
        }
        if let about {
            guard let v = try? JSONDecoder().decode(JSONValue.self, from: Data(about.utf8)), case .object = v else {
                throw ValidationError("--about must be a JSON object")
            }
            o["about"] = v
        }
        return .object(o)
    }

    func run() async throws {
        try requireRoomName(room, g)
        let text = question.joined(separator: " ")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw fail(HostError(.invalid, "say the question"), g) }
        let spec = try spec()
        try chatAsksNeedChat(g)
        var q = ChatAskRequest(room: room)
        q.question = text
        q.spec = spec
        q.actionID = UUID().uuidString.lowercased()
        let o = try decode(try call(chatAskRequest(.chatAsk, q), g), ChatAskOutcome.self, g)
        if !wait {
            if g.json { Out.json(o); return }
            Out.stdout("Asked \(o.ask) in \(room); deciders: \((o.deciders ?? []).joined(separator: ", ")).\n")
            return
        }
        if !g.json { Out.stdout("Asked \(o.ask) in \(room); deciders: \((o.deciders ?? []).joined(separator: ", ")). Waiting for the outcome…\n") }
        try await chatAskWait(room: room, ref: o.msgId, g)
    }
}

/// Waits until the ask is not open, says how it ended and exits with its code: 0 decided, 10 declined, 11 expired,
/// 12 withdrawn.
func chatAskWait(room: String, ref: String, _ g: GlobalOptions) async throws -> Never {
    let c = try chatOwner(g)
    var fails = 0
    while true {
        let (status, m) = try chatAsk(c, "GET", "/agent/asks/\(ref.replacingOccurrences(of: "#", with: "%23"))?room=\(room)", g)
        if status == 200, let a = ChatAsk.read(message: m), a.state != "open" {
            let id = m.field("msg_id")?.stringValue ?? ref
            let label = ChatAsk.label(number: a.number, msgID: id)
            let declined = a.decision?.declined == true || a.decision?.option == "decline"
            if g.json { Out.stdout(ChatJSON.encodeString(m) + "\n") }
            switch a.state {
            case "decided":
                if !g.json { Out.stdout("\(label): \(a.decision.map { ChatAskReply.summary(a, $0) } ?? "decided") (decided by \(a.decision?.by ?? "?")).\n") }
                Darwin.exit(declined ? 10 : 0)
            case "expired":
                if !g.json { Out.stdout("\(label) expired: its answer was decline.\n") }
                Darwin.exit(11)
            default:
                if !g.json { Out.stdout("\(label) was withdrawn.\n") }
                Darwin.exit(12)
            }
        }
        if status != 200 {
            fails += 1
            if fails > 30 { throw fail(HostError(.failed, "cannot read the ask (\(status))"), g) }
        } else { fails = 0 }
        try await Task.sleep(for: .seconds(1))
    }
}

struct ChatDecideCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "decide", abstract: "Answer an ask, as you.",
        discussion: """
            ASK is #N (or N), or the start of its id (doz chat asks). The answer: an option's id, its letter (A for the \
            first) or its label, with words of your own after it if the question takes them; your answer in words; or \
            decline (--decline), with your reason. An ask of several questions, or one that takes several options, is \
            answered with --answers '[{"question_id":"q1","options":["web"],"text":"…"}]' (or - to read it from standard \
            input). A refusal says why, exit 1.
            """)
    @Argument(help: "The room.") var room: String
    @Argument(help: "The ask: #N, N, or the start of its id.") var ask: String
    @Argument(help: "Your answer.") var answer: [String] = []
    @Option(name: .long, help: "Words with the option, or your reason with --decline.") var text: String?
    @Flag(name: .long, help: "Decline it.") var decline = false
    @Option(name: .long, help: "The answers as JSON (or -), one for each question.") var answers: String?
    @OptionGroup var g: GlobalOptions

    func request() throws -> ChatAskRequest {
        var q = ChatAskRequest(room: room, ask: ChatAskRef.normalise(ask))
        q.actionID = UUID().uuidString.lowercased()
        let words = answer.joined(separator: " ")
        if decline {
            if answers != nil { throw ValidationError("--decline, or --answers: not both") }
            q.decline = true
            q.text = [words, text ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
        } else if let answers {
            if !words.isEmpty || text != nil { throw ValidationError("with --answers, give the words in each answer's text") }
            let data = answers == "-" ? FileHandle.standardInput.readDataToEndOfFile() : Data(answers.utf8)
            struct In: Decodable { var question_id: String; var options: [String]?; var text: String?; var skipped: Bool? }
            guard data.count <= 64 * 1024, let list = try? JSONDecoder().decode([In].self, from: data) else {
                throw ValidationError(#"--answers must be a JSON array: [{"question_id":"q1","options":["web"],"text":"…"}]"#)
            }
            q.answers = list.map { ChatAskAnswerItem(questionId: $0.question_id, options: $0.options, text: $0.text, skipped: $0.skipped) }
        } else {
            guard !words.isEmpty else { throw ValidationError("say your answer: an option, its letter or label, your own words, or --decline") }
            q.reply = [words, text ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
        }
        return q
    }

    func run() async throws {
        try requireRoomName(room, g)
        let q = try request()
        guard ChatAskRef.isValid(q.ask ?? "") else { throw fail(HostError(.invalid, "\(ask): which ask? #N, or the start of its id (doz chat asks)"), g) }
        try chatAsksNeedChat(g)
        let o = try decode(try call(chatAskRequest(.chatDecide, q), g), ChatAskOutcome.self, g)
        if g.json { Out.json(o); return }
        if o.state == "duplicate" { Out.stdout("\(o.ask) was answered already by this request.\n"); return }
        let by = o.decidedBy.map { $0 == chatYou(g) ? "you" : $0 } ?? "you"
        Out.stdout("Answered \(o.ask): \(o.summary ?? "decided") (decided by \(by)).\n")
    }
}

/// Your name in chat (nil: not known).
func chatYou(_ g: GlobalOptions) -> String? {
    (try? ChatDirectory.load(ChatPaths(store: g.dozableStore)))?.human
}

struct ChatWithdrawCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "withdraw", abstract: "Withdraw an ask you asked.",
        discussion: "It closes with no decision. ASK is #N (or N), or the start of its id.")
    @Argument(help: "The room.") var room: String
    @Argument(help: "The ask: #N, N, or the start of its id.") var ask: String
    @OptionGroup var g: GlobalOptions
    func run() async throws {
        try requireRoomName(room, g)
        var q = ChatAskRequest(room: room, ask: ChatAskRef.normalise(ask))
        guard ChatAskRef.isValid(q.ask ?? "") else { throw fail(HostError(.invalid, "\(ask): which ask? #N, or the start of its id (doz chat asks)"), g) }
        q.actionID = UUID().uuidString.lowercased()
        try chatAsksNeedChat(g)
        let o = try decode(try call(chatAskRequest(.chatWithdraw, q), g), ChatAskOutcome.self, g)
        if g.json { Out.json(o); return }
        Out.stdout("Withdrew \(o.ask) in \(room).\n")
    }
}

struct ChatAsksCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "asks", abstract: "The open asks of your rooms.",
        discussion: "One line each: #N, the room, who asked, how long ago, the question, its deciders and when it expires. The chat server runs while the daemon does: with no daemon this is refused, and nothing starts one.")
    @Argument(help: "Only this room.") var room: String?
    @OptionGroup var g: GlobalOptions
    func run() async throws {
        if let room { try requireRoomName(room, g) }
        try chatAsksNeedChat(g)
        try chatNeedsDaemon(g)
        let l = try decode(try call(chatAskRequest(.chatAsks, ChatAskRequest(room: room)), g, autostart: false), ChatAsksListing.self, g)
        if g.json { Out.json(l); return }
        if l.asks.isEmpty { Out.stdout(room.map { "no open ask in \($0)\n" } ?? "no open ask\n"); return }
        for a in l.asks {
            let left = chatAskLeft(a.expiresAt).map { "; expires \($0)" } ?? ""
            let who = a.noDecider == true ? "no decider left" : a.deciders.joined(separator: ", ")
            Out.stdout("\(a.label) \(a.room) \(a.from) \(chatAskAge(a.at)) \(a.title) (\(who)\(left))\n")
        }
    }
}

/// The line `doz chat read` shows above an ask's text: "ask #N · open | decided by X | expired | withdrawn".
func chatAskMark(_ m: JValue) -> String? {
    guard let a = ChatAsk.read(message: m) else { return nil }
    let label = ChatAsk.label(number: a.number, msgID: m.field("msg_id")?.stringValue ?? "")
    let state: String
    switch a.state {
    // 775: decided in the terminal (`doz workspace decide`): applied or declined, said so — never "withdrawn".
    case "decided" where a.decision?.via == ChatServerCore.decidedElsewhereVia:
        state = (a.decision?.declined == true ? "declined" : "applied") + " with doz workspace decide"
    case "decided": state = "decided by \(a.decision?.by ?? "?")" + (a.decision?.deciderRole == true ? " (decider role)" : "")
    case "expired": state = "expired"
    case "withdrawn": state = "withdrawn"
    default: state = a.noDecider ? "open · no decider left" : "open"
    }
    return "ask \(label) · \(state)"
}
