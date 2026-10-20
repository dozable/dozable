import Foundation
@testable import DozableKit
import XCTest
@testable import DozableHost

/// 634 (owner: "drop the special status of a 'try' vs not a try but keep the ability to easily delete"): the folder
/// Dozable made for ANY sandbox is recorded (`SandboxConfig.createdFolder`) and goes with it while empty; a folder that
/// was there is never recorded; a duplicate never owns its source's; an old doz.json carrying 617's `trial` /
/// `trialFolder` loads with both ignored (NO migration). In-process host, no VM: create never boots.
final class CreatedFolderTests: XCTestCase {
    private var root: URL!
    private var projects: URL!
    let keychain = FakeKeychain()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("doz-created-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Outside the store and the system locations ($TMPDIR is under /private/var): a folder Dozable would make.
        projects = URL(fileURLWithPath: "/tmp/doz-created-projects-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: projects)
    }

    func core() async -> HostCore {
        let s = CredentialServices(keychain: keychain, verifier: FakeVerifier(answer: .verified), claudeBinary: { nil }, home: root,
                                   keepaliveRunner: FakeRunner(), isClaudeRunning: { false }, watchInterval: .seconds(3600))
        let c = HostCore(store: DozableStore(root: root), readOnly: false, version: "test", services: s)
        await c.load()
        return c
    }

    func create(_ c: HostCore, _ name: String, workspace: String?) async -> HostMessage {
        var r = HostRequest(.create, name: name)
        r.create = CreateOptions(image: "lab", workspace: workspace)
        return await c.handle(r)
    }

    func info(_ c: HostCore, _ name: String) async throws -> SandboxInfo {
        let m = await c.handle(HostRequest(.inspect, name: name))
        return try XCTUnwrap(m.result).decode(SandboxDetail.self).info
    }

    func testAFolderDozableMadeIsRecordedAndGoesWithTheSandboxWhileEmpty() async throws {
        let c = await core()
        let given = projects.appendingPathComponent("plain").path
        let made = "/private" + given               // a workspace is recorded resolved (/tmp is a link to /private/tmp)
        let m = await create(c, "plain", workspace: given)
        XCTAssertNil(m.error, m.error?.message ?? "")
        let plain = try await info(c, "plain")
        XCTAssertEqual(plain.createdFolder, made, "any sandbox, not only a try")
        XCTAssertEqual(SandboxConfig.read(DozableStore(root: root).configFile("plain"))?.createdFolder, made)
        let rm = await c.handle(HostRequest(.rm, name: "plain"))
        XCTAssertNil(rm.error, rm.error?.message ?? "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: made), "the empty folder went with it")
    }

    func testAFolderWithFilesIsKept() async throws {
        let c = await core()
        let made = projects.appendingPathComponent("busy").path
        _ = await create(c, "busy", workspace: made)
        try "notes".write(toFile: made + "/notes.md", atomically: true, encoding: .utf8)
        _ = await c.handle(HostRequest(.rm, name: "busy"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: made + "/notes.md"), "a folder that holds files is the person's")
    }

    func testAFolderThatWasThereIsNeverRecorded() async throws {
        let c = await core()
        let there = projects.appendingPathComponent("mine").path
        try FileManager.default.createDirectory(atPath: there, withIntermediateDirectories: true)
        _ = await create(c, "mine", workspace: there)
        let mine = try await info(c, "mine")
        XCTAssertNil(mine.createdFolder)
        _ = await c.handle(HostRequest(.rm, name: "mine"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: there), "never a folder Dozable did not make")
        // Isolated: none.
        _ = await create(c, "iso", workspace: nil)
        let iso = try await info(c, "iso")
        XCTAssertNil(iso.createdFolder)
    }

    func testAnOldConfigsTryFieldsAreIgnored() throws {
        let store = DozableStore(root: root)
        let spec = try DozableImages.spec(name: "old", options: CreateOptions(image: "lab"), store: store).0
        var cfg = SandboxConfig(name: "old", image: "lab", spec: spec, workspace: "/tmp/x")
        cfg.createdFolder = nil
        let url = store.configFile("old")
        try cfg.write(url)
        // 617's fields, written as an older doz wrote them.
        var obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        obj["trial"] = true
        obj["trialFolder"] = "/tmp/x"
        try JSONSerialization.data(withJSONObject: obj).write(to: url)
        let back = try XCTUnwrap(SandboxConfig.read(url), "it still loads")
        XCTAssertNil(back.createdFolder, "the old folder field is not honoured (no migration)")
        XCTAssertEqual(back.name, "old")
    }
}
