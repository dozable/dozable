// `make test-cli-host`: an UNFENCED session's conversations exported (`doz sessions @mac --transcripts S --export DIR`),
// with the suite's FAKE claude (never the real one) and its scratch Claude folders (DOZ_TEST_CLAUDE_PROJECTS).
//
//  T1. a claude session's conversation is learned; a `/clear` (the fake's record names another conversation) and its end
//      record both: claudeSessionIDs has two ids
//  T2. the export copies exactly the recorded conversations: the first, swept, with a manifest (both shas); the second, a
//      symlinked <id>.jsonl, is refused and named; the folder's other session's file is never copied
//  T3. with no daemon the listing and the export run in-process, and nothing starts one
import Darwin
import Foundation
import DozableChat
import DozableHost

func cliHostTranscriptRows(t: CLIHarness, root: URL, projects: URL, claudeSessions: URL, work: URL, started: (String) -> Void) {
    let fm = FileManager.default
    func records() -> MacSessionRecords? {
        (try? Data(contentsOf: root.appendingPathComponent("mac-sessions/sessions.json"))).flatMap { try? HostWire.decoder.decode(MacSessionRecords.self, from: $0) }
    }
    let dir = work.appendingPathComponent("tx")
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let real = MacFencePaths.resolve(dir.path) ?? dir.path
    var r = t.run(["run", "@mac", "-d", "--unfenced", "--session", "tx", "--folder", dir.path, "--", "claude"], timeout: 60)
    if r.code == 0 { started("tx") }
    // T1. the first conversation learned (10 s after the open), then a "/clear": the fake's record names another one.
    let learned = t.waitFor(25) { records()?.sessions["tx"]?.claudeSessionID != nil }
    let v1 = records()?.sessions["tx"]?.claudeSessionID ?? ""
    let pid = records()?.sessions["tx"]?.pid ?? (t.json(["sessions", "@mac"], [SessionRow].self) ?? []).first { $0.name == "tx" }?.pid ?? 0
    check(r.code == 0 && learned && !v1.isEmpty, "T1 a claude session's conversation is learned (\(v1))")
    let v2 = UUID().uuidString.lowercased()
    let pidFile = claudeSessions.path + "/\(pid).json"
    try? Data(#"{"pid":\#(pid),"sessionId":"\#(v2)","cwd":"\#(real)"}"#.utf8).write(to: URL(fileURLWithPath: pidFile))
    r = t.run(["sessions", "end", "@mac", "tx", "--yes"], timeout: 60)             // the end reads its conversation once more
    let ids = records()?.sessions["tx"]?.claudeSessionIDs ?? []
    check(ids == [v1, v2], "T1 /clear then the end: two conversations recorded (\(ids.count))")

    // T2. the files: v1 a real conversation with a planted token, v2 a link, and another session's file in the same folder.
    let folder = projects.path + "/" + MacPlace.claudeProjectFolderName(real)
    try? fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
    let token = "dzc_" + String(repeating: "Q", count: 43)
    // A chat participant's token, known to the store as its hash only (no chat server is needed for the sweep).
    let chat = ChatPaths(store: DozableStore(root: root))
    try? fm.createDirectory(atPath: chat.folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let added = fm.createFile(atPath: chat.tokens, contents: ChatTokenHashes(sha256: ["botx": ChatSecrets.hash(token)]).bytes(),
                              attributes: [.posixPermissions: 0o600])
    try? Data((#"{"type":"user","cwd":"\#(real)","message":"hello"}"# + "\n" + #"{"type":"assistant","cwd":"\#(real)","text":"\#(token)"}"# + "\n").utf8)
        .write(to: URL(fileURLWithPath: folder + "/\(v1).jsonl"))
    let elsewhere = root.appendingPathComponent("elsewhere.jsonl").path
    try? Data(#"{"cwd":"\#(real)","secret":"not yours"}"#.utf8).write(to: URL(fileURLWithPath: elsewhere))
    try? fm.createSymbolicLink(atPath: folder + "/\(v2).jsonl", withDestinationPath: elsewhere)
    let sibling = UUID().uuidString.lowercased()
    try? Data(#"{"cwd":"\#(real)","other":"session"}"#.utf8).write(to: URL(fileURLWithPath: folder + "/\(sibling).jsonl"))
    check(t.run(["daemon", "stop"], timeout: 60).code == 0 && t.waitFor(10) { !t.hostRunning }, "T2 the daemon stopped")

    // T3 (and T2): with no daemon, in-process.
    r = t.run(["sessions", "@mac", "--transcripts", "tx"], timeout: 30)
    check(r.code == 0 && r.out.contains(v1) && r.out.contains(v2) && !r.out.contains(sibling), "T3 no daemon: the listing names exactly the recorded conversations")
    let out = root.path + "-tx-export"
    try? fm.removeItem(atPath: out)
    defer { try? fm.removeItem(atPath: out) }
    r = t.run(["sessions", "@mac", "--transcripts", "tx", "--export", out, "--json"], timeout: 30)
    let names = ((try? fm.contentsOfDirectory(atPath: out)) ?? []).sorted()
    check(r.code == 0 && names == ["\(v1).jsonl", "manifest.json"], "T2 the export holds the recorded conversation and the manifest only (\(names))")
    let manifest = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: out + "/manifest.json")))) as? [String: Any]
    let skipped = (manifest?["skipped"] as? [[String: Any]]) ?? []
    check(skipped.contains { ($0["name"] as? String) == "\(v2).jsonl" && (($0["why"] as? String) ?? "").contains("link") },
          "T2 the symlinked conversation is refused and named")
    let files = (manifest?["files"] as? [[String: Any]]) ?? []
    check(files.count == 1 && files[0]["sourceSHA256"] as? String != files[0]["sha256"] as? String, "T2 the manifest keeps both shas (the sweep changed the copy)")
    let copied = (try? String(contentsOfFile: out + "/\(v1).jsonl", encoding: .utf8)) ?? ""
    check(!added || (!copied.contains(token) && copied.contains("[a chat token of botx, removed by doz]") && !r.out.contains(token)),
          "T2 the planted chat token is removed from the copy and named, never printed")
    check(!copied.contains("not yours") && !copied.contains("\"other\""), "T2 nothing of the link's target or the other session is copied")
    check(!t.hostRunning, "T3 …and no daemon was started")
    try? fm.removeItem(atPath: chat.folder)
    try? fm.removeItem(atPath: elsewhere)
}

/// `make test-cli-host` F1–F4: forgetting ended and gone sessions on this Mac (`doz sessions @mac --forget-ended`), no VM.
///
///  F1. --dry-run with no daemon: an ended, a gone and (from T1) another ended one would go, never the running one — and no
///      daemon is started
///  F2. no terminal and no --yes: declined, nothing forgotten
///  F3. --yes: the ended and the gone ones forgotten, the running one kept
///  F4. a second run forgets nothing; --forget on the running one keeps it, saying why
func cliHostForgetRows(t: CLIHarness, work: URL, started: (String) -> Void) {
    func rows() -> [SessionRow] { t.json(["sessions", "@mac"], [SessionRow].self) ?? [] }
    let dir = work.appendingPathComponent("fg")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    func run(_ s: String, _ argv: [String]) -> Bool {
        let r = t.run(["run", "@mac", "-d", "--unfenced", "--session", s, "--folder", dir.path, "--"] + argv, timeout: 60)
        if r.code == 0 { started(s) }
        return r.code == 0
    }
    let made = run("fe1", ["/bin/sh", "-c", "echo fe1"]) && run("fr1", ["/bin/sleep", "600"]) && run("fg1", ["/bin/sleep", "600"])
    check(made && t.waitFor(10) { rows().first { $0.name == "fe1" }?.ended == true }, "F an ended (fe1), a running (fr1) and a third session (fg1)")
    t.run(["daemon", "stop"], timeout: 60)
    if let child = rows().first(where: { $0.name == "fg1" })?.pid, let holder = parentOf(child) {
        kill(pid_t(holder), SIGKILL)
        kill(pid_t(child), SIGKILL)
    }
    check(t.waitFor(10) { rows().first { $0.name == "fg1" }?.gone == true }, "F fg1's holder killed: gone")
    check(t.waitFor(10) { !t.hostRunning }, "F no daemon runs")

    var r = t.run(["sessions", "@mac", "--forget-ended", "--dry-run", "--json"], timeout: 30)
    let plan = try? HostWire.decoder.decode(SessionsForgotten.self, from: r.outData)
    check(r.code == 0 && plan?.dryRun == true && Set(plan?.forgotten ?? []).isSuperset(of: ["fe1", "fg1"]) && !(plan?.forgotten ?? []).contains("fr1"),
          "F1 --dry-run: fe1 and fg1 would go, the running fr1 is no candidate (\(plan?.forgotten ?? []))")
    check(!t.hostRunning, "F1 …with no daemon, and none was started")
    r = t.run(["sessions", "@mac", "--forget-ended"], timeout: 60)
    check(r.code != 0 && rows().contains { $0.name == "fe1" }, "F2 no terminal and no --yes: declined, nothing forgotten (\(r.code))")
    r = t.run(["sessions", "@mac", "--forget-ended", "--yes", "--json"], timeout: 60)
    let done = try? HostWire.decoder.decode(SessionsForgotten.self, from: r.outData)
    let names = Set(rows().map(\.name))
    check(r.code == 0 && Set(done?.forgotten ?? []).isSuperset(of: ["fe1", "fg1"]) && !names.contains("fe1") && !names.contains("fg1") && names.contains("fr1"),
          "F3 --yes: the ended and the gone ones forgotten, the running one kept (\(done?.forgotten ?? []))")
    r = t.run(["sessions", "@mac", "--forget-ended", "--yes"], timeout: 60)
    check(r.code == 0 && r.out.contains("nothing to forget"), "F4 a second run forgets nothing (\(r.out.split(separator: "\n").first ?? ""))")
    r = t.run(["sessions", "@mac", "--forget", "fr1", "--yes"], timeout: 60)
    check(r.code == 0 && r.out.contains("kept fr1") && r.out.contains("running") && rows().contains { $0.name == "fr1" && !$0.ended },
          "F4 --forget on a running session keeps it, saying why")
}

/// The parent of `pid` (`ps -o ppid=`).
private func parentOf(_ pid: Int) -> Int? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/ps")
    p.arguments = ["-o", "ppid=", "-p", String(pid)]
    let o = Pipe()
    p.standardOutput = o
    try? p.run()
    p.waitUntilExit()
    return Int(String(decoding: o.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
}
