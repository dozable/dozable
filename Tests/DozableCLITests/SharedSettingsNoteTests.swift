import Foundation
import XCTest
@testable import DozableCLI

/// A first-run confusion: a second store (DOZ_STORE or --store) with no XDG_CONFIG_HOME of its own reads and writes this
/// Mac's one doz.toml, and `doz config set` with a throwaway store changed the real file. Resolution is unchanged;
/// config set, doctor and onboard say which file it is, only then.
final class SharedSettingsNoteTests: XCTestCase {
    func testSaidOnlyForANamedStoreWithTheSharedFile() {
        let file = "/Users/x/.config/doz/doz.toml"
        XCTAssertNil(SharedSettingsNote.line(storeOption: nil, environment: [:], settingsPath: file), "the default store: nothing to say")
        XCTAssertNil(SharedSettingsNote.line(storeOption: nil, environment: ["DOZ_STORE": ""], settingsPath: file))
        XCTAssertNil(SharedSettingsNote.line(storeOption: nil, environment: ["DOZ_STORE": "/tmp/s", "XDG_CONFIG_HOME": "/tmp/x"], settingsPath: file),
                     "settings of its own: nothing to say")
        let e = SharedSettingsNote.line(storeOption: nil, environment: ["DOZ_STORE": "/tmp/s2"], settingsPath: file)
        XCTAssertNotNil(e)
        XCTAssertTrue(e!.contains("/tmp/s2") && e!.contains("doz.toml") && e!.contains("XDG_CONFIG_HOME") && e!.contains("chat server's ports"))
        let o = SharedSettingsNote.line(storeOption: "/tmp/s3", environment: [:], settingsPath: file)
        XCTAssertTrue(o?.contains("/tmp/s3") == true, "--store too")
    }
}
