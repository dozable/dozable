import DozableChat
@testable import DozableHost
import Foundation
import XCTest

/// The run journal, journal/1: the pure rules (kinds and reserved names, a known kind's data, refs, the corrections matrix,
/// `superseded_by` computed, the sweep), the store (append order, fsync'd 0600 lines in a 0700 folder, `wseq` kept across a
/// new process and resumed with nothing missed or repeated, an unknown cursor refused), the daemon end to end (add, read,
/// no open run, a closed run, evidence copied and hashed or referenced in place, the limits, level-triggered wait), the
/// permissions (journal.read on by default in the agent's own workspace, journal.write:KIND, journal.supersede decided
/// once the entry is read) and the archive (the journal and its evidence frozen into it, read from there afterwards).
/// Scratch folders only.
final class RunJournalTests: XCTestCase {
    var dir = ""
    var storeRoot: String { dir + "/store" }
    var store: DozableStore { DozableStore(root: URL(fileURLWithPath: storeRoot)) }
    var project: String { dir + "/project" }

    override func setUpWithError() throws {
        dir = WorkspaceStore.resolved("/tmp") + "/doz-journal-\(getpid())-\(UUID().uuidString.prefix(6))"
        try FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        JournalFollower.stopping = false
    }

    override func tearDownWithError() throws {
        JournalFollower.stopping = false
        try? FileManager.default.removeItem(atPath: dir)
    }

    // MARK: pure

    func testKindsFollowThePatternAndTheReservedOnesAreDozablesOwn() {
        for k in ["note", "review", "acme.deploy", "a", "x_y-z.9"] { XCTAssertNoThrow(try JournalKinds.check(k), k) }
        for k in ["", "Note", "9x", "-x", "a b", String(repeating: "a", count: 65)] {
            XCTAssertThrowsError(try JournalKinds.check(k), k) { XCTAssertEqual(ExitCodes.exit(for: HostError.from($0)), 65) }
        }
        for k in ["gate", "hook", "dozable.gate", "dozable.anything"] {
            XCTAssertThrowsError(try JournalKinds.check(k), k) { XCTAssertEqual(ExitCodes.exit(for: HostError.from($0)), 65, "reserved: 65 from anyone") }
        }
        XCTAssertEqual(JournalKinds.known.count, 10, "the bare names are frozen")
        // No identity may be named owner.
        XCTAssertThrowsError(try WorkspaceName.checkNewAgent("owner")) { XCTAssertEqual(ExitCodes.exit(for: HostError.from($0)), 65) }
        XCTAssertNoThrow(try WorkspaceName.checkNewAgent("owner2"))
    }

    func testAKnownKindsDocumentedFieldsAreCheckedWhenPresent() {
        func ok(_ k: String, _ d: JSONValue?) { XCTAssertNoThrow(try JournalKinds.checkData(k, d), "\(k) \(String(describing: d))") }
        func no(_ k: String, _ d: JSONValue?) {
            XCTAssertThrowsError(try JournalKinds.checkData(k, d), "\(k) \(String(describing: d))") { XCTAssertEqual(ExitCodes.exit(for: HostError.from($0)), 65) }
        }
        ok("note", nil)
        ok("review", .object(["criterion": .string("c1"), "met": .string("partly"), "extra": .number(1)]))
        no("review", .object(["met": .string("maybe")]))
        no("review", .object(["criterion": .number(1)]))
        ok("finding", .object(["severity": .string("high")]))
        no("finding", .object(["severity": .string("urgent")]))
        no("criterion", nil)
        no("criterion", .object(["check": .string("make test")]))
        ok("criterion", .object(["id": .string("c1")]))
        no("outcome", .object([:]))
        ok("outcome", .object(["value": .string("accepted")]))
        ok("acme.deploy", .object(["anything": .array([])]))
        no("note", .array([]))
    }

