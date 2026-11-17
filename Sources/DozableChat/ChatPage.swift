import Foundation

// The page port's requests and answers, transport-free: `ChatPageHandler.handle` takes one whole request (its method,
// the request target exactly as sent, its headers, its body and the caller's address) and returns one whole answer.
// The listener (ChatListeners.swift) only frames HTTP around it. Everything a client can see — the status, the
// headers, the bytes of the body — is decided here, as the reference server answers.

/// Who a request came from, by the way it arrived: a TCP connection (judged by its address, `ChatAccess`) or the
/// owner's private socket (`ChatOwnerSocket`: a Unix socket in a 0700 folder, only the same user admitted) — the one
/// way to act as the human when tokens are required. A TCP caller is never the owner. A connection accepted on a remote
/// listener (`remote_bind`: this Mac's Tailscale address) is `remote`, whatever its address or the config says: always an
/// agent — `/agent/` and a file with a participant's token, nothing else, and never the human.
public enum ChatCaller: Sendable, Equatable {
    case tcp
    case owner
    case remote
}

public struct ChatHTTPRequest: Sendable {
    public var method: String
    /// The request target as sent (`/agent/../x?y=1`), never tidied.
    public var target: String
    /// Header names in lower case; the first value of each.
    public var headers: [String: String]
    public var body: [UInt8]
    public var remoteIP: String
    /// The body was longer than this request may send (`ChatPageHandler.bodyLimit`): what came past it was not kept.
    public var truncated = false
    /// How it arrived (`ChatCaller`); TCP unless the owner's socket served it.
    public var caller: ChatCaller = .tcp

    public init(method: String, target: String, headers: [String: String] = [:], body: [UInt8] = [], remoteIP: String, truncated: Bool = false,
                caller: ChatCaller = .tcp) {
        self.method = method; self.target = target; self.headers = headers; self.body = body; self.remoteIP = remoteIP
        self.truncated = truncated
        self.caller = caller
    }

    /// The human acts without a token: over the owner's socket, or (a config that requires no tokens) from an owned
    /// address the access gate already let through.
    func humanWithoutToken(requireTokens: Bool) -> Bool { caller == .owner || (caller == .tcp && !requireTokens) }

    public func header(_ name: String) -> String { headers[name.lowercased()] ?? "" }

    public var rawPath: String { String(target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? "") }
    public var rawQuery: String? {
        let parts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        return parts.count > 1 ? String(parts[1]) : nil
    }

    /// The first value of a query parameter, decoded; "" when absent.
    public func query(_ name: String) -> String {
        guard let q = rawQuery else { return "" }
        for pair in q.split(separator: "&", omittingEmptySubsequences: true) {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let k = String(kv[0]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? ""
            if k == name {
                let v = kv.count > 1 ? String(kv[1]) : ""
                return v.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? ""
            }
        }
        return ""
    }
}

public struct ChatHTTPResponse: Sendable, Equatable {
    public var status: Int
    public var headers: [(String, String)]
    public var body: [UInt8]
    /// The live stream: the head is written, then `body` (the hello), then each event as it comes, until it ends.
    public var stream: ChatSubscriber?
    /// A receive that waits: the listener finishes it (`ChatLongPoll.finish`) and writes that answer instead.
    public var poll: ChatLongPoll?

    public init(status: Int, headers: [(String, String)], body: [UInt8]) {
        self.status = status; self.headers = headers; self.body = body
    }

    public static func == (a: ChatHTTPResponse, b: ChatHTTPResponse) -> Bool {
        a.status == b.status && a.body == b.body && a.headers.map { $0.0 + ":" + $0.1 } == b.headers.map { $0.0 + ":" + $0.1 }
    }

    public func header(_ name: String) -> String? { headers.first { $0.0.lowercased() == name.lowercased() }?.1 }
    public var text: String { String(decoding: body, as: UTF8.self) }

