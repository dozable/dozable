import DozableKit
import Foundation

/// How the chat server looks to the bots: its participants (`directory.json`), and a participant added, changed, given a new
/// token or removed — the supervisor's own operations, so `directory.json` and `tokens.json` keep ONE writer. The daemon's
/// is `SupervisorBotChat` (HostServer.swift); tests give a fake that hashes like the supervisor.
public protocol BotChat: Sendable {
    /// `directory.json` as it is now.
    func directory() throws -> ChatDirectory
    /// Whether chat is on (the setting): with chat off a participant waits until it is.
    func enabled() -> Bool
    /// A new participant with this token (its hash only is written).
    func add(_ name: String, token: String, kind: String, deliver: String, entry: String?, session: String?) async throws
    /// How it is reached, changed — its token, rooms and history kept.
    func set(_ name: String, deliver: String, entry: String?, session: String?) async throws
    /// Its token replaced (the old one refused from now on).
    func replaceToken(_ name: String, token: String) async throws
    /// It and its token go; it leaves every room.
    func remove(_ name: String) async throws
}

/// What `doz chat` refuses for a bot's name — pure (`BotGuardsTests`). Everything else is unchanged.
public enum BotGuards {
    public static func chatRefusal(_ op: HostOp, name: String?, bots: BotsFile) -> HostError? {
        guard let n = name, let b = bots.bot(n) else { return nil }
        if let at = b.retiredAt {
            // The name stays with its old messages: nobody takes it, in chat or as you.
            return op == .chatAdd || op == .chatSync ? BotName.retiredRefusal(n, at) : nil
        }
        switch op {
        case .chatAdd: return HostError(.exists, "\(n) is already in chat as a bot (doz bot show \(n))")
        case .chatSync: return HostError(.exists, "\(n) is a bot's name — you need a name of your own")
        case .chatRemove: return HostError(.invalid, "\(n) is a bot — doz bot retire \(n)")
        case .chatToken: return HostError(.invalid, "\(n) is a bot — doz bot token \(n) --new")
        case .chatSet: return HostError(.invalid, "\(n) is a bot — doz bot set \(n) --deliver inbox|poll|webhook")
        default: return nil
        }
    }
}

/// The Agents / Bots in the daemon (`bot-*`). Looking (ls, show) is answered in-process by a read-only core too; every change
/// holds the `bots` gate, checks everything first and only then writes — the keychain item, then the chat server's
/// participant, then `bots.json` — undoing what it wrote when a later step fails. `docs/engineering/workspaces.md`.
extension HostCore {
    nonisolated var bots: BotStore { BotStore(store: store) }

    func performBot(_ r: HostRequest) async throws -> JSONValue {
        let b = r.botRequest ?? BotRequest()
        switch r.op {
        case .botList:
            var l = try botListing(retired: b.retired == true)
            let running = await runningManagers()
            let works = liveWorkers()
            for i in l.bots.indices {
                l.bots[i].running = running[l.bots[i].name]
                l.bots[i].worksIn = works[l.bots[i].name]
            }
            return try JSONValue(encoding: l)
        case .botShow:
            let n = try botName(b)
            var d = try botDetail(try botRecord(n, in: try bots.read()))
            d.running = await runningManagers()[n]
            d.worksIn = liveWorkers()[n]
            return try JSONValue(encoding: d)
        default:
            break
        }
        guard !readOnly else { throw HostError(.unavailable, "\(r.op.rawValue) needs the daemon") }
        guard let chat = botChat else { throw HostError(.unavailable, "\(r.op.rawValue) needs the daemon's chat server") }
        await botGate.lock("bots")
        defer { botGate.unlock("bots") }
        switch r.op {
        case .botNew: return try JSONValue(encoding: try await botNew(b, chat))
        case .botSet: return try JSONValue(encoding: try await botSet(b, chat))
        case .botRetire: return try JSONValue(encoding: try await botRetire(b, chat))
        case .botAdopt: return try JSONValue(encoding: try await botAdopt(b, chat))
        case .botToken: return try JSONValue(encoding: try await botToken(b, chat))
        default: throw HostError(.invalid, "not a bot operation: \(r.op.rawValue)")
        }
    }

