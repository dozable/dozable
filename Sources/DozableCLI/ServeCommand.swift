import ArgumentParser
import Darwin
import Foundation
import Security
import DozableKit
import DozableHost
import DozableWeb
import DozableTUI

// 606 — `doz serve`: the dashboard for the OTHER browsers of a home lab (owner rulings at the end of
// changes/606-*/606.01-DESIGN.md, plan 606.02-PLAN.md — workspace). Plain HTTP out of the box; HTTPS through the
// person's own reverse proxy (serve.public_origins, serve.trusted_proxies).
//
// 645 (owner: one dashboard command) — it is now `doz ui`'s LAN option: ONE process, ONE port, the Mac's browser signed
// in by the link and every other browser as a device, decided per request (`DozableWebServer.requestContext`). This
// file is the dashboard's LAN side: `LANDashboard` builds the LAN profile (the audit keeps it out of UICommand.swift,
// which opens browsers), and the device commands (`doz ui share|devices|revoke|rename|log|status`). `doz serve` stays
// for one release as a hidden alias (`doz serve` = `doz ui --lan`; its subcommands unchanged).

/// The LAN side of a running `doz ui`: the LAN profile's state and server, `serve.lock`, `serve.sock`, Bonjour.
enum LANDashboard {
    final class Handle: @unchecked Sendable {
        let server: DozableWebServer
        let state: WebServeState
        let config: WebServeConfig
        let root: URL
        let lockFD: Int32
        var listenFD: Int32 = -1
        var bonjour: WebBonjour?

        init(server: DozableWebServer, state: WebServeState, config: WebServeConfig, root: URL, lockFD: Int32) {
            self.server = server
            self.state = state
            self.config = config
            self.root = root
            self.lockFD = lockFD
        }

        /// Where the other browsers reach it.
        var origins: [String] { state.origins }

        /// serve.sock (the devices, invites and `doz doctor`'s probe — `WebServeControl`); `onStop` for its `stop`.
        func serveControl(onStop: @escaping @Sendable () -> Void) throws {
            listenFD = try WebServeControl.serve(root, server: server, onStop: onStop)
        }

        /// Bonjour (`serve.advertise`; never for a loopback-only LAN side). A failure is said, never fatal.
        func announce(json: Bool) {
            guard config.advertise, config.bind != .loopback else { return }
            let name = "Dozable on \(state.names.localHostName ?? "this Mac")"
            let server = self.server
            bonjour = WebBonjour.advertise(name: name, port: state.port) { error, registered in
                if error == 0 {
                    server.advertised = registered ?? name
                } else if !json {
                    Out.stderr("doz ui: not announced with Bonjour — \(WebBonjour.explain(error)). Browsers still reach it by address.\n")
                }
            }
        }

        func recordStop() { state.audit.record(WebAuditEntry(kind: "stop")) }

        /// serve.sock and serve/port go, serve.lock is released.
        func cleanUp() { WebServeControl.cleanUp(root, listenFD: listenFD, lockFD: lockFD) }

