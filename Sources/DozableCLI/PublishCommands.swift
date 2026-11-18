// 715 — `doz ui publish tailscale`, `doz ui publish status`, `doz ui unpublish tailscale`, and doctor's rows for them.
// The rules (paths, argv, the LaunchAgent, the settings) are `TailscalePublish`'s (DozableHost); port 80's redirect is
// `WebPublishRedirect` (DozableWeb, run by doz ui). Not in a build without the dashboard (the helper).
#if !DOZ_NO_WEB
import ArgumentParser
import Darwin
import Foundation
import DozableKit
import DozableHost
import DozableWeb

struct UIPublish: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "publish",
        abstract: "Put the dashboard on your tailnet at its own https address (doz ui publish tailscale), or show how it is published.",
        discussion: """
        doz ui publish tailscale gives the dashboard its own address on your tailnet, https://<name>.<your tailnet>.ts.net, \
        with Tailscale's certificate; plain http there redirects to it. It runs Dozable's own Tailscale node, from Homebrew's \
        tailscale (brew install tailscale — it need not be linked: the Mac's own Tailscale, app or command, is left as it is), \
        kept running by a LaunchAgent of yours. The first time, it shows Tailscale's sign-in link and waits until you approve \
        it. It sets the dashboard up for it in the same step (a fixed ui.port, ui.lan on, serve.bind loopback, \
        serve.public_origins the address, serve.trusted_proxies 127.0.0.1,::1) and restarts the dashboard. A browser on \
        another device still gets in once with an invite: doz ui share on this Mac. doz ui unpublish tailscale undoes it.
        """,
        subcommands: [PublishTailscale.self, PublishStatus.self])
}

struct UIUnpublish: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "unpublish",
        abstract: "Take the dashboard off your tailnet (doz ui unpublish tailscale): this Mac only again.",
        subcommands: [UnpublishTailscale.self])
}

/// What `publish tailscale --json` and `publish status --json` print.
struct PublishAnswer: Encodable {
    struct Node: Encodable {
        var installed: Bool
        var program: String?
        var agent: String?
        var agentLoaded: Bool?
        var running: Bool
        var state: String?
        var signedIn: Bool
        var name: String?
        var dnsName: String?
    }
    struct Serve: Encodable { var https: String?; var http: String? }
    var published: Bool
    var address: String?
    var node: Node
    var serve: Serve?
    var settings: [String: String]
    var dashboard: String?
    /// The daemon starts the dashboard while published (false: `doz ui stop` was the last word).
    var keptByDaemon: Bool?
    var verdict: DoctorCheck?
}

enum PublishHelp {
    static let notInstalled = "Tailscale is not installed from Homebrew — brew install tailscale, then run this again (Dozable runs its own Tailscale node from it; the Mac's own Tailscale is left as it is)"
}

