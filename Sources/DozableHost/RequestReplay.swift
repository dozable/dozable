import CryptoKit
import Darwin
import Foundation

/// `--request-id ID` on the creates (`workspace new`, `worker add`, `workspace adopt`, `permissions grant`): the same request
/// sent again with the same id is answered with its first answer and does nothing again — so an agent that lost an answer
/// (a timeout, a dropped connection, a restart) can simply retry.
///
/// - An id is scoped per command kind (`HostOp`): `r-1` for a `workspace new` and `r-1` for a `worker add` are two ids.
/// - The daemon keeps, per id, a fingerprint of the request's meaningful arguments — one sha256 per field, never a value — and
///   its FIRST SUCCESSFUL answer, for `ttl` (24 h) from that answer. A failed attempt is not recorded: a retry runs for real.
/// - A replay (same kind, id and fields) answers the recorded answer with `"replayed": true` added, exit 0; the same id with
///   other fields is refused (`request-id-reused`, exit 3), the message naming the fields that differ — never a value.
/// - Requests with the same id are serialised on it (`HostCore.requestGate`), so two at once never both run.
///
/// The store: `<store>/requests/` (0700, no link in its path), one file per id — `<sha256(kind NUL id)>.json`, 0600, written
/// atomically — read back after a daemon restart. Bounded: an expired entry is pruned on every write (and never answers), and
/// at most `maximumEntries` are kept (the oldest go first); an answer over `maximumAnswerBytes` is not recorded.
/// `RequestReplayTests`; docs/engineering/workspaces.md, "Retrying a create".
public enum RequestReplay {
    /// The ops that take `--request-id`.
    public static let ops: Set<HostOp> = [.workspaceNew, .workerAdd, .workspaceAdopt, .permissionsGrant]
    public static let ttl: TimeInterval = 24 * 3600
    public static let maximumIDLength = 128
    public static let maximumEntries = 1000
    public static let maximumAnswerBytes = 1 << 20

    /// An id: 1–128 of A-Z a-z 0-9 and `. _ : -` (a UUID, `r-1`, `task-42:new`).
    public static func validate(_ id: String) throws {
        let ok = !id.isEmpty && id.utf8.count <= maximumIDLength
            && id.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._:-".unicodeScalars.contains($0)) }
        guard ok else {
            throw HostError(.invalidValue, "--request-id is 1–\(maximumIDLength) characters of A-Z, a-z, 0-9, '.', '_', ':' and '-'")
        }
    }

    /// The request's meaningful arguments, one sha256 per field (its canonical JSON): the op's own arguments, and who it is
    /// made as. `permissions grant`'s `until` counts as typed (`untilTyped`: `2h` is the same `2h` on a retry).
    public static func fields(of r: HostRequest) throws -> [String: String] {
        var o: [String: JSONValue] = [:]
        switch r.op {
        case .workspaceNew, .workspaceAdopt:
            o = try object(r.workspaceRequest ?? WorkspaceRequest())
        case .workerAdd:
            o = try object(r.workerRequest ?? WorkerRequest())
        case .permissionsGrant:
            o = try object(r.permissionsRequest ?? PermissionsRequest())
            if let typed = o["untilTyped"] { o["until"] = typed; o["untilTyped"] = nil }
        default:
            throw HostError(.usage, "--request-id is taken by workspace new, worker add, workspace adopt and permissions grant")
        }
        if let a = r.actAs { o["actAs"] = .string(a) }
        var out: [String: String] = [:]
        for (k, v) in o where v != .null { out[k] = sha256(try HostWire.encoder.encode(v)) }
        return out
    }

    static func object<T: Encodable>(_ v: T) throws -> [String: JSONValue] {
        if case .object(let o) = try JSONValue(encoding: v) { return o }
        return [:]
    }

