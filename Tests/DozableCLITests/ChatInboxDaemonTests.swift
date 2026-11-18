import Darwin
import DozableChat
import Foundation
import XCTest
@testable import DozableHost

/// Delivery into a Claude Code session's inbox under the daemon: the directory's `inbox` participants, the generated
/// config (`inbox-socket` for a `claude-session` only, a session name never a path), the sessions folder as a SEAM the
/// supervisor hands the server (`--claude-sessions`, only while one is delivered to by inbox), `set --deliver` keeping
/// the token and the rooms, and — with the real `doz chat serve` the supervisor starts — a scratch session handed a
/// message, a missing one `failed`, presence, the token answering, and nothing written outside the data folder.
///
/// No test here reads the person's `~/.claude` or connects to a real session: every sessions folder and socket is made
/// by the test under /tmp (`ScratchClaudeSession` refuses a real one), and the default resolver is stopped by
/// `TestSafety` in a test run without the seam.
final class ChatInboxDirectoryTests: XCTestCase {
    var root: String!
    var paths: ChatPaths { ChatPaths(folder: root + "/chat") }

    override func setUpWithError() throws {
        root = "/tmp/dzc-ibx-\(getpid())-\(UUID().uuidString.prefix(6))"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(atPath: root) }

    func testTheGeneratedConfigCarriesAnInboxSessionByName() throws {
        let d = ChatDirectory(human: "ada", participants: [
            .init(name: "bot1", kind: "claude-session", added: "2026-01-01T00:00:00Z", deliver: "inbox"),
            .init(name: "bot2", kind: "claude-session", added: "2026-01-01T00:00:00Z", deliver: "inbox", session: "worker-2"),
            .init(name: "bot3", added: "2026-01-01T00:00:00Z"),
        ])
        let text = String(decoding: try ChatConfigFile.bytes(d, paths: paths, pagePort: 8790, linePort: 8791), as: UTF8.self)
        let c = try ChatConfig.parse(Data(text.utf8))
        let byName = Dictionary(uniqueKeysWithValues: c.participants.map { ($0.name, $0) })
        XCTAssertEqual(byName["bot1"]?.deliver, "inbox-socket")
        XCTAssertEqual(byName["bot1"]?.session, "bot1", "its own name by default")
        XCTAssertEqual(byName["bot2"]?.session, "worker-2")
        XCTAssertEqual(byName["bot3"]?.deliver, "", "one that polls has no deliver value")
        XCTAssertTrue(d.hasInbox)
        XCTAssertFalse(ChatDirectory(human: "ada", participants: [.init(name: "bot3", added: "x")]).hasInbox)
        // The profile is unchanged otherwise: loopback, tokens required, every loopback caller an agent.
        XCTAssertEqual(c.bind, "127.0.0.1")
        XCTAssertTrue(c.requireTokens)
        XCTAssertEqual(c.access.page(remote: "127.0.0.1", agentPath: false), ChatAccess.agentOnly)
    }

    func testTheGeneratorRefusesInboxForAnotherKindOrABadSessionName() {
        for p in [ChatDirectory.Participant(name: "bot1", kind: "agent", added: "x", deliver: "inbox"),
                  ChatDirectory.Participant(name: "bot1", kind: "claude-session", added: "x", deliver: "inbox", session: "../../x"),
                  ChatDirectory.Participant(name: "bot1", kind: "claude-session", added: "x", deliver: "inbox", session: "/tmp/sock")] {
            XCTAssertThrowsError(try ChatConfigFile.bytes(ChatDirectory(human: "ada", participants: [p]), paths: paths, pagePort: 8790, linePort: 8791),
                                 "\(p.kind) \(p.session ?? "")")
        }
    }

