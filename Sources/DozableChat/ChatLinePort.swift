import Foundation

// The line port's protocol, transport-free: one connection's state (whether a token is required, who the token named)
// and what each line does — a reply line, nothing, or closing the connection with no reply. The listener frames the
// lines (JSON lines, at most 32 MiB, closed after 30 s without one) and calls this in order, one line at a time.

public struct ChatLineConnection: Sendable {
    public enum Outcome: Equatable, Sendable {
        case reply([UInt8])
        case nothing
        case close(String)   // why, for the log (never a secret)
    }

    let core: ChatServerCore
    let ip: String
    let required: Bool
    public private(set) var sender = ""

    /// A connection from ip, or nil when the address may not use the line port (closed at once).
    public init?(core: ChatServerCore, remoteIP ip: String) {
        guard let required = core.access.line(remote: ip) else { return nil }
        self.core = core
        self.ip = ip
        self.required = required
    }

    /// The seconds a connection may stay without a line.
    public static let idleSeconds: Int64 = 30

    public mutating func handle(_ raw: [UInt8]) -> Outcome {
        if raw.isEmpty { return .nothing }
        guard let v = try? ChatJSON.parse(raw), let m = try? ChatLine.read(v) else { return .close("a line that is not JSON") }
        if m.type == "auth" {
            sender = core.whoHas(m.token) ?? ""
            if sender.isEmpty && required { return .close("a bad auth line") }
            if required && core.isHuman(sender) { return .close("the human's token on the line port") }
            return .nothing
        }
        if required && sender.isEmpty { return .close("a line from a connection that did not authenticate") }
        func reply(_ members: [JMember]) -> Outcome { .reply(ChatJSON.encode(.map(Dictionary(uniqueKeysWithValues: members.map { ($0.key, $0.value) }))) + [0x0A]) }
        let base = [JMember("msgV", .int(Int64(ChatProtocol.msgV))), JMember("type", .string("control")), JMember("orig_msg_id", .string(m.msgID))]
        func receipt(_ rc: ChatReceipt) -> Outcome {
            var r = base + [JMember("action", .string("receipt")), JMember("state", .string(rc.state))]
            if !rc.detail.isEmpty { r.append(JMember("detail", .string(rc.detail))) }
            return reply(r)
        }
        switch (m.type, m.action) {
        case ("control", "heartbeat"), ("control", "thinking"):
            let who = sender.isEmpty ? m.from : sender
            if core.participant(who) != nil {
                core.heard(who, answered: false)
                if m.action == "thinking" {
                    core.mark(who, \.thinking)
                    if !m.reMsgID.isEmpty {   // "I have started on this message"
                        let room = m.room.isEmpty ? core.config.defaultRoom : m.room
                        if let st = try? core.store(room) {
                            core.started(who, room: room, msgID: st.fullID(m.reMsgID), detail: "it said it has started on this message")
                        }
                    }
                }
            }
            return reply(base + [JMember("action", .string("ok"))])
        case ("control", "file"):
            // No attachment is stored by this server yet, so every id is unknown.
            return reply(base + [JMember("action", .string("file")), JMember("state", .string("refused")), JMember("detail", .string("no such attachment"))])
        case ("control", "protocol"):
            return reply(base + [JMember("action", .string("protocol")), JMember("version", .string(ChatProtocol.version)),
                                 JMember("protocol", core.protocolJSON())])
        case ("control", "ping"):
            return reply(base + [JMember("action", .string("pong"))])
        case ("reaction", _):
            let who = sender.isEmpty ? m.from : sender
            return receipt(core.reactOnce(room: m.room, sender: who, lineID: m.msgID, msgID: m.reMsgID, what: m.reaction))
        case ("user", _):
            var line = m
            let who = sender.isEmpty ? m.from : sender   // one of the owner's own machines is taken at its word
            line.verified = !sender.isEmpty
            return receipt(core.post(line, sender: who))
        default:
            return receipt(.refused("unknown line type"))
        }
    }
}
