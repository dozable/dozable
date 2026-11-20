import DozableChat
@testable import DozableHost
import DozableKit
import Foundation
import XCTest

/// A run's evidence archive: 0700 folders and 0600 files under `<store>/archives/` only; never written over; the manifest's
/// keys (the peer's space-test-h shape, in JSON); one changed byte caught by `verify`; a second sweep that finds anything
/// fails the archive and leaves no partial; a token planted in a message and a conversation redacted everywhere; and no
/// program is ever run to build it.
final class RunArchiveTests: XCTestCase {
    var root = ""
    var store: DozableStore { DozableStore(root: URL(fileURLWithPath: root + "/store")) }
    let token = ChatTokens.make()

    override func setUpWithError() throws {
        root = "/tmp/dzc-runarch-\(getpid())-\(UUID().uuidString.prefix(6))"
        try FileManager.default.createDirectory(atPath: root + "/store", withIntermediateDirectories: true)
        root = WorkspaceStore.resolved(root)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(atPath: root) }

    func evidence(planted: Bool = false) -> RunEvidence {
        var run = WorkspaceRun(id: "2026-11-20-1", startedAt: Date(timeIntervalSince1970: 1_795_000_000),
                               rooms: [WorkspaceRunRoom(room: "demo", id: "rm_00000000000000aa", fromSeq: 3, toSeq: 6)])
        run.endedAt = Date(timeIntervalSince1970: 1_795_000_600)
        var e = RunEvidence(workspace: "demo", run: run, endedAt: run.endedAt!, brief: Data("Make the launch video.\n".utf8))
        e.rooms = ["demo": "rm_00000000000000aa"]
        e.you = "ada"
        e.chat = ["demo": (4...6).map { s in .map(["seq": .int(Int64(s)), "from": .string(s == 4 ? "ada" : "bot1"),
                                                   "content": .string(planted && s == 5 ? "the token is \(token)" : "message \(s)")]) }]
        let line = #"{"type":"assistant","timestamp":"2026-11-20T00:00:30.000Z","cwd":"/w","message":{"id":"m1","model":"claude-x","usage":{"input_tokens":10,"cache_creation_input_tokens":5,"cache_read_input_tokens":100,"output_tokens":7},"content":"\#(planted ? token : "hi")"}}"#
        e.transcripts = [RunTranscript(agent: "bot1", name: "8f8f8f8f-1111-4222-8333-444455556666.jsonl", source: "conversation", data: Data((line + "\n").utf8))]
        e.screens = ["bot1": "$ done\n"]
        e.agents = [("bot1", "worker", nil), ("far", "adopted", "elsewhere: its conversations are on its own machine")]
        e.versions = ["doz": "test"]
        return e
    }

    var sweep: ExportSweep { ExportSweep(tokenHashes: ["bot1": ChatSecrets.hash(token)]) }

