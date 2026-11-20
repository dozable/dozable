import Foundation

/// `permissions-*` in the daemon: what agents may do in Dozable. Looking (`show`, `why`) is answered in-process by a read-only
/// core too — looking never starts the daemon; every change is the owner's, through the daemon, checked whole before
/// anything is written: the everywhere grants and this Mac's ceiling in `<store>/grants/grants.json`, a workspace's in its
/// record (under the `workspaces` gate), a bot's ceiling in `bots.json` (under the `bots` gate). Each change is one line of
/// `<store>/grants/log.jsonl` (and a workspace's of its own log), by `you`. Every answer comes from `GrantDecision.decide`.
/// docs/engineering/workspaces.md, "Permissions".
extension HostCore {
    nonisolated var grantStore: GrantStore { GrantStore(store: store) }
    nonisolated var grantFacts: GrantFactsReader { GrantFactsReader(store: store) }

    func performPermissions(_ r: HostRequest) async throws -> JSONValue {
        let p = r.permissionsRequest ?? PermissionsRequest()
        switch r.op {
        case .permissionsShow: return try JSONValue(encoding: try permissionsShow(p))
        case .permissionsWhy: return try JSONValue(encoding: try permissionsWhy(p))
        default: break
        }
        guard !readOnly else { throw HostError(.unavailable, "\(r.op.rawValue) needs the daemon") }
        if r.op == .permissionsCeiling, p.bot != nil {
            await botGate.lock("bots")
            defer { botGate.unlock("bots") }
            return try JSONValue(encoding: try permissionsCeiling(p))
        }
        await workspaceGate.lock("workspaces")
        defer { workspaceGate.unlock("workspaces") }
        switch r.op {
        case .permissionsGrant: return try JSONValue(encoding: try permissionsGrant(p))
        case .permissionsRevoke: return try JSONValue(encoding: try permissionsRevoke(p))
        case .permissionsCeiling: return try JSONValue(encoding: try permissionsCeiling(p))
        default: throw HostError(.invalid, "not a permissions operation: \(r.op.rawValue)")
        }
    }

    // MARK: looking

    /// Every permission's answer for `who` acting in `w`.
    func grantAnswers(_ who: GrantWho, workspace w: String?, now: Date = Date()) -> AgentGrantAnswers {
        let facts = grantFacts.facts(who, workspace: w, now: now)
        let rows = GrantPermissions.ids.map { perm in
            GrantAnswerRow(GrantDecision.decide(GrantQuery(name: who.name, home: who.home, bot: who.bot, perm: perm, workspace: w,
                                                          recordRoles: who.recordRoles), facts),
                          enforced: PermissionWords.enforced(actsAsYou: who.actsAsYou))
        }
        var roles = who.recordRoles.filter { $0.workspace == w }.map { "\($0.role) (from the workspace)" }
        for g in facts.grants where g.role != nil && g.isActive(now) {
            guard let s = g.subjectValue, s == who.subject || (who.home.map { s == .agent($0, who.name) } ?? false),
                  g.scopeValue?.workspace == nil || g.scopeValue?.workspace == w else { continue }
            roles.append("\(g.role!) ✎ (\(g.scopeValue?.display ?? g.scope))")
        }
        return AgentGrantAnswers(name: who.name, workspace: w, bot: who.bot, roles: roles, actsAsYou: who.actsAsYou, rows: rows)
    }

    func ceilingRows(_ lid: String, _ words: String, _ raw: [String: String]?) -> [CeilingRow] {
        GrantCeiling.caps(raw).sorted { $0.key < $1.key }.map { CeilingRow(lid: lid, words: words, perm: $0.key, answer: $0.value.rawValue) }
    }

    func botCeilingRows(_ b: BotRecord) -> [CeilingRow] {
        var rows = ceilingRows("bot:" + b.name, "\(b.name)'s", b.ceilingAnswers)
        if let iso = b.isolation.ceiling, iso == "fenced" || iso == "vm", rows.first(where: { $0.perm == "isolation.unfenced" }) == nil {
            rows.append(CeilingRow(lid: "bot:" + b.name, words: "\(b.name)'s isolation (\(iso))", perm: "isolation.unfenced", answer: "never"))
        }
        return rows
    }

