import Darwin
import Foundation
import XCTest
@testable import DozableHost

/// `<store>/grants/grants.json` and its log: the round trip, a higher version and fields this build does not know kept, 0600
/// in 0700, written by rename, the log one line per change (a torn line skipped). And who a question is about. Scratch roots.
final class GrantStoreTests: XCTestCase {
    private var root: URL!
    private var grants: GrantStore!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: "/tmp/doz-grants-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        grants = GrantStore(store: DozableStore(root: root))
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func mode(_ p: String) -> mode_t { var st = stat(); return lstat(p, &st) == 0 ? st.st_mode & 0o777 : 0 }

    func testRoundTripModesAndTheLog() throws {
        XCTAssertEqual(try grants.read(), GrantsFile(), "no file: nothing")
        XCTAssertNil(MacFenceHostFS.kind(grants.root), "reading writes nothing")
        let at = Date(timeIntervalSince1970: 1_900_000_000.5)
        let f = GrantsFile(grants: [Grant(id: "g1", subject: .bot("otto"), perm: "sudo", answer: .never, scope: .everywhere, at: at),
                                    Grant(id: "g2", subject: .bot("ops"), role: "admin", scope: .everywhere, until: at.addingTimeInterval(86_400), at: at)],
                           ceiling: ["worker.start": "never"])
        try grants.write(f)
        XCTAssertEqual(try grants.read(), f)
        XCTAssertEqual(mode(grants.root), 0o700)
        XCTAssertEqual(mode(grants.file), 0o600)
        try grants.append(GrantLogEntry(at: at, action: "granted", subject: "bot:otto", perm: "sudo", answer: "never", scope: "everywhere", id: "g1"))
        // A torn line, then another entry: it starts on a line of its own, and the torn one is skipped.
        let fd = open(grants.logFile, O_WRONLY | O_APPEND)
        _ = "{\"v\":1,\"at\"".withCString { write(fd, $0, strlen($0)) }
        close(fd)
        try grants.append(GrantLogEntry(at: at, action: "ceiling-set", perm: "worker.start", answer: "never", scope: "mac"))
        XCTAssertEqual(grants.log().map(\.action), ["granted", "ceiling-set"])
        XCTAssertEqual(mode(grants.logFile), 0o600)
        let text = try String(contentsOfFile: grants.logFile, encoding: .utf8)
        XCTAssertFalse(text.contains("dzc_"), "never a token")
    }

    /// A newer doz's version and fields survive this build's rewrite — the file, a grant, the workspace's section.
    func testANewerFileSurvivesARewrite() throws {
        try grants.write(GrantsFile(grants: [Grant(id: "g1", subject: .bot("otto"), perm: "sudo", answer: .never, scope: .everywhere)]))
        var obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: grants.file))) as? [String: Any])
        obj["version"] = 3
        obj["budgets"] = ["otto": 4]
        var list = try XCTUnwrap(obj["grants"] as? [[String: Any]])
        list[0]["by"] = "mira"
        list[0]["later"] = ["x": 1]
        list.append(["id": "g9", "subject": "bot:otto", "perm": "spend", "answer": "maybe", "scope": "everywhere", "by": "you",
                     "at": "2030-03-17T17:46:40.000Z"])
        obj["grants"] = list
        try JSONSerialization.data(withJSONObject: obj).write(to: URL(fileURLWithPath: grants.file))
        var f = try grants.read()
        XCTAssertEqual(f.version, 3)
        XCTAssertNil(f.grants[1].answerValue, "an answer word this build does not know says nothing")
        f.ceiling["sudo"] = "never"
        try grants.write(f)
        let again = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: grants.file))) as? [String: Any])
        XCTAssertEqual(again["version"] as? Int, 3)
        XCTAssertEqual((again["budgets"] as? [String: Int])?["otto"], 4)
        let g = try XCTUnwrap((again["grants"] as? [[String: Any]])?.first)
        XCTAssertEqual((g["later"] as? [String: Int])?["x"], 1)
        XCTAssertEqual(g["by"] as? String, "mira")
        XCTAssertEqual((again["grants"] as? [[String: Any]])?.last?["answer"] as? String, "maybe")
    }

    /// Who a question is about: an agent of a workspace by its name (its record's role is its role there), a bot, the forms
    /// `bot:` and `agent:`, and the refusals.
    func testWho() throws {
        let store = DozableStore(root: root)
        let ws = WorkspaceStore(store: store)
        let at = Date(timeIntervalSince1970: 1_900_000_000)
        var rec = WorkspaceRecord(name: "myapp-tests", createdAt: at, brief: WorkspaceBrief(refs: [], sha256: "ab", bytes: 2, updatedAt: at), folders: [])
        rec.agents = [WorkspaceAgent(name: "mira", role: "manager", place: .macSession("myapp-tests"), startedAt: at, bot: "mira"),
                      WorkspaceAgent(name: "bot2", role: "worker", place: .macSession("myapp-tests-bot2"), startedAt: at)]
        rec.permissions = WorkspaceGrants(grants: [Grant(subject: .agent("myapp-tests", "bot2"), perm: "folder.read", answer: .allow, scope: .workspace("myapp-tests"))],
                                          ceiling: ["folder.read": "ask"])
        try ws.create(rec, brief: Data("x".utf8), log: [])
        try BotStore(store: store).write(BotsFile(bots: [BotRecord(name: "mira", createdAt: at, agent: "claude-code", isolation: BotIsolation(default: "fenced"),
                                                                   kind: "claude-session", token: BotTokenState(keeper: "dozable", fingerprint: nil, at: at))]))
        let r = GrantFactsReader(store: store)
        let bot2 = try r.resolve("bot2", in: "myapp-tests")
        XCTAssertEqual(bot2, GrantWho(name: "bot2", home: "myapp-tests", bot: nil, recordRoles: [HeldRole(role: "worker", workspace: "myapp-tests")]))
        XCTAssertEqual(try r.resolve("bot2", in: nil), bot2, "the one agent of that name")
        XCTAssertEqual(try r.resolve("agent:myapp-tests/bot2", in: nil), bot2)
        XCTAssertEqual(try r.resolve("mira", in: "myapp-tests").bot, "mira")
        XCTAssertEqual(try r.resolve("bot:mira", in: nil).recordRoles, [HeldRole(role: "manager", workspace: "myapp-tests")])
        XCTAssertThrowsError(try r.resolve("ghost", in: "myapp-tests"))
        XCTAssertThrowsError(try r.resolve("ghost", in: nil))
        XCTAssertThrowsError(try r.resolve("role:worker", in: nil))
        // The workspace's grant, capped by its own ceiling.
        let d = r.decide(bot2, perm: "folder.read", workspace: "myapp-tests")
        XCTAssertEqual(d.answer, .ask)
        XCTAssertEqual(d.decidedAt, 5)
        XCTAssertEqual(r.facts(bot2, workspace: "myapp-tests").manager, "mira")
    }
}
