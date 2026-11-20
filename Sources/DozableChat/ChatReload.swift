import CryptoKit
import Darwin
import Foundation

// A participant change without a restart (docs/engineering/chat.md, "The control channel").
//
// Only a server the daemon runs has the channel: `--control-fd N` (accepted only with `--supervised` and
// `--token-hashes`) is one end of a socketpair the supervisor made. It writes one line, `{"version":1,"reload":"<sha>"}`,
// where sha is the SHA-256 of the config file's bytes followed by the token-hashes file's bytes as it wrote them; the
// server reads both files again, checks they are those bytes, judges the config with the loader every start uses, refuses
// unless only the participants changed, applies the participants and the hashes under the core's lock, and answers one
// line: `{"reloaded":"<sha>"}` or `{"refused":"<why>"}`. There is no signal, file or HTTP way to ask for it: `doz chat
// serve` as the conformance runner starts it has no channel, and SIGHUP still stops it.
//
// A reload must leave the server exactly as a restart on the same files would (`ChatLiveReloadTests`, the differential
// test): the participants and the registered sessions as a start reads them, the rooms' members recomputed from what the
// data folder keeps. What a restart would have cut is cut: a removed participant's token (or a replaced one) is refused
// at once, its waiting receive ends with 401, a line-port connection it authenticated is closed at its next line, and its
// presence goes.

public enum ChatReload {
    public enum Outcome: Equatable, Sendable {
        case reloaded(String)
        case refused(String)

        /// The answer line.
        public var line: [UInt8] {
            switch self {
            case .reloaded(let s): return ChatJSON.encode(.object([JMember("reloaded", .string(s))])) + [0x0A]
            case .refused(let w): return ChatJSON.encode(.object([JMember("refused", .string(w))])) + [0x0A]
            }
        }
    }

