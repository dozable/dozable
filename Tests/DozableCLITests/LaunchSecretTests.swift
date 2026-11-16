import Foundation
import XCTest
@testable import DozableCLI
@testable import DozableHost
@testable import DozableKit

// 692 — `--secret VAR,src=PATH,to=HOST:PORT[,header=NAME][,file=FILEVAR]` in the CLI and the daemon, without a VM or the
// login Keychain (MemoryKeychain / FakeKeychain only). Every secret value here is an obviously fake string.

private let fakeValue = "FAKE-LAUNCH-SECRET-0123456789abcdef"

/// A scratch folder with a 0600 secret file in it.
private func scratch(_ tag: String) throws -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("doz-692-\(tag)-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return URL(fileURLWithPath: HostCore.resolvedRoot(u.path))
}

private func secretFile(_ dir: URL, _ name: String = "token", _ content: String = fakeValue + "\n", mode: Int = 0o600) throws -> String {
    let p = dir.appendingPathComponent(name).path
    FileManager.default.createFile(atPath: p, contents: Data(content.utf8), attributes: [.posixPermissions: mode])
    return p
}

private func grant(_ variable: String = "SERVER_TOKEN", file: String? = nil, host: String = "host.dozable.internal", port: UInt16 = 8780,
                   value: String = fakeValue, source: String = "/nonexistent/outside/token") -> LaunchSecretGrant {
    LaunchSecretGrant(secret: LaunchSecret(variable: variable, fileVariable: file, host: host, port: port, fingerprint: "ignored-by-daemon"),
                      value: value, source: source)
}

final class LaunchSecretTests: XCTestCase {
    func testTheFlagsForm() throws {
        let s = try LaunchSecrets.parse("SERVER_TOKEN,src=~/.config/token,to=host.dozable.internal:8780,file=SERVER_TOKEN_FILE", home: "/Users/someone")
        XCTAssertEqual(s, LaunchSecrets.Spec(variable: "SERVER_TOKEN", fileVariable: "SERVER_TOKEN_FILE", source: "/Users/someone/.config/token",
                                             host: "host.dozable.internal", port: 8780, header: "authorization", bearer: true))
        let h = try LaunchSecrets.parse("API_KEY,to=svc.example.com:8443,src=/k,header=X-Service-Token")
        XCTAssertEqual(h.header, "x-service-token")
        XCTAssertFalse(h.bearer, "any other header gets the raw value")
        XCTAssertTrue(try LaunchSecrets.parse("TK,src=/k,to=10.0.0.5:9000,header=authorization").bearer)
        XCTAssertEqual(try LaunchSecrets.parse("TK,src=/k,to=100.64.0.9:8080").host, "100.64.0.9")
    }

