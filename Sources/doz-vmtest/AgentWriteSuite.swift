// `doz-vmtest agent-write` (`make test-vm-agentwrite`; also run by `make test-vm-cwd` and `make test-vm-ignore`) —
// the image's session user (the agent, uid 1001) writes a shared workspace through the view.
//
// The bug it pins (0.30.0–0.33.0): Apple's virtio-fs server reports the Mac user's files as owned by WHICHEVER
// guest uid asks. The view's daemon (dozview, root) asked as root, saw 0:0 for everything and passed it on;
// the view is mounted with default_permissions, so the guest kernel refused every write by the agent on a
// 755/644 folder — a folder Dozable made, a project under ~, anything — and git refused the repository
// ("dubious ownership"). Root could write, so every earlier suite (which wrote as root) passed. dozview ≥ 1.2.0
// reports the conf's `owner=` (the image user's uid/gid, resolved in the guest) for what it sees as its own.
//
//   ONE sandbox of a small image (Alpine + bash + git + the `agent` user, uid 1001 — baked once per store),
//   four shares, all through the view: /workspace (a folder Dozable made: Workspace.prepare), /w/pre (made by
//   the Mac user, 755/644), /w/priv (700/600, nested), /w/rules (.dozignore + .dozreadonly — the rules view).
//   As the agent, in each: ownership shown as the agent, create, append, mkdir, a file in a subfolder,
//   git init + git status — and on the Mac the files exist, owned by the Mac user. In the rules view, as the
//   agent: the locked file, a .dozreadonly path, the rule files and doz_project.yaml are still refused.
//   Another guest user (nobody) does not write through the view (documented). The same after sleep→wake
//   and after hibernate→wake.
import Foundation
import DozableKit
import DozableHost

/// Alpine (the lab's pinned base) + bash + git + the agent user — the cheapest image whose session user is
/// not root.
let agentWriteImage = ImageSpec(
    name: "vmtest-agentw",
    base: "docker.io/library/alpine@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc",
    steps: [
        BakeStep("packages", argv: ["sh", "-eu", "-c", "apk add --no-cache bash git"]),
        BakeStep("the agent user", argv: ["sh", "-eu", "-c",
                                           "id agent >/dev/null 2>&1 || adduser -D -s /bin/bash -u 1001 agent; mkdir -p /workspace && chown agent:agent /workspace"],
                 needsNetwork: false),
    ],
    verify: [VerifyCheck(["sh", "-c", "echo uid=$(id -u); git --version"], expect: "uid=1001")],
    user: "agent", home: "/home/agent", persistDirs: [], rootfsMiB: 1024)

