import Darwin
import Foundation
import DozableKit
import DozableHost

// `make test-cli-workspace`, the wide views' rows (after the lifecycle's, in the same scratch store): the real doz, its daemon
// and the real deckhold-mac — no VM, the memory keychain, a scratch fence home. `views`: a fenced session on this Mac running
// a harmless program with a launch secret whose value is a SENTINEL (from a 0600 file), adopted while it runs.
//
//  V1. show --network --json: the secret by name, its destination and fingerprint; never its value
//  V2. the leak sweep: the sentinel nowhere in any answer (text or --json), the store's files, daemon.log or ps
//  V3. show --folders: a file touched after the start listed (A), one from before not, a link's target neither listed nor followed
//  V4. log --limit 1, then --before its first: the page before; --json carries first and more
//  V5. the daemon stopped: show --can-do (its permissions and ceiling rows) and --network answer (refusals "not known"), and
//      no daemon starts
func cliWorkspaceViewRows(_ h: CLIHarness, root: URL, store: DozableStore, started: inout Set<String>) {
    print("cli: a workspace's wide views — what it can reach and hold, its folders, its log in pages")
    let fm = FileManager.default
    let pid = getpid()
    let home = URL(fileURLWithPath: "/private/tmp/dzo-\(pid)-wsv-home")
    let work = URL(fileURLWithPath: "/private/tmp/dzo-\(pid)-wsv-work")
    let outside = URL(fileURLWithPath: "/private/tmp/dzo-\(pid)-wsv-outside")
    let src = URL(fileURLWithPath: "/private/tmp/dzo-\(pid)-wsv-src")
    for d in [home, work, outside, src] { try? fm.removeItem(at: d); try? fm.createDirectory(at: d, withIntermediateDirectories: true) }
    chmod(src.path, 0o700)
    defer { for d in [home, work, outside, src] { try? fm.removeItem(at: d) } }
    func stopDaemon() {
        h.run(["daemon", "stop"], timeout: 60)
        _ = h.waitFor(20) { !h.hostRunning }
    }
    func psText() -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axww", "-o", "command="]
        let o = Pipe()
        p.standardOutput = o
        try? p.run()
        let d = o.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: d, as: UTF8.self)
    }
    func holders(_ needle: String, under dir: String) -> [String] {
        guard let e = fm.enumerator(atPath: dir) else { return [] }
        var out: [String] = []
        while let rel = e.nextObject() as? String {
            let p = dir + "/" + rel
            var st = stat()
            guard lstat(p, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_size < 32 << 20 else { continue }
            if let d = fm.contents(atPath: p), d.range(of: Data(needle.utf8)) != nil { out.append(p) }
        }
        return out
    }
    // An obviously fake value, unique to this run: anywhere it shows up, a secret leaked.
    let sentinel = "FAKE-VIEWS-SENTINEL-\(pid)-7f3a9c"
    fm.createFile(atPath: src.path + "/token", contents: Data((sentinel + "\n").utf8), attributes: [.posixPermissions: 0o600])
    // A file from before the start, and the link out (its target is new).
    fm.createFile(atPath: work.path + "/before.txt", contents: Data("old\n".utf8))
    try? fm.setAttributes([.modificationDate: Date().addingTimeInterval(-7200)], ofItemAtPath: work.path + "/before.txt")
    fm.createFile(atPath: outside.path + "/outside-new.txt", contents: Data("x\n".utf8))
    try? fm.createSymbolicLink(atPath: work.path + "/out", withDestinationPath: outside.path)

    stopDaemon()
    h.env["DOZ_TEST_FENCE_HOME"] = home.path
    h.env["DOZ_TEST_MAC_PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
    var r = h.run(["run", "@mac", "-d", "--fenced", "--session", "vsec", "--folder", work.path, "--permissions", "standard,site:api.views.test",
                   "--secret", "VIEWS_TOKEN,src=\(src.path)/token,to=api.views.test:443", "--", "/bin/sh", "-c", "exec sleep 600"], timeout: 90)
    if r.code == 0 { started.insert("vsec") }
    check(r.code == 0, "V fenced vsec with a launch secret (\(r.code) \(r.err.suffix(240)))")
    let brief = root.appendingPathComponent("views-brief.md").path
    try? "Look at what it reaches.\n".write(toFile: brief, atomically: true, encoding: .utf8)
    r = h.run(["workspace", "new", "views", "--prompt-file", brief, "--folder", work.path, "--no-room", "--adopt", "@mac/vsec"], timeout: 60)
    check(r.code == 0, "V new views --adopt @mac/vsec (\(r.code) \(r.err.prefix(200)))")
    // After the start (the adoption of a running agent): a new file.
    Thread.sleep(forTimeInterval: 1.1)
    fm.createFile(atPath: work.path + "/after.txt", contents: Data("new\n".utf8))

    // V1. the network: the secret by name, its destination and fingerprint.
    var answers = ""
    r = h.run(["workspace", "show", "views", "--network", "--json"], timeout: 60)
    answers += r.out + r.err
    struct Show: Decodable { let reach: WorkspaceReach? }
    let reach = (try? HostWire.decoder.decode(Show.self, from: Data(r.out.utf8)))?.reach
    let held = reach?.agents.first { $0.name == "vsec" }?.held.first { $0.name == "VIEWS_TOKEN" }
    check(r.code == 0 && held?.to == "api.views.test:443" && held?.fingerprint == CredentialFingerprint.of(sentinel) && held?.kind == "given",
          "V1 show --network --json: VIEWS_TOKEN → api.views.test:443, its fingerprint, kind given (\(r.code) \(String(describing: held)))")
    r = h.run(["workspace", "show", "views", "--network"], timeout: 60)
    answers += r.out + r.err
    check(r.code == 0 && r.out.contains("VIEWS_TOKEN") && r.out.contains("Nothing here shows a secret"), "V1 …and its text says it by name (\(r.out.suffix(200)))")
    for args in [["--can-do"], ["--can-do", "--json"], ["--folders", "--json"]] {
        r = h.run(["workspace", "show", "views"] + args, timeout: 60)
        answers += r.out + r.err
    }
    // V2. the leak sweep.
    let logs = ["daemon.log", "ui.log"].map { (try? String(contentsOf: root.appendingPathComponent($0), encoding: .utf8)) ?? "" }.joined()
    check(!answers.contains(sentinel) && !logs.contains(sentinel) && !psText().contains(sentinel) && holders(sentinel, under: root.path).isEmpty
          && holders(sentinel, under: home.path).isEmpty,
          "V2 the leak sweep: the sentinel in no answer, log, file of the store or the fence home, nor ps")

    // V3. the folders: after.txt listed, before.txt not, nothing through the link.
    let folders = h.json(["workspace", "show", "views", "--folders"], Show2.self)?.folders
    let main = folders?.folders.first { $0.path == WorkspaceStore.resolved(work.path) }
    let paths = main?.changes.map(\.path) ?? []
    check(paths.contains("after.txt") && main?.changes.first { $0.path == "after.txt" }?.kind == "A", "V3 show --folders: after.txt changed since the start, A (\(paths))")
    check(!paths.contains("before.txt") && !paths.contains { $0.hasPrefix("out") }, "V3 …before.txt not, and nothing through the link out (\(paths))")
    r = h.run(["workspace", "show", "views", "--folders"], timeout: 60)
    check(r.code == 0 && r.out.contains("A after.txt") && r.out.contains("never which agent"), "V3 …its text says so (\(r.out.prefix(240)))")

    // V4. the log in pages.
    struct Page: Decodable { let entries: [WorkspaceLogEntry]; let first: Int?; let more: Bool }
    let p1 = h.json(["workspace", "log", "views", "--limit", "1"], Page.self)
    let p2 = p1?.first.flatMap { h.json(["workspace", "log", "views", "--limit", "1", "--before", String($0)], Page.self) }
    let all = h.json(["workspace", "log", "views"], [WorkspaceLogEntry].self) ?? []
    check(p1?.entries.count == 1 && p1?.more == true && p1?.entries.first == all.last, "V4 log --limit 1: the newest line, more (\(p1?.entries.first?.action ?? "?"))")
    check(p2?.entries.count == 1 && all.count >= 2 && p2?.entries.first == all[all.count - 2], "V4 …--before its first: the line before (\(p2?.entries.first?.action ?? "?"))")
    r = h.run(["workspace", "log", "views", "--limit", "1", "--json"], timeout: 30)
    check(r.out.contains("\"first\"") && r.out.contains("\"more\""), "V4 …--json carries first and more")
    check(h.run(["workspace", "log", "views", "--limit", "501"], timeout: 30).code != 0, "V4 …--limit 501 refused")

    // V5. no daemon: the views answer from the store, and none starts.
    stopDaemon()
    r = h.run(["workspace", "show", "views", "--can-do"], timeout: 60)
    check(r.code == 0 && r.out.contains("Control") && r.out.contains("Permissions (allow · ask · never)  allow ") && r.out.contains("not enforced yet")
          && !r.out.contains("— later"), "V5 show --can-do with the daemon stopped: its permissions and ceiling rows (\(r.code) \(r.out.prefix(200)))")
    r = h.run(["workspace", "show", "views", "--network"], timeout: 60)
    check(r.code == 0 && r.out.contains("not known: no daemon is running"), "V5 show --network: refusals not known (\(r.out.prefix(300)))")
    check(h.run(["workspace", "show", "views", "--folders"], timeout: 60).code == 0, "V5 show --folders answers")
    check(!h.hostRunning, "V5 …and no daemon started")
}

private struct Show2: Decodable { let folders: WorkspaceFolders? }