    /// `writeJSON`: the value, a newline, `application/json`.
    public static func json(_ status: Int, _ v: JValue) -> ChatHTTPResponse {
        ChatHTTPResponse(status: status, headers: [("Content-Type", "application/json")], body: ChatJSON.encode(v) + [0x0A])
    }

    public static func jsonError(_ status: Int, _ message: String) -> ChatHTTPResponse {
        json(status, .map(["error": .string(message)]))
    }

    /// `http.Error`: plain text and a newline.
    public static func error(_ status: Int, _ text: String) -> ChatHTTPResponse {
        ChatHTTPResponse(status: status, headers: [("Content-Type", "text/plain; charset=utf-8"), ("X-Content-Type-Options", "nosniff")],
                         body: Array((text + "\n").utf8))
    }
}

public struct ChatPageHandler: Sendable {
    public let core: ChatServerCore

    public init(core: ChatServerCore) { self.core = core }

    /// The answer to one request. Every answer tells a browser to forget any HTTPS-only rule for the host.
    public func handle(_ r: ChatHTTPRequest) -> ChatHTTPResponse {
        var out = gate(r)
        out.headers.insert(("Strict-Transport-Security", "max-age=0"), at: 0)
        if r.method == "HEAD" {
            // The same headers as GET, the length of the body GET would send, and no body.
            if !out.body.isEmpty && out.header("Content-Length") == nil { out.headers.append(("Content-Length", String(out.body.count))) }
            out.body = []
        }
        return out
    }

    /// Who may call: only the owner's own machines; a machine that must use a token, or an agent address, only /agent/.
    private func gate(_ r: ChatHTTPRequest) -> ChatHTTPResponse {
        // The owner's socket admitted only this user's processes (`ChatOwnerSocket.admit`): it is the human's own door.
        if r.caller == .owner { return route(r) }
        // A remote listener's caller: one of the agents the config lets in (`allow`), and then only an exact /agent/ call
        // or a file fetch with a participant's token — never the page, /api or the stream, never the human.
        if r.caller == .remote {
            guard core.access.allow.contains(r.remoteIP) else { return .error(403, ChatAccess.notOwned) }
            guard ChatPath.isAgentPath(rawPath: r.rawPath) || isTokenFileFetch(r) else { return .error(403, ChatAccess.agentOnly) }
            return route(r)
        }
        // An agent address may also fetch a file, with a participant's token: the download decides who that is.
        if core.access.isAgentAddress(r.remoteIP), isTokenFileFetch(r) { return route(r) }
        if let refusal = core.access.page(remote: r.remoteIP, agentPath: ChatPath.isAgentPath(rawPath: r.rawPath)) {
            return .error(403, refusal)
        }
        return route(r)
    }

    /// The routes, matched as a router that redirects an untidy path and answers 405 for a known path's wrong method.
    private func route(_ r: ChatHTTPRequest) -> ChatHTTPResponse {
        let path = ChatPath.percentDecoded(r.rawPath) ?? r.rawPath
        guard path.hasPrefix("/") else { return .error(400, "400 Bad Request") }
        let tidy = Self.cleanPath(path)
        if tidy != path {
            let loc = tidy + (r.rawQuery.map { "?" + $0 } ?? "")
            var res = ChatHTTPResponse(status: 301, headers: [("Location", loc)], body: [])
            if r.method == "GET" || r.method == "HEAD" {
                res.headers.insert(("Content-Type", "text/html; charset=utf-8"), at: 0)
                res.body = Array("<a href=\"\(Self.htmlEscape(loc))\">Moved Permanently</a>.\n\n".utf8)
            }
            return res
        }
        let seg = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().map(String.init)
        let method = r.method == "HEAD" ? "GET" : r.method
        var allowed: [String] = []
        for route in Self.routes {
            guard let vars = route.match(seg) else { continue }
            if route.method != method { allowed.append(route.method); continue }
            return run(route.name, vars, r)
        }
        if !allowed.isEmpty {
            var methods = Set(allowed)
            if methods.contains("GET") { methods.insert("HEAD") }
            var res = ChatHTTPResponse.error(405, "Method Not Allowed")
            res.headers.append(("Allow", methods.sorted().joined(separator: ", ")))
            return res
        }
        return .error(404, "404 page not found")
    }

