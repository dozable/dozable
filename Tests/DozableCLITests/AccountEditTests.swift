import Foundation
import DozableKit
import XCTest
@testable import DozableCLI
@testable import DozableHost

// 641 (owner: "add a way to edit key details") — `account-edit`: a rename carries everything that names the account
// (its keychain item, the defaults, every sandbox's account and custom keys), a setup token's plan changes without
// pasting it again; and `account-add --force` (the value replaced) keeps the name's default, sandboxes and plan.
// No VM, no real keychain: the fake keychain and verifier of AccountTests; every key is a made-up string.
final class AccountEditTests: XCTestCase {
    private var root: URL!
    let keychain = FakeKeychain()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("doz-edit-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("home"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func core() async -> HostCore {
        let s = CredentialServices(keychain: keychain, verifier: FakeVerifier(answer: .verified), claudeBinary: { nil },
                                   home: root.appendingPathComponent("home"), keepaliveRunner: FakeRunner(), isClaudeRunning: { false },
                                   watchInterval: .seconds(3600))
        let c = HostCore(store: DozableStore(root: root), readOnly: false, version: "test", services: s)
        await c.load()
        return c
    }

    var file: AccountsFile { AccountStore(store: DozableStore(root: root)).load() }

    @discardableResult
    func ok(_ c: HostCore, _ r: HostRequest, file: StaticString = #filePath, line: UInt = #line) async throws -> [AccountRow] {
        let m = await c.handle(r)
        XCTAssertNil(m.error, m.error?.message ?? "", file: file, line: line)
        return try XCTUnwrap(m.result, file: file, line: line).decode([AccountRow].self)
    }

    func add(_ c: HostCore, _ name: String, _ kind: AccountKind, secret: String, plan: String? = nil, force: Bool = false) async throws {
        try await ok(c, HostRequest.accountAdd(name: name, kind: kind, plan: plan, secret: secret, force: force))
    }

    func edit(_ name: String, newName: String? = nil, plan: String? = nil) -> HostRequest {
        var r = HostRequest(.accountEdit)
        r.account = name
        r.newName = newName
        r.plan = plan
        return r
    }

    func create(_ c: HostCore, _ name: String, account: String? = nil, keys: [String]? = nil, allow: [String]? = nil) async throws {
        var r = HostRequest(.create, name: name)
        r.create = CreateOptions(image: "claude-code", account: account)
        r.create?.keys = keys
        r.create?.allow = allow
        let m = await c.handle(r)
        if let e = m.error { throw e }
    }

    let apiKey = "sk-ant-api03-EDIT-" + String(repeating: "K", count: 30)

    func testARenameCarriesTheKeychainItemTheDefaultAndEverySandbox() async throws {
        let c = await core()
        try await add(c, "work", .apiKey, secret: apiKey)
        var d = HostRequest(.accountDefault)
        d.account = "work"
        try await ok(c, d)
        try await create(c, "pinned", account: "work")
        try await create(c, "follower")
        let v = try await XCTUnwrapAsync(await c.vault(of: "pinned"))
        let placeholder = try XCTUnwrap(v.mint("anthropic"))

        let rows = try await ok(c, edit("work", newName: "team"))
        // The keychain item Dozable made moved (written, read back) and the old one is gone.
        XCTAssertEqual(keychain.get("doz-anthropic:team"), apiKey)
        XCTAssertNil(keychain.get("doz-anthropic:work"))
        // The record, the default and the sandboxes.
        XCTAssertNil(rows.first { $0.name == "work" })
        let team = try XCTUnwrap(rows.first { $0.name == "team" })
        XCTAssertEqual(team.keychainService, "doz-anthropic:team")
        XCTAssertTrue(team.isDefault, "the default moved with it")
        XCTAssertEqual(team.usedBy.sorted(), ["follower", "pinned"])
        XCTAssertEqual(team.state, "ok")
        XCTAssertEqual(file.defaultAccount, "team")
        let cfg = await c.config(of: "pinned")
        XCTAssertEqual(cfg?.account, "team")
        XCTAssertEqual(SandboxConfig.read(DozableStore(root: root).configFile("pinned"))?.account, "team", "written to doz.json")
        // A running session keeps working: its placeholder still swaps to the same key.
        let head = Array("GET / HTTP/1.1\r\nHost: api.anthropic.com\r\nx-api-key: \(placeholder)\r\n\r\n".utf8)
        guard case .swapped(let out, _) = v.rewrite(head: head, host: "api.anthropic.com") else { return XCTFail("an open session lost its key") }
        XCTAssertTrue(String(decoding: out, as: UTF8.self).contains(apiKey))
        let fv = try await XCTUnwrapAsync(await c.vault(of: "follower"))
        XCTAssertTrue(fv.hasSecret("anthropic"), "a follower of the default keeps its key")
        // accounts.json never holds the key.
        XCTAssertFalse(try String(contentsOf: root.appendingPathComponent("accounts.json"), encoding: .utf8).contains("KKKKKKKK"))
    }

