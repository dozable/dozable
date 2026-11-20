import Darwin
import Foundation
import XCTest
@testable import DozableKit
@testable import DozableHost

/// `workspace-reach` in an in-process core on a scratch store (no VM: a lab sandbox made, never booted; sessions on this Mac
/// as records, no process started): every kind of agent and role, the control words, live or at the next start, the
/// permissions and ceiling rows (real answers, `permissions show`'s counts), no secret value or chat token's fingerprint anywhere in the answer, no daemon → refusals not known.
final class WorkspaceReachTests: XCTestCase {
    private var root: URL!
    private var folder: URL!
    let keychain = FakeKeychain()
    static let sentinel = "doz-sentinel-SECRET-7f3a9c"

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: "/tmp/doz-wsr-\(UUID().uuidString.prefix(8))")
        folder = root.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        folder = URL(fileURLWithPath: WorkspaceStore.resolved(folder.path))
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    var store: DozableStore { DozableStore(root: root.appendingPathComponent("store")) }

    func core(readOnly: Bool = false) async -> HostCore {
        let s = CredentialServices(keychain: keychain, verifier: FakeVerifier(answer: .verified), claudeBinary: { nil }, home: root,
                                   keepaliveRunner: FakeRunner(), isClaudeRunning: { false }, watchInterval: .seconds(3600))
        let c = HostCore(store: store, readOnly: readOnly, version: "test", services: s)
        await c.load()
        return c
    }

    static func fence(_ workdir: String, secrets: [LaunchSecret]) -> MacFenceRecord {
        var f = MacFenceRecord(profile: "agent", keychain: false, readable: ["/opt/ref"], writable: [], sessionFolder: "/f/s",
                               grants: MacFenceGrants(profile: "agent", keychain: false, readable: [], writable: []), tag: "t", templateVersion: 1,
                               profileSHA256: "x", gitBaseline: nil, stoppedForGit: nil, stoppedPids: nil)
        f.proxyPort = 40001
        f.policy = try? MacFenceNetwork.policy(words: ["standard"])
        f.secrets = secrets
        f.account = "mac"
        f.hostPorts = [HostPort(port: 41234)]
        return f
    }

    /// A workspace with a VM worker, a fenced manager, an unfenced worker, a fenced adopted session and an agent elsewhere.
    func fixture() async throws -> HostCore {
        let c = await core()
        var r = HostRequest(.create, name: "vmw")
        r.create = CreateOptions(image: "lab")
        let m = await c.handle(r)
        XCTAssertNil(m.error, m.error?.message ?? "")
        // The sandbox's record holds a given secret (its value only in the keychain) — never seen in an answer.
        let cfgURL = store.configFile("vmw")
        var cfg = try XCTUnwrap(SandboxConfig.read(cfgURL))
        cfg.secrets = [LaunchSecret(variable: "MUSIC_API_TOKEN", host: "api.music.example", port: 443, fingerprint: "abcdef012345", keychainService: "doz-secret-x-vmw-MUSIC")]
        try cfg.write(cfgURL)
        keychain.put("doz-secret-x-vmw-MUSIC", Self.sentinel)
        // Sessions on this Mac, as records.
        let dir = store.root.appendingPathComponent("mac-sessions")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var recs = MacSessionRecords()
        var fenced = MacSessionRecord(argv: ["claude"], workdir: folder.path, openedAt: Date())
        fenced.fence = Self.fence(folder.path, secrets: [LaunchSecret(variable: "CHAT_TOKEN", fileVariable: "CHAT_TOKEN_FILE", host: "host.dozable.internal", port: 41234,
                                                                      fingerprint: "c0ffee000111", bot: "mira")])
        recs.sessions["demo"] = fenced
        var adopted = MacSessionRecord(argv: ["/bin/sh"], workdir: folder.path, openedAt: Date())
        adopted.fence = Self.fence(folder.path, secrets: [LaunchSecret(variable: "API_KEY", host: "api.example.com", port: 443, fingerprint: "1234567890ab",
                                                                       keychainService: "doz-secret-x-mac.side-API_KEY")])
        recs.sessions["side"] = adopted
        recs.sessions["demo-otto"] = MacSessionRecord(argv: ["claude"], workdir: folder.path, openedAt: Date())
        try HostWire.prettyEncoder.encode(recs).write(to: dir.appendingPathComponent("sessions.json"))
        // The record.
        var manager = WorkspaceAgent(name: "mira", role: "manager", place: .macSession("demo"), startedAt: Date(), bot: "mira", isolation: "fenced")
        manager.stoppedAt = nil
        var worker = WorkspaceAgent(name: "vmw", role: "worker", place: .sandbox("vmw"), startedAt: Date(), isolation: "vm")
        worker.task = "render"
        var otto = WorkspaceAgent(name: "otto", role: "worker", place: .macSession("demo-otto"), startedAt: Date(), bot: "otto", isolation: "unfenced")
        otto.task = "check"
        let side = WorkspaceAgent(name: "side", place: .macSession("side"), startedAt: Date())
        let far = WorkspaceAgent(name: "far", place: AgentPlace(elsewhere: "a laptop"), startedAt: Date(), bot: "far", isolation: "elsewhere")
        let brief = Data("The work.\n".utf8)
        let rec = WorkspaceRecord(name: "demo", createdAt: Date(), brief: WorkspaceBrief(sha256: WorkspaceStore.sha256(brief), bytes: brief.count, updatedAt: Date()),
                                  folders: [WorkspaceFolder(path: folder.path, mode: "rw", main: true)],
                                  rooms: [WorkspaceRoom(label: "demo", chatRoom: "demo", main: true)], agents: [manager, worker, otto, side, far],
                                  defaults: WorkspaceDefaults(isolation: "vm", network: "standard"), flags: WorkspaceFlags(startedAt: Date()))
        try WorkspaceStore(store: store).create(rec, brief: brief, log: [WorkspaceLogEntry(action: "created")])
        _ = c
        return await core()          // a core that read the sandbox's record as it is now
    }

    func reach(_ c: HostCore, agent: String? = nil) async throws -> (WorkspaceReach, String) {
        var w = WorkspaceRequest(name: "demo")
        w.agent = agent
        var r = HostRequest(.workspaceReach)
        r.workspaceRequest = w
        let m = await c.handle(r)
        XCTAssertNil(m.error, m.error?.message ?? "")
        let v = try XCTUnwrap(m.result)
        let text = String(decoding: try HostWire.encoder.encode(v), as: UTF8.self)
        return (try v.decode(WorkspaceReach.self), text)
    }

    func testEveryKindOfAgentAndItsControlWords() async throws {
        let c = try await fixture()
        let (r, _) = try await reach(c)
        XCTAssertEqual(r.defaults, .init(isolation: "vm", network: "standard"))
        let by = Dictionary(uniqueKeysWithValues: r.agents.map { ($0.name, $0) })
        XCTAssertEqual(Set(by.keys), ["mira", "vmw", "otto", "side", "far"])
        func control(_ n: String) -> MacCapability? { by[n]?.capabilities.first { $0.id == "control" } }
        // The manager, fenced: the room only.
        XCTAssertEqual(by["mira"]?.isolation, "fenced")
        XCTAssertEqual(control("mira")?.state, "talks in the room only")
        XCTAssertTrue(control("mira")!.sentence.contains("cannot drive Dozable"))
        // A VM worker: worker ls's words; its rows say the micro VM, folders, the given secret by name.
        XCTAssertEqual(by["vmw"]?.kind, "sandbox")
        XCTAssertEqual(control("vmw")?.state, "micro VM · proxy · placeholders")
        let vmIds = by["vmw"]!.capabilities.map(\.id)
        XCTAssertEqual(Array(vmIds.prefix(3)), ["isolation", "folders", "network"])
        XCTAssertTrue(vmIds.contains("secrets"))
        XCTAssertEqual(by["vmw"]?.held, [HeldSecret(name: "MUSIC_API_TOKEN", to: "api.music.example:443", header: "authorization (Bearer)", fingerprint: "abcdef012345", kind: "given")])
        // An unfenced worker: acts as you, the warning words, the network not limited.
        XCTAssertEqual(by["otto"]?.actsAsYou, true)
        XCTAssertEqual(control("otto")?.state, "acts as you")
        XCTAssertTrue(control("otto")!.sentence.contains("runs doz and anything else as you"))
        XCTAssertFalse(by["otto"]!.network.proxied)
        // Elsewhere: token only.
        XCTAssertEqual(control("far")?.state, "not run by Dozable — token only")
        XCTAssertEqual(by["far"]?.control, "not run by Dozable · token only")
        // An @mac agent's rows are MacFence.capabilities unchanged, then the control row.
        let side = try XCTUnwrap(by["side"])
        let shape = MacCapabilityShape(session: "side", record: try XCTUnwrap(MacSessions(store: store, readOnly: true).records().sessions["side"]), home: nil)
        let expected = MacFence.capabilities(shape)
        XCTAssertEqual(Array(side.capabilities.prefix(expected.count)).map(\.id), expected.map(\.id))
        XCTAssertEqual(side.folders, [ReachFolder(path: folder.path, mode: "rw"), ReachFolder(path: "/opt/ref", mode: "ro")])
        XCTAssertEqual(side.account, "mac")
        // Live or at the next start: the network live, isolation and secrets at the next start.
        XCTAssertEqual(by["vmw"]!.capabilities.first { $0.id == "isolation" }?.editable, "restart")
        XCTAssertEqual(by["vmw"]!.capabilities.first { $0.id == "secrets" }?.editable, "restart")
        XCTAssertEqual(side.capabilities.first { $0.id == "network" }?.editable, "live")
        // The chat row: the manager's token held by Dozable.
        XCTAssertTrue(by["mira"]!.capabilities.contains { $0.id == "chat" && $0.sentence.contains("its chat token is held by Dozable") })
        // Last, each agent's permissions and ceiling — real answers, the counts `permissions show` prints, read only.
        for a in r.agents {
            XCTAssertEqual(a.capabilities.suffix(2).map(\.id), ["permissions", "ceiling"], a.name)
            let p = a.capabilities.first { $0.id == "permissions" }!
            XCTAssertTrue(p.state.hasPrefix("allow ") && p.state.contains(" · ask ") && p.state.contains(" · never "), p.state)
            XCTAssertTrue(p.sentence.contains("not enforced yet"), p.sentence)
            XCTAssertEqual(p.link, "doz permissions show demo --agent \(a.name)")
            XCTAssertEqual(a.capabilities.first { $0.id == "ceiling" }?.state, "none set: no cap")
        }
        XCTAssertTrue(by["otto"]!.capabilities.first { $0.id == "permissions" }!.sentence.contains("acts as you, so what it does is a promise"))
        // One agent only.
        let (one, _) = try await reach(c, agent: "otto")
        XCTAssertEqual(one.agents.map(\.name), ["otto"])
    }

    func testNoSecretValueNorAChatTokensFingerprint() async throws {
        let c = try await fixture()
        let (r, text) = try await reach(c)
        XCTAssertFalse(text.contains(Self.sentinel), "a secret's value in the answer")
        XCTAssertFalse(text.contains("c0ffee000111"), "a chat token's fingerprint in the answer")
        let chat = try XCTUnwrap(r.agents.first { $0.name == "mira" }?.held.first)
        XCTAssertEqual(chat.kind, "chat-bot")
        XCTAssertNil(chat.fingerprint)
        // The field is `held` — no key named like a secret's value anywhere.
        XCTAssertFalse(text.contains("\"value\":"))
        XCTAssertFalse(text.contains("\"secrets\":"))
        XCTAssertFalse(text.contains("\"token\":"))
    }

    func testNoDaemonRefusalsNotKnownAndNothingStarts() async throws {
        _ = try await fixture()
        let ro = await core(readOnly: true)
        let (r, _) = try await reach(ro)
        XCTAssertFalse(r.refusalsKnown)
        XCTAssertTrue(r.notes?.contains { $0.contains("not known: no daemon is running") } == true)
        XCTAssertFalse(r.agents.contains { !$0.network.refused.isEmpty })
        XCTAssertFalse(r.agents.contains { $0.network.live })
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.root.appendingPathComponent("daemon.pid").path))
        XCTAssertTrue(HostOp.workspaceReach.isReadOnly)
        XCTAssertTrue(HostOp.workspaceFolders.isReadOnly)
        XCTAssertTrue(HostOp.workspaceLog.isReadOnly)
    }

    func testAnUnknownAgentIsNotFound() async throws {
        let c = try await fixture()
        var w = WorkspaceRequest(name: "demo")
        w.agent = "nobody"
        var r = HostRequest(.workspaceReach)
        r.workspaceRequest = w
        let m = await c.handle(r)
        XCTAssertEqual(m.error?.code, .notFound)
    }

    func testTheFoldersAnswer() async throws {
        let c = try await fixture()
        try Data("x".utf8).write(to: folder.appendingPathComponent("made.txt"))
        try Data("a\n# c\nb\n".utf8).write(to: folder.appendingPathComponent(".dozignore"))
        var r = HostRequest(.workspaceFolders)
        r.workspaceRequest = WorkspaceRequest(name: "demo")
        let m = await c.handle(r)
        XCTAssertNil(m.error, m.error?.message ?? "")
        let f = try XCTUnwrap(m.result).decode(WorkspaceFolders.self)
        XCTAssertEqual(f.folders.first?.path, folder.path)
        XCTAssertEqual(f.folders.first?.main, true)
        XCTAssertEqual(f.folders.first?.rules.ignore, 2)
        XCTAssertNil(f.folders.first?.rules.readonly)
        XCTAssertTrue(f.folders.first!.changes.contains { $0.path == "made.txt" && $0.kind == "A" })
        XCTAssertTrue(Set(f.folders.first!.agents).isSuperset(of: ["mira", "side", "otto"]))
        XCTAssertEqual(f.points.map(\.sandbox), ["vmw"])
    }
}

