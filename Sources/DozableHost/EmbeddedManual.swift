import Foundation

/// The user manual a build carries (`doz docs`): every page of `docs/manual` at the build's commit, made into
/// `manual/` BESIDE the resolved executable by `Scripts/manual-bundle.py` — `llms.txt` (the index, relative links),
/// `llms-full.txt` (every page in one file), `VERSION` and the pages. Beside the executable because every way doz is
/// installed carries that one folder whole and nothing else: Homebrew's formula installs `libexec/*`, `doz upgrade`
/// swaps `libexec/doz` atomically, and an app copies the helper's `libexec/doz` into its bundle — a manual anywhere else
/// would be dropped or left at an older version. `make cli` puts one beside `.build/debug/doz` too.
///
/// Read-only and local: nothing here opens a connection, reads the store or starts a daemon. A build without the folder
/// (`swift build` alone) has no local manual and says so; its URL is still this version's.
public enum EmbeddedManual {
    public static let folderName = "manual"
    public static let index = "llms.txt"
    public static let full = "llms-full.txt"
    public static let site = "https://dozable.com"

    /// This version's manual online: `https://dozable.com/v/X.Y.Z/llms.txt`. Never the version-less `/llms.txt` — that is
    /// the stable release's, and a canary, beta or development build must not send an agent to another version's manual.
    public static func url(version: String) -> String { "\(site)/v/\(version)/\(index)" }
    /// This version's whole manual in one file online.
    public static func fullURL(version: String) -> String { "\(site)/v/\(version)/\(full)" }
    /// A page of this version's manual online, by its website name (`install-upgrade-uninstall`).
    public static func pageURL(version: String, slug: String) -> String { "\(site)/v/\(version)/docs/\(slug).md" }

    /// The manual beside `executable` (symlinks resolved), when it is there (its `llms.txt` exists); else nil.
    public static func directory(executable: String = HostLauncher.executablePath) -> URL? {
        let dir = URL(fileURLWithPath: executable).resolvingSymlinksInPath().deletingLastPathComponent()
            .appendingPathComponent(folderName).standardizedFileURL
        return FileManager.default.fileExists(atPath: dir.appendingPathComponent(index).path) ? dir : nil
    }

    /// One page: `37-workspaces.md` is number 37, name `workspaces`.
    public struct Page: Equatable, Sendable {
        public var file: String
        public var number: Int
        public var name: String
        public init?(file: String) {
            guard file.hasSuffix(".md"), file.count > 6 else { return nil }
            let stem = file.dropLast(3)
            let digits = stem.prefix(2)
            guard digits.count == 2, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber), let n = Int(digits),
                  stem.dropFirst(2).first == "-" else { return nil }
            let name = String(stem.dropFirst(3))
            guard !name.isEmpty, name.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }) else { return nil }
            self.file = file; self.number = n; self.name = name
        }
    }

    /// The pages in `dir`, in reading order.
    public static func pages(in dir: URL) -> [Page] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.compactMap(Page.init(file:)).sorted { ($0.number, $0.name) < ($1.number, $1.name) }
    }

    /// The page a person asked for: its number (`37`, `037`), its name (`workspaces`), or its file name (`37-workspaces`,
    /// `37-workspaces.md`) — any case. Nil: no such page.
    public static func lookup(_ query: String, in pages: [Page]) -> Page? {
        var q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if q.hasSuffix(".md") { q = String(q.dropLast(3)) }
        guard !q.isEmpty, q.count <= 80 else { return nil }
        if q.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(q) { return pages.first { $0.number == n } }
        return pages.first { $0.name == q || String($0.file.dropLast(3)) == q }
    }

    /// The list a refusal names: `01 getting-started, 02 install-upgrade-uninstall, …`.
    public static func listing(_ pages: [Page]) -> String {
        pages.map { String(format: "%02d", $0.number) + " " + $0.name }.joined(separator: ", ")
    }
}
