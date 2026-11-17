import Darwin
import DozableHost
import Foundation

// Chat in the dashboard (docs/engineering/web.md, "Chat"). The browser talks to the dashboard only; the dashboard talks to
// the chat server on the owner's socket (`<store>/chat/chat.sock`, `ChatOwnerClient`) as the person. This is NOT a proxy:
// every route below is a case of a closed enum, each one builds a FIXED upstream method and path from values checked here
// by the chat server's own rules, and nothing of the browser's request — its path, query, cookies, Origin or any other
// header — reaches the socket. Only the listed fields of an answer, and the one header `X-More`, come back.
// A browser of another computer (the LAN option) gets none of it (`WebExposure`, kind `chat`).

/// One chat route, after `/api/v1/chat/`.
public enum WebChatRoute: Equatable, Sendable {
    /// GET status — whether chat is on and ready (no upstream call; never starts anything).
    case status
    /// GET state — the server's `/api/state`, projected.
    case state
    /// GET presence — `/api/presence`.
    case presence
    /// GET unread?ROOM=SEQ… — `/api/unread` with at most 256 markers.
    case unread([WebChatMarker])
    /// GET protocol — `/api/protocol`.
    case protocolDescription
    /// GET rooms/ROOM/messages?after=&before=&limit= — one page of a room's log.
    case messages(room: String, after: Int64?, before: Int64?, limit: Int?)
    /// POST rooms/ROOM/messages — the person posts (a strict body, re-encoded).
    case post(room: String)
    /// GET stream — the live stream, relayed (its own hub).
    case stream
    /// GET files/ID/NAME — an attachment, served with the sandboxing headers.
    case file(id: String, name: String)

    public var isSafe: Bool { if case .post = self { false } else { true } }

    /// The prefix every chat route is under.
    public static let prefix = "/api/v1/chat/"

    /// A room's name: the server's rule.
    public static func isRoom(_ s: String) -> Bool {
        let b = Array(s.utf8)
        guard (1...64).contains(b.count), let f = b.first, isLowerAlnum(f) else { return false }
        return b.allSatisfy { isLowerAlnum($0) || $0 == UInt8(ascii: "_") || $0 == UInt8(ascii: "-") }
    }

    /// A participant's name (what `to` names): the same rule as a room's.
    public static func isName(_ s: String) -> Bool { isRoom(s) }

    /// A message id or the start of one: lower-case hex and dashes, at most 36.
    public static func isMessageID(_ s: String) -> Bool {
        (1...36).contains(s.utf8.count) && s.utf8.allSatisfy { isHex($0) || $0 == UInt8(ascii: "-") }
    }

    /// An attachment's id: 16 or 32 lower-case hex digits.
    public static func isFileID(_ s: String) -> Bool { (s.utf8.count == 16 || s.utf8.count == 32) && s.utf8.allSatisfy(isHex) }

    /// An attachment's name as the server keeps it: `A-Za-z0-9._ ()+-`, at most 120 bytes, never starting with a dot or a
    /// space (the server drops those), so never `.` or `..`.
    public static func isFileName(_ s: String) -> Bool {
        let b = Array(s.utf8)
        guard (1...120).contains(b.count), b[0] != UInt8(ascii: "."), b[0] != UInt8(ascii: " ") else { return false }
        return b.allSatisfy { isAlnum($0) || "._ ()+-".utf8.contains($0) }
    }

    /// `X-Chat-Id`: a version 4 UUID, lower-case. (Slice 2's routes send it; nothing in this one does.)
    public static func isActionID(_ s: String) -> Bool {
        let b = Array(s.utf8)
        guard b.count == 36 else { return false }
        for (i, c) in b.enumerated() {
            if [8, 13, 18, 23].contains(i) { guard c == UInt8(ascii: "-") else { return false } } else { guard isHex(c) else { return false } }
        }
        return b[14] == UInt8(ascii: "4") && "89ab".utf8.contains(b[19])
    }

    private static func isHex(_ c: UInt8) -> Bool { (48...57).contains(c) || (97...102).contains(c) }
    private static func isLowerAlnum(_ c: UInt8) -> Bool { (48...57).contains(c) || (97...122).contains(c) }
    private static func isAlnum(_ c: UInt8) -> Bool { isLowerAlnum(c) || (65...90).contains(c) }

