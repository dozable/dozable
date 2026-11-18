import Darwin
import Foundation

/// 715 — `doz ui publish tailscale`: the dashboard on the person's tailnet at its own address, through DOZABLE'S OWN
/// Tailscale node — a userspace `tailscaled` from Homebrew's `tailscale` formula (installed, never needing a link: the Mac's
/// own `tailscale` command and the Tailscale app are never run or touched), with its state and socket in the store:
///
///     <store>/tailscale/state/            tailscaled's --statedir (the node's identity; `unpublish --logout` removes it)
///     <store>/tailscale/tailscaled.sock   its --socket (every `tailscale` command here names it)
///     <store>/tailscale/tailscaled.log    the LaunchAgent's stdout/stderr
///     <store>/tailscale/published.json    the marker: published, under which name, at which address, port 80's redirect's
///                                         loopback port (doctor's rows)
///
/// kept running by ONE per-user LaunchAgent per store (`com.dozable.tailscale.<8 hex>`, RunAtLoad + KeepAlive) — written
/// through the login item's seams (`LaunchAgentsFolder`, `Launchctl`: a guarded run never reaches the real ones).
///
/// Serving: `serve --https=443` → `http://127.0.0.1:<ui.port>` (Tailscale's certificate; the dashboard believes its
/// X-Forwarded-* because 127.0.0.1 is a trusted proxy), and `serve --http=80` → `http://127.0.0.1:<the marker's
/// redirectPort>`, where the running `doz ui` (WebPublishRedirect) answers EVERY request with a 308 to
/// `https://<name>.<tailnet>.ts.net<same path>`. `tailscale serve` has no redirect of its own, and the redirect's target
/// comes from the published address, never from a request header, so nothing depends on what Tailscale forwards on port 80.
/// 716: a loopback TCP port, never a unix socket — Tailscale (1.104.7) serves a `unix:` target or a path handler only for
/// root or an operator who may run `sudo tailscale` ("401 Unauthorized: must be root, …"), and Dozable's node runs under a
/// LaunchAgent, so 0.51.14's `unix:<store>/tailscale/http.sock` was always refused. A plain `http://127.0.0.1:<port>`
/// target needs no admin (443 always worked that way). Like the dashboard's own port, a sandbox's proxy never reaches
/// this Mac's loopback.
///
/// Everything here is pure or a seam (TailscalePublishTests); the command is `doz ui publish|unpublish` (DozableCLI).
public enum TailscalePublish {
    public static let labelPrefix = "com.dozable.tailscale."
    /// The formula's folder under a Homebrew prefix.
    public static let formulaBin = "opt/tailscale/bin"

    public static func label(_ store: DozableStore) -> String { labelPrefix + MacPlace.storeHash(store) }
    public static func plistURL(_ store: DozableStore, folder: URL) -> URL { folder.appendingPathComponent(label(store) + ".plist") }

    // MARK: paths

    public struct Paths: Equatable, Sendable {
        public let root: URL
        public var stateDir: URL { root.appendingPathComponent("state") }
        public var socket: URL { root.appendingPathComponent("tailscaled.sock") }
        public var log: URL { root.appendingPathComponent("tailscaled.log") }
        /// 0.51.14's port 80 redirect socket (never served — Tailscale refuses a `unix:` target without admin): publish and
        /// unpublish remove one left behind.
        public var staleRedirectSocket: URL { root.appendingPathComponent("http.sock") }
        public var marker: URL { root.appendingPathComponent("published.json") }
    }

    public static func paths(_ store: DozableStore) -> Paths { Paths(root: store.root.appendingPathComponent("tailscale")) }

    /// A unix socket's path must fit `sun_path` (104 bytes with its NUL).
    public static func socketFits(_ url: URL) -> Bool { url.path.utf8.count < 104 }

    // MARK: Homebrew's tailscale

    public struct Binaries: Equatable, Sendable {
        public let prefix: String
        public var bin: String { prefix + "/" + TailscalePublish.formulaBin }
        public var tailscale: String { bin + "/tailscale" }
        public var tailscaled: String { bin + "/tailscaled" }
    }

