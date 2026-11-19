import Foundation

/// The set-up check `doz workspace start` runs before anything is posted or started: a workspace starts only once it is
/// fully set up. ONE pure function (`gaps`), fed what the daemon read (`HostCore.workspaceSetupInput`); every gap carries
/// the command that fixes it, and every gap is returned at once. A bot that already runs in another live workspace is a
/// refusal of its own (`liveElsewhereRefusal`) — for now a bot runs in one live workspace at a time.
/// `WorkspaceSetupCheckTests`; `docs/engineering/workspaces.md` ("The manager").
public enum WorkspaceSetupCheck {
    /// One thing missing: what it is about (`brief`, `chat`, `room`, `folder`, `agent`, `manager`), why, and the fix.
    public struct Gap: Codable, Equatable, Sendable {
        public var item: String
        public var why: String
        public var fix: String
        public init(item: String, why: String, fix: String) { self.item = item; self.why = why; self.fix = fix }
        /// As a person reads it: "the brief is empty — doz workspace edit W --prompt-file F".
        public var line: String { why + " — " + fix }
    }

    public enum Chat: Equatable, Sendable {
        case off
        case notReady(String)
        case ready
    }

    /// One of the workspace's folders, and whether it is there.
    public struct Folder: Equatable, Sendable {
        public var path: String
        public var exists: Bool
        public init(path: String, exists: Bool) { self.path = path; self.exists = exists }
    }

    /// An adopted agent (not the manager): its name, its place as typed, its kind (`sandbox` or `session`), whether it is there.
    public struct Agent: Equatable, Sendable {
        public var name: String
        public var place: String
        public var kind: String
        public var exists: Bool
        public init(name: String, place: String, kind: String, exists: Bool) {
            self.name = name; self.place = place; self.kind = kind; self.exists = exists
        }
    }

    /// The manager as the daemon found it.
    public struct Manager: Equatable, Sendable {
        public var bot: String
        /// It is in `bots.json`.
        public var known: Bool
        public var retired: Bool
        /// The bot's own default isolation (`elsewhere` is never started).
        public var botIsolation: String
        /// Where its token is: `dozable`, `elsewhere` or `none`.
        public var keeper: String
        /// `poll`, `inbox` or `webhook`.
        public var deliver: String
        /// The isolation it is started in: `fenced`, `vm` or `unfenced`.
        public var isolation: String
        /// Its agent program as recorded (`claude-code`, `codex`, …).
        public var agent: String
        /// The program is on this Mac's sessions' PATH (nil: not looked — a VM manager).
        public var programOnPath: Bool?
        /// Its token can be read from the keychain item, and it is the one recorded (its fingerprint).
        public var keychainReadable: Bool
        /// The session's (or sandbox's) name, and whether something else of that name exists already.
        public var placeName: String
        public var placeTaken: Bool
        public init(bot: String, known: Bool = true, retired: Bool = false, botIsolation: String = "fenced", keeper: String = "dozable",
                    deliver: String = "poll", isolation: String = "fenced", agent: String = "claude-code", programOnPath: Bool? = true,
                    keychainReadable: Bool = true, placeName: String, placeTaken: Bool = false) {
            self.bot = bot; self.known = known; self.retired = retired; self.botIsolation = botIsolation; self.keeper = keeper
            self.deliver = deliver; self.isolation = isolation; self.agent = agent; self.programOnPath = programOnPath
            self.keychainReadable = keychainReadable; self.placeName = placeName; self.placeTaken = placeTaken
        }
    }

    public struct Input: Equatable, Sendable {
        public var workspace: String
        /// The brief's text as read now (0: empty or missing).
        public var briefBytes: Int
        public var chat: Chat
        /// The main room recorded (nil: none), and whether the chat server has it (read only while chat is ready).
        public var mainRoom: String?
        public var mainRoomExists: Bool
        public var folders: [Folder]
        public var agents: [Agent]
        public var manager: Manager?
        public init(workspace: String, briefBytes: Int, chat: Chat, mainRoom: String?, mainRoomExists: Bool, folders: [Folder] = [],
                    agents: [Agent] = [], manager: Manager? = nil) {
            self.workspace = workspace; self.briefBytes = briefBytes; self.chat = chat; self.mainRoom = mainRoom
            self.mainRoomExists = mainRoomExists; self.folders = folders; self.agents = agents; self.manager = manager
        }
    }

    /// Everything missing, in the order a person fixes it (empty: ready to start).
    public static func gaps(_ i: Input) -> [Gap] {
        let w = i.workspace
        var out: [Gap] = []
        if i.briefBytes == 0 {
            out.append(Gap(item: "brief", why: "the brief is empty", fix: "doz workspace edit \(w) --prompt-file F"))
        }
        switch i.chat {
        case .off:
            if i.manager != nil { out.append(Gap(item: "chat", why: "a manager needs chat", fix: "doz chat on")) }
        case .notReady(let why):
            out.append(Gap(item: "chat", why: "chat is on but its server is not ready (\(why))", fix: "doz chat status"))
        case .ready:
            if let r = i.mainRoom {
                if !i.mainRoomExists { out.append(Gap(item: "room", why: "the room \(r) is gone from the chat server", fix: "doz chat room \(r), then start again")) }
            } else {
                out.append(Gap(item: "room", why: "no main room", fix: "doz workspace edit \(w) --make-room"))
            }
        }
        for f in i.folders where !f.exists {
            let p = DisplayPath.tilde(f.path)
            out.append(Gap(item: "folder", why: "folder \(p) is gone", fix: "doz workspace edit \(w) --remove-folder \(p)"))
        }
        for a in i.agents where !a.exists {
            out.append(Gap(item: "agent", why: "agent \(a.name): \(a.kind) \(a.place) is gone", fix: "doz workspace release \(w) \(a.name)"))
        }
        if let m = i.manager { out += managerGaps(m, workspace: w) }
        return out
    }

