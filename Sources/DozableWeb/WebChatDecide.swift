import DozableChat
import DozableHost
import Foundation

/// The decision card's answer (`chat-decide`): exactly the HostOp `chat-decide` that `doz chat decide` sends, strictly
/// decoded here. `room` (a room's name), `ask` (`#N` or the start of its msg_id: hex and dashes, at most 36), `actionId` (a
/// lower-case v4 UUID: the decision's `X-Chat-Id`, so a retry is a duplicate) and exactly one of `answers` (at most 5, each
/// `{questionId, options ≤ 10 option ids, text ≤ 4 KiB, skipped}`), `decline: true` (with `text`, its reason, ≤ 4 KiB) or
/// `reply` (≤ 4 KiB: an option, its letter or label, decline, or words — `ChatAskReply`). This Mac's own browser only
/// (`WebAction.isAsk`, `WebExposure.decideAskAction`). Its text is never in the operation's label or line.
public struct WebChatDecide: Equatable, Sendable {
    public var answers: [ChatAskAnswerItem]?
    public var decline = false
    public var text: String?
    public var reply: String?

    static let fields: Set<String> = ["room", "ask", "answers", "decline", "text", "reply", "actionId"]
    static let maxText = 4096
    static let maxAnswers = 5, maxOptions = 10

    typealias Invalid = WebAction.Invalid

    /// A person's words: a string of 1 to 4 KiB (as UTF-8), no control character but a newline or a tab.
    static func words(_ v: Any?, _ key: String, emptyOK: Bool = false) throws -> String? {
        guard let v, !(v is NSNull) else { return nil }
        guard let s = v as? String else { throw Invalid("\(key) must be a string") }
        guard (emptyOK || !s.isEmpty), s.utf8.count <= maxText,
              !s.unicodeScalars.contains(where: { $0.properties.generalCategory == .control && $0 != "\n" && $0 != "\t" }) else {
            throw Invalid("\(key): 1 to 4096 bytes, no control characters but a newline or a tab")
        }
        return s
    }

    static func decode(_ d: [String: Any]) throws -> (room: String, ask: String, input: WebChatDecide, actionID: String) {
        guard let room = d["room"] as? String, room.range(of: "^[a-z0-9][a-z0-9_-]{0,63}$", options: .regularExpression) != nil else {
            throw Invalid("room: a room's name")
        }
        guard let ask = d["ask"] as? String, ChatAskRef.isValid(ask) else { throw Invalid("ask: #N, or the start of its id") }
        guard let id = d["actionId"] as? String, (try? HostCore.actionID(id)) != nil else { throw Invalid("actionId: a lower-case v4 UUID") }
        var input = WebChatDecide()
        var forms = 0
        if let v = d["answers"], !(v is NSNull) {
            forms += 1
            guard let a = v as? [Any], (1...maxAnswers).contains(a.count) else { throw Invalid("answers: 1 to 5 answers") }
            input.answers = try a.map { e in
                guard let o = e as? [String: Any], Set(o.keys).isSubset(of: ["questionId", "options", "text", "skipped"]) else {
                    throw Invalid("answers: each {questionId, options, text, skipped}")
                }
                guard let q = o["questionId"] as? String, q.range(of: "^[a-z0-9][a-z0-9-]{0,63}$", options: .regularExpression) != nil else {
                    throw Invalid("answers: questionId, a question's id")
                }
                var opts: [String]?
                if let ov = o["options"], !(ov is NSNull) {
                    guard let l = ov as? [Any], l.count <= maxOptions,
                          let ids = l as? [String], ids.allSatisfy({ $0.range(of: "^[a-z0-9][a-z0-9-]{0,31}$", options: .regularExpression) != nil }) else {
                        throw Invalid("answers: options, at most 10 option ids")
                    }
                    opts = ids
                }
                var skipped: Bool?
                if let sv = o["skipped"], !(sv is NSNull) {
                    guard let b = sv as? Bool, CFGetTypeID(sv as CFTypeRef) == CFBooleanGetTypeID() else { throw Invalid("answers: skipped, true or false") }
                    skipped = b ? true : nil
                }
                return ChatAskAnswerItem(questionId: q, options: opts, text: try words(o["text"], "answers: text", emptyOK: true), skipped: skipped)
            }
        }
        if let v = d["decline"], !(v is NSNull) {
            guard let b = v as? Bool, CFGetTypeID(v as CFTypeRef) == CFBooleanGetTypeID(), b else { throw Invalid("decline: true") }
            forms += 1
            input.decline = true
        }
        input.text = try words(d["text"], "text")
        if input.text != nil && !input.decline { throw Invalid("text: goes with decline (an answer's words go in reply or answers)") }
        if let r = try words(d["reply"], "reply") { forms += 1; input.reply = r }
        guard forms == 1 else { throw Invalid("chat-decide: exactly one of answers, decline or reply") }
        return (room, ask, input, id)
    }

    /// What `doz chat decide R ASK …` sends.
    func request(room: String, ask: String, actionID: String) -> HostRequest {
        var q = ChatAskRequest(room: room, ask: ask)
        q.answers = answers
        if decline { q.decline = true; q.text = text }
        q.reply = reply
        q.actionID = actionID
        var r = HostRequest(.chatDecide)
        r.chatAsk = q
        return r
    }
}