    // MARK: looking

    func botName(_ b: BotRequest) throws -> String {
        guard let n = b.name, !n.isEmpty else { throw HostError(.invalid, "which bot? (doz bot ls)") }
        if let why = ChatNames.refusal(n) { throw HostError(.invalid, why) }
        return n
    }

    func botRecord(_ n: String, in file: BotsFile) throws -> BotRecord {
        guard let r = file.bot(n) else { throw HostError(.notFound, "\(n) is not a bot (doz bot ls)") }
        return r
    }

    /// The chat server's participants: through the daemon's chat when there is one, else read from the store.
    func botDirectory() throws -> ChatDirectory {
        if let c = botChat { return try c.directory() }
        return try ChatDirectory.load(ChatPaths(store: store))
    }

    /// The workspaces each bot is an agent of, and the ones it manages.
    func botWorkspaces() -> (member: [String: [String]], manages: [String: [String]]) {
        var member: [String: [String]] = [:], manages: [String: [String]] = [:]
        for w in workspaces.records() {
            for a in w.agents {
                guard let bot = a.bot else { continue }
                if !(member[bot]?.contains(w.name) ?? false) { member[bot, default: []].append(w.name) }
                if a.role == "manager", !(manages[bot]?.contains(w.name) ?? false) { manages[bot, default: []].append(w.name) }
            }
        }
        return (member, manages)
    }

    func botDetail(_ rec: BotRecord, notes: [String] = []) throws -> BotDetail {
        let dir = (try? botDirectory()) ?? ChatDirectory()
        let ws = botWorkspaces()
        return BotDetail(rec, inChat: dir.participants.contains { $0.name == rec.name }, workspaces: ws.member[rec.name] ?? [],
                         manages: ws.manages[rec.name] ?? [], notes: notes.isEmpty ? nil : notes)
    }

    func botListing(retired: Bool) throws -> BotListing {
        let file = try bots.read()
        let dir = (try? botDirectory()) ?? ChatDirectory()
        let ws = botWorkspaces()
        let rows = file.bots.filter { $0.retired == retired }.sorted { $0.name < $1.name }.map { r in
            BotRow(name: r.name, agent: r.agent, model: r.model, isolation: r.isolation.default, kind: r.kind, deliver: r.deliver,
                   inChat: dir.participants.contains { $0.name == r.name }, manages: ws.manages[r.name] ?? [], retiredAt: r.retiredAt)
        }
        return BotListing(bots: rows)
    }

    // MARK: checks

    /// The agent program, resolved (an unknown one refused).
    func botAgent(_ s: String?) throws -> String {
        guard let s, !s.isEmpty else { throw HostError(.invalid, "which agent? --agent claude-code, codex, … (doz search)") }
        let ref: AgentRef?
        do { ref = try AgentRef.resolve(s) } catch { throw HostError(.invalid, "--agent \(s.prefix(60)): \(error)") }
        guard let ref else { throw HostError(.notFound, "no agent \(s.prefix(60)) (doz search)") }
        return ref.text
    }

    func botCheckAccount(_ a: String) throws {
        guard a == "mac" || accountStore.load().accounts.contains(where: { $0.name == a }) else {
            throw HostError(.notFound, "no account \(a.prefix(60)) (doz account ls)")
        }
    }

