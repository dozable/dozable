import CryptoKit
import Darwin
import DozableKit
import Foundation

// A workspace's manager, started from its bot (`doz workspace start | stop`). The order of a start: the set-up check
// (nothing written on a refusal) → the bot invited to the main room → the kick-off (the brief as your first message, ONCE:
// `flags.startedAt`) → the bot's token as a bot-held launch secret (fenced, VM) or a 0600 file (unfenced, only when named)
// → the session or sandbox → the record. `docs/engineering/workspaces.md` ("The manager").

/// What one launch of a manager needs, decided by the core (`ManagerLauncher.launch`).
public struct ManagerLaunchOrder: Equatable, Sendable {
    public var workspace: String
    public var bot: String
    public var isolation: ManagerIsolation
    /// The session's (or sandbox's) name.
    public var place: String
    /// Its folder: the workspace's main folder, else `<projects_dir>/<workspace>`.
    public var workdir: String
    public var plan: ManagerLaunch.Plan
    /// START's text.
    public var start: Data
    /// Its session or sandbox exists from an earlier start: opened again (its conversation resumed), never made anew.
    public var restart: Bool
    public var agent: String
    public var account: String?
    public var model: String?
    /// Its network permissions: the workspace's default, else `locked`.
    public var permissions: String
}

/// What the core knows of a manager's place: there at all, running now, and the bot whose bot-held secret its record
/// carries (it is this workspace's manager's own, not a stranger of the same name).
public struct ManagerPlaceInfo: Equatable, Sendable {
    public var exists: Bool
    public var running: Bool
    public var heldBy: String?
    public init(exists: Bool = false, running: Bool = false, heldBy: String? = nil) { self.exists = exists; self.running = running; self.heldBy = heldBy }
}

/// How a manager is started and stopped — the daemon's (`DaemonManagerLauncher`: `macOpen`/`macReopen`/`macEnd` and the
/// sandbox create/start/run/shutdown paths), or a test's fake.
public protocol ManagerLauncher: Sendable {
    func info(isolation: ManagerIsolation, place: String) async -> ManagerPlaceInfo
    /// Start it; answers what to say.
    func launch(_ o: ManagerLaunchOrder) async throws -> [String]
    /// Stop it (only called while it runs); keeps its record, disk and conversation.
    func stop(isolation: ManagerIsolation, place: String) async throws
}

/// The daemon's launcher: the core's own paths.
final class DaemonManagerLauncher: ManagerLauncher, @unchecked Sendable {
    weak var core: HostCore?
    init(core: HostCore) { self.core = core }
    func info(isolation: ManagerIsolation, place: String) async -> ManagerPlaceInfo {
        await core?.managerPlaceInfo(isolation, place) ?? ManagerPlaceInfo()
    }
    func launch(_ o: ManagerLaunchOrder) async throws -> [String] {
        guard let core else { throw HostError(.unavailable, "the daemon is stopping") }
        return try await core.launchManager(o)
    }
    func stop(isolation: ManagerIsolation, place: String) async throws {
        guard let core else { throw HostError(.unavailable, "the daemon is stopping") }
        try await core.stopManager(isolation, place)
    }
}

extension HostCore {
    var managerLauncher: any ManagerLauncher { managerLauncherOverride ?? DaemonManagerLauncher(core: self) }

    // MARK: the record's manager (`--manager` on new and edit)

    /// The manager's entry for `bot` in workspace `w`: the bot exists, is not retired, does not run elsewhere; its
    /// isolation resolved (unfenced only when named).
    func workspaceManagerEntry(bot: String, asked: String?, workspace w: String, at: Date) throws -> WorkspaceAgent {
        if let why = ChatNames.refusal(bot) { throw HostError(.invalid, why) }
        guard let b = try bots.read().bot(bot) else { throw HostError(.notFound, "\(bot) is not a bot (doz bot ls)") }
        if let at = b.retiredAt { throw BotName.retiredRefusal(bot, at) }
        guard b.isolation.default != "elsewhere" else {
            throw HostError(.invalid, "a bot elsewhere runs on its own machine; Dozable never starts it — choose a bot that runs here")
        }
        let iso = try ManagerIsolation.resolve(asked: asked, botDefault: b.isolation.default)
        if iso == .unfenced, let no = unfencedManagerRefusal() { throw no }
        let s = ManagerLaunch.sessionName(workspace: w)
        return WorkspaceAgent(name: bot, role: "manager", place: iso == .vm ? .sandbox(s) : .macSession(s), startedBy: "you", startedAt: at,
                              bot: bot, isolation: iso.rawValue)
    }

    /// Whether a workspace's manager entry runs now.
    func managerRunning(_ a: WorkspaceAgent) async -> Bool {
        guard a.isManager, let place = a.place.sandbox ?? a.place.session else { return false }
        return await managerLauncher.info(isolation: ManagerIsolation(rawValue: a.isolation ?? "fenced") ?? .fenced, place: place).running
    }

    /// bot → the workspace where it runs as a manager now.
    func runningManagers() async -> [String: String] {
        var out: [String: String] = [:]
        for w in workspaces.records() {
            for a in w.agents where a.isManager {
                if let b = a.bot, out[b] == nil, await managerRunning(a) || startingWorkspaces.contains(w.name) { out[b] = w.name }
            }
        }
        return out
    }

