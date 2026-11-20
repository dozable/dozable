import CryptoKit
import Darwin
import Foundation

// `transcripts: discard`, done as a forget (`doz sessions @mac --forget S --discard-transcripts`): a session's
// conversations removed only where a closed run's VERIFIED archive holds the same bytes. Each file is opened with no link in
// any component of its path (`O_NOFOLLOW_ANY`) through its folder's descriptor, `fstat`ed (a regular, one-link file of this
// user), hashed THROUGH THAT descriptor, and unlinked (`unlinkat`) only when the sha256 is the archive's `sourceSHA256` and
// the name still points at the same file (dev and inode unchanged). Never a folder, never a listing, never another file:
// a file that changed since it was archived is kept, and says so (EDGE-CASES 14). `TranscriptDiscardTests`.

public enum TranscriptDiscard {
    public enum Outcome: Equatable, Sendable {
        case removed
        case kept(String)
    }

    /// Removes `path` (absolute, resolved) only when its content's sha256 is `sha256`.
    public static func remove(_ path: String, sha256 want: String, uid: uid_t = getuid()) -> Outcome {
        let parent = (path as NSString).deletingLastPathComponent, name = (path as NSString).lastPathComponent
        guard path.hasPrefix("/"), !name.isEmpty, name != ".", name != ".." else { return .kept("not a file's path") }
        let dir = Darwin.open(parent, O_RDONLY | O_DIRECTORY | MacFenceHostFS.noFollowAny | O_CLOEXEC)
        guard dir >= 0 else { return .kept(errno == ELOOP ? "a link in its path — not followed" : "its folder cannot be opened") }
        defer { close(dir) }
        let fd = openat(dir, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return .kept(errno == ELOOP ? "a link — refused" : errno == ENOENT ? "not there any more" : "it cannot be opened") }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { return .kept("it cannot be read") }
        guard (st.st_mode & S_IFMT) == S_IFREG else { return .kept("not a regular file") }
        guard st.st_nlink == 1 else { return .kept("a hard link (\(st.st_nlink) names) — refused") }
        guard st.st_uid == uid else { return .kept("not yours") }
        guard st.st_size <= off_t(MacTranscripts.maximumFileBytes) else { return .kept("larger than \(MacTranscripts.maximumFileBytes) bytes") }
        var h = SHA256()
        var buf = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let n = read(fd, &buf, buf.count)
            if n < 0 && errno == EINTR { continue }
            if n < 0 { return .kept("it cannot be read") }
            if n == 0 { break }
            h.update(data: buf[0..<n])
        }
        let got = h.finalize().map { String(format: "%02x", $0) }.joined()
        guard got == want else { return .kept("changed since it was archived") }
        // The name must still be this file: another put in its place meanwhile is never removed.
        var now = stat()
        guard fstatat(dir, name, &now, AT_SYMLINK_NOFOLLOW) == 0, now.st_dev == st.st_dev, now.st_ino == st.st_ino else {
            return .kept("it was replaced while it was checked")
        }
        guard unlinkat(dir, name, 0) == 0 else { return .kept("it could not be removed: \(String(cString: strerror(errno)))") }
        return .removed
    }

    /// One file a discard would remove: where it is now, the sha256 its archive holds, and the name it was archived under.
    public struct Target: Equatable, Sendable {
        public var path: String
        public var sha256: String
        public var name: String
        public init(path: String, sha256: String, name: String) { self.path = path; self.sha256 = sha256; self.name = name }
    }

    /// The files of session `session` a discard may remove, from the archive's files that name it: Dozable's kept copy (in
    /// the store, `<ended>-<uuid>.jsonl`), a carried copy (by the record's `carried` `name:sha256`, the same sha256 as the
    /// archive's), an unfenced session's recorded conversation (exactly `<projects>/<slug>/<id>.jsonl`). Pure.
    public static func targets(session: String, archived: [RunArchive.File], keptRoot: String, own: [MacTranscripts.Item]) -> [Target] {
        var out: [Target] = []
        for f in archived where f.session == session {
            guard let src = f.sourceSHA256 else { continue }
            let base = (f.path as NSString).lastPathComponent
            switch f.source {
            case "archive":
                guard let dash = base.firstIndex(of: "-") else { continue }
                let ended = String(base[..<dash]), name = String(base[base.index(after: dash)...])
                guard MacTranscripts.isTranscriptName(name), !ended.contains("/"), !ended.isEmpty else { continue }
                out.append(Target(path: keptRoot + "/" + ended + "/" + name, sha256: src, name: f.path))
            case "carried":
                let name = base.hasPrefix("carried-") ? String(base.dropFirst("carried-".count)) : base
                for i in own where i.source == "carried" && i.name == name && i.sha256 == src { out.append(Target(path: i.path, sha256: src, name: f.path)) }
            case "conversation":
                for i in own where i.source == "conversation" && i.name == base { out.append(Target(path: i.path, sha256: src, name: f.path)) }
            default:
                continue
            }
        }
        return out
    }
}
