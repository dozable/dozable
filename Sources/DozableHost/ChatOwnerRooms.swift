import DozableChat
import Foundation

/// The chat server's state as you see it on the owner's socket: rooms → members, and the participants.
public struct ChatStateView: Sendable {
    public var rooms: [String: [String]] = [:]
    public var participants: [(name: String, kind: String)] = []
    public var defaultRoom = ChatConfigFile.defaultRoom
    /// The rooms archived now (read-only; their history stays).
    public var archived: Set<String> = []

    public init(_ v: JValue) {
        if case .object(let m)? = v.field("rooms") { for e in m { rooms[e.key] = (try? e.value.goStrings("rooms")) ?? [] } }
        if case .array(let a)? = v.field("participants") {
            participants = a.compactMap { p in p.field("name")?.stringValue.map { ($0, p.field("kind")?.stringValue ?? "") } }
        }
        if let d = v.field("default_room")?.stringValue, !d.isEmpty { defaultRoom = d }
        archived = Set((try? v.field("archived")?.goStrings("archived")) ?? [])
    }

    /// You.
    public var human: String? { participants.first { $0.kind == "human" }?.name }
    /// Every human but you.
    public var otherHumans: [String] { participants.filter { $0.kind == "human" && $0.name != human }.map(\.name) }
}

/// Rooms made AS YOU, over the owner's socket (`ChatOwnerClient`) — the ONE implementation `doz chat
/// room` and the daemon's workspaces both use. A room is made by sending `/room NAME @members…` in a room you are in, as
/// the page does. Errors are `HostError`s: the server not listening or not answering is `unavailable`.
public struct ChatOwnerRooms: Sendable {
    public let client: ChatOwnerClient
    public init(client: ChatOwnerClient) { self.client = client }

    /// One request, its JSON answer (any status).
    public func ask(_ method: String, _ target: String, body: JValue? = nil) throws -> (Int, JValue) {
        do {
            let a = try client.request(method, target, json: body.map { Data(ChatJSON.encode($0)) })
            return (a.status, (try? ChatJSON.parse(a.body)) ?? .null)
        } catch ChatOwnerClient.Failure.notListening {
            throw HostError(.unavailable, "chat is on but its server is not ready — doz chat status")
        } catch ChatOwnerClient.Failure.failed(let why) {
            throw HostError(.unavailable, why)
        }
    }

    public func state() throws -> ChatStateView {
        let (status, v) = try ask("GET", "/api/state")
        guard status == 200 else { throw HostError(.failed, "the chat server answered \(status)") }
        return ChatStateView(v)
    }

    /// Make `name` with these members (and you); answered with its members as the server has them.
    @discardableResult
    public func makeRoom(_ name: String, members: [String]) throws -> [String] {
        guard chatIsRoomName(name) else { throw HostError(.invalid, "\(name) is not a room name: lower-case letters, digits, - and _") }
        let s = try state()
        if s.rooms[name] != nil { throw HostError(.exists, "there is already a room \(name)") }
        for n in members where !s.participants.contains(where: { $0.name == n }) {
            throw HostError(.notFound, "no participant \(n) in chat (doz chat add \(n))")
        }
        guard let me = s.human else { throw HostError(.failed, "chat has no human") }
        // The command is sent as a message in a room you are in: the first room, else any.
        let at = s.rooms[s.defaultRoom]?.contains(me) == true ? s.defaultRoom : (s.rooms.keys.sorted().first { s.rooms[$0]!.contains(me) } ?? s.defaultRoom)
        let content = (["/room", name] + members.map { "@" + $0 }).joined(separator: " ")
        let (status, v) = try ask("POST", "/api/rooms/\(at)/messages", body: .map(["content": .string(content)]))
        guard status == 200 else { throw HostError(.failed, Self.reason(v, status)) }
        return try state().rooms[name] ?? []
    }

    /// Post `content` in `room` AS YOU (a workspace's kick-off). Refused unless the server took it.
    public func post(room: String, content: String) throws {
        guard chatIsRoomName(room) else { throw HostError(.invalid, "\(room) is not a room name") }
        let (status, v) = try ask("POST", "/api/rooms/\(room)/messages", body: .map(["content": .string(content)]))
        guard status == 200 else { throw HostError(.failed, "the chat server did not take the message: " + Self.reason(v, status)) }
    }

    /// Invite `name` to `room` AS YOU (`/invite @NAME`, sent in that room); nothing when it is a member already. Answers
    /// whether it was invited now.
    @discardableResult
    public func invite(room: String, name: String) throws -> Bool {
        let s = try state()
        guard let members = s.rooms[room] else { throw HostError(.notFound, "no room \(room) in chat") }
        if members.contains(name) { return false }
        guard s.participants.contains(where: { $0.name == name }) else { throw HostError(.notFound, "no participant \(name) in chat") }
        let (status, v) = try ask("POST", "/api/rooms/\(room)/messages", body: .map(["content": .string("/invite @" + name)]))
        guard status == 200 else { throw HostError(.failed, "\(name) could not be invited to \(room): " + Self.reason(v, status)) }
        return true
    }

    /// Archive `room` AS YOU (`/archive`, sent in that room — read-only from now on, its history kept), or open it again
    /// (`/unarchive`). Nothing when it is so already. Answers whether it changed now.
    @discardableResult
    public func setArchived(room: String, _ on: Bool) throws -> Bool {
        guard chatIsRoomName(room) else { throw HostError(.invalid, "\(room) is not a room name") }
        let s = try state()
        guard s.rooms[room] != nil else { throw HostError(.notFound, "no room \(room) in chat") }
        if s.archived.contains(room) == on { return false }
        let (status, v) = try ask("POST", "/api/rooms/\(room)/messages", body: .map(["content": .string(on ? "/archive" : "/unarchive")]))
        guard status == 200 else { throw HostError(.failed, "the room \(room) could not be \(on ? "archived" : "opened again"): " + Self.reason(v, status)) }
        return true
    }

    static func reason(_ v: JValue, _ status: Int) -> String {
        v.field("detail")?.stringValue ?? v.field("error")?.stringValue ?? "refused (\(status))"
    }
}
