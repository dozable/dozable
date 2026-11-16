import Darwin
import Foundation
import DozableKit
import DozableHost

// `make test-cli-fence`, the network part: a fenced session's proxy (the holder-held socket), DNS closed, the address
// guard, the password, the head deadline and the connection cap, live edits, the fence's refusals in the system log, a
// request while no host runs, and an update hand-over. Fake upstreams on this Mac's loopback only (the host's guarded seam
// `DOZ_TEST_FENCE_UPSTREAMS`); the real internet only in the opt-in rows (`FENCE_NET=1`). Row numbers are the plan's (M2).

/// A fake upstream on 127.0.0.1: every HTTP request answered `200` with `UPSTREAM-OK` and the head it received (so a row
/// can see what was forwarded); `stream: true` answers with 40 lines, one every 0.5 s (a 20 s download).
final class FenceUpstream: @unchecked Sendable {
    let fd: Int32
    let port: UInt16
    init(stream: Bool = false) {
        let s = socket(AF_INET, SOCK_STREAM, 0)
        var one: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, 4)
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        listen(s, 128)
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(s, $0, &len) } }
        fd = s
        port = UInt16(bigEndian: a.sin_port)
        Thread.detachNewThread { [fd] in
            while true {
                let c = accept(fd, nil, nil)
                if c < 0 { if errno == EINTR { continue }; return }
                var nos: Int32 = 1
                setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &nos, 4)
                Thread.detachNewThread {
                    defer { close(c) }
                    var acc = [UInt8]()
                    var buf = [UInt8](repeating: 0, count: 8192)
                    while !acc.isEmpty ? FenceUpstream.find(acc) == nil : true {
                        let n = read(c, &buf, buf.count)
                        if n <= 0 { return }
                        acc += buf[0..<n]
                    }
                    if stream {
                        let lines = (0..<40).map { "line \($0)\n" }
                        let total = lines.reduce(0) { $0 + $1.utf8.count }
                        guard FenceUpstream.write(c, "HTTP/1.1 200 OK\r\nContent-Length: \(total)\r\nConnection: close\r\n\r\n") else { return }
                        for l in lines {
                            guard FenceUpstream.write(c, l) else { return }
                            usleep(500_000)
                        }
                        return
                    }
                    let body = "UPSTREAM-OK\n" + String(decoding: acc, as: UTF8.self)
                    _ = FenceUpstream.write(c, "HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body)
                }
            }
        }
    }
    static func find(_ a: [UInt8]) -> Int? {
        guard a.count >= 4 else { return nil }
        for i in 0...(a.count - 4) where a[i] == 13 && a[i + 1] == 10 && a[i + 2] == 13 && a[i + 3] == 10 { return i }
        return nil
    }
    static func write(_ fd: Int32, _ s: String) -> Bool {
        let b = Array(s.utf8)
        var off = 0
        while off < b.count {
            let n = b[off...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if n <= 0 { return false }
            off += n
        }
        return true
    }
    func stop() { Darwin.shutdown(fd, SHUT_RDWR); close(fd) }
}

/// A raw request to 127.0.0.1:`port` from outside every fence; what came back (until the peer closed or `seconds`).
func fenceRawHTTP(_ port: UInt16, _ text: String, seconds: Int = 5) -> String {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    defer { close(fd) }
    var a = sockaddr_in()
    a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    a.sin_family = sa_family_t(AF_INET)
    a.sin_port = port.bigEndian
    a.sin_addr.s_addr = inet_addr("127.0.0.1")
    guard withUnsafePointer(to: &a, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }) == 0 else { return "" }
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, 4)
    var tv = timeval(tv_sec: seconds, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    _ = FenceUpstream.write(fd, text)
    var out = [UInt8]()
    var buf = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = read(fd, &buf, buf.count)
        if n <= 0 { break }
        out += buf[0..<n]
    }
    return String(decoding: out, as: UTF8.self)
}

