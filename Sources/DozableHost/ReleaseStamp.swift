import Foundation

/// 598: the version a release build carries in `VERSION` beside its (resolved) executable. 714: in DozableHost (it was
/// the CLI's), so the dashboard can read the version installed now (`StableExecutable.installedVersion`).
public enum ReleaseStamp {
    public static let fileName = "VERSION"

    /// The stamp beside `executable` (symlinks resolved — `bin/doz` is a link into the keg), or nil.
    public static func read(executable: String = HostLauncher.executablePath) -> String? {
        let dir = URL(fileURLWithPath: executable).resolvingSymlinksInPath().deletingLastPathComponent()
        guard let text = try? String(contentsOf: dir.appendingPathComponent(fileName), encoding: .utf8) else { return nil }
        return parse(text)
    }

    /// A stamp is one semver line (`0.12.0`, `0.12.0-rc.1`); anything else is ignored.
    public static func parse(_ text: String) -> String? {
        let v = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard v.count <= 40, v.range(of: #"^\d+\.\d+\.\d+([-+][0-9A-Za-z.-]+)?$"#, options: .regularExpression) != nil else { return nil }
        return v
    }
}

