import CryptoKit
import Darwin
import Foundation

// The shape of an ask (the protocol's section 13, "ask v3"): an ask puts 1 to 5 questions, each with 0 to 8 options,
// single or multiple choice and free text by default, to named deciders, and waits for a decision. Declining is
// ask-level and always possible. Here: the shapes as stored and returned, how a posted ask is checked and normalised
// (the reference's words, in its order), how an ask stored by the reference's 0.15 reads in the same shape, how a
// decision is checked, the digest, and the plain text a client that does not know asks reads. Transport- and lock-free:
// the server's side of asks is ChatAsks.swift.
//
// Dozable's one addition to the shape: `number`, a short number per Mac (`#12`), kept in the stored ask's JSON (a key the
// reference ignores) and in every ask object returned; it is not in the digest.

public struct ChatAskOption: Sendable, Equatable {
    public var id: String
    public var label: String
    public var description = ""

    public init(id: String, label: String, description: String = "") { self.id = id; self.label = label; self.description = description }

    var json: JValue {
        var o = JObject()
        o.add("id", .string(id)); o.add("label", .string(label)); o.omitEmpty("description", description)
        return o.value
    }

    static func read(_ v: JValue, _ what: String) throws -> ChatAskOption {
        guard v.isObject || v.isNull else { throw ChatFieldError(description: "\(what): not an object") }
        return ChatAskOption(id: try v.field("id")?.goString(what + ".id") ?? "", label: try v.field("label")?.goString(what + ".label") ?? "",
                             description: try v.field("description")?.goString(what + ".description") ?? "")
    }
}

/// One question as stored and returned: every field filled in.
public struct ChatAskQuestion: Sendable, Equatable {
    public var id = ""
    public var header = ""
    public var question = ""
    public var options: [ChatAskOption] = []
    public var multi = false
    public var min = 0
    public var max = 0
    public var freeText = false
    public var recommended = ""
    public var optional = false

    public init() {}

    func option(_ id: String) -> ChatAskOption? { options.first { $0.id == id } }
    var optionIDs: String { options.map(\.id).joined(separator: ", ") }

    var json: JValue {
        var o = JObject()
        o.add("id", .string(id)); o.omitEmpty("header", header); o.add("question", .string(question))
        o.add("options", .array(options.map(\.json))); o.add("multi", .bool(multi)); o.add("min", .int(Int64(min)))
        o.add("max", .int(Int64(max))); o.add("free_text", .bool(freeText)); o.omitEmpty("recommended", recommended)
        o.add("optional", .bool(optional))
        return o.value
    }

    static func read(_ v: JValue) -> ChatAskQuestion {
        var q = ChatAskQuestion()
        func s(_ k: String) -> String { v.field(k)?.stringValue ?? "" }
        func b(_ k: String) -> Bool { v.field(k)?.boolValue ?? false }
        func n(_ k: String) -> Int { ((try? v.field(k)?.goInt(k)) ?? nil) ?? 0 }
        q.id = s("id"); q.header = s("header"); q.question = s("question")
        if case .array(let a)? = v.field("options") { q.options = a.compactMap { try? ChatAskOption.read($0, "option") } }
        q.multi = b("multi"); q.min = n("min"); q.max = n("max"); q.freeText = b("free_text"); q.recommended = s("recommended")
        q.optional = b("optional")
        return q
    }
}

/// A decider's answer to one question; `skipped` for an optional question skipped.
public struct ChatAskAnswer: Sendable, Equatable {
    public var questionID: String
    public var options: [String] = []
    public var labels: [String] = []
    public var text = ""
    public var skipped = false

    var json: JValue {
        var o = JObject()
        o.add("question_id", .string(questionID)); o.add("options", .strings(options)); o.add("labels", .strings(labels))
        o.omitEmpty("text", text); o.omitEmpty("skipped", skipped)
        return o.value
    }

    static func read(_ v: JValue) -> ChatAskAnswer {
        ChatAskAnswer(questionID: v.field("question_id")?.stringValue ?? "", options: ((try? v.field("options")?.goStrings("options")) ?? nil) ?? [],
                      labels: ((try? v.field("labels")?.goStrings("labels")) ?? nil) ?? [], text: v.field("text")?.stringValue ?? "",
                      skipped: v.field("skipped")?.boolValue ?? false)
    }
}

/// Who decided an ask, how and when. One made by the server itself (on expiry) has by `chat` and no sender.
public struct ChatAskDecision: Sendable, Equatable {
    public var by: String
    public var sender: ChatSender?
    public var declined = false
    public var answers: [ChatAskAnswer]? = []
    public var option = ""
    public var label = ""
    public var text = ""
    public var at: Double = 0
    public var digest = ""
    /// command (/decide), agent (POST /agent/decide), page, or expiry.
    public var via = ""
    /// A decider that is not human, by the decider role the owner gave it.
    public var deciderRole = false

    var json: JValue {
        var o = JObject()
        o.add("by", .string(by))
        if let sender { o.add("sender", sender.json) }
        o.add("declined", .bool(declined)); o.add("answers", .array((answers ?? []).map(\.json)))
        o.omitEmpty("option", option); o.omitEmpty("label", label); o.omitEmpty("text", text)
        o.add("at", .double(at)); o.add("digest", .string(digest)); o.add("via", .string(via)); o.omitEmpty("decider_role", deciderRole)
        return o.value
    }

