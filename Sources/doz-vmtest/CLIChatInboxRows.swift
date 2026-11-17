// `make test-cli-chat`, rows 28–34: a Claude Code session delivered to by inbox, end to end through the daemon — never a
// real session. The sessions folder is the suite's seam (DOZ_TEST_CLAUDE_SESSIONS, a scratch folder the Makefile sets for
// every test target; the daemon reads it from the environment it was started with); the "session" is `SuiteClaudeSession`,
// a record and key file the suite writes there and a socket it listens on under /tmp. dozchat is the one `make cli` put
// beside doz (dozchat-mac), run with CHAT_URL naming the suite's port (8790, its default on a Mac, may be this Mac's own
// chat: never used here) and CHAT_TOKEN_FILE, no proxy.
//
//  28. add bot4 --kind claude-session --inbox --to-file: what it says (the sentence, CHAT_TOKEN_FILE, CHAT_URL for a port
//      that is not 8790); who: inbox, not running; status and doctor: the standing line naming the folder read
//  29. no session running: a message is failed "no running Claude session with that name"
//  30. a scratch session: the next message is in its inbox (delivered), its text ends with the dozchat answer; who: idle
//  31. the session answers with dozchat send ROOM --re ID "…" and its own token: in the room, as an answer
//  32. set bot4 --deliver poll: its rooms and token kept, it receives by polling; set --deliver inbox again; the refusals
//  33. the sweep: the token and the session's key in no log, no file of the store, no --json
//  34. remove bot4: the standing line goes
import Darwin
import Foundation
import DozableChat
import DozableHost

/// A Claude Code session the suite makes (never a real one): its record and key in the scratch sessions folder, its
/// socket in a scratch folder under /tmp.
final class SuiteClaudeSession: @unchecked Sendable {
    let socketDir: String
    let record: String
    let key: String
    let peerKey = "suite-peer-key-" + UUID().uuidString.prefix(12).lowercased()
    private let fd: Int32
    private let lock = NSLock()
    private var got: [String] = []

    init?(name: String, sessionsDir: String) {
        guard TestSafety.claudeSessionsViolation(sessionsDir) == nil else { return nil }
        var template = Array("/tmp/dzs-XXXXXX".utf8CString)
        guard let made = mkdtemp(&template) else { return nil }
        socketDir = String(cString: made)
        let path = socketDir + "/inbox.sock"
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in for (i, b) in Array(path.utf8).enumerated() { raw[i] = b } }
        guard withUnsafePointer(to: &addr, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }) == 0,
              listen(s, 16) == 0 else { close(s); return nil }
        fd = s
        try? FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        record = sessionsDir + "/\(getpid()).json"
        key = sessionsDir + "/\(getpid()).5eed5eed.key"
        let ms = Int64(Date().timeIntervalSince1970 * 1000)
        FileManager.default.createFile(atPath: key, contents: Data(#"{"peerToken":"\#(peerKey)"}"#.utf8), attributes: [.posixPermissions: 0o600])
        FileManager.default.createFile(atPath: record, contents: Data(#"{"pid":\#(getpid()),"name":"\#(name)","messagingSocketPath":"\#(path)","status":"idle","statusUpdatedAt":\#(ms)}"#.utf8),
                                       attributes: [.posixPermissions: 0o600])
        Thread.detachNewThread { [self] in serve() }
    }

    /// The message lines' texts, in order.
    var texts: [String] { lock.withLock { got } }

    func stop() {
        shutdown(fd, SHUT_RDWR)
        close(fd)
        unlink(record); unlink(key)
        try? FileManager.default.removeItem(atPath: socketDir)
    }

    private func serve() {
        while true {
            let c = accept(fd, nil, nil)
            if c < 0 { return }
            var data = [UInt8](), buf = [UInt8](repeating: 0, count: 65536)
            while true { let n = read(c, &buf, buf.count); if n <= 0 { break }; data += buf[0..<n] }
            close(c)
            for line in data.split(separator: 0x0A) {
                guard let v = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any], v["type"] as? String == "user",
                      let t = (v["message"] as? [String: Any])?["content"] as? String else { continue }
                lock.withLock { got.append(t) }
            }
        }
    }
}

