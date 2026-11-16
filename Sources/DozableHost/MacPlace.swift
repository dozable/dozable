import CryptoKit
import Darwin
import DozableKit
import Foundation

/// `@mac` — the place that is THIS Mac: terminal sessions held by `deckhold-mac` beside the host, never a sandbox.
///
/// A sandbox name is `a-z0-9-`, so `@mac` can never be one. Session commands take it as their PLACE
/// (`doz run @mac`, `doz attach @mac`, `doz sessions @mac`, `doz sessions end|restart|send|screen|wait @mac S`); every other
/// command refuses it with one message. It is never a sandbox: no VM, and no code path may treat it as one (no `Managed`,
/// no `Sandbox`) — `HostCore.perform` routes it to `MacSessions` before anything looks a sandbox up. A proxy and key
/// placeholders exist ONLY inside the fence (`MacFence`; fenced is the default for a new session, `--unfenced` opts out),
/// per session, served by the host on a socket its holder owns; nothing a fenced program can write is later executed or
/// loaded by anything unfenced except the project's own files. An UNFENCED session's program runs as the person, with
/// the person's files, Keychain and network, and no proxy or placeholder ever. A bypass flag is only ever the session's
/// own argv, marked.
public enum MacPlace {
    public static let name = "@mac"

    public static func isPlace(_ s: String?) -> Bool { s == name }

    /// The host operations `@mac` takes; anything else is refused (`refusal`).
    public static let operations: Set<HostOp> = [.openSession, .sessions, .sessionScreen, .sessionLive, .sessionSend, .sessionEnd,
                                                 .sessionRestart, .sessionWait, .attach, .sessionGrids, .sessionResume, .sessionQuarantine,
                                                 .sessionBridges, .sessionTranscripts,
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
        temp + "dh-" + storeHash(store)
    }

