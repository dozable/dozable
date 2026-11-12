import Darwin
import Foundation
@testable import DozableKit
import XCTest
@testable import DozableHost

/// A scratch world for the fence's tests: a home with twins of the person's secrets, a store, a socket folder, a user
/// temp — all under /private/tmp (resolved), never the real home.
final class FenceScratch {
    let root: String
    var home: String { root + "/home" }
    var store: String { root + "/store" }
    var work: String { root + "/work" }
    var places: MacFencePlaces {
        MacFencePlaces(home: home, store: store, socketDirectory: root + "/sock", userTemp: root + "/ut/", dozConfig: home + "/.config/doz")
    }

    init() throws {
        let r = "/private/tmp/dzft-\(getpid())-\(UInt32.random(in: 0...UInt32.max))"
        root = r
        for d in [home, store, work, root + "/sock", root + "/ut", home + "/.ssh", home + "/.config/gh", home + "/.aws", home + "/Library/Keychains",
                  home + "/Library/Caches", home + "/Documents", home + "/other-repo"] {
            try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        }
        write(home + "/.ssh/id_x", "PRIVATE")
        write(home + "/.ssh/id_x.pub", "ssh-ed25519 AAAA")
        write(home + "/.ssh/config", "Host x\n")
        write(home + "/.aws/credentials", "[default]\naws_secret_access_key=SECRET\n")
        write(home + "/.zsh_history", "secret history\n")
        write(home + "/.config/gh/hosts.yml", "oauth_token: SECRET\n")
        write(home + "/other-repo/.env", "TOKEN=SECRET\n")
        write(home + "/Library/Caches/x", "cache")
        write(home + "/Documents/doc.txt", "mine")
    }

    func write(_ p: String, _ s: String) {
        try? FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: p, contents: Data(s.utf8))
    }

    func read(_ p: String) -> String? { (try? String(contentsOfFile: p, encoding: .utf8)) }

    func remove() { try? FileManager.default.removeItem(atPath: root) }

    /// A fence over `work` (no PATH links, no git).
    func fence(keychain: Bool = false, write: [String] = [], read: [String] = [], path: String = "/usr/bin:/bin") throws -> MacFence {
        try FileManager.default.createDirectory(atPath: store + "/state", withIntermediateDirectories: true)
        return try MacFence.make(session: "s1", workdir: work, request: MacFenceRequest(keychain: keychain, read: read, write: write), places: places,
                                 path: path, fenceRead: [], hooksPathGlobal: nil, scratch: store + "/state")
    }

    /// Run `argv` under `profile` (sandbox-exec, TTY → /dev/null): exit code and stderr.
    func sandboxed(_ profile: String, _ argv: [String], cwd: String? = nil, env: [String: String] = [:]) -> (code: Int32, err: String) {
        let pf = root + "/p-\(UInt32.random(in: 0...UInt32.max)).sb"
        write(pf, profile)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        p.arguments = ["-f", pf, "-D", "TTY=/dev/null", "--"] + argv
        p.environment = ["PATH": "/usr/bin:/bin", "HOME": home].merging(env) { $1 }
        p.currentDirectoryURL = URL(fileURLWithPath: cwd ?? work)
        let e = Pipe()
        p.standardError = e
        p.standardOutput = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: e.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }
}

/// The profile: its order, its rules, and that sandbox-exec takes it and enforces what it says (harmless programs only).
final class MacFenceProfileTests: XCTestCase {
    var w: FenceScratch!
    override func setUpWithError() throws { w = try FenceScratch() }
    override func tearDown() { w.remove() }

