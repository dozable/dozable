import Foundation
import XCTest
@testable import DozableHost

/// A worker's START: the first line in the shape the test's fake claude reads (`You are NAME,` / `Your room in chat:`), the
/// room, who directs it, the skills, the task verbatim, what it can do where it runs — and no token.
final class WorkerKickoffTests: XCTestCase {
    func testTheShapeAndTheTask() {
        let task = "list the files\nthen count them, and say how many"
        let t = WorkerKickoff.startText(name: "bot1", workspace: "demo", room: "demo", task: task, director: nil, place: .fenced,
                                        skills: [], instructions: nil)
        XCTAssertTrue(t.hasPrefix("You are bot1, a worker in the workspace demo. Your task: list the files\nYour room in chat: demo\n"), t)
        XCTAssertTrue(t.contains("## Your task\n\n" + task + "\n"), "the task verbatim, in full")
        for s in ["- chat-worker", "- chat-room-member", "CHAT_TOKEN_FILE", "The person, in demo", "fenced on this Mac",
                  "Say in demo that you are up, with your task in a few words"] {
            XCTAssertTrue(t.contains(s), s)
        }
        XCTAssertTrue(t.contains("A workspace is an environment set up for getting work done: its agents, its rooms, the brief that says what the work is for, and any folders it works on (usually projects)."))
        XCTAssertFalse(t.contains("dzc_"))
    }

    func testABotsWorkerAndItsDirector() {
        let t = WorkerKickoff.startText(name: "otto", workspace: "wk", room: "wk", task: "review the PR", director: "mira", place: .vm,
                                        skills: ["review"], instructions: "Be brief.")
        XCTAssertTrue(t.hasPrefix("You are otto, a worker in the workspace wk. Your task: review the PR\n"))
        for s in ["mira, the workspace's manager, in wk", "- review", "## Your instructions\n\nBe brief.", "micro VM of your own"] {
            XCTAssertTrue(t.contains(s), s)
        }
    }

    func testWhereItRuns() {
        func text(_ w: WorkerKickoff.Where) -> String {
            WorkerKickoff.startText(name: "v2", workspace: "vw", room: "vw", task: "t", director: nil, place: w, skills: [], instructions: nil)
        }
        XCTAssertTrue(text(.shared("vw-v1")).contains("the sandbox vw-v1, which other agents of the workspace share: they can read your files and placeholders there"))
        XCTAssertTrue(text(.unfenced).contains("You act as the person"))
        let long = String(repeating: "y", count: 400)
        let t = WorkerKickoff.startText(name: "b", workspace: "w", room: "w", task: long, director: nil, place: .fenced, skills: [], instructions: nil)
        XCTAssertLessThan(t.split(separator: "\n").first!.count, 300, "the first line is shortened; the task is in full below")
        XCTAssertTrue(t.contains(long))
    }
}