    static func read(_ v: JValue) -> ChatAskDecision {
        var d = ChatAskDecision(by: v.field("by")?.stringValue ?? "")
        if let s = v.field("sender"), s.isObject { d.sender = ChatSender.read(s) }
        d.declined = v.field("declined")?.boolValue ?? false
        if case .array(let a)? = v.field("answers") { d.answers = a.map(ChatAskAnswer.read) } else { d.answers = nil }
        d.option = v.field("option")?.stringValue ?? ""; d.label = v.field("label")?.stringValue ?? ""
        d.text = v.field("text")?.stringValue ?? ""; d.at = v.field("at")?.doubleValue ?? 0
        d.digest = v.field("digest")?.stringValue ?? ""; d.via = v.field("via")?.stringValue ?? ""
        d.deciderRole = v.field("decider_role")?.boolValue ?? false
        return d
    }

    /// The server's own answer on expiry: decline, with no sender.
    static func expiry(digest: String, at: Double) -> ChatAskDecision {
        ChatAskDecision(by: ChatProtocol.systemName, sender: nil, declined: true, answers: [], option: "decline", label: "Decline", at: at,
                        digest: digest, via: "expiry")
    }
}

/// The ask object of a stored message. `question` is the message's text as posted: the title, and the question of a
/// one-question ask.
public struct ChatAsk: Sendable, Equatable {
    public var question = ""
    public var reason = ""
    public var questions: [ChatAskQuestion] = []
    /// Only in an ask stored by the reference's 0.15: `normalise()` moves them into `questions`.
    var legacyOptions: [ChatAskOption] = []
    var legacyFreeText = false
    public var deciders: [String] = []
    /// Canonical JSON (keys sorted, no spaces, no HTML escaping), "" when there is none.
    public var about = ""
    public var expiresAt = ""
    public var onExpiry = ""
    public var digest = ""
    /// open, then exactly one of decided, expired or withdrawn.
    public var state = "open"
    public var closedAt: Double = 0
    public var noDecider = false
    public var decision: ChatAskDecision?
    /// Dozable's: the short number per Mac (`#12`); 0 when it has none (an ask the reference stored).
    public var number = 0

    public init() {}

    /// When it expires, in seconds since 1970; 0 when it does not.
    public var expires: Double { ChatTime.parse(expiresAt)?.seconds ?? 0 }

    func question(_ id: String) -> ChatAskQuestion? { questions.first { $0.id == id } }

    /// The object as returned (13.2), with `number` last.
    public var json: JValue { object(stored: false) }

    /// What the room file's `ask` column keeps: the shape without its state, decision and closing (the row's own
    /// columns hold those), as the reference writes it.
    var storedJSON: String { ChatJSON.encodeString(object(stored: true)) }

    private func object(stored: Bool) -> JValue {
        var o = JObject()
        o.add("question", .string(question)); o.omitEmpty("reason", reason); o.add("questions", .array(questions.map(\.json)))
        if !legacyOptions.isEmpty { o.add("options", .array(legacyOptions.map(\.json))) }
        o.omitEmpty("free_text", legacyFreeText)
        o.add("deciders", .strings(deciders))
        if !about.isEmpty, let v = try? ChatJSON.parse(Array(about.utf8)) { o.add("about", v) }
        o.omitEmpty("expires_at", expiresAt); o.omitEmpty("on_expiry", onExpiry); o.add("digest", .string(digest))
        o.add("state", .string(stored ? "" : state))
        if !stored {
            o.omitEmpty("closed_at", closedAt); o.omitEmpty("no_decider", noDecider)
            if let decision { o.add("decision", decision.json) }
        }
        if number > 0 { o.add("number", .int(Int64(number))) }
        return o.value
    }

    /// Reads the stored `ask` column; the row's state, closing, no_decider and decision are set by the caller.
    static func readStored(_ text: String) -> ChatAsk? {
        guard let v = try? ChatJSON.parse(Array(text.utf8)), v.isObject else { return nil }
        var a = ChatAsk()
        a.question = v.field("question")?.stringValue ?? ""
        a.reason = v.field("reason")?.stringValue ?? ""
        if case .array(let qs)? = v.field("questions") { a.questions = qs.map(ChatAskQuestion.read) }
        if case .array(let os)? = v.field("options") { a.legacyOptions = os.compactMap { try? ChatAskOption.read($0, "option") } }
        a.legacyFreeText = v.field("free_text")?.boolValue ?? false
        a.deciders = ((try? v.field("deciders")?.goStrings("deciders")) ?? nil) ?? []
        if let ab = v.field("about"), !ab.isNull { a.about = (try? ChatAsk.canonical(ab)) ?? "" }
        a.expiresAt = v.field("expires_at")?.stringValue ?? ""
        a.onExpiry = v.field("on_expiry")?.stringValue ?? ""
        a.digest = v.field("digest")?.stringValue ?? ""
        a.number = ((try? v.field("number")?.goInt("number")) ?? nil) ?? 0
        return a
    }

