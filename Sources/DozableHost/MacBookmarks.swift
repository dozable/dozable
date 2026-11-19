import Darwin
import Foundation

// Your Macs: the other Macs' dashboards this one keeps a bookmark of (`doz ui macs`, the dashboard's machine picker).
//
// The list is one the person keeps — nothing is discovered (a name announced on a café network would be a phishing link
// under "Your Macs"). A bookmark is a NAME and an ORIGIN (`scheme://host[:port]`) and nothing else that a person gives:
// never a token, cookie, code or link. Opening one is a plain link to that origin, where that Mac's own sign-in applies;
// nothing of this Mac's travels. Whether it answered is known only when a person asks (`doz ui macs add`, `check`) —
// never the page, the daemon or a timer. `MacBookmarkTests`, `MacBookmarkStoreTests`, `MacReachabilityTests`.

/// One of your other Macs: its name here and its dashboard's origin, and what the last check found.
public struct MacBookmark: Codable, Equatable, Sendable {
    /// Its name in this list (`MacBookmarkName`): `^[a-z0-9][a-z0-9-]{0,31}$`.
    public var name: String
    /// Its dashboard's origin, exactly `scheme://host[:port]` (`MacAddress.origin`) — no path, query, fragment or login.
    public var origin: String
    public var addedAt: Date
    /// When a person last checked it, and when it last answered as a Dozable dashboard (kept when a later check fails).
    public var lastCheckAt: Date?
    public var lastSeenAt: Date?
    /// The last check's outcome (`MacReachability.Outcome`'s raw value).
    public var lastResult: String?
    /// The name its dashboard gave itself at the last check that reached it ("Dozable – m1mini" → `m1mini`).
    public var reportedName: String?
    /// Fields a newer doz wrote, kept as read.
    public var unknown = UnknownFields()
    /// Every key this build writes — `MacBookmarkTests` pins it (none can hold a secret).
    public static let known: Set<String> = ["name", "origin", "addedAt", "lastCheckAt", "lastSeenAt", "lastResult", "reportedName"]

    public init(name: String, origin: String, addedAt: Date) { self.name = name; self.origin = origin; self.addedAt = addedAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicKey.self)
        name = try c.decode(String.self, forKey: "name")
        origin = try c.decode(String.self, forKey: "origin")
        addedAt = try c.decode(Date.self, forKey: "addedAt")
        lastCheckAt = try c.decodeIfPresent(Date.self, forKey: "lastCheckAt")
        lastSeenAt = try c.decodeIfPresent(Date.self, forKey: "lastSeenAt")
        lastResult = try c.decodeIfPresent(String.self, forKey: "lastResult")
        reportedName = try c.decodeIfPresent(String.self, forKey: "reportedName")
        unknown = try UnknownFields(c, known: Self.known)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicKey.self)
        try unknown.encode(&c, known: Self.known)
        try c.encode(name, forKey: "name")
        try c.encode(origin, forKey: "origin")
        try c.encode(addedAt, forKey: "addedAt")
        try c.encodeIfPresent(lastCheckAt, forKey: "lastCheckAt")
        try c.encodeIfPresent(lastSeenAt, forKey: "lastSeenAt")
        try c.encodeIfPresent(lastResult, forKey: "lastResult")
        try c.encodeIfPresent(reportedName, forKey: "reportedName")
    }

    /// The outcome of a check, recorded: when, what, and — when it answered — when it was seen and the name it gave.
    public mutating func record(_ r: MacReachability.Result, at: Date) {
        lastCheckAt = at
        lastResult = r.outcome.rawValue
        if r.outcome == .reachable {
            lastSeenAt = at
            reportedName = r.reportedName
        }
    }
}

