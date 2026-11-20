// `make test-cli-chat`, rows 41–45: a whole room read and exported — no 500 cap, attachments, the leak sweep.
//
//  41. 600 messages, one with an attachment and one with a planted live token (bot9's), posted as you on your socket
//  42. chat read ROOM --since 1h --json: every one of them (more than 500), oldest first; --last with --since refused
//  43. chat export ROOM --to DIR: ROOM.jsonl has every message, the attachment is copied byte for byte, manifest.json lists
//      each file's sha256; the planted token is replaced and named with its fix (bot9, doz chat token bot9 --new) — never
//      its value, in no exported file, no --json, no log, no ps output
//  44. a folder that is not empty, or one inside the store, is refused with nothing written
//  45. (after row 9's daemon stop) read --since and export are refused with no daemon, and nothing starts one
import Darwin
import Foundation
import DozableChat
import DozableHost

func cliChatExportRows(h: CLIHarness, root: URL, paths: ChatPaths) {
    let fm = FileManager.default
    let owner = ChatOwnerClient(paths: paths)
    // Exports go beside the scratch store, never into it (that is refused, row 44).
    let outside = URL(fileURLWithPath: root.path + "-exports")
    try? fm.createDirectory(at: outside, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: outside) }
    // 41. the room and its messages
    var r = h.run(["chat", "room", "export1"])
    check(r.code == 0, "41 a room export1 (\(r.code))")
    let botFile = root.appendingPathComponent("bot9.token").path
    r = h.run(["chat", "add", "bot9", "--to-file", botFile], timeout: 60)
    let planted = ((try? String(contentsOfFile: botFile, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    var posted = 0
    for i in 1...600 {
        let body = ChatJSON.encode(.map(["content": .string(i == 300 ? "pasted by mistake: \(planted)" : "message \(i)")]))
        if let a = try? owner.request("POST", "/api/rooms/export1/messages", json: Data(body)), a.status == 200 { posted += 1 }
    }
    let fileBytes = Data((0..<4096).map { UInt8($0 % 251) })
    var attached = false
    if let up = try? owner.request("POST", "/api/files?name=blob.bin", json: fileBytes, contentType: "application/octet-stream"),
       up.status == 200, let a = try? ChatJSON.parse(up.body) {
        let body = ChatJSON.encode(.map(["content": .string("a file"), "attachments": .array([a])]))
        attached = (try? owner.request("POST", "/api/rooms/export1/messages", json: Data(body)))?.status == 200
    }
    check(posted == 600 && attached && !planted.isEmpty, "41 600 messages and one with an attachment posted (\(posted))")

    // 42. read --since: no cap
    r = h.run(["chat", "read", "export1", "--since", "1h", "--json"], timeout: 120)
    let read = (try? ChatJSON.parse(Array(r.out.utf8))).flatMap { v -> [JValue]? in if case .array(let a) = v { return a }; return nil } ?? []
    check(r.code == 0 && read.count >= 601, "42 read --since 1h --json: every message, more than 500 (\(read.count))")
    check(read.first?.field("content")?.stringValue == "message 1" || read.first?.field("kind")?.stringValue == "change", "42 …oldest first")
    r = h.run(["chat", "read", "export1", "--since", "1h", "--last", "5"])
    check(r.code == 64, "42 --last with --since is refused (\(r.code))")
    r = h.run(["chat", "read", "export1", "--since", "1h"], timeout: 120)
    check(r.code == 0 && r.out.contains("message 1\n") && r.out.contains("message 600\n"), "42 read --since shows them all as lines")

    // 43. export
    let out = outside.appendingPathComponent("export-43").path
    r = h.run(["chat", "export", "export1", "--to", out, "--json"], timeout: 120)
    let jsonl = (try? String(contentsOfFile: out + "/export1.jsonl", encoding: .utf8)) ?? ""
    let lines = jsonl.split(separator: "\n").count
    check(r.code == 0 && lines >= 601, "43 export: export1.jsonl has every message (\(lines) lines)")
    let copied = (try? fm.contentsOfDirectory(atPath: out + "/attachments")).flatMap { ids in ids.first.flatMap { fm.contents(atPath: out + "/attachments/\($0)/blob.bin") } }
    check(copied == fileBytes, "43 the attachment is copied byte for byte")
    let manifest = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: out + "/manifest.json")))) as? [String: Any]
    let sweep = manifest?["sweep"] as? [String: Any]
    let findings = sweep?["findings"] as? [[String: Any]] ?? []
    check(manifest?["version"] as? Int == 1 && (manifest?["files"] as? [Any])?.count == 2, "43 manifest.json v1 lists both files")
    check(sweep?["redacted"] as? Int == 1 && findings.first?["participant"] as? String == "bot9", "43 the sweep found bot9's token and removed it")
    check(jsonl.contains("[a chat token of bot9, removed by doz]"), "43 …replaced in place")
    var leaks: [String] = []
    for f in (try? fm.subpathsOfDirectory(atPath: out)) ?? [] where (fm.contents(atPath: out + "/" + f)).map({ String(decoding: $0, as: UTF8.self).contains(planted) }) == true {
        leaks.append(f)
    }
    if r.out.contains(planted) { leaks.append("--json") }
    let out2 = outside.appendingPathComponent("export-43b").path
    r = h.run(["chat", "export", "export1", "--to", out2], timeout: 120)
    check(r.code == 0 && r.out.contains("bot9") && r.out.contains("doz chat token bot9 --new"), "43 the export names whose token it removed and the fix")
    if r.out.contains(planted) { leaks.append("stdout") }
    let store = DozableStore(root: root)
    for (n, text) in [("daemon.log", (try? String(contentsOf: store.logFile, encoding: .utf8)) ?? ""), ("server.log", (try? String(contentsOfFile: paths.serverLog, encoding: .utf8)) ?? ""),
                      ("ps", psArgs())] where text.contains(planted) { leaks.append(n) }
    check(leaks.isEmpty, "43 the planted token is in no exported file, no --json or output, no log, no ps\(leaks.isEmpty ? "" : ": " + leaks.joined(separator: ", "))")
    var st = stat()
    check(lstat(out, &st) == 0 && st.st_mode & 0o777 == 0o700 && lstat(out + "/export1.jsonl", &st) == 0 && st.st_mode & 0o777 == 0o600,
          "43 the folder is 0700, its files 0600")

    // 44. refusals
    r = h.run(["chat", "export", "export1", "--to", out], timeout: 60)
    check(r.code != 0 && r.err.contains("not empty"), "44 a folder that is not empty is refused (\(r.code))")
    r = h.run(["chat", "export", "export1", "--to", root.appendingPathComponent("chat/exports").path], timeout: 60)
    check(r.code != 0 && r.err.contains("inside doz's store") && !fm.fileExists(atPath: root.appendingPathComponent("chat/exports").path),
          "44 a folder inside the store is refused, nothing made")
    h.run(["chat", "remove", "bot9"], timeout: 60)
    try? fm.removeItem(atPath: out)
    try? fm.removeItem(atPath: out2)
    try? fm.removeItem(atPath: botFile)
}

/// Row 45: with no daemon, reading a window and exporting are refused, and no daemon is started.
func cliChatExportNoDaemonRow(h: CLIHarness, root: URL) {
    let out = root.path + "-exports/export-45"
    let r1 = h.run(["chat", "export", "export1", "--to", out])
    let r2 = h.run(["chat", "read", "export1", "--since", "1d"])
    check(r1.code == 6 && r1.err.contains("the chat server runs while the daemon does") && r2.code == 6, "45 no daemon: export and read --since are refused (\(r1.code), \(r2.code))")
    check(!h.hostRunning && !FileManager.default.fileExists(atPath: out), "45 …no daemon started, nothing written")
}