    /// An ask read from storage in the one shape every reader sees: an ask stored by 0.15 (top-level options with decline
    /// among them, and free_text) becomes one question q1, and its decision gains declined and answers. Its digest is kept.
    mutating func normalise() {
        if questions.isEmpty {
            var q = ChatAskQuestion()
            q.id = "q1"; q.question = question; q.freeText = legacyFreeText
            q.options = legacyOptions.filter { $0.id != "decline" }
            if !q.options.isEmpty { q.min = 1; q.max = 1 }
            questions = [q]
        }
        legacyOptions = []; legacyFreeText = false
        if var d = decision, d.answers == nil {
            d.answers = []
            if d.option == "decline" {
                d.declined = true
            } else if !d.option.isEmpty || !d.text.isEmpty {
                var ans = ChatAskAnswer(questionID: questions[0].id, text: d.text)
                if !d.option.isEmpty { ans.options = [d.option]; ans.labels = [d.label] }
                d.answers = [ans]
            }
            decision = d
        }
    }

    // MARK: - Limits

    static let maxQuestions = 5, maxQuestion = 2000, maxHeader = 16, maxDescription = 300
    static let maxOptions = 8, maxLabel = 200, maxAbout = 4096, maxText = 4000, maxReason = 1000
    static let maxLifetime: Double = 7 * 24 * 3600
    /// decision.option for a decision that is not one option of a one-question ask.
    static let answered = "answered"

    /// `^[a-z0-9][a-z0-9-]{0,31}$`.
    static func isOptionID(_ s: String) -> Bool {
        let u = Array(s.utf8)
        guard (1...32).contains(u.count) else { return false }
        func ok(_ c: UInt8, first: Bool) -> Bool { (0x61...0x7A).contains(c) || (0x30...0x39).contains(c) || (!first && c == 0x2D) }
        return u.enumerated().allSatisfy { ok($1, first: $0 == 0) }
    }

    static func runes(_ s: String) -> Int { s.unicodeScalars.count }

    // MARK: - Canonical JSON

    /// A JSON value with its object keys sorted (by bytes, as Go sorts a map's keys), no spaces and no HTML escaping, its
    /// numbers as Go writes a float64: how `about` is stored, hashed and compared.
    static func canonical(_ v: JValue) throws -> String {
        String(decoding: ChatJSON.encode(try canonicalValue(v), escapeHTML: false), as: UTF8.self)
    }

    static func canonicalValue(_ v: JValue) throws -> JValue {
        switch v {
        case .object(let ms):
            var last: [String: JValue] = [:]
            for m in ms { last[m.key] = m.value }
            let keys = last.keys.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
            return .object(try keys.map { JMember($0, try canonicalValue(last[$0]!)) })
        case .array(let a): return .array(try a.map(canonicalValue))
        case .int, .double, .number:
            guard let d = v.doubleValue, d.isFinite else { throw ChatFieldError(description: "not a number") }
            return .number(ChatJSON.goFloat(d))
        default: return v
        }
    }
}

// MARK: - What an asker sends

/// One question as an asker sends it; nil tells a field left out from one given.
public struct ChatAskQuestionSpec: Sendable, Equatable {
    public var id = "", header = "", question = ""
    public var options: [ChatAskOption] = []
    public var multi = false
    public var min: Int?, max: Int?
    public var freeText: Bool?
    public var recommended = ""
    public var optional = false
    public init() {}
}

/// What an asker sends with a message of kind `ask`: questions, or the 0.15 form (options and free_text, one question).
public struct ChatAskSpec: Sendable, Equatable {
    public var questions: [ChatAskQuestionSpec] = []
    public var options: [ChatAskOption] = []
    public var freeText: Bool?
    public var deciders: [String] = []
    public var about: JValue?
    public var expiresAt = ""
    public var onExpiry = ""
    public var reason = ""
    public init() {}

    /// Reads the `ask` object of a line or a post as Go decodes it into its struct: a value of the wrong type is an error.
    public static func read(_ v: JValue) throws -> ChatAskSpec? {
        if v.isNull { return nil }
        guard v.isObject else { throw ChatFieldError(description: "ask: not an object") }
        var s = ChatAskSpec()
        func str(_ o: JValue, _ k: String) throws -> String { try o.field(k)?.goString("ask." + k) ?? "" }
        func optInt(_ o: JValue, _ k: String) throws -> Int? {
            guard let f = o.field(k), !f.isNull else { return nil }
            return try f.goInt("ask." + k)
        }
        func optBool(_ o: JValue, _ k: String) throws -> Bool? {
            guard let f = o.field(k), !f.isNull else { return nil }
            return try f.goBool("ask." + k)
        }
        func opts(_ o: JValue) throws -> [ChatAskOption] {
            switch o.field("options") ?? .null {
            case .null: return []
            case .array(let a): return try a.map { try ChatAskOption.read($0, "ask.options") }
            default: throw ChatFieldError(description: "ask.options: not an array")
            }
        }
        switch v.field("questions") ?? .null {
        case .null: break
        case .array(let a):
            for q in a {
                guard q.isObject || q.isNull else { throw ChatFieldError(description: "ask.questions: not an object") }
                var x = ChatAskQuestionSpec()
                x.id = try str(q, "id"); x.header = try str(q, "header"); x.question = try str(q, "question")
                x.options = try opts(q); x.multi = try q.field("multi")?.goBool("ask.multi") ?? false
                x.min = try optInt(q, "min"); x.max = try optInt(q, "max"); x.freeText = try optBool(q, "free_text")
                x.recommended = try str(q, "recommended"); x.optional = try q.field("optional")?.goBool("ask.optional") ?? false
                s.questions.append(x)
            }
        default: throw ChatFieldError(description: "ask.questions: not an array")
        }
        s.options = try opts(v)
        s.freeText = try optBool(v, "free_text")
        s.deciders = try v.field("deciders")?.goStrings("ask.deciders") ?? []
        s.about = v.field("about")
        s.expiresAt = try str(v, "expires_at"); s.onExpiry = try str(v, "on_expiry"); s.reason = try str(v, "reason")
        return s
    }
}

