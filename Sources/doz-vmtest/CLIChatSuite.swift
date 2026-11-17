// `doz-vmtest cli-chat --doz PATH` (`make test-cli-chat`): the chat server run by the daemon, end to end, no VM — a
// scratch store and settings of its own (/tmp/dzo-PID-ch), free ports the suite picks (`doz config set chat.*_port`),
// neutral names (ada, bot1, room1). The rows:
//
//   1. fresh: status says off, no daemon starts, no <store>/chat
//   2. on --name ada: ready; the server's parent is the daemon; 127.0.0.1 only (this Mac's LAN address is refused)
//   3. add bot1 --to-file: the file 0600; the token in no log, no file of the chat folder, no --json, no ps output
//   4. room, rooms, send; bot1 receives (/agent/receive) and answers (/agent/send); read shows both, no ids
//   5. GET /api/state on the page port is 403; the line port without a token is refused
//   6. kill -9 the server: it is restarted, restarts 1
//   7. a port in use: stopped with the line, no new server within 10 s, doctor FAIL; freed + on brings it back
//   8. off stops it and keeps the data; on brings the rooms back
//  14. token --new: the old token is refused     13. remove bot1: its token gets 401
//   9. daemon stop leaves no server running       10. kill -9 the daemon: the server exits within 2 s
//  11. always-on off, an idle timeout of 3 s: chat keeps the daemon up; off lets it exit
//  12. the program replaced by rename: the daemon restarts in place and a new server runs (its child)
//  15. add bot2 --webhook: who says webhook (not set); a message for it fails at once and reaches no one — a planted
//      data/secrets.json naming a webhook for it is ignored
//  16. webhook set (two lines on stdin): refused for a LAN http address, the shared name, an unknown entry, a file
//      others can read; then set: the server restarts, status shows scheme, host and port, never the path or header
//  17. a message for bot2 is delivered to the suite's listener with the Authorization value, as `delivered`
//  18. the sweep: the path, the secret and (for an unreachable host) the host appear in no log, no file of the store,
//      no --json but `webhook status`, no ps output sampled during the set and while serving; nothing in the chat
//      folder can be read by others; a failure's reason names no host
//  19. the child listens on exactly 127.0.0.1:page and 127.0.0.1:line (lsof)
//  20. webhook remove: who says not set; a message fails at once again
//
// Every daemon and server it starts is stopped at the end; the store is removed.
import Darwin
import Foundation
import DozableChat
import DozableKit
import DozableHost

