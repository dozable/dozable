import Foundation
import DozableKit

// 635 — the host-side session registry: which sessions each sandbox has, kept from the host's OWN events, so the
// overview (`ls`, polled every 3 s by the dashboard) can list every sandbox's sessions without a guest call ("a
// poller never counts sessions": `deckhold ls` connects to every holder, and each connect is a line in the guest's
// log).
//
// What feeds it (HostCore+Sessions):
// - a session opened or answered "already running" (`openSessionLocked`), or attached (`sessionAttached`);
// - its program's end: the status watcher's `.ended` (only for the epoch that watcher was opened under — a restart's
//   late `.ended` of the OLD program must not remove the new one), `session-end`, the attach relay's EXIT;
// - every guest list the host makes ANYWAY (a transition's `refreshStatusWatches`, the page's `detail` / `sessions`,
//   the open path, the periodic screen capture) — `reconcile`, which never drops a session registered after the list
//   began (`mark`);
// - off / removed / reset / shutdown / died with its host: `clear`.
//
// What `ls` shows is `view`: running → this memory (until the first guest list of this run: the saved screens);
// paused, asleep, hibernated → the saved screens on disk (exactly the live set when it stopped running — the capture
// is the first step); anything else → none. Pure: no I/O, no actor — `SessionRegistryTests`.
//
// Staleness, by design: a session that ends with nobody watching (its holder is older than the status protocol and
// drops WATCH, or the watcher gave up) or one started from inside the guest is corrected at the next list the host
// makes anyway — at once for the page's own sandbox, else within `host.screen_capture_minutes`. Never a new guest call.

/// One session as the overview carries it — nothing that moves by itself (an age, a byte count, a viewer count):
/// the overview is compared poll to poll for `changed`.
public struct SessionBrief: Codable, Equatable, Sendable {
    public var name: String
    /// The program's name (the basename of what it runs: `claude`, `bash`, `npm`) — never its command line.
    public var program: String
    /// The sandbox's own session (its agent's, `doz up`'s).
    public var isDefault: Bool?
    /// When the host opened it (`sessions.json`), else when it first saw it.
    public var openedAt: Date?
    /// From its saved screen: the sandbox is paused, asleep or hibernated.
    public var saved: Bool?
    public init(name: String, program: String, isDefault: Bool? = nil, openedAt: Date? = nil, saved: Bool? = nil) {
        self.name = name; self.program = program; self.isDefault = isDefault; self.openedAt = openedAt; self.saved = saved
    }
}

public struct SessionRegistry: Sendable {
    public struct Entry: Equatable, Sendable {
        public var program: String
        public var firstSeen: Date
        /// The registry's epoch when this entry was (re)registered.
        public var epoch: UInt64
    }

    /// At most this many sessions per sandbox in the overview (the rest are counted: `more`).
    public static let maximumListed = SavedScreens.maximumSessions
    public static let maximumProgramLength = 64

    /// Bumped by every registration; an entry remembers the epoch it was registered under.
    public private(set) var epoch: UInt64 = 0
    private var live: [String: [String: Entry]] = [:]
    /// Sandboxes whose set came from a guest list since they last came to run.
    private var listed: Set<String> = []

    public init() {}

    /// A program was started under this session name (a new epoch: a watcher of an earlier program of the same
    /// name no longer removes it). Returns the epoch it is registered under.
    @discardableResult
    public mutating func opened(_ sandbox: String, _ session: String, program: String, now: Date = Date()) -> UInt64 {
        epoch += 1
        live[sandbox, default: [:]][session] = Entry(program: Self.programName(program), firstSeen: now, epoch: epoch)
        return epoch
    }

    /// A session was found running (an "already running" answer, an attach): registered when unknown, else kept as
    /// it is (same epoch).
    public mutating func seen(_ sandbox: String, _ session: String, program: String?, now: Date = Date()) {
        guard live[sandbox]?[session] == nil else { return }
        epoch += 1
        live[sandbox, default: [:]][session] = Entry(program: Self.programName(program ?? session), firstSeen: now, epoch: epoch)
    }

