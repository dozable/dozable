import CryptoKit
import Darwin
import Foundation

// Tokens and webhook entries. In this milestone they come from ONE place: a secrets file (`secrets.json` version 1, the
// shape the reference's file store reads — `{"version":1,"tokens":{name:token},"webhooks":{name:{"url","header"}}}`),
// read once at start, mode 0600 and the user's own. A token is kept only as its SHA-256: it is hashed as the file is read
// and the plain value is dropped. Nothing here is ever logged; an error names the file and the problem, never a value.
// No Keychain, no other source.

public struct ChatWebhook: Sendable, Equatable {
    public var url: String
    public var header: String
    public init(url: String, header: String) { self.url = url; self.header = header }
}

public struct ChatSecrets: Sendable {
    /// Participant name → SHA-256 hex of its token.
    public private(set) var tokenHashes: [String: String] = [:]
    /// Webhook name → its address and the exact Authorization value to send.
    public private(set) var webhooks: [String: ChatWebhook] = [:]

    public init() {}

    /// The fewest characters a token may have.
    public static let minimumTokenLength = 16

    public static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Reads a secrets file. Refused: a missing or unreadable file, one that is not a regular file, one others can read,
    /// one of another owner, and one that is not version 1 of the shape.
    public static func load(path: String) throws -> ChatSecrets {
        var st = stat()
        guard lstat(path, &st) == 0 else { throw ChatConfigError("secrets file: \(path) does not exist or cannot be read") }
        guard (st.st_mode & S_IFMT) == S_IFREG else { throw ChatConfigError("secrets file: \(path) is not a regular file") }
        if st.st_mode & 0o077 != 0 {
            throw ChatConfigError(String(format: "secrets file: %@ can be read by other users (mode %04o); fix it with: chmod 600 %@",
                                         path, Int(st.st_mode & 0o777), path))
        }
        guard st.st_uid == getuid() else {
            throw ChatConfigError("secrets file: \(path) is owned by another user; it must belong to the user that runs the server")
        }
        guard let fh = FileHandle(forReadingAtPath: path) else { throw ChatConfigError("secrets file: cannot read \(path)") }
        defer { try? fh.close() }
        let data = (try? fh.read(upToCount: 4 << 20)) ?? Data()
        return try parse(data, path: path)
    }

    public static func parse(_ data: Data, path: String = "the secrets file") throws -> ChatSecrets {
        let shape = ChatConfigError("secrets file: \(path) is not valid JSON of the expected shape")
        guard let v = try? ChatJSON.parse(data), v.isObject else { throw shape }
        guard let version = try? v.field("version")?.goInt("version") else { throw shape }
        guard version == 1 else {
            throw ChatConfigError("secrets file: \(path) is version \(version), which this server does not read (it reads version 1)")
        }
        var s = ChatSecrets()
        switch v.field("tokens") ?? .null {
        case .null: break
        case .object(let m):
            for e in m {
                guard case .string(let t) = e.value else { throw shape }
                if !t.isEmpty { s.tokenHashes[e.key] = hash(t) }
            }
        default: throw shape
        }
        switch v.field("webhooks") ?? .null {
        case .null: break
        case .object(let m):
            for e in m {
                guard e.value.isObject,
                      let url = try? e.value.field("url")?.goString("url") ?? "",
                      let header = try? e.value.field("header")?.goString("header") ?? "" else { throw shape }
                s.webhooks[e.key.isEmpty ? "default" : e.key] = ChatWebhook(url: url, header: header)
            }
        default: throw shape
        }
        return s
    }

    /// The name a presented token belongs to among `names`, or nil. Compared in constant time, on the hashes.
    public func whoHas(_ token: String, among names: [String]) -> String? {
        guard token.utf8.count >= Self.minimumTokenLength else { return nil }
        let want = Self.hash(token)
        var found: String?
        for n in names {
            if let have = tokenHashes[n], Self.constantTimeEqual(have, want) { found = n }
        }
        return found
    }

    public func hasToken(_ name: String) -> Bool { tokenHashes[name] != nil }

    /// The webhook a participant's entry name points to: its own entry when it has an address, else the shared one
    /// ("default"); nil when neither has an address. The header is the Authorization value without an
    /// "Authorization:" prefix and trimmed, as the reference sends it.
    public func webhook(for entry: String) -> ChatWebhook? {
        func usable(_ k: String) -> ChatWebhook? {
            guard let w = webhooks[k], !w.url.isEmpty else { return nil }
            return ChatWebhook(url: w.url, header: Self.trimAuthorization(w.header))
        }
        if entry.isEmpty || entry == Self.sharedWebhook { return usable(Self.sharedWebhook) }
        return usable(entry) ?? usable(Self.sharedWebhook)
    }

    /// The entry every bot without one of its own is sent to.
    public static let sharedWebhook = "default"

    static func trimAuthorization(_ s: String) -> String {
        let t = s.lowercased().hasPrefix("authorization:") ? String(s.dropFirst("authorization:".count)) : s
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var d: UInt8 = 0
        for i in 0..<x.count { d |= x[i] ^ y[i] }
        return d == 0
    }
}
