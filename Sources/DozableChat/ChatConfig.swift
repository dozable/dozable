import Darwin
import Foundation

// The chat server's one input: config.json. It holds no secret. The keys are the protocol's (its storage section) plus
// `agent_addresses`; the loader is STRICT — an unknown key, a value of the wrong type, an address that is not one, a
// non-loopback `test_owned_addresses` entry, or a feature this server does not have (a peer name, HTTPS) is a fault the
// server reports in one line and exits 78 for, because a restart cannot fix it.

/// A fault in the configuration or the start: one line, never a secret.
public struct ChatConfigError: Error, Sendable, Equatable, CustomStringConvertible {
    public var description: String
    public init(_ d: String) { description = d }
}

public struct ChatConfig: Sendable, Equatable {
    public var linePort = 8765
    public var httpPort = 8780
    public var dataDir = ""
    public var tokenService = "dozable-chat"
    public var defaultRoom = "general"
    public var participants: [ChatParticipant] = []
    /// Room name → members, in the order the file lists them.
    public var rooms: [String: [String]] = [:]
    public var allow: [String] = []
    public var requireTokens = false
    public var requireTokensFrom: [String] = []
    public var agentRunCap = 0
    public var secretsFileOnly = false
    public var testOwnedAddresses: [String] = []
    /// Addresses (or CIDR prefixes) whose callers are never the human: the page port serves them only the token-checked
    /// /agent/ calls, and the line port always asks them for a token. It overrides being owned.
    public var agentAddresses: [String] = []
    public var bind = ""
    /// This Mac's own Tailscale addresses the server ALSO listens on, both ports (Dozable's own key; the daemon writes it).
    /// Every connection accepted there is an agent (`ChatCaller.remote`). Only IPv4 in 100.64.0.0/10, only with
    /// `require_tokens`.
    public var remoteBind: [String] = []
    /// Asks (the protocol's section 13) are on unless this is true.
    public var noAsks = false
    /// How long an ask that names no expires_at stays open; 0 is the default, 24 hours.
    public var askExpirySeconds = 0
    /// How long after a decline or an expiry the same asker may not ask about the same thing again; 0 is the default, 10
    /// minutes; below 0 turns the cooldown off.
    public var askCooldownSeconds = 0
    /// How many open asks one asker may have in one room; 0 is the default, 1.
    public var askMaxOpen = 0
    /// The deprecated `experiments` object, still read so that a config written for an earlier release starts.
    public var experiments = LegacyExperiments()

    /// The deprecated `experiments` object: `ask: false` turns asks off; its three tuning values are used when the
    /// top-level one is not set.
    public struct LegacyExperiments: Sendable, Equatable {
        public var ask: Bool?
        public var askExpirySeconds = 0, askCooldownSeconds = 0, askMaxOpen = 0
        public init() {}
        var isSet: Bool { ask != nil || askExpirySeconds != 0 || askCooldownSeconds != 0 || askMaxOpen != 0 }
    }

    public init() {}

    /// Whether this server offers asks: on unless `no_asks` is set or the deprecated `experiments.ask` is false.
    public var asksOn: Bool { !noAsks && (experiments.ask ?? true) }
    /// The optional parts of the protocol this server offers, in a fixed order; never nil.
    public var features: [String] { asksOn ? ["ask"] : [] }
    private static func legacyOr(_ top: Int, _ legacy: Int) -> Int { top != 0 ? top : legacy }
    /// The ask settings with their defaults applied.
    public var askExpiry: Double {
        let s = Self.legacyOr(askExpirySeconds, experiments.askExpirySeconds)
        return s > 0 ? Double(s) : 24 * 3600
    }
    public var askCooldown: Double {
        let s = Self.legacyOr(askCooldownSeconds, experiments.askCooldownSeconds)
        return s < 0 ? 0 : (s > 0 ? Double(s) : 600)
    }
    public var askMaxOpenValue: Int {
        let n = Self.legacyOr(askMaxOpen, experiments.askMaxOpen)
        return n > 0 ? n : 1
    }
    /// The one line logged at start when the config still sets an ask key under the deprecated `experiments` object.
    public var deprecatedExperiments: String? {
        guard experiments.isSet else { return nil }
        return #"the config's "experiments" object is deprecated (still read): asks are on by default; use "no_asks": true to turn them off, "#
            + "and the top-level ask_expiry_seconds, ask_cooldown_seconds and ask_max_open instead of the ones under experiments"
    }

