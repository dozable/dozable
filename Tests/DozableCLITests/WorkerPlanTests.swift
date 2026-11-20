import CryptoKit
import DozableChat
import Foundation
import XCTest
@testable import DozableKit
@testable import DozableHost
@testable import DozableCLI

/// `worker-plan` (the dashboard's Add a worker page, `doz worker add … --dry-run`): the plan and the add agree over a
/// table of requests — the plan's problem is the add's refusal (its sentence and code) with the field it is about, and
/// when there is none the add does what the plan said; the plan writes nothing (the store's files byte for byte, no
/// participant, no keychain item, nothing launched); never unfenced from a default; with no daemon the checks that need
/// one are skipped and said to be checked again. Scratch stores, a memory keychain, the fakes of `WorkspaceWorkerTests`.
final class WorkerPlanTests: BotTestCase {
    var trace: WorkspaceWorkerTests.Trace!
    var rooms: WorkspaceWorkerTests.Rooms!
    var managers: WorkspaceWorkerTests.Managers!
    var workers: WorkspaceWorkerTests.Workers!
    var work: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        trace = WorkspaceWorkerTests.Trace()
        rooms = WorkspaceWorkerTests.Rooms(trace, chat)
        managers = WorkspaceWorkerTests.Managers()
        workers = WorkspaceWorkerTests.Workers(trace)
        work = root.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        work = URL(fileURLWithPath: WorkspaceStore.resolved(work.path))
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: bin.appendingPathComponent("claude").path, contents: Data("#!/bin/sh\n".utf8),
                                       attributes: [.posixPermissions: 0o755])
        let home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        setenv("DOZ_TEST_MAC_PATH", bin.path + ":/usr/bin:/bin", 1)
        setenv("DOZ_TEST_FENCE_HOME", home.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("DOZ_TEST_MAC_PATH")
        unsetenv("DOZ_TEST_FENCE_HOME")
        try super.tearDownWithError()
    }

    func wcore(readOnly: Bool = false) async -> HostCore {
        let c = await core(readOnly: readOnly, withChat: !readOnly)
        if !readOnly { await c.setWorkspaceChat(rooms) }
        await c.setManagerLauncher(managers)
        await c.setWorkerLauncher(workers)
        return c
    }

    @discardableResult
    func ws(_ c: HostCore, _ op: HostOp, _ name: String?, _ edit: (inout WorkspaceRequest) -> Void = { _ in }) async -> HostMessage {
        var w = WorkspaceRequest(name: name)
        edit(&w)
        var r = HostRequest(op)
        r.workspaceRequest = w
        return await c.handle(r)
    }

    func send(_ c: HostCore, _ op: HostOp, _ q: WorkerRequest) async -> HostMessage {
        var r = HostRequest(op)
        r.workerRequest = q
        return await c.handle(r)
    }

    func plan(_ c: HostCore, _ q: WorkerRequest, file: StaticString = #filePath, line: UInt = #line) async throws -> WorkerPlan {
        let m = await send(c, .workerPlan, q)
        XCTAssertNil(m.error, m.error?.message ?? "", file: file, line: line)
        return try XCTUnwrap(m.result, file: file, line: line).decode(WorkerPlan.self)
    }

    func req(_ w: String = "demo", _ name: String? = nil, _ edit: (inout WorkerRequest) -> Void = { _ in }) -> WorkerRequest {
        var q = WorkerRequest(workspace: w, name: name)
        q.task = "list the files"
        edit(&q)
        return q
    }

    func started(_ c: HostCore, _ name: String = "demo") async throws {
        let m = await ws(c, .workspaceNew, name) { $0.brief = "Make the launch video.\n"; $0.folders = [WorkspaceFolder(path: self.work.path)] }
        XCTAssertNil(m.error, m.error?.message ?? "")
        let s = await ws(c, .workspaceStart, name)
        XCTAssertNil(s.error, s.error?.message ?? "")
    }

    /// Every file under the store with its bytes' sha256 — "nothing written".
    func treeDigest() -> [String: String] {
        var out: [String: String] = [:]
        let base = store.root.path
        guard let e = FileManager.default.enumerator(atPath: base) else { return [:] }
        for case let p as String in e {
            // Logs, and the daemon's own metrics database (its sampler writes the WAL on a timer, whatever a request does).
            if p.hasSuffix(".log") || p.hasPrefix("logs") || p.hasPrefix("metrics.sqlite") { continue }
            let full = base + "/" + p
            var d: ObjCBool = false
            FileManager.default.fileExists(atPath: full, isDirectory: &d)
            out[p] = d.boolValue ? "dir" : (FileManager.default.contents(atPath: full).map { SHA256.hash(data: $0).description } ?? "?")
        }
        return out
    }

    /// What a look must leave as it was. Every part is put in a fixed order first: two dictionaries with the same
    /// contents need not print in the same order, so comparing their descriptions failed now and then (CI, 0.52.14).
    func snapshot() -> String {
        func sorted(_ v: Any) -> String {
            if let d = v as? [String: Any] { return d.keys.sorted().map { "\($0)=\(sorted(d[$0]!))" }.joined(separator: ",") }
            if let s = v as? Set<String> { return s.sorted().joined(separator: ",") }
            return "\(v)"
        }
        let services = keychain.items(servicePrefix: "").map(\.service).sorted()
        return [sorted(treeDigest()), sorted(chat.dir), sorted(chat.hashes), "\(services)",
                "\(workers.orders.count)", "\(workers.ends.count)", "\(trace.all)"].joined(separator: " | ")
    }

    // MARK: the plan and the add agree

    func testThePlanAndTheAddAgree() async throws {
        let c = await wcore()
        try await started(c)
        let setup = await ws(c, .workspaceNew, "setup") { $0.brief = "B\n"; $0.folders = [WorkspaceFolder(path: self.work.path)] }
        XCTAssertNil(setup.error)
        chat.plant("pat", token: "pat-token-0123456789")
        _ = try change(await ask(c, .botNew, "otto") { $0.agent = "claude-code"; $0.isolation = "fenced" })
        let rows: [(String, WorkerRequest, String?)] = [
            ("anonymous", req(), nil),
            ("named, a tool allowed", req("demo", "carl") { $0.allowTools = ["Edit"] }, nil),
            ("its own VM", req("demo", "vmw") { $0.isolation = "vm"; $0.cpus = 2; $0.memory = "2G" }, nil),
            ("unfenced, named", req("demo", "uni") { $0.isolation = "unfenced" }, nil),
            ("from a bot", req() { $0.fromBot = "otto" }, nil),
            ("Codex", req("demo", "cdx") { $0.agent = "codex" }, nil),
            ("a participant's name", req("demo", "pat"), "name"),
            ("a bot's name", req("demo", "otto"), "name"),
            ("an unknown workspace", req("nosuch"), "workspace"),
            ("setting up", req("setup"), "workspace"),
            ("no task", req() { $0.task = "  " }, "task"),
            ("--cpus fenced", req() { $0.cpus = 2 }, "cpus"),
            ("--memory fenced", req() { $0.memory = "2G" }, "memory"),
            ("another program", req() { $0.agent = "pi" }, "agent"),
            ("an unknown bot", req() { $0.fromBot = "nosuch" }, "fromBot"),
            ("an unknown room", req() { $0.rooms = ["nosuch"] }, "rooms"),
            ("an unknown isolation", req() { $0.isolation = "bogus" }, "isolation"),
            ("a tool unfenced", req("demo", "u2") { $0.isolation = "unfenced"; $0.allowTools = ["Edit"] }, "allowTools"),
            ("a sandbox not of it", req() { $0.sandbox = "loose" }, "sandbox"),
            ("a bot and NAME", req("demo", "zed") { $0.fromBot = "otto" }, "name"),
        ]
        for (label, q, field) in rows {
            let before = snapshot()
            let p = try await plan(c, q)
            XCTAssertEqual(snapshot(), before, "\(label): the plan wrote, made or started nothing")
            XCTAssertEqual(p.command, WorkerAddCommand.text(q), label)
            let m = await send(c, .workerAdd, q)
            if let e = m.error {
                XCTAssertEqual(p.problem?.text, e.message, label)
                XCTAssertEqual(p.problem?.code, e.code.rawValue, label)
                XCTAssertEqual(p.problem?.field, field, "\(label): \(e.message)")
                XCTAssertNil(p.name, label)
                continue
            }
            XCTAssertNil(field, "\(label): added, but expected a refusal")
            XCTAssertNil(p.problem, "\(label): \(p.problem?.text ?? "")")
            let a = try XCTUnwrap(m.result, label).decode(WorkerAdded.self)
            let o = try XCTUnwrap(workers.orders.last, label)
            XCTAssertEqual(p.name, a.worker.name, label)
            XCTAssertEqual(p.isolation, o.isolation.rawValue, label)
            XCTAssertEqual(p.place, a.worker.place, label)
            XCTAssertEqual(p.sandbox, o.isolation == .vm ? o.place : nil, label)
            XCTAssertEqual(p.session, o.session ?? o.place, label)
            XCTAssertEqual(p.folder, o.workdir, label)
            XCTAssertEqual(p.network, o.isolation == .unfenced ? "not limited" : o.permissions, label)
            XCTAssertEqual(p.control, a.worker.control, label)
            XCTAssertEqual(p.actsAsYou, a.worker.actsAsYou == true, label)
            XCTAssertEqual(p.rooms, ["demo"], label)
            XCTAssertEqual(p.agent, o.agent, label)
            XCTAssertEqual(p.director, "you", label)
            if o.isolation == .fenced, o.agent == "claude-code" {
                XCTAssertEqual(p.allowTools, WorkerLaunch.defaultAllowedTools + (q.allowTools ?? []), label)
                XCTAssertTrue(o.plan.argv.joined(separator: " ").hasSuffix(p.allowTools.joined(separator: " ")), label)
            } else {
                XCTAssertEqual(p.allowTools, [], label)
            }
            XCTAssertEqual(p.account, o.isolation == .unfenced ? nil : (o.account ?? (o.isolation == .vm ? "mac" : "mac")), label)
            XCTAssertTrue(p.lines.first?.hasPrefix("worker \(a.worker.name) in demo") == true, "\(label): \(p.lines)")
            // Free its name and place for the next row.
            let e = await send(c, .workerEnd, WorkerRequest(workspace: "demo", name: a.worker.name))
            XCTAssertNil(e.error, e.error?.message ?? "")
        }
        try? FileManager.default.removeItem(atPath: c.managerTokenRoot)
    }

    func testAPlaceTakenIsTheAddsSentence() async throws {
        let c = await wcore()
        try await started(c)
        workers.places["demo-bot1"] = ManagerPlaceInfo(exists: true, running: true)
        let p = try await plan(c, req())
        let m = await send(c, .workerAdd, req())
        XCTAssertEqual(p.problem?.text, m.error?.message)
        XCTAssertEqual(p.problem?.field, "name")
        XCTAssertTrue(p.problem?.text.contains("already exists on this Mac") == true, p.problem?.text ?? "")
        let q = req("demo", nil) { $0.session = "mine" }
        workers.places["mine"] = ManagerPlaceInfo(exists: true, running: true)
        let taken = try await plan(c, q)
        XCTAssertEqual(taken.problem?.field, "session")
    }

    func testUnfencedNeverFromADefault() async throws {
        let c = await wcore()
        try await started(c)
        _ = try change(await ask(c, .botNew, "uma") { $0.agent = "claude-code"; $0.isolation = "unfenced" })
        var rec = try XCTUnwrap(try WorkspaceStore(store: store).read("demo"))
        rec.defaults.isolation = "unfenced"
        try WorkspaceStore(store: store).write(rec)
        var p = try await plan(c, req())
        XCTAssertEqual(p.isolation, "fenced", "the workspace's default never makes it unfenced")
        XCTAssertFalse(p.actsAsYou)
        p = try await plan(c, req() { $0.fromBot = "uma" })
        XCTAssertEqual(p.isolation, "fenced", "nor the bot's")
        p = try await plan(c, req("demo", "u") { $0.isolation = "unfenced" })
        XCTAssertEqual(p.isolation, "unfenced")
        XCTAssertTrue(p.actsAsYou)
        XCTAssertNil(p.account, "unfenced: it acts as you — no account of ours")
        XCTAssertEqual(p.control, "no proxy · no placeholders · no guard · acts as you")
        XCTAssertEqual(p.network, "not limited")
    }

    func testWithNoDaemonItStartsNothingAndSaysWhatIsCheckedAtTheAdd() async throws {
        let d = await wcore()
        try await started(d)
        workers.places["demo-bot1"] = ManagerPlaceInfo(exists: true, running: true)
        let ro = await wcore(readOnly: true)
        await ro.setChatSettingOverride(true)
        let before = snapshot()
        let p = try await plan(ro, req())
        XCTAssertNil(p.problem, p.problem?.text ?? "")
        XCTAssertEqual(p.name, "bot1")
        XCTAssertTrue(p.notes.contains { $0.contains("checked again when you add") }, "\(p.notes)")
        XCTAssertEqual(snapshot(), before, "nothing written, made or started")
        // Chat off by its setting: the add's sentence.
        await ro.setChatSettingOverride(false)
        let off = try await plan(ro, req())
        XCTAssertEqual(off.problem?.text, "a worker needs chat — doz chat on")
        XCTAssertEqual(off.problem?.field, "workspace")
        XCTAssertTrue(HostOp.workerPlan.isReadOnly)
        // The add itself still needs the daemon.
        let m = await send(ro, .workerAdd, req())
        XCTAssertEqual(m.error?.code, .unavailable)
    }

    func testALongTaskGoesInAFile() async throws {
        let c = await wcore()
        try await started(c)
        let long = String(repeating: "word ", count: 300)
        let p = try await plan(c, req() { $0.task = long })
        XCTAssertTrue(p.command.contains("--task=\"$(cat task.txt)\""), p.command)
        XCTAssertTrue(p.notes.contains { $0.contains("task.txt") }, "\(p.notes)")
        XCTAssertFalse(p.command.contains("word word"))
    }
}

