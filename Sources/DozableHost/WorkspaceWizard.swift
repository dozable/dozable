import Foundation

// 782 — the New workspace wizard's answers, added to the plan (`workspace-plan`; docs/engineering/workspaces.md, "Making
// one: the plan and the dry run"): the next free name, which bots can manage it and why the others cannot, and every
// refusal and gap said in the wizard's words, on the step and field that changes it. ONE source for each sentence: the
// draft's refusals and the set-up check's gaps are what `new` and `start` say; this only words them for a person at the
// wizard (no `doz …` command, no "brief"). The CLI and `--dry-run` keep `refusals` and `gaps`.

/// The next free name (`workspaceN`) and its folder.
public struct WorkspaceSuggestion: Codable, Equatable, Sendable {
    public var name: String
    public var folder: String
    public init(name: String, folder: String) { self.name = name; self.folder = folder }
}

/// A one-click fix the wizard offers: `poll` (`bot-set deliver=poll`), `token` (`bot-token`, held only), `use-room` (the
/// existing room as its room), `chat-on` (turn chat on).
public struct WorkspaceWizardFix: Codable, Equatable, Sendable {
    public var label: String
    public var action: String
    public init(label: String, action: String) { self.label = label; self.action = action }
}

/// Whether a bot can manage this workspace now; when not, why in one line, and its one fix where there is one.
public struct WorkspaceManagerFit: Codable, Equatable, Sendable {
    public var bot: String
    public var fits: Bool
    public var why: String?
    public var fix: WorkspaceWizardFix?
    public init(bot: String, fits: Bool, why: String? = nil, fix: WorkspaceWizardFix? = nil) {
        self.bot = bot; self.fits = fits; self.why = why; self.fix = fix
    }
}

/// One finding: the step (`name`, `manager`, `workers`, `chat`, `confirm`), the field it is about, the sentence.
public struct WorkspaceFinding: Codable, Equatable, Sendable {
    public var step: String
    public var field: String
    public var text: String
    public var fix: WorkspaceWizardFix?
    public init(step: String, field: String, text: String, fix: WorkspaceWizardFix? = nil) {
        self.step = step; self.field = field; self.text = text; self.fix = fix
    }
}

/// The wizard's words — pure (`WorkspaceWizardTests`).
public enum WorkspaceWizard {
    /// The program's name as a person knows it.
    public static func programWords(_ agent: String) -> String {
        ManagerLaunch.program(agent: agent) == "codex" ? "Codex" : "Claude Code"
    }

    /// A manager gap (by its code) in the wizard's words, and its fix.
    public static func managerWords(code: String, bot: String, agent: String, place: String, isolation: String) -> (String, WorkspaceWizardFix?) {
        switch code {
        case "notBot": return ("\(bot) is not a bot.", nil)
        case "retired": return ("\(bot) was retired.", nil)
        case "elsewhere": return ("Runs on another machine: Dozable never starts it.", nil)
        case "token": return ("Its token is not held by Dozable.", WorkspaceWizardFix(label: "Make a new token", action: "token"))
        case "keychain": return ("\(bot)'s key could not be read — unlock your login keychain.", nil)
        case "inbox": return ("Reached by inbox, which only an unfenced session gets.", WorkspaceWizardFix(label: "Reach it by poll", action: "poll"))
        case "webhook": return ("Reached by webhook: a manager Dozable starts collects its own messages.",
                                WorkspaceWizardFix(label: "Reach it by poll", action: "poll"))
        case "program": return ("\(programWords(agent)) is not installed on this Mac.", nil)
        case "agent": return ("Dozable starts Claude Code or Codex managers.", nil)
        case "placeTaken":
            return (isolation == "vm" ? "A sandbox called \(place) already exists." : "A session called \(place) already exists on this Mac.", nil)
        default: return ("\(bot) cannot manage it now.", nil)
        }
    }

    /// A bot live in another workspace, in the wizard's words.
    public static func liveWords(_ e: WorkspaceSetupCheck.Entry) -> String {
        e.role == "worker" ? "Working in \(e.workspace), which is running." : "Managing \(e.workspace), which is running."
    }