    /// Every refusal, with its message.
    func testEveryRefusal() {
        func refused(_ word: String, _ fragment: String, line: UInt = #line) {
            XCTAssertThrowsError(try LaunchSecrets.parse(word, home: "/h"), word, line: line) { e in
                XCTAssertTrue(HostError.from(e).message.contains(fragment), "\(word): \(HostError.from(e).message)", line: line)
            }
        }
        refused("src=/k,to=host.dozable.internal:8780", "the variable comes first")
        refused("lower,src=/k,to=a.example.com:1", "an upper-case variable name")
        for own in ["ANTHROPIC_API_KEY", "ANTHROPIC_BASE_URL", "CLAUDE_CODE_OAUTH_TOKEN", "GH_TOKEN", "GITHUB_TOKEN", "OPENAI_API_KEY", "HTTPS_PROXY",
                    "NO_PROXY", "NODE_EXTRA_CA_CERTS", "DOZ_X"] {
            refused("\(own),src=/k,to=a.example.com:1", own == "DOZ_X" ? "an upper-case variable name" : "one of Dozable's own variables")
        }
        refused("TK,src=/k,to=a.example.com:1,file=HTTP_PROXY", "file= HTTP_PROXY is one of Dozable's own variables")
        refused("TK,src=/k,to=a.example.com:1,file=TK", "another variable")
        refused("TK,src=/a,b,to=a.example.com:1", "a comma inside PATH is refused")
        refused("TK,src=/k,to=a.example.com:1,src=/j", "given twice")
        refused("TK,src=/k,to=a.example.com:1,mode=x", "unknown mode=")
        refused("TK,to=a.example.com:1", "src=PATH is required")
        refused("TK,src=/k", "to=HOST:PORT is required")
        refused("TK,src=/k,to=a.example.com", "the port is required")
        refused("TK,src=/k,to=a.example.com:0", "a number from 1 to 65535")
        refused("TK,src=/k,to=a.example.com:70000", "a number from 1 to 65535")
        refused("TK,src=/k,to=mac.dozable.internal:8780", "alias")
        refused("TK,src=/k,to=[::1]:8780", "IPv6")
        refused("TK,src=/k,to=fd7a::1:8780", "IPv6")
        refused("TK,src=/k,to=localhost:8780", "loopback")
        refused("TK,src=/k,to=127.0.0.1:8780", "loopback")
        refused("TK,src=/k,to=169.254.169.254:80", "link-local")
        refused("TK,src=/k,to=api.github.com:443", "already holds keys for")
        refused("TK,src=/k,to=api.openai.com:443", "already holds keys for")
        refused("TK,src=/k,to=api.anthropic.com:443", "already holds keys for")
        refused("TK,src=/k,to=single:80", "a host name like")
        refused("TK,src=/k,to=a.example.com:1,header=host", "header=host")
        refused("TK,src=/k,to=a.example.com:1,header=proxy-authorization", "proxy-authorization")
        refused("TK,src=/k,to=a.example.com:1,header=bad header", "header=")
        // This Mac's own addresses (an injected interface list).
        XCTAssertThrowsError(try LaunchSecrets.destination("192.168.7.7:8780", variable: "TK", own: [[192, 168, 7, 7]])) { e in
            XCTAssertTrue(HostError.from(e).message.contains("this Mac's own"))
        }
        XCTAssertNoThrow(try LaunchSecrets.destination("192.168.7.8:8780", variable: "TK", own: [[192, 168, 7, 7]]))
        // Together: at most four, each variable once (a FILEVAR included).
        XCTAssertThrowsError(try LaunchSecrets.check((1...5).map { ("T\($0)", nil) }))
        XCTAssertThrowsError(try LaunchSecrets.check([("A", "F"), ("F", nil)]))
        XCTAssertThrowsError(try LaunchSecrets.check([("A", nil), ("A", nil)]))
        XCTAssertNoThrow(try LaunchSecrets.check([("A", "AF"), ("B", "BF")]))
    }

    /// The value never reaches a record, the ledger, an answer, `--json`, the log or a session's variables.
    func testValueNeverEncoded() async throws {
        let root = try scratch("store")
        let outside = try scratch("outside")
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        let keychain = MemoryKeychain()
        let c = HostCore(store: DozableStore(root: root), readOnly: false, version: "test", services: LaunchSecretLifetimeTests.services(keychain, root))
        await c.load()
        var r = HostRequest(.create, name: "sb")
        var o = CreateOptions(image: "claude-code", account: "none")
        o.isolated = true
        o.hostPorts = [HostPort(port: 8780)]
        r.create = o
        r.secrets = [grant(file: "SERVER_TOKEN_FILE", source: try secretFile(outside))]
        let m = await c.handle(r)
        XCTAssertNil(m.error, m.error?.message ?? "")
        let info = try XCTUnwrap(m.result).decode(SandboxInfo.self)
        XCTAssertEqual(info.secretLines?.first?.hasPrefix("secret SERVER_TOKEN → host.dozable.internal:8780 (fp \(CredentialFingerprint.of(fakeValue))"), true,
                       info.secretLines?.description ?? "")
        let vault = try await XCTUnwrapAsync(await c.vault(of: "sb"))
        let env = vault.sessionEnvironment()
        XCTAssertEqual(env["SERVER_TOKEN"]?.hasPrefix("doz_cred_"), true, "a placeholder in VAR")
        await c.persistPlaceholders("sb")
        var report = HostRequest(.netPermissions, name: "sb")
        report.v = HostProtocol.version
        let shown = await c.handle(report)
        let rep = try XCTUnwrap(shown.result).decode(PermissionReport.self)
        let row = try XCTUnwrap(rep.secrets?.first)
        XCTAssertEqual(rep.secrets?.count, 1)
        XCTAssertEqual([row.variable, row.to, row.header, row.fingerprint], ["SERVER_TOKEN", "host.dozable.internal:8780", "authorization (Bearer)", CredentialFingerprint.of(fakeValue)])
        XCTAssertTrue(row.plainHTTP)
        // Everything Dozable wrote, every answer: no value.
        for any in [try HostWire.encoder.encode(info), try HostWire.encoder.encode(rep), try HostWire.encoder.encode(await c.config(of: "sb"))] {
            XCTAssertFalse(String(decoding: any, as: UTF8.self).contains(fakeValue))
        }
        let files = FileManager.default.enumerator(atPath: root.path)?.allObjects as? [String] ?? []
        XCTAssertTrue(files.contains("secrets.json"))
        for f in files {
            guard let d = FileManager.default.contents(atPath: root.appendingPathComponent(f).path) else { continue }
            XCTAssertFalse(String(decoding: d, as: UTF8.self).contains(fakeValue), f)
        }
        XCTAssertFalse(env.values.contains(fakeValue))
        // The one copy outside the daemon's memory is its own keychain item.
        let service = LaunchSecrets.service(store: root, owner: "sb", variable: "SERVER_TOKEN")
        XCTAssertTrue(service.hasPrefix("doz-secret-") && service.hasSuffix("-sb-SERVER_TOKEN"))
        XCTAssertEqual(keychain.read(service: service, account: nil).value, fakeValue)
    }

