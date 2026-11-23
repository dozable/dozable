import Foundation
import XCTest
@testable import DozableHost

/// `WorkspaceLifecycle.plan` — pure: each verb against every kind of agent (a VM, fenced, unfenced, elsewhere, an adopted
/// sandbox, an adopted program that is no agent, a shared sandbox; a manager, an anonymous worker, a worker from a bot), the
/// queue at widths 1 and 3, the refusals (all at once, the first one's code), the Bin's refusals, and the sha (stable, blind
/// to order, sizes and activity; changed by what matters).
final class WorkspaceLifecycleTests: XCTestCase {
    typealias L = WorkspaceLifecycle
    typealias F = WorkspaceLifecycle.AgentFacts
    let t = Date(timeIntervalSince1970: 1_800_000_000)

    func agent(_ name: String, _ role: String, _ place: AgentPlace, isolation: String? = nil, task: String? = nil, anonymous: Bool? = nil,
               bot: String? = nil, stopped: Bool = false) -> WorkspaceAgent {
        var a = WorkspaceAgent(name: name, role: role, place: place, startedAt: t, bot: bot, isolation: isolation)
        a.task = task
        a.anonymous = anonymous
        if stopped { a.stoppedAt = t }
        return a
    }

    /// demo: a fenced manager, an anonymous fenced worker, a bot worker in a VM of its own, an unfenced worker, a VM worker
    /// sharing the adopted sandbox `lab`, the adopted sandbox `lab`, an adopted program on this Mac, and one elsewhere.
    func record(flags: WorkspaceFlags? = nil, rooms: Bool = true, folders: [String] = ["/work/demo"]) -> WorkspaceRecord {
        WorkspaceRecord(name: "demo", createdAt: t, brief: WorkspaceBrief(sha256: "x", bytes: 1, updatedAt: t),
                        folders: folders.map { WorkspaceFolder(path: $0, main: true) },
                        rooms: rooms ? [WorkspaceRoom(label: "main", chatRoom: "demo", main: true)] : [],
                        agents: [
                            agent("mira", "manager", .macSession("demo"), isolation: "fenced", bot: "mira"),
                            agent("bot1", "worker", .macSession("demo-bot1"), isolation: "fenced", task: "list", anonymous: true),
                            agent("otto", "worker", .sandbox("demo-otto"), isolation: "vm", task: "render", bot: "otto"),
                            agent("bot2", "worker", .macSession("demo-bot2"), isolation: "unfenced", task: "tidy", anonymous: true),
                            agent("bot3", "worker", AgentPlace(sandbox: "lab", session: "bot3"), isolation: "vm", task: "test", anonymous: true),
                            agent("lab", "worker", .sandbox("lab")),
                            agent("shell", "worker", .macSession("shell")),
                            agent("far", "worker", AgentPlace(elsewhere: "laptop")),
                        ],
                        flags: flags ?? WorkspaceFlags(startedAt: t))
    }

    func running() -> [String: F] {
        ["mira": F(now: .running, activity: "working", fenced: true, resumable: true),
         "bot1": F(now: .running, activity: "idle", fenced: true, resumable: true, secretKept: true),
         "otto": F(now: .running, resumable: true, memoryMiB: 4096, diskBytes: 6 << 30, points: 2),
         "bot2": F(now: .running, fenced: false, resumable: true),
         "bot3": F(now: .running, resumable: true, memoryMiB: 2048, diskBytes: 3 << 30, secretKept: true),
         "lab": F(now: .running, resumable: true, memoryMiB: 2048, diskBytes: 3 << 30),
         "shell": F(now: .running, fenced: false, resumable: false),
         "far": F(now: .elsewhere)]
    }

    func plan(_ v: WorkspaceVerb, _ rec: WorkspaceRecord? = nil, facts: [String: F]? = nil, chat: L.Chat = .ready, width: Int = 3,
              options: L.Options = L.Options(), busy: Bool = false, inUse: [String: String] = [:]) -> WorkspaceLifecyclePlan {
        L.plan(verb: v, record: rec ?? record(), state: "working",
               facts: L.Facts(agents: facts ?? running(), chat: chat, width: width, busy: busy, home: "/Users/ada", store: "/Users/ada/doz-store",
                              foldersInUse: inUse), options: options)
    }

    func row(_ p: WorkspaceLifecyclePlan, _ n: String) -> WorkspaceLifecycleRow? { p.rows.first { $0.name == n } }

