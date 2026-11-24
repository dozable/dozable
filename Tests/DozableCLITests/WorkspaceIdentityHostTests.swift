import DozableChat
import Foundation
import XCTest
@testable import DozableKit
@testable import DozableHost

/// A kept memory as a capture writes it, in the store: `<store>/workspaces/W/memory/NAME/` with its manifest and one file.
func writeKeptMemory(store: DozableStore, workspace: String, name: String, text: String = "the build needs make first\n") throws -> String {
    let dir = WorkspaceStore.resolved(WorkspaceStore(store: store).folder(workspace)) + "/memory/" + name
    let rel = "projects/-work/memory/notes.md"
    let file = dir + "/" + rel
    try FileManager.default.createDirectory(atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try Data(text.utf8).write(to: URL(fileURLWithPath: file))
    let m = SpaceMemory.Manifest(isolation: "fenced", files: [.init(path: rel, sha256: WorkspaceStore.sha256(Data(text.utf8)))])
    try HostWire.prettyEncoder.encode(m).write(to: URL(fileURLWithPath: dir + "/" + SpaceMemory.manifestName))
    return dir
}

func fileSHA256(_ path: String) -> String? { (try? Data(contentsOf: URL(fileURLWithPath: path))).map { WorkspaceStore.sha256($0) } }

/// Workers as identities (776), in an in-process daemon core with the workers' fakes: a name given makes a lasting identity,
/// none a run-owned one (the add's answer says which); ending a lasting one's session keeps the identity — in the
/// participants, with its memory — and revokes its token; added again by its name it comes back as itself (its id, its
/// participant with a new token, its memory); ending a run-owned one removes it; `worker reset` clears only that identity's
/// kept memory, and is refused while its session runs; the listing and the state carry identities and sessions, never a token.
extension WorkspaceWorkerTests {
    func testANameGivenMakesALastingIdentityNoneARunOwnedOne() async throws {
        let c = await wcore()
        try await started(c)
        let named = try added(await wk(c, .workerAdd, "demo", "helper"))
        XCTAssertEqual(named.identity?.lifetime, "workspace")
        XCTAssertEqual(named.identity?.name, "helper")
        XCTAssertEqual(named.identity?.kind, "claude-code")
        XCTAssertNotNil(named.identity?.token?.issuedAt)
        XCTAssertEqual(named.identity?.memory.present, false)
        let unnamed = try added(await wk(c, .workerAdd, "demo"))
        XCTAssertEqual(unnamed.worker.name, "bot1")
        XCTAssertEqual(unnamed.identity?.lifetime, "run")
        let rec = try XCTUnwrap(record("demo"))
        XCTAssertEqual(rec.agents.first { $0.name == "helper" }?.lifetime, "workspace")
        XCTAssertEqual(rec.agents.first { $0.name == "bot1" }?.lifetime, "run")
        let listed = await wk(c, .workerList, "demo")
        let json = encoded(listed)
        let r1 = await wk(c, .workerList, "demo")
        let l = try XCTUnwrap(r1.result).decode(WorkerListing.self)
        XCTAssertEqual(l.agents.map(\.lifetime), ["workspace", "run"])
        XCTAssertEqual(l.identities?.map(\.name), ["helper", "bot1"])
        let token = try XCTUnwrap(itemOf("mac.demo-helper"))
        XCTAssertFalse(json.contains(token) || json.contains("dzc_"), "no token in the listing")
    }

    func testEndingALastingIdentityKeepsItWithItsMemoryAndItComesBackAsItself() async throws {
        let c = await wcore()
        try await started(c)
        _ = try added(await wk(c, .workerAdd, "demo", "helper"))
        let before = try XCTUnwrap(record("demo")?.agents.first { $0.name == "helper" })
        let firstHash = try XCTUnwrap(chat.hashes["helper"])
        let mem = try writeKeptMemory(store: store, workspace: "demo", name: "helper")
        let memSHA = fileSHA256(mem + "/projects/-work/memory/notes.md")
        // End: the session ends; the identity stays — in chat, with its memory — and its token is revoked.
        let m = await wk(c, .workerEnd, "demo", "helper")
        XCTAssertNil(m.error, m.error?.message ?? "")
        let ended = try XCTUnwrap(m.result).decode(WorkerEnded.self)
        XCTAssertTrue((ended.notes ?? []).contains { $0.contains("lasting identity of demo: kept, with its memory") }, (ended.notes ?? []).joined(separator: "; "))
        XCTAssertTrue(chat.dir.participants.contains { $0.name == "helper" }, "it stays a participant")
        XCTAssertNotNil(chat.hashes["helper"])
        XCTAssertNotEqual(chat.hashes["helper"], firstHash, "its token is revoked: replaced by one nobody holds")
        XCTAssertNil(itemOf("mac.demo-helper"), "no session holds its token")
        XCTAssertEqual(fileSHA256(mem + "/projects/-work/memory/notes.md"), memSHA, "its memory is kept")
        var rec = try XCTUnwrap(record("demo"))
        let e = try XCTUnwrap(rec.agents.first { $0.name == "helper" })
        XCTAssertNotNil(e.endedAt)
        XCTAssertNotNil(e.tokenRevokedAt)
        XCTAssertTrue(e.identityExists)
        let r2 = await wk(c, .workerList, "demo")
        let l = try XCTUnwrap(r2.result).decode(WorkerListing.self)
        XCTAssertTrue(l.agents.isEmpty, "no session runs")
        let id = try XCTUnwrap(l.identities?.first { $0.name == "helper" })
        XCTAssertFalse(id.hasSession)
        XCTAssertEqual(id.lifetime, "workspace")
        XCTAssertEqual(id.memory.present, true)
        XCTAssertEqual(id.memory.files, 1)
        XCTAssertEqual(id.memory.path, mem)
        XCTAssertNotNil(id.token?.revokedAt)
        // Added again by its name: itself — its id, its participant with a new token, its memory.
        let again = try added(await wk(c, .workerAdd, "demo", "helper"))
        XCTAssertEqual(again.identity?.id, before.id, "the same identity")
        XCTAssertEqual(again.identity?.memory.present, true)
        XCTAssertNil(again.identity?.token?.revokedAt)
        XCTAssertTrue((again.notes ?? []).contains { $0.contains("comes back as itself") })
        let token = try XCTUnwrap(itemOf("mac.demo-helper"))
        XCTAssertEqual(chat.hashes["helper"], ChatSecrets.hash(token), "its participant's token is the new one held")
        XCTAssertEqual(chat.dir.participants.filter { $0.name == "helper" }.count, 1)
        rec = try XCTUnwrap(record("demo"))
        XCTAssertEqual(rec.agents.filter { $0.name == "helper" }.count, 1)
        XCTAssertEqual(rec.agents.first { $0.name == "helper" }?.lifetime, "workspace")
        XCTAssertEqual(fileSHA256(mem + "/projects/-work/memory/notes.md"), memSHA)
    }

    func testALastingIdentityThatDoesNotComeBackStaysAsItWas() async throws {
        let c = await wcore()
        try await started(c)
        _ = try added(await wk(c, .workerAdd, "demo", "helper"))
        _ = await wk(c, .workerEnd, "demo", "helper")
        let before = try XCTUnwrap(record("demo")?.agents.first { $0.name == "helper" })
        workers.failLaunch = true
        let m = await wk(c, .workerAdd, "demo", "helper")
        XCTAssertNotNil(m.error)
        let after = try XCTUnwrap(record("demo")?.agents.filter { $0.name == "helper" })
        XCTAssertEqual(after, [before], "the identity as it was")
        XCTAssertTrue(chat.dir.participants.contains { $0.name == "helper" }, "its participant is never removed by a failed add")
    }

    func testEndingARunOwnedIdentityRemovesIt() async throws {
        let c = await wcore()
        try await started(c)
        _ = try added(await wk(c, .workerAdd, "demo"))
        let keep = work.appendingPathComponent("keep.txt").path
        try "the person's\n".write(toFile: keep, atomically: true, encoding: .utf8)
        let sha = fileSHA256(keep)
        let m = await wk(c, .workerEnd, "demo", "bot1")
        XCTAssertNil(m.error, m.error?.message ?? "")
        XCTAssertFalse(chat.dir.participants.contains { $0.name == "bot1" }, "the run's identity goes with its session")
        XCTAssertNil(chat.hashes["bot1"])
        let r3 = await wk(c, .workerList, "demo")
        let l = try XCTUnwrap(r3.result).decode(WorkerListing.self)
        XCTAssertEqual(l.identities ?? [], [], "no identity left")
        XCTAssertEqual(fileSHA256(keep), sha, "the workspace's folder is untouched")
    }

    func testWorkerResetClearsOnlyThatIdentitysKeptMemory() async throws {
        let c = await wcore()
        try await started(c)
        _ = try added(await wk(c, .workerAdd, "demo", "helper"))
        _ = try added(await wk(c, .workerAdd, "demo", "scout"))
        let mem = try writeKeptMemory(store: store, workspace: "demo", name: "helper")
        let other = try writeKeptMemory(store: store, workspace: "demo", name: "scout")
        let keep = work.appendingPathComponent("keep.txt").path
        try "the person's\n".write(toFile: keep, atomically: true, encoding: .utf8)
        // Refused while its session runs; nothing removed.
        var m = await wk(c, .workerReset, "demo", "helper")
        XCTAssertEqual(m.error?.code, .invalidPhase)
        XCTAssertTrue(FileManager.default.fileExists(atPath: mem))
        // An unknown name, a run-owned identity.
        m = await wk(c, .workerReset, "demo", "nobody")
        XCTAssertEqual(m.error?.code, .notFound)
        _ = try added(await wk(c, .workerAdd, "demo"))
        m = await wk(c, .workerReset, "demo", "bot1")
        XCTAssertEqual(m.error?.code, .invalid)
        // Its session ended: cleared — only its own folder.
        _ = await wk(c, .workerEnd, "demo", "helper")
        m = await wk(c, .workerReset, "demo", "helper")
        XCTAssertNil(m.error, m.error?.message ?? "")
        XCTAssertEqual(try XCTUnwrap(m.result).decode(WorkerEnded.self).removed, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: mem))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other + "/" + SpaceMemory.manifestName), "another identity's memory is kept")
        XCTAssertTrue(FileManager.default.fileExists(atPath: keep), "the workspace's folder is untouched")
        XCTAssertTrue(try WorkspaceStore(store: store).log("demo").contains { $0.action == "memory-reset" && $0.agent == "helper" })
        // Again: nothing to reset.
        m = await wk(c, .workerReset, "demo", "helper")
        XCTAssertEqual(try XCTUnwrap(m.result).decode(WorkerEnded.self).removed, false)
        // Never for an agent: the owner's own.
        XCTAssertEqual(ActionClasses.classify(HostRequest(.workerReset)), .dozableOwn)
        XCTAssertFalse(HostOp.workerReset.isReadOnly)
    }

    func testTheStateCarriesIdentitiesAndSessionsAndNoToken() async throws {
        let c = await wcore()
        try await started(c)
        _ = try added(await wk(c, .workerAdd, "demo", "helper"))
        _ = try added(await wk(c, .workerAdd, "demo"))
        _ = await wk(c, .workerEnd, "demo", "bot1")
        _ = try writeKeptMemory(store: store, workspace: "demo", name: "helper")
        let m = await ws(c, .workspaceState, "demo") { $0.withConditions = true }
        XCTAssertNil(m.error, m.error?.message ?? "")
        let s = try XCTUnwrap(m.result).decode(SpaceState.self)
        XCTAssertEqual(s.identities?.map(\.name), ["helper"], "bot1 was the run's: gone with its session")
        XCTAssertEqual(s.identities?.first?.lifetime, "workspace")
        XCTAssertEqual(s.identities?.first?.memory.present, true)
        XCTAssertEqual(s.sessions?.map(\.identity), ["helper"])
        let answer = String(decoding: ChatJSON.encodeIndented(s.stateAnswer(), indent: "  "), as: UTF8.self)
        XCTAssertTrue(answer.contains("\"identities\"") && answer.contains("\"sessions\"") && answer.contains("\"issuedAt\""))
        XCTAssertTrue(answer.contains("\"agents\""), "the agents view stays for one release")
        let token = try XCTUnwrap(itemOf("mac.demo-helper"))
        XCTAssertFalse(answer.contains(token) || answer.contains("dzc_"), "never a token")
        XCTAssertFalse(answer.contains("the build needs make first"), "never the memory's content")
        // show: its identities too.
        let r4 = await ws(c, .workspaceShow, "demo")
        let d = try XCTUnwrap(r4.result).decode(WorkspaceDetail.self)
        XCTAssertEqual(d.identities?.map(\.name), ["helper"])
        XCTAssertEqual(d.agents.first { $0.name == "helper" }?.lifetime, "workspace")
    }
}

