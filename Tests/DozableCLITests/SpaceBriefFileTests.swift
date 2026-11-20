import Foundation
import XCTest
@testable import DozableHost
@testable import DozableCLI

/// The brief of a space workspace is its file, under one rule set: never a link anywhere in its path, a regular file of
/// this user with one name, at most 256 KiB of UTF-8, under the home folder and never in the store, `~/.claude` or
/// `~/Library`; written by temp-and-rename with its mode kept. An edit (the dashboard's, `--prompt-file`) writes the file,
/// never the store's `brief.md`; a stale `ifBrief` is refused; `up` never writes it; `show --space` says where it is.
final class SpaceBriefFileTests: XCTestCase {
    var home: String!
    var store: String!

    override func setUpWithError() throws {
        home = WorkspaceStore.resolved("/tmp") + "/doz-brief-\(UUID().uuidString.prefix(8))"
        store = home + "/store"
        try FileManager.default.createDirectory(atPath: store, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(atPath: home) }

    func testThePlaceRules() {
        XCTAssertNil(SpaceBriefFile.placeRefusal(home + "/work/BRIEF.md", home: home, store: store))
        XCTAssertNotNil(SpaceBriefFile.placeRefusal("/etc/BRIEF.md", home: home, store: store), "outside the home")
        XCTAssertNotNil(SpaceBriefFile.placeRefusal(store + "/BRIEF.md", home: home, store: store), "the store")
        XCTAssertNotNil(SpaceBriefFile.placeRefusal(home + "/.claude/BRIEF.md", home: home, store: store))
        XCTAssertNotNil(SpaceBriefFile.placeRefusal(home + "/Library/BRIEF.md", home: home, store: store))
        XCTAssertNotNil(SpaceBriefFile.placeRefusal(home + "/work/../.claude/x.md", home: home, store: store))
        XCTAssertNotNil(SpaceBriefFile.placeRefusal("work/BRIEF.md", home: home, store: store))
    }

    func testReadAndWriteKeepTheRules() throws {
        let dir = home + "/work"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/BRIEF.md"
        try "one\n".write(toFile: path, atomically: true, encoding: .utf8)
        chmod(path, 0o640)
        let r = try SpaceBriefFile.read(path, store: store, home: home)
        XCTAssertEqual(r.text, "one\n")
        // A stale sha: refused, nothing written.
        XCTAssertThrowsError(try SpaceBriefFile.write("two\n", to: path, ifSHA: String(repeating: "0", count: 64), store: store, home: home))
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "one\n")
        let w = try SpaceBriefFile.write("two\n", to: path, ifSHA: r.sha256, store: store, home: home)
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "two\n")
        XCTAssertEqual(w.sha256, WorkspaceStore.sha256(Data("two\n".utf8)))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue, 0o640, "its mode kept")
        // A link: refused, never followed or written through.
        let target = home + "/target.md"
        try "target\n".write(toFile: target, atomically: true, encoding: .utf8)
        let link = dir + "/LINK.md"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
        XCTAssertThrowsError(try SpaceBriefFile.read(link, store: store, home: home))
        XCTAssertThrowsError(try SpaceBriefFile.write("x", to: link, ifSHA: nil, store: store, home: home))
        XCTAssertEqual(try String(contentsOfFile: target, encoding: .utf8), "target\n")
        // A link in the path.
        try FileManager.default.createSymbolicLink(atPath: home + "/linked", withDestinationPath: dir)
        XCTAssertThrowsError(try SpaceBriefFile.read(home + "/linked/BRIEF.md", store: store, home: home))
        // Gone: said so.
        try FileManager.default.removeItem(atPath: path)
        XCTAssertThrowsError(try SpaceBriefFile.read(path, store: store, home: home)) { e in
            XCTAssertTrue(HostError.from(e).message.contains("BRIEF.md is gone from"), HostError.from(e).message)
        }
        // Not UTF-8; too large.
        try Data([0xff, 0xfe, 0x00]).write(to: URL(fileURLWithPath: path))
        XCTAssertThrowsError(try SpaceBriefFile.read(path, store: store, home: home))
        try Data(count: WorkspaceStore.maximumBriefBytes + 1).write(to: URL(fileURLWithPath: path))
        XCTAssertThrowsError(try SpaceBriefFile.read(path, store: store, home: home))
    }
}

/// The brief from the space file, through the daemon: an edit writes the file (never the store's copy), a stale `ifBrief`
/// is refused, the next `up` keeps the edit and never writes the brief, and `show` says where the brief is.
extension WorkspaceLifecycleHostTests {
    func testTheBriefIsTheSpaceFile() async throws {
        try await withBriefHome {
            let c = await lcore()
            let s = try spaceFiles(agents: """
              w1: { kind: claude-code, prompt: one }
            """)
            _ = try acted(try await spaceUpAct(c, try spaceRequest(s)))
            let showM = await ws(c, .workspaceShow, "sp") { $0.withBrief = true }
            let shown = try XCTUnwrap(showM.result).decode(WorkspaceDetail.self)
            XCTAssertEqual(shown.briefText, "Make the thing.\n")
            XCTAssertEqual(shown.space?.brief, "BRIEF.md")
            XCTAssertTrue(shown.space?.up == true)
            let sha = shown.brief.sha256
            // A stale ifBrief: refused, the file untouched.
            var m = await ws(c, .workspaceEdit, "sp") { $0.brief = "stale\n"; $0.ifBrief = String(repeating: "0", count: 64) }
            XCTAssertEqual(m.error?.code, .invalidPhase)
            XCTAssertEqual(try String(contentsOfFile: s.brief, encoding: .utf8), "Make the thing.\n")
            // An edit (the dashboard's card sends exactly this): the file is written; the store's copy stays empty.
            m = await ws(c, .workspaceEdit, "sp") { $0.brief = "Make the better thing.\n"; $0.ifBrief = sha }
            XCTAssertNil(m.error, m.error?.message ?? "")
            XCTAssertEqual(try String(contentsOfFile: s.brief, encoding: .utf8), "Make the better thing.\n")
            XCTAssertEqual(WorkspaceStore(store: store).readBrief("sp"), "")
            XCTAssertEqual(try XCTUnwrap(record("sp")).brief.sha256, WorkspaceStore.sha256(Data("Make the better thing.\n".utf8)))
            // The next up keeps it: never writes the brief.
            let before = try Data(contentsOf: URL(fileURLWithPath: s.brief))
            _ = try acted(try await spaceUpAct(c, try spaceRequest(s)))
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: s.brief)), before)
            // The file gone: the brief is "gone", an edit refused naming it.
            try FileManager.default.removeItem(atPath: s.brief)
            m = await ws(c, .workspaceEdit, "sp") { $0.brief = "x\n" }
            XCTAssertEqual(m.error?.code, .notFound)
            XCTAssertTrue(m.error?.message.contains("BRIEF.md is gone from") == true, m.error?.message ?? "")
        }
    }
}
