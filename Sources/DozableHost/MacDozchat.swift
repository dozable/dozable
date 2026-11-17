import Darwin
import Foundation

/// `dozchat-mac` — the chat-room member (Guest/dozchat/dozchat.c, built for macOS by Guest/dozchat/build-mac.sh) that a
/// FENCED session on this Mac runs as `dozchat`: shipped beside `doz` in the CLI flavour (`libexec/doz/dozchat-mac`; `make
/// cli` puts it beside `.build/debug/doz`). Not in the helper build, not on an unfenced session's PATH.
///
/// A fenced session reaches it only as ONE file: its profile allows reading exactly this path (`MacFenceProfile`, as for
/// `doz` itself) and its folder's `etc/bin/dozchat` shim execs it (`MacFenceSessionFolder.dozchatShim`). It gives the session
/// no new reach — the chat server is reached through the session's own proxy and route, as curl would.
public enum MacDozchat {
    public static let fileName = "dozchat-mac"

    /// Why a file is not a usable dozchat for this Mac (nil: it is).
    public static func problem(_ url: URL) -> String? {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return "\(url.path) is not there" }
        guard (st.st_mode & S_IFMT) == S_IFREG else { return "\(url.path) is not a file" }
        guard access(url.path, X_OK) == 0 else { return "\(url.path) is not executable" }
        guard let h = FileHandle(forReadingAtPath: url.path) else { return "\(url.path) cannot be read" }
        defer { try? h.close() }
        let magic = [UInt8](h.readData(ofLength: 4))
        if magic == [0x7F, 0x45, 0x4C, 0x46] { return "\(url.path) is the guest's Linux dozchat, not the Mac's" }
        guard magic == [0xCF, 0xFA, 0xED, 0xFE] || magic == [0xCA, 0xFE, 0xBA, 0xBE] || magic == [0xBE, 0xBA, 0xFE, 0xCA] else {
            return "\(url.path) is not a Mac executable"
        }
        return nil
    }

    /// dozchat-mac beside the resolved `executable` (a Homebrew `bin/doz` is a link into the keg). TEST SEAM (guarded runs
    /// only): `DOZ_DOZCHAT_MAC=<path>`. nil: none usable — `why` says what was wrong.
    public static func locate(executable: String = HostLauncher.executablePath,
                              environment env: [String: String] = ProcessInfo.processInfo.environment) -> (url: URL?, why: String?) {
        if let o = env["DOZ_DOZCHAT_MAC"], !o.isEmpty, TestSafety.guarded(env) {
            let u = URL(fileURLWithPath: o)
            return problem(u).map { (nil, $0) } ?? (u, nil)
        }
        let u = URL(fileURLWithPath: executable).resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent(fileName)
        if let p = problem(u) {
            return (nil, BuildFlavor.current.isHelper ? "this build does not carry \(fileName)" : p)
        }
        return (u, nil)
    }

    /// The path a fenced session's profile and shim name (resolved, and safe in a profile literal and a shell word), or nil.
    public static func forFence(executable: String = HostLauncher.executablePath,
                                environment env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        guard let u = locate(executable: executable, environment: env).url, let p = MacFencePaths.resolve(u.path),
              MacFencePaths.pathProblem(p) == nil else { return nil }
        return p
    }
}