    // MARK: the set-up check's input

    /// The set-up check's input for `rec`. The start reads everything, the keychain included. A LOOK (`look`: the plan,
    /// `show`) never reads the keychain (`keychainReadable` nil — a locked one shows only at the start), takes chat from its
    /// setting when no daemon runs (`workspaceLookReadiness`) and nothing starts the daemon. The plan's in-memory record also
    /// gives the brief's size (`brief`), whether its room is made or linked when it is (`roomWillBeMade`) and the folders
    /// made with it (`foldersMadeNow`).
    func workspaceSetupInput(_ rec: WorkspaceRecord, look: Bool = false, brief: Int? = nil, roomWillBeMade: Bool = false,
                             foldersMadeNow: Set<String> = []) async -> WorkspaceSetupCheck.Input {
        let (readiness, assumed) = await workspaceLookReadiness(look: look)
        let chat: WorkspaceSetupCheck.Chat
        var roomExists = false
        switch readiness {
        case .off: chat = .off
        case .notReady(let why): chat = .notReady(why)
        case .ready:
            chat = .ready
            if roomWillBeMade || assumed {
                roomExists = true
            } else if let r = rec.mainRoom?.chatRoom {
                roomExists = (try? workspaceChat?.rooms().contains(r)) == true
            }
        }
        let folders = rec.folders.map { f -> WorkspaceSetupCheck.Folder in
            var d: ObjCBool = false
            return .init(path: f.path, exists: foldersMadeNow.contains(f.path)
                         || (FileManager.default.fileExists(atPath: f.path, isDirectory: &d) && d.boolValue))
        }
        let sessions = mac.records().sessions
        // The adopted agents (the manager has its own checks; a worker is added once the workspace has started).
        let agents = rec.agents.filter { !$0.isManager && !$0.isWorker }.map { a -> WorkspaceSetupCheck.Agent in
            if let s = a.place.sandbox { return .init(name: a.name, place: s, kind: "sandbox", exists: managed[s] != nil) }
            if a.place.mac == true, let s = a.place.session {
                return .init(name: a.name, place: a.place.display, kind: "session", exists: sessions[s] != nil)
            }
            return .init(name: a.name, place: a.place.display, kind: "agent", exists: true)
        }
        var manager: WorkspaceSetupCheck.Manager?
        if let m = rec.manager, let bot = m.bot {
            let iso = ManagerIsolation(rawValue: m.isolation ?? "fenced") ?? .fenced
            let place = m.place.sandbox ?? m.place.session ?? ManagerLaunch.sessionName(workspace: rec.name)
            let b = bots.readOrEmpty().bot(bot)
            var check = WorkspaceSetupCheck.Manager(bot: bot, known: b != nil, retired: b?.retired ?? false,
                                                    botIsolation: b?.isolation.default ?? "fenced", keeper: b?.token.keeper ?? "none",
                                                    deliver: b?.deliver ?? "poll", isolation: iso.rawValue, agent: b?.agent ?? "?",
                                                    programOnPath: nil, keychainReadable: look ? nil : false, placeName: place)
            if let b {
                // 749: under the stub agent the program is this doz (never the agent's).
                if iso != .vm, let p = ManagerLaunch.program(agent: b.agent), !buildFlavor.isHelper {
                    check.programOnPath = TestSafety.stubAgent() ? true : await mac.programOnPath(p)
                }
                if !look, let v = services.keychain.read(service: botService(bot), account: Keychain.user).value {
                    check.keychainReadable = BotTokens.fingerprint(v) == b.token.fingerprint
                }
            }
            let info = await managerLauncher.info(isolation: iso, place: place)
            // Ours: its record carries this bot's bot-held secret, or this manager was stopped there (a VM's shutdown revokes
            // its secrets), or an unfenced one's token folder is there.
            let ours = info.heldBy == bot || m.stoppedAt != nil || (iso == .unfenced && managerTokenFolderExists(place))
            check.placeTaken = info.exists && !ours
            manager = check
        }
        var input = WorkspaceSetupCheck.Input(workspace: rec.name, briefBytes: brief ?? workspaceBriefText(rec)?.utf8.count ?? 0, chat: chat,
                                              mainRoom: rec.mainRoom?.chatRoom, mainRoomExists: roomExists, folders: folders, agents: agents,
                                              manager: manager)
        input.declaredWorkers = rec.declaredWorkers.count
        return input
    }

    /// The other live workspace `bot` runs in (nil: none): as a running manager, or as a worker not ended.
    func liveWorkspace(of bot: String, except w: String) async -> WorkspaceSetupCheck.Entry? {
        var entries: [WorkspaceSetupCheck.Entry] = []
        for r in workspaces.records() where r.name != w {
            for a in r.agents where a.bot == bot {
                if a.isManager { entries.append(.init(workspace: r.name, bot: a.bot, running: await managerRunning(a))) }
                if a.isLiveWorker { entries.append(.init(workspace: r.name, bot: a.bot, running: true, role: "worker")) }
            }
        }
        return WorkspaceSetupCheck.liveElsewhereEntry(bot: bot, workspace: w, entries: entries, starting: startingWorkspaces)
    }

