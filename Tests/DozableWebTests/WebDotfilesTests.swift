import Foundation
import XCTest
@testable import DozableHost
import DozableKit
@testable import DozableWeb

/// 657: the dashboard and dotfiles — the Settings page sets a repository's URL, never a folder on the Mac (a host path);
/// a sandbox's dotfiles are projected field by field; the project wizard keeps the file's `dotfiles`.
final class WebDotfilesTests: XCTestCase {
    var xdg: URL!

    override func setUp() {
        xdg = FileManager.default.temporaryDirectory.appendingPathComponent("doz-webdotfiles-\(UUID().uuidString.prefix(8))")
    }
    override func tearDown() { try? FileManager.default.removeItem(at: xdg) }

    func testTheSettingsPageSetsAURLNeverAFolder() throws {
        let store = WebSettingsStore(environment: ["XDG_CONFIG_HOME": xdg.path])
        let body = { (v: String) in Data(#"{"key":"sandbox.dotfiles","value":"\#(v)"}"#.utf8) }
        let rep = try store.apply(try WebSettingChange.decode(body("https://github.com/you/dotfiles")))
        let row = try XCTUnwrap(rep.settings.first { $0.key == SettingKey.dotfiles })
        XCTAssertEqual(row.value, .string("https://github.com/you/dotfiles"))
        XCTAssertEqual(row.type, "dotfiles")
        XCTAssertTrue(row.editable)
        XCTAssertThrowsError(try store.apply(try WebSettingChange.decode(body("/Users/me/dotfiles")))) { e in
            XCTAssertTrue("\(e)".contains("set on the Mac"), "\(e)")
        }
        XCTAssertThrowsError(try store.apply(try WebSettingChange.decode(body("~/dotfiles"))))
        XCTAssertThrowsError(try store.apply(try WebSettingChange.decode(body("https://tok@github.com/you/dotfiles"))), "no credential in a URL")
        XCTAssertNoThrow(try store.apply(try WebSettingChange.decode(body(""))), "empty: none")
    }

    func testASandboxsDotfilesAreProjected() {
        var i = SandboxInfo(name: "s", image: "lab", phase: "off", busy: false, cpus: 1, memoryMiB: 512, ramHeldMiB: 0, memoryReturnedMiB: 0,
                            diskBytes: 0, sessions: nil, network: "bake", deniedConnections: nil, workspace: nil, createdAt: nil, diedWithHost: nil)
        XCTAssertNil(WebSandboxRow(i).dotfiles)
        i.dotfiles = DotfilesState(source: "/Users/me/dots", display: "~/dots", commit: String(repeating: "ab", count: 20), resolvedAt: Date(),
                                   state: "applied", method: "links", script: nil, summary: "3 linked", at: Date())
        let d = WebSandboxRow(i).dotfiles
        XCTAssertEqual(d?.source, "~/dots", "a folder shown with ~")
        XCTAssertEqual(d?.commit, "abababababab")
        XCTAssertEqual(d?.state, "applied")
        XCTAssertEqual(d?.summary, "3 linked")
    }

    func testTheWizardKeepsTheFilesDotfiles() throws {
        var p = DozableProject(name: "x", image: "lab")
        p.dotfiles = "https://github.com/you/dotfiles"
        let f = WebProjectForm(p)
        XCTAssertEqual(f.dotfiles, "https://github.com/you/dotfiles")
        XCTAssertEqual(try f.project().dotfiles, "https://github.com/you/dotfiles")
        var bad = f
        bad.dotfiles = "http://insecure.example/x"
        XCTAssertThrowsError(try bad.project())
    }
}