/// The ONE command source: each request's argv parses back into the same request; the text, run by /bin/sh, gives the
/// argv back word for word (quotes, line breaks, `$`, unicode); a long task read from task.txt; a dry run prints the
/// command exactly.
final class WorkerAddCommandTests: XCTestCase {
    func requests() -> [WorkerRequest] {
        var a = WorkerRequest(workspace: "demo")
        a.task = "list the files"
        var b = WorkerRequest(workspace: "launch-video", name: "bot4")
        b.task = "Make the 15-second cut — scenes 1, 4 & 6.\nUse 'it' and \"that\"; cost $5 `now` \\ ünïcødé 🎬"
        b.agent = "codex"
        b.isolation = "vm"
        b.cpus = 4
        b.memory = "4G"
        b.rooms = ["review", "launch-video-ops"]
        var c = WorkerRequest(workspace: "demo")
        c.task = "review the cut"
        c.fromBot = "otto"
        c.rooms = ["review"]
        var d = WorkerRequest(workspace: "demo", name: "carl")
        d.task = "-starts with a dash"
        d.isolation = "fenced"
        d.session = "my-session"
        d.allowTools = ["Edit", "Bash(git status:*)"]
        var e = WorkerRequest(workspace: "demo", name: "v2")
        e.task = "x"
        e.sandbox = "wsa"
        return [a, b, c, d, e]
    }

