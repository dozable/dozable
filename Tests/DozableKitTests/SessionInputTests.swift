import Foundation
import XCTest
@testable import DozableKit

/// 678 B5: `doz sessions send` — keys as bytes, the frames for deckhold, its receipt (cut at every offset); and the live
/// screen's parse.
final class SessionInputTests: XCTestCase {
    func testKeysAndOrder() throws {
        XCTAssertEqual(SessionInput.key("enter"), [0x0D])
        XCTAssertEqual(SessionInput.key("ESC"), [0x1B])
        XCTAssertEqual(SessionInput.key("up"), [0x1B, 0x5B, 0x41])
        XCTAssertEqual(SessionInput.key("pgdn"), Array("\u{1B}[6~".utf8))
        XCTAssertEqual(SessionInput.key("f1"), Array("\u{1B}OP".utf8))
        XCTAssertEqual(SessionInput.key("f12"), Array("\u{1B}[24~".utf8))
        XCTAssertEqual(SessionInput.key("ctrl-c"), [0x03])
        XCTAssertEqual(SessionInput.key("ctrl-a"), [0x01])
        XCTAssertNil(SessionInput.key("ctrl-1"))
        XCTAssertNil(SessionInput.key("hyper"))
        // text, then the keys as given, then Enter
        XCTAssertEqual(try SessionInput.bytes(text: "hi", keys: ["tab", "left"], enter: true, paste: false),
                       Data("hi".utf8) + Data([0x09, 0x1B, 0x5B, 0x44, 0x0D]))
        XCTAssertEqual(try SessionInput.bytes(text: "a\nb", keys: [], enter: false, paste: true), Data("\u{1B}[200~a\nb\u{1B}[201~".utf8))
        XCTAssertThrowsError(try SessionInput.bytes(text: nil, keys: [], enter: false, paste: false), "nothing")
        XCTAssertThrowsError(try SessionInput.bytes(text: nil, keys: ["nope"], enter: false, paste: false))
        XCTAssertThrowsError(try SessionInput.bytes(text: String(repeating: "x", count: 65_537), keys: [], enter: false, paste: false))
        XCTAssertNoThrow(try SessionInput.bytes(text: String(repeating: "x", count: 65_536), keys: [], enter: false, paste: false))
    }

    func testTheFrames() {
        let f = SessionInput.frames(Data("ab".utf8))
        XCTAssertEqual(Array(f), [0x44, 0, 0, 0, 2, 0x61, 0x62, 0x51, 0, 0, 0, 0], "DATA then QUERY")
        let big = SessionInput.frames(Data(repeating: 0x41, count: 40_000))
        // 16384 + 16384 + 7232 in three DATA frames, then QUERY
        XCTAssertEqual(big.count, 3 * 5 + 40_000 + 5)
        XCTAssertEqual(big[big.count - 5], 0x51)
        XCTAssertEqual(Array(big[1..<5]), [0, 0, 0x40, 0])
    }

    func testTheReceiptAtEveryCut() {
        func frame(_ t: Character, _ p: [UInt8]) -> Data {
            let n = UInt32(p.count)
            return Data([t.asciiValue!, UInt8(n >> 24), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)] + p)
        }
        let info = frame("I", Array("name=s pid=7 ended=0 cmd".utf8))
        for cut in 0..<info.count { XCTAssertNil(SessionInput.receipt(info.prefix(cut)), "incomplete at \(cut)") }
        XCTAssertEqual(SessionInput.receipt(info), .delivered(info: "name=s pid=7 ended=0 cmd"))
        let none = frame("N", [])
        for cut in 0..<none.count { XCTAssertNil(SessionInput.receipt(none.prefix(cut))) }
        XCTAssertEqual(SessionInput.receipt(none), .noSession)
        let exit = frame("X", [0, 0, 0, 3])
        for cut in 0..<exit.count { XCTAssertNil(SessionInput.receipt(exit.prefix(cut))) }
        XCTAssertEqual(SessionInput.receipt(exit), .ended(3))
        // A frame before it is skipped.
        XCTAssertEqual(SessionInput.receipt(frame("T", Array("status=x".utf8)) + info), .delivered(info: "name=s pid=7 ended=0 cmd"))
    }

    func testTheLiveScreen() {
        let s = LiveScreen.parse("$ make test\ngot:hi   \n\u{1B}[31mred\u{1B}[0m\ncursor=4,2 size=80x24 screen=primary\n")
        XCTAssertEqual(s?.text, "$ make test\ngot:hi\nred")
        XCTAssertEqual(s?.cursorX, 4)
        XCTAssertEqual(s?.cursorY, 2)
        XCTAssertEqual(s?.cols, 80)
        XCTAssertEqual(s?.rows, 24)
        XCTAssertEqual(s?.screen, "primary")
        XCTAssertEqual(LiveScreen.parse("x\ncursor=0,0 size=10x5 screen=alt")?.screen, "alt")
        XCTAssertNil(LiveScreen.parse(""), "no dump: no session")
        XCTAssertNil(LiveScreen.parse("deckhold: no session s\n"))
    }
}
