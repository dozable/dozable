import Foundation

// 646 (owner: "open the workspace in my editor"): `doz files open NAME [PATH] --app APP` and the dashboard's Open folder
// menu open a shared workspace — or a folder or file in it — in an editor on this Mac. This is the PERSON's action (the
// CLI, the Mac's own browser), never the agent's bridge — but the host op is reachable from the web, so the app is never
// free text that reaches `open -a` unchecked. Accepted:
//
//   · an editor from the KNOWN list below that is INSTALLED — resolved by its bundle identifier through LaunchServices
//     (`MacDefaultApp.appPath`, read-only), and opened by that resolved `.app` path (`open -a <path>`), never by a name;
//   · or a name in `bridges.open_apps` — the LISTED spelling reaches `open -a`, as for the agent's `doz-open --app`.
//
// `--app` matches an editor's id or its name, case-insensitively. A wrong bundle id below only means "not installed".
// Tests never ask the Mac: `DOZ_TEST_EDITORS=vscode,zed` says which known editors are installed (at a path that does not
// exist, so nothing could ever launch from it).

public enum EditorApps {
    /// One editor this build knows: a short id (`--app cursor`), the name people know it by, its bundle identifiers (the
    /// first installed one wins).
    public struct Known: Equatable, Sendable {
        public let id: String
        public let name: String
        public let bundleIDs: [String]
    }

    /// The known editors, in the order the dashboard offers them. Bundle ids checked with `mdls` on 2026-10-24 where one
    /// was installed (VS Code, Zed, Xcode, Sublime Text, BBEdit, IntelliJ IDEA); the rest from their vendors.
    public static let known: [Known] = [
        Known(id: "vscode", name: "Visual Studio Code", bundleIDs: ["com.microsoft.VSCode"]),
        Known(id: "cursor", name: "Cursor", bundleIDs: ["com.todesktop.230313mzl4w4u92"]),
        Known(id: "zed", name: "Zed", bundleIDs: ["dev.zed.Zed"]),
        Known(id: "windsurf", name: "Windsurf", bundleIDs: ["com.exafunction.windsurf"]),
        Known(id: "xcode", name: "Xcode", bundleIDs: ["com.apple.dt.Xcode"]),
        Known(id: "sublime", name: "Sublime Text", bundleIDs: ["com.sublimetext.4"]),
        Known(id: "nova", name: "Nova", bundleIDs: ["com.panic.Nova"]),
        Known(id: "bbedit", name: "BBEdit", bundleIDs: ["com.barebones.bbedit"]),
        Known(id: "intellij", name: "IntelliJ IDEA", bundleIDs: ["com.jetbrains.intellij", "com.jetbrains.intellij.ce"]),
        Known(id: "pycharm", name: "PyCharm", bundleIDs: ["com.jetbrains.pycharm", "com.jetbrains.pycharm.ce"]),
        Known(id: "webstorm", name: "WebStorm", bundleIDs: ["com.jetbrains.WebStorm"]),
        Known(id: "goland", name: "GoLand", bundleIDs: ["com.jetbrains.goland"]),
        Known(id: "textmate", name: "TextMate", bundleIDs: ["com.macromates.TextMate"]),
    ]

    /// The test seam: the known editors' ids taken as installed.
    public static let testSeam = "DOZ_TEST_EDITORS"

    /// One row of the `editors` op: what `--app` takes (`id`) and what a person reads (`name`).
    public struct Editor: Codable, Equatable, Sendable {
        public var id: String
        public var name: String
        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    /// An app `--app` named, resolved: `name` for people (the notice), `target` what reaches `open -a` (a known editor's
    /// resolved `.app` path, or the listed spelling of a `bridges.open_apps` name).
    public struct Resolved: Equatable, Sendable {
        public let name: String
        public let target: String
    }

    /// Where a known editor is installed (nil: it is not). The seam answers for tests; else LaunchServices, read-only.
    public static func installedPath(_ k: Known, environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if let seam = environment[testSeam] {
            let ids = seam.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            return ids.contains(k.id) ? "/nonexistent/doz-test-editors/\(k.name).app" : nil
        }
        for b in k.bundleIDs { if let p = MacDefaultApp.appPath(bundleIdentifier: b) { return p } }
        return nil
    }

    /// The `editors` op: the known editors installed here, then the `bridges.open_apps` names not already among them.
    public static func installed(openApps: [String], environment: [String: String] = ProcessInfo.processInfo.environment) -> [Editor] {
        var out = known.filter { installedPath($0, environment: environment) != nil }.map { Editor(id: $0.id, name: $0.name) }
        for n in openApps where !out.contains(where: { $0.name.caseInsensitiveCompare(n) == .orderedSame || $0.id.caseInsensitiveCompare(n) == .orderedSame }) {
            out.append(Editor(id: n, name: n))
        }
        return out
    }

    /// The known editor `app` names (its id or its name, case-insensitively), if any.
    public static func match(_ app: String) -> Known? {
        known.first { $0.id.caseInsensitiveCompare(app) == .orderedSame || $0.name.caseInsensitiveCompare(app) == .orderedSame }
    }

    /// `--app APP`: a known editor that is installed, else a `bridges.open_apps` name, else why not. Every refusal is
    /// short (a notice is one line) and names what `--app` accepts.
    public static func resolve(_ app: String, openApps: [String],
                               environment: [String: String] = ProcessInfo.processInfo.environment) -> Result<Resolved, WorkspaceFiles.Refusal> {
        let shown = String(app.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }.prefix(64))
        guard WorkspaceFiles.isAppName(app) else { return .failure(WorkspaceFiles.Refusal("\"\(shown)\" is not an app name")) }
        let k = match(app)
        if let k, let path = installedPath(k, environment: environment) { return .success(Resolved(name: k.name, target: path)) }
        if let listed = openApps.first(where: { $0.caseInsensitiveCompare(app) == .orderedSame }) {
            return .success(Resolved(name: listed, target: listed))
        }
        if let k { return .failure(WorkspaceFiles.Refusal("\(k.name) is not installed on this Mac")) }
        return .failure(WorkspaceFiles.Refusal("\(shown) is not a known editor or in bridges.open_apps (doz files editors lists them)"))
    }
}
