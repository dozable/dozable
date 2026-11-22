import DozableChat
import Foundation
import XCTest
@testable import DozableHost
@testable import DozableCLI

/// 758: space/3.1 — Dozable's keys first-class (docs/engineering/workspace-model.md, "The space/3.1 keys"): each
/// first-class key accepted in a `doz: space/3.1` file; `lifetime` required there; a first-class key in a `doz: space/3`
/// file refused with the fix; the `x-dozable` form read with a note in either version; both forms refused; the held keys
/// still only under `x-dozable`; a `space-defaults/3.1` file; `lift` and generate → validate. The exact words of each
/// refusal are the vectors (`SpaceValidationTableTests.testEveryRowOfTheSpace31Vectors`); the space/3 corpus is the
/// reference's table, unchanged.
final class Space31Tests: XCTestCase {
    let loc0 = SpaceLocator(sources: [], origins: [:])

    func check(_ yaml: String) -> (problems: [SpaceProblem], model: SpaceModel, doc: JValue) {
        let (doc, lines, parse) = SpaceResolver.parse(yaml, name: "t.space.yaml")
        XCTAssertTrue(parse.isEmpty, parse.map(\.text).joined(separator: "\n"))
        let loc = SpaceLocator(sources: [SpaceSource(path: "/x/t.space.yaml", name: "t.space.yaml", kind: "space", sha256: "")], origins: lines)
        let (p, m) = SpaceValidator.checkMerged(doc ?? .object([]), loc)
        return (p, m, doc ?? .object([]))
    }

    func errors(_ yaml: String) -> [String] { check(yaml).problems.filter(\.isError).map(\.message) }
    func notes(_ yaml: String) -> [String] {
        let c = check(yaml)
        XCTAssertEqual(c.problems.filter(\.isError).map(\.text), [])
        return SpaceIntent.compile(c.model, c.doc, loc0).notes
    }

    static let v31 = "doz: space/3.1\nspace: app\nowner: ada\n"
    static let v3 = "doz: space/3\nspace: app\nowner: ada\n"

    /// 750.09's "after", with the held keys still under x-dozable (network, an agent's external sandbox, lifetime: run).
    static let after = """
    doz: space/3.1
    space: app
    owner: jscott
    lifetime: standing
    brief: { text: Fix the build, refs: [https://example.com/1] }
    about: { title: Work on a project, summary: A manager and a helper work in one of your folders., tags: [build] }
    layout: { repo: { x: 1, y: 2 } }
    x-dozable: { network: standard }
    folders:
      repo: { external: ~/work/app, main: true }
      notes: { x-dozable: { lifetime: run } }
    agents:
      manager: { external: { bot: mira }, role: manager }
      helper: { kind: claude-code, role: worker, isolation: fenced, folder: repo, prompt: Fix the failing test., restart: on-failure }
      reviewer: { x-dozable: { external: { sandbox: old-review } } }
    chat:
      rooms:
        app: { members: [owner, manager, helper] }
    """

    func testEachFirstClassKeyIsAccepted() {
        let (p, m, doc) = check(Self.after)
        XCTAssertEqual(p.filter(\.isError).map(\.text), [])
        XCTAssertEqual(m.lifetime, "standing")
        XCTAssertEqual(m.briefText, "Fix the build")
        XCTAssertEqual(m.briefRefs, ["https://example.com/1"])
        XCTAssertEqual(m.brief, "")
        XCTAssertEqual(m.resource("reviewer")?.lifetime, "external")
        let i = SpaceIntent.compile(m, doc, loc0)
        XCTAssertEqual(i.effectiveLifetime, "standing")
        XCTAssertEqual(i.agents.first { $0.name == "helper" }?.restart, "on-failure")
        XCTAssertEqual(i.runLifetime, ["folder:notes"])
        XCTAssertFalse(i.notes.contains { $0.contains("read for this release only") }, "a held key under x-dozable is no deprecated use: \(i.notes)")
        // A brief as a path, and as { file }.
        XCTAssertEqual(check(Self.v31 + "lifetime: runs\nbrief: B.md\n").model.brief, "B.md")
        let f = check(Self.v31 + "lifetime: runs\nbrief: { file: BRIEF.md, refs: [a.md] }\n")
        XCTAssertEqual(f.problems.filter(\.isError).map(\.text), [])
        XCTAssertEqual(f.model.brief, "BRIEF.md")
        XCTAssertEqual(f.model.briefRefs, ["a.md"])
        // A plain space/3.1 file: space/3 with a lifetime.
        XCTAssertEqual(errors(Self.v31 + "lifetime: runs\nbrief: B.md\n"), [])
    }

