import Foundation
import XCTest
@testable import DozableKit

/// 657: the dotfiles model — the source's rules, Dozable's protected paths, the plan (the install script's choice, the
/// links, what is skipped), the tree parser, the guest scripts' answers; and the apply script itself, run by this Mac's
/// /bin/sh against a scratch home (the link pass, never over a file that is there, an update dropping its old links).
final class DotfilesTests: XCTestCase {
    // MARK: the source

    func testTheSourceRules() throws {
        for ok in ["", "none", "https://github.com/you/dotfiles", "https://git.example.com/a/b.git", "/Users/x/dotfiles", "~/dotfiles", "~"] {
            XCTAssertNil(DotfilesSource.problem(ok), ok)
        }
        XCTAssertNotNil(DotfilesSource.problem("http://github.com/you/dotfiles"), "plain http is refused")
        XCTAssertNotNil(DotfilesSource.problem("git@github.com:you/dotfiles.git"), "only https or a folder")
        XCTAssertNotNil(DotfilesSource.problem("https://user:ghp_secret@github.com/you/dotfiles"), "no credentials in the URL")
        XCTAssertEqual(DotfilesSource.problem("https://tok@github.com/you/d"), "no user name or token in the URL — the Mac's own git login is used")
        XCTAssertNotNil(DotfilesSource.problem("https://github.com/you/dotfiles?x=1"))
        XCTAssertNotNil(DotfilesSource.problem("https://github.com"), "a path is needed")
        XCTAssertNotNil(DotfilesSource.problem("~other/dotfiles"), "another user's home is not a folder we name")
        XCTAssertNotNil(DotfilesSource.problem("/a/../b"))
        XCTAssertNotNil(DotfilesSource.problem("/a b"), "no spaces")
        XCTAssertNotNil(DotfilesSource.problem("https://github.com/x/\u{1b}[31m"))
        XCTAssertNotNil(DotfilesSource.problem("relative/folder"))
        XCTAssertNotNil(DotfilesSource.problem(String(repeating: "a", count: 600)))

        XCTAssertNil(try DotfilesSource.normalized("none", home: "/h"))
        XCTAssertNil(try DotfilesSource.normalized("  ", home: "/h"))
        XCTAssertEqual(try DotfilesSource.normalized("~/dots/", home: "/Users/me"), "/Users/me/dots")
        XCTAssertEqual(try DotfilesSource.normalized("/a/./b//", home: "/h"), "/a/b")
        XCTAssertEqual(try DotfilesSource.normalized("https://github.com/you/dotfiles/", home: "/h"), "https://github.com/you/dotfiles")
        XCTAssertThrowsError(try DotfilesSource.normalized("ftp://x/y", home: "/h"))
        XCTAssertEqual(DotfilesSource.fetchURL("/Users/me/dots"), "file:///Users/me/dots")
        XCTAssertEqual(DotfilesSource.fetchURL("https://github.com/you/d"), "https://github.com/you/d")
        XCTAssertEqual(DotfilesSource.label("https://github.com/you/d"), "github.com/you/d")
        XCTAssertEqual(DotfilesSource.label("/Users/me/dots"), "the folder dots")
        XCTAssertEqual(DotfilesSource.cacheID("https://github.com/you/d").count, 16)
        XCTAssertNotEqual(DotfilesSource.cacheID("a"), DotfilesSource.cacheID("b"))
        XCTAssertTrue(DotfilesPin.isCommit(String(repeating: "a1", count: 20)))
        XCTAssertFalse(DotfilesPin.isCommit(String(repeating: "A1", count: 20)))
        XCTAssertFalse(DotfilesPin.isCommit("abc"))
    }

    // MARK: Dozable's own paths