    func testTheDeliveryRules() {
        XCTAssertNil(ChatDirectory.deliveryRefusal("inbox", kind: "claude-session", session: nil))
        XCTAssertNil(ChatDirectory.deliveryRefusal("inbox", kind: "claude-session", session: "worker-2"))
        XCTAssertTrue(ChatDirectory.deliveryRefusal("inbox", kind: "agent", session: nil)?.contains("claude-session") == true)
        // A Claude Code session's name is free text the person sets: capitals and spaces are fine, compared exactly.
        XCTAssertNil(ChatDirectory.deliveryRefusal("inbox", kind: "claude-session", session: "OPS-PROJECTS on m1max"))
        XCTAssertNil(ChatDirectory.deliveryRefusal("inbox", kind: "claude-session", session: "Revue de code — été"))
        XCTAssertNil(ChatDirectory.deliveryRefusal("inbox", kind: "claude-session", session: String(repeating: "a", count: 100)))
        for bad in ["", " lead", "lead ", "a\nb", "a\u{0}b", "a\u{1B}[31mb", "a\u{2028}b", "a\u{202E}b", "../x", "/tmp/sock",
                    String(repeating: "a", count: 101)] {
            XCTAssertNotNil(ChatDirectory.deliveryRefusal("inbox", kind: "claude-session", session: bad), bad.debugDescription)
        }
        XCTAssertFalse(ChatDirectory.deliveryRefusal("inbox", kind: "claude-session", session: "a\u{1B}b")!.contains("\u{1B}"),
                       "the refusal never echoes a control character")
        XCTAssertNotNil(ChatDirectory.deliveryRefusal("poll", kind: "agent", session: "x"), "--session goes with inbox")
        XCTAssertNotNil(ChatDirectory.deliveryRefusal("socket", kind: "agent", session: nil))
        XCTAssertNil(ChatDirectory.deliveryRefusal("webhook", kind: "grok-bot", session: nil))
        let p = ChatDirectory.Participant(name: "bot1", kind: "claude-session", added: "x", deliver: "inbox")
        XCTAssertEqual(p.inboxSession, "bot1")
        XCTAssertEqual(p.delivery, "inbox")
        XCTAssertNil(p.webhookEntry)
        // An older doz's record (no session field) reads back.
        let old = #"{"version":1,"human":"ada","participants":[{"name":"bot1","kind":"agent","added":"x"}]}"#
        XCTAssertEqual(try JSONDecoder().decode(ChatDirectory.self, from: Data(old.utf8)).participants.first?.delivery, "poll")
    }

    /// The sessions folder: the seam in a test run; the real one would stop a guarded run.
    func testTheSessionsFolderIsASeamAndTheRealOneIsRefusedInATest() {
        XCTAssertEqual(ChatClaudeSessions.folder(environment: ["DOZ_TEST_GUARD": "1", "DOZ_TEST_CLAUDE_SESSIONS": "/tmp/scratch-sessions"]), "/tmp/scratch-sessions")
        let home = TestSafety.realHome
        XCTAssertNotNil(TestSafety.claudeSessionsViolation(home.appendingPathComponent(".claude/sessions").path))
        XCTAssertNotNil(TestSafety.claudeSessionsViolation(home.appendingPathComponent(".claude").path))
        XCTAssertNil(TestSafety.claudeSessionsViolation("/tmp/scratch-sessions"))
        XCTAssertNil(TestSafety.claudeSessionsViolation(home.appendingPathComponent(".claudex/sessions").path))
    }
}

/// The supervisor against a fake process table: the folder handed only while a participant is delivered to by inbox,
/// and `set` keeping the token and the participant.
final class ChatInboxSupervisorTests: XCTestCase {
    var root: String!
    var fake: FakeChatProcesses!
    var box: SettingsBox!
    var sup: ChatSupervisor!
    var paths: ChatPaths { ChatPaths(folder: root + "/chat") }
    var sessions: String { root + "/sessions" }

    override func setUpWithError() throws {
        root = "/tmp/dzc-isup-\(getpid())-\(UUID().uuidString.prefix(6))"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        fake = FakeChatProcesses()
        box = SettingsBox()
        box.set(true)
        let b = box!, s = sessions
        sup = ChatSupervisor(paths: paths, executable: "/usr/bin/false", release: "0.0.0", processes: fake, environment: [:],
                             claudeSessions: { s }, readSettings: { b.get() })
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(atPath: root) }

    func args(_ i: Int) -> [String] { fake.lock.withLock { fake.spawned[i] } }