    /// Where Homebrew may be: `$HOMEBREW_PREFIX`, `/opt/homebrew` (Apple silicon), `/usr/local`. In a test run ONLY the seam
    /// `DOZ_TEST_BREW_PREFIX` (a scratch prefix with a fake tailscale) — never a real one.
    public static func prefixCandidates(env: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        if TestSafety.guarded(env) { return env["DOZ_TEST_BREW_PREFIX"].flatMap { $0.hasPrefix("/") ? [$0] : nil } ?? [] }
        var out: [String] = []
        if let p = env["HOMEBREW_PREFIX"], p.hasPrefix("/") { out.append(p) }
        for p in ["/opt/homebrew", "/usr/local"] where !out.contains(p) { out.append(p) }
        return out
    }

    /// The formula's `tailscale` and `tailscaled` (its `opt` link: linked or not, it is there once installed). nil: not
    /// installed (`brew install tailscale`).
    public static func locate(env: [String: String] = ProcessInfo.processInfo.environment) -> Binaries? {
        for p in prefixCandidates(env: env) {
            let b = Binaries(prefix: (p as NSString).standardizingPath)
            if FileManager.default.isExecutableFile(atPath: b.tailscale), FileManager.default.isExecutableFile(atPath: b.tailscaled) { return b }
        }
        return nil
    }

    /// Why running `path` as Dozable's tailscale is refused in a guarded run (nil: allowed): anything outside the seam's
    /// prefix — a test never runs a real tailscale, which would reach the person's tailnet.
    public static func runViolation(_ path: String, env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        guard let seam = env["DOZ_TEST_BREW_PREFIX"], seam.hasPrefix("/") else {
            return "a test would run a real tailscale (\(path)) — give it a fake one under DOZ_TEST_BREW_PREFIX"
        }
        let s = (seam as NSString).standardizingPath
        return path.hasPrefix(s + "/") ? nil : "a test would run \(path), outside DOZ_TEST_BREW_PREFIX (\(s))"
    }

    // MARK: the node's name

    /// A DNS label from anything: lower-case, every run of characters outside `a-z0-9` one hyphen, no hyphen at either
    /// end, at most 63 characters. Empty when nothing is left.
    public static func dnsLabel(_ s: String) -> String {
        var out = ""
        var hyphen = false
        for c in s.lowercased().unicodeScalars {
            if ("a"..."z").contains(c) || ("0"..."9").contains(c) {
                if hyphen && !out.isEmpty { out.append("-") }
                hyphen = false
                out.unicodeScalars.append(c)
            } else {
                hyphen = true
            }
        }
        if out.count > 63 { out = String(out.prefix(63)) }
        while out.hasSuffix("-") { out.removeLast() }
        return out
    }

    /// The default name: `dozable-<LocalHostName>` as a DNS label (`dozable` alone when the Mac has no name).
    public static func defaultName(mac: String?) -> String {
        let m = dnsLabel(mac ?? "")
        return m.isEmpty ? "dozable" : dnsLabel("dozable-" + m)
    }

