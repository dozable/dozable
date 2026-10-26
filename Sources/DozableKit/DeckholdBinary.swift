import Foundation

/// Finds the committed deckhold guest binary (the package resource) at run time.
///
/// Deliberately NOT SwiftPM's generated `Bundle.module`: that accessor `fatalError`s when the
/// resource bundle is not exactly where the build put it, which is never true for an assembled
/// `.app` (resource bundles belong in `Contents/Resources`) or a moved binary. This searches the
/// places a host legitimately puts `DozableKit_DozableKit.bundle`, and returns
/// nil rather than trapping.
public enum DeckholdBinary {
    public static let bundleName = "DozableKit_DozableKit.bundle"
    public static let resourceName = "deckhold"
    /// Overrides the lookup (a locally rebuilt deckhold, for instance).
    public static let environmentOverride = "DOZ_DECKHOLD"

    public static func locate(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        locate(resource: resourceName, override: environmentOverride, environment: environment)
    }

    /// Any committed guest binary of this package's resource bundle (deckhold, doznet).
    static func locate(resource resourceName: String, override environmentOverride: String,
                       environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        let fm = FileManager.default
        if let override = environment[environmentOverride], !override.isEmpty {
            return fm.fileExists(atPath: override) ? URL(fileURLWithPath: override) : nil
        }
        for bundle in candidateBundleDirectories() {
            for rel in ["Contents/Resources/\(resourceName)", resourceName] {
                let url = bundle.appendingPathComponent(rel)
                if fm.fileExists(atPath: url.path) { return url }
            }
        }
        return nil
    }

    static func candidateBundleDirectories() -> [URL] {
        var dirs: [URL] = []
        if let r = Bundle.main.resourceURL { dirs.append(r) }
        dirs.append(Bundle.main.bundleURL)
        if let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            dirs.append(exe.deletingLastPathComponent())
        }
        // Test runners: the resource bundle sits beside the .xctest bundle in the build dir.
        for b in Bundle.allBundles where b.bundleURL.pathExtension == "xctest" {
            dirs.append(b.bundleURL.deletingLastPathComponent())
        }
        var seen = Set<String>()
        return dirs.map { $0.appendingPathComponent(bundleName) }
            .filter { seen.insert($0.standardizedFileURL.path).inserted }
    }
}

/// Finds the committed `doznet` guest binary (580: the guest half of a proxied sandbox's
/// network) the same way — `$DOZ_DOZNET` overrides.
public enum DoznetBinary {
    public static let resourceName = "doznet"
    public static let environmentOverride = "DOZ_DOZNET"
    public static func locate(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        DeckholdBinary.locate(resource: resourceName, override: environmentOverride, environment: environment)
    }
}

/// Finds the committed guest `tmux` (sessions.tmux — `Guest/tmux/`, copied in by the tools layer) the same way, and
/// accepts it only when its bytes are the pinned ones (`ToolsLayer.tmuxSHA256`). `$DOZ_TMUX` overrides (a local
/// rebuild, a test) and is taken as it is.
public enum TmuxBinary {
    public static let resourceName = "tmux"
    public static let environmentOverride = "DOZ_TMUX"

    public static func locate(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        DeckholdBinary.locate(resource: resourceName, override: environmentOverride, environment: environment)
    }

    /// The file to copy in, or why there is none.
    public static func verified(environment: [String: String] = ProcessInfo.processInfo.environment) -> Result<URL, CheckFailure> {
        guard let url = locate(environment: environment) else {
            return .failure(CheckFailure("this build of Dozable has no tmux of its own"))
        }
        if let o = environment[environmentOverride], !o.isEmpty { return .success(url) }
        let sum: String? = lock.withLock {
            if let c = checked, c.path == url.path { return c.sum }
            guard let data = try? Data(contentsOf: url) else { return nil }
            let s = ToolsCache.sha256(data)
            checked = (url.path, s)
            return s
        }
        return check(url, sum: sum)
    }

    /// `url` when `sum` (its sha256) is the pin.
    static func check(_ url: URL, sum: String?) -> Result<URL, CheckFailure> {
        guard let sum else { return .failure(CheckFailure("could not read Dozable's tmux (\(url.path))")) }
        guard sum == ToolsLayer.tmuxSHA256 else {
            return .failure(CheckFailure("Dozable's tmux is not the pinned build (sha256 \(sum.prefix(16))…) — not used"))
        }
        return .success(url)
    }

    /// The last file hashed (one hash per process: the bundle does not change under a running doz).
    private static let lock = NSLock()
    nonisolated(unsafe) private static var checked: (path: String, sum: String)?
}