struct PublishTailscale: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "tailscale",
        abstract: "Put the dashboard on your tailnet at https://<name>.<your tailnet>.ts.net (Dozable's own Tailscale node; run it again any time — it re-applies).")
    @OptionGroup var g: GlobalOptions
    @Option(name: .long, help: "The node's name on your tailnet: letters, digits and hyphens (default: dozable-<this Mac's local hostname>).") var name: String?
    @Option(name: .long, help: "The dashboard's port (default: ui.port when set, else the running dashboard's, else a free one) — it becomes ui.port.") var port: Int?
    @Option(name: .long, help: "How long to wait for the sign-in to be approved, in seconds (default 300).") var wait = 300
    @Option(name: .customLong("adopt-state"), help: "Take over a Tailscale node you started yourself: copy its state folder (stop its tailscaled first) — the node keeps its name and address.") var adoptState: String?

    func validate() throws {
        if let name, TailscalePublish.validName(name) == nil { throw ValidationError("--name is 1–63 letters, digits and hyphens, not starting or ending with a hyphen") }
        if let port, !(1024...65_535).contains(port) { throw ValidationError("--port is a port 1024–65535") }
        if !(5...3600).contains(wait) { throw ValidationError("--wait is 5–3600 seconds") }
    }

    func run() async throws {
        let env = ProcessInfo.processInfo.environment
        let store = g.dozableStore
        let paths = TailscalePublish.paths(store)
        guard let bin = TailscalePublish.locate(env: env) else { throw fail(HostError(.unavailable, PublishHelp.notInstalled), g) }
        guard TailscalePublish.socketFits(paths.socket), TailscalePublish.socketFits(paths.redirectSocket) else {
            throw fail(HostError(.unavailable, "the store's path is too long for a socket (\(paths.socket.path)) — use a shorter store"), g)
        }
        let settings = DozableSettings.load()
        if let e = settings.fileError { throw fail(HostError(.failed, "\(e) — fix the settings file first; nothing was changed"), g) }
        let nodeName = name.flatMap(TailscalePublish.validName) ?? TailscalePublish.defaultName(mac: WebAppName.current(env))
        func say(_ s: String) { if g.json { Out.stderr(s + "\n") } else if !g.quiet { Out.stdout(s + "\n") } }

        // The dashboard's port: --port, else ui.port when set, else the running dashboard's, else this store's last when
        // free, else the OS's pick.
        let running = WebControl.requestStatus(store)
        let runningPort = running.flatMap { Int($0.origin.split(separator: ":").last ?? "") }
        let chosen: Int
        if let port { chosen = port }
        else if settings.int(SettingKey.uiPort) != 0 { chosen = settings.int(SettingKey.uiPort) }
        else if let runningPort { chosen = runningPort }
        else if let p = WebControl.rememberedPort(store), !WebLoopbackAddress.inUse(p) { chosen = p }
        else if let p = TailscalePublish.freeLoopbackPort() { chosen = p }
        else { throw fail(HostError(.unavailable, "no free port on 127.0.0.1 for the dashboard — set one: doz config set ui.port N"), g) }

        // Adopt a node started by hand (its state, so it keeps its name and address).
        if let adoptState { try adopt(from: adoptState, into: paths) }

        // The node, kept running by its LaunchAgent.
        do {
            if let refused = try TailscalePublish.installAgent(store, bin) {
                throw fail(HostError(.failed, "launchd did not load Dozable's Tailscale node (\(refused)) — run this from a terminal in your own desktop session"), g)
            }
        } catch let e as ExitCode { throw e } catch {
            throw fail(HostError(.failed, "could not write Dozable's Tailscale node's LaunchAgent: \(error.localizedDescription)"), g)
        }
        var status: TailscalePublish.NodeStatus?
        let end = Date().addingTimeInterval(20)
        while Date() < end {
            if let s = TailscalePublish.status(bin, paths, timeout: 5) { status = s; break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard var node = status else {
            throw fail(HostError(.unavailable, "Dozable's Tailscale node did not start within 20 s — its log: \(DisplayPath.tilde(paths.log.path))"), g)
        }

        // Signed in: re-apply the name. Not yet: `up`, showing Tailscale's link, waiting for the approval.
        if node.signedIn {
            let r = TailscalePublish.run(TailscalePublish.cli(bin, paths, TailscalePublish.setArguments(name: nodeName)), timeout: 20)
            if !r.ok { throw fail(HostError(.failed, "Tailscale did not take the name \(nodeName): \(r.reason)"), g) }
        } else {
            let shown = LinkOnce()
            let wait = self.wait, json = g.json
            let r = TailscalePublish.run(TailscalePublish.cli(bin, paths, TailscalePublish.upArguments(name: nodeName, timeout: wait)),
                                         timeout: Double(wait) + 15, onLine: { line in
                guard let link = TailscalePublish.link(in: line), shown.first(link) else { return }
                let text = "Sign Dozable's Tailscale node in to your tailnet — open this link and approve it:\n  \(link)\nwaiting up to \(wait / 60 > 0 ? "\(wait / 60) min" : "\(wait) s") for it…"
                if json { Out.stderr(text + "\n") } else { Out.stdout(text + "\n") }
            })
            node = TailscalePublish.status(bin, paths) ?? node
            if !node.signedIn {
                let why = r.timedOut || r.reason.lowercased().contains("timeout") ? "not approved yet" : r.reason
                throw fail(HostError(.unavailable, "Dozable's Tailscale node is not signed in (\(why)). It keeps running: approve the link, then run the same command again to continue — doz ui publish tailscale"), g)
            }
        }
        node = TailscalePublish.status(bin, paths) ?? node
        guard let dns = node.dnsName else {
            throw fail(HostError(.unavailable, "Tailscale gave the node no address yet (\(node.backendState)) — run the same command again in a moment"), g)
        }
        let origin = TailscalePublish.origin(dnsName: dns)

        // The dashboard's settings, through the settings code.
        do { try TailscalePublish.apply(TailscalePublish.publishSettings(port: chosen, origin: origin), to: settings) } catch let e as SettingsError {
            throw fail(HostError(.failed, e.message), g)
        }
        do { try TailscalePublish.writeMarker(store, .init(name: node.hostName ?? nodeName, origin: origin, port: chosen, published: Date())) } catch {
            throw fail(HostError(.failed, "could not write \(paths.marker.path): \(error.localizedDescription)"), g)
        }

        // The dashboard restarts (or starts in the background) with them — then port 80's redirect is there to point at.
        PublishedDashboard.clearStopped(store)
        let ui = try await PublishDashboard.restartOrStart(store, g, say: say)

        // Serving: what this node served before is replaced (it is Dozable's own node).
        _ = TailscalePublish.run(TailscalePublish.cli(bin, paths, TailscalePublish.serveResetArguments()), timeout: 20)
        let json = g.json
        for args in [TailscalePublish.serveHTTPSArguments(port: chosen), TailscalePublish.serveHTTPArguments(paths)] {
            let shown = LinkOnce()
            let r = TailscalePublish.run(TailscalePublish.cli(bin, paths, args), timeout: 60, onLine: { line in
                guard let link = TailscalePublish.link(in: line), shown.first(link) else { return }
                let text = "Tailscale asks for this first (HTTPS certificates for your tailnet):\n  \(link)"
                if json { Out.stderr(text + "\n") } else { Out.stdout(text + "\n") }
            })
            if !r.ok {
                throw fail(HostError(.failed, "tailscale serve did not take it (\(r.reason)) — once it is fixed, run the same command again"), g)
            }
        }

        if g.json {
            Out.json(PublishStatus.gather(store, g))
            return
        }
        Out.stdout("The dashboard is on your tailnet: \(origin)\n")
        Out.stdout("  Dozable's Tailscale node \(node.hostName ?? nodeName) — kept running by \(DisplayPath.tilde(TailscalePublish.plistURL(store, folder: LaunchAgentsFolder.current()).path))\n")
        Out.stdout("  \(origin) → this dashboard (\(ui ?? "http://127.0.0.1:\(chosen)")); http:// redirects to https://\n")
        Out.stdout("Next: let a browser on another device in, once — run doz ui share on this Mac and open its link there (or type its code at \(origin)).\n")
    }

    /// Copy a hand-started node's state folder into ours (only when ours has none, and only when no tailscaled answers on
    /// a socket in it — two copies of one node would fight).
    func adopt(from dir: String, into paths: TailscalePublish.Paths) throws {
        let src = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath).standardizedFileURL
        let fm = FileManager.default
        guard fm.fileExists(atPath: src.appendingPathComponent("tailscaled.state").path) else {
            throw fail(HostError(.notFound, "\(src.path) has no tailscaled.state — not a Tailscale node's state folder"), g)
        }
        for item in (try? fm.contentsOfDirectory(atPath: src.path)) ?? [] where item.hasSuffix(".sock") {
            if TailscalePublish.socketAnswers(src.appendingPathComponent(item).path) {
                throw fail(HostError(.invalid, "a tailscaled still runs on \(src.appendingPathComponent(item).path) — stop it first (the same node twice would fight)"), g)
            }
        }
        if fm.fileExists(atPath: paths.stateDir.appendingPathComponent("tailscaled.state").path) {
            throw fail(HostError(.exists, "Dozable's node already has a state (\(DisplayPath.tilde(paths.stateDir.path))) — doz ui unpublish tailscale --logout removes it first"), g)
        }
        try? fm.createDirectory(at: paths.stateDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for item in (try? fm.contentsOfDirectory(atPath: src.path)) ?? [] where !item.hasSuffix(".sock") && !item.hasSuffix(".log") {
            let to = paths.stateDir.appendingPathComponent(item)
            try? fm.removeItem(at: to)
            do { try fm.copyItem(at: src.appendingPathComponent(item), to: to) } catch {
                throw fail(HostError(.failed, "could not copy \(item) from \(src.path): \(error.localizedDescription)"), g)
            }
        }
    }
}

/// A link is said once.
final class LinkOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: Set<String> = []
    func first(_ s: String) -> Bool { lock.withLock { seen.insert(s).inserted } }
}

enum PublishDashboard {
    /// Restart the running dashboard (it reads the new settings), or start one in the background. Its origin.
    static func restartOrStart(_ store: DozableStore, _ g: GlobalOptions, say: (String) -> Void) async throws -> String? {
        if WebControl.requestStatus(store) != nil {
            guard let r = WebControl.requestRestart(store) else { return nil }
            if case .failure(let e) = r { throw fail(e, g) }
            let end = Date().addingTimeInterval(30)
            var gone = false
            while Date() < end {
                let s = WebControl.requestStatus(store)
                if s == nil { gone = true } else if gone {
                    if !LANDashboard.isServing(store) {
                        say("note: the running dashboard did not take the new settings (started with --no-lan, or DOZ_UI_LAN / DOZ_UI_PORT set?) — stop it and start it again: doz ui stop, then doz ui --detach")
                    }
                    say("the dashboard restarted with the new settings (\(s!.origin))")
                    return s!.origin
                }
                try? await Task.sleep(for: .milliseconds(150))
            }
            throw fail(HostError(.failed, "the dashboard did not come back within 30 s after its restart — its terminal or \(DisplayPath.tilde(DetachedLauncher.uiLog(store.root).path)) says why"), g)
        }
        let log = DetachedLauncher.uiLog(store.root)
        let pid: pid_t
        do {
            pid = try DetachedLauncher.spawnViaIntermediate(
                DetachedLauncher.uiIntermediateArgs(executable: StableExecutable.path(), store: store.root.path, extra: []), log: log)
        } catch let e as HostError { throw fail(e, g) }
        let end = Date().addingTimeInterval(20)
        while Date() < end {
            if let s = WebControl.requestStatus(store) {
                say("the dashboard is running in the background (\(s.origin)) — doz ui stop stops it")
                return s.origin
            }
            if kill(pid, 0) != 0 { break }
            try? await Task.sleep(for: .milliseconds(150))
        }
        throw fail(HostError(.unavailable, "the dashboard did not start in the background — its log: \(DisplayPath.tilde(log.path))"), g)
    }

    /// Restart the running dashboard, if one runs (after unpublishing). Its origin, or nil.
    static func restartIfRunning(_ store: DozableStore) async -> String? {
        guard WebControl.requestStatus(store) != nil, case .success? = WebControl.requestRestart(store) else { return nil }
        let end = Date().addingTimeInterval(30)
        var gone = false
        while Date() < end {
            let s = WebControl.requestStatus(store)
            if s == nil { gone = true } else if gone { return s!.origin }
            try? await Task.sleep(for: .milliseconds(150))
        }
        return nil
    }

    /// The running dashboard's port (nil: none runs).
    static func runningPort(_ store: DozableStore) -> Int? {
        WebControl.requestStatus(store).flatMap { Int($0.origin.split(separator: ":").last ?? "") }
    }
}

struct PublishStatus: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status",
        abstract: "How the dashboard is published: Dozable's Tailscale node (running, signed in, name, address), what it serves, the settings, and whether the address reaches this dashboard.")
    @OptionGroup var g: GlobalOptions

    static func gather(_ store: DozableStore, _ g: GlobalOptions) -> PublishAnswer {
        let bin = TailscalePublish.locate()
        let paths = TailscalePublish.paths(store)
        let marker = TailscalePublish.readMarker(store)
        let agent = TailscalePublish.agentState(store, binaries: bin)
        let st = bin.flatMap { TailscalePublish.status($0, paths) }
        let serve = (st != nil ? bin : nil).flatMap { TailscalePublish.serveConfig($0, paths) }
        let s = DozableSettings.load()
        var settings: [String: String] = [:]
        let rows = s.report().settings
        for k in [SettingKey.uiPort, SettingKey.uiLAN, SettingKey.serveBind, SettingKey.servePublicOrigins, SettingKey.serveTrustedProxies] {
            settings[k] = rows.first { $0.key == k }?.value.plain ?? ""
        }
        let address = marker?.origin ?? st?.dnsName.map(TailscalePublish.origin)
        var verdict: DoctorCheck?
        if marker != nil, let address, case .success(let lan)? = WebServeControl.request(store.root, "status", as: WebServeStatus.self),
           lan.publicOrigins.contains(address) {
            verdict = ServeDoctor.probe(store.root, origin: address)
        }
        return PublishAnswer(
            published: marker != nil,
            address: address,
            node: .init(installed: bin != nil, program: bin?.tailscaled, agent: agent?.installed == true ? agent?.path : nil, agentLoaded: agent?.loaded,
                        running: st != nil, state: st?.backendState, signedIn: st?.signedIn ?? false, name: st?.hostName, dnsName: st?.dnsName),
            serve: serve.map { .init(https: $0.https, http: $0.http) },
            settings: settings,
            dashboard: WebControl.requestStatus(store)?.origin,
            keptByDaemon: marker != nil ? !PublishedDashboard.stoppedByPerson(store) : nil,
            verdict: verdict)
    }

    func run() async throws {
        let a = Self.gather(g.dozableStore, g)
        if g.json { Out.json(a); return }
        if !a.published && !a.node.running {
            Out.stdout("The dashboard is not published\(a.node.installed ? "" : " (and Tailscale is not installed from Homebrew)") — doz ui publish tailscale puts it on your tailnet\n")
            return
        }
        Out.stdout(a.published ? "Published on your tailnet: \(a.address ?? "(no address yet)")\n" : "Not published (Dozable's Tailscale node runs: doz ui unpublish tailscale stops it)\n")
        let node = a.node
        Out.stdout("  node: \(node.running ? "running" : "not running")\(node.agent.map { " — LaunchAgent \(DisplayPath.tilde($0))\(node.agentLoaded == true ? ", loaded" : ", not loaded")" } ?? " — no LaunchAgent")\n")
        if node.running {
            Out.stdout("  \(node.signedIn ? "signed in" : "not signed in (\(node.state ?? "?")) — doz ui publish tailscale shows the sign-in link")\(node.name.map { " as \($0)" } ?? "")\(node.dnsName.map { " (\($0))" } ?? "")\n")
        }
        if let s = a.serve {
            Out.stdout("  serves: https → \(s.https ?? "nothing"); http → \(s.http.map { $0.hasPrefix("unix:") ? "the redirect to https" : $0 } ?? "nothing")\n")
        }
        Out.stdout("  settings: " + a.settings.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value.isEmpty ? "(unset)" : $0.value)" }.joined(separator: " · ") + "\n")
        Out.stdout("  dashboard: \(a.dashboard.map { "running at \($0)" } ?? "not running — doz ui --detach")\n")
        if a.published {
            Out.stdout(a.keptByDaemon == true ? "  the dashboard starts with the daemon while published\n"
                       : "  the daemon does not start the dashboard now: doz ui stop was the last word (doz ui --detach starts it again)\n")
        }
        if let v = a.verdict { Out.stdout("  the address: \(v.status == .ok ? "" : "\(v.status.rawValue.uppercased()): ")\(v.detail)\n") }
    }
}