    func testTheProtectedPathsHoldEveryOneTheBriefNames() {
        let p = DotfilesLayer.protectedPaths
        for path in [".claude", ".claude.json", ".codex", ".pi", ".config/opencode", ".agents", ".local/state/doz", ".local/share/doz",
                     ".local/bin/claude", ".local/bin/codex", ".local/bin/pi"] {
            XCTAssertTrue(p.contains(path), path)
        }
        // Every recipe's launcher, and its state under ~.
        for r in AgentRecipes.all {
            XCTAssertTrue(DotfilesLayer.isProtected(".local/bin/" + r.install.binary), r.id)
            for d in r.state.persist where d.hasPrefix("~/") { XCTAssertTrue(DotfilesLayer.isProtected(String(d.dropFirst(2))), "\(r.id): \(d)") }
        }
        XCTAssertTrue(DotfilesLayer.isProtected(".claude/settings.json"), "inside one")
        XCTAssertTrue(DotfilesLayer.isProtected(".claude.json.backup"), "every .claude* at the top")
        XCTAssertTrue(DotfilesLayer.isProtected(".config/opencode/x.json"))
        XCTAssertFalse(DotfilesLayer.isProtected(".config"), "the folder that holds one is not itself Dozable's")
        XCTAssertFalse(DotfilesLayer.isProtected(".config/nvim"))
        XCTAssertFalse(DotfilesLayer.isProtected(".bashrc"))
        XCTAssertFalse(DotfilesLayer.isProtected(".local/bin/mytool"))
        XCTAssertTrue(DotfilesLayer.isProtected("work/x", extra: ["work"]), "a share under the home")
    }

    // MARK: the plan

    private func tree(_ items: [(String, DotfilesEntry.Kind)]) -> [DotfilesEntry] { items.map { DotfilesEntry($0.0, $0.1) } }

    func testTheScriptIsChosenInCodespacesOrder() {
        XCTAssertEqual(DotfilesLayer.scriptNames, ["install.sh", "install", "bootstrap.sh", "bootstrap", "script/bootstrap", "setup.sh", "setup", "script/setup"])
        XCTAssertEqual(DotfilesLayer.scriptChoice(tree([("setup.sh", .file), ("bootstrap", .file), ("install.sh", .file)])), "install.sh")
        XCTAssertEqual(DotfilesLayer.scriptChoice(tree([("setup", .file), ("script", .dir), ("script/bootstrap", .file)])), "script/bootstrap")
        XCTAssertEqual(DotfilesLayer.scriptChoice(tree([("install", .link)])), "install", "a link to a script counts")
        XCTAssertNil(DotfilesLayer.scriptChoice(tree([("install.sh", .dir), (".bashrc", .file)])), "a FOLDER named install.sh is not a script")
        XCTAssertNil(DotfilesLayer.scriptChoice(tree([("scripts/setup", .file)])), "only the names Codespaces runs")
        let p = DotfilesLayer.plan(tree([(".bashrc", .file), ("bootstrap.sh", .file)]))
        XCTAssertEqual(p.method, "script")
        XCTAssertEqual(p.script, "bootstrap.sh")
        XCTAssertTrue(p.links.isEmpty, "a script replaces the link pass")
    }

    func testTheLinksSkipDozablesOwnAndTheRepositorysOwn() {
        let p = DotfilesLayer.plan(tree([
            (".bashrc", .file), (".gitconfig", .file), ("README.md", .file), (".git", .dir), (".github", .dir), (".github/ci.yml", .file),
            (".gitignore", .file), (".claude", .dir), (".claude/settings.json", .file), (".claude.json", .file), (".codex", .dir), (".pi", .dir),
            (".agents", .dir), (".vimrc", .link), (".zsh", .dir), (".zsh/a.zsh", .file), ("vendor-lib", .submodule), (".tmux", .submodule),
            (".config", .dir), (".config/nvim", .dir), (".config/nvim/init.lua", .file), (".config/opencode", .dir), (".config/opencode/c.json", .file),
            (".config/starship.toml", .file),
            (".local", .dir), (".local/bin", .dir), (".local/bin/claude", .file), (".local/bin/mytool", .file), (".local/state", .dir),
            (".local/state/doz", .dir), (".local/state/doz/x", .file), (".local/state/other", .dir), (".local/share", .dir), (".local/share/doz", .dir),
            (".odd\u{7}name", .file),
        ]))
        XCTAssertEqual(p.method, "links")
        XCTAssertEqual(p.links, [".bashrc", ".config/nvim", ".config/starship.toml", ".gitconfig", ".local/bin/mytool", ".local/state/other", ".vimrc", ".zsh"])
        let why = Dictionary(p.skipped.map { ($0.path, $0.why) }, uniquingKeysWith: { a, _ in a })
        for d in [".claude", ".claude.json", ".codex", ".pi", ".agents", ".config/opencode", ".local/bin/claude", ".local/state/doz", ".local/share/doz"] {
            XCTAssertEqual(why[d], "Dozable's own", d)
        }
        XCTAssertEqual(why[".git"], "the repository's own file")
        XCTAssertEqual(why[".github"], "the repository's own file")
        XCTAssertEqual(why[".gitignore"], "the repository's own file")
        XCTAssertEqual(why[".tmux"], "a submodule (not fetched)")
        XCTAssertEqual(why[".odd\u{7}name"], "an unusual name")
        XCTAssertNil(why["README.md"], "a file that is not a dotfile is not mentioned")
        XCTAssertFalse(p.links.contains(".config"), "a folder holding something of Dozable's is never linked whole")
        XCTAssertFalse(p.links.contains(".local"))
        XCTAssertTrue(p.summary.contains("8 dotfiles linked into ~"), p.summary)
    }