    // MARK: each verb

    func testSleep() {
        let p = plan(.sleep)
        XCTAssertTrue(p.refusals.isEmpty, p.refusals.joined())
        XCTAssertEqual(row(p, "mira")?.after, "ended, its conversation kept")
        XCTAssertEqual(row(p, "mira")?.back, "resumes its conversation")
        XCTAssertEqual(row(p, "bot1")?.after, "ended, its conversation kept")
        XCTAssertEqual(row(p, "otto")?.after, "hibernated: its memory given back")
        XCTAssertEqual(row(p, "otto")?.back, "the same sessions and screens")
        XCTAssertEqual(row(p, "bot2")?.after, "ended, its conversation kept; its token file deleted")
        XCTAssertEqual(row(p, "bot2")?.back, "resumes its conversation, with a new token", "an anonymous unfenced worker's token lives only in its file")
        XCTAssertEqual(row(p, "shell")?.back, "starts fresh", "a program with no conversation starts fresh")
        XCTAssertEqual(row(p, "far")?.after, "untouched")
        XCTAssertEqual(row(p, "far")?.back, "runs on its own machine; Dozable cannot sleep it")
        XCTAssertFalse(row(p, "far")!.changes)
        XCTAssertEqual(p.confirm, "none")
        XCTAssertNil(p.confirmName)
        // bot3 and lab share the sandbox lab: one change, its memory counted once.
        XCTAssertEqual(row(p, "bot3")?.change, row(p, "lab")?.change)
        XCTAssertEqual(p.queue.changes, 6, "mira, bot1, otto, bot2, lab (with bot3), shell")
        XCTAssertEqual(p.goes.first?.bytes, Int64(4096 + 2048) << 20, "the memory given back: otto's and lab's once")
        XCTAssertTrue(p.commands.contains("doz hibernate lab") && p.commands.contains("doz sessions end @mac demo-bot1"))
        XCTAssertEqual(p.commands.filter { $0 == "doz hibernate lab" }.count, 1)
        XCTAssertEqual(p.command, "doz workspace sleep demo")
        XCTAssertTrue(p.notes.contains { $0.contains("stays asleep until you wake it") })
    }

    func testWake() {
        var f = running()
        for k in ["mira", "bot1", "bot2", "shell"] { f[k]?.now = .ended }
        f["otto"]?.now = .asleep
        f["lab"]?.now = .asleep
        f["bot3"]?.now = .asleep
        var rec = record()
        for i in rec.agents.indices { rec.agents[i].stoppedAt = t }
        let p = plan(.wake, rec, facts: f)
        XCTAssertTrue(p.refusals.isEmpty, p.refusals.joined())
        XCTAssertEqual(row(p, "mira")?.after, "running again, in the same conversation")
        XCTAssertEqual(row(p, "otto")?.after, "woken")
        XCTAssertEqual(row(p, "bot2")?.after, "running again, in the same conversation; a new token, in its file again")
        XCTAssertEqual(row(p, "shell")?.after, "running again, started fresh")
        XCTAssertEqual(row(p, "far")?.after, "untouched; stays in the room")
        XCTAssertTrue(p.commands.contains("doz workspace start demo"))
        XCTAssertTrue(p.commands.contains("doz sessions restart @mac demo-bot1"))
        // From a shut-down VM: a cold boot, its conversation continued; an anonymous worker whose secret went: a new token.
        f["bot3"]?.now = .off
        f["bot3"]?.secretKept = false
        f["otto"]?.now = .off
        let q = plan(.wake, rec, facts: f)
        XCTAssertEqual(row(q, "otto")?.after, "started: a cold boot, its agent continues its conversation")
        XCTAssertEqual(row(q, "bot3")?.after, "started: a cold boot, its agent continues its conversation, with a new token")
        // An adopted agent the person stopped themselves stays as it is.
        var rec2 = rec
        rec2.agents[rec2.agents.firstIndex { $0.name == "shell" }!].stoppedAt = nil
        XCTAssertEqual(row(plan(.wake, rec2, facts: f), "shell")?.changes, false)
        // An unfenced manager: said.
        var rec3 = rec
        rec3.agents[0].isolation = "unfenced"
        XCTAssertTrue(plan(.wake, rec3, facts: f).notes.contains("mira runs unfenced: it acts as you"))
    }

