import Foundation
import XCTest
@testable import DozableHost
@testable import DozableCLI

/// 778.B2: in a store that declined this Mac's Claude Code login, what a person reads says what a fenced session will use —
/// `doz run @mac --dry-run`'s capability list (`MacCapabilityShape.planned`, shared with the dashboard's plan) and `doz config
/// show`'s mac.account row — from the daemon's one rule, `HostCore.fencedDefaultAccount`.
final class DeclinedAccountDisplayTests: XCTestCase {
    private func accounts(declined: Bool, default d: String = "mac", names: [String] = []) -> AccountsFile {
        var f = AccountsFile()
        f.macDeclined = declined ? true : nil
        f.defaultAccount = d
        f.accounts = names.map { AccountRecord(name: $0, kind: .key) }
        return f
    }

    private func planned(_ a: AccountsFile, account: String? = nil) -> MacCapabilityShape {
        var q = MacFenceRequest(permissions: ["standard"])
        q.account = account
        return MacCapabilityShape.planned(session: "claude", workdir: "/tmp/x", argv: ["claude"], fenced: true, request: q,
                                          settings: DozableSettings(text: nil), accounts: a, home: "/tmp/home")
    }

    func testTheDryRunsAccountIsTheOneTheSessionWillUse() {
        XCTAssertEqual(planned(accounts(declined: false)).account, "mac", "not declined: as before")
        XCTAssertEqual(planned(accounts(declined: true, default: "none")).account, "none", "declined: none, never mac")
        XCTAssertEqual(planned(accounts(declined: true, default: "work", names: ["work"])).account, "work")
        XCTAssertEqual(planned(accounts(declined: true), account: "work").account, "work", "--account wins")
        let login = MacFence.capabilities(planned(accounts(declined: true, default: "none"))).first { $0.id == "claude-login" }
        XCTAssertEqual(login?.state, "none", "never \"swapped in (account mac)\"")
    }

    func testConfigShowNotesADeclinedStore() {
        let unset = DozableSettings(text: nil)
        XCTAssertNil(ConfigShow.declinedNote(settings: unset, accounts: accounts(declined: false)))
        XCTAssertEqual(ConfigShow.declinedNote(settings: unset, accounts: accounts(declined: true, default: "none")), "declined by this store: none")
        XCTAssertEqual(ConfigShow.declinedNote(settings: unset, accounts: accounts(declined: true, default: "work", names: ["work"])), "declined by this store: work")
        let none = DozableSettings(text: "[mac]\naccount = \"none\"\n")
        XCTAssertNil(ConfigShow.declinedNote(settings: none, accounts: accounts(declined: true, default: "work", names: ["work"])),
                     "mac.account = none is used as set: nothing to note")
    }
}
