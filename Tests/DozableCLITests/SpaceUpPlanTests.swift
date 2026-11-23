import DozableChat
import Foundation
import XCTest
@testable import DozableHost
@testable import DozableCLI

/// `up`'s plan (`SpaceIntent.compile`, `SpaceUp.plan`, `workspace-up-plan`): pure and acting on nothing. The v3 examples'
/// facts against the reference's recorded outputs (`Fixtures/space3/fixtures-v3`: the same resources, external or owned
/// and their lifetimes, the risky settings with the same source file and line, the same refusals — compared as facts,
/// never bytes: the wording is Dozable's); every unfenced agent confirmed whatever set it; a workspace made without a file
/// refused; a second plan in an open run skips what is there; the daemon's own checks (strict, capped, the backstop); the
/// in-process answer with no daemon.
final class SpaceUpPlanTests: BotTestCase {
    static let examples = SpaceResolverTests.recorded.appendingPathComponent("spaces")
    let home = NSHomeDirectory()

    struct Read {
        var resolved: SpaceResolver.Resolved
        var intent: SpaceIntent
        var specSHA: String
    }

    func read(_ path: String, profiles: [String] = []) throws -> Read {
        let r = SpaceResolver().resolve(path)
        let (problems, model) = r.check(profiles: profiles)
        XCTAssertFalse(problems.contains(where: \.isError), "\(problems.map(\.text))")
        let doc = r.filled
        let intent = SpaceIntent.compile(try XCTUnwrap(model), doc, r.locator)
        return Read(resolved: r, intent: intent, specSHA: SpaceDoc.sha256(SpaceDoc.text(doc)))
    }

    /// This Mac as the reference recorded it: the bot manager, the room general, the repository of example-space; no
    /// sandbox-team repository.
    func recordedFacts(_ i: SpaceIntent) -> SpaceFacts {
        var f = SpaceFacts(known: true, home: home, projectsDir: home + "/doz-workspaces", owner: "ada", chatOn: true)
        f.bots["manager"] = .init(exists: true)
        f.rooms = ["general"]
        f.folders[home + "/work/example-repo"] = true
        f.folders[home + "/work/throwaway/sandbox-team"] = false
        return f
    }

    func plan(_ space: String) throws -> (SpacePlan, Read) {
        let r = try read(Self.examples.appendingPathComponent("\(space).space.yaml").path)
        return (SpaceUp.plan(r.intent, facts: recordedFacts(r.intent), specSHA: r.specSHA, sources: r.resolved.sources), r)
    }

    /// The reference's `[kind:name · lifetime]` tags, as `kind:name lifetime` (its `space` lifetime is our `persisted`;
    /// its chat members, token folders, trust records and by-hand steps are parts of Dozable's own operations).
    func referenceResources(_ space: String) throws -> Set<String> {
        let (out, _) = try SpaceResolverTests.recordedOutput(space, "plan")
        var set = Set<String>()
        let re = try NSRegularExpression(pattern: "\\[(check|agent|room|sandbox|folder):([a-z0-9-]+) · (external|run|space)\\]")
        for m in re.matches(in: out, range: NSRange(out.startIndex..., in: out)) {
            let g = { (i: Int) in String(out[Range(m.range(at: i), in: out)!]) }
            set.insert("\(g(1)):\(g(2)) \(g(3) == "space" ? "persisted" : g(3))")
        }
        return set
    }

    /// Ours, in the same terms.
    func ourResources(_ i: SpaceIntent) -> Set<String> {
        var set = Set<String>()
        for x in i.folders { set.insert(x.path != nil ? "check:\(x.name) external" : "folder:\(x.name) \(x.persisted == nil ? "run" : "persisted")") }
        for a in i.agents { set.insert(a.external ? "check:\(a.name) external" : "agent:\(a.name) run") }
        for r in i.rooms { set.insert(r.external ? "check:\(r.name) external" : "room:\(r.name) \(r.persisted == nil ? "run" : "persisted")") }
        for s in i.sandboxes { set.insert(s.external ? "check:\(s.name) external" : "sandbox:\(s.name) \(s.persisted == nil ? "run" : "persisted")") }
        return set
    }

