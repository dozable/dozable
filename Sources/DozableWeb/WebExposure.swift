import Foundation

// 606 — who may do what: the remote-capability table (606.02-PLAN.md). A closed `switch` over every `WebRoute`
// with no `default`, so a new route cannot ship without a decision (`WebExposureTests` pins the table).
//
// Owner ruling: a browser admitted to `doz serve` may do everything the Mac's dashboard does, EXCEPT typing a
// secret while the request is plain HTTP (allowed when it arrived over https through a trusted proxy). Not a
// restriction but a fact: what opens a window on the Mac's own SCREEN (its folder and file pickers, Terminal)
// is not offered to another computer. The server is the wall; the page only hides what it cannot do.

public enum WebExposure {
    /// Who is asking.
    public enum Principal: Equatable, Sendable {
        /// `doz ui` — the Mac's own browser (loopback).
        case mac
        /// A browser admitted to `doz serve`; `secure`: the request arrived over https at a trusted proxy.
        case remote(secure: Bool)

        public var isRemote: Bool { if case .remote = self { true } else { false } }
        public var name: String {
            switch self { case .mac: "mac"; case .remote(let s): s ? "remote-https" : "remote-http" }
        }
    }

    /// What a route is, for this table.
    public enum Kind: String, Sendable, CaseIterable {
        /// The page itself and the session (no data).
        case page
        /// Reads (and changes nothing).
        case read
        /// Changes: actions, terminals, settings, the wizards' writes.
        case change
        /// A key or token typed in a masked field.
        case secretEntry = "secret-entry"
        /// Opens a window on the Mac's own screen.
        case macScreen = "mac-screen"
        /// doz serve's devices and invites.
        case devices
        /// Only doz serve answers it (the doctor's probe).
        case serveOnly = "serve-only"
        /// The sessions on this Mac (`@mac`): NOT isolated — another computer gets what `serve.mac_sessions` allows.
        case macSession = "mac-session"
        /// Chat: the person's own conversations, posting as them — another computer only as `serve.chat` allows.
        case chat
        /// 714: this Mac's own browser only, whatever the settings — restarting the dashboard itself (every other browser's
        /// pages and terminals go with it).
        case macOnly = "mac-only"
    }

    /// `serve.mac_sessions`: what a remote browser may do with the sessions on this Mac.
    public enum MacSessions: String, Sendable, CaseIterable {
        /// Nothing: they are not listed, watched or typed into (the default).
        case off
        /// List them, read their saved screens, watch them (read-only terminals, painted tiles).
        case watch
        /// Everything the Mac's own browser does with them: type, end, restart.
        case interactive
    }

    /// `serve.chat`: what a remote browser may do with chat. Through the dashboard a browser acts as the person — the
    /// verified human in chat, whose words the agents act on — so it is off unless set on this Mac.
    public enum ChatServe: String, Sendable, CaseIterable {
        /// Nothing: every chat route is refused and the page has no Chat (the default).
        case off
        /// Read the rooms; every route that changes something (post, upload, react, edit, delete, reveal, typing) is refused.
        case read
        /// Everything the Mac's own browser does in chat; each change is a line in the audit log.
        case write
    }

    /// `decide` lets a remote principal reach the `mac-session` routes unless the setting is off; a ticket is decided again
    /// by its mode (`decideMacTerminal`), the end and restart actions by `decideMacAction`, `@mac` tiles in `grids` by
    /// the setting. A terminal on this Mac's session in `mode`, for `who`.
    public static func decideMacTerminal(_ mode: WebTerminalMode, _ who: Principal, _ allowed: MacSessions) -> WebRejection? {
        guard who.isRemote else { return nil }
        switch (allowed, mode) {
        case (.interactive, _), (.watch, .watch): return nil
        default: return .macSession
        }
    }

    /// Typing's kin — ending or restarting a session on this Mac — for `who`.
    public static func decideMacAction(_ who: Principal, _ allowed: MacSessions) -> WebRejection? {
        who.isRemote && allowed != .interactive ? .macSession : nil
    }

