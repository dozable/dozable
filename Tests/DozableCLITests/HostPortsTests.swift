import Foundation
import XCTest
@testable import DozableCLI
@testable import DozableHost
@testable import DozableKit

/// 691 — this Mac's ports (`host:PORT`, `--host-port`): the words beside the permissions, the live edit and its setting,
/// the model server's entry, the suggestion, the records (an older one has none), the fence's widening, the project
/// file, the facts and capabilities.
final class HostPortsTests: XCTestCase {
    override func tearDown() {
        HostRoute.protect(nil)
        super.tearDown()
    }

    func testHostWordsAreNeverPermissions() throws {
        let (ports, rest) = try PermissionPolicy.hostWords(["standard", "host:8780:tag", "site:a.example.com", "host:8781,8782"])
        XCTAssertEqual(ports.map(\.port), [8780, 8781, 8782])
        XCTAssertEqual(ports.first?.tag, true)
        XCTAssertEqual(rest, ["standard", "site:a.example.com"])
        XCTAssertThrowsError(try PermissionPolicy.hostWords(["host:80"]))
        // The policy never gets them: an edit with only host words leaves it as it was; Open does not include them.
        var r = HostRequest(.netPolicy, name: "x")
        r.grant = ["host:8780"]
        let p = NetworkPolicy.permissions(AgentPermissions.preset("agent", base: nil)!, preset: "agent")
        XCTAssertEqual(try HostCore.editedPolicy(p, r), p)
        let open = NetworkPolicy.permissions(AgentPermissions.preset("open", base: nil)!, preset: "open")
        XCTAssertFalse(open.rules.contains { HostRoute.isHost($0.host) })
        XCTAssertEqual(open.evaluateConnection(host: "host.dozable.internal", port: 8780).kind, .allow,
                       "the policy alone would say yes — which is why the route is judged FIRST and the policy never decides it")
        // A site rule may not name the route.
        for bad in ["site:host.dozable.internal", "site:mac.dozable.internal:8780"] {
            XCTAssertThrowsError(try PermissionPolicy.site(bad), bad) { XCTAssertTrue(HostError.from($0).message.contains("host:PORT")) }
        }
        // The fence's policy words skip them too.
        XCTAssertNoThrow(try MacFenceNetwork.policy(words: ["standard", "host:8780"]))
    }

    func testTheLiveEditAndItsSetting() throws {
        var list = try PermissionPolicy.editedHostPorts([], model: nil, grant: [HostPort(port: 8780)], revoke: [], live: true)
        XCTAssertEqual(list, [HostPort(port: 8780, origin: .live)])
        list = try PermissionPolicy.editedHostPorts([HostPort(port: 8780, origin: .launch)], model: nil, grant: [HostPort(port: 8780, tag: true)], revoke: [], live: true)
        XCTAssertEqual(list, [HostPort(port: 8780, tag: true, origin: .launch)], "a launch port keeps its origin; the tag follows")
        // Off: a grant is refused (with what to do); asking for what is already open is not; a deny always works.
        XCTAssertThrowsError(try PermissionPolicy.editedHostPorts([], model: nil, grant: [HostPort(port: 8781)], revoke: [], live: false)) {
            XCTAssertTrue(HostError.from($0).message.contains("network.host_ports_live is off") && HostError.from($0).message.contains("--host-port"))
        }
        XCTAssertEqual(try PermissionPolicy.editedHostPorts([HostPort(port: 8780)], model: nil, grant: [HostPort(port: 8780)], revoke: [], live: false),
                       [HostPort(port: 8780)])
        XCTAssertEqual(try PermissionPolicy.editedHostPorts([HostPort(port: 8780)], model: nil, grant: [], revoke: [HostPort(port: 8780)], live: false), [])
        // The model server's port cannot be denied by host: — it belongs to the model source.
        XCTAssertThrowsError(try PermissionPolicy.editedHostPorts([], model: 11434, grant: [], revoke: [HostPort(port: 11434)], live: true)) {
            XCTAssertTrue(HostError.from($0).message.contains("model server"))
        }
        // Dozable's own ports, port 0, privileged ports: refused at grant.
        HostRoute.protect { [8790] }
        XCTAssertThrowsError(try PermissionPolicy.editedHostPorts([], model: nil, grant: [HostPort(port: 8790)], revoke: [], live: true))
        XCTAssertThrowsError(try PermissionPolicy.checkedLaunchPorts([HostPort(port: 8790)]))
        XCTAssertThrowsError(try PermissionPolicy.checkedLaunchPorts([HostPort(port: 0)]))
        XCTAssertThrowsError(try PermissionPolicy.checkedLaunchPorts([HostPort(port: 443)]))
        // At most 16 with the model server's.
        let fifteen = (0..<15).map { HostPort(port: UInt16(9000 + $0)) }
        XCTAssertEqual(try PermissionPolicy.checkedLaunchPorts(fifteen, model: 11434).count, 15)
        XCTAssertThrowsError(try PermissionPolicy.checkedLaunchPorts(fifteen + [HostPort(port: 9100)], model: 11434))
    }