    func testRefsTheirFormsAndWhatIsCheckedAgainstTheRun() throws {
        var run = WorkspaceRun(id: "2026-11-24-1", startedAt: Date())
        run.rooms = [WorkspaceRunRoom(room: "room1", fromSeq: 40)]
        XCTAssertEqual(try JournalRefs.check(["seq:2", "entry:2026-11-23-1#4", "msg:41"], nextSeq: 3, run: run, folders: []), [])
        for bad in ["seq:3", "seq:0", "msg:40", "nope:1", "entry:x", "plain", "commit:zz"] {
            XCTAssertThrowsError(try JournalRefs.check([bad], nextSeq: 3, run: run, folders: []), bad) {
                XCTAssertEqual(ExitCodes.exit(for: HostError.from($0)), 65, bad)
            }
        }
        XCTAssertThrowsError(try JournalRefs.check(Array(repeating: "url:x", count: 33), nextSeq: 1, run: run, folders: [])) {
            XCTAssertEqual(ExitCodes.exit(for: HostError.from($0)), 8, "past the refs limit: limited")
        }
        XCTAssertEqual(try JournalRefs.check(["url:https://example.com"], nextSeq: 1, run: run, folders: []).first?.verified, false, "never fetched")
        // A commit: its loose object looked for, without git.
        let sha = String(repeating: "ab", count: 20)
        try FileManager.default.createDirectory(atPath: project + "/.git/objects/ab", withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: project + "/.git/objects/ab/" + String(sha.dropFirst(2)), contents: Data([1]))
        XCTAssertEqual(try JournalRefs.check(["commit:\(sha)"], nextSeq: 1, run: run, folders: [project]).first?.present, true)
        XCTAssertEqual(try JournalRefs.check(["commit:\(String(repeating: "cd", count: 20))@project"], nextSeq: 1, run: run, folders: [project]).first?.present, false)
        XCTAssertNil(try JournalRefs.check(["commit:abcd"], nextSeq: 1, run: run, folders: [project]).first?.present, "a short sha: not said")
    }

    func testTheCorrectionsMatrix() {
        let entries = [JournalEntry(id: "r#1", seq: 1, at: "", by: "owner", kind: "note"), JournalEntry(id: "r#2", seq: 2, at: "", by: "helper", kind: "review")]
        func code(_ n: Int, _ kind: String, _ by: String, _ may: Bool) -> Int32? {
            JournalCorrection.refusal(supersedes: n, kind: kind, by: by, entries: entries, mayCorrectOthers: may).map { ExitCodes.exit(for: $0) }
        }
        XCTAssertEqual(code(9, "note", "owner", true), 65, "a later or missing seq")
        XCTAssertEqual(code(0, "note", "owner", true), 65)
        XCTAssertEqual(code(1, "review", "owner", true), 65, "another kind: the wrong shape, whoever sends it")
        XCTAssertEqual(code(1, "note", "helper", false), 9, "another's entry without journal.supersede")
        XCTAssertNil(code(2, "review", "helper", false), "its own author")
        XCTAssertNil(code(2, "review", "manager", true), "journal.supersede held (or the owner)")
        // superseded_by is computed; chains end at the effective entry.
        var c = JournalEntry(id: "r#3", seq: 3, at: "", by: "helper", kind: "review"); c.supersedes = 2
        var d = JournalEntry(id: "r#4", seq: 4, at: "", by: "helper", kind: "review"); d.supersedes = 3
        let marked = JournalRead.markSuperseded(entries + [c, d])
        XCTAssertEqual(marked.map(\.supersededBy), [nil, 3, 4, nil])
        XCTAssertEqual(JournalRead.effective(entries + [c, d]).map(\.seq), [1, 4])
    }

    func testTheSweepReplacesATokenInTheTextAndEveryStringOfTheData() {
        let token = ChatTokens.make()
        let sweep = ExportSweep(tokenHashes: ["bot1": ChatSecrets.hash(token)])
        let out = JournalSweep.apply(sweep, text: "the token is \(token)", data: .object(["a": .array([.string("x \(token)")]), "n": .number(1)]))
        XCTAssertTrue(out.swept)
        XCTAssertFalse(out.text!.contains(token))
        XCTAssertTrue(out.text!.contains("[a chat token of bot1"))
        XCTAssertFalse(String(data: try! HostWire.encoder.encode(out.data!), encoding: .utf8)!.contains(token))
        XCTAssertFalse(JournalSweep.apply(sweep, text: "nothing here", data: nil).swept)
    }

    // MARK: the daemon end to end

