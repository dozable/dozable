import CryptoKit
import Darwin
import DozableKit
import Foundation

// 692: a secret given at launch — `--secret VAR,src=PATH,to=HOST:PORT[,header=NAME][,file=FILEVAR]` on `doz create`,
// `doz run NAME` and `doz run @mac` (fenced). Its value is read from a file by the CLI, sent ONCE to the daemon
// (`HostRequest.secrets`), kept in a keychain item of its own (or this daemon's memory when the keychain is locked) and
// bound into the proxy's vault (`secret:VAR`, swap-only, ONE host and port). The session sees only a placeholder: in VAR,
// and with `file=` in a 0600 file named by FILEVAR. Records hold the record below — never the value.

/// What is recorded of a launch secret (`SandboxConfig.secrets`, `MacFenceRecord.secrets`): never its value.
public struct LaunchSecret: Codable, Equatable, Sendable {
    /// The variable its placeholder is in, and (with `file=`) the variable that names the file holding it.
    public var variable: String
    public var fileVariable: String?
    /// The ONE destination it is swapped for.
    public var host: String
    public var port: UInt16
    /// The header (lower-case); `bearer`: sent as `Authorization: Bearer <secret>`, else the header gets the raw value.
    public var header: String
    public var bearer: Bool
    /// The first 12 hex of the value's sha256 (as every foreign credential is shown).
    public var fingerprint: String
    /// The keychain item holding the value (nil: this daemon's memory only — the keychain was locked; or a bot-held one).
    public var keychainService: String?
    /// A BOT-HELD secret: the bot whose token it is (a workspace's manager). Its value is read from the bot's own item
    /// (`BotTokens.service`), only while its fingerprint is the one recorded; it has no item of its own and no ledger line,
    /// so nothing that revokes, forgets or sweeps launch secrets ever deletes it. Additive: an older doz drops it and treats
    /// the secret as memory-only (a 401 notice until the manager is started again — never a deletion). The daemon sets it;
    /// one a client sends is cleared (`checkedLaunchSecrets`).
    public var bot: String?

    public init(variable: String, fileVariable: String? = nil, host: String, port: UInt16, header: String = "authorization",
                bearer: Bool = true, fingerprint: String, keychainService: String? = nil, bot: String? = nil) {
        self.variable = variable
        self.fileVariable = fileVariable
        self.host = host.lowercased()
        self.port = port
        self.header = header.lowercased()
        self.bearer = bearer
        self.fingerprint = fingerprint
        self.keychainService = keychainService
        self.bot = bot
    }

    /// `HOST:PORT`.
    public var destination: String { "\(host):\(port)" }
    /// Its vault binding's id.
    public var bindingID: String { CredentialBinding.launchSecretPrefix + variable }

    /// Its vault binding: swap-only (never injected — so never beside the program's own credential), exactly its host and
    /// port; `plainHTTP` — `network.placeholders_plain_http` as it is when it is bound.
    public func binding(plainHTTP: Bool) -> CredentialBinding {
        CredentialBinding(id: bindingID, hosts: [host], header: bearer ? .bearer : .apiKey(name: header), environmentVariable: variable,
                          swapOnly: true, port: port, plainHTTP: plainHTTP)
    }

    /// The launch line: "secret SERVER_TOKEN → host.dozable.internal:8780 (fp abc123…)".
    public var line: String { "secret \(variable) → \(destination) (fp \(fingerprint)…)" }

    /// What the agent is told (its facts, the fence's capabilities).
    public var facts: String {
        "\(variable) holds a placeholder Dozable swaps for a secret on requests to \(destination)"
            + (bearer ? " (Authorization: Bearer)" : " (header \(header))")
            + (fileVariable.map { "; $\($0) names a file holding the same placeholder" } ?? "")
    }
}

/// What the CLI sends the daemon ONCE per secret (`HostRequest.secrets`): the record, the value and the real path of the
/// file it came from (the daemon refuses a file the session could read). Never logged, never stored.
public struct LaunchSecretGrant: Codable, Equatable, Sendable {
    public var secret: LaunchSecret
    public var value: String
    public var source: String

    public init(secret: LaunchSecret, value: String, source: String) {
        self.secret = secret
        self.value = value
        self.source = source
    }
}

/// `doz net show` (`--json secrets`): a launch secret as the person reads it — never its value.
public struct LaunchSecretRow: Codable, Equatable, Sendable {
    public var variable: String
    public var to: String
    public var header: String
    public var fingerprint: String
    public var plainHTTP: Bool
    public init(_ s: LaunchSecret, plainHTTP: Bool) {
        variable = s.variable
        to = s.destination
        header = s.bearer ? "authorization (Bearer)" : s.header
        fingerprint = s.fingerprint
        self.plainHTTP = plainHTTP
    }
}