func cliChatSuite(binary: String) async {
    print("cli: the chat server under the daemon")
    let fm = FileManager.default
    let root = URL(fileURLWithPath: "/tmp/dzo-\(getpid())-ch")
    try? fm.removeItem(at: root)
    try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    let h = CLIHarness(binary: binary, store: root)
    let store = DozableStore(root: root)
    let chat = root.appendingPathComponent("chat").path
    let paths = ChatPaths(store: store)

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
    func sh(_ argv: [String], stdin: Data? = nil) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: argv[0])
        p.arguments = Array(argv.dropFirst())
        let o = Pipe()
        p.standardOutput = o
        p.standardError = FileHandle.nullDevice
        try? p.run()
        let d = o.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: d, as: UTF8.self))
    }
    func parent(of pid: Int32) -> Int32? { Int32(sh(["/bin/ps", "-o", "ppid=", "-p", String(pid)]).1.trimmingCharacters(in: .whitespacesAndNewlines)) }
    func alive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }
    func server() -> Int32? {
        let s = ChatServer.status(dataDir: paths.data, release: "")
        return s.running ? Int32(s.pid) : nil
    }
    func supervisor() -> ChatServerState? { ChatServerState.load(paths) }
    /// Every chat server of this store (by its config path in its command line).
    func serversOfStore() -> [Int32] {
        sh(["/bin/ps", "-axo", "pid=,command="]).1.split(separator: "\n").compactMap { l in
            let t = l.trimmingCharacters(in: .whitespaces)
            guard t.contains("chat serve"), t.contains(paths.config) else { return nil }
            return Int32(t.split(separator: " ").first ?? "")
        }
    }
    func connects(_ host: String, _ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var a = sockaddr_in()
        a.sin_family = sa_family_t(AF_INET); a.sin_port = in_port_t(UInt16(port).bigEndian); a.sin_addr.s_addr = inet_addr(host)
        return withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } == 0
    }
    func lanAddress() -> String? {
        var ifs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifs) == 0 else { return nil }
        defer { freeifaddrs(ifs) }
        var p = ifs
        while let i = p {
            if let a = i.pointee.ifa_addr, a.pointee.sa_family == sa_family_t(AF_INET), (i.pointee.ifa_flags & UInt32(IFF_LOOPBACK)) == 0,
               (i.pointee.ifa_flags & UInt32(IFF_UP)) != 0 {
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                var sin = a.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                inet_ntop(AF_INET, &sin.sin_addr, &buf, socklen_t(buf.count))
                return String(cString: buf)
            }
            p = i.pointee.ifa_next
        }
        return nil
    }
    func curl(_ args: [String]) -> String { sh(["/usr/bin/curl", "-s", "-m", "15"] + args).1 }

    var daemons: Set<Int32> = []
    defer {
        h.run(["chat", "off"], timeout: 30)
        h.run(["daemon", "stop"], timeout: 60)
        _ = h.waitFor(20) { !h.hostRunning }
        for p in daemons where alive(p) { kill(p, SIGKILL) }
        for p in serversOfStore() { kill(p, SIGKILL) }
        check(serversOfStore().isEmpty && !h.hostRunning, "chat: no daemon or chat server of this suite left running")
        try? fm.removeItem(at: root)
    }

    let page = freePort(), line = freePort()
    h.run(["config", "set", "chat.page_port", String(page)])
    h.run(["config", "set", "chat.line_port", String(line)])

    // 1. fresh
    var r = h.run(["chat", "status"])
    check(r.code == 0 && r.out.hasPrefix("chat: off"), "1 status says off (\(r.out.split(separator: "\n").first ?? ""))")
    check(!h.hostRunning, "1 …and no daemon started")
    check(!fm.fileExists(atPath: chat), "1 …and no chat folder in the store")
    r = h.run(["--help"])
    check(!r.out.contains("  chat "), "the chat group is hidden from doz --help")
    r = h.run(["chat", "--help"])
    check(r.code == 0 && ["on", "off", "status", "add", "remove", "who", "token", "rooms", "room", "send", "read"].allSatisfy { r.out.contains("  \($0)") },
          "doz chat --help lists every command")

    // 2. on
    r = h.run(["chat", "on", "--name", "ada"], timeout: 60)
    check(r.code == 0 && r.out == "Chat is on: 127.0.0.1, page port \(page), line port \(line). You are ada.\n", "2 on --name ada (\(r.out.trimmingCharacters(in: .newlines)))")
    if let d = h.hostPID() { daemons.insert(d) }
    guard let s1 = server() else { check(false, "2 a chat server runs"); return }
    check(parent(of: s1) == h.hostPID(), "2 the chat server's parent is the daemon (\(parent(of: s1).map(String.init) ?? "?"))")
    r = h.run(["chat", "status"])
    check(r.out.hasPrefix("chat: on — running and ready") && r.out.contains("you are ada"), "2 status: running and ready, you are ada")
    check(connects("127.0.0.1", page) && connects("127.0.0.1", line), "2 it listens on 127.0.0.1")
    if let lan = lanAddress() {
        check(!connects(lan, page) && !connects(lan, line), "2 …and not on this Mac's LAN address \(lan)")
    } else { info("no LAN address on this Mac: the LAN connect is not tried") }
    var st = stat()
    check(lstat(chat, &st) == 0 && st.st_mode & 0o777 == 0o700, "2 the chat folder is 0700")
    check(lstat(paths.socket, &st) == 0 && st.st_mode & 0o777 == 0o600, "2 the owner's socket is 0600")

    // 3. add, the token kept nowhere
    let tokenFile = root.appendingPathComponent("bot1.token").path
    r = h.run(["chat", "add", "bot1"])
    check(r.code == 64, "3 add with no terminal and no --to-file is refused (\(r.code))")
    r = h.run(["chat", "add", "bot1", "--to-file", tokenFile, "--json"], timeout: 60)
    let token = ((try? String(contentsOfFile: tokenFile, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    check(r.code == 0 && token.hasPrefix("dzc_") && token.count == 47, "3 add bot1 --to-file (\(r.code))")
    check(lstat(tokenFile, &st) == 0 && st.st_mode & 0o777 == 0o600, "3 the token file is 0600")
    check(!r.out.contains(token) && r.out.contains("tokenFile"), "3 --json names the file, not the token")
    r = h.run(["chat", "add", "bot1", "--to-file", tokenFile + "2"])
    check(r.code == 4 && !fm.fileExists(atPath: tokenFile + "2"), "3 add bot1 again: exit 4, no file left (\(r.code))")
    var leaks: [String] = []
    for f in (try? fm.subpathsOfDirectory(atPath: chat)) ?? [] where (try? String(contentsOfFile: chat + "/" + f, encoding: .utf8))?.contains(token) == true { leaks.append(f) }
    for (n, text) in [("daemon.log", (try? String(contentsOf: store.logFile, encoding: .utf8)) ?? ""),
                      ("chat status --json", h.run(["chat", "status", "--json"]).out), ("daemon status --json", h.run(["daemon", "status", "--json"]).out),
                      ("ps -axww", sh(["/bin/ps", "-axww", "-o", "command="]).1)] where text.contains(token) { leaks.append(n) }
    check(leaks.isEmpty, "3 the token is in no log, no file of the chat folder (server.log included), no --json, no ps output\(leaks.isEmpty ? "" : ": " + leaks.joined(separator: ", "))")

    // 4. a room, a message each way
    r = h.run(["chat", "room", "room1", "@bot1"])
    check(r.code == 0 && r.out == "Made room1 with ada, bot1.\n", "4 room room1 @bot1 (\(r.out.trimmingCharacters(in: .newlines)))")
    r = h.run(["chat", "rooms"])
    check(r.out.contains("room1 — ada, bot1"), "4 rooms: room1 — ada, bot1")
    r = h.run(["chat", "room", "room1"])
    check(r.code == 4, "4 room room1 again: exit 4 (\(r.code))")
    r = h.run(["chat", "room", "room2", "@bot9"])
    check(r.code == 2, "4 a room with an unknown member: exit 2 (\(r.code))")
    r = h.run(["chat", "send", "room1", "hello @bot1"])
    check(r.code == 0 && r.out == "Sent to room1 — bot1: waiting.\n", "4 send (\(r.out.trimmingCharacters(in: .newlines)))")
    r = h.run(["chat", "send", "nosuch", "x"])
    check(r.code == 2, "4 send to no such room: exit 2 (\(r.code))")
    let got = curl(["-H", "Authorization: Bearer \(token)", "http://127.0.0.1:\(page)/agent/receive?wait=10"])
    check(got.contains("hello @bot1"), "4 bot1 receives it with GET /agent/receive")
    let sent = curl(["-H", "Authorization: Bearer \(token)", "-H", "Content-Type: application/json",
                     "-d", #"{"room":"room1","message":{"content":"hi ada"}}"#, "http://127.0.0.1:\(page)/agent/send"])
    check(sent.contains("\"state\":\"queued\""), "4 bot1 answers with POST /agent/send (\(sent.prefix(100)))")
    r = h.run(["chat", "read", "room1"])
    check(r.out.contains("ada: hello @bot1") && r.out.contains("bot1: hi ada"), "4 read shows both")
    check(r.out.range(of: "[0-9a-f]{8}-[0-9a-f]{4}", options: .regularExpression) == nil, "4 …with no ids")
    r = h.run(["chat", "who"])
    check(r.out.contains("bot1") && r.out.contains("agent"), "4 who lists bot1")

    // 5. nothing on the network acts as you
    check(curl(["-o", "/dev/null", "-w", "%{http_code}", "http://127.0.0.1:\(page)/api/state"]) == "403", "5 GET /api/state on the page port is 403")
    let lineAnswer = sh(["/bin/sh", "-c", "printf '%s\\n' '{\"type\":\"user\",\"room\":\"room1\",\"msg_id\":\"\(UUID().uuidString.lowercased())\",\"message\":{\"content\":\"x\"}}' | /usr/bin/nc -w 3 127.0.0.1 \(line)"]).1
    check(!lineAnswer.contains("\"queued\""), "5 the line port refuses a message without a token (\(lineAnswer.prefix(120)))")

    // 15–21. a webhook bot (its entry in the daemon's keychain seam — the memory one here — handed over on a pipe)
    await cliChatWebhookRows(h: h, root: root, paths: paths, page: page, line: line, sh: sh, server: server, supervisor: supervisor)

    // 6. a killed server comes back
    guard let s6 = server() else { check(false, "6 a chat server runs"); return }      // `add` restarted the first one
    kill(s6, SIGKILL)
    let back = h.waitFor(15) { server().map { $0 != s6 } == true && supervisor()?.ready == true }
    check(back && supervisor()?.restarts == 1, "6 kill -9 the server: restarted, restarts \(supervisor()?.restarts ?? -1)")

    // 7. a port in use
    r = h.run(["chat", "off"], timeout: 30)
    let blocker = socket(AF_INET, SOCK_STREAM, 0)
    var on: Int32 = 1
    setsockopt(blocker, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
    var ba = sockaddr_in()
    ba.sin_family = sa_family_t(AF_INET); ba.sin_port = in_port_t(UInt16(line).bigEndian); ba.sin_addr.s_addr = inet_addr("127.0.0.1")
    let held = withUnsafePointer(to: &ba) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(blocker, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } == 0
    listen(blocker, 4)
    r = h.run(["chat", "on"], timeout: 60)
    check(held && r.code == 1 && r.err.contains("line port \(line) is in use by another program — doz config set chat.line_port N"),
          "7 a port in use: on fails with the setting to change (\(r.err.trimmingCharacters(in: .newlines).suffix(160)))")
    let restarts7 = supervisor()?.restarts
    usleep(10_000_000)
    check(supervisor()?.state == "stopped" && server() == nil && supervisor()?.restarts == restarts7, "7 …stopped, no new server within 10 s")
    r = h.run(["doctor"], timeout: 120)
    check(r.out.split(separator: "\n").contains { $0.hasPrefix("FAIL") && $0.contains("chat") }, "7 doctor: chat FAIL")
    close(blocker)
    r = h.run(["chat", "on"], timeout: 60)
    check(r.code == 0 && server() != nil, "7 the port freed, on brings it back")

    // 8. off keeps the data
    let before = server()
    r = h.run(["chat", "off"], timeout: 30)
    check(r.code == 0 && r.out == "Chat is off. Rooms and messages are kept.\n" && before.map { !alive($0) } == true && server() == nil, "8 off stops the server")
    check(fm.fileExists(atPath: paths.data + "/rooms/room1.db"), "8 …and keeps the data")
    r = h.run(["chat", "rooms"])
    check(r.code == 6, "8 rooms while off: exit 6 (\(r.code))")
    r = h.run(["chat", "on"], timeout: 60)
    r = h.run(["chat", "read", "room1"])
    check(r.out.contains("bot1: hi ada"), "8 on brings the rooms and messages back")

    // 14 and 13. tokens
    let tf2 = tokenFile + ".new"
    r = h.run(["chat", "token", "bot1", "--new", "--to-file", tf2], timeout: 60)
    let token2 = ((try? String(contentsOfFile: tf2, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    func code(_ t: String) -> String { curl(["-o", "/dev/null", "-w", "%{http_code}", "-H", "Authorization: Bearer \(t)", "http://127.0.0.1:\(page)/agent/receive"]) }
    check(r.code == 0 && code(token) == "401" && code(token2) == "200", "14 token --new: the old token is refused, the new one works")
    r = h.run(["chat", "token", "bot1", "--from-stdin"], stdin: Data("bot1-own-token-0123456789\n".utf8), timeout: 60)
    check(r.code == 0 && code("bot1-own-token-0123456789") == "200" && code(token2) == "401", "14 token --from-stdin: the given one is used")
    r = h.run(["chat", "remove", "bot1"], timeout: 60)
    check(r.code == 0 && r.out == "Removed bot1.\n" && code("bot1-own-token-0123456789") == "401", "13 remove bot1: its token gets 401")
    check(!h.run(["chat", "rooms"]).out.contains("bot1"), "13 …and it left every room")
    r = h.run(["chat", "remove", "bot1"])
    check(r.code == 2, "13 remove it again: exit 2 (\(r.code))")

    // 9. daemon stop
    let s9 = server()
    r = h.run(["daemon", "stop"], timeout: 60)
    check(r.code == 0 && s9.map { !alive($0) } == true && serversOfStore().isEmpty, "9 daemon stop leaves no chat server")

    // 10. kill -9 the daemon
    r = h.run(["chat", "on"], timeout: 60)
    guard let d10 = h.hostPID(), let s10 = server() else { check(false, "10 a daemon and a server run again"); return }
    daemons.insert(d10)
    kill(d10, SIGKILL)
    let t10 = Date()
    let gone = h.waitFor(2.5) { !alive(s10) }
    check(gone, String(format: "10 kill -9 the daemon: the server exited in %.1f s", Date().timeIntervalSince(t10)))
    if !gone { kill(s10, SIGKILL) }

    // 11. chat keeps an idle daemon up
    let idle = CLIHarness(binary: binary, store: root)
    idle.env = h.env
    idle.env["DOZ_DAEMON_ALWAYS_ON"] = "off"
    idle.env["DOZ_DAEMON_IDLE"] = "0.05"                                 // 3 s
    r = idle.run(["daemon", "start"], timeout: 60)
    let d11 = idle.hostPID()
    if let d11 { daemons.insert(d11) }
    _ = idle.waitFor(15) { server() != nil && supervisor()?.ready == true }
    usleep(12_000_000)
    check(d11.map(alive) == true && idle.hostRunning, "11 always-on off, idle timeout 3 s: chat keeps the daemon up 12 s")
    r = idle.run(["chat", "off"], timeout: 30)
    check(idle.waitFor(30) { !idle.hostRunning }, "11 off lets it exit")
    check(serversOfStore().isEmpty, "11 …with no chat server left")

    // 12. the program replaced by rename
    let src = URL(fileURLWithPath: binary).deletingLastPathComponent()
    let copies = root.appendingPathComponent("installed")
    try? fm.createDirectory(at: copies, withIntermediateDirectories: true)
    for item in (try? fm.contentsOfDirectory(atPath: src.path)) ?? [] where item.hasSuffix(".bundle") || item == "VERSION" || item == "deckhold-mac" {
        try? fm.copyItem(at: src.appendingPathComponent(item), to: copies.appendingPathComponent(item))
    }
    let t = copies.appendingPathComponent("doz").path
    let entitlements = URL(fileURLWithPath: "Scripts/doz.entitlements").standardizedFileURL.path
    func install() -> Bool {
        sh(["/bin/cp", binary, t + ".new"]).0 == 0 && sh(["/usr/bin/codesign", "--force", "--sign", "-", "--entitlements", entitlements, t + ".new"]).0 == 0
            && rename(t + ".new", t) == 0
    }
    check(install(), "12 an installed copy of this build")
    let inst = CLIHarness(binary: t, store: root)
    inst.env = h.env                                                      // always-on off (the Makefile's): chat alone keeps it
    r = inst.run(["chat", "on"], timeout: 60)
    guard let d12 = inst.hostPID(), let s12 = server() else { check(false, "12 a daemon from the copy runs chat"); return }
    daemons.insert(d12)
    usleep(1_000_000)
    check(install(), "12 a new build renamed over its program")
    let moved = h.waitFor(60) {
        guard let d = (try? String(contentsOf: store.pidFile, encoding: .utf8)).flatMap({ Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }),
              d != d12, alive(d), let s = server(), s != s12 else { return false }
        return supervisor()?.ready == true && parent(of: s) == d
    }
    if let d = h.hostPID() { daemons.insert(d) }
    check(moved && !alive(d12) && !alive(s12), "12 the daemon restarted in place with no command; a new chat server runs, its child")
    check(serversOfStore().count == 1, "12 one chat server (\(serversOfStore()))")
}


/// Every process's command line, as `ps -axww -o args=` prints it.
func psArgs() -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/ps")
    p.arguments = ["-axww", "-o", "args="]
    let o = Pipe()
    p.standardOutput = o
    p.standardError = FileHandle.nullDevice
    try? p.run()
    let d = o.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: d, as: UTF8.self)
}

/// A plain HTTP listener on 127.0.0.1 the suite starts: it records each request's first line and its Authorization header
/// and answers 200.
final class SuiteHook: @unchecked Sendable {
    let port: Int
    private let fd: Int32
    private let lock = NSLock()
    private var got: [(line: String, auth: String)] = []
    private var stopped = false

    init?() {
        let s = socket(AF_INET, SOCK_STREAM, 0)
        var on: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        var a = sockaddr_in()
        a.sin_family = sa_family_t(AF_INET); a.sin_addr.s_addr = inet_addr("127.0.0.1")
        guard withUnsafePointer(to: &a, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }) == 0,
              listen(s, 16) == 0 else { close(s); return nil }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(s, $0, &len) } }
        fd = s
        port = Int(UInt16(bigEndian: a.sin_port))
        Thread.detachNewThread { [self] in self.serve() }
    }

    var requests: [(line: String, auth: String)] { lock.withLock { got } }

    func stop() { lock.withLock { stopped = true }; shutdown(fd, SHUT_RDWR); close(fd) }

    private func serve() {
        while true {
            let c = accept(fd, nil, nil)
            if c < 0 { if lock.withLock({ stopped }) { return }; continue }
            var data = [UInt8]()
            var buf = [UInt8](repeating: 0, count: 65536)
            var tv = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            while true {
                let n = read(c, &buf, buf.count)
                if n <= 0 { break }
                data += buf[0..<n]
                let text = String(decoding: data, as: UTF8.self)
                guard let end = text.range(of: "\r\n\r\n") else { continue }
                let head = String(text[..<end.lowerBound])
                let length = head.split(separator: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
                    .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
                if text.utf8.count - text[..<end.upperBound].utf8.count >= length { break }
            }
            let head = String(decoding: data, as: UTF8.self).components(separatedBy: "\r\n\r\n").first ?? ""
            let lines = head.components(separatedBy: "\r\n")
            let auth = lines.first { $0.lowercased().hasPrefix("authorization:") }.map { String($0.dropFirst("authorization:".count)).trimmingCharacters(in: .whitespaces) } ?? ""
            lock.withLock { got.append((lines.first ?? "", auth)) }
            let answer = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
            _ = answer.withCString { write(c, $0, strlen($0)) }
            close(c)
        }
    }
}

func cliChatWebhookRows(h: CLIHarness, root: URL, paths: ChatPaths, page: Int, line: Int, sh: (_ argv: [String], _ stdin: Data?) -> (Int32, String),
                        server: () -> Int32?, supervisor: () -> ChatServerState?) async {
    let fm = FileManager.default
    guard h.env["DOZ_TEST_CREDENTIALS"] == "memory" || ProcessInfo.processInfo.environment["DOZ_TEST_CREDENTIALS"] == "memory" else {
        check(false, "15 the webhook rows need the memory keychain seam (DOZ_TEST_CREDENTIALS=memory): not run")
        return
    }
    guard let hook = SuiteHook() else { check(false, "15 a listener for the webhook"); return }
    defer { hook.stop() }
    let rand = { UUID().uuidString.prefix(8).lowercased() }
    let pathSentinel = "p-\(rand())", secret = "s-\(rand())\(rand())", lostHost = "h-\(rand()).invalid"
    let hookURL = "http://localhost:\(hook.port)/\(pathSentinel)"
    var outputs: [String: String] = [:]          // every --json and status output, swept at the end
    final class Samples: @unchecked Sendable { var text = ""; var running = true; let lock = NSLock() }
    let samples = Samples()

    // 15. add bot2 --webhook
    let tf = root.appendingPathComponent("bot2.token").path
    var r = h.run(["chat", "add", "bot2", "--kind", "grok-bot", "--webhook", "--to-file", tf, "--json"], timeout: 60)
    outputs["add --json"] = r.out
    check(r.code == 0 && r.out.contains("\"webhookEntry\" : \"bot2\"") || r.out.contains("\"webhookEntry\":\"bot2\""), "15 add bot2 --kind grok-bot --webhook (\(r.code))")
    r = h.run(["chat", "who"])
    check(r.out.split(separator: "\n").contains { $0.contains("bot2") && $0.contains("grok-bot") && $0.contains("webhook (not set)") }, "15 who: bot2 grok-bot webhook (not set)")
    r = h.run(["chat", "status"])
    check(r.out.contains("warning: no webhook entry bot2"), "15 status warns: no webhook entry bot2")
    // A planted secrets.json in the data folder naming a webhook for bot2 (to the suite's listener) is never read.
    let planted = #"{"version":1,"tokens":{},"webhooks":{"bot2":{"url":"http://127.0.0.1:\#(hook.port)/planted","header":"Bearer planted-0123456789"},"default":{"url":"http://127.0.0.1:\#(hook.port)/planted","header":""}}}"#
    FileManager.default.createFile(atPath: paths.data + "/secrets.json", contents: Data(planted.utf8), attributes: [.posixPermissions: 0o600])
    _ = h.run(["chat", "off"], timeout: 30); _ = h.run(["chat", "on"], timeout: 60)
    _ = h.run(["chat", "room", "room3", "@bot2"])
    r = h.run(["chat", "send", "room3", "first @bot2"])
    let firstFailed = h.waitFor(5) { h.run(["chat", "read", "room3", "--json"]).out.contains("\"failed\"") }
    check(firstFailed && hook.requests.isEmpty, "15 no entry: a message for bot2 fails at once, and the planted secrets.json is ignored (no call: \(hook.requests.count))")

    // 16. webhook set — the refusals first
    func set(_ entry: String, _ input: String, file: String? = nil) -> CLIRun {
        var args = ["chat", "webhook", "set", entry]
        if let file { args += ["--from-file", file] }
        return h.run(args, stdin: file == nil ? Data(input.utf8) : nil, timeout: 60)
    }
    r = set("bot2", "http://192.168.1.5:9000/\(pathSentinel)\nBearer \(secret)\n")
    check(r.code != 0 && r.err.contains("plain http") && !r.err.contains(pathSentinel), "16 a LAN http address is refused (\(r.code))")
    r = set("default", "https://bot.example/x\n\n")
    check(r.code != 0, "16 the shared name default is refused (\(r.code))")
    r = set("nobody", "https://bot.example/x\n\n")
    check(r.code == 2, "16 an entry no webhook bot uses: exit 2 (\(r.code))")
    r = set("bot2", "https://bot.example/x\nBearer a\nthird line\n")
    check(r.code != 0, "16 a third line is refused (\(r.code))")
    let wide = root.appendingPathComponent("hook-wide").path
    fm.createFile(atPath: wide, contents: Data("\(hookURL)\nBearer \(secret)\n".utf8), attributes: [.posixPermissions: 0o644])
    r = set("bot2", "", file: wide)
    check(r.code != 0 && r.err.contains("chmod go="), "16 --from-file that others can read is refused (\(r.code))")
    try? fm.removeItem(atPath: wide)
    // the set itself, with ps sampled while it runs
    let before = server()
    let sampler = Thread {
        while samples.lock.withLock({ samples.running }) {
            let o = psArgs()
            samples.lock.withLock { samples.text += o }
            usleep(50_000)
        }
    }
    sampler.start()
    r = set("bot2", "\(hookURL)\nBearer \(secret)\n")
    samples.lock.withLock { samples.running = false }
    usleep(100_000)
    check(r.code == 0 && r.out.hasPrefix("Set the webhook entry bot2: set — http://localhost:\(hook.port), fingerprint "), "16 webhook set bot2 (\(r.out.trimmingCharacters(in: .newlines)))")
    check(server() != nil && server() != before && supervisor()?.ready == true, "16 …the server restarted to take it")
    r = h.run(["chat", "webhook", "status", "bot2"])
    outputs["webhook status"] = r.out
    check(r.out.hasPrefix("bot2: set — http://localhost:\(hook.port), fingerprint ") && r.out.contains("(for bot2)"), "16 webhook status: scheme, host, port (\(r.out.trimmingCharacters(in: .newlines)))")
    r = h.run(["chat", "webhook", "status", "--json"])
    outputs["webhook status --json"] = r.out
    check(r.code == 0 && r.out.contains("\"host\"") && r.out.contains("localhost"), "16 webhook status --json has the host")
    r = h.run(["chat", "who"])
    check(r.out.split(separator: "\n").contains { $0.contains("bot2") && $0.contains("webhook (set)") }, "16 who: webhook (set)")

    // 17. delivered with the Authorization value
    let n0 = hook.requests.count
    r = h.run(["chat", "send", "room3", "hello @bot2"])
    let delivered = h.waitFor(10) { hook.requests.count > n0 }
    let req = hook.requests.last
    check(delivered && req?.line.hasPrefix("POST /\(pathSentinel) ") == true && req?.auth == "Bearer \(secret)", "17 a message for bot2 reaches its webhook with its Authorization value")
    check(h.waitFor(5) { h.run(["chat", "read", "room3", "--json"]).out.contains("\"delivered\"") }, "17 …and is marked delivered")
    // the sample while serving
    samples.lock.withLock { samples.text += psArgs() }
    let psSamples = samples.lock.withLock { samples.text }

    // a second bot whose host cannot be reached: the host is shown by `webhook status` and nowhere else
    let tf3 = root.appendingPathComponent("bot3.token").path
    r = h.run(["chat", "add", "bot3", "--kind", "grok-bot", "--webhook", "--to-file", tf3], timeout: 60)
    let f3 = root.appendingPathComponent("hook3").path
    fm.createFile(atPath: f3, contents: Data("https://\(lostHost)/\(pathSentinel)\nBearer \(secret)\n".utf8), attributes: [.posixPermissions: 0o600])
    r = set("bot3", "", file: f3)
    try? fm.removeItem(atPath: f3)
    check(r.code == 0 && r.out.contains(lostHost), "18 webhook set bot3 --from-file (mode 600) (\(r.code))")
    _ = h.run(["chat", "send", "room1", "/invite @bot3"])
    r = h.run(["chat", "send", "room1", "x @bot3"])
    let failed3 = h.waitFor(40) { h.run(["chat", "read", "room1", "--json"]).out.contains("could not reach the webhook") }
    let readOut = h.run(["chat", "read", "room1", "--json"]).out
    check(failed3 && !readOut.contains(lostHost), "18 bot3's unreachable host fails with a reason that names no host")

    // 18. the sweep
    for (n, args) in [("chat status --json", ["chat", "status", "--json"]), ("daemon status --json", ["daemon", "status", "--json"]),
                      ("who --json", ["chat", "who", "--json"]), ("doctor --json", ["doctor", "--json"])] {
        outputs[n] = h.run(args, timeout: 120).out
    }
    var leaks: [String] = []
    for (n, text) in outputs {
        if text.contains(pathSentinel) || text.contains(secret) { leaks.append(n + " (path or secret)") }
        if !n.hasPrefix("webhook status") && text.contains(lostHost) { leaks.append(n + " (host)") }
    }
    if psSamples.contains(pathSentinel) || psSamples.contains(secret) || psSamples.contains(lostHost) { leaks.append("ps output") }
    check(!psSamples.isEmpty, "18 ps was sampled during the set and while serving")
    for f in (try? fm.subpathsOfDirectory(atPath: root.path)) ?? [] {
        guard let d = fm.contents(atPath: root.path + "/" + f) else { continue }
        let text = String(decoding: d, as: UTF8.self)
        if text.contains(pathSentinel) || text.contains(secret) || text.contains(lostHost) { leaks.append(f) }
    }
    check(leaks.isEmpty, "18 the path, the secret and the host are in no log (server.log, daemon.log), no file of the store, no --json, no ps output\(leaks.isEmpty ? "" : ": " + leaks.joined(separator: ", "))")
    let open = sh(["/usr/bin/find", paths.folder, "-perm", "+044"], nil).1.trimmingCharacters(in: .whitespacesAndNewlines)
    check(open.isEmpty, "18 nothing in the chat folder can be read by others\(open.isEmpty ? "" : ": " + open)")

    // 19. exactly the two listeners on 127.0.0.1
    if let s = server() {
        let ls = sh(["/usr/sbin/lsof", "-nP", "-a", "-p", String(s), "-iTCP", "-sTCP:LISTEN", "-Fn"], nil).1
        let names = Set(ls.split(separator: "\n").filter { $0.hasPrefix("n") }.map { String($0.dropFirst()) })
        check(names == ["127.0.0.1:\(page)", "127.0.0.1:\(line)"], "19 the chat server listens on exactly 127.0.0.1:\(page) and :\(line) (\(names.sorted()))")
    } else { check(false, "19 a chat server runs") }

    // 20. remove
    r = h.run(["chat", "webhook", "remove", "bot2"], timeout: 60)
    check(r.code == 0 && r.out.contains("Messages for bot2 fail at once"), "20 webhook remove bot2 (\(r.out.trimmingCharacters(in: .newlines)))")
    r = h.run(["chat", "who"])
    check(r.out.split(separator: "\n").contains { $0.contains("bot2") && $0.contains("webhook (not set)") }, "20 who: webhook (not set) again")
    let n1 = hook.requests.count
    _ = h.run(["chat", "send", "room3", "again @bot2"])
    usleep(1_500_000)
    check(hook.requests.count == n1, "20 …and a message for bot2 reaches no one")
    _ = h.run(["chat", "remove", "bot3"], timeout: 60)
    _ = h.run(["chat", "webhook", "remove", "bot3"], timeout: 60)
    try? fm.removeItem(atPath: paths.data + "/secrets.json")
}
