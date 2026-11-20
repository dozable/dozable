import CryptoKit
import Darwin
@testable import DozableChat
import Foundation
import XCTest

/// A value several threads share in a test.
final class ChatAskBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ v: T) { value = v }
    func with<R>(_ f: (inout T) -> R) -> R { lock.withLock { f(&value) } }
}

/// A core made as a start makes it, for the ask tests: ada the human; bot1 and bot3 poll; bot2 polls and has the role
/// decider; room1 and room2 hold everyone.
class ChatAskTestCase: XCTestCase {
    var dir = ""
    var dataDir: String { dir + "/data" }
    var cores: [ChatServerCore] = []

    override func setUpWithError() throws {
        dir = "/tmp/dzc-ask-\(getpid())-\(UUID().uuidString.prefix(6))"
        try FileManager.default.createDirectory(atPath: dataDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    override func tearDownWithError() throws {
        for c in cores { c.close() }
        try? FileManager.default.removeItem(atPath: dir)
    }

    static let everyone = #"["ada", "bot1", "bot2", "bot3"]"#

    func config(roles: Bool = true, extra: String = "", participants: String? = nil) -> String {
        let ps = participants ?? """
            [{"name": "ada", "kind": "human", "deliver": "web"}, {"name": "bot1", "kind": "agent"},
             {"name": "bot2", "kind": "agent"\(roles ? #", "roles": ["decider"]"# : "")}, {"name": "bot3", "kind": "agent"}]
            """
        return """
            {"line_port": 0, "http_port": 0, "data_dir": "\(dataDir)", "default_room": "room1", "participants": \(ps),
             "rooms": {"room1": \(Self.everyone), "room2": \(Self.everyone)}, "allow": ["127.0.0.1"], "require_tokens": true,
             "agent_addresses": ["127.0.0.0/8"], "secrets_file_only": true, "bind": "127.0.0.1"\(extra)}
            """
    }

    func core(roles: Bool = true, extra: String = "", participants: String? = nil, secrets: ChatSecrets = ChatSecrets(),
              sessionsDir: String? = nil, start: Bool = true) throws -> ChatServerCore {
        let c = try ChatConfig.resolve(data: Data(config(roles: roles, extra: extra, participants: participants).utf8), .init())
        let core = ChatServerCore(config: c, secrets: secrets, release: "1.2.3", sessionsDir: sessionsDir ?? dir + "/no-sessions")
        core.webhookBackoff = [0, 0.1, 0.2]
        core.webhookTimeout = 2
        core.load()
        if start { core.startAsks() }
        cores.append(core)
        return core
    }

    func line(_ text: String, room: String = "room1", ask: String? = nil) -> ChatLine { Self.makeLine(text, room: room, ask: ask) }

    static func makeLine(_ text: String, room: String = "room1", ask: String? = nil) -> ChatLine {
        var l = ChatLine()
        l.msgID = chatNewID(); l.content = text; l.room = room; l.msgV = 1; l.type = "user"; l.hasBody = true; l.verified = true
        if let ask { l.kind = "ask"; l.ask = try! ChatAskSpec.read(try! ChatJSON.parse(Array(ask.utf8))) }
        return l
    }

    /// Posts an ask; its msg_id and the receipt.
    @discardableResult
    func ask(_ core: ChatServerCore, _ who: String, _ spec: String, text: String = "Let bot1 read the shared folder?", room: String = "room1") -> (String, ChatReceipt) {
        let l = line(text, room: room, ask: spec)
        return (l.msgID, core.post(l, sender: who))
    }

    func askOK(_ core: ChatServerCore, _ who: String, _ spec: String, text: String = "Let bot1 read the shared folder?", room: String = "room1",
               file: StaticString = #filePath, line: UInt = #line) -> String {
        let (id, r) = ask(core, who, spec, text: text, room: room)
        XCTAssertEqual(r.state, "queued", r.detail, file: file, line: line)
        return id
    }

    func stored(_ core: ChatServerCore, _ id: String, room: String = "room1") -> ChatStored? {
        (try? core.messagePage(room: room, after: 0, before: 0, limit: 500, viewer: ""))?.messages.first { $0.msgID == id }
    }

    func askOf(_ core: ChatServerCore, _ id: String, room: String = "room1") -> ChatAsk? { stored(core, id, room: room)?.ask }

    /// The items a polling participant collects now.
    func receive(_ core: ChatServerCore, _ name: String) -> [JValue] {
        let r = core.receive(name, wait: "0", ack: false, redeliver: false)
        guard case .array(let a)? = (try? ChatJSON.parse(r.body))?.field("messages") else { return [] }
        return a
    }

    func waitFor(_ what: String, seconds: Double = 10, _ ok: () -> Bool) {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until { if ok() { return }; usleep(20_000) }
        XCTFail("never: \(what)")
    }

    static let one = #"{"options": [{"id": "allow-once", "label": "Allow once"}, {"id": "copy", "label": "Copy instead"}]}"#
}

// MARK: - The form

final class ChatAskSpecTests: ChatAskTestCase {
    func refusal(_ core: ChatServerCore, _ spec: String, text: String = "Q?", who: String = "bot1") -> String {
        let (_, r) = ask(core, who, spec, text: text)
        XCTAssertEqual(r.state, "refused", spec)
        return r.detail
    }

    func testEveryPostRefusalInTheReferencesWordsAndNothingIsStored() throws {
        let c = try core()
        let past = ChatTime.now().adding(seconds: -60).format()
        let far = ChatTime.now().adding(seconds: 8 * 24 * 3600).format()
        let cases: [(String, String, String)] = [
            (#"{"options":[{"id":"Allow Once"}]}"#, "Q?", #""Allow Once" is not an option id"#),
            (#"{"options":[{"id":"a"}],"deciders":["nobody"]}"#, "Q?", "nobody is not a member of room room1, so cannot decide"),
            (#"{"options":[{"id":"a"}],"deciders":["bot1"]}"#, "Q?", "the asker cannot be a decider of its own ask"),
            (#"{"options":[{"id":"a"}],"deciders":["bot3"]}"#, "Q?", "bot3 does not have the decider role"),
            (#"{"options":[{"id":"a"}],"expires_at":"\#(past)"}"#, "Q?", "expires_at is not in the future"),
            (#"{"options":[{"id":"a"}],"expires_at":"\#(far)"}"#, "Q?", "expires_at is at most 7 days ahead"),
            (#"{"options":[{"id":"a"}],"expires_at":"tomorrow"}"#, "Q?", "expires_at must be a time in RFC 3339"),
            (#"{"options":[{"id":"a"}],"on_expiry":"a"}"#, "Q?", "on_expiry can only be decline for now"),
            (#"{}"#, "Q?", "an ask needs options (1 to 8) or free_text, or both; or questions"),
            (#"{"options":[{"id":"a"}],"questions":[{"options":[{"id":"b"}]}]}"#, "Q?", "give questions, or the older options and free_text, not both"),
            (#"{"questions":[{"question":"a"},{"question":"b"},{"question":"c"},{"question":"d"},{"question":"e"},{"question":"f"}]}"#, "Q?", "an ask has at most 5 questions"),
            (#"{"questions":[{"options":[{"id":"a"}]},{"options":[{"id":"b"}]}]}"#, "Q?", "question q1 needs its text"),
            (#"{"questions":[{"id":"x","question":"a"},{"id":"x","question":"b"}]}"#, "Q?", "the question id x is given twice"),
            (#"{"questions":[{"optional":true}]}"#, "Q?", "an ask of one question cannot make it optional"),
            (#"{"questions":[{"options":[{"id":"decline"}]}]}"#, "Q?", "decline cannot be an option id"),
            (#"{"questions":[{"options":[{"id":"a"},{"id":"a"}]}]}"#, "Q?", "the option id a is given twice"),
            (#"{"questions":[{"options":[{"id":"a"}],"recommended":"b"}]}"#, "Q?", #"recommended "b" is not an option of question q1"#),
            (#"{"questions":[{"multi":true}]}"#, "Q?", "question q1 is multi, so it needs options"),
            (#"{"questions":[{"options":[{"id":"a"},{"id":"b"}],"multi":true,"min":3}]}"#, "Q?", "question q1: min and max must keep 1 <= min <= max <= 2"),
            (#"{"questions":[{"options":[{"id":"a"}],"max":2}]}"#, "Q?", "question q1: min and max are for a question with multi"),
            (#"{"questions":[{"free_text":false}]}"#, "Q?", "question q1 needs options or free_text"),
            (#"{"questions":[{"header":"seventeen chars!!"}]}"#, "Q?", "a question's header is at most 16 characters"),
            (#"{"options":[{"id":"a"}],"about":[1]}"#, "Q?", "about must be a JSON object"),
            (#"{"options":[{"id":"a"}],"reason":"\#(String(repeating: "r", count: 1001))"}"#, "Q?", "reason is at most 1000 characters"),
            (#"{"options":[{"id":"a"}]}"#, "/rooms", "an ask's question cannot be a command"),
        ]
        for (spec, text, want) in cases {
            let d = refusal(c, spec, text: text)
            XCTAssertTrue(d.hasPrefix(want), "\(spec): \(d) — wanted \(want)")
        }
        var dm = line("Q?", ask: Self.one)
        dm.isPrivate = true; dm.to = ["ada"]
        XCTAssertEqual(c.post(dm, sender: "bot1").detail, "an ask cannot be a direct message")
        var bare = line("Q?")
        bare.kind = "ask"
        XCTAssertEqual(c.post(bare, sender: "bot1").detail, #"an ask needs an ask object: {"questions":[{"options":[{"id":"yes","label":"Yes"}]}]}"#)
        XCTAssertTrue(try c.messagePage(room: "room1", after: 0, before: 0, limit: 500, viewer: "").messages.isEmpty, "nothing was stored")
    }

    func testTheShapeIsNormalisedAndTheOldFormIsOneQuestion() throws {
        let c = try core()
        let id = askOK(c, "bot1", #"{"options":[{"id":"allow-once","label":" Allow once "},{"id":"decline","label":"Decline"}],"reason":" it needs it ","about":{"path":"~/x"}}"#)
        let m = try XCTUnwrap(stored(c, id))
        let a = try XCTUnwrap(m.ask)
        XCTAssertEqual(m.kind, "ask")
        XCTAssertEqual(a.deciders, ["ada"], "the room's humans by default")
        XCTAssertEqual(m.to, ["ada"], "the deciders are addressed")
        XCTAssertEqual(a.questions.count, 1)
        XCTAssertEqual(a.questions[0].id, "q1")
        XCTAssertEqual(a.questions[0].options, [ChatAskOption(id: "allow-once", label: "Allow once")], "decline is ask-level: dropped")
        XCTAssertFalse(a.questions[0].freeText, "the old form's default is no free text")
        XCTAssertEqual(a.questions[0].min, 1); XCTAssertEqual(a.questions[0].max, 1)
        XCTAssertEqual(a.reason, "it needs it")
        XCTAssertEqual(a.about, #"{"path":"~/x"}"#)
        XCTAssertEqual(a.onExpiry, "decline")
        let exp = try XCTUnwrap(ChatTime.parse(a.expiresAt))
        XCTAssertEqual(exp.seconds - chatNow(), 86400, accuracy: 5, "24 hours by default")
        XCTAssertEqual(a.number, 1)
        XCTAssertEqual(a.digest, ChatAskForm.digest(a))
        // the new form: free text by default, multi bounds
        let id2 = askOK(c, "bot3", #"{"questions":[{"options":[{"id":"web"},{"id":"ios"},{"id":"mac"}],"multi":true,"max":2}]}"#)
        let q = try XCTUnwrap(askOf(c, id2)?.questions.first)
        XCTAssertEqual([q.min, q.max], [1, 2]); XCTAssertTrue(q.freeText); XCTAssertEqual(q.options[0].label, "web", "an empty label is the id")
    }

    func testTheDigestIsTheReferencesArrayWithNoHTMLEscaping() {
        var a = ChatAsk()
        a.question = "Ship <it> & go?"; a.reason = ""
        var q = ChatAskQuestion()
        q.id = "q1"; q.question = "Ship <it> & go?"; q.options = [ChatAskOption(id: "yes", label: "Yes", description: "now")]
        q.min = 1; q.max = 1; q.freeText = false
        a.questions = [q]
        a.deciders = ["bot2", "ada"]
        a.about = #"{"a":1}"#
        a.expiresAt = "2026-11-19T17:00:00Z"; a.onExpiry = "decline"
        let want = #"["ask-v3","Ship <it> & go?","",[["q1","","Ship <it> & go?",[["yes","Yes","now"]],false,1,1,false,"",false]],["ada","bot2"],{"a":1},"2026-11-19T17:00:00Z","decline"]"#
        let hex = SHA256.hash(data: Data(want.utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(ChatAskForm.digest(a), hex)
    }

    func testAboutIsCanonical() throws {
        XCTAssertEqual(try ChatAsk.canonical(try ChatJSON.parse(Array(#"{"b": 1.50, "a": "<x>", "c": {"z": 1e3, "y": [true, null]}, "b": 2}"#.utf8))),
                       #"{"a":"<x>","b":2,"c":{"y":[true,null],"z":1000}}"#)
    }

    func testAnAskStoredByTheOlderFormReadsInTheNewShape() throws {
        let st = try ChatRoomStore(path: dir + "/old.db")
        defer { st.close() }
        var m = ChatStored(kind: "ask", msgID: chatNewID(), from: "bot1", content: "plain", at: chatNow())
        XCTAssertFalse(try st.insert(&m))
        let old = #"{"question":"Q?","options":[{"id":"yes","label":"Yes"},{"id":"decline","label":"Decline"}],"free_text":true,"deciders":["ada"],"digest":"d2","state":""}"#
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        p.arguments = [dir + "/old.db", "INSERT INTO asks(msg_id,ask,state,decision,asker) VALUES('\(m.msgID)','\(old)','decided','{\"by\":\"ada\",\"option\":\"decline\",\"text\":\"no\",\"at\":1,\"digest\":\"d2\",\"via\":\"page\"}','bot1');"]
        try p.run(); p.waitUntilExit()
        let a = try XCTUnwrap(st.askOf(m.msgID))
        XCTAssertEqual(a.questions.map(\.id), ["q1"])
        XCTAssertEqual(a.questions[0].options.map(\.id), ["yes"])
        XCTAssertTrue(a.questions[0].freeText)
        XCTAssertEqual(a.digest, "d2", "its stored digest is kept")
        XCTAssertEqual(a.decision?.declined, true)
        XCTAssertEqual(a.decision?.answers, [])
    }

    func testTimesAreGosRFC3339Nano() {
        XCTAssertEqual(ChatTime.parse("2026-11-19T17:00:00+01:00")?.format(), "2026-11-19T16:00:00Z")
        XCTAssertEqual(ChatTime.parse("2026-11-19T17:00:00.123456789Z")?.format(), "2026-11-19T17:00:00.123456789Z")
        XCTAssertEqual(ChatTime.parse("2026-11-19T17:00:00.500Z")?.format(), "2026-11-19T17:00:00.5Z")
        XCTAssertEqual(ChatTime.parse("2026-11-19T17:00:00.5Z")?.format(fraction: false), "2026-11-19T17:00:00Z")
        for bad in ["2026-02-30T00:00:00Z", "2026-11-19 17:00:00Z", "2026-11-19T17:00:00", "2026-11-19T24:00:00Z", "tomorrow", ""] {
            XCTAssertNil(ChatTime.parse(bad), bad)
        }
    }

    func testThePlainTextOfAnAskOfOneQuestion() {
        var a = ChatAsk()
        a.question = "Ship?"; a.reason = "release day"
        var q = ChatAskQuestion()
        q.id = "q1"; q.question = "Ship?"; q.options = [ChatAskOption(id: "yes", label: "Yes", description: "now"), ChatAskOption(id: "no", label: "No")]
        q.recommended = "yes"; q.freeText = true; q.min = 1; q.max = 1
        a.questions = [q]; a.deciders = ["ada"]; a.expiresAt = "2026-11-19T17:00:00Z"; a.onExpiry = "decline"
        XCTAssertEqual(ChatAskForm.text(id: "ID", asker: "bot1", a), """
            Ship?

            Why: release day

            Options (pick one):
            A. `yes` Yes (recommended)
               now
            B. `no` No
            Or answer in your own words.

            This is an ask from Bot1, for Ada to decide. To decide, send `/decide ID A` with the option's letter or id, with words of your own after it if you like, or `/decide ID <your own answer>`. To decline, send `/decide ID decline` with your reason after it if you like. It expires at 2026-11-19T17:00:00Z; then the answer is `decline`.
            """)
    }

    func testAnOldRoomFileGainsTheAsksTable() throws {
        let path = dir + "/older.db"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        p.arguments = [path, "CREATE TABLE messages(seq INTEGER PRIMARY KEY AUTOINCREMENT, msg_id TEXT NOT NULL UNIQUE, sender TEXT NOT NULL, recipients TEXT NOT NULL, re_msg_id TEXT NOT NULL DEFAULT '', content TEXT NOT NULL, at REAL NOT NULL);"]
        try p.run(); p.waitUntilExit()
        let st = try ChatRoomStore(path: path)
        defer { st.close() }
        XCTAssertEqual(try st.columns(of: "asks"), ["msg_id", "ask", "state", "expires", "decision", "closed_at", "asker", "about", "declined", "no_decider"])
    }
}