/// `<store>/macs.json`: `{version: 1, macs: [...]}` — additive, unknown fields kept, a newer version kept.
public struct MacsFile: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public var version: Int
    public var macs: [MacBookmark]
    public var unknown = UnknownFields()
    static let known: Set<String> = ["version", "macs"]

    public init(macs: [MacBookmark] = []) { version = Self.currentVersion; self.macs = macs }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicKey.self)
        version = try c.decodeIfPresent(Int.self, forKey: "version") ?? 1
        macs = try c.decodeIfPresent([MacBookmark].self, forKey: "macs") ?? []
        unknown = try UnknownFields(c, known: Self.known)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicKey.self)
        try unknown.encode(&c, known: Self.known)
        try c.encode(max(version, Self.currentVersion), forKey: "version")
        try c.encode(macs, forKey: "macs")
    }

    public func mac(_ name: String) -> MacBookmark? { macs.first { $0.name == name } }
}

/// A Mac's name in the list: a lower-case letter or digit, then lower-case letters, digits and -, at most 32.
public enum MacBookmarkName {
    public static let rule = "a Mac's name: 1–32 characters of a-z, 0-9 and -, starting with a letter or digit"

    public static func isValid(_ s: String) -> Bool {
        guard (1...32).contains(s.utf8.count), let first = s.utf8.first, first != 0x2D else { return false }
        return s.utf8.allSatisfy { ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2D }
    }

    /// Checked before anything is read or written; the refusal never echoes the name.
    public static func validate(_ s: String) throws {
        guard isValid(s) else { throw HostError(.invalid, rule) }
    }
}

/// A dashboard's origin: its scheme, host and port (`origin` the one string a link is made of).
public struct MacOrigin: Equatable, Sendable {
    public var scheme: String
    /// The host as written in a URL: a lower-case DNS name, an IPv4 literal, or a bracketed IPv6 literal.
    public var host: String
    public var port: Int
    public init(scheme: String, host: String, port: Int) { self.scheme = scheme; self.host = host; self.port = port }

    /// `scheme://host[:port]`, the port left out when it is the scheme's own (http 80, https 443).
    public var origin: String {
        (scheme == "http" && port == 80) || (scheme == "https" && port == 443) ? "\(scheme)://\(host)" : "\(scheme)://\(host):\(port)"
    }
    /// The page's address: the origin and `/` — nothing else, ever.
    public var link: String { origin + "/" }
    /// The host without brackets (what is shown).
    public var displayHost: String { host.hasPrefix("[") ? String(host.dropFirst().dropLast()) : host }
    /// This Mac's own loopback names.
    public var isLoopback: Bool { ["127.0.0.1", "localhost", "[::1]"].contains(host) }
}

/// What a person types as a Mac's ADDRESS → exactly one origin, or a refusal that never echoes what was typed.
///
/// Accepted: `host[:port]`, or `http(s)://host[:port]` with at most a `/` after it. A bare host is https when it ends in
/// `.ts.net` or its port is 443, else http; the port as written; no port → 7443 (the LAN dashboard's) over http, or 443 for
/// a `.ts.net` name (a dashboard published on Tailscale). A host is an LDH DNS name (≤ 253), an IPv4 literal or a bracketed
/// IPv6 literal. Refused before anything is written: a sign-in link (anything with `cap=` or `code=`), a login
/// (`user@`), a query, a fragment, a path other than `/`, > 512 characters, anything not ASCII or with a space, another
/// scheme, and this Mac's own dashboard (a loopback name on one of `thisMacPorts`; other loopback ports stay allowed — an
/// ssh tunnel).
public enum MacAddress {
    public static let maximumLength = 512
    public static let defaultPort = 7443

    public static let signInLinkRefusal = "That is a sign-in link. Give the address only (for example mini.example.ts.net:7443). "
        + "Then open it and sign in there with `doz ui share` on that Mac."

