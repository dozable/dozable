import DozableChat
import Foundation
import XCTest
@testable import DozableKit
@testable import DozableHost

/// The chat server as the bots see it, in memory: participants and their tokens' hashes, hashed as the supervisor does.
final class FakeBotChat: BotChat, @unchecked Sendable {
    let lock = NSLock()
    var dir = ChatDirectory(human: "ada")
    var hashes: [String: String] = [:]
    var on = true
    /// The next call of this name fails (`add`, `set`, `replaceToken`, `remove`).
    var failing: Set<String> = []

    func directory() throws -> ChatDirectory { lock.withLock { dir } }
    func enabled() -> Bool { lock.withLock { on } }

    private func fail(_ op: String) throws {
        if lock.withLock({ failing.contains(op) }) { throw HostError(.failed, "the chat server failed (\(op))") }
    }

    func add(_ name: String, token: String, kind: String, deliver: String, entry: String?, session: String?) async throws {
        try fail("add")
        try lock.withLock {
            if dir.has(name) { throw HostError(.exists, "\(name) is already in chat") }
            dir.participants.append(.init(name: name, kind: kind, added: "now", deliver: deliver == "poll" ? nil : deliver,
                                          webhook: deliver == "webhook" ? entry : nil, session: deliver == "inbox" ? session : nil))
            hashes[name] = ChatSecrets.hash(token)
        }
    }

    func set(_ name: String, deliver: String, entry: String?, session: String?) async throws {
        try fail("set")
        try lock.withLock {
            guard let i = dir.participants.firstIndex(where: { $0.name == name }) else { throw HostError(.notFound, "no participant \(name) in chat") }
            dir.participants[i].deliver = deliver == "poll" ? nil : deliver
            dir.participants[i].webhook = deliver == "webhook" ? entry : nil
            dir.participants[i].session = deliver == "inbox" ? session : nil
        }
    }

    func replaceToken(_ name: String, token: String) async throws {
        try fail("replaceToken")
        try lock.withLock {
            guard dir.participants.contains(where: { $0.name == name }) else { throw HostError(.notFound, "no participant \(name) in chat") }
            hashes[name] = ChatSecrets.hash(token)
        }
    }

    func remove(_ name: String) async throws {
        try fail("remove")
        try lock.withLock {
            guard dir.participants.contains(where: { $0.name == name }) else { throw HostError(.notFound, "no participant \(name) in chat") }
            dir.participants.removeAll { $0.name == name }
            hashes[name] = nil
        }
    }

    /// A participant added as `doz chat add` would, with a token the test knows.
    func plant(_ name: String, kind: String = "agent", deliver: String? = nil, token: String) {
        lock.withLock {
            dir.participants.append(.init(name: name, kind: kind, added: "then", deliver: deliver))
            hashes[name] = ChatSecrets.hash(token)
        }
    }
}

/// What every bot test shares: a scratch store, a fresh memory keychain, an in-process daemon core with the fake chat, and
/// every event the core said (its log lines) captured.
class BotTestCase: XCTestCase {
    var root: URL!
    var keychain: MemoryKeychain!
    var chat: FakeBotChat!
    var events: EventCapture!

