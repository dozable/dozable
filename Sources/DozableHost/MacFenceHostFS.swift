import Darwin
import Foundation

/// The ONE way the host touches a place a fenced program can write — the workdir, the session's own folder (and, later,
/// the carried-back transcripts). The host is unfenced: anything it does there is a confused-deputy risk (a component
/// swapped for a link turns "clear the session's temp" into deleting the person's files, "strip a git key" into rewriting
/// another repository's config). So:
///
/// - every open, stat, delete and rename uses `O_NOFOLLOW_ANY` (no link in ANY component of the path), or a `dirfd` walk
///   from a directory opened that way (`openat(…, O_NOFOLLOW)`, `unlinkat`, `renameat`, `fstatat(AT_SYMLINK_NOFOLLOW)`);
/// - a file it reads or replaces is a regular file, `st_nlink == 1`, owned by this user (a hard link to a file elsewhere is
///   refused);
/// - a tree is removed by a `dirfd` walk that never descends through a link (a link is unlinked as a link) and stays on its
///   starting device;
/// - every refusal is an error naming the path and why (the caller makes it a note — for git, a violation).
///
/// Every path given here must already be resolved (`realpath`): `/tmp` is a link to `/private/tmp`, and `O_NOFOLLOW_ANY`
/// refuses it. `MacFenceHostFSTests`.
public enum MacFenceHostFS {
    public struct Refusal: Error, CustomStringConvertible, Equatable {
        public let path: String
        public let why: String
        public var description: String { "\(DisplayPath.tilde(path)): \(why)" }
    }

    /// `O_NOFOLLOW_ANY` (sys/fcntl.h, macOS 11+): no symbolic link in any component of the path.
    static let noFollowAny: Int32 = 0x2000_0000

    static func errnoText(_ e: Int32 = errno) -> String { String(cString: strerror(e)) }

    /// Open `path` (absolute, resolved) with no link in any component.
    static func open(_ path: String, _ flags: Int32, _ mode: mode_t = 0) throws -> Int32 {
        guard path.hasPrefix("/") else { throw Refusal(path: path, why: "not an absolute path") }
        let fd = Darwin.open(path, flags | noFollowAny | O_CLOEXEC, mode)
        guard fd >= 0 else {
            let e = errno
            throw Refusal(path: path, why: e == ELOOP ? "a link in its path — not followed" : errnoText(e))
        }
        return fd
    }

    /// A folder, opened for walking (no link anywhere in its path).
    public static func openDirectory(_ path: String) throws -> Int32 {
        try open(path, O_RDONLY | O_DIRECTORY)
    }

