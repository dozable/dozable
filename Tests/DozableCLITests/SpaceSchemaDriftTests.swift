import Foundation
import XCTest
@testable import DozableHost

/// The hand-written validator's tables against the reference's JSON Schemas (vendored, `Fixtures/space3/schema/`, PIN):
/// every object's property set, every enum, const and pattern. A change of the format upstream fails here first; the
/// table of refusals (`SpaceValidationTableTests`) then says whether the words still hold.
final class SpaceSchemaDriftTests: XCTestCase {
    typealias Obj = [String: Any]
    static let dir = SpaceValidationTableTests.fixtures.appendingPathComponent("schema")

    func load(_ name: String) throws -> Obj {
        try JSONSerialization.jsonObject(with: Data(contentsOf: Self.dir.appendingPathComponent(name))) as! Obj
    }

    func keys(_ o: Any?) -> [String] { ((o as? Obj)?["properties"] as? Obj).map { Array($0.keys).sorted() } ?? [] }
    func props(_ o: Any?) -> Obj { (o as? Obj)?["properties"] as? Obj ?? [:] }
    func enumOf(_ o: Any?) -> [String] { (o as? Obj)?["enum"] as? [String] ?? [] }
    func pattern(_ o: Any?) -> String? { (o as? Obj)?["pattern"] as? String }
    func sorted(_ a: [String]) -> [String] { a.sorted() }

    func testTheSpaceSchemaMatchesTheTables() throws {
        let s = try load("space-3.schema.json")
        let defs = s["$defs"] as! Obj
        XCTAssertEqual(Set(defs.keys), ["agent", "agentSettings", "agent_defaults", "approvals", "archive", "extends", "folder", "labels",
                                         "name", "persist", "persistEntry", "preset", "profiles", "room", "sandbox", "secret", "service"],
                       "a new definition: give it a table and a check")
        XCTAssertEqual(Array((s["properties"] as! Obj).keys).sorted(), sorted(SpaceFormat.topKeys))
        XCTAssertEqual(s["required"] as? [String], SpaceFormat.requiredTop)
        XCTAssertEqual((props(s)["doz"] as? Obj)?["const"] as? String, SpaceFormat.doz)
        XCTAssertEqual(keys(props(s)["chat"]), sorted(SpaceFormat.chatKeys))

        XCTAssertEqual(keys(defs["agent"]), sorted(SpaceFormat.agentOwnKeys))
        XCTAssertEqual(keys(defs["agentSettings"]), sorted(SpaceFormat.agentSettingsKeys))
        let agentDep = (((defs["agent"] as! Obj)["dependentSchemas"] as! Obj)["external"] as! Obj)
        XCTAssertEqual(keys(agentDep), sorted(SpaceFormat.agentExternalForbidden))
        XCTAssertEqual(keys(defs["agent_defaults"]), sorted(SpaceFormat.agentDefaultsOwnKeys))
        XCTAssertEqual(enumOf(props(defs["agent_defaults"])["isolation"]), ["fenced"])
        let requests = props(defs["agent"])["requests"]
        XCTAssertEqual(keys(requests), sorted(SpaceFormat.requestsKeys))
        XCTAssertEqual((requests as? Obj)?["required"] as? [String], ["reason"])
        let settings = props(defs["agentSettings"])
        XCTAssertEqual(keys(settings["chat"]), sorted(SpaceFormat.agentChatKeys))
        XCTAssertEqual(enumOf(settings["kind"]), SpaceFormat.kinds)
        XCTAssertEqual(enumOf(settings["role"]), SpaceFormat.roles)
        XCTAssertEqual(enumOf(settings["isolation"]), SpaceFormat.isolations)
        XCTAssertEqual(enumOf(settings["access"]), SpaceFormat.accesses)
        XCTAssertEqual(enumOf(settings["transcripts"]), SpaceFormat.transcripts)
        XCTAssertEqual(enumOf(settings["resume"]), SpaceFormat.resumes)
        XCTAssertEqual(enumOf(props(settings["chat"])["delivery"]), SpaceFormat.deliveries)
        XCTAssertEqual(pattern(settings["where"]), SpaceFormat.patterns["where"])

        XCTAssertEqual(keys(defs["approvals"]), sorted(SpaceFormat.approvalsKeys))
        XCTAssertEqual(enumOf(props(defs["approvals"])["via"]), SpaceFormat.vias)
        let archive = (defs["archive"] as! Obj)["anyOf"] as! [Obj]
        XCTAssertEqual(archive[0]["const"] as? String, "off")
        XCTAssertEqual(keys(archive[1]), sorted(SpaceFormat.archiveKeys))
        XCTAssertEqual(enumOf((props(archive[1])["keep"] as? Obj)?["items"]), SpaceFormat.archiveKeep)

        XCTAssertEqual(keys(defs["folder"]), sorted(SpaceFormat.folderKeys))
        XCTAssertEqual(enumOf(props(defs["folder"])["trust"]), SpaceFormat.trusts)
        XCTAssertEqual(keys(defs["room"]), sorted(SpaceFormat.roomKeys))
        XCTAssertEqual(keys(defs["sandbox"]), sorted(SpaceFormat.sandboxKeys))
        XCTAssertEqual(keys(((defs["sandbox"] as! Obj)["dependentSchemas"] as! Obj)["external"]), sorted(SpaceFormat.sandboxExternalForbidden))
        XCTAssertEqual(pattern(props(defs["sandbox"])["memory"]), SpaceFormat.patterns["memory"])
        XCTAssertEqual(keys(defs["secret"]), sorted(SpaceFormat.secretKeys))
        XCTAssertEqual((defs["secret"] as! Obj)["required"] as? [String], SpaceFormat.secretRequired)
        XCTAssertEqual(pattern(props(defs["secret"])["to"]), SpaceFormat.patterns["to"])
        XCTAssertEqual(keys(defs["service"]), sorted(SpaceFormat.serviceKeys))
        XCTAssertEqual(keys(((defs["service"] as! Obj)["dependentSchemas"] as! Obj)["external"]), sorted(SpaceFormat.serviceExternalForbidden))
        XCTAssertEqual(keys(props(defs["service"])["health"]), sorted(SpaceFormat.healthKeys))
        XCTAssertEqual(pattern(props(props(defs["service"])["health"])["http"]), SpaceFormat.patterns["url"])
        XCTAssertEqual(keys(defs["persistEntry"]), sorted(SpaceFormat.persistKinds))
        XCTAssertEqual(pattern(defs["name"]), SpaceFormat.patterns["name"])

        // The externals' full-name patterns, and every section's name rule.
        func anyOfPatterns(_ def: String) -> [String] {
            ((props(defs[def])["external"] as? Obj)?["anyOf"] as? [Obj] ?? []).compactMap { $0["pattern"] as? String }
        }
        XCTAssertEqual(anyOfPatterns("agent"), [SpaceFormat.patterns["agentExternal"]!])
        XCTAssertEqual(anyOfPatterns("room"), [SpaceFormat.patterns["roomExternal"]!])
        XCTAssertEqual(anyOfPatterns("sandbox"), [SpaceFormat.patterns["sandboxExternal"]!])
        XCTAssertEqual(anyOfPatterns("service"), [SpaceFormat.patterns["serviceExternal"]!])
        for section in ["folders", "agents", "services", "sandboxes", "secrets"] {
            XCTAssertEqual(((props(s)[section] as? Obj)?["propertyNames"] as? Obj)?["pattern"] as? String, SpaceFormat.patterns["sectionName"], section)
        }
        XCTAssertEqual(((props(props(s)["chat"])["rooms"] as? Obj)?["propertyNames"] as? Obj)?["pattern"] as? String, SpaceFormat.patterns["sectionName"])
        XCTAssertEqual(((defs["persist"] as? Obj)?["propertyNames"] as? Obj)?["pattern"] as? String, SpaceFormat.patterns["sectionName"])
        XCTAssertEqual(pattern(((defs["profiles"] as? Obj)?["items"])), SpaceFormat.patterns["name"])
    }

