import ArgumentParser
import Foundation
import XCTest
@testable import DozableKit
@testable import DozableHost
@testable import DozableCLI

/// One-shot `doz workspace new` (WS.04): `--preset` (today's presets; an unknown one 65 `invalid-value`, naming them; a flag
/// given wins), `--brief TEXT` / `--brief -` (the trailing line break dropped) beside `--prompt-file` (each excludes the
/// other), `--worker TASK` (declared at new, recorded while setting up, listed `not-started`, in the plan's lines and its
/// command), and `workspace create` as new's alias. The scratch store, fake chat and launcher of `WorkspacePlanTests`.
extension WorkspacePlanTests {
    func exitCode(_ body: () throws -> Void) -> Int32? {
        do { try body() } catch let e as ExitCode { return e.rawValue } catch { return -1 }
        return nil
    }

    // MARK: parsing

    func testAnUnknownPresetIsAnInvalidValueNamingThePresets() throws {
        XCTAssertThrowsError(try WorkspacePresets.named("nosuch")) { e in
            let h = HostError.from(e)
            XCTAssertEqual(h.code, .invalidValue)
            XCTAssertEqual(ExitCodes.exit(for: h), 65)
            for p in WorkspacePresets.builtIn { XCTAssertTrue(h.message.contains(p.id), h.message) }
        }
        XCTAssertEqual(try WorkspacePresets.named("blank").id, "blank")
        let cmd = try WorkspaceNew.parse(["app", "--preset", "nosuch", "--brief", "x"])
        XCTAssertEqual(exitCode { _ = try cmd.presetChosen() }, 65)
        XCTAssertEqual(exitCode { _ = try cmd.request(brief: "x") }, 65, "the request is refused too: nothing is sent")
    }

    func testAPresetFillsOnlyWhatTheFlagsLeaveUnset() throws {
        // 782 (D7): a retired preset is refused before anything is sent.
        var cmd = try WorkspaceNew.parse(["app", "--preset", "research", "--brief", "x", "--folder", work.path])
        XCTAssertEqual(exitCode { _ = try cmd.request(brief: "x") }, 65)
        var w: WorkspaceRequest
        cmd = try WorkspaceNew.parse(["app", "--preset", "remotion-video", "--brief", "x", "--network", "open", "--manager", "mira"])
        w = try cmd.request(brief: "x")
        XCTAssertEqual(w.network, "open", "the flag wins")
        XCTAssertEqual(w.workerIsolation, "vm")
        XCTAssertEqual(w.managerIsolation, "vm")
        cmd = try WorkspaceNew.parse(["app", "--preset", "blank", "--brief", "x", "--folder", work.path])
        w = try cmd.request(brief: "x")
        var plain = WorkspaceRequest(name: "app")
        plain.brief = "x"; plain.folders = [WorkspaceFolder(path: work.path)]; plain.refs = []
        XCTAssertEqual(w, plain, "blank changes nothing")
    }

    func testTheBriefFromStandardInputDropsItsTrailingLineBreak() throws {
        XCTAssertEqual(WorkspaceNew.trailingLineBreaksDropped("Fix the build\n"), "Fix the build")
        XCTAssertEqual(WorkspaceNew.trailingLineBreaksDropped("Fix the build\r\n\n"), "Fix the build")
        XCTAssertEqual(WorkspaceNew.trailingLineBreaksDropped("one\ntwo\n"), "one\ntwo")
        XCTAssertEqual(WorkspaceNew.trailingLineBreaksDropped("  kept  "), "  kept  ")
        XCTAssertEqual(try WorkspaceNew.parse(["app", "--brief", "Fix the build"]).briefText(), "Fix the build", "the text as given")
    }