    func testTheTreeParser() {
        let raw = "040000 tree aaaa\t.config\u{0}100644 blob bbbb\t.config/x y\u{0}120000 blob cccc\t.vimrc\u{0}160000 commit dddd\tsub\u{0}100755 blob eeee\tinstall.sh\u{0}"
        let e = DotfilesLayer.parseTree(Data(raw.utf8))
        XCTAssertEqual(e, [DotfilesEntry(".config", .dir), DotfilesEntry(".config/x y", .file), DotfilesEntry(".vimrc", .link),
                           DotfilesEntry("sub", .submodule), DotfilesEntry("install.sh", .file)])
    }

    // MARK: the guest's answers

    func testTheResultsOfAScriptRun() {
        let pin = DotfilesPin(source: "https://github.com/you/d", commit: String(repeating: "ab", count: 20))
        let plan = DotfilesPlan(method: "script", script: "install.sh")
        var r = DotfilesLayer.results("doz-dotfiles files\ndoz-dotfiles script 0\ndoz-out hello\u{1b}[31m red\ndoz-out done\ndoz-dotfiles done\n", pin: pin, plan: plan)
        XCTAssertTrue(r.ok)
        XCTAssertEqual(r.exitCode, 0)
        XCTAssertEqual(r.output, ["hello red", "done"], "the output made inert")
        XCTAssertEqual(r.summary, "install.sh ran (exit 0)")
        r = DotfilesLayer.results("doz-dotfiles files\ndoz-dotfiles script 3\ndoz-dotfiles done\n", pin: pin, plan: plan)
        XCTAssertFalse(r.ok)
        XCTAssertTrue(r.summary.hasPrefix("install.sh failed (exit 3)"), r.summary)
        r = DotfilesLayer.results("doz-dotfiles files\ndoz-dotfiles script 124\ndoz-dotfiles done\n", pin: pin, plan: plan)
        XCTAssertEqual(r.summary, "install.sh ran out of time (300 s)")
        r = DotfilesLayer.results("doz-dotfiles failed could not unpack the files: bad\n", pin: pin, plan: plan)
        XCTAssertFalse(r.ok)
        XCTAssertEqual(r.summary, "failed: could not unpack the files: bad")
        r = DotfilesLayer.results("", pin: pin, plan: plan)
        XCTAssertEqual(r.failure, "no answer from the guest")
    }

    func testTheResultsOfALinkRun() {
        let pin = DotfilesPin(source: "/Users/me/d", commit: String(repeating: "cd", count: 20))
        let plan = DotfilesPlan(method: "links", links: [".bashrc", ".vimrc", ".gitconfig", ".zsh"])
        let r = DotfilesLayer.results("""
            doz-dotfiles files
            doz-dotfile dropped .oldrc
            doz-dotfile linked .vimrc
            doz-dotfile stock .bashrc
            doz-dotfile kept .gitconfig
            doz-dotfile ok .zsh
            doz-dotfiles done
            """, pin: pin, plan: plan)
        XCTAssertTrue(r.ok)
        XCTAssertEqual(r.linked, [".vimrc"])
        XCTAssertEqual(r.stock, [".bashrc"])
        XCTAssertEqual(r.kept, [".gitconfig"])
        XCTAssertEqual(r.unchanged, [".zsh"])
        XCTAssertEqual(r.dropped, [".oldrc"])
        XCTAssertTrue(r.summary.contains("1 linked") && r.summary.contains("kept (yours: .gitconfig)") && r.summary.contains("1 old link removed"), r.summary)
        XCTAssertEqual(DotfilesLayer.appliedCommit("applied=\(pin.commit)\n"), pin.commit)
        XCTAssertNil(DotfilesLayer.appliedCommit(""))
    }

