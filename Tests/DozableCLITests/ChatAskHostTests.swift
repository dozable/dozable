import Foundation
import XCTest
@testable import DozableChat
@testable import DozableHost

/// The daemon's ask operations (`chat-ask`, `chat-decide`, `chat-withdraw`, `chat-asks`) in an in-process core over a REAL
/// chat server core reached as the owner's socket reaches it (`ChatPageHandler`, caller `.owner`): a person asks, lists,
/// answers by option, letter, label, words and decline, and withdraws; every refusal is told in Dozable's words, decided by
/// the ask's state read after it; a decision is made once per action id; `#N` goes as `%23N`; chat off is unavailable.
/// Scratch folders only; no socket, no port.
final class ChatAskHostTests: XCTestCase {
    /// The real core behind the owner's socket, in-process.
    final class RealChat: WorkspaceChat, @unchecked Sendable {
        let handler: ChatPageHandler
        var calls: [(String, String, [(String, String)])] = []
        let lock = NSLock()
        init(_ core: ChatServerCore) { handler = ChatPageHandler(core: core) }
        func readiness() async -> WorkspaceChatReadiness { .ready }
        func rooms() throws -> Set<String> { ["room1"] }
        func makeRoom(_ name: String) throws {}
        func post(room: String, content: String) throws {}
        func invite(room: String, name: String) throws -> Bool { false }
        func ownerCall(_ method: String, _ target: String, body: JValue?, headers: [(String, String)]) throws -> (Int, JValue) {
            lock.withLock { calls.append((method, target, headers)) }
            var hs: [String: String] = [:]
            for (k, v) in headers { hs[k.lowercased()] = v }
            let res = handler.handle(ChatHTTPRequest(method: method, target: target, headers: hs, body: body.map { ChatJSON.encode($0) } ?? [],
                                                     remoteIP: "", caller: .owner))
            return (res.status, (try? ChatJSON.parse(res.body)) ?? .null)
        }
    }

    final class OffChat: WorkspaceChat, @unchecked Sendable {
        func readiness() async -> WorkspaceChatReadiness { .off }
        func rooms() throws -> Set<String> { [] }
        func makeRoom(_ name: String) throws {}
        func post(room: String, content: String) throws {}
        func invite(room: String, name: String) throws -> Bool { false }
    }

    var dir = ""
    var cores: [ChatServerCore] = []