func agentWriteSuite() async throws {
    let fm = FileManager.default
    let root = storeRoot.appendingPathComponent("agentw")
    try? fm.removeItem(at: root)
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    func write(_ p: URL, _ s: String, mode: Int16) throws {
        try fm.createDirectory(at: p.deletingLastPathComponent(), withIntermediateDirectories: true)
        try s.write(to: p, atomically: false, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: p.path)
    }
    // 1. a folder Dozable makes (the default for a new sandbox) — under /tmp: the store's $TMPDIR is under
    // /private/var, where Dozable refuses to make one.
    let madeRoot = URL(fileURLWithPath: "/tmp/doz-agentw-\(getpid())")
    try? fm.removeItem(at: madeRoot)
    defer { try? fm.removeItem(at: madeRoot) }
    let made = try Workspace.prepare(madeRoot.appendingPathComponent("made/ws").path, store: nil)
    check(made.created, "Workspace.prepare made \(made.path)")
    let madeURL = URL(fileURLWithPath: made.path)
    try write(madeURL.appendingPathComponent("README.md"), "made\n", mode: 0o644)
    try write(madeURL.appendingPathComponent("src/main.js"), "x\n", mode: 0o644)
    // 2. a folder the Mac user made, 755/644.
    let pre = root.appendingPathComponent("pre")
    try write(pre.appendingPathComponent("README.md"), "pre\n", mode: 0o644)
    try write(pre.appendingPathComponent("src/main.js"), "x\n", mode: 0o644)
    // 3. private: 700/600, nested.
    let priv = root.appendingPathComponent("priv")
    try write(priv.appendingPathComponent("README.md"), "priv\n", mode: 0o600)
    try write(priv.appendingPathComponent("src/main.js"), "x\n", mode: 0o600)
    try write(priv.appendingPathComponent("nested/deep/secret.txt"), "s\n", mode: 0o600)
    for d in [priv, priv.appendingPathComponent("src"), priv.appendingPathComponent("nested"), priv.appendingPathComponent("nested/deep")] {
        try fm.setAttributes([.posixPermissions: Int16(0o700)], ofItemAtPath: d.path)
    }
    // 4. the rules view.
    let rules = root.appendingPathComponent("rules")
    try write(rules.appendingPathComponent("README.md"), "rules\n", mode: 0o644)
    try write(rules.appendingPathComponent("src/main.js"), "x\n", mode: 0o644)
    try write(rules.appendingPathComponent("secret.env"), "SECRET=1\n", mode: 0o644)
    try write(rules.appendingPathComponent("locked-ro.txt"), "ro\n", mode: 0o644)
    try write(rules.appendingPathComponent("doz_project.yaml"), "version: 1\n", mode: 0o644)
    try write(rules.appendingPathComponent(".dozignore"), "secret.env\n", mode: 0o644)
    try write(rules.appendingPathComponent(".dozreadonly"), "locked-ro.txt\n", mode: 0o644)

    let shares = [(made.path, "/workspace"), (pre.path, "/w/pre"), (priv.path, "/w/priv"), (rules.path, "/w/rules")]
    let spec = SandboxSpec(name: "vmtest-agentw", storeRoot: storeRoot, kernelPath: kernelPath, kernelCacheDirectory: kernelCache,
                           cpus: 2, memoryMiB: 1024, shares: shares.map { Share(hostPath: $0.0, guestPath: $0.1) },
                           subnet: ProcessInfo.processInfo.environment["DOZ_SUBNET"] ?? "192.168.207.0/24", imageSpec: agentWriteImage)
    let sb = try Sandbox(spec: spec)
    let log = logEvents(sb, prefix: "[agentw] ")
    defer { log.cancel() }
    if await sb.phase != .off { try? await sb.shutDown() }
    try? await sb.delete()

    print("agent-write: bake (or cache hit) + boot")
    _ = try await bakeImage(sb, agentWriteImage)
    try await sb.start()
    let views = sb.activeViews
    check(views.count == 4 && views.values.filter(\.isPassthrough).count == 3 && views.values.allSatisfy { $0.owner == "agent" },
          "all four shares are served through a view (3 passthrough + 1 with rules), owner agent (\(views.values.map { "\($0.guestPath):\($0.owner ?? "-")" }.sorted()))")
    let report = await sb.workspaceViewReport()
    check(report.count == 4 && report.allSatisfy { $0.state["owner"] == "1001:1001" && $0.state["version"] == "1.2.0" },
          "every view's daemon is 1.2.0 and reports owner 1001:1001 (\(report.map { "\($0.state["version"] ?? "?") \($0.state["owner"] ?? "?")" }))")

    let writable = """
        P=$1; T=$2
        echo "owner=$(stat -c %u:%g "$P") readme=$(stat -c %u "$P/README.md")"
        touch "$P/new-$T" && echo ok-create
        echo a >> "$P/README.md" && echo ok-append
        mkdir "$P/dir-$T" && echo ok-mkdir
        echo s > "$P/src/sub-$T.txt" && echo ok-subfolder
        git init -q "$P/repo-$T" && git -C "$P/repo-$T" status --porcelain >/dev/null && echo ok-git
        """
    let refused = """
        P=$1
        cat "$P/secret.env" >/dev/null 2>&1 || echo refused-locked-read
        { echo x >> "$P/secret.env"; } 2>/dev/null || echo refused-locked-write
        chmod 644 "$P/secret.env" 2>/dev/null || echo refused-locked-chmod
        { echo x >> "$P/locked-ro.txt"; } 2>/dev/null || echo refused-readonly-write
        rm -f "$P/locked-ro.txt" 2>/dev/null; [ -e "$P/locked-ro.txt" ] && echo refused-readonly-rm
        { echo x >> "$P/.dozignore"; } 2>/dev/null || echo refused-dozignore-write
        rm -f "$P/.dozreadonly" 2>/dev/null; [ -e "$P/.dozreadonly" ] && echo refused-dozreadonly-rm
        { echo 'version: 9' > "$P/doz_project.yaml"; } 2>/dev/null || echo refused-project-file
        """
    let refusals = ["refused-locked-read", "refused-locked-write", "refused-locked-chmod", "refused-readonly-write", "refused-readonly-rm",
                    "refused-dozignore-write", "refused-dozreadonly-rm", "refused-project-file"]

    func round(_ label: String) async throws {
        let t = label.filter { $0.isLetter || $0.isNumber }
        for (host, guest) in shares {
            let r = try await sb.exec(["sh", "-c", writable, "sh", guest, t], user: "agent", timeoutSeconds: 30)
            let o = r.output + r.errorOutput
            let ok = ["ok-create", "ok-append", "ok-mkdir", "ok-subfolder", "ok-git"].allSatisfy(o.contains)
            check(ok && o.contains("owner=1001:1001") && o.contains("readme=1001"),
                  "\(label): the agent owns \(guest) and creates, appends, mkdirs, writes a subfolder, git init + status (\(o.split(separator: "\n").joined(separator: " · ")))")
            let h = URL(fileURLWithPath: host)
            let attrs = try? fm.attributesOfItem(atPath: h.appendingPathComponent("src/sub-\(t).txt").path)
            check((attrs?[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(), "\(label): on the Mac \(guest)'s new file exists, owned by the Mac user")
        }
        let deep = try await sb.exec(["sh", "-c", "cat /w/priv/nested/deep/secret.txt && echo b >> /w/priv/nested/deep/secret.txt && echo ok-deep"],
                                     user: "agent", timeoutSeconds: 20)
        check(deep.output.contains("ok-deep"), "\(label): the agent reads and appends a 600 file two levels down a 700 tree (\((deep.output + deep.errorOutput).trimmingCharacters(in: .whitespacesAndNewlines)))")
        let rr = try await sb.exec(["sh", "-c", refused, "sh", "/w/rules"], user: "agent", timeoutSeconds: 30)
        let missing = refusals.filter { !rr.output.contains($0) }
        check(missing.isEmpty, "\(label): as the agent the locked file, a .dozreadonly path, the rule files and doz_project.yaml are still refused\(missing.isEmpty ? "" : " — NOT refused: \(missing)")")
        let rootRefused = try await sb.exec(["sh", "-c", refused, "sh", "/w/rules"], privileged: true, timeoutSeconds: 30)
        let rootMissing = refusals.filter { !rootRefused.output.contains($0) }
        check(rootMissing.isEmpty, "\(label): and as root\(rootMissing.isEmpty ? "" : " — NOT refused: \(rootMissing)")")
        let other = try await sb.exec(["sh", "-c", "touch /w/pre/nobody-\(t) 2>/dev/null && echo wrote || echo refused"], user: "nobody", timeoutSeconds: 20)
        check(other.output.contains("refused"), "\(label): another guest user (nobody) does not write through the view (documented)")
    }

    try await round("boot")
    try await sb.sleep(); try await sb.wake()
    try await round("after sleep→wake")
    try await sb.hibernate(); try await sb.wake()
    try await round("after hibernate→wake")

    try await sb.shutDown()
    try? await sb.delete()
    try? fm.removeItem(at: root)
}
