import Darwin
import Foundation

// 771: an agent reaches the run journal and the work description itself — through the chat server, with its own chat token
// (dozchat journal …, dozchat propose, dozchat proposal decide, dozchat addendum). The chat server authenticates the token,
// names the participant that holds it and relays the call to the daemon (`agent-relay`, on the daemon's own socket); the
// daemon maps the participant to the workspace identity it is and decides with the SAME gate as `--as W/AGENT`. The shapes
// and the pure parts are here; the daemon's side is `HostCore+AgentRelay.swift`. docs/engineering/journal.md, "Agents' own
// access", and workspaces.md, "The agent relay".
//
// The trust argument. The daemon's socket is the owner's alone (0600 in the store, this user's): whatever connects to it can
// already do anything the owner can, so a relay that names a participant cannot widen anything — it is a NARROWING, like
// `--as`, and every answer comes from the agent's own grants. On top of that the daemon accepts `agent-relay` only from the
// process it supervises as its chat server (the connection's peer pid, LOCAL_PEERPID, equals the pid of the chat server it
// spawned and has not reaped: that pid cannot be reused while the daemon has not reaped it), so a participant's name comes
// only from the chat server's own token check — never from a field an agent sets. Every other caller is refused (9).

/// `agent-relay`'s request: who the chat server authenticated, and the call.
public struct AgentRelayRequest: Codable, Equatable, Sendable {
    /// The participant whose token the chat server checked (never a name from the request's body).
    public var participant: String
    /// `journal` (GET /agent/journal), `journal-add` (POST /agent/journal), `journal-wait` (GET /agent/journal/wait),
    /// `propose` (POST /agent/proposals), `decide` (POST /agent/proposals/{id}/decide), `addendum` (POST /agent/addenda).
    public var route: String
    /// The query's parameters (`run`, `kind`, `after`, `timeout`, `workspace`).
    public var query: [String: String]?
    /// The JSON body as sent (a POST's).
    public var body: JSONValue?
    /// `decide`: the proposal's id from the path.
    public var id: String?

    public init(participant: String, route: String, query: [String: String]? = nil, body: JSONValue? = nil, id: String? = nil) {
        self.participant = participant; self.route = route; self.query = query; self.body = body; self.id = id
    }

    public static let routes = ["journal", "journal-add", "journal-wait", "propose", "decide", "addendum"]
}

/// `agent-relay`'s answer: the operation's own result, or its refusal in doz's words (code, exit, and the permission an
/// agent lacked). The relay itself always answers this — the chat server turns it into the HTTP answer.
public struct AgentRelayAnswer: Codable, Equatable, Sendable {
    public struct Failure: Codable, Equatable, Sendable {
        public var code: String
        public var message: String
        public var exit: Int32
        /// The permission the agent's request needed and was refused (not-permitted only).
        public var permission: String?
        public init(code: String, message: String, exit: Int32, permission: String? = nil) {
            self.code = code; self.message = message; self.exit = exit; self.permission = permission
        }
    }
    public var ok: Bool
    public var result: JSONValue?
    public var error: Failure?

    public static func success(_ v: JSONValue) -> AgentRelayAnswer { AgentRelayAnswer(ok: true, result: v, error: nil) }
    public static func failure(_ e: HostError, permission: String? = nil) -> AgentRelayAnswer {
        AgentRelayAnswer(ok: false, result: nil, error: Failure(code: e.code.rawValue, message: e.message, exit: ExitCodes.exit(for: e), permission: permission))
    }

    /// The HTTP status the chat server answers with, chosen so dozchat keeps its ONE exit-code table (0 done, 1 local, 2
    /// usage, 3 refused = 422, 4 = 401/403/409, 5 no answer or 5xx; 124 a wait's timeout): not-permitted → 403 and a decided
    /// proposal → 409 (exit 4); a closed or missing run, a value refused (a reserved kind, a bad correction, a file outside the
    /// folders), anything not possible now, not found or limited → 422 (exit 3); a timeout → 408 (dozchat's 124); the daemon
    /// away → 503 (exit 5). The chat server's body is `{"error":{code, message, permission?}}` — `code` carries the reason (a refused value: `invalid`).
    public var httpStatus: Int {
        guard !ok else { return 200 }
        if error?.code == HostError.Code.notPermitted.rawValue { return 403 }
        if error?.code == HostError.Code.proposalDecided.rawValue { return 409 }
        switch error?.exit ?? ExitCodes.failed {
        case ExitCodes.notPermitted: return 403
        case ExitCodes.notPossibleNow, ExitCodes.notFound, ExitCodes.invalid, ExitCodes.usage, ExitCodes.limited, ExitCodes.alreadyExists: return 422
        case ExitCodes.timedOut: return 408
        case ExitCodes.daemonUnavailable: return 503
        default: return 500
        }
    }
}