    func permissionsShow(_ p: PermissionsRequest) throws -> PermissionsShown {
        let now = Date()
        let file = grantStore.readOrEmpty()
        let bots = BotStore(store: store).readOrEmpty()
        let mac = ceilingRows("mac", "this Mac's", file.ceiling)
        if p.roles == true {
            return PermissionsShown(view: "roles", roleTable: RoleTable.roles.map(RoleRow.init),
                                    notes: ["a permission a role does not name, it says nothing about: another role or the default (ask) decides"])
        }
        if p.mac == true {
            return PermissionsShown(view: "mac", grants: file.grants.map { GrantRow($0, now: now) }, ceilings: mac)
        }
        if let b = p.bot {
            guard let rec = bots.bot(b), !rec.retired else { throw HostError(.notFound, "there is no bot \(b) (doz bot ls)") }
            let records = workspaces.records()
            let grants = (file.grants + records.flatMap { $0.permissions?.grants ?? [] }).filter { $0.subject == GrantSubject.bot(b).stored }
            let roles = records.flatMap { r in r.agents.filter { $0.bot == b && $0.endedAt == nil }.map { "\(r.name): \($0.role) (from the workspace)" } }
            return PermissionsShown(view: "bot", subject: b, grants: grants.map { GrantRow($0, now: now) }, ceilings: botCeilingRows(rec), botRoles: roles)
        }
        if let a = p.agent {
            let who = try grantFacts.resolve(a, in: p.workspace)
            let w = p.workspace ?? who.home
            let facts = grantFacts.facts(who, workspace: w, now: now)
            let mine = facts.grants.filter { g in
                guard let s = g.subjectValue else { return false }
                if s == who.subject || (who.home.map { s == .agent($0, who.name) } ?? false) { return true }
                if case .role(let r) = s { return who.recordRoles.contains { $0.role == r } }
                return false
            }
            var ceilings = mac
            if let b = who.bot.flatMap(bots.bot) { ceilings += botCeilingRows(b) }
            if let w, let rec = try? workspaces.read(w) { ceilings += ceilingRows("workspace:" + w, "\(w)'s", rec.permissions?.ceiling) }
            return PermissionsShown(view: "agent", workspace: w, subject: who.name, agents: [grantAnswers(who, workspace: w, now: now)],
                                    grants: mine.map { GrantRow($0, now: now) }, ceilings: ceilings)
        }
        if let w = p.workspace {
            let rec = try workspaceRecord(w)
            let agents = rec.agents.filter { $0.endedAt == nil }.map { grantAnswers(GrantFactsReader.who($0, in: rec), workspace: w, now: now) }
            var ceilings = mac + ceilingRows("workspace:" + w, "\(w)'s", rec.permissions?.ceiling)
            for b in Set(rec.agents.compactMap(\.bot)).sorted() { if let x = bots.bot(b) { ceilings += botCeilingRows(x) } }
            return PermissionsShown(view: "workspace", workspace: w, agents: agents,
                                    grants: (file.grants + (rec.permissions?.grants ?? [])).map { GrantRow($0, now: now) }, ceilings: ceilings)
        }
        let records = workspaces.records()
        var ceilings = mac
        for r in records { ceilings += ceilingRows("workspace:" + r.name, "\(r.name)'s", r.permissions?.ceiling) }
        for b in bots.active { ceilings += botCeilingRows(b) }
        return PermissionsShown(view: "all", grants: (file.grants + records.flatMap { $0.permissions?.grants ?? [] }).map { GrantRow($0, now: now) },
                                ceilings: ceilings)
    }

