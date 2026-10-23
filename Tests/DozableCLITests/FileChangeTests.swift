import Foundation
import XCTest
@testable import DozableCLI
@testable import DozableKit
@testable import DozableHost

/// 644: the file explorer panel's writes — the item rule, every change on a real scratch folder (never replacing, links
/// never followed, nothing outside the share), the workspace rules, the isolated sandbox's script and its answers, the
/// kept open folders, the open through the bridge's seam, and the host ops answered in-process (no host, no VM).
final class FileChangeTests: XCTestCase {
    private var root: URL!
    private var ws: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("doz-fchange-\(UUID().uuidString.prefix(8))")
        ws = root.appendingPathComponent("ws")
        try fm.createDirectory(at: ws, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? fm.removeItem(at: root) }

    private func write(_ rel: String, _ text: String = "x\n") throws {
        let u = ws.appendingPathComponent(rel)
        try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: u)
    }
    private func mkdir(_ rel: String) throws { try fm.createDirectory(at: ws.appendingPathComponent(rel), withIntermediateDirectories: true) }
    private func exists(_ rel: String) -> Bool { (try? fm.attributesOfItem(atPath: ws.appendingPathComponent(rel).path)) != nil }
    private func item(_ s: String) -> FileItemPath { FileItemPath.parse(s)! }
    private func code(_ block: () throws -> Any) -> HostError.Code? {
        do { _ = try block(); return nil } catch { return (error as? HostError)?.code }
    }
    private func message(_ block: () throws -> Any) -> String {
        do { _ = try block(); return "" } catch { return (error as? HostError)?.message ?? "\(error)" }
    }

    // MARK: the item

    func testTheItemRule() {
        XCTAssertEqual(FileItemPath.parse("src/a.c"), FileItemPath(guest: "/workspace/src/a.c", rel: "src/a.c", parent: "src", name: "a.c"))
        XCTAssertEqual(FileItemPath.parse("/workspace/a")?.parent, "")
        XCTAssertEqual(FileItemPath.parse("a/../b")?.rel, "b")
        for bad in [nil, "", ".", "/workspace", "/workspace/", "..", "../x", "/etc/passwd", "a\u{1}b", "src/..",
                    String(repeating: "n", count: 256)] {
            XCTAssertNil(FileItemPath.parse(bad), String(describing: bad))
        }
        XCTAssertNotNil(FileItemPath.parse(String(repeating: "n", count: 255)))
    }

    // MARK: the Mac

    func testMakeMoveAndDeleteOnTheMacNeverReplacing() throws {
        try write("a.txt", "a\n")
        XCTAssertEqual(try MacFileChange.mkdir(workspace: ws.path, item: item("src"), rules: nil), "folder")
        XCTAssertEqual(try MacFileChange.create(workspace: ws.path, item: item("src/new.md"), rules: nil), "file")
        XCTAssertTrue(exists("src/new.md"))
        XCTAssertEqual(code { try MacFileChange.mkdir(workspace: ws.path, item: self.item("src"), rules: nil) }, .exists)
        XCTAssertEqual(code { try MacFileChange.create(workspace: ws.path, item: self.item("a.txt"), rules: nil) }, .exists, "never over a file")
        XCTAssertEqual(try String(contentsOf: ws.appendingPathComponent("a.txt"), encoding: .utf8), "a\n")
        XCTAssertEqual(code { try MacFileChange.mkdir(workspace: ws.path, item: self.item("nope/x"), rules: nil) }, .notFound, "never -p")
        // rename and move — never replacing
        XCTAssertEqual(try MacFileChange.move(workspace: ws.path, item: item("a.txt"), to: item("b.txt"), rules: nil), "file")
        XCTAssertEqual(try MacFileChange.move(workspace: ws.path, item: item("b.txt"), to: item("src/b.txt"), rules: nil), "file")
        XCTAssertTrue(exists("src/b.txt"))
        try write("c.txt")
        XCTAssertEqual(code { try MacFileChange.move(workspace: ws.path, item: self.item("c.txt"), to: self.item("src/b.txt"), rules: nil) }, .exists)
        XCTAssertTrue(exists("c.txt"))
        XCTAssertEqual(code { try MacFileChange.move(workspace: ws.path, item: self.item("src"), to: self.item("src/inner"), rules: nil) }, .invalid,
                       "a folder never goes into itself")
        XCTAssertEqual(code { try MacFileChange.move(workspace: ws.path, item: self.item("gone"), to: self.item("x"), rules: nil) }, .notFound)
        // delete: a file; an empty folder; a folder with contents only recursively
        XCTAssertEqual(try MacFileChange.remove(workspace: ws.path, item: item("c.txt"), recursive: false, rules: nil).kind, "file")
        XCTAssertTrue(message { try MacFileChange.remove(workspace: ws.path, item: self.item("src"), recursive: false, rules: nil) }.contains("not empty"))
        XCTAssertTrue(exists("src/new.md"))
        try mkdir("src/deep/er")
        let gone = try MacFileChange.remove(workspace: ws.path, item: item("src"), recursive: true, rules: nil)
        XCTAssertEqual(gone.kind, "folder")
        XCTAssertEqual(gone.items, 5, "src, new.md, b.txt, deep, deep/er")
        XCTAssertFalse(exists("src"))
        try mkdir("empty")
        XCTAssertEqual(try MacFileChange.remove(workspace: ws.path, item: item("empty"), recursive: false, rules: nil).items, 1)
    }

    func testLinksAreNeverFollowedAndNothingOutsideIsTouched() throws {
        let outside = root.appendingPathComponent("outside")
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("keep\n".utf8).write(to: outside.appendingPathComponent("precious"))
        try fm.createSymbolicLink(atPath: ws.appendingPathComponent("out").path, withDestinationPath: outside.path)
        try fm.createSymbolicLink(atPath: ws.appendingPathComponent("file-link").path, withDestinationPath: outside.appendingPathComponent("precious").path)
        // a link out as a parent: refused before anything is made
        XCTAssertEqual(code { try MacFileChange.mkdir(workspace: ws.path, item: self.item("out/x"), rules: nil) }, .invalid)
        XCTAssertEqual(code { try MacFileChange.remove(workspace: ws.path, item: self.item("out/precious"), recursive: false, rules: nil) }, .invalid)
        XCTAssertEqual(code { try MacFileChange.move(workspace: ws.path, item: self.item("file-link"), to: self.item("out/stolen"), rules: nil) }, .invalid)
        // a link itself is the item: deleted, never what it points to
        XCTAssertEqual(try MacFileChange.remove(workspace: ws.path, item: item("file-link"), recursive: false, rules: nil).kind, "link")
        XCTAssertEqual(try MacFileChange.remove(workspace: ws.path, item: item("out"), recursive: true, rules: nil).kind, "link")
        XCTAssertTrue(fm.fileExists(atPath: outside.appendingPathComponent("precious").path))
        // a link INSIDE a folder deleted recursively is removed, never followed
        try mkdir("d")
        try fm.createSymbolicLink(atPath: ws.appendingPathComponent("d/l").path, withDestinationPath: outside.path)
        XCTAssertEqual(try MacFileChange.remove(workspace: ws.path, item: item("d"), recursive: true, rules: nil).items, 2)
        XCTAssertTrue(fm.fileExists(atPath: outside.appendingPathComponent("precious").path))
        // the share itself gone
        XCTAssertEqual(code { try MacFileChange.mkdir(workspace: self.root.appendingPathComponent("gone").path, item: self.item("x"), rules: nil) }, .failed)
    }

    func testTheWorkspaceRulesAreHonoured() throws {
        try write(".dozignore", "secret.env\nprivate\n**/*.key\n")
        try write(".dozreadonly", "config\nREADME.md\n")
        try write("secret.env")
        try write("private/x")
        try write("config/app.yaml")
        try write("README.md")
        try write("src/main.c")
        try write("box/inner.key")
        let lock = try XCTUnwrap(MacFolderListing.rules(workspace: ws.path, mode: .lock, viewOn: true))
        let hide = try XCTUnwrap(MacFolderListing.rules(workspace: ws.path, mode: .hide, viewOn: true))
        // locked / read-only items: never changed
        XCTAssertTrue(message { try MacFileChange.remove(workspace: ws.path, item: self.item("secret.env"), recursive: false, rules: lock) }.contains("locked"))
        XCTAssertTrue(message { try MacFileChange.move(workspace: ws.path, item: self.item("README.md"), to: self.item("r.md"), rules: lock) }.contains("read-only"))
        XCTAssertTrue(message { try MacFileChange.remove(workspace: ws.path, item: self.item(".dozignore"), recursive: false, rules: lock) }.contains("read-only"),
                      "the rule files are read-only")
        XCTAssertTrue(message { try MacFileChange.create(workspace: ws.path, item: self.item("config/new.yaml"), rules: lock) }.contains("read-only"),
                      "nothing new in a read-only folder")
        XCTAssertTrue(message { try MacFileChange.mkdir(workspace: ws.path, item: self.item("private/y"), rules: lock) }.contains("locked"))
        // hidden: not there at all
        XCTAssertEqual(code { try MacFileChange.remove(workspace: ws.path, item: self.item("secret.env"), recursive: false, rules: hide) }, .notFound)
        // a new name the rules would hide / lock / make read-only
        XCTAssertTrue(message { try MacFileChange.create(workspace: ws.path, item: self.item("src/new.key"), rules: hide) }.contains("hide that name"))
        XCTAssertTrue(message { try MacFileChange.create(workspace: ws.path, item: self.item("src/new.key"), rules: lock) }.contains("would lock"))
        XCTAssertTrue(message { try MacFileChange.move(workspace: ws.path, item: self.item("src/main.c"), to: self.item("README.md2/x"), rules: lock) }.contains("no such"))
        XCTAssertTrue(message { try MacFileChange.move(workspace: ws.path, item: self.item("src/main.c"), to: self.item("main.key"), rules: lock) }.contains("would lock"))
        // a folder holding something the rules protect: not deleted, not moved
        XCTAssertTrue(message { try MacFileChange.remove(workspace: ws.path, item: self.item("box"), recursive: true, rules: lock) }.contains("inner.key"))
        XCTAssertTrue(message { try MacFileChange.move(workspace: ws.path, item: self.item("box"), to: self.item("box2"), rules: lock) }.contains("protect"))
        XCTAssertTrue(exists("box/inner.key"))
        // a folder moved where its contents would fall under a rule
        try write("plain/readme.txt")
        try write(".dozreadonly", "config\nREADME.md\nlater/**\n")
        let ro = try XCTUnwrap(MacFolderListing.rules(workspace: ws.path, mode: .lock, viewOn: true))
        XCTAssertTrue(message { try MacFileChange.move(workspace: ws.path, item: self.item("plain"), to: self.item("later"), rules: ro) }.contains("read-only")
                      || message { try MacFileChange.move(workspace: ws.path, item: self.item("plain"), to: self.item("later"), rules: ro) }.contains("fall under"))
        // a visible item: fine
        XCTAssertEqual(try MacFileChange.move(workspace: ws.path, item: item("src/main.c"), to: item("src/app.c"), rules: lock), "file")
        // no rules: anything visible goes
        XCTAssertEqual(try MacFileChange.remove(workspace: ws.path, item: item("secret.env"), recursive: false, rules: nil).kind, "file")
    }

    // MARK: the guest

    func testTheGuestScriptQuotesAndConfines() {
        let s = GuestFileChange.script("mkdir", item: item("it's/a b"))
        XCTAssertTrue(s.contains("d='/workspace/it'\\''s'"))
        XCTAssertTrue(s.contains("n='a b'"))
        XCTAssertTrue(s.contains("inws || { echo 'doz-change outside'"), "the folder must resolve inside /workspace")
        XCTAssertTrue(s.contains("mkdir \"./$n\""), "a name is passed as ./NAME")
        XCTAssertTrue(GuestFileChange.script("new", item: item("f")).contains("set -C"), "never over a file")
        let mv = GuestFileChange.script("move", item: item("a"), to: item("d/b"))
        XCTAssertTrue(mv.contains("t='/workspace/d'") && mv.contains("m='b'") && mv.contains("into-itself"))
        XCTAssertTrue(GuestFileChange.script("rm", item: item("d"), recursive: true).contains("[ 1 = 1 ]"))
        XCTAssertTrue(GuestFileChange.script("rm", item: item("d"), recursive: false).contains("[ 0 = 1 ]"))
    }

    func testTheGuestScriptRunsUnderShInAScratchWorkspaceShape() throws {
        // The script hard-codes /workspace; run it against a copy whose paths are rewritten to the scratch folder.
        func run(_ script: String) throws -> GuestFileChange.Outcome {
            let s = script.replacingOccurrences(of: "/workspace", with: ws.path)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", s]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
            return GuestFileChange.parse(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        }
        // realpath of the scratch folder (macOS /var → /private/var) so `pwd -P` stays inside
        ws = URL(fileURLWithPath: MacFolderListing.realPath(ws.path)!)
        XCTAssertEqual(try run(GuestFileChange.script("mkdir", item: item("d"))), .ok(kind: "folder", count: nil))
        XCTAssertEqual(try run(GuestFileChange.script("mkdir", item: item("d"))), .refused("exists"))
        XCTAssertEqual(try run(GuestFileChange.script("new", item: item("d/f.txt"))), .ok(kind: "file", count: nil))
        XCTAssertEqual(try run(GuestFileChange.script("new", item: item("d/f.txt"))), .refused("exists"))
        XCTAssertEqual(try run(GuestFileChange.script("move", item: item("d/f.txt"), to: item("g.txt"))), .ok(kind: "file", count: nil))
        XCTAssertEqual(try run(GuestFileChange.script("move", item: item("d"), to: item("d/x"))), .refused("into-itself"))
        XCTAssertEqual(try run(GuestFileChange.script("move", item: item("nope"), to: item("x"))), .refused("missing"))
        XCTAssertEqual(try run(GuestFileChange.script("mkdir", item: item("nope/x"))), .refused("missing-parent"))
        try write("d/inner")
        XCTAssertEqual(try run(GuestFileChange.script("rm", item: item("d"))), .refused("notempty"))
        XCTAssertEqual(try run(GuestFileChange.script("rm", item: item("d"), recursive: true)), .ok(kind: "folder", count: 2))
        XCTAssertEqual(try run(GuestFileChange.script("rm", item: item("g.txt"))), .ok(kind: "file", count: 1))
        try fm.createSymbolicLink(atPath: ws.appendingPathComponent("out").path, withDestinationPath: "/tmp")
        XCTAssertEqual(try run(GuestFileChange.script("mkdir", item: item("out/x"))), .refused("outside"), "a link out of /workspace")
    }

    func testTheGuestAnswersAreExplained() {
        XCTAssertEqual(GuestFileChange.parse("noise\ndoz-change ok link 1\n"), .ok(kind: "link", count: 1))
        XCTAssertEqual(GuestFileChange.parse("doz-change denied\n"), .refused("denied"))
        XCTAssertEqual(GuestFileChange.parse("sh: oops\n"), .unreadable)
        let i = item("a"), t = item("b/c")
        XCTAssertEqual(GuestFileChange.explain("exists", item: i, to: t, sandbox: "s", user: "agent").code, .exists)
        XCTAssertTrue(GuestFileChange.explain("exists", item: i, to: t, sandbox: "s", user: "agent").message.contains("/workspace/b/c"))
        XCTAssertEqual(GuestFileChange.explain("missing", item: i, to: nil, sandbox: "s", user: nil).code, .notFound)
        XCTAssertTrue(GuestFileChange.explain("denied", item: i, to: nil, sandbox: "s", user: "agent").message.contains("agent may not"))
    }

    // MARK: the kept open folders

    private func storeWithSandbox(workspace: URL?) throws -> DozableStore {
        let store = DozableStore(root: root.appendingPathComponent("store"))
        var o = CreateOptions(image: "lab")
        o.workspace = workspace?.path
        let (s, n) = try DozableImages.spec(name: "x", options: o, store: store, environment: [:])
        let cfg = SandboxConfig(name: "x", image: n, spec: s, workspace: workspace?.path)
        try fm.createDirectory(at: store.configFile("x").deletingLastPathComponent(), withIntermediateDirectories: true)
        try cfg.write(store.configFile("x"))
        return store
    }

    func testTheOpenFoldersAreKeptLikeTheTerminalLayout() throws {
        let store = try storeWithSandbox(workspace: ws)
        XCTAssertNil(FileTreeState.read(store, "x"))
        try FileTreeState.write(FileTreeState(expanded: ["src", "src/lib"]), store, "x")
        XCTAssertEqual(FileTreeState.read(store, "x")?.expanded, ["src", "src/lib"])
        XCTAssertNotNil(FileTreeState.read(store, "x")?.updatedAt)
        let mode = (try fm.attributesOfItem(atPath: store.fileTreeFile("x").path)[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(mode, 0o600)
        for bad in [["src", "src"], [""], ["../x"], ["/workspace/src"], ["a\u{1}"], (0...FileTreeState.maximumExpanded).map { "d\($0)" }] {
            XCTAssertThrowsError(try FileTreeState(expanded: bad).validate(), "\(bad)")
        }
        // never creates the directory of a removed (or never made) sandbox
        XCTAssertThrowsError(try FileTreeState.write(FileTreeState(expanded: []), store, "gone")) { XCTAssertEqual(($0 as? HostError)?.code, .notFound) }
        XCTAssertFalse(fm.fileExists(atPath: store.layout("gone").sandboxDirectory.path))
        // an invalid file reads as none
        try Data(#"{"expanded":["../x"]}"#.utf8).write(to: store.fileTreeFile("x"))
        XCTAssertNil(FileTreeState.read(store, "x"))
        try FileTreeState.write(nil, store, "x")
        XCTAssertFalse(fm.fileExists(atPath: store.fileTreeFile("x").path))
    }

    // MARK: the host ops, in-process

    func testTheChangesAreAnsweredInProcessWithoutAHost() async throws {
        XCTAssertFalse(HostOp.filesMkdir.isReadOnly)
        XCTAssertTrue(HostOp.filesMkdir.isAnsweredWithoutHost)
        XCTAssertTrue(HostOp.filesTree.isReadOnly)
        try write("a.txt")
        let store = try storeWithSandbox(workspace: ws)
        let core = HostCore(store: store, readOnly: true, version: "test")
        await core.load()
        var r = HostRequest(.filesMkdir, name: "x")
        r.filePath = "/workspace/made"
        var m = await core.handle(r)
        XCTAssertEqual(m.ok, true, m.error?.message ?? "")
        let c = try XCTUnwrap(m.result).decode(FileChangeResult.self)
        XCTAssertEqual(c.folders, ["/workspace"])
        XCTAssertEqual(c.source, "mac")
        XCTAssertTrue(exists("made"))
        r = HostRequest(.filesMove, name: "x")
        r.filePath = "a.txt"
        r.fileTarget = "made/a.txt"
        m = await core.handle(r)
        XCTAssertEqual(try XCTUnwrap(m.result).decode(FileChangeResult.self).folders, ["/workspace", "/workspace/made"])
        r = HostRequest(.filesRm, name: "x")
        r.filePath = "made"
        m = await core.handle(r)
        XCTAssertTrue(m.error?.message.contains("not empty") == true)
        r.recursive = true
        m = await core.handle(r)
        XCTAssertEqual(try XCTUnwrap(m.result).decode(FileChangeResult.self).items, 2)
        r = HostRequest(.filesRm, name: "x")
        r.filePath = "/workspace"
        m = await core.handle(r)
        XCTAssertEqual(m.error?.code, .invalid, "never /workspace itself")
        // the open folders, in-process too
        var t = HostRequest(.filesTreeSet, name: "x")
        t.fileTree = FileTreeState(expanded: ["src"])
        m = await core.handle(t)
        XCTAssertEqual(try XCTUnwrap(m.result).decode(FileTreeState.self).expanded, ["src"])
        m = await core.handle(HostRequest(.filesTree, name: "x"))
        XCTAssertEqual(try XCTUnwrap(m.result).decode(FileTreeState.self).expanded, ["src"])
        XCTAssertFalse(store.hostIsRunning())
        // isolated and off: refused with why, nothing woken or started
        try fm.removeItem(at: root.appendingPathComponent("store"))
        let iso = try storeWithSandbox(workspace: nil)
        let core2 = HostCore(store: iso, readOnly: true, version: "test")
        await core2.load()
        r = HostRequest(.filesNew, name: "x")
        r.filePath = "f"
        m = await core2.handle(r)
        XCTAssertEqual(m.error?.code, .invalidPhase)
        XCTAssertTrue(m.error?.message.contains("never wakes or starts it") == true)
        r = HostRequest(.filesOpen, name: "x")
        r.filePath = "f"
        m = await core2.handle(r)
        XCTAssertTrue(m.error?.message.contains("doz get") == true, "isolated: no open, the copy command instead")
    }

    func testOpenFollowsTheBridgesRulesThroughItsSeam() throws {
        let seam = root.appendingPathComponent("opened.txt")
        let env = ["DOZ_TEST_OPEN_URL": seam.path]
        try write("docs/index.html", "<p>hi</p>\n")
        try write("tool.sh", "#!/bin/sh\n")
        try write("secret.md", "s\n")
        try write(".dozignore", "secret.md\n")
        let rules = try XCTUnwrap(MacFolderListing.rules(workspace: ws.path, mode: .lock, viewOn: true))
        let said = try MacFileChange.open(workspace: ws.path, guestPath: "/workspace/docs/index.html", reveal: false, enabled: true, rules: rules, environment: env)
        XCTAssertTrue(said.hasPrefix("opened docs/index.html"), said)
        XCTAssertTrue(try MacFileChange.open(workspace: ws.path, guestPath: "/workspace/docs", reveal: false, enabled: true, rules: rules, environment: env).contains("Finder"))
        XCTAssertTrue(try MacFileChange.open(workspace: ws.path, guestPath: "/workspace/tool.sh", reveal: true, enabled: true, rules: rules, environment: env).hasPrefix("showed"))
        XCTAssertThrowsError(try MacFileChange.open(workspace: ws.path, guestPath: "/workspace/tool.sh", reveal: false, enabled: true, rules: rules, environment: env),
                             "a script is never opened")
        XCTAssertThrowsError(try MacFileChange.open(workspace: ws.path, guestPath: "/workspace/secret.md", reveal: false, enabled: true, rules: rules, environment: env)) {
            XCTAssertTrue(($0 as? HostError)?.message.contains("locked") == true)
        }
        XCTAssertThrowsError(try MacFileChange.open(workspace: ws.path, guestPath: "/workspace/docs/index.html", reveal: false, enabled: false, rules: nil, environment: env),
                             "sandbox.open_files off")
        // a HIDDEN file of a type that is never opened: "no such file" — never its type (that would say it is there)
        try write("hidden.bin", "b\n")
        try write(".dozignore", "secret.md\nhidden.bin\n")
        let hide = try XCTUnwrap(MacFolderListing.rules(workspace: ws.path, mode: .hide, viewOn: true))
        XCTAssertThrowsError(try MacFileChange.open(workspace: ws.path, guestPath: "/workspace/hidden.bin", reveal: false, enabled: true, rules: hide, environment: env)) {
            XCTAssertEqual(($0 as? HostError)?.code, .notFound)
            XCTAssertFalse(($0 as? HostError)?.message.contains("type") == true)
        }
        let lines = try String(contentsOf: seam, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].hasPrefix("open-file default "))
        XCTAssertTrue(lines[1].hasPrefix("open-folder "))
        XCTAssertTrue(lines[2].hasPrefix("reveal "))
    }

    // MARK: 646 — open in an editor

    func testOpenInAnEditorThroughTheSeams() throws {
        let seam = root.appendingPathComponent("opened.txt")
        let env = ["DOZ_TEST_OPEN_URL": seam.path, EditorApps.testSeam: "cursor,vscode"]
        try write("src/main.swift", "print(1)\n")
        try write("Makefile", "all:\n")
        try write("tool.sh", "#!/bin/sh\n")
        try write("bin/prog", "\u{7F}ELF....")
        try write("setup.pkg", "x\n")
        try mkdir("Thing.app")
        try write("secret.md", "s\n")
        try write("hidden.txt", "h\n")
        try write(".dozignore", "secret.md\n")
        let exe = ws.appendingPathComponent("run.txt")
        try Data("plain\n".utf8).write(to: exe)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
        let real = try XCTUnwrap(MacFolderListing.realPath(ws.path))
        func open(_ p: String, _ app: String?, reveal: Bool = false, enabled: Bool = true, rules: WorkspaceRules? = nil,
                  openApps: [String] = ["Typora"]) throws -> String {
            try MacFileChange.open(workspace: ws.path, guestPath: p, reveal: reveal, enabled: enabled, rules: rules, app: app,
                                   openApps: openApps, environment: env)
        }
        // the workspace, a folder, a file the document list would refuse (an editor opens text)
        XCTAssertEqual(try open("/workspace", "cursor"), "opened the workspace in Cursor")
        XCTAssertEqual(try open("/workspace/src", "Visual Studio Code"), "opened src/ in Visual Studio Code")
        XCTAssertEqual(try open("/workspace/src/main.swift", "VSCODE"), "opened src/main.swift in Visual Studio Code", "the id, any case")
        XCTAssertEqual(try open("/workspace/Makefile", "cursor"), "opened Makefile in Cursor", "no extension: fine for an editor")
        try write("lib.py", "x = 1\n")
        XCTAssertEqual(try open("/workspace/lib.py", "cursor"), "opened lib.py in Cursor", "source text: an editor opens it (a default app never)")
        XCTAssertThrowsError(try open("/workspace/lib.py", nil), "without an editor the document rules stay")
        XCTAssertEqual(try open("/workspace/src", "typora"), "opened src/ in Typora", "a bridges.open_apps name, its listed spelling")
        // never a program, a never-type or a package; the setting, --reveal, an app not installed or not known
        for (p, why) in [("/workspace/tool.sh", "script"), ("/workspace/bin/prog", "ELF"), ("/workspace/run.txt", "executable"),
                         ("/workspace/setup.pkg", "never opened"), ("/workspace/Thing.app", "package")] {
            XCTAssertThrowsError(try open(p, "cursor"), p) { XCTAssertTrue(($0 as? HostError)?.message.contains(why) == true, "\(p): \($0)") }
        }
        XCTAssertThrowsError(try open("/workspace", "zed")) { XCTAssertEqual(($0 as? HostError)?.message, "Zed is not installed on this Mac") }
        XCTAssertThrowsError(try open("/workspace", "Safari")) { XCTAssertTrue(($0 as? HostError)?.message.contains("not a known editor or in bridges.open_apps") == true) }
        XCTAssertThrowsError(try open("/workspace", "-a")) { XCTAssertEqual(($0 as? HostError)?.code, .invalid) }
        XCTAssertThrowsError(try open("/workspace", "cursor", enabled: false)) { XCTAssertTrue(($0 as? HostError)?.message.contains("sandbox.open_files") == true) }
        XCTAssertThrowsError(try open("/workspace/src/main.swift", "cursor", reveal: true)) { XCTAssertEqual(($0 as? HostError)?.code, .invalid) }
        // the rules first: locked refused, hidden is "no such file"
        let lock = try XCTUnwrap(MacFolderListing.rules(workspace: ws.path, mode: .lock, viewOn: true))
        XCTAssertThrowsError(try open("/workspace/secret.md", "cursor", rules: lock)) { XCTAssertTrue(($0 as? HostError)?.message.contains("locked") == true) }
        try write(".dozignore", "secret.md\nhidden.txt\n")
        let hide = try XCTUnwrap(MacFolderListing.rules(workspace: ws.path, mode: .hide, viewOn: true))
        XCTAssertThrowsError(try open("/workspace/hidden.txt", "zed", rules: hide)) { XCTAssertEqual(($0 as? HostError)?.code, .notFound, "before the app is looked at") }
        let lines = try String(contentsOf: seam, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines, ["open-file Cursor \(real)", "open-file Visual Studio Code \(real)/src",
                               "open-file Visual Studio Code \(real)/src/main.swift", "open-file Cursor \(real)/Makefile",
                               "open-file Cursor \(real)/lib.py", "open-file Typora \(real)/src"], "the seam names the editor; nothing else was opened")
    }

    func testTheEditorsAndTheOpenWithAnAppAreAnsweredInProcess() async throws {
        XCTAssertTrue(HostOp.editors.isReadOnly)
        let store = try storeWithSandbox(workspace: ws)
        let core = HostCore(store: store, readOnly: true, version: "test")
        await core.load()
        setenv(EditorApps.testSeam, "zed", 1)
        defer { unsetenv(EditorApps.testSeam) }
        let m = await core.handle(HostRequest(.editors))
        XCTAssertEqual(m.ok, true, m.error?.message ?? "")
        let list = try XCTUnwrap(m.result).decode([EditorApps.Editor].self)
        XCTAssertEqual(list.first, EditorApps.Editor(id: "zed", name: "Zed"))
        XCTAssertFalse(list.contains { $0.id == "vscode" })
        // an app that is not known (or listed) is refused before anything opens
        var r = HostRequest(.filesOpen, name: "x")
        r.filePath = "/workspace"
        r.app = "no-such-editor"
        let refused = await core.handle(r)
        XCTAssertEqual(refused.error?.code, .invalid)
        XCTAssertTrue(refused.error?.message.contains("not a known editor") == true, refused.error?.message ?? "")
        XCTAssertFalse(store.hostIsRunning())
    }
}
