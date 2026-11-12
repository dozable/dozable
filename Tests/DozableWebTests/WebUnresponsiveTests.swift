import Foundation
import XCTest
import DozableHost
@testable import DozableWeb

/// A sandbox whose guest does not answer (`SandboxInfo.unresponsive`, the host's bounded read) reaches the page: the
/// list's "not answering" line and the sandbox page's callout read `unresponsive` from the row.
final class WebUnresponsiveTests: XCTestCase {
    func info(_ unresponsive: Bool?) -> SandboxInfo {
        var i = SandboxInfo(name: "box", image: "lab", phase: "running", busy: false, cpus: 2, memoryMiB: 1024, ramHeldMiB: 1024,
                            memoryReturnedMiB: 0, diskBytes: 0, sessions: nil, network: "bake", deniedConnections: nil, workspace: nil,
                            createdAt: Date(timeIntervalSince1970: 0), diedWithHost: nil)
        i.unresponsive = unresponsive
        return i
    }

    func testTheRowCarriesIt() throws {
        XCTAssertEqual(WebSandboxRow(info(true)).unresponsive, true)
        XCTAssertNil(WebSandboxRow(info(nil)).unresponsive)
        XCTAssertNil(WebSandboxRow(info(false)).unresponsive, "said only when true")
        let json = String(decoding: try WebJSON.encoder.encode(WebSandboxRow(info(true))), as: UTF8.self)
        XCTAssertTrue(json.contains("\"unresponsive\":true"), json)
    }
}