        /// What `doz ui --lan` prints at start (no key in it).
        func startText() -> String {
            var t = "  on your network: \(state.origins.first ?? "port \(state.port)")\n"
            let more = state.origins.dropFirst()
            let v6 = more.filter { $0.contains("[") }
            if !more.isEmpty {
                t += "  also: \(more.filter { !$0.contains("[") }.joined(separator: "  "))" + (v6.isEmpty ? "" : " (and \(v6.count) IPv6 address\(v6.count == 1 ? "" : "es"): doz ui status)") + "\n"
            }
            switch config.bind {
            case .lan: t += "  listening on this Mac's network interfaces and Tailscale (never a sandbox's network)\n"
            case .loopback: t += "  the other browsers through a reverse proxy on this Mac (serve.bind loopback)\n"
            case .addresses(let ips): t += "  the other browsers on \(ips.map(\.description).joined(separator: ", ")) only\n"
            }
            if config.publicOrigins.isEmpty {
                t += "  plain HTTP: another browser can do everything except type keys and tokens. For HTTPS behind your reverse proxy:\n"
                t += "    doz config set serve.public_origins https://doz.example.home   (the address your proxy serves)\n"
                t += "    doz config set serve.trusted_proxies 127.0.0.1,::1             (the proxy's address)\n"
                t += "    doz config set serve.bind loopback                             (a proxy on this Mac)\n"
            } else {
                t += "  behind your proxy: \(config.publicOrigins.map(\.description).joined(separator: ", "))\n"
                t += "    the proxy's upstream: http://\(config.bind == .loopback ? "127.0.0.1" : (state.names.names.first ?? "this-mac")):\(state.port) — pass Host (or X-Forwarded-Host),\n"
                t += "    X-Forwarded-Proto and X-Forwarded-For; allow WebSocket upgrades; do not buffer responses (live updates)\n"
                if config.trustedProxies.isEmpty {
                    t += "    ! serve.trusted_proxies is empty: no proxy is believed, so the public address is refused — set it to the proxy's address\n"
                }
                t += "    check it: doz doctor\n"
            }
            if let fw = Firewall.note() { t += fw + "\n" }
            return t
        }

        /// An invite at start — printed only on a terminal (it is a key for one browser).
        func printInvite() async {
            if isatty(STDOUT_FILENO) == 1 {
                let inv = await server.share(by: "the Mac").answer(origin: state.preferredOrigin, alsoAt: state.addressOrigins)
                Out.stdout("\n" + ServeShare.render(inv) + "\n")
            } else {
                Out.stdout("To let another browser in: doz ui share (on a terminal — an invite is a key).\n")
            }
        }
    }

    /// Bind the dashboard with its LAN side on `port` (0: a test's ephemeral one is never asked for here — the CLI's port
    /// is always fixed with the LAN). Takes `serve.lock`: an earlier `doz serve` still running holds it (and the port).
    static func bind(store: DozableStore, data: HostWebData, assets: WebAssets, settings: WebSettingsStore, port: Int,
                     launched: Bool) async throws -> Handle {
        let root = store.root
        let lockFD: Int32
        do {
            guard let fd = try WebServeControl.takeLock(root) else {
                throw HostError(.unavailable, "an earlier doz serve is running for this store (it holds the LAN's devices and port) — stop it: doz serve stop, then doz ui --lan")
            }
            lockFD = fd
        }
        var config = WebServeConfig(settings: settings)
        config.port = port
        // The port never moves silently: devices, an installed app and a bookmark belong to it.
        if let holder = PortHolder.describe(port) {
            WebServeControl.releaseLock(lockFD)
            throw HostError(.unavailable, "the dashboard's port is \(port), and \(holder) listens there — stop it, or choose another port: doz config set ui.port N")
        }
        let state = WebServeState(config: config, names: WebMacNames.current(), devices: WebDeviceStore(file: WebServeControl.devicesFile(root)),
                                  audit: WebServeAudit(file: WebServeControl.auditFile(root)), natSubnet: settings.current.string(SettingKey.natSubnet))
        state.detached = launched
        state.logPath = launched ? DetachedLauncher.uiLog(root).path : nil
        state.responsibleApp = HostCore.responsibleAppDescription
        let server: DozableWebServer
        do {
            server = try await DozableWebServer.bindServe(data: data, assets: assets, version: DozableCommand.version,
                                                        limits: try WebLimits(maximumConnections: 256), settings: settings, serve: state,
                                                        sessionsFile: WebControl.sessionsFile(store), revokedFile: WebControl.revokedFile(store),
                                                        operationsFile: WebControl.operationsFile(store))
        } catch {
            WebServeControl.releaseLock(lockFD)
            throw HostError(.unavailable, "could not listen on port \(port): \(error)")
        }
        WebServeControl.writePort(root, state.port)
        state.audit.record(WebAuditEntry(kind: "start", outcome: "\(state.origins.first ?? "") \(DozableCommand.version)"))
        return Handle(server: server, state: state, config: config, root: root, lockFD: lockFD)
    }

