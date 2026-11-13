import Foundation
@testable import DozableKit
import XCTest
@testable import DozableCLI
@testable import DozableHost

/// 683 M5: `doz run @mac … --dry-run` and the dashboard's New session wizard build the session they WOULD open with one
/// function (`MacCapabilityShape.planned`), so the rows they print are the same; and a live row says what a host serving
/// it knows (the network through the proxy, never "waiting for a host").
final class MacFenceCapabilitiesTests: XCTestCase {
    func testTheDryRunUsesTheSharedShape() throws {
        let settings = DozableSettings(text: nil)
        let cases: [[String]] = [
            ["@mac", "--fenced", "--workdir", "/Users/x/src/app", "--", "claude"],
            ["@mac", "--fenced", "--local-port", "3000", "--github", "read", "--workdir", "/Users/x/src/app", "--", "claude"],
            ["@mac", "--simulator", "--keychain", "--agent-config", "shared", "--workdir", "/Users/x/src/app", "--", "claude"],
            ["@mac", "--fenced", "--permissions", "locked", "--ssh-agent", "--workdir", "/Users/x/src/app", "--", "claude"],
            ["@mac", "--unfenced", "--workdir", "/Users/x", "--", "claude"],
        ]
        for args in cases {
            let run = try Run.parse(args)
            let fence = run.fencedOnMac(settings)
            let cli = run.dryRunShape(settings, fence: fence, workdir: "/Users/x/src/app", absolute: { $0 })
            let shared = MacCapabilityShape.planned(session: "claude", workdir: "/Users/x/src/app", argv: ["claude"], fenced: fence,
                                                    request: fence ? run.fenceRequest(settings, absolute: { $0 }) : nil,
                                                    settings: settings, home: NSHomeDirectory())
            XCTAssertEqual(cli, shared, args.joined(separator: " "))
            XCTAssertEqual(MacFence.capabilities(cli), MacFence.capabilities(shared))
        }
    }

    func testTheStandardPresetIsNamedStandard() {
        var s = MacCapabilityShape(session: "s", workdir: "/w", fenced: true)
        s.preset = "agent"
        XCTAssertEqual(MacFence.capabilities(s).first { $0.id == "network" }?.state, "through Dozable's proxy (standard)")
        s.preset = nil
        XCTAssertEqual(MacFence.capabilities(s).first { $0.id == "network" }?.state, "through Dozable's proxy (custom)")
        s.network = "proxy"
        XCTAssertFalse(MacFence.capabilities(s).first { $0.id == "network" }!.state.contains("waiting"))
    }

    func testTheRowCarriesTheLastCopyTimeOnly() throws {
        let json = #"{"profile":"agent","keychain":false,"readable":[],"writable":[],"sessionFolder":"/s","templateVersion":1,"profileSHA256":"x","lastCopyAt":"2026-11-13T10:00:00Z"}"#
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        XCTAssertNotNil(try dec.decode(MacFenceRow.self, from: Data(json.utf8)).lastCopyAt)
    }
}
