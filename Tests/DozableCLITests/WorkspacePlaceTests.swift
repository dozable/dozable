import DozableChat
import Foundation
import XCTest
@testable import DozableHost
@testable import DozableCLI

/// Places (model v3, docs/engineering/workspace-model.md, "Place"): `x-dozable.places` validated and planned as entities;
/// `where:` naming a place (an unknown one refused, listing the places); an unfenced place declaring nothing and saying
/// "none: acts as you" for each part; a vm place and space/3.1's `sandboxes:` as vm places; the external shape
/// `external: {sandbox: NAME}`; a fenced place as a policy — each session its own fence (two fences from one policy); a
/// grant refused on a place; an existing workspace's places derived from its agents; the record's `placeName` additive.
final class WorkspacePlaceTests: XCTestCase {
    let loc0 = SpaceLocator(sources: [], origins: [:])

    func check(_ yaml: String) -> (problems: [SpaceProblem], model: SpaceModel, doc: JValue) {
        let (doc, lines, parse) = SpaceResolver.parse(yaml, name: "t.space.yaml")
        XCTAssertTrue(parse.isEmpty, parse.map(\.text).joined(separator: "\n"))
        let loc = SpaceLocator(sources: [SpaceSource(path: "/x/t.space.yaml", name: "t.space.yaml", kind: "space", sha256: "")], origins: lines)
        let (p, m) = SpaceValidator.checkMerged(doc ?? .object([]), loc)
        return (p, m, doc ?? .object([]))
    }

    func errors(_ yaml: String) -> [SpaceProblem] { check(yaml).problems.filter(\.isError) }

    static func space(agents: String, places: String, extra: String = "") -> String {
        """
        doz: space/3.1
        space: app
        owner: ada
        brief: {text: Fix the build}
        folders:
          repo: { external: ~/work/app, main: true }
        agents:
        \(agents)
        \(extra)x-dozable:
          places:
        \(places)
        """
    }

    static let three = space(agents: """
      helper:   { kind: claude-code, role: worker, where: desk, folder: repo }
      reviewer: { kind: claude-code, role: reviewer, where: build, access: ro }
    """, places: """
        desk:    { isolation: fenced }
        build:   { isolation: vm, image: claude-code, cpus: 4, memory: 8G }
        old-box: { external: { sandbox: old-review } }
    """)

    // MARK: the model and the validator

    func testDeclaredPlacesAreEntitiesAndAnAgentNamesItsPlace() throws {
        let (p, m, doc) = check(Self.three)
        XCTAssertEqual(p.filter(\.isError).map(\.text), [])
        XCTAssertEqual(m.places.map(\.name), ["desk", "build", "old-box"])
        XCTAssertEqual(m.places.map(\.isolation), ["fenced", "vm", "vm"])
        XCTAssertEqual(m.places.first { $0.name == "old-box" }?.external, .init(sandbox: "old-review"))
        XCTAssertEqual(m.places.first { $0.name == "build" }?.cpus, 4)
        XCTAssertEqual(m.agents.first { $0.name == "helper" }?.place, "desk")
        XCTAssertNil(m.agents.first { $0.name == "helper" }?.sandbox, "a fenced place is on this Mac")
        XCTAssertEqual(m.agents.first { $0.name == "helper" }?.isolation, "fenced")
        XCTAssertEqual(m.agents.first { $0.name == "reviewer" }?.sandbox, "build", "a vm place is the agent's sandbox")
        let i = SpaceIntent.compile(m, doc, loc0)
        XCTAssertEqual(i.places?.map(\.name), ["desk", "build", "old-box"])
        XCTAssertEqual(i.agents.first { $0.name == "helper" }?.place, "desk")
        XCTAssertEqual(i.sandboxes.first { $0.name == "build" }?.placeName, "app-build", "a vm place is an owned sandbox of the space")
        XCTAssertEqual(i.sandboxes.first { $0.name == "build" }?.agents, ["reviewer"])
        XCTAssertEqual(i.sandboxes.first { $0.name == "old-box" }?.placeName, "old-review", "an external place keeps its sandbox's name")
        XCTAssertEqual(i.sandboxes.first { $0.name == "old-box" }?.external, true)
    }

