import DozableHost
import DozableKit
import Foundation

// The sessions on THIS Mac (`@mac`) in the dashboard — their typed routes (`WebRoute.macSessions`, `macSessionScreen`,
// `macTerminalTicket`, `macTerminalSocket`), their projections, and the rules a remote browser is held to
// (`WebExposure`: `serve.mac_sessions`). Nothing here opens a session: the page lists, watches, types into (on a click),
// ends and restarts the ones `doz run @mac` opened.

/// One session on this Mac, as the page shows it. Its text (the command, the folder) is the person's own, shown as text.
public struct WebMacSession: Codable, Equatable, Sendable {
    public var name: String
    /// running | ended | gone (its holder is gone: the Mac restarted, or it was killed — its saved screen is what is left).
    public var state: String
    public var pid: Int?
    public var cols: UInt16?
    public var rows: UInt16?
    public var clients: Int
    public var exitCode: Int32?
    public var command: String
    /// The folder it runs in (absolute; the page shows it with `~`).
    public var workdir: String?
    public var openedAt: Date?
    /// Its own command line asked for its permissions to be bypassed (never Dozable): marked on its tile and pane.
    public var bypassed: Bool
    public var status: WebAgentStatus?

    public init(_ s: SessionRow) {
        name = s.name
        state = s.gone == true ? "gone" : s.ended ? "ended" : "running"
        pid = s.pid
        cols = s.cols
        rows = s.rows
        clients = s.clients
        exitCode = s.exitCode
        command = String(s.command.prefix(1024))
        workdir = s.workdir
        openedAt = s.openedAt
        bypassed = s.bypassed == true
        status = s.status.map(WebAgentStatus.init)
    }
}

/// `GET /api/v1/mac/sessions`.
public struct WebMacSessions: Codable, Equatable, Sendable {
    /// Always false — said in the answer itself, so no client can take these for sandboxes.
    public var isolated = false
    public var sessions: [WebMacSession]
    /// What this browser may do with them: `interactive` | `watch` (a remote browser under `serve.mac_sessions`).
    public var access: String

    public init(sessions: [WebMacSession], access: String) {
        self.sessions = sessions
        self.access = access
    }
}

/// The body of `POST /api/v1/mac/terminal-ticket`, decoded STRICTLY: a session must be named (there is no "own" session
/// on the Mac to open), and the mode is interactive or watch (no console: the Mac has no boot).
public enum WebMacTicket {
    public static func decode(_ body: Data) throws -> WebTerminalTicketRequest {
        let r = try WebTerminalTicketRequest.decode(body)
        guard r.mode != .console else { throw WebAction.Invalid("mode: interactive or watch") }
        guard let s = r.session, WebRoute.isMacSessionName(s) else {
            throw WebAction.Invalid("session: a session on this Mac — 1–32 of letters, digits . _ - (not starting with .)")
        }
        guard !r.quiet else { throw WebAction.Invalid("quiet: not for a session on this Mac") }
        return r
    }
}

extension WebGridsRequest {
    /// `@mac` tiles are the sessions on this Mac: a remote browser gets them only when `serve.mac_sessions` allows watching.
    static func macAllowed(_ who: WebExposure.Principal, _ allowed: WebExposure.MacSessions) -> Bool {
        !who.isRemote || allowed != .off
    }
}