    /// A refusal of the draft (`new`'s sentence) as a finding. A refusal no wizard field causes says its first clause.
    public static func refusal(_ message: String, name: String) -> WorkspaceFinding {
        let m = message
        func has(_ s: String) -> Bool { m.contains(s) }
        if m.hasPrefix("which workspace") { return .init(step: "name", field: "name", text: "Give it a name.") }
        if m.hasPrefix("there is already a workspace") { return .init(step: "name", field: "name", text: "There is already a workspace \(name).") }
        if has("is not a workspace name") {
            return .init(step: "name", field: "name", text: "A name is 1–40 characters of a-z, 0-9 and -, not starting with -.")
        }
        if m.hasPrefix("there is already a room "), let r = word(after: "there is already a room ", in: m) {
            return .init(step: "chat", field: "room", text: "#\(r) exists.", fix: WorkspaceWizardFix(label: "Use it", action: "use-room"))
        }
        if m.hasPrefix("the room "), has(" is already the room of "), let r = word(after: "the room ", in: m),
           let w = word(after: " is already the room of ", in: m) {
            return .init(step: "chat", field: "room", text: "#\(r) is already the room of \(w).")
        }
        if m.hasPrefix("no room ") { return .init(step: "chat", field: "room", text: "That room is gone.") }
        if has("is a file, not a folder") || m.hasPrefix("no folder ") || has("is given twice") {
            return .init(step: "name", field: "folder", text: sentence(m))
        }
        if has("is not a bot") || has("was retired") || has("Dozable never starts it") || has("unfenced") && has("manager") {
            return .init(step: "manager", field: "manager", text: sentence(m))
        }
        if has("chat is on but its server is not ready") { return .init(step: "chat", field: "chat", text: "Chat is not answering yet — try again.") }
        if m.hasPrefix("chat is off") { return .init(step: "chat", field: "chat", text: "Chat is off.", fix: WorkspaceWizardFix(label: "Turn chat on", action: "chat-on")) }
        if m.hasPrefix("--room-name") { return .init(step: "chat", field: "room", text: "A room's name is 1–40 characters of a-z, 0-9 and -.") }
        if m.hasPrefix("--invite") { return .init(step: "chat", field: "invite", text: sentence(String(m.dropFirst("--invite: ".count)))) }
        if m.hasPrefix("--worker-isolation") || m.hasPrefix("new workers") {
            return .init(step: "workers", field: "workers", text: "New workers run fenced on this Mac or in a Sandbox.")
        }
        if m.hasPrefix("--network") { return .init(step: "workers", field: "network", text: "The network is Locked, Standard or Open.") }
        return .init(step: "confirm", field: "", text: sentence(m))
    }

    /// A set-up gap (not the manager's: those come with their codes) as a finding; nil for one the wizard cannot cause.
    public static func gap(_ g: WorkspaceSetupCheck.Gap) -> WorkspaceFinding? {
        switch g.item {
        case "chat":
            if g.why.hasPrefix("chat is on but") { return .init(step: "chat", field: "chat", text: "Chat is not answering yet — try again.") }
            return .init(step: "chat", field: "chat", text: "Chat is off: a manager and its workers talk in a room.",
                         fix: WorkspaceWizardFix(label: "Turn chat on", action: "chat-on"))
        case "room":
            return .init(step: "chat", field: "room", text: "It has no room: a manager talks in its room.")
        case "manager":
            return nil
        default:
            return .init(step: "confirm", field: "", text: sentence(g.why))
        }
    }

    /// The first clause of a sentence (before " — ", the command part), capitalised, ending with a full stop.
    public static func sentence(_ s: String) -> String {
        var t = s.components(separatedBy: " — ").first ?? s
        t = t.trimmingCharacters(in: .whitespaces)
        if let f = t.first { t = f.uppercased() + t.dropFirst() }
        return t.hasSuffix(".") ? t : t + "."
    }

    static func word(after prefix: String, in s: String) -> String? {
        guard let r = s.range(of: prefix) else { return nil }
        let w = s[r.upperBound...].prefix { !$0.isWhitespace && $0 != "," && $0 != "." }
        return w.isEmpty ? nil : String(w)
    }

    /// The findings, said once each, in step order.
    public static func ordered(_ f: [WorkspaceFinding]) -> [WorkspaceFinding] {
        let order = ["name", "manager", "workers", "chat", "confirm"]
        var seen = Set<String>()
        return f.filter { seen.insert($0.step + "|" + $0.text).inserted }
            .enumerated().sorted { (order.firstIndex(of: $0.element.step) ?? 9, $0.offset) < (order.firstIndex(of: $1.element.step) ?? 9, $1.offset) }
            .map(\.element)
    }
}

