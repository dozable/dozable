import Darwin
import DozableChat
import Foundation
import XCTest
@testable import DozableHost

/// Agents on other machines, the daemon's side: the two settings (exact Tailscale addresses, set on this Mac only), the
/// generated config (each remote agent in `allow` AND an agent address; `remote_bind` only for addresses this Mac has on a
/// Tailscale interface now — an injected interface list here, never a real bind), what the state says.
final class ChatRemoteDaemonTests: XCTestCase {
    var root: String!
    var paths: ChatPaths { ChatPaths(folder: root + "/chat") }

    override func setUpWithError() throws {
        root = "/tmp/dzc-rd-\(getpid())-\(UUID().uuidString.prefix(6))"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(atPath: root) }

    func testTheTwoSettings() throws {
        for k in [SettingKey.chatRemoteListen, SettingKey.chatRemoteAgents] {
            let d = try XCTUnwrap(DozableSettings.definition(k))
            XCTAssertEqual(d.defaultValue, .string(""))
            XCTAssertNil(d.environment, "\(k): never an environment value")
            XCTAssertNil(d.flag)
            XCTAssertFalse(d.editableInUI, "\(k): set on this Mac only")
            XCTAssertFalse(d.summary.lowercased().contains("hub"))
            XCTAssertNoThrow(try d.parse("100.100.1.2"))
            XCTAssertNoThrow(try d.parse("100.100.1.2, 100.100.1.3"))
            XCTAssertNoThrow(try d.parse(""))
            for bad in ["0.0.0.0", "::", "192.168.1.5", "169.254.1.1", "127.0.0.1", "100.64.0.0/10", "100.128.0.1", "fd7a:115c:a1e0::1", "bot.example",
                        "100.100.1.2, 100.100.1.2"] {
                XCTAssertThrowsError(try d.parse(bad), "\(k) = \(bad)")
            }
        }
    }

    func testTheGeneratedConfigLetsEachRemoteAgentInAsAnAgentOnly() throws {
        let d = ChatDirectory(human: "ada", participants: [.init(name: "bot1", added: "x")])
        let out = try ChatConfigFile.bytes(d, paths: paths, pagePort: 8790, linePort: 8791, remoteBind: ["100.100.1.1"], remoteAgents: ["100.100.1.2"])
        let c = try ChatConfig.parse(Data(out))
        XCTAssertEqual(c.remoteBind, ["100.100.1.1"])
        XCTAssertEqual(c.allow, ["127.0.0.1", "::1", "100.100.1.2"])
        XCTAssertEqual(c.agentAddresses, ["127.0.0.0/8", "::1", "100.100.1.2"])
        XCTAssertEqual(c.access.page(remote: "100.100.1.2", agentPath: false), ChatAccess.agentOnly)
        XCTAssertEqual(c.access.line(remote: "100.100.1.2"), true)
        XCTAssertNil(c.access.line(remote: "100.100.1.3"))
        // Without a remote listener: no remote_bind at all (the golden loopback-only config is unchanged).
        let plain = try ChatConfig.parse(Data(try ChatConfigFile.bytes(d, paths: paths, pagePort: 8790, linePort: 8791)))
        XCTAssertTrue(plain.remoteBind.isEmpty)
        // The generator refuses what the setting would refuse anyway.
        XCTAssertThrowsError(try ChatConfigFile.bytes(d, paths: paths, pagePort: 8790, linePort: 8791, remoteAgents: ["192.168.1.5"]))
        XCTAssertThrowsError(try ChatConfigFile.bytes(d, paths: paths, pagePort: 8790, linePort: 8791, remoteBind: ["0.0.0.0"]))
    }

    final class IfBox: @unchecked Sendable {
        let lock = NSLock()
        var list: [ChatInterface] = []
        func get() -> [ChatInterface] { lock.withLock { list } }
    }

    func testOnlyAnAddressThisMacHasOnTailscaleIsListenedOn() async throws {
        let fake = FakeChatProcesses()
        let ifs = IfBox()
        final class View: @unchecked Sendable { var v = ChatSettingsView(enabled: true, remoteListen: ["100.100.1.1"], remoteAgents: ["100.100.1.2"]) }
        let view = View()
        let sup = ChatSupervisor(paths: paths, executable: "/usr/bin/false", release: "0.0.0", processes: fake, environment: [:],
                                 interfaces: { ifs.get() }, readSettings: { view.v })
        _ = try await sup.sync(human: "ada", retry: true, waitReady: false, blocked: false)
        var st = await sup.status()
        XCTAssertEqual(st.remote, ChatRemoteState(listen: [], agents: ["100.100.1.2"], missing: ["100.100.1.1"]))
        XCTAssertTrue(st.warnings?.contains("not listening on 100.100.1.1: not an address of this Mac now (is Tailscale up?)") == true)
        XCTAssertFalse(try String(contentsOfFile: paths.config, encoding: .utf8).contains("remote_bind"), "loopback only while it is missing")
        XCTAssertEqual(fake.spawnCount, 1)
        // The same address on a LAN interface is not it.
        ifs.lock.withLock { ifs.list = [ChatInterface(name: "en0", address: "100.100.1.1", up: true)] }
        _ = try await sup.sync(human: nil, retry: false, waitReady: false, blocked: false)
        XCTAssertEqual(fake.spawnCount, 1)
        // On Tailscale: the files change, the server restarts with it.
        ifs.lock.withLock { ifs.list = [ChatInterface(name: "utun3", address: "100.100.1.1", up: true)] }
        _ = try await sup.sync(human: nil, retry: false, waitReady: false, blocked: false)
        st = await sup.status()
        XCTAssertEqual(st.remote?.listen, ["100.100.1.1"])
        XCTAssertNil(st.warnings)
        XCTAssertEqual(fake.spawnCount, 2)
        XCTAssertTrue(try String(contentsOfFile: paths.config, encoding: .utf8).contains(#""remote_bind": ["#))
        XCTAssertEqual(st.remote?.line(pagePort: 8790, linePort: 8791),
                       "Also listening on 100.100.1.1 (page port 8790, line port 8791) for 100.100.1.2 — agents with a token only.")
        // Listening with nobody let in is said.
        view.v.remoteAgents = []
        _ = try await sup.sync(human: nil, retry: false, waitReady: false, blocked: false)
        st = await sup.status()
        XCTAssertTrue(st.warnings?.contains { $0.contains("chat.remote_agents is empty") } == true)
        await sup.stopForExit()
    }
}