    func makeWorkspace(openRun: Bool = true) throws {
        let ws = WorkspaceStore(store: store)
        var rec = WorkspaceRecord(name: "demo", createdAt: Date(), brief: WorkspaceBrief(sha256: "", bytes: 0, updatedAt: Date()),
                                  folders: [WorkspaceFolder(path: project, main: true)],
                                  rooms: [WorkspaceRoom(label: "demo", chatRoom: "room1", main: true, owned: true)])
        var run = WorkspaceRun(id: "2026-11-24-1", startedAt: Date(timeIntervalSinceNow: -60))
        run.rooms = [WorkspaceRunRoom(room: "room1", fromSeq: 10)]
        if !openRun { run.endedAt = Date() }
        rec.runs = [run]
        try ws.create(rec, brief: Data("Fix the build\n".utf8), log: [WorkspaceLogEntry(action: "created")])
    }

    func host(readOnly: Bool = false) -> HostCore { HostCore(store: store, readOnly: readOnly, version: "test") }

    func send(_ c: HostCore, _ op: HostOp, _ edit: (inout WorkspaceJournalRequest) -> Void) async -> HostMessage {
        var w = WorkspaceRequest(name: "demo")
        var j = WorkspaceJournalRequest()
        edit(&j)
        w.journal = j
        var r = HostRequest(op)
        r.workspaceRequest = w
        return await c.handle(r)
    }

    func entry(_ m: HostMessage, file: StaticString = #filePath, line: UInt = #line) throws -> JournalEntry {
        XCTAssertNil(m.error, m.error?.message ?? "", file: file, line: line)
        return try XCTUnwrap(m.result, file: file, line: line).decode(JournalEntry.self)
    }