    func testSpace31SandboxesAreReadAsVMPlaces() {
        let (p, m, _) = check("""
        doz: space/3.1
        space: app
        owner: ada
        brief: {text: Fix the build}
        sandboxes:
          build: { image: claude-code }
        folders:
          repo: { external: ~/work/app, main: true }
        agents:
          helper: { kind: claude-code, role: worker, where: sandbox:build, folder: repo }
        """)
        XCTAssertEqual(p.filter(\.isError).map(\.text), [])
        XCTAssertEqual(m.places.map(\.name), ["build"])
        XCTAssertEqual(m.places.first?.isolation, "vm")
        XCTAssertEqual(m.places.first?.from, "sandboxes")
        XCTAssertEqual(m.agents.first?.place, "build")
    }

    func testAnUnfencedPlaceDeclaresNothingAndSaysItActsAsYou() {
        for declares in ["view: { repo: rw }", "network: { allow: [example.com] }", "credentials: [github]"] {
            let e = errors(Self.space(agents: "  helper: { kind: claude-code, role: worker, where: here, folder: repo }",
                                      places: "    here: { isolation: unfenced, \(declares) }"))
            XCTAssertEqual(e.count, 1, "\(declares): \(e.map(\.text))")
            XCTAssertTrue(e.first?.message.contains(WorkspacePlace.actsAsYou) == true, e.map(\.text).joined())
        }
        let (p, m, _) = check(Self.space(agents: "  helper: { kind: claude-code, role: worker, where: here, folder: repo }",
                                         places: "    here: { isolation: unfenced }"))
        XCTAssertEqual(p.filter(\.isError).map(\.text), [])
        let here = m.places.first { $0.name == "here" }
        for part in [here?.view, here?.network, here?.credentials] { XCTAssertEqual(part, .text("none: acts as you"), "never an empty policy") }
        XCTAssertEqual(m.agents.first?.isolation, "unfenced", "the place sets it")
        XCTAssertTrue(m.risks.contains { $0.setting == "agents.helper.isolation" && $0.source == "t.space.yaml:8" },
                      "an unfenced place is a risky setting, named with the line that puts the agent there: \(m.risks.map(\.line))")
        // JSON: each part the string itself.
        let json = String(decoding: try! JSONEncoder().encode(here!), as: UTF8.self)
        XCTAssertTrue(json.contains("\"view\":\"none: acts as you\""), json)
    }

    func testAnUnfencedPlaceIsNeverInherited() {
        let e = errors(Self.space(agents: "  helper: { kind: claude-code, role: worker, folder: repo }",
                                  places: "    here: { isolation: unfenced }", extra: "agent_defaults: { where: here }\n"))
        XCTAssertTrue(e.contains { $0.message.contains("unfenced by inheritance") }, e.map(\.text).joined(separator: "\n"))
    }

    func testAnAgentsIsolationIsItsPlaces() {
        let e = errors(Self.space(agents: "  helper: { kind: claude-code, role: worker, where: desk, isolation: unfenced, folder: repo }",
                                  places: "    desk: { isolation: fenced }"))
        XCTAssertTrue(e.contains { $0.pointer == "/agents/helper/isolation" && $0.message.contains("its isolation is the place's") }, e.map(\.text).joined())
    }