    /// A workspace's action (`workspace-brief`) for `who`: it speaks as you in the workspace's room (its announcement), so
    /// another computer only with `serve.chat = write` — as a chat write, and audited the same way. The Mac's own browser
    /// always. There is no workspace lifecycle action for any browser (start, stop, a worker, a bot): the CLI's.
    public static func decideWorkspaceAction(_ who: Principal, _ chat: ChatServe) -> WebRejection? {
        guard who.isRemote else { return nil }
        switch chat {
        case .off: return .briefRemote
        case .read: return .chatReadOnly
        case .write: return nil
        }
    }

    /// Filing an agent into a workspace or out of one (`workspace-adopt`, `-new`, `-release`) for `who`: this Mac's own browser
    /// only, whatever `serve.chat` or `serve.mac_sessions` say — what a workspace holds decides what it (and later its
    /// manager) may reach, and `workspace-new` makes a room as you. Another computer is shown the command instead.
    public static func decideFilingAction(_ who: Principal) -> WebRejection? { who.isRemote ? .macOnlyFiling : nil }

    /// A workspace started (`workspace-start`) for `who`: this Mac's own browser only, whatever `serve.chat` or
    /// `serve.mac_sessions` say — it posts the brief as you and starts a program holding a bot's token, maybe an unfenced
    /// manager that acts as you. Another computer is shown the command instead; its attempt is one audit line.
    public static func decideStartAction(_ who: Principal) -> WebRejection? { who.isRemote ? .macOnlyStart : nil }

    /// An Agent / Bot changed (`bot-new`, `-set`, `-retire`, `-adopt`, `-token`) for `who`: this Mac's own browser only, whatever
    /// `serve.chat` or `serve.mac_sessions` say — each makes, replaces or revokes a token and writes the login keychain.
    /// Another computer is shown the command instead; its attempt is one audit line.
    public static func decideBotAction(_ who: Principal) -> WebRejection? { who.isRemote ? .macOnlyBots : nil }

    /// A worker added or ended (`worker-add`, `worker-end`) for `who`: this Mac's own browser only, whatever `serve.chat` or
    /// `serve.mac_sessions` say — an add makes a participant and its token and starts a program (maybe an unfenced one acting
    /// as you), an end revokes a token. Another computer is shown the command instead; its attempt is one audit line.
    public static func decideWorkerAction(_ who: Principal) -> WebRejection? { who.isRemote ? .macOnlyWorkers : nil }

    /// A workspace's lifecycle (`workspace-stop` … `workspace-delete`) for `who`: this Mac's own browser only, whatever
    /// `serve.chat` or `serve.mac_sessions` say — each stops, starts or removes what the workspace holds, archives its rooms as
    /// you, or hands a bot's token to a program again. Another computer is shown the command instead; its attempt is one
    /// audit line. Its plan route is `mac-screen`.
    public static func decideLifecycleAction(_ who: Principal) -> WebRejection? { who.isRemote ? .macOnlyLifecycle : nil }

    /// A refused site allowed for a fenced session on this Mac (`mac-net-policy`) for `who`: this Mac's own browser only,
    /// whatever `serve.mac_sessions` or `serve.chat` say — a fenced session's network is what holds an agent that works as you
    /// on this Mac to its folder. Another computer is shown the command instead; its attempt is one audit line.
    public static func decideMacNetAction(_ who: Principal) -> WebRejection? { who.isRemote ? .macOnlyNet : nil }

    /// A space file saved (`workspace-space-save`) for `who`: this Mac's own browser only, whatever `serve.chat` or
    /// `serve.mac_sessions` say — the file decides what the next up starts, where, and with what access. Another computer
    /// reads it (with serve.chat read or write) and is shown the command instead; its attempt is one audit line.
    public static func decideSpaceAction(_ who: Principal) -> WebRejection? { who.isRemote ? .macOnlySpace : nil }

    /// A room archived or removed for good, or a run's archive written again, for `who`: this Mac's own browser only, whatever
    /// the serve settings — a room's removal cannot be undone, and its archive is written as you.
    public static func decideRoomAction(_ who: Principal) -> WebRejection? { who.isRemote ? .macOnlyRooms : nil }

