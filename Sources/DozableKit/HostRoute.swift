import Foundation

// 691: the route to THIS computer's ports — the one deliberate way through the strict address guard besides the test
// seams. A sandbox or a fenced `@mac` session is given a LIST of this Mac's ports (`--host-port PORT[:tag]`, the
// permission `host:PORT`, and the model server's port of `--provider local --local-port N`); it reaches each as
// `host.dozable.internal:PORT` (or the older name `mac.dozable.internal:PORT` — the same route), and the proxy dials
// 127.0.0.1:PORT — never `localhost`, never another address of this Mac, never by a redirect. Nothing else of this Mac
// opens: an address of it typed directly (127.0.0.1, its LAN or Tailscale address) is refused even for a port in the
// list, because only the NAME is the route. Never a policy rule: no preset widens it and Open does not include it.

/// One port of this Mac a sandbox or a fenced session may reach (`EgressProxy.hostPorts`).
public struct HostPort: Codable, Equatable, Hashable, Sendable {
    /// Where it came from: given at launch (`--host-port`, `host_ports:`, `--permissions host:PORT`), the model server
    /// the sandbox was made with (`--provider local --local-port N` — it belongs to the model source), or added live
    /// (`doz net allow NAME host:PORT`).
    public enum Origin: String, Codable, Sendable {
        case launch, model, live
    }
    public var port: UInt16
    /// Plain-HTTP requests through the route carry `X-Dozable-Session` naming the sandbox or session (`PORT:tag`).
    public var tag: Bool
    public var origin: Origin

    public init(port: UInt16, tag: Bool = false, origin: Origin = .launch) {
        self.port = port
        self.tag = tag
        self.origin = origin
    }

    /// `8780` or `8780:tag` — what `--host-port` takes and `doz net show` prints.
    public var word: String { tag ? "\(port):tag" : String(port) }
}

public enum HostRoute {
    /// The name a sandbox or a fenced session reaches this Mac's ports by (`.internal`: reserved for private use).
    public static let hostName = "host.dozable.internal"
    /// Both names of the route: the new one and the model server's older one (an alias — the same list).
    public static let names = [hostName, MacModelServer.hostName]
    /// The header a tagged port's plain-HTTP requests carry (identification, not authentication).
    public static let sessionHeader = "X-Dozable-Session"
    /// The most ports one sandbox or session may have open (launch and live together; the model server's included).
    public static let maximumPorts = 16

    /// Whether `host` is one of the route's names (case and a trailing dot ignored).
    public static func isHost(_ host: String) -> Bool {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return h == hostName || h == MacModelServer.hostName
    }

    // MARK: ports that are never opened

    nonisolated(unsafe) private static var provider: (@Sendable () -> Set<UInt16>)?
    private static let lock = NSLock()
    nonisolated(unsafe) private static var registered: [UInt16: Int] = [:]

    /// The daemon's own listeners beyond the dashboards (`LocalDashboards`): set once by the daemon (nil: none).
    public static func protect(_ ports: (@Sendable () -> Set<UInt16>)?) {
        lock.lock(); provider = ports; lock.unlock()
    }

    /// A proxy's own listening port (a fenced session's) while it is served — never a port of the route.
    public static func registerOwn(_ port: UInt16) {
        lock.lock(); registered[port, default: 0] += 1; lock.unlock()
    }

    public static func unregisterOwn(_ port: UInt16) {
        lock.lock()
        if let n = registered[port] { if n <= 1 { registered[port] = nil } else { registered[port] = n - 1 } }
        lock.unlock()
    }

    /// Every port of Dozable's own on this Mac now: the dashboards (`doz ui`, `doz serve`), every proxy's own port, and
    /// what the daemon protects besides.
    public static var ownPorts: Set<UInt16> {
        lock.lock(); let p = provider; let r = Set(registered.keys); lock.unlock()
        return LocalDashboards.ports.union(r).union(p?() ?? [])
    }

