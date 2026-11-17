import Darwin
import DozableChat
import DozableKit
import Foundation
import XCTest
@testable import DozableHost

/// Webhook bots under the daemon: the address rule, the pipe the entries travel on, the supervisor (entries from the
/// keychain SEAM only — a `MemoryKeychain` or a test keychain here, never the login keychain — handed on descriptor 3, never
/// argv, the environment or a file), and the webhook client's refusal of a certificate nobody trusts. Neutral names; the
/// values are sentinels.
final class ChatWebhookAddressTests: XCTestCase {
    func testTheAddressRule() {
        for ok in ["https://bot.example/hook", "https://bot.example:8443/a/b?c=d", "https://203.0.113.9/x", "https://[2001:db8::1]/x",
                   "http://127.0.0.1:9000/x", "http://localhost:9000/x", "http://[::1]:9000/x", "http://100.100.1.2:8080/x", "http://127.0.0.2/x"] {
            XCTAssertNil(ChatWebhookAddress.refusal(url: ok, header: "Bearer s-1"), ok)
        }
        for (bad, says) in [("http://192.168.1.5/x", "plain http"), ("http://bot.example/x", "plain http"), ("http://100.128.0.1/x", "plain http"),
                            ("https://0.0.0.0/x", "unspecified"), ("https://[::]/x", "unspecified"), ("https://224.0.0.1/x", "multicast"),
                            ("https://255.255.255.255/x", "broadcast"), ("https://169.254.169.254/x", "link-local"), ("https://[fe80::1]/x", "link-local"),
                            ("https://u:p@bot.example/x", "user or password"), ("https://bot.example/x#f", "fragment"), ("ftp://bot.example/x", "https://"),
                            ("https://bot.example/a b", "space"), ("https://bot.example/\u{7}", "control"), ("", "no address"),
                            ("https://bot.example/" + String(repeating: "a", count: 2048), "longer than 2048")] {
            let why = ChatWebhookAddress.refusal(url: bad, header: "")
            XCTAssertTrue(why?.contains(says) == true, "\(bad): \(why ?? "nil")")
            XCTAssertFalse(why?.contains("bot.example") == true, "a refusal never quotes the address")
        }
        XCTAssertNotNil(ChatWebhookAddress.refusal(url: "https://bot.example/x", header: "Bearer a\r\nX-Evil: 1"))
        XCTAssertNotNil(ChatWebhookAddress.refusal(url: "https://bot.example/x", header: String(repeating: "a", count: 1025)))
        XCTAssertEqual(ChatWebhookAddress.parts("https://Bot.Example:8443/p?q"), .init(scheme: "https", host: "Bot.Example", port: 8443))
        XCTAssertEqual(ChatWebhookAddress.parts("https://[2001:db8::1]/p")?.host, "2001:db8::1")
    }

