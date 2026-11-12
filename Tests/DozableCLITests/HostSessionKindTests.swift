import Foundation
import XCTest
@testable import DozableCLI
@testable import DozableHost

/// 679 B6: a host started from a session where the login keychain is locked (ssh) — the decision from the session's
/// attributes, the seam, what is said, and doctor's mismatch.
final class HostSessionKindTests: XCTestCase {
    typealias A = HostSessionKind.Attributes

    func testTheDecision() {
        XCTAssertNil(HostSessionKind.lockedReason(A(hasGraphicAccess: true, isRemote: false, sshEnvironment: false)), "the console login")
        XCTAssertEqual(HostSessionKind.lockedReason(A(hasGraphicAccess: false, isRemote: true, sshEnvironment: true)), "ssh")
        XCTAssertEqual(HostSessionKind.lockedReason(A(hasGraphicAccess: false, isRemote: false, sshEnvironment: true)), "ssh",
                       "SSH_CONNECTION and no GUI: an ssh session")
        XCTAssertEqual(HostSessionKind.lockedReason(A(hasGraphicAccess: true, isRemote: true, sshEnvironment: false)), "ssh", "remote")
        XCTAssertNil(HostSessionKind.lockedReason(A(hasGraphicAccess: true, isRemote: false, sshEnvironment: true)),
                     "ssh from inside a logged-in session (its own terminal): the login is there")
        XCTAssertEqual(HostSessionKind.lockedReason(A(hasGraphicAccess: false, isRemote: false, sshEnvironment: false)), "no login session")
    }

    func testTheSeamIsGuardedOnly() {
        XCTAssertEqual(HostSessionKind.lockedReason(environment: ["DOZ_TEST_GUARD": "1", "DOZ_TEST_KEYCHAIN_LOCKED": "1"]), "ssh")
        XCTAssertNil(HostSessionKind.lockedReason(environment: ["DOZ_TEST_GUARD": "1"]), "a guarded run's own session is no reason to warn")
        // Outside a guarded run the seam does nothing (XCTest is guarded by itself, so only REAL_MAC turns it off).
        let real = HostSessionKind.lockedReason(environment: ["DOZ_TEST_REAL_MAC": "1", "DOZ_TEST_KEYCHAIN_LOCKED": "1"])
        XCTAssertEqual(real, HostSessionKind.lockedReason(HostSessionKind.current(environment: [:])), "the seam is ignored: the real session decides")
    }

    func testWhatIsSaid() {
        var c = DateComponents()
        c.year = 2026; c.month = 11; c.day = 12; c.hour = 14; c.minute = 1
        let at = Calendar.current.date(from: c)!
        let a = HostSessionKind.hostAdvice(pid: 6720, startedAt: at, reason: "ssh")
        XCTAssertEqual(a, "the doz host (pid 6720, started 2:01 pm) was started from a session where the login keychain is locked (ssh) — run doz host restart from a logged-in session")
        XCTAssertTrue(HostSessionKind.startWarning("ssh").contains("cannot use this Mac's Claude login"))
    }

    func testDoctorFlagsTheMismatch() {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let fail = Doctor.hostLoginCheck(doctorReads: true, reason: "ssh", pid: 7, startedAt: at)
        XCTAssertEqual(fail.status, .fail)
        XCTAssertTrue(fail.detail.hasPrefix("doctor can read your Claude login, the host cannot — the doz host (pid 7"), fail.detail)
        let warn = Doctor.hostLoginCheck(doctorReads: nil, reason: "ssh", pid: 7, startedAt: at)
        XCTAssertEqual(warn.status, .warn)
        XCTAssertTrue(warn.detail.contains("doz host restart"))
    }

    func testTheStatusCarriesIt() throws {
        var s = HostStatus(version: "x", protocolVersion: 1, pid: 3, startedAt: Date(timeIntervalSince1970: 0), store: "/s",
                           idleTimeoutMinutes: 5, liveSandboxes: [], connections: 0, idleSeconds: nil)
        s.keychainLocked = "ssh"
        XCTAssertEqual(try HostWire.decoder.decode(HostStatus.self, from: HostWire.encoder.encode(s)).keychainLocked, "ssh")
    }
}
