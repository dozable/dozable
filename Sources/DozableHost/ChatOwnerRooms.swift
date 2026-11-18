import DozableChat
import Foundation

/// The chat server's state as you see it on the owner's socket: rooms → members, and the participants.
public struct ChatStateView: Sendable {
    public var rooms: [String: [String]] = [:]
    public var participants: [(name: String, kind: String)] = []
    public var defaultRoom = ChatConfigFile.defaultRoom

    public init(_ v: JValue) {
        if case .object(let m)? = v.field("rooms") { for e in m { rooms[e.key] = (try? e.value.goStrings("rooms")) ?? [] } }
        if case .array(let a)? = v.field("participants") {
            participants = a.compactMap { p in p.field("name")?.stringValue.map { ($0, p.field("kind")?.stringValue ?? "") } }
        }
        if let d = v.field("default_room")?.stringValue, !d.isEmpty { defaultRoom = d }
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

    static func reason(_ v: JValue, _ status: Int) -> String {
        v.field("detail")?.stringValue ?? v.field("error")?.stringValue ?? "refused (\(status))"
    }
}
