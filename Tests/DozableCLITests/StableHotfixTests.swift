import Foundation
import XCTest
@testable import DozableHost

/// 778 (the hotfix after 0.52.55 reached stable): a store that declined this Mac's Claude Code login never falls back to
/// it for a fenced session, and a workspace's `standard` network is a VM's `agent`. No VM, no real keychain.
final class StableHotfixTests: XCTestCase {
    private func accounts(declined: Bool, default d: String = "mac", names: [String] = []) -> AccountsFile {
        var f = AccountsFile()
        f.macDeclined = declined ? true : nil
        f.defaultAccount = d
        f.accounts = names.map { AccountRecord(name: $0, kind: .key) }
        return f
    }

    func testADeclinedMacLoginIsNeverTheFencedFallback() {
        let unset = DozableSettings(text: nil)
        XCTAssertEqual(HostCore.fencedDefaultAccount(settings: unset, accounts: accounts(declined: false)), "mac",
                       "not declined: as before")
        XCTAssertEqual(HostCore.fencedDefaultAccount(settings: unset, accounts: accounts(declined: true, default: "none")), "none",
                       "declined, no other account: none — never mac")
        XCTAssertEqual(HostCore.fencedDefaultAccount(settings: unset, accounts: accounts(declined: true, default: "work", names: ["work"])), "work",
                       "declined, a default account of the store's own: that one")
        XCTAssertEqual(HostCore.fencedDefaultAccount(settings: unset, accounts: accounts(declined: true, default: "mac")), "none",
                       "declined while the default still says mac: none")
    }

    func testAWorkspacesStandardNetworkIsAVMsAgentNetwork() throws {
        XCTAssertEqual(HostCore.vmNetwork(permissions: "standard"), "agent")
        XCTAssertEqual(HostCore.vmNetwork(permissions: "locked"), "locked")
        XCTAssertEqual(HostCore.vmNetwork(permissions: "open"), "open")
        for level in WorkspaceNetworks.presets {   // every level a workspace takes is a network a VM knows
            XCTAssertNoThrow(try DozableImages.networkMode(HostCore.vmNetwork(permissions: level)), level)
        }
    }
}
