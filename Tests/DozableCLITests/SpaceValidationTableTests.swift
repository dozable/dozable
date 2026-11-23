import DozableChat
import Foundation
import XCTest
@testable import DozableHost
@testable import DozableCLI

/// Every refusal of the space format (space/3): the reference's 68 rows (`Fixtures/space3/validation-errors.json`,
/// vendored with its PIN). Each row's files are written into a scratch folder — the space file as `space.yaml`, a
/// defaults file as `defaults.yaml` (extended from the space file's last line, so no earlier line moves), an override as
/// `space.override.yaml`, an `extends` row's own files — then read by `SpaceResolver` and checked by both passes, as the
/// CLI does. The row's problem must be there with its severity, pointer, message, hint, file and line, exactly.
final class SpaceValidationTableTests: XCTestCase {
    struct Row: Decodable {
        var n: Int
        var layer: String
        var severity: String
        var path: String
        var file: String?
        var line: Int
        var message: String
        var hint: String?
        var yaml: String
        var defaults: String?
        var override: String?
        var files: [String: String]?
    }

    static let fixtures = Pins.packageRoot.appendingPathComponent("Tests/DozableCLITests/Fixtures/space3")

    static func rows() throws -> [Row] {
        try JSONDecoder().decode([Row].self, from: Data(contentsOf: fixtures.appendingPathComponent("validation-errors.json")))
    }

    /// 758: Dozable's own vectors for space/3.1 (the reference's copy above is vendored read-only, at its PIN): the same
    /// row shape, through the same two passes. `Fixtures/space31/validation-errors-3.1.json`.
    static func rows31() throws -> [Row] {
        let f = Pins.packageRoot.appendingPathComponent("Tests/DozableCLITests/Fixtures/space31/validation-errors-3.1.json")
        return try JSONDecoder().decode([Row].self, from: Data(contentsOf: f))
    }

    func testEveryRowOfTheSpace31Vectors() throws {
        let rows = try Self.rows31()
        XCTAssertEqual(rows.count, 14)
        for r in rows {
            let (got, _) = try problems(r)
            guard let p = got.first(where: { $0.message == r.message }) else {
                XCTFail("3.1 #\(r.n): no \"\(r.message)\" — got:\n" + got.map { "  \($0.pointer) \($0.text)" }.joined(separator: "\n"))
                continue
            }
            XCTAssertEqual("\(p.severity) \(p.pointer) \(p.file):\(p.line) \(p.hint ?? "-")",
                           "\(r.severity) \(r.path) \(r.file ?? "space.yaml"):\(r.line) \(r.hint ?? "-")", "3.1 #\(r.n) \(r.message)")
            XCTAssertTrue(p.isError, "3.1 #\(r.n)")
        }
    }

    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("doz-space-table-\(UUID().uuidString.prefix(8))")
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    /// Writes a row's files into a fresh folder and returns what both passes say.
    func problems(_ r: Row) throws -> (problems: [SpaceProblem], folder: String) {
        let d = dir.appendingPathComponent("row\(r.n)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        func write(_ name: String, _ text: String) throws { try Data(text.utf8).write(to: d.appendingPathComponent(name)) }
        if let files = r.files {
            for (name, text) in files { try write(name, text) }
        } else {
            var space = r.yaml
            if let defaults = r.defaults {
                // "# defaults.yaml\n" names the file in the row; the file is what follows.
                let text = defaults.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).dropFirst().joined()
                try write("defaults.yaml", text)
                space += "extends: defaults.yaml\n"
            }
            try write("space.yaml", space)
            if let o = r.override { try write("space.override.yaml", o) }
        }
        var resolver = SpaceResolver()
        resolver.environment = [:]
        let resolved = resolver.resolve(d.appendingPathComponent("space.yaml").path)
        return (resolved.check().problems, d.standardizedFileURL.path)
    }

    func testEveryRowOfTheReference() throws {
        let rows = try Self.rows()
        XCTAssertEqual(rows.count, 68, "the reference's 68 cases")
        var passed = 0
        for r in rows {
            let (got, folder) = try problems(r)
            let hint = r.hint?.replacingOccurrences(of: "/s/", with: folder + "/")
            guard let p = got.first(where: { $0.message == r.message }) else {
                XCTFail("#\(r.n): no \"\(r.message)\" — got:\n" + got.map { "  \($0.pointer) \($0.text)" }.joined(separator: "\n"))
                continue
            }
            let want = "\(r.severity) \(r.path) \(r.file ?? "space.yaml"):\(r.line) \(hint ?? "-")"
            let have = "\(p.severity) \(p.pointer) \(p.file):\(p.line) \(p.hint ?? "-")"
            if want == have { passed += 1 } else { XCTFail("#\(r.n) \(r.message)\n  want \(want)\n  have \(have)") }
        }
        XCTAssertEqual(passed, 68)
    }

    /// The layers the table names: schema rows are found by the schema pass alone, rule rows only once the rules run.
    func testTheErrorsStopAndTheWarningsDoNot() throws {
        for r in try Self.rows() {
            let (got, _) = try problems(r)
            if r.severity == "warning" {
                XCTAssertFalse(got.contains { $0.isError }, "#\(r.n) is a warning alone: \(got.map(\.text))")
            } else {
                XCTAssertTrue(got.contains { $0.isError }, "#\(r.n)")
            }
        }
    }
}