    /// An ask answered from its card (`chat-decide`) for `who`: this Mac's own browser only, whatever `serve.chat` says — a
    /// decision is made as you and cannot be taken back. Another computer sees the card read-only.
    public static func decideAskAction(_ who: Principal) -> WebRejection? { who.isRemote ? .macOnlyAsks : nil }

    /// Chat turned on (`chat-on`) for `who`: this Mac's own browser only — it starts a server that listens. Another computer
    /// sees the terminal's command instead.
    public static func decideChatOnAction(_ who: Principal) -> WebRejection? { who.isRemote ? .macOnlyChatOn : nil }

    /// A workspace's room made (`workspace-make-room`) for `who`: this Mac's own browser only — the room is made as you.
    public static func decideMakeRoomAction(_ who: Principal) -> WebRejection? { who.isRemote ? .macOnlyMakeRoom : nil }

    /// An ended or gone session on this Mac removed (`mac-session-forget`, `mac-sessions-forget-ended`) for `who`: this Mac's
    /// own browser only, whatever `serve.mac_sessions` says (watch or interactive) — a forgotten session can no longer be
    /// restarted. Another computer is shown the command instead; its attempt is one audit line.
    public static func decideMacForgetAction(_ who: Principal) -> WebRejection? { who.isRemote ? .macOnlySessions : nil }

    /// 683 M5: a conversation exported (its whole text) — another computer only with `serve.mac_sessions = interactive`
    /// (watching shows screens, never a session's history).
    public static func decideMacExport(_ who: Principal, _ allowed: MacSessions) -> WebRejection? { decideMacAction(who, allowed) }

    public static func kind(_ route: WebRoute) -> Kind {
        switch route {
        case .index, .asset, .terminalFrame, .offline, .serviceWorker, .chatPage, .sessionBootstrap, .sessionInfo, .sessionRenew, .sessionEnd:
            return .page
        case .overview, .sandbox, .sandboxSessions, .sandboxNetwork, .sandboxTools, .images, .imageTree, .accounts, .metrics,
             .metricsCSV, .events, .doctor, .stream, .operations, .settings, .sessionScreen, .terminalLayout, .bootLogs, .bootLog, .buildLog,
             .onboarding, .preparations, .resources, .bases, .access, .tryCatalog, .tryList, .models, .files, .filesWatch, .filesTree,
             .grids,                    // 648: a read (POST only because it carries the pictures asked)
             .recipes,                  // 669: Settings › Recipes — states and settings, read from the store
             .workspaces, .workspace, .loose, .bots,  // reads; the rows on this Mac follow serve.mac_sessions (WebWorkspaceReads)
             .botsRetired, .bot,        // Agents / Bots: read only everywhere; a bot's inbox session follows serve.mac_sessions (WebBotReads)
             .workspaceLog,             // the log's lines about this Mac's sessions follow serve.mac_sessions too
             .workspaceBrief,           // the brief's text: another computer only with serve.chat read or write (`decide`)
             .workspaceRuns,            // a workspace's runs: their windows, archives' status and totals (no message, no file)
             .workspaceRunChat,         // a run's archived messages: another computer only as serve.chat lets it read (`decide`)
             .workspaceSpace, .workspaceSpacePlan,  // a space file's text and its plan: another computer only with serve.chat
                                        // read or write (`decide`) — the file is what the agents are set up from
             .workspaceState,           // a space's state: this Mac's sessions as serve.mac_sessions allows (SpaceStateViewer)
             .workspaceRunFrames,       // a space's run in frames: the same projection, frame by frame; never a message
             .workspaceReach, .workspaceFolders, .workspaceActivity,  // the wide views: projections — this Mac's sessions follow
                                        // serve.mac_sessions, held secrets a count only (WebWorkspaceReach.forBrowser)
             .macs:                     // Your Macs — another computer sees the same list (a phone switching Macs is its main use)
            return .read
        case .actions, .operationsCancel, .policyPreview, .terminalTicket,     // 650: a cancel is decided as the actions are
             .terminalSocket, .settingsChange, .terminalLayoutSet, .filesTreeSet, .onboardingConfig,
             .workspaceCheck, .quickAdd, .plan, .projectOpen, .projectPreview, .projectWrite, .resourcesPreview, .accessCheck, .signup, .updatesCheck,
             .dotfilesResolve:          // 657: fetches on the Mac (starts the host) — a change, like accessCheck
            return .change
        case .accountAdd, .sandboxKey, .accessGithubKey:
            return .secretEntry
        case .terminal, .workspaceChoose, .projectsDirChoose, .dockerfileChoose, .filesOpen, .editors,   // 646: editors with files/open
             .portOpen,                 // 666: opens this Mac's browser (signed in) — another computer's 127.0.0.1 is its own
             .macSessionPlan,           // 683 M5: the New session wizard — its command is for this Mac's own terminal (and
                                        // Open in Terminal opens a window here): another computer never gets the route
             .workspacePlan,            // the New workspace wizard's plan — it shows this Mac's folders and bots, and a
                                        // workspace is made only from this Mac: another computer never gets the route
             .workerPlan,               // the Add a worker page's plan — it shows this Mac's bots, sessions and folders, and a
                                        // worker is added only from this Mac: another computer never gets the route
             .chatRoomPlan,             // a room's archive or removal looked at — the actions are this Mac's own browser's
             .workspaceLifecyclePlan:   // a lifecycle verb's plan — this Mac's agents, sessions and folders; the verbs are this
                                        // Mac's own browser's: another computer never gets the route
            return .macScreen
        case .serveStatus, .serveDevices, .serveShare, .serveRevoke, .serveRename:
            return .devices
        case .serveProbe:
            return .serveOnly
        case .macSessions, .macSessionScreen, .macTerminalTicket, .macTerminalSocket,
             .macSessionNetwork, .macSessionQuarantine, .macSessionTranscripts,
             .macSessionTranscript:     // 683 M5: a conversation's text — for another computer only with `interactive` (decideMacExport)
            return .macSession
        case .chat:
            return .chat
        case .uiRestart:
            return .macOnly
        }
    }

