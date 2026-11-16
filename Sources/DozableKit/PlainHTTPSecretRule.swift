import Foundation

// 692: the ONE exception to "a credential placeholder never travels over plain HTTP" (`EgressProxy.plainHTTP`). A launch
// secret (`--secret VAR,src=PATH,to=HOST:PORT`) is swapped on a plain-HTTP request only when ALL of these hold:
//   (a) every placeholder the request carries is a launch secret's (`secret:VAR`) — an Anthropic, GitHub, OpenAI or any
//       other placeholder beside it keeps the old refusal;
//   (b) the vault swaps it for exactly that host and port (the leak guard: another host, port or the route's alias → 403);
//   (c) `network.placeholders_plain_http` was on when the secret was bound (`CredentialBinding.plainHTTP`);
//   (d) the destination is this Mac's route (`host.dozable.internal`, dialled at 127.0.0.1 by `macRoute`), or a Tailscale
//       address — 100.64.0.0/10, judged on EVERY address the dial resolves and dials (`Wire.connectTCPGuarded(require:)`),
//       and only while THIS Mac has an interface address in that range itself (Tailscale is up here; otherwise the range
//       may be a carrier's network).
// Everything else is refused, and a refusal never names a value.

/// 692: Tailscale's address range, 100.64.0.0/10 (also carrier-grade NAT space — hence the "this Mac is on it" rule).
public enum TailscaleRange {
    public static let cidr = "100.64.0.0/10"

    /// Whether `ip` (4 bytes, network order) is in 100.64.0.0/10.
    public static func contains(_ ip: [UInt8]) -> Bool { ip.count == 4 && ip[0] == 100 && (ip[1] & 0xC0) == 0x40 }

    /// The same for a dotted IPv4 literal (false for anything else).
    public static func contains(literal s: String) -> Bool { ipv4Bytes(s).map(contains) ?? false }

    /// A dotted IPv4 literal's 4 bytes (nil: not one) — the proxy's own parser.
    public static func ipv4Bytes(_ s: String) -> [UInt8]? {
        guard let v = IPv4CIDR.parseAddress(s) else { return nil }
        return [UInt8(v >> 24), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)]
    }

    /// Whether this Mac is on a Tailscale network now: one of its interface addresses (`own`) is in the range. Pure.
    public static func macIsOn(_ own: Set<[UInt8]>) -> Bool { own.contains(where: contains) }
}

/// 692: the plain-HTTP decision for the placeholders one request carries — pure (the vault's swap and the dial come after).
public enum PlainHTTPSecretRule {
    public enum Verdict: Equatable, Sendable {
        /// A placeholder of another binding (not a launch secret's): the old refusal, unchanged.
        case notSecrets
        /// A placeholder the vault does not know (revoked, or never issued): the vault's leak guard answers.
        case unknown
        /// Refused before anything is swapped or dialled — the reason.
        case refuse(String)
        /// May be swapped (the vault decides host and port); `tailscale`: dial only addresses in 100.64.0.0/10.
        case swap(tailscale: Bool)
    }

    /// What a refusal under (c) or (d) says.
    public static func message(host: String, port: UInt16) -> String {
        "a secret's placeholder is never sent over plain HTTP to \(host):\(port) — only to this Mac's ports (\(HostRoute.hostName)) or a "
            + "Tailscale address (\(TailscaleRange.cidr)) while network.placeholders_plain_http is on; use https"
    }

    /// Why a Tailscale destination is refused while this Mac is not on Tailscale.
    public static let notOnTailscale = "this Mac is not on a Tailscale network now"

    /// `bindings`: the binding of each placeholder the request carries (nil: unknown or revoked). `throughSeam`: a guarded
    /// test seam carries the connection (only an IPv4 literal can then qualify as Tailscale — a name is never resolved).
    public static func judge(bindings: [CredentialBinding?], host: String, port: UInt16, macOnTailscale: Bool,
                             throughSeam: Bool = false) -> Verdict {
        if bindings.contains(where: { $0 != nil && $0?.isLaunchSecret != true }) { return .notSecrets }
        if bindings.contains(where: { $0 == nil }) { return .unknown }
        let h = host.lowercased()
        guard bindings.allSatisfy({ $0?.plainHTTP == true }) else { return .refuse(message(host: h, port: port)) }
        // (d) this Mac's route: `macRoute` allowed the connection already (a refused port never gets here); the vault then
        // checks the name and the port (the alias is not the secret's host).
        if HostRoute.isHost(h) { return .swap(tailscale: false) }
        if IPv4CIDR.parseAddress(h) != nil {
            guard TailscaleRange.contains(literal: h) else { return .refuse(message(host: h, port: port)) }
        } else {
            // A name: only a plain DNS name (never an IPv6 literal); its every address is judged at the dial.
            guard !h.contains(":"), !h.contains("["), !throughSeam else { return .refuse(message(host: h, port: port)) }
        }
        guard macOnTailscale else { return .refuse(message(host: h, port: port) + " (" + notOnTailscale + ")") }
        return .swap(tailscale: true)
    }
}
