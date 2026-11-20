import Foundation
import XCTest
@testable import DozableKit
@testable import DozableHost

/// `session-forget` in an in-process daemon core on a scratch store (recorded sessions whose holders are gone — no process
/// is started): ended ones forgotten, a workspace's kept with its reason, a dry run changes nothing and needs no daemon, a
/// second run forgets nothing. A running session and a refused carry-back: `make test-cli-host` and `make test-cli-fence`.
final class MacForgetTests: XCTestCase {
    private var root: URL!
    private var folder: URL!
    let keychain = FakeKeychain()

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: "/tmp/doz-mfg-\(UUID().uuidString.prefix(8))")
        folder = root.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        folder = URL(fileURLWithPath: WorkspaceStore.resolved(folder.path))
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    var store: DozableStore { DozableStore(root: root.appendingPathComponent("store")) }

    func core(readOnly: Bool = false) async -> HostCore {
        let s = CredentialServices(keychain: keychain, verifier: FakeVerifier(answer: .verified), claudeBinary: { nil }, home: root,
                                   keepaliveRunner: FakeRunner(), isClaudeRunning: { false }, watchInterval: .seconds(3600))
        let c = HostCore(store: store, readOnly: readOnly, version: "test", services: s)
        await c.load()
        return c
    }

    func macSession(_ name: String) throws {
        let dir = store.root.appendingPathComponent("mac-sessions")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("sessions.json")
        var recs = (try? Data(contentsOf: file)).flatMap { try? HostWire.decoder.decode(MacSessionRecords.self, from: $0) } ?? MacSessionRecords()
        recs.sessions[name] = MacSessionRecord(argv: ["/bin/sh"], workdir: folder.path, openedAt: Date())
        try HostWire.prettyEncoder.encode(recs).write(to: file)
    }

    func recorded() -> Set<String> {
        let file = store.root.appendingPathComponent("mac-sessions/sessions.json")
        return Set(((try? Data(contentsOf: file)).flatMap { try? HostWire.decoder.decode(MacSessionRecords.self, from: $0) })?.sessions.keys.map { $0 } ?? [])
    }

    func forget(_ c: HostCore, ended: Bool = false, sessions: [String]? = nil, dry: Bool = false) async throws -> SessionsForgotten {
        var r = HostRequest(.sessionForget, name: MacPlace.name)
        r.forgetEnded = ended ? true : nil
        r.sessions = sessions
        r.dryRun = dry ? true : nil
        let m = await c.handle(r)
        XCTAssertNil(m.error, m.error?.message ?? "")
        return try XCTUnwrap(m.result).decode(SessionsForgotten.self)
    }

    func testEndedAreForgottenAWorkspacesIsKeptAndASecondRunForgetsNothing() async throws {
        for s in ["old1", "old2", "wsu"] { try macSession(s) }
        let c = await core()
        var w = WorkspaceRequest(name: "demo")
        w.brief = "x\n"
        w.folders = [WorkspaceFolder(path: folder.path)]
        w.noRoom = true
        w.adopt = ["@mac/wsu"]
        var r = HostRequest(.workspaceNew)
        r.workspaceRequest = w
        let made = await c.handle(r)
        XCTAssertNil(made.error, made.error?.message ?? "")

        // A dry run, in a read-only core (no daemon): what would go and what stays; nothing changed.
        let ro = await core(readOnly: true)
        let plan = try await forget(ro, ended: true, dry: true)
        XCTAssertEqual(plan.dryRun, true)
        XCTAssertEqual(Set(plan.forgotten), ["old1", "old2"])
        XCTAssertEqual(plan.kept.map(\.name), ["wsu"])
        XCTAssertTrue(plan.kept[0].why.contains("in workspace demo"), plan.kept[0].why)
        XCTAssertEqual(recorded(), ["old1", "old2", "wsu"], "a dry run changes nothing")
        var refused = HostRequest(.sessionForget, name: MacPlace.name)
        refused.forgetEnded = true
        let m = await ro.handle(refused)
        XCTAssertNotNil(m.error, "forgetting needs the daemon; only the dry run is in-process")

        let done = try await forget(c, ended: true)
        XCTAssertEqual(Set(done.forgotten), ["old1", "old2"])
        XCTAssertEqual(recorded(), ["wsu"], "the workspace's session is kept")
        let again = try await forget(c, ended: true)
        XCTAssertTrue(again.forgotten.isEmpty, "a second run forgets nothing")
        XCTAssertEqual(again.kept.map(\.name), ["wsu"])
    }

    func testNamedOnesAndOnesThatAreNotThere() async throws {
        try macSession("old1")
        let c = await core()
        let f = try await forget(c, sessions: ["old1", "nosuch"])
        XCTAssertEqual(f.forgotten, ["old1"])
        XCTAssertEqual(f.kept.map(\.name), ["nosuch"])
    }

    func testTheDashboardsEndNeverForgets() async throws {
        try macSession("old1")
        let c = await core()
        var r = HostRequest(.sessionEnd, name: MacPlace.name)
        r.session = "old1"
        r.onlyRunning = true
        let m = await c.handle(r)
        XCTAssertNotNil(m.error, "an end that may only end a running session is refused for an ended one")
        XCTAssertEqual(recorded(), ["old1"], "and nothing is forgotten")
        r.onlyRunning = nil
        let cli = await c.handle(r)
        XCTAssertNil(cli.error, "the CLI's end of an ended session still forgets it")
        XCTAssertEqual(recorded(), [])
    }
}
