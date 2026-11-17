import Darwin
import Foundation

// A bot's webhook entry under the daemon: where its calls go (an address) and the Authorization value they carry. The
// entry is the owner's to set, on this Mac only; it lives in the login keychain and reaches the server through a pipe
// (`--webhooks-fd`), never a file. Both sides judge it with the one rule here: the daemon when it is set, the server
// again when it arrives.

public enum ChatWebhookAddress {
    public static let maxURLBytes = 2048
    public static let maxHeaderBytes = 1024

    /// The words for an `http` address that is neither this Mac nor a Tailscale address.
    public static let plainHTTPRefusal = "plain http would carry the Authorization value and every message in the clear — only to this Mac or a Tailscale address; use https"

    /// The parts of an address a person may be shown: never its path, query or the header.
    public struct Parts: Equatable, Sendable {
        public var scheme: String
        public var host: String
        public var port: Int
        public init(scheme: String, host: String, port: Int) { self.scheme = scheme; self.host = host; self.port = port }
    }

    /// Why this entry is refused (nil: it may be used). Never quotes the address or the header back.
    public static func refusal(url: String, header: String) -> String? {
        if let why = refusal(url: url) { return why }
        if header.utf8.count > maxHeaderBytes { return "the Authorization value is longer than \(maxHeaderBytes) bytes" }
        if header.unicodeScalars.contains(where: { $0.value < 0x20 && $0 != "\t" || $0.value == 0x7F }) {
            return "the Authorization value has a line break or a control character"
        }
        return nil
    }

    public static func refusal(url: String) -> String? {
        if url.isEmpty { return "no address" }
        if url.utf8.count > maxURLBytes { return "the address is longer than \(maxURLBytes) bytes" }
        if url.unicodeScalars.contains(where: { $0.value <= 0x20 || $0.value >= 0x7F }) {
            return "the address has a space, a control character or a character outside ASCII (percent-encode it)"
        }
        guard let c = URLComponents(string: url), let scheme = c.scheme?.lowercased() else { return "the address is not a URL" }
        guard scheme == "https" || scheme == "http" else { return "the address must start with https:// (or http:// to this Mac or a Tailscale address)" }
        if c.user != nil || c.password != nil { return "the address may not carry a user or password (put the secret in the Authorization value)" }
        if c.fragment != nil { return "the address may not have a #fragment" }
        guard let parts = parts(url) else { return "the address has no host" }
        let ip = ChatAddress(parts.host)
        if scheme == "http" {
            if parts.host.lowercased() == "localhost" { return nil }
            guard let a = ip, a.isLoopback || tailnet.contains(a) else { return plainHTTPRefusal }
            return nil
        }
        if let a = ip, let why = unusable(a) { return "the address is \(why)" }
        return nil
    }

    /// Tailscale's IPv4 range (CGNAT).
    public static let tailnet = ChatAddressPrefix("100.64.0.0/10")!

    /// Why an IP literal can never be a webhook's host: unspecified, multicast, broadcast, link-local.
    static func unusable(_ a: ChatAddress) -> String? {
        let b = a.bytes
        if b.allSatisfy({ $0 == 0 }) { return "an unspecified address" }
        if b.count == 4 {
            if b == [255, 255, 255, 255] { return "a broadcast address" }
            if b[0] >= 224 && b[0] <= 239 { return "a multicast address" }
            if b[0] == 169 && b[1] == 254 { return "a link-local address" }
        } else {
            if b[0] == 0xFF { return "a multicast address" }
            if b[0] == 0xFE && (b[1] & 0xC0) == 0x80 { return "a link-local address" }
        }
        return nil
    }

    /// The scheme, host (an IPv6 literal without its brackets) and port of an address; nil when it has no host.
    public static func parts(_ url: String) -> Parts? {
        guard let c = URLComponents(string: url), let scheme = c.scheme?.lowercased(), var host = c.host, !host.isEmpty else { return nil }
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        return Parts(scheme: scheme, host: host, port: c.port ?? (scheme == "https" ? 443 : 80))
    }
}

/// The webhook entries the daemon hands its server on a pipe: `{"version":1,"webhooks":{NAME:{"url","header"}}}`. Read
/// once, at start, from a descriptor that must be a pipe; never written anywhere.
public enum ChatWebhookPipe {
    /// The most the pipe may carry.
    public static let maxBytes = 16 << 10

    /// What came, and the entries refused (by name, with why — never a value).
    public struct Read: Sendable, Equatable {
        public var webhooks: [String: ChatWebhook] = [:]
        public var refused: [String: String] = [:]
    }

    /// Reads the descriptor to its end (5 s at most, `maxBytes` at most) and closes it. A descriptor that is not a pipe,
    /// or one that does not end in time, is a fault.
    public static func read(fd: Int32, deadline seconds: Double = 5) throws -> Data {
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw ChatConfigError("--webhooks-fd \(fd): not an open descriptor") }
        guard (st.st_mode & S_IFMT) == S_IFIFO else { throw ChatConfigError("--webhooks-fd \(fd): not a pipe") }
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let until = Date().addingTimeInterval(seconds)
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let left = until.timeIntervalSinceNow
            guard left > 0 else { throw ChatConfigError("--webhooks-fd \(fd): the webhook entries did not arrive within \(Int(seconds)) s") }
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let r = poll(&p, 1, Int32(min(left, 1) * 1000))
            if r < 0 && errno == EINTR { continue }
            if r < 0 { throw ChatConfigError("--webhooks-fd \(fd): \(String(cString: strerror(errno)))") }
            if r == 0 { continue }
            let n = Darwin.read(fd, &buf, buf.count)
            if n < 0 && (errno == EAGAIN || errno == EINTR) { continue }
            if n < 0 { throw ChatConfigError("--webhooks-fd \(fd): \(String(cString: strerror(errno)))") }
            if n == 0 { return out }
            out.append(contentsOf: buf[0..<n])
            if out.count > maxBytes { throw ChatConfigError("--webhooks-fd \(fd): more than \(maxBytes >> 10) KiB of webhook entries") }
        }
    }

    /// The entries. A `tokens` member, or anything but the shape, is a fault; an entry whose address or header the rule
    /// refuses is dropped and named.
    public static func parse(_ data: Data) throws -> Read {
        let shape = ChatConfigError("--webhooks-fd: the webhook entries are not of the expected shape")
        guard let v = try? ChatJSON.parse(data), case .object(let members) = v else { throw shape }
        for m in members where !["version", "webhooks"].contains(m.key) {
            throw ChatConfigError("--webhooks-fd: \"\(m.key)\" is not taken here (only webhook entries come this way)")
        }
        guard (try? v.field("version")?.goInt("version")) == 1 else { throw shape }
        var out = Read()
        switch v.field("webhooks") ?? .null {
        case .null: break
        case .object(let es):
            for e in es {
                guard case .object(let fields) = e.value, fields.allSatisfy({ ["url", "header"].contains($0.key) }),
                      let url = try? e.value.field("url")?.goString("url") ?? "",
                      let header = try? e.value.field("header")?.goString("header") ?? "" else { throw shape }
                if !chatIsSessionName(e.key) || e.key == ChatSecrets.sharedWebhook {
                    out.refused[e.key.isEmpty ? "(no name)" : String(e.key.prefix(40))] = "not an entry name"
                    continue
                }
                if let why = ChatWebhookAddress.refusal(url: url, header: header) { out.refused[e.key] = why; continue }
                out.webhooks[e.key] = ChatWebhook(url: url, header: header)
            }
        default: throw shape
        }
        return out
    }
}
