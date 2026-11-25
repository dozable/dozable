import CryptoKit
import DozableChat
import Foundation
import XCTest
@testable import DozableKit
@testable import DozableHost
@testable import DozableCLI

/// `workspace-plan` (the New workspace wizard, `doz workspace new --dry-run`): the plan and `new` agree over a table of
/// requests — `refusals` is empty exactly when `new` succeeds, and the made record is the draft apart from its times; the
/// plan writes nothing (the store's tree unchanged, no room, no log); its gaps; a look never reads the keychain; with no
/// daemon chat is judged from its setting; the presets; `newFolder`, `workerIsolation`, `network`. And the one command
/// source: each request's commands parse back into the same request. Scratch stores, a memory keychain that counts its
/// reads, the fake chat and launcher of `WorkspaceManagerTests`.
final class WorkspacePlanTests: BotTestCase {
    /// A memory keychain that counts reads of the bots' items.
    final class CountingKeychain: KeychainAccess, @unchecked Sendable {
        let inner = MemoryKeychain()
        let lock = NSLock()
        var reads = 0
        func read(service: String, account: String?) -> KeychainRead {
            if service.hasPrefix("doz-bot-") { lock.withLock { reads += 1 } }
            return inner.read(service: service, account: account)
        }
        func write(service: String, account: String, secret: String) throws { try inner.write(service: service, account: account, secret: secret) }
        func delete(service: String, account: String) throws { try inner.delete(service: service, account: account) }
        func items(servicePrefix: String) -> [KeychainItemInfo] { inner.items(servicePrefix: servicePrefix) }
        var count: Int { lock.withLock { reads } }
    }