    /// `--room R` (its label in `w`) or `W/R`: the workspace and the room's label, checked against the record.
    func grantRoom(_ room: String?, workspace w: String?) throws -> (String?, String?) {
        guard let room else { return (w, nil) }
        var ws = w, label = room
        if room.contains("/") {
            let parts = room.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2 else { throw HostError(.invalid, "--room W/R, or R with --in W") }
            if let w, w != parts[0] { throw HostError(.invalid, "--room \(room) is not in \(w)") }
            ws = parts[0]; label = parts[1]
        }
        guard let ws else { throw HostError(.invalid, "which workspace is the room in? --room W/R, or --in W") }
        let rec = try workspaceRecord(ws)
        if let r = rec.rooms.first(where: { $0.label == label || $0.chatRoom == label }) { return (ws, r.label) }
        throw HostError(.notFound, "\(ws) has no room \(label)" + (rec.rooms.isEmpty ? " (it has no rooms)" : " — its rooms: \(rec.rooms.map(\.label).joined(separator: ", "))"))
    }

    func permissionsWhy(_ p: PermissionsRequest) throws -> GrantDecision {
        guard let a = p.agent, !a.isEmpty else { throw HostError(.invalid, "which agent or bot? doz why AGENT PERM [--in W]") }
        guard let perm = p.perm, !perm.isEmpty else { throw HostError(.invalid, "which permission? one of: \(GrantPermissions.ids.joined(separator: ", "))") }
        let (w0, room) = try grantRoom(p.room, workspace: p.workspace)
        let who = try grantFacts.resolve(a, in: w0)
        return grantFacts.decide(who, perm: perm, workspace: w0 ?? who.home, room: room)
    }

    // MARK: changing

    /// The one scope a grant is written in: `--everywhere`, `--in W` or `--room W/R` — exactly one.
    func grantScope(_ p: PermissionsRequest, required: Bool) throws -> GrantScope? {
        if p.everywhere == true && (p.workspace != nil || p.room != nil) {
            throw HostError(.invalid, "one scope: --everywhere, --in W or --room W/R")
        }
        if p.everywhere == true { return .everywhere }
        let (w, room) = try grantRoom(p.room, workspace: p.workspace)
        if let w, let room { return .room(w, room) }
        if let w {
            _ = try workspaceRecord(w)
            return .workspace(w)
        }
        if required { throw HostError(.invalid, "where? one scope: --in W, --room W/R or --everywhere") }
        return nil
    }

    /// The subject a grant is written for: a stored form as typed, else the bot or agent the name resolves to.
    func grantSubject(_ name: String?, scope: GrantScope?) throws -> GrantSubject {
        guard let name, !name.isEmpty else { throw HostError(.invalid, "for whom? an agent or bot (doz workspace show W), or role:ROLE") }
        if let s = GrantSubject(stored: name) {
            if case .bot(let b) = s, BotStore(store: store).readOrEmpty().bot(b).map({ !$0.retired }) != true {
                throw HostError(.notFound, "there is no bot \(b) (doz bot ls)")
            }
            if case .agent(let w, _) = s { _ = try workspaceRecord(w) }
            return s
        }
        if name.hasPrefix("role:") { throw HostError(.invalid, "\(name.dropFirst(5).prefix(40)) is not a role — roles: \(RoleTable.names.joined(separator: ", "))") }
        let who = try grantFacts.resolve(name, in: scope?.workspace)
        guard let s = who.subject else { throw HostError(.notFound, "there is no agent or bot \(name)") }
        return s
    }

    /// Write `grants` into the everywhere file or the workspace's record, replacing what each one replaces.
    func writeGrants(_ change: (inout [Grant]) throws -> Void, scope: GrantScope) throws {
        if let w = scope.workspace {
            var rec = try workspaceRecord(w)
            var section = rec.permissions ?? WorkspaceGrants()
            try change(&section.grants)
            rec.permissions = section
            try workspaces.write(rec)
        } else {
            var file = try grantStore.read()
            try change(&file.grants)
            try grantStore.write(file)
        }
    }

    func logGrant(_ e: GrantLogEntry, workspace: String?) {
        try? grantStore.append(e)
        guard let w = workspace else { return }
        var l = WorkspaceLogEntry(at: e.at, by: e.by, action: e.action, reason: e.reason)
        l.subject = e.subject; l.perm = e.perm; l.role = e.role; l.answer = e.answer; l.scope = e.scope; l.until = e.until; l.op = e.op
        try? workspaces.append(w, l)
    }