    func testTheFirstClassKeysAreChecked() {
        func one(_ yaml: String, _ want: String, file: StaticString = #filePath, line: UInt = #line) {
            let e = errors(Self.v31 + yaml)
            XCTAssertTrue(e.contains { $0.contains(want) }, "wanted \(want) in \(e)", file: file, line: line)
        }
        one("lifetime: forever\nbrief: B.md\n", "is not a valid \"lifetime\"")
        one("lifetime: runs\nbrief: {}\n", "brief needs its text or its file")
        one("lifetime: runs\nbrief: { txt: a }\n", "unknown key \"txt\" in brief (did you mean \"text\"?)")
        one("lifetime: runs\nbrief: B.md\nabout: { titel: x }\n", "unknown key \"titel\" in about")
        one("lifetime: runs\nbrief: B.md\nlayout: 3\n", "expected a map")
        one("lifetime: runs\nbrief: B.md\nfolders:\n  a: { external: /a, main: yes }\n", "expected true or false")
        one("lifetime: runs\nbrief: B.md\nagents:\n  w: { prompt: x, restart: always }\n", "is not a valid \"restart\"")
    }

    func testLifetimeIsRequiredIn31() {
        let c = check(Self.v31 + "brief: B.md\n")
        let e = c.problems.filter(\.isError)
        XCTAssertEqual(e.map(\.message), ["the file is missing \"lifetime\""])
        XCTAssertEqual(e.first.map { "\($0.file):\($0.line)" }, "t.space.yaml:1")
        XCTAssertTrue(e.first?.hint?.contains("lifetime: standing") == true)
        // Its x-dozable form says it too (for one release).
        XCTAssertEqual(errors(Self.v31 + "brief: B.md\nx-dozable: { lifetime: standing }\n"), [])
        // A space/3 file needs none: read as runs.
        XCTAssertEqual(errors(Self.v3 + "brief: B.md\n"), [])
    }

    func testA31KeyUnderSpace3IsRefusedWithTheFix() {
        for (yaml, key) in [("brief: B.md\nlifetime: standing\n", "lifetime"), ("brief: { text: x }\n", "brief"),
                            ("brief: B.md\nabout: { title: T }\n", "about"), ("brief: B.md\nlayout: {}\n", "layout"),
                            ("brief: B.md\nfolders:\n  a: { external: /a, main: true }\n", "main"),
                            ("brief: B.md\nagents:\n  w: { prompt: x, restart: on-failure }\n", "restart")] {
            let e = errors(Self.v3 + yaml)
            XCTAssertEqual(e, ["\"\(key)\" is a space/3.1 key: change the version line to doz: space/3.1"], yaml)
        }
        // The same file with the version line changed (and a lifetime) is accepted.
        XCTAssertEqual(errors(Self.v31 + "lifetime: runs\nbrief: B.md\nagents:\n  w: { prompt: x, restart: on-failure }\n"), [])
    }