    /// `-e VAR=` for a secret's variable (or its FILEVAR) is refused — at launch and on any later run or exec.
    func testEnvironmentForASecretVariableIsRefused() async throws {
        let root = try scratch("env")
        defer { try? FileManager.default.removeItem(at: root) }
        let c = HostCore(store: DozableStore(root: root), readOnly: false, version: "test", services: LaunchSecretLifetimeTests.services(MemoryKeychain(), root))
        await c.load()
        try await LaunchSecretLifetimeTests.create(c, "sb", [grant(file: "TF")])
        for (op, key) in [(HostOp.openSession, "SERVER_TOKEN"), (.openSession, "TF"), (.exec, "SERVER_TOKEN")] {
            var r = HostRequest(op, name: "sb")
            r.argv = ["true"]
            r.environment = [key: "x"]
            let m = await c.handle(r)
            XCTAssertEqual(m.error?.message, "-e \(key): \(key) carries a secret's placeholder — give it with --secret", "\(op)")
        }
        // At launch too (the run's own secret).
        var r = HostRequest(.openSession, name: "sb")
        r.environment = ["NEW_T": "x"]
        r.secrets = [grant("NEW_T")]
        let launched = await c.handle(r)
        XCTAssertEqual(launched.error?.message, "-e NEW_T: NEW_T carries a secret's placeholder — give it with --secret")
        XCTAssertHelpers.refusesUnfenced()
    }
}

/// `--unfenced --secret` is refused by the CLI (and the daemon refuses a secret for an unfenced `@mac` request).
enum XCTAssertHelpers {
    static func refusesUnfenced() {
        XCTAssertThrowsError(try Run.parse(["@mac", "--unfenced", "--secret", "TK,src=/k,to=a.example.com:1", "--", "true"]).validate()) { e in
            XCTAssertTrue("\(e)".contains("an unfenced session has no proxy to hold a secret"), "\(e)")
        }
        XCTAssertNoThrow(try Run.parse(["sb", "--secret", "TK,src=/k,to=a.example.com:1", "--", "true"]).validate(), "a sandbox takes it")
    }
}

