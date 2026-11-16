import Darwin
import Foundation
import XCTest
@testable import DozableHost

/// 693: the path a new daemon is started from — a Homebrew keg maps to its formula's `opt` link (the keg goes at
/// `brew cleanup`), anything else stays itself — and a new program at that path counts as this daemon's program replaced.
final class StableExecutableTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("stable-exe-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    /// `<root>/libexec/doz/doz` (an empty file).
    @discardableResult
    private func program(_ root: URL, _ contents: String = "") throws -> URL {
        let libexec = root.appendingPathComponent("libexec/doz")
        try FileManager.default.createDirectory(at: libexec, withIntermediateDirectories: true)
        let exe = libexec.appendingPathComponent("doz")
        try Data(contents.utf8).write(to: exe)
        return exe
    }

    /// `<prefix>/opt/<formula>` → `../Cellar/<formula>/<version>`, as `brew link` makes it.
    private func opt(_ prefix: URL, _ formula: String, _ version: String) throws {
        let o = prefix.appendingPathComponent("opt")
        try FileManager.default.createDirectory(at: o, withIntermediateDirectories: true)
        let link = o.appendingPathComponent(formula)
        try? FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "../Cellar/\(formula)/\(version)")
    }

    func testAKegMapsToItsFormulasOptLink() throws {
        for (prefix, formula) in [("opt/homebrew", "doz"), ("opt/homebrew", "doz-canary"), ("usr/local", "doz"), ("usr/local", "doz-beta")] {
            let p = dir.appendingPathComponent(prefix)
            let exe = try program(p.appendingPathComponent("Cellar/\(formula)/0.50.4"))
            try opt(p, formula, "0.50.4")
            XCTAssertEqual(StableExecutable.path(for: exe.path), p.appendingPathComponent("opt/\(formula)/libexec/doz/doz").path, "\(prefix) \(formula)")
            // Asked through the opt link itself (how the formula's bin/doz reaches it): the same.
            XCTAssertEqual(StableExecutable.path(for: p.appendingPathComponent("opt/\(formula)/libexec/doz/doz").path),
                           p.appendingPathComponent("opt/\(formula)/libexec/doz/doz").path)
        }
    }

    func testAKegWithoutAnOptLinkStaysItself() throws {
        let exe = try program(dir.appendingPathComponent("opt/homebrew/Cellar/doz/0.50.4"))
        XCTAssertEqual(StableExecutable.path(for: exe.path), exe.path)
    }

    func testATarballOrInstallCliPrefixAndAPlainBuildStayThemselves() throws {
        let local = try program(dir.appendingPathComponent("home/.local"))
        XCTAssertEqual(StableExecutable.path(for: local.path), local.path, "the folder is swapped in place")
        XCTAssertNotNil(StableExecutable.installation(executable: local.path))
        let plain = dir.appendingPathComponent("build/debug/doz")
        try FileManager.default.createDirectory(at: plain.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: plain)
        XCTAssertEqual(StableExecutable.path(for: plain.path), plain.path)
        // A link to it resolves to it.
        let link = dir.appendingPathComponent("doz-link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: plain.path)
        XCTAssertEqual(StableExecutable.path(for: link.path), plain.path)
        // Not one of doz's formulas: not a keg.
        let other = try program(dir.appendingPathComponent("opt/homebrew/Cellar/dozzz/1.0.0"))
        try opt(dir.appendingPathComponent("opt/homebrew"), "dozzz", "1.0.0")
        XCTAssertEqual(StableExecutable.path(for: other.path), other.path)
    }

    /// The brew-upgrade case: the old keg stays on disk (no cleanup), `opt/doz` now leads to the new keg. A daemon of the
    /// old keg sees its program REPLACED (and so restarts in place from the opt link) — without the stable path it saw no
    /// change at all and an always-on daemon stayed old forever.
    func testANewKegBehindTheOptLinkIsAReplacedProgram() throws {
        let p = dir.appendingPathComponent("opt/homebrew")
        let old = try program(p.appendingPathComponent("Cellar/doz/0.50.4"), "old")
        try opt(p, "doz", "0.50.4")
        let stable = StableExecutable.path(for: old.path)
        let started = try XCTUnwrap(ExecutableIdentity.of(path: old.path))
        func change() -> ExecutableIdentity.Change? {
            started.change(now: ExecutableIdentity.of(path: started.path), stableNow: ExecutableIdentity.of(path: stable))
        }
        XCTAssertNil(change(), "nothing changed")
        try program(p.appendingPathComponent("Cellar/doz/0.50.5"), "new")
        XCTAssertNil(change(), "a new keg installed but not linked yet: nothing")
        try opt(p, "doz", "0.50.5")
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.path), "the old keg is still there")
        XCTAssertNil(started.change(now: ExecutableIdentity.of(path: started.path)), "by its own path alone: no change (the bug)")
        XCTAssertEqual(change(), .replaced, "by its stable path: replaced")
        // brew cleanup then removes the old keg: removed (its own file gone) — the stable path is still there to start from.
        try FileManager.default.removeItem(at: p.appendingPathComponent("Cellar/doz/0.50.4"))
        XCTAssertEqual(change(), .removed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stable))
    }

    func testTheStablePathAddsNothingWhenItIsTheProgramItself() throws {
        let exe = try program(dir.appendingPathComponent("home/.local"), "a")
        let started = try XCTUnwrap(ExecutableIdentity.of(path: exe.path))
        XCTAssertNil(started.change(now: ExecutableIdentity.of(path: exe.path), stableNow: ExecutableIdentity.of(path: exe.path)))
        XCTAssertNil(started.change(now: ExecutableIdentity.of(path: exe.path), stableNow: nil))
        // An install renames a new file over it: replaced, as before.
        let next = exe.deletingLastPathComponent().appendingPathComponent(".doz.new")
        try Data("b".utf8).write(to: next)
        XCTAssertEqual(rename(next.path, exe.path), 0)
        XCTAssertEqual(started.change(now: ExecutableIdentity.of(path: exe.path), stableNow: nil), .replaced)
    }
}
