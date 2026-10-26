import Foundation
import DozableKit

// 617 (RP-1, owner: "web port forwarding first"): a sandbox's web ports on the Mac's loopback. What a forward is and
// why it is safe: `DozableKit/PortForwarding.swift`; the design: changes/617-*/617.10-WEB-PORT-FORWARD.md (workspace).
// The recipe's own ports (`ports@1`) and the ones a person added (`doz ports add`, kept in the sandbox's record) are
// bound when the sandbox comes to run (`handleEvent`) and closed when it stops, sleeps or hibernates.

extension HostCore {
    /// One forward the sandbox should have: from its recipe, or added.
    struct WantedPort {
        var port: AgentRecipe.WebPort
        var origin: String
    }

    /// The forwards a sandbox should have — its recipe's, then the added ones (a port the recipe has is the recipe's).
    func wantedPorts(_ m: Managed) -> [WantedPort] {
        var out: [WantedPort] = []
        let recipe = m.config.spec.imageSpec.flatMap { ImageChoice.parse($0.name) }?.agent.recipe
        for p in recipe?.ports?.ports ?? [] { out.append(WantedPort(port: p, origin: "recipe")) }
        for e in m.config.ports ?? [] where !out.contains(where: { $0.port.port == e.port }) {
            out.append(WantedPort(port: AgentRecipe.WebPort(port: e.port, title: e.title ?? "port \(e.port)", path: e.path), origin: "added"))
        }
        return Array(out.prefix(PortForwarding.maximumPerSandbox))
    }

