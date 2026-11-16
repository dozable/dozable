import Foundation
import XCTest
@testable import DozableHost

/// 693: what an idle daemon does at each look — always on, the idle exit, restart in place, the hand-over, and a daemon
/// whose login keychain is locked (never always on).
final class IdleDecisionTests: XCTestCase {
    private func d(alwaysOn: Bool = true, locked: String? = nil, timeout: Double = 0, live: [String] = [], fenced: [String] = [],
                   keepers: Int = 0, connections: Int = 0, stopping: Bool = false, change: ExecutableIdentity.Change? = nil,
                   catalogue: Bool = false, idle: Double? = nil, launched: Bool = true) -> IdleDecision {
        IdleDecision(alwaysOnSetting: alwaysOn, keychainLocked: locked, timeoutMinutes: timeout, live: live, fenced: fenced, keepers: keepers,
                     connections: connections, stopping: stopping, executableChange: change, recipeCatalogueWaiting: catalogue,
                     idleSeconds: idle, launched: launched)
    }

    private func isExit(_ a: IdleDecision.Action) -> Bool { if case .exit = a { return true }; return false }
    private func isRestart(_ a: IdleDecision.Action) -> Bool { if case .restartInPlace = a { return true }; return false }
    private func isHandOver(_ a: IdleDecision.Action) -> Bool { if case .handOver = a { return true }; return false }

    func testAlwaysOnNeverIdlesOutWhateverTheTimeout() {
        XCTAssertEqual(d(timeout: 0, idle: 1_000_000).action, .stay)
        XCTAssertEqual(d(timeout: 5, idle: 1_000_000).action, .stay, "an older file's 5 minutes apply only when always on is off")
        XCTAssertNil(d(timeout: 5).effectiveTimeout)
        XCTAssertTrue(d().alwaysOn)
    }

    func testOffExitsAfterItsTimeoutAndZeroStillMeansNever() {
        XCTAssertEqual(d(alwaysOn: false, timeout: 5, idle: 299).action, .stay)
        XCTAssertTrue(isExit(d(alwaysOn: false, timeout: 5, idle: 300).action))
        XCTAssertEqual(d(alwaysOn: false, timeout: 0, idle: 1_000_000).action, .stay, "0 = never, as it always was")
        XCTAssertEqual(d(alwaysOn: false, timeout: 5, idle: nil).action, .stay, "not idle at the last look")
    }

    func testAnythingLiveKeepsItUp() {
        for x in [d(alwaysOn: false, timeout: 1, live: ["a"], idle: 999), d(alwaysOn: false, timeout: 1, fenced: ["s"], idle: 999),
                  d(alwaysOn: false, timeout: 1, keepers: 1, idle: 999), d(alwaysOn: false, timeout: 1, connections: 1, idle: 999)] {
            XCTAssertFalse(x.isIdle)
            XCTAssertEqual(x.action, .stay)
        }
        XCTAssertTrue(isExit(d(alwaysOn: false, timeout: 1, idle: 999).action), "the control: nothing at all → it exits")
        XCTAssertEqual(d(alwaysOn: false, timeout: 1, stopping: true, change: .replaced, idle: 999).action, .stay, "a stopping daemon does nothing more")
    }

    func testALockedDaemonIsNeverAlwaysOnAndExitsAfterFiveMinutes() {
        let locked = d(alwaysOn: true, locked: "ssh", timeout: 0)
        XCTAssertFalse(locked.alwaysOn)
        XCTAssertEqual(locked.effectiveTimeout, 5)
        XCTAssertEqual(d(locked: "ssh", timeout: 0, idle: 299).action, .stay)
        XCTAssertTrue(isExit(d(locked: "ssh", timeout: 0, idle: 300).action), "whatever the settings say")
        XCTAssertEqual(d(alwaysOn: false, locked: "ssh", timeout: 60).effectiveTimeout, 5, "never longer than 5 minutes")
        XCTAssertEqual(d(locked: "ssh", timeout: 0.05).effectiveTimeout, 0.05, "a shorter one (a test's) still applies")
        if case .exit(let why) = d(locked: "ssh", timeout: 0, idle: 300).action {
            XCTAssertTrue(why.contains("login keychain is locked"), why)
        }
        // Its program replaced, nothing live: it exits (the next command — from the desktop — starts a daemon that can read
        // the keychain), never restarts itself where the keychain is locked.
        XCTAssertTrue(isExit(d(locked: "ssh", change: .replaced).action))
        XCTAssertTrue(isHandOver(d(locked: "ssh", fenced: ["s"], change: .replaced).action), "fenced sessions are still handed over")
    }

    func testAProgramChangeRestartsInPlaceOnlyWhenNothingIsLiveAndNobodyIsConnected() {
        for c in [ExecutableIdentity.Change.replaced, .overwritten, .removed] {
            XCTAssertTrue(isRestart(d(change: c).action), c.rawValue)
            XCTAssertTrue(isExit(d(alwaysOn: false, change: c).action), "off: today's exit (\(c.rawValue))")
        }
        XCTAssertEqual(d(live: ["a"], change: .replaced).action, .stay, "a live sandbox: never")
        XCTAssertEqual(d(live: ["prepare claude-code"], change: .replaced).action, .stay, "a preparation: never")
        XCTAssertEqual(d(connections: 1, change: .replaced).action, .stay, "a client connected: never")
        XCTAssertTrue(isRestart(d(timeout: 0, change: .replaced, idle: nil).action), "the timeout plays no part (the bug: a timeout of 0 skipped it)")
        XCTAssertTrue(isExit(d(change: .replaced, launched: false).action), "a person's --foreground daemon exits, never replaced by a detached one")
    }

    func testANewerRecipeCatalogueIsTreatedLikeAProgramChange() {
        XCTAssertTrue(isRestart(d(catalogue: true).action))
        XCTAssertTrue(isExit(d(alwaysOn: false, catalogue: true).action))
        XCTAssertEqual(d(live: ["a"], catalogue: true).action, .stay)
        XCTAssertTrue(isHandOver(d(fenced: ["s"], catalogue: true).action))
    }

    func testFencedOrKeptSessionsAreHandedOver() {
        XCTAssertTrue(isHandOver(d(fenced: ["work"], change: .replaced).action))
        XCTAssertTrue(isHandOver(d(alwaysOn: false, fenced: ["work"], change: .replaced).action))
        XCTAssertTrue(isHandOver(d(keepers: 1, change: .removed).action))
        XCTAssertEqual(d(fenced: ["work"], connections: 1, change: .replaced).action, .stay)
    }

    func testTheLookIsPromptWhenItNeverIdlesOut() {
        XCTAssertEqual(IdleDecision.interval(effectiveTimeout: nil), 5)
        XCTAssertEqual(IdleDecision.interval(effectiveTimeout: 0.05), 0.75)
        XCTAssertEqual(IdleDecision.interval(effectiveTimeout: 5), 15)
        XCTAssertEqual(IdleDecision.interval(effectiveTimeout: 0.001), 0.5)
    }
}
