import Foundation
import XCTest
@testable import DozableCLI
@testable import DozableHost

/// 678 B5: the `sessions send` / `sessions screen` command lines.
final class SessionsSendCommandTests: XCTestCase {
    func testABareThenScreenMeansTheDefault() {
        XCTAssertEqual(SessionsSend.normalized(["sessions", "send", "a", "s", "--text", "x", "--then-screen"]),
                       ["sessions", "send", "a", "s", "--text", "x", "--then-screen-default"])
        XCTAssertEqual(SessionsSend.normalized(["sessions", "send", "a", "s", "--then-screen", "--enter"]),
                       ["sessions", "send", "a", "s", "--then-screen-default", "--enter"])
        XCTAssertEqual(SessionsSend.normalized(["sessions", "send", "a", "s", "--then-screen", "900"]),
                       ["sessions", "send", "a", "s", "--then-screen", "900"], "a value is kept")
        XCTAssertEqual(SessionsSend.normalized(["sessions", "send", "a", "s", "--then-screen=900"]), ["sessions", "send", "a", "s", "--then-screen=900"])
        XCTAssertEqual(SessionsSend.normalized(["exec", "a", "--", "--then-screen"]), ["exec", "a", "--", "--then-screen"], "not send: untouched")
    }

    func testTheyParse() throws {
        let send = try DozableCommand.parseAsRoot(SessionsSend.normalized(["sessions", "send", "box", "agent", "--text", "hi", "--keys", "tab", "up", "--enter", "--then-screen"]))
        let s = try XCTUnwrap(send as? SessionsSend)
        XCTAssertEqual(s.name, "box")
        XCTAssertEqual(s.session, "agent")
        XCTAssertEqual(s.keys, ["tab", "up"])
        XCTAssertTrue(s.enter)
        XCTAssertTrue(s.thenScreenDefault)
        let scr = try XCTUnwrap(try DozableCommand.parseAsRoot(["sessions", "screen", "box", "agent", "--wake", "--json"]) as? SessionsScreen)
        XCTAssertTrue(scr.wake)
        XCTAssertTrue(scr.g.json)
        // The list stays the default.
        XCTAssertTrue(try DozableCommand.parseAsRoot(["sessions", "box"]) is SessionsList)
    }

    func testTheAnswersRoundTrip() throws {
        let sent = SessionSent(sandbox: "a", session: "s", bytes: 3, woke: true, milliseconds: 12)
        XCTAssertEqual(try HostWire.decoder.decode(SessionSent.self, from: HostWire.encoder.encode(sent)), sent)
        var live = SessionLive(sandbox: "a", session: "s", live: false, text: "x", cols: 80, rows: 24, cursorX: nil, cursorY: nil, screen: "primary")
        live.savedAt = Date(timeIntervalSince1970: 1_800_000_000)
        live.reason = "hibernate"
        XCTAssertEqual(try HostWire.decoder.decode(SessionLive.self, from: HostWire.encoder.encode(live)), live)
        XCTAssertTrue(HostOp.sessionLive.isReadOnly)
        XCTAssertFalse(HostOp.sessionSend.isReadOnly)
        var r = HostRequest(.sessionSend, name: "a")
        r.input = Data([0x1B, 0x0D])
        XCTAssertEqual(try HostWire.decoder.decode(HostRequest.self, from: HostWire.encoder.encode(r)).input, Data([0x1B, 0x0D]))
    }
}
