import ArgumentParser
import Foundation
import XCTest
@testable import DozableCLI
@testable import DozableHost

/// `doz docs` and the manual a build carries (`EmbeddedManual`, Scripts/manual-bundle.py): page lookup, the JSON
/// answer's shape, nothing of it reaching the network or a daemon, this version's URL (never the version-less one — the
/// stable release's), and the bundled llms.txt linking only inside itself.
final class DocsCommandTests: XCTestCase {
    /// Every version-less manual URL: the stable release's manual.
    static let versionLess = #"https?://(?:www\.)?dozable\.com/(?:llms(?:-full)?\.txt|docs/[^\s)]*)"#

    func scratch() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("doz-docs-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: d) }
        return d
    }

    /// The repository's manual bundled by the release's own script into `dir/manual`.
    func bundle(into dir: URL, version: String = "0.52.50") throws -> URL {
        let out = dir.appendingPathComponent("manual")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = ["-I", Pins.packageRoot.appendingPathComponent("Scripts/manual-bundle.py").path,
                       "--manual", Pins.packageRoot.appendingPathComponent("docs/manual").path,
                       "--out", out.path, "--version", version, "--check"]
        p.standardOutput = FileHandle.nullDevice
        let err = Pipe()
        p.standardError = err
        try p.run()
        p.waitUntilExit()
        let said = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(p.terminationStatus, 0, said)
        return out
    }

    // MARK: pages

    func testAPageIsFoundByItsNameOrNumber() {
        let pages = ["01-getting-started.md", "14-letting-another-agent-drive.md", "37-workspaces.md"].compactMap(EmbeddedManual.Page.init(file:))
        XCTAssertEqual(pages.count, 3)
        for q in ["workspaces", "Workspaces", "37", "037", "37-workspaces", "37-workspaces.md", " workspaces "] {
            XCTAssertEqual(EmbeddedManual.lookup(q, in: pages)?.file, "37-workspaces.md", q)
        }
        XCTAssertEqual(EmbeddedManual.lookup("1", in: pages)?.name, "getting-started")
        XCTAssertEqual(EmbeddedManual.lookup("letting-another-agent-drive", in: pages)?.number, 14)
        for q in ["", "work", "99", "no-such-page", "../37-workspaces", "workspaces.txt", String(repeating: "a", count: 200)] {
            XCTAssertNil(EmbeddedManual.lookup(q, in: pages), q)
        }
    }

    func testOnlyNumberedPagesArePages() {
        for f in ["README.md", "llms.txt", "VERSION", "x.md", "1-a.md", "ab-c.md", "01-.md", "01-A.md", "01_a.md", "01-a.txt"] {
            XCTAssertNil(EmbeddedManual.Page(file: f), f)
        }
        XCTAssertEqual(EmbeddedManual.Page(file: "40-history-and-retention.md")?.name, "history-and-retention")
    }

    func testAnUnknownPageIs65WithTheListOfPages() throws {
        let dir = try scratch()
        for f in ["01-getting-started.md", "37-workspaces.md"] { try "# \(f)\n".write(to: dir.appendingPathComponent(f), atomically: true, encoding: .utf8) }
        guard case .failure(let e) = DocsCommand.page("nope", version: "0.52.50", dir: dir) else { return XCTFail("found") }
        XCTAssertEqual(DozableExit.code(for: e), 65)
        XCTAssertTrue(e.message.contains("01 getting-started") && e.message.contains("37 workspaces"), e.message)
        guard case .success(let p) = DocsCommand.page("37", version: "0.52.50", dir: dir) else { return XCTFail("not found") }
        XCTAssertEqual(p.markdown, "# 37-workspaces.md\n")
        XCTAssertEqual(p.name, "workspaces")
        // No manual in this build: said, with this version's URL — never a version-less one.
        guard case .failure(let none) = DocsCommand.page("37", version: "0.52.50", dir: nil) else { return XCTFail("a page with no manual") }
        XCTAssertTrue(none.message.contains("https://dozable.com/v/0.52.50/llms.txt"), none.message)
    }

    // MARK: the answer

