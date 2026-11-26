import ArgumentParser
import Foundation
import XCTest
@testable import DozableCLI
@testable import DozableHost

/// 775 (cold fixes): a usage error under `--json` is the JSON error every other failure is; `doz onboard --claude-account
/// none` leaves no account `mac` (and `doz account default mac` takes the Mac's login back). No VM, no real keychain.
final class ColdFixesTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("doz-cold-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("home"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    // MARK: --json usage errors

    func parseError(_ args: [String]) -> Error? {
        do { _ = try DozableCommand.parseAsRoot(args); return nil } catch { return error }
    }

    func testAUsageErrorUnderJSONIsTheJSONError() throws {
        // An unknown option, anywhere `--json` is on the line.
        let unknown = try XCTUnwrap(parseError(["workspace", "list", "--no-such-flag", "--json"]))
        let e = try XCTUnwrap(UsageJSON.error(unknown, args: ["workspace", "list", "--no-such-flag", "--json"]))
        XCTAssertEqual(e.code, .usage)
        XCTAssertTrue(e.message.contains("--no-such-flag"), e.message)
        XCTAssertFalse(e.message.hasPrefix("Error:"), e.message)
        XCTAssertFalse(e.message.contains("\n"), "one line, never the usage text")
        XCTAssertEqual(ErrorAnswer(e).error.exit, 64)
        let data = try JSONEncoder().encode(ErrorAnswer(e))
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual((obj["error"] as? [String: Any])?["code"] as? String, "usage")
        // A missing argument.
        let missing = try XCTUnwrap(parseError(["workspace", "show", "--json"]))
        XCTAssertEqual(UsageJSON.error(missing, args: ["workspace", "show", "--json"])?.code, .usage)
        // A renamed option keeps its hint.
        let renamed = try XCTUnwrap(parseError(["create", "x", "--workspace", "/tmp", "--json"]))
        XCTAssertTrue(UsageJSON.error(renamed, args: ["create", "x", "--workspace", "/tmp", "--json"])?.message.contains("was renamed") == true)
        // Without --json: as before (ArgumentParser's own text).
        XCTAssertNil(UsageJSON.error(unknown, args: ["workspace", "list", "--no-such-flag"]))
        // Help is not an error, and a command's own exit has said its error already.
        XCTAssertNil(UsageJSON.error(CleanExit.helpRequest(), args: ["workspace", "list", "--help", "--json"]))
        XCTAssertNil(UsageJSON.error(ExitCode(64), args: ["--json"]))
        XCTAssertNil(UsageJSON.error(ExitCode(3), args: ["--json"]))
    }

    /// `doz workspace new --path` is told `--folder` (the parser's nearest spelling was `--site`); a command with no
    /// `--folder` keeps the parser's own suggestion.
    func testPathSuggestsFolder() throws {
        let args = ["workspace", "new", "y", "--path", "/tmp"]
        let e = try XCTUnwrap(parseError(args))
        let said = OptionSuggestion.corrected(DozableCommand.fullMessage(for: e), args: args)
        XCTAssertTrue(said.contains("Unknown option '--path'. Did you mean '--folder'?"), said)
        XCTAssertFalse(said.contains("'--site'"), said)
        XCTAssertTrue(said.contains("Usage:"), "the rest of the parser's text is kept")
        let json = try XCTUnwrap(UsageJSON.error(e, args: args + ["--json"]))
        XCTAssertTrue(json.message.contains("Did you mean '--folder'?"), json.message)
        // `--path=DIR` too.
        let eq = ["workspace", "new", "y", "--path=/tmp"]
        let e2 = try XCTUnwrap(parseError(eq))
        XCTAssertTrue(OptionSuggestion.corrected(DozableCommand.fullMessage(for: e2), args: eq).contains("'--folder'"))
        // A command that takes no --folder: unchanged.
        let other = ["workspace", "list", "--path", "/tmp"]
        let e3 = try XCTUnwrap(parseError(other))
        let plain = DozableCommand.fullMessage(for: e3)
        XCTAssertEqual(OptionSuggestion.corrected(plain, args: other), plain)
    }

    // MARK: --claude-account none

    func core() async -> HostCore {
        let s = CredentialServices(keychain: FakeKeychain(), verifier: FakeVerifier(answer: .verified), claudeBinary: { nil },
                                   home: root.appendingPathComponent("home"), keepaliveRunner: FakeRunner(), isClaudeRunning: { false },
                                   watchInterval: .seconds(3600))
        let c = HostCore(store: DozableStore(root: root), readOnly: false, version: "test", services: s)
        await c.load()
        return c
    }

    func rows(_ c: HostCore, _ r: HostRequest, file: StaticString = #filePath, line: UInt = #line) async throws -> [AccountRow] {
        let m = await c.handle(r)
        XCTAssertNil(m.error, m.error?.message ?? "", file: file, line: line)
        return try XCTUnwrap(m.result, file: file, line: line).decode([AccountRow].self)
    }

    func defaultRequest(_ account: String, macLogin: String? = nil) -> HostRequest {
        var r = HostRequest(.accountDefault)
        r.account = account
        r.macLogin = macLogin
        return r
    }

    func testDecliningTheMacsClaudeLoginLeavesNoAccountMac() async throws {
        let c = await core()
        let first = try await rows(c, HostRequest(.accountList))
        XCTAssertTrue(first.contains { $0.name == "mac" }, "the built-in account, as always")
        // Declined: no account mac, the default none — and it stays so (a restart reads the file).
        var r = try await rows(c, defaultRequest("none", macLogin: "none"))
        XCTAssertFalse(r.contains { $0.name == "mac" }, "\(r.map(\.name))")
        let store = AccountStore(store: DozableStore(root: root))
        XCTAssertEqual(store.load().macDeclined, true)
        XCTAssertEqual(store.load().defaultAccount, "none")
        XCTAssertFalse(store.load().accounts.contains { $0.name == "mac" })
        let again = await core()
        r = try await rows(again, HostRequest(.accountList))
        XCTAssertFalse(r.contains { $0.name == "mac" })
        let json = String(decoding: try JSONEncoder().encode(r), as: UTF8.self)
        XCTAssertFalse(json.contains("\"mac\""), json)
        // Named the default again: the Mac's login is the account mac again.
        r = try await rows(again, defaultRequest("mac"))
        XCTAssertTrue(r.contains { $0.name == "mac" && $0.isDefault })
        XCTAssertNil(store.load().macDeclined)
        // And `--claude-account mac` (macLogin mac) after another decline.
        _ = try await rows(again, defaultRequest("none", macLogin: "none"))
        r = try await rows(again, defaultRequest("mac", macLogin: "mac"))
        XCTAssertTrue(r.contains { $0.name == "mac" && $0.isDefault })
    }

    func testTheClaudeAccountFlag() throws {
        XCTAssertNoThrow(try Onboard.parse(["--claude-account", "none", "--yes"]))
        XCTAssertNoThrow(try Onboard.parse(["--claude-account", "mac"]))
        XCTAssertNoThrow(try Onboard.parse(["--claude-account", "later"]))
        XCTAssertThrowsError(try Onboard.parse(["--claude-account", "chatgpt"]))
    }
}
