import Darwin
import Foundation
@testable import DozableKit
import XCTest
@testable import DozableCLI
@testable import DozableHost

/// `doz fence-connect`: the proxy it uses, what it asks, what it says when refused.
final class FenceConnectTests: XCTestCase {
    func testTheProxyComesOnlyFromTheSessionsLoopbackURL() {
        let p = FenceConnect.proxy(from: ["HTTPS_PROXY": "http://doz:s3cr%2Bt@127.0.0.1:41234"])
        XCTAssertEqual(p, FenceConnect.Proxy(port: 41234, user: "doz", password: "s3cr+t"))
        XCTAssertEqual(FenceConnect.proxy(from: ["https_proxy": "http://doz:x@127.0.0.1:9"])?.port, 9)
        XCTAssertNil(FenceConnect.proxy(from: ["HTTPS_PROXY": "http://doz:x@proxy.example.com:8080"]), "never another host")
        XCTAssertNil(FenceConnect.proxy(from: ["HTTPS_PROXY": "socks5://127.0.0.1:1080"]))
        XCTAssertNil(FenceConnect.proxy(from: [:]))
    }

    func testTargetsAndTheRequest() {
        XCTAssertNil(FenceConnect.targetProblem(host: "github.com", port: "22"))
        for (h, p) in [("", "22"), ("a b", "22"), ("x\r\nHost: y", "22"), ("github.com", "0"), ("github.com", "70000"), ("github.com", "x"), ("u@h", "22")] {
            XCTAssertNotNil(FenceConnect.targetProblem(host: h, port: p), "\(h):\(p)")
        }
        let r = FenceConnect.request(host: "github.com", port: "22", proxy: .init(port: 1, user: "doz", password: "pw"))
        XCTAssertTrue(r.hasPrefix("CONNECT github.com:22 HTTP/1.1\r\nHost: github.com:22\r\n"))
        XCTAssertTrue(r.contains("Proxy-Authorization: Basic " + Data("doz:pw".utf8).base64EncodedString() + "\r\n"))
        XCTAssertTrue(r.hasSuffix("\r\n\r\n"))
        XCTAssertTrue(FenceConnect.request(host: "::1", port: "22", proxy: .init(port: 1, user: "", password: "")).hasPrefix("CONNECT [::1]:22 "))
    }

    func testARefusalSaysTheProxysReason() {
        let reply = Array("HTTP/1.1 403 Forbidden\r\nContent-Length: 60\r\n\r\nblocked by the sandbox network policy: x.test:22 (default deny)\n".utf8)
        XCTAssertEqual(FenceConnect.refusal(reply), "blocked by the sandbox network policy: x.test:22 (default deny)")
    }

    func testWithoutAProxyItSaysWhereItRuns() {
        XCTAssertEqual(FenceConnect.run(["github.com", "22"], environment: [:]), 1)
        XCTAssertEqual(FenceConnect.run(["github.com"], environment: [:]), 64)
    }
}

/// M4's environment: git's helper, ssh through fence-connect, the SSH agent, gh's door, Xcode's DerivedData.
final class MacFenceToolsEnvironmentTests: XCTestCase {
    var w: FenceScratch!
    override func setUpWithError() throws { w = try FenceScratch() }
    override func tearDown() { w.remove() }

    func env(_ f: MacFence) throws -> [String: String] {
        var e = try MacSessionsEnvironment.build(host: ["HOME": "/Users/x", "SSH_AUTH_SOCK": "/tmp/person-agent", "GH_TOKEN": "ghp_person"], path: "/usr/bin:/bin")
        MacFenceEnvironment.add(&e, fence: f, proxyPassword: "pw", ca: true)
        return e
    }
    func gitConfig(_ e: [String: String]) -> [(String, String)] {
        (0..<(Int(e["GIT_CONFIG_COUNT"] ?? "0") ?? 0)).map { (e["GIT_CONFIG_KEY_\($0)"] ?? "", e["GIT_CONFIG_VALUE_\($0)"] ?? "") }
    }