    func permissionsGrant(_ p: PermissionsRequest) throws -> PermissionsChanged {
        let scope = try grantScope(p, required: true)!
        let subject = try grantSubject(p.agent, scope: scope)
        let words = p.words ?? []
        guard !words.isEmpty else { throw HostError(.invalid, "what? a role (\(RoleTable.names.filter { $0 != "owner" }.joined(separator: ", "))) or PERM=allow|ask|never") }
        let now = Date()
        if let u = p.until, u <= now { throw HostError(.invalid, "--until is in the past: a grant must end later than now") }
        // Every word checked before anything is written.
        var made: [Grant] = []
        for word in words {
            if word.contains("=") {
                let (perm, answer) = try GrantWords.parse(word)
                if GrantPermissions.ownerOnly.contains(perm) {
                    throw HostError(.invalid, "chat.decide is never granted: deciders are made in chat, by you only (doz chat set NAME --role decider, in a later version)")
                }
                made.append(Grant(subject: subject, perm: perm, answer: answer, scope: scope, until: p.until, at: now))
            } else {
                if let e = RoleTable.grantRefusal(word, scope: scope, subject: subject) { throw e }
                made.append(Grant(subject: subject, role: word, scope: scope, until: p.until, at: now))
            }
        }
        try writeGrants({ list in
            for g in made {
                list.removeAll { $0.subject == g.subject && $0.scope == g.scope && $0.role == g.role && $0.perm == g.perm }
                list.append(g)
            }
        }, scope: scope)
        var lines: [String] = []
        for g in made {
            logGrant(GrantLogEntry(at: now, action: "granted", subject: g.subject, perm: g.perm, role: g.role, answer: g.answer, scope: g.scope,
                                   until: g.until, id: g.id), workspace: scope.workspace)
            lines.append("granted \(subject.display) \(g.what) " + (scope == .everywhere ? "everywhere" : "in " + scope.display)
                         + (g.until.map { " until " + BotName.day($0) } ?? ""))
        }
        return PermissionsChanged(lines: lines, grants: made.map { GrantRow($0, now: now) }, notes: [PermissionWords.footer])
    }

    func permissionsRevoke(_ p: PermissionsRequest) throws -> PermissionsChanged {
        let scope = try grantScope(p, required: false)
        let subject = try grantSubject(p.agent, scope: scope)
        let words = p.words ?? []
        guard !words.isEmpty else { throw HostError(.invalid, "what? the ROLE or PERM to take back") }
        let now = Date()
        let file = try grantStore.read()
        let records = workspaces.records()
        func held(_ word: String) -> [Grant] {
            (file.grants + records.flatMap { $0.permissions?.grants ?? [] }).filter { g in
                g.subject == subject.stored && (g.role == word || g.perm == word) && (scope.map { g.scope == $0.stored } ?? true)
            }
        }
        var gone: [Grant] = []
        for word in words {
            let found = held(word)
            if found.isEmpty {
                // A role the workspace's record gives is the workspace's: never a grant to take back.
                let derived = records.first { r in
                    (scope?.workspace == nil || scope?.workspace == r.name) && r.agents.contains { a in
                        a.endedAt == nil && a.role == word && (subject == .agent(r.name, a.name) || a.bot.map { subject == .bot($0) } == true)
                    }
                }
                if let r = derived {
                    throw HostError(.invalid, "\(subject.display) is \(r.name)'s \(word) — it is its role there, not a grant; change the workspace (doz workspace show \(r.name))")
                }
                throw HostError(.notFound, "\(subject.display) holds no grant of \(word)" + (scope.map { " " + ($0 == .everywhere ? "everywhere" : "in " + $0.display) } ?? "")
                                + " (doz permissions show)")
            }
            if scope == nil, Set(found.map(\.scope)).count > 1 {
                throw HostError(.invalid, "\(subject.display) holds \(word) in \(found.compactMap { $0.scopeValue?.display }.joined(separator: ", ")) — which one? (--in W, --room W/R or --everywhere)")
            }
            gone += found
        }
        for s in Set(gone.compactMap(\.scopeValue)) {
            try writeGrants({ list in list.removeAll { g in gone.contains { $0.id == g.id && $0.subject == g.subject && $0.scope == g.scope } } }, scope: s)
        }
        var lines: [String] = []
        for g in gone {
            logGrant(GrantLogEntry(at: now, action: "revoked", subject: g.subject, perm: g.perm, role: g.role, answer: g.answer, scope: g.scope, id: g.id),
                     workspace: g.scopeValue?.workspace)
            lines.append("revoked \(subject.display)'s \(g.what) " + (g.scopeValue == .everywhere ? "everywhere" : "in " + (g.scopeValue?.display ?? g.scope)))
        }
        return PermissionsChanged(lines: lines, grants: gone.map { GrantRow($0, now: now) })
    }