    /// Its program ended. `ifEpoch`: only when the entry is still the one registered under that epoch (a status
    /// watcher's view — a newer registration means the session was opened again since). nil: unconditionally.
    public mutating func ended(_ sandbox: String, _ session: String, ifEpoch: UInt64? = nil) {
        guard let e = live[sandbox]?[session] else { return }
        if let want = ifEpoch, e.epoch != want { return }
        live[sandbox]?[session] = nil
        if live[sandbox]?.isEmpty == true { live[sandbox] = nil }
    }

    /// A guest list the host made anyway. Every live session in it is registered (a session started inside the
    /// guest), and an entry missing from it is dropped — only when it was registered no later than `mark` (the
    /// epoch read BEFORE the list was asked for), so a session opened while the list ran is never lost.
    public mutating func reconcile(_ sandbox: String, live list: [SessionInfo], mark: UInt64, now: Date = Date()) {
        let running = list.filter { !$0.isEnded }
        let names = Set(running.map(\.name))
        for (session, e) in live[sandbox] ?? [:] where !names.contains(session) && e.epoch <= mark {
            live[sandbox]?[session] = nil
        }
        for s in running where live[sandbox]?[s.name] == nil {
            epoch += 1
            live[sandbox, default: [:]][s.name] = Entry(program: Self.programName(Self.firstWord(s.command)), firstSeen: now, epoch: epoch)
        }
        if live[sandbox]?.isEmpty == true { live[sandbox] = nil }
        listed.insert(sandbox)
    }

    /// The sandbox came to run: until a guest list of this run, `view` shows its saved screens.
    public mutating func cameToRun(_ sandbox: String) { listed.remove(sandbox) }

    /// Off, removed, reset: no sessions.
    public mutating func clear(_ sandbox: String) {
        live[sandbox] = nil
        listed.remove(sandbox)
    }

    /// The names registered for a sandbox (tests, diagnostics).
    public func names(_ sandbox: String) -> [String] { (live[sandbox] ?? [:]).keys.sorted() }
    public func entry(_ sandbox: String, _ session: String) -> Entry? { live[sandbox]?[session] }
    public func hasListed(_ sandbox: String) -> Bool { listed.contains(sandbox) }

    /// What `ls` carries for a sandbox in `phase`: the sessions (default first, then by when opened, then by name)
    /// and how many more there are beyond `maximumListed`.
    public func view(_ sandbox: String, phase: Phase, saved: [SavedScreenInfo], records: SessionRecords,
                     defaultSession: String) -> (list: [SessionBrief], more: Int) {
        var out: [SessionBrief] = []
        let fromSaved: Bool
        switch phase {
        case .running: fromSaved = !listed.contains(sandbox)
        case .paused, .asleep, .hibernated: fromSaved = true
        default: return ([], 0)
        }
        if fromSaved {
            for s in saved {
                let rec = records.sessions[s.session]
                let program = rec?.argv.first ?? Self.firstWord(s.command)
                out.append(SessionBrief(name: s.session, program: Self.programName(program), isDefault: s.session == defaultSession ? true : nil,
                                        openedAt: rec?.openedAt, saved: phase == .running ? nil : true))
            }
        } else {
            for (session, e) in live[sandbox] ?? [:] {
                let rec = records.sessions[session]
                out.append(SessionBrief(name: session, program: rec.flatMap { $0.argv.first }.map(Self.programName) ?? e.program,
                                        isDefault: session == defaultSession ? true : nil, openedAt: rec?.openedAt ?? e.firstSeen))
            }
        }
        out.sort { a, b in
            if (a.isDefault == true) != (b.isDefault == true) { return a.isDefault == true }
            switch (a.openedAt, b.openedAt) {
            case let (x?, y?) where x != y: return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.name < b.name
            }
        }
        let more = max(0, out.count - Self.maximumListed)
        return (Array(out.prefix(Self.maximumListed)), more)
    }

    /// A program as shown: the basename of its first word, printable ASCII only, capped.
    public static func programName(_ raw: String) -> String {
        let base = raw.split(separator: "/").last.map(String.init) ?? raw
        let kept = base.unicodeScalars.filter { $0.isASCII && $0.value > 0x20 && $0.value < 0x7F }
        let s = String(String.UnicodeScalarView(kept.prefix(maximumProgramLength)))
        return s.isEmpty ? "program" : s
    }

    static func firstWord(_ command: String) -> String {
        command.split(separator: " ", omittingEmptySubsequences: true).first.map(String.init) ?? command
    }
}