/// An answer to one question as a decider sends it.
public struct ChatAnswerIn: Sendable, Equatable {
    public var questionID = ""
    public var options: [String] = []
    public var text = ""
    public var skipped = false
}

/// What a decider sends: the 0.15 form {option, text} (an ask of one question), answers, or decline; or the words of a
/// typed `/decide`, read against the ask under its lock.
public struct ChatDecideInput: Sendable, Equatable {
    public var option = ""
    public var text = ""
    public var answers: [ChatAnswerIn] = []
    public var decline = false
    var typed = ""

    public init(option: String = "", text: String = "", answers: [ChatAnswerIn] = [], decline: Bool = false) {
        self.option = option; self.text = text; self.answers = answers; self.decline = decline
    }

    /// The body's fields as Go decodes them: a value of the wrong type is an error.
    static func read(_ v: JValue) throws -> ChatDecideInput {
        var d = ChatDecideInput()
        if v.isNull { return d }
        guard v.isObject else { throw ChatFieldError(description: "not an object") }
        d.option = try v.field("option")?.goString("option") ?? ""
        d.text = try v.field("text")?.goString("text") ?? ""
        d.decline = try v.field("decline")?.goBool("decline") ?? false
        switch v.field("answers") ?? .null {
        case .null: break
        case .array(let a):
            for e in a {
                guard e.isObject || e.isNull else { throw ChatFieldError(description: "answers: not an object") }
                d.answers.append(ChatAnswerIn(questionID: try e.field("question_id")?.goString("question_id") ?? "",
                                              options: try e.field("options")?.goStrings("options") ?? [],
                                              text: try e.field("text")?.goString("text") ?? "",
                                              skipped: try e.field("skipped")?.goBool("skipped") ?? false))
            }
        default: throw ChatFieldError(description: "answers: not an array")
        }
        return d
    }

    /// What was sent, in short, for the server's log.
    var summary: String {
        if !typed.isEmpty { return typed }
        if decline { return "decline" }
        if !answers.isEmpty { return answers.map { $0.questionID + "=" + $0.options.joined(separator: ",") }.joined(separator: " ") }
        return option
    }
}

// MARK: - The form: checks, digest, text

enum ChatAskForm {
    static let decideHelp = "use /decide <ask id> <option> [text] (the option by id or letter, A for the first, several with commas when the question takes several), "
        + "/decide <ask id> <text> for an answer in words, or /decide <ask id> decline [text]"
    static let withdrawHelp = "use /withdraw <ask id>"

    static func trim(_ s: String) -> String { ChatServerCore.trimSpace(s) }
    static func fields(_ s: String) -> [String] { ChatServerCore.fields(s) }
    static func isCommand(_ s: String) -> Bool { fields(s).first.map(ChatProtocol.isCommandWord) ?? false }
    static func letter(_ n: Int) -> String { String(UnicodeScalar(UInt8(0x41 + n))) }

    /// Checks the questions an asker sent and normalises them. content is the ask's title, and the question of a
    /// one-question ask that does not give its own.
    static func questions(content: String, spec: ChatAskSpec) throws -> [ChatAskQuestion] {
        var spec = spec
        let legacy = !spec.options.isEmpty || spec.freeText != nil
        if !spec.questions.isEmpty && legacy { throw ChatFieldError(description: "give questions, or the older options and free_text, not both") }
        if spec.questions.isEmpty {   // the 0.15 form: one question; decline is ask-level now, so it is not an option
            let ft = spec.freeText ?? false
            var q = ChatAskQuestionSpec()
            q.id = "q1"; q.freeText = ft
            q.options = spec.options.filter { $0.id != "decline" }
            if q.options.isEmpty && !ft {
                throw ChatFieldError(description: "an ask needs options (1 to \(ChatAsk.maxOptions)) or free_text, or both; or questions")
            }
            spec.questions = [q]
        }
        if spec.questions.count > ChatAsk.maxQuestions { throw ChatFieldError(description: "an ask has at most \(ChatAsk.maxQuestions) questions") }
        var out: [ChatAskQuestion] = []
        for (i, qs) in spec.questions.enumerated() {
            let q = try question(i, spec.questions.count, content, qs)
            if out.contains(where: { $0.id == q.id }) { throw ChatFieldError(description: "the question id \(q.id) is given twice") }
            out.append(q)
        }
        return out
    }