final class LaunchSecretSourceTests: XCTestCase {
    func testTheFileRules() throws {
        let d = try scratch("src")
        defer { try? FileManager.default.removeItem(at: d) }
        let ok = try secretFile(d, "ok", fakeValue + "\r\n")
        XCTAssertEqual(try LaunchSecrets.read(ok, variable: "TK").value, fakeValue, "trailing CR/LF trimmed")
        func refused(_ path: String, _ fragment: String, line: UInt = #line) {
            XCTAssertThrowsError(try LaunchSecrets.read(path, variable: "TK"), line: line) { e in
                let msg = HostError.from(e).message
                XCTAssertTrue(msg.contains(fragment), msg, line: line)
                XCTAssertFalse(msg.contains("FAKE"), "never the content", line: line)
            }
        }
        refused(try secretFile(d, "world", mode: 0o644), "chmod go-rwx")
        refused(try secretFile(d, "group", mode: 0o640), "chmod go-rwx")
        let link = d.appendingPathComponent("link").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: ok)
        refused(link, "is a link")
        refused(d.path, "not a regular file")
        refused(try secretFile(d, "big", String(repeating: "A", count: 1801)), "1800")
        XCTAssertNoThrow(try LaunchSecrets.read(try secretFile(d, "max", String(repeating: "A", count: 1800) + "\n"), variable: "TK"))
        refused(try secretFile(d, "crlf", "FAKE-A\r\nInjected: header"), "printable ASCII")
        refused(try secretFile(d, "space", "FAKE A"), "printable ASCII")
        refused(try secretFile(d, "empty", "\n"), "empty")
        refused(d.appendingPathComponent("missing").path, "cannot be opened")
    }

    /// The daemon's own checks: a file inside the workspace (or any root a fenced session reads) is refused; the value is
    /// checked again; the destination must be reachable as given.
    func testTheDaemonChecksAgain() async throws {
        let root = try scratch("daemon")
        let ws = try scratch("ws")
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: ws) }
        let c = HostCore(store: DozableStore(root: root), readOnly: false, version: "test", services: LaunchSecretLifetimeTests.services(MemoryKeychain(), root))
        await c.load()
        func create(_ name: String, _ g: LaunchSecretGrant, workspace: String? = nil, hostPorts: [HostPort] = [HostPort(port: 8780)], allow: [String]? = nil) async -> String? {
            var r = HostRequest(.create, name: name)
            var o = CreateOptions(image: "claude-code", workspace: workspace, account: "none")
            if workspace == nil { o.isolated = true }
            o.hostPorts = hostPorts
            o.allow = allow
            r.create = o
            r.secrets = [g]
            return (await c.handle(r)).error?.message
        }
        let inside = try secretFile(ws)
        let e1 = await create("a", grant(source: inside), workspace: ws.path)
        XCTAssertTrue(e1?.contains("is inside its workspace") == true, e1 ?? "nil")
        let e2 = await create("b", grant(value: "FAKE\r\nX: y"))
        XCTAssertTrue(e2?.contains("printable ASCII") == true, e2 ?? "nil")
        let e3 = await create("c", grant(port: 8781))
        XCTAssertTrue(e3?.contains("needs that port of this Mac open to it — add --host-port 8781") == true, e3 ?? "nil")
        let e4 = await create("d", grant(host: "svc.example.com", port: 8443))
        XCTAssertTrue(e4?.contains("is not reachable from it — add --allow site:svc.example.com:8443") == true, e4 ?? "nil")
        let e5 = await create("e", grant(host: "svc.example.com", port: 8443), allow: ["site:svc.example.com:8443"])
        XCTAssertNil(e5, e5 ?? "")
        let e6 = await create("f", grant(host: "api.openai.com", port: 443))
        XCTAssertTrue(e6?.contains("already holds keys for") == true, e6 ?? "nil")
        let e7 = await create("g", grant("T1"), hostPorts: [])
        XCTAssertTrue(e7?.contains("--host-port 8780") == true, e7 ?? "nil")
        // Nothing was made by a refused create.
        let cfg8 = await c.config(of: "a")
        XCTAssertNil(cfg8)
        // A non-proxied sandbox has no proxy to hold one.
        var r = HostRequest(.create, name: "nat")
        var o = CreateOptions(image: "lab", network: "nat")
        o.isolated = true
        r.create = o
        r.secrets = [grant()]
        let nat = await c.handle(r)
        XCTAssertTrue(nat.error?.message.contains("needs a proxied network") == true, nat.error?.message ?? "")
    }
}

final class LaunchSecretLifetimeTests: XCTestCase {
    static func services(_ k: KeychainAccess, _ root: URL) -> CredentialServices {
        CredentialServices(keychain: k, verifier: FakeVerifier(answer: .verified), claudeBinary: { nil }, home: root,
                           keepaliveRunner: FakeRunner(), isClaudeRunning: { false }, watchInterval: .seconds(3600))
    }

    @discardableResult
    static func create(_ c: HostCore, _ name: String, _ grants: [LaunchSecretGrant]) async throws -> SandboxInfo {
        var r = HostRequest(.create, name: name)
        var o = CreateOptions(image: "claude-code", account: "none")
        o.isolated = true
        o.hostPorts = [HostPort(port: 8780)]
        r.create = o
        r.secrets = grants
        let m = await c.handle(r)
        if let e = m.error { throw e }
        return try XCTUnwrap(m.result).decode(SandboxInfo.self)
    }

