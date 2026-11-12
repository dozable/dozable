import Foundation
import XCTest
import DozableKit
import DozableHost
@testable import DozableWeb

/// The sessions on this Mac in the dashboard: the projection (states, the bypass mark, no isolation said in the answer),
/// the ticket's strict body, and the route table (the Serve*/WebAction tests hold the exposure and the actions).
final class WebMacSessionsTests: XCTestCase {
    func testTheProjection() throws {
        var live = SessionRow(SessionInfo(name: "agent", pid: 7, size: TermSize(cols: 120, rows: 40), clients: 1, command: "claude"))
        live.workdir = "/Users/x/app"
        live.openedAt = Date(timeIntervalSince1970: 1)
        var bypassed = SessionRow(SessionInfo(name: "yolo", pid: 8, command: "claude --dangerously-skip-permissions"))
        bypassed.bypassed = true
        var gone = SessionRow(SessionInfo(name: "old", command: "sh"))
        gone.ended = true
        gone.gone = true
        let ended = SessionRow(SessionInfo(name: "done", exitCode: 3))
        let p = [live, bypassed, gone, ended].map(WebMacSession.init)
        XCTAssertEqual(p.map(\.state), ["running", "running", "gone", "ended"])
        XCTAssertEqual(p.map(\.bypassed), [false, true, false, false])
        XCTAssertEqual(p[0].workdir, "/Users/x/app")
        XCTAssertEqual(p[3].exitCode, 3)
        let all = WebMacSessions(sessions: p, access: "watch")
        let json = String(decoding: try WebJSON.encoder.encode(all), as: UTF8.self)
        XCTAssertTrue(json.contains("\"isolated\":false"), "no client can take them for sandboxes")
    }

    func testTheTicketBodyIsStrict() throws {
        let ok = try WebMacTicket.decode(Data(#"{"mode":"watch","session":"agent"}"#.utf8))
        XCTAssertEqual(ok.mode, .watch)
        XCTAssertNil(ok.size, "a watcher never sizes the session")
        XCTAssertEqual(try WebMacTicket.decode(Data(#"{"mode":"interactive","session":"agent","cols":80,"rows":24,"reattach":true}"#.utf8)).size,
                       TermSize(cols: 80, rows: 24))
        for bad in [#"{"mode":"watch"}"#, #"{"mode":"console"}"#, #"{"mode":"interactive","session":"a","quiet":true}"#,
                    #"{"mode":"watch","session":"\#(String(repeating: "a", count: 33))"}"#, #"{"mode":"watch","session":"../x"}"#,
                    #"{"mode":"watch","session":"a","argv":["sh"]}"#, "[]"] {
            XCTAssertThrowsError(try WebMacTicket.decode(Data(bad.utf8)), bad)
        }
    }

    func testTheGridsTakeTheMac() throws {
        let items = try WebGridsRequest.decode(Data(#"{"items":[{"sandbox":"@mac","session":"agent","gen":0}]}"#.utf8))
        XCTAssertEqual(items.first?.sandbox, "@mac")
        XCTAssertThrowsError(try WebGridsRequest.decode(Data(#"{"items":[{"sandbox":"@other","session":"a","gen":0}]}"#.utf8)))
    }
}
