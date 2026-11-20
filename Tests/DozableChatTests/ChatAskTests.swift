import CryptoKit
import Darwin
@testable import DozableChat
import Foundation
import XCTest

extension ChatAskTestCase {
    func decide(_ core: ChatServerCore, _ who: String, _ id: String, option: String = "", text: String = "", decline: Bool = false,
                answers: [ChatAnswerIn] = [], room: String = "room1") -> ChatReceipt {
        core.decide(room: room, who: who, ref: id, input: ChatDecideInput(option: option, text: text, answers: answers, decline: decline), via: "agent", verified: true)
    }
}

// MARK: - Deciding

final class ChatAskDecideTests: ChatAskTestCase {
    func testEveryDecideRefusalInOrder() throws {
        let c = try core()
        let id = askOK(c, "bot1", #"{"options":[{"id":"yes"},{"id":"no"}],"free_text":false,"deciders":["ada","bot2"]}"#)
        XCTAssertEqual(decide(c, "bot1", id, option: "yes").detail, "the asker cannot decide its own ask")
        XCTAssertEqual(decide(c, "bot3", id, option: "yes").detail, "bot3 does not have the decider role")
        XCTAssertEqual(decide(c, "bot2", "zzz", option: "yes").detail, "no ask in room room1 starts with zzz")
        XCTAssertEqual(decide(c, "bot2", id, option: "maybe").detail, #""maybe" is not an option of this ask; its options are yes, no"#)
        XCTAssertEqual(decide(c, "bot2", id, option: "yes", text: "because").detail, "this ask takes no free text: answer with its options alone, or decline with your words")
        XCTAssertEqual(decide(c, "bot2", id, option: "yes", decline: true).detail, "", "decline wins over an option")
        XCTAssertEqual(askOf(c, id)?.state, "decided")
        XCTAssertEqual(decide(c, "ada", id, option: "no").detail, "this ask was already decided by bot2: decline")
        // not a decider: a role bot the ask did not name
        let id2 = askOK(c, "bot3", Self.one)
        XCTAssertEqual(decide(c, "bot2", id2, option: "copy").detail, "bot2 is not a decider of this ask; its deciders are ada")
        // a message that is no ask
        let plain = line("hello")
        XCTAssertEqual(c.post(plain, sender: "bot1").state, "queued")
        XCTAssertEqual(decide(c, "ada", plain.msgID, option: "x").detail, "msg \(plain.msgID.prefix(8)) is not an ask")
        XCTAssertEqual(c.withdraw(room: "room1", who: "bot1", ref: id2, via: "agent").detail, "only bot3, who asked it, can withdraw this ask")
    }

    func testLettersMultiFreeTextDeclineAndSkipped() throws {
        let c = try core()
        // letters and commas, then words
        let a = askOK(c, "bot1", #"{"deciders":["bot2"],"questions":[{"options":[{"id":"red"},{"id":"green"},{"id":"blue"}],"multi":true,"max":2}]}"#)
        XCTAssertEqual(c.post(line("/decide \(a.prefix(8)) A,B,C"), sender: "bot2").detail, "pick 1 to 2 options, not 3")
        XCTAssertEqual(c.post(line("/decide \(a.prefix(8)) C,red both"), sender: "bot2").state, "decided")
        let d = try XCTUnwrap(askOf(c, a)?.decision)
        XCTAssertEqual(d.answers?.first?.options, ["blue", "red"]); XCTAssertEqual(d.answers?.first?.text, "both")
        XCTAssertEqual(d.option, "answered"); XCTAssertEqual(d.via, "command"); XCTAssertTrue(d.deciderRole)
        // free text alone
        let b = askOK(c, "bot3", #"{"questions":[{"options":[{"id":"x"}]}]}"#, text: "What then?")
        XCTAssertEqual(c.post(line("/decide ^\(b.prefix(8)) use the other copy"), sender: "ada").state, "decided")
        XCTAssertEqual(askOf(c, b)?.decision?.answers?.first?.text, "use the other copy")
        XCTAssertEqual(askOf(c, b)?.decision?.option, "answered")
        // two questions: the typed form is refused; answers with a skipped optional one
        let two = #"{"deciders":["bot2"],"questions":[{"id":"what","header":"What","question":"Which?","options":[{"id":"web"}]},{"id":"note","question":"Note?","optional":true}]}"#
        let t = askOK(c, "bot1", two, text: "Two things")
        XCTAssertTrue(c.post(line("/decide \(t.prefix(8)) A"), sender: "bot2").detail.hasPrefix("this ask has 2 questions, so it cannot be decided with /decide"))
        XCTAssertEqual(decide(c, "bot2", t, answers: [ChatAnswerIn(questionID: "what", options: ["web"])]).detail, "give your answer to question note in words")
        XCTAssertEqual(decide(c, "bot2", t, answers: [ChatAnswerIn(questionID: "what", options: ["web"]), ChatAnswerIn(questionID: "what", skipped: true)]).detail,
                       "question what is answered twice")
        XCTAssertEqual(decide(c, "bot2", t, answers: [ChatAnswerIn(questionID: "what", skipped: true), ChatAnswerIn(questionID: "note", skipped: true)]).detail,
                       "question what is not optional, so it cannot be skipped")
        XCTAssertEqual(decide(c, "bot2", t, option: "web").detail.hasPrefix("this ask has 2 questions: send \"answers\""), true)
        XCTAssertEqual(decide(c, "bot2", t, answers: [ChatAnswerIn(questionID: "what", options: ["web"]), ChatAnswerIn(questionID: "note", skipped: true)]).state, "decided")
        XCTAssertEqual(askOf(c, t)?.decision?.label, "What: web; Note?: (skipped)")
        // an unverified typed /decide is refused
        var l = line("/decide \(t.prefix(8)) decline")
        l.verified = false
        XCTAssertTrue(c.post(l, sender: "bot2").detail.hasPrefix("/decide needs a sender verified by its own token"))
    }

    func testTheFirstOfEightConcurrentDecidersWins() throws {
        var ps = #"[{"name": "ada", "kind": "human", "deliver": "web"}, {"name": "bot1", "kind": "agent"}"#
        for i in 0..<8 { ps += #", {"name": "dec\#(i)", "kind": "agent", "roles": ["decider"]}"# }
        ps += "]"
        let c = try ChatConfig.resolve(data: Data(config(participants: ps).utf8), .init())
        try FileManager.default.createDirectory(atPath: dataDir, withIntermediateDirectories: true)
        try Data(#"{"room1": ["ada", "bot1", "dec0", "dec1", "dec2", "dec3", "dec4", "dec5", "dec6", "dec7"]}"#.utf8).write(to: URL(fileURLWithPath: dataDir + "/rooms.json"))
        let core = ChatServerCore(config: c, secrets: ChatSecrets(), release: "1", sessionsDir: dir + "/none")
        core.load(); core.startAsks(); cores.append(core)
        let names = (0..<8).map { "dec\($0)" }
        let id = askOK(core, "bot1", #"{"options":[{"id":"yes"}],"deciders":\#(ChatJSON.encodeString(.strings(names)))}"#)
        let box = ChatAskBox<[String]>([])
        DispatchQueue.concurrentPerform(iterations: 8) { i in
            let r = core.decide(room: "room1", who: names[i], ref: id, input: ChatDecideInput(option: "yes"), via: "agent", verified: true)
            box.with { $0.append(r.state) }
        }
        let states = box.with { $0 }
        XCTAssertEqual(states.filter { $0 == "decided" }.count, 1, "the first valid decision wins")
        XCTAssertEqual(states.filter { $0 == "refused" }.count, 7)
    }

    func testOncePerMsgIDAndPerXChatID() throws {
        let c = try core()
        let h = ChatPageHandler(core: c)
        let id = askOK(c, "bot1", Self.one + "")
        // the page, once per X-Chat-Id (the human, over the owner's socket)
        let xid = chatNewID()
        func page() -> ChatHTTPResponse {
            h.handle(ChatHTTPRequest(method: "POST", target: "/api/rooms/room1/messages/\(id.prefix(8))/decide", headers: ["x-chat-id": xid],
                                     body: Array(#"{"option":"copy"}"#.utf8), remoteIP: "", caller: .owner))
        }
        XCTAssertEqual(page().status, 200)
        let again = page()
        XCTAssertEqual(again.status, 200)
        XCTAssertEqual(try ChatJSON.parse(again.body).field("state"), .string("duplicate"))
        XCTAssertEqual(askOf(c, id)?.decision?.via, "page")
        // a line, once per msg_id
        let id2 = askOK(c, "bot3", #"{"options":[{"id":"yes"}],"deciders":["bot2"]}"#)
        let l = line("/decide \(id2.prefix(8)) yes")
        XCTAssertEqual(c.post(l, sender: "bot2").state, "decided")
        XCTAssertEqual(c.post(l, sender: "bot2").state, "duplicate")
        XCTAssertEqual(c.post(l, sender: "bot2").detail, "already done: decided")
    }
}

// MARK: - The life of an ask

final class ChatAskLifecycleTests: ChatAskTestCase {
    func soon(_ s: Double) -> String { ChatTime.now().adding(seconds: s).format() }

    func testAnAskExpiresWhileUpAndWhileDown() throws {
        let c = try core()
        let up = askOK(c, "bot1", #"{"options":[{"id":"yes"}],"expires_at":"\#(soon(0.8))"}"#)
        let down = askOK(c, "bot3", #"{"options":[{"id":"yes"}],"expires_at":"\#(soon(1.5))"}"#)
        waitFor("the first to expire") { askOf(c, up)?.state == "expired" }
        let d = try XCTUnwrap(askOf(c, up)?.decision)
        XCTAssertEqual([d.by, d.option, d.label, d.via], ["chat", "decline", "Decline", "expiry"])
        XCTAssertNil(d.sender); XCTAssertTrue(d.declined)
        XCTAssertEqual(askOf(c, down)?.state, "open")
        c.close(); cores.removeAll()
        usleep(1_800_000)
        let again = try core()
        XCTAssertEqual(askOf(again, down)?.state, "expired", "expired at the start, before anything answers")
        XCTAssertEqual(decide(again, "ada", up, option: "yes").detail, "this ask has expired")
    }

    func testAnAskSurvivesARestartByteForByte() throws {
        let c = try core()
        let id = askOK(c, "bot1", #"{"options":[{"id":"yes"}],"about":{"n":1}}"#)
        XCTAssertEqual(decide(c, "ada", id, option: "yes").state, "decided")
        let before = try XCTUnwrap(stored(c, id)).json
        c.close(); cores.removeAll()
        let after = try XCTUnwrap(stored(try core(), id)).json
        XCTAssertEqual(ChatJSON.encodeString(before), ChatJSON.encodeString(after))
    }

    func testTheLimitTheCooldownAndAWithdrawThatStartsNone() throws {
        let c = try core()
        let about = #""about":{"path":"~/x","mode":"ro"}"#
        let id = askOK(c, "bot1", #"{"options":[{"id":"yes"}],\#(about)}"#)
        XCTAssertEqual(ask(c, "bot1", Self.one).1.detail, "bot1 already has 1 open ask(s) in room room1, the most it may have: withdraw one or wait for its outcome")
        askOK(c, "bot1", Self.one, room: "room2")   // another room is not limited
        askOK(c, "bot3", Self.one)                   // another asker is not limited
        XCTAssertEqual(decide(c, "ada", id, decline: true).state, "decided")
        XCTAssertTrue(ask(c, "bot1", #"{"options":[{"id":"yes"}],"about":{"mode":"ro","path":"~/x"}}"#).1.detail
            .hasPrefix("an ask from bot1 about the same thing was declined or expired a moment ago: ask again after "))
        let other = askOK(c, "bot1", #"{"options":[{"id":"yes"}],"about":{"path":"~/y"}}"#)
        XCTAssertEqual(c.post(line("/withdraw #\(askOf(c, other)!.number)"), sender: "bot1").state, "withdrawn")
        askOK(c, "bot1", #"{"options":[{"id":"yes"}],"about":{"path":"~/y"}}"#)   // a withdraw starts no cooldown
    }

    func testTheMaxOpenSettingAndCooldownOff() throws {
        let c = try core(extra: #", "ask_max_open": 2, "ask_cooldown_seconds": -1"#)
        let a = askOK(c, "bot1", Self.one)
        askOK(c, "bot1", Self.one)
        XCTAssertEqual(ask(c, "bot1", Self.one).1.state, "refused")
        XCTAssertEqual(decide(c, "ada", a, decline: true).state, "decided")
        askOK(c, "bot1", Self.one)   // no cooldown
    }

    func testNoDeciderAfterTheRoleIsTakenOrTheDeciderLeaves() throws {
        let c = try core()
        let id = askOK(c, "bot1", #"{"options":[{"id":"yes"}],"deciders":["bot2"]}"#)
        c.close(); cores.removeAll()
        let c2 = try core(roles: false)   // the owner took the role away; the server restarted
        XCTAssertEqual(askOf(c2, id)?.noDecider, true)
        XCTAssertEqual(askOf(c2, id)?.state, "open")
        XCTAssertEqual(receive(c2, "bot1").first?.field("event")?.stringValue, "ask-no-decider")
        XCTAssertEqual(decide(c2, "bot2", id, option: "yes").detail, "bot2 does not have the decider role")
        // a decider that leaves the room
        let c3 = try core()
        let id2 = askOK(c3, "bot3", #"{"options":[{"id":"yes"}],"deciders":["bot2"]}"#)
        XCTAssertEqual(c3.post(line("/leave"), sender: "bot2").state, "queued")
        XCTAssertEqual(askOf(c3, id2)?.noDecider, true)
        // a reload that removes the decider
        let id3 = askOK(c3, "bot1", #"{"options":[{"id":"yes"}],"deciders":["bot2"]}"#, room: "room2")
        _ = c3.apply(participants: c3.people().filter { $0.name != "bot2" }, hashes: ChatSecrets())
        XCTAssertEqual(askOf(c3, id3, room: "room2")?.noDecider, true)
    }

    func testAClosedRoomExpiresItsOpenAsksOnceWithNoCooldown() throws {
        let c = try core()
        let id = askOK(c, "bot1", #"{"options":[{"id":"yes"}],"about":{"n":1}}"#)
        let set = try ChatJSON.parse(Array(#"{"version":1,"id":"c1","closed":{"rooms":{"room1":"demo"},"reasons":true}}"#.utf8))
        _ = ChatRoomControl.answer(set, core: c)
        XCTAssertEqual(askOf(c, id)?.state, "expired")
        let items = receive(c, "bot1")
        XCTAssertEqual(items.count, 1)
        XCTAssertTrue(items.first?.field("note")?.stringValue?.hasSuffix("expired: room room1 was closed, so its answer is the one set for expiry: decline (Decline).") ?? false)
        _ = ChatRoomControl.answer(set, core: c)   // sent again at every start: nothing is open
        XCTAssertTrue(receive(c, "bot1").isEmpty)
        let r = decide(c, "ada", id, option: "yes")
        XCTAssertEqual(r.detail, ChatRoomControl.closedText(room: "room1", workspace: "demo"))
        XCTAssertEqual(r.reason, ChatRoomControl.reasonWord)
        _ = ChatRoomControl.answer(try ChatJSON.parse(Array(#"{"version":1,"id":"c2","closed":{"rooms":{}}}"#.utf8)), core: c)
        askOK(c, "bot1", #"{"options":[{"id":"yes"}],"about":{"n":1}}"#)   // the same about at once: no cooldown
    }

    func testNumbersAreUniqueAcrossRoomsAndNeverReused() throws {
        let c = try core()
        let a = askOK(c, "bot1", Self.one)
        let b = askOK(c, "bot1", Self.one, room: "room2")
        XCTAssertEqual([askOf(c, a)?.number, askOf(c, b, room: "room2")?.number], [1, 2])
        XCTAssertEqual(c.askTimers.scheduled.count, 2)
        // the room removed: its timers go, its numbers stay used
        let last = (try c.store("room2")).lastSeq()
        XCTAssertNoThrow(try c.removeRoom("room2", lastSeq: last, id: "rm_1").get())
        XCTAssertEqual(c.askTimers.scheduled.map(\.room), ["room1"])
        XCTAssertEqual(decide(c, "ada", "#1", option: "copy").state, "decided", "#N names an ask")
        let n3 = askOK(c, "bot1", Self.one)
        XCTAssertEqual(askOf(c, n3)?.number, 3)
        c.close(); cores.removeAll()
        try? FileManager.default.removeItem(atPath: dataDir + "/rooms/room1.db")
        let c2 = try core()
        XCTAssertEqual(askOf(c2, askOK(c2, "bot1", Self.one))?.number, 4, "the high-water mark outlives every room")
        XCTAssertEqual(decide(c2, "ada", "#99", option: "copy").detail, "no ask #99 in room room1")
    }

    func testAsksOffRefuseInTheReferencesWordsAndChangeNothingElse() throws {
        let on = ChatProtocol.description(rooms: [:], defaultRoom: "room1", asks: true)
        let c = try core(extra: #", "no_asks": true"#)
        XCTAssertEqual(ask(c, "bot1", Self.one).1.detail, "asks are off on this server")
        XCTAssertEqual(c.post(line("/decide 41fa46f4 yes"), sender: "bot2").detail, "asks are off on this server")
        XCTAssertEqual(c.post(line("/withdraw 41fa46f4"), sender: "bot1").detail, "asks are off on this server")
        let p = c.protocolJSON()
        XCTAssertEqual(p.field("features"), .array([]))
        XCTAssertNil(p.field("asks"))
        XCTAssertEqual(p.field("version"), on.field("version"), "asks off never changes the version")
        XCTAssertEqual(c.askLookup(name: "bot1", room: "room1", ref: "41fa46f4").status, 404)
        XCTAssertTrue(try c.messagePage(room: "room1", after: 0, before: 0, limit: 50, viewer: "").messages.isEmpty)
    }

}

// MARK: - The outcome, to the asker

final class ChatAskDeliveryTests: ChatAskTestCase {
    var listeners: [TestWebhookListener] = []
    override func tearDownWithError() throws {
        for l in listeners { l.stop() }
        try super.tearDownWithError()
    }

    func testTheOutcomeByWebhookPollAndInboxAndTheStream() throws {
        let l = try TestWebhookListener(answer: { _ in .status(200) })
        listeners.append(l)
        let sessions = dir + "/sessions"
        try FileManager.default.createDirectory(atPath: sessions, withIntermediateDirectories: true)
        let s = try TestClaudeSession(name: "bot4", sessionsDir: sessions)
        defer { s.stop() }
        let ps = """
            [{"name": "ada", "kind": "human", "deliver": "web"}, {"name": "bot1", "kind": "agent"},
             {"name": "bot2", "kind": "agent", "roles": ["decider"]}, {"name": "bot3", "kind": "grok-bot", "deliver": "webhook", "webhook": "bot3"},
             {"name": "bot4", "kind": "claude-session", "deliver": "inbox-socket", "session": "bot4"}]
            """
        try Data(#"{"room1": ["ada", "bot1", "bot2", "bot3", "bot4"]}"#.utf8).write(to: URL(fileURLWithPath: dataDir + "/rooms.json"))
        let sec = try ChatSecrets.parse(Data(#"{"version": 1, "tokens": {}, "webhooks": {"bot3": {"url": "\#(l.url)/hook", "header": ""}}}"#.utf8))
        let c = try core(participants: ps, secrets: sec, sessionsDir: sessions)
        let sub = c.subscribe()
        defer { c.unsubscribe(sub); sub.cancel() }
        let events = ChatAskBox<[ChatEvent]>([])
        Task.detached {
            while case .event(let e) = await sub.next() { if e.kind == "ask" { events.with { $0.append(e) } } }
        }
        // by webhook
        let w = askOK(c, "bot3", #"{"options":[{"id":"yes","label":"Yes"}],"about":{"task":42},"deciders":["bot2"]}"#)
        XCTAssertEqual(decide(c, "bot2", w, option: "yes").state, "decided")
        waitFor("the webhook outcome") { l.calls.contains { $0.json?["event"] as? String == "chan-ask-outcome" } }
        let body = try XCTUnwrap(l.calls.first { $0.json?["event"] as? String == "chan-ask-outcome" }?.json)
        XCTAssertEqual(body["ask_id"] as? String, w)
        XCTAssertEqual(body["decided_by"] as? String, "bot2")
        XCTAssertEqual(body["decider_role"] as? Bool, true)
        XCTAssertEqual((body["about"] as? [String: Any])?["task"] as? Int, 42)
        XCTAssertTrue((body["message_text"] as? String ?? "").hasPrefix("[switchboard] Your ask \(w.prefix(8)) in room room1 was decided by bot2 (bot, "))
        // by poll
        let p = askOK(c, "bot1", Self.one)
        XCTAssertEqual(decide(c, "ada", p, decline: true, room: "room1").state, "decided")
        let item = try XCTUnwrap(receive(c, "bot1").first { $0.field("event")?.stringValue == "ask-outcome" })
        XCTAssertEqual(item.field("type"), .string("ask"))
        XCTAssertEqual(item.field("from"), .string("ada"))
        XCTAssertEqual(item.field("option"), .string("decline"))
        XCTAssertTrue(item.field("delivery")?.stringValue?.hasPrefix("notice:") ?? false)
        // by inbox, and a refused /decide is told to the session alone
        let i = askOK(c, "bot4", Self.one)
        XCTAssertEqual(c.post(line("/decide \(i.prefix(8)) copy"), sender: "bot4").state, "refused")
        XCTAssertEqual(decide(c, "ada", i, option: "copy").state, "decided")
        waitFor("the refusal and the outcome in the session's inbox") {
            s.texts.contains { $0 == "[switchboard] Your /decide was refused, and nothing was written in the room: the asker cannot decide its own ask" }
                && s.texts.contains { $0.hasPrefix("[room room1 · ask \(i.prefix(8)) · decided] Your ask \(i.prefix(8)) in room room1 was decided by ada") }
        }
        // the stream: an ask event with the whole message for each change of state
        waitFor("three ask events") { events.with { $0.count } == 3 }
        let last = try XCTUnwrap(events.with { $0.last })
        XCTAssertEqual(last.room, "room1")
        XCTAssertEqual(last.message?.msgID, i)
        XCTAssertEqual(last.message?.ask?.state, "decided")
    }
}

// MARK: - Locks

/// The lock order (ChatAsks.swift): posts of asks, decisions, the expiry timer, the closed set (the close gate) and
/// a room's removal, all at once, end — nothing waits on another forever.
final class ChatAskLockOrderTests: ChatAskTestCase {
    func testTimerCloseGateAndCoreLockNeverDeadlock() throws {
        let c = try core(extra: #", "ask_max_open": 1000, "ask_cooldown_seconds": -1"#)
        let done = DispatchGroup()
        let stop = Date().addingTimeInterval(3)
        let made = ChatAskBox<[String]>([])
        for who in ["bot1", "bot3"] {
            DispatchQueue.global().async(group: done) {
                while Date() < stop {
                    let l = Self.makeLine("Q?", room: Bool.random() ? "room1" : "room2",
                                      ask: #"{"options":[{"id":"yes"}],"deciders":["ada","bot2"],"expires_at":"\#(ChatTime.now().adding(seconds: 0.05).format())"}"#)
                    if c.post(l, sender: who).state == "queued" { made.with { $0.append(l.msgID) } }
                }
            }
        }
        DispatchQueue.global().async(group: done) {
            while Date() < stop {
                for id in made.with({ Array($0.suffix(5)) }) {
                    _ = c.decide(room: "room1", who: "bot2", ref: id, input: ChatDecideInput(option: "yes"), via: "agent", verified: true)
                }
            }
        }
        DispatchQueue.global().async(group: done) {
            var on = false
            while Date() < stop {
                on.toggle()
                c.setClosed(on ? ["room2": "demo"] : [:], reasons: false)
                _ = c.members("room1")
                usleep(2_000)
            }
            c.setClosed([:], reasons: false)
        }
        XCTAssertEqual(done.wait(timeout: .now() + 20), .success, "a deadlock between the timer, the close gate and the core's lock")
        XCTAssertFalse(made.with { $0.isEmpty })
        waitFor("every ask closed") { (try? c.store("room1"))?.openAsks().isEmpty == true && (try? c.store("room2"))?.openAsks().isEmpty == true }
    }
}
