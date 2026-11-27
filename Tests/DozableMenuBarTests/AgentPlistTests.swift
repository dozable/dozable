import XCTest
@testable import DozableMenuBarCore

/// The login agent's plist (Resources/MenuBar/com.dozable.app.daemon.plist, sealed into the bundle by assemble-app.sh):
/// exactly the design's keys and values — never KeepAlive, Sockets or MachServices — launchd runs the app's own
/// executable with `--launch-daemon`, and its label is doz's reserved one (`DaemonLoginItem.appLabel`; DozableCLITests
/// checks the same file against doz's constant).
final class AgentPlistTests: XCTestCase {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let file = AgentPlistTests.repo.appendingPathComponent("Resources/MenuBar/com.dozable.app.daemon.plist")

    func plist() throws -> [String: Any] {
        try XCTUnwrap(try PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil) as? [String: Any])
    }

    func testTheFileIsExactlyTheDesign() throws {
        let p = try plist()
        XCTAssertEqual(AgentPlist.problems(p), [])
        XCTAssertEqual(Set(p.keys), ["Label", "BundleProgram", "ProgramArguments", "RunAtLoad", "StartInterval", "LimitLoadToSessionType",
                                     "AbandonProcessGroup", "ProcessType"])
        XCTAssertEqual(p["Label"] as? String, "com.dozable.app.daemon")
        XCTAssertEqual(p["BundleProgram"] as? String, "Contents/MacOS/Dozable")
        XCTAssertEqual(p["ProgramArguments"] as? [String], ["Dozable", "--launch-daemon"])
        XCTAssertEqual(p["StartInterval"] as? Int, 900)
        XCTAssertEqual(p["ProcessType"] as? String, "Interactive", "Standard held the daemon and its sessions at utility QoS")
        for never in ["KeepAlive", "Sockets", "MachServices", "Program", "EnvironmentVariables", "StandardOutPath"] { XCTAssertNil(p[never], never) }
        XCTAssertEqual(AgentPlist.label, "com.dozable.app.daemon")
        XCTAssertEqual(AgentPlist.fileName, "com.dozable.app.daemon.plist")
        XCTAssertEqual(AgentPlist.bundlePath, "Contents/Library/LaunchAgents/com.dozable.app.daemon.plist")
        XCTAssertEqual((p["ProgramArguments"] as? [String])?.last, AgentPlist.launchFlag)
    }

    func testAnyOtherKeyOrValueIsNamed() throws {
        var p = try plist()
        p["KeepAlive"] = true
        XCTAssertEqual(AgentPlist.problems(p), ["keys it must not have: KeepAlive"])
        p = try plist()
        p.removeValue(forKey: "AbandonProcessGroup")
        XCTAssertEqual(AgentPlist.problems(p), ["keys missing: AbandonProcessGroup"])
        p = try plist()
        p["RunAtLoad"] = 1                      // a number, not a boolean
        XCTAssertEqual(AgentPlist.problems(p).count, 1)
        p = try plist()
        p["ProgramArguments"] = ["/bin/sh", "-c", "doz daemon start"]
        XCTAssertEqual(AgentPlist.problems(p).count, 1)
        p = try plist()
        p["Label"] = "com.dozable.daemon.0badf00d"
        XCTAssertEqual(AgentPlist.problems(p).count, 1)
    }

    /// The release and assemble-app.sh check the file with Scripts/check-agent-plist.py — the same rule, the same answer.
    func testTheScriptAgrees() throws {
        let script = Self.repo.appendingPathComponent("Scripts/check-agent-plist.py").path
        func run(_ path: String) -> Int32 {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            p.arguments = [script, path]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
            return p.terminationStatus
        }
        XCTAssertEqual(run(file.path), 0)
        var bad = try plist()
        bad["KeepAlive"] = true
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("agent-\(UUID().uuidString).plist")
        try PropertyListSerialization.data(fromPropertyList: bad, format: .xml, options: 0).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        XCTAssertEqual(run(tmp.path), 1)
    }
}
