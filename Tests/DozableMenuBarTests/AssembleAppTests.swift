import XCTest

/// `Scripts/assemble-app.sh`: the release bundle is exactly what it always was (the template stamped, the agent plist
/// as is, nothing else); `--dev` makes "Dozable Dev.app" with its own identifier, name and keys, and NO login agent.
/// The executable is a tiny arm64 program compiled here (the script checks it is one); nothing is signed or opened.
final class AssembleAppTests: XCTestCase {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    var dir: URL!
    var exe: String!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("assemble-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let src = dir.appendingPathComponent("main.c").path
        try "int main(void) { return 0; }\n".write(toFile: src, atomically: true, encoding: .utf8)
        exe = dir.appendingPathComponent("Dozable").path
        let cc = run(["/usr/bin/xcrun", "clang", "-arch", "arm64", src, "-o", exe])
        try XCTSkipUnless(cc.code == 0, "no C compiler for the stand-in executable: \(cc.out)")
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    @discardableResult
    func run(_ argv: [String], env: [String: String]? = nil) -> (code: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: argv[0])
        p.arguments = Array(argv.dropFirst())
        if let env { p.environment = env }
        let o = Pipe()
        p.standardOutput = o
        p.standardError = o
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return (127, "\(error)") }
        let d = o.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: d, as: UTF8.self))
    }

    func assemble(_ extra: [String]) -> (code: Int32, out: String) {
        run(["/bin/bash", Self.repo.appendingPathComponent("Scripts/assemble-app.sh").path,
             "--exe", exe, "--version", "1.2.3", "--out", dir.appendingPathComponent("out").path] + extra)
    }

    func files(_ app: URL) -> [String] {
        let e = FileManager.default.enumerator(atPath: app.path)
        return ((e?.allObjects as? [String]) ?? []).sorted()
    }

    func info(_ app: URL) throws -> [String: Any] {
        let d = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any])
    }

    func testTheReleaseBundleIsUnchanged() throws {
        let r = assemble([])
        XCTAssertEqual(r.code, 0, r.out)
        let app = dir.appendingPathComponent("out/Dozable.app")
        XCTAssertEqual(files(app), ["Contents", "Contents/Info.plist", "Contents/Library", "Contents/Library/LaunchAgents",
                                    "Contents/Library/LaunchAgents/com.dozable.app.daemon.plist", "Contents/MacOS",
                                    "Contents/MacOS/Dozable", "Contents/PkgInfo", "Contents/Resources"])
        // The Info.plist is the template with its version stamped — byte for byte, nothing added.
        let template = try String(contentsOf: Self.repo.appendingPathComponent("Resources/MenuBar/Info.plist"), encoding: .utf8)
        XCTAssertEqual(try String(contentsOf: app.appendingPathComponent("Contents/Info.plist"), encoding: .utf8),
                       template.replacingOccurrences(of: "__VERSION__", with: "1.2.3"))
        XCTAssertEqual(try Data(contentsOf: app.appendingPathComponent("Contents/Library/LaunchAgents/com.dozable.app.daemon.plist")),
                       try Data(contentsOf: Self.repo.appendingPathComponent("Resources/MenuBar/com.dozable.app.daemon.plist")))
        XCTAssertEqual(try String(contentsOf: app.appendingPathComponent("Contents/PkgInfo"), encoding: .utf8), "APPL????")
        let i = try info(app)
        XCTAssertEqual(i["CFBundleIdentifier"] as? String, "com.dozable.app")
        XCTAssertNil(i["DozableFlavour"])
        XCTAssertEqual(assemble(["--commit", "abcdef1"]).code, 1, "--commit is the dev build's only")
    }

    func testDevGivesTheDevIdentifierKeysAndName() throws {
        let r = assemble(["--dev", "--commit", "0123456789abcdef0123456789abcdef01234567",
                          "--dev-doz", "/Users/someone/.local/doz-dev/bin/doz", "--dev-config-home", "/Users/someone/.local/doz-dev/config",
                          "--dev-store", "/Users/someone/doz-dev-store"])
        XCTAssertEqual(r.code, 0, r.out)
        let app = dir.appendingPathComponent("out/Dozable Dev.app")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("out/Dozable.app").path), "never the release bundle's place")
        XCTAssertEqual(files(app), ["Contents", "Contents/Info.plist", "Contents/MacOS", "Contents/MacOS/Dozable", "Contents/PkgInfo",
                                    "Contents/Resources"], "no login agent in the dev build")
        let i = try info(app)
        XCTAssertEqual(i["CFBundleIdentifier"] as? String, "com.dozable.app.dev")
        XCTAssertEqual(i["CFBundleName"] as? String, "Dozable Dev")
        XCTAssertEqual(i["CFBundleDisplayName"] as? String, "Dozable Dev")
        XCTAssertEqual(i["CFBundleExecutable"] as? String, "Dozable")
        XCTAssertEqual(i["CFBundleShortVersionString"] as? String, "1.2.3")
        XCTAssertEqual(i["LSUIElement"] as? Bool, true)
        XCTAssertEqual(i["DozableFlavour"] as? String, "dev")
        XCTAssertEqual(i["DozableDevDoz"] as? String, "/Users/someone/.local/doz-dev/bin/doz")
        XCTAssertEqual(i["DozableDevConfigHome"] as? String, "/Users/someone/.local/doz-dev/config")
        XCTAssertEqual(i["DozableDevStore"] as? String, "/Users/someone/doz-dev-store")
        XCTAssertEqual(i["DozableDevCommit"] as? String, "0123456789abcdef0123456789abcdef01234567")
    }

    func testDevDefaultsAreExpandedFromHome() throws {
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = "/Users/someone"
        let r = run(["/bin/bash", Self.repo.appendingPathComponent("Scripts/assemble-app.sh").path, "--dev",
                     "--exe", exe, "--version", "1.2.3", "--out", dir.appendingPathComponent("out").path], env: env)
        XCTAssertEqual(r.code, 0, r.out)
        let i = try info(dir.appendingPathComponent("out/Dozable Dev.app"))
        XCTAssertEqual(i["DozableDevDoz"] as? String, "/Users/someone/.local/doz-dev/bin/doz")
        XCTAssertEqual(i["DozableDevConfigHome"] as? String, "/Users/someone/.local/doz-dev/config")
        XCTAssertEqual(i["DozableDevStore"] as? String, "/Users/someone/doz-dev-store")
        XCTAssertNil(i["DozableDevCommit"])
        XCTAssertEqual(assemble(["--dev", "--dev-doz", "relative/doz"]).code, 1, "never a relative doz")
        XCTAssertEqual(assemble(["--dev", "--dev-store", "relative/store"]).code, 1, "never a relative store")
        XCTAssertEqual(assemble(["--dev", "--commit", "not-a-sha"]).code, 1)
    }
}