    /// How the chat server would reach it: inbox for a Claude Code bot only, an entry with webhook, a session with inbox.
    func botCheckDelivery(_ deliver: String, kind: String, entry: String?, session: String?, name: String) throws {
        guard ChatDirectory.deliveries.contains(deliver) else {
            throw HostError(.invalid, "--deliver is one of \(ChatDirectory.deliveries.joined(separator: ", ")), not \(deliver.prefix(40))")
        }
        if deliver == "inbox" && kind != "claude-session" {
            throw HostError(.invalid, "inbox delivery is for a Claude Code bot (--agent claude-code); \(name) is \(kind == "agent" ? "an agent" : kind) — use --deliver poll or webhook")
        }
        if entry != nil && deliver != "webhook" { throw HostError(.invalid, "--webhook-entry goes with --deliver webhook") }
        if deliver == "webhook", let why = ChatWebhookEntries.nameRefusal(entry ?? name) { throw HostError(.invalid, why) }
        if let why = ChatDirectory.deliveryRefusal(deliver, kind: kind, session: session) { throw HostError(.invalid, why) }
    }

    /// The fields every change may carry, checked.
    func botCheckFields(_ b: BotRequest) throws -> Data? {
        if let m = b.model { try BotFields.checkModel(m) }
        if let a = b.account { try botCheckAccount(a) }
        if let a = b.avatar { try BotFields.checkAvatar(a) }
        if let s = b.skills { try BotFields.checkSkills(s) }
        if let i = b.isolation { try BotFields.checkIsolation(i) }
        guard let t = b.instructions else { return nil }
        let d = Data(t.utf8)
        try BotFields.checkInstructions(d)
        return d
    }

    /// A held bot's token needs the login keychain: refused where it is locked, nothing written (no memory fallback).
    func botCheckKeychain() throws {
        if let why = HostServer.keychainLocked {
            throw HostError(.unavailable, "the login keychain is locked here (\(why)) — run it in the Mac's own session")
        }
    }

    func botService(_ name: String) -> String { BotTokens.service(store: store.root, name: name) }

    func botKeep(_ name: String, _ token: String) throws {
        do { try services.keychain.write(service: botService(name), account: Keychain.user, secret: token) } catch {
            throw HostError(.unavailable, "\(name)'s token could not be kept in the login keychain (is it unlocked?)")
        }
    }

    func botNotes(_ rec: BotRecord, chat: BotChat) -> [String] {
        var notes: [String] = []
        if !chat.enabled() { notes.append("\(rec.name) takes part once chat is on (doz chat on)") }
        if rec.isolation.default == "unfenced" { notes.append("unfenced: \(rec.name) acts as you") }
        if rec.deliver == "inbox" && rec.isolation.default != "unfenced" {
            notes.append("inbox reaches only a Claude Code session run without a fence — while \(rec.name) runs \(rec.isolation.default == "vm" ? "in a sandbox" : rec.isolation.default) it collects its messages with dozchat")
        }
        if rec.deliver == "webhook" { notes.append("set its webhook entry next: doz chat webhook set \(rec.webhookEntry ?? rec.name)") }
        return notes
    }

    // MARK: changing