    /// bot → the workspace where it works now, as a worker not ended.
    func liveWorkers() -> [String: String] {
        var out: [String: String] = [:]
        for w in workspaces.records() { for a in w.agents where a.isLiveWorker { if let b = a.bot, out[b] == nil { out[b] = w.name } } }
        return out
    }

    // MARK: start

    /// The start, then the workers declared at `new` (`startDeclaredWorkers`): one that does not start is a note — the
    /// workspace is started either way, and the next start tries it again.
    func workspaceStart(_ w: WorkspaceRequest) async throws -> WorkspaceStarted {
        var s = try await workspaceStartOnce(w)
        let (started, notes) = await startDeclaredWorkers(s.name)
        guard !started.isEmpty || !notes.isEmpty else { return s }
        s.workers = started.isEmpty ? nil : started
        s.notes = (s.notes ?? []) + notes
        if let rec = try? workspaceRecord(s.name) { s.workspace = await workspaceDetail(rec, withBrief: false) }
        return s
    }

    func workspaceStartOnce(_ w: WorkspaceRequest) async throws -> WorkspaceStarted {
        let n = try workspaceName(w)
        // 1. Under the gate: the check (nothing written on a refusal), then the mark.
        await workspaceGate.lock("workspaces")
        var rec: WorkspaceRecord
        do {
            rec = try workspaceRecord(n)
            guard rec.flags.archivedAt == nil, rec.flags.finishedAt == nil else {
                throw HostError(.invalidPhase, "\(n) is \(rec.flags.archivedAt != nil ? "archived" : "finished")")
            }
            guard !startingWorkspaces.contains(n) else { throw HostError(.invalidPhase, "\(n) is starting already") }
            guard !lifecycleWorkspaces.contains(n) else {
                throw HostError(.invalidPhase, "\(n) is busy: it is being put to sleep, woken, finished or archived — start it once that is over")
            }
            let gaps = WorkspaceSetupCheck.gaps(await workspaceSetupInput(rec))
            if !gaps.isEmpty {
                throw HostError(.invalidPhase, "\(n) is not fully set up yet:\n" + gaps.map { "  - " + $0.line }.joined(separator: "\n"))
            }
            // 749: under the stub agent a VM manager is refused before anything is posted or made.
            if let m = rec.manager, let no = stubVMRefusal(m.name, isolation: ManagerIsolation(rawValue: m.isolation ?? "fenced") ?? .fenced) {
                throw no
            }
            if let bot = rec.manager?.bot, let other = await liveWorkspace(of: bot, except: n) {
                throw HostError(.exists, WorkspaceSetupCheck.liveElsewhereRefusal(bot: bot, other))
            }
            // The dashboard asks for the person's confirmation of an unfenced manager (it acts as them): without it, refused —
            // nothing posted, nothing started. The CLI never asks for it (naming --manager-isolation unfenced is the consent).
            if w.confirmRequired == true, let m = rec.manager, m.actsAsYou, w.unfencedConfirmed != true {
                throw HostError(.invalidPhase, "\(m.name) acts as you — confirm it")
            }
            startingWorkspaces.insert(n)
        } catch {
            workspaceGate.unlock("workspaces")
            throw error
        }
        workspaceGate.unlock("workspaces")
        await workspaceGate.lock("workspace:" + n)
        defer {
            startingWorkspaces.remove(n)
            workspaceGate.unlock("workspace:" + n)
        }
        var notes: [String] = []
        let chat = workspaceChat
        let ready = await chat?.readiness() == .ready
        let room = rec.mainRoom?.chatRoom
        // 2. The bot invited to the main room.
        if let bot = rec.manager?.bot, let room, let chat, ready {
            if try chat.invite(room: room, name: bot) {
                try? workspaces.append(n, WorkspaceLogEntry(action: "bot-invited", agent: bot, room: room))
                logAgentJoined(n, agent: bot, room: room)
            }
        }
        // 3. The kick-off, as you, before the manager — once. The first run opens just before it (each room's last seq its
        // start marker, as data): the brief is the run's first message.
        var kickedOff = false
        if rec.flags.startedAt == nil {
            _ = try? await openRun(n)
            if let room, let chat, ready {
                let brief = workspaceBriefText(rec) ?? ""
                let text = ManagerKickoff.briefPost(brief: brief, refs: rec.brief.refs)
                try chat.post(room: room, content: text)
                kickedOff = true
                rec = try await workspaceUpdate(n) { r in
                    r.flags.startedAt = Date()
                    return [WorkspaceLogEntry(action: "kicked-off", room: room, sha256: WorkspaceStore.sha256(Data(text.utf8)), bytes: text.utf8.count)]
                }
            } else {
                rec = try await workspaceUpdate(n) { r in r.flags.startedAt = Date(); return [] }
                notes.append("chat is off: the brief was not posted — you drive")
            }
        }
        // No manager: you drive.
        guard let m = rec.manager, let bot = m.bot else {
            note(nil, "workspace \(n) started (no manager)")
            return WorkspaceStarted(name: n, kickedOff: kickedOff, notes: notes.isEmpty ? nil : notes,
                                    workspace: await startDone(n, rec))
        }
        let iso = ManagerIsolation(rawValue: m.isolation ?? "fenced") ?? .fenced
        let place = m.place.sandbox ?? m.place.session ?? ManagerLaunch.sessionName(workspace: n)
        let info = await managerLauncher.info(isolation: iso, place: place)
        if info.running {
            notes.append("\(bot) is running already")
            return WorkspaceStarted(name: n, kickedOff: kickedOff, manager: bot, isolation: iso.rawValue, session: place, alreadyRunning: true,
                                    notes: notes, workspace: await startDone(n, rec))
        }
        // 4–5. Its token and its session.
        let launched: (fingerprint: String, notes: [String])
        do {
            launched = try await workspaceLaunchManager(rec, bot: bot, isolation: iso, place: place, restart: info.exists)
        } catch {
            let e = HostError.from(error)
            throw HostError(e.code, "\(bot) did not start: \(e.message)"
                            + (rec.flags.startedAt != nil ? " — doz workspace start \(n) again (the brief is not posted twice)" : ""))
        }
        notes += launched.notes
        // 6. The record.
        rec = try await workspaceUpdate(n) { r in
            guard let i = r.managerIndex else { return [] }
            r.agents[i].place = iso == .vm ? .sandbox(place) : .macSession(place)
            r.agents[i].stoppedAt = nil
            return [WorkspaceLogEntry(action: "manager-started", agent: bot, place: r.agents[i].place.key, isolation: iso.rawValue,
                                      fingerprint: launched.fingerprint)]
        }
        note(nil, "workspace \(n): manager \(bot) started (\(iso.rawValue), \(place)), token fp \(launched.fingerprint)")
        return WorkspaceStarted(name: n, kickedOff: kickedOff, manager: bot, isolation: iso.rawValue, session: place,
                                notes: notes.isEmpty ? nil : notes, workspace: await startDone(n, rec))
    }

