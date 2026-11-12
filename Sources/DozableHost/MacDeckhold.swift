import Darwin
import Foundation

/// The PTY holder for sessions held on THIS Mac (`deckhold-mac`: Guest/deckhold/build-mac.sh) — the same holder as the
/// guest's, built for macOS, shipped beside `doz` in the CLI flavour (`libexec/doz/deckhold-mac`; `make cli` puts it
/// beside `.build/debug/doz`). Not in the helper build. `MacSessions` (`@mac`) runs it.
public enum MacDeckhold {
    public static let fileName = "deckhold-mac"

    /// Why a file is not a usable holder (nil: it is).
    public static func problem(_ url: URL) -> String? {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return "\(url.path) is not there" }
        guard (st.st_mode & S_IFMT) == S_IFREG else { return "\(url.path) is not a file" }
        guard access(url.path, X_OK) == 0 else { return "\(url.path) is not executable" }
        guard let h = FileHandle(forReadingAtPath: url.path) else { return "\(url.path) cannot be read" }
        defer { try? h.close() }
        let magic = [UInt8](h.readData(ofLength: 4))
        if magic == [0x7F, 0x45, 0x4C, 0x46] { return "\(url.path) is the guest's Linux holder, not the Mac's" }
        // MH_MAGIC_64 (cffaedfe little-endian) or a fat/universal header.
        guard magic == [0xCF, 0xFA, 0xED, 0xFE] || magic == [0xCA, 0xFE, 0xBA, 0xBE] || magic == [0xBE, 0xBA, 0xFE, 0xCA] else {
            return "\(url.path) is not a Mac executable"
        }
        return nil
    }

    /// The holder beside the resolved `executable` (a Homebrew `bin/doz` is a link into the keg). TEST SEAM (guarded runs
    /// only): `DOZ_DECKHOLD_MAC=<path>`. nil: none usable — `why` says what was wrong.
    public static func locate(executable: String = HostLauncher.executablePath,
                              environment env: [String: String] = ProcessInfo.processInfo.environment) -> (url: URL?, why: String?) {
        if let o = env["DOZ_DECKHOLD_MAC"], !o.isEmpty, TestSafety.guarded(env) {
            let u = URL(fileURLWithPath: o)
            return problem(u).map { (nil, $0) } ?? (u, nil)
        }
        let u = URL(fileURLWithPath: executable).resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent(fileName)
        if let p = problem(u) {
            return (nil, BuildFlavor.current.isHelper ? "this build does not carry \(fileName) (the helper build leaves sessions on the Mac out)" : p)
        }
        return (u, nil)
    }
}