    /// `--name`: 1–63 letters, digits and hyphens, not starting or ending with one; upper case is taken as lower. nil: not
    /// a valid name (said, never silently changed).
    public static func validName(_ s: String) -> String? {
        let n = s.lowercased()
        guard (1...63).contains(n.count), !n.hasPrefix("-"), !n.hasSuffix("-"),
              n.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }) else { return nil }
        return n
    }

    // MARK: argv (pure)

    public static func daemonArguments(_ b: Binaries, _ p: Paths) -> [String] {
        [b.tailscaled, "--tun=userspace-networking", "--statedir=\(p.stateDir.path)", "--socket=\(p.socket.path)", "--port=0"]
    }

    /// Every `tailscale` command names Dozable's node's socket first.
    public static func cli(_ b: Binaries, _ p: Paths, _ args: [String]) -> [String] { [b.tailscale, "--socket=\(p.socket.path)"] + args }

    public static func statusArguments() -> [String] { ["status", "--json"] }
    /// A node that is not signed in: `up` (it prints Tailscale's login link and waits — at most `timeout` seconds).
    public static func upArguments(name: String, timeout: Int) -> [String] { ["up", "--hostname=\(name)", "--timeout=\(timeout)s"] }
    /// A node that is signed in: only its name is (re)applied — `up` would ask for every non-default flag again.
    public static func setArguments(name: String) -> [String] { ["set", "--hostname=\(name)"] }
    public static func serveResetArguments() -> [String] { ["serve", "reset"] }
    public static func serveHTTPSArguments(port: Int) -> [String] { ["serve", "--bg", "--yes", "--https=443", "http://127.0.0.1:\(port)"] }
    public static func serveHTTPArguments(redirectPort: Int) -> [String] { ["serve", "--bg", "--yes", "--http=80", httpTarget(redirectPort: redirectPort)] }
    public static func serveStatusArguments() -> [String] { ["serve", "status", "--json"] }
    public static func logoutArguments() -> [String] { ["logout"] }

    // MARK: the LaunchAgent (pure)

    public static func renderPlist(_ store: DozableStore, _ b: Binaries) -> String {
        let p = paths(store)
        let dict: [String: Any] = [
            "Label": label(store),
            "ProgramArguments": daemonArguments(b, p),
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Standard",
            "StandardOutPath": p.log.path,
            "StandardErrorPath": p.log.path,
        ]
        let data = (try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: what the node says (pure)

    public struct NodeStatus: Equatable, Sendable {
        /// `Running` once signed in; `NeedsLogin`, `NeedsMachineAuth`, `Starting`, `Stopped`, …
        public var backendState: String
        /// `<name>.<tailnet>.ts.net` (no final dot); nil before sign-in.
        public var dnsName: String?
        public var hostName: String?
        public var authURL: String?
        public var signedIn: Bool { backendState == "Running" }
        public init(backendState: String, dnsName: String?, hostName: String?, authURL: String?) {
            self.backendState = backendState; self.dnsName = dnsName; self.hostName = hostName; self.authURL = authURL
        }
    }

    /// `tailscale status --json` (BackendState, AuthURL, Self.DNSName, Self.HostName). nil: not that.
    public static func parseStatus(_ data: Data) -> NodeStatus? {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let state = o["BackendState"] as? String else { return nil }
        let me = o["Self"] as? [String: Any]
        var dns = (me?["DNSName"] as? String).map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 }
        if dns?.isEmpty == true { dns = nil }
        let auth = (o["AuthURL"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return NodeStatus(backendState: state, dnsName: dns, hostName: me?["HostName"] as? String, authURL: auth)
    }

    public struct ServeConfig: Equatable, Sendable {
        /// Where `<name>:443 /` goes (`http://127.0.0.1:7443`).
        public var https: String?
        /// Where `<name>:80 /` goes (`http://127.0.0.1:<redirect port>`).
        public var http: String?
        public init(https: String?, http: String?) { self.https = https; self.http = http }
    }

    /// `tailscale serve status --json`: `Web["<host>:<port>"].Handlers["/"].Proxy` for 443 and 80 (an empty config: `{}`).
    public static func parseServe(_ data: Data) -> ServeConfig? {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var c = ServeConfig(https: nil, http: nil)
        for (hostPort, v) in (o["Web"] as? [String: Any]) ?? [:] {
            guard let handlers = (v as? [String: Any])?["Handlers"] as? [String: Any],
                  let proxy = (handlers["/"] as? [String: Any])?["Proxy"] as? String else { continue }
            if hostPort.hasSuffix(":443") { c.https = proxy }
            if hostPort.hasSuffix(":80") { c.http = proxy }
        }
        return c
    }

    /// The first `https://` link in a line `tailscale up` printed (its login link, or a "enable HTTPS" page).
    public static func link(in line: String) -> String? {
        for word in line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\"" }) where word.hasPrefix("https://") {
            return String(word).trimmingCharacters(in: CharacterSet(charactersIn: ".,;)"))
        }
        return nil
    }

    public static func origin(dnsName: String) -> String { "https://" + dnsName }

    /// The 443 target the dashboard's port means.
    public static func httpsTarget(port: Int) -> String { "http://127.0.0.1:\(port)" }
    /// The 80 target: port 80's redirect on its loopback port (the marker's `redirectPort`).
    public static func httpTarget(redirectPort: Int) -> String { "http://127.0.0.1:\(redirectPort)" }

    // MARK: the settings (pure)

    /// What publishing sets: the fixed port, the LAN option, loopback only (Tailscale's proxy is on this Mac), the
    /// address, and the proxy believed (127.0.0.1 and ::1). `serve.chat` is never touched.
    public static func publishSettings(port: Int, origin: String) -> [(key: String, value: TOMLValue?)] {
        [(SettingKey.uiPort, .int(port)), (SettingKey.uiLAN, .bool(true)), (SettingKey.serveBind, .string("loopback")),
         (SettingKey.servePublicOrigins, .string(origin)), (SettingKey.serveTrustedProxies, .string("127.0.0.1,::1"))]
    }

    /// What unpublishing puts back: this Mac only — the LAN option off, the address, the proxy and where it listens to
    /// their defaults. `ui.port` stays (an installed dashboard app belongs to it).
    public static func unpublishSettings() -> [(key: String, value: TOMLValue?)] {
        [(SettingKey.uiLAN, .bool(false)), (SettingKey.servePublicOrigins, nil), (SettingKey.serveTrustedProxies, nil),
         (SettingKey.serveBind, nil)]
    }

    /// Write `plan` through the settings code (validated; a file that does not parse is refused, never overwritten).
    @discardableResult
    public static func apply(_ plan: [(key: String, value: TOMLValue?)], to settings: DozableSettings) throws -> DozableSettings {
        var s = settings
        for (k, v) in plan { s = try s.writing(k, v) }
        return s
    }

    // MARK: the marker

    public struct Marker: Codable, Equatable, Sendable {
        public var name: String
        /// `https://<name>.<tailnet>.ts.net`.
        public var origin: String
        public var port: Int
        public var published: Date
        /// 716: port 80's redirect's loopback port (127.0.0.1). nil: a 0.51.14 marker (it had a unix socket) — the next
        /// `doz ui publish tailscale` picks one.
        public var redirectPort: Int?
        public init(name: String, origin: String, port: Int, published: Date, redirectPort: Int? = nil) {
            self.name = name; self.origin = origin; self.port = port; self.published = published; self.redirectPort = redirectPort
        }
    }

    /// The redirect's port for a publish: the one the marker records (a re-run keeps it — the running dashboard holds it)
    /// unless another program holds it (`takenByOther`), else a free loopback port that is not the dashboard's. nil: none free.
    public static func chooseRedirectPort(previous: Marker?, dashboardPort: Int, takenByOther: (Int) -> Bool = { _ in false },
                                          free: () -> Int? = freeLoopbackPort) -> Int? {
        if let p = previous?.redirectPort, (1024...65_535).contains(p), p != dashboardPort, !takenByOther(p) { return p }
        for _ in 0..<8 {
            guard let p = free() else { return nil }
            if p != dashboardPort { return p }
        }
        return nil
    }

    public static func readMarker(_ store: DozableStore) -> Marker? {
        guard let d = try? Data(contentsOf: paths(store).marker) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(Marker.self, from: d)
    }

    public static func writeMarker(_ store: DozableStore, _ m: Marker) throws {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let url = paths(store).marker
        try ensureRoot(store)
        try enc.encode(m).write(to: url, options: .atomic)
        chmod(url.path, 0o600)
    }

    public static func ensureRoot(_ store: DozableStore) throws {
        let p = paths(store)
        try FileManager.default.createDirectory(at: p.stateDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(p.root.path, 0o700)
    }

    // MARK: port 80's redirect (pure)

    /// The redirect's `Location`: the published https address + the request's own path and query — only when it is an
    /// origin-form target of visible ASCII (no space, no backslash, at most 2 KiB); anything else goes to `/`.
    public static func redirectLocation(origin: String, target: String) -> String {
        let ok = target.hasPrefix("/") && target.utf8.count <= 2048
            && target.unicodeScalars.allSatisfy { $0.value > 0x20 && $0.value < 0x7F && $0 != "\\" }
        return origin + (ok ? target : "/")
    }

    // MARK: the LaunchAgent (seams)

    public struct AgentState: Equatable, Sendable {
        public var path: String
        public var installed: Bool
        public var loaded: Bool
        /// Its ProgramArguments are what this doz would write.
        public var current: Bool
    }

    /// Read only: the plist and launchd's `print` (nil seams in a guarded run without them: nothing looked at).
    public static func agentState(_ store: DozableStore, binaries: Binaries?, launchctl: Launchctl? = Launchctl.forLooking(),
                                  folder: URL? = LaunchAgentsFolder.forLooking()) -> AgentState? {
        guard let folder, let launchctl else { return nil }
        let url = plistURL(store, folder: folder)
        let installed = FileManager.default.fileExists(atPath: url.path)
        let args = installed ? DaemonLoginItem.installedArguments(url) : nil
        let current = binaries.map { args == daemonArguments($0, paths(store)) } ?? false
        return AgentState(path: url.path, installed: installed, loaded: installed && launchctl.printJob(label: label(store)) != nil, current: current)
    }

    /// Write the plist (atomically, 0644) and (re)load it: an older one loaded is booted out first. The line launchd said
    /// when it refused, or nil.
    public static func installAgent(_ store: DozableStore, _ b: Binaries, launchctl: Launchctl = Launchctl.current(),
                                    folder: URL = LaunchAgentsFolder.current()) throws -> String? {
        try ensureRoot(store)
        let url = plistURL(store, folder: folder)
        try DaemonLoginItem.write(renderPlist(store, b), to: url)
        if launchctl.printJob(label: label(store)) != nil { _ = launchctl.bootout(label: label(store)) }
        let r = launchctl.bootstrap(plist: url.path)
        return r.ok ? nil : (r.output.split(separator: "\n").first.map(String.init) ?? "launchctl bootstrap failed (\(r.code))")
    }

    /// Unload and remove the plist. true: there was one.
    @discardableResult
    public static func removeAgent(_ store: DozableStore, launchctl: Launchctl = Launchctl.current(),
                                   folder: URL = LaunchAgentsFolder.current()) -> Bool {
        let url = plistURL(store, folder: folder)
        if launchctl.printJob(label: label(store)) != nil { _ = launchctl.bootout(label: label(store)) }
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        return unlink(url.path) == 0
    }

    // MARK: running tailscale

    public struct Run: Equatable, Sendable {
        public var code: Int32
        public var out: String
        public var err: String
        public var timedOut: Bool
        public var ok: Bool { code == 0 && !timedOut }
        /// One line for a person: the last non-empty line it wrote (stderr first, then stdout).
        public var reason: String {
            let lines = (err + "\n" + out).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return timedOut ? "no answer in time" : (lines.last ?? "exit \(code)")
        }
    }

    /// Run `argv` (no shell), at most `timeout` seconds; each line of its output (stdout and stderr) goes to `onLine` as it
    /// comes. In a guarded run anything outside the seam's prefix STOPS the process.
    public static func run(_ argv: [String], timeout: Double, onLine: (@Sendable (String) -> Void)? = nil,
                           env: [String: String] = ProcessInfo.processInfo.environment) -> Run {
        TestSafety.enforce(TestSafety.guarded(env) ? runViolation(argv[0], env: env) : nil, env: env)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: argv[0])
        p.arguments = Array(argv.dropFirst())
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return Run(code: -1, out: "", err: "could not run \(argv[0]): \(error.localizedDescription)", timedOut: false) }
        let o = Collected(onLine), e = Collected(onLine)
        let to = Thread { o.read(out.fileHandleForReading) }, te = Thread { e.read(err.fileHandleForReading) }
        to.start(); te.start()
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { usleep(10_000) }
        var timedOut = false
        if p.isRunning {
            timedOut = true
            p.terminate(); usleep(300_000)
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        }
        p.waitUntilExit()
        let readDeadline = Date().addingTimeInterval(2)
        while !(o.done && e.done) && Date() < readDeadline { usleep(5_000) }
        return Run(code: p.terminationStatus, out: o.text, err: e.text, timedOut: timedOut)
    }

    /// The node's status (nil: its socket does not answer — not running).
    public static func status(_ b: Binaries, _ p: Paths, timeout: Double = 8) -> NodeStatus? {
        let r = run(cli(b, p, statusArguments()), timeout: timeout)
        guard r.code == 0 || !r.out.isEmpty else { return nil }
        return parseStatus(Data(r.out.utf8))
    }

    public static func serveConfig(_ b: Binaries, _ p: Paths, timeout: Double = 8) -> ServeConfig? {
        let r = run(cli(b, p, serveStatusArguments()), timeout: timeout)
        guard r.ok else { return nil }
        return parseServe(Data(r.out.utf8))
    }

    /// Does `path` (a unix socket) accept a connection now?
    public static func socketAnswers(_ path: String) -> Bool {
        UnixSocket.connect(path).map { close($0); return true } ?? false
    }

    /// Ask port 80's redirect (127.0.0.1:`port`) for `/doctor` and return its status and Location (nil: no answer).
    public static func askRedirect(port: Int, timeout: Int = 3) -> (status: Int, location: String?)? {
        guard (1...65_535).contains(port) else { return nil }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = in_port_t(UInt16(port).bigEndian)
        a.sin_addr.s_addr = inet_addr("127.0.0.1")
        let r = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard r == 0 else { return nil }
        var tv = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let req = "GET /doctor HTTP/1.1\r\nHost: doctor\r\nConnection: close\r\n\r\n"
        _ = req.withCString { write(fd, $0, strlen($0)) }
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while data.count < 16_384 {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            data.append(buf, count: n)
        }
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.components(separatedBy: "\r\n")
        guard let first = lines.first, first.hasPrefix("HTTP/1."), let code = Int(first.split(separator: " ").dropFirst().first ?? "") else { return nil }
        let loc = lines.first { $0.lowercased().hasPrefix("location:") }.map { String($0.dropFirst("location:".count)).trimmingCharacters(in: .whitespaces) }
        return (code, loc)
    }

    /// A free port on 127.0.0.1 (the OS's pick), for a dashboard that has none fixed and none running.
    public static func freeLoopbackPort() -> Int? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = 0
        a.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0 else { return nil }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        guard withUnsafeMutablePointer(to: &a, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }) == 0 else { return nil }
        return Int(UInt16(bigEndian: a.sin_port))
    }
}