    func testARenamedCustomKeyMovesInEverySandboxThatAttachedIt() async throws {
        let c = await core()
        var r = HostRequest.accountAdd(name: "ex", kind: .key, plan: nil, secret: "EXAMPLE-CUSTOM-0123456789")
        r.custom = CustomKey(hosts: ["api.example.test"], header: "authorization", format: "Bearer %s", env: "EXAMPLE_API_KEY")
        try await ok(c, r)
        try await create(c, "cc", account: "none", keys: ["ex"], allow: ["site:api.example.test"])
        let v = try await XCTUnwrapAsync(await c.vault(of: "cc"))
        XCTAssertTrue(v.hasSecret("custom:ex"))
        let rows = try await ok(c, edit("ex", newName: "example"))
        XCTAssertEqual(keychain.get("doz-custom:example"), "EXAMPLE-CUSTOM-0123456789")
        XCTAssertNil(keychain.get("doz-custom:ex"))
        let cfg = await c.config(of: "cc")
        XCTAssertEqual(cfg?.extraKeys, ["example"])
        XCTAssertTrue(v.hasSecret("custom:example"), "its new binding has the key")
        XCTAssertNil(v.allBindings.first { $0.id == "custom:ex" }, "the old name's binding is gone")
        XCTAssertEqual(rows.first { $0.name == "example" }?.usedBy, ["cc"])
        XCTAssertEqual(rows.first { $0.name == "example" }?.hosts, ["api.example.test"])
    }

    func testAKeyProvidersDefaultMovesAndAnAdoptedItemKeepsItsService() async throws {
        let c = await core()
        try await ok(c, HostRequest.keyAccountAdd(name: "grok", provider: "xai", secret: "xai-FAKE-" + String(repeating: "x", count: 30)))
        XCTAssertEqual(file.providerDefaults?["xai"], "grok")
        try await ok(c, edit("grok", newName: "grok-work"))
        XCTAssertEqual(file.providerDefaults?["xai"], "grok-work")
        XCTAssertNotNil(keychain.get("doz-xai:grok-work"))
        XCTAssertNil(keychain.get("doz-xai:grok"))
        // An item the person named is theirs: it keeps its service, and it is not deleted.
        keychain.put("my-own-anthropic-key", apiKey)
        var r = HostRequest.accountAdd(name: "mine", kind: .apiKey, plan: nil, secret: nil, keychain: "my-own-anthropic-key")
        r.verify = false
        try await ok(c, r)
        let rows = try await ok(c, edit("mine", newName: "ours"))
        let ours = try XCTUnwrap(rows.first { $0.name == "ours" })
        XCTAssertEqual(ours.keychainService, "my-own-anthropic-key")
        XCTAssertEqual(ours.adopted, true)
        XCTAssertEqual(keychain.get("my-own-anthropic-key"), apiKey)
        XCTAssertEqual(ours.state, "ok")
    }

    func testRenameRefusalsChangeNothing() async throws {
        let c = await core()
        try await add(c, "work", .apiKey, secret: apiKey)
        try await add(c, "other", .apiKey, secret: apiKey + "2")
        let before = file
        for (r, code, why) in [(edit("mac", newName: "mine"), HostError.Code.invalid, "the Mac login"),
                               (edit("work", newName: "other"), .exists, "a name that is taken"),
                               (edit("work", newName: "mac"), .invalid, "the built-in login's name"),
                               (edit("work", newName: "default"), .invalid, "reserved"),
                               (edit("work", newName: "none"), .invalid, "reserved"),
                               (edit("work", newName: "Not OK"), .invalid, "not a name"),
                               (edit("nope", newName: "x"), .notFound, "no such account"),
                               (edit("work"), .invalid, "nothing to change"),
                               (edit("work", plan: "max"), .invalid, "an API key has no plan")] {
            let m = await c.handle(r)
            XCTAssertEqual(m.error?.code, code, "\(why): \(m.error?.message ?? "no error")")
        }
        XCTAssertEqual(file, before)
        // The new item cannot be written: nothing changes, the key stays where it was.
        keychain.failWrites = ["doz-anthropic:team"]
        let m = await c.handle(edit("work", newName: "team"))
        XCTAssertEqual(m.error?.code, .failed, m.error?.message ?? "")
        XCTAssertEqual(keychain.get("doz-anthropic:work"), apiKey, "the secret is never lost")
        XCTAssertNil(keychain.get("doz-anthropic:team"))
        XCTAssertEqual(file, before)
        // A locked item is not moved either.
        keychain.failWrites = []
        keychain.lockedServices = ["doz-anthropic:work"]
        let locked = await c.handle(edit("work", newName: "team"))
        XCTAssertEqual(locked.error?.code, .failed)
        XCTAssertTrue(locked.error?.message.contains("locked") == true, locked.error?.message ?? "")
        XCTAssertEqual(file, before)
    }