    /// A non-negative integer of at most 18 digits (no sign, no leading zero but `0` itself).
    static func number(_ s: Substring) -> Int64? {
        guard (1...18).contains(s.count), s.allSatisfy({ $0.isASCII && $0.isNumber }), s == "0" || s.first != "0" else { return nil }
        return Int64(s)
    }

    /// An attachment's address: `/api/v1/chat/files/ID/NAME`, the name percent-encoded by the browser (a space is `%20`).
    /// Parsed before the route table's no-`%` rule; the decoded name must pass `isFileName`.
    static func parseFile(method: WebHTTPMethod, path: String) -> WebChatRoute? {
        guard method.isSafe, path.hasPrefix(prefix + "files/") else { return nil }
        let parts = path.dropFirst((prefix + "files/").count).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, isFileID(String(parts[0])) else { return nil }
        let raw = String(parts[1])
        // Only `%20` and the name's own characters: no other escape (a `%2F` would be a separator in disguise).
        guard !raw.contains("%") || raw.replacingOccurrences(of: "%20", with: "").allSatisfy({ $0 != "%" }) else { return nil }
        let name = raw.replacingOccurrences(of: "%20", with: " ")
        guard isFileName(name) else { return nil }
        return .file(id: String(parts[0]), name: name)
    }

    /// The route for the path after `/api/v1/chat/` (`parts`, split on `/`) and its query. A query is read only where a
    /// route takes one, each key by its rule; a query anywhere else, or an unknown key, is not a route.
    static func parse(method: WebHTTPMethod, parts: [String], query: String?) -> WebChatRoute? {
        let q = query ?? ""
        switch (method, parts.count) {
        case (.get, 1), (.head, 1):
            switch parts[0] {
            case "status": return q.isEmpty ? .status : nil
            case "state": return q.isEmpty ? .state : nil
            case "presence": return q.isEmpty ? .presence : nil
            case "protocol": return q.isEmpty ? .protocolDescription : nil
            case "stream": return q.isEmpty && method == .get ? .stream : nil
            case "unread": return WebChatMarker.parse(q).map(WebChatRoute.unread)
            default: return nil
            }
        case (.get, 3) where parts[0] == "rooms" && isRoom(parts[1]) && parts[2] == "messages":
            var after: Int64?, before: Int64?, limit: Int?
            if !q.isEmpty {
                var seen = Set<Substring>()
                for kv in q.split(separator: "&", omittingEmptySubsequences: false) {
                    let p = kv.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                    guard p.count == 2, seen.insert(p[0]).inserted, let n = number(p[1]) else { return nil }
                    switch p[0] {
                    case "after": after = n
                    case "before": before = n
                    case "limit": guard (1...500).contains(n) else { return nil }; limit = Int(n)
                    default: return nil
                    }
                }
            }
            return .messages(room: parts[1], after: after, before: before, limit: limit)
        case (.post, 3) where parts[0] == "rooms" && isRoom(parts[1]) && parts[2] == "messages":
            return q.isEmpty ? .post(room: parts[1]) : nil
        default:
            return nil
        }
    }

    /// The fixed upstream target, built from the checked values only.
    var upstreamTarget: String {
        switch self {
        case .status: return ""
        case .state: return "/api/state"
        case .presence: return "/api/presence"
        case .protocolDescription: return "/api/protocol"
        case .stream: return "/api/stream"
        case .unread(let ms): return "/api/unread" + (ms.isEmpty ? "" : "?" + ms.map { "\($0.room)=\($0.seq)" }.joined(separator: "&"))
        case .messages(let room, let after, let before, let limit):
            let q = [after.map { "after=\($0)" }, before.map { "before=\($0)" }, limit.map { "limit=\($0)" }].compactMap { $0 }
            return "/api/rooms/\(room)/messages" + (q.isEmpty ? "" : "?" + q.joined(separator: "&"))
        case .post(let room): return "/api/rooms/\(room)/messages"
        case .file(let id, let name): return "/files/\(id)/" + name.replacingOccurrences(of: " ", with: "%20")
        }
    }
}

/// One unread marker: the newest seq this browser has seen in a room.
public struct WebChatMarker: Equatable, Sendable {
    public var room: String
    public var seq: Int64

    public static let maximum = 256

