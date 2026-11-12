import Darwin
import Foundation

/// Which RESOLVED addresses the egress proxy refuses to dial, whatever the policy says — checked in `Wire.connectTCP` on
/// the address it is about to connect to (it resolves once and dials what it checked), so a name that resolves to one
/// of these is refused as surely as the address typed.
///
/// - `loopback` — what every proxied sandbox has had (660): this Mac's loopback and the unspecified address.
/// - `strict` — a fenced session on this Mac: also link-local (169.254/16 — cloud metadata at 169.254.169.254 — and
///   fe80::/10), multicast and the broadcast address, 0/8, the IPv6 forms that carry an IPv4 address (mapped,
///   compatible, NAT64 64:ff9b::/96 — the address inside is judged), site-local fec0::/10, NAT64's local-use
///   64:ff9b:1::/48, and EVERY address of this Mac's own interfaces (read with `getifaddrs`, at most every 5 s). The
///   program runs on this Mac, so any of these reaches the Mac itself or its link, never the internet. No rule widens it.
public enum AddressGuard: String, Codable, Sendable {
    case loopback
    case strict

    /// Why `ip` (4 or 16 bytes, network order) is refused, or nil.
    public func refusal(_ ip: [UInt8]) -> String? {
        switch self {
        case .loopback:
            return MacModelServer.isLoopbackOrUnspecified(ip) ? "this Mac's own loopback" : nil
        case .strict:
            return Self.strictRefusal(ip, own: Self.interfaceAddresses())
        }
    }

    /// The strict rule against `own` (this Mac's interface addresses) — pure, for tests.
    public static func strictRefusal(_ ip: [UInt8], own: Set<[UInt8]>) -> String? {
        if ip.count == 16, let v4 = embeddedIPv4(ip) {
            if let why = strictRefusal(v4, own: own) { return why + " (inside an IPv6 address)" }
        }
        if ip.count == 4 {
            if ip[0] == 127 { return "this Mac's own loopback" }
            if ip[0] == 0 { return "the unspecified network (0.0.0.0/8)" }
            if ip[0] == 169 && ip[1] == 254 { return "a link-local address (169.254.0.0/16 — cloud metadata among them)" }
            if ip[0] >= 224 && ip[0] <= 239 { return "a multicast address" }
            if ip == [255, 255, 255, 255] { return "the broadcast address" }
        } else if ip.count == 16 {
            if ip.allSatisfy({ $0 == 0 }) { return "the unspecified address (::)" }
            if ip == [UInt8](repeating: 0, count: 15) + [1] { return "this Mac's own loopback (::1)" }
            if ip[0] == 0xFE && (ip[1] & 0xC0) == 0x80 { return "a link-local address (fe80::/10)" }
            if ip[0] == 0xFE && (ip[1] & 0xC0) == 0xC0 { return "a site-local address (fec0::/10)" }
            if ip[0] == 0xFF { return "a multicast address" }
            if Array(ip[0..<6]) == [0x00, 0x64, 0xFF, 0x9B, 0x00, 0x01] { return "a NAT64 local-use address (64:ff9b:1::/48)" }
        } else {
            return "an address of an unknown family"
        }
        if own.contains(ip) { return "an address of this Mac's own (its interfaces)" }
        return nil
    }

    /// The IPv4 address an IPv6 address carries: mapped (::ffff:a.b.c.d), compatible (::a.b.c.d, never :: or ::1),
    /// NAT64's well-known prefix (64:ff9b::a.b.c.d).
    static func embeddedIPv4(_ ip: [UInt8]) -> [UInt8]? {
        guard ip.count == 16 else { return nil }
        let tail = Array(ip[12..<16])
        if ip[0..<10].allSatisfy({ $0 == 0 }), ip[10] == 0xFF, ip[11] == 0xFF { return tail }
        if ip[0..<12].allSatisfy({ $0 == 0 }), !(tail == [0, 0, 0, 0] || tail == [0, 0, 0, 1]) { return tail }
        if Array(ip[0..<12]) == [0x00, 0x64, 0xFF, 0x9B, 0, 0, 0, 0, 0, 0, 0, 0] { return tail }
        return nil
    }

    // MARK: this Mac's addresses

    nonisolated(unsafe) private static var cached: (at: Date, addresses: Set<[UInt8]>)?
    private static let cacheLock = NSLock()

    /// Every address of this Mac's interfaces (IPv4 as 4 bytes, IPv6 as 16 — a scope id is not part of it), read again
    /// at most every 5 s. A failed read gives nil… never: it gives what was read last (an empty set at worst — the other
    /// rules still hold).
    public static func interfaceAddresses(now: Date = Date()) -> Set<[UInt8]> {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let c = cached, now.timeIntervalSince(c.at) < 5 { return c.addresses }
        var out: Set<[UInt8]> = []
        var list: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&list) == 0, let first = list {
            var p: UnsafeMutablePointer<ifaddrs>? = first
            while let i = p {
                if let sa = i.pointee.ifa_addr {
                    switch Int32(sa.pointee.sa_family) {
                    case AF_INET:
                        out.insert(sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { s in withUnsafeBytes(of: s.pointee.sin_addr.s_addr) { Array($0) } })
                    case AF_INET6:
                        out.insert(sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { s in withUnsafeBytes(of: s.pointee.sin6_addr) { Array($0) } })
                    default: break
                    }
                }
                p = i.pointee.ifa_next
            }
            freeifaddrs(first)
        } else if let c = cached {
            out = c.addresses
        }
        cached = (now, out)
        return out
    }

    /// The bytes of a socket address (IPv4: 4, IPv6: 16 — kept as IPv6, mapped forms included, so `refusal` sees them).
    static func bytes(_ sa: UnsafePointer<sockaddr>) -> [UInt8]? {
        switch Int32(sa.pointee.sa_family) {
        case AF_INET: return sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { s in withUnsafeBytes(of: s.pointee.sin_addr.s_addr) { Array($0) } }
        case AF_INET6: return sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { s in withUnsafeBytes(of: s.pointee.sin6_addr) { Array($0) } }
        default: return nil
        }
    }
}
