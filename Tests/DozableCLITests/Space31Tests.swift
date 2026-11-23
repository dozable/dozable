import DozableChat
import Foundation
import XCTest
@testable import DozableHost
@testable import DozableCLI

/// 758: space/3.1 — Dozable's model-neutral keys first-class (docs/engineering/workspace-model.md, "The space/3.1 keys";
/// model v3's option A): each first-class key accepted in a `doz: space/3.1` file; the lifetime NOT a 3.1 key (under
/// `x-dozable` in either version, never required; top-level in 3.1 refused with the fix); a top-level `title:` read with a
/// note naming `about.title`; a first-class key in a `doz: space/3` file refused with the fix; the `x-dozable` form read
/// with a note in either version; both forms refused; the held keys still only under `x-dozable`; a `space-defaults/3.1`
/// file; `lift` and generate → validate. The exact words of each refusal are the vectors
/// (`SpaceValidationTableTests.testEveryRowOfTheSpace31Vectors`); the space/3 corpus is the reference's table, unchanged.
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

    /// 750.09's "after", cut to option A: the lifetime (and the per-resource `lifetime: run`) still under x-dozable.
    static let after = """
    doz: space/3.1
    space: app
    owner: jscott
    brief: { text: Fix the build, refs: [https://example.com/1] }
    about: { title: Work on a project, summary: A manager and a helper work in one of your folders., tags: [build] }
    layout: { repo: { x: 1, y: 2 } }
    network: standard
    x-dozable: { lifetime: standing }
    folders:
      repo: { external: ~/work/app, main: true }
      notes: { x-dozable: { lifetime: run } }
    agents:
      manager: { external: { bot: mira }, role: manager }
      helper: { kind: claude-code, role: worker, isolation: fenced, folder: repo, prompt: Fix the failing test., restart: on-failure, network: { preset: locked, allow: [api.example.com] } }
      reviewer: { external: { sandbox: old-review } }
    chat:
      rooms:
        app: { members: [owner, manager, helper] }
    """

    func testEachFirstClassKeyIsAccepted() {
        let (p, m, doc) = check(Self.after)
        XCTAssertEqual(p.filter(\.isError).map(\.text), [])
        XCTAssertEqual(m.lifetime, "standing")
        XCTAssertEqual(m.title, "Work on a project", "about.title is the title")
        XCTAssertEqual(m.briefText, "Fix the build")
        XCTAssertEqual(m.briefRefs, ["https://example.com/1"])
        XCTAssertEqual(m.brief, "")
        XCTAssertEqual(m.resource("reviewer")?.lifetime, "external")
        let i = SpaceIntent.compile(m, doc, loc0)
        XCTAssertEqual(i.effectiveLifetime, "standing")
        XCTAssertEqual(i.agents.first { $0.name == "helper" }?.restart, "on-failure")
        XCTAssertEqual(i.agents.first { $0.name == "reviewer" }?.sandbox, "old-review")
        XCTAssertEqual(i.runLifetime, ["folder:notes"])
        XCTAssertFalse(i.notes.contains { $0.contains("read for this release only") }, "a held key under x-dozable is no deprecated use: \(i.notes)")
        // A brief as a path, and as { file }.
        XCTAssertEqual(check(Self.v31 + "brief: B.md\n").model.brief, "B.md")
        let f = check(Self.v31 + "brief: { file: BRIEF.md, refs: [a.md] }\n")
        XCTAssertEqual(f.problems.filter(\.isError).map(\.text), [])
        XCTAssertEqual(f.model.brief, "BRIEF.md")
        XCTAssertEqual(f.model.briefRefs, ["a.md"])
        // A plain space/3.1 file: space/3 with the version line, no lifetime needed (read as runs).
        let plain = check(Self.v31 + "brief: B.md\n")
        XCTAssertEqual(plain.problems.filter(\.isError).map(\.text), [])
        XCTAssertEqual(SpaceIntent.compile(plain.model, plain.doc, loc0).effectiveLifetime, "runs")
    }

    func testTheFirstClassKeysAreChecked() {
        func one(_ yaml: String, _ want: String, file: StaticString = #filePath, line: UInt = #line) {
            let e = errors(Self.v31 + yaml)
            XCTAssertTrue(e.contains { $0.contains(want) }, "wanted \(want) in \(e)", file: file, line: line)
        }
        one("brief: {}\n", "brief needs its text or its file")
        one("brief: { txt: a }\n", "unknown key \"txt\" in brief (did you mean \"text\"?)")
        one("brief: B.md\nabout: { titel: x }\n", "unknown key \"titel\" in about")
        one("brief: B.md\nlayout: 3\n", "expected a map")
        one("brief: B.md\nnetwork: wide\n", "is not a valid \"network\"")
        one("brief: B.md\nfolders:\n  a: { external: /a, main: yes }\n", "expected true or false")
        one("brief: B.md\nagents:\n  w: { prompt: x, restart: always }\n", "is not a valid \"restart\"")
        one("brief: B.md\nagents:\n  w: { prompt: x, network: { preset: wide } }\n", "is not a valid \"preset\"")
        one("brief: B.md\nagents:\n  r: { external: { sandbox: \"\" } }\n", "must NOT have fewer than 1 characters")
        one("brief: B.md\nagents:\n  r: { external: { sandbox: s }, kind: claude-code }\n", "\"r\" is external, so \"kind\" can't apply")
        one("brief: B.md\nsandboxes:\n  s: {}\nagents:\n  r: { external: { sandbox: s } }\n", "\"s\" is a sandbox of this space")
    }

    /// Option A: persistence is not in space/3.1.
    func testTheLifetimeIsNotA31Key() {
        let c = check(Self.v31 + "brief: B.md\nlifetime: runs\n")
        let e = c.problems.filter(\.isError)
        XCTAssertEqual(e.map(\.message), ["\"lifetime\" is not a space/3.1 key: it stays under x-dozable"])
        XCTAssertEqual(e.first.map { "\($0.file):\($0.line)" }, "t.space.yaml:5")
        XCTAssertEqual(e.first?.hint, "write x-dozable: { lifetime: runs } (standing or runs)")
        // Under x-dozable it is read in either version, with no note of its own.
        XCTAssertEqual(errors(Self.v31 + "brief: B.md\nx-dozable: { lifetime: standing }\n"), [])
        XCTAssertEqual(check(Self.v31 + "brief: B.md\nx-dozable: { lifetime: standing }\n").model.lifetime, "standing")
        XCTAssertFalse(notes(Self.v31 + "brief: B.md\nx-dozable: { lifetime: standing }\n").contains { $0.contains("lifetime") })
        XCTAssertEqual(errors(Self.v3 + "brief: B.md\nx-dozable: { lifetime: standing }\n"), [])
        // Required by neither version.
        XCTAssertEqual(errors(Self.v31 + "brief: B.md\n"), [])
        XCTAssertEqual(errors(Self.v3 + "brief: B.md\n"), [])
        // In space/3 a top-level lifetime is unknown, as it always was.
        XCTAssertEqual(errors(Self.v3 + "brief: B.md\nlifetime: standing\n"), ["unknown key \"lifetime\" in the file"])
    }

    /// The format author's point 3: about.title replaces the top-level title, which still reads with a note.
    func testATopLevelTitleReadsWithANoteNamingAboutTitle() {
        let yaml = Self.v31 + "title: App\nbrief: B.md\n"
        XCTAssertEqual(check(yaml).model.title, "App")
        XCTAssertTrue(notes(yaml).contains("title is read for this release only: space/3.1 writes it as about.title (about: { title: … })"))
        XCTAssertFalse(notes(Self.v3 + "title: App\nbrief: B.md\n").contains { $0.contains("about.title") }, "space/3's title is its own")
        XCTAssertEqual(errors(Self.v31 + "title: App\nbrief: B.md\nabout: { title: Other }\n"), ["the title is written twice: title: and about.title"])
        // lift moves it into about.
        let lifted = SpaceDozable.lift(check(yaml).doc)
        XCTAssertNil(SpaceDoc.member(lifted, "title"))
        XCTAssertEqual(SpaceDoc.string(SpaceDoc.at(lifted, "/about/title")), "App")
        let withAbout = SpaceDozable.lift(check(Self.v3 + "title: App\nbrief: B.md\nx-dozable: { about: { summary: S } }\n").doc)
        XCTAssertEqual(SpaceDoc.members(SpaceDoc.member(withAbout, "about")).map(\.key), ["title", "summary"])
    }

    func testA31KeyUnderSpace3IsRefusedWithTheFix() {
        for (yaml, key) in [("brief: { text: x }\n", "brief"), ("brief: B.md\nabout: { title: T }\n", "about"),
                            ("brief: B.md\nlayout: {}\n", "layout"), ("brief: B.md\nnetwork: standard\n", "network"),
                            ("brief: B.md\nfolders:\n  a: { external: /a, main: true }\n", "main"),
                            ("brief: B.md\nagents:\n  w: { prompt: x, restart: on-failure }\n", "restart"),
                            ("brief: B.md\nagents:\n  w: { prompt: x, network: locked }\n", "network"),
                            ("brief: B.md\nagents:\n  r: { external: { sandbox: s } }\n", "external")] {
            let e = errors(Self.v3 + yaml)
            XCTAssertEqual(e, ["\"\(key)\" is a space/3.1 key: change the version line to doz: space/3.1"], yaml)
        }
        // The same file with the version line changed is accepted.
        XCTAssertEqual(errors(Self.v31 + "brief: B.md\nagents:\n  w: { prompt: x, restart: on-failure }\n"), [])
        // space/3's own external forms are unchanged.
        XCTAssertEqual(errors(Self.v3 + "brief: B.md\nagents:\n  m: { external: { bot: mira } }\n"), [])
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
          r: { x-dozable: { external: { sandbox: s } } }

        """
        let old = notes(Self.v3 + body)
        XCTAssertEqual(old.filter { $0.contains("read for this release only") || $0.contains("stays under x-dozable") }, [
            "x-dozable.brief is read for this release only: write brief: at the top level, with the version line doz: space/3.1",
            "folder \"repo\": x-dozable.main is read for this release only: write main: on folder \"repo\", with the version line doz: space/3.1",
            "agent \"w\": x-dozable.restart is read for this release only: write restart: on agent \"w\", with the version line doz: space/3.1",
            "agent \"r\": x-dozable.external is read for this release only: write external: on agent \"r\", with the version line doz: space/3.1",
        ])
        XCTAssertFalse(old.contains { $0.contains("lifetime") }, "the lifetime is not a 3.1 key: no note (\(old))")
        let new = notes(Self.v31 + body)
        XCTAssertEqual(new.filter { $0.contains("read for this release only") }.count, 4)
        XCTAssertFalse(new.contains { $0.contains("version line") }, "a 3.1 file has the version line already")
        // Read the same either way.
        let a = check(Self.v3 + body).model, b = check(Self.v31 + body).model
        XCTAssertEqual(a.lifetime, "standing")
        XCTAssertEqual(b.lifetime, "standing")
        XCTAssertEqual(a.briefText, b.briefText)
        XCTAssertEqual(a.resource("r")?.lifetime, "external")
        // A plain space/3 file has no such note.
        XCTAssertFalse(notes(Self.v3 + "brief: B.md\n").contains { $0.contains("x-dozable") })
    }

    func testBothFormsOfOneKeyAreRefused() {
        XCTAssertTrue(errors(Self.v31 + "brief: B.md\nnetwork: open\nx-dozable: { network: locked }\n").contains("\"network\" is written twice: network: and x-dozable.network"))
        XCTAssertTrue(errors(Self.v31 + "brief: { text: a }\nx-dozable: { brief: { text: b } }\n").contains("the brief is written twice: brief: and x-dozable.brief"))
        XCTAssertTrue(errors(Self.v31 + "brief: B.md\nfolders:\n  a: { external: /a, main: true, x-dozable: { main: true } }\n").contains("\"main\" is written twice: main: and x-dozable.main"))
        XCTAssertTrue(errors(Self.v31 + "brief: B.md\nagents:\n  w: { prompt: x, restart: on-failure, x-dozable: { restart: on-failure } }\n").contains("\"restart\" is written twice: restart: and x-dozable.restart"))
        XCTAssertTrue(errors(Self.v31 + "brief: B.md\nagents:\n  r: { external: { sandbox: s }, x-dozable: { external: { sandbox: s } } }\n").contains("\"r\" is external twice: external: and x-dozable.external"))
        // One main folder across both forms.
        XCTAssertTrue(errors(Self.v31 + "brief: B.md\nfolders:\n  a: { external: /a, main: true }\n  b: { external: /b, x-dozable: { main: true } }\n").contains("two main folders: \"a\" and \"b\""))
    }

    /// The keys whose design is still open (persistence, the defaults' vm) stay under x-dozable only, in either version.
    func testTheHeldKeysStayUnderXDozable() {
        let head = Self.v31 + "brief: B.md\n"
        XCTAssertTrue(errors(head + "folders:\n  a: { lifetime: run }\n").contains("unknown key \"lifetime\" in folder \"a\""))
        XCTAssertTrue(errors(head + "chat:\n  rooms:\n    r: { lifetime: run }\n").contains("unknown key \"lifetime\" in room \"r\""))
        XCTAssertTrue(errors(head + "agents:\n  w: { prompt: x, lifetime: run }\n").contains("unknown key \"lifetime\" in agent \"w\""))
        XCTAssertTrue(errors(head + "agent_defaults: { isolation: vm }\n").contains { $0.contains("is not a valid \"isolation\"") })
        let held = head + """
        x-dozable: { lifetime: runs }
        agent_defaults: { x-dozable: { isolation: vm } }
        folders:
          a: { x-dozable: { lifetime: run } }
        agents:
          r: { x-dozable: { lifetime: run }, prompt: x }
        sandboxes:
          box: { x-dozable: { lifetime: run } }

        """
        XCTAssertEqual(errors(held), [])
        XCTAssertFalse(notes(held).contains { $0.contains("read for this release only") || $0.contains("lifetime") })
        // lift leaves them where they are.
        let lifted = SpaceDozable.lift(check(held).doc)
        XCTAssertEqual(SpaceDoc.string(SpaceDoc.at(lifted, "/x-dozable/lifetime")), "runs")
        XCTAssertEqual(SpaceDoc.string(SpaceDoc.at(lifted, "/agents/r/x-dozable/lifetime")), "run")
        XCTAssertEqual(SpaceDoc.string(SpaceDoc.at(lifted, "/agent_defaults/x-dozable/isolation")), "vm")
    }

    /// A defaults file may say space-defaults/3.1; it holds what a space-defaults/3 one does.
    func testASpaceDefaults31File() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("doz-space31-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "doz: space-defaults/3.1\nagent_defaults: { transcripts: keep }\narchive: { keep: [plan] }\n".write(to: dir.appendingPathComponent("d.yaml"), atomically: true, encoding: .utf8)
        try (Self.v31 + "brief: B.md\nextends: d.yaml\n").write(to: dir.appendingPathComponent("s.space.yaml"), atomically: true, encoding: .utf8)
        var r = SpaceResolver()
        r.environment = [:]
        let (p, _) = r.resolve(dir.appendingPathComponent("s.space.yaml").path).check()
        XCTAssertEqual(p.filter(\.isError).map(\.text), [])
        XCTAssertEqual(SpaceValidator.checkSource(.object([JMember("doz", .string("space-defaults/3.1"))]), name: "d", lines: [:]).filter(\.isError).map(\.text), [])
        XCTAssertEqual(SpaceValidator.checkSource(.object([JMember("doz", .string("space-defaults/4"))]), name: "d", lines: [:]).first?.message, "d is not a defaults file")
    }

    /// `lift` writes the 3.1 form: every x-dozable spelling of a first-class key lifted, in its map's place; the lifetime
    /// stays under x-dozable; the result validates as space/3.1.
    func testLiftWritesThe31Form() {
        let before = """
        doz: space/3
        space: app
        title: Work on a project
        owner: jscott
        x-dozable:
          lifetime: standing
          brief: { text: Fix the build }
          network: standard
          about: { summary: A manager and a helper. }
        folders:
          repo: { external: ~/work/app, x-dozable: { main: true } }
        agents:
          helper: { kind: claude-code, prompt: x, x-dozable: { restart: on-failure, network: locked } }
          old: { x-dozable: { external: { sandbox: s } } }

        """
        let doc = check(before).doc
        let after = SpaceDozable.lift(doc)
        XCTAssertEqual(SpaceDoc.members(after).map(\.key), ["doz", "space", "owner", "brief", "network", "about", "x-dozable", "folders", "agents"])
        XCTAssertEqual(SpaceDoc.string(SpaceDoc.member(after, "doz")), "space/3.1")
        XCTAssertEqual(SpaceDoc.members(SpaceDozable.of(after)).map(\.key), ["lifetime"], "only the held key stays")
        XCTAssertEqual(SpaceDoc.string(SpaceDoc.at(after, "/about/title")), "Work on a project")
        XCTAssertEqual(SpaceDoc.bool(SpaceDoc.at(after, "/folders/repo/main")), true)
        XCTAssertNil(SpaceDoc.at(after, "/folders/repo/x-dozable"))
        XCTAssertEqual(SpaceDoc.string(SpaceDoc.at(after, "/agents/helper/restart")), "on-failure")
        XCTAssertEqual(SpaceDoc.string(SpaceDoc.at(after, "/agents/helper/network")), "locked")
        XCTAssertEqual(SpaceDoc.string(SpaceDoc.at(after, "/agents/old/external/sandbox")), "s")
        let loc = SpaceLocator(sources: [SpaceSource(path: "/x", name: "x", kind: "space", sha256: "")], origins: [:])
        XCTAssertEqual(SpaceValidator.checkMerged(after, loc).problems.filter(\.isError).map(\.text), [])
        XCTAssertEqual(SpaceDozable.lift(after), after, "lifting twice changes nothing")
        // Its YAML reads back as a valid 3.1 file.
        let text = SpaceYAML.emit(after, origins: [:], sources: [])
        XCTAssertEqual(check(text).problems.filter(\.isError).map(\.text), [])
    }
}