/// The body of a POST, strictly read: only the fields of its route (an unknown one is 65).
public struct AgentRelayBody: Decodable, Sendable {
    public init() {}
    var kind: String?
    var text: String?
    var data: JSONValue?
    var refs: [String]?
    var supersedes: Int?
    var attach: [String]?
    var attachRef: [String]?
    var addendum: String?
    var run: String?
    var decision: String?
    var workspace: String?

    static let fields: [String: Set<String>] = [
        "journal-add": ["kind", "text", "data", "refs", "supersedes", "attach", "attachRef", "workspace"],
        "propose": ["addendum", "run", "workspace"],
        "decide": ["decision", "workspace"],
        "addendum": ["addendum", "run", "workspace"],
    ]
}

public enum AgentRelay {
    /// The longest a `journal-wait` call holds the connection; dozchat calls again until its own `--timeout`.
    public static let maximumWaitSeconds = 25

    /// Who a participant is in a workspace: the identity's workspace and name. A manager or worker is its participant (its
    /// bot's name, or the daemon-made participant of its name); an adopted agent only through the participant made at its
    /// adoption (`WorkspaceAgent.participant`). Not ended, not still being added. `workspace` narrows it to one. None →
    /// not-permitted (9): the chat server's token check proves who it is, and that is no identity Dozable gives anything to.
    /// Several (a bot that is an agent of more than one) → 65: name the workspace.
    public static func identity(participant: String, workspace: String?, records: [WorkspaceRecord]) throws -> (workspace: String, name: String) {
        var found: [(String, String, Bool)] = []
        for rec in records where workspace == nil || rec.name == workspace {
            for a in rec.agents where a.endedAt == nil && a.pendingAt == nil {
                let mine = (a.isManager || a.isWorker) ? (a.name == participant || a.bot == participant) : a.participant == participant
                if mine { found.append((rec.name, a.name, rec.flags.archivedAt == nil)) }
            }
        }
        if found.isEmpty {
            throw HostError(.notPermitted, "\(participant) is no identity of \(workspace ?? "any workspace"): only a workspace's manager, its workers and the agents adopted into it reach its journal")
        }
        if found.count == 1 { return (found[0].0, found[0].1) }
        let live = found.filter(\.2)
        if live.count == 1 { return (live[0].0, live[0].1) }
        throw HostError(.invalidValue, "\(participant) is an agent of several workspaces (\(found.map(\.0).sorted().joined(separator: ", "))) — name the workspace with dozchat … --in W")
    }

    /// The workspace the call names (its query's or body's `workspace`), checked; nil: none named.
    static func namedWorkspace(_ r: AgentRelayRequest, _ body: AgentRelayBody?) throws -> String? {
        guard let w = r.query?["workspace"] ?? body?.workspace, !w.isEmpty else { return nil }
        guard WorkspaceName.isValid(w) else { throw HostError(.invalidValue, "\(w.prefix(60)) is not a workspace's name") }
        return w
    }

    /// A POST's body, strictly: an object whose fields are its route's (none: an empty object).
    static func body(_ r: AgentRelayRequest) throws -> AgentRelayBody? {
        guard let allowed = AgentRelayBody.fields[r.route] else { return nil }
        guard let v = r.body, case .object(let o) = v else {
            if r.body == nil || r.body == .null { return AgentRelayBody() }
            throw HostError(.invalidValue, "send a JSON object")
        }
        if let bad = o.keys.sorted().first(where: { !allowed.contains($0) }) {
            throw HostError(.invalidValue, "\(bad.prefix(40)) is not a field of this call (\(allowed.sorted().joined(separator: ", ")))")
        }
        do { return try JSONDecoder().decode(AgentRelayBody.self, from: try HostWire.encoder.encode(v)) } catch {
            throw HostError(.invalidValue, "the body does not read: a field has the wrong type")
        }
    }