public enum LaunchSecrets {
    /// The most secrets one sandbox or session is given.
    public static let maximum = 4
    /// The flag's form, for every refusal.
    public static let form = "--secret VAR,src=PATH,to=HOST:PORT[,header=NAME][,file=FILEVAR]"
    /// What a fenced session's file is under (`<session>/etc/secrets/VAR`), and a sandbox's (`$HOME/.doz-secrets/VAR`).
    public static let fenceFolder = "secrets"
    public static let sandboxFolder = ".doz-secrets"
    /// The keychain items' prefix (`doz-secret-<store>-<owner>-<VAR>`).
    public static let servicePrefix = "doz-secret-"

    /// One `--secret` value, before its file is read: the variable, the file variable, the source path, the destination
    /// and the header. Checked for form only here and in `check`; the daemon checks it again.
    public struct Spec: Equatable, Sendable {
        public var variable: String
        public var fileVariable: String?
        public var source: String
        public var host: String
        public var port: UInt16
        public var header: String
        public var bearer: Bool
    }

    /// Dozable's own variables — never a secret's (VAR or FILEVAR): what Dozable sets in a sandbox or a fenced session.
    public static let reservedVariables: Set<String> = [
        "GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "OPENAI_API_KEY", "NODE_EXTRA_CA_CERTS", "SSL_CERT_FILE",
        "REQUESTS_CA_BUNDLE", "CURL_CA_BUNDLE", "GIT_SSL_CAINFO", "NODE_USE_ENV_PROXY", "SSH_AUTH_SOCK", "PATH", "HOME",
        "TMPDIR", "SHELL", "USER", "LOGNAME", "BROWSER", "ZDOTDIR", "HISTFILE", "GH_CONFIG_DIR", "CODEX_HOME",
    ]
    public static let reservedPrefixes = ["ANTHROPIC_", "CLAUDE_CODE_", "DOZ_", "GIT_CONFIG", "XDG_"]

    /// Why `v` cannot carry a secret's placeholder (nil: it can). `what`: `VAR` or `file=`.
    public static func variableProblem(_ v: String, what: String = "VAR") -> String? {
        guard CustomKey.isVariableName(v) else { return "\(what) \(v): an upper-case variable name like SERVER_TOKEN" }
        if reservedVariables.contains(v) || reservedPrefixes.contains(where: v.hasPrefix) || v.hasSuffix("_PROXY") {
            return "\(what) \(v) is one of Dozable's own variables — choose another name"
        }
        return nil
    }

    /// One `--secret` value, parsed (`expandHome` turns a leading `~/` into the person's home). Throws a plain message.
    public static func parse(_ word: String, home: String = NSHomeDirectory()) throws -> Spec {
        let parts = word.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard let variable = parts.first, !variable.isEmpty, !variable.contains("=") else {
            throw HostError(.invalid, "--secret \(word): the variable comes first — \(form)")
        }
        if let p = variableProblem(variable) { throw HostError(.invalid, "--secret: \(p)") }
        var fields: [String: String] = [:]
        for piece in parts.dropFirst() {
            guard let eq = piece.firstIndex(of: "=") else {
                throw HostError(.invalid, "--secret \(variable): \"\(piece)\" is not KEY=VALUE — a comma inside PATH is refused (\(form))")
            }
            let k = String(piece[..<eq]), v = String(piece[piece.index(after: eq)...])
            guard ["src", "to", "header", "file"].contains(k) else {
                throw HostError(.invalid, "--secret \(variable): unknown \(k)= — it takes src=, to=, header= and file= (\(form))")
            }
            guard fields[k] == nil else { throw HostError(.invalid, "--secret \(variable): \(k)= given twice") }
            guard !v.isEmpty else { throw HostError(.invalid, "--secret \(variable): \(k)= is empty") }
            fields[k] = v
        }
        guard var src = fields["src"] else { throw HostError(.invalid, "--secret \(variable): src=PATH is required — the file holding the secret (\(form))") }
        if src == "~" || src.hasPrefix("~/") { src = home + src.dropFirst() }
        guard src.hasPrefix("/") || !src.hasPrefix("~") else { throw HostError(.invalid, "--secret \(variable): src=\(src) — ~ means only your own home (~/…)") }
        guard let to = fields["to"] else { throw HostError(.invalid, "--secret \(variable): to=HOST:PORT is required (\(form))") }
        let (host, port) = try destination(to, variable: variable)
        var header = "authorization", bearer = true
        if let h = fields["header"] {
            let lower = h.lowercased()
            guard CustomKey.isHeaderName(lower), !["proxy-authorization", HostRoute.sessionHeader.lowercased()].contains(lower) else {
                throw HostError(.invalid, "--secret \(variable): header=\(h) — a header name like x-api-key (never host, cookie, proxy-authorization or the framing fields)")
            }
            header = lower
            bearer = lower == "authorization"
        }
        var fileVariable: String?
        if let f = fields["file"] {
            if let p = variableProblem(f, what: "file=") { throw HostError(.invalid, "--secret \(variable): \(p)") }
            guard f != variable else { throw HostError(.invalid, "--secret \(variable): file= names another variable than the secret's own") }
            fileVariable = f
        }
        return Spec(variable: variable, fileVariable: fileVariable, source: src, host: host, port: port, header: header, bearer: bearer)
    }

