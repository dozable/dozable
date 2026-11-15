import Foundation
import DozableKit
import XCTest
@testable import DozableHost

// 687 — the Mac's Claude login from its two stores (the Keychain item, `~/.claude/.credentials.json`), read-only.
// A login made over ssh refreshes only the file (the Keychain is locked there); doz read only the Keychain and said the
// login expired. Every token here is made up; no real Keychain, no real file (a scratch file through the seam).

final class ClaudeMacLoginTests: XCTestCase {
    private var root: URL!
    let now = Date(timeIntervalSince1970: 2_000_000_000)

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().appendingPathComponent("doz-cml-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func token(_ access: String, _ expires: Date?) -> ClaudeLoginToken {
        ClaudeLogin.parse(claudeItem(access, expires: expires))!
    }

    /// The chooser: keychain valid / expired / missing / locked / unparsable × file valid / expired / missing /
    /// malformed / refused (a link).
    func testTheChooser_table() {
        let later = now.addingTimeInterval(7200), sooner = now.addingTimeInterval(600), past = now.addingTimeInterval(-600)
        let kValid = KeychainRead.found(claudeItem("kc-valid", expires: sooner))
        let kValidLater = KeychainRead.found(claudeItem("kc-later", expires: later))
        let kExpired = KeychainRead.found(claudeItem("kc-expired", expires: past))
        let fValid = ClaudeCredentialsFile.Read.token(token("file-valid", later))
        let fValidSooner = ClaudeCredentialsFile.Read.token(token("file-sooner", sooner))
        let fExpired = ClaudeCredentialsFile.Read.token(token("file-expired", past))
        struct Row { var k: KeychainRead; var f: ClaudeCredentialsFile.Read; var want: String; var line: UInt = #line }
        let rows: [Row] = [
            // Both unexpired: the one that expires later.
            Row(k: kValid, f: fValid, want: "file-valid@file"),
            Row(k: kValidLater, f: fValidSooner, want: "kc-later@keychain"),
            Row(k: kValid, f: .token(token("file-same", sooner)), want: "kc-valid@keychain"),        // a tie: the Keychain
            // One unexpired: that one.
            Row(k: kValid, f: fExpired, want: "kc-valid@keychain"),
            Row(k: kValid, f: .missing, want: "kc-valid@keychain"),
            Row(k: kValid, f: .malformed, want: "kc-valid@keychain"),
            Row(k: kValid, f: .refused, want: "kc-valid@keychain"),
            Row(k: kExpired, f: fValid, want: "file-valid@file"),                                    // THE ssh case
            Row(k: .absent, f: fValid, want: "file-valid@file"),
            Row(k: .locked, f: fValid, want: "file-valid@file"),                                     // a host over ssh
            Row(k: .failed, f: fValid, want: "file-valid@file"),
            Row(k: .found("not json"), f: fValid, want: "file-valid@file"),
            // No unexpired login in the file: the Keychain's answer as before.
            Row(k: kExpired, f: fExpired, want: "kc-expired@keychain"),
            Row(k: kExpired, f: .missing, want: "kc-expired@keychain"),
            Row(k: .absent, f: fExpired, want: "absent"),
            Row(k: .absent, f: .missing, want: "absent"),
            Row(k: .absent, f: .malformed, want: "absent"),
            Row(k: .absent, f: .refused, want: "absent"),
            Row(k: .locked, f: .missing, want: "locked"),
            Row(k: .locked, f: fExpired, want: "locked"),
            Row(k: .failed, f: .malformed, want: "failed"),
            Row(k: .found("not json"), f: .missing, want: "unparsable"),
        ]
        for r in rows {
            let got: String
            switch ClaudeMacLogin.choose(keychain: r.k, file: r.f, now: now) {
            case .token(let t, let s): got = "\(t.accessToken)@\(s.rawValue)"
            case .absent: got = "absent"
            case .locked: got = "locked"
            case .failed: got = "failed"
            case .unparsable: got = "unparsable"
            }
            XCTAssertEqual(got, r.want, line: r.line)
        }
        // A login with no expiry counts as unexpired; against a dated one it keeps the Keychain's.
        if case .token(let t, .keychain) = ClaudeMacLogin.choose(keychain: .found(claudeItem("kc-nodate", expires: nil)), file: fValid, now: now) {
            XCTAssertEqual(t.accessToken, "kc-nodate")
        } else { XCTFail("no-expiry keychain login") }
    }

    /// The file: a regular file of this user's, never a link, never too large; the access token kept, nothing else.
    func testTheFileReader() throws {
        let f = root.appendingPathComponent(".credentials.json").path
        XCTAssertEqual(ClaudeCredentialsFile.read(f), .missing)
        XCTAssertEqual(ClaudeCredentialsFile.read(nil), .missing)
        FileManager.default.createFile(atPath: f, contents: Data(claudeItem("file-tok", expires: now).utf8), attributes: [.posixPermissions: 0o600])
        guard case .token(let t) = ClaudeCredentialsFile.read(f) else { return XCTFail("a valid file") }
        XCTAssertEqual(t.accessToken, "file-tok")
        XCTAssertEqual(t.expiresAt, now)
        XCTAssertFalse(String(describing: t).contains("NEVER-USED"), "the refresh token is not kept")
        try Data("{\"claudeAiOauth\":{}}".utf8).write(to: URL(fileURLWithPath: f))
        XCTAssertEqual(ClaudeCredentialsFile.read(f), .malformed)
        try Data("garbage".utf8).write(to: URL(fileURLWithPath: f))
        XCTAssertEqual(ClaudeCredentialsFile.read(f), .malformed)
        let link = root.appendingPathComponent("link.json").path
        let real = root.appendingPathComponent("real.json").path
        FileManager.default.createFile(atPath: real, contents: Data(claudeItem("via-link", expires: now).utf8))
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)
        XCTAssertEqual(ClaudeCredentialsFile.read(link), .refused, "a link is never followed")
        let big = root.appendingPathComponent("big.json").path
        FileManager.default.createFile(atPath: big, contents: Data(count: ClaudeCredentialsFile.maximumBytes + 1))
        XCTAssertEqual(ClaudeCredentialsFile.read(big), .refused)
        let dir = root.appendingPathComponent("adir").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        XCTAssertEqual(ClaudeCredentialsFile.read(dir), .refused, "not a regular file")
    }