    func testTheXDozableFormIsReadWithANoteInBothVersions() {
        let body = """
        x-dozable:
          lifetime: standing
          brief: { text: Fix the build }
        folders:
          repo: { external: ~/work/app, x-dozable: { main: true } }
        agents:
          w: { prompt: x, x-dozable: { restart: on-failure } }

        """
        let old = notes(Self.v3 + body)
        XCTAssertEqual(old.filter { $0.contains("read for this release only") }, [
            "x-dozable.lifetime is read for this release only: write lifetime: at the top level, with the version line doz: space/3.1",
            "x-dozable.brief is read for this release only: write brief: at the top level, with the version line doz: space/3.1",
            "folder \"repo\": x-dozable.main is read for this release only: write main: on folder \"repo\", with the version line doz: space/3.1",
            "agent \"w\": x-dozable.restart is read for this release only: write restart: on agent \"w\", with the version line doz: space/3.1",
        ])
        let new = notes(Self.v31 + body)
        XCTAssertEqual(new.filter { $0.contains("read for this release only") }.count, 4)
        XCTAssertFalse(new.contains { $0.contains("version line") }, "a 3.1 file has the version line already")
        // Read the same either way.
        let a = check(Self.v3 + body).model, b = check(Self.v31 + body).model
        XCTAssertEqual(a.lifetime, "standing")
        XCTAssertEqual(b.lifetime, "standing")
        XCTAssertEqual(a.briefText, b.briefText)
        // A plain space/3 file has no such note.
        XCTAssertFalse(notes(Self.v3 + "brief: B.md\n").contains { $0.contains("x-dozable") })
    }

    func testBothFormsOfOneKeyAreRefused() {
        XCTAssertTrue(errors(Self.v31 + "brief: B.md\nlifetime: runs\nx-dozable: { lifetime: runs }\n").contains("\"lifetime\" is written twice: lifetime: and x-dozable.lifetime"))
        XCTAssertTrue(errors(Self.v31 + "lifetime: runs\nbrief: { text: a }\nx-dozable: { brief: { text: b } }\n").contains("the brief is written twice: brief: and x-dozable.brief"))
        XCTAssertTrue(errors(Self.v31 + "lifetime: runs\nbrief: B.md\nfolders:\n  a: { external: /a, main: true, x-dozable: { main: true } }\n").contains("\"main\" is written twice: main: and x-dozable.main"))
        XCTAssertTrue(errors(Self.v31 + "lifetime: runs\nbrief: B.md\nagents:\n  w: { prompt: x, restart: on-failure, x-dozable: { restart: on-failure } }\n").contains("\"restart\" is written twice: restart: and x-dozable.restart"))
        // One main folder across both forms.
        XCTAssertTrue(errors(Self.v31 + "lifetime: runs\nbrief: B.md\nfolders:\n  a: { external: /a, main: true }\n  b: { external: /b, x-dozable: { main: true } }\n").contains("two main folders: \"a\" and \"b\""))
    }

    /// The keys whose design is still open stay under x-dozable only, in either version: first-class they are unknown.
    func testTheHeldKeysStayUnderXDozable() {
        let head = Self.v31 + "lifetime: runs\nbrief: B.md\n"
        XCTAssertTrue(errors(head + "network: standard\n").contains("unknown key \"network\" in the file"))
        XCTAssertTrue(errors(head + "folders:\n  a: { lifetime: run }\n").contains("unknown key \"lifetime\" in folder \"a\""))
        XCTAssertTrue(errors(head + "chat:\n  rooms:\n    r: { lifetime: run }\n").contains("unknown key \"lifetime\" in room \"r\""))
        XCTAssertFalse(errors(head + "agents:\n  r: { external: { sandbox: s } }\n").isEmpty)
        XCTAssertTrue(errors(head + "agent_defaults: { isolation: vm }\n").contains { $0.contains("is not a valid \"isolation\"") })
        let held = head + """
        x-dozable: { network: { preset: standard, allow: [api.example.com] } }
        agent_defaults: { x-dozable: { isolation: vm } }
        folders:
          a: { x-dozable: { lifetime: run } }
        agents:
          r: { x-dozable: { external: { sandbox: s }, network: locked, lifetime: run } }
        sandboxes:
          box: { x-dozable: { lifetime: run } }

        """
        XCTAssertEqual(errors(held), [])
        XCTAssertFalse(notes(held).contains { $0.contains("read for this release only") })
        // lift leaves them where they are.
        let lifted = SpaceDozable.lift(check(held).doc)
        XCTAssertEqual(SpaceDoc.string(SpaceDoc.at(lifted, "/x-dozable/network/preset")), "standard")
        XCTAssertEqual(SpaceDoc.string(SpaceDoc.at(lifted, "/agents/r/x-dozable/external/sandbox")), "s")
    }