    /// Every key the file may have.
    public static let keys: Set<String> = [
        "line_port", "http_port", "data_dir", "token_service", "default_room", "participants", "rooms", "allow",
        "require_tokens", "require_tokens_from", "peer_name", "agent_run_cap", "https_port", "https_domain",
        "tailscale_command", "secrets_file_only", "test_owned_addresses", "agent_addresses", "bind", "no_loopback_agent",
        "remote_bind", "no_asks", "ask_expiry_seconds", "ask_cooldown_seconds", "ask_max_open", "experiments",
    ]

    /// Reads the config file.
    public static func load(path: String) throws -> ChatConfig {
        let data: Data
        do { data = try Data(contentsOf: URL(fileURLWithPath: path)) } catch {
            throw ChatConfigError("config: \(path) cannot be read")
        }
        return try parse(data)
    }

    public static func parse(_ data: Data) throws -> ChatConfig {
        let v: JValue
        do { v = try ChatJSON.parse(data) } catch { throw ChatConfigError("config: not valid JSON (\(error))") }
        guard case .object(let members) = v else { throw ChatConfigError("config: not a JSON object") }
        var c = ChatConfig()
        for m in members where !keys.contains(m.key) { throw ChatConfigError("config: unknown key \"\(m.key)\"") }
        func get<T>(_ k: String, _ read: (JValue) throws -> T) throws -> T? {
            guard let f = members.last(where: { $0.key == k })?.value else { return nil }
            do { return try read(f) } catch { throw ChatConfigError("config \(k): \(error)") }
        }
        if let n = try get("line_port", { try $0.goInt("line_port") }) { c.linePort = n }
        if let n = try get("http_port", { try $0.goInt("http_port") }) { c.httpPort = n }
        if let s = try get("data_dir", { try $0.goString("data_dir") }) { c.dataDir = s }
        if let s = try get("token_service", { try $0.goString("token_service") }) { c.tokenService = s }
        if let s = try get("default_room", { try $0.goString("default_room") }) { c.defaultRoom = s }
        if let s = try get("participants", { v -> [ChatParticipant] in
            switch v {
            case .null: return []
            case .array(let a): return try a.map { try ChatParticipant.read($0, strict: true) }
            default: throw ChatFieldError(description: "not an array")
            }
        }) { c.participants = s }
        if let r = try get("rooms", { v -> [String: [String]] in
            switch v {
            case .null: return [:]
            case .object(let ms):
                var out: [String: [String]] = [:]
                for m in ms { out[m.key] = try m.value.goStrings("rooms.\(m.key)") }
                return out
            default: throw ChatFieldError(description: "not an object")
            }
        }) { c.rooms = r }
        if let a = try get("allow", { try $0.goStrings("allow") }) { c.allow = a }
        if let b = try get("require_tokens", { try $0.goBool("require_tokens") }) { c.requireTokens = b }
        if let a = try get("require_tokens_from", { try $0.goStrings("require_tokens_from") }) { c.requireTokensFrom = a }
        if let n = try get("agent_run_cap", { try $0.goInt("agent_run_cap") }) { c.agentRunCap = n }
        if let b = try get("secrets_file_only", { try $0.goBool("secrets_file_only") }) { c.secretsFileOnly = b }
        if let a = try get("test_owned_addresses", { try $0.goStrings("test_owned_addresses") }) { c.testOwnedAddresses = a }
        if let a = try get("agent_addresses", { try $0.goStrings("agent_addresses") }) { c.agentAddresses = a }
        if let s = try get("bind", { try $0.goString("bind") }) { c.bind = s }
        if let a = try get("remote_bind", { try $0.goStrings("remote_bind") }) { c.remoteBind = a }
        if let b = try get("no_asks", { try $0.goBool("no_asks") }) { c.noAsks = b }
        if let n = try get("ask_expiry_seconds", { try $0.goInt("ask_expiry_seconds") }) { c.askExpirySeconds = n }
        if let n = try get("ask_cooldown_seconds", { try $0.goInt("ask_cooldown_seconds") }) { c.askCooldownSeconds = n }
        if let n = try get("ask_max_open", { try $0.goInt("ask_max_open") }) { c.askMaxOpen = n }
        if let e = try get("experiments", { v -> LegacyExperiments in
            var e = LegacyExperiments()
            switch v {
            case .null: return e
            case .object(let ms):
                let known: Set<String> = ["ask", "ask_expiry_seconds", "ask_cooldown_seconds", "ask_max_open"]
                if let bad = ms.first(where: { !known.contains($0.key) }) { throw ChatFieldError(description: "unknown key \"\(bad.key)\"") }
                if let a = v.field("ask"), !a.isNull { e.ask = try a.goBool("ask") }
                e.askExpirySeconds = try v.field("ask_expiry_seconds")?.goInt("ask_expiry_seconds") ?? 0
                e.askCooldownSeconds = try v.field("ask_cooldown_seconds")?.goInt("ask_cooldown_seconds") ?? 0
                e.askMaxOpen = try v.field("ask_max_open")?.goInt("ask_max_open") ?? 0
                return e
            default: throw ChatFieldError(description: "not an object")
            }
        }) { c.experiments = e }
        // The reference's keys for what this server does not do: accepted only when they ask for nothing.
        if let s = try get("peer_name", { try $0.goString("peer_name") }), !s.isEmpty {
            throw ChatConfigError("config peer_name: \"\(s)\" — this server is not a Claude Code peer; leave it empty")
        }
        if let n = try get("https_port", { try $0.goInt("https_port") }), n != 0 {
            throw ChatConfigError("config https_port: \(n) — this server has no HTTPS listener (HTTPS goes in front of it); use 0")
        }
        if let s = try get("https_domain", { try $0.goString("https_domain") }), !s.isEmpty {
            throw ChatConfigError("config https_domain: this server has no HTTPS listener; leave it empty")
        }
        _ = try get("tailscale_command", { try $0.goString("tailscale_command") })   // never run: ownership is configured
        _ = try get("no_loopback_agent", { try $0.goBool("no_loopback_agent") })
        return c
    }

