import ArgumentParser
import Foundation
import XCTest
@testable import DozableCLI
@testable import DozableHost

/// The frozen exit-code contract (`ExitCodes`): its codes and their meanings, every error code placed exactly once,
/// and `doz help exit-codes --json`'s shape. A change here is a change to a published contract.
final class ExitCodesTests: XCTestCase {
    func testTheExitSetIsThePublishedOne() {
        XCTAssertEqual(ExitCodes.table.map(\.exit), [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 64, 65, 75, 124, 125])
        XCTAssertEqual(Set(ExitCodes.table.map(\.exit)).count, ExitCodes.table.count, "every exit once")
        XCTAssertEqual(Set(ExitCodes.table.map(\.name)).count, ExitCodes.table.count, "every name once")
        XCTAssertFalse(ExitCodes.table.contains { $0.meaning.isEmpty })
    }

    func testEachErrorCodeIsInExactlyOneRow() {
        let all = ExitCodes.table.flatMap { $0.errorCodes + ($0.alsoErrorCodes ?? []) }
        XCTAssertEqual(all.count, Set(all).count, "an error code in two rows: \(all)")
    }

    /// A new HostError code must be placed in the table (the switch in `exit(for:)` is exhaustive; this checks the
    /// published rows agree with it).
    func testEveryErrorKindMapsThroughTheTable() {
        for c in HostError.Code.allCases {
            let rows = ExitCodes.table.filter { $0.errorCodes.contains(c.rawValue) || ($0.alsoErrorCodes ?? []).contains(c.rawValue) }
            XCTAssertEqual(rows.count, 1, "\(c.rawValue) is in \(rows.count) rows")
            XCTAssertEqual(rows.first?.exit, ExitCodes.exit(for: c), "\(c.rawValue): the row and exit(for:) disagree")
            XCTAssertEqual(DozableExit.code(for: HostError(c, "")), ExitCodes.exit(for: c), "the CLI uses the table")
        }
        let listed = Set(ExitCodes.table.flatMap { $0.errorCodes + ($0.alsoErrorCodes ?? []) })
        XCTAssertEqual(listed, Set(HostError.Code.allCases.map(\.rawValue)), "every listed code is a real one")
    }

    func testTwoIsOnlyNotFoundAndAmbiguous() {
        XCTAssertEqual(ExitCodes.entry(2)?.errorCodes, ["not-found", "ambiguous"])
        XCTAssertNil(ExitCodes.entry(2)?.alsoErrorCodes)
        for c in HostError.Code.allCases where ExitCodes.exit(for: c) == 2 { XCTAssertTrue([.notFound, .ambiguous].contains(c), c.rawValue) }
    }

    func testThePlansCodes() {
        XCTAssertEqual(ExitCodes.exit(for: .invalid), 65)
        XCTAssertEqual(ExitCodes.exit(for: .invalidDocument), 65)
        XCTAssertEqual(ExitCodes.exit(for: .invalidValue), 65)
        XCTAssertEqual(ExitCodes.exit(for: .secretValueInDocument), 65)
        XCTAssertEqual(ExitCodes.exit(for: .usage), 64)
        XCTAssertEqual(ExitCodes.exit(for: .unclearRequest), 64)
        XCTAssertEqual(ExitCodes.entry(3)?.errorCodes, ["invalid-phase", "conflict", "plan-changed", "file-changed", "already-answered", "not-owned", "request-id-reused", "run-open", "proposal-decided"])
        XCTAssertEqual(ExitCodes.entry(4)?.errorCodes, ["already-exists"])
        XCTAssertEqual(ExitCodes.entry(5)?.errorCodes, ["needs-confirmation"])
        XCTAssertEqual(ExitCodes.entry(6)?.errorCodes, ["needs-daemon"])
        XCTAssertEqual(ExitCodes.entry(8)?.errorCodes, ["limited"])
        XCTAssertEqual(ExitCodes.entry(9)?.errorCodes, ["not-permitted"])
        XCTAssertEqual(ExitCodes.entry(75)?.errorCodes, ["partial"])
        XCTAssertEqual(ExitCodes.entry(124)?.errorCodes, ["timed-out"])
        XCTAssertEqual(ExitCodes.timedOut, DozableExitCode.timedOut)
        // Today's codes keep their exits.
        XCTAssertEqual(ExitCodes.exit(for: .exists), 4)
        XCTAssertEqual(ExitCodes.exit(for: .unavailable), 6)
        XCTAssertEqual(ExitCodes.exit(for: .version), 6)
        XCTAssertEqual(ExitCodes.exit(forCode: "no-such-code"), 1)
    }

