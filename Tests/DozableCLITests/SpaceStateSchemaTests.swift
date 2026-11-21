import Foundation
import XCTest
@testable import DozableHost

/// The editor's SpaceState schema (`Fixtures/space-state/space-state-1.schema.json`, PIN), checked by a validator written
/// for exactly the keywords it uses — the test first asserts it uses no other, so a schema that grows one fails here
/// rather than passing unchecked. Every fixture passes; `SpaceStateTests.testEveryBuiltDocumentPassesTheSchema` runs the
/// builder's documents through the same validator; a document with a field the schema does not name, a wrong state for its
/// type or Ask fields on another kind fails.
final class SpaceStateSchemaTests: XCTestCase {
    static let keywords = JSONSchemaCheck.keywords

    static func schema() throws -> [String: Any] {
        let d = try Data(contentsOf: SpaceStateTests.fixtures.appendingPathComponent("space-state-1.schema.json"))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: d) as? [String: Any])
    }

    static func usedKeywords(_ s: Any) -> Set<String> { JSONSchemaCheck.usedKeywords(s) }
    static func validate(_ v: Any, _ root: [String: Any]) -> [String] { JSONSchemaCheck.validate(v, root) }

    // MARK: the tests

    func testTheSchemaUsesOnlyTheKeywordsThisValidatorChecks() throws {
        let used = Self.usedKeywords(try Self.schema())
        XCTAssertEqual(used.subtracting(Self.keywords), [], "a keyword this validator does not check")
    }

    func testEveryFixturePasses() throws {
        let schema = try Self.schema()
        for n in SpaceStateTests.names {
            let v = try JSONSerialization.jsonObject(with: try SpaceStateTests.fixture(n))
            XCTAssertEqual(Self.validate(v, schema), [], n)
        }
    }

    /// An ask's attention item as the builder writes it passes the schema; one without what kind `ask` requires does not.
    func testAnAskItemPassesTheSchemaAndAMissingFieldDoesNot() throws {
        let schema = try Self.schema()
        var d = try XCTUnwrap(try JSONSerialization.jsonObject(with: try SpaceStateTests.fixture("running")) as? [String: Any])
        let item: [String: Any] = ["subject": "manager", "kind": "ask", "text": "manager asks a question", "askId": "bbbbbbbb-1111-4222-8333-444455556666",
                                   "room": "example-space", "from": "manager", "openedAt": "2026-11-18T11:08:20Z", "question": "Ship it now?",
                                   "options": ["Ship", "Wait", "Decline"], "answerers": ["ada"], "canAnswer": true, "expiresAt": "2026-11-21T09:00:00Z"]
        d["attention"] = [item]
        XCTAssertEqual(Self.validate(d, schema), [])
        var hidden = item
        hidden["question"] = nil
        d["attention"] = [hidden]
        XCTAssertEqual(Self.validate(d, schema), [], "the question is absent when hidden")
        var bad = item
        bad["canAnswer"] = nil
        d["attention"] = [bad]
        XCTAssertFalse(Self.validate(d, schema).isEmpty, "kind ask requires canAnswer")
    }

    func testWhatTheSchemaRefusesIsRefused() throws {
        let schema = try Self.schema()
        func doc(_ change: (inout [String: Any]) -> Void) throws -> [String: Any] {
            var d = try XCTUnwrap(try JSONSerialization.jsonObject(with: try SpaceStateTests.fixture("running")) as? [String: Any])
            change(&d)
            return d
        }
        XCTAssertFalse(Self.validate(try doc { $0["extra"] = 1 }, schema).isEmpty, "an unknown field")
        XCTAssertFalse(Self.validate(try doc { $0["sha"] = "x" }, schema).isEmpty, "a sha that is not 64 hex")
        XCTAssertFalse(Self.validate(try doc { $0["version"] = 2 }, schema).isEmpty, "another version")
        XCTAssertFalse(Self.validate(try doc { d in
            var items = d["items"] as! [[String: Any]]
            items[0]["state"] = "present"
            d["items"] = items
        }, schema).isEmpty, "an agent's state from another type")
        XCTAssertFalse(Self.validate(try doc { d in
            var items = d["items"] as! [[String: Any]]
            items[1]["activity"] = "idle"
            d["items"] = items
        }, schema).isEmpty, "activity on a member")
        XCTAssertFalse(Self.validate(try doc { d in
            d["attention"] = [["subject": "worker", "kind": "permission", "text": "t", "question": "q"]]
        }, schema).isEmpty, "a question on an attention that is not an Ask")
        XCTAssertEqual(Self.validate(try doc { d in
            d["attention"] = [["subject": "worker", "kind": "permission", "text": "t"]]
        }, schema), [])
    }
}