    func testThePipesShape() throws {
        let ok = try ChatWebhookPipe.parse(Data(#"{"version":1,"webhooks":{"bot1":{"url":"https://bot.example/p","header":"Bearer s"},"bot2":{"url":"http://192.168.1.5/p","header":""},"default":{"url":"https://x.example/","header":""}}}"#.utf8))
        XCTAssertEqual(ok.webhooks, ["bot1": ChatWebhook(url: "https://bot.example/p", header: "Bearer s")])
        XCTAssertEqual(Set(ok.refused.keys), ["bot2", "default"], "a refused address and the shared name are dropped and named")
        XCTAssertFalse(ok.refused.values.contains { $0.contains("192.168") })
        XCTAssertThrowsError(try ChatWebhookPipe.parse(Data(#"{"version":1,"tokens":{"bot1":"t-0123456789abcdef"}}"#.utf8)), "tokens never come this way")
        XCTAssertThrowsError(try ChatWebhookPipe.parse(Data(#"{"version":2,"webhooks":{}}"#.utf8)))
        XCTAssertThrowsError(try ChatWebhookPipe.parse(Data(#"{"version":1,"webhooks":{"bot1":{"url":"https://a/","header":"","x":1}}}"#.utf8)))
    }

    func testThePipeIsReadToItsEndAndOnlyAPipe() throws {
        var p: [Int32] = [-1, -1]
        XCTAssertEqual(pipe(&p), 0)
        let bytes = ChatWebhookEntries.pipeBytes(["bot1": ChatWebhookEntry(url: "https://bot.example/p", authorization: "Bearer s", set: "")])
        _ = bytes.withUnsafeBytes { write(p[1], $0.baseAddress!, $0.count) }
        close(p[1])
        XCTAssertEqual(try ChatWebhookPipe.read(fd: p[0]), bytes)
        XCTAssertEqual(fcntl(p[0], F_GETFD), -1, "closed after reading")
        // A regular file is not the daemon's pipe.
        let f = "/tmp/dzc-pipe-\(getpid())"
        FileManager.default.createFile(atPath: f, contents: bytes)
        defer { unlink(f) }
        let fd = open(f, O_RDONLY)
        XCTAssertThrowsError(try ChatWebhookPipe.read(fd: fd))
        // A writer that never closes: the deadline.
        XCTAssertEqual(pipe(&p), 0)
        defer { close(p[1]) }
        XCTAssertThrowsError(try ChatWebhookPipe.read(fd: p[0], deadline: 0.3))
    }

    func testTheInputIsTwoLines() throws {
        XCTAssertEqual(try ChatWebhookEntries.parseInput(Data("https://bot.example/p\nBearer s\n".utf8)).authorization, "Bearer s")
        XCTAssertEqual(try ChatWebhookEntries.parseInput(Data("https://bot.example/p\r\n\r\n".utf8)).authorization, "")
        XCTAssertEqual(try ChatWebhookEntries.parseInput(Data("https://bot.example/p\n".utf8)).url, "https://bot.example/p")
        XCTAssertThrowsError(try ChatWebhookEntries.parseInput(Data("https://bot.example/p\nBearer s\nthird\n".utf8)))
        XCTAssertThrowsError(try ChatWebhookEntries.parseInput(Data("\nBearer s\n".utf8)))
        XCTAssertNotNil(ChatWebhookEntries.nameRefusal("default"))
        XCTAssertNil(ChatWebhookEntries.nameRefusal("bot1"))
    }

    /// No action of the dashboard reaches a `chat-*` operation (and so never a webhook entry): DozableWeb names none.
    func testNoWebActionMapsToAChatOperation() throws {
        let web = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/DozableWeb")
        let files = try FileManager.default.contentsOfDirectory(atPath: web.path).filter { $0.hasSuffix(".swift") }
        XCTAssertFalse(files.isEmpty)
        let chatOps = HostOp.allCases.filter { $0.rawValue.hasPrefix("chat-") }
        XCTAssertTrue(chatOps.contains(.chatWebhookSet))
        for f in files {
            let text = try String(contentsOfFile: web.appendingPathComponent(f).path, encoding: .utf8)
            for op in chatOps {
                XCTAssertFalse(text.contains("." + String(describing: op)) || text.contains("\"" + op.rawValue + "\""), "\(f) names \(op.rawValue)")
            }
        }
    }
}

/// A keychain the test can lock and that counts its reads.
final class TestKeychain: KeychainAccess, @unchecked Sendable {
    let lock = NSLock()
    var items: [String: String] = [:]
    var locked = false
    var reads = 0
    func read(service: String, account: String?) -> KeychainRead {
        lock.withLock { reads += 1; return locked ? .locked : (items[service].map(KeychainRead.found) ?? .absent) }
    }
    func write(service: String, account: String, secret: String) throws {
        try Keychain.checkSecretSize(secret, service: service)
        try lock.withLock { if locked { throw HostError(.failed, "locked") }; items[service] = secret }
    }
    func delete(service: String, account: String) throws { lock.withLock { items[service] = nil } }
    func items(servicePrefix: String) -> [KeychainItemInfo] { [] }
}

final class ChatWebhookSupervisorTests: XCTestCase {
    var root: String!
    var fake: FakeChatProcesses!
    var box: SettingsBox!
    var keychain: TestKeychain!
    var locked: LockedBox!
    var sup: ChatSupervisor!
    var paths: ChatPaths { ChatPaths(folder: root + "/chat") }

    final class LockedBox: @unchecked Sendable { var why: String? }

    let url = "https://h-\(UUID().uuidString.prefix(8).lowercased()).invalid/p-\(UUID().uuidString.prefix(8).lowercased())"
    let secret = "Bearer s-\(UUID().uuidString)"

    override func setUpWithError() throws {
        root = "/tmp/dzc-wh-\(getpid())-\(UUID().uuidString.prefix(6))"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        fake = FakeChatProcesses()
        box = SettingsBox()
        keychain = TestKeychain()
        locked = LockedBox()
        let b = box!, l = locked!
        sup = ChatSupervisor(paths: ChatPaths(folder: root + "/chat"), executable: "/usr/bin/false", release: "0.0.0", processes: fake,
                             environment: [:], keychain: keychain, keychainLocked: { l.why }, unreadableRetrySeconds: 0.2, readSettings: { b.get() })
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(atPath: root) }

    func on() async throws {
        box.set(true)
        _ = try await sup.sync(human: "ada", retry: true, waitReady: false, blocked: false)
    }

    /// Every byte the supervisor wrote, and everything a process listing would show of its children.
    func everythingVisible() async throws -> String {
        var out = ""
        for f in try FileManager.default.subpathsOfDirectory(atPath: paths.folder) {
            out += (try? String(contentsOfFile: paths.folder + "/" + f, encoding: .utf8)) ?? ""
        }
        for (a, e) in zip(fake.spawned, fake.environments) { out += a.joined(separator: " ") + e.map { $0.key + "=" + $0.value }.joined(separator: " ") }
        let st = await sup.status()
        out += String(decoding: try ChatServerState.encoder.encode(st), as: UTF8.self)
        return out
    }

    func testAWebhookBotsEntryGoesOnDescriptorThreeOnly() async throws {
        try await on()
        _ = try await sup.add("bot1", token: nil, kind: "grok-bot", webhook: true)
        // The generated config: the bot by its entry's name, never an address.
        let config = try String(contentsOfFile: paths.config, encoding: .utf8)
        XCTAssertTrue(config.contains(#""deliver": "webhook""#) && config.contains(#""webhook": "bot1""#) && config.contains(#""kind": "grok-bot""#))
        // No entry yet: nothing on descriptor 3, the state says so.
        XCTAssertNil(fake.inputs.last!)
        XCTAssertFalse(fake.spawned.last!.contains("--webhooks-fd"))
        var st = await sup.status()
        XCTAssertEqual(st.webhooks, ["bot1": "not set"])
        XCTAssertTrue(st.warnings?.first?.contains("no webhook entry bot1") == true)

        let before = fake.spawnCount
        let info = try await sup.setWebhook("bot1", url: url, authorization: secret)
        XCTAssertEqual(info.state, "set")
        XCTAssertEqual(info.host, ChatWebhookAddress.parts(url)!.host)
        XCTAssertEqual(info.fingerprint?.count, 12)
        XCTAssertEqual(fake.spawnCount, before + 1, "a set restarts the server")
        let args = fake.spawned.last!
        XCTAssertEqual(Array(args.suffix(2)), ["--webhooks-fd", "3"])
        let input = try XCTUnwrap(fake.inputs.last!)
        XCTAssertEqual(try ChatWebhookPipe.parse(input).webhooks, ["bot1": ChatWebhook(url: url, header: secret)])
        st = await sup.status()
        XCTAssertEqual(st.webhooks, ["bot1": "set"])
        XCTAssertNil(st.warnings)
        // The value is in the keychain item (one, at most 1800 bytes) and nowhere the supervisor writes or shows.
        XCTAssertEqual(keychain.items.count, 1)
        XCTAssertTrue(keychain.items.keys.first!.hasPrefix(ChatWebhookEntries.servicePrefix))
        XCTAssertLessThanOrEqual(keychain.items.values.first!.utf8.count, Keychain.maximumSecretBytes)
        let seen = try await everythingVisible()
        let path = String(url.split(separator: "/").last!)
        XCTAssertFalse(seen.contains(path) || seen.contains(secret) || seen.contains(ChatWebhookAddress.parts(url)!.host), "no path, secret or host in a file, argv, the environment or the state")
        for f in try FileManager.default.subpathsOfDirectory(atPath: paths.folder) {
            var s = stat()
            XCTAssertEqual(lstat(paths.folder + "/" + f, &s), 0)
            XCTAssertEqual(s.st_mode & 0o077, 0, "\(f) is the user's alone")
        }
        // Read once: looking again does not ask the keychain every second.
        let reads = keychain.reads
        for _ in 0..<5 { await sup.tick(blocked: false) }
        XCTAssertEqual(keychain.reads, reads)
        // Removed: nothing on descriptor 3 again, a restart.
        let n = fake.spawnCount
        let gone = try await sup.removeWebhook("bot1")
        XCTAssertEqual(gone.usedBy, ["bot1"])
        XCTAssertEqual(fake.spawnCount, n + 1)
        XCTAssertNil(fake.inputs.last!)
        XCTAssertTrue(keychain.items.isEmpty)
    }

    func testWhatASetRefuses() async throws {
        try await on()
        _ = try await sup.add("bot1", token: nil, kind: "grok-bot", webhook: true)
        _ = try await sup.add("bot2", token: nil)
        await XCTAssertThrowsErrorAsync(try await sup.setWebhook("bot2", url: url, authorization: secret), "bot2 polls: no entry of its")
        await XCTAssertThrowsErrorAsync(try await sup.setWebhook("default", url: url, authorization: secret))
        await XCTAssertThrowsErrorAsync(try await sup.setWebhook("bot1", url: "http://192.168.1.5/p", authorization: secret))
        await XCTAssertThrowsErrorAsync(try await sup.setWebhook("bot1", url: "https://bot.example/" + String(repeating: "a", count: 1900), authorization: ""),
                                        "more than one keychain item holds")
        await XCTAssertThrowsErrorAsync(try await sup.add("bot3", token: nil, webhook: true, entry: "default"))
        await XCTAssertThrowsErrorAsync(try await sup.add("bot3", token: nil, kind: "robot"))
        locked.why = "an ssh session"
        await XCTAssertThrowsErrorAsync(try await sup.setWebhook("bot1", url: url, authorization: secret), "the keychain is locked: refused, never kept in memory")
        XCTAssertTrue(keychain.items.isEmpty)
        // The supervisor's input holds only what the keychain gave: none.
        XCTAssertTrue(fake.inputs.allSatisfy { $0 == nil })
    }

    func testAnEntryThatCannotBeReadIsWithheldAndTriedAgain() async throws {
        try await on()
        _ = try await sup.add("bot1", token: nil, kind: "grok-bot", webhook: true)
        _ = try await sup.setWebhook("bot1", url: url, authorization: secret)
        // A new daemon whose keychain is locked: the entry is withheld and said.
        keychain.locked = true
        let b = box!
        let f2 = FakeChatProcesses()
        let s2 = ChatSupervisor(paths: paths, executable: "/usr/bin/false", release: "0.0.0", processes: f2, environment: [:], keychain: keychain,
                                unreadableRetrySeconds: 0.2, readSettings: { b.get() })
        await s2.tick(blocked: false)
        var st = await s2.status()
        XCTAssertEqual(st.webhooks, ["bot1": "unreadable"])
        XCTAssertTrue(st.warnings?.contains { $0.contains("the webhook entry bot1 cannot be read: the login keychain is locked") } == true)
        XCTAssertEqual(f2.spawnCount, 1)
        XCTAssertNil(f2.inputs.last!, "withheld")
        // Unlocked: within the retry it is read, the files change, and the server restarts with it.
        keychain.locked = false
        try await Task.sleep(for: .milliseconds(300))
        await s2.tick(blocked: false)
        st = await s2.status()
        XCTAssertEqual(st.webhooks, ["bot1": "set"])
        XCTAssertEqual(f2.spawnCount, 2)
        XCTAssertNotNil(f2.inputs.last!)
        await s2.stopForExit()
    }

    func testOneEntryServesTwoBotsAndAnOldDirectoryReadsAsPollers() async throws {
        try await on()
        _ = try await sup.add("bot1", token: nil, kind: "grok-bot", webhook: true, entry: "shared")
        _ = try await sup.add("bot2", token: nil, kind: "grok-bot", webhook: true, entry: "shared")
        let d = try ChatDirectory.load(paths)
        XCTAssertEqual(d.webhookEntries, ["shared": ["bot1", "bot2"]])
        let info = try await sup.setWebhook("shared", url: url, authorization: "")
        XCTAssertEqual(info.usedBy, ["bot1", "bot2"])
        XCTAssertEqual(try ChatWebhookPipe.parse(try XCTUnwrap(fake.inputs.last!)).webhooks.keys.sorted(), ["shared"])
        // An older record (no deliver field) decodes as a poller.
        let old = try JSONDecoder().decode(ChatDirectory.self, from: Data(#"{"version":1,"human":"ada","participants":[{"name":"bot1","kind":"agent","added":"x"}]}"#.utf8))
        XCTAssertNil(old.participants[0].webhookEntry)
    }
}

/// The webhook client and a certificate no system root vouches for: the call fails, and the reason names no host, port
/// or header. The listener is the stand-in provider (a TLS server on 127.0.0.1 the test starts, with a throwaway CA).
final class ChatWebhookTLSTests: XCTestCase {
    func testABadCertificateFailsWithAReasonThatNamesNothing() async throws {
        let server = try StandInProvider()
        defer { server.stop() }
        let r = await ChatURLSessionWebhook().post(url: "https://127.0.0.1:\(server.port)/p-hidden", authorization: "Bearer s-hidden",
                                                   body: Array("{}".utf8), timeout: 10)
        guard case .unreachable(let why) = r else { return XCTFail("a certificate nobody trusts was accepted: \(r)") }
        XCTAssertTrue(why.hasPrefix("tls:"), why)
        for s in ["127.0.0.1", String(server.port), "p-hidden", "s-hidden"] { XCTAssertFalse(why.contains(s), "\(why) names \(s)") }
        XCTAssertTrue(server.requests.isEmpty, "nothing was sent over it")
    }
}
