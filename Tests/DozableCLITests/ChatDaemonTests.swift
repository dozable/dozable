import Darwin
import DozableChat
import Foundation
import XCTest
@testable import DozableHost

/// The chat server under the daemon: the generated files (a golden config, loopback only, hashes only, modes, names),
/// the restart policy, and the supervisor against a FAKE process table — never started while chat is off, stopped before
/// the daemon lets go, never started after a program change, an orphan of ours stopped and anyone else's refused.
final class ChatDirectoryTests: XCTestCase {
    var root: String!
    var paths: ChatPaths { ChatPaths(folder: root + "/chat") }

    override func setUpWithError() throws {
        root = "/tmp/dzc-dir-\(getpid())-\(UUID().uuidString.prefix(6))"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(atPath: root) }

    func testTheGoldenConfig() throws {
        let d = ChatDirectory(human: "ada", participants: [.init(name: "bot1", added: "2026-01-01T00:00:00Z")])
        let text = String(decoding: try ChatConfigFile.bytes(d, paths: paths, pagePort: 8790, linePort: 8791), as: UTF8.self)
        XCTAssertEqual(text, """
            {
             "line_port": 8791,
             "http_port": 8790,
             "data_dir": "\(root!)/chat/data",
             "default_room": "general",
             "participants": [
              {
               "name": "ada",
               "kind": "human",
               "deliver": "web"
              },
              {
               "name": "bot1",
               "kind": "agent"
              }
             ],
             "rooms": {
              "general": [
               "ada"
              ]
             },
             "allow": [
              "127.0.0.1",
              "::1"
             ],
             "require_tokens": true,
             "agent_addresses": [
              "127.0.0.0/8",
              "::1"
             ],
             "secrets_file_only": true,
             "bind": "127.0.0.1"
            }

            """)
        let c = try ChatConfig.parse(Data(text.utf8))
        XCTAssertEqual(c.bind, "127.0.0.1")
        // No TCP caller is ever the human: the page port serves loopback /agent/ only, the line port wants a token.
        XCTAssertEqual(c.access.page(remote: "127.0.0.1", agentPath: false), ChatAccess.agentOnly)
        XCTAssertEqual(c.access.page(remote: "::1", agentPath: false), ChatAccess.agentOnly)
        XCTAssertNil(c.access.page(remote: "127.0.0.1", agentPath: true))
        XCTAssertEqual(c.access.line(remote: "127.0.0.1"), true)
        XCTAssertNil(c.access.line(remote: "192.168.1.5"), "a LAN address is closed at once")
        XCTAssertFalse(c.participants.contains { $0.deliver == "inbox-socket" })
    }

    /// Asks in the generated config: a store with no roles and the default settings gets the bytes it got before asks
    /// (the golden config above); a decider's entry carries `roles`, and each asks setting appears only when it is not the
    /// server's default — `no_asks` only when `chat.asks` is off. The server's own loader reads each back.
    func testRolesAndTheAsksSettingsInTheGeneratedConfig() throws {
        var d = ChatDirectory(human: "ada", participants: [.init(name: "bot1", added: "x"), .init(name: "bot2", added: "x", roles: ["decider"])])
        let base = try ChatConfigFile.bytes(d, paths: paths, pagePort: 8790, linePort: 8791)
        XCTAssertEqual(base, try ChatConfigFile.bytes(d, paths: paths, pagePort: 8790, linePort: 8791, asks: ChatAskSettings()))
        let text = String(decoding: base, as: UTF8.self)
        XCTAssertFalse(text.contains("no_asks") || text.contains("ask_"), "defaults are never written")
        let c = try ChatConfig.parse(Data(base))
        XCTAssertEqual(c.participants.first { $0.name == "bot2" }?.roles, ["decider"])
        XCTAssertEqual(c.participants.first { $0.name == "bot1" }?.roles, [])
        XCTAssertTrue(c.asksOn)
        let off = try ChatConfig.parse(Data(try ChatConfigFile.bytes(d, paths: paths, pagePort: 8790, linePort: 8791,
                                                                    asks: ChatAskSettings(enabled: false, maxOpen: 2, expirySeconds: 60, cooldownSeconds: -1))))
        XCTAssertFalse(off.asksOn)
        XCTAssertEqual([off.askMaxOpen, off.askExpirySeconds, off.askCooldownSeconds], [2, 60, -1])
        d.participants[1].roles = nil
        XCTAssertFalse(String(decoding: try ChatConfigFile.bytes(d, paths: paths, pagePort: 8790, linePort: 8791), as: UTF8.self).contains("roles"))
    }