    /// 756 (D3): stop ends every agent's process — not only the manager's — and removes nothing; it asks a yes.
    func testStopStopsEveryAgentAndRemovesNothing() {
        let p = plan(.stop)
        XCTAssertTrue(p.refusals.isEmpty, p.refusals.joined())
        XCTAssertEqual(Set(p.rows.filter(\.changes).map(\.name)), ["mira", "bot1", "otto", "bot2", "bot3", "lab", "shell"])
        XCTAssertEqual(row(p, "mira")?.after, "stopped, its conversation kept")
        XCTAssertEqual(row(p, "bot1")?.after, "stopped, its conversation kept")
        XCTAssertEqual(row(p, "bot2")?.after, "stopped, its conversation kept; its token file deleted")
        XCTAssertEqual(row(p, "otto")?.after, "shut down, its disk kept", "a VM's process ends: shut down, not hibernated")
        XCTAssertTrue(row(p, "shell")?.after.hasPrefix("stopped") == true, "a program with no conversation: stopped")
        XCTAssertEqual(row(p, "far")?.after, "untouched; stays in the room")
        XCTAssertFalse(row(p, "far")!.changes)
        XCTAssertTrue(row(p, "mira")!.back.hasPrefix("doz workspace wake demo"))
        XCTAssertEqual(p.confirm, "yes")
        XCTAssertTrue(p.goes.isEmpty, "stop removes nothing")
        // 762 (F7): the person's folder is untouched, named apart — never under Kept.
        XCTAssertFalse(p.keeps.contains { $0.text.contains("folder") || $0.path != nil })
        XCTAssertEqual(p.untouched?.map(\.path), ["/work/demo"])
        XCTAssertTrue(p.commands.contains("doz shutdown demo-otto") && p.commands.contains("doz sessions end @mac demo-bot1"))
        XCTAssertFalse(p.commands.contains { $0.contains("hibernate") })
        XCTAssertEqual(p.command, "doz workspace stop demo")
        XCTAssertTrue(p.notes.contains { $0.contains("doz workspace manager stop demo") })
    }

    /// 756: a stop of a workspace that is asleep or stopped already changes nothing (harmless), and refuses nothing.
    func testStopOfAnAsleepOrStoppedWorkspaceChangesNothing() {
        var f = running()
        for k in ["mira", "bot1", "bot2", "shell"] { f[k]?.now = .ended }
        for k in ["otto", "lab", "bot3"] { f[k]?.now = .asleep }
        let p = plan(.stop, facts: f)
        XCTAssertTrue(p.refusals.isEmpty, p.refusals.joined())
        XCTAssertTrue(p.rows.allSatisfy { !$0.changes }, "an asleep VM is not shut down by stop: it stays asleep")
        XCTAssertEqual(row(p, "otto")?.after, "stays asleep")
        XCTAssertEqual(p.queue.changes, 0)
        XCTAssertTrue(p.notes.contains("nothing runs: nothing to stop"))
        // Finished: nothing runs, nothing refused.
        let q = plan(.stop, record(flags: WorkspaceFlags(finishedAt: t, startedAt: t)), facts: f)
        XCTAssertTrue(q.refusals.isEmpty && q.queue.changes == 0)
    }

    /// 756 (D4/D12): what a finish keeps, by name — folders by their absolute path, rooms room/NAME, agents agent/NAME,
    /// sandboxes sandbox/NAME — and what a person reads: a standing workspace says it removed nothing.
    func testTheFinishInventory() {
        let rec = record()
        let held = WorkspaceFinishInventory.held(rec)
        XCTAssertEqual(held.first, "/work/demo")
        XCTAssertTrue(held.contains("room/demo") && held.contains("agent/mira") && held.contains("sandbox/demo-otto") && held.contains("sandbox/lab"))
        XCTAssertEqual(held.filter { $0 == "sandbox/lab" }.count, 1, "a shared sandbox once")
        XCTAssertEqual(WorkspaceFinishInventory.kept(before: rec, removed: []), held, "nothing removed: everything kept (the --json contract)")
        XCTAssertEqual(WorkspaceFinishInventory.kept(before: rec, removed: ["room/demo"]).contains("room/demo"), false)
        // 762 (F7): the person's folder (not made by it) is untouched; the text never says it under "kept:".
        XCTAssertEqual(WorkspaceFinishInventory.untouched(rec), ["/work/demo"])
        var made = rec
        made.madeFolders = ["/work/demo"]
        XCTAssertEqual(WorkspaceFinishInventory.untouched(made), [], "a folder it made is its own")
        let lines = WorkspaceFinishInventory.lines(removed: [], kept: held, untouched: WorkspaceFinishInventory.untouched(rec), released: ["agent/far"],
                                                   standing: true, archive: nil)
        XCTAssertEqual(lines.first, "finished; nothing removed (standing)")
        XCTAssertTrue(lines[1].hasPrefix("kept: room/demo"), lines[1])
        XCTAssertFalse(lines[1].contains("/work/demo") || lines[1].contains("agent/far"), lines[1])
        XCTAssertEqual(lines[2], "released (loose again): agent/far")
        XCTAssertEqual(lines[3], "untouched (yours, not its own): /work/demo")
        XCTAssertTrue(WorkspaceFinishInventory.lines(removed: [], kept: held, standing: true, archive: nil)[1].hasPrefix("kept: /work/demo, room/demo"),
                      "without the split, as before")
        XCTAssertEqual(WorkspaceFinishInventory.lines(removed: ["/x/s"], kept: [], standing: false, archive: "a/b").first, "removed: /x/s")
    }