    /// The SHA-256 (hex) the supervisor and the server agree on: the config's bytes, then the token hashes' bytes.
    public static func sha(config: some DataProtocol, tokens: some DataProtocol) -> String {
        var h = SHA256()
        h.update(data: Data(config))
        h.update(data: Data(tokens))
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// One request line, answered. A request that is not one is refused (nothing is changed).
    public static func answer(_ raw: [UInt8], core: ChatServerCore, configPath: String, overrides: ChatConfig.Overrides,
                              hashesPath: String) -> Outcome {
        guard let v = try? ChatJSON.parse(raw), v.isObject,
              (try? v.field("version")?.goInt("version")) == 1,
              let want = v.field("reload")?.stringValue, ChatSecrets.isHashHex(want) else {
            return .refused("not a reload request")
        }
        return perform(core: core, configPath: configPath, overrides: overrides, hashesPath: hashesPath, want: want)
    }

    /// Reads the two files again and applies them when only the participants (and the hashes) changed.
    public static func perform(core: ChatServerCore, configPath: String, overrides: ChatConfig.Overrides, hashesPath: String,
                               want: String) -> Outcome {
        guard let configBytes = FileManager.default.contents(atPath: configPath) else { return .refused("the config cannot be read") }
        let tokenBytes: Data
        do { tokenBytes = try ChatSecrets.readHashesFile(path: hashesPath) } catch { return .refused("\(error)") }
        let got = sha(config: configBytes, tokens: tokenBytes)
        guard got == want else { return .refused("the files are not the ones the reload names (they changed meanwhile)") }
        let new: ChatConfig
        let hashes: ChatSecrets
        do {
            new = try ChatConfig.resolve(data: configBytes, overrides)
            hashes = try ChatSecrets.parseHashes(tokenBytes, path: hashesPath)
        } catch { return .refused("\(error)") }
        if let why = refusal(old: core.config, new: new) { return .refused(why) }
        core.apply(participants: new.participants, hashes: hashes)
        return .reloaded(got)
    }

    /// Why a config cannot be taken without a restart (nil: it can) — anything but its participants changed. Pure.
    public static func refusal(old: ChatConfig, new: ChatConfig) -> String? {
        var a = old, b = new
        a.participants = []
        b.participants = []
        return a == b ? nil : "more than the participants changed: a restart takes it"
    }

    /// Serves the control channel on a thread of its own until the other end closes it. Each line is answered in order.
    public static func serve(fd: Int32, core: ChatServerCore, configPath: String, overrides: ChatConfig.Overrides, hashesPath: String,
                             log: ChatLog, pending: [UInt8] = []) {
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        let t = Thread {
            var buf: [UInt8] = pending
            var chunk = [UInt8](repeating: 0, count: 4096)
            var first = !pending.isEmpty
            while true {
                if !first {
                    let n = read(fd, &chunk, chunk.count)
                    if n < 0 && errno == EINTR { continue }
                    if n <= 0 { break }
                    buf += chunk[0..<n]
                }
                first = false
                if buf.count > 64 << 10 { log("chat: the control channel sent a line too long; closed"); break }
                while let nl = buf.firstIndex(of: 0x0A) {
                    let line = Array(buf[..<nl])
                    buf.removeSubrange(...nl)
                    // The closed set and a room's removal (ChatRoomControl.swift).
                    if let v = try? ChatJSON.parse(line), v.isObject, (try? v.field("version")?.goInt("version")) == 1,
                       v.field("reload") == nil, let other = ChatRoomControl.answer(v, core: core) {
                        ChatRoomControl.write(fd, other)
                        continue
                    }
                    let out = answer(line, core: core, configPath: configPath, overrides: overrides, hashesPath: hashesPath)
                    switch out {
                    case .reloaded: log("chat: took a change of participants without a restart")
                    case .refused(let why): log("chat: a reload was refused: \(why)")
                    }
                    let bytes = out.line
                    var at = 0
                    while at < bytes.count {
                        let w = bytes[at...].withUnsafeBytes { write(fd, $0.baseAddress!, $0.count) }
                        if w < 0 && errno == EINTR { continue }
                        if w <= 0 { break }
                        at += w
                    }
                }
            }
            close(fd)
        }
        t.name = "chat.control"
        t.start()
    }
}

extension ChatServerCore {
    /// Takes new participants and token hashes, as a start on the same files would have them: the registered sessions
    /// and the rooms' members are read again from the data folder the way `load` reads them. Answers the names whose
    /// token stopped being valid (removed, or given a new one): their waiting receives end, their presence goes.
    @discardableResult
    public func apply(participants new: [ChatParticipant], hashes: ChatSecrets) -> [String] {
        let revoked: [String] = lock.withLock {
            let agentsFile = readJSON("agents.json")
            let roomsFile = readJSON("rooms.json")
            let reg = Self.registered(agentsFile, besides: new)
            let all = new + reg.participants
            let before = storedSecrets.tokenHashes
            var gone = participants.map(\.name).filter { n in !all.contains { $0.name == n } }
            for (n, h) in before where hashes.tokenHashes[n] != nil && hashes.tokenHashes[n] != h && !gone.contains(n) { gone.append(n) }
            participants = all
            agentTokens = reg.tokens
            rooms = Self.memberships(roomsFile, base: config.rooms, participants: all)
            storedSecrets.setTokenHashes(hashes.tokenHashes)
            for n in gone {
                pollEpoch[n, default: 0] += 1
                for k in [\ChatLiveState.seen, \.pending, \.woken, \.thinking, \.typing] as [WritableKeyPath<ChatLiveState, [String: Double]>] {
                    live[keyPath: k][n] = nil
                }
            }
            return gone
        }
        for n in revoked { wakePoll(n) }
        publishPresence()
        checkAllDeciders()   // a decider removed: an open ask may have no one left to decide it
        return revoked
    }

    /// The reload count a waiting receive started under (ChatLongPoll).
    func pollEpochOf(_ name: String) -> Int { lock.withLock { pollEpoch[name] ?? 0 } }

    /// Whether a receive started under `epoch` may still be answered: the participant was not removed or given a new
    /// token since.
    func pollStillValid(_ name: String, _ epoch: Int) -> Bool { lock.withLock { (pollEpoch[name] ?? 0) == epoch } }

    /// Whether `name` still holds the token whose hash is `hash` (a line-port connection checks it at every line).
    func stillHolds(_ name: String, hash: String) -> Bool {
        lock.withLock {
            guard participants.contains(where: { $0.name == name }), let have = storedSecrets.tokenHashes[name] else { return false }
            return ChatSecrets.constantTimeEqual(have, hash)
        }
    }

    /// What a start would have in memory, for the differential test: the participants, the rooms and their members, the
    /// registered sessions' token hashes, the participants' token hashes.
    public func membershipSnapshot() -> (participants: [ChatParticipant], rooms: [String: [String]], sessions: [String: String], hashes: [String: String]) {
        lock.withLock { (participants, rooms, agentTokens, storedSecrets.tokenHashes) }
    }
}
