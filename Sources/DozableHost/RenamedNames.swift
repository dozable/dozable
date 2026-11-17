import Foundation

/// 0.51: what a sandbox or a session works on is its FOLDER — never "workspace" or "workdir". The old names are NOT
/// aliases: each still fails (an unknown option, a settings line that is not read, an unknown key of doz_project.yaml,
/// an unknown placeholder), and these tables only add what it was renamed to, so the person can fix it in one go.
/// REMOVE in 0.53 (two minors after the rename): the failures stay, only the hints go. `/workspace` inside a sandbox
/// keeps its name and is not here.
public enum RenamedNames {
    /// Command-line options: the old option → what to say instead.
    public static let options: [String: String] = [
        "--workspace": "--folder DIR",
        "--workspace-view": "--folder-view on|off",
        "--workdir": "--folder DIR on doz run @mac, --cwd DIR in a sandbox",
    ]

    /// doz.toml keys: the old key → the new one (`[workspace] ignore_mode` is the key `workspace.ignore_mode`).
    public static let settings: [String: String] = [
        "workspace.ignore_mode": "folder.ignore_mode",
        "workspace.view": "folder.view",
    ]

    /// doz_project.yaml keys.
    public static let projectKeys: [String: String] = [
        "workspace_view": "folder_view",
    ]

    /// The hint for an argument-parsing failure, appended to its first line — nil when no renamed option is involved.
    /// `message` is the parser's own text ("Unknown option '--workdir'"); the exit code stays the parser's.
    public static func optionHint(_ message: String) -> String? {
        for (old, new) in options.sorted(by: { $0.key.count > $1.key.count }) where message.contains("'\(old)'") {
            return "\(old) was renamed: \(new)"
        }
        return nil
    }

    /// `message` with the hint added to the line that names the old option (unchanged when there is none).
    public static func withOptionHint(_ message: String) -> String {
        guard let hint = optionHint(message) else { return message }
        var lines = message.components(separatedBy: "\n")
        if let i = lines.firstIndex(where: { l in options.keys.contains(where: { l.contains("'\($0)'") }) }) {
            lines[i] += " (\(hint).)"
        }
        return lines.joined(separator: "\n")
    }

    /// The warning for a doz.toml line under an old name — the line is not read.
    public static func settingWarning(line: Int, old: String, new: String) -> String {
        "line \(line): \(old) was renamed \(new) — this line is not read; say \(new) instead (doz config set \(new) VALUE)"
    }
}
