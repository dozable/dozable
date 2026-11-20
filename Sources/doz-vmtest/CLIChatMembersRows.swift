// `make test-cli-chat`, rows 35–40: participants changed while the chat server runs — taken over the daemon's control
// channel, never a restart (docs/engineering/chat.md, "The control channel").
//
//  35. add bot3 bot4 bot5 --to-dir DIR: the server's pid and its restart count unchanged, one reload more; each token in its
//      own 0600 file in a 0700 folder; --json names the files, never a token; an open `chat read --follow` keeps streaming
//  36. a second name without --to-dir is refused; an existing token file refuses the batch with nothing added
//  37. bot3 waits in /agent/receive; remove bot3: its wait ends with 401 at once, and its token is 401 from then on
//  38. the person's EDGE 17: bot4 invited to room1, then remove bot4 bot5 (asked once: no terminal, no --yes → nothing
//      done; --yes → both gone); add bot4 again: it is back in room1 with no invite (as after a restart)
//  39. the server's argv names `--control-fd 4` and no token; the server is still the same process
//  40. the sweep: no token of the batch in a log, a file of the chat folder, any --json or ps output
import Darwin
import Foundation
import DozableChat
import DozableHost

func cliChatMembersRows(h: CLIHarness, root: URL, paths: ChatPaths, page: Int, sh: ([String], Data?) -> (Int32, String),
                        server: () -> Int32?, supervisor: () -> ChatServerState?) {
    let fm = FileManager.default
    func curlCode(_ t: String, wait: Int = 0) -> String {
        sh(["/usr/bin/curl", "-s", "-m", "30", "-o", "/dev/null", "-w", "%{http_code}", "-H", "Authorization: Bearer \(t)",
            "http://127.0.0.1:\(page)/agent/receive?wait=\(wait)"], nil).1
    }
    guard let pid0 = server(), let st0 = supervisor() else { check(false, "35 a chat server runs"); return }
    let reloads0 = st0.reloads ?? 0

    // An open follow (the person's stream on the owner's socket) across the batch.
    let follow = h.process(["chat", "read", "room1", "--follow"])
    let fo = Pipe()
    follow.standardOutput = fo
    follow.standardError = FileHandle.nullDevice
    try? follow.run()
    let followed = PipeCollector(fo.fileHandleForReading)
    usleep(800_000)

    // 35. the batch
    let dir = root.appendingPathComponent("tokens-35").path
    var r = h.run(["chat", "add", "bot3", "bot4", "bot5", "--to-dir", dir, "--json"], timeout: 60)
    let tokens = ["bot3", "bot4", "bot5"].map { ((try? String(contentsOfFile: dir + "/\($0).token", encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
    check(r.code == 0 && tokens.allSatisfy { $0.hasPrefix("dzc_") }, "35 add bot3 bot4 bot5 --to-dir (\(r.code))")
    var st = stat()
    check(lstat(dir, &st) == 0 && st.st_mode & 0o777 == 0o700, "35 the folder is 0700")
    check(["bot3", "bot4", "bot5"].allSatisfy { lstat(dir + "/\($0).token", &st) == 0 && st.st_mode & 0o777 == 0o600 }, "35 each token file is 0600")
    check(r.out.contains("bot5.token") && !tokens.contains { r.out.contains($0) }, "35 --json names the files, never a token")
    let st35 = supervisor()
    check(server() == pid0 && st35?.restarts == st0.restarts && (st35?.reloads ?? 0) == reloads0 + 1,
          "35 the same server (pid \(pid0)), restarts \(st35?.restarts ?? -1) unchanged, one reload more (\(st35?.reloads ?? -1))")
    check(curlCode(tokens[0]) == "200", "35 bot3's token works at once")
    r = h.run(["chat", "send", "room1", "after the batch"])
    let streamed = h.waitFor(10) { followed.text.contains("after the batch") }
    check(r.code == 0 && streamed && follow.isRunning, "35 an open read --follow keeps streaming across the batch")
    follow.terminate()

    // 36. refusals
    r = h.run(["chat", "add", "bot6", "bot7"])
    check(r.code == 64, "36 a second name without --to-dir is refused (\(r.code))")
    r = h.run(["chat", "add", "bot6", "bot3", "--to-dir", dir], timeout: 60)
    check(r.code == 4 && !h.run(["chat", "who"]).out.contains("bot6") && !fm.fileExists(atPath: dir + "/bot6.token"),
          "36 an existing token file refuses the batch: nothing added, no file left (\(r.code))")

    // 37. a removal ends a waiting receive at once
    let waiter = Process()
    waiter.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
    waiter.arguments = ["-s", "-m", "40", "-o", "/dev/null", "-w", "%{http_code}", "-H", "Authorization: Bearer \(tokens[0])",
                        "http://127.0.0.1:\(page)/agent/receive?wait=30"]
    let wo = Pipe()
    waiter.standardOutput = wo
    try? waiter.run()
    let waited = PipeCollector(wo.fileHandleForReading)
    usleep(1_000_000)
    let t37 = Date()
    r = h.run(["chat", "remove", "bot3"], timeout: 60)
    let ended = h.waitFor(10) { !waiter.isRunning }
    waited.wait(2)
    check(r.code == 0 && ended && waited.text == "401" && Date().timeIntervalSince(t37) < 10,
          String(format: "37 remove bot3: its waiting receive ended with %@ in %.1f s", waited.text, Date().timeIntervalSince(t37)))
    if waiter.isRunning { waiter.terminate() }
    check(curlCode(tokens[0]) == "401", "37 …and its token is 401 from then on")
    check(server() == pid0, "37 the same server")

    // 38. EDGE 17
    r = h.run(["chat", "send", "room1", "/invite @bot4"])
    check(h.run(["chat", "rooms"]).out.contains("bot4"), "38 bot4 invited to room1")
    r = h.run(["chat", "remove", "bot4", "bot5"], timeout: 60)
    check(r.code != 0 && h.run(["chat", "who"]).out.contains("bot4"), "38 remove bot4 bot5 with no terminal and no --yes: nothing done (\(r.code))")
    r = h.run(["chat", "remove", "bot4", "bot5", "--yes"], timeout: 60)
    check(r.code == 0 && r.out == "Removed bot4, bot5.\n" && !h.run(["chat", "rooms"]).out.contains("bot4"), "38 remove bot4 bot5 --yes: both gone, out of room1")
    check(curlCode(tokens[1]) == "401" && curlCode(tokens[2]) == "401", "38 …their tokens 401")
    let again = root.appendingPathComponent("bot4-again.token").path
    r = h.run(["chat", "add", "bot4", "--to-file", again], timeout: 60)
    let rooms = h.run(["chat", "rooms"]).out
    check(r.code == 0 && rooms.split(separator: "\n").contains { $0.hasPrefix("room1") && $0.contains("bot4") },
          "38 bot4 added again is back in room1 with no invite, as after a restart (EDGE 17)")
    let tokenAgain = ((try? String(contentsOfFile: again, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    h.run(["chat", "remove", "bot4"], timeout: 60)

    // 39. the channel in argv, never a token
    let args = psArgs().split(separator: "\n").first { $0.contains("chat serve") && $0.contains(paths.config) }.map(String.init) ?? ""
    check(args.contains("--control-fd 4") && !tokens.contains { args.contains($0) }, "39 the server's argv names --control-fd 4 and no token")
    let st39 = supervisor()
    check(server() == pid0 && st39?.restarts == st0.restarts, "39 rows 35–38 changed participants \( (st39?.reloads ?? 0) - reloads0) times with no restart")
    r = h.run(["chat", "status"])
    check(r.out.contains("participant changes without a restart") || r.out.contains("participant change without a restart"),
          "39 status says how many participant changes it took without a restart")

    // 40. the sweep
    var leaks: [String] = []
    let secrets = tokens + [tokenAgain]
    for f in (try? fm.subpathsOfDirectory(atPath: paths.folder)) ?? [] {
        if let text = try? String(contentsOfFile: paths.folder + "/" + f, encoding: .utf8), secrets.contains(where: { text.contains($0) }) { leaks.append(f) }
    }
    let store = DozableStore(root: root)
    for (n, text) in [("daemon.log", (try? String(contentsOf: store.logFile, encoding: .utf8)) ?? ""),
                      ("chat status --json", h.run(["chat", "status", "--json"]).out), ("chat who --json", h.run(["chat", "who", "--json"]).out),
                      ("daemon status --json", h.run(["daemon", "status", "--json"]).out), ("ps", psArgs())]
        where secrets.contains(where: { text.contains($0) }) { leaks.append(n) }
    check(leaks.isEmpty, "40 no token of these rows in a log, a file of the chat folder, --json or ps\(leaks.isEmpty ? "" : ": " + leaks.joined(separator: ", "))")
    try? fm.removeItem(atPath: dir)
    try? fm.removeItem(atPath: again)
}
