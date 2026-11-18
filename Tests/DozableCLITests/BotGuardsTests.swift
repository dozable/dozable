import Foundation
import XCTest
@testable import DozableHost

/// What `doz chat` refuses for a bot's name, and what it leaves alone: the table.
final class BotGuardsTests: XCTestCase {
    let at = Date(timeIntervalSince1970: 1_800_000_000)

    var bots: BotsFile {
        var gone = BotRecord(name: "gone", createdAt: at, agent: "codex", isolation: BotIsolation(default: "fenced"), kind: "agent",
                             token: BotTokenState(keeper: "none", fingerprint: nil, at: at))
        gone.retiredAt = at
        return BotsFile(bots: [BotRecord(name: "mira", createdAt: at, agent: "claude-code", isolation: BotIsolation(default: "fenced"),
                                         kind: "claude-session", token: BotTokenState(keeper: "dozable", fingerprint: "0123456789ab", at: at)),
                               gone])
    }

    func testTheTable() {
        let rows: [(HostOp, String?, HostError.Code?, String?)] = [
            (.chatAdd, "mira", .exists, "doz bot show mira"),
            (.chatRemove, "mira", .invalid, "doz bot retire mira"),
            (.chatToken, "mira", .invalid, "doz bot token mira --new"),
            (.chatSet, "mira", .invalid, "doz bot set mira --deliver"),
            (.chatSync, "mira", .exists, "a bot's name"),
            (.chatAdd, "gone", .exists, "gone was a bot, retired 2027-"),
            (.chatSync, "gone", .exists, "the name stays with its old messages"),
            // A retired name is no participant any more: the supervisor answers these as before.
            (.chatRemove, "gone", nil, nil), (.chatToken, "gone", nil, nil), (.chatSet, "gone", nil, nil),
            // Everyone else, and the ops that carry no participant: unchanged.
            (.chatAdd, "bot1", nil, nil), (.chatRemove, "bot1", nil, nil), (.chatToken, "bot1", nil, nil), (.chatSet, "bot1", nil, nil),
            (.chatSync, "ada", nil, nil), (.chatSync, nil, nil, nil), (.chatWebhookSet, nil, nil, nil), (.chatImport, nil, nil, nil),
            (.chatWebhookStatus, "mira", nil, nil),
        ]
        for (op, name, code, words) in rows {
            let e = BotGuards.chatRefusal(op, name: name, bots: bots)
            XCTAssertEqual(e?.code, code, "\(op.rawValue) \(name ?? "-")")
            if let words { XCTAssertTrue(e?.message.contains(words) == true, "\(op.rawValue) \(name ?? "-"): \(e?.message ?? "")") }
        }
        XCTAssertNil(BotGuards.chatRefusal(.chatRemove, name: "mira", bots: BotsFile()), "no bots: nothing refused")
    }
}