    /// `ROOM=SEQ&…` — at most 256, each room once; empty is none.
    static func parse(_ q: String) -> [WebChatMarker]? {
        if q.isEmpty { return [] }
        let pairs = q.split(separator: "&", omittingEmptySubsequences: false)
        guard pairs.count <= maximum else { return nil }
        var out: [WebChatMarker] = []
        var seen = Set<Substring>()
        for kv in pairs {
            let p = kv.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard p.count == 2, WebChatRoute.isRoom(String(p[0])), seen.insert(p[0]).inserted, let n = WebChatRoute.number(p[1]) else { return nil }
            out.append(WebChatMarker(room: String(p[0]), seq: n))
        }
        return out
    }
}

/// What the chat routes answer, as pure functions over the upstream answer (unit-tested without a server).
enum WebChatProjection {
    /// The longest error text passed on from the chat server.
    static let maximumErrorText = 300

    /// `/api/state`, field by field: rooms, archived, participants (name and kind only), default_room, reactions, version.
    /// Everything else (`token_service`, `need_token`, `https_url`, `apps`, `release`, a participant's other fields) is
    /// dropped. nil: not the shape it should be.
    static func state(_ body: Data) -> Data? {
        guard let o = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return nil }
        var out: [String: Any] = [:]
        var rooms: [String: [String]] = [:]
        for (r, v) in (o["rooms"] as? [String: Any]) ?? [:] {
            guard WebChatRoute.isRoom(r), let names = v as? [String] else { continue }
            rooms[r] = names.filter(WebChatRoute.isName)
        }
        out["rooms"] = rooms
        out["archived"] = ((o["archived"] as? [Any]) ?? []).compactMap { $0 as? String }.filter(WebChatRoute.isRoom)
        out["participants"] = ((o["participants"] as? [Any]) ?? []).compactMap { p -> [String: String]? in
            guard let p = p as? [String: Any], let n = p["name"] as? String, WebChatRoute.isName(n) else { return nil }
            let kind = (p["kind"] as? String).flatMap { k in k.count <= 32 && k.allSatisfy { $0.isASCII && ($0.isLetter || $0 == "-") } ? k : nil } ?? ""
            return ["name": n, "kind": kind]
        }
        if let d = o["default_room"] as? String, WebChatRoute.isRoom(d) { out["default_room"] = d }
        out["reactions"] = ((o["reactions"] as? [Any]) ?? []).compactMap { r -> [String: String]? in
            guard let r = r as? [String: Any], let n = r["name"] as? String, let e = r["emoji"] as? String, n.count <= 32, e.count <= 16 else { return nil }
            return ["name": n, "emoji": e]
        }
        if let v = o["version"] as? String, v.count <= 64 { out["version"] = v }
        return try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    /// The post's answer: msg_id, state and detail only.
    static func posted(_ body: Data) -> Data? {
        guard let o = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return nil }
        var out: [String: String] = [:]
        for k in ["msg_id", "state", "detail"] { if let v = o[k] as? String { out[k] = String(v.prefix(maximumErrorText)) } }
        return try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    /// A JSON body passed through as it is (messages, presence, unread, protocol) — only when it IS JSON of the expected
    /// kind. These are the protocol's own view for the person; its human API carries no token field.
    static func passThrough(_ body: Data, array: Bool) -> Data? {
        guard let v = try? JSONSerialization.jsonObject(with: body) else { return nil }
        return (array ? v is [Any] : v is [String: Any]) ? body : nil
    }

    /// The chat server's refusal, re-wrapped in the dashboard's error shape (its text cut to 300 characters; nothing else).
    static func error(status: Int, _ body: Data) -> (Int, Data) {
        let o = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        var text = (o?["error"] as? String) ?? (o?["detail"] as? String) ?? ""
        if text.isEmpty { text = "the chat server answered \(status)" }
        text = String(text.prefix(maximumErrorText)).filter { !$0.isNewline }
        let s = (400...599).contains(status) ? status : 502
        return (s, DozableWebServer.errorBody("chat", text))
    }

