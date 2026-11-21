import Darwin
import Foundation

/// The grants that apply everywhere and this Mac's ceiling: `<store>/grants/grants.json` (version 1), and every change to any
/// grant or ceiling as one line of `<store>/grants/log.jsonl`. A workspace's own grants and ceiling live in its record
/// (`workspace.json`, key `permissions`); a bot's ceiling in `bots.json` (`ceilingAnswers`).
///
/// - `grants/` is 0700, made with no link in its path and owned by this user; `grants.json` is 0600, rewritten whole and
///   atomically; the log is appended one line per `write` (`O_APPEND`), a torn line skipped when read.
/// - Reading never writes: `doz permissions show` and `doz why` read it in-process with no daemon. The daemon is the one
///   writer (its permission ops hold the `workspaces` gate). Never a token or a secret. `GrantStoreTests`.
public struct GrantStore: Sendable {
    public let store: DozableStore
    /// `<store>/grants`, resolved (no link in it — `/tmp` is one).
    public let root: String
    public static let maximumFileBytes = 4 << 20
    public static let maximumLogBytes = 16 << 20

    public init(store: DozableStore) {
        self.store = store
        root = WorkspaceStore.resolved(store.root.path) + "/grants"
    }

    public var file: String { root + "/grants.json" }
    public var logFile: String { root + "/log.jsonl" }

    /// The file (an empty one when there is none). A file that cannot be read is an error naming it.
    public func read() throws -> GrantsFile {
        guard MacFenceHostFS.kind(file) != nil else { return GrantsFile() }
        let d: Data
        do { d = try MacFenceHostFS.readRegular(file, maximum: Self.maximumFileBytes) } catch {
            throw HostError(.failed, "the grants cannot be read: \(error)")
        }
        do { return try HostWire.decoder.decode(GrantsFile.self, from: d) } catch {
            throw HostError(.failed, "the grants cannot be read: \(error.localizedDescription)")
        }
    }

    public func readOrEmpty() -> GrantsFile { (try? read()) ?? GrantsFile() }

    /// Replace `grants.json` whole (atomically; every field this build does not know kept as read).
    public func write(_ f: GrantsFile) throws {
        try WorkspaceStore.ensureOwnedDirectory(root)
        var d = try HostWire.prettyEncoder.encode(f)
        d.append(0x0A)
        try MacFenceHostFS.writeAtomically(d, dir: root, name: "grants.json")
    }

    /// Append one line: ONE write.
    public func append(_ e: GrantLogEntry) throws {
        try WorkspaceStore.ensureOwnedDirectory(root)
        let fd = try MacFenceHostFS.open(logFile, O_RDWR | O_CREAT | O_APPEND, 0o600)
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw HostError(.failed, "the grants' log: \(String(cString: strerror(errno)))") }
        try MacFenceHostFS.checkRegular(st, path: logFile, uid: getuid())
        var last: UInt8 = 0x0A
        if st.st_size > 0 { _ = pread(fd, &last, 1, st.st_size - 1) }
        let line = ((try? HostWire.encoder.encode(e)).map { String(decoding: $0, as: UTF8.self) } ?? "{}") + "\n"
        let d = Data(((last == 0x0A ? "" : "\n") + line).utf8)
        let n = d.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }
        guard n == d.count else { throw HostError(.failed, "the grants' log: a short write") }
        TimelineSignal.poke(store.root.path, .grants)             // 747: the timeline reads the new line
    }

    /// The log's lines, oldest first (a torn one skipped).
    public func log() -> [GrantLogEntry] {
        guard MacFenceHostFS.kind(logFile) != nil, let d = try? MacFenceHostFS.readRegular(logFile, maximum: Self.maximumLogBytes) else { return [] }
        return d.split(separator: 0x0A).compactMap { try? HostWire.decoder.decode(GrantLogEntry.self, from: Data($0)) }
    }
}

/// Who a permission question is about, resolved from what a person typed (`bot2`, `otto`, `bot:otto`, `agent:demo/bot1`) and
/// the workspace it is asked in.
public struct GrantWho: Equatable, Sendable {
    public var name: String
    /// The workspace it is an agent of (nil: none).
    public var home: String?
    public var bot: String?
    public var recordRoles: [HeldRole]
    /// Its entry acts as you (an unfenced manager or worker): what it does is a promise.
    public var actsAsYou: Bool
    public init(name: String, home: String?, bot: String?, recordRoles: [HeldRole] = [], actsAsYou: Bool = false) {
        self.name = name; self.home = home; self.bot = bot; self.recordRoles = recordRoles; self.actsAsYou = actsAsYou
    }

