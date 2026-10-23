import ArgumentParser
import Foundation
import XCTest
@testable import DozableCLI
@testable import DozableHost

/// 646: the editors `doz files open --app` takes — the known list, the test seam (never the Mac's LaunchServices), how
/// `--app` matches, `bridges.open_apps`, the refusals; and the CLI's parse.
final class EditorAppsTests: XCTestCase {
    private let seam = [EditorApps.testSeam: "cursor, VSCode,nope"]

    func testTheKnownListIsWellFormed() {
        let ids = EditorApps.known.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "ids are unique")
        XCTAssertEqual(EditorApps.known.map(\.name).count, Set(EditorApps.known.map(\.name)).count, "names are unique")
        for k in EditorApps.known {
            XCTAssertTrue(WorkspaceFiles.isAppName(k.id) && WorkspaceFiles.isAppName(k.name), k.id)
            XCTAssertEqual(k.id, k.id.lowercased(), "an id is lower case")
            XCTAssertFalse(k.bundleIDs.isEmpty, k.id)
        }
        XCTAssertEqual(EditorApps.match("CURSOR")?.id, "cursor")
        XCTAssertEqual(EditorApps.match("visual studio code")?.id, "vscode")
        XCTAssertNil(EditorApps.match("Safari"))
    }

    func testTheSeamSaysWhatIsInstalledAndNeverALaunchablePath() {
        let list = EditorApps.installed(openApps: ["Typora", "cursor", "Visual Studio Code"], environment: seam)
        XCTAssertEqual(list, [EditorApps.Editor(id: "vscode", name: "Visual Studio Code"), EditorApps.Editor(id: "cursor", name: "Cursor"),
                              EditorApps.Editor(id: "Typora", name: "Typora")], "known ones in the list's order, then open_apps not already there")
        let path = EditorApps.installedPath(EditorApps.match("cursor")!, environment: seam)
        XCTAssertNotNil(path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path ?? "/"), "a seam path cannot launch anything")
        XCTAssertNil(EditorApps.installedPath(EditorApps.match("zed")!, environment: seam))
        XCTAssertEqual(EditorApps.installed(openApps: [], environment: [EditorApps.testSeam: ""]), [])
    }

    func testAppResolvesToAnInstalledEditorOrAListedApp() {
        func r(_ a: String, _ apps: [String] = []) -> Result<EditorApps.Resolved, WorkspaceFiles.Refusal> {
            EditorApps.resolve(a, openApps: apps, environment: seam)
        }
        XCTAssertEqual(try r("Cursor").get().name, "Cursor")
        XCTAssertTrue(try r("cursor").get().target.hasSuffix("/Cursor.app"), "a known editor opens by its resolved path")
        XCTAssertEqual(try r("typora", ["Typora"]).get(), EditorApps.Resolved(name: "Typora", target: "Typora"), "the listed spelling")
        XCTAssertEqual(try r("zed", ["Zed"]).get().target, "Zed", "not installed, but listed: the listed name")
        XCTAssertThrowsError(try r("zed").get()) { XCTAssertEqual(($0 as? WorkspaceFiles.Refusal)?.message, "Zed is not installed on this Mac") }
        XCTAssertThrowsError(try r("Safari").get()) {
            XCTAssertTrue(($0 as? WorkspaceFiles.Refusal)?.message.contains("not a known editor or in bridges.open_apps") == true)
        }
        for bad in ["", "-a", ".hidden", "/Applications/Evil.app", "a;b", "a\u{1}b"] {
            XCTAssertThrowsError(try r(bad, [bad]).get(), bad)
        }
    }

    func testTheCLIParsesAppAndEditors() throws {
        let c = try XCTUnwrap(try DozableCommand.parseAsRoot(["files", "open", "my-app", "--app", "Visual Studio Code"]) as? FilesOpen)
        XCTAssertEqual(c.name, "my-app")
        XCTAssertNil(c.path)
        XCTAssertEqual(c.app, "Visual Studio Code")
        let d = try XCTUnwrap(try DozableCommand.parseAsRoot(["files", "open", "my-app", "src/main.swift", "--app", "cursor"]) as? FilesOpen)
        XCTAssertEqual(d.path, "src/main.swift")
        XCTAssertTrue(try DozableCommand.parseAsRoot(["files", "editors", "--json"]) is FilesEditors)
        XCTAssertTrue(FilesOpen.configuration.discussion.contains("cursor"), "the help names the known editors")
        XCTAssertTrue(FilesEditors.render([]).contains("bridges.open_apps"))
        XCTAssertTrue(FilesEditors.render([EditorApps.Editor(id: "zed", name: "Zed")]).contains("zed"))
    }
}