    /// Read a regular file: no link in its path, `st_nlink == 1`, this user's, at most `maximum` bytes.
    public static func readRegular(_ path: String, maximum: Int, uid: uid_t = getuid()) throws -> Data {
        let fd = try open(path, O_RDONLY | O_NONBLOCK)
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw Refusal(path: path, why: errnoText()) }
        try checkRegular(st, path: path, uid: uid)
        guard st.st_size <= off_t(maximum) else { throw Refusal(path: path, why: "larger than \(maximum) bytes") }
        var out = Data(count: Int(st.st_size))
        var got = 0
        while got < out.count {
            let n = out.withUnsafeMutableBytes { read(fd, $0.baseAddress! + got, $0.count - got) }
            if n < 0 { if errno == EINTR { continue }; throw Refusal(path: path, why: errnoText()) }
            if n == 0 { break }
            got += n
        }
        return out.prefix(got)
    }

    /// Why a stat result is not a file the host may read or replace (nil: it may).
    static func checkRegular(_ st: stat, path: String, uid: uid_t) throws {
        guard (st.st_mode & S_IFMT) == S_IFREG else { throw Refusal(path: path, why: "not a regular file") }
        guard st.st_nlink == 1 else { throw Refusal(path: path, why: "a hard link (\(st.st_nlink) names) — refused") }
        guard st.st_uid == uid else { throw Refusal(path: path, why: "not yours") }
    }

    /// What `path` is, without following a link anywhere (`nil`: not there).
    public static func kind(_ path: String) -> mode_t? {
        let parent = (path as NSString).deletingLastPathComponent, name = (path as NSString).lastPathComponent
        guard let dfd = try? openDirectory(parent) else { return nil }
        defer { close(dfd) }
        var st = stat()
        guard fstatat(dfd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { return nil }
        return st.st_mode & S_IFMT
    }

    /// Write `data` as `dir/name` atomically: a fresh temp name (`O_CREAT|O_EXCL|O_NOFOLLOW`) in the SAME folder opened
    /// with no link in its path, then `renameat` over the name. An existing `name` must be a regular file (or absent) —
    /// a link or a folder there is refused, never written through.
    public static func writeAtomically(_ data: Data, dir: String, name: String, mode: mode_t = 0o600, sync: Bool = false, uid: uid_t = getuid()) throws {
        guard !name.contains("/"), name != ".", name != ".." else { throw Refusal(path: dir + "/" + name, why: "not a name") }
        let dfd = try openDirectory(dir)
        defer { close(dfd) }
        var st = stat()
        if fstatat(dfd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 {
            guard (st.st_mode & S_IFMT) == S_IFREG else { throw Refusal(path: dir + "/" + name, why: "not a regular file — not replaced") }
        }
        let temp = ".\(name).doz-\(UInt32.random(in: 0...UInt32.max))"
        let fd = openat(dfd, temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
        guard fd >= 0 else { throw Refusal(path: dir + "/" + temp, why: errnoText()) }
        var ok = false
        defer { if !ok { unlinkat(dfd, temp, 0) } }
        var written = 0
        while written < data.count {
            let n = data.withUnsafeBytes { write(fd, $0.baseAddress! + written, $0.count - written) }
            if n < 0 { if errno == EINTR { continue }; close(fd); throw Refusal(path: dir + "/" + temp, why: errnoText()) }
            written += n
        }
        fchmod(fd, mode)
        if sync { fsync(fd) }       // a git config the host rewrote; the session folder's files are re-made at every open
        close(fd)
        guard renameat(dfd, temp, dfd, name) == 0 else { throw Refusal(path: dir + "/" + name, why: errnoText()) }
        ok = true
    }

    /// Make `path` a folder (mode `mode`) when it is not there; every component must be a folder, never a link.
    public static func ensureDirectory(_ path: String, mode: mode_t = 0o700) throws {
        let parts = path.split(separator: "/").map(String.init)
        var fd = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw Refusal(path: "/", why: errnoText()) }
        var at = ""
        for p in parts {
            at += "/" + p
            var next = openat(fd, p, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0 && errno == ENOENT {
                if mkdirat(fd, p, mode) != 0 && errno != EEXIST { let e = errno; close(fd); throw Refusal(path: at, why: errnoText(e)) }
                next = openat(fd, p, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            let e = errno
            close(fd)
            guard next >= 0 else { throw Refusal(path: at, why: e == ELOOP || e == ENOTDIR ? "a link or not a folder — refused" : errnoText(e)) }
            fd = next
        }
        close(fd)
    }

    /// Remove `path` itself — a file or a link unlinked as such, a folder by `removeTree`.
    public static func remove(_ path: String) throws {
        let parent = (path as NSString).deletingLastPathComponent, name = (path as NSString).lastPathComponent
        let dfd = try openDirectory(parent)
        defer { close(dfd) }
        var st = stat()
        guard fstatat(dfd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { if errno == ENOENT { return }; throw Refusal(path: path, why: errnoText()) }
        if (st.st_mode & S_IFMT) == S_IFDIR {
            var dev = stat(); fstat(dfd, &dev)
            try removeContents(dfd: dfd, name: name, path: path, device: dev.st_dev, depth: 0)
            guard unlinkat(dfd, name, AT_REMOVEDIR) == 0 else { throw Refusal(path: path, why: errnoText()) }
        } else {
            guard unlinkat(dfd, name, 0) == 0 else { throw Refusal(path: path, why: errnoText()) }
        }
    }

    /// Empty the folder `path` (it stays), except the top-level names `keep` says to keep. A link anywhere is unlinked as
    /// a link, never followed; a folder on another device is left (and said).
    @discardableResult
    public static func clearContents(_ path: String, keep: (String) -> Bool = { _ in false }) throws -> [String] {
        let dfd = try openDirectory(path)
        defer { close(dfd) }
        var st = stat()
        fstat(dfd, &st)
        var notes: [String] = []
        for name in try entries(dfd, path: path) where !keep(name) {
            var e = stat()
            guard fstatat(dfd, name, &e, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            if (e.st_mode & S_IFMT) == S_IFDIR {
                do {
                    try removeContents(dfd: dfd, name: name, path: path + "/" + name, device: st.st_dev, depth: 0)
                    if unlinkat(dfd, name, AT_REMOVEDIR) != 0 { notes.append("\(name): \(errnoText())") }
                } catch let r as Refusal { notes.append(r.description) }
            } else if unlinkat(dfd, name, 0) != 0 {
                notes.append("\(name): \(errnoText())")
            }
        }
        return notes
    }

    /// The names in an open folder (no `.`/`..`).
    static func entries(_ dfd: Int32, path: String) throws -> [String] {
        let dup = Darwin.dup(dfd)
        guard dup >= 0, let d = fdopendir(dup) else { throw Refusal(path: path, why: errnoText()) }
        defer { closedir(d) }
        rewinddir(d)
        var out: [String] = []
        while let ent = readdir(d) {
            let name = withUnsafePointer(to: ent.pointee.d_name) { $0.withMemoryRebound(to: CChar.self, capacity: 1024) { String(cString: $0) } }
            if name != "." && name != ".." { out.append(name) }
        }
        return out
    }

    /// Everything inside `parent/name` (a folder), depth-first, by `dirfd` — never through a link, never off `device`.
    static func removeContents(dfd parent: Int32, name: String, path: String, device: dev_t, depth: Int) throws {
        guard depth < 256 else { throw Refusal(path: path, why: "nested deeper than 256 folders — left") }
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Refusal(path: path, why: errno == ELOOP || errno == ENOTDIR ? "became a link — not followed" : errnoText()) }
        defer { close(fd) }
        var st = stat()
        fstat(fd, &st)
        guard st.st_dev == device else { throw Refusal(path: path, why: "on another volume — left") }
        for n in try entries(fd, path: path) {
            var e = stat()
            guard fstatat(fd, n, &e, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            if (e.st_mode & S_IFMT) == S_IFDIR {
                try removeContents(dfd: fd, name: n, path: path + "/" + n, device: device, depth: depth + 1)
                if unlinkat(fd, n, AT_REMOVEDIR) != 0 { throw Refusal(path: path + "/" + n, why: errnoText()) }
            } else if unlinkat(fd, n, 0) != 0 {
                throw Refusal(path: path + "/" + n, why: errnoText())
            }
        }
    }

    /// Move `path` (a file, a link or a folder — never followed) into the folder `into` (the store's quarantine) as
    /// `newName`. Across volumes: a file is copied through its descriptor and removed; anything else is removed.
    public static func move(_ path: String, into: String, newName: String) throws {
        let parent = (path as NSString).deletingLastPathComponent, name = (path as NSString).lastPathComponent
        let sfd = try openDirectory(parent)
        defer { close(sfd) }
        let dfd = try openDirectory(into)
        defer { close(dfd) }
        if renameat(sfd, name, dfd, newName) == 0 { return }
        guard errno == EXDEV else { throw Refusal(path: path, why: errnoText()) }
        var st = stat()
        if fstatat(sfd, name, &st, AT_SYMLINK_NOFOLLOW) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_size <= 4 << 20 {
            let data = try readRegular(path, maximum: 4 << 20)
            try writeAtomically(data, dir: into, name: newName)
        }
        try remove(path)
    }

    /// Walk `root` (resolved) for at most `maximum` entries, depth ≤ `maxDepth`, never through a link or off its device,
    /// calling `visit(path, mode)` for every entry (folders before their contents). `visit` returns false to not descend.
    /// Returns false when the walk was cut short (a limit).
    @discardableResult
    public static func walk(_ root: String, maximum: Int = 400_000, maxDepth: Int = 64,
                            visit: (String, mode_t) -> Bool) -> Bool {
        guard let fd = try? openDirectory(root) else { return true }
        var st = stat()
        fstat(fd, &st)
        var count = 0
        func go(_ fd: Int32, _ path: String, _ depth: Int) -> Bool {
            guard let names = try? entries(fd, path: path) else { return true }
            for n in names {
                count += 1
                if count > maximum { return false }
                var e = stat()
                guard fstatat(fd, n, &e, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
                let p = path + "/" + n
                let mode = e.st_mode & S_IFMT
                let descend = visit(p, mode)
                guard mode == S_IFDIR, descend, e.st_dev == st.st_dev else { continue }
                guard depth < maxDepth else { return false }
                let c = openat(fd, n, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard c >= 0 else { continue }
                let ok = go(c, p, depth + 1)
                close(c)
                if !ok { return false }
            }
            return true
        }
        let ok = go(fd, root, 0)
        close(fd)
        return ok
    }
}