extension HostCore {
    /// The next free `workspaceN` (N ≥ 1): no workspace, chat room, sandbox or session on this Mac of that name, and no
    /// `<projects_dir>/workspaceN` that holds anything. Read-only.
    func workspaceSuggestion() async -> WorkspaceSuggestion {
        let rooms = (try? workspaceChat?.rooms()) ?? []
        let sessions = mac.records().sessions
        let fm = FileManager.default
        for n in 1...100_000 {
            let name = "workspace\(n)"
            if workspaces.exists(name) || rooms.contains(name) || managed[name] != nil || sessions[name] != nil { continue }
            if workspaceRoomOwner(name) != nil { continue }
            let folder = WorkspaceStore.resolved(Workspace.defaultPath(name: name))
            if let items = try? fm.contentsOfDirectory(atPath: folder), !items.isEmpty { continue }
            var dir: ObjCBool = false
            if fm.fileExists(atPath: folder, isDirectory: &dir), !dir.boolValue { continue }
            return WorkspaceSuggestion(name: name, folder: folder)
        }
        return WorkspaceSuggestion(name: "workspace", folder: WorkspaceStore.resolved(Workspace.defaultPath(name: "workspace")))
    }

    /// Every bot not retired, as the manager of workspace `name`, where the bot runs (unfenced included — the wizard asks the
    /// one consent at the end): whether it can manage now and, when not, why and its fix. A look: no keychain read.
    func workspaceManagerFits(name: String) async -> [WorkspaceManagerFit] {
        let file = bots.readOrEmpty()
        var out: [WorkspaceManagerFit] = []
        for b in file.bots where b.retiredAt == nil {
            let iso = ManagerIsolation(rawValue: IsolationWord.stored(b.isolation.default)) ?? .fenced
            let place = ManagerLaunch.sessionName(workspace: WorkspaceName.isValid(name) ? name : "workspace")
            var m = WorkspaceSetupCheck.Manager(bot: b.name, known: true, retired: false, botIsolation: b.isolation.default,
                                                keeper: b.token.keeper, deliver: b.deliver, isolation: iso.rawValue, agent: b.agent,
                                                programOnPath: nil, keychainReadable: nil, placeName: place)
            if b.isolation.default != "elsewhere" {
                if iso != .vm, let p = ManagerLaunch.program(agent: b.agent), !buildFlavor.isHelper {
                    m.programOnPath = TestSafety.stubAgent() ? true : await mac.programOnPath(p)
                }
                if WorkspaceName.isValid(name), !workspaces.exists(name) {
                    let info = await managerLauncher.info(isolation: iso, place: place)
                    m.placeTaken = info.exists && info.heldBy != b.name
                }
            }
            // The place's name follows the workspace's: it is the name step's finding, not the bot's.
            let found = WorkspaceSetupCheck.managerFindings(m, workspace: name).filter { $0.code != "placeTaken" }
            if let first = found.first {
                let (why, fix) = WorkspaceWizard.managerWords(code: first.code, bot: b.name, agent: b.agent, place: place, isolation: iso.rawValue)
                out.append(WorkspaceManagerFit(bot: b.name, fits: false, why: why,
                                               fix: fix?.action == "token" && !b.isolation.held ? nil : fix))
            } else if let live = await liveWorkspace(of: b.name, except: name) {
                out.append(WorkspaceManagerFit(bot: b.name, fits: false, why: WorkspaceWizard.liveWords(live)))
            } else {
                out.append(WorkspaceManagerFit(bot: b.name, fits: true))
            }
        }
        return out
    }

    /// The plan's refusals and gaps in the wizard's words (`input`: the set-up check's input the gaps came from).
    func workspaceFindings(_ d: WorkspaceNewDraft, gaps: [WorkspaceSetupCheck.Gap], input: WorkspaceSetupCheck.Input) async -> [WorkspaceFinding] {
        var out = d.refusals.map { WorkspaceWizard.refusal($0.message, name: d.record.name) }
        out += gaps.compactMap(WorkspaceWizard.gap)
        if let m = input.manager {
            for f in WorkspaceSetupCheck.managerFindings(m, workspace: d.record.name) {
                let (why, fix) = WorkspaceWizard.managerWords(code: f.code, bot: m.bot, agent: m.agent, place: m.placeName, isolation: m.isolation)
                out.append(WorkspaceFinding(step: f.code == "placeTaken" ? "name" : "manager", field: f.code == "placeTaken" ? "name" : "manager",
                                            text: f.code == "placeTaken" ? why : "\(m.bot): " + why.prefix(1).lowercased() + why.dropFirst(), fix: fix))
            }
            if let live = await liveWorkspace(of: m.bot, except: d.record.name) {
                out.append(WorkspaceFinding(step: "manager", field: "manager", text: "\(m.bot): " + WorkspaceWizard.liveWords(live).prefix(1).lowercased()
                                            + WorkspaceWizard.liveWords(live).dropFirst()))
            }
        }
        return WorkspaceWizard.ordered(out)
    }
}