    struct Route: Sendable {
        let method: String
        let pattern: [String]   // a segment in braces is a variable; "" at the end is an exact "/"
        let name: String

        func match(_ seg: [String]) -> [String: String]? {
            guard seg.count == pattern.count else { return nil }
            var vars: [String: String] = [:]
            for (p, s) in zip(pattern, seg) {
                if p.hasPrefix("{") { guard !s.isEmpty else { return nil }; vars[String(p.dropFirst().dropLast())] = s } else if p != s { return nil }
            }
            return vars
        }
    }

    static func r(_ m: String, _ p: String, _ name: String) -> Route {
        Route(method: m, pattern: p.split(separator: "/", omittingEmptySubsequences: false).dropFirst().map(String.init), name: name)
    }

    /// Every route of the protocol. Those of a later milestone answer that they are not available yet.
    static let routes: [Route] = [
        r("GET", "/", "page"),
        r("GET", "/api/state", "state"),
        r("GET", "/api/protocol", "protocol"),
        r("GET", "/api/rooms/{room}/messages", "messages"),
        r("POST", "/api/rooms/{room}/messages", "post"),
        r("POST", "/api/reload", "reload"),
        r("POST", "/api/typing", "typing"),
        r("POST", "/agent/register", "register"),
        r("POST", "/agent/unregister", "unregister"),
        r("POST", "/agent/send", "send"),
        r("POST", "/agent/ack", "ack"),
        r("GET", "/agent/receive", "receive"),
        r("GET", "/api/unread", "unread"),
        r("GET", "/api/presence", "presence"),
        r("GET", "/api/stream", "stream"),
        r("POST", "/api/rooms/{room}/reactions", "react"),
        r("POST", "/api/rooms/{room}/messages/{id}/reveal", "reveal"),
        r("POST", "/api/rooms/{room}/messages/{id}/edit", "edit"),
        r("POST", "/api/rooms/{room}/messages/{id}/delete", "delete"),
        r("POST", "/api/files", "upload"),
        r("GET", "/files/{id}/{name}", "file"),
        r("GET", "/api/rooms/{room}/app", "later"),
        r("POST", "/api/rooms/{room}/app", "app-change"),
        r("POST", "/api/rooms/{room}/app/icon", "app-change"),
        r("POST", "/api/rooms/{room}/app/reset", "app-change"),
        r("GET", "/sw.js", "later"),
        r("GET", "/manifest.webmanifest", "later"),
    ]