    func testTheBriefAndThePromptFileExcludeEachOther() throws {
        let file = root.appendingPathComponent("brief.md").path
        try "From a file.\n".write(toFile: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(exitCode { _ = try WorkspaceNew.parse(["app", "--brief", "x", "--prompt-file", file]).briefText() }, 65)
        XCTAssertEqual(try WorkspaceNew.parse(["app"]).briefText(), "", "782: no description at all is the empty one")
        XCTAssertNil(try WorkspaceNew.parse([]).name, "782: no name — the daemon takes the next free workspaceN")
        XCTAssertEqual(try WorkspaceNew.parse(["--worker-isolation", "sandbox"]).request(brief: "").workerIsolation, "vm", "sandbox, stored as vm")
        XCTAssertEqual(try WorkspaceNew.parse(["app", "--prompt-file", file]).briefText(), "From a file.\n", "a file as it is")
    }

    func testCreateIsNewsAlias() throws {
        XCTAssertEqual(WorkspaceNew.configuration.aliases, ["create"])
        let cmd = try WorkspaceCommand.parseAsRoot(["create", "app", "--brief", "x", "--worker", "t"])
        XCTAssertEqual((cmd as? WorkspaceNew)?.workers, ["t"])
        XCTAssertTrue(Create.helpMessage().split(separator: "\n").prefix(15).contains { $0.contains("doz workspace new") })
    }

    func testTheWorkersAreInTheRequestAndTheCommand() throws {
        let cmd = try WorkspaceNew.parse(["app", "--brief", "x", "--worker", "Fix the failing test", "--worker", "it's 'quoted'"])
        let w = try cmd.request(brief: "x")
        XCTAssertEqual(w.workers, ["Fix the failing test", "it's 'quoted'"])
        let argv = WorkspaceNewCommand.argv(w)
        XCTAssertEqual(Array(argv.suffix(4)), ["--worker", "Fix the failing test", "--worker", "it's 'quoted'"])
        XCTAssertTrue(WorkspaceNewCommand.text(w).contains(#"--worker 'it'\''s '\''quoted'\'''"#))
        var back = try WorkspaceNew.parse(Array(argv.dropFirst(3))).request(brief: "x")
        back.brief = w.brief
        XCTAssertEqual(back, w, "the command parses back into the same request")
    }

    // MARK: the daemon

    func testWorkersAreDeclaredAtNewAndListedNotStarted() async throws {
        let c = await daemon()
        let p = try await plan(c, request("app") { $0.workers = ["Fix the failing test", "Review the fix"] })
        XCTAssertEqual(p.refusals, [])
        XCTAssertTrue(p.lines.contains { $0.hasPrefix("worker bot1: Fix the failing test") }, "\(p.lines)")
        XCTAssertTrue(p.commands.contains("--worker 'Fix the failing test' --worker 'Review the fix'"), p.commands)
        await made(c, request("app") { $0.workers = ["  Fix the failing test\n", "Review the fix"] })
        let rec = try XCTUnwrap(try WorkspaceStore(store: store).read("app"))
        XCTAssertEqual(rec.declaredWorkers.map(\.name), ["bot1", "bot2"])
        XCTAssertEqual(rec.declaredWorkers.map(\.task), ["Fix the failing test", "Review the fix"], "trimmed as worker add trims it")
        XCTAssertNil(rec.flags.startedAt)
        XCTAssertTrue(rec.agents.isEmpty, "nothing made: no agent, no participant")
        let shown = try await show(c, "app")
        XCTAssertEqual(shown.declaredWorkers?.map(\.name), ["bot1", "bot2"])
        XCTAssertEqual(shown.kind, "Workspace")
        // Listed by worker ls, not started.
        var r = HostRequest(.workerList)
        r.workerRequest = WorkerRequest(workspace: "app")
        let answer = await c.handle(r)
        let l = try XCTUnwrap(answer.result, answer.error?.message ?? "").decode(WorkerListing.self)
        XCTAssertEqual(l.kind, "WorkerListing")
        XCTAssertEqual(l.schema, 1)
        XCTAssertEqual(l.agents.map(\.task), ["Fix the failing test", "Review the fix"])
        XCTAssertTrue(l.agents.allSatisfy { $0.condition == "not-started" && $0.declared == true && $0.isolation == "fenced" && $0.place.hasPrefix("@mac/app-bot") })
        // The next workspace's declared names do not clash.
        await made(c, request("app2") { $0.workers = ["x"] })
        XCTAssertEqual(try WorkspaceStore(store: store).read("app2")?.declaredWorkers.map(\.name), ["bot3"])
        // The log says so.
        XCTAssertEqual(try WorkspaceStore(store: store).log("app").filter { $0.action == "worker-declared" }.map(\.agent), ["bot1", "bot2"])
    }

    func testAWorkerNeedsATaskAndNoRoomContradictsIt() async throws {
        let c = await daemon()
        var m = await send(c, .workspaceNew, request("lone") { $0.noRoom = true; $0.workers = ["x"] })
        XCTAssertEqual(m.error?.code, .invalid)
        XCTAssertTrue(m.error?.message.contains("--no-room") == true, m.error?.message ?? "")
        m = await send(c, .workspaceNew, request("lone") { $0.workers = ["  \n"] })
        XCTAssertEqual(m.error?.code, .invalid)
        XCTAssertFalse(WorkspaceStore(store: store).exists("lone"), "nothing made")
    }

    func testAWorkerIsDeclaredWithChatOffAndTheStartSaysWhatItNeeds() async throws {
        let c = await daemon(chat: false)
        let p = try await plan(c, request("quiet") { $0.workers = ["Fix the failing test"] })
        XCTAssertEqual(p.refusals, [], "declaring is intent: no room or chat needed at new")
        XCTAssertEqual(p.gaps.map(\.item), ["chat"], "the dry run already says what the start needs")
        let m = await send(c, .workspaceNew, request("quiet") { $0.workers = ["Fix the failing test"] })
        XCTAssertNil(m.error, m.error?.message ?? "")
        let rec = try XCTUnwrap(try WorkspaceStore(store: store).read("quiet"))
        XCTAssertEqual(rec.declaredWorkers.map(\.task), ["Fix the failing test"])
        let shown = try await show(c, "quiet")
        XCTAssertEqual(shown.gaps?.map(\.why), ["its declared worker needs chat"])
        // The start refuses as it does a manager with chat off (3, nothing done), and the worker stays declared.
        let s = await send(c, .workspaceStart, WorkspaceRequest(name: "quiet"))
        XCTAssertEqual(s.error?.code, .invalidPhase, s.error?.message ?? "")
        XCTAssertEqual(ExitCodes.exit(for: try XCTUnwrap(s.error)), 3)
        XCTAssertTrue(s.error?.message.contains("declared worker needs chat") == true, s.error?.message ?? "")
        let after = try XCTUnwrap(try WorkspaceStore(store: store).read("quiet"))
        XCTAssertNil(after.flags.startedAt, "nothing started")
        XCTAssertEqual(after.declaredWorkers.map(\.task), ["Fix the failing test"], "nothing dropped")
    }

    func testTheDeclaredWorkersRoundTripInTheRecordAndAnOlderOneHasNone() throws {
        let d = WorkspaceDeclaredWorker(name: "bot1", task: "t", declaredAt: Date(timeIntervalSince1970: 1_700_000_000))
        var rec = WorkspaceRecord(name: "a", createdAt: Date(timeIntervalSince1970: 1), brief: WorkspaceBrief(sha256: "", bytes: 0, updatedAt: Date(timeIntervalSince1970: 1)),
                                  folders: [])
        let none = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(rec)) as? [String: Any]
        XCTAssertNil(none?["declaredWorkers"], "written only while there is one")
        rec.declaredWorkers = [d]
        let back = try JSONDecoder().decode(WorkspaceRecord.self, from: try JSONEncoder().encode(rec))
        XCTAssertEqual(back.declaredWorkers, [d])
    }
}