    func testTheFolderIsHandedOnlyWhileOneIsDeliveredByInbox() async throws {
        _ = try await sup.sync(human: "ada", retry: true, waitReady: false, blocked: false)
        XCTAssertFalse(args(0).contains("--claude-sessions"), "no inbox participant: the server reads nothing outside its data folder")
        var st = await sup.status()
        XCTAssertNil(st.claudeSessions)
        let token = try await sup.add("bot1", token: nil, kind: "claude-session", inbox: true)
        let a = args(fake.spawnCount - 1)
        XCTAssertEqual(a[a.firstIndex(of: "--claude-sessions")! + 1], sessions)
        st = await sup.status()
        XCTAssertEqual(st.claudeSessions, sessions)
        for f in try FileManager.default.contentsOfDirectory(atPath: paths.folder) {
            XCTAssertFalse(((try? String(contentsOfFile: paths.folder + "/" + f, encoding: .utf8)) ?? "").contains(token), "no token in \(f)")
        }
        // set: poll → the folder is no longer handed; the token's hash and the participant stay
        let before = try ChatTokenHashes.load(paths).sha256["bot1"]
        let p = try await sup.set("bot1", deliver: "poll")
        XCTAssertEqual(p.delivery, "poll")
        XCTAssertFalse(args(fake.spawnCount - 1).contains("--claude-sessions"))
        XCTAssertEqual(try ChatTokenHashes.load(paths).sha256["bot1"], before, "the token is kept")
        st = await sup.status()
        XCTAssertNil(st.claudeSessions)
        // and back, with another session name
        let q = try await sup.set("bot1", deliver: "inbox", session: "worker-2")
        XCTAssertEqual(q.inboxSession, "worker-2")
        XCTAssertTrue(String(decoding: try Data(contentsOf: URL(fileURLWithPath: paths.config)), as: UTF8.self).contains("\"worker-2\""))
        XCTAssertEqual(try ChatTokenHashes.load(paths).sha256["bot1"], before)
    }

    func testTheRefusals() async throws {
        _ = try await sup.sync(human: "ada", retry: true, waitReady: false, blocked: false)
        await XCTAssertThrowsErrorAsync(try await sup.add("bot1", token: nil, kind: "agent", inbox: true), "inbox for an agent")
        await XCTAssertThrowsErrorAsync(try await sup.add("bot1", token: nil, kind: "claude-session", webhook: true, inbox: true), "both")
        _ = try await sup.add("bot1", token: nil)
        await XCTAssertThrowsErrorAsync(try await sup.set("bot1", deliver: "inbox"), "an agent cannot be inbox")
        await XCTAssertThrowsErrorAsync(try await sup.set("nobody", deliver: "poll"))
        await XCTAssertThrowsErrorAsync(try await sup.set("ada", deliver: "poll"), "you")
        await XCTAssertThrowsErrorAsync(try await sup.set("bot1", deliver: "poll", entry: "e1"), "an entry without webhook")
        await XCTAssertThrowsErrorAsync(try await sup.set("bot1", deliver: "webhook", entry: "default"), "the shared entry name")
        let p = try await sup.set("bot1", deliver: "inbox", kind: "claude-session")
        XCTAssertEqual(p.kind, "claude-session")
        XCTAssertEqual(p.delivery, "inbox")
        let w = try await sup.set("bot1", deliver: "webhook")
        XCTAssertEqual(w.webhookEntry, "bot1")
        XCTAssertNil(w.inboxSession)
    }
}

/// A Claude Code session the test makes: a record (and key file) in a SCRATCH sessions folder, naming a socket in a
/// scratch folder under /tmp that this test listens on. It refuses a real `~/.claude`.
final class ScratchClaudeSession: @unchecked Sendable {
    let socketDir: String
    var socket: String { socketDir + "/inbox.sock" }
    let token: String
    let record: String
    private let fd: Int32
    private let lock = NSLock()
    private var got: [[String: Any]] = []

