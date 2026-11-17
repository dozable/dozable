import Darwin
import DozableHost
import Foundation

// Chat in the dashboard (docs/engineering/web.md, "Chat"). The browser talks to the dashboard only; the dashboard talks to
// the chat server on the owner's socket (`<store>/chat/chat.sock`, `ChatOwnerClient`) as the person. This is NOT a proxy:
// every route below is a case of a closed enum, each one builds a FIXED upstream method and path from values checked here
// by the chat server's own rules, and nothing of the browser's request — its path, query, cookies, Origin or any other
// header — reaches the socket. Only the listed fields of an answer, and the one header `X-More`, come back.
// A browser of another computer (the LAN option) gets what `serve.chat` (set on this Mac only, default off) allows — off:
// nothing; read: the reads; write: everything, each change a line in the audit log (`WebExposure.decideChat`). Through
// these routes a browser acts as the person: the verified human in chat.

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
    /// POST files?name=NAME — the person uploads one file (`application/octet-stream`, at most the chat server's 20 MiB);
    /// the session and the unsafe-request checks are made from the request's head BEFORE its body is read.
    case upload(name: String)
    /// POST rooms/ROOM/reactions — `{msg_id, reaction}`, with `X-Chat-Id` (done once per id).
    case react(room: String)
    /// POST rooms/ROOM/messages/ID/edit — `{text}`, with `X-Chat-Id`.
    case edit(room: String, id: String)
    /// POST rooms/ROOM/messages/ID/delete — with `X-Chat-Id`.
    case delete(room: String, id: String)
    /// POST rooms/ROOM/messages/ID/reveal — read a direct message between others (the room records that you did).
    case reveal(room: String, id: String)
    /// POST typing — the person is typing (a moment's presence; nothing is stored).
    case typing

    /// Only the reads; every POST changes something (and is refused to a `serve.chat = read` browser).
    public var isSafe: Bool {
        switch self {
        case .status, .state, .presence, .unread, .protocolDescription, .messages, .stream, .file: true
        case .post, .upload, .react, .edit, .delete, .reveal, .typing: false
        }
    }

    /// The calls the chat server does once per `X-Chat-Id`: the header is REQUIRED on them (a v4 UUID), and it is the only
    /// header of the browser's that ever reaches the socket.
    public var takesActionID: Bool {
        switch self { case .react, .edit, .delete: true; default: false }
    }

    /// The route's name in the dashboard's audit log (no value of the request).
    public var label: String {
        switch self {
        case .status: "status"
        case .state: "state"
        case .presence: "presence"
        case .unread: "unread"
        case .protocolDescription: "protocol"
        case .messages: "messages"
        case .post: "post"
        case .stream: "stream"
        case .file: "file"
        case .upload: "upload"
        case .react: "react"
        case .edit: "edit"
        case .delete: "delete"
        case .reveal: "reveal"
        case .typing: "typing"
        }
    }

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
        case (.post, 3) where parts[0] == "rooms" && isRoom(parts[1]) && parts[2] == "reactions":
            return q.isEmpty ? .react(room: parts[1]) : nil
        case (.post, 5) where parts[0] == "rooms" && isRoom(parts[1]) && parts[2] == "messages" && isMessageID(parts[3]):
            guard q.isEmpty else { return nil }
            switch parts[4] {
            case "edit": return .edit(room: parts[1], id: parts[3])
            case "delete": return .delete(room: parts[1], id: parts[3])
            case "reveal": return .reveal(room: parts[1], id: parts[3])
            default: return nil
            }
        case (.post, 1) where parts[0] == "typing":
            return q.isEmpty ? .typing : nil
        case (.post, 1) where parts[0] == "files":
            // Exactly `name=VALUE`: the browser's percent-encoding decoded here, the name then held to the server's rule.
            guard q.hasPrefix("name="), !q.contains("&"), let name = decodeQueryName(String(q.dropFirst(5))) else { return nil }
            return .upload(name: name)
        default:
            return nil
        }
    }

    /// A file name from a query value: `%XX` escapes decoded, raw characters only the name's own (and never `+`, which
    /// some readers take for a space); the result must pass `isFileName`. nil: not a name.
    static func decodeQueryName(_ raw: String) -> String? {
        let b = Array(raw.utf8)
        guard b.count <= 360 else { return nil }
        var out: [UInt8] = []
        var i = 0
        func hex(_ c: UInt8) -> UInt8? {
            switch c { case 48...57: c - 48; case 97...102: c - 87; case 65...70: c - 55; default: nil }
        }
        while i < b.count {
            if b[i] == UInt8(ascii: "%") {
                guard i + 2 < b.count, let hi = hex(b[i + 1]), let lo = hex(b[i + 2]) else { return nil }
                out.append(hi << 4 | lo)
                i += 3
            } else {
                guard isAlnum(b[i]) || "._()-".utf8.contains(b[i]) else { return nil }
                out.append(b[i])
                i += 1
            }
        }
        guard let s = String(bytes: out, encoding: .utf8), isFileName(s) else { return nil }
        return s
    }

    /// A checked name in a query: every byte but `A-Za-z0-9._-` as `%XX`.
    static func encodeQueryName(_ name: String) -> String {
        name.utf8.map { isAlnum($0) || "._-".utf8.contains($0) ? String(UnicodeScalar($0)) : String(format: "%%%02X", $0) }.joined()
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
        case .upload(let name): return "/api/files?name=" + Self.encodeQueryName(name)
        case .react(let room): return "/api/rooms/\(room)/reactions"
        case .edit(let room, let id): return "/api/rooms/\(room)/messages/\(id)/edit"
        case .delete(let room, let id): return "/api/rooms/\(room)/messages/\(id)/delete"
        case .reveal(let room, let id): return "/api/rooms/\(room)/messages/\(id)/reveal"
        case .typing: return "/api/typing"
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

    /// The post's body, strictly: `content` (a string, at most 64 KiB), `to` (at most 32 names), `re_msg_id` (optional),
    /// `attachments` (at most 10 `{id}` of uploaded files; with one, the text may be empty). Unknown keys, wrong types and
    /// out-of-rule values are refused; the body sent upstream is made here.
    static func postBody(_ body: Data) throws -> Data {
        guard let o = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { throw WebAction.Invalid("the body must be a JSON object") }
        guard Set(o.keys).isSubset(of: ["content", "to", "re_msg_id", "attachments"]) else {
            throw WebAction.Invalid("the body is {content, to?, re_msg_id?, attachments?}")
        }
        var files: [String] = []
        if let a = o["attachments"] {
            guard let list = a as? [Any], list.count <= maximumAttachments else { throw WebAction.Invalid("attachments is a list of at most 10 {id}") }
            for e in list {
                guard let d = e as? [String: Any], d.count == 1, let id = d["id"] as? String, WebChatRoute.isFileID(id) else {
                    throw WebAction.Invalid("an attachment is {id} of an uploaded file")
                }
                files.append(id)
            }
        }
        guard let content = o["content"] as? String, !content.isEmpty || !files.isEmpty, content.utf8.count <= maximumContent else {
            throw WebAction.Invalid("content is the message's text, 1 byte to 64 KiB (it may be empty with an attachment)")
        }
        var out: [String: Any] = ["content": content]
        if !files.isEmpty { out["attachments"] = files.map { ["id": $0] } }
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
    static let maximumAttachments = 10

    /// A reaction's body, strictly: `{msg_id, reaction}` — a message id, and a reaction's name or an emoji (1 to 32 bytes,
    /// no control character).
    static func reactBody(_ body: Data) throws -> Data {
        guard let o = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any], Set(o.keys) == ["msg_id", "reaction"],
              let id = o["msg_id"] as? String, WebChatRoute.isMessageID(id),
              let r = o["reaction"] as? String, (1...32).contains(r.utf8.count), !r.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
        else { throw WebAction.Invalid("the body is {msg_id, reaction}: a message id and a reaction's name or an emoji") }
        return try JSONSerialization.data(withJSONObject: ["msg_id": id, "reaction": r], options: [.sortedKeys, .withoutEscapingSlashes])
    }

    /// An edit's body, strictly: `{text}`, at most 64 KiB.
    static func editBody(_ body: Data) throws -> Data {
        guard let o = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any], Set(o.keys) == ["text"],
              let t = o["text"] as? String, t.utf8.count <= maximumContent
        else { throw WebAction.Invalid("the body is {text}: the message's new text, at most 64 KiB") }
        return try JSONSerialization.data(withJSONObject: ["text": t], options: [.sortedKeys, .withoutEscapingSlashes])
    }

    /// The body of a call that takes none (delete, reveal, typing): nothing, or `{}`. Upstream it is always `{}`.
    static func emptyBody(_ body: Data) throws -> Data {
        if !body.isEmpty {
            guard let o = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any], o.isEmpty else { throw WebAction.Invalid("this call takes no body") }
        }
        return Data("{}".utf8)
    }

    /// The upload's answer: id, name, type, size and url only — never the server's own `path` (a folder of this Mac).
    static func uploaded(_ body: Data) -> Data? {
        guard let o = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let id = o["id"] as? String, WebChatRoute.isFileID(id), let name = o["name"] as? String, WebChatRoute.isFileName(name),
              let url = o["url"] as? String, url == "/files/\(id)/\(name)" else { return nil }
        var out: [String: Any] = ["id": id, "name": name, "url": url]
        if let t = o["type"] as? String, t.count <= 100, t.allSatisfy({ $0.isASCII && !$0.isWhitespace && $0 != "\"" }) { out["type"] = t }
        if let n = o["size"] as? Int, n >= 0 { out["size"] = n }
        return try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys, .withoutEscapingSlashes])
    }

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
    /// What this browser may do: `write` (this Mac's own, or another computer with `serve.chat = write`) or `read` (the
    /// composer and every control that changes something are off). nil before chat runs.
    public var access: String?

    public init(state: String, problem: String? = nil, access: String? = nil) {
        self.state = state; self.problem = problem; self.access = access
    }
}

