import Foundation
import XCTest
@testable import DozableCLI
@testable import DozableKit
@testable import DozableHost

/// 643: the file watcher's reads — the guest-path rule, a shared folder listed on the Mac (links never followed, nothing
/// outside the share), the workspace rules honoured, names made inert, the isolated listing's parser, the coalescer, the
/// FSEvents hub against a real scratch folder, and `files-list` answered in-process (no host, no VM).
final class FilesTests: XCTestCase {
    private var root: URL!
    private var ws: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("doz-files-\(UUID().uuidString.prefix(8))")
        ws = root.appendingPathComponent("ws")
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    /// Written in place (an atomic write makes a temporary file in the folder first — a real, if brief, listing change).
    private func write(_ rel: String, _ text: String = "x\n") throws {
        let u = ws.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: u)
    }
    private func mkdir(_ rel: String) throws {
        try FileManager.default.createDirectory(at: ws.appendingPathComponent(rel), withIntermediateDirectories: true)
    }
    private func link(_ rel: String, to target: String) throws {
        try FileManager.default.createSymbolicLink(atPath: ws.appendingPathComponent(rel).path, withDestinationPath: target)
    }
    private func names(_ e: [FileEntry]) -> [String] { e.map(\.name) }
    private func entry(_ e: [FileEntry], _ n: String) -> FileEntry? { e.first { $0.name == n } }

    // MARK: the path

    func testTheGuestPathRule() {
        XCTAssertEqual(FileListPaths.folder(nil)?.guest, "/workspace")
        XCTAssertEqual(FileListPaths.folder("")?.rel, "")
        XCTAssertEqual(FileListPaths.folder(".")?.rel, "")
        XCTAssertEqual(FileListPaths.folder("src")?.guest, "/workspace/src")
        XCTAssertEqual(FileListPaths.folder("src/a/../b/")?.rel, "src/b")
        XCTAssertEqual(FileListPaths.folder("/workspace")?.rel, "")
        XCTAssertEqual(FileListPaths.folder("/workspace//src/./x")?.rel, "src/x")
        XCTAssertEqual(FileListPaths.folder("src/..")?.rel, "", "back to /workspace itself")
        for bad in ["..", "../etc", "/etc", "/workspace/../etc", "/workspacex", "src/../../x", "a\u{1}b", "a\nb",
                    String(repeating: "a", count: FileListPaths.maximumPathBytes + 1)] {
            XCTAssertNil(FileListPaths.folder(bad), bad.debugDescription)
        }
    }

    func testNamesAreMadeInert() {
        XCTAssertEqual(FileListPaths.inert("plain.txt").text, "plain.txt")
        XCTAssertFalse(FileListPaths.inert("plain.txt").altered)
        let esc = FileListPaths.inert("a\u{1B}[31mred\u{7}")
        XCTAssertEqual(esc.text, "a\u{FFFD}[31mred\u{FFFD}")
        XCTAssertTrue(esc.altered)
        XCTAssertEqual(FileListPaths.inert("txt.\u{202E}exe").text, "txt.\u{FFFD}exe", "a bidi override never reorders what is drawn")
        XCTAssertEqual(FileListPaths.inert("x\u{9B}y").text, "x\u{FFFD}y", "C1 controls too")
        let long = FileListPaths.inert(String(repeating: "é", count: 300))
        XCTAssertEqual(long.text.count, FileListPaths.maximumNameCharacters)
        XCTAssertTrue(long.text.hasSuffix("…"))
        XCTAssertTrue(long.altered)
    }

    // MARK: the Mac

    func testAFolderIsListedOnTheMacLinksNeverFollowed() throws {
        try write("b.txt", "hello\n")
        try write("A.md", "#\n")
        try mkdir("src/deep")
        try write("src/main.c", "int main;\n")
        try link("to-src", to: "src")
        try link("out", to: "/etc")
        try link("dangling", to: "nope")
        let l = try MacFolderListing.list(workspace: ws.path, rel: "", rules: nil)
        XCTAssertEqual(names(l.entries), ["src", "A.md", "b.txt", "dangling", "out", "to-src"], "folders first, then by name")
        XCTAssertEqual(entry(l.entries, "b.txt")?.kind, "file")
        XCTAssertEqual(entry(l.entries, "b.txt")?.size, 6)
        XCTAssertNotNil(entry(l.entries, "b.txt")?.modified)
        XCTAssertEqual(entry(l.entries, "src")?.kind, "folder")
        XCTAssertNil(entry(l.entries, "src")?.size)
        XCTAssertEqual(entry(l.entries, "out")?.kind, "link", "a link is never followed")
        XCTAssertEqual(entry(l.entries, "out")?.target, "/etc", "its target, for display")
        XCTAssertNil(entry(l.entries, "out")?.size)
        XCTAssertEqual(entry(l.entries, "dangling")?.target, "nope")
        XCTAssertFalse(l.truncated)
        XCTAssertNil(l.state)
        // A folder through a link that stays inside: listed (what the guest reaches); a link out: refused.
        XCTAssertEqual(names(try MacFolderListing.list(workspace: ws.path, rel: "to-src", rules: nil).entries), ["deep", "main.c"])
        XCTAssertThrowsError(try MacFolderListing.list(workspace: ws.path, rel: "out", rules: nil)) {
            XCTAssertEqual(($0 as? HostError)?.code, .invalid)
            XCTAssertTrue(($0 as? HostError)?.message.contains("leads outside the shared folder") == true)
        }
        XCTAssertThrowsError(try MacFolderListing.list(workspace: ws.path, rel: "b.txt", rules: nil)) { XCTAssertEqual(($0 as? HostError)?.code, .invalid) }
        XCTAssertThrowsError(try MacFolderListing.list(workspace: ws.path, rel: "missing", rules: nil)) { XCTAssertEqual(($0 as? HostError)?.code, .notFound) }
        XCTAssertThrowsError(try MacFolderListing.list(workspace: ws.path, rel: "dangling", rules: nil)) { XCTAssertEqual(($0 as? HostError)?.code, .notFound) }
        XCTAssertThrowsError(try MacFolderListing.list(workspace: root.appendingPathComponent("gone").path, rel: "", rules: nil)) {
            XCTAssertEqual(($0 as? HostError)?.code, .failed)
        }
        // An odd name is made inert; the folder of the share itself through a link is fine.
        try write("bad\u{1B}[2Jname", "x")
        let odd = try XCTUnwrap(try MacFolderListing.list(workspace: ws.path, rel: "", rules: nil).entries.first { $0.altered == true })
        XCTAssertEqual(odd.name, "bad\u{FFFD}[2Jname")
        let viaLink = root.appendingPathComponent("ws-link")
        try FileManager.default.createSymbolicLink(atPath: viaLink.path, withDestinationPath: ws.path)
        XCTAssertEqual(try MacFolderListing.list(workspace: viaLink.path, rel: "src", rules: nil).entries.count, 2, "a share named through a link resolves")
    }

    func testABigFolderIsCut() throws {
        try mkdir("many")
        for i in 0..<(FileListPaths.maximumEntries + 5) {
            FileManager.default.createFile(atPath: ws.appendingPathComponent("many/f\(i)").path, contents: nil)
        }
        let l = try MacFolderListing.list(workspace: ws.path, rel: "many", rules: nil)
        XCTAssertEqual(l.entries.count, FileListPaths.maximumEntries)
        XCTAssertTrue(l.truncated)
    }

    func testTheWorkspaceRulesAreHonoured() throws {
        try write(".dozignore", "secret.env\nlogs\n!logs/keep.txt\nprivate\n")
        try write(".dozreadonly", "config\n")
        try write("secret.env", "S\n")
        try write("logs/keep.txt", "k\n")
        try write("logs/other.log", "o\n")
        try write("private/x", "p\n")
        try write("config/app.yaml", "c\n")
        try write("doz_project.yaml", "v\n")
        try write("src/main.c", "m\n")
        // lock: listed as locked (no size, no time); read-only marked; the rule files read-only; implicit read-only.
        let lock = try XCTUnwrap(MacFolderListing.rules(workspace: ws.path, mode: .lock, viewOn: true))
        let top = try MacFolderListing.list(workspace: ws.path, rel: "", rules: lock).entries
        XCTAssertEqual(entry(top, "secret.env")?.state, "locked")
        XCTAssertNil(entry(top, "secret.env")?.size)
        XCTAssertNil(entry(top, "secret.env")?.modified)
        XCTAssertEqual(entry(top, "private")?.state, "locked")
        XCTAssertEqual(entry(top, "config")?.state, "read-only")
        XCTAssertEqual(entry(top, ".dozignore")?.state, "read-only")
        XCTAssertEqual(entry(top, ".dozreadonly")?.state, "read-only")
        XCTAssertEqual(entry(top, "doz_project.yaml")?.state, "read-only")
        XCTAssertNil(entry(top, "src")?.state)
        XCTAssertNil(entry(top, "logs")?.state, "a folder a ! line re-includes from is shown")
        // inside: the re-included file visible, the rest locked; a read-only folder's own state; a locked folder refused
        let logs = try MacFolderListing.list(workspace: ws.path, rel: "logs", rules: lock).entries
        XCTAssertNil(entry(logs, "keep.txt")?.state)
        XCTAssertEqual(entry(logs, "other.log")?.state, "locked")
        XCTAssertEqual(try MacFolderListing.list(workspace: ws.path, rel: "config", rules: lock).state, "read-only")
        XCTAssertThrowsError(try MacFolderListing.list(workspace: ws.path, rel: "private", rules: lock)) {
            XCTAssertTrue(($0 as? HostError)?.message.contains("locked by the workspace rules") == true)
        }
        // case-insensitive volume: a different case is still selected
        XCTAssertThrowsError(try MacFolderListing.list(workspace: ws.path, rel: "PRIVATE", rules: lock))
        // hide: absent, and a hidden folder is "no such folder"
        let hide = try XCTUnwrap(MacFolderListing.rules(workspace: ws.path, mode: .hide, viewOn: true))
        let hidden = try MacFolderListing.list(workspace: ws.path, rel: "", rules: hide).entries
        XCTAssertNil(entry(hidden, "secret.env"))
        XCTAssertNil(entry(hidden, "private"))
        XCTAssertNotNil(entry(hidden, "logs"))
        XCTAssertEqual(names(try MacFolderListing.list(workspace: ws.path, rel: "logs", rules: hide).entries), ["keep.txt"])
        XCTAssertThrowsError(try MacFolderListing.list(workspace: ws.path, rel: "private", rules: hide)) { XCTAssertEqual(($0 as? HostError)?.code, .notFound) }
        // the view off, or no rule file: no rules at all
        XCTAssertNil(MacFolderListing.rules(workspace: ws.path, mode: .lock, viewOn: false))
        try FileManager.default.removeItem(at: ws.appendingPathComponent(".dozignore"))
        try FileManager.default.removeItem(at: ws.appendingPathComponent(".dozreadonly"))
        XCTAssertNil(MacFolderListing.rules(workspace: ws.path, mode: .lock, viewOn: true))
    }

    func testRulesAreDecidedOnTheResolvedPath() throws {
        try write(".dozignore", "private\n")
        try write("private/x", "p\n")
        try link("innocent", to: "private")
        let rules = try XCTUnwrap(MacFolderListing.rules(workspace: ws.path, mode: .hide, viewOn: true))
        XCTAssertThrowsError(try MacFolderListing.list(workspace: ws.path, rel: "innocent", rules: rules), "a link into a hidden folder reaches nothing") {
            XCTAssertEqual(($0 as? HostError)?.code, .notFound)
        }
    }

    // MARK: the guest

    func testTheGuestScriptQuotesItsPathAndNamesNeverLookLikeOptions() {
        let s = GuestFolderListing.script("/workspace/it's here")
        XCTAssertTrue(s.contains("d='/workspace/it'\\''s here'"))
        XCTAssertTrue(s.contains("\"./$f\""), "every name is passed as ./NAME")
        XCTAssertTrue(s.contains("stat -c 'doz-entry %F|%s|%Y|%n'"))
        XCTAssertTrue(s.contains("[ \"$n\" -le \(FileListPaths.maximumEntries) ]"))
    }

    func testTheGuestAnswerIsParsed() {
        let out = """
        doz-files ok 6 1
        doz-entry directory|4096|1729580000|./src
        doz-entry regular file|12|1729580001|./a|b.txt
        doz-entry regular empty file|0|1729580002|./empty
        doz-entry symbolic link|7|1729580003|./ln
        doz-entry fifo|0|1729580004|./pipe
        doz-entry regular file|3|1729580005|./x\u{1B}y
        doz-link ./ln
        doz-target ../../etc
        """
        guard case .ok(let e, let total, let unlisted) = GuestFolderListing.parse(out) else { return XCTFail("not ok") }
        XCTAssertEqual(total, 6)
        XCTAssertEqual(unlisted, 1)
        XCTAssertEqual(names(e), ["src", "a|b.txt", "empty", "ln", "pipe", "x\u{FFFD}y"])
        XCTAssertEqual(e.map(\.kind), ["folder", "file", "file", "link", "other", "file"])
        XCTAssertEqual(entry(e, "a|b.txt")?.size, 12, "a | in a name stays in the name")
        XCTAssertNil(entry(e, "src")?.size)
        XCTAssertEqual(entry(e, "ln")?.target, "../../etc")
        XCTAssertEqual(entry(e, "empty")?.modified, Date(timeIntervalSince1970: 1729580002))
        XCTAssertEqual(GuestFolderListing.parse("doz-files missing\n"), .missing)
        XCTAssertEqual(GuestFolderListing.parse("doz-files notdir\n"), .notDirectory)
        XCTAssertEqual(GuestFolderListing.parse("doz-files denied\n"), .denied)
        XCTAssertEqual(GuestFolderListing.parse("doz-files ok 0 0\n"), .ok(entries: [], total: 0, unlisted: 0))
        if case .unreadable = GuestFolderListing.parse("sh: stat: not found\n") {} else { XCTFail("no head: unreadable") }
    }

    // MARK: the coalescer

    private let a = UUID(), b = UUID()

    func testTheCoalescerSaysWhichWatchedFoldersChangedOnce() {
        var c = FileWatchCoalescer(rules: nil)
        XCTAssertTrue(c.isEmpty)
        c.add("src/a.c", isDirectory: false)
        c.add("src/b.c", isDirectory: false)
        c.add("src/b.c", isDirectory: false)
        c.add("docs/x.md", isDirectory: false)
        c.add("lib", isDirectory: true)
        let ws: [FileWatchCoalescer.Watcher] = [.init(id: a, folders: ["src": "/workspace/src", "": "/workspace"]),
                                                .init(id: b, folders: ["other": "/workspace/other"])]
        let out = c.drain(ws, sandbox: "s", now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(out.count, 1, "nothing for a watcher none of whose folders changed")
        XCTAssertEqual(out[0].id, a)
        XCTAssertEqual(out[0].batch.folders, ["/workspace", "/workspace/src"], "one batch, each folder once; a new folder changes its parent")
        XCTAssertFalse(out[0].batch.resync)
        XCTAssertTrue(c.isEmpty, "drained")
        XCTAssertTrue(c.drain(ws, sandbox: "s").isEmpty)
        // a folder itself removed: its parent and itself
        c.add("src", isDirectory: true)
        XCTAssertEqual(c.drain(ws, sandbox: "s").first?.batch.folders, ["/workspace", "/workspace/src"])
        // a folder's own time moving (a child changed): no change of its own — the child's event says it
        c.add("src", isDirectory: true, metadataOnly: true)
        c.add("", isDirectory: true, metadataOnly: true)
        XCTAssertTrue(c.isEmpty)
        c.add("src/a.c", isDirectory: false, metadataOnly: true)
        XCTAssertEqual(c.pending, ["src"], "a file's contents changing changes its size and time in the listing")
    }

    func testTheCoalescerKeepsHiddenNamesAndLockedFoldersOut() {
        let rules = WorkspaceRules(ignoreText: "secret.env\nprivate\n", readOnlyText: nil, mode: .hide)
        var c = FileWatchCoalescer(rules: rules)
        c.add("secret.env", isDirectory: false)
        c.add("private/x", isDirectory: false)
        XCTAssertTrue(c.isEmpty, "a hidden entry's change is no change anyone sees")
        c.add("SECRET.ENV", isDirectory: false)
        XCTAssertTrue(c.isEmpty, "folded, as the volume compares")
        c.add("open.txt", isDirectory: false)
        XCTAssertEqual(c.pending, [""])
        var locked = FileWatchCoalescer(rules: WorkspaceRules(ignoreText: "private\nsecret.env\n", readOnlyText: nil, mode: .lock))
        locked.add("private/x", isDirectory: false)
        XCTAssertTrue(locked.isEmpty, "inside a locked folder: nothing can be listed")
        locked.add("secret.env", isDirectory: false)
        XCTAssertEqual(locked.pending, [""], "a locked entry is listed, so its parent changed")
        locked.add("private", isDirectory: true)
        XCTAssertEqual(locked.pending, [""], "a locked folder's own listing is refused: only its parent")
    }

    func testTheCoalescerResyncs() {
        var c = FileWatchCoalescer(rules: nil)
        XCTAssertTrue(c.add(".dozignore", isDirectory: false), "a rule file: read the rules again")
        XCTAssertTrue(c.add(".DozReadOnly", isDirectory: false))
        XCTAssertFalse(c.add("src/.dozignore", isDirectory: false), "only at the root")
        var out = c.drain([.init(id: a, folders: ["x": "/workspace/x"])], sandbox: "s")
        XCTAssertEqual(out.first?.batch.resync, true)
        XCTAssertEqual(out.first?.batch.folders, [])
        c.addResync()
        out = c.drain([.init(id: a, folders: ["x": "/workspace/x"]), .init(id: b, folders: ["": "/workspace"])], sandbox: "s")
        XCTAssertEqual(out.map(\.batch.resync), [true, true], "dropped events: every watcher lists again")
        // more changed folders than a batch names
        var many: [String: String] = [:]
        for i in 0...FileWatchCoalescer.maximumFolders { many["d\(i)"] = "/workspace/d\(i)"; c.add("d\(i)/f", isDirectory: false) }
        out = c.drain([.init(id: a, folders: many)], sandbox: "s")
        XCTAssertEqual(out.first?.batch.resync, true)
    }

    // MARK: the hub (real FSEvents, a scratch folder)

    private func storeWithSandbox(workspace: URL?, mode: String? = nil) throws -> DozableStore {
        let store = DozableStore(root: root.appendingPathComponent("store"))
        var o = CreateOptions(image: "lab")
        o.workspace = workspace?.path
        let (s, n) = try DozableImages.spec(name: "x", options: o, store: store, environment: [:])
        var cfg = SandboxConfig(name: "x", image: n, spec: s, workspace: workspace?.path)
        if let mode { cfg.settings = [SettingKey.ignoreMode: .string(mode)] }
        try FileManager.default.createDirectory(at: store.configFile("x").deletingLastPathComponent(), withIntermediateDirectories: true)
        try cfg.write(store.configFile("x"))
        return store
    }

    final class Batches: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [FileChangeBatch] = []
        func add(_ b: FileChangeBatch) { lock.withLock { list.append(b) } }
        func clear() { lock.withLock { list.removeAll() } }
        var all: [FileChangeBatch] { lock.withLock { list } }
        func wait(_ seconds: Double, _ pred: ([FileChangeBatch]) -> Bool) -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end { if pred(all) { return true }; usleep(50_000) }
            return pred(all)
        }
    }

    func testTheHubWatchesARealFolderWithOneStreamPerSandbox() throws {
        try mkdir("src")
        try mkdir("docs")
        try write(".dozignore", "secret.env\n")
        let store = try storeWithSandbox(workspace: ws, mode: "hide")
        let target = try FileWatchTarget.resolve(store: store, sandbox: "x", folders: ["src", "/workspace"])
        XCTAssertEqual(Set(target.folders.values), ["/workspace/src", "/workspace"])
        let hub = FileWatchHub(window: .milliseconds(100))
        let one = Batches(), two = Batches()
        let s1 = try hub.watch(target) { one.add($0) }
        let s2 = try hub.watch(try FileWatchTarget.resolve(store: store, sandbox: "x", folders: ["docs"])) { two.add($0) }
        XCTAssertEqual(hub.streams, 1, "one FSEventStream for the sandbox, shared")
        // FSEvents starts "since now", but on a loaded Mac the folders made just above can still arrive late (CI on
        // m1max2): let the stream settle, then forget whatever came before the checks.
        usleep(1_000_000)
        one.clear(); two.clear()
        try write("src/new.c")
        XCTAssertTrue(one.wait(5) { $0.contains { $0.folders == ["/workspace/src"] } }, "a file written → its folder (\(one.all))")
        XCTAssertTrue(two.all.isEmpty, "nothing for a watcher of another folder (\(two.all))")
        try write("secret.env")
        usleep(800_000)
        XCTAssertFalse(one.all.contains { $0.folders.contains("/workspace") }, "a hidden file's change never travels (\(one.all))")
        try write("docs/a.md")
        XCTAssertTrue(two.wait(5) { $0.contains { $0.folders == ["/workspace/docs"] } })
        s1.cancel()
        XCTAssertEqual(hub.streams, 1)
        s2.cancel()
        XCTAssertEqual(hub.streams, 0, "stopped with the last watcher")
        s2.cancel()                                                // twice is harmless
        // and again after it stopped: a fresh stream
        let three = Batches()
        let s3 = try hub.watch(target) { three.add($0) }
        XCTAssertEqual(hub.streams, 1)
        usleep(300_000)
        try write("src/again.c")
        XCTAssertTrue(three.wait(5) { !$0.isEmpty })
        s3.cancel()
        XCTAssertEqual(hub.streams, 0)
    }

    func testAWatchTargetIsResolvedAndConfinedFromTheStore() throws {
        try mkdir("src")
        try write(".dozignore", "private\n")
        try mkdir("private")
        try link("out", to: "/etc")
        let store = try storeWithSandbox(workspace: ws)
        XCTAssertNoThrow(try FileWatchTarget.resolve(store: store, sandbox: "x", folders: []))
        XCTAssertEqual(try FileWatchTarget.resolve(store: store, sandbox: "x", folders: []).folders, ["": "/workspace"])
        for (folder, code) in [("out", HostError.Code.invalid), ("../etc", .invalid), ("missing", .notFound), ("private", .failed)] {
            XCTAssertThrowsError(try FileWatchTarget.resolve(store: store, sandbox: "x", folders: [folder]), folder) {
                XCTAssertEqual(($0 as? HostError)?.code, code, folder)
            }
        }
        XCTAssertThrowsError(try FileWatchTarget.resolve(store: store, sandbox: "x", folders: Array(repeating: "src", count: 65)))
        XCTAssertThrowsError(try FileWatchTarget.resolve(store: store, sandbox: "../x", folders: [])) { XCTAssertEqual(($0 as? HostError)?.code, .notFound) }
        XCTAssertThrowsError(try FileWatchTarget.resolve(store: store, sandbox: "nope", folders: [])) { XCTAssertEqual(($0 as? HostError)?.code, .notFound) }
        let iso = try storeWithSandbox(workspace: nil)
        XCTAssertThrowsError(try FileWatchTarget.resolve(store: iso, sandbox: "x", folders: [])) {
            XCTAssertTrue(($0 as? HostError)?.message.contains("list them again to refresh") == true)
        }
    }

    // MARK: the host op, in-process

    func testFilesListIsAnsweredFromTheMacWithoutAHostAndNeverWakesAnIsolatedSandbox() async throws {
        XCTAssertTrue(HostOp.filesList.isReadOnly, "looking never starts a host")
        try write("src/main.c", "m\n")
        try write(".dozreadonly", "src\n")
        let store = try storeWithSandbox(workspace: ws)
        let core = HostCore(store: store, readOnly: true, version: "test")
        await core.load()
        var r = HostRequest(.filesList, name: "x")
        r.filePath = "src"
        let m = await core.handle(r)
        let l = try XCTUnwrap(m.result).decode(FileList.self)
        XCTAssertEqual(l.path, "/workspace/src")
        XCTAssertEqual(l.source, "mac")
        XCTAssertEqual(l.watch, "mac")
        XCTAssertTrue(l.rules)
        XCTAssertEqual(l.state, "read-only")
        XCTAssertEqual(l.entries.map(\.name), ["main.c"])
        XCTAssertEqual(l.entries.first?.state, "read-only")
        r.filePath = "../x"
        let bad = await core.handle(r)
        XCTAssertEqual(bad.error?.code, .invalid)
        XCTAssertFalse(store.hostIsRunning())
        // isolated and off: refused with why — nothing woken, nothing started
        let iso = try storeWithSandbox(workspace: nil)
        let core2 = HostCore(store: iso, readOnly: true, version: "test")
        await core2.load()
        let off = await core2.handle(HostRequest(.filesList, name: "x"))
        XCTAssertEqual(off.error?.code, .invalidPhase)
        XCTAssertTrue(off.error?.message.contains("never wakes or starts it") == true, off.error?.message ?? "")
        XCTAssertFalse(iso.hostIsRunning())
    }

    // MARK: the CLI

    func testTheCLITable() {
        let l = FileList(sandbox: "s", path: "/workspace/src", source: "mac", watch: "mac", rules: true, entries: [
            FileEntry(name: "lib", kind: "folder", modified: Date(timeIntervalSince1970: 0)),
            FileEntry(name: "a.c", kind: "file", size: 2048, modified: Date(timeIntervalSince1970: 0)),
            FileEntry(name: "ln", kind: "link", target: "../x"),
            FileEntry(name: "secret", kind: "file", state: "locked"),
        ], truncated: true)
        let t = FilesList.render(l)
        XCTAssertTrue(t.hasPrefix("s:/workspace/src\n"))
        XCTAssertTrue(t.contains("lib/"))
        XCTAssertTrue(t.contains("ln -> ../x"))
        XCTAssertTrue(t.contains("secret  (locked)"))
        XCTAssertTrue(t.contains("only the first 4 entries"))
        XCTAssertTrue(FilesList.render(FileList(sandbox: "s", path: "/workspace", source: "guest", watch: "none", rules: false, entries: [], truncated: false))
            .contains("(empty)"))
    }
}