    /// The running dashboard of this store serves the LAN (its serve.sock answers).
    static func isServing(_ store: DozableStore) -> Bool {
        if case .success(let st)? = WebServeControl.request(store.root, "status", as: WebServeStatus.self) { return st.state == "running" }
        return false
    }

    /// After `doz ui --detach --lan`: where the other browsers reach it, and an invite (a terminal only).
    static func printDetached(_ store: DozableStore, invite: Bool) {
        guard case .success(let st)? = WebServeControl.request(store.root, "status", as: WebServeStatus.self), st.state == "running" else { return }
        Out.stdout("  on your network: \(st.origins.filter { !$0.contains("[") }.joined(separator: "  "))\n")
        guard invite else { return }
        if isatty(STDOUT_FILENO) == 1, case .success(let inv)? = WebServeControl.request(store.root, "share", as: WebServeInviteAnswer.self) {
            Out.stdout("\n" + ServeShare.render(inv) + "\n")
        } else {
            Out.stdout("To let another browser in: doz ui share (on a terminal — an invite is a key).\n")
        }
    }
}

/// A stop that runs once (a signal, or serve.sock's `stop`).
final class StopOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func first() -> Bool { lock.withLock { defer { done = true }; return !done } }
    var started: Bool { lock.withLock { done } }
}

/// The store's root as a URL.
private func root(_ g: GlobalOptions) -> URL { g.dozableStore.root }

/// 645: `doz serve` — the earlier name of `doz ui --lan`, kept for one release (hidden; its subcommands unchanged).
struct ServeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "serve",
        abstract: "The earlier name of doz ui --lan (the dashboard on your network).",
        discussion: "doz serve is now doz ui --lan: one dashboard for this Mac and your other browsers, on one port. Its subcommands are doz ui share, devices, revoke, rename, status, log and stop. This name goes in a later release.",
        shouldDisplay: false,
        subcommands: [ServeStart.self, ServeShare.self, ServeDevices.self, ServeRevoke.self, ServeRename.self, ServeStatus.self,
                      ServeLog.self, ServeStop.self],
        defaultSubcommand: ServeStart.self)
}

/// `doz serve [start]` = `doz ui start --lan`.
struct ServeStart: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "start", abstract: "The earlier name of doz ui start --lan.")
    @OptionGroup var o: UIStartOptions

    func validate() throws {
        try o.validate()
        if o.noLAN { throw ValidationError("doz serve is the dashboard on your network: --no-lan is doz ui") }
    }

    func run() async throws {
        if !o.g.json && !o.g.quiet && !o.launched && !o.launchDetached {
            Out.stderr("doz: `doz serve` is now `doz ui --lan` — one dashboard for this Mac and your network (this name goes in a later release)\n")
        }
        var options = o
        options.lan = true
        try await UIRunner(o: options).run()
    }
}

/// 645: `doz ui status` — whether the dashboard runs, where, its open pages, and its LAN side.
struct UIStatus: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status",
        abstract: "Whether doz ui runs for this store, where, how many pages are open, and (with the LAN option) where your other browsers reach it.")
    @OptionGroup var g: GlobalOptions

    struct Answer: Encodable {
        let running: Bool
        let origin: String?
        let pages: Int?
        let lan: WebServeStatus?
    }

    func run() async throws {
        let store = g.dozableStore
        let ui = WebControl.requestStatus(store)
        var lan: WebServeStatus?
        if case .success(let st)? = WebServeControl.request(store.root, "status", as: WebServeStatus.self), st.state == "running" { lan = st }
        if g.json { Out.json(Answer(running: ui != nil, origin: ui?.origin, pages: ui?.pages, lan: lan)); return }
        guard let ui else {
            let n = WebDeviceStore.listFile(WebServeControl.devicesFile(store.root)).count
            Out.stdout("doz ui is not running for \(store.root.path)\(n > 0 ? " (\(n) browser\(n == 1 ? "" : "s") let in on your network)" : "") — start it: doz ui\n")
            return
        }
        Out.stdout("doz ui is running at \(ui.origin) — \(ui.pages == 1 ? "1 page" : "\(ui.pages) pages") open\n")
        guard let st = lan else {
            Out.stdout("  this Mac only (the LAN option is off: doz config set ui.lan true, then doz ui restart)\n")
            return
        }
        Out.stdout("  on your network: \(st.origins.joined(separator: "  "))\n")
        var facts: [String] = []
        if let pid = st.pid { facts.append("pid \(pid)") }
        if let since = st.since { facts.append("since \(Out.ago(since))") }
        if let v = st.version { facts.append("doz \(v)") }
        if st.detached == true { facts.append("detached") }
        if !facts.isEmpty { Out.stdout("  " + facts.joined(separator: " · ") + "\n") }
        if let log = st.log { Out.stdout("  its log: \(log)\n") }
        if let app = st.responsibleApp { Out.stdout("  on behalf of: \(app) (what macOS asks about Local Network access)\n") }
        if !st.publicOrigins.isEmpty { Out.stdout("  behind your proxy: \(st.publicOrigins.joined(separator: ", "))\n") }
        Out.stdout("  \(st.devices) browser\(st.devices == 1 ? "" : "s") let in, \(st.openInvites ?? 0) open invite\((st.openInvites ?? 0) == 1 ? "" : "s")")
        Out.stdout(st.advertised.map { "; announced as \"\($0)\"\n" } ?? "\n")
    }
}

