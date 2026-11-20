import Darwin
import Foundation
import XCTest
@testable import DozableHost

/// The Agent / Bot record and its store: the round trip, fields this build does not know kept (top level and per bot) and a
/// higher version kept through a rewrite, names (reserved, the human, a retired bot's), the kind from the agent, modes, links
/// refused, the instructions' size. Scratch roots only.
final class BotRecordTests: XCTestCase {
    private var root: URL!
    private var bots: BotStore!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: "/tmp/doz-bot-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        bots = BotStore(store: DozableStore(root: root))
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func record(_ name: String = "mira", isolation: String = "fenced") -> BotRecord {
        let at = Date(timeIntervalSince1970: 1_800_000_000.25)
        return BotRecord(name: name, createdAt: at, agent: "claude-code", model: "opus", account: "mac", avatar: "🦊",
                         isolation: BotIsolation(default: isolation), kind: BotKinds.kind(forAgent: "claude-code"), deliver: "inbox",
                         skills: ["chat-manager"], instructions: BotInstructions(sha256: "ab", bytes: 2, updatedAt: at),
                         token: BotTokenState(keeper: "dozable", fingerprint: "0123456789ab", at: at))
    }

    func testRoundTrip() throws {
        XCTAssertEqual(try bots.read(), BotsFile(), "no file: no bots")
        let f = BotsFile(bots: [record(), record("far", isolation: "elsewhere")])
        try bots.write(f)
        let back = try bots.read()
        XCTAssertEqual(back, f)
        XCTAssertEqual(back.bot("mira")?.kind, "claude-session")
        XCTAssertTrue(back.bot("mira")!.holdsToken)
        XCTAssertFalse(back.bot("far")!.isolation.held)
        XCTAssertEqual(back.active.map(\.name), ["mira", "far"])
    }

