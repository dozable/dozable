import Darwin
import DozableHost
import Foundation

/// 749 (WS.02): `doz debug stub-agent --name NAME [--room ROOM] [--task TASK]` — the stub agent the daemon starts in place of
/// a workspace agent's program under `DOZ_TEST_STUB_AGENT=1` (guarded runs only; `StubAgent` holds its words and decisions).
/// It runs where the agent would, inside a fence too, so it is taken before anything of doz is read or made
/// (`DozableEntry`), reads no settings, store or token, and speaks only through `dozchat` — the one beside this doz (the file
/// a fence lets it run), with the environment the daemon gave it (`CHAT_URL`, `CHAT_TOKEN_FILE`, the proxy). Every message
/// is handed to dozchat on stdin (`send ROOM -`), so nothing it says is ever read as an option.
enum StubAgentRunner {
    static func run(_ args: [String], environment env: [String: String]) -> Int32 {
        guard TestSafety.stubAgent(env) else {
            FileHandle.standardError.write(Data("doz: the stub agent is a test hook: it runs only in a guarded test run with \(StubAgent.variable)=1\n".utf8))
            return ExitCodes.notPermitted
        }
        guard let o = StubAgent.Options.parse(args) else {
            FileHandle.standardError.write(Data("usage: doz debug stub-agent --name NAME [--room ROOM] [--task TASK]\n".utf8))
            return ExitCodes.usage
        }
        guard let chat = dozchat(env) else {
            FileHandle.standardError.write(Data("doz: the stub agent needs dozchat-mac beside doz\n".utf8))
            return ExitCodes.failed
        }
        return Stub(o, dozchat: chat, resumed: env[StubAgent.resumedVariable] == "1").run()
    }

    /// dozchat-mac beside this doz, else `dozchat` on the PATH.
    static func dozchat(_ env: [String: String]) -> String? {
        if let u = MacDozchat.locate(executable: HostLauncher.executablePath, environment: [:]).url { return u.path }
        for dir in (env["PATH"] ?? "").split(separator: ":") {
            let p = String(dir) + "/dozchat"
            if access(p, X_OK) == 0 { return p }
        }
        return nil
    }
}

/// One stub agent's run: up, its task, then every message addressed to it until a signal ends it.
private final class Stub: @unchecked Sendable {
    let o: StubAgent.Options
    let dozchat: String
    let resumed: Bool
    let workdir = FileManager.default.currentDirectoryPath
    private let lock = NSLock()
    private var children: Set<pid_t> = []
    private var sources: [DispatchSourceSignal] = []

    init(_ o: StubAgent.Options, dozchat: String, resumed: Bool) {
        self.o = o
        self.dozchat = dozchat
        self.resumed = resumed
    }

    func run() -> Int32 {
        // A sleep, a stop or an end: quietly, 0. `doz debug crash`: the crash code, posting nothing.
        signal(SIGPIPE, SIG_IGN)            // a dozchat that went away is never this process's end
        let q = DispatchQueue(label: "doz.stub-agent.signals")
        for (sig, code) in [(SIGHUP, Int32(0)), (SIGTERM, 0), (SIGINT, 0), (StubAgent.crashSignal, StubAgent.crashExitCode)] {
            signal(sig, SIG_IGN)
            let s = DispatchSource.makeSignalSource(signal: sig, queue: q)
            s.setEventHandler { [weak self] in self?.leave(code) }
            s.resume()
            sources.append(s)
        }
        let room = o.room
        if let room {
            say(room, StubAgent.isUp(o.name))
            if let t = o.task, !resumed {
                say(room, StubAgent.task(t))
                say(room, StubAgent.done)
            }
        }
        var backoff: UInt32 = 1
        while true {
            let began = Date()
            listen()
            // dozchat listen retries on its own while the server does not answer; an exit is a refusal (a token revoked):
            // again, a moment later.
            if Date().timeIntervalSince(began) > 30 { backoff = 1 }
            sleep(backoff)
            backoff = min(backoff * 2, 8)
        }
    }

    /// Ends this process with `code`, its children first.
    func leave(_ code: Int32) {
        let kids = lock.withLock { children }
        for p in kids { kill(p, SIGKILL) }
        _exit(code)
    }

    // MARK: listening