    func testFinish() {
        let p = plan(.finish)
        XCTAssertTrue(p.refusals.isEmpty)
        XCTAssertEqual(p.confirm, "yes")
        XCTAssertEqual(row(p, "otto")?.after, "shut down, its disk kept")
        XCTAssertEqual(row(p, "mira")?.after, "ended, its conversation kept")
        XCTAssertEqual(row(p, "bot2")?.after, "ended, its conversation kept; its token file deleted")
        XCTAssertEqual(row(p, "far")?.after, "untouched; stays in the room")
        // 0.52.15 (the owner's decision): finish closes the room it made — it was "you can still write" in 0.52.12.
        XCTAssertTrue(p.keeps.contains { $0.text.contains("members can read") })
        XCTAssertTrue(p.keeps.contains { $0.text == "every token (reopen works)" })
        XCTAssertEqual(p.rooms?.first?.after, "linked: not closed", "a room it does not own is not closed")
        XCTAssertTrue(p.goes.isEmpty, "nothing goes at a finish when no room is its own")
        XCTAssertTrue(p.commands.contains("doz shutdown demo-otto"))
        // Its own room: closed, the owner's line verbatim, and the sha covers it.
        var f = L.Facts(agents: running(), chat: .ready, home: "/Users/ada", store: "/Users/ada/doz-store")
        f.ownedRooms = ["demo"]
        let owned = L.plan(verb: .finish, record: record(), state: "working", facts: f, options: L.Options())
        XCTAssertEqual(owned.rooms?.first, WorkspaceLifecycleRoomRow(room: "demo", label: "main", owned: true,
                                                                     after: "closed: members can read it, posts refused"))
        XCTAssertTrue(owned.notes.contains("finish closes the room to new messages until you reopen"))
        XCTAssertTrue(owned.goes.contains { $0.text.contains("closed until you reopen") })
        XCTAssertNotEqual(owned.sha, p.sha)
        // --no-archive is part of the command and the sha.
        let off = plan(.finish, options: L.Options(noArchive: true))
        XCTAssertTrue(off.command.hasSuffix("--no-archive"))
        XCTAssertEqual(off.archive?.off, true)
        XCTAssertNotEqual(off.sha, p.sha)
    }

    func testReopenAndRestore() {
        let finished = record(flags: WorkspaceFlags(finishedAt: t, startedAt: t))
        var f = running()
        for k in f.keys where k != "far" { f[k]?.now = k == "otto" || k == "lab" || k == "bot3" ? .off : .ended }
        let p = plan(.reopen, finished, facts: f)
        XCTAssertTrue(p.refusals.isEmpty)
        XCTAssertTrue(p.rows.allSatisfy { !$0.changes })
        XCTAssertEqual(row(p, "mira")?.after, "asleep until you wake it")
        XCTAssertEqual(plan(.reopen, record(), facts: f).refusals, ["demo is not finished — nothing to reopen"])
        var archived = record(flags: WorkspaceFlags(finishedAt: t, archivedAt: t, startedAt: t))
        archived.flags.archive = WorkspaceArchive(rooms: ["demo"], removed: ["demo-otto"], templates: ["demo-otto": "demo-otto-tpl"])
        archived.agents[1].endedAt = t
        let r = plan(.restore, archived, facts: f)
        XCTAssertTrue(r.refusals.isEmpty, r.refusals.joined())
        XCTAssertTrue(r.notes.contains("retired workers stay ended: bot1"))
        XCTAssertTrue(r.notes.contains("demo-otto is gone — its disk is the image demo-otto-tpl"))
        XCTAssertEqual(plan(.restore, finished, facts: f).refusals, ["demo is not archived — nothing to restore"])
    }

