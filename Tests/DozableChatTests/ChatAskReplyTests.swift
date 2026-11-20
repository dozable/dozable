@testable import DozableChat
import Foundation
import XCTest

/// What every client of asks shares, pure: a person's words turned into a decision (`ChatAskReply`), a refusal told in
/// Dozable's words (`ChatAskRefusal`), who may answer (`ChatAskViewer`) and a bare number made `#N` (`ChatAskRef`).
final class ChatAskReplyTests: XCTestCase {
    func ask(_ spec: String, state: String = "open", question: String = "Ship it?") -> ChatAsk {
        let s = try! ChatAskSpec.read(try! ChatJSON.parse(Array(spec.utf8)))!
        var a = ChatAsk()
        a.question = question
        a.questions = try! ChatAskForm.questions(content: question, spec: s)
        a.deciders = s.deciders.isEmpty ? ["ada"] : s.deciders
        a.state = state
        return a
    }

    func picked(_ r: Result<ChatDecideInput, ChatAskRefusal>) -> [String] {
        guard case .success(let i) = r else { return [] }
        if i.decline { return ["decline", i.text] }
        return (i.answers.first?.options ?? []) + [i.answers.first?.text ?? ""]
    }

    static let two = #"{"questions": [{"options": [{"id": "now", "label": "Right now"}, {"id": "next", "label": "Next week"}]}]}"#

    func testAnOptionByIDLetterLabelThenDeclineThenWords() {
        let a = ask(Self.two)
        XCTAssertEqual(picked(ChatAskReply.resolve(a, words: "next")), ["next", ""])
        XCTAssertEqual(picked(ChatAskReply.resolve(a, words: "next after lunch")), ["next", "after lunch"])
        XCTAssertEqual(picked(ChatAskReply.resolve(a, words: "B")), ["next", ""])
        XCTAssertEqual(picked(ChatAskReply.resolve(a, words: "a")), ["now", ""], "a letter in either case")
        XCTAssertEqual(picked(ChatAskReply.resolve(a, words: "right NOW")), ["now", ""], "the label, ignoring case")
        XCTAssertEqual(picked(ChatAskReply.resolve(a, words: "next WEEK")), ["next", "WEEK"], "an option's id comes first")
        XCTAssertEqual(picked(ChatAskReply.resolve(a, words: "Decline not this week")), ["decline", "not this week"])
        XCTAssertEqual(picked(ChatAskReply.resolve(a, words: "whenever you like")), ["whenever you like"], "free text by default")
        XCTAssertEqual(picked(ChatAskReply.resolve(a, words: "C")), ["C"], "a letter past the options is words")
    }