    /// The workspace as it is once a start is over (no longer "starting").
    func startDone(_ n: String, _ rec: WorkspaceRecord) async -> WorkspaceDetail {
        startingWorkspaces.remove(n)
        return await workspaceDetail(rec, withBrief: false)
    }

    /// Change the record under the `workspaces` gate: read it again, apply, write, log.
    func workspaceUpdate(_ n: String, _ change: (inout WorkspaceRecord) throws -> [WorkspaceLogEntry]) async throws -> WorkspaceRecord {
        await workspaceGate.lock("workspaces")
        defer { workspaceGate.unlock("workspaces") }
        var r = try workspaceRecord(n)
        let log = try change(&r)
        try workspaces.write(r)
        for e in log { try? workspaces.append(n, e) }
        spaceFramesPoke(n, log.first?.action ?? "the workspace changed")
        return r
    }

    /// The manager's launch: its token, its START, its session or sandbox. Answers the token's fingerprint.
    func workspaceLaunchManager(_ rec: WorkspaceRecord, bot: String, isolation iso: ManagerIsolation, place: String,
                                restart: Bool) async throws -> (fingerprint: String, notes: [String]) {
        guard let b = try bots.read().bot(bot) else { throw HostError(.notFound, "\(bot) is not a bot (doz bot ls)") }
        let pagePort = ChatSettingsView.read().pagePort
        let workdir = try managerFolder(rec)
        let instructions = bots.readInstructions(bot)
        let start = Data(ManagerKickoff.startText(bot: bot, workspace: rec.name, room: rec.mainRoom?.chatRoom ?? rec.name, isolation: iso,
                                                  skills: b.skills, instructions: instructions, brief: workspaceBriefText(rec) ?? "",
                                                  refs: rec.brief.refs).utf8)
        var notes: [String] = []
        let fingerprint: String
        let plan: ManagerLaunch.Plan
        switch iso {
        case .fenced, .vm:
            let startFile = iso == .vm ? "~/" + ManagerLaunch.vmStartFolder + "/start.md"
                : MacFence.sessionFolder(try mac.fencePlaces(), session: place) + "/etc/manager/start.md"
            let secret = try botLaunchSecret(bot, port: pagePort)
            fingerprint = secret.fingerprint
            plan = try ManagerLaunch.plan(isolation: iso, agent: b.agent, model: b.model, bot: bot, startFile: startFile, pagePort: pagePort,
                                          fingerprint: fingerprint)
        case .unfenced:
            let prepared = try await prepareUnfencedManager(rec.name, bot: b, place: place, start: start)
            fingerprint = prepared.fingerprint
            notes += prepared.notes
            plan = try ManagerLaunch.plan(isolation: iso, agent: b.agent, model: b.model, bot: bot, startFile: prepared.startFile,
                                          pagePort: pagePort, fingerprint: fingerprint, tokenFile: prepared.tokenFile)
        }
        let order = ManagerLaunchOrder(workspace: rec.name, bot: bot, isolation: iso, place: place, workdir: workdir, plan: plan, start: start,
                                       restart: restart, agent: b.agent, account: b.account, model: b.model,
                                       permissions: rec.defaults.network ?? "locked")
        do {
            notes += try await managerLauncher.launch(order)
        } catch {
            if iso == .unfenced { removeManagerTokenFolder(place) }
            throw error
        }
        return (fingerprint, notes)
    }