/// The lifecycle and identities (776): each start rotates a daemon-made token (seen as its time); `down` (finish, for a
/// workspace made without a space file) keeps every lasting identity and its memory, revokes its token and ends the run's
/// identities — removing nothing on disk; `--purge` removes only what Dozable keeps of its lasting identities (their memory,
/// after its copy in the archive verifies) and retires them — never the workspace's folder, another workspace's memory or
/// a bot's token.
extension WorkspaceLifecycleHostTests {
    func addNamed(_ c: HostCore, _ name: String) async throws {
        var w = WorkerRequest(workspace: "demo", name: name)
        w.task = "work on the project"
        var r = HostRequest(.workerAdd)
        r.workerRequest = w
        let a = await c.handle(r)
        XCTAssertNil(a.error, a.error?.message ?? "")
    }

    func testEachStartIssuesANewToken() async throws {
        let c = await lcore()
        try await started(c)
        try await addNamed(c, "helper")
        let issued = try XCTUnwrap(record()?.agents.first { $0.name == "helper" }?.tokenIssuedAt)
        let hash = try XCTUnwrap(chat.hashes["helper"])
        _ = try ok(try await act(c, .stop))
        try await Task.sleep(for: .milliseconds(1100))
        let s = await ws(c, .workspaceStart, "demo")
        XCTAssertNil(s.error, s.error?.message ?? "")
        let now = try XCTUnwrap(record()?.agents.first { $0.name == "helper" && $0.endedAt == nil })
        XCTAssertGreaterThan(try XCTUnwrap(now.tokenIssuedAt), issued, "a new token's time")
        XCTAssertNotEqual(chat.hashes["helper"], hash, "the old token is refused")
        XCTAssertEqual(chat.hashes["otto"].map { _ in true }, true, "a bot keeps its own token")
        let o = try XCTUnwrap(workers.orders.last { $0.name == "helper" })
        XCTAssertTrue(o.restart)
        XCTAssertNotNil(o.plan.secret, "the new token is given to its session")
    }

