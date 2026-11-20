import Foundation

// What every client of asks shares — `doz chat`, the daemon's ask operations, the dashboard's card and the space diagram:
// an ask read back from a message, a person's words turned into a decision (`ChatAskReply`), a refusal told in Dozable's
// words (`ChatAskRefusal`) and who may answer one (`ChatAskViewer`). Pure: no transport, no lock. The server's own side is
// ChatAsk.swift and ChatAsks.swift. docs/engineering/chat.md, "Asks".

extension ChatAsk {
    /// The ask of a message as the server returns it (`message.ask`: its shape, state and decision), normalised; nil when
    /// the message is not an ask or its ask cannot be read.
    public static func read(message m: JValue) -> ChatAsk? {
        guard m.field("kind")?.stringValue == "ask", let v = m.field("ask"), v.isObject else { return nil }
        guard var a = readStored(ChatJSON.encodeString(v)) else { return nil }
        a.state = v.field("state")?.stringValue ?? "open"
        if a.state.isEmpty { a.state = "open" }
        a.closedAt = v.field("closed_at")?.doubleValue ?? 0
        a.noDecider = v.field("no_decider")?.boolValue ?? false
        if let d = v.field("decision"), d.isObject { a.decision = ChatAskDecision.read(d) }
        a.normalise()
        guard !a.questions.isEmpty else { return nil }
        return a
    }

    /// `#N` when it has a number, else the first 8 of its msg_id.
    public static func label(number: Int, msgID: String) -> String { number > 0 ? "#\(number)" : String(msgID.prefix(8)) }

    /// Whether one string answers it: one question, not several options at once.
    public var answerableWithOneString: Bool { questions.count == 1 && !questions[0].multi }

    /// The title a list shows: the first line of the question.
    public var title: String { ChatAskForm.clipLine(question.split(separator: "\n").first.map(String.init) ?? question, 120) }

    /// The letter of option `k` (A for the first).
    public static func letter(_ k: Int) -> String { ChatAskForm.letter(k) }
}

/// A client's name for an ask, the way a person types it: `#12`, a bare `12` (made `#12` — in clients only: the server
/// reads a bare number as the start of a msg_id), or the start of its msg_id.
public enum ChatAskRef {
    public static func normalise(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty, t.utf8.count <= 9, t.allSatisfy(\.isASCII), t.allSatisfy(\.isNumber) { return "#" + t }
        return t
    }

    /// `#N` (N ≥ 1) or 1 to 36 hex digits and dashes (a msg_id or its start).
    public static func isValid(_ s: String) -> Bool {
        if s.hasPrefix("#") { return Int(s.dropFirst()).map { $0 > 0 && s.utf8.count <= 10 } ?? false }
        let u = Array(s.utf8)
        guard (1...36).contains(u.count) else { return false }
        return u.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) || $0 == 0x2D }
    }
}

/// A person's words turned into a decision, for an ask of one question taking one option or words — the CLI's
/// `doz chat decide R #N WORDS`, the card's free-text field and the space diagram's reply. In order: an option's id, its
/// letter (A to J, either case), its label (the whole words, ignoring case), `decline` (any words after it are the reason),
/// then the words as a free-text answer when the question takes one. Several questions, or a question that takes several
/// options, need `answers`.
public enum ChatAskReply {
    public static func resolve(_ a: ChatAsk, words raw: String) -> Result<ChatDecideInput, ChatAskRefusal> {
        let words = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = words.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).first.map(String.init) else {
            return .failure(.init(.badAnswer, "Say your answer: an option, its letter, its label, your own words, or decline."))
        }
        let rest = words.dropFirst(first.count).trimmingCharacters(in: .whitespacesAndNewlines)
        func decline() -> Result<ChatDecideInput, ChatAskRefusal> { .success(ChatDecideInput(text: rest, decline: true)) }
        guard a.questions.count == 1, let q = a.questions.first, !q.multi else {
            if first.lowercased() == "decline" { return decline() }
            let why = a.questions.count > 1 ? "This ask has \(a.questions.count) questions" : "This question takes several options"
            return .failure(.init(.badAnswer, why + ": answer it with --answers (one answer for each question) or on the card in this Mac's browser."))
        }
        func pick(_ o: ChatAskOption, _ text: String) -> Result<ChatDecideInput, ChatAskRefusal> {
            .success(ChatDecideInput(answers: [ChatAnswerIn(questionID: q.id, options: [o.id], text: text)]))
        }
        if let o = q.option(first) { return pick(o, rest) }
        if first.count == 1, let c = first.uppercased().unicodeScalars.first, (65...74).contains(c.value), Int(c.value) - 65 < q.options.count {
            return pick(q.options[Int(c.value) - 65], rest)
        }
        if let o = q.options.first(where: { $0.label.caseInsensitiveCompare(words) == .orderedSame }) { return pick(o, "") }
        if first.lowercased() == "decline" { return decline() }
        if q.freeText || q.options.isEmpty { return .success(ChatDecideInput(answers: [ChatAnswerIn(questionID: q.id, text: words)])) }
        return .failure(.init(.badAnswer, "\u{201C}\(ChatAskForm.clipLine(words, 60))\u{201D} is not one of this ask's options: \(optionList(q)), or decline."))
    }

    /// "A. Yes, B. No".
    public static func optionList(_ q: ChatAskQuestion) -> String {
        q.options.enumerated().map { "\(ChatAskForm.letter($0.offset)). \($0.element.label.isEmpty ? $0.element.id : $0.element.label)" }.joined(separator: ", ")
    }

    /// How a decision reads in one line: "B. Next", "declined", "declined: not now", or the answers in short.
    public static func summary(_ a: ChatAsk, _ d: ChatAskDecision) -> String {
        if d.declined || d.option == "decline" { return d.text.isEmpty ? "declined" : "declined: \(ChatAskForm.clipLine(d.text, 80))" }
        let answers = d.answers ?? []
        if a.questions.count == 1, answers.count == 1, let q = a.questions.first {
            let ans = answers[0]
            var s = ans.options.compactMap { id in q.options.firstIndex { $0.id == id }.map { "\(ChatAskForm.letter($0)). \(q.options[$0].label)" } }
                .joined(separator: ", ")
            if !ans.text.isEmpty { s += (s.isEmpty ? "" : " ") + "\u{201C}\(ChatAskForm.clipLine(ans.text, 80))\u{201D}" }
            return s
        }
        return ChatAskForm.clipLine(ChatAskForm.summary(a, answers, sep: "; "), 160)
    }
}

