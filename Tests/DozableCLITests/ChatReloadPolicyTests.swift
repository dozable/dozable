import Darwin
import DozableChat
@testable import DozableHost
import Foundation
import XCTest

/// `ChatReloadPolicy`: which change of the files the running server takes over its control channel — a table test.
final class ChatReloadPolicyTests: XCTestCase {
    let paths = ChatPaths(folder: "/tmp/dzc-policy/chat")

    func config(_ names: [String], page: Int = 8790, line: Int = 8791, remote: [String] = [], webhook: String? = nil, inbox: String? = nil) throws -> [UInt8] {
        var d = ChatDirectory()
        d.human = "ada"
        d.participants = names.map { ChatDirectory.Participant(name: $0, kind: "agent", added: "2026-11-20T00:00:00Z") }
        if let w = webhook { d.participants.append(.init(name: w, kind: "grok-bot", added: "2026-11-20T00:00:00Z", deliver: "webhook")) }
        if let i = inbox { d.participants.append(.init(name: i, kind: "claude-session", added: "2026-11-20T00:00:00Z", deliver: "inbox")) }
        return try ChatConfigFile.bytes(d, paths: paths, pagePort: page, linePort: line, remoteBind: remote, remoteAgents: remote.isEmpty ? [] : ["100.100.1.2"])
    }

    func files(_ c: [UInt8], tokens: String = "a", webhooks: String = "", sessions: String? = nil) -> ChatServerFiles {
        ChatServerFiles(config: c, tokens: Data(tokens.utf8), webhooks: Data(webhooks.utf8), sessions: sessions)
    }

    func testTheTable() throws {
        let base = files(try config(["bot1", "bot2"]))
        let rows: [(String, ChatServerFiles, ChatReloadPolicy.Decision)] = [
            ("the same files", base, .same),
            ("a participant added", files(try config(["bot1", "bot2", "bot3"])), .reload),
            ("a participant removed", files(try config(["bot1"])), .reload),
            ("three added and one removed", files(try config(["bot2", "bot3", "bot4", "bot5"])), .reload),
            ("a token replaced", files(try config(["bot1", "bot2"]), tokens: "b"), .reload),
            ("added with its token", files(try config(["bot1", "bot2", "bot3"]), tokens: "b"), .reload),
            ("a webhook bot added (its entry not set yet)", files(try config(["bot1", "bot2"], webhook: "hook1")), .reload),
            ("the page port", files(try config(["bot1", "bot2"], page: 8800)), .restart),
            ("the line port", files(try config(["bot1", "bot2"], line: 8801)), .restart),
            ("the remote listener", files(try config(["bot1", "bot2"], remote: ["100.100.1.1"])), .restart),
            ("a webhook entry", files(try config(["bot1", "bot2"]), webhooks: "x"), .restart),
            ("the first inbox participant (the sessions folder)", files(try config(["bot1", "bot2"], inbox: "sess"), sessions: "/tmp/s"), .restart),
            ("a config that is not JSON", files(Array("nope".utf8)), .restart),
        ]
        for (what, new, want) in rows {
            XCTAssertEqual(ChatReloadPolicy.decide(old: base, new: new), want, what)
        }
    }

    func testAChangedDeliveryRestarts() throws {
        let a = files(try config(["bot1"], webhook: "hook1"))
        var d = ChatDirectory()
        d.human = "ada"
        d.participants = [.init(name: "bot1", kind: "agent", added: "x"), .init(name: "hook1", kind: "grok-bot", added: "x")]
        let b = files(try ChatConfigFile.bytes(d, paths: paths, pagePort: 8790, linePort: 8791))
        XCTAssertEqual(ChatReloadPolicy.decide(old: a, new: b), .restart, "a participant whose entry changed in place")
    }
}

