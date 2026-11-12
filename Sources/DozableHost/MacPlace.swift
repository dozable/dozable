import CryptoKit
import Darwin
import DozableKit
import Foundation

/// `@mac` — the place that is THIS Mac: terminal sessions held by `deckhold-mac` beside the host, never a sandbox.
///
/// A sandbox name is `a-z0-9-`, so `@mac` can never be one. Session commands take it as their PLACE
/// (`doz run @mac`, `doz attach @mac`, `doz sessions @mac`, `doz sessions end|restart|send|screen|wait @mac S`); every other
/// command refuses it with one message. Nothing about it is isolated: no VM, no proxy, no key placeholders — its
/// programs run as the person, with the person's files, Keychain and network. No code path may treat it as a sandbox
/// (no `Managed`, no `Sandbox`): `HostCore.perform` routes it to `MacSessions` before anything looks a sandbox up.
public enum MacPlace {
    public static let name = "@mac"

    public static func isPlace(_ s: String?) -> Bool { s == name }

    /// The host operations `@mac` takes; anything else is refused (`refusal`).
    public static let operations: Set<HostOp> = [.openSession, .sessions, .sessionScreen, .sessionLive, .sessionSend, .sessionEnd,
                                                 .sessionRestart, .sessionWait, .attach, .sessionGrids, .sessionResume, .sessionQuarantine,
                                                 // A FENCED session's network (`--session S`): its permissions, policy, log.
                                                 .netPermissions, .netPolicy, .netLog]

    public static func refusal(_ what: String) -> HostError {
        HostError(.invalid, "@mac is this Mac, not a sandbox — it has no start, sleep, network or keys, so \(what) does not apply "
                  + "(@mac takes doz run, attach and sessions; for a command on this Mac, use your own shell)")
    }

    /// Session names under `@mac`: at most this long (the socket path's budget).
    public static let maximumSessionName = 32

    public static func validateSessionName(_ s: String) throws {
        do { try GuestCommand.validateSessionName(s) } catch {
            throw HostError(.invalid, "\(s) is not a session name — letters, digits, '.', '_' and '-', not starting with '.'")
        }
        guard s.count <= maximumSessionName else {
            throw HostError(.invalid, "a session on this Mac has a name of at most \(maximumSessionName) characters (\(s) has \(s.count))")
        }
    }

    /// The bytes a unix socket path may have (sun_path, with its NUL).
    public static let socketPathLimit = 104

