import DozableChat
import Foundation
import XCTest
@testable import DozableHost

/// `bot-adopt`: an existing participant becomes a bot — its token replaced (Dozable never had the old one), its kind,
/// delivery, rooms and history kept; refused for the human, a bot, a missing participant and a retired name, every refusal
/// leaving every byte as it was.
final class BotAdoptTests: BotTestCase {
    func testAdoptReplacesTheTokenAndKeepsKindAndDelivery() async throws {
        let c = await core()
        let old = "olda-own-token-0123456789"
        chat.plant("olda", kind: "claude-session", deliver: "inbox", token: old)
        let m = await ask(c, .botAdopt, "olda") { $0.agent = "codex" }
        let ch = try change(m)
        XCTAssertNotEqual(chat.hashes["olda"], ChatSecrets.hash(old), "the old token is refused from now on")
        let token = try XCTUnwrap(item("olda"))
        XCTAssertEqual(chat.hashes["olda"], ChatSecrets.hash(token))
        XCTAssertNil(ch.oneTimeToken)
        XCTAssertEqual(ch.bot.origin, "adopted")
        XCTAssertEqual(ch.bot.kind, "claude-session", "its kind is kept")
        XCTAssertEqual(ch.bot.deliver, "inbox", "its delivery is kept")
        XCTAssertEqual(ch.bot.isolation.default, "fenced")
        XCTAssertTrue(ch.bot.notes?.first?.hasPrefix("its token is replaced") == true, "\(ch.bot.notes ?? [])")
        XCTAssertFalse(encoded(m).contains("dzc_"))
        XCTAssertFalse(fileText().contains("dzc_"))
        XCTAssertEqual(chat.dir.participants.map(\.name), ["olda"], "still the same one participant")
    }

    func testAdoptElsewhereShowsTheNewTokenOnceAndCanChangeTheDelivery() async throws {
        let c = await core()
        chat.plant("olda", token: "olda-own-token-0123456789")
        let ch = try change(await ask(c, .botAdopt, "olda") { $0.agent = "codex"; $0.isolation = "elsewhere"; $0.deliver = "webhook" })
        let token = try XCTUnwrap(ch.oneTimeToken)
        XCTAssertEqual(chat.hashes["olda"], ChatSecrets.hash(token))
        XCTAssertNil(item("olda"))
        XCTAssertEqual(ch.bot.deliver, "webhook")
        XCTAssertEqual(chat.dir.participants.first?.delivery, "webhook")
    }

    func testRefusalsChangeNothing() async throws {
        let c = await core()
        chat.plant("olda", token: "olda-own-token-0123456789")
        _ = try change(await ask(c, .botNew, "mira") { $0.agent = "claude-code" })
        _ = try change(await ask(c, .botNew, "gone") { $0.agent = "codex" })
        _ = try change(await ask(c, .botRetire, "gone"))
        let before = (fileBytes(), chat.hashes, chat.dir, item("mira"))
        for (name, agent, code) in [("ada", "codex", HostError.Code.invalid),      // the human
                                    ("mira", "codex", .exists),                    // already a bot
                                    ("nosuch", "codex", .notFound),                // not in chat
                                    ("gone", "codex", .exists),                    // retired
                                    ("olda", "no-such-agent-x", .notFound),        // unknown agent
                                    ("olda", "codex", .invalid)] {                 // inbox for a non-Claude Code participant
            let m = await ask(c, .botAdopt, name) { $0.agent = agent; if name == "olda" && agent == "codex" { $0.deliver = "inbox" } }
            XCTAssertEqual(m.error?.code, code, "\(name): \(m.error?.message ?? "no error")")
        }
        XCTAssertEqual(fileBytes(), before.0)
        XCTAssertEqual(chat.hashes, before.1)
        XCTAssertEqual(chat.dir, before.2)
        XCTAssertEqual(item("mira"), before.3)
        XCTAssertNil(item("olda"))
        let retired = await ask(c, .botAdopt, "gone") { $0.agent = "codex" }
        XCTAssertTrue(retired.error?.message.contains("gone was a bot, retired") == true)
    }

    /// The dashboard's adoption (`heldOnly`): elsewhere is refused before anything is touched — no item, no chat call, every
    /// byte as it was; a held adoption is unchanged.
    func testHeldOnlyRefusesAnAdoptionElsewhereAndKeepsTheHeldOne() async throws {
        let c = await core()
        let old = "olda-own-token-0123456789"
        chat.plant("olda", token: old)
        let before = (fileBytes(), chat.hashes, chat.dir)
        chat.failing = ["add", "set", "replaceToken", "remove"]          // any chat call would fail differently
        let m = await ask(c, .botAdopt, "olda") { $0.agent = "codex"; $0.isolation = "elsewhere"; $0.heldOnly = true }
        XCTAssertEqual(m.error?.code, .invalid, m.error?.message ?? "")
        XCTAssertEqual(m.error?.message, "a bot elsewhere gets its token in a terminal on this Mac: doz bot adopt olda --agent codex --isolation elsewhere --to-file F")
        XCTAssertEqual(fileBytes(), before.0)
        XCTAssertEqual(chat.hashes, before.1)
        XCTAssertEqual(chat.dir, before.2)
        XCTAssertNil(item("olda"))
        chat.failing = []
        let ch = try change(await ask(c, .botAdopt, "olda") { $0.agent = "codex"; $0.heldOnly = true })
        XCTAssertNil(ch.oneTimeToken)
        XCTAssertEqual(chat.hashes["olda"], ChatSecrets.hash(try XCTUnwrap(item("olda"))))
    }

    func testALockedKeychainRefusesAHeldAdoption() async throws {
        let c = await core()
        let old = "olda-own-token-0123456789"
        chat.plant("olda", token: old)
        HostServer.keychainLocked = "ssh"
        let a17 = await ask(c, .botAdopt, "olda") { $0.agent = "codex" }
        XCTAssertEqual((a17).error?.code, .unavailable)
        XCTAssertEqual(chat.hashes["olda"], ChatSecrets.hash(old), "the token it has still works")
        XCTAssertNil(fileBytes())
    }
}