    private var root: URL!
    override func setUpWithError() throws { root = try scratch("life") }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func swap(_ v: CredentialVault, _ t: String) -> CredentialDecision {
        v.rewrite(head: Array("GET / HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer \(t)\r\n\r\n".utf8), host: "host.dozable.internal", port: 8780)
    }

    /// One keychain shared by two daemons: the second re-reads the item and honours the first's placeholder (by its hash).
    func testNewDaemonRereads() async throws {
        let keychain = MemoryKeychain()
        let c1 = HostCore(store: DozableStore(root: root), readOnly: false, version: "test", services: Self.services(keychain, root))
        await c1.load()
        try await Self.create(c1, "sb", [grant()])
        let v1 = try await XCTUnwrapAsync(await c1.vault(of: "sb"))
        let t = try XCTUnwrap(v1.mint("secret:SERVER_TOKEN"))
        await c1.persistPlaceholders("sb")
        let c2 = HostCore(store: DozableStore(root: root), readOnly: false, version: "test", services: Self.services(keychain, root))
        await c2.load()
        let v2 = try await XCTUnwrapAsync(await c2.vault(of: "sb"))
        guard case .swapped(let out, _) = swap(v2, t) else { return XCTFail("the new daemon did not swap the old placeholder") }
        XCTAssertTrue(String(decoding: out, as: UTF8.self).contains("Bearer \(fakeValue)"))
        // A new daemon whose keychain has nothing (memory-only, a new process): the placeholder is answered 401 with why.
        let c3 = HostCore(store: DozableStore(root: root), readOnly: false, version: "test", services: Self.services(MemoryKeychain(), root))
        await c3.load()
        let v3 = try await XCTUnwrapAsync(await c3.vault(of: "sb"))
        guard case .refuse(401, let why) = swap(v3, t) else { return XCTFail("not a 401") }
        XCTAssertTrue(why.contains("no secret behind SERVER_TOKEN's placeholder now"), why)
    }

    /// Shutdown (and reset, rm) revokes: the binding and its placeholders gone ("unknown or revoked"), the item deleted, the
    /// record cleared.
    func testShutdownRevokes() async throws {
        let keychain = MemoryKeychain()
        let c = HostCore(store: DozableStore(root: root), readOnly: false, version: "test", services: Self.services(keychain, root))
        await c.load()
        try await Self.create(c, "sb", [grant(), grant("SECOND", port: 8780)])
        let v = try await XCTUnwrapAsync(await c.vault(of: "sb"))
        let t = try XCTUnwrap(v.mint("secret:SERVER_TOKEN"))
        let service = LaunchSecrets.service(store: root, owner: "sb", variable: "SERVER_TOKEN")
        XCTAssertNotNil(keychain.read(service: service, account: nil).value)
        _ = await c.handle(HostRequest(.shutdown, name: "sb"))
        guard case .reject(let why) = swap(v, t) else { return XCTFail("not revoked") }
        XCTAssertEqual(why, "an unknown or revoked credential placeholder")
        XCTAssertNil(keychain.read(service: service, account: nil).value)
        XCTAssertTrue(keychain.items(servicePrefix: LaunchSecrets.servicePrefix).isEmpty)
        let cfg = await c.config(of: "sb")
        XCTAssertNil(cfg?.secrets)
        XCTAssertTrue(LaunchSecretLedger.load(DozableStore(root: root)).items.isEmpty)
        // A sandbox made without one records none (an older record decodes with none: the field is optional).
        try await Self.create(c, "plain", [])
        let cfg9 = await c.config(of: "plain")
        XCTAssertNil(cfg9?.secrets)
        let plainFile = try String(contentsOf: DozableStore(root: root).configFile("plain"), encoding: .utf8)
        XCTAssertFalse(plainFile.contains("\"secrets\""))
        // rm too.
        try await Self.create(c, "sb2", [grant()])
        _ = await c.handle(HostRequest(.rm, name: "sb2"))
        XCTAssertTrue(keychain.items(servicePrefix: LaunchSecrets.servicePrefix).isEmpty)
    }