    final class EventCapture: @unchecked Sendable {
        let lock = NSLock()
        var lines: [String] = []
        var task: Task<Void, Never>?
        var text: String { lock.withLock { lines.joined(separator: "\n") } }
    }

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: "/tmp/doz-bt-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        keychain = MemoryKeychain()
        chat = FakeBotChat()
        events = EventCapture()
        HostServer.keychainLocked = nil
    }

    override func tearDownWithError() throws {
        events.task?.cancel()
        HostServer.keychainLocked = nil
        try? FileManager.default.removeItem(at: root)
    }

    var store: DozableStore { DozableStore(root: root.appendingPathComponent("store")) }
    var botStore: BotStore { BotStore(store: store) }

    func core(readOnly: Bool = false, withChat: Bool = true) async -> HostCore {
        let s = CredentialServices(keychain: keychain, verifier: FakeVerifier(answer: .verified), claudeBinary: { nil }, home: root,
                                   keepaliveRunner: FakeRunner(), isClaudeRunning: { false }, watchInterval: .seconds(3600))
        let c = HostCore(store: store, readOnly: readOnly, version: "test", services: s)
        await c.load()
        if withChat { await c.setBotChat(chat) }
        let stream = c.subscribe()
        let cap = events!
        cap.task = Task { for await e in stream { cap.lock.withLock { cap.lines.append(e.text ?? "") } } }
        return c
    }

    @discardableResult
    func ask(_ c: HostCore, _ op: HostOp, _ name: String, _ edit: (inout BotRequest) -> Void = { _ in }) async -> HostMessage {
        var b = BotRequest(name: name)
        edit(&b)
        var r = HostRequest(op)
        r.botRequest = b
        return await c.handle(r)
    }

    func change(_ m: HostMessage, file: StaticString = #filePath, line: UInt = #line) throws -> BotChange {
        XCTAssertNil(m.error, m.error?.message ?? "", file: file, line: line)
        return try XCTUnwrap(m.result, file: file, line: line).decode(BotChange.self)
    }

    func shown(_ m: HostMessage, file: StaticString = #filePath, line: UInt = #line) throws -> BotDetail {
        XCTAssertNil(m.error, m.error?.message ?? "", file: file, line: line)
        return try XCTUnwrap(m.result, file: file, line: line).decode(BotDetail.self)
    }

    func item(_ name: String) -> String? { keychain.read(service: BotTokens.service(store: store.root, name: name), account: nil).value }
    func fileBytes() -> Data? { try? Data(contentsOf: URL(fileURLWithPath: botStore.file)) }
    func fileText() -> String { fileBytes().map { String(decoding: $0, as: UTF8.self) } ?? "" }
    func encoded(_ m: HostMessage) -> String { (try? HostWire.encoder.encode(m)).map { String(decoding: $0, as: UTF8.self) } ?? "" }
}

/// A bot's token: held in its own keychain item (the fake's hash is the item's), never in bots.json, an answer or the log;
/// a bot elsewhere's only in the answer's `oneTimeToken`, never kept; rotation replaces both; a locked keychain refuses with
/// nothing written; a chat failure rolls the item back; retire deletes the item, removes the participant and reserves the
/// name; the sweep deletes orphans of this store's prefix only; a read-only core refuses every change.
final class BotTokenTests: BotTestCase {
    func testAHeldTokenLivesOnlyInItsKeychainItem() async throws {
        let c = await core()
        let m = await ask(c, .botNew, "mira") { $0.agent = "claude-code"; $0.isolation = "fenced"; $0.deliver = "inbox" }
        let ch = try change(m)
        XCTAssertNil(ch.oneTimeToken, "a held bot's token never travels")
        let token = try XCTUnwrap(item("mira"))
        XCTAssertTrue(token.hasPrefix("dzc_"))
        XCTAssertEqual(chat.hashes["mira"], ChatSecrets.hash(token), "the chat server has its hash")
        XCTAssertEqual(ch.bot.token.keeper, "dozable")
        XCTAssertEqual(ch.bot.token.fingerprint, BotTokens.fingerprint(token))
        XCTAssertEqual(ch.bot.kind, "claude-session")
        XCTAssertEqual(ch.bot.deliver, "inbox")
        XCTAssertTrue(ch.bot.inChat)
        XCTAssertTrue(ch.bot.notes?.contains { $0.contains("dozchat") } == true, "inbox while fenced: the note says it polls")
        try await Task.sleep(for: .milliseconds(100))
        for (what, text) in [("bots.json", fileText()), ("the answer", encoded(m)), ("the log", events.text)] {
            XCTAssertFalse(text.contains("dzc_"), "no token in \(what)")
            XCTAssertFalse(text.contains(token), "no token in \(what)")
        }
        XCTAssertTrue(events.text.contains("bot mira: made (fenced, inbox), token fp \(BotTokens.fingerprint(token))"), events.text)
    }