    /// The post's body, strictly: `content` (a string, at most 64 KiB), `to` (at most 32 names), `re_msg_id` (optional).
    /// Unknown keys, wrong types and out-of-rule values are refused; the body sent upstream is made here.
    static func postBody(_ body: Data) throws -> Data {
        guard let o = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { throw WebAction.Invalid("the body must be a JSON object") }
        guard Set(o.keys).isSubset(of: ["content", "to", "re_msg_id"]) else { throw WebAction.Invalid("the body is {content, to?, re_msg_id?}") }
        guard let content = o["content"] as? String, !content.isEmpty, content.utf8.count <= maximumContent else {
            throw WebAction.Invalid("content is the message's text, 1 byte to 64 KiB")
        }
        var out: [String: Any] = ["content": content]
        if let t = o["to"] {
            guard let names = t as? [String], names.count <= 32, names.allSatisfy(WebChatRoute.isName) else {
                throw WebAction.Invalid("to is a list of at most 32 participant names")
            }
            out["to"] = names
        }
        if let r = o["re_msg_id"] {
            guard let id = r as? String, WebChatRoute.isMessageID(id) else { throw WebAction.Invalid("re_msg_id is a message id") }
            out["re_msg_id"] = id
        }
        return try JSONSerialization.data(withJSONObject: out, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    static let maximumContent = 64 * 1024

    /// How an attachment is served: inline only for these pictures, else a download.
    static let inlineTypes: Set<String> = ["image/png", "image/jpeg", "image/gif", "image/webp"]

    /// The headers of an attachment's answer, decided here from the upstream type alone (its own disposition is never
    /// trusted): nosniff, a sandboxing policy (a rendered document is opaque and runs nothing), same-origin, never cached.
    static func fileHeaders(upstreamType: String?, name: String) -> [(String, String)] {
        let t = (upstreamType ?? "").split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        var h: [(String, String)] = [
            ("X-Content-Type-Options", "nosniff"),
            ("Content-Security-Policy", "sandbox; default-src 'none'"),
            ("Cross-Origin-Resource-Policy", "same-origin"),
            ("Cache-Control", "private, no-store"),
            ("Referrer-Policy", "no-referrer"),
        ]
        if inlineTypes.contains(t) {
            h.insert(("Content-Type", t), at: 0)
        } else {
            h.insert(("Content-Type", "application/octet-stream"), at: 0)
            h.append(("Content-Disposition", "attachment; filename=\"\(name.filter { $0 != "\"" && $0 != "\\" })\""))
        }
        return h
    }

    /// One `data:` line of the upstream stream, judged before it is relayed: a JSON object with a string `kind`, at most
    /// 1 MiB. Its kind, or nil to drop it.
    static func streamKind(_ line: String) -> String? {
        guard line.utf8.count <= WebChatProxy.maximumStreamLine,
              let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any], let k = o["kind"] as? String else { return nil }
        return k
    }
}

/// Whether chat can be used now — `GET /api/v1/chat/status`. Read from the settings, the store's daemon lock and the
/// supervisor's file; nothing is started.
public struct WebChatStatus: Codable, Equatable, Sendable {
    /// off · no-daemon · starting · running · failing
    public var state: String
    /// What is wrong, in the supervisor's words (failing only).
    public var problem: String?
}

/// The chat routes' work: blocking socket calls on their own queue (at most 8 at once, never the event loop or the
/// cooperative pool), and one thread per relayed stream (at most `chatHub`'s 4).
final class WebChatProxy: @unchecked Sendable {
    static let maximumStreamLine = 1 << 20
    /// An attachment: the server's 20 MiB, and a margin.
    static let maximumFile = 21 << 20
    /// The post's body: 64 KiB of text in at most 80 KiB of JSON.
    static let maximumPostBody = 80 * 1024
    static let maximumAtOnce = 8

    let paths: ChatPaths
    let store: DozableStore
    let enabled: @Sendable () -> Bool
    private let queue = DispatchQueue(label: "doz.web.chat", attributes: .concurrent)
    private let slots = DispatchSemaphore(value: WebChatProxy.maximumAtOnce)

    init(storePath: String, enabled: @escaping @Sendable () -> Bool) {
        store = DozableStore(root: URL(fileURLWithPath: storePath))
        paths = ChatPaths(store: store)
        self.enabled = enabled
    }

    var client: ChatOwnerClient { ChatOwnerClient(paths: paths) }

    func status() -> WebChatStatus {
        guard enabled() else { return WebChatStatus(state: "off") }
        guard store.hostIsRunning() else { return WebChatStatus(state: "no-daemon") }
        let sup = ChatServerState.load(paths)
        switch sup?.state ?? "starting" {
        case "running" where sup?.ready == true:
            return WebChatStatus(state: FileManager.default.fileExists(atPath: paths.socket) ? "running" : "starting")
        case "failing", "stopped":
            return WebChatStatus(state: "failing", problem: sup?.problem.map { String($0.prefix(WebChatProjection.maximumErrorText)) })
        default:
            return WebChatStatus(state: "starting")
        }
    }

    /// What a missing socket means for the person: chat is off, or not ready yet.
    func unavailable() -> WebRejection { enabled() ? .chatNotReady : .chatOff }