    /// Given again for the same VAR (`doz run NAME --secret`): the value replaced, the old placeholder valid for it.
    func testGivenAgainReplaces() async throws {
        let keychain = MemoryKeychain()
        let c = HostCore(store: DozableStore(root: root), readOnly: false, version: "test", services: Self.services(keychain, root))
        await c.load()
        try await Self.create(c, "sb", [grant()])
        let v = try await XCTUnwrapAsync(await c.vault(of: "sb"))
        let t = try XCTUnwrap(v.mint("secret:SERVER_TOKEN"))
        var r = HostRequest(.openSession, name: "sb")
        r.argv = ["true"]
        r.secrets = [grant(value: "FAKE-SECOND-VALUE")]
        _ = await c.handle(r)          // the session cannot open (no VM); the secret was added first
        guard case .swapped(let out, _) = swap(v, t) else { return XCTFail() }
        XCTAssertTrue(String(decoding: out, as: UTF8.self).contains("FAKE-SECOND-VALUE"))
        let cfg10 = await c.config(of: "sb")
        XCTAssertEqual(cfg10?.secrets?.count, 1)
        // Never copied to a duplicate.
        var d = HostRequest(.duplicate, name: "sb")
        d.newName = "copy"
        _ = await c.handle(d)
        if let copy = await c.config(of: "copy") { XCTAssertNil(copy.secrets) }
    }

    /// A locked keychain: kept in memory only, and the launch line says so — never a refused launch.
    func testALockedKeychainKeepsItInMemory() async throws {
        let keychain = FakeKeychain()
        keychain.failWrites = [LaunchSecrets.service(store: root, owner: "sb", variable: "SERVER_TOKEN")]
        let c = HostCore(store: DozableStore(root: root), readOnly: false, version: "test", services: Self.services(keychain, root))
        await c.load()
        let info = try await Self.create(c, "sb", [grant()])
        XCTAssertTrue(info.secretLines?.first?.hasSuffix("— kept until the daemon stops (the login keychain is locked)") == true, info.secretLines?.description ?? "")
        let cfg11 = await c.config(of: "sb")
        XCTAssertNil(cfg11?.secrets?.first?.keychainService)
        let v = try await XCTUnwrapAsync(await c.vault(of: "sb"))
        let t = try XCTUnwrap(v.mint("secret:SERVER_TOKEN"))
        guard case .swapped = swap(v, t) else { return XCTFail("memory holds it") }
    }

    /// The sweep: an item in the ledger whose owner is gone is deleted at a daemon's start; a live owner's stays.
    func testTheSweepRemovesOrphans() async throws {
        let keychain = MemoryKeychain()
        let store = DozableStore(root: root)
        let c = HostCore(store: store, readOnly: false, version: "test", services: Self.services(keychain, root))
        await c.load()
        try await Self.create(c, "sb", [grant()])
        let orphan = LaunchSecrets.service(store: root, owner: "gone", variable: "X")
        let orphanMac = LaunchSecrets.service(store: root, owner: LaunchSecrets.macOwner("old"), variable: "X")
        try keychain.write(service: orphan, account: "u", secret: "FAKE-ORPHAN")
        try keychain.write(service: orphanMac, account: "u", secret: "FAKE-ORPHAN")
        var ledger = LaunchSecretLedger.load(store)
        ledger.items[orphan] = "gone"
        ledger.items[orphanMac] = LaunchSecrets.macOwner("old")
        ledger.save(store)
        let c2 = HostCore(store: store, readOnly: false, version: "test", services: Self.services(keychain, root))
        await c2.load()
        await c2.recoverAfterStart()
        XCTAssertNil(keychain.read(service: orphan, account: nil).value)
        XCTAssertNil(keychain.read(service: orphanMac, account: nil).value)
        XCTAssertNotNil(keychain.read(service: LaunchSecrets.service(store: root, owner: "sb", variable: "SERVER_TOKEN"), account: nil).value)
        XCTAssertEqual(Set(LaunchSecretLedger.load(store).items.values), ["sb"])
    }
}

final class MacFenceSecretTests: XCTestCase {
    let s = LaunchSecret(variable: "SERVER_TOKEN", fileVariable: "SERVER_TOKEN_FILE", host: "host.dozable.internal", port: 8780, fingerprint: "abc123abc123")