    func testTheExamplesHaveTheReferencesResourcesAndLifetimes() throws {
        for s in SpaceResolverTests.spaces {
            let (p, r) = try plan(s)
            XCTAssertEqual(ourResources(r.intent), try referenceResources(s), s)
            XCTAssertEqual(try SpaceResolverTests.recordedOutput(s, "plan").exit, 0)
            XCTAssertNotNil(p.intent)
        }
    }

    func testTheRiskySettingsNameTheSameSources() throws {
        for s in SpaceResolverTests.spaces {
            let (p, _) = try plan(s)
            let (out, _) = try SpaceResolverTests.recordedOutput(s, "plan")
            let summary = p.summary.joined(separator: "\n")
            // Every "FILE:LINE" the reference's summary names, ours names too.
            let re = try NSRegularExpression(pattern: "[a-z_.-]+\\.yaml:[0-9]+")
            let theirs = Set(re.matches(in: out, range: NSRange(out.startIndex..., in: out)).map { String(out[Range($0.range, in: out)!]) })
            let ours = Set(re.matches(in: summary, range: NSRange(summary.startIndex..., in: summary)).map { String(summary[Range($0.range, in: summary)!]) })
            XCTAssertTrue(theirs.isSubset(of: ours), "\(s): \(theirs.subtracting(ours)) missing from\n\(summary)")
        }
        let (iso, _) = try plan("example-space")
        let summary = iso.summary.joined(separator: "\n")
        XCTAssertTrue(summary.contains("1 unfenced bypass agent with full access to your user (worker: unfenced from example-space.space.yaml:20, bypass from my_doz_workspace_defaults.yaml:6"), summary)
        XCTAssertTrue(summary.contains("Transcripts: kept for worker (persisted: the next run continues them)."), summary)
        XCTAssertEqual(iso.confirm, ["worker"])
        let (clean, _) = try plan("clean-room")
        XCTAssertTrue(clean.summary.contains { $0.hasPrefix("Archive: off (from clean-room.space.yaml:8)") }, "\(clean.summary)")
        XCTAssertTrue(clean.summary.contains { $0.hasPrefix("A clean room") })
        XCTAssertEqual(clean.confirm, [])
    }

    /// The reference's up --dry-run: example-space and clean-room pass their checks; sandbox-team stops before
    /// changing anything, its external repository missing. Dozable's code for that refusal is not-found (exit 2).
    func testTheDryRunsRefusalsAndExitCodes() throws {
        for s in ["example-space", "clean-room"] {
            let (p, _) = try plan(s)
            XCTAssertEqual(try SpaceResolverTests.recordedOutput(s, "up-dry-run").exit, 0)
            XCTAssertEqual(p.refusals, [], s)
            XCTAssertNil(p.refusalCode, s)
            XCTAssertFalse(p.steps.contains { $0.action == "refuse" }, s)
        }
        let (team, _) = try plan("sandbox-team")
        let (out, exit) = try SpaceResolverTests.recordedOutput("sandbox-team", "up-dry-run")
        XCTAssertEqual(exit, 1)
        XCTAssertTrue(out.contains("~/work/throwaway/sandbox-team doesn't exist") && out.contains("nothing was changed"))
        XCTAssertEqual(team.refusals, ["folder repo: ~/work/throwaway/sandbox-team doesn't exist"])
        XCTAssertEqual(team.refusalCode, HostError.Code.notFound.rawValue)
        XCTAssertEqual(DozableExit.code(for: HostError(.notFound, "")), 2)
        XCTAssertEqual(team.steps.first { $0.subject == "folder repo" }?.action, "refuse")
        // Its two sandboxed agents share one new sandbox, made by the first; the reviewer is in a profile, left out.
        let adds = team.steps.filter { $0.kind == "worker-add" }
        XCTAssertEqual(adds.map(\.subject), ["agent builder", "agent tester"])
        XCTAssertEqual(adds[0].worker?.isolation, "vm")
        XCTAssertEqual(adds[0].worker?.cpus, 2)
        XCTAssertEqual(adds[1].worker?.sandbox, "sandbox-team-build-vm")
        XCTAssertEqual(adds.map(\.permissionMode), ["bypass", "bypass"])
        XCTAssertTrue(team.notes.contains { $0.contains("reviewer is only in profile review") })
        // With --profile review the reviewer comes in, and its preset is one Dozable does not hold yet.
        let r = try read(Self.examples.appendingPathComponent("sandbox-team.space.yaml").path, profiles: ["review"])
        XCTAssertTrue(r.intent.refusals.contains { $0.message.contains("permissions: auto is not a preset Dozable holds yet") })
        XCTAssertEqual(r.intent.requests.map(\.agent), ["reviewer"])
    }