/// The Application Firewall, read only (`socketfilterfw`): a line when incoming connections to doz would be blocked.
enum Firewall {
    static func run(_ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/libexec/ApplicationFirewall/socketfilterfw")
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let d = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: d, as: UTF8.self)
    }

    static func note() -> String? {
        guard let state = run(["--getglobalstate"]), state.contains("enabled") else { return nil }
        let exe = URL(fileURLWithPath: HostLauncher.executablePath).resolvingSymlinksInPath().path
        let blocked = run(["--getappblocked", exe]) ?? ""
        if blocked.contains("permitted") { return nil }
        let block = run(["--getblockall"]) ?? ""
        if block.contains("ENABLED") || block.contains("enabled") {
            return "  ! the macOS firewall blocks all incoming connections (System Settings › Network › Firewall › Options) — other browsers cannot reach the dashboard until you allow it"
        }
        return "  ! the macOS firewall is on: macOS asks whether doz may accept incoming connections — answer Allow (or add \(exe) in System Settings › Network › Firewall › Options)"
    }
}

struct ServeShare: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "share",
        abstract: "An invite for one more browser on your network: a QR code, a short code and a link (each works once, for five minutes). Printed only on a terminal.")
    @OptionGroup var g: GlobalOptions

    func validate() throws {
        if g.json { throw ValidationError("an invite is a key for one browser — it is printed for a person, not as --json") }
        if isatty(STDOUT_FILENO) == 0 { throw ValidationError("doz ui share prints only to a terminal (stdout is redirected) — an invite is a key") }
    }

    func run() async throws {
        guard let r = WebServeControl.request(root(g), "share", as: WebServeInviteAnswer.self) else {
            throw fail(HostError(.unavailable, "the dashboard is not on your network for \(root(g).path) — start it with the LAN option: doz ui --lan"), g)
        }
        switch r {
        case .failure(let e): throw fail(e, g)
        case .success(let inv): Out.stdout(Self.render(inv))
        }
    }

    /// The QR code (black on white, whatever the terminal's colours), the code, the link, when it expires.
    static func render(_ inv: WebServeInviteAnswer) -> String {
        var t = ""
        if let rows = inv.qr?.rows, let qr = WebQR(rows: rows) {
            t += qr.terminalText(ansi: Terminal.current.colour)
        }
        let mins = max(1, Int((inv.expiresAt.timeIntervalSinceNow / 60).rounded()))
        t += "Let one more browser in (whichever is used first, within \(mins) min):\n"
        t += "  scan the QR code with a phone or tablet, or\n"
        t += "  type the code \(inv.code) on the dashboard's sign-in page (\(inv.link.components(separatedBy: "/#").first ?? "")), or\n"
        t += "  open the link: \(inv.link)\n"
        for alt in inv.alternates ?? [] { t += "     or by address: \(alt)\n" }
        t += "It is a key for one browser: do not paste it anywhere else.\n"
        return t
    }
}

