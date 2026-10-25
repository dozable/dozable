import Foundation
@testable import DozableKit
import XCTest
@testable import DozableHost

/// 648: the host op `session-grids` in-process, no VM — a status watcher made by hand whose holder is played here.
/// Checked: a grid, unchanged, every reason (not-found, invalid, not-running, no-watcher, busy, timeout, too-large,
/// no-host), the order of the answers, the cap of 64, never a GRID frame to a holder that did not announce it, and
/// never a wake: an asleep/off sandbox is answered not-running and stays as it was.
final class SessionGridsTests: XCTestCase {
    private var root: URL!
    let keychain = FakeKeychain()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("doz-grids-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    var store: DozableStore { DozableStore(root: root) }

    func core(readOnly: Bool = false) async -> HostCore {
        let s = CredentialServices(keychain: keychain, verifier: FakeVerifier(answer: .verified), claudeBinary: { nil }, home: root,
                                   keepaliveRunner: FakeRunner(), isClaudeRunning: { false }, watchInterval: .seconds(3600))
        let c = HostCore(store: store, readOnly: readOnly, version: "test", services: s)
        await c.load()
        return c
    }

    func create(_ c: HostCore, _ name: String) async {
        var r = HostRequest(.create, name: name)
        var o = CreateOptions(image: "lab")
        o.isolated = true
        r.create = o
        let m = await c.handle(r)
        XCTAssertNil(m.error, m.error?.message ?? "")
    }

    func ask(_ c: HostCore, _ items: [SessionGridRequest]) async throws -> [SessionGridAnswer] {
        var r = HostRequest(.sessionGrids)
        r.grids = items
        let m = await c.handle(r)
        if let e = m.error { throw e }
        return try (m.result ?? .null).decode([SessionGridAnswer].self)
    }

    /// deckhold's GRID answer (WIRE in deckhold.c): one row with "hi" in red on 4 columns, or unchanged.
    static func answer(gen: UInt32, changed: UInt8 = 1) -> Data {
        var b: [UInt8] = [1, UInt8(gen >> 24), UInt8((gen >> 16) & 0xFF), UInt8((gen >> 8) & 0xFF), UInt8(gen & 0xFF), changed]
        guard changed == 1 else { return Data(b) }
        b += [0, 4, 0, 1, 1, 0, 2, 0, 0, 0xFF, 0xFF, 0xFF, 0, 0, 0]          // 4×1, cursor (2,0), fg white, bg black
        b += [0, 1, 0, 0, 0, 2, 1, 1, 0xCD, 0x00, 0x00, 0, 0, 0, 0, 0, 2] + Array("hi".utf8)
        return Data(b)
    }

    /// A status watcher whose holder is played here: it announces GRID (or not) and answers each GRID frame with
    /// `reply(gen)` (nil: never answers). The task's value is how many GRID frames it was sent.
    func watcher(announces: Bool, reply: (@Sendable (UInt32) -> Data?)?) -> (SessionConnection, Task<Int, Never>) {
        let c = SessionConnection(statusOf: "main")
        c.receive(DeckholdFrame.status(announces ? "grid=1" : "").encoded)
        let t = Task { () -> Int in
            var asked = 0
            for await d in c.input where d.first == UInt8(ascii: "G") {
                asked += 1
                let b = [UInt8](d)
                let gen = UInt32(b[5]) << 24 | UInt32(b[6]) << 16 | UInt32(b[7]) << 8 | UInt32(b[8])
                if let a = reply?(gen) { c.receive(DeckholdFrame.grid(a).encoded) }
            }
            return asked
        }
        return (c, t)
    }

    func testWithNoHostEveryPictureIsUnavailable() async throws {
        let ro = await core(readOnly: true)
        let a = try await ask(ro, [SessionGridRequest(sandbox: "box", session: "main"), SessionGridRequest(sandbox: "x", session: "y", gen: 3)])
        XCTAssertEqual(a.map(\.state), [.unavailable, .unavailable])
        XCTAssertEqual(a.map(\.reason), [.noHost, .noHost])
        XCTAssertEqual(a.map(\.session), ["main", "y"], "in the order asked")
        XCTAssertTrue(HostOp.sessionGrids.isReadOnly, "read-only: answered in-process when no host runs — never a host started")
    }

    func testAtMost64() async {
        let c = await core()
        var r = HostRequest(.sessionGrids)
        r.grids = Array(repeating: SessionGridRequest(sandbox: "box", session: "main"), count: 65)
        let m = await c.handle(r)
        XCTAssertEqual(m.error?.code, .invalid)
        r.grids = []
        let empty = await c.handle(r)
        XCTAssertNil(empty.error)
    }

    func testAGridUnchangedAndEveryReasonInOrder() async throws {
        let c = await core()
        await create(c, "box")
        await create(c, "old")
        await create(c, "busy")
        await create(c, "quiet")
        let (fresh, freshAsked) = watcher(announces: true) { gen in gen == 9 ? Self.answer(gen: 9, changed: 0) : Self.answer(gen: 9) }
        let (older, olderAsked) = watcher(announces: false) { _ in Self.answer(gen: 1) }
        let (big, _) = watcher(announces: true) { _ in Self.answer(gen: 4, changed: 2) }
        let (silent, _) = watcher(announces: true, reply: nil)
        await c.setGridSeamsForTests(runs: { $0 != "quiet" },
                                     watchers: ["box": ["main": fresh, "huge": big, "mute": silent], "old": ["main": older]],
                                     inFlight: ["busy": HostCore.gridRequestsPerSandbox])
        let items = [
            SessionGridRequest(sandbox: "box", session: "main"),            // the grid
            SessionGridRequest(sandbox: "box", session: "main", gen: 9),    // the same gen: unchanged
            SessionGridRequest(sandbox: "nope", session: "main"),           // no such sandbox
            SessionGridRequest(sandbox: "box", session: "../x"),            // not a session name
            SessionGridRequest(sandbox: "quiet", session: "main"),          // not running
            SessionGridRequest(sandbox: "old", session: "main"),            // a holder that never announced GRID
            SessionGridRequest(sandbox: "box", session: "other"),           // no watcher
            SessionGridRequest(sandbox: "busy", session: "main"),           // too many requests under way
            SessionGridRequest(sandbox: "box", session: "huge"),            // larger than a grid may be
            SessionGridRequest(sandbox: "box", session: "mute"),            // no answer within a second
        ]
        let a = try await ask(c, items)
        XCTAssertEqual(a.map(\.session), items.map(\.session), "in the order asked")
        XCTAssertEqual(a[0].state, .grid)
        XCTAssertEqual(a[0].gen, 9)
        XCTAssertEqual(a[0].grid?.lines.first?.first, ScreenGrid.Run(col: 0, text: "hi", fg: "#cd0000", bg: nil, flags: 1, cells: 2))
        XCTAssertEqual(a[0].grid?.cursor, ScreenGrid.Cursor(x: 2, y: 0))
        XCTAssertEqual(a[1].state, .unchanged)
        XCTAssertNil(a[1].grid)
        XCTAssertEqual(a.dropFirst(2).map(\.reason), [.notFound, .invalid, .notRunning, .noWatcher, .noWatcher, .busy, .tooLarge, .timeout])
        XCTAssertTrue(a.dropFirst(2).allSatisfy { $0.state == .unavailable && $0.grid == nil })
        fresh.close(); older.close()
        let sentToOld = await olderAsked.value
        XCTAssertEqual(sentToOld, 0, "no GRID frame to a holder that did not announce it — it would drop the status watcher")
        let sentToFresh = await freshAsked.value
        XCTAssertEqual(sentToFresh, 2)
        big.close(); silent.close()
        let busyAfter = try await ask(c, [SessionGridRequest(sandbox: "box", session: "main")])
        XCTAssertEqual(busyAfter.first?.reason, .noWatcher, "a closed watcher is no watcher")
        let flight = await c.gridsInFlight
        XCTAssertEqual(flight["box"] ?? 0, 0, "every request let go of its count")
    }

    func testAnOffSandboxIsNeverWoken() async throws {
        let c = await core()
        await create(c, "box")
        let a = try await ask(c, [SessionGridRequest(sandbox: "box", session: "main")])
        XCTAssertEqual(a.first?.reason, .notRunning)
        var ls = HostRequest(.ls)
        ls.withSessions = false
        let rows = try (await c.handle(ls).result ?? .null).decode([SandboxInfo].self)
        XCTAssertEqual(rows.first { $0.name == "box" }?.phase, "off", "looking never starts it")
    }

    func testTheAnswersAreFieldsOnly() throws {
        let a = SessionGridAnswer(sandbox: "box", session: "main", state: .unavailable, reason: .noWatcher)
        let json = String(decoding: try JSONEncoder().encode(a), as: UTF8.self)
        XCTAssertTrue(json.contains(#""reason":"no-watcher""#), json)
        XCTAssertEqual(Set(SessionGridAnswer.Reason.allCases.map(\.rawValue)),
                       ["not-found", "not-running", "no-watcher", "busy", "timeout", "too-large", "no-host", "invalid"])
        var r = HostRequest(.sessionGrids)
        r.grids = [SessionGridRequest(sandbox: "box", session: "main", gen: 7)]
        let back = try JSONDecoder().decode(HostRequest.self, from: JSONEncoder().encode(r))
        XCTAssertEqual(back.grids, r.grids)
        XCTAssertEqual(HostOp(rawValue: "session-grids"), .sessionGrids)
    }
}