    static func question(_ i: Int, _ n: Int, _ content: String, _ qs: ChatAskQuestionSpec) throws -> ChatAskQuestion {
        func fail(_ s: String) -> ChatFieldError { ChatFieldError(description: s) }
        var q = ChatAskQuestion()
        q.id = qs.id; q.header = trim(qs.header); q.question = trim(qs.question); q.multi = qs.multi
        q.freeText = qs.freeText ?? true; q.recommended = qs.recommended; q.optional = qs.optional
        if q.optional && n < 2 { throw fail("an ask of one question cannot make it optional: the decider may decline the ask instead") }
        if q.id.isEmpty { q.id = "q\(i + 1)" }
        if !ChatAsk.isOptionID(q.id) {
            throw fail("\(goQuote(q.id)) is not a question id: lower-case letters, digits and -, starting with a letter or digit, at most 32")
        }
        if q.question.isEmpty {
            if n > 1 { throw fail("question \(q.id) needs its text: an ask of \(n) questions gives each its question") }
            q.question = trim(content)
        }
        if ChatAsk.runes(q.question) > ChatAsk.maxQuestion { throw fail("a question is at most \(ChatAsk.maxQuestion) characters") }
        if isCommand(q.question) { throw fail("an ask's question cannot be a command") }
        if ChatAsk.runes(q.header) > ChatAsk.maxHeader { throw fail("a question's header is at most \(ChatAsk.maxHeader) characters") }
        if qs.options.count > ChatAsk.maxOptions {
            throw fail("a question has at most \(ChatAsk.maxOptions) options (decline is not one: every ask can be declined)")
        }
        for o in qs.options {
            if !ChatAsk.isOptionID(o.id) {
                throw fail("\(goQuote(o.id)) is not an option id: lower-case letters, digits and -, starting with a letter or digit, at most 32")
            }
            if o.id == "decline" || o.id == ChatAsk.answered {
                throw fail("\(o.id) cannot be an option id: every ask can be declined, apart from its options, and \(ChatAsk.answered) names a decision")
            }
            if q.option(o.id) != nil { throw fail("the option id \(o.id) is given twice") }
            var label = trim(o.label)
            if label.isEmpty { label = o.id }
            if ChatAsk.runes(label) > ChatAsk.maxLabel { throw fail("an option's label is at most \(ChatAsk.maxLabel) characters") }
            let desc = trim(o.description)
            if ChatAsk.runes(desc) > ChatAsk.maxDescription { throw fail("an option's description is at most \(ChatAsk.maxDescription) characters") }
            q.options.append(ChatAskOption(id: o.id, label: label, description: desc))
        }
        if q.options.isEmpty && !q.freeText { throw fail("question \(q.id) needs options or free_text") }
        if !q.recommended.isEmpty && q.option(q.recommended) == nil {
            throw fail("recommended \(goQuote(q.recommended)) is not an option of question \(q.id)")
        }
        if q.multi {
            if q.options.isEmpty { throw fail("question \(q.id) is multi, so it needs options") }
            q.min = qs.min ?? 1; q.max = qs.max ?? q.options.count
            if q.min < 1 || q.min > q.max || q.max > q.options.count {
                throw fail("question \(q.id): min and max must keep 1 <= min <= max <= \(q.options.count), its number of options")
            }
        } else if (qs.min != nil && qs.min != 1) || (qs.max != nil && qs.max != 1) {
            throw fail("question \(q.id): min and max are for a question with multi")
        } else if !q.options.isEmpty {
            q.min = 1; q.max = 1
        }
        return q
    }

    /// The SHA-256 (hex) of `["ask-v3", title, reason, [question, ...], [deciders, sorted], about, expires_at, on_expiry]`,
    /// each question `[id, header, question, [[option id, label, description], ...], multi, min, max, free_text,
    /// recommended, optional]`, with no spaces and no HTML escaping; about its canonical JSON or null.
    static func digest(_ a: ChatAsk) -> String {
        let qs: [JValue] = a.questions.map { q in
            .array([.string(q.id), .string(q.header), .string(q.question),
                    .array(q.options.map { .array([.string($0.id), .string($0.label), .string($0.description)]) }),
                    .bool(q.multi), .int(Int64(q.min)), .int(Int64(q.max)), .bool(q.freeText), .string(q.recommended), .bool(q.optional)])
        }
        let ds = a.deciders.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
        let about: JValue = a.about.isEmpty ? .null : ((try? ChatJSON.parse(Array(a.about.utf8))) ?? .null)
        let arr: JValue = .array([.string("ask-v3"), .string(a.question), .string(a.reason), .array(qs), .strings(ds), about,
                                  .string(a.expiresAt), .string(a.onExpiry)])
        return SHA256.hash(data: Data(ChatJSON.encode(arr, escapeHTML: false))).map { String(format: "%02x", $0) }.joined()
    }

    /// How many options a question takes, in words: "pick one", "pick 1 to 3", "pick 2".
    static func pickRule(_ q: ChatAskQuestion) -> String {
        if q.options.isEmpty { return "" }
        if !q.multi { return "pick one" }
        if q.min == q.max { return "pick \(q.min)" }
        return "pick \(q.min) to \(q.max)"
    }