/// The changed-files walk: mtime and birth around the start, a link out neither listed nor followed, `.git` skipped, the
/// caps and `truncated`, a missing and a read-only folder, and NO program run — a `.git/config` whose fsmonitor would write a
/// marker is never run (the rule: Dozable never runs a program in a folder an agent writes in order to look at it).
final class WorkspaceChangedFilesTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = URL(fileURLWithPath: WorkspaceStore.resolved("/tmp/doz-wcf-\(UUID().uuidString.prefix(8))"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        chmod(root.appendingPathComponent("ro").path, 0o755)
        try? FileManager.default.removeItem(at: root)
    }

    func touch(_ rel: String, at date: Date? = nil) throws {
        let u = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: u)
        if let date { try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: u.path) }
    }

    func testMtimeAndBirthAroundTheStart() throws {
        try touch("old.txt", at: Date().addingTimeInterval(-3600))
        try touch("changed.txt", at: Date().addingTimeInterval(-3600))
        let start = Date().addingTimeInterval(-60)
        // Born before the start, changed after it: M.
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: root.appendingPathComponent("changed.txt").path)
        // changed.txt was born now (the test made it): give the walk a start between its birth and now by moving its birth back.
        var times = [timespec(tv_sec: Int(Date().timeIntervalSince1970) - 3600, tv_nsec: 0)]
        var list = attrlist(bitmapcount: u_short(ATTR_BIT_MAP_COUNT), reserved: 0, commonattr: attrgroup_t(ATTR_CMN_CRTIME), volattr: 0, dirattr: 0, fileattr: 0, forkattr: 0)
        XCTAssertEqual(setattrlist(root.appendingPathComponent("changed.txt").path, &list, &times, MemoryLayout<timespec>.size, 0), 0)
        try touch("src/new.swift")
        let r = WorkspaceChangedFiles.walk(root.path, since: start)
        XCTAssertTrue(r.exists)
        XCTAssertEqual(Set(r.changes.map { "\($0.kind) \($0.path)" }), ["M changed.txt", "A src/new.swift"])
        XCTAssertFalse(r.truncated)
        XCTAssertEqual(r.count, 2)
    }

    func testALinkOutIsNeitherListedNorFollowedAndGitIsSkipped() throws {
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("y".utf8).write(to: outside.appendingPathComponent("secret.txt"))
        let inside = root.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: inside.appendingPathComponent("link").path, withDestinationPath: outside.path)
        try FileManager.default.createSymbolicLink(atPath: inside.appendingPathComponent("file-link").path, withDestinationPath: outside.appendingPathComponent("secret.txt").path)
        try FileManager.default.createDirectory(at: inside.appendingPathComponent(".git/objects"), withIntermediateDirectories: true)
        try Data("z".utf8).write(to: inside.appendingPathComponent(".git/objects/abc"))
        try Data("w".utf8).write(to: inside.appendingPathComponent("real.txt"))
        let r = WorkspaceChangedFiles.walk(inside.path, since: Date().addingTimeInterval(-60))
        XCTAssertEqual(r.changes.map(\.path), ["real.txt"])
        // The folder itself through a link: refused (not opened through it).
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("via").path, withDestinationPath: inside.path)
        XCTAssertFalse(WorkspaceChangedFiles.walk(root.appendingPathComponent("via").path, since: .distantPast).exists)
    }

    func testTheCapsAndTruncated() throws {
        for i in 0..<30 { try touch("f\(i).txt") }
        let listed = WorkspaceChangedFiles.walk(root.path, since: Date().addingTimeInterval(-60), listed: 10)
        XCTAssertEqual(listed.changes.count, 10)
        XCTAssertEqual(listed.count, 30)
        XCTAssertTrue(listed.truncated)
        let entries = WorkspaceChangedFiles.walk(root.path, since: Date().addingTimeInterval(-60), maximumEntries: 5)
        XCTAssertTrue(entries.truncated)
        XCTAssertLessThanOrEqual(entries.scanned, 6)
        // The time cap: a clock that has run out at once.
        var t = Date()
        let timed = WorkspaceChangedFiles.walk(root.path, since: .distantPast, maximumSeconds: 1, clock: { t = t.addingTimeInterval(2); return t })
        XCTAssertTrue(timed.truncated)
    }

    func testAMissingAndAReadOnlyFolder() throws {
        XCTAssertFalse(WorkspaceChangedFiles.walk(root.appendingPathComponent("gone").path, since: .distantPast).exists)
        try touch("ro/inner/a.txt")
        chmod(root.appendingPathComponent("ro/inner").path, 0o000)
        defer { chmod(root.appendingPathComponent("ro/inner").path, 0o755) }
        let r = WorkspaceChangedFiles.walk(root.appendingPathComponent("ro").path, since: .distantPast)
        XCTAssertTrue(r.exists)
        XCTAssertTrue(r.changes.isEmpty, "an unreadable folder is skipped, never an error")
    }

    /// The rule's test: a repository whose `.git/config` would run a program on any git status (`core.fsmonitor`) — the walk
    /// never runs it; and the walk's source starts no process of any kind.
    func testNoProgramIsRunInTheFolder() throws {
        let repo = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let marker = root.appendingPathComponent("RAN")
        let hook = root.appendingPathComponent("monitor.sh")
        try Data("#!/bin/sh\ntouch '\(marker.path)'\n".utf8).write(to: hook)
        chmod(hook.path, 0o755)
        try Data("[core]\n\tfsmonitor = \(hook.path)\n[filter \"x\"]\n\tclean = \(hook.path)\n".utf8).write(to: repo.appendingPathComponent(".git/config"))
        try Data("* filter=x\n".utf8).write(to: repo.appendingPathComponent(".gitattributes"))
        try Data("a".utf8).write(to: repo.appendingPathComponent("a.txt"))
        let r = WorkspaceChangedFiles.walk(repo.path, since: Date().addingTimeInterval(-60))
        XCTAssertTrue(r.changes.contains { $0.path == "a.txt" })
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "a program ran in the agent's folder")
        // The source of the walk and the folders read: no process, no shell, no git.
        let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for file in ["Sources/DozableHost/WorkspaceChangedFiles.swift", "Sources/DozableHost/HostCore+WorkspaceViews.swift"] {
            let src = try String(contentsOf: here.appendingPathComponent(file), encoding: .utf8)
            for word in ["Process(", "posix_spawn", "popen(", "system(", "NSTask", "/usr/bin/git", "\"git\""] {
                XCTAssertFalse(src.contains(word), "\(file) contains \(word)")
            }
        }
    }
}