    func testEntriesAreAppendedInOrderWithTheDaemonsFieldsFsyncedAndPrivate() async throws {
        try makeWorkspace()
        let c = host()
        let a = try entry(await send(c, .workspaceJournalAdd) { $0.kind = "note"; $0.text = "first" })
        XCTAssertEqual(a.id, "2026-11-24-1#1")
        XCTAssertEqual(a.seq, 1)
        XCTAssertEqual(a.by, "owner")
        XCTAssertNotNil(ISO8601DateFormatter().date(from: a.at.replacingOccurrences(of: #"\.\d{3}"#, with: "", options: .regularExpression)))
        XCTAssertTrue(a.at.hasSuffix("Z") && a.at.contains("."), "UTC, milliseconds: \(a.at)")
        let b = try entry(await send(c, .workspaceJournalAdd) { $0.kind = "review"; $0.data = .object(["criterion": .string("c1"), "met": .string("yes")]) })
        XCTAssertEqual(b.seq, 2)
        let fix = try entry(await send(c, .workspaceJournalAdd) {
            $0.kind = "review"; $0.data = .object(["criterion": .string("c1"), "met": .string("no")]); $0.supersedes = 2; $0.refs = ["seq:1"]
        })
        XCTAssertEqual(fix.supersedes, 2)
        // Read, by the daemon and in-process with none: in seq order, the corrected entry marked.
        for core in [c, host(readOnly: true)] {
            let m = await send(core, .workspaceJournal) { _ in }
            let j = try XCTUnwrap(m.result).decode(WorkspaceJournal.self)
            XCTAssertEqual(j.kind, "WorkspaceJournal")
            XCTAssertEqual(j.format, "journal/1")
            XCTAssertEqual(j.run, "2026-11-24-1")
            XCTAssertTrue(j.open)
            XCTAssertEqual(j.entries.map(\.kind), ["note", "review", "review"])
            XCTAssertEqual(j.entries.map(\.supersededBy), [nil, 3, nil])
        }
        // superseded_by is never stored.
        let path = RunJournalStore.shared(storeRoot).journalPath("demo", "2026-11-24-1")
        let text = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertFalse(text.contains("superseded_by"))
        XCTAssertEqual(text.split(separator: "\n").count, 3)
        func mode(_ p: String) -> Int { ((try? FileManager.default.attributesOfItem(atPath: p)[.posixPermissions]) as? NSNumber)?.intValue ?? -1 }
        XCTAssertEqual(mode(path), 0o600)
        XCTAssertEqual(mode((path as NSString).deletingLastPathComponent), 0o700)
        // Refused shapes: nothing appended.
        let wrong = await send(c, .workspaceJournalAdd) { $0.kind = "note"; $0.supersedes = 2 }
        XCTAssertEqual(wrong.error.map { ExitCodes.exit(for: $0) }, 65)
        let reserved = await send(c, .workspaceJournalAdd) { $0.kind = "gate" }
        XCTAssertEqual(reserved.error.map { ExitCodes.exit(for: $0) }, 65)
        let big = await send(c, .workspaceJournalAdd) { $0.kind = "note"; $0.text = String(repeating: "x", count: JournalLimits.textBytes + 1) }
        XCTAssertEqual(big.error.map { ExitCodes.exit(for: $0) }, 8)
        XCTAssertEqual(try RunJournalStore.shared(storeRoot).entries("demo", "2026-11-24-1").count, 3)
    }

    func testAnEntryIsWrittenOnlyWhileItsRunIsOpen() async throws {
        try makeWorkspace(openRun: false)
        let c = host()
        let m = await send(c, .workspaceJournalAdd) { $0.kind = "note" }
        XCTAssertEqual(m.error?.code, .noOpenRun)
        XCTAssertEqual(ExitCodes.exit(for: .noOpenRun), 3)
        // A run that closed while the entry was being written: run-closed.
        var w = WorkspaceRequest(name: "demo"); w.journal = WorkspaceJournalRequest()
        var r = HostRequest(.workspaceJournalAdd); r.workspaceRequest = w
        do {
            _ = try await c.commitJournalEntry(r, "demo", "2026-11-24-1", by: "owner", kind: "note", j: WorkspaceJournalRequest(), folders: [], staged: [])
            XCTFail("a closed run took an entry")
        } catch { XCTAssertEqual(HostError.from(error).code, .runClosed) }
        XCTAssertEqual(ExitCodes.exit(for: .runClosed), 3)
    }

    func testEvidenceIsCopiedAndHashedOrReferencedInPlaceAndLaterEditsNeverChangeTheRecord() async throws {
        try makeWorkspace()
        let c = host()
        try "2 passed\n".write(toFile: project + "/test.log", atomically: true, encoding: .utf8)
        let e = try entry(await send(c, .workspaceJournalAdd) { $0.kind = "review"; $0.attach = [self.project + "/test.log"] })
        let ev = try XCTUnwrap(e.evidence?.first)
        XCTAssertEqual(ev.ref, "file:test.log")
        XCTAssertEqual(ev.bytes, 9)
        XCTAssertEqual(ev.sha256, RunArchive.sha(Array("2 passed\n".utf8)))
        let stored = try XCTUnwrap(RunJournalStore.shared(storeRoot).evidencePath("demo", "2026-11-24-1", stored: try XCTUnwrap(ev.stored)))
        try "0 passed, edited\n".write(toFile: project + "/test.log", atomically: true, encoding: .utf8)
        XCTAssertEqual(try String(contentsOfFile: stored, encoding: .utf8), "2 passed\n", "the copy is the record")
        XCTAssertEqual(try RunJournalStore.shared(storeRoot).entries("demo", "2026-11-24-1").first?.evidence?.first?.sha256, ev.sha256)
        // Referenced in place: hashed, not copied.
        try Data(repeating: 7, count: 1000).write(to: URL(fileURLWithPath: project + "/render.mov"))
        let r = try entry(await send(c, .workspaceJournalAdd) { $0.kind = "note"; $0.attachRef = [self.project + "/render.mov"] })
        XCTAssertEqual(r.evidence?.first?.copied, false)
        XCTAssertNil(r.evidence?.first?.stored)
        XCTAssertEqual(r.evidence?.first?.bytes, 1000)
        // Outside the run's folders, or through a link: refused.
        try "x".write(toFile: dir + "/outside.txt", atomically: true, encoding: .utf8)
        let out = await send(c, .workspaceJournalAdd) { $0.kind = "note"; $0.attach = [self.dir + "/outside.txt"] }
        XCTAssertEqual(out.error.map { ExitCodes.exit(for: $0) }, 65)
        try FileManager.default.createSymbolicLink(atPath: project + "/link", withDestinationPath: dir)
        let viaLink = await send(c, .workspaceJournalAdd) { $0.kind = "note"; $0.attach = [self.project + "/link/outside.txt"] }
        XCTAssertEqual(viaLink.error.map { ExitCodes.exit(for: $0) }, 65)
        // Past the copy limit: 8 limited (a large file is referenced instead).
        let fd = open(project + "/big.bin", O_WRONLY | O_CREAT, 0o600)
        ftruncate(fd, off_t(JournalLimits.copyFileBytes + 1))
        close(fd)
        let big = await send(c, .workspaceJournalAdd) { $0.kind = "note"; $0.attach = [self.project + "/big.bin"] }
        XCTAssertEqual(big.error.map { ExitCodes.exit(for: $0) }, 8)
        let bigRef = await send(c, .workspaceJournalAdd) { $0.kind = "note"; $0.attachRef = [self.project + "/big.bin"] }
        XCTAssertNil(bigRef.error)
        // No staging file is left behind.
        let left = try FileManager.default.contentsOfDirectory(atPath: RunJournalStore.shared(storeRoot).runFolder("demo", "2026-11-24-1") + "/evidence")
        XCTAssertFalse(left.contains { $0.hasPrefix(".staging") }, "\(left)")
    }

    func testWaitIsLevelTriggeredAndAnUnknownPointIsRefused() async throws {
        try makeWorkspace()
        let c = host()
        _ = try entry(await send(c, .workspaceJournalAdd) { $0.kind = "note"; $0.text = "done" })
        func read(_ edit: (inout WorkspaceJournalRequest) -> Void) async throws -> WorkspaceJournal {
            let m = await send(c, .workspaceJournal, edit)
            return try XCTUnwrap(m.result).decode(WorkspaceJournal.self)
        }
        let now = try await read { $0.kind = "note" }
        XCTAssertEqual(now.entries.map(\.seq), [1], "an entry already written matches at once")
        let none = try await read { $0.kind = "review" }
        XCTAssertEqual(none.entries, [])
        let after = try await read { $0.kind = "note"; $0.after = "2026-11-24-1#1" }
        XCTAssertEqual(after.entries, [], "after a point: only what comes later")
        _ = try entry(await send(c, .workspaceJournalAdd) { $0.kind = "note"; $0.text = "again" })
        let later = try await read { $0.kind = "note"; $0.after = "2026-11-24-1#1" }
        XCTAssertEqual(later.entries.map(\.seq), [2])
        for bad in ["2026-11-24-1#9", "nosuch#1", "garbage"] {
            let m = await send(c, .workspaceJournal) { $0.kind = "note"; $0.after = bad }
            XCTAssertEqual(m.error.map { ExitCodes.exit(for: $0) }, 65, bad)
        }
    }

    // MARK: following

    func collect(_ f: JournalFollower, max: Int, stopAfter: Double = 1.0) -> [JSONValue] {
        var out: [JSONValue] = []
        let t0 = Date()
        f.run(send: { out.append($0); return out.count < max }, cancelled: { Date().timeIntervalSince(t0) > stopAfter })
        return out
    }

    func testWseqIsOnePerWorkspaceKeptAcrossProcessesAndAFollowResumesWithNothingMissedOrRepeated() async throws {
        try makeWorkspace()
        let c = host()
        // Workspace events come from its log: the description changed.
        try WorkspaceStore(store: store).append("demo", WorkspaceLogEntry(action: "addendum-added"))
        for t in ["a", "b", "c"] { _ = try entry(await send(c, .workspaceJournalAdd) { $0.kind = "note"; $0.text = t }) }
        let js = RunJournalStore.shared(storeRoot)
        XCTAssertEqual(js.lastWseq("demo"), 4)
        // Another process (a new store object) reads the same cursor back and goes on from it.
        let other = RunJournalStore(storeRoot: storeRoot)
        XCTAssertEqual(other.lastWseq("demo"), 4)
        XCTAssertEqual(try other.appendFollow("demo", ["type": .string("workspace"), "event": .string("test")]), 5)
        XCTAssertEqual(js.lastWseq("demo"), 5, "re-read: the file is not the one it read")
        let rec = try XCTUnwrap(try WorkspaceStore(store: store).read("demo"))
        // From the start: hello, then every line, each wseq once and in order.
        let all = collect(try JournalFollower.make(store: js, workspace: "demo", record: rec, afterWseq: 0, after: nil, untilFinish: false), max: 6)
        XCTAssertEqual(all.map { $0["type"]?.stringValue }, ["hello", "workspace", "entry", "entry", "entry", "workspace"])
        XCTAssertEqual(all[0]["after"], .number(0))
        XCTAssertEqual(all[0]["format"], .string("journal/1"))
        XCTAssertEqual(all.dropFirst().map { $0["wseq"] }, [1, 2, 3, 4, 5].map { JSONValue.number($0) })
        XCTAssertEqual(all[1]["event"], .string("description.changed"))
        XCTAssertEqual(all[1]["revision"], .number(2))
        // Resumed after 2: nothing missed, nothing repeated.
        let resumed = collect(try JournalFollower.make(store: js, workspace: "demo", record: rec, afterWseq: 2, after: nil, untilFinish: false), max: 4)
        XCTAssertEqual(resumed.dropFirst().map { $0["wseq"] }, [3, 4, 5].map { JSONValue.number($0) })
        // Entries only, after an entry id.
        let entries = collect(try JournalFollower.make(store: js, workspace: "demo", record: rec, afterWseq: nil, after: "2026-11-24-1#1", untilFinish: false), max: 3)
        XCTAssertEqual(entries.map { $0["type"]?.stringValue }, ["hello", "entry", "entry"])
        XCTAssertEqual(entries.dropFirst().compactMap { if case .number(let n)? = $0["entry"]?["seq"] { return Int(n) }; return nil }, [2, 3])
        // An unknown cursor is refused, never a replay from the start.
        for (w, a) in [(Int64(99), nil), (nil, "2026-11-24-1#99"), (nil, "nosuch#1")] as [(Int64?, String?)] {
            XCTAssertThrowsError(try JournalFollower.make(store: js, workspace: "demo", record: rec, afterWseq: w, after: a, untilFinish: false)) {
                XCTAssertEqual(ExitCodes.exit(for: HostError.from($0)), 65)
            }
        }
    }

    func testAFollowEndsCleanlyAtTheRunsFinishOrTheDaemonsStopAndSendsAHeartbeat() async throws {
        try makeWorkspace()
        let js = RunJournalStore.shared(storeRoot)
        let rec = try XCTUnwrap(try WorkspaceStore(store: store).read("demo"))
        // A heartbeat carries the cursor.
        let quiet = JournalFollower(store: js, workspace: "demo", mode: .workspace, startWseq: 0, startAfter: .number(0), openRun: "2026-11-24-1",
                                    untilFinish: false, poll: 0.02, heartbeat: 0.05)
        let beats = collect(quiet, max: 2)
        XCTAssertEqual(beats.last?["type"], .string("heartbeat"))
        XCTAssertEqual(beats.last?["after"], .number(0))
        // The followed run finishes: end, run-finished.
        try WorkspaceStore(store: store).append("demo", WorkspaceLogEntry(action: "run-closed", reason: "finish", run: "2026-11-24-1"))
        let f = try JournalFollower.make(store: js, workspace: "demo", record: rec, afterWseq: 0, after: nil, untilFinish: true)
        let lines = collect(f, max: 10, stopAfter: 3)
        XCTAssertEqual(lines.map { $0["type"]?.stringValue }, ["hello", "run", "end"])
        XCTAssertEqual(lines.last?["reason"], .string("run-finished"))
        XCTAssertEqual(lines.last?["after"], .number(1))
        // The daemon stopping: end, daemon-stopping.
        JournalFollower.stopping = true
        let stopped = collect(try JournalFollower.make(store: js, workspace: "demo", record: rec, afterWseq: nil, after: nil, untilFinish: false), max: 10)
        XCTAssertEqual(stopped.map { $0["type"]?.stringValue }, ["hello", "end"])
        XCTAssertEqual(stopped.last?["reason"], .string("daemon-stopping"))
    }

    // MARK: permissions

    func testTheJournalPermissionsGate() throws {
        let now = Date()
        func decide(_ perm: String, in w: String = "app", _ grants: [Grant] = [], role: String = "worker") -> GrantAnswer {
            GrantDecision.decide(GrantQuery(name: "helper", home: "app", bot: nil, perm: perm, workspace: w,
                                            recordRoles: [HeldRole(role: role, workspace: "app")]),
                                 GrantFacts(grants: grants, now: now)).answer
        }
        XCTAssertEqual(decide("journal.read"), .allow, "on by default in its own workspace")
        XCTAssertEqual(decide("journal.read", role: "member"), .allow)
        XCTAssertEqual(decide("journal.read", in: "other"), .never, "never another workspace's")
        XCTAssertEqual(decide("journal.read", [Grant(subject: .agent("app", "helper"), perm: "journal.read", answer: .never, scope: .workspace("app"), at: now)]),
                       .never, "withdrawable")
        XCTAssertEqual(decide("journal.write:review"), .ask, "off until granted")
        let reviewOnly = Grant(subject: .agent("app", "helper"), perm: "journal.write:review", answer: .allow, scope: .workspace("app"), at: now)
        XCTAssertEqual(decide("journal.write:review", [reviewOnly]), .allow)
        XCTAssertEqual(decide("journal.write:note", [reviewOnly]), .ask, "that kind only")
        let any = Grant(subject: .agent("app", "helper"), perm: "journal.write", answer: .allow, scope: .workspace("app"), at: now)
        XCTAssertEqual(decide("journal.write:note", [any]), .allow, "journal.write answers for every kind")
        XCTAssertEqual(decide("journal.write:note", [Grant(subject: .agent("app", "helper"), role: "reviewer", scope: .workspace("app"), at: now)]), .allow)
        XCTAssertTrue(GrantPermissions.isKnown("journal.write:review"))
        XCTAssertFalse(GrantPermissions.isKnown("journal.write:Bad Kind"))
        XCTAssertFalse(GrantPermissions.isKnown("journal.read:note"))
        XCTAssertNoThrow(try GrantWords.parse("journal.write:review=allow"))
        // The gate's classes: write by kind, attach adds evidence.attach.
        var r = HostRequest(.workspaceJournalAdd)
        var w = WorkspaceRequest(name: "app"); var j = WorkspaceJournalRequest(); j.kind = "review"; j.attach = ["/x"]; w.journal = j
        r.workspaceRequest = w
        XCTAssertEqual(ActionClasses.classify(r), .needs(["journal.write:review", "evidence.attach"], .workspace("app")))
        // journal.supersede is decided by the daemon once the entry is read: the owner never, an agent by its grants.
        try makeWorkspace()
        var owner = HostRequest(.workspaceJournalAdd); owner.workspaceRequest = WorkspaceRequest(name: "demo")
        XCTAssertNil(PermissionGate.require("journal.supersede", for: owner, workspace: "demo", store: store))
        var agent = owner; agent.actAs = "demo/helper"
        XCTAssertEqual(PermissionGate.require("journal.supersede", for: agent, workspace: "demo", store: store)?.code, .notPermitted)
        var g = GrantStore(store: store).readOrEmpty()
        g.grants.append(Grant(subject: .agent("demo", "helper"), perm: "journal.supersede", answer: .allow, scope: .workspace("demo"), at: now))
        try GrantStore(store: store).write(g)
        XCTAssertNil(PermissionGate.require("journal.supersede", for: agent, workspace: "demo", store: store))
    }

    // MARK: the archive

    func testTheJournalAndItsEvidenceAreFrozenIntoTheRunsArchiveAndReadFromThere() async throws {
        try makeWorkspace()
        let c = host()
        try "proof\n".write(toFile: project + "/proof.txt", atomically: true, encoding: .utf8)
        _ = try entry(await send(c, .workspaceJournalAdd) { $0.kind = "note"; $0.text = "with proof"; $0.attach = [self.project + "/proof.txt"] })
        let rec = try XCTUnwrap(try WorkspaceStore(store: store).read("demo"))
        let j = c.journalForArchive("demo", "2026-11-24-1")
        XCTAssertNotNil(j.journal)
        XCTAssertEqual(j.evidence.count, 1)
        var e = RunEvidence(workspace: "demo", run: rec.runs[0], endedAt: Date(), brief: Data("Fix\n".utf8))
        e.journal = j.journal
        e.evidence = j.evidence
        let out = try RunArchive.write(e, store: store, sweep: ExportSweep(tokenHashes: [:]), fetch: nil)
        XCTAssertTrue(out.manifest.files.contains { $0.path == "journal.jsonl" })
        XCTAssertTrue(out.manifest.files.contains { $0.path.hasPrefix("evidence/") && $0.path.hasSuffix("proof.txt") })
        XCTAssertTrue(RunArchive.verify(root: storeRoot + "/" + out.path).ok)
        // The run's folder gone (as once its archive verifies): read from the archive.
        try MacFenceHostFS.remove(RunJournalStore.shared(storeRoot).runFolder("demo", "2026-11-24-1"))
        let back = try RunJournalStore.shared(storeRoot).entries("demo", "2026-11-24-1")
        XCTAssertEqual(back.map(\.text), ["with proof"])
        XCTAssertNotNil(RunJournalStore.shared(storeRoot).evidencePath("demo", "2026-11-24-1", stored: try XCTUnwrap(back[0].evidence?.first?.stored)))
    }
}