/// The chat routes' work: blocking socket calls on their own queue (at most 8 at once, never the event loop or the
/// cooperative pool), and one thread per relayed stream (at most `chatHub`'s 4).
final class WebChatProxy: @unchecked Sendable {
    static let maximumStreamLine = 1 << 20
    /// An attachment: the server's 20 MiB, and a margin.
    static let maximumFile = 21 << 20
    /// The post's body: 64 KiB of text in at most 80 KiB of JSON (an edit's too).
    static let maximumPostBody = 80 * 1024
    /// The chat server's largest attachment (`ChatFileRules.maxSize`; a test pins the two together).
    static let maximumUpload = 20 << 20
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
    func call(_ method: String, _ target: String, body: Data? = nil, headers: [(String, String)] = [], contentType: String = "application/json",
              maximum: Int = ChatOwnerClient.maximumAnswer) async throws -> ChatOwnerClient.Answer {
        let c = client, slots = slots
        return try await withCheckedThrowingContinuation { cont in
            queue.async {
                slots.wait()
                defer { slots.signal() }
                cont.resume(with: Result { try c.request(method, target, json: body, headers: headers, contentType: contentType, timeout: 20, maximum: maximum) })
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
    func chatReply(_ route: WebChatRoute, _ md: WebRequestMetadata, body: Data, cookie: String, writable: Bool = true) async throws -> Reply {
        let jsonType = ("Content-Type", "application/json; charset=utf-8")
        if case .status = route {
            var st = chat.status()
            if st.state == "running" { st.access = writable ? "write" : "read" }
            return json(st)
        }
        if case .stream = route {
            guard chat.enabled() else { throw WebRejection.chatOff }
            guard FileManager.default.fileExists(atPath: chat.paths.socket) else { throw WebRejection.chatNotReady }
            guard let client = chatHub.add(cookie: cookie) else { throw WebRejection.tooManyStreams }
            let handle = ChatOwnerClient.StreamHandle()
            chat.relay(to: client, hub: chatHub, handle: handle)
            return .chatStream(client, handle)
        }
        // The one header of the browser's that may go upstream: X-Chat-Id, on the calls done once per id, as a v4 UUID.
        var upstreamHeaders: [(String, String)] = []
        if route.takesActionID {
            guard let id = md.chatActionID, WebChatRoute.isActionID(id) else { throw WebAction.Invalid("X-Chat-Id must be a version 4 UUID") }
            upstreamHeaders = [("X-Chat-Id", id)]
        }
        var upstreamBody: Data?
        var contentType = "application/json"
        switch route {
        case .post:
            try Self.requireJSONBody(md)
            upstreamBody = try WebChatProjection.postBody(body)
        case .react:
            try Self.requireJSONBody(md)
            upstreamBody = try WebChatProjection.reactBody(body)
        case .edit:
            try Self.requireJSONBody(md)
            upstreamBody = try WebChatProjection.editBody(body)
        case .delete, .reveal, .typing:
            if !body.isEmpty { try Self.requireJSONBody(md) }
            upstreamBody = try WebChatProjection.emptyBody(body)
        case .upload:
            try Self.requireUploadBody(md)
            guard !body.isEmpty else { throw WebAction.Invalid("the body is the file's bytes") }
            guard body.count <= WebChatProxy.maximumUpload else { throw WebRejection.chatFileTooLarge }
            upstreamBody = body
            contentType = "application/octet-stream"
        case .status, .state, .presence, .unread, .protocolDescription, .messages, .stream, .file:
            break
        }
        let isFile: Bool = if case .file = route { true } else { false }
        let answer: ChatOwnerClient.Answer
        do {
            answer = try await chat.call(route.isSafe ? "GET" : "POST", route.upstreamTarget, body: upstreamBody, headers: upstreamHeaders,
                                         contentType: contentType, maximum: isFile ? WebChatProxy.maximumFile : ChatOwnerClient.maximumAnswer)
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
        case .post, .react, .edit, .delete:
            guard let d = WebChatProjection.posted(answer.body) else { throw bad }
            return .response(200, [jsonType], d)
        case .reveal:
            // The revealed message: the protocol's own view for the person, like a page of the log.
            guard let d = WebChatProjection.passThrough(answer.body, array: false) else { throw bad }
            return .response(200, [jsonType], d)
        case .typing:
            return .response(204, [], Data())
        case .upload:
            guard let d = WebChatProjection.uploaded(answer.body) else { throw bad }
            return .response(200, [jsonType], d)
        case .file(_, let name):
            return .response(200, WebChatProjection.fileHeaders(upstreamType: answer.header("content-type"), name: name), answer.body)
        }
    }
}
