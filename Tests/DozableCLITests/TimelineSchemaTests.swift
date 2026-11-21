import CryptoKit
import Foundation
import XCTest
@testable import DozableHost

/// The timeline contract's documents (`Fixtures/timeline`, PIN): every vendored file is the one pinned; the schema uses
/// only keywords `JSONSchemaCheck` checks; every example passes, decodes into Dozable's types and re-encodes to the same
/// JSON; Dozable's own catalogue passes and keeps each source to its kinds and attrs; no forbidden attr anywhere.
final class TimelineSchemaTests: XCTestCase {
    static let fixtures = Pins.packageRoot.appendingPathComponent("Tests/DozableCLITests/Fixtures/timeline")
    static let examples = ["batch", "catalog", "query-binned", "query", "recording", "result-binned", "result", "view"]

    static func json(_ rel: String) throws -> Any {
        try JSONSerialization.jsonObject(with: Data(contentsOf: fixtures.appendingPathComponent(rel)))
    }
    static func schema() throws -> [String: Any] { try XCTUnwrap(try json("timeline-1.schema.json") as? [String: Any]) }
    static func validate(_ v: Any) throws -> [String] { JSONSchemaCheck.validate(v, try schema()) }
    /// A Dozable document as the schema sees it.
    static func validate<T: Encodable>(encoded v: T) throws -> [String] {
        try validate(try JSONSerialization.jsonObject(with: HostWire.encoder.encode(v)))
    }

