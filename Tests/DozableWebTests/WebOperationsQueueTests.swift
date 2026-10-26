import Foundation
import DozableKit
import DozableHost
import XCTest
@testable import DozableWeb

/// 650 — the lifecycle queue (`WebOperations`): queued instead of refused, the lane's width, a person's own request ahead
/// of a batch, the exempt pause, cancel, the bound, and a queued one across a `doz ui` restart. The host is `FakeData`,
/// whose `hold` keeps every operation it was sent open.
final class WebOperationsQueueTests: XCTestCase {
    var fake: FakeData!
    var hub: SSEHub!

    override func setUp() {
        fake = FakeData()
        fake.hold = true
        hub = SSEHub(maxClients: 4, capacity: 4096)
    }

    override func tearDown() {
        fake.hold = false
    }

    func make(width: Int, file: URL? = nil) -> WebOperations {
        WebOperations(data: fake, hub: hub, monitor: WebMonitor(data: fake, hub: hub, pollInterval: .seconds(60)), file: file,
                      laneWidth: { width })
    }

    func wake(_ name: String) -> WebAction { .lifecycle(.wake, name: name) }

    /// Until `cond` holds (or 5 s).
    func until(_ what: String, _ cond: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(5)
        while !cond(), Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        let held = cond()
        XCTAssertTrue(held, what)
    }

    func op(_ ops: WebOperations, _ id: String) -> WebOperation { ops.recent.first { $0.id == id }! }
    var sent: [String] { fake.performed.compactMap(\.name) }

    // MARK: the lane

    func testTwelveWakesAreAllAcceptedAndAtMostTheWidthRunAtOnce() async throws {
        let ops = make(width: 3)
        let client = try XCTUnwrap(hub.add(cookie: "c"))
        let started = try (0..<12).map { try ops.start(wake("w\($0)"), priority: false) }
        XCTAssertEqual(started.map(\.state), Array(repeating: "running", count: 12), "every one accepted, none refused")
        XCTAssertEqual(started.prefix(3).map(\.queued), [nil, nil, nil])
        XCTAssertEqual(started.dropFirst(3).map(\.queued), Array(repeating: true, count: 9))
        XCTAssertEqual(started.dropFirst(3).map(\.position), Array(1...9))
        XCTAssertEqual(started[3].text, "queued — next")
        XCTAssertEqual(started[5].text, "queued — 2 ahead")
        await until("three sent") { [self] in fake.performed.count == 3 }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(sent.sorted(), ["w0", "w1", "w2"], "nothing beyond the width reaches the host — the first three")
        fake.hold = false
        await until("all ended") { ops.recent.allSatisfy { $0.state == "done" } }
        // Every one once (the strict order is the width-1 tests': with three at once, three tasks race to the host).
        XCTAssertEqual(sent.sorted(), (0..<12).map { "w\($0)" }.sorted())
        XCTAssertTrue(ops.recent.allSatisfy { $0.queued == nil && $0.position == nil })
        client.finish(.clientGone)
        var frames = ""
        for await f in client.frames { frames += String(decoding: f.bytes, as: UTF8.self) }
        XCTAssertTrue(frames.contains("\"queued\":true") && frames.contains("queued — 8 ahead"), "each place is told to the pages")
    }

    func testATurnStartsTheOperationsOwnClock() async throws {
        let ops = make(width: 1)
        _ = try ops.start(wake("a"), priority: false)
        let b = try ops.start(wake("b"), priority: false)
        XCTAssertEqual(b.queued, true)
        try await Task.sleep(for: .milliseconds(150))
        fake.hold = false
        await until("b ran") { [self] in op(ops, b.id).state == "done" }
        XCTAssertGreaterThan(op(ops, b.id).startedAt.timeIntervalSince(b.startedAt), 0.1, "its time is the work's own, not the wait's")
    }

