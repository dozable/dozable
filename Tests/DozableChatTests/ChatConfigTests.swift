import DozableChat
import Foundation
import XCTest

/// The chat server's one input, read strictly; its secrets file; and the JSON it writes, byte for byte.
final class ChatConfigTests: XCTestCase {
    /// The start contract's config, with neutral names.
    static func contract(_ extra: String = "") -> String {
        """
        {"line_port": 18765, "http_port": 18780, "data_dir": "/tmp/chat-data", "default_room": "room1",
         "participants": [{"name": "ada", "kind": "human", "deliver": "web"},
                          {"name": "bot1", "kind": "grok-bot", "deliver": "webhook", "webhook": "bot1"},
                          {"name": "bot2", "kind": "claude-session", "deliver": "inbox-socket", "session": "bot2"}],
         "rooms": {"room1": ["ada", "bot1", "bot2"], "room2": ["ada", "bot1"]},
         "peer_name": "", "agent_run_cap": 0, "require_tokens": false, "require_tokens_from": [], "allow": [],
         "test_owned_addresses": ["127.0.0.1"], "secrets_file_only": true, "token_service": "unused"\(extra)}
        """
    }

    func parse(_ s: String) throws -> ChatConfig { try ChatConfig.parse(Data(s.utf8)) }

    func refused(_ s: String, containing: String, file: StaticString = #filePath, line: UInt = #line) {
        do {
            var c = try parse(s)
            if c.dataDir.isEmpty { c.dataDir = "/tmp/x" }
            try c.check()
            XCTFail("accepted: \(s)", file: file, line: line)
        } catch {
            XCTAssertTrue("\(error)".contains(containing), "\(error) does not say \(containing)", file: file, line: line)
            XCTAssertFalse("\(error)".contains("\n"), "a fault is one line", file: file, line: line)
        }
    }

    func testTheStartContractConfigIsRead() throws {
        let c = try parse(Self.contract())
        try c.check()
        XCTAssertEqual(c.linePort, 18765)
        XCTAssertEqual(c.httpPort, 18780)
        XCTAssertEqual(c.dataDir, "/tmp/chat-data")
        XCTAssertEqual(c.defaultRoom, "room1")
        XCTAssertEqual(c.participants.map(\.name), ["ada", "bot1", "bot2"])
        XCTAssertEqual(c.participants[1].webhook, "bot1")
        XCTAssertEqual(c.participants[2].session, "bot2")
        XCTAssertEqual(c.rooms["room1"], ["ada", "bot1", "bot2"], "members keep the file's order")
        XCTAssertEqual(c.testOwnedAddresses, ["127.0.0.1"])
        XCTAssertTrue(c.secretsFileOnly)
        XCTAssertEqual(c.tokenService, "unused")
        XCTAssertTrue(c.agentAddresses.isEmpty)
    }