    func testArchive() {
        let p = plan(.archive)
        XCTAssertEqual(p.confirm, "typed")
        XCTAssertEqual(p.confirmName, "demo")
        XCTAssertTrue(row(p, "bot1")!.after.contains("retired: its token is refused from now on"))
        XCTAssertFalse(row(p, "otto")!.after.contains("retired"), "a bot keeps its token")
        XCTAssertTrue(row(p, "otto")!.after.contains("otto keeps its token"))
        XCTAssertFalse(row(p, "otto")!.after.contains("removed"), "no disk goes without --remove-sandboxes")
        XCTAssertTrue(p.goes.contains { $0.text == "writing in #demo (archived: read-only)" })
        XCTAssertTrue(p.goes.contains { $0.text.contains("bot1, bot2, bot3") })
        XCTAssertNil(p.templates)
        // --remove-sandboxes: only the sandboxes Dozable made for it (otto's own), a template each first; never the adopted lab.
        let r = plan(.archive, options: L.Options(removeSandboxes: true))
        XCTAssertEqual(r.templates, ["demo-otto": "demo-otto-tpl"])
        XCTAssertTrue(row(r, "otto")!.after.contains("its disk saved as the image demo-otto-tpl; its sandbox removed"))
        // 757: today's command for it is `doz image save` (the `templates` key keeps its name).
        XCTAssertTrue(r.commands.contains("doz image save demo-otto demo-otto-tpl"), r.commands.joined(separator: " | "))
        XCTAssertFalse(r.commands.contains { $0.hasPrefix("doz template") })
        XCTAssertFalse(row(r, "lab")!.after.contains("removed"))
        XCTAssertFalse(row(r, "bot3")!.after.contains("sandbox removed"), "a worker sharing a sandbox never removes it")
        XCTAssertEqual(r.goes.first { $0.text.contains("demo-otto") }?.bytes, 6 << 30)
        XCTAssertEqual(r.command, "doz workspace archive demo --remove-sandboxes")
        let nt = plan(.archive, options: L.Options(removeSandboxes: true, keepTemplates: false))
        XCTAssertNil(nt.templates)
        XCTAssertEqual(nt.command, "doz workspace archive demo --remove-sandboxes --no-keep-templates")
        XCTAssertNotEqual(r.sha, p.sha, "the flags are part of the plan")
    }

    func testDelete() {
        let finished = record(flags: WorkspaceFlags(finishedAt: t, startedAt: t))
        var f = running()
        for k in f.keys where k != "far" { f[k]?.now = k == "otto" || k == "lab" || k == "bot3" ? .off : .ended }
        let p = plan(.delete, finished, facts: f)
        XCTAssertTrue(p.refusals.isEmpty, p.refusals.joined())
        XCTAssertEqual(p.confirm, "typed")
        XCTAssertEqual(row(p, "mira")?.after, "its session's record forgotten; mira keeps its token")
        XCTAssertEqual(row(p, "lab")?.after, "released: loose again, its disk kept")
        XCTAssertEqual(row(p, "shell")?.after, "released: loose again")
        XCTAssertEqual(row(p, "otto")?.after, "otto keeps its token; released: loose again, its disk kept")
        XCTAssertTrue(row(p, "bot1")!.after.hasPrefix("retired"))
        XCTAssertEqual(row(p, "far")?.after, "untouched; stays in the room")
        XCTAssertTrue(p.keeps.contains { $0.text == "every folder, untouched" })
        XCTAssertFalse(p.goes.contains { $0.path != nil }, "no folder goes without --bin-folders")
        XCTAssertTrue(p.notes.contains { $0.contains("doz chat room rm R removes a room for good") })
        // While anything runs: refused, naming them; not finished: refused.
        var g = f
        g["lab"]?.now = .running
        let q = plan(.delete, finished, facts: g)
        XCTAssertEqual(q.refusals, ["lab still runs — doz workspace finish demo stops it first"])
        XCTAssertEqual(q.refusalCode, "invalid-phase")
        XCTAssertEqual(plan(.delete).refusals.first, "demo is not finished — finish it first: doz workspace finish demo")
        // --bin-folders on a folder it did not make (/work/demo is the person's): kept, said with why; nothing goes (759).
        let b = plan(.delete, finished, facts: f, options: L.Options(binFolders: true))
        XCTAssertEqual(b.goes.compactMap(\.path), [])
        XCTAssertEqual(b.keeps.filter { $0.path != nil }.map(\.path), ["/work/demo"])
        XCTAssertTrue(b.notes.contains("no folder of it was made by demo: nothing goes to the Bin"), b.notes.joined(separator: "; "))
        XCTAssertEqual(b.command, "doz workspace delete demo --bin-folders")
    }