/// A process table whose children have a control channel: a thread answers each reload request as told.
final class ControlChatProcesses: ChatProcesses, @unchecked Sendable {
    enum Answer { case reloaded, refused, silent }
    let lock = NSLock()
    var answer = Answer.reloaded
    var spawned = 0
    var requests: [String] = []
    var running: Set<pid_t> = []
    var exits: [pid_t: ChatChildExit] = [:]
    var holder: Int32?
    var nextPid: pid_t = 80_000
    var terms = 0

    var offersControl: Bool { true }

    func spawn(executable: String, arguments: [String], environment: [String: String], log: String, input: Data?) throws -> pid_t {
        lock.withLock { spawned += 1; nextPid += 1; running.insert(nextPid); holder = nextPid; return nextPid }
    }

    func spawnSupervised(executable: String, arguments: [String], environment: [String: String], log: String, input: Data?) throws -> (pid: pid_t, control: Int32?) {
        precondition(arguments.contains("--control-fd"), "the channel is named in argv")
        let pid = try spawn(executable: executable, arguments: arguments, environment: environment, log: log, input: input)
        var sv: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sv) == 0 else { throw HostError(.failed, "socketpair") }
        let child = sv[1]
        let t = Thread { [self] in
            var buf = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = read(child, &buf, buf.count)
                if n <= 0 { break }
                let line = String(decoding: buf[0..<n], as: UTF8.self)
                // The closed set the supervisor sends at every start (ChatRoomControl): answered as a server does, by its id.
                if let v = try? ChatJSON.parse(Array(line.utf8).filter { $0 != 0x0A }), v.field("closed") != nil {
                    let id = v.field("id")?.stringValue ?? ""
                    let out = #"{"closed":{},"id":"\#(id)"}"# + "\n"
                    _ = out.withCString { write(child, $0, strlen($0)) }
                    continue
                }
                let a = lock.withLock { () -> Answer in requests.append(line); return answer }
                let sha = (try? ChatJSON.parse(Array(line.utf8).filter { $0 != 0x0A }))?.field("reload")?.stringValue ?? ""
                let out: String
                switch a {
                case .reloaded: out = #"{"reloaded":"\#(sha)"}"# + "\n"
                case .refused: out = #"{"refused":"no"}"# + "\n"
                case .silent: continue
                }
                _ = out.withCString { write(child, $0, strlen($0)) }
            }
            close(child)
        }
        t.start()
        return (pid, sv[0])
    }

    func reap(_ pid: pid_t) -> ChatChildExit? {
        lock.withLock {
            guard let e = exits.removeValue(forKey: pid) else { return nil }
            running.remove(pid)
            if holder == pid { holder = nil }
            return e
        }
    }
    func signal(_ pid: pid_t, _ sig: Int32) {
        lock.withLock {
            if sig == SIGTERM { terms += 1 }
            if running.contains(pid) { exits[pid] = ChatChildExit(signal: sig) }
        }
    }
    func server(dataDir: String) -> (pid: Int32?, ready: Bool) { lock.withLock { (holder, true) } }
    func arguments(of pid: pid_t) -> [String]? { nil }
    func portInUse(_ port: Int) -> Bool { false }
}

/// The supervisor with a control channel: a participant change is a reload, never a restart, unless the server cannot
/// take it; a batch is all or nothing.
final class ChatSupervisorReloadTests: XCTestCase {
    var root: String!
    var fake: ControlChatProcesses!
    var box: SettingsBox!
    var sup: ChatSupervisor!

