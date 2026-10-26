import CryptoKit
import Foundation
import XCTest
@testable import DozableKit

/// 599h: the tools layer — the plan per settings, the guest's answer, the apply script, the results, the
/// pinned github.com host keys (checked against GitHub's published fingerprints), gh's checksum refusal (a
/// local file — never the network), the test seam's limits, and the image recipes unchanged.
final class ToolsLayerTests: XCTestCase {
    private func ids(_ p: ToolPlan) -> [String] { p.items.map(\.id) }

    func testThePlanFollowsTheSettings() throws {
        let none = ToolsLayer.plan(ToolInputs())
        XCTAssertEqual(ids(none), ["git", "curl", "ca-certificates"], "always the basics")
        XCTAssertEqual(none.removals, ["gh", "github-known-hosts"], "Dozable's own tools go when their setting is off")
        let all = ToolsLayer.plan(ToolInputs(github: true, ssh: true, tmux: true))
        XCTAssertEqual(ids(all), ["gh", "ssh", "github-known-hosts", "tmux", "git", "curl", "ca-certificates"])
        XCTAssertEqual(all.removals, [])
        let gh = all.items[0]
        XCTAssertEqual(gh.reason, "for GitHub as you")
        XCTAssertEqual(gh.kind, "binary")
        XCTAssertEqual(gh.version, ToolsLayer.ghVersion)
        XCTAssertEqual(all.items.first { $0.id == "ssh" }?.package, "openssh-client")
        XCTAssertEqual(all.items.first { $0.id == "ssh" }?.reason, "for SSH agent forwarding")
        let tmux = try XCTUnwrap(all.items.first { $0.id == "tmux" })
        XCTAssertEqual(tmux.reason, "for tmux sessions")
        XCTAssertEqual(tmux.kind, "binary", "Dozable's own tmux, copied in — never the distro's package")
        XCTAssertEqual(tmux.title, "tmux \(ToolsLayer.tmuxVersion)")
        XCTAssertNil(tmux.package)
        XCTAssertFalse(ToolsLayer.plan(ToolInputs()).removals.contains("tmux"), "kept when off: a running server may be it")
        XCTAssertEqual(ids(ToolsLayer.plan(ToolInputs(ssh: true))), ["ssh", "github-known-hosts", "git", "curl", "ca-certificates"])
        XCTAssertEqual(ToolsLayer.plan(ToolInputs(ssh: true)).removals, ["gh"])
    }

    func testTheGuestsAnswerAndWhatIsMissing() {
        let s = ToolsLayer.GuestState.parse("first=0\ngh=\(ToolsLayer.ghVersion)\nhave=git\nhave=ca-certificates\nhave=ssh\npm=apk\n")
        XCTAssertFalse(s.first)
        XCTAssertEqual(s.gh, ToolsLayer.ghVersion)
        XCTAssertEqual(s.packageManager, "apk")
        let plan = ToolsLayer.plan(ToolInputs(github: true, ssh: true, tmux: true))
        XCTAssertEqual(ToolsLayer.missingPackages(plan, s).map(\.id), ["curl"], "tmux is not a package any more")
        let fresh = ToolsLayer.GuestState.parse("first=1\npm=none\n")
        XCTAssertTrue(fresh.first)
        XCTAssertNil(fresh.gh)
        XCTAssertNil(fresh.tmux)
        // Dozable's tmux (its recorded version) is not the distro's (`have=tmux`).
        let t = ToolsLayer.GuestState.parse("first=0\nhave=tmux\ntmux=\(ToolsLayer.tmuxVersion)\npm=apt\n")
        XCTAssertEqual(t.tmux, ToolsLayer.tmuxVersion)
        XCTAssertTrue(t.have.contains("tmux"))
        XCTAssertNil(ToolsLayer.GuestState.parse("have=tmux\n").tmux)
        XCTAssertTrue(ToolsLayer.checkScript.contains("[ -x '\(ToolsLayer.guestTmuxPath)' ] && v=$(cat '\(ToolsLayer.guestStateDirectory)/tmux.version'"))
        // The check is a plain shell script that never fails.
        XCTAssertTrue(ToolsLayer.checkScript.hasSuffix("exit 0"))
    }