    func testOrder_denyDefaultFirst_theStoreLast_noNetwork_noKeychainUnlessAsked() throws {
        let f = try w.fence()
        let p = MacFenceProfile.render(f)
        let lines = p.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines[0], "(version 1)")
        XCTAssertEqual(lines[1], "(deny default (with message \"doz-fence:\(f.tag)\"))")
        XCTAssertTrue(lines.last!.hasPrefix("(deny file-read* file-write* (subpath \"\(w.store)\")"), "the store, sockets and doz's settings are closed LAST")
        let tag = " (with message \"doz-fence:\(f.tag)\"))"
        let fenceRoot = lines.firstIndex { $0 == "(deny file-read* file-write* (subpath \"\(f.places.fenceRoot)\")" + tag }!
        let session = lines.firstIndex { $0 == "(allow file-read* file-write* (subpath \"\(f.sessionFolder)\"))" }!
        let etc = lines.firstIndex { $0 == "(deny file-write* (subpath \"\(f.etc)\")" + tag }!
        XCTAssertTrue(fenceRoot < session && session < etc, "the fence root closed, this session's folder opened again, its etc read-only")
        XCTAssertFalse(p.contains("network-") || p.contains("network*"), "no network rule at all in this release")
        XCTAssertFalse(p.contains("SecurityServer"))
        XCTAssertTrue(MacFenceProfile.render(try w.fence(keychain: true)).contains("com.apple.SecurityServer"))
        XCTAssertFalse(p.contains("kern.proc"), "another process's argv and environment stay closed")
        XCTAssertFalse(p.contains("sysctl-write") || p.contains("appleevent"))
        XCTAssertTrue(p.contains("(deny file-write-create (literal \"\(w.work)/.git\")" + tag), "no .git at the top of a folder without one")
        XCTAssertTrue(p.contains(#"(deny file-write* (regex #"^"# + MacFenceProfile.regexEscape(w.work) + #"/(.*/)?\.git/hooks(/|$)")"# + tag))
        XCTAssertTrue(p.contains(#"(deny file-write-unlink (regex #"^"# + MacFenceProfile.regexEscape(w.work) + #"/(.*/)?\.git$")"# + tag))
        for l in lines where l.hasPrefix("(deny ") { XCTAssertTrue(l.hasSuffix("(with message \"doz-fence:\(f.tag)\"))"), "every refusal carries the tag: \(l)") }
    }

    func testRegexEscape() {
        XCTAssertEqual(MacFenceProfile.regexEscape("/a.b/c (1)/[x]+y$"), #"/a\.b/c \(1\)/\[x\]\+y\$"#)
    }

    func testEveryHomeWriteIsClosed_andReadsAreAnAllowlist() throws {
        let f = try w.fence(path: "/usr/bin:/bin:" + w.home + "/.local/bin")
        let p = MacFenceProfile.render(f)
        for line in p.split(separator: "\n") where line.contains("file-write") && line.hasPrefix("(allow") {
            for q in line.components(separatedBy: "(subpath \"").dropFirst() {
                let path = String(q.prefix { $0 != "\"" })
                XCTAssertTrue(MacFencePaths.isWithin(path, w.work) || MacFencePaths.isWithin(path, f.sessionFolder) || path == "/dev/fd",
                              "a write allow outside the folder and the session's own: \(path)")
            }
        }
    }

    /// sandbox-exec takes the profile, and it does what it says (1.1, 1.1a, 1.2, 1.3, 1.6, 1.8).
    func testTheProfileRunsAndHolds() throws {
        let f = try w.fence()
        try MacFenceSessionFolder.prepare(f, previous: nil, person: .init())
        let p = MacFenceProfile.render(f)
        XCTAssertEqual(w.sandboxed(p, ["/usr/bin/true"]).code, 0, "sandbox-exec takes it")
        XCTAssertEqual(w.sandboxed(p, ["/bin/sh", "-c", "echo x > a && cat a"]).code, 0, "the folder is writable (1.1)")
        XCTAssertEqual(w.sandboxed(p, ["/bin/sh", "-c", "echo x > \"$1/b\"", "sh", f.tmp]).code, 0, "its own temp is writable (1.1)")
        for target in [w.home + "/x", w.home + "/.zshrc", w.home + "/Library/LaunchAgents/x.plist", "/private/tmp/dzft-escape-\(getpid())",
                       w.home + "/Library/Caches/y", w.root + "/ut/z", w.store + "/x", f.etc + "/gitconfig", f.places.fenceRoot + "/other"] {
            XCTAssertNotEqual(w.sandboxed(p, ["/bin/sh", "-c", "echo x > \"$1\"", "sh", target]).code, 0, "write \(target) refused (1.1a/1.2/1.6)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/private/tmp/dzft-escape-\(getpid())"))
        for target in [w.home + "/.ssh/id_x", w.home + "/.aws/credentials", w.home + "/.zsh_history", w.home + "/.config/gh/hosts.yml",
                       w.home + "/other-repo/.env", w.home + "/Library/Caches/x", w.home + "/Documents/doc.txt", w.store + "/state"] {
            XCTAssertNotEqual(w.sandboxed(p, ["/bin/cat", target]).code, 0, "read \(target) refused (1.3)")
        }
        XCTAssertNotEqual(w.sandboxed(p, ["/bin/ls", w.home]).code, 0, "the home is not listed")
        XCTAssertEqual(w.sandboxed(p, ["/bin/cat", w.home + "/.ssh/config"]).code, 0, ".ssh/config is readable")
        XCTAssertEqual(w.sandboxed(p, ["/bin/cat", w.home + "/.ssh/id_x.pub"]).code, 0, "a public key is readable")
        XCTAssertEqual(w.sandboxed(p, ["/bin/cat", f.etc + "/gitconfig"]).code, 0, "its own etc is readable")
        // 1.8: the denied programs, and a COPY of one (the path rule is cosmetic; launchd/LaunchServices are what stop it).
        XCTAssertNotEqual(w.sandboxed(p, ["/usr/bin/sudo", "-n", "true"]).code, 0, "sudo")
        XCTAssertNotEqual(w.sandboxed(p, ["/usr/bin/sandbox-exec", "-p", "(version 1)(allow default)", "/usr/bin/true"]).code, 0, "a nested sandbox-exec")
        XCTAssertNotEqual(w.sandboxed(p, ["/bin/launchctl", "list"]).code, 0, "launchctl")
        try FileManager.default.copyItem(atPath: "/bin/launchctl", toPath: w.work + "/lc")
        XCTAssertNotEqual(w.sandboxed(p, [w.work + "/lc", "list"]).code, 0, "a copy of launchctl fails too (no launchd service)")
        // 1.11c: another process's argv/environment (kern.procargs2) — `ps` fails (setuid) and sysctl is refused.
        XCTAssertNotEqual(w.sandboxed(p, ["/bin/ps", "-E", "-p", String(getpid())]).code, 0, "ps is unavailable")
        // 1.18: no network in this release.
        XCTAssertNotEqual(w.sandboxed(p, ["/usr/bin/nc", "-z", "-w", "2", "127.0.0.1", "22"]).code, 0, "no network")
    }

    /// Rename rules (1.4–1.4e): hooks at any depth, a .git renamed out, renamed in, an absent top .git, etc/.
    func testGitPathsCannotBeWrittenOrExposedByARename() throws {
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["init", "-q", w.work]
        try git.run(); git.waitUntilExit()
        try FileManager.default.createDirectory(atPath: w.work + "/a/b/c/d/e/.git/hooks", withIntermediateDirectories: true)
        let f = try w.fence()
        try MacFenceSessionFolder.prepare(f, previous: nil, person: .init())
        let p = MacFenceProfile.render(f)
        func refused(_ script: String) -> Bool { w.sandboxed(p, ["/bin/sh", "-c", script]).code != 0 }
        XCTAssertTrue(refused("echo x > .git/hooks/pre-commit"), "1.4 hooks")
        XCTAssertTrue(refused("echo x > a/b/c/d/e/.git/hooks/pre-commit"), "1.4 hooks at depth 5")
        XCTAssertTrue(refused("mv .git g2"), "1.4a a .git renamed out")
        XCTAssertTrue(refused("mv a/b/c/d/e/.git a/b/c/d/e/g2"), "1.4a nested")
        XCTAssertTrue(refused("echo x > y && mv y .git/hooks/y"), "1.4b renamed in")
        XCTAssertFalse(refused("echo x > .git/description"), "an ordinary .git file stays writable")
        XCTAssertTrue(refused("echo x > '\(f.etc)/gitconfig'"), "1.4e etc")
        XCTAssertTrue(refused("rm -f '\(f.etc)/gitconfig' && ln -s /etc/hosts '\(f.etc)/gitconfig'"), "1.4e etc replaced by a link")
        XCTAssertTrue(refused("rm -f '\(f.etc)/excludes'"), "1.4e etc unlink")
        // An absent top .git (1.4d).
        let other = w.root + "/work2"
        try FileManager.default.createDirectory(atPath: other, withIntermediateDirectories: true)
        var g = try w.fence()
        g.workdir = other
        g.workdirGit = nil
        let q = MacFenceProfile.render(g)
        XCTAssertNotEqual(w.sandboxed(q, ["/bin/mkdir", ".git"], cwd: other).code, 0, "mkdir .git at the top")
        XCTAssertNotEqual(w.sandboxed(q, ["/bin/sh", "-c", "mkdir -p x/hooks && mv x .git"], cwd: other).code, 0, "mv x .git at the top")
        XCTAssertEqual(w.sandboxed(q, ["/bin/sh", "-c", "mkdir sub && /usr/bin/git init -q --template= sub"], cwd: other,
                                   env: ["TMPDIR": g.tmp, "GIT_CONFIG_GLOBAL": "/dev/null"]).code, 0, "git init in a sub-folder works")
    }

    /// An in-tree core.hooksPath (husky) and its parent: written, renamed (1.4c).
    func testAnInTreeHooksPathIsProtectedWithItsAncestors() throws {
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["-C", w.work, "init", "-q"]
        try git.run(); git.waitUntilExit()
        let c = Process()
        c.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        c.arguments = ["-C", w.work, "config", "core.hooksPath", ".husky/_"]
        try c.run(); c.waitUntilExit()
        try FileManager.default.createDirectory(atPath: w.work + "/.husky/_", withIntermediateDirectories: true)
        let f = try w.fence()
        XCTAssertEqual(f.protectedPaths, [w.work + "/.husky"])
        try MacFenceSessionFolder.prepare(f, previous: nil, person: .init())
        let p = MacFenceProfile.render(f)
        XCTAssertNotEqual(w.sandboxed(p, ["/bin/sh", "-c", "echo x > .husky/pre-commit"]).code, 0)
        XCTAssertNotEqual(w.sandboxed(p, ["/bin/mv", ".husky", "h2"]).code, 0)
    }
}

/// The file model: refusals, the home's read allowlist, links on the PATH.
final class MacFencePathsTests: XCTestCase {
    var w: FenceScratch!
    override func setUpWithError() throws { w = try FenceScratch() }
    override func tearDown() { w.remove() }

    func testRefusals() {
        let p = w.places
        for bad in ["/", w.home, w.root, w.home + "/.config", w.home + "/.ssh", w.home + "/Library", w.home + "/Library/Keychains",
                    w.store, w.store + "/x", w.root + "/sock", w.home + "/.ssh/keys", w.home + "/Library/Keychains/x", p.fenceRoot + "/s",
                    w.root + "/ut/dh-1"] {
            XCTAssertNotNil(MacFencePaths.folderRefusal(bad, p), bad)
        }
        XCTAssertNil(MacFencePaths.folderRefusal(w.home + "/.config/gh", p), "inside ~/.config: the person's own choice (only ~/.config itself is refused)")
        XCTAssertEqual(MacFencePaths.lexical("/private/tmp/a/./b/../c"), "/private/tmp/a/c", "lexical, and /private stays")
        for ok in [w.work, w.home + "/Documents", w.home + "/src"] { XCTAssertNil(MacFencePaths.folderRefusal(ok, p), ok) }
        XCTAssertNotNil(MacFencePaths.folderRefusal(w.root + "/a\"b", p), "a quote cannot go into a profile")
    }

    func testAWorkdirWhoseGitConfigIsALinkIsRefused() throws {
        try FileManager.default.createDirectory(atPath: w.work + "/.git", withIntermediateDirectories: true)
        symlink(w.home + "/.aws/credentials", w.work + "/.git/config")
        XCTAssertNotNil(MacFencePaths.workdirRefusal(w.work, w.places))
        XCTAssertThrowsError(try w.fence())
    }

    /// 1.3a: a PATH link's target folder (its install root for a bin/), a link into a secret place not followed, a link to a
    /// file directly in the home opens that file only, a PATH entry that is the home or ~/Library is not opened.
    func testPathLinksResolveReadOnly() throws {
        let h = w.home
        w.write(h + "/.local/share/tool/v1/tool", "#!/bin/sh\necho tool\n")
        chmod(h + "/.local/share/tool/v1/tool", 0o755)
        w.write(h + "/.hermes/node/bin/node", "#!/bin/sh\n")
        chmod(h + "/.hermes/node/bin/node", 0o755)
        w.write(h + "/.config/x", "#!/bin/sh\n")
        chmod(h + "/.config/x", 0o755)
        w.write(h + "/loose", "#!/bin/sh\n")
        chmod(h + "/loose", 0o755)
        try FileManager.default.createDirectory(atPath: h + "/.local/bin", withIntermediateDirectories: true)
        symlink(h + "/.local/share/tool/v1/tool", h + "/.local/bin/tool")
        symlink(h + "/.hermes/node/bin/node", h + "/.local/bin/node")
        symlink(h + "/.config/x", h + "/.local/bin/cfg")
        symlink(h + "/loose", h + "/.local/bin/loose")
        let r = MacFencePaths.homeReads(w.places, path: "/usr/bin:\(h)/.local/bin:\(h):\(h)/Library")
        XCTAssertTrue(r.folders.contains(h + "/.local/bin"), "a toolchain root")
        XCTAssertTrue(r.folders.contains(h + "/.local/share/tool/v1"), "a link's target folder")
        XCTAssertTrue(r.folders.contains(h + "/.hermes/node"), "a bin/ target opens its install root")
        XCTAssertFalse(r.folders.contains { MacFencePaths.isWithin(h + "/.config/x", $0) } || r.files.contains(h + "/.config/x"), "never into .config")
        XCTAssertTrue(r.notes.contains { $0.contains(".config") }, "and said")
        XCTAssertTrue(r.files.contains(h + "/loose") && !r.folders.contains(h), "a file in the home: that file only")
        XCTAssertFalse(r.folders.contains(h) || r.folders.contains(h + "/Library"), "a PATH entry that is the home or ~/Library is not opened")
        XCTAssertTrue(r.files.contains(h + "/.ssh/config") && r.files.contains(h + "/.ssh/id_x.pub") && !r.files.contains(h + "/.ssh/id_x"))
        // And for real: the linked tool runs, ls ~ and the history stay closed.
        let f = try w.fence(path: "/usr/bin:/bin:\(h)/.local/bin")
        try MacFenceSessionFolder.prepare(f, previous: nil, person: .init())
        let p = MacFenceProfile.render(f)
        XCTAssertEqual(w.sandboxed(p, [h + "/.local/bin/tool"]).code, 0, "the linked tool runs")
        XCTAssertNotEqual(w.sandboxed(p, ["/bin/cat", h + "/.zsh_history"]).code, 0)
        XCTAssertNotEqual(w.sandboxed(p, ["/bin/ls", h]).code, 0)
    }

    func testReadAndWriteFolders_andTheirRefusals() throws {
        let extra = w.home + "/src/lib"
        try FileManager.default.createDirectory(atPath: extra, withIntermediateDirectories: true)
        w.write(w.home + "/notes/n.txt", "n")
        let f = try w.fence(write: [extra], read: [w.home + "/notes"])
        XCTAssertEqual(f.writable, [extra])
        XCTAssertEqual(f.readable, [w.home + "/notes"])
        try MacFenceSessionFolder.prepare(f, previous: nil, person: .init())
        let p = MacFenceProfile.render(f)
        XCTAssertEqual(w.sandboxed(p, ["/bin/sh", "-c", "echo x > \"$1/y\"", "sh", extra]).code, 0)
        XCTAssertEqual(w.sandboxed(p, ["/bin/cat", w.home + "/notes/n.txt"]).code, 0)
        XCTAssertNotEqual(w.sandboxed(p, ["/bin/sh", "-c", "echo x > \"$1/y\"", "sh", w.home + "/notes"]).code, 0, "--read is read-only")
        for bad in [w.home, w.home + "/.ssh", w.home + "/Library", w.store] {
            XCTAssertThrowsError(try w.fence(write: [bad]), bad)
            XCTAssertThrowsError(try w.fence(read: [bad]), bad)
        }
    }

    func testFenceReadSetting() {
        XCTAssertNil(MacFencePaths.fenceReadProblem("notes, src/shared"))
        XCTAssertNil(MacFencePaths.fenceReadProblem(""))
        for bad in ["/etc", "~/x", "a/../b", ".ssh", "Library", ".ssh/id_x", "Library/Keychains/login"] {
            XCTAssertNotNil(MacFencePaths.fenceReadProblem(bad), bad)
        }
        XCTAssertThrowsError(try DozableSettings.definition(SettingKey.macFenceRead)!.parse(".ssh"))
        XCTAssertNoThrow(try DozableSettings.definition(SettingKey.macFenceRead)!.parse("notes"))
        let r = MacFencePaths.homeReads(w.places, path: "/usr/bin", extra: ["Documents", "nope"])
        XCTAssertTrue(r.folders.contains(w.home + "/Documents"))
        XCTAssertTrue(r.notes.contains { $0.contains("nope") })
    }
}

/// The fenced environment (1.17).
final class MacFenceEnvironmentTests: XCTestCase {
    func testWhatAFencedSessionGets() throws {
        let w = try FenceScratch()
        defer { w.remove() }
        let f = try w.fence()
        let host = ["HOME": "/Users/x", "USER": "x", "SHELL": "/bin/zsh", "TMPDIR": "/var/folders/T/", "SSH_AUTH_SOCK": "/tmp/agent",
                    "CLAUDECODE": "1", "CLAUDE_CODE_ENTRYPOINT": "cli", "ANTHROPIC_API_KEY": "k", "GITHUB_TOKEN": "t", "XPC_SERVICE_NAME": "x",
                    "__CF_USER_TEXT_ENCODING": "0x1", "DOZ_STORE": "/s", "DOZ_TEST_GUARD": "1"]
        var env = try MacSessionsEnvironment.build(host: host, path: "/usr/bin:/bin")
        MacFenceEnvironment.add(&env, fence: f)
        XCTAssertEqual(env["TMPDIR"], f.tmp + "/")
        XCTAssertNil(env["SSH_AUTH_SOCK"])
        for k in env.keys {
            XCTAssertFalse(k.hasPrefix("CLAUDE") || k.hasPrefix("ANTHROPIC") || k == "GITHUB_TOKEN" || k.hasPrefix("XPC_") || k.hasPrefix("__CF"), k)
            if k.hasPrefix("DOZ_") { XCTAssertTrue(["DOZ_TTY", "DOZ_FENCE", "DOZ_DERIVED"].contains(k), k) }
        }
        for (k, _) in MacFenceEnvironment.caches { XCTAssertTrue(env[k]!.hasPrefix(f.cache + "/"), k) }
        XCTAssertEqual(env["GIT_CONFIG_GLOBAL"], f.etc + "/gitconfig")
        XCTAssertEqual(env["GIT_TEMPLATE_DIR"], f.etc + "/git-template")
        XCTAssertEqual(env["DISABLE_AUTOUPDATER"], "1")
        XCTAssertEqual(env["DOZ_FENCE"], "agent")
    }
}

/// The git allowlist, the guard (strip, stop, quarantine), and the git shapes.
final class MacFenceGitTests: XCTestCase {
    var w: FenceScratch!
    override func setUpWithError() throws { w = try FenceScratch() }
    override func tearDown() { w.remove() }

    func testTheAllowlist() {
        let wt = w.work, wd = w.work
        for (k, v) in [("branch.main.remote", "origin"), ("branch.Feature/X.merge", "refs/heads/x"), ("remote.origin.url", "https://github.com/a/b"),
                       ("remote.o.url", "git@github.com:a/b.git"), ("remote.o.url", "ssh://git@h/x"), ("remote.o.url", "../sibling-inside-is-not"),
                       ("remote.o.fetch", "+refs/heads/*:refs/remotes/o/*"), ("submodule.s.active", "true"), ("core.bare", "false"),
                       ("core.filemode", "true"), ("lfs.locksverify", "false"), ("remote.o.url", "sub/repo")] where v != "../sibling-inside-is-not" {
            XCTAssertTrue(MacFenceGit.allowed(k, v, worktree: wt, workdir: wd), "\(k)=\(v)")
        }
        for (k, v) in [("core.hooksPath", ".h"), ("core.fsmonitor", "x"), ("pager.log", "x"), ("remote.o.uploadpack", "x"), ("remote.o.vcs", "x"),
                       ("url.x.insteadOf", "y"), ("protocol.ext.allow", "always"), ("submodule.s.update", "!x"), ("difftool.x.cmd", "x"),
                       ("core.gitProxy", "x"), ("core.worktree", "/"), ("extensions.worktreeConfig", "true"), ("whatever.unknown", "1"),
                       ("remote.o.url", "ext::sh -c x"), ("remote.o.url", "-oProxyCommand=x"), ("remote.o.url", "file:///etc"),
                       ("remote.o.url", "http://h/x"), ("remote.o.url", "../outside"), ("core.bare", "true"), ("user.email", "a@b"),
                       ("core.sshCommand", "x"), ("core.pager", "x"), ("include.path", "x"), ("alias.x", "!x")] {
            XCTAssertFalse(MacFenceGit.allowed(k, v, worktree: wt, workdir: wd), "\(k)=\(v)")
        }
    }

    func testParseList() {
        let e = MacFenceGit.parseList("core.bare\nfalse\u{0}remote.o.url\nhttps://x\u{0}core.weird\u{0}")
        XCTAssertEqual(e.map { $0.0 }, ["core.bare", "remote.o.url", "core.weird"])
        XCTAssertEqual(e.map { $0.1 }, ["false", "https://x", ""])
    }

    func git(_ args: [String], in dir: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", dir] + args
        p.environment = ["HOME": w.root, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "PATH": "/usr/bin:/bin"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }

    final class Calls: @unchecked Sendable {
        let lock = NSLock()
        var stops = 0
        var reports: [MacFenceGitViolation] = []
    }

    func makeGuard(_ calls: Calls) throws -> MacFenceGitGuard {
        let state = w.store + "/state/s1"
        try MacFenceHostFS.ensureDirectory(state)
        return MacFenceGitGuard(session: "s1", workdir: w.work, roots: [w.work], stateFolder: state, quarantine: w.store + "/quarantine/s1",
                                stop: { calls.lock.withLock { calls.stops += 1 } },
                                report: { v in calls.lock.withLock { calls.reports.append(v) } })
    }

    /// 1.5 / 1.5a: allowlisted changes are kept and stop nothing; every other key is stripped (the person's own keys kept),
    /// the session stopped, the stripped text in the quarantine — never in the folder.
    func testTheGuardStripsStopsAndQuarantines() throws {
        git(["init", "-q"], in: w.work)
        git(["config", "core.sshCommand", "ssh -i mine"], in: w.work)          // the person's own, at open: trusted
        let calls = Calls()
        let g = try makeGuard(calls)
        _ = try g.recordBaseline()
        git(["config", "branch.x.remote", "origin"], in: w.work)
        git(["config", "remote.o.url", "https://example.com/r.git"], in: w.work)
        XCTAssertTrue(g.check().isEmpty, "allowlisted changes")
        XCTAssertEqual(calls.stops, 0)
        for (k, v) in [("core.fsmonitor", "touch /tmp/x"), ("core.hooksPath", "zq-hooks"), ("pager.log", "zq-pager"), ("remote.o.uploadpack", "zq-up"),
                       ("url.x.insteadOf", "https://zq-y"), ("protocol.ext.allow", "zq-always"), ("extensions.worktreeConfig", "zq-true"),
                       ("an.unknown", "zq-1"), ("remote.p.url", "ext::sh -c x")] {
            git(["config", k, v], in: w.work)
            let found = g.check()
            XCTAssertFalse(found.isEmpty, k)
            let text = w.read(w.work + "/.git/config") ?? ""
            XCTAssertFalse(text.contains(v), "\(k) stripped")
            XCTAssertTrue(text.contains("ssh -i mine"), "the person's own key is kept")
            XCTAssertTrue(text.contains("https://example.com/r.git"), "allowlisted keys are kept")
        }
        XCTAssertGreaterThan(calls.stops, 0)
        let q = (try? FileManager.default.contentsOfDirectory(atPath: w.store + "/quarantine/s1")) ?? []
        XCTAssertTrue(q.contains { $0.hasSuffix(".txt") })
        let all = q.map { w.read(w.store + "/quarantine/s1/" + $0) ?? "" }.joined()
        XCTAssertTrue(all.contains("core.fsmonitor = touch /tmp/x"), "kept in the store")
    }

    /// 1.5c: a config replaced by a link is never read (nothing of its target anywhere); it is rebuilt from the baseline.
    func testAConfigReplacedByALinkIsNeverRead() throws {
        git(["init", "-q"], in: w.work)
        let calls = Calls()
        let g = try makeGuard(calls)
        _ = try g.recordBaseline()
        unlink(w.work + "/.git/config")
        symlink(w.home + "/.aws/credentials", w.work + "/.git/config")
        let found = g.check()
        XCTAssertFalse(found.isEmpty)
        XCTAssertNotEqual(MacFenceHostFS.kind(w.work + "/.git/config"), S_IFLNK, "the link is gone")
        XCTAssertTrue(w.read(w.work + "/.git/config")?.contains("repositoryformatversion") == true, "rebuilt from the baseline")
        for n in (try? FileManager.default.contentsOfDirectory(atPath: w.store + "/quarantine/s1")) ?? [] where n.hasSuffix(".txt") {
            XCTAssertFalse((w.read(w.store + "/quarantine/s1/" + n) ?? "").contains("SECRET"))
        }
        XCTAssertEqual(w.read(w.home + "/.aws/credentials"), "[default]\naws_secret_access_key=SECRET\n", "the target untouched")
    }

    /// 1.5e / 1.5f: a .git FILE pointing at an ordinary folder, a bare-repository shape, a config.worktree change; a real
    /// worktree pointer is not a violation.
    func testGitShapes() throws {
        git(["init", "-q"], in: w.work)
        git(["-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-q", "--allow-empty", "-m", "x"], in: w.work)
        let calls = Calls()
        let g = try makeGuard(calls)
        _ = try g.recordBaseline()
        // A real worktree's pointer.
        git(["worktree", "add", "-q", w.work + "/wt"], in: w.work)
        XCTAssertTrue(g.check().filter { $0.path.hasSuffix("/wt/.git") }.isEmpty, "a real worktree is not a violation")
        // A .git file pointing at an ordinary folder with config + hooks.
        try FileManager.default.createDirectory(atPath: w.work + "/gd/hooks", withIntermediateDirectories: true)
        w.write(w.work + "/gd/config", "[core]\n\tfsmonitor = touch /tmp/pwn\n")
        w.write(w.work + "/sub/.git", "gitdir: \(w.work)/gd\n")
        var found = g.check()
        XCTAssertTrue(found.contains { $0.path == w.work + "/sub/.git" })
        XCTAssertNil(MacFenceHostFS.kind(w.work + "/sub/.git"), "the .git file is taken out")
        // A bare shape.
        try FileManager.default.createDirectory(atPath: w.work + "/x/objects", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: w.work + "/x/hooks", withIntermediateDirectories: true)
        w.write(w.work + "/x/HEAD", "ref: refs/heads/main\n")
        w.write(w.work + "/x/config", "[core]\n\tfsmonitor = x\n")
        found = g.check()
        XCTAssertTrue(found.contains { $0.path == w.work + "/x" })
        XCTAssertNil(MacFenceHostFS.kind(w.work + "/x/config"))
        XCTAssertNil(MacFenceHostFS.kind(w.work + "/x/hooks"))
        // config.worktree.
        w.write(w.work + "/.git/config.worktree", "[core]\n\thooksPath = .h\n")
        found = g.check()
        XCTAssertTrue(found.contains { $0.path == w.work + "/.git/config.worktree" })
        XCTAssertFalse((w.read(w.work + "/.git/config.worktree") ?? "").contains("hooksPath"))
        // A new repository arriving with a hook.
        try FileManager.default.createDirectory(atPath: w.root + "/elsewhere", withIntermediateDirectories: true)
        git(["init", "-q", w.root + "/elsewhere/r"], in: w.root)
        w.write(w.root + "/elsewhere/r/.git/hooks/pre-commit", "#!/bin/sh\ntouch /tmp/pwn\n")
        try FileManager.default.moveItem(atPath: w.root + "/elsewhere/r", toPath: w.work + "/r")
        found = g.check()
        XCTAssertTrue(found.contains { $0.what.contains { $0.contains("pre-commit") } }, "a hook that arrived with a repository")
        XCTAssertNil(MacFenceHostFS.kind(w.work + "/r/.git/hooks/pre-commit"))
    }

    /// 1.5g: includes — a target inside the folder is protected; a linked one makes the open refuse.
    func testIncludes() throws {
        git(["init", "-q"], in: w.work)
        w.write(w.work + "/team.gitconfig", "[user]\n\tname = t\n")
        git(["config", "include.path", "../team.gitconfig"], in: w.work)
        XCTAssertEqual(try MacFenceGit.protectedPaths(workdir: w.work, hooksPathGlobal: nil, home: w.home, scratch: w.store), [w.work + "/team.gitconfig"])
        let f = try w.fence()
        try MacFenceSessionFolder.prepare(f, previous: nil, person: .init())
        XCTAssertNotEqual(w.sandboxed(MacFenceProfile.render(f), ["/bin/sh", "-c", "echo '[core]' >> team.gitconfig"]).code, 0, "the include is write-denied")
        unlink(w.work + "/team.gitconfig")
        symlink(w.home + "/.aws/credentials", w.work + "/team.gitconfig")
        XCTAssertThrowsError(try MacFenceGit.protectedPaths(workdir: w.work, hooksPathGlobal: nil, home: w.home, scratch: w.store), "a linked include: unverifiable")
    }

    /// The watch itself: a change made by a program is dealt with in under a second.
    func testTheWatchActsWithinASecond() throws {
        git(["init", "-q"], in: w.work)
        let calls = Calls()
        let g = try makeGuard(calls)
        _ = try g.recordBaseline()
        g.start()
        defer { g.cancel() }
        usleep(300_000)
        let t0 = Date()
        git(["config", "core.fsmonitor", "x"], in: w.work)
        while Date().timeIntervalSince(t0) < 5, calls.lock.withLock({ calls.reports.isEmpty }) { usleep(20_000) }
        XCTAssertFalse(calls.lock.withLock { calls.reports.isEmpty })
        XCTAssertLessThan(Date().timeIntervalSince(t0), 1.5)
        XCTAssertFalse((w.read(w.work + "/.git/config") ?? "").contains("fsmonitor"))
    }
}

/// The host's own file operations (§1.13) against trees whose components are links.
final class MacFenceHostFSTests: XCTestCase {
    var w: FenceScratch!
    override func setUpWithError() throws { w = try FenceScratch() }
    override func tearDown() { w.remove() }

    func testReadsRefuseLinksHardLinksAndOddFiles() throws {
        w.write(w.work + "/f", "x")
        XCTAssertEqual(try MacFenceHostFS.readRegular(w.work + "/f", maximum: 10), Data("x".utf8))
        symlink(w.home + "/.aws/credentials", w.work + "/l")
        XCTAssertThrowsError(try MacFenceHostFS.readRegular(w.work + "/l", maximum: 1000))
        link(w.home + "/.aws/credentials", w.work + "/h")
        XCTAssertThrowsError(try MacFenceHostFS.readRegular(w.work + "/h", maximum: 1000), "a hard link")
        mkfifo(w.work + "/fifo", 0o600)
        XCTAssertThrowsError(try MacFenceHostFS.readRegular(w.work + "/fifo", maximum: 1000), "a FIFO")
        try FileManager.default.createDirectory(atPath: w.work + "/d", withIntermediateDirectories: true)
        symlink(w.home, w.work + "/d/up")
        XCTAssertThrowsError(try MacFenceHostFS.readRegular(w.work + "/d/up/.zsh_history", maximum: 1000), "a link in a middle component")
        XCTAssertThrowsError(try MacFenceHostFS.readRegular("/tmp/" + (w.root as NSString).lastPathComponent + "/work/f", maximum: 10), "/tmp itself is a link")
    }

    /// 1.26: a clear never crosses a link — the folder swapped for a link, a nested link, a link inside.
    func testAClearNeverCrossesALink() throws {
        let dir = w.work + "/agent"
        try FileManager.default.createDirectory(atPath: dir + "/x", withIntermediateDirectories: true)
        w.write(dir + "/x/y", "1")
        symlink(w.home + "/Documents", dir + "/docs")
        symlink(w.home + "/Documents", dir + "/x/docs")
        XCTAssertNoThrow(try MacFenceHostFS.clearContents(dir))
        XCTAssertEqual(w.read(w.home + "/Documents/doc.txt"), "mine", "nothing behind a link removed")
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? ["?"], [])
        // The folder itself swapped for a link.
        try FileManager.default.removeItem(atPath: dir)
        symlink(w.home + "/Documents", dir)
        XCTAssertThrowsError(try MacFenceHostFS.clearContents(dir))
        XCTAssertEqual(w.read(w.home + "/Documents/doc.txt"), "mine")
        // A writeAtomically onto a name that is a link is refused (the link not written through).
        unlink(dir)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        symlink(w.home + "/Documents/doc.txt", dir + "/settings.json")
        XCTAssertThrowsError(try MacFenceHostFS.writeAtomically(Data("x".utf8), dir: dir, name: "settings.json"))
        XCTAssertEqual(w.read(w.home + "/Documents/doc.txt"), "mine")
    }

    /// A clear racing a program that swaps a component for a link (1.26, the racing loop).
    func testAClearRacingALinkSwap() throws {
        let dir = w.work + "/agent"
        for round in 0..<20 {
            try? FileManager.default.removeItem(atPath: dir)
            try FileManager.default.createDirectory(atPath: dir + "/a/b", withIntermediateDirectories: true)
            for i in 0..<50 { w.write(dir + "/a/b/f\(i)", "x") }
            let stop = DispatchSemaphore(value: 0)
            let a = dir + "/a"
            let target = w.home + "/Documents"
            Thread.detachNewThread {
                while stop.wait(timeout: .now()) == .timedOut {
                    rename(a, a + ".old")
                    symlink(target, a)
                    usleep(50)
                    unlink(a)
                    rename(a + ".old", a)
                }
            }
            _ = try? MacFenceHostFS.clearContents(dir)
            stop.signal()
            usleep(2_000)
            XCTAssertEqual(w.read(w.home + "/Documents/doc.txt"), "mine", "round \(round)")
        }
    }

    func testWalkDoesNotFollowLinks() throws {
        try FileManager.default.createDirectory(atPath: w.work + "/a", withIntermediateDirectories: true)
        symlink(w.home, w.work + "/a/home")
        var seen: [String] = []
        MacFenceHostFS.walk(w.work) { p, _ in seen.append(p); return true }
        XCTAssertTrue(seen.contains(w.work + "/a/home"))
        XCTAssertFalse(seen.contains { $0.contains(".zsh_history") })
    }
}

/// The session folder: re-seeded every open; caches kept, emptied when the grants widen (1.21, 1.27).
final class MacFenceSessionFolderTests: XCTestCase {
    func testReseedAndGrants() throws {
        let w = try FenceScratch()
        defer { w.remove() }
        w.write(w.home + "/.ssh/known_hosts", "host1 ssh-ed25519 AAAA\n")
        var person = MacFenceSessionFolder.PersonGit()
        person.values = [("user.name", "Me"), ("user.email", "me@example.com")]
        person.excludes = "*.log\n"
        let f = try w.fence()
        try MacFenceSessionFolder.prepare(f, previous: nil, person: person)
        let cfg = w.read(f.etc + "/gitconfig") ?? ""
        XCTAssertTrue(cfg.contains("name = \"Me\"") && cfg.contains("excludesfile = \"\(f.etc)/excludes\""))
        XCTAssertEqual(w.read(f.etc + "/excludes"), "*.log\n")
        XCTAssertEqual(w.read(f.ssh + "/known_hosts"), "host1 ssh-ed25519 AAAA\n")
        XCTAssertNotNil(MacFenceHostFS.kind(f.sentinel))
        XCTAssertNotNil(MacFenceHostFS.kind(f.antiSentinel))
        w.write(f.tmp + "/t", "1")
        w.write(f.cache + "/npm/x", "1")
        w.write(f.derived + "/y", "1")
        // The same grants: tmp emptied, caches kept.
        var again = try w.fence()
        again.tag = f.tag
        let s1 = try MacFenceSessionFolder.prepare(again, previous: f.grants, person: person)
        XCTAssertFalse(s1.cachesCleared)
        XCTAssertNil(MacFenceHostFS.kind(f.tmp + "/t"))
        XCTAssertNotNil(MacFenceHostFS.kind(f.cache + "/npm/x"))
        // Wider (the Keychain): caches and DerivedData emptied.
        let wider = try w.fence(keychain: true)
        let s2 = try MacFenceSessionFolder.prepare(wider, previous: f.grants, person: person)
        XCTAssertTrue(s2.cachesCleared)
        XCTAssertNil(MacFenceHostFS.kind(f.cache + "/npm/x"))
        XCTAssertNil(MacFenceHostFS.kind(f.derived + "/y"))
        // Narrower again: kept.
        w.write(f.cache + "/z", "1")
        _ = try MacFenceSessionFolder.prepare(f, previous: wider.grants, person: person)
        XCTAssertNotNil(MacFenceHostFS.kind(f.cache + "/z"))
        // 1.26: its temp swapped for a link to the person's Documents, a cache entry a link: the re-seed removes the
        // links as links — the Documents untouched.
        try FileManager.default.removeItem(atPath: f.tmp)
        symlink(w.home + "/Documents", f.tmp)
        symlink(w.home + "/Documents", f.cache + "/docs")
        let s3 = try MacFenceSessionFolder.prepare(wider, previous: f.grants, person: person)
        XCTAssertEqual(MacFenceHostFS.kind(f.tmp), S_IFDIR)
        XCTAssertTrue(s3.notes.contains { $0.contains("tmp/") })
        XCTAssertNil(MacFenceHostFS.kind(f.cache + "/docs"))
        XCTAssertEqual(w.read(w.home + "/Documents/doc.txt"), "mine")
    }

    func testTheGitconfigCarriesOnlyTheAllowlist() throws {
        let w = try FenceScratch()
        defer { w.remove() }
        w.write(w.home + "/.gitconfig", """
        [user]
        \tname = Me
        \temail = me@example.com
        [credential]
        \thelper = osxkeychain
        [alias]
        \tx = !rm -rf /
        [core]
        \thooksPath = ~/hooks
        \tfsmonitor = x
        \tpager = less
        [url "https://evil"]
        \tinsteadOf = https://github.com
        [filter "lfs"]
        \tclean = git-lfs clean -- %f
        \tprocess = git-lfs filter-process
        [include]
        \tpath = ~/.gitconfig.local
        """)
        w.write(w.home + "/.gitconfig.local", "[user]\n\tsigningkey = K\n")
        let p = MacFenceSessionFolder.personGit(home: w.home)
        let keys = p.values.map(\.0)
        XCTAssertEqual(Set(keys), ["user.name", "user.email", "filter.lfs.clean", "filter.lfs.process"])
        XCTAssertEqual(p.hooksPath, w.home + "/hooks")
        let text = MacFenceSessionFolder.gitconfig(p, etc: "/x/etc")
        for bad in ["osxkeychain", "rm -rf", "fsmonitor", "pager", "evil", "signingkey", "include"] { XCTAssertFalse(text.contains(bad), bad) }
    }
}

/// Stopping every process of a fence — a detached one too — and nothing else (1.5b), by `sandbox_check` and the sentinel.
final class MacFenceStopTests: XCTestCase {
    func testStopFindsTheFenceAndOnlyIt() throws {
        let w = try FenceScratch()
        defer { w.remove() }
        guard MacFenceStop.available else { throw XCTSkip("sandbox_check is not available here") }
        XCTAssertEqual(MacFenceStop.sandboxed(getpid()), false, "this test process is not sandboxed")
        let f = try w.fence()
        try MacFenceSessionFolder.prepare(f, previous: nil, person: .init())
        let pf = w.root + "/fence.sb"
        w.write(pf, MacFenceProfile.render(f))
        // The program, and a detached child that leaves its group (setsid via a double fork through `sh -c … &`).
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        p.arguments = ["-f", pf, "-D", "TTY=/dev/null", "--", "/bin/sh", "-c", "(/bin/sleep 60 &) ; exec /bin/sleep 60"]
        p.currentDirectoryURL = URL(fileURLWithPath: w.work)
        try p.run()
        defer { p.terminate() }
        // An unfenced bystander.
        let b = Process()
        b.executableURL = URL(fileURLWithPath: "/bin/sleep")
        b.arguments = ["60"]
        try b.run()
        defer { b.terminate() }
        usleep(500_000)
        let m = MacFenceStop.members(sentinel: f.sentinel, anti: f.antiSentinel, program: p.processIdentifier)
        XCTAssertEqual(m.how, "sandbox_check")
        XCTAssertTrue(m.pids.contains(p.processIdentifier), "the program")
        XCTAssertGreaterThanOrEqual(m.pids.count, 2, "and its detached child")
        XCTAssertFalse(m.pids.contains(b.processIdentifier), "never an unfenced process")
        let s = MacFenceStop.stop(sentinel: f.sentinel, anti: f.antiSentinel, program: p.processIdentifier)
        for pid in s.pids { XCTAssertTrue(MacFenceStop.isStopped(pid_t(pid)), "\(pid) stopped") }
        XCTAssertFalse(MacFenceStop.isStopped(b.processIdentifier))
        MacFenceStop.resume(sentinel: f.sentinel, anti: f.antiSentinel, program: p.processIdentifier, also: s.pids.map(Int.init))
        usleep(100_000)
        for pid in s.pids { XCTAssertFalse(MacFenceStop.isStopped(pid), "\(pid) continued") }
        for pid in s.pids { kill(pid, SIGKILL) }
    }
}

/// Records: an older record (no fence) stays unfenced; the grants' widening rule.
final class MacFenceRecordTests: XCTestCase {
    func testAnOldRecordIsUnfenced() throws {
        let json = #"{"version":1,"sessions":{"a":{"argv":["sh"],"workdir":"/tmp","openedAt":"2026-01-01T00:00:00Z"}}}"#
        let r = try HostWire.decoder.decode(MacSessionRecords.self, from: Data(json.utf8))
        XCTAssertNil(r.sessions["a"]?.fence)
    }

    func testGrantsWiden() {
        let base = MacFenceGrants(profile: "agent", keychain: false, readable: ["/r"], writable: ["/w"])
        XCTAssertFalse(base.widens(nil))
        XCTAssertFalse(base.widens(base))
        XCTAssertTrue(MacFenceGrants(profile: "agent", keychain: true, readable: ["/r"], writable: ["/w"]).widens(base))
        XCTAssertTrue(MacFenceGrants(profile: "xcode", keychain: false, readable: ["/r"], writable: ["/w"]).widens(base))
        XCTAssertTrue(MacFenceGrants(profile: "agent", keychain: false, readable: ["/r", "/s"], writable: ["/w"]).widens(base))
        XCTAssertTrue(MacFenceGrants(profile: "agent", keychain: false, readable: ["/r"], writable: ["/w", "/v"]).widens(base))
        XCTAssertFalse(MacFenceGrants(profile: "agent", keychain: false, readable: ["/w"], writable: []).widens(base), "narrower")
    }

    func testTheFencedVersionIsRefusedByAnOlderHost() {
        XCTAssertGreaterThan(HostProtocol.fencedVersion, HostProtocol.version)
        XCTAssertGreaterThanOrEqual(HostProtocol.accepted, HostProtocol.fencedVersion)
    }
}