    func testElsewhereIsShownOnceAndNeverKept() async throws {
        let c = await core()
        let m = await ask(c, .botNew, "far") { $0.agent = "codex"; $0.isolation = "elsewhere" }
        let ch = try change(m)
        let token = try XCTUnwrap(ch.oneTimeToken)
        XCTAssertEqual(chat.hashes["far"], ChatSecrets.hash(token))
        XCTAssertNil(item("far"), "never kept")
        XCTAssertEqual(ch.bot.token.keeper, "elsewhere")
        XCTAssertEqual(ch.bot.kind, "agent")
        XCTAssertEqual(ch.bot.deliver, "poll")
        XCTAssertFalse(fileText().contains("dzc_"))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(events.text.contains(token))
        // Looking says where it is, and never has it.
        let show = await ask(c, .botShow, "far")
        XCTAssertFalse(encoded(show).contains("dzc_"))
    }

    func testRotationReplacesTheItemAndTheHash() async throws {
        let c = await core()
        _ = try change(await ask(c, .botNew, "mira") { $0.agent = "claude-code" })
        let first = try XCTUnwrap(item("mira"))
        let m = await ask(c, .botToken, "mira")
        let ch = try change(m)
        let second = try XCTUnwrap(item("mira"))
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(chat.hashes["mira"], ChatSecrets.hash(second))
        XCTAssertNil(ch.oneTimeToken)
        XCTAssertEqual(ch.bot.token.fingerprint, BotTokens.fingerprint(second))
        XCTAssertFalse(encoded(m).contains("dzc_"))
        // Elsewhere: shown once, the hash follows.
        let far = try change(await ask(c, .botNew, "far") { $0.agent = "codex"; $0.isolation = "elsewhere" })
        let again = try change(await ask(c, .botToken, "far"))
        XCTAssertNotEqual(far.oneTimeToken, again.oneTimeToken)
        XCTAssertEqual(chat.hashes["far"], ChatSecrets.hash(try XCTUnwrap(again.oneTimeToken)))
        // Moving to elsewhere and back rotates too; the item goes and comes back.
        let out = try change(await ask(c, .botSet, "mira") { $0.isolation = "elsewhere" })
        XCTAssertNil(item("mira"))
        XCTAssertEqual(chat.hashes["mira"], ChatSecrets.hash(try XCTUnwrap(out.oneTimeToken)))
        let back = try change(await ask(c, .botSet, "mira") { $0.isolation = "vm" })
        XCTAssertNil(back.oneTimeToken)
        XCTAssertEqual(chat.hashes["mira"], ChatSecrets.hash(try XCTUnwrap(item("mira"))))
        XCTAssertEqual(back.bot.token.keeper, "dozable")
    }

    func testALockedKeychainRefusesAHeldBotWithNothingWritten() async throws {
        let c = await core()
        HostServer.keychainLocked = "ssh"
        let m = await ask(c, .botNew, "mira") { $0.agent = "claude-code" }
        XCTAssertEqual(m.error?.code, .unavailable)
        XCTAssertTrue(m.error?.message.contains("the login keychain is locked here") == true)
        XCTAssertNil(fileBytes())
        XCTAssertNil(item("mira"))
        XCTAssertFalse(chat.dir.has("mira"))
        // Elsewhere needs no keychain.
        _ = try change(await ask(c, .botNew, "far") { $0.agent = "codex"; $0.isolation = "elsewhere" })
        // A held bot's rotation is refused too, and leaves everything as it was.
        HostServer.keychainLocked = nil
        _ = try change(await ask(c, .botNew, "mira") { $0.agent = "claude-code" })
        let before = (item("mira"), chat.hashes["mira"], fileBytes())
        HostServer.keychainLocked = "no login session"
        let a1 = await ask(c, .botToken, "mira")
        XCTAssertEqual((a1).error?.code, .unavailable)
        let a2 = await ask(c, .botSet, "far") { $0.isolation = "fenced" }
        XCTAssertEqual((a2).error?.code, .unavailable)
        XCTAssertTrue(item("mira") == before.0 && chat.hashes["mira"] == before.1)
        XCTAssertEqual(fileBytes(), before.2)
    }

