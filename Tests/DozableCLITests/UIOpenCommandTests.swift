import Foundation
import XCTest
@testable import DozableCLI

/// `doz ui open NAME | --workspaces`: the page it names (the one the control line and the link's `&to=` allow),
/// and what it refuses before anything runs.
final class UIOpenCommandTests: XCTestCase {
    func testThePageItOpens() throws {
        let one = try XCTUnwrap(try DozableCommand.parseAsRoot(["ui", "open", "alpha", "-q"]) as? UIOpen)
        XCTAssertEqual(one.page, "w/alpha")
        let all = try XCTUnwrap(try DozableCommand.parseAsRoot(["ui", "open", "--workspaces"]) as? UIOpen)
        XCTAssertEqual(all.page, "workspaces")
    }

    func testOneOfTheTwoAndOnlyAWorkspacesName() {
        for bad in [["ui", "open"], ["ui", "open", "alpha", "--workspaces"], ["ui", "open", "Alpha"],
                    ["ui", "open", "a/room"], ["ui", "open", String(repeating: "a", count: 41)]] {
            XCTAssertThrowsError(try DozableCommand.parseAsRoot(bad), "\(bad)")
        }
    }
}