    func testDownKeepsTheLastingIdentitiesAndTheirMemoryAndEndsTheRuns() async throws {
        let c = await lcore()
        try await started(c)                          // mira (manager), bot1 (the run's), otto (a bot)
        try await addNamed(c, "helper")
        let mem = try writeKeptMemory(store: store, workspace: "demo", name: "helper")
        let memSHA = fileSHA256(mem + "/projects/-work/memory/notes.md")
        let keep = work.appendingPathComponent("keep.txt").path
        try "the person's\n".write(toFile: keep, atomically: true, encoding: .utf8)
        let keepSHA = fileSHA256(keep)
        let helperHash = try XCTUnwrap(chat.hashes["helper"])
        let ottoHash = chat.hashes["otto"]
        let p = try await plan(c, .finish)
        XCTAssertTrue(p.goes.contains { $0.text.hasPrefix("the run's identities bot1") }, p.goes.map(\.text).joined(separator: " | "))
        XCTAssertTrue(p.keeps.contains { $0.text.contains("lasting identities") && $0.text.contains("helper") })
        let f = try ok(try await act(c, .finish))
        XCTAssertEqual(f.removed, ["agent/bot1"], "the run's identity; nothing on disk")
        XCTAssertTrue(try XCTUnwrap(f.kept).contains("agent/helper"))
        XCTAssertNil(f.purged)
        // The run's identity: gone. The lasting one: kept, its memory untouched, its token revoked. The bot's: its own.
        XCTAssertFalse(chat.dir.participants.contains { $0.name == "bot1" })
        XCTAssertTrue(chat.dir.participants.contains { $0.name == "helper" })
        XCTAssertNotEqual(chat.hashes["helper"], helperHash, "revoked at down")
        XCTAssertEqual(chat.hashes["otto"], ottoHash)
        XCTAssertNotNil(try XCTUnwrap(record()).agents.first { $0.name == "helper" }?.tokenRevokedAt)
        XCTAssertEqual(fileSHA256(mem + "/projects/-work/memory/notes.md"), memSHA, "its memory is kept")
        XCTAssertEqual(fileSHA256(keep), keepSHA, "the workspace's folder is untouched")
        XCTAssertTrue(FileManager.default.fileExists(atPath: work.path))
        XCTAssertFalse(trace.all.contains { $0.hasPrefix("rm ") || $0.hasPrefix("forget ") }, trace.all.joined(separator: ", "))
        XCTAssertTrue(log().contains("tokens-revoked"))
        // The next run: helper back, with a new token; bot1 is not (it was the last run's).
        _ = try ok(try await act(c, .reopen))
        let s = await ws(c, .workspaceStart, "demo")
        XCTAssertNil(s.error, s.error?.message ?? "")
        let rec = try XCTUnwrap(record())
        XCTAssertNil(rec.agents.first { $0.name == "helper" && $0.endedAt == nil }?.tokenRevokedAt, "a new token at its start")
        XCTAssertFalse(rec.agents.contains { $0.name == "bot1" && $0.endedAt == nil })
    }

