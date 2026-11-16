import Foundation

/// Dozable versions as the menu bar app compares them: `MAJOR.MINOR.PATCH`, optionally `-PRERELEASE` (dot-separated,
/// numeric parts compared as numbers, a release above its prereleases) and `+BUILD` (ignored). The app's own copy of the
/// rule — it links nothing of Dozable's (the audit holds it).
public struct DozVersion: Comparable, CustomStringConvertible, Sendable {
    public let major: Int, minor: Int, patch: Int
    public let prerelease: [String]
    public let text: String

    public init?(_ s: String) {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= 40 else { return nil }
        let noBuild = t.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? t
        let parts = noBuild.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let core = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard core.count == 3, let a = Int(core[0]), let b = Int(core[1]), let c = Int(core[2]), a >= 0, b >= 0, c >= 0 else { return nil }
        major = a; minor = b; patch = c
        if parts.count == 2 {
            let pre = parts[1].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard !pre.contains(where: \.isEmpty) else { return nil }
            prerelease = pre
        } else {
            prerelease = []
        }
        text = t
    }

    public var description: String { text }

    public static func == (l: DozVersion, r: DozVersion) -> Bool {
        l.major == r.major && l.minor == r.minor && l.patch == r.patch && l.prerelease == r.prerelease
    }

    public static func < (l: DozVersion, r: DozVersion) -> Bool {
        if l.major != r.major { return l.major < r.major }
        if l.minor != r.minor { return l.minor < r.minor }
        if l.patch != r.patch { return l.patch < r.patch }
        // A release ranks above its own prereleases.
        if l.prerelease.isEmpty || r.prerelease.isEmpty { return !l.prerelease.isEmpty && r.prerelease.isEmpty }
        for (a, b) in zip(l.prerelease, r.prerelease) where a != b {
            switch (Int(a), Int(b)) {
            case let (x?, y?): return x < y
            case (_?, nil): return true          // numeric parts rank below alphanumeric ones
            case (nil, _?): return false
            default: return a < b
            }
        }
        return l.prerelease.count < r.prerelease.count
    }

    /// `a` is older than `b` — false when either does not parse (an unreadable version is never called old).
    public static func isOlder(_ a: String?, than b: String?) -> Bool {
        guard let a, let b, let x = DozVersion(a), let y = DozVersion(b) else { return false }
        return x < y
    }
}
