import Foundation

// 771: an agent's journal and work-description calls — Dozable's own routes on the page port, beside the protocol's
// /agent/* (never in the conformance gate's set): GET and POST /agent/journal, GET /agent/journal/wait, POST /agent/proposals,
// POST /agent/proposals/{id}/decide, POST /agent/addenda. Each is authenticated by the agent's own token exactly as /agent/send
// is (`Authorization: Bearer`; the human's token is refused); the server then RELAYS the call to the daemon that runs it
// (`ChatServeOptions.relay`, set only when the daemon supervises this server and named its socket), naming the participant
// the token belongs to — the only name the daemon takes. With no relay (the conformance runner's server, a server run by
// hand) they answer 501. docs/engineering/chat.md, "Dozable's agent routes".

/// One call to relay: who the token proved, which call, and what it carries.
public struct ChatAgentRelayCall: Sendable, Equatable {
    public var participant: String
    /// `journal`, `journal-add`, `journal-wait`, `propose`, `decide`, `addendum`.
    public var route: String
    public var query: [String: String]
    /// A POST's JSON body as sent (empty: none).
    public var body: [UInt8]
    /// `decide`: the proposal's id from the path.
    public var id: String?

    public init(participant: String, route: String, query: [String: String] = [:], body: [UInt8] = [], id: String? = nil) {
        self.participant = participant; self.route = route; self.query = query; self.body = body; self.id = id
    }
}

/// The relay: given by whoever runs the server (the CLI's `doz chat serve --daemon-socket`), answers the HTTP answer.
public typealias ChatAgentRelay = @Sendable (ChatAgentRelayCall) async -> ChatHTTPResponse

/// A relayed call the listener finishes (like a receive that waits): the answer comes from the daemon.
public final class ChatRelayPending: @unchecked Sendable {
    let call: ChatAgentRelayCall
    let relay: ChatAgentRelay
    init(call: ChatAgentRelayCall, relay: @escaping ChatAgentRelay) { self.call = call; self.relay = relay }
    public func finish() async -> ChatHTTPResponse { await relay(call) }
}

extension ChatPageHandler {
    /// The query parameters a relayed call passes on (anything else is not sent).
    static let relayQuery = ["run", "kind", "after", "timeout", "workspace"]

    /// The routes' names → the relay's call.
    static let relayRoutes = ["journal-read": "journal", "journal-add": "journal-add", "journal-wait": "journal-wait",
                              "proposal-make": "propose", "proposal-decide": "decide", "addendum-add": "addendum"]

    func agentRelay(_ name: String, _ vars: [String: String], _ r: ChatHTTPRequest) -> ChatHTTPResponse {
        let token = Self.bearerToken(r)
        guard let caller = core.whoHolds(token) else { return .jsonError(401, Self.needBearer) }
        // From another machine the human's token is no one's (as on /agent/send); on this Mac the human never comes this way
        // either: the owner reaches the journal with doz, never gated.
        if r.caller == .remote && core.isHuman(caller) { return .jsonError(401, Self.needBearer) }
        if core.isHuman(caller) { return .jsonError(403, "the human's token is not an agent's: the owner uses doz workspace journal") }
        guard let route = Self.relayRoutes[name] else { return .jsonError(404, "404 page not found") }
        guard let relay = core.agentRelay else {
            return .jsonError(501, "this call is Dozable's own: it needs the chat server Dozable's daemon runs")
        }
        if r.truncated { return .jsonError(413, "the request is too large") }
        var query: [String: String] = [:]
        for k in Self.relayQuery { let v = r.query(k); if !v.isEmpty { query[k] = v } }
        core.heard(caller, answered: false)
        var res = ChatHTTPResponse(status: 200, headers: [], body: [])
        res.relay = ChatRelayPending(call: ChatAgentRelayCall(participant: caller, route: route, query: query,
                                                              body: r.method == "POST" ? r.body : [], id: vars["id"]), relay: relay)
        return res
    }
}