    // MARK: --bin-folders: only what the workspace made (759)

    /// The facts of a Mac whose `projects_dir` is /p, each folder resolving to itself unless `targets` says otherwise.
    func binFacts(_ folders: [String], targets: [String: String] = [:], inUse: [String: String] = [:]) -> L.Facts {
        var f = L.Facts(agents: running().mapValues { var x = $0; if x.now != .elsewhere { x.now = .off }; return x },
                        home: "/Users/ada", store: "/Users/ada/doz-store", foldersInUse: inUse)
        f.projectsDir = "/p"
        for p in folders { f.folderTargets[p] = p }
        for (k, v) in targets { f.folderTargets[k] = v }
        return f
    }

    func binRecord(_ folders: [String], made: [String]) -> WorkspaceRecord {
        var r = record(flags: WorkspaceFlags(finishedAt: t, startedAt: t), folders: folders)
        r.madeFolders = made
        return r
    }

    func binPlan(_ rec: WorkspaceRecord, _ f: L.Facts) -> WorkspaceLifecyclePlan {
        L.plan(verb: .delete, record: rec, state: "finished", facts: f, options: L.Options(binFolders: true))
    }

    func kept(_ p: WorkspaceLifecyclePlan) -> [String: String] {
        Dictionary(uniqueKeysWithValues: p.keeps.compactMap { k in k.path.map { ($0, k.text) } })
    }

    func testAnExternalFolderIsNeverBinnedAndIsSaidKept() {
        let rec = binRecord(["/p/demo", "/Users/ada/src/app", "/p/theirs"], made: ["/p/demo"])
        let p = binPlan(rec, binFacts(rec.folders.map(\.path)))
        XCTAssertTrue(p.refusals.isEmpty, p.refusals.joined())
        XCTAssertEqual(p.goes.compactMap(\.path), ["/p/demo"], "only the folder it made")
        XCTAssertEqual(kept(p)["/Users/ada/src/app"], "kept: not made by demo: your folder — never moved to the Bin")
        XCTAssertEqual(kept(p)["/p/theirs"], "kept: not made by demo: your folder — never moved to the Bin",
                       "under projects_dir is not enough: it must be recorded as made")
        XCTAssertEqual(L.binDecision("/Users/ada/src/app", record: rec, facts: binFacts(rec.folders.map(\.path))),
                       .keep("not made by demo: your folder — never moved to the Bin"))
        // A record from before 759 (no madeFolders): every folder kept — even <projects_dir>/NAME.
        let old = binRecord(["/p/demo"], made: [])
        XCTAssertEqual(binPlan(old, binFacts(["/p/demo"])).goes.compactMap(\.path), [])
    }

    func testAFolderItMadeIsBinnedAndAScratchFolderToo() {
        var rec = binRecord(["/p/demo", "/p/.runs/demo/r1/notes"], made: ["/p/demo"])
        var ref = SpaceRecordRef()
        ref.scratch = [.init(run: "r1", name: "notes", path: "/p/.runs/demo/r1/notes")]
        ref.persistedPaths = ["/p/demo-kept"]
        ref.store(in: &rec)
        rec.folders.append(WorkspaceFolder(path: "/p/demo-kept"))
        let f = binFacts(rec.folders.map(\.path))
        let p = binPlan(rec, f)
        XCTAssertEqual(Set(p.goes.compactMap(\.path)), ["/p/demo", "/p/.runs/demo/r1/notes"])
        XCTAssertTrue(p.goes.contains { $0.text == "moved to the Bin (made by demo)" })
        XCTAssertEqual(kept(p)["/p/demo-kept"], "kept: a kept folder of the space file (not recorded as made by demo) — never moved to the Bin",
                       "up makes a kept folder only when missing and does not record which: kept")
        XCTAssertEqual(L.binDecision("/p/demo", record: rec, facts: f), .bin)
    }

