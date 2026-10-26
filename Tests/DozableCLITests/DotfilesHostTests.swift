import Foundation
import XCTest
@testable import DozableCLI
@testable import DozableHost
@testable import DozableKit

/// 657: the person's dotfiles on the Mac — the setting, the cache the Mac's git fetches into (a LOCAL scratch repository
/// made here, never the owner's), the pin, the trust record, `dotfiles:` in doz_project.yaml and `--dotfiles`, the plan's
/// line and the agent's facts line.
final class DotfilesHostTests: XCTestCase {
    var root: URL!
    /// git never reads this Mac's own configuration here.
    var env: [String: String] {
        ["PATH": "/usr/bin:/bin", "HOME": root.path, "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
         "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.invalid", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.invalid"]
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("doz-dotfiles-host-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    func git(_ args: [String], in dir: URL) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        p.environment = env
        p.currentDirectoryURL = dir
        let o = Pipe()
        p.standardOutput = o
        p.standardError = o
        try p.run()
        let d = o.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let s = String(decoding: d, as: UTF8.self)
        guard p.terminationStatus == 0 else { throw DotfilesError("git \(args.joined(separator: " ")): \(s)") }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A scratch dotfiles repository: `.bashrc`, `.config/nvim/init.lua`, `.claude/x` — committed.
    func makeRepo(_ name: String = "dots") throws -> URL {
        let repo = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".config/nvim"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try "alias ll='ls -l'\n".write(to: repo.appendingPathComponent(".bashrc"), atomically: true, encoding: .utf8)
        try "-- nvim\n".write(to: repo.appendingPathComponent(".config/nvim/init.lua"), atomically: true, encoding: .utf8)
        try "{}\n".write(to: repo.appendingPathComponent(".claude/x"), atomically: true, encoding: .utf8)
        try git(["init", "-q", "-b", "main"], in: repo)
        try git(["add", "-A"], in: repo)
        try git(["commit", "-q", "-m", "first dotfiles"], in: repo)
        return repo
    }

    func cache() -> DotfilesCache { DotfilesCache(root: root.appendingPathComponent("store/dotfiles"), environment: env) }

    // MARK: the setting

    func testTheSettingIsOneEntryOfTheClosedSchema() throws {
        let d = try XCTUnwrap(DozableSettings.definition(SettingKey.dotfiles))
        XCTAssertEqual(d.defaultValue, .string(""), "none by default — nothing changes for anyone who does not set it")
        XCTAssertEqual(d.applies, .nextCreate)
        XCTAssertTrue(d.editableInUI, "a URL — settable from the page (a folder is refused there)")
        XCTAssertEqual(try d.parse("https://github.com/you/dotfiles"), .string("https://github.com/you/dotfiles"))
        XCTAssertEqual(try d.parse("~/dotfiles"), .string("~/dotfiles"))
        XCTAssertThrowsError(try d.parse("git@github.com:you/dotfiles.git"))
        XCTAssertThrowsError(try d.parse("https://x:y@github.com/you/dotfiles"))
        let s = DozableSettings(text: "[sandbox]\ndotfiles = \"https://github.com/you/dotfiles\"\n")
        XCTAssertEqual(s.string(SettingKey.dotfiles), "https://github.com/you/dotfiles")
        XCTAssertEqual(HostCore.settingDotfiles(s), "https://github.com/you/dotfiles")
        XCTAssertNil(HostCore.settingDotfiles(DozableSettings(text: "")))
        XCTAssertFalse(DozableSettings.perSandbox.contains(SettingKey.dotfiles), "a sandbox keeps its own as a pin (--update moves it), not a live value")
    }

    // MARK: the cache (the Mac's git, a local scratch repository)

    func testResolveFetchesTheHeadAndThePinnedCommitStaysReadable() throws {
        let repo = try makeRepo()
        let head = try git(["rev-parse", "HEAD"], in: repo)
        let c = cache()
        let commit = try c.resolve(repo.path)
        XCTAssertEqual(commit, head)
        XCTAssertTrue(c.has(repo.path, commit))
        XCTAssertEqual(c.subject(repo.path, commit: commit), "first dotfiles")
        let entries = try c.entries(repo.path, commit: commit)
        XCTAssertTrue(entries.contains(DotfilesEntry(".config/nvim/init.lua", .file)))
        let plan = DotfilesLayer.plan(entries)
        XCTAssertEqual(plan.links, [".bashrc", ".config/nvim"])
        XCTAssertEqual(plan.skipped.first { $0.path == ".claude" }?.why, "Dozable's own")
        let tar = try c.archive(repo.path, commit: commit)
        XCTAssertGreaterThan(tar.count, 1024)
        XCTAssertNil(String(decoding: tar.prefix(512), as: UTF8.self).range(of: "pax_global_header"), "the tree's tar: no header naming the commit")
        XCTAssertFalse(c.isDirty(repo.path))
        try "x\n".write(to: repo.appendingPathComponent(".bashrc"), atomically: true, encoding: .utf8)
        XCTAssertTrue(c.isDirty(repo.path), "changes not committed are said")

        // The branch moves on (a new commit); the first stays readable, the head is the new one.
        try git(["commit", "-qam", "second"], in: repo)
        let second = try git(["rev-parse", "HEAD"], in: repo)
        XCTAssertEqual(try c.resolve(repo.path), second)
        XCTAssertNoThrow(try c.ensure(repo.path, commit: commit))
        XCTAssertNoThrow(try c.archive(repo.path, commit: commit))
        // A fresh cache asked for an older commit fetches it (by id, or the whole history).
        let fresh = DotfilesCache(root: root.appendingPathComponent("store2/dotfiles"), environment: env)
        XCTAssertNoThrow(try fresh.ensure(repo.path, commit: commit))
        XCTAssertTrue(fresh.has(repo.path, commit))
        XCTAssertThrowsError(try fresh.ensure(repo.path, commit: String(repeating: "0", count: 40)))
        XCTAssertEqual(fresh.cached().map(\.source), [repo.path])
    }

    func testAFolderThatIsNotARepositoryIsRefusedWithWhatToDo() throws {
        let plain = root.appendingPathComponent("plain")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        XCTAssertThrowsError(try cache().resolve(plain.path)) { e in
            XCTAssertTrue("\(e)".contains("is not a git repository") && "\(e)".contains("git init"), "\(e)")
        }
        XCTAssertThrowsError(try cache().resolve(root.appendingPathComponent("missing").path)) { e in
            XCTAssertTrue("\(e)".contains("is not a folder on this Mac"), "\(e)")
        }
    }

    func testGitNeverAsksAndNeverReadsThisMacsConfigInATestRun() {
        let e = DotfilesCache.gitEnvironment(["DOZ_TEST_GUARD": "1", "HOME": "/h"])
        XCTAssertEqual(e["GIT_TERMINAL_PROMPT"], "0")
        XCTAssertEqual(e["GIT_ASKPASS"], "/usr/bin/false")
        XCTAssertEqual(e["GIT_CONFIG_NOSYSTEM"], "1")
        XCTAssertEqual(e["GIT_CONFIG_GLOBAL"], "/dev/null")
        XCTAssertEqual(DotfilesCache.gitEnvironment(["DOZ_TEST_GUARD": "1", "GIT_CONFIG_GLOBAL": "/tmp/x"])["GIT_CONFIG_GLOBAL"], "/tmp/x", "a scratch one given is kept")
    }

    // MARK: trust

    func testTrustIsOncePerSourceAndCommit() throws {
        let e = ["XDG_CONFIG_HOME": root.appendingPathComponent("xdg").path]
        let a = String(repeating: "a", count: 40), b = String(repeating: "b", count: 40)
        XCTAssertFalse(DotfilesTrust.isTrusted(source: "https://github.com/you/d", commit: a, e))
        try DotfilesTrust.trust(source: "https://github.com/you/d", commit: a, e)
        XCTAssertTrue(DotfilesTrust.isTrusted(source: "https://github.com/you/d", commit: a, e))
        XCTAssertFalse(DotfilesTrust.isTrusted(source: "https://github.com/you/d", commit: b, e), "another commit is asked again")
        XCTAssertFalse(DotfilesTrust.isTrusted(source: "https://github.com/other/d", commit: a, e))
        try DotfilesTrust.trust(source: "https://github.com/you/d", commit: a, e)
        XCTAssertEqual(DotfilesTrust.records(e).count, 1, "said twice, kept once")
        let f = try XCTUnwrap(DotfilesTrust.file(e))
        XCTAssertEqual(f.lastPathComponent, "dotfiles-trusted.json")
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: f.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    // MARK: the project file, the flag, the plan

    func testTheProjectKeyRoundTrips() throws {
        var p = DozableProject(name: "box", image: "lab")
        XCTAssertTrue(p.render().contains("# dotfiles: https://github.com/you/dotfiles"), "commented when not set")
        p.dotfiles = "https://github.com/you/dotfiles"
        let back = try DozableProject.parse(p.render())
        XCTAssertEqual(back.dotfiles, "https://github.com/you/dotfiles")
        XCTAssertEqual(back.createOptions(folder: root, file: root.appendingPathComponent("doz_project.yaml")).dotfiles, "https://github.com/you/dotfiles")
        XCTAssertEqual(try DozableProject.parse("name: box\nimage: lab\ndotfiles: none\n").dotfiles, "none")
        XCTAssertEqual(try DozableProject.parse("name: box\nimage: lab\ndotfiles: no\n").dotfiles, "none", "YAML's no is none")
        XCTAssertEqual(try DozableProject.parse("name: box\nimage: lab\ndotfiles: ~/dots\n").dotfiles, "~/dots")
        XCTAssertThrowsError(try DozableProject.parse("name: box\nimage: lab\ndotfiles: http://x/y\n"))
        // A value equal to the setting is left to it (unless set on purpose).
        var q = p
        q.dropDefaults(settings: DozableSettings(text: "[sandbox]\ndotfiles = \"https://github.com/you/dotfiles\"\n"), explicit: [])
        XCTAssertNil(q.dotfiles)
        q = p
        q.dropDefaults(settings: DozableSettings(text: "[sandbox]\ndotfiles = \"https://github.com/you/dotfiles\"\n"), explicit: ["dotfiles"])
        XCTAssertNotNil(q.dotfiles)
    }

    func testTheFlagAndThePlan() throws {
        let o = try ChoiceOptions.from(["--image", "lab", "--dotfiles", "https://github.com/you/dotfiles"]).planChoices()
        XCTAssertEqual(o.dotfiles, "https://github.com/you/dotfiles")
        XCTAssertEqual(try ChoiceOptions.from(["--image", "lab", "--dotfiles", "none"]).planChoices().dotfiles, "none")
        XCTAssertThrowsError(try ChoiceOptions.from(["--image", "lab", "--dotfiles", "http://x/y"]).planChoices())
        let repo = try makeRepo()
        let rel = try ChoiceOptions.from(["--image", "lab", "--dotfiles", repo.path]).planChoices()
        XCTAssertEqual(rel.dotfiles, repo.path)
        let facts = PlanFacts(settings: DozableSettings(text: ""), accounts: AccountsFile(), taken: [], images: [], store: DozableStore(root: root),
                              projectsDir: root.appendingPathComponent("projects").path)
        let plan = CreatePlanner.plan(PlanRequest(purpose: "create", name: "box", create: o), facts: facts)
        XCTAssertEqual(plan.dotfiles, "https://github.com/you/dotfiles")
        XCTAssertTrue(plan.argv.contains("--dotfiles"), plan.command)
        XCTAssertTrue(plan.yaml.contains("dotfiles: \"https://github.com/you/dotfiles\"") || plan.yaml.contains("dotfiles: https://github.com/you/dotfiles"), plan.yaml)
        XCTAssertNil(CreatePlanner.plan(PlanRequest(purpose: "create", name: "box", create: CreateOptions(image: "lab")), facts: facts).dotfiles)
        let fromSetting = PlanFacts(settings: DozableSettings(text: "[sandbox]\ndotfiles = \"https://github.com/you/dotfiles\"\n"), accounts: AccountsFile(),
                                    taken: [], images: [], store: DozableStore(root: root), projectsDir: root.path)
        XCTAssertEqual(CreatePlanner.plan(PlanRequest(purpose: "create", name: "box", create: CreateOptions(image: "lab")), facts: fromSetting).dotfiles,
                       "https://github.com/you/dotfiles", "the setting applies when the create names none")
        var none = CreateOptions(image: "lab")
        none.dotfiles = "none"
        XCTAssertNil(CreatePlanner.plan(PlanRequest(purpose: "create", name: "box", create: none), facts: fromSetting).dotfiles, "none wins over the setting")
    }

    // MARK: the agent's facts

    func testTheFactsSayTheDotfilesWereApplied() throws {
        func facts(_ d: DotfilesState?) -> String {
            AgentPrompt.values(name: "n", image: "pi", cpus: 1, memoryMiB: 1024, workspace: "/w", network: .none, account: nil, version: "1",
                               hostname: "h", dotfiles: d)["dotfiles.facts"] ?? "?"
        }
        XCTAssertEqual(facts(nil), "", "no dotfiles: no line")
        let commit = String(repeating: "9f", count: 20)
        var d = DotfilesState(source: "https://github.com/you/d", display: "https://github.com/you/d", commit: commit, resolvedAt: Date(),
                              state: "applied", method: "script", script: "install.sh", summary: "install.sh ran (exit 0)", at: Date())
        var f = facts(d)
        XCTAssertTrue(f.contains("https://github.com/you/d at commit 9f9f9f9f9f9f") && f.contains("their install.sh ran"), f)
        d.state = "failed"
        f = facts(d)
        XCTAssertTrue(f.contains("did not apply cleanly"), f)
        XCTAssertTrue(AgentPrompt.variables.contains { $0.name == "dotfiles.facts" })
        XCTAssertTrue(AgentPrompt.builtInTemplate.contains("- {{dotfiles.facts}}"))
        let rendered = try AgentPrompt.render(AgentPrompt.builtInTemplate,
                                              AgentPrompt.values(name: "n", image: "pi", cpus: 1, memoryMiB: 1024, workspace: "/w", network: .none,
                                                                 account: nil, version: "1", hostname: "h"), source: "b")
        XCTAssertFalse(rendered.contains("Dotfiles"), "the line is dropped when there are none")
    }
}
