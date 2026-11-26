import DozableChat
import Foundation
import XCTest
@testable import DozableHost
@testable import DozableCLI

/// The workspace drawn from a file that uses Dozable's newer keys (`x-dozable.places` with `where: PLACE`, `x-dozable.feeds`),
/// which the vendored renderer's own reader does not know: `SpacePicture` hands it the same document in its words — a vm place
/// as a sandbox, a fenced place's agents on this Mac fenced, places and feeds left out — and a file without them is drawn from
/// its own text. The renderer itself is exercised by `make dashboard-walk` (the "pictures" rows, a workspace with places).
/// The canonical demo file is `canonical/workspace/app/app.workspace.yaml` (canonical/README.md).
final class SpacePictureTests: XCTestCase {
    static let canonicalDir = Pins.packageRoot.appendingPathComponent("canonical/workspace/app")
    static func canonical() throws -> String { try String(contentsOf: canonicalDir.appendingPathComponent("app.workspace.yaml"), encoding: .utf8) }

    func doc(_ text: String) throws -> JValue { try XCTUnwrap(SpaceResolver.parse(text, name: "t.space.yaml").0) }

    func testTheCanonicalFileIsDrawnWithItsPlacesAsTheRendererKnowsThem() throws {
        let d = try XCTUnwrap(SpacePicture.document(try doc(try Self.canonical())))
        // The vm place is a sandbox of its name, sized as the place; its agents run in it.
        XCTAssertEqual(SpaceDoc.members(SpaceDoc.member(d, "sandboxes")).map(\.key), ["build"])
        XCTAssertEqual(SpaceDoc.string(SpaceDoc.at(d, "/sandboxes/build/image")), "claude-code")
        XCTAssertEqual(SpaceDoc.int(SpaceDoc.at(d, "/sandboxes/build/cpus")), 4)
        XCTAssertEqual(SpaceDoc.string(SpaceDoc.at(d, "/sandboxes/build/memory")), "8G")
        for a in ["builder", "tester"] { XCTAssertEqual(SpaceDoc.string(SpaceDoc.at(d, "/agents/\(a)/where")), "sandbox:build", a) }
        // The fenced place is this Mac, each of its agents fenced.
        for a in ["reviewer", "helper"] {
            XCTAssertEqual(SpaceDoc.string(SpaceDoc.at(d, "/agents/\(a)/where")), "mac", a)
            XCTAssertEqual(SpaceDoc.string(SpaceDoc.at(d, "/agents/\(a)/isolation")), "fenced", a)
        }
        // Places and feeds are left out; everything else of x-dozable stays (the renderer reads lifetime and permissions).
        XCTAssertEqual(SpaceDoc.members(SpaceDozable.of(d)).map(\.key), ["lifetime", "permissions"])
        XCTAssertNotNil(SpaceDoc.at(d, "/x-editor/layout/build"), "the layout pins are kept: the sandbox has the place's name")
        XCTAssertEqual(SpaceDoc.string(SpaceDoc.at(d, "/network/preset")), "standard")
        // The text: the version line first, as the renderer looks for it, and the same document read back.
        let t = SpacePicture.text(d)
        XCTAssertTrue(t.hasPrefix("doz: space/3.1\n"), t)
        XCTAssertEqual(try doc(t), d, "the picture's text reads as the translated document")
        XCTAssertEqual(SpaceDashboardPlan.picture(try Self.canonical()), t, "doz ui's reader: the file read, translated, written")
    }

    func testAFileWithoutPlacesOrFeedsIsDrawnFromItsOwnText() throws {
        let plain = "doz: space/3.1\nspace: t\nowner: ada\nbrief: { text: x }\nx-dozable: { lifetime: standing, permissions: { w: [reviewer] } }\n"
        XCTAssertNil(SpacePicture.document(try doc(plain)))
        XCTAssertNil(SpaceDashboardPlan.picture(plain))
        XCTAssertNil(SpaceDashboardPlan.picture("doz: space/3.1\n  : [unclosed"), "a file that does not read: the renderer says why, from its text")
    }

    func testFeedsAloneAreLeftOutAndAnEmptyXDozableGoes() throws {
        let d = try XCTUnwrap(SpacePicture.document(try doc("doz: space/3.1\nspace: t\nx-dozable: { feeds: { journal: { to: room } } }\n")))
        XCTAssertNil(SpaceDozable.of(d))
        XCTAssertNil(SpaceDoc.member(d, "sandboxes"))
    }

    func testEveryKindOfPlace() throws {
        let text = """
        doz: space/3.1
        space: t
        agent_defaults: { where: desk }
        sandboxes:
          box: { image: lab }
        agents:
          a: { kind: claude-code, where: vm1 }
          b: { kind: claude-code, where: old }
          c: { kind: claude-code, where: me }
          d: { kind: claude-code, where: desk, isolation: fenced }
          e: { kind: claude-code, where: mac }
          f: { kind: claude-code, where: sandbox:box }
        x-dozable:
          places:
            vm1: { isolation: vm }
            old: { external: { sandbox: old-review } }
            me: { isolation: unfenced }
            desk: { isolation: fenced, view: { notes: ro } }
        """
        let d = try XCTUnwrap(SpacePicture.document(try doc(text)))
        XCTAssertEqual(SpaceDoc.members(SpaceDoc.member(d, "sandboxes")).map(\.key), ["box", "vm1", "old"], "the file's sandboxes first, then each vm place")
        XCTAssertEqual(SpaceDoc.members(SpaceDoc.at(d, "/sandboxes/vm1")).count, 0)
        XCTAssertEqual(SpaceDoc.string(SpaceDoc.at(d, "/sandboxes/old/external")), "old-review", "an external place is the sandbox it names")
        XCTAssertEqual(SpaceDoc.string(SpaceDoc.at(d, "/agents/a/where")), "sandbox:vm1")
        XCTAssertEqual(SpaceDoc.string(SpaceDoc.at(d, "/agents/b/where")), "sandbox:old")
        XCTAssertEqual(SpaceDoc.string(SpaceDoc.at(d, "/agents/c/where")), "mac")
        XCTAssertEqual(SpaceDoc.string(SpaceDoc.at(d, "/agents/c/isolation")), "unfenced")
        XCTAssertEqual(SpaceDoc.members(SpaceDoc.at(d, "/agents/d")).filter { $0.key == "isolation" }.count, 1, "an isolation written stays, once")
        XCTAssertEqual(SpaceDoc.string(SpaceDoc.at(d, "/agents/e/where")), "mac", "mac and sandbox:NAME are left as they are")
        XCTAssertNil(SpaceDoc.at(d, "/agents/e/isolation"))
        XCTAssertEqual(SpaceDoc.string(SpaceDoc.at(d, "/agents/f/where")), "sandbox:box")
        XCTAssertEqual(SpaceDoc.string(SpaceDoc.at(d, "/agent_defaults/where")), "mac")
        XCTAssertEqual(SpaceDoc.string(SpaceDoc.at(d, "/agent_defaults/isolation")), "fenced")
    }
}