    func testAFolderSharedWithAnotherWorkspaceIsKept() {
        let rec = binRecord(["/p/demo", "/p/demo2"], made: ["/p/demo", "/p/demo2"])
        let f = binFacts(rec.folders.map(\.path), inUse: ["/p/demo": "the workspace other", "/p/demo2/sub": "the sandbox s1"])
        let p = binPlan(rec, f)
        XCTAssertTrue(p.refusals.isEmpty, "kept, not refused: \(p.refusals)")
        XCTAssertEqual(p.goes.compactMap(\.path), [])
        XCTAssertEqual(kept(p)["/p/demo"], "kept: used by the workspace other — never moved to the Bin while it is")
        XCTAssertEqual(kept(p)["/p/demo2"], "kept: used by the sandbox s1 — never moved to the Bin while it is", "one holding a folder in use")
    }

    func testALinkOrDotDotThatEscapesIsKept() {
        let rec = binRecord(["/p/demo", "/p/x/../../Users/ada/src", "/p/./demo3", "/elsewhere/demo4", "/p", "/p/gone"],
                            made: ["/p/demo", "/p/x/../../Users/ada/src", "/p/./demo3", "/elsewhere/demo4", "/p", "/p/gone"])
        var f = binFacts(rec.folders.map(\.path), targets: ["/p/demo": "/Users/ada/src"])
        f.folderTargets["/p/gone"] = nil
        let p = binPlan(rec, f)
        XCTAssertTrue(p.refusals.isEmpty, p.refusals.joined())
        XCTAssertEqual(p.goes.compactMap(\.path), [], "nothing goes")
        XCTAssertEqual(kept(p)["/p/demo"], "kept: it now leads to /Users/ada/src (a link) — never moved to the Bin")
        XCTAssertEqual(kept(p)["/p/x/../../Users/ada/src"], "kept: its path is not a plain absolute path — never moved to the Bin")
        XCTAssertEqual(kept(p)["/p/./demo3"], "kept: its path is not a plain absolute path — never moved to the Bin")
        XCTAssertEqual(kept(p)["/elsewhere/demo4"], "kept: outside the workspaces' folder /p — never moved to the Bin")
        XCTAssertEqual(kept(p)["/p"], "kept: outside the workspaces' folder /p — never moved to the Bin", "never projects_dir itself")
        XCTAssertEqual(kept(p)["/p/gone"], "kept: not there any more: nothing to move")
    }

    func testThePlanListsBinnedAndKeptAndItsShaFollows() {
        let rec = binRecord(["/p/demo", "/Users/ada/src/app"], made: ["/p/demo"])
        let f = binFacts(rec.folders.map(\.path))
        let p = binPlan(rec, f)
        XCTAssertEqual(p.goes.filter { $0.path != nil }.map { "\($0.path!) \($0.text)" }, ["/p/demo moved to the Bin (made by demo)"])
        XCTAssertEqual(p.keeps.filter { $0.path != nil }.map { "\($0.path!) \($0.text)" },
                       ["/Users/ada/src/app kept: not made by demo: your folder — never moved to the Bin"])
        XCTAssertFalse(p.keeps.contains { $0.text == "every folder, untouched" }, "with the flag, each folder is listed instead")
        // A made folder replaced by a link since: it moves from goes to keeps — a different plan.
        var g = f
        g.folderTargets["/p/demo"] = "/Users/ada"
        let q = binPlan(rec, g)
        XCTAssertEqual(q.goes.compactMap(\.path), [])
        XCTAssertNotEqual(q.sha, p.sha, "what goes changed: the plan's sha changes")
    }

