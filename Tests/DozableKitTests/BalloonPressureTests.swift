import Foundation
import XCTest
@testable import DozableKit

/// 678 B7: the memory balloon's safety rules — the reserve an inflate leaves, when the host deflates, and a read that
/// never answers counting as "starving".
final class BalloonPressureTests: XCTestCase {
    func testTheReserveIsAtLeastHalfAndTwoGiBPlusWhatIsUsed() {
        XCTAssertEqual(BalloonPressure.reserveMiB(memoryMiB: 8192, usedMiB: 300), 4096, "half of 8 GiB is more than 2 GiB + 300")
        XCTAssertEqual(BalloonPressure.reserveMiB(memoryMiB: 8192, usedMiB: 3000), 5048, "2 GiB on top of what runs")
        XCTAssertEqual(BalloonPressure.reserveMiB(memoryMiB: 4096, usedMiB: 0), 2048)
        // Under 4 GiB: what is used plus half (a flat 2 GiB would leave a small sandbox no balloon at all).
        XCTAssertEqual(BalloonPressure.reserveMiB(memoryMiB: 2048, usedMiB: 100), 1124)
        XCTAssertEqual(BalloonPressure.reserveMiB(memoryMiB: 1024, usedMiB: 100), 612)
        // The wedged sandbox: 8 GiB, "keeps 2048" before — now at least 4 GiB stays free.
        XCTAssertGreaterThanOrEqual(BalloonPressure.reserveMiB(memoryMiB: 8192, usedMiB: 0), 4096)
    }

    func testTheDecision() {
        let reserve: UInt64 = 2048 * 1024
        XCTAssertEqual(BalloonPressure.decide(meminfo: ["MemAvailable": 3000 * 1024], reserveKiB: reserve), .hold)
        guard case .deflate(let why) = BalloonPressure.decide(meminfo: ["MemAvailable": 1500 * 1024], reserveKiB: reserve) else {
            return XCTFail("short: deflate")
        }
        XCTAssertTrue(why.contains("1500 MiB") && why.contains("2048 MiB"), why)
        guard case .deflate(let slow) = BalloonPressure.decide(meminfo: nil, reserveKiB: reserve) else { return XCTFail("no answer: deflate") }
        XCTAssertTrue(slow.contains("did not answer"), slow)
        if case .hold = BalloonPressure.decide(meminfo: ["MemFree": 9_999_999], reserveKiB: reserve) { XCTFail("no MemAvailable: deflate") }
    }

    func testABoundedReadNeverWaitsForAStuckGuest() async {
        let stuck = Task { () throws -> Int in try await Task.sleep(for: .seconds(5)); return 1 }
        let t0 = ContinuousClock.now
        let v = await BalloonPressure.value(of: stuck, within: .milliseconds(200))
        XCTAssertNil(v)
        XCTAssertLessThan(ContinuousClock.now - t0, .seconds(2))
        stuck.cancel()
        let quick = await BalloonPressure.value(of: Task { () throws -> Int in 7 }, within: .seconds(2))
        XCTAssertEqual(quick, 7)
        struct Boom: Error {}
        let r = await BalloonPressure.outcome(of: Task { () throws -> Int in throw Boom() }, within: .seconds(2))
        XCTAssertNotNil(r, "a failure is an answer, not a timeout")
        XCTAssertThrowsError(try r?.get())
        let none = await BalloonPressure.outcome(of: Task { () throws -> Int in try await Task.sleep(for: .seconds(5)); return 1 }, within: .milliseconds(100))
        XCTAssertNil(none, "a timeout is nil")
    }
}
