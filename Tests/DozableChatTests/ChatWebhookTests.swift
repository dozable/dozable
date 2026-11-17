import Darwin
import DozableChat
import Foundation
import XCTest

/// Delivery by webhook, in-process with neutral names, against listeners the tests start on 127.0.0.1 (free ports):
/// the call and its body, the states, the tries and their schedule, the client's limits (no redirect followed, the
/// answer's body never read, a deadline on every call, nobody blocked by a slow webhook, no secret in a log, an error
/// text or the stream), edit notices, redelivery at start and nothing delivered twice.
final class ChatWebhookTests: XCTestCase {
    static let humanToken = "ada-token-0123456789abcdef"
    static let headerSecret = "Bearer hook-secret-0123456789abcdef"
    var dataDir = ""
    var cores: [ChatServerCore] = []
    var listeners: [TestWebhookListener] = []

    override func tearDown() {
        for c in cores { c.close() }
        for l in listeners { l.stop() }
        if !dataDir.isEmpty { try? FileManager.default.removeItem(atPath: dataDir) }
    }

    func listener(_ answer: @escaping @Sendable (Int) -> TestWebhookListener.Answer = { _ in .status(200) }) throws -> TestWebhookListener {
        let l = try TestWebhookListener(answer: answer)
        listeners.append(l)
        return l
    }