    /// The stored text of an ask: the title, each question with its options lettered, and how to answer, readable by a
    /// client that does not know asks. Written once, when the ask is posted.
    static func text(id: String, asker: String, _ a: ChatAsk) -> String {
        var b = a.question + "\n\n"
        if !a.reason.isEmpty { b += "Why: " + a.reason + "\n\n" }
        for (i, q) in a.questions.enumerated() {
            if a.questions.count > 1 {
                b += "**Question \(i + 1) of \(a.questions.count)** (`\(q.id)`)"
                if !q.header.isEmpty { b += " " + q.header }
                if q.optional { b += " (optional)" }
                b += ": " + q.question + "\n\n"
            } else if q.question != a.question {
                b += q.question + "\n\n"
            }
            if !q.options.isEmpty {
                b += "Options (\(pickRule(q))):\n"
                for (k, o) in q.options.enumerated() {
                    b += "\(letter(k)). `\(o.id)` \(o.label)"
                    if o.id == q.recommended { b += " (recommended)" }
                    b += "\n"
                    if !o.description.isEmpty { b += "   " + o.description.replacingOccurrences(of: "\n", with: " ") + "\n" }
                }
                if q.freeText { b += "Or answer in your own words.\n" }
                b += "\n"
            } else {
                b += "Answer in your own words.\n\n"
            }
        }
        b += "This is an ask from \(capitalFirst(asker)), for \(a.deciders.map(capitalFirst).joined(separator: ", ")) to decide. "
        if a.questions.count > 1 {
            b += "It has \(a.questions.count) questions, so it is answered on the chat page, or with POST /agent/decide and its answers. "
        } else {
            let q = a.questions[0]
            if !q.options.isEmpty {
                b += "To decide, send `/decide \(id) A` with the option's letter or id"
                if q.multi { b += ", several with commas such as `A,C`" }
                b += q.freeText ? ", with words of your own after it if you like, or `/decide \(id) <your own answer>`. " : ". "
            } else {
                b += "To decide, send `/decide \(id) <your answer>`. "
            }
        }
        b += "To decline, send `/decide \(id) decline` with your reason after it if you like."
        if !a.expiresAt.isEmpty {
            b += " It expires at \(a.expiresAt)"
            if !a.onExpiry.isEmpty { b += "; then the answer is `\(a.onExpiry)`" }
            b += "."
        }
        return b
    }