    /// Which file a process reads: a guarded run ONLY its seam; a run with the Mac-login seams none; else the person's.
    func testWhichFile_theSeams() {
        let home = URL(fileURLWithPath: "/Users/someone")
        XCTAssertNil(ClaudeCredentialsFile.path(configDir: nil, env: ["DOZ_TEST_GUARD": "1"], home: home), "guarded, no seam: no file")
        XCTAssertEqual(ClaudeCredentialsFile.path(configDir: nil, env: ["DOZ_TEST_GUARD": "1", "DOZ_TEST_CLAUDE_CREDENTIALS_FILE": "/s/c.json"], home: home), "/s/c.json")
        XCTAssertNil(ClaudeCredentialsFile.path(configDir: nil, env: ["DOZ_TEST_GUARD": "1", "DOZ_TEST_CLAUDE_CREDENTIALS_FILE": "rel.json"], home: home))
        // (XCTest is itself guarded: the real-run answers are asked with the guard lifted explicitly.)
        XCTAssertEqual(ClaudeCredentialsFile.path(configDir: nil, env: ["DOZ_TEST_REAL_MAC": "1"], home: home), "/Users/someone/.claude/.credentials.json")
        XCTAssertEqual(ClaudeCredentialsFile.path(configDir: "/cfg", env: ["DOZ_TEST_REAL_MAC": "1"], home: home), "/cfg/.credentials.json")
        XCTAssertNil(ClaudeCredentialsFile.path(configDir: nil, env: ["DOZ_TEST_REAL_MAC": "1", "DOZ_TEST_NO_MAC_LOGIN": "1"], home: home))
        XCTAssertNil(ClaudeCredentialsFile.path(configDir: nil, env: ["DOZ_TEST_REAL_MAC": "1", "DOZ_TEST_CREDENTIALS": "memory"], home: home))
        XCTAssertEqual(ClaudeLoginStore.keychain.label(configDir: nil), "the Keychain")
    }