    func testItsPlaceModesManifestAndVerify() throws {
        let out = try RunArchive.write(evidence(), store: store, sweep: sweep, fetch: nil)
        XCTAssertEqual(out.path, "archives/demo/runs/2026-11-20-1")
        let dir = root + "/store/" + out.path
        for d in ["/store/archives", "/store/archives/demo", "/store/archives/demo/runs", "/store/" + out.path, "/store/" + out.path + "/chat"] {
            var st = stat()
            XCTAssertEqual(lstat(root + d, &st), 0, d)
            XCTAssertEqual(st.st_mode & 0o777, 0o700, d)
        }
        let m = out.manifest
        for f in m.files + [RunArchive.File(path: "manifest.json", sha256: "", bytes: 0)] {
            var st = stat()
            XCTAssertEqual(lstat(dir + "/" + f.path, &st), 0, f.path)
            XCTAssertEqual(st.st_mode & 0o777, 0o600, f.path)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir + ".partial"))
        // The keys the peer's archive has (in JSON), and the files.
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: dir + "/manifest.json"))) as! [String: Any]
        for k in ["run", "workspace", "window", "versions", "rooms", "labels", "notes", "sweep", "files"] { XCTAssertNotNil(json[k], k) }
        XCTAssertEqual(Set(m.files.map(\.path)), ["run.json", "brief.md", "chat/demo.jsonl", "transcripts/bot1/8f8f8f8f-1111-4222-8333-444455556666.jsonl",
                                                 "screens/bot1.txt", "usage.json", "timesheet.md"])
        XCTAssertNotNil(m.files.first { $0.path.hasPrefix("transcripts/") }?.sourceSHA256)
        XCTAssertTrue(m.notes.contains(RunArchive.gitNote), "commits are not collected: no git")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir + "/git.json"))
        XCTAssertEqual(m.messages, ["demo": 3])
        XCTAssertTrue(try String(contentsOfFile: dir + "/timesheet.md", encoding: .utf8).contains(Timesheet.commitsNotCollected))
        // Verified now; one changed byte is caught.
        XCTAssertTrue(RunArchive.verify(root: dir).ok)
        let chat = dir + "/chat/demo.jsonl"
        var b = try Data(contentsOf: URL(fileURLWithPath: chat))
        b[0] = b[0] == 0x7B ? 0x5B : 0x7B
        try b.write(to: URL(fileURLWithPath: chat))
        let v = RunArchive.verify(root: dir)
        XCTAssertFalse(v.ok)
        XCTAssertEqual(v.problems, ["chat/demo.jsonl changed since it was archived"])
        // Never written over.
        XCTAssertThrowsError(try RunArchive.write(evidence(), store: store, sweep: sweep, fetch: nil)) { e in
            XCTAssertEqual((e as? HostError)?.code, .exists)
        }
    }

    func testAPlantedTokenIsRedactedEverywhere() throws {
        let out = try RunArchive.write(evidence(planted: true), store: store, sweep: sweep, fetch: nil)
        XCTAssertGreaterThanOrEqual(out.manifest.sweep.redacted, 2)
        var all = ""
        let dir = root + "/store/" + out.path
        for f in out.manifest.files.map(\.path) + ["manifest.json"] { all += (try? String(contentsOfFile: dir + "/" + f, encoding: .utf8)) ?? "" }
        XCTAssertFalse(all.contains(token), "no token anywhere in the archive")
        XCTAssertTrue(all.contains("[a chat token of bot1, removed by doz]"))
    }

    func testANonZeroSecondSweepFailsTheArchiveAndRemovesThePartial() throws {
        // The first pass knows no hashes (it misses the token); the second does: the archive is not kept.
        XCTAssertThrowsError(try RunArchive.write(evidence(planted: true), store: store, sweep: ExportSweep(tokenHashes: [:]), verifySweep: sweep, fetch: nil)) { e in
            XCTAssertTrue((e as? HostError)?.message.contains("second sweep") == true, "\(e)")
        }
        let runs = root + "/store/archives/demo/runs"
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: runs), [], "no partial and no archive left")
    }

    func testOnlyUnderTheStoresArchivesAndNeverThroughALink() throws {
        try FileManager.default.createDirectory(atPath: root + "/elsewhere", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: root + "/store/archives", withDestinationPath: root + "/elsewhere")
        XCTAssertThrowsError(try RunArchive.write(evidence(), store: store, sweep: sweep, fetch: nil))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root + "/elsewhere"), [], "nothing written through the link")
        XCTAssertThrowsError(try RunArchiveFolder(store: store, workspace: "demo", run: "../x"), "a run id is checked before a path is built")
    }

    /// The no-git rule: the archive's writer, its readers and the run's code start no program.
    func testNoProgramIsStartedToBuildTheArchive() throws {
        let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for file in ["Sources/DozableHost/RunArchive.swift", "Sources/DozableHost/TranscriptUsage.swift", "Sources/DozableHost/Timesheet.swift",
                     "Sources/DozableHost/WorkspaceRuns.swift", "Sources/DozableHost/HostCore+Runs.swift", "Sources/DozableHost/SandboxTranscriptExport.swift"] {
            let src = try String(contentsOf: here.appendingPathComponent(file), encoding: .utf8)
            for word in ["Process(", "posix_spawn", "popen(", "system(", "NSTask", "/usr/bin/git", "\"git\""] {
                XCTAssertFalse(src.contains(word), "\(file) contains \(word)")
            }
        }
    }
}

/// A run's chat slice: exactly `fromSeq < seq <= toSeq`, more than 500 included; two runs on one day each their own.
final class ChatSliceTests: XCTestCase {
    final class Room: @unchecked Sendable {
        let n: Int
        var asked: [String] = []
        init(_ n: Int) { self.n = n }
        func fetch(_ target: String) throws -> (status: Int, body: Data) {
            asked.append(target)
            let q = URLComponents(string: "http://x" + target)!.queryItems ?? []
            let before = Int(q.first { $0.name == "before" }?.value ?? "0") ?? 0
            let limit = Int(q.first { $0.name == "limit" }?.value ?? "500") ?? 500
            let top = before > 0 ? min(before - 1, n) : n
            let lo = max(1, top - limit + 1)
            let page = top >= 1 ? (lo...top).map { JValue.map(["seq": .int(Int64($0)), "content": .string("m\($0)")]) } : []
            return (200, Data(ChatJSON.encode(.array(page))))
        }
    }