    func permissionsCeiling(_ p: PermissionsRequest) throws -> PermissionsChanged {
        let places = [p.mac == true, p.workspace != nil, p.bot != nil].filter { $0 }.count
        guard places == 1 else { throw HostError(.invalid, "whose ceiling? one of --mac, --in W or --bot B") }
        guard p.room == nil, p.everywhere != true else { throw HostError(.invalid, "a ceiling is this Mac's (--mac), a workspace's (--in W) or a bot's (--bot B)") }
        var set: [(String, GrantAnswer)] = []
        for w in p.words ?? [] { set.append(try GrantCeiling.parse(w)) }
        let clear = p.clear ?? []
        for c in clear where !GrantPermissions.isKnown(c) { throw GrantPermissions.unknownRefusal(c) }
        guard !set.isEmpty || !clear.isEmpty else { throw HostError(.invalid, "what? PERM=ask|never …, or --clear PERM") }
        func apply(_ raw: inout [String: String]) {
            for c in clear { raw.removeValue(forKey: c) }
            for (perm, a) in set { raw[perm] = a.rawValue }
        }
        let now = Date()
        let lid: String, words: String, rows: [CeilingRow]
        var logIn: String?
        if p.mac == true {
            var file = try grantStore.read()
            apply(&file.ceiling)
            try grantStore.write(file)
            lid = "mac"; words = "this Mac's"; rows = ceilingRows(lid, words, file.ceiling)
        } else if let w = p.workspace {
            var rec = try workspaceRecord(w)
            var section = rec.permissions ?? WorkspaceGrants()
            apply(&section.ceiling)
            rec.permissions = section
            try workspaces.write(rec)
            lid = "workspace:" + w; words = "\(w)'s"; rows = ceilingRows(lid, words, section.ceiling)
            logIn = w
        } else {
            let b = p.bot!
            let botStore = BotStore(store: store)
            var file = try botStore.read()
            guard let i = file.index(b), !file.bots[i].retired else { throw HostError(.notFound, "there is no bot \(b) (doz bot ls)") }
            var raw = file.bots[i].ceilingAnswers ?? [:]
            apply(&raw)
            file.bots[i].ceilingAnswers = raw.isEmpty ? nil : raw
            try botStore.write(file)
            lid = "bot:" + b; words = "\(b)'s"; rows = botCeilingRows(file.bots[i])
        }
        var lines: [String] = []
        for c in clear {
            logGrant(GrantLogEntry(at: now, action: "ceiling-set", subject: lid, perm: c, answer: "none", scope: lid), workspace: logIn)
            lines.append("cleared \(words) ceiling on \(c)")
        }
        for (perm, a) in set {
            logGrant(GrantLogEntry(at: now, action: "ceiling-set", subject: lid, perm: perm, answer: a.rawValue, scope: lid), workspace: logIn)
            lines.append("\(words) ceiling: \(perm)=\(a.rawValue)")
        }
        return PermissionsChanged(lines: lines, ceilings: rows, notes: [PermissionWords.footer])
    }
}