    /// The manager's folder: the workspace's main one, else `<projects_dir>/<workspace>` (made 0700).
    func managerFolder(_ rec: WorkspaceRecord) throws -> String {
        if let f = rec.mainFolder?.path { return f }
        let p = Workspace.defaultPath(name: rec.name)
        TestSafety.checkMadeFolder(p)
        do { try MacFenceHostFS.ensureDirectory(p, mode: 0o700) } catch {
            throw HostError(.failed, "cannot make \(DisplayPath.tilde(p)) for the manager: \(error)")
        }
        return WorkspaceStore.resolved(p)
    }

    /// The bot's token as a BOT-HELD launch secret to `host.dozable.internal:<port>`: its value read now (and only while it
    /// is the token recorded) to check it is there; the record carries no item and no value. The reach check holds (the
    /// port is the one the manager is given); there is no source file to check.
    func botLaunchSecret(_ bot: String, port: Int, variable: String = ManagerLaunch.tokenVariable,
                         fileVariable: String = ManagerLaunch.tokenFileVariable) throws -> LaunchSecret {
        guard let b = try bots.read().bot(bot), b.holdsToken else { throw HostError(.invalid, "\(bot)'s token is not held by Dozable — doz bot token \(bot) --new") }
        guard let v = services.keychain.read(service: botService(bot), account: Keychain.user).value,
              BotTokens.fingerprint(v) == b.token.fingerprint else {
            throw HostError(.unavailable, "\(bot)'s token cannot be read from the login keychain — unlock it, or doz bot token \(bot) --new")
        }
        let (host, p) = try LaunchSecrets.destination("\(HostRoute.hostName):\(port)", variable: variable)
        return LaunchSecret(variable: variable, fileVariable: fileVariable, host: host, port: p,
                            fingerprint: CredentialFingerprint.of(v), keychainService: nil, bot: bot)
    }

    // MARK: stop

    /// `doz workspace manager stop W` (`workspace-stop` with `managerOnly`): the manager alone, its conversation kept.
    func workspaceStop(_ w: WorkspaceRequest) async throws -> WorkspaceStopped {
        let n = try workspaceName(w)
        await workspaceGate.lock("workspace:" + n)
        defer { workspaceGate.unlock("workspace:" + n) }
        var rec = try workspaceRecord(n)
        guard let m = rec.manager, let bot = m.bot else {
            return WorkspaceStopped(name: n, stopped: false, notes: ["\(n) has no manager: nothing to stop"],
                                    workspace: await workspaceDetail(rec, withBrief: false))
        }
        let iso = ManagerIsolation(rawValue: m.isolation ?? "fenced") ?? .fenced
        let place = m.place.sandbox ?? m.place.session ?? ManagerLaunch.sessionName(workspace: n)
        guard await managerLauncher.info(isolation: iso, place: place).running else {
            return WorkspaceStopped(name: n, stopped: false, manager: bot, notes: ["\(bot) is not running: nothing to stop"],
                                    workspace: await workspaceDetail(rec, withBrief: false))
        }
        try await managerLauncher.stop(isolation: iso, place: place)
        if iso == .unfenced { removeManagerTokenFolder(place) }
        rec = try await workspaceUpdate(n) { r in
            guard let i = r.managerIndex else { return [] }
            r.agents[i].stoppedAt = Date()
            return [WorkspaceLogEntry(action: "manager-stopped", agent: bot, place: r.agents[i].place.key, isolation: iso.rawValue)]
        }
        note(nil, "workspace \(n): manager \(bot) stopped (its conversation kept)")
        return WorkspaceStopped(name: n, stopped: true, manager: bot,
                                notes: ["\(bot) stopped; its conversation is kept — doz workspace start \(n) wakes it (the brief is not posted again)"],
                                workspace: await workspaceDetail(rec, withBrief: false))
    }

    // MARK: the daemon's launcher

    func managerPlaceInfo(_ iso: ManagerIsolation, _ place: String) async -> ManagerPlaceInfo {
        switch iso {
        case .vm:
            guard let m = managed[place] else { return ManagerPlaceInfo() }
            let phase = await effectivePhase(m)
            return ManagerPlaceInfo(exists: true, running: phase == .running || phase == .booting, heldBy: m.config.secrets?.first { $0.bot != nil }?.bot)
        case .fenced, .unfenced:
            guard !buildFlavor.isHelper, let rec = mac.records().sessions[place] else { return ManagerPlaceInfo() }
            return ManagerPlaceInfo(exists: true, running: await mac.isRunning(place), heldBy: rec.fence?.secrets?.first { $0.bot != nil }?.bot)
        }
    }

    func launchManager(_ o: ManagerLaunchOrder) async throws -> [String] {
        switch o.isolation {
        case .fenced, .unfenced: return try await launchManagerOnMac(o)
        case .vm: return try await launchManagerInVM(o)
        }
    }