    func testUnfencedIsConfirmedWhateverSetItAndTheSHAIsStable() throws {
        let (a, _) = try plan("example-space")
        let (b, _) = try plan("example-space")
        XCTAssertEqual(a.sha, b.sha)
        XCTAssertEqual(a.sha.count, 64)
        let (c, _) = try plan("clean-room")
        XCTAssertNotEqual(a.sha, c.sha)
        let unfenced = try XCTUnwrap(a.steps.first { $0.subject == "agent worker" })
        XCTAssertEqual(unfenced.worker?.isolation, "unfenced")
        XCTAssertEqual(unfenced.permissionMode, "bypass")
    }

    func record(_ name: String, space: Bool) -> WorkspaceRecord {
        var rec = WorkspaceRecord(name: name, createdAt: Date(), brief: WorkspaceBrief(refs: [], sha256: "", bytes: 0, updatedAt: Date()), folders: [])
        if space { rec.unknown.extra["space"] = .object(["file": .string("\(name).space.yaml")]) }
        return rec
    }

    func testAWorkspaceMadeWithoutASpaceFileIsRefused() throws {
        let (_, r) = try plan("clean-room")
        var f = recordedFacts(r.intent)
        f.record = record("clean-room", space: false)
        let p = SpaceUp.plan(r.intent, facts: f, specSHA: r.specSHA, sources: [])
        XCTAssertEqual(p.refusalCode, HostError.Code.exists.rawValue)
        XCTAssertTrue(p.refusals[0].contains("made without a space file"))
        // One the file made is edited, not made again.
        f.record = record("clean-room", space: true)
        let q = SpaceUp.plan(r.intent, facts: f, specSHA: r.specSHA, sources: [])
        XCTAssertNil(q.refusalCode)
        XCTAssertFalse(q.steps.contains { $0.kind == "workspace-new" })
        XCTAssertTrue(q.steps.contains { $0.kind == "workspace-edit" })
    }

    /// 765: `up --no-run` — the agents start, no run opens: a down space is reopened with no run, a new one started with
    /// none; the plan (and its sha) says so; a scratch folder, which lives in a run, refuses it.
    func testNoRunOpensNoRun() throws {
        let (_, r) = try plan("clean-room")
        var f = recordedFacts(r.intent)
        let fresh = SpaceUp.plan(r.intent, facts: f, specSHA: r.specSHA, sources: [], noRun: true)
        let normal = SpaceUp.plan(r.intent, facts: f, specSHA: r.specSHA, sources: [])
        XCTAssertNotEqual(fresh.sha, normal.sha)
        XCTAssertTrue(fresh.steps.contains { $0.kind == "workspace-start" && $0.text.contains("no run (--no-run)") }, fresh.steps.map(\.text).joined(separator: "\n"))
        XCTAssertTrue(normal.steps.contains { $0.kind == "workspace-start" && $0.text.contains("open a new run") })
        var rec = record("clean-room", space: true)
        rec.flags.startedAt = Date()
        rec.flags.finishedAt = Date()
        rec.runs = [WorkspaceRun(id: "2026-11-20-1", startedAt: Date(), rooms: [])]
        rec.runs[0].endedAt = Date()
        f.record = rec
        let down = SpaceUp.plan(r.intent, facts: f, specSHA: r.specSHA, sources: [], noRun: true)
        XCTAssertTrue(down.steps.contains { $0.kind == "workspace-reopen" && $0.text.contains("with no run (--no-run)") })
        let scratch = r.intent.folders.contains { $0.path == nil && $0.persisted == nil }
        XCTAssertEqual(down.refusals.contains { $0.contains("--no-run: the scratch folder") }, scratch)
    }