    func testAChatFailureRollsTheItemBack() async throws {
        let c = await core()
        chat.failing = ["add"]
        let m = await ask(c, .botNew, "mira") { $0.agent = "claude-code" }
        XCTAssertNotNil(m.error)
        XCTAssertNil(item("mira"), "the item made for it is deleted")
        XCTAssertNil(fileBytes())
        chat.failing = []
        _ = try change(await ask(c, .botNew, "mira") { $0.agent = "claude-code" })
        let old = try XCTUnwrap(item("mira"))
        chat.failing = ["replaceToken"]
        let a3 = await ask(c, .botToken, "mira")
        XCTAssertNotNil((a3).error)
        XCTAssertEqual(item("mira"), old, "a failed rotation restores the old value")
        XCTAssertEqual(chat.hashes["mira"], ChatSecrets.hash(old))
    }

    func testRetireDeletesTheItemRemovesTheParticipantAndReservesTheName() async throws {
        let c = await core()
        _ = try change(await ask(c, .botNew, "mira") { $0.agent = "claude-code" })
        let ch = try change(await ask(c, .botRetire, "mira"))
        XCTAssertNil(item("mira"))
        XCTAssertFalse(chat.dir.has("mira"))
        XCTAssertNil(chat.hashes["mira"])
        XCTAssertEqual(ch.bot.token.keeper, "none")
        XCTAssertNotNil(ch.bot.retiredAt)
        let again = await ask(c, .botNew, "mira") { $0.agent = "codex" }
        XCTAssertEqual(again.error?.code, .exists)
        XCTAssertTrue(again.error?.message.contains("mira was a bot, retired") == true, again.error?.message ?? "")
        XCTAssertEqual(BotGuards.chatRefusal(.chatAdd, name: "mira", bots: try botStore.read())?.code, .exists)
        // Hidden from the list; --retired lists it.
        var r = HostRequest(.botList)
        r.botRequest = BotRequest()
        let a4 = await c.handle(r)
        XCTAssertEqual(try XCTUnwrap((a4).result).decode(BotListing.self).bots.map(\.name), [])
        r.botRequest?.retired = true
        let a5 = await c.handle(r)
        XCTAssertEqual(try XCTUnwrap((a5).result).decode(BotListing.self).bots.map(\.name), ["mira"])
        let a6 = await ask(c, .botToken, "mira")
        XCTAssertEqual((a6).error?.code, .exists, "a retired bot gets no token")
        let a7 = await ask(c, .botRetire, "mira")
        XCTAssertEqual((a7).error?.code, .exists)
    }

    func testABotInAWorkspaceIsNotRetired() async throws {
        let c = await core()
        _ = try change(await ask(c, .botNew, "mira") { $0.agent = "claude-code" })
        let at = Date()
        let rec = WorkspaceRecord(name: "demo", createdAt: at, brief: WorkspaceBrief(sha256: "ab", bytes: 2, updatedAt: at), folders: [],
                                  agents: [WorkspaceAgent(name: "mira", place: .macSession("mira"), startedAt: at, bot: "mira")])
        try WorkspaceStore(store: store).create(rec, brief: Data("hi".utf8), log: [])
        let before = fileBytes()
        let m = await ask(c, .botRetire, "mira")
        XCTAssertEqual(m.error?.code, .exists)
        XCTAssertTrue(m.error?.message.contains("mira is in demo — doz workspace release demo mira first") == true, m.error?.message ?? "")
        XCTAssertEqual(fileBytes(), before)
        XCTAssertNotNil(item("mira"))
        let a8 = await ask(c, .botShow, "mira")
        XCTAssertEqual(try XCTUnwrap(a8.result).decode(BotDetail.self).workspaces, ["demo"])
    }