func cliChatInboxRows(h: CLIHarness, root: URL, paths: ChatPaths, page: Int, sh: (_ argv: [String], _ stdin: Data?) -> (Int32, String)) {
    let fm = FileManager.default
    guard let sessions = h.env[ChatClaudeSessions.testSeam], sessions.hasPrefix("/"), TestSafety.claudeSessionsViolation(sessions) == nil else {
        check(false, "28 the inbox rows need the scratch sessions folder (DOZ_TEST_CLAUDE_SESSIONS, the Makefile's): not run")
        return
    }
    try? fm.createDirectory(atPath: sessions, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    var outputs: [String: String] = [:]

    // 28. add --inbox
    let tf = root.appendingPathComponent("bot4.token").path
    var r = h.run(["chat", "add", "bot4", "--inbox", "--to-file", tf], timeout: 60)
    outputs["add"] = r.out
    let token = ((try? String(contentsOfFile: tf, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    check(r.code == 0 && r.out.hasPrefix("Added bot4 (claude-session): the chat server writes each message for it into the inbox of the Claude Code session named bot4 on this Mac"),
          "28 add bot4 --inbox (\(r.out.split(separator: "\n").first ?? ""))")
    check(r.out.contains("  CHAT_TOKEN_FILE=") && r.out.contains("  CHAT_URL=http://127.0.0.1:\(page)\n") && !r.out.contains(token),
          "28 …it prints the two settings for the session (CHAT_URL: the port is not 8790), never the token")
    r = h.run(["chat", "add", "bot5", "--kind", "agent", "--inbox", "--to-file", tf + "5"], timeout: 60)
    check(r.code != 0 && !fm.fileExists(atPath: tf + "5"), "28 --inbox for an agent is refused (\(r.code))")
    r = h.run(["chat", "who"])
    let row = r.out.split(separator: "\n").first { $0.hasPrefix("bot4") }.map(String.init) ?? ""
    check(row.contains("claude-session") && row.contains(" inbox ") && row.hasSuffix("not running"), "28 who: bot4 claude-session inbox … not running (\(row))")
    r = h.run(["chat", "status"])
    let line = "delivers into Claude Code sessions on this Mac: reads \(DisplayPath.tilde(sessions))"
    check(r.out.contains("  " + line + "\n"), "28 status: the standing line (\(line))")
    r = h.run(["chat", "status", "--json"])
    outputs["status --json"] = r.out
    check(r.out.contains("\"claudeSessions\"") && r.out.contains(sessions), "28 status --json: claudeSessions names the folder")
    r = h.run(["doctor"], timeout: 120)
    outputs["doctor"] = r.out
    check(r.out.split(separator: "\n").contains { $0.contains("chat") && $0.contains(line) }, "28 doctor: the chat row says it")
    if let s = ChatServer.status(dataDir: paths.data, release: "").running ? ChatServer.status(dataDir: paths.data, release: "").pid : nil {
        let argv = ProcessArguments.of(pid_t(s)) ?? []
        check(argv.firstIndex(of: "--claude-sessions").map { argv[$0 + 1] } == sessions, "28 the server is handed exactly that folder")
    } else { check(false, "28 a chat server runs") }
    _ = h.run(["chat", "room", "room4", "@bot4"])

    // 29. no session
    func read(_ room: String) -> String { h.run(["chat", "read", room, "--json"]).out }
    _ = h.run(["chat", "send", "room4", "first @bot4"])
    let failed = h.waitFor(10) { read("room4").contains("no running Claude session with that name") }
    check(failed, "29 no session running: failed, no running Claude session with that name")

    // 30. a scratch session
    guard let session = SuiteClaudeSession(name: "bot4", sessionsDir: sessions) else { check(false, "30 a scratch session"); return }
    defer { session.stop() }
    _ = h.run(["chat", "send", "room4", "second @bot4"])
    let handed = h.waitFor(10) { session.texts.contains { $0.contains("second @bot4") } }
    let text = session.texts.first { $0.contains("second @bot4") } ?? ""
    let id = text.range(of: #"--re [0-9a-f-]{36}"#, options: .regularExpression).map { String(text[$0].dropFirst(5)) } ?? ""
    check(handed && text.hasSuffix("To answer in the room: dozchat send room4 --re \(id) \"…\""), "30 the message is in the session's inbox, ending with the dozchat answer")
    check(h.waitFor(10) { read("room4").contains("in the session's inbox in") }, "30 …marked delivered")
    r = h.run(["chat", "who"])
    check(r.out.split(separator: "\n").contains { $0.hasPrefix("bot4") && $0.hasSuffix("idle") }, "30 who: bot4 idle")

    // 31. the answer, as the text says, with its own token
    let dozchat = URL(fileURLWithPath: h.binary).deletingLastPathComponent().appendingPathComponent("dozchat-mac").path
    if fm.isExecutableFile(atPath: dozchat), !id.isEmpty {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: dozchat)
        p.arguments = ["send", "room4", "--re", id, "the answer from bot4"]
        p.environment = ["PATH": "/usr/bin:/bin", "HOME": root.path, "CHAT_URL": "http://127.0.0.1:\(page)", "CHAT_TOKEN_FILE": tf]
        let o = Pipe()
        p.standardOutput = o
        p.standardError = o
        try? p.run()
        let out = String(decoding: o.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        outputs["dozchat"] = out
        check(p.terminationStatus == 0 && out.contains("\"queued\""), "31 dozchat send room4 --re ID \"…\" with CHAT_TOKEN_FILE (and the suite's CHAT_URL), no proxy (\(p.terminationStatus))")
        let back = read("room4")
        check(back.contains("the answer from bot4") && back.contains("re_msg_id") && back.components(separatedBy: id).count > 2, "31 …in the room, as bot4's answer")
    } else { check(false, "31 dozchat-mac beside doz (make cli) and the message's id") }

    // 32. set --deliver poll and back
    r = h.run(["chat", "set", "bot4", "--deliver", "poll"], timeout: 60)
    check(r.code == 0 && r.out.contains("polls with its own token. Its token, rooms and history are kept."), "32 set bot4 --deliver poll (\(r.out.trimmingCharacters(in: .newlines)))")
    r = h.run(["chat", "who"])
    check(r.out.split(separator: "\n").contains { $0.hasPrefix("bot4") && $0.contains("polls") && $0.contains("room4") }, "32 who: polls, still in room4")
    check(!h.run(["chat", "status"]).out.contains("delivers into Claude Code sessions"), "32 no inbox participant: no standing line")
    _ = h.run(["chat", "send", "room4", "third @bot4"])
    let got = sh(["/usr/bin/curl", "-s", "-m", "15", "-H", "Authorization: Bearer \(token)", "http://127.0.0.1:\(page)/agent/receive?wait=5"], nil).1
    check(got.contains("third @bot4") && !session.texts.contains { $0.contains("third @bot4") }, "32 …it collects the next one by polling, with the same token")
    r = h.run(["chat", "set", "bot4", "--deliver", "inbox"], timeout: 60)
    check(r.code == 0 && r.out.contains("Its token, rooms and history are kept.") && r.out.contains("CHAT_TOKEN_FILE="), "32 set bot4 --deliver inbox")
    _ = h.run(["chat", "send", "room4", "fourth @bot4"])
    check(h.waitFor(10) { session.texts.contains { $0.contains("fourth @bot4") } }, "32 …the next message is in its inbox again")
    r = h.run(["chat", "set", "bot1", "--deliver", "inbox"], timeout: 60)
    check(r.code != 0 && r.err.contains("claude-session"), "32 inbox for an agent is refused, with the kind to set (\(r.code))")
    r = h.run(["chat", "set", "bot4", "--deliver", "socket"])
    check(r.code == 64, "32 an unknown delivery is a usage error (\(r.code))")
    r = h.run(["chat", "set", "bot4", "--deliver", "inbox", "--json"], timeout: 60)
    outputs["set --json"] = r.out
    check(r.code == 0 && r.out.contains("\"delivery\"") && r.out.contains("inbox"), "32 set --json says the delivery")

    // 33. the sweep
    for (n, args) in [("who --json", ["chat", "who", "--json"]), ("daemon status --json", ["daemon", "status", "--json"])] { outputs[n] = h.run(args).out }
    var leaks: [String] = []
    for (n, t) in outputs where t.contains(token) || t.contains(session.peerKey) { leaks.append(n) }
    for f in (try? fm.subpathsOfDirectory(atPath: root.path)) ?? [] where f != "bot4.token" {
        guard let d = fm.contents(atPath: root.path + "/" + f) else { continue }
        let t = String(decoding: d, as: UTF8.self)
        if t.contains(token) || t.contains(session.peerKey) { leaks.append(f) }
    }
    check(!token.isEmpty && leaks.isEmpty, "33 the token and the session's key are in no log, no file of the store, no --json\(leaks.isEmpty ? "" : ": " + leaks.joined(separator: ", "))")

    // 34. remove
    r = h.run(["chat", "remove", "bot4"], timeout: 60)
    check(r.code == 0 && !h.run(["chat", "status"]).out.contains("delivers into Claude Code sessions"), "34 remove bot4: the standing line goes")
}