    func testTheApplyScript() {
        let plan = ToolsLayer.plan(ToolInputs(github: true, ssh: true))
        var s = ToolsLayer.GuestState.parse("first=1\nhave=git\nhave=curl\nhave=ca-certificates\npm=apt\n")
        var script = ToolsLayer.applyScript(plan, state: s, ghCopied: true, ghProblem: nil)
        XCTAssertTrue(script.contains("apt-get install -y --no-install-recommends -o Dpkg::Use-Pty=0 openssh-client"), "only what is missing")
        XCTAssertFalse(script.contains("install -y --no-install-recommends -o Dpkg::Use-Pty=0 git"))
        XCTAssertTrue(script.contains("mv -f '\(ToolsLayer.guestGhPath).tmp' '\(ToolsLayer.guestGhPath)'"), "gh from the copy")
        XCTAssertTrue(script.contains("ln -sf '\(ToolsLayer.guestGhPath)' '\(ToolsLayer.ghLink)'"), "linked where every PATH looks, when free")
        XCTAssertTrue(script.contains("doz-tool git ok"))
        XCTAssertTrue(script.contains(ToolsLayer.githubHostKeys[0]), "the pinned keys")
        XCTAssertTrue(script.hasSuffix("exit 0"), "never fails the caller")
        // gh not had: skipped with the reason; already there: ok.
        script = ToolsLayer.applyScript(plan, state: s, ghCopied: false, ghProblem: "refused the gh download: …")
        XCTAssertTrue(script.contains("doz-tool gh skipped refused the gh download: …"))
        s.gh = ToolsLayer.ghVersion
        s.have.insert("github-known-hosts")
        script = ToolsLayer.applyScript(plan, state: s, ghCopied: false, ghProblem: nil)
        XCTAssertTrue(script.contains("doz-tool gh ok") && script.contains("doz-tool github-known-hosts ok"))
        // Off: removed — only Dozable's copy and Dozable's link; the host keys block only when there.
        let off = ToolsLayer.plan(ToolInputs())
        script = ToolsLayer.applyScript(off, state: s, ghCopied: false, ghProblem: nil)
        XCTAssertTrue(script.contains("rm -f '\(ToolsLayer.guestGhPath)'") && script.contains("doz-tool gh removed"))
        XCTAssertTrue(script.contains("[ \"$(readlink '\(ToolsLayer.ghLink)' 2>/dev/null)\" = '\(ToolsLayer.guestGhPath)' ] && rm -f '\(ToolsLayer.ghLink)'"), "a gh the user put there stays")
        XCTAssertTrue(script.contains("doz-tool github-known-hosts removed"))
        s.have.remove("github-known-hosts")
        XCTAssertFalse(ToolsLayer.applyScript(off, state: s, ghCopied: false, ghProblem: nil).contains("github-known-hosts removed"))
        // No package manager: said, not attempted.
        let bare = ToolsLayer.GuestState.parse("first=1\npm=none\n")
        XCTAssertTrue(ToolsLayer.applyScript(off, state: bare, ghCopied: false, ghProblem: nil).contains("doz-tool git failed missing, and this base has neither apt-get nor apk"))
        // No single quote can break out of a quoted string (the details are guest text in single quotes).
        XCTAssertTrue(ToolsLayer.applyScript(plan, state: bare, ghCopied: false, ghProblem: "it's offline").contains("it’s offline"))
    }

    // MARK: tmux — Dozable's own