    func botNew(_ b: BotRequest, _ chat: BotChat) async throws -> BotChange {
        let name = try botName(b)
        var file = try bots.read()
        let dir = try chat.directory()
        try BotName.validate(name, human: dir.human, file: file)
        if dir.participants.contains(where: { $0.name == name }) {
            throw HostError(.exists, "\(name) is already in chat — doz bot adopt \(name) --agent AGENT makes it a bot")
        }
        let agent = try botAgent(b.agent)
        let instructions = try botCheckFields(b)
        let isolation = BotIsolation(default: b.isolation ?? "fenced")
        let kind = BotKinds.kind(forAgent: agent)
        let deliver = b.deliver ?? "poll"
        try botCheckDelivery(deliver, kind: kind, entry: b.webhookEntry, session: b.session, name: name)
        if isolation.held { try botCheckKeychain() }
        // Everything checked: the item, then the participant, then the record — each undone when a later one fails.
        let token = ChatTokens.make()
        let now = Date()
        let fp = BotTokens.fingerprint(token)
        if isolation.held { try botKeep(name, token) }
        do { try await chat.add(name, token: token, kind: kind, deliver: deliver, entry: b.webhookEntry, session: b.session) } catch {
            if isolation.held { try? services.keychain.delete(service: botService(name), account: Keychain.user) }
            throw error
        }
        var rec = BotRecord(name: name, createdAt: now, origin: "new", agent: agent, model: b.model, account: b.account, avatar: b.avatar,
                            isolation: isolation, kind: kind, deliver: deliver, webhookEntry: deliver == "webhook" ? b.webhookEntry : nil,
                            session: deliver == "inbox" ? b.session : nil, skills: b.skills ?? [],
                            token: BotTokenState(keeper: isolation.held ? "dozable" : "elsewhere", fingerprint: fp, at: now))
        do {
            if let instructions { rec.instructions = try bots.writeInstructions(name, instructions, at: now) } else { try bots.ensureFolder(name) }
            file.bots.append(rec)
            try bots.write(file)
        } catch {
            try? await chat.remove(name)
            if isolation.held { try? services.keychain.delete(service: botService(name), account: Keychain.user) }
            throw error
        }
        note(nil, "bot \(name): made (\(isolation.default), \(deliver)), token fp \(fp)")
        var notes = botNotes(rec, chat: chat)
        if isolation.held { notes.append("its token is kept in your login keychain (fingerprint \(fp)), for Dozable to start \(name) with — never shown") }
        return BotChange(bot: try botDetail(rec, notes: notes), oneTimeToken: isolation.held ? nil : token)
    }

    func botSet(_ b: BotRequest, _ chat: BotChat) async throws -> BotChange {
        let name = try botName(b)
        var file = try bots.read()
        var rec = try botRecord(name, in: file)
        if let at = rec.retiredAt { throw BotName.retiredRefusal(name, at) }
        let instructions = try botCheckFields(b)
        let newIsolation = b.isolation ?? rec.isolation.default
        let moving = BotIsolation(default: newIsolation).held != rec.isolation.held
        let deliver = b.deliver ?? (b.webhookEntry != nil ? "webhook" : b.session != nil ? "inbox" : nil)
        if let deliver { try botCheckDelivery(deliver, kind: rec.kind, entry: b.webhookEntry, session: b.session, name: name) }
        guard b.model != nil || b.account != nil || b.avatar != nil || b.skills != nil || instructions != nil || b.isolation != nil || deliver != nil else {
            throw HostError(.invalid, "nothing to change — give --model, --account, --avatar, --skills, --instructions-file, --isolation or --deliver")
        }
        if moving && !rec.isolation.held { try botCheckKeychain() }
        let now = Date()
        var oneTime: String?
        // The chat server first (how it is reached; a new token when it moves to or from elsewhere), then the record.
        if let deliver {
            try await chat.set(name, deliver: deliver, entry: b.webhookEntry, session: b.session)
            rec.deliver = deliver
            rec.webhookEntry = deliver == "webhook" ? b.webhookEntry : nil
            rec.session = deliver == "inbox" ? b.session : nil
        }
        if moving {
            let token = ChatTokens.make()
            if rec.isolation.held {
                // To elsewhere: shown once, never kept — the item goes.
                try await chat.replaceToken(name, token: token)
                try? services.keychain.delete(service: botService(name), account: Keychain.user)
                rec.token = BotTokenState(keeper: "elsewhere", fingerprint: BotTokens.fingerprint(token), at: now)
                oneTime = token
            } else {
                try botKeep(name, token)
                do { try await chat.replaceToken(name, token: token) } catch {
                    try? services.keychain.delete(service: botService(name), account: Keychain.user)
                    throw error
                }
                rec.token = BotTokenState(keeper: "dozable", fingerprint: BotTokens.fingerprint(token), at: now)
            }
        }
        rec.isolation.default = newIsolation
        if let m = b.model { rec.model = m }
        if let a = b.account { rec.account = a }
        if let a = b.avatar { rec.avatar = a }
        if let s = b.skills { rec.skills = s }
        if let instructions { rec.instructions = try bots.writeInstructions(name, instructions, at: now) }
        guard let i = file.index(name) else { throw HostError(.notFound, "\(name) is not a bot (doz bot ls)") }
        file.bots[i] = rec
        try bots.write(file)
        if moving { note(nil, "bot \(name): now \(newIsolation), a new token, fp \(rec.token.fingerprint ?? "?")") }
        var notes = moving ? ["its token was replaced: the old one is refused from now on"] : []
        if b.isolation == "unfenced" { notes.append("unfenced: \(name) acts as you") }
        if deliver == "webhook" { notes.append("set its webhook entry next: doz chat webhook set \(rec.webhookEntry ?? name)") }
        return BotChange(bot: try botDetail(rec, notes: notes), oneTimeToken: oneTime)
    }

