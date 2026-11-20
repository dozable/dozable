import DozableChat
import Foundation

/// The files a chat server is started with: the generated config, the token hashes, the webhook entries' pipe bytes
/// (held in memory only, never written to a file; empty: no webhook bot) and the sessions folder handed with
/// `--claude-sessions` (nil: no participant is delivered to by inbox).
public struct ChatServerFiles: Equatable, Sendable {
    public var config: [UInt8]
    public var tokens: Data
    public var webhooks: Data
    public var sessions: String?

    public init(config: [UInt8], tokens: Data, webhooks: Data = Data(), sessions: String? = nil) {
        self.config = config; self.tokens = tokens; self.webhooks = webhooks; self.sessions = sessions
    }

    /// What the supervisor names in a reload request and the server checks: the config's bytes, then the hashes'.
    public var reloadSHA: String { ChatReload.sha(config: config, tokens: tokens) }
}

/// Whether a change of the files is taken by the running server (`reload`, over the control channel) or needs a restart —
/// pure (`ChatReloadPolicyTests`). A reload only when the config differs by participant entries added or removed (every
/// other byte the same, and every entry both have the same) and/or the token hashes differ; the webhook entries and the
/// sessions folder equal. Anything else — a port, the bind, the remote listener, a participant's delivery, a webhook
/// entry, the first inbox participant — restarts, as before. When in doubt, a restart.
public enum ChatReloadPolicy {
    public enum Decision: Equatable, Sendable { case same, reload, restart }

    public static func decide(old: ChatServerFiles, new: ChatServerFiles) -> Decision {
        if old == new { return .same }
        guard old.webhooks == new.webhooks, old.sessions == new.sessions else { return .restart }
        if old.config == new.config { return .reload }                 // the token hashes alone
        guard case .object(let a)? = try? ChatJSON.parse(Data(old.config)), case .object(let b)? = try? ChatJSON.parse(Data(new.config)) else {
            return .restart
        }
        func rest(_ m: [JMember]) -> [UInt8] { ChatJSON.encode(.object(m.filter { $0.key != "participants" })) }
        guard rest(a) == rest(b) else { return .restart }
        guard let pa = entries(a), let pb = entries(b) else { return .restart }
        // Every name both have: its entry byte for byte the same (a changed delivery or kind restarts).
        for (name, e) in pa { if let f = pb[name], f != e { return .restart } }
        // Something was added or removed; a reordering alone is not a change a reload is for.
        return Set(pa.keys) == Set(pb.keys) ? .restart : .reload
    }

    /// The participant entries by name (their encoded bytes); nil when the list is not one of named objects, or a name
    /// is there twice.
    static func entries(_ members: [JMember]) -> [String: [UInt8]]? {
        guard let m = members.first(where: { $0.key == "participants" }), case .array(let list) = m.value else { return nil }
        var out: [String: [UInt8]] = [:]
        for v in list {
            guard let n = v.field("name")?.stringValue, out[n] == nil else { return nil }
            out[n] = ChatJSON.encode(v)
        }
        return out
    }
}
