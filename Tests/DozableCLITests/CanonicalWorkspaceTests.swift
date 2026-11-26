import DozableChat
import DozableKit
import Foundation
import XCTest
@testable import DozableHost
@testable import DozableCLI

/// `canonical/` is the one source of the workspace models (canonical/README.md): each model's folder holds
/// `NAME.workspace.yaml`, `INSTRUCTIONS.md` and `README.md`; the templates doz carries are generated from it
/// (`make templates`, `Scripts/canonical-templates.sh`) — this is the drift test that fails when a shipped template is not
/// exactly canonical/'s; every model that is not a template reads with no error; and `expected/picture.yaml` is exactly
/// what doz ui hands the renderer for that file (`DOZ_CANONICAL_WRITE=1` — `make canonical-expected` — writes it).
final class CanonicalWorkspaceTests: XCTestCase {
    static let canonical = Pins.packageRoot.appendingPathComponent("canonical")
    static let models = canonical.appendingPathComponent("workspace")
    static let shipped = Pins.packageRoot.appendingPathComponent("Sources/DozableKit/Resources/templates")

    static func text(_ u: URL) throws -> String { try String(contentsOf: u, encoding: .utf8) }
    static func templateIDs() throws -> [String] {
        try text(canonical.appendingPathComponent("TEMPLATES")).split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }
    static func modelNames() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: models.path).filter { !$0.hasPrefix(".") }.sorted()
    }

    func testEveryModelHasItsFiles() throws {
        let names = try Self.modelNames()
        XCTAssertEqual(Set(names), Set(try Self.templateIDs()).union(["app", "example-space", "sandbox-team", "clean-room"]),
                       "the models: the templates, the demo and the engine's shared examples")
        for n in names {
            let dir = Self.models.appendingPathComponent(n)
            for f in ["\(n).workspace.yaml", "INSTRUCTIONS.md", "README.md"] {
                XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(f).path), "\(n)/\(f)")
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(n).space.yaml").path), "\(n): the new name only")
            let lines = try Self.text(dir.appendingPathComponent("INSTRUCTIONS.md")).split(separator: "\n", omittingEmptySubsequences: false).count
            XCTAssertTrue((10...31).contains(lines), "\(n)/INSTRUCTIONS.md: 10–30 lines (\(lines))")
            XCTAssertTrue(try Self.text(dir.appendingPathComponent("README.md")).hasPrefix("# \(n)\n"), "\(n)/README.md")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: Self.canonical.appendingPathComponent("README.md").path))
    }

    /// The drift test: every shipped template file is canonical/'s, byte for byte, and nothing else is shipped.
    func testTheShippedTemplatesAreGeneratedFromCanonical() throws {
        let ids = try Self.templateIDs()
        let fix = "— edit canonical/, then make templates"
        XCTAssertEqual(try Self.text(Self.shipped.appendingPathComponent("ORDER")), try Self.text(Self.canonical.appendingPathComponent("TEMPLATES")), "ORDER \(fix)")
        let shippedIDs = try FileManager.default.contentsOfDirectory(atPath: Self.shipped.path).filter { $0 != "ORDER" && !$0.hasPrefix(".") }
        XCTAssertEqual(Set(shippedIDs), Set(ids), "the shipped templates are canonical/TEMPLATES \(fix)")
        for id in ids {
            let from = Self.models.appendingPathComponent(id), to = Self.shipped.appendingPathComponent(id)
            for (a, b) in [("\(id).workspace.yaml", "workspace.yaml"), ("template.json", "template.json"), ("DESCRIPTION.md", "DESCRIPTION.md")] {
                XCTAssertEqual(try Data(contentsOf: to.appendingPathComponent(b)), try Data(contentsOf: from.appendingPathComponent(a)),
                               "\(id)/\(b) differs from canonical/workspace/\(id)/\(a) \(fix)")
            }
            XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: to.path)), ["workspace.yaml", "template.json", "DESCRIPTION.md"], "\(id) \(fix)")
        }
        XCTAssertEqual(WorkspaceTemplates.list().map(\.id), ids, "what doz carries is canonical's, in its order")
    }

    /// Every model that is not a template (those have placeholders: WorkspaceTemplatesTests renders and reads them) reads
    /// with the CLI's resolver with no error — the file as named, its `extends:`, its own override.
    func testEveryOtherModelReads() throws {
        let templates = Set(try Self.templateIDs())
        for n in try Self.modelNames() where !templates.contains(n) {
            let file = Self.models.appendingPathComponent(n).appendingPathComponent("\(n).workspace.yaml").path
            var res = SpaceResolver()
            res.environment = [:]
            let r = res.resolve(file)
            XCTAssertFalse(r.broken, n)
            let (problems, model) = r.check()
            XCTAssertNotNil(model, "\(n): \(problems.map(\.text))")
            XCTAssertEqual(problems.filter(\.isError).map(\.text), [], n)
            XCTAssertEqual(r.spaceName, n, "\(n): the space is named as its folder")
        }
    }

    /// `expected/picture.yaml`: the document `doz ui` hands the vendored renderer for the file (`SpacePicture`, in the
    /// renderer's words) — for every model whose file needs one (Dozable's own keys: places, feeds). A model that needs none
    /// is drawn from its own text, and has no expected/ picture.
    func testTheExpectedPictures() throws {
        let write = ProcessInfo.processInfo.environment["DOZ_CANONICAL_WRITE"] == "1"
        let templates = Set(try Self.templateIDs())
        for n in try Self.modelNames() where !templates.contains(n) {
            let dir = Self.models.appendingPathComponent(n)
            let want = dir.appendingPathComponent("expected/picture.yaml")
            let got = SpaceDashboardPlan.picture(try Self.text(dir.appendingPathComponent("\(n).workspace.yaml")))
            if write {
                if let got {
                    try FileManager.default.createDirectory(at: want.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try Data(got.utf8).write(to: want)
                } else if FileManager.default.fileExists(atPath: want.path) {
                    try FileManager.default.removeItem(at: want)
                }
                continue
            }
            let have = try? Self.text(want)
            XCTAssertEqual(have, got, "\(n): expected/picture.yaml is not what doz ui draws — make canonical-expected, and commit")
        }
    }
}
