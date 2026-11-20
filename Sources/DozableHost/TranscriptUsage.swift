import Foundation

// What an agent's conversations say it used, read from the archived copies only (never a live file): per model the
// calls, the tokens — new input, cache write, cache read, output — and the active minutes (the gaps between its lines
// under 5 minutes, summed). Claude Code writes one line per content block of an answer, each with the same message id and
// usage: a message is counted once. The cost is "—": Dozable does not know the price. Pure (`TranscriptUsageTests`).

public enum TranscriptUsage {
    public struct Model: Codable, Equatable, Sendable {
        public var model: String
        public var calls = 0
        public var tokensNew = 0
        public var tokensCacheWrite = 0
        public var tokensCacheRead = 0
        public var tokensOut = 0
        public init(model: String) { self.model = model }
    }

    public struct Agent: Codable, Equatable, Sendable {
        public var agent: String
        public var role: String
        /// The conversations read.
        public var files: Int
        /// Turns: messages a person (or the room) sent it — user lines that are not a tool's result.
        public var turns: Int
        public var activeMinutes: Int
        public var models: [Model]
        /// "—": not known.
        public var cost: String
        /// Why there is nothing (not started, elsewhere, no conversation kept).
        public var note: String?
        public init(agent: String, role: String, files: Int = 0, turns: Int = 0, activeMinutes: Int = 0, models: [Model] = [], cost: String = "—", note: String? = nil) {
            self.agent = agent; self.role = role; self.files = files; self.turns = turns; self.activeMinutes = activeMinutes; self.models = models
            self.cost = cost; self.note = note
        }
        public var calls: Int { models.map(\.calls).reduce(0, +) }
    }

    public struct Totals: Codable, Equatable, Sendable {
        public var calls = 0, tokensNew = 0, tokensCacheWrite = 0, tokensCacheRead = 0, tokensOut = 0, activeMinutes = 0, turns = 0
    }

    /// `usage.json` (version 1).
    public struct Report: Codable, Equatable, Sendable {
        public var version = 1
        public var run: String
        public var window: RunWindow
        public var agents: [Agent]
        public var totals: Totals
    }

    /// One agent's usage over its conversations' bytes, lines at or after `since` (nil: all).
    public static func agent(_ name: String, role: String, files: [Data], since: Date? = nil, until: Date? = nil) -> Agent {
        var models: [String: Model] = [:]
        var seen = Set<String>()
        var times: [Date] = []
        var turns = 0
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        for data in files {
            for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
                guard let o = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { continue }
                var at: Date?
                if let t = o["timestamp"] as? String { at = iso.date(from: t) ?? isoPlain.date(from: t) }
                if let at, let since, at < since { continue }
                if let at, let until, at > until { continue }
                if let at { times.append(at) }
                let type = o["type"] as? String
                let msg = o["message"] as? [String: Any]
                if type == "user", let m = msg {
                    if m["content"] is String { turns += 1 }
                    else if let blocks = m["content"] as? [[String: Any]], !blocks.contains(where: { $0["type"] as? String == "tool_result" }) { turns += 1 }
                }
                guard type == "assistant", let m = msg, let u = m["usage"] as? [String: Any] else { continue }
                let id = (m["id"] as? String) ?? (o["uuid"] as? String) ?? UUID().uuidString
                guard seen.insert(id).inserted else { continue }
                let name = (m["model"] as? String) ?? "unknown"
                var e = models[name] ?? Model(model: name)
                e.calls += 1
                e.tokensNew += u["input_tokens"] as? Int ?? 0
                e.tokensCacheWrite += u["cache_creation_input_tokens"] as? Int ?? 0
                e.tokensCacheRead += u["cache_read_input_tokens"] as? Int ?? 0
                e.tokensOut += u["output_tokens"] as? Int ?? 0
                models[name] = e
            }
        }
        return Agent(agent: name, role: role, files: files.count, turns: turns, activeMinutes: activeMinutes(times),
                     models: models.values.sorted { $0.model < $1.model })
    }

    /// The minutes between consecutive lines, counting only gaps under 5 minutes (rounded down).
    public static func activeMinutes(_ times: [Date]) -> Int {
        let t = times.sorted()
        var s: Double = 0
        for i in t.indices.dropFirst() {
            let gap = t[i].timeIntervalSince(t[i - 1])
            if gap > 0 && gap < 300 { s += gap }
        }
        return Int(s / 60)
    }

    public static func report(run: String, window: RunWindow, agents: [Agent]) -> Report {
        var t = Totals()
        for a in agents {
            t.activeMinutes += a.activeMinutes
            t.turns += a.turns
            for m in a.models {
                t.calls += m.calls; t.tokensNew += m.tokensNew; t.tokensCacheWrite += m.tokensCacheWrite; t.tokensCacheRead += m.tokensCacheRead
                t.tokensOut += m.tokensOut
            }
        }
        return Report(run: run, window: window, agents: agents, totals: t)
    }
}

/// A run's window, as ISO 8601 in the archive's files.
public struct RunWindow: Codable, Equatable, Sendable {
    public var from: Date
    public var to: Date
    public init(from: Date, to: Date) { self.from = from; self.to = to }
}