    /// A core whose bots' webhooks are the given addresses (nil: no entry), with short tries for a test.
    func core(bot1: String?, bot2: String? = nil, header: String = headerSecret, backoff: [Double] = [0, 0.2, 0.4],
              timeout: Double = 2, log: ChatLog = .none, freshDir: Bool = true) throws -> ChatServerCore {
        if freshDir || dataDir.isEmpty {
            if !dataDir.isEmpty { try? FileManager.default.removeItem(atPath: dataDir) }
            dataDir = FileManager.default.temporaryDirectory.appendingPathComponent("chat-webhook-\(UUID().uuidString)").path
        }
        let json = """
            {"data_dir": "\(dataDir)", "default_room": "room1", "secrets_file_only": true,
             "test_owned_addresses": ["127.0.0.1"],
             "participants": [{"name": "ada", "kind": "human", "deliver": "web"},
                              {"name": "bot1", "kind": "grok-bot", "deliver": "webhook", "webhook": "bot1"},
                              {"name": "bot2", "kind": "grok-bot", "deliver": "webhook", "webhook": "bot2"}],
             "rooms": {"room1": ["ada", "bot1", "bot2"]}}
            """
        let c = try ChatConfig.parse(Data(json.utf8))
        try c.check()
        var hooks: [String] = []
        if let bot1 { hooks.append(#""bot1": {"url": \#(String(decoding: ChatJSON.encode(.string(bot1)), as: UTF8.self)), "header": "\#(header)"}"#) }
        if let bot2 { hooks.append(#""bot2": {"url": "\#(bot2)", "header": ""}"#) }
        let sec = try ChatSecrets.parse(Data(#"{"version": 1, "tokens": {"ada": "\#(Self.humanToken)"}, "webhooks": {\#(hooks.joined(separator: ","))}}"#.utf8))
        let core = ChatServerCore(config: c, secrets: sec, release: "1.2.3", log: log,
                                  sessionsDir: (dataDir as NSString).appendingPathComponent("no-sessions"))
        core.webhookBackoff = backoff
        core.webhookTimeout = timeout
        core.load()
        cores.append(core)
        return core
    }

    @discardableResult
    func humanSays(_ core: ChatServerCore, _ text: String) -> String {
        var l = ChatLine()
        l.msgID = chatNewID(); l.type = "user"; l.hasBody = true; l.room = "room1"; l.content = text; l.msgV = 1
        XCTAssertEqual(core.post(l, sender: "ada").state, "queued")
        return l.msgID
    }

    func message(_ core: ChatServerCore, _ id: String) -> ChatStored? {
        (try? core.messagePage(room: "room1", after: 0, before: 0, limit: 500, viewer: ""))?.messages.first { $0.msgID == id }
    }

    func states(_ core: ChatServerCore, _ id: String, _ who: String) -> [ChatState] {
        message(core, id)?.states.filter { $0.recipient == who } ?? []
    }

    /// Waits until who has the state for the message; the states it has then.
    @discardableResult
    func wait(_ core: ChatServerCore, _ id: String, _ who: String, _ state: String, seconds: Double = 10) -> [ChatState] {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until {
            let s = states(core, id, who)
            if s.contains(where: { $0.state == state }) { return s }
            usleep(20_000)
        }
        XCTFail("\(who) never had \(state) for \(id): \(states(core, id, who).map(\.state))")
        return states(core, id, who)
    }

    // MARK: the call

    func testTheReferenceScheduleAndDeadlineAreTheDefaults() throws {
        let c = try core(bot1: nil)
        let fresh = ChatServerCore(config: c.config, secrets: ChatSecrets(), release: "1", sessionsDir: "/nonexistent")
        XCTAssertEqual(fresh.webhookBackoff, [0, 5, 20], "tried at once, after 5 s, after 20 s more")
        XCTAssertEqual(fresh.webhookTimeout, 30)
        XCTAssertEqual(fresh.redeliverAfter, 24 * 3600)
    }

    func testAWebhookIsCalledWithTheMessageAndTheStoredHeader() throws {
        let l = try listener()
        let core = try core(bot1: l.url + "/hook/bot1", header: "Authorization:  " + Self.headerSecret + " ")
        let id = humanSays(core, "hello @bot1 <b>")
        let s = wait(core, id, "bot1", "delivered")
        XCTAssertEqual(s.map(\.state), ["queued", "woken", "delivered"])
        XCTAssertTrue(s[1].detail.hasPrefix("its webhook accepted it (200) in "), s[1].detail)
        XCTAssertEqual(s[1].detail, s[2].detail)
        let call = try XCTUnwrap(l.calls.first)
        XCTAssertEqual(call.path, "/hook/bot1")
        XCTAssertEqual(call.headers["authorization"], Self.headerSecret, "the stored value, without its 'Authorization:' prefix")
        XCTAssertEqual(call.headers["content-type"], "application/json")
        let body = try XCTUnwrap(call.json)
        XCTAssertEqual(body["event"] as? String, "chan-message")
        XCTAssertEqual(body["msg_id"] as? String, id)
        XCTAssertEqual(body["message_text"] as? String, "[switchboard] room room1, message \(id) from ada\n\nhello @bot1 <b>")
        XCTAssertEqual(body["addressed_to_you"] as? Bool, true)
        let raw = String(decoding: call.body, as: UTF8.self)
        let escaped = "\\" + "u003cb" + "\\" + "u003e"   // the six-character escapes, spelled out
        XCTAssertTrue(raw.contains(escaped) && !raw.contains("<b>"), "< and > escaped as the reference writes them")
        XCTAssertTrue(raw.hasPrefix(#"{"addressed_to_you":"#), "keys in order")
        // a reaction, a command and an edit of nothing new wake nobody
        XCTAssertEqual(core.react(room: "room1", sender: "ada", msgID: id, what: "like").state, "added")
        usleep(300_000)
        XCTAssertEqual(l.calls.count, 1)
    }

    func testTheTextIsCutAt600CharactersNotBytes() throws {
        let l = try listener()
        let core = try core(bot1: l.url)
        let long = String(repeating: "é", count: 650)
        let id = humanSays(core, long)
        wait(core, id, "bot1", "delivered")
        let body = try XCTUnwrap(l.calls.first?.json)
        XCTAssertEqual(body["text"] as? String, String(repeating: "é", count: 600) + " … (cut)")
        XCTAssertEqual((body["message"] as? [String: Any])?["content"] as? String, long)
    }

    // MARK: tries and failures

    func testThreeTriesOnTheScheduleThenFailedWithTheLastStatus() throws {
        let l = try listener { _ in .status(500) }
        let core = try core(bot1: l.url, backoff: [0, 0.3, 0.6])
        let id = humanSays(core, "never accepted")
        let s = wait(core, id, "bot1", "failed")
        XCTAssertEqual(s.map(\.state), ["queued", "failed"])
        XCTAssertEqual(s.last?.detail, "webhook try 3: status 500")
        let at = l.calls.map(\.at)
        XCTAssertEqual(at.count, 3)
        XCTAssertGreaterThanOrEqual(at[1].timeIntervalSince(at[0]), 0.28)
        XCTAssertGreaterThanOrEqual(at[2].timeIntervalSince(at[1]), 0.58)
        XCTAssertEqual(l.calls[0].body, l.calls[2].body, "each try sends the same bytes")
    }

    func testARetryThatIsAcceptedIsDelivered() throws {
        let l = try listener { $0 == 0 ? .status(503) : .status(204) }
        let core = try core(bot1: l.url)
        let id = humanSays(core, "try twice")
        let s = wait(core, id, "bot1", "delivered")
        XCTAssertEqual(s.map(\.state), ["queued", "woken", "delivered"])
        XCTAssertTrue(s[2].detail.hasPrefix("its webhook accepted it (204)"), s[2].detail)
        XCTAssertEqual(l.calls.count, 2)
    }

    func testNoWebhookAddressFailsAtOnce() throws {
        let core = try core(bot1: nil)
        let id = humanSays(core, "nowhere to go")
        XCTAssertEqual(wait(core, id, "bot1", "failed").last?.detail, "no webhook address for bot1 in the file store or the Keychain")
    }

    func testARedirectIsNotFollowed() throws {
        let other = try listener()
        let l = try listener { _ in .redirect(other.url + "/elsewhere") }
        let core = try core(bot1: l.url, backoff: [0, 0.05, 0.05])
        let id = humanSays(core, "go elsewhere")
        XCTAssertEqual(wait(core, id, "bot1", "failed").last?.detail, "webhook try 3: status 302")
        XCTAssertEqual(l.calls.count, 3)
        XCTAssertEqual(other.connections, 0, "the address a redirect names is never dialled")
    }

    func testTheAnswersBodyIsNotRead() throws {
        let l = try listener { _ in .endless }
        let core = try core(bot1: l.url, timeout: 5)
        let started = Date()
        let id = humanSays(core, "a big answer")
        let s = wait(core, id, "bot1", "delivered")
        XCTAssertLessThan(Date().timeIntervalSince(started), 3, "the call ends at the answer's head")
        XCTAssertTrue(s.last?.detail.hasPrefix("its webhook accepted it (200)") ?? false)
        usleep(300_000)
        XCTAssertLessThan(l.bytesSent, 16 << 20, "the client stopped reading: \(l.bytesSent) bytes were written")
    }

    func testADeadWebhookTimesOutAndBlocksNeitherPostingNorAnotherRecipient() throws {
        let dead = try listener { _ in .hang }
        let fine = try listener()
        let core = try core(bot1: dead.url, bot2: fine.url, backoff: [0, 0.05, 0.05], timeout: 0.5)
        let t0 = Date()
        let id = humanSays(core, "one is dead")
        XCTAssertLessThan(Date().timeIntervalSince(t0), 0.3, "posting does not wait for a webhook")
        wait(core, id, "bot2", "delivered", seconds: 3)
        XCTAssertFalse(states(core, id, "bot1").contains { $0.state == "failed" }, "bot2 was not kept waiting behind bot1")
        let s = wait(core, id, "bot1", "failed", seconds: 6)
        XCTAssertEqual(s.last?.detail,
                       "webhook try 3: could not reach the webhook (context deadline exceeded (Client.Timeout exceeded while awaiting headers))")
        XCTAssertEqual(dead.calls.count, 3)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 4, "three tries of 0.5 s each")
    }

    func testNoSecretReachesALogAnErrorTextOrTheStream() throws {
        let lines = LockedLines()
        let secretURL = "http://127.0.0.1:\(chatTestClosedPort())/hook/url-secret-path?key=url-secret-query"
        let core = try core(bot1: secretURL, backoff: [0, 0.05, 0.05], log: ChatLog { lines.add($0) })
        let sub = core.subscribe()
        let id = humanSays(core, "to a closed port")
        let s = wait(core, id, "bot1", "failed")
        XCTAssertEqual(s.last?.detail, "webhook try 3: could not reach the webhook (connection refused)")
        // an edit notice to the same address fails the same way, and says nothing more
        XCTAssertEqual(core.edit(room: "room1", sender: "ada", ref: id, text: "changed").state, "edited")
        usleep(500_000)
        sub.cancel()
        var frames = ""
        while true {
            let next = runBlocking { await sub.next() }
            guard case .event(let e) = next else { break }
            frames += String(decoding: e.frame, as: UTF8.self)
        }
        core.unsubscribe(sub)
        let page = String(decoding: ChatJSON.encode(.array((try core.messagePage(room: "room1", after: 0, before: 0, limit: 50, viewer: "")).messages.map(\.json))), as: UTF8.self)
        for text in [lines.all.joined(separator: "\n"), frames, page] {
            for secret in ["url-secret-path", "url-secret-query", "hook-secret", "127.0.0.1:"] {
                XCTAssertFalse(text.contains(secret), "\(secret) appears in: \(text.prefix(400))")
            }
        }
        XCTAssertFalse(lines.all.isEmpty, "the failure was logged")
        XCTAssertFalse(frames.isEmpty, "the stream carried the states")
    }

    // MARK: notices

    func testAnEditIsToldToABotThatWasHandedTheMessage() throws {
        let l = try listener()
        let core = try core(bot1: l.url)
        let id = humanSays(core, "first text")
        wait(core, id, "bot1", "delivered")
        XCTAssertEqual(core.edit(room: "room1", sender: "ada", ref: id, text: "second text").state, "edited")
        let until = Date().addingTimeInterval(5)
        while l.calls.count < 2 && Date() < until { usleep(20_000) }
        let notice = try XCTUnwrap(l.calls.last?.json)
        XCTAssertEqual(notice["event"] as? String, "chan-message-edited")
        XCTAssertEqual(notice["text"] as? String, "second text")
        XCTAssertEqual(notice["message_text"] as? String,
                       "[switchboard] room room1, message \(id) from ada, edited\n\nsecond text\n\nThis edits msg \(id.prefix(8)) and replaces the text you were given before.")
        XCTAssertEqual(Set(notice.keys), ["event", "protocol_version", "room", "msg_id", "from", "text", "note", "message_text"])
    }

    // MARK: the hold and redelivery at start

    func testAHeldMessageGoesOutWhenTheHumanPosts() throws {
        let l = try listener()
        let c = try core(bot1: l.url)
        XCTAssertEqual(c.post(ChatLineHelper.line("/hold 1"), sender: "ada").state, "queued")
        let a = ChatLineHelper.line("from bot2, one"), b = ChatLineHelper.line("from bot2, two")
        XCTAssertEqual(c.post(a, sender: "bot2").state, "queued")
        XCTAssertEqual(c.post(b, sender: "bot2").state, "queued")
        wait(c, a.msgID, "bot1", "delivered")
        XCTAssertEqual(states(c, b.msgID, "bot1").map(\.state), ["held"])
        let h = humanSays(c, "go on")
        wait(c, h, "bot1", "delivered")
        wait(c, b.msgID, "bot1", "delivered")
        let order = l.calls.compactMap { $0.json?["msg_id"] as? String }
        XCTAssertEqual(order, [a.msgID, b.msgID, h], "what was held goes out first, in order")
    }

    func testWhatWaitedAtAStopIsHandedOverOnceAtTheNextStart() throws {
        let first = try listener { _ in .status(500) }
        let c1 = try core(bot1: first.url, backoff: [0, 30])
        let id = humanSays(c1, "interrupted")
        let until = Date().addingTimeInterval(5)
        while first.calls.isEmpty && Date() < until { usleep(20_000) }
        XCTAssertEqual(states(c1, id, "bot1").map(\.state), ["queued"], "waiting for its second try")
        let t0 = Date()
        c1.close()
        XCTAssertLessThan(Date().timeIntervalSince(t0), 1, "a stop does not wait out a pause between tries")
        cores.removeAll()

        let second = try listener()
        let c2 = try core(bot1: second.url, freshDir: false)
        XCTAssertEqual(c2.redeliver(), 1)
        let s = wait(c2, id, "bot1", "delivered")
        XCTAssertEqual(s.map(\.state), ["queued", "woken", "delivered"])
        usleep(200_000)
        XCTAssertEqual(second.calls.count, 1)
        // delivered now: a further start hands nothing over again
        c2.close()
        cores.removeAll()
        let c3 = try core(bot1: second.url, freshDir: false)
        XCTAssertEqual(c3.redeliver(), 0, "nothing delivered twice")
        usleep(200_000)
        XCTAssertEqual(second.calls.count, 1)
    }

    /// The entry is the truth at each try: a message still waiting for a bot whose entry was CHANGED (the daemon restarts
    /// its server with the new one) goes to the new address with the new Authorization value — never the old ones. One
    /// whose entry was REMOVED fails at once and goes nowhere.
    func testAWaitingMessageFollowsAChangedEntryAndFailsWhenItIsRemoved() throws {
        let old = try listener { _ in .status(500) }
        let c1 = try core(bot1: old.url + "/old", header: "Bearer old-secret-0123456789", backoff: [0, 30])
        let id = humanSays(c1, "waiting")
        let until = Date().addingTimeInterval(5)
        while old.calls.isEmpty && Date() < until { usleep(20_000) }
        c1.close()
        cores.removeAll()
        // changed: the new address and value
        let new = try listener()
        let c2 = try core(bot1: new.url + "/new", header: "Bearer new-secret-0123456789", freshDir: false)
        XCTAssertEqual(c2.redeliver(), 1)
        _ = wait(c2, id, "bot1", "delivered")
        XCTAssertEqual(new.calls.map(\.path), ["/new"])
        XCTAssertEqual(new.calls.first?.headers["authorization"], "Bearer new-secret-0123456789")
        XCTAssertEqual(old.calls.count, 1, "the old address is never called again")
        c2.close()
        cores.removeAll()
        // removed: a message waiting for it fails at once, with the protocol's words, and nothing is called
        let dead = try listener { _ in .status(500) }
        let c3 = try core(bot1: dead.url, backoff: [0, 30], freshDir: false)
        let id2 = humanSays(c3, "waiting again")
        let until2 = Date().addingTimeInterval(5)
        while dead.calls.isEmpty && Date() < until2 { usleep(20_000) }
        c3.close()
        cores.removeAll()
        let c4 = try core(bot1: nil, freshDir: false)
        _ = c4.redeliver()
        let s = wait(c4, id2, "bot1", "failed")
        XCTAssertEqual(s.last?.detail, "no webhook address for bot1 in the file store or the Keychain")
        usleep(200_000)
        XCTAssertEqual(dead.calls.count, 1)
        XCTAssertEqual(new.calls.count, 1)
    }

    /// The webhook client says which doz it is — the release number only, nothing of the machine or the user.
    func testTheUserAgentIsTheReleaseOnly() throws {
        let l = try listener()
        let core = try core(bot1: l.url)
        _ = wait(core, humanSays(core, "hi @bot1"), "bot1", "delivered")
        XCTAssertEqual(l.calls.first?.headers["user-agent"], "doz/1.2.3 chat")
        XCTAssertEqual(ChatURLSessionWebhook(release: "0.51.5-rc.1").userAgent, "doz/0.51.5 chat")
        XCTAssertEqual(ChatURLSessionWebhook().userAgent, "doz chat")
    }

    func testAMessageQueuedLongerThanTheLimitIsNotHandedOverAtStart() throws {
        let c1 = try core(bot1: "http://127.0.0.1:\(chatTestClosedPort())", backoff: [0, 30])
        let id = humanSays(c1, "old")
        usleep(300_000)
        c1.close()
        cores.removeAll()
        let l = try listener()
        let c2 = try core(bot1: l.url, freshDir: false)
        c2.redeliverAfter = 0
        XCTAssertEqual(c2.redeliver(), 0)
        XCTAssertEqual(states(c2, id, "bot1").map(\.state), ["queued"])
    }

    // MARK: reactions

    func testReactionsToggleWakeNobodyAndAreDoneOncePerID() throws {
        let core = try core(bot1: nil)
        let h = ChatPageHandler(core: core)
        let sub = core.subscribe()
        let id = humanSays(core, "react to me")
        XCTAssertEqual(core.react(room: "room1", sender: "bot1", msgID: String(id.prefix(8)), what: "LIKE").state, "added")
        XCTAssertEqual(message(core, id)?.reactions.map { "\($0.who):\($0.reaction):\($0.emoji)" }, ["bot1:like:\u{1F44D}"])
        XCTAssertEqual(core.react(room: "room1", sender: "bot1", msgID: id, what: "\u{1F44D}").state, "removed", "by its emoji: the same one")
        // the stream: added, then removed
        var reactions: [JValue] = []
        sub.cancel()
        while case .event(let e) = runBlocking({ await sub.next() }) { if e.kind == "reaction", let r = e.reaction { reactions.append(r) } }
        core.unsubscribe(sub)
        XCTAssertEqual(reactions.count, 2)
        XCTAssertNil(reactions.first?.field("removed"), "removed is left out of an added reaction")
        XCTAssertEqual(reactions.last?.field("removed"), .bool(true))
        // refusals, in the reference's words and order
        XCTAssertEqual(core.react(room: "nosuch", sender: "ada", msgID: id, what: "zzz").detail, #"no room "nosuch""#)
        XCTAssertEqual(core.react(room: "room1", sender: "ada", msgID: chatNewID(), what: "zzz").detail, ChatReactions.help)
        XCTAssertEqual(core.react(room: "room1", sender: "ada", msgID: chatNewID(), what: "like").detail, "no such message in room room1")
        for bad in ["a", "1", ":)", "", "\u{1F525}!", String(repeating: "\u{1F525}", count: 9)] {
            XCTAssertEqual(core.react(room: "room1", sender: "ada", msgID: id, what: bad).detail, ChatReactions.help, bad)
        }
        // a reaction line with its own msg_id is done once
        XCTAssertEqual(core.reactOnce(room: "room1", sender: "bot2", lineID: "react-1", msgID: id, what: "eyes").state, "added")
        XCTAssertEqual(core.reactOnce(room: "room1", sender: "bot2", lineID: "react-1", msgID: id, what: "eyes"),
                       ChatReceipt("duplicate", "already done: added"))
        // /react in a message
        var l = ChatLineHelper.line("/react ^\(id.prefix(8)) party")
        XCTAssertEqual(core.post(l, sender: "bot2"), ChatReceipt("added"))
        XCTAssertEqual(core.post(l, sender: "bot2"), ChatReceipt("duplicate", "already done: added"))
        l = ChatLineHelper.line("/react party")
        XCTAssertEqual(core.post(l, sender: "bot2").detail, "say which message: /react <start of its msg_id> like")
        // the page's call: once per X-Chat-Id, a body of at most 4096 bytes
        let key = chatNewID()
        let body = Array(#"{"msg_id":"\#(id)","reaction":"yes"}"#.utf8)
        let call = { h.handle(ChatHTTPRequest(method: "POST", target: "/api/rooms/room1/reactions", headers: ["x-chat-id": key], body: body, remoteIP: "127.0.0.1")) }
        XCTAssertEqual(call().text, #"{"detail":"","state":"added"}"# + "\n")
        XCTAssertEqual(call().text, #"{"detail":"already done: added","state":"duplicate"}"# + "\n")
        let big = h.handle(ChatHTTPRequest(method: "POST", target: "/api/rooms/room1/reactions",
                                           body: Array((#"{"msg_id":"x","reaction":""# + String(repeating: "x", count: 5000) + #""}"#).utf8), remoteIP: "127.0.0.1"))
        XCTAssertEqual(big.status, 400)
        // archived: refused in its own words on every path
        XCTAssertEqual(core.post(ChatLineHelper.line("/archive"), sender: "ada").state, "queued")
        let arch = "room room1 is archived: its messages cannot be reacted to. A human can reopen it with /unarchive"
        XCTAssertEqual(core.react(room: "room1", sender: "ada", msgID: id, what: "like").detail, arch)
        XCTAssertEqual(core.post(ChatLineHelper.line("/react ^\(id.prefix(8)) like"), sender: "bot1").detail, arch)
        // a delete erases every reaction
        XCTAssertEqual(core.post(ChatLineHelper.line("/unarchive"), sender: "ada").state, "queued")
        XCTAssertEqual(core.delete(room: "room1", who: "ada", ref: id).state, "deleted")
        XCTAssertEqual(message(core, id)?.reactions.count, 0)
        XCTAssertEqual(core.react(room: "room1", sender: "ada", msgID: id, what: "like").detail, "that message was deleted")
    }

    func testThePageReactionNeedsTheHumansTokenWhenTokensAreRequired() throws {
        let core = try core(bot1: nil)
        _ = core
        // with require_tokens on, a call without the human's token is 401 in the reference's words
        let json = """
            {"data_dir": "\(dataDir)-rt", "default_room": "room1", "secrets_file_only": true, "require_tokens": true,
             "test_owned_addresses": ["127.0.0.1"],
             "participants": [{"name": "ada", "kind": "human", "deliver": "web"}, {"name": "bot1", "kind": "grok-bot"}],
             "rooms": {"room1": ["ada", "bot1"]}}
            """
        addTeardownBlock { [dir = dataDir + "-rt"] in try? FileManager.default.removeItem(atPath: dir) }
        let c = try ChatConfig.parse(Data(json.utf8))
        let rt = ChatServerCore(config: c, secrets: try ChatSecrets.parse(Data(#"{"version":1,"tokens":{"ada":"\#(Self.humanToken)"}}"#.utf8)),
                                release: "1", sessionsDir: "/nonexistent")
        rt.load()
        cores.append(rt)
        let h = ChatPageHandler(core: rt)
        for headers in [[:], ["x-chat-token": "0000000000000000000000"]] {
            let r = h.handle(ChatHTTPRequest(method: "POST", target: "/api/rooms/room1/reactions", headers: headers,
                                             body: Array(#"{"msg_id":"x","reaction":"like"}"#.utf8), remoteIP: "127.0.0.1"))
            XCTAssertEqual(r.status, 401)
            XCTAssertEqual(r.text, #"{"error":"reacting needs the human's token"}"# + "\n")
        }
        let up = h.handle(ChatHTTPRequest(method: "POST", target: "/api/files?name=a.txt", body: [0x61], remoteIP: "127.0.0.1"))
        XCTAssertEqual(up.text, #"{"error":"uploading a file needs the human's token"}"# + "\n")
    }
}

/// Lines a test's log collected.
final class LockedLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ s: String) { lock.withLock { lines.append(s) } }
    var all: [String] { lock.withLock { lines } }
}

enum ChatLineHelper {
    static func line(_ text: String, room: String = "room1") -> ChatLine {
        var l = ChatLine()
        l.msgID = chatNewID(); l.type = "user"; l.hasBody = true; l.room = room; l.content = text; l.msgV = 1
        return l
    }
}

/// Runs an async call to its end from synchronous test code.
func runBlocking<T: Sendable>(_ f: @escaping @Sendable () async -> T) -> T {
    let box = ResultBox<T>()
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        box.value = await f()
        done.signal()
    }
    done.wait()
    return box.value!
}

final class ResultBox<T>: @unchecked Sendable { var value: T? }