struct ServeDevices: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "devices", abstract: "The browsers let in on your network: name, when first and last seen, from where, which browser.")
    @OptionGroup var g: GlobalOptions

    func run() async throws {
        let list: WebServeDevices
        if let r = WebServeControl.request(root(g), "devices", as: WebServeDevices.self) {
            switch r { case .failure(let e): throw fail(e, g); case .success(let l): list = l }
        } else {
            list = WebServeControl.offlineDevices(root(g))
        }
        if g.json { Out.json(list.devices); return }
        guard !list.devices.isEmpty else {
            Out.stdout("No browsers are let in\(list.running ? "" : " (the dashboard is not on your network now)") — an invite: doz ui share\n")
            return
        }
        var rows = [["ID", "NAME", "FIRST SEEN", "LAST SEEN", "FROM", "BROWSER"]]
        for d in list.devices {
            rows.append([d.id, d.name, Out.ago(d.created), Out.ago(d.lastSeen), d.lastAddress, String(d.userAgent.prefix(48))])
        }
        Out.stdout(Out.table(rows))
        if !list.running { Out.stdout("(the dashboard is not on your network now: doz ui --lan)\n") }
    }
}

struct ServeRevoke: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "revoke",
        abstract: "Remove a browser (by its ID from doz ui devices), or --all: it is signed out at once and needs a new invite.")
    @OptionGroup var g: GlobalOptions
    @Argument(help: "The device's ID (doz ui devices).") var id: String?
    @Flag(name: .long, help: "Every browser.") var all = false

    func validate() throws {
        if all == (id != nil) { throw ValidationError("name one device's ID, or --all") }
        if let id, !WebRoute.isDeviceID(id) { throw ValidationError("a device's ID is six letters and digits (doz ui devices)") }
    }

    func run() async throws {
        let gone: [WebDeviceView]
        if let r = WebServeControl.request(root(g), "revoke \(all ? "--all" : id!)", as: WebServeControl.Revoked.self) {
            switch r { case .failure(let e): throw fail(HostError(.notFound, e.message), g); case .success(let v): gone = v.revoked }
        } else {
            do { gone = try WebServeControl.offlineRevoke(root(g), id: all ? nil : id, by: "the Mac") } catch let r as WebRejection {
                throw fail(HostError(r == .notFound ? .notFound : .failed, r == .notFound ? "no device \(id ?? "") — doz ui devices lists them" : r.message), g)
            }
        }
        if g.json { Out.json(gone); return }
        Out.stdout(gone.isEmpty ? "No browsers were let in.\n" : gone.map { "removed \($0.name) (\($0.id))\n" }.joined())
    }
}

struct ServeRename: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rename", abstract: "Give a browser a name you will recognise (\"Kitchen iPad\").")
    @OptionGroup var g: GlobalOptions
    @Argument(help: "The device's ID (doz ui devices).") var id: String
    @Argument(help: "Its new name (1–60 characters).") var name: String

    func validate() throws {
        if !WebRoute.isDeviceID(id) { throw ValidationError("a device's ID is six letters and digits (doz ui devices)") }
        if !(1...60).contains(name.count) { throw ValidationError("a name is 1–60 characters") }
    }

    func run() async throws {
        let d: WebDeviceView
        let clean = name.replacingOccurrences(of: "\n", with: " ")
        if let r = WebServeControl.request(root(g), "rename \(id) \(clean)", as: WebDeviceView.self) {
            switch r { case .failure(let e): throw fail(HostError(.notFound, e.message), g); case .success(let v): d = v }
        } else {
            do { d = try WebServeControl.offlineRename(root(g), id: id, to: clean) } catch {
                throw fail(HostError(.notFound, "no device \(id) — doz ui devices lists them"), g)
            }
        }
        if g.json { Out.json(d) } else { Out.stdout("\(d.id) is now \(d.name)\n") }
    }
}