    /// The settings of `doz chat serve` that are not in the config: each beats the file's value.
    public struct Overrides: Sendable, Equatable {
        public var dataDir: String?
        public var bind: String?
        public var linePort: Int?
        public var pagePort: Int?
        public init(dataDir: String? = nil, bind: String? = nil, linePort: Int? = nil, pagePort: Int? = nil) {
            self.dataDir = dataDir; self.bind = bind; self.linePort = linePort; self.pagePort = pagePort
        }
    }

    /// The config file read, the flags applied, and every check passed.
    public static func resolve(path: String, _ o: Overrides) throws -> ChatConfig {
        try apply(o, to: try load(path: path))
    }

    /// The same from the config's bytes (a reload hashes what it read before it judges it).
    public static func resolve(data: Data, _ o: Overrides) throws -> ChatConfig {
        try apply(o, to: try parse(data))
    }

    static func apply(_ o: Overrides, to loaded: ChatConfig) throws -> ChatConfig {
        var c = loaded
        if let d = o.dataDir { c.dataDir = d }
        if let b = o.bind { c.bind = b }
        if let n = o.linePort { c.linePort = n }
        if let n = o.pagePort { c.httpPort = n }
        if !c.dataDir.isEmpty { c.dataDir = URL(fileURLWithPath: c.dataDir).standardizedFileURL.path }
        try c.check()
        return c
    }