    override func setUpWithError() throws {
        root = "/tmp/dzc-supr-\(getpid())-\(UUID().uuidString.prefix(6))"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        fake = ControlChatProcesses()
        box = SettingsBox()
        let b = box!
        sup = ChatSupervisor(paths: ChatPaths(folder: root + "/chat"), executable: "/usr/bin/false", release: "0.0.0", processes: fake,
                             environment: [:], readSettings: { b.get() })
        box.set(true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(atPath: root) }

    func running() async throws {
        _ = try await sup.sync(human: "ada", retry: true, waitReady: false, blocked: false)
        await sup.tick(blocked: false)
        let st = await sup.status()
        XCTAssertTrue(st.ready)
    }

    func testABatchOfThreeIsOneReloadAndNoRestart() async throws {
        try await running()
        let made = try await sup.members(add: [ChatMemberAdd(name: "bot1"), ChatMemberAdd(name: "bot2"), ChatMemberAdd(name: "bot3")], remove: [])
        XCTAssertEqual(made.map(\.name), ["bot1", "bot2", "bot3"])
        XCTAssertTrue(made.allSatisfy { $0.token.hasPrefix("dzc_") })
        let st = await sup.status()
        XCTAssertEqual(fake.spawned, 1, "no restart")
        XCTAssertEqual(fake.terms, 0)
        XCTAssertEqual(st.reloads, 1, "one write, one reload")
        XCTAssertEqual(fake.requests.count, 1)
        let d = try ChatDirectory.load(sup.paths)
        XCTAssertEqual(d.participants.map(\.name), ["bot1", "bot2", "bot3"])
        // Removing two is one more reload, still no restart; a single add too.
        _ = try await sup.members(add: [], remove: ["bot1", "bot2"])
        _ = try await sup.add("bot4", token: nil)
        try await sup.remove("bot3")
        let st2 = await sup.status()
        XCTAssertEqual(st2.reloads, 4)
        XCTAssertEqual(fake.spawned, 1)
        XCTAssertEqual(st2.restarts, 0)
    }

    func testABatchIsAllOrNothing() async throws {
        try await running()
        _ = try await sup.add("bot1", token: nil)
        let before = try Data(contentsOf: URL(fileURLWithPath: sup.paths.directory))
        let tokensBefore = try Data(contentsOf: URL(fileURLWithPath: sup.paths.tokens))
        for (add, remove) in [([ChatMemberAdd(name: "bot2"), ChatMemberAdd(name: "bot1")], [String]()),     // one already in chat
                              ([ChatMemberAdd(name: "bot2"), ChatMemberAdd(name: "Bad Name")], []),          // the name rule
                              ([ChatMemberAdd(name: "bot2"), ChatMemberAdd(name: "bot2")], []),              // twice
                              ([ChatMemberAdd(name: "bot2")], ["nobody"]),                                   // not there to remove
                              ([ChatMemberAdd(name: "bot2")], ["ada"]),                                      // the human
                              ([ChatMemberAdd(name: "bot2", kind: "nope")], [])] {                           // a kind
            await XCTAssertThrowsErrorAsync(try await sup.members(add: add, remove: remove))
        }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: sup.paths.directory)), before, "nothing was written")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: sup.paths.tokens)), tokensBefore)
    }

    func testARefusedOrUnansweredReloadFallsBackToARestart() async throws {
        try await running()
        fake.lock.withLock { fake.answer = .refused }
        _ = try await sup.add("bot1", token: nil)
        var st = await sup.status()
        XCTAssertEqual(st.reloadFallbacks, 1)
        XCTAssertEqual(fake.terms, 1, "restarted instead")
        await sup.tick(blocked: false)
        await sup.tick(blocked: false)
        XCTAssertEqual(fake.spawned, 2)
        fake.lock.withLock { fake.answer = .silent }
        let t0 = Date()
        _ = try await sup.add("bot2", token: nil)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 4.5, "at most the reload's 2 s, then the restart")
        st = await sup.status()
        XCTAssertEqual(st.reloadFallbacks, 2)
        XCTAssertEqual(fake.terms, 2)
    }

    func testAPortChangeStillRestarts() async throws {
        try await running()
        box.lock.withLock { box.view.pagePort = 8800 }
        _ = try await sup.sync(human: nil, retry: false, waitReady: false, blocked: false)
        XCTAssertEqual(fake.terms, 1)
        XCTAssertTrue(fake.requests.isEmpty, "never a reload for a port")
    }
}
