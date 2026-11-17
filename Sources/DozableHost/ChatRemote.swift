import DozableChat
import Foundation

// Agents on other machines (docs/engineering/chat.md, "Agents on other machines"): the chat server ALSO listens on this
// Mac's own Tailscale addresses (`chat.remote_listen`, both ports) for the machines `chat.remote_agents` names. Every
// caller there is an agent with its own token (`ChatCaller.remote`): `/agent/…` and a file with its token, never the page,
// /api or the human. Both settings are set on this Mac only — never from the dashboard or the environment.

public enum ChatRemoteSettings {
    /// The most addresses either setting holds.
    public static let maximum = 16

    /// The addresses of a setting's value ("" = none).
    public static func list(_ s: String) -> [String] {
        s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Why a value is refused (nil: it may be used): each an exact IPv4 address in 100.64.0.0/10 — no range, no LAN,
    /// loopback, link-local or IPv6 address —, each once, at most 16.
    public static func problem(_ s: String) -> String? {
        let l = list(s)
        if l.count > maximum { return "at most \(maximum) addresses" }
        var seen = Set<String>()
        for e in l {
            if e.contains("/") { return "\(e): a range is not taken here — name each machine's address exactly" }
            guard let a = ChatAddress(e), a.bytes.count == 4, ChatAddress.text(a) == e else { return "\(e) is not an IPv4 address (like 100.100.1.2)" }
            guard ChatWebhookAddress.tailnet.contains(a) else { return "\(e) is not a Tailscale address (100.64.0.0/10); only Tailscale addresses are taken here" }
            guard seen.insert(e).inserted else { return "\(e) is listed twice" }
        }
        return nil
    }
}

/// What the supervisor says of the remote listener (`supervisor.json`, `doz chat status --json`'s `remote`).
public struct ChatRemoteState: Codable, Equatable, Sendable {
    /// The addresses it listens on now (besides loopback).
    public var listen: [String]
    /// The machines that may connect.
    public var agents: [String]
    /// Addresses of `chat.remote_listen` that are not this Mac's Tailscale addresses now: not listened on.
    public var missing: [String]

    public init(listen: [String], agents: [String], missing: [String]) { self.listen = listen; self.agents = agents; self.missing = missing }

    /// The one sentence that says what is open.
    public func line(pagePort: Int, linePort: Int) -> String? {
        guard !listen.isEmpty else { return nil }
        let who = agents.isEmpty ? "nobody yet (chat.remote_agents is empty)" : agents.joined(separator: ", ")
        return "Also listening on \(listen.joined(separator: ", ")) (page port \(pagePort), line port \(linePort)) for \(who) — agents with a token only."
    }

    /// The standing problems: an address that is not here now, and a listener that admits nobody.
    public var warnings: [String] {
        var w = missing.map { "not listening on \($0): not an address of this Mac now (is Tailscale up?)" }
        if !(listen.isEmpty && missing.isEmpty) && agents.isEmpty {
            w.append("chat.remote_listen is set but chat.remote_agents is empty: no other machine is let in")
        }
        return w
    }
}

/// One address of `chat.remote_listen`, as `doz chat status` and `doz doctor` say it — the same words in both, and true
/// at every moment: `listening` (the server runs with it), `starting` (the daemon has not looked at the new setting yet,
/// or the server is (re)starting with it), `missing` (the daemon's own look at this Mac's interfaces did not find it).
public struct ChatRemoteAddressStatus: Codable, Equatable, Sendable {
    public var address: String
    /// listening · starting · missing
    public var state: String
    public var text: String

    /// Every address of the setting (`wanted`), judged from what the daemon last wrote (`seen`, nil: nothing yet) and
    /// whether its server is ready now.
    public static func of(wanted: [String], seen: ChatRemoteState?, serverReady: Bool, pagePort: Int, linePort: Int) -> [ChatRemoteAddressStatus] {
        wanted.map { a in
            if let s = seen, s.missing.contains(a) {
                return ChatRemoteAddressStatus(address: a, state: "missing",
                                               text: "Not listening on \(a): not an address of this Mac now (is Tailscale up?)")
            }
            if let s = seen, s.listen.contains(a), serverReady {
                let who = s.agents.isEmpty ? "nobody yet (chat.remote_agents is empty)" : s.agents.joined(separator: ", ")
                return ChatRemoteAddressStatus(address: a, state: "listening",
                                               text: "Also listening on \(a) (page port \(pagePort), line port \(linePort)) for \(who) — agents with a token only.")
            }
            // Not looked at yet by the daemon, or the server is (re)starting with it.
            return ChatRemoteAddressStatus(address: a, state: "starting", text: "Remote listening on \(a): starting…")
        }
    }
}