struct UnpublishTailscale: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "tailscale",
        abstract: "Stop serving the dashboard on your tailnet and stop Dozable's Tailscale node; the dashboard is this Mac's only again (ui.port is kept).")
    @OptionGroup var g: GlobalOptions
    @Flag(name: .long, help: "Also sign the node out of your tailnet and remove its state (publishing again then asks to sign in again, as a new device).") var logout = false

    func run() async throws {
        let store = g.dozableStore
        let paths = TailscalePublish.paths(store)
        let bin = TailscalePublish.locate()
        var lines: [String] = []
        if let bin, TailscalePublish.status(bin, paths) != nil {
            let r = TailscalePublish.run(TailscalePublish.cli(bin, paths, TailscalePublish.serveResetArguments()), timeout: 20)
            lines.append(r.ok ? "stopped serving the dashboard on your tailnet" : "tailscale serve reset: \(r.reason)")
            if logout {
                let o = TailscalePublish.run(TailscalePublish.cli(bin, paths, TailscalePublish.logoutArguments()), timeout: 30)
                lines.append(o.ok ? "signed Dozable's Tailscale node out of your tailnet" : "tailscale logout: \(o.reason)")
            }
        }
        if TailscalePublish.removeAgent(store) { lines.append("stopped Dozable's Tailscale node and removed its LaunchAgent") }
        if logout {
            try? FileManager.default.removeItem(at: paths.stateDir)
            unlink(paths.socket.path)
            lines.append("removed the node's state (\(DisplayPath.tilde(paths.stateDir.path)))")
        }
        let wasPublished = TailscalePublish.readMarker(store) != nil
        unlink(paths.marker.path)
        do { try TailscalePublish.apply(TailscalePublish.unpublishSettings(), to: DozableSettings.load()) } catch let e as SettingsError {
            throw fail(HostError(.failed, "\(e.message) — the dashboard's settings were not put back"), g)
        }
        lines.append("the dashboard is this Mac's only again (ui.lan false; serve.public_origins, serve.trusted_proxies and serve.bind back to their defaults; ui.port kept)")
        if let o = await PublishDashboard.restartIfRunning(store) { lines.append("the dashboard restarted (\(o))") }
        if g.json { Out.jsonLine(["unpublished": wasPublished ? "true" : "false", "logout": logout ? "true" : "false"]); return }
        for l in lines { Out.stdout(l + "\n") }
    }
}