    func testAnUnknownCodeDecodesAsFailed() throws {
        let e = try JSONDecoder().decode(HostError.self, from: Data(#"{"code":"from-a-later-doz","message":"m"}"#.utf8))
        XCTAssertEqual(e.code, .failed)
        XCTAssertEqual(e.message, "m")
    }

    func testTheHelpJSONShape() throws {
        let d = try HostWire.prettyEncoder.encode(ExitCodesAnswer())
        let o = try XCTUnwrap(JSONSerialization.jsonObject(with: d) as? [String: Any])
        XCTAssertEqual(o["kind"] as? String, "ExitCodes")
        XCTAssertEqual(o["schema"] as? Int, 1)
        let codes = try XCTUnwrap(o["codes"] as? [[String: Any]])
        XCTAssertEqual(codes.compactMap { $0["exit"] as? Int }, [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 64, 65, 75, 124, 125])
        let two = try XCTUnwrap(codes.first { $0["exit"] as? Int == 2 })
        XCTAssertEqual(two["name"] as? String, "not-found")
        XCTAssertEqual(two["errorCodes"] as? [String], ["not-found", "ambiguous"])
        XCTAssertNotNil(two["meaning"] as? String)
        XCTAssertTrue(HelpExitCodes.isAsked(["help", "exit-codes", "--json"]))
        XCTAssertFalse(HelpExitCodes.isAsked(["help", "ls"]))
        XCTAssertNoThrow(try HelpExitCodes.parseAsRoot(["--json"]))
    }

    func testTheErrorShapeGainsExit() throws {
        let d = try HostWire.encoder.encode(ErrorAnswer(HostError(.notFound, "no workspace nosuch")))
        let o = try XCTUnwrap(JSONSerialization.jsonObject(with: d) as? [String: Any])
        let e = try XCTUnwrap(o["error"] as? [String: Any])
        XCTAssertEqual(e["code"] as? String, "not-found")
        XCTAssertEqual(e["message"] as? String, "no workspace nosuch")
        XCTAssertEqual(e["exit"] as? Int, 2)
        XCTAssertEqual(try ErrorAnswer(HostError(.failed, "x"), exit: 125).error.exit, 125, "an exit the command chose is the one said")
    }

    /// A space file's errors are one invalid document: 65, never 2 (2 is only not found).
    func testASpaceFilesErrorsAreAnInvalidDocument() throws {
        let p = [SpaceProblem(pointer: "/agents/w/isolation", message: "isolation: fenced, vm or unfenced", file: "a.space.yaml", line: 6)]
        let e = spaceDocumentError(p)
        XCTAssertEqual(e.code, .invalidDocument)
        XCTAssertEqual(ExitCodes.exit(for: e), 65)
        XCTAssertTrue(e.message.contains("a.space.yaml:6"))
        var plan = SpacePlan(space: "s", title: "", specPath: nil, specSHA: "", sources: [], factsKnown: false)
        plan.refusalCode = "invalid"
        plan.refusals = ["the space file has 1 error(s)"]
        XCTAssertEqual(spacePlanError(plan)?.code, .invalidDocument)
        plan.refusalCode = "not-found"
        XCTAssertEqual(spacePlanError(plan).map(ExitCodes.exit(for:)), 2)
        plan.refusalCode = nil
        XCTAssertNil(spacePlanError(plan))
        // The answer: the plan's own fields, and `error` beside them.
        let d = try HostWire.encoder.encode(WithError(value: SpaceProblemsAnswer(problems: p), error: e))
        let o = try XCTUnwrap(JSONSerialization.jsonObject(with: d) as? [String: Any])
        XCTAssertNotNil(o["problems"])
        XCTAssertEqual((o["error"] as? [String: Any])?["exit"] as? Int, 65)
    }

    func testAPartialAnswerSaysWhatRemainsAndHowToRetry() throws {
        let p = PartialAnswer(done: ["room r"], remaining: ["agent a"], retry: ["doz", "workspace", "up", "-f", "/x.space.yaml"])
        let d = try HostWire.encoder.encode(WithError(value: ["space": "s"], error: HostError(.partial, "m"), partial: p))
        let o = try XCTUnwrap(JSONSerialization.jsonObject(with: d) as? [String: Any])
        let q = try XCTUnwrap(o["partial"] as? [String: Any])
        XCTAssertEqual(q["code"] as? String, "partial")
        XCTAssertEqual(q["done"] as? [String], ["room r"])
        XCTAssertEqual(q["remaining"] as? [String], ["agent a"])
        XCTAssertEqual(q["retry"] as? [String], ["doz", "workspace", "up", "-f", "/x.space.yaml"])
        XCTAssertEqual((o["error"] as? [String: Any])?["exit"] as? Int, 75)
    }
}