    func testTheBinsRefusals() {
        let fin = WorkspaceFlags(finishedAt: t, startedAt: t)
        var f = running()
        for k in f.keys where k != "far" { f[k]?.now = .off }
        func refusals(_ folders: [String], inUse: [String: String] = [:]) -> [String] {
            plan(.delete, record(flags: fin, folders: folders), facts: f, options: L.Options(binFolders: true), inUse: inUse).refusals
        }
        XCTAssertEqual(refusals(["/Users/ada"]), ["/Users/ada is your home folder — never moved to the Bin"].map { $0.replacingOccurrences(of: "/Users/ada", with: DisplayPath.tilde("/Users/ada")) })
        XCTAssertTrue(refusals(["/Users"]).first?.contains("your home folder or holds it") == true)
        XCTAssertTrue(refusals(["/"]).first?.contains("the disk's root") == true)
        XCTAssertTrue(refusals(["/Users/ada/doz-store"]).first?.contains("Dozable's store") == true)
        XCTAssertTrue(refusals(["/Users/ada/doz-store/x"]).first?.contains("Dozable's store") == true)
        // A folder in use is KEPT (said why), never refused: testAFolderSharedWithAnotherWorkspaceIsKept (759).
        XCTAssertEqual(refusals(["/work/shared"], inUse: ["/work/shared": "the workspace other"]), [])
        XCTAssertEqual(refusals(["/work/mine"], inUse: ["/work/shared": "the workspace other"]), [])
        XCTAssertEqual(plan(.delete, record(flags: fin, folders: ["/work/mine"]), facts: f, options: L.Options(binFolders: true)).refusalCode, nil)
        XCTAssertEqual(plan(.delete, record(flags: fin, folders: ["/"]), facts: f, options: L.Options(binFolders: true)).refusalCode, "invalid")
    }

    // MARK: the refusals, the queue, the sha

    func testRefusalsAllAtOnceWithTheFirstsCode() {
        let p = plan(.archive, chat: .off, busy: true)
        XCTAssertEqual(p.refusals.count, 2)
        XCTAssertTrue(p.refusals[0].contains("busy"))
        XCTAssertEqual(p.refusals[1], "chat is off, and demo's rooms are archived as you — doz chat on")
        XCTAssertEqual(p.refusalCode, "invalid-phase")
        XCTAssertEqual(plan(.archive, chat: .off).refusalCode, "unavailable")
        XCTAssertTrue(plan(.archive, record(rooms: false), chat: .off).refusals.isEmpty, "no room: chat is not needed")
        let fin = record(flags: WorkspaceFlags(finishedAt: t, startedAt: t))
        XCTAssertEqual(plan(.sleep, fin).refusals, ["demo is finished — doz workspace reopen demo first"])
        XCTAssertEqual(plan(.finish, fin).refusals, ["demo is finished already — doz workspace reopen demo to work on it again"])
        XCTAssertEqual(plan(.wake, record(flags: WorkspaceFlags())).refusals, ["demo is still setting up — doz workspace start demo first"])
    }

    func testTheQueue() {
        let one = plan(.sleep, width: 1)
        XCTAssertEqual(one.queue.width, 1)
        XCTAssertEqual(one.queue.changes, 6)
        XCTAssertNotNil(one.queue.note)
        let three = plan(.sleep, width: 3)
        XCTAssertTrue(three.queue.note?.contains("at most 3 agents change at once") == true)
        var f = running()
        for k in ["bot1", "otto", "bot2", "bot3", "lab", "shell"] { f[k]?.now = .ended }
        f["otto"]?.now = .asleep; f["lab"]?.now = .asleep
        let few = plan(.sleep, facts: f, width: 3)
        XCTAssertEqual(few.queue.changes, 1)
        XCTAssertNil(few.queue.note)
        XCTAssertEqual(one.sha, three.sha, "the width is not part of what is done")
    }

    func testTheShaIsStableAndOrderIndependent() {
        let a = plan(.sleep)
        XCTAssertEqual(a.sha.count, 16)
        XCTAssertEqual(plan(.sleep).sha, a.sha)
        var shuffled = record()
        shuffled.agents.reverse()
        XCTAssertEqual(plan(.sleep, shuffled).sha, a.sha, "the agents' order does not matter")
        var f = running()
        f["mira"]?.activity = "idle"
        f["otto"]?.memoryMiB = 8192
        f["otto"]?.diskBytes = 1
        XCTAssertEqual(plan(.sleep, facts: f).sha, a.sha, "activity and sizes do not change it")
        f["bot1"]?.now = .ended
        XCTAssertNotEqual(plan(.sleep, facts: f).sha, a.sha, "an agent that stopped in between does")
        XCTAssertNotEqual(plan(.finish).sha, a.sha, "another verb is another plan")
        var rec = record()
        rec.agents.append(agent("bot9", "worker", .macSession("demo-bot9"), isolation: "fenced", task: "x", anonymous: true))
        XCTAssertNotEqual(plan(.sleep, rec).sha, a.sha, "a worker added in between changes it")
    }

    func testEndedWorkersHaveNoRow() {
        var rec = record()
        rec.agents[1].endedAt = t
        XCTAssertNil(row(plan(.sleep, rec), "bot1"))
    }
}