    /// The subject a grant to it is written for: its bot when it is one, else the agent of its workspace.
    public var subject: GrantSubject? {
        if let b = bot { return .bot(b) }
        if let h = home { return .agent(h, name) }
        return nil
    }
}

/// Reads what a decision needs from the store — the grants file, the workspace's record, `bots.json`, the chat directory's
/// human — and hands `GrantDecision.decide` its facts. Reading only; the same in the daemon and in-process.
public struct GrantFactsReader: Sendable {
    public let store: DozableStore
    public init(store: DozableStore) { self.store = store }

    var workspaces: WorkspaceStore { WorkspaceStore(store: store) }
    var bots: BotStore { BotStore(store: store) }

    /// An agent of `rec` as a `GrantWho` (its record's role is its role there).
    public static func who(_ a: WorkspaceAgent, in rec: WorkspaceRecord) -> GrantWho {
        GrantWho(name: a.name, home: rec.name, bot: a.bot, recordRoles: [HeldRole(role: a.role, workspace: rec.name)], actsAsYou: a.actsAsYou)
    }

    /// `name` (as typed) in workspace `w` (nil: wherever it is the one agent of that name).
    public func resolve(_ name: String, in w: String?) throws -> GrantWho {
        let file = bots.readOrEmpty()
        if let s = GrantSubject(stored: name) {
            switch s {
            case .bot(let b):
                guard let r = file.bot(b), !r.retired else { throw HostError(.notFound, "there is no bot \(b) (doz bot ls)") }
                return try resolve(b, in: w)
            case .agent(let ws, let n):
                guard let rec = try workspaces.read(ws) else { throw HostError(.notFound, "\(ws) is not a workspace (doz workspace ls)") }
                if let a = rec.agents.first(where: { $0.name == n && $0.endedAt == nil }) { return Self.who(a, in: rec) }
                return GrantWho(name: n, home: ws, bot: nil)
            case .role:
                throw HostError(.invalid, "\(name): a question is about one agent or bot, not a role")
            }
        }
        if let w {
            guard let rec = try workspaces.read(w) else { throw HostError(.notFound, "\(w) is not a workspace (doz workspace ls)") }
            if let a = rec.agents.first(where: { ($0.name == name || $0.bot == name) && $0.endedAt == nil }) { return Self.who(a, in: rec) }
            if let b = file.bot(name), !b.retired { return GrantWho(name: name, home: nil, bot: name) }
            throw HostError(.notFound, "\(w) has no agent \(name), and there is no bot \(name) (doz workspace show \(w), doz bot ls)")
        }
        let found = workspaces.records().flatMap { rec in
            rec.agents.filter { ($0.name == name || $0.bot == name) && $0.endedAt == nil }.map { (rec, $0) }
        }
        if found.count == 1 { return Self.who(found[0].1, in: found[0].0) }
        if found.count > 1 {
            throw HostError(.invalid, "\(name) is in \(found.map(\.0.name).joined(separator: ", ")) — which one? (--in W)")
        }
        if let b = file.bot(name), !b.retired { return GrantWho(name: name, home: nil, bot: name) }
        throw HostError(.notFound, "there is no agent or bot \(name) (doz workspace ls, doz bot ls)")
    }

    /// The facts for `who` acting in workspace `w` (nil: outside every workspace).
    public func facts(_ who: GrantWho, workspace w: String?, now: Date = Date()) -> GrantFacts {
        let file = GrantStore(store: store).readOrEmpty()
        let rec = w.flatMap { try? workspaces.read($0) }
        let bot = who.bot.flatMap { bots.readOrEmpty().bot($0) }
        let directory = try? ChatDirectory.load(ChatPaths(store: store))
        return GrantFacts(grants: file.grants + (rec?.permissions?.grants ?? []), macCeiling: GrantCeiling.caps(file.ceiling),
                          botCeiling: GrantCeiling.caps(bot?.ceilingAnswers), botIsolationCeiling: bot?.isolation.ceiling,
                          workspaceCeiling: GrantCeiling.caps(rec?.permissions?.ceiling), now: now, owner: directory?.human,
                          manager: rec?.manager?.name, deciders: directory?.participants.filter(\.isDecider).map(\.name) ?? [])
    }

    /// The decision for `who` and `perm` in `w` (and room `room`).
    public func decide(_ who: GrantWho, perm: String, workspace w: String?, room: String? = nil, now: Date = Date()) -> GrantDecision {
        let q = GrantQuery(name: who.name, home: who.home, bot: who.bot, perm: perm, workspace: w, room: room, recordRoles: who.recordRoles)
        return GrantDecision.decide(q, facts(who, workspace: w, now: now))
    }
}