    func testTheJSONShape() throws {
        let dir = URL(fileURLWithPath: "/opt/doz/libexec/doz/manual")
        let a = DocsCommand.answer(version: "0.52.50", dir: dir)
        let o = try XCTUnwrap(JSONSerialization.jsonObject(with: HostWire.prettyEncoder.encode(a)) as? [String: Any])
        XCTAssertEqual(Set(o.keys), ["kind", "schema", "version", "local", "llms", "url"])
        XCTAssertEqual(o["kind"] as? String, "DozDocs")
        XCTAssertEqual(o["schema"] as? Int, 1)
        XCTAssertEqual(o["version"] as? String, "0.52.50")
        XCTAssertEqual(o["local"] as? String, "/opt/doz/libexec/doz/manual")
        XCTAssertEqual(o["llms"] as? String, "/opt/doz/libexec/doz/manual/llms.txt")
        XCTAssertEqual(o["url"] as? String, "https://dozable.com/v/0.52.50/llms.txt")
        // No manual: no local, no llms — the URL still this version's.
        let none = try XCTUnwrap(JSONSerialization.jsonObject(with: HostWire.prettyEncoder.encode(DocsCommand.answer(version: "0.52.50", dir: nil))) as? [String: Any])
        XCTAssertNil(none["local"]); XCTAssertNil(none["llms"])
        XCTAssertEqual(none["url"] as? String, "https://dozable.com/v/0.52.50/llms.txt")
    }

    func testTheArguments() throws {
        XCTAssertNoThrow(try DocsCommand.parse([]))
        XCTAssertEqual(try DocsCommand.parse(["workspaces", "--json"]).page, "workspaces")
        XCTAssertTrue(try DocsCommand.parse(["--path"]).path)
        XCTAssertThrowsError(try DocsCommand.parse(["workspaces", "--path"]))
        XCTAssertTrue(DozableCommand.configuration.subcommands.contains { ObjectIdentifier($0) == ObjectIdentifier(DocsCommand.self) })
    }

    // MARK: no network, no daemon

    func testDocsNeverReachesTheNetworkOrTheDaemon() throws {
        // Neither the update check nor the usage statistics run after it (both could open a connection).
        XCTAssertFalse(UpdateHook.applies(["docs"], env: ["DOZ_TEST_UPDATE_TTY": "1"]))
        XCTAssertFalse(UpdateHook.applies(["docs", "workspaces"], env: ["DOZ_TEST_UPDATE_TTY": "1"]))
        XCTAssertFalse(UsageHook.counts(["docs"]))
        XCTAssertFalse(UsageHook.counts(["docs", "--json"]))
        // The command reads its folder and nothing else: no store, no socket (its source names neither).
        let source = try String(contentsOf: Pins.packageRoot.appendingPathComponent("Sources/DozableCLI/DocsCommand.swift"), encoding: .utf8)
        for word in ["HostClient", "HostRequest", "dozableStore", "URLSession", "call(", "autostart"] {
            XCTAssertFalse(source.contains(word), "doz docs uses \(word)")
        }
        let model = try String(contentsOf: Pins.packageRoot.appendingPathComponent("Sources/DozableHost/EmbeddedManual.swift"), encoding: .utf8)
        XCTAssertFalse(model.contains("URLSession") || model.contains("HostClient"), "EmbeddedManual reaches out")
    }

    // MARK: this version's URL, never the version-less one

