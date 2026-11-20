import CryptoKit
import Darwin
import Foundation

// The brief of a workspace a space file made: the file the space names (`brief: PATH`, resolved by the CLI against the
// space file's folder and recorded at `up` as `space.brief.path`). The file wins: it is read for the kick-off, `show
// --brief`, the set-up check and the run's archive, and the dashboard's and `doz workspace edit --prompt-file`'s edits are
// written into it — never into the store's `brief.md`. `up` itself never writes it. One rule set for every read and write,
// through `MacFenceHostFS`: no link anywhere in its path (`O_NOFOLLOW_ANY`), a regular file of this user with one name, at
// most 256 KiB of UTF-8, under the owner's home and never in the store, `~/.claude` or `~/Library`. A write goes to a temp
// name in the same folder and is renamed over the file, its mode kept. The path is the record's, never a request's.
// docs/engineering/workspaces.md ("Space files"). `SpaceBriefFileTests`.

public enum SpaceBriefFile {
    /// The home a brief must be under: the person's real one — in a guarded test run, `DOZ_TEST_BRIEF_HOME` (a scratch
    /// folder) when set.
    public static func home(_ env: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if TestSafety.guarded(env), let h = env["DOZ_TEST_BRIEF_HOME"], h.hasPrefix("/") { return h }
        return TestSafety.realHome.path
    }

    public struct Read: Equatable, Sendable {
        public var text: String
        public var sha256: String
        public var bytes: Int
    }

    /// Why `path` may not be a brief (nil: it may), from its place alone — before anything is opened.
    public static func placeRefusal(_ path: String, home: String = SpaceBriefFile.home(), store: String) -> String? {
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

    /// The brief's text, read by its descriptor under every rule. A missing file is "BRIEF.md is gone from PATH".
    public static func read(_ path: String, store: String, home: String = SpaceBriefFile.home()) throws -> Read {
        if let why = placeRefusal(path, home: home, store: store) { throw HostError(.invalid, "the brief: \(why)") }
        let resolved = onDisk(path, home: home)
        guard MacFenceHostFS.kind(resolved) != nil else {
            throw HostError(.notFound, "\((path as NSString).lastPathComponent) is gone from \(DisplayPath.tilde((path as NSString).deletingLastPathComponent))")
        }
        let d: Data
        do { d = try MacFenceHostFS.readRegular(resolved, maximum: WorkspaceStore.maximumBriefBytes) } catch {
            throw HostError(.invalid, "the brief: \(error)")
        }
        guard let text = String(data: d, encoding: .utf8) else { throw HostError(.invalid, "the brief \(DisplayPath.tilde(path)) is not UTF-8 text") }
        return Read(text: text, sha256: WorkspaceStore.sha256(d), bytes: d.count)
    }

    /// Writes `text` as the brief at `path` (temp, then renamed over it; its mode kept), only when the file as it is now
    /// hashes to `ifSHA` (when given). Answers what was written.
    @discardableResult
    public static func write(_ text: String, to path: String, ifSHA: String?, store: String, home: String = SpaceBriefFile.home()) throws -> Read {
        let now = try read(path, store: store, home: home)
        if let want = ifSHA, want != now.sha256 {
            throw HostError(.invalidPhase, "the brief changed since you opened it — read it again")
        }
        let data = Data(text.utf8)
        guard data.count <= WorkspaceStore.maximumBriefBytes else {
            throw HostError(.invalid, "the brief is \(data.count) bytes — at most \(WorkspaceStore.maximumBriefBytes >> 10) KiB")
        }
        let full = onDisk(path, home: home)
        let dir = (full as NSString).deletingLastPathComponent
        let name = (full as NSString).lastPathComponent
        var st = stat()
        let mode: mode_t = lstat(dir + "/" + name, &st) == 0 ? st.st_mode & 0o777 : 0o644
        do { try MacFenceHostFS.writeAtomically(data, dir: dir, name: name, mode: mode) } catch {
            throw HostError(.failed, "the brief could not be written: \(error)")
        }
        return Read(text: text, sha256: WorkspaceStore.sha256(data), bytes: data.count)
    }
}
