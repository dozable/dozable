import Darwin
import Foundation
import DozableKit
import DozableHost

// `make test-cli-workspace`, the brief's rows (after rows 1–33, in the same scratch store, chat on):
//
//  34. an edit while setting up posts nothing; once started (no manager: you drive), an edit is announced ONCE as your
//      message ("I edited the work:" and the new text) and logged brief-announced; --if-brief with another sha256 is
//      refused and writes and posts nothing
//  35. doz chat read ROOM --with-log: the workspace's log lines among the messages, by time ("started the work",
//      "edited the work" before its announcement)
func cliWorkspaceBriefRows(_ h: CLIHarness, root: URL, store: DozableStore) {
    print("cli: a workspace's brief — the edit announced, the log among the messages")
    let ws = WorkspaceStore(store: store)
    func text(_ p: String) -> String { (try? String(contentsOfFile: p, encoding: .utf8)) ?? "" }
    func sha(_ p: String) -> String { (try? Data(contentsOf: URL(fileURLWithPath: p))).map(WorkspaceStore.sha256) ?? "" }
    func mine(_ room: String) -> [String] {
        let r = h.run(["chat", "read", room, "--last", "100", "--json"])
        let ms = ((try? JSONSerialization.jsonObject(with: r.outData)) as? [[String: Any]]) ?? []
        return ms.filter { $0["from"] as? String == "ada" && ($0["kind"] as? String) != "change" }.compactMap { $0["content"] as? String }
    }
    let first = root.appendingPathComponent("ann-brief.md").path
    let second = root.appendingPathComponent("ann-brief-2.md").path
    let marker = "EDITED-\(UUID().uuidString.prefix(8))"
    try? "Write the release notes.\n".write(toFile: first, atomically: true, encoding: .utf8)
    try? "Write the release notes, shorter. \(marker)\n".write(toFile: second, atomically: true, encoding: .utf8)

    // 34. setting up: nothing posted
    var r = h.run(["workspace", "new", "pre", "--prompt-file", first], timeout: 60)
    check(r.code == 0, "34 new pre (\(r.code) \(r.err.prefix(160)))")
    r = h.run(["workspace", "edit", "pre", "--prompt-file", second], timeout: 60)
    check(r.code == 0 && mine("pre").isEmpty, "34 an edit while setting up posts nothing (\(r.code))")
    check(!((try? ws.log("pre")) ?? []).map(\.action).contains("brief-announced"), "34 …and logs no announcement")

    // 34. started (you drive): the kick-off, then each edit announced once
    h.run(["workspace", "new", "ann", "--prompt-file", first], timeout: 60)
    r = h.run(["workspace", "start", "ann"], timeout: 60)
    check(r.code == 0 && mine("ann").count == 1, "34 start ann: the kick-off is your first message (\(r.code) \(r.err.prefix(160)))")
    let recPath = ws.folder("ann") + "/workspace.json"
    let before = sha(recPath)
    r = h.run(["workspace", "edit", "ann", "--prompt-file", second, "--if-brief", String(repeating: "0", count: 64)], timeout: 60)
    check(r.code != 0 && r.err.contains("changed since you opened it"), "34 --if-brief another sha256: refused (\(r.code) \(r.err.prefix(160)))")
    check(sha(recPath) == before && mine("ann").count == 1, "34 …nothing written, nothing posted")
    let current = h.json(["workspace", "show", "ann"], WorkspaceDetail.self)?.brief.sha256 ?? ""
    r = h.run(["workspace", "edit", "ann", "--prompt-file", second, "--if-brief", current], timeout: 60)
    let posts = mine("ann")
    check(r.code == 0 && posts.count == 2, "34 edit ann after the start: one more message of yours (\(r.code), \(posts.count))")
    check(posts.last?.hasPrefix("I edited the work:") == true && posts.last?.contains(marker) == true, "34 …saying so, with the new brief (\(posts.last?.prefix(60) ?? ""))")
    let acts = (try? ws.log("ann").map(\.action)) ?? []
    check(acts.suffix(2) == ["brief-edited", "brief-announced"], "34 …logged brief-edited, brief-announced (\(acts.suffix(2)))")
    check(!(text(ws.folder("ann") + "/log.jsonl").contains(marker)), "34 …the brief's text in no log")

    // 35. the log among the messages
    r = h.run(["chat", "read", "ann", "--with-log"], timeout: 60)
    let lines = r.out.split(separator: "\n").map(String.init)
    let started = lines.firstIndex { $0.contains(" — you started the work: posted the brief in ann") }
    let edited = lines.firstIndex { $0.contains(" — you edited the work (") }
    let announcement = lines.firstIndex { $0.contains(" ada: I edited the work:") }
    let kickoff = lines.firstIndex { $0.contains(" ada: Write the release notes.") }
    check(r.code == 0 && started != nil && edited != nil && announcement != nil && kickoff != nil,
          "35 chat read ann --with-log: the log's lines among the messages (\(r.code) \(r.out.prefix(400)))")
    if let started, let edited, let announcement, let kickoff {
        check(kickoff < started && started < edited && edited < announcement, "35 …by time (\(kickoff), \(started), \(edited), \(announcement))")
    }
    r = h.run(["chat", "read", "ann"], timeout: 60)
    check(!r.out.contains("edited the work ("), "35 without --with-log: messages only")
    check(h.run(["chat", "read", "ann", "--with-log", "--json"]).code == 64, "35 --with-log with --json: refused")
}