    /// The per-user temporary folder macOS keeps for this user (`confstr(_CS_DARWIN_USER_TEMP_DIR)`) — never `$TMPDIR`,
    /// which a caller can set.
    public static func userTempDirectory() -> String {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        let n = confstr(_CS_DARWIN_USER_TEMP_DIR, &buf, buf.count)
        guard n > 0, n <= buf.count else { return "/private/tmp/" }
        let s = String(decoding: buf.prefix(n - 1).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return s.hasSuffix("/") ? s : s + "/"
    }

    /// The store's socket folder: the user's temporary folder + `dh-<8 hex of the store path>` — two stores never share
    /// one, and a test's scratch store never meets a real host's.
    public static func socketDirectory(store: DozableStore, temp: String = userTempDirectory()) -> String {
        let h = SHA256.hash(data: Data(store.root.standardizedFileURL.path.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
        return temp + "dh-" + h
    }

    /// Where session `s`'s holder listens.
    public static func socketPath(_ dir: String, _ s: String) -> String { dir + "/" + s + ".sock" }

    /// Every path the holder makes for a session (`NAME.sock`, `.exit`, `.log`) fits a unix socket's budget.
    public static func checkPathBudget(_ dir: String, _ s: String) throws {
        let longest = socketPath(dir, s).utf8.count
        guard longest < socketPathLimit else {
            throw HostError(.invalid, "the socket path for \(s) would be \(longest) bytes (at most \(socketPathLimit - 1)) — a shorter session name")
        }
    }

    /// Why `dir` must not be used (nil: it is fine) — a folder (not a link), owned by this user, mode 0700.
    public static func folderProblem(_ dir: String, uid: uid_t = getuid()) -> String? {
        var st = stat()
        guard lstat(dir, &st) == 0 else { return "\(dir) is not there" }
        if (st.st_mode & S_IFMT) == S_IFLNK { return "\(dir) is a link — refused" }
        guard (st.st_mode & S_IFMT) == S_IFDIR else { return "\(dir) is not a folder — refused" }
        guard st.st_uid == uid else { return "\(dir) belongs to another user — refused" }
        guard (st.st_mode & 0o777) == 0o700 else { return String(format: "%@ has mode %o, not 700 — refused", dir, st.st_mode & 0o777) }
        return nil
    }

    /// Make the folder (0700) when it is not there, then check it.
    public static func ensureFolder(_ dir: String) throws {
        if mkdir(dir, 0o700) != 0, errno != EEXIST {
            throw HostError(.failed, "cannot make \(dir): \(String(cString: strerror(errno)))")
        }
        if let p = folderProblem(dir) { throw HostError(.failed, "the session folder for this Mac: \(p)") }
    }

    /// Whether `path` is a socket this user owns (a stale one may be removed).
    public static func isOwnSocket(_ path: String, uid: uid_t = getuid()) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFSOCK && st.st_uid == uid
    }

    // MARK: what a program asks for

    /// The argv asks for its permissions to be bypassed — allowed (the session's own choice), never added by Dozable,
    /// and marked wherever the session is shown.
    public static func bypassesPermissions(_ argv: [String]) -> Bool {
        for (i, a) in argv.enumerated() {
            if a == "--dangerously-skip-permissions" || a == "--dangerously-bypass-approvals-and-sandbox" { return true }
            if a == "--permission-mode=bypassPermissions" { return true }
            if a == "--permission-mode", i + 1 < argv.count, argv[i + 1] == "bypassPermissions" { return true }
        }
        return false
    }

    /// Claude Code's own argv (the program is `claude`).
    public static func isClaude(_ argv: [String]) -> Bool {
        argv.first.map { ($0 as NSString).lastPathComponent == "claude" } ?? false
    }

    /// What a restart appends: `claude` continues the folder's newest conversation (`--continue`) unless `fresh`, or its
    /// argv already names one.
    public static func resumeArguments(_ argv: [String], fresh: Bool) -> [String] {
        guard !fresh, isClaude(argv) else { return [] }
        let names = ["--continue", "-c", "--resume", "-r"]
        if argv.dropFirst().contains(where: { a in names.contains(a) || a.hasPrefix("--resume=") }) { return [] }
        return ["--continue"]
    }

    /// Claude Code keeps a folder's conversations in `<projects>/<the folder, every character but A-Z a-z 0-9 a '-'>/*.jsonl`.
    public static func claudeProjectFolderName(_ dir: String) -> String {
        String(dir.unicodeScalars.map { s -> Character in
            s.isASCII && (CharacterSet.alphanumerics.contains(s)) ? Character(s) : "-"
        })
    }

    /// Where this Mac's Claude Code keeps its projects: `$CLAUDE_CONFIG_DIR/projects`, else `~/.claude/projects`.
    /// TEST SEAM (guarded runs only): `DOZ_TEST_CLAUDE_PROJECTS`.
    public static func claudeProjects(_ env: [String: String]) -> String {
        if TestSafety.guarded(env), let p = env["DOZ_TEST_CLAUDE_PROJECTS"], p.hasPrefix("/") { return p }
        if let c = env["CLAUDE_CONFIG_DIR"], c.hasPrefix("/") { return c + "/projects" }
        return (env["HOME"].flatMap { $0.hasPrefix("/") ? $0 : nil } ?? NSHomeDirectory()) + "/.claude/projects"
    }

    /// Claude Code has a conversation to continue in `workdir` (as given, or resolved — `/tmp` is `/private/tmp`).
    /// `claude --continue` with none exits at once, which would end the session it was restarted in.
    public static func claudeHasConversation(workdir: String, projects: String) -> Bool {
        var dirs = [workdir]
        if let r = realpath(workdir, nil) { dirs.append(String(cString: r)); free(r) }
        for d in Set(dirs) {
            let folder = projects + "/" + claudeProjectFolderName(d)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
            if names.contains(where: { $0.hasSuffix(".jsonl") }) { return true }
        }
        return false
    }

    /// The one line `doz run @mac` says on stderr.
    public static let noIsolationLine = "@mac is this Mac: no sandbox, no proxy, no key placeholders — this program can reach everything your user can (files, Keychain, network)."
    /// The mark of a session whose argv bypasses permissions.
    public static let bypassedMark = "permissions bypassed — nothing around it"
}