    /// A defaults file may say space-defaults/3.1; it holds what a space-defaults/3 one does.
    func testASpaceDefaults31File() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("doz-space31-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "doz: space-defaults/3.1\nagent_defaults: { transcripts: keep }\narchive: { keep: [plan] }\n".write(to: dir.appendingPathComponent("d.yaml"), atomically: true, encoding: .utf8)
        try (Self.v31 + "lifetime: runs\nbrief: B.md\nextends: d.yaml\n").write(to: dir.appendingPathComponent("s.space.yaml"), atomically: true, encoding: .utf8)
        var r = SpaceResolver()
        r.environment = [:]
        let (p, _) = r.resolve(dir.appendingPathComponent("s.space.yaml").path).check()
        XCTAssertEqual(p.filter(\.isError).map(\.text), [])
        XCTAssertEqual(SpaceValidator.checkSource(.object([JMember("doz", .string("space-defaults/3.1"))]), name: "d", lines: [:]).filter(\.isError).map(\.text), [])
        XCTAssertEqual(SpaceValidator.checkSource(.object([JMember("doz", .string("space-defaults/4"))]), name: "d", lines: [:]).first?.message, "d is not a defaults file")
    }

    /// `lift` writes the 3.1 form: every x-dozable spelling of a first-class key lifted, in its map's place; the result
    /// validates as space/3.1 (plus a lifetime when the file had none).
    func testLiftWritesThe31Form() {
        let before = """
        doz: space/3
        space: app
        owner: jscott
        x-dozable:
          lifetime: standing
          brief: { text: Fix the build }
          network: standard
          about: { title: Work on a project }
        folders:
          repo: { external: ~/work/app, x-dozable: { main: true } }
        agents:
          helper: { kind: claude-code, prompt: x, x-dozable: { restart: on-failure } }

        """
        let doc = check(before).doc
        let after = SpaceDozable.lift(doc)
        XCTAssertEqual(SpaceDoc.members(after).map(\.key), ["doz", "space", "owner", "lifetime", "brief", "about", "x-dozable", "folders", "agents"])
        XCTAssertEqual(SpaceDoc.string(SpaceDoc.member(after, "doz")), "space/3.1")
        XCTAssertEqual(SpaceDoc.members(SpaceDozable.of(after)).map(\.key), ["network"], "only the held key stays")
        XCTAssertEqual(SpaceDoc.bool(SpaceDoc.at(after, "/folders/repo/main")), true)
        XCTAssertNil(SpaceDoc.at(after, "/folders/repo/x-dozable"))
        XCTAssertEqual(SpaceDoc.string(SpaceDoc.at(after, "/agents/helper/restart")), "on-failure")
        let loc = SpaceLocator(sources: [SpaceSource(path: "/x", name: "x", kind: "space", sha256: "")], origins: [:])
        XCTAssertEqual(SpaceValidator.checkMerged(after, loc).problems.filter(\.isError).map(\.text), [])
        XCTAssertEqual(SpaceDozable.lift(after), after, "lifting twice changes nothing")
        // Its YAML reads back as a valid 3.1 file.
        let text = SpaceYAML.emit(after, origins: [:], sources: [])
        XCTAssertEqual(check(text).problems.filter(\.isError).map(\.text), [])
    }
}
