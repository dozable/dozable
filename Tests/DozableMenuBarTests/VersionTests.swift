import XCTest
@testable import DozableMenuBarCore

final class VersionTests: XCTestCase {
    func v(_ s: String) -> DozVersion { DozVersion(s)! }

    func testOrder() {
        XCTAssertLessThan(v("0.50.4"), v("0.50.5"))
        XCTAssertLessThan(v("0.50.9"), v("0.50.10"), "numbers, not text")
        XCTAssertLessThan(v("0.9.0"), v("0.50.0"))
        XCTAssertLessThan(v("0.50.5"), v("1.0.0"))
        XCTAssertLessThan(v("0.51.0-rc.1"), v("0.51.0"), "a release ranks above its prereleases")
        XCTAssertLessThan(v("0.51.0-rc.2"), v("0.51.0-rc.10"))
        XCTAssertLessThan(v("0.31.0-t.1"), v("0.31.0-t.2"))
        XCTAssertLessThan(v("0.51.0-1"), v("0.51.0-alpha"), "numeric parts below alphanumeric ones")
        XCTAssertLessThan(v("0.51.0-rc"), v("0.51.0-rc.1"))
        XCTAssertEqual(v("0.50.7+build.3"), v("0.50.7"), "build metadata is ignored")
        XCTAssertEqual(v(" 0.50.7\n"), v("0.50.7"))
    }

    func testWhatIsNotAVersion() {
        for s in ["", "0.50", "0.50.x", "v0.50.7", "0.50.7-", "0.50.7-rc..1", "1.2.3.4", "-1.0.0", String(repeating: "1", count: 50)] {
            XCTAssertNil(DozVersion(s), s)
        }
    }

    func testIsOlderNeverCallsTheUnreadableOld() {
        XCTAssertTrue(DozVersion.isOlder("0.50.3", than: "0.50.5"))
        XCTAssertFalse(DozVersion.isOlder("0.50.5", than: "0.50.5"))
        XCTAssertFalse(DozVersion.isOlder("garbage", than: "0.50.5"))
        XCTAssertFalse(DozVersion.isOlder(nil, than: "0.50.5"))
        XCTAssertFalse(DozVersion.isOlder("0.50.3", than: nil))
    }

    func testTheMinimumParses() {
        XCTAssertNotNil(DozVersion(MenuBarApp.minimumDoz))
    }
}