    func testTmuxIsCopiedInCheckedAndLinkedOnlyWhenFree() {
        let plan = ToolsLayer.plan(ToolInputs(tmux: true))
        var s = ToolsLayer.GuestState.parse("first=1\nhave=git\nhave=curl\nhave=ca-certificates\nhave=tmux\npm=apt\n")
        var script = ToolsLayer.applyScript(plan, state: s, ghCopied: false, ghProblem: nil, tmuxCopied: true)
        XCTAssertFalse(script.contains("apt-get"), "nothing to install: the distro's tmux is not asked for")
        XCTAssertTrue(script.contains("mv -f '\(ToolsLayer.guestTmuxPath).tmp' '\(ToolsLayer.guestTmuxPath)'"), "moved into place (a rename: a running server keeps its file)")
        XCTAssertTrue(script.contains("[ \"$('\(ToolsLayer.guestTmuxPath)' -V 2>/dev/null)\" = 'tmux \(ToolsLayer.tmuxVersion)' ]"), "it must run and be this version")
        XCTAssertTrue(script.contains("> '\(ToolsLayer.guestStateDirectory)/tmux.version'"))
        XCTAssertTrue(script.contains("doz-tool tmux installed tmux \(ToolsLayer.tmuxVersion), built into Dozable"))
        XCTAssertTrue(script.contains("doz-tool tmux failed the copied tmux does not run here"))
        XCTAssertTrue(script.contains("if [ ! -e '\(ToolsLayer.tmuxLink)' ] && [ ! -L '\(ToolsLayer.tmuxLink)' ] || [ \"$(readlink '\(ToolsLayer.tmuxLink)')\" = '\(ToolsLayer.guestTmuxPath)' ]; then ln -sf"),
                      "linked only where nothing else is, or already Dozable's")
        script = ToolsLayer.applyScript(plan, state: s, ghCopied: false, ghProblem: nil, tmuxProblem: "this build of Dozable has no tmux of its own")
        XCTAssertTrue(script.contains("doz-tool tmux skipped this build of Dozable has no tmux of its own"))
        s.tmux = ToolsLayer.tmuxVersion
        script = ToolsLayer.applyScript(plan, state: s, ghCopied: false, ghProblem: nil)
        XCTAssertTrue(script.contains("doz-tool tmux ok tmux \(ToolsLayer.tmuxVersion)"))
        XCTAssertFalse(script.contains("mv -f '\(ToolsLayer.guestTmuxPath).tmp'"))
        // Off: nothing about tmux (kept — see the plan).
        XCTAssertFalse(ToolsLayer.applyScript(ToolsLayer.plan(ToolInputs()), state: s, ghCopied: false, ghProblem: nil).contains("doz-tool tmux"))
        XCTAssertEqual(ToolsLayer.results("doz-tool tmux installed tmux 3.8, built into Dozable\n", plan: plan).first?.state, "installed")
    }

    /// The committed binary is the pinned one, recorded in its provenance; a file that is not refused.
    func testTheCommittedTmuxIsThePin() throws {
        let pkg = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let bin = try Data(contentsOf: pkg.appendingPathComponent("Sources/DozableKit/Resources/tmux"))
        XCTAssertEqual(ToolsCache.sha256(bin), ToolsLayer.tmuxSHA256, "Resources/tmux is the pinned build (make tmux; update the pin)")
        XCTAssertEqual(Array(bin.prefix(4)), [0x7F, 0x45, 0x4C, 0x46], "an ELF")
        XCTAssertEqual(bin[18], 0xB7, "aarch64")
        let prov = try String(contentsOf: pkg.appendingPathComponent("Guest/tmux/PROVENANCE.md"), encoding: .utf8)
        XCTAssertTrue(prov.contains("| sha256 (auto) | `\(ToolsLayer.tmuxSHA256)` |"))
        let build = try String(contentsOf: pkg.appendingPathComponent("Guest/tmux/build.sh"), encoding: .utf8)
        XCTAssertTrue(build.contains("TMUX_VERSION=\"\(ToolsLayer.tmuxVersion)\""), "the build and the pin name the same version")
        if case .success = TmuxBinary.check(URL(fileURLWithPath: "/x"), sum: String(repeating: "0", count: 64)) { XCTFail("another file was accepted") }
        if case .success = TmuxBinary.check(URL(fileURLWithPath: "/x"), sum: nil) { XCTFail("an unreadable file was accepted") }
        XCTAssertEqual(try? TmuxBinary.check(URL(fileURLWithPath: "/x"), sum: ToolsLayer.tmuxSHA256).get(), URL(fileURLWithPath: "/x"))
        // The bundle's copy (the test runner finds the resource bundle beside it) passes the check.
        if TmuxBinary.locate(environment: [:]) != nil {
            XCTAssertNotNil(try? TmuxBinary.verified(environment: [:]).get(), "the bundled tmux is the pin")
        }
    }