    func testTheURLIsAlwaysThisVersions() throws {
        let rx = try NSRegularExpression(pattern: Self.versionLess)
        func versionLess(_ s: String) -> Bool { rx.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }
        for v in ["0.52.50", "0.53.0-canary.1", "1.0.0"] {
            for u in [EmbeddedManual.url(version: v), EmbeddedManual.fullURL(version: v), EmbeddedManual.pageURL(version: v, slug: "workspaces")] {
                XCTAssertTrue(u.hasPrefix("https://dozable.com/v/\(v)/"), u)
                XCTAssertFalse(versionLess(u), u)
            }
        }
        // doz help (the root's discussion): doz docs first, then this version's URL, and no version-less manual URL.
        let help = DozableCommand.helpMessage(columns: 1000)
        let docs = try XCTUnwrap(help.range(of: "doz docs"))
        let url = try XCTUnwrap(help.range(of: "https://dozable.com/v/\(DozableCommand.version)/llms.txt"))
        XCTAssertLessThan(docs.lowerBound, url.lowerBound, "doz docs is named before the URL")
        XCTAssertFalse(versionLess(help), "doz --help names a version-less manual URL")
        // The shipped skill, as `doz skill show doz` prints it.
        let skill = try String(contentsOf: Pins.packageRoot.appendingPathComponent("Sources/DozableKit/Resources/skills/doz/SKILL.md"), encoding: .utf8)
        let shown = SkillShow.versioned(skill, version: "0.53.0-canary.1")
        XCTAssertTrue(shown.contains("doz docs"))
        XCTAssertTrue(shown.contains("https://dozable.com/v/0.53.0-canary.1/llms.txt"), "the skill names this version's manual")
        XCTAssertFalse(versionLess(shown), "the skill names a version-less manual URL")
        XCTAssertEqual(SkillShow.versioned(shown, version: "0.53.0-canary.1"), shown, "stamping twice changes nothing")
        // No user-facing source names the version-less manual.
        for dir in ["Sources/DozableCLI", "Sources/DozableHost", "Sources/DozableMenuBarCore", "Sources/DozableMenuBar", "Sources/DozableKit/Resources/skills"] {
            let root = Pins.packageRoot.appendingPathComponent(dir)
            for case let f as URL in FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)! where ["swift", "md"].contains(f.pathExtension) {
                let text = try String(contentsOf: f, encoding: .utf8)
                XCTAssertFalse(versionLess(text), "\(dir)/\(f.lastPathComponent) names a version-less manual URL")
            }
        }
    }

    // MARK: the bundle

    func testTheBundledLlmsTxtLinksOnlyInsideItself() throws {
        let manual = try bundle(into: try scratch())
        let llms = try String(contentsOf: manual.appendingPathComponent("llms.txt"), encoding: .utf8)
        let rx = try NSRegularExpression(pattern: #"\]\(([^)\s]+)\)"#)
        let links = rx.matches(in: llms, range: NSRange(llms.startIndex..., in: llms)).compactMap { Range($0.range(at: 1), in: llms).map { String(llms[$0]) } }
        let pages = EmbeddedManual.pages(in: manual)
        XCTAssertGreaterThanOrEqual(pages.count, 30)
        XCTAssertGreaterThanOrEqual(links.count, pages.count)
        for l in links {
            XCTAssertFalse(l.hasPrefix("http") || l.hasPrefix("/"), "llms.txt: \(l) is not relative")
            XCTAssertTrue(FileManager.default.fileExists(atPath: manual.appendingPathComponent(l).path), "llms.txt: \(l) is missing")
        }
        for p in pages { XCTAssertTrue(links.contains(p.file), "llms.txt does not list \(p.file)") }
        XCTAssertFalse(llms.contains("dozable.com/llms.txt") || llms.contains("dozable.com/docs/"), "llms.txt names the version-less manual")
        XCTAssertTrue(llms.contains("https://dozable.com/v/0.52.50/llms.txt"))
        let full = try String(contentsOf: manual.appendingPathComponent("llms-full.txt"), encoding: .utf8)
        for p in pages { XCTAssertTrue(full.contains("File: \(p.file)\n"), "llms-full.txt has no \(p.file)") }
        XCTAssertEqual(try String(contentsOf: manual.appendingPathComponent("VERSION"), encoding: .utf8), "0.52.50\n")
        // Getting started says how the Mac's login stays fresh for unattended work.
        let gs = try String(contentsOf: manual.appendingPathComponent("01-getting-started.md"), encoding: .utf8)
        XCTAssertTrue(gs.contains("doz account keepalive") && gs.contains("setup-token"))
        // workspaces, found by name in the bundle, says doz workspace.
        guard case .success(let w) = DocsCommand.page("workspaces", version: "0.52.50", dir: manual) else { return XCTFail("no workspaces page") }
        XCTAssertTrue(w.markdown.contains("doz workspace"))
    }

    func testTheManualIsFoundBesideTheResolvedExecutable() throws {
        let root = try scratch()
        let libexec = root.appendingPathComponent("prefix/libexec/doz")
        try FileManager.default.createDirectory(at: libexec.appendingPathComponent("manual"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("prefix/bin"), withIntermediateDirectories: true)
        try Data().write(to: libexec.appendingPathComponent("doz"))
        let link = root.appendingPathComponent("prefix/bin/doz")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "../libexec/doz/doz")
        XCTAssertNil(EmbeddedManual.directory(executable: link.path), "a folder with no llms.txt is no manual")
        try "# x\n".write(to: libexec.appendingPathComponent("manual/llms.txt"), atomically: true, encoding: .utf8)
        let found = try XCTUnwrap(EmbeddedManual.directory(executable: link.path), "through bin/doz's link")
        XCTAssertEqual(found.resolvingSymlinksInPath().path, libexec.appendingPathComponent("manual").resolvingSymlinksInPath().path)
    }
}
