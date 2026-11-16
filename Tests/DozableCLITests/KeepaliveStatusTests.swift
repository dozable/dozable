import Foundation
import DozableKit
import XCTest
@testable import DozableCLI
@testable import DozableHost

// 695 — what is kept and shown about the login keep-alive: the mode in accounts.json (as an older doz reads it), the record
// `<store>/keepalive.json`, the lines of `account ls` / `daemon status`, doctor's row, the follow-up question's decision.
// No token anywhere (a fake one is fed in and looked for).
final class KeepaliveStatusTests: XCTestCase {
    private var root: URL!
    let fakeToken = "sk-ant-ort01-FAKEFAKEFAKEFAKEFAKEFAKEFAKE"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("doz-ka-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    /// The bool an older doz reads stays true for on and always; the new field is optional and only says always.
    func testTheModeIsReadSanelyByAnOlderDoz() throws {
        var f = AccountsFile()
        XCTAssertEqual(KeepaliveMode.of(f), .off)
        f.keepaliveSetting = .always
        XCTAssertTrue(f.keepalive)
        XCTAssertEqual(f.keepaliveMode, "always")
        let json = String(decoding: try HostWire.encoder.encode(f), as: UTF8.self)
        XCTAssertTrue(json.contains(#""keepalive":true"#) && json.contains(#""keepaliveMode":"always""#), json)
        // An older doz's shape of the same file (no keepaliveMode): it reads "on".
        struct Older: Codable { var keepalive: Bool }
        XCTAssertEqual(try HostWire.decoder.decode(Older.self, from: Data(json.utf8)).keepalive, true)
        f.keepaliveSetting = .on
        XCTAssertNil(f.keepaliveMode)
        XCTAssertFalse(String(decoding: try HostWire.encoder.encode(f), as: UTF8.self).contains("keepaliveMode"), "on writes only the bool")
        // A file written before this release decodes (no field), and one an older doz turned off is off.
        XCTAssertEqual(KeepaliveMode.of(try HostWire.decoder.decode(AccountsFile.self, from: Data(#"{"version":1,"defaultAccount":"mac","keepalive":true,"accounts":[]}"#.utf8))), .on)
        XCTAssertEqual(KeepaliveMode.of(try HostWire.decoder.decode(AccountsFile.self, from: Data(#"{"version":1,"defaultAccount":"mac","keepalive":false,"keepaliveMode":"always","accounts":[]}"#.utf8))), .off)
    }

    func testTheRecordIsOwnerOnlyKeepsTheLastRenewalAndHoldsNoToken() throws {
        let store = DozableStore(root: root)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        try KeepaliveRecord(account: "mac", mode: "always", lastAttemptAt: t0, outcome: .renewed, exit: 0,
                            expiresBefore: t0.addingTimeInterval(300), expiresAfter: t0.addingTimeInterval(28_800), nextTryAt: t0.addingTimeInterval(28_200)).save(store)
        let mode = ((try FileManager.default.attributesOfItem(atPath: KeepaliveRecord.url(store).path))[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(mode, 0o600)
        try KeepaliveRecord(account: "mac", mode: "always", lastAttemptAt: t0.addingTimeInterval(28_300), outcome: .failed,
                            reason: "exit 1: refresh failed for \(fakeToken)", exit: 1, expiresBefore: t0.addingTimeInterval(28_800)).save(store)
        let r = try XCTUnwrap(KeepaliveRecord.read(store))
        XCTAssertEqual(r.outcome, .failed)
        XCTAssertEqual(r.lastRenewedAt, t0, "the last renewal is kept across a later try")
        XCTAssertEqual(r.renewedUntil, t0.addingTimeInterval(28_800))
        let raw = try String(contentsOf: KeepaliveRecord.url(store), encoding: .utf8)
        XCTAssertFalse(raw.contains("sk-ant") || raw.contains("FAKEFAKE"), raw)
        XCTAssertEqual(r.reason, "exit 1: refresh failed for …")
    }

    func testCleanReplacesTokenShapedTextAndKeepsItShort() {
        XCTAssertEqual(KeepaliveRecord.clean("exit 1: OAuth token has expired"), "exit 1: OAuth token has expired")
        XCTAssertEqual(KeepaliveRecord.clean("Authorization: Bearer abc.def"), "Authorization: …")
        XCTAssertFalse(KeepaliveRecord.clean("token eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.c2lnbmF0dXJl here").contains("eyJ"))
        XCTAssertEqual(KeepaliveRecord.clean("a\nb"), "a b")
        XCTAssertLessThanOrEqual(KeepaliveRecord.clean(String(repeating: "word ", count: 100)).count, 200)
    }

    func testTheLines() {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        let hm = CredentialVaultClock.hm
        var rec = KeepaliveRecord(account: "mac", mode: "always", lastAttemptAt: t, outcome: .renewed, exit: 0,
                                  expiresBefore: t.addingTimeInterval(300), expiresAfter: t.addingTimeInterval(28_800))
        let ok = KeepaliveStatus(mode: .always, record: rec, expiresAt: t.addingTimeInterval(28_800))
        XCTAssertEqual(ok.line(now: t), "keep-alive always · last renewed \(hm(t)) (until \(hm(t.addingTimeInterval(28_800)))) · next try \(hm(t.addingTimeInterval(28_800)))")
        rec = KeepaliveRecord(account: "mac", mode: "always", lastAttemptAt: t, outcome: .failed, reason: "exit 1: no network", exit: 1,
                              expiresBefore: t.addingTimeInterval(300))
        let failed = KeepaliveStatus(mode: .always, record: rec, expiresAt: t.addingTimeInterval(300))
        XCTAssertTrue(failed.line(now: t).hasPrefix("keep-alive always · last try \(hm(t)) FAILED (exit 1: no network)"), failed.line(now: t))
        XCTAssertTrue(failed.failed)
        XCTAssertTrue(failed.line(now: t).hasSuffix("no other try for this login: it renews when Claude Code is next used on this Mac (or doz account keepalive is set again)"), failed.line(now: t))
        let changed = KeepaliveStatus(mode: .always, record: rec, expiresAt: t.addingTimeInterval(9000))
        XCTAssertTrue(changed.line(now: t).hasSuffix("next try \(hm(t.addingTimeInterval(9000)))"), "the login changed since: tried at its expiry")
        let retry = KeepaliveRecord(account: "mac", mode: "always", lastAttemptAt: t, outcome: .unchanged, reason: "x", exit: 0,
                                    expiresBefore: t, expiresAfter: t, nextTryAt: t.addingTimeInterval(60))
        XCTAssertEqual(KeepaliveStatus(mode: .always, record: retry, expiresAt: t).nextTryAt, t.addingTimeInterval(60), "an unchanged run: its retry")
        XCTAssertEqual(KeepaliveStatus(mode: .off, record: nil, expiresAt: t).line(now: t), "keep-alive off (doz account keepalive on|always)")
        let fresh = KeepaliveStatus(mode: .on, record: nil, expiresAt: t.addingTimeInterval(3600))
        XCTAssertEqual(fresh.line(now: t), "keep-alive on · no renewal yet · next try \(hm(t.addingTimeInterval(3600))) if a sandbox or fenced session uses the login")
        let locked = KeepaliveStatus(mode: .always, record: nil, expiresAt: t.addingTimeInterval(3600), keychainLocked: "ssh")
        XCTAssertTrue(locked.line(now: t).hasSuffix("never run by this daemon: it was started where the login keychain is locked (ssh)"), locked.line(now: t))
        // Another account's record is not this one's.
        XCTAssertNil(KeepaliveStatus(mode: .always, account: "work-mac", record: rec, expiresAt: nil).outcome)
    }

    func testDoctorsRow() {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        let failedRec = KeepaliveRecord(account: "mac", mode: "always", lastAttemptAt: t, outcome: .failed, reason: "exit 1: x", exit: 1)
        var c = Doctor.keepaliveCheck(KeepaliveStatus(mode: .always, record: failedRec, expiresAt: nil), mode: .always, daemonRunning: true, inUse: false, now: t)
        XCTAssertEqual(c.check, "Claude login keep-alive")
        XCTAssertEqual(c.status, .warn)
        XCTAssertTrue(c.detail.contains("FAILED (exit 1: x)"), c.detail)
        c = Doctor.keepaliveCheck(KeepaliveStatus(mode: .always, record: nil, expiresAt: nil, keychainLocked: "ssh"), mode: .always, daemonRunning: true, inUse: true, now: t)
        XCTAssertEqual(c.status, .warn)
        c = Doctor.keepaliveCheck(KeepaliveStatus(mode: .on, record: nil, expiresAt: nil), mode: .on, daemonRunning: true, inUse: false, now: t)
        XCTAssertEqual(c.status, .warn, "on with nothing using the login never runs")
        XCTAssertTrue(c.detail.contains("doz account keepalive always"))
        c = Doctor.keepaliveCheck(KeepaliveStatus(mode: .on, record: nil, expiresAt: nil), mode: .on, daemonRunning: true, inUse: true, now: t)
        XCTAssertEqual(c.status, .ok)
        c = Doctor.keepaliveCheck(KeepaliveStatus(mode: .off, record: nil, expiresAt: nil), mode: .off, daemonRunning: false, inUse: false, now: t)
        XCTAssertEqual(c.status, .ok)
        let renewed = KeepaliveRecord(account: "mac", mode: "always", lastAttemptAt: t, outcome: .renewed, exit: 0, expiresAfter: t.addingTimeInterval(28_800))
        c = Doctor.keepaliveCheck(KeepaliveStatus(mode: .always, record: renewed, expiresAt: nil), mode: .always, daemonRunning: true, inUse: false, now: t)
        XCTAssertEqual(c.status, .ok)
        XCTAssertFalse(c.detail.contains("sk-ant"))
    }

    /// The follow-up question: only on a terminal, never --json/-q, never in a test run (this one is), never when always.
    func testTheFollowUpQuestionsDecision() {
        let person: [String: String] = [:]
        XCTAssertEqual(KeepaliveOffer.decide(mode: .off, terminal: true, json: false, env: ["DOZ_TEST_REAL_MAC": "1"]), .ask)
        XCTAssertEqual(KeepaliveOffer.decide(mode: .on, terminal: false, json: false, env: ["DOZ_TEST_REAL_MAC": "1"]), .hint)
        XCTAssertEqual(KeepaliveOffer.decide(mode: .off, terminal: true, json: true, env: ["DOZ_TEST_REAL_MAC": "1"]), .none)
        XCTAssertEqual(KeepaliveOffer.decide(mode: .off, terminal: true, json: false, quiet: true, env: ["DOZ_TEST_REAL_MAC": "1"]), .none)
        XCTAssertEqual(KeepaliveOffer.decide(mode: .always, terminal: true, json: false, env: ["DOZ_TEST_REAL_MAC": "1"]), .none)
        XCTAssertEqual(KeepaliveOffer.decide(mode: .off, terminal: true, json: false, env: person), .hint, "this XCTest run is guarded: never asked")
        XCTAssertEqual(KeepaliveOffer.decide(mode: .off, terminal: true, json: false, env: ["DOZ_TEST_GUARD": "1"]), .hint)
    }

    /// `account ls`'s line under the table: one for one Mac login, named when there are several.
    func testAccountListLines() {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        func row(_ n: String, _ k: KeepaliveStatus?) -> AccountRow {
            AccountRow(name: n, kind: k == nil ? "api-key" : "mac", plan: nil, identity: nil, expiresAt: nil, verification: nil, isDefault: false,
                       usedBy: [], state: "ok", keepalive: k)
        }
        let k = KeepaliveStatus(mode: .off, record: nil, expiresAt: nil)
        XCTAssertEqual(keepaliveLines([row("mac", k), row("work", nil)], now: t), "keep-alive off (doz account keepalive on|always)\n")
        XCTAssertEqual(keepaliveLines([row("mac", k), row("other", k)], now: t),
                       "mac: keep-alive off (doz account keepalive on|always)\nother: keep-alive off (doz account keepalive on|always)\n")
    }
}