    init(name: String, sessionsDir: String, token: String = "peer-key-0123456789abcdef") throws {
        precondition(TestSafety.claudeSessionsViolation(sessionsDir) == nil && !sessionsDir.hasPrefix(NSHomeDirectory() + "/.claude"), "a test never uses a real sessions folder")
        self.token = token
        var template = Array("/tmp/dzc-XXXXXX".utf8CString)
        guard let made = mkdtemp(&template) else { throw NSError(domain: "ScratchClaudeSession", code: Int(errno)) }
        socketDir = String(cString: made)
        let s = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let p = Array((socketDir + "/inbox.sock").utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in for (i, b) in p.enumerated() { raw[i] = b } }
        let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard ok == 0, listen(s, 16) == 0 else { close(s); throw NSError(domain: "ScratchClaudeSession", code: Int(errno)) }
        fd = s
        try FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        record = (sessionsDir as NSString).appendingPathComponent("\(getpid()).json")
        try Data(#"{"peerToken":"\#(token)"}"#.utf8).write(to: URL(fileURLWithPath: (sessionsDir as NSString).appendingPathComponent("\(getpid()).0a1b2c3d.key")))
        let ms = Int64(Date().timeIntervalSince1970 * 1000)
        try Data(#"{"pid":\#(getpid()),"name":"\#(name)","messagingSocketPath":"\#(socket)","status":"idle","statusUpdatedAt":\#(ms),"kind":"interactive"}"#.utf8)
            .write(to: URL(fileURLWithPath: record))
        Thread.detachNewThread { [self] in accept() }
    }

    var texts: [String] {
        lock.withLock { got }.filter { $0["type"] as? String == "user" }.compactMap { ($0["message"] as? [String: Any])?["content"] as? String }
    }
    var authTokens: [String] { lock.withLock { got }.compactMap { $0["type"] as? String == "auth" ? $0["token"] as? String : nil } }

    func waitTexts(_ n: Int, seconds: Double = 10) -> [String] {
        let deadline = Date().addingTimeInterval(seconds)
        while texts.count < n && Date() < deadline { usleep(20_000) }
        return texts
    }

    func stop() {
        shutdown(fd, SHUT_RDWR)
        close(fd)
        try? FileManager.default.removeItem(atPath: socketDir)
    }

    private func accept() {
        while true {
            let c = Darwin.accept(fd, nil, nil)
            if c < 0 { return }
            Thread.detachNewThread { [self] in
                defer { close(c) }
                var buf = [UInt8](repeating: 0, count: 65536), pending = [UInt8]()
                while true {
                    let n = read(c, &buf, buf.count)
                    if n <= 0 { break }
                    pending += buf[0..<n]
                    while let i = pending.firstIndex(of: 0x0A) {
                        let line = Array(pending[..<i])
                        pending.removeSubrange(...i)
                        if let v = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] { lock.withLock { got.append(v) } }
                    }
                }
            }
        }
    }
}

/// The real `doz chat serve`, started by the real supervisor (posix_spawn) with the generated inbox profile: a scratch
/// store folder, HOME, TMPDIR and sessions folder, all short paths under /tmp; free ports the test picks.
final class ChatInboxServeTests: XCTestCase {
    var root: String!
    var started: ChatSupervisor?
    var paths: ChatPaths { ChatPaths(folder: root + "/chat") }
    var sessions: String { root + "/sess" }
    let botToken = "bot1-own-token-0123456789abcdef"

    override func setUpWithError() throws {
        root = "/tmp/dzc-ise-\(getpid())-\(UUID().uuidString.prefix(4))"
        for d in [root!, root + "/home", root + "/tmp"] {
            try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
    }
    override func tearDown() async throws {
        if let s = started { await s.stopForExit() }
        try? FileManager.default.removeItem(atPath: root)
    }

    static func doz() throws -> String {
        if let p = ProcessInfo.processInfo.environment["DOZ_CHAT_TEST_DOZ"], !p.isEmpty { return p }
        let u = Bundle(for: ChatInboxServeTests.self).bundleURL.deletingLastPathComponent().appendingPathComponent("doz")
        guard FileManager.default.isExecutableFile(atPath: u.path) else { throw XCTSkip("no doz beside the test bundle (\(u.path)); build it first (make build)") }
        return u.path
    }

    static func freePort() -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var a = sockaddr_in()
        a.sin_family = sa_family_t(AF_INET); a.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        return Int(UInt16(bigEndian: a.sin_port))
    }

