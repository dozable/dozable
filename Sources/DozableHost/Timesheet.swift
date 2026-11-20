import Foundation

// A run's timesheet (`timesheet.md` in its archive): the window, the agents' table (role, active time, turns, model,
// calls, tokens new / cache write / cache read, tokens out, cost), your messages in the run, and the commits section —
// which says Dozable does not collect them: it never runs git (or any program) in a folder an agent writes. Pure, from
// the usage and the chat slice (`TimesheetTests`, golden).

public enum Timesheet {
    public static let commitsNotCollected = "Not collected: Dozable does not run git in a folder an agent writes."

    public struct Input: Sendable {
        public var workspace: String
        public var run: String
        public var window: RunWindow
        public var usage: TranscriptUsage.Report
        /// You (the chat's human) and the messages you posted in the run, per room.
        public var you: String
        public var yourMessages: [String: Int]
        public var timeZone: TimeZone
        public init(workspace: String, run: String, window: RunWindow, usage: TranscriptUsage.Report, you: String, yourMessages: [String: Int],
                    timeZone: TimeZone = .current) {
            self.workspace = workspace; self.run = run; self.window = window; self.usage = usage; self.you = you
            self.yourMessages = yourMessages; self.timeZone = timeZone
        }
    }

    public static func markdown(_ i: Input) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = i.timeZone
        let minutes = max(0, Int(i.window.to.timeIntervalSince(i.window.from) / 60))
        var s = "# Timesheet: \(i.workspace), run \(i.run)\n\n"
        s += "- **Workspace:** \(i.workspace)\n"
        s += "- **Window:** \(f.string(from: i.window.from)) → \(f.string(from: i.window.to)) (\(minutes / 60) h \(String(format: "%02d", minutes % 60)) min)\n"
        s += "- **Labels:** none\n\n"
        s += "## Agents\n\n"
        s += "| Agent | Role | Active | Turns | Model | Calls | Tokens in (new / cache write / cache read) | Tokens out | Cost |\n"
        s += "|---|---|---|---|---|---|---|---|---|\n"
        if i.usage.agents.isEmpty { s += "| — | — | — | — | — | — | — | — | — |\n" }
        for a in i.usage.agents {
            if a.models.isEmpty {
                s += "| \(a.agent) | \(a.role) | \(a.files == 0 ? "—" : "\(a.activeMinutes) min") | \(a.files == 0 ? "—" : String(a.turns)) | — | — | — | — | \(a.note ?? "no model calls") |\n"
                continue
            }
            for (k, m) in a.models.enumerated() {
                let first = k == 0
                s += "| \(first ? a.agent : "") | \(first ? a.role : "") | \(first ? "\(a.activeMinutes) min" : "") | \(first ? String(a.turns) : "") | \(m.model) | \(m.calls) | "
                    + "\(m.tokensNew) / \(m.tokensCacheWrite) / \(m.tokensCacheRead) | \(m.tokensOut) | \(a.cost) |\n"
            }
        }
        let t = i.usage.totals
        s += "\n**Totals:** \(t.calls) calls · \(t.tokensNew) / \(t.tokensCacheWrite) / \(t.tokensCacheRead) tokens in · \(t.tokensOut) out · \(t.activeMinutes) min active\n\n"
        s += "## \(i.you)'s messages and decisions\n\n"
        let total = i.yourMessages.values.reduce(0, +)
        if total == 0 {
            s += "None in this run.\n\n"
        } else {
            for (room, n) in i.yourMessages.sorted(by: { $0.key < $1.key }) where n > 0 {
                s += "- #\(room): \(n) message\(n == 1 ? "" : "s")\n"
            }
            s += "\n"
        }
        s += "Asks: Dozable has no Ask export yet, so Asks are not listed.\n\n"
        s += "## Commits\n\n\(commitsNotCollected)\n"
        return s
    }
}
