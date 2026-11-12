import Darwin
import DozableKit
import Foundation

/// A fenced session's network: the ONLY outbound connection its profile allows is `localhost:<its port>`, a socket
/// on this Mac's loopback that the host binds at open and its holder holds for the session's life
/// (`deckhold-mac serve --hold-fd 3`); the host serves it with an `EgressProxy` of its own (`MacFenceProxy`), judged by
/// the sandboxes' permissions (`AgentPermissions`, the `mac` base — `macPreset`), with the strict address guard
/// (`AddressGuard.strict`: never this Mac's own addresses, link-local or metadata, whatever the permissions). DNS is
/// closed inside the fence: the proxy resolves names on the Mac. A host that starts later takes the socket from the
/// holder (`DeckholdSocket.heldSocket`, GETFD); while no host runs, connections wait in the socket's backlog.
public enum MacFenceNetwork {
    /// Bind `127.0.0.1:0` (never SO_REUSEPORT/SO_REUSEADDR: nobody may share the port) and listen: the descriptor and
    /// its port. The caller passes it to the holder and keeps its own.
    public static func bindLoopback() throws -> (fd: Int32, port: UInt16) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HostError(.failed, "a fenced session's proxy socket: \(String(cString: strerror(errno)))") }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = 0
        a.sin_addr.s_addr = inet_addr("127.0.0.1")
        let ok = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } == 0
        guard ok, listen(fd, 128) == 0, let port = port(of: fd) else {
            let e = String(cString: strerror(errno))
            close(fd)
            throw HostError(.failed, "a fenced session's proxy socket on 127.0.0.1: \(e)")
        }
        return (fd, port)
    }

    /// The local port of a bound socket.
    public static func port(of fd: Int32) -> UInt16? {
        var a = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } } == 0
        return ok && a.sin_family == sa_family_t(AF_INET) ? UInt16(bigEndian: a.sin_port) : nil
    }

    /// The policy a fenced session starts with: `words` (`doz create --permissions`'s — standard, locked, open,
    /// PERMISSION, -PERMISSION, site:HOST) from this Mac's Standard. Unknown words are refused.
    public static func policy(words: [String]) throws -> NetworkPolicy {
        var names: [String] = []
        var sites: [String] = []
        for w in words.flatMap({ $0.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) } }) where !w.isEmpty {
            if w.hasPrefix("site:") {
                let h = String(w.dropFirst(5)).lowercased()
                guard !h.isEmpty, !h.contains("/"), !h.contains(" ") else { throw HostError(.invalid, "--permissions \(w): site:HOST") }
                sites.append(h)
                continue
            }
            let id = w.hasPrefix("-") || w.hasPrefix("+") ? String(w.dropFirst()) : w
            guard ["standard", "locked", "open", "agent"].contains(w) || AgentPermissions.isValid(id) || id == "install" else {
                throw HostError(.invalid, "--permissions \(w): no such permission or preset — doz net permissions lists them (standard, locked, open)")
            }
            names.append(w == "agent" ? "standard" : w)
        }
        let set = PermissionPolicy.names(from: names, base: AgentPermissions.macBase, start: AgentPermissions.macPreset("standard"))
        var p = NetworkPolicy.permissions(set, preset: AgentPermissions.presetName(set, base: AgentPermissions.macBase))
        for h in sites { p.allow(host: h, note: "site you allowed") }
        return p
    }

    /// Whether `p` keeps certificate trust (trustd) open — closed under Locked (only the model).
    public static func trust(_ p: NetworkPolicy) -> Bool {
        AgentPermissions.presetName(p.permissions ?? [], base: AgentPermissions.macBase) != "locked" || !p.rules.isEmpty
    }

    /// TEST SEAM (guarded runs only): `DOZ_TEST_FENCE_UPSTREAMS=name=127.0.0.1:PORT,…` — names whose upstream is a fake on
    /// this Mac's loopback.
    public static func upstreamsForTests(_ env: [String: String]) -> [String: EgressProxy.UpstreamAddress] {
        guard TestSafety.guarded(env), let s = env["DOZ_TEST_FENCE_UPSTREAMS"] else { return [:] }
        var out: [String: EgressProxy.UpstreamAddress] = [:]
        for item in s.split(separator: ",") {
            let kv = item.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { continue }
            let hp = kv[1].split(separator: ":").map(String.init)
            guard hp.count == 2, hp[0] == "127.0.0.1", let port = UInt16(hp[1]) else { continue }
            out[kv[0].lowercased()] = EgressProxy.UpstreamAddress(host: hp[0], port: port)
        }
        return out
    }

    /// The system's trust store as PEM (`/etc/ssl/cert.pem` — what curl, Python and git read on macOS), for the session's
    /// CA bundle.
    static func systemBundle() -> String {
        guard let d = FileManager.default.contents(atPath: "/private/etc/ssl/cert.pem"), d.count <= 4 << 20 else { return "" }
        return String(decoding: d, as: UTF8.self)
    }

    /// The session's CA (`<store>/mac-sessions/fence/NAME/egress-ca*.pem`, the key never leaves the store) — and its copies
    /// in the session's `etc/` (0444, host-owned: write- and unlink-denied in the profile): `ca.pem`, `ca-bundle.pem`
    /// (the system's roots + it).
    static func writeCA(_ ca: SandboxCA, etc: String) throws {
        try MacFenceHostFS.writeAtomically(Data(ca.certificatePEM.utf8), dir: etc, name: "ca.pem", mode: 0o444)
        var bundle = systemBundle()
        if !bundle.isEmpty, !bundle.hasSuffix("\n") { bundle += "\n" }
        try MacFenceHostFS.writeAtomically(Data((bundle + ca.certificatePEM).utf8), dir: etc, name: "ca-bundle.pem", mode: 0o444)
    }
}

/// One fenced session's proxy in this host: its `EgressProxy` (policy, log, CA, the strict guard) on the session's
/// loopback socket (`LoopbackProxyListener`).
final class MacFenceProxy: @unchecked Sendable {
    let session: String
    let port: UInt16
    let proxy: EgressProxy
    let listener: LoopbackProxyListener

    init(session: String, fd: Int32, port: UInt16, policy: NetworkPolicy, secretSHA256: String, ca: SandboxCA?,
         environment: [String: String]) throws {
        self.session = session
        self.port = port
        proxy = try EgressProxy(policy: policy, ca: ca)
        proxy.addressGuard = .strict
        proxy.fenceUpstreamsForTests = MacFenceNetwork.upstreamsForTests(environment)
        listener = LoopbackProxyListener(fd: fd, proxy: proxy, secretSHA256: secretSHA256)
        listener.onNote = { HostLog.line("@mac \(session): \($0)") }
    }

    func start() { listener.start() }

    /// The end of the session (or this host): stop, cut what is open.
    func stop() { listener.drain(timeout: 0) }
}
