import DozableChat
import Foundation

// A space's state as it changed during a run — its frames: `<store>/workspaces/W/runs/<run>/frames/NNNNNN.json`, each
// `{at, label, state}` (a `SpaceState`; never an Ask, a question or a program's own message), 0600 in 0700 folders, written
// atomically. Moved by events only, never a timer: a session's status, a sandbox's phase, a write of the workspace's record
// (its rooms closed or opened, up and down among them) poke the recorder; pokes within a second are coalesced (one pending
// recompute); a frame is written only when the document's sha differs from the last one. Bounded: at most 2,000 frames or
// 16 MiB per run — past that only `frames/last.json` is rewritten and the run is marked `framesCapped`, so the end state is
// always kept. Finish (and so down) writes a final frame; the run's archive copies `frames/` (in its manifest, swept,
// hash-checked) and the run's folder is removed only once that archive verifies. `HostCore+SpaceState`,
// `SpaceStateRecorderTests`; docs/engineering/workspaces.md ("Space files").

public final class SpaceStateRecorder: @unchecked Sendable {
    public static let maximumFrames = 2_000
    public static let maximumBytes = 16 << 20
    public static let lastName = "last.json"

    /// A frame's file name: `NNNNNN.json` or `last.json`.
    public static func isFrameName(_ s: String) -> Bool {
        s == lastName || s.range(of: "^[0-9]{6}\\.json$", options: .regularExpression) != nil
    }

    /// One frame as written: when, what changed, the state.
    public struct Frame: Codable, Equatable, Sendable {
        public var at: String
        public var label: String
        public var state: SpaceState
        public init(at: String, label: String, state: SpaceState) { self.at = at; self.label = label; self.state = state }
        /// Its bytes: `{at, label, state}`, the state in the editor's key order.
        public var bytes: Data {
            Data(SpaceState.stringify(.object([JMember("at", .string(at)), JMember("label", .string(label)), JMember("state", state.ordered())])).utf8)
        }
    }

    /// What is known of one run's frames (read from its folder once, then kept).
    struct Memo {
        var count: Int
        var bytes: Int
        var lastSHA: String?
        var capped: Bool
    }

    /// The coalescing window: pokes within it make one recompute.
    public var debounce: Duration
    private let lock = NSLock()
    private var pending = false
    private var all = false
    private var poked: Set<String> = []
    private var labels: [String: String] = [:]
    private var memos: [String: Memo] = [:]

    public init(debounce: Duration = .seconds(1)) { self.debounce = debounce }

    /// A change happened (`workspace` nil: it may touch any of them). True when the caller must schedule the one recompute.
    func poke(_ workspace: String?, _ label: String) -> Bool {
        lock.withLock {
            if let w = workspace { poked.insert(w); labels[w] = label } else { all = true; labels["*"] = label }
            if pending { return false }
            pending = true
            return true
        }
    }

    /// What the recompute is for: every space with an open run (nil), or these; and each one's label.
    func take() -> (Set<String>?, [String: String]) {
        lock.withLock {
            defer { pending = false; all = false; poked = []; labels = [:] }
            return (all ? nil : poked, labels)
        }
    }

    func memo(_ key: String, load: () -> Memo) -> Memo {
        lock.withLock {
            if let m = memos[key] { return m }
            let m = load()
            memos[key] = m
            return m
        }
    }

    func setMemo(_ key: String, _ m: Memo) { lock.withLock { memos[key] = m } }
    func forget(_ key: String) { _ = lock.withLock { memos.removeValue(forKey: key) } }
}