    func testNoHumanNoConfig() {
        XCTAssertThrowsError(try ChatConfigFile.bytes(ChatDirectory(), paths: paths, pagePort: 8790, linePort: 8791))
    }

    func testPortClashes() {
        XCTAssertNotNil(ChatConfigFile.portClash(pagePort: 9000, linePort: 9000, dashboards: []))
        XCTAssertTrue(ChatConfigFile.portClash(pagePort: 7443, linePort: 8791, dashboards: [("serve.port", 7443)])!.contains("chat.page_port"))
        XCTAssertTrue(ChatConfigFile.portClash(pagePort: 8790, linePort: 7443, dashboards: [("serve.port", 7443)])!.contains("chat.line_port"))
        XCTAssertNil(ChatConfigFile.portClash(pagePort: 8790, linePort: 8791, dashboards: [("ui.port", 0), ("serve.port", 7443)]))
    }

    func testNamesAndTokens() {
        XCTAssertNil(ChatNames.refusal("bot1"))
        XCTAssertNil(ChatNames.refusal("ada"))
        XCTAssertNotNil(ChatNames.refusal("chat"), "the server's own name")
        for bad in ["Bot1", "1bot", "", "bot_1", "bot 1", String(repeating: "a", count: 41)] { XCTAssertNotNil(ChatNames.refusal(bad), bad) }
        XCTAssertEqual(ChatNames.defaultHuman("Ada.Lovelace"), "ada-lovelace")
        XCTAssertEqual(ChatNames.defaultHuman("1984"), "me")
        XCTAssertEqual(ChatNames.defaultHuman("chat"), "me")
        let t = ChatTokens.make()
        XCTAssertTrue(t.hasPrefix("dzc_"))
        XCTAssertEqual(t.count, 47)
        XCTAssertNotEqual(t, ChatTokens.make())
        XCTAssertNil(ChatTokens.refusal(t))
        XCTAssertNotNil(ChatTokens.refusal("short"))
        XCTAssertNotNil(ChatTokens.refusal("a token with spaces in it"))
        XCTAssertNotNil(ChatTokens.refusal(String(repeating: "x", count: 257)))
    }