    /// `to=HOST:PORT`: a name, an IPv4 address or `host.dozable.internal`, and a port (1–65535, required). Refused: the
    /// route's alias, IPv6, the loopback, this Mac's own addresses (and link-local, metadata, multicast — the strict
    /// guard's list), hosts Dozable already holds keys for. `own`: this Mac's interface addresses (tests give their own).
    public static func destination(_ to: String, variable: String, own: Set<[UInt8]> = AddressGuard.interfaceAddresses()) throws -> (String, UInt16) {
        let t = to.lowercased()
        if t.hasPrefix("[") || t.filter({ $0 == ":" }).count > 1 {
            throw HostError(.invalid, "--secret \(variable): to=\(to) — an IPv6 address is not supported; a name or an IPv4 address and a port")
        }
        guard let colon = t.lastIndex(of: ":") else { throw HostError(.invalid, "--secret \(variable): to=\(to) — HOST:PORT, the port is required") }
        let host = String(t[..<colon]).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let p = String(t[t.index(after: colon)...])
        guard !p.isEmpty, p.count <= 5, p.allSatisfy(\.isASCII), p.allSatisfy(\.isNumber), let n = Int(p), (1...65535).contains(n) else {
            throw HostError(.invalid, "--secret \(variable): to=\(to) — the port is a number from 1 to 65535")
        }
        if host == MacModelServer.hostName {
            throw HostError(.invalid, "--secret \(variable): to=\(to) — say \(HostRoute.hostName):\(n) (the other name is an alias the secret never goes to)")
        }
        if host == "localhost" || host.hasSuffix(".localhost") {
            throw HostError(.invalid, "--secret \(variable): to=\(to) — this Mac's loopback is never a destination; a service on this Mac is \(HostRoute.hostName):PORT (with --host-port PORT)")
        }
        if let b = TailscaleRange.ipv4Bytes(host) {
            if let why = AddressGuard.strictRefusal(b, own: own) {
                throw HostError(.invalid, "--secret \(variable): to=\(to) — \(why) is never a destination; a service on this Mac is \(HostRoute.hostName):PORT (with --host-port PORT)")
            }
        } else if host != HostRoute.hostName {
            guard host.count <= 253, CustomKey.isExactHostName(host) else {
                throw HostError(.invalid, "--secret \(variable): to=\(to) — a host name like api.example.com, an IPv4 address, or \(HostRoute.hostName)")
            }
            if CustomKey.isHeldHost(host) || host == "api.anthropic.com" {
                throw HostError(.invalid, "--secret \(variable): to=\(to) is a host Dozable already holds keys for — use an account for it")
            }
        }
        return (host, UInt16(n))
    }

    /// Several `--secret`s together: at most `maximum`, each variable once (a VAR or a FILEVAR never names another's).
    public static func check(_ specs: [(variable: String, fileVariable: String?)]) throws {
        guard specs.count <= maximum else { throw HostError(.invalid, "at most \(maximum) --secret for one sandbox or session") }
        var seen = Set<String>()
        for s in specs {
            for v in [s.variable] + (s.fileVariable.map { [$0] } ?? []) {
                guard seen.insert(v).inserted else { throw HostError(.invalid, "--secret: \(v) is named twice") }
            }
        }
    }

    // MARK: the value