    func testEveryVendoredFileIsTheOnePinned() throws {
        let pin = try String(contentsOf: Self.fixtures.appendingPathComponent("PIN"), encoding: .utf8)
        XCTAssertTrue(pin.contains("peer-commit 4f43c1f8616679085bee15483352a5c295f0de68"))
        var listed = 0
        for line in pin.split(separator: "\n") where line.hasPrefix("  ") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            XCTAssertEqual(parts.count, 2, String(line))
            let d = try Data(contentsOf: Self.fixtures.appendingPathComponent(String(parts[1].dropFirst(2))))
            XCTAssertEqual(SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined(), String(parts[0]), String(parts[1]))
            listed += 1
        }
        let files = FileManager.default.enumerator(atPath: Self.fixtures.path)!.compactMap { $0 as? String }
            .filter { !$0.hasSuffix("PIN") && $0.hasSuffix(".json") }
        XCTAssertEqual(listed, files.count, "every vendored file is pinned, and nothing unlisted")
    }

    func testTheSchemaUsesOnlyTheKeywordsTheValidatorChecks() throws {
        XCTAssertEqual(JSONSchemaCheck.usedKeywords(try Self.schema()).subtracting(JSONSchemaCheck.keywords), [])
    }

    func testEveryExamplePassesDecodesAndReencodesTheSame() throws {
        for n in Self.examples {
            let raw = try Self.json("examples/\(n).json")
            XCTAssertEqual(try Self.validate(raw), [], n)
            let d = try Data(contentsOf: Self.fixtures.appendingPathComponent("examples/\(n).json"))
            let again: Data
            switch (raw as? [String: Any])?["type"] as? String {
            case "catalog": again = try HostWire.encoder.encode(try HostWire.decoder.decode(TimelineCatalog.self, from: d))
            case "query": again = try HostWire.encoder.encode(try HostWire.decoder.decode(TimelineQuery.self, from: d))
            case "result": again = try HostWire.encoder.encode(try HostWire.decoder.decode(TimelineResult.self, from: d))
            case "batch": again = try HostWire.encoder.encode(try HostWire.decoder.decode(TimelineBatch.self, from: d))
            case "view": again = try HostWire.encoder.encode(try HostWire.decoder.decode(TimelineView.self, from: d))
            case "recording": again = try HostWire.encoder.encode(try HostWire.decoder.decode(TimelineRecording.self, from: d))
            default: XCTFail("\(n): no type"); continue
            }
            let a = try JSONSerialization.jsonObject(with: again) as? NSDictionary
            XCTAssertEqual(a, raw as? NSDictionary, "\(n) re-encodes to the same document")
        }
    }

    func testTheWeekRecordingPassesAndDecodes() throws {
        let raw = try Self.json("host-a-week.json")
        XCTAssertEqual(try Self.validate(raw), [])
        let rec = try HostWire.decoder.decode(TimelineRecording.self, from: Data(contentsOf: Self.fixtures.appendingPathComponent("host-a-week.json")))
        XCTAssertGreaterThan(rec.events.count, 1000)
        XCTAssertGreaterThan(rec.metrics.count, 1000)
    }

    /// Dozable's catalogue: twelve sources kept, each kind and attr list the contract's, sensitive attrs named.
    func testDozablesCatalogPasses() throws {
        let retention = TimelineSources.all.map {
            TimelineEffectiveRetention(source: $0.name, retention: $0.defaultRetention, setBy: "default", keptFrom: TimelineKeptFrom())
        }
        let cat = TimelineCatalog(hosts: ["this Mac"], sources: TimelineSources.all, retention: retention,
                                  names: [TimelineScopeName(scope: "host:this%20Mac/workspace:example-space", label: "example-space", space: true)],
                                  now: 1_795_262_400_000)
        XCTAssertEqual(try Self.validate(encoded: cat), [])
        XCTAssertEqual(TimelineSources.kept.map(\.name), ["actions", "sessions", "daemon", "network", "workspace", "grants", "runs", "chat",
                                                          "daemon-events", "egress", "resources", "keys"])
        XCTAssertTrue(TimelineSources.isSensitive("egress", "dest"))
        XCTAssertTrue(TimelineSources.isSensitive("workspace", "folder"))
        XCTAssertFalse(TimelineSources.isSensitive("egress", "port"))
        for s in TimelineSources.all { for a in s.attrs { XCTAssertFalse(TimelineAttrs.forbidden.contains(a), "\(s.name).\(a)") } }
    }

    /// The schema refuses what the contract forbids: a forbidden attr, a kind outside its source's list, a long summary,
    /// a real-looking scope with a space.
    func testWhatTheSchemaRefusesIsRefused() throws {
        func event(_ change: (inout TimelineEvent) -> Void) -> TimelineBatch {
            var e = TimelineEvent(id: "actions/1", t: 1_795_000_000_000, dur: 12, scope: "host:this%20Mac/sandbox:build-vm", source: "actions",
                                  kind: "action.ok", severity: .info, summary: "start ok", attrs: ["action": .string("start")])
            change(&e)
            return TimelineBatch(events: [e], metrics: [], now: 1_795_000_000_100)
        }
        XCTAssertEqual(try Self.validate(encoded: event { _ in }), [])
        XCTAssertFalse(try Self.validate(encoded: event { $0.attrs["path"] = .string("/x") }).isEmpty, "a forbidden attr")
        XCTAssertFalse(try Self.validate(encoded: event { $0.kind = "egress.allowed" }).isEmpty, "a kind of another source")
        XCTAssertFalse(try Self.validate(encoded: event { $0.attrs["dest"] = .string("x") }).isEmpty, "an attr of another source")
        XCTAssertFalse(try Self.validate(encoded: event { $0.summary = String(repeating: "x", count: 201) }).isEmpty, "a long summary")
        XCTAssertFalse(try Self.validate(encoded: event { $0.scope = "host:this Mac" }).isEmpty, "an unescaped space")
        // The builder drops a forbidden key (a debug build stops on it — so this checks the release path's list only).
        XCTAssertTrue(TimelineAttrs.forbidden.isSuperset(of: ["text", "question", "command", "url", "path", "headers", "hostname", "token"]))
    }

    func testScopesEscapeAndNest() {
        XCTAssertEqual(TimelineScope.join("", "host", "this Mac"), "host:this%20Mac")
        XCTAssertEqual(TimelineScope.join("host:a", "session", "a/b:c%d"), "host:a/session:a%2Fb%3Ac%25d")
        XCTAssertTrue(TimelineScope.isScope("host:this%20Mac/workspace:w/sandbox:s/session:claude~12"))
        XCTAssertFalse(TimelineScope.isScope("host:this Mac"))
        XCTAssertFalse(TimelineScope.isScope("planet:x"))
        XCTAssertTrue(TimelineScope.within("host:a/workspace:w/sandbox:s", "host:a/workspace:w"))
        XCTAssertFalse(TimelineScope.within("host:a/workspace:w-2", "host:a/workspace:w"))
        XCTAssertEqual(TimelineScope.name("host:this%20Mac"), "this Mac")
        XCTAssertEqual(TimelineScope.kind("host:a/room:rm_1"), "room")
    }

    func testTheMacsNameIsTheSettingOrTheTestsAndNeverTheNetworks() {
        XCTAssertEqual(MacDisplayName.current(["DOZ_TEST_GUARD": "1", "DOZ_TEST_MAC_NAME": "mini"]), "mini")
        XCTAssertEqual(MacDisplayName.current(["DOZ_TEST_GUARD": "1", "DOZ_MAC_NAME": "studio"]), "studio")
        XCTAssertEqual(MacDisplayName.current(["DOZ_TEST_GUARD": "1", "XDG_CONFIG_HOME": "/nonexistent-747"]), "this Mac")
        XCTAssertTrue(MacDisplayName.isValid("this Mac"))
        XCTAssertTrue(MacDisplayName.isValid("studio-2"))
        XCTAssertFalse(MacDisplayName.isValid("studio.local"))
        XCTAssertFalse(MacDisplayName.isValid(""))
        XCTAssertFalse(MacDisplayName.isValid(String(repeating: "a", count: 64)))
        XCTAssertEqual(HostCore.spaceStateHost(["DOZ_TEST_GUARD": "1", "DOZ_TEST_MAC_NAME": "mini"]), "mini")
    }
}