    private func listen() {
        guard let (pid, out) = spawn([dozchat, "listen"], stdin: nil, captureOutput: true) else { return }
        var pending = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(out, &buf, buf.count)
            if n < 0, errno == EINTR { continue }
            if n <= 0 { break }
            pending.append(contentsOf: buf[0..<n])
            while let nl = pending.firstIndex(of: 0x0A) {
                let line = pending[pending.startIndex..<nl]
                pending.removeSubrange(pending.startIndex...nl)
                if let a = StubAgent.addressed(Data(line), name: o.name) { handle(a) }
            }
        }
        close(out)
        reap(pid)
    }

    private func handle(_ a: StubAgent.Addressed) {
        switch a.command {
        case .ack: say(a.room, StubAgent.ack(a.msgID), re: a.msgID)
        case .ping: say(a.room, StubAgent.pong, re: a.msgID)
        case .unknown(let w): say(a.room, StubAgent.unknown(w), re: a.msgID)
        case .exit(let code): leave(code)
        case .write(let path): say(a.room, write(path), re: a.msgID)
        case .ask(let question):
            guard !question.hasPrefix("-") else { say(a.room, StubAgent.askRefused("a question may not start with -"), re: a.msgID); return }
            var argv = [dozchat, "ask", a.room, question]
            for opt in StubAgent.askOptions { argv += ["--option", opt] }
            let (code, output) = runCapturing(argv)
            if let text = StubAgent.askAnswer(exit: code, output: output) { say(a.room, text, re: a.msgID) }
        }
    }

    private func write(_ path: String) -> String {
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, 0o644)
        guard fd >= 0 else { return StubAgent.refused(path, StubAgent.writeRefusal(errno: errno, path: path, workdir: workdir)) }
        let text = Array("written by the stub agent \(o.name)\n".utf8)
        let n = text.withUnsafeBufferPointer { Darwin.write(fd, $0.baseAddress, $0.count) }
        let e = errno
        close(fd)
        guard n == text.count else { return StubAgent.refused(path, StubAgent.writeRefusal(errno: e, path: path, workdir: workdir)) }
        return StubAgent.wrote(path)
    }

    // MARK: dozchat

    /// One message, its text on dozchat's stdin (never an argument, so never read as an option).
    private func say(_ room: String, _ text: String, re: String? = nil) {
        var argv = [dozchat, "send", room, "-"]
        if let re { argv += ["--re", re] }
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { return }
        guard let (pid, _) = spawn(argv, stdin: fds[0], captureOutput: false) else { close(fds[0]); close(fds[1]); return }
        close(fds[0])
        let bytes = Array(text.utf8)
        _ = bytes.withUnsafeBufferPointer { Darwin.write(fds[1], $0.baseAddress, $0.count) }
        close(fds[1])
        reap(pid)
    }

    /// A dozchat call's exit code and everything it printed (stdout and stderr).
    private func runCapturing(_ argv: [String]) -> (Int32, String) {
        guard let (pid, out) = spawn(argv, stdin: nil, captureOutput: true, mergeStderr: true) else { return (1, "") }
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 16384)
        while true {
            let n = read(out, &buf, buf.count)
            if n < 0, errno == EINTR { continue }
            if n <= 0 { break }
            data.append(contentsOf: buf[0..<n])
        }
        close(out)
        return (reap(pid), String(decoding: data, as: UTF8.self))
    }

    /// posix_spawn with every signal at its default and none blocked (this process ignores the ones it handles), stdout
    /// piped back when asked; stdin the given descriptor, else /dev/null. Answers the pid and the read end.
    private func spawn(_ argv: [String], stdin: Int32?, captureOutput: Bool, mergeStderr: Bool = false) -> (pid_t, Int32)? {
        var out: [Int32] = [-1, -1]
        if captureOutput, pipe(&out) != 0 { return nil }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        if let i = stdin { posix_spawn_file_actions_adddup2(&actions, i, 0) } else { posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0) }
        if captureOutput { posix_spawn_file_actions_adddup2(&actions, out[1], 1) } else { posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0) }
        if captureOutput, mergeStderr { posix_spawn_file_actions_adddup2(&actions, out[1], 2) } else { posix_spawn_file_actions_addinherit_np(&actions, 2) }
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        var all = sigset_t(), none = sigset_t()
        sigfillset(&all)
        sigemptyset(&none)
        posix_spawnattr_setsigdefault(&attr, &all)
        posix_spawnattr_setsigmask(&attr, &none)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT))
        var cargs = argv.map { strdup($0) } + [nil]
        defer { for p in cargs { free(p) } }
        var pid: pid_t = 0
        let rc = lock.withLock { () -> Int32 in
            let r = posix_spawn(&pid, argv[0], &actions, &attr, &cargs, environ)
            if r == 0 { children.insert(pid) }
            return r
        }
        if captureOutput { close(out[1]) }
        guard rc == 0 else {
            if captureOutput { close(out[0]) }
            return nil
        }
        return (pid, captureOutput ? out[0] : -1)
    }

    @discardableResult
    private func reap(_ pid: pid_t) -> Int32 {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0, errno == EINTR {}
        lock.withLock { _ = children.remove(pid) }
        if (status & 0x7f) == 0 { return (status >> 8) & 0xff }
        return 128 + (status & 0x7f)
    }
}