    func testRefusedWithTheOptionsListed() {
        let a = ask(#"{"questions": [{"options": [{"id": "yes", "label": "Yes"}, {"id": "no", "label": "No"}], "free_text": false}]}"#)
        guard case .failure(let r) = ChatAskReply.resolve(a, words: "perhaps") else { return XCTFail("taken") }
        XCTAssertEqual(r.code, .badAnswer)
        XCTAssertEqual(r.words, "\u{201C}perhaps\u{201D} is not one of this ask's options: A. Yes, B. No, or decline.")
        guard case .failure(let empty) = ChatAskReply.resolve(a, words: "  ") else { return XCTFail("taken") }
        XCTAssertEqual(empty.code, .badAnswer)
        let multi = ask(#"{"questions": [{"options": [{"id": "a"}, {"id": "b"}], "multi": true}]}"#)
        guard case .failure(let m) = ChatAskReply.resolve(multi, words: "a") else { return XCTFail("taken") }
        XCTAssertTrue(m.words.hasPrefix("This question takes several options"))
        XCTAssertEqual(picked(ChatAskReply.resolve(multi, words: "decline")), ["decline", ""], "declining is always one word")
        let several = ask(#"{"questions": [{"id": "q1", "question": "One?"}, {"id": "q2", "question": "Two?"}]}"#)
        guard case .failure(let s) = ChatAskReply.resolve(several, words: "yes") else { return XCTFail("taken") }
        XCTAssertTrue(s.words.hasPrefix("This ask has 2 questions"))
    }

    func testRefusalsAreDecidedByTheAskReadAfterThem() {
        var decided = ask(Self.two, state: "decided")
        decided.decision = ChatAskDecision(by: "worker", deciderRole: true)
        XCTAssertEqual(ChatAskRefusal.classify(detail: "anything", ask: decided), .init(.answered, "It was already answered: decided by Worker (decider role)."))
        var expired = ask(Self.two, state: "expired")
        expired.onExpiry = "decline"
        XCTAssertEqual(ChatAskRefusal.classify(detail: "", ask: expired), .init(.expired, "This ask expired: its answer was decline."))
        XCTAssertEqual(ChatAskRefusal.classify(detail: "", ask: ask(Self.two, state: "withdrawn")).code, .withdrawn)
        let open = ask(#"{"questions": [{}], "deciders": ["decbot"]}"#)
        XCTAssertEqual(ChatAskRefusal.classify(detail: "ada is not a decider of this ask; its deciders are decbot", ask: open).words,
                       "You are not one of this ask's deciders (only Decbot is).")
        XCTAssertEqual(ChatAskRefusal.classify(detail: "the asker cannot decide its own ask", ask: open).code, .asker)
        XCTAssertEqual(ChatAskRefusal.classify(detail: ChatServerCore.askOff, ask: nil).code, .asksOff)
        XCTAssertEqual(ChatAskRefusal.classify(detail: ChatRoomControl.closedText(room: "r", workspace: "w"), ask: open).code, .roomClosed)
        XCTAssertEqual(ChatAskRefusal.classify(detail: "pick one option, not 2", ask: open), .init(.badAnswer, "Pick one option, not 2."))
        XCTAssertEqual(ChatAskRefusal.macOnly.words, "Asks are answered in this Mac's own browser for now.")
    }

    func testWhoMayAnswer() {
        var a = ask(#"{"questions": [{}], "deciders": ["ada", "decbot"]}"#)
        XCTAssertTrue(ChatAskViewer.canAnswer(a, viewer: "ada", asker: "bot1"))
        XCTAssertFalse(ChatAskViewer.canAnswer(a, viewer: "ada", asker: "ada"), "the asker")
        XCTAssertFalse(ChatAskViewer.canAnswer(a, viewer: "bob", asker: "bot1"), "not a decider")
        XCTAssertEqual(ChatAskViewer.readOnlyLine(a, viewer: "bob", asker: "bot1"), "Only Ada, Decbot can answer.")
        a.noDecider = true
        XCTAssertFalse(ChatAskViewer.canAnswer(a, viewer: "ada", asker: "bot1"), "no decider left")
        a.noDecider = false; a.state = "decided"
        XCTAssertFalse(ChatAskViewer.canAnswer(a, viewer: "ada", asker: "bot1"), "closed")
    }

    func testABareNumberIsHashN() {
        XCTAssertEqual(ChatAskRef.normalise("12"), "#12")
        XCTAssertEqual(ChatAskRef.normalise("#12"), "#12")
        XCTAssertEqual(ChatAskRef.normalise("4f1a"), "4f1a")
        for ok in ["#1", "4f1a", "0b7e2c4a-1111-4222-8333-444455556666"] { XCTAssertTrue(ChatAskRef.isValid(ok), ok) }
        for bad in ["", "#0", "#x", "../x", "ABC", "%23", String(repeating: "a", count: 37)] { XCTAssertFalse(ChatAskRef.isValid(bad), bad) }
    }

    func testAnAskIsReadBackFromItsMessage() throws {
        let m = try ChatJSON.parse(Array(#"{"msg_id":"m1","kind":"ask","from":"bot1","ask":{"question":"Go?","questions":[{"id":"q1","question":"Go?","options":[],"multi":false,"min":0,"max":0,"free_text":true,"optional":false}],"deciders":["ada"],"digest":"d","state":"decided","number":7,"decision":{"by":"ada","declined":true,"answers":[],"at":1,"digest":"d","via":"page"}}}"#.utf8))
        let a = try XCTUnwrap(ChatAsk.read(message: m))
        XCTAssertEqual(a.state, "decided")
        XCTAssertEqual(a.number, 7)
        XCTAssertEqual(a.decision?.declined, true)
        XCTAssertNil(ChatAsk.read(message: try ChatJSON.parse(Array(#"{"kind":"","content":"hi"}"#.utf8))))
    }
}