    /// TestSafety: a guarded process never reads the person's real credentials file.
    func testTestSafety_theRealFileIsRefused() {
        let real = TestSafety.realHome
        XCTAssertNotNil(TestSafety.claudeCredentialsFileViolation(real.appendingPathComponent(".claude/.credentials.json").path))
        XCTAssertNotNil(TestSafety.claudeCredentialsFileViolation(real.appendingPathComponent("other-config/.credentials.json").path))
        XCTAssertNil(TestSafety.claudeCredentialsFileViolation("/tmp/scratch/.credentials.json"))
        XCTAssertNil(TestSafety.claudeCredentialsFileViolation(real.appendingPathComponent(".claude/settings.json").path), "only the credentials file")
        XCTAssertNil(TestSafety.claudeCredentialsFileViolation(root.appendingPathComponent(".credentials.json").path))
    }

    /// The status (doctor, account ls) and the watcher (what the proxy swaps in) use the file's login and say so.
    func testStatusAndWatcher_followTheFile() throws {
        let file = root.appendingPathComponent(".credentials.json").path
        let env = ["DOZ_TEST_GUARD": "1", "DOZ_TEST_CLAUDE_CREDENTIALS_FILE": file]
        let keychain = FakeKeychain()
        let svc = ClaudeLogin.baseService
        keychain.put(svc, claudeItem("kc-expired", expires: now.addingTimeInterval(-3600)))
        FileManager.default.createFile(atPath: file, contents: Data(claudeItem("file-fresh", expires: now.addingTimeInterval(3600)).utf8),
                                       attributes: [.posixPermissions: 0o600])
        let st = ClaudeLoginStatus.check(configDir: nil, keychain: keychain, probeBinary: false, home: root, now: now, env: env)
        XCTAssertEqual(st.state, .signedIn)
        XCTAssertEqual(st.store, .file)
        XCTAssertNil(st.problem(now: now), "seen as valid")
        XCTAssertTrue(st.summary(now: now).contains("from ") && st.summary(now: now).contains(".credentials.json"), st.summary(now: now))
        XCTAssertFalse(st.summary(now: now).contains("file-fresh"), "no token in what is said")
        // The watcher: the file's token goes to its subscribers; the store is named.
        let w = LoginWatcher(account: "mac", configDir: nil, keychain: keychain, pinned: nil, identityReader: { nil }, identityStamp: { nil },
                             credentialsFile: { file })
        let target = RecordingTarget()
        w.subscribe("sb", target)
        w.readNow(now: now)
        XCTAssertEqual(w.state, .ok)
        XCTAssertEqual(w.store, .file)
        XCTAssertEqual(target.last, "file-fresh")
        // Claude Code renews the Keychain's later: back to the Keychain (the later expiry).
        keychain.put(svc, claudeItem("kc-renewed", expires: now.addingTimeInterval(7200)))
        w.readNow(now: now)
        XCTAssertEqual(w.store, .keychain)
        XCTAssertEqual(target.last, "kc-renewed")
        // Both expired: the Keychain's expired one, as before (the proxy answers "expired", never another account's).
        keychain.put(svc, claudeItem("kc-old", expires: now.addingTimeInterval(-60)))
        FileManager.default.createFile(atPath: file, contents: Data(claudeItem("file-old", expires: now.addingTimeInterval(-60)).utf8))
        w.readNow(now: now)
        XCTAssertEqual(w.state, .expired)
        XCTAssertEqual(w.store, .keychain)
        // Nothing doz did wrote either store.
        XCTAssertTrue(keychain.writes.isEmpty)
        XCTAssertTrue((try String(contentsOfFile: file, encoding: .utf8)).contains("file-old"))
    }
}

/// A credential target that records what it was given (the token only — a made-up one).
final class RecordingTarget: CredentialTarget, @unchecked Sendable {
    private let lock = NSLock()
    private var _last: String?
    var last: String? { lock.withLock { _last } }
    var egress: EgressProxy? { nil }
    func setCredential(_ binding: CredentialBinding, secret: String?, expiresAt: Date?, environment: [String: String], notice: String?) {
        lock.withLock { _last = secret }
    }
}