/// A child's output, read on its own thread, each line handed on as it comes.
final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var finished = false
    private var pending = ""
    private let onLine: (@Sendable (String) -> Void)?
    init(_ onLine: (@Sendable (String) -> Void)?) { self.onLine = onLine }

    func read(_ h: FileHandle) {
        while true {
            let d = h.availableData
            if d.isEmpty { break }
            lock.withLock { data.append(d) }
            if let onLine {
                pending += String(decoding: d, as: UTF8.self)
                while let r = pending.range(of: "\n") {
                    onLine(String(pending[..<r.lowerBound]))
                    pending = String(pending[r.upperBound...])
                }
            }
        }
        if let onLine, !pending.isEmpty { onLine(pending) }
        lock.withLock { finished = true }
    }

    var done: Bool { lock.withLock { finished } }
    var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
}

/// 715: while the dashboard is published (the marker), the DAEMON — started at login by its login item — keeps the
/// dashboard running: at its start and on a slow tick, when no `doz ui` holds this store's `ui.lock`, it starts one the
/// way `doz ui --detach --no-open` does (the double spawn: its parent is launchd; no browser). Never after the person said
/// stop: `doz ui stop` (or Ctrl-C of a dashboard in a terminal) writes `<store>/ui.stopped`; `doz ui` / `--detach`,
/// `doz try --ui` and `doz ui publish` remove it.
public enum PublishedDashboard {
    public static func stoppedFile(_ store: DozableStore) -> URL { store.root.appendingPathComponent("ui.stopped") }
    public static func markStopped(_ store: DozableStore) {
        let fd = open(stoppedFile(store).path, O_WRONLY | O_CREAT | O_CLOEXEC, 0o600)
        if fd >= 0 { close(fd) }
    }
    public static func clearStopped(_ store: DozableStore) { unlink(stoppedFile(store).path) }
    public static func stoppedByPerson(_ store: DozableStore) -> Bool { FileManager.default.fileExists(atPath: stoppedFile(store).path) }

