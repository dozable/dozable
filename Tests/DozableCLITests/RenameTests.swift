import Foundation
@testable import DozableKit
import XCTest
@testable import DozableHost

/// Owner, 2026-10-23 ("add rename"): `rename` moves a SHUT-DOWN sandbox to another name in place — the same disk files
/// (the same inodes: nothing copied), restore points, workspace, account, settings, kept terminal layout and open folders —
/// and a fresh host loads it under the new name with records that name it. Refused: a sandbox that is not shut down, a
/// name taken or invalid, the same name. In-process host, no VM: a lab create never boots; disks are stand-in files.
final class RenameTests: XCTestCase {
    private var root: URL!
    private var projects: URL!
    let keychain = FakeKeychain()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("doz-rename-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Outside the store and the system locations ($TMPDIR is under /private/var).
        projects = URL(fileURLWithPath: "/tmp/doz-rename-projects-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: projects)
    }

    var store: DozableStore { DozableStore(root: root) }

    func core() async -> HostCore {
        let s = CredentialServices(keychain: keychain, verifier: FakeVerifier(answer: .verified), claudeBinary: { nil }, home: root,
                                   keepaliveRunner: FakeRunner(), isClaudeRunning: { false }, watchInterval: .seconds(3600))
        let c = HostCore(store: store, readOnly: false, version: "test", services: s)
        await c.load()
        return c
    }

    func create(_ c: HostCore, _ name: String, workspace: String?) async throws {
        var r = HostRequest(.create, name: name)
        r.create = CreateOptions(image: "lab", workspace: workspace)
        let m = await c.handle(r)
        XCTAssertNil(m.error, m.error?.message ?? "")
    }

    func rename(_ c: HostCore, _ name: String, _ new: String) async -> HostMessage {
        var r = HostRequest(.rename, name: name)
        r.newName = new
        return await c.handle(r)
    }

    func inode(_ url: URL) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int)
    }

    /// A shut-down sandbox as a start leaves it: a root disk, a state disk, its record (off), a restore point.
    func shutDownWithDisks(_ name: String) throws {
        let l = store.layout(name)
        try Data("root".utf8).write(to: l.rootfs)
        try Data("state".utf8).write(to: l.stateDisk)
        let spec = try XCTUnwrap(SandboxConfig.read(store.configFile(name))).spec
        var p = PersistedSandbox(spec: spec, phase: .off, machineIdentifier: Data([1, 2, 3]), macAddress: nil, subnet: nil, shareTags: [:])
        p.rootImage = "lab-image"
        try p.write(to: l.persistedState)
        let rp = RestorePoint(id: "rp-1", name: "before", note: "", createdAt: Date(), parent: nil, sourceImage: "lab-image",
                              takenWhile: .stopped, hasStateDisk: true, automatic: false)
        let dir = l.restorePointDirectory(rp.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("root".utf8).write(to: dir.appendingPathComponent("root.ext4"))
        try ImageBaker.encoder.encode(rp).write(to: dir.appendingPathComponent("meta.json"))
    }

    func testAShutDownSandboxIsRenamedInPlaceWithEverythingItHas() async throws {
        let c = await core()
        let ws = projects.appendingPathComponent("demo").path
        try await create(c, "demo", workspace: ws)
        try shutDownWithDisks("demo")
        try TerminalLayout.write(TerminalLayout(panes: [.init(tabs: [.init(session: "shell")])]), store, "demo")
        try FileTreeState.write(FileTreeState(expanded: ["src"]), store, "demo")
        let before = try XCTUnwrap(SandboxConfig.read(store.configFile("demo")))
        let rootInode = try inode(store.layout("demo").rootfs), stateInode = try inode(store.layout("demo").stateDisk)

        let m = await rename(c, "demo", "website")
        XCTAssertNil(m.error, m.error?.message ?? "")
        let info = try XCTUnwrap(m.result).decode(SandboxInfo.self)
        XCTAssertEqual(info.name, "website")
        XCTAssertEqual(info.phase, "off")
        XCTAssertEqual(info.workspace, before.workspace, "the same folder — never moved")
        XCTAssertEqual(info.createdFolder, before.createdFolder, "the record that Dozable made it goes along")

        // The old name is gone, from the host and the store.
        let gone = await c.handle(HostRequest(.inspect, name: "demo"))
        XCTAssertEqual(gone.error?.code, .notFound)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.layout("demo").sandboxDirectory.path))
        // The same files under the new name — moved, not copied.
        let nl = store.layout("website")
        XCTAssertEqual(try inode(nl.rootfs), rootInode)
        XCTAssertEqual(try inode(nl.stateDisk), stateInode)
        XCTAssertEqual(nl.restorePoints().map(\.name), ["before"])
        let points = await c.handle(HostRequest(.pointList, name: "website"))
        XCTAssertNil(points.error, points.error?.message ?? "")
        XCTAssertEqual(TerminalLayout.read(store, "website")?.panes.first?.tabs.map(\.session), ["shell"])
        XCTAssertEqual(FileTreeState.read(store, "website")?.expanded, ["src"])
        // The records name it: doz.json (its name and spec) and sandbox.json (its spec), the rest as it was.
        let after = try XCTUnwrap(SandboxConfig.read(store.configFile("website")))
        XCTAssertEqual(after.name, "website")
        XCTAssertEqual(after.spec.name, "website")
        var expected = before
        expected.name = "website"
        expected.spec.name = "website"
        XCTAssertEqual(after, expected, "only the name changed: image, network, account, settings, workspace, created-at")
        let p = try XCTUnwrap(PersistedSandbox.read(from: nl.persistedState))
        XCTAssertEqual(p.spec.name, "website")
        XCTAssertEqual(p.rootImage, "lab-image")
        XCTAssertEqual(p.phase, .off)

        // A fresh host (what a start would read) loads it under the new name, its spec's paths in the new directory.
        let c2 = await core()
        let d = await c2.handle(HostRequest(.inspect, name: "website"))
        XCTAssertNil(d.error, d.error?.message ?? "")
        XCTAssertEqual(StoreLayout(spec: after.spec).rootfs.path, nl.rootfs.path)
        XCTAssertEqual(StoreLayout(spec: after.spec).persistedState.path, nl.persistedState.path)
        let none = await c2.handle(HostRequest(.inspect, name: "demo"))
        XCTAssertEqual(none.error?.code, .notFound)

        // And back: a name freed by a rename can be taken again.
        let back = await rename(c2, "website", "demo")
        XCTAssertNil(back.error, back.error?.message ?? "")
        XCTAssertEqual(try inode(store.layout("demo").rootfs), rootInode)
    }

    func testRefusals() async throws {
        let c = await core()
        try await create(c, "one", workspace: nil)
        try await create(c, "two", workspace: nil)
        let taken = await rename(c, "one", "two")
        XCTAssertEqual(taken.error?.code, .exists)
        let same = await rename(c, "one", "one")
        XCTAssertEqual(same.error?.code, .invalid)
        for bad in ["One", "-one", "a_b", "a b", String(repeating: "a", count: 41)] {
            let m = await rename(c, "one", bad)
            XCTAssertEqual(m.error?.code, .invalid, bad)
        }
        var noName = HostRequest(.rename, name: "one")
        noName.newName = nil
        let missing = await c.handle(noName)
        XCTAssertEqual(missing.error?.code, .invalid)
        let nobody = await rename(c, "nobody", "three")
        XCTAssertEqual(nobody.error?.code, .notFound)
        // A directory not made by doz holds the name.
        try FileManager.default.createDirectory(at: store.layout("stray").sandboxDirectory, withIntermediateDirectories: true)
        let stray = await rename(c, "one", "stray")
        XCTAssertEqual(stray.error?.code, .exists)
        // Nothing moved for any of them.
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.configFile("one").path))
        let one = await c.handle(HostRequest(.inspect, name: "one"))
        XCTAssertNil(one.error, one.error?.message ?? "")
    }

    /// Not shut down: a sandbox a wake would restore (asleep with its snapshot — hibernated to a new host) is refused, and
    /// says how; nothing moves.
    func testASandboxThatIsNotShutDownIsRefused() async throws {
        let c0 = await core()
        try await create(c0, "sleepy", workspace: nil)
        let l = store.layout("sleepy")
        try Data("root".utf8).write(to: l.rootfs)
        try Data("snapshot".utf8).write(to: l.snapshot)
        let spec = try XCTUnwrap(SandboxConfig.read(store.configFile("sleepy"))).spec
        try PersistedSandbox(spec: spec, phase: .asleep, machineIdentifier: Data([1]), macAddress: nil, subnet: nil, shareTags: [:])
            .write(to: l.persistedState)
        let c = await core()
        let m = await rename(c, "sleepy", "awake")
        XCTAssertEqual(m.error?.code, .invalidPhase)
        XCTAssertTrue(m.error?.message.contains("doz shutdown sleepy") == true, m.error?.message ?? "")
        XCTAssertTrue(FileManager.default.fileExists(atPath: l.snapshot.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.layout("awake").sandboxDirectory.path))
        let still = await c.handle(HostRequest(.inspect, name: "sleepy"))
        XCTAssertNil(still.error, still.error?.message ?? "")
    }

    /// It changes the store: an in-process (read-only) core refuses it — a host does it, as `rm`.
    func testRenameNeedsTheHost() async throws {
        let c = await core()
        try await create(c, "solo", workspace: nil)
        let s = CredentialServices(keychain: keychain, verifier: FakeVerifier(answer: .verified), claudeBinary: { nil }, home: root,
                                   keepaliveRunner: FakeRunner(), isClaudeRunning: { false }, watchInterval: .seconds(3600))
        let ro = HostCore(store: store, readOnly: true, version: "test", services: s)
        await ro.load()
        let m = await rename(ro, "solo", "duo")
        XCTAssertEqual(m.error?.code, .unavailable)
        XCTAssertFalse(HostOp.rename.isReadOnly)
        XCTAssertFalse(HostOp.rename.isAnsweredWithoutHost)
    }
}
