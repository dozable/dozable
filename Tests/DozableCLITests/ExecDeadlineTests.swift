import Foundation
import XCTest
@testable import DozableHost

/// 678: `doz exec`'s deadline — counted from the process's start (the kernel's record), found in argv without the parser
/// (the watchdog is armed before anything else runs), and enforced by the host whatever is under way.
final class ExecDeadlineTests: XCTestCase {
    func testTheArgvScan() {
        XCTAssertEqual(ExecDeadline.seconds(["exec", "lab", "--", "true"]), 120)
        XCTAssertEqual(ExecDeadline.seconds(["exec", "lab", "--timeout", "3", "--", "sleep", "30"]), 3)
        XCTAssertEqual(ExecDeadline.seconds(["exec", "--timeout=7", "lab", "--", "true"]), 7)
        XCTAssertEqual(ExecDeadline.seconds(["--store", "/tmp/s", "--json", "exec", "lab", "--timeout", "9", "--", "x"]), 9)
        XCTAssertEqual(ExecDeadline.seconds(["exec", "lab", "-e", "--timeout", "--", "true"]), 120, "an option's value is not the flag")
        XCTAssertEqual(ExecDeadline.seconds(["exec", "lab", "--", "x", "--timeout", "5"]), 120, "after -- it is the program's")
        XCTAssertNil(ExecDeadline.seconds(["exec", "lab", "--timeout", "0", "--", "true"]), "no deadline")
        XCTAssertNil(ExecDeadline.seconds(["run", "lab", "--", "exec"]))
        XCTAssertNil(ExecDeadline.seconds(["--store", "exec", "ls"]), "the store's value is no command")
        XCTAssertNil(ExecDeadline.seconds([]))
        XCTAssertNil(ExecDeadline.seconds(["--", "exec"]))
        XCTAssertEqual(ExecDeadline.seconds(["exec", "lab", "--timeout", "abc", "--", "true"]), 120, "the parser refuses it; the default stands")
    }

    func testTheProcessStartIsTheKernelsAndBeforeNow() throws {
        let s = try XCTUnwrap(ProcessStart.date)
        XCTAssertLessThanOrEqual(s.timeIntervalSinceNow, 0)
        XCTAssertGreaterThan(s.timeIntervalSinceNow, -86_400 * 7, "this test process started within the week")
        XCTAssertEqual(ProcessStart.of(getpid()), s)
        XCTAssertNil(ProcessStart.of(-1))
    }

    func testTheTimeLeft() {
        let now = Date()
        XCTAssertEqual(ExecDeadline.remaining(now.addingTimeInterval(2.2), now: now), 3, "rounded up")
        XCTAssertEqual(ExecDeadline.remaining(now.addingTimeInterval(-5), now: now), 1, "at least 1 for an older host")
        XCTAssertEqual(ExecDeadline.deadline(seconds: 3, start: now), now.addingTimeInterval(3))
        XCTAssertEqual(ExecDeadline.message(3), "doz: exec timed out after 3 s (counted from when doz started)")
    }

    func testTheAnswerAtTheDeadline() throws {
        let o = ExecOutput.timedOut(during: "waking", milliseconds: 12)
        XCTAssertEqual(o.exitCode, 124)
        XCTAssertEqual(o.timedOut, true)
        XCTAssertEqual(o.timedOutDuring, "waking")
        // An older CLI still decodes it (the fields are optional), and an older host's answer has none.
        let j = try HostWire.encoder.encode(o)
        XCTAssertEqual(try HostWire.decoder.decode(ExecOutput.self, from: j), o)
        let old = try HostWire.decoder.decode(ExecOutput.self, from: Data(#"{"exitCode":0,"stdout":"","stderr":"","milliseconds":1}"#.utf8))
        XCTAssertNil(old.timedOut)
        var r = HostRequest(.exec, name: "x")
        r.deadline = 1_800_000_000.5
        XCTAssertEqual(try HostWire.decoder.decode(HostRequest.self, from: HostWire.encoder.encode(r)).deadline, 1_800_000_000.5)
    }

    /// The host's race: at the deadline the answer is given while the work (a wake, a start) goes on to its end.
    func testTheRaceAnswersAtTheDeadlineAndTheWorkGoesOn() async throws {
        final class Done: @unchecked Sendable { var at: Date?; let lock = NSLock() }
        let done = Done()
        let work = Task { () throws -> Int in
            try await Task.sleep(nanoseconds: 800_000_000)
            done.lock.withLock { done.at = Date() }
            return 7
        }
        let t0 = Date()
        let r = try await HostCore.race(until: t0.addingTimeInterval(0.2), work)
        XCTAssertNil(r, "the deadline came first")
        XCTAssertLessThan(Date().timeIntervalSince(t0), 0.6)
        XCTAssertNil(done.lock.withLock { done.at }, "answered before the work ended")
        let v = try await work.value
        XCTAssertEqual(v, 7, "the work was not cancelled")
        XCTAssertNotNil(done.lock.withLock { done.at })

        // Work that ends first gives its value; its error is thrown.
        let three = try await HostCore.race(until: Date().addingTimeInterval(5), Task { () throws -> Int in 3 })
        XCTAssertEqual(three, 3)
        struct Boom: Error {}
        do {
            _ = try await HostCore.race(until: Date().addingTimeInterval(5), Task { () throws -> Int in throw Boom() })
            XCTFail("thrown")
        } catch is Boom {}
        // A deadline already gone: nothing is awaited.
        let gone = try await HostCore.race(until: Date().addingTimeInterval(-1), Task { () throws -> Int in 1 })
        XCTAssertNil(gone)
    }
}