    private func run(_ name: String, _ vars: [String: String], _ r: ChatHTTPRequest) -> ChatHTTPResponse {
        switch name {
        case "page":
            return ChatHTTPResponse(status: 200, headers: [("Content-Type", "text/html; charset=utf-8")], body: Array(ChatServerCore.pageShell.utf8))
        case "state": return .json(200, core.stateJSON())
        case "protocol": return .json(200, core.protocolJSON())
        case "messages": return messages(vars["room"] ?? "", r)
        case "post": return post(vars["room"] ?? "", r)
        case "reload":
            if let refusal = pageCaller(r, "telling the pages to reload") { return refusal }
            let n = core.viewers
            core.publish(ChatEvent(kind: "reload"))
            return .json(200, .map(["pages": .int(Int64(n))]))
        case "typing":
            if let refusal = pageCaller(r, "saying the human is typing") { return refusal }
            core.mark(core.human(), \.typing)
            return ChatHTTPResponse(status: 204, headers: [], body: [])
        case "presence": return .json(200, .array(core.presence()))
        case "unread": return .json(200, core.unread(markers: { r.query($0) }))
        case "stream":
            var res = ChatHTTPResponse(status: 200, headers: [("Content-Type", "text/event-stream"), ("Cache-Control", "no-cache")],
                                       body: Array("data: {\"kind\":\"hello\",\"version\":\(goQuote(ChatServerCore.pageVersion))}\n\n".utf8))
            res.stream = core.subscribe()
            return res
        case "reveal":
            let who = r.humanWithoutToken(requireTokens: core.config.requireTokens) ? core.human() : (core.whoHas(r.header(Self.tokenHeader)) ?? "")
            switch core.reveal(room: vars["room"] ?? "", msgID: vars["id"] ?? "", who: who) {
            case .success(let m): return .json(200, m.json)
            case .failure(let e): return .jsonError(e.status, e.description)
            }
        case "edit", "delete": return change(name, vars["room"] ?? "", vars["id"] ?? "", r)
        case "react": return react(vars["room"] ?? "", r)
        case "upload": return upload(r)
        case "file": return download(vars["id"] ?? "", r)
        case "app-change":
            // Who may call it is decided now (only the human); what it does comes in a later step.
            if let refusal = pageCaller(r, "changing a room's app") { return refusal }
            return .jsonError(501, "this call is not available on this server yet")
        case "register", "unregister", "send", "ack", "receive": return agent(name, r)
        default: return .jsonError(501, "this call is not available on this server yet")
        }
    }

    /// One page of a room's log as the human sees it.
    private func messages(_ room: String, _ r: ChatHTTPRequest) -> ChatHTTPResponse {
        func num(_ k: String, _ def: Int64) -> Int64? {
            let v = r.query(k)
            if v.isEmpty { return def }
            guard let n = Int64(v), n >= 0 else { return nil }
            return n
        }
        guard let after = num("after", 0), let before = num("before", 0), let limit = num("limit", 500), limit >= 1 else {
            return .jsonError(400, "after and before are message seqs (0 or more), and limit is a number from 1 to 500")
        }
        let human = core.human()
        if core.hasRoom(room) && !core.member(room, human) { return .jsonError(403, "\(human) is not a member of room \(room)") }
        do {
            let (ms, more) = try core.messagePage(room: room, after: after, before: before, limit: Int(min(limit, 500)), viewer: human)
            var res = ChatHTTPResponse.json(200, .array(ms.map(\.json)))
            res.headers.insert(("X-More", more ? "true" : "false"), at: 0)
            return res
        } catch {
            return .jsonError(404, "\(error)")
        }
    }

    /// The human posts from the page.
    private func post(_ room: String, _ r: ChatHTTPRequest) -> ChatHTTPResponse {
        var who = core.whoHas(r.header(Self.tokenHeader)) ?? ""
        if r.humanWithoutToken(requireTokens: core.config.requireTokens) { who = core.human() }   // the page is only served to the owner's own machines
        guard core.isHuman(who) else { return .jsonError(401, "posting needs the human's token") }
        guard let v = Self.decodeFirst(r.body, limit: ChatProtocol.maxLine) else { return .jsonError(400, "body must be JSON") }
        var line = ChatLine()
        do {
            if !v.isNull {
                guard v.isObject else { return .jsonError(400, "body must be JSON") }
                line.content = try v.field("content")?.goString("content") ?? ""
                line.to = try v.field("to")?.goStrings("to") ?? []
                line.reMsgID = try v.field("re_msg_id")?.goString("re_msg_id") ?? ""
                line.msgID = try v.field("msg_id")?.goString("msg_id") ?? ""
                line.isPrivate = try v.field("private")?.goBool("private") ?? false
                switch v.field("attachments") ?? .null {
                case .null: break
                case .array(let a):
                    guard a.allSatisfy({ $0.isObject || $0.isNull }) else { return .jsonError(400, "body must be JSON") }
                    line.attachments = a.filter(\.isObject)
                default: return .jsonError(400, "body must be JSON")
                }
            }
        } catch { return .jsonError(400, "body must be JSON") }
        if line.msgID.isEmpty { line.msgID = chatNewID() }
        line.msgV = ChatProtocol.msgV
        line.type = "user"
        line.hasBody = true
        line.room = room
        // Checked: by its token, or by the owner's socket (only this user's processes reach it).
        line.verified = core.config.requireTokens || r.caller == .owner
        let rc = core.post(line, sender: who)
        return .json(rc.state == "refused" ? 422 : 200,
                     .map(["msg_id": .string(line.msgID), "state": .string(rc.state), "detail": .string(rc.detail)]))
    }