    func testTheWidthIsReadWhenAPlaceFrees() async throws {
        final class Width: @unchecked Sendable { var n = 1 }
        let w = Width()
        let ops = WebOperations(data: fake, hub: hub, monitor: WebMonitor(data: fake, hub: hub, pollInterval: .seconds(60)), laneWidth: { w.n })
        for i in 0..<4 { _ = try ops.start(wake("w\(i)"), priority: false) }
        await until("one sent") { [self] in fake.performed.count == 1 }
        w.n = 3
        _ = try ops.start(wake("w4"), priority: false)     // a start reads it too
        await until("three sent") { [self] in fake.performed.count == 3 }
        w.n = 99                                            // clamped to 8
        XCTAssertEqual(WebOperations.clampWidth(99), 8)
        XCTAssertEqual(WebOperations.clampWidth(0), 1)
        fake.hold = false
        await until("all ended") { ops.recent.allSatisfy { $0.state == "done" } }
    }

    // MARK: order

    func testAPersonsOwnActionGoesAheadOfTheBatch() async throws {
        let ops = make(width: 1)
        let batch = try (0..<4).map { try ops.start(wake("b\($0)"), priority: false) }
        let p = try ops.start(wake("p"))
        XCTAssertEqual(p.position, 1, "a single click waits behind no batch")
        XCTAssertEqual(op(ops, batch[1].id).position, 2)
        let q = try ops.start(.lifecycle(.start, name: "q"), firstLine: "a key typed in a terminal — waking")
        XCTAssertEqual(q.position, 2, "after the other person's own, first in first out")
        // A person's repeat of what the batch queued: that operation goes ahead (the same one); a repeat of a running one,
        // or a batch repeat, is still refused.
        let promoted = try ops.start(wake("b3"))
        XCTAssertEqual(promoted.id, batch[3].id)
        XCTAssertEqual(promoted.position, 3)
        XCTAssertThrowsError(try ops.start(wake("b0"))) { XCTAssertEqual($0 as? WebRejection, .alreadyRunning) }
        XCTAssertThrowsError(try ops.start(wake("b2"), priority: false)) { XCTAssertEqual($0 as? WebRejection, .alreadyRunning) }
        XCTAssertThrowsError(try ops.start(wake("p"))) { XCTAssertEqual($0 as? WebRejection, .alreadyRunning) }
        fake.hold = false
        await until("all ended") { ops.recent.allSatisfy { $0.state == "done" } }
        XCTAssertEqual(sent, ["b0", "p", "q", "b3", "b1", "b2"])
    }

    // MARK: lanes

    func testAPauseAndAResumeFromPauseNeverWait() async throws {
        let ops = make(width: 1)
        _ = try ops.start(wake("w0"))
        XCTAssertEqual(try ops.start(wake("w1")).queued, true)
        XCTAssertNil(try ops.start(.lifecycle(.pause, name: "x")).queued)
        XCTAssertNil(try ops.start(.lifecycle(.resume, name: "y"), phase: "paused").queued, "the terminal's keystroke resume")
        XCTAssertEqual(try ops.start(.lifecycle(.resume, name: "z")).queued, true, "a resume of a phase not known waits (it may be a wake)")
        XCTAssertEqual(try ops.start(.lifecycle(.resume, name: "h"), phase: "hibernated").queued, true)
        // The monitor's overview says demo is paused: its resume never waits.
        fake.phase = "paused"
        ops.reconcile(try await fake.overview())
        XCTAssertNil(try ops.start(.lifecycle(.resume, name: "demo")).queued)
        for verb: HostOp in [.start, .sleep, .hibernate, .shutdown] {
            XCTAssertEqual(WebOperations.lane(.lifecycle(verb, name: "s"), phase: "running"), .lifecycle, verb.rawValue)
        }
        XCTAssertEqual(WebOperations.lane(.lifecycle(.reset, name: "s"), phase: nil), .general)
        XCTAssertEqual(WebOperations.lane(.lifecycle(.rm, name: "s"), phase: nil), .general)
        XCTAssertEqual(WebOperations.lane(.toolsApply("s"), phase: nil), .general)
        await until("w0, x, y, demo sent") { [self] in Set(sent).isSuperset(of: ["w0", "x", "y", "demo"]) }
        XCTAssertFalse(sent.contains("w1") || sent.contains("z"))
        fake.hold = false
        await until("all ended") { ops.recent.allSatisfy { $0.state == "done" } }
    }