    func seqs(_ ms: [JValue]) -> [Int] { ms.compactMap { (try? $0.field("seq")?.goInt("seq")) ?? nil }.map { Int($0) } }

    func testExactlyTheRunsMessages() throws {
        let r = Room(2000)
        let a = try ChatExport.messages(room: "demo", fromSeq: 100, toSeq: 700, fetch: r.fetch)
        XCTAssertEqual(seqs(a), Array(101...700), "more than 500, no cap")
        XCTAssertEqual(r.asked.first, "/api/rooms/demo/messages?limit=500&before=701")
        // Two runs on one day (the same id twice is impossible; adjacent runs never overlap).
        let one = try ChatExport.messages(room: "demo", fromSeq: 700, toSeq: 703, fetch: r.fetch)
        let two = try ChatExport.messages(room: "demo", fromSeq: 703, toSeq: 705, fetch: r.fetch)
        XCTAssertEqual(seqs(one), [701, 702, 703])
        XCTAssertEqual(seqs(two), [704, 705])
        XCTAssertTrue(try ChatExport.messages(room: "demo", fromSeq: 9, toSeq: 9, fetch: r.fetch).isEmpty)
        XCTAssertEqual(seqs(try ChatExport.messages(room: "demo", fromSeq: 1995, toSeq: nil, fetch: r.fetch)), [1996, 1997, 1998, 1999, 2000])
    }
}

/// Usage from conversations: a message counted once whatever its lines; tokens by kind; active minutes under 5-minute gaps.
final class TranscriptUsageTests: XCTestCase {
    func line(_ t: String, id: String, model: String = "claude-x", input: Int = 1, out: Int = 2) -> String {
        #"{"type":"assistant","timestamp":"\#(t)","message":{"id":"\#(id)","model":"\#(model)","usage":{"input_tokens":\#(input),"cache_creation_input_tokens":3,"cache_read_input_tokens":4,"output_tokens":\#(out)}}}"#
    }

    func testCountsAndMinutes() {
        let lines = [
            #"{"type":"user","timestamp":"2026-11-20T00:00:00Z","message":{"role":"user","content":"do it"}}"#,
            line("2026-11-20T00:01:00Z", id: "a"), line("2026-11-20T00:01:00Z", id: "a"),   // one message, two lines
            #"{"type":"user","timestamp":"2026-11-20T00:02:00Z","message":{"role":"user","content":[{"type":"tool_result","content":"x"}]}}"#,
            line("2026-11-20T00:03:00Z", id: "b", model: "claude-y", input: 10, out: 20),
            line("2026-11-20T01:00:00Z", id: "c"),   // after an hour away: the gap is not active time
        ].joined(separator: "\n")
        let a = TranscriptUsage.agent("bot1", role: "worker", files: [Data(lines.utf8)])
        XCTAssertEqual(a.calls, 3)
        XCTAssertEqual(a.turns, 1, "a tool's result is not a turn")
        XCTAssertEqual(a.activeMinutes, 3)
        XCTAssertEqual(a.models.map(\.model), ["claude-x", "claude-y"])
        XCTAssertEqual(a.models[0].tokensNew, 2)
        XCTAssertEqual(a.models[1].tokensOut, 20)
        let r = TranscriptUsage.report(run: "r", window: RunWindow(from: Date(), to: Date()), agents: [a])
        XCTAssertEqual(r.totals.calls, 3)
        XCTAssertEqual(r.totals.tokensCacheRead, 12)
        let since = TranscriptUsage.agent("bot1", role: "worker", files: [Data(lines.utf8)], since: ISO8601DateFormatter().date(from: "2026-11-20T00:30:00Z"))
        XCTAssertEqual(since.calls, 1, "only the run's lines")
    }
}