    /// The human edits or deletes a message, done once per X-Chat-Id.
    private func change(_ verb: String, _ room: String, _ id: String, _ r: ChatHTTPRequest) -> ChatHTTPResponse {
        var who = core.whoHas(r.header(Self.tokenHeader)) ?? ""
        if r.humanWithoutToken(requireTokens: core.config.requireTokens) { who = core.human() }
        guard core.isHuman(who) else { return .jsonError(401, "changing a message needs the human's token") }
        var text = ""
        let v = Self.decodeFirst(r.body, limit: ChatProtocol.maxLine)
        let parsed: String?? = v.map { v in v.isNull ? "" : (v.isObject ? (try? v.field("text")?.goString("text") ?? "") : nil) }
        if case .some(.some(let t)) = parsed { text = t } else if verb == "edit" {
            return .jsonError(400, "body must be JSON: {\"text\":\"…\"}")
        }
        guard let rc = core.pageOnce(id: r.header(Self.idHeader), room: room, who: who, {
            verb == "edit" ? core.edit(room: room, sender: who, ref: id, text: text) : core.delete(room: room, who: who, ref: id)
        }) else { return .jsonError(400, Self.idHeader + " must be a uuid") }
        return .json(rc.state == "refused" ? 422 : 200, .map(["state": .string(rc.state), "detail": .string(rc.detail)]))
    }

    /// The human reacts from the page, done once per X-Chat-Id. The body is at most 4096 bytes.
    private func react(_ room: String, _ r: ChatHTTPRequest) -> ChatHTTPResponse {
        var who = core.whoHas(r.header(Self.tokenHeader)) ?? ""
        if r.humanWithoutToken(requireTokens: core.config.requireTokens) { who = core.human() }
        guard core.isHuman(who) else { return .jsonError(401, "reacting needs the human's token") }
        let bad = ChatHTTPResponse.jsonError(400, "body must be JSON")
        guard r.body.count <= 4096, let v = Self.decodeFirst(r.body, limit: 4096), v.isObject || v.isNull,
              let id = try? v.field("msg_id")?.goString("msg_id") ?? "",
              let what = try? v.field("reaction")?.goString("reaction") ?? "" else { return bad }
        guard let rc = core.pageOnce(id: r.header(Self.idHeader), room: room, who: who, {
            core.react(room: room, sender: who, msgID: id, what: what)
        }) else { return .jsonError(400, Self.idHeader + " must be a uuid") }
        return .json(rc.state == "refused" ? 422 : 200, .map(["state": .string(rc.state), "detail": .string(rc.detail)]))
    }

