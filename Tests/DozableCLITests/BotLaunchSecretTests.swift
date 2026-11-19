import DozableChat
import Foundation
import XCTest
@testable import DozableKit
@testable import DozableHost

/// A bot-held launch secret (a workspace's manager's token): `bot` set and no item of its own, round trip; one a client
/// sends is cleared; its value is the bot's item only while the fingerprint matches (a rotated token: none — the 401
/// notice); forgetting, revoking (a sandbox's rm) and both sweeps leave `doz-bot-…` alone; an older doz's view of it
/// (no `bot`) deletes nothing.
final class BotLaunchSecretTests: BotTestCase {
    func botSecret(_ c: HostCore, _ bot: String = "mira", port: Int = 41000) async throws -> LaunchSecret {
        try await c.botLaunchSecret(bot, port: port)
    }

    func testTheRecordAndItsRoundTrip() async throws {
        let c = await core()
        _ = try change(await ask(c, .botNew, "mira") { $0.agent = "claude-code" })
        let s = try await botSecret(c)
        XCTAssertEqual(s.bot, "mira")
        XCTAssertNil(s.keychainService)
        XCTAssertEqual(s.variable, "CHAT_TOKEN")
        XCTAssertEqual(s.fileVariable, "CHAT_TOKEN_FILE")
        XCTAssertEqual(s.fingerprint, BotTokens.fingerprint(try XCTUnwrap(item("mira"))))
        let d = try JSONEncoder().encode(s)
        XCTAssertFalse(String(decoding: d, as: UTF8.self).contains("dzc_"))
        XCTAssertEqual(try JSONDecoder().decode(LaunchSecret.self, from: d), s)
        let value = await c.launchSecretValue(owner: "mac.demo", s)
        XCTAssertEqual(value, item("mira"))
    }

    func testAClientCannotSendOne() async throws {
        let c = await core()
        let src = root.appendingPathComponent("tok")
        try "a-secret-value-123".write(to: src, atomically: true, encoding: .utf8)
        chmod(src.path, 0o600)
        let given = LaunchSecret(variable: "SERVER_TOKEN", host: "host.dozable.internal", port: 41000, fingerprint: "x", keychainService: "doz-bot-x-mira",
                                 bot: "mira")
        let checked = try await c.checkedLaunchSecrets([LaunchSecretGrant(secret: given, value: "a-secret-value-123", source: src.path)],
                                                       readable: [], readableWhat: "its folder", hostPorts: [41000],
                                                       reach: { _, _ in true }, allowFlag: "--allow")
        XCTAssertNil(checked.first?.secret.bot, "a client-sent bot is cleared")
        XCTAssertNil(checked.first?.secret.keychainService)
    }

    func testARotatedTokenFailsTheFingerprint() async throws {
        let c = await core()
        _ = try change(await ask(c, .botNew, "mira") { $0.agent = "claude-code" })
        let s = try await botSecret(c)
        _ = try change(await ask(c, .botToken, "mira"))
        let value = await c.launchSecretValue(owner: "mac.demo", s)
        XCTAssertNil(value, "the item now holds another token: no value, the 401 notice")
        let vault = CredentialVault()
        await c.bindLaunchSecrets(vault, [s], owner: "mac.demo", who: "@mac demo")
        XCTAssertFalse(vault.hasSecret(s.bindingID))
    }

    func testNothingDeletesTheBotsItem() async throws {
        var c = await core()
        _ = try change(await ask(c, .botNew, "mira") { $0.agent = "claude-code" })
        let token = try XCTUnwrap(item("mira"))
        let s = try await botSecret(c)
        await c.forgetLaunchSecret(owner: "mac.demo", s)
        await c.sweepLaunchSecrets()
        await c.sweepBotTokens()
        XCTAssertEqual(item("mira"), token, "forget and both sweeps leave doz-bot-… alone")
        // A sandbox holding it, removed: its secrets are revoked, the bot's item stays.
        var r = HostRequest(.create, name: "wsv")
        r.create = CreateOptions(image: "lab")
        let made = await c.handle(r)
        XCTAssertNil(made.error)
        let url = store.configFile("wsv")
        var cfg = try XCTUnwrap(SandboxConfig.read(url))
        cfg.secrets = [s]
        try cfg.write(url)
        c = await core()
        let rm = await c.handle(HostRequest(.rm, name: "wsv"))
        XCTAssertNil(rm.error, rm.error?.message ?? "")
        XCTAssertEqual(item("mira"), token, "rm revoked its secrets; the bot's token is not one of them")
        // An older doz drops `bot`: a memory-only secret with no item — it deletes nothing, and has no value.
        var obj = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(s)) as? [String: Any])
        obj["bot"] = nil
        let older = try JSONDecoder().decode(LaunchSecret.self, from: JSONSerialization.data(withJSONObject: obj))
        XCTAssertNil(older.bot)
        await c.forgetLaunchSecret(owner: "mac.demo", older)
        let none = await c.launchSecretValue(owner: "mac.demo", older)
        XCTAssertNil(none)
        XCTAssertEqual(item("mira"), token)
    }
}
