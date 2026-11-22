import CryptoKit
import Darwin
import Foundation

// The files a space workspace's record names, opened by the daemon: its brief (`brief: PATH`, resolved by the CLI against
// the space file's folder and recorded at `up` as `space.brief.path`) and the space file itself (`space.path`, read and saved
// from the dashboard and `doz workspace show --space` / `edit --space-file`). The path is ALWAYS the record's, never a
// request's. One rule set for every read and write, through `MacFenceHostFS`: no link anywhere in its path (`O_NOFOLLOW_ANY`),
// a regular file of this user with one name, at most 256 KiB of UTF-8, under the owner's home and never in the store,
// `~/.claude` or `~/Library`. A write goes to a temp name in the same folder and is renamed over the file, its mode kept, and
// only when the file as it is now — hashed through the descriptor it is read by — is the one the writer read (`ifSHA`): a file
// changed since is refused and nothing is written. A space file also must start with its format line (`doz: space/3`, or
// `doz: space-defaults/3`), before and after a save. Saving a space file never runs `up`.
//
// The brief: the file wins — it is read for the kick-off, `show --brief`, the set-up check and the run's archive, and the
// dashboard's and `doz workspace edit --prompt-file`'s edits are written into it, never into the store's `brief.md`. `up`
// itself never writes it. docs/engineering/workspaces.md ("Space files"). `SpaceRecordFileTests`, `SpaceBriefFileTests`.

public enum SpaceRecordFile {
    public enum Kind: String, Sendable {
        case brief, space
        /// How a message names it.
        var words: String { self == .brief ? "the brief" : "the space file" }
    }

    /// The formats a space file may declare on its first line that is not blank or a comment.
    public static let formats = ["doz: space/3", "doz: space-defaults/3"]
    public static let maximumBytes = WorkspaceStore.maximumBriefBytes

    /// The home a recorded file must be under: the person's real one — in a guarded test run, `DOZ_TEST_BRIEF_HOME` (a
    /// scratch folder) when set.
    public static func home(_ env: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if TestSafety.guarded(env), let h = env["DOZ_TEST_BRIEF_HOME"], h.hasPrefix("/") { return h }
        return TestSafety.realHome.path
    }

    public struct Read: Equatable, Sendable {
        public var text: String
        public var sha256: String
        public var bytes: Int
    }