    public static func origin(_ input: String, thisMacPorts: Set<Int> = []) throws -> MacOrigin {
        func no(_ why: String) -> HostError { HostError(.invalid, why) }
        guard input.utf8.count <= maximumLength else { throw no("the address is too long: at most \(maximumLength) characters") }
        guard input.unicodeScalars.allSatisfy({ $0.isASCII }) else { throw no("the address must be plain ASCII (a host name or an IP address)") }
        let lower = input.lowercased()
        // Before anything else: a link that signs in is never kept, and never repeated back.
        if lower.contains("cap=") || lower.contains("code=") { throw no(signInLinkRefusal) }
        guard !input.unicodeScalars.contains(where: { $0.value <= 0x20 || $0.value == 0x7F }) else { throw no("the address has a space or a control character in it") }
        var rest = Substring(input)
        var scheme: String?
        if let r = rest.range(of: "://") {
            let s = rest[..<r.lowerBound].lowercased()
            guard s == "http" || s == "https" else { throw no("only an http:// or https:// address, or a host name") }
            scheme = s
            rest = rest[r.upperBound...]
        }
        if rest.contains("#") { throw no("an address has no # part — give the address only") }
        if rest.contains("?") { throw no("an address has no query (?…) — give the address only") }
        if rest.contains("@") { throw no("an address has no user name or password in it — give the address only") }
        if rest.contains("\\") { throw no("not an address") }
        if let slash = rest.firstIndex(of: "/") {
            guard rest[slash...] == "/" else { throw no("an address has no path — give the address only (scheme, host and port)") }
            guard scheme != nil else { throw no("an address has no path — give the address only (scheme, host and port)") }
            rest = rest[..<slash]
        }
        // host[:port], the host perhaps a bracketed IPv6 literal.
        var host: String
        var portText: Substring?
        if rest.hasPrefix("[") {
            guard let close = rest.firstIndex(of: "]") else { throw no("an IPv6 address goes in brackets: [fd7a::1]:7443") }
            let inner = String(rest[rest.index(after: rest.startIndex)..<close])
            var a = in6_addr()
            guard !inner.isEmpty, !inner.contains("%"), inet_pton(AF_INET6, inner, &a) == 1 else { throw no("not an IPv6 address") }
            host = "[" + inner.lowercased() + "]"
            let after = rest[rest.index(after: close)...]
            if !after.isEmpty {
                guard after.hasPrefix(":") else { throw no("not an address") }
                portText = after.dropFirst()
            }
        } else {
            let parts = rest.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count <= 2 else { throw no("an IPv6 address goes in brackets: [fd7a::1]:7443") }
            host = String(parts[0]).lowercased()
            if parts.count == 2 { portText = parts[1] }
            try checkHost(host)
        }
        var port: Int?
        if let p = portText {
            guard !p.isEmpty, p.count <= 5, p.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(p), (1...65535).contains(n) else {
                throw no("the port must be a number from 1 to 65535")
            }
            port = n
        }
        let tsNet = host.hasSuffix(".ts.net")
        let s = scheme ?? ((tsNet || port == 443) ? "https" : "http")
        let finalPort = port ?? (scheme == "https" ? 443 : scheme == "http" ? 80 : tsNet ? 443 : defaultPort)
        let o = MacOrigin(scheme: s, host: host, port: finalPort)
        if o.isLoopback, thisMacPorts.contains(finalPort) {
            throw no("that is this Mac — its own dashboard is always first in the list")
        }
        return o
    }

    /// An LDH DNS name (letters, digits, -; labels 1–63, not starting or ending with -; ≤ 253 in all) or an IPv4 literal.
    static func checkHost(_ h: String) throws {
        guard !h.isEmpty else { throw HostError(.invalid, "the address has no host") }
        let labels = h.split(separator: ".", omittingEmptySubsequences: false)
        if labels.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }) {
            var a = in_addr()
            guard labels.count == 4, inet_pton(AF_INET, h, &a) == 1 else { throw HostError(.invalid, "not an IPv4 address") }
            return
        }
        guard h.utf8.count <= 253 else { throw HostError(.invalid, "the host name is too long") }
        for l in labels {
            guard (1...63).contains(l.utf8.count), l.first != "-", l.last != "-",
                  l.utf8.allSatisfy({ ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2D }) else {
                throw HostError(.invalid, "not a host name — letters, digits, - and dots (for example mini.example.ts.net)")
            }
        }
    }

    /// The origin of a STORED bookmark (already checked when it was added; a file edited by hand is checked again).
    public static func stored(_ origin: String) -> MacOrigin? {
        guard let o = try? Self.origin(origin), o.origin == origin else { return nil }
        return o
    }
}

