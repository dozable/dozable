import DozableChat
import Foundation
import XCTest
@testable import DozableHost
@testable import DozableCLI

/// `SpaceResolver`: the `extends:` chain, the override beside the file, `${VAR}`, the merge (maps merge, lists replace,
/// `null` removes), each place's origin, JSON-pointer escaping, picking the one file; and the reference's recorded `config`
/// outputs (`Fixtures/space3/fixtures-v3/*/config.txt`): the merged VALUES are the same, exactly.
final class SpaceResolverTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("doz-space-resolver-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func write(_ name: String, _ text: String) throws { try Data(text.utf8).write(to: dir.appendingPathComponent(name)) }

    func resolve(_ name: String = "t.space.yaml", env: [String: String] = [:]) -> SpaceResolver.Resolved {
        var r = SpaceResolver()
        r.environment = env
        return r.resolve(dir.appendingPathComponent(name).path)
    }

    static let head = "doz: space/3\nspace: t\nbrief: B.md\nowner: ada\n"

    func testMapsMergeListsReplaceAndNullRemoves() throws {
        try write("a.yaml", "doz: space-defaults/3\npersist:\n  one: { room: t }\n  two: { agent: \"*\" }\napprovals: { deciders: [owner, w], via: ask }\n")
        try write("t.space.yaml", Self.head + "extends: a.yaml\npersist:\n  two: null\napprovals: { deciders: [owner] }\nchat:\n  rooms:\n    t: {}\n")
        let r = resolve()
        XCTAssertFalse(r.broken)
        XCTAssertEqual(SpaceDoc.members(SpaceDoc.member(r.merged, "persist")).map(\.key), ["one"])
        XCTAssertEqual(SpaceDoc.strings(SpaceDoc.at(r.merged, "/approvals/deciders")), ["owner"])
        XCTAssertEqual(SpaceDoc.string(SpaceDoc.at(r.merged, "/approvals/via")), "ask", "a map merges: via stays")
        XCTAssertNil(SpaceDoc.member(r.merged, "extends"), "extends is resolved away")
        // Origins: inherited places name the defaults file, written ones the space file.
        XCTAssertEqual(r.locator.sourceOf("/persist/one"), "a.yaml:3")
        XCTAssertEqual(r.locator.sourceOf("/approvals/deciders"), "t.space.yaml:8")
        XCTAssertEqual(r.locator.sourceOf("/approvals/via"), "a.yaml:5")
        XCTAssertEqual(r.sources.map(\.kind), ["defaults", "space"])
        XCTAssertEqual(r.sources[1].sha256, SpaceDoc.sha256(try String(contentsOf: dir.appendingPathComponent("t.space.yaml"), encoding: .utf8)))
    }

    func testAChainAppliesEachFileAfterTheFilesItExtendsOnce() throws {
        try write("base.yaml", "doz: space-defaults/3\nagent_defaults: { model: a, permissions: standard }\n")
        try write("team.yaml", "doz: space-defaults/3\nextends: base.yaml\nagent_defaults: { model: b }\n")
        try write("t.space.yaml", Self.head + "extends: [base.yaml, team.yaml]\n")
        let r = resolve()
        XCTAssertEqual(r.sources.map(\.name), ["base.yaml", "team.yaml", "t.space.yaml"])
        XCTAssertEqual(SpaceDoc.string(SpaceDoc.at(r.merged, "/agent_defaults/model")), "b")
        XCTAssertEqual(SpaceDoc.string(SpaceDoc.at(r.merged, "/agent_defaults/permissions")), "standard")
    }

    func testTheOverrideBesideTheFile() throws {
        try write("t.space.yaml", Self.head + "title: from the file\n")
        try write("t.space.override.yaml", "title: from the override\n")
        let r = resolve()
        XCTAssertEqual(SpaceDoc.string(SpaceDoc.member(r.merged, "title")), "from the override")
        XCTAssertEqual(r.locator.sourceOf("/title"), "t.space.override.yaml:1")
        XCTAssertEqual(r.sources.map(\.kind), ["space", "override"])
    }

    func testVariablesFromTheEnvironmentAndTheDotEnvValuesOnly() throws {
        try write(".env", "# a comment\nTITLE=from env file\nexport PORT=4100\nQUOTED=\"a b\"\n")
        try write("t.space.yaml", Self.head + "title: \"${TITLE}\"\nlabels: { who: \"${WHO:-nobody}\", q: \"${QUOTED}\", cost: \"$$5\" }\n"
                  + "services:\n  s: { external: { url: \"http://127.0.0.1:${PORT}/\" }, ports: [\"${PORT}\"] }\n"
                  + "secrets:\n  k: { external: { file: \"${TOKEN}\" }, to: api.github.com }\n")
        let r = resolve(env: ["TITLE": "from the environment"])
        XCTAssertEqual(SpaceDoc.string(SpaceDoc.member(r.merged, "title")), "from the environment", "the environment wins over .env")
        XCTAssertEqual(SpaceDoc.string(SpaceDoc.at(r.merged, "/labels/who")), "nobody")
        XCTAssertEqual(SpaceDoc.string(SpaceDoc.at(r.merged, "/labels/q")), "a b")
        XCTAssertEqual(SpaceDoc.string(SpaceDoc.at(r.merged, "/labels/cost")), "$5")
        XCTAssertEqual(SpaceDoc.int(SpaceDoc.at(r.merged, "/services/s/ports/0")), 4100, "one ${VAR} alone takes its value's type")
        XCTAssertEqual(SpaceDoc.string(SpaceDoc.at(r.merged, "/secrets/k/external/file")), "${TOKEN}", "never under secrets")
        XCTAssertEqual(r.sources.map(\.kind), ["space", "env"])
        XCTAssertTrue(r.check().problems.contains { $0.message == "a secret can't use ${VAR}" })
    }

    func testAnUnquotedVariableInAFlowListSaysToQuoteIt() throws {
        try write("t.space.yaml", Self.head + "services:\n  s: { command: x, ports: [${PORT}] }\n")
        let r = resolve()
        XCTAssertTrue(r.broken)
        XCTAssertEqual(r.problems.first?.line, 6)
        XCTAssertTrue(r.problems.first?.hint?.contains("must be in quotes") == true, "\(r.problems)")
    }

    func testPointersEscapeSlashAndTilde() throws {
        try write("t.space.yaml", Self.head + "labels:\n  a/b: x\n  c~d: y\n")
        let r = resolve()
        XCTAssertEqual(r.locator.sourceOf("/labels/a~1b"), "t.space.yaml:6")
        XCTAssertEqual(r.locator.sourceOf("/labels/c~0d"), "t.space.yaml:7")
        XCTAssertEqual(SpaceDoc.string(SpaceDoc.at(r.merged, "/labels/a~1b")), "x")
    }

    func testYAML12ScalarsAndRefusedAnchors() throws {
        try write("t.space.yaml", Self.head + "archive: off\nlabels: { a: yes, b: \"true\", c: 012 }\n")
        let r = resolve()
        XCTAssertEqual(SpaceDoc.string(SpaceDoc.member(r.merged, "archive")), "off", "off is text, not false")
        XCTAssertEqual(SpaceDoc.string(SpaceDoc.at(r.merged, "/labels/a")), "yes")
        XCTAssertEqual(SpaceDoc.string(SpaceDoc.at(r.merged, "/labels/b")), "true")
        try write("t.space.yaml", Self.head + "labels: &l { a: x }\ntitle: *l\n")
        XCTAssertTrue(resolve().problems.contains { $0.message.contains("anchors and aliases are not allowed") })
        try write("t.space.yaml", Self.head + "title: a\ntitle: b\n")
        XCTAssertTrue(resolve().problems.contains { $0.hint == "a key is written twice in the same map" })
    }

    func testPickingTheOneFile() throws {
        XCTAssertThrowsError(try SpaceResolver.find(in: dir.path)) { XCTAssertTrue("\($0)".contains("no *.space.yaml")) }
        try write("a.space.yaml", Self.head)
        try write("a.space.override.yaml", "title: x\n")
        XCTAssertEqual(try SpaceResolver.find(in: dir.path), dir.appendingPathComponent("a.space.yaml").path)
        try write("b.space.yaml", Self.head)
        XCTAssertThrowsError(try SpaceResolver.find(in: dir.path)) { XCTAssertTrue("\($0)".contains("a.space.yaml, b.space.yaml")) }
        XCTAssertEqual(SpaceResolver.overridePath("/x/a.space.yaml"), "/x/a.space.override.yaml")
    }

    // MARK: the reference's recorded outputs

    static let recorded = SpaceValidationTableTests.fixtures.appendingPathComponent("fixtures-v3")
    static let spaces = ["example-space", "sandbox-team", "clean-room"]

    /// A recorded output's stdout, and its exit code.
    static func recordedOutput(_ space: String, _ command: String) throws -> (stdout: String, exit: Int) {
        let t = try String(contentsOf: recorded.appendingPathComponent("\(space)/\(command).txt"), encoding: .utf8)
        let stdout = t.components(separatedBy: "--- stdout\n")[1].components(separatedBy: "\n--- ")[0]
        let exit = Int(t.components(separatedBy: "--- exit ").last!.trimmingCharacters(in: .whitespacesAndNewlines))!
        return (stdout, exit)
    }

    func testTheMergedValuesAreTheReferencesConfig() throws {
        for s in Self.spaces {
            let (out, exit) = try Self.recordedOutput(s, "config")
            XCTAssertEqual(exit, 0)
            let body = out.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.hasPrefix("#") }.joined(separator: "\n")
            let (want, _, problems) = SpaceResolver.parse(body, name: "config.txt")
            XCTAssertEqual(problems, [])
            let r = SpaceResolver().resolve(Self.recorded.appendingPathComponent("spaces/\(s).space.yaml").path)
            XCTAssertEqual(r.merged, want, s)
            // The risky settings and their sources, line for line.
            let wantRisky = out.split(separator: "\n").filter { $0.hasPrefix("#   ") && $0.contains(": ") && !$0.contains("sha256") }
                .map { String($0.dropFirst(4)) }
            XCTAssertEqual(r.check().model?.risks.map(\.line), wantRisky, s)
            // The sources and their sha256.
            let shas = out.split(separator: "\n").filter { $0.contains("sha256 ") }.map { String($0.split(separator: " ").last!.dropLast()) }
            XCTAssertEqual(r.sources.map { String($0.sha256.prefix(16)) }, shas, s)
            // What config prints reads back as the same document.
            let printed = SpaceYAML.emit(r.merged, origins: r.origins, sources: r.sources)
            XCTAssertEqual(SpaceResolver.parse(printed, name: "printed").0, r.merged, s)
        }
    }
}