    func testTheServersOwnNameIsReservedAndNoDeliverValueIsPolling() throws {
        refused(#"{"participants": [{"name": "chat", "kind": "grok-bot"}], "data_dir": "/x", "secrets_file_only": true}"#,
                containing: #"config participants: "chat" is a reserved name"#)
        var c = try parse(#"{"participants": [{"name": "ada", "kind": "human"}, {"name": "bot1", "kind": "grok-bot"}, {"name": "switchboard", "kind": "grok-bot", "deliver": "webhook"}], "data_dir": "/x", "secrets_file_only": true}"#)
        try c.check()
        XCTAssertEqual(c.participants.map(\.route), ["", "poll", "webhook"], "no deliver value: the human has none, anyone else polls")
        c.participants[1].deliver = "pigeon"
        XCTAssertThrowsError(try c.check())
        XCTAssertEqual(ChatProtocol.systemName, "chat")
    }

    func testStrictRefusals() {
        refused(Self.contract(#", "mystery": 1"#), containing: "unknown key \"mystery\"")
        refused(#"{"line_port": "8765", "data_dir": "/x", "secrets_file_only": true}"#, containing: "config line_port")
        refused(#"{"line_port": 1.5, "data_dir": "/x", "secrets_file_only": true}"#, containing: "config line_port")
        refused(#"{"line_port": 70000, "data_dir": "/x", "secrets_file_only": true}"#, containing: "is not a port")
        refused(#"{"require_tokens": "yes", "data_dir": "/x", "secrets_file_only": true}"#, containing: "require_tokens")
        refused(#"{"test_owned_addresses": ["10.0.0.1"], "data_dir": "/x", "secrets_file_only": true}"#, containing: "not a loopback address")
        refused(#"{"require_tokens_from": ["nonsense"], "data_dir": "/x", "secrets_file_only": true}"#, containing: "not an IP address or CIDR range")
        refused(#"{"agent_addresses": ["127.0.0.1/40"], "data_dir": "/x", "secrets_file_only": true}"#, containing: "agent_addresses")
        refused(#"{"peer_name": "chat", "data_dir": "/x", "secrets_file_only": true}"#, containing: "not a Claude Code peer")
        refused(#"{"https_port": 8443, "data_dir": "/x", "secrets_file_only": true}"#, containing: "no HTTPS listener")
        refused(#"{"data_dir": "/x"}"#, containing: "secrets_file_only")
        refused(#"{"rooms": {"Room One": ["ada"]}, "data_dir": "/x", "secrets_file_only": true}"#, containing: "not a room name")
        refused(#"{"participants": [{"name": "ada", "kind": "human", "deliver": "web", "colour": "red"}], "data_dir": "/x", "secrets_file_only": true}"#,
                containing: "unknown key \"colour\"")
        refused(#"{"participants": [{"name": "ada", "kind": "human", "deliver": "pigeon"}], "data_dir": "/x", "secrets_file_only": true}"#,
                containing: "delivery")
        refused(#"{"participants": [{"name": "ada", "kind": "human", "deliver": "web"}, {"name": "ada", "kind": "human", "deliver": "web"}], "data_dir": "/x", "secrets_file_only": true}"#,
                containing: "listed twice")
        refused("{not json", containing: "not valid JSON")
        refused("[]", containing: "not a JSON object")
    }

    func testAgentAddressesAreReadAndChecked() throws {
        let c = try parse(Self.contract(#", "agent_addresses": ["127.0.0.1/8", "::1", "::ffff:10.0.0.0/104"]"#))
        try c.check()
        XCTAssertEqual(c.agentAddresses, ["127.0.0.1/8", "::1", "::ffff:10.0.0.0/104"])
        let a = c.access
        XCTAssertTrue(a.isAgentAddress("127.0.0.1"))
        XCTAssertTrue(a.isAgentAddress("127.9.9.9"))
        XCTAssertTrue(a.isAgentAddress("::1"))
        XCTAssertTrue(a.isAgentAddress("10.20.30.40"), "a 4-in-6 prefix means its IPv4 range")
        XCTAssertFalse(a.isAgentAddress("11.0.0.1"))
        XCTAssertTrue(a.isAgentAddress("not an address"), "an address that cannot be read is treated as an agent's")
    }

    func testFlagsBeatTheFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("chat-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("config.json").path
        try Data(Self.contract().utf8).write(to: URL(fileURLWithPath: path))
        let c = try ChatConfig.resolve(path: path, .init(dataDir: "/tmp/other/../flagged", bind: "127.0.0.1", linePort: 0, pagePort: 0))
        XCTAssertEqual(c.dataDir, "/tmp/flagged")
        XCTAssertEqual(c.bind, "127.0.0.1")
        XCTAssertEqual(c.linePort, 0)
        XCTAssertEqual(c.httpPort, 0)
        XCTAssertThrowsError(try ChatConfig.resolve(path: dir.appendingPathComponent("missing.json").path, .init()))
    }

    // MARK: the secrets file

    func testSecretsVersionOneTokensAreHashed() throws {
        let s = try ChatSecrets.parse(Data(#"{"version": 1, "tokens": {"ada": "0123456789abcdef0123456789abcdef", "bot1": "fedcba9876543210fedcba9876543210"}, "webhooks": {"bot1": {"url": "http://127.0.0.1:9/hook/bot1", "header": "Bearer k"}}}"#.utf8))
        XCTAssertEqual(s.tokenHashes["ada"], ChatSecrets.hash("0123456789abcdef0123456789abcdef"))
        XCTAssertFalse(s.tokenHashes.values.contains("0123456789abcdef0123456789abcdef"), "a token is kept only as its hash")
        XCTAssertEqual(s.whoHas("fedcba9876543210fedcba9876543210", among: ["ada", "bot1"]), "bot1")
        XCTAssertNil(s.whoHas("fedcba9876543210fedcba9876543210", among: ["ada"]), "only the names asked about")
        XCTAssertNil(s.whoHas(String(repeating: "0", count: 32), among: ["ada", "bot1"]))
        XCTAssertNil(s.whoHas("short", among: ["ada", "bot1"]), "fewer than 16 characters is never a token")
        XCTAssertEqual(s.webhooks["bot1"], ChatWebhook(url: "http://127.0.0.1:9/hook/bot1", header: "Bearer k"))
        XCTAssertThrowsError(try ChatSecrets.parse(Data(#"{"version": 2, "tokens": {}}"#.utf8)))
        XCTAssertThrowsError(try ChatSecrets.parse(Data(#"{"version": 1, "tokens": {"ada": 7}}"#.utf8)))
        XCTAssertThrowsError(try ChatSecrets.parse(Data("[]".utf8)))
    }

    func testASecretsFileOthersCanReadIsRefusedWithoutItsValues() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("chat-secrets-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("secrets.json").path
        let secret = "0123456789abcdef0123456789abcdef"
        try Data(#"{"version": 1, "tokens": {"ada": "\#(secret)"}}"#.utf8).write(to: URL(fileURLWithPath: path))
        chmod(path, 0o644)
        XCTAssertThrowsError(try ChatSecrets.load(path: path)) { e in
            XCTAssertTrue("\(e)".contains("can be read by other users"))
            XCTAssertFalse("\(e)".contains(secret))
        }
        chmod(path, 0o600)
        XCTAssertNotNil(try ChatSecrets.load(path: path).tokenHashes["ada"])
        XCTAssertThrowsError(try ChatSecrets.load(path: dir.appendingPathComponent("none.json").path))
    }

    // MARK: the JSON the server writes

    func testJSONIsWrittenAsTheReferenceWritesIt() {
        XCTAssertEqual(ChatJSON.encodeString(.string("a <b> & c / d")), #""a \u003cb\u003e \u0026 c / d""#)
        XCTAssertEqual(ChatJSON.encodeString(.string("\u{1}\u{8}\u{c}\n\r\t\"\\\u{2028}\u{2029}")), #""\u0001\b\f\n\r\t\"\\\u2028\u2029""#)
        XCTAssertEqual(ChatJSON.encodeString(.string("👍 é")), "\"👍 é\"", "non-ASCII is written as UTF-8")
        XCTAssertEqual(ChatJSON.encodeString(.map(["b": .int(1), "a": .bool(true), "c": .null])), #"{"a":true,"b":1,"c":null}"#)
        XCTAssertEqual(ChatJSON.encodeString(.object([JMember("z", .int(1)), JMember("a", .int(2))])), #"{"z":1,"a":2}"#, "a struct keeps its order")
        XCTAssertEqual(String(decoding: ChatJSON.encodeIndented(.map(["room1": .strings(["ada", "bot1"]), "room2": .strings([])]), indent: " "), as: UTF8.self),
                       "{\n \"room1\": [\n  \"ada\",\n  \"bot1\"\n ],\n \"room2\": []\n}")
        for (d, s) in [(5.0, "5"), (0.5, "0.5"), (1763300000.123, "1763300000.123"), (-2.25, "-2.25"), (1e20, "100000000000000000000"),
                       (1e21, "1e+21"), (1e-7, "1e-7"), (0.000001, "0.000001"), (123456789012.5, "123456789012.5"), (0.0, "0")] {
            XCTAssertEqual(ChatJSON.goFloat(d), s, "\(d)")
        }
    }

    func testJSONIsReadAsTheReferenceReadsIt() throws {
        let v = try ChatJSON.parse(Array(#"{"MSG_ID": "a", "msg_id": "b", "x": "😀é", "bad": "\ud800"}"#.utf8))
        XCTAssertEqual(v.field("msg_id"), .string("b"), "case-insensitive, the last one wins")
        XCTAssertEqual(v.field("x"), .string("😀é"))
        XCTAssertEqual(v.field("bad"), .string("\u{FFFD}"), "a lone surrogate becomes U+FFFD")
        XCTAssertThrowsError(try ChatJSON.parse(Array(#"{"a": 1} x"#.utf8)))
        XCTAssertEqual(try ChatJSON.parse(Array(#"{"a": 1} x"#.utf8), trailing: true).field("a"), .number("1"))
        XCTAssertThrowsError(try ChatJSON.parse(Array("{\"a\": \"line\nbreak\"}".utf8)), "a control character in a string")
        XCTAssertThrowsError(try ChatJSON.parse(Array("[01]".utf8)))
        XCTAssertThrowsError(try ChatLine.read(try ChatJSON.parse(Array(#"{"msgV": "1"}"#.utf8))), "a field of the wrong type")
        XCTAssertThrowsError(try ChatLine.read(try ChatJSON.parse(Array(#"{"msgV": 1.5}"#.utf8))))
        XCTAssertEqual(try ChatLine.read(try ChatJSON.parse(Array(#"{"msgV": 7, "message": {"content": "hi"}}"#.utf8))).content, "hi")
        XCTAssertEqual(try ChatLine.read(.null).type, "", "null is an empty line, as in Go")
    }

    func testTheProtocolVersionIsTenHexAndStable() {
        XCTAssertEqual(ChatProtocol.version.count, 10)
        XCTAssertTrue(ChatProtocol.version.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        let d = ChatProtocol.description(rooms: ["room1": ["ada"]], defaultRoom: "room1")
        guard case .object(let m) = d else { return XCTFail("not an object") }
        XCTAssertEqual(m.map(\.key), m.map(\.key).sorted(), "the keys are written in alphabetical order")
        XCTAssertEqual(d.field("version"), .string(ChatProtocol.version))
        let other = ChatProtocol.description(rooms: ["x": []], defaultRoom: "x")
        XCTAssertEqual(other.field("version"), d.field("version"), "rooms are not part of the version")
    }
}
