import Foundation
import XCTest
@testable import DozableHost

/// 0.37 (no migration): the unset `defaults.projects_dir` is `~/doz-workspaces` — an earlier version's
/// `~/dozer-sandbox-workspaces` is never looked for.
final class ProjectsDirDefaultTests: XCTestCase {
    func test_theUnsetDefaultIsAlwaysTheNewFolder() {
        XCTAssertEqual(Workspace.unsetProjectsDir(), "~/doz-workspaces")
    }

    func test_settingsResolveTheEffectiveDefaultAndExplicitWins() {
        let new = DozableSettings(text: nil, unsetProjectsDir: Workspace.unsetProjectsDir())
        XCTAssertEqual(new.string(SettingKey.projectsDir), "~/doz-workspaces")
        // The documented default is the same.
        XCTAssertEqual(DozableSettings.definition(SettingKey.projectsDir)?.defaultValue, .string("~/doz-workspaces"))
        // An explicit setting wins.
        let set = DozableSettings(text: "[defaults]\nprojects_dir = \"/private/tmp/mine\"\n", unsetProjectsDir: "~/elsewhere")
        XCTAssertEqual(set.string(SettingKey.projectsDir), "/private/tmp/mine")
        XCTAssertEqual(Workspace.defaultPath(name: "x", settings: set), "/private/tmp/mine/x")
        // "" (automatic) means the effective default.
        let auto = DozableSettings(text: "[defaults]\nprojects_dir = \"\"\n", unsetProjectsDir: "~/doz-workspaces")
        XCTAssertTrue(Workspace.defaultPath(name: "x", settings: auto).hasSuffix("/doz-workspaces/x"))
    }
}
