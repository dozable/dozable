import XCTest
@testable import DozableMenuBarCore

/// The app's reading of `doz daemon status --json`: every shape doz prints, read with the app's own all-optional types.
final class StatusModelTests: XCTestCase {
    func testNoDaemon() {
        let s = Fixture.status(Fixture.noDaemon)
        XCTAssertFalse(s.isRunning)
        XCTAssertEqual(s.store, "/tmp/dzo-cap/store")
        XCTAssertEqual(s.held, false)
        XCTAssertEqual(s.alwaysOn, true)
        XCTAssertEqual(s.loginItem?.owner, "none")
        XCTAssertEqual(s.loginItem?.installed, false)
        XCTAssertNil(s.version)
    }

    func testRunningHasNoRunningKeyButAPid() {
        let s = Fixture.status(Fixture.running)
        XCTAssertNil(s.running, "the daemon's own status carries no running key")
        XCTAssertTrue(s.isRunning)
        XCTAssertEqual(s.pid, 16586)
        XCTAssertEqual(s.version, "0.50.6")
        XCTAssertEqual(s.parentPid, 1)
        XCTAssertEqual(s.liveSandboxes, [])
        XCTAssertNil(s.keychainLocked)
        XCTAssertNil(s.executableChange)
    }

    func testLockedHeldAndExecutableChange() {
        XCTAssertEqual(Fixture.runningWith { $0["keychainLocked"] = "ssh" }.keychainLocked, "ssh")
        let changed = Fixture.runningWith { $0["executableChange"] = "replaced"; $0["executableNote"] = "its program was replaced" }
        XCTAssertEqual(changed.executableChange, "replaced")
        XCTAssertEqual(Fixture.noDaemonWith { $0["held"] = true }.held, true)
    }

    func testLoginItemOwners() {
        for owner in ["doz", "app", "none"] {
            let s = Fixture.noDaemonWith { o in
                var li = o["loginItem"] as! [String: Any]; li["owner"] = owner; li["installed"] = owner == "doz"; o["loginItem"] = li
            }
            XCTAssertEqual(s.loginItem?.owner, owner)
        }
    }

    func testAnOlderDozsShape() {
        let s = Fixture.status(Fixture.oldNoDaemon)
        XCTAssertFalse(s.isRunning)
        XCTAssertNil(s.held)
        XCTAssertNil(s.alwaysOn)
        XCTAssertNil(s.loginItem)
        XCTAssertNil(s.store)
    }

    func testUnknownFieldsAreIgnoredAndKnownOnesOfAnotherTypeDoNotBreakIt() {
        let s = Fixture.runningWith { $0["somethingNew"] = ["a": [1, 2, 3]]; $0["keepers"] = 3 }
        XCTAssertTrue(s.isRunning)
        XCTAssertEqual(s.version, "0.50.6")
    }

    func testWhatIsNotAStatusIsNotReadAsOne() {
        XCTAssertNil(DozStatus.decode(Data(#"{"error":{"code":"unavailable","message":"x"}}"#.utf8)))
        XCTAssertNil(DozStatus.decode(Data("{}".utf8)))
        XCTAssertNil(DozStatus.decode(Data("not json".utf8)))
        XCTAssertNil(DozStatus.decode(Data()))
    }

    func testAppStatus() {
        let a = DozAppStatus.decode(Data(#"{"bundled":{"path":"/x/Dozable.app","version":"0.51.0"},"installed":[{"path":"/Applications/Dozable.app","version":"0.50.7"}],"other":1}"#.utf8))
        XCTAssertEqual(a?.bundled?.version, "0.51.0")
        XCTAssertEqual(a?.installed?.first?.version, "0.50.7")
        XCTAssertEqual(DozAppStatus.decode(Data(#"{"bundled":null}"#.utf8))?.bundled, nil)
    }
}