    /// The checks every config passes, after the flags are applied as well.
    public func check() throws {
        for (k, n) in [("line_port", linePort), ("http_port", httpPort)] where !(0...65535).contains(n) {
            throw ChatConfigError("config \(k): \(n) is not a port (0 to 65535)")
        }
        if linePort != 0 && linePort == httpPort {
            throw ChatConfigError("config: the line port and the page port are both \(linePort)")
        }
        for e in requireTokensFrom where ChatAddressPrefix(e) == nil {
            throw ChatConfigError("config require_tokens_from: \"\(e)\" is not an IP address or CIDR range")
        }
        for e in agentAddresses where ChatAddressPrefix(e) == nil {
            throw ChatConfigError("config agent_addresses: \"\(e)\" is not an IP address or CIDR range")
        }
        for p in participants where ChatProtocol.reservedNames.contains(p.name) {
            throw ChatConfigError("config participants: \(goQuote(p.name)) is a reserved name (the chat server writes its own lines under it); rename that participant")
        }
        for e in testOwnedAddresses {
            guard let a = ChatAddress(e.trimmingCharacters(in: .whitespaces)), a.isLoopback else {
                throw ChatConfigError("config test_owned_addresses: \"\(e)\" is not a loopback address (it is for tests on this Mac only)")
            }
        }
        for e in allow where ChatAddress(e) == nil {
            throw ChatConfigError("config allow: \"\(e)\" is not an IP address")
        }
        var names = Set<String>()
        for p in participants {
            guard !p.name.isEmpty else { throw ChatConfigError("config participants: an entry has no name") }
            guard names.insert(p.name).inserted else { throw ChatConfigError("config participants: \(p.name) is listed twice") }
            // No deliver value: a participant that is not the human collects its messages by polling (`route`).
            guard ["", "web", "inbox-socket", "webhook", "poll"].contains(p.deliver) else {
                throw ChatConfigError("config participants: \(p.name) has the delivery \"\(p.deliver)\" (web, inbox-socket, webhook, poll, or none)")
            }
        }
        for r in rooms.keys where !chatIsRoomName(r) {
            throw ChatConfigError("config rooms: \"\(r)\" is not a room name (lower-case letters, digits, - and _)")
        }
        if let why = Self.remoteBindRefusal(remoteBind, requireTokens: requireTokens) { throw ChatConfigError(why) }
        if dataDir.isEmpty { throw ChatConfigError("config data_dir: no data folder (set data_dir, or pass --data-dir)") }
        if !secretsFileOnly {
            throw ChatConfigError("config secrets_file_only: must be true — this server reads tokens from its secrets file only")
        }
    }

    /// Why `remote_bind` cannot be used (nil: it can): each entry an IPv4 address in 100.64.0.0/10 (so never loopback,
    /// unspecified, multicast, link-local or a LAN address), listed once, and only with `require_tokens`.
    public static func remoteBindRefusal(_ list: [String], requireTokens: Bool) -> String? {
        guard !list.isEmpty else { return nil }
        guard requireTokens else { return "config remote_bind: needs require_tokens (every caller there is an agent with its own token)" }
        var seen = Set<String>()
        for e in list {
            guard let a = ChatAddress(e), a.bytes.count == 4, e == ChatAddress.text(a), ChatWebhookAddress.tailnet.contains(a) else {
                return "config remote_bind: \"\(e)\" is not a Tailscale address (100.64.0.0/10) — only this Mac's own Tailscale addresses are listened on besides loopback"
            }
            guard seen.insert(e).inserted else { return "config remote_bind: \(e) is listed twice" }
        }
        return nil
    }

    /// Who may call what, from this config.
    public var access: ChatAccess { ChatAccess(self) }
}

// MARK: - Addresses

/// An IP address, IPv4-mapped IPv6 unmapped to IPv4, zone dropped.
public struct ChatAddress: Sendable, Hashable {
    public let bytes: [UInt8]   // 4 or 16

