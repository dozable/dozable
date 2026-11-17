import Darwin
import Foundation
import DozableKit
import DozableHost

// `make test-cli-fence`, the chat rows: a fenced session is a member of a chat room with `dozchat` and nothing installed —
// the daemon's own chat server on free ports, bot1's token given at launch (`--secret … file=CHAT_TOKEN_FILE`) and its
// page port opened to the session (`--host-port`). Inside: `dozchat` is the session's shim (dozchat-mac beside this doz),
// it sends and receives through the session's proxy and route, the server sees bot1 verified, and the session holds only
// the placeholder. Without `--host-port` the route refuses it (exit 4). Neither the token nor the proxy's password is in
// anything dozchat printed. Chat is turned off again at the end.

func cliFenceChatChecks(_ t: CLIHarness, root: String, store: String, net: String, helpers: String, started: inout Set<String>) async {
    print("cli: dozchat in a fenced session — a chat-room member through the session's proxy and route")
    func put(_ p: String, _ s: String) { FileManager.default.createFile(atPath: p, contents: Data(s.utf8)) }
    func get(_ p: String) -> String { (try? String(contentsOfFile: p, encoding: .utf8)) ?? "" }
    func res(_ n: String) -> String { get(net + "/res/" + n).trimmingCharacters(in: .whitespacesAndNewlines) }
    func done(_ n: String, _ seconds: Double = 60) -> Bool { t.waitFor(seconds) { FileManager.default.fileExists(atPath: net + "/res/" + n) } }
    func freePort() -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var a = sockaddr_in()
        a.sin_family = sa_family_t(AF_INET); a.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        return Int(UInt16(bigEndian: a.sin_port))
    }
    let dozchat = (t.binary as NSString).deletingLastPathComponent + "/dozchat-mac"
    guard FileManager.default.isExecutableFile(atPath: dozchat) else {
        check(false, "dozchat-mac beside \(t.binary) (make cli builds it)")
        return
    }
    /// dozchat on THIS Mac, straight to the server (bot2's side of the conversation).
    func outside(_ file: String, _ args: [String], page: Int) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: dozchat)
        p.arguments = args
        p.environment = ["PATH": "/usr/bin:/bin", "CHAT_URL": "http://127.0.0.1:\(page)", "CHAT_TOKEN_FILE": file]
        let o = Pipe()
        p.standardOutput = o
        p.standardError = FileHandle.nullDevice
        try? p.run()
        let d = o.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: d, as: UTF8.self))
    }
    func items(_ s: String) -> [[String: Any]] {
        s.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }

    let page = freePort(), line = freePort()
    t.run(["config", "set", "chat.page_port", String(page)])
    t.run(["config", "set", "chat.line_port", String(line)])
    var r = t.run(["chat", "on", "--name", "ada"], timeout: 60)
    check(r.code == 0, "chat on (page port \(page)) (\(r.code) \(r.err.prefix(160)))")
    defer { t.run(["chat", "off"], timeout: 30) }
    let src = root + "/chat-src"
    try? FileManager.default.createDirectory(atPath: src, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    r = t.run(["chat", "add", "bot1", "--to-file", src + "/bot1.token"], timeout: 60)
    check(r.code == 0, "chat add bot1 --to-file (\(r.err.prefix(120)))")
    r = t.run(["chat", "add", "bot2", "--to-file", src + "/bot2.token"], timeout: 60)
    check(r.code == 0, "chat add bot2 --to-file (\(r.err.prefix(120)))")
    r = t.run(["chat", "room", "room1", "@bot1", "@bot2"], timeout: 30)
    check(r.code == 0, "chat room room1 @bot1 @bot2 (\(r.err.prefix(120)))")
    let token1 = get(src + "/bot1.token").trimmingCharacters(in: .whitespacesAndNewlines)
    // Each new participant is handed the protocol's announcement first: collected here.
    _ = outside(src + "/bot2.token", ["receive", "--ack"], page: page)
    var o = outside(src + "/bot2.token", ["send", "room1", "for bot1, from outside"], page: page)
    check(o.0 == 0, "bot2 (outside, direct) sends to room1 (\(o.0))")

    // MARK: a fenced session, wired with the two flags (and CHAT_URL: the page port is not 8790)
    put(net + "/chat.sh", helpers + """
    printf '%s' "$CHAT_TOKEN" > res/ch-var; cat "$CHAT_TOKEN_FILE" > res/ch-file; env > res/ch-env
    command -v dozchat > res/ch-which
    dozchat --version > res/ch-ver 2>&1
    dozchat rooms > res/ch-rooms 2> res/ch-rooms.err; echo $? > res/ch-rooms.rc
    dozchat send room1 "hello from a fenced session" > res/ch-send 2> res/ch-send.err; echo $? > res/ch-send.rc
    dozchat receive --wait 10 --ack > res/ch-recv 2> res/ch-recv.err; echo $? > res/ch-recv.rc
    echo done > res/CH0
    sleep 600
    """)
    let flags = ["--host-port", String(page), "-e", "CHAT_URL=http://\(HostRoute.hostName):\(page)",
                 "--secret", "CHAT_TOKEN,src=\(src)/bot1.token,to=\(HostRoute.hostName):\(page),file=CHAT_TOKEN_FILE"]
    r = t.run(["run", "@mac", "-d", "--fenced", "--session", "chat", "--folder", net] + flags + ["--", "/bin/sh", "chat.sh"], timeout: 90)
    if r.code == 0 { started.insert("chat") }
    check(r.code == 0, "a fenced session with --host-port and --secret for chat (\(r.code) \(r.err.suffix(200)))")
    check(done("CH0"), "the session's dozchat calls ran")
    check(res("ch-which").hasSuffix("/etc/bin/dozchat"), "dozchat is on its PATH: the session's shim (\(res("ch-which")))")
    check(res("ch-ver") == "dozchat \(ToolsLayer.dozchatVersion)", "dozchat --version (\(res("ch-ver")))")
    let placeholder = res("ch-var")
    check(placeholder.hasPrefix("doz_cred_") && placeholder != token1 && res("ch-file") == placeholder,
          "the session holds only the placeholder (its variable and its file)")
    check(res("ch-rooms.rc") == "0" && res("ch-rooms").contains("#room1"), "dozchat rooms from inside (\(res("ch-rooms.rc")) \(res("ch-rooms.err").prefix(200)))")
    check(res("ch-send.rc") == "0" && res("ch-send").contains("\"queued\""), "dozchat send room1 from inside (\(res("ch-send.rc")) \(res("ch-send.err").prefix(200)))")
    check(res("ch-recv.rc") == "0" && res("ch-recv").contains("for bot1, from outside"),
          "dozchat receive --ack from inside (\(res("ch-recv.rc")) \(res("ch-recv.err").prefix(200)))")
    o = outside(src + "/bot2.token", ["receive", "--wait", "10", "--ack"], page: page)
    let got = items(o.1).first { ($0["message"] as? [String: Any])?["content"] as? String == "hello from a fenced session" }
    let sender = got?["sender"] as? [String: Any]
    check(got?["from"] as? String == "bot1" && sender?["verified"] as? Bool == true,
          "the server saw the session's message from bot1, verified by its token (\(o.1.prefix(200)))")
    // Neither the token nor the proxy's password in anything dozchat printed.
    let env = res("ch-env")
    let proxyURL = env.split(separator: "\n").first { $0.hasPrefix("http_proxy=") }.map { String($0.dropFirst("http_proxy=".count)) } ?? ""
    let password = proxyURL.split(separator: "@").first.flatMap { $0.split(separator: ":").last }.map(String.init) ?? ""
    check(password.count >= 8, "the session's proxy has a password (\(password.count) characters)")
    let printed = ["ch-rooms", "ch-rooms.err", "ch-send", "ch-send.err", "ch-recv", "ch-recv.err", "ch-ver"].map { get(net + "/res/" + $0) }.joined()
    check(!printed.contains(token1) && !env.contains(token1), "no token in the session's environment or dozchat's output")
    check(!password.isEmpty && !printed.contains(password), "no proxy password in dozchat's output")

    // MARK: without --host-port the route refuses it (403 from the proxy: exit 4)
    put(net + "/chat2.sh", helpers + """
    dozchat receive > res/ch2 2> res/ch2.err; echo $? > res/ch2.rc
    echo done > res/CH2
    sleep 600
    """)
    r = t.run(["run", "@mac", "-d", "--fenced", "--session", "chat2", "--folder", net, "-e", "CHAT_URL=http://\(HostRoute.hostName):\(page)",
               "-e", "CHAT_TOKEN=not-a-real-token-0123456789", "--", "/bin/sh", "chat2.sh"], timeout: 90)
    if r.code == 0 { started.insert("chat2") }
    check(r.code == 0 && done("CH2") && res("ch2.rc") == "4" && res("ch2.err").contains("HTTP 403"),
          "without --host-port: the route refuses it, exit 4 (\(res("ch2.rc")) \(res("ch2.err").prefix(200)))")
    for s in ["chat", "chat2"] {
        t.run(["sessions", "end", "@mac", s, "--yes"], timeout: 60)
        t.run(["sessions", "end", "@mac", s, "--yes"], timeout: 60)
        started.remove(s)
    }
}