    static func sha256(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    /// The fields that differ between the recorded request and this one, as a person names them (`--brief`, `NAME`).
    public static func differences(_ recorded: [String: String], _ now: [String: String], op: HostOp) -> [String] {
        Set(recorded.keys).union(now.keys).filter { recorded[$0] != now[$0] }.map { flagName($0, op: op) }.sorted()
    }

    /// A request field as its flag or argument.
    static func flagName(_ field: String, op: HostOp) -> String {
        switch (op, field) {
        case (.workspaceNew, "name"), (.workspaceAdopt, "name"): return "NAME"
        case (.workspaceAdopt, "agent"): return "AGENT"
        case (.workspaceAdopt, "asName"): return "--as"
        case (.workerAdd, "workspace"): return "WORKSPACE"
        case (.workerAdd, "name"): return "NAME"
        case (.workerAdd, "fromBot"): return "--from-bot"
        case (.workerAdd, "rooms"): return "--room"
        case (.workerAdd, "allowTools"): return "--allow-tool"
        case (.workerAdd, "permissionMode"): return "--permissions"
        case (.permissionsGrant, "agent"): return "SUBJECT"
        case (.permissionsGrant, "words"): return "the role or permissions"
        case (.permissionsGrant, "workspace"): return "--in"
        case (_, "actAs"): return "--as"
        case (_, "folders"): return "--folder"
        case (_, "refs"): return "--ref"
        case (_, "workers"): return "--worker"
        case (_, "adopt"): return "--adopt"
        case (_, "noRoom"): return "--no-room"
        case (_, "newFolder"): return "--new-folder"
        case (_, "project"): return "--from-project"
        default:
            // `managerIsolation` → `--manager-isolation`
            var s = "--"
            for ch in field { if ch.isUppercase { s += "-" + ch.lowercased() } else { s.append(ch) } }
            return s
        }
    }
}

/// One id as kept: its kind, the id, when its first answer was given, the fingerprint and that answer.
public struct RequestReplayEntry: Codable, Equatable, Sendable {
    public var schema = 1
    public var op: String
    public var id: String
    public var at: Date
    public var fields: [String: String]
    public var answer: JSONValue
}

/// `<store>/requests/`: the ids, one file each.
public struct RequestReplayStore: Sendable {
    public let root: String
    let now: @Sendable () -> Date

    public init(store: DozableStore, now: @escaping @Sendable () -> Date = { Date() }) {
        root = WorkspaceStore.resolved(store.root.path) + "/requests"
        self.now = now
    }

    func file(_ op: HostOp, _ id: String) -> String {
        root + "/" + RequestReplay.sha256(Data((op.rawValue + "\u{0}" + id).utf8)) + ".json"
    }

    /// The id's entry while it is kept (nil: none, or expired — an expired one is removed).
    public func read(_ op: HostOp, _ id: String) -> RequestReplayEntry? {
        let f = file(op, id)
        guard MacFenceHostFS.kind(f) != nil,
              let d = try? MacFenceHostFS.readRegular(f, maximum: RequestReplay.maximumAnswerBytes + (64 << 10)),
              let e = try? HostWire.decoder.decode(RequestReplayEntry.self, from: d),
              e.op == op.rawValue, e.id == id else { return nil }
        guard now().timeIntervalSince(e.at) < RequestReplay.ttl else { unlink(f); return nil }
        return e
    }

    /// Keep the first answer of `id` (pruning the expired, and the oldest past the bound, first). An answer too large to
    /// keep is not recorded (the request then runs again on a retry, as with no id).
    public func record(_ op: HostOp, _ id: String, fields: [String: String], answer: JSONValue) throws {
        let e = RequestReplayEntry(op: op.rawValue, id: id, at: now(), fields: fields, answer: answer)
        var d = try HostWire.encoder.encode(e)
        guard d.count <= RequestReplay.maximumAnswerBytes else { return }
        d.append(0x0A)
        try WorkspaceStore.ensureOwnedDirectory(root)
        prune(keeping: RequestReplay.maximumEntries - 1)
        let f = file(op, id)
        try MacFenceHostFS.writeAtomically(d, dir: root, name: (f as NSString).lastPathComponent)
    }

    /// Remove every expired entry, then the oldest until at most `keeping` remain. An entry's file is written once, when its
    /// answer is recorded, so its modification time is its `at` (no file is opened to prune; `read` checks `at` itself).
    public func prune(keeping: Int = RequestReplay.maximumEntries) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root) else { return }
        var live: [(path: String, at: Date)] = []
        for n in names where n.hasSuffix(".json") && !n.hasPrefix(".") {
            let p = root + "/" + n
            var st = stat()
            guard lstat(p, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { continue }
            let at = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec) + TimeInterval(st.st_mtimespec.tv_nsec) / 1e9)
            if now().timeIntervalSince(at) >= RequestReplay.ttl { unlink(p) } else { live.append((p, at)) }
        }
        guard live.count > keeping else { return }
        for x in live.sorted(by: { $0.at < $1.at }).prefix(live.count - max(keeping, 0)) { unlink(x.path) }
    }

    /// The ids kept now (for tests and `doctor`-like looks).
    public func count() -> Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []).filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }.count
    }
}