    func testTheArgvParsesBackIntoTheSameRequest() throws {
        for q in requests() {
            let argv = WorkerAddCommand.argv(q)
            XCTAssertEqual(Array(argv.prefix(3)), ["doz", "worker", "add"])
            let cmd = try WorkerAdd.parse(Array(argv.dropFirst(3)))
            XCTAssertEqual(cmd.request(), q)
            XCTAssertFalse(cmd.dryRun)
        }
    }

    /// The words /bin/sh makes of a command line (`doz` replaced by a function that prints its arguments).
    func shellWords(_ text: String, in dir: URL? = nil) throws -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "doz() { printf 'doz\\0'; for a; do printf '%s\\0' \"$a\"; done; }; " + text]
        if let dir { p.currentDirectoryURL = dir }
        p.environment = ["PATH": "/usr/bin:/bin", "HOME": "/nonexistent", "LANG": "en_US.UTF-8"]
        let o = Pipe()
        p.standardOutput = o
        try p.run()
        let data = o.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
        return String(decoding: data, as: UTF8.self).split(separator: "\0", omittingEmptySubsequences: false).dropLast().map(String.init)
    }

    func testTheTextIsTheArgvToAShell() throws {
        for q in requests() {
            XCTAssertEqual(try shellWords(WorkerAddCommand.text(q)), WorkerAddCommand.argv(q), WorkerAddCommand.text(q))
        }
    }

    func testALongTaskIsReadFromAFile() throws {
        var q = WorkerRequest(workspace: "demo")
        q.task = String(repeating: "Make it 'so' $HOME. ", count: 80).trimmingCharacters(in: .whitespaces)
        XCTAssertTrue(WorkerAddCommand.taskInFile(q))
        let text = WorkerAddCommand.text(q)
        XCTAssertTrue(text.contains("--task=\"$(cat task.txt)\""), text)
        XCTAssertNotNil(WorkerAddCommand.taskFileNote(q))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("doz-task-\(getpid())-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try q.task!.write(to: dir.appendingPathComponent("task.txt"), atomically: true, encoding: .utf8)
        let words = try shellWords(text, in: dir)
        XCTAssertEqual(try WorkerAdd.parse(Array(words.dropFirst(3))).request(), q, "the same request, its task read from the file")
        q.task = "short"
        XCTAssertNil(WorkerAddCommand.taskFileNote(q))
    }

    func testADryRunPrintsTheCommandExactly() {
        var p = WorkerPlan(workspace: "demo", command: WorkerAddCommand.text(requests()[1]))
        p.lines = ["worker bot4 in launch-video"]
        var text = WorkerAdd.planText(p)
        XCTAssertTrue(text.hasSuffix("\nThe command:\n" + p.command + "\n"), text)
        p.problem = WorkerPlanProblem(field: "name", text: "pat is already in chat — choose another name, or leave it out", code: "exists")
        p.lines = []
        text = WorkerAdd.planText(p)
        XCTAssertTrue(text.hasPrefix("It cannot be added: pat is already in chat"), text)
    }
}