    /// Reads the words of a typed "/decide <ask id> ..." against the ask: "decline [words]"; for an ask of one question,
    /// options by id or by UPPER-CASE position letter (A is the first), several with commas, then words; or, for a question
    /// that takes free text, words alone. The input, or why not.
    static func parseTyped(_ a: ChatAsk, _ words: String) -> (ChatDecideInput, String) {
        let f = fields(words)
        guard let first = f.first else { return (ChatDecideInput(), decideHelp) }
        let t = trim(words)
        let rest = trim(t.hasPrefix(first) ? String(t.dropFirst(first.count)) : t)
        if first == "decline" { return (ChatDecideInput(text: rest, decline: true), "") }
        if a.questions.count != 1 {
            return (ChatDecideInput(), "this ask has \(a.questions.count) questions, so it cannot be decided with /decide: answer it on the chat page, or POST /agent/decide with "
                + #"{"answers":[{"question_id":"<id>","options":["<option id>"],"text":"<words>"}, ...]}; /decide <ask id> decline [words] declines it"#)
        }
        let q = a.questions[0]
        var ids: [String] = [], ok = true
        for raw in first.split(separator: ",", omittingEmptySubsequences: false) {
            let p = trim(String(raw))
            if q.option(p) != nil { ids.append(p); continue }
            let u = Array(p.utf8)
            if u.count == 1, (0x41...0x5A).contains(u[0]), Int(u[0] - 0x41) < q.options.count { ids.append(q.options[Int(u[0] - 0x41)].id); continue }
            ok = false
            break
        }
        if ok && !ids.isEmpty { return (ChatDecideInput(answers: [ChatAnswerIn(questionID: q.id, options: ids, text: rest)]), "") }
        if q.freeText { return (ChatDecideInput(answers: [ChatAnswerIn(questionID: q.id, options: [], text: t)]), "") }
        return (ChatDecideInput(), "\(goQuote(first)) is not an option of this ask; its options are \(q.optionIDs) (or their letters, A for the first)")
    }

    /// Checks a decider's input against the ask: the answers, whether it declines (text is then the reason), or why not.
    static func checkAnswers(_ a: ChatAsk, _ input: ChatDecideInput) -> (answers: [ChatAskAnswer], declined: Bool, text: String, bad: String) {
        func no(_ s: String) -> ([ChatAskAnswer], Bool, String, String) { ([], false, "", s) }
        if input.decline || (input.option == "decline" && input.answers.isEmpty) {
            if !input.answers.isEmpty { return no("decline, or answers, not both") }
            let t = trim(input.text)
            if ChatAsk.runes(t) > ChatAsk.maxText { return no("the text of a decision is at most \(ChatAsk.maxText) characters") }
            return ([], true, t, "")
        }
        var given = input.answers
        if given.isEmpty {   // the 0.15 form: {option, text}, for an ask of one question
            if a.questions.count != 1 {
                return no(#"this ask has \#(a.questions.count) questions: send "answers":[{"question_id":"<id>","options":["<option id>"],"text":"<words>"}, ...], one for each"#)
            }
            given = [ChatAnswerIn(questionID: a.questions[0].id, options: input.option.isEmpty ? [] : [input.option], text: input.text)]
        } else if !input.option.isEmpty || !input.text.isEmpty {
            return no("give answers, or option and text, not both")
        }
        var byQ: [String: ChatAnswerIn] = [:]
        for g in given {
            if a.question(g.questionID) == nil {
                return no("\(goQuote(g.questionID)) is not a question of this ask; its questions are \(a.questions.map(\.id).joined(separator: ", "))")
            }
            if byQ[g.questionID] != nil { return no("question \(g.questionID) is answered twice") }
            byQ[g.questionID] = g
        }
        let one = a.questions.count == 1
        var answers: [ChatAskAnswer] = []
        for q in a.questions {
            let of = one ? "" : " of question " + q.id
            let g = byQ[q.id] ?? ChatAnswerIn(questionID: q.id)
            let t = trim(g.text)
            if g.skipped {
                if !q.optional { return no("question \(q.id) is not optional, so it cannot be skipped") }
                if !g.options.isEmpty || !t.isEmpty { return no("question \(q.id) is skipped, so it takes no options or words") }
                answers.append(ChatAskAnswer(questionID: q.id, skipped: true))
                continue
            }
            var ans = ChatAskAnswer(questionID: q.id, text: t)
            for id in g.options {
                guard let o = q.option(id) else { return no("\(goQuote(id)) is not an option\(of) of this ask; its options are \(q.optionIDs)") }
                if !ans.options.contains(id) { ans.options.append(id); ans.labels.append(o.label) }
            }
            let n = ans.options.count
            if n == 0 && t.isEmpty && !q.freeText { return no("say which option\(of): \(q.optionIDs)") }
            if n == 0 && t.isEmpty && q.options.isEmpty { return no("give your answer\(one ? "" : " to question " + q.id) in words") }
            if n == 0 && t.isEmpty { return no("say which option\(of) (\(q.optionIDs)), or give your own answer") }
            if !t.isEmpty && !q.freeText {
                if one { return no("this ask takes no free text: answer with its options alone, or decline with your words") }
                return no("question \(q.id) takes no free text: answer it with its options alone")
            }
            if !q.multi && n > 1 { return no("pick one option\(of), not \(n)") }
            if q.multi && n > 0 && (n < q.min || n > q.max) { return no("\(pickRule(q)) options\(of), not \(n)") }
            if ChatAsk.runes(t) > ChatAsk.maxText { return no("the text of a decision is at most \(ChatAsk.maxText) characters") }
            answers.append(ans)
        }
        return (answers, false, "", "")
    }

    /// The decision's option, label and text from its answers, for a reader of 0.15.
    static func compatFields(_ a: ChatAsk, _ d: inout ChatAskDecision) {
        if d.declined { d.option = "decline"; d.label = "Decline"; return }
        let answers = d.answers ?? []
        if a.questions.count == 1 && answers.count == 1 {
            let ans = answers[0]
            d.text = ans.text
            if ans.options.count == 1 { d.option = ans.options[0]; d.label = ans.labels[0]; return }
        }
        d.option = ChatAsk.answered
        d.label = clipLine(summary(a, answers, sep: "; "), ChatAsk.maxLabel)
    }

    /// The answers in words: "Header: Label, Label (words)", one per question, joined by sep.
    static func summary(_ a: ChatAsk, _ answers: [ChatAskAnswer], sep: String) -> String {
        answers.map { ans in
            var s = ans.skipped ? "(skipped)" : ans.labels.joined(separator: ", ")
            if !ans.text.isEmpty {
                if !s.isEmpty { s += " " }
                s += "\u{201C}" + ans.text + "\u{201D}"
            }
            if a.questions.count > 1 {
                var name = ans.questionID
                if let q = a.question(ans.questionID) { name = q.header.isEmpty ? q.question : q.header }
                s = clipLine(name, 60) + ": " + s
            }
            return s
        }.joined(separator: sep)
    }

    /// The body of POST /agent/decide that answers this ask, with an answer for each of its questions.
    static func decideBody(room: String, id: String, _ a: ChatAsk) -> String {
        let ans = a.questions.map { q in
            #"{"question_id":\#(goQuote(q.id)),"options":\#(q.options.isEmpty ? "[]" : #"["<option id>"]"#),"text":"<words, or empty>"\#(q.optional ? #","skipped":false"# : "")}"#
        }
        return #"{"room":\#(goQuote(room)),"ask_id":\#(goQuote(id)),"answers":[\#(ans.joined(separator: ","))],"msg_id":"<new uuid>"}"#
    }

    /// How a decider decides this ask, in one sentence (a receive item's how_to_respond).
    static func decideHow(room: String, id: String, _ a: ChatAsk) -> String {
        let s = "You are a decider of this ask: POST /agent/decide with your token and \(decideBody(room: room, id: id, a)), an answer for every question, or "
            + #"{"room":\#(goQuote(room)),"ask_id":\#(goQuote(id)),"decline":true,"text":"<why>"} to decline"#
        if a.questions.count == 1 {
            return s + #"; or send the content "/decide \#(id) <option id or letter, A for the first> [text]", or "/decide \#(id) decline [text]"."#
        }
        return s + #". It has \#(a.questions.count) questions, so a typed /decide cannot answer it; "/decide \#(id) decline [text]" declines it."#
    }

    /// s on one line, cut to n characters with an ellipsis.
    static func clipLine(_ s: String, _ n: Int) -> String {
        let one = fields(s).joined(separator: " ")
        let u = one.unicodeScalars
        if u.count > n { return String(String.UnicodeScalarView(u.prefix(n - 1))) + "…" }
        return one
    }
}

// MARK: - Time, as Go's RFC 3339 with nanoseconds

/// A time to the nanosecond, read and written as Go's `time.RFC3339Nano` in UTC (trailing zeros of the fraction dropped).
struct ChatTime: Equatable {
    var sec: Int64
    var nsec: Int64

    var seconds: Double { Double(sec) + Double(nsec) / 1e9 }

    static func now() -> ChatTime {
        var ts = timespec()
        clock_gettime(CLOCK_REALTIME, &ts)
        return ChatTime(sec: Int64(ts.tv_sec), nsec: Int64(ts.tv_nsec))
    }

    func adding(seconds s: Double) -> ChatTime {
        let whole = Int64(s.rounded(.down))
        var n = nsec + Int64(((s - Double(whole)) * 1e9).rounded())
        var t = sec + whole
        if n >= 1_000_000_000 { n -= 1_000_000_000; t += 1 }
        return ChatTime(sec: t, nsec: n)
    }

    /// `2026-11-19T20:15:53.000274Z`; with `fraction: false`, Go's `time.RFC3339` (no fraction).
    func format(fraction: Bool = true) -> String {
        var t = time_t(sec)
        var tm = Darwin.tm()
        gmtime_r(&t, &tm)
        var s = String(format: "%04d-%02d-%02dT%02d:%02d:%02d", Int(tm.tm_year) + 1900, Int(tm.tm_mon) + 1, Int(tm.tm_mday),
                       Int(tm.tm_hour), Int(tm.tm_min), Int(tm.tm_sec))
        if fraction && nsec > 0 {
            var f = String(format: "%09lld", nsec)
            while f.hasSuffix("0") { f.removeLast() }
            s += "." + f
        }
        return s + "Z"
    }

    /// Reads RFC 3339 as Go's `time.Parse(time.RFC3339Nano, …)` does: a date and time, an optional fraction of any
    /// length (nanoseconds kept), and `Z` or `±hh:mm`. nil when it is not one, or a field is out of range.
    static func parse(_ s: String) -> ChatTime? {
        let u = Array(s.utf8)
        func num(_ i: Int, _ n: Int) -> Int? {
            guard i + n <= u.count else { return nil }
            var v = 0
            for c in u[i..<(i + n)] { guard (0x30...0x39).contains(c) else { return nil }; v = v * 10 + Int(c - 0x30) }
            return v
        }
        guard u.count >= 20, let y = num(0, 4), u[4] == 0x2D, let mo = num(5, 2), u[7] == 0x2D, let d = num(8, 2), u[10] == 0x54,
              let h = num(11, 2), u[13] == 0x3A, let mi = num(14, 2), u[16] == 0x3A, let se = num(17, 2) else { return nil }
        var i = 19
        var nsec: Int64 = 0
        if i < u.count, u[i] == 0x2E {
            i += 1
            let start = i
            while i < u.count, (0x30...0x39).contains(u[i]) { i += 1 }
            guard i > start else { return nil }
            var digits = Array(u[start..<i].prefix(9))
            while digits.count < 9 { digits.append(0x30) }
            nsec = Int64(String(decoding: digits, as: UTF8.self)) ?? 0
        }
        guard i < u.count else { return nil }
        var offset = 0
        if u[i] == 0x5A {
            i += 1
        } else if u[i] == 0x2B || u[i] == 0x2D, let oh = num(i + 1, 2), i + 3 < u.count, u[i + 3] == 0x3A, let om = num(i + 4, 2) {
            guard oh < 24, om < 60 else { return nil }
            offset = (oh * 3600 + om * 60) * (u[i] == 0x2D ? -1 : 1)
            i += 6
        } else {
            return nil
        }
        guard i == u.count, (1...12).contains(mo), h < 24, mi < 60, se < 60 else { return nil }
        let leap = (y % 4 == 0 && y % 100 != 0) || y % 400 == 0
        let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][mo - 1]
        guard (1...days).contains(d) else { return nil }
        var tm = Darwin.tm()
        tm.tm_year = Int32(y - 1900); tm.tm_mon = Int32(mo - 1); tm.tm_mday = Int32(d)
        tm.tm_hour = Int32(h); tm.tm_min = Int32(mi); tm.tm_sec = Int32(se)
        return ChatTime(sec: Int64(timegm(&tm)) - Int64(offset), nsec: nsec)
    }
}