    /// Fields a newer doz wrote survive this build's rewrite — top level and in each bot (and its isolation) — and a higher
    /// version is kept, never lowered.
    func testUnknownFieldsAndAHigherVersionSurviveARewrite() throws {
        try bots.write(BotsFile(bots: [record()]))
        var obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: bots.file))) as? [String: Any])
        obj["version"] = 4
        obj["future"] = ["deep": [1, 2]]
        var list = try XCTUnwrap(obj["bots"] as? [[String: Any]])
        list[0]["ceilingAnswers"] = ["sudo": "never"]
        var iso = try XCTUnwrap(list[0]["isolation"] as? [String: Any])
        iso["later"] = true
        list[0]["isolation"] = iso
        obj["bots"] = list
        try JSONSerialization.data(withJSONObject: obj).write(to: URL(fileURLWithPath: bots.file))
        var f = try bots.read()
        XCTAssertEqual(f.version, 4)
        f.bots[0].model = "sonnet"          // a `set`
        try bots.write(f)
        let again = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: bots.file))) as? [String: Any])
        XCTAssertEqual(again["version"] as? Int, 4)
        XCTAssertEqual((again["future"] as? [String: Any])?["deep"] as? [Int], [1, 2])
        let b = try XCTUnwrap((again["bots"] as? [[String: Any]])?.first)
        XCTAssertEqual((b["ceilingAnswers"] as? [String: String])?["sudo"], "never")
        XCTAssertEqual((b["isolation"] as? [String: Any])?["later"] as? Bool, true)
        XCTAssertEqual(b["model"] as? String, "sonnet")
    }

    func testNames() {
        var f = BotsFile(bots: [record()])
        XCTAssertNil(BotName.refusal("ada-2", human: "ada", file: f))
        XCTAssertEqual(BotName.refusal("chat", human: "ada", file: f)?.code, .invalid, "the server's own name")
        XCTAssertEqual(BotName.refusal("ada", human: "ada", file: f)?.code, .invalid, "the human")
        for bad in ["", "Mira", "-x", "1a", "a_b", "a.b", "a/b", String(repeating: "a", count: 41)] {
            XCTAssertNotNil(BotName.refusal(bad, human: nil, file: f), bad)
        }
        XCTAssertEqual(BotName.refusal("mira", human: nil, file: f)?.code, .exists)
        f.bots[0].retiredAt = Date(timeIntervalSince1970: 1_800_000_000)
        let e = BotName.refusal("mira", human: nil, file: f)
        XCTAssertEqual(e?.code, .exists)
        XCTAssertTrue(e?.message.hasPrefix("mira was a bot, retired 2027-") == true, e?.message ?? "")
        XCTAssertTrue(e?.message.contains("the name stays with its old messages") == true)
    }

    func testKinds() {
        XCTAssertEqual(BotKinds.kind(forAgent: "claude-code"), "claude-session")
        XCTAssertEqual(BotKinds.kind(forAgent: "anthropic/claude-code@2"), "claude-session")
        XCTAssertEqual(BotKinds.kind(forAgent: "codex"), "agent")
        XCTAssertEqual(BotKinds.kind(forAgent: "opencode@1"), "agent")
    }

    func testFields() {
        XCTAssertNoThrow(try BotFields.checkSkills(["chat-manager", "web_search"]))
        XCTAssertThrowsError(try BotFields.checkSkills(["Bad"]))
        XCTAssertThrowsError(try BotFields.checkSkills(["a", "a"]))
        XCTAssertThrowsError(try BotFields.checkModel("has space"))
        XCTAssertThrowsError(try BotFields.checkAvatar("a\nb"))
        XCTAssertThrowsError(try BotFields.checkIsolation("cloud"))
        for i in BotIsolation.choices { XCTAssertNoThrow(try BotFields.checkIsolation(i)) }
        XCTAssertEqual(BotIsolation.words("unfenced"), "unfenced (acts as you)")
    }

    /// 0700 folders, 0600 files; the instructions copied with an empty notes.md beside them.
    func testModesAndInstructions() throws {
        try bots.write(BotsFile(bots: [record()]))
        let i = try bots.writeInstructions("mira", Data("Be brief.\n".utf8))
        XCTAssertEqual(i.bytes, 10)
        XCTAssertEqual(i.sha256, BotFields.sha256(Data("Be brief.\n".utf8)))
        XCTAssertEqual(bots.readInstructions("mira"), "Be brief.\n")
        func mode(_ p: String) -> mode_t { var st = stat(); lstat(p, &st); return st.st_mode & 0o777 }
        XCTAssertEqual(mode(bots.root), 0o700)
        XCTAssertEqual(mode(bots.folder("mira")), 0o700)
        XCTAssertEqual(mode(bots.file), 0o600)
        XCTAssertEqual(mode(bots.folder("mira") + "/instructions.md"), 0o600)
        XCTAssertEqual(mode(bots.folder("mira") + "/notes.md"), 0o600)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: bots.folder("mira") + "/notes.md")).count, 0)
    }

    func testOversizeOrNonUTF8InstructionsAreRefused() {
        XCTAssertThrowsError(try bots.writeInstructions("mira", Data(count: BotStore.maximumInstructionsBytes + 1)))
        XCTAssertThrowsError(try bots.writeInstructions("mira", Data([0xFF, 0xFE, 0x00])))
        XCTAssertFalse(FileManager.default.fileExists(atPath: bots.folder("mira")), "nothing made")
    }

    /// A link where `bots/` or its file is: refused, never followed.
    func testLinksAreRefused() throws {
        let elsewhere = root.appendingPathComponent("elsewhere").path
        try FileManager.default.createDirectory(atPath: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: bots.root, withDestinationPath: elsewhere)
        XCTAssertThrowsError(try bots.write(BotsFile(bots: [record()])))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: elsewhere), [])
        try FileManager.default.removeItem(atPath: bots.root)
        try bots.write(BotsFile(bots: [record()]))
        try FileManager.default.removeItem(atPath: bots.file)
        try FileManager.default.createSymbolicLink(atPath: bots.file, withDestinationPath: elsewhere + "/b.json")
        XCTAssertThrowsError(try bots.read())
    }

    /// A workspace's agent may name the bot it is; an older record (no `bot`) reads as nil.
    func testWorkspaceAgentNamesItsBot() throws {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let a = WorkspaceAgent(name: "mira", place: .macSession("mira"), startedAt: at, bot: "mira")
        let back = try HostWire.decoder.decode(WorkspaceAgent.self, from: try HostWire.encoder.encode(a))
        XCTAssertEqual(back.bot, "mira")
        let old = WorkspaceAgent(name: "wsa", place: .sandbox("wsa"), startedAt: at)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: try HostWire.encoder.encode(old)) as? [String: Any])
        XCTAssertNil(obj["bot"], "no bot: no field")
        XCTAssertNil(try HostWire.decoder.decode(WorkspaceAgent.self, from: try HostWire.encoder.encode(old)).bot)
    }

    /// The bot's ceiling (`ceilingAnswers`, additive): a record from before has none and is written back without the key; one
    /// set survives a rewrite, and only ask and never cap (`GrantCeiling.caps`).
    func testTheCeilingAnswers() throws {
        var r = record()
        try bots.write(BotsFile(bots: [r]))
        let before = try Data(contentsOf: URL(fileURLWithPath: bots.file))
        XCTAssertNil(try bots.read().bot("mira")?.ceilingAnswers)
        try bots.write(try bots.read())
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: bots.file)), before, "written back byte for byte")
        r.ceilingAnswers = ["sudo": "never", "spend": "ask"]
        try bots.write(BotsFile(bots: [r]))
        let back = try XCTUnwrap(try bots.read().bot("mira"))
        XCTAssertEqual(back.ceilingAnswers, ["sudo": "never", "spend": "ask"])
        XCTAssertEqual(GrantCeiling.caps(back.ceilingAnswers), ["sudo": .never, "spend": .ask])
    }
}