    public init?(_ text: String) {
        var s = text
        if let pct = s.firstIndex(of: "%") { s = String(s[..<pct]) }   // a zone is dropped
        if s.isEmpty { return nil }
        var v4 = in_addr()
        if !s.contains(":") {
            guard inet_pton(AF_INET, s, &v4) == 1 else { return nil }
            bytes = withUnsafeBytes(of: v4.s_addr) { Array($0) }
            return
        }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, s, &v6) == 1 else { return nil }
        let b = withUnsafeBytes(of: v6) { Array($0) }
        if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xFF && b[11] == 0xFF { bytes = Array(b[12..<16]) } else { bytes = b }
    }

    init(bytes: [UInt8]) { self.bytes = bytes }

    /// Whether this is an IPv4-mapped form in the text: `::ffff:a.b.c.d`.
    static func is4in6(_ text: String) -> Bool {
        var v6 = in6_addr()
        guard text.contains(":"), inet_pton(AF_INET6, text, &v6) == 1 else { return false }
        let b = withUnsafeBytes(of: v6) { Array($0) }
        return b[0..<10].allSatisfy { $0 == 0 } && b[10] == 0xFF && b[11] == 0xFF
    }

    /// The dotted form of an IPv4 address (nil for IPv6).
    public static func text(_ a: ChatAddress) -> String? {
        a.bytes.count == 4 ? a.bytes.map(String.init).joined(separator: ".") : nil
    }

    public var isLoopback: Bool {
        if bytes.count == 4 { return bytes[0] == 127 }
        return bytes[0..<15].allSatisfy { $0 == 0 } && bytes[15] == 1
    }
}

/// An address or a CIDR range, as `require_tokens_from` and `agent_addresses` take them. A plain address is the range
/// of that address alone; `::ffff:10.0.0.0/104` means 10.0.0.0/8.
public struct ChatAddressPrefix: Sendable, Hashable {
    public let base: [UInt8]
    public let bits: Int

    public init?(_ text: String) {
        let e = text.trimmingCharacters(in: .whitespaces)
        if let slash = e.firstIndex(of: "/") {
            let addr = String(e[..<slash]), n = String(e[e.index(after: slash)...])
            guard !addr.contains("%"), let a = ChatAddress(addr), let bits = Int(n), n.allSatisfy(\.isNumber) else { return nil }
            let full = ChatAddress.is4in6(addr) ? 128 : a.bytes.count * 8
            guard (0...full).contains(bits) else { return nil }
            let effective = ChatAddress.is4in6(addr) ? max(bits - 96, 0) : bits
            base = Self.masked(a.bytes, effective); self.bits = effective
        } else {
            guard let a = ChatAddress(e) else { return nil }
            base = a.bytes; bits = a.bytes.count * 8
        }
    }

    static func masked(_ b: [UInt8], _ bits: Int) -> [UInt8] {
        var out = b
        for i in 0..<out.count {
            let keep = max(0, min(8, bits - i * 8))
            out[i] &= keep == 8 ? 0xFF : UInt8(truncatingIfNeeded: 0xFF << (8 - keep))
        }
        return out
    }

    public func contains(_ a: ChatAddress) -> Bool {
        a.bytes.count == base.count && Self.masked(a.bytes, bits) == base
    }
}

// MARK: - Who may call what

/// The access rules of the page port and the line port, as one pure decision each.
public struct ChatAccess: Sendable {
    public let owned: [ChatAddress]
    public let allow: [String]
    public let requireTokens: Bool
    public let requireTokensFrom: [ChatAddressPrefix]
    public let agentAddresses: [ChatAddressPrefix]

    public init(_ c: ChatConfig) {
        owned = c.testOwnedAddresses.compactMap { ChatAddress($0.trimmingCharacters(in: .whitespaces)) }.filter(\.isLoopback)
        allow = c.allow
        requireTokens = c.requireTokens
        requireTokensFrom = c.requireTokensFrom.compactMap(ChatAddressPrefix.init)
        agentAddresses = c.agentAddresses.compactMap(ChatAddressPrefix.init)
    }

