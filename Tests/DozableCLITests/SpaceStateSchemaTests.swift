import Foundation
import XCTest
@testable import DozableHost

/// The editor's SpaceState schema (`Fixtures/space-state/space-state-1.schema.json`, PIN), checked by a validator written
/// for exactly the keywords it uses — the test first asserts it uses no other, so a schema that grows one fails here
/// rather than passing unchecked. Every fixture passes; `SpaceStateTests.testEveryBuiltDocumentPassesTheSchema` runs the
/// builder's documents through the same validator; a document with a field the schema does not name, a wrong state for its
/// type or Ask fields on another kind fails.
final class SpaceStateSchemaTests: XCTestCase {
    static let keywords: Set<String> = ["$schema", "$id", "$defs", "$ref", "title", "description", "type", "additionalProperties", "required",
                                        "properties", "const", "enum", "items", "pattern", "minLength", "maxLength", "allOf", "anyOf", "if",
                                        "then", "else", "not"]

    static func schema() throws -> [String: Any] {
        let d = try Data(contentsOf: SpaceStateTests.fixtures.appendingPathComponent("space-state-1.schema.json"))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: d) as? [String: Any])
    }

    /// Every keyword the schema uses, at every level (property and definition names are not keywords).
    static func usedKeywords(_ s: Any) -> Set<String> {
        guard let o = s as? [String: Any] else { return [] }
        var out = Set(o.keys)
        for (k, v) in o {
            switch k {
            case "properties", "$defs": for sub in (v as? [String: Any] ?? [:]).values { out.formUnion(usedKeywords(sub)) }
            case "allOf", "anyOf": for sub in v as? [Any] ?? [] { out.formUnion(usedKeywords(sub)) }
            case "items", "if", "then", "else", "not", "additionalProperties": out.formUnion(usedKeywords(v))
            default: break
            }
        }
        return out
    }

    // MARK: the validator: exactly these keywords

    static func isBool(_ v: Any) -> Bool { (v as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false }

    static func same(_ a: Any, _ b: Any) -> Bool {
        if isBool(a) != isBool(b) { return false }
        return (a as? NSObject)?.isEqual(b) ?? false
    }

    static func validate(_ v: Any, _ root: [String: Any]) -> [String] {
        var errors: [String] = []
        check(v, root, root, "", &errors)
        return errors
    }

    static func check(_ v: Any, _ s: [String: Any], _ root: [String: Any], _ at: String, _ errors: inout [String]) {
        func fail(_ m: String) { errors.append("\(at.isEmpty ? "/" : at): \(m)") }
        func valid(_ sub: Any) -> Bool {
            var e: [String] = []
            check(v, sub as? [String: Any] ?? [:], root, at, &e)
            return e.isEmpty
        }
        if let ref = s["$ref"] as? String {
            let name = ref.replacingOccurrences(of: "#/$defs/", with: "")
            guard let sub = (root["$defs"] as? [String: Any])?[name] as? [String: Any] else { return fail("no definition \(ref)") }
            check(v, sub, root, at, &errors)
        }
        if let t = s["type"] as? String {
            let ok: Bool
            switch t {
            case "object": ok = v is [String: Any]
            case "array": ok = v is [Any]
            case "string": ok = v is String
            case "boolean": ok = isBool(v)
            case "integer": ok = !isBool(v) && (v as? NSNumber).map { $0.doubleValue == $0.doubleValue.rounded() } == true
            case "number": ok = !isBool(v) && v is NSNumber
            default: ok = false
            }
            if !ok { fail("not of type \(t)") }
        }
        if let c = s["const"], !same(v, c) { fail("not \(c)") }
        if let e = s["enum"] as? [Any], !e.contains(where: { same(v, $0) }) { fail("not one of \(e)") }
        if let str = v as? String {
            let n = str.utf16.count
            if let m = s["minLength"] as? Int, n < m { fail("shorter than \(m)") }
            if let m = s["maxLength"] as? Int, n > m { fail("longer than \(m)") }
            if let p = s["pattern"] as? String, str.range(of: p, options: .regularExpression) == nil { fail("does not match \(p)") }
        }
        if let o = v as? [String: Any] {
            let props = s["properties"] as? [String: Any] ?? [:]
            for r in s["required"] as? [String] ?? [] where o[r] == nil { fail("\(r) is required") }
            for (k, x) in o {
                if let sub = props[k] as? [String: Any] { check(x, sub, root, at + "/" + k, &errors) }
                else if let ap = s["additionalProperties"] {
                    if isBool(ap), (ap as? Bool) == false { fail("\(k) is not allowed") }
                    else if let sub = ap as? [String: Any] { check(x, sub, root, at + "/" + k, &errors) }
                }
            }
        }
        if let a = v as? [Any], let items = s["items"] as? [String: Any] {
            for (i, x) in a.enumerated() { check(x, items, root, at + "/\(i)", &errors) }
        }
        for sub in s["allOf"] as? [Any] ?? [] { check(v, sub as? [String: Any] ?? [:], root, at, &errors) }
        if let any = s["anyOf"] as? [Any], !any.contains(where: valid) { fail("none of anyOf") }
        if let n = s["not"], valid(n) { fail("matches what not forbids") }
        if let i = s["if"] {
            if valid(i) { if let t = s["then"] as? [String: Any] { check(v, t, root, at, &errors) } }
            else if let e = s["else"] as? [String: Any] { check(v, e, root, at, &errors) }
        }
    }

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