    /// Bind every wanted forward of a RUNNING sandbox that is not listening yet. Remembers each Mac port it got.
    /// `settle`: called on the phase event — the sandbox may say `running` a moment after it announced it, so wait
    /// for it (up to 10 s) rather than miss the start.
    func bindPorts(_ name: String, settle: Bool = false) async {
        guard !readOnly, managed[name] != nil else { return }
        if settle {
            for _ in 0..<40 {
                guard let m = managed[name] else { return }
                if await effectivePhase(m) == .running { break }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        guard let m = managed[name], await effectivePhase(m) == .running else { return }
        let wanted = wantedPorts(m)
        guard !wanted.isEmpty else { return }
        let have = portTable.forwards(of: name)
        let sandbox = m.sandbox
        var remembered = m.config.portMacPorts ?? [:]
        var changed = false
        for w in wanted where have[w.port.port].map({ !$0.isStopped }) != true {
            let guest = w.port.port
            let candidates = PortForwarding.macPortCandidates(guest: guest, previous: remembered[String(guest)])
            do {
                let f = try StandingForward(sandbox: name, guestPort: guest, candidates: candidates,
                                            openStream: { try await sandbox.openGuestStream([GuestCommand.deckholdPath, "connect", "-p", String(guest)]) })
                portTable.set(f)
                f.start()
                let previous = remembered[String(guest)]
                let moved = f.macPort == guest ? ""
                    : guest < PortForwarding.lowestMacPort ? " (\(guest) is below 1024 — never bound on the Mac)"
                    : previous == f.macPort ? " (the port it had before; \(guest) was in use)"
                    : " (\(guest) was in use)"
                note(name, "\(w.port.title): the sandbox's port \(guest) is at \(PortForwarding.url(macPort: f.macPort, path: w.port.path)) on this Mac\(moved)")
                if previous != f.macPort { remembered[String(guest)] = f.macPort; changed = true }
            } catch {
                portTable.fail(name, guest, error.localizedDescription)
                note(name, "\(w.port.title): could not forward port \(guest) — \(error.localizedDescription)")
            }
        }
        if changed, let mm = managed[name] {
            mm.config.portMacPorts = remembered
            try? mm.config.write(store.configFile(name))
        }
    }

    /// Close every forward of a sandbox (it stopped, slept, hibernated or went away).
    nonisolated func unbindPorts(_ name: String, why: String) {
        let gone = portTable.remove(name)
        if !gone.isEmpty {
            let list = gone.map { "\($0.guestPort)→\($0.macPort)" }.sorted().joined(separator: ", ")
            Task { await self.note(name, "web port forwards closed (\(why)): \(list)") }
        }
    }

    /// What `doz ports` and the dashboard show.
    func portRows(_ m: Managed, running: Bool) -> [PortForwardRow] {
        let live = portTable.forwards(of: m.name)
        let failed = portTable.failures(of: m.name)
        return wantedPorts(m).map { w in
            let p = w.port
            var row = PortForwardRow(port: p.port, title: p.title, path: p.openPath, protocol: p.protocol ?? "http", origin: w.origin,
                                     state: "stopped", macPort: m.config.portMacPorts?[String(p.port)], auth: p.auth, tokenHint: p.tokenHint)
            if running, let f = live[p.port], !f.isStopped {
                row.state = "listening"
                row.macPort = f.macPort
                if p.isHTTP { row.url = PortForwarding.url(macPort: f.macPort, path: p.path) }
            } else if running, let why = failed[p.port] {
                row.state = "failed"
                row.why = why
            }
            if let mp = row.macPort, mp != p.port { row.moved = true }
            if running { row.serving = portServing[m.name].map { $0.ports.contains(p.port) } }
            if w.origin == "recipe", let serve = recipeServe(m), !serve.isEmpty { row.serveHint = serve.joined(separator: " ") }
            if w.origin == "recipe", p.isHTTP, let s = p.signIn { row.signIn = s.command }       // 666
            return row
        }
    }

    func recipeServe(_ m: Managed) -> [String]? {
        m.config.spec.imageSpec.flatMap { ImageChoice.parse($0.name) }?.agent.recipe?.ports?.serve
    }

    /// Which ports a program in a RUNNING sandbox listens on: the guest's own /proc/net/tcp and tcp6, read by one
    /// utility exec, at most every `maxAge` seconds per sandbox (a look — the page's sandbox view, `doz ports` — never
    /// the overview's poll, which only starts a background read at most every 15 s). Only for a sandbox with web ports.
    func refreshServing(_ name: String, maxAge: TimeInterval) async {
        guard !readOnly, let m = managed[name], !wantedPorts(m).isEmpty else { return }
        if let c = portServing[name], Date().timeIntervalSince(c.checked) < maxAge { return }
        guard await effectivePhase(m) == .running else { portServing[name] = nil; return }
        portServing[name] = (Date(), portServing[name]?.ports ?? [])      // one read at a time
        let out = try? await m.sandbox.exec(["cat", "/proc/net/tcp", "/proc/net/tcp6"], timeoutSeconds: 5)
        if let text = out?.output { portServing[name] = (Date(), Self.listeningPorts(procNetTCP: text)) }
        else { portServing[name] = nil }
    }

    /// /proc/net/tcp(6) → the local ports in state LISTEN (0A). Pure.
    nonisolated static func listeningPorts(procNetTCP text: String) -> Set<Int> {
        var out = Set<Int>()
        for line in text.split(separator: "\n") {
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count > 3, f[3] == "0A", let colon = f[1].lastIndex(of: ":"),
                  let port = Int(f[1][f[1].index(after: colon)...], radix: 16) else { continue }
            out.insert(port)
        }
        return out
    }

    /// 666: `port-open` — open a running sandbox's web port in this Mac's browser, signed in when its recipe declares a
    /// sign-in command (`PortSignIn`: run as the session's user, with a session's environment; the link never leaves this
    /// process). A port without one is opened as it is. Never starts or wakes anything: its ports listen while it runs.
    func portOpen(_ r: HostRequest) async throws -> PortOpened {
        let m = try get(r.name)
        guard let port = r.openPort else { throw HostError(.invalid, "which port? (doz open \(m.name) PORT)") }
        guard let w = wantedPorts(m).first(where: { $0.port.port == port }), w.port.isHTTP else {
            throw HostError(.notFound, "\(m.name) forwards no web port \(port)")
        }
        let phase = await effectivePhase(m)
        guard phase == .running else {
            throw HostError(.invalidPhase, "\(m.name) is \(PhaseName.label(phase)) — its ports listen while it runs")
        }
        await bindPorts(m.name)                                    // a forward that failed earlier is tried again
        guard let f = portTable.forwards(of: m.name)[port], !f.isStopped else {
            throw HostError(.unavailable, "\(w.port.title) (port \(port)) is not listening on this Mac: \(portTable.failures(of: m.name)[port] ?? "no forward")")
        }
        let macPort = f.macPort
        guard w.origin == "recipe", let s = w.port.signIn else {
            let plain = PortForwarding.url(macPort: macPort, path: w.port.path)
            guard let u = URL(string: plain), PortSignIn.openOnMac(u, signedIn: false) else { throw HostError(.failed, "this Mac could not open \(plain)") }
            return PortOpened(sandbox: m.name, port: port, title: w.port.title, url: plain, signedIn: false)
        }
        let ctx = Self.execContext(config: m.config,
                                   environment: recipeEnvironment(Self.withClaudePermissions([:], imageSpec: m.config.spec.imageSpec?.name), m),
                                   workdir: nil, user: nil)
        let sandbox = m.sandbox
        let outcome = await PortSignIn.run(s, title: w.port.title, guestPort: port, macPort: macPort, path: w.port.path,
                                           exec: { argv, seconds in
                                               try await sandbox.exec(argv, environment: ctx.environment, workingDirectory: ctx.workdir,
                                                                      user: ctx.user, timeoutSeconds: Int64(seconds))
                                           },
                                           open: { url, signedIn in PortSignIn.openOnMac(url, signedIn: signedIn) })
        note(m.name, outcome.line)
        if !outcome.opened { throw HostError(.failed, outcome.line) }
        return PortOpened(sandbox: m.name, port: port, title: w.port.title, url: outcome.url, signedIn: outcome.signedIn, problem: outcome.problem)
    }

    /// The `ports` operation: list, add (`portAdd`) or remove (`portRemove`).
    func ports(_ r: HostRequest) async throws -> PortsAnswer {
        let m = try get(r.name)
        await refreshServing(m.name, maxAge: 2)
        var note: String?
        if let add = r.portAdd {
            guard (1...65_535).contains(add.port) else { throw HostError(.invalid, "a port is 1–65535") }
            if let p = add.path, !PortForwarding.isPath(p) { throw HostError(.invalid, "\(p): a path starts with / and has no spaces") }
            if let t = add.title, t.isEmpty || t.count > 40 { throw HostError(.invalid, "a title of 1–40 characters") }
            let wanted = wantedPorts(m)
            if let w = wanted.first(where: { $0.port.port == add.port }) {
                guard w.origin == "added" else { throw HostError(.exists, "port \(add.port) is already forwarded (\(w.port.title), from the recipe)") }
            } else if wanted.count >= PortForwarding.maximumPerSandbox {
                throw HostError(.invalid, "at most \(PortForwarding.maximumPerSandbox) forwards per sandbox")
            }
            var list = (m.config.ports ?? []).filter { $0.port != add.port }
            list.append(add)
            m.config.ports = list.sorted { $0.port < $1.port }
            try m.config.write(store.configFile(m.name))
            portTable.remove(m.name, port: add.port)          // a changed title/path rebinds with the same Mac port
            await bindPorts(m.name)
            note = await effectivePhase(m) == .running ? nil : "kept — it listens while \(m.name) runs"
        }
        if let port = r.portRemove {
            guard (m.config.ports ?? []).contains(where: { $0.port == port }) else {
                if wantedPorts(m).contains(where: { $0.port.port == port }) {
                    throw HostError(.invalid, "port \(port) is the recipe's — it is forwarded while \(m.name) runs")
                }
                throw HostError(.notFound, "\(m.name) has no forward of port \(port)")
            }
            m.config.ports = (m.config.ports ?? []).filter { $0.port != port }
            if m.config.ports?.isEmpty == true { m.config.ports = nil }
            m.config.portMacPorts?[String(port)] = nil
            try m.config.write(store.configFile(m.name))
            portTable.remove(m.name, port: port)
            note = "port \(port) is no longer forwarded"
        }
        let phase = await effectivePhase(m)
        if phase == .running { await bindPorts(m.name) }       // a forward that failed earlier is tried again
        return PortsAnswer(sandbox: m.name, phase: phase.rawValue, ports: portRows(m, running: phase == .running), note: note)
    }
}