    func testGitHubHelperAndTheNoCredentialHelper() throws {
        var f = try w.fence()
        f.proxyPort = 4000
        var e = try env(f)
        var g = gitConfig(e)
        XCTAssertEqual(g.first?.0, "http.proxyAuthMethod")
        XCTAssertTrue(g.contains { $0 == ("credential.helper", "") }, "the system's osxkeychain helper dropped")
        XCTAssertEqual(g.last?.1, MacFenceEnvironment.noGitHubHelper)
        XCTAssertNil(e["GH_TOKEN"], "the host's GH_TOKEN never passes")
        f.github = .read
        f.ghSocket = w.root + "/sock/s1.gh"
        f.placeholders["GH_TOKEN"] = "doz_cred_" + String(repeating: "a", count: 48)
        e = try env(f)
        g = gitConfig(e)
        XCTAssertEqual(g.last?.0, "credential.https://github.com.helper")
        XCTAssertEqual(g.last?.1, MacFenceEnvironment.githubHelper)
        XCTAssertEqual(e["GH_TOKEN"], f.placeholders["GH_TOKEN"])
        XCTAssertEqual(e["GH_CONFIG_DIR"], f.cache + "/config/gh")
        // The helpers, run by a shell as git would: the placeholder for `get`, nothing for `store`; the refusal says why.
        func helper(_ h: String, _ op: String) -> (Int32, String, String) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", String(h.dropFirst()) + " \"$@\"", "helper", op]
            p.environment = ["GH_TOKEN": "doz_cred_x", "PATH": "/usr/bin:/bin"]
            let o = Pipe(), er = Pipe()
            p.standardOutput = o
            p.standardError = er
            try? p.run()
            p.waitUntilExit()
            return (p.terminationStatus, String(decoding: o.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                    String(decoding: er.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        }
        XCTAssertEqual(helper(MacFenceEnvironment.githubHelper, "get").1, "username=x-access-token\npassword=doz_cred_x\n")
        XCTAssertEqual(helper(MacFenceEnvironment.githubHelper, "store").1, "")
        let none = helper(MacFenceEnvironment.noGitHubHelper, "get")
        XCTAssertEqual(none.1, "quit=1\n")
        XCTAssertTrue(none.2.contains("--github push") && none.2.contains("--ssh-agent"))
    }

    func testSSHGoesThroughFenceConnect_withTheSessionsKnownHosts() throws {
        var f = try w.fence()
        f.dozExecutable = "/opt/doz it's/bin/doz"
        let e = try env(f)
        XCTAssertNil(e["SSH_AUTH_SOCK"], "the person's agent never passes")
        let cmd = try XCTUnwrap(e["GIT_SSH_COMMAND"])
        // As git runs it (a shell): ssh, then the options intact.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "ssh() { for a; do printf '%s\\n' \"$a\"; done; }; " + cmd]
        let o = Pipe()
        p.standardOutput = o
        try p.run()
        p.waitUntilExit()
        let args = String(decoding: o.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n").map(String.init)
        XCTAssertEqual(args, ["-o", "ProxyCommand=\"/opt/doz it's/bin/doz\" fence-connect %h %p", "-o", "UserKnownHostsFile=\"\(f.ssh)/known_hosts\"",
                              "-o", "StrictHostKeyChecking=accept-new"])
        XCTAssertTrue(MacFenceSessionFolder.sshShim(f).contains("exec /usr/bin/ssh -o 'ProxyCommand="))
        XCTAssertFalse(MacFenceEnvironment.sshCommand(doz: "/a\"b/doz", knownHosts: "/k").contains("ProxyCommand"), "a path a profile cannot carry: no way through")
    }

    func testTheAgentAndXcodesVariables() throws {
        var f = try w.fence()
        f.sshAgent = true
        f.agentSocket = w.root + "/sock/s1.agent"
        f.profile = "xcode"
        let e = try env(f)
        XCTAssertEqual(e["SSH_AUTH_SOCK"], f.agentSocket)
        XCTAssertEqual(e["DOZ_FENCE"], "xcode")
        XCTAssertEqual(e["DOZ_DERIVED"], f.derived)
        f.profile = "agent"
        XCTAssertNil(try env(f)["DOZ_DERIVED"])
    }
}

/// M4's profile rules: the doors, Xcode's profiles, submodules' hooks, a worktree's common git folder, doz itself.
final class MacFenceToolsProfileTests: XCTestCase {
    var w: FenceScratch!
    override func setUpWithError() throws { w = try FenceScratch() }
    override func tearDown() { w.remove() }

    func testXcodeAndTheSimulator() throws {
        var f = try w.fence()
        let agent = MacFenceProfile.render(f)
        XCTAssertFalse(agent.contains("launchservicesd") || agent.contains("CoreSimulator") || agent.contains("lsd.mapdb"))
        f.profile = "xcode"
        let x = MacFenceProfile.render(f)
        XCTAssertFalse(x.contains("launchservicesd") || x.contains("CoreSimulator") || x.contains("lsd.mapdb"), "--xcode: LaunchServices and the Simulator closed")
        XCTAssertFalse(x.contains("user-preference-write"), "no preference writes")
        f.profile = "simulator"
        let s = MacFenceProfile.render(f)
        XCTAssertTrue(s.contains("(global-name \"com.apple.coreservices.launchservicesd\")") && s.contains("(global-name-prefix \"com.apple.CoreSimulator.\")"))
        XCTAssertFalse(s.contains("user-preference-write") || s.contains("SecurityServer"))
        // Apple's tools' item-replacement and driver temp folders, never the whole user temp folder.
        XCTAssertTrue(agent.contains("TemporaryItems/NSIRD_(xcodebuild|"))
        XCTAssertFalse(agent.contains("(subpath \"\(w.places.userTemp)"))
    }

    func testXcodeReads_butNotItsBuilds() throws {
        try FileManager.default.createDirectory(atPath: w.home + "/Library/Developer/Xcode/DerivedData", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: w.home + "/Library/Developer/CoreSimulator", withIntermediateDirectories: true)
        let r = MacFencePaths.homeReads(w.places, path: "/usr/bin", profile: "xcode")
        XCTAssertTrue(r.folders.contains(w.home + "/Library/Developer/Xcode"))
        XCTAssertFalse(r.folders.contains(w.home + "/Library/Developer/CoreSimulator"))
        XCTAssertTrue(r.closed.contains(w.home + "/Library/Developer/Xcode/DerivedData"))
        XCTAssertTrue(MacFencePaths.homeReads(w.places, path: "/usr/bin", profile: "simulator").folders.contains(w.home + "/Library/Developer/CoreSimulator"))
        XCTAssertTrue(MacFencePaths.homeReads(w.places, path: "/usr/bin").closed.isEmpty)
    }

    func testTheDoorsAndDozItself() throws {
        var f = try w.fence()
        XCTAssertFalse(MacFenceProfile.render(f).contains("network-outbound (literal"))
        f.agentSocket = w.root + "/sock/s1.agent"
        f.ghSocket = w.root + "/sock/s1.gh"
        f.dozExecutable = "/opt/homebrew/bin/doz"
        let p = MacFenceProfile.render(f)
        XCTAssertTrue(p.contains("(allow network-outbound (literal \"\(w.root)/sock/s1.agent\"))"))
        XCTAssertTrue(p.contains("(allow network-outbound (literal \"\(w.root)/sock/s1.gh\"))"))
        XCTAssertTrue(p.contains("(allow file-read* (literal \"/opt/homebrew/bin/doz\"))"))
        XCTAssertTrue(p.split(separator: "\n").last?.contains("(subpath \"\(w.root)/sock\")") == true, "the socket folder stays closed to files, last")
    }

    /// A submodule's hooks cannot be written; a connect to one door works while the folder stays closed (sandbox-exec).
    func testSubmoduleHooksAndADoorHold() throws {
        var f = try w.fence()
        try MacFenceSessionFolder.prepare(f, previous: nil, person: .init())
        try FileManager.default.createDirectory(atPath: w.work + "/.git/modules/sub/hooks", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: w.work + "/.git/modules/sub/refs", withIntermediateDirectories: true)
        let door = w.root + "/sock/s1.gh"
        let d = try MacFenceDoor(path: door) { c in _ = Wire.writeAll(c, Array("HELLO\n".utf8)) }
        defer { d.stop() }
        f.ghSocket = door
        let p = MacFenceProfile.render(f)
        XCTAssertNotEqual(w.sandboxed(p, ["/bin/sh", "-c", "echo x > .git/modules/sub/hooks/post-checkout"]).code, 0)
        XCTAssertEqual(w.sandboxed(p, ["/bin/sh", "-c", "echo x > .git/modules/sub/refs/x"]).code, 0)
        XCTAssertEqual(w.sandboxed(p, ["/bin/sh", "-c", "/usr/bin/nc -U '\(door)' < /dev/null | grep -q HELLO"]).code, 0, "the door answers")
        XCTAssertNotEqual(w.sandboxed(p, ["/bin/ls", w.root + "/sock"]).code, 0, "its folder does not")
        f.ghSocket = nil
        XCTAssertNotEqual(w.sandboxed(MacFenceProfile.render(f), ["/bin/sh", "-c", "/usr/bin/nc -U '\(door)' < /dev/null | grep -q HELLO"]).code, 0, "no door: no connect")
    }

    func testAWorktreesCommonGitFolder() throws {
        let main = w.root + "/main", wt = w.root + "/wt"
        try FileManager.default.createDirectory(atPath: main, withIntermediateDirectories: true)
        func git(_ a: [String], _ dir: String) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", dir] + a
            p.environment = ["PATH": "/usr/bin:/bin", "HOME": w.home, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
        }
        git(["init", "-q"], main)
        git(["-c", "user.name=t", "-c", "user.email=t@x", "commit", "-q", "--allow-empty", "-m", "s"], main)
        git(["worktree", "add", "-q", "-b", "b", wt], main)
        XCTAssertEqual(try MacFenceGit.worktreeCommon(workdir: wt), main + "/.git")
        let f = try MacFence.make(session: "s1", workdir: wt, request: MacFenceRequest(), places: w.places, path: "/usr/bin", fenceRead: [],
                                  hooksPathGlobal: nil, scratch: w.store)
        XCTAssertEqual(f.gitCommon, [main + "/.git"])
        XCTAssertEqual(f.record(profileSHA256: "", gitBaseline: nil).gitCommon, [main + "/.git"])
        let p = MacFenceProfile.render(f)
        XCTAssertTrue(p.contains("(allow file-read* file-write* (subpath \"\(main)/.git\"))"))
        XCTAssertTrue(p.contains("(deny file-write* (subpath \"\(main)/.git/hooks\")"))
        XCTAssertTrue(f.grants.writable.contains(main + "/.git"), "a wider grant than the folder alone")
        // A worktree whose repository lives in a closed place is refused.
        let closed = w.store + "/repo"
        try FileManager.default.createDirectory(atPath: closed, withIntermediateDirectories: true)
        git(["init", "-q"], closed)
        git(["-c", "user.name=t", "-c", "user.email=t@x", "commit", "-q", "--allow-empty", "-m", "s"], closed)
        let wt2 = w.root + "/wt2"
        git(["worktree", "add", "-q", "-b", "c", wt2], closed)
        XCTAssertThrowsError(try MacFence.make(session: "s1", workdir: wt2, request: MacFenceRequest(), places: w.places, path: "/usr/bin", fenceRead: [],
                                               hooksPathGlobal: nil, scratch: w.store))
        // A .git file pointing nowhere.
        let odd = w.root + "/odd"
        try FileManager.default.createDirectory(atPath: odd, withIntermediateDirectories: true)
        w.write(odd + "/.git", "gitdir: /nonexistent\n")
        XCTAssertThrowsError(try MacFenceGit.worktreeCommon(workdir: odd))
    }

    func testASubmodulesWorktreeKeyIsAllowedInsideTheFolder() {
        let wd = "/w", g = "/w/.git/modules/sub"
        XCTAssertTrue(MacFenceGit.allowed("core.worktree", "../../../sub", worktree: g, workdir: wd, gitdir: g))
        XCTAssertFalse(MacFenceGit.allowed("core.worktree", "../../../../elsewhere", worktree: g, workdir: wd, gitdir: g))
        XCTAssertFalse(MacFenceGit.allowed("core.worktree", "../../../sub", worktree: "/w", workdir: wd, gitdir: "/w/.git"), "only a submodule's")
        XCTAssertFalse(MacFenceGit.allowed("core.worktree", "/", worktree: "/w", workdir: wd))
    }
}

/// M4's request, record, row, grants and capabilities.
final class MacFenceToolsRecordTests: XCTestCase {
    func testRequestAndRecord() throws {
        var q = MacFenceRequest()
        XCTAssertEqual(q.profile, "agent")
        q.xcode = true
        XCTAssertEqual(q.profile, "xcode")
        q.simulator = true
        XCTAssertEqual(q.profile, "simulator")
        let w = try FenceScratch()
        defer { w.remove() }
        var r = MacFenceRequest(); r.simulator = true; r.github = "push"; r.sshAgent = true
        let f = try MacFence.make(session: "s1", workdir: w.work, request: r, places: w.places, path: "/usr/bin", fenceRead: [], hooksPathGlobal: nil, scratch: w.store)
        XCTAssertEqual(f.profile, "simulator")
        XCTAssertEqual(f.github, .push)
        XCTAssertTrue(f.sshAgent)
        let rec = f.record(profileSHA256: "x", gitBaseline: nil)
        XCTAssertEqual(rec.profile, "simulator")
        XCTAssertEqual(rec.github, "push")
        XCTAssertEqual(rec.sshAgent, true)
        let back = rec.request
        XCTAssertEqual(back.profile, "simulator")
        XCTAssertEqual(back.github, "push")
        XCTAssertEqual(back.sshAgent, true)
        XCTAssertEqual(MacFenceRow(rec).state, "guard rail (Simulator)")
        XCTAssertTrue(f.line().contains("a guard rail, not a boundary") && f.line().contains("GitHub as you (read and push)") && f.line().contains("SSH agent"))
        var bad = MacFenceRequest(); bad.github = "write"
        XCTAssertThrowsError(try MacFence.make(session: "s1", workdir: w.work, request: bad, places: w.places, path: "/usr/bin", fenceRead: [], hooksPathGlobal: nil, scratch: w.store))
        let placeholders = ["GH_TOKEN": "doz_cred_aa", "CLAUDE_CODE_OAUTH_TOKEN": "doz_cred_bb"]
        var g = f
        g.placeholders = placeholders
        XCTAssertEqual(Set((g.record(profileSHA256: "", gitBaseline: nil).placeholderHashes ?? [:]).values), ["github", CredentialBinding.claudeOAuth.id])
    }

    func testGrantsWidenWithGitHubAndTheAgent() {
        let base = MacFenceGrants(profile: "agent", keychain: false, readable: [], writable: [])
        var g = base
        g.github = "read"
        XCTAssertTrue(g.widens(base))
        var p = g
        p.github = "push"
        XCTAssertTrue(p.widens(g))
        XCTAssertFalse(g.widens(p), "push → read is narrower")
        var a = base
        a.sshAgent = true
        XCTAssertTrue(a.widens(base))
        var s = base
        s.profile = "simulator"
        XCTAssertTrue(s.widens(MacFenceGrants(profile: "xcode", keychain: false, readable: [], writable: [])))
    }

    func testCapabilities() {
        var s = MacCapabilityShape(session: "s", workdir: "/w", fenced: true)
        func row(_ id: String) -> MacCapability? { MacFence.capabilities(s).first { $0.id == id } }
        XCTAssertEqual(row("fence")?.state, "fenced")
        XCTAssertEqual(row("github")?.state, "off")
        XCTAssertEqual(row("ssh-agent")?.state, "off")
        s.profile = "xcode"; s.github = "read"; s.sshAgent = true
        XCTAssertEqual(row("fence")?.state, "fenced (Xcode)")
        XCTAssertEqual(row("github")?.sentence, "Clones and reads as you; pushes are refused.")
        XCTAssertEqual(row("ssh-agent")?.state, "on (list + sign only)")
        s.profile = "simulator"; s.github = "push"
        XCTAssertEqual(row("fence")?.state, "guard rail (Simulator)")
        XCTAssertTrue(row("fence")?.sentence.contains("a guard rail, not a boundary") == true)
        XCTAssertEqual(row("github")?.state, "push")
        XCTAssertEqual(row("github")?.editable, "restart")
    }

    func testTheFactsSayGitHubSSHAndXcode() throws {
        let w = try FenceScratch()
        defer { w.remove() }
        var f = try w.fence()
        var t = MacAgentPrompt.facts(fence: f, agent: nil, workdir: f.workdir)
        XCTAssertTrue(t.contains("GitHub: no credential") && t.contains("without keys"))
        XCTAssertFalse(t.contains("DOZ_DERIVED"))
        f.github = .read; f.sshAgent = true; f.profile = "xcode"
        t = MacAgentPrompt.facts(fence: f, agent: nil, workdir: f.workdir)
        XCTAssertTrue(t.contains("read-only") && t.contains("SSH agent (list and sign only)") && t.contains("-derivedDataPath \"$DOZ_DERIVED\"")
                      && t.contains("Simulator and LaunchServices are closed"))
        f.profile = "simulator"
        XCTAssertTrue(MacAgentPrompt.facts(fence: f, agent: nil, workdir: f.workdir).contains("runs outside the fence"))
    }

    func testTheReadOnlyRefusalNamesTheFencesWay() {
        XCTAssertTrue(GitHubAccess.pushOff("@mac s1", "git push refused").contains("doz run @mac --github push"))
        XCTAssertTrue(GitHubAccess.pushOff("box", "git push refused").contains("doz net allow box github:push"))
    }
}

/// M4's doors: the agent relay filters, the gh door serves only GitHub's hosts.
final class MacFenceDoorTests: XCTestCase {
    func testTheAgentDoorFilters() throws {
        let root = "/private/tmp/dzdt-\(getpid())-\(UInt32.random(in: 0...UInt32.max))"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        // A fake agent: every request answered SSH_AGENT_SUCCESS (6).
        let fake = try MacFenceDoor(path: root + "/fake.sock") { c in
            var b = [UInt8](repeating: 0, count: 1024)
            while read(c, &b, b.count) > 0 { _ = Wire.writeAll(c, [0, 0, 0, 1, 6]) }
        }
        defer { fake.stop() }
        let door = try MacFenceDoor(path: root + "/s.agent") { c in MacFenceDoor.relayAgent(c, upstream: { root + "/fake.sock" }) }
        defer { door.stop() }
        var st = stat()
        XCTAssertEqual(lstat(root + "/s.agent", &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o600)
        let c = SSHAgentRelay.connectUnix(root + "/s.agent")
        XCTAssertGreaterThanOrEqual(c, 0)
        defer { close(c) }
        func ask(_ m: [UInt8]) -> [UInt8]? {
            guard Wire.writeAll(c, [0, 0, 0, UInt8(m.count)] + m) else { return nil }
            return Wire.readExact(c, 5)
        }
        XCTAssertEqual(ask([11]), [0, 0, 0, 1, 6], "list keys reaches the agent")
        XCTAssertEqual(ask([19]), [0, 0, 0, 1, 5], "remove all identities is refused here")
        XCTAssertEqual(ask([17, 0]), [0, 0, 0, 1, 5], "adding a key is refused here")
        door.stop()
        XCTAssertNotEqual(lstat(root + "/s.agent", &st), 0, "a stopped door takes its socket away")
        XCTAssertThrowsError(try { () throws -> Void in
            FileManager.default.createFile(atPath: root + "/f.agent", contents: Data())
            _ = try MacFenceDoor(path: root + "/f.agent") { _ in }
        }(), "a file that is not a socket is never replaced")
    }

    func testTheGitHubDoorServesOnlyGitHub() throws {
        let p = try EgressProxy(policy: .permissions(["github", "github:as-you"], preset: nil), ca: nil)
        var pair: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        let fds = pair
        defer { close(fds[1]) }
        let t = Thread { p.serveUnwrapped(fds[0], hosts: Set(GitHubAccess.credentialHosts)); close(fds[0]) }
        t.start()
        _ = Wire.writeAll(fds[1], Array("GET / HTTP/1.1\r\nHost: example.com\r\n\r\n".utf8))
        var got = [UInt8]()
        var b = [UInt8](repeating: 0, count: 4096)
        while true { let n = read(fds[1], &b, b.count); if n <= 0 { break }; got += b[0..<n] }
        let text = String(decoding: got, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 403") && text.contains("GitHub only"), text)
        XCTAssertTrue(p.log.records.contains { $0.host == "example.com" && $0.verdict == .denied })
    }
}
