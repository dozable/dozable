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
                                                    settings: settings, home: MacSessions.plannedHome())
            XCTAssertEqual(cli, shared, args.joined(separator: " "))
            XCTAssertEqual(MacFence.capabilities(cli), MacFence.capabilities(shared))
        }
    }

    /// 683 M6: fenced is the default for a NEW session; the flag > `DOZ_MAC_FENCE` > `mac.fence` (the file) > on.
    func testFencedIsTheDefaultAndThePrecedence() throws {
        func fenced(_ args: [String], file: String? = nil, env: [String: String] = [:]) throws -> Bool {
            try Run.parse(["@mac"] + args + ["--", "/bin/sh"]).fencedOnMac(DozableSettings(text: file, environment: env))
        }
        let off = "[mac]\nfence = \"off\"\n"
        XCTAssertEqual(DozableSettings(text: nil).string(SettingKey.macFence), "on")
        XCTAssertTrue(try fenced([]), "no flag, no setting: fenced")
        XCTAssertFalse(try fenced(["--unfenced"]))
        XCTAssertFalse(try fenced([], file: off), "mac.fence = off")
        XCTAssertFalse(try fenced([], env: ["DOZ_MAC_FENCE": "off"]))
        XCTAssertTrue(try fenced([], file: off, env: ["DOZ_MAC_FENCE": "on"]), "the variable beats the file")
        XCTAssertTrue(try fenced(["--fenced"], env: ["DOZ_MAC_FENCE": "off"]), "the flag beats the variable")
        XCTAssertTrue(try fenced(["--keychain"], file: off), "a fenced-only flag means fenced")
        XCTAssertFalse(try fenced(["--unfenced"], env: ["DOZ_MAC_FENCE": "on"]))
    }

    /// 683 M6: a planned session (the wizard, `--dry-run`) names the agent folder under the home `DisplayPath` shows as `~`
    /// — the History row once read `/Users/…/.claude/projects/…`.
    func testThePlannedHistoryRowShowsTheHomeWithATilde() {
        let home = TestSafety.realHome.path
        let s = MacCapabilityShape.planned(session: "claude", workdir: home + "/src/app", argv: ["claude"], fenced: true,
                                           request: MacFenceRequest(permissions: ["standard"]), settings: DozableSettings(text: nil), home: home)
        let history = MacFence.capabilities(s).first { $0.id == "history" }
        XCTAssertEqual(history?.state, "keep")
        XCTAssertTrue(history?.sentence.contains("~/.claude/projects/…") == true, history?.sentence ?? "no row")
        XCTAssertFalse(MacFence.capabilities(s).contains { $0.sentence.contains(home + "/") || $0.state.contains(home + "/") })
        // A guarded run (XCTest always is): the fence's scratch seam when given, else the real home's spelling (words only).
        XCTAssertEqual(MacSessions.plannedHome([:]), home)
        XCTAssertEqual(MacSessions.plannedHome(["DOZ_TEST_FENCE_HOME": "/private/tmp"]), "/private/tmp")
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