/// `doz serve status` (the alias) — the LAN side's status as before.
struct ServeStatus: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "The earlier name of doz ui status.")
    @OptionGroup var g: GlobalOptions

    func run() async throws {
        let st: WebServeStatus
        if let r = WebServeControl.request(root(g), "status", as: WebServeStatus.self) {
            switch r { case .failure(let e): throw fail(e, g); case .success(let s): st = s }
        } else {
            st = WebServeStatus(state: "stopped", origins: [], publicOrigins: [], port: nil, bind: nil,
                                devices: WebDeviceStore.listFile(WebServeControl.devicesFile(root(g))).count, openInvites: nil, advertised: nil)
        }
        if g.json { Out.json(st); return }
        if st.state != "running" {
            Out.stdout("the dashboard is not on your network for \(root(g).path) (\(st.devices) browser\(st.devices == 1 ? "" : "s") let in) — start it: doz ui --lan\n")
            return
        }
        Out.stdout("the dashboard is on your network — \(st.origins.joined(separator: "  ")) (doz serve is now doz ui --lan; this: doz ui status)\n")
    }
}

struct ServeLog: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "log", abstract: "What the other browsers did (the audit log): admissions, changes, terminals, refusals.")
    @OptionGroup var g: GlobalOptions
    @Option(name: [.customShort("n"), .customLong("lines")], help: "How many lines (newest last).") var lines = 50

    func run() async throws {
        let entries = Array(WebServeAudit.recent(WebServeControl.auditFile(root(g)), limit: max(1, min(lines, 10_000))).reversed())
        if g.json { Out.json(entries); return }
        guard !entries.isEmpty else { Out.stdout("Nothing yet.\n"); return }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        for e in entries {
            var parts = [f.string(from: e.time), e.kind]
            if let n = e.deviceName { parts.append(n + (e.device.map { " (\($0))" } ?? "")) }
            if let a = e.address { parts.append("from \(a)") }
            if let r = e.route { parts.append(r) }
            if let a = e.action { parts.append(a) }
            if let s = e.sandbox { parts.append(s) }
            if let o = e.outcome { parts.append("→ \(o)") }
            if let c = e.count { parts.append("×\(c)") }
            Out.stdout(parts.joined(separator: "  ") + "\n")
        }
    }
}

/// `doz serve stop` (the alias): the dashboard serving the LAN stops (an earlier doz serve too — over serve.sock).
struct ServeStop: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "stop", abstract: "The earlier name of doz ui stop (its browsers stay let in for the next start).")
    @OptionGroup var g: GlobalOptions

    func run() async throws {
        guard WebServeControl.ask(root(g), "stop") != nil else {
            throw fail(HostError(.unavailable, "the dashboard is not on your network for \(root(g).path) (doz ui stop stops this Mac's)"), g)
        }
        for _ in 0..<50 where FileManager.default.fileExists(atPath: WebServeControl.socket(root(g)).path) {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if !g.json { Out.stdout("stopped\n") }
    }
}

