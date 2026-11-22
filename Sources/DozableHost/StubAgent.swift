import Darwin
import Foundation

/// 749 (WS.02): the STUB AGENT — a test hook, guarded runs only. With `DOZ_TEST_STUB_AGENT=1` in a guarded run
/// (`TestSafety.stubAgent`), the daemon starts `doz debug stub-agent …` wherever it would start an agent program for a
/// workspace's manager or worker on this Mac (fenced or unfenced) — never claude, never a VM (a VM manager or worker is
/// refused: `vmRefusal`). The stub is part of doz itself (the acceptance harness runs a release tarball), is stateless and
/// deterministic (no time, no randomness in what it posts), and speaks in chat only through `dozchat` with the token the
/// daemon handed it (`CHAT_TOKEN_FILE`) — it never reads a token itself. Its words (docs/engineering/workspaces.md, "Test
/// hooks"):
///
/// - start: `<name> is up` once in its room; a worker with a task then `task: <task>` and `done` (not again on a wake);
/// - `@<name> <text>`: `ack <first 8 of the message id>`; the script commands `@<name> /stub write PATH` (`wrote PATH`, or
///   `refused PATH: <reason>`), `/stub ask QUESTION` (an ask, options yes/no, for the room's deciders; `refused ask: no
///   decider` when there is none), `/stub exit CODE` (exits with it, posting nothing), `/stub ping` (`pong`);
/// - SIGHUP / SIGTERM / SIGINT (a sleep, a stop, an end): exits 0 quietly; `crashSignal` (`doz debug crash W/AGENT`): exits
///   `crashExitCode` without posting — a crash the daemon logs (`agent-crashed`).
///
/// The decisions here are pure (`StubAgentTests`); the runner is `DozableCLI/StubAgentRunner.swift`.
public enum StubAgent {
    /// The switch (guarded runs only).
    public static let variable = "DOZ_TEST_STUB_AGENT"
    /// Set by the daemon on a re-open (a wake, a start after a stop): the stub says it is up again but not its task.
    public static let resumedVariable = "DOZ_TEST_STUB_AGENT_RESUMED"
    /// `doz debug stub-agent` — taken before anything of doz is read or made (it runs inside a fence).
    public static let words = ["debug", "stub-agent"]
    /// What `doz debug crash` sends the stub, and the code it then exits with.
    public static let crashSignal: Int32 = SIGUSR1
    public static let crashExitCode: Int32 = 70

    /// The stub's argv: this doz, its words, its name, its room, its task (a worker's).
    public static func argv(doz: String, name: String, room: String?, task: String?) -> [String] {
        var a = [doz] + words + ["--name", name]
        if let room, !room.isEmpty { a += ["--room", room] }
        if let task, !task.isEmpty { a += ["--task=" + task] }
        return a
    }

    /// The environment the daemon gives it: its own (the plan's: `CHAT_URL`, …) plus the guard and the switch, so the stub
    /// itself also runs only as a test's; `resumed` on a re-open.
    public static func environment(_ base: [String: String], resumed: Bool) -> [String: String] {
        var e = base
        e["DOZ_TEST_GUARD"] = "1"
        e[variable] = "1"
        if resumed { e[resumedVariable] = "1" } else { e[resumedVariable] = nil }
        return e
    }

    /// A VM manager or worker under the stub: refused, nothing made or started (the stub never starts a VM).
    public static func vmRefusal(_ who: String) -> HostError {
        HostError(.invalid, "\(who) would run in a micro VM, and the stub agent (\(variable)=1) runs on this Mac only — no VM is started under it; "
                  + "make it fenced (or unfenced) for the test")
    }

    /// Is `argv` the stub agent called `name` (what `doz debug crash` checks before it signals a process)?
    public static func isStub(argv: [String], name: String) -> Bool {
        guard let i = argv.firstIndex(of: words[0]), i + 1 < argv.count, argv[i + 1] == words[1] else { return false }
        guard let n = argv.firstIndex(of: "--name"), n + 1 < argv.count else { return false }
        return argv[n + 1] == name
    }

    /// The stub's own arguments (after `debug stub-agent`): `--name NAME [--room ROOM] [--task TASK | --task=TASK]`. nil: not those.
    public struct Options: Equatable, Sendable {
        public var name: String
        public var room: String?
        public var task: String?

        public static func parse(_ args: [String]) -> Options? {
            var name: String?, room: String?, task: String?
            var i = 0
            while i < args.count {
                let a = args[i]
                if a.hasPrefix("--task=") { task = String(a.dropFirst(7)); i += 1; continue }
                if a.hasPrefix("--name=") { name = String(a.dropFirst(7)); i += 1; continue }
                if a.hasPrefix("--room=") { room = String(a.dropFirst(7)); i += 1; continue }
                guard ["--name", "--room", "--task"].contains(a), i + 1 < args.count else { return nil }
                let v = args[i + 1]
                switch a {
                case "--name": name = v
                case "--room": room = v
                default: task = v
                }
                i += 2
            }
            guard let name, !name.isEmpty else { return nil }
            return Options(name: name, room: room?.isEmpty == true ? nil : room, task: task?.isEmpty == true ? nil : task)
        }
    }

    // MARK: what it says

