import Foundation
import XCTest
@testable import DozableHost

/// 676: `docs/HOST-PROTOCOL.md` cannot drift from the host: every op has a row in its table, and the protocol version it
/// states is the one the code speaks.
final class HostProtocolDocTests: XCTestCase {
    private func document() throws -> String {
        try String(contentsOf: Pins.packageRoot.appendingPathComponent("docs/HOST-PROTOCOL.md"), encoding: .utf8)
    }

    func testEveryOperationHasARow() throws {
        let doc = try document()
        let rows = Set(doc.split(separator: "\n").compactMap { line -> String? in
            guard line.hasPrefix("| `") else { return nil }
            return line.dropFirst(3).prefix { $0 != "`" }.description
        })
        for op in HostOp.allCases {
            XCTAssertTrue(rows.contains(op.rawValue), "docs/HOST-PROTOCOL.md has no row for the op `\(op.rawValue)`")
        }
        let known = Set(HostOp.allCases.map(\.rawValue))
        let table = doc.components(separatedBy: "\n## Operations\n").last?.components(separatedBy: "\n## The stability promise").first ?? ""
        for line in table.split(separator: "\n") where line.hasPrefix("| `") {
            let name = line.dropFirst(3).prefix { $0 != "`" }.description
            XCTAssertTrue(known.contains(name), "docs/HOST-PROTOCOL.md documents an op the host does not serve: `\(name)`")
        }
    }

    func testDocumentedVersionIsTheHostsVersion() throws {
        let doc = try document()
        let line = try XCTUnwrap(doc.split(separator: "\n").first { $0.hasPrefix("**Protocol version: ") }, "no 'Protocol version' line")
        let digits = line.dropFirst("**Protocol version: ".count).prefix { $0.isNumber }
        XCTAssertEqual(Int(digits), HostProtocol.version)
    }

    func testProtocolChangesHasTheCurrentRelease() throws {
        let doc = try document()
        let changes = try XCTUnwrap(doc.components(separatedBy: "\n## Protocol changes\n").last)
        XCTAssertTrue(changes.contains("| 0.37.42 |"))
    }
}
