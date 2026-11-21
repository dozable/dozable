import Foundation
import XCTest
@testable import DozableHost

/// The search language's vectors (`Fixtures/timeline/vectors.json`): each `where` decodes strictly, and the Swift port of
/// the contract's `matchAst` applies it to the week's recording as the reference does. `TimelineQueryTests` then holds
/// the SQL compiler to this port on every vector.
final class TimelineMatchTests: XCTestCase {
    struct Vectors: Decodable {
        struct V: Decodable { var q: String; var `where`: TimelineSearchAst; var from: Int64; var to: Int64; var warnings: [String] }
        var now: Int64; var from: Int64; var to: Int64; var vectors: [V]
    }
    static func vectors() throws -> Vectors {
        try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: TimelineSchemaTests.fixtures.appendingPathComponent("vectors.json")))
    }
    static func recording() throws -> TimelineRecording {
        try HostWire.decoder.decode(TimelineRecording.self, from: Data(contentsOf: TimelineSchemaTests.fixtures.appendingPathComponent("host-a-week.json")))
    }

    func testEveryVectorDecodesAndReencodes() throws {
        let v = try Self.vectors()
        XCTAssertGreaterThan(v.vectors.count, 30)
        for x in v.vectors {
            let again = try JSONDecoder().decode(TimelineSearchAst.self, from: JSONEncoder().encode(x.where))
            XCTAssertEqual(again, x.where, x.q)
        }
    }

    func testThePortAppliesEachTermAsTheContractSays() throws {
        let rec = try Self.recording(), v = try Self.vectors()
        func hits(_ q: String) throws -> [TimelineEvent] {
            let w = try XCTUnwrap(v.vectors.first { $0.q == q }).where
            return rec.events.filter { TimelineMatcher.matches(w, $0) }
        }
        XCTAssertEqual(try hits("").count, rec.events.count)
        XCTAssertEqual(try hits("kind:action.ok").count, rec.events.filter { $0.kind == "action.ok" }.count)
        XCTAssertEqual(try hits("kind:action.*").count, rec.events.filter { $0.kind.hasPrefix("action.") }.count)
        XCTAssertEqual(try hits("-source:chat").count, rec.events.filter { $0.source != "chat" }.count)
        XCTAssertEqual(try hits("severity:>=notice").count, rec.events.filter { $0.severity >= .notice }.count)
        XCTAssertEqual(try hits("kind:session.open kind:session.end").count,
                       rec.events.filter { $0.kind == "session.open" || $0.kind == "session.end" }.count)
        let scoped = try hits("scope:host:host-a/workspace:example-space")
        XCTAssertFalse(scoped.isEmpty)
        XCTAssertTrue(scoped.allSatisfy { $0.scope.hasPrefix("host:host-a/workspace:example-space") })
        // A sensitive attr is never matched by free text, only by attr.KEY:.
        let e = TimelineEvent(id: "egress/1", t: 1, scope: "host:a/sandbox:s", source: "egress", kind: "egress.denied", severity: .warning,
                              summary: "a connection denied", attrs: ["dest": .string("example.net"), "port": .number(443)])
        XCTAssertFalse(TimelineMatcher.matches(TimelineSearchAst(all: [TimelineAstTerm(any: [.text("example.net")])]), e))
        XCTAssertTrue(TimelineMatcher.matches(TimelineSearchAst(all: [TimelineAstTerm(any: [.attr(key: "dest", value: "EXAMPLE.net")])]), e))
        XCTAssertTrue(TimelineMatcher.matches(TimelineSearchAst(all: [TimelineAstTerm(any: [.attr(key: "port", value: "443")])]), e))
    }
}
