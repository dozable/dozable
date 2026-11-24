import Darwin
import Foundation

// The closed set and a room's removal, over the daemon's control channel (`--control-fd`, ChatReload.swift) — never an
// HTTP route, a file or a slash command. docs/engineering/chat.md ("The control channel").
//
// - `{"version":1,"id":"…","closed":{"rooms":{"R":"W"},"reasons":false}}`: the WHOLE closed set (room → the workspace
//   whose finish closed it), held in memory only — the daemon's records are the truth, and it sends the set again after
//   every start (before the server says it is ready) and after every change. A post, edit, reaction or command (but
//   `/leave`, `/rooms` and a human's `/archive` and `/unarchive`) in a closed room is refused with the status the reference
//   gives an archived room and Dozable's words; `reason: "space-down"` is an extra field only with `reasons` true. Archived
//   outranks closed. Answered `{"id":"…","closed":{"R":LASTSEQ}}`: each room's last seq taken under the close gate — no
//   post is between its check and its store while the set changes, so the seq is exact.
// - `{"version":1,"id":"…","roomRemove":{"room":"R","id":"rm_…","lastSeq":N}}`: under the core's lock, refused when the
//   room's last seq moved; else its store closed, its memberships, archived flag, hold and app dropped, its members'
//   waiting receives ended (with nothing, as for a room they are not in), what still waited for delivery in it dropped,
//   `rooms/<room>.db`, `-wal` and `-shm` unlinked and the attachments no other room names removed. Answered
//   `{"id":"…","removed":"R"}` or `{"id":"…","refused":"…"}`. The server keeps running.

/// A reader-writer lock (posts read, a change of the closed set writes).
public final class ChatRWLock: @unchecked Sendable {
    private var l = pthread_rwlock_t()
    public init() { pthread_rwlock_init(&l, nil) }
    deinit { pthread_rwlock_destroy(&l) }
    public func read() { pthread_rwlock_rdlock(&l) }
    public func write() { pthread_rwlock_wrlock(&l) }
    public func done() { pthread_rwlock_unlock(&l) }
}

public enum ChatRoomControl {
    public static let reasonWord = "space-down"

    /// The closed set's value for a loose room the owner closed by hand.
    public static let looseOwner = "_"

    /// Dozable's words for a closed room.
    public static func closedText(room: String, workspace: String) -> String {
        if workspace == looseOwner { return "room \(room) is closed by the owner. It can still be read; the owner can open it with doz chat room open \(room) --loose" }
        return "room \(room) is closed: its workspace \(workspace) is finished. It can still be read; the owner can reopen it with doz workspace reopen \(workspace)"
    }

    /// One control line that is not a reload: answered (nil: not one of these).
    public static func answer(_ v: JValue, core: ChatServerCore) -> [UInt8]? {
        let id = v.field("id")?.stringValue ?? ""
        func line(_ members: [String: JValue]) -> [UInt8] {
            var m = members
            m["id"] = .string(id)
            return ChatJSON.encode(.map(m)) + [0x0A]
        }
        if let c = v.field("closed"), c.isObject {
            var set: [String: String] = [:]
            if case .object(let rooms)? = c.field("rooms") {
                for e in rooms { if let w = e.value.stringValue, chatIsRoomName(e.key) { set[e.key] = w } }
            }
            let seqs = core.setClosed(set, reasons: c.field("reasons")?.boolValue ?? false)
            return line(["closed": .map(seqs.mapValues { JValue.int($0) })])
        }
        // 766: Dozable's own ask (a proposal to change a workspace's work description) and its close (ChatSystemAsks.swift).
        if let a = v.field("systemAsk"), a.isObject {
            guard let room = a.field("room")?.stringValue, chatIsRoomName(room), let msgID = a.field("msgId")?.stringValue,
                  let question = a.field("question")?.stringValue, let raw = a.field("ask"),
                  let spec = (try? ChatAskSpec.read(raw)) ?? nil else { return line(["refused": .string("not a system ask")]) }
            switch core.systemAsk(room: room, msgID: msgID, question: question, spec: spec) {
            case .success(let r): return line(["asked": .map(["msgId": .string(r.msgID), "number": .int(Int64(r.number))])])
            case .failure(let e): return line(["refused": .string(e.description)])
            }
        }
        if let a = v.field("systemAskClose"), a.isObject {
            guard let room = a.field("room")?.stringValue, chatIsRoomName(room), let msgID = a.field("msgId")?.stringValue else {
                return line(["refused": .string("not a system ask's close")])
            }
            switch core.systemAskClose(room: room, msgID: msgID, outcome: a.field("outcome")?.stringValue ?? "",
                                       decision: a.field("decision")?.stringValue) {
            case .success(let state): return line(["closedAsk": .string(state)])
            case .failure(let e): return line(["refused": .string(e.description)])
            }
        }
        if let r = v.field("roomRemove"), r.isObject {
            guard let room = r.field("room")?.stringValue, chatIsRoomName(room),
                  let last = (try? r.field("lastSeq")?.goInt("lastSeq")) ?? nil else { return line(["refused": .string("not a room removal")]) }
            switch core.removeRoom(room, lastSeq: Int64(last), id: r.field("id")?.stringValue ?? "") {
            case .success: return line(["removed": .string(room)])
            case .failure(let e): return line(["refused": .string(e.description)])
            }
        }
        return nil
    }