    var trace: WorkspaceManagerTests.Trace!
    var wchat: WorkspaceManagerTests.Chat!
    var launcher: WorkspaceManagerTests.Launcher!
    var counting: CountingKeychain!
    var work: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        trace = WorkspaceManagerTests.Trace()
        wchat = WorkspaceManagerTests.Chat(trace)
        launcher = WorkspaceManagerTests.Launcher(trace)
        counting = CountingKeychain()
        work = root.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        work = URL(fileURLWithPath: WorkspaceStore.resolved(work.path))
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: bin.appendingPathComponent("claude").path, contents: Data("#!/bin/sh\n".utf8),
                                       attributes: [.posixPermissions: 0o755])
        setenv("DOZ_TEST_MAC_PATH", bin.path + ":/usr/bin:/bin", 1)
        setenv("DOZ_TEST_FENCE_HOME", root.appendingPathComponent("home").path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("DOZ_TEST_MAC_PATH")
        unsetenv("DOZ_TEST_FENCE_HOME")
        try super.tearDownWithError()
    }

    func daemon(readOnly: Bool = false, chat: Bool = true) async -> HostCore {
        let s = CredentialServices(keychain: counting, verifier: FakeVerifier(answer: .verified), claudeBinary: { nil }, home: root,
                                   keepaliveRunner: FakeRunner(), isClaudeRunning: { false }, watchInterval: .seconds(3600))
        let c = HostCore(store: store, readOnly: readOnly, version: "test", services: s)
        await c.load()
        if !readOnly {
            await c.setBotChat(self.chat)
            if chat { await c.setWorkspaceChat(wchat) }
        }
        await c.setManagerLauncher(launcher)
        return c
    }

    func send(_ c: HostCore, _ op: HostOp, _ w: WorkspaceRequest) async -> HostMessage {
        var r = HostRequest(op)
        r.workspaceRequest = w
        return await c.handle(r)
    }

    func plan(_ c: HostCore, _ w: WorkspaceRequest, file: StaticString = #filePath, line: UInt = #line) async throws -> WorkspacePlan {
        let m = await send(c, .workspacePlan, w)
        XCTAssertNil(m.error, m.error?.message ?? "", file: file, line: line)
        return try XCTUnwrap(m.result, file: file, line: line).decode(WorkspacePlan.self)
    }

    func show(_ c: HostCore, _ n: String) async throws -> WorkspaceDetail {
        let m = await send(c, .workspaceShow, WorkspaceRequest(name: n))
        return try XCTUnwrap(m.result, m.error?.message ?? "").decode(WorkspaceDetail.self)
    }

    func made(_ c: HostCore, _ w: WorkspaceRequest, file: StaticString = #filePath, line: UInt = #line) async {
        let m = await send(c, .workspaceNew, w)
        XCTAssertNil(m.error, m.error?.message ?? "", file: file, line: line)
    }

    func request(_ name: String, _ edit: (inout WorkspaceRequest) -> Void = { _ in }) -> WorkspaceRequest {
        var w = WorkspaceRequest(name: name)
        w.brief = "Make the launch video.\n"
        w.folders = [WorkspaceFolder(path: work.path)]
        edit(&w)
        return w
    }

    func newBot(_ c: HostCore, _ name: String = "mira", isolation: String = "fenced") async throws {
        _ = try change(await ask(c, .botNew, name) { $0.agent = "claude-code"; $0.isolation = isolation })
    }

    /// Every file under the store with its bytes' sha256 — "nothing written".
    func treeDigest() -> [String: String] {
        var out: [String: String] = [:]
        let base = store.root.path
        guard let e = FileManager.default.enumerator(atPath: base) else { return [:] }
        for case let p as String in e {
            // Logs, and the daemon's own metrics database (its sampler writes the WAL on a timer, whatever a request does).
            if p.hasSuffix(".log") || p.hasPrefix("logs") || p.hasPrefix("metrics.sqlite") { continue }
            let full = base + "/" + p
            var d: ObjCBool = false
            FileManager.default.fileExists(atPath: full, isDirectory: &d)
            out[p] = d.boolValue ? "dir" : (FileManager.default.contents(atPath: full).map { SHA256.hash(data: $0).description } ?? "?")
        }
        return out
    }

    static func timeless(_ r: WorkspaceRecord) -> WorkspaceRecord {
        var r = r
        r.createdAt = .distantPast
        r.brief.updatedAt = .distantPast
        for i in r.agents.indices { r.agents[i].startedAt = .distantPast }
        if r.flags.firstAgentAt != nil { r.flags.firstAgentAt = .distantPast }
        return r
    }

    // MARK: plan and new agree

    func testThePlanAndNewAgree() async throws {
        let c = await daemon()
        try await newBot(c)
        try await newBot(c, "otto", isolation: "unfenced")
        _ = await send(c, .workspaceNew, request("taken"))
        wchat.roomSet.insert("clash")
        let rows: [(String, WorkspaceRequest)] = [
            ("plain", request("plain")),
            ("no folder", request("nofolder") { $0.folders = [] }),
            ("empty brief", request("empty") { $0.brief = "  \n" }),
            ("missing folder", request("missing") { $0.folders = [WorkspaceFolder(path: self.work.path + "/nope")] }),
            ("taken", request("taken")),
            ("room clash", request("clash")),
            ("linked", request("linked") { $0.room = "general" }),
            ("no such room", request("noroom") { $0.room = "nosuch" }),
            ("manager", request("managed") { $0.manager = "mira" }),
            ("unfenced manager", request("unf") { $0.manager = "otto"; $0.managerIsolation = "unfenced" }),
            ("unknown bot", request("unknown") { $0.manager = "nosuch" }),
            ("isolation without manager", request("iso") { $0.managerIsolation = "vm" }),
            ("worker vm", request("wvm") { $0.workerIsolation = "vm"; $0.network = "open" }),
            ("worker unfenced", request("wunf") { $0.workerIsolation = "unfenced" }),
            ("several", request("Bad Name") { $0.brief = ""; $0.workerIsolation = "unfenced" }),
            ("room and no room", request("both") { $0.room = "general"; $0.noRoom = true }),
        ]
        for (label, w) in rows {
            let p = try await plan(c, w)
            let draft = await c.workspaceNewDraft(w, look: true)
            let m = await send(c, .workspaceNew, w)
            XCTAssertEqual(p.refusals.isEmpty, m.error == nil, "\(label): \(p.refusals) vs \(m.error?.message ?? "made")")
            if let e = m.error {
                XCTAssertEqual(p.refusals.first, e.message, label)
                XCTAssertEqual(p.refusalCode, e.code.rawValue, label)
            } else {
                let made = try XCTUnwrap(try WorkspaceStore(store: store).read(w.name!), label)
                XCTAssertEqual(Self.timeless(made), Self.timeless(draft.record), label)
                XCTAssertEqual(try WorkspaceStore(store: store).log(w.name!).map(\.action), draft.log.map(\.action), label)
            }
        }
        // Several at once: every refusal, in new's order.
        let several = try await plan(c, request("Bad Name") { $0.brief = ""; $0.workerIsolation = "unfenced" })
        XCTAssertEqual(several.refusals.count, 2, "\(several.refusals) — 782: an empty description is no refusal")
        XCTAssertEqual(several.refusalCode, "invalid")
    }

    func testThePlanWritesNothing() async throws {
        let c = await daemon()
        try await newBot(c)
        let before = treeDigest()
        let posts = wchat.posts.count
        let rooms = wchat.roomSet
        let p = try await plan(c, request("demo") { $0.manager = "mira"; $0.newFolder = true })
        XCTAssertTrue(p.refusals.isEmpty, "\(p.refusals)")
        XCTAssertEqual(treeDigest(), before, "the store's tree is unchanged")
        XCTAssertEqual(wchat.posts.count, posts)
        XCTAssertEqual(wchat.roomSet, rooms, "no room made")
        XCTAssertFalse(WorkspaceStore(store: store).exists("demo"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: WorkspaceStore.resolved(Workspace.defaultPath(name: "demo"))), "no folder made")
        XCTAssertEqual(trace.all, [], "nothing posted or started")
        XCTAssertTrue(p.lines.contains { $0.contains("room: #demo is made") }, "\(p.lines)")
        XCTAssertTrue(p.lines.contains("manager: mira · fenced"), "\(p.lines)")
    }

    func testGapsPerItem() async throws {
        let c = await daemon()
        try await newBot(c)
        // 782: an empty description is no refusal and no gap.
        var p = try await plan(c, request("demo") { $0.brief = "" })
        XCTAssertEqual(p.refusals, [])
        XCTAssertEqual(p.gaps, [])
        XCTAssertTrue(p.lines.contains("description: none yet — the manager asks in the room"), "\(p.lines)")
        // A manager with chat off: the chat gap.
        wchat.off = true
        p = try await plan(c, request("demo") { $0.manager = "mira" })
        XCTAssertEqual(p.gaps.map(\.item), ["chat"])
        XCTAssertTrue(p.lines.contains("room: none"))
        // No manager, chat off: nothing to set up (you drive).
        p = try await plan(c, request("demo"))
        XCTAssertEqual(p.gaps, [])
        wchat.off = false
        // Chat on with no room asked for: the room gap.
        p = try await plan(c, request("demo") { $0.noRoom = true })
        XCTAssertEqual(p.gaps.map(\.item), ["room"])
        // A program not on the PATH.
        setenv("DOZ_TEST_MAC_PATH", "/usr/bin:/bin", 1)
        let c2 = await daemon()
        p = try await plan(c2, request("demo") { $0.manager = "mira" })
        XCTAssertEqual(p.gaps.map(\.item), ["manager"], "\(p.gaps)")
    }

    func testALookNeverReadsTheKeychain() async throws {
        let c = await daemon()
        try await newBot(c)
        let before = counting.count
        _ = try await plan(c, request("demo") { $0.manager = "mira" })
        XCTAssertEqual(counting.count, before, "the plan reads no bot's item")
        await made(c, request("demo") { $0.manager = "mira" })
        let shown = try await show(c, "demo")
        XCTAssertEqual(shown.gaps, [], "set up: no gap")
        XCTAssertEqual(counting.count, before, "show reads no bot's item")
        // A locked keychain shows only at the start.
        try counting.inner.delete(service: BotTokens.service(store: store.root, name: "mira"), account: Keychain.user)
        let again = try await show(c, "demo")
        XCTAssertEqual(again.gaps, [])
        let start = await send(c, .workspaceStart, WorkspaceRequest(name: "demo"))
        XCTAssertTrue(start.error?.message.contains("keychain") == true, start.error?.message ?? "")
        XCTAssertGreaterThan(counting.count, before, "the start reads it")
    }

    func testShowsGapsOnlyWhileSettingUp() async throws {
        let c = await daemon()
        await made(c, request("demo"))
        try FileManager.default.removeItem(at: work)
        var d = try await show(c, "demo")
        XCTAssertEqual(d.gaps?.map(\.item), ["folder"])
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        _ = await send(c, .workspaceStart, WorkspaceRequest(name: "demo"))
        d = try await show(c, "demo")
        XCTAssertEqual(d.state, "asleep")
        XCTAssertNil(d.gaps, "started: no gaps")
    }

    func testWithNoDaemonChatIsJudgedFromItsSetting() async throws {
        let d = await daemon()
        try await newBot(d)
        let c = await daemon(readOnly: true)
        await c.setChatSettingOverride(true)
        var p = try await plan(c, request("demo") { $0.manager = "mira" })
        XCTAssertEqual(p.refusals, [])
        XCTAssertEqual(p.gaps, [], "on, starts with Dozable: the room will be made")
        XCTAssertTrue(p.notes.contains { $0.contains("checked when it is made") }, "\(p.notes)")
        await c.setChatSettingOverride(false)
        p = try await plan(c, request("demo") { $0.manager = "mira" })
        XCTAssertEqual(p.gaps.map(\.item), ["chat"])
        XCTAssertEqual(trace.all, [])
    }

    func testPresetsRoundTrip() throws {
        let data = try JSONEncoder().encode(WorkspacePresets.builtIn)
        XCTAssertEqual(try JSONDecoder().decode([WorkspacePreset].self, from: data), WorkspacePresets.builtIn)
        XCTAssertEqual(WorkspacePresets.builtIn.map(\.id), ["remotion-video", "blank"])
        XCTAssertFalse(WorkspacePresets.builtIn.contains { $0.workerIsolation == "unfenced" || $0.managerIsolation == "unfenced" })
        // 782 (D7): the retired presets are refused, naming what to use instead.
        for id in ["swift-tests", "mac-admin", "research"] {
            XCTAssertThrowsError(try WorkspacePresets.named(id)) { e in
                XCTAssertTrue(HostError.from(e).message.contains("was retired"), "\(e)")
            }
        }
    }

    // MARK: 782 — the wizard's answers

    /// An empty description: made, nothing posted at the start, the manager's START asks what to work on.
    func testAnEmptyDescriptionIsMadeAndNothingIsPosted() async throws {
        let c = await daemon()
        await made(c, request("quiet") { $0.brief = "" })
        let d = try await show(c, "quiet")
        XCTAssertEqual(d.brief.bytes, 0)
        let s = await send(c, .workspaceStart, WorkspaceRequest(name: "quiet"))
        XCTAssertNil(s.error, s.error?.message ?? "")
        XCTAssertFalse(trace.all.contains { $0.hasPrefix("post quiet") }, "nothing posted as you: \(trace.all)")
        let start = ManagerKickoff.startText(bot: "mira", workspace: "w", room: "w", isolation: .fenced, skills: [], instructions: nil, brief: "", refs: [])
        XCTAssertTrue(start.contains(ManagerKickoff.noDescription))
        XCTAssertTrue(start.contains("ask the person what to work on"))
    }

    /// No name: the next free workspaceN, skipping a workspace, a room, a non-empty projects folder, a sandbox or a session
    /// of that name; the plan names it (`suggested`), and `new` makes it.
    func testTheNextFreeNameSkipsEveryKindOfCollision() async throws {
        let c = await daemon()
        var p = try await plan(c, WorkspaceRequest())
        XCTAssertEqual(p.suggested?.name, "workspace1")
        XCTAssertEqual(p.suggested?.folder, WorkspaceStore.resolved(Workspace.defaultPath(name: "workspace1")))
        XCTAssertEqual(p.name, "workspace1", "no name: the plan is the next free one's")
        await made(c, request("workspace1"))
        wchat.roomSet.insert("workspace2")                                    // a room of that name
        let folder3 = WorkspaceStore.resolved(Workspace.defaultPath(name: "workspace3"))
        try FileManager.default.createDirectory(atPath: folder3, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: folder3 + "/x", contents: Data())   // a folder that holds something
        defer { try? FileManager.default.removeItem(atPath: folder3) }
        let folder4 = WorkspaceStore.resolved(Workspace.defaultPath(name: "workspace4"))
        try FileManager.default.createDirectory(atPath: folder4, withIntermediateDirectories: true)   // empty: free
        defer { try? FileManager.default.removeItem(atPath: folder4) }
        p = try await plan(c, WorkspaceRequest())
        XCTAssertEqual(p.suggested?.name, "workspace4", "\(String(describing: p.suggested))")
        var w = request("x")
        w.name = nil
        let m = await send(c, .workspaceNew, w)
        XCTAssertNil(m.error, m.error?.message ?? "")
        XCTAssertEqual(try m.result?.decode(WorkspaceDetail.self).name, "workspace4")
    }

    /// Each bot's fitness as the manager, from the same checks as the set-up check's (`managerFindings`), in the wizard's
    /// words with its one fix: fits; reached by inbox while fenced (Reach it by poll); a webhook; elsewhere; a program not
    /// installed (a Sandbox bot stays fit); live elsewhere; retired ones are not listed.
    func testManagerFitnessFollowsTheSetUpCheck() async throws {
        let c = await daemon()
        try await newBot(c, "mira")
        try await newBot(c, "vera", isolation: "vm")
        _ = try change(await ask(c, .botNew, "ida") { $0.agent = "claude-code"; $0.isolation = "fenced"; $0.deliver = "inbox" })
        _ = try change(await ask(c, .botNew, "otto") { $0.agent = "claude-code"; $0.isolation = "unfenced"; $0.deliver = "inbox" })
        var p = try await plan(c, request("demo"))
        let fits = Dictionary(uniqueKeysWithValues: (p.managers ?? []).map { ($0.bot, $0) })
        XCTAssertEqual(fits["mira"]?.fits, true)
        XCTAssertEqual(fits["vera"]?.fits, true)
        XCTAssertEqual(fits["otto"]?.fits, true, "unfenced and reached by inbox: the one combination that works for it")
        XCTAssertEqual(fits["ida"]?.fits, false)
        XCTAssertEqual(fits["ida"]?.why, "Reached by inbox, which only an unfenced session gets.")
        XCTAssertEqual(fits["ida"]?.fix, WorkspaceWizardFix(label: "Reach it by poll", action: "poll"))
        // Claude Code not installed: a fenced bot is folded, a Sandbox one is not.
        setenv("DOZ_TEST_MAC_PATH", "/usr/bin:/bin", 1)
        let c2 = await daemon()
        p = try await plan(c2, request("demo"))
        let f2 = Dictionary(uniqueKeysWithValues: (p.managers ?? []).map { ($0.bot, $0) })
        XCTAssertEqual(f2["mira"]?.why, "Claude Code is not installed on this Mac.")
        XCTAssertEqual(f2["vera"]?.fits, true)
        // Words: every code has a sentence with no `doz` command in it.
        for code in ["notBot", "retired", "elsewhere", "token", "keychain", "inbox", "webhook", "program", "agent", "placeTaken"] {
            let (why, _) = WorkspaceWizard.managerWords(code: code, bot: "b", agent: "claude-code", place: "w", isolation: "fenced")
            XCTAssertFalse(why.contains("doz "), why)
        }
    }

    /// Findings: the refusals and gaps in the wizard's words, on their steps — never a `doz …` command or "brief".
    func testFindingsAreInTheWizardsWords() async throws {
        let c = await daemon()
        try await newBot(c)
        await made(c, request("taken"))
        wchat.roomSet.insert("busy")
        var p = try await plan(c, request("taken"))
        XCTAssertTrue(p.findings?.contains(WorkspaceFinding(step: "name", field: "name", text: "There is already a workspace taken.")) == true, "\(p.findings ?? [])")
        p = try await plan(c, request("busy"))
        XCTAssertEqual(p.findings?.first { $0.field == "room" }?.fix?.action, "use-room", "\(p.findings ?? [])")
        wchat.off = true
        p = try await plan(c, request("demo") { $0.manager = "mira" })
        XCTAssertEqual(p.findings?.first?.step, "chat")
        XCTAssertEqual(p.findings?.first?.fix?.action, "chat-on")
        wchat.off = false
        for f in p.findings ?? [] { XCTAssertFalse(f.text.contains("doz ") || f.text.lowercased().contains("brief"), f.text) }
        XCTAssertEqual(WorkspaceWizard.refusal("which workspace? (doz workspace ls)", name: "").text, "Give it a name.")
        XCTAssertEqual(WorkspaceWizard.sentence("folder /x is gone — doz workspace edit w --remove-folder /x"), "Folder /x is gone.")
    }

    /// The room under another name, and who is invited to it (logged; a refusal for a bad name); the commands carry both.
    func testTheRoomNameAndInvites() async throws {
        let c = await daemon()
        try await newBot(c)
        await made(c, request("named") { $0.roomName = "team-room"; $0.invite = ["mira"] })
        let d = try await show(c, "named")
        XCTAssertEqual(d.rooms.first { $0.main }?.chatRoom, "team-room")
        XCTAssertTrue(wchat.roomSet.contains("team-room"))
        XCTAssertTrue(trace.all.contains { $0.contains("invite mira team-room") }, "\(trace.all)")
        let log = await send(c, .workspaceLog, WorkspaceRequest(name: "named"))
        XCTAssertTrue((try log.result?.decode([WorkspaceLogEntry].self) ?? []).contains { $0.action == "bot-invited" && $0.agent == "mira" })
        let bad = try await plan(c, request("other") { $0.roomName = "Bad Name" })
        XCTAssertFalse(bad.refusals.isEmpty)
        XCTAssertTrue(WorkspaceNewCommand.argv(request("n") { $0.roomName = "r"; $0.invite = ["a", "b"] }).joined(separator: " ")
            .contains("--room-name r --invite a --invite b"))
    }

    /// 782 (D1): `sandbox` is the input word for the isolation stored as vm — workers' default, a manager's, a bot's.
    func testSandboxIsTheInputWordForVM() async throws {
        XCTAssertEqual(IsolationWord.stored("sandbox"), "vm")
        XCTAssertEqual(IsolationWord.stored("vm"), "vm")
        XCTAssertEqual(IsolationWord.stored("fenced"), "fenced")
        XCTAssertEqual(try ManagerIsolation.resolve(asked: "sandbox", botDefault: "fenced"), .vm)
        XCTAssertEqual(try WorkerIsolation.resolve(asked: "sandbox", workspaceDefault: nil, botDefault: nil), .vm)
        let c = await daemon()
        await made(c, request("sbx") { $0.workerIsolation = "sandbox" })
        XCTAssertEqual(try WorkspaceStore(store: store).read("sbx")?.defaults.isolation, "vm", "stored as vm")
        _ = try change(await ask(c, .botNew, "sam") { $0.agent = "claude-code"; $0.isolation = "sandbox" })
        let m = await send(c, .workspacePlan, request("p") { $0.manager = "sam" })
        XCTAssertNil(m.error)
    }

    /// 775: the remotion-video preset allows remotion.media (where a render downloads Remotion's browser) on top of
    /// Standard — in its dry run, its commands, the record, and the network every agent it starts gets.
    func testTheRemotionPresetAllowsRemotionMedia() async throws {
        let remotion = try WorkspacePresets.named("remotion-video")
        XCTAssertEqual(remotion.sites, ["remotion.media"])
        XCTAssertTrue(remotion.summary.contains("remotion.media"))
        var w = request("clip")
        WorkspacePresets.apply(remotion, to: &w, folderModeGiven: [true])
        XCTAssertEqual(w.network, "standard")
        XCTAssertEqual(w.sites, ["remotion.media"])
        // A site given joins it, once each.
        var w2 = request("clip") { $0.sites = ["api.example.com", "remotion.media"] }
        WorkspacePresets.apply(remotion, to: &w2, folderModeGiven: [true])
        XCTAssertEqual(w2.sites, ["api.example.com", "remotion.media"])
        XCTAssertTrue(WorkspaceNewCommand.argv(w).joined(separator: " ").contains("--network standard --site remotion.media"))
        let c = await daemon()
        let p = try await plan(c, w)
        XCTAssertEqual(p.refusals, [])
        XCTAssertTrue(p.lines.contains("network: standard + remotion.media + the room"), "\(p.lines)")
        XCTAssertTrue(p.commands.contains("--site remotion.media"), p.commands)
        let m = await send(c, .workspaceNew, w)
        XCTAssertNil(m.error, m.error?.message ?? "")
        let rec = try XCTUnwrap(try WorkspaceStore(store: store).read("clip"))
        XCTAssertEqual(rec.defaults, WorkspaceDefaults(isolation: "vm", network: "standard", sites: ["remotion.media"]))
        XCTAssertEqual(rec.defaults.siteWords, ["site:remotion.media"])
        // Sites are host names: no port, no address of this Mac's route, at most 16; `site:` and case are taken.
        XCTAssertEqual(try WorkspaceNetworks.checkedSites(["site:Remotion.Media", "remotion.media"]), ["remotion.media"])
        XCTAssertNil(try WorkspaceNetworks.checkedSites([]))
        XCTAssertThrowsError(try WorkspaceNetworks.checkedSites(["remotion.media:443"]))
        XCTAssertThrowsError(try WorkspaceNetworks.checkedSites(["host.dozable.internal"]))
        XCTAssertThrowsError(try WorkspaceNetworks.checkedSites(["not a host"]))
        XCTAssertThrowsError(try WorkspaceNetworks.checkedSites((0..<17).map { "h\($0).example.com" }))
        let bad = await send(c, .workspacePlan, request("bad") { $0.sites = ["x.example.com:22"] })
        let badPlan = try XCTUnwrap(try bad.result?.decode(WorkspacePlan.self))
        XCTAssertTrue(badPlan.refusals.contains { $0.contains("no port") }, "\(badPlan.refusals)")
    }

    func testNewFolderWorkerIsolationAndNetwork() async throws {
        let c = await daemon()
        let target = WorkspaceStore.resolved(Workspace.defaultPath(name: "fresh"))
        let parent = (target as NSString).deletingLastPathComponent
        try? FileManager.default.removeItem(atPath: target)
        let before = Set((try? FileManager.default.contentsOfDirectory(atPath: parent)) ?? [])
        defer { try? FileManager.default.removeItem(atPath: target) }
        let m = await send(c, .workspaceNew, request("fresh") { $0.folders = []; $0.newFolder = true; $0.workerIsolation = "vm"; $0.network = "open" })
        XCTAssertNil(m.error, m.error?.message ?? "")
        var st = stat()
        XCTAssertEqual(lstat(target, &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o700)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: parent)).subtracting(before), ["fresh"], "only <projects_dir>/NAME")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target), [], "made empty")
        let rec = try XCTUnwrap(try WorkspaceStore(store: store).read("fresh"))
        XCTAssertEqual(rec.folders, [WorkspaceFolder(path: target, mode: "rw", main: true)])
        XCTAssertEqual(rec.defaults, WorkspaceDefaults(isolation: "vm", network: "open"))
        // Never unfenced by default.
        let u = await send(c, .workspaceNew, request("unf") { $0.workerIsolation = "unfenced" })
        XCTAssertEqual(u.error?.code, .invalid)
        XCTAssertTrue(u.error?.message.contains("never unfenced by default") == true)
        XCTAssertFalse(WorkspaceStore(store: store).exists("unf"))
    }

    // MARK: the one command source

    func testTheCommandsParseBackIntoTheSameRequest() throws {
        let odd = root.appendingPathComponent("odd 'dir':ro")
        try FileManager.default.createDirectory(at: odd, withIntermediateDirectories: true)
        let oddPath = WorkspaceStore.resolved(odd.path)
        let briefs = ["Make it.\n", "Line one\nDOZ_BRIEF_x\n'quoted' $HOME `tick`\n"]
        for brief in briefs {
            var w = WorkspaceRequest(name: "demo")
            w.brief = brief
            w.refs = ["https://example.com/a?b=c&d", oddPath]
            w.folders = [WorkspaceFolder(path: work.path), WorkspaceFolder(path: oddPath, mode: "ro"), WorkspaceFolder(path: oddPath + "x:rw")]
            w.newFolder = true
            w.room = "general"
            w.manager = "mira"
            w.managerIsolation = "unfenced"
            w.workerIsolation = "vm"
            w.network = "standard"
            w.adopt = ["wsa", "@mac/wsu"]
            let argv = WorkspaceNewCommand.argv(w)
            XCTAssertEqual(Array(argv.prefix(3)), ["doz", "workspace", "new"])
            let cmd = try WorkspaceNew.parse(Array(argv.dropFirst(3)))
            XCTAssertEqual(cmd.promptFile, "-")
            // The heredoc gives the brief back, its delimiter absent from the text.
            let text = WorkspaceNewCommand.text(w)
            let d = WorkspaceNewCommand.delimiter(brief)
            XCTAssertFalse(brief.contains(d))
            XCTAssertTrue(text.hasSuffix("\n" + d + "\n"))
            let body = text.components(separatedBy: "<<'\(d)'\n")[1].dropLast(d.count + 1)
            var back = try cmd.request(brief: String(body))
            back.brief = String(body)
            XCTAssertEqual(back, w, brief)
        }
        XCTAssertEqual(WorkspaceNewCommand.quote("it's"), "'it'\\''s'")
        XCTAssertEqual(WorkspaceNewCommand.quote("plain-word_1"), "plain-word_1")
    }

    func testTheProjectFillsInChoicesAndIsNeverWritten() throws {
        let file = work.appendingPathComponent("doz_project.yaml")
        let text = "name: demo\nimage: claude-code\nnetwork: open\n"
        try text.write(to: file, atomically: true, encoding: .utf8)
        var w = WorkspaceRequest(name: "demo")
        w.folders = [WorkspaceFolder(path: work.path)]
        try WorkspaceProjectFill.apply(&w) { try DozableProject.parse($0, file: $1) }
        XCTAssertEqual(w.network, "open")
        XCTAssertEqual(w.project, file.path)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), text, "never written")
        var differ = WorkspaceRequest(name: "demo")
        differ.folders = [WorkspaceFolder(path: work.path)]
        differ.network = "locked"
        XCTAssertThrowsError(try WorkspaceProjectFill.apply(&differ) { try DozableProject.parse($0, file: $1) })
        var none = WorkspaceRequest(name: "demo")
        XCTAssertThrowsError(try WorkspaceProjectFill.apply(&none) { try DozableProject.parse($0, file: $1) }) {
            XCTAssertTrue(HostError.from($0).message.contains("--folder"))
        }
    }
}