    func testAnUnknownWhereIsRefusedListingThePlaces() {
        let e = errors(Self.space(agents: "  helper: { kind: claude-code, role: worker, where: dsek, folder: repo }",
                                  places: "    desk: { isolation: fenced }"))
        XCTAssertEqual(e.count, 1, e.map(\.text).joined(separator: "\n"))
        XCTAssertEqual(e.first?.pointer, "/agents/helper/where")
        XCTAssertTrue(e.first?.message.contains("\"dsek\" is not a place") == true, e.map(\.text).joined())
        XCTAssertTrue(e.first?.message.contains("did you mean \"desk\"") == true, e.map(\.text).joined())
        XCTAssertTrue(e.first?.hint?.contains("the places: desk") == true, e.first?.hint ?? "")
        XCTAssertTrue(e.first?.hint?.contains("mac") == true, "mac and sandbox:NAME stay reserved")
    }

    func testThePlacesShapes() {
        func one(_ place: String) -> [String] {
            errors(Self.space(agents: "  helper: { kind: claude-code, role: worker, folder: repo }", places: "    p: \(place)")).map(\.message)
        }
        XCTAssertEqual(one("{ isolation: fenced }"), [])
        XCTAssertEqual(one("{ isolation: fenced, view: { repo: ro }, network: { preset: locked, allow: [api.example.com] }, credentials: [github] }"), [])
        XCTAssertEqual(one("{ external: { sandbox: old } }"), [])
        XCTAssertEqual(one("{ external: { sandbox: old }, isolation: vm }"), [])
        XCTAssertFalse(one("{ external: { sandbox: old }, isolation: fenced }").isEmpty, "an external place is a vm")
        XCTAssertFalse(one("{ external: { sandbox: old }, image: x }").isEmpty, "an external place says nothing else")
        XCTAssertFalse(one("{ external: old }").isEmpty, "the one shape is { sandbox: NAME }")
        XCTAssertFalse(one("{ isolation: fenced, image: x }").isEmpty, "only a vm place has an image")
        XCTAssertFalse(one("{ isolation: jail }").isEmpty)
        XCTAssertFalse(one("{ image: x }").isEmpty, "a place says its isolation")
        XCTAssertFalse(one("{ isolation: fenced, colour: red }").isEmpty)
        XCTAssertFalse(one("{ isolation: fenced, view: { repo: maybe } }").isEmpty)
        for reserved in ["mac", "sandbox"] {
            let e = errors(Self.space(agents: "  helper: { kind: claude-code, role: worker, folder: repo }", places: "    \(reserved): { isolation: fenced }"))
            XCTAssertTrue(e.contains { $0.message.contains("keyword") }, "\(reserved): \(e.map(\.text))")
        }
        let twice = errors(Self.space(agents: "  helper: { kind: claude-code, role: worker, folder: repo }", places: "    repo: { isolation: fenced }"))
        XCTAssertTrue(twice.contains { $0.message.contains("used twice") }, twice.map(\.text).joined())
    }

    func testAPlaceNoAgentRunsInIsNotChecked() {
        let (_, m, doc) = check(Self.three)
        let i = SpaceIntent.compile(m, doc, loc0)
        let f = SpaceFacts(known: true, home: "/h", projectsDir: "/p", owner: "ada", chatOn: true, record: nil)
        let plan = SpaceUp.plan(i, facts: f, specSHA: "x", sources: [])
        let check = plan.steps.first { $0.subject == "sandbox old-box" }
        XCTAssertEqual(check?.action, "skip", "an external place no agent runs in is not looked for")
        XCTAssertFalse(plan.refusals.contains { $0.contains("old-review") }, plan.refusals.joined())
        XCTAssertEqual(plan.places?.map(\.name), ["desk", "build", "old-box"])
        XCTAssertEqual(plan.agents?.first { $0.name == "helper" }?.where, "desk")
        XCTAssertEqual(plan.agents?.first { $0.name == "reviewer" }?.where, "build")
        // Each agent in the fenced place is its own worker, its own session, recorded in the place.
        let adds = plan.steps.filter { $0.kind == "worker-add" }
        XCTAssertEqual(adds.first { $0.subject == "agent helper" }?.worker?.placeName, "desk")
        XCTAssertEqual(adds.first { $0.subject == "agent helper" }?.worker?.isolation, "fenced")
    }