    /// Why `path` may not be such a file (nil: it may), from its place alone — before anything is opened.
    public static func placeRefusal(_ path: String, home: String = SpaceRecordFile.home(), store: String) -> String? {
        let p = path
        guard p.hasPrefix("/"), !p.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) else {
            return "\(DisplayPath.tilde(path)) is not an absolute, plain path"
        }
        let homes = Set([home, WorkspaceStore.resolved(home)])
        func under(_ root: String) -> Bool { p == root || p.hasPrefix(root.hasSuffix("/") ? root : root + "/") }
        guard homes.contains(where: under) else { return "\(DisplayPath.tilde(path)) is not under your home folder" }
        let stores = Set([store, WorkspaceStore.resolved(store)])
        if stores.contains(where: under) { return "\(DisplayPath.tilde(path)) is in Dozable's store" }
        for h in homes {
            if under(h + "/.claude") { return "\(DisplayPath.tilde(path)) is in ~/.claude" }
            if under(h + "/Library") { return "\(DisplayPath.tilde(path)) is in ~/Library" }
        }
        return nil
    }

    /// The path as the file system takes it: only the home folder itself resolved (`/tmp` is a link to `/private/tmp`) —
    /// never a link below it, which every open then refuses (`O_NOFOLLOW_ANY`).
    static func onDisk(_ path: String, home: String) -> String {
        guard path.hasPrefix(home + "/") else { return path }
        return WorkspaceStore.resolved(home) + String(path.dropFirst(home.count))
    }

    /// Why `text` is not a space file (nil: it is one): its first line that is not blank or a comment names its format.
    public static func formatRefusal(_ text: String) -> String? {
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line == "---" { continue }
            return formats.contains(line) ? nil : "it does not start with doz: space/3 (or doz: space-defaults/3)"
        }
        return "it is empty"
    }

    /// The file's text, read by its descriptor under every rule. A missing file is "NAME is gone from FOLDER".
    public static func read(_ kind: Kind, _ path: String, store: String, home: String = SpaceRecordFile.home()) throws -> Read {
        if let why = placeRefusal(path, home: home, store: store) { throw HostError(.invalid, "\(kind.words): \(why)") }
        let resolved = onDisk(path, home: home)
        guard MacFenceHostFS.kind(resolved) != nil else {
            throw HostError(.notFound, "\((path as NSString).lastPathComponent) is gone from \(DisplayPath.tilde((path as NSString).deletingLastPathComponent))")
        }
        let d: Data
        do { d = try MacFenceHostFS.readRegular(resolved, maximum: maximumBytes) } catch {
            throw HostError(.invalid, "\(kind.words): \(error)")
        }
        guard let text = String(data: d, encoding: .utf8) else { throw HostError(.invalid, "\(kind.words) \(DisplayPath.tilde(path)) is not UTF-8 text") }
        if kind == .space, let why = formatRefusal(text) { throw HostError(.invalid, "\(kind.words) \(DisplayPath.tilde(path)): \(why)") }
        return Read(text: text, sha256: WorkspaceStore.sha256(d), bytes: d.count)
    }

    /// Writes `text` at `path` (temp, then renamed over it; its mode kept), only when the file as it is now hashes to
    /// `ifSHA` (when given — a space file's save always gives it). Answers what was written.
    @discardableResult
    public static func write(_ kind: Kind, _ text: String, to path: String, ifSHA: String?, store: String,
                             home: String = SpaceRecordFile.home()) throws -> Read {
        let data = Data(text.utf8)
        guard data.count <= maximumBytes else {
            throw HostError(.invalid, "\(kind.words) is \(data.count) bytes — at most \(maximumBytes >> 10) KiB")
        }
        if kind == .space, let why = formatRefusal(text) { throw HostError(.invalid, "\(kind.words) was not saved: \(why)") }
        let now = try read(kind, path, store: store, home: home)
        if let want = ifSHA, want != now.sha256 {
            throw HostError(.fileChanged, "\(kind.words) changed since you opened it — read it again")
        }
        let full = onDisk(path, home: home)
        let dir = (full as NSString).deletingLastPathComponent
        let name = (full as NSString).lastPathComponent
        var st = stat()
        let mode: mode_t = lstat(dir + "/" + name, &st) == 0 ? st.st_mode & 0o777 : 0o644
        do { try MacFenceHostFS.writeAtomically(data, dir: dir, name: name, mode: mode) } catch {
            throw HostError(.failed, "\(kind.words) could not be written: \(error)")
        }
        return Read(text: text, sha256: WorkspaceStore.sha256(data), bytes: data.count)
    }
}

/// The brief of a space workspace: `SpaceRecordFile` with kind `brief`.
public enum SpaceBriefFile {
    public typealias Read = SpaceRecordFile.Read
    public static func home(_ env: [String: String] = ProcessInfo.processInfo.environment) -> String { SpaceRecordFile.home(env) }
    public static func placeRefusal(_ path: String, home: String = SpaceRecordFile.home(), store: String) -> String? {
        SpaceRecordFile.placeRefusal(path, home: home, store: store)
    }
    static func onDisk(_ path: String, home: String) -> String { SpaceRecordFile.onDisk(path, home: home) }
    public static func read(_ path: String, store: String, home: String = SpaceRecordFile.home()) throws -> Read {
        try SpaceRecordFile.read(.brief, path, store: store, home: home)
    }
    @discardableResult
    public static func write(_ text: String, to path: String, ifSHA: String?, store: String, home: String = SpaceRecordFile.home()) throws -> Read {
        try SpaceRecordFile.write(.brief, text, to: path, ifSHA: ifSHA, store: store, home: home)
    }
}