    func testTheResults() {
        let plan = ToolsLayer.plan(ToolInputs(github: true))
        let out = "doz-tool gh installed gh \(ToolsLayer.ghVersion), from Dozable's cache on the Mac\ndoz-tool git ok already in the image\ndoz-tool curl failed apk could not install curl\nnoise\n"
        let rs = ToolsLayer.results(out, plan: plan)
        XCTAssertEqual(rs.map(\.id), ["gh", "git", "curl", "ca-certificates"])
        XCTAssertEqual(rs.map(\.state), ["installed", "ok", "failed", "failed"])
        XCTAssertEqual(rs[3].detail, "no answer from the guest")
        let rep = ToolsReport(results: rs, first: true)
        XCTAssertTrue(rep.changed && rep.failed)
        XCTAssertTrue(rep.summary.contains("gh \(ToolsLayer.ghVersion) ✓") && rep.summary.contains("curl ✗ (apk could not install curl)"))
        XCTAssertEqual(ToolsLayer.label(rs[0]), "tools: gh \(ToolsLayer.ghVersion) — for GitHub as you")
        let removed = ToolsLayer.results("doz-tool gh removed GitHub as you is off\n", plan: ToolsLayer.plan(ToolInputs()))
        XCTAssertEqual(removed.last?.id, "gh")
        XCTAssertEqual(removed.last?.state, "removed")
    }

    // MARK: the pinned github.com host keys

    /// GitHub's published SSH key fingerprints (docs.github.com: "GitHub's SSH key fingerprints").
    static let publishedFingerprints = [
        "ssh-ed25519": "SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU",
        "ecdsa-sha2-nistp256": "SHA256:p2QAMXNIC1TJYWeIOttrVc98/R1BUFWu3/LiyKgUfQM",
        "ssh-rsa": "SHA256:uNiVztksCsDhcc0u9e8BujQXVUpKZIDTMczCvj3tD2s",
    ]

    func testTheHostKeysAreGitHubsPublishedOnes() throws {
        XCTAssertEqual(ToolsLayer.githubHostKeys.count, 3)
        for line in ToolsLayer.githubHostKeys {
            let parts = line.split(separator: " ").map(String.init)
            XCTAssertEqual(parts.count, 3)
            XCTAssertEqual(parts[0], "github.com")
            let blob = try XCTUnwrap(Data(base64Encoded: parts[2]))
            let fp = "SHA256:" + Data(SHA256.hash(data: blob)).base64EncodedString().replacingOccurrences(of: "=", with: "")
            XCTAssertEqual(fp, Self.publishedFingerprints[parts[1]], "\(parts[1])")
        }
        XCTAssertFalse(ToolsLayer.knownHostsBegin.contains("'"), "the marker sits in single-quoted shell")
    }

    // MARK: gh's download

