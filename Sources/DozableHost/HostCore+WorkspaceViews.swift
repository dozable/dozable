import DozableKit
import Foundation

/// The workspace-wide views' reads — `workspace-reach`, `workspace-folders` and the log in pages. Each only reads: answered
/// in-process by a read-only core when no daemon runs (looking never starts one); what only a daemon holds (its proxies'
/// refusals) is then "not known". Never a secret's value or a token: a held secret is a name, a destination, a header and
/// (a given one only) a fingerprint. docs/engineering/workspaces.md, "Workspace-wide views".
extension HostCore {
    // MARK: reach

    func workspaceReach(_ w: WorkspaceRequest) async throws -> WorkspaceReach {
        let rec = try workspaceRecord(try workspaceName(w))
        var agents = rec.agents.filter { $0.endedAt == nil }
        if let one = w.agent {
            agents = agents.filter { $0.name == one }
            guard !agents.isEmpty else { throw HostError(.notFound, "\(rec.name) has no agent \(one) (doz workspace show \(rec.name))") }
        }
        let macs = agents.contains { $0.place.mac == true } ? await workspaceMacRows() : [:]
        let states = Dictionary(await workspaceAgents(rec, macs: macs).map { ($0.0.name, $0.0.state) }, uniquingKeysWith: { a, _ in a })
        var out: [AgentReach] = []
        for a in agents { out.append(await agentReach(rec, a, state: states[a.name] ?? "gone")) }
        var notes: [String] = []
        if readOnly { notes.append("what each agent was refused is not known: no daemon is running") }
        return WorkspaceReach(workspace: rec.name, agents: out,
                              defaults: .init(isolation: rec.defaults.isolation ?? "fenced", network: rec.defaults.network ?? "locked"),
                              refusalsKnown: !readOnly, notes: notes.isEmpty ? nil : notes)
    }

    /// One agent's reach, from its place's own records (and the live proxy, the daemon's only).
    func agentReach(_ rec: WorkspaceRecord, _ a: WorkspaceAgent, state: String) async -> AgentReach {
        let rooms = (a.isManager || a.isWorker || a.bot != nil) ? (rec.mainRoom.map { [$0.chatRoom] } ?? []) : []
        let shares = workerShares(rec, a)
        if let s = a.place.sandbox {
            var i = AgentCapabilities.Input(name: a.name, role: a.role, isolation: "vm", place: s)
            i.rooms = rooms
            i.shares = shares
            if let m = managed[s] {
                let cfg = m.config
                let running = await effectivePhase(m) == .running
                if let share = cfg.workspace {
                    let mode = rec.folders.first { $0.path == share }?.mode ?? "rw"
                    i.folders = [ReachFolder(path: share, mode: mode)]
                }
                if let egress = m.sandbox.egress {
                    let records = readOnly ? [] : egress.log.records
                    let rep = PermissionPolicy.report(name: m.name, policy: Self.withoutSignInBlock(egress.policy), base: PermissionPolicy.base(of: cfg),
                                                      log: records, hostPorts: egress.hostPorts, hostPortsLive: DozableSettings.load().bool(SettingKey.hostPortsLive))
                    i.network = AgentNetworkReach(proxied: true, live: running && !readOnly, preset: rep.preset, sites: rep.sites, hostPorts: egress.hostPorts,
                                                  forwarded: [], refused: readOnly ? [] : Self.refusals(rep, records))
                } else {
                    i.network = .none
                }
                let live = readOnly ? [:] : portTable.forwards(of: m.name)
                i.network.forwarded = wantedPorts(m).map { w in
                    ReachForward(port: w.port.port, local: running ? live[w.port.port].flatMap { $0.isStopped ? nil : $0.macPort } : cfg.portMacPorts?[String(w.port.port)])
                }
                i.held = (cfg.secrets ?? []).map { HeldSecret($0, worker: a.isWorker || a.isManager) }
                i.account = cfg.account
                i.keys = cfg.credentialSources.isEmpty ? "none" : "\(cfg.credentialSources.count) held by Dozable"
            }
            return AgentReach(name: a.name, role: a.role, isolation: "vm", place: a.place.display, kind: "sandbox",
                              control: WorkerLaunch.control(isolation: "vm", shares: shares), actsAsYou: false, state: state,
                              capabilities: AgentCapabilities.rows(i), network: i.network, held: i.held, folders: i.folders, account: i.account, rooms: rooms)
        }
        if a.place.mac == true, let s = a.place.session {
            let r = mac.records().sessions[s]
            let fenced = r.map { $0.fence != nil } ?? (a.isolation != "unfenced")
            let iso = fenced ? "fenced" : "unfenced"
            var i = AgentCapabilities.Input(name: a.name, role: a.role, isolation: iso, place: a.place.display)
            i.rooms = rooms
            if let r {
                var shape = MacCapabilityShape(session: s, record: r, home: mac.fenceHome())
                if let p = macProxies[s] {
                    shape.network = "proxy"
                    shape.preset = AgentPermissions.presetName(p.proxy.policy.permissions ?? [], base: AgentPermissions.macBase)
                }
                i.mac = MacFence.capabilities(shape)
                i.folders = [ReachFolder(path: r.workdir, mode: "rw")]
                if let f = r.fence {
                    i.folders += f.writable.map { ReachFolder(path: $0, mode: "rw") } + f.readable.map { ReachFolder(path: $0, mode: "ro") }
                    i.account = f.account
                    i.held = (f.secrets ?? []).map { HeldSecret($0, worker: a.isWorker || a.isManager) }
                    if let stored = f.policy {
                        let live = macProxies[s]
                        let policy = live?.proxy.policy ?? stored
                        let records = readOnly ? [] : (live?.proxy.log.records ?? [])
                        let hostPorts = live?.proxy.hostPorts ?? f.hostPorts ?? []
                        let rep = PermissionPolicy.report(name: "@mac \(s)", policy: policy, base: AgentPermissions.macBase, log: records,
                                                          hostPorts: hostPorts, hostPortsLive: DozableSettings.load().bool(SettingKey.hostPortsLive))
                        i.network = AgentNetworkReach(proxied: true, live: live != nil, preset: rep.preset, sites: rep.sites, hostPorts: hostPorts,
                                                      forwarded: [], refused: readOnly ? [] : Self.refusals(rep, records))
                    }
                }
            }
            return AgentReach(name: a.name, role: a.role, isolation: iso, place: a.place.display, kind: "mac",
                              control: WorkerLaunch.control(isolation: iso), actsAsYou: !fenced, state: state,
                              capabilities: AgentCapabilities.rows(i), network: i.network, held: i.held, folders: i.folders, account: i.account, rooms: rooms)
        }
        var i = AgentCapabilities.Input(name: a.name, role: a.role, isolation: "elsewhere", place: a.place.display)
        i.rooms = rooms
        return AgentReach(name: a.name, role: a.role, isolation: "elsewhere", place: a.place.display, kind: "elsewhere",
                          control: "not run by Dozable · token only", actsAsYou: false, state: state,
                          capabilities: AgentCapabilities.rows(i), network: .none, held: [], folders: [], account: nil, rooms: rooms)
    }