    func testPurgeRemovesOnlyWhatItOwnsAfterItsCopyVerifies() async throws {
        let c = await lcore()
        try await started(c)
        try await addNamed(c, "helper")
        let mem = try writeKeptMemory(store: store, workspace: "demo", name: "helper")
        // Another workspace's identity of the same name, and the person's folder: never touched.
        let otherMem = try writeKeptMemory(store: store, workspace: "other", name: "helper", text: "another workspace's\n")
        let otherSHA = fileSHA256(otherMem + "/projects/-work/memory/notes.md")
        let keep = work.appendingPathComponent("keep.txt").path
        try "the person's\n".write(toFile: keep, atomically: true, encoding: .utf8)
        let keepSHA = fileSHA256(keep)
        let ottoToken = item("otto")
        let p = try await plan(c, .finish) { $0.purge = true }
        XCTAssertTrue(p.goes.contains { $0.text.contains("(--purge)") && $0.text.contains("helper") }, p.goes.map(\.text).joined(separator: " | "))
        XCTAssertEqual(p.command, "doz workspace down demo --purge")
        let plain = try await plan(c, .finish)
        XCTAssertNotEqual(plain.sha, p.sha, "the purge is in the plan's sha")
        let f = try ok(try await act(c, .finish) { $0.purge = true })
        XCTAssertEqual(f.purged, ["agent/helper"], "helper retired (mira, a bot, has no memory kept: nothing of it purged)")
        XCTAssertFalse(try XCTUnwrap(f.kept).contains("agent/helper"))
        // Its memory: gone from the store — but its copy is in the archive, and verifies.
        XCTAssertFalse(FileManager.default.fileExists(atPath: mem))
        let run = try XCTUnwrap(f.run)
        let copy = WorkspaceStore.resolved(store.root.path) + "/archives/demo/folders/\(run)/memory-helper"
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy + "/manifest.json"), "the copy is kept")
        XCTAssertTrue(RunArchive.verify(root: copy).problems.isEmpty, "the copy verifies")
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy + "/files/projects/-work/memory/notes.md"))
        // Retired: out of chat, its session ended; never the person's folder, another workspace's memory or a bot's token.
        XCTAssertFalse(chat.dir.participants.contains { $0.name == "helper" })
        let h = try XCTUnwrap(record()?.agents.first { $0.name == "helper" })
        XCTAssertNotNil(h.retiredAt)
        XCTAssertNotNil(h.endedAt)
        XCTAssertFalse(h.identityExists)
        XCTAssertEqual(fileSHA256(keep), keepSHA, "the workspace's folder is untouched")
        XCTAssertEqual(fileSHA256(otherMem + "/projects/-work/memory/notes.md"), otherSHA, "another workspace's memory is untouched")
        XCTAssertEqual(item("otto"), ottoToken, "a bot keeps its token")
        XCTAssertTrue(chat.dir.participants.contains { $0.name == "otto" })
        XCTAssertTrue(log().contains("identity-retired"))
    }

    /// A copy that does not verify (here: the archive's folder is not the store's — a file where it must be) keeps the
    /// memory, and the identity is not retired.
    func testAPurgeWhoseCopyFailsKeepsTheMemory() async throws {
        let c = await lcore()
        try await started(c)
        try await addNamed(c, "helper")
        let mem = try writeKeptMemory(store: store, workspace: "demo", name: "helper")
        let archives = WorkspaceStore.resolved(store.root.path) + "/archives"
        try FileManager.default.createDirectory(atPath: archives + "/demo", withIntermediateDirectories: true)
        try Data("not a folder".utf8).write(to: URL(fileURLWithPath: archives + "/demo/folders"))
        let f = try ok(try await act(c, .finish) { $0.purge = true; $0.noArchive = true })
        XCTAssertEqual(f.purged, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: mem + "/" + SpaceMemory.manifestName), "kept: its copy could not be made")
        XCTAssertTrue((f.notes ?? []).contains { $0.contains("helper's memory is kept") }, (f.notes ?? []).joined(separator: "; "))
        XCTAssertNil(try XCTUnwrap(record()).agents.first { $0.name == "helper" }?.retiredAt)
    }
}