    func testABadChecksumIsRefusedAndNothingIsKept() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/dztl-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bad = root.appendingPathComponent("served.tar.gz")
        try Data("not gh".utf8).write(to: bad)
        let cache = ToolsCache(root: root.appendingPathComponent("tools"))
        let r = await ToolsCache.fetchGh(from: bad, root: cache.root, dir: cache.ghDirectory, binary: cache.ghBinary, stamp: cache.ghStamp)
        guard case .failure(let f) = r else { return XCTFail("a tampered download was accepted") }
        XCTAssertTrue(f.reason.hasPrefix("refused the gh download: its sha256 is"), f.reason)
        XCTAssertNil(cache.cachedGh())
        XCTAssertTrue(cache.entries().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.ghBinary.path))
        // An unreachable server: a plain reason (an offline Mac).
        let off = await ToolsCache.fetchGh(from: URL(string: "http://127.0.0.1:9/" + ToolsLayer.ghTarball)!, root: cache.root, dir: cache.ghDirectory,
                                           binary: cache.ghBinary, stamp: cache.ghStamp)
        guard case .failure(let o) = off else { return XCTFail("no server, yet a download") }
        XCTAssertTrue(o.reason.contains("could not download gh"), o.reason)
    }

    func testTheRealTarballIsAcceptedWhenTheFixtureIsHere() async throws {
        let fixture = NSTemporaryDirectory() + "doz-vmtest-store/fixtures/" + ToolsLayer.ghTarball
        guard FileManager.default.fileExists(atPath: fixture) else { throw XCTSkip("no fixture (make tools-fixture)") }
        let root = URL(fileURLWithPath: "/private/tmp/dztl-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = ToolsCache(root: root.appendingPathComponent("tools"))
        let r = await ToolsCache.fetchGh(from: URL(fileURLWithPath: fixture), root: cache.root, dir: cache.ghDirectory, binary: cache.ghBinary, stamp: cache.ghStamp)
        guard case .success(let gh) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(cache.cachedGh(), gh)
        XCTAssertEqual(cache.entries().first?.version, ToolsLayer.ghVersion)
    }

    func testTheSeamIsLocalOnly() {
        XCTAssertEqual(try? ToolsCache.ghSource(environment: [:]).get(),
                       URL(string: "https://github.com/cli/cli/releases/download/v\(ToolsLayer.ghVersion)/\(ToolsLayer.ghTarball)"))
        XCTAssertEqual(try? ToolsCache.ghSource(environment: ["DOZ_TEST_TOOLS_URL": "http://127.0.0.1:8080"]).get(),
                       URL(string: "http://127.0.0.1:8080/\(ToolsLayer.ghTarball)"))
        if case .success = ToolsCache.ghSource(environment: ["DOZ_TEST_TOOLS_URL": "http://example.com"]) { XCTFail("the seam is 127.0.0.1 only") }
    }

    // MARK: no recipe changes

    /// The bake keys of catalogue images, as they were at v0.14.0-rc.1: the tools layer changes no recipe
    /// (no "older recipe" on an existing image, no rebuild).
    func testTheImageRecipesAreUnchanged() throws {
        func key(_ base: String, _ agent: AgentKind) throws -> String {
            let b = try XCTUnwrap(BaseCatalogue.base(base))
            return try ImageComposer.spec(name: ImageChoice(base: base, agent: agent).name, base: b.source(), agent: agent,
                                          release: agent == .none ? nil : AgentImages.claudeCodePinned, native: nil)
                .bakeKey(kernelSHA256: "k", deckholdSHA256: "d")
        }
        XCTAssertEqual(try key("debian", .none), "b7c98e178b877b42c79e8f5fed4888a1f88b2b8ee334974ad751a26a9f54a34c")
        XCTAssertEqual(try key("alpine", .none), "371cb65ba518154ba82dc0b86a36b4bcba1c464a566baef130161d99fd017d35")
        XCTAssertEqual(try key("ubuntu", .none), "ac11aef87be7d4cc8d6c0068fd229c3b379a16b7a2b4b4cc0aad514bce5bde6a")
        XCTAssertEqual(AgentImages.claudeCode.bakeKey(kernelSHA256: "k", deckholdSHA256: "d"), "7c9b0e39f68860c5e9bbf3677790e43d75a40314c3e1199a62f44f055f201ae2")
    }
}