/// The timesheet's sections (the peer's fixture) and its golden text; commits are not collected.
final class TimesheetTests: XCTestCase {
    func testGolden() {
        var a = TranscriptUsage.Agent(agent: "bot1", role: "worker", files: 1, turns: 2, activeMinutes: 7)
        var m = TranscriptUsage.Model(model: "claude-x")
        m.calls = 3; m.tokensNew = 10; m.tokensCacheWrite = 20; m.tokensCacheRead = 30; m.tokensOut = 40
        a.models = [m]
        let far = TranscriptUsage.Agent(agent: "far", role: "adopted", note: "elsewhere: its conversations are on its own machine")
        let w = RunWindow(from: Date(timeIntervalSince1970: 1_795_000_000), to: Date(timeIntervalSince1970: 1_795_003_900))
        let md = Timesheet.markdown(.init(workspace: "demo", run: "2026-11-20-1", window: w, usage: TranscriptUsage.report(run: "2026-11-20-1", window: w, agents: [a, far]),
                                          you: "ada", yourMessages: ["demo": 2], timeZone: TimeZone(identifier: "UTC")!))
        XCTAssertEqual(md, """
        # Timesheet: demo, run 2026-11-20-1

        - **Workspace:** demo
        - **Window:** 2026-11-18T11:06:40Z → 2026-11-18T12:11:40Z (1 h 05 min)
        - **Labels:** none

        ## Agents

        | Agent | Role | Active | Turns | Model | Calls | Tokens in (new / cache write / cache read) | Tokens out | Cost |
        |---|---|---|---|---|---|---|---|---|
        | bot1 | worker | 7 min | 2 | claude-x | 3 | 10 / 20 / 30 | 40 | — |
        | far | adopted | — | — | — | — | — | — | elsewhere: its conversations are on its own machine |

        **Totals:** 3 calls · 10 / 20 / 30 tokens in · 40 out · 7 min active

        ## ada's messages and decisions

        - #demo: 2 messages

        Asks: Dozable has no Ask export yet, so Asks are not listed.

        ## Commits

        Not collected: Dozable does not run git in a folder an agent writes.

        """)
    }
}

/// A sandbox's conversations: only conversation names modified since the run began; one member of a tar, never a link.
final class SandboxTranscriptExportTests: XCTestCase {
    func tar(_ name: String, _ body: Data, type: UInt8 = UInt8(ascii: "0")) -> Data {
        var h = [UInt8](repeating: 0, count: 512)
        for (i, b) in name.utf8.enumerated() { h[i] = b }
        for (i, b) in String(format: "%011o", body.count).utf8.enumerated() { h[124 + i] = b }
        h[156] = type
        var out = Data(h) + body
        out += Data(count: (512 - body.count % 512) % 512) + Data(count: 1024)
        return out
    }

    final class Guest: SandboxTranscriptSource, @unchecked Sendable {
        var running = true
        var list = ""
        var files: [String: Data] = [:]
        func list(sandbox: String, script: [String]) async throws -> String? { running ? list : nil }
        func tar(sandbox: String, argv: [String], maximum: Int) async throws -> Data {
            let n = files.keys.first { argv.joined(separator: " ").contains($0) }!
            return files[n]!
        }
    }

    func testOnlyTheRunsConversationsAndNeverALink() async {
        let a = "8f8f8f8f-1111-4222-8333-444455556666.jsonl", b = "9f8f8f8f-1111-4222-8333-444455556666.jsonl"
        let c = "af8f8f8f-1111-4222-8333-444455556666.jsonl"
        let since = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(SandboxTranscriptExport.parseList("\(a) 2000\n\(b) 500\nnotes.jsonl 3000\n\(c) 1500\n", since: since), [a, c])
        let g = Guest()
        XCTAssertEqual(SandboxTranscriptExport.parseLinks("\(a) link\nnotes.jsonl link\n\(b) 900\n"), [a])
        g.list = "\(a) 2000\n\(c) 2000\n\(b) link\n"
        let ok = Data(#"{"type":"user","cwd":"/workspace","message":{"content":"x"}}"#.utf8 + [0x0A])
        g.files = [a: tar(a, ok), c: tar(c, Data(), type: UInt8(ascii: "2"))]
        let got = await SandboxTranscriptExport.collect(g, sandbox: "wsa", agent: "bot1", since: since)
        XCTAssertEqual(got.files.map(\.name), [a])
        XCTAssertEqual(got.files.first?.data, ok)
        XCTAssertEqual(got.files.first?.source, "sandbox")
        XCTAssertTrue(got.notes.contains { $0.contains(c) && $0.contains("a link") }, "\(got.notes)")
        XCTAssertTrue(got.notes.contains { $0.contains(b) && $0.contains("a link — refused") }, "a listed link is refused and said")
        g.running = false
        let off = await SandboxTranscriptExport.collect(g, sandbox: "wsa", agent: "bot1", since: since)
        XCTAssertTrue(off.files.isEmpty)
        XCTAssertEqual(off.notes, ["bot1: wsa is not running: its conversations stay on its disk"])
        // Written somewhere else than the agent's folder: refused by the content rule.
        g.running = true
        g.list = "\(a) 2000\n"
        g.files = [a: tar(a, Data(#"{"cwd":"/elsewhere"}"#.utf8 + [0x0A]))]
        let other = await SandboxTranscriptExport.collect(g, sandbox: "wsa", agent: "bot1", since: since)
        XCTAssertTrue(other.files.isEmpty)
    }
}
