import DozableHost
import DozableKit
import Foundation

/// The dashboard's Agents / Bots reads: three typed GET routes, each EXACTLY ONE read-only HostOp the CLI also sends —
/// `GET /api/v1/bots` (`doz bot ls`), `GET /api/v1/bots?retired=1` (`doz bot ls --retired`) and `GET /api/v1/bots/{name}`
/// (`doz bot show NAME --instructions`) — answered in-process when no daemon runs (looking never starts one). Nothing here
/// changes a bot, and nothing here ever carries a token: the projections hold who keeps it and its fingerprint only
/// (`WebBotDetail`). `WebWorkspaceReads.request(for:)` hands the bot routes here; `WebBotsTests` pins both.
public enum WebBotReads {
    /// The request a bot read route sends (nil: not one of these routes).
    public static func request(for route: WebRoute) -> HostRequest? {
        var r = HostRequest(.botList)
        switch route {
        case .bots:
            r.botRequest = BotRequest()
        case .botsRetired:
            var b = BotRequest()
            b.retired = true
            r.botRequest = b
        case .bot(let name):
            var b = BotRequest(name: name)
            b.withInstructions = true
            r = HostRequest(.botShow)
            r.botRequest = b
        default:
            return nil
        }
        return r
    }

    /// A bot's name in the address, checked by the chat name rule before any call; the refusal never echoes it.
    public static func checkName(_ n: String) throws {
        guard ChatNames.refusal(n) == nil else {
            throw WebAction.Invalid("bot: its name — a lower-case letter, then lower-case letters, digits and -")
        }
    }

    /// A bot for a browser that may not see the sessions on this Mac (`macAllowed` false: another computer while
    /// `serve.mac_sessions` is off): the inbox session's name (a session on this Mac) and every note naming one are left out.
    public static func forBrowser(_ d: WebBotDetail, macAllowed: Bool) -> WebBotDetail {
        guard !macAllowed else { return d }
        var out = d
        out.session = nil
        out.notes = d.notes.filter { n in !n.contains(MacPlace.name) && !(d.session.map { n.contains($0) } ?? false) && !n.contains("session") }
        return out
    }
}