    /// Fenced (`macOpen` with the bot-held secret and START under its etc/) or unfenced (`macOpen` with the token file's
    /// variable); a start after a stop re-opens the same session, resuming its conversation (`macReopen`).
    func launchManagerOnMac(_ o: ManagerLaunchOrder) async throws -> [String] {
        guard !buildFlavor.isHelper else { throw HostError(.notImplemented, BuildFlavor.helperLeavesOut("sessions on this Mac")) }
        let fenced = o.isolation == .fenced
        let secrets = o.plan.secret.map { [$0] }
        if o.restart, let rec = mac.records().sessions[o.place] {
            let located = MacDeckhold.locate()
            guard let holder = located.url else {
                throw HostError(.unavailable, "sessions on this Mac need deckhold-mac beside doz — \(located.why ?? "it is not there")")
            }
            guard (rec.fence != nil) == fenced else {
                throw HostError(.invalid, "the session \(o.place) on this Mac is \(fenced ? "unfenced" : "fenced") — doz sessions end @mac \(o.place) twice, then start again")
            }
            await sessionGate.lock(MacPlace.name)
            defer { sessionGate.unlock(MacPlace.name) }
            let held = await macLearnClaudeID(o.place)
            let how = try await mac.end(o.place)
            if how == .stuck { throw HostError(.failed, "session \(o.place) on this Mac did not end, even after SIGKILL") }
            let r = try await macReopen(o.place, rec: mac.records().sessions[o.place] ?? rec, holder: holder, fresh: false,
                                        size: TermSize(cols: 120, rows: 40), knownID: held, ended: how.rawValue,
                                        request: HostRequest(.sessionRestart, name: MacPlace.name), extra: agentMacReopenEnvironment(o.plan.environment),
                                        botSecrets: secrets, managerStart: fenced ? o.start : nil)
            return r.notice.map { [$0] } ?? []
        }
        // 749: the stub agent in its place under DOZ_TEST_STUB_AGENT (guarded runs only).
        let program = agentMacProgram(argv: o.plan.argv, environment: o.plan.environment, account: o.account, workspace: o.workspace, name: o.bot, task: nil)
        return try await launchAgentOnMac(AgentMacLaunch(place: o.place, argv: program.argv, workdir: o.workdir, environment: program.environment,
                                                         fenced: fenced, permissions: o.permissions, hostPorts: o.plan.hostPorts,
                                                         account: program.account, secrets: secrets, start: fenced ? o.start : nil,
                                                         startFolder: "manager", bridgesOff: false))
    }

    /// In a micro VM: the sandbox made the first time (`create` with the choices `doz create S --agent A --approvals skip
    /// --permissions P --host-port PORT --folder MAIN [--account] [--model]` sends), the bot-held secret in its record, started,
    /// START copied by one exec, then the session `manager`. A start after a stop starts the same sandbox (its disk kept)
    /// and continues the conversation.
    func launchManagerInVM(_ o: ManagerLaunchOrder) async throws -> [String] {
        if let no = stubVMRefusal(o.bot, isolation: .vm) { throw no }
        guard let secret = o.plan.secret else { throw HostError(.invalid, "a VM manager needs its token's launch secret") }
        let env = ProcessInfo.processInfo.environment
        let seamArgv = TestSafety.guarded(env) ? env["DOZ_TEST_MANAGER_ARGV"].flatMap { s in
            (try? JSONDecoder().decode([String].self, from: Data(s.utf8))) } : nil
        return try await launchAgentInVM(AgentVMLaunch(
            sandbox: o.place, session: ManagerLaunch.vmSession, create: true, workdir: o.workdir, permissions: o.permissions, account: o.account,
            model: o.model, agent: o.agent, hostPorts: o.plan.hostPorts, secret: secret, start: o.start, startDir: ManagerLaunch.vmStartFolder,
            argv: seamArgv ?? (o.restart ? ManagerLaunch.vmResumeArgv(agent: o.agent) : nil) ?? o.plan.argv, environment: o.plan.environment,
            seamImage: TestSafety.guarded(env) ? env["DOZ_TEST_MANAGER_IMAGE"] : nil, cpus: nil, memoryMiB: nil, bridgesOff: false, alias: nil))
    }

    func stopManager(_ iso: ManagerIsolation, _ place: String) async throws {
        switch iso {
        case .fenced, .unfenced:
            var r = HostRequest(.sessionEnd, name: MacPlace.name)
            r.session = place
            _ = try await macEnd(r)
        case .vm:
            let a = await handle(HostRequest(.shutdown, name: place))
            if let e = a.error { throw HostError(e.code, e.message) }
        }
    }
}

// MARK: the role-aware launch paths (a manager's and a worker's)

/// One open of an agent's session on this Mac (fenced or unfenced) for a workspace: its argv and environment (never a
/// token), its folder, its network permissions and the chat server's page port (fenced), the bot-held or daemon-made
/// secrets, START under its `etc/<startFolder>/` (fenced), and — a worker's narrowest defaults — no URL opening and no
/// clipboard (`bridgesOff`).
struct AgentMacLaunch {
    var place: String
    var argv: [String]
    var workdir: String
    var environment: [String: String]
    var fenced: Bool
    var permissions: String
    var hostPorts: [UInt16]
    var account: String?
    var secrets: [LaunchSecret]?
    var start: Data?
    var startFolder: String
    var bridgesOff: Bool
}