/// `doz ui macs ls --json` and the `macs-ls` answer: the list as it is stored, each with its parts.
public struct MacListing: Codable, Equatable, Sendable {
    public var macs: [MacRow]
    public init(macs: [MacRow]) { self.macs = macs }

    public init(_ f: MacsFile) {
        macs = f.macs.compactMap(MacRow.init)
    }
}

public struct MacRow: Codable, Equatable, Sendable {
    public var name: String
    public var origin: String
    public var scheme: String
    public var host: String
    public var port: Int
    public var addedAt: Date
    public var lastCheckAt: Date?
    public var lastSeenAt: Date?
    public var lastResult: String?
    public var reportedName: String?

    /// A row for a stored bookmark — nil when its name or origin is not one this build would have written (a hand edit).
    public init?(_ b: MacBookmark) {
        guard MacBookmarkName.isValid(b.name), let o = MacAddress.stored(b.origin) else { return nil }
        name = b.name; origin = o.origin; scheme = o.scheme; host = o.displayHost; port = o.port
        addedAt = b.addedAt; lastCheckAt = b.lastCheckAt; lastSeenAt = b.lastSeenAt
        lastResult = b.lastResult.flatMap { MacReachability.Outcome(rawValue: $0)?.rawValue }
        reportedName = b.reportedName.flatMap(MacReachability.cleanName)
    }
}

/// The list's file: `<store>/macs.json` (0600 in the 0700 store, written atomically) under `<store>/macs.lock` (flock).
/// Read in-process by anything that looks; written only by `doz ui macs add | rm | check` — the daemon never writes it.
public struct MacBookmarkStore: Sendable {
    public let root: String
    public static let maximumFileBytes = 1 << 20

    public init(store: DozableStore) { root = WorkspaceStore.resolved(store.root.path) }

    public var file: String { root + "/macs.json" }
    public var lockFile: String { root + "/macs.lock" }

    /// The list (empty when there is no file). A file that cannot be read is an error saying so.
    public func read() throws -> MacsFile {
        guard MacFenceHostFS.kind(file) != nil else { return MacsFile() }
        let d: Data
        do { d = try MacFenceHostFS.readRegular(file, maximum: Self.maximumFileBytes) } catch {
            throw HostError(.failed, "the list of your Macs cannot be read: \(error)")
        }
        do { return try HostWire.decoder.decode(MacsFile.self, from: d) } catch {
            throw HostError(.failed, "the list of your Macs cannot be read (\(DisplayPath.tilde(file))): \(error.localizedDescription)")
        }
    }

    public func listing() throws -> MacListing { MacListing(try read()) }

    /// Read, change and write the list under its lock; written only when `body` changed it.
    @discardableResult
    public func update<T>(_ body: (inout MacsFile) throws -> T) throws -> T {
        try WorkspaceStore.ensureOwnedDirectory(root)
        let fd = open(lockFile, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw HostError(.failed, "cannot open \(DisplayPath.tilde(lockFile))") }
        defer { close(fd) }
        while flock(fd, LOCK_EX) != 0 {
            guard errno == EINTR else { throw HostError(.failed, "cannot lock \(DisplayPath.tilde(lockFile))") }
        }
        defer { flock(fd, LOCK_UN) }
        var f = try read()
        let before = f
        let out = try body(&f)
        if f != before {
            var d = try HostWire.prettyEncoder.encode(f)
            d.append(0x0A)
            do { try MacFenceHostFS.writeAtomically(d, dir: root, name: "macs.json") } catch {
                throw HostError(.failed, "the list of your Macs was not written: \(error)")
            }
        }
        return out
    }
}