    /// At start, before the listeners: the first line on the control channel — the daemon sends the closed set right after
    /// it starts the server. Waits at most `seconds`; answers what was read past that line (the rest of the channel's
    /// bytes, handed to `ChatReload.serve`).
    public static func takeFirst(fd: Int32, core: ChatServerCore, seconds: Double, log: ChatLog) -> [UInt8] {
        var buf: [UInt8] = []
        let until = Date().timeIntervalSince1970 + seconds
        var chunk = [UInt8](repeating: 0, count: 4096)
        while !buf.contains(0x0A) {
            let left = until - Date().timeIntervalSince1970
            if left <= 0 { log("chat: no closed set came on the control channel at the start — every room is open"); return buf }
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let r = Darwin.poll(&p, 1, Int32(max(1, left * 1000)))
            if r < 0 && errno == EINTR { continue }
            if r <= 0 { continue }
            let n = read(fd, &chunk, chunk.count)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return buf }
            buf += chunk[0..<n]
            if buf.count > 64 << 10 { return buf }
        }
        let nl = buf.firstIndex(of: 0x0A)!
        let first = Array(buf[..<nl])
        let rest = Array(buf[(nl + 1)...])
        if let v = try? ChatJSON.parse(first), v.isObject, (try? v.field("version")?.goInt("version")) == 1, let out = answer(v, core: core) {
            write(fd, out)
            log("chat: took the closed set at the start (\(core.closedRooms().count) room\(core.closedRooms().count == 1 ? "" : "s"))")
            return rest
        }
        return buf   // not a closed set: the serve loop answers it
    }

    public static func write(_ fd: Int32, _ bytes: [UInt8]) {
        var at = 0
        while at < bytes.count {
            let w = bytes[at...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }
            if w < 0 && errno == EINTR { continue }
            if w <= 0 { break }
            at += w
        }
    }
}

extension ChatServerCore {
    /// The refusal a closed room gives (nil: not closed). Archived is checked first by every caller.
    func closedRefusal(_ room: String) -> ChatReceipt? {
        let (w, reasons): (String?, Bool) = lock.withLock { (closed[room], refusalReasons) }
        guard let w else { return nil }
        var r = ChatReceipt.refused(ChatRoomControl.closedText(room: room, workspace: w))
        if reasons { r.reason = ChatRoomControl.reasonWord }
        return r
    }

    public func closedRooms() -> [String: String] { lock.withLock { closed } }

    /// The whole closed set taken (under the close gate's write: no post is between its check and its store), answered with
    /// each closed room's last seq.
    @discardableResult
    public func setClosed(_ set: [String: String], reasons: Bool) -> [String: Int64] {
        let out: [String: Int64] = {
            closeGate.write()
            defer { closeGate.done() }
            let known = lock.withLock { () -> Set<String> in
                closed = set.filter { rooms[$0.key] != nil }
                refusalReasons = reasons
                return Set(closed.keys)
            }
            var out: [String: Int64] = [:]
            for r in known { out[r] = (try? store(r))?.lastSeq() ?? 0 }
            return out
        }()
        // A closed room leaves no ask waiting — after the gate is let go (the lock order, ChatAsks.swift).
        expireClosedRooms(Array(out.keys))
        return out
    }

    /// A room removed for good (the daemon's `roomRemove`): refused when its last seq is not `lastSeq`.
    public func removeRoom(_ room: String, lastSeq: Int64, id: String) -> Result<Void, ChatAPIError> {
        func no(_ s: String) -> Result<Void, ChatAPIError> { .failure(ChatAPIError(status: 409, description: s)) }
        closeGate.write()
        defer { closeGate.done() }
        guard hasRoom(room) else { return no("no room \(room)") }
        guard let st = try? store(room) else { return no("the room \(room) cannot be opened") }
        let now = st.lastSeq()
        guard now == lastSeq else { return no("the room \(room) changed since it was archived (its last message is \(now), not \(lastSeq))") }
        let files = st.attachmentIDs()
        let (members, all, arch, hold): ([String], [String: [String]], [String: Bool], [String: Int]) = lock.withLock {
            let m = rooms[room] ?? []
            rooms[room] = nil
            archived[room] = nil
            holds[room] = nil
            apps[room] = nil
            closed[room] = nil
            agentRun[room] = nil
            stores[room] = nil
            for n in m { roomGoneEpoch[n, default: 0] += 1 }
            return (m, rooms, archived, holds)
        }
        askTimers.cancelRoom(room)   // its asks go with it; the numbers they had stay used
        st.close()
        saveRooms(all)
        save("archived.json", .map(arch.mapValues { JValue.bool($0) }))
        save("holds.json", .map(hold.mapValues { JValue.int(Int64($0)) }))
        let base = (file("rooms") as NSString).appendingPathComponent(room + ".db")
        for suffix in ["", "-wal", "-shm"] { unlink(base + suffix) }
        // Its attachments that no other room names.
        for fid in files {
            var used = false
            for other in roomNames() { if let o = try? store(other), o.usesFile(fid, except: "") { used = true; break } }
            if !used { try? FileManager.default.removeItem(atPath: (filesDir as NSString).appendingPathComponent(fid)) }
        }
        for n in members { wakePoll(n) }
        log("chat: the room \(room) was removed for good (\(id.isEmpty ? "no id" : id)); its archive is the daemon's")
        publishPresence()
        return .success(())
    }

    func roomGoneEpochOf(_ name: String) -> Int { lock.withLock { roomGoneEpoch[name] ?? 0 } }
}