    /// One upstream call off the cooperative pool.
    func call(_ method: String, _ target: String, body: Data? = nil, maximum: Int = ChatOwnerClient.maximumAnswer) async throws -> ChatOwnerClient.Answer {
        let c = client, slots = slots
        return try await withCheckedThrowingContinuation { cont in
            queue.async {
                slots.wait()
                defer { slots.signal() }
                cont.resume(with: Result { try c.request(method, target, json: body, timeout: 20, maximum: maximum) })
            }
        }
    }

    /// The relay of one browser's stream: a thread follows the upstream and hands each judged line to `client`; it ends
    /// when the client ends (`handle` is cancelled by the caller then), the upstream ends (`chatGone`), or it says resync.
    func relay(to client: SSEClient, hub: SSEHub, handle: ChatOwnerClient.StreamHandle) {
        let c = self.client
        let t = Thread {
            do {
                try c.stream(WebChatRoute.stream.upstreamTarget, handle: handle, maximumLine: Self.maximumStreamLine) { line in
                    guard client.end == nil else { return false }
                    guard let kind = WebChatProjection.streamKind(line) else { return true }
                    if kind == "resync" { client.finish(.overflow); return false }
                    client.send(SSEFrame(event: "chat", id: hub.nextSeq(), json: Data(line.utf8)))
                    return client.end == nil
                }
            } catch {}
            client.finish(.chatGone)
        }
        t.name = "doz.web.chat-stream"
        t.stackSize = 512 * 1024
        t.start()
    }
}

extension DozableWebServer {
    /// One chat route (the Mac's own browser, signed in, its unsafe-request checks passed already).
    func chatReply(_ route: WebChatRoute, _ md: WebRequestMetadata, body: Data, cookie: String) async throws -> Reply {
        let jsonType = ("Content-Type", "application/json; charset=utf-8")
        if case .status = route { return json(chat.status()) }
        if case .stream = route {
            guard chat.enabled() else { throw WebRejection.chatOff }
            guard FileManager.default.fileExists(atPath: chat.paths.socket) else { throw WebRejection.chatNotReady }
            guard let client = chatHub.add(cookie: cookie) else { throw WebRejection.tooManyStreams }
            let handle = ChatOwnerClient.StreamHandle()
            chat.relay(to: client, hub: chatHub, handle: handle)
            return .chatStream(client, handle)
        }
        var upstreamBody: Data?
        if case .post = route {
            try Self.requireJSONBody(md)
            upstreamBody = try WebChatProjection.postBody(body)
        }
        let isFile: Bool = if case .file = route { true } else { false }
        let answer: ChatOwnerClient.Answer
        do {
            answer = try await chat.call(route.isSafe ? "GET" : "POST", route.upstreamTarget, body: upstreamBody,
                                         maximum: isFile ? WebChatProxy.maximumFile : ChatOwnerClient.maximumAnswer)
        } catch ChatOwnerClient.Failure.notListening {
            throw chat.unavailable()
        } catch {
            throw HostError(.unavailable, "the chat server did not answer")
        }
        guard (200...299).contains(answer.status) else {
            let (s, d) = WebChatProjection.error(status: answer.status, answer.body)
            return .response(s, [jsonType], d)
        }
        let bad = HostError(.failed, "the chat server's answer could not be read")
        switch route {
        case .status, .stream:
            throw WebRejection.notFound
        case .state:
            guard let d = WebChatProjection.state(answer.body) else { throw bad }
            return .response(200, [jsonType], d)
        case .presence:
            guard let d = WebChatProjection.passThrough(answer.body, array: true) else { throw bad }
            return .response(200, [jsonType], d)
        case .unread, .protocolDescription:
            guard let d = WebChatProjection.passThrough(answer.body, array: false) else { throw bad }
            return .response(200, [jsonType], d)
        case .messages:
            guard let d = WebChatProjection.passThrough(answer.body, array: true) else { throw bad }
            // The one upstream header the browser gets: whether newer messages are left.
            return .response(200, [jsonType, ("X-More", answer.header("x-more") == "true" ? "true" : "false")], d)
        case .post:
            guard let d = WebChatProjection.posted(answer.body) else { throw bad }
            return .response(200, [jsonType], d)
        case .file(_, let name):
            return .response(200, WebChatProjection.fileHeaders(upstreamType: answer.header("content-type"), name: name), answer.body)
        }
    }
}