    func testFilesAreTheUsersAloneAndHoldHashesOnly() throws {
        try paths.ensureFolder()
        var st = stat()
        XCTAssertEqual(lstat(paths.folder, &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o700)
        let token = ChatTokens.make()
        let h = ChatTokenHashes(sha256: ["bot1": ChatSecrets.hash(token)])
        try paths.write("tokens.json", h.bytes())
        XCTAssertEqual(lstat(paths.tokens, &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o600)
        let text = try String(contentsOfFile: paths.tokens, encoding: .utf8)
        XCTAssertFalse(text.contains(token))
        XCTAssertEqual(try ChatTokenHashes.load(paths), h)
        // The server reads exactly that file.
        XCTAssertEqual(try ChatSecrets.loadHashes(path: paths.tokens).whoHas(token, among: ["bot1"]), "bot1")
        // A folder open to others is closed again; a link is refused.
        chmod(paths.folder, 0o755)
        try paths.ensureFolder()
        XCTAssertEqual(lstat(paths.folder, &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o700)
        let link = ChatPaths(folder: root + "/linked")
        symlink(paths.folder, link.folder)
        XCTAssertThrowsError(try link.ensureFolder())
    }
}

final class ChatRestartPolicyTests: XCTestCase {
    func testSeventyEightIsNeverRetried() {
        var p = ChatRestartPolicy()
        XCTAssertEqual(p.exited(code: 78, upSeconds: 1, now: 0), .stopped)
        XCTAssertEqual(p.consecutive, 0)
    }

    func testTheBackoffThenFailing() {
        var p = ChatRestartPolicy()
        XCTAssertEqual(p.exited(code: 1, upSeconds: 0, now: 0), .retry(after: 1))
        XCTAssertEqual(p.exited(code: nil, upSeconds: 0, now: 1), .retry(after: 2))
        XCTAssertEqual(p.exited(code: 1, upSeconds: 0, now: 3), .retry(after: 4))
        XCTAssertEqual(p.exited(code: 1, upSeconds: 0, now: 7), .retry(after: 8))
        XCTAssertEqual(p.exited(code: 1, upSeconds: 0, now: 15), .failing, "5 failures within 10 minutes")
    }

    func testTheBackoffCapsAtAMinuteAndResetsAfterTenMinutesUp() {
        var p = ChatRestartPolicy()
        var now = 0.0
        var last = ChatRestartPolicy.Next.stopped
        for _ in 0..<8 { now += 200; last = p.exited(code: 1, upSeconds: 0, now: now) }   // spread out: never 5 in 10 minutes
        XCTAssertEqual(last, .retry(after: 60))
        XCTAssertEqual(p.exited(code: 1, upSeconds: 600, now: now + 1000), .retry(after: 1), "10 minutes up starts the count again")
        p.reset()
        XCTAssertEqual(p.consecutive, 0)
        XCTAssertTrue(p.recent.isEmpty)
    }
}

/// A fake process table: nothing is ever started.
final class FakeChatProcesses: ChatProcesses, @unchecked Sendable {
    let lock = NSLock()
    var spawned: [[String]] = []
    /// What each start was handed on descriptor 3 (nil: nothing).
    var inputs: [Data?] = []
    var environments: [[String: String]] = []
    var signals: [(pid_t, Int32)] = []
    var running: Set<pid_t> = []
    var exits: [pid_t: ChatChildExit] = [:]
    var lockHolder: Int32?
    var holderArguments: [String]?
    var ready = true
    var nextPid: pid_t = 70_000

    func spawn(executable: String, arguments: [String], environment: [String: String], log: String, input: Data?) throws -> pid_t {
        lock.withLock { spawned.append(arguments); inputs.append(input); environments.append(environment); nextPid += 1; running.insert(nextPid); lockHolder = nextPid; return nextPid }
    }
    func reap(_ pid: pid_t) -> ChatChildExit? {
        lock.withLock {
            guard let e = exits.removeValue(forKey: pid) else { return nil }
            running.remove(pid)
            if lockHolder == pid { lockHolder = nil }
            return e
        }
    }
    func signal(_ pid: pid_t, _ sig: Int32) {
        lock.withLock {
            signals.append((pid, sig))
            if running.contains(pid) { exits[pid] = ChatChildExit(signal: sig) }
            if lockHolder == pid && !running.contains(pid) { lockHolder = nil }
        }
    }
    func server(dataDir: String) -> (pid: Int32?, ready: Bool) { lock.withLock { (lockHolder, ready) } }
    func arguments(of pid: pid_t) -> [String]? { lock.withLock { holderArguments } }
    /// Ports another program holds (none by default); the system's free port when asked.
    var taken: Set<Int> = []
    var osPort: Int? = 41_234
    func portInUse(_ port: Int) -> Bool { lock.withLock { taken.contains(port) } }
    func freePort() -> Int? { lock.withLock { osPort } }
    /// The child dies by itself.
    func die(_ pid: pid_t, _ e: ChatChildExit) { lock.withLock { exits[pid] = e } }
    var spawnCount: Int { lock.withLock { spawned.count } }
    var terms: [pid_t] { lock.withLock { signals.filter { $0.1 == SIGTERM }.map(\.0) } }
}

final class SettingsBox: @unchecked Sendable {
    let lock = NSLock()
    var view = ChatSettingsView(enabled: false, pagePort: 8790, linePort: 8791)
    func set(_ on: Bool) { lock.withLock { view.enabled = on } }
    func get() -> ChatSettingsView { lock.withLock { view } }
}

final class ChatSupervisorTests: XCTestCase {
    var root: String!
    var fake: FakeChatProcesses!
    var box: SettingsBox!
    var sup: ChatSupervisor!

    override func setUpWithError() throws {
        root = "/tmp/dzc-sup-\(getpid())-\(UUID().uuidString.prefix(6))"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        fake = FakeChatProcesses()
        box = SettingsBox()
        let b = box!
        sup = ChatSupervisor(paths: ChatPaths(folder: root + "/chat"), executable: "/usr/bin/false", release: "0.0.0", processes: fake,
                             environment: [:], readSettings: { b.get() })
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(atPath: root) }

    func testNeverStartedWhileChatIsOff() async {
        for _ in 0..<3 { await sup.tick(blocked: false) }
        XCTAssertEqual(fake.spawnCount, 0)
        let st = await sup.status()
        XCTAssertEqual(st.state, "off")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/chat"), "chat off makes no folder")
    }

    func testOnStartsOneThenOffStopsIt() async throws {
        box.set(true)
        _ = try await sup.sync(human: "ada", retry: true, waitReady: false, blocked: false)
        XCTAssertEqual(fake.spawnCount, 1)
        let args = fake.spawned[0]
        XCTAssertEqual(Array(args.prefix(2)), ["chat", "serve"])
        XCTAssertTrue(args.contains("--supervised") && args.contains("--token-hashes") && args.contains("--owner-socket"))
        XCTAssertEqual(args[args.firstIndex(of: "--bind")! + 1], "127.0.0.1")
        await sup.tick(blocked: false)
        var st = await sup.status()
        XCTAssertEqual(st.state, "running")
        XCTAssertTrue(st.ready)
        box.set(false)
        _ = try await sup.sync(human: nil, retry: false, waitReady: false, blocked: false)
        st = await sup.status()
        XCTAssertEqual(st.state, "off")
        XCTAssertNil(st.pid)
        XCTAssertEqual(fake.terms.count, 1, "SIGTERM first")
        await sup.tick(blocked: false)
        XCTAssertEqual(fake.spawnCount, 1, "nothing started again while off")
    }

    func testStoppedBeforeTheDaemonLetsGoAndNeverAgain() async throws {
        box.set(true)
        _ = try await sup.sync(human: "ada", retry: true, waitReady: false, blocked: false)
        await sup.stopForExit()
        XCTAssertEqual(fake.terms.count, 1)
        let pidNow = await sup.status().pid
        XCTAssertNil(pidNow)
        for _ in 0..<3 { await sup.tick(blocked: false) }
        XCTAssertEqual(fake.spawnCount, 1, "an exiting daemon starts no chat server")
    }

    func testNoStartAfterAProgramChange() async throws {
        box.set(true)
        _ = try await sup.sync(human: "ada", retry: false, waitReady: false, blocked: true)
        XCTAssertEqual(fake.spawnCount, 0)
        let waiting = await sup.status().state
        XCTAssertEqual(waiting, "waiting")
        await sup.tick(blocked: false)
        XCTAssertEqual(fake.spawnCount, 1)
        await sup.tick(blocked: true)
        XCTAssertEqual(fake.terms.count, 1, "a running one is stopped when the program changes")
        XCTAssertEqual(fake.spawnCount, 1)
    }

    func testAKilledChildIsRestartedAndCounted() async throws {
        box.set(true)
        _ = try await sup.sync(human: "ada", retry: true, waitReady: false, blocked: false)
        let pid = fake.spawned.isEmpty ? 0 : fake.nextPid
        fake.die(pid, ChatChildExit(signal: SIGKILL))
        await sup.tick(blocked: false)
        var st = await sup.status()
        XCTAssertEqual(st.state, "restarting")
        XCTAssertEqual(st.restarts, 1)
        XCTAssertEqual(st.lastExit, "signal 9")
        try await Task.sleep(for: .milliseconds(1100))
        await sup.tick(blocked: false)
        XCTAssertEqual(fake.spawnCount, 2)
        st = await sup.status()
        XCTAssertEqual(st.restarts, 1)
    }

    func testExit78StaysStoppedUntilTheFilesChange() async throws {
        box.set(true)
        _ = try await sup.sync(human: "ada", retry: true, waitReady: false, blocked: false)
        fake.die(fake.nextPid, ChatChildExit(code: 78))
        for _ in 0..<3 { await sup.tick(blocked: false) }
        let stopped = await sup.status().state
        XCTAssertEqual(stopped, "stopped")
        XCTAssertEqual(fake.spawnCount, 1, "78 is never retried by itself")
        _ = try await sup.add("bot1", token: nil)
        XCTAssertEqual(fake.spawnCount, 2, "new files are tried")
    }

    func testAnOrphanOfOursIsStoppedAndAnyoneElsesRefused() async throws {
        box.set(true)
        fake.lockHolder = 999_999
        fake.holderArguments = ["chat", "serve", "--config", root + "/chat/config.json", "--supervised"]
        _ = try await sup.sync(human: "ada", retry: true, waitReady: false, blocked: false)
        XCTAssertTrue(fake.terms.contains(999_999), "our earlier server is stopped")
        XCTAssertEqual(fake.spawnCount, 1)

        let f2 = FakeChatProcesses()
        f2.lockHolder = 999_998
        f2.holderArguments = ["chat", "serve", "--config", "/elsewhere/config.json"]
        let b = box!
        let s2 = ChatSupervisor(paths: ChatPaths(folder: root + "/chat"), executable: "/usr/bin/false", release: "0.0.0", processes: f2,
                                environment: [:], readSettings: { b.get() })
        await s2.tick(blocked: false)
        let st = await s2.status()
        XCTAssertEqual(st.state, "stopped")
        XCTAssertTrue(st.problem?.contains("another chat server holds") == true)
        XCTAssertEqual(f2.spawnCount, 0, "two servers never share a data folder")
        XCTAssertTrue(f2.terms.isEmpty, "someone else's server is never signalled")
    }

    func testParticipantsAndTokens() async throws {
        box.set(true)
        _ = try await sup.sync(human: "ada", retry: true, waitReady: false, blocked: false)
        let t = try await sup.add("bot1", token: nil)
        XCTAssertTrue(t.hasPrefix("dzc_"))
        await XCTAssertThrowsErrorAsync(try await sup.add("bot1", token: nil))
        await XCTAssertThrowsErrorAsync(try await sup.add("ada", token: nil))
        let given = "a-token-it-already-has-0123"
        let replaced = try await sup.replaceToken("bot1", token: given)
        XCTAssertEqual(replaced, given)
        let h = try ChatTokenHashes.load(ChatPaths(folder: root + "/chat"))
        XCTAssertEqual(h.sha256["bot1"], ChatSecrets.hash(given))
        for f in try FileManager.default.contentsOfDirectory(atPath: root + "/chat") {
            let text = (try? String(contentsOfFile: root + "/chat/" + f, encoding: .utf8)) ?? ""
            XCTAssertFalse(text.contains(t) || text.contains(given), "no plain token in \(f)")
        }
        try await sup.remove("bot1")
        await XCTAssertThrowsErrorAsync(try await sup.remove("bot1"))
        await XCTAssertThrowsErrorAsync(try await sup.remove("ada"))
        XCTAssertNil(try ChatTokenHashes.load(ChatPaths(folder: root + "/chat")).sha256["bot1"])
        // A name taken once stays yours.
        await XCTAssertThrowsErrorAsync(try await sup.sync(human: "bob", retry: false, waitReady: false, blocked: false))
    }
}

func XCTAssertThrowsErrorAsync<T>(_ e: @autoclosure () async throws -> T, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) async {
    do { _ = try await e(); XCTFail("no error" + (message.isEmpty ? "" : ": " + message), file: file, line: line) } catch {}
}

final class ChatIdleAndSettingsTests: XCTestCase {
    func testChatKeepsTheDaemonUpAndFollowsAnUpgrade() {
        let on = IdleDecision(alwaysOnSetting: false, timeoutMinutes: 1, chatOn: true, idleSeconds: 999)
        XCTAssertFalse(on.isIdle)
        XCTAssertEqual(on.action, .stay)
        XCTAssertNotEqual(IdleDecision(alwaysOnSetting: false, timeoutMinutes: 1, idleSeconds: 999).action, .stay, "the control: chat off exits")
        if case .restartInPlace = IdleDecision(alwaysOnSetting: false, timeoutMinutes: 1, chatOn: true, executableChange: .replaced).action {} else {
            XCTFail("chat on follows an upgrade with no command, even with always-on off")
        }
        if case .exit = IdleDecision(alwaysOnSetting: false, timeoutMinutes: 1, chatOn: true, executableChange: .replaced, launched: false).action {} else {
            XCTFail("a person's --foreground daemon still exits")
        }
    }

    func testChatCountsAsAKeeperForTheLoginItem() {
        XCTAssertEqual(DaemonLoginItem.decide(setting: "on", alwaysOn: false, keepers: 1, appOwned: false, installed: false, stale: false,
                                              loaded: false, mode: .command).action, .install)
        XCTAssertEqual(DaemonLoginItem.decide(setting: "on", alwaysOn: false, keepers: 0, appOwned: false, installed: false, stale: false,
                                              loaded: false, mode: .command).action, .none)
    }

    func testTheThreeSettings() {
        for (k, def) in [(SettingKey.chatEnabled, TOMLValue.bool(false)), (SettingKey.chatPagePort, .int(8790)), (SettingKey.chatLinePort, .int(8791))] {
            guard let d = DozableSettings.definition(k) else { return XCTFail("no \(k)") }
            XCTAssertEqual(d.defaultValue, def)
            XCTAssertNil(d.environment, "\(k): consent and ports are never an environment value")
            XCTAssertFalse(d.editableInUI, "\(k): set on this Mac only")
            XCTAssertEqual(d.settingClass, .mac)
            XCTAssertFalse(d.summary.lowercased().contains("hub"))
        }
    }
}

/// A chat port left at its default that another program holds (two Dozables on one Mac): chat takes a free one — the next
/// above it, else the system's — saves it in the settings and says so; a port the person chose is never moved.
final class ChatPortChoiceTests: XCTestCase {
    final class Saved: @unchecked Sendable {
        let lock = NSLock()
        var writes: [[String: Int]] = []
        func add(_ p: [String: Int]) { lock.withLock { writes.append(p) } }
        var all: [[String: Int]] { lock.withLock { writes } }
    }
    var root: String!
    override func setUpWithError() throws {
        root = "/tmp/dzc-ports-\(getpid())-\(UUID().uuidString.prefix(6))"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(atPath: root) }

    func supervisor(_ fake: FakeChatProcesses, _ box: SettingsBox, _ saved: Saved) -> ChatSupervisor {
        ChatSupervisor(paths: ChatPaths(folder: root + "/chat"), executable: "/usr/bin/false", release: "0.0.0", processes: fake,
                       environment: [:], readSettings: { box.get() }, savePorts: { p in
                           saved.add(p)
                           box.lock.withLock {
                               if let v = p[SettingKey.chatPagePort] { box.view.pagePort = v; box.view.pageChosen = true }
                               if let v = p[SettingKey.chatLinePort] { box.view.linePort = v; box.view.lineChosen = true }
                           }
                       })
    }
    func defaults(_ box: SettingsBox) { box.lock.withLock { box.view.enabled = true; box.view.pageChosen = false; box.view.lineChosen = false } }

    func testATakenDefaultMovesToAFreePortSavedAndSaid() async throws {
        let fake = FakeChatProcesses(), box = SettingsBox(), saved = Saved()
        defaults(box)
        fake.taken = [8790, 8792]                                   // 8791 is ours (the line port), 8792 another's
        let sup = supervisor(fake, box, saved)
        _ = try await sup.sync(human: "ada", retry: true, waitReady: false, blocked: false)
        XCTAssertEqual(saved.all, [[SettingKey.chatPagePort: 8793]], "the next free one above, never the line port or a taken one")
        let st = await sup.status()
        XCTAssertEqual(st.pagePort, 8793)
        XCTAssertEqual(st.linePort, 8791, "a free default stays")
        XCTAssertEqual(st.note, "page port 8790 was taken by another program; chat uses 8793 (saved in your settings)")
        XCTAssertEqual(fake.spawnCount, 1)
    }

    func testNothingFreeNearbyTakesTheSystemsPort() async throws {
        let fake = FakeChatProcesses(), box = SettingsBox(), saved = Saved()
        defaults(box)
        fake.taken = Set(8791...8811)                               // the line default and the 20 above it
        let sup = supervisor(fake, box, saved)
        _ = try await sup.sync(human: "ada", retry: true, waitReady: false, blocked: false)
        XCTAssertEqual(saved.all, [[SettingKey.chatLinePort: 41_234]])
        let st = await sup.status()
        XCTAssertEqual(st.linePort, 41_234)
        XCTAssertEqual(st.note, "line port 8791 was taken by another program; chat uses 41234 (saved in your settings)")
    }

    func testAChosenPortThatIsTakenIsNeverMoved() async throws {
        let fake = FakeChatProcesses(), box = SettingsBox(), saved = Saved()
        box.set(true)                                               // pageChosen and lineChosen: the person set them
        fake.taken = [8790]
        let sup = supervisor(fake, box, saved)
        _ = try await sup.sync(human: "ada", retry: true, waitReady: false, blocked: false)
        XCTAssertTrue(saved.all.isEmpty, "nothing written")
        let st = await sup.status()
        XCTAssertEqual(st.pagePort, 8790)
        XCTAssertNil(st.note)
    }

    func testAFreeDefaultIsUnchanged() async throws {
        let fake = FakeChatProcesses(), box = SettingsBox(), saved = Saved()
        defaults(box)
        let sup = supervisor(fake, box, saved)
        _ = try await sup.sync(human: "ada", retry: true, waitReady: false, blocked: false)
        XCTAssertTrue(saved.all.isEmpty)
        let st = await sup.status()
        XCTAssertEqual([st.pagePort, st.linePort], [8790, 8791])
        XCTAssertNil(st.note)
    }

    func testARestartKeepsThePickedPorts() async throws {
        let fake = FakeChatProcesses(), box = SettingsBox(), saved = Saved()
        defaults(box)
        fake.taken = [8790]
        let first = supervisor(fake, box, saved)
        _ = try await first.sync(human: "ada", retry: true, waitReady: false, blocked: false)
        await first.stopForExit()
        // Another daemon later (the saved setting now chosen), 8790 free again: chat stays on the port it took.
        fake.taken = []
        let f2 = FakeChatProcesses()
        let second = supervisor(f2, box, saved)
        _ = try await second.sync(human: "ada", retry: true, waitReady: false, blocked: false)
        let st = await second.status()
        XCTAssertEqual(st.pagePort, 8792, "the port it took (8791 is the line port, so never that)")
        XCTAssertEqual(saved.all.count, 1, "saved once")
        XCTAssertNil(st.note, "nothing moved this time")
    }

    func testTheSaveWritesTheSettingsFileThroughTheSchema() throws {
        let xdg = root + "/xdg"
        try FileManager.default.createDirectory(atPath: xdg + "/doz", withIntermediateDirectories: true)
        let env = ["XDG_CONFIG_HOME": xdg, "DOZ_TEST_GUARD": "1"]
        var s = DozableSettings.load(environment: env)
        s = try s.writing(SettingKey.chatPagePort, .int(8793))
        let back = DozableSettings.load(environment: env)
        XCTAssertEqual(back.int(SettingKey.chatPagePort), 8793)
        XCTAssertEqual(ChatSettingsView.read(back, environment: env).pageChosen, true)
        XCTAssertEqual(ChatSettingsView.read(back, environment: env).lineChosen, false)
        // The test seam: a guarded run's default may be the test's own port; a chosen value is never replaced by it.
        let seam = env.merging(["DOZ_TEST_CHAT_DEFAULT_LINE_PORT": "45000", "DOZ_TEST_CHAT_DEFAULT_PAGE_PORT": "45001"]) { $1 }
        let v = ChatSettingsView.read(back, environment: seam)
        XCTAssertEqual([v.pagePort, v.linePort], [8793, 45000])
        XCTAssertEqual(ChatPortChoice.free(after: 8790, avoid: [8791], inUse: { $0 == 8792 }, system: { nil }), 8793)
        XCTAssertNil(ChatPortChoice.free(after: 8790, avoid: [], inUse: { _ in true }, system: { nil }))
    }
}
