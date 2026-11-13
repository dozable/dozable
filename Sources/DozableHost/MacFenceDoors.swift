import Darwin
import DozableKit
import Foundation

/// 683 M4: a fenced session's doors in the store's socket folder (0700, closed to every fence for reads and writes) —
/// unix sockets the host listens on and ONLY that session's profile may connect to (`(allow network-outbound (literal
/// …))`; a connect needs no file access):
///
/// - `NAME.agent` (`--ssh-agent`): each connection is relayed to the person's ssh-agent, FILTERED to list + sign
///   (`SSHAgentRelay.relayFiltered` — the sandboxes' rule: adding, removing, locking never reach it); the agent is looked
///   up at each connection (one started later is used).
/// - `NAME.gh` (`--github`): `gh`'s `http_unix_socket` — plain HTTP for GitHub's hosts, served by the session's proxy as
///   the inside of a decrypted tunnel (`EgressProxy.serveUnwrapped`): the swap, the read-only gate, the log.
///
/// A door lives as long as this host serves the session's proxy (`MacFenceProxy`): no host, no door (the program's
/// connection is refused and it says so).
final class MacFenceDoor: @unchecked Sendable {
    let path: String
    private let fd: Int32
    private let lock = NSLock()
    private var open = true
    /// At most this many connections at once (a door is one session's).
    static let maximumConnections = 32
    private var live = 0

    /// Listen at `path` (an earlier socket there — a host before this one — is replaced; anything else is refused).
    init(path: String, handle: @escaping @Sendable (Int32) -> Void) throws {
        self.path = path
        var st = stat()
        if lstat(path, &st) == 0 {
            guard (st.st_mode & S_IFMT) == S_IFSOCK, st.st_uid == getuid() else {
                throw HostError(.failed, "\(DisplayPath.tilde(path)) is there and is not this host's socket — not replaced")
            }
            unlink(path)
        }
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { throw HostError(.failed, "a fenced session's door: \(String(cString: strerror(errno)))") }
        _ = fcntl(s, F_SETFD, FD_CLOEXEC)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { close(s); throw HostError(.invalid, "\(path): too long for a socket") }
        withUnsafeMutableBytes(of: &addr.sun_path) { p in
            for (i, b) in bytes.enumerated() { p[i] = b }
            p[bytes.count] = 0
        }
        let old = umask(0o177)
        let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } } == 0
        umask(old)
        guard ok, listen(s, 16) == 0 else {
            let e = String(cString: strerror(errno))
            close(s)
            throw HostError(.failed, "a fenced session's door at \(DisplayPath.tilde(path)): \(e)")
        }
        chmod(path, 0o600)
        fd = s
        Thread.detachNewThread { [self] in
            while true {
                let c = accept(s, nil, nil)
                if c < 0 {
                    if errno == EINTR || errno == ECONNABORTED { continue }
                    return
                }
                guard lock.withLock({ () -> Bool in
                    guard open, live < Self.maximumConnections else { return false }
                    live += 1
                    return true
                }) else { close(c); continue }
                var one: Int32 = 1
                setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, 4)
                Thread.detachNewThread { [self] in
                    handle(c)
                    close(c)
                    lock.withLock { live -= 1 }
                }
            }
        }
    }

    /// Stop listening and take the socket away (only ours: the path is unlinked while it is still a socket).
    func stop() {
        let was: Bool = lock.withLock {
            let o = open
            open = false
            return o
        }
        guard was else { return }
        shutdown(fd, SHUT_RDWR)
        close(fd)
        var st = stat()
        if lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFSOCK { unlink(path) }
    }

    /// The ssh-agent door's work: one connection relayed, filtered, to the agent `upstream()` names now (none: closed).
    static func relayAgent(_ c: Int32, upstream: () -> String?) {
        guard let a = upstream() else { return }
        let u = SSHAgentRelay.connectUnix(a)
        guard u >= 0 else { return }
        defer { close(u) }
        var one: Int32 = 1
        setsockopt(u, SOL_SOCKET, SO_NOSIGPIPE, &one, 4)
        SSHAgentRelay.relayFiltered(guest: c, agent: u)
    }

    /// The person's ssh-agent for a fenced session's door: the host's `SSH_AUTH_SOCK` — in a guarded test run ONLY the
    /// throwaway `DOZ_TEST_SSH_AUTH_SOCK` (never the person's agent). Nil: none (a socket that is not there).
    static func agentSocket(_ env: [String: String]) -> String? {
        let p = TestSafety.guarded(env) ? env["DOZ_TEST_SSH_AUTH_SOCK"] : (env["DOZ_TEST_SSH_AUTH_SOCK"].flatMap { $0.isEmpty ? nil : $0 } ?? env["SSH_AUTH_SOCK"])
        guard let p, !p.isEmpty else { return nil }
        var st = stat()
        guard stat(p, &st) == 0, (st.st_mode & S_IFMT) == S_IFSOCK else { return nil }
        return p
    }
}

/// 683 M4: one fenced session's doors, opened by the host BEFORE its program starts (a program that asks at once finds
/// them listening) and closed with the session or this host's proxy for it. gh's door serves through the session's proxy
/// once this host has made it (`attach`) — a connection that arrives first waits for it (up to 10 s).
final class MacFenceDoorSet: @unchecked Sendable {
    private let lock = NSLock()
    private var proxy: EgressProxy?
    private var doors: [MacFenceDoor] = []

    init(session: String, agent: String?, upstream: @escaping @Sendable () -> String?, gh: String?) {
        if let a = agent {
            do { doors.append(try MacFenceDoor(path: a) { c in MacFenceDoor.relayAgent(c, upstream: upstream) }) }
            catch { HostLog.line("@mac \(session): its SSH agent door did not open (\(error))") }
        }
        if let g = gh {
            let hosts = Set(GitHubAccess.credentialHosts)
            do {
                doors.append(try MacFenceDoor(path: g) { [weak self] c in
                    guard let p = self?.waitForProxy(seconds: 10) else {
                        let b = Array("HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
                        _ = b.withUnsafeBytes { write(c, $0.baseAddress, $0.count) }
                        return
                    }
                    p.serveUnwrapped(c, hosts: hosts)
                })
            } catch { HostLog.line("@mac \(session): its GitHub door did not open (\(error))") }
        }
    }

    func attach(_ p: EgressProxy?) { lock.withLock { proxy = p } }

    private func waitForProxy(seconds: Double) -> EgressProxy? {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until {
            if let p = lock.withLock({ proxy }) { return p }
            usleep(50_000)
        }
        return nil
    }

    func close() {
        let all = lock.withLock { () -> [MacFenceDoor] in
            let d = doors
            doors = []
            proxy = nil
            return d
        }
        for d in all { d.stop() }
    }
}