    /// The sweep deletes this store's items of no held, unretired bot; another store's, a launch secret's and a live bot's
    /// are kept; secrets.json is never written.
    func testTheSweepDeletesOrphansOfItsOwnPrefixOnly() async throws {
        let c = await core()
        _ = try change(await ask(c, .botNew, "mira") { $0.agent = "claude-code" })
        _ = try change(await ask(c, .botNew, "gone") { $0.agent = "codex" })
        _ = try change(await ask(c, .botRetire, "gone"))
        let ghost = BotTokens.service(store: store.root, name: "ghost")
        let other = BotTokens.service(store: URL(fileURLWithPath: "/tmp/another-store"), name: "mira")
        let secret = LaunchSecrets.service(store: store.root, owner: "wsa", variable: "API_KEY")
        for s in [ghost, other, secret] { try keychain.write(service: s, account: Keychain.user, secret: "dzc_planted-0123456789") }
        try keychain.write(service: BotTokens.service(store: store.root, name: "gone"), account: Keychain.user, secret: "dzc_left-0123456789")
        await c.sweepBotTokens()
        XCTAssertNil(keychain.read(service: ghost, account: nil).value, "an orphan of this store: deleted")
        XCTAssertNil(item("gone"), "a retired bot's: deleted")
        XCTAssertNotNil(item("mira"), "a live bot's: kept")
        XCTAssertNotNil(keychain.read(service: other, account: nil).value, "another store's: kept")
        XCTAssertNotNil(keychain.read(service: secret, account: nil).value, "a launch secret's: kept")
        XCTAssertFalse(FileManager.default.fileExists(atPath: LaunchSecretLedger.url(store).path), "secrets.json never written")
        // The read-only core never sweeps.
        let ro = await core(readOnly: true, withChat: false)
        try keychain.write(service: ghost, account: Keychain.user, secret: "dzc_planted-0123456789")
        await ro.sweepBotTokens()
        XCTAssertNotNil(keychain.read(service: ghost, account: nil).value)
    }

    func testAReadOnlyCoreAnswersLookingAndRefusesEveryChange() async throws {
        let c = await core()
        _ = try change(await ask(c, .botNew, "mira") { $0.agent = "claude-code" })
        let before = fileBytes()
        let ro = await core(readOnly: true, withChat: false)
        var r = HostRequest(.botList)
        r.botRequest = BotRequest()
        let a9 = await ro.handle(r)
        XCTAssertEqual(try XCTUnwrap((a9).result).decode(BotListing.self).bots.map(\.name), ["mira"])
        let a10 = await ask(ro, .botShow, "mira")
        XCTAssertNil((a10).error)
        for op in [HostOp.botNew, .botSet, .botRetire, .botAdopt, .botToken] {
            let m = await ask(ro, op, "mira") { $0.agent = "codex"; $0.model = "m" }
            XCTAssertEqual(m.error?.code, .unavailable, op.rawValue)
        }
        XCTAssertEqual(fileBytes(), before)
    }