/// The network rows. `t`: the suite's harness (its host has `DOZ_TEST_FENCE_UPSTREAMS` for `allowed`, `denied` and
/// `stream.doz.test`); `started`: the sessions to end at the end.
func cliFenceNetworkChecks(_ t: CLIHarness, root: String, home: String, store: String, binary: String,
                           allowed: FenceUpstream, streamer: FenceUpstream, started: inout Set<String>) async {
    print("cli: a fenced session's network — its proxy, DNS closed, the address guard, the log, the hand-over")
    let net = root + "/net"
    try? FileManager.default.createDirectory(atPath: net, withIntermediateDirectories: true)
    func put(_ p: String, _ s: String) { FileManager.default.createFile(atPath: p, contents: Data(s.utf8)) }
    func get(_ p: String) -> String { (try? String(contentsOfFile: p, encoding: .utf8)) ?? "" }
    func rows() -> [SessionRow] { t.json(["sessions", "@mac"], [SessionRow].self) ?? [] }
    func row(_ s: String) -> SessionRow? { rows().first { $0.name == s } }
    let sites = "standard,site:allowed.doz.test,site:stream.doz.test"
    func run(_ s: String, _ script: String, extra: [String] = [], harness: CLIHarness? = nil) -> CLIRun {
        let r = (harness ?? t).run(["run", "@mac", "-d", "--fenced", "--session", s, "--workdir", net] + extra + ["--", "/bin/sh", script], timeout: 90)
        if r.code == 0 { started.insert(s) }
        return r
    }
    // The shell helpers every script starts with: r NAME CMD… → its exit code; c NAME CURL-ARGS… → curl's code and
    // "%{http_code} %{http_connect}".
    let helpers = """
    r() { n=$1; shift; ( "$@" ) >/dev/null 2>&1; echo $? > "res/$n"; }
    c() { n=$1; shift; curl -s -o "res/$n.body" -w '%{http_code} %{http_connect}' "$@" > "res/$n.code" 2>/dev/null; echo $? > "res/$n"; }
    mkdir -p res

    """
    func res(_ n: String) -> Int? { Int(get(net + "/res/" + n).trimmingCharacters(in: .whitespacesAndNewlines)) }
    func code(_ n: String) -> String { get(net + "/res/" + n + ".code") }
    func body(_ n: String) -> String { get(net + "/res/" + n + ".body") }

    // MARK: B first (its port is what A tries)
    put(net + "/b.sh", "sleep 600\n")
    var r = run("netb", "b.sh")
    check(r.code == 0, "a second fenced session (B)")
    let bPort = row("netb")?.fence?.proxyPort ?? 0
    check(bPort > 0 && row("netb")?.fence?.network == "proxy", "B has a proxy port of its own (\(bPort)), served by the daemon")

    // MARK: A — the probes (2.1–2.5, 2.7, 2.11, 2.11b, 2.17)
    let lp = 43_000 + Int(getpid() % 1000)
    put(net + "/held.py", """
    import os, stat
    def sock(n):
        try: return stat.S_ISSOCK(os.fstat(n).st_mode)
        except OSError: return False
    print(','.join(str(n) for n in range(3, 256) if sock(n)))
    """)
    put(net + "/lp.py", """
    import os, socket
    s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(('127.0.0.1', \(lp))); s.listen(4)
    open('res/lp-listening', 'w').write('1')
    while True:
        c, _ = s.accept(); c.sendall(b'LP-OK'); c.close()
    """)
    put(net + "/a.sh", helpers + """
    echo "$HTTPS_PROXY" > res/proxyurl
    c allowed -m 10 http://allowed.doz.test/x
    c tunnel -m 10 -p http://allowed.doz.test/t
    c denied -m 10 http://denied.doz.test/
    r noproxy curl -s -m 5 --noproxy '*' http://allowed.doz.test/
    r raw /usr/bin/python3 -c "import socket; socket.create_connection(('93.184.216.34', 80), timeout=3)"
    r dns /usr/bin/python3 -c "import socket; socket.getaddrinfo('example.com', 443)"
    r dnslocal /usr/bin/python3 -c "import socket; socket.getaddrinfo('localhost', 443)"
    r udp /usr/bin/python3 -c "import socket; socket.socket(socket.AF_INET, socket.SOCK_DGRAM).sendto(b'x', ('1.1.1.1', 53))"
    r ping /sbin/ping -c 1 -t 2 1.1.1.1
    r cross nc -z -w 2 127.0.0.1 \(bPort)
    r bindb /usr/bin/python3 -c "import socket; s=socket.socket(); s.bind(('127.0.0.1', \(bPort))); s.listen(1)"
    r bindany /usr/bin/python3 -c "import socket; s=socket.socket(); s.bind(('127.0.0.1', 0)); s.listen(1)"
    r bindother /usr/bin/python3 -c "import socket; s=socket.socket(); s.bind(('127.0.0.1', \(lp + 1))); s.listen(1)"
    /usr/bin/python3 held.py > res/held 2>&1
    /usr/bin/python3 lp.py > /dev/null 2>&1 &
    sh -c 'echo x > "/private/tmp/dzo-spoof-$PPID
    doz-fence:'"$(cat btag)"'"' 2>/dev/null
    echo done > res/DONE
    while [ ! -e go-denied ]; do sleep 0.2; done
    c edited -m 10 http://allowed.doz.test/e
    while [ ! -e go-nohost ]; do sleep 0.2; done
    c nohost -m 40 http://allowed.doz.test/n
    while [ ! -e go-allowed ]; do sleep 0.2; done
    c edited2 -m 10 http://allowed.doz.test/e2
    sleep 600
    """)
    put(net + "/btag", sessionTagOf(store, "netb") ?? "0000000000000000")
    r = run("net", "a.sh", extra: ["--permissions", sites, "--local-port", String(lp)])
    check(r.code == 0 && r.err.contains("network through Dozable's proxy"), "run @mac --fenced --permissions … --local-port: the line says its network (\(r.code))")
    check(t.waitFor(60) { FileManager.default.fileExists(atPath: net + "/res/DONE") }, "the network probes ran")
    check(res("allowed") == 0 && code("allowed").hasPrefix("200") && body("allowed").contains("UPSTREAM-OK"), "2.1 an allowed name through the proxy: 200 (\(code("allowed")))")
    check(res("tunnel") == 0 && code("tunnel").hasPrefix("200 200"), "2.1 …through a CONNECT tunnel too (\(code("tunnel")))")
    check(code("denied").hasPrefix("403") && body("denied").contains("blocked"), "2.2 a name the permissions do not allow: 403 with the rule (\(code("denied")))")
    check(!body("allowed").lowercased().contains("proxy-authorization"), "2.8 the proxy's password never goes upstream")
    check(res("noproxy").map { $0 != 0 } ?? false, "2.3 a program that ignores the proxy (curl --noproxy '*') fails closed")
    check(res("raw").map { $0 != 0 } ?? false, "2.3 a raw socket to an address fails closed")
    check(res("dns").map { $0 != 0 } ?? false, "2.4 DNS is closed inside")
    check(res("dnslocal") == 0, "2.4 …localhost still resolves")
    check(res("udp").map { $0 != 0 } ?? false, "2.5 UDP refused")
    check(res("ping").map { $0 != 0 } ?? false, "2.5 ICMP (ping) refused")
    check(res("cross").map { $0 != 0 } ?? false, "2.7 session A cannot reach session B's proxy port")
    check(res("bindb").map { $0 != 0 } ?? false && res("bindany").map { $0 != 0 } ?? false, "2.11 a fenced bind on B's port, or any port, refused")
    check(res("bindother").map { $0 != 0 } ?? false, "2.17 a port other than its --local-port: refused")
    check(get(net + "/res/held").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "2.11b the held proxy socket is not in the program (\(get(net + "/res/held").trimmingCharacters(in: .whitespacesAndNewlines)))")
    check(t.waitFor(10) { FileManager.default.fileExists(atPath: net + "/res/lp-listening") }, "2.17 it listens on its --local-port \(lp)")
    check(fenceRawHTTP(UInt16(lp), "", seconds: 3) == "LP-OK", "2.17 …and this Mac reaches it there directly")
    let nrow = row("net")
    check(nrow?.fence?.localPorts == [lp] && nrow?.fence?.network == "proxy" && nrow?.fence?.preset == "agent", "sessions --json: its ports, its network, its permissions (Standard + its sites)")

    // MARK: 2.18 the fence's refusals (this host's — read before any host stop)
    var d = t.json(["net", "log", "@mac", "--session", "net", "--fence"], FenceDenials.self)
    if d?.denialLog == "on" {
        check(t.waitFor(10) {
            d = t.json(["net", "log", "@mac", "--session", "net", "--fence"], FenceDenials.self)
            return d?.denials.contains { $0.operation.hasPrefix("network") } == true
        }, "2.18 the fence's refusals are in the session's log (\(d?.denials.count ?? 0), e.g. network-outbound)")
        let bd = t.json(["net", "log", "@mac", "--session", "netb", "--fence"], FenceDenials.self)
        check(bd != nil && !(bd!.denials.contains { $0.target.contains("dzo-spoof") }), "2.18 a path naming B's tag, refused in A, never reaches B's log")
        check(row("net")?.fence?.denialsSeen.map { $0 > 0 } == true, "2.18 sessions --json: refusals seen")
    } else {
        check(d?.denialLog == "unavailable", "2.18 the system log is not readable by this account: said (\(d?.denialLog ?? "no answer"))")
    }

    // MARK: 2.6, 2.6a — from outside: the password, the head deadline, the cap
    let url = get(net + "/res/proxyurl").trimmingCharacters(in: .whitespacesAndNewlines)
    let aPort = UInt16(nrow?.fence?.proxyPort ?? 0)
    let pw = url.split(separator: "@").first.map { String($0.dropFirst("http://doz:".count)) } ?? ""
    check(url.hasPrefix("http://doz:") && url.hasSuffix("@127.0.0.1:\(aPort)") && pw.count >= 40, "its proxy variables: the password in the URL, 127.0.0.1 and its port")
    func authed(_ p: String) -> String { "Proxy-Authorization: Basic " + Data("doz:\(p)".utf8).base64EncodedString() + "\r\n" }
    let req = "GET http://allowed.doz.test/o HTTP/1.1\r\nHost: allowed.doz.test\r\n"
    check(fenceRawHTTP(aPort, req + "\r\n").hasPrefix("HTTP/1.1 407"), "2.6 no password: 407")
    check(fenceRawHTTP(aPort, req + authed("wrong") + "\r\n").hasPrefix("HTTP/1.1 407"), "2.6 a wrong password: 407")
    check(fenceRawHTTP(aPort, req + authed(pw) + "\r\n").hasPrefix("HTTP/1.1 200"), "2.6 the right one: 200")
    var lim = rlimit()
    getrlimit(RLIMIT_NOFILE, &lim)
    if lim.rlim_cur < 2048 { lim.rlim_cur = min(4096, lim.rlim_max); setrlimit(RLIMIT_NOFILE, &lim) }
    var loris: [Int32] = []
    let t0 = Date()
    for _ in 0..<300 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = aPort.bigEndian
        a.sin_addr.s_addr = inet_addr("127.0.0.1")
        if withUnsafePointer(to: &a, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }) == 0 {
            loris.append(fd)
        } else { close(fd) }
    }
    usleep(800_000)
    var got503 = 0
    for fd in loris {
        var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        if poll(&p, 1, 0) == 1 {
            var b = [UInt8](repeating: 0, count: 64)
            let n = read(fd, &b, b.count)
            if n > 0, String(decoding: b[0..<n], as: UTF8.self).hasPrefix("HTTP/1.1 503") { got503 += 1 }
        }
    }
    check(loris.count == 300 && got503 >= 40 && got503 <= 44, "2.6a 300 connections that send nothing: past 256 at once each gets 503 (\(got503) of \(loris.count))")
    var closedBy7 = 0
    let deadline = t0.addingTimeInterval(7.5)
    for fd in loris {
        var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let left = Int32(max(0, deadline.timeIntervalSinceNow * 1000))
        if poll(&p, 1, left) == 1 {
            // What is left of an answer, then the end.
            var b = [UInt8](repeating: 0, count: 4096)
            var n = read(fd, &b, b.count)
            for _ in 0..<8 where n > 0 { n = read(fd, &b, b.count) }
            if n <= 0 { closedBy7 += 1 }
        }
    }
    check(closedBy7 == loris.count, "2.6a …and every one is closed by the 5 s head deadline (\(closedBy7) of \(loris.count) within 7.5 s)")
    for fd in loris { close(fd) }
    usleep(300_000)
    check(fenceRawHTTP(aPort, req + authed(pw) + "\r\n").hasPrefix("HTTP/1.1 200"), "2.6a the session's own requests are served again")

    // MARK: 2.9/2.10 — this Mac's addresses, whatever the permissions (Open)
    let own = AddressGuard.interfaceAddresses().first { $0.count == 4 && $0[0] != 127 && $0[0] != 169 }.map { $0.map(String.init).joined(separator: ".") }
    put(net + "/g.sh", helpers + """
    c lo -m 10 --noproxy '' -p http://127.0.0.1:\(allowed.port)/
    c lohttp -m 10 --noproxy '' http://127.0.0.1:\(allowed.port)/
    c localhost -m 10 --noproxy '' -p http://localhost:\(allowed.port)/
    c md -m 10 --noproxy '' -p http://169.254.169.254/
    c mdhttp -m 10 --noproxy '' http://169.254.169.254/latest/meta-data/
    c mapped -m 10 --noproxy '' -p "http://[::ffff:127.0.0.1]:\(allowed.port)/"
    c mappedmd -m 10 --noproxy '' -p "http://[::ffff:169.254.169.254]/"
    c own -m 10 --noproxy '' -p http://\(own ?? "127.0.0.1"):\(allowed.port)/
    echo done > res/GDONE
    sleep 600
    """)
    r = run("netopen", "g.sh", extra: ["--permissions", "open"])
    check(r.code == 0 && t.waitFor(60) { FileManager.default.fileExists(atPath: net + "/res/GDONE") }, "a fenced session with --permissions open")
    for (n, what) in [("lo", "127.0.0.1 (CONNECT)"), ("lohttp", "127.0.0.1 (plain HTTP)"), ("localhost", "localhost"), ("md", "169.254.169.254 (metadata)"),
                      ("mdhttp", "metadata (plain HTTP)"), ("mapped", "::ffff:127.0.0.1"), ("mappedmd", "::ffff:169.254.169.254"),
                      ("own", "this Mac's own address \(own ?? "(none found)")")] {
        let c = code(n)
        check(c.hasPrefix("403") || c.hasSuffix(" 403"), "2.9 \(what) refused through the proxy under Open (\(c))")
    }
    check(row("netopen")?.fence?.preset == "open", "its preset: open")

    // MARK: 2.13 live edits; 2.12 a request while no host runs
    r = t.run(["net", "deny", "@mac", "site:allowed.doz.test", "--session", "net"])
    check(r.code == 0, "2.13 doz net deny @mac site:… --session net")
    FileManager.default.createFile(atPath: net + "/go-denied", contents: nil)
    check(t.waitFor(20) { res("edited") != nil } && code("edited").hasPrefix("403"), "2.13 …its next request is refused (\(code("edited")))")
    r = t.run(["net", "allow", "@mac", "site:allowed.doz.test", "--session", "net"])
    check(r.code == 0 && r.out.contains("@mac net"), "2.13 doz net allow @mac … --session net (the checklist printed)")
    // The edit is kept across hosts: stop, look without a host, start again.
    check(t.run(["daemon", "stop"], timeout: 60).code == 0, "daemon stop (fenced sessions keep running)")
    let kept = t.json(["net", "policy", "@mac", "--session", "net"], NetworkPolicy.self)
    check(kept?.rules.contains { $0.host == "allowed.doz.test" && $0.action == .allow } == true, "2.13 the live edit is in the record (read with no daemon)")
    check(MacCLIState.state(row("net")).contains("network waiting (no daemon)"), "sessions @mac: network waiting (no daemon)")
    FileManager.default.createFile(atPath: net + "/go-nohost", contents: nil)
    usleep(2_000_000)
    check(res("nohost") == nil, "2.12 a request made while no daemon runs waits (in the holder's backlog)")
    r = t.run(["sessions", "send", "@mac", "netb", "--text", "x"], timeout: 30)          // starts a host, which adopts
    check(t.waitFor(40) { res("nohost") != nil } && code("nohost").hasPrefix("200"), "2.12 …and is served once a host returns (\(code("nohost")))")
    FileManager.default.createFile(atPath: net + "/go-allowed", contents: nil)
    check(t.waitFor(20) { res("edited2") != nil } && code("edited2").hasPrefix("200"), "2.13 the adopted proxy has the edited policy (\(code("edited2")))")
    // 2.11a: from outside, with B's host down, B's port cannot be taken.
    check(t.run(["daemon", "stop"], timeout: 60).code == 0, "daemon stop")
    var taken = false
    for opt in [Int32(0), SO_REUSEADDR, SO_REUSEPORT] {
        let s = socket(AF_INET, SOCK_STREAM, 0)
        var one: Int32 = 1
        if opt != 0 { setsockopt(s, SOL_SOCKET, opt, &one, 4) }
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = UInt16(bPort).bigEndian
        a.sin_addr.s_addr = inet_addr("127.0.0.1")
        if withUnsafePointer(to: &a, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }) == 0 { taken = true }
        close(s)
    }
    check(!taken, "2.11a with no daemon, nobody outside can bind B's port (± SO_REUSEADDR / SO_REUSEPORT): its holder holds it")

    // MARK: 2.14 Locked: the model only, and no certificate trust on its behalf
    put(net + "/l.sh", "sleep 600\n")
    r = run("netlocked", "l.sh", extra: ["--permissions", "locked"])
    check(r.code == 0 && r.err.contains("locked permissions"), "a fenced session with --permissions locked")
    if let pid = row("netlocked")?.pid {
        check(MacFenceStop.mayLookUp(pid_t(pid), "com.apple.trustd") == false, "2.14 Locked closes trustd")
    } else { check(false, "the locked session's pid") }
    let rep = t.json(["net", "show", "@mac", "--session", "netlocked"], PermissionReport.self)
    check(rep?.preset == "locked" && rep?.permissions.filter(\.on).map(\.id) == ["model"], "2.14 doz net show @mac: Locked — the model only")

    // MARK: 2.18 an account that cannot read the system log
    check(t.run(["daemon", "stop"], timeout: 60).code == 0, "daemon stop")
    t.env["DOZ_TEST_FENCE_LOG"] = "unavailable"
    r = t.run(["sessions", "send", "@mac", "netb", "--text", "x"], timeout: 30)
    let un = t.json(["net", "log", "@mac", "--session", "net", "--fence"], FenceDenials.self)
    check(un?.denialLog == "unavailable" && row("net")?.fence?.denialLog == "unavailable", "2.18 an account that cannot read the log: denialLog unavailable, the session runs on")
    check(fenceRawHTTP(aPort, req + authed(pw) + "\r\n").hasPrefix("HTTP/1.1 200"), "…its network unaffected")
    check(t.run(["daemon", "stop"], timeout: 60).code == 0, "daemon stop")
    t.env["DOZ_TEST_FENCE_LOG"] = nil

    // MARK: 2.19 the net commands' refusals
    r = t.run(["net", "show", "@mac"])
    check(r.code != 0 && r.err.contains("--session"), "2.19 doz net show @mac without --session: refused")
    r = t.run(["net", "show", "@mac", "--session", "nosuch"])
    check(r.code != 0 && r.err.contains("no fenced session"), "2.19 …a session that is not fenced: refused")
    r = t.run(["net", "log", "@mac", "--session", "net", "--follow", "--fence"])
    check(r.code != 0, "2.19 --fence with --follow: refused")
    for s in ["net", "netopen", "netlocked", "netb"] { t.run(["sessions", "end", "@mac", s, "--yes"], timeout: 60); started.remove(s) }
    check(FileManager.default.fileExists(atPath: "/private/tmp") && !(try? FileManager.default.contentsOfDirectory(atPath: "/private/tmp"))!.contains { $0.hasPrefix("dzo-spoof") },
          "the spoof file was never written (refused)")

    // MARK: 690 site port rules — `site:HOST:PORT` (ports.doz.test is the same fake upstream under a name of its own)
    let p1 = 8081, p2 = 8082
    put(net + "/pt.sh", helpers + """
    w() { while [ ! -e "go-$1" ]; do sleep 0.2; done; }
    c a1 -m 10 http://ports.doz.test:\(p1)/
    c a2 -m 10 http://ports.doz.test:\(p2)/
    c a1t -m 10 -p http://ports.doz.test:\(p1)/
    c a2t -m 10 -p http://ports.doz.test:\(p2)/
    c old -m 10 http://allowed.doz.test:8099/
    c lo -m 10 --noproxy '' -p http://127.0.0.1:\(allowed.port)/
    c lohttp -m 10 --noproxy '' http://127.0.0.1:\(allowed.port)/
    c own -m 10 --noproxy '' -p http://\(own ?? "127.0.0.1"):\(allowed.port)/
    c ownhttp -m 10 --noproxy '' http://\(own ?? "127.0.0.1"):\(allowed.port)/
    echo done > res/PDONE
    w 1
    c b1 -m 10 http://ports.doz.test:\(p1)/
    c b2 -m 10 http://ports.doz.test:\(p2)/
    echo done > res/P1DONE
    w 2
    c c1 -m 10 http://ports.doz.test:\(p1)/
    c c2 -m 10 http://ports.doz.test:\(p2)/
    echo done > res/P2DONE
    w 3
    c d1 -m 10 http://ports.doz.test:\(p1)/
    c d2 -m 10 http://ports.doz.test:\(p2)/
    echo done > res/P3DONE
    sleep 600
    """)
    let portWords = "standard,site:ports.doz.test:\(p1),site:allowed.doz.test,site:127.0.0.1:\(allowed.port),site:\(own ?? "127.0.0.1"):\(allowed.port)"
    r = run("netport", "pt.sh", extra: ["--permissions", portWords])
    check(r.code == 0, "690 a fenced session with --permissions site:HOST:PORT (and a site with every port, and this Mac's own addresses by port) (\(r.code))")
    check(t.waitFor(60) { FileManager.default.fileExists(atPath: net + "/res/PDONE") }, "690 the port probes ran")
    check(code("a1").hasPrefix("200") && body("a1").contains("UPSTREAM-OK"), "690 site:HOST:\(p1) opens port \(p1) (\(code("a1")))")
    check(code("a2").hasPrefix("403") && body("a2").contains("blocked"), "690 …and refuses port \(p2) of the same host (\(code("a2")))")
    check(code("a1t").hasPrefix("200 200") && (code("a2t").hasPrefix("403") || code("a2t").hasSuffix(" 403")), "690 …through a CONNECT tunnel too (\(code("a1t")) / \(code("a2t")))")
    check(code("old").hasPrefix("200"), "690 an old site:HOST rule still opens every port (8099: \(code("old")))")
    for (n, what) in [("lo", "site:127.0.0.1:PORT (CONNECT)"), ("lohttp", "site:127.0.0.1:PORT (plain HTTP)"),
                      ("own", "site:\(own ?? "(none found)"):PORT (CONNECT)"), ("ownhttp", "site:\(own ?? "(none found)"):PORT (plain HTTP)")] {
        let c = code(n)
        check(c.hasPrefix("403") || c.hasSuffix(" 403"), "690 the strict address guard still refuses \(what) (\(c))")
    }
    var shown = t.run(["net", "show", "@mac", "--session", "netport"])
    check(shown.code == 0 && shown.out.contains("ports.doz.test:\(p1)"), "690 doz net show @mac prints the port")
    let rep690 = t.json(["net", "show", "@mac", "--session", "netport"], PermissionReport.self)
    check(rep690?.sites.contains("ports.doz.test:\(p1)") == true && rep690?.sites.contains("allowed.doz.test") == true, "690 --json: sites are strings, host or host:port")
    shown = t.run(["net", "deny", "@mac", "site:ports.doz.test:\(p1)", "--session", "netport"])
    check(shown.code == 0, "690 doz net deny @mac --session … site:HOST:\(p1)")
    FileManager.default.createFile(atPath: net + "/go-1", contents: nil)
    check(t.waitFor(30) { FileManager.default.fileExists(atPath: net + "/res/P1DONE") } && code("b1").hasPrefix("403") && code("b2").hasPrefix("403"),
          "690 …live: port \(p1) is refused now (\(code("b1"))), \(p2) was never open (\(code("b2")))")
    shown = t.run(["net", "allow", "@mac", "site:ports.doz.test", "--session", "netport"])
    check(shown.code == 0, "690 doz net allow @mac … site:HOST (every port)")
    FileManager.default.createFile(atPath: net + "/go-2", contents: nil)
    check(t.waitFor(30) { FileManager.default.fileExists(atPath: net + "/res/P2DONE") } && code("c1").hasPrefix("200") && code("c2").hasPrefix("200"),
          "690 …the whole host is open (\(code("c1")) / \(code("c2")))")
    shown = t.run(["net", "deny", "@mac", "site:ports.doz.test:\(p2)", "--session", "netport"])
    check(shown.code == 0, "690 doz net deny @mac … site:HOST:\(p2) under the whole-host allow")
    FileManager.default.createFile(atPath: net + "/go-3", contents: nil)
    check(t.waitFor(30) { FileManager.default.fileExists(atPath: net + "/res/P3DONE") } && code("d1").hasPrefix("200") && code("d2").hasPrefix("403"),
          "690 …just \(p2) is refused, \(p1) answers (\(code("d1")) / \(code("d2")))")
    check(t.run(["daemon", "stop"], timeout: 60).code == 0, "690 daemon stop")
    let kept690 = t.json(["net", "policy", "@mac", "--session", "netport"], NetworkPolicy.self)
    check(kept690?.rules.contains { $0.host == "ports.doz.test" && $0.action == .deny && $0.ports == [UInt16(p2)] } == true
          && kept690?.rules.contains { $0.host == "ports.doz.test" && $0.action == .allow && $0.ports == nil } == true, "690 the record keeps the port rules with no daemon")
    t.run(["sessions", "end", "@mac", "netport", "--yes"], timeout: 60); started.remove("netport")

    // MARK: 691 this Mac's ports — `--host-port`, `host:PORT`, `host.dozable.internal` (two listeners of the suite's own on
    // this Mac's loopback, ephemeral ports, stopped at the end of the rows)
    let hp1 = FenceUpstream(), hp2 = FenceUpstream()
    let hpA = hp1.port, hpB = hp2.port
    put(net + "/hp.sh", helpers + """
    w() { while [ ! -e "go-$1" ]; do sleep 0.2; done; }
    c hpa -m 10 http://host.dozable.internal:\(hpA)/
    c hpb -m 10 http://host.dozable.internal:\(hpB)/
    c hpm -m 10 http://mac.dozable.internal:\(hpA)/
    c hpat -m 10 -p http://host.dozable.internal:\(hpA)/
    c hplo -m 10 --noproxy '' http://127.0.0.1:\(hpA)/
    c hplot -m 10 --noproxy '' -p http://127.0.0.1:\(hpA)/
    c hpown -m 10 --noproxy '' http://\(own ?? "127.0.0.1"):\(hpA)/
    c hplh -m 10 --noproxy '' http://localhost:\(hpA)/
    r hpdir curl -s -m 5 --noproxy '*' http://127.0.0.1:\(hpA)/
    echo done > res/HP0
    w hp1; c hpb1 -m 10 http://host.dozable.internal:\(hpB)/; echo done > res/HP1
    w hp2; c hpb2 -m 10 http://host.dozable.internal:\(hpB)/; echo done > res/HP2
    w hp3; c hpa3 -m 40 http://host.dozable.internal:\(hpA)/; echo done > res/HP3
    w hp4; c hpa4 -m 10 http://host.dozable.internal:\(hpA)/; echo done > res/HP4
    sleep 600
    """)
    r = run("hp", "hp.sh", extra: ["--host-port", String(hpA)])
    check(r.code == 0 && r.err.contains("this Mac's ports \(hpA)"), "691 a fenced session with --host-port \(hpA): its line says the port (\(r.code))")
    check(t.waitFor(60) { FileManager.default.fileExists(atPath: net + "/res/HP0") }, "691 the host-port probes ran")
    check(code("hpa").hasPrefix("200") && body("hpa").contains("UPSTREAM-OK"), "691 host.dozable.internal:\(hpA) reaches the service on this Mac (\(code("hpa")))")
    check(code("hpm").hasPrefix("200"), "691 …mac.dozable.internal:\(hpA) is the same route (\(code("hpm")))")
    check(code("hpat").hasPrefix("200 200"), "691 …through a CONNECT tunnel too (\(code("hpat")))")
    check(code("hpb").hasPrefix("403") && body("hpb").contains("only port \(hpA) of this Mac"), "691 another port of this Mac: 403 naming the open one (\(code("hpb")))")
    for (n, what) in [("hplo", "127.0.0.1:PORT (plain HTTP)"), ("hplot", "127.0.0.1:PORT (CONNECT)"), ("hplh", "localhost:PORT"),
                      ("hpown", "\(own ?? "(no LAN address — loopback again)"):PORT")] {
        let c = code(n)
        check(c.hasPrefix("403") || c.hasSuffix(" 403"), "691 the OPEN port by an address of this Mac is still refused: \(what) (\(c))")
    }
    check(res("hpdir").map { $0 != 0 } ?? false, "691 …and directly (not through the proxy): the fence refuses it")
    var hrep = t.json(["net", "show", "@mac", "--session", "hp"], PermissionReport.self)
    check(hrep?.hostPorts?.map(\.port) == [hpA] && hrep?.hostPortsLive == true, "691 doz net show @mac --json: hostPorts [\(hpA)]")
    check(t.run(["net", "show", "@mac", "--session", "hp"]).out.contains("This Mac's ports: \(hpA)"), "691 doz net show @mac prints this Mac's ports")
    check(row("hp")?.capabilities?.contains { $0.id == "host-ports" && $0.state == String(hpA) } == true, "691 its capabilities say the port")
    // Live: allow, then deny.
    r = t.run(["net", "allow", "@mac", "host:\(hpB)", "--session", "hp"])
    check(r.code == 0 && r.out.contains("This Mac's ports: ") && r.out.contains(String(hpA)) && r.out.contains(String(hpB)), "691 doz net allow @mac --session hp host:\(hpB) (live) (\(r.code) \(r.err.prefix(160)))")
    FileManager.default.createFile(atPath: net + "/go-hp1", contents: nil)
    check(t.waitFor(30) { FileManager.default.fileExists(atPath: net + "/res/HP1") } && code("hpb1").hasPrefix("200"), "691 …its next request to \(hpB): 200 (\(code("hpb1")))")
    r = t.run(["net", "deny", "@mac", "host:\(hpB)", "--session", "hp"])
    check(r.code == 0, "691 doz net deny @mac --session hp host:\(hpB)")
    FileManager.default.createFile(atPath: net + "/go-hp2", contents: nil)
    check(t.waitFor(30) { FileManager.default.fileExists(atPath: net + "/res/HP2") } && code("hpb2").hasPrefix("403"), "691 …403 again (\(code("hpb2")))")
    // Dozable's own port (this session's own proxy) is refused at grant.
    if let own = row("hp")?.fence?.proxyPort {
        r = t.run(["net", "allow", "@mac", "host:\(own)", "--session", "hp"])
        check(r.code != 0 && r.err.contains("Dozable's own"), "691 a proxy's own port is refused at grant (\(r.err.prefix(160)))")
    } else { check(false, "691 the session's proxy port") }
    // The record keeps the ports across a daemon stop; the adopted proxy routes them.
    check(t.run(["daemon", "stop"], timeout: 60).code == 0, "691 daemon stop")
    hrep = t.json(["net", "show", "@mac", "--session", "hp"], PermissionReport.self)
    check(hrep?.hostPorts?.map(\.port) == [hpA], "691 with no daemon the record keeps this Mac's ports (\(hrep?.hostPorts?.map(\.port) ?? []))")
    _ = t.run(["sessions", "send", "@mac", "hp", "--text", "x"], timeout: 30)          // starts a daemon, which adopts
    FileManager.default.createFile(atPath: net + "/go-hp3", contents: nil)
    check(t.waitFor(60) { FileManager.default.fileExists(atPath: net + "/res/HP3") } && code("hpa3").hasPrefix("200"), "691 …and a new daemon's proxy routes it (\(code("hpa3")))")
    // The setting off: an allow is refused (saying what to do), a deny still works.
    check(t.run(["config", "set", "network.host_ports_live", "false"]).code == 0, "691 doz config set network.host_ports_live false")
    r = t.run(["net", "allow", "@mac", "host:\(hpB)", "--session", "hp"])
    check(r.code != 0 && r.err.contains("network.host_ports_live is off") && r.err.contains("--host-port"), "691 off: allow host:PORT refused (\(r.err.prefix(200)))")
    r = t.run(["net", "deny", "@mac", "host:\(hpA)", "--session", "hp"])
    check(r.code == 0, "691 off: deny host:PORT still works")
    FileManager.default.createFile(atPath: net + "/go-hp4", contents: nil)
    check(t.waitFor(30) { FileManager.default.fileExists(atPath: net + "/res/HP4") } && code("hpa4").hasPrefix("403"), "691 …the port is closed live (\(code("hpa4")))")
    check(t.run(["config", "set", "network.host_ports_live", "true"]).code == 0, "691 doz config set network.host_ports_live true")
    // The tag: the service sees X-Dozable-Session naming the session, never the program's copy; CONNECT untouched; an
    // untagged port passes the program's own field.
    put(net + "/hpt.sh", helpers + """
    c hpt1 -m 10 -H 'X-Dozable-Session: spoof' -H 'x-dozable-session: spoof2' http://host.dozable.internal:\(hpA)/
    c hpt2 -m 10 -H 'X-Dozable-Session: mine' http://host.dozable.internal:\(hpB)/
    c hpt3 -m 10 -p -H 'X-Dozable-Session: inside' http://host.dozable.internal:\(hpA)/
    echo done > res/HPT
    sleep 600
    """)
    r = run("hptag", "hpt.sh", extra: ["--host-port", "\(hpA):tag", "--permissions", "standard,host:\(hpB)"])
    check(r.code == 0 && t.waitFor(60) { FileManager.default.fileExists(atPath: net + "/res/HPT") }, "691 a fenced session with --host-port PORT:tag and --permissions host:PORT")
    let tagged = body("hpt1")
    check(code("hpt1").hasPrefix("200") && tagged.contains("X-Dozable-Session: @mac/hptag\r\n") && !tagged.contains("spoof")
          && tagged.lowercased().components(separatedBy: "x-dozable-session").count == 2,
          "691 :tag — the service sees X-Dozable-Session: @mac/hptag, and not the program's copies (\(code("hpt1")))")
    check(code("hpt2").hasPrefix("200") && body("hpt2").contains("X-Dozable-Session: mine") && !body("hpt2").contains("@mac/hptag"),
          "691 without :tag the route is transparent (the program's field passes, nothing added)")
    check(code("hpt3").hasPrefix("200 200") && body("hpt3").contains("X-Dozable-Session: inside") && !body("hpt3").contains("@mac/hptag"),
          "691 a CONNECT tunnel is never read: untouched")
    // --unfenced with --host-port: refused (an unfenced session already reaches every port).
    r = t.run(["run", "@mac", "-d", "--unfenced", "--host-port", String(hpA), "--session", "hpun", "--workdir", net, "--", "/bin/sh", "-c", "true"])
    check(r.code != 0 && r.err.contains("--host-port"), "691 --unfenced --host-port refused (\(r.err.prefix(160)))")
    for s in ["hp", "hptag"] { t.run(["sessions", "end", "@mac", s, "--yes"], timeout: 60); started.remove(s) }
    hp1.stop(); hp2.stop()

    // MARK: 687 listening on any port (mac.fence_loopback_listen, off by default — rows 2.11/2.17 above are that default)
    let lis = root + "/lis"
    try? FileManager.default.createDirectory(atPath: lis, withIntermediateDirectories: true)
    func lres(_ n: String) -> Int? { Int(get(lis + "/res/" + n).trimmingCharacters(in: .whitespacesAndNewlines)) }
    put(lis + "/srv.py", """
    socket = __import__('socket')    # (no line starting "import": the audit reads those as Swift imports)
    s = socket.socket(); s.bind(('127.0.0.1', 0)); s.listen(4)
    open('res/port', 'w').write(str(s.getsockname()[1]))
    while True:
        c, _ = s.accept(); c.sendall(b'LIS-OK'); c.close()
    """)
    put(lis + "/l.sh", helpers + """
    r l4 /usr/bin/python3 -c "import socket; s=socket.socket(); s.bind(('127.0.0.1', 0)); s.listen(1)"
    r l6 /usr/bin/python3 -c "import socket; s=socket.socket(socket.AF_INET6); s.bind(('::1', 0)); s.listen(1)"
    r lany /usr/bin/python3 -c "import socket; s=socket.socket(); s.bind(('0.0.0.0', 0)); s.listen(1)"
    r ludp /usr/bin/python3 -c "import socket; socket.socket(socket.AF_INET, socket.SOCK_DGRAM).bind(('127.0.0.1', 0))"
    r self /usr/bin/python3 -c "import socket; s=socket.socket(); s.bind(('127.0.0.1', 0)); s.listen(1); socket.create_connection(s.getsockname(), timeout=3)"
    /usr/bin/python3 srv.py > /dev/null 2>&1 &
    echo done > res/DONE
    sleep 600
    """)
    check(t.run(["config", "set", "mac.fence_loopback_listen", "on"]).code == 0, "doz config set mac.fence_loopback_listen on")
    r = t.run(["run", "@mac", "-d", "--fenced", "--session", "lis", "--workdir", lis, "--", "/bin/sh", "l.sh"], timeout: 90)
    if r.code == 0 { started.insert("lis") }
    check(r.code == 0 && r.err.contains("it may listen on any port") && t.waitFor(60) { FileManager.default.fileExists(atPath: lis + "/res/DONE") },
          "a fenced session with the setting on: its line says it may listen on any port")
    check(lres("l4") == 0, "listen(0) on 127.0.0.1 works (\(lres("l4").map(String.init) ?? "-"))")
    check(lres("l6") == 0, "…on ::1 too")
    check(lres("ludp").map { $0 != 0 } ?? false, "UDP stays closed")
    check(lres("self").map { $0 != 0 } ?? false, "it cannot connect to its own listener from inside (outbound unchanged: its proxy and --local-port only)")
    // Seatbelt cannot keep the bind to the loopback address: said, not hidden (the capability and the setting say so).
    print("  INFO  a bind on 0.0.0.0 with the setting on: \(lres("lany") == 0 ? "works — reachable from the network, as the capability says" : "refused")")
    check(t.waitFor(10) { !get(lis + "/res/port").isEmpty }, "its server listens on a free port (\(get(lis + "/res/port")))")
    let lisPort = UInt16(get(lis + "/res/port").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    check(lisPort > 0 && fenceRawHTTP(lisPort, "", seconds: 3) == "LIS-OK", "this Mac (outside the fence) reaches it")
    check(row("lis")?.capabilities?.contains { $0.id == "listen" && $0.state == "any port" } == true && row("lis")?.fence?.loopbackListen == true,
          "its capabilities say it may listen on any port")
    put(lis + "/x.sh", helpers + "r cross nc -z -w 2 127.0.0.1 \(lisPort)\necho done > res/XDONE\nsleep 600\n")
    r = t.run(["run", "@mac", "-d", "--fenced", "--session", "lisx", "--workdir", lis, "--", "/bin/sh", "x.sh"], timeout: 90)
    if r.code == 0 { started.insert("lisx") }
    check(r.code == 0 && t.waitFor(60) { FileManager.default.fileExists(atPath: lis + "/res/XDONE") } && (lres("cross").map { $0 != 0 } ?? false),
          "another fenced session cannot connect to it")
    check(t.run(["config", "set", "mac.fence_loopback_listen", "off"]).code == 0, "doz config set mac.fence_loopback_listen off")
    try? FileManager.default.removeItem(atPath: lis + "/res")
    r = t.run(["sessions", "restart", "@mac", "lis", "--yes", "-d"], timeout: 60)
    check(r.code == 0 && t.waitFor(60) { FileManager.default.fileExists(atPath: lis + "/res/DONE") } && (lres("l4").map { $0 != 0 } ?? false),
          "the setting off: a restart follows it — listen(0) refused again (\(lres("l4").map(String.init) ?? "-"))")
    check(row("lis")?.capabilities?.contains { $0.id == "listen" } == false, "…and the capability is gone")
    for s in ["lis", "lisx"] { t.run(["sessions", "end", "@mac", s, "--yes"], timeout: 60); started.remove(s) }

    // MARK: 2.16 the hand-over: the host's program replaced by rename, only a fenced session live
    await fenceHandOver(t, root: root, net: net, binary: binary, store: store, sites: sites, allowed: allowed, started: &started)

    // MARK: opt-in: the real internet through the proxy (FENCE_NET=1)
    if ProcessInfo.processInfo.environment["FENCE_NET"] == "1" {
        put(net + "/i.sh", helpers + """
        c gh -m 30 https://github.com/
        r py /usr/bin/python3 -c "import urllib.request; urllib.request.urlopen('https://pypi.org/simple/pip/', timeout=30).read(100)"
        r git git ls-remote https://github.com/git/git HEAD
        r node sh -c 'command -v node >/dev/null || exit 0; node -e "fetch(\\"https://registry.npmjs.org/left-pad\\").then(r => process.exit(r.ok ? 0 : 1), () => process.exit(1))"'
        c nope -m 30 https://example.com/
        echo done > res/IDONE
        sleep 600
        """)
        r = run("netreal", "i.sh")
        check(r.code == 0 && t.waitFor(120) { FileManager.default.fileExists(atPath: net + "/res/IDONE") }, "[FENCE_NET] a fenced session on the real internet")
        check(code("gh").hasPrefix("200") || code("gh").hasPrefix("30"), "[FENCE_NET] curl https://github.com (Standard: GitHub) — \(code("gh"))")
        check(res("py") == 0, "[FENCE_NET] Python urllib → PyPI")
        check(res("git") == 0, "[FENCE_NET] git ls-remote over https")
        check(res("node") == 0, "[FENCE_NET] Node fetch with NODE_USE_ENV_PROXY (or no node here)")
        check(code("nope").hasSuffix(" 403"), "[FENCE_NET] example.com (not in Standard) refused — \(code("nope"))")
        t.run(["sessions", "end", "@mac", "netreal", "--yes"], timeout: 60)
        started.remove("netreal")
    } else {
        print("  SKIP  the real internet through the proxy (FENCE_NET=1 runs it)")
    }
}