    func testTheSettingIsInTheClosedSchemaAndOnByDefault() {
        let d = DozableSettings.schema.first { $0.key == SettingKey.hostPortsLive }
        XCTAssertNotNil(d)
        XCTAssertEqual(d?.defaultValue, .bool(true))
        XCTAssertEqual(SettingKey.hostPortsLive, "network.host_ports_live")
        XCTAssertTrue(DozableSettings(text: nil).bool(SettingKey.hostPortsLive))
    }

    func testARefusalToTheRouteSuggestsHostPortOnlyWhileLive() {
        let p = NetworkPolicy.permissions(["model"], preset: "locked")
        let log = [ConnectionRecord(kind: .http, host: "host.dozable.internal", port: 8780, verdict: .denied, rule: "no port"),
                   ConnectionRecord(kind: .http, host: "mac.dozable.internal", port: 8780, verdict: .denied, rule: "no port")]
        var r = PermissionPolicy.report(name: "s", policy: p, base: nil, log: log)
        XCTAssertEqual(r.suggestions.map(\.grant), ["host:8780"], "one suggestion for both names, never a site")
        r = PermissionPolicy.report(name: "s", policy: p, base: nil, log: log, hostPortsLive: false)
        XCTAssertEqual(r.suggestions, [], "off: nothing to suggest (a port is given at start)")
        r = PermissionPolicy.report(name: "s", policy: p, base: nil, log: log, hostPorts: [HostPort(port: 8780)])
        XCTAssertEqual(r.suggestions, [], "opened since: no suggestion")
        XCTAssertEqual(r.hostPorts, [HostPort(port: 8780)])
    }

    func testRecordsBeforeThisChangeHaveNoHostPorts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("doz-hp-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (spec, image) = try DozableImages.spec(name: "a", options: CreateOptions(image: "lab"), store: DozableStore(root: root), environment: [:])
        let cfg = SandboxConfig(name: "a", image: image, spec: spec, workspace: nil)
        var data = try JSONEncoder().encode(cfg)
        var obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertNil(obj["hostPorts"], "nothing written for a sandbox without them")
        obj["localModelPort"] = 11434
        data = try JSONSerialization.data(withJSONObject: obj)
        let back = try JSONDecoder().decode(SandboxConfig.self, from: data)
        XCTAssertNil(back.hostPorts)
        XCTAssertEqual(back.localModelPort, 11434)
        // With them: kept with their origin and tag.
        var c2 = cfg
        c2.hostPorts = [HostPort(port: 8780, tag: true, origin: .live)]
        XCTAssertEqual(try JSONDecoder().decode(SandboxConfig.self, from: try JSONEncoder().encode(c2)).hostPorts, c2.hostPorts)
        // A fence record and grants before them.
        let g = #"{"profile":"agent","keychain":false,"readable":[],"writable":[]}"#
        XCTAssertNil(try JSONDecoder().decode(MacFenceGrants.self, from: Data(g.utf8)).hostPorts)
    }

