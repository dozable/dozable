import Darwin
import Foundation

// The owner's private socket (`--owner-socket PATH`): a Unix socket the server serves its page API on, as the HUMAN,
// with no token. It is how the person's own `doz chat` commands post, read and follow — so no human token needs to exist
// (nothing can steal one), and no TCP caller is ever the human. Who may connect is the file system's answer first: the
// socket's folder must be 0700 and the user's own, the socket is made 0600; then each connection's peer is asked
// (LOCAL_PEERCRED) and admitted only when it runs as this same user. A fenced session on this Mac runs as the same user
// too — Seatbelt, not the uid, keeps it out (the fence closes the store, and every Unix socket but its own doors).

public enum ChatOwnerSocket {
    /// The longest path a Unix socket's address can hold (sockaddr_un.sun_path, with its NUL).
    public static let maximumPathBytes = 103

    /// Whether a connecting process may act as the owner: only one that runs as this user (and only when its user could be
    /// read at all — an unknown peer is refused).
    public static func admit(peerUID: uid_t?, ourUID: uid_t = getuid()) -> Bool {
        guard let p = peerUID else { return false }
        return p == ourUID
    }

    /// Why the socket at `path` may not be served (nil: it may): its path is too long, or its folder is missing, a link,
    /// not a folder, not this user's, or open to anyone else (it must be 0700). Something already at the path that is not
    /// a socket is never removed.
    public static func refusal(path: String, ourUID: uid_t = getuid()) -> String? {
        guard path.hasPrefix("/") else { return "--owner-socket \(path): give an absolute path" }
        guard path.utf8.count <= maximumPathBytes else {
            return "--owner-socket \(path): the path is \(path.utf8.count) bytes; a socket's path can be at most \(maximumPathBytes)"
        }
        let dir = (path as NSString).deletingLastPathComponent
        var st = stat()
        guard lstat(dir, &st) == 0 else { return "--owner-socket: its folder \(dir) does not exist" }
        guard (st.st_mode & S_IFMT) == S_IFDIR else { return "--owner-socket: \(dir) is not a folder (a link is refused)" }
        guard st.st_uid == ourUID else { return "--owner-socket: the folder \(dir) belongs to another user" }
        guard st.st_mode & 0o077 == 0 else {
            return String(format: "--owner-socket: the folder %@ is open to other users (mode %04o); it must be 0700", dir, Int(st.st_mode & 0o777))
        }
        var s = stat()
        if lstat(path, &s) == 0, (s.st_mode & S_IFMT) != S_IFSOCK {
            return "--owner-socket: \(path) exists and is not a socket"
        }
        return nil
    }
}