    /// 8 hex of the store path's sha256 — the socket folder's name, and (694) the store's login item's label.
    public static func storeHash(_ store: DozableStore) -> String {
        SHA256.hash(data: Data(store.root.standardizedFileURL.path.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
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

    /// What a restart appends when nothing more is known (no id, a conversation in the folder) — `restartArgv`'s answer
    /// as the extra arguments (kept for its callers and tests): `claude` continues the folder's newest conversation
    /// (`--continue`) unless `fresh`, or its argv already names one.
    public static func resumeArguments(_ argv: [String], fresh: Bool) -> [String] {
        guard !fresh, isClaude(argv) else { return [] }
        let names = ["--continue", "-c", "--resume", "-r"]
        if argv.dropFirst().contains(where: { a in names.contains(a) || a.hasPrefix("--resume=") }) { return [] }
        return ["--continue"]
    }

    /// How a restart resumes Claude Code (`restartArgv`'s second answer).
    public enum RestartResume: Equatable, Sendable {
        /// `--resume ID`: the conversation has a transcript.
        case resume(String)
        /// `--session-id ID` again: the id is known but it never talked (`--resume` would fail "No conversation found").
        case sessionID(String)
        /// `--continue`: no id known, the folder has a conversation.
        case continued
        /// Nothing added: `--fresh`, no id and no conversation in the folder, or not Claude Code.
        case none
    }

    /// Claude Code's flags that take a value — the value is never read as a flag (`-n -c` is a name, not `--continue`).
    static let claudeValueFlags: Set<String> = ["--session-id", "--name", "-n", "--model", "--append-system-prompt", "--system-prompt",
                                                "--permission-mode", "--settings", "--agent"]
    /// …and the ones whose value is optional (taken only when the next word is not a flag).
    static let claudeOptionalValueFlags: Set<String> = ["--resume", "-r", "--remote-control"]

    /// A Claude Code session id as Dozable uses one: an RFC 4122 UUID, lower-cased (nil: not one).
    public static func claudeSessionID(_ s: String?) -> String? {
        guard let s, s.count == 36, UUID(uuidString: s) != nil else { return nil }
        return s.lowercased()
    }

    /// 685 M1 — the argv a restart of `argv` opens (pure; `MacPlaceTests`). Only for `claude`; any other program is
    /// returned as it is. First every conversation choice in the argv is taken out — `--session-id X`/`=X`, `--continue`/`-c`,
    /// `--resume X`/`-r X`/`--resume=X`, a bare `--resume`/`-r` (a picker: it would wait for a person), `--fork-session`
    /// (each restart would fork again) — then ONE is put back, where the first one was (else at the end):
    /// the id to resume is `knownID` (what Claude holds now, else the record's learned one), else the argv's
    /// `--session-id X`, else its `--resume X`; with a transcript (`transcriptExists`) → `--resume ID`; without one →
    /// `--session-id ID` (it never talked); no id → `--continue` when the folder `hasConversation`, else nothing.
    /// `fresh` adds nothing (a `--session-id` is dropped too: Claude refuses an id in use).
    /// INVARIANT (tested over generated argvs): the answer never carries `--continue` beside `--session-id`.
    public static func restartArgv(_ argv: [String], fresh: Bool, knownID: String?, transcriptExists: (String) -> Bool,
                                   hasConversation: Bool) -> (argv: [String], how: RestartResume) {
        guard isClaude(argv) else { return (argv, .none) }
        var kept: [String] = [argv[0]]
        var insertAt: Int?
        var argSessionID: String?, argResumeID: String?
        var i = 1
        func strip() { if insertAt == nil { insertAt = kept.count } }
        while i < argv.count {
            let a = argv[i]
            if a == "--" { kept.append(contentsOf: argv[i...]); break }
            let next: String? = i + 1 < argv.count ? argv[i + 1] : nil
            switch a {
            case "--session-id":
                strip()
                if let n = next { argSessionID = argSessionID ?? claudeSessionID(n); i += 2 } else { i += 1 }
                continue
            case "--continue", "-c", "--fork-session":
                strip(); i += 1; continue
            case "--resume", "-r":
                strip()
                if let n = next, !n.hasPrefix("-") { argResumeID = argResumeID ?? claudeSessionID(n); i += 2 } else { i += 1 }
                continue
            default:
                break
            }
            if a.hasPrefix("--session-id=") {
                strip(); argSessionID = argSessionID ?? claudeSessionID(String(a.dropFirst("--session-id=".count))); i += 1; continue
            }
            if a.hasPrefix("--resume=") {
                strip(); argResumeID = argResumeID ?? claudeSessionID(String(a.dropFirst("--resume=".count))); i += 1; continue
            }
            kept.append(a)
            if claudeValueFlags.contains(a), let n = next { kept.append(n); i += 2; continue }
            if claudeOptionalValueFlags.contains(a), let n = next, !n.hasPrefix("-") { kept.append(n); i += 2; continue }
            i += 1
        }
        if fresh { return (kept, .none) }
        let id = claudeSessionID(knownID) ?? argSessionID ?? argResumeID
        let add: [String]
        let how: RestartResume
        if let id {
            if transcriptExists(id) { add = ["--resume", id]; how = .resume(id) } else { add = ["--session-id", id]; how = .sessionID(id) }
        } else if hasConversation {
            add = ["--continue"]; how = .continued
        } else {
            return (kept, .none)
        }
        let at = min(insertAt ?? kept.count, kept.count)
        // A `--` ends the flags: what is put back goes before it.
        let dash = kept.firstIndex(of: "--") ?? kept.count
        kept.insert(contentsOf: add, at: min(at, dash))
        return (kept, how)
    }

    /// Where this Mac's Claude Code records which process holds which conversation: `$CLAUDE_CONFIG_DIR/sessions`, else
    /// `~/.claude/sessions` (`<pid>.json`, its `sessionId`) — the sibling of `claudeProjects`.
    /// TEST SEAM (guarded runs only): beside `DOZ_TEST_CLAUDE_PROJECTS` (its folder's `sessions`).
    public static func claudeSessions(_ env: [String: String]) -> String {
        if TestSafety.guarded(env), let p = env["DOZ_TEST_CLAUDE_PROJECTS"], p.hasPrefix("/") {
            return (p as NSString).deletingLastPathComponent + "/sessions"
        }
        return (claudeProjects(env) as NSString).deletingLastPathComponent + "/sessions"
    }

    /// The conversation a Claude Code process holds, from its `<sessions>/<pid>.json` (nil: none, not a regular file of
    /// at most 64 KiB — a link is refused —, not JSON, or no UUID `sessionId`). Internal to Claude Code: read defensively.
    public static func claudeHeldSessionID(sessions: String, pid: Int) -> String? {
        // The folder resolved (`/tmp` is `/private/tmp`); the file itself is opened with no link anywhere in its path.
        let dir = MacFencePaths.resolve(sessions) ?? sessions
        guard pid > 0, let d = try? MacFenceHostFS.readRegular(dir + "/\(pid).json", maximum: 64 << 10) else { return nil }
        return claudeHeldSessionID(json: d)
    }

    static func claudeHeldSessionID(json d: Data) -> String? {
        guard let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return nil }
        return claudeSessionID(o["sessionId"] as? String)
    }

    /// Conversation `id` has a transcript in `workdir`'s projects folder (as given, or resolved).
    public static func claudeTranscriptExists(id: String, workdir: String, projects: String) -> Bool {
        guard claudeSessionID(id) != nil else { return false }
        var dirs = [workdir]
        if let r = realpath(workdir, nil) { dirs.append(String(cString: r)); free(r) }
        for d in Set(dirs) {
            var st = stat()
            if lstat(projects + "/" + claudeProjectFolderName(d) + "/" + id.lowercased() + ".jsonl", &st) == 0, (st.st_mode & S_IFMT) == S_IFREG { return true }
        }
        return false
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
