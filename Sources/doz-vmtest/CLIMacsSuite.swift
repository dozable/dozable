import Darwin
import Foundation
import DozableHost

// `make test-cli-macs` (`doz-vmtest cli-macs --doz PATH`): Your Macs through the real signed doz — no VM, no other Mac, no
// internet. Two scratch stores (/tmp/dzo-PID-macs-a and -b), each with its own settings; store B runs a `doz ui` named
// `mini` (DOZ_TEST_MAC_NAME) on a port the system chose (checked not to be a live one), standing in for another Mac. A
// non-Dozable page is a listener in this process, also on an OS-chosen port. Every process it stops is one it started.
//
//   1. ui macs ls with nothing and no daemon: answered, none starts
//   2. add mini http://127.0.0.1:P2 (B's dashboard): it answered; ls --json: reachable, reportedName mini, lastSeenAt
//   3. add router 127.0.0.1:P3 (a page that is not Dozable): kept, not-dozable
//   4. refusals — a sign-in link, a query, a path, a login, a bad name, a name taken, an address taken, this Mac's own
//      dashboard: each refused, its secret never echoed, macs.json unchanged byte for byte
//   5. B's dashboard stopped; check mini: refused or timeout, lastSeenAt kept
//   6. add air 127.0.0.1:<closed> --no-check: never checked
//   7. macs.json: 0600, no `cap=`, `code=` or token-shaped run, only the keys this build writes
//   8. rm air: gone; rm nobody: refused, unchanged
//   9. ls with the daemon stopped starts none; with a daemon running, macs-ls answers the same list
func cliMacsSuite(binary: String) async {
    print("cli: Your Macs — no VM")
    let fm = FileManager.default
    let rootA = URL(fileURLWithPath: "/tmp/dzo-\(getpid())-macs-a"), rootB = URL(fileURLWithPath: "/tmp/dzo-\(getpid())-macs-b")
    for u in [rootA, rootB] { try? fm.removeItem(at: u); try? fm.createDirectory(at: u, withIntermediateDirectories: true) }
    let a = CLIHarness(binary: binary, store: rootA), b = CLIHarness(binary: binary, store: rootB)
    b.env["DOZ_TEST_MAC_NAME"] = "mini"
    for h in [a, b] {
        h.env["DOZ_TEST_MODEL_LIST"] = "offline"
        h.env["DO_NOT_TRACK"] = "1"
    }
    let live: Set<Int> = [7443, 8765, 8766, 8780, 8782, 8790, 8890, 8891, 8443]
    let macs = MacBookmarkStore(store: DozableStore(root: rootA))

    func freePort() -> Int {
        for _ in 0..<20 {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            var s = sockaddr_in()
            s.sin_family = sa_family_t(AF_INET); s.sin_addr.s_addr = inet_addr("127.0.0.1")
            _ = withUnsafePointer(to: &s) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &s) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
            close(fd)
            let p = Int(UInt16(bigEndian: s.sin_port))
            if p > 1023, !live.contains(p) { return p }
        }
        return 0
    }
    func sha(_ path: String) -> String { (try? Data(contentsOf: URL(fileURLWithPath: path))).map(WorkspaceStore.sha256) ?? "none" }
    func mode(_ p: String) -> mode_t { var st = stat(); return lstat(p, &st) == 0 ? st.st_mode & 0o777 : 0 }
    func answers(_ port: Int) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        p.arguments = ["-s", "-m", "3", "-o", "/dev/null", "-w", "%{http_code}", "http://127.0.0.1:\(port)/"]
        let o = Pipe()
        p.standardOutput = o
        p.standardError = FileHandle.nullDevice
        try? p.run()
        let d = o.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: d, as: UTF8.self) == "200"
    }
    func list() -> [MacRow] { a.json(["ui", "macs", "ls"], MacListing.self)?.macs ?? [] }

    // A page that is not Dozable, on an OS-chosen port of this process.
    let other = socket(AF_INET, SOCK_STREAM, 0)
    var sa = sockaddr_in()
    sa.sin_family = sa_family_t(AF_INET); sa.sin_addr.s_addr = inet_addr("127.0.0.1")
    _ = withUnsafePointer(to: &sa) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(other, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    listen(other, 8)
    var slen = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &sa) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(other, $0, &slen) } }
    let otherPort = Int(UInt16(bigEndian: sa.sin_port))
    Thread.detachNewThread {
        while true {
            let c = accept(other, nil, nil)
            if c < 0 { return }
            var buf = [UInt8](repeating: 0, count: 4096)
            _ = read(c, &buf, buf.count)
            let body = "<html><head><title>Router admin</title></head></html>"
            let reply = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            _ = reply.withCString { write(c, $0, strlen($0)) }
            close(c)
        }
    }

    defer {
        b.run(["ui", "stop"], timeout: 30)
        for h in [a, b] { h.run(["daemon", "stop"], timeout: 60) }
        shutdown(other, SHUT_RDWR); close(other)
        check(!a.hostRunning && !b.hostRunning, "macs: no daemon of this suite left running")
        for u in [rootA, rootB] { try? fm.removeItem(at: u) }
    }

    // 1. nothing yet, no daemon
    var r = a.run(["ui", "macs", "ls"])
    check(r.code == 0 && r.out.contains("Your Macs: none yet"), "1 ui macs ls with nothing: answered (\(r.code))")
    check(!a.hostRunning, "1 …and no daemon started")
    r = a.run(["ui", "macs", "--help"])
    check(["ls", "add", "rm", "check"].allSatisfy { r.out.contains("  \($0)") }, "1 doz ui macs --help lists every command")

    // 2. another Mac's dashboard: store B's doz ui, named mini, on an OS-chosen port
    let p2 = freePort()
    check(p2 > 1023 && !live.contains(p2), "2 the other dashboard's port is the system's choice, not a live one (\(p2))")
    b.run(["config", "set", "ui.port", String(p2)])
    r = b.run(["ui", "--detach", "--no-open"], timeout: 60)
    check(r.code == 0 && b.waitFor(20) { answers(p2) }, "2 the other dashboard (mini) answers on 127.0.0.1:\(p2) (\(r.code))")
    r = a.run(["ui", "macs", "add", "mini", "http://127.0.0.1:\(p2)"], timeout: 30)
    check(r.code == 0 && r.out.contains("Added mini: http://127.0.0.1:\(p2)") && r.out.contains("it answered")
          && r.out.contains("sign in there: run `doz ui share` on that Mac"), "2 add mini: checked, it answered (\(r.code): \(r.out.prefix(200)))")
    var mini = list().first { $0.name == "mini" }
    check(mini?.lastResult == "reachable" && mini?.reportedName == "mini" && mini?.lastSeenAt != nil && mini?.origin == "http://127.0.0.1:\(p2)",
          "2 ls --json: mini reachable, reportedName mini, lastSeenAt set")
    let seenAt = mini?.lastSeenAt
    r = a.run(["ui", "macs", "ls"])
    check(r.out.contains("mini") && r.out.contains("http://127.0.0.1:\(p2) (plain HTTP)") && r.out.contains("answered"), "2 ls: mini, its address marked plain HTTP")

    // 3. a page that is not Dozable
    r = a.run(["ui", "macs", "add", "router", "127.0.0.1:\(otherPort)"], timeout: 30)
    check(r.code == 0 && r.out.contains("not a Dozable dashboard"), "3 add router: kept, said not a Dozable dashboard (\(r.code))")
    check(list().first { $0.name == "router" }?.lastResult == "not-dozable" && list().first { $0.name == "router" }?.lastSeenAt == nil,
          "3 ls --json: router not-dozable, never seen")

    // 4. refusals leave macs.json as it was, and never repeat what was typed
    let secret = "q7secretq7secretq7secretq7secret"
    let p4 = freePort()
    a.run(["config", "set", "ui.port", String(p4)])
    let before = sha(macs.file)
    let refusals: [(String, [String], Int32?)] = [
        ("a sign-in link", ["ui", "macs", "add", "x", "http://127.0.0.1:\(p2)/#cap=\(secret)"], 64),
        ("a code", ["ui", "macs", "add", "x", "http://127.0.0.1:\(p2)/?code=\(secret)"], 64),
        ("a query", ["ui", "macs", "add", "x", "http://127.0.0.1:\(p2)/?q=\(secret)"], 64),
        ("a path", ["ui", "macs", "add", "x", "http://127.0.0.1:\(p2)/\(secret)"], 64),
        ("a login", ["ui", "macs", "add", "x", "http://u:\(secret)@127.0.0.1:\(p2)"], 64),
        ("a bad name", ["ui", "macs", "add", "Bad_\(secret)", "127.0.0.1:\(p2)"], 64),
        ("a name taken", ["ui", "macs", "add", "mini", "mini.local"], 4),
        ("an address taken", ["ui", "macs", "add", "mini2", "http://127.0.0.1:\(p2)/"], 4),
        ("this Mac's own dashboard", ["ui", "macs", "add", "self", "127.0.0.1:\(p4)"], 64),
    ]
    for (what, args, code) in refusals {
        r = a.run(args, timeout: 30)
        check(r.code != 0 && (code == nil || r.code == code) && !(r.out + r.err).contains(secret),
              "4 \(what): refused (\(r.code)), the input not repeated")
    }
    r = a.run(["ui", "macs", "add", "x", "http://127.0.0.1:\(p2)/#cap=\(secret)", "--json"], timeout: 30)
    check(r.code == 64 && r.out.contains("That is a sign-in link") && !r.out.contains(secret), "4 a sign-in link with --json: the fixed message only")
    check(sha(macs.file) == before, "4 macs.json unchanged by every refusal")

    // 5. the other dashboard stopped: a check fails, and when it was last seen is kept
    b.run(["ui", "stop"], timeout: 30)
    check(b.waitFor(15) { !answers(p2) }, "5 the other dashboard is stopped")
    r = a.run(["ui", "macs", "check", "mini"], timeout: 30)
    mini = list().first { $0.name == "mini" }
    check(r.code == 0 && ["refused", "timeout"].contains(mini?.lastResult ?? "") && mini?.lastSeenAt == seenAt && mini?.lastCheckAt != seenAt,
          "5 check mini: \(mini?.lastResult ?? "?"), lastSeenAt kept (\(r.out.trimmingCharacters(in: .whitespacesAndNewlines)))")
    check(r.out.contains("last seen"), "5 …and says when it was last seen")

    // 6. a Mac added without a check
    let closed = freePort()
    r = a.run(["ui", "macs", "add", "air", "127.0.0.1:\(closed)", "--no-check"], timeout: 30)
    let air = list().first { $0.name == "air" }
    check(r.code == 0 && air != nil && air?.lastCheckAt == nil && air?.lastResult == nil, "6 add air --no-check: kept, never checked")
    r = a.run(["ui", "macs", "ls"])
    check(r.out.contains("never checked"), "6 ls says never checked")

    // 7. the file holds names and origins only
    let bytes = (try? Data(contentsOf: URL(fileURLWithPath: macs.file))) ?? Data()
    let text = String(decoding: bytes, as: UTF8.self)
    check(mode(macs.file) == 0o600, "7 macs.json is 0600")
    check(!text.lowercased().contains("cap=") && !text.lowercased().contains("code=") && !text.contains("dzc_") && !text.contains(secret),
          "7 no cap=, code=, token prefix or refused input in macs.json")
    check(text.range(of: "[A-Za-z0-9_-]{32,}", options: .regularExpression) == nil, "7 no token-shaped run in macs.json")
    let keys = ((try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]).flatMap { $0["macs"] as? [[String: Any]] }?
        .reduce(into: Set<String>()) { $0.formUnion($1.keys) } ?? []
    check(keys.isSubset(of: MacBookmark.known) && keys.contains("origin"), "7 only the keys this build writes: \(keys.sorted().joined(separator: ", "))")

    // 8. rm
    r = a.run(["ui", "macs", "rm", "air"])
    check(r.code == 0 && !list().contains { $0.name == "air" }, "8 rm air: gone (\(r.code))")
    let afterRm = sha(macs.file)
    r = a.run(["ui", "macs", "rm", "nobody"])
    check(r.code != 0 && sha(macs.file) == afterRm, "8 rm nobody: refused (\(r.code)), unchanged")

    // 9. looking never starts the daemon; a running daemon answers the same list
    a.run(["daemon", "stop"], timeout: 60)
    _ = a.waitFor(20) { !a.hostRunning }
    let inProcess = a.run(["ui", "macs", "ls", "--json"]).out
    check(!a.hostRunning, "9 ls with the daemon stopped starts none")
    r = a.run(["daemon", "start"], timeout: 60)
    check(r.code == 0 && a.waitFor(20) { a.hostRunning }, "9 a daemon started (\(r.code))")
    let viaDaemon = a.run(["ui", "macs", "ls", "--json"]).out
    check(!inProcess.isEmpty && inProcess == viaDaemon, "9 the daemon's macs-ls answers the same list as in-process")
}
