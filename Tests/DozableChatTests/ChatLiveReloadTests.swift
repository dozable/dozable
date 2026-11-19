import Darwin
@testable import DozableChat
import Foundation
import XCTest

/// A participant change without a restart (ChatReload.swift): the server reads its two files again over the daemon's
/// control channel. The differential test holds the rule "a reload equals a restart": the state after a reload is the
/// state a fresh start on the same files makes.
final class ChatLiveReloadTests: XCTestCase {
    static let t1 = "bot1-token-0123456789abcdef"
    static let t1b = "bot1-other-token-0123456789"
    static let t2 = "bot2-token-0123456789abcdef"
    static let t3 = "bot3-token-0123456789abcdef"
    static let sessionHash = String(repeating: "ab", count: 32)

    var dir = ""
    var configPath: String { dir + "/config.json" }
    var hashesPath: String { dir + "/tokens.json" }
    var dataDir: String { dir + "/data" }

    override func setUpWithError() throws {
        dir = "/tmp/dzc-reload-\(getpid())-\(UUID().uuidString.prefix(6))"
        try FileManager.default.createDirectory(atPath: dataDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // The data folder as a running server left it: room1 lists bot2 (removed later and added again — EDGE 17), and a
        // registered session.
        try write(dataDir + "/rooms.json", #"{"room1": ["ada", "bot1", "bot2", "sess1"]}"#)
        try write(dataDir + "/agents.json", #"{"participants": [{"name": "sess1", "kind": "claude-session"}], "tokens": {"sess1": "\#(Self.sessionHash)"}}"#)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(atPath: dir) }

    func write(_ path: String, _ text: String) throws {
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
        chmod(path, 0o600)
    }

    /// The generated profile's shape: the human, the participants (none delivered to: each polls), one room.
    func files(_ names: [String], tokens: [String: String], port: Int = 0) throws {
        let people = ([#"{"name": "ada", "kind": "human", "deliver": "web"}"#] + names.map { #"{"name": "\#($0)", "kind": "agent"}"# }).joined(separator: ", ")
        try write(configPath, """
            {"line_port": \(port), "http_port": 0, "data_dir": "\(dataDir)", "default_room": "room1", "participants": [\(people)],
             "rooms": {"room1": ["ada"]}, "allow": ["127.0.0.1", "::1"], "require_tokens": true, "agent_addresses": ["127.0.0.0/8", "::1"],
             "secrets_file_only": true, "bind": "127.0.0.1"}
            """)
        let h = tokens.map { #""\#($0.key)": "\#(ChatSecrets.hash($0.value))""# }.joined(separator: ", ")
        try write(hashesPath, #"{"version": 1, "sha256": {\#(h)}}"#)
    }

    func start() throws -> ChatServerCore {
        let c = try ChatConfig.resolve(path: configPath, .init())
        let core = ChatServerCore(config: c, secrets: try ChatSecrets.loadHashes(path: hashesPath), release: "1.2.3",
                                  sessionsDir: dir + "/no-sessions")
        core.load()
        return core
    }

    func sha() throws -> String {
        ChatReload.sha(config: try Data(contentsOf: URL(fileURLWithPath: configPath)), tokens: try Data(contentsOf: URL(fileURLWithPath: hashesPath)))
    }

    @discardableResult
    func reload(_ core: ChatServerCore) throws -> ChatReload.Outcome {
        ChatReload.perform(core: core, configPath: configPath, overrides: .init(), hashesPath: hashesPath, want: try sha())
    }

    func assertSameAsAStart(_ core: ChatServerCore, tokens: [String], file: StaticString = #filePath, line: UInt = #line) throws {
        let fresh = try start()
        let a = core.membershipSnapshot(), b = fresh.membershipSnapshot()
        XCTAssertEqual(a.participants, b.participants, "participants", file: file, line: line)
        XCTAssertEqual(a.rooms, b.rooms, "rooms and members", file: file, line: line)
        XCTAssertEqual(a.sessions, b.sessions, "registered sessions", file: file, line: line)
        XCTAssertEqual(a.hashes, b.hashes, "token hashes", file: file, line: line)
        for t in tokens {
            XCTAssertEqual(core.whoHas(t), fresh.whoHas(t), file: file, line: line)
            XCTAssertEqual(core.whoHolds(t), fresh.whoHolds(t), file: file, line: line)
        }
        XCTAssertEqual(ChatServer.problems(config: core.config, secrets: core.secrets, core: core),
                       ChatServer.problems(config: fresh.config, secrets: fresh.secrets, core: fresh), file: file, line: line)
        fresh.close()
    }

    // MARK: the differential test

    func testAReloadEqualsARestart() throws {
        let all = [Self.t1, Self.t1b, Self.t2, Self.t3]
        try files(["bot1", "bot2"], tokens: ["bot1": Self.t1, "bot2": Self.t2])
        let core = try start()
        defer { core.close() }
        try assertSameAsAStart(core, tokens: all)

        // bot2 removed, bot3 added, bot1's token replaced: one reload.
        try files(["bot1", "bot3"], tokens: ["bot1": Self.t1b, "bot3": Self.t3])
        XCTAssertEqual(try reload(core), .reloaded(try sha()))
        try assertSameAsAStart(core, tokens: all)
        XCTAssertFalse(core.member("room1", "bot2"))
        XCTAssertFalse(core.member("room1", "bot3"), "a new participant is in no room until it is invited")
        XCTAssertNil(core.whoHas(Self.t1), "the replaced token is refused at once")
        XCTAssertEqual(core.whoHas(Self.t1b), "bot1")
        XCTAssertTrue(core.member("room1", "sess1"), "a registered session is kept")

        // EDGE 17: bot2 added again is back in the rooms the data folder still lists it in — as after a restart.
        try files(["bot1", "bot2", "bot3"], tokens: ["bot1": Self.t1b, "bot2": Self.t2, "bot3": Self.t3])
        XCTAssertEqual(try reload(core), .reloaded(try sha()))
        try assertSameAsAStart(core, tokens: all)
        XCTAssertTrue(core.member("room1", "bot2"), "a name removed and added again is back in its rooms")
    }

    func testAReloadAfterARoomChangeStillEqualsARestart() throws {
        try files(["bot1", "bot2"], tokens: ["bot1": Self.t1, "bot2": Self.t2])
        let core = try start()
        defer { core.close() }
        var line = ChatLine()
        line.msgID = chatNewID()
        line.room = "room1"
        line.content = "/room room2 @bot1 @bot2"
        XCTAssertNotEqual(core.post(line, sender: "ada").state, "refused")
        XCTAssertTrue(core.member("room2", "bot2"))
        try files(["bot1"], tokens: ["bot1": Self.t1])
        XCTAssertEqual(try reload(core), .reloaded(try sha()))
        try assertSameAsAStart(core, tokens: [Self.t1, Self.t2])
    }

    // MARK: what a removal cuts

    func testARemovedTokenIsRefusedAtOnceAndItsWaitingReceiveEnds() async throws {
        try files(["bot1", "bot2"], tokens: ["bot1": Self.t1, "bot2": Self.t2])
        let core = try start()
        defer { core.close() }
        let h = ChatPageHandler(core: core)
        func receive(_ t: String, wait: Int) -> ChatHTTPResponse {
            h.handle(ChatHTTPRequest(method: "GET", target: "/agent/receive?wait=\(wait)", headers: ["authorization": "Bearer " + t], body: [],
                                     remoteIP: "127.0.0.1"))
        }
        let poll = try XCTUnwrap(receive(Self.t2, wait: 20).poll, "nothing waits for bot2, so it waits")
        let started = Date()
        async let answer = poll.finish()
        try await Task.sleep(nanoseconds: 200_000_000)
        try files(["bot1"], tokens: ["bot1": Self.t1])
        XCTAssertEqual(try reload(core), .reloaded(try sha()))
        let a = await answer
        XCTAssertEqual(a.status, 401, "the waiting receive of a removed participant ends")
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "at once, not at the end of its wait")
        XCTAssertEqual(receive(Self.t2, wait: 0).status, 401, "its token is refused from then on")
        XCTAssertEqual(receive(Self.t1, wait: 0).status, 200, "the others are untouched")
    }

    func testANewParticipantWorksWithoutARestart() throws {
        try files(["bot1"], tokens: ["bot1": Self.t1])
        let core = try start()
        defer { core.close() }
        let h = ChatPageHandler(core: core)
        let req = ChatHTTPRequest(method: "GET", target: "/agent/receive?wait=0", headers: ["authorization": "Bearer " + Self.t3], body: [],
                                  remoteIP: "127.0.0.1")
        XCTAssertEqual(h.handle(req).status, 401)
        try files(["bot1", "bot3"], tokens: ["bot1": Self.t1, "bot3": Self.t3])
        XCTAssertEqual(try reload(core), .reloaded(try sha()))
        XCTAssertEqual(h.handle(req).status, 200)
    }

    func testALinePortConnectionOfARemovedParticipantIsClosedAtItsNextLine() throws {
        try files(["bot1", "bot2"], tokens: ["bot1": Self.t1, "bot2": Self.t2])
        let core = try start()
        defer { core.close() }
        var c1 = try XCTUnwrap(ChatLineConnection(core: core, remoteIP: "127.0.0.1"))
        var c2 = try XCTUnwrap(ChatLineConnection(core: core, remoteIP: "127.0.0.1"))
        XCTAssertEqual(c1.handle(Array(#"{"type": "auth", "token": "\#(Self.t1)"}"#.utf8)), .nothing)
        XCTAssertEqual(c2.handle(Array(#"{"type": "auth", "token": "\#(Self.t2)"}"#.utf8)), .nothing)
        let ping = Array(#"{"type": "control", "action": "ping", "msg_id": "x"}"#.utf8)
        guard case .reply = c2.handle(ping) else { return XCTFail("bot2 is answered before") }
        try files(["bot1"], tokens: ["bot1": Self.t1])
        XCTAssertEqual(try reload(core), .reloaded(try sha()))
        guard case .close = c2.handle(ping) else { return XCTFail("bot2's connection is closed after its removal") }
        guard case .reply = c1.handle(ping) else { return XCTFail("bot1's connection goes on") }
    }

    // MARK: refusals

    func testARefusedReloadChangesNothing() throws {
        try files(["bot1"], tokens: ["bot1": Self.t1], port: 0)
        let core = try start()
        defer { core.close() }
        let before = core.membershipSnapshot()
        // A port changed with a participant: more than the participants.
        try files(["bot1", "bot3"], tokens: ["bot1": Self.t1, "bot3": Self.t3], port: 45_999)
        guard case .refused(let why) = try reload(core) else { return XCTFail("a port change is refused") }
        XCTAssertTrue(why.contains("more than the participants"), why)
        // Files that are not the ones the request names.
        try files(["bot1", "bot3"], tokens: ["bot1": Self.t1, "bot3": Self.t3])
        let stale = ChatReload.perform(core: core, configPath: configPath, overrides: .init(), hashesPath: hashesPath, want: String(repeating: "0", count: 64))
        guard case .refused = stale else { return XCTFail("a sha that is not the files' is refused") }
        // Not a request at all.
        guard case .refused = ChatReload.answer(Array("{}".utf8), core: core, configPath: configPath, overrides: .init(), hashesPath: hashesPath) else {
            return XCTFail("not a request")
        }
        let after = core.membershipSnapshot()
        XCTAssertEqual(before.participants, after.participants)
        XCTAssertEqual(before.hashes, after.hashes)
    }

    func testTheChannelAnswersOneLinePerRequest() throws {
        try files(["bot1"], tokens: ["bot1": Self.t1])
        let core = try start()
        defer { core.close() }
        var sv: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sv), 0)
        ChatReload.serve(fd: sv[1], core: core, configPath: configPath, overrides: .init(), hashesPath: hashesPath, log: .none)
        try files(["bot1", "bot3"], tokens: ["bot1": Self.t1, "bot3": Self.t3])
        let want = try sha()
        let req = Array(#"{"version":1,"reload":"\#(want)"}"#.utf8) + [0x0A]
        XCTAssertEqual(req.withUnsafeBytes { Darwin.write(sv[0], $0.baseAddress!, $0.count) }, req.count)
        var buf = [UInt8](repeating: 0, count: 512)
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(sv[0], SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let n = read(sv[0], &buf, buf.count)
        XCTAssertGreaterThan(n, 0)
        XCTAssertEqual(String(decoding: buf[0..<max(n, 0)], as: UTF8.self), #"{"reloaded":"\#(want)"}"# + "\n")
        XCTAssertEqual(core.whoHas(Self.t3), "bot3")
        close(sv[0])
    }
}