    /// The operation the call is, made as the identity would make it with `--as W/NAME` — the request the gate decides and the
    /// daemon serves. `attach` here are the paths as the agent's place sees them (mapped by the daemon before this).
    public static func request(_ r: AgentRelayRequest, workspace w: String, name: String, body: AgentRelayBody?) throws -> HostRequest {
        var wr = WorkspaceRequest(name: w)
        let op: HostOp
        let q = r.query ?? [:]
        switch r.route {
        case "journal":
            op = .workspaceJournal
            var j = WorkspaceJournalRequest()
            if let run = q["run"], !run.isEmpty { j.run = run }
            wr.journal = j
        case "journal-wait":
            op = .workspaceJournal
            guard let kind = q["kind"], !kind.isEmpty else { throw HostError(.invalidValue, "which kind? journal wait KIND") }
            guard JournalKinds.isValid(kind) else { throw HostError(.invalidValue, "\(kind.prefix(70)) is not a kind") }
            var j = WorkspaceJournalRequest()
            j.kind = kind
            if let a = q["after"], !a.isEmpty { j.after = a }
            wr.journal = j
        case "journal-add":
            op = .workspaceJournalAdd
            var j = WorkspaceJournalRequest()
            j.kind = body?.kind
            j.text = body?.text
            j.data = body?.data
            j.refs = body?.refs
            j.supersedes = body?.supersedes
            j.attach = body?.attach
            j.attachRef = body?.attachRef
            wr.journal = j
        case "propose":
            op = .workspaceRetro
            wr.addendum = body?.addendum
            wr.run = body?.run
        case "decide":
            op = .workspaceDecide
            wr.proposal = r.id
            wr.decision = body?.decision
        case "addendum":
            op = .workspaceAddendum
            wr.addendum = body?.addendum
            wr.run = body?.run
        default:
            throw HostError(.invalidValue, "\(r.route.prefix(40)) is not a call of the agent relay")
        }
        var out = HostRequest(op)
        out.workspaceRequest = wr
        out.actAs = w + "/" + name
        return out
    }

    /// A `journal-wait`'s timeout: `timeout=` seconds, 0 to `maximumWaitSeconds` (default the maximum).
    static func waitSeconds(_ r: AgentRelayRequest) throws -> Int {
        guard let t = r.query?["timeout"], !t.isEmpty else { return maximumWaitSeconds }
        guard let n = Int(t), n >= 0 else { throw HostError(.invalidValue, "timeout is whole seconds") }
        return min(n, maximumWaitSeconds)
    }

    /// An `--attach` path as the agent's place sees it, as the path on this Mac: a session on this Mac sees this Mac's own
    /// paths (an absolute one is kept); a sandbox's path is mapped through the folder it is under (`shares`: its folders —
    /// this Mac's path → where the sandbox sees it; the longest match wins). A path under none is refused (65), never guessed.
    public static func hostPath(_ path: String, place: AgentPlace, shares: [(host: String, guest: String)]?) throws -> String {
        guard path.hasPrefix("/"), !path.split(separator: "/").contains("..") else {
            throw HostError(.invalidValue, "--attach \(path.prefix(80)): an absolute path with no ..")
        }
        if place.mac == true { return path }
        guard let sandbox = place.sandbox else {
            throw HostError(.invalidValue, "--attach: an agent elsewhere has no folder of this Mac — attach from a sandbox or a session on this Mac")
        }
        guard let shares, !shares.isEmpty else {
            throw HostError(.invalidValue, "--attach: \(sandbox)'s folders are not known — its paths cannot be mapped to this Mac's")
        }
        let best = shares.filter { path == $0.guest || path.hasPrefix($0.guest.hasSuffix("/") ? $0.guest : $0.guest + "/") }
            .max { $0.guest.count < $1.guest.count }
        guard let s = best else {
            throw HostError(.invalidValue, "--attach \(path.prefix(80)) is not inside a folder the workspace mounts into \(sandbox) (\(shares.map(\.guest).sorted().joined(separator: ", ")))")
        }
        let rest = String(path.dropFirst(s.guest.count))
        return s.host.hasSuffix("/") && rest.hasPrefix("/") ? s.host + rest.dropFirst() : s.host + rest
    }
}

/// Who may send `agent-relay`: the daemon's own supervised chat server only — the connection's peer process is it.
public enum AgentRelayTrust {
    /// Pure: the peer's pid equals the chat server's (and both are known).
    public static func accepts(peer: pid_t?, chatServer: pid_t?) -> Bool {
        guard let p = peer, let c = chatServer, p > 0 else { return false }
        return p == c
    }

    /// The pid of the process at the other end of a connected Unix socket (LOCAL_PEERPID), or nil.
    public static func peerPID(_ fd: Int32) -> pid_t? {
        var pid: pid_t = 0
        var len = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &len) == 0, pid > 0 else { return nil }
        return pid
    }
}

/// 771: an adopted agent's chat token, in a keychain item of its own (this store's, the workspace's and the agent's) — never
/// in the ledger of launch secrets (no sweep judges it by a place's record), never written to the place. Delivered as a
/// launch secret at every session Dozable starts in the place (`HostCore.adoptedChatSecret`); deleted at release.
public enum AdoptedToken {
    public static func service(store root: URL, workspace: String, agent: String) -> String {
        LaunchSecrets.service(store: root, owner: ownerWord(workspace: workspace, agent: agent), variable: ManagerLaunch.tokenVariable)
    }
    static func ownerWord(workspace: String, agent: String) -> String { "adopted." + workspace + "." + agent }
    /// A keychain service that is an adopted agent's token (nothing that revokes a place's launch secrets deletes it).
    public static func isAdopted(_ service: String) -> Bool { service.contains("-adopted.") }
}