    func testASetupTokensPlanChangesWithoutPastingItAgain() async throws {
        let token = "sk-ant-oat01-" + String(repeating: "P", count: 95)
        let c = await core()
        try await add(c, "sub", .setupToken, secret: token, plan: "max")
        try await create(c, "a", account: "sub")
        let v = try await XCTUnwrapAsync(await c.vault(of: "a"))
        XCTAssertEqual(v.sessionEnvironment()["CLAUDE_CODE_SUBSCRIPTION_TYPE"], "max")
        let writes = keychain.writes.count
        let rows = try await ok(c, edit("sub", plan: "Pro"))
        XCTAssertEqual(rows.first { $0.name == "sub" }?.plan, "pro")
        XCTAssertEqual(file.accounts.first { $0.name == "sub" }?.plan, "pro")
        XCTAssertEqual(v.sessionEnvironment()["CLAUDE_CODE_SUBSCRIPTION_TYPE"], "pro", "sessions started from now on get it")
        XCTAssertEqual(keychain.writes.count, writes, "the token was not written again")
        XCTAssertEqual(keychain.get("doz-claude:sub"), token)
        let bad = await c.handle(edit("sub", plan: "gold"))
        XCTAssertEqual(bad.error?.code, .invalid)
        // Both at once: renamed, and its plan.
        let both = try await ok(c, edit("sub", newName: "sub2", plan: "team"))
        XCTAssertEqual(both.first { $0.name == "sub2" }?.plan, "team")
        XCTAssertEqual(keychain.get("doz-claude:sub2"), token)
        let cfg = await c.config(of: "a")
        XCTAssertEqual(cfg?.account, "sub2")
        XCTAssertEqual(v.sessionEnvironment()["CLAUDE_CODE_SUBSCRIPTION_TYPE"], "team")
    }

    /// The value replaced (`doz account add NAME --force`, the dashboard's Replace the key): the name keeps its default,
    /// its sandboxes, its place in the list and — a setup token without --plan — its plan.
    func testReplacingTheValueKeepsTheDefaultTheSandboxesAndThePlan() async throws {
        let c = await core()
        let t1 = "sk-ant-oat01-" + String(repeating: "A", count: 95), t2 = "sk-ant-oat01-" + String(repeating: "B", count: 95)
        try await add(c, "first", .apiKey, secret: apiKey)
        try await add(c, "sub", .setupToken, secret: t1, plan: "team")
        try await add(c, "last", .apiKey, secret: apiKey + "3")
        var d = HostRequest(.accountDefault)
        d.account = "sub"
        try await ok(c, d)
        try await create(c, "a", account: "sub")
        try await create(c, "b")
        let order = file.accounts.map(\.name)
        let rows = try await ok(c, HostRequest.accountAdd(name: "sub", kind: .setupToken, plan: nil, secret: t2, force: true))
        XCTAssertEqual(keychain.get("doz-claude:sub"), t2)
        let sub = try XCTUnwrap(rows.first { $0.name == "sub" })
        XCTAssertEqual(sub.plan, "team", "kept without --plan")
        XCTAssertTrue(sub.isDefault)
        XCTAssertEqual(sub.usedBy.sorted(), ["a", "b"])
        XCTAssertEqual(sub.fingerprint, CredentialFingerprint.of(t2))
        XCTAssertEqual(file.accounts.map(\.name), order, "it keeps its place")
        XCTAssertEqual(file.defaultAccount, "sub")
        let cfg = await c.config(of: "a")
        XCTAssertEqual(cfg?.account, "sub")
        let v = try await XCTUnwrapAsync(await c.vault(of: "a"))
        XCTAssertEqual(v.sessionEnvironment()["CLAUDE_CODE_SUBSCRIPTION_TYPE"], "team")
        // --plan still wins.
        let again = try await ok(c, HostRequest.accountAdd(name: "sub", kind: .setupToken, plan: "max", secret: t1, force: true))
        XCTAssertEqual(again.first { $0.name == "sub" }?.plan, "max")
    }

    func testTheCLICommandsParse() throws {
        XCTAssertTrue(try DozableCommand.parseAsRoot(["account", "rename", "work", "team"]) is AccountRename)
        XCTAssertThrowsError(try DozableCommand.parseAsRoot(["account", "rename", "work", "Bad Name"]))
        XCTAssertThrowsError(try DozableCommand.parseAsRoot(["account", "rename", "work", "mac"]))
        XCTAssertThrowsError(try DozableCommand.parseAsRoot(["account", "rename", "work"]))
        XCTAssertTrue(try DozableCommand.parseAsRoot(["account", "set-plan", "sub", "pro"]) is AccountSetPlan)
        XCTAssertThrowsError(try DozableCommand.parseAsRoot(["account", "set-plan", "sub", "gold"]))
    }
}
