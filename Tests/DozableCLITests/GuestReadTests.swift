import Foundation
@testable import DozableKit
import XCTest
@testable import DozableHost

/// 678 B7: one stuck guest never holds the host's answers — a listing's read of a guest is bounded, the guest is then
/// `unresponsive` and not asked again for a while, and the host goes on answering. In-process host, no VM.
final class GuestReadTests: XCTestCase {
    private var root: URL!
    private var projects: URL!
    let keychain = FakeKeychain()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("doz-guestread-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        projects = URL(fileURLWithPath: "/tmp/doz-guestread-projects-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: projects)
    }

    func core() async throws -> HostCore {
        let s = CredentialServices(keychain: keychain, verifier: FakeVerifier(answer: .verified), claudeBinary: { nil }, home: root,
                                   keepaliveRunner: FakeRunner(), isClaudeRunning: { false }, watchInterval: .seconds(3600))
        let c = HostCore(store: DozableStore(root: root), readOnly: false, version: "test", services: s)
        await c.load()
        var r = HostRequest(.create, name: "stuck")
        r.create = CreateOptions(image: "lab", workspace: nil)
        let m = await c.handle(r)
        XCTAssertNil(m.error, m.error?.message ?? "")
        return c
    }

    func testAStuckReadIsBoundedAndTheHostGoesOnAnswering() async throws {
        let c = try await core()
        let t0 = Date()
        let r = await c.guestRead(named: "stuck") { _ -> Int in try await Task.sleep(for: .seconds(20)); return 1 }
        guard case .unresponsive = r else { return XCTFail("a read past the limit: unresponsive") }
        XCTAssertLessThan(Date().timeIntervalSince(t0), 6, "bounded by guestReadLimit")
        // Not asked again for a while: at once.
        let t1 = Date()
        let again = await c.guestRead(named: "stuck") { _ -> Int in XCTFail("not asked again"); return 2 }
        guard case .unresponsive = again else { return XCTFail("still unresponsive") }
        XCTAssertLessThan(Date().timeIntervalSince(t1), 0.5)
        // The host answers its listing meanwhile (the stuck read is still pending).
        let t2 = Date()
        let ls = await c.handle(HostRequest(.ls))
        XCTAssertNil(ls.error)
        XCTAssertLessThan(Date().timeIntervalSince(t2), 2)
        // A lifecycle request asks again at once; an answer clears it.
        await c.clearUnresponsiveForTests("stuck")
        let ok = await c.guestRead(named: "stuck") { _ -> Int in 3 }
        guard case .answered(let v) = ok, v == 3 else { return XCTFail("answered") }
        struct Boom: Error {}
        let bad = await c.guestRead(named: "stuck") { _ -> Int in throw Boom() }
        guard case .failed = bad else { return XCTFail("a failure is not unresponsive") }
    }

    func testTheInfoFieldRoundTripsAndAnOlderRowDecodes() throws {
        var i = SandboxInfo(name: "x", image: "lab", phase: "running", busy: false, cpus: 1, memoryMiB: 512, ramHeldMiB: 512,
                            memoryReturnedMiB: 0, diskBytes: 0, sessions: nil, network: "none", deniedConnections: nil,
                            workspace: nil, createdAt: nil, diedWithHost: nil)
        i.unresponsive = true
        let back = try HostWire.decoder.decode(SandboxInfo.self, from: HostWire.encoder.encode(i))
        XCTAssertEqual(back.unresponsive, true)
        i.unresponsive = nil
        let old = try HostWire.decoder.decode(SandboxInfo.self, from: HostWire.encoder.encode(i))
        XCTAssertNil(old.unresponsive)
    }
}