    /// The most a request's body may be: a file upload's is one file and one byte more (so one byte over is told from
    /// more); every other request's is a line and one byte. What comes past it is not kept.
    public static func bodyLimit(method: String, target: String) -> Int {
        let path = String(target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        return method == "POST" && path == "/api/files" ? ChatFileRules.maxSize + 1 : ChatProtocol.maxLine + 1
    }

    /// The human uploads one file (`?name=`, the bytes as the body); the answer is the attachment to name in a message.
    /// Its size is checked before anything is written; the name is cleaned and never used as a path.
    private func upload(_ r: ChatHTTPRequest) -> ChatHTTPResponse {
        if let refusal = pageCaller(r, "uploading a file") { return refusal }
        if r.truncated { return .jsonError(413, "a file can be at most \(ChatFileRules.maxSize >> 20) MB") }
        switch core.saveFile(name: r.query("name"), r.body) {
        case .success(let a): return .json(200, a.json(filesDir: core.filesDir))
        case .failure(let e): return .jsonError(e.status == 500 ? 500 : 400, e.description)
        }
    }

    /// A file fetch an agent address is served: `GET`/`HEAD` of an exact `/files/<id>/<name>` (nothing a router would tidy)
    /// with `Authorization: Bearer` and a token that is a participant's. Anything else — no token, a token that is no
    /// one's, the page's own header — is the agent-address refusal (403): the address rule comes first (protocol 1.2,
    /// the reference's TestS4_8_FetchFromAgentAddress). Whether that participant may read the file is the download's.
    func isTokenFileFetch(_ r: ChatHTTPRequest) -> Bool {
        let token = Self.bearerToken(r)
        return (r.method == "GET" || r.method == "HEAD") && ChatPath.isFilePath(rawPath: r.rawPath) && !token.isEmpty
            && core.whoHolds(token) != nil
    }

    /// The token of `Authorization: Bearer <token>`, trimmed; "" when there is none.
    static func bearerToken(_ r: ChatHTTPRequest) -> String {
        let auth = r.header("Authorization")
        guard auth.hasPrefix("Bearer ") else { return "" }
        return ChatServerCore.trimSpace(String(auth.dropFirst(7)))
    }

    /// Who fetches a file on the page port. A participant's token (`Authorization: Bearer`; from one of the owner's own
    /// callers also `X-Chat-Token`) makes that participant the caller. Without one, the owner's socket or an owned caller
    /// is the human. An agent address is never the human: it needs a token, and a token that is no one's — or the
    /// human's — fetches nothing (nil: the plain 404, never "treat it as the human").
    func fileCaller(_ r: ChatHTTPRequest) -> String? {
        let agentOnly = r.caller == .remote || (r.caller == .tcp && core.access.isAgentAddress(r.remoteIP))
        let bearer = Self.bearerToken(r)
        if !bearer.isEmpty {
            guard let who = core.whoHolds(bearer) else { return nil }
            return agentOnly && core.isHuman(who) ? nil : who
        }
        if agentOnly { return nil }
        let other = r.header(Self.tokenHeader)
        if !other.isEmpty, let who = core.whoHas(other) { return who }
        return core.human()
    }

    /// A stored file. Only to a caller that may read a message that names it; never sniffed; sandboxed; shown inline
    /// only when it is a plain image, otherwise a download. One byte range (`a-b`, `a-`, `-n`) is answered 206; a start
    /// past the end 416; several ranges, or one that cannot be read, the whole file (as the RFC allows). Anything else
    /// is the router's 404.
    private func download(_ id: String, _ r: ChatHTTPRequest) -> ChatHTTPResponse {
        guard let who = fileCaller(r), !who.isEmpty, let a = core.storedFile(id), core.mayFetch(id, by: who), let bytes = core.fileBytes(a) else {
            return .error(404, "404 page not found")
        }
        var headers = [("Accept-Ranges", "bytes"), ("Content-Type", a.type), ("X-Content-Type-Options", "nosniff"), ("Content-Security-Policy", "sandbox")]
        if !ChatFileRules.isInlineImage(a.type) { headers.append(("Content-Disposition", "attachment; filename=\(goQuote(a.name))")) }
        switch Self.byteRange(r.header("Range"), size: bytes.count) {
        case .whole:
            return ChatHTTPResponse(status: 200, headers: headers, body: bytes)
        case .part(let lo, let hi):
            headers.append(("Content-Range", "bytes \(lo)-\(hi)/\(bytes.count)"))
            return ChatHTTPResponse(status: 206, headers: headers, body: Array(bytes[lo...hi]))
        case .unsatisfiable:
            return ChatHTTPResponse(status: 416, headers: [("Content-Range", "bytes */\(bytes.count)"), ("Content-Type", "text/plain; charset=utf-8"),
                                                           ("X-Content-Type-Options", "nosniff"), ("Content-Security-Policy", "sandbox")],
                                    body: Array("invalid range: failed to overlap\n".utf8))
        }
    }

    enum ByteRange: Equatable { case whole, part(Int, Int), unsatisfiable }

    /// One `Range: bytes=…` header read against a file of `size` bytes.
    static func byteRange(_ header: String, size: Int) -> ByteRange {
        let h = header.trimmingCharacters(in: .whitespaces)
        guard h.hasPrefix("bytes=") else { return .whole }
        let spec = String(h.dropFirst(6)).trimmingCharacters(in: .whitespaces)
        guard !spec.contains(","), let dash = spec.firstIndex(of: "-") else { return .whole }
        let first = spec[..<dash].trimmingCharacters(in: .whitespaces), last = spec[spec.index(after: dash)...].trimmingCharacters(in: .whitespaces)
        func num(_ s: String) -> Int? { s.isEmpty || !s.allSatisfy(\.isASCII) || !s.allSatisfy(\.isNumber) ? nil : Int(s) }
        if first.isEmpty {   // the last n bytes
            guard let n = num(last) else { return .whole }
            if n == 0 { return .unsatisfiable }
            if size == 0 { return .unsatisfiable }
            return .part(max(0, size - n), size - 1)
        }
        guard let lo = num(first) else { return .whole }
        if lo >= size { return .unsatisfiable }
        if last.isEmpty { return .part(lo, size - 1) }
        guard let hi = num(last), hi >= lo else { return .whole }
        return .part(lo, min(hi, size - 1))
    }

    /// Who makes a page call that changes something: the human. nil serves it; otherwise the 401 answer.
    private func pageCaller(_ r: ChatHTTPRequest, _ what: String) -> ChatHTTPResponse? {
        var who = core.whoHas(r.header(Self.tokenHeader)) ?? ""
        if r.humanWithoutToken(requireTokens: core.config.requireTokens) { who = core.human() }
        return core.isHuman(who) ? nil : .jsonError(401, "\(what) needs the human's token")
    }

    /// The header that carries the human's token on a page call that changes something.
    public static let tokenHeader = "X-Chat-Token"
    /// The header that carries the page's own id for one edit, delete or reaction call: with it, the call is done once.
    public static let idHeader = "X-Chat-Id"

    // MARK: /agent/

    static let needBearer = "these calls need a token: Authorization: Bearer <token>"

    private func agent(_ name: String, _ r: ChatHTTPRequest) -> ChatHTTPResponse {
        let auth = r.header("Authorization")
        let token = ChatServerCore.trimSpace(auth.hasPrefix("Bearer ") ? String(auth.dropFirst(7)) : auth)
        guard let caller = core.whoHolds(token) else { return .jsonError(401, Self.needBearer) }
        // From another machine the human's token is no one's: the human never comes in that way.
        if r.caller == .remote && core.isHuman(caller) { return .jsonError(401, Self.needBearer) }
        let p = core.participant(caller)
        switch name {
        case "register":
            if p == nil || p?.deliver == "poll" { return .jsonError(403, "a registered session cannot register another") }
            guard let v = Self.decodeFirst(r.body, limit: 1 << 16), v.isObject || v.isNull,
                  let n = try? v.field("Name")?.goString("name") ?? "", let room = try? v.field("Room")?.goString("room") ?? "" else {
                return .jsonError(400, "send {\"name\":\"…\",\"room\":\"…\"}")
            }
            do {
                let token = try core.register(launcher: caller, name: n, room: room)
                return .json(200, .map(["name": .string(n), "room": .string(room), "token": .string(token),
                                        "note": .string("This token is shown once. Hand it to the session; it sends with POST /agent/send and waits with GET /agent/receive.")]))
            } catch let e as ChatAPIError { return .jsonError(e.status, e.description) } catch { return .jsonError(422, "\(error)") }
        case "unregister":
            guard let v = Self.decodeFirst(r.body, limit: 1 << 16), v.isObject || v.isNull,
                  let n = try? v.field("Name")?.goString("name") ?? "", !n.isEmpty else {
                return .jsonError(400, "send {\"name\":\"…\"}")
            }
            do {
                try core.unregister(by: caller, name: n)
                return .json(200, .map(["removed": .string(n)]))
            } catch let e as ChatAPIError { return .jsonError(e.status, e.description) } catch { return .jsonError(422, "\(error)") }
        case "send":
            if core.isHuman(caller) {
                return .jsonError(403, "the human's token cannot send on /agent/send: the human posts from the page")
            }
            guard let v = Self.decodeFirst(r.body, limit: 32 << 20), var line = try? ChatLine.read(v) else {
                return .jsonError(400, "send a message as JSON: {\"message\":{\"content\":\"…\"},\"room\":\"…\"}")
            }
            if line.msgID.isEmpty { line.msgID = chatNewID() }
            line.msgV = ChatProtocol.msgV
            line.type = "user"
            line.verified = true
            core.heard(caller, answered: false)
            let rc = core.post(line, sender: caller)
            return .json(rc.state == "refused" ? 422 : 200,
                         .map(["state": .string(rc.state), "detail": .string(rc.detail), "msg_id": .string(line.msgID)]))
        case "ack":
            if let refusal = core.mayPoll(caller) { return .jsonError(refusal.status, refusal.description) }
            let bad = ChatHTTPResponse.jsonError(400, "send {\"acks\":[{\"room\":\"…\",\"msg_id\":\"…\"}]}")
            guard let v = Self.decodeFirst(r.body, limit: 1 << 20), v.isObject || v.isNull else { return bad }
            var items: [(room: String, msgID: String, delivery: String)] = []
            switch v.field("acks") ?? .null {
            case .null: break
            case .array(let a):
                for e in a {
                    if e.isNull { items.append(("", "", "")); continue }
                    guard e.isObject, let room = try? e.field("room")?.goString("room") ?? "", let id = try? e.field("msg_id")?.goString("msg_id") ?? "",
                          let d = try? e.field("delivery")?.goString("delivery") ?? "" else { return bad }
                    items.append((room, id, d))
                }
            default: return bad
            }
            core.heard(caller, answered: false)
            return .json(200, .map(["acked": .int(Int64(core.ack(caller, items)))]))
        default: // receive
            if let refusal = core.mayPoll(caller) { return .jsonError(refusal.status, refusal.description) }
            return core.receive(caller, wait: r.query("wait"), ack: r.query("ack") == "1", redeliver: r.query("redeliver") == "1")
        }
    }

    // MARK: helpers

    /// The first JSON value of a body read up to limit bytes, as a decoder reads a request body; nil when there is none.
    static func decodeFirst(_ body: [UInt8], limit: Int) -> JValue? {
        let b = body.count > limit ? Array(body.prefix(limit)) : body
        return try? ChatJSON.parse(b, trailing: true)
    }

    /// The router's tidy form of a path: `path.Clean`, keeping a trailing slash.
    static func cleanPath(_ p: String) -> String {
        if p.isEmpty { return "/" }
        var np = ChatPath.clean(p.hasPrefix("/") ? p : "/" + p)
        if p.hasSuffix("/") && np != "/" { np += "/" }
        return np
    }

    static func htmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&#34;").replacingOccurrences(of: "'", with: "&#39;")
    }
}
