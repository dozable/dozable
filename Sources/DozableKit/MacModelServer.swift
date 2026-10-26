import Foundation

// 660 (618.B4, owner: "go"): Claude Code — or any agent whose models@1 names it natively — with a model server on THIS
// Mac (Ollama, LM Studio, llama.cpp's llama-server, LiteLLM, vLLM, oMLX), reached from the sandbox through the host
// proxy. A proxied sandbox has no NIC; the proxy runs on the Mac, so a connection it makes to 127.0.0.1 IS the Mac's
// loopback. The rule (docs/manual/32-models-on-this-mac.md, `EgressProxy.macModelPort`):
//
//   - the guest names the Mac by ONE name, `mac.dozable.internal`, which the proxy answers and routes to 127.0.0.1:PORT
//     only for the port the sandbox was made with — never a policy rule (no preset or edit widens it);
//   - every other way to the Mac's loopback (127.0.0.0/8, ::1, 0.0.0.0 — by address or `localhost` through the proxy)
//     is refused to every sandbox, whatever its policy (`Wire.connectTCP`);
//   - the request is plain HTTP and carries no secret: the source takes no key (`ModelSources.isKeyless`), and the
//     proxy refuses a placeholder over plain HTTP.

public enum MacModelServer {
    /// The model source's id (`--provider local`).
    public static let sourceID = "local"
    public static let title = "A model server on this Mac"
    /// The name the guest reaches this Mac's server by (`.internal`: reserved for private use, never on the internet).
    public static let hostName = "mac.dozable.internal"
    /// What the proxy's DNS answers for it — an address nothing else uses (198.18.0.0/15, RFC 2544), so a client that
    /// ignores the proxy settings still arrives (redirected TCP) and is recognised by the name it resolved.
    public static let syntheticAddress: UInt32 = 0xC612_FFFE          // 198.18.255.254
    /// What Claude Code is given for its bearer token: a fixed, non-secret word — it wants one, the local servers ignore
    /// it (Ollama's own Claude Code page sets `ANTHROPIC_AUTH_TOKEN=ollama`). Never a key: nothing of the person's.
    public static let noKeyWord = "dozable-no-key"
    /// The ports a person may name: unprivileged only.
    public static let ports: ClosedRange<Int> = 1024...65_535

    public static func isHost(_ host: String) -> Bool {
        host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) == hostName
    }

    public static func baseURL(port: Int) -> String { "http://\(hostName):\(port)" }

    /// Why `port` cannot be named (nil: it can).
    public static func portProblem(_ port: Int?) -> String? {
        guard let port else { return "which port does the model server on this Mac listen on? (--local-port N — Ollama 11434, LM Studio 1234)" }
        guard ports.contains(port) else { return "a port of this Mac from \(ports.lowerBound) to \(ports.upperBound) (the model server's)" }
        return nil
    }

    /// One known server — what the plan, the dashboard and the manual list. `native: false` = it needs a translator
    /// (not offered yet; `reason` says why).
    public struct Server: Sendable, Equatable, Codable {
        public var id: String
        public var title: String
        public var port: Int
        public var native: Bool
        public var since: String?
        public var reason: String?
        public var source: String
    }

    /// Checked 2026-10-27 against each server's docs (workspace `changes/660-*/660.01-PLAN-MODELS.md`).
    public static let servers: [Server] = [
        Server(id: "ollama", title: "Ollama", port: 11434, native: true, since: "0.14.0", reason: nil,
               source: "https://docs.ollama.com/api/anthropic-compatibility"),
        Server(id: "lm-studio", title: "LM Studio", port: 1234, native: true, since: "0.4.1", reason: nil,
               source: "https://lmstudio.ai/docs/developer/anthropic-compat"),
        Server(id: "llama-server", title: "llama.cpp (llama-server)", port: 8080, native: true, since: "PR #17570 (2025-11-28)", reason: nil,
               source: "https://github.com/ggml-org/llama.cpp/pull/17570"),
        Server(id: "litellm", title: "LiteLLM proxy", port: 4000, native: true, since: nil, reason: nil,
               source: "https://docs.litellm.ai/docs/anthropic_unified"),
        Server(id: "vllm", title: "vLLM", port: 8000, native: true, since: nil, reason: nil,
               source: "https://docs.vllm.ai/en/latest/serving/online_serving/"),
        Server(id: "omlx", title: "oMLX", port: 8000, native: true, since: nil, reason: nil,
               source: "https://github.com/jundot/omlx"),
        Server(id: "mlx-lm", title: "mlx-lm (mlx_lm.server)", port: 8080, native: false, since: nil,
               reason: "it speaks OpenAI's chat API only — Claude Code needs Anthropic's Messages API, so it needs a translator (not yet)",
               source: "https://github.com/ml-explore/mlx-lm/blob/main/mlx_lm/SERVER.md"),
    ]

    /// Whether something on this Mac accepts a connection on 127.0.0.1:`port` (`doz doctor`; nothing is sent).
    public static func answers(port: Int, timeoutMS: Int32 = 500) -> Bool {
        guard let p = UInt16(exactly: port) else { return false }
        let fd = Wire.connectTCP("127.0.0.1", p, timeoutMS: timeoutMS, allowLoopback: true)
        guard fd >= 0 else { return false }
        close(fd)
        return true
    }

    /// Whether `host` (a name or an address) resolves, on this Mac, to a loopback or unspecified address.
    public static func resolvesToLoopback(_ host: String) -> Bool {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: IPPROTO_TCP,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &res) == 0, let first = res else { return false }
        defer { freeaddrinfo(first) }
        var ai: UnsafeMutablePointer<addrinfo>? = first
        while let a = ai {
            if let sa = a.pointee.ai_addr, let b = LocalDashboards.bytes(UnsafePointer(sa)), isLoopbackOrUnspecified(b) { return true }
            ai = a.pointee.ai_next
        }
        return false
    }

    /// Whether `addr` (an IPv4 or IPv6 address's bytes) is a loopback or unspecified address — this Mac's own, which no
    /// sandbox reaches except through the named port.
    static func isLoopbackOrUnspecified(_ ip: [UInt8]) -> Bool {
        if ip.count == 4 { return ip[0] == 127 || ip == [0, 0, 0, 0] }
        // An IPv4-mapped IPv6 address (::ffff:a.b.c.d) is its IPv4 address — ::ffff:127.0.0.1 IS the loopback on macOS.
        if ip.count == 16, ip[0..<10].allSatisfy({ $0 == 0 }), ip[10] == 0xFF, ip[11] == 0xFF { return isLoopbackOrUnspecified(Array(ip[12..<16])) }
        if ip.count == 16 { return ip == [UInt8](repeating: 0, count: 15) + [1] || ip.allSatisfy { $0 == 0 } }
        return false
    }
}
