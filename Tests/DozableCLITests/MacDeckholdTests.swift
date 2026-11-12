import Foundation
import XCTest
@testable import DozableHost

/// The Mac's PTY holder is found beside the resolved doz, and only a Mac executable will do (never the guest's ELF).
final class MacDeckholdTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("doz-dhm-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("keg"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func write(_ name: String, _ bytes: [UInt8], executable: Bool = true) throws -> URL {
        let u = dir.appendingPathComponent(name)
        try Data(bytes).write(to: u)
        try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: u.path)
        return u
    }

    func testOnlyAMacExecutableWill() throws {
        XCTAssertNil(MacDeckhold.problem(URL(fileURLWithPath: "/bin/ls")), "a real Mac executable")
        let elf = try write("elf", [0x7F, 0x45, 0x4C, 0x46, 2, 1, 1, 0])
        XCTAssertTrue(MacDeckhold.problem(elf)?.contains("guest's Linux holder") == true)
        let script = try write("script", Array("#!/bin/sh\n".utf8))
        XCTAssertTrue(MacDeckhold.problem(script)?.contains("not a Mac executable") == true)
        let plain = try write("plain", [0xCF, 0xFA, 0xED, 0xFE], executable: false)
        XCTAssertTrue(MacDeckhold.problem(plain)?.contains("not executable") == true)
        XCTAssertTrue(MacDeckhold.problem(dir.appendingPathComponent("none"))?.contains("not there") == true)
        XCTAssertTrue(MacDeckhold.problem(dir)?.contains("not a file") == true)
    }

    func testFoundBesideTheResolvedDoz() throws {
        // keg/doz + keg/deckhold-mac, and bin/doz a link into the keg (as Homebrew lays it out).
        let doz = dir.appendingPathComponent("keg/doz")
        try FileManager.default.copyItem(atPath: "/bin/ls", toPath: doz.path)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("bin"), withIntermediateDirectories: true)
        let link = dir.appendingPathComponent("bin/doz")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: doz)
        var r = MacDeckhold.locate(executable: link.path, environment: [:])
        XCTAssertNil(r.url)
        XCTAssertNotNil(r.why, "none beside it yet")
        try FileManager.default.copyItem(atPath: "/bin/ls", toPath: dir.appendingPathComponent("keg/deckhold-mac").path)
        r = MacDeckhold.locate(executable: link.path, environment: [:])
        XCTAssertEqual(r.url?.resolvingSymlinksInPath().path, dir.appendingPathComponent("keg/deckhold-mac").resolvingSymlinksInPath().path)
    }

    func testTheOverrideIsGuardedOnly() throws {
        let other = dir.appendingPathComponent("other")
        try FileManager.default.copyItem(atPath: "/bin/ls", toPath: other.path)
        // XCTest is a guarded run: the override counts.
        XCTAssertEqual(MacDeckhold.locate(executable: "/nonexistent/doz", environment: ["DOZ_DECKHOLD_MAC": other.path]).url, other)
        // Outside one (DOZ_TEST_REAL_MAC=1 turns the guard off): ignored — beside the executable only.
        XCTAssertNil(MacDeckhold.locate(executable: "/nonexistent/doz", environment: ["DOZ_DECKHOLD_MAC": other.path, "DOZ_TEST_REAL_MAC": "1"]).url)
        // An override that is not a Mac holder is refused, with why.
        let elf = try write("elf2", [0x7F, 0x45, 0x4C, 0x46])
        let bad = MacDeckhold.locate(executable: "/nonexistent/doz", environment: ["DOZ_DECKHOLD_MAC": elf.path])
        XCTAssertNil(bad.url)
        XCTAssertTrue(bad.why?.contains("guest's") == true)
    }
}