    /// One HTTP/1.1 call on TCP 127.0.0.1 (an agent's), its status and body.
    func tcp(_ port: Int, _ method: String, _ path: String, token: String, body: String? = nil) -> (Int, String) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var tv = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var a = sockaddr_in()
        a.sin_family = sa_family_t(AF_INET); a.sin_port = in_port_t(UInt16(port).bigEndian); a.sin_addr.s_addr = inet_addr("127.0.0.1")
        guard withUnsafePointer(to: &a, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }) == 0 else { return (0, "") }
        var req = "\(method) \(path) HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer \(token)\r\nConnection: close\r\n"
        if let body { req += "Content-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n" }
        req += "\r\n" + (body ?? "")
        _ = req.withCString { write(fd, $0, strlen($0)) }
        var out = Data(), buf = [UInt8](repeating: 0, count: 8192)
        while true { let n = read(fd, &buf, buf.count); if n <= 0 { break }; out.append(contentsOf: buf[0..<n]) }
        let text = String(decoding: out, as: UTF8.self)
        let status = Int(text.split(separator: " ").dropFirst().first ?? "") ?? 0
        return (status, text.components(separatedBy: "\r\n\r\n").dropFirst().joined(separator: "\r\n\r\n"))
    }

    func owner(_ method: String, _ target: String, _ body: String? = nil) -> (Int, JValue) {
        guard let a = try? ChatOwnerClient(paths: paths).request(method, target, json: body.map { Data($0.utf8) }) else { return (0, .null) }
        return (a.status, (try? ChatJSON.parse(a.body)) ?? .null)
    }

    /// The states of the room's message with this text, for a recipient.
    func states(_ room: String, _ text: String, for who: String) -> [(String, String)] {
        let (_, v) = owner("GET", "/api/rooms/\(room)/messages?limit=50")
        guard case .array(let ms) = v, let m = ms.last(where: { $0.field("content")?.stringValue == text }), case .array(let sts)? = m.field("states") else { return [] }
        return sts.compactMap { s in
            guard s.field("recipient")?.stringValue == who, let st = s.field("state")?.stringValue else { return nil }
            return (st, s.field("detail")?.stringValue ?? "")
        }
    }

    func waitState(_ room: String, _ text: String, for who: String, _ want: String) -> (String, String)? {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let s = states(room, text, for: who).first(where: { $0.0 == want }) { return s }
            usleep(100_000)
        }
        return nil
    }

    func presence(_ name: String) -> String {
        let (_, v) = owner("GET", "/api/presence")
        guard case .array(let ps) = v else { return "" }
        return ps.first { $0.field("name")?.stringValue == name }?.field("state")?.stringValue ?? ""
    }

    /// Every path under a folder, relative to it.
    func tree(_ dir: String) -> Set<String> {
        guard let e = FileManager.default.enumerator(atPath: dir) else { return [] }
        return Set(e.compactMap { $0 as? String })
    }

    func testAnInboxParticipantUnderTheDaemonProfile() async throws {
        let doz = try Self.doz()
        XCTAssertLessThanOrEqual(paths.socket.utf8.count, 103)
        let box = SettingsBox()
        box.view = ChatSettingsView(enabled: true, pagePort: Self.freePort(), linePort: Self.freePort())
        let page = box.view.pagePort
        let s = sessions
        let sup = ChatSupervisor(paths: paths, executable: doz, release: "0.0.0", processes: ChatSystemProcesses(),
                                 environment: ["HOME": root + "/home", "TMPDIR": root + "/tmp/", "LANG": "en_US.UTF-8"],
                                 claudeSessions: { s }, readSettings: { box.get() })
        started = sup
        var st = try await sup.sync(human: "ada", retry: true, waitReady: true, blocked: false)
        XCTAssertTrue(st.ready, "ready: \(st.problem ?? st.state)")
        _ = try await sup.add("bot1", token: botToken, kind: "claude-session", inbox: true)
        st = try await sup.sync(human: nil, retry: false, waitReady: true, blocked: false)
        XCTAssertTrue(st.ready, "ready again with bot1: \(st.problem ?? st.state)")
        let pid = try XCTUnwrap(st.pid)
        let argv = ProcessArguments.of(pid) ?? []
        XCTAssertEqual(argv.firstIndex(of: "--claude-sessions").map { argv[$0 + 1] }, sessions, "the seam, handed on the command line: \(argv)")

        XCTAssertEqual(owner("POST", "/api/rooms/general/messages", #"{"content":"/room room1 @bot1"}"#).0, 200)
        // No session running: failed in the protocol's words, presence says so.
        XCTAssertEqual(owner("POST", "/api/rooms/room1/messages", #"{"content":"first @bot1"}"#).0, 200)
        let failed = waitState("room1", "first @bot1", for: "bot1", "failed")
        XCTAssertEqual(failed?.1, "no running Claude session with that name")
        XCTAssertEqual(presence("bot1"), "not running")

        // A scratch session: the next message is in its inbox, with the answer that works.
        let session = try ScratchClaudeSession(name: "bot1", sessionsDir: sessions)
        defer { session.stop() }
        let records = tree(sessions)
        XCTAssertEqual(presence("bot1"), "idle")
        XCTAssertEqual(owner("POST", "/api/rooms/room1/messages", #"{"content":"second @bot1"}"#).0, 200)
        XCTAssertNotNil(waitState("room1", "second @bot1", for: "bot1", "delivered"))
        let texts = session.waitTexts(1)
        let handed = texts.first { $0.contains("second @bot1") } ?? ""
        XCTAssertTrue(handed.hasPrefix("[room room1 · from ada"), handed)
        let id = try XCTUnwrap(handed.range(of: #"--re [0-9a-f-]{36}"#, options: .regularExpression).map { String(handed[$0].dropFirst(5)) }, handed)
        XCTAssertTrue(handed.hasSuffix("To answer in the room: dozchat send room1 --re \(id) \"…\""), handed)
        XCTAssertEqual(session.authTokens, [session.token], "the session's own key, on its own socket")

        // It answers with its own token on the agent calls, like any participant; it may not also poll.
        let ans = tcp(page, "POST", "/agent/send", token: botToken,
                      body: #"{"room":"room1","re_msg_id":"\#(id)","message":{"content":"answered"}}"#)
        XCTAssertEqual(ans.0, 200, ans.1)
        XCTAssertTrue(ans.1.contains("\"queued\""), ans.1)
        XCTAssertEqual(tcp(page, "GET", "/agent/receive", token: botToken).0, 403, "an inbox participant is not also polled")

        // set --deliver poll and back: the token, the room and the history are kept.
        _ = try await sup.set("bot1", deliver: "poll")
        _ = try await sup.sync(human: nil, retry: false, waitReady: true, blocked: false)
        XCTAssertEqual(tcp(page, "GET", "/agent/receive", token: botToken).0, 200, "polls now, with the same token")
        _ = try await sup.set("bot1", deliver: "inbox")
        _ = try await sup.sync(human: nil, retry: false, waitReady: true, blocked: false)
        let (_, state) = owner("GET", "/api/state")
        XCTAssertEqual(state.field("rooms")?.field("room1").flatMap { try? $0.goStrings("rooms") }, ["ada", "bot1"], "still in room1")
        XCTAssertEqual(owner("POST", "/api/rooms/room1/messages", #"{"content":"third @bot1"}"#).0, 200)
        XCTAssertNotNil(waitState("room1", "third @bot1", for: "bot1", "delivered"))
        XCTAssertFalse(states("room1", "answered", for: "ada").isEmpty, "the history is kept")

        // Isolation: outside its data folder only the records it read and the socket it wrote to; none written.
        await sup.stopForExit()
        started = nil
        XCTAssertEqual(tree(sessions), records, "the session records are read, never written")
        XCTAssertEqual(tree(root + "/home"), [], "nothing in the home folder")
        XCTAssertEqual(tree(root + "/tmp"), [], "nothing in TMPDIR")
        XCTAssertEqual(Set((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []), ["chat", "home", "tmp", "sess"])
        // No token or key anywhere it writes, and none in what status says.
        var leaks: [String] = []
        for f in tree(paths.folder) {
            guard let d = FileManager.default.contents(atPath: paths.folder + "/" + f) else { continue }
            let t = String(decoding: d, as: UTF8.self)
            if t.contains(botToken) || t.contains(session.token) { leaks.append(f) }
        }
        XCTAssertEqual(leaks, [], "a token or the session's key in the chat folder")
        let enc = String(decoding: try JSONEncoder().encode(await sup.status()), as: UTF8.self)
        XCTAssertFalse(enc.contains(session.token) || enc.contains(botToken))
    }
}