    /// A `doz ui` holds this store's `ui.lock` (running, or starting).
    public static func uiRunning(_ store: DozableStore) -> Bool {
        let fd = open(store.root.appendingPathComponent("ui.lock").path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if flock(fd, LOCK_SH | LOCK_NB) == 0 { flock(fd, LOCK_UN); return false }
        return true
    }

    public enum Decision: Equatable, Sendable { case notPublished, stoppedByPerson, running, start }

    /// What the daemon does now (pure but for the files it reads).
    public static func decide(_ store: DozableStore) -> Decision {
        guard TailscalePublish.readMarker(store) != nil else { return .notPublished }
        if stoppedByPerson(store) { return .stoppedByPerson }
        return uiRunning(store) ? .running : .start
    }

    /// The daemon's look (each tick): start the dashboard when `decide` says so. The line for the daemon's log, or nil.
    public static func ensure(_ store: DozableStore, program: String) -> String? {
        guard decide(store) == .start else { return nil }
        do {
            let pid = try DetachedLauncher.spawnViaIntermediate(
                DetachedLauncher.uiIntermediateArgs(executable: program, store: store.root.path, extra: []), log: DetachedLauncher.uiLog(store.root))
            return "the dashboard is published and was not running — started it in the background (pid \(pid), \(program) ui --detach)"
        } catch {
            return "the dashboard is published and was not running — could not start it: \(error)"
        }
    }

    /// How often the daemon looks (60 s; a guarded test run may set `DOZ_TEST_UI_KEEP_INTERVAL` to 1–600 seconds).
    public static func interval(_ env: [String: String] = ProcessInfo.processInfo.environment) -> Double {
        if TestSafety.guarded(env), let s = env["DOZ_TEST_UI_KEEP_INTERVAL"].flatMap(Double.init), (1...600).contains(s) { return s }
        return 60
    }
}
