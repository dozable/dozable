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