/// The dashboard's start asks for the person's confirmation of an unfenced manager: without it the daemon refuses, nothing
/// posted or started; the CLI never asks.
extension WorkspaceManagerTests {
    func testConfirmRequiredRefusesAnUnconfirmedUnfencedManager() async throws {
        let c = await mgr()
        try await newBot(c, "otto", isolation: "unfenced")
        _ = try await newWorkspace(c, "solo", manager: "otto", isolation: "unfenced")
        var w = WorkspaceRequest(name: "solo")
        w.confirmRequired = true
        var r = HostRequest(.workspaceStart)
        r.workspaceRequest = w
        let refused = await c.handle(r)
        XCTAssertEqual(refused.error?.code, .invalidPhase)
        XCTAssertEqual(refused.error?.message, "otto acts as you — confirm it")
        XCTAssertEqual(trace.all, [], "nothing posted, nothing started")
        XCTAssertNil(try record("solo")?.flags.startedAt)
        w.unfencedConfirmed = true
        r.workspaceRequest = w
        let s = try started(await c.handle(r))
        XCTAssertEqual(s.isolation, "unfenced")
        _ = await ws(c, .workspaceStop, "solo") { $0.managerOnly = true }
        try? FileManager.default.removeItem(atPath: c.managerTokenRoot)
    }
}
