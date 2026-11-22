import Foundation
import XCTest
@testable import DozableHost

/// Every action a workspace's log holds reads as a sentence (`WorkspaceLogEntry.sentence`) — the words `doz workspace log`,
/// `doz chat read --with-log` and the dashboard's system lines share. None is the bare action word, none holds a hash or a
/// fingerprint.
final class WorkspaceLogSentenceTests: XCTestCase {
    func testEveryActionHasASentence() {
        let e: (String) -> WorkspaceLogEntry = { a in
            WorkspaceLogEntry(action: a, agent: "mira", place: "sandbox:lab", room: "demo", from: "old", to: "new", sha256: String(repeating: "a", count: 64),
                              bytes: 120, added: 1, removed: 2, reason: "its place did not run", isolation: "fenced", fingerprint: "abcdef123456")
        }
        for a in WorkspaceLogEntry.actions.sorted() {
            let s = e(a).sentence
            XCTAssertNotEqual(s, a == "created" ? "" : a, "\(a): a sentence, not the action word")
            XCTAssertFalse(s.contains("aaaaaaaa") || s.contains("abcdef123456"), "\(a): never a hash or a fingerprint — \(s)")
        }
        XCTAssertEqual(e("created").sentence, "created")
        XCTAssertEqual(e("kicked-off").sentence, "started the work: posted the brief in demo (120 bytes)")
        XCTAssertEqual(e("brief-edited").sentence, "edited the work (120 bytes)")
        XCTAssertEqual(e("brief-announced").sentence, "announced the edit in demo")
        XCTAssertEqual(e("bot-invited").sentence, "invited mira to demo")
        XCTAssertEqual(e("manager-started").sentence, "started the manager mira (fenced, sandbox:lab)")
        XCTAssertEqual(e("worker-ended").sentence, "ended the worker mira")
        XCTAssertEqual(e("room-archived").sentence, "archived the room demo (it stays readable)")
        XCTAssertEqual(e("worker-retired").sentence, "retired the worker mira (its token is refused from now on)")
        XCTAssertEqual(e("sandbox-removed").sentence, "removed the sandbox lab")
        XCTAssertEqual(e("template-kept").sentence, "saved the disk of old as the image new")
        XCTAssertEqual(WorkspaceLogEntry(action: "slept").sentence, "put the workspace to sleep")
        XCTAssertEqual(WorkspaceLogEntry(action: "agent-woke", agent: "bot1").sentence, "bot1 is awake")
        XCTAssertEqual(WorkspaceLogEntry(action: "something-later").sentence, "something-later", "an action of a newer doz: its word")
    }
}