    func testAnOpenRunIsAttachedToAndALiveWorkerSkipped() throws {
        let (_, r) = try plan("clean-room")
        var f = recordedFacts(r.intent)
        var rec = record("clean-room", space: true)
        rec.runs = [WorkspaceRun(id: "2026-11-20-1", startedAt: Date(), rooms: [])]
        var w = WorkspaceAgent(name: "worker", role: "worker", place: AgentPlace(mac: true, session: "clean-room-worker"), startedBy: "doz", startedAt: Date())
        w.task = "x"
        rec.agents = [w]
        f.record = rec
        let p = SpaceUp.plan(r.intent, facts: f, specSHA: r.specSHA, sources: [])
        XCTAssertEqual(p.steps.first { $0.kind == "workspace-start" }?.action, "skip")
        XCTAssertEqual(p.steps.first { $0.kind == "worker-add" }?.action, "skip")
    }

    func testTheOwnerMustBeThisMacsOwner() throws {
        let (_, r) = try plan("clean-room")
        var f = recordedFacts(r.intent)
        f.owner = "someone"
        let p = SpaceUp.plan(r.intent, facts: f, specSHA: r.specSHA, sources: [])
        XCTAssertTrue(p.refusals.contains { $0.contains("owner: ada is not this Mac's owner") })
    }

    /// The daemon never trusts the CLI: an unknown field and an oversize request are refused, and anything that starts
    /// or owns something with a defaults file as its origin is refused by the backstop.
    func testTheDaemonsOwnChecks() throws {
        let r = try read(Self.examples.appendingPathComponent("clean-room.space.yaml").path)
        var q = r.resolved.request(profiles: [], brief: nil)
        XCTAssertNoThrow(try q.check())
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(q)) as! [String: Any]
        json["extra"] = 1
        XCTAssertThrowsError(try JSONDecoder().decode(SpaceRequest.self, from: JSONSerialization.data(withJSONObject: json)))
        q.spec = String(repeating: " ", count: SpaceRequest.maximumBytes) + q.spec
        XCTAssertThrowsError(try q.check()) { XCTAssertTrue("\($0)".contains("at most 256 KiB")) }
        // The backstop: an agent whose origin is a defaults file.
        var sources = r.resolved.sources
        sources.append(SpaceSource(path: "/x/d.yaml", name: "d.yaml", kind: "defaults", sha256: ""))
        var origins = r.resolved.origins
        origins["/agents/worker"] = SpaceOrigin(s: sources.count - 1, l: 3, k: 3)
        let checked = SpaceValidator.checkMerged(r.resolved.filled, SpaceLocator(sources: sources, origins: origins))
        XCTAssertTrue(checked.problems.contains { $0.isError && $0.pointer == "/agents/worker" && $0.message.contains("comes from the defaults file d.yaml") },
                      "\(checked.problems.map(\.text))")
    }

    /// With no daemon: answered by a read-only core, `factsKnown` false, nothing written to the store.
    func testNoDaemonAnswersInProcessAndWritesNothing() async throws {
        let r = try read(Self.examples.appendingPathComponent("clean-room.space.yaml").path)
        let c = await core(readOnly: true, withChat: false)
        let before = (FileManager.default.enumerator(atPath: store.root.path)?.allObjects as? [String] ?? []).sorted()
        var q = HostRequest(.workspaceUpPlan)
        q.space = r.resolved.request(profiles: [], brief: nil)
        let m = await c.handle(q)
        XCTAssertEqual(m.ok, true, "\(String(describing: m.error))")
        let p = try XCTUnwrap(m.result).decode(SpacePlan.self)
        XCTAssertFalse(p.factsKnown)
        XCTAssertEqual(p.space, "clean-room")
        XCTAssertEqual(p.specSHA, r.specSHA)
        let after = (FileManager.default.enumerator(atPath: store.root.path)?.allObjects as? [String] ?? []).sorted()
        XCTAssertEqual(before, after)
        XCTAssertEqual(ActionClasses.classify(q), .dozableOwn)
        XCTAssertTrue(HostOp.workspaceUpPlan.isReadOnly)
    }
}