    /// What a proxy refused lately, one row per grant that would allow it: the host, its port, how often, when last.
    static func refusals(_ rep: PermissionReport, _ records: [ConnectionRecord]) -> [ReachRefusal] {
        rep.suggestions.map { s in
            let hosts = Set(s.hosts.map { $0.lowercased() })
            let last = records.filter { $0.verdict == .denied && hosts.contains($0.host.lowercased()) }.map(\.time).max()
            let port = records.last { $0.verdict == .denied && hosts.contains($0.host.lowercased()) }?.port
            return ReachRefusal(host: s.hosts.first ?? s.what, port: port.map(Int.init), count: s.count, lastAt: last, grant: s.grant)
        }
    }

    // MARK: folders

    func workspaceFolders(_ w: WorkspaceRequest) async throws -> WorkspaceFolders {
        let rec = try workspaceRecord(try workspaceName(w))
        let since = rec.flags.startedAt ?? rec.flags.firstAgentAt ?? rec.createdAt
        let live = rec.agents.filter { $0.endedAt == nil }
        // Each agent's working folders: a sandbox's share, a session's folder and the folders its fence writes.
        var worksIn: [(agent: String, path: String)] = []
        var points: [WorkspaceFolders.Points] = []
        for a in live {
            if let s = a.place.sandbox, let m = managed[s] {
                if let share = m.config.workspace { worksIn.append((a.name, WorkspaceStore.resolved(share))) }
                if !points.contains(where: { $0.sandbox == s }) {
                    points.append(.init(agent: a.name, sandbox: s, rows: (try? m.sandbox.restorePoints()) ?? []))
                }
            } else if a.place.mac == true, let s = a.place.session, let r = mac.records().sessions[s] {
                // Resolved as the workspace's folders are (a session may record /tmp/…, a link): one folder, one row.
                worksIn.append((a.name, WorkspaceStore.resolved(r.workdir)))
                for p in r.fence?.writable ?? [] { worksIn.append((a.name, WorkspaceStore.resolved(p))) }
            }
        }
        var list: [(path: String, mode: String, main: Bool, workspace: Bool)] = rec.folders.map { ($0.path, $0.mode, $0.main, true) }
        for x in worksIn where !list.contains(where: { $0.path == x.path }) { list.append((x.path, "rw", false, false)) }
        var out: [WorkspaceFolders.Folder] = []
        for f in list {
            let path = f.path
            // Off the actor: a walk may take its 3 seconds, and nothing else should wait on it.
            let r = await Task.detached { WorkspaceChangedFiles.walk(path, since: since) }.value
            var names: [String] = []
            for x in worksIn where (x.path == path || x.path.hasPrefix(path + "/")) && !names.contains(x.agent) { names.append(x.agent) }
            out.append(.init(path: path, mode: f.mode, main: f.main, workspace: f.workspace, exists: r.exists,
                             rules: .init(ignore: WorkspaceChangedFiles.ruleCount(path, WorkspaceRules.ignoreFile),
                                          readonly: WorkspaceChangedFiles.ruleCount(path, WorkspaceRules.readOnlyFile)),
                             agents: names, changes: r.changes, count: r.count, truncated: r.truncated, scanned: r.scanned, hidden: nil))
        }
        return WorkspaceFolders(workspace: rec.name, since: since, folders: out, points: points)
    }

    // MARK: the log in pages

    func workspaceLogAnswer(_ w: WorkspaceRequest) throws -> JSONValue {
        let n = try workspaceName(w)
        _ = try workspaceRecord(n)
        guard w.before != nil || w.limit != nil else { return try JSONValue(encoding: try workspaces.log(n, since: w.since)) }
        if let l = w.limit, !(1...WorkspaceLogPage.maximumLimit).contains(l) {
            throw HostError(.invalid, "--limit: 1–\(WorkspaceLogPage.maximumLimit) lines")
        }
        if let b = w.before, b < 0 { throw HostError(.invalid, "--before: a line's position from an earlier page (its first)") }
        return try JSONValue(encoding: try workspaces.logPage(n, before: w.before, limit: w.limit ?? WorkspaceLogPage.defaultLimit))
    }
}