    func testTwoAgentsInOneFencedPlaceAreTwoSessionsOfTheirOwn() {
        let (_, m, doc) = check(Self.space(agents: """
          helper:   { kind: claude-code, role: worker, where: desk, folder: repo }
          reviewer: { kind: claude-code, role: reviewer, where: desk, folder: repo }
        """, places: "    desk: { isolation: fenced }"))
        let i = SpaceIntent.compile(m, doc, loc0)
        let f = SpaceFacts(known: true, home: "/h", projectsDir: "/p", owner: "ada", chatOn: true, record: nil)
        let adds = SpaceUp.plan(i, facts: f, specSHA: "x", sources: []).steps.filter { $0.kind == "worker-add" }.compactMap(\.worker)
        XCTAssertEqual(adds.map(\.placeName), ["desk", "desk"])
        XCTAssertEqual(adds.map(\.isolation), ["fenced", "fenced"], "each a fenced session — a fence of its own")
        XCTAssertEqual(Set(adds.compactMap(\.name)).count, 2)
        XCTAssertTrue(adds.allSatisfy { $0.sandbox == nil && $0.session == nil }, "no shared session or sandbox: each gets W-NAME")
    }

    // MARK: places with their sessions

    func agent(_ name: String, session: String? = nil, sandbox: String? = nil, place: String? = nil, task: String? = "t",
               isolation: String = "fenced") -> WorkspaceAgent {
        var a = WorkspaceAgent(name: name, place: sandbox.map { .sandbox($0) } ?? .macSession(session ?? "app-" + name), startedAt: Date(),
                               isolation: isolation)
        a.task = task
        a.placeName = place
        return a
    }

    func testTwoFencesFromOnePolicy() {
        let desk = WorkspacePlaces.declared("desk", .object([JMember("isolation", .string("fenced"))]), workspaceNetwork: .text("locked"))
        let agents = [agent("helper", place: "desk"), agent("reviewer", place: "desk")]
        let tags = ["helper": "doz-fence:aaaa", "reviewer": "doz-fence:bbbb"]
        let s = WorkspacePlaces.states(declared: [desk], agents: agents, placeOf: { $0.placeName }, fence: { tags[$0.name] }, fenced: { _ in true },
                                       state: { _ in "running" })
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s[0].sessions.map(\.identity), ["helper", "reviewer"])
        XCTAssertEqual(s[0].sessions.map(\.session), ["@mac/app-helper", "@mac/app-reviewer"])
        let fences = s[0].sessions.compactMap(\.fence)
        XCTAssertEqual(fences.count, 2)
        XCTAssertEqual(Set(fences).count, 2, "a fence per session, never shared")
    }

    func testAnExistingWorkspacesPlacesAreDerived() {
        var adopted = agent("old", sandbox: "old-review", task: nil)
        adopted.role = "worker"
        var ended = agent("gone")
        ended.endedAt = Date()
        let agents = [agent("w1"), agent("w2", isolation: "unfenced"), agent("v1", sandbox: "box"), agent("v2", sandbox: "box"), adopted, ended]
        let s = WorkspacePlaces.states(declared: [], agents: agents, placeOf: { $0.placeName }, fence: { _ in nil }, fenced: { _ in nil },
                                       state: { _ in "unknown" })
        XCTAssertEqual(s.map(\.name), ["@mac/app-w1", "@mac/app-w2", "box", "old-review"])
        XCTAssertEqual(s.map(\.isolation), ["fenced", "unfenced", "vm", "vm"])
        XCTAssertEqual(s[1].view, .text(WorkspacePlace.actsAsYou))
        XCTAssertEqual(s[2].sessions.map(\.identity), ["v1", "v2"], "agents sharing a sandbox share its place")
        XCTAssertEqual(s[3].external, .init(sandbox: "old-review"), "an adopted sandbox is an external place")
        XCTAssertTrue(s.allSatisfy { WorkspacePlace.isolations.contains($0.isolation) })
    }

    func testTheRecordsPlaceNameIsAdditive() throws {
        var a = agent("helper", place: "desk")
        a.place = .macSession("app-helper")
        let data = try HostWire.encoder.encode(a)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"placeName\":\"desk\""))
        XCTAssertEqual(try HostWire.decoder.decode(WorkspaceAgent.self, from: data).placeName, "desk")
        // A record from before places: no placeName, decoded unchanged.
        let old = #"{"name":"w","role":"worker","place":{"mac":true,"session":"s"},"startedBy":"you","startedAt":"2026-11-01T00:00:00.000Z"}"#
        let o = try HostWire.decoder.decode(WorkspaceAgent.self, from: Data(old.utf8))
        XCTAssertNil(o.placeName)
        XCTAssertFalse(String(decoding: try HostWire.encoder.encode(o), as: UTF8.self).contains("placeName"))
    }

    func testThePolicyEncodesEachShape() throws {
        for p: WorkspacePlace.Policy in [.text("none: acts as you"), .access(["repo": "ro"]), .list(["github"]), .network(preset: "locked", allow: ["a.example"])] {
            let d = try JSONEncoder().encode(p)
            XCTAssertEqual(try JSONDecoder().decode(WorkspacePlace.Policy.self, from: d), p, String(decoding: d, as: UTF8.self))
        }
    }
}