/// One launch of an agent in a sandbox: made the first time (`create`), its secret joined to the sandbox's record, started,
/// START copied by one exec under `~/<startDir>/start.md`, then its session. `create` false: a sandbox that must exist
/// already (a worker joining another agent's). `alias`: that session's own token variable (a shared sandbox).
struct AgentVMLaunch {
    var sandbox: String
    var session: String
    var create: Bool
    var workdir: String
    var permissions: String
    var account: String?
    var model: String?
    var agent: String
    var hostPorts: [UInt16]
    var secret: LaunchSecret
    var start: Data
    var startDir: String
    var argv: [String]
    var environment: [String: String]
    var seamImage: String?
    var cpus: Int?
    var memoryMiB: UInt64?
    var bridgesOff: Bool
    var alias: String?
}

extension HostCore {
    func launchAgentOnMac(_ l: AgentMacLaunch) async throws -> [String] {
        var r = HostRequest(.openSession, name: MacPlace.name)
        r.session = l.place
        r.argv = l.argv
        r.folder = l.workdir
        r.environment = l.environment
        r.cols = 120
        r.rows = 40
        if l.fenced {
            var req = MacFenceRequest(permissions: [l.permissions])
            req.hostPorts = l.hostPorts.map { HostPort(port: $0) }
            req.account = l.account
            if l.bridgesOff {
                req.openURL = false
                req.clipboard = false
            }
            r.macFence = req
        }
        let opened = try await macOpen(r, botSecrets: l.secrets, managerStart: l.start, startFolder: l.startFolder)
        return (opened.fenceNotes ?? []) + (opened.notice.map { [$0] } ?? [])
    }

    func launchAgentInVM(_ l: AgentVMLaunch) async throws -> [String] {
        if l.create, managed[l.sandbox] == nil {
            var c = CreateOptions(image: l.seamImage ?? (ManagerLaunch.program(agent: l.agent) == "codex" ? "codex" : "claude-code"))
            c.folder = l.workdir
            c.network = l.permissions
            c.account = l.account
            c.hostPorts = l.hostPorts.map { HostPort(port: $0) }
            c.cpus = l.cpus
            c.memoryMiB = l.memoryMiB
            if l.seamImage == nil {
                c.settings = ["approvals": .string("skip")]
                c.model = l.model
            }
            if l.bridgesOff {
                c.settings = (c.settings ?? [:]).merging([SettingKey.clipboard: .string("off"), SettingKey.browserBridge: .string("off")]) { a, _ in a }
            }
            var r = HostRequest(.create, name: l.sandbox)
            r.create = c
            let a = await handle(r)
            if let e = a.error { throw HostError(e.code, e.message) }
        }
        guard let m = managed[l.sandbox] else { throw HostError(.notFound, "no sandbox \(l.sandbox)") }
        m.config.secrets = (m.config.secrets ?? []).filter { $0.variable != l.secret.variable } + [l.secret]
        try m.config.write(store.configFile(m.name))
        if await effectivePhase(m) != .running {
            let a = await handle(HostRequest(.start, name: l.sandbox))
            if let e = a.error { throw HostError(e.code, e.message) }
        }
        applyLaunchSecrets(m)
        // START, as the image's user, in one exec.
        let image = m.config.spec.imageSpec
        let home = image?.home ?? "/root", user = image?.user ?? "root"
        let dir = home + "/" + l.startDir
        let base = home + "/" + ManagerLaunch.vmStartFolder
        let owned = dir == base ? "'\(dir)'" : "'\(base)' '\(dir)'"
        let script = "set -e; umask 077; mkdir -p '\(dir)'; printf %s '\(l.start.base64EncodedString())' | base64 -d > '\(dir)/start.md'; "
            + (dir == base ? "chown -R '\(user)' '\(dir)'; " : "chown '\(user)' \(owned); chown -R '\(user)' '\(dir)'; ")
            + "chmod 0700 \(owned); chmod 0600 '\(dir)/start.md'"
        let x = try await m.sandbox.exec(["sh", "-c", script], timeoutSeconds: 30)
        if x.exitCode != 0 { throw HostError(.failed, "could not put START in \(l.sandbox) (exit \(x.exitCode))") }
        var r = HostRequest(.openSession, name: l.sandbox)
        r.session = l.session
        r.argv = l.argv
        r.environment = l.environment
        r.start = true
        if let v = l.alias { sessionSecretAliases[l.sandbox + "/" + l.session] = v }
        let a = await handle(r)
        sessionSecretAliases[l.sandbox + "/" + l.session] = nil
        if let e = a.error { throw HostError(e.code, e.message) }
        return []
    }
}

// MARK: an UNFENCED manager's (or worker's) token file — SEPARABLE (open with the owner)
//
// An unfenced session has no proxy, so its token cannot be a placeholder: it is the REAL token, in a 0600 file in a 0700
// folder under the per-user temp folder (`<temp>/doz-<store's 8 hex>/manager-<session>/chat-token`), named by
// CHAT_TOKEN_FILE, written just before the open (deleted when it fails), deleted at stop (a worker's at `doz worker end`),
// swept at a daemon's start. An unfenced worker's file is at the same path for its own session (`workerTokenFolder`).
// To turn unfenced managers AND workers off, make `unfencedManagerRefusal` return its error: `--manager-isolation unfenced`
// and `doz worker add --isolation unfenced` are then refused, and nothing below runs. `WorkspaceManagerTests.testUnfenced…`,
// `WorkspaceWorkerTests`, `make test-cli-workspace` rows 19 and 27.
extension HostCore {
    /// nil: an unfenced manager or worker may be named. Return a `HostError` here to refuse every one.
    func unfencedManagerRefusal() -> HostError? { nil }