/// The log in pages: `before` and `limit`, a torn line skipped the same way, stable while appending, 10,000 lines read one page.
final class WorkspaceLogPageTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = URL(fileURLWithPath: "/tmp/doz-wlp-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    var ws: WorkspaceStore { WorkspaceStore(store: DozableStore(root: root.appendingPathComponent("store"))) }

    func make(_ n: Int) throws {
        let brief = Data("b\n".utf8)
        let rec = WorkspaceRecord(name: "demo", createdAt: Date(), brief: WorkspaceBrief(sha256: WorkspaceStore.sha256(brief), bytes: 2, updatedAt: Date()), folders: [])
        try ws.create(rec, brief: brief, log: (0..<n).map { WorkspaceLogEntry(at: Date(timeIntervalSince1970: Double($0)), action: "renamed", from: "a\($0)") })
    }

    func testBeforeAndLimit() throws {
        try make(10)
        let p1 = try ws.logPage("demo", limit: 4)
        XCTAssertEqual(p1.entries.map(\.from), ["a9", "a8", "a7", "a6"])
        XCTAssertTrue(p1.more)
        let p2 = try ws.logPage("demo", before: p1.first, limit: 4)
        XCTAssertEqual(p2.entries.map(\.from), ["a5", "a4", "a3", "a2"])
        let p3 = try ws.logPage("demo", before: p2.first, limit: 4)
        XCTAssertEqual(p3.entries.map(\.from), ["a1", "a0"])
        XCTAssertFalse(p3.more)
        XCTAssertEqual(p3.first, 0)
        XCTAssertEqual(try ws.logPage("demo", before: 0, limit: 4).entries, [])
    }

    func testATornLineIsSkippedTheSameWayEveryTime() throws {
        try make(3)
        let path = ws.folder("demo") + "/log.jsonl"
        let h = try XCTUnwrap(FileHandle(forWritingAtPath: path))
        h.seekToEndOfFile()
        h.write(Data("{\"v\":1,\"at\":".utf8))                 // a write cut short
        h.closeFile()
        XCTAssertEqual(try ws.logPage("demo").entries.map(\.from), ["a2", "a1", "a0"])
        try ws.append("demo", WorkspaceLogEntry(at: Date(timeIntervalSince1970: 100), action: "renamed", from: "after"))
        let all = try ws.logPage("demo", limit: 10)
        XCTAssertEqual(all.entries.map(\.from), ["after", "a2", "a1", "a0"])
        XCTAssertEqual(try ws.logPage("demo", limit: 2).entries.map(\.from), ["after", "a2"])
        XCTAssertEqual(try ws.logPage("demo", before: try ws.logPage("demo", limit: 2).first, limit: 2).entries.map(\.from), ["a1", "a0"])
    }

    func testStableWhileAppending() throws {
        try make(6)
        let p1 = try ws.logPage("demo", limit: 3)
        for i in 0..<5 { try ws.append("demo", WorkspaceLogEntry(action: "renamed", from: "new\(i)")) }
        let p2 = try ws.logPage("demo", before: p1.first, limit: 3)
        XCTAssertEqual(p2.entries.map(\.from), ["a2", "a1", "a0"], "the page before a page is the same after appends")
    }

    func testTenThousandLinesReadOnePage() throws {
        try make(10_000)
        let t0 = Date()
        let p = try ws.logPage("demo", limit: 200)
        XCTAssertEqual(p.entries.count, 200)
        XCTAssertEqual(p.entries.first?.from, "a9999")
        XCTAssertEqual(p.entries.last?.from, "a9800")
        XCTAssertLessThan(Date().timeIntervalSince(t0), 0.5)
        // The limit is held to 500.
        XCTAssertEqual(try ws.logPage("demo", limit: 9_999).entries.count, WorkspaceLogPage.maximumLimit)
    }

    func testTheOperationRefusesABadLimitAndAnswersAPage() async throws {
        try make(5)
        let c = HostCore(store: DozableStore(root: root.appendingPathComponent("store")), readOnly: true, version: "test")
        await c.load()
        var w = WorkspaceRequest(name: "demo")
        w.limit = 501
        var r = HostRequest(.workspaceLog)
        r.workspaceRequest = w
        let bad = await c.handle(r)
        XCTAssertEqual(bad.error?.code, .invalid)
        w.limit = 2
        r.workspaceRequest = w
        let got = await c.handle(r)
        let page = try XCTUnwrap(got.result).decode(WorkspaceLogPage.self)
        XCTAssertEqual(page.entries.map(\.from), ["a4", "a3"])
        // Without before/limit the answer is the entries, as before.
        r.workspaceRequest = WorkspaceRequest(name: "demo")
        let old = await c.handle(r)
        XCTAssertEqual(try XCTUnwrap(old.result).decode([WorkspaceLogEntry].self).count, 5)
    }
}