/// The places through an in-process daemon core: up records each agent's place, and a grant naming a place is refused
/// with nothing written.
extension WorkspaceLifecycleHostTests {
    func testUpRecordsEachAgentsPlaceAndAGrantNeverNamesAPlace() async throws {
        try await withBriefHome {
            let c = await lcore()
            let s = try spaceFiles(agents: """
              helper:   { kind: claude-code, where: desk, prompt: one }
              reviewer: { kind: claude-code, where: desk, prompt: two }
            """, extra: """
            x-dozable:
              places:
                desk: { isolation: fenced }
            """)
            let p = try await spacePlanned(c, try spaceRequest(s))
            XCTAssertEqual(p.places?.map(\.name), ["desk"])
            XCTAssertEqual(p.agents?.map(\.where), ["desk", "desk"])
            let done = try acted(try await spaceUpAct(c, try spaceRequest(s)))
            XCTAssertTrue(done.ok, done.results.map { "\($0.status) \($0.text)" }.joined(separator: " | "))
            let orders = workers.orders.suffix(2)
            XCTAssertEqual(orders.map(\.place), ["sp-helper", "sp-reviewer"], "two sessions, each its own place on this Mac")
            let rec = try XCTUnwrap(record("sp"))
            XCTAssertEqual(rec.agents.filter { $0.endedAt == nil }.compactMap(\.placeName), ["desk", "desk"])
            // A grant names an identity, never a place: refused before anything is read or written.
            let before = GrantStore(store: store).readOrEmpty().grants
            let recBefore = try XCTUnwrap(record("sp"))
            var r = HostRequest(.permissionsGrant)
            var q = PermissionsRequest(agent: "desk")
            q.words = ["journal.write=allow"]
            q.workspace = "sp"
            r.permissionsRequest = q
            let m = await c.handle(r)
            XCTAssertEqual(m.error?.code, .notFound)
            XCTAssertEqual(m.error.map { ExitCodes.exit(for: $0) }, 2)
            XCTAssertTrue(m.error?.message.contains("desk is a place — grants attach to an agent, never to a place") == true, m.error?.message ?? "")
            XCTAssertEqual(GrantStore(store: store).readOrEmpty().grants, before)
            XCTAssertEqual(try XCTUnwrap(record("sp")).permissions, recBefore.permissions, "nothing granted")
            // An agent of the place is granted as before.
            q.agent = "helper"
            r.permissionsRequest = q
            let ok = await c.handle(r)
            XCTAssertNil(ok.error, ok.error?.message ?? "")
        }
    }
}