    /// Read a secret from `path`: opened with O_NOFOLLOW (a link is refused), a regular file owned by this user that no
    /// one else may read (`chmod 600 PATH`); trailing CR/LF trimmed; at most `Keychain.maximumSecretBytes`; printable
    /// ASCII without spaces only (so it is header-safe and no header can be injected). Returns the value and the file's
    /// real path. A refusal never quotes the file's content.
    public static func read(_ path: String, variable: String) throws -> (value: String, realPath: String) {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else {
            let e = errno
            if e == ELOOP { throw HostError(.invalid, "--secret \(variable): src=\(DisplayPath.tilde(path)) is a link — give the file itself") }
            throw HostError(.invalid, "--secret \(variable): src=\(DisplayPath.tilde(path)) cannot be opened (\(String(cString: strerror(e))))")
        }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else {
            throw HostError(.invalid, "--secret \(variable): src=\(DisplayPath.tilde(path)) is not a regular file")
        }
        guard st.st_uid == getuid() else { throw HostError(.invalid, "--secret \(variable): src=\(DisplayPath.tilde(path)) is not your own file") }
        guard st.st_mode & 0o077 == 0 else {
            throw HostError(.invalid, "--secret \(variable): src=\(DisplayPath.tilde(path)) may be read by other users — chmod go-rwx \(DisplayPath.tilde(path))")
        }
        let limit = Keychain.maximumSecretBytes
        guard st.st_size <= off_t(limit + 2) else {
            throw HostError(.invalid, "--secret \(variable): src=\(DisplayPath.tilde(path)) holds more than \(limit) bytes — a secret is at most \(limit)")
        }
        var bytes: [UInt8] = []
        var buf = [UInt8](repeating: 0, count: 4096)
        while bytes.count <= limit + 2 {
            let n = buf.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n < 0 { if errno == EINTR { continue }; throw HostError(.invalid, "--secret \(variable): src=\(DisplayPath.tilde(path)) could not be read") }
            if n == 0 { break }
            bytes += buf[0..<n]
        }
        while let last = bytes.last, last == 10 || last == 13 { bytes.removeLast() }
        let value = try checkedValue(bytes, variable: variable)
        var real = [CChar](repeating: 0, count: Int(PATH_MAX))
        let resolved = realpath(path, &real).map { String(cString: $0) } ?? path
        return (value, resolved)
    }

    /// A value's bytes (trailing CR/LF already trimmed), checked: 1–1800 bytes of printable ASCII without spaces.
    public static func checkedValue(_ bytes: [UInt8], variable: String) throws -> String {
        guard !bytes.isEmpty else { throw HostError(.invalid, "--secret \(variable): the file is empty") }
        guard bytes.count <= Keychain.maximumSecretBytes else {
            throw HostError(.invalid, "--secret \(variable): the secret is over \(Keychain.maximumSecretBytes) bytes")
        }
        guard bytes.allSatisfy({ $0 > 0x20 && $0 < 0x7F }) else {
            throw HostError(.invalid, "--secret \(variable): the secret must be printable ASCII with no spaces or line breaks inside it (one line, trailing newline allowed)")
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: where it lives

    /// The keychain item of `variable`'s secret for `owner` (a sandbox's name, or `mac.SESSION`) in the store at `root`.
    public static func service(store root: URL, owner: String, variable: String) -> String {
        let digest = SHA256.hash(data: Data(root.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
        return servicePrefix + digest.prefix(8) + "-" + owner + "-" + variable
    }

    /// A fenced session's owner word (`mac.SESSION`).
    public static func macOwner(_ session: String) -> String { "mac." + session }

    /// Whether `path` (resolved) is `root` or inside it.
    public static func isWithin(_ path: String, _ root: String) -> Bool {
        let r = root.hasSuffix("/") ? String(root.dropLast()) : root
        return path == r || path.hasPrefix(r + "/")
    }
}

/// `<store>/secrets.json`: which keychain item belongs to which owner (`service → owner`) — never a value. A daemon's
/// start sweeps the items whose owner is gone; a revocation removes its line.
public struct LaunchSecretLedger: Codable, Equatable, Sendable {
    public var version = 1
    public var items: [String: String] = [:]
    public init() {}

    public static func url(_ store: DozableStore) -> URL { store.root.appendingPathComponent("secrets.json") }

    public static func load(_ store: DozableStore) -> LaunchSecretLedger {
        guard let d = try? Data(contentsOf: url(store)), let l = try? JSONDecoder().decode(LaunchSecretLedger.self, from: d) else { return LaunchSecretLedger() }
        return l
    }

    public func save(_ store: DozableStore) {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let d = try? e.encode(self) else { return }
        try? FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
        try? d.write(to: Self.url(store), options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.url(store).path)
    }
}