    /// Why `port` can never be opened to a sandbox or a session (nil: it can) — checked when a port is granted AND at each
    /// connection (a dashboard may start later on a port that was granted). Port 0 and the privileged ports are refused
    /// (`MacModelServer.portProblem`'s range), and every listener of Dozable's own.
    public static func refusal(port: Int) -> String? {
        if port == 0 { return "port 0 is not a port of a service" }
        guard MacModelServer.portProblem(port) == nil else {
            return "port \(port): a port of this Mac from \(MacModelServer.ports.lowerBound) to \(MacModelServer.ports.upperBound)"
        }
        if ownPorts.contains(UInt16(port)) { return "port \(port) is Dozable's own (a dashboard or a proxy) — never opened to a sandbox or a session" }
        return nil
    }

    // MARK: words

    /// One `--host-port` value: `8780` or `8780:tag`. Checked for its form and range only (`refusal` is the daemon's).
    public static func parsePort(_ s: String) -> Result<HostPort, ParseError> {
        let form = "a port of this Mac (1024–65535), or PORT:tag to name the session to it — 8780, 8780:tag"
        let parts = s.lowercased().split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard (1...2).contains(parts.count), parts.count == 1 || parts[1] == "tag" else { return .failure(ParseError("\(s): \(form)")) }
        let w = parts[0]
        guard !w.isEmpty, w.count <= 5, w.allSatisfy({ $0 >= "0" && $0 <= "9" }), let n = Int(w) else { return .failure(ParseError("\(s): \(form)")) }
        guard n != 0, MacModelServer.portProblem(n) == nil else { return .failure(ParseError("\(s): \(form)")) }
        return .success(HostPort(port: UInt16(n), tag: parts.count == 2))
    }

    /// A permission word `host:PORT`, `host:PORT:tag` or `host:P1,P2` (the tag then applies to each) — the ports, or why not.
    public static func parseWord(_ s: String) -> Result<[HostPort], ParseError> {
        let form = "host:PORT — host:8780, host:8780:tag, host:8780,8781"
        guard s.lowercased().hasPrefix("host:") else { return .failure(ParseError("\(s): \(form)")) }
        var body = String(s.dropFirst(5)).lowercased()
        var tag = false
        if body.hasSuffix(":tag") { tag = true; body = String(body.dropLast(4)) }
        let words = body.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard !words.isEmpty, words.count <= maximumPorts else { return .failure(ParseError("\(s): at most \(maximumPorts) ports — \(form)")) }
        var out: [HostPort] = []
        for w in words {
            guard case .success(var p) = parsePort(w) else { return .failure(ParseError("\(s): \"\(w)\" is not a port of this Mac (1024–65535) — \(form)")) }
            p.tag = tag
            if !out.contains(where: { $0.port == p.port }) { out.append(p) }
        }
        return .success(out)
    }

    /// Whether a permission word is a `host:` word.
    public static func isWord(_ s: String) -> Bool { s.lowercased().hasPrefix("host:") }

    public struct ParseError: Error, Sendable, CustomStringConvertible {
        public var description: String
        public init(_ d: String) { description = d }
    }

    // MARK: what a person reads

    /// "8780 (named), 11434 (model server)" — the list as `doz net show` prints it ("none" when empty).
    public static func listText(_ ports: [HostPort]) -> String {
        guard !ports.isEmpty else { return "none" }
        return ports.sorted { $0.port < $1.port }.map { p in
            var notes: [String] = []
            if p.tag { notes.append("named") }
            if p.origin == .model { notes.append("model server") }
            return notes.isEmpty ? String(p.port) : "\(p.port) (\(notes.joined(separator: ", ")))"
        }.joined(separator: ", ")
    }

    /// "8780, 11434" or "8780".
    static func numbers(_ ports: [UInt16]) -> String { ports.sorted().map(String.init).joined(separator: ", ") }

    /// A list merged with a change: `add` (each replaces the same port's launch or live entry — never the model server's),
    /// `remove` ports (never the model server's — it belongs to the model source). Sorted by port.
    public static func merged(_ list: [HostPort], add: [HostPort] = [], remove: [UInt16] = []) -> [HostPort] {
        var byPort: [UInt16: HostPort] = [:]
        for p in list { byPort[p.port] = p }
        for p in add {
            if let have = byPort[p.port], have.origin == .model { byPort[p.port]?.tag = p.tag; continue }
            byPort[p.port] = p
        }
        for r in remove where byPort[r]?.origin != .model { byPort[r] = nil }
        return byPort.values.sorted { $0.port < $1.port }
    }
}
