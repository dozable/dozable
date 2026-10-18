import Foundation
import XCTest
@testable import DozerHost

/// Dozable rename: the unset `defaults.projects_dir` is `~/doz-workspaces`, unless the Mac already has
/// `~/dozer-sandbox-workspaces` (then nobody moves). Home and the directory check are injected.
final class ProjectsDirDefaultTests: XCTestCase {
    func test_oldFolderPresentKeepsOld() {
        var asked: [String] = []
        let r = Workspace.unsetProjectsDir(home: "/Users/fake", isDirectory: { asked.append($0); return true })
        XCTAssertEqual(r, "~/dozer-sandbox-workspaces")
        XCTAssertEqual(asked, ["/Users/fake/dozer-sandbox-workspaces"])
    }

    func test_oldFolderAbsentIsNew() {
        XCTAssertEqual(Workspace.unsetProjectsDir(home: "/Users/fake", isDirectory: { _ in false }), "~/doz-workspaces")
    }

    func test_settingsResolveTheEffectiveDefaultAndExplicitWins() {
        let old = DozerSettings(text: nil, unsetProjectsDir: Workspace.unsetProjectsDir(home: "/Users/fake", isDirectory: { _ in true }))
        XCTAssertEqual(old.string(SettingKey.projectsDir), "~/dozer-sandbox-workspaces")
        let new = DozerSettings(text: nil, unsetProjectsDir: Workspace.unsetProjectsDir(home: "/Users/fake", isDirectory: { _ in false }))
        XCTAssertEqual(new.string(SettingKey.projectsDir), "~/doz-workspaces")
        // The documented default is the new one either way.
        XCTAssertEqual(DozerSettings.definition(SettingKey.projectsDir)?.defaultValue, .string("~/doz-workspaces"))
        // An explicit setting wins over both.
        let set = DozerSettings(text: "[defaults]\nprojects_dir = \"/private/tmp/mine\"\n", unsetProjectsDir: "~/dozer-sandbox-workspaces")
        XCTAssertEqual(set.string(SettingKey.projectsDir), "/private/tmp/mine")
        XCTAssertEqual(Workspace.defaultPath(name: "x", settings: set), "/private/tmp/mine/x")
        // "" (automatic) means the effective default.
        let auto = DozerSettings(text: "[defaults]\nprojects_dir = \"\"\n", unsetProjectsDir: "~/doz-workspaces")
        XCTAssertTrue(Workspace.defaultPath(name: "x", settings: auto).hasSuffix("/doz-workspaces/x"))
    }
}