    func botRetire(_ b: BotRequest, _ chat: BotChat) async throws -> BotChange {
        let name = try botName(b)
        var file = try bots.read()
        var rec = try botRecord(name, in: file)
        if let at = rec.retiredAt { throw HostError(.exists, "\(name) was retired \(BotName.day(at)) already") }
        for w in workspaces.records() {
            if let a = w.agents.first(where: { $0.bot == name && $0.isLiveWorker }) {
                throw HostError(.exists, "\(name) works in \(w.name) — doz worker end \(w.name) \(a.name) first")
            }
            if let a = w.agents.first(where: { $0.bot == name }) {
                throw HostError(.exists, "\(name) is in \(w.name) — doz workspace release \(w.name) \(a.name) first")
            }
        }
        // Idempotent if interrupted: a participant already gone is not removed twice; an item already gone is not missed.
        if try chat.directory().participants.contains(where: { $0.name == name }) { try await chat.remove(name) }
        try? services.keychain.delete(service: botService(name), account: Keychain.user)
        let now = Date()
        rec.retiredAt = now
        rec.token = BotTokenState(keeper: "none", fingerprint: nil, at: now)
        guard let i = file.index(name) else { throw HostError(.notFound, "\(name) is not a bot (doz bot ls)") }
        file.bots[i] = rec
        try bots.write(file)
        note(nil, "bot \(name): retired (its token refused, its name kept with its old messages)")
        return BotChange(bot: try botDetail(rec, notes: ["\(name)'s old messages keep its name; nobody else can take it"]))
    }

    func botAdopt(_ b: BotRequest, _ chat: BotChat) async throws -> BotChange {
        let name = try botName(b)
        var file = try bots.read()
        let dir = try chat.directory()
        if dir.human == name { throw HostError(.invalid, "\(name) is you in chat — only a participant can become a bot") }
        if let bot = file.bot(name) {
            if let at = bot.retiredAt { throw BotName.retiredRefusal(name, at) }
            throw HostError(.exists, "\(name) is already a bot (doz bot show \(name))")
        }
        guard let p = dir.participants.first(where: { $0.name == name }) else {
            throw HostError(.notFound, "no participant \(name) in chat (doz chat who) — doz bot new \(name) makes a new one")
        }
        let agent = try botAgent(b.agent)
        let instructions = try botCheckFields(b)
        let isolation = BotIsolation(default: b.isolation ?? "fenced")
        if let d = b.deliver ?? (b.webhookEntry != nil ? "webhook" : b.session != nil ? "inbox" : nil) {
            try botCheckDelivery(d, kind: p.kind, entry: b.webhookEntry, session: b.session, name: name)
        }
        if isolation.held { try botCheckKeychain() }
        // Its token is replaced: Dozable never had the old one.
        let token = ChatTokens.make()
        let now = Date()
        if isolation.held { try botKeep(name, token) }
        do { try await chat.replaceToken(name, token: token) } catch {
            if isolation.held { try? services.keychain.delete(service: botService(name), account: Keychain.user) }
            throw error
        }
        var notes = ["its token is replaced: Dozable never had the old one, and an agent still using it stops working now (the chat server refuses it)"]
        if let d = b.deliver ?? (b.webhookEntry != nil ? "webhook" : b.session != nil ? "inbox" : nil), d != p.delivery || b.webhookEntry != nil || b.session != nil {
            do { try await chat.set(name, deliver: d, entry: b.webhookEntry, session: b.session) } catch {
                notes.append("it is still reached by \(p.delivery): \(HostError.from(error).message)")
            }
        }
        let now2 = (try? chat.directory().participants.first { $0.name == name }) ?? p
        var rec = BotRecord(name: name, createdAt: now, origin: "adopted", agent: agent, model: b.model, account: b.account, avatar: b.avatar,
                            isolation: isolation, kind: p.kind, deliver: now2.delivery, webhookEntry: now2.webhookEntry == name ? nil : now2.webhookEntry,
                            session: now2.inboxSession == name ? nil : now2.inboxSession, skills: b.skills ?? [],
                            token: BotTokenState(keeper: isolation.held ? "dozable" : "elsewhere", fingerprint: BotTokens.fingerprint(token), at: now))
        if let instructions { rec.instructions = try bots.writeInstructions(name, instructions, at: now) } else { try bots.ensureFolder(name) }
        file.bots.append(rec)
        try bots.write(file)
        note(nil, "bot \(name): adopted from chat (\(isolation.default), \(rec.deliver)), a new token, fp \(rec.token.fingerprint ?? "?")")
        notes += botNotes(rec, chat: chat)
        return BotChange(bot: try botDetail(rec, notes: notes), oneTimeToken: isolation.held ? nil : token)
    }

