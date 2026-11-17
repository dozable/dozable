import CryptoKit
import DozableChat
import Foundation

// A webhook bot's entry under the daemon (docs/engineering/chat.md, "Under the daemon"): the address its calls go to and
// the Authorization value they carry. ONE login keychain item per entry, through the keychain seam (`KeychainAccess`;
// the memory one in every test), written on `security -i`'s standard input; handed to the chat server on a pipe at each
// start (`ChatWebhookPipe`). Never in a file, a log, `supervisor.json`, `--json` or argv. Set only through the daemon's
// socket, by this user on this Mac — no web action, no setting, no environment value reaches it.

/// One entry as it is kept (the keychain item's value: JSON, at most `Keychain.maximumSecretBytes`).
public struct ChatWebhookEntry: Codable, Equatable, Sendable {
    public var url: String
    /// Sent as `Authorization: <value>` verbatim; empty: no header.
    public var authorization: String
    /// When it was set (ISO 8601).
    public var set: String

    public init(url: String, authorization: String, set: String) { self.url = url; self.authorization = authorization; self.set = set }

    /// 12 hex of sha256(address, a newline, the value): tells two entries apart, shows neither.
    public var fingerprint: String {
        SHA256.hash(data: Data((url + "\n" + authorization).utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }
}

/// What a person may see of an entry (`doz chat webhook status`): never its path, query or header.
public struct ChatWebhookInfo: Codable, Equatable, Sendable {
    public var entry: String
    /// set · not set · unreadable
    public var state: String
    public var scheme: String?
    public var host: String?
    public var port: Int?
    public var fingerprint: String?
    public var setAt: String?
    /// Why it cannot be read (the keychain is locked, …).
    public var problem: String?
    /// The participants that use it.
    public var usedBy: [String]

    public init(entry: String, state: String, usedBy: [String]) { self.entry = entry; self.state = state; self.usedBy = usedBy }
}

public enum ChatWebhookEntries {
    public static let servicePrefix = "doz-chat-webhook-"

    /// The keychain item of `entry` for the store whose chat folder is `paths` (the store's id as launch secrets have it).
    public static func service(_ paths: ChatPaths, entry: String) -> String {
        let store = (paths.folder as NSString).deletingLastPathComponent
        let digest = SHA256.hash(data: Data(URL(fileURLWithPath: store).standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
        return servicePrefix + digest.prefix(8) + "-" + entry
    }

    /// Why `name` cannot be an entry's name: the session-name rule, and never `default` (no shared entry nobody chose).
    public static func nameRefusal(_ name: String) -> String? {
        if name == ChatSecrets.sharedWebhook { return "\(name) is not an entry name here (each bot has its own, or one named for it)" }
        guard chatIsSessionName(name) else { return "\(name) is not an entry name: a lower-case letter, then lower-case letters, digits and -, at most 40" }
        return nil
    }

    public static func encode(_ e: ChatWebhookEntry) throws -> String {
        let v = JValue.object([JMember("authorization", .string(e.authorization)), JMember("set", .string(e.set)), JMember("url", .string(e.url))])
        let s = String(decoding: ChatJSON.encode(v), as: UTF8.self)
        guard s.utf8.count <= Keychain.maximumSecretBytes else {
            throw HostError(.invalid, "the address and the Authorization value together are too long for one keychain item (at most \(Keychain.maximumSecretBytes) bytes)")
        }
        return s
    }

    public static func decode(_ s: String) -> ChatWebhookEntry? {
        guard let v = try? ChatJSON.parse(Data(s.utf8)), v.isObject,
              let url = try? v.field("url")?.goString("url"), let auth = try? v.field("authorization")?.goString("authorization") ?? "" else { return nil }
        let set = ((try? v.field("set")?.goString("set")) ?? nil) ?? ""
        return ChatWebhookEntry(url: url, authorization: auth, set: set)
    }

    /// The pipe's bytes: `{"version":1,"webhooks":{NAME:{"url","header"}}}`, names in order.
    public static func pipeBytes(_ entries: [String: ChatWebhookEntry]) -> Data {
        var hooks: [JMember] = []
        for k in entries.keys.sorted() {
            let e = entries[k]!
            hooks.append(JMember(k, .object([JMember("header", .string(e.authorization)), JMember("url", .string(e.url))])))
        }
        return Data(ChatJSON.encode(.object([JMember("version", .int(1)), JMember("webhooks", .object(hooks))])))
    }

    /// Two lines: the address, then the Authorization value (empty: none). A third line is refused; a final newline is fine.
    public static func parseInput(_ data: Data) throws -> (url: String, authorization: String) {
        guard data.count <= 4096 else { throw HostError(.invalid, "the input is longer than 4096 bytes") }
        var text = String(decoding: data, as: UTF8.self)
        if text.hasSuffix("\n") { text.removeLast() }
        if text.hasSuffix("\r") { text.removeLast() }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { $0.hasSuffix("\r") ? String($0.dropLast()) : String($0) }
        guard (1...2).contains(lines.count), !lines[0].isEmpty else {
            throw HostError(.invalid, "give two lines: the address, then the Authorization value (an empty second line: no header)")
        }
        return (lines[0].trimmingCharacters(in: .whitespaces), lines.count > 1 ? lines[1] : "")
    }
}
