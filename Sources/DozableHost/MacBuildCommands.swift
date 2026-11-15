import Foundation

/// One command line a person can paste into a fenced Swift / Xcode session.
public struct MacBuildCommand: Codable, Equatable, Sendable {
    public var label: String
    public var command: String
    public init(label: String, command: String) {
        self.label = label
        self.command = command
    }
}

/// The build and test commands that work INSIDE a fenced `--xcode` (or `--simulator`) session — the ONE source: the
/// dashboard's New session wizard, `doz run @mac --xcode --dry-run`, and the fence tests (`make test-cli-fence` runs these
/// very lines) all take them from here, so the page never shows a command the suite does not run.
public enum MacBuildCommands {
    /// SwiftPM inside the fence: its own sandbox cannot nest (`--disable-sandbox`), its caches are the session's.
    public static let swiftFlags = "--disable-sandbox --cache-path \"$XDG_CACHE_HOME/swiftpm\""
    /// Scratch (build products) in the session's own DerivedData; the default `.build` works too, without this flag.
    public static let scratchFlag = "--scratch-path \"$DOZ_DERIVED\""

    /// The lines for a profile (`MacCapabilityShape.profile`: `xcode`, `simulator`, or `agent` → none). `scheme` and
    /// `project` name the Xcode project the xcodebuild lines build (the page shows a placeholder scheme).
    public static func commands(profile: String, scheme: String = "MyApp", project: String? = nil) -> [MacBuildCommand] {
        guard profile == "xcode" || profile == "simulator" else { return [] }
        let p = project.map { "-project \($0) " } ?? ""
        let x = "-scheme \(scheme) -derivedDataPath \"$DOZ_DERIVED\" -scmProvider system"
        return [
            MacBuildCommand(label: "Build a Swift package", command: "swift build \(swiftFlags) \(scratchFlag)"),
            MacBuildCommand(label: "Test a Swift package", command: "swift test \(swiftFlags) \(scratchFlag)"),
            MacBuildCommand(label: "Build with xcodebuild", command: "xcodebuild build \(p)\(x)"),
            MacBuildCommand(label: "Test with xcodebuild", command: "xcodebuild test \(p)\(x) -destination \"platform=macOS\""),
        ]
    }

    /// The same Swift line with the default `.build` (no scratch flag).
    public static func withDefaultScratch(_ c: MacBuildCommand) -> String {
        c.command.replacingOccurrences(of: " " + scratchFlag, with: "")
    }

    /// The lines `doz run @mac … --dry-run` prints after the capabilities (empty for a session with no build lines).
    public static func text(_ list: [MacBuildCommand]) -> String {
        guard !list.isEmpty else { return "" }
        let width = list.map(\.label.count).max() ?? 0
        return "\nInside the session, builds and tests work with (nothing was run):\n"
            + list.map { "  " + $0.label.padding(toLength: width, withPad: " ", startingAt: 0) + "  " + $0.command }.joined(separator: "\n") + "\n"
            + "  (swift build and swift test also work with the default .build — leave --scratch-path out.)\n"
    }
}