    func testAFenceWhoseHostPortsGrewIsWidened() {
        var old = MacFenceGrants(profile: "agent", keychain: false, readable: [], writable: [])
        old.hostPorts = [8780]
        var same = old
        XCTAssertFalse(same.widens(old))
        same.hostPorts = nil
        XCTAssertFalse(same.widens(old), "fewer is narrower")
        var more = old
        more.hostPorts = [8780, 8781]
        XCTAssertTrue(more.widens(old))
        var fromNone = MacFenceGrants(profile: "agent", keychain: false, readable: [], writable: [])
        XCTAssertFalse(fromNone.widens(old))
        fromNone.hostPorts = [9000]
        XCTAssertTrue(fromNone.widens(MacFenceGrants(profile: "agent", keychain: false, readable: [], writable: [])), "an older record: none")
        // The record's request carries them (a restart keeps them, live ones as live).
        var rec = MacFenceRecord(profile: "agent", keychain: false, readable: [], writable: [], sessionFolder: "/f",
                                 grants: old, tag: "t", templateVersion: 1, profileSHA256: "x", gitBaseline: nil, stoppedForGit: nil, stoppedPids: nil)
        rec.hostPorts = [HostPort(port: 8780, origin: .live)]
        XCTAssertEqual(rec.request.hostPorts, [HostPort(port: 8780, origin: .live)])
        XCTAssertEqual(try PermissionPolicy.checkedLaunchPorts(rec.request.hostPorts ?? []), [HostPort(port: 8780, origin: .live)])
    }

    func testTheProjectFileAndThePlan() throws {
        let p = try DozableProject.parse("name: box\nimage: lab\nhost_ports: [8780, \"8781:tag\"]\n")
        XCTAssertEqual(p.hostPorts, [HostPort(port: 8780), HostPort(port: 8781, tag: true)])
        XCTAssertEqual(try DozableProject.parse(p.render()).hostPorts, p.hostPorts, "rendered and read back")
        XCTAssertEqual(try DozableProject.parse("name: box\nimage: lab\nhost_ports: 8780\n").hostPorts, [HostPort(port: 8780)])
        for bad in ["host_ports: [80]", "host_ports: [\"8780:x\"]", "host_ports: [0]"] {
            XCTAssertThrowsError(try DozableProject.parse("name: box\nimage: lab\n\(bad)\n"), bad)
        }
        var o = p.createOptions(folder: URL(fileURLWithPath: "/tmp/box"), file: URL(fileURLWithPath: "/tmp/box/doz_project.yaml"))
        XCTAssertEqual(o.hostPorts, p.hostPorts)
        o.allow = ["host:9000"]
        let argv = CreatePlanner.argv(purpose: "create", name: "box", options: o, given: o, choice: nil, settings: DozableSettings(text: nil))
        XCTAssertTrue(argv.contains("--host-port") && argv.contains("8781:tag"), argv.joined(separator: " "))
    }

    func testFactsAndCapabilitiesSayThePorts() {
        // A sandbox with only its model server: the line as before.
        let before = AgentPrompt.values(name: "s", image: "claude-code", cpus: 2, memoryMiB: 2048, workspace: nil,
                                        network: .proxied(.permissions(["model"], preset: "locked")), account: nil, version: "1",
                                        hostname: "m", localModelPort: 11434)
        XCTAssertTrue(before["network.permissions"]!.contains("Of the user's Mac you may reach only port 11434, as http://mac.dozable.internal:11434 (the model server you use)"))
        let with = AgentPrompt.values(name: "s", image: "claude-code", cpus: 2, memoryMiB: 2048, workspace: nil,
                                      network: .proxied(.permissions(["model"], preset: "locked")), account: nil, version: "1",
                                      hostname: "m", localModelPort: 11434, hostPorts: [HostPort(port: 8780)])
        XCTAssertTrue(with["network.permissions"]!.contains("http://host.dozable.internal:8780"), with["network.permissions"]!)
        XCTAssertTrue(with["network.permissions"]!.contains("port 11434"))
        var shape = MacCapabilityShape(session: "s", workdir: "/w", fenced: true)
        XCTAssertFalse(MacFence.capabilities(shape).contains { $0.id == "host-ports" }, "said only when it has some")
        shape.hostPorts = [HostPort(port: 8780, tag: true)]
        let row = MacFence.capabilities(shape).first { $0.id == "host-ports" }
        XCTAssertEqual(row?.state, "8780 (named)")
        XCTAssertTrue(row?.sentence.contains("host.dozable.internal:8780") == true && row?.editable == "live")
    }
}