    func testSetKeepsTheTokenAndAnUnknownField() async throws {
        let c = await core()
        _ = try change(await ask(c, .botNew, "mira") { $0.agent = "claude-code"; $0.deliver = "inbox" })
        let token = item("mira")
        var obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(fileBytes())) as? [String: Any])
        var list = try XCTUnwrap(obj["bots"] as? [[String: Any]])
        list[0]["budget"] = ["usd": 5]
        obj["bots"] = list
        try JSONSerialization.data(withJSONObject: obj).write(to: URL(fileURLWithPath: botStore.file))
        let ch = try change(await ask(c, .botSet, "mira") { $0.deliver = "poll"; $0.model = "sonnet"; $0.skills = ["chat-manager"] })
        XCTAssertEqual(ch.bot.deliver, "poll")
        XCTAssertEqual(ch.bot.model, "sonnet")
        XCTAssertEqual(item("mira"), token, "the token is kept")
        XCTAssertEqual(chat.dir.participants.first?.delivery, "poll")
        XCTAssertTrue(fileText().contains("\"budget\""))
        let a11 = await ask(c, .botSet, "mira")
        XCTAssertEqual((a11).error?.code, .invalid, "nothing to change")
        let a12 = await ask(c, .botSet, "mira") { $0.deliver = "inbox"; $0.session = "x y\n" }
        XCTAssertEqual((a12).error?.code, .invalid)
    }

    /// `heldOnly` (every change the dashboard asks): whatever would make a token to show once is refused before the
    /// keychain or the chat server is touched — new elsewhere, a new token for a bot elsewhere, set to or from elsewhere —
    /// with the terminal's command; the held flows are unchanged.
    func testHeldOnlyRefusesEveryTokenToShowOnce() async throws {
        let c = await core()
        _ = try change(await ask(c, .botNew, "mira") { $0.agent = "claude-code" })
        let far = try change(await ask(c, .botNew, "far") { $0.agent = "codex"; $0.isolation = "elsewhere" })
        XCTAssertNotNil(far.oneTimeToken, "the CLI (no heldOnly) still gets its one-time token")
        let before = (fileBytes(), chat.hashes, chat.dir, item("mira"), Set(keychain.items(servicePrefix: BotTokens.prefix(store: store.root)).map(\.service)))
        chat.failing = ["add", "set", "replaceToken", "remove"]          // any chat call would fail differently
        let cases: [(HostOp, String, (inout BotRequest) -> Void, String)] = [
            (.botNew, "neo", { $0.agent = "codex"; $0.isolation = "elsewhere" },
             "a bot elsewhere gets its token in a terminal on this Mac: doz bot new neo --agent codex --isolation elsewhere --to-file F"),
            (.botToken, "far", { _ in }, "a bot elsewhere gets its token in a terminal on this Mac: doz bot token far --new --to-file F"),
            (.botSet, "mira", { $0.isolation = "elsewhere" },
             "a bot elsewhere gets its token in a terminal on this Mac: doz bot set mira --isolation elsewhere --to-file F"),
            (.botSet, "far", { $0.isolation = "fenced" },
             "far is elsewhere: moving it to this Mac makes it a new token — in a terminal on this Mac: doz bot set far --isolation fenced"),
        ]
        for (op, name, edit, words) in cases {
            let m = await ask(c, op, name) { edit(&$0); $0.heldOnly = true }
            XCTAssertEqual(m.error?.code, .invalid, "\(op.rawValue) \(name): \(m.error?.message ?? "no error")")
            XCTAssertEqual(m.error?.message, words)
            XCTAssertNil(m.result)
        }
        XCTAssertEqual(fileBytes(), before.0, "bots.json: identical bytes")
        XCTAssertEqual(chat.hashes, before.1)
        XCTAssertEqual(chat.dir, before.2)
        XCTAssertEqual(item("mira"), before.3)
        XCTAssertEqual(Set(keychain.items(servicePrefix: BotTokens.prefix(store: store.root)).map(\.service)), before.4, "no keychain item made or deleted")
        // The held flows are unchanged under heldOnly: a held rotation, a change of an elsewhere bot's model.
        chat.failing = []
        let rot = try change(await ask(c, .botToken, "mira") { $0.heldOnly = true })
        XCTAssertNil(rot.oneTimeToken)
        XCTAssertNotEqual(item("mira"), before.3)
        let mod = try change(await ask(c, .botSet, "far") { $0.model = "o4"; $0.heldOnly = true })
        XCTAssertNil(mod.oneTimeToken)
        XCTAssertEqual(mod.bot.model, "o4")
        let neo = try change(await ask(c, .botNew, "neo") { $0.agent = "codex"; $0.isolation = "vm"; $0.heldOnly = true })
        XCTAssertNil(neo.oneTimeToken)
        XCTAssertNotNil(item("neo"))
        XCTAssertNil(BotGuards.heldOnlyRefusal(.botList, BotRequest(name: "far"), bots: try botStore.read()), "looking is never refused")
    }

    /// `bot-show` with `withInstructions`: the text, as written (round trip); without it, never; a bot with none: nil.
    func testShowWithTheInstructionsText() async throws {
        let c = await core()
        let text = "Be brief.\nAnswer in the room — once.\n"
        _ = try change(await ask(c, .botNew, "mira") { $0.agent = "claude-code"; $0.instructions = text })
        _ = try change(await ask(c, .botNew, "otto") { $0.agent = "codex" })
        let plain = try await shown(ask(c, .botShow, "mira"))
        XCTAssertNil(plain.instructionsText, "only when asked")
        let d = try await shown(ask(c, .botShow, "mira") { $0.withInstructions = true })
        XCTAssertEqual(d.instructionsText, text)
        XCTAssertEqual(d.instructions?.bytes, text.utf8.count)
        let none = try await shown(ask(c, .botShow, "otto") { $0.withInstructions = true })
        XCTAssertNil(none.instructionsText)
        // The read-only core answers it too (looking never starts the daemon); the limit is the store's 256 KiB.
        let ro = await core(readOnly: true, withChat: false)
        let r = try await shown(ask(ro, .botShow, "mira") { $0.withInstructions = true })
        XCTAssertEqual(r.instructionsText, text)
        let big = String(repeating: "x", count: BotStore.maximumInstructionsBytes)
        _ = try change(await ask(c, .botSet, "otto") { $0.instructions = big })
        let b = try await shown(ask(c, .botShow, "otto") { $0.withInstructions = true })
        XCTAssertEqual(b.instructionsText?.utf8.count, BotStore.maximumInstructionsBytes)
        // The listing's additive columns: avatar, account, who keeps the token — never a fingerprint.
        _ = try change(await ask(c, .botSet, "mira") { $0.avatar = "🦊"; $0.account = "mac" })
        var lr = HostRequest(.botList)
        lr.botRequest = BotRequest()
        let lm = await c.handle(lr)
        let l = try XCTUnwrap(lm.result).decode(BotListing.self)
        let row = try XCTUnwrap(l.bots.first { $0.name == "mira" })
        XCTAssertEqual(row.avatar, "🦊")
        XCTAssertEqual(row.account, "mac")
        XCTAssertEqual(row.tokenKeeper, "dozable")
    }

    func testNewRefusals() async throws {
        let c = await core()
        chat.plant("olda", token: "olda-own-token-0123456789")
        for (name, agent, code, words) in [("olda", "codex", HostError.Code.exists, "doz bot adopt olda"),
                                           ("ada", "codex", .invalid, "you in chat"),
                                           ("chat", "codex", .invalid, "reserved"),
                                           ("Bad", "codex", .invalid, "not a name in chat"),
                                           ("mira", "no-such-agent-x", .notFound, "no agent"),
                                           ("mira", "", .invalid, "which agent")] {
            let m = await ask(c, .botNew, name) { $0.agent = agent }
            XCTAssertEqual(m.error?.code, code, name)
            XCTAssertTrue(m.error?.message.contains(words) == true, "\(name): \(m.error?.message ?? "")")
        }
        let a13 = await ask(c, .botNew, "mira") { $0.agent = "codex"; $0.deliver = "inbox" }
        XCTAssertEqual((a13).error?.code, .invalid, "inbox for a Claude Code bot only")
        let a14 = await ask(c, .botNew, "mira") { $0.agent = "codex"; $0.account = "nobody" }
        XCTAssertEqual((a14).error?.code, .notFound)
        let a15 = await ask(c, .botNew, "mira") { $0.agent = "codex"; $0.isolation = "cloud" }
        XCTAssertEqual((a15).error?.code, .invalid)
        let a16 = await ask(c, .botNew, "mira") { $0.agent = "codex"; $0.instructions = String(repeating: "x", count: (256 << 10) + 1) }
        XCTAssertEqual((a16).error?.code, .invalid)
        XCTAssertNil(fileBytes(), "nothing written")
        XCTAssertNil(item("mira"))
        // Chat off: the participant waits.
        chat.on = false
        let ch = try change(await ask(c, .botNew, "mira") { $0.agent = "codex"; $0.deliver = "webhook" })
        XCTAssertTrue(ch.bot.notes?.contains("mira takes part once chat is on (doz chat on)") == true, "\(ch.bot.notes ?? [])")
        XCTAssertTrue(ch.bot.notes?.contains("set its webhook entry next: doz chat webhook set mira") == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: botStore.folder("mira") + "/notes.md"))
    }
}