    func testEveryNameIsQuotedForTheShell() {
        XCTAssertEqual(DotfilesLayer.quote("a'b"), "'a'\\''b'")
        let s = DotfilesLayer.applyScript(plan: DotfilesPlan(method: "links", links: [".it's"]), commit: "c", home: "/home/a'b")
        XCTAssertTrue(s.contains("l '.it'\\''s'"), s)
        XCTAssertTrue(s.contains("H='/home/a'\\''b'"), s)
        XCTAssertFalse(s.contains("$(cat"), "nothing of the repository is evaluated by the link pass")
    }

    // MARK: the apply script, for real (this Mac's /bin/sh, a scratch home)

    private func sh(_ script: String, stdin: Data, env: [String: String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        p.environment = env
        let i = Pipe(), o = Pipe()
        p.standardInput = i
        p.standardOutput = o
        p.standardError = o
        try p.run()
        i.fileHandleForWriting.write(stdin)
        try i.fileHandleForWriting.close()
        let out = o.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: out, as: UTF8.self)
    }

    private func tar(_ dir: URL) throws -> Data {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        p.arguments = ["-c", "-f", "-", "-C", dir.path, "."]
        let o = Pipe()
        p.standardOutput = o
        try p.run()
        let d = o.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return d
    }

    func testTheLinkPassForRealNeverOverwritesAndAnUpdateDropsItsOldLinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("doz-dotfiles-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let repo = root.appendingPathComponent("repo"), home = root.appendingPathComponent("home")
        for d in [repo.appendingPathComponent(".config/nvim"), repo.appendingPathComponent(".config/opencode"), repo.appendingPathComponent(".claude"),
                  home.appendingPathComponent(".claude"), home.appendingPathComponent(".config")] {
            try fm.createDirectory(at: d, withIntermediateDirectories: true)
        }
        try "repo bashrc\n".write(to: repo.appendingPathComponent(".bashrc"), atomically: true, encoding: .utf8)
        try "repo gitconfig\n".write(to: repo.appendingPathComponent(".gitconfig"), atomically: true, encoding: .utf8)
        try "old\n".write(to: repo.appendingPathComponent(".oldrc"), atomically: true, encoding: .utf8)
        try "init\n".write(to: repo.appendingPathComponent(".config/nvim/init.lua"), atomically: true, encoding: .utf8)
        try "{\"evil\": 1}\n".write(to: repo.appendingPathComponent(".config/opencode/opencode.json"), atomically: true, encoding: .utf8)
        try "{\"evil\": 1}\n".write(to: repo.appendingPathComponent(".claude/settings.json"), atomically: true, encoding: .utf8)
        try "mine\n".write(to: home.appendingPathComponent(".gitconfig"), atomically: true, encoding: .utf8)
        try "dozable's\n".write(to: home.appendingPathComponent(".claude/settings.json"), atomically: true, encoding: .utf8)
        let entries: [DotfilesEntry] = [DotfilesEntry(".bashrc", .file), DotfilesEntry(".gitconfig", .file), DotfilesEntry(".oldrc", .file),
                                        DotfilesEntry(".config", .dir), DotfilesEntry(".config/nvim", .dir), DotfilesEntry(".config/opencode", .dir),
                                        DotfilesEntry(".claude", .dir)]
        let plan = DotfilesLayer.plan(entries)
        let pin = DotfilesPin(source: "/x", commit: String(repeating: "1", count: 40))
        let env = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": home.path]
        var out = try sh(DotfilesLayer.applyScript(plan: plan, commit: pin.commit, home: home.path), stdin: try tar(repo), env: env)
        var r = DotfilesLayer.results(out, pin: pin, plan: plan)
        XCTAssertTrue(r.ok, out)
        XCTAssertEqual(Set(r.linked), [".bashrc", ".config/nvim", ".oldrc"], out)
        XCTAssertEqual(r.kept, [".gitconfig"])
        let files = home.appendingPathComponent(DotfilesLayer.guestDirectoryRelative)
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: home.appendingPathComponent(".bashrc").path), files.appendingPathComponent(".bashrc").path)
        XCTAssertEqual(try String(contentsOf: home.appendingPathComponent(".gitconfig"), encoding: .utf8), "mine\n", "yours is never overwritten")
        XCTAssertEqual(try String(contentsOf: home.appendingPathComponent(".claude/settings.json"), encoding: .utf8), "dozable's\n", "Dozable's is never touched")
        XCTAssertFalse(fm.fileExists(atPath: home.appendingPathComponent(".config/opencode").path), "never linked")
        XCTAssertEqual(try String(contentsOf: home.appendingPathComponent(DotfilesLayer.guestMarkerRelative), encoding: .utf8), pin.commit + "\n")
        XCTAssertEqual(try sh(DotfilesLayer.checkScript(home: home.path), stdin: Data(), env: env), "applied=\(pin.commit)\n")

        // Again (a re-apply): nothing new; then an update that removes .oldrc — its dangling link goes.
        out = try sh(DotfilesLayer.applyScript(plan: plan, commit: pin.commit, home: home.path), stdin: try tar(repo), env: env)
        r = DotfilesLayer.results(out, pin: pin, plan: plan)
        XCTAssertEqual(Set(r.unchanged), [".bashrc", ".config/nvim", ".oldrc"], out)
        try fm.removeItem(at: repo.appendingPathComponent(".oldrc"))
        try "new\n".write(to: repo.appendingPathComponent(".newrc"), atomically: true, encoding: .utf8)
        let plan2 = DotfilesLayer.plan(entries.filter { $0.path != ".oldrc" } + [DotfilesEntry(".newrc", .file)])
        let pin2 = DotfilesPin(source: "/x", commit: String(repeating: "2", count: 40))
        out = try sh(DotfilesLayer.applyScript(plan: plan2, commit: pin2.commit, home: home.path), stdin: try tar(repo), env: env)
        r = DotfilesLayer.results(out, pin: pin2, plan: plan2)
        XCTAssertTrue(r.ok, out)
        XCTAssertEqual(r.dropped, [".oldrc"], out)
        XCTAssertEqual(r.linked, [".newrc"], out)
        XCTAssertNil(try? fm.destinationOfSymbolicLink(atPath: home.appendingPathComponent(".oldrc").path))
        XCTAssertEqual(try String(contentsOf: home.appendingPathComponent(".newrc"), encoding: .utf8), "new\n")
    }

    func testTheScriptRunsFromTheFilesWithItsOutputKept() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("doz-dotfiles-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let repo = root.appendingPathComponent("repo"), home = root.appendingPathComponent("home")
        try fm.createDirectory(at: repo, withIntermediateDirectories: true)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        // No #! and no exec bit: run with sh. It reads stdin: /dev/null (never the tar).
        try "echo \"ran in $(pwd)\"; touch \"$HOME/.installed\"; cat >/dev/null; exit 0\n".write(to: repo.appendingPathComponent("install.sh"), atomically: true, encoding: .utf8)
        let plan = DotfilesLayer.plan([DotfilesEntry("install.sh", .file)])
        let pin = DotfilesPin(source: "/x", commit: String(repeating: "3", count: 40))
        let out = try sh(DotfilesLayer.applyScript(plan: plan, commit: pin.commit, home: home.path), stdin: try tar(repo),
                         env: ["PATH": "/usr/bin:/bin", "HOME": home.path])
        let r = DotfilesLayer.results(out, pin: pin, plan: plan)
        XCTAssertTrue(r.ok, out)
        XCTAssertEqual(r.output, ["ran in " + home.appendingPathComponent(DotfilesLayer.guestDirectoryRelative).path], out)
        XCTAssertTrue(fm.fileExists(atPath: home.appendingPathComponent(".installed").path))
        XCTAssertTrue(fm.fileExists(atPath: home.appendingPathComponent(DotfilesLayer.guestLogRelative).path), "all of it in the log")
    }
}