    /// The 403 text for a caller that is not one of the owner's own machines.
    public static let notOwned = "only the owner's own tailnet machines may connect"
    /// The 403 text for a caller that is served only the /agent/ calls.
    public static let agentOnly = "this machine must use a token: only /agent/ calls are served to it"
    /// The 403 text for such a caller whose `Authorization` carries a token no participant holds (`ChatPageHandler.agentRefusal`).
    public static let unknownToken = "that token is no one's here: an agent machine must send its own participant's token"

    /// One of the addresses whose callers are never the human. An address that cannot be read is one: the safe answer.
    public func isAgentAddress(_ ip: String) -> Bool {
        guard !agentAddresses.isEmpty else { return false }
        guard let a = ChatAddress(ip) else { return true }
        return agentAddresses.contains { $0.contains(a) }
    }

    /// One of the owner's own machines. Only the configured loopback addresses are; an agent address never is.
    public func isOwned(_ ip: String) -> Bool {
        guard let a = ChatAddress(ip), !isAgentAddress(ip) else { return false }
        return owned.contains(a)
    }

    /// On `require_tokens_from`. An address that cannot be read counts as listed.
    public func needsToken(_ ip: String) -> Bool {
        guard !requireTokensFrom.isEmpty else { return false }
        guard let a = ChatAddress(ip) else { return true }
        return requireTokensFrom.contains { $0.contains(a) }
    }

    /// The page port: nil serves the request; otherwise the 403 text it is answered with.
    public func page(remote ip: String, agentPath: Bool) -> String? {
        if isAgentAddress(ip) { return agentPath ? nil : Self.agentOnly }
        if !isOwned(ip) { return Self.notOwned }
        if needsToken(ip) && !agentPath { return Self.agentOnly }
        return nil
    }

    /// The line port: nil closes the connection at once; otherwise whether a token is required on it.
    public func line(remote ip: String) -> Bool? {
        let own = isOwned(ip)
        guard own || allow.contains(ip) else { return nil }
        return requireTokens || !own || needsToken(ip) || isAgentAddress(ip)
    }
}

// MARK: - The path of an /agent/ call

public enum ChatPath {
    /// Whether a request is, exactly as it would be routed, a call under /agent/: anything a router would clean or
    /// redirect (`..`, `.`, `//`, a different case) is not followed but refused.
    public static func isAgentPath(rawPath: String) -> Bool {
        let decoded = percentDecoded(rawPath) ?? rawPath
        return decoded.hasPrefix("/agent/") && rawPath.hasPrefix("/agent/") && clean(decoded) == decoded && !decoded.contains("//")
    }

    /// Whether a request is, exactly as it would be routed, `/files/<id>/<name>`: the id 16 or 32 lower-case hex digits, a
    /// name, and nothing a router would clean or redirect.
    public static func isFilePath(rawPath: String) -> Bool {
        guard rawPath.hasPrefix("/files/"), let decoded = percentDecoded(rawPath), decoded.hasPrefix("/files/") else { return false }
        guard clean(decoded) == decoded, !decoded.contains("//") else { return false }
        let parts = decoded.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0].isEmpty, parts[1] == "files" else { return false }
        let id = parts[2], name = parts[3]
        guard id.count == 16 || id.count == 32, id.utf8.allSatisfy({ (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }) else { return false }
        return !name.isEmpty && name != "." && name != ".."
    }

    /// The path with %XX decoded; nil when an escape is malformed.
    public static func percentDecoded(_ s: String) -> String? {
        guard s.contains("%") else { return s }
        return s.removingPercentEncoding
    }

    /// Go's `path.Clean`: one slash between elements, no `.`, `..` resolved, no trailing slash (but "/").
    public static func clean(_ p: String) -> String {
        if p.isEmpty { return "." }
        let rooted = p.hasPrefix("/")
        var out: [Substring] = []
        for part in p.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." {
                if let last = out.last, last != ".." { out.removeLast() } else if !rooted { out.append(part) }
                continue
            }
            out.append(part)
        }
        let joined = out.joined(separator: "/")
        if rooted { return "/" + joined }
        return joined.isEmpty ? "." : joined
    }
}