    /// nil: allowed; else the refusal (its message says why and what to do instead). `macSessions`: the setting
    /// `serve.mac_sessions` (only a remote principal is affected; the Mac's own browser always has them).
    public static func decide(_ route: WebRoute, _ who: Principal, macSessions: MacSessions = .off, chat: ChatServe = .off) -> WebRejection? {
        if case .chat(let c) = route, who.isRemote { return decideChat(c, who, chat) }
        // A workspace's brief is what its agents act on, as chat is: another computer reads it only as serve.chat allows.
        if case .workspaceBrief = route, who.isRemote, chat == .off { return .briefRemote }
        // A run's archived messages are chat: another computer reads them only as serve.chat allows.
        if case .workspaceRunChat = route, who.isRemote, chat == .off { return .chatRemote }
        // A space file is what its agents are set up from, as the brief is: another computer reads it (and plans it) only as
        // serve.chat allows. Saving it is this Mac's own browser's only (`decideSpaceAction`).
        if route == .workspaceSpace || route == .workspaceSpacePlan, who.isRemote, chat == .off { return .spaceRemote }
        switch (kind(route), who) {
        case (.secretEntry, .remote(secure: false)): return .secretOverHTTP
        case (.macScreen, .remote): return .macScreen
        case (.serveOnly, .mac): return .notFound
        case (.macSession, .remote): return macSessions == .off ? .macSession : nil
        case (.chat, .remote): return .chatRemote                      // decided above (decideChat)
        case (.macOnly, .remote): return .macOnly
        case (.page, _), (.read, _), (.change, _), (.secretEntry, _), (.macScreen, .mac), (.devices, _), (.serveOnly, .remote), (.macSession, .mac), (.chat, .mac), (.macOnly, .mac):
            return nil
        }
    }

    /// A chat route for `who` under `serve.chat`: the Mac's own browser always; another computer nothing while off, the
    /// routes that change nothing with read, everything with write.
    public static func decideChat(_ route: WebChatRoute, _ who: Principal, _ allowed: ChatServe) -> WebRejection? {
        guard who.isRemote else { return nil }
        switch allowed {
        case .off: return .chatRemote
        case .read: return route.isSafe ? nil : .chatReadOnly
        case .write: return nil
        }
    }
}