    func botToken(_ b: BotRequest, _ chat: BotChat) async throws -> BotChange {
        let name = try botName(b)
        var file = try bots.read()
        var rec = try botRecord(name, in: file)
        if let at = rec.retiredAt { throw BotName.retiredRefusal(name, at) }
        let held = rec.isolation.held
        if held { try botCheckKeychain() }
        let token = ChatTokens.make()
        let now = Date()
        if held {
            let old = services.keychain.read(service: botService(name), account: Keychain.user).value
            try botKeep(name, token)
            do { try await chat.replaceToken(name, token: token) } catch {
                if let old { try? services.keychain.write(service: botService(name), account: Keychain.user, secret: old) } else {
                    try? services.keychain.delete(service: botService(name), account: Keychain.user)
                }
                throw error
            }
        } else {
            try await chat.replaceToken(name, token: token)
        }
        rec.token = BotTokenState(keeper: held ? "dozable" : "elsewhere", fingerprint: BotTokens.fingerprint(token), at: now)
        guard let i = file.index(name) else { throw HostError(.notFound, "\(name) is not a bot (doz bot ls)") }
        file.bots[i] = rec
        try bots.write(file)
        note(nil, "bot \(name): a new token, fp \(rec.token.fingerprint ?? "?")")
        let notes = ["the old token is refused from now on" + (held ? "; a running \(name) stops working until it is started again" : "")]
        return BotChange(bot: try botDetail(rec, notes: notes), oneTimeToken: held ? nil : token)
    }

    // MARK: the sweep

    /// Delete every keychain item of this store's bot prefix that belongs to no held, unretired bot (a bot made while an
    /// older doz rewrote the file, a change interrupted between the item and the record). At a daemon's start; never in the
    /// read-only core; only this store's prefix is listed. A store that never had a bot is not looked at.
    public func sweepBotTokens() {
        guard !readOnly, MacFenceHostFS.kind(bots.root) != nil, let file = try? bots.read() else { return }
        let items = services.keychain.items(servicePrefix: BotTokens.prefix(store: store.root))
        let orphans = BotTokens.orphans(items, store: store.root, bots: file)
        for s in orphans { try? services.keychain.delete(service: s, account: Keychain.user) }
        if !orphans.isEmpty { HostLog.line("bots: \(orphans.count) keychain item\(orphans.count == 1 ? "" : "s") of no bot deleted") }
    }
}
