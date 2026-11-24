import Foundation
import XCTest
@testable import DozableKit
@testable import DozableHost

/// The workspace operations in an in-process daemon core on a scratch store (no VM: a lab sandbox made, never booted)
/// with a fake chat server: adopt and release, one workspace only, missing targets, bare @mac, check-then-write (the bytes
/// unchanged on every refusal), the sandbox's doz.json and sessions.json never written, the rename/rm hooks, the
/// `workspace` field, every room case, and a read-only core that answers looking and refuses changing.
final class WorkspaceAdoptTests: XCTestCase {
    private var root: URL!
    private var folder: URL!
    let keychain = FakeKeychain()

    final class FakeChat: WorkspaceChat, @unchecked Sendable {
        let lock = NSLock()
        var state: WorkspaceChatReadiness = .ready
        var roomSet: Set<String> = ["general"]
        var made: [String] = []
        func readiness() async -> WorkspaceChatReadiness { lock.withLock { state } }
        func rooms() throws -> Set<String> { lock.withLock { roomSet } }
        func makeRoom(_ name: String) throws { lock.withLock { roomSet.insert(name); made.append(name) } }
        func post(room: String, content: String) throws {}
        func invite(room: String, name: String) throws -> Bool { false }
    }

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: "/tmp/doz-wsa-\(UUID().uuidString.prefix(8))")
        folder = root.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        folder = URL(fileURLWithPath: WorkspaceStore.resolved(folder.path))
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    var store: DozableStore { DozableStore(root: root.appendingPathComponent("store")) }
    var ws: WorkspaceStore { WorkspaceStore(store: store) }

    func core(readOnly: Bool = false, chat: WorkspaceChat? = nil) async -> HostCore {
        let s = CredentialServices(keychain: keychain, verifier: FakeVerifier(answer: .verified), claudeBinary: { nil }, home: root,
                                   keepaliveRunner: FakeRunner(), isClaudeRunning: { false }, watchInterval: .seconds(3600))
        let c = HostCore(store: store, readOnly: readOnly, version: "test", services: s)
        await c.load()
        await c.setWorkspaceChat(chat)
        return c
    }

    func sandbox(_ c: HostCore, _ name: String) async {
        var r = HostRequest(.create, name: name)
        r.create = CreateOptions(image: "lab")
        let m = await c.handle(r)
        XCTAssertNil(m.error, m.error?.message ?? "")
    }

    /// A recorded session on this Mac (its holder gone — no process is started).
    func macSession(_ name: String) throws {
        let dir = store.root.appendingPathComponent("mac-sessions")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("sessions.json")
        var recs = (try? Data(contentsOf: file)).flatMap { try? HostWire.decoder.decode(MacSessionRecords.self, from: $0) } ?? MacSessionRecords()
        recs.sessions[name] = MacSessionRecord(argv: ["/bin/sh"], workdir: folder.path, openedAt: Date())
        try HostWire.prettyEncoder.encode(recs).write(to: dir.appendingPathComponent("sessions.json"))
    }

    @discardableResult
    func ask(_ c: HostCore, _ op: HostOp, _ w: WorkspaceRequest) async -> HostMessage {
        var r = HostRequest(op)
        r.workspaceRequest = w
        return await c.handle(r)
    }

    func new(_ c: HostCore, _ name: String, folders: [String]? = nil, room: String? = nil, noRoom: Bool? = nil, adopt: [String]? = nil,
             project: String? = nil) async -> HostMessage {
        var w = WorkspaceRequest(name: name)
        w.brief = "Make the launch video.\n"
        w.folders = (folders ?? [folder.path]).map { WorkspaceFolder(path: $0) }
        w.room = room
        w.noRoom = noRoom
        w.adopt = adopt
        w.project = project
        return await ask(c, .workspaceNew, w)
    }

    func adopt(_ c: HostCore, _ name: String, _ agent: String, as asName: String? = nil) async -> HostMessage {
        var w = WorkspaceRequest(name: name)
        w.agent = agent
        w.asName = asName
        return await ask(c, .workspaceAdopt, w)
    }

    func bytes(_ path: String) -> Data? { try? Data(contentsOf: URL(fileURLWithPath: path)) }
    func recordBytes(_ n: String) -> Data? { bytes(ws.folder(n) + "/workspace.json") }

    // MARK: adopt and release

    /// 771 (the owner's option B): an adopted agent's chat token is DELIVERED at session start — its own participant, its own
    /// keychain item, the fingerprint on the entry, a launch secret for every session in its place (a sandbox's and a session's
    /// on this Mac) — and nothing written to the sandbox's doz.json or sessions.json; --no-token keeps it off chat; release
    /// revokes it (the participant gone, the item deleted); a replaced token follows.
    func testAnAdoptedAgentsTokenIsDeliveredAtSessionStartAndReleaseRevokesIt() async throws {
        let c = await core(chat: FakeChat())
        let participants = FakeBotChat()
        await c.setBotChat(participants)
        await sandbox(c, "wsa")
        try macSession("wsu")
        try macSession("wsn")
        let docJSON = bytes(store.configFile("wsa").path)
        let sessionsJSON = bytes(store.root.appendingPathComponent("mac-sessions/sessions.json").path)
        var m = await new(c, "demo")
        XCTAssertNil(m.error, m.error?.message ?? "")
        m = await adopt(c, "demo", "wsa")
        XCTAssertNil(m.error, m.error?.message ?? "")
        m = await adopt(c, "demo", "@mac/wsu")
        XCTAssertNil(m.error, m.error?.message ?? "")
        let d = try XCTUnwrap(m.result).decode(WorkspaceDetail.self)
        XCTAssertTrue(d.notes?.contains { $0.contains("from now on gets its chat token and this store's chat address") } == true, "\(d.notes ?? [])")
        var w = WorkspaceRequest(name: "demo"); w.agent = "@mac/wsn"; w.noToken = true
        m = await ask(c, .workspaceAdopt, w)
        XCTAssertNil(m.error, m.error?.message ?? "")
        XCTAssertEqual(bytes(store.configFile("wsa").path), docJSON, "the sandbox's doz.json is never written")
        XCTAssertEqual(bytes(store.root.appendingPathComponent("mac-sessions/sessions.json").path), sessionsJSON, "sessions.json is never written")
        // Each a participant of its own, its token in its own item, the entry holding only the fingerprint.
        let names = try participants.directory().participants.map(\.name)
        XCTAssertTrue(names.contains("wsa") && names.contains("wsu"))
        XCTAssertFalse(names.contains("wsn"), "--no-token: no participant")
        let rec = try XCTUnwrap(ws.read("demo"))
        for a in ["wsa", "wsu"] {
            let e = try XCTUnwrap(rec.agents.first { $0.name == a })
            XCTAssertEqual(e.participant, a)
            let item = keychain.get(AdoptedToken.service(store: store.root, workspace: "demo", agent: a))
            XCTAssertEqual(item.map(CredentialFingerprint.of), e.tokenFingerprint, "\(a): its item is the token its fingerprint names")
        }
        XCTAssertNil(rec.agents.first { $0.name == "wsn" }?.tokenFingerprint)
        // Every session started in the place carries it (a sandbox's: in the secrets its sessions get; never its record).
        let sandboxSecret = await c.adoptedChatSecret(placeKey: "sandbox:wsa")
        XCTAssertEqual(sandboxSecret?.variable, "CHAT_TOKEN"); XCTAssertEqual(sandboxSecret?.fileVariable, "CHAT_TOKEN_FILE")
        XCTAssertEqual(sandboxSecret?.host, HostRoute.hostName)
        XCTAssertTrue(sandboxSecret.flatMap(\.keychainService).map(AdoptedToken.isAdopted) == true)
        let carried = await c.sessionSecretsOf("wsa")
        XCTAssertEqual(carried.map(\.variable), ["CHAT_TOKEN"], "a session of wsa gets its token")
        let macSecret = await c.adoptedChatSecret(placeKey: "mac:wsu"), none = await c.adoptedChatSecret(placeKey: "mac:wsn")
        XCTAssertNotNil(macSecret, "a session on this Mac in the place gets it too")
        XCTAssertNil(none, "--no-token: nothing")
        // A restart's reopen delivers what a new open does (macOpen and macReopen share `adoptedMacDelivery`; a sandbox's
        // restart opens through openSession, which `sessionSecrets` feeds): fenced, its launch secret and the page port;
        // unfenced, a token file; what the session was given wins.
        let fenced = try await c.adoptedMacDelivery("wsu", fence: MacFenceRequest(), environment: nil, botSecrets: nil, recorded: nil)
        XCTAssertEqual(fenced.botSecrets?.map(\.variable), ["CHAT_TOKEN"])
        XCTAssertTrue(fenced.fence?.hostPorts?.contains { $0.port == macSecret?.port } == true)
        let unfenced = try await c.adoptedMacDelivery("wsu", fence: nil, environment: nil, botSecrets: nil, recorded: nil)
        let file = try XCTUnwrap(unfenced.environment?["CHAT_TOKEN_FILE"])
        XCTAssertEqual(CredentialFingerprint.of(try String(contentsOfFile: file, encoding: .utf8)), macSecret?.fingerprint)
        let own = try await c.adoptedMacDelivery("wsu", fence: MacFenceRequest(), environment: ["CHAT_TOKEN_FILE": "/x"], botSecrets: nil, recorded: nil)
        XCTAssertNil(own.botSecrets, "its own token wins")
        let kept = try await c.adoptedMacDelivery("wsu", fence: MacFenceRequest(), environment: nil, botSecrets: nil,
                                                  recorded: [LaunchSecret(variable: "CHAT_TOKEN", host: "x.example", port: 1, fingerprint: "f")])
        XCTAssertNil(kept.botSecrets, "a secret of its own record wins")
        let notAdopted = try await c.adoptedMacDelivery("wsn", fence: MacFenceRequest(), environment: nil, botSecrets: nil, recorded: nil)
        XCTAssertNil(notAdopted.botSecrets, "--no-token: nothing at a restart either")
        try? FileManager.default.removeItem(atPath: (file as NSString).deletingLastPathComponent)
        // Revoking a place's launch secrets never deletes it (only release does).
        await c.forgetForTest(owner: "wsa", try XCTUnwrap(sandboxSecret))
        XCTAssertNotNil(keychain.get(AdoptedToken.service(store: store.root, workspace: "demo", agent: "wsa")))
        // A replaced token (doz chat token wsu) follows into its item and the fingerprint.
        await c.adoptedTokenReplaced("wsu", token: "replaced-token-0123456789")
        XCTAssertEqual(keychain.get(AdoptedToken.service(store: store.root, workspace: "demo", agent: "wsu")), "replaced-token-0123456789")
        XCTAssertEqual(try ws.read("demo")?.agents.first { $0.name == "wsu" }?.tokenFingerprint, CredentialFingerprint.of("replaced-token-0123456789"))
        // Release: the participant gone, the item deleted, nothing carried any more.
        w = WorkspaceRequest(name: "demo"); w.agent = "wsa"
        m = await ask(c, .workspaceRelease, w)
        XCTAssertNil(m.error, m.error?.message ?? "")
        XCTAssertFalse(try participants.directory().participants.contains { $0.name == "wsa" })
        XCTAssertNil(keychain.get(AdoptedToken.service(store: store.root, workspace: "demo", agent: "wsa")))
        let gone = await c.adoptedChatSecret(placeKey: "sandbox:wsa")
        XCTAssertNil(gone)
        let after = await c.sessionSecretsOf("wsa")
        XCTAssertTrue(after.isEmpty)
        w = WorkspaceRequest(name: "demo"); w.agent = "@mac/wsu"
        m = await ask(c, .workspaceRelease, w)
        XCTAssertNil(m.error, m.error?.message ?? "")
        let reopened = try await c.adoptedMacDelivery("wsu", fence: MacFenceRequest(), environment: nil, botSecrets: nil, recorded: nil)
        XCTAssertNil(reopened.botSecrets, "released: a restart carries no token")
        XCTAssertNil(reopened.environment?["CHAT_TOKEN_FILE"])
        XCTAssertEqual(bytes(store.configFile("wsa").path), docJSON, "…and its doz.json still never written")
    }

    func testAdoptAndReleaseASandboxAndASession() async throws {
        let c = await core()
        await sandbox(c, "wsa")
        try macSession("wsu")
        let docJSON = bytes(store.configFile("wsa").path)
        let sessionsJSON = bytes(store.root.appendingPathComponent("mac-sessions/sessions.json").path)
        var m = await new(c, "demo", noRoom: true)
        XCTAssertNil(m.error, m.error?.message ?? "")
        var d = try XCTUnwrap(m.result).decode(WorkspaceDetail.self)
        XCTAssertEqual(d.state, "setting-up")
        XCTAssertEqual(d.driver, "you")
        XCTAssertEqual(d.folders, [WorkspaceFolder(path: folder.path, mode: "rw", main: true)])

        m = await adopt(c, "demo", "wsa")
        XCTAssertNil(m.error, m.error?.message ?? "")
        m = await adopt(c, "demo", "@mac/wsu")
        XCTAssertNil(m.error, m.error?.message ?? "")
        d = try XCTUnwrap(m.result).decode(WorkspaceDetail.self)
        XCTAssertEqual(d.agents.map(\.place), ["wsa", "@mac/wsu"])
        XCTAssertEqual(d.agents.map(\.role), ["worker", "worker"])
        XCTAssertEqual(d.agents.map(\.state), ["off", "gone"])
        XCTAssertEqual(d.state, "setting-up", "neither runs: adopting them does not start the work")
        XCTAssertEqual(bytes(store.configFile("wsa").path), docJSON, "the sandbox's doz.json is never written")
        XCTAssertEqual(bytes(store.root.appendingPathComponent("mac-sessions/sessions.json").path), sessionsJSON, "sessions.json is never written")

        // The `workspace` field: doz ls --json, doz sessions @mac --json.
        let a1 = await c.handle(HostRequest(.ls))
        let ls = try XCTUnwrap(a1.result).decode([SandboxInfo].self)
        XCTAssertEqual(ls.first { $0.name == "wsa" }?.workspace, "demo")
        let a2 = await c.handle(HostRequest(.sessions, name: MacPlace.name))
        let macRows = try XCTUnwrap(a2.result).decode([SessionRow].self)
        XCTAssertEqual(macRows.first { $0.name == "wsu" }?.workspace, "demo")

        // Listed in the workspace, not loose.
        let a3 = await ask(c, .workspaceList, WorkspaceRequest())
        var listing = try XCTUnwrap(a3.result).decode(WorkspaceListing.self)
        XCTAssertEqual(listing.workspaces.map(\.name), ["demo"])
        XCTAssertEqual(listing.workspaces.first?.agents, 2)
        XCTAssertEqual(listing.loose, [])
        // Additive (--json only): who brought each in, and the places a sandbox's or session's page finds its workspace by.
        XCTAssertEqual(d.agents.map(\.startedBy), ["you", "you"])
        XCTAssertEqual(d.agents.map(\.session), [nil, nil], "a session on this Mac is its place; a sandbox's own agent names none")
        XCTAssertEqual(listing.workspaces.first?.places, ["wsa", "@mac/wsu"])

        var w = WorkspaceRequest(name: "demo")
        w.agent = "wsa"
        m = await ask(c, .workspaceRelease, w)
        XCTAssertNil(m.error, m.error?.message ?? "")
        let a4 = await ask(c, .workspaceList, WorkspaceRequest())
        listing = try XCTUnwrap(a4.result).decode(WorkspaceListing.self)
        XCTAssertEqual(listing.loose.map(\.name), ["wsa"])
        XCTAssertEqual(listing.loose.first?.kind, "sandbox")
        let a5 = await c.handle(HostRequest(.ls))
        let ls2 = try XCTUnwrap(a5.result).decode([SandboxInfo].self)
        XCTAssertNil(ls2.first { $0.name == "wsa" }?.workspace)
        let actions = try ws.log("demo").map(\.action)
        XCTAssertEqual(actions, ["created", "adopted", "adopted", "released"])
        XCTAssertNil(try ws.read("demo")?.flags.firstAgentAt, "only a running agent marks it started")
    }

    /// A worker sharing a sandbox names its session there; an ended worker's place is no longer the workspace's; a place shared
    /// by two agents is listed once; an agent elsewhere has none.
    func testTheDashboardFieldsSessionStartedByAndPlaces() async throws {
        let c = await core()
        await sandbox(c, "wsa")
        let m = await new(c, "demo", noRoom: true, adopt: ["wsa"])
        XCTAssertNil(m.error, m.error?.message ?? "")
        var rec = try XCTUnwrap(try ws.read("demo"))
        let t = Date()
        var shared = WorkspaceAgent(name: "bot1", place: AgentPlace(sandbox: "wsa", session: "bot1"), startedBy: "doz", startedAt: t)
        shared.task = "list the files"
        var ended = WorkspaceAgent(name: "bot2", place: .macSession("demo-bot2"), startedAt: t)
        ended.task = "gone now"
        ended.endedAt = t
        rec.agents += [shared, ended, WorkspaceAgent(name: "far", place: AgentPlace(elsewhere: "another Mac"), startedAt: t)]
        try ws.write(rec)
        let s = await ask(c, .workspaceShow, WorkspaceRequest(name: "demo"))
        let d = try XCTUnwrap(s.result).decode(WorkspaceDetail.self)
        XCTAssertEqual(d.agents.map(\.name), ["wsa", "bot1", "far"], "an ended worker is left out")
        XCTAssertEqual(d.agents.map(\.session), [nil, "bot1", nil])
        XCTAssertEqual(d.agents.map(\.startedBy), ["you", "doz", "you"])
        let l = await ask(c, .workspaceList, WorkspaceRequest())
        let row = try XCTUnwrap(try XCTUnwrap(l.result).decode(WorkspaceListing.self).workspaces.first)
        XCTAssertEqual(row.places, ["wsa"], "once each; not the ended worker's session, nothing for elsewhere")
    }

    /// A FAKE holder of a session on this Mac: it answers QUERY with an INFO line, so the session runs (no deckhold, no
    /// program). Its socket is in the scratch store's own socket folder.
    final class FakeHolder: @unchecked Sendable {
        let lfd: Int32
        let path: String
        init(_ path: String) {
            self.path = path
            unlink(path)
            lfd = socket(AF_UNIX, SOCK_STREAM, 0)
            var a = sockaddr_un()
            a.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &a.sun_path) { r in r.copyBytes(from: Array(path.utf8)); r[path.utf8.count] = 0 }
            _ = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(lfd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            listen(lfd, 8)
            let l = lfd
            let name = (path as NSString).lastPathComponent.replacingOccurrences(of: ".sock", with: "")
            Thread.detachNewThread {
                while true {
                    let c = accept(l, nil, nil)
                    if c < 0 { return }
                    Thread.detachNewThread {
                        var buf = [UInt8](repeating: 0, count: 4096)
                        _ = read(c, &buf, buf.count)
                        let f = DeckholdFrame.info("\(name)\tpid=42\tsize=80x24\tclients=0\tscreen=primary\thistory=0\tbytes=5\tgrid=1\tsleep").encoded
                        f.withUnsafeBytes { _ = write(c, $0.baseAddress, $0.count) }
                        close(c)
                    }
                }
            }
        }
        func stop() { Darwin.shutdown(lfd, SHUT_RDWR); Darwin.close(lfd); unlink(path) }
    }

    /// A manager launcher that says which places run (nothing is ever launched).
    final class RunningLauncher: ManagerLauncher, @unchecked Sendable {
        let running: Set<String>
        init(_ running: Set<String>) { self.running = running }
        func info(isolation: ManagerIsolation, place: String) async -> ManagerPlaceInfo {
            ManagerPlaceInfo(exists: running.contains(place), running: running.contains(place))
        }
        func launch(_ o: ManagerLaunchOrder) async throws -> [String] { throw HostError(.failed, "never launched here") }
        func stop(isolation: ManagerIsolation, place: String) async throws {}
    }

    final class CountingChat: WorkspaceChat, @unchecked Sendable {
        let lock = NSLock()
        var roomSet: Set<String> = []
        var posts = 0
        func readiness() async -> WorkspaceChatReadiness { .ready }
        func rooms() throws -> Set<String> { lock.withLock { roomSet } }
        func makeRoom(_ name: String) throws { lock.withLock { _ = roomSet.insert(name) } }
        func post(room: String, content: String) throws { lock.withLock { posts += 1 } }
        func invite(room: String, name: String) throws -> Bool { false }
    }

    /// Filing a RUNNING agent marks the workspace started — `firstAgentAt` set, out of setting up — with nothing posted and
    /// nothing started; one that does not run leaves it setting up; `new` with a running agent is started at once.
    func testAdoptingARunningAgentMarksTheWorkspaceStartedWithNothingPosted() async throws {
        let chat = CountingChat()
        let c = await core(chat: chat)
        try macSession("wsu")
        try macSession("wsv")
        await sandbox(c, "wsa")
        try MacPlace.ensureFolder(c.mac.directory)
        let holder = FakeHolder(c.mac.socket("wsu"))
        let holder2 = FakeHolder(c.mac.socket("wsv"))
        defer { holder.stop(); holder2.stop(); try? FileManager.default.removeItem(atPath: c.mac.directory) }
        let isRunning = await c.mac.isRunning("wsu")
        XCTAssertTrue(isRunning, "the fake holder answers")

        var m = await new(c, "demo")
        XCTAssertNil(m.error, m.error?.message ?? "")
        XCTAssertEqual(chat.roomSet, ["demo"], "its room made, nothing posted")
        m = await adopt(c, "demo", "wsa")
        var d = try XCTUnwrap(m.result).decode(WorkspaceDetail.self)
        XCTAssertEqual(d.state, "setting-up", "an off sandbox leaves it setting up")
        XCTAssertNil(d.flags.firstAgentAt)
        m = await adopt(c, "demo", "@mac/wsu")
        XCTAssertNil(m.error, m.error?.message ?? "")
        d = try XCTUnwrap(m.result).decode(WorkspaceDetail.self)
        XCTAssertNotEqual(d.state, "setting-up", "a running agent marks it started")
        XCTAssertNotNil(d.flags.firstAgentAt)
        XCTAssertNil(d.flags.startedAt, "no kick-off: the brief is not posted")
        XCTAssertEqual(d.agents.first { $0.name == "wsu" }?.state, "running")
        XCTAssertEqual(chat.posts, 0, "nothing posted")
        XCTAssertEqual(try ws.log("demo").map(\.action), ["created", "room-made", "adopted", "adopted"])

        m = await new(c, "fresh", adopt: ["@mac/wsv"])
        XCTAssertNil(m.error, m.error?.message ?? "")
        d = try XCTUnwrap(m.result).decode(WorkspaceDetail.self)
        XCTAssertNotEqual(d.state, "setting-up", "new with a running agent is started")
        XCTAssertNotNil(d.flags.firstAgentAt)
        XCTAssertEqual(chat.posts, 0)

        // Releasing it keeps the mark (the rule governs the start only); the agent is loose and runs on.
        var w = WorkspaceRequest(name: "demo")
        w.agent = "wsu"
        m = await ask(c, .workspaceRelease, w)
        XCTAssertNil(m.error, m.error?.message ?? "")
        XCTAssertNotNil(try ws.read("demo")?.flags.firstAgentAt)
        let answer = await ask(c, .workspaceList, WorkspaceRequest())
        let l = try XCTUnwrap(answer.result).decode(WorkspaceListing.self)
        XCTAssertEqual(l.loose.first { $0.name == "@mac/wsu" }?.state, "running")
    }

    /// Release refuses a live worker and a running manager, naming the command, and writes nothing.
    func testReleaseRefusesALiveWorkerAndARunningManager() async throws {
        let c = await core()
        await sandbox(c, "wsa")
        let m = await new(c, "demo", noRoom: true)
        XCTAssertNil(m.error, m.error?.message ?? "")
        var rec = try XCTUnwrap(try ws.read("demo"))
        var worker = WorkspaceAgent(name: "bot1", place: AgentPlace(sandbox: "wsa", session: "bot1"), startedBy: "doz", startedAt: Date())
        worker.task = "list the files"
        rec.agents.append(worker)
        rec.agents.append(WorkspaceAgent(name: "mira", role: "manager", place: .macSession("demo"), startedAt: Date(), bot: "mira", isolation: "fenced"))
        try ws.write(rec)
        await c.setManagerLauncher(RunningLauncher(["demo"]))
        let before = (recordBytes("demo"), bytes(ws.folder("demo") + "/log.jsonl"))
        var w = WorkspaceRequest(name: "demo")
        w.agent = "bot1"
        var r = await ask(c, .workspaceRelease, w)
        XCTAssertEqual(r.error?.code, .invalidPhase)
        XCTAssertEqual(r.error?.message, "bot1 is a worker of demo — doz worker end demo bot1")
        w.agent = "mira"
        r = await ask(c, .workspaceRelease, w)
        XCTAssertEqual(r.error?.code, .invalidPhase)
        XCTAssertEqual(r.error?.message, "mira manages demo and is running — stop it first: doz workspace stop demo")
        XCTAssertTrue(recordBytes("demo") == before.0 && bytes(ws.folder("demo") + "/log.jsonl") == before.1, "nothing written")
    }

    /// In one workspace only; missing targets; bare @mac; a name clash — each refused with nothing written.
    func testRefusalsWriteNothing() async throws {
        let c = await core()
        await sandbox(c, "wsa")
        let a6 = await new(c, "demo", noRoom: true, adopt: ["wsa"])
        XCTAssertNil(a6.error)
        let a7 = await new(c, "other", noRoom: true)
        XCTAssertNil(a7.error)
        let before = (recordBytes("demo"), recordBytes("other"), bytes(ws.folder("other") + "/log.jsonl"))
        var m = await adopt(c, "other", "wsa")
        XCTAssertEqual(m.error?.code, .exists)
        XCTAssertEqual(m.error?.message, "wsa is already in demo — doz workspace release demo wsa first.")
        m = await adopt(c, "other", "nosuch")
        XCTAssertEqual(m.error?.code, .notFound)
        m = await adopt(c, "other", "@mac")
        XCTAssertEqual(m.error?.message, "name the session: @mac/SESSION")
        m = await adopt(c, "other", "@mac/nosuch")
        XCTAssertEqual(m.error?.code, .notFound)
        m = await adopt(c, "nosuch", "wsa")
        XCTAssertEqual(m.error?.code, .notFound)
        await sandbox(c, "wsb")
        m = await adopt(c, "demo", "wsb", as: "wsa")
        XCTAssertEqual(m.error?.code, .exists, "an agent name in use")
        XCTAssertTrue(m.error?.message.contains("--as NAME") == true)
        m = await new(c, "third", noRoom: true, adopt: ["wsa"])
        XCTAssertEqual(m.error?.code, .exists)
        XCTAssertFalse(ws.exists("third"), "a refused new makes nothing")
        XCTAssertTrue(recordBytes("demo") == before.0 && recordBytes("other") == before.1 && bytes(ws.folder("other") + "/log.jsonl") == before.2,
                      "every refusal left the records and logs as they were")
        // --as gives another name.
        m = await adopt(c, "demo", "wsb", as: "second")
        XCTAssertNil(m.error, m.error?.message ?? "")
        XCTAssertEqual(try ws.read("demo")?.agents.map(\.name), ["wsa", "second"])
    }

    /// doz rename moves the agent's place (and its name when it had the sandbox's); doz rm lets it go — both logged as doz.
    func testTheRenameAndRmHooks() async throws {
        let c = await core()
        await sandbox(c, "wsa")
        let a8 = await new(c, "demo", noRoom: true, adopt: ["wsa"])
        XCTAssertNil(a8.error)
        var r = HostRequest(.rename, name: "wsa")
        r.newName = "wsz"
        var m = await c.handle(r)
        XCTAssertNil(m.error, m.error?.message ?? "")
        var rec = try XCTUnwrap(try ws.read("demo"))
        XCTAssertEqual(rec.agents.first?.place, .sandbox("wsz"))
        XCTAssertEqual(rec.agents.first?.name, "wsz")
        XCTAssertEqual(ws.membership(), ["sandbox:wsz": "demo"])
        m = await c.handle(HostRequest(.rm, name: "wsz"))
        XCTAssertNil(m.error, m.error?.message ?? "")
        rec = try XCTUnwrap(try ws.read("demo"))
        XCTAssertEqual(rec.agents, [])
        let log = try ws.log("demo")
        XCTAssertEqual(log.suffix(2).map(\.action), ["agent-renamed", "agent-removed"])
        XCTAssertEqual(log.suffix(2).map(\.by), ["doz", "doz"])
        let a9 = await ask(c, .workspaceShow, WorkspaceRequest(name: "demo"))
        let d = try XCTUnwrap(a9.result).decode(WorkspaceDetail.self)
        XCTAssertEqual(d.state, "setting-up", "empty, and its only agent never ran here: still setting up")
    }

    // MARK: rooms

    func testTheRoomCases() async throws {
        let chat = FakeChat()
        let c = await core(chat: chat)
        // Chat on, no --room: the room is made, named for the workspace; nothing is posted.
        var m = await new(c, "demo")
        XCTAssertNil(m.error, m.error?.message ?? "")
        XCTAssertEqual(chat.made, ["demo"])
        XCTAssertEqual(try ws.read("demo")?.rooms, [WorkspaceRoom(label: "main", chatRoom: "demo", main: true, owned: true)])
        XCTAssertEqual(try ws.log("demo").map(\.action), ["created", "room-made"])
        // The room exists already: refused, nothing written.
        chat.roomSet.insert("taken")
        m = await new(c, "taken")
        XCTAssertEqual(m.error?.code, .exists)
        XCTAssertTrue(m.error?.message.contains("--room taken") == true, m.error?.message ?? "")
        XCTAssertFalse(ws.exists("taken"))
        // --room EXISTING: linked, not made.
        m = await new(c, "taken", room: "taken")
        XCTAssertNil(m.error, m.error?.message ?? "")
        XCTAssertEqual(chat.made, ["demo"])
        XCTAssertEqual(try ws.log("taken").map(\.action), ["created", "room-linked"])
        // --room of another workspace, or one that is not there: refused.
        let a10 = await new(c, "again", room: "demo")
        XCTAssertEqual(a10.error?.code, .exists)
        let a11 = await new(c, "again", room: "nosuch")
        XCTAssertEqual(a11.error?.code, .notFound)
        let a12 = await new(c, "again", room: "demo", noRoom: true)
        XCTAssertEqual(a12.error?.code, .invalid)
        // --no-room: none.
        m = await new(c, "quiet", noRoom: true)
        XCTAssertNil(m.error)
        XCTAssertEqual(try ws.read("quiet")?.rooms, [])
        // Chat on, not ready: refused, nothing written.
        chat.state = .notReady("starting")
        m = await new(c, "late")
        XCTAssertEqual(m.error?.code, .unavailable)
        XCTAssertFalse(ws.exists("late"))
        // Chat off: no room, and the note says how to make one later.
        chat.state = .off
        m = await new(c, "off")
        XCTAssertNil(m.error, m.error?.message ?? "")
        let d = try XCTUnwrap(m.result).decode(WorkspaceDetail.self)
        XCTAssertEqual(d.rooms, [])
        XCTAssertTrue(d.notes?.contains { $0.contains("doz workspace edit off --make-room") } == true)
        let a13 = await new(c, "off2", room: "general")
        XCTAssertEqual(a13.error?.code, .unavailable)
        // edit --make-room once it is on.
        chat.state = .ready
        var w = WorkspaceRequest(name: "off")
        w.makeRoom = true
        m = await ask(c, .workspaceEdit, w)
        XCTAssertNil(m.error, m.error?.message ?? "")
        XCTAssertEqual(try ws.read("off")?.mainRoom?.chatRoom, "off")
        let a14 = await ask(c, .workspaceEdit, w)
        XCTAssertEqual(a14.error?.code, .exists, "it has its room")
        // rename keeps the room's name, and says so.
        w = WorkspaceRequest(name: "demo")
        w.newName = "demo2"
        m = await ask(c, .workspaceRename, w)
        XCTAssertNil(m.error, m.error?.message ?? "")
        let r = try XCTUnwrap(m.result).decode(WorkspaceDetail.self)
        XCTAssertEqual(r.rooms.first?.chatRoom, "demo")
        XCTAssertTrue(r.notes?.first?.contains("keeps its name") == true)
    }

    // MARK: folders, edit, the read-only core

    /// Folders are optional; --from-project needs a main folder; an unknown field survives an edit.
    func testNoFoldersAndEdits() async throws {
        let c = await core()
        var m = await new(c, "bare", folders: [], noRoom: true)
        XCTAssertNil(m.error, m.error?.message ?? "")
        XCTAssertEqual(try XCTUnwrap(m.result).decode(WorkspaceDetail.self).folders, [])
        m = await new(c, "proj", folders: [], noRoom: true, project: folder.path + "/doz_project.yaml")
        XCTAssertEqual(m.error?.code, .invalid)
        XCTAssertTrue(m.error?.message.contains("--from-project") == true)
        let a15 = await new(c, "gone", folders: ["/nonexistent-doz-folder"], noRoom: true)
        XCTAssertEqual(a15.error?.code, .notFound)
        // An unknown field kept across an edit.
        let path = ws.folder("bare") + "/workspace.json"
        var obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any])
        obj["later"] = "kept"
        try JSONSerialization.data(withJSONObject: obj).write(to: URL(fileURLWithPath: path))
        var w = WorkspaceRequest(name: "bare")
        w.brief = "A new brief.\n"
        w.addFolders = [WorkspaceFolder(path: folder.path, mode: "ro")]
        m = await ask(c, .workspaceEdit, w)
        XCTAssertNil(m.error, m.error?.message ?? "")
        let again = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any])
        XCTAssertEqual(again["later"] as? String, "kept")
        let rec = try XCTUnwrap(try ws.read("bare"))
        XCTAssertEqual(rec.folders, [WorkspaceFolder(path: folder.path, mode: "ro", main: true)])
        XCTAssertEqual(ws.readBrief("bare"), "A new brief.\n")
        XCTAssertEqual(rec.brief.bytes, 13)
        let log = try ws.log("bare")
        XCTAssertEqual(log.map(\.action), ["created", "brief-edited", "folders-edited"])
        let text = try String(contentsOfFile: ws.folder("bare") + "/log.jsonl", encoding: .utf8)
        XCTAssertFalse(text.contains("A new brief") || text.contains(folder.path), "never the brief's text or a folder's path in the log")
        let a16 = await ask(c, .workspaceEdit, WorkspaceRequest(name: "bare"))
        XCTAssertEqual(a16.error?.code, .invalid, "nothing to change")
        var big = WorkspaceRequest(name: "bare")
        big.brief = String(repeating: "x", count: (256 << 10) + 1)
        let a17 = await ask(c, .workspaceEdit, big)
        XCTAssertEqual(a17.error?.code, .invalid)
        var bad = WorkspaceRequest(name: "Bad_Name")
        bad.brief = "x"
        let a18 = await ask(c, .workspaceNew, bad)
        XCTAssertEqual(a18.error?.code, .invalid)
    }

    /// Looking is answered in-process; changing needs the daemon.
    func testTheReadOnlyCore() async throws {
        let c = await core()
        await sandbox(c, "wsa")
        let a19 = await new(c, "demo", noRoom: true)
        XCTAssertNil(a19.error)
        let ro = await core(readOnly: true)
        let list = await ask(ro, .workspaceList, WorkspaceRequest())
        XCTAssertNil(list.error, list.error?.message ?? "")
        XCTAssertEqual(try XCTUnwrap(list.result).decode(WorkspaceListing.self).loose.map(\.name), ["wsa"])
        let a20 = await ask(ro, .workspaceShow, WorkspaceRequest(name: "demo"))
        XCTAssertNil(a20.error)
        let a21 = await ask(ro, .workspaceLog, WorkspaceRequest(name: "demo"))
        XCTAssertNil(a21.error)
        let before = recordBytes("demo")
        for op in [HostOp.workspaceNew, .workspaceAdopt, .workspaceRelease, .workspaceEdit, .workspaceRename] {
            var w = WorkspaceRequest(name: "demo")
            w.agent = "wsa"
            w.newName = "x"
            w.brief = "b"
            let m = await ask(ro, op, w)
            XCTAssertEqual(m.error?.code, .unavailable, op.rawValue)
            XCTAssertTrue(m.error?.message.contains("needs the daemon") == true, op.rawValue)
        }
        XCTAssertEqual(recordBytes("demo"), before)
    }
}
