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

    public static func kind(_ route: WebRoute) -> Kind {
        switch route {
        case .index, .asset, .terminalFrame, .offline, .serviceWorker, .sessionBootstrap, .sessionInfo, .sessionRenew, .sessionEnd:
            return .page
        case .overview, .sandbox, .sandboxSessions, .sandboxNetwork, .sandboxTools, .images, .imageTree, .accounts, .metrics,
             .metricsCSV, .events, .doctor, .stream, .operations, .settings, .sessionScreen, .terminalLayout, .bootLogs, .bootLog, .buildLog,
             .onboarding, .preparations, .resources, .bases, .access, .tryCatalog, .tryList, .models, .files, .filesWatch, .filesTree,
             .grids,                    // 648: a read (POST only because it carries the pictures asked)
             .recipes:                  // 669: Settings › Recipes — states and settings, read from the store
            return .read
        case .actions, .operationsCancel, .policyPreview, .terminalTicket,     // 650: a cancel is decided as the actions are
             .terminalSocket, .settingsChange, .terminalLayoutSet, .filesTreeSet, .onboardingConfig,
             .workspaceCheck, .quickAdd, .plan, .projectOpen, .projectPreview, .projectWrite, .resourcesPreview, .accessCheck, .signup, .updatesCheck,
             .dotfilesResolve:          // 657: fetches on the Mac (starts the host) — a change, like accessCheck
            return .change
        case .accountAdd, .sandboxKey, .accessGithubKey:
            return .secretEntry
        case .terminal, .workspaceChoose, .projectsDirChoose, .dockerfileChoose, .filesOpen, .editors,   // 646: editors with files/open
             .portOpen:                 // 666: opens this Mac's browser (signed in) — another computer's 127.0.0.1 is its own
            return .macScreen
        case .serveStatus, .serveDevices, .serveShare, .serveRevoke, .serveRename:
            return .devices
        case .serveProbe:
            return .serveOnly
        case .macSessions, .macSessionScreen, .macTerminalTicket, .macTerminalSocket:
            return .macSession
        }
    }

    /// nil: allowed; else the refusal (its message says why and what to do instead). `macSessions`: the setting
    /// `serve.mac_sessions` (only a remote principal is affected; the Mac's own browser always has them).
    public static func decide(_ route: WebRoute, _ who: Principal, macSessions: MacSessions = .off) -> WebRejection? {
        switch (kind(route), who) {
        case (.secretEntry, .remote(secure: false)): return .secretOverHTTP
        case (.macScreen, .remote): return .macScreen
        case (.serveOnly, .mac): return .notFound
        case (.macSession, .remote): return macSessions == .off ? .macSession : nil
        case (.page, _), (.read, _), (.change, _), (.secretEntry, _), (.macScreen, .mac), (.devices, _), (.serveOnly, .remote), (.macSession, .mac):
            return nil
        }
    }
}