    func testTheBindingOfAVariable() {
        XCTAssertEqual(MacFence.binding(ofVariable: "SERVER_TOKEN", secrets: [s]), "secret:SERVER_TOKEN")
        XCTAssertEqual(MacFence.binding(ofVariable: "SERVER_TOKEN"), "claude-oauth", "unknown variables keep the old default")
        XCTAssertEqual(MacFence.binding(ofVariable: "GH_TOKEN", secrets: [s]), "github")
        let b = s.binding(plainHTTP: true)
        XCTAssertEqual(b.id, "secret:SERVER_TOKEN")
        XCTAssertEqual(b.swapOnly, true)
        XCTAssertEqual(b.port, 8780)
        XCTAssertEqual(b.hosts, ["host.dozable.internal"])
        XCTAssertEqual(b.header, .bearer)
        XCTAssertEqual(LaunchSecret(variable: "K", host: "a.example.com", port: 1, header: "x-k", bearer: false, fingerprint: "f").binding(plainHTTP: false).header,
                       .apiKey(name: "x-k"))
    }

    /// The environment: VAR the placeholder, FILEVAR the file; the record keeps the hash under `secret:VAR` and the record,
    /// never a value; a record from before decodes with none.
    func testEnvironmentFileAndRecord() throws {
        let d = try scratch("fence")
        defer { try? FileManager.default.removeItem(at: d) }
        let places = MacFencePlaces(home: d.path, store: d.path + "/store", socketDirectory: d.path + "/s", userTemp: d.path + "/t/", dozConfig: d.path + "/.config/doz")
        var f = MacFence(places: places, session: "s1", workdir: d.path + "/w", sessionFolder: d.path + "/fence/s1", readable: [], writable: [],
                         homeReads: .init(), keychain: false, tag: "t")
        f.secrets = [s]
        let token = HostCore.newPlaceholder()
        f.placeholders["SERVER_TOKEN"] = token
        try FileManager.default.createDirectory(atPath: f.etc, withIntermediateDirectories: true)
        f.secretFiles = try HostCore.writeFenceSecretFiles(f)
        let path = f.etc + "/secrets/SERVER_TOKEN"
        XCTAssertEqual(f.secretFiles, ["SERVER_TOKEN_FILE": path])
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), token)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        var env: [String: String] = ["PATH": "/usr/bin"]
        MacFenceEnvironment.add(&env, fence: f)
        XCTAssertEqual(env["SERVER_TOKEN"], token)
        XCTAssertEqual(env["SERVER_TOKEN_FILE"], path)
        let r = f.record(profileSHA256: "x", gitBaseline: nil)
        XCTAssertEqual(r.placeholderHashes, [CredentialFingerprint.placeholderHash(token): "secret:SERVER_TOKEN"])
        XCTAssertEqual(r.secrets, [s])
        let json = String(decoding: try HostWire.encoder.encode(r), as: UTF8.self)
        XCTAssertFalse(json.contains(token), "never the placeholder itself")
        var old = r
        old.secrets = nil
        let decoded = try HostWire.decoder.decode(MacFenceRecord.self, from: try HostWire.encoder.encode(old))
        XCTAssertNil(decoded.secrets)
        // The capabilities and the agent's facts say where it goes — never a value.
        var shape = MacCapabilityShape(session: "s1", workdir: f.workdir, fenced: true)
        shape.hasNetwork = true
        shape.secrets = [s]
        let caps = MacFence.capabilities(shape)
        let cap = try XCTUnwrap(caps.first { $0.id == "secrets" })
        XCTAssertTrue(cap.sentence.contains("SERVER_TOKEN holds a placeholder Dozable swaps for a secret on requests to host.dozable.internal:8780"), cap.sentence)
    }

    func testTheSettingIsInTheClosedSchemaAndOnByDefault() {
        let d = DozableSettings.schema.first { $0.key == SettingKey.placeholdersPlainHTTP }
        XCTAssertEqual(SettingKey.placeholdersPlainHTTP, "network.placeholders_plain_http")
        XCTAssertEqual(d?.defaultValue, .bool(true))
        XCTAssertEqual(d?.applies, .nextSession)
        XCTAssertTrue(DozableSettings(text: nil).bool(SettingKey.placeholdersPlainHTTP))
        XCTAssertFalse(d?.summary.contains("692") ?? true)
    }
}