/// `doz doctor`'s LAN lines: whether the dashboard serves the LAN, and that each configured public origin (your reverse
/// proxy) comes back to THIS dashboard — over https, through a trusted proxy. The proof is a one-use token the dashboard
/// issues over serve.sock and answers on `GET /api/v1/serve/probe` only once.
enum ServeDoctor {
    static func checks(store: DozableStore, settings: DozableSettings) -> [DoctorCheck] {
        let root = store.root
        let configured = (settings.string(SettingKey.servePublicOrigins) ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard case .success(let st)? = WebServeControl.request(root, "status", as: WebServeStatus.self) else {
            if configured.isEmpty {
                return [DoctorCheck(check: "dashboard on your network", status: .ok, detail: "off — your other browsers: doz ui --lan")]
            }
            return [DoctorCheck(check: "dashboard on your network", status: .warn,
                                detail: "off, so serve.public_origins (\(configured.joined(separator: ", "))) cannot be checked — start it: doz ui --lan")]
        }
        var out = [DoctorCheck(check: "dashboard on your network", status: .ok,
                               detail: "on — \(st.origins.first ?? "") · \(st.devices) browser\(st.devices == 1 ? "" : "s") let in")]
        for o in st.publicOrigins { out.append(probe(root, origin: o)) }
        return out
    }

    static func probe(_ root: URL, origin: String) -> DoctorCheck {
        let name = "dashboard via \(origin)"
        guard case .success(let p)? = WebServeControl.request(root, "probe", as: WebServeControl.Probe.self),
              let url = URL(string: origin + "/api/v1/serve/probe") else {
            return DoctorCheck(check: name, status: .warn, detail: "the dashboard did not give a probe token — is it another version?")
        }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 6
        cfg.httpShouldSetCookies = false
        cfg.urlCache = nil
        var req = URLRequest(url: url)
        req.setValue(p.token, forHTTPHeaderField: "X-Doz-Probe")
        final class Box: @unchecked Sendable { var data: Data?; var response: HTTPURLResponse?; var error: Error? }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        // TEST seam (the proxy probe): DOZ_TEST_SERVE_CA=<pem> — the proxy's certificate is trusted ONLY when it chains to
        // that CA (a scratch one; never the keychain). Without it: the system's trust, as a browser would.
        let anchors = ProcessInfo.processInfo.environment["DOZ_TEST_SERVE_CA"].flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
            .map(TestAnchors.certificates) ?? []
        URLSession(configuration: cfg, delegate: anchors.isEmpty ? nil : TestAnchors(anchors), delegateQueue: nil).dataTask(with: req) { d, r, e in
            box.data = d; box.response = r as? HTTPURLResponse; box.error = e
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 8)
        if let e = box.error {
            return DoctorCheck(check: name, status: .fail, detail: "could not reach it from this Mac: \(e.localizedDescription)")
        }
        guard let r = box.response else { return DoctorCheck(check: name, status: .fail, detail: "no answer within 8 s") }
        let body = (box.data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
        let code = ((body["error"] as? [String: Any])?["code"] as? String) ?? ""
        switch r.statusCode {
        case 200:
            let scheme = body["scheme"] as? String ?? "?"
            if origin.hasPrefix("https:"), scheme != "https" {
                return DoctorCheck(check: name, status: .fail,
                                   detail: "it reached this dashboard, but as plain http — make the proxy send X-Forwarded-Proto: https (and keys stay refused there)")
            }
            return DoctorCheck(check: name, status: .ok, detail: "reaches this dashboard as \(scheme), through a trusted proxy")
        case 403 where code == "host-rejected":
            return DoctorCheck(check: name, status: .fail,
                               detail: "the dashboard refused that address — put the proxy's address in serve.trusted_proxies, and make the proxy pass Host (or X-Forwarded-Host) and X-Forwarded-Proto")
        case 404:
            return DoctorCheck(check: name, status: .fail, detail: "something answered, but not this dashboard — check the proxy's upstream (http://<this Mac>:<the dashboard's port>)")
        default:
            return DoctorCheck(check: name, status: .fail, detail: "answered HTTP \(r.statusCode)\(code.isEmpty ? "" : " (\(code))")")
        }
    }
}

/// `DOZ_TEST_SERVE_CA` (tests only): trust exactly these anchors for the doctor's probe.
final class TestAnchors: NSObject, URLSessionDelegate, @unchecked Sendable {
    let anchors: [SecCertificate]
    init(_ anchors: [SecCertificate]) { self.anchors = anchors }

    static func certificates(_ pem: String) -> [SecCertificate] {
        pem.components(separatedBy: "-----BEGIN CERTIFICATE-----").dropFirst().compactMap { part in
            let b64 = part.components(separatedBy: "-----END CERTIFICATE-----")[0].filter { !$0.isWhitespace }
            return Data(base64Encoded: b64).flatMap { SecCertificateCreateWithData(nil, $0 as CFData) }
        }
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust, let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil); return
        }
        SecTrustSetAnchorCertificates(trust, anchors as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        if SecTrustEvaluateWithError(trust, nil) { completionHandler(.useCredential, URLCredential(trust: trust)) } else { completionHandler(.cancelAuthenticationChallenge, nil) }
    }
}
