import Darwin
import Foundation
import XCTest
@testable import DozableKit

/// 648: the GRID — deckhold's binary answer decoded (every length and bound checked), the JSON contract the page
/// paints from, inert text, the frame codec, the capability (`grid=1`), `SessionConnection.requestGrid` (in order, a
/// timeout, never to a holder that did not announce it) and the saved screen's grid file. No VM; deckhold's own side
/// is `make deckhold-grid-check`.
final class ScreenGridTests: XCTestCase {
    // MARK: a binary GRID answer, as deckhold writes it (WIRE in deckhold.c)

    struct WireRun {
        var col: UInt16, cells: UInt16, flags: UInt8 = 0
        var fg: (UInt8, UInt8, UInt8)? = nil, bg: (UInt8, UInt8, UInt8)? = nil
        var text: [UInt8]
    }

    static func be16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xFF)] }
    static func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }

    static func wire(gen: UInt32 = 7, changed: UInt8 = 1, cols: UInt16 = 10, rows: UInt16 = 2, cursor: (UInt16, UInt16)? = (3, 1),
                     fg: (UInt8, UInt8, UInt8) = (0xEE, 0xEE, 0xEE), bg: (UInt8, UInt8, UInt8) = (0x11, 0x22, 0x33),
                     lines: [[WireRun]]? = nil) -> Data {
        var b: [UInt8] = [1] + be32(gen) + [changed]
        guard changed == 1 else { return Data(b) }
        b += be16(cols) + be16(rows) + [cursor == nil ? 0 : 1] + be16(cursor?.0 ?? 0) + be16(cursor?.1 ?? 0)
        b += [fg.0, fg.1, fg.2, bg.0, bg.1, bg.2]
        let ls = lines ?? [[WireRun(col: 0, cells: 5, flags: 1, fg: (0xFF, 0, 0), text: Array("hello".utf8)),
                            WireRun(col: 6, cells: 2, bg: (0, 0x80, 0), text: Array("ok".utf8))],
                           []]
        for runs in ls {
            b += be16(UInt16(runs.count))
            for r in runs {
                b += be16(r.col) + be16(r.cells) + [r.flags]
                b += [r.fg == nil ? 0 : 1, r.fg?.0 ?? 0, r.fg?.1 ?? 0, r.fg?.2 ?? 0]
                b += [r.bg == nil ? 0 : 1, r.bg?.0 ?? 0, r.bg?.1 ?? 0, r.bg?.2 ?? 0]
                b += be16(UInt16(r.text.count)) + r.text
            }
        }
        return Data(b)
    }

    // MARK: the codec

    func test_aGridDecodesFieldByField() throws {
        guard case .grid(let g) = try ScreenGrid.decode(Self.wire()) else { return XCTFail("a grid") }
        XCTAssertEqual(g.cols, 10)
        XCTAssertEqual(g.rows, 2)
        XCTAssertEqual(g.gen, 7)
        XCTAssertEqual(g.fg, "#eeeeee")
        XCTAssertEqual(g.bg, "#112233")
        XCTAssertEqual(g.cursor, ScreenGrid.Cursor(x: 3, y: 1))
        XCTAssertEqual(g.lines.count, 2, "exactly `rows` lines")
        XCTAssertEqual(g.lines[0], [ScreenGrid.Run(col: 0, text: "hello", fg: "#ff0000", bg: nil, flags: 1, cells: 5),
                                    ScreenGrid.Run(col: 6, text: "ok", fg: nil, bg: "#008000", flags: 0, cells: 2)])
        XCTAssertEqual(g.lines[1], [], "a blank row is []")
    }

    func test_unchangedAndNone() throws {
        XCTAssertEqual(try ScreenGrid.decode(Self.wire(gen: 9, changed: 0)), .unchanged(gen: 9))
        XCTAssertEqual(try ScreenGrid.decode(Self.wire(gen: 9, changed: 2)), .none(gen: 9))
        XCTAssertThrowsError(try ScreenGrid.decode(Self.wire(gen: 9, changed: 0) + Data([0])), "nothing may follow unchanged")
    }

    func test_aHiddenCursorOrOneOutsideTheScreenIsNone() throws {
        guard case .grid(let a) = try ScreenGrid.decode(Self.wire(cursor: nil)) else { return XCTFail() }
        XCTAssertNil(a.cursor)
        guard case .grid(let b) = try ScreenGrid.decode(Self.wire(cursor: (10, 0))) else { return XCTFail() }
        XCTAssertNil(b.cursor, "x = cols is outside")
    }

    func test_everyTruncationIsRefused() {
        let w = Self.wire()
        for cut in 0..<w.count {
            XCTAssertThrowsError(try ScreenGrid.decode(w.prefix(cut)), "cut at \(cut)")
        }
        XCTAssertThrowsError(try ScreenGrid.decode(w + Data([0])), "a trailing byte")
    }

    func test_garbageIsRefused() {
        var v2 = [UInt8](Self.wire()); v2[0] = 2
        XCTAssertThrowsError(try ScreenGrid.decode(Data(v2))) { XCTAssertEqual($0 as? ScreenGrid.DecodeError, .version(2)) }
        var c3 = [UInt8](Self.wire()); c3[5] = 3
        XCTAssertThrowsError(try ScreenGrid.decode(Data(c3))) { XCTAssertEqual($0 as? ScreenGrid.DecodeError, .changed(3)) }
        XCTAssertThrowsError(try ScreenGrid.decode(Self.wire(cols: 0, lines: [[], []])), "no columns")
        XCTAssertThrowsError(try ScreenGrid.decode(Self.wire(cols: 1001, lines: [[], []])), "past 1000 columns")
        XCTAssertThrowsError(try ScreenGrid.decode(Self.wire(rows: 501, lines: Array(repeating: [], count: 501))), "past 500 rows")
        XCTAssertThrowsError(try ScreenGrid.decode(Self.wire(lines: [[WireRun(col: 8, cells: 3, text: [0x61])], []])), "a run out of its row")
        XCTAssertThrowsError(try ScreenGrid.decode(Self.wire(lines: [[WireRun(col: 0, cells: 0, text: [])], []])), "a run of no cells")
        XCTAssertThrowsError(try ScreenGrid.decode(Self.wire(lines: [[WireRun(col: 2, cells: 3, text: [0x61]),
                                                                      WireRun(col: 3, cells: 1, text: [0x62])], []])), "overlapping runs")
        XCTAssertThrowsError(try ScreenGrid.decode(Self.wire(lines: [[]])), "fewer rows than said")
        XCTAssertThrowsError(try ScreenGrid.decode(Data()), "nothing")
        // Random bytes never crash it.
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<2000 {
            let n = Int.random(in: 0..<64, using: &rng)
            _ = try? ScreenGrid.decode(Data((0..<n).map { _ in UInt8.random(in: 0...255, using: &rng) }))
        }
    }

    func test_theTextIsInert() throws {
        let evil: [UInt8] = Array("a\u{1B}[31mb\u{07}c\u{7F}d\u{85}e\u{202E}f\u{2066}g\u{200F}h\u{061C}i".utf8) + [0xFF, 0x41]
        guard case .grid(let g) = try ScreenGrid.decode(Self.wire(lines: [[WireRun(col: 0, cells: 10, text: evil)], []])) else { return XCTFail() }
        let t = g.lines[0][0].text
        XCTAssertEqual(t, "a\u{FFFD}[31mb\u{FFFD}c\u{FFFD}d\u{FFFD}e\u{FFFD}f\u{FFFD}g\u{FFFD}h\u{FFFD}i\u{FFFD}A",
                       "every C0/C1/DEL and bidi control — and a byte that is not UTF-8 — is U+FFFD")
        XCTAssertEqual(ScreenGrid.inert("café ✓ 漢 😀 e\u{301}"), "café ✓ 漢 😀 e\u{301}", "ordinary text is kept")
        XCTAssertFalse(t.unicodeScalars.contains { $0.value < 0x20 || (0x7F...0x9F).contains($0.value) })
    }

    func test_aRowsTextStopsAt4KiB() throws {
        let runs = (0..<10).map { i in WireRun(col: UInt16(i * 100), cells: 100, fg: (UInt8(i), 0, 0), text: Array(repeating: 0x78, count: 500)) }
        guard case .grid(let g) = try ScreenGrid.decode(Self.wire(cols: 1000, rows: 1, cursor: nil, lines: [runs])) else { return XCTFail() }
        XCTAssertEqual(g.lines[0].count, 8, "8 × 500 bytes fit in 4096; the runs past it are left out")
        XCTAssertLessThanOrEqual(g.lines[0].reduce(0) { $0 + $1.text.utf8.count }, ScreenGrid.maximumRowText)
    }

    // MARK: the JSON contract

    func test_theJSONIsTheContract() throws {
        guard case .grid(let g) = try ScreenGrid.decode(Self.wire(cursor: nil)) else { return XCTFail() }
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let json = String(decoding: try enc.encode(g), as: UTF8.self)
        XCTAssertEqual(json, ##"{"bg":"#112233","cols":10,"cursor":null,"fg":"#eeeeee","gen":7,"lines":[[[0,"hello","#ff0000",null,1,5],[6,"ok",null,"#008000",0,2]],[]],"rows":2}"##)
        XCTAssertEqual(try JSONDecoder().decode(ScreenGrid.self, from: Data(json.utf8)), g, "round trip")
        XCTAssertThrowsError(try JSONDecoder().decode(ScreenGrid.Run.self, from: Data(#"[0,"a",null,null,0,1,9]"#.utf8)), "a run has six elements")
    }

    func test_validatedRefusesWhatTheContractDoesNot() throws {
        let ok = ScreenGrid(cols: 4, rows: 1, gen: 1, fg: "#ffffff", bg: "#000000", cursor: .init(x: 9, y: 0),
                            lines: [[.init(col: 0, text: "a\u{202E}b", fg: "#00ff00", flags: 255, cells: 2)]])
        let v = try XCTUnwrap(ok.validated())
        XCTAssertNil(v.cursor, "a cursor outside is dropped")
        XCTAssertEqual(v.lines[0][0].text, "a\u{FFFD}b", "inert again")
        XCTAssertEqual(v.lines[0][0].flags, 31)
        var bad = ok; bad.fg = "red"
        XCTAssertNil(bad.validated(), "a colour is #rrggbb")
        bad = ok; bad.lines = []
        XCTAssertNil(bad.validated(), "exactly rows lines")
        bad = ok; bad.lines = [[.init(col: 3, text: "x", cells: 2)]]
        XCTAssertNil(bad.validated(), "a run out of its row")
        bad = ok; bad.lines = [[.init(col: 0, text: "x", fg: "#GGGGGG", cells: 1)]]
        XCTAssertNil(bad.validated())
    }

    // MARK: the frame, the capability, the ls line

    func test_theFrames() throws {
        XCTAssertEqual(DeckholdFrame.gridRequest(0x01020304).encoded, Data([0x47, 0, 0, 0, 4, 1, 2, 3, 4]))
        var d = DeckholdFrameDecoder()
        let w = Self.wire()
        let frames = try d.feed(DeckholdFrame.grid(w).encoded)
        XCTAssertEqual(frames, [.grid(w)])
        XCTAssertEqual(DeckholdFrame.captureWithGridRequest,
                       DeckholdFrame.hello(TermSize(cols: 0, rows: 0)).encoded + Data([0x47, 0, 0, 0, 4, 0, 0, 0, 0]) + Data([0x50, 0, 0, 0, 0]),
                       "the capture of a holder that knows GRID: HELLO 0×0, GRID 0, DUMP")
        XCTAssertTrue(DeckholdFrame.announcesGrid("grid=1"))
        XCTAssertTrue(DeckholdFrame.announcesGrid("grid=1\tstatus=state=working\tstatus_age=0"))
        XCTAssertFalse(DeckholdFrame.announcesGrid(""))
        XCTAssertFalse(DeckholdFrame.announcesGrid("status=state=working\tstatus_age=0"))
        XCTAssertNil(ProgramStatus.parse(frame: "grid=1"), "an older host reads the announcement as no status")
        XCTAssertEqual(ProgramStatus.parse(frame: "grid=1\tstatus=state=done\tstatus_age=3")?.state, .done, "…and the status beside it")
    }

    func test_theLsLineSaysGrid() {
        let list = SessionInfo.parseList("main\tpid=9\tsize=80x24\tclients=0\tscreen=primary\thistory=0\tbytes=5\tgrid=1\tstatus=state=done\tstatus_age=1\tbash -l\n"
            + "old\tpid=8\tsize=80x24\tclients=0\tscreen=primary\thistory=0\tbytes=5\tbash -l\n"
            + "odd\tpid=7\tsize=80x24\tclients=0\tscreen=primary\thistory=0\tbytes=5\tgrid=1\n")
        XCTAssertEqual(list.map(\.name), ["main", "odd", "old"])
        XCTAssertTrue(list[0].grid)
        XCTAssertEqual(list[0].command, "bash -l")
        XCTAssertEqual(list[0].status?.state, .done)
        XCTAssertFalse(list[2].grid, "an older holder says nothing")
        XCTAssertFalse(list[1].grid, "the LAST field is the command, whatever it says")
        XCTAssertEqual(list[1].command, "grid=1")
    }

    // MARK: SessionConnection.requestGrid

    private func gridFrames(_ c: SessionConnection, _ n: Int) async -> [Data] {
        var out: [Data] = []
        for await d in c.input {
            if d.first == UInt8(ascii: "G") { out.append(d) }
            if out.count == n { break }
        }
        return out
    }

    func test_aHolderThatNeverAnnouncedItIsNeverAsked() async {
        let c = SessionConnection(statusOf: "agent")
        c.receive(DeckholdFrame.status("status=state=working\tstatus_age=0").encoded)    // an older holder's answer
        XCTAssertTrue(c.sawStatus)
        XCTAssertFalse(c.gridCapable)
        let a = await c.requestGrid(gen: 0)
        XCTAssertNil(a)
        c.close()
        var sent: [Data] = []
        for await d in c.input { sent.append(d) }
        XCTAssertEqual(sent, [DeckholdFrame.watch.encoded], "nothing but WATCH was sent: no GRID to an older holder")
        let v = SessionConnection(session: "agent", size: .standard)
        v.receive(DeckholdFrame.status("grid=1").encoded)
        XCTAssertFalse(v.gridCapable, "only a status watcher's WATCH answer announces it")
    }

    func test_requestsAreAnsweredInOrder() async throws {
        let c = SessionConnection(statusOf: "agent")
        c.receive(DeckholdFrame.status("grid=1").encoded)
        XCTAssertTrue(c.gridCapable)
        async let first = c.requestGrid(gen: 0, timeout: .seconds(5))
        async let second = c.requestGrid(gen: 7, timeout: .seconds(5))
        let sent = await gridFrames(c, 2)
        XCTAssertEqual(Set(sent), [DeckholdFrame.gridRequest(0).encoded, DeckholdFrame.gridRequest(7).encoded])
        // Two answers in ONE read (coalesced), plus a status frame between: the first answer goes to the first sent.
        let firstSentIsZero = sent[0] == DeckholdFrame.gridRequest(0).encoded
        let grid = DeckholdFrame.grid(Self.wire(gen: 7)).encoded, same = DeckholdFrame.grid(Self.wire(gen: 7, changed: 0)).encoded
        c.receive((firstSentIsZero ? grid : same) + DeckholdFrame.status("status=state=done\tstatus_age=0").encoded + (firstSentIsZero ? same : grid))
        let (a, b) = await (first, second)
        guard case .grid(let g)? = a else { return XCTFail("the gen-0 request gets the grid: \(String(describing: a))") }
        XCTAssertEqual(g.gen, 7)
        XCTAssertEqual(b, .unchanged(gen: 7))
        c.close()
    }

    func test_aTimeoutTakesItsLateAnswerWithIt() async {
        let c = SessionConnection(statusOf: "agent")
        c.receive(DeckholdFrame.status("grid=1").encoded)
        let late = await c.requestGrid(gen: 0, timeout: .milliseconds(50))
        XCTAssertNil(late, "no answer within the time: nil")
        async let next = c.requestGrid(gen: 3, timeout: .seconds(5))
        _ = await gridFrames(c, 2)
        // The late answer to the first, then the answer to the second.
        c.receive(DeckholdFrame.grid(Self.wire(gen: 1)).encoded + DeckholdFrame.grid(Self.wire(gen: 3, changed: 0)).encoded)
        let n = await next
        XCTAssertEqual(n, .unchanged(gen: 3), "the late answer was not taken for the next one's")
        c.close()
    }

    func test_closingAnswersEveryWaiterAndLimitsHold() async {
        let c = SessionConnection(statusOf: "agent")
        c.receive(DeckholdFrame.status("grid=1").encoded)
        async let a = c.requestGrid(gen: 0, timeout: .seconds(30))
        _ = await gridFrames(c, 1)
        c.close()
        let got = await a
        XCTAssertNil(got, "a closed connection answers nil at once")
        let after = await c.requestGrid(gen: 0)
        XCTAssertNil(after, "and asks nothing more")
        // At most `maximumPendingGrids` outstanding.
        let d = SessionConnection(statusOf: "agent")
        d.receive(DeckholdFrame.status("grid=1").encoded)
        await withTaskGroup(of: ScreenGrid.Answer?.self) { group in
            for _ in 0..<(SessionConnection.maximumPendingGrids + 2) { group.addTask { await d.requestGrid(gen: 0, timeout: .milliseconds(300)) } }
            var n = 0
            for await r in group where r == nil { n += 1 }
            XCTAssertEqual(n, SessionConnection.maximumPendingGrids + 2, "all nil (none answered)")
        }
        d.close()
        var frames = 0
        for await x in d.input where x.first == UInt8(ascii: "G") { frames += 1 }
        XCTAssertLessThanOrEqual(frames, SessionConnection.maximumPendingGrids + 2)
        XCTAssertGreaterThanOrEqual(frames, 1)
    }

    func test_aGarbledAnswerIsNil() async {
        let c = SessionConnection(statusOf: "agent")
        c.receive(DeckholdFrame.status("grid=1").encoded)
        async let a = c.requestGrid(gen: 0, timeout: .seconds(5))
        _ = await gridFrames(c, 1)
        c.receive(DeckholdFrame.grid(Data([1, 0, 0])).encoded)
        let got = await a
        XCTAssertNil(got)
        XCTAssertFalse(c.isClosed, "the watcher goes on")
        c.close()
    }

    // MARK: the saved screen's grid

    func test_aSavedScreenKeepsItsGridAndDropsAStaleOne() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("doz-grid-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: dir) }
        let spec = SandboxSpec(name: "lab", storeRoot: dir)
        let layout = StoreLayout(spec: spec)
        try FileManager.default.createDirectory(at: layout.sandboxDirectory, withIntermediateDirectories: true)
        guard case .grid(let g) = try ScreenGrid.decode(Self.wire()) else { return XCTFail() }
        let info = SavedScreenInfo(session: "main", savedAt: Date(), reason: "sleep", cols: 10, rows: 2, command: "sh")
        try SavedScreens.write(layout, info: info, vt: Data("v".utf8), text: "hello ok", grid: g)
        let file = layout.screensDirectory.appendingPathComponent("main.grid.json")
        var st = stat()
        XCTAssertEqual(stat(file.path, &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o600)
        let s = try XCTUnwrap(SavedScreens.read(layout, session: "main"))
        XCTAssertEqual(s.grid, g)
        XCTAssertEqual(s.info.grid, true)
        XCTAssertEqual(SavedScreens.list(layout).map(\.session), ["main"], "the grid file is not a session")
        // A capture without a grid (an older holder) leaves no stale grid beside the new text.
        try SavedScreens.write(layout, info: info, vt: Data("v2".utf8), text: "newer")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertNil(try XCTUnwrap(SavedScreens.read(layout, session: "main")).grid)
        // A grid file someone edited is validated as it is read.
        try SavedScreens.write(layout, info: info, vt: Data("v".utf8), text: "t", grid: g)
        try Data(##"{"cols":10,"rows":2,"gen":1,"fg":"#ffffff","bg":"#000000","cursor":null,"lines":[[[0,"a\u202eb",null,null,0,3]],[]]}"##.utf8).write(to: file)
        XCTAssertEqual(SavedScreens.read(layout, session: "main")?.grid?.lines[0][0].text, "a\u{FFFD}b")
        try Data(##"{"cols":10,"rows":3,"gen":1,"fg":"#ffffff","bg":"#000000","cursor":null,"lines":[[]]}"##.utf8).write(to: file)
        XCTAssertNil(SavedScreens.read(layout, session: "main")?.grid, "not a grid: none")
        // Removed with the others.
        SavedScreens.remove(layout)
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.screensDirectory.path))
    }
}