    public static func isUp(_ name: String) -> String { "\(name) is up" }
    public static func ack(_ msgID: String) -> String { "ack " + String(msgID.prefix(8)) }
    public static func task(_ t: String) -> String { "task: \(t)" }
    public static let done = "done"
    public static let pong = "pong"
    public static func wrote(_ path: String) -> String { "wrote \(path)" }
    public static func refused(_ path: String, _ reason: String) -> String { "refused \(path): \(reason)" }
    public static let noDecider = "refused ask: no decider"
    public static func askRefused(_ why: String) -> String { "refused ask: \(why)" }
    public static func unknown(_ word: String) -> String { "refused /stub \(word): not a stub command (write, ask, exit, ping)" }
    public static let askOptions = ["yes=yes", "no=no"]

    // MARK: what it hears

    /// A script command, or a plain message (`ack`).
    public enum Command: Equatable, Sendable {
        case ack
        case ping
        case write(String)
        case ask(String)
        case exit(Int32)
        case unknown(String)
    }

    /// A message addressed to the stub: where to answer and what it asks.
    public struct Addressed: Equatable, Sendable {
        public var room: String
        public var msgID: String
        public var from: String
        public var command: Command
    }

    /// The text after `@name` (nil: not addressed to `name` — the first word is not `@name`).
    public static func addressedText(_ content: String, name: String) -> String? {
        let t = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let tag = "@" + name
        guard t.hasPrefix(tag) else { return nil }
        let rest = t.dropFirst(tag.count)
        guard rest.isEmpty || rest.first!.isWhitespace else { return nil }
        return rest.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The command in the text after `@name`.
    public static func command(_ text: String) -> Command {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t == "/stub" || t.hasPrefix("/stub ") || t.hasPrefix("/stub\t") else { return .ack }
        let body = t.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
        let verb = body.prefix { !$0.isWhitespace }
        let arg = body.dropFirst(verb.count).trimmingCharacters(in: .whitespacesAndNewlines)
        switch verb {
        case "ping": return arg.isEmpty ? .ping : .unknown("ping " + arg)
        case "write": return arg.isEmpty ? .unknown("write") : .write(arg)
        case "ask": return arg.isEmpty ? .unknown("ask") : .ask(arg)
        case "exit":
            guard let c = Int32(arg), (0...255).contains(c) else { return .unknown(arg.isEmpty ? "exit" : "exit " + arg) }
            return .exit(c)
        default: return .unknown(verb.isEmpty ? "" : String(verb))
        }
    }

    /// One line `dozchat listen` printed (one item of `/agent/receive`): a message addressed to `name`, or nil — a notice, its
    /// own message, or one for someone else.
    public static func addressed(_ line: Data, name: String) -> Addressed? {
        guard let o = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              (o["type"] as? String).map({ $0 == "user" }) ?? true,
              let room = o["room"] as? String, let id = o["msg_id"] as? String, let from = o["from"] as? String, from != name,
              let content = (o["message"] as? [String: Any])?["content"] as? String,
              let text = addressedText(content, name: name) else { return nil }
        return Addressed(room: room, msgID: id, from: from, command: command(text))
    }

    /// What the stub posts after `dozchat ask` exited with `exit` and printed `output` (nil: the ask is open — it is the
    /// message). A refusal about deciders is "no decider"; any other, the server's words (its `detail` or `error`).
    public static func askAnswer(exit: Int32, output: String) -> String? {
        guard exit != 0 else { return nil }
        var why: String?
        for line in output.split(whereSeparator: \.isNewline) {
            guard let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
            why = (o["detail"] as? String) ?? (o["error"] as? String) ?? why
        }
        let words = why ?? output.split(whereSeparator: \.isNewline).first.map(String.init) ?? "dozchat exit \(exit)"
        if words.lowercased().contains("decider") { return noDecider }
        return askRefused(String(words.prefix(200)))
    }

    /// Why writing `path` failed with `errno` `e`, naming the grant or the folder rule: inside its folder (`workdir`), a
    /// folder rule that makes it read-only; outside it, the `folder.write` grant it does not have. Never a path of the Mac.
    public static func writeRefusal(errno e: Int32, path: String, workdir: String) -> String {
        guard [EPERM, EACCES, EROFS].contains(e) else { return String(cString: strerror(e)) }
        let p = URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: workdir, isDirectory: true)).standardizedFileURL.path
        let w = URL(fileURLWithPath: workdir).standardizedFileURL.path
        if p == w || p.hasPrefix(w + "/") {
            let rule = FileManager.default.fileExists(atPath: w + "/.dozreadonly") ? ".dozreadonly" : "the fence's"
            return "a folder rule (\(rule)) makes it read-only"
        }
        return "no folder.write grant — it is outside the workspace's folders"
    }

    /// The argv of process `pid` (`KERN_PROCARGS2`; nil: gone or not readable).
    public static func processArguments(_ pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var argmax: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctl(&mib, 2, &argmax, &size, nil, 0) == 0, argmax > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: Int(argmax))
        mib = [CTL_KERN, KERN_PROCARGS2, pid]
        size = buf.count
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        let argc = buf.withUnsafeBytes { $0.load(as: Int32.self) }
        var i = MemoryLayout<Int32>.size
        while i < size, buf[i] != 0 { i += 1 }          // the executable's path
        while i < size, buf[i] == 0 { i += 1 }          // its padding
        var out: [String] = []
        while i < size, out.count < Int(argc) {
            let start = i
            while i < size, buf[i] != 0 { i += 1 }
            out.append(String(decoding: buf[start..<i], as: UTF8.self))
            i += 1
        }
        return out
    }
}
