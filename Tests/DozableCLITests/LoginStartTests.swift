import XCTest
@testable import DozableHost

/// 694: `doz daemon start --login-item` decides — held vs the boot time, a locked idle daemon replaced, a live one kept,
/// nothing to do when always on is off and nothing is kept.
final class LoginStartTests: XCTestCase {
    let boot = Date(timeIntervalSince1970: 1_000_000)

    func testHeldSinceThisBootStartsNothingAndAnOlderHoldIsIgnored() {
        XCTAssertEqual(LoginStart.decide(heldAt: boot.addingTimeInterval(60), bootTime: boot, daemon: nil, alwaysOn: true, keepers: 0), .held)
        XCTAssertEqual(LoginStart.decide(heldAt: boot.addingTimeInterval(-60), bootTime: boot, daemon: nil, alwaysOn: true, keepers: 0), .start,
                       "a hold from before this boot is over: the next login starts it")
        XCTAssertEqual(LoginStart.decide(heldAt: nil, bootTime: boot, daemon: nil, alwaysOn: true, keepers: 0), .start)
    }

    func testARunningDaemonIsLeftAloneUnlessLockedAndIdle() {
        let unlocked = LoginStart.Daemon(pid: 42, keychainLocked: nil)
        XCTAssertEqual(LoginStart.decide(heldAt: nil, bootTime: boot, daemon: unlocked, alwaysOn: true, keepers: 0), .running(42))
        let lockedIdle = LoginStart.Daemon(pid: 43, keychainLocked: "ssh")
        XCTAssertEqual(LoginStart.decide(heldAt: nil, bootTime: boot, daemon: lockedIdle, alwaysOn: true, keepers: 0), .replaceLocked(43))
        XCTAssertEqual(LoginStart.decide(heldAt: nil, bootTime: boot, daemon: lockedIdle, alwaysOn: false, keepers: 0), .replaceLocked(43),
                       "replaced even with always on off: a person's next command should get a daemon that can read the keychain")
        XCTAssertEqual(LoginStart.decide(heldAt: nil, bootTime: boot, daemon: lockedIdle, alwaysOn: true, keepers: 0, selfLocked: true), .running(43),
                       "run from ssh itself: replacing locked with locked is pointless")
        for busy in [LoginStart.Daemon(pid: 44, keychainLocked: "ssh", live: ["box"]),
                     LoginStart.Daemon(pid: 44, keychainLocked: "ssh", preparations: ["claude-code"]),
                     LoginStart.Daemon(pid: 44, keychainLocked: "ssh", fenced: ["admin"]),
                     LoginStart.Daemon(pid: 44, keychainLocked: "ssh", keepers: 1)] {
            XCTAssertEqual(LoginStart.decide(heldAt: nil, bootTime: boot, daemon: busy, alwaysOn: true, keepers: 0), .running(44),
                           "a locked daemon that serves something is left (\(busy))")
        }
    }

    func testAlwaysOnOffWithNothingKeptStartsNothing() {
        XCTAssertEqual(LoginStart.decide(heldAt: nil, bootTime: boot, daemon: nil, alwaysOn: false, keepers: 0), .notNeeded)
        XCTAssertEqual(LoginStart.decide(heldAt: nil, bootTime: boot, daemon: nil, alwaysOn: false, keepers: 1), .start)
    }

    func testTheBootTimeSeamAndTheRealOne() {
        XCTAssertEqual(LoginStart.bootTime(environment: ["DOZ_TEST_GUARD": "1", "DOZ_TEST_BOOT_TIME": "1234.5"]), Date(timeIntervalSince1970: 1234.5))
        let real = LoginStart.bootTime(environment: [:])
        XCTAssertLessThan(real, Date())
        XCTAssertGreaterThan(real, Date(timeIntervalSince1970: 1_600_000_000))
    }

    func testTheHoldAndTheLog() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("doz-ls-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DozableStore(root: root)
        XCTAssertNil(LoginStart.heldAt(store))
        LoginStart.hold(store)
        XCTAssertNotNil(LoginStart.heldAt(store))
        LoginStart.release(store)
        XCTAssertNil(LoginStart.heldAt(store))
        LoginStart.log(store, "one")
        LoginStart.log(store, "two")
        let text = try String(contentsOf: store.loginItemLog, encoding: .utf8)
        XCTAssertEqual(text.split(separator: "\n").count, 2)
        XCTAssertTrue(text.contains("doz daemon start --login-item (pid \(getpid())): two"))
        // Above 256 KiB it is cut back.
        try Data(repeating: 0x41, count: DaemonLoginItem.logLimit + 10).write(to: store.loginItemLog)
        LoginStart.log(store, "three")
        let size = (try FileManager.default.attributesOfItem(atPath: store.loginItemLog.path)[.size] as? Int) ?? 0
        XCTAssertLessThan(size, 1024)
    }
}