/// A refused decide, withdraw or ask, in Dozable's words. The ask's state as read AFTER the refusal decides which (it
/// was answered, it expired, it was withdrawn); then what the server said; its own detail is only the fallback.
public struct ChatAskRefusal: Error, Equatable, Sendable {
    public enum Code: String, Sendable, Codable {
        case expired, answered, withdrawn, notAnAnswerer = "not-an-answerer", asker, roomClosed = "room-closed"
        case asksOff = "asks-off", badAnswer = "bad-answer", macOnly = "mac-only"
    }
    public var code: Code
    public var words: String

    public init(_ code: Code, _ words: String) { self.code = code; self.words = words }

    /// Another computer's answer, before any request: asks are answered in this Mac's own browser.
    public static let macOnly = ChatAskRefusal(.macOnly, "Asks are answered in this Mac's own browser for now.")

    /// `detail`: the server's own words; `ask`: the ask as read after the refusal (nil: not read).
    public static func classify(detail: String, ask: ChatAsk?) -> ChatAskRefusal {
        if detail == ChatServerCore.askOff {
            return .init(.asksOff, "Asks are off on this Mac's chat server (the setting chat.asks).")
        }
        if let a = ask {
            switch a.state {
            case "expired":
                if a.decision?.declined == true || !a.onExpiry.isEmpty { return .init(.expired, "This ask expired: its answer was decline.") }
                return .init(.expired, "This ask expired.")
            case "decided":
                let by = a.decision.map { capitalFirst($0.by) + ($0.deciderRole ? " (decider role)" : "") } ?? "someone"
                return .init(.answered, "It was already answered: decided by \(by).")
            case "withdrawn":
                return .init(.withdrawn, "It was withdrawn by the one who asked it.")
            default: break
            }
        }
        if detail.contains(" is closed") || detail.contains(" is archived") {
            return .init(.roomClosed, "Its room is closed: it can still be read, but nothing is asked or answered there.")
        }
        if detail.hasPrefix("the asker cannot decide") { return .init(.asker, "You asked this: the one who asks cannot answer it.") }
        if detail.hasPrefix("only ") && detail.contains("can withdraw") { return .init(.notAnAnswerer, "Only the one who asked it can withdraw it.") }
        if detail.contains("is not a decider of this ask") || detail.contains("does not have the decider role") {
            let only = (ask?.deciders ?? []).map(capitalFirst)
            let tail = only.isEmpty ? "" : " (only \(only.joined(separator: ", ")) \(only.count == 1 ? "is" : "are"))"
            return .init(.notAnAnswerer, "You are not one of this ask's deciders\(tail).")
        }
        if detail.hasPrefix("this ask has expired") { return .init(.expired, "This ask expired.") }
        if detail.hasPrefix("this ask was already decided") { return .init(.answered, "It was already answered.") }
        if detail.hasPrefix("this ask was withdrawn") { return .init(.withdrawn, "It was withdrawn by the one who asked it.") }
        return .init(.badAnswer, detail.isEmpty ? "The chat server refused it." : capitalFirst(detail) + (detail.hasSuffix(".") ? "" : "."))
    }
}

/// Who may answer an ask where they look at it.
public enum ChatAskViewer {
    /// `viewer` may answer: the ask is open, someone is left to decide, the viewer is one of its deciders and did not ask it.
    public static func canAnswer(_ a: ChatAsk, viewer: String, asker: String) -> Bool {
        a.state == "open" && !a.noDecider && a.deciders.contains(viewer) && viewer != asker
    }

    /// Why a viewer cannot (nil: they can), in one line.
    public static func readOnlyLine(_ a: ChatAsk, viewer: String, asker: String) -> String? {
        if canAnswer(a, viewer: viewer, asker: asker) { return nil }
        if a.state != "open" { return nil }
        if a.noDecider { return "No decider is left: it expires to decline." }
        if viewer == asker { return "You asked this." }
        let only = a.deciders.map(capitalFirst)
        return "Only \(only.joined(separator: ", ")) can answer."
    }
}