    static func managerGaps(_ m: Manager, workspace w: String) -> [Gap] {
        let b = m.bot
        guard m.known else {
            return [Gap(item: "manager", why: "\(b) is not a bot", fix: "doz workspace edit \(w) --manager BOT (doz bot ls)")]
        }
        guard !m.retired else {
            return [Gap(item: "manager", why: "\(b) was retired", fix: "doz workspace edit \(w) --manager BOT, or --no-manager")]
        }
        guard m.botIsolation != "elsewhere" else {
            return [Gap(item: "manager", why: "a bot elsewhere runs on its own machine; Dozable never starts it", fix: "doz workspace edit \(w) --no-manager")]
        }
        var out: [Gap] = []
        if m.keeper != "dozable" {
            out.append(Gap(item: "manager", why: "\(b)'s token is not held by Dozable", fix: "doz bot token \(b) --new"))
        } else if !m.keychainReadable {
            out.append(Gap(item: "manager", why: "\(b)'s token cannot be read from the login keychain (locked, or changed underneath)",
                           fix: "unlock it, or doz bot token \(b) --new"))
        }
        switch m.deliver {
        case "inbox" where m.isolation != "unfenced":
            out.append(Gap(item: "manager", why: "\(b) is reached by inbox, which only an unfenced session gets; a fenced or VM manager polls",
                           fix: "doz bot set \(b) --deliver poll"))
        case "webhook":
            out.append(Gap(item: "manager", why: "\(b) is reached by webhook; a manager Dozable starts collects its own messages",
                           fix: "doz bot set \(b) --deliver poll"))
        default:
            break
        }
        if let p = ManagerLaunch.program(agent: m.agent) {
            if m.programOnPath == false {
                out.append(Gap(item: "manager", why: "\(p) is not on this Mac's PATH", fix: "install it, or doz workspace edit \(w) --manager \(b) --manager-isolation vm"))
            }
        } else {
            out.append(Gap(item: "manager", why: "Dozable does not start a manager running \(m.agent) yet",
                           fix: "make a Claude Code or Codex bot its manager: doz workspace edit \(w) --manager BOT"))
        }
        if m.placeTaken {
            if m.isolation == "vm" {
                out.append(Gap(item: "manager", why: "a sandbox called \(m.placeName) already exists", fix: "doz rm \(m.placeName), or rename the workspace"))
            } else {
                out.append(Gap(item: "manager", why: "a session called \(m.placeName) already exists on this Mac",
                               fix: "doz sessions end @mac \(m.placeName), or rename the workspace"))
            }
        }
        return out
    }

    // MARK: one live workspace per bot

    /// Another workspace's entry for a bot: whether it runs now, and its role there (`manager` or `worker`).
    public struct Entry: Equatable, Sendable {
        public var workspace: String
        public var bot: String?
        public var running: Bool
        public var role: String
        public init(workspace: String, bot: String?, running: Bool, role: String = "manager") {
            self.workspace = workspace; self.bot = bot; self.running = running; self.role = role
        }
    }

    /// The live workspace `bot` already runs in, other than `workspace` (nil: none). Live: another workspace's entry for that
    /// bot is running (a worker not ended counts as running), or its start is under way (`starting`). Being in another
    /// workspace's room, or an entry that does not run, does not count.
    public static func liveElsewhere(bot: String, workspace: String, entries: [Entry], starting: Set<String>) -> String? {
        liveElsewhereEntry(bot: bot, workspace: workspace, entries: entries, starting: starting)?.workspace
    }

    /// The same, with the bot's role there.
    public static func liveElsewhereEntry(bot: String, workspace: String, entries: [Entry], starting: Set<String>) -> Entry? {
        entries.filter { $0.workspace != workspace && $0.bot == bot && ($0.running || starting.contains($0.workspace)) }
            .sorted { $0.workspace < $1.workspace }.first
    }

    public static func liveElsewhereRefusal(bot: String, other: String) -> String {
        "\(bot) already manages \(other), which is running. For now a bot runs in one live workspace at a time — doz workspace stop \(other) first."
    }

    /// The refusal for `bot` live in `e` — as its manager, or as a worker.
    public static func liveElsewhereRefusal(bot: String, _ e: Entry) -> String {
        guard e.role == "worker" else { return liveElsewhereRefusal(bot: bot, other: e.workspace) }
        return "\(bot) already works in \(e.workspace), which is running. For now a bot runs in one live workspace at a time — doz worker end \(e.workspace) \(bot) first."
    }
}