    /// `<temp>/doz-<8 hex of the store's path>` — this store's, resolved.
    nonisolated var managerTokenRoot: String {
        let digest = SHA256.hash(data: Data(store.root.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
        return WorkspaceStore.resolved(NSTemporaryDirectory()) + "/doz-" + digest.prefix(8)
    }

    nonisolated func managerTokenFolder(_ session: String) -> String { managerTokenRoot + "/manager-" + session }

    /// An unfenced WORKER's token folder: the manager's path for its session (OPEN WITH THE OWNER — this one line is the change).
    nonisolated func workerTokenFolder(_ session: String) -> String { managerTokenFolder(session) }

    nonisolated func managerTokenFolderExists(_ session: String) -> Bool { MacFenceHostFS.kind(managerTokenFolder(session)) != nil }

    /// The token file and START for an unfenced manager; an inbox bot whose inbox names another session is pointed at
    /// this one (said).
    func prepareUnfencedManager(_ w: String, bot b: BotRecord, place: String,
                                start: Data) async throws -> (tokenFile: String, startFile: String, fingerprint: String, notes: [String]) {
        if let no = unfencedManagerRefusal() { throw no }
        TestSafety.enforce(TestSafety.managerTokenViolation(store: store.root))
        guard let v = services.keychain.read(service: botService(b.name), account: Keychain.user).value,
              BotTokens.fingerprint(v) == b.token.fingerprint else {
            throw HostError(.unavailable, "\(b.name)'s token cannot be read from the login keychain — unlock it, or doz bot token \(b.name) --new")
        }
        let files = try writeAgentTokenFolder(managerTokenFolder(place), token: v, start: start, who: b.name)
        var notes = ["unfenced: \(b.name) acts as you; its token is in a 0600 file named by $\(ManagerLaunch.tokenFileVariable), deleted at stop"]
        notes += await pointBotInbox(w, bot: b, place: place)
        return (files.tokenFile, files.startFile, BotTokens.fingerprint(v), notes)
    }

    /// The 0700 folder `dir` with the token (`chat-token`) and START (`start.md`), both 0600; removed whole when a write fails.
    func writeAgentTokenFolder(_ dir: String, token v: String, start: Data, who: String) throws -> (tokenFile: String, startFile: String) {
        do {
            try MacFenceHostFS.ensureDirectory(managerTokenRoot, mode: 0o700)
            try MacFenceHostFS.ensureDirectory(dir, mode: 0o700)
            try MacFenceHostFS.writeAtomically(Data(v.utf8), dir: dir, name: "chat-token", mode: 0o600)
            try MacFenceHostFS.writeAtomically(start, dir: dir, name: "start.md", mode: 0o600)
        } catch {
            try? FileManager.default.removeItem(atPath: dir)
            throw HostError(.failed, "cannot write \(who)'s token file: \(error)")
        }
        return (dir + "/chat-token", dir + "/start.md")
    }

    /// An inbox bot started unfenced in session `place`: its inbox pointed at that session when it names another (said).
    func pointBotInbox(_ w: String, bot b: BotRecord, place: String) async -> [String] {
        guard b.deliver == "inbox", b.session != place, let chat = botChat else { return [] }
        await botGate.lock("bots")
        defer { botGate.unlock("bots") }
        do {
            try await chat.set(b.name, deliver: "inbox", entry: nil, session: place)
            var file = try bots.read()
            if let i = file.index(b.name) { file.bots[i].session = place; try bots.write(file) }
            try? workspaces.append(w, WorkspaceLogEntry(by: "doz", action: "bot-invited", agent: b.name, place: "mac:" + place,
                                                        reason: "its inbox now names this session"))
            return ["\(b.name)'s inbox now names the session \(place)"]
        } catch {
            return ["\(b.name)'s inbox still names \(b.session ?? "another session"): \(HostError.from(error).message)"]
        }
    }

    /// The token file's folder, gone (at stop, or when the open failed).
    nonisolated func removeManagerTokenFolder(_ session: String) {
        try? FileManager.default.removeItem(atPath: managerTokenFolder(session))
    }

    /// At a daemon's start: every manager token folder of this store whose session does not run is deleted (a daemon that
    /// died before a stop). Never in the read-only core.
    public func sweepManagerTokenFiles() async {
        guard !readOnly else { return }
        let root = managerTokenRoot
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root) else { return }
        var removed = 0
        for d in names where d.hasPrefix("manager-") {
            let s = String(d.dropFirst("manager-".count))
            if await mac.isRunning(s) { continue }
            try? FileManager.default.removeItem(atPath: root + "/" + d)
            removed += 1
        }
        if removed > 0 { HostLog.line("workspaces: \(removed) manager token folder\(removed == 1 ? "" : "s") of no running session deleted") }
    }
}