/// 2.16: the host runs from a COPY of doz (beside it deckhold-mac); a fenced session streams a 20 s download and makes a
/// request every 200 ms; the copy is replaced by rename; the old host hands over (drains while holding daemon.lock), the new
/// one adopts — the download completes, every request is answered 200, never two hosts, no hand-over file.
func fenceHandOver(_ t: CLIHarness, root: String, net: String, binary: String, store: String, sites: String, allowed: FenceUpstream,
                   started: inout Set<String>) async {
    let bin2 = root + "/bin2"
    try? FileManager.default.createDirectory(atPath: bin2, withIntermediateDirectories: true)
    guard let holder = MacDeckhold.locate(executable: binary).url else { check(false, "2.16 deckhold-mac beside doz"); return }
    do {
        try FileManager.default.copyItem(atPath: binary, toPath: bin2 + "/doz")
        try FileManager.default.copyItem(atPath: holder.path, toPath: bin2 + "/deckhold-mac")
    } catch { check(false, "2.16 a copy of doz to replace: \(error)"); return }
    _ = t.run(["daemon", "stop"], timeout: 60)
    let t2 = CLIHarness(binary: bin2 + "/doz", store: URL(fileURLWithPath: store))
    t2.env = t.env
    t2.env["DOZ_DAEMON_IDLE"] = "0.1"          // its idle loop looks every 1.5 s (a fenced session keeps it up regardless)
    let ho = net + "/ho"
    try? FileManager.default.removeItem(atPath: ho)
    FileManager.default.createFile(atPath: net + "/ho.sh", contents: Data("""
    mkdir -p ho
    ( curl -s -m 90 http://stream.doz.test/s > ho/stream.txt; echo $? > ho/stream.rc ) &
    i=0
    while [ $i -lt 250 ]; do
      ( curl -s -o /dev/null -m 90 -w '%{http_code}\\n' http://allowed.doz.test/h$i >> ho/codes ) &
      i=$((i+1)); sleep 0.2
    done
    wait; echo done > ho/DONE; sleep 600

    """.utf8))
    let r = t2.run(["run", "@mac", "-d", "--fenced", "--session", "ho", "--workdir", net, "--permissions", sites, "--", "/bin/sh", "ho.sh"], timeout: 90)
    if r.code == 0 { started.insert("ho") }
    check(r.code == 0, "2.16 a fenced session from the copy's host, streaming a 20 s download and asking every 200 ms")
    guard let oldHost = t2.hostPID() else { check(false, "2.16 the copy's daemon runs"); return }
    usleep(1_500_000)
    // The update: the copy replaced by rename (the running host keeps its own file).
    do {
        try FileManager.default.copyItem(atPath: binary, toPath: bin2 + "/.doz.new")
        _ = rename(bin2 + "/.doz.new", bin2 + "/doz")
    } catch { check(false, "2.16 replace the copy: \(error)") }
    check(t.waitFor(90) { kill(oldHost, 0) != 0 }, "2.16 the old daemon hands over and exits (pid \(oldHost))")
    check(t.waitFor(120) { FileManager.default.fileExists(atPath: ho + "/DONE") }, "2.16 the session's requests all finished")
    let codes = ((try? String(contentsOfFile: ho + "/codes", encoding: .utf8)) ?? "").split(separator: "\n")
    check(codes.count == 250 && codes.allSatisfy { $0 == "200" }, "2.16 every request answered 200 — the ones during the pause waited (\(codes.filter { $0 == "200" }.count)/\(codes.count))")
    let stream = (try? String(contentsOfFile: ho + "/stream.txt", encoding: .utf8)) ?? ""
    let rc = ((try? String(contentsOfFile: ho + "/stream.rc", encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    check(rc == "0" && stream.hasSuffix("line 39\n"), "2.16 the open 20 s download completed across the hand-over (rc \(rc), \(stream.split(separator: "\n").count) lines)")
    let newHost = t2.hostPID()
    check(newHost != nil && newHost != oldHost, "2.16 a new daemon serves (pid \(newHost.map(String.init) ?? "none"))")
    let log = (try? String(contentsOfFile: store + "/daemon.log", encoding: .utf8)) ?? ""
    let handed = log.range(of: "handing them to a new daemon")
    let drained = log.range(of: "the new daemon takes over", options: .backwards)
    let newStart = newHost.flatMap { log.range(of: "(pid \($0)) — store") }          // its own first line, once it has the lock
    check(handed != nil && drained != nil && newStart != nil && drained!.lowerBound < newStart!.lowerBound,
          "2.16 never two hosts: the old one drained and exited before the new one began (daemon.log order)")
    let names = (try? FileManager.default.subpathsOfDirectory(atPath: store)) ?? []
    check(!names.contains { $0.contains("handover") }, "2.16 no hand-over file anywhere in the store")
    check(t2.json(["sessions", "@mac"], [SessionRow].self)?.first { $0.name == "ho" }?.fence?.network == "proxy", "2.16 the session is adopted, its proxy served")
    t2.run(["sessions", "end", "@mac", "ho", "--yes"], timeout: 60)
    started.remove("ho")
    t2.run(["daemon", "stop"], timeout: 60)
    _ = allowed
}

/// A session's tag, from the store's record (the test runs outside every fence).
func sessionTagOf(_ store: String, _ s: String) -> String? {
    guard let d = FileManager.default.contents(atPath: store + "/mac-sessions/sessions.json"),
          let r = try? HostWire.decoder.decode(MacSessionRecords.self, from: d) else { return nil }
    return r.sessions[s]?.fence?.tag
}

/// `doz sessions @mac`'s state words for a row, as the CLI prints them (a nil row: "").
enum MacCLIState {
    static func state(_ s: SessionRow?) -> String {
        guard let s else { return "" }
        var t = s.ended ? "ended" : "running"
        if let f = s.fence {
            t += " · " + f.state
            if !s.ended, f.network == "waiting (no daemon)" { t += " · network waiting (no daemon)" }
        }
        return t
    }
}