/// `AgentCapabilities.permissions` — pure: the counts are `permissions show`'s, the ceiling the strictest cap per permission
/// with whose it is, "none set: no cap" when nothing caps it.
final class AgentCapabilitiesTests: XCTestCase {
    func answers(_ actsAsYou: Bool = false) -> AgentGrantAnswers {
        let f = GrantFacts(macCeiling: ["sudo": .never], botCeiling: ["spend": .ask, "sudo": .never])
        let rows = GrantPermissions.ids.map { p in
            GrantAnswerRow(GrantDecision.decide(GrantQuery(name: "bot1", home: "demo", bot: nil, perm: p, workspace: "demo",
                                                           recordRoles: [HeldRole(role: "worker", workspace: "demo")]), f), enforced: PermissionWords.notYet)
        }
        return AgentGrantAnswers(name: "bot1", workspace: "demo", bot: nil, roles: ["worker (from the workspace)"], actsAsYou: actsAsYou, rows: rows)
    }

    func testThePermissionsAndCeilingRows() {
        let g = answers()
        let ceilings = [CeilingRow(lid: "mac", words: "this Mac's", perm: "sudo", answer: "never"),
                        CeilingRow(lid: "bot:otto", words: "otto's", perm: "sudo", answer: "never"),
                        CeilingRow(lid: "bot:otto", words: "otto's", perm: "spend", answer: "ask")]
        let rows = AgentCapabilities.permissions(g, ceilings: ceilings, workspace: "demo")
        XCTAssertEqual(rows.map(\.id), ["permissions", "ceiling"])
        XCTAssertEqual(rows[0].state, g.counts)
        XCTAssertEqual(rows[0].link, "doz permissions show demo --agent bot1")
        XCTAssertTrue(rows[0].sentence.contains("worker (from the workspace)") && rows[0].sentence.contains("not enforced yet"))
        XCTAssertEqual(rows[1].state, "1 never · 1 ask (otto's, this Mac's)")
        XCTAssertTrue(rows[1].sentence.contains("spend=ask (otto's)") && rows[1].sentence.contains("sudo=never (this Mac's, otto's)"), rows[1].sentence)
        XCTAssertTrue(rows.allSatisfy { $0.editable == "live" })
        XCTAssertEqual(AgentCapabilities.permissions(g, ceilings: [], workspace: "demo")[1].state, "none set: no cap")
        XCTAssertTrue(AgentCapabilities.permissions(answers(true), ceilings: [], workspace: "demo")[0].sentence.contains("a promise"))
        let c = g.rows.reduce(into: [String: Int]()) { $0[$1.answer, default: 0] += 1 }
        XCTAssertEqual(g.counts, "allow \(c["allow"] ?? 0) · ask \(c["ask"] ?? 0) · never \(c["never"] ?? 0)")
    }
}