    func testOtherActionsKeepTheirOwnCapOfEight() async throws {
        let ops = make(width: 1)
        let tools = try (0..<9).map { try ops.start(.toolsApply("t\($0)")) }
        XCTAssertEqual(tools.prefix(8).compactMap(\.queued), [])
        XCTAssertEqual(tools[8].queued, true, "the ninth waits — it is not refused")
        XCTAssertNil(try ops.start(wake("w")).queued, "the lifecycle lane is its own")
        await until("nine sent") { [self] in fake.performed.count == 9 }
        fake.hold = false
        await until("all ended") { ops.recent.allSatisfy { $0.state == "done" } }
        XCTAssertEqual(fake.performed.count, 10)
    }

    // MARK: cancel, the bound, a restart

    func testCancelWithdrawsOnlyWhatIsQueued() async throws {
        let ops = make(width: 1)
        let a = try ops.start(wake("a"), priority: false)
        let b = try ops.start(wake("b"), priority: false)
        let c = try ops.start(wake("c"), priority: false)
        let r = ops.cancel([b.id, a.id, "nope"])
        XCTAssertEqual(r, WebOperationsCancelled(cancelled: [b.id], notQueued: [a.id, "nope"]))
        XCTAssertEqual(op(ops, b.id).state, "interrupted", "an ended state, never a failure")
        XCTAssertEqual(op(ops, b.id).text, "cancelled before its turn — nothing was done")
        XCTAssertNil(op(ops, b.id).queued)
        XCTAssertEqual(op(ops, c.id).position, 1, "the others move up")
        XCTAssertEqual(op(ops, a.id).state, "running", "a running one is answered back unchanged")
        let again = try ops.start(wake("b"), priority: false)            // its place in flight was freed
        XCTAssertEqual(again.position, 2)
        fake.hold = false
        await until("all ended") { ops.recent.filter { $0.state == "running" }.isEmpty }
        XCTAssertEqual(sent, ["a", "c", "b"], "the cancelled one never reached the host")
        XCTAssertEqual(ops.cancel([c.id]).notQueued, [c.id])
    }

    func testTheQueueIsBoundedAt256AndKeepsEveryWaitingOne() async throws {
        let ops = make(width: 1)
        for i in 0...WebOperations.maxQueued { _ = try ops.start(wake("q\(i)"), priority: false) }
        XCTAssertThrowsError(try ops.start(wake("over"), priority: false)) { XCTAssertEqual($0 as? WebRejection, .tooManyOperations) }
        XCTAssertNil(try ops.start(.lifecycle(.pause, name: "p")).queued, "a pause still goes")
        XCTAssertEqual(ops.recent.filter { $0.queued == true }.count, WebOperations.maxQueued, "beyond the ring's 50: none forgotten")
        XCTAssertEqual(ops.recent.last { $0.queued == true }?.position, WebOperations.maxQueued)
        fake.hold = false
        await until("all ended") { ops.recent.filter { $0.state == "running" }.isEmpty }
        XCTAssertLessThanOrEqual(ops.recent.count, ops.keep, "ended ones are trimmed to the ring")
    }

    func testAQueuedOperationAcrossARestartWasNotStarted() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("doz-queue-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("ui.operations.json")
        let first = make(width: 1, file: file)
        let a = try first.start(wake("demo"), priority: false)
        let b = try first.start(.lifecycle(.start, name: "demo2"), priority: false)
        XCTAssertEqual(b.queued, true)
        // doz ui restarts: the ring is read back.
        let second = make(width: 1, file: file)
        let ra = op(second, a.id), rb = op(second, b.id)
        XCTAssertEqual(ra.state, "running")
        XCTAssertEqual(ra.interrupted, true, "the one that ran is resolved from the overview")
        XCTAssertEqual(rb.state, "interrupted")
        XCTAssertEqual(rb.text, "doz ui restarted before its turn — it was not started")
        XCTAssertNil(rb.queued)
        XCTAssertNil(rb.position)
        fake.phase = "running"
        second.reconcile(try await fake.overview())
        XCTAssertEqual(op(second, a.id).state, "done")
        XCTAssertEqual(op(second, b.id).text, "doz ui restarted before its turn — it was not started", "never resolved from the overview: it never ran")
    }
}
