// `make test-cli-chat`, rows C1–C6: a room archived and removed for good — only after a copy that verifies now.
//
//  C1. a room a workspace links is refused (exit 3), with --loose too; a loose room is refused without --loose
//  C2. refused while the owning workspace's run is open
//  C3. after its finish: archive copies its whole history (600+ messages) into the store, verified; the room is read-only
//  C4. rm with no archive is refused; a loose room archived, then /unarchive, a post and /archive again: rm refused "changed
//      since it was archived"
//  C5. rm with no terminal and no --yes: exit 5; --yes without --confirm refused; with --confirm: gone — a member's long poll
//      ends, its post answers as for an unknown room, the chat server's pid unchanged, the tombstone has all five fields
//      (doz chat rooms --gone), a room made again under the name gets a new id
//  C5b. rm --loose of a loose room, archived first: its tombstone has no owner
//  (C6. the conformance gate stays at 171: make test-chat-conformance)
import Darwin
import Foundation
import DozableChat
import DozableHost

func cliChatRoomRows(h: CLIHarness, root: URL, paths: ChatPaths, page: Int, server: () -> Int32?,
                     curl: ([String]) -> String) {
    let fm = FileManager.default
    let owner = ChatOwnerClient(paths: paths)
    let brief = root.appendingPathComponent("room-brief.md").path
    fm.createFile(atPath: brief, contents: Data("Rooms.\n".utf8))
    func post(_ room: String, _ text: String) -> Int {
        (try? owner.request("POST", "/api/rooms/\(room)/messages", json: Data(ChatJSON.encode(.map(["content": .string(text)])))))?.status ?? 0
    }

    // C1. linked and loose
    var r = h.run(["chat", "room", "linkedc"])
    r = h.run(["workspace", "new", "wslink", "--prompt-file", brief, "--room", "linkedc"], timeout: 60)
    check(r.code == 0, "C1 a workspace that links linkedc (\(r.code) \(r.err.prefix(160)))")
    r = h.run(["chat", "room", "archive", "linkedc", "--yes"], timeout: 60)
    check(r.code == 3 && r.err.contains("linked"), "C1 a linked room is refused: exit 3 (\(r.code) \(r.err.prefix(160)))")
    r = h.run(["chat", "room", "rm", "linkedc", "--loose", "--yes", "--confirm", "linkedc"], timeout: 60)
    check(r.code == 3 && r.err.contains("linked"), "C1 …with --loose too (\(r.code))")
    h.run(["chat", "room", "loosec"])
    _ = post("loosec", "a loose message")
    r = h.run(["chat", "room", "archive", "loosec", "--yes"], timeout: 60)
    check(r.code == 3 && r.err.contains("--loose"), "C1 a loose room is refused without --loose (\(r.code) \(r.err.prefix(160)))")

    // C2. an open run
    r = h.run(["workspace", "new", "wsroom", "--prompt-file", brief], timeout: 60)
    check(r.code == 0, "C2 a workspace wsroom with its own room (\(r.code) \(r.err.prefix(160)))")
    r = h.run(["workspace", "start", "wsroom"], timeout: 60)
    check(r.code == 0, "C2 …started: its run open (\(r.code) \(r.err.prefix(160)))")
    r = h.run(["chat", "room", "archive", "wsroom", "--yes"], timeout: 60)
    check(r.code == 3 && r.err.contains("is open"), "C2 archive refused while its run is open (\(r.code) \(r.err.prefix(160)))")
    // A member that will be waiting when the room goes.
    let tokenFile = root.appendingPathComponent("rmbot.token").path
    h.run(["chat", "add", "rmbot", "--to-file", tokenFile], timeout: 60)
    let token = ((try? String(contentsOfFile: tokenFile, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    _ = post("wsroom", "/invite @rmbot")
    var posted = 0
    for i in 1...600 where post("wsroom", "work \(i)") == 200 { posted += 1 }
    check(posted == 600, "C2 600 messages in the run (\(posted))")
    r = h.run(["workspace", "finish", "wsroom", "--yes"], timeout: 180)
    check(r.code == 0, "C3 finish (\(r.code) \(r.err.prefix(200)))")

    // C4. rm with no archive
    r = h.run(["chat", "room", "rm", "wsroom", "--yes", "--confirm", "wsroom"], timeout: 60)
    check(r.code == 3 && r.err.contains("not archived"), "C4 rm with no archive is refused (\(r.code) \(r.err.prefix(160)))")

    // C3. archive: the whole history, verified; the room read-only
    r = h.run(["chat", "room", "archive", "wsroom", "--yes", "--json"], timeout: 180)
    let changed = try? JSONDecoder().decode(ChatRoomChanged.self, from: Data(r.out.utf8))
    let dir = WorkspaceStore.resolved(root.path) + "/" + (changed?.archive ?? "?")
    let v = RunArchive.verify(root: dir)
    check(r.code == 0 && v.ok && (v.manifest?.messages["wsroom"] ?? 0) >= 601, "C3 archive: its whole history copied and verified (\(r.code), \(v.manifest?.messages["wsroom"] ?? -1) messages)")
    var st = stat()
    check(lstat(dir, &st) == 0 && st.st_mode & 0o777 == 0o700 && lstat(dir + "/manifest.json", &st) == 0 && st.st_mode & 0o777 == 0o600, "C3 …0700, its files 0600")
    check(post("wsroom", "after the archive") != 200 && h.run(["chat", "read", "wsroom"]).code == 0, "C3 …read-only, still readable")

    // C4. the loose room changed since its archive
    r = h.run(["chat", "room", "archive", "loosec", "--loose", "--yes"], timeout: 120)
    check(r.code == 0, "C4 loosec archived with --loose (\(r.code) \(r.err.prefix(160)))")
    _ = post("loosec", "/unarchive")
    _ = post("loosec", "written after the archive")
    _ = post("loosec", "/archive")
    r = h.run(["chat", "room", "rm", "loosec", "--loose", "--yes", "--confirm", "loosec"], timeout: 60)
    check(r.code == 3 && r.err.contains("changed since it was archived"), "C4 …changed since: rm refused (\(r.code) \(r.err.prefix(160)))")

    // C5. rm
    r = h.run(["chat", "room", "rm", "wsroom"], timeout: 60)
    check(r.code == 5 && h.run(["chat", "rooms"]).out.contains("wsroom"), "C5 rm with no terminal and no --yes: exit 5, nothing removed (\(r.code))")
    r = h.run(["chat", "room", "rm", "wsroom", "--yes"], timeout: 60)
    check(r.code == 64, "C5 --yes without --confirm is refused (\(r.code))")
    // What waited for rmbot (the run's 600 messages) handed over first, so its next receive waits.
    for _ in 0..<20 where curl(["-H", "Authorization: Bearer \(token)", "http://127.0.0.1:\(page)/agent/receive?wait=0"]).contains("\"msg_id\"") {}
    let pid = server()
    let polled = DispatchSemaphore(value: 0)
    var pollAnswer = ""
    var pollSeconds = 0.0
    Thread.detachNewThread {
        let t0 = Date()
        let pr = Process()
        pr.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        pr.arguments = ["-s", "-m", "40", "-H", "Authorization: Bearer \(token)", "http://127.0.0.1:\(page)/agent/receive?wait=30"]
        let pipe = Pipe()
        pr.standardOutput = pipe
        try? pr.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        pr.waitUntilExit()
        pollAnswer = String(decoding: data, as: UTF8.self)
        pollSeconds = Date().timeIntervalSince(t0)
        polled.signal()
    }
    usleep(800_000)
    r = h.run(["chat", "room", "rm", "wsroom", "--yes", "--confirm", "wsroom"], timeout: 60)
    check(r.code == 0, "C5 rm --yes --confirm: removed (\(r.code) \(r.err.prefix(200)))")
    _ = polled.wait(timeout: .now() + 45)
    check(pollSeconds > 0.5 && pollSeconds < 15 && pollAnswer.contains("messages"), "C5 …a member's waiting receive ended when the room went (\(String(format: "%.1f", pollSeconds)) s, not its 30 s)")
    let sent = curl(["-H", "Authorization: Bearer \(token)", "-H", "Content-Type: application/json",
                     "-d", #"{"room":"wsroom","message":{"content":"still here?"}}"#, "http://127.0.0.1:\(page)/agent/send"])
    check(sent.contains("\"refused\"") && sent.contains("no room"), "C5 …its post answers as for an unknown room (\(sent.prefix(120)))")
    check(pid != nil && server() == pid, "C5 …the chat server was not restarted (pid \(pid ?? -1) → \(server() ?? -1))")
    r = h.run(["chat", "rooms", "--gone", "--json"])
    let tombs = (try? JSONSerialization.jsonObject(with: Data(r.out.utf8))) as? [[String: Any]] ?? []
    let t = tombs.first { $0["name"] as? String == "wsroom" }
    check(t != nil && ["name", "id", "deletedAt", "archive", "owner"].allSatisfy { t?[$0] != nil } && (t?["owner"] as? String) == "wsroom",
          "C5 …its tombstone: name, id, deletedAt, run, archive, owner (\(t.map { "\($0.keys.sorted())" } ?? "none"))")
    check(!h.run(["chat", "rooms"]).out.contains("wsroom —"), "C5 …no longer listed")
    r = h.run(["chat", "room", "wsroom"])
    _ = post("wsroom", "a new room of the old name")
    _ = h.run(["chat", "room", "archive", "wsroom", "--loose", "--yes"], timeout: 120)
    let idx = try? ChatRoomIndex.load(paths)
    let newID = idx?.rooms["wsroom"]?.id
    check(r.code == 0 && newID != nil && newID != t?["id"] as? String, "C5 …made again under the same name: a new room, a new id (\(newID ?? "none"))")

    // C5b. --loose: a loose room, archived again first
    _ = post("loosec", "/unarchive")
    r = h.run(["chat", "room", "archive", "loosec", "--loose", "--yes"], timeout: 120)
    check(r.code == 0, "C5b loosec archived again (\(r.code) \(r.err.prefix(160)))")
    r = h.run(["chat", "room", "rm", "loosec", "--loose", "--yes", "--confirm", "loosec"], timeout: 60)
    let lt = (try? ChatRoomIndex.load(paths))?.tombstone("loosec")
    check(r.code == 0 && lt != nil && lt?.owner == nil && lt?.archive.hasPrefix("archives/_/rooms/loosec-") == true,
          "C5b rm --loose: removed, its tombstone with no owner (\(r.code) \(r.err.prefix(160)))")
    try? fm.removeItem(atPath: tokenFile)
    try? fm.removeItem(atPath: brief)
}