    override func setUpWithError() throws {
        dir = "/tmp/doz-askhost-\(getpid())-\(UUID().uuidString.prefix(6))"
        try FileManager.default.createDirectory(atPath: dir + "/data", withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    override func tearDownWithError() throws {
        for c in cores { c.close() }
        try? FileManager.default.removeItem(atPath: dir)
    }

    func chatCore(extra: String = #", "ask_max_open": 10, "ask_cooldown_seconds": -1"#) throws -> ChatServerCore {
        let everyone = #"["ada", "bot1", "bot2", "bot3"]"#
        let config = """
            {"line_port": 0, "http_port": 0, "data_dir": "\(dir)/data", "default_room": "room1", "participants": [{"name": "ada", "kind": "human", "deliver": "web"},
             {"name": "bot1", "kind": "agent"}, {"name": "bot2", "kind": "agent", "roles": ["decider"]}, {"name": "bot3", "kind": "agent"}],
             "rooms": {"room1": \(everyone)}, "allow": ["127.0.0.1"], "require_tokens": true, "agent_addresses": ["127.0.0.0/8"],
             "secrets_file_only": true, "bind": "127.0.0.1"\(extra)}
            """
        let c = try ChatConfig.resolve(data: Data(config.utf8), .init())
        let core = ChatServerCore(config: c, secrets: ChatSecrets(), release: "1.2.3", sessionsDir: dir + "/no-sessions")
        core.load()
        core.startAsks()
        cores.append(core)
        return core
    }

    func host(_ chat: WorkspaceChat?) async -> HostCore {
        let c = HostCore(store: DozableStore(root: URL(fileURLWithPath: dir + "/store")), readOnly: false, version: "test")
        await c.setWorkspaceChat(chat)
        return c
    }

    /// A bot's ask, posted with its token as the line port would: its msg_id.
    @discardableResult
    func botAsk(_ core: ChatServerCore, _ who: String, _ spec: String, text: String = "Ship it today?") -> String {
        var l = ChatLine()
        l.msgID = chatNewID(); l.content = text; l.room = "room1"; l.msgV = 1; l.type = "user"; l.hasBody = true; l.verified = true
        l.kind = "ask"; l.ask = try! ChatAskSpec.read(try! ChatJSON.parse(Array(spec.utf8)))
        let r = core.post(l, sender: who)
        XCTAssertEqual(r.state, "queued", r.detail)
        return l.msgID
    }

    func op(_ c: HostCore, _ op: HostOp, _ q: ChatAskRequest) async -> HostMessage {
        var r = HostRequest(op)
        r.chatAsk = q
        return await c.handle(r)
    }

    func decide(_ c: HostCore, _ ask: String, reply: String? = nil, decline: Bool = false, text: String? = nil, actionID: String? = nil) async -> HostMessage {
        var q = ChatAskRequest(room: "room1", ask: ask)
        q.reply = reply
        if decline { q.decline = true; q.text = text }
        q.actionID = actionID
        return await op(c, .chatDecide, q)
    }

    func listed(_ c: HostCore, room: String? = nil) async throws -> [OpenAsk] {
        let m = await op(c, .chatAsks, ChatAskRequest(room: room))
        XCTAssertNil(m.error, m.error?.message ?? "")
        return try (m.result ?? .null).decode(ChatAsksListing.self).asks
    }

    func outcome(_ m: HostMessage, file: StaticString = #filePath, line: UInt = #line) throws -> ChatAskOutcome {
        XCTAssertNil(m.error, m.error?.message ?? "", file: file, line: line)
        return try (m.result ?? .null).decode(ChatAskOutcome.self)
    }

    static let two = #"{"options": [{"id": "now", "label": "Now"}, {"id": "next", "label": "Next"}], "free_text": false}"#

    func testAPersonAsksListsAnswersAndWithdraws() async throws {
        let core = try chatCore()
        let c = await host(RealChat(core))
        var q = ChatAskRequest(room: "room1")
        q.question = "Which build goes out?"
        q.spec = .object(["questions": .array([.object(["options": .array([.object(["id": .string("web"), "label": .string("Web")])])])]),
                          "deciders": .array([.string("bot2")])])
        let asked = try outcome(await op(c, .chatAsk, q))
        XCTAssertEqual(asked.state, "asked")
        XCTAssertEqual(asked.ask, "#1")
        XCTAssertEqual(asked.deciders, ["bot2"])
        let listing = ChatAsksListing(asks: try await listed(c))
        XCTAssertEqual(listing.asks.map(\.label), ["#1"])
        XCTAssertEqual(listing.asks.first?.options, ["Web"])
        XCTAssertEqual(listing.asks.first?.from, "ada")
        let v1 = try await listed(c, room: "room2")
        XCTAssertEqual(v1, [])
        // A bare number is #N in clients.
        let w = try outcome(await op(c, .chatWithdraw, ChatAskRequest(room: "room1", ask: "1")))
        XCTAssertEqual(w.state, "withdrawn")
        XCTAssertEqual(w.askState, "withdrawn")
        let v2 = try await listed(c)
        XCTAssertEqual(v2, [])

        // By letter, by label, by words, decline.
        botAsk(core, "bot1", Self.two)
        let v3 = try outcome(await decide(c, "#2", reply: "b")).summary
        XCTAssertEqual(v3, "B. Next")
        botAsk(core, "bot1", Self.two)
        let v4 = try outcome(await decide(c, "3", reply: "now")).summary
        XCTAssertEqual(v4, "A. Now")
        botAsk(core, "bot1", #"{"questions": [{"options": [{"id": "yes", "label": "Ship it"}]}]}"#)
        let v5 = try outcome(await decide(c, "#4", reply: "ship IT")).summary
        XCTAssertEqual(v5, "A. Ship it")
        botAsk(core, "bot1", #"{"questions": [{"options": [{"id": "yes", "label": "Yes"}]}]}"#)
        let v6 = try outcome(await decide(c, "#5", reply: "after lunch, please")).summary
        XCTAssertEqual(v6, "\u{201C}after lunch, please\u{201D}")
        botAsk(core, "bot1", Self.two)
        let d = try outcome(await decide(c, "#6", decline: true, text: "not now"))
        XCTAssertEqual(d.summary, "declined: not now")
        XCTAssertEqual(d.decidedBy, "ada")
    }

    func testEveryRefusalIsToldInDozablesWords() async throws {
        let core = try chatCore()
        let c = await host(RealChat(core))
        func refused(_ m: HostMessage) -> String { m.error?.message ?? "(not refused)" }
        // answered
        botAsk(core, "bot1", Self.two)
        _ = try outcome(await decide(c, "#1", reply: "A"))
        let v7 = refused(await decide(c, "#1", reply: "B"))
        XCTAssertEqual(v7, "It was already answered: decided by Ada.")
        // 751 (D10): exit 3, already-answered — never 1 failed.
        let again = await decide(c, "#1", reply: "B")
        XCTAssertEqual(again.error?.code, .alreadyAnswered)
        XCTAssertEqual(again.error.map(ExitCodes.exit(for:)), 3)
        // expired
        let soon = ISO8601DateFormatter().string(from: Date().addingTimeInterval(2))
        botAsk(core, "bot1", #"{"options": [{"id": "a", "label": "A"}], "expires_at": "\#(soon)"}"#)
        try await Task.sleep(for: .seconds(3))
        let v8 = refused(await decide(c, "#2", reply: "A"))
        XCTAssertEqual(v8, "This ask expired: its answer was decline.")
        // withdrawn
        botAsk(core, "bot1", Self.two)
        XCTAssertEqual(core.withdraw(room: "room1", who: "bot1", ref: "#3", via: "agent").state, "withdrawn")
        let v9 = refused(await decide(c, "#3", decline: true))
        XCTAssertEqual(v9, "It was withdrawn by the one who asked it.")
        // not one of its deciders
        botAsk(core, "bot1", #"{"options": [{"id": "a", "label": "A"}], "deciders": ["bot2"]}"#)
        let v10 = refused(await decide(c, "#4", reply: "A"))
        XCTAssertEqual(v10, "You are not one of this ask's deciders (only Bot2 is).")
        // the asker
        var q = ChatAskRequest(room: "room1")
        q.question = "Lunch?"
        q.spec = .object(["questions": .array([.object([:])]), "deciders": .array([.string("bot2")])])
        _ = try outcome(await op(c, .chatAsk, q))
        let v11 = refused(await decide(c, "#5", reply: "yes"))
        XCTAssertEqual(v11, "You asked this: the one who asks cannot answer it.")
        // only its asker withdraws
        botAsk(core, "bot1", Self.two)
        let v12 = refused(await op(c, .chatWithdraw, ChatAskRequest(room: "room1", ask: "#6")))
        XCTAssertEqual(v12, "Only the one who asked it can withdraw it.")
        // a bad answer: the options listed, nothing sent
        let v13 = refused(await decide(c, "#6", reply: "maybe"))
        XCTAssertEqual(v13, "That is not one of this ask's options: A. Now, B. Next, or decline.")
        // 751 (D10): each refusal's code — exit 3 for a closed ask or one not yours; a bad answer stays failed.
        let codes: [(HostMessage, HostError.Code)] = [
            (await decide(c, "#2", reply: "A"), .invalidPhase),           // expired
            (await decide(c, "#3", decline: true), .invalidPhase),        // withdrawn
            (await decide(c, "#4", reply: "A"), .notOwned),               // not one of its deciders
            (await decide(c, "#5", reply: "yes"), .notOwned),             // the asker
            (await op(c, .chatWithdraw, ChatAskRequest(room: "room1", ask: "#6")), .notOwned),
            (await decide(c, "#6", reply: "maybe"), .failed),
        ]
        for (i, (m, want)) in codes.enumerated() { XCTAssertEqual(m.error?.code, want, "refusal \(i)") }
        // no such ask
        let none = await decide(c, "#99", reply: "A")
        XCTAssertEqual(none.error?.code, .notFound)
    }

    func testAsksOffAndAClosedRoom() async throws {
        let off = try chatCore(extra: #", "no_asks": true"#)
        let c = await host(RealChat(off))
        var q = ChatAskRequest(room: "room1")
        q.question = "Ship?"
        let v14 = (await op(c, .chatAsk, q)).error?.message
        XCTAssertEqual(v14, "Asks are off on this Mac's chat server (the setting chat.asks).")
        let v15 = (await op(c, .chatWithdraw, ChatAskRequest(room: "room1", ask: "#1"))).error?.message
        XCTAssertEqual(v15,
                       "Asks are off on this Mac's chat server (the setting chat.asks).")
        XCTAssertEqual(ChatAskRefusal.classify(detail: "room room1 is closed: its workspace w is finished. It can still be read", ask: nil).code, .roomClosed)
    }

    func testADecisionIsMadeOncePerActionIDAndNamesTheAskAsHashN() async throws {
        let core = try chatCore()
        let chat = RealChat(core)
        let c = await host(chat)
        botAsk(core, "bot1", Self.two)
        let id = UUID().uuidString.lowercased()
        let v16 = try outcome(await decide(c, "#1", reply: "A", actionID: id)).state
        XCTAssertEqual(v16, "decided")
        let v17 = try outcome(await decide(c, "#1", reply: "A", actionID: id)).state
        XCTAssertEqual(v17, "duplicate", "a retry is a duplicate, never a second decision")
        let posts = chat.calls.filter { $0.0 == "POST" }
        XCTAssertEqual(posts.map(\.1), ["/api/rooms/room1/messages/%231/decide", "/api/rooms/room1/messages/%231/decide"])
        XCTAssertTrue(posts.allSatisfy { $0.2.contains { $0.0 == "X-Chat-Id" && $0.1 == id } })
        // Refused before any call: an action id that is not a lower-case v4 UUID, an ask that is no name, two answer forms.
        let n = chat.calls.count
        let v18 = (await decide(c, "#1", reply: "A", actionID: "NOT-A-UUID")).error?.code
        XCTAssertEqual(v18, .invalid)
        let v19 = (await decide(c, "../x", reply: "A")).error?.code
        XCTAssertEqual(v19, .invalid)
        var two = ChatAskRequest(room: "room1", ask: "#1")
        two.reply = "A"; two.decline = true
        let v20 = (await op(c, .chatDecide, two)).error?.code
        XCTAssertEqual(v20, .invalid)
        let v21 = (await op(c, .chatDecide, ChatAskRequest(room: "no/room", ask: "#1"))).error?.code
        XCTAssertEqual(v21, .invalid)
        XCTAssertEqual(chat.calls.count, n)
    }

    func testChatOffIsUnavailable() async throws {
        for chat in [nil, OffChat() as WorkspaceChat?] {
            let c = await host(chat)
            for o in [HostOp.chatAsk, .chatDecide, .chatWithdraw, .chatAsks] {
                let v22 = (await op(c, o, ChatAskRequest(room: "room1", ask: "#1"))).error?.code
                XCTAssertEqual(v22, .unavailable, o.rawValue)
            }
        }
        let ro = HostCore(store: DozableStore(root: URL(fileURLWithPath: dir + "/store")), readOnly: true, version: "test")
        let v23 = (await op(ro, .chatAsks, ChatAskRequest())).error?.code
        XCTAssertEqual(v23, .unavailable)
    }
}