/// `doz doctor`'s rows for a published dashboard (only when it is published, or its LaunchAgent is there).
enum PublishDoctor {
    static func checks(store: DozableStore) -> [DoctorCheck] {
        let marker = TailscalePublish.readMarker(store)
        let bin = TailscalePublish.locate()
        let agent = TailscalePublish.agentState(store, binaries: bin)
        guard marker != nil || agent?.installed == true else { return [] }
        let paths = TailscalePublish.paths(store)
        var out: [DoctorCheck] = []
        guard let bin else { return [DoctorCheck(check: "tailscale node", status: .fail, detail: PublishHelp.notInstalled)] }
        if let agent {
            if !agent.installed {
                out.append(DoctorCheck(check: "tailscale node", status: .fail, detail: "no LaunchAgent keeps it running — doz ui publish tailscale adds it again"))
            } else if !agent.loaded {
                out.append(DoctorCheck(check: "tailscale node", status: .fail, detail: "its LaunchAgent is not loaded (\(DisplayPath.tilde(agent.path))) — doz ui publish tailscale loads it"))
            } else if !agent.current {
                out.append(DoctorCheck(check: "tailscale node", status: .warn, detail: "its LaunchAgent runs another program or folder than this doz would — doz ui publish tailscale rewrites it"))
            }
        }
        guard let st = TailscalePublish.status(bin, paths) else {
            out.append(DoctorCheck(check: "tailscale node", status: .fail, detail: "not answering on \(DisplayPath.tilde(paths.socket.path)) — its log: \(DisplayPath.tilde(paths.log.path))"))
            return out
        }
        if out.isEmpty { out.append(DoctorCheck(check: "tailscale node", status: .ok, detail: "running (\(DisplayPath.tilde(bin.tailscaled)), kept running by its LaunchAgent)")) }
        guard st.signedIn else {
            out.append(DoctorCheck(check: "tailscale login", status: .fail, detail: "not signed in (\(st.backendState)) — doz ui publish tailscale shows the sign-in link"))
            return out
        }
        out.append(DoctorCheck(check: "tailscale login", status: .ok, detail: "signed in as \(st.hostName ?? "?")\(st.dnsName.map { " (\($0))" } ?? "")"))
        let serve = TailscalePublish.serveConfig(bin, paths)
        let settingsPort = DozableSettings.load().int(SettingKey.uiPort)
        let port = PublishDashboard.runningPort(store) ?? (settingsPort != 0 ? settingsPort : marker?.port ?? 0)
        let want = TailscalePublish.httpsTarget(port: port)
        switch serve?.https {
        case nil:
            out.append(DoctorCheck(check: "tailscale https", status: .fail, detail: "the node serves nothing on 443 — doz ui publish tailscale"))
        case want?:
            out.append(DoctorCheck(check: "tailscale https", status: .ok, detail: "\(st.dnsName.map(TailscalePublish.origin) ?? "443") → \(want), the dashboard's port"))
        case let other?:
            out.append(DoctorCheck(check: "tailscale https", status: .fail,
                                   detail: "443 goes to \(other), but the dashboard's port is \(port) — doz ui publish tailscale points it at the dashboard again"))
        }
        out.append(PublishedDashboard.stoppedByPerson(store)
            ? DoctorCheck(check: "tailscale ui", status: .warn, detail: "doz ui stop was the last word: the daemon does not start the dashboard (doz ui --detach starts it, and it starts with the daemon again)")
            : DoctorCheck(check: "tailscale ui", status: .ok, detail: "the dashboard starts with the daemon while published"))
        let redirect = TailscalePublish.httpTarget(paths)
        if serve?.http != redirect {
            out.append(DoctorCheck(check: "tailscale http", status: .fail,
                                   detail: "port 80 \(serve?.http.map { "goes to \($0)" } ?? "serves nothing"), not to the redirect to https — doz ui publish tailscale"))
        } else if WebControl.requestStatus(store) == nil {
            out.append(DoctorCheck(check: "tailscale http", status: .warn, detail: "the dashboard is not running, so neither is the redirect from http (doz ui --detach)"))
        } else if let origin = marker?.origin, let a = TailscalePublish.askRedirect(paths.redirectSocket.path), a.status == 308,
                  a.location == origin + "/doctor" {
            out.append(DoctorCheck(check: "tailscale http", status: .ok, detail: "http:// redirects to \(origin)"))
        } else {
            out.append(DoctorCheck(check: "tailscale http", status: .fail,
                                   detail: "the redirect from http does not answer as it should — doz ui restart (a dashboard started before publishing has none)"))
        }
        return out
    }
}
#endif
