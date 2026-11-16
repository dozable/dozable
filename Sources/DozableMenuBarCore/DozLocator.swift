import Foundation

/// Finds the `doz` the menu bar app runs — again at every refresh (a `stat` each), so a doz upgraded or replaced while the
/// app runs is the one the next refresh uses.
///
/// The candidates, in order: Homebrew on Apple silicon, Homebrew's older prefix, `make install-cli`'s default prefix. The
/// path is kept AS IS (a `bin/doz` link is not resolved): a `brew upgrade` re-points the link, and the next run follows it.
/// In a guarded test run (`DOZ_TEST_GUARD=1`) the ONLY candidate is the seam `DOZ_MENUBAR_DOZ` — a test never runs this
/// Mac's own doz; without the seam it finds none.
public struct DozLocator: Sendable {
    public var candidates: [String]
    /// Whether a candidate may be used (an executable file by default; a stricter check — a signature — can be given).
    public var accept: @Sendable (String) -> Bool

    public init(candidates: [String], accept: @escaping @Sendable (String) -> Bool = DozLocator.isExecutableFile) {
        self.candidates = candidates
        self.accept = accept
    }

    /// The candidates for this process: the seam in a guarded run, else the standard places under `home`.
    public static func standardCandidates(env: [String: String] = ProcessInfo.processInfo.environment,
                                          home: String = NSHomeDirectory()) -> [String] {
        if MenuBarSeams.guarded(env) {
            guard let seam = env["DOZ_MENUBAR_DOZ"], seam.hasPrefix("/") else { return [] }
            return [seam]
        }
        return ["/opt/homebrew/bin/doz", "/usr/local/bin/doz", (home as NSString).appendingPathComponent(".local/bin/doz")]
    }

    public static func standard(env: [String: String] = ProcessInfo.processInfo.environment) -> DozLocator {
        DozLocator(candidates: standardCandidates(env: env))
    }

    @Sendable public static func isExecutableFile(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && !isDir.boolValue
            && FileManager.default.isExecutableFile(atPath: path)
    }

    /// The first acceptable candidate (its path as listed), or nil: doz is not installed.
    public func locate() -> String? {
        candidates.first { $0.hasPrefix("/") && accept($0) }
    }
}

/// Which file a path is now — the identity the app keys its cached `doz --version` on. A doz replaced by rename (an
/// install, a `brew upgrade` re-pointing the link) is a different file; its version is read again.
public struct FileIdentity: Equatable, Sendable {
    public let resolvedPath: String
    public let inode: UInt64
    public let device: Int64
    public let size: Int64
    public let modified: Double

    public static func of(_ path: String) -> FileIdentity? {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        var st = stat()
        guard stat(resolved, &st) == 0 else { return nil }
        let mtime = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
        return FileIdentity(resolvedPath: resolved, inode: UInt64(st.st_ino), device: Int64(st.st_dev), size: Int64(st.st_size), modified: mtime)
    }

    /// The identity of doz together with the VERSION stamp beside it (what `doz --version` reads).
    public static func ofDoz(_ path: String) -> [FileIdentity] {
        guard let exe = of(path) else { return [] }
        let stamp = (exe.resolvedPath as NSString).deletingLastPathComponent + "/VERSION"
        return [exe] + (of(stamp).map { [$0] } ?? [])
    }
}

/// The app's test seams: honoured only in a guarded run — `DOZ_TEST_GUARD=1` (every `make test*` target), lifted only by
/// `DOZ_TEST_REAL_MAC=1`, as doz's own guard.
public enum MenuBarSeams {
    public static func guarded(_ env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        env["DOZ_TEST_REAL_MAC"] != "1" && env["DOZ_TEST_GUARD"] == "1"
    }
}