    func testTheDefaultsSchemaMatchesTheTables() throws {
        let d = try load("space-defaults-3.schema.json")
        XCTAssertEqual(Array((d["properties"] as! Obj).keys).sorted(), sorted(SpaceFormat.defaultsKeys))
        XCTAssertEqual((props(d)["doz"] as? Obj)?["const"] as? String, SpaceFormat.defaultsDoz)
        XCTAssertEqual(d["required"] as? [String], ["doz"])
        let defs = d["$defs"] as! Obj
        XCTAssertEqual(keys(defs["agentSettings"]), sorted(SpaceFormat.agentSettingsKeys))
        XCTAssertEqual(enumOf(props(defs["agent_defaults"])["isolation"]), ["fenced"])
        // What a defaults file may hold is what the space file holds under the same names.
        let space = try load("space-3.schema.json")["$defs"] as! Obj
        for k in ["persist", "persistEntry", "approvals", "agentSettings", "labels", "profiles", "preset", "extends"] {
            XCTAssertEqual(keys(defs[k]), keys(space[k]), k)
        }
    }

    /// The PIN names the reference's commit and every vendored file's sha256.
    func testThePinCoversEveryVendoredFile() throws {
        let root = SpaceValidationTableTests.fixtures
        let pin = try String(contentsOf: root.appendingPathComponent("PIN"), encoding: .utf8)
        XCTAssertTrue(pin.contains("peer-commit "))
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!.compactMap { $0 as? URL }
            .filter { !$0.hasDirectoryPath && $0.lastPathComponent != "PIN" }
        XCTAssertGreaterThan(files.count, 20)
        for f in files {
            let rel = "./" + f.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1)
            let sha = SpaceDoc.sha256(try String(contentsOf: f, encoding: .utf8))
            XCTAssertTrue(pin.contains("\(sha)  \(rel)"), "\(rel) changed since it was pinned")
        }
    }
}
